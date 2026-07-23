//! Official Runtime metadata parsing and rollback-safe Runtime repair.

use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use portkit_core::github::{Capability, GitHubError, GitHubTransport, Progress};
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::path::{ManagedRoot, PathSafetyError};
use crate::{CancellationToken, ProgressChannel, TaskProgress};

const OFFICIAL_PREFIX: &str = "https://github.com/PortsMaster/PortMaster-New/releases/download/";
const MAX_METADATA_BYTES: usize = 32 * 1024 * 1024;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct RuntimeMetadataEntry {
    pub name: String,
    pub arch: String,
    pub size: u64,
    pub md5: String,
    pub url: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeMetadata {
    entries: BTreeMap<(String, String), RuntimeMetadataEntry>,
}

#[derive(Debug, Deserialize)]
struct PortsDocument {
    utils: BTreeMap<String, serde_json::Value>,
}

#[derive(Debug, Deserialize)]
struct RawRuntime {
    runtime_name: String,
    runtime_arch: String,
    size: u64,
    md5: String,
    url: String,
}

impl RuntimeMetadata {
    pub fn parse(bytes: &[u8]) -> Result<Self, RuntimeRepairError> {
        if bytes.is_empty() || bytes.len() > MAX_METADATA_BYTES {
            return Err(RuntimeRepairError::InvalidMetadata(
                "ports.json is empty or exceeds 32 MiB".to_owned(),
            ));
        }
        let document: PortsDocument = serde_json::from_slice(bytes)
            .map_err(|error| RuntimeRepairError::InvalidMetadata(error.to_string()))?;
        let mut entries = BTreeMap::new();
        for value in document.utils.into_values() {
            let Ok(raw) = serde_json::from_value::<RawRuntime>(value) else {
                continue;
            };
            let Some(entry) = validate_raw_runtime(raw) else {
                continue;
            };
            let key = (entry.name.clone(), entry.arch.clone());
            if entries.insert(key.clone(), entry).is_some() {
                return Err(RuntimeRepairError::InvalidMetadata(format!(
                    "duplicate Runtime metadata for {} ({})",
                    key.0, key.1
                )));
            }
        }
        if entries.is_empty() {
            return Err(RuntimeRepairError::InvalidMetadata(
                "ports.json contains no valid Runtime entries".to_owned(),
            ));
        }
        Ok(Self { entries })
    }

    pub fn get(&self, name: &str, arch: &str) -> Option<&RuntimeMetadataEntry> {
        self.entries.get(&(name.to_owned(), arch.to_owned()))
    }

    pub fn entries(&self) -> impl Iterator<Item = &RuntimeMetadataEntry> {
        self.entries.values()
    }

    pub fn to_tsv(&self) -> String {
        let mut output = String::new();
        for entry in self.entries() {
            use std::fmt::Write as _;
            writeln!(
                output,
                "{}\t{}\t{}\t{}\t{}",
                entry.name, entry.arch, entry.size, entry.md5, entry.url
            )
            .expect("writing to a String cannot fail");
        }
        output
    }
}

fn validate_raw_runtime(raw: RawRuntime) -> Option<RuntimeMetadataEntry> {
    if !matches!(raw.runtime_arch.as_str(), "aarch64" | "armhf" | "x86_64")
        || raw.size == 0
        || raw.md5.len() != 32
        || !raw.md5.bytes().all(|byte| byte.is_ascii_hexdigit())
        || !raw.runtime_name.ends_with(".squashfs")
        || !safe_asset_name(&raw.runtime_name)
    {
        return None;
    }
    let suffix = raw.url.strip_prefix(OFFICIAL_PREFIX)?;
    let (release, asset) = suffix.split_once('/')?;
    if release.is_empty()
        || release.contains('/')
        || asset != raw.runtime_name
        || !safe_asset_name(asset)
    {
        return None;
    }
    let name = raw.runtime_name.strip_suffix(".squashfs")?.to_owned();
    if !safe_runtime_name(&name) {
        return None;
    }
    Some(RuntimeMetadataEntry {
        name,
        arch: raw.runtime_arch,
        size: raw.size,
        md5: raw.md5.to_ascii_lowercase(),
        url: raw.url,
    })
}

fn safe_asset_name(name: &str) -> bool {
    !name.is_empty()
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'+' | b'-'))
}

