use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, FileTimes, OpenOptions};
use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::fs::MetadataExt;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::context::{CapabilityState, ResolvedDeviceContext};
use crate::path::ManagedRoot;

/// Script names in the managed scripts root that are always protected from
/// managed file operations and excluded from inventory/size scans. This is a
/// security boundary, not device policy, so it is compiled in: remote
/// configuration must never be able to unprotect these entries.
pub const PROTECTED_SCRIPT_NAMES: &[&str] = &["APP Manager.sh", "PortMaster.sh", ".port.sh"];

/// Directory names that are always protected from managed file operations.
/// Like [`PROTECTED_SCRIPT_NAMES`], this is a compiled-in security boundary,
/// not device policy: remote configuration must never be able to unprotect
/// these entries.
pub const PROTECTED_DIR_NAMES: &[&str] = &["PortMaster", "images"];

/// The PortMaster drop directory for user-supplied install archives. It is
/// not a managed port, so it is excluded from inventory/size scans — but it
/// is deliberately NOT part of [`PROTECTED_DIR_NAMES`]: managed file
/// operations may remove it.
pub const AUTOINSTALL_DIR_NAME: &str = "autoinstall";

/// Directory names excluded from inventory and size scans: every entry of
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
    DeleteItem,
    CleanAppleDouble,
}

impl FileActionKind {
    fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "TRASH" => Self::Trash,
            "DELETE_MANAGED" => Self::DeleteManaged,
            "EMPTY_TRASH" => Self::EmptyTrash,
            "RESTORE_TRASH" => Self::RestoreTrash,
            "RESTORE_ITEM" => Self::RestoreItem,
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
    pub plan: &'a Path,
    pub result: &'a Path,
    pub size_cache: Option<&'a Path>,
    pub self_launcher: &'a Path,
    pub self_port: &'a str,
    pub privilege_command: Option<&'a Path>,
    pub privilege_arguments: &'a [String],
    pub progress_file: Option<&'a Path>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileApplyOutcome {
    pub handled: usize,
    pub failures: usize,
    pub appledouble_removed: usize,
    pub changed_scripts: bool,
    pub changed_game_dirs: bool,
    pub changed_images: bool,
    pub changed_trash: bool,
}

#[derive(Debug, Clone)]
pub struct SizeScanRequest<'a> {
    pub context: &'a ResolvedDeviceContext,
    pub output: &'a Path,
    pub self_port: &'a str,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SizeScanOutcome {
    pub entries: usize,
    pub total_bytes: u64,
}

