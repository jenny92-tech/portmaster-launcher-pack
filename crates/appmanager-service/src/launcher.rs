use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::env;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use appmanager_core::{
    FileAction, FileActionKind, FileApplyOutcome, FileApplyRequest, Inventory, InventoryOptions,
    ManagementMode, PROTECTED_DIR_NAMES, PROTECTED_SCRIPT_NAMES, RuntimeMetadata,
    RuntimeRepairRequest, SCAN_EXCLUDED_DIR_NAMES, apply_file_actions as apply_typed_file_actions,
    repair_runtimes,
};
use portkit_core::github::{Capability, GitHubTransport};
use portkit_core::{
    DigestAlgorithm, HealthReport, HealthStatus, digest_file, evaluate_health, zip_readable,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use crate::resolution::{ConfigDirectories, DeviceResolution};

mod support;
use support::*;

const PORT_NAME: &str = "jenny92-appmanager";
const CONFIG_REFRESH_SUCCESS_TTL_SECONDS: u64 = 24 * 60 * 60;
const CONFIG_REFRESH_ERROR_TTL_SECONDS: u64 = 6 * 60 * 60;
const CONFIG_REFRESH_TIMEOUT_SECONDS: u64 = 5;

/// Mirror of the library group contract used by the installer's
/// ExportLibraryGroup transform. Read-only probing shares the same rule.
#[derive(Debug, Deserialize)]
struct LibraryGroupProbe {
    candidates: Vec<PathBuf>,
    required_sonames: Vec<String>,
}

/// Append one line to the APP's log file (used from task threads).
fn append_task_log(path: &std::path::Path, message: &str) {
    if let Ok(mut file) = fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "[PAM] {message}");
    }
}

fn probe_device_path(candidate: &Path, root: Option<&Path>) -> PathBuf {
    match root {
        Some(root) if candidate.is_absolute() => {
            root.join(candidate.strip_prefix("/").unwrap_or(candidate))
        }
        _ => candidate.to_path_buf(),
    }
}

// Keep a corrupt or unbounded proxy response from filling the SD card. The
// installer independently enforces the same 512 MiB ceiling after extraction.
const PORTMASTER_ARCHIVE_MAX_BYTES: u64 = 512 * 1024 * 1024;

#[derive(Clone)]
pub(crate) struct Request {
    pub source_dir: PathBuf,
    pub launcher: PathBuf,
    pub app_root: PathBuf,
    pub config_directories: ConfigDirectories,
    pub cancel_token: Option<appmanager_core::CancellationToken>,
    pub progress_channel: Option<appmanager_core::ProgressChannel>,
}

/// Paths needed by the APP Manager UI process. The embedded service resolves
/// device policy itself; LOVE-lite does not invoke a shell or helper process.
#[derive(Clone, Debug)]
pub struct EmbeddedRequest {
    pub source_dir: PathBuf,
    pub launcher: PathBuf,
    pub app_root: PathBuf,
    pub config_dir: Option<PathBuf>,
    pub remote_config_dir: Option<PathBuf>,
}

pub struct EmbeddedBootstrap {
    request: EmbeddedRequest,
    resolved: Arc<DeviceResolution>,
    environment: BTreeMap<String, String>,
}

impl EmbeddedBootstrap {
    pub fn environment(&self) -> &BTreeMap<String, String> {
        &self.environment
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct ServiceEvent {
    pub task_id: u64,
    pub kind: String,
    pub status: String,
    pub data: Value,
}

#[derive(Clone)]
pub struct EmbeddedService {
    request: Request,
    resolved: Arc<DeviceResolution>,
    health: SharedHealth,
    events: Arc<Mutex<VecDeque<ServiceEvent>>>,
    snapshot: Arc<Mutex<Option<Value>>>,
    next_task: Arc<AtomicU64>,
    busy: Arc<AtomicBool>,
    background_busy: Arc<AtomicBool>,
    active_task: Arc<AtomicU64>,
    input_helper: Arc<Mutex<Option<Child>>>,
    cancel_token: appmanager_core::CancellationToken,
    progress_channel: appmanager_core::ProgressChannel,
    web_server: Arc<Mutex<Option<WebServerTask>>>,
}

struct WebServerTask {
    endpoint: crate::web::WebEndpoint,
    stop: Arc<AtomicBool>,
    thread: std::thread::JoinHandle<Result<u16, String>>,
}

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EmbeddedAction {
    pub kind: String,
    pub arg: String,
    #[serde(default)]
    pub source_identity: Option<String>,
    #[serde(default)]
    pub replace_existing: bool,
    /// Ephemeral archive password. It is accepted only by INSTALL_ZIP,
    /// redacted from Debug output, never serialized, and zeroized on drop.
    #[serde(default)]
    pub password: Option<String>,
}

impl std::fmt::Debug for EmbeddedAction {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("EmbeddedAction")
            .field("kind", &self.kind)
            .field("arg", &self.arg)
            .field("source_identity", &self.source_identity)
            .field("replace_existing", &self.replace_existing)
            .field("password", &self.password.as_ref().map(|_| "[REDACTED]"))
            .finish()
    }
}

impl Drop for EmbeddedAction {
    fn drop(&mut self) {
        use zeroize::Zeroize;
        self.password.zeroize();
    }
}

#[derive(Debug)]
pub(crate) struct Paths {
    source_dir: PathBuf,
    launcher: PathBuf,
    pub(crate) app_root: PathBuf,
    bin_dir: PathBuf,
    share_dir: PathBuf,
    config_dir: PathBuf,
    state: PathBuf,
    trash: PathBuf,
    update_cache: PathBuf,
    portmaster_lock: PathBuf,
    operation_lock: PathBuf,
    runtime_metadata_json: PathBuf,
    config_refresh_cache: PathBuf,
    remote_config_dir: PathBuf,
    remote_config: PathBuf,
    inventory: PathBuf,
}

impl Paths {
    fn new(request: &Request) -> Self {
        let state =
            env_path("PAM_STATE_DIR_OVERRIDE").unwrap_or_else(|| request.app_root.join("state"));
        let remote_config_dir = state.join("device-config");
        Self {
            source_dir: request.source_dir.clone(),
            launcher: env_path("PAM_NATIVE_LAUNCHER_OVERRIDE")
                .unwrap_or_else(|| request.launcher.clone()),
            app_root: request.app_root.clone(),
            bin_dir: request.app_root.join("bin"),
            share_dir: request.app_root.join("share"),
            config_dir: request.app_root.join("config"),
            trash: request.app_root.join("trash"),
            update_cache: state.join("portmaster-update.tsv"),
            portmaster_lock: state.join("portmaster.lock"),
            operation_lock: state.join("operation.lock"),
            runtime_metadata_json: state.join("ports.json"),
            config_refresh_cache: state.join("device-config-refresh.tsv"),
            remote_config: remote_config_dir.join("config.json"),
            inventory: state.join("inventory.json"),
            remote_config_dir,
            state,
        }
    }
}

#[derive(Clone, Debug)]
struct ReleaseSource {
    manifest_url: String,
    archive_name: String,
    install_allowed: bool,
}

pub(crate) struct Session {
    pub(crate) paths: Paths,
    resolved: Arc<DeviceResolution>,
    root: Option<PathBuf>,
    cancel_token: Option<appmanager_core::CancellationToken>,
    progress_channel: Option<appmanager_core::ProgressChannel>,
    config_refresh_status: Option<String>,
    health: SharedHealth,
}

#[derive(Clone)]
pub(crate) struct HealthFacts {
    status: &'static str,
    report: Option<HealthReport>,
    python_ok: bool,
    system_python_ok: bool,
    python_imports: String,
}

pub(crate) type SharedHealth = Arc<Mutex<Option<HealthFacts>>>;
type BackgroundRunner =
    fn(&Request, &Arc<DeviceResolution>, &SharedHealth) -> Result<Value, (String, Value)>;

pub(crate) fn empty_inventory() -> appmanager_core::Inventory {
    use appmanager_core::RuntimeInventory;
    appmanager_core::Inventory {
        schema: appmanager_core::INVENTORY_SCHEMA,
        entries: Vec::new(),
        ports: Vec::new(),
        data_refcount: Default::default(),
        data_dirs: Vec::new(),
        images: Vec::new(),
        orphan_dirs: Vec::new(),
        orphan_images: Vec::new(),
        dead_scripts: Vec::new(),
        trash: Vec::new(),
        runtimes: RuntimeInventory {
            need: Default::default(),
            facts: Vec::new(),
        },
        apps: Vec::new(),
        diagnostics: Vec::new(),
        classification_uncertain: false,
    }
}

fn inventory_available(_management: &ManagementMode, _health: &str) -> bool {
    // Game management (list / uninstall / leftover cleanup) only needs the
    // ports directory layout, never a working PortMaster core. Do not gate it
    // on core health: uninstalling and cleaning up images must keep working
    // even when the PortMaster environment is missing or damaged.
    true
}

fn configured_directories(request: &Request, paths: &Paths) -> ConfigDirectories {
    let mut directories = request.config_directories.clone();
    directories
        .embedded
        .get_or_insert_with(|| paths.config_dir.clone());
    directories
        .remote
        .get_or_insert_with(|| paths.remote_config_dir.clone());
    directories
}

impl EmbeddedService {
    fn request(
        request: &EmbeddedRequest,
        cancel_token: Option<appmanager_core::CancellationToken>,
        progress_channel: Option<appmanager_core::ProgressChannel>,
    ) -> Request {
        Request {
            source_dir: request.source_dir.clone(),
            launcher: request.launcher.clone(),
            app_root: request.app_root.clone(),
            config_directories: ConfigDirectories {
                embedded: request.config_dir.clone(),
                remote: request.remote_config_dir.clone(),
            },
            cancel_token,
            progress_channel,
        }
    }

    /// Resolves only the process environment required to create the UI.
    ///
    /// This intentionally skips cleanup, artwork synchronization, diagnostics,
    /// inventory and PortMaster health work so SDL can present a window first.
    pub fn prepare(request: EmbeddedRequest) -> Result<EmbeddedBootstrap, String> {
        let session = Session::new(Self::request(&request, None, None))?;
        let environment = session.love_environment()?;
        Ok(EmbeddedBootstrap {
            request,
            resolved: session.resolved,
            environment,
        })
    }

    pub fn new(request: EmbeddedRequest) -> Result<Self, String> {
        Self::activate(Self::prepare(request)?)
    }

    pub fn activate(bootstrap: EmbeddedBootstrap) -> Result<Self, String> {
        let cancel_token = appmanager_core::CancellationToken::default();
        let progress_channel = appmanager_core::ProgressChannel::default();
        let request = Self::request(
            &bootstrap.request,
            Some(cancel_token.clone()),
            Some(progress_channel.clone()),
        );
        let resolved = bootstrap.resolved;
        let health = Arc::new(Mutex::new(None));
        let session = Session::new_pinned_without_recovery(
            request.clone(),
            Arc::clone(&resolved),
            Arc::clone(&health),
        )?;
        session.sync_artwork();
        session.write_startup_diagnostics();
        Ok(Self {
            request,
            resolved,
            health,
            events: Arc::new(Mutex::new(VecDeque::new())),
            snapshot: Arc::new(Mutex::new(None)),
            next_task: Arc::new(AtomicU64::new(1)),
            busy: Arc::new(AtomicBool::new(false)),
            background_busy: Arc::new(AtomicBool::new(false)),
            active_task: Arc::new(AtomicU64::new(0)),
            input_helper: Arc::new(Mutex::new(None)),
            cancel_token,
            progress_channel,
            web_server: Arc::new(Mutex::new(None)),
        })
    }

    /// Serve the LAN admin UI on a worker thread until the web switch is turned
    /// off. The APP must remain open while remote management is in use.
    pub fn enable_web(&self) -> Result<crate::web::WebEndpoint, String> {
        self.reap_finished_web_server();
        if let Some(task) = self
            .web_server
            .lock()
            .unwrap_or_else(|value| value.into_inner())
            .as_ref()
        {
            return Ok(task.endpoint.clone());
        }
        let prepared = crate::web::prepare_server().map_err(|message| {
            append_task_log(
                &self.request.app_root.join("log.txt"),
                &format!("web.enable FAILED: {message}"),
            );
            message
        })?;
        let endpoint = prepared.endpoint.clone();
        append_task_log(
            &self.request.app_root.join("log.txt"),
            &format!("web.enable port={}", endpoint.port),
        );
        let stop = Arc::new(AtomicBool::new(false));
        let request = self.request.clone();
        let resolved = Arc::clone(&self.resolved);
        let health = Arc::clone(&self.health);
        let server_stop = Arc::clone(&stop);
        let thread = std::thread::Builder::new()
            .name("appmanager-web".to_owned())
            .spawn(move || {
                crate::web::serve_prepared(request, resolved, health, prepared, server_stop)
            })
            .map_err(|error| format!("cannot start web server: {error}"))?;
        *self
            .web_server
            .lock()
            .unwrap_or_else(|value| value.into_inner()) = Some(WebServerTask {
            endpoint: endpoint.clone(),
            stop,
            thread,
        });
        append_task_log(
            &self.request.app_root.join("log.txt"),
            &format!("web.enable OK port={}", endpoint.port),
        );
        Ok(endpoint)
    }

    /// Turn the web switch off; the serving loop exits on its next poll.
    pub fn disable_web(&self) -> Result<(), String> {
        append_task_log(&self.request.app_root.join("log.txt"), "web.disable");
        let task = self
            .web_server
            .lock()
            .unwrap_or_else(|value| value.into_inner())
            .take();
        let Some(task) = task else {
            return Ok(());
        };
        task.stop.store(true, Ordering::Release);
        match task.thread.join() {
            Ok(Ok(_)) => Ok(()),
            Ok(Err(message)) => Err(message),
            Err(_) => Err("web server panicked during shutdown".to_owned()),
        }
    }

    /// In-APP web switch: returns the bound port and pairing code after the
    /// worker has bound its listener and generated the pairing code.
    pub fn web_set(&self, enabled: bool) -> Result<crate::web::WebEndpoint, String> {
        if enabled {
            self.enable_web()
        } else {
            self.disable_web()?;
            Ok(crate::web::WebEndpoint {
                port: 0,
                code: String::new(),
            })
        }
    }

    /// Whether the web switch is currently on.
    pub fn web_on(&self) -> bool {
        self.reap_finished_web_server();
        self.web_server
            .lock()
            .unwrap_or_else(|value| value.into_inner())
            .is_some()
    }

    fn reap_finished_web_server(&self) {
        let mut server = self
            .web_server
            .lock()
            .unwrap_or_else(|value| value.into_inner());
        let finished = server
            .as_ref()
            .is_some_and(|task| task.thread.is_finished());
        if finished && let Some(task) = server.take() {
            let _ = task.thread.join();
        }
    }