fn safe_runtime_name(name: &str) -> bool {
    safe_asset_name(name) && !name.starts_with('.') && !name.contains("..")
}

#[derive(Clone, Debug)]
pub struct RuntimeRepairRequest {
    pub metadata: Vec<u8>,
    pub runtime_names: Vec<String>,
    pub arch: String,
    pub libs_root: PathBuf,
    pub progress_file: PathBuf,
    pub cancel_file: Option<PathBuf>,
    pub cancel_token: Option<CancellationToken>,
    pub progress_channel: Option<ProgressChannel>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum RuntimeRepairSource {
    Current,
    Cache,
    Network,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct RuntimeRepairItem {
    pub name: String,
    pub source: RuntimeRepairSource,
    pub route_id: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct RuntimeRepairOutcome {
    pub schema: u32,
    pub arch: String,
    pub runtimes: Vec<RuntimeRepairItem>,
}

#[derive(Debug, Error)]
pub enum RuntimeRepairError {
    #[error("invalid official Runtime metadata: {0}")]
    InvalidMetadata(String),
    #[error("unsupported Runtime architecture: {0}")]
    UnsupportedArchitecture(String),
    #[error("invalid Runtime name: {0}")]
    InvalidName(String),
    #[error("Runtime metadata does not contain {name} for {arch}")]
    MissingMetadata { name: String, arch: String },
    #[error("Runtime repair was cancelled")]
    Cancelled,
    #[error("unsafe Runtime repair path: {0}")]
    UnsafePath(#[from] PathSafetyError),
    #[error("Runtime download failed: {0}")]
    Download(String),
    #[error("Runtime image failed strict validation: {0}")]
    Validation(String),
    #[error("Runtime repair I/O failed: {0}")]
    Io(#[from] io::Error),
}

pub fn repair_runtimes(
    request: &RuntimeRepairRequest,
) -> Result<RuntimeRepairOutcome, RuntimeRepairError> {
    let transport = GitHubTransport::new();
    repair_with_fetcher(request, |entry, output, progress| {
        match transport.fetch(
            Capability::Release,
            &entry.url,
            output,
            |path| validate_image(path, entry).is_ok(),
            Some(progress),
            Some(entry.size),
        ) {
            Ok(outcome) => Ok(outcome.route_id().to_owned()),
            Err(GitHubError::Io(error)) if error.kind() == io::ErrorKind::Interrupted => {
                Err(RuntimeRepairError::Cancelled)
            }
            Err(error) => Err(RuntimeRepairError::Download(error.to_string())),
        }
    })
}

fn repair_with_fetcher<F>(
    request: &RuntimeRepairRequest,
    mut fetch: F,
) -> Result<RuntimeRepairOutcome, RuntimeRepairError>
where
    F: FnMut(&RuntimeMetadataEntry, &Path, &dyn Progress) -> Result<String, RuntimeRepairError>,
{
    if !matches!(request.arch.as_str(), "aarch64" | "armhf" | "x86_64") {
        return Err(RuntimeRepairError::UnsupportedArchitecture(
            request.arch.clone(),
        ));
    }
    if request.runtime_names.is_empty() {
        return Err(RuntimeRepairError::InvalidName(
            "at least one Runtime is required".to_owned(),
        ));
    }
    let metadata = RuntimeMetadata::parse(&request.metadata)?;
    let mut selected = Vec::with_capacity(request.runtime_names.len());
    let mut seen = BTreeSet::new();
    let mut total = 0_u64;
    for name in &request.runtime_names {
        if !safe_runtime_name(name) || !seen.insert(name.clone()) {
            return Err(RuntimeRepairError::InvalidName(name.clone()));
        }
        let entry = metadata.get(name, &request.arch).ok_or_else(|| {
            RuntimeRepairError::MissingMetadata {
                name: name.clone(),
                arch: request.arch.clone(),
            }
        })?;
        total = total.checked_add(entry.size).ok_or_else(|| {
            RuntimeRepairError::InvalidMetadata("Runtime size total overflowed".to_owned())
        })?;
        selected.push(entry.clone());
    }

    let progress = ProgressWriter::new(
        &request.progress_file,
        selected.len(),
        total,
        request.progress_channel.clone(),
    )?;
    progress.write("preparing", "", 0, 0, "Preparing operation")?;
    let result = repair_selected(request, &selected, &progress, &mut fetch);
    if let Err(error) = &result {
        let phase = if matches!(error, RuntimeRepairError::Cancelled) {
            "cancelled"
        } else {
            "failed"
        };
        let _ = progress.write(phase, "", 0, 0, &error.to_string());
    }
    result
}

fn repair_selected<F>(
    request: &RuntimeRepairRequest,
    selected: &[RuntimeMetadataEntry],
    progress: &ProgressWriter,
    fetch: &mut F,
) -> Result<RuntimeRepairOutcome, RuntimeRepairError>
where
    F: FnMut(&RuntimeMetadataEntry, &Path, &dyn Progress) -> Result<String, RuntimeRepairError>,
{
    check_cancel(request)?;
    let libs = prepare_root(&request.libs_root)?;
    let progress_parent = request
        .progress_file
        .parent()
        .ok_or_else(|| RuntimeRepairError::InvalidName("progress file has no parent".to_owned()))?;
    let state = ManagedRoot::new(progress_parent)?;
    state.validate_direct_child(&request.progress_file)?;
    let cache_path = state.join_child("runtime-cache")?;
    let cache = prepare_root(&cache_path)?;

    let mut completed = 0_u64;
    let mut outcomes = Vec::with_capacity(selected.len());
    for (offset, entry) in selected.iter().enumerate() {
        let index = offset + 1;
        check_cancel(request)?;
        progress.write_at("preparing", &entry.name, index, completed, 0, &entry.name)?;
        let target = libs.join_child(&format!("{}.squashfs", entry.name))?;
        reject_directory(&target)?;
        if !is_symlink(&target)? && validate_image(&target, entry).is_ok() {
            completed += entry.size;
            progress.write_at(
                "finished",
                &entry.name,
                index,
                completed,
                0,
                "Already valid",
            )?;
            outcomes.push(RuntimeRepairItem {
                name: entry.name.clone(),
                source: RuntimeRepairSource::Current,
                route_id: None,
            });
            continue;
        }

        let cache_dir_path = cache.join_child(&entry.md5)?;
        let cache_dir = prepare_root(&cache_dir_path)?;
        let download = cache_dir.join_child("runtime.download")?;
        clean_symlink(&download)?;
        clean_symlink(&suffixed_path(&download, ".part"))?;
        clean_symlink(&suffixed_path(&download, ".part.route"))?;

        let (source, route_id) = if validate_image(&download, entry).is_ok() {
            progress.write_at(
                "downloading",
                &entry.name,
                index,
                completed + entry.size,
                0,
                "Using local cache",
            )?;
            (RuntimeRepairSource::Cache, None)
        } else {
            remove_regular_if_exists(&download)?;
            progress.write_at(
                "probing",
                &entry.name,
                index,
                completed,
                0,
                "Checking routes",
            )?;
            progress.write_at(
                "downloading",
                &entry.name,
                index,
                completed,
                0,
                "Downloading Runtime",
            )?;
            let live_progress = RuntimeDownloadProgress::new(
                progress,
                request.cancel_file.as_deref(),
                request.cancel_token.as_ref(),
                &entry.name,
                index,
                completed,
            );
            let route = fetch(entry, &download, &live_progress)?;
            (RuntimeRepairSource::Network, Some(route))
        };

        check_cancel(request)?;
        progress.write_at(
            "verifying",
            &entry.name,
            index,
            completed + entry.size,
            0,
            &entry.name,
        )?;
        validate_image(&download, entry)?;
        let staged = libs.join_child(&format!(
            ".pam-{}.squashfs.{}",
            entry.name,
            std::process::id()
        ))?;
        remove_regular_if_exists(&staged)?;
        progress.write_at(
            "installing",
            &entry.name,
            index,
            completed + entry.size,
            0,
            &target.to_string_lossy(),
        )?;
        if let Err(error) = stage_and_replace(&download, &staged, &target, entry) {
            let _ = remove_regular_if_exists(&staged);
            return Err(error);
        }
        completed += entry.size;
        // Installation has committed. A removable-media progress write must
        // not retroactively report this Runtime as a failed replacement.
        let _ = progress.write_at("finished", &entry.name, index, completed, 0, &entry.name);
        outcomes.push(RuntimeRepairItem {
            name: entry.name.clone(),
            source,
            route_id,
        });
    }
    let _ = progress.write(
        "complete",
        "",
        selected.len(),
        completed,
        "Operation complete",
    );
    Ok(RuntimeRepairOutcome {
        schema: 1,
        arch: request.arch.clone(),
        runtimes: outcomes,
    })
}

fn prepare_root(path: &Path) -> Result<ManagedRoot, RuntimeRepairError> {
    let root = ManagedRoot::new(path)?;
    fs::create_dir_all(root.path())?;
    if !fs::metadata(root.path())?.is_dir() {
        return Err(RuntimeRepairError::Io(io::Error::new(
            io::ErrorKind::NotADirectory,
            format!("{} is not a directory", root.path().display()),
        )));
    }
    Ok(ManagedRoot::new(path)?)
}

fn stage_and_replace(
    source: &Path,
    staged: &Path,
    target: &Path,
    entry: &RuntimeMetadataEntry,
) -> Result<(), RuntimeRepairError> {
    let mut input = File::open(source)?;
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(staged)?;
    io::copy(&mut input, &mut output)?;
    output.sync_all()?;
    drop(output);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(staged, fs::Permissions::from_mode(0o644))?;
    }
    validate_image(staged, entry)?;
    check_target_replaceable(target)?;
    fs::rename(staged, target)?;
    if let Some(parent) = target.parent() {
        // The rename is the transaction commit point. Some removable-media
        // filesystems reject directory fsync even though the atomic rename
        // succeeded, so a durability hint must not turn a committed repair
        // into a reported failure.
        let _ = File::open(parent).and_then(|directory| directory.sync_all());
    }
    Ok(())
}

fn validate_image(path: &Path, entry: &RuntimeMetadataEntry) -> Result<(), RuntimeRepairError> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|_| RuntimeRepairError::Validation(entry.name.clone()))?;
    if !metadata.file_type().is_file() || metadata.len() != entry.size {
        return Err(RuntimeRepairError::Validation(entry.name.clone()));
    }
    let mut file =
        File::open(path).map_err(|_| RuntimeRepairError::Validation(entry.name.clone()))?;
    let mut magic = [0_u8; 4];
    file.read_exact(&mut magic)
        .map_err(|_| RuntimeRepairError::Validation(entry.name.clone()))?;
    if &magic != b"hsqs" {
        return Err(RuntimeRepairError::Validation(entry.name.clone()));
    }
    let mut context = md5::Context::new();
    context.consume(magic);
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let count = file
            .read(&mut buffer)
            .map_err(|_| RuntimeRepairError::Validation(entry.name.clone()))?;
        if count == 0 {
            break;
        }
        context.consume(&buffer[..count]);
    }
    if format!("{:x}", context.compute()) != entry.md5 {
        return Err(RuntimeRepairError::Validation(entry.name.clone()));
    }
    Ok(())
}

fn check_cancel(request: &RuntimeRepairRequest) -> Result<(), RuntimeRepairError> {
    if request
        .cancel_token
        .as_ref()
        .is_some_and(CancellationToken::is_cancelled)
        || request
            .cancel_file
            .as_ref()
            .is_some_and(|path| path.exists())
    {
        Err(RuntimeRepairError::Cancelled)
    } else {
        Ok(())
    }
}

fn check_target_replaceable(path: &Path) -> Result<(), RuntimeRepairError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_dir() => Err(RuntimeRepairError::Io(
            io::Error::new(io::ErrorKind::IsADirectory, path.display().to_string()),
        )),
        Ok(_) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

fn reject_directory(path: &Path) -> Result<(), RuntimeRepairError> {
    check_target_replaceable(path)
}

fn is_symlink(path: &Path) -> Result<bool, RuntimeRepairError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => Ok(metadata.file_type().is_symlink()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error.into()),
    }
}

