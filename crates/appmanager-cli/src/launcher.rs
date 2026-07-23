use std::collections::{BTreeMap, VecDeque};
use std::env;
use std::ffi::CString;
use std::fs;
use std::io::{Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitCode, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use appmanager_core::{
    FileApplyRequest, Inventory, InventoryOptions, ManagementMode, PendingValidationRequest,
    PendingValidationStatus, RuntimeMetadata, RuntimeRepairRequest, SizeScanRequest,
    apply_file_plan, plan_contains_only_file_actions, repair_runtimes, scan_size_cache,
    validate_pending_install,
};
use portkit_core::github::{Capability, GitHubTransport, Progress};
use portkit_core::{
    DigestAlgorithm, ExclusiveFileLock, HealthStatus, digest_file, evaluate_health, zip_readable,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::{ConfigDirectories, DeviceResolution};

const COMMAND: &str = "launcher-session";
const PORT_NAME: &str = "jenny92-appmanager";

#[derive(Clone)]
pub(crate) struct Request {
    pub source_dir: PathBuf,
    pub launcher: PathBuf,
    pub app_root: PathBuf,
    pub entry_arguments: Vec<String>,
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
    events: Arc<Mutex<VecDeque<ServiceEvent>>>,
    snapshot: Arc<Mutex<Option<Value>>>,
    next_task: Arc<AtomicU64>,
    busy: Arc<AtomicBool>,
    cancel_path: PathBuf,
    progress_path: PathBuf,
    last_progress: Arc<Mutex<String>>,
    input_helper: Arc<Mutex<Option<Child>>>,
    cancel_token: appmanager_core::CancellationToken,
    progress_channel: appmanager_core::ProgressChannel,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct EmbeddedAction {
    kind: String,
    arg: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Mode {
    ApplyPlan,
    ScanSizes,
    HealthCheck,
    CheckUpdate,
    ForceCheckUpdate,
    ValidatePending,
    RefreshRuntimeMetadata,
    WriteInstallPlan,
    RefreshDeviceConfig,
    WriteEnv,
    RefreshInventory,
}

impl Mode {
    fn parse(arguments: &[String]) -> Result<Self, String> {
        if arguments.len() > 1 {
            return Err("launcher session accepts at most one mode argument".into());
        }
        match arguments.first().map(String::as_str).unwrap_or("") {
            "" => Err("launcher-session is diagnostic-only and requires an explicit mode".into()),
            "--apply-plan" => Ok(Self::ApplyPlan),
            "--scan-sizes" => Ok(Self::ScanSizes),
            "--health-check" => Ok(Self::HealthCheck),
            "--check-pm-update" => Ok(Self::CheckUpdate),
            "--check-pm-update-force" => Ok(Self::ForceCheckUpdate),
            "--validate-pending" => Ok(Self::ValidatePending),
            "--refresh-runtime-metadata" => Ok(Self::RefreshRuntimeMetadata),
            "--write-install-plan" => Ok(Self::WriteInstallPlan),
            "--refresh-device-config" => Ok(Self::RefreshDeviceConfig),
            "--write-env" => Ok(Self::WriteEnv),
            "--refresh-inventory" => Ok(Self::RefreshInventory),
            value => Err(format!("unsupported launcher mode {value:?}")),
        }
    }
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
    plan: PathBuf,
    result: PathBuf,
    progress: PathBuf,
    cancel: PathBuf,
    update_cache: PathBuf,
    validation_result: PathBuf,
    portmaster_active: PathBuf,
    portmaster_lock: PathBuf,
    operation_active: PathBuf,
    operation_lock: PathBuf,
    size_cache: PathBuf,
    runtime_metadata_tsv: PathBuf,
    runtime_metadata_json: PathBuf,
    remote_config_dir: PathBuf,
    remote_config: PathBuf,
    config_refresh_result: PathBuf,
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
            plan: state.join("plan.txt"),
            result: state.join("result.txt"),
            progress: state.join("progress.tsv"),
            cancel: state.join("cancel.request"),
            update_cache: state.join("portmaster-update.tsv"),
            validation_result: state.join("validation-result.tsv"),
            portmaster_active: state.join("portmaster-active.tsv"),
            portmaster_lock: state.join("portmaster-active.lock"),
            operation_active: state.join("operation-active.tsv"),
            operation_lock: state.join("operation-active.lock"),
            size_cache: state.join("sizes.tsv"),
            runtime_metadata_tsv: state.join("runtime-metadata.tsv"),
            runtime_metadata_json: state.join("ports.json"),
            remote_config: remote_config_dir.join("config.json"),
            config_refresh_result: state.join("config-refresh.tsv"),
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
    config_directories: ConfigDirectories,
    resolved: DeviceResolution,
    root: Option<PathBuf>,
    target_override: Option<PathBuf>,
    cancel_token: Option<appmanager_core::CancellationToken>,
    progress_channel: Option<appmanager_core::ProgressChannel>,
}

pub(crate) fn run(request: Request) -> ExitCode {
    let mode = match Mode::parse(&request.entry_arguments) {
        Ok(mode) => mode,
        Err(error) => return fail(64, &error),
    };
    let mut session = match Session::new(request) {
        Ok(session) => session,
        Err(error) => return fail(78, &error),
    };
    match session.execute(mode) {
        Ok(code) => exit_code(code),
        Err(error) => {
            session.log(&error);
            fail(1, &error)
        }
    }
}

impl EmbeddedService {
    pub fn new(request: EmbeddedRequest) -> Result<Self, String> {
        let cancel_token = appmanager_core::CancellationToken::default();
        let progress_channel = appmanager_core::ProgressChannel::default();
        let request = Request {
            source_dir: request.source_dir,
            launcher: request.launcher,
            app_root: request.app_root,
            entry_arguments: Vec::new(),
            config_directories: ConfigDirectories {
                embedded: request.config_dir,
                remote: request.remote_config_dir,
            },
            cancel_token: Some(cancel_token.clone()),
            progress_channel: Some(progress_channel.clone()),
        };
        let paths = Paths::new(&request);
        let session = Session::new(request.clone())?;
        session.cleanup_stale_activity();
        session.sync_artwork();
        Ok(Self {
            request,
            events: Arc::new(Mutex::new(VecDeque::new())),
            snapshot: Arc::new(Mutex::new(None)),
            next_task: Arc::new(AtomicU64::new(1)),
            busy: Arc::new(AtomicBool::new(false)),
            cancel_path: paths.cancel,
            progress_path: paths.progress,
            last_progress: Arc::new(Mutex::new(String::new())),
            input_helper: Arc::new(Mutex::new(None)),
            cancel_token,
            progress_channel,
        })
    }

    pub fn process_environment(&self) -> Result<BTreeMap<String, String>, String> {
        let session = Session::new(self.request.clone())?;
        session.love_environment()
    }

    pub fn start_input_helper(&self, process_name: &str) {
        let helper = self.request.app_root.join("bin/gptokeyb");
        if !helper.is_file() {
            return;
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
        let child = command
            .arg(process_name)
            .arg("-c")
            .arg(self.request.app_root.join("love_ui/ui.gptk"))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .ok();
        *self
            .input_helper
            .lock()
            .unwrap_or_else(|value| value.into_inner()) = child;
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
        let session = Session::new(self.request.clone())?;
        let snapshot = session.embedded_snapshot(None)?;
        *self
            .snapshot
            .lock()
            .unwrap_or_else(|value| value.into_inner()) = Some(snapshot.clone());
        Ok(snapshot)
    }

    pub fn start(&self, kind: &str, payload: &str) -> Result<u64, String> {
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
            let actions: Vec<EmbeddedAction> = match serde_json::from_str(payload) {
                Ok(actions) => actions,
                Err(error) => {
                    self.busy.store(false, Ordering::Release);
                    return Err(format!("invalid APP Manager action list: {error}"));
                }
            };
            if actions.is_empty() {
                self.busy.store(false, Ordering::Release);
                return Err("APP Manager action list is empty".into());
            }
            Some(actions)
        } else {
            if !payload.is_empty() && payload != "{}" && payload != "null" {
                self.busy.store(false, Ordering::Release);
                return Err(format!("task {kind:?} does not accept a payload"));
            }
            None
        };
        let supported = matches!(
            kind.as_str(),
            "apply"
                | "config-refresh"
                | "update-check"
                | "update-check-if-stale"
                | "validate-pending"
                | "runtime-metadata"
                | "scan-sizes"
        );
        if !supported {
            self.busy.store(false, Ordering::Release);
            return Err(format!("unsupported APP Manager task {kind:?}"));
        }
        let request = self.request.clone();
        let events = Arc::clone(&self.events);
        let snapshot = Arc::clone(&self.snapshot);
        let busy = Arc::clone(&self.busy);
        let progress = self.progress_path.clone();
        let cancel = self.cancel_path.clone();
        self.last_progress
            .lock()
            .unwrap_or_else(|value| value.into_inner())
            .clear();
        self.cancel_token.reset();
        self.progress_channel.clear();
        let _ = fs::remove_file(&progress);
        let _ = fs::remove_file(&cancel);
        std::thread::Builder::new()
            .name(format!("appmanager-{kind}"))
            .spawn(move || {
                let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    run_embedded_task(&request, &kind, actions.as_deref(), &snapshot)
                }))
                .unwrap_or_else(|_| Err("APP Manager task stopped unexpectedly".into()));
                let event = match outcome {
                    Ok(data) => ServiceEvent {
                        task_id,
                        kind,
                        status: "complete".into(),
                        data,
                    },
                    Err(message) => ServiceEvent {
                        task_id,
                        kind,
                        status: "error".into(),
                        data: json!({"message": message}),
                    },
                };
                let _ = fs::remove_file(&progress);
                let _ = fs::remove_file(&cancel);
                events
                    .lock()
                    .unwrap_or_else(|value| value.into_inner())
                    .push_back(event);
                busy.store(false, Ordering::Release);
            })
            .map_err(|error| {
                self.busy.store(false, Ordering::Release);
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
        if let Some(progress) = self.progress_channel.take() {
            return Some(ServiceEvent {
                task_id: self.next_task.load(Ordering::Relaxed).saturating_sub(1),
                kind: "progress".into(),
                status: "progress".into(),
                data: serde_json::to_value(progress).unwrap_or_else(|_| json!({})),
            });
        }
        let text = fs::read_to_string(&self.progress_path).ok()?;
        let mut previous = self
            .last_progress
            .lock()
            .unwrap_or_else(|value| value.into_inner());
        if *previous == text {
            return None;
        }
        *previous = text.clone();
        Some(ServiceEvent {
            task_id: self.next_task.load(Ordering::Relaxed).saturating_sub(1),
            kind: "progress".into(),
            status: "progress".into(),
            data: progress_value(&text),
        })
    }

    pub fn cancel(&self) -> Result<(), String> {
        if !self.busy.load(Ordering::Acquire) {
            return Ok(());
        }
        self.cancel_token.cancel();
        Ok(())
    }
}

fn run_embedded_task(
    request: &Request,
    kind: &str,
    actions: Option<&[EmbeddedAction]>,
    cached_snapshot: &Mutex<Option<Value>>,
) -> Result<Value, String> {
    let mut session = Session::new(request.clone())?;
    session.cleanup_stale_activity();
    let code = match kind {
        "apply" => {
            write_embedded_plan(&session.paths.plan, actions.unwrap_or_default())?;
            session.apply_plan()?
        }
        "config-refresh" => session.refresh_device_config()?,
        "update-check" => session.check_update(true)?,
        "update-check-if-stale" => session.check_update(false)?,
        "validate-pending" => session.validate_pending()?,
        "runtime-metadata" => session.refresh_runtime_metadata(true)?,
        "scan-sizes" => session.scan_sizes()?,
        _ => return Err(format!("unsupported APP Manager task {kind:?}")),
    };
    session.reload()?;
    let result = fs::read_to_string(&session.paths.result).unwrap_or_default();
    let validation = fs::read_to_string(&session.paths.validation_result).unwrap_or_default();
    let config_refresh =
        fs::read_to_string(&session.paths.config_refresh_result).unwrap_or_default();
    let reuse_inventory = if matches!(kind, "apply" | "config-refresh") {
        session.persisted_inventory()
    } else if matches!(
        kind,
        "update-check" | "update-check-if-stale" | "runtime-metadata" | "scan-sizes"
    ) {
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
    let _ = fs::remove_file(&session.paths.result);
    let _ = fs::remove_file(&session.paths.validation_result);
    let _ = fs::remove_file(&session.paths.config_refresh_result);
    Ok(json!({
        "code": code,
        "result": result,
        "validation": validation,
        "config_refresh": config_refresh,
        "snapshot": snapshot,
    }))
}

fn write_embedded_plan(path: &Path, actions: &[EmbeddedAction]) -> Result<(), String> {
    let mut rendered = String::from("# APP Manager recovery plan v1\n");
    for action in actions {
        if action.kind.is_empty()
            || action.arg.contains(['\t', '\r', '\n', '\0'])
            || !action
                .kind
                .bytes()
                .all(|byte| byte.is_ascii_uppercase() || byte == b'_')
        {
            return Err("APP Manager action contains unsafe text".into());
        }
        rendered.push_str(&action.kind);
        rendered.push('\t');
        rendered.push_str(&action.arg);
        rendered.push('\n');
    }
    write_text(path, &rendered)
}

fn progress_value(text: &str) -> Value {
    let fields = text.trim_end().split('\t').collect::<Vec<_>>();
    if fields.len() < 9 || fields[0] != "1" {
        return json!({});
    }
    json!({
        "phase": fields[1],
        "runtime": fields[2],
        "index": fields[3].parse::<u64>().unwrap_or(0),
        "count": fields[4].parse::<u64>().unwrap_or(0),
        "current": fields[5].parse::<u64>().unwrap_or(0),
        "total": fields[6].parse::<u64>().unwrap_or(0),
        "speed": fields[7].parse::<u64>().unwrap_or(0),
        "detail": fields[8],
    })
}

impl Session {
    fn new(request: Request) -> Result<Self, String> {
        let paths = Paths::new(&request);
        if !paths.app_root.is_dir() {
            return Err(format!(
                "APP Manager directory is missing: {}",
                paths.app_root.display()
            ));
        }
        fs::create_dir_all(&paths.state).map_err(display_error)?;
        fs::create_dir_all(&paths.trash).map_err(display_error)?;
        let root = env_path("PAM_NATIVE_ROOT");
        let target_override = normalized_target_override(root.as_deref());
        let mut config_directories = request.config_directories;
        config_directories
            .embedded
            .get_or_insert_with(|| paths.config_dir.clone());
        config_directories
            .remote
            .get_or_insert_with(|| paths.remote_config_dir.clone());
        let resolved = resolve(
            &paths,
            root.clone(),
            target_override.clone(),
            &config_directories,
        )?;
        Ok(Self {
            paths,
            config_directories,
            resolved,
            root,
            target_override,
            cancel_token: request.cancel_token,
            progress_channel: request.progress_channel,
        })
    }

    fn execute(&mut self, mode: Mode) -> Result<u8, String> {
        self.cleanup_stale_activity();
        match mode {
            Mode::ApplyPlan => self.apply_plan(),
            Mode::ScanSizes => self.scan_sizes(),
            Mode::HealthCheck => {
                let health = self.health_status()?;
                println!(
                    "{}\t{}\t{}\t{}",
                    health,
                    self.core_version().unwrap_or_default(),
                    self.resolved.resolution.device_class,
                    self.portmaster_root()
                        .map_or_else(String::new, |path| path.display().to_string())
                );
                Ok(0)
            }
            Mode::CheckUpdate => self.check_update(false),
            Mode::ForceCheckUpdate => self.check_update(true),
            Mode::ValidatePending => self.validate_pending(),
            Mode::RefreshRuntimeMetadata => self.refresh_runtime_metadata(false),
            Mode::WriteInstallPlan => self.write_install_plan(),
            Mode::RefreshDeviceConfig => self.refresh_device_config(),
            Mode::WriteEnv => {
                self.write_env()?;
                Ok(0)
            }
            Mode::RefreshInventory => {
                self.refresh_inventory()?;
                Ok(0)
            }
        }
    }

    fn reload(&mut self) -> Result<(), String> {
        self.resolved = resolve(
            &self.paths,
            self.root.clone(),
            self.target_override.clone(),
            &self.config_directories,
        )?;
        Ok(())
    }

    fn log(&self, message: &str) {
        let path = self.paths.app_root.join("log.txt");
        if let Ok(mut file) = fs::OpenOptions::new().create(true).append(true).open(path) {
            let _ = writeln!(file, "[PAM] {message}");
        }
    }

    fn portmaster_root(&self) -> Option<&Path> {
        self.resolved.context.roots.portmaster.as_deref()
    }

    fn cancelled(&self) -> bool {
        self.cancel_token
            .as_ref()
            .is_some_and(appmanager_core::CancellationToken::is_cancelled)
            || self.paths.cancel.exists()
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

    fn health_status(&self) -> Result<&'static str, String> {
        if !self.portmaster_root().is_some_and(Path::is_dir) {
            return Ok("missing");
        }
        let report = evaluate_health(&self.resolved.resolution).map_err(display_error)?;
        let python_ready = match report.python_mode.as_str() {
            "system" => python_imports_ready(&report.python_imports),
            "runtime_mount" => report
                .python_runtime_image
                .as_deref()
                .is_some_and(squashfs_has_magic),
            "" => true,
            _ => false,
        };
        Ok(match report.status {
            HealthStatus::Unresolved => "missing",
            HealthStatus::Damaged => "damaged",
            HealthStatus::Healthy if python_ready => "healthy",
            HealthStatus::Healthy => "damaged",
        })
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
            scan_script_images: self.resolved.resolution.platform_id == "miniloong",
            ignore_dirs: ["PortMaster", "autoinstall", "images", PORT_NAME]
                .into_iter()
                .map(str::to_owned)
                .collect(),
            ignore_scripts: [
                "PortMaster.sh",
                launcher_name(&self.paths.launcher),
                ".port.sh",
            ]
            .into_iter()
            .map(str::to_owned)
            .collect(),
            self_port: Some(PORT_NAME.into()),
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
        let inventory = Inventory::scan_with_options(
            &self.resolved.context,
            Default::default(),
            &self.inventory_options(),
        )
        .map_err(display_error)?;
        write_json(&self.paths.inventory, &inventory)
    }

    fn refresh_inventory_if_available(&self, health: &str) -> Result<(), String> {
        if self.resolved.context.management == ManagementMode::System || health == "healthy" {
            self.refresh_inventory()
        } else {
            let _ = fs::remove_file(&self.paths.inventory);
            Ok(())
        }
    }

    fn env_document(&self) -> Result<Value, String> {
        let health = self.health_status()?;
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
            "scan_script_images": self.resolved.resolution.platform_id == "miniloong",
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
            "size_file": self.paths.size_cache,
            "runtime_metadata_file": self.paths.runtime_metadata_tsv,
            "app_root": self.paths.app_root,
            "portmaster_health": health,
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
            "device_class": self.resolved.resolution.device_class,
            "target_confirmed": if self.resolved.resolution.target_confirmed { "1" } else { "0" },
            "pending_install": self.paths.state.join("pending-install.tsv"),
            "install_transaction": self.paths.state.join("install-transaction.tsv"),
            "portmaster_active": self.paths.portmaster_active,
            "operation_active": self.paths.operation_active,
            "update_cache_file": self.paths.update_cache,
            "update_checked": update_checked,
            "update_status": update_status,
            "portmaster_latest": latest,
            "ignore_dirs": ["PortMaster", "autoinstall", "images", PORT_NAME],
            "ignore_scripts": ["PortMaster.sh", launcher_name(&self.paths.launcher), ".port.sh"],
            "self_port": PORT_NAME
        });
        values
            .as_object()
            .ok_or_else(|| "invalid environment snapshot".to_owned())?;
        Ok(values)
    }

    fn write_env(&self) -> Result<(), String> {
        write_json(&self.paths.state.join("env.json"), &self.env_document()?)
    }

    fn inventory_snapshot(&self) -> Result<Option<Inventory>, String> {
        if !self.capability("manage_ports") {
            return Ok(None);
        }
        Inventory::scan_with_options(
            &self.resolved.context,
            Default::default(),
            &self.inventory_options(),
        )
        .map(Some)
        .map_err(display_error)
    }

    fn persisted_inventory(&self) -> Option<Value> {
        let bytes = fs::read(&self.paths.inventory).ok()?;
        serde_json::from_slice(&bytes).ok()
    }

    fn embedded_snapshot(&self, reusable_inventory: Option<Value>) -> Result<Value, String> {
        let health = self.health_status()?;
        let inventory = if self.resolved.context.management == ManagementMode::System
            || health == "healthy"
        {
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
        }))
    }

    fn refresh_inventory_state(&self) -> Result<(), String> {
        let health = self.health_status()?;
        self.refresh_inventory_if_available(health)
    }

    fn cleanup_stale_activity(&self) {
        cleanup_marker(&self.paths.operation_lock, &self.paths.operation_active);
        cleanup_marker(&self.paths.portmaster_lock, &self.paths.portmaster_active);
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

    fn scan_sizes(&self) -> Result<u8, String> {
        scan_size_cache(&SizeScanRequest {
            context: &self.resolved.context,
            output: &self.paths.size_cache,
            self_port: PORT_NAME,
        })
        .map_err(display_error)?;
        Ok(0)
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

    fn refresh_runtime_metadata(&self, force: bool) -> Result<u8, String> {
        if !self.capability("repair_runtimes") {
            return Ok(0);
        }
        refresh_runtime_metadata_cache(self, force)?;
        Ok(0)
    }

    fn write_install_plan(&self) -> Result<u8, String> {
        let source = self.source()?;
        if !source.install_allowed || !self.capability("install_portmaster") {
            return Err("PortMaster installation is disabled by the device configuration".into());
        }
        let plan = appmanager_core::InstallPlan::from_context(&self.resolved.context)
            .map_err(display_error)?;
        plan.validate(&self.resolved.context)
            .map_err(display_error)?;
        print!("{}", plan.to_tsv().map_err(display_error)?);
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
        detection.target_override = self.target_override.clone();
        let status = portkit_core::refresh_config(&portkit_core::ConfigRefreshRequest {
            source,
            packaged_root: self.paths.config_dir.join("config.json"),
            packaged_dir: self.paths.config_dir.clone(),
            cached_root: self.paths.remote_config.clone(),
            cache_dir: self.paths.remote_config_dir.clone(),
            timeout: std::time::Duration::from_secs(timeout),
            detection,
        })
        .map_err(display_error)?;
        write_text(
            &self.paths.config_refresh_result,
            &format!("1\t{}\n", status.as_str()),
        )?;
        self.reload()?;
        self.refresh_inventory_state()?;
        Ok(0)
    }

    fn validate_pending(&self) -> Result<u8, String> {
        let health = self.health_status()?;
        let plan = appmanager_core::InstallPlan::from_context(&self.resolved.context)
            .map_err(display_error)?
            .validate(&self.resolved.context)
            .map_err(display_error)?;
        let outcome = validate_pending_install(&PendingValidationRequest {
            state_dir: self.paths.state.clone(),
            plan,
            core_health_healthy: health == "healthy" && self.core_version().is_some(),
            interrupt_before_mutation: false,
            fail_restore_after: None,
        })
        .map_err(display_error)?;
        let code = match outcome.status {
            PendingValidationStatus::Valid | PendingValidationStatus::None => 0,
            PendingValidationStatus::Interrupted => 75,
            PendingValidationStatus::Restored | PendingValidationStatus::NoUsable => 1,
        };
        Ok(code)
    }

    fn apply_plan(&mut self) -> Result<u8, String> {
        execute_plan(self)
    }
}

fn resolve(
    paths: &Paths,
    root: Option<PathBuf>,
    target_override: Option<PathBuf>,
    config_directories: &ConfigDirectories,
) -> Result<DeviceResolution, String> {
    super::resolve_device_context(
        COMMAND,
        paths.launcher.clone(),
        paths.state.clone(),
        paths.trash.clone(),
        paths
            .remote_config
            .is_file()
            .then(|| paths.remote_config.clone()),
        target_override,
        root,
        Vec::new(),
        config_directories,
    )
    .map_err(|error| error.message)
}

fn execute_plan(session: &mut Session) -> Result<u8, String> {
    let _guard = ActivityGuard::acquire(
        &session.paths.operation_lock,
        &session.paths.operation_active,
    )?;
    let actions = read_plan(&session.paths.plan)?;
    write_text(&session.paths.result, "")?;
    let _ = fs::remove_file(&session.paths.progress);
    let _ = fs::remove_file(progress_temporary(&session.paths.progress));

    let file_only = plan_contains_only_file_actions(&session.paths.plan).map_err(display_error)?;
    let has_file_actions = actions.iter().any(|action| is_file_action(&action.kind));
    if file_only {
        apply_file_actions(session)?;
    } else if has_file_actions {
        append_result(&session.paths.result, "FAIL\toperation\tmixed-file-plan\n")?;
    } else {
        apply_network_actions(session, &actions)?;
    }

    unsafe { libc::sync() };
    session.reload()?;
    let health = session.health_status()?;
    session.refresh_inventory_if_available(health)?;
    fs::remove_file(&session.paths.plan).map_err(display_error)?;
    Ok(0)
}

#[derive(Clone, Debug)]
struct PlanAction {
    kind: String,
    argument: String,
}

fn read_plan(path: &Path) -> Result<Vec<PlanAction>, String> {
    let text = fs::read_to_string(path).map_err(display_error)?;
    let mut actions = Vec::new();
    for (index, line) in text.lines().enumerate() {
        if line.trim().is_empty() || line.starts_with('#') {
            continue;
        }
        let fields = line.split('\t').collect::<Vec<_>>();
        if fields.len() != 2 || fields.iter().any(|field| field.contains(['\r', '\n'])) {
            return Err(format!("invalid plan row {}", index + 1));
        }
        actions.push(PlanAction {
            kind: fields[0].to_owned(),
            argument: fields[1].to_owned(),
        });
    }
    if actions.is_empty() {
        return Err("operation plan is empty".into());
    }
    Ok(actions)
}

fn is_file_action(kind: &str) -> bool {
    matches!(
        kind,
        "TRASH"
            | "DELETE_MANAGED"
            | "EMPTY_TRASH"
            | "RESTORE_TRASH"
            | "RESTORE_ITEM"
            | "DELETE_ITEM"
            | "CLEAN_APPLEDOUBLE"
    )
}

fn apply_file_actions(session: &Session) -> Result<(), String> {
    let (privilege_command, privilege_arguments) = privilege_command();
    apply_file_plan(&FileApplyRequest {
        context: &session.resolved.context,
        plan: &session.paths.plan,
        result: &session.paths.result,
        size_cache: Some(&session.paths.size_cache),
        self_launcher: &session.paths.launcher,
        self_port: PORT_NAME,
        privilege_command: privilege_command.as_deref(),
        privilege_arguments: &privilege_arguments,
        progress_file: Some(&session.paths.progress),
    })
    .map_err(display_error)?;
    Ok(())
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

fn apply_network_actions(session: &Session, actions: &[PlanAction]) -> Result<(), String> {
    let runtime_names = actions
        .iter()
        .filter(|action| action.kind == "INSTALL_RUNTIME")
        .map(|action| action.argument.clone())
        .collect::<Vec<_>>();
    if !runtime_names.is_empty() {
        repair_runtime_batch(session, &runtime_names)?;
    }

    let mut risk_ack = false;
    let mut support_ack = false;
    for action in actions {
        match action.kind.as_str() {
            "INSTALL_RUNTIME" => {}
            "ACK_DEVICE_RISK"
                if action.argument == session.resolved.resolution.device_class
                    && matches!(
                        action.argument.as_str(),
                        "official-untested" | "unsupported-known"
                    ) =>
            {
                risk_ack = true;
            }
            "ACK_DEVICE_SUPPORT"
                if session.resolved.resolution.device_class == "unsupported-known"
                    && session
                        .portmaster_root()
                        .is_some_and(|path| path == Path::new(&action.argument)) =>
            {
                support_ack = true;
            }
            "ACK_DEVICE_RISK" => append_result(
                &session.paths.result,
                "FAIL\tportmaster\tinvalid-device-ack\n",
            )?,
            "ACK_DEVICE_SUPPORT" => append_result(
                &session.paths.result,
                "FAIL\tportmaster\tinvalid-support-ack\n",
            )?,
            "INSTALL_PORTMASTER" => {
                install_portmaster_action(session, action, risk_ack, support_ack)?;
            }
            _ => {
                append_result(&session.paths.result, "FAIL\toperation\tunknown-action\n")?;
            }
        }
    }
    Ok(())
}

fn repair_runtime_batch(session: &Session, runtime_names: &[String]) -> Result<(), String> {
    if !session.capability("repair_runtimes") {
        for name in runtime_names {
            append_result(
                &session.paths.result,
                &format!("FAIL\truntime\t{name}\tcapability-disabled\n"),
            )?;
        }
        return Ok(());
    }
    refresh_runtime_metadata_cache(session, true)?;
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
        progress_file: session.paths.progress.clone(),
        cancel_file: session
            .cancel_token
            .is_none()
            .then(|| session.paths.cancel.clone()),
        cancel_token: session.cancel_token.clone(),
        progress_channel: session.progress_channel.clone(),
    });
    match outcome {
        Ok(_) => {
            for name in runtime_names {
                append_result(
                    &session.paths.result,
                    &format!("OK\truntime\t{name}\tnative\n"),
                )?;
            }
        }
        Err(error) => {
            session.log(&format!("Runtime repair failed: {error}"));
            let metadata = RuntimeMetadata::parse(
                &fs::read(&session.paths.runtime_metadata_json).map_err(display_error)?,
            )
            .map_err(display_error)?;
            for name in runtime_names {
                let valid = runtime_image_matches(session, &metadata, name);
                append_result(
                    &session.paths.result,
                    &format!(
                        "{}\truntime\t{name}\t{}\n",
                        if valid { "OK" } else { "FAIL" },
                        if session.cancelled() {
                            "cancelled"
                        } else {
                            "repair"
                        }
                    ),
                )?;
            }
        }
    }
    Ok(())
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
    action: &PlanAction,
    risk_ack: bool,
    support_ack: bool,
) -> Result<(), String> {
    let failure = |reason: &str| {
        append_result(
            &session.paths.result,
            &format!("FAIL\tportmaster\t{reason}\n"),
        )
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
        Ok(()) => append_result(
            &session.paths.result,
            "OK\tportmaster\tpending-validation\n",
        ),
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
    let _guard = ActivityGuard::acquire(
        &session.paths.portmaster_lock,
        &session.paths.portmaster_active,
    )?;
    let _ = fs::remove_file(&session.paths.cancel);
    write_progress(
        &session.paths.progress,
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
    let valid = || {
        archive.is_file()
            && digest_file(&archive, DigestAlgorithm::Md5)
                .is_ok_and(|digest| digest.eq_ignore_ascii_case(&expected_md5))
            && zip_readable(&archive).unwrap_or(false)
    };
    if !valid() {
        let _ = fs::remove_file(&archive);
        let progress = DownloadProgress::new(
            session.paths.progress.clone(),
            session.progress_channel.clone(),
            "PortMaster",
        );
        GitHubTransport::new()
            .fetch(
                Capability::Release,
                &url,
                &archive,
                |_| valid(),
                Some(&progress),
                None,
            )
            .map_err(display_error)?;
    }
    if !valid() {
        let _ = fs::remove_file(&archive);
        return Err("downloaded PortMaster archive failed verification".into());
    }
    if session.cancelled() {
        return Err("PortMaster installation was cancelled".into());
    }
    write_progress(
        &session.paths.progress,
        session.progress_channel.as_ref(),
        "installing",
        88,
        100,
        0,
        "Installing PortMaster",
    )?;
    install_archive(session, archive)?;
    for name in [
        "pending-install.tsv",
        "pending-manifest.tsv",
        "pending-frontend-manifest.tsv",
    ] {
        if !session.paths.state.join(name).exists() {
            return Err(format!("installation did not publish {name}"));
        }
    }
    write_progress(
        &session.paths.progress,
        session.progress_channel.as_ref(),
        "complete",
        100,
        100,
        0,
        &format!("PortMaster {version} installed; reopen required"),
    )?;
    Ok(())
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
        cancel_file: session
            .cancel_token
            .is_none()
            .then(|| session.paths.cancel.clone()),
        cancel_token: session.cancel_token.clone(),
        progress_channel: session.progress_channel.clone(),
        probe_root: session.root.clone(),
        plan,
        fail_after_backup: false,
        fail_restore_after: None,
    })
    .map(|_| ())
    .map_err(display_error)
}

fn ensure_python_runtime(session: &Session) -> Result<(), String> {
    let report = evaluate_health(&session.resolved.resolution).map_err(display_error)?;
    if report.python_mode != "runtime_mount" || python_imports_ready(&report.python_imports) {
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
    refresh_runtime_metadata_cache(session, true)?;
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
        progress_file: session.paths.progress.clone(),
        cancel_file: session
            .cancel_token
            .is_none()
            .then(|| session.paths.cancel.clone()),
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
        tsv_cache: session.paths.runtime_metadata_tsv.clone(),
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

struct ActivityGuard {
    _lock: ExclusiveFileLock,
    marker: PathBuf,
}

impl ActivityGuard {
    fn acquire(lock: &Path, marker: &Path) -> Result<Self, String> {
        let lock = ExclusiveFileLock::try_acquire(lock).map_err(|error| {
            if error.kind() == std::io::ErrorKind::WouldBlock {
                "another APP Manager operation is already running".to_owned()
            } else {
                error.to_string()
            }
        })?;
        let started = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        write_text(
            marker,
            &format!(
                "version\t1\npid\t{}\nstarted\t{started}\n",
                std::process::id()
            ),
        )?;
        Ok(Self {
            _lock: lock,
            marker: marker.to_path_buf(),
        })
    }
}

impl Drop for ActivityGuard {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.marker);
    }
}

struct DownloadProgress {
    path: PathBuf,
    channel: Option<appmanager_core::ProgressChannel>,
    runtime: &'static str,
    state: Mutex<(Instant, u64)>,
}

impl DownloadProgress {
    fn new(
        path: PathBuf,
        channel: Option<appmanager_core::ProgressChannel>,
        runtime: &'static str,
    ) -> Self {
        Self {
            path,
            channel,
            runtime,
            state: Mutex::new((Instant::now(), 0)),
        }
    }

    fn publish(&self, received: u64, total: u64) -> std::io::Result<()> {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let elapsed = state.0.elapsed().as_secs_f64();
        let speed = if elapsed > 0.25 {
            let speed = ((received.saturating_sub(state.1)) as f64 / elapsed) as u64;
            *state = (Instant::now(), received);
            speed
        } else {
            0
        };
        write_progress_io(
            &self.path,
            "downloading",
            received,
            total,
            speed,
            self.runtime,
        )?;
        publish_progress(
            self.channel.as_ref(),
            "downloading",
            self.runtime,
            received,
            total,
            speed,
            self.runtime,
        );
        Ok(())
    }
}

impl Progress for DownloadProgress {
    fn update(&self, received: u64, total: u64) -> std::io::Result<()> {
        self.publish(received, total)
    }
}

fn write_progress(
    path: &Path,
    channel: Option<&appmanager_core::ProgressChannel>,
    phase: &str,
    current: u64,
    total: u64,
    speed: u64,
    detail: &str,
) -> Result<(), String> {
    write_progress_io(path, phase, current, total, speed, detail).map_err(display_error)?;
    publish_progress(channel, phase, "PortMaster", current, total, speed, detail);
    Ok(())
}

fn publish_progress(
    channel: Option<&appmanager_core::ProgressChannel>,
    phase: &str,
    runtime: &str,
    current: u64,
    total: u64,
    speed: u64,
    detail: &str,
) {
    if let Some(channel) = channel {
        channel.publish(appmanager_core::TaskProgress {
            phase: phase.to_owned(),
            runtime: runtime.to_owned(),
            index: 0,
            count: 1,
            current,
            total,
            speed,
            detail: detail.replace(['\t', '\r', '\n'], " "),
        });
    }
}

fn write_progress_io(
    path: &Path,
    phase: &str,
    current: u64,
    total: u64,
    speed: u64,
    detail: &str,
) -> std::io::Result<()> {
    let detail = detail.replace(['\t', '\r', '\n'], " ");
    let row = format!("1\t{phase}\tPortMaster\t0\t1\t{current}\t{total}\t{speed}\t{detail}\n");
    let temporary = progress_temporary(path);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(&temporary, row)?;
    fs::rename(temporary, path)
}

fn progress_temporary(path: &Path) -> PathBuf {
    let mut value = path.as_os_str().to_os_string();
    value.push(format!(".tmp.{}", std::process::id()));
    PathBuf::from(value)
}

fn append_result(path: &Path, value: &str) -> Result<(), String> {
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(display_error)?;
    file.write_all(value.as_bytes()).map_err(display_error)
}

fn write_text(path: &Path, value: &str) -> Result<(), String> {
    portkit_core::atomic_write(path, value.as_bytes()).map_err(display_error)
}

fn env_path(name: &str) -> Option<PathBuf> {
    env::var_os(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

fn normalized_target_override(root: Option<&Path>) -> Option<PathBuf> {
    let target = env_path("PAM_PORTMASTER_DIR_OVERRIDE")?;
    let Some(root) = root else {
        return Some(target);
    };
    target
        .strip_prefix(root)
        .ok()
        .map(|relative| Path::new("/").join(relative))
        .or(Some(target))
}

fn launcher_name(path: &Path) -> &str {
    path.file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("APP Manager.sh")
}

fn path_string(path: Option<&Path>) -> String {
    path.map_or_else(String::new, |value| value.display().to_string())
}

fn safe_version(value: &str) -> String {
    value
        .chars()
        .filter(|character| character.is_ascii_alphanumeric() || "._-".contains(*character))
        .collect()
}

fn safe_asset_name(value: &str) -> bool {
    !value.is_empty()
        && !matches!(value, "." | "..")
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'+' | b'-'))
}

fn device_arch() -> String {
    env::var("DEVICE_ARCH").unwrap_or_else(|_| match env::consts::ARCH {
        "aarch64" => "aarch64".into(),
        "x86_64" => "x86_64".into(),
        value => value.into(),
    })
}

fn python_imports_ready(imports: &[String]) -> bool {
    let executable = env::var("PAM_PYTHON3_CMD_OVERRIDE").unwrap_or_else(|_| "python3".into());
    const CHECK: &str =
        "import importlib,sys\nfor name in sys.argv[1:]: importlib.import_module(name)";
    Command::new(executable)
        .arg("-c")
        .arg(CHECK)
        .args(imports)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

fn squashfs_has_magic(path: &Path) -> bool {
    let mut magic = [0_u8; 4];
    fs::File::open(path)
        .and_then(|mut file| file.read_exact(&mut magic))
        .is_ok()
        && magic == *b"hsqs"
}

fn read_update_cache(path: &Path) -> (u64, String, String) {
    let Ok(value) = fs::read_to_string(path) else {
        return (0, "unknown".into(), String::new());
    };
    let mut fields = value.trim_end().split('\t');
    let checked = fields
        .next()
        .and_then(|value| value.parse().ok())
        .unwrap_or(0);
    let status = match fields.next().unwrap_or("") {
        "ok" => "ok",
        "error" => "error",
        _ => "unknown",
    }
    .to_owned();
    let latest = fields
        .next()
        .filter(|value| {
            value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        })
        .unwrap_or("")
        .to_owned();
    (checked, status, latest)
}

fn cleanup_marker(lock: &Path, marker: &Path) {
    if lock.is_dir() {
        let _ = fs::remove_dir_all(lock);
        let _ = fs::remove_file(marker);
        return;
    }
    if let Ok(lock) = ExclusiveFileLock::try_acquire(lock) {
        let _ = fs::remove_file(marker);
        drop(lock);
    }
}

fn write_json(path: &Path, value: &impl serde::Serialize) -> Result<(), String> {
    let bytes = serde_json::to_vec_pretty(value).map_err(display_error)?;
    portkit_core::atomic_write(path, &bytes).map_err(display_error)
}

fn free_bytes(path: &Path) -> u64 {
    let Ok(path) = CString::new(path.as_os_str().as_bytes()) else {
        return 0;
    };
    let mut value = std::mem::MaybeUninit::<libc::statvfs>::uninit();
    let result = unsafe { libc::statvfs(path.as_ptr(), value.as_mut_ptr()) };
    if result != 0 {
        return 0;
    }
    let value = unsafe { value.assume_init() };
    u64::from(value.f_bavail).saturating_mul(value.f_frsize)
}

fn display_error(error: impl std::fmt::Display) -> String {
    error.to_string()
}

fn fail(code: u8, message: &str) -> ExitCode {
    eprintln!("[PAM] {message}");
    ExitCode::from(code)
}

fn exit_code(code: u8) -> ExitCode {
    ExitCode::from(code)
}
