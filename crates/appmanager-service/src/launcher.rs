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
    ManagementMode, PROTECTED_SCRIPT_NAMES, RuntimeMetadata, RuntimeRepairRequest,
    SCAN_EXCLUDED_DIR_NAMES, apply_file_actions as apply_typed_file_actions, repair_runtimes,
};
use portkit_core::github::{Capability, GitHubTransport};
use portkit_core::{
    DigestAlgorithm, HealthReport, HealthStatus, digest_file, evaluate_health, zip_readable,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::resolution::{ConfigDirectories, DeviceResolution};

mod support;
use support::*;

const PORT_NAME: &str = "jenny92-appmanager";
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
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EmbeddedAction {
    pub kind: String,
    pub arg: String,
}

#[derive(Debug)]
struct Paths {
    source_dir: PathBuf,
    launcher: PathBuf,
    app_root: PathBuf,
    bin_dir: PathBuf,
    share_dir: PathBuf,
    config_dir: PathBuf,
    state: PathBuf,
    trash: PathBuf,
    update_cache: PathBuf,
    portmaster_lock: PathBuf,
    operation_lock: PathBuf,
    size_cache: PathBuf,
    runtime_metadata_json: PathBuf,
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
            size_cache: state.join("sizes.tsv"),
            runtime_metadata_json: state.join("ports.json"),
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

struct Session {
    paths: Paths,
    resolved: Arc<DeviceResolution>,
    root: Option<PathBuf>,
    cancel_token: Option<appmanager_core::CancellationToken>,
    progress_channel: Option<appmanager_core::ProgressChannel>,
    config_refresh_status: Option<String>,
    health: SharedHealth,
}

#[derive(Clone)]
struct HealthFacts {
    status: &'static str,
    report: Option<HealthReport>,
    python_ok: bool,
    system_python_ok: bool,
    python_imports: String,
}

type SharedHealth = Arc<Mutex<Option<HealthFacts>>>;
type BackgroundRunner =
    fn(&Request, &Arc<DeviceResolution>, &SharedHealth) -> Result<Value, (String, Value)>;

fn inventory_available(management: &ManagementMode, health: &str) -> bool {
    management == &ManagementMode::System || matches!(health, "healthy" | "damaged")
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
        let session =
            Session::new_pinned(request.clone(), Arc::clone(&resolved), Arc::clone(&health))?;
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
        })
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
        let session = Session::new_pinned(
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
        if kind == "config-refresh-if-newer" {
            if actions.is_some() {
                return Err(format!("task {kind:?} does not accept a payload"));
            }
            return self.start_background_config_refresh();
        }
        if kind == "update-check-if-stale" {
            if actions.is_some() {
                return Err(format!("task {kind:?} does not accept a payload"));
            }
            return self.start_background_update_check();
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
        let actions = if kind == "apply" {
            let actions = actions.unwrap_or_default();
            if actions.is_empty() {
                self.busy.store(false, Ordering::Release);
                return Err("APP Manager action list is empty".into());
            }
            Some(actions)
        } else {
            if actions.is_some() {
                self.busy.store(false, Ordering::Release);
                return Err(format!("task {kind:?} does not accept a payload"));
            }
            None
        };
        let supported = matches!(
            kind.as_str(),
            "apply" | "update-check" | "inventory-refresh"
        );
        if !supported {
            self.busy.store(false, Ordering::Release);
            return Err(format!("unsupported APP Manager task {kind:?}"));
        }
        self.active_task.store(task_id, Ordering::Release);
        let request = self.request.clone();
        let resolved = Arc::clone(&self.resolved);
        let health = Arc::clone(&self.health);
        let events = Arc::clone(&self.events);
        let snapshot = Arc::clone(&self.snapshot);
        let busy = Arc::clone(&self.busy);
        let active_task = Arc::clone(&self.active_task);
        self.cancel_token.reset();
        self.progress_channel.clear();
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

    pub fn cancel(&self) -> Result<(), String> {
        if !self.busy.load(Ordering::Acquire) {
            return Ok(());
        }
        self.cancel_token.cancel();
        Ok(())
    }
}

fn update_cache_value(path: &Path) -> Value {
    let (checked, status, latest) = read_update_cache(path);
    json!({
        "update_checked": checked,
        "update_status": status,
        "portmaster_latest": latest,
    })
}

fn run_background_update_check(
    request: &Request,
    resolved: &Arc<DeviceResolution>,
    health: &SharedHealth,
) -> Result<Value, (String, Value)> {
    let session = Session::new_pinned(request.clone(), Arc::clone(resolved), Arc::clone(health))
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
    let mut session =
        Session::new_pinned(request.clone(), Arc::clone(resolved), Arc::clone(health))
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
    cached_snapshot: &Mutex<Option<Value>>,
) -> Result<Value, String> {
    let mut session =
        Session::new_pinned(request.clone(), Arc::clone(resolved), Arc::clone(health))?;
    let outcome = (|| -> Result<(u8, OperationOutcome), String> {
        match kind {
            "apply" => execute_actions(&mut session, actions.unwrap_or_default())
                .map(|outcome| (0, outcome)),
            "update-check" => session
                .check_update(true)
                .map(|code| (code, OperationOutcome::default())),
            "inventory-refresh" => {
                session.refresh_inventory_state()?;
                let _ = fs::remove_file(&session.paths.size_cache);
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
    Ok(json!({
        "code": code,
        "operation": serde_json::to_value(operation).unwrap_or_else(|_| json!({})),
        "snapshot": snapshot,
    }))
}

#[derive(Clone, Debug, Default, Serialize)]
struct OperationOutcome {
    failed: bool,
    handled: usize,
    appledouble_removed: usize,
}

impl From<FileApplyOutcome> for OperationOutcome {
    fn from(value: FileApplyOutcome) -> Self {
        Self {
            failed: value.failures != 0,
            handled: value.handled,
            appledouble_removed: value.appledouble_removed,
        }
    }
}

fn read_size_cache(path: &Path) -> BTreeMap<String, u64> {
    fs::read_to_string(path)
        .ok()
        .map(|text| {
            text.lines()
                .filter_map(|line| {
                    let (bytes, path) = line.split_once('\t')?;
                    Some((path.to_owned(), bytes.parse().ok()?))
                })
                .collect()
        })
        .unwrap_or_default()
}

impl Session {
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
        Self::from_resolution(
            request,
            paths,
            Arc::new(resolved),
            root,
            Arc::new(Mutex::new(None)),
        )
    }

    fn new_pinned(
        request: Request,
        resolved: Arc<DeviceResolution>,
        health: SharedHealth,
    ) -> Result<Self, String> {
        let paths = Paths::new(&request);
        let root = env_path("PAM_NATIVE_ROOT");
        Self::from_resolution(request, paths, resolved, root, health)
    }

    fn from_resolution(
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
                "runtime_mount" => report
                    .python_runtime_image
                    .as_deref()
                    .is_some_and(squashfs_has_magic),
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
        if !self.capability("manage_ports") {
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
            "size_cache_ready": self.paths.size_cache.is_file(),
            "app_root": self.paths.app_root,
            "portmaster_health": health,
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
            "update_cache_file": self.paths.update_cache,
            "update_checked": update_checked,
            "update_status": update_status,
            "portmaster_latest": latest,
            "ignore_dirs": SCAN_EXCLUDED_DIR_NAMES.iter().copied().chain([PORT_NAME]).collect::<Vec<_>>(),
            "ignore_scripts": [PROTECTED_SCRIPT_NAMES[1], launcher_name(&self.paths.launcher), PROTECTED_SCRIPT_NAMES[2]],
            "self_port": PORT_NAME
        });
        values
            .as_object()
            .ok_or_else(|| "invalid environment snapshot".to_owned())?;
        Ok(values)
    }

    fn inventory_snapshot(&self) -> Result<Option<Inventory>, String> {
        if !self.capability("manage_ports") {
            return Ok(None);
        }
        Inventory::scan_with_options(&self.resolved.context, &self.inventory_options())
            .map(Some)
            .map_err(display_error)
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
        Ok(json!({
            "env": self.env_document()?,
            "inventory": inventory,
            "sizes": read_size_cache(&self.paths.size_cache),
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
        let arch = runtime_arch();
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
        resolved.insert("LOVE_LITE_FPS".into(), "6".into());
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
            .unwrap_or(40);
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
                self.config_refresh_status = Some("error".to_owned());
                return Err(display_error(error));
            }
        };
        self.config_refresh_status = Some(status.as_str().to_owned());
        Ok(0)
    }
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

fn execute_actions(
    session: &mut Session,
    embedded_actions: &[EmbeddedAction],
) -> Result<OperationOutcome, String> {
    let _guard = ActivityGuard::acquire(&session.paths.operation_lock)?;
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
            let current_references = inventory.refcount.get(&entry.name).copied().unwrap_or(0);
            let still_orphan = inventory.orphan_dirs.iter().any(|name| name == &entry.name);
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
        size_cache: Some(&session.paths.size_cache),
        self_launcher: &session.paths.launcher,
        self_port: PORT_NAME,
        privilege_command: privilege_command.as_deref(),
        privilege_arguments: &privilege_arguments,
        progress_channel: session.progress_channel.clone(),
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
            handled: runtime_names.len(),
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
        arch: runtime_arch(),
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
            let failures = runtime_names
                .iter()
                .filter(|name| !runtime_image_matches(session, &metadata, name))
                .count();
            Ok(OperationOutcome {
                failed: failures != 0,
                handled: runtime_names.len(),
                ..OperationOutcome::default()
            })
        }
    }
}

fn runtime_image_matches(session: &Session, metadata: &RuntimeMetadata, name: &str) -> bool {
    let Some(entry) = metadata.get(name, &runtime_arch()) else {
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
    if !source.install_allowed || !session.capability("install_portmaster") {
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
            let reason = if session.cancelled() {
                "cancelled"
            } else {
                "installer"
            };
            failure(reason)
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
        let progress = DownloadProgress::new(session.progress_channel.clone(), "PortMaster");
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
        launcher: session.paths.launcher.clone(),
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
        arch: runtime_arch(),
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

fn runtime_arch() -> String {
    match device_arch().to_ascii_lowercase().as_str() {
        "arm64" | "armv8" | "aarch64" => "aarch64".into(),
        "armv7" | "armv7l" => "armhf".into(),
        "amd64" | "x86_64" => "x86_64".into(),
        value => value.into(),
    }
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
        assert!(inventory_available(&ManagementMode::App, "healthy"));
        assert!(inventory_available(&ManagementMode::App, "damaged"));
        assert!(!inventory_available(&ManagementMode::App, "missing"));
        assert!(inventory_available(&ManagementMode::System, "missing"));
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
            schema: 3,
            entries: Vec::new(),
            ports: vec![port("A"), port("B"), port("C")],
            refcount: BTreeMap::from([("shared".into(), 3)]),
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
            diagnostics: Vec::new(),
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
        inventory.refcount.insert("shared".into(), 2);
        validate_destructive_inventory(&inventory, &actions).unwrap();
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
    fn embedded_actions_reject_unsafe_boundary_text() {
        let unsafe_action = EmbeddedAction {
            kind: "TRASH".into(),
            arg: "/ports/Game.sh\nDELETE_MANAGED\t/ports/Game".into(),
        };
        assert!(ServiceAction::try_from(&unsafe_action).is_err());

        let valid_action = EmbeddedAction {
            kind: "TRASH".into(),
            arg: "/ports/Game.sh".into(),
        };
        let parsed = ServiceAction::try_from(&valid_action).unwrap();
        assert_eq!(parsed.kind, "TRASH");
        assert_eq!(parsed.argument, "/ports/Game.sh");
    }

    #[test]
    fn size_cache_is_consumed_inside_the_native_service() {
        let temp = tempfile::NamedTempFile::new().unwrap();
        fs::write(temp.path(), "12\t/ports/Alpha.sh\n34\t/ports/Alpha\nbad\n").unwrap();
        assert_eq!(
            read_size_cache(temp.path()),
            BTreeMap::from([
                ("/ports/Alpha".to_owned(), 34),
                ("/ports/Alpha.sh".to_owned(), 12),
            ])
        );
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
}
