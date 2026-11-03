// INPUT:  archive_bundle、文件系统、serde、安装目标与取消/密码参数
// OUTPUT: ZipCandidate/ZipKind、ArchiveIssue、安装包扫描/安装/事务恢复接口
// POS:    按显式符号布局识别包内关联并事务化安装 Port/TrimUI APP，不提供设备清理归属
//! Portable-game zip bundle scanning and recognition.
//!
//! People share PortMaster games as zip bundles. The layout varies: the zip
//! may nest a folder or two, but within three levels it must contain a
//! launcher script plus a data folder (standard Port) or a TrimUI app folder
//! (launcher.sh + config.json + icon.png). We only *read* the zip entry names
//! here; installation (extraction with the installer's safety limits) happens
//! separately.

use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use crate::archive_bundle::{
    self, ArchiveCatalog, INVALID_PASSWORD, PASSWORD_REQUIRED, RESOURCE_LIMIT, UNSUPPORTED_FEATURE,
    UNSUPPORTED_METHOD,
};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ArchiveIssue {
    /// Stable machine-readable category. This is not a schema version.
    pub code: String,
    /// Detected or inferred archive format: "zip", "7z", or "unknown".
    pub format: String,
    pub summary: String,
    /// Sanitized detail suitable for display and bug reports.
    pub detail: String,
    /// Copyable report containing no password or device-absolute path.
    pub report: String,
}

impl ArchiveIssue {
    pub fn message(&self) -> String {
        if self.detail.is_empty() || self.detail == self.summary {
            self.summary.clone()
        } else {
            format!("{}：{}", self.summary, self.detail)
        }
    }
}

/// A recognized bundle found on a storage card root.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ZipCandidate {
    pub path: String,
    pub size: u64,
    /// Opaque filesystem identity captured during recognition. Installation
    /// must open the same object; a same-path replacement requires a rescan.
    pub source_identity: String,
    /// Physical archive format detected from the file signature: "zip" or "7z".
    pub format: String,
    /// True when extraction requires a password. A locked archive may not be
    /// classifiable until the password also unlocks its file names or launcher.
    pub password_required: bool,
    /// "port" (standard .sh + data folder), "trimui_app" (folder with
    /// launcher.sh + config.json), or "unknown".
    pub kind: String,
    /// The launcher script entry inside the zip (e.g. "game.sh" or
    /// "app/launch.sh").
    pub entry_script: String,
    /// The data folder entry inside the zip, if any (for ports).
    pub entry_data: String,
    /// Top-level folder holding the app for TrimUI apps.
    pub app_name: String,
    /// Empty for a recognized bundle; otherwise explains why it cannot be installed.
    pub diagnostic: String,
    /// Structured, sanitized information for displaying or copying a failure report.
    pub issue: Option<ArchiveIssue>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ZipKind {
    Port,
    TrimuiApp,
    Ambiguous,
    Unknown,
}

impl ZipKind {
    fn name(self) -> &'static str {
        match self {
            ZipKind::Port => "port",
            ZipKind::TrimuiApp => "trimui_app",
            ZipKind::Ambiguous => "ambiguous",
            ZipKind::Unknown => "unknown",
        }
    }
}

/// Associate archive entries using explicit symbolic layouts, never host paths.
/// This is package recognition only, not evidence for on-device deletion.
fn launcher_data_directories(
    text: &str,
    real_dirs: &BTreeSet<String>,
    script_name: &str,
    script_dir: &str,
) -> BTreeSet<String> {
    // Archive inspection has no mounted card. Bind only the symbolic card-root
    // input; this cannot establish an on-device path or deletion ownership.
    let seed = BTreeMap::from([("directory".to_owned(), "/__portmaster_card__".to_owned())]);
    let virtual_parent = Path::new("/__archive__").join(script_dir);
    let analysis = crate::shell_paths::analyze(
        text,
        &seed,
        &virtual_parent.join(format!("{script_name}.sh")),
    );
    // Explicit portable-package layouts, not guesses based on a segment named
    // `ports`. The on-device inventory must never use these symbolic roots.
    let roots = [
        virtual_parent.as_path(),
        Path::new("/__portmaster_card__/ports"),
        Path::new("/roms/ports"),
        Path::new("/ports"),
    ];
    analysis
        .paths
        .iter()
        .chain(&analysis.declared_paths)
        .chain(&analysis.sources)
        .chain(&analysis.working_directories)
        .flat_map(|value| {
            roots.iter().filter_map(move |root| {
                let relative = Path::new(value).strip_prefix(root).ok()?;
                if relative
                    .components()
                    .any(|part| matches!(part, std::path::Component::ParentDir))
                {
                    return None;
                }
                match relative.components().next()? {
                    std::path::Component::Normal(name) => name.to_str().map(str::to_owned),
                    _ => None,
                }
            })
        })
        .filter(|name| real_dirs.contains(name))
        .collect()
}

const MAX_ZIP_ENTRIES: usize = 4096;
const MAX_LAUNCHER_INSPECTION_BYTES: u64 = 4 * 1024 * 1024;

/// Scan the given root directories for `*.zip` and `*.7z` files in their top level and
/// recognize each bundle's structure (read-only, entries are not extracted).
pub fn scan_zip_bundles(
    roots: &[&Path],
    cancel: &dyn Fn() -> bool,
) -> Result<Vec<ZipCandidate>, String> {
    let mut out = Vec::new();
    let mut seen = BTreeSet::new();
    for root in roots {
        let Ok(entries) = std::fs::read_dir(root) else {
            continue;
        };
        let mut names = entries
            .filter_map(std::result::Result::ok)
            .map(|entry| entry.path())
            .filter(|path| {
                path.is_file()
                    && path
                        .extension()
                        .and_then(|ext| ext.to_str())
                        .is_some_and(|ext| {
                            ext.eq_ignore_ascii_case("zip") || ext.eq_ignore_ascii_case("7z")
                        })
            })
            .collect::<Vec<_>>();
        names.sort();
        for path in names {
            if cancel() {
                return Err("zip scan cancelled".to_owned());
            }
            if !seen.insert(file_identity(&path)) {
                continue;
            }
            match inspect_archive_bundle_with_password(&path, None, cancel) {
                Ok(candidate) => out.push(candidate),
                Err(message) if is_password_required_error(&message) => {
                    let mut file = open_archive(&path)?;
                    let identity = SourceIdentity::from_file(&file)?;
                    let format =
                        archive_bundle::detect_format(&mut file, &path.display().to_string())?;
                    out.push(ZipCandidate {
                        path: path.to_string_lossy().into_owned(),
                        size: identity.length,
                        source_identity: identity.token(),
                        format: format.name().to_owned(),
                        password_required: true,
                        kind: "locked".to_owned(),
                        entry_script: String::new(),
                        entry_data: String::new(),
                        app_name: String::new(),
                        diagnostic: "压缩包已加密，需要输入密码后识别".to_owned(),
                        issue: None,
                    });
                }
                Err(message) => {
                    let issue = archive_issue(&path.to_string_lossy(), "", &message);
                    out.push(ZipCandidate {
                        path: path.to_string_lossy().into_owned(),
                        size: path.metadata().map(|metadata| metadata.len()).unwrap_or(0),
                        source_identity: source_identity_token(&path).unwrap_or_default(),
                        format: issue.format.clone(),
                        password_required: false,
                        kind: "invalid".to_owned(),
                        entry_script: String::new(),
                        entry_data: String::new(),
                        app_name: String::new(),
                        diagnostic: issue.message(),
                        issue: Some(issue),
                    });
                }
            }
        }
    }
    Ok(out)
}

/// Inspect one zip file directly.
///
/// This is deliberately separate from [`scan_zip_bundles`], whose inputs are
/// directories. Upload and one-tap install callers already know the exact zip
/// path and must not accidentally pass that file to `read_dir`.
pub fn inspect_zip_bundle(path: &Path, cancel: &dyn Fn() -> bool) -> Result<ZipCandidate, String> {
    inspect_archive_bundle_with_password(path, None, cancel)
}

/// Inspect a ZIP or 7z archive with an optional password.
pub fn inspect_archive_bundle_with_password(
    path: &Path,
    password: Option<&str>,
    cancel: &dyn Fn() -> bool,
) -> Result<ZipCandidate, String> {
    let mut file = open_archive(path)?;
    let identity = SourceIdentity::from_file(&file)?;
    let (candidate, catalog) =
        recognize_archive_file(&mut file, &path.display().to_string(), password, cancel)?;
    let issue = (!candidate.diagnostic.is_empty()).then(|| {
        archive_issue(
            &path.to_string_lossy(),
            catalog.format.name(),
            &candidate.diagnostic,
        )
    });
    Ok(ZipCandidate {
        path: path.to_string_lossy().into_owned(),
        size: identity.length,
        source_identity: identity.token(),
        format: catalog.format.name().to_owned(),
        password_required: catalog.encrypted,
        kind: candidate.kind.name().to_owned(),
        entry_script: candidate.entry_script,
        entry_data: candidate.entry_data,
        app_name: candidate.app_name,
        diagnostic: candidate.diagnostic,
        issue,
    })
}

pub fn is_password_required_error(message: &str) -> bool {
    message == PASSWORD_REQUIRED || message.starts_with(&format!("{PASSWORD_REQUIRED}:"))
}

pub fn is_invalid_password_error(message: &str) -> bool {
    message == INVALID_PASSWORD || message.starts_with(&format!("{INVALID_PASSWORD}:"))
}

/// Convert an internal archive error into a stable, path- and password-free report.
pub fn archive_issue(display_name: &str, format_hint: &str, message: &str) -> ArchiveIssue {
    let marked_method = marker_detail(message, UNSUPPORTED_METHOD);
    let marked_feature = marker_detail(message, UNSUPPORTED_FEATURE);
    let marked_limit = marker_detail(message, RESOURCE_LIMIT);
    let marked = marked_method.or(marked_feature).or(marked_limit);
    let marker_format = marked.and_then(|value| value.split_once(':').map(|(format, _)| format));
    let mut format = normalize_report_format(marker_format.unwrap_or(format_hint));
    if format == "unknown" && message != "只支持 ZIP 或 7z 压缩包" {
        format = infer_report_format(display_name);
    }
    let (code, summary, detail) = if let Some(value) = marked_method {
        (
            "unsupported_method",
            "压缩包使用了当前版本不支持的压缩算法",
            marked_value(value),
        )
    } else if let Some(value) = marked_feature {
        (
            "unsupported_feature",
            "压缩包使用了当前版本不支持的格式功能",
            marked_value(value),
        )
    } else if let Some(value) = marked_limit {
        (
            "resource_limit",
            "解压这个压缩包需要超出当前限制的内存",
            marked_value(value),
        )
    } else if is_password_required_error(message) {
        (
            "password_required",
            "压缩包已加密",
            "需要输入密码后继续识别",
        )
    } else if is_invalid_password_error(message) {
        ("invalid_password", "压缩包密码不正确", "请重新输入密码")
    } else if message == "只支持 ZIP 或 7z 压缩包" {
        format = "unknown".to_owned();
        (
            "unsupported_format",
            "当前只支持 ZIP 或 7z 压缩包",
            "文件内容不是受支持的 ZIP 或 7z 格式",
        )
    } else if message.starts_with("7z anti-item is not supported") {
        (
            "unsupported_feature",
            "压缩包使用了当前版本不支持的 7z 功能",
            "7z anti-item",
        )
    } else if message.contains("installation is disabled by device configuration") {
        (
            "device_unsupported",
            "当前设备配置不支持此类安装包",
            "请复制诊断信息反馈设备型号与安装包类型",
        )
    } else if is_rejected_archive_error(message) {
        (
            "rejected_archive",
            "压缩包未通过安全或资源限制检查",
            rejected_archive_detail(message),
        )
    } else if is_unsupported_layout_error(message) {
        (
            "unsupported_layout",
            "没有识别到可安装的 APP 或 Port",
            layout_detail(message),
        )
    } else if message.contains("changed after") || message.contains("changed while") {
        (
            "archive_changed",
            "扫描后压缩包发生了变化",
            "请重新扫描或重新上传后再试",
        )
    } else if message.contains("cancelled") || message.contains("canceled") {
        ("cancelled", "操作已取消", "现有文件保持不变")
    } else {
        (
            "invalid_archive",
            "压缩包损坏或无法读取",
            "请重新下载或重新压缩后再试",
        )
    };
    let filename = report_filename(display_name);
    let detail = clean_report_value(detail, 240);
    let report = format!(
        "APP Manager 压缩包诊断\n文件: {filename}\n格式: {format}\n代码: {code}\n说明: {summary}\n详情: {detail}\n支持范围: ZIP / 7z 常用单卷压缩算法"
    );
    ArchiveIssue {
        code: code.to_owned(),
        format,
        summary: summary.to_owned(),
        detail,
        report,
    }
}

fn marker_detail<'a>(message: &'a str, marker: &str) -> Option<&'a str> {
    message
        .strip_prefix(marker)
        .map(|value| value.strip_prefix(": ").unwrap_or(value).trim())
}

fn marked_value(value: &str) -> &str {
    value
        .split_once(':')
        .map_or(value, |(_, detail)| detail)
        .trim()
}

fn normalize_report_format(value: &str) -> String {
    match value.trim().to_ascii_lowercase().as_str() {
        "zip" => "zip".to_owned(),
        "7z" => "7z".to_owned(),
        _ => "unknown".to_owned(),
    }
}

fn infer_report_format(value: &str) -> String {
    let name = value.replace('\\', "/");
    match name
        .rsplit('.')
        .next()
        .unwrap_or("")
        .to_ascii_lowercase()
        .as_str()
    {
        "zip" => "zip".to_owned(),
        "7z" => "7z".to_owned(),
        _ => "unknown".to_owned(),
    }
}

fn report_filename(value: &str) -> String {
    let normalized = value.replace('\\', "/");
    let filename = normalized.rsplit('/').next().unwrap_or("").trim();
    let filename = clean_report_value(filename, 120);
    if filename.is_empty() {
        "unknown".to_owned()
    } else {
        filename
    }
}

fn clean_report_value(value: &str, max_chars: usize) -> String {
    let mut output = String::new();
    let mut pending_space = false;
    for character in value.chars() {
        if output.chars().count() >= max_chars {
            break;
        }
        if character.is_control() || character.is_whitespace() {
            pending_space = !output.is_empty();
            continue;
        }
        if pending_space {
            output.push(' ');
            pending_space = false;
        }
        output.push(character);
    }
    output.trim().to_owned()
}

fn is_rejected_archive_error(message: &str) -> bool {
    message.contains("too many entries")
        || message.contains("exceeds limit")
        || message.contains("expansion exceeds")
        || message.contains("duplicate entry")
        || message.contains("entry conflicts")
        || message.contains("unsafe path")
        || message.contains("reserved transaction path")
}

fn rejected_archive_detail(message: &str) -> &'static str {
    if message.contains("too many entries") {
        "压缩包条目数量超过安全上限"
    } else if message.contains("exceeds limit") || message.contains("expansion exceeds") {
        "单个文件或解压后的总大小超过安全上限"
    } else if message.contains("duplicate entry") || message.contains("entry conflicts") {
        "压缩包内存在重复或冲突路径"
    } else {
        "压缩包内存在不安全路径"
    }
}

fn is_unsupported_layout_error(message: &str) -> bool {
    message == "unsupported zip bundle"
        || message.contains("installable payload")
        || message.contains("supported APP or Port payload")
        || message.contains("launcher or manifest candidates")
        || message.contains("launcher references more than one")
        || message.contains("launcher is missing from the archive")
        || message.contains("data folder is missing from the archive")
}

fn layout_detail(message: &str) -> &'static str {
    if message.contains("more than one") || message.contains("installable payloads") {
        "压缩包中存在多个候选安装内容，无法安全决定安装哪一个"
    } else {
        "需要一个可识别的 launch.sh APP，或一个 SH 启动脚本及其脚本中引用的数据目录"
    }
}

struct Recognized {
    kind: ZipKind,
    entry_script: String,
    entry_data: String,
    app_name: String,
    diagnostic: String,
}

#[derive(Deserialize)]
struct PortPackageManifest {
    items: Vec<String>,
}

fn normalize(entry: &str) -> String {
    archive_bundle::normalize_name(entry)
}

fn depth(entry: &str) -> usize {
    if entry.is_empty() {
        return 0;
    }
    entry.split('/').count()
}

fn parent(entry: &str) -> &str {
    entry.rsplit_once('/').map_or("", |(parent, _)| parent)
}

fn sibling(parent: &str, name: &str) -> String {
    if parent.is_empty() {
        name.to_owned()
    } else {
        format!("{parent}/{name}")
    }
}

fn file_identity(path: &Path) -> String {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if let Ok(metadata) = fs::metadata(path) {
            return format!("{}:{}", metadata.dev(), metadata.ino());
        }
    }
    fs::canonicalize(path)
        .unwrap_or_else(|_| path.to_path_buf())
        .to_string_lossy()
        .into_owned()
}

/// Look inside a ZIP or 7z archive and classify the bundle within the first
/// three directory levels.
fn recognize_archive_file(
    file: &mut File,
    label: &str,
    password: Option<&str>,
    cancel: &dyn Fn() -> bool,
) -> Result<(Recognized, ArchiveCatalog), String> {
    let catalog = archive_bundle::catalog(file, label, password)?;
    let recognized = recognize_catalog(file, label, &catalog, password, cancel)?;
    Ok((recognized, catalog))
}

