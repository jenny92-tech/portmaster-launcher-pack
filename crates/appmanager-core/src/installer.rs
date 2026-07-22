use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;
use sha2::{Digest, Sha256};
use thiserror::Error;
use zip::ZipArchive;

use crate::{FrontendTransform, ManagedRoot, ValidatedInstallPlan};

const PROTOCOL_VERSION: u8 = 1;
#[derive(Clone, Copy)]
struct ArchiveLimits {
    entries: usize,
    entry_bytes: u64,
    total_bytes: u64,
}

const ARCHIVE_LIMITS: ArchiveLimits = ArchiveLimits {
    entries: 20_000,
    entry_bytes: 128 * 1024 * 1024,
    total_bytes: 512 * 1024 * 1024,
};
const FIXED_PRESERVED: &[&str] = &[
    "log.txt",
    "pugwash.txt",
    "harbourmaster.txt",
    ".appmanager-state",
    ".appmanager-rollback",
];

#[derive(Debug, Clone)]
pub struct InstallRequest {
    pub archive: PathBuf,
    pub launcher: PathBuf,
    pub state_dir: PathBuf,
    pub trash_dir: PathBuf,
    pub cancel_file: Option<PathBuf>,
    /// Optional filesystem prefix used only to probe device-absolute library candidates in tests.
    pub probe_root: Option<PathBuf>,
    pub plan: ValidatedInstallPlan,
    /// Deterministic fault injection for transaction rollback tests.
    #[doc(hidden)]
    pub fail_after_backup: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum InstallMode {
    Install,
    Update,
}

impl InstallMode {
    fn as_str(self) -> &'static str {
        match self {
            Self::Install => "install",
            Self::Update => "update",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct InstallOutcome {
    pub device: String,
    pub target: PathBuf,
    pub mode: InstallMode,
    pub status: &'static str,
    pub manifest_count: usize,
    pub frontend_manifest_count: usize,
}

#[derive(Debug, Error)]
pub enum InstallError {
    #[error("invalid install request: {0}")]
    Invalid(String),
    #[error("installation was cancelled before core replacement")]
    Cancelled,
    #[error("another installation is already running")]
    Locked,
    #[error("a previous installation is still pending validation")]
    Pending,
    #[error("a previous installation transaction requires recovery")]
    RecoveryRequired,
    #[error("unsafe or invalid PortMaster archive: {0}")]
    Archive(String),
    #[error("installation failed: {0}")]
    Io(#[from] io::Error),
    #[error(
        "installation failed and automatic rollback was incomplete: {install}; rollback: {rollback}"
    )]
    Rollback { install: String, rollback: String },
}

struct LockGuard {
    _file: File,
}

struct WorkGuard(PathBuf);

impl Drop for WorkGuard {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

struct Transaction<'a> {
    request: &'a InstallRequest,
    rollback: PathBuf,
    frontend_rollback: PathBuf,
    core_stage_name: String,
    mode: InstallMode,
    mutation_started: bool,
    backup_complete: bool,
    frontend_existing: Vec<String>,
    backup_tops: Vec<String>,
    frontend_backup_hash: String,
    backup_top_hash: String,
}

pub fn install_portmaster(request: &InstallRequest) -> Result<InstallOutcome, InstallError> {
    let state_is_safe = ManagedRoot::new(&request.state_dir).is_ok();
    let result = install_portmaster_inner(request);
    if state_is_safe && !progress_is_terminal(&request.state_dir) {
        if let Err(error) = &result {
            let _ = progress(request, "failed", 0, &error.to_string());
        }
    }
    result
}

fn install_portmaster_inner(request: &InstallRequest) -> Result<InstallOutcome, InstallError> {
    validate_request(request)?;
    fs::create_dir_all(&request.state_dir)?;
    progress(request, "extracting", 10, "Extracting PortMaster core")?;
    cancel(request)?;

    fs::create_dir_all(&request.plan.target)?;
    fs::create_dir_all(&request.plan.frontend_dir)?;
    let core_work = unique_path(&request.plan.target, ".pm-install");
    let frontend_work = unique_path(&request.plan.frontend_dir, ".pm-install");
    let _core_work_guard = WorkGuard(core_work.clone());
    let _frontend_work_guard = WorkGuard(frontend_work.clone());
    let staged_core = core_work.join("stage");
    let staged_frontend = frontend_work.join("stage");
    fs::create_dir_all(&staged_core)?;
    fs::create_dir_all(&staged_frontend)?;
    extract_archive(&request.archive, &staged_core)?;
    prepare_staging(
        &request.plan,
        &staged_core,
        &staged_frontend,
        request.probe_root.as_deref(),
    )?;
    let staged_files = regular_files(&staged_core)?;
    if staged_files.is_empty() {
        return fail_before_mutation(
            request,
            InstallError::Archive("managed core is empty".into()),
        );
    }
    cancel(request)?;

    let _lock = acquire_lock(&request.state_dir)?;
    if request.state_dir.join("pending-install.tsv").exists() {
        return fail_before_mutation(request, InstallError::Pending);
    }
    if request.state_dir.join("install-transaction.tsv").exists() {
        return fail_before_mutation(request, InstallError::RecoveryRequired);
    }
    cancel(request)?;

    fs::create_dir_all(&request.plan.scripts)?;
    let rollback = request.plan.target.join(".appmanager-rollback");
    let frontend_rollback = request.plan.frontend_dir.join(".appmanager-rollback");
    if rollback.exists() {
        fs::remove_dir_all(&rollback)?;
    }
    if frontend_rollback.exists() {
        fs::remove_dir_all(&frontend_rollback)?;
    }
    fs::create_dir_all(rollback.join("core"))?;
    fs::create_dir_all(&frontend_rollback)?;

    let mode = if ["control.txt", "pugwash", "harbourmaster"]
        .iter()
        .any(|name| request.plan.target.join(name).is_file())
    {
        InstallMode::Update
    } else {
        InstallMode::Install
    };
    let frontend_existing = request
        .plan
        .frontend_names
        .iter()
        .filter(|name| path_exists(&request.plan.frontend_dir.join(name)))
        .cloned()
        .collect::<Vec<_>>();
    let frontend_list = lines(&frontend_existing);
    atomic_write(
        &frontend_rollback.join("frontend-existing.tsv"),
        frontend_list.as_bytes(),
    )?;
    let frontend_backup_hash = sha256_bytes(frontend_list.as_bytes());
    let mut transaction = Transaction {
        request,
        rollback,
        frontend_rollback,
        core_stage_name: core_work
            .file_name()
            .and_then(|name| name.to_str())
            .expect("generated stage name is UTF-8")
            .to_owned(),
        mode,
        mutation_started: false,
        backup_complete: false,
        frontend_existing,
        backup_tops: Vec::new(),
        frontend_backup_hash,
        backup_top_hash: sha256_bytes(b""),
    };
    if let Err(error) = transaction.write_state("prepared") {
        let _ = transaction.discard_prepared();
        return Err(error.into());
    }
    if let Err(error) = progress(request, "installing", 60, "Replacing managed core") {
        let _ = transaction.discard_prepared();
        return Err(error.into());
    }
    transaction.mutation_started = true;
    let result = (|| -> Result<InstallOutcome, InstallError> {
        transaction.back_up()?;
        if request.fail_after_backup {
            return Err(InstallError::Io(io::Error::other(
                "simulated replacement failure",
            )));
        }
        install_staged(&request.plan, &staged_core, &staged_frontend)?;
        set_executables(&request.plan)?;

        progress(request, "recording", 90, "Recording managed core manifest")?;
        let manifest = manifest_for(&request.plan.target, &staged_files)?;
        let frontend_manifest = frontend_manifest(&request.plan)?;
        let manifest_text = manifest_rows(&manifest);
        let frontend_text = manifest_rows(&frontend_manifest);
        atomic_write(
            &request.state_dir.join("pending-manifest.tsv"),
            manifest_text.as_bytes(),
        )?;
        atomic_write(
            &request.state_dir.join("pending-frontend-manifest.tsv"),
            frontend_text.as_bytes(),
        )?;
        let launcher = if request.plan.frontend_names.is_empty() {
            request.plan.target.join(&request.plan.primary_frontend)
        } else {
            request
                .plan
                .frontend_dir
                .join(&request.plan.primary_frontend)
        };
        let pending = transaction.pending_state(
            manifest.len(),
            &sha256_bytes(manifest_text.as_bytes()),
            &sha256_file(&launcher)?,
            frontend_manifest.len(),
            &sha256_bytes(frontend_text.as_bytes()),
        );
        atomic_write(
            &request.state_dir.join("pending-install.tsv"),
            pending.as_bytes(),
        )?;
        progress(request, "complete", 100, "PortMaster core installed")?;
        match fs::remove_file(request.state_dir.join("install-transaction.tsv")) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        Ok(InstallOutcome {
            device: request.plan.device.clone(),
            target: request.plan.target.clone(),
            mode,
            status: "pending-validation",
            manifest_count: manifest.len(),
            frontend_manifest_count: frontend_manifest.len(),
        })
    })();

    match result {
        Ok(outcome) => Ok(outcome),
        Err(error) => match transaction.rollback() {
            Ok(()) => {
                let _ = progress(
                    request,
                    "rolled-back",
                    0,
                    "Previous core restored after installation failure",
                );
                Err(error)
            }
            Err(rollback) => {
                let _ = progress(
                    request,
                    "rollback-failed",
                    0,
                    "Automatic rollback was incomplete; recovery state was preserved",
                );
                Err(InstallError::Rollback {
                    install: error.to_string(),
                    rollback: rollback.to_string(),
                })
            }
        },
    }
}

fn progress_is_terminal(state: &Path) -> bool {
    let Ok(contents) = fs::read_to_string(state.join("install-progress.tsv")) else {
        return false;
    };
    matches!(
        contents.split('\t').nth(1),
        Some("cancelled" | "rolled-back" | "rollback-failed")
    )
}

fn validate_request(request: &InstallRequest) -> Result<(), InstallError> {
    if request.plan.schema != 1 {
        return Err(InstallError::Invalid("unsupported plan schema".to_owned()));
    }
    if !request.archive.is_file() {
        return Err(InstallError::Invalid("archive is not a file".to_owned()));
    }
    for (name, path) in [
        (
            "launcher directory",
            request.launcher.parent().unwrap_or(Path::new("/")),
        ),
        ("target", &request.plan.target),
        ("scripts", &request.plan.scripts),
        ("frontend", &request.plan.frontend_dir),
        ("state", &request.state_dir),
        ("trash", &request.trash_dir),
    ] {
        ManagedRoot::new(path)
            .map_err(|error| InstallError::Invalid(format!("unsafe {name} path: {error}")))?;
    }
    for name in request
        .plan
        .frontend_names
        .iter()
        .chain(std::iter::once(&request.plan.primary_frontend))
        .chain(
            request
                .plan
                .frontend_map
                .iter()
                .map(|mapping| &mapping.destination),
        )
    {
        ManagedRoot::validate_child_name(name).map_err(|error| {
            InstallError::Invalid(format!("unsafe frontend direct-child name: {error}"))
        })?;
    }
    for mapping in &request.plan.frontend_map {
        validate_archive_relative(&mapping.source)
            .map_err(|_| InstallError::Invalid("unsafe frontend mapping source".to_owned()))?;
    }
    validate_install_roots(request)?;
    Ok(())
}

fn validate_install_roots(request: &InstallRequest) -> Result<(), InstallError> {
    let plan = &request.plan;
    let launcher_directory = request
        .launcher
        .parent()
        .ok_or_else(|| InstallError::Invalid("launcher has no parent directory".to_owned()))?;

    let resolved = |path: &Path| {
        ManagedRoot::new(path)
            .map(|root| root.resolved_path().to_path_buf())
            .map_err(|error| InstallError::Invalid(error.to_string()))
    };
    let target_resolved = resolved(&plan.target)?;
    let frontend_resolved = resolved(&plan.frontend_dir)?;
    let scripts_resolved = resolved(&plan.scripts)?;
    let launcher_resolved = resolved(launcher_directory)?;
    let state_resolved = resolved(&request.state_dir)?;
    let trash_resolved = resolved(&request.trash_dir)?;
    for (name, root) in [("app state", &state_resolved), ("trash", &trash_resolved)] {
        if paths_overlap(&target_resolved, root) {
            return Err(InstallError::Invalid(format!(
                "PortMaster target and {name} root overlap"
            )));
        }
    }
    if target_resolved == frontend_resolved || target_resolved == scripts_resolved {
        return Err(InstallError::Invalid(
            "PortMaster target cannot also be a frontend or scripts root".to_owned(),
        ));
    }
    if frontend_resolved.starts_with(&target_resolved)
        || scripts_resolved.starts_with(&target_resolved)
    {
        return Err(InstallError::Invalid(
            "frontend and scripts roots cannot be inside the recursively replaced target"
                .to_owned(),
        ));
    }
    if frontend_resolved != scripts_resolved && paths_overlap(&frontend_resolved, &scripts_resolved)
    {
        return Err(InstallError::Invalid(
            "frontend and scripts roots overlap unsafely".to_owned(),
        ));
    }

    let launcher_device = device_path(&launcher_resolved, request.probe_root.as_deref());
    let scripts_device = device_path(&scripts_resolved, request.probe_root.as_deref());
    let launcher_anchor = storage_anchor(&launcher_device).ok_or_else(|| {
        InstallError::Invalid(format!(
            "launcher directory {} has no supported storage anchor",
            launcher_device.display()
        ))
    })?;
    let target_device = device_path(&target_resolved, request.probe_root.as_deref());
    if !app_specific_leaf(&target_device) {
        return Err(InstallError::Invalid(
            "PortMaster target must be an app-specific PortMaster leaf".to_owned(),
        ));
    }
    for (name, root) in [("app state", &state_resolved), ("trash", &trash_resolved)] {
        let device = device_path(root, request.probe_root.as_deref());
        if forbidden_system_namespace(&device) {
            return Err(InstallError::Invalid(format!(
                "{name} root {} is in a protected system namespace",
                device.display()
            )));
        }
    }
    if scripts_device != launcher_device
        || storage_anchor(&scripts_device).as_deref() != Some(launcher_anchor.as_path())
    {
        return Err(InstallError::Invalid(
            "scripts root must be the launcher directory on the same storage anchor".to_owned(),
        ));
    }

    for (name, physical, resolved_root) in [
        ("target", &plan.target, &target_resolved),
        ("frontend", &plan.frontend_dir, &frontend_resolved),
    ] {
        let device = device_path(resolved_root, request.probe_root.as_deref());
        if forbidden_system_namespace(&device) {
            return Err(InstallError::Invalid(format!(
                "{name} root {} is in a protected system namespace",
                device.display()
            )));
        }
        let is_dynamic_frontend = name == "frontend" && device == launcher_device;
        if is_dynamic_frontend {
            continue;
        }
        if storage_anchor(&device).is_some() {
            continue;
        }
        if !physical.is_dir() || !app_specific_leaf(&device) {
            return Err(InstallError::Invalid(format!(
                "cross-anchor explicit {name} root must already exist as an app-specific leaf"
            )));
        }
    }
    Ok(())
}

fn paths_overlap(left: &Path, right: &Path) -> bool {
    left == right || left.starts_with(right) || right.starts_with(left)
}

fn device_path(path: &Path, fixture_root: Option<&Path>) -> PathBuf {
    let Some(root) = fixture_root else {
        return path.to_path_buf();
    };
    let canonical_root = fs::canonicalize(root).unwrap_or_else(|_| root.to_path_buf());
    let Ok(relative) = path.strip_prefix(&canonical_root) else {
        return path.to_path_buf();
    };
    Path::new("/").join(relative)
}

fn storage_anchor(path: &Path) -> Option<PathBuf> {
    let parts = path
        .components()
        .filter_map(|component| match component {
            Component::Normal(value) => value.to_str(),
            _ => None,
        })
        .collect::<Vec<_>>();
    match parts.as_slice() {
        ["mnt" | "media", volume, ..] => Some(Path::new("/").join(parts[0]).join(volume)),
        ["run", "media", volume, ..] => Some(Path::new("/run/media").join(volume)),
        [anchor @ ("userdata" | "storage" | "roms" | "sdcard"), ..] => {
            Some(Path::new("/").join(anchor))
        }
        _ => None,
    }
}

fn forbidden_system_namespace(path: &Path) -> bool {
    const FORBIDDEN: &[&str] = &[
        "/bin", "/dev", "/etc", "/lib", "/lib64", "/proc", "/sbin", "/sys", "/tmp", "/usr", "/var",
    ];
    FORBIDDEN.iter().any(|root| path.starts_with(root))
        || (path.starts_with("/run") && !path.starts_with("/run/media"))
        || (path.starts_with("/root") && !path.starts_with("/root/.local/share"))
        || (path.starts_with("/home") && !home_app_data_path(path))
}

fn home_app_data_path(path: &Path) -> bool {
    let parts = path
        .components()
        .filter_map(|component| match component {
            Component::Normal(value) => value.to_str(),
            _ => None,
        })
        .collect::<Vec<_>>();
    matches!(parts.as_slice(), ["home", _, ".local", "share", _, ..])
}

fn app_specific_leaf(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name.eq_ignore_ascii_case("PortMaster"))
}

fn fail_before_mutation<T>(
    request: &InstallRequest,
    error: InstallError,
) -> Result<T, InstallError> {
    let _ = progress(request, "failed", 0, &error.to_string());
    Err(error)
}

fn cancel(request: &InstallRequest) -> Result<(), InstallError> {
    if request
        .cancel_file
        .as_ref()
        .is_some_and(|path| path.exists())
    {
        let _ = progress(
            request,
            "cancelled",
            0,
            "Installation cancelled before core replacement",
        );
        return Err(InstallError::Cancelled);
    }
    Ok(())
}

fn progress(request: &InstallRequest, phase: &str, percent: u8, detail: &str) -> io::Result<()> {
    let detail = detail.replace(['\t', '\r', '\n'], " ");
    atomic_write(
        &request.state_dir.join("install-progress.tsv"),
        format!("1\t{phase}\t{percent}\t{detail}\n").as_bytes(),
    )
}

fn acquire_lock(state: &Path) -> Result<LockGuard, InstallError> {
    let lock = state.join("install-lock");
    if fs::symlink_metadata(&lock).is_ok_and(|metadata| metadata.file_type().is_symlink()) {
        return Err(InstallError::Locked);
    }
    let mut file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(&lock)?;
    verify_open_lock_path(&lock, &file)?;
    try_lock_install(&file).map_err(|error| {
        if error.kind() == io::ErrorKind::WouldBlock {
            InstallError::Locked
        } else {
            InstallError::Io(error)
        }
    })?;
    let token = format!(
        "{}-{}-{}",
        std::process::id(),
        epoch_seconds(),
        unique_counter()
    );
    if let Err(error) = file
        .set_len(0)
        .and_then(|()| file.write_all(format!("{token}\n").as_bytes()))
        .and_then(|()| file.sync_all())
        .and_then(|()| sync_parent(&lock))
    {
        return Err(error.into());
    }
    Ok(LockGuard { _file: file })
}

#[cfg(unix)]
fn verify_open_lock_path(path: &Path, file: &File) -> io::Result<()> {
    use std::os::unix::fs::MetadataExt;
    let path_metadata = fs::symlink_metadata(path)?;
    let file_metadata = file.metadata()?;
    if !path_metadata.file_type().is_file()
        || path_metadata.dev() != file_metadata.dev()
        || path_metadata.ino() != file_metadata.ino()
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "install lock path changed while opening",
        ));
    }
    Ok(())
}