    pub fn start_input_helper(&self, process_name: &str) -> Result<(), String> {
        let helper = self.request.app_root.join("bin/gptokeyb");
        if !helper.is_file() {
            return Err(format!(
                "controller input helper is missing: {}",
                helper.display()
            ));
        }
        let mut words = env::var("ESUDO")
            .unwrap_or_default()
            .split_whitespace()
            .map(str::to_owned)
            .collect::<Vec<_>>();
        let mut command = if words.is_empty() {
            Command::new(&helper)
        } else {
            let mut command = Command::new(words.remove(0));
            command.args(words).arg(&helper);
            command
        };
        let mut child = command
            .arg(process_name)
            .arg("-c")
            .arg(self.request.app_root.join("love_ui/ui.gptk"))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()
            .map_err(|error| format!("controller input helper could not start: {error}"))?;
        std::thread::sleep(Duration::from_millis(25));
        if let Some(status) = child
            .try_wait()
            .map_err(|error| format!("controller input helper status failed: {error}"))?
        {
            return Err(format!(
                "controller input helper exited during startup: {status}"
            ));
        }
        *self
            .input_helper
            .lock()
            .unwrap_or_else(|value| value.into_inner()) = Some(child);
        Ok(())
    }

    pub fn stop_input_helper(&self) {
        if let Some(mut child) = self
            .input_helper
            .lock()
            .unwrap_or_else(|value| value.into_inner())
            .take()
        {
            let _ = child.kill();
            let _ = child.wait();
        }
    }

    pub fn snapshot(&self) -> Result<Value, String> {
        if let Some(snapshot) = self
            .snapshot
            .lock()
            .unwrap_or_else(|value| value.into_inner())
            .clone()
        {
            return Ok(snapshot);
        }
        let session = Session::new_pinned_without_recovery(
            self.request.clone(),
            Arc::clone(&self.resolved),
            Arc::clone(&self.health),
        )?;
        let snapshot = session.embedded_snapshot(None)?;
        session.write_snapshot_diagnostics(&snapshot);
        *self
            .snapshot
            .lock()
            .unwrap_or_else(|value| value.into_inner()) = Some(snapshot.clone());
        Ok(snapshot)
    }

    pub fn start(&self, kind: &str, actions: Option<Vec<EmbeddedAction>>) -> Result<u64, String> {
        self.start_at_revision(kind, actions, None)
    }

    pub fn start_at_revision(
        &self,
        kind: &str,
        actions: Option<Vec<EmbeddedAction>>,
        expected_revision: Option<String>,
    ) -> Result<u64, String> {
        if kind == "config-refresh-if-newer" {
            if actions.is_some() || expected_revision.is_some() {
                return Err(format!("task {kind:?} does not accept a payload"));
            }
            return self.start_background_config_refresh();
        }
        if kind == "update-check-if-stale" {
            if actions.is_some() || expected_revision.is_some() {
                return Err(format!("task {kind:?} does not accept a payload"));
            }
            return self.start_background_update_check();
        }
        if let Some(actions) = actions.as_deref()
            && actions.iter().any(|action| {
                action.password.as_ref().is_some_and(|password| {
                    kind != "install-zips" || action.kind != "INSTALL_ZIP" || password.len() > 1024
                })
            })
        {
            return Err(
                "archive passwords are accepted only by INSTALL_ZIP and must be at most 1024 bytes"
                    .into(),
            );
        }
        if kind == "update-check" && self.background_busy.load(Ordering::Acquire) {
            return Err("the automatic PortMaster update check is already running".into());
        }
        if self
            .busy
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err("another APP Manager task is already running".into());
        }
        let task_id = self.next_task.fetch_add(1, Ordering::Relaxed);
        let kind = kind.to_owned();
        let actions = if matches!(kind.as_str(), "apply" | "install-zips") {
            let actions = actions.unwrap_or_default();
            if actions.is_empty() {
                self.busy.store(false, Ordering::Release);
                return Err("APP Manager action list is empty".into());
            }
            Some(actions)
        } else {
            if actions.is_some() || expected_revision.is_some() {
                self.busy.store(false, Ordering::Release);
                return Err(format!("task {kind:?} does not accept a payload"));
            }
            None
        };
        let supported = matches!(
            kind.as_str(),
            "initial-snapshot"
                | "apply"
                | "update-check"
                | "inventory-refresh"
                | "scan-zips"
                | "install-zips"
        );
        if !supported {
            self.busy.store(false, Ordering::Release);
            return Err(format!("unsupported APP Manager task {kind:?}"));
        }
        if kind == "apply"
            && expected_revision.as_deref().is_none_or(|revision| {
                revision.len() != 64 || !revision.bytes().all(|byte| byte.is_ascii_hexdigit())
            })
        {
            self.busy.store(false, Ordering::Release);
            return Err("apply requires a current inventory revision".into());
        }
        if kind != "apply" && expected_revision.is_some() {
            self.busy.store(false, Ordering::Release);
            return Err(format!(
                "task {kind:?} does not accept an inventory revision"
            ));
        }
        self.active_task.store(task_id, Ordering::Release);
        let request = self.request.clone();
        let resolved = Arc::clone(&self.resolved);
        let health = Arc::clone(&self.health);
        let events = Arc::clone(&self.events);
        let snapshot = Arc::clone(&self.snapshot);
        let busy = Arc::clone(&self.busy);
        let active_task = Arc::clone(&self.active_task);
        let log_path = self.request.app_root.join("log.txt");
        let started_at = std::time::Instant::now();
        self.cancel_token.reset();
        self.progress_channel.clear();
        append_task_log(&log_path, &format!("task.start kind={kind} id={task_id}"));
        std::thread::Builder::new()
            .name(format!("appmanager-{kind}"))
            .spawn(move || {
                let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    run_embedded_task(
                        &request,
                        &resolved,
                        &health,
                        &kind,
                        actions.as_deref(),
                        expected_revision.as_deref(),
                        &snapshot,
                    )
                }))
                .unwrap_or_else(|_| Err("APP Manager task stopped unexpectedly".into()));
                let event = match outcome {
                    Ok(data) => ServiceEvent {
                        task_id,
                        kind,
                        status: "complete".into(),
                        data,
                    },
                    Err(message) => {
                        // A failed task may have already changed the disk;
                        // run_embedded_task refreshed the shared snapshot, so
                        // the UI can re-render reality instead of a stale view.
                        let current = snapshot
                            .lock()
                            .unwrap_or_else(|value| value.into_inner())
                            .clone()
                            .unwrap_or(Value::Null);
                        ServiceEvent {
                            task_id,
                            kind,
                            status: "error".into(),
                            data: json!({"message": message, "snapshot": current}),
                        }
                    }
                };
                let mut events = events.lock().unwrap_or_else(|value| value.into_inner());
                // Publish completion only after releasing the task lane. A
                // consumer may start its next queued task immediately after
                // observing this event.
                active_task.store(0, Ordering::Release);
                busy.store(false, Ordering::Release);
                let elapsed = started_at.elapsed().as_secs();
                append_task_log(
                    &log_path,
                    &format!(
                        "task.end kind={} id={task_id} status={} elapsed={elapsed}s",
                        event.kind, event.status
                    ),
                );
                events.push_back(event);
            })
            .map_err(|error| {
                self.active_task.store(0, Ordering::Release);
                self.busy.store(false, Ordering::Release);
                error.to_string()
            })?;
        Ok(task_id)
    }

    fn start_background_update_check(&self) -> Result<u64, String> {
        self.start_background_task(
            "update-check-if-stale",
            "appmanager-update-check-background",
            "the automatic PortMaster update check is already running",
            "PortMaster update check stopped unexpectedly",
            "update",
            run_background_update_check,
        )
    }

    fn start_background_config_refresh(&self) -> Result<u64, String> {
        self.start_background_task(
            "config-refresh-if-newer",
            "appmanager-config-refresh-background",
            "an APP Manager background task is already running",
            "device information refresh stopped unexpectedly",
            "config_refresh",
            run_background_config_refresh,
        )
    }

    fn start_background_task(
        &self,
        kind: &'static str,
        thread_name: &'static str,
        busy_message: &'static str,
        panic_message: &'static str,
        error_field: &'static str,
        runner: BackgroundRunner,
    ) -> Result<u64, String> {
        if self
            .background_busy
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err(busy_message.into());
        }
        let task_id = self.next_task.fetch_add(1, Ordering::Relaxed);
        let request = self.request.clone();
        let resolved = Arc::clone(&self.resolved);
        let health = Arc::clone(&self.health);
        let events = Arc::clone(&self.events);
        let background_busy = Arc::clone(&self.background_busy);
        let log_path = self.request.app_root.join("log.txt");
        let started_at = std::time::Instant::now();
        append_task_log(
            &log_path,
            &format!("task.start kind={kind} id={task_id} background=1"),
        );
        std::thread::Builder::new()
            .name(thread_name.into())
            .spawn(move || {
                let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    runner(&request, &resolved, &health)
                }))
                .unwrap_or_else(|_| Err((panic_message.into(), json!({}))));
                let event = match outcome {
                    Ok(data) => ServiceEvent {
                        task_id,
                        kind: kind.into(),
                        status: "complete".into(),
                        data,
                    },
                    Err((message, details)) => {
                        let mut data = serde_json::Map::new();
                        data.insert("message".into(), Value::String(message));
                        data.insert(error_field.into(), details);
                        ServiceEvent {
                            task_id,
                            kind: kind.into(),
                            status: "error".into(),
                            data: Value::Object(data),
                        }
                    }
                };
                let mut events = events.lock().unwrap_or_else(|value| value.into_inner());
                // An event is the public completion boundary: once visible,
                // the next background request must be able to acquire this lane.
                background_busy.store(false, Ordering::Release);
                let elapsed = started_at.elapsed().as_secs();
                append_task_log(
                    &log_path,
                    &format!(
                        "task.end kind={} id={task_id} status={} elapsed={elapsed}s",
                        event.kind, event.status
                    ),
                );
                events.push_back(event);
            })
            .map_err(|error| {
                self.background_busy.store(false, Ordering::Release);
                error.to_string()
            })?;
        Ok(task_id)
    }

    pub fn poll(&self) -> Option<ServiceEvent> {
        if let Some(event) = self
            .events
            .lock()
            .unwrap_or_else(|value| value.into_inner())
            .pop_front()
        {
            return Some(event);
        }
        if !self.busy.load(Ordering::Acquire) {
            return None;
        }
        let task_id = self.active_task.load(Ordering::Acquire);
        if task_id == 0 {
            return None;
        }
        if let Some(progress) = self.progress_channel.take() {
            return Some(ServiceEvent {
                task_id,
                kind: "progress".into(),
                status: "progress".into(),
                data: serde_json::to_value(progress).unwrap_or_else(|_| json!({})),
            });
        }
        None
    }

    /// Validate a current inventory launcher and publish a shell handoff.
    /// The frontend-owned launcher consumes it only after SDL has exited.
    pub fn run_script(&self, path: String) -> Result<(), String> {
        use std::os::unix::fs::{MetadataExt, OpenOptionsExt};

        let script = PathBuf::from(&path);
        let handoff = self.request.app_root.join("game_to_launch.txt");
        let fingerprint = self.request.app_root.join("game_to_launch.fingerprint");
        let xdg_data_home = self.request.app_root.join("game_to_launch.xdg_data_home");
        let _ = fs::remove_file(&handoff);
        let _ = fs::remove_file(&fingerprint);
        let _ = fs::remove_file(&xdg_data_home);
        let file = fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&script)
            .map_err(|error| format!("cannot open launcher script {path}: {error}"))?;
        let metadata = file.metadata().map_err(display_error)?;
        if !metadata.file_type().is_file() {
            return Err(format!("launcher script not found: {path}"));
        }
        let inventory = Inventory::scan(&self.resolved.context).map_err(display_error)?;
        if !inventory.ports.iter().any(|port| port.path == script)
            && !inventory.apps.iter().any(|app| app.launch == script)
        {
            return Err("launcher is not a current managed inventory item".to_owned());
        }
        let identity = format!("{}:{}\n", metadata.dev(), metadata.ino());
        let write_atomic = |target: &Path, bytes: &[u8]| -> Result<(), String> {
            let temporary = target.with_extension(format!(
                "handoff-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|duration| duration.as_nanos())
                    .unwrap_or(0)
            ));
            let mut output = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&temporary)
                .map_err(display_error)?;
            output.write_all(bytes).map_err(display_error)?;
            output.sync_all().map_err(display_error)?;
            fs::rename(&temporary, target).map_err(display_error)
        };
        // A normal device frontend supplies the PortMaster base directory to
        // launchers through XDG_DATA_HOME. APP Manager is itself a Port, so its
        // child otherwise inherits the APP's environment instead of the
        // frontend's launch environment. Derive the same value from the
        // resolved Config root; this covers both old and new filesystem
        // layouts without teaching individual game scripts about devices.
        if let Some(value) = portmaster_xdg_data_home(
            self.resolved.context.roots.portmaster.as_deref(),
            Some(&self.resolved.context.roots.scripts),
        ) {
            let value = value
                .to_str()
                .ok_or_else(|| "PortMaster launch environment is not UTF-8".to_owned())?;
            write_atomic(&xdg_data_home, value.as_bytes())?;
        }
        // Environment and fingerprint first; publishing the path is the
        // handoff commit point.
        write_atomic(&fingerprint, identity.as_bytes())?;
        if let Err(error) = write_atomic(&handoff, path.as_bytes()) {
            let _ = fs::remove_file(&fingerprint);
            let _ = fs::remove_file(&xdg_data_home);
            return Err(error);
        }
        append_task_log(
            &self.request.app_root.join("log.txt"),
            &format!(
                "launch_handoff platform_id={} path={path} identity={}",
                self.resolved.resolution.platform_id,
                identity.trim()
            ),
        );
        Ok(())
    }

    pub fn cancel(&self) -> Result<(), String> {
        append_task_log(
            &self.request.app_root.join("log.txt"),
            &format!(
                "task.cancel id={}",
                self.active_task.load(Ordering::Acquire)
            ),
        );
        if !self.busy.load(Ordering::Acquire) {
            return Ok(());
        }
        self.cancel_token.cancel();
        Ok(())
    }
}

fn portmaster_xdg_data_home(root: Option<&Path>, scripts: Option<&Path>) -> Option<PathBuf> {
    let root = root?;
    if root.file_name()? == "PortMaster" {
        return root.parent().map(Path::to_path_buf);
    }
    // canonicalize_existing may resolve a configured `.../PortMaster`
    // symlink to a target with another basename. In that layout the frontend
    // entry remains beside the Port launchers, so their resolved scripts root
    // is the correct XDG base. The shell verifies PortMaster/control.txt
    // below it before exporting the value.
    scripts.map(Path::to_path_buf)
}

fn update_cache_value(path: &Path) -> Value {
    let (checked, status, latest) = read_update_cache(path);
    json!({
        "update_checked": checked,
        "update_status": status,
        "portmaster_latest": latest,
    })
}

