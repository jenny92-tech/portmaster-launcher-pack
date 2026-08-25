//! Small, dependency-free LAN administration server.
//!
//! The server runs on a worker thread, streams uploads to disk, and requires a
//! pairing code shown on the device before any management API can be used.

use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{IpAddr, SocketAddr, TcpListener, TcpStream};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::launcher::Session;

const FIRST_PORT: u16 = 8080;
const LAST_PORT: u16 = 8090;
const MAX_UPLOAD_BODY: u64 = 4 * 1024 * 1024 * 1024;
const MAX_CONTROL_BODY: u64 = 64 * 1024;
const MAX_HEADER_BYTES: usize = 32 * 1024;
const MAX_CONNECTIONS: usize = 8;
const HEADER_TIMEOUT: Duration = Duration::from_secs(8);
const SERVER_ID: &str = "port-app-manager";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct WebEndpoint {
    pub port: u16,
    pub code: String,
}

#[derive(Debug)]
struct RequestHead {
    method: String,
    path: String,
    content_length: Option<u64>,
    filename: String,
    token: String,
    replace_existing: bool,
}

struct AuthState {
    code: String,
    token: String,
    pairing: Mutex<HashMap<IpAddr, PairingRate>>,
    upload_active: AtomicBool,
    upload_cancel: Mutex<Option<appmanager_core::CancellationToken>>,
}

pub(crate) struct PreparedWebServer {
    listener: TcpListener,
    auth: Arc<AuthState>,
    pub(crate) endpoint: WebEndpoint,
}

#[derive(Debug)]
struct PairingRate {
    failures: u32,
    retry_after: Instant,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PairingResult {
    Accepted,
    Rejected,
    RateLimited,
}

#[derive(Default)]
struct ConnectionGate {
    active: AtomicUsize,
}

struct ConnectionLease(Arc<ConnectionGate>);

struct UploadLease<'a> {
    active: &'a AtomicBool,
    cancel: &'a Mutex<Option<appmanager_core::CancellationToken>>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ManageRequest {
    action: String,
    revision: String,
    #[serde(default)]
    paths: Vec<String>,
}

/// Bind the first available LAN port and create the pairing secret before the
/// worker starts. Keeping the listener in this value removes the old
/// probe/drop/rebind race and the need for a PID/ready-file protocol.
pub(crate) fn prepare_server() -> Result<PreparedWebServer, String> {
    for port in FIRST_PORT..=LAST_PORT {
        let Ok(listener) = TcpListener::bind(("0.0.0.0", port)) else {
            continue;
        };
        let auth = Arc::new(AuthState::new()?);
        return Ok(PreparedWebServer {
            listener,
            endpoint: WebEndpoint {
                port,
                code: auth.code.clone(),
            },
            auth,
        });
    }
    Err("no free web UI port (8080-8090 are all in use)".to_owned())
}

pub(crate) fn serve_prepared(
    request: crate::launcher::Request,
    resolved: Arc<crate::resolution::DeviceResolution>,
    health: crate::launcher::SharedHealth,
    prepared: PreparedWebServer,
    stop: Arc<std::sync::atomic::AtomicBool>,
) -> Result<u16, String> {
    serve_listener_until(
        request,
        resolved,
        health,
        prepared.listener,
        prepared.endpoint.port,
        prepared.auth,
        stop,
    )
}

