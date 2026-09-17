// INPUT:  ValidatedInstallPlan、ZIP 包、ManagedRoot、文件锁与任务取消/进度通道
// OUTPUT: InstallRequest/Outcome、install_portmaster()、recover_portmaster_transactions()
// POS:    PortMaster 有界解压、前端适配、事务替换与崩溃恢复实现
use std::collections::BTreeSet;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use portkit_core::ExclusiveFileLock;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use zip::ZipArchive;

use crate::{
    CancellationToken, FrontendTransform, ManagedRoot, ProgressChannel, TaskProgress,
    ValidatedInstallPlan,
};

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
/// Runtime state files written by the official PortMaster package. Preserving
/// them across core reinstalls is part of the PortMaster package contract, so
/// this list is a compiled-in constant shared with other consumers.
pub const PORTMASTER_STATE_PRESERVED: &[&str] = &["log.txt", "pugwash.txt", "harbourmaster.txt"];

#[derive(Debug, Clone)]
pub struct InstallRequest {
    pub archive: PathBuf,
    pub state_dir: PathBuf,
    pub trash_dir: PathBuf,
    pub cancel_token: Option<CancellationToken>,
    pub progress_channel: Option<ProgressChannel>,
    /// Optional filesystem prefix used only to probe device-absolute library candidates in tests.
    pub probe_root: Option<PathBuf>,
    pub plan: ValidatedInstallPlan,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum InstallMode {
    Install,
    Update,
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
    #[error("unsafe or invalid PortMaster archive: {0}")]
    Archive(String),
    #[error("storage card is not writable: cannot create directory {path}: {source}")]
    StorageNotWritable {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error("installation failed: {0}")]
    Io(#[from] io::Error),
}

const TRANSACTION_PREFIX: &str = ".pm-install-v1-";

struct WorkGuard {
    path: PathBuf,
    cleanup: bool,
}

impl WorkGuard {
    fn new(path: PathBuf) -> Self {
        Self {
            path,
            cleanup: true,
        }
    }

    fn preserve(&mut self) {
        self.cleanup = false;
    }
}

impl Drop for WorkGuard {
    fn drop(&mut self) {
        if self.cleanup {
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct SwapJournal {
    schema: u32,
    transaction_id: String,
    old_core: Vec<String>,
    old_frontend: Vec<String>,
    new_core: Vec<String>,
    new_frontend: Vec<String>,
}

pub fn install_portmaster(request: &InstallRequest) -> Result<InstallOutcome, InstallError> {
    let result = install_portmaster_inner(request);
    if let Err(error) = &result
        && !matches!(error, InstallError::Cancelled)
    {
        progress(request, "failed", 0, &error.to_string());
    }
    result
}

/// Recover a PortMaster swap left by a crashed process before any new archive
/// is downloaded or staged. This is safe to call at APP startup.
pub fn recover_portmaster_transactions(
    plan: &ValidatedInstallPlan,
    state_dir: &Path,
) -> Result<(), InstallError> {
    if !plan.target.exists() && !plan.frontend_dir.exists() {
        return Ok(());
    }
    fs::create_dir_all(state_dir)?;
    fs::create_dir_all(&plan.target)?;
    fs::create_dir_all(&plan.frontend_dir)?;
    let _lock = acquire_lock(state_dir)?;
    sweep_stale_artifacts(plan, &[])
}

fn install_portmaster_inner(request: &InstallRequest) -> Result<InstallOutcome, InstallError> {
    validate_request(request)?;
    cancel(request)?;
    ensure_install_directory(&request.plan.scripts)?;
    ensure_install_directory(&request.plan.frontend_dir)?;
    ensure_install_directory(&request.plan.target)?;
    ensure_install_directory(&request.state_dir)?;
    progress(request, "extracting", 10, "Extracting PortMaster core");

    let (transaction_id, core_work, frontend_work) =
        allocate_work_pair(&request.plan.target, &request.plan.frontend_dir)?;
    let mut core_work_guard = WorkGuard::new(core_work.clone());
    let mut frontend_work_guard = WorkGuard::new(frontend_work.clone());
    let staged_core = core_work.join("stage");
    let staged_frontend = frontend_work.join("stage");
    fs::create_dir_all(&staged_core)?;
    fs::create_dir_all(&staged_frontend)?;
    extract_archive(
        &request.archive,
        &staged_core,
        request.cancel_token.as_ref(),
    )?;
    prepare_staging(
        &request.plan,
        &staged_core,
        &staged_frontend,
        request.probe_root.as_deref(),
    )?;
    let staged_files = regular_files(&staged_core)?;
    if staged_files.is_empty() {
        return Err(InstallError::Archive("managed core is empty".into()));
    }
    sync_tree(&staged_core)?;
    sync_tree(&staged_frontend)?;
    cancel(request)?;

    let _lock = acquire_lock(&request.state_dir)?;
    sweep_stale_artifacts(&request.plan, &[&core_work, &frontend_work])?;
    cancel(request)?;

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
    progress(request, "installing", 60, "Replacing managed core");

    // Retire the current managed entries into same-filesystem work
    // directories. The journal is durable before the first rename, so both an
    // ordinary I/O failure and a process/device crash can restore the previous
    // core instead of leaving a half-installed system.
    let retired_core = core_work.join("retired");
    let retired_frontend = frontend_work.join("retired");
    fs::create_dir_all(&retired_core)?;
    fs::create_dir_all(&retired_frontend)?;
    let stage_name = core_work
        .file_name()
        .and_then(|name| name.to_str())
        .expect("generated stage name is UTF-8");
    let old_core = managed_top_entries(&request.plan, Some(stage_name))?;
    let new_core = direct_names(&staged_core)?;
    let journal = SwapJournal {
        schema: 1,
        transaction_id: transaction_id.clone(),
        old_core: old_core.iter().map(|(name, _)| name.clone()).collect(),
        old_frontend: frontend_existing.clone(),
        new_core: new_core.clone(),
        new_frontend: request.plan.frontend_names.clone(),
    };
    write_swap_journal(&core_work, &journal)?;
    let swap = (|| -> io::Result<()> {
        for (name, path) in &old_core {
            rename_synced(path, &retired_core.join(name))?;
        }
        for name in &frontend_existing {
            rename_synced(
                &request.plan.frontend_dir.join(name),
                &retired_frontend.join(name),
            )?;
        }
        for name in &new_core {
            rename_synced(&staged_core.join(name), &request.plan.target.join(name))?;
        }
        for name in &request.plan.frontend_names {
            rename_synced(
                &staged_frontend.join(name),
                &request.plan.frontend_dir.join(name),
            )?;
        }
        set_executables(&request.plan)
    })();
    if let Err(swap_error) = swap {
        if let Err(rollback_error) =
            rollback_swap(&request.plan, &core_work, &frontend_work, &journal, true)
        {
            core_work_guard.preserve();
            frontend_work_guard.preserve();
            return Err(InstallError::Io(io::Error::other(format!(
                "swap failed: {swap_error}; rollback failed: {rollback_error}"
            ))));
        }
        return Err(InstallError::Io(swap_error));
    }
    if let Err(commit_error) = write_commit_marker(&core_work) {
        if let Err(rollback_error) =
            rollback_swap(&request.plan, &core_work, &frontend_work, &journal, true)
        {
            core_work_guard.preserve();
            frontend_work_guard.preserve();
            return Err(InstallError::Io(io::Error::other(format!(
                "cannot commit install journal: {commit_error}; rollback failed: {rollback_error}"
            ))));
        }
        return Err(InstallError::Io(commit_error));
    }
    // The replacement above is the commit point. A removable filesystem may
    // reject this final UI-only write; never report a committed install as
    // failed because its completion message could not be persisted.
    progress(request, "complete", 100, "PortMaster core installed");
    Ok(InstallOutcome {
        device: request.plan.device.clone(),
        target: request.plan.target.clone(),
        mode,
        status: "installed",
        manifest_count: staged_files.len(),
        frontend_manifest_count: request.plan.frontend_names.len(),
    })
}

fn ensure_install_directory(path: &Path) -> Result<(), InstallError> {
    fs::create_dir_all(path).map_err(|source| InstallError::StorageNotWritable {
        path: path.to_path_buf(),
        source,
    })?;
    if !path.is_dir() {
        return Err(InstallError::StorageNotWritable {
            path: path.to_path_buf(),
            source: io::Error::new(
                io::ErrorKind::AlreadyExists,
                "the configured path is not a directory",
            ),
        });
    }
    Ok(())
}

// Removes per-run work directories left by a crashed install.
fn sweep_stale_artifacts(plan: &ValidatedInstallPlan, keep: &[&Path]) -> Result<(), InstallError> {
    for name in direct_names(&plan.target)? {
        if !name.starts_with(TRANSACTION_PREFIX) {
            continue;
        }
        let core_work = plan.target.join(&name);
        if keep.iter().any(|kept| **kept == core_work) {
            continue;
        }
        let journal_path = core_work.join("swap.json");
        if !core_work.join("owner").is_file() && !journal_path.is_file() {
            // Crash before transaction publication: no managed rename could
            // have occurred because swap.json is written after both owners.
            remove_any(&plan.frontend_dir.join(&name))?;
            remove_any(&core_work)?;
            continue;
        }
        validate_transaction_owner(&core_work, &name)?;
        if journal_path.is_file() {
            let journal: SwapJournal =
                serde_json::from_slice(&fs::read(&journal_path)?).map_err(|error| {
                    InstallError::Invalid(format!("invalid stale install journal: {error}"))
                })?;
            validate_journal(&journal, &name)?;
            let frontend_work = plan.frontend_dir.join(&journal.transaction_id);
            match fs::symlink_metadata(&frontend_work) {
                Ok(_) => validate_transaction_owner(&frontend_work, &journal.transaction_id)?,
                // Recovery may have completed and removed the frontend half
                // immediately before power was lost. The core journal is the
                // authoritative half and rollback is idempotent without it.
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => return Err(InstallError::Io(error)),
            }
            if !core_work.join("committed").is_file() {
                // A stale journal is filesystem input, not authority to
                // delete a live new-only name. Restoring entries that have a
                // real retired backup is safe; any extra new entry is left for
                // the immediately following install to retire and replace.
                rollback_swap(plan, &core_work, &frontend_work, &journal, false)?;
            }
            remove_any(&frontend_work)?;
        }
        remove_any(&core_work)?;
    }
    for name in direct_names(&plan.frontend_dir)? {
        if !name.starts_with(TRANSACTION_PREFIX) {
            continue;
        }
        let path = plan.frontend_dir.join(name);
        if !keep.iter().any(|kept| **kept == path) {
            let name = path
                .file_name()
                .and_then(|name| name.to_str())
                .ok_or_else(|| InstallError::Invalid("work name is not UTF-8".to_owned()))?;
            if !path.join("owner").is_file() {
                // Frontend work without an owner is necessarily from the
                // create-dir window before either staging or swapping.
                remove_any(&path)?;
                continue;
            }
            validate_transaction_owner(&path, name)?;
            // Orphan frontend stages have no journal and therefore predate
            // the first managed rename; they are safe to discard.
            remove_any(&path)?;
        }
    }
    Ok(())
}

fn allocate_work_pair(
    core_parent: &Path,
    frontend_parent: &Path,
) -> Result<(String, PathBuf, PathBuf), InstallError> {
    for _ in 0..128 {
        let transaction_id = secure_transaction_name()?;
        let core_work = core_parent.join(&transaction_id);
        let frontend_work = frontend_parent.join(&transaction_id);
        match fs::create_dir(&core_work) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(InstallError::Io(error)),
        }
        test_pm_crash_point("after-core-work-dir");
        if let Err(error) = fs::create_dir(&frontend_work) {
            let _ = fs::remove_dir(&core_work);
            if error.kind() == io::ErrorKind::AlreadyExists {
                continue;
            }
            return Err(InstallError::Io(error));
        }
        test_pm_crash_point("after-frontend-work-dir");
        let write_owners = write_owner(&core_work, &transaction_id).and_then(|()| {
            test_pm_crash_point("after-core-owner");
            write_owner(&frontend_work, &transaction_id)
        });
        if let Err(error) = write_owners {
            let _ = fs::remove_dir_all(&frontend_work);
            let _ = fs::remove_dir_all(&core_work);
            return Err(InstallError::Io(error));
        }
        return Ok((transaction_id, core_work, frontend_work));
    }
    Err(InstallError::Invalid(
        "cannot allocate an install transaction".to_owned(),
    ))
}

#[cfg(test)]
fn test_pm_crash_point(point: &str) {
    if std::env::var("PAM_TEST_PM_CRASH_POINT").as_deref() == Ok(point) {
        std::process::exit(87);
    }
}

#[cfg(not(test))]
fn test_pm_crash_point(_point: &str) {}

fn write_owner(work: &Path, transaction_id: &str) -> io::Result<()> {
    let path = work.join("owner");
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)?;
    output.write_all(transaction_id.as_bytes())?;
    output.flush()?;
    output.sync_all()?;
    sync_parent(&path)
}

fn validate_transaction_owner(work: &Path, expected: &str) -> Result<(), InstallError> {
    let metadata = fs::symlink_metadata(work).map_err(|error| {
        InstallError::Invalid(format!("invalid transaction directory: {error}"))
    })?;
    if !metadata.file_type().is_dir() || metadata.file_type().is_symlink() {
        return Err(InstallError::Invalid(
            "transaction path is not a real directory".to_owned(),
        ));
    }
    let owner = work.join("owner");
    let owner_metadata = fs::symlink_metadata(&owner)
        .map_err(|_| InstallError::Invalid("transaction owner marker is missing".to_owned()))?;
    if !owner_metadata.file_type().is_file()
        || fs::read_to_string(owner).ok().as_deref() != Some(expected)
    {
        return Err(InstallError::Invalid(
            "transaction owner marker is invalid".to_owned(),
        ));
    }
    Ok(())
}

fn validate_journal(
    journal: &SwapJournal,
    expected_transaction_id: &str,
) -> Result<(), InstallError> {
    if journal.schema != 1
        || journal.transaction_id != expected_transaction_id
        || !journal.transaction_id.starts_with(TRANSACTION_PREFIX)
        || journal.transaction_id.len() != TRANSACTION_PREFIX.len() + 64
        || !journal.transaction_id[TRANSACTION_PREFIX.len()..]
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit())
    {
        return Err(InstallError::Invalid(
            "install journal is not owned by its transaction directory".to_owned(),
        ));
    }
    ManagedRoot::validate_child_name(&journal.transaction_id)
        .map_err(|error| InstallError::Invalid(format!("unsafe install journal: {error}")))?;
    for name in journal
        .old_core
        .iter()
        .chain(&journal.old_frontend)
        .chain(&journal.new_core)
        .chain(&journal.new_frontend)
    {
        ManagedRoot::validate_child_name(name)
            .map_err(|error| InstallError::Invalid(format!("unsafe install journal: {error}")))?;
    }
    Ok(())
}

fn write_swap_journal(work: &Path, journal: &SwapJournal) -> io::Result<()> {
    let path = work.join("swap.json");
    let temporary = work.join("swap.json.new");
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)?;
    serde_json::to_writer(&mut output, journal).map_err(io::Error::other)?;
    output.flush()?;
    output.sync_all()?;
    fs::rename(&temporary, &path)?;
    sync_parent(&path)
}

fn write_commit_marker(work: &Path) -> io::Result<()> {
    let path = work.join("committed");
    let output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)?;
    output.sync_all()?;
    sync_parent(&path)
}