fn recognize_catalog(
    file: &mut File,
    label: &str,
    catalog: &ArchiveCatalog,
    password: Option<&str>,
    cancel: &dyn Fn() -> bool,
) -> Result<Recognized, String> {
    if catalog.entries.len() > MAX_ZIP_ENTRIES {
        return Ok(Recognized {
            kind: ZipKind::Unknown,
            entry_script: String::new(),
            entry_data: String::new(),
            app_name: String::new(),
            diagnostic: "archive contains too many entries".to_owned(),
        });
    }
    let mut entries = Vec::with_capacity(catalog.entries.len());
    let mut selected = BTreeMap::new();
    for entry in &catalog.entries {
        if cancel() {
            return Err("archive inspection cancelled".to_owned());
        }
        let name = normalize(&entry.name);
        if name.is_empty() || archive_bundle::is_ignored_metadata_path(&name) {
            continue;
        }
        if !entry.directory
            && depth(&name) <= 3
            && name.rsplit('/').next() == Some("port.json")
            && entry.size <= 64 * 1024
        {
            selected.insert(name.clone(), 64 * 1024);
        }
        if !entry.directory
            && name.ends_with(".sh")
            && depth(&name) <= 3
            && entry.size <= MAX_LAUNCHER_INSPECTION_BYTES
        {
            selected.insert(name.clone(), MAX_LAUNCHER_INSPECTION_BYTES);
        }
        entries.push((name, entry.directory));
    }
    if selected.len() > 64 {
        return Ok(Recognized {
            kind: ZipKind::Unknown,
            entry_script: String::new(),
            entry_data: String::new(),
            app_name: String::new(),
            diagnostic: "archive contains too many launcher or manifest candidates".to_owned(),
        });
    }
    let selected_bytes =
        archive_bundle::read_selected(file, label, catalog, &selected, password, cancel)?;
    let mut package_manifests = Vec::new();
    let mut launcher_text = BTreeMap::new();
    for (name, bytes) in selected_bytes {
        if name.rsplit('/').next() == Some("port.json") {
            if let Ok(manifest) = serde_json::from_slice::<PortPackageManifest>(&bytes) {
                package_manifests.push((name.clone(), manifest));
            }
        } else if name.ends_with(".sh") {
            launcher_text.insert(name.clone(), String::from_utf8_lossy(&bytes).into_owned());
        }
    }
    let mut scripts = Vec::new();
    let mut files = BTreeSet::new();
    let mut dirs = BTreeSet::new();
    for (name, is_dir) in &entries {
        if depth(name) > 3 {
            continue;
        }
        if *is_dir {
            if depth(name) >= 1 && depth(name) <= 3 {
                dirs.insert(name.clone());
            }
            continue;
        }
        // A file also implies its parent directory exists.
        if let Some((parent, _)) = name.rsplit_once('/') {
            let mut current = String::new();
            for component in parent.split('/') {
                current = sibling(&current, component);
                if depth(&current) <= 3 {
                    dirs.insert(current.clone());
                }
            }
        }
        files.insert(name.clone());
        let file_name = name.rsplit('/').next().unwrap_or(name);
        if file_name.ends_with(".sh") {
            scripts.push(name.clone());
        }
    }
    // TrimUI app: launch.sh and config.json must be siblings inside one app
    // folder. A random launch.sh elsewhere in an archive is not sufficient.
    let trimui_launchers = scripts
        .iter()
        .filter(|script| script.rsplit('/').next() == Some("launch.sh"))
        .filter(|script| {
            let launcher_dir = parent(script);
            !launcher_dir.is_empty() && files.contains(&sibling(launcher_dir, "config.json"))
        })
        .collect::<Vec<_>>();
    let mut candidates = Vec::new();
    for launcher in trimui_launchers {
        let launcher_dir = parent(launcher);
        let app_name = launcher_dir
            .rsplit('/')
            .next()
            .unwrap_or(launcher_dir)
            .to_owned();
        candidates.push(Recognized {
            kind: ZipKind::TrimuiApp,
            entry_script: (*launcher).clone(),
            entry_data: String::new(),
            app_name,
            diagnostic: String::new(),
        });
    }
    // A Port payload is associated by the data directory named in the launcher
    // itself. The SH filename is deliberately not part of the association
    // contract: launchers are freely renameable while data directory names are
    // not. A sole sibling directory is not enough evidence by itself.
    scripts.sort_by_key(|script| (depth(script), script.clone()));
    for script in scripts
        .iter()
        .filter(|script| script.rsplit('/').next() != Some("launch.sh"))
    {
        let script_parent = parent(script);
        let script_file = script.rsplit('/').next().unwrap_or(script);
        let script_stem = script_file.trim_end_matches(".sh");
        let sibling_dirs = dirs
            .iter()
            .filter(|directory| parent(directory) == script_parent)
            .cloned()
            .collect::<Vec<_>>();
        let real_dirs = sibling_dirs
            .iter()
            .filter_map(|directory| directory.rsplit('/').next().map(str::to_owned))
            .collect::<BTreeSet<_>>();
        let referenced = launcher_text
            .get(script)
            .map(|text| launcher_data_directories(text, &real_dirs, script_stem, script_parent))
            .unwrap_or_default();
        let data_dir = if referenced.len() == 1 {
            let name = referenced.iter().next().expect("one reference");
            sibling_dirs
                .iter()
                .find(|directory| directory.rsplit('/').next() == Some(name.as_str()))
                .cloned()
        } else {
            None
        };
        if referenced.len() > 1 {
            candidates.push(Recognized {
                kind: ZipKind::Ambiguous,
                entry_script: script.clone(),
                entry_data: String::new(),
                app_name: String::new(),
                diagnostic: "launcher references more than one packaged data directory".to_owned(),
            });
            continue;
        }
        if let Some(data_dir) = data_dir {
            candidates.push(Recognized {
                kind: ZipKind::Port,
                entry_script: script.clone(),
                entry_data: data_dir,
                app_name: String::new(),
                diagnostic: String::new(),
            });
        }
    }
    // A port.json may confirm which payload items belong to one package, but it
    // must never create the launcher/data association by itself. The launcher
    // contents remain the single source of truth for the immutable data-folder
    // name; SH filenames are presentation names and are freely renameable.
    for (manifest_path, manifest) in package_manifests {
        if manifest.items.len() < 2 || manifest.items.len() > 32 {
            continue;
        }
        let manifest_parent = parent(&manifest_path);
        // PortMaster packages use both layouts in the wild:
        //   port.json + launcher + data directory at one level, or
        //   launcher + data/port.json where `items` still names archive-root
        //   entries. A nested manifest may use archive-root items only when it
        //   lives directly inside the declared data directory; this keeps an
        //   unrelated nested manifest from claiming arbitrary payloads.
        let mut bases = vec![manifest_parent];
        if !manifest_parent.is_empty() {
            bases.push("");
        }
        for base in bases {
            let mut declared_scripts = Vec::new();
            let mut declared_data = Vec::new();
            let mut declaration_valid = true;
            for item in &manifest.items {
                let item = normalize(item);
                if validate_path(&item).is_err() || depth(&item) > 2 {
                    declaration_valid = false;
                    break;
                }
                let full = sibling(base, &item);
                if files.contains(&full) && item.ends_with(".sh") {
                    declared_scripts.push(full);
                } else if dirs.contains(&full) {
                    declared_data.push(full);
                }
            }
            let root_relative_nested_manifest = base.is_empty() && !manifest_parent.is_empty();
            if declaration_valid
                && declared_scripts.len() == 1
                && declared_data.len() == 1
                && (!root_relative_nested_manifest || declared_data[0] == manifest_parent)
            {
                let declared_script = declared_scripts.remove(0);
                let declared_directory = declared_data.remove(0);
                let script_parent = parent(&declared_script);
                let script_file = declared_script
                    .rsplit('/')
                    .next()
                    .unwrap_or(&declared_script);
                let script_stem = script_file.trim_end_matches(".sh");
                let Some(data_name) = declared_directory.rsplit('/').next() else {
                    continue;
                };
                let real_dirs = BTreeSet::from([data_name.to_owned()]);
                let referenced = launcher_text
                    .get(&declared_script)
                    .map(|text| {
                        launcher_data_directories(text, &real_dirs, script_stem, script_parent)
                    })
                    .unwrap_or_default();
                if referenced.len() == 1 && referenced.contains(data_name) {
                    candidates.push(Recognized {
                        kind: ZipKind::Port,
                        entry_script: declared_script,
                        entry_data: declared_directory,
                        app_name: String::new(),
                        diagnostic: String::new(),
                    });
                }
            }
        }
    }
    let mut unique = BTreeSet::new();
    candidates.retain(|candidate| {
        unique.insert((
            candidate.kind.name(),
            candidate.entry_script.clone(),
            candidate.entry_data.clone(),
            candidate.app_name.clone(),
        ))
    });
    if candidates.len() == 1 {
        return Ok(candidates.remove(0));
    }
    if candidates.len() > 1 {
        return Ok(Recognized {
            kind: ZipKind::Ambiguous,
            entry_script: String::new(),
            entry_data: String::new(),
            app_name: String::new(),
            diagnostic: format!("archive contains {} installable payloads", candidates.len()),
        });
    }
    Ok(Recognized {
        kind: ZipKind::Unknown,
        entry_script: String::new(),
        entry_data: String::new(),
        app_name: String::new(),
        diagnostic: "archive does not contain one supported APP or Port payload".to_owned(),
    })
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::io::Write;

    use super::*;
    use tempfile::TempDir;

    #[test]
    fn archive_association_uses_explicit_roots_not_magic_directory_names() {
        let names = BTreeSet::from([
            "ports".into(),
            "data".into(),
            "gamedata".into(),
            "Game".into(),
        ]);
        for name in &names {
            for root in ["/ports", "/roms/ports", "$directory/ports"] {
                let text = format!("cd \"{root}/{name}/nested\"\n");
                assert_eq!(
                    launcher_data_directories(&text, &names, "renamed", "wrapper"),
                    BTreeSet::from([name.clone()])
                );
            }
        }
        assert!(
            launcher_data_directories("cd /unrelated/ports/Game\n", &names, "renamed", "wrapper")
                .is_empty()
        );
        assert_eq!(
            launcher_data_directories(
                "cd \"$(dirname \"$0\")/Game\"\n",
                &names,
                "renamed",
                "wrapper"
            ),
            BTreeSet::from(["Game".into()])
        );
    }

    #[test]
    fn archive_issue_keeps_method_details_but_removes_absolute_paths() {
        let issue = archive_issue(
            "/private/device/zip-upload/secret-game.7z",
            "",
            "archive_unsupported_method: 7z:LZMA2 method 21",
        );
        assert_eq!(issue.code, "unsupported_method");
        assert_eq!(issue.format, "7z");
        assert!(issue.report.contains("LZMA2 method 21"));
        assert!(issue.report.contains("secret-game.7z"));
        assert!(!issue.report.contains("/private/device"));
        assert!(!issue.report.contains("zip-upload"));
    }

    #[test]
    fn generic_archive_errors_do_not_copy_raw_error_or_password_text() {
        let issue = archive_issue(
            "/mnt/card/game.zip",
            "zip",
            "cannot read /mnt/card/game.zip with password=hunter2",
        );
        assert_eq!(issue.code, "invalid_archive");
        assert!(!issue.report.contains("/mnt/card"));
        assert!(!issue.report.contains("hunter2"));
        assert!(!issue.report.contains("password="));
    }

    #[test]
    fn unsupported_layout_has_a_stable_feedback_category() {
        let issue = archive_issue(
            "two-games.zip",
            "zip",
            "archive contains 2 installable payloads",
        );
        assert_eq!(issue.code, "unsupported_layout");
        assert!(issue.detail.contains("多个候选"));
    }

    fn current_test_executable() -> PathBuf {
        std::env::var_os("PAM_LAB_TEST_EXECUTABLE")
            .map(PathBuf::from)
            .unwrap_or_else(|| std::env::current_exe().unwrap())
    }
    use zip::write::SimpleFileOptions;

    fn make_zip(dir: &TempDir, name: &str, entries: &[(&str, bool, &[u8])]) -> std::path::PathBuf {
        let path = dir.path().join(name);
        let file = fs::File::create(&path).unwrap();
        let mut zip = zip::ZipWriter::new(file);
        let options =
            SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
        for (entry_name, is_dir, content) in entries {
            if *is_dir {
                zip.add_directory(*entry_name, options).unwrap();
            } else {
                zip.start_file(*entry_name, options).unwrap();
                zip.write_all(content).unwrap();
            }
        }
        zip.finish().unwrap();
        path
    }

    fn set_zip_compression_method(path: &Path, method: u16) {
        let mut bytes = fs::read(path).unwrap();
        let encoded = method.to_le_bytes();
        for index in 0..bytes.len().saturating_sub(12) {
            if bytes[index..].starts_with(b"PK\x03\x04") {
                bytes[index + 8..index + 10].copy_from_slice(&encoded);
            } else if bytes[index..].starts_with(b"PK\x01\x02") {
                bytes[index + 10..index + 12].copy_from_slice(&encoded);
            }
        }
        fs::write(path, bytes).unwrap();
    }

    #[test]
    fn scan_reports_the_exact_unsupported_zip_method() {
        let temp = tempfile::tempdir().unwrap();
        let path = make_zip(
            &temp,
            "ppmd.zip",
            &[
                ("game.sh", false, b"#!/bin/sh\nGAMEDIR=/ports/game\n"),
                ("game/data.bin", false, b"data"),
            ],
        );
        set_zip_compression_method(&path, 98);

        let found = scan_zip_bundles(&[temp.path()], &|| false).unwrap();

        assert_eq!(found.len(), 1);
        let issue = found[0].issue.as_ref().unwrap();
        assert_eq!(issue.code, "unsupported_method");
        assert_eq!(issue.format, "zip");
        assert!(issue.detail.contains("PPMd (method 98)"));
    }

    fn make_encrypted_zip(
        dir: &TempDir,
        name: &str,
        password: &str,
        entries: &[(&str, &[u8])],
    ) -> PathBuf {
        let path = dir.path().join(name);
        let file = fs::File::create(&path).unwrap();
        let mut zip = zip::ZipWriter::new(file);
        for (entry_name, content) in entries {
            let options = SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated)
                .with_aes_encryption(zip::AesMode::Aes256, password);
            zip.start_file(*entry_name, options).unwrap();
            zip.write_all(content).unwrap();
        }
        zip.finish().unwrap();
        path
    }

    fn make_7z(dir: &TempDir, name: &str, password: Option<&str>) -> PathBuf {
        let source = dir.path().join(format!("{name}-source"));
        fs::create_dir_all(source.join("seven-game")).unwrap();
        fs::create_dir_all(source.join("__MACOSX")).unwrap();
        fs::write(
            source.join("Seven_Game.sh"),
            b"#!/bin/sh\nGAMEDIR=/ports/seven-game\n",
        )
        .unwrap();
        fs::write(source.join("seven-game/data.bin"), b"game data").unwrap();
        fs::write(source.join(".DS_Store"), b"junk").unwrap();
        fs::write(
            source.join("__MACOSX/ignored.sh"),
            b"GAMEDIR=/ports/wrong\n",
        )
        .unwrap();
        let path = dir.path().join(name);
        let mut writer = sevenz_rust2::ArchiveWriter::create(&path).unwrap();
        if let Some(password) = password {
            writer.set_content_methods(vec![
                sevenz_rust2::encoder_options::AesEncoderOptions::new(sevenz_rust2::Password::new(
                    password,
                ))
                .into(),
                sevenz_rust2::EncoderMethod::LZMA2.into(),
            ]);
        }
        writer.push_source_path(&source, |_| true).unwrap();
        writer.finish().unwrap();
        path
    }

    fn no_cancel() -> impl Fn() -> bool {
        move || false
    }

    #[test]
    fn encrypted_zip_requires_a_password_and_installs_after_unlocking() {
        let temp = tempfile::tempdir().unwrap();
        let path = make_encrypted_zip(
            &temp,
            "encrypted.zip",
            "s3cret",
            &[
                ("Encrypted.sh", b"#!/bin/sh\nGAMEDIR=/ports/encrypted\n"),
                ("encrypted/data.bin", b"game data"),
                ("__MACOSX/ignored.sh", b"GAMEDIR=/ports/wrong\n"),
            ],
        );
        let scanned = scan_zip_bundles(&[temp.path()], &no_cancel()).unwrap();
        assert_eq!(scanned.len(), 1);
        assert_eq!(scanned[0].kind, "locked");
        assert_eq!(scanned[0].format, "zip");
        assert!(scanned[0].password_required);
        assert!(is_password_required_error(
            &inspect_archive_bundle_with_password(&path, None, &no_cancel()).unwrap_err()
        ));
        assert!(is_invalid_password_error(
            &inspect_archive_bundle_with_password(&path, Some("wrong"), &no_cancel()).unwrap_err()
        ));

        let scripts = temp.path().join("scripts");
        let games = temp.path().join("games");
        let trash = temp.path().join("trash");
        let work = temp.path().join("work");
        for root in [&scripts, &games, &trash, &work] {
            fs::create_dir(root).unwrap();
        }
        install_bundle_replacing_with_password(
            &scanned[0],
            &scripts,
            &games,
            &[],
            &trash,
            &work,
            &BundleLimits::default(),
            false,
            Some("s3cret"),
            &no_cancel(),
        )
        .unwrap();
        assert!(scripts.join("Encrypted.sh").is_file());
        assert_eq!(
            fs::read(games.join("encrypted/data.bin")).unwrap(),
            b"game data"
        );
        assert!(!path.exists());
    }

    #[test]
    fn plain_and_encrypted_7z_are_recognized_and_mac_metadata_is_ignored() {
        let temp = tempfile::tempdir().unwrap();
        let plain = make_7z(&temp, "plain.7z", None);
        let candidate = inspect_archive_bundle_with_password(&plain, None, &no_cancel()).unwrap();
        assert_eq!(candidate.kind, "port");
        assert_eq!(candidate.format, "7z");
        assert_eq!(candidate.entry_script, "Seven_Game.sh");
        assert_eq!(candidate.entry_data, "seven-game");

        let encrypted = make_7z(&temp, "encrypted.7z", Some("7z-pass"));
        let scanned = scan_zip_bundles(&[temp.path()], &no_cancel()).unwrap();
        let locked = scanned
            .iter()
            .find(|bundle| bundle.path == encrypted.to_string_lossy())
            .unwrap()
            .clone();
        assert_eq!(locked.kind, "locked");
        assert_eq!(locked.format, "7z");
        assert!(locked.password_required);
        assert!(is_invalid_password_error(
            &inspect_archive_bundle_with_password(&encrypted, Some("wrong"), &no_cancel())
                .unwrap_err()
        ));
        let unlocked =
            inspect_archive_bundle_with_password(&encrypted, Some("7z-pass"), &no_cancel())
                .unwrap();
        assert_eq!(unlocked.kind, "port");
        assert_eq!(unlocked.entry_data, "seven-game");

        let scripts = temp.path().join("seven-scripts");
        let games = temp.path().join("seven-games");
        let trash = temp.path().join("seven-trash");
        let work = temp.path().join("seven-work");
        for root in [&scripts, &games, &trash, &work] {
            fs::create_dir(root).unwrap();
        }
        install_bundle_replacing_with_password(
            &locked,
            &scripts,
            &games,
            &[],
            &trash,
            &work,
            &BundleLimits::default(),
            false,
            Some("7z-pass"),
            &no_cancel(),
        )
        .unwrap();
        assert!(scripts.join("Seven_Game.sh").is_file());
        assert_eq!(
            fs::read(games.join("seven-game/data.bin")).unwrap(),
            b"game data"
        );
        assert!(!encrypted.exists());
    }

    #[test]
    fn recognizes_standard_port_with_nested_folder() {
        let temp = tempfile::tempdir().unwrap();
        let path = make_zip(
            &temp,
            "game.zip",
            &[
                ("game.sh", false, b"#!/bin/sh\nGAMEDIR=\"/ports/game\"\n"),
                ("game/data/save.txt", false, b"save"),
                ("game/config.json", false, b"{}"),
            ],
        );
        let cancel = no_cancel();
        let found = scan_zip_bundles(&[temp.path()], &cancel).unwrap();
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].kind, "port");
        assert_eq!(found[0].entry_script, "game.sh");
        assert_eq!(found[0].entry_data, "game");

        let direct = inspect_zip_bundle(&path, &cancel).unwrap();
        assert_eq!(direct, found[0]);
    }

    #[test]
    fn port_json_confirms_a_launcher_with_a_differently_named_data_folder() {
        let temp = tempfile::tempdir().unwrap();
        let path = make_zip(
            &temp,
            "appmanager.zip",
            &[
                (
                    "port.json",
                    false,
                    br#"{"items":["APP Manager.sh","jenny92-appmanager"]}"#,
                ),
                (
                    "APP Manager.sh",
                    false,
                    b"#!/bin/sh\nGAMEDIR=/$directory/ports/jenny92-appmanager\n",
                ),
                ("jenny92-appmanager/runtime.bin", false, b"runtime"),
                ("unrelated/file.bin", false, b"not selected"),
            ],
        );
        let candidate = inspect_zip_bundle(&path, &no_cancel()).unwrap();
        assert_eq!(candidate.kind, "port");
        assert_eq!(candidate.entry_script, "APP Manager.sh");
        assert_eq!(candidate.entry_data, "jenny92-appmanager");
    }

    #[test]
    fn port_json_cannot_invent_a_launcher_data_directory_association() {
        let temp = tempfile::tempdir().unwrap();
        let path = make_zip(
            &temp,
            "unbound.zip",
            &[
                (
                    "port.json",
                    false,
                    r#"{"items":["任意名字.sh","fixed-data"]}"#.as_bytes(),
                ),
                ("任意名字.sh", false, b"#!/bin/sh\necho start\n"),
                ("fixed-data/game.bin", false, b"runtime"),
            ],
        );
        let candidate = inspect_zip_bundle(&path, &no_cancel()).unwrap();
        assert_eq!(candidate.kind, "unknown");
        assert!(candidate.entry_data.is_empty());
    }

    #[test]
    fn port_json_inside_data_directory_can_declare_archive_root_items() {
        let temp = tempfile::tempdir().unwrap();
        let path = make_zip(
            &temp,
            "portable-game.zip",
            &[
                (
                    "Z_植物大战僵尸[中].sh",
                    false,
                    b"#!/bin/sh\nGAMEDIR=/$directory/ports/pvz_portable_jenny\n",
                ),
                (
                    "pvz_portable_jenny/port.json",
                    false,
                    r#"{"items":["Z_植物大战僵尸[中].sh","pvz_portable_jenny"]}"#.as_bytes(),
                ),
                ("pvz_portable_jenny/game.bin", false, b"binary"),
            ],
        );
        let candidate = inspect_zip_bundle(&path, &no_cancel()).unwrap();
        assert_eq!(candidate.kind, "port");
        assert_eq!(candidate.entry_script, "Z_植物大战僵尸[中].sh");
        assert_eq!(candidate.entry_data, "pvz_portable_jenny");
    }

    #[test]
    fn launcher_contents_bind_a_freely_named_sh_to_its_immutable_data_folder() {
        let temp = tempfile::tempdir().unwrap();
        let path = make_zip(
            &temp,
            "pvz.zip",
            &[
                (
                    "Z_植物大战僵尸[中].sh",
                    false,
                    b"#!/bin/sh\nGAMEDIR=/roms/ports/pvz_portable_jenny\n",
                ),
                ("pvz_portable_jenny/game.bin", false, b"game"),
                ("docs/readme.txt", false, b"docs"),
            ],
        );
        let candidate = inspect_zip_bundle(&path, &no_cancel()).unwrap();
        assert_eq!(candidate.kind, "port");
        assert_eq!(candidate.entry_script, "Z_植物大战僵尸[中].sh");
        assert_eq!(candidate.entry_data, "pvz_portable_jenny");

        let scripts = temp.path().join("scripts");
        let games = temp.path().join("games");
        let trash = temp.path().join("trash");
        let work = temp.path().join("work");
        for root in [&scripts, &games, &trash, &work] {
            fs::create_dir(root).unwrap();
        }
        fs::write(scripts.join("Z_植物大战僵尸[中].sh"), b"existing").unwrap();
        install_bundle(
            &candidate,
            &scripts,
            &games,
            &[],
            &trash,
            &work,
            &BundleLimits::default(),
            &no_cancel(),
        )
        .unwrap();
        assert!(scripts.join("Z_植物大战僵尸[中]1.sh").is_file());
        assert!(games.join("pvz_portable_jenny/game.bin").is_file());
        assert!(
            fs::read_to_string(scripts.join("Z_植物大战僵尸[中]1.sh"))
                .unwrap()
                .contains("pvz_portable_jenny")
        );
    }

    #[test]
    fn runtime_mount_prefix_does_not_hide_a_literal_data_folder_name() {
        let temp = tempfile::tempdir().unwrap();
        let path = make_zip(
            &temp,
            "portable.zip",
            &[
                (
                    "任意显示名字.sh",
                    false,
                    b"PORT_NAME=pvz_portable_jenny\nGAMEDIR=\"/$directory/ports/$PORT_NAME\"\n",
                ),
                ("pvz_portable_jenny/game.bin", false, b"game"),
            ],
        );
        let candidate = inspect_zip_bundle(&path, &no_cancel()).unwrap();
        assert_eq!(candidate.kind, "port");
        assert_eq!(candidate.entry_script, "任意显示名字.sh");
        assert_eq!(candidate.entry_data, "pvz_portable_jenny");
    }

    #[test]
    fn numbered_launcher_preserves_the_literal_data_directory_reference() {
        let temp = tempfile::tempdir().unwrap();
        let path = make_zip(
            &temp,
            "game.zip",
            &[
                (
                    "game.sh",
                    false,
                    br#"#!/bin/sh
GAMEDIR="/$directory/ports/game"
"#,
                ),
                ("port.json", false, br#"{"items":["game.sh","game"]}"#),
                ("game/data.bin", false, b"data"),
            ],
        );
        let candidate = inspect_zip_bundle(&path, &no_cancel()).unwrap();
        let scripts = temp.path().join("scripts");
        let games = temp.path().join("games");
        let trash = temp.path().join("trash");
        let work = temp.path().join("work");
        for root in [&scripts, &games, &trash, &work] {
            fs::create_dir(root).unwrap();
        }
        fs::write(scripts.join("game.sh"), b"existing").unwrap();
        install_bundle(
            &candidate,
            &scripts,
            &games,
            &[],
            &trash,
            &work,
            &BundleLimits::default(),
            &no_cancel(),
        )
        .unwrap();
        let installed = fs::read_to_string(scripts.join("game1.sh")).unwrap();
        assert!(installed.contains("/ports/game"), "{installed}");
        assert!(!installed.contains("/ports/game1"), "{installed}");
    }

    #[test]
    fn recognizes_trimui_app_folder() {
        let temp = tempfile::tempdir().unwrap();
        make_zip(
            &temp,
            "myapp.zip",
            &[
                ("myapp/launch.sh", false, b"#!/bin/sh\nexec app\n"),
                ("myapp/config.json", false, b"{}"),
                ("myapp/icon.png", false, b"png"),
                ("myapp/bin/app", false, b"elf"),
            ],
        );
        let cancel = no_cancel();
        let found = scan_zip_bundles(&[temp.path()], &cancel).unwrap();
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].kind, "trimui_app");
        assert_eq!(found[0].app_name, "myapp");
    }

    #[test]
    fn app_install_rejects_an_ambiguous_configured_destination() {
        let temp = tempfile::tempdir().unwrap();
        let archive = make_zip(
            &temp,
            "myapp.zip",
            &[
                ("myapp/launch.sh", false, b"#!/bin/sh\n"),
                ("myapp/config.json", false, b"{}"),
            ],
        );
        let bundle = inspect_zip_bundle(&archive, &no_cancel()).unwrap();
        let scripts = temp.path().join("scripts");
        let games = temp.path().join("games");
        let first_apps = temp.path().join("apps-a");
        let second_apps = temp.path().join("apps-b");
        let trash = temp.path().join("trash");
        let work = temp.path().join("work");
        let error = install_uploaded_bundle(
            &bundle,
            &scripts,
            &games,
            &[first_apps.as_path(), second_apps.as_path()],
            &trash,
            &work,
            &BundleLimits::default(),
            &no_cancel(),
        )
        .unwrap_err();
        assert!(error.contains("exactly one APP install target"), "{error}");
        assert!(archive.is_file());
        assert!(!first_apps.exists());
        assert!(!second_apps.exists());
    }

    #[test]
    fn rejects_non_game_zips() {
        let temp = tempfile::tempdir().unwrap();
        make_zip(
            &temp,
            "docs.zip",
            &[
                ("readme.txt", false, b"hello"),
                ("images/logo.png", false, b"png"),
            ],
        );
        let cancel = no_cancel();
        let found = scan_zip_bundles(&[temp.path()], &cancel).unwrap();
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].kind, "unknown");
    }

    #[test]
    fn never_selects_an_unrelated_directory_as_port_data() {
        let temp = tempfile::tempdir().unwrap();
        make_zip(
            &temp,
            "mixed.zip",
            &[
                ("game.sh", false, b"#!/bin/sh\nGAMEDIR=/ports/game\n"),
                ("docs/readme.txt", false, b"documentation"),
                ("game/data.bin", false, b"game"),
            ],
        );
        let bundle = inspect_zip_bundle(&temp.path().join("mixed.zip"), &no_cancel()).unwrap();
        assert_eq!(bundle.entry_data, "game");

        let unrelated = make_zip(
            &temp,
            "unrelated.zip",
            &[
                ("other.sh", false, b"#!/bin/sh\n"),
                ("docs/readme.txt", false, b"documentation"),
            ],
        );
        let bundle = inspect_zip_bundle(&unrelated, &no_cancel()).unwrap();
        assert_eq!(bundle.entry_data, "");
    }

    #[test]
    fn recognizes_wrapped_port_and_keeps_only_the_data_leaf_name() {
        let temp = tempfile::tempdir().unwrap();
        let zip = make_zip(
            &temp,
            "wrapped.zip",
            &[
                (
                    "package/game.sh",
                    false,
                    b"#!/bin/sh\nGAMEDIR=/ports/game\n",
                ),
                ("package/game/data.bin", false, b"game"),
            ],
        );
        let bundle = inspect_zip_bundle(&zip, &no_cancel()).unwrap();
        assert_eq!(bundle.entry_script, "package/game.sh");
        assert_eq!(bundle.entry_data, "package/game");

        let scripts = temp.path().join("scripts");
        let games = temp.path().join("games");
        let apps = temp.path().join("apps");
        let trash = temp.path().join("trash");
        let work = temp.path().join("work");
        for directory in [&scripts, &games, &apps, &trash, &work] {
            fs::create_dir_all(directory).unwrap();
        }
        install_uploaded_bundle(
            &bundle,
            &scripts,
            &games,
            &[apps.as_path()],
            &trash,
            &work,
            &BundleLimits::default(),
            &no_cancel(),
        )
        .unwrap();
        assert!(scripts.join("game.sh").is_file());
        assert!(games.join("game/data.bin").is_file());
        assert!(!games.join("package").exists());
    }

    #[test]
    fn launch_sh_without_sibling_config_is_not_a_trimui_app() {
        let temp = tempfile::tempdir().unwrap();
        let zip = make_zip(
            &temp,
            "not-an-app.zip",
            &[
                ("tools/launch.sh", false, b"#!/bin/sh\n"),
                ("tools/readme.txt", false, b"docs"),
            ],
        );
        assert_eq!(
            inspect_zip_bundle(&zip, &no_cancel()).unwrap().kind,
            "unknown"
        );
    }

    #[test]
    fn installs_standard_port_and_retires_the_zip() {
        let temp = tempfile::tempdir().unwrap();
        let zip = make_zip(
            &temp,
            "game.zip",
            &[
                ("game.sh", false, b"#!/bin/sh\nGAMEDIR=\"/ports/game\"\n"),
                ("game/data/save.txt", false, b"save"),
            ],
        );
        let cancel = no_cancel();
        let bundles = scan_zip_bundles(&[temp.path()], &cancel).unwrap();
        assert_eq!(bundles.len(), 1);
        assert_eq!(bundles[0].kind, "port");
        let scripts = temp.path().join("scripts");
        let games = temp.path().join("games");
        let apps = temp.path().join("apps");
        let trash = temp.path().join("trash");
        let work = temp.path().join("work");
        for d in [&scripts, &games, &apps, &trash, &work] {
            fs::create_dir_all(d).unwrap();
        }
        let outcome = install_bundle(
            &bundles[0],
            &scripts,
            &games,
            &[apps.as_path()],
            &trash,
            &work,
            &BundleLimits::default(),
            &no_cancel(),
        )
        .unwrap();
        assert_eq!(outcome.conflicts.len(), 0);
        assert!(scripts.join("game.sh").is_file());
        assert!(games.join("game").join("data/save.txt").is_file());
        // The zip was moved to the trash, not left at the root.
        assert!(!zip.exists());
        let trash_count = fs::read_dir(&trash).unwrap().count();
        assert!(trash_count >= 1);
        // Re-running still conflicts because the data directory already
        // exists. The existing launcher is never overwritten.
        let zip2 = make_zip(
            &temp,
            "game2.zip",
            &[
                ("game.sh", false, b"GAMEDIR=/ports/game\nnew"),
                ("game/data/new.txt", false, b"new"),
            ],
        );
        let b2 = scan_zip_bundles(&[temp.path()], &cancel).unwrap();
        let outcome2 = install_bundle(
            &b2[0],
            &scripts,
            &games,
            &[apps.as_path()],
            &trash,
            &work,
            &BundleLimits::default(),
            &no_cancel(),
        )
        .unwrap();
        assert!(outcome2.conflicts.iter().any(|c| c.ends_with("games/game")));
        assert!(zip2.exists()); // nothing installed -> zip stays
    }

    #[test]
    fn duplicate_port_launchers_receive_the_next_numeric_suffix() {
        let temp = tempfile::tempdir().unwrap();
        let zip = make_zip(
            &temp,
            "game.zip",
            &[
                ("game.sh", false, b"GAMEDIR=/ports/game\nnew launcher"),
                ("game/data.bin", false, b"data"),
            ],
        );
        let bundle = inspect_zip_bundle(&zip, &no_cancel()).unwrap();
        let scripts = temp.path().join("scripts");
        let games = temp.path().join("games");
        let apps = temp.path().join("apps");
        let trash = temp.path().join("trash");
        let work = temp.path().join("work");
        for directory in [&scripts, &games, &apps, &trash, &work] {
            fs::create_dir_all(directory).unwrap();
        }
        fs::write(scripts.join("game.sh"), b"original launcher").unwrap();
        fs::write(scripts.join("game1.sh"), b"first duplicate").unwrap();

        let outcome = install_bundle(
            &bundle,
            &scripts,
            &games,
            &[apps.as_path()],
            &trash,
            &work,
            &BundleLimits::default(),
            &no_cancel(),
        )
        .unwrap();

        assert!(outcome.conflicts.is_empty());
        assert_eq!(
            fs::read(scripts.join("game.sh")).unwrap(),
            b"original launcher"
        );
        assert_eq!(
            fs::read(scripts.join("game1.sh")).unwrap(),
            b"first duplicate"
        );
        assert_eq!(
            fs::read(scripts.join("game2.sh")).unwrap(),
            b"GAMEDIR=/ports/game\nnew launcher"
        );
        assert!(games.join("game/data.bin").is_file());
        assert!(
            outcome
                .installed
                .iter()
                .any(|path| path.ends_with("game2.sh"))
        );
    }

    #[test]
    fn remote_upload_is_removed_instead_of_retained_in_trash() {
        let temp = tempfile::tempdir().unwrap();
        let zip = make_zip(
            &temp,
            "upload.zip",
            &[
                ("upload.sh", false, b"#!/bin/sh\nGAMEDIR=/ports/upload\n"),
                ("upload/data.bin", false, b"data"),
            ],
        );
        let cancel = no_cancel();
        let bundle = inspect_zip_bundle(&zip, &cancel).unwrap();
        let scripts = temp.path().join("scripts");
        let games = temp.path().join("games");
        let apps = temp.path().join("apps");
        let trash = temp.path().join("trash");
        let work = temp.path().join("work");
        for directory in [&scripts, &games, &apps, &trash, &work] {
            fs::create_dir_all(directory).unwrap();
        }
        let outcome = install_uploaded_bundle(
            &bundle,
            &scripts,
            &games,
            &[apps.as_path()],
            &trash,
            &work,
            &BundleLimits::default(),
            &no_cancel(),
        )
        .unwrap();
        assert_eq!(outcome.installed.len(), 2);
        assert!(!zip.exists());
        assert_eq!(fs::read_dir(trash).unwrap().count(), 0);
    }

    #[test]
    fn a_data_conflict_prevents_the_launcher_from_being_installed() {
        let temp = tempfile::tempdir().unwrap();
        let zip = make_zip(
            &temp,
            "atomic.zip",
            &[
                ("atomic.sh", false, b"#!/bin/sh\nGAMEDIR=/ports/atomic\n"),
                ("atomic/data.bin", false, b"data"),
            ],
        );
        let bundle = inspect_zip_bundle(&zip, &no_cancel()).unwrap();
        let scripts = temp.path().join("scripts");
        let games = temp.path().join("games");
        let apps = temp.path().join("apps");
        let trash = temp.path().join("trash");
        let work = temp.path().join("work");
        for directory in [&scripts, &games, &apps, &trash, &work] {
            fs::create_dir_all(directory).unwrap();
        }
        fs::create_dir_all(games.join("atomic")).unwrap();
        let outcome = install_bundle(
            &bundle,
            &scripts,
            &games,
            &[apps.as_path()],
            &trash,
            &work,
            &BundleLimits::default(),
            &no_cancel(),
        )
        .unwrap();
        assert!(outcome.installed.is_empty());
        assert_eq!(outcome.conflicts.len(), 1);
        assert!(!scripts.join("atomic.sh").exists());
        assert!(zip.exists());
    }

    #[test]
    fn confirmed_data_replacement_is_transactional_and_keeps_sh_names_independent() {
        let temp = tempfile::tempdir().unwrap();
        let zip = make_zip(
            &temp,
            "replace.zip",
            &[
                ("display.sh", false, b"GAMEDIR=/ports/data-folder\n"),
                ("data-folder/version", false, b"new"),
            ],
        );
        let bundle = inspect_zip_bundle(&zip, &no_cancel()).unwrap();
        let scripts = temp.path().join("scripts");
        let games = temp.path().join("games");
        let trash = temp.path().join("trash");
        let work = temp.path().join("work");
        for root in [&scripts, &games, &trash, &work] {
            fs::create_dir(root).unwrap();
        }
        fs::write(scripts.join("display.sh"), b"old launcher").unwrap();
        fs::create_dir(games.join("data-folder")).unwrap();
        fs::write(games.join("data-folder/version"), b"old").unwrap();

        let outcome = install_bundle_replacing(
            &bundle,
            &scripts,
            &games,
            &[],
            &trash,
            &work,
            &BundleLimits::default(),
            true,
            &no_cancel(),
        )
        .unwrap();

        assert!(outcome.conflicts.is_empty());
        assert_eq!(
            fs::read(scripts.join("display.sh")).unwrap(),
            b"old launcher"
        );
        assert!(scripts.join("display1.sh").is_file());
        assert_eq!(fs::read(games.join("data-folder/version")).unwrap(), b"new");
        assert!(!zip.exists());
    }

    #[test]
    fn replacement_rolls_the_old_directory_back_when_source_retirement_fails() {
        let temp = tempfile::tempdir().unwrap();
        let zip = make_zip(
            &temp,
            "replace-fail.zip",
            &[
                ("display.sh", false, b"GAMEDIR=/ports/data-folder\n"),
                ("data-folder/version", false, b"new"),
            ],
        );
        let bundle = inspect_zip_bundle(&zip, &no_cancel()).unwrap();
        let scripts = temp.path().join("scripts");
        let games = temp.path().join("games");
        let trash = temp.path().join("trash-file");
        let work = temp.path().join("work");
        for root in [&scripts, &games, &work] {
            fs::create_dir(root).unwrap();
        }
        fs::write(&trash, b"not a directory").unwrap();
        fs::create_dir(games.join("data-folder")).unwrap();
        fs::write(games.join("data-folder/version"), b"old").unwrap();

        assert!(
            install_bundle_replacing(
                &bundle,
                &scripts,
                &games,
                &[],
                &trash,
                &work,
                &BundleLimits::default(),
                true,
                &no_cancel(),
            )
            .is_err()
        );
        assert_eq!(fs::read(games.join("data-folder/version")).unwrap(), b"old");
        assert!(!scripts.join("display.sh").exists());
        assert!(zip.exists());
    }

    #[test]
    fn archive_validation_rejects_duplicate_normalized_paths() {
        let temp = tempfile::tempdir().unwrap();
        let path = make_zip(
            &temp,
            "duplicate.zip",
            &[
                ("game.sh", false, b"GAMEDIR=/ports/game\n"),
                ("game/data.bin", false, b"first"),
                ("./game/data.bin", false, b"second"),
            ],
        );
        let mut file = open_archive(&path).unwrap();
        let error = validate_archive_file(
            &mut file,
            "duplicate.zip",
            &BundleLimits::default(),
            None,
            &no_cancel(),
        )
        .unwrap_err();
        assert!(error.contains("duplicate entry"), "{error}");
    }

    #[test]
    fn destination_preflight_failure_leaves_no_partial_launcher() {
        let temp = tempfile::tempdir().unwrap();
        let zip = make_zip(
            &temp,
            "blocked.zip",
            &[
                ("blocked.sh", false, b"#!/bin/sh\nGAMEDIR=/ports/blocked\n"),
                ("blocked/data.bin", false, b"data"),
            ],
        );
        let bundle = inspect_zip_bundle(&zip, &no_cancel()).unwrap();
        let scripts = temp.path().join("scripts");
        let games = temp.path().join("games-is-a-file");
        let apps = temp.path().join("apps");
        let trash = temp.path().join("trash");
        let work = temp.path().join("work");
        for directory in [&scripts, &apps, &trash, &work] {
            fs::create_dir_all(directory).unwrap();
        }
        fs::write(&games, b"not a directory").unwrap();
        assert!(
            install_bundle(
                &bundle,
                &scripts,
                &games,
                &[apps.as_path()],
                &trash,
                &work,
                &BundleLimits::default(),
                &no_cancel(),
            )
            .is_err()
        );
        assert!(!scripts.join("blocked.sh").exists());
        assert!(zip.exists());
    }

    #[test]
    fn failing_to_retire_the_source_rolls_back_committed_targets() {
        let temp = tempfile::tempdir().unwrap();
        let zip = make_zip(
            &temp,
            "retire.zip",
            &[
                ("retire.sh", false, b"#!/bin/sh\nGAMEDIR=/ports/retire\n"),
                ("retire/data.bin", false, b"data"),
            ],
        );
        let bundle = inspect_zip_bundle(&zip, &no_cancel()).unwrap();
        let scripts = temp.path().join("scripts");
        let games = temp.path().join("games");
        let apps = temp.path().join("apps");
        let trash = temp.path().join("trash-is-a-file");
        let work = temp.path().join("work");
        for directory in [&scripts, &games, &apps, &work] {
            fs::create_dir_all(directory).unwrap();
        }
        fs::write(&trash, b"not a directory").unwrap();
        assert!(
            install_bundle(
                &bundle,
                &scripts,
                &games,
                &[apps.as_path()],
                &trash,
                &work,
                &BundleLimits::default(),
                &no_cancel(),
            )
            .is_err()
        );
        assert!(!scripts.join("retire.sh").exists());
        assert!(!games.join("retire").exists());
        assert!(zip.exists());
    }

    #[test]
    fn cancellation_during_staging_leaves_source_and_destinations_untouched() {
        use std::cell::Cell;

        let temp = tempfile::tempdir().unwrap();
        let zip = make_zip(
            &temp,
            "cancel.zip",
            &[
                ("cancel.sh", false, b"#!/bin/sh\nGAMEDIR=/ports/cancel\n"),
                ("cancel/data.bin", false, &[7_u8; 1024 * 1024]),
            ],
        );
        let bundle = inspect_zip_bundle(&zip, &no_cancel()).unwrap();
        let scripts = temp.path().join("scripts");
        let games = temp.path().join("games");
        let apps = temp.path().join("apps");
        let trash = temp.path().join("trash");
        let work = temp.path().join("work");
        for directory in [&scripts, &games, &apps, &trash, &work] {
            fs::create_dir_all(directory).unwrap();
        }
        let checks = Cell::new(0_u32);
        let cancel = || {
            let next = checks.get() + 1;
            checks.set(next);
            next > 5
        };

        let error = install_bundle(
            &bundle,
            &scripts,
            &games,
            &[apps.as_path()],
            &trash,
            &work,
            &BundleLimits::default(),
            &cancel,
        )
        .unwrap_err();
        assert!(error.contains("cancelled"));
        assert!(zip.is_file());
        assert!(!scripts.join("cancel.sh").exists());
        assert!(!games.join("cancel").exists());
    }

    #[cfg(unix)]
    #[test]
    fn scanning_alias_roots_reports_each_archive_once() {
        let temp = tempfile::tempdir().unwrap();
        let real = temp.path().join("real");
        let alias = temp.path().join("alias");
        fs::create_dir(&real).unwrap();
        std::os::unix::fs::symlink(&real, &alias).unwrap();
        let zip = real.join("game.zip");
        let file = fs::File::create(&zip).unwrap();
        let mut writer = zip::ZipWriter::new(file);
        writer
            .start_file("game.sh", SimpleFileOptions::default())
            .unwrap();
        writer.write_all(b"#!/bin/sh\n").unwrap();
        writer.finish().unwrap();
        let found = scan_zip_bundles(&[&real, &alias], &no_cancel()).unwrap();
        assert_eq!(
            found
                .iter()
                .filter(|item| item.path.ends_with("game.zip"))
                .count(),
            1
        );
    }

    #[test]
    fn deeper_than_three_levels_is_not_a_bundle() {
        let temp = tempfile::tempdir().unwrap();
        make_zip(
            &temp,
            "deep.zip",
            &[
                ("a/b/c/game.sh", false, b"#!/bin/sh\n"),
                ("a/b/c/data/", true, b""),
            ],
        );
        let cancel = no_cancel();
        let found = scan_zip_bundles(&[temp.path()], &cancel).unwrap();
        // The .sh is at depth 4: not recognized.
        assert_eq!(found[0].kind, "unknown");
    }

    #[test]
    fn multiple_ports_are_rejected_as_ambiguous() {
        let temp = tempfile::tempdir().unwrap();
        let path = make_zip(
            &temp,
            "multi.zip",
            &[
                ("a.sh", false, b"#!/bin/sh\nGAMEDIR=/ports/a\n"),
                ("a/", true, b""),
                ("b.sh", false, b"#!/bin/sh\nGAMEDIR=/ports/b\n"),
                ("b/", true, b""),
            ],
        );
        let candidate = inspect_zip_bundle(&path, &no_cancel()).unwrap();
        assert_eq!(candidate.kind, "ambiguous");
        assert!(candidate.diagnostic.contains("2 installable payloads"));
    }

    #[test]
    fn one_launcher_referencing_two_packaged_directories_is_ambiguous() {
        let temp = tempfile::tempdir().unwrap();
        let path = make_zip(
            &temp,
            "multi-data.zip",
            &[
                (
                    "display.sh",
                    false,
                    b"GAMEDIR=/ports/primary\ncd /ports/secondary\n",
                ),
                ("primary/data", false, b"a"),
                ("secondary/data", false, b"b"),
            ],
        );
        let candidate = inspect_zip_bundle(&path, &no_cancel()).unwrap();
        assert_eq!(candidate.kind, "ambiguous");
        assert!(candidate.diagnostic.contains("more than one"));
    }

    #[test]
    fn mixed_app_and_port_are_rejected_as_ambiguous() {
        let temp = tempfile::tempdir().unwrap();
        let path = make_zip(
            &temp,
            "mixed.zip",
            &[
                ("app/launch.sh", false, b"#!/bin/sh\n"),
                ("app/config.json", false, b"{}"),
                ("game.sh", false, b"#!/bin/sh\nGAMEDIR=/ports/game\n"),
                ("game/", true, b""),
            ],
        );
        assert_eq!(
            inspect_zip_bundle(&path, &no_cancel()).unwrap().kind,
            "ambiguous"
        );
    }

    #[test]
    fn corrupt_archive_does_not_hide_valid_archives_in_the_same_root() {
        let temp = tempfile::tempdir().unwrap();
        make_zip(
            &temp,
            "valid.zip",
            &[
                ("game.sh", false, b"#!/bin/sh\nGAMEDIR=/ports/game\n"),
                ("game/", true, b""),
            ],
        );
        fs::write(temp.path().join("broken.zip"), b"not a zip").unwrap();
        let found = scan_zip_bundles(&[temp.path()], &no_cancel()).unwrap();
        assert_eq!(found.len(), 2);
        assert!(found.iter().any(|candidate| candidate.kind == "port"));
        assert!(found.iter().any(|candidate| candidate.kind == "invalid"));
    }

    #[test]
    fn crash_recovery_infers_a_fully_published_launcher_as_committed() {
        let temp = tempfile::tempdir().unwrap();
        let scripts = temp.path().join("scripts");
        let games = temp.path().join("games");
        let apps = temp.path().join("apps");
        let trash = temp.path().join("trash");
        let work = temp.path().join("work");
        for directory in [&scripts, &games, &apps, &trash, &work] {
            fs::create_dir(directory).unwrap();
        }
        let owner_token = "a".repeat(64);
        let transaction_id = format!("{BUNDLE_TRANSACTION_PREFIX}{owner_token}");
        let temporary = scripts.join(format!(".pam-install-stage-{transaction_id}-0-crash"));
        let target = scripts.join("crash.sh");
        fs::write(&temporary, b"staged").unwrap();
        let (device, inode) = file_identity_numbers(&temporary).unwrap();
        let journal_dir = work.join(&transaction_id);
        fs::create_dir(&journal_dir).unwrap();
        write_empty_sync(&journal_dir.join(format!("owner-{owner_token}"))).unwrap();
        write_json_sync(
            &journal_dir.join("transaction.json"),
            &BundleTransactionJournal {
                schema: 1,
                transaction_id,
                owner_token,
                entries: vec![BundleTransactionEntry {
                    target: target.clone(),
                    temporary: temporary.clone(),
                    device,
                    inode,
                    ready: true,
                    replacement: None,
                }],
            },
        )
        .unwrap();
        fs::rename(&temporary, &target).unwrap();

        recover_bundle_transactions(&work, &scripts, &games, &[&apps], &trash).unwrap();
        assert_eq!(fs::read(&target).unwrap(), b"staged");
        assert!(fs::read_dir(&work).unwrap().next().is_none());
    }

    #[test]
    fn crash_recovery_never_deletes_a_replacement_with_a_new_inode() {
        let temp = tempfile::tempdir().unwrap();
        let scripts = temp.path().join("scripts");
        let games = temp.path().join("games");
        let trash = temp.path().join("trash");
        let work = temp.path().join("work");
        for directory in [&scripts, &games, &trash, &work] {
            fs::create_dir(directory).unwrap();
        }
        let owner_token = "b".repeat(64);
        let transaction_id = format!("{BUNDLE_TRANSACTION_PREFIX}{owner_token}");
        let temporary = scripts.join(format!(".pam-install-stage-{transaction_id}-0-crash"));
        let target = scripts.join("crash.sh");
        fs::write(&temporary, b"staged").unwrap();
        let (device, inode) = file_identity_numbers(&temporary).unwrap();
        let journal_dir = work.join(&transaction_id);
        fs::create_dir(&journal_dir).unwrap();
        write_empty_sync(&journal_dir.join(format!("owner-{owner_token}"))).unwrap();
        write_json_sync(
            &journal_dir.join("transaction.json"),
            &BundleTransactionJournal {
                schema: 1,
                transaction_id,
                owner_token,
                entries: vec![BundleTransactionEntry {
                    target: target.clone(),
                    temporary: temporary.clone(),
                    device,
                    inode,
                    ready: true,
                    replacement: None,
                }],
            },
        )
        .unwrap();
        fs::rename(&temporary, &target).unwrap();
        fs::rename(&target, scripts.join("holding-old-inode")).unwrap();
        fs::write(&target, b"replacement").unwrap();

        recover_bundle_transactions(&work, &scripts, &games, &[], &trash).unwrap();
        assert_eq!(fs::read(&target).unwrap(), b"replacement");
        assert!(!journal_dir.exists());
    }

    #[test]
    fn crash_recovery_rolls_forward_ready_targets_without_deleting_live_paths() {
        let temp = tempfile::tempdir().unwrap();
        let scripts = temp.path().join("scripts");
        let games = temp.path().join("games");
        let trash = temp.path().join("trash");
        let work = temp.path().join("work");
        for directory in [&scripts, &games, &trash, &work] {
            fs::create_dir(directory).unwrap();
        }
        let owner_token = "c".repeat(64);
        let transaction_id = format!("{BUNDLE_TRANSACTION_PREFIX}{owner_token}");
        let directory_temp = games.join(format!(".pam-install-stage-{transaction_id}-0-crash"));
        let directory_target = games.join("game");
        fs::create_dir(&directory_temp).unwrap();
        write_empty_sync(&owner_marker(&directory_temp, &owner_token)).unwrap();
        fs::write(directory_temp.join("data"), b"data").unwrap();
        let (directory_device, directory_inode) = file_identity_numbers(&directory_temp).unwrap();
        let file_temp = scripts.join(format!(".pam-install-stage-{transaction_id}-1-crash"));
        fs::write(&file_temp, b"launcher").unwrap();
        let (file_device, file_inode) = file_identity_numbers(&file_temp).unwrap();
        let journal_dir = work.join(&transaction_id);
        fs::create_dir(&journal_dir).unwrap();
        write_empty_sync(&journal_dir.join(format!("owner-{owner_token}"))).unwrap();
        write_json_sync(
            &journal_dir.join("transaction.json"),
            &BundleTransactionJournal {
                schema: 1,
                transaction_id,
                owner_token,
                entries: vec![
                    BundleTransactionEntry {
                        target: directory_target.clone(),
                        temporary: directory_temp.clone(),
                        device: directory_device,
                        inode: directory_inode,
                        ready: true,
                        replacement: None,
                    },
                    BundleTransactionEntry {
                        target: scripts.join("game.sh"),
                        temporary: file_temp.clone(),
                        device: file_device,
                        inode: file_inode,
                        ready: true,
                        replacement: None,
                    },
                ],
            },
        )
        .unwrap();
        fs::rename(&directory_temp, &directory_target).unwrap();

        recover_bundle_transactions(&work, &scripts, &games, &[], &trash).unwrap();
        assert_eq!(fs::read(directory_target.join("data")).unwrap(), b"data");
        assert!(!file_temp.exists());
        assert_eq!(fs::read(scripts.join("game.sh")).unwrap(), b"launcher");
        assert!(!journal_dir.exists());
    }

    #[test]
    fn forged_journal_cannot_delete_or_modify_an_existing_victim_directory() {
        let temp = tempfile::tempdir().unwrap();
        let scripts = temp.path().join("scripts");
        let games = temp.path().join("games");
        let trash = temp.path().join("trash");
        let work = temp.path().join("work");
        for directory in [&scripts, &games, &trash, &work] {
            fs::create_dir(directory).unwrap();
        }
        let owner_token = "9".repeat(64);
        let transaction_id = format!("{BUNDLE_TRANSACTION_PREFIX}{owner_token}");
        let victim = games.join("victim");
        fs::create_dir(&victim).unwrap();
        fs::write(victim.join("precious"), b"keep").unwrap();
        write_empty_sync(&owner_marker(&victim, &owner_token)).unwrap();
        let (device, inode) = file_identity_numbers(&victim).unwrap();
        let journal_dir = work.join(&transaction_id);
        fs::create_dir(&journal_dir).unwrap();
        write_empty_sync(&journal_dir.join(format!("owner-{owner_token}"))).unwrap();
        write_json_sync(
            &journal_dir.join("transaction.json"),
            &BundleTransactionJournal {
                schema: 1,
                transaction_id: transaction_id.clone(),
                owner_token: owner_token.clone(),
                entries: vec![
                    BundleTransactionEntry {
                        target: victim.clone(),
                        temporary: games
                            .join(format!(".pam-install-stage-{transaction_id}-0-forged")),
                        device,
                        inode,
                        ready: true,
                        replacement: None,
                    },
                    BundleTransactionEntry {
                        target: scripts.join("missing.sh"),
                        temporary: scripts
                            .join(format!(".pam-install-stage-{transaction_id}-1-forged")),
                        device: 1,
                        inode: 1,
                        ready: false,
                        replacement: None,
                    },
                ],
            },
        )
        .unwrap();

        recover_bundle_transactions(&work, &scripts, &games, &[], &trash).unwrap();
        assert_eq!(fs::read(victim.join("precious")).unwrap(), b"keep");
        assert!(owner_marker(&victim, &owner_token).is_file());
        assert!(!journal_dir.exists());
    }

    #[test]
    #[ignore = "spawned by crash_recovery_survives_real_process_exit"]
    fn crash_fixture_process() {
        let root = PathBuf::from(std::env::var_os("PAM_TEST_BUNDLE_CRASH_ROOT").unwrap());
        let trash = std::env::var_os("PAM_TEST_BUNDLE_CRASH_TRASH")
            .map(PathBuf::from)
            .unwrap_or_else(|| root.join("trash"));
        let zip = root.join("game.zip");
        let candidate = inspect_zip_bundle(&zip, &no_cancel()).unwrap();
        let result = install_bundle(
            &candidate,
            &root.join("scripts"),
            &root.join("games"),
            &[],
            &trash,
            &root.join("work"),
            &BundleLimits::default(),
            &no_cancel(),
        );
        panic!("crash failpoint did not exit the process: {result:?}");
    }

    #[test]
    fn crash_recovery_survives_real_process_exit() {
        for point in ["after-extract", "after-target-copy", "after-first-publish"] {
            let temp = tempfile::tempdir().unwrap();
            make_zip(
                &temp,
                "game.zip",
                &[
                    ("game.sh", false, b"#!/bin/sh\nGAMEDIR=/ports/game\n"),
                    ("game/data.bin", false, b"data"),
                ],
            );
            for root in ["scripts", "games", "trash", "work"] {
                fs::create_dir(temp.path().join(root)).unwrap();
            }
            let status = std::process::Command::new(current_test_executable())
                .args([
                    "--exact",
                    "port_zip::tests::crash_fixture_process",
                    "--ignored",
                    "--nocapture",
                ])
                .env("PAM_TEST_BUNDLE_CRASH_ROOT", temp.path())
                .env("PAM_TEST_BUNDLE_CRASH_POINT", point)
                .status()
                .unwrap();
            assert_eq!(status.code(), Some(86), "failpoint {point}");
            if point == "after-target-copy" {
                fs::write(temp.path().join("scripts/game.sh"), b"late occupant").unwrap();
            }
            assert!(
                temp.path()
                    .join("work")
                    .read_dir()
                    .unwrap()
                    .next()
                    .is_some()
            );

            recover_bundle_transactions(
                &temp.path().join("work"),
                &temp.path().join("scripts"),
                &temp.path().join("games"),
                &[],
                &temp.path().join("trash"),
            )
            .unwrap();
            assert!(
                temp.path()
                    .join("work")
                    .read_dir()
                    .unwrap()
                    .next()
                    .is_none()
            );
            if point == "after-extract" {
                assert!(
                    temp.path()
                        .join("scripts")
                        .read_dir()
                        .unwrap()
                        .next()
                        .is_none()
                );
                assert!(
                    temp.path()
                        .join("games")
                        .read_dir()
                        .unwrap()
                        .next()
                        .is_none()
                );
            } else if point == "after-target-copy" {
                assert_eq!(
                    fs::read(temp.path().join("scripts/game.sh")).unwrap(),
                    b"late occupant"
                );
                assert!(temp.path().join("games/game/data.bin").is_file());
            } else {
                assert!(temp.path().join("scripts/game.sh").is_file());
                assert!(temp.path().join("games/game/data.bin").is_file());
            }
            assert!(temp.path().join("game.zip").is_file());
        }
    }

    #[cfg(unix)]
    #[test]
    fn crash_recovery_never_overwrites_a_dangling_target_symlink() {
        let temp = tempfile::tempdir().unwrap();
        let scripts = temp.path().join("scripts");
        let games = temp.path().join("games");
        let trash = temp.path().join("trash");
        let work = temp.path().join("work");
        for directory in [&scripts, &games, &trash, &work] {
            fs::create_dir(directory).unwrap();
        }
        let owner_token = "8".repeat(64);
        let transaction_id = format!("{BUNDLE_TRANSACTION_PREFIX}{owner_token}");
        let temporary = scripts.join(format!(".pam-install-stage-{transaction_id}-0-crash"));
        let target = scripts.join("game.sh");
        fs::write(&temporary, b"staged launcher").unwrap();
        let (device, inode) = file_identity_numbers(&temporary).unwrap();
        std::os::unix::fs::symlink("missing-launcher", &target).unwrap();
        let journal_dir = work.join(&transaction_id);
        fs::create_dir(&journal_dir).unwrap();
        write_empty_sync(&journal_dir.join(format!("owner-{owner_token}"))).unwrap();
        write_json_sync(
            &journal_dir.join("transaction.json"),
            &BundleTransactionJournal {
                schema: 1,
                transaction_id,
                owner_token,
                entries: vec![BundleTransactionEntry {
                    target: target.clone(),
                    temporary: temporary.clone(),
                    device,
                    inode,
                    ready: true,
                    replacement: None,
                }],
            },
        )
        .unwrap();

        recover_bundle_transactions(&work, &scripts, &games, &[], &trash).unwrap();

        assert!(
            fs::symlink_metadata(&target)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(
            fs::read_link(&target).unwrap(),
            PathBuf::from("missing-launcher")
        );
        assert!(!temporary.exists());
        assert!(!journal_dir.exists());
    }

    #[test]
    fn crash_recovery_finishes_a_confirmed_directory_replacement() {
        let temp = tempfile::tempdir().unwrap();
        let scripts = temp.path().join("scripts");
        let games = temp.path().join("games");
        let trash = temp.path().join("trash");
        let work = temp.path().join("work");
        for directory in [&scripts, &games, &trash, &work] {
            fs::create_dir(directory).unwrap();
        }
        let owner_token = "7".repeat(64);
        let transaction_id = format!("{BUNDLE_TRANSACTION_PREFIX}{owner_token}");
        let target = games.join("game-data");
        let temporary = games.join(format!(".pam-install-stage-{transaction_id}-0-crash"));
        let backup = games.join(format!(".pam-install-replaced-{transaction_id}-0"));
        fs::create_dir(&target).unwrap();
        fs::write(target.join("version"), b"old").unwrap();
        let (old_device, old_inode) = file_identity_numbers(&target).unwrap();
        rename_without_overwrite(&target, &backup).unwrap();
        fs::create_dir(&temporary).unwrap();
        fs::write(temporary.join("version"), b"new").unwrap();
        write_empty_sync(&owner_marker(&temporary, &owner_token)).unwrap();
        let (device, inode) = file_identity_numbers(&temporary).unwrap();
        let journal_dir = work.join(&transaction_id);
        fs::create_dir(&journal_dir).unwrap();
        write_empty_sync(&journal_dir.join(format!("owner-{owner_token}"))).unwrap();
        write_json_sync(
            &journal_dir.join("transaction.json"),
            &BundleTransactionJournal {
                schema: 1,
                transaction_id,
                owner_token,
                entries: vec![BundleTransactionEntry {
                    target: target.clone(),
                    temporary,
                    device,
                    inode,
                    ready: true,
                    replacement: Some(BundleReplacement {
                        backup: backup.clone(),
                        device: old_device,
                        inode: old_inode,
                    }),
                }],
            },
        )
        .unwrap();

        recover_bundle_transactions(&work, &scripts, &games, &[], &trash).unwrap();

        assert_eq!(fs::read(target.join("version")).unwrap(), b"new");
        assert!(!backup.exists());
        assert!(!journal_dir.exists());
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn cross_filesystem_retirement_recovers_real_process_exit() {
        for point in [
            "after-retire-journal",
            "after-source-detach",
            "after-source-unlink",
        ] {
            let temp = tempfile::tempdir().unwrap();
            let Ok(trash) = tempfile::Builder::new()
                .prefix("pam-cross-crash-")
                .tempdir_in("/dev/shm")
            else {
                return;
            };
            if filesystem_id(temp.path()) == filesystem_id(trash.path()) {
                return;
            }
            make_zip(
                &temp,
                "game.zip",
                &[
                    ("game.sh", false, b"#!/bin/sh\nGAMEDIR=/ports/game\n"),
                    ("game/data.bin", false, b"data"),
                ],
            );
            for root in ["scripts", "games", "work"] {
                fs::create_dir(temp.path().join(root)).unwrap();
            }
            let status = std::process::Command::new(current_test_executable())
                .args([
                    "--exact",
                    "port_zip::tests::crash_fixture_process",
                    "--ignored",
                    "--nocapture",
                ])
                .env("PAM_TEST_BUNDLE_CRASH_ROOT", temp.path())
                .env("PAM_TEST_BUNDLE_CRASH_TRASH", trash.path())
                .env("PAM_TEST_BUNDLE_CRASH_POINT", point)
                .status()
                .unwrap();
            assert_eq!(status.code(), Some(86), "failpoint {point}");

            if point != "after-retire-journal" {
                // A watcher or a second upload may reuse the original pathname
                // before recovery. That replacement is never part of this
                // transaction and must survive both interrupted states.
                fs::write(temp.path().join("game.zip"), b"replacement").unwrap();
            }

            recover_bundle_transactions(
                &temp.path().join("work"),
                &temp.path().join("scripts"),
                &temp.path().join("games"),
                &[],
                trash.path(),
            )
            .unwrap();
            if point == "after-retire-journal" {
                assert!(temp.path().join("game.zip").is_file());
            } else {
                assert_eq!(
                    fs::read(temp.path().join("game.zip")).unwrap(),
                    b"replacement"
                );
            }
            assert!(temp.path().join("scripts/game.sh").is_file());
            assert!(temp.path().join("games/game/data.bin").is_file());
            let batches = fs::read_dir(trash.path())
                .unwrap()
                .map(Result::unwrap)
                .collect::<Vec<_>>();
            if point == "after-retire-journal" {
                assert!(batches.is_empty());
            } else {
                assert_eq!(batches.len(), 1);
                assert!(batches[0].path().join("game.zip").is_file());
            }
        }
    }

    #[test]
    fn stale_partial_cross_filesystem_retirement_is_swept_safely() {
        let temp = tempfile::tempdir().unwrap();
        let trash = temp.path().join("trash");
        let work = temp.path().join("work");
        let scripts = temp.path().join("scripts");
        let games = temp.path().join("games");
        for directory in [&trash, &work, &scripts, &games] {
            fs::create_dir(directory).unwrap();
        }
        let token = "d".repeat(64);
        let partial = trash.join(format!("{PARTIAL_RETIRE_PREFIX}{token}"));
        fs::create_dir(&partial).unwrap();
        write_empty_sync(&partial.join(format!("owner-{token}"))).unwrap();
        fs::write(partial.join("bundle.zip"), b"partial").unwrap();
        recover_bundle_transactions(&work, &scripts, &games, &[], &trash).unwrap();
        assert!(!partial.exists());
    }

    #[test]
    fn ownerless_prepublication_directories_do_not_block_recovery() {
        let temp = tempfile::tempdir().unwrap();
        let trash = temp.path().join("trash");
        let work = temp.path().join("work");
        let scripts = temp.path().join("scripts");
        let games = temp.path().join("games");
        for directory in [&trash, &work, &scripts, &games] {
            fs::create_dir(directory).unwrap();
        }
        let token = "f".repeat(64);
        let transaction = work.join(format!("{BUNDLE_TRANSACTION_PREFIX}{token}"));
        fs::create_dir(&transaction).unwrap();
        let retirement = trash.join(format!("{PARTIAL_RETIRE_PREFIX}{token}"));
        fs::create_dir(&retirement).unwrap();

        recover_bundle_transactions(&work, &scripts, &games, &[], &trash).unwrap();
        assert!(!transaction.exists());
        assert!(!retirement.exists());
    }

    #[test]
    fn retirement_never_consumes_a_replacement_at_the_same_path() {
        let temp = tempfile::tempdir().unwrap();
        let trash = temp.path().join("trash");
        fs::create_dir(&trash).unwrap();
        let source = temp.path().join("bundle.zip");
        fs::write(&source, b"original").unwrap();
        let mut open = open_archive(&source).unwrap();
        let identity = SourceIdentity::from_file(&open).unwrap();
        fs::rename(&source, temp.path().join("original-away.zip")).unwrap();
        fs::write(&source, b"replacement").unwrap();

        let error = retire_local_bundle(&source, &mut open, &trash, &identity).unwrap_err();
        assert!(error.contains("changed") || error.contains("replaced"));
        assert_eq!(fs::read(&source).unwrap(), b"replacement");
        assert!(fs::read_dir(&trash).unwrap().next().is_none());
    }

    #[test]
    fn same_filesystem_rollback_preserves_a_captured_file_when_source_is_occupied() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("bundle.zip");
        let batch = temp.path().join("trash-batch");
        fs::create_dir(&batch).unwrap();
        let destination = batch.join("bundle.zip");
        fs::write(&source, b"new source occupant").unwrap();
        fs::write(&destination, b"captured unrelated file").unwrap();
        let mut guard = RetireGuard {
            path: batch.clone(),
            cleanup: true,
        };

        preserve_or_restore_acquired_source(&source, &destination, &mut guard);
        drop(guard);

        assert_eq!(fs::read(&source).unwrap(), b"new source occupant");
        assert_eq!(fs::read(&destination).unwrap(), b"captured unrelated file");
    }

    #[cfg(unix)]
    #[test]
    fn same_filesystem_rollback_never_overwrites_a_dangling_symlink() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("bundle.zip");
        let batch = temp.path().join("trash-batch");
        fs::create_dir(&batch).unwrap();
        let destination = batch.join("bundle.zip");
        std::os::unix::fs::symlink("missing-target", &source).unwrap();
        fs::write(&destination, b"captured unrelated file").unwrap();
        let mut guard = RetireGuard {
            path: batch.clone(),
            cleanup: true,
        };

        preserve_or_restore_acquired_source(&source, &destination, &mut guard);
        drop(guard);

        assert!(
            fs::symlink_metadata(&source)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(
            fs::read_link(&source).unwrap(),
            PathBuf::from("missing-target")
        );
        assert_eq!(fs::read(&destination).unwrap(), b"captured unrelated file");
    }

    #[test]
    fn same_filesystem_rollback_restores_without_an_overwrite_window() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("bundle.zip");
        let batch = temp.path().join("trash-batch");
        fs::create_dir(&batch).unwrap();
        let destination = batch.join("bundle.zip");
        fs::write(&destination, b"captured file").unwrap();
        let mut guard = RetireGuard {
            path: batch.clone(),
            cleanup: true,
        };

        preserve_or_restore_acquired_source(&source, &destination, &mut guard);
        drop(guard);

        assert_eq!(fs::read(&source).unwrap(), b"captured file");
        assert!(!batch.exists());
    }

    #[test]
    fn source_acquisition_refuses_an_occupied_quarantine_name() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("bundle.zip");
        let detached = temp.path().join(".pam-source-v1-occupied");
        fs::write(&source, b"original").unwrap();
        fs::write(&detached, b"occupant").unwrap();
        let identity = SourceIdentity::from_file(&open_archive(&source).unwrap()).unwrap();

        assert!(detach_source_to(&source, &detached, &identity).is_err());
        assert_eq!(fs::read(&source).unwrap(), b"original");
        assert_eq!(fs::read(&detached).unwrap(), b"occupant");
    }

    #[cfg(unix)]
    #[test]
    fn source_acquisition_never_overwrites_a_dangling_quarantine_symlink() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("bundle.zip");
        let detached = temp.path().join(".pam-source-v1-occupied");
        fs::write(&source, b"original").unwrap();
        std::os::unix::fs::symlink("missing-target", &detached).unwrap();
        let identity = SourceIdentity::from_file(&open_archive(&source).unwrap()).unwrap();

        assert!(detach_source_to(&source, &detached, &identity).is_err());
        assert_eq!(fs::read(&source).unwrap(), b"original");
        assert!(
            fs::symlink_metadata(&detached)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(
            fs::read_link(&detached).unwrap(),
            PathBuf::from("missing-target")
        );
    }

    #[test]
    fn retirement_recovery_publishes_original_copy_beside_source_replacement() {
        let temp = tempfile::tempdir().unwrap();
        let trash = temp.path().join("trash");
        fs::create_dir(&trash).unwrap();
        let source = temp.path().join("game.zip");
        fs::write(&source, b"original bundle").unwrap();
        let open = open_archive(&source).unwrap();
        let identity = SourceIdentity::from_file(&open).unwrap();
        let token = "e".repeat(64);
        let partial = trash.join(format!("{PARTIAL_RETIRE_PREFIX}{token}"));
        fs::create_dir(&partial).unwrap();
        write_empty_sync(&partial.join(format!("owner-{token}"))).unwrap();
        fs::write(partial.join("game.zip"), b"original bundle").unwrap();
        let detached = temp.path().join(format!(".pam-source-v1-{token}"));
        let final_batch = trash.join(format!("zip-{token}"));
        let journal = RetireTransactionJournal {
            schema: 1,
            token: token.clone(),
            source: source.clone(),
            detached,
            final_batch: final_batch.clone(),
            identity,
        };
        write_json_sync(&partial.join("retire.json"), &journal).unwrap();
        fs::remove_file(&source).unwrap();
        fs::write(&source, b"replacement bundle").unwrap();

        recover_retire_transaction(&trash, &partial, &token, &journal).unwrap();

        assert_eq!(fs::read(&source).unwrap(), b"replacement bundle");
        assert_eq!(
            fs::read(final_batch.join("game.zip")).unwrap(),
            b"original bundle"
        );
        assert!(!final_batch.join("retire.json").exists());
    }

    #[test]
    fn install_rejects_a_same_path_replacement_after_scan() {
        let temp = tempfile::tempdir().unwrap();
        let path = make_zip(
            &temp,
            "game.zip",
            &[
                ("game.sh", false, b"GAMEDIR=/ports/game\nold"),
                ("game/data", false, b"old"),
            ],
        );
        let candidate = inspect_zip_bundle(&path, &no_cancel()).unwrap();
        fs::rename(&path, temp.path().join("old.zip")).unwrap();
        make_zip(
            &temp,
            "game.zip",
            &[
                ("game.sh", false, b"GAMEDIR=/ports/game\nnew"),
                ("game/data", false, b"new"),
            ],
        );
        let scripts = temp.path().join("scripts");
        let games = temp.path().join("games");
        let apps = temp.path().join("apps");
        let trash = temp.path().join("trash");
        let work = temp.path().join("work");
        for root in [&scripts, &games, &apps, &trash, &work] {
            fs::create_dir(root).unwrap();
        }

        let error = install_bundle(
            &candidate,
            &scripts,
            &games,
            &[&apps],
            &trash,
            &work,
            &BundleLimits::default(),
            &no_cancel(),
        )
        .unwrap_err();
        assert!(error.contains("changed after it was scanned"));
        assert!(scripts.read_dir().unwrap().next().is_none());
        assert!(games.read_dir().unwrap().next().is_none());
        assert!(path.exists());
    }

    #[test]
    fn live_commit_never_overwrites_a_target_created_during_staging() {
        use std::sync::atomic::{AtomicBool, Ordering};

        let temp = tempfile::tempdir().unwrap();
        let path = make_zip(
            &temp,
            "game.zip",
            &[
                ("game.sh", false, b"#!/bin/sh\nGAMEDIR=/ports/game\n"),
                ("game/data", false, b"data"),
            ],
        );
        let candidate = inspect_zip_bundle(&path, &no_cancel()).unwrap();
        let scripts = temp.path().join("scripts");
        let games = temp.path().join("games");
        let trash = temp.path().join("trash");
        let work = temp.path().join("work");
        for root in [&scripts, &games, &trash, &work] {
            fs::create_dir(root).unwrap();
        }
        let inserted = AtomicBool::new(false);
        let insert_during_staging = || {
            if !inserted.load(Ordering::Relaxed)
                && scripts.read_dir().is_ok_and(|entries| {
                    entries.filter_map(Result::ok).any(|entry| {
                        entry
                            .file_name()
                            .to_string_lossy()
                            .starts_with(".pam-install-stage-")
                    })
                })
                && games.read_dir().is_ok_and(|entries| {
                    entries.filter_map(Result::ok).any(|entry| {
                        entry
                            .file_name()
                            .to_string_lossy()
                            .starts_with(".pam-install-stage-")
                    })
                })
            {
                fs::write(scripts.join("game.sh"), b"late occupant").unwrap();
                inserted.store(true, Ordering::Relaxed);
            }
            false
        };

        let error = install_bundle(
            &candidate,
            &scripts,
            &games,
            &[],
            &trash,
            &work,
            &BundleLimits::default(),
            &insert_during_staging,
        )
        .unwrap_err();

        assert!(inserted.load(Ordering::Relaxed));
        assert!(error.contains("without replacing another entry"));
        assert_eq!(fs::read(scripts.join("game.sh")).unwrap(), b"late occupant");
        assert!(!games.join("game").exists());
        assert!(path.exists());
        assert!(work.read_dir().unwrap().next().is_none());
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn cross_filesystem_retirement_copies_publishes_then_removes_source() {
        let source_root = tempfile::tempdir().unwrap();
        let Ok(trash_root) = tempfile::Builder::new()
            .prefix("pam-cross-fs-")
            .tempdir_in("/dev/shm")
        else {
            return;
        };
        if filesystem_id(source_root.path()) == filesystem_id(trash_root.path()) {
            return;
        }
        let source = source_root.path().join("bundle.zip");
        fs::write(&source, b"archive bytes").unwrap();
        let mut open = open_archive(&source).unwrap();
        let identity = SourceIdentity::from_file(&open).unwrap();

        retire_local_bundle(&source, &mut open, trash_root.path(), &identity).unwrap();

        assert!(!source.exists());
        let batches = fs::read_dir(trash_root.path())
            .unwrap()
            .map(Result::unwrap)
            .collect::<Vec<_>>();
        assert_eq!(batches.len(), 1);
        assert_eq!(
            fs::read(batches[0].path().join("bundle.zip")).unwrap(),
            b"archive bytes"
        );
    }
}