#[cfg(not(unix))]
fn verify_open_lock_path(path: &Path, _file: &File) -> io::Result<()> {
    if fs::symlink_metadata(path)?.file_type().is_file() {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "install lock is not a regular file",
        ))
    }
}

#[cfg(unix)]
fn try_lock_install(file: &File) -> io::Result<()> {
    use std::os::fd::AsRawFd;
    unsafe extern "C" {
        fn flock(file_descriptor: i32, operation: i32) -> i32;
    }
    const LOCK_EXCLUSIVE: i32 = 2;
    const LOCK_NONBLOCKING: i32 = 4;
    if unsafe { flock(file.as_raw_fd(), LOCK_EXCLUSIVE | LOCK_NONBLOCKING) } == 0 {
        Ok(())
    } else {
        let error = io::Error::last_os_error();
        if matches!(error.raw_os_error(), Some(11 | 35)) {
            Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "another installation is already active",
            ))
        } else {
            Err(error)
        }
    }
}

#[cfg(not(unix))]
fn try_lock_install(_file: &File) -> io::Result<()> {
    Ok(())
}

fn extract_archive(archive: &Path, staged_core: &Path) -> Result<(), InstallError> {
    extract_archive_with_limits(archive, staged_core, ARCHIVE_LIMITS)
}