fn rollback_swap(
    plan: &ValidatedInstallPlan,
    core_work: &Path,
    frontend_work: &Path,
    journal: &SwapJournal,
    remove_new_only: bool,
) -> io::Result<()> {
    rollback_domain(
        &plan.frontend_dir,
        &frontend_work.join("retired"),
        &journal.old_frontend,
        &journal.new_frontend,
        remove_new_only,
    )?;
    rollback_domain(
        &plan.target,
        &core_work.join("retired"),
        &journal.old_core,
        &journal.new_core,
        remove_new_only,
    )
}

fn rollback_domain(
    live: &Path,
    retired: &Path,
    old_names: &[String],
    new_names: &[String],
    remove_new_only: bool,
) -> io::Result<()> {
    let old = old_names
        .iter()
        .map(String::as_str)
        .collect::<BTreeSet<_>>();
    for name in old_names.iter().rev() {
        let backup = retired.join(name);
        if path_exists(&backup) {
            let destination = live.join(name);
            if remove_new_only || !path_exists(&destination) {
                remove_any(&destination)?;
                rename_synced(&backup, &destination)?;
            }
        }
    }
    // If an old entry's backup is already gone, a previous recovery pass has
    // restored it. Never delete it again. Entries which had no old value are
    // always safe to remove, making this rollback crash-idempotent.
    if remove_new_only {
        for name in new_names.iter().rev() {
            if old.contains(name.as_str()) {
                continue;
            }
            let path = live.join(name);
            if path_exists(&path) {
                remove_any(&path)?;
                sync_parent(&path)?;
            }
        }
    }
    Ok(())
}