fn serve_listener_until(
    request: crate::launcher::Request,
    resolved: Arc<crate::resolution::DeviceResolution>,
    health: crate::launcher::SharedHealth,
    listener: TcpListener,
    port: u16,
    auth: Arc<AuthState>,
    stop: Arc<std::sync::atomic::AtomicBool>,
) -> Result<u16, String> {
    listener
        .set_nonblocking(true)
        .map_err(|error| format!("configure web UI listener: {error}"))?;
    let stale_uploads = sweep_stale_uploads(&request.app_root)?;
    if stale_uploads > 0 {
        append_log(
            &request.app_root.join("log.txt"),
            &format!("web.serve removed {stale_uploads} stale upload(s)"),
        );
    }
    let connections = Arc::new(ConnectionGate::default());
    append_log(
        &request.app_root.join("log.txt"),
        &format!(
            "web.serve listening port={port} platform={}",
            resolved.resolution.platform_id
        ),
    );

    let mut handlers: Vec<std::thread::JoinHandle<()>> = Vec::new();
    while !stop.load(std::sync::atomic::Ordering::Acquire) {
        let mut index = 0;
        while index < handlers.len() {
            if handlers[index].is_finished() {
                let handler = handlers.swap_remove(index);
                let _ = handler.join();
            } else {
                index += 1;
            }
        }
        match listener.accept() {
            Ok((mut stream, peer)) => {
                let Some(lease) = ConnectionGate::try_acquire(&connections) else {
                    let _ = respond_error(&mut stream, 503, "远程管理正忙，请稍后重试");
                    continue;
                };
                let request = request.clone();
                let resolved = Arc::clone(&resolved);
                let health = Arc::clone(&health);
                let auth = Arc::clone(&auth);
                if let Ok(handler) = std::thread::Builder::new()
                    .name("appmanager-web-request".to_owned())
                    .spawn(move || {
                        let _lease = lease;
                        if let Err(error) =
                            handle(stream, peer, request.clone(), resolved, health, auth)
                        {
                            append_log(
                                &request.app_root.join("log.txt"),
                                &format!("web.request error: {error}"),
                            );
                        }
                    })
                {
                    handlers.push(handler);
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(error) => {
                append_log(
                    &request.app_root.join("log.txt"),
                    &format!("web.accept error: {error}"),
                );
                std::thread::sleep(Duration::from_millis(200));
            }
        }
    }
    // The listener is closed to new work above; keep the worker alive until
    // every accepted request has reached a safe transaction boundary.
    for handler in handlers {
        let _ = handler.join();
    }
    append_log(
        &request.app_root.join("log.txt"),
        &format!("web.serve stopped port={port}"),
    );
    Ok(port)
}

fn handle(
    stream: TcpStream,
    peer: SocketAddr,
    request: crate::launcher::Request,
    resolved: Arc<crate::resolution::DeviceResolution>,
    health: crate::launcher::SharedHealth,
    auth: Arc<AuthState>,
) -> Result<(), String> {
    stream
        .set_nonblocking(false)
        .map_err(|error| format!("configure accepted web connection: {error}"))?;
    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(180)));
    let mut reader = BufReader::new(stream);
    let head = match read_head_with_timeout(&mut reader, HEADER_TIMEOUT) {
        Ok(head) => head,
        Err(message) => return respond_error(reader.get_mut(), 400, &message),
    };

    match (head.method.as_str(), head.path.as_str()) {
        ("GET", "/") => {
            return respond(
                reader.get_mut(),
                200,
                "text/html; charset=utf-8",
                INDEX_HTML.as_bytes(),
            );
        }
        ("GET", "/api/status") => {
            return respond_json(
                reader.get_mut(),
                200,
                &json!({
                    "ok": true,
                    "service": SERVER_ID,
                    "paired": false,
                }),
            );
        }
        ("POST", "/api/session") => {
            let body = match read_small_body(&mut reader, head.content_length) {
                Ok(body) => body,
                Err(message) => return respond_error(reader.get_mut(), 400, &message),
            };
            let code = String::from_utf8_lossy(&body).trim().to_owned();
            match auth.verify_pairing_code(peer.ip(), &code) {
                PairingResult::Accepted => {}
                PairingResult::Rejected => {
                    return respond_error(reader.get_mut(), 401, "配对码不正确");
                }
                PairingResult::RateLimited => {
                    return respond_error(reader.get_mut(), 429, "尝试过于频繁，请稍后重试");
                }
            }
            return respond_json(
                reader.get_mut(),
                200,
                &json!({"ok": true, "token": auth.token}),
            );
        }
        _ => {}
    }

    if !constant_time_eq(head.token.as_bytes(), auth.token.as_bytes()) {
        return respond_error(reader.get_mut(), 401, "需要在设备上查看配对码");
    }

    if (head.method.as_str(), head.path.as_str()) == ("POST", "/api/cancel") {
        let cancelled = auth
            .upload_cancel
            .lock()
            .unwrap_or_else(|value| value.into_inner())
            .as_ref()
            .is_some_and(|token| {
                token.cancel();
                true
            });
        return respond_json(
            reader.get_mut(),
            200,
            &json!({"ok": true, "cancelled": cancelled}),
        );
    }

    match (head.method.as_str(), head.path.as_str()) {
        ("GET", "/api/snapshot") | ("GET", "/api/list") => {
            let session = match Session::new_pinned_without_recovery(
                request,
                Arc::clone(&resolved),
                health,
            ) {
                Ok(session) => session,
                Err(message) => return respond_error(reader.get_mut(), 500, &message),
            };
            match snapshot_json(&session, &resolved) {
                Ok(value) => respond_json(reader.get_mut(), 200, &value),
                Err(message) => respond_error(reader.get_mut(), 500, &message),
            }
        }
        ("POST", "/api/manage") => {
            let body = match read_small_body(&mut reader, head.content_length) {
                Ok(body) => body,
                Err(message) => return respond_error(reader.get_mut(), 400, &message),
            };
            let payload: ManageRequest = match serde_json::from_slice(&body) {
                Ok(payload) => payload,
                Err(error) => {
                    return respond_error(
                        reader.get_mut(),
                        400,
                        &format!("invalid management request: {error}"),
                    );
                }
            };
            let mut session = match Session::new_pinned(request, Arc::clone(&resolved), health) {
                Ok(session) => session,
                Err(message) => return respond_error(reader.get_mut(), 500, &message),
            };
            match manage(&mut session, payload) {
                Ok(()) => respond_json(reader.get_mut(), 200, &json!({"ok": true})),
                Err(message) if message.starts_with("inventory changed") => {
                    respond_error(reader.get_mut(), 409, &message)
                }
                Err(message) => respond_error(reader.get_mut(), 400, &message),
            }
        }
        ("POST", "/api/upload") => {
            let cancel_token = appmanager_core::CancellationToken::default();
            let Some(_upload_lease) = UploadLease::try_acquire(
                &auth.upload_active,
                &auth.upload_cancel,
                cancel_token.clone(),
            ) else {
                return respond_error(reader.get_mut(), 409, "已有安装包正在上传或安装");
            };
            let _ = reader
                .get_mut()
                .set_read_timeout(Some(Duration::from_secs(180)));
            let Some(length) = head.content_length else {
                return respond_error(reader.get_mut(), 400, "missing Content-Length");
            };
            if length == 0 || length > MAX_UPLOAD_BODY {
                return respond_error(reader.get_mut(), 413, "zip 文件必须小于 4 GiB");
            }
            if head.filename.is_empty() {
                return respond_error(reader.get_mut(), 400, "missing X-Filename");
            }
            let mut request = request;
            request.cancel_token = Some(cancel_token.clone());
            let session = match Session::new_pinned(request.clone(), resolved, health) {
                Ok(session) => session,
                Err(message) => return respond_error(reader.get_mut(), 423, &message),
            };
            let _reservation = match session.reserve_operation() {
                Ok(reservation) => reservation,
                Err(message) => return respond_error(reader.get_mut(), 423, &message),
            };
            let (zip_path, _upload) = match receive_upload(
                &mut reader,
                &request.app_root,
                &head.filename,
                length,
                &cancel_token,
            ) {
                Ok(upload) => upload,
                Err(message) => return respond_error(reader.get_mut(), 400, &message),
            };
            match session.install_zip_reserved(
                zip_path.to_string_lossy().into_owned(),
                head.replace_existing,
            ) {
                Ok(result) => respond_json(
                    reader.get_mut(),
                    200,
                    &json!({"ok": true, "result": result}),
                ),
                Err(message) => respond_error(reader.get_mut(), 400, &message),
            }
        }
        _ => respond_error(reader.get_mut(), 404, "not found"),
    }
}