#[derive(Debug, Error)]
pub enum FileOperationError {
    #[error("resolved device context is invalid: {0}")]
    Context(String),
    #[error("file operations are unavailable for this device")]
    Capability,
    #[error("operation plan cannot be read: {0}")]
    PlanIo(#[source] io::Error),
    #[error("operation plan line {line} is malformed")]
    PlanRow { line: usize },
    #[error("operation plan line {line} contains unsafe text")]
    UnsafePlanRow { line: usize },
    #[error("operation plan contains no file actions")]
    EmptyPlan,
    #[error("operation result cannot be published: {0}")]
    ResultIo(#[source] io::Error),
}

pub fn scan_size_cache(
    request: &SizeScanRequest<'_>,
) -> Result<SizeScanOutcome, FileOperationError> {
    request
        .context
        .validate()
        .map_err(|error| FileOperationError::Context(error.to_string()))?;
    if request.context.capabilities.manage_ports != CapabilityState::Current {
        return Err(FileOperationError::Capability);
    }
    let mut paths = BTreeSet::new();
    collect_managed_size_paths(request, &mut paths)
        .map_err(|error| FileOperationError::ResultIo(io::Error::other(error)))?;
    let temporary = request
        .output
        .with_extension(format!("tmp.{}", std::process::id()));
    let mut output = File::create(&temporary).map_err(FileOperationError::ResultIo)?;
    let mut outcome = SizeScanOutcome::default();
    for path in paths {
        let bytes = allocated_size(&path);
        writeln!(output, "{}\t{}", bytes, path.display()).map_err(FileOperationError::ResultIo)?;
        outcome.entries += 1;
        outcome.total_bytes = outcome.total_bytes.saturating_add(bytes);
    }
    output.flush().map_err(FileOperationError::ResultIo)?;
    fs::rename(temporary, request.output).map_err(FileOperationError::ResultIo)?;
    Ok(outcome)
}

#[derive(Debug, Clone)]
enum Mutation {
    Move { from: PathBuf, to: PathBuf },
    Delete { path: PathBuf },
}

pub fn plan_contains_only_file_actions(path: &Path) -> Result<bool, FileOperationError> {
    let file = File::open(path).map_err(FileOperationError::PlanIo)?;
    let mut found = false;
    for (index, line) in BufReader::new(file).lines().enumerate() {
        let line = line.map_err(FileOperationError::PlanIo)?;
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (kind, _) = parse_row(index + 1, &line)?;
        if FileActionKind::parse(kind).is_none() {
            return Ok(false);
        }
        found = true;
    }
    Ok(found)
}

pub fn apply_file_plan(
    request: &FileApplyRequest<'_>,
) -> Result<FileApplyOutcome, FileOperationError> {
    request
        .context
        .validate()
        .map_err(|error| FileOperationError::Context(error.to_string()))?;
    if request.context.capabilities.manage_ports != CapabilityState::Current {
        return Err(FileOperationError::Capability);
    }
    let actions = read_actions(request.plan)?;
    if actions.is_empty() {
        return Err(FileOperationError::EmptyPlan);
    }
    let mut result = OpenOptions::new()
        .create(true)
        .append(true)
        .open(request.result)
        .map_err(FileOperationError::ResultIo)?;
    let mut outcome = FileApplyOutcome::default();
    let mut mutations = Vec::new();
    let mut appledouble_ran = false;
    let trash_batch = actions
        .iter()
        .any(|action| action.kind == FileActionKind::Trash)
        .then(|| create_trash_batch(request))
        .transpose()
        .map_err(|message| FileOperationError::ResultIo(io::Error::other(message)))?;

    for action in actions {
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
                .and_then(|()| restore_selected(request, &action.argument, &mut mutations)),
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
                let removed = cleanup_appledouble(request)?;
                outcome.appledouble_removed += removed;
                writeln!(result, "OK\tappledouble\t{removed}")
                    .map_err(|error| error.to_string())?;
                Ok(())
            }),
        };
        if let Err(message) = operation {
            outcome.failures += 1;
            writeln!(result, "FAIL\toperation\t{}", sanitize_result(&message))
                .map_err(FileOperationError::ResultIo)?;
        }
    }
    for mutation in &mutations {
        mark_changed(request.context, mutation, &mut outcome);
    }
    if appledouble_ran {
        write_appledouble_progress(request, "indexing", outcome.appledouble_removed);
        if let Some(path) = request.size_cache {
            if scan_size_cache(&SizeScanRequest {
                context: request.context,
                output: path,
                self_port: request.self_port,
            })
            .is_err()
            {
                let _ = fs::remove_file(path);
            }
        }
        write_appledouble_progress(request, "complete", outcome.appledouble_removed);
    } else if let Some(path) = request.size_cache {
        if apply_size_mutations(path, &mutations).is_err() {
            let _ = fs::remove_file(path);
        }
    }
    if let Some(batch) = trash_batch {
        remove_empty(&batch);
    }
    result.flush().map_err(FileOperationError::ResultIo)?;
    Ok(outcome)
}

fn require_capability(value: CapabilityState) -> Result<(), String> {
    (value == CapabilityState::Current)
        .then_some(())
        .ok_or_else(|| "capability disabled".to_owned())
}

fn read_actions(path: &Path) -> Result<Vec<FileAction>, FileOperationError> {
    let file = File::open(path).map_err(FileOperationError::PlanIo)?;
    let mut actions = Vec::new();
    for (index, line) in BufReader::new(file).lines().enumerate() {
        let line = line.map_err(FileOperationError::PlanIo)?;
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (kind, argument) = parse_row(index + 1, &line)?;
        let Some(kind) = FileActionKind::parse(kind) else {
            return Err(FileOperationError::PlanRow { line: index + 1 });
        };
        actions.push(FileAction {
            kind,
            argument: PathBuf::from(argument),
        });
    }
    Ok(actions)
}