fn extract_archive_with_limits(
    archive: &Path,
    staged_core: &Path,
    limits: ArchiveLimits,
) -> Result<(), InstallError> {
    let file = File::open(archive)?;
    let mut zip =
        ZipArchive::new(file).map_err(|error| InstallError::Archive(error.to_string()))?;
    if zip.len() > limits.entries {
        return Err(InstallError::Archive(format!(
            "archive contains too many entries ({} > {})",
            zip.len(),
            limits.entries
        )));
    }
    let mut seen = BTreeSet::new();
    let mut total = 0_u64;
    for index in 0..zip.len() {
        let mut entry = zip
            .by_index(index)
            .map_err(|error| InstallError::Archive(error.to_string()))?;
        let raw = std::str::from_utf8(entry.name_raw())
            .map_err(|_| InstallError::Archive("non-UTF-8 entry name".to_owned()))?
            .to_owned();
        if raw == "PortMaster" || raw == "PortMaster/" {
            continue;
        }
        let relative = raw
            .strip_prefix("PortMaster/")
            .ok_or_else(|| InstallError::Archive(format!("unexpected archive root: {raw:?}")))?;
        validate_archive_relative(relative)?;
        if !seen.insert(relative.trim_end_matches('/').to_owned()) {
            return Err(InstallError::Archive(format!("duplicate entry: {raw:?}")));
        }
        if let Some(mode) = entry.unix_mode() {
            let kind = mode & 0o170000;
            if kind != 0 && kind != 0o100000 && kind != 0o040000 {
                return Err(InstallError::Archive(format!("non-regular entry: {raw:?}")));
            }
        }
        let output = staged_core.join(relative.trim_end_matches('/'));
        if entry.is_dir() || raw.ends_with('/') {
            fs::create_dir_all(&output)?;
            continue;
        }
        if entry.size() > limits.entry_bytes {
            return Err(InstallError::Archive(format!(
                "entry exceeds expansion limit: {raw:?}"
            )));
        }
        if let Some(parent) = output.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut target = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&output)?;
        copy_bounded(&mut entry, &mut target, &raw, &mut total, limits)?;
        target.sync_all()?;
    }
    Ok(())
}

