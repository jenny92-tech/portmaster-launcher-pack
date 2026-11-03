// INPUT:  ResolvedDeviceContext、ManagedRoot、LocationRole、文件动作及进度通道
// OUTPUT: FileAction/FileApplyRequest/Outcome、保护名单与 apply_file_actions()
// POS:    在托管路径和能力边界内执行回收、恢复、删除及 AppleDouble 清理
use std::collections::BTreeSet;
use std::fs::{self, File, FileTimes, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::context::{CapabilityState, ResolvedDeviceContext};
use crate::path::ManagedRoot;
use crate::{ProgressChannel, TaskProgress};
use portkit_core::LocationRole;

/// Script names in the managed scripts root that are always protected from
/// managed file operations and excluded from inventory scans. This is a
/// security boundary, not device policy, so it is compiled in: remote
/// configuration must never be able to unprotect these entries.
pub const PROTECTED_SCRIPT_NAMES: &[&str] = &["APP Manager.sh", "PortMaster.sh", ".port.sh"];

/// Directory names that are always protected from managed file operations.
/// Like [`PROTECTED_SCRIPT_NAMES`], this is a compiled-in security boundary,
/// not device policy: remote configuration must never be able to unprotect
/// these entries.
pub const PROTECTED_DIR_NAMES: &[&str] = &["PortMaster", "images"];

/// The PortMaster drop directory for user-supplied install archives. It is
/// not a managed port, so it is excluded from inventory scans — but it
/// is deliberately NOT part of [`PROTECTED_DIR_NAMES`]: managed file
/// operations may remove it.
pub const AUTOINSTALL_DIR_NAME: &str = "autoinstall";

/// Directory names excluded from inventory scans: every entry of
/// [`PROTECTED_DIR_NAMES`] plus [`AUTOINSTALL_DIR_NAME`] (pinned by the
/// `scan_exclusions_are_a_superset_of_protected_dirs` test).
pub const SCAN_EXCLUDED_DIR_NAMES: &[&str] = &["PortMaster", "autoinstall", "images"];

/// Default launcher script name, used when the launcher path yields no file
/// name. Always the first entry of [`PROTECTED_SCRIPT_NAMES`].
pub const DEFAULT_LAUNCHER_SCRIPT_NAME: &str = PROTECTED_SCRIPT_NAMES[0];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileActionKind {
    Trash,
    DeleteManaged,
    EmptyTrash,
    RestoreTrash,
    RestoreItem,
    RestoreReplace,
    DeleteItem,
    CleanAppleDouble,
}

impl FileActionKind {
    pub fn from_code(value: &str) -> Option<Self> {
        Some(match value {
            "TRASH" => Self::Trash,
            "DELETE_MANAGED" => Self::DeleteManaged,
            "EMPTY_TRASH" => Self::EmptyTrash,
            "RESTORE_TRASH" => Self::RestoreTrash,
            "RESTORE_ITEM" => Self::RestoreItem,
            "RESTORE_REPLACE" => Self::RestoreReplace,
            "DELETE_ITEM" => Self::DeleteItem,
            "CLEAN_APPLEDOUBLE" => Self::CleanAppleDouble,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileAction {
    pub kind: FileActionKind,
    pub argument: PathBuf,
}

#[derive(Debug, Clone)]
pub struct FileApplyRequest<'a> {
    pub context: &'a ResolvedDeviceContext,
    pub actions: &'a [FileAction],
    pub self_launcher: &'a Path,
    pub self_port: &'a str,
    pub privilege_command: Option<&'a Path>,
    pub privilege_arguments: &'a [String],
    pub progress_channel: Option<ProgressChannel>,
    pub cancel_token: Option<&'a crate::CancellationToken>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileApplyOutcome {
    pub handled: usize,
    pub failures: usize,
    pub results: Vec<FileActionResult>,
    pub appledouble_removed: usize,
    pub changed_scripts: bool,
    pub changed_game_dirs: bool,
    pub changed_images: bool,
    pub changed_trash: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileActionResult {
    pub argument: PathBuf,
    pub success: bool,
    pub message: Option<String>,
}

#[derive(Debug, Error)]
pub enum FileOperationError {
    #[error("resolved device context is invalid: {0}")]
    Context(String),
    #[error("file operations are unavailable for this device")]
    Capability,
    #[error("operation contains no file actions")]
    EmptyActions,
    #[error("file action is invalid: {0}")]
    InvalidAction(String),
    #[error("file operation failed: {0}")]
    ResultIo(#[source] io::Error),
}

#[derive(Debug, Clone)]
enum Mutation {
    Move { from: PathBuf, to: PathBuf },
    Delete { path: PathBuf },
}

pub fn apply_file_actions(
    request: &FileApplyRequest<'_>,
) -> Result<FileApplyOutcome, FileOperationError> {
    request
        .context
        .validate()
        .map_err(|error| FileOperationError::Context(error.to_string()))?;
    if request.context.capabilities.manage_ports != CapabilityState::Current
        && request.context.capabilities.manage_apps != CapabilityState::Current
    {
        return Err(FileOperationError::Capability);
    }
    if request.actions.is_empty() {
        return Err(FileOperationError::EmptyActions);
    }
    validate_actions(request, request.actions)?;
    let mut outcome = FileApplyOutcome::default();
    let mut mutations = Vec::new();
    let mut changed_directories = BTreeSet::new();
    let mut appledouble_ran = false;
    let mut appledouble_failed = false;
    let trash_batch = request
        .actions
        .iter()
        .any(|action| {
            matches!(
                action.kind,
                FileActionKind::Trash | FileActionKind::RestoreReplace
            )
        })
        .then(|| create_trash_batch(request))
        .transpose()
        .map_err(|message| FileOperationError::ResultIo(io::Error::other(message)))?;

    for action in request.actions {
        outcome.handled += 1;
        let operation = match action.kind {
            FileActionKind::Trash => require_capability(request.context.capabilities.trash)
                .and_then(|()| {
                    trash_item(
                        request,
                        &action.argument,
                        trash_batch
                            .as_deref()
                            .expect("Trash action created a batch"),
                        &mut mutations,
                    )
                }),
            FileActionKind::DeleteManaged => require_capability(request.context.capabilities.trash)
                .and_then(|()| delete_managed(request, &action.argument, &mut mutations)),
            FileActionKind::EmptyTrash => require_capability(request.context.capabilities.trash)
                .and_then(|()| empty_trash(request, &mut mutations)),
            FileActionKind::RestoreTrash => require_capability(request.context.capabilities.trash)
                .and_then(|()| restore_all(request, &mut mutations)),
            FileActionKind::RestoreItem => require_capability(request.context.capabilities.trash)
                .and_then(|()| {
                    restore_selected(request, &action.argument, false, None, &mut mutations)
                }),
            FileActionKind::RestoreReplace => {
                require_capability(request.context.capabilities.trash).and_then(|()| {
                    restore_selected(
                        request,
                        &action.argument,
                        true,
                        trash_batch.as_deref(),
                        &mut mutations,
                    )
                })
            }
            FileActionKind::DeleteItem => require_capability(request.context.capabilities.trash)
                .and_then(|()| delete_selected(request, &action.argument, &mut mutations)),
            FileActionKind::CleanAppleDouble => require_capability(
                request.context.capabilities.cleanup_appledouble,
            )
            .and_then(|()| {
                if action.argument != Path::new("-") {
                    return Err("invalid cleanup marker".to_owned());
                }
                write_appledouble_progress(request, "scanning", 0);
                appledouble_ran = true;
                let mut removed = 0;
                let result = cleanup_appledouble(request, &mut changed_directories, &mut removed);
                outcome.appledouble_removed += removed;
                result
            }),
        };
        match operation {
            Ok(()) => outcome.results.push(FileActionResult {
                argument: action.argument.clone(),
                success: true,
                message: None,
            }),
            Err(message) => {
                if action.kind == FileActionKind::CleanAppleDouble {
                    appledouble_failed = true;
                }
                outcome.failures += 1;
                outcome.results.push(FileActionResult {
                    argument: action.argument.clone(),
                    success: false,
                    message: Some(message),
                });
            }
        }
    }
    for mutation in &mutations {
        mark_changed(request.context, mutation, &mut outcome);
        collect_mutation_directories(mutation, &mut changed_directories);
    }
    if appledouble_ran {
        let phase = if appledouble_failed {
            if request
                .cancel_token
                .is_some_and(crate::CancellationToken::is_cancelled)
            {
                "cancelled"
            } else {
                "failed"
            }
        } else {
            "complete"
        };
        write_appledouble_progress(request, phase, outcome.appledouble_removed);
    }
    if let Some(batch) = trash_batch {
        remove_empty(&batch);
    }
    sync_directories(&changed_directories);
    Ok(outcome)
}

fn validate_actions(
    request: &FileApplyRequest<'_>,
    actions: &[FileAction],
) -> Result<(), FileOperationError> {
    for action in actions {
        let result = match action.kind {
            FileActionKind::Trash | FileActionKind::DeleteManaged => {
                require_capability(request.context.capabilities.trash)
                    .and_then(|()| managed_source(request, &action.argument).map(|_| ()))
            }
            FileActionKind::EmptyTrash | FileActionKind::RestoreTrash => {
                require_capability(request.context.capabilities.trash).and_then(|()| {
                    (action.argument == Path::new("-"))
                        .then_some(())
                        .ok_or_else(|| "invalid Trash action marker".to_owned())
                })
            }
            FileActionKind::RestoreItem | FileActionKind::RestoreReplace => {
                require_capability(request.context.capabilities.trash).and_then(|()| {
                    validate_trash_item(&request.context.roots.trash, &action.argument, false)?;
                    let bucket =
                        structured_trash_bucket(&request.context.roots.trash, &action.argument)?;
                    require_restore_domain(request.context, &bucket)
                })
            }
            FileActionKind::DeleteItem => require_capability(request.context.capabilities.trash)
                .and_then(|()| {
                    validate_trash_item(&request.context.roots.trash, &action.argument, true)
                        .map(|_| ())
                }),
            FileActionKind::CleanAppleDouble => require_capability(
                request.context.capabilities.cleanup_appledouble,
            )
            .and_then(|()| {
                (action.argument == Path::new("-"))
                    .then_some(())
                    .ok_or_else(|| "invalid cleanup marker".to_owned())
            }),
        };
        result.map_err(FileOperationError::InvalidAction)?;
    }
    Ok(())
}

fn require_capability(value: CapabilityState) -> Result<(), String> {
    (value == CapabilityState::Current)
        .then_some(())
        .ok_or_else(|| "capability disabled".to_owned())
}

fn require_restore_domain(context: &ResolvedDeviceContext, bucket: &str) -> Result<(), String> {
    if bucket.starts_with("apps-") {
        require_capability(context.capabilities.manage_apps)
    } else if matches!(bucket, "scripts" | "script-images" | "images" | "data") {
        require_capability(context.capabilities.manage_ports)
    } else {
        Err("unknown restore bucket".to_owned())
    }
}

fn trash_item(
    request: &FileApplyRequest<'_>,
    path: &Path,
    batch: &Path,
    mutations: &mut Vec<Mutation>,
) -> Result<(), String> {
    let kind = managed_source(request, path)?;
    if !path_exists(path) {
        return Ok(());
    }
    let base = direct_name(path)?;
    let bucket = match kind {
        ManagedSource::Script => "scripts".to_owned(),
        ManagedSource::ScriptImage => "script-images".to_owned(),
        ManagedSource::Image => "images".to_owned(),
        ManagedSource::Data => "data".to_owned(),
        ManagedSource::App(id) => format!("apps-{id}"),
    };
    ensure_real_directory(batch)?;
    let destination = batch.join(bucket);
    if !path_exists(&destination)
        && let Err(error) = create_directory(request, &destination)
        && !path_exists(&destination)
    {
        return Err(error);
    }
    ensure_real_directory(&destination)?;
    let target = unique_child(&destination, base);
    move_managed(request, path, &target)?;
    mutations.push(Mutation::Move {
        from: path.to_path_buf(),
        to: target,
    });
    Ok(())
}

fn create_trash_batch(request: &FileApplyRequest<'_>) -> Result<PathBuf, String> {
    let root = &request.context.roots.trash;
    ensure_real_directory(root)?;
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    for attempt in 0..128_u32 {
        let batch = root.join(format!("{nonce}-{}-{attempt}", std::process::id()));
        if path_exists(&batch) {
            continue;
        }
        match create_directory(request, &batch) {
            Ok(()) if is_real_directory(&batch) => return Ok(batch),
            Ok(()) => return Err("new Trash batch is not a real directory".to_owned()),
            Err(_) if path_exists(&batch) => continue,
            Err(error) => return Err(error),
        }
    }
    Err("unable to allocate a unique Trash batch".to_owned())
}

fn delete_managed(
    request: &FileApplyRequest<'_>,
    path: &Path,
    mutations: &mut Vec<Mutation>,
) -> Result<(), String> {
    managed_source(request, path)?;
    if path_exists(path) {
        remove_managed(request, path)?;
        mutations.push(Mutation::Delete {
            path: path.to_path_buf(),
        });
    }
    Ok(())
}

fn empty_trash(
    request: &FileApplyRequest<'_>,
    mutations: &mut Vec<Mutation>,
) -> Result<(), String> {
    ensure_real_directory(&request.context.roots.trash)?;
    let mut first_error = None;
    for path in direct_entries(&request.context.roots.trash)? {
        match remove_managed(request, &path) {
            Ok(()) => mutations.push(Mutation::Delete { path }),
            Err(error) => remember_error(&mut first_error, error.to_string()),
        }
    }
    first_error.map_or(Ok(()), Err)
}

fn restore_all(
    request: &FileApplyRequest<'_>,
    mutations: &mut Vec<Mutation>,
) -> Result<(), String> {
    ensure_real_directory(&request.context.roots.trash)?;
    let mut first_error = None;
    for batch in direct_entries(&request.context.roots.trash)? {
        if !is_real_directory(&batch) {
            remember_error(
                &mut first_error,
                "legacy Trash item has no recorded restore destination".to_owned(),
            );
            continue;
        }
        for item in direct_entries(&batch)? {
            let bucket = item
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("");
            if is_structured_bucket(bucket) && is_real_directory(&item) {
                for child in direct_entries(&item)? {
                    if let Err(error) =
                        restore_to_bucket(request, &child, bucket, false, None, mutations)
                    {
                        remember_error(&mut first_error, error);
                    }
                }
                remove_empty(&item);
            } else {
                remember_error(
                    &mut first_error,
                    "legacy Trash item has no recorded restore destination".to_owned(),
                );
            }
        }
        remove_empty(&batch);
    }
    first_error.map_or(Ok(()), Err)
}

fn remember_error(first: &mut Option<String>, error: String) {
    if first.is_none() {
        *first = Some(error);
    }
}

fn restore_selected(
    request: &FileApplyRequest<'_>,
    source: &Path,
    replace: bool,
    trash_batch: Option<&Path>,
    mutations: &mut Vec<Mutation>,
) -> Result<(), String> {
    validate_trash_item(&request.context.roots.trash, source, false)?;
    let bucket = structured_trash_bucket(&request.context.roots.trash, source)?;
    if !path_exists(source) {
        return Ok(());
    }
    restore_to_bucket(request, source, &bucket, replace, trash_batch, mutations)?;
    cleanup_trash_parents(&request.context.roots.trash, source);
    Ok(())
}

fn delete_selected(
    request: &FileApplyRequest<'_>,
    source: &Path,
    mutations: &mut Vec<Mutation>,
) -> Result<(), String> {
    validate_trash_item(&request.context.roots.trash, source, true)?;
    if path_exists(source) {
        remove_managed(request, source)?;
        mutations.push(Mutation::Delete {
            path: source.to_path_buf(),
        });
        cleanup_trash_parents(&request.context.roots.trash, source);
    }
    Ok(())
}

fn cleanup_appledouble(
    request: &FileApplyRequest<'_>,
    changed_directories: &mut BTreeSet<PathBuf>,
    count: &mut usize,
) -> Result<(), String> {
    let mut roots = Vec::new();
    if request.context.capabilities.manage_ports == CapabilityState::Current {
        roots.extend(
            [
                Some(&request.context.roots.scripts),
                Some(&request.context.roots.game_dirs),
                request
                    .context
                    .roots
                    .images
                    .as_ref()
                    .filter(|path| path_exists(path)),
            ]
            .into_iter()
            .flatten()
            .cloned(),
        );
    }
    if request.context.capabilities.manage_apps == CapabilityState::Current {
        roots.extend(
            request
                .context
                .roots
                .apps
                .iter()
                .filter(|root| root.roles.contains(&LocationRole::CleanupAppleDouble))
                .map(|root| root.path.clone()),
        );
    }
    roots.sort_by_key(|path| path.components().count());
    let mut selected = Vec::<PathBuf>::new();
    for root in roots {
        if !selected.iter().any(|parent| root.starts_with(parent)) {
            selected.push(root);
        }
    }
    for root in selected {
        cleanup_appledouble_under(request, &root, count, changed_directories)?;
    }
    Ok(())
}

fn cleanup_appledouble_under(
    request: &FileApplyRequest<'_>,
    root: &Path,
    count: &mut usize,
    changed_directories: &mut BTreeSet<PathBuf>,
) -> Result<(), String> {
    ensure_real_directory(root)?;
    let root_device = fs::symlink_metadata(root)
        .map_err(|error| error.to_string())?
        .dev();
    let mut stack = vec![root.to_path_buf()];
    while let Some(directory) = stack.pop() {
        if request
            .cancel_token
            .is_some_and(crate::CancellationToken::is_cancelled)
        {
            return Err("AppleDouble cleanup cancelled".to_owned());
        }
        for entry in fs::read_dir(&directory).map_err(|error| error.to_string())? {
            if request
                .cancel_token
                .is_some_and(crate::CancellationToken::is_cancelled)
            {
                return Err("AppleDouble cleanup cancelled".to_owned());
            }
            let entry = entry.map_err(|error| error.to_string())?;
            let path = entry.path();
            let kind = entry.file_type().map_err(|error| error.to_string())?;
            let name = entry.file_name();
            if kind.is_symlink() {
                continue;
            }
            let metadata = entry.metadata().map_err(|error| error.to_string())?;
            if metadata.dev() != root_device {
                continue;
            }
            if name.to_string_lossy().starts_with("._") && kind.is_file() {
                remove_managed(request, &path)?;
                changed_directories.insert(directory.clone());
                *count += 1;
                if (*count).is_multiple_of(10) {
                    write_appledouble_progress(request, "cleaning", *count);
                }
            } else if kind.is_dir() {
                stack.push(path);
            }
        }
    }
    Ok(())
}

fn collect_mutation_directories(mutation: &Mutation, output: &mut BTreeSet<PathBuf>) {
    match mutation {
        Mutation::Move { from, to } => {
            if let Some(parent) = from.parent() {
                output.insert(parent.to_path_buf());
            }
            if let Some(parent) = to.parent() {
                output.insert(parent.to_path_buf());
            }
        }
        Mutation::Delete { path } => {
            if let Some(parent) = path.parent() {
                output.insert(parent.to_path_buf());
            }
        }
    }
}

fn sync_directories(directories: &BTreeSet<PathBuf>) {
    let mut existing = BTreeSet::new();
    for directory in directories {
        let mut candidate = directory.as_path();
        while !candidate.is_dir() {
            let Some(parent) = candidate.parent() else {
                break;
            };
            candidate = parent;
        }
        if candidate.is_dir() {
            existing.insert(candidate.to_path_buf());
        }
    }
    for directory in existing {
        if let Ok(handle) = File::open(&directory) {
            // Some FAT/FUSE implementations reject directory fsync. The
            // mutation itself has already completed, so persistence remains
            // best effort instead of turning a successful delete into an
            // operation failure.
            let _ = handle.sync_all();
        }
    }
}

fn write_appledouble_progress(request: &FileApplyRequest<'_>, phase: &str, count: usize) {
    if let Some(channel) = &request.progress_channel {
        channel.publish(TaskProgress {
            phase: phase.to_owned(),
            runtime: "AppleDouble".to_owned(),
            index: 1,
            count: 1,
            current: count as u64,
            total: 0,
            speed: 0,
            detail: String::new(),
        });
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum ManagedSource {
    Script,
    ScriptImage,
    Image,
    Data,
    App(String),
}

fn managed_source(request: &FileApplyRequest<'_>, path: &Path) -> Result<ManagedSource, String> {
    let parent = path
        .parent()
        .ok_or_else(|| "path has no parent".to_owned())?;
    let name = direct_name(path)?;
    if path == request.self_launcher
        || PROTECTED_SCRIPT_NAMES.contains(&name.as_str())
        || name == request.self_port
        || PROTECTED_DIR_NAMES.contains(&name.as_str())
    {
        return Err("protected APP or PortMaster path".to_owned());
    }
    if parent == request.context.roots.scripts {
        require_capability(request.context.capabilities.manage_ports)?;
        if extension_is(path, "sh") {
            return Ok(ManagedSource::Script);
        }
        if is_image(path) {
            return Ok(ManagedSource::ScriptImage);
        }
    }
    if request.context.roots.images.as_deref() == Some(parent) && is_image(path) {
        require_capability(request.context.capabilities.manage_ports)?;
        return Ok(ManagedSource::Image);
    }
    if parent == request.context.roots.game_dirs {
        require_capability(request.context.capabilities.manage_ports)?;
        return Ok(ManagedSource::Data);
    }
    if let Some(root) = request
        .context
        .roots
        .apps
        .iter()
        .find(|root| root.path == parent && root.roles.contains(&LocationRole::Manage))
    {
        require_capability(request.context.capabilities.manage_apps)?;
        return Ok(ManagedSource::App(root.id.clone()));
    }
    Err("path is outside managed direct children".to_owned())
}

fn is_structured_bucket(value: &str) -> bool {
    matches!(value, "scripts" | "script-images" | "images" | "data")
        || value.strip_prefix("apps-").is_some_and(is_safe_bucket_id)
}

fn is_safe_bucket_id(value: &str) -> bool {
    let mut bytes = value.bytes();
    !value.is_empty()
        && value.len() <= 128
        && matches!(bytes.next(), Some(b'a'..=b'z'))
        && bytes.all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'-' | b'_' | b'.')
        })
}

fn validate_trash_item(root: &Path, path: &Path, deleting: bool) -> Result<String, String> {
    let managed = ManagedRoot::new(root).map_err(|error| error.to_string())?;
    let parent = path
        .parent()
        .ok_or_else(|| "Trash item has no parent".to_owned())?;
    if parent != root {
        managed
            .validate_descendant(parent)
            .map_err(|error| error.to_string())?;
    }
    direct_name(path)?;
    let relative = path
        .strip_prefix(root)
        .map_err(|_| "path is outside Trash".to_owned())?;
    let parts = relative.components().collect::<Vec<_>>();
    if parts.is_empty() || parts.len() > 3 {
        return Err("path is not a direct Trash item".to_owned());
    }
    for ancestor in path.ancestors().skip(1).take(parts.len().saturating_sub(1)) {
        if ancestor != root && !is_real_directory(ancestor) {
            return Err("Trash parent is not a real directory".to_owned());
        }
    }
    let bucket = if parts.len() == 3 {
        let value = parts[1].as_os_str().to_string_lossy().into_owned();
        if !is_structured_bucket(&value) {
            return Err("unknown Trash bucket".to_owned());
        }
        value
    } else if is_real_directory(path) {
        "data".to_owned()
    } else if extension_is(path, "sh") {
        "scripts".to_owned()
    } else {
        "images".to_owned()
    };
    if deleting
        && is_real_directory(path)
        && (parts.len() == 1 || parts.len() == 2 && is_structured_bucket(&direct_name(path)?))
    {
        return Err("Trash containers cannot be deleted as items".to_owned());
    }
    Ok(bucket)
}

fn structured_trash_bucket(root: &Path, path: &Path) -> Result<String, String> {
    let relative = path
        .strip_prefix(root)
        .map_err(|_| "path is outside Trash".to_owned())?;
    let parts = relative.components().collect::<Vec<_>>();
    if parts.len() != 3 {
        return Err("legacy Trash item has no recorded restore destination".to_owned());
    }
    let bucket = parts[1].as_os_str().to_string_lossy().into_owned();
    if !is_structured_bucket(&bucket) {
        return Err("unknown Trash bucket".to_owned());
    }
    Ok(bucket)
}

fn restore_to_bucket(
    request: &FileApplyRequest<'_>,
    source: &Path,
    bucket: &str,
    replace: bool,
    trash_batch: Option<&Path>,
    mutations: &mut Vec<Mutation>,
) -> Result<(), String> {
    require_restore_domain(request.context, bucket)?;
    let target_root = match bucket {
        "scripts" | "script-images" => &request.context.roots.scripts,
        "images" => request
            .context
            .roots
            .images
            .as_ref()
            .ok_or_else(|| "image root is unavailable".to_owned())?,
        "data" => &request.context.roots.game_dirs,
        value if value.starts_with("apps-") => request
            .context
            .roots
            .apps
            .iter()
            .find(|root| root.id == value[5..] && root.roles.contains(&LocationRole::TrashRestore))
            .map(|root| &root.path)
            .ok_or_else(|| "APP restore root is unavailable".to_owned())?,
        _ => return Err("unknown restore bucket".to_owned()),
    };
    ensure_real_directory(target_root)?;
    let target = target_root.join(direct_name(source)?);
    let mut replaced_to = None;
    if path_exists(&target) {
        if !replace {
            return Err("restore destination already exists".to_owned());
        }
        let before = mutations.len();
        trash_item(
            request,
            &target,
            trash_batch.ok_or_else(|| "restore replacement Trash batch is missing".to_owned())?,
            mutations,
        )?;
        if let Some(Mutation::Move { from, to }) = mutations.get(before)
            && from == &target
        {
            replaced_to = Some(to.clone());
        }
    }
    if let Err(error) = move_managed(request, source, &target) {
        if let Some(preserved) = replaced_to
            && !path_exists(&target)
            && move_managed(request, &preserved, &target).is_ok()
        {
            mutations.pop();
        }
        return Err(error);
    }
    mutations.push(Mutation::Move {
        from: source.to_path_buf(),
        to: target,
    });
    Ok(())
}

fn mark_changed(
    context: &ResolvedDeviceContext,
    mutation: &Mutation,
    outcome: &mut FileApplyOutcome,
) {
    let paths: [&Path; 2] = match mutation {
        Mutation::Move { from, to } => [from, to],
        Mutation::Delete { path } => [path, path],
    };
    for path in paths {
        outcome.changed_scripts |= path.starts_with(&context.roots.scripts);
        outcome.changed_game_dirs |= path.starts_with(&context.roots.game_dirs);
        outcome.changed_images |= context
            .roots
            .images
            .as_ref()
            .is_some_and(|root| path.starts_with(root));
        outcome.changed_trash |= path.starts_with(&context.roots.trash);
    }
}

fn unique_child(directory: &Path, name: String) -> PathBuf {
    let initial = directory.join(&name);
    if !path_exists(&initial) {
        return initial;
    }
    for index in 2..=u32::MAX {
        let candidate = directory.join(format!("{name}.{index}"));
        if !path_exists(&candidate) {
            return candidate;
        }
    }
    unreachable!("u32 collision space exhausted")
}

fn direct_entries(path: &Path) -> Result<Vec<PathBuf>, String> {
    let mut entries = fs::read_dir(path)
        .map_err(|error| error.to_string())?
        .map(|entry| {
            entry
                .map(|entry| entry.path())
                .map_err(|error| error.to_string())
        })
        .collect::<Result<Vec<_>, _>>()?;
    entries.sort();
    Ok(entries)
}

fn direct_name(path: &Path) -> Result<String, String> {
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| "path has no UTF-8 direct name".to_owned())?;
    ManagedRoot::validate_child_name(name).map_err(|error| error.to_string())?;
    Ok(name.to_owned())
}

fn ensure_real_directory(path: &Path) -> Result<(), String> {
    if is_real_directory(path) {
        Ok(())
    } else {
        Err(format!("{} is not a real directory", path.display()))
    }
}

fn is_real_directory(path: &Path) -> bool {
    fs::symlink_metadata(path)
        .is_ok_and(|metadata| metadata.is_dir() && !metadata.file_type().is_symlink())
}

fn path_exists(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok()
}

fn remove_any(path: &Path) -> io::Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.is_dir() && !metadata.file_type().is_symlink() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    }
}

fn create_directory(request: &FileApplyRequest<'_>, path: &Path) -> Result<(), String> {
    match fs::create_dir(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => Err(error.to_string()),
        Err(error) => run_privileged(request, "mkdir", &[], &[path]).map_err(|_| error.to_string()),
    }
}

fn remove_managed(request: &FileApplyRequest<'_>, path: &Path) -> Result<(), String> {
    match remove_any(path) {
        Ok(()) => Ok(()),
        Err(error) => {
            run_privileged(request, "rm", &["-rf"], &[path]).map_err(|_| error.to_string())
        }
    }
}

fn move_managed(
    request: &FileApplyRequest<'_>,
    source: &Path,
    target: &Path,
) -> Result<(), String> {
    match move_path_no_follow(source, target) {
        Ok(()) => Ok(()),
        Err(error) => run_privileged(request, "mv", &[], &[source, target]).map_err(|_| error),
    }
}

fn run_privileged(
    request: &FileApplyRequest<'_>,
    program: &str,
    options: &[&str],
    paths: &[&Path],
) -> Result<(), ()> {
    let command = request.privilege_command.ok_or(())?;
    // PortMaster exposes ESUDO as a whitespace-delimited command prefix (for
    // example `sudo --preserve-env=...`). Never pass it through a shell, but
    // preserve each prefix argument before appending our validated command.
    let mut prefix = command.as_os_str().to_str().ok_or(())?.split_whitespace();
    let executable = prefix.next().ok_or(())?;
    let status = Command::new(executable)
        .args(prefix)
        .args(request.privilege_arguments)
        .arg(program)
        .args(options)
        .arg("--")
        .args(paths)
        .status()
        .map_err(|_| ())?;
    status.success().then_some(()).ok_or(())
}

fn move_path_no_follow(source: &Path, target: &Path) -> Result<(), String> {
    match fs::rename(source, target) {
        Ok(()) => return Ok(()),
        Err(error) if error.raw_os_error() == Some(18) => {}
        Err(error) => return Err(error.to_string()),
    }
    let parent = target
        .parent()
        .ok_or_else(|| "move destination has no parent".to_owned())?;
    ensure_real_directory(parent)?;
    let temporary = unique_child(parent, format!(".pam-move-{}", std::process::id()));
    if let Err(error) = copy_path_no_follow(source, &temporary) {
        let _ = remove_any(&temporary);
        return Err(error);
    }
    if let Err(error) = fs::rename(&temporary, target) {
        let _ = remove_any(&temporary);
        return Err(error.to_string());
    }
    if let Err(error) = remove_any(source) {
        let _ = remove_any(target);
        return Err(error.to_string());
    }
    Ok(())
}

fn copy_path_no_follow(source: &Path, target: &Path) -> Result<(), String> {
    let metadata = fs::symlink_metadata(source).map_err(|error| error.to_string())?;
    let file_type = metadata.file_type();
    if file_type.is_symlink() {
        let link = fs::read_link(source).map_err(|error| error.to_string())?;
        return symlink(link, target).map_err(|error| error.to_string());
    }
    if file_type.is_file() {
        let mut input = File::open(source).map_err(|error| error.to_string())?;
        let mut output = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(target)
            .map_err(|error| error.to_string())?;
        io::copy(&mut input, &mut output).map_err(|error| error.to_string())?;
        output.flush().map_err(|error| error.to_string())?;
        fs::set_permissions(
            target,
            fs::Permissions::from_mode(metadata.permissions().mode()),
        )
        .map_err(|error| error.to_string())?;
        preserve_times(target, &metadata);
        return Ok(());
    }
    if file_type.is_dir() {
        fs::create_dir(target).map_err(|error| error.to_string())?;
        for child in direct_entries(source)? {
            let name = direct_name(&child)?;
            copy_path_no_follow(&child, &target.join(name))?;
        }
        fs::set_permissions(
            target,
            fs::Permissions::from_mode(metadata.permissions().mode()),
        )
        .map_err(|error| error.to_string())?;
        preserve_times(target, &metadata);
        return Ok(());
    }
    Err("special filesystem entries cannot be moved across devices".to_owned())
}

fn preserve_times(path: &Path, metadata: &fs::Metadata) {
    let (Ok(accessed), Ok(modified), Ok(file)) =
        (metadata.accessed(), metadata.modified(), File::open(path))
    else {
        return;
    };
    let _ = file.set_times(
        FileTimes::new()
            .set_accessed(accessed)
            .set_modified(modified),
    );
}

fn remove_empty(path: &Path) {
    let _ = fs::remove_dir(path);
}

fn cleanup_trash_parents(root: &Path, source: &Path) {
    let mut parent = source.parent();
    while let Some(path) = parent {
        if path == root {
            break;
        }
        if fs::remove_dir(path).is_err() {
            break;
        }
        parent = path.parent();
    }
}

fn extension_is(path: &Path, expected: &str) -> bool {
    path.extension()
        .and_then(|value| value.to_str())
        .is_some_and(|value| value.eq_ignore_ascii_case(expected))
}

fn is_image(path: &Path) -> bool {
    ["png", "jpg", "jpeg", "webp"]
        .iter()
        .any(|extension| extension_is(path, extension))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::context::{
        ContextCapabilities, ExpectedInstallContract, FrontendContext, ManagedAppLocation,
        ManagedRoots, ManagementMode,
    };
    use crate::inventory::{Inventory, InventoryOptions};
    use tempfile::TempDir;

    #[test]
    fn scan_exclusions_are_a_superset_of_protected_dirs() {
        for name in PROTECTED_DIR_NAMES {
            assert!(
                SCAN_EXCLUDED_DIR_NAMES.contains(name),
                "protected dir {name} must also be excluded from scans"
            );
        }
        // Deliberate asymmetry: autoinstall is scan-excluded but may be
        // removed by managed file operations.
        assert!(SCAN_EXCLUDED_DIR_NAMES.contains(&AUTOINSTALL_DIR_NAME));
        assert!(!PROTECTED_DIR_NAMES.contains(&AUTOINSTALL_DIR_NAME));
    }

    #[test]
    fn default_launcher_script_name_is_the_first_protected_script() {
        assert_eq!(DEFAULT_LAUNCHER_SCRIPT_NAME, PROTECTED_SCRIPT_NAMES[0]);
    }

    fn fixture() -> (TempDir, ResolvedDeviceContext) {
        let temp = tempfile::tempdir().unwrap();
        let scripts = temp.path().join("ports");
        let game_dirs = temp.path().join("data");
        let images = temp.path().join("images");
        let apps = temp.path().join("apps");
        let app_state = temp.path().join("state");
        let trash = temp.path().join("app/trash");
        for directory in [&scripts, &game_dirs, &images, &apps, &app_state, &trash] {
            fs::create_dir_all(directory).unwrap();
        }
        let frontend = scripts.join("PortMaster.sh");
        let context = ResolvedDeviceContext {
            schema: 1,
            profile: "test".to_owned(),
            device_class: "tested".to_owned(),
            management: ManagementMode::App,
            target_confirmed: true,
            capabilities: ContextCapabilities {
                inventory: CapabilityState::Current,
                inventory_ports: CapabilityState::Current,
                cache_invalidation: CapabilityState::Current,
                manage_ports: CapabilityState::Current,
                install_ports: CapabilityState::Current,
                inventory_apps: CapabilityState::Current,
                manage_apps: CapabilityState::Current,
                install_apps: CapabilityState::Current,
                trash: CapabilityState::Current,
                leftovers: CapabilityState::Current,
                cleanup_appledouble: CapabilityState::Current,
                ..ContextCapabilities::default()
            },
            roots: ManagedRoots {
                portmaster: Some(temp.path().join("PortMaster")),
                scripts: scripts.clone(),
                game_dirs: game_dirs.clone(),
                images: Some(images),
                libs: Some(temp.path().join("PortMaster/libs")),
                apps: vec![ManagedAppLocation {
                    id: "apps-primary".to_owned(),
                    path: apps,
                    roles: vec![
                        LocationRole::Inventory,
                        LocationRole::Install,
                        LocationRole::Manage,
                        LocationRole::Trash,
                        LocationRole::TrashRestore,
                    ],
                    formats: vec![portkit_core::BundleFormat::TrimuiApp],
                    priority: 100,
                }],
                app_state,
                trash,
            },
            frontend: FrontendContext {
                kind: "script".to_owned(),
                directory: scripts,
                launcher: frontend,
                names: vec!["PortMaster.sh".to_owned()],
            },
            install: ExpectedInstallContract {
                schema: 1,
                frontend_names: vec!["PortMaster.sh".to_owned()],
                primary_frontend: "PortMaster.sh".to_owned(),
                control_source: None,
                core_launcher_source: None,
                frontend_map: vec![crate::context::FrontendMapEntry {
                    source: "PortMaster.sh".to_owned(),
                    destination: "PortMaster.sh".to_owned(),
                }],
                remove_core_launcher: false,
                empty_tasksetter: false,
                core_executable: None,
                frontend_executable: None,
                frontend_transforms: Vec::new(),
                preserve_core_entries: vec![
                    "config".to_owned(),
                    "libs".to_owned(),
                    "themes".to_owned(),
                ],
            },
        };
        (temp, context)
    }

    fn action(kind: FileActionKind, argument: impl Into<PathBuf>) -> FileAction {
        FileAction {
            kind,
            argument: argument.into(),
        }
    }

    fn apply(
        context: &ResolvedDeviceContext,
        actions: &[FileAction],
        progress_channel: Option<ProgressChannel>,
    ) -> Result<FileApplyOutcome, FileOperationError> {
        apply_file_actions(&FileApplyRequest {
            context,
            actions,
            self_launcher: &context.roots.scripts.join("APP Manager.sh"),
            self_port: "jenny92-appmanager",
            privilege_command: None,
            privilege_arguments: &[],
            progress_channel,
            cancel_token: None,
        })
    }

    #[test]
    fn deleting_one_duplicate_launcher_and_orphan_images_keeps_other_ports_linked() {
        let (_temp, context) = fixture();
        fs::create_dir(context.roots.game_dirs.join("Shared")).unwrap();
        fs::write(
            context.roots.scripts.join("Keep.sh"),
            format!("GAMEDIR='{}/Shared'\n", context.roots.game_dirs.display()),
        )
        .unwrap();
        fs::write(
            context.roots.scripts.join("Duplicate.sh"),
            format!("GAMEDIR='{}/Shared'\n", context.roots.game_dirs.display()),
        )
        .unwrap();
        fs::write(
            context.roots.images.as_ref().unwrap().join("OldA.png"),
            b"a",
        )
        .unwrap();
        fs::write(
            context.roots.images.as_ref().unwrap().join("OldB.png"),
            b"b",
        )
        .unwrap();
        let actions = [
            action(
                FileActionKind::Trash,
                context.roots.scripts.join("Duplicate.sh"),
            ),
            action(
                FileActionKind::Trash,
                context.roots.images.as_ref().unwrap().join("OldA.png"),
            ),
            action(
                FileActionKind::Trash,
                context.roots.images.as_ref().unwrap().join("OldB.png"),
            ),
        ];
        apply(&context, &actions, None).unwrap();

        let inventory = Inventory::scan_with_options(
            &context,
            &InventoryOptions {
                directory: "/data".to_owned(),
                ..InventoryOptions::default()
            },
        )
        .unwrap();
        assert_eq!(inventory.ports.len(), 1);
        assert_eq!(inventory.ports[0].script, "Keep.sh");
        assert_eq!(inventory.ports[0].dir, "Shared");
        assert!(inventory.orphan_dirs.is_empty());
        assert!(inventory.dead_scripts.is_empty());
    }

    #[test]
    fn app_directory_round_trips_through_structured_trash() {
        let (_temp, context) = fixture();
        let app = context.roots.apps[0].path.join("Clock");
        fs::create_dir(&app).unwrap();
        fs::write(app.join("launch.sh"), b"#!/bin/sh\n").unwrap();

        apply(
            &context,
            &[action(FileActionKind::Trash, app.clone())],
            None,
        )
        .unwrap();
        assert!(!app.exists());

        let trashed = fs::read_dir(&context.roots.trash)
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path()
            .join("apps-apps-primary/Clock");
        assert!(trashed.is_dir());
        apply(
            &context,
            &[action(FileActionKind::RestoreItem, trashed)],
            None,
        )
        .unwrap();
        assert!(app.join("launch.sh").is_file());
    }

    #[test]
    fn app_restore_uses_stable_root_id_after_locations_are_reordered() {
        let (temp, mut context) = fixture();
        let second = temp.path().join("apps-secondary");
        fs::create_dir(&second).unwrap();
        context.roots.apps.push(ManagedAppLocation {
            id: "apps-secondary".to_owned(),
            path: second.clone(),
            roles: vec![
                LocationRole::Inventory,
                LocationRole::Manage,
                LocationRole::Trash,
                LocationRole::TrashRestore,
            ],
            formats: vec![portkit_core::BundleFormat::TrimuiApp],
            priority: 50,
        });

        let original = context.roots.apps[0].path.join("Clock");
        fs::create_dir(&original).unwrap();
        fs::write(original.join("launch.sh"), b"#!/bin/sh\n").unwrap();
        apply(
            &context,
            &[action(FileActionKind::Trash, original.clone())],
            None,
        )
        .unwrap();
        let trashed = fs::read_dir(&context.roots.trash)
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path()
            .join("apps-apps-primary/Clock");

        context.roots.apps.reverse();
        apply(
            &context,
            &[action(FileActionKind::RestoreItem, trashed)],
            None,
        )
        .unwrap();
        assert!(original.join("launch.sh").is_file());
        assert!(!second.join("Clock").exists());
    }

    #[test]
    fn an_invalid_later_action_rejects_the_whole_operation_before_mutation() {
        let (_temp, context) = fixture();
        let launcher = context.roots.scripts.join("APP Manager.sh");
        let managed = context.roots.scripts.join("Game.sh");
        let outside = context.roots.app_state.join("outside.sh");
        fs::write(&launcher, b"app").unwrap();
        fs::write(&managed, b"game").unwrap();
        fs::write(&outside, b"outside").unwrap();
        let actions = [
            action(FileActionKind::Trash, managed.clone()),
            action(FileActionKind::Trash, outside.clone()),
        ];
        let error = apply(&context, &actions, None).unwrap_err();
        assert!(matches!(error, FileOperationError::InvalidAction(_)));
        assert!(launcher.exists());
        assert!(managed.exists());
        assert!(outside.exists());
    }

    #[test]
    fn trash_item_actions_reject_lexical_traversal() {
        let (_temp, context) = fixture();
        let outside = context.roots.app_state.join("outside");
        fs::write(&outside, b"keep").unwrap();
        let escaped = context.roots.trash.join("../state/outside");
        let deep_escaped = context.roots.trash.join("batch/../../state/outside");
        let actions = [
            action(FileActionKind::DeleteItem, escaped),
            action(FileActionKind::RestoreItem, deep_escaped),
        ];
        let error = apply(&context, &actions, None).unwrap_err();
        assert!(matches!(error, FileOperationError::InvalidAction(_)));
        assert_eq!(fs::read(outside).unwrap(), b"keep");
    }

    #[test]
    fn appledouble_cleanup_does_not_follow_symlinks() {
        use std::os::unix::fs::symlink;

        let (temp, context) = fixture();
        let nested = context.roots.game_dirs.join("Game/nested");
        fs::create_dir_all(&nested).unwrap();
        fs::write(nested.join("._local"), b"metadata").unwrap();
        fs::create_dir(nested.join("._real-directory")).unwrap();
        let outside = temp.path().join("outside");
        fs::create_dir(&outside).unwrap();
        fs::write(outside.join("._keep"), b"metadata").unwrap();
        symlink(&outside, context.roots.game_dirs.join("Game/link")).unwrap();
        let progress = ProgressChannel::default();

        let actions = [action(FileActionKind::CleanAppleDouble, "-")];
        let outcome = apply(&context, &actions, Some(progress.clone())).unwrap();

        assert_eq!(outcome.appledouble_removed, 1);
        assert!(!nested.join("._local").exists());
        assert!(nested.join("._real-directory").is_dir());
        assert!(outside.join("._keep").exists());
        let update = progress.take().unwrap();
        assert_eq!(update.phase, "complete");
        assert_eq!(update.runtime, "AppleDouble");
    }

    #[test]
    fn appledouble_cleanup_includes_configured_apps_and_honors_cancellation() {
        let (_temp, mut context) = fixture();
        context.roots.apps[0]
            .roles
            .push(LocationRole::CleanupAppleDouble);
        let app = context.roots.apps[0].path.join("Clock");
        fs::create_dir(&app).unwrap();
        let junk = app.join("._metadata");
        fs::write(&junk, b"junk").unwrap();
        let actions = [action(FileActionKind::CleanAppleDouble, "-")];
        let outcome = apply(&context, &actions, None).unwrap();
        assert_eq!(outcome.failures, 0);
        assert!(!junk.exists());

        fs::write(&junk, b"junk").unwrap();
        let cancel = crate::CancellationToken::default();
        cancel.cancel();
        let outcome = apply_file_actions(&FileApplyRequest {
            context: &context,
            actions: &actions,
            self_launcher: &context.roots.scripts.join("APP Manager.sh"),
            self_port: "jenny92-appmanager",
            privilege_command: None,
            privilege_arguments: &[],
            progress_channel: None,
            cancel_token: Some(&cancel),
        })
        .unwrap();
        assert_eq!(outcome.failures, 1);
        assert!(
            outcome.results[0]
                .message
                .as_deref()
                .is_some_and(|message| message.contains("cancelled"))
        );
        assert!(junk.exists());
    }

    #[test]
    fn appledouble_late_cancellation_reports_partial_count_and_cancelled_phase() {
        let (_temp, context) = fixture();
        let root = context.roots.game_dirs.join("Many");
        fs::create_dir(&root).unwrap();
        for index in 0..5_000 {
            fs::write(root.join(format!("._{index:05}")), b"metadata").unwrap();
        }
        let cancel = crate::CancellationToken::default();
        let worker_cancel = cancel.clone();
        let progress = ProgressChannel::default();
        let worker_progress = progress.clone();
        let worker = std::thread::spawn(move || {
            let actions = [action(FileActionKind::CleanAppleDouble, "-")];
            apply_file_actions(&FileApplyRequest {
                context: &context,
                actions: &actions,
                self_launcher: &context.roots.scripts.join("APP Manager.sh"),
                self_port: "jenny92-appmanager",
                privilege_command: None,
                privilege_arguments: &[],
                progress_channel: Some(worker_progress),
                cancel_token: Some(&worker_cancel),
            })
            .unwrap()
        });
        for _ in 0..2_000 {
            if progress
                .take()
                .is_some_and(|update| update.phase == "cleaning")
            {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        cancel.cancel();
        let outcome = worker.join().unwrap();
        assert_eq!(outcome.failures, 1);
        assert!(outcome.appledouble_removed > 0);
        assert_eq!(progress.take().unwrap().phase, "cancelled");
    }

    #[test]
    fn trash_items_round_trip_to_their_original_roots() {
        let (_temp, context) = fixture();
        let script = context.roots.scripts.join("Game.sh");
        let image = context.roots.images.as_ref().unwrap().join("Game.png");
        let data = context.roots.game_dirs.join("GameData");
        fs::write(&script, b"#!/bin/sh\n").unwrap();
        fs::write(&image, b"image").unwrap();
        fs::create_dir(&data).unwrap();
        fs::write(data.join("save.dat"), b"save").unwrap();
        let trash_actions = [
            action(FileActionKind::Trash, script.clone()),
            action(FileActionKind::Trash, image.clone()),
            action(FileActionKind::Trash, data.clone()),
        ];
        apply(&context, &trash_actions, None).unwrap();
        assert!(!script.exists() && !image.exists() && !data.exists());

        let restore_actions = [action(FileActionKind::RestoreTrash, "-")];
        apply(&context, &restore_actions, None).unwrap();
        assert!(script.exists() && image.exists() && data.join("save.dat").exists());
        assert!(direct_entries(&context.roots.trash).unwrap().is_empty());
    }

    #[test]
    fn permanent_delete_is_limited_to_managed_or_trash_items() {
        let (_temp, context) = fixture();
        let managed = context.roots.game_dirs.join("Disposable");
        fs::create_dir(&managed).unwrap();
        fs::write(managed.join("data"), b"data").unwrap();
        let outside = context.roots.app_state.join("outside");
        fs::write(&outside, b"keep").unwrap();
        let actions = [
            action(FileActionKind::DeleteManaged, managed.clone()),
            action(FileActionKind::DeleteManaged, outside.clone()),
        ];
        let error = apply(&context, &actions, None).unwrap_err();
        assert!(matches!(error, FileOperationError::InvalidAction(_)));
        assert!(managed.exists());
        assert!(outside.exists());
    }

    #[test]
    fn selected_restore_never_overwrites_a_reinstalled_item() {
        let (_temp, context) = fixture();
        let installed = context.roots.scripts.join("Game.sh");
        let trashed = context.roots.trash.join("batch/scripts/Game.sh");
        fs::create_dir_all(trashed.parent().unwrap()).unwrap();
        fs::write(&installed, b"new").unwrap();
        fs::write(&trashed, b"old").unwrap();
        let actions = [action(FileActionKind::RestoreItem, trashed.clone())];
        let outcome = apply(&context, &actions, None).unwrap();
        assert_eq!(outcome.failures, 1);
        assert_eq!(fs::read(&installed).unwrap(), b"new");
        assert_eq!(fs::read(&trashed).unwrap(), b"old");
    }

    #[test]
    fn confirmed_restore_moves_the_current_item_back_to_trash_before_replacing_it() {
        let (_temp, context) = fixture();
        let installed = context.roots.scripts.join("Game.sh");
        let trashed = context.roots.trash.join("old-batch/scripts/Game.sh");
        fs::create_dir_all(trashed.parent().unwrap()).unwrap();
        fs::write(&installed, b"new").unwrap();
        fs::write(&trashed, b"old").unwrap();

        let outcome = apply(
            &context,
            &[action(FileActionKind::RestoreReplace, trashed.clone())],
            None,
        )
        .unwrap();

        assert_eq!(outcome.failures, 0);
        assert_eq!(fs::read(&installed).unwrap(), b"old");
        assert!(!trashed.exists());
        let preserved_current = direct_entries(&context.roots.trash)
            .unwrap()
            .into_iter()
            .flat_map(|batch| direct_entries(&batch).unwrap_or_default())
            .filter(|bucket| bucket.file_name().is_some_and(|name| name == "scripts"))
            .flat_map(|bucket| direct_entries(&bucket).unwrap_or_default())
            .find(|item| item.file_name().is_some_and(|name| name == "Game.sh"))
            .expect("the overwritten current launcher remains recoverable in Trash");
        assert_eq!(fs::read(preserved_current).unwrap(), b"new");
    }

    #[test]
    fn legacy_trash_items_can_be_deleted_but_are_never_restored_by_guessing() {
        let (_temp, context) = fixture();
        let legacy = context.roots.trash.join("old-batch/Unknown.sh");
        fs::create_dir_all(legacy.parent().unwrap()).unwrap();
        fs::write(&legacy, b"legacy").unwrap();
        let guessed_target = context.roots.scripts.join("Unknown.sh");
        let restore_actions = [action(FileActionKind::RestoreItem, legacy.clone())];
        let error = apply(&context, &restore_actions, None).unwrap_err();
        assert!(matches!(error, FileOperationError::InvalidAction(_)));
        assert!(legacy.exists());
        assert!(!guessed_target.exists());

        let delete_actions = [action(FileActionKind::DeleteItem, legacy.clone())];
        let outcome = apply(&context, &delete_actions, None).unwrap();
        assert_eq!(outcome.failures, 0);
        assert!(!legacy.exists());
    }

    #[test]
    fn restore_all_continues_after_a_conflicting_item() {
        let (_temp, context) = fixture();
        let conflict = context.roots.scripts.join("Conflict.sh");
        let restored = context.roots.scripts.join("Restored.sh");
        fs::write(&conflict, b"installed").unwrap();
        let bucket = context.roots.trash.join("batch/scripts");
        fs::create_dir_all(&bucket).unwrap();
        fs::write(bucket.join("Conflict.sh"), b"trash").unwrap();
        fs::write(bucket.join("Restored.sh"), b"restore").unwrap();
        let actions = [action(FileActionKind::RestoreTrash, "-")];
        let outcome = apply(&context, &actions, None).unwrap();
        assert_eq!(outcome.failures, 1);
        assert_eq!(fs::read(conflict).unwrap(), b"installed");
        assert_eq!(fs::read(bucket.join("Conflict.sh")).unwrap(), b"trash");
        assert_eq!(fs::read(restored).unwrap(), b"restore");
    }

    #[test]
    fn selected_delete_unlinks_a_trash_symlink_without_following_it() {
        use std::os::unix::fs::symlink;

        let (temp, context) = fixture();
        let outside = temp.path().join("outside");
        fs::write(&outside, b"keep").unwrap();
        let link = context.roots.trash.join("batch/images/Game.png");
        fs::create_dir_all(link.parent().unwrap()).unwrap();
        symlink(&outside, &link).unwrap();
        let actions = [action(FileActionKind::DeleteItem, link.clone())];
        let outcome = apply(&context, &actions, None).unwrap();
        assert_eq!(outcome.failures, 0);
        assert!(!path_exists(&link));
        assert_eq!(fs::read(outside).unwrap(), b"keep");
    }

    #[test]
    fn cross_device_copy_primitive_preserves_symlinks_without_following_them() {
        use std::os::unix::fs::symlink;

        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("source");
        let target = temp.path().join("target");
        let outside = temp.path().join("outside");
        fs::create_dir(&source).unwrap();
        fs::write(&outside, b"outside").unwrap();
        fs::write(source.join("data"), b"inside").unwrap();
        let expected_mtime = UNIX_EPOCH + std::time::Duration::from_secs(1_700_000_000);
        File::open(source.join("data"))
            .unwrap()
            .set_times(FileTimes::new().set_modified(expected_mtime))
            .unwrap();
        symlink(&outside, source.join("link")).unwrap();

        copy_path_no_follow(&source, &target).unwrap();

        assert_eq!(fs::read(target.join("data")).unwrap(), b"inside");
        assert_eq!(
            fs::metadata(target.join("data"))
                .unwrap()
                .modified()
                .unwrap(),
            expected_mtime
        );
        assert_eq!(fs::read_link(target.join("link")).unwrap(), outside);
        assert_eq!(fs::read(&outside).unwrap(), b"outside");
    }

    #[test]
    fn privilege_prefix_keeps_portmaster_arguments_without_using_a_shell() {
        let (temp, context) = fixture();
        let helper = temp.path().join("privilege-helper");
        let arguments = temp.path().join("arguments.txt");
        fs::write(
            &helper,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$@\" > '{}'\n",
                arguments.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&helper, fs::Permissions::from_mode(0o755)).unwrap();
        let prefix = PathBuf::from(format!("{} --preserve-env=DEVICE", helper.display()));
        let explicit = vec!["--non-interactive".to_owned()];
        let actions = [action(FileActionKind::CleanAppleDouble, "-")];
        let request = FileApplyRequest {
            context: &context,
            actions: &actions,
            self_launcher: &context.roots.scripts.join("APP Manager.sh"),
            self_port: "jenny92-appmanager",
            privilege_command: Some(&prefix),
            privilege_arguments: &explicit,
            progress_channel: None,
            cancel_token: None,
        };

        run_privileged(
            &request,
            "rm",
            &["-rf"],
            &[context.roots.scripts.join("Game.sh").as_path()],
        )
        .unwrap();

        assert_eq!(
            fs::read_to_string(arguments)
                .unwrap()
                .lines()
                .collect::<Vec<_>>(),
            [
                "--preserve-env=DEVICE",
                "--non-interactive",
                "rm",
                "-rf",
                "--",
                context.roots.scripts.join("Game.sh").to_str().unwrap(),
            ]
        );
    }
}