#[cfg(test)]
fn read_head(reader: &mut impl BufRead) -> Result<RequestHead, String> {
    read_head_with_timeout(reader, Duration::from_secs(60))
}

fn read_head_with_timeout(
    reader: &mut impl BufRead,
    timeout: Duration,
) -> Result<RequestHead, String> {
    let started = Instant::now();
    let mut used = 0_usize;
    let request_line = read_limited_line(reader, MAX_HEADER_BYTES, started, timeout)?;
    if request_line.is_empty() {
        return Err("empty request".to_owned());
    }
    used += request_line.len();
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or("").to_ascii_uppercase();
    let target = parts.next().unwrap_or("");
    let version = parts.next().unwrap_or("");
    if !matches!(method.as_str(), "GET" | "POST") || !version.starts_with("HTTP/1.") {
        return Err("unsupported HTTP request".to_owned());
    }
    let path = target.split('?').next().unwrap_or("").to_owned();
    if !path.starts_with('/') || path.contains(['\r', '\n', '\0']) {
        return Err("invalid request path".to_owned());
    }
    let mut content_length = None;
    let mut filename = String::new();
    let mut token = String::new();
    let mut replace_existing = false;
    loop {
        let remaining = MAX_HEADER_BYTES.saturating_sub(used);
        let line = read_limited_line(reader, remaining, started, timeout)?;
        if line.is_empty() {
            return Err("incomplete HTTP headers".to_owned());
        }
        used = used.saturating_add(line.len());
        if used > MAX_HEADER_BYTES {
            return Err("HTTP headers are too large".to_owned());
        }
        let line = line.trim_end_matches(['\r', '\n']);
        if line.is_empty() {
            break;
        }
        let Some((name, value)) = line.split_once(':') else {
            return Err("invalid HTTP header".to_owned());
        };
        match name.trim().to_ascii_lowercase().as_str() {
            "content-length" => {
                content_length = Some(
                    value
                        .trim()
                        .parse::<u64>()
                        .map_err(|_| "invalid Content-Length".to_owned())?,
                );
            }
            "transfer-encoding" if !value.trim().eq_ignore_ascii_case("identity") => {
                return Err("chunked uploads are not supported".to_owned());
            }
            "x-filename" => filename = value.trim().to_owned(),
            "x-appmanager-token" => token = value.trim().to_owned(),
            "x-appmanager-replace" => {
                replace_existing = match value.trim() {
                    "1" => true,
                    "0" | "" => false,
                    _ => return Err("invalid X-AppManager-Replace header".to_owned()),
                };
            }
            _ => {}
        }
    }
    Ok(RequestHead {
        method,
        path,
        content_length,
        filename,
        token,
        replace_existing,
    })
}

fn read_limited_line(
    reader: &mut impl BufRead,
    limit: usize,
    started: Instant,
    timeout: Duration,
) -> Result<String, String> {
    let mut bytes = Vec::new();
    loop {
        if started.elapsed() > timeout {
            return Err("HTTP headers timed out".to_owned());
        }
        let available = reader.fill_buf().map_err(|error| error.to_string())?;
        if available.is_empty() {
            break;
        }
        let take = available
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(available.len(), |index| index + 1);
        if bytes.len().saturating_add(take) > limit {
            return Err("HTTP headers are too large".to_owned());
        }
        bytes.extend_from_slice(&available[..take]);
        reader.consume(take);
        if bytes.last() == Some(&b'\n') {
            break;
        }
    }
    String::from_utf8(bytes).map_err(|_| "HTTP headers are not valid UTF-8".to_owned())
}

fn read_small_body(reader: &mut impl Read, length: Option<u64>) -> Result<Vec<u8>, String> {
    let length = length.ok_or_else(|| "missing Content-Length".to_owned())?;
    if length > MAX_CONTROL_BODY {
        return Err("request body is too large".to_owned());
    }
    let mut body = Vec::with_capacity(length as usize);
    let copied = reader
        .take(length)
        .read_to_end(&mut body)
        .map_err(|error| error.to_string())? as u64;
    if copied != length {
        return Err("request body ended early".to_owned());
    }
    Ok(body)
}