fn validate_archive_relative(value: &str) -> Result<(), InstallError> {
    if value.is_empty()
        || value.starts_with('/')
        || value.contains(['\\', '\0', '\t', '\r', '\n'])
        || value.contains("//")
    {
        return Err(InstallError::Archive(format!("unsafe path: {value:?}")));
    }
    for component in Path::new(value.trim_end_matches('/')).components() {
        if !matches!(component, Component::Normal(_)) {
            return Err(InstallError::Archive(format!("unsafe path: {value:?}")));
        }
    }
    Ok(())
}

fn copy_bounded(
    source: &mut impl Read,
    destination: &mut impl Write,
    label: &str,
    total: &mut u64,
    limits: ArchiveLimits,
) -> Result<(), InstallError> {
    let mut entry_bytes = 0_u64;
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = source
            .read(&mut buffer)
            .map_err(|error| InstallError::Archive(format!("cannot read {label:?}: {error}")))?;
        if read == 0 {
            return Ok(());
        }
        entry_bytes = entry_bytes
            .checked_add(read as u64)
            .ok_or_else(|| InstallError::Archive("entry size overflow".to_owned()))?;
        *total = total
            .checked_add(read as u64)
            .ok_or_else(|| InstallError::Archive("archive size overflow".to_owned()))?;
        if entry_bytes > limits.entry_bytes {
            return Err(InstallError::Archive(format!(
                "entry exceeds expansion limit: {label:?}"
            )));
        }
        if *total > limits.total_bytes {
            return Err(InstallError::Archive(
                "archive exceeds total expansion limit".to_owned(),
            ));
        }
        destination.write_all(&buffer[..read])?;
    }
}

fn validate_nested_zip(path: &Path) -> Result<(), InstallError> {
    let mut archive = ZipArchive::new(File::open(path)?)
        .map_err(|error| InstallError::Archive(format!("invalid pylibs.zip: {error}")))?;
    if archive.len() > ARCHIVE_LIMITS.entries {
        return Err(InstallError::Archive(
            "pylibs.zip contains too many entries".to_owned(),
        ));
    }
    let mut total = 0_u64;
    let mut seen = BTreeSet::new();
    for index in 0..archive.len() {
        let mut entry = archive
            .by_index(index)
            .map_err(|error| InstallError::Archive(format!("invalid pylibs.zip: {error}")))?;
        let raw = std::str::from_utf8(entry.name_raw())
            .map_err(|_| InstallError::Archive("non-UTF-8 pylibs.zip entry name".to_owned()))?
            .to_owned();
        validate_archive_relative(&raw)?;
        if !seen.insert(raw.trim_end_matches('/').to_owned()) {
            return Err(InstallError::Archive(format!(
                "duplicate pylibs.zip entry: {raw:?}"
            )));
        }
        if let Some(mode) = entry.unix_mode() {
            let kind = mode & 0o170000;
            if kind != 0 && kind != 0o100000 && kind != 0o040000 {
                return Err(InstallError::Archive(format!(
                    "non-regular pylibs.zip entry: {raw:?}"
                )));
            }
        }
        if entry.is_dir() || raw.ends_with('/') {
            continue;
        }
        if entry.size() > ARCHIVE_LIMITS.entry_bytes {
            return Err(InstallError::Archive(
                "pylibs.zip entry exceeds expansion limit".to_owned(),
            ));
        }
        copy_bounded(
            &mut entry,
            &mut io::sink(),
            "pylibs.zip entry",
            &mut total,
            ARCHIVE_LIMITS,
        )?;
    }
    Ok(())
}

fn prepare_staging(
    plan: &ValidatedInstallPlan,
    core: &Path,
    frontend: &Path,
    probe_root: Option<&Path>,
) -> Result<(), InstallError> {
    for required in [
        "control.txt",
        "device_info.txt",
        "funcs.txt",
        "PortMaster.sh",
    ] {
        if !core.join(required).is_file() {
            return Err(InstallError::Archive(format!("missing {required}")));
        }
    }
    if let Some(source) = &plan.control_source {
        copy_regular(&core.join(source), &core.join("control.txt"), source)?;
    }
    if let Some(source) = &plan.core_launcher_source {
        copy_regular(&core.join(source), &core.join("PortMaster.sh"), source)?;
    }
    for mapping in &plan.frontend_map {
        copy_regular(
            &core.join(&mapping.source),
            &frontend.join(&mapping.destination),
            &mapping.source,
        )?;
    }
    for transform in &plan.frontend_transforms {
        apply_frontend_transform(transform, frontend, probe_root)?;
    }
    if plan.remove_core_launcher {
        remove_any(&core.join("PortMaster.sh"))?;
    }
    if plan.empty_tasksetter {
        fs::write(core.join("tasksetter"), b"")?;
    }
    for name in plan
        .preserve_core_entries
        .iter()
        .map(String::as_str)
        .chain(FIXED_PRESERVED.iter().copied())
    {
        remove_any(&core.join(name))?;
    }
    let pylibs_zip = core.join("pylibs.zip");
    if pylibs_zip.is_file() {
        validate_nested_zip(&pylibs_zip)?;
        remove_any(&core.join("pylibs"))?;
    } else if !core.join("pylibs").is_dir() {
        return Err(InstallError::Archive(
            "archive contains neither pylibs.zip nor pylibs".to_owned(),
        ));
    }
    Ok(())
}

fn apply_frontend_transform(
    transform: &FrontendTransform,
    frontend: &Path,
    probe_root: Option<&Path>,
) -> Result<(), InstallError> {
    match transform {
        FrontendTransform::ExportLibraryGroup {
            target,
            variable,
            candidates,
            required_sonames,
        } => {
            let selected = candidates.iter().find(|candidate| {
                let probe = probe_device_path(candidate, probe_root);
                required_sonames
                    .iter()
                    .all(|name| probe.join(name).exists())
            });
            let selected = selected.ok_or_else(|| {
                InstallError::Archive(format!(
                    "no candidate contains the complete library group for {variable}"
                ))
            })?;
            let path = frontend.join(target);
            let bytes = fs::read(&path)?;
            let text = std::str::from_utf8(&bytes).map_err(|_| {
                InstallError::Archive(format!("frontend transform target {target:?} is not UTF-8"))
            })?;
            let prefix = format!("export {variable}=");
            let mut replacements = 0;
            let mut output = String::with_capacity(text.len() + selected.as_os_str().len());
            for line in text.split_inclusive('\n') {
                let content = line.strip_suffix('\n').unwrap_or(line);
                let content = content.strip_suffix('\r').unwrap_or(content);
                if content.starts_with(&prefix) {
                    replacements += 1;
                    output.push_str(&format!(
                        "export {variable}={}",
                        shell_single_quote(&selected.to_string_lossy())
                    ));
                    if line.ends_with('\n') {
                        output.push('\n');
                    }
                } else {
                    output.push_str(line);
                }
            }
            if replacements != 1 {
                return Err(InstallError::Archive(format!(
                    "frontend transform expected exactly one export for {variable}, found {replacements}"
                )));
            }
            fs::write(path, output)?;
        }
    }
    Ok(())
}

fn shell_single_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

fn probe_device_path(candidate: &Path, probe_root: Option<&Path>) -> PathBuf {
    match probe_root {
        Some(root) if candidate.is_absolute() => {
            root.join(candidate.strip_prefix("/").unwrap_or(candidate))
        }
        _ => candidate.to_path_buf(),
    }
}

fn copy_regular(source: &Path, destination: &Path, label: &str) -> Result<(), InstallError> {
    if !source.is_file() {
        return Err(InstallError::Archive(format!(
            "missing planned file {label}"
        )));
    }
    let temporary = destination.with_extension(format!("copy.{}", unique_counter()));
    let result = (|| -> io::Result<()> {
        let mut input = File::open(source)?;
        let mut output = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        io::copy(&mut input, &mut output)?;
        output.sync_all()?;
        fs::rename(&temporary, destination)?;
        sync_parent(destination)
    })();
    if result.is_err() {
        let _ = remove_any(&temporary);
    }
    result?;
    Ok(())
}