fn epoch_seconds() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn fresh_config_refresh_status(path: &Path, now: u64) -> Option<&'static str> {
    let value = fs::read_to_string(path).ok()?;
    let mut fields = value.trim().split('\t');
    let checked = fields.next()?.parse::<u64>().ok()?;
    let status = fields.next()?;
    if fields.next().is_some() {
        return None;
    }
    let age = now.checked_sub(checked)?;
    match status {
        "ok" if age < CONFIG_REFRESH_SUCCESS_TTL_SECONDS => Some("cached"),
        "error" if age < CONFIG_REFRESH_ERROR_TTL_SECONDS => Some("cached_error"),
        _ => None,
    }
}

fn write_config_refresh_status(path: &Path, status: &str) {
    let value = format!("{}\t{status}\n", epoch_seconds());
    let _ = portkit_core::atomic_write(path, value.as_bytes());
}

fn run_background_update_check(
    request: &Request,
    resolved: &Arc<DeviceResolution>,
    health: &SharedHealth,
) -> Result<Value, (String, Value)> {
    let session = Session::new_pinned_without_recovery(
        request.clone(),
        Arc::clone(resolved),
        Arc::clone(health),
    )
    .map_err(|message| (message, json!({})))?;
    match session.check_update(false) {
        Ok(_) => Ok(json!({"update": update_cache_value(&session.paths.update_cache)})),
        Err(message) => Err((message, update_cache_value(&session.paths.update_cache))),
    }
}

fn run_background_config_refresh(
    request: &Request,
    resolved: &Arc<DeviceResolution>,
    health: &SharedHealth,
) -> Result<Value, (String, Value)> {
    let mut session = Session::new_pinned_without_recovery(
        request.clone(),
        Arc::clone(resolved),
        Arc::clone(health),
    )
    .map_err(|message| (message, json!({})))?;
    match session.refresh_device_config() {
        Ok(_) => {
            let status = session
                .config_refresh_status
                .take()
                .unwrap_or_else(|| "unchanged".into());
            Ok(json!({"config_refresh": {"status": status}}))
        }
        Err(message) => Err((message, json!({"status": "error"}))),
    }
}

fn run_embedded_task(
    request: &Request,
    resolved: &Arc<DeviceResolution>,
    health: &SharedHealth,
    kind: &str,
    actions: Option<&[EmbeddedAction]>,
    expected_revision: Option<&str>,
    cached_snapshot: &Mutex<Option<Value>>,
) -> Result<Value, String> {
    let mut session = if task_needs_recovery(kind) {
        Session::new_pinned(request.clone(), Arc::clone(resolved), Arc::clone(health))?
    } else {
        Session::new_pinned_without_recovery(
            request.clone(),
            Arc::clone(resolved),
            Arc::clone(health),
        )?
    };
    let mut zip_bundles: Option<Vec<appmanager_core::port_zip::ZipCandidate>> = None;
    let mut zip_install: Option<Value> = None;
    let outcome = (|| -> Result<(u8, OperationOutcome), String> {
        match kind {
            "initial-snapshot" => Ok((0, OperationOutcome::default())),
            "apply" => execute_actions_at_revision(
                &mut session,
                actions.unwrap_or_default(),
                expected_revision,
            )
            .map(|outcome| (0, outcome)),
            "update-check" => session
                .check_update(true)
                .map(|code| (code, OperationOutcome::default())),
            "inventory-refresh" => {
                session.refresh_inventory_state()?;
                Ok((0, OperationOutcome::default()))
            }
            "scan-zips" => {
                if !session.capability("install_ports") && !session.capability("install_apps") {
                    return Err("bundle installation is disabled by device configuration".into());
                }
                // Storage discovery is a fixed Linux contract, independent of
                // platform configuration. Cards absent from the mount table
                // are not guessed.
                let roots =
                    appmanager_core::storage::mounted_storage_roots(session.root.as_deref());
                let roots_refs = roots.iter().map(PathBuf::as_path).collect::<Vec<_>>();
                let cancelled = || {
                    session
                        .cancel_token
                        .as_ref()
                        .is_some_and(|token| token.is_cancelled())
                };
                let bundles = appmanager_core::port_zip::scan_zip_bundles(&roots_refs, &cancelled)?;
                zip_bundles = Some(bundles);
                Ok((0, OperationOutcome::default()))
            }
            "install-zips" => {
                let actions = actions.unwrap_or_default();
                if actions.len() > 32 {
                    return Err("too many zip bundles selected".into());
                }
                if actions.iter().any(|action| action.kind != "INSTALL_ZIP") {
                    return Err("invalid zip install task payload".into());
                }
                let guard = ActivityGuard::acquire(&session.paths.operation_lock)?;
                let mut installed_bundles = 0_usize;
                let mut installed_items = 0_usize;
                let mut conflicted_bundles = 0_usize;
                let mut conflicts = 0_usize;
                let mut failures = Vec::new();
                for action in actions {
                    if session.cancelled() {
                        return Err("zip installation cancelled".to_owned());
                    }
                    match session.install_zip_unlocked(
                        &action.arg,
                        true,
                        action.source_identity.as_deref(),
                        action.replace_existing,
                        action.password.as_deref(),
                    ) {
                        Ok(result) => {
                            if result.installed.is_empty() && !result.conflicts.is_empty() {
                                conflicted_bundles += 1;
                            } else if !result.installed.is_empty() {
                                installed_bundles += 1;
                            }
                            installed_items += result.installed.len();
                            conflicts += result.conflicts.len();
                        }
                        Err(message) => {
                            let diagnostic =
                                appmanager_core::port_zip::archive_issue(&action.arg, "", &message);
                            failures.push(json!({
                                "path": action.arg,
                                "message": diagnostic.message(),
                                "diagnostic": diagnostic,
                            }));
                        }
                    }
                }
                zip_install = Some(json!({
                    "selected_bundles": actions.len(),
                    "installed_bundles": installed_bundles,
                    "installed_items": installed_items,
                    "conflicted_bundles": conflicted_bundles,
                    "conflicts": conflicts,
                    "failed_bundles": failures.len(),
                    "failures": failures,
                }));
                drop(guard);
                let roots =
                    appmanager_core::storage::mounted_storage_roots(session.root.as_deref());
                let roots_refs = roots.iter().map(PathBuf::as_path).collect::<Vec<_>>();
                if let Ok(bundles) =
                    appmanager_core::port_zip::scan_zip_bundles(&roots_refs, &|| false)
                {
                    zip_bundles = Some(bundles);
                }
                Ok((0, OperationOutcome::default()))
            }
            _ => Err(format!("unsupported APP Manager task {kind:?}")),
        }
    })();
    if kind == "inventory-refresh" || (kind == "apply" && outcome.is_err()) {
        session.clear_health();
    }
    // Refresh the shared snapshot even when the task failed: mutations may
    // already be on disk, and a stale snapshot invites operating on a world
    // that no longer exists.
    if let Err(task_error) = outcome {
        if let Ok(current) = session.embedded_snapshot(None) {
            *cached_snapshot
                .lock()
                .unwrap_or_else(|value| value.into_inner()) = Some(current);
        }
        return Err(task_error);
    }
    let (code, operation) = outcome.expect("checked above");
    let reuse_inventory = if matches!(kind, "apply" | "inventory-refresh") {
        session.persisted_inventory()
    } else if kind == "update-check" {
        cached_snapshot
            .lock()
            .unwrap_or_else(|value| value.into_inner())
            .as_ref()
            .and_then(|value| value.get("inventory"))
            .cloned()
    } else {
        None
    };
    let snapshot = session.embedded_snapshot(reuse_inventory)?;
    *cached_snapshot
        .lock()
        .unwrap_or_else(|value| value.into_inner()) = Some(snapshot.clone());
    let mut result = json!({
        "code": code,
        "operation": serde_json::to_value(operation).unwrap_or_else(|_| json!({})),
        "snapshot": snapshot,
    });
    if let Some(bundles) = zip_bundles
        && let Ok(value) = serde_json::to_value(bundles)
    {
        result["bundles"] = value;
    }
    if let Some(summary) = zip_install {
        result["zip_install"] = summary;
    }
    Ok(result)
}

fn task_needs_recovery(kind: &str) -> bool {
    matches!(kind, "initial-snapshot" | "apply" | "install-zips")
}

#[derive(Clone, Debug, Default, Serialize)]
struct OperationOutcome {
    failed: bool,
    handled: usize,
    failures: Vec<String>,
    appledouble_removed: usize,
    cancelled: bool,
}

impl From<FileApplyOutcome> for OperationOutcome {
    fn from(value: FileApplyOutcome) -> Self {
        let failures = value
            .results
            .into_iter()
            .filter_map(|result| {
                result
                    .message
                    .map(|message| format!("{}: {message}", result.argument.display()))
            })
            .collect();
        Self {
            failed: value.failures != 0,
            handled: value.handled,
            failures,
            appledouble_removed: value.appledouble_removed,
            cancelled: false,
        }
    }
}

fn local_ip() -> String {
    #[cfg(unix)]
    unsafe {
        let mut ifaddr: *mut libc::ifaddrs = std::ptr::null_mut();
        if libc::getifaddrs(&mut ifaddr) != 0 {
            return String::new();
        }
        let mut result = String::new();
        let mut current = ifaddr;
        while !current.is_null() {
            let addr = (*current).ifa_addr;
            if !addr.is_null() && (*addr).sa_family as i32 == libc::AF_INET {
                let name = std::ffi::CStr::from_ptr((*current).ifa_name)
                    .to_string_lossy()
                    .into_owned();
                if name != "lo" {
                    let sockaddr = addr as *const libc::sockaddr_in;
                    let bytes = (*sockaddr).sin_addr.s_addr.to_ne_bytes();
                    result = format!("{}.{}.{}.{}", bytes[0], bytes[1], bytes[2], bytes[3]);
                    break;
                }
            }
            current = (*current).ifa_next;
        }
        libc::freeifaddrs(ifaddr);
        result
    }
    #[cfg(not(unix))]
    {
        String::new()
    }
}

impl Session {
    pub(crate) fn reserve_operation(&self) -> Result<OperationReservation, String> {
        ActivityGuard::acquire(&self.paths.operation_lock)
            .map(|guard| OperationReservation { _guard: guard })
    }

    /// Install a recognized zip bundle (web upload path). Re-recognizes the
    /// archive, moves pieces to platform destinations, then removes the
    /// transport copy instead of filling Trash with another large archive.
    pub(crate) fn install_zip_reserved(
        &self,
        path: String,
        replace_existing: bool,
        password: Option<&str>,
    ) -> Result<Value, String> {
        let outcome = self.install_zip_unlocked(&path, false, None, replace_existing, password)?;
        serde_json::to_value(outcome).map_err(|error| error.to_string())
    }

    fn install_zip_unlocked(
        &self,
        path: &str,
        retire_source: bool,
        expected_identity: Option<&str>,
        replace_existing: bool,
        password: Option<&str>,
    ) -> Result<appmanager_core::port_zip::BundleInstallOutcome, String> {
        let script_path = PathBuf::from(&path);
        let cancel = || self.cancelled();
        let bundle = appmanager_core::port_zip::inspect_archive_bundle_with_password(
            &script_path,
            password,
            &cancel,
        )?;
        if expected_identity.is_some_and(|expected| expected != bundle.source_identity) {
            return Err("ZIP changed after it was scanned; please scan it again".to_owned());
        }
        require_bundle_capability(&self.resolved.resolution.capabilities, &bundle.kind)?;
        let roots = &self.resolved.context.roots;
        let work = roots.app_state.join("zip-work");
        let app_roots = app_install_targets(&roots.apps);
        if retire_source {
            appmanager_core::port_zip::install_bundle_replacing_with_password(
                &bundle,
                &roots.scripts,
                &roots.game_dirs,
                &app_roots,
                &roots.trash,
                &work,
                &appmanager_core::port_zip::BundleLimits::default(),
                replace_existing,
                password,
                &cancel,
            )
        } else {
            appmanager_core::port_zip::install_uploaded_bundle_replacing_with_password(
                &bundle,
                &roots.scripts,
                &roots.game_dirs,
                &app_roots,
                &roots.trash,
                &work,
                &appmanager_core::port_zip::BundleLimits::default(),
                replace_existing,
                password,
                &cancel,
            )
        }
    }
    fn new(request: Request) -> Result<Self, String> {
        let paths = Paths::new(&request);
        let root = env_path("PAM_NATIVE_ROOT");
        let target_override = normalized_target_override(root.as_deref());
        let config_directories = configured_directories(&request, &paths);
        let resolved = resolve(
            &paths,
            root.clone(),
            target_override.clone(),
            &config_directories,
        )?;
        Self::from_resolution_without_recovery(
            request,
            paths,
            Arc::new(resolved),
            root,
            Arc::new(Mutex::new(None)),
        )
    }

    pub(crate) fn new_pinned(
        request: Request,
        resolved: Arc<DeviceResolution>,
        health: SharedHealth,
    ) -> Result<Self, String> {
        let session = Self::new_pinned_without_recovery(request, resolved, health)?;
        session.recover_transactions()?;
        Ok(session)
    }

    pub(crate) fn new_pinned_without_recovery(
        request: Request,
        resolved: Arc<DeviceResolution>,
        health: SharedHealth,
    ) -> Result<Self, String> {
        let paths = Paths::new(&request);
        let root = env_path("PAM_NATIVE_ROOT");
        Self::from_resolution_without_recovery(request, paths, resolved, root, health)
    }

    fn from_resolution_without_recovery(
        request: Request,
        paths: Paths,
        resolved: Arc<DeviceResolution>,
        root: Option<PathBuf>,
        health: SharedHealth,
    ) -> Result<Self, String> {
        if !paths.app_root.is_dir() {
            return Err(format!(
                "APP Manager directory is missing: {}",
                paths.app_root.display()
            ));
        }
        fs::create_dir_all(&paths.state).map_err(display_error)?;
        fs::create_dir_all(&paths.trash).map_err(display_error)?;
        Ok(Self {
            paths,
            resolved,
            root,
            cancel_token: request.cancel_token,
            progress_channel: request.progress_channel,
            config_refresh_status: None,
            health,
        })
    }

    fn recover_transactions(&self) -> Result<(), String> {
        {
            let _guard = ActivityGuard::acquire(&self.paths.operation_lock)?;
            let roots = &self.resolved.context.roots;
            let app_roots = app_install_targets(&roots.apps);
            appmanager_core::port_zip::recover_bundle_transactions(
                &roots.app_state.join("zip-work"),
                &roots.scripts,
                &roots.game_dirs,
                &app_roots,
                &roots.trash,
            )?;
            if let Ok(plan) = appmanager_core::InstallPlan::from_context(&self.resolved.context)
                .and_then(|plan| plan.validate(&self.resolved.context))
            {
                appmanager_core::recover_portmaster_transactions(&plan, &self.paths.state)
                    .map_err(display_error)?;
            }
        }
        Ok(())
    }

    fn clear_health(&self) {
        *self
            .health
            .lock()
            .unwrap_or_else(|value| value.into_inner()) = None;
    }

    fn log(&self, message: &str) {
        let path = self.paths.app_root.join("log.txt");
        if let Ok(mut file) = fs::OpenOptions::new().create(true).append(true).open(path) {
            let _ = writeln!(file, "[PAM] {message}");
        }
    }