fn receive_upload(
    reader: &mut impl Read,
    app_root: &Path,
    encoded_filename: &str,
    length: u64,
    cancel_token: &appmanager_core::CancellationToken,
) -> Result<(PathBuf, UploadGuard), String> {
    let filename = safe_upload_name(&percent_decode(encoded_filename))?;
    let directory = ensure_upload_directory(app_root)?;
    if available_bytes(&directory)
        .is_some_and(|bytes| bytes < length.saturating_add(64 * 1024 * 1024))
    {
        return Err("存储空间不足，无法接收这个 zip 文件".to_owned());
    }
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let mut selected = None;
    for attempt in 0..128_u32 {
        let path = directory.join(format!(
            "{nonce}-{}-{attempt}-{filename}",
            std::process::id()
        ));
        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(file) => {
                let guard = UploadGuard::from_file(path.clone(), &file)?;
                selected = Some((path, file, guard));
                break;
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(format!("create upload file: {error}")),
        }
    }
    let (path, mut output, guard) =
        selected.ok_or_else(|| "cannot allocate upload file".to_owned())?;
    let mut copied = 0_u64;
    let mut input = reader.take(length);
    let mut buffer = [0_u8; 128 * 1024];
    while copied < length {
        if cancel_token.is_cancelled() {
            return Err("upload cancelled".to_owned());
        }
        let count = input
            .read(&mut buffer)
            .map_err(|error| format!("upload failed: {error}"))?;
        if count == 0 {
            break;
        }
        output
            .write_all(&buffer[..count])
            .map_err(|error| format!("upload failed: {error}"))?;
        copied = copied.saturating_add(count as u64);
    }
    if copied != length {
        return Err("上传中断，请重新选择文件".to_owned());
    }
    if let Err(error) = output.flush() {
        return Err(format!("flush upload: {error}"));
    }
    Ok((path, guard))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct UploadIdentity {
    device: u64,
    inode: u64,
}

fn upload_identity(path: &Path) -> Option<UploadIdentity> {
    let metadata = std::fs::symlink_metadata(path).ok()?;
    if !metadata.file_type().is_file() {
        return None;
    }
    Some(UploadIdentity {
        device: metadata.dev(),
        inode: metadata.ino(),
    })
}

fn ensure_upload_directory(app_root: &Path) -> Result<PathBuf, String> {
    let directory = app_root.join("zip-upload");
    let mut builder = std::fs::DirBuilder::new();
    builder.mode(0o700);
    match builder.create(&directory) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(format!("create upload directory: {error}")),
    }
    let metadata = std::fs::symlink_metadata(&directory)
        .map_err(|error| format!("inspect upload directory: {error}"))?;
    if !metadata.file_type().is_dir() {
        return Err("upload directory is not a real directory".to_owned());
    }
    // Best effort for an existing directory. FAT/exFAT mounts commonly do
    // not implement chmod; the directory is still private to this service's
    // app_root namespace and all entries use create_new.
    let _ = std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700));
    Ok(directory)
}

fn sweep_stale_uploads(app_root: &Path) -> Result<usize, String> {
    let directory = ensure_upload_directory(app_root)?;
    let mut removed = 0;
    for entry in
        std::fs::read_dir(&directory).map_err(|error| format!("scan upload directory: {error}"))?
    {
        let entry = entry.map_err(|error| format!("read upload entry: {error}"))?;
        let path = entry.path();
        let Some(identity) = upload_identity(&path) else {
            // Never follow or remove symlinks, directories, or special files.
            continue;
        };
        if upload_identity(&path) != Some(identity) {
            continue;
        }
        match std::fs::remove_file(&path) {
            Ok(()) => removed += 1,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(format!("remove stale upload: {error}")),
        }
    }
    Ok(removed)
}

struct UploadGuard {
    path: PathBuf,
    identity: UploadIdentity,
    // Keep the original inode alive until Drop. Without this handle, an
    // unlink followed by a same-path replacement may immediately reuse the
    // inode number and make a new file look like our old transport copy.
    _file: File,
}

impl UploadGuard {
    #[cfg(test)]
    fn new(path: PathBuf) -> Result<Self, String> {
        let file =
            File::open(&path).map_err(|error| format!("open uploaded transport: {error}"))?;
        Self::from_file(path, &file)
    }

    fn from_file(path: PathBuf, file: &File) -> Result<Self, String> {
        let metadata = file
            .metadata()
            .map_err(|error| format!("inspect upload file: {error}"))?;
        if !metadata.file_type().is_file() {
            return Err("uploaded transport is not a regular file".to_owned());
        }
        Ok(Self {
            path,
            identity: UploadIdentity {
                device: metadata.dev(),
                inode: metadata.ino(),
            },
            _file: file
                .try_clone()
                .map_err(|error| format!("pin uploaded transport: {error}"))?,
        })
    }
}

impl Drop for UploadGuard {
    fn drop(&mut self) {
        // The installer may consume the upload, while another actor can later
        // create a file with the same pathname. Only remove the exact regular
        // file that this request created; a replacement is never ours.
        if upload_identity(&self.path) == Some(self.identity) {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

fn safe_upload_name(value: &str) -> Result<String, String> {
    let base = value.rsplit(['/', '\\']).next().unwrap_or("").trim();
    if !base.to_ascii_lowercase().ends_with(".zip") {
        return Err("只支持 .zip 安装包".to_owned());
    }
    let mut safe = base
        .chars()
        .filter(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '.' | '-' | '_')
        })
        .take(96)
        .collect::<String>();
    if safe.is_empty() || safe == ".zip" {
        safe = "bundle.zip".to_owned();
    }
    Ok(safe)
}

fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut output = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%'
            && index + 2 < bytes.len()
            && let (Some(high), Some(low)) =
                (hex_value(bytes[index + 1]), hex_value(bytes[index + 2]))
        {
            let value = high * 16 + low;
            output.push(value);
            index += 3;
            continue;
        }
        output.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&output).into_owned()
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn manage(session: &mut Session, payload: ManageRequest) -> Result<(), String> {
    if payload.revision.len() != 64
        || !payload
            .revision
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        return Err("invalid inventory revision".to_owned());
    }
    if payload.paths.len() > 256 {
        return Err("too many selected paths".to_owned());
    }
    let actions = match payload.action.as_str() {
        "uninstall" if !payload.paths.is_empty() => payload
            .paths
            .into_iter()
            .map(|arg| crate::launcher::EmbeddedAction {
                kind: "TRASH".to_owned(),
                arg,
                source_identity: None,
                replace_existing: false,
            })
            .collect(),
        "restore" if !payload.paths.is_empty() => payload
            .paths
            .into_iter()
            .map(|arg| crate::launcher::EmbeddedAction {
                kind: "RESTORE_ITEM".to_owned(),
                arg,
                source_identity: None,
                replace_existing: false,
            })
            .collect(),
        "restore_replace" if !payload.paths.is_empty() => payload
            .paths
            .into_iter()
            .map(|arg| crate::launcher::EmbeddedAction {
                kind: "RESTORE_REPLACE".to_owned(),
                arg,
                source_identity: None,
                replace_existing: false,
            })
            .collect(),
        "delete" if !payload.paths.is_empty() => payload
            .paths
            .into_iter()
            .map(|arg| crate::launcher::EmbeddedAction {
                kind: "DELETE_ITEM".to_owned(),
                arg,
                source_identity: None,
                replace_existing: false,
            })
            .collect(),
        "empty_trash" if payload.paths.is_empty() => vec![crate::launcher::EmbeddedAction {
            kind: "EMPTY_TRASH".to_owned(),
            arg: "-".to_owned(),
            source_identity: None,
            replace_existing: false,
        }],
        _ => return Err("invalid management action".to_owned()),
    };
    crate::launcher::apply_embedded_actions_at_revision(session, &actions, Some(&payload.revision))
}