impl Transaction<'_> {
    fn discard_prepared(&self) -> io::Result<()> {
        remove_any(&self.rollback)?;
        remove_any(&self.frontend_rollback)?;
        remove_any(&self.request.state_dir.join("install-transaction.tsv"))
    }

    fn write_state(&self, phase: &str) -> io::Result<()> {
        let plan = &self.request.plan;
        let content = format!(
            concat!(
                "version\t{}\nphase\t{}\nmode\t{}\ndevice\t{}\ntarget\t{}\nscripts\t{}\n",
                "frontend_dir\t{}\nfrontend_names\t{}\nrollback\t{}\nfrontend_rollback\t{}\nhad_launcher\t{}\n",
                "frontend_backup_count\t{}\nfrontend_backup_sha256\t{}\n",
                "backup_top_count\t{}\nbackup_top_sha256\t{}\n"
            ),
            PROTOCOL_VERSION,
            phase,
            self.mode.as_str(),
            plan.device,
            plan.target.display(),
            plan.scripts.display(),
            plan.frontend_dir.display(),
            frontend_names(plan),
            self.rollback.display(),
            self.frontend_rollback.display(),
            u8::from(self.frontend_existing.contains(&plan.primary_frontend)),
            self.frontend_existing.len(),
            self.frontend_backup_hash,
            self.backup_tops.len(),
            self.backup_top_hash,
        );
        atomic_write(
            &self.request.state_dir.join("install-transaction.tsv"),
            content.as_bytes(),
        )
    }

    fn back_up(&mut self) -> Result<(), InstallError> {
        for (name, path) in
            managed_top_entries(&self.request.plan, Some(self.core_stage_name.as_str()))?
        {
            rename_synced(&path, &self.rollback.join("core").join(&name))?;
        }
        for name in &self.frontend_existing {
            rename_synced(
                &self.request.plan.frontend_dir.join(name),
                &self.frontend_rollback.join(name),
            )?;
        }
        self.backup_tops = direct_names(&self.rollback.join("core"))?;
        let content = lines(&self.backup_tops);
        self.backup_top_hash = sha256_bytes(content.as_bytes());
        atomic_write(&self.rollback.join("expected-tops.tsv"), content.as_bytes())?;
        self.backup_complete = true;
        self.write_state("backed-up")?;
        Ok(())
    }

    fn pending_state(
        &self,
        manifest_count: usize,
        manifest_hash: &str,
        launcher_hash: &str,
        frontend_count: usize,
        frontend_hash: &str,
    ) -> String {
        let plan = &self.request.plan;
        format!(
            concat!(
                "version\t{}\nmode\t{}\ndevice\t{}\ntarget\t{}\nscripts\t{}\n",
                "frontend_dir\t{}\nfrontend_names\t{}\nrollback\t{}\nfrontend_rollback\t{}\n",
                "manifest_count\t{}\nmanifest_sha256\t{}\nlauncher_sha256\t{}\n",
                "frontend_manifest_count\t{}\nfrontend_manifest_sha256\t{}\nhad_launcher\t{}\n",
                "frontend_backup_count\t{}\nfrontend_backup_sha256\t{}\n",
                "backup_top_count\t{}\nbackup_top_sha256\t{}\ncreated\t{}\n"
            ),
            PROTOCOL_VERSION,
            self.mode.as_str(),
            plan.device,
            plan.target.display(),
            plan.scripts.display(),
            plan.frontend_dir.display(),
            frontend_names(plan),
            self.rollback.display(),
            self.frontend_rollback.display(),
            manifest_count,
            manifest_hash,
            launcher_hash,
            frontend_count,
            frontend_hash,
            u8::from(self.frontend_existing.contains(&plan.primary_frontend)),
            self.frontend_existing.len(),
            self.frontend_backup_hash,
            self.backup_tops.len(),
            self.backup_top_hash,
            epoch_seconds(),
        )
    }

    fn rollback(&mut self) -> Result<(), InstallError> {
        if !self.mutation_started {
            return Ok(());
        }
        if self.backup_complete {
            for (_, path) in
                managed_top_entries(&self.request.plan, Some(self.core_stage_name.as_str()))?
            {
                remove_any(&path)?;
            }
            for name in &self.request.plan.frontend_names {
                remove_any(&self.request.plan.frontend_dir.join(name))?;
            }
        }
        for name in direct_names(&self.rollback.join("core"))? {
            let live = self.request.plan.target.join(&name);
            if path_exists(&live) {
                return Err(InstallError::Invalid(format!(
                    "rollback collision at {}",
                    live.display()
                )));
            }
            rename_synced(&self.rollback.join("core").join(&name), &live)?;
        }
        for name in &self.frontend_existing {
            let backup = self.frontend_rollback.join(name);
            if path_exists(&backup) {
                let live = self.request.plan.frontend_dir.join(name);
                if path_exists(&live) {
                    return Err(InstallError::Invalid(format!(
                        "rollback collision at {}",
                        live.display()
                    )));
                }
                rename_synced(&backup, &live)?;
            }
        }
        fs::remove_dir_all(&self.rollback)?;
        fs::remove_dir_all(&self.frontend_rollback)?;
        for name in [
            "pending-install.tsv",
            "pending-manifest.tsv",
            "pending-frontend-manifest.tsv",
            "install-transaction.tsv",
        ] {
            remove_any(&self.request.state_dir.join(name))?;
        }
        Ok(())
    }
}

fn install_staged(plan: &ValidatedInstallPlan, core: &Path, frontend: &Path) -> io::Result<()> {
    for name in direct_names(core)? {
        rename_synced(&core.join(&name), &plan.target.join(name))?;
    }
    for name in &plan.frontend_names {
        rename_synced(&frontend.join(name), &plan.frontend_dir.join(name))?;
    }
    Ok(())
}

fn set_executables(plan: &ValidatedInstallPlan) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        for path in [
            plan.core_executable
                .as_ref()
                .map(|name| plan.target.join(name)),
            plan.frontend_executable
                .as_ref()
                .map(|name| plan.frontend_dir.join(name)),
        ]
        .into_iter()
        .flatten()
        {
            let mut permissions = fs::metadata(&path)?.permissions();
            permissions.set_mode(permissions.mode() | 0o111);
            fs::set_permissions(path, permissions)?;
        }
        for entry in fs::read_dir(&plan.target)? {
            let entry = entry?;
            if !entry.file_type()?.is_file() {
                continue;
            }
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name.ends_with(".sh")
                || name.starts_with("gptokeyb")
                || name == "harbourmaster"
                || name == "pugwash"
            {
                let mut permissions = entry.metadata()?.permissions();
                permissions.set_mode(permissions.mode() | 0o111);
                fs::set_permissions(entry.path(), permissions)?;
            }
        }
    }
    Ok(())
}

fn managed_top_entries(
    plan: &ValidatedInstallPlan,
    excluded: Option<&str>,
) -> io::Result<Vec<(String, PathBuf)>> {
    let preserved = plan
        .preserve_core_entries
        .iter()
        .map(String::as_str)
        .chain(FIXED_PRESERVED.iter().copied())
        .collect::<BTreeSet<_>>();
    let mut result = Vec::new();
    for entry in fs::read_dir(&plan.target)? {
        let entry = entry?;
        let name = entry
            .file_name()
            .into_string()
            .map_err(|_| io::Error::other("non-UTF-8 top-level target entry"))?;
        if name.contains(['\t', '\r', '\n']) {
            return Err(io::Error::other("unsafe top-level target entry"));
        }
        if !preserved.contains(name.as_str()) && excluded != Some(name.as_str()) {
            result.push((name, entry.path()));
        }
    }
    result.sort_by(|left, right| left.0.cmp(&right.0));
    Ok(result)
}