    fn write_startup_diagnostics(&self) {
        let management = match self.resolved.context.management {
            ManagementMode::App => "app",
            ManagementMode::System => "system",
        };
        let identity = &self.resolved.identity;
        let resolution = &self.resolved.resolution;
        let mut lines = vec![
            "----- startup diagnostics -----".to_owned(),
            format!("app.version={}", env!("CARGO_PKG_VERSION")),
            format!("config.origin={:?}", self.resolved.config_origin),
            format!("platform.id={}", resolution.platform_id),
            format!("platform.name={}", resolution.platform_display_name),
            format!("platform.class={}", resolution.device_class),
            format!(
                "model.id={}",
                self.resolved.model_id.as_deref().unwrap_or("")
            ),
            format!(
                "device.name={}",
                resolution
                    .model_display_name
                    .as_deref()
                    .unwrap_or(&resolution.platform_display_name)
            ),
            format!(
                "device.manufacturer={}",
                resolution
                    .device_manufacturer
                    .as_deref()
                    .or(identity.manufacturer.as_deref())
                    .unwrap_or("")
            ),
            format!(
                "device.submodel={}",
                identity.submodel.as_deref().unwrap_or("")
            ),
            format!(
                "system.name={}",
                identity.system_name.as_deref().unwrap_or("")
            ),
            format!(
                "system.version={}",
                identity.system_version.as_deref().unwrap_or("")
            ),
            format!("runtime.arch={}", device_arch()),
            format!("portmaster.management={management}"),
            "portmaster.health=checking".to_owned(),
            format!("portmaster.source_route={}", resolution.source_route),
            format!("portmaster.root={}", path_string(self.portmaster_root())),
            format!("path.launcher={}", self.paths.launcher.display()),
            format!("path.app_root={}", self.paths.app_root.display()),
            format!("path.state={}", self.paths.state.display()),
            format!(
                "path.scripts={}",
                self.resolved.context.roots.scripts.display()
            ),
            format!(
                "path.game_data={}",
                self.resolved.context.roots.game_dirs.display()
            ),
            format!(
                "path.libs={}",
                path_string(self.resolved.context.roots.libs.as_deref())
            ),
            format!(
                "path.images={}",
                path_string(self.resolved.context.roots.images.as_deref())
            ),
            format!("frontend.kind={}", self.resolved.context.frontend.kind),
            format!(
                "frontend.directory={}",
                self.resolved.context.frontend.directory.display()
            ),
            format!(
                "frontend.launcher={}",
                self.resolved.context.frontend.launcher.display()
            ),
            format!(
                "display.detected={}x{}",
                env::var("DISPLAY_WIDTH").unwrap_or_default(),
                env::var("DISPLAY_HEIGHT").unwrap_or_default()
            ),
            format!(
                "display.default={}x{}",
                resolution
                    .display
                    .get("default_width")
                    .and_then(Value::as_u64)
                    .unwrap_or(0),
                resolution
                    .display
                    .get("default_height")
                    .and_then(Value::as_u64)
                    .unwrap_or(0)
            ),
            format!(
                "display.driver={}",
                env::var("SDL_VIDEODRIVER").unwrap_or_default()
            ),
            format!(
                "display.wayland={}/{}",
                env::var("XDG_RUNTIME_DIR").unwrap_or_default(),
                env::var("WAYLAND_DISPLAY").unwrap_or_default()
            ),
        ];
        let enabled = resolution
            .capabilities
            .iter()
            .filter_map(|(name, enabled)| enabled.then_some(name.as_str()))
            .collect::<Vec<_>>()
            .join(",");
        lines.push(format!("capabilities.enabled={enabled}"));
        lines.push("-------------------------------".to_owned());
        self.log(&lines.join("\n[PAM] "));
    }

    fn write_snapshot_diagnostics(&self, snapshot: &Value) {
        let environment = snapshot.get("env").unwrap_or(&Value::Null);
        let text = |name: &str| environment.get(name).and_then(Value::as_str).unwrap_or("");
        let runtime_count = snapshot
            .get("runtime_metadata")
            .and_then(Value::as_object)
            .map_or(0, serde_json::Map::len);
        self.log(&format!(
            "portmaster.health={}\n[PAM] portmaster.version={}\n[PAM] \
             portmaster.target={}\n[PAM] update.status={}\n[PAM] \
             update.latest={}\n[PAM] runtime.catalog_entries={runtime_count}\n[PAM] \
             initialization=ready",
            text("portmaster_health"),
            text("portmaster_version"),
            text("portmaster_target"),
            text("update_status"),
            text("portmaster_latest"),
        ));
    }

    fn portmaster_root(&self) -> Option<&Path> {
        self.resolved.context.roots.portmaster.as_deref()
    }

    fn cancelled(&self) -> bool {
        self.cancel_token
            .as_ref()
            .is_some_and(appmanager_core::CancellationToken::is_cancelled)
    }

    fn source(&self) -> Result<ReleaseSource, String> {
        let route = &self.resolved.resolution.source_route;
        let endpoints = self
            .resolved
            .config
            .sources
            .get("endpoints")
            .and_then(Value::as_object)
            .ok_or_else(|| "device configuration has no source endpoints".to_owned())?;
        let value = self
            .resolved
            .config
            .sources
            .get("release_routes")
            .and_then(|value| value.get(route))
            .and_then(Value::as_object)
            .ok_or_else(|| format!("device configuration has no source route {route:?}"))?;
        let endpoint = value
            .get("manifest")
            .and_then(Value::as_str)
            .and_then(|name| endpoints.get(name))
            .and_then(Value::as_str)
            .filter(|url| url.starts_with("https://github.com/"))
            .ok_or_else(|| format!("source route {route:?} has no valid manifest endpoint"))?;
        let archive_name = value
            .get("archive_name")
            .and_then(Value::as_str)
            .filter(|name| safe_asset_name(name))
            .ok_or_else(|| format!("source route {route:?} has no safe archive name"))?;
        Ok(ReleaseSource {
            manifest_url: endpoint.to_owned(),
            archive_name: archive_name.to_owned(),
            install_allowed: value
                .get("install_allowed")
                .and_then(Value::as_bool)
                .unwrap_or(true),
        })
    }

    fn runtime_metadata_url(&self) -> Result<String, String> {
        let endpoint = self
            .resolved
            .config
            .sources
            .get("runtime")
            .and_then(|value| value.get("metadata"))
            .and_then(Value::as_str)
            .and_then(|name| self.resolved.config.sources.get("endpoints")?.get(name))
            .and_then(Value::as_str)
            .filter(|value| value.starts_with("https://github.com/"))
            .ok_or_else(|| {
                "device configuration has no valid Runtime metadata source".to_owned()
            })?;
        Ok(endpoint.to_owned())
    }

    fn runtime_arch(&self) -> Result<String, String> {
        configured_runtime_arch(&self.resolved.config, &device_arch())
    }

    fn capability(&self, name: &str) -> bool {
        self.resolved.resolution.capabilities.get(name) == Some(&true)
    }

    fn health_facts(&self) -> Result<HealthFacts, String> {
        if let Some(facts) = self
            .health
            .lock()
            .unwrap_or_else(|value| value.into_inner())
            .clone()
        {
            return Ok(facts);
        }
        let root_exists = self.portmaster_root().is_some_and(Path::is_dir);
        let report = match evaluate_health(&self.resolved.resolution) {
            Ok(report) => Some(report),
            Err(_) if !root_exists => None,
            Err(error) => return Err(display_error(error)),
        };
        let status = if !root_exists {
            "missing"
        } else {
            match report
                .as_ref()
                .expect("an existing PortMaster root requires a health report")
                .status
            {
                HealthStatus::Unresolved => "missing",
                HealthStatus::Damaged => "damaged",
                HealthStatus::Healthy => "healthy",
            }
        };
        let python_imports = report
            .as_ref()
            .map(|report| report.python_imports.join(","))
            .unwrap_or_default();
        let system_python_ok = report.as_ref().is_some_and(|report| {
            !matches!(report.python_mode.as_str(), "system" | "runtime_mount")
                || python_imports_ready(&report.python_imports)
        });
        let python_ok = report
            .as_ref()
            .is_some_and(|report| match report.python_mode.as_str() {
                "system" => system_python_ok,
                "runtime_mount" => {
                    system_python_ok
                        || report
                            .python_runtime_image
                            .as_deref()
                            .is_some_and(squashfs_has_magic)
                }
                "" => true,
                _ => false,
            });
        let facts = HealthFacts {
            status,
            report,
            python_ok,
            system_python_ok,
            python_imports,
        };
        *self
            .health
            .lock()
            .unwrap_or_else(|value| value.into_inner()) = Some(facts.clone());
        Ok(facts)
    }