/// Safety limits for bundle extraction (zip-slip and zip-bomb protection).
pub struct BundleLimits {
    pub entries: usize,
    pub entry_bytes: u64,
    pub total_bytes: u64,
}

impl Default for BundleLimits {
    fn default() -> Self {
        Self {
            entries: 4096,
            // Remote installs commonly contain one large game data file. Keep
            // hard zip-bomb limits, but allow the advertised 1-2 GiB bundles.
            entry_bytes: 4 * 1024 * 1024 * 1024,
            total_bytes: 8 * 1024 * 1024 * 1024,
        }
    }
}

/// Result of installing one recognized zip bundle.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct BundleInstallOutcome {
    pub installed: Vec<String>,
    pub conflicts: Vec<String>,
}

/// Extract a bundle with the same safety rules as the PortMaster installer
/// (no path traversal, no archive bombs) into `work`, then move the pieces to
/// their platform destinations. `kind`/`entry_*`/`app_name` come from the
/// recognition step; the caller resolves scripts/game_dirs and the single
/// typed APP install target from platform config. The original zip is moved
/// to `trash` on success.
#[allow(clippy::too_many_arguments)]
pub fn install_bundle(
    bundle: &ZipCandidate,
    scripts_dir: &Path,
    game_dirs: &Path,
    app_install_targets: &[&Path],
    trash_dir: &Path,
    work: &Path,
    limits: &BundleLimits,
    cancel: &dyn Fn() -> bool,
) -> Result<BundleInstallOutcome, String> {
    install_bundle_replacing(
        bundle,
        scripts_dir,
        game_dirs,
        app_install_targets,
        trash_dir,
        work,
        limits,
        false,
        cancel,
    )
}