fn snapshot_json(
    session: &Session,
    resolved: &crate::resolution::DeviceResolution,
) -> Result<Value, String> {
    let report = session
        .inventory_snapshot()?
        .unwrap_or_else(crate::launcher::empty_inventory);
    let revision = crate::launcher::inventory_revision(&report);
    let can_manage_apps =
        resolved.context.capabilities.manage_apps == appmanager_core::CapabilityState::Current;
    let can_manage_ports =
        resolved.context.capabilities.manage_ports == appmanager_core::CapabilityState::Current;
    let mut items = Vec::new();
    for app in &report.apps {
        let manageable = can_manage_apps && !crate::launcher::protected_app_name(&app.name);
        items.push(json!({
            "id": format!("app:{}:{}", app.root_id, app.name),
            "name": app.label_zh.as_deref().or(app.label.as_deref()).unwrap_or(&app.name),
            "raw_name": app.name,
            "kind": "app",
            "paths": [app.folder.to_string_lossy()],
            "manageable": manageable,
        }));
    }
    for port in &report.ports {
        let mut paths = vec![port.path.to_string_lossy().into_owned()];
        if !report.classification_uncertain
            && port.dir_exists
            && !port.dir.is_empty()
            && report
                .data_refcount
                .get(&port.data_path.to_string_lossy().into_owned())
                .copied()
                .unwrap_or(0)
                == 1
        {
            paths.push(port.data_path.to_string_lossy().into_owned());
        }
        for image in &port.images {
            let users = report
                .ports
                .iter()
                .filter(|candidate| candidate.images.iter().any(|item| item.path == image.path))
                .count();
            if users == 1 {
                paths.push(image.path.to_string_lossy().into_owned());
            }
        }
        items.push(json!({
            "id": format!("port:{}", port.script),
            "name": port.script.strip_suffix(".sh").unwrap_or(&port.script),
            "raw_name": port.script,
            "kind": "port",
            "paths": paths,
            "manageable": can_manage_ports,
            "keeps_shared_data": port.dir_exists
                && !paths.contains(&port.data_path.to_string_lossy().into_owned()),
        }));
    }
    items.sort_by(|left, right| {
        let left = left
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_ascii_lowercase();
        let right = right
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_ascii_lowercase();
        left.cmp(&right)
    });
    let trash = report
        .trash
        .iter()
        .map(|entry| {
            let restorable = (can_manage_ports
                && matches!(
                    entry.bucket.as_str(),
                    "scripts" | "script-images" | "images" | "data"
                ))
                || (can_manage_apps
                    && entry.bucket.strip_prefix("apps-").is_some_and(|root_id| {
                        resolved.context.roots.apps.iter().any(|root| {
                            root.id == root_id
                                && root
                                    .roles
                                    .contains(&portkit_core::LocationRole::TrashRestore)
                        })
                    }));
            json!({
                "name": entry.name,
                "path": entry.path.to_string_lossy(),
                "bucket": entry.bucket,
                "is_dir": entry.is_dir,
                "restorable": restorable,
                "restore_target": entry.restore_target.to_string_lossy(),
                "restore_conflict": entry.restore_conflict,
            })
        })
        .collect::<Vec<_>>();
    Ok(json!({
        "ok": true,
        "device": {
            "name": resolved.resolution.model_display_name.as_deref()
                .unwrap_or(&resolved.resolution.platform_display_name),
            "platform": resolved.resolution.platform_display_name,
        },
        "items": items,
        "trash": trash,
        "revision": revision,
        "capabilities": {
            "install": resolved.resolution.capabilities.get("install_ports") == Some(&true)
                || resolved.resolution.capabilities.get("install_apps") == Some(&true),
            "manage_apps": can_manage_apps,
            "manage_ports": can_manage_ports,
            "trash": resolved.context.capabilities.trash
                == appmanager_core::CapabilityState::Current,
        },
        "limits": {"upload_bytes": MAX_UPLOAD_BODY},
    }))
}

impl AuthState {
    fn new() -> Result<Self, String> {
        let mut bytes = [0_u8; 36];
        File::open("/dev/urandom")
            .and_then(|mut file| file.read_exact(&mut bytes))
            .map_err(|error| format!("generate web pairing secret: {error}"))?;
        let number = u32::from_ne_bytes(bytes[0..4].try_into().expect("four bytes")) % 1_000_000;
        let token = bytes[4..]
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        #[cfg(debug_assertions)]
        let code = std::env::var("PAM_WEB_TEST_CODE")
            .ok()
            .filter(|value| value.len() == 6 && value.bytes().all(|byte| byte.is_ascii_digit()))
            .unwrap_or_else(|| format!("{number:06}"));
        #[cfg(not(debug_assertions))]
        let code = format!("{number:06}");
        Ok(Self {
            code,
            token,
            pairing: Mutex::new(HashMap::new()),
            upload_active: AtomicBool::new(false),
            upload_cancel: Mutex::new(None),
        })
    }