fn direct_names(directory: &Path) -> io::Result<Vec<String>> {
    let mut result = Vec::new();
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        result.push(
            entry
                .file_name()
                .into_string()
                .map_err(|_| io::Error::other("non-UTF-8 entry name"))?,
        );
    }
    result.sort();
    Ok(result)
}

fn regular_files(root: &Path) -> io::Result<Vec<String>> {
    fn visit(root: &Path, directory: &Path, output: &mut Vec<String>) -> io::Result<()> {
        for entry in fs::read_dir(directory)? {
            let entry = entry?;
            let file_type = entry.file_type()?;
            if file_type.is_symlink() {
                return Err(io::Error::other("staged core contains a symbolic link"));
            }
            if file_type.is_dir() {
                visit(root, &entry.path(), output)?;
            } else if file_type.is_file() {
                output.push(
                    entry
                        .path()
                        .strip_prefix(root)
                        .expect("walk stays below root")
                        .to_str()
                        .ok_or_else(|| io::Error::other("non-UTF-8 staged filename"))?
                        .to_owned(),
                );
            } else {
                return Err(io::Error::other("staged core contains a special file"));
            }
        }
        Ok(())
    }
    let mut files = Vec::new();
    visit(root, root, &mut files)?;
    files.sort();
    Ok(files)
}

fn manifest_for(root: &Path, files: &[String]) -> Result<BTreeMap<String, String>, InstallError> {
    files
        .iter()
        .map(|relative| Ok((relative.clone(), sha256_file(&root.join(relative))?)))
        .collect()
}

fn frontend_manifest(
    plan: &ValidatedInstallPlan,
) -> Result<BTreeMap<String, String>, InstallError> {
    plan.frontend_names
        .iter()
        .map(|name| Ok((name.clone(), sha256_file(&plan.frontend_dir.join(name))?)))
        .collect()
}

fn manifest_rows(rows: &BTreeMap<String, String>) -> String {
    rows.iter()
        .map(|(name, hash)| format!("{hash}\t{name}\n"))
        .collect()
}

fn frontend_names(plan: &ValidatedInstallPlan) -> String {
    if plan.frontend_names.is_empty() {
        "-".to_owned()
    } else {
        plan.frontend_names.join(",")
    }
}

fn lines(values: &[String]) -> String {
    values.iter().map(|value| format!("{value}\n")).collect()
}

fn sha256_file(path: &Path) -> io::Result<String> {
    let mut file = File::open(path)?;
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        digest.update(&buffer[..read]);
    }
    Ok(format!("{:x}", digest.finalize()))
}

fn sha256_bytes(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn atomic_write(path: &Path, bytes: &[u8]) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let temporary = path.with_extension(format!("tmp.{}", std::process::id()));
    let mut file = File::create(&temporary)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    fs::rename(temporary, path)?;
    sync_parent(path)
}

fn rename_synced(source: &Path, destination: &Path) -> io::Result<()> {
    fs::rename(source, destination)?;
    sync_parent(destination)?;
    if source.parent() != destination.parent() {
        sync_parent(source)?;
    }
    Ok(())
}

fn sync_parent(path: &Path) -> io::Result<()> {
    File::open(
        path.parent()
            .ok_or_else(|| io::Error::other("path has no parent"))?,
    )?
    .sync_all()
}

fn remove_any(path: &Path) -> io::Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    if metadata.file_type().is_dir() && !metadata.file_type().is_symlink() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    }
}

fn path_exists(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok()
}

fn unique_path(parent: &Path, prefix: &str) -> PathBuf {
    parent.join(format!(
        "{prefix}-{}.{}.{}",
        std::process::id(),
        epoch_seconds(),
        unique_counter()
    ))
}

fn unique_counter() -> u64 {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    NEXT.fetch_add(1, Ordering::Relaxed)
}

fn epoch_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[cfg(test)]
mod tests {
    use std::io::Write;

    use tempfile::TempDir;
    use zip::write::SimpleFileOptions;

    use super::*;
    use crate::FrontendMapEntry;

    fn plan(temp: &TempDir) -> ValidatedInstallPlan {
        ValidatedInstallPlan {
            schema: 1,
            device: "fixture".into(),
            target: temp.path().join("mnt/card/Apps/PortMaster/PortMaster"),
            scripts: temp.path().join("mnt/card/ports"),
            frontend_dir: temp.path().join("mnt/card/Apps/PortMaster"),
            frontend_names: vec!["launch.sh".into(), "icon.png".into()],
            primary_frontend: "launch.sh".into(),
            control_source: Some("device/control.txt".into()),
            core_launcher_source: None,
            frontend_map: vec![
                FrontendMapEntry {
                    source: "device/launcher.sh".into(),
                    destination: "launch.sh".into(),
                },
                FrontendMapEntry {
                    source: "device/icon.png".into(),
                    destination: "icon.png".into(),
                },
            ],
            remove_core_launcher: true,
            empty_tasksetter: true,
            core_executable: None,
            frontend_executable: Some("launch.sh".into()),
            frontend_transforms: Vec::new(),
            preserve_core_entries: ["libs", "config", "themes", "logs", "cache"]
                .map(str::to_owned)
                .to_vec(),
        }
    }

    fn archive(temp: &TempDir, malicious: Option<&str>) -> PathBuf {
        let path = temp.path().join("PortMaster.zip");
        let file = File::create(&path).unwrap();
        let mut zip = zip::ZipWriter::new(file);
        let options =
            SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
        for (name, data) in [
            ("PortMaster/control.txt", b"base".as_slice()),
            ("PortMaster/device_info.txt", b"device"),
            ("PortMaster/funcs.txt", b"funcs"),
            ("PortMaster/PortMaster.sh", b"core launcher"),
            ("PortMaster/pugwash", b"core"),
            ("PortMaster/pylibs/module.py", b"module"),
            ("PortMaster/device/control.txt", b"mapped control"),
            ("PortMaster/device/launcher.sh", b"frontend"),
            ("PortMaster/device/icon.png", b"icon"),
            ("PortMaster/config/archive-owned", b"must not install"),
        ] {
            zip.start_file(name, options).unwrap();
            zip.write_all(data).unwrap();
        }
        if let Some(name) = malicious {
            zip.start_file(name, options).unwrap();
            zip.write_all(b"escape").unwrap();
        }
        zip.finish().unwrap();
        path
    }

    fn request(temp: &TempDir) -> InstallRequest {
        InstallRequest {
            archive: archive(temp, None),
            launcher: temp.path().join("mnt/card/ports/App.sh"),
            state_dir: temp.path().join("state"),
            trash_dir: temp.path().join("trash"),
            cancel_file: None,
            probe_root: Some(temp.path().to_path_buf()),
            plan: plan(temp),
            fail_after_backup: false,
        }
    }

    #[test]
    fn fresh_install_maps_frontend_and_writes_protocol_v1_state() {
        let temp = tempfile::tempdir().unwrap();
        let request = request(&temp);
        let result = install_portmaster(&request).unwrap();
        assert_eq!(result.mode, InstallMode::Install);
        assert_eq!(
            fs::read(request.plan.target.join("control.txt")).unwrap(),
            b"mapped control"
        );
        assert_eq!(
            fs::read(request.plan.frontend_dir.join("launch.sh")).unwrap(),
            b"frontend"
        );
        assert!(!request.plan.target.join("config/archive-owned").exists());
        let pending = fs::read_to_string(request.state_dir.join("pending-install.tsv")).unwrap();
        assert!(pending.starts_with("version\t1\nmode\tinstall\n"));
        assert!(pending.contains(&format!(
            "frontend_rollback\t{}\n",
            request.plan.frontend_dir.join(".appmanager-rollback").display()
        )));
        assert!(pending.contains("frontend_manifest_count\t2\n"));
        assert!(!request.state_dir.join("install-transaction.tsv").exists());
    }