/// Install a local bundle, optionally replacing an existing APP/data directory.
/// Launcher files are never replaced: duplicate SH names always receive a
/// numeric suffix.
#[allow(clippy::too_many_arguments)]
pub fn install_bundle_replacing(
    bundle: &ZipCandidate,
    scripts_dir: &Path,
    game_dirs: &Path,
    app_install_targets: &[&Path],
    trash_dir: &Path,
    work: &Path,
    limits: &BundleLimits,
    replace_existing: bool,
    cancel: &dyn Fn() -> bool,
) -> Result<BundleInstallOutcome, String> {
    install_bundle_replacing_with_password(
        bundle,
        scripts_dir,
        game_dirs,
        app_install_targets,
        trash_dir,
        work,
        limits,
        replace_existing,
        None,
        cancel,
    )
}

/// Password-aware local archive installation.
#[allow(clippy::too_many_arguments)]
pub fn install_bundle_replacing_with_password(
    bundle: &ZipCandidate,
    scripts_dir: &Path,
    game_dirs: &Path,
    app_install_targets: &[&Path],
    trash_dir: &Path,
    work: &Path,
    limits: &BundleLimits,
    replace_existing: bool,
    password: Option<&str>,
    cancel: &dyn Fn() -> bool,
) -> Result<BundleInstallOutcome, String> {
    install_bundle_with_source(
        bundle,
        scripts_dir,
        game_dirs,
        app_install_targets,
        trash_dir,
        work,
        limits,
        true,
        replace_existing,
        password,
        cancel,
    )
}