    fn health_status(&self) -> Result<&'static str, String> {
        Ok(self.health_facts()?.status)
    }

    fn python_health(&self) -> (bool, String) {
        self.health_facts()
            .map(|facts| (facts.python_ok, facts.python_imports))
            .unwrap_or_else(|_| (false, String::new()))
    }

    /// Failed health checks only, so the UI can tell a definitely broken core
    /// (missing required files / launcher) from a merely suspicious one
    /// (permissions, pylibs, Python imports) and keep startup prompts quiet
    /// unless the problem is certain.
    fn health_checks(&self) -> Vec<Value> {
        let Ok(facts) = self.health_facts() else {
            return Vec::new();
        };
        let Some(report) = facts.report else {
            return Vec::new();
        };
        report
            .checks
            .iter()
            .map(|check| json!({ "kind": check.kind, "passed": check.passed }))
            .collect()
    }

    /// Read-only probe of the system library groups, using exactly the same
    /// rule the installer applies at install time: a candidate directory that
    /// contains every required soname. Only groups actually referenced by the
    /// frontend transforms are probed (those are the only ones the installer
    /// enforces); unreferenced groups are skipped so the UI never cries wolf.
    fn library_groups_readiness(&self) -> Vec<Value> {
        let referenced = self.referenced_library_groups();
        if referenced.is_empty() {
            return Vec::new();
        }
        let Some(groups) = self
            .resolved
            .resolution
            .libraries
            .get("groups")
            .and_then(Value::as_object)
        else {
            return Vec::new();
        };
        let mut out = Vec::new();
        for (name, value) in groups {
            if !referenced.contains(name) {
                continue;
            }
            let Ok(group) = serde_json::from_value::<LibraryGroupProbe>(value.clone()) else {
                continue;
            };
            let selected = group
                .candidates
                .iter()
                .find(|candidate| {
                    let probe = probe_device_path(candidate, self.root.as_deref());
                    group
                        .required_sonames
                        .iter()
                        .all(|soname| probe.join(soname).exists())
                })
                .cloned();
            let missing: Vec<String> = group
                .required_sonames
                .iter()
                .filter(|soname| {
                    !group.candidates.iter().any(|candidate| {
                        probe_device_path(candidate, self.root.as_deref())
                            .join(soname)
                            .exists()
                    })
                })
                .cloned()
                .collect();
            out.push(json!({
                "name": name,
                "ok": selected.is_some(),
                "selected": selected.map(|path| path.to_string_lossy().into_owned()),
                "missing": missing,
            }));
        }
        out
    }

    fn referenced_library_groups(&self) -> BTreeSet<String> {
        let mut out = BTreeSet::new();
        let Some(frontend) = self.resolved.resolution.frontend.as_object() else {
            return out;
        };
        let Some(transforms) = frontend.get("transforms").and_then(Value::as_array) else {
            return out;
        };
        for transform in transforms {
            let Some(object) = transform.as_object() else {
                continue;
            };
            if object.get("kind").and_then(Value::as_str) != Some("export_library_group") {
                continue;
            }
            if let Some(name) = object.get("library_group").and_then(Value::as_str) {
                out.insert(name.to_owned());
            }
        }
        out
    }

    fn core_version(&self) -> Option<String> {
        let root = self.portmaster_root()?;
        let version = root.join("version");
        if let Ok(value) = fs::read_to_string(version) {
            let value = safe_version(value.lines().next().unwrap_or(""));
            if !value.is_empty() {
                return Some(value);
            }
        }
        let source = fs::read_to_string(root.join("pugwash")).ok()?;
        source.lines().find_map(|line| {
            let value = line.trim().strip_prefix("PORTMASTER_VERSION = '")?;
            Some(safe_version(value.strip_suffix('\'')?))
        })
    }

    fn inventory_options(&self) -> InventoryOptions {
        InventoryOptions {
            scan_script_images: self.capability("scan_script_images"),
            ignore_dirs: SCAN_EXCLUDED_DIR_NAMES
                .iter()
                .copied()
                .chain([PORT_NAME])
                .map(str::to_owned)
                .collect(),
            // Order is part of the contract: PortMaster.sh, launcher, .port.sh.
            ignore_scripts: [
                PROTECTED_SCRIPT_NAMES[1],
                launcher_name(&self.paths.launcher),
                PROTECTED_SCRIPT_NAMES[2],
            ]
            .into_iter()
            .map(str::to_owned)
            .collect(),
            directory: self.launcher_directory().display().to_string(),
            controlfolder: self
                .portmaster_root()
                .map_or_else(String::new, |path| path.display().to_string()),
            home: env::var("HOME").unwrap_or_else(|_| "/root".into()),
        }
    }

    fn launcher_directory(&self) -> &Path {
        self.resolved
            .resolution
            .paths
            .get("launcher_directory")
            .or_else(|| self.resolved.resolution.paths.get("game_data"))
            .map(PathBuf::as_path)
            .unwrap_or(&self.paths.source_dir)
    }

    fn refresh_inventory(&self) -> Result<(), String> {
        if !self.capability("inventory_ports") && !self.capability("inventory_apps") {
            let _ = fs::remove_file(&self.paths.inventory);
            return Ok(());
        }
        let inventory =
            Inventory::scan_with_options(&self.resolved.context, &self.inventory_options())
                .map_err(display_error)?;
        write_json(&self.paths.inventory, &inventory)
    }

    fn refresh_inventory_if_available(&self, health: &str) -> Result<(), String> {
        if inventory_available(&self.resolved.context.management, health) {
            self.refresh_inventory()
        } else {
            let _ = fs::remove_file(&self.paths.inventory);
            Ok(())
        }
    }

    fn env_document(&self) -> Result<Value, String> {
        let health = self.health_status()?;
        let (python_ok, python_imports) = self.python_health();
        let (update_checked, update_status, latest) = read_update_cache(&self.paths.update_cache);
        let portmaster = self.portmaster_root();
        let libs = self.resolved.context.roots.libs.as_deref();
        let scripts = &self.resolved.context.roots.scripts;
        let game_data = &self.resolved.context.roots.game_dirs;
        let images = self.resolved.context.roots.images.as_deref();
        let display = &self.resolved.resolution.display;
        let input = &self.resolved.resolution.input;
        let source = self.source().ok();
        let values = json!({
            "controlfolder": path_string(portmaster),
            "scripts_dir": scripts,
            "gamedirs_dir": game_data,
            "images_dir": path_string(images),
            "scan_script_images": self.capability("scan_script_images"),
            "libs_dir": path_string(libs),
            "gamedir": self.paths.app_root,
            "directory": self.launcher_directory(),
            "home": env::var("HOME").unwrap_or_else(|_| "/root".into()),
            "cfw": self.resolved.resolution.platform_display_name,
            "free_bytes": free_bytes(scripts),
            "display_width": env::var("DISPLAY_WIDTH").ok().and_then(|v| v.parse::<u64>().ok()).or_else(|| display.get("default_width").and_then(Value::as_u64)).unwrap_or(960).to_string(),
            "display_height": env::var("DISPLAY_HEIGHT").ok().and_then(|v| v.parse::<u64>().ok()).or_else(|| display.get("default_height").and_then(Value::as_u64)).unwrap_or(720).to_string(),
            "device_arch": device_arch(),
            "device": env::var("DEVICE").unwrap_or_default(),
            "param_device": self.resolved.resolution.platform_id,
            "analog_sticks": input.get("analog_sticks").and_then(Value::as_u64).unwrap_or(2).to_string(),
            "lowres": env::var("LOWRES").unwrap_or_else(|_| "N".into()),
            "cur_tty": input.get("tty").and_then(Value::as_str).unwrap_or("/dev/tty0"),
            "sdl_controller_file": self.paths.share_dir.join("gamecontrollerdb.txt"),
            "esudo": env::var("ESUDO").unwrap_or_default(),
            "gptokeyb": self.paths.bin_dir.join("gptokeyb"),
            "path": env::var("PATH").unwrap_or_default(),
            "ld_library_path": env::var("LD_LIBRARY_PATH").unwrap_or_default(),
            "xdg_config_home": env::var("XDG_CONFIG_HOME").unwrap_or_default(),
            "xdg_data_home": env::var("XDG_DATA_HOME").unwrap_or_default(),
            "app_root": self.paths.app_root,
            "portmaster_health": health,
            "portmaster_health_checks": self.health_checks(),
            "portmaster_python_ok": python_ok,
            "portmaster_python_imports": python_imports,
            "portmaster_version": self.core_version().unwrap_or_default(),
            "portmaster_target": path_string(portmaster),
            "portmaster_release_channel": self.resolved.resolution.source_route,
            "portmaster_release_manifest_url": source.as_ref().map(|v| v.manifest_url.as_str()).unwrap_or(""),
            "portmaster_release_archive_url": source.as_ref().map(|v| v.manifest_url.replace("version.json", &v.archive_name)).unwrap_or_default(),
            "portmaster_release_archive_name": source.as_ref().map(|v| v.archive_name.as_str()).unwrap_or(""),
            "portmaster_release_install_allowed": source.as_ref().is_some_and(|v| v.install_allowed),
            "portmaster_management": match self.resolved.context.management { ManagementMode::App => "app", ManagementMode::System => "system" },
            "capability_install_portmaster": self.capability("install_portmaster"),
            "capability_update_portmaster": self.capability("update_portmaster"),
            "capability_repair_runtimes": self.capability("repair_runtimes"),
            "capability_manage_portmaster": self.capability("manage_portmaster"),
            "capability_manage_ports": self.capability("manage_ports"),
            "capability_inventory_ports": self.capability("inventory_ports"),
            "capability_install_ports": self.capability("install_ports"),
            "capability_inventory_apps": self.capability("inventory_apps"),
            "capability_manage_apps": self.capability("manage_apps"),
            "capability_install_apps": self.capability("install_apps"),
            "capability_trash": self.capability("trash"),
            "capability_leftovers": self.capability("leftovers"),
            "capability_cleanup_appledouble": self.capability("cleanup_appledouble"),
            "capability_manage_artwork": self.capability("manage_artwork"),
            "capability_manage_frontend": self.capability("manage_frontend"),
            "capability_manage_images": self.capability("manage_images"),
            "health_contract": "portkit.health.v1",
            "health_required": portkit_core::health::HEALTH_REQUIRED_KINDS,
            "portmaster_frontend_kind": self.resolved.context.frontend.kind,
            "portmaster_frontend_dir": self.resolved.context.frontend.directory,
            "portmaster_frontend_launcher": self.resolved.context.frontend.launcher,
            "portmaster_frontend_names": self.resolved.context.frontend.names.join(","),
            "device_name": self.resolved.resolution.model_display_name.as_ref().unwrap_or(&self.resolved.resolution.platform_display_name),
            "device_manufacturer": self.resolved.resolution.device_manufacturer.as_deref()
                .or(self.resolved.identity.manufacturer.as_deref()).unwrap_or(""),
            "device_submodel": self.resolved.identity.submodel.as_deref().unwrap_or(""),
            "system_name": self.resolved.identity.system_name.as_deref().unwrap_or(""),
            "system_version": self.resolved.identity.system_version.as_deref().unwrap_or(""),
            "device_class": self.resolved.resolution.device_class,
            "target_confirmed": if self.resolved.resolution.target_confirmed { "1" } else { "0" },
            "library_groups": self.library_groups_readiness(),
            "update_cache_file": self.paths.update_cache,
            "update_checked": update_checked,
            "update_status": update_status,
            "portmaster_latest": latest,
            "ignore_dirs": SCAN_EXCLUDED_DIR_NAMES.iter().copied().chain([PORT_NAME]).collect::<Vec<_>>(),
            "protected_app_names": PROTECTED_DIR_NAMES.iter().copied().chain([PORT_NAME]).collect::<Vec<_>>(),
            "ignore_scripts": [PROTECTED_SCRIPT_NAMES[1], launcher_name(&self.paths.launcher), PROTECTED_SCRIPT_NAMES[2]],
            "self_port": PORT_NAME,
            "web_url": if local_ip().is_empty() { String::new() } else { format!("http://{}", local_ip()) }
        });
        values
            .as_object()
            .ok_or_else(|| "invalid environment snapshot".to_owned())?;
        Ok(values)
    }

    pub(crate) fn inventory_snapshot(&self) -> Result<Option<Inventory>, String> {
        if !self.capability("inventory_ports") && !self.capability("inventory_apps") {
            return Ok(None);
        }
        let mut inventory =
            Inventory::scan_with_options(&self.resolved.context, &self.inventory_options())
                .map_err(display_error)?;
        // SquashFS magic alone cannot tell a truncated/bit-rotted image from a
        // good one. Cross-check the byte size against the official metadata
        // (the same metadata the repair path validates against) and mark a
        // size mismatch as damaged so it stops hiding from the repair UI.
        let Ok(bytes) = fs::read(&self.paths.runtime_metadata_json) else {
            return Ok(Some(inventory));
        };
        let Ok(metadata) = RuntimeMetadata::parse(&bytes) else {
            return Ok(Some(inventory));
        };
        let arch = self.runtime_arch()?;
        for fact in &mut inventory.runtimes.facts {
            if fact.health == appmanager_core::RuntimeHealth::Unknown
                && let Some(entry) = metadata.get(&fact.name, &arch)
                && fact.bytes != entry.size
            {
                fact.health = appmanager_core::RuntimeHealth::InvalidMagic;
            }
        }
        Ok(Some(inventory))
    }

    fn persisted_inventory(&self) -> Option<Value> {
        let bytes = fs::read(&self.paths.inventory).ok()?;
        serde_json::from_slice(&bytes).ok()
    }

    fn embedded_snapshot(&self, reusable_inventory: Option<Value>) -> Result<Value, String> {
        let health = self.health_status()?;
        let inventory = if inventory_available(&self.resolved.context.management, health) {
            match reusable_inventory {
                Some(value) => value,
                None => serde_json::to_value(self.inventory_snapshot()?).map_err(display_error)?,
            }
        } else {
            Value::Null
        };
        let revision = serde_json::from_value::<Inventory>(inventory.clone())
            .ok()
            .map(|inventory| inventory_revision(&inventory))
            .unwrap_or_default();
        Ok(json!({
            "env": self.env_document()?,
            "inventory": inventory,
            "revision": revision,
            "runtime_metadata": self.runtime_metadata_snapshot(),
        }))
    }

    fn runtime_metadata_snapshot(&self) -> Value {
        let Ok(bytes) = fs::read(&self.paths.runtime_metadata_json) else {
            return json!({});
        };
        let Ok(metadata) = RuntimeMetadata::parse(&bytes) else {
            return json!({});
        };
        let Ok(arch) = self.runtime_arch() else {
            return json!({});
        };
        Value::Object(
            metadata
                .entries()
                .filter(|entry| entry.arch == arch)
                .map(|entry| {
                    (
                        entry.name.clone(),
                        json!({
                            "arch": entry.arch,
                            "bytes": entry.size,
                            "md5": entry.md5,
                            "url": entry.url,
                        }),
                    )
                })
                .collect(),
        )
    }

    fn refresh_inventory_state(&self) -> Result<(), String> {
        let health = self.health_status()?;
        self.refresh_inventory_if_available(health)
    }

    fn love_environment(&self) -> Result<BTreeMap<String, String>, String> {
        let mut variables = BTreeMap::new();
        variables.insert("app_root".into(), self.paths.app_root.display().to_string());
        variables.insert("state_dir".into(), self.paths.state.display().to_string());
        variables.insert(
            "scripts_dir".into(),
            self.paths.source_dir.display().to_string(),
        );
        variables.insert(
            "platform_id".into(),
            self.resolved.resolution.platform_id.clone(),
        );
        for (name, path) in &self.resolved.resolution.paths {
            variables.insert(name.clone(), path.display().to_string());
            variables.insert(format!("{name}_dir"), path.display().to_string());
        }
        let environment = self
            .resolved
            .config
            .environment
            .command_environment_for_scope("love_ui", &variables)
            .map_err(display_error)?;
        let mut resolved = environment
            .resolve(&self.resolved.config.environment, env::vars_os())
            .map_err(display_error)?;
        resolved.insert(
            "PAM_SOURCE_DIR".into(),
            self.paths.source_dir.display().to_string(),
        );
        resolved.insert(
            "PAM_APP_ROOT".into(),
            self.paths.app_root.display().to_string(),
        );
        resolved.insert(
            "PAM_LAUNCHER".into(),
            self.paths.launcher.display().to_string(),
        );
        // Static pages are event-driven (no idle FPS). Animation still requests 60 FPS.
        resolved.insert("LOVE_LITE_ANIMATION_FPS".into(), "60".into());
        resolved.insert("LOVE_LITE_RENDERER".into(), "auto".into());
        let runtime_dir = resolved
            .get("XDG_RUNTIME_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| "/run".into());
        let wayland = resolved
            .get("WAYLAND_DISPLAY")
            .cloned()
            .unwrap_or_else(|| "wayland-0".into());
        if runtime_dir.join(&wayland).exists() {
            resolved.insert("XDG_RUNTIME_DIR".into(), runtime_dir.display().to_string());
            resolved.insert("WAYLAND_DISPLAY".into(), wayland);
            resolved.insert("SDL_VIDEODRIVER".into(), "wayland".into());
            resolved.remove("LIBGL_FB");
        } else {
            resolved.remove("SDL_VIDEODRIVER");
            resolved.remove("WAYLAND_DISPLAY");
            resolved.insert(
                "LIBGL_FB".into(),
                if Path::new("/dev/dri/card0").exists() {
                    "4"
                } else {
                    "2"
                }
                .into(),
            );
        }
        Ok(resolved)
    }

    fn sync_artwork(&self) {
        if !self.capability("manage_artwork") {
            return;
        }
        let Some(images) = self.resolved.context.roots.images.as_deref() else {
            return;
        };
        if images.is_symlink() || fs::create_dir_all(images).is_err() {
            return;
        }
        let stem = self
            .paths
            .launcher
            .file_stem()
            .and_then(|name| name.to_str())
            .unwrap_or("");
        if stem.is_empty() || stem == ".port" {
            return;
        }
        for extension in ["png", "PNG", "jpg", "JPG", "jpeg", "JPEG", "webp", "WEBP"] {
            let source = self.paths.source_dir.join(format!("{stem}.{extension}"));
            let target = images.join(format!("{stem}.{extension}"));
            if source.is_file() && !source.is_symlink() && !target.exists() {
                let _ = fs::copy(source, target);
                break;
            }
        }
    }

    fn check_update(&self, force: bool) -> Result<u8, String> {
        if !self.capability("update_portmaster") {
            return Ok(0);
        }
        let source = self.source()?;
        if !source.install_allowed {
            return Ok(0);
        }
        appmanager_core::refresh_stable_cache(&appmanager_core::StableCacheRequest {
            manifest_url: source.manifest_url,
            cache: self.paths.update_cache.clone(),
            force,
        })
        .map_err(display_error)?;
        Ok(0)
    }

    fn refresh_device_config(&mut self) -> Result<u8, String> {
        if let Some(status) =
            fresh_config_refresh_status(&self.paths.config_refresh_cache, epoch_seconds())
        {
            self.config_refresh_status = Some(status.to_owned());
            return Ok(0);
        }
        let configured_source = self
            .resolved
            .config
            .bootstrap
            .get("config_url")
            .and_then(Value::as_str)
            .ok_or_else(|| "embedded configuration has no bootstrap URL".to_owned())?;
        let source =
            env::var("PAM_DEVICE_CONFIG_URL").unwrap_or_else(|_| configured_source.to_owned());
        let timeout = env::var("PAM_CONFIG_REFRESH_TIMEOUT_SECONDS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .filter(|value| (1..=44).contains(value))
            .unwrap_or(CONFIG_REFRESH_TIMEOUT_SECONDS);
        let mut detection = portkit_core::DetectionContext::current(self.paths.launcher.clone());
        detection.root = self.root.clone();
        detection.target_override = normalized_target_override(self.root.as_deref());
        let status = match portkit_core::refresh_config(&portkit_core::ConfigRefreshRequest {
            source,
            packaged_root: self.paths.config_dir.join("config.json"),
            packaged_dir: self.paths.config_dir.clone(),
            cached_root: self.paths.remote_config.clone(),
            cache_dir: self.paths.remote_config_dir.clone(),
            timeout: std::time::Duration::from_secs(timeout),
            detection,
        }) {
            Ok(status) => status,
            Err(error) => {
                write_config_refresh_status(&self.paths.config_refresh_cache, "error");
                self.config_refresh_status = Some("error".to_owned());
                return Err(display_error(error));
            }
        };
        write_config_refresh_status(&self.paths.config_refresh_cache, "ok");
        self.config_refresh_status = Some(status.as_str().to_owned());
        Ok(0)
    }
}

pub(crate) struct OperationReservation {
    _guard: ActivityGuard,
}

fn app_install_targets(roots: &[appmanager_core::ManagedAppLocation]) -> Vec<&Path> {
    let highest = roots
        .iter()
        .filter(|root| {
            root.roles.contains(&portkit_core::LocationRole::Install)
                && root
                    .formats
                    .contains(&portkit_core::BundleFormat::TrimuiApp)
        })
        .map(|root| root.priority)
        .max();
    roots
        .iter()
        .filter(|root| {
            Some(root.priority) == highest
                && root.roles.contains(&portkit_core::LocationRole::Install)
                && root
                    .formats
                    .contains(&portkit_core::BundleFormat::TrimuiApp)
        })
        .map(|root| root.path.as_path())
        .collect()
}

fn require_bundle_capability(
    capabilities: &BTreeMap<String, bool>,
    kind: &str,
) -> Result<(), String> {
    let capability = match kind {
        "port" => "install_ports",
        "trimui_app" => "install_apps",
        _ => return Err("unsupported zip bundle".to_owned()),
    };
    (capabilities.get(capability) == Some(&true))
        .then_some(())
        .ok_or_else(|| format!("{kind} installation is disabled by device configuration"))
}

fn resolve(
    paths: &Paths,
    root: Option<PathBuf>,
    target_override: Option<PathBuf>,
    config_directories: &ConfigDirectories,
) -> Result<DeviceResolution, String> {
    crate::resolution::resolve_device_context(
        paths.launcher.clone(),
        paths.state.clone(),
        paths.trash.clone(),
        paths
            .remote_config
            .is_file()
            .then(|| paths.remote_config.clone()),
        target_override,
        root,
        config_directories,
    )
}

pub(crate) fn apply_embedded_actions_at_revision(
    session: &mut Session,
    actions: &[EmbeddedAction],
    expected_revision: Option<&str>,
) -> Result<(), String> {
    let outcome = execute_actions_at_revision(session, actions, expected_revision)?;
    if outcome.failed {
        let details = if outcome.failures.is_empty() {
            String::new()
        } else {
            format!(": {}", outcome.failures.join("; "))
        };
        return Err(format!(
            "operation reported a failure after handling {} item(s){details}",
            outcome.handled,
        ));
    }
    Ok(())
}

fn execute_actions_at_revision(
    session: &mut Session,
    embedded_actions: &[EmbeddedAction],
    expected_revision: Option<&str>,
) -> Result<OperationOutcome, String> {
    let _guard = ActivityGuard::acquire(&session.paths.operation_lock)?;
    if let Some(expected) = expected_revision {
        let report = session
            .inventory_snapshot()?
            .unwrap_or_else(empty_inventory);
        if inventory_revision(&report) != expected {
            return Err("inventory changed; refresh before applying this operation".to_owned());
        }
    }
    let actions = embedded_actions
        .iter()
        .map(ServiceAction::try_from)
        .collect::<Result<Vec<_>, _>>()?;
    if actions.is_empty() {
        return Err("APP Manager action list is empty".into());
    }
    let has_file_actions = actions.iter().any(|action| is_file_action(&action.kind));
    let file_only = actions.iter().all(|action| is_file_action(&action.kind));
    let outcome = if file_only {
        validate_destructive_intent(session, &actions)?;
        apply_file_action_batch(session, &actions)?
    } else if has_file_actions {
        OperationOutcome {
            failed: true,
            handled: actions.len(),
            ..OperationOutcome::default()
        }
    } else {
        session.clear_health();
        apply_network_actions(session, &actions)?
    };

    let health = session.health_status()?;
    session.refresh_inventory_if_available(health)?;
    Ok(outcome)
}

pub(crate) fn inventory_revision(report: &Inventory) -> String {
    let mut facts = Vec::new();
    for app in &report.apps {
        facts.push(format!("app-root\t{}", app.root_id));
        append_path_revision(&mut facts, &app.folder);
        append_path_revision(&mut facts, &app.launch);
    }
    for port in &report.ports {
        facts.push(format!(
            "port\t{}\t{}",
            port.path.display(),
            port.data_path.display()
        ));
        append_path_revision(&mut facts, &port.path);
        if port.dir_exists {
            append_path_revision(&mut facts, &port.data_path);
        }
        for image in &port.images {
            facts.push(format!(
                "port-image\t{}\t{}",
                port.path.display(),
                image.path.display()
            ));
            append_path_revision(&mut facts, &image.path);
        }
    }
    for entry in &report.orphan_dirs {
        facts.push(format!("orphan-dir\t{}", entry.path.display()));
        append_path_revision(&mut facts, &entry.path);
    }
    for image in &report.orphan_images {
        facts.push(format!("orphan-image\t{}", image.path.display()));
        append_path_revision(&mut facts, &image.path);
    }
    for (path, count) in &report.data_refcount {
        facts.push(format!("data-reference-count\t{path}\t{count}"));
    }
    for entry in &report.trash {
        facts.push(format!("trash-bucket\t{}", entry.bucket));
        append_path_revision(&mut facts, &entry.path);
        if !entry.restore_target.as_os_str().is_empty() {
            facts.push(format!(
                "restore-conflict\t{}\t{}",
                entry.restore_target.display(),
                entry.restore_conflict
            ));
            append_path_revision(&mut facts, &entry.restore_target);
        }
    }
    facts.sort();
    let mut digest = Sha256::new();
    for fact in facts {
        digest.update(fact.as_bytes());
        digest.update(b"\n");
    }
    format!("{:x}", digest.finalize())
}

pub(crate) fn protected_app_name(name: &str) -> bool {
    name == PORT_NAME || PROTECTED_DIR_NAMES.contains(&name)
}

fn append_path_revision(facts: &mut Vec<String>, path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        match fs::symlink_metadata(path) {
            Ok(metadata) => facts.push(format!(
                "path\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
                path.display(),
                metadata.dev(),
                metadata.ino(),
                metadata.mode(),
                metadata.size(),
                metadata.mtime(),
                metadata.mtime_nsec(),
            )),
            Err(_) => facts.push(format!("missing\t{}", path.display())),
        }
    }
    #[cfg(not(unix))]
    {
        match fs::symlink_metadata(path) {
            Ok(metadata) => facts.push(format!(
                "path\t{}\t{}\t{:?}",
                path.display(),
                metadata.len(),
                metadata.modified().ok(),
            )),
            Err(_) => facts.push(format!("missing\t{}", path.display())),
        }
    }
}