fn clean_symlink(path: &Path) -> Result<(), RuntimeRepairError> {
    if is_symlink(path)? {
        fs::remove_file(path)?;
    }
    Ok(())
}

fn remove_regular_if_exists(path: &Path) -> Result<(), RuntimeRepairError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_dir() => Err(RuntimeRepairError::Io(
            io::Error::new(io::ErrorKind::IsADirectory, path.display().to_string()),
        )),
        Ok(_) => {
            fs::remove_file(path)?;
            Ok(())
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

fn suffixed_path(path: &Path, suffix: &str) -> PathBuf {
    let mut value = path.as_os_str().to_os_string();
    value.push(suffix);
    PathBuf::from(value)
}

struct RuntimeDownloadProgress<'a> {
    writer: &'a ProgressWriter,
    cancel_file: Option<&'a Path>,
    cancel_token: Option<&'a CancellationToken>,
    runtime: &'a str,
    index: usize,
    completed: u64,
    state: Mutex<RuntimeDownloadState>,
}

struct RuntimeDownloadState {
    start: Instant,
    base: u64,
    previous: u64,
    last_write: Option<Instant>,
}

impl<'a> RuntimeDownloadProgress<'a> {
    fn new(
        writer: &'a ProgressWriter,
        cancel_file: Option<&'a Path>,
        cancel_token: Option<&'a CancellationToken>,
        runtime: &'a str,
        index: usize,
        completed: u64,
    ) -> Self {
        Self {
            writer,
            cancel_file,
            cancel_token,
            runtime,
            index,
            completed,
            state: Mutex::new(RuntimeDownloadState {
                start: Instant::now(),
                base: 0,
                previous: 0,
                last_write: None,
            }),
        }
    }
}