/// Install a bundle received as a remote upload. The uploaded archive is a
/// disposable transport copy, so a successful install removes it instead of
/// consuming the same space again in Trash.
#[allow(clippy::too_many_arguments)]
pub fn install_uploaded_bundle(
    bundle: &ZipCandidate,
    scripts_dir: &Path,
    game_dirs: &Path,
    app_install_targets: &[&Path],
    trash_dir: &Path,
    work: &Path,
    limits: &BundleLimits,
    cancel: &dyn Fn() -> bool,
) -> Result<BundleInstallOutcome, String> {
    install_uploaded_bundle_replacing(
        bundle,
        scripts_dir,
        game_dirs,
        app_install_targets,
        trash_dir,
        work,
        limits,
        false,
        cancel,
    )
}

/// Install an uploaded bundle with an explicit pre-upload overwrite choice.
#[allow(clippy::too_many_arguments)]
pub fn install_uploaded_bundle_replacing(
    bundle: &ZipCandidate,
    scripts_dir: &Path,
    game_dirs: &Path,
    app_install_targets: &[&Path],
    trash_dir: &Path,
    work: &Path,
    limits: &BundleLimits,
    replace_existing: bool,
    cancel: &dyn Fn() -> bool,
) -> Result<BundleInstallOutcome, String> {
    install_uploaded_bundle_replacing_with_password(
        bundle,
        scripts_dir,
        game_dirs,
        app_install_targets,
        trash_dir,
        work,
        limits,
        replace_existing,
        None,
        cancel,
    )
}