    #[test]
    fn upgrade_replaces_managed_core_and_preserves_resolution_owned_entries() {
        let temp = tempfile::tempdir().unwrap();
        let request = request(&temp);
        fs::create_dir_all(request.plan.target.join("config")).unwrap();
        fs::create_dir_all(request.plan.target.join("libs")).unwrap();
        fs::create_dir_all(request.plan.target.join(".appmanager-state")).unwrap();
        fs::write(request.plan.target.join("config/user.ini"), b"user").unwrap();
        fs::write(request.plan.target.join("libs/runtime"), b"runtime").unwrap();
        fs::write(request.plan.target.join("log.txt"), b"runtime log").unwrap();
        fs::write(request.plan.target.join("pugwash.txt"), b"pugwash state").unwrap();
        fs::write(
            request.plan.target.join("harbourmaster.txt"),
            b"harbourmaster state",
        )
        .unwrap();
        fs::write(
            request.plan.target.join(".appmanager-state/marker"),
            b"transaction state",
        )
        .unwrap();
        fs::write(request.plan.target.join("control.txt"), b"old").unwrap();
        fs::write(request.plan.target.join("obsolete"), b"old").unwrap();
        install_portmaster(&request).unwrap();
        assert_eq!(
            fs::read(request.plan.target.join("config/user.ini")).unwrap(),
            b"user"
        );
        assert_eq!(
            fs::read(request.plan.target.join("libs/runtime")).unwrap(),
            b"runtime"
        );
        assert_eq!(
            fs::read(request.plan.target.join("log.txt")).unwrap(),
            b"runtime log"
        );
        assert_eq!(
            fs::read(request.plan.target.join("pugwash.txt")).unwrap(),
            b"pugwash state"
        );
        assert_eq!(
            fs::read(request.plan.target.join("harbourmaster.txt")).unwrap(),
            b"harbourmaster state"
        );
        assert_eq!(
            fs::read(request.plan.target.join(".appmanager-state/marker")).unwrap(),
            b"transaction state"
        );
        assert!(!request.plan.target.join("obsolete").exists());
        assert!(
            request
                .plan
                .target
                .join(".appmanager-rollback/core/obsolete")
                .exists()
        );
    }

    #[test]
    fn unsafe_zip_entry_is_rejected_before_mutation() {
        let temp = tempfile::tempdir().unwrap();
        let mut request = request(&temp);
        request.archive = archive(&temp, Some("PortMaster/../../escaped"));
        let error = install_portmaster(&request).unwrap_err();
        assert!(matches!(error, InstallError::Archive(_)));
        assert!(!temp.path().join("escaped").exists());
        assert!(!request.state_dir.join("install-transaction.tsv").exists());
    }

    #[test]
    fn replacement_failure_restores_core_and_frontend_automatically() {
        let temp = tempfile::tempdir().unwrap();
        let mut request = request(&temp);
        fs::create_dir_all(&request.plan.target).unwrap();
        fs::create_dir_all(&request.plan.frontend_dir).unwrap();
        fs::write(request.plan.target.join("control.txt"), b"old core").unwrap();
        fs::write(request.plan.frontend_dir.join("launch.sh"), b"old frontend").unwrap();
        request.fail_after_backup = true;
        assert!(install_portmaster(&request).is_err());
        assert_eq!(
            fs::read(request.plan.target.join("control.txt")).unwrap(),
            b"old core"
        );
        assert_eq!(
            fs::read(request.plan.frontend_dir.join("launch.sh")).unwrap(),
            b"old frontend"
        );
        assert!(!request.plan.target.join(".appmanager-rollback").exists());
        assert_eq!(
            fs::read_to_string(request.state_dir.join("install-progress.tsv"))
                .unwrap()
                .split('\t')
                .nth(1),
            Some("rolled-back")
        );
    }

    #[test]
    fn stale_lock_is_replaced_and_cancellation_is_pre_mutation() {
        let temp = tempfile::tempdir().unwrap();
        let mut request = request(&temp);
        fs::create_dir_all(request.state_dir.join("install-lock")).unwrap();
        fs::write(
            request.state_dir.join("install-lock/pid"),
            format!("{}\n", std::process::id()),
        )
        .unwrap();
        request.cancel_file = Some(temp.path().join("cancel"));
        fs::write(request.cancel_file.as_ref().unwrap(), b"").unwrap();
        assert!(matches!(
            install_portmaster(&request),
            Err(InstallError::Cancelled)
        ));
        assert!(!request.plan.target.exists());
    }

    #[test]
    fn lock_file_is_stable_while_the_advisory_lock_changes_owner() {
        let temp = tempfile::tempdir().unwrap();
        let state = temp.path().join("state");
        fs::create_dir(&state).unwrap();
        let guard = acquire_lock(&state).unwrap();
        assert!(matches!(acquire_lock(&state), Err(InstallError::Locked)));
        fs::write(state.join("install-lock"), b"replacement-owner\n").unwrap();
        drop(guard);
        assert_eq!(
            fs::read_to_string(state.join("install-lock")).unwrap(),
            "replacement-owner\n"
        );
        let next = acquire_lock(&state).unwrap();
        drop(next);
        assert!(state.join("install-lock").is_file());
    }

    #[test]
    fn crash_stale_regular_lock_is_reused_but_a_live_lock_is_excluded() {
        let temp = tempfile::tempdir().unwrap();
        let state = temp.path().join("state");
        fs::create_dir(&state).unwrap();
        fs::write(state.join("install-lock"), b"stale-owner\n").unwrap();
        let guard = acquire_lock(&state).unwrap();
        assert!(matches!(acquire_lock(&state), Err(InstallError::Locked)));
        assert_ne!(
            fs::read_to_string(state.join("install-lock")).unwrap(),
            "stale-owner\n"
        );
        drop(guard);
        assert!(state.join("install-lock").is_file());
    }

    #[test]
    fn extraction_enforces_entry_and_total_expansion_limits() {
        let temp = tempfile::tempdir().unwrap();
        let archive = temp.path().join("bounded.zip");
        let mut zip = zip::ZipWriter::new(File::create(&archive).unwrap());
        let options = SimpleFileOptions::default();
        for (name, bytes) in [
            ("PortMaster/one", b"123".as_slice()),
            ("PortMaster/two", b"456".as_slice()),
        ] {
            zip.start_file(name, options).unwrap();
            zip.write_all(bytes).unwrap();
        }
        zip.finish().unwrap();

        let limits = ArchiveLimits {
            entries: 2,
            entry_bytes: 3,
            total_bytes: 5,
        };
        assert!(matches!(
            extract_archive_with_limits(&archive, &temp.path().join("stage"), limits),
            Err(InstallError::Archive(message)) if message.contains("total expansion")
        ));
        let limits = ArchiveLimits {
            entries: 1,
            entry_bytes: 3,
            total_bytes: 6,
        };
        assert!(matches!(
            extract_archive_with_limits(&archive, &temp.path().join("stage-2"), limits),
            Err(InstallError::Archive(message)) if message.contains("too many entries")
        ));
    }