    fn verify_pairing_code(&self, peer: IpAddr, candidate: &str) -> PairingResult {
        let now = Instant::now();
        let mut rates = self
            .pairing
            .lock()
            .unwrap_or_else(|value| value.into_inner());
        rates.retain(|_, rate| now.duration_since(rate.retry_after) < Duration::from_secs(300));
        if !rates.contains_key(&peer) && rates.len() >= 64 {
            return PairingResult::RateLimited;
        }
        let rate = rates.entry(peer).or_insert(PairingRate {
            failures: 0,
            retry_after: now,
        });
        if now < rate.retry_after {
            return PairingResult::RateLimited;
        }
        if constant_time_eq(candidate.as_bytes(), self.code.as_bytes()) {
            rate.failures = 0;
            rate.retry_after = now;
            return PairingResult::Accepted;
        }
        rate.failures = rate.failures.saturating_add(1);
        let exponent = rate.failures.saturating_sub(1).min(5);
        let delay_ms = 250_u64.saturating_mul(1_u64 << exponent);
        rate.retry_after = now + Duration::from_millis(delay_ms.min(8_000));
        PairingResult::Rejected
    }
}

impl ConnectionGate {
    fn try_acquire(gate: &Arc<Self>) -> Option<ConnectionLease> {
        let mut active = gate.active.load(Ordering::Acquire);
        loop {
            if active >= MAX_CONNECTIONS {
                return None;
            }
            match gate.active.compare_exchange_weak(
                active,
                active + 1,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => return Some(ConnectionLease(Arc::clone(gate))),
                Err(current) => active = current,
            }
        }
    }
}

impl Drop for ConnectionLease {
    fn drop(&mut self) {
        self.0.active.fetch_sub(1, Ordering::AcqRel);
    }
}

impl<'a> UploadLease<'a> {
    fn try_acquire(
        active: &'a AtomicBool,
        cancel: &'a Mutex<Option<appmanager_core::CancellationToken>>,
        token: appmanager_core::CancellationToken,
    ) -> Option<Self> {
        active
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .ok()
            .map(|_| {
                *cancel.lock().unwrap_or_else(|value| value.into_inner()) = Some(token);
                Self { active, cancel }
            })
    }
}

impl Drop for UploadLease<'_> {
    fn drop(&mut self) {
        self.cancel
            .lock()
            .unwrap_or_else(|value| value.into_inner())
            .take();
        self.active.store(false, Ordering::Release);
    }
}

fn append_log(path: &Path, message: &str) {
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "[PAM] {message}");
    }
}

fn respond_json(stream: &mut TcpStream, status: u16, value: &Value) -> Result<(), String> {
    respond(
        stream,
        status,
        "application/json; charset=utf-8",
        value.to_string().as_bytes(),
    )
}

fn respond_error(stream: &mut TcpStream, status: u16, message: &str) -> Result<(), String> {
    respond_json(stream, status, &json!({"ok": false, "error": message}))
}

fn respond(
    stream: &mut TcpStream,
    status: u16,
    content_type: &str,
    body: &[u8],
) -> Result<(), String> {
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        409 => "Conflict",
        429 => "Too Many Requests",
        404 => "Not Found",
        413 => "Payload Too Large",
        423 => "Locked",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        _ => "Error",
    };
    let header = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; frame-ancestors 'none'\r\n\r\n",
        body.len()
    );
    stream
        .write_all(header.as_bytes())
        .and_then(|_| stream.write_all(body))
        .map_err(|error| error.to_string())
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.iter()
        .zip(right)
        .fold(0_u8, |difference, (left, right)| {
            difference | (left ^ right)
        })
        == 0
}

#[cfg(unix)]
fn available_bytes(path: &Path) -> Option<u64> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    let path = CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut value = std::mem::MaybeUninit::<libc::statvfs>::uninit();
    if unsafe { libc::statvfs(path.as_ptr(), value.as_mut_ptr()) } != 0 {
        return None;
    }
    let value = unsafe { value.assume_init() };
    Some((value.f_bavail as u64).saturating_mul(value.f_frsize))
}

#[cfg(not(unix))]
fn available_bytes(_path: &Path) -> Option<u64> {
    None
}

const INDEX_HTML: &str = include_str!("web/index.html");

#[cfg(test)]
mod tests {
    use super::*;

    fn try_http(port: u16, request: &str) -> std::io::Result<String> {
        let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
        stream.write_all(request.as_bytes()).unwrap();
        stream.shutdown(std::net::Shutdown::Write).unwrap();
        let mut response = String::new();
        stream.read_to_string(&mut response)?;
        Ok(response)
    }

    fn http(port: u16, request: &str) -> String {
        try_http(port, request).unwrap()
    }

    fn response_json(response: &str) -> serde_json::Value {
        serde_json::from_str(response.split("\r\n\r\n").nth(1).unwrap()).unwrap()
    }

    #[test]
    fn parses_headers_case_insensitively() {
        let input = b"POST /api/upload HTTP/1.1\r\ncontent-length: 12\r\nX-FILENAME: game.zip\r\nx-appmanager-token: abc\r\nX-AppManager-Replace: 1\r\n\r\n";
        let mut reader = BufReader::new(&input[..]);
        let head = read_head(&mut reader).unwrap();
        assert_eq!(head.path, "/api/upload");
        assert_eq!(head.content_length, Some(12));
        assert_eq!(head.filename, "game.zip");
        assert_eq!(head.token, "abc");
        assert!(head.replace_existing);
    }