/// Password-aware remote archive installation.
#[allow(clippy::too_many_arguments)]
pub fn install_uploaded_bundle_replacing_with_password(
    bundle: &ZipCandidate,
    scripts_dir: &Path,
    game_dirs: &Path,
    app_install_targets: &[&Path],
    trash_dir: &Path,
    work: &Path,
    limits: &BundleLimits,
    replace_existing: bool,
    password: Option<&str>,
    cancel: &dyn Fn() -> bool,
) -> Result<BundleInstallOutcome, String> {
    install_bundle_with_source(
        bundle,
        scripts_dir,
        game_dirs,
        app_install_targets,
        trash_dir,
        work,
        limits,
        false,
        replace_existing,
        password,
        cancel,
    )
}

fn next_port_launcher_target(scripts_dir: &Path, entry_script: &str) -> Result<PathBuf, String> {
    let file_name = Path::new(entry_script)
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| "Port launcher has no valid UTF-8 file name".to_owned())?;
    let stem = file_name
        .strip_suffix(".sh")
        .ok_or_else(|| "Port launcher file name must end in .sh".to_owned())?;
    let original = scripts_dir.join(file_name);
    if !path_entry_exists(&original) {
        return Ok(original);
    }
    for suffix in 1..=u32::MAX {
        let candidate = scripts_dir.join(format!("{stem}{suffix}.sh"));
        if !path_entry_exists(&candidate) {
            return Ok(candidate);
        }
    }
    Err(format!(
        "cannot allocate a unique launcher name for {file_name}"
    ))
}

#[allow(clippy::too_many_arguments)]
fn install_bundle_with_source(
    bundle: &ZipCandidate,
    scripts_dir: &Path,
    game_dirs: &Path,
    app_install_targets: &[&Path],
    trash_dir: &Path,
    work: &Path,
    limits: &BundleLimits,
    retire_source: bool,
    replace_existing: bool,
    password: Option<&str>,
    cancel: &dyn Fn() -> bool,
) -> Result<BundleInstallOutcome, String> {
    check_cancelled(cancel)?;
    fs::create_dir_all(work).map_err(|error| format!("create work root: {error}"))?;
    recover_bundle_transactions(work, scripts_dir, game_dirs, app_install_targets, trash_dir)?;
    let source_path = Path::new(&bundle.path);
    let mut source = open_archive(source_path)?;
    let source_identity = SourceIdentity::from_file(&source)?;
    if source_identity.token() != bundle.source_identity {
        return Err("archive changed after it was scanned; please scan it again".to_owned());
    }
    let (recognized, catalog) =
        recognize_archive_file(&mut source, &bundle.path, password, cancel)?;
    if catalog.format.name() != bundle.format && !bundle.format.is_empty() {
        return Err("archive changed after it was scanned; please scan it again".to_owned());
    }
    let unlocks_classification = bundle.kind == "locked" && bundle.password_required;
    if !unlocks_classification
        && (recognized.kind.name() != bundle.kind
            || recognized.entry_script != bundle.entry_script
            || recognized.entry_data != bundle.entry_data
            || recognized.app_name != bundle.app_name)
    {
        return Err("压缩包在扫描后发生了变化，请重新扫描".to_owned());
    }
    let expanded_bytes =
        validate_archive_file(&mut source, &bundle.path, limits, password, cancel)?;
    let mut port_script_target = None;
    let intended_targets = match recognized.kind.name() {
        "trimui_app" => {
            let [app_install_target] = app_install_targets else {
                return Err(
                    "device configuration must resolve exactly one APP install target".into(),
                );
            };
            vec![app_install_target.join(&recognized.app_name)]
        }
        "port" => {
            let script_target = next_port_launcher_target(scripts_dir, &recognized.entry_script)?;
            port_script_target = Some(script_target.clone());
            let mut targets = vec![script_target];
            if !recognized.entry_data.is_empty() {
                let data_name = Path::new(&recognized.entry_data)
                    .file_name()
                    .ok_or_else(|| "Port data folder has no name".to_owned())?;
                targets.push(game_dirs.join(data_name));
            }
            targets
        }
        _ => return Err("无法识别这个压缩包，请确认文件完整且受支持".into()),
    };
    for target in &intended_targets {
        let parent = target
            .parent()
            .ok_or_else(|| format!("invalid install target: {}", target.display()))?;
        fs::create_dir_all(parent)
            .map_err(|error| format!("create install destination {}: {error}", parent.display()))?;
    }
    let conflicts = intended_targets
        .iter()
        .filter(|target| path_entry_exists(target))
        .map(|target| target.to_string_lossy().into_owned())
        .collect::<Vec<_>>();
    if !conflicts.is_empty() && !replace_existing {
        return Ok(BundleInstallOutcome {
            installed: Vec::new(),
            conflicts,
        });
    }
    ensure_available(
        work,
        expanded_bytes.saturating_add(INSTALL_SPACE_RESERVE),
        "解压安装包",
    )?;
    // The durable transaction exists before the first large extraction or
    // destination-side copy. Its stage lives inside the journal directory, so
    // a power loss cannot leak an unowned 1-2 GiB staging tree.
    let mut transaction = InstallTransaction::begin(work)?;
    let stage = transaction.stage().to_path_buf();
    extract_safe_file(&mut source, &bundle.path, &stage, password, cancel)?;
    test_crash_point("after-extract");

    let mut plan = Vec::new();
    match recognized.kind.name() {
        "trimui_app" => {
            let app_dir = stage
                .join(&recognized.entry_script)
                .parent()
                .map(Path::to_path_buf)
                .unwrap_or_else(|| stage.clone());
            let [app_install_target] = app_install_targets else {
                return Err(
                    "device configuration must resolve exactly one APP install target".into(),
                );
            };
            if !app_dir.is_dir() || !app_dir.join("launch.sh").is_file() {
                return Err("TrimUI APP launcher is missing from the archive".into());
            }
            plan.push(InstallTarget::directory(
                app_dir,
                app_install_target.join(&recognized.app_name),
                Some(PathBuf::from("launch.sh")),
            ));
        }
        "port" => {
            let script_src = stage.join(&recognized.entry_script);
            if !script_src.is_file() {
                return Err("Port launcher is missing from the archive".into());
            }
            let name = script_src
                .file_name()
                .ok_or_else(|| "Port launcher has no file name".to_owned())?
                .to_os_string();
            plan.push(InstallTarget::file(
                script_src,
                port_script_target
                    .take()
                    .ok_or_else(|| format!("Port launcher target was not resolved: {:?}", name))?,
                true,
            ));
            if !recognized.entry_data.is_empty() {
                let data_src = stage.join(&recognized.entry_data);
                if !data_src.is_dir() {
                    return Err("Port data folder is missing from the archive".into());
                }
                let name = data_src
                    .file_name()
                    .ok_or_else(|| "Port data folder has no name".to_owned())?
                    .to_os_string();
                plan.push(InstallTarget::directory(
                    data_src,
                    game_dirs.join(name),
                    None,
                ));
            }
        }
        _ => {
            return Err("无法识别这个压缩包，请确认文件完整且受支持".into());
        }
    }

    prepare_destination_parents(&plan)?;
    let conflicts = plan
        .iter()
        .filter(|item| path_entry_exists(&item.target))
        .map(|item| item.target.to_string_lossy().into_owned())
        .collect::<Vec<_>>();
    if !conflicts.is_empty() && !replace_existing {
        return Ok(BundleInstallOutcome {
            installed: Vec::new(),
            conflicts,
        });
    }

    preflight_destinations(&plan)?;
    for (index, item) in plan.iter().enumerate() {
        let parent = item
            .target
            .parent()
            .ok_or_else(|| format!("invalid install target: {}", item.target.display()))?;
        fs::create_dir_all(parent)
            .map_err(|error| format!("create install destination {}: {error}", parent.display()))?;
        let temporary =
            allocate_target(parent, transaction.transaction_id(), index, item.directory)?;
        transaction.register(item, temporary.clone())?;
        if item.directory {
            copy_tree(&item.source, &temporary, cancel)?;
        } else {
            copy_file(&item.source, &temporary, cancel)?;
        }
        if let Some(executable) = &item.executable {
            let executable = if executable.as_os_str().is_empty() {
                temporary.clone()
            } else {
                temporary.join(executable)
            };
            set_executable(&executable)?;
        }
        transaction.mark_ready(index)?;
    }
    test_crash_point("after-target-copy");

    // Cancellation is honored throughout validation/staging. Once commit
    // begins, the transaction must finish or roll back as one unit.
    check_cancelled(cancel)?;
    if replace_existing {
        for (index, item) in plan.iter().enumerate() {
            if path_entry_exists(&item.target) {
                if !item.replaceable {
                    return Err(format!(
                        "launcher target appeared during installation; rescan and retry: {}",
                        item.target.display()
                    ));
                }
                transaction.acquire_replacement(index)?;
            }
        }
    }
    // Publish directories first and the launcher file last. A launcher is the
    // activation point for a Port, so recovery can infer a fully published
    // transaction without ever deleting an unrelated live file from JSON.
    let mut publish_order = (0..plan.len()).collect::<Vec<_>>();
    publish_order.sort_by_key(|index| !plan[*index].directory);
    for index in publish_order {
        let item = &plan[index];
        let temporary = transaction.temporary(index).to_path_buf();
        rename_without_overwrite(&temporary, &item.target).map_err(|error| {
            format!(
                "commit install target without replacing another entry {}: {error}",
                item.target.display()
            )
        })?;
        sync_parent(&item.target)
            .map_err(|error| format!("sync install target {}: {error}", item.target.display()))?;
        transaction.committed.push(item.target.clone());
        if transaction.committed.len() == 1 {
            test_crash_point("after-first-publish");
        }
    }

    // A storage-card source goes to Trash so local one-tap install remains
    // reversible. A remote upload is only a transport copy and is discarded.
    if !retire_source {
        source_identity.verify_open_file(&source)?;
        let detached = detach_source(source_path, &source_identity)?;
        // The Web service owns the upload directory and sweeps every stale
        // regular transport (including this quarantine name) before it binds
        // the listener. A crash here therefore cannot leak an upload forever.
        test_crash_point("after-upload-detach");
        fs::remove_file(&detached)
            .map_err(|error| format!("remove uploaded bundle after install: {error}"))?;
        sync_parent(&detached).map_err(|error| format!("sync removed uploaded bundle: {error}"))?;
    } else {
        retire_local_bundle(source_path, &mut source, trash_dir, &source_identity)?;
    }
    transaction.commit()?;
    let installed = plan
        .iter()
        .map(|item| item.target.to_string_lossy().into_owned())
        .collect();
    transaction.keep_committed = true;
    Ok(BundleInstallOutcome {
        installed,
        conflicts: Vec::new(),
    })
}

#[cfg(test)]
fn test_crash_point(point: &str) {
    if std::env::var("PAM_TEST_BUNDLE_CRASH_POINT").as_deref() == Ok(point) {
        // `process::exit` intentionally skips every Drop implementation and
        // models the filesystem state a killed process leaves behind.
        std::process::exit(86);
    }
}

#[cfg(not(test))]
fn test_crash_point(_point: &str) {}

const INSTALL_SPACE_RESERVE: u64 = 64 * 1024 * 1024;

struct InstallTarget {
    source: PathBuf,
    target: PathBuf,
    directory: bool,
    executable: Option<PathBuf>,
    replaceable: bool,
}

impl InstallTarget {
    fn file(source: PathBuf, target: PathBuf, executable: bool) -> Self {
        Self {
            source,
            target,
            directory: false,
            executable: executable.then(PathBuf::new),
            replaceable: false,
        }
    }

    fn directory(source: PathBuf, target: PathBuf, executable: Option<PathBuf>) -> Self {
        Self {
            source,
            target,
            directory: true,
            executable,
            replaceable: true,
        }
    }
}