fn validate_destructive_intent(session: &Session, actions: &[ServiceAction]) -> Result<(), String> {
    if !actions
        .iter()
        .any(|action| matches!(action.kind.as_str(), "TRASH" | "DELETE_MANAGED"))
    {
        return Ok(());
    }
    let inventory =
        Inventory::scan_with_options(&session.resolved.context, &session.inventory_options())
            .map_err(display_error)?;
    validate_destructive_inventory(&inventory, actions)
}

fn validate_destructive_inventory(
    inventory: &Inventory,
    actions: &[ServiceAction],
) -> Result<(), String> {
    let selected = actions
        .iter()
        .filter(|action| matches!(action.kind.as_str(), "TRASH" | "DELETE_MANAGED"))
        .map(|action| Path::new(&action.argument))
        .collect::<BTreeSet<_>>();

    for action in actions
        .iter()
        .filter(|action| matches!(action.kind.as_str(), "TRASH" | "DELETE_MANAGED"))
    {
        let path = Path::new(&action.argument);
        if let Some(entry) = inventory.data_dirs.iter().find(|entry| entry.path == path) {
            let selected_references = inventory
                .ports
                .iter()
                .filter(|port| port.data_path == path && selected.contains(port.path.as_path()))
                .count();
            let current_references = inventory
                .data_refcount
                .get(&entry.path.to_string_lossy().into_owned())
                .copied()
                .unwrap_or(0);
            let still_orphan = inventory
                .orphan_dirs
                .iter()
                .any(|orphan| orphan.path == entry.path);
            if current_references > selected_references
                || (current_references == 0 && !still_orphan)
            {
                return Err(format!(
                    "selection changed; rescan before removing {}",
                    path.display()
                ));
            }
        }

        if inventory.images.iter().any(|image| image.path == path) {
            let used_by_unselected = inventory.ports.iter().any(|port| {
                !selected.contains(port.path.as_path())
                    && port.images.iter().any(|image| image.path == path)
            });
            let associated = inventory
                .ports
                .iter()
                .any(|port| port.images.iter().any(|image| image.path == path));
            let still_orphan = inventory
                .orphan_images
                .iter()
                .any(|image| image.path == path);
            if used_by_unselected || (!associated && !still_orphan) {
                return Err(format!(
                    "selection changed; rescan before removing {}",
                    path.display()
                ));
            }
        }
    }
    Ok(())
}

#[derive(Clone, Debug)]
struct ServiceAction {
    kind: String,
    argument: String,
}

impl TryFrom<&EmbeddedAction> for ServiceAction {
    type Error = String;

    fn try_from(action: &EmbeddedAction) -> Result<Self, Self::Error> {
        if action.kind.is_empty()
            || action.arg.contains(['\t', '\r', '\n', '\0'])
            || !action
                .kind
                .bytes()
                .all(|byte| byte.is_ascii_uppercase() || byte == b'_')
        {
            return Err("APP Manager action contains unsafe text".into());
        }
        Ok(Self {
            kind: action.kind.clone(),
            argument: action.arg.clone(),
        })
    }
}

fn is_file_action(kind: &str) -> bool {
    FileActionKind::from_code(kind).is_some()
}

fn apply_file_action_batch(
    session: &Session,
    actions: &[ServiceAction],
) -> Result<OperationOutcome, String> {
    let actions = actions
        .iter()
        .map(|action| {
            Ok(FileAction {
                kind: FileActionKind::from_code(&action.kind)
                    .ok_or_else(|| format!("unknown file action {:?}", action.kind))?,
                argument: PathBuf::from(&action.argument),
            })
        })
        .collect::<Result<Vec<_>, String>>()?;
    let (privilege_command, privilege_arguments) = privilege_command();
    apply_typed_file_actions(&FileApplyRequest {
        context: &session.resolved.context,
        actions: &actions,
        self_launcher: &session.paths.launcher,
        self_port: PORT_NAME,
        privilege_command: privilege_command.as_deref(),
        privilege_arguments: &privilege_arguments,
        progress_channel: session.progress_channel.clone(),
        cancel_token: session.cancel_token.as_ref(),
    })
    .map(OperationOutcome::from)
    .map_err(display_error)
}

fn privilege_command() -> (Option<PathBuf>, Vec<String>) {
    let mut words = env::var("ESUDO")
        .unwrap_or_default()
        .split_whitespace()
        .map(str::to_owned)
        .collect::<Vec<_>>();
    if words.is_empty() {
        return (None, Vec::new());
    }
    let command = PathBuf::from(words.remove(0));
    (Some(command), words)
}

fn apply_network_actions(
    session: &Session,
    actions: &[ServiceAction],
) -> Result<OperationOutcome, String> {
    let validated = match validate_network_actions(session, actions) {
        Ok(validated) => validated,
        Err(reason) => {
            session.log(&format!("Network action rejected: {reason}"));
            return Ok(OperationOutcome {
                failed: true,
                handled: actions.len(),
                ..OperationOutcome::default()
            });
        }
    };
    match validated {
        ValidatedNetworkActions::Runtimes(runtime_names) => {
            repair_runtime_batch(session, &runtime_names)
        }
        ValidatedNetworkActions::PortMaster {
            action,
            risk_ack,
            support_ack,
        } => install_portmaster_action(session, &action, risk_ack, support_ack),
    }
}

#[derive(Debug)]
enum ValidatedNetworkActions {
    Runtimes(Vec<String>),
    PortMaster {
        action: ServiceAction,
        risk_ack: bool,
        support_ack: bool,
    },
}

fn validate_network_actions(
    session: &Session,
    actions: &[ServiceAction],
) -> Result<ValidatedNetworkActions, &'static str> {
    if actions
        .iter()
        .any(|action| action.kind == "INSTALL_RUNTIME")
    {
        if !actions
            .iter()
            .all(|action| action.kind == "INSTALL_RUNTIME")
        {
            return Err("mixed-network-actions");
        }
        return Ok(ValidatedNetworkActions::Runtimes(
            actions
                .iter()
                .map(|action| action.argument.clone())
                .collect(),
        ));
    }

    let mut risk_ack = false;
    let mut support_ack = false;
    let mut install = None;
    for (index, action) in actions.iter().enumerate() {
        match action.kind.as_str() {
            "ACK_DEVICE_RISK"
                if install.is_none()
                    && !risk_ack
                    && action.argument == session.resolved.resolution.device_class
                    && matches!(
                        action.argument.as_str(),
                        "official-untested" | "unsupported-known"
                    ) =>
            {
                risk_ack = true;
            }
            "ACK_DEVICE_SUPPORT"
                if install.is_none()
                    && !support_ack
                    && session.resolved.resolution.device_class == "unsupported-known"
                    && session
                        .portmaster_root()
                        .is_some_and(|path| path == Path::new(&action.argument)) =>
            {
                support_ack = true;
            }
            "INSTALL_PORTMASTER"
                if install.is_none()
                    && index + 1 == actions.len()
                    && action.argument == "stable" =>
            {
                install = Some(action.clone());
            }
            "ACK_DEVICE_RISK" => return Err("invalid-device-ack"),
            "ACK_DEVICE_SUPPORT" => return Err("invalid-support-ack"),
            "INSTALL_PORTMASTER" => return Err("invalid-portmaster-action"),
            _ => return Err("unknown-action"),
        }
    }
    let action = install.ok_or("missing-portmaster-action")?;
    match session.resolved.resolution.device_class.as_str() {
        "tested" if !risk_ack && !support_ack => {}
        "official-untested" if risk_ack && !support_ack => {}
        "unsupported-known" if risk_ack && support_ack => {}
        "tested" | "official-untested" | "unsupported-known" => {
            return Err("invalid-device-ack-set");
        }
        _ => return Err("unsupported-device"),
    }
    Ok(ValidatedNetworkActions::PortMaster {
        action,
        risk_ack,
        support_ack,
    })
}

fn repair_runtime_batch(
    session: &Session,
    runtime_names: &[String],
) -> Result<OperationOutcome, String> {
    if !session.capability("repair_runtimes") {
        return Ok(OperationOutcome {
            failed: true,
            failures: runtime_names
                .iter()
                .map(|name| format!("{name}: capability disabled"))
                .collect(),
            ..OperationOutcome::default()
        });
    }
    refresh_runtime_metadata_cache(session, false)?;
    let libs = session
        .resolved
        .context
        .roots
        .libs
        .clone()
        .ok_or_else(|| "device configuration has no Runtime directory".to_owned())?;
    let metadata = fs::read(&session.paths.runtime_metadata_json).map_err(display_error)?;
    let outcome = repair_runtimes(&RuntimeRepairRequest {
        metadata,
        runtime_names: runtime_names.to_vec(),
        arch: session.runtime_arch()?,
        libs_root: libs,
        state_dir: session.paths.state.clone(),
        cancel_token: session.cancel_token.clone(),
        progress_channel: session.progress_channel.clone(),
    });
    match outcome {
        Ok(_) => Ok(OperationOutcome {
            handled: runtime_names.len(),
            ..OperationOutcome::default()
        }),
        Err(error) => {
            session.log(&format!("Runtime repair failed: {error}"));
            let metadata = RuntimeMetadata::parse(
                &fs::read(&session.paths.runtime_metadata_json).map_err(display_error)?,
            )
            .map_err(display_error)?;
            Ok(runtime_failure_outcome(
                runtime_names,
                &error.to_string(),
                |name| runtime_image_matches(session, &metadata, name),
            ))
        }
    }
}