fn parse_row(line: usize, value: &str) -> Result<(&str, &str), FileOperationError> {
    if value.contains(['\0', '\r', '\n']) {
        return Err(FileOperationError::UnsafePlanRow { line });
    }
    let mut fields = value.split('\t');
    let kind = fields.next().unwrap_or_default();
    let argument = fields.next().ok_or(FileOperationError::PlanRow { line })?;
    if kind.is_empty() || argument.is_empty() || fields.next().is_some() {
        return Err(FileOperationError::PlanRow { line });
    }
    Ok((kind, argument))
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
        ManagedSource::Script => "scripts",
        ManagedSource::ScriptImage => "script-images",
        ManagedSource::Image => "images",
        ManagedSource::Data => "data",
    };
    ensure_real_directory(batch)?;
    let destination = batch.join(bucket);
    if !path_exists(&destination) {
        if let Err(error) = create_directory(request, &destination) {
            if !path_exists(&destination) {
                return Err(error);
            }
        }
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
            continue;
        }
        let mut structured = false;
        for bucket in ["scripts", "script-images", "images", "data"] {
            let directory = batch.join(bucket);
            if !is_real_directory(&directory) {
                continue;
            }
            structured = true;
            for item in direct_entries(&directory)? {
                if let Err(error) = restore_to_bucket(request, &item, bucket, mutations) {
                    remember_error(&mut first_error, error);
                }
            }
            remove_empty(&directory);
        }
        for item in direct_entries(&batch)? {
            if structured
                && item
                    .file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| {
                        matches!(name, "scripts" | "script-images" | "images" | "data")
                    })
            {
                continue;
            }
            let bucket = if is_real_directory(&item) {
                "data"
            } else if extension_is(&item, "sh") {
                "scripts"
            } else {
                "images"
            };
            if let Err(error) = restore_to_bucket(request, &item, bucket, mutations) {
                remember_error(&mut first_error, error);
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
    mutations: &mut Vec<Mutation>,
) -> Result<(), String> {
    let bucket = validate_trash_item(&request.context.roots.trash, source, false)?;
    if !path_exists(source) {
        return Ok(());
    }
    let bucket = if bucket == "scripts" && is_real_directory(source) {
        "data"
    } else {
        bucket.as_str()
    };
    restore_to_bucket(request, source, bucket, mutations)?;
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

fn cleanup_appledouble(request: &FileApplyRequest<'_>) -> Result<usize, String> {
    let mut count = 0;
    let mut roots = [
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
    .cloned()
    .collect::<Vec<_>>();
    roots.sort_by_key(|path| path.components().count());
    let mut selected = Vec::<PathBuf>::new();
    for root in roots {
        if !selected.iter().any(|parent| root.starts_with(parent)) {
            selected.push(root);
        }
    }
    for root in selected {
        cleanup_appledouble_under(request, &root, &mut count)?;
    }
    Ok(count)
}

fn cleanup_appledouble_under(
    request: &FileApplyRequest<'_>,
    root: &Path,
    count: &mut usize,
) -> Result<(), String> {
    ensure_real_directory(root)?;
    let root_device = fs::symlink_metadata(root)
        .map_err(|error| error.to_string())?
        .dev();
    let mut stack = vec![root.to_path_buf()];
    while let Some(directory) = stack.pop() {
        for entry in fs::read_dir(&directory).map_err(|error| error.to_string())? {
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
                *count += 1;
                if *count % 10 == 0 {
                    write_appledouble_progress(request, "cleaning", *count);
                }
            } else if kind.is_dir() {
                stack.push(path);
            }
        }
    }
    Ok(())
}

fn write_appledouble_progress(request: &FileApplyRequest<'_>, phase: &str, count: usize) {
    let Some(path) = request.progress_file else {
        return;
    };
    let temporary = path.with_extension(format!("tmp.{}", std::process::id()));
    let published = File::create(&temporary)
        .and_then(|mut output| {
            writeln!(output, "1\t{phase}\tAppleDouble\t1\t1\t{count}\t0\t0\t")?;
            output.flush()
        })
        .and_then(|()| fs::rename(&temporary, path));
    if published.is_err() {
        let _ = fs::remove_file(temporary);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ManagedSource {
    Script,
    ScriptImage,
    Image,
    Data,
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
        if extension_is(path, "sh") {
            return Ok(ManagedSource::Script);
        }
        if is_image(path) {
            return Ok(ManagedSource::ScriptImage);
        }
    }
    if request.context.roots.images.as_deref() == Some(parent) && is_image(path) {
        return Ok(ManagedSource::Image);
    }
    if parent == request.context.roots.game_dirs {
        return Ok(ManagedSource::Data);
    }
    Err("path is outside managed direct children".to_owned())
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
        if !matches!(
            value.as_str(),
            "scripts" | "script-images" | "images" | "data"
        ) {
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
        && (parts.len() == 1
            || parts.len() == 2
                && matches!(
                    direct_name(path)?.as_str(),
                    "scripts" | "script-images" | "images" | "data"
                ))
    {
        return Err("Trash containers cannot be deleted as items".to_owned());
    }
    Ok(bucket)
}

fn restore_to_bucket(
    request: &FileApplyRequest<'_>,
    source: &Path,
    bucket: &str,
    mutations: &mut Vec<Mutation>,
) -> Result<(), String> {
    let target_root = match bucket {
        "scripts" | "script-images" => &request.context.roots.scripts,
        "images" => request
            .context
            .roots
            .images
            .as_ref()
            .ok_or_else(|| "image root is unavailable".to_owned())?,
        "data" => &request.context.roots.game_dirs,
        _ => return Err("unknown restore bucket".to_owned()),
    };
    ensure_real_directory(target_root)?;
    let target = target_root.join(direct_name(source)?);
    if path_exists(&target) {
        return Err("restore destination already exists".to_owned());
    }
    move_managed(request, source, &target)?;
    mutations.push(Mutation::Move {
        from: source.to_path_buf(),
        to: target,
    });
    Ok(())
}

fn apply_size_mutations(path: &Path, mutations: &[Mutation]) -> io::Result<()> {
    if !path.is_file() {
        return Ok(());
    }
    let mut values = BTreeMap::<PathBuf, u64>::new();
    for line in BufReader::new(File::open(path)?).lines() {
        let line = line?;
        let Some((bytes, item)) = line.split_once('\t') else {
            continue;
        };
        if let Ok(bytes) = bytes.parse() {
            values.insert(PathBuf::from(item), bytes);
        }
    }
    for mutation in mutations {
        match mutation {
            Mutation::Move { from, to } => {
                let bytes = values.remove(from).unwrap_or_else(|| allocated_size(to));
                values.insert(to.clone(), bytes);
            }
            Mutation::Delete { path } => {
                values.retain(|item, _| item != path && !item.starts_with(path));
            }
        }
    }
    let temporary = path.with_extension(format!("tmp.{}", std::process::id()));
    let mut output = File::create(&temporary)?;
    for (item, bytes) in values {
        writeln!(output, "{}\t{}", bytes, item.display())?;
    }
    output.flush()?;
    fs::rename(temporary, path)
}

fn collect_managed_size_paths(
    request: &SizeScanRequest<'_>,
    paths: &mut BTreeSet<PathBuf>,
) -> Result<(), String> {
    ensure_real_directory(&request.context.roots.game_dirs)?;
    ensure_real_directory(&request.context.roots.scripts)?;
    ensure_real_directory(&request.context.roots.trash)?;
    for path in direct_entries(&request.context.roots.game_dirs)? {
        let name = direct_name(&path)?;
        if is_real_directory(&path)
            && name != request.self_port
            && !SCAN_EXCLUDED_DIR_NAMES.contains(&name.as_str())
        {
            paths.insert(path);
        }
    }
    for path in direct_entries(&request.context.roots.scripts)? {
        let name = direct_name(&path)?;
        if path.is_file()
            && !PROTECTED_SCRIPT_NAMES.contains(&name.as_str())
            && (extension_is(&path, "sh") || is_image(&path))
        {
            paths.insert(path);
        }
    }
    if let Some(images) = &request.context.roots.images {
        if path_exists(images) {
            ensure_real_directory(images)?;
            for path in direct_entries(images)? {
                if path.is_file() {
                    paths.insert(path);
                }
            }
        }
    }
    for batch in direct_entries(&request.context.roots.trash)? {
        if !is_real_directory(&batch) {
            paths.insert(batch);
            continue;
        }
        let mut structured = false;
        for bucket in ["scripts", "script-images", "data", "images"] {
            let directory = batch.join(bucket);
            if !is_real_directory(&directory) {
                continue;
            }
            structured = true;
            paths.extend(direct_entries(&directory)?);
        }
        for item in direct_entries(&batch)? {
            let is_bucket = item
                .file_name()
                .and_then(|value| value.to_str())
                .is_some_and(|value| {
                    matches!(value, "scripts" | "script-images" | "data" | "images")
                });
            if !structured || !is_bucket {
                paths.insert(item);
            }
        }
    }
    Ok(())
}

fn allocated_size(path: &Path) -> u64 {
    let Ok(metadata) = fs::symlink_metadata(path) else {
        return 0;
    };
    let own = metadata.blocks().saturating_mul(512);
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return own;
    }
    own.saturating_add(
        fs::read_dir(path)
            .into_iter()
            .flatten()
            .filter_map(Result::ok)
            .map(|entry| allocated_size(&entry.path()))
            .sum(),
    )
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

fn sanitize_result(value: &str) -> String {
    value.replace(['\t', '\r', '\n'], " ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::context::{
        ContextCapabilities, ExpectedInstallContract, FrontendContext, ManagedRoots, ManagementMode,
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
        let app_state = temp.path().join("state");
        let trash = temp.path().join("app/trash");
        for directory in [&scripts, &game_dirs, &images, &app_state, &trash] {
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
                cache_invalidation: CapabilityState::Current,
                manage_ports: CapabilityState::Current,
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

    #[test]
    fn deleting_one_duplicate_launcher_and_orphan_images_keeps_other_ports_linked() {
        let (_temp, context) = fixture();
        fs::create_dir(context.roots.game_dirs.join("Shared")).unwrap();
        fs::write(
            context.roots.scripts.join("Keep.sh"),
            b"GAMEDIR=/data/ports/Shared\n",
        )
        .unwrap();
        fs::write(
            context.roots.scripts.join("Duplicate.sh"),
            b"GAMEDIR=/data/ports/Shared\n",
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
        let plan = context.roots.app_state.join("plan.txt");
        fs::write(
            &plan,
            format!(
                "TRASH\t{}\nTRASH\t{}\nTRASH\t{}\n",
                context.roots.scripts.join("Duplicate.sh").display(),
                context
                    .roots
                    .images
                    .as_ref()
                    .unwrap()
                    .join("OldA.png")
                    .display(),
                context
                    .roots
                    .images
                    .as_ref()
                    .unwrap()
                    .join("OldB.png")
                    .display(),
            ),
        )
        .unwrap();
        let result = context.roots.app_state.join("result.txt");
        apply_file_plan(&FileApplyRequest {
            context: &context,
            plan: &plan,
            result: &result,
            size_cache: None,
            self_launcher: &context.roots.scripts.join("APP Manager.sh"),
            self_port: "jenny92-appmanager",
            privilege_command: None,
            privilege_arguments: &[],
            progress_file: None,
        })
        .unwrap();

        let inventory = Inventory::scan_with_options(&context, &InventoryOptions {
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
    fn a_plan_cannot_move_the_app_launcher_or_an_outside_path() {
        let (_temp, context) = fixture();
        let launcher = context.roots.scripts.join("APP Manager.sh");
        let outside = context.roots.app_state.join("outside.sh");
        fs::write(&launcher, b"app").unwrap();
        fs::write(&outside, b"outside").unwrap();
        let plan = context.roots.app_state.join("plan.txt");
        fs::write(
            &plan,
            format!(
                "TRASH\t{}\nTRASH\t{}\n",
                launcher.display(),
                outside.display()
            ),
        )
        .unwrap();
        let result = context.roots.app_state.join("result.txt");
        let outcome = apply_file_plan(&FileApplyRequest {
            context: &context,
            plan: &plan,
            result: &result,
            size_cache: None,
            self_launcher: &launcher,
            self_port: "jenny92-appmanager",
            privilege_command: None,
            privilege_arguments: &[],
            progress_file: None,
        })
        .unwrap();
        assert_eq!(outcome.failures, 2);
        assert!(launcher.exists());
        assert!(outside.exists());
    }

    #[test]
    fn trash_item_actions_reject_lexical_traversal() {
        let (_temp, context) = fixture();
        let outside = context.roots.app_state.join("outside");
        fs::write(&outside, b"keep").unwrap();
        let escaped = context.roots.trash.join("../state/outside");
        let deep_escaped = context.roots.trash.join("batch/../../state/outside");
        let plan = context.roots.app_state.join("plan.txt");
        fs::write(
            &plan,
            format!(
                "DELETE_ITEM\t{}\nRESTORE_ITEM\t{}\n",
                escaped.display(),
                deep_escaped.display()
            ),
        )
        .unwrap();
        let result = context.roots.app_state.join("result.txt");
        let outcome = apply_file_plan(&FileApplyRequest {
            context: &context,
            plan: &plan,
            result: &result,
            size_cache: None,
            self_launcher: &context.roots.scripts.join("APP Manager.sh"),
            self_port: "jenny92-appmanager",
            privilege_command: None,
            privilege_arguments: &[],
            progress_file: None,
        })
        .unwrap();
        assert_eq!(outcome.failures, 2);
        assert_eq!(fs::read(outside).unwrap(), b"keep");
    }

    #[test]
    fn size_scan_deduplicates_shared_roots_and_excludes_the_app_directory() {
        let (_temp, mut context) = fixture();
        context.roots.game_dirs = context.roots.scripts.clone();
        let app = context.roots.game_dirs.join("jenny92-appmanager");
        let game = context.roots.game_dirs.join("GameData");
        fs::create_dir(&app).unwrap();
        fs::create_dir(&game).unwrap();
        fs::write(game.join("save.dat"), vec![0_u8; 4096]).unwrap();
        fs::write(context.roots.scripts.join("Game.sh"), b"#!/bin/sh\n").unwrap();
        fs::write(context.roots.scripts.join("Game.png"), b"image").unwrap();
        let trash_item = context.roots.trash.join("batch/data/OldGame");
        fs::create_dir_all(&trash_item).unwrap();
        fs::write(trash_item.join("save.dat"), b"old").unwrap();
        let output = context.roots.app_state.join("sizes.tsv");

        let outcome = scan_size_cache(&SizeScanRequest {
            context: &context,
            output: &output,
            self_port: "jenny92-appmanager",
        })
        .unwrap();
        let rows = fs::read_to_string(output).unwrap();

        assert_eq!(rows.matches(&format!("\t{}\n", game.display())).count(), 1);
        assert_eq!(
            rows.matches(&format!(
                "\t{}\n",
                context.roots.scripts.join("Game.sh").display()
            ))
            .count(),
            1
        );
        assert_eq!(rows.matches(&format!("\t{}\n", app.display())).count(), 0);
        assert_eq!(
            rows.matches(&format!("\t{}\n", trash_item.display()))
                .count(),
            1
        );
        assert_eq!(outcome.entries, rows.lines().count());
        assert!(outcome.total_bytes > 0);
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
        let plan = context.roots.app_state.join("plan.txt");
        fs::write(&plan, "CLEAN_APPLEDOUBLE\t-\n").unwrap();
        let result = context.roots.app_state.join("result.txt");
        let sizes = context.roots.app_state.join("sizes.tsv");
        let progress = context.roots.app_state.join("progress.tsv");

        let outcome = apply_file_plan(&FileApplyRequest {
            context: &context,
            plan: &plan,
            result: &result,
            size_cache: Some(&sizes),
            self_launcher: &context.roots.scripts.join("APP Manager.sh"),
            self_port: "jenny92-appmanager",
            privilege_command: None,
            privilege_arguments: &[],
            progress_file: Some(&progress),
        })
        .unwrap();

        assert_eq!(outcome.appledouble_removed, 1);
        assert!(!nested.join("._local").exists());
        assert!(nested.join("._real-directory").is_dir());
        assert!(outside.join("._keep").exists());
        assert!(sizes.is_file());
        assert!(
            fs::read_to_string(progress)
                .unwrap()
                .contains("\tcomplete\tAppleDouble\t")
        );
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
        let plan = context.roots.app_state.join("plan.txt");
        let result = context.roots.app_state.join("result.txt");
        fs::write(
            &plan,
            format!(
                "TRASH\t{}\nTRASH\t{}\nTRASH\t{}\n",
                script.display(),
                image.display(),
                data.display()
            ),
        )
        .unwrap();
        apply_file_plan(&FileApplyRequest {
            context: &context,
            plan: &plan,
            result: &result,
            size_cache: None,
            self_launcher: &context.roots.scripts.join("APP Manager.sh"),
            self_port: "jenny92-appmanager",
            privilege_command: None,
            privilege_arguments: &[],
            progress_file: None,
        })
        .unwrap();
        assert!(!script.exists() && !image.exists() && !data.exists());

        fs::write(&plan, "RESTORE_TRASH\t-\n").unwrap();
        apply_file_plan(&FileApplyRequest {
            context: &context,
            plan: &plan,
            result: &result,
            size_cache: None,
            self_launcher: &context.roots.scripts.join("APP Manager.sh"),
            self_port: "jenny92-appmanager",
            privilege_command: None,
            privilege_arguments: &[],
            progress_file: None,
        })
        .unwrap();
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
        let plan = context.roots.app_state.join("plan.txt");
        let result = context.roots.app_state.join("result.txt");
        fs::write(
            &plan,
            format!(
                "DELETE_MANAGED\t{}\nDELETE_MANAGED\t{}\n",
                managed.display(),
                outside.display()
            ),
        )
        .unwrap();
        let outcome = apply_file_plan(&FileApplyRequest {
            context: &context,
            plan: &plan,
            result: &result,
            size_cache: None,
            self_launcher: &context.roots.scripts.join("APP Manager.sh"),
            self_port: "jenny92-appmanager",
            privilege_command: None,
            privilege_arguments: &[],
            progress_file: None,
        })
        .unwrap();
        assert!(!managed.exists());
        assert!(outside.exists());
        assert_eq!(outcome.failures, 1);
    }

    #[test]
    fn selected_restore_never_overwrites_a_reinstalled_item() {
        let (_temp, context) = fixture();
        let installed = context.roots.scripts.join("Game.sh");
        let trashed = context.roots.trash.join("batch/scripts/Game.sh");
        fs::create_dir_all(trashed.parent().unwrap()).unwrap();
        fs::write(&installed, b"new").unwrap();
        fs::write(&trashed, b"old").unwrap();
        let plan = context.roots.app_state.join("plan.txt");
        let result = context.roots.app_state.join("result.txt");
        fs::write(&plan, format!("RESTORE_ITEM\t{}\n", trashed.display())).unwrap();
        let outcome = apply_file_plan(&FileApplyRequest {
            context: &context,
            plan: &plan,
            result: &result,
            size_cache: None,
            self_launcher: &context.roots.scripts.join("APP Manager.sh"),
            self_port: "jenny92-appmanager",
            privilege_command: None,
            privilege_arguments: &[],
            progress_file: None,
        })
        .unwrap();
        assert_eq!(outcome.failures, 1);
        assert_eq!(fs::read(&installed).unwrap(), b"new");
        assert_eq!(fs::read(&trashed).unwrap(), b"old");
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
        let plan = context.roots.app_state.join("plan.txt");
        fs::write(&plan, "RESTORE_TRASH\t-\n").unwrap();
        let result = context.roots.app_state.join("result.txt");
        let outcome = apply_file_plan(&FileApplyRequest {
            context: &context,
            plan: &plan,
            result: &result,
            size_cache: None,
            self_launcher: &context.roots.scripts.join("APP Manager.sh"),
            self_port: "jenny92-appmanager",
            privilege_command: None,
            privilege_arguments: &[],
            progress_file: None,
        })
        .unwrap();
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
        let plan = context.roots.app_state.join("plan.txt");
        fs::write(&plan, format!("DELETE_ITEM\t{}\n", link.display())).unwrap();
        let result = context.roots.app_state.join("result.txt");
        let outcome = apply_file_plan(&FileApplyRequest {
            context: &context,
            plan: &plan,
            result: &result,
            size_cache: None,
            self_launcher: &context.roots.scripts.join("APP Manager.sh"),
            self_port: "jenny92-appmanager",
            privilege_command: None,
            privilege_arguments: &[],
            progress_file: None,
        })
        .unwrap();
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
        let request = FileApplyRequest {
            context: &context,
            plan: &context.roots.app_state.join("unused-plan"),
            result: &context.roots.app_state.join("unused-result"),
            size_cache: None,
            self_launcher: &context.roots.scripts.join("APP Manager.sh"),
            self_port: "jenny92-appmanager",
            privilege_command: Some(&prefix),
            privilege_arguments: &explicit,
            progress_file: None,
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