const BUNDLE_TRANSACTION_PREFIX: &str = ".pam-install-transaction-v1-";

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct BundleTransactionJournal {
    schema: u32,
    transaction_id: String,
    owner_token: String,
    entries: Vec<BundleTransactionEntry>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct BundleTransactionEntry {
    target: PathBuf,
    temporary: PathBuf,
    device: u64,
    inode: u64,
    ready: bool,
    #[serde(default)]
    replacement: Option<BundleReplacement>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct BundleReplacement {
    backup: PathBuf,
    device: u64,
    inode: u64,
}

struct InstallTransaction {
    transaction_id: String,
    owner_token: String,
    entries: Vec<BundleTransactionEntry>,
    committed: Vec<PathBuf>,
    keep_committed: bool,
    preserve_journal: bool,
    journal_dir: PathBuf,
    stage: PathBuf,
}

impl InstallTransaction {
    fn begin(work: &Path) -> Result<Self, String> {
        for _ in 0..128 {
            let owner_token = secure_random_hex()?;
            let transaction_id = format!("{BUNDLE_TRANSACTION_PREFIX}{owner_token}");
            let journal_dir = work.join(&transaction_id);
            match fs::create_dir(&journal_dir) {
                Ok(()) => {
                    write_empty_sync(&journal_dir.join(format!("owner-{owner_token}")))?;
                    let stage = journal_dir.join("stage");
                    fs::create_dir(&stage)
                        .map_err(|error| format!("create transaction stage: {error}"))?;
                    sync_parent(&stage)
                        .map_err(|error| format!("sync transaction stage: {error}"))?;
                    let transaction = Self {
                        transaction_id,
                        owner_token,
                        entries: Vec::new(),
                        committed: Vec::new(),
                        keep_committed: false,
                        preserve_journal: false,
                        journal_dir,
                        stage,
                    };
                    transaction.persist()?;
                    return Ok(transaction);
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(format!("create transaction directory: {error}")),
            }
        }
        Err("cannot allocate a bundle install transaction".to_owned())
    }

    fn persist(&self) -> Result<(), String> {
        let journal = BundleTransactionJournal {
            schema: 1,
            transaction_id: self.transaction_id.clone(),
            owner_token: self.owner_token.clone(),
            entries: self.entries.clone(),
        };
        write_json_replace_sync(&self.journal_dir.join("transaction.json"), &journal)
    }

    fn register(&mut self, item: &InstallTarget, temporary: PathBuf) -> Result<(), String> {
        if item.directory {
            write_empty_sync(
                &temporary.join(format!(".pam-install-owner-v1-{}", self.owner_token)),
            )?;
        }
        let (device, inode) = file_identity_numbers(&temporary)?;
        self.entries.push(BundleTransactionEntry {
            target: item.target.clone(),
            temporary,
            device,
            inode,
            ready: false,
            replacement: None,
        });
        self.persist()
    }

    fn acquire_replacement(&mut self, index: usize) -> Result<(), String> {
        let target = self.entries[index].target.clone();
        let parent = target
            .parent()
            .ok_or_else(|| format!("replacement target has no parent: {}", target.display()))?;
        let backup = parent.join(format!(
            ".pam-install-replaced-{}-{index}",
            self.transaction_id
        ));
        if path_entry_exists(&backup) {
            return Err(format!(
                "replacement backup already exists: {}",
                backup.display()
            ));
        }
        let (device, inode) = file_identity_numbers(&target)?;
        self.entries[index].replacement = Some(BundleReplacement {
            backup: backup.clone(),
            device,
            inode,
        });
        // Publish the intent before moving the only old copy.
        self.persist()?;
        rename_without_overwrite(&target, &backup).map_err(|error| {
            format!(
                "preserve existing install target {}: {error}",
                target.display()
            )
        })?;
        sync_parent(&target).map_err(|error| format!("sync preserved install target: {error}"))?;
        if !identity_matches(&backup, device, inode)? {
            self.preserve_journal = true;
            let _ = rename_without_overwrite(&backup, &target);
            return Err("install target changed while preparing replacement".to_owned());
        }
        Ok(())
    }

    fn mark_ready(&mut self, index: usize) -> Result<(), String> {
        self.entries[index].ready = true;
        self.persist()
    }

    fn stage(&self) -> &Path {
        &self.stage
    }

    fn transaction_id(&self) -> &str {
        &self.transaction_id
    }

    fn temporary(&self, index: usize) -> &Path {
        &self.entries[index].temporary
    }

    fn commit(&mut self) -> Result<(), String> {
        write_empty_sync(&self.journal_dir.join("committed"))?;
        self.keep_committed = true;
        for entry in &self.entries {
            if remove_owner_marker(&entry.target, &self.owner_token).is_err() {
                self.preserve_journal = true;
            }
            if let Some(old) = &entry.replacement
                && !remove_if_identity(&old.backup, old.device, old.inode).unwrap_or(false)
            {
                self.preserve_journal = true;
            }
        }
        Ok(())
    }
}

impl Drop for InstallTransaction {
    fn drop(&mut self) {
        let mut cleanup_complete = true;
        for entry in &self.entries {
            cleanup_complete &=
                remove_if_identity(&entry.temporary, entry.device, entry.inode).unwrap_or(false);
        }
        if !self.keep_committed {
            for entry in self.entries.iter().rev() {
                if identity_matches(&entry.target, entry.device, entry.inode).unwrap_or(false) {
                    cleanup_complete &=
                        remove_if_identity(&entry.target, entry.device, entry.inode)
                            .unwrap_or(false);
                }
                if let Some(old) = &entry.replacement
                    && identity_matches(&old.backup, old.device, old.inode).unwrap_or(false)
                {
                    match rename_without_overwrite(&old.backup, &entry.target) {
                        Ok(()) => {
                            cleanup_complete &= sync_parent(&entry.target).is_ok();
                        }
                        Err(_) => cleanup_complete = false,
                    }
                }
            }
        }
        if (self.keep_committed && !self.preserve_journal)
            || (!self.keep_committed && cleanup_complete)
        {
            let _ = fs::remove_dir_all(&self.journal_dir);
        }
    }
}

/// Recover any bundle transaction interrupted after one destination rename.
/// Journal entries are accepted only when every target is a direct child of a
/// currently configured install root and the on-disk inode is the one staged
/// by this transaction. A replaced or unrelated path is never removed.
pub fn recover_bundle_transactions(
    work: &Path,
    scripts_dir: &Path,
    game_dirs: &Path,
    app_install_targets: &[&Path],
    trash_dir: &Path,
) -> Result<(), String> {
    sweep_partial_retirements(trash_dir)?;
    let Ok(entries) = fs::read_dir(work) else {
        return Ok(());
    };
    let allowed_roots = std::iter::once(scripts_dir)
        .chain(std::iter::once(game_dirs))
        .chain(app_install_targets.iter().copied())
        .collect::<Vec<_>>();
    for entry in entries {
        let entry = entry.map_err(|error| format!("read transaction root: {error}"))?;
        let file_type = entry
            .file_type()
            .map_err(|error| format!("inspect transaction entry: {error}"))?;
        let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        if !file_type.is_dir() || !name.starts_with(BUNDLE_TRANSACTION_PREFIX) {
            continue;
        }
        let directory = entry.path();
        if !directory.join("transaction.json").is_file()
            && fs::read_dir(&directory)
                .map_err(|error| format!("inspect unstarted transaction: {error}"))?
                .all(|child| {
                    child.ok().is_some_and(|child| {
                        child.file_name() == "stage"
                            && child.file_type().is_ok_and(|file_type| file_type.is_dir())
                    })
                })
        {
            // create-dir -> owner publication crash window. No destination
            // temporary can exist before transaction.json is first synced.
            fs::remove_dir_all(&directory)
                .map_err(|error| format!("remove unstarted transaction: {error}"))?;
            continue;
        }
        let owner_token = validate_bundle_transaction_directory(&name, &directory)?;
        let journal_path = directory.join("transaction.json");
        if !journal_path.is_file() {
            sweep_transaction_temporaries(&allowed_roots, &name, &[])?;
            fs::remove_dir_all(&directory)
                .map_err(|error| format!("remove unstarted transaction {name:?}: {error}"))?;
            continue;
        }
        let journal: BundleTransactionJournal = serde_json::from_slice(
            &fs::read(&journal_path)
                .map_err(|error| format!("read bundle transaction {name:?}: {error}"))?,
        )
        .map_err(|error| format!("invalid bundle transaction {name:?}: {error}"))?;
        if journal.owner_token != owner_token {
            return Err("bundle transaction owner token disagrees with its directory".to_owned());
        }
        validate_bundle_journal(&journal, &name, &directory, &allowed_roots)?;
        let committed = directory.join("committed").is_file();
        if !committed {
            for item in &journal.entries {
                if let Some(old) = &item.replacement
                    && !identity_matches(&old.backup, old.device, old.inode)?
                    && identity_matches(&item.target, old.device, old.inode)?
                {
                    rename_without_overwrite(&item.target, &old.backup).map_err(|error| {
                        format!(
                            "recover preserved install target {}: {error}",
                            item.target.display()
                        )
                    })?;
                    sync_parent(&item.target)
                        .map_err(|error| format!("sync recovered replacement: {error}"))?;
                }
            }
            // Recovery only publishes into a missing target and never
            // overwrites a directory entry created by another actor.
            for item in &journal.entries {
                if identity_matches(&item.target, item.device, item.inode)? {
                    continue;
                }
                let old_is_safe = item.replacement.as_ref().is_none_or(|old| {
                    identity_matches(&old.backup, old.device, old.inode).unwrap_or(false)
                });
                if item.ready
                    && old_is_safe
                    && identity_matches(&item.temporary, item.device, item.inode)?
                {
                    match rename_without_overwrite(&item.temporary, &item.target) {
                        Ok(()) => sync_parent(&item.target)
                            .map_err(|error| format!("sync recovered install: {error}"))?,
                        // Another actor owns the live target. Leave it intact;
                        // the identity-bound temporary is swept below.
                        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
                        Err(error) => {
                            return Err(format!(
                                "finish interrupted install {}: {error}",
                                item.target.display()
                            ));
                        }
                    }
                }
            }
        }
        let fully_published = !journal.entries.is_empty()
            && journal.entries.iter().all(|item| {
                item.ready
                    && identity_matches(&item.target, item.device, item.inode).unwrap_or(false)
            });
        let mut cleanup_complete = true;
        for item in journal.entries.iter().rev() {
            cleanup_complete &= remove_if_identity(&item.temporary, item.device, item.inode)?;
            if (committed || fully_published)
                && identity_matches(&item.target, item.device, item.inode)?
            {
                remove_owner_marker(&item.target, &journal.owner_token)?;
            }
            if let Some(old) = &item.replacement {
                if committed || fully_published {
                    cleanup_complete &= remove_if_identity(&old.backup, old.device, old.inode)?;
                } else {
                    cleanup_complete &= remove_if_identity(&item.target, item.device, item.inode)?;
                    if identity_matches(&old.backup, old.device, old.inode)? {
                        match rename_without_overwrite(&old.backup, &item.target) {
                            Ok(()) => sync_parent(&item.target).map_err(|error| {
                                format!("sync restored install target: {error}")
                            })?,
                            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                                cleanup_complete = false;
                            }
                            Err(error) => {
                                return Err(format!(
                                    "restore interrupted install target {}: {error}",
                                    item.target.display()
                                ));
                            }
                        }
                    }
                }
            }
        }
        cleanup_complete &= sweep_transaction_temporaries(
            &allowed_roots,
            &journal.transaction_id,
            &journal.entries,
        )?;
        if cleanup_complete {
            fs::remove_dir_all(&directory)
                .map_err(|error| format!("remove recovered transaction {name:?}: {error}"))?;
        }
    }
    Ok(())
}

const PARTIAL_RETIRE_PREFIX: &str = ".pam-install-retire-v1-";

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct RetireTransactionJournal {
    schema: u32,
    token: String,
    source: PathBuf,
    detached: PathBuf,
    final_batch: PathBuf,
    identity: SourceIdentity,
}

struct RetireGuard {
    path: PathBuf,
    cleanup: bool,
}

impl RetireGuard {
    fn preserve(&mut self) {
        self.cleanup = false;
    }
}

impl Drop for RetireGuard {
    fn drop(&mut self) {
        if self.cleanup {
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}

fn preserve_or_restore_acquired_source(source: &Path, destination: &Path, guard: &mut RetireGuard) {
    let restored = restore_acquired_source_without_overwrite(destination, source);
    if !restored {
        // The original spelling is occupied or rollback itself failed. Keep
        // the acquired file in Trash so neither object is ever destroyed.
        guard.preserve();
    }
}

/// Restore an acquired regular file without replacing any pathname another
/// actor created. Hard-link creation is one atomic no-replace operation and
/// treats dangling symlinks as occupied. Filesystems without hard-link support
/// keep the acquired file quarantined instead of falling back to unsafe rename.
fn restore_acquired_source_without_overwrite(acquired: &Path, source: &Path) -> bool {
    if fs::hard_link(acquired, source).is_err() {
        return false;
    }
    // Do not remove the quarantine link until the restored source name is
    // durable. On fsync failure both links are deliberately preserved.
    if sync_parent(source).is_err() {
        return false;
    }
    let _ = fs::remove_file(acquired);
    let _ = sync_parent(acquired);
    true
}

/// Atomically rename without replacing a pre-existing directory entry. The
/// APP Manager runtime targets Linux; Apple support keeps host-side tests using
/// the equivalent exclusive rename. Unknown platforms fail closed.
fn rename_without_overwrite(source: &Path, destination: &Path) -> std::io::Result<()> {
    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        use std::ffi::CString;
        use std::os::unix::ffi::OsStrExt;
        let source = CString::new(source.as_os_str().as_bytes())
            .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
        let destination = CString::new(destination.as_os_str().as_bytes())
            .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
        // SAFETY: both C strings are NUL-terminated and live for the call.
        let result = unsafe {
            libc::renameat2(
                libc::AT_FDCWD,
                source.as_ptr(),
                libc::AT_FDCWD,
                destination.as_ptr(),
                libc::RENAME_NOREPLACE,
            )
        };
        return if result == 0 {
            Ok(())
        } else {
            Err(std::io::Error::last_os_error())
        };
    }
    #[cfg(target_vendor = "apple")]
    {
        use std::ffi::CString;
        use std::os::unix::ffi::OsStrExt;
        let source = CString::new(source.as_os_str().as_bytes())
            .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
        let destination = CString::new(destination.as_os_str().as_bytes())
            .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
        // SAFETY: both C strings are NUL-terminated and live for the call.
        let result =
            unsafe { libc::renamex_np(source.as_ptr(), destination.as_ptr(), libc::RENAME_EXCL) };
        return if result == 0 {
            Ok(())
        } else {
            Err(std::io::Error::last_os_error())
        };
    }
    #[allow(unreachable_code)]
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "atomic no-replace rename is unavailable",
    ))
}

fn retire_local_bundle(
    source: &Path,
    source_file: &mut File,
    trash_dir: &Path,
    identity: &SourceIdentity,
) -> Result<(), String> {
    fs::create_dir_all(trash_dir).map_err(|error| format!("create trash root: {error}"))?;
    let zip_name = source
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "bundle.zip".to_owned());
    let same_filesystem = source
        .parent()
        .and_then(filesystem_id)
        .zip(filesystem_id(trash_dir))
        .is_some_and(|(left, right)| left == right);
    if same_filesystem {
        identity.verify_open_file(source_file)?;
        let batch = allocate_directory(trash_dir, "zip")?;
        let mut guard = RetireGuard {
            path: batch.clone(),
            cleanup: true,
        };
        let destination = batch.join(&zip_name);
        rename_without_overwrite(source, &destination)
            .map_err(|error| format!("retire zip without replacing another entry: {error}"))?;
        if let Err(error) = identity.verify_moved_path(&destination) {
            preserve_or_restore_acquired_source(source, &destination, &mut guard);
            return Err(error);
        }
        // The only copy has moved into Trash. Preserve it even if a later
        // directory fsync reports an error.
        guard.preserve();
        sync_parent(source).map_err(|error| format!("sync retired zip source: {error}"))?;
        sync_parent(&destination)
            .map_err(|error| format!("sync retired zip destination: {error}"))?;
        return Ok(());
    }

    identity.verify_open_file(source_file)?;
    let required = source_file
        .metadata()
        .map_err(|error| format!("inspect open zip before retirement: {error}"))?
        .len()
        .saturating_add(INSTALL_SPACE_RESERVE);
    ensure_available(trash_dir, required, "移动原始安装包到回收站")?;
    let retirement_token = secure_random_hex()?;
    let partial = trash_dir.join(format!("{PARTIAL_RETIRE_PREFIX}{retirement_token}"));
    fs::create_dir(&partial).map_err(|error| format!("create Trash transaction: {error}"))?;
    write_empty_sync(&partial.join(format!("owner-{retirement_token}")))?;
    let mut guard = RetireGuard {
        path: partial.clone(),
        cleanup: true,
    };
    copy_file_handle_durable(source_file, &partial.join(&zip_name))?;
    let final_batch = trash_dir.join(format!("zip-{}", retirement_token));
    if final_batch.exists() {
        return Err("trash batch collision".to_owned());
    }
    let detached = source
        .parent()
        .ok_or_else(|| "ZIP source has no parent".to_owned())?
        .join(format!(".pam-source-v1-{retirement_token}"));
    write_json_sync(
        &partial.join("retire.json"),
        &RetireTransactionJournal {
            schema: 1,
            token: retirement_token.clone(),
            source: source.to_path_buf(),
            detached: detached.clone(),
            final_batch: final_batch.clone(),
            identity: *identity,
        },
    )?;
    test_crash_point("after-retire-journal");
    detach_source_to(source, &detached, identity)?;
    test_crash_point("after-source-detach");
    if let Err(error) = fs::remove_file(&detached) {
        guard.preserve();
        return Err(format!("retire zip source: {error}"));
    }
    if let Err(error) = sync_parent(&detached) {
        guard.preserve();
        return Err(format!("sync retired zip source: {error}"));
    }
    test_crash_point("after-source-unlink");
    if let Err(error) = rename_without_overwrite(&partial, &final_batch) {
        guard.preserve();
        return Err(format!("publish retired zip: {error}"));
    }
    guard.path = final_batch.clone();
    guard.preserve();
    sync_parent(&final_batch).map_err(|error| format!("sync retired zip batch: {error}"))?;
    cleanup_retire_metadata(&final_batch, &retirement_token)?;
    Ok(())
}

fn sweep_partial_retirements(trash_dir: &Path) -> Result<(), String> {
    let Ok(entries) = fs::read_dir(trash_dir) else {
        return Ok(());
    };
    for entry in entries {
        let entry = entry.map_err(|error| format!("read trash root: {error}"))?;
        if let Some(token) = entry
            .file_name()
            .to_str()
            .and_then(|name| name.strip_prefix(PARTIAL_RETIRE_PREFIX))
        {
            let metadata = entry
                .file_type()
                .map_err(|error| format!("inspect partial Trash batch: {error}"))?;
            if !metadata.is_dir() {
                return Err("partial Trash transaction is not a directory".to_owned());
            }
            if fs::read_dir(entry.path())
                .map_err(|error| format!("inspect partial Trash transaction: {error}"))?
                .next()
                .is_none()
            {
                fs::remove_dir(entry.path())
                    .map_err(|error| format!("remove unstarted Trash transaction: {error}"))?;
                continue;
            }
            if token.len() != 64
                || !token.bytes().all(|byte| byte.is_ascii_hexdigit())
                || !entry.path().join(format!("owner-{token}")).is_file()
            {
                return Err("partial Trash transaction owner is invalid".to_owned());
            }
            let journal_path = entry.path().join("retire.json");
            if journal_path.is_file() {
                let journal: RetireTransactionJournal = serde_json::from_slice(
                    &fs::read(&journal_path)
                        .map_err(|error| format!("read Trash transaction: {error}"))?,
                )
                .map_err(|error| format!("invalid Trash transaction: {error}"))?;
                recover_retire_transaction(trash_dir, &entry.path(), token, &journal)?;
            } else {
                fs::remove_dir_all(entry.path())
                    .map_err(|error| format!("remove partial Trash transaction: {error}"))?;
            }
        }
    }
    Ok(())
}

fn recover_retire_transaction(
    trash_dir: &Path,
    partial: &Path,
    token: &str,
    journal: &RetireTransactionJournal,
) -> Result<(), String> {
    let expected_detached = journal
        .source
        .parent()
        .ok_or_else(|| "Trash transaction source has no parent".to_owned())?
        .join(format!(".pam-source-v1-{token}"));
    let expected_batch = trash_dir.join(format!("zip-{token}"));
    if journal.schema != 1
        || journal.token != token
        || journal.detached != expected_detached
        || journal.final_batch != expected_batch
        || !journal.source.is_absolute()
        || path_entry_exists(&expected_batch)
    {
        return Err("Trash transaction contains an unsafe path".to_owned());
    }
    let source_is_original = journal.identity.matches_original_path(&journal.source)?;
    if source_is_original && !journal.detached.exists() {
        // Acquisition never happened: the original archive is still safely
        // present at its original pathname, so the redundant Trash copy may
        // be discarded.
        fs::remove_dir_all(partial)
            .map_err(|error| format!("discard uncommitted Trash copy: {error}"))?;
        return Ok(());
    }
    if journal.detached.exists() {
        journal.identity.verify_moved_path(&journal.detached)?;
        fs::remove_file(&journal.detached)
            .map_err(|error| format!("finish retired ZIP source removal: {error}"))?;
        sync_parent(&journal.detached)
            .map_err(|error| format!("sync recovered ZIP source removal: {error}"))?;
    }
    // If the original pathname is missing, or now names a different inode,
    // the partial Trash copy is the only durable original. Publish it while
    // leaving any replacement at the source pathname untouched.
    rename_without_overwrite(partial, &journal.final_batch)
        .map_err(|error| format!("publish recovered Trash batch: {error}"))?;
    sync_parent(&journal.final_batch)
        .map_err(|error| format!("sync recovered Trash batch: {error}"))?;
    cleanup_retire_metadata(&journal.final_batch, token)
}

fn cleanup_retire_metadata(batch: &Path, token: &str) -> Result<(), String> {
    for path in [
        batch.join("retire.json"),
        batch.join(format!("owner-{token}")),
    ] {
        match fs::remove_file(&path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(format!("remove Trash transaction metadata: {error}")),
        }
    }
    File::open(batch)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| format!("sync cleaned Trash batch: {error}"))
}

fn validate_bundle_journal(
    journal: &BundleTransactionJournal,
    expected_id: &str,
    directory: &Path,
    allowed_roots: &[&Path],
) -> Result<(), String> {
    if journal.schema != 1
        || journal.transaction_id != expected_id
        || journal.owner_token.len() != 64
        || !journal
            .owner_token
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit())
        || journal.transaction_id != format!("{BUNDLE_TRANSACTION_PREFIX}{}", journal.owner_token)
        || !directory
            .join(format!("owner-{}", journal.owner_token))
            .is_file()
    {
        return Err("bundle transaction ownership check failed".to_owned());
    }
    let mut targets = BTreeSet::new();
    let mut temporaries = BTreeSet::new();
    let mut backups = BTreeSet::new();
    for (index, item) in journal.entries.iter().enumerate() {
        let allowed = allowed_roots
            .iter()
            .any(|root| item.target.parent() == Some(*root));
        let expected_temporary_prefix =
            format!(".pam-install-stage-{}-{index}-", journal.transaction_id);
        let temporary_name = item
            .temporary
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.starts_with(&expected_temporary_prefix));
        if !item.target.is_absolute()
            || !item.temporary.is_absolute()
            || !allowed
            || item.temporary.parent() != item.target.parent()
            || !temporary_name
            || !targets.insert(&item.target)
            || !temporaries.insert(&item.temporary)
        {
            return Err("bundle transaction contains an unsafe path".to_owned());
        }
        if let Some(old) = &item.replacement {
            let expected_backup = item
                .target
                .parent()
                .expect("validated parent")
                .join(format!(
                    ".pam-install-replaced-{}-{index}",
                    journal.transaction_id
                ));
            if old.backup != expected_backup
                || !old.backup.is_absolute()
                || !backups.insert(&old.backup)
            {
                return Err("bundle replacement transaction contains an unsafe path".to_owned());
            }
        }
    }
    Ok(())
}

fn validate_bundle_transaction_directory(
    transaction_id: &str,
    directory: &Path,
) -> Result<String, String> {
    let Some(owner_token) = transaction_id.strip_prefix(BUNDLE_TRANSACTION_PREFIX) else {
        return Err("bundle transaction prefix is invalid".to_owned());
    };
    if owner_token.len() != 64
        || !owner_token.bytes().all(|byte| byte.is_ascii_hexdigit())
        || !directory.join(format!("owner-{owner_token}")).is_file()
    {
        return Err("bundle transaction directory owner is invalid".to_owned());
    }
    Ok(owner_token.to_owned())
}