    #[test]
    fn nested_pylibs_zip_is_fully_read_and_crc_checked() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("pylibs.zip");
        let mut zip = zip::ZipWriter::new(File::create(&path).unwrap());
        let options =
            SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
        zip.start_file("module.py", options).unwrap();
        zip.write_all(b"crc-payload").unwrap();
        zip.finish().unwrap();
        let mut bytes = fs::read(&path).unwrap();
        let offset = bytes
            .windows(b"crc-payload".len())
            .position(|window| window == b"crc-payload")
            .unwrap();
        bytes[offset] ^= 1;
        fs::write(&path, bytes).unwrap();
        assert!(matches!(
            validate_nested_zip(&path),
            Err(InstallError::Archive(message)) if message.contains("pylibs.zip")
        ));
    }

    #[test]
    fn nested_pylibs_zip_rejects_unsafe_paths() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("pylibs.zip");
        let mut zip = zip::ZipWriter::new(File::create(&path).unwrap());
        zip.start_file("../escape.py", SimpleFileOptions::default())
            .unwrap();
        zip.write_all(b"escape").unwrap();
        zip.finish().unwrap();
        assert!(matches!(
            validate_nested_zip(&path),
            Err(InstallError::Archive(message)) if message.contains("unsafe path")
        ));
    }

    #[test]
    fn declared_library_transform_probes_fixture_root_and_writes_device_path() {
        let temp = tempfile::tempdir().unwrap();
        let mut request = request(&temp);
        let device_candidate = PathBuf::from("/usr/device-libs");
        let probe = temp.path().join("usr/device-libs");
        fs::create_dir_all(&probe).unwrap();
        for name in ["libSDL2.so", "libSDL2_image.so"] {
            fs::write(probe.join(name), b"library").unwrap();
        }
        request.plan.frontend_transforms = vec![FrontendTransform::ExportLibraryGroup {
            target: "launch.sh".into(),
            variable: "PYSDL2_DLL_PATH".into(),
            candidates: vec![device_candidate],
            required_sonames: vec!["libSDL2.so".into(), "libSDL2_image.so".into()],
        }];
        request.probe_root = Some(temp.path().to_path_buf());
        request.archive = {
            let path = temp.path().join("transform.zip");
            let file = File::create(&path).unwrap();
            let mut zip = zip::ZipWriter::new(file);
            let options = SimpleFileOptions::default();
            for (name, data) in [
                ("PortMaster/control.txt", b"base".as_slice()),
                ("PortMaster/device_info.txt", b"device"),
                ("PortMaster/funcs.txt", b"funcs"),
                ("PortMaster/PortMaster.sh", b"core launcher"),
                ("PortMaster/pugwash", b"core"),
                ("PortMaster/pylibs/module.py", b"module"),
                ("PortMaster/device/control.txt", b"mapped control"),
                (
                    "PortMaster/device/launcher.sh",
                    b"#!/bin/sh\nexport PYSDL2_DLL_PATH=\"/old/path\"\nexec app\n",
                ),
                ("PortMaster/device/icon.png", b"icon"),
            ] {
                zip.start_file(name, options).unwrap();
                zip.write_all(data).unwrap();
            }
            zip.finish().unwrap();
            path
        };
        install_portmaster(&request).unwrap();
        let launcher = fs::read_to_string(request.plan.frontend_dir.join("launch.sh")).unwrap();
        assert!(launcher.contains("export PYSDL2_DLL_PATH='/usr/device-libs'"));
        assert!(!launcher.contains(temp.path().to_str().unwrap()));
    }

    #[test]
    fn rendered_library_export_cannot_inject_shell_syntax() {
        assert_eq!(
            shell_single_quote("/tmp/a'; touch /tmp/pwned; #"),
            "'/tmp/a'\"'\"'; touch /tmp/pwned; #'"
        );
    }

    #[test]
    fn rejects_target_state_trash_and_recursive_root_overlap() {
        let temp = tempfile::tempdir().unwrap();
        let mut candidate = request(&temp);
        candidate.state_dir = candidate.plan.target.join("state");
        let error = validate_request(&candidate).unwrap_err();
        assert!(error.to_string().contains("app state root overlap"));

        let mut candidate = request(&temp);
        candidate.trash_dir = candidate.plan.target.join("trash");
        let error = validate_request(&candidate).unwrap_err();
        assert!(error.to_string().contains("trash root overlap"));

        let mut candidate = request(&temp);
        candidate.plan.frontend_dir = candidate.plan.target.join("frontend");
        let error = validate_request(&candidate).unwrap_err();
        assert!(error.to_string().contains("recursively replaced target"));

        let mut candidate = request(&temp);
        candidate.plan.target = PathBuf::from("/");
        assert!(validate_request(&candidate).is_err());

        let mut candidate = request(&temp);
        candidate.plan.target = temp.path().join("mnt/card");
        assert!(validate_request(&candidate).is_err());
    }

    #[test]
    fn rejects_system_namespace_and_cross_anchor_dynamic_scripts() {
        let temp = tempfile::tempdir().unwrap();
        let mut candidate = request(&temp);
        candidate.plan.frontend_dir = temp.path().join("etc/PortMaster");
        let error = validate_request(&candidate).unwrap_err();
        assert!(error.to_string().contains("protected system namespace"));

        let mut candidate = request(&temp);
        candidate.state_dir = temp.path().join("etc/appmanager-state");
        let error = validate_request(&candidate).unwrap_err();
        assert!(error.to_string().contains("protected system namespace"));

        let mut candidate = request(&temp);
        candidate.plan.scripts = temp.path().join("media/other/ports");
        let error = validate_request(&candidate).unwrap_err();
        assert!(error.to_string().contains("same storage anchor"));
    }

    #[test]
    fn allows_bounded_target_parent_and_safe_existing_explicit_root() {
        let temp = tempfile::tempdir().unwrap();
        let mut candidate = request(&temp);
        candidate.plan.target = temp.path().join("mnt/card/ports/PortMaster");
        candidate.plan.frontend_dir = candidate.plan.scripts.clone();
        assert!(validate_request(&candidate).is_ok());

        let mut candidate = request(&temp);
        candidate.plan.target = temp.path().join("opt/tools/PortMaster");
        fs::create_dir_all(&candidate.plan.target).unwrap();
        assert!(validate_request(&candidate).is_ok());

        candidate.plan.target = temp.path().join("opt/tools/not-portmaster");
        fs::create_dir_all(&candidate.plan.target).unwrap();
        let error = validate_request(&candidate).unwrap_err();
        assert!(error.to_string().contains("app-specific PortMaster leaf"));
    }

    #[test]
    fn allows_existing_home_app_data_and_distinct_storage_anchors() {
        let temp = tempfile::tempdir().unwrap();
        let mut candidate = request(&temp);
        candidate.plan.frontend_dir = temp.path().join("root/.local/share/PortMaster");
        fs::create_dir_all(&candidate.plan.frontend_dir).unwrap();
        assert!(validate_request(&candidate).is_ok());

        candidate.plan.target = temp.path().join("mnt/other/MUOS/PortMaster");
        candidate.plan.frontend_dir = temp.path().join("roms/ports/PortMaster");
        assert!(validate_request(&candidate).is_ok());
    }

    #[cfg(unix)]
    #[test]
    fn overlap_detection_resolves_existing_parent_aliases() {
        use std::os::unix::fs::symlink;

        let temp = tempfile::tempdir().unwrap();
        let mut candidate = request(&temp);
        let actual = temp.path().join("mnt/card/Apps");
        fs::create_dir_all(&actual).unwrap();
        symlink(&actual, temp.path().join("alias")).unwrap();
        candidate.plan.target = actual.join("PortMaster");
        candidate.state_dir = temp.path().join("alias/PortMaster/state");
        let error = validate_request(&candidate).unwrap_err();
        assert!(error.to_string().contains("app state root overlap"));

        let mut candidate = request(&temp);
        fs::create_dir_all(temp.path().join("etc/PortMaster")).unwrap();
        symlink(temp.path().join("etc"), temp.path().join("safe-looking")).unwrap();
        candidate.plan.frontend_dir = temp.path().join("safe-looking/PortMaster");
        let error = validate_request(&candidate).unwrap_err();
        assert!(error.to_string().contains("protected system namespace"));
    }

    #[test]
    fn parent_frontend_exception_still_requires_direct_child_contract() {
        let temp = tempfile::tempdir().unwrap();
        let mut request = request(&temp);
        request.plan.frontend_map[0].destination = "../escape".to_owned();
        let error = validate_request(&request).unwrap_err();
        assert!(error.to_string().contains("direct-child"));
    }
}