impl Progress for RuntimeDownloadProgress<'_> {
    fn begin(&self, received: u64, total: u64) -> io::Result<()> {
        let now = Instant::now();
        {
            let mut state = self
                .state
                .lock()
                .map_err(|_| io::Error::other("Runtime progress lock poisoned"))?;
            state.start = now;
            state.base = received;
            state.previous = received;
            state.last_write = None;
        }
        self.update(received, total)
    }

    fn finish(&self, received: u64, total: u64) -> io::Result<()> {
        self.state
            .lock()
            .map_err(|_| io::Error::other("Runtime progress lock poisoned"))?
            .last_write = Some(Instant::now() - Duration::from_millis(250));
        self.update(received, total)
    }

    fn update(&self, received: u64, total: u64) -> io::Result<()> {
        if self
            .cancel_token
            .is_some_and(CancellationToken::is_cancelled)
            || self.cancel_file.is_some_and(Path::exists)
        {
            return Err(io::Error::new(io::ErrorKind::Interrupted, "cancelled"));
        }
        let now = Instant::now();
        let mut state = self
            .state
            .lock()
            .map_err(|_| io::Error::other("Runtime progress lock poisoned"))?;
        if received < state.previous {
            state.start = now;
            state.base = received;
            state.last_write = None;
        } else if state.last_write.is_none() {
            state.start = now;
            state.base = received;
        }
        state.previous = received;
        if state
            .last_write
            .is_some_and(|last| now.duration_since(last) < Duration::from_millis(250))
            && (total == 0 || received != total)
        {
            return Ok(());
        }
        let elapsed = now.duration_since(state.start).as_secs_f64();
        let speed = if elapsed > 0.0 {
            ((received - state.base) as f64 / elapsed) as u64
        } else {
            0
        };
        self.writer
            .write_at(
                "downloading",
                self.runtime,
                self.index,
                self.completed.saturating_add(received),
                speed,
                "Downloading Runtime",
            )
            .map_err(|error| io::Error::other(error.to_string()))?;
        state.last_write = Some(now);
        Ok(())
    }
}