fn write_json_sync(path: &Path, value: &impl Serialize) -> Result<(), String> {
    let mut output = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|error| format!("create transaction journal: {error}"))?;
    serde_json::to_writer(&mut output, value)
        .map_err(|error| format!("write transaction journal: {error}"))?;
    output
        .flush()
        .and_then(|()| output.sync_all())
        .map_err(|error| format!("sync transaction journal: {error}"))?;
    sync_parent(path).map_err(|error| format!("sync transaction directory: {error}"))
}

fn write_json_replace_sync(path: &Path, value: &impl Serialize) -> Result<(), String> {
    let temporary = path.with_extension(format!(
        "json.new-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or(0)
    ));
    write_json_sync(&temporary, value)?;
    fs::rename(&temporary, path)
        .map_err(|error| format!("publish transaction journal: {error}"))?;
    sync_parent(path).map_err(|error| format!("sync published transaction journal: {error}"))
}

fn write_empty_sync(path: &Path) -> Result<(), String> {
    let output = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|error| format!("create transaction commit marker: {error}"))?;
    output
        .sync_all()
        .map_err(|error| format!("sync transaction commit marker: {error}"))?;
    sync_parent(path).map_err(|error| format!("sync transaction commit marker: {error}"))
}

fn sync_parent(path: &Path) -> std::io::Result<()> {
    File::open(
        path.parent()
            .ok_or_else(|| std::io::Error::other("path has no parent"))?,
    )?
    .sync_all()
}

fn secure_random_hex() -> Result<String, String> {
    let mut bytes = [0_u8; 32];
    File::open("/dev/urandom")
        .and_then(|mut source| source.read_exact(&mut bytes))
        .map_err(|error| format!("read transaction randomness: {error}"))?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn open_archive(path: &Path) -> Result<File, String> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        let file = fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)
            .map_err(|error| format!("open {}: {error}", path.display()))?;
        if !file
            .metadata()
            .map_err(|error| format!("inspect {}: {error}", path.display()))?
            .file_type()
            .is_file()
        {
            return Err(format!(
                "ZIP source is not a regular file: {}",
                path.display()
            ));
        }
        Ok(file)
    }
    #[cfg(not(unix))]
    {
        File::open(path).map_err(|error| format!("open {}: {error}", path.display()))
    }
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct SourceIdentity {
    device: u64,
    inode: u64,
    length: u64,
    change_seconds: i64,
    change_nanoseconds: i64,
}

impl SourceIdentity {
    fn from_file(file: &File) -> Result<Self, String> {
        let metadata = file
            .metadata()
            .map_err(|error| format!("inspect open ZIP source: {error}"))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            Ok(Self {
                device: metadata.dev(),
                inode: metadata.ino(),
                length: metadata.len(),
                change_seconds: metadata.ctime(),
                change_nanoseconds: metadata.ctime_nsec(),
            })
        }
        #[cfg(not(unix))]
        Ok(Self {
            device: metadata.len(),
            inode: 0,
            length: metadata.len(),
            change_seconds: 0,
            change_nanoseconds: 0,
        })
    }

    fn verify_moved_path(&self, path: &Path) -> Result<(), String> {
        let metadata = fs::symlink_metadata(path)
            .map_err(|error| format!("inspect acquired ZIP source {}: {error}", path.display()))?;
        if !metadata.file_type().is_file() {
            return Err("ZIP source was replaced before retirement".to_owned());
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            if metadata.dev() != self.device
                || metadata.ino() != self.inode
                || metadata.len() != self.length
            {
                return Err("ZIP source was replaced before retirement".to_owned());
            }
        }
        #[cfg(not(unix))]
        if metadata.len() != self.length || self.device != self.length || self.inode != 0 {
            return Err("ZIP source was replaced before retirement".to_owned());
        }
        Ok(())
    }

    fn verify_open_file(&self, file: &File) -> Result<(), String> {
        let current = Self::from_file(file)?;
        if current.token() != self.token() {
            return Err("ZIP source changed while it was being installed".to_owned());
        }
        Ok(())
    }

    fn matches_original_path(&self, path: &Path) -> Result<bool, String> {
        let file = match open_archive(path) {
            Ok(file) => file,
            Err(_error) if !path.exists() => return Ok(false),
            Err(error) => {
                // An occupied symlink, directory, or unreadable replacement
                // is not the original source. Preserve it and publish the
                // durable Trash copy instead of treating it as fatal.
                let _ = error;
                return Ok(false);
            }
        };
        Ok(Self::from_file(&file)?.token() == self.token())
    }

    fn token(&self) -> String {
        format!(
            "{}:{}:{}:{}:{}",
            self.device, self.inode, self.length, self.change_seconds, self.change_nanoseconds
        )
    }
}

/// Move the pathname into an unpredictable same-directory quarantine first,
/// then verify the object that was actually moved. This makes retirement an
/// atomic path acquisition instead of a check-then-rename/unlink sequence.
fn detach_source(source: &Path, identity: &SourceIdentity) -> Result<PathBuf, String> {
    let parent = source
        .parent()
        .ok_or_else(|| "ZIP source has no parent".to_owned())?;
    let detached = parent.join(format!(".pam-source-v1-{}", secure_random_hex()?));
    detach_source_to(source, &detached, identity)
}

fn detach_source_to(
    source: &Path,
    detached: &Path,
    identity: &SourceIdentity,
) -> Result<PathBuf, String> {
    if detached.parent() != source.parent() {
        return Err("ZIP source quarantine path is unsafe".to_owned());
    }
    rename_without_overwrite(source, detached)
        .map_err(|error| format!("atomically acquire ZIP source without replacement: {error}"))?;
    sync_parent(detached).map_err(|error| format!("sync acquired ZIP source: {error}"))?;
    if let Err(error) = identity.verify_moved_path(detached) {
        // The pathname was replaced immediately before rename. Restore that
        // unrelated file only through an atomic no-replace operation;
        // otherwise preserve it under the quarantine name and report the race.
        restore_acquired_source_without_overwrite(detached, source);
        return Err(error);
    }
    Ok(detached.to_path_buf())
}

fn source_identity_token(path: &Path) -> Result<String, String> {
    let file = open_archive(path)?;
    SourceIdentity::from_file(&file).map(|identity| identity.token())
}

#[cfg(unix)]
fn file_identity_numbers(path: &Path) -> Result<(u64, u64), String> {
    use std::os::unix::fs::MetadataExt;
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("inspect staged install path {}: {error}", path.display()))?;
    Ok((metadata.dev(), metadata.ino()))
}

#[cfg(not(unix))]
fn file_identity_numbers(path: &Path) -> Result<(u64, u64), String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("inspect staged install path {}: {error}", path.display()))?;
    Ok((metadata.len(), 0))
}

fn remove_if_identity(path: &Path, device: u64, inode: u64) -> Result<bool, String> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(true),
        Err(error) => return Err(format!("inspect recovery path {}: {error}", path.display())),
    };
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if metadata.dev() != device || metadata.ino() != inode {
            return Ok(false);
        }
    }
    #[cfg(not(unix))]
    if metadata.len() != device || inode != 0 {
        return Ok(false);
    }
    remove_install_path(path)
        .map(|()| true)
        .map_err(|error| format!("remove recovery path {}: {error}", path.display()))
}

fn identity_matches(path: &Path, device: u64, inode: u64) -> Result<bool, String> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(format!("inspect recovery path {}: {error}", path.display())),
    };
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Ok(metadata.dev() == device && metadata.ino() == inode)
    }
    #[cfg(not(unix))]
    Ok(metadata.len() == device && inode == 0)
}

fn owner_marker(path: &Path, token: &str) -> PathBuf {
    path.join(format!(".pam-install-owner-v1-{token}"))
}

fn remove_owner_marker(path: &Path, token: &str) -> Result<(), String> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_dir() => {}
        Ok(_) => return Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(format!("inspect installed target: {error}")),
    }
    let marker = owner_marker(path, token);
    match fs::symlink_metadata(&marker) {
        Ok(metadata) if metadata.file_type().is_file() => {
            fs::remove_file(&marker)
                .map_err(|error| format!("remove install owner marker: {error}"))?;
            sync_parent(&marker).map_err(|error| format!("sync owner marker removal: {error}"))
        }
        Ok(_) => Err("install owner marker is not a regular file".to_owned()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("inspect install owner marker: {error}")),
    }
}

fn sweep_transaction_temporaries(
    allowed_roots: &[&Path],
    transaction_id: &str,
    entries: &[BundleTransactionEntry],
) -> Result<bool, String> {
    let listed = entries
        .iter()
        .map(|entry| entry.temporary.as_path())
        .collect::<BTreeSet<_>>();
    let prefix = format!(".pam-install-stage-{transaction_id}-");
    for root in allowed_roots {
        let Ok(children) = fs::read_dir(root) else {
            continue;
        };
        for child in children {
            let child = child.map_err(|error| format!("scan install temporaries: {error}"))?;
            let path = child.path();
            if listed.contains(path.as_path()) {
                continue;
            }
            if child
                .file_name()
                .to_str()
                .is_some_and(|name| name.starts_with(&prefix))
            {
                remove_install_path(&path)
                    .map_err(|error| format!("remove orphan install temporary: {error}"))?;
            }
        }
    }
    Ok(true)
}

fn validate_archive_file(
    file: &mut File,
    label: &str,
    limits: &BundleLimits,
    password: Option<&str>,
    cancel: &dyn Fn() -> bool,
) -> Result<u64, String> {
    let catalog = archive_bundle::catalog(file, label, password)?;
    if catalog.entries.len() > limits.entries {
        return Err("archive contains too many entries".into());
    }
    if catalog.encrypted && password.is_none() {
        return Err(PASSWORD_REQUIRED.to_owned());
    }
    let mut total = 0_u64;
    let entries = archive_bundle::validate_catalog_uniqueness(&catalog.entries)?;
    for entry in &catalog.entries {
        check_cancelled(cancel)?;
        if entry.anti_item {
            return Err(format!("7z anti-item is not supported: {}", entry.name));
        }
        let raw = &entry.name;
        let relative = raw.trim_start_matches("./").to_owned();
        validate_path(&relative)?;
        if !entry.directory && !raw.ends_with('/') && entry.size > limits.entry_bytes {
            return Err(format!("entry exceeds limit: {raw}"));
        }
        total = total.saturating_add(entry.size);
        if total > limits.total_bytes {
            return Err("archive expansion exceeds total limit".into());
        }
    }
    for (path, directory) in &entries {
        let mut ancestor = Path::new(path).parent().map(Path::to_path_buf);
        while let Some(parent) = ancestor {
            if parent.as_os_str().is_empty() {
                break;
            }
            let parent = parent.to_string_lossy();
            if entries.get(parent.as_ref()) == Some(&false) {
                return Err(format!(
                    "archive entry conflicts with a file ancestor: {path}"
                ));
            }
            ancestor = Path::new(parent.as_ref()).parent().map(Path::to_path_buf);
        }
        if !directory {
            let prefix = format!("{path}/");
            if entries
                .keys()
                .any(|candidate| candidate.starts_with(&prefix))
            {
                return Err(format!(
                    "archive file entry conflicts with child entries: {path}"
                ));
            }
        }
    }
    Ok(total)
}

fn extract_safe_file(
    file: &mut File,
    label: &str,
    target: &Path,
    password: Option<&str>,
    cancel: &dyn Fn() -> bool,
) -> Result<(), String> {
    archive_bundle::extract(file, label, target, password, cancel)
}

fn validate_path(value: &str) -> Result<(), String> {
    if value.is_empty()
        || value.starts_with('/')
        || value.contains(['\\', '\0', '\t', '\r', '\n'])
        || value.contains("//")
    {
        return Err(format!("unsafe path: {value:?}"));
    }
    for component in std::path::Path::new(value.trim_end_matches('/')).components() {
        let std::path::Component::Normal(name) = component else {
            return Err(format!("unsafe path: {value:?}"));
        };
        if name.to_str().is_some_and(|name| {
            name.starts_with(".pam-install")
                || name.starts_with(".pam-source")
                || name.starts_with(".pm-install")
        }) {
            return Err(format!("reserved transaction path: {value:?}"));
        }
    }
    Ok(())
}

fn copy_file(src: &Path, dst: &Path, cancel: &dyn Fn() -> bool) -> Result<(), String> {
    let mut input = File::open(src).map_err(|error| format!("open {src:?}: {error}"))?;
    let mut output = File::create(dst).map_err(|error| format!("create {dst:?}: {error}"))?;
    copy_stream(&mut input, &mut output, cancel)?;
    output
        .sync_all()
        .map_err(|error| format!("sync {dst:?}: {error}"))
}

fn copy_file_handle_durable(input: &mut File, dst: &Path) -> Result<(), String> {
    input
        .seek(SeekFrom::Start(0))
        .map_err(|error| format!("seek open ZIP source: {error}"))?;
    let mut output = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(dst)
        .map_err(|error| format!("create {dst:?}: {error}"))?;
    std::io::copy(input, &mut output).map_err(|error| format!("copy open ZIP source: {error}"))?;
    output
        .flush()
        .and_then(|()| output.sync_all())
        .map_err(|error| format!("sync {dst:?}: {error}"))
}

fn copy_stream(
    input: &mut impl Read,
    output: &mut impl Write,
    cancel: &dyn Fn() -> bool,
) -> Result<(), String> {
    let mut buffer = [0_u8; 256 * 1024];
    loop {
        check_cancelled(cancel)?;
        let read = input.read(&mut buffer).map_err(|error| error.to_string())?;
        if read == 0 {
            return output.flush().map_err(|error| error.to_string());
        }
        output
            .write_all(&buffer[..read])
            .map_err(|error| error.to_string())?;
    }
}

fn check_cancelled(cancel: &dyn Fn() -> bool) -> Result<(), String> {
    if cancel() {
        Err("zip installation cancelled".to_owned())
    } else {
        Ok(())
    }
}

fn copy_tree(src: &Path, dst: &Path, cancel: &dyn Fn() -> bool) -> Result<(), String> {
    check_cancelled(cancel)?;
    fs::create_dir_all(dst).map_err(|e| e.to_string())?;
    for entry in fs::read_dir(src).map_err(|e| e.to_string())? {
        check_cancelled(cancel)?;
        let entry = entry.map_err(|e| e.to_string())?;
        let target = dst.join(entry.file_name());
        let ty = entry.file_type().map_err(|e| e.to_string())?;
        if ty.is_dir() {
            copy_tree(&entry.path(), &target, cancel)?;
        } else if ty.is_file() {
            copy_file(&entry.path(), &target, cancel)?;
        }
    }
    File::open(dst)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| format!("sync install directory {dst:?}: {error}"))
}

fn allocate_directory(parent: &Path, prefix: &str) -> Result<PathBuf, String> {
    for attempt in 0..128_u32 {
        let path = parent.join(format!(
            "{prefix}-{}-{}-{attempt}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|duration| duration.as_nanos())
                .unwrap_or(0),
        ));
        match fs::create_dir(&path) {
            Ok(()) => return Ok(path),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(format!("allocate temporary directory: {error}")),
        }
    }
    Err("cannot allocate a unique temporary directory".into())
}

fn allocate_target(
    parent: &Path,
    transaction_id: &str,
    index: usize,
    directory: bool,
) -> Result<PathBuf, String> {
    let prefix = format!(".pam-install-stage-{transaction_id}-{index}");
    if directory {
        return allocate_directory(parent, &prefix);
    }
    for attempt in 0..128_u32 {
        let path = parent.join(format!("{prefix}-{}-{attempt}", std::process::id()));
        match fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
        {
            Ok(_) => return Ok(path),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(format!("allocate temporary file: {error}")),
        }
    }
    Err("cannot allocate a unique temporary file".into())
}

fn remove_install_path(path: &Path) -> std::io::Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    if metadata.file_type().is_dir() && !metadata.file_type().is_symlink() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    }
}

fn path_entry_exists(path: &Path) -> bool {
    match fs::symlink_metadata(path) {
        Ok(_) => true,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
        // An unreadable entry is occupied for mutation purposes. The actual
        // operation will surface the underlying error without replacing it.
        Err(_) => true,
    }
}

fn path_size(path: &Path) -> Result<u64, String> {
    let metadata = fs::symlink_metadata(path).map_err(|error| error.to_string())?;
    if metadata.file_type().is_symlink() {
        return Err(format!(
            "install source contains a symbolic link: {}",
            path.display()
        ));
    }
    if metadata.is_file() {
        return Ok(metadata.len());
    }
    let mut total = 0_u64;
    for entry in fs::read_dir(path).map_err(|error| error.to_string())? {
        let entry = entry.map_err(|error| error.to_string())?;
        total = total.saturating_add(path_size(&entry.path())?);
    }
    Ok(total)
}

fn preflight_destinations(plan: &[InstallTarget]) -> Result<(), String> {
    let mut filesystems: BTreeMap<u64, (PathBuf, u64)> = BTreeMap::new();
    for item in plan {
        let parent = item
            .target
            .parent()
            .ok_or_else(|| format!("invalid install target: {}", item.target.display()))?;
        fs::create_dir_all(parent)
            .map_err(|error| format!("create install destination {}: {error}", parent.display()))?;
        let bytes = path_size(&item.source)?;
        let key = filesystem_id(parent).unwrap_or_else(|| {
            // Unsupported targets still receive a distinct conservative
            // bucket, while Unix uses the real device ID.
            let value = parent.to_string_lossy();
            value.bytes().fold(0_u64, |hash, byte| {
                hash.wrapping_mul(131).wrapping_add(byte as u64)
            })
        });
        let entry = filesystems.entry(key).or_insert((parent.to_path_buf(), 0));
        entry.1 = entry.1.saturating_add(bytes);
    }
    for (_, (path, bytes)) in filesystems {
        ensure_available(
            &path,
            bytes.saturating_add(INSTALL_SPACE_RESERVE),
            "写入安装目标",
        )?;
    }
    Ok(())
}

fn prepare_destination_parents(plan: &[InstallTarget]) -> Result<(), String> {
    for item in plan {
        let parent = item
            .target
            .parent()
            .ok_or_else(|| format!("invalid install target: {}", item.target.display()))?;
        fs::create_dir_all(parent)
            .map_err(|error| format!("create install destination {}: {error}", parent.display()))?;
        let metadata = fs::symlink_metadata(parent).map_err(|error| {
            format!("inspect install destination {}: {error}", parent.display())
        })?;
        if !metadata.file_type().is_dir() || metadata.file_type().is_symlink() {
            return Err(format!(
                "install destination is not a real directory: {}",
                parent.display()
            ));
        }
    }
    Ok(())
}

#[cfg(unix)]
fn filesystem_id(path: &Path) -> Option<u64> {
    use std::os::unix::fs::MetadataExt;
    fs::metadata(path).ok().map(|metadata| metadata.dev())
}

#[cfg(not(unix))]
fn filesystem_id(_path: &Path) -> Option<u64> {
    None
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

fn ensure_available(path: &Path, required: u64, purpose: &str) -> Result<(), String> {
    if available_bytes(path).is_some_and(|available| available < required) {
        return Err(format!(
            "存储空间不足，无法{purpose}（至少还需要 {} MiB）",
            required.saturating_add(1024 * 1024 - 1) / (1024 * 1024)
        ));
    }
    Ok(())
}

fn set_executable(path: &Path) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let metadata = fs::metadata(path)
            .map_err(|error| format!("read executable permissions {}: {error}", path.display()))?;
        let mut permissions = metadata.permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(path, permissions)
            .map_err(|error| format!("set executable permission {}: {error}", path.display()))?;
        File::open(path)
            .and_then(|file| file.sync_all())
            .map_err(|error| format!("sync executable {}: {error}", path.display()))?;
    }
    let _ = path;
    Ok(())
}