    #[test]
    fn rejects_chunked_requests_and_unsafe_upload_types() {
        let input = b"POST /api/upload HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n";
        assert!(read_head(&mut BufReader::new(&input[..])).is_err());
        assert!(safe_upload_name("../../game.zip").is_ok());
        assert!(safe_upload_name("game.tar").is_err());
        assert_eq!(
            safe_upload_name("%E6%B8%B8%E6%88%8F.zip").unwrap(),
            "E6B8B8E6888F.zip"
        );
    }

    #[test]
    fn percent_decodes_browser_filename_header() {
        assert_eq!(percent_decode("My%20Game.zip"), "My Game.zip");
        assert_eq!(
            safe_upload_name(&percent_decode("My%20Game.zip")).unwrap(),
            "MyGame.zip"
        );
    }

    #[test]
    fn constant_time_comparison_requires_equal_contents_and_length() {
        assert!(constant_time_eq(b"123456", b"123456"));
        assert!(!constant_time_eq(b"123456", b"123457"));
        assert!(!constant_time_eq(b"123456", b"12345"));
    }

    #[test]
    fn rejects_an_unterminated_header_before_allocating_past_the_limit() {
        let input = vec![b'a'; MAX_HEADER_BYTES + 1];
        let error = read_head(&mut BufReader::new(&input[..])).unwrap_err();
        assert!(error.contains("too large"));
    }

    #[test]
    fn pairing_failures_are_limited_per_peer() {
        let auth = AuthState {
            code: "123456".to_owned(),
            token: "token".to_owned(),
            pairing: Mutex::new(HashMap::new()),
            upload_active: AtomicBool::new(false),
            upload_cancel: Mutex::new(None),
        };
        let first = "10.0.0.2".parse().unwrap();
        let second = "10.0.0.3".parse().unwrap();
        assert_eq!(
            auth.verify_pairing_code(first, "000000"),
            PairingResult::Rejected
        );
        assert_eq!(
            auth.verify_pairing_code(first, "123456"),
            PairingResult::RateLimited
        );
        assert_eq!(
            auth.verify_pairing_code(second, "123456"),
            PairingResult::Accepted
        );
    }

    #[test]
    fn connection_gate_never_exceeds_the_configured_limit() {
        let gate = Arc::new(ConnectionGate::default());
        let leases = (0..MAX_CONNECTIONS)
            .map(|_| ConnectionGate::try_acquire(&gate).unwrap())
            .collect::<Vec<_>>();
        assert!(ConnectionGate::try_acquire(&gate).is_none());
        drop(leases);
        assert!(ConnectionGate::try_acquire(&gate).is_some());
    }