fn runtime_failure_outcome(
    runtime_names: &[String],
    message: &str,
    mut installed: impl FnMut(&str) -> bool,
) -> OperationOutcome {
    let failures = runtime_names
        .iter()
        .filter(|name| !installed(name))
        .map(|name| format!("{name}: {message}"))
        .collect::<Vec<_>>();
    OperationOutcome {
        failed: !failures.is_empty(),
        handled: runtime_names.len().saturating_sub(failures.len()),
        failures,
        ..OperationOutcome::default()
    }
}

fn runtime_image_matches(session: &Session, metadata: &RuntimeMetadata, name: &str) -> bool {
    let Ok(arch) = session.runtime_arch() else {
        return false;
    };
    let Some(entry) = metadata.get(name, &arch) else {
        return false;
    };
    let Some(libs) = session.resolved.context.roots.libs.as_deref() else {
        return false;
    };
    let image = libs.join(format!("{name}.squashfs"));
    image
        .metadata()
        .is_ok_and(|value| value.len() == entry.size)
        && squashfs_has_magic(&image)
        && digest_file(&image, DigestAlgorithm::Md5).is_ok_and(|value| value == entry.md5)
}

fn install_portmaster_action(
    session: &Session,
    action: &ServiceAction,
    risk_ack: bool,
    support_ack: bool,
) -> Result<OperationOutcome, String> {
    let failure = |reason: &str| {
        session.log(&format!("PortMaster installation rejected: {reason}"));
        Ok(OperationOutcome {
            failed: true,
            handled: 1,
            ..OperationOutcome::default()
        })
    };
    if session.resolved.context.management == ManagementMode::System {
        return failure("system-managed");
    }
    let source = session.source()?;
    let existing_install = session.portmaster_root().is_some_and(|root| {
        ["control.txt", "pugwash", "harbourmaster", "PortMaster.sh"]
            .iter()
            .any(|name| {
                fs::symlink_metadata(root.join(name))
                    .is_ok_and(|metadata| metadata.file_type().is_file())
            })
    });
    let action_capability = if existing_install {
        "update_portmaster"
    } else {
        "install_portmaster"
    };
    if !source.install_allowed
        || !session.capability("manage_portmaster")
        || !session.capability(action_capability)
    {
        return failure("capability-disabled");
    }
    if action.argument != "stable" {
        return failure("invalid-release");
    }
    if !session.resolved.resolution.target_confirmed || session.portmaster_root().is_none() {
        return failure("unknown-target");
    }
    match session.resolved.resolution.device_class.as_str() {
        "tested" => {}
        "official-untested" if !risk_ack => return failure("device-ack-required"),
        "unsupported-known" if !risk_ack || !support_ack => {
            return failure("device-acks-required");
        }
        "official-untested" | "unsupported-known" => {}
        _ => return failure("unsupported-device"),
    }
    match install_stable_release(session, &source) {
        Ok(()) => Ok(OperationOutcome {
            handled: 1,
            ..OperationOutcome::default()
        }),
        Err(error) => {
            session.log(&format!("PortMaster installation failed: {error}"));
            let cancelled = session.cancelled();
            Ok(OperationOutcome {
                failed: !cancelled,
                handled: 1,
                cancelled,
                ..OperationOutcome::default()
            })
        }
    }
}

fn install_stable_release(session: &Session, source: &ReleaseSource) -> Result<(), String> {
    let _guard = ActivityGuard::acquire(&session.paths.portmaster_lock)?;
    publish_task_progress(
        session.progress_channel.as_ref(),
        "preparing",
        2,
        100,
        0,
        "Preparing PortMaster",
    )?;
    ensure_python_runtime(session)?;
    let cache = session.paths.state.join("portmaster-download");
    fs::create_dir_all(&cache).map_err(display_error)?;
    let release = cache.join("version.tsv");
    appmanager_core::fetch_stable_release(&appmanager_core::StableReleaseRequest {
        manifest_url: source.manifest_url.clone(),
        archive_name: source.archive_name.clone(),
        output: release.clone(),
    })
    .map_err(display_error)?;
    let (version, url, expected_md5) = read_release_row(&release)?;
    let archive = cache.join(&source.archive_name);
    let mut archive_valid = stable_archive_valid(&archive, &expected_md5);
    if !archive_valid {
        let _ = fs::remove_file(&archive);
        let progress = DownloadProgress::new(
            session.progress_channel.clone(),
            "PortMaster",
            session.cancel_token.clone(),
        );
        GitHubTransport::new()
            .fetch_with_timeout(
                Capability::Release,
                &url,
                &archive,
                |candidate| stable_archive_valid(candidate, &expected_md5),
                Some(&progress),
                Some(PORTMASTER_ARCHIVE_MAX_BYTES),
                std::time::Duration::from_secs(15 * 60),
            )
            .map_err(display_error)?;
        // A successful fetch has already passed the exact validator above.
        archive_valid = true;
    }
    if !archive_valid {
        let _ = fs::remove_file(&archive);
        return Err("downloaded PortMaster archive failed verification".into());
    }
    if session.cancelled() {
        return Err("PortMaster installation was cancelled".into());
    }
    publish_task_progress(
        session.progress_channel.as_ref(),
        "installing",
        88,
        100,
        0,
        "Installing PortMaster",
    )?;
    install_archive(session, archive)?;
    // Installation has committed. Completion progress is best-effort so a
    // full or briefly unavailable SD card cannot turn success into failure.
    let _ = publish_task_progress(
        session.progress_channel.as_ref(),
        "complete",
        100,
        100,
        0,
        &format!("PortMaster {version} installed"),
    );
    Ok(())
}

fn stable_archive_valid(path: &Path, expected_md5: &str) -> bool {
    path.is_file()
        && digest_file(path, DigestAlgorithm::Md5)
            .is_ok_and(|digest| digest.eq_ignore_ascii_case(expected_md5))
        && zip_readable(path).unwrap_or(false)
}

fn install_archive(session: &Session, archive: PathBuf) -> Result<(), String> {
    let plan = appmanager_core::InstallPlan::from_context(&session.resolved.context)
        .map_err(display_error)?
        .validate(&session.resolved.context)
        .map_err(display_error)?;
    appmanager_core::install_portmaster(&appmanager_core::InstallRequest {
        archive,
        state_dir: session.paths.state.clone(),
        trash_dir: session.paths.trash.clone(),
        cancel_token: session.cancel_token.clone(),
        progress_channel: session.progress_channel.clone(),
        probe_root: session.root.clone(),
        plan,
    })
    .map(|_| ())
    .map_err(display_error)
}

fn ensure_python_runtime(session: &Session) -> Result<(), String> {
    let facts = session.health_facts()?;
    let report = facts
        .report
        .ok_or_else(|| "PortMaster Python requirements could not be checked".to_owned())?;
    if report.python_mode != "runtime_mount" || facts.system_python_ok {
        return Ok(());
    }
    let runtime = report.python_runtime.as_deref().unwrap_or("python_3.11");
    let metadata_ready = fs::read(&session.paths.runtime_metadata_json)
        .ok()
        .and_then(|bytes| RuntimeMetadata::parse(&bytes).ok())
        .is_some_and(|metadata| runtime_image_matches(session, &metadata, runtime));
    if metadata_ready {
        return Ok(());
    }
    refresh_runtime_metadata_cache(session, false)?;
    let libs = session
        .resolved
        .context
        .roots
        .libs
        .clone()
        .ok_or_else(|| "device configuration has no Python Runtime directory".to_owned())?;
    repair_runtimes(&RuntimeRepairRequest {
        metadata: fs::read(&session.paths.runtime_metadata_json).map_err(display_error)?,
        runtime_names: vec![runtime.to_owned()],
        arch: session.runtime_arch()?,
        libs_root: libs,
        state_dir: session.paths.state.clone(),
        cancel_token: session.cancel_token.clone(),
        progress_channel: session.progress_channel.clone(),
    })
    .map_err(display_error)?;
    Ok(())
}

fn refresh_runtime_metadata_cache(session: &Session, force: bool) -> Result<(), String> {
    appmanager_core::refresh_runtime_metadata(&appmanager_core::RuntimeMetadataRequest {
        source: session.runtime_metadata_url()?,
        json_cache: session.paths.runtime_metadata_json.clone(),
        tsv_cache: None,
        force,
    })
    .map(|_| ())
    .map_err(display_error)
}

fn configured_runtime_arch(
    config: &portkit_core::Config,
    system_arch: &str,
) -> Result<String, String> {
    let system_arch = system_arch.to_ascii_lowercase();
    let architectures = config
        .sources
        .get("runtime")
        .and_then(|value| value.get("architectures"))
        .and_then(Value::as_array)
        .ok_or_else(|| "device configuration has no Runtime architecture map".to_owned())?;
    architectures
        .iter()
        .find(|architecture| {
            architecture
                .get("system_names")
                .and_then(Value::as_array)
                .is_some_and(|aliases| {
                    aliases
                        .iter()
                        .any(|alias| alias.as_str() == Some(system_arch.as_str()))
                })
        })
        .and_then(|architecture| architecture.get("id"))
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| {
            format!("device architecture {system_arch:?} has no configured Runtime mapping")
        })
}