struct ProgressWriter {
    path: PathBuf,
    count: usize,
    total: u64,
    channel: Option<ProgressChannel>,
    #[cfg(not(unix))]
    lock_path: PathBuf,
    _lock: File,
}

impl ProgressWriter {
    fn new(
        path: &Path,
        count: usize,
        total: u64,
        channel: Option<ProgressChannel>,
    ) -> Result<Self, RuntimeRepairError> {
        if !path.is_absolute() {
            return Err(RuntimeRepairError::UnsafePath(PathSafetyError::NotAbsolute));
        }
        let parent = path.parent().ok_or(PathSafetyError::FilesystemRoot)?;
        let root = ManagedRoot::new(parent)?;
        fs::create_dir_all(root.path())?;
        let root = ManagedRoot::new(parent)?;
        root.validate_direct_child(path)?;
        if is_symlink(path)? {
            return Err(RuntimeRepairError::UnsafePath(PathSafetyError::Symlink(
                path.to_path_buf(),
            )));
        }
        let lock_path = suffixed_path(path, ".lock");
        if is_symlink(&lock_path)? {
            return Err(RuntimeRepairError::UnsafePath(PathSafetyError::Symlink(
                lock_path,
            )));
        }
        #[cfg(unix)]
        let lock = {
            let lock = OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .truncate(false)
                .open(&lock_path)?;
            try_lock_progress(&lock)?;
            lock
        };
        #[cfg(not(unix))]
        let lock = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&lock_path)
            .map_err(|error| {
                if error.kind() == io::ErrorKind::AlreadyExists {
                    io::Error::new(
                        io::ErrorKind::WouldBlock,
                        "Runtime repair is already active",
                    )
                } else {
                    error
                }
            })?;
        Ok(Self {
            path: path.to_path_buf(),
            count,
            total,
            channel,
            #[cfg(not(unix))]
            lock_path,
            _lock: lock,
        })
    }

    fn write(
        &self,
        phase: &str,
        runtime: &str,
        index: usize,
        current: u64,
        detail: &str,
    ) -> Result<(), RuntimeRepairError> {
        self.write_at(phase, runtime, index, current, 0, detail)
    }

    fn write_at(
        &self,
        phase: &str,
        runtime: &str,
        index: usize,
        current: u64,
        speed: u64,
        detail: &str,
    ) -> Result<(), RuntimeRepairError> {
        let clean = detail.replace(['\t', '\r', '\n'], " ");
        if let Some(channel) = &self.channel {
            channel.publish(TaskProgress {
                phase: phase.to_owned(),
                runtime: runtime.to_owned(),
                index: index as u64,
                count: self.count as u64,
                current: current.min(self.total),
                total: self.total,
                speed,
                detail: clean.clone(),
            });
        }
        let temp = suffixed_path(&self.path, &format!(".tmp.{}", std::process::id()));
        if is_symlink(&temp)? {
            return Err(RuntimeRepairError::UnsafePath(PathSafetyError::Symlink(
                temp,
            )));
        }
        remove_regular_if_exists(&temp)?;
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)?;
        writeln!(
            file,
            "1\t{phase}\t{runtime}\t{index}\t{}\t{}\t{}\t{speed}\t{clean}",
            self.count,
            current.min(self.total),
            self.total
        )?;
        file.sync_all()?;
        drop(file);
        if is_symlink(&self.path)? {
            let _ = fs::remove_file(&temp);
            return Err(RuntimeRepairError::UnsafePath(PathSafetyError::Symlink(
                self.path.clone(),
            )));
        }
        fs::rename(temp, &self.path)?;
        Ok(())
    }
}