fn validate_request(request: &InstallRequest) -> Result<(), InstallError> {
    if request.plan.schema != 1 {
        return Err(InstallError::Invalid("unsupported plan schema".to_owned()));
    }
    if !request.archive.is_file() {
        return Err(InstallError::Invalid("archive is not a file".to_owned()));
    }
    for (name, path) in [
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

    // Platform config is the sole source of path layout. This layer validates
    // path roles and containment only; it must not classify device mount roots.
    let resolved = |path: &Path| {
        ManagedRoot::new(path)
            .map(|root| root.resolved_path().to_path_buf())
            .map_err(|error| InstallError::Invalid(error.to_string()))
    };
    let target_resolved = resolved(&plan.target)?;
    let frontend_resolved = resolved(&plan.frontend_dir)?;
    let scripts_resolved = resolved(&plan.scripts)?;
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

    let scripts_device = device_path(&scripts_resolved, request.probe_root.as_deref());
    let target_device = device_path(&target_resolved, request.probe_root.as_deref());
    if !app_specific_leaf(&target_device) {
        return Err(InstallError::Invalid(
            "PortMaster target must be an app-specific PortMaster leaf".to_owned(),
        ));
    }
    if protected_system_namespace(&target_device) {
        return Err(InstallError::Invalid(format!(
            "target root {} is in a protected system namespace",
            target_device.display()
        )));
    }
    for (name, root) in [("app state", &state_resolved), ("trash", &trash_resolved)] {
        let device = device_path(root, request.probe_root.as_deref());
        if protected_system_namespace(&device) {
            return Err(InstallError::Invalid(format!(
                "{name} root {} is in a protected system namespace",
                device.display()
            )));
        }
    }
    if protected_system_namespace(&scripts_device) {
        return Err(InstallError::Invalid(format!(
            "scripts root {} is in a protected system namespace",
            scripts_device.display()
        )));
    }

    let frontend_device = device_path(&frontend_resolved, request.probe_root.as_deref());
    let supported_root_frontend = frontend_device
        .strip_prefix("/root/.local/share")
        .is_ok_and(|relative| relative.components().count() == 1);
    if protected_system_namespace(&frontend_device) && !supported_root_frontend {
        return Err(InstallError::Invalid(format!(
            "frontend root {} is in a protected system namespace",
            frontend_device.display()
        )));
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

fn protected_system_namespace(path: &Path) -> bool {
    const FORBIDDEN: &[&str] = &[
        "/bin", "/boot", "/dev", "/etc", "/lib", "/lib64", "/proc", "/root", "/sbin", "/sys",
        "/usr", "/var",
    ];
    FORBIDDEN.iter().any(|root| path.starts_with(root))
        || path == Path::new("/run")
        || (path.starts_with("/run") && !path.starts_with("/run/media"))
}

fn app_specific_leaf(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name.eq_ignore_ascii_case("PortMaster"))
}

fn cancel(request: &InstallRequest) -> Result<(), InstallError> {
    if request
        .cancel_token
        .as_ref()
        .is_some_and(CancellationToken::is_cancelled)
    {
        progress(
            request,
            "cancelled",
            0,
            "Installation cancelled before core replacement",
        );
        return Err(InstallError::Cancelled);
    }
    Ok(())
}

fn progress(request: &InstallRequest, phase: &str, percent: u8, detail: &str) {
    let detail = detail.replace(['\t', '\r', '\n'], " ");
    if let Some(channel) = &request.progress_channel {
        channel.publish(TaskProgress {
            phase: phase.to_owned(),
            runtime: "PortMaster".into(),
            index: 0,
            count: 1,
            current: u64::from(percent),
            total: 100,
            speed: 0,
            detail: detail.clone(),
        });
    }
}

fn acquire_lock(state: &Path) -> Result<ExclusiveFileLock, InstallError> {
    ExclusiveFileLock::try_acquire(&state.join("install.lock")).map_err(|error| {
        if error.kind() == io::ErrorKind::WouldBlock {
            InstallError::Locked
        } else {
            InstallError::Io(error)
        }
    })
}

fn extract_archive(
    archive: &Path,
    staged_core: &Path,
    cancel_token: Option<&CancellationToken>,
) -> Result<(), InstallError> {
    extract_archive_with_limits_and_cancel(archive, staged_core, ARCHIVE_LIMITS, cancel_token)
}

#[cfg(test)]
fn extract_archive_with_limits(
    archive: &Path,
    staged_core: &Path,
    limits: ArchiveLimits,
) -> Result<(), InstallError> {
    extract_archive_with_limits_and_cancel(archive, staged_core, limits, None)
}

fn extract_archive_with_limits_and_cancel(
    archive: &Path,
    staged_core: &Path,
    limits: ArchiveLimits,
    cancel_token: Option<&CancellationToken>,
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
        cancel_token_check(cancel_token)?;
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
        copy_bounded(
            &mut entry,
            &mut target,
            &raw,
            &mut total,
            limits,
            cancel_token,
        )?;
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
        let Component::Normal(name) = component else {
            return Err(InstallError::Archive(format!("unsafe path: {value:?}")));
        };
        if name
            .to_str()
            .is_some_and(|name| name.starts_with(".pm-install") || name.starts_with(".pam-install"))
        {
            return Err(InstallError::Archive(format!(
                "reserved transaction path: {value:?}"
            )));
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
    cancel_token: Option<&CancellationToken>,
) -> Result<(), InstallError> {
    let mut entry_bytes = 0_u64;
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        cancel_token_check(cancel_token)?;
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

fn cancel_token_check(cancel_token: Option<&CancellationToken>) -> Result<(), InstallError> {
    if cancel_token.is_some_and(CancellationToken::is_cancelled) {
        Err(InstallError::Cancelled)
    } else {
        Ok(())
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
            None,
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
        .chain(PORTMASTER_STATE_PRESERVED.iter().copied())
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
        .chain(PORTMASTER_STATE_PRESERVED.iter().copied())
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

fn sync_tree(path: &Path) -> io::Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() {
        return Err(io::Error::other("cannot sync a symbolic link"));
    }
    if metadata.is_file() {
        return File::open(path)?.sync_all();
    }
    for entry in fs::read_dir(path)? {
        sync_tree(&entry?.path())?;
    }
    File::open(path)?.sync_all()
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

fn secure_transaction_name() -> io::Result<String> {
    let mut bytes = [0_u8; 32];
    File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    Ok(format!(
        "{TRANSACTION_PREFIX}{}",
        bytes
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>()
    ))
}

fn unique_counter() -> u64 {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    NEXT.fetch_add(1, Ordering::Relaxed)
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::io::Write;

    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt as _;

    use tempfile::TempDir;

    fn current_test_executable() -> PathBuf {
        std::env::var_os("PAM_LAB_TEST_EXECUTABLE")
            .map(PathBuf::from)
            .unwrap_or_else(|| std::env::current_exe().unwrap())
    }
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
        let plan = plan(temp);
        fs::create_dir_all(&plan.scripts).unwrap();
        fs::create_dir_all(&plan.frontend_dir).unwrap();
        InstallRequest {
            archive: archive(temp, None),
            state_dir: temp.path().join("state"),
            trash_dir: temp.path().join("trash"),
            cancel_token: None,
            progress_channel: None,
            probe_root: Some(temp.path().to_path_buf()),
            plan,
        }
    }

    fn resolved_miniloong_request(
        root: &Path,
        profile: &str,
    ) -> (crate::ResolvedDeviceContext, ValidatedInstallPlan) {
        let launcher = match profile {
            "miniloong" => PathBuf::from("/mnt/sdcard/roms/ports/APP Manager.sh"),
            "miniloong-loongos" => PathBuf::from("/roms/ports/APP Manager.sh"),
            other => panic!("unsupported release fixture profile {other}"),
        };
        let launcher_on_disk = root.join(launcher.strip_prefix("/").unwrap());
        fs::create_dir_all(launcher_on_disk.parent().unwrap()).unwrap();
        fs::write(&launcher_on_disk, b"#!/bin/sh\n").unwrap();

        fs::create_dir_all(root.join("loong")).unwrap();
        fs::write(
            root.join("loong/loong_version"),
            b"{\"verShow\":\"1.3.0.32\"}\n",
        )
        .unwrap();
        if profile == "miniloong-loongos" {
            fs::create_dir_all(root.join("etc")).unwrap();
            fs::write(
                root.join("etc/os-release"),
                b"NAME=LoongOS\nID=loong\nVERSION_ID=\"1.4.0.27\"\n",
            )
            .unwrap();
        }

        let config_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../config");
        let resolution = crate::resolve_device(crate::DeviceResolutionRequest {
            launcher,
            app_state: root.join("pam-state"),
            trash: root.join("pam-trash"),
            target_override: None,
            probe_root: Some(root.to_path_buf()),
            environment: BTreeMap::new(),
            config: crate::DeviceConfigSources {
                embedded_root: fs::read(config_dir.join("config.json")).unwrap(),
                embedded_dir: config_dir,
                remote_root: None,
                remote_dir: None,
            },
        })
        .unwrap();
        assert_eq!(resolution.context.profile, profile);
        let plan = crate::InstallPlan::from_context(&resolution.context)
            .unwrap()
            .validate(&resolution.context)
            .unwrap();
        (resolution.context, plan)
    }

    #[test]
    fn maintained_portmaster_candidate_installs_for_miniloong_profiles() {
        let Some(candidate) = std::env::var_os("PAM_PORTMASTER_CANDIDATE") else {
            eprintln!("PAM_PORTMASTER_CANDIDATE is not set; maintained-candidate test skipped");
            return;
        };
        let candidate = PathBuf::from(candidate);
        assert!(
            candidate.is_file(),
            "candidate is missing: {}",
            candidate.display()
        );

        for profile in ["miniloong", "miniloong-loongos"] {
            let temp = tempfile::tempdir().unwrap();
            let (_context, plan) = resolved_miniloong_request(temp.path(), profile);
            let request = InstallRequest {
                archive: candidate.clone(),
                state_dir: temp.path().join("state"),
                trash_dir: temp.path().join("trash"),
                cancel_token: None,
                progress_channel: None,
                probe_root: Some(temp.path().to_path_buf()),
                plan,
            };

            let installed = install_portmaster(&request).unwrap();
            assert_eq!(installed.mode, InstallMode::Install, "{profile}");
            assert!(
                request.plan.target.join("control.txt").is_file(),
                "{profile}"
            );
            assert!(
                request.plan.target.join("PortMaster.sh").is_file(),
                "{profile}"
            );
            assert!(
                request.plan.frontend_dir.join("PortMaster.sh").is_file(),
                "{profile}"
            );
            let core_launcher = fs::read(request.plan.target.join("PortMaster.sh")).unwrap();
            let frontend_launcher =
                fs::read(request.plan.frontend_dir.join("PortMaster.sh")).unwrap();
            if profile == "miniloong-loongos" {
                assert_eq!(
                    frontend_launcher, core_launcher,
                    "current LoongOS must use the standard PortMaster launcher"
                );
            } else {
                assert_ne!(
                    frontend_launcher, core_launcher,
                    "legacy LoongOS must keep its Python runtime wrapper"
                );
                assert!(
                    String::from_utf8(frontend_launcher)
                        .unwrap()
                        .contains("python_3.11.squashfs"),
                    "legacy LoongOS launcher must mount the maintained Python runtime"
                );
            }
            #[cfg(unix)]
            for launcher in [
                request.plan.target.join("PortMaster.sh"),
                request.plan.frontend_dir.join("PortMaster.sh"),
            ] {
                assert_ne!(
                    fs::metadata(&launcher).unwrap().permissions().mode() & 0o111,
                    0,
                    "launcher is not executable for {profile}: {}",
                    launcher.display()
                );
            }

            for entry in ["libs", "config", "themes", "logs", "cache"] {
                let directory = request.plan.target.join(entry);
                fs::create_dir_all(&directory).unwrap();
                fs::write(directory.join("keep.sentinel"), profile.as_bytes()).unwrap();
            }
            let updated = install_portmaster(&request).unwrap();
            assert_eq!(updated.mode, InstallMode::Update, "{profile}");
            for entry in ["libs", "config", "themes", "logs", "cache"] {
                assert_eq!(
                    fs::read(request.plan.target.join(entry).join("keep.sentinel")).unwrap(),
                    profile.as_bytes(),
                    "preserved entry was replaced for {profile}: {entry}"
                );
            }
        }
    }

    #[test]
    fn fresh_install_maps_frontend_and_reports_installed() {
        let temp = tempfile::tempdir().unwrap();
        let request = request(&temp);
        let result = install_portmaster(&request).unwrap();
        assert_eq!(result.mode, InstallMode::Install);
        assert_eq!(result.status, "installed");
        assert_eq!(
            fs::read(request.plan.target.join("control.txt")).unwrap(),
            b"mapped control"
        );
        assert_eq!(
            fs::read(request.plan.frontend_dir.join("launch.sh")).unwrap(),
            b"frontend"
        );
        assert!(!request.plan.target.join("config/archive-owned").exists());
        assert!(
            direct_names(&request.plan.target)
                .unwrap()
                .iter()
                .all(|name| !name.starts_with(".pm-install"))
        );
    }

    #[test]
    fn upgrade_replaces_managed_core_and_preserves_resolution_owned_entries() {
        let temp = tempfile::tempdir().unwrap();
        let request = request(&temp);
        fs::create_dir_all(request.plan.target.join("config")).unwrap();
        fs::create_dir_all(request.plan.target.join("libs")).unwrap();
        fs::write(request.plan.target.join("config/user.ini"), b"user").unwrap();
        fs::write(request.plan.target.join("libs/runtime"), b"runtime").unwrap();
        fs::write(request.plan.target.join("log.txt"), b"runtime log").unwrap();
        fs::write(request.plan.target.join("pugwash.txt"), b"pugwash state").unwrap();
        fs::write(
            request.plan.target.join("harbourmaster.txt"),
            b"harbourmaster state",
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
        assert!(!request.plan.target.join(".appmanager-state").exists());
        assert!(!request.plan.target.join("obsolete").exists());
    }

    #[test]
    fn failed_swap_restores_the_previous_core_and_frontend() {
        let temp = tempfile::tempdir().unwrap();
        let mut request = request(&temp);
        fs::create_dir_all(&request.plan.target).unwrap();
        fs::write(request.plan.target.join("control.txt"), b"old core").unwrap();
        fs::write(request.plan.frontend_dir.join("launch.sh"), b"old frontend").unwrap();
        // This file is deliberately absent. set_executables runs after all
        // renames, giving the transaction a deterministic post-swap failure.
        request.plan.core_executable = Some("missing-core-entry".to_owned());

        assert!(install_portmaster(&request).is_err());
        assert_eq!(
            fs::read(request.plan.target.join("control.txt")).unwrap(),
            b"old core"
        );
        assert_eq!(
            fs::read(request.plan.frontend_dir.join("launch.sh")).unwrap(),
            b"old frontend"
        );
        assert!(!request.plan.target.join("device_info.txt").exists());
    }

    #[test]
    fn rollback_is_idempotent_after_an_old_entry_was_already_restored() {
        let temp = tempfile::tempdir().unwrap();
        let request = request(&temp);
        fs::create_dir_all(&request.plan.target).unwrap();
        fs::create_dir_all(&request.plan.frontend_dir).unwrap();
        let core_work = request.plan.target.join(".pm-install-v1-recovery");
        let frontend_work = request.plan.frontend_dir.join(".pm-install-v1-recovery");
        fs::create_dir_all(core_work.join("retired")).unwrap();
        fs::create_dir_all(frontend_work.join("retired")).unwrap();
        fs::write(request.plan.target.join("control.txt"), b"old-restored").unwrap();
        fs::write(request.plan.target.join("new-only"), b"new").unwrap();
        let journal = SwapJournal {
            schema: 1,
            transaction_id: ".pm-install-v1-recovery".to_owned(),
            old_core: vec!["control.txt".to_owned()],
            old_frontend: Vec::new(),
            new_core: vec!["control.txt".to_owned(), "new-only".to_owned()],
            new_frontend: Vec::new(),
        };

        rollback_swap(&request.plan, &core_work, &frontend_work, &journal, true).unwrap();
        rollback_swap(&request.plan, &core_work, &frontend_work, &journal, true).unwrap();
        assert_eq!(
            fs::read(request.plan.target.join("control.txt")).unwrap(),
            b"old-restored"
        );
        assert!(!request.plan.target.join("new-only").exists());
    }

    #[test]
    fn stale_journal_cannot_name_a_managed_frontend_directory() {
        let temp = tempfile::tempdir().unwrap();
        let request = request(&temp);
        fs::create_dir_all(&request.plan.target).unwrap();
        fs::create_dir_all(&request.plan.frontend_dir).unwrap();
        fs::write(request.plan.frontend_dir.join("launch.sh"), b"keep").unwrap();
        let work = request.plan.target.join(".pm-install-v1-forged");
        fs::create_dir_all(&work).unwrap();
        fs::write(
            work.join("swap.json"),
            serde_json::to_vec(&SwapJournal {
                schema: 1,
                transaction_id: "launch.sh".to_owned(),
                old_core: Vec::new(),
                old_frontend: Vec::new(),
                new_core: Vec::new(),
                new_frontend: Vec::new(),
            })
            .unwrap(),
        )
        .unwrap();

        assert!(sweep_stale_artifacts(&request.plan, &[]).is_err());
        assert_eq!(
            fs::read(request.plan.frontend_dir.join("launch.sh")).unwrap(),
            b"keep"
        );
    }

    #[test]
    fn stale_recovery_tolerates_a_cleaned_frontend_half_and_keeps_new_only_live_files() {
        let temp = tempfile::tempdir().unwrap();
        let request = request(&temp);
        fs::create_dir_all(&request.plan.target).unwrap();
        fs::create_dir_all(&request.plan.frontend_dir).unwrap();
        let live = request.plan.target.join("unowned-live-entry");
        fs::write(&live, b"keep").unwrap();
        let transaction_id = secure_transaction_name().unwrap();
        let core_work = request.plan.target.join(&transaction_id);
        fs::create_dir_all(core_work.join("retired")).unwrap();
        write_owner(&core_work, &transaction_id).unwrap();
        write_swap_journal(
            &core_work,
            &SwapJournal {
                schema: 1,
                transaction_id,
                old_core: Vec::new(),
                old_frontend: Vec::new(),
                new_core: vec!["unowned-live-entry".to_owned()],
                new_frontend: Vec::new(),
            },
        )
        .unwrap();

        recover_portmaster_transactions(&request.plan, &request.state_dir).unwrap();
        assert_eq!(fs::read(&live).unwrap(), b"keep");
        assert!(!core_work.exists());
    }

    #[test]
    fn ownerless_pretransaction_directories_are_swept_without_blocking_install() {
        let temp = tempfile::tempdir().unwrap();
        let request = request(&temp);
        fs::create_dir_all(&request.plan.target).unwrap();
        fs::create_dir_all(&request.plan.frontend_dir).unwrap();
        let transaction_id = format!("{TRANSACTION_PREFIX}{}", "e".repeat(64));
        fs::create_dir(request.plan.target.join(&transaction_id)).unwrap();
        fs::create_dir(request.plan.frontend_dir.join(&transaction_id)).unwrap();

        sweep_stale_artifacts(&request.plan, &[]).unwrap();

        assert!(!request.plan.target.join(&transaction_id).exists());
        assert!(!request.plan.frontend_dir.join(&transaction_id).exists());
    }

    #[test]
    #[ignore = "spawned by work_pair_crash_windows_recover_after_real_process_exit"]
    fn work_pair_crash_fixture_process() {
        let core = PathBuf::from(std::env::var_os("PAM_TEST_PM_CORE").unwrap());
        let frontend = PathBuf::from(std::env::var_os("PAM_TEST_PM_FRONTEND").unwrap());
        let result = allocate_work_pair(&core, &frontend);
        panic!("PortMaster work failpoint did not exit: {result:?}");
    }

    #[test]
    fn work_pair_crash_windows_recover_after_real_process_exit() {
        for point in [
            "after-core-work-dir",
            "after-frontend-work-dir",
            "after-core-owner",
        ] {
            let temp = tempfile::tempdir().unwrap();
            let request = request(&temp);
            fs::create_dir_all(&request.plan.target).unwrap();
            fs::create_dir_all(&request.plan.frontend_dir).unwrap();
            let status = std::process::Command::new(current_test_executable())
                .args([
                    "--exact",
                    "installer::tests::work_pair_crash_fixture_process",
                    "--ignored",
                    "--nocapture",
                ])
                .env("PAM_TEST_PM_CORE", &request.plan.target)
                .env("PAM_TEST_PM_FRONTEND", &request.plan.frontend_dir)
                .env("PAM_TEST_PM_CRASH_POINT", point)
                .status()
                .unwrap();
            assert_eq!(status.code(), Some(87), "failpoint {point}");

            sweep_stale_artifacts(&request.plan, &[]).unwrap();
            assert!(
                direct_names(&request.plan.target)
                    .unwrap()
                    .iter()
                    .all(|name| !name.starts_with(TRANSACTION_PREFIX))
            );
            assert!(
                direct_names(&request.plan.frontend_dir)
                    .unwrap()
                    .iter()
                    .all(|name| !name.starts_with(TRANSACTION_PREFIX))
            );
        }
    }

    #[test]
    fn stale_journal_never_overwrites_an_existing_live_entry() {
        let temp = tempfile::tempdir().unwrap();
        let request = request(&temp);
        fs::create_dir_all(&request.plan.target).unwrap();
        fs::create_dir_all(&request.plan.frontend_dir).unwrap();
        let transaction_id = secure_transaction_name().unwrap();
        let core_work = request.plan.target.join(&transaction_id);
        let frontend_work = request.plan.frontend_dir.join(&transaction_id);
        fs::create_dir_all(core_work.join("retired")).unwrap();
        fs::create_dir_all(&frontend_work).unwrap();
        write_owner(&core_work, &transaction_id).unwrap();
        write_owner(&frontend_work, &transaction_id).unwrap();
        fs::write(request.plan.target.join("victim"), b"live").unwrap();
        fs::write(core_work.join("retired/victim"), b"journal backup").unwrap();
        write_swap_journal(
            &core_work,
            &SwapJournal {
                schema: 1,
                transaction_id,
                old_core: vec!["victim".to_owned()],
                old_frontend: Vec::new(),
                new_core: vec!["victim".to_owned()],
                new_frontend: Vec::new(),
            },
        )
        .unwrap();

        sweep_stale_artifacts(&request.plan, &[]).unwrap();
        assert_eq!(
            fs::read(request.plan.target.join("victim")).unwrap(),
            b"live"
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
    }

    #[test]
    fn archive_cannot_occupy_the_private_transaction_namespace() {
        let temp = tempfile::tempdir().unwrap();
        let mut request = request(&temp);
        request.archive = archive(&temp, Some("PortMaster/.pm-install-v1-forged/payload"));
        let error = install_portmaster(&request).unwrap_err();
        assert!(matches!(error, InstallError::Archive(message) if message.contains("reserved")));
    }

    #[test]
    fn install_sweeps_stale_work_directories() {
        let temp = tempfile::tempdir().unwrap();
        let request = request(&temp);
        let stale = request.plan.target.join(".pm-install-v1-stale");
        fs::create_dir_all(stale.join("stage")).unwrap();
        write_owner(&stale, ".pm-install-v1-stale").unwrap();
        install_portmaster(&request).unwrap();
        assert!(!stale.exists());
    }

    #[test]
    fn cancellation_is_observed_before_mutation() {
        let temp = tempfile::tempdir().unwrap();
        let mut request = request(&temp);
        let cancel = CancellationToken::default();
        cancel.cancel();
        request.cancel_token = Some(cancel);
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
        fs::write(state.join("install.lock"), b"diagnostic-content\n").unwrap();
        drop(guard);
        assert_eq!(
            fs::read_to_string(state.join("install.lock")).unwrap(),
            "diagnostic-content\n"
        );
        let next = acquire_lock(&state).unwrap();
        drop(next);
        assert!(state.join("install.lock").is_file());
    }

    #[test]
    fn persistent_lock_file_has_no_stale_ownership() {
        let temp = tempfile::tempdir().unwrap();
        let state = temp.path().join("state");
        fs::create_dir(&state).unwrap();
        fs::write(state.join("install.lock"), b"stale-content\n").unwrap();
        let guard = acquire_lock(&state).unwrap();
        assert!(matches!(acquire_lock(&state), Err(InstallError::Locked)));
        assert_eq!(
            fs::read_to_string(state.join("install.lock")).unwrap(),
            "stale-content\n"
        );
        drop(guard);
        assert!(state.join("install.lock").is_file());
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
    fn extraction_observes_cancellation_inside_the_copy_loop() {
        let temp = tempfile::tempdir().unwrap();
        let archive = temp.path().join("cancel.zip");
        let mut zip = zip::ZipWriter::new(File::create(&archive).unwrap());
        zip.start_file("PortMaster/large", SimpleFileOptions::default())
            .unwrap();
        zip.write_all(&vec![7_u8; 256 * 1024]).unwrap();
        zip.finish().unwrap();
        let token = CancellationToken::default();
        token.cancel();
        assert!(matches!(
            extract_archive_with_limits_and_cancel(
                &archive,
                &temp.path().join("stage"),
                ARCHIVE_LIMITS,
                Some(&token)
            ),
            Err(InstallError::Cancelled)
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
    fn rejects_protected_system_namespaces() {
        let temp = tempfile::tempdir().unwrap();
        let mut candidate = request(&temp);
        candidate.plan.frontend_dir = temp.path().join("etc/PortMaster");
        let error = validate_request(&candidate).unwrap_err();
        assert!(error.to_string().contains("protected system namespace"));

        let mut candidate = request(&temp);
        candidate.state_dir = temp.path().join("etc/appmanager-state");
        let error = validate_request(&candidate).unwrap_err();
        assert!(error.to_string().contains("protected system namespace"));
    }

    #[test]
    fn fresh_install_creates_all_configured_directories() {
        let temp = tempfile::tempdir().unwrap();
        let mut plan = plan(&temp);
        plan.scripts = temp.path().join("mnt/card/Roms/PORTS");
        fs::create_dir_all(temp.path().join("mnt/card")).unwrap();
        let request = InstallRequest {
            archive: archive(&temp, None),
            state_dir: temp.path().join("state"),
            trash_dir: temp.path().join("trash"),
            cancel_token: None,
            progress_channel: None,
            probe_root: Some(temp.path().to_path_buf()),
            plan,
        };

        install_portmaster(&request).unwrap();

        assert!(request.plan.scripts.is_dir());
        assert!(request.plan.frontend_dir.is_dir());
        assert!(request.plan.target.is_dir());
        assert!(request.plan.target.join("control.txt").is_file());
        assert!(request.plan.frontend_dir.join("launch.sh").is_file());
    }

    #[test]
    fn existing_file_at_configured_directory_reports_storage_not_writable() {
        let temp = tempfile::tempdir().unwrap();
        let mut request = request(&temp);
        let file = temp.path().join("not-a-directory");
        fs::write(&file, b"occupied").unwrap();
        request.plan.scripts = file.clone();

        let error = install_portmaster(&request).unwrap_err();

        assert!(matches!(&error, InstallError::StorageNotWritable { path, .. } if path == &file));
        assert!(error.to_string().contains("storage card is not writable"));
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
    fn allows_official_external_launcher_beside_a_fresh_declared_core() {
        let temp = tempfile::tempdir().unwrap();
        let mut candidate = request(&temp);
        candidate.plan.scripts = temp.path().join("roms2/ports");
        candidate.plan.target = temp.path().join("opt/system/Tools/PortMaster");
        candidate.plan.frontend_dir = temp.path().join("opt/system/Tools");
        candidate.plan.frontend_names = vec!["PortMaster.sh".into()];
        candidate.plan.primary_frontend = "PortMaster.sh".into();
        candidate.plan.control_source = None;
        candidate.plan.frontend_map = vec![FrontendMapEntry {
            source: "PortMaster.sh".into(),
            destination: "PortMaster.sh".into(),
        }];
        candidate.plan.empty_tasksetter = false;
        candidate.plan.core_executable = None;
        candidate.plan.frontend_executable = Some("PortMaster.sh".into());
        fs::create_dir_all(&candidate.plan.scripts).unwrap();
        fs::create_dir_all(candidate.plan.target.parent().unwrap()).unwrap();
        fs::create_dir_all(&candidate.plan.frontend_dir).unwrap();

        if let Err(error) = validate_request(&candidate) {
            panic!("official external launcher layout was rejected: {error}");
        }
        install_portmaster(&candidate).unwrap();
        assert!(candidate.plan.target.join("control.txt").is_file());
        assert!(candidate.plan.frontend_dir.join("PortMaster.sh").is_file());
        assert!(!candidate.plan.target.join("PortMaster.sh").exists());
    }

    #[test]
    fn accepts_unlisted_vendor_roots_from_the_resolved_contract() {
        let temp = tempfile::tempdir().unwrap();
        let mut candidate = request(&temp);
        candidate.plan.scripts = temp.path().join("vendor/card/ports");
        candidate.plan.target = temp.path().join("srv/vendor/tools/PortMaster");
        candidate.plan.frontend_dir = temp.path().join("srv/vendor/menu");
        candidate.plan.frontend_names = vec!["PortMaster.sh".into()];
        candidate.plan.primary_frontend = "PortMaster.sh".into();
        candidate.plan.control_source = None;
        candidate.plan.frontend_map = vec![FrontendMapEntry {
            source: "PortMaster.sh".into(),
            destination: "PortMaster.sh".into(),
        }];
        candidate.plan.core_executable = None;
        candidate.plan.frontend_executable = Some("PortMaster.sh".into());
        fs::create_dir_all(&candidate.plan.scripts).unwrap();
        fs::create_dir_all(candidate.plan.target.parent().unwrap()).unwrap();
        fs::create_dir_all(&candidate.plan.frontend_dir).unwrap();

        install_portmaster(&candidate).unwrap();
        assert!(candidate.plan.target.join("control.txt").is_file());
        assert!(candidate.plan.frontend_dir.join("PortMaster.sh").is_file());
    }

    #[test]
    fn declared_roots_can_be_created_recursively() {
        let temp = tempfile::tempdir().unwrap();
        let mut candidate = request(&temp);
        candidate.plan.target = temp.path().join("vendor/missing/PortMaster");
        install_portmaster(&candidate).unwrap();
        assert!(candidate.plan.target.join("control.txt").is_file());

        let mut candidate = request(&temp);
        let parent = temp.path().join("vendor/menu");
        fs::create_dir_all(&parent).unwrap();
        candidate.plan.frontend_dir = parent.join("nested/missing");
        install_portmaster(&candidate).unwrap();
        assert!(candidate.plan.frontend_dir.join("launch.sh").is_file());
    }

    #[test]
    fn allows_existing_home_app_data_and_distinct_declared_roots() {
        let temp = tempfile::tempdir().unwrap();
        let mut candidate = request(&temp);
        candidate.plan.frontend_dir = temp.path().join("root/.local/share/PortMaster");
        fs::create_dir_all(&candidate.plan.frontend_dir).unwrap();
        assert!(validate_request(&candidate).is_ok());

        candidate.plan.target = temp.path().join("mnt/other/MUOS/PortMaster");
        candidate.plan.frontend_dir = temp.path().join("roms/ports/PortMaster");
        fs::create_dir_all(candidate.plan.target.parent().unwrap()).unwrap();
        fs::create_dir_all(candidate.plan.frontend_dir.parent().unwrap()).unwrap();
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