fn read_release_row(path: &Path) -> Result<(String, String, String), String> {
    let value = fs::read_to_string(path).map_err(display_error)?;
    let fields = value.trim_end().split('\t').collect::<Vec<_>>();
    if fields.len() != 3
        || safe_version(fields[0]) != fields[0]
        || !fields[1].starts_with("https://github.com/")
        || fields[2].len() != 32
        || !fields[2].bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        return Err("invalid stable release metadata".into());
    }
    Ok((
        fields[0].into(),
        fields[1].into(),
        fields[2].to_ascii_lowercase(),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_test_port_zip(path: &Path, marker: &[u8]) {
        use std::io::Write as _;
        let file = fs::File::create(path).unwrap();
        let mut zip = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default();
        zip.start_file("game.sh", options).unwrap();
        zip.write_all(b"#!/bin/sh\n").unwrap();
        zip.start_file("game/data.bin", options).unwrap();
        zip.write_all(marker).unwrap();
        zip.finish().unwrap();
    }

    fn embedded_fixture() -> (tempfile::TempDir, EmbeddedService) {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("ports");
        let app_root = source.join("jenny92-appmanager");
        fs::create_dir_all(app_root.join("state")).unwrap();
        fs::create_dir_all(&source).unwrap();
        let launcher = source.join("APP Manager.sh");
        fs::write(&launcher, "#!/bin/sh\n").unwrap();
        let config = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../config");
        let service = EmbeddedService::new(EmbeddedRequest {
            source_dir: source,
            launcher,
            app_root,
            config_dir: Some(config),
            remote_config_dir: None,
        })
        .unwrap();
        (temp, service)
    }

    #[test]
    fn damaged_app_managed_environment_still_exposes_game_inventory() {
        // Game management never depends on a working PortMaster core.
        assert!(inventory_available(&ManagementMode::App, "healthy"));
        assert!(inventory_available(&ManagementMode::App, "damaged"));
        assert!(inventory_available(&ManagementMode::App, "missing"));
        assert!(inventory_available(&ManagementMode::System, "missing"));
    }

    #[test]
    fn game_handoff_derives_frontend_environment_from_the_resolved_core() {
        assert_eq!(
            portmaster_xdg_data_home(
                Some(Path::new("/mnt/sdcard/roms/ports/PortMaster")),
                Some(Path::new("/mnt/sdcard/roms/ports"))
            ),
            Some(PathBuf::from("/mnt/sdcard/roms/ports"))
        );
        assert_eq!(
            portmaster_xdg_data_home(
                Some(Path::new("/roms/ports/PortMaster")),
                Some(Path::new("/roms/ports"))
            ),
            Some(PathBuf::from("/roms/ports"))
        );
        assert_eq!(
            portmaster_xdg_data_home(
                Some(Path::new("/userdata/app/portmaster")),
                Some(Path::new("/roms/ports"))
            ),
            Some(PathBuf::from("/roms/ports"))
        );
        assert_eq!(portmaster_xdg_data_home(None, None), None);
    }

    #[test]
    fn game_handoff_publishes_the_config_resolved_portmaster_base() {
        let (_temp, mut service) = embedded_fixture();
        let scripts = service.request.source_dir.clone();
        let portmaster = scripts.join("PortMaster");
        fs::create_dir_all(&portmaster).unwrap();
        fs::write(portmaster.join("control.txt"), b"#!/bin/sh\n").unwrap();
        Arc::get_mut(&mut service.resolved)
            .expect("fixture owns its resolution")
            .context
            .roots
            .portmaster = Some(portmaster);
        let game = scripts.join("Game.sh");
        fs::write(&game, b"#!/bin/sh\n").unwrap();

        service
            .run_script(game.to_string_lossy().into_owned())
            .unwrap();

        assert_eq!(
            fs::read_to_string(
                service
                    .request
                    .app_root
                    .join("game_to_launch.xdg_data_home")
            )
            .unwrap(),
            scripts.to_string_lossy()
        );
        assert_eq!(
            fs::read_to_string(service.request.app_root.join("game_to_launch.txt")).unwrap(),
            game.to_string_lossy()
        );
    }

    #[test]
    fn background_update_lane_never_blocks_foreground_file_work() {
        let (_temp, service) = embedded_fixture();
        service.background_busy.store(true, Ordering::Release);
        let task_id = service.start("inventory-refresh", None).unwrap();
        assert!(task_id > 0);
        let error = service.start("update-check", None).unwrap_err();
        assert!(error.contains("automatic PortMaster update check"));
        service.background_busy.store(false, Ordering::Release);
    }

    #[test]
    fn remote_management_is_owned_by_the_embedded_service() {
        use std::io::{Read as _, Write as _};
        use std::net::{Shutdown, TcpStream};

        let (_temp, service) = embedded_fixture();
        let endpoint = service.enable_web().unwrap();
        assert_eq!(endpoint.code.len(), 6);
        assert!(endpoint.code.bytes().all(|byte| byte.is_ascii_digit()));
        assert!(service.web_on());
        assert!(!service.request.app_root.join("web-server.json").exists());

        let mut stream = TcpStream::connect(("127.0.0.1", endpoint.port)).unwrap();
        stream
            .write_all(b"GET /api/status HTTP/1.1\r\nHost: localhost\r\n\r\n")
            .unwrap();
        stream.shutdown(Shutdown::Write).unwrap();
        let mut response = String::new();
        stream.read_to_string(&mut response).unwrap();
        assert!(response.starts_with("HTTP/1.1 200"), "{response}");

        service.disable_web().unwrap();
        assert!(!service.web_on());
        assert!(TcpStream::connect(("127.0.0.1", endpoint.port)).is_err());
    }

    #[test]
    fn library_groups_readiness_is_exposed_in_the_env_snapshot() {
        let temp = tempfile::tempdir().unwrap();
        // Rooted probing mirrors the installer: candidates under the probe
        // root, sonames looked up inside each candidate directory.
        let root = temp.path();
        assert!(probe_device_path(Path::new("/usr/lib"), Some(root)).starts_with(root));
        assert_eq!(
            probe_device_path(Path::new("relative"), Some(root)),
            Path::new("relative")
        );
        // The fixture has no platform marker files, so it falls back to the
        // generic profile, whose frontend declares no library transforms: the
        // installer never enforces a library group there, so readiness must
        // not probe (and never cry wolf about) any group.
        let (_temp, service) = embedded_fixture();
        let snapshot = service.snapshot().unwrap();
        let document = snapshot.get("env").expect("snapshot exposes env");
        let groups = document.get("library_groups").and_then(Value::as_array);
        let groups = groups.expect("env_document must expose library_groups");
        assert!(
            groups.is_empty(),
            "generic profile references no library groups"
        );
    }

    #[test]
    fn destructive_data_removal_rejects_a_new_unselected_reference() {
        use appmanager_core::{InventoryEntry, InventoryKind, PortFact, RuntimeInventory};

        let data = PathBuf::from("/ports/data/shared");
        let port = |name: &str| PortFact {
            script: format!("{name}.sh"),
            path: PathBuf::from(format!("/ports/{name}.sh")),
            dir: "shared".into(),
            data_path: data.clone(),
            claimed_dir: "shared".into(),
            dir_exists: true,
            images: Vec::new(),
            runtime: String::new(),
            runtimes: Vec::new(),
        };
        let mut inventory = Inventory {
            schema: appmanager_core::INVENTORY_SCHEMA,
            entries: Vec::new(),
            ports: vec![port("A"), port("B"), port("C")],
            data_refcount: BTreeMap::from([(data.to_string_lossy().into_owned(), 3)]),
            data_dirs: vec![InventoryEntry {
                root: "game-dirs".into(),
                name: "shared".into(),
                path: data.clone(),
                kind: InventoryKind::Directory,
                bytes: None,
            }],
            images: Vec::new(),
            orphan_dirs: Vec::new(),
            orphan_images: Vec::new(),
            dead_scripts: Vec::new(),
            trash: Vec::new(),
            runtimes: RuntimeInventory {
                need: BTreeMap::new(),
                facts: Vec::new(),
            },
            apps: Vec::new(),
            diagnostics: Vec::new(),
            classification_uncertain: false,
        };
        let actions = vec![
            ServiceAction {
                kind: "TRASH".into(),
                argument: "/ports/A.sh".into(),
            },
            ServiceAction {
                kind: "TRASH".into(),
                argument: "/ports/B.sh".into(),
            },
            ServiceAction {
                kind: "TRASH".into(),
                argument: data.display().to_string(),
            },
        ];
        assert!(validate_destructive_inventory(&inventory, &actions).is_err());
        inventory.ports.pop();
        inventory
            .data_refcount
            .insert(data.to_string_lossy().into_owned(), 2);
        validate_destructive_inventory(&inventory, &actions).unwrap();
    }

    #[test]
    fn destructive_orphan_validation_matches_the_exact_inventory_path_not_its_name() {
        use appmanager_core::{InventoryEntry, InventoryKind};

        let selected = PathBuf::from("/ports/data/shared");
        let mut inventory = empty_inventory();
        inventory.data_dirs.push(InventoryEntry {
            root: "game-dirs".into(),
            name: "shared".into(),
            path: selected.clone(),
            kind: InventoryKind::Directory,
            bytes: None,
        });
        inventory.orphan_dirs.push(InventoryEntry {
            root: "game-dirs".into(),
            name: "shared".into(),
            path: PathBuf::from("/another-root/shared"),
            kind: InventoryKind::Directory,
            bytes: None,
        });
        let actions = vec![ServiceAction {
            kind: "TRASH".into(),
            argument: selected.display().to_string(),
        }];
        assert!(validate_destructive_inventory(&inventory, &actions).is_err());

        inventory.orphan_dirs[0].path = selected;
        validate_destructive_inventory(&inventory, &actions).unwrap();
    }

    #[test]
    fn embedded_apply_rejects_a_stale_inventory_revision() {
        let (_temp, service) = embedded_fixture();
        let snapshot = service.snapshot().unwrap();
        let current = snapshot
            .get("revision")
            .and_then(Value::as_str)
            .expect("embedded snapshot exposes a revision");
        assert_eq!(current.len(), 64);
        let mut session = Session::new_pinned(
            service.request.clone(),
            Arc::clone(&service.resolved),
            Arc::clone(&service.health),
        )
        .unwrap();
        let stale = if current.bytes().all(|byte| byte == b'0') {
            "1".repeat(64)
        } else {
            "0".repeat(64)
        };
        let error = apply_embedded_actions_at_revision(
            &mut session,
            &[EmbeddedAction {
                kind: "TRASH".to_owned(),
                arg: service
                    .resolved
                    .context
                    .roots
                    .scripts
                    .join("old.sh")
                    .display()
                    .to_string(),
                source_identity: None,
                replace_existing: false,
                password: None,
            }],
            Some(&stale),
        )
        .unwrap_err();
        assert!(error.contains("inventory changed"));
    }

    #[test]
    fn missing_controller_input_helper_is_reported() {
        let (_temp, service) = embedded_fixture();
        let error = service.start_input_helper("love.aarch64").unwrap_err();
        assert!(error.contains("controller input helper is missing"));
        assert!(
            service
                .input_helper
                .lock()
                .unwrap_or_else(|value| value.into_inner())
                .is_none()
        );
    }

    #[test]
    fn initial_snapshot_runs_as_a_task_and_populates_the_shared_cache() {
        let (_temp, service) = embedded_fixture();
        let task_id = service.start("initial-snapshot", None).unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        let event = loop {
            if let Some(event) = service.poll()
                && event.task_id == task_id
                && event.status != "progress"
            {
                break event;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "initial snapshot task did not finish"
            );
            std::thread::sleep(std::time::Duration::from_millis(5));
        };
        assert_eq!(event.kind, "initial-snapshot");
        assert_eq!(event.status, "complete");
        assert!(event.data.get("snapshot").is_some_and(Value::is_object));
        assert!(service.snapshot().unwrap().get("env").is_some());
    }

    #[test]
    fn transaction_recovery_is_limited_to_startup_and_mutating_tasks() {
        for kind in ["initial-snapshot", "apply", "install-zips"] {
            assert!(task_needs_recovery(kind), "{kind}");
        }
        for kind in [
            "inventory-refresh",
            "scan-zips",
            "update-check",
            "config-refresh-if-newer",
        ] {
            assert!(!task_needs_recovery(kind), "{kind}");
        }
    }

    #[test]
    fn config_refresh_cache_throttles_success_and_failure_without_trusting_future_time() {
        let cache = tempfile::NamedTempFile::new().unwrap();
        let now = 1_000_000_u64;

        fs::write(
            cache.path(),
            format!("{}\tok\n", now - CONFIG_REFRESH_SUCCESS_TTL_SECONDS + 1),
        )
        .unwrap();
        assert_eq!(
            fresh_config_refresh_status(cache.path(), now),
            Some("cached")
        );
        fs::write(
            cache.path(),
            format!("{}\tok\n", now - CONFIG_REFRESH_SUCCESS_TTL_SECONDS),
        )
        .unwrap();
        assert_eq!(fresh_config_refresh_status(cache.path(), now), None);

        fs::write(
            cache.path(),
            format!("{}\terror\n", now - CONFIG_REFRESH_ERROR_TTL_SECONDS + 1),
        )
        .unwrap();
        assert_eq!(
            fresh_config_refresh_status(cache.path(), now),
            Some("cached_error")
        );
        fs::write(cache.path(), format!("{}\terror\n", now + 1)).unwrap();
        assert_eq!(fresh_config_refresh_status(cache.path(), now), None);
    }

    #[test]
    fn network_actions_are_fully_validated_before_execution() {
        let (_temp, service) = embedded_fixture();
        let session = Session::new(service.request.clone()).unwrap();
        let actions = vec![
            ServiceAction {
                kind: "INSTALL_RUNTIME".into(),
                argument: "python_3.11".into(),
            },
            ServiceAction {
                kind: "UNKNOWN".into(),
                argument: "-".into(),
            },
        ];
        assert!(matches!(
            validate_network_actions(&session, &actions),
            Err("mixed-network-actions")
        ));

        let actions = vec![
            ServiceAction {
                kind: "INSTALL_RUNTIME".into(),
                argument: "python_3.11".into(),
            },
            ServiceAction {
                kind: "INSTALL_RUNTIME".into(),
                argument: "mono_6.12".into(),
            },
        ];
        let ValidatedNetworkActions::Runtimes(names) =
            validate_network_actions(&session, &actions).unwrap()
        else {
            panic!("Runtime actions were not classified as a Runtime batch");
        };
        assert_eq!(names, ["python_3.11", "mono_6.12"]);
    }

    #[test]
    fn runtime_architecture_mapping_is_read_from_config() {
        let (_temp, service) = embedded_fixture();
        let session = Session::new(service.request.clone()).unwrap();
        let mut config = session.resolved.config.clone();
        let system_arch = device_arch().to_ascii_lowercase();
        config
            .sources
            .get_mut("runtime")
            .and_then(Value::as_object_mut)
            .unwrap()
            .insert(
                "architectures".to_owned(),
                json!([{"id": "future_arch", "system_names": [system_arch]}]),
            );
        assert_eq!(
            configured_runtime_arch(&config, &device_arch()).unwrap(),
            "future_arch"
        );
    }

    #[test]
    fn embedded_actions_reject_unsafe_boundary_text() {
        let unsafe_action = EmbeddedAction {
            kind: "TRASH".into(),
            arg: "/ports/Game.sh\nDELETE_MANAGED\t/ports/Game".into(),
            source_identity: None,
            replace_existing: false,
            password: None,
        };
        assert!(ServiceAction::try_from(&unsafe_action).is_err());

        let valid_action = EmbeddedAction {
            kind: "TRASH".into(),
            arg: "/ports/Game.sh".into(),
            source_identity: None,
            replace_existing: false,
            password: None,
        };
        let parsed = ServiceAction::try_from(&valid_action).unwrap();
        assert_eq!(parsed.kind, "TRASH");
        assert_eq!(parsed.argument, "/ports/Game.sh");
    }

    #[test]
    fn embedded_archive_password_is_redacted_from_debug_output() {
        let action = EmbeddedAction {
            kind: "INSTALL_ZIP".into(),
            arg: "/media/encrypted.7z".into(),
            source_identity: Some("identity".into()),
            replace_existing: false,
            password: Some("never-print-this-password".into()),
        };
        let debug = format!("{action:?}");
        assert!(debug.contains("[REDACTED]"));
        assert!(!debug.contains("never-print-this-password"));
    }

    #[test]
    fn inventory_revision_ignores_nested_updates_but_detects_item_replacement() {
        let temp = tempfile::tempdir().unwrap();
        let game = temp.path().join("Game");
        fs::create_dir_all(game.join("saves")).unwrap();
        let script = temp.path().join("Game.sh");
        fs::write(&script, b"#!/bin/sh").unwrap();
        let save = game.join("saves/save.dat");
        fs::write(&save, b"old").unwrap();
        let mut report = empty_inventory();
        report.ports.push(appmanager_core::PortFact {
            script: "Game.sh".into(),
            path: script,
            dir: "Game".into(),
            data_path: game.clone(),
            claimed_dir: "Game".into(),
            dir_exists: true,
            images: Vec::new(),
            runtime: String::new(),
            runtimes: Vec::new(),
        });
        let before = inventory_revision(&report);
        fs::write(&save, b"new-save-data").unwrap();
        assert_eq!(before, inventory_revision(&report));

        let old_game = temp.path().join("Game.old");
        fs::rename(&game, &old_game).unwrap();
        fs::create_dir(&game).unwrap();
        assert_ne!(before, inventory_revision(&report));
    }

    #[test]
    fn inventory_revision_tracks_actionable_orphan_replacement() {
        use appmanager_core::{ImageFact, InventoryEntry, InventoryKind};

        let temp = tempfile::tempdir().unwrap();
        let directory = temp.path().join("orphan-data");
        let image = temp.path().join("orphan.png");
        fs::create_dir(&directory).unwrap();
        fs::write(&image, b"first").unwrap();
        let mut report = empty_inventory();
        report.orphan_dirs.push(InventoryEntry {
            root: "game-dirs".into(),
            name: "same-display-name".into(),
            path: directory.clone(),
            kind: InventoryKind::Directory,
            bytes: None,
        });
        report.orphan_images.push(ImageFact {
            name: "same-display-name.png".into(),
            path: image.clone(),
            is_dir: false,
        });
        let before = inventory_revision(&report);

        fs::rename(&directory, temp.path().join("old-data")).unwrap();
        fs::create_dir(&directory).unwrap();
        assert_ne!(before, inventory_revision(&report));

        let after_directory = inventory_revision(&report);
        fs::rename(&image, temp.path().join("old-image.png")).unwrap();
        fs::write(&image, b"second").unwrap();
        assert_ne!(after_directory, inventory_revision(&report));
    }

    #[test]
    fn embedded_zip_action_rejects_a_same_path_replacement() {
        let (temp, service) = embedded_fixture();
        let path = temp.path().join("game.zip");
        write_test_port_zip(&path, b"first");
        let scanned = appmanager_core::port_zip::inspect_zip_bundle(&path, &|| false).unwrap();
        fs::remove_file(&path).unwrap();
        write_test_port_zip(&path, b"second");
        let session = Session::new_pinned(
            service.request.clone(),
            Arc::clone(&service.resolved),
            Arc::clone(&service.health),
        )
        .unwrap();
        let error = session
            .install_zip_unlocked(
                &scanned.path,
                true,
                Some(&scanned.source_identity),
                false,
                None,
            )
            .unwrap_err();
        assert!(error.contains("changed after it was scanned"), "{error}");
    }

    #[test]
    fn stable_archive_validation_uses_the_download_candidate() {
        let temp = tempfile::NamedTempFile::new().unwrap();
        let mut archive = zip::ZipWriter::new(fs::File::create(temp.path()).unwrap());
        archive
            .start_file(
                "PortMaster/README",
                zip::write::SimpleFileOptions::default(),
            )
            .unwrap();
        std::io::Write::write_all(&mut archive, b"fixture").unwrap();
        archive.finish().unwrap();
        let digest = digest_file(temp.path(), DigestAlgorithm::Md5).unwrap();
        assert!(stable_archive_valid(temp.path(), &digest));
        assert!(!stable_archive_valid(
            temp.path(),
            "00000000000000000000000000000000"
        ));
    }

    #[test]
    fn runtime_partial_failure_reports_success_count_and_failed_names() {
        let names = vec!["mono".to_owned(), "godot".to_owned(), "love".to_owned()];
        let outcome = runtime_failure_outcome(&names, "download failed", |name| name != "godot");
        assert!(outcome.failed);
        assert_eq!(outcome.handled, 2);
        assert_eq!(outcome.failures, ["godot: download failed"]);
    }
}