    #[test]
    fn upload_guard_removes_an_unconsumed_transport_copy() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("upload.zip");
        std::fs::write(&path, b"partial").unwrap();
        drop(UploadGuard::new(path.clone()).unwrap());
        assert!(!path.exists());
    }

    #[test]
    fn upload_guard_never_removes_a_replacement_at_the_same_path() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("upload.zip");
        std::fs::write(&path, b"first upload").unwrap();
        let guard = UploadGuard::new(path.clone()).unwrap();

        std::fs::remove_file(&path).unwrap();
        std::fs::write(&path, b"replacement").unwrap();
        drop(guard);

        assert_eq!(std::fs::read(&path).unwrap(), b"replacement");
    }

    #[test]
    fn stale_upload_sweep_removes_only_regular_files_from_its_private_directory() {
        let app_root = tempfile::tempdir().unwrap();
        let upload = ensure_upload_directory(app_root.path()).unwrap();
        // A power loss after core atomically quarantines a completed upload
        // leaves this exact kind of regular file. Web startup must reclaim it.
        let stale = upload.join(format!(".pam-source-v1-{}", "a".repeat(64)));
        let nested = upload.join("nested");
        let outside = app_root.path().join("outside.zip");
        let link = upload.join("linked.zip");
        std::fs::write(&stale, b"old transport").unwrap();
        std::fs::create_dir(&nested).unwrap();
        std::fs::write(&outside, b"must survive").unwrap();
        std::os::unix::fs::symlink(&outside, &link).unwrap();

        assert_eq!(sweep_stale_uploads(app_root.path()).unwrap(), 1);
        assert!(!stale.exists());
        assert!(nested.is_dir());
        assert!(
            std::fs::symlink_metadata(&link)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(std::fs::read(&outside).unwrap(), b"must survive");
        assert_eq!(
            std::fs::symlink_metadata(&upload)
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
    }

    #[test]
    fn upload_directory_refuses_a_symlink() {
        let app_root = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        std::os::unix::fs::symlink(outside.path(), app_root.path().join("zip-upload")).unwrap();

        assert!(ensure_upload_directory(app_root.path()).is_err());
        assert!(sweep_stale_uploads(app_root.path()).is_err());
    }

    #[test]
    fn real_http_server_pairs_and_returns_an_authenticated_snapshot() {
        let fixture = tempfile::tempdir().unwrap();
        let device = fixture.path().join("device");
        for relative in [
            "usr/trimui",
            "mnt/SDCARD/Roms/PORTS",
            "mnt/SDCARD/Imgs/PORTS",
            "mnt/SDCARD/Apps",
            "mnt/SDCARD/Apps/PortMaster/PortMaster",
            "app/state",
            "app/trash",
        ] {
            std::fs::create_dir_all(device.join(relative)).unwrap();
        }
        for app in ["PortMaster", "jenny92-appmanager", "Clock"] {
            let app_dir = device.join("mnt/SDCARD/Apps").join(app);
            std::fs::create_dir_all(&app_dir).unwrap();
            std::fs::write(app_dir.join("launch.sh"), b"#!/bin/sh\n").unwrap();
        }
        std::fs::write(
            device.join("mnt/SDCARD/Roms/PORTS/Z_植物大战僵尸年度版[中].sh"),
            b"#!/bin/sh\n",
        )
        .unwrap();
        let config_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../config");
        let resolved = appmanager_core::resolve_device(appmanager_core::DeviceResolutionRequest {
            launcher: "/mnt/SDCARD/Roms/PORTS/APP Manager.sh".into(),
            app_state: device.join("app/state"),
            trash: device.join("app/trash"),
            target_override: None,
            probe_root: Some(device.clone()),
            environment: std::collections::BTreeMap::new(),
            config: appmanager_core::DeviceConfigSources {
                embedded_root: std::fs::read(config_dir.join("config.json")).unwrap(),
                embedded_dir: config_dir.clone(),
                remote_root: None,
                remote_dir: None,
            },
        })
        .unwrap();
        let app_root = device.join("app");
        let request = crate::launcher::Request {
            source_dir: device.join("mnt/SDCARD/Roms/PORTS"),
            launcher: device.join("mnt/SDCARD/Roms/PORTS/APP Manager.sh"),
            app_root: app_root.clone(),
            config_directories: crate::resolution::ConfigDirectories {
                embedded: Some(config_dir),
                remote: None,
            },
            cancel_token: None,
            progress_channel: None,
        };
        // Keep the listener open while handing it to the server thread. A
        // probe-and-drop free-port helper has a real TOCTOU race under a
        // parallel test runner.
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let auth = Arc::new(AuthState::new().unwrap());
        let pairing_code = auth.code.clone();
        let stop = Arc::new(AtomicBool::new(false));
        let server_stop = Arc::clone(&stop);
        let server = std::thread::spawn(move || {
            serve_listener_until(
                request,
                Arc::new(resolved),
                Arc::new(Mutex::new(None)),
                listener,
                port,
                auth,
                server_stop,
            )
        });
        let status = http(port, "GET /api/status HTTP/1.1\r\nHost: localhost\r\n\r\n");
        assert!(status.starts_with("HTTP/1.1 200"));
        assert_eq!(response_json(&status)["service"], SERVER_ID);
        assert!(response_json(&status).get("keep_awake").is_none());

        let pair = http(
            port,
            &format!(
                "POST /api/session HTTP/1.1\r\nHost: localhost\r\nContent-Length: {}\r\n\r\n{}",
                pairing_code.len(),
                pairing_code
            ),
        );
        assert!(pair.starts_with("HTTP/1.1 200"));
        let token = response_json(&pair)["token"].as_str().unwrap().to_owned();
        let operation_lock =
            portkit_core::ExclusiveFileLock::try_acquire(&app_root.join("state/operation.lock"))
                .unwrap();
        let busy_upload = http(
            port,
            &format!(
                "POST /api/upload HTTP/1.1\r\nHost: localhost\r\nX-AppManager-Token: {token}\r\nX-Filename: game.zip\r\nContent-Length: 1048576\r\n\r\n"
            ),
        );
        assert!(busy_upload.starts_with("HTTP/1.1 423"), "{busy_upload}");
        drop(operation_lock);
        let snapshot = http(
            port,
            &format!(
                "GET /api/snapshot HTTP/1.1\r\nHost: localhost\r\nX-AppManager-Token: {token}\r\n\r\n"
            ),
        );
        assert!(snapshot.starts_with("HTTP/1.1 200"), "{snapshot}");
        let body = response_json(&snapshot);
        assert_eq!(body["ok"], true);
        assert!(
            body["revision"]
                .as_str()
                .is_some_and(|value| !value.is_empty())
        );
        let apps = body["items"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|item| item["kind"] == "app")
            .map(|item| {
                (
                    item["raw_name"].as_str().unwrap().to_owned(),
                    item["manageable"].as_bool().unwrap(),
                )
            })
            .collect::<std::collections::BTreeMap<_, _>>();
        assert_eq!(apps.get("PortMaster"), Some(&false));
        assert_eq!(apps.get("jenny92-appmanager"), Some(&false));
        assert_eq!(apps.get("Clock"), Some(&true));
        let port_item = body["items"]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["kind"] == "port")
            .unwrap();
        assert_eq!(port_item["name"], "Z_植物大战僵尸年度版[中]");

        // Saturating the request gate must not stop the owning worker.
        let mut busy_connections = Vec::new();
        for _ in 0..MAX_CONNECTIONS {
            let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
            stream
                .write_all(b"GET /api/status HTTP/1.1\r\nHost: localhost\r\n")
                .unwrap();
            busy_connections.push(stream);
        }
        std::thread::sleep(Duration::from_millis(100));
        assert!(!server.is_finished());
        drop(busy_connections);

        // A slow target (notably aarch64 under QEMU) may need longer than the
        // fixed sleep above to observe every closed socket and release all
        // connection leases. Wait for an ordinary request to prove that the
        // gate has capacity before testing shutdown with a draining request.
        let capacity_deadline = Instant::now() + Duration::from_secs(5);
        loop {
            match try_http(port, "GET /api/status HTTP/1.1\r\nHost: localhost\r\n\r\n") {
                Ok(response) if response.starts_with("HTTP/1.1 200") => break,
                Ok(response) => assert!(response.starts_with("HTTP/1.1 503"), "{response}"),
                Err(error) if error.kind() == std::io::ErrorKind::ConnectionReset => {}
                Err(error) => panic!("capacity probe failed: {error}"),
            }
            assert!(
                Instant::now() < capacity_deadline,
                "connection gate did not drain"
            );
            std::thread::sleep(Duration::from_millis(25));
        }

        let mut draining = TcpStream::connect(("127.0.0.1", port)).unwrap();
        draining
            .write_all(b"GET /api/status HTTP/1.1\r\nHost: localhost\r\n")
            .unwrap();
        std::thread::sleep(Duration::from_millis(100));
        stop.store(true, Ordering::Release);
        std::thread::sleep(Duration::from_millis(100));
        assert!(!server.is_finished());
        drop(draining);
        server.join().unwrap().unwrap();
    }
}