impl Drop for ProgressWriter {
    fn drop(&mut self) {
        #[cfg(not(unix))]
        let _ = fs::remove_file(&self.lock_path);
    }
}

#[cfg(unix)]
fn try_lock_progress(file: &File) -> io::Result<()> {
    use std::os::fd::AsRawFd;

    unsafe extern "C" {
        fn flock(file_descriptor: i32, operation: i32) -> i32;
    }
    // SAFETY: `file` owns a live descriptor for the duration of this call.
    if unsafe { flock(file.as_raw_fd(), 2 | 4) } == 0 {
        Ok(())
    } else {
        let error = io::Error::last_os_error();
        if error.kind() == io::ErrorKind::WouldBlock {
            Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "Runtime repair is already active",
            ))
        } else {
            Err(error)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn image(body: &[u8]) -> Vec<u8> {
        let mut bytes = b"hsqs".to_vec();
        bytes.extend_from_slice(body);
        bytes
    }

    fn metadata(name: &str, arch: &str, image: &[u8]) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({
            "utils": {
                "arbitrary-key": {
                    "runtime_name": format!("{name}.squashfs"),
                    "runtime_arch": arch,
                    "size": image.len(),
                    "md5": format!("{:x}", md5::compute(image)),
                    "url": format!("{OFFICIAL_PREFIX}test/{name}.squashfs")
                }
            }
        }))
        .unwrap()
    }

    fn request(temp: &tempfile::TempDir, image: &[u8]) -> RuntimeRepairRequest {
        RuntimeRepairRequest {
            metadata: metadata("godot", "aarch64", image),
            runtime_names: vec!["godot".to_owned()],
            arch: "aarch64".to_owned(),
            libs_root: temp.path().join("libs"),
            progress_file: temp.path().join("state/progress.tsv"),
            cancel_file: Some(temp.path().join("state/cancel")),
            cancel_token: None,
            progress_channel: None,
        }
    }

    #[test]
    fn parses_only_canonical_official_runtime_entries() {
        let payload = image(b"runtime");
        let parsed = RuntimeMetadata::parse(&metadata("godot", "aarch64", &payload)).unwrap();
        let entry = parsed.get("godot", "aarch64").unwrap();
        assert_eq!(entry.size, payload.len() as u64);
        assert_eq!(entry.url, format!("{OFFICIAL_PREFIX}test/godot.squashfs"));

        let malicious = metadata("godot", "aarch64", &payload)
            .into_iter()
            .collect::<Vec<_>>();
        let mut value: serde_json::Value = serde_json::from_slice(&malicious).unwrap();
        value["utils"]["arbitrary-key"]["url"] =
            serde_json::json!("https://example.com/godot.squashfs");
        assert!(RuntimeMetadata::parse(&serde_json::to_vec(&value).unwrap()).is_err());
    }

    #[test]
    fn renders_runtime_metadata_as_stable_tsv() {
        let payload = image(b"runtime");
        let parsed = RuntimeMetadata::parse(&metadata("godot", "aarch64", &payload)).unwrap();
        assert_eq!(
            parsed.to_tsv(),
            format!(
                "godot\taarch64\t{}\t{:x}\t{OFFICIAL_PREFIX}test/godot.squashfs\n",
                payload.len(),
                md5::compute(&payload)
            )
        );
    }

    #[test]
    fn successful_repair_validates_then_atomically_replaces_old_runtime() {
        let temp = tempfile::tempdir().unwrap();
        let payload = image(b"new-runtime");
        let mut request = request(&temp, &payload);
        let progress_channel = ProgressChannel::default();
        request.progress_channel = Some(progress_channel.clone());
        fs::create_dir_all(&request.libs_root).unwrap();
        let target = request.libs_root.join("godot.squashfs");
        fs::write(&target, b"old-runtime").unwrap();

        let result = repair_with_fetcher(&request, |entry, output, progress| {
            assert_eq!(entry.url, format!("{OFFICIAL_PREFIX}test/godot.squashfs"));
            fs::write(output, &payload)?;
            progress.update(payload.len() as u64, payload.len() as u64)?;
            Ok("origin".to_owned())
        })
        .unwrap();

        assert_eq!(fs::read(target).unwrap(), payload);
        assert_eq!(result.runtimes[0].source, RuntimeRepairSource::Network);
        assert_eq!(result.runtimes[0].route_id.as_deref(), Some("origin"));
        let progress = fs::read_to_string(&request.progress_file).unwrap();
        assert!(progress.starts_with("1\tcomplete\t\t1\t1\t"));
        assert_eq!(progress_channel.take().unwrap().phase, "complete");
    }

    #[test]
    fn invalid_download_and_cancellation_preserve_old_runtime() {
        let temp = tempfile::tempdir().unwrap();
        let payload = image(b"expected");
        let request = request(&temp, &payload);
        fs::create_dir_all(&request.libs_root).unwrap();
        let target = request.libs_root.join("godot.squashfs");
        fs::write(&target, b"old-runtime").unwrap();
        let error = repair_with_fetcher(&request, |_entry, output, _progress| {
            fs::write(output, b"hsqswrong")?;
            Ok("origin".to_owned())
        })
        .unwrap_err();
        assert!(matches!(error, RuntimeRepairError::Validation(_)));
        assert_eq!(fs::read(&target).unwrap(), b"old-runtime");

        fs::create_dir_all(request.progress_file.parent().unwrap()).unwrap();
        fs::write(request.cancel_file.as_ref().unwrap(), b"cancel").unwrap();
        let error = repair_with_fetcher(&request, |_entry, _output, _progress| {
            panic!("cancelled repair must not download")
        })
        .unwrap_err();
        assert!(matches!(error, RuntimeRepairError::Cancelled));
        assert_eq!(fs::read(target).unwrap(), b"old-runtime");
        assert!(
            fs::read_to_string(&request.progress_file)
                .unwrap()
                .starts_with("1\tcancelled\t")
        );
    }

    #[test]
    fn live_download_progress_observes_mid_transfer_cancellation() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("state/progress.tsv");
        let writer = ProgressWriter::new(&path, 1, 16, None).unwrap();
        let cancel = temp.path().join("state/cancel");
        let progress = RuntimeDownloadProgress::new(&writer, Some(&cancel), None, "godot", 1, 4);
        progress.update(3, 12).unwrap();
        let row = fs::read_to_string(&path).unwrap();
        assert_eq!(row.split('\t').nth(5), Some("7"));
        fs::write(&cancel, b"cancel").unwrap();
        assert_eq!(
            progress.update(4, 12).unwrap_err().kind(),
            io::ErrorKind::Interrupted
        );
    }

    #[cfg(unix)]
    #[test]
    fn progress_temp_symlink_is_rejected_without_touching_target() {
        use std::os::unix::fs::symlink;

        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("state/progress.tsv");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let victim = temp.path().join("victim");
        fs::write(&victim, b"keep").unwrap();
        let progress_temp = suffixed_path(&path, &format!(".tmp.{}", std::process::id()));
        symlink(&victim, progress_temp).unwrap();
        let writer = ProgressWriter::new(&path, 1, 8, None).unwrap();
        assert!(writer.write("preparing", "", 0, 0, "test").is_err());
        assert_eq!(fs::read(victim).unwrap(), b"keep");
    }

    #[test]
    fn progress_writer_excludes_concurrent_repairs_without_stale_poisoning() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("state/progress.tsv");
        let first = ProgressWriter::new(&path, 1, 8, None).unwrap();
        let Err(error) = ProgressWriter::new(&path, 1, 8, None) else {
            panic!("a concurrent progress writer must be rejected")
        };
        assert!(
            matches!(error, RuntimeRepairError::Io(ref error) if error.kind() == io::ErrorKind::WouldBlock)
        );
        drop(first);
        drop(ProgressWriter::new(&path, 1, 8, None).unwrap());
    }
}
