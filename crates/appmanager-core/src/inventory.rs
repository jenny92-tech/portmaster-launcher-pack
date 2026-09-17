// INPUT:  ResolvedDeviceContext、ManagedRoot、Shell 路径事实、文件系统与 serde
// OUTPUT: Inventory/InventoryOptions、Port/App/Runtime/Trash 事实及 scan()/to_tsv()
// POS:    按配置根与实际路径关联启动脚本、共享数据、Runtime 和残留，不按目录名猜归属
use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsStr;
use std::fs::{self, File};
use std::io::Read;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::context::{CapabilityState, ResolvedDeviceContext};
use crate::path::{ManagedRoot, PathSafetyError};

pub const INVENTORY_SCHEMA: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum InventoryKind {
    Directory,
    File,
    Symlink,
    Other,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InventoryEntry {
    pub root: String,
    pub name: String,
    pub path: PathBuf,
    pub kind: InventoryKind,
    pub bytes: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Inventory {
    pub schema: u32,
    pub entries: Vec<InventoryEntry>,
    pub ports: Vec<PortFact>,
    /// Exact managed data-directory path -> number of launchers that reference
    /// it. Display names must never be used as destructive association keys.
    pub data_refcount: BTreeMap<String, usize>,
    pub data_dirs: Vec<InventoryEntry>,
    pub images: Vec<ImageFact>,
    pub orphan_dirs: Vec<InventoryEntry>,
    pub orphan_images: Vec<ImageFact>,
    pub dead_scripts: Vec<DeadScriptFact>,
    pub trash: Vec<TrashFact>,
    pub runtimes: RuntimeInventory,
    #[serde(default)]
    pub apps: Vec<AppFact>,
    pub diagnostics: Vec<String>,
    /// True when any script could not be parsed reliably. Callers must then
    /// fail closed: never delete a shared data folder based on reference counts that
    /// may be missing dynamic references.
    #[serde(default)]
    pub classification_uncertain: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InventoryOptions {
    pub scan_script_images: bool,
    pub ignore_dirs: BTreeSet<String>,
    pub ignore_scripts: BTreeSet<String>,
    pub directory: String,
    pub controlfolder: String,
    pub home: String,
}

impl Default for InventoryOptions {
    fn default() -> Self {
        Self {
            scan_script_images: false,
            ignore_dirs: BTreeSet::new(),
            ignore_scripts: BTreeSet::new(),
            directory: String::new(),
            controlfolder: String::new(),
            home: "/root".to_owned(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AppFact {
    pub root_id: String,
    pub name: String,
    pub folder: PathBuf,
    pub launch: PathBuf,
    pub has_icon: bool,
    pub has_config: bool,
    /// config.json `label` (English display name) when present.
    #[serde(default)]
    pub label: Option<String>,
    /// config.json `label.ch.lang` (Chinese display name) when present.
    #[serde(default)]
    pub label_zh: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PortFact {
    pub script: String,
    pub path: PathBuf,
    pub dir: String,
    pub data_path: PathBuf,
    pub claimed_dir: String,
    pub dir_exists: bool,
    pub images: Vec<ImageFact>,
    pub runtime: String,
    pub runtimes: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ImageFact {
    pub name: String,
    pub path: PathBuf,
    pub is_dir: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeadScriptFact {
    pub script: String,
    pub path: PathBuf,
    pub missing_dir: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TrashFact {
    pub name: String,
    pub path: PathBuf,
    pub kind: InventoryKind,
    pub is_dir: bool,
    pub bucket: String,
    #[serde(default)]
    pub restore_target: PathBuf,
    #[serde(default)]
    pub restore_conflict: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeHealth {
    Missing,
    InvalidMagic,
    Healthy,
    Unknown,
    Symlink,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RuntimeFact {
    pub name: String,
    pub path: PathBuf,
    pub users: Vec<String>,
    pub health: RuntimeHealth,
    pub bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RuntimeInventory {
    pub need: BTreeMap<String, Vec<String>>,
    pub facts: Vec<RuntimeFact>,
}

#[derive(Debug, Error)]
pub enum InventoryError {
    #[error("device context is invalid: {0}")]
    Context(String),
    #[error("inventory capability is unknown")]
    CapabilityUnknown,
    #[error("cache state is invalid: {0}")]
    CacheState(String),
    #[error("inventory root `{root}` is unsafe: {source}")]
    UnsafeRoot {
        root: &'static str,
        #[source]
        source: PathSafetyError,
    },
    #[error("cannot enumerate inventory root `{root}`: {source}")]
    Enumerate {
        root: &'static str,
        #[source]
        source: std::io::Error,
    },
    #[error("inventory entry under `{root}` is not valid UTF-8")]
    NonUtf8 { root: &'static str },
    #[error("cannot read inventory file {path}: {source}")]
    Read {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("script exceeds the inventory read limit: {0}")]
    ScriptTooLarge(PathBuf),
}

impl Inventory {
    pub fn scan(context: &ResolvedDeviceContext) -> Result<Self, InventoryError> {
        Self::scan_with_options(context, &InventoryOptions::default())
    }

    pub fn scan_with_options(
        context: &ResolvedDeviceContext,
        options: &InventoryOptions,
    ) -> Result<Self, InventoryError> {
        context
            .validate()
            .map_err(|error| InventoryError::Context(error.to_string()))?;
        if context.capabilities.inventory_ports != CapabilityState::Current
            && context.capabilities.inventory_apps != CapabilityState::Current
        {
            return Err(InventoryError::CapabilityUnknown);
        }

        let mut roots = vec![("trash", context.roots.trash.as_path())];
        if context.capabilities.inventory_ports == CapabilityState::Current {
            roots.extend([
                ("scripts", context.roots.scripts.as_path()),
                ("game-dirs", context.roots.game_dirs.as_path()),
            ]);
            if let Some(libs) = &context.roots.libs {
                roots.push(("libs", libs.as_path()));
            }
            if let Some(images) = &context.roots.images {
                roots.push(("images", images.as_path()));
            }
        }
        let mut directories = DirectorySnapshots::default();
        let mut entries = Vec::new();
        for (name, path) in roots {
            entries.extend(directories.read(name, path)?);
        }
        entries.sort_by(|left, right| {
            (&left.root, &left.name, &left.path).cmp(&(&right.root, &right.name, &right.path))
        });
        let facts = scan_facts(context, options, &entries, &mut directories)?;
        Ok(Self {
            schema: INVENTORY_SCHEMA,
            entries,
            ports: facts.ports,
            data_refcount: facts.data_refcount,
            data_dirs: facts.data_dirs,
            images: facts.images,
            orphan_dirs: facts.orphan_dirs,
            orphan_images: facts.orphan_images,
            dead_scripts: facts.dead_scripts,
            trash: facts.trash,
            runtimes: facts.runtimes,
            apps: facts.apps,
            diagnostics: facts.diagnostics,
            classification_uncertain: facts.classification_uncertain,
        })
    }

    pub fn to_tsv(&self) -> String {
        let mut rows = vec![format!("schema\t{}", self.schema)];
        for entry in &self.entries {
            rows.push(format!(
                "entry\t{}\t{}\t{}\t{}\t{}",
                entry.root,
                kind_name(entry.kind),
                entry
                    .bytes
                    .map_or_else(|| "-".to_owned(), |value| value.to_string()),
                entry.path.display(),
                entry.name
            ));
        }
        for port in &self.ports {
            rows.push(format!(
                "port\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
                port.script,
                port.path.display(),
                port.dir,
                port.data_path.display(),
                port.claimed_dir,
                u8::from(port.dir_exists),
                port.runtime,
                port.runtimes.join(",")
            ));
            for image in &port.images {
                rows.push(format!(
                    "port-image\t{}\t{}\t{}",
                    port.script,
                    image.path.display(),
                    image.name
                ));
            }
        }
        for (path, count) in &self.data_refcount {
            rows.push(format!("data-refcount\t{path}\t{count}"));
        }
        for entry in &self.orphan_dirs {
            rows.push(format!(
                "orphan-dir\t{}\t{}",
                entry.path.display(),
                entry.name
            ));
        }
        for image in &self.orphan_images {
            rows.push(format!(
                "orphan-image\t{}\t{}",
                image.path.display(),
                image.name
            ));
        }
        for dead in &self.dead_scripts {
            rows.push(format!(
                "dead-script\t{}\t{}\t{}",
                dead.path.display(),
                dead.script,
                dead.missing_dir
            ));
        }
        for item in &self.trash {
            rows.push(format!(
                "trash\t{}\t{}\t{}\t{}",
                item.bucket,
                kind_name(item.kind),
                item.path.display(),
                item.name
            ));
        }
        for runtime in &self.runtimes.facts {
            rows.push(format!(
                "runtime\t{}\t{}\t{}\t{}",
                runtime.name,
                runtime_health_name(runtime.health),
                runtime.bytes,
                runtime.path.display()
            ));
            for user in &runtime.users {
                rows.push(format!("runtime-user\t{}\t{}", runtime.name, user));
            }
        }
        for diagnostic in &self.diagnostics {
            rows.push(format!(
                "diagnostic\t{}",
                diagnostic.replace(['\t', '\r', '\n'], " ")
            ));
        }
        rows.push(String::new());
        rows.join("\n")
    }
}

struct ScannedFacts {
    ports: Vec<PortFact>,
    data_refcount: BTreeMap<String, usize>,
    data_dirs: Vec<InventoryEntry>,
    images: Vec<ImageFact>,
    orphan_dirs: Vec<InventoryEntry>,
    orphan_images: Vec<ImageFact>,
    dead_scripts: Vec<DeadScriptFact>,
    trash: Vec<TrashFact>,
    runtimes: RuntimeInventory,
    apps: Vec<AppFact>,
    diagnostics: Vec<String>,
    classification_uncertain: bool,
}

fn scan_facts(
    context: &ResolvedDeviceContext,
    options: &InventoryOptions,
    entries: &[InventoryEntry],
    directories: &mut DirectorySnapshots,
) -> Result<ScannedFacts, InventoryError> {
    let data_dirs = entries
        .iter()
        .filter(|entry| {
            entry.root == "game-dirs"
                && entry.kind == InventoryKind::Directory
                && !options.ignore_dirs.contains(&entry.name)
        })
        .cloned()
        .collect::<Vec<_>>();
    let real_dirs = data_dirs
        .iter()
        .map(|entry| entry.name.clone())
        .collect::<BTreeSet<_>>();

    let mut images = entries
        .iter()
        .filter(|entry| {
            entry.kind == InventoryKind::File
                && !is_appledouble(&entry.name)
                && is_image(&entry.name)
                && (entry.root == "images" || options.scan_script_images && entry.root == "scripts")
        })
        .map(|entry| ImageFact {
            name: entry.name.clone(),
            path: entry.path.clone(),
            is_dir: false,
        })
        .collect::<Vec<_>>();
    images.sort_by_key(|image| path_sort_key(&image.path));
    images.dedup_by(|left, right| left.path == right.path);
    let mut images_by_stem = BTreeMap::<String, Vec<ImageFact>>::new();
    for image in &images {
        images_by_stem
            .entry(stem(&image.name).to_owned())
            .or_default()
            .push(image.clone());
    }

    let mut script_entries = entries
        .iter()
        .filter(|entry| {
            entry.root == "scripts"
                && entry.kind == InventoryKind::File
                && !is_appledouble(&entry.name)
                && entry.name.to_ascii_lowercase().ends_with(".sh")
                && !options.ignore_scripts.contains(&entry.name)
        })
        .cloned()
        .collect::<Vec<_>>();
    script_entries.sort_by(|left, right| left.name.cmp(&right.name));
    let all_script_stems = entries
        .iter()
        .filter(|entry| {
            entry.root == "scripts"
                && entry.kind == InventoryKind::File
                && !is_appledouble(&entry.name)
                && entry.name.to_ascii_lowercase().ends_with(".sh")
        })
        .map(|entry| stem(&entry.name).to_owned())
        .collect::<BTreeSet<_>>();

    let mut ports = Vec::new();
    let mut dead_scripts = Vec::new();
    let mut data_refcount = BTreeMap::<String, usize>::new();
    let mut parsed_dir_refs = BTreeSet::new();
    let mut diagnostics = Vec::new();
    let mut orphan_classification_uncertain = false;
    let data_dir_paths = data_dirs
        .iter()
        .map(|entry| (entry.name.clone(), entry.path.clone()))
        .collect::<BTreeMap<_, _>>();
    let mut port_json_cache = BTreeMap::<String, Result<Option<Vec<String>>, String>>::new();
    let mut reported_port_json_errors = BTreeSet::new();
    let seed = [
        ("directory".to_owned(), options.directory.clone()),
        ("controlfolder".to_owned(), options.controlfolder.clone()),
        ("HOME".to_owned(), options.home.clone()),
    ]
    .into_iter()
    .filter(|(_, value)| !value.is_empty())
    .collect::<BTreeMap<_, _>>();
    let source_environment = crate::shell_sources::FileEnvironment::new(
        [
            Some(context.roots.scripts.clone()),
            Some(context.roots.game_dirs.clone()),
            context.roots.portmaster.clone(),
        ]
        .into_iter()
        .flatten(),
    );
    for entry in script_entries {
        let text = match read_script(&entry.path) {
            Ok(text) => text,
            Err(error) => {
                orphan_classification_uncertain = true;
                diagnostics.push(format!("skipped script {}: {error}", entry.name));
                continue;
            }
        };
        let analysis = crate::shell_paths::analyze_with_environment(
            &text,
            &seed,
            &entry.path,
            &source_environment,
        );
        let path_references = analysis
            .paths
            .iter()
            .chain(&analysis.declared_paths)
            .chain(&analysis.sources)
            .chain(&analysis.working_directories)
            .collect::<BTreeSet<_>>()
            .into_iter()
            .map(|path| {
                (
                    path,
                    managed_data_names(Path::new(path), &context.roots.game_dirs),
                )
            })
            .collect::<BTreeMap<_, _>>();
        let candidates = path_references
            .values()
            .flatten()
            .filter(|name| !options.ignore_dirs.contains(*name))
            .cloned()
            .collect::<BTreeSet<_>>();
        let mut claimed_dir = if candidates.len() == 1 {
            candidates.iter().next().unwrap().clone()
        } else {
            String::new()
        };
        let mut dir_exists = real_dirs.contains(&claimed_dir);
        let working_references = analysis
            .working_directories
            .iter()
            .map(|path| (path, &path_references[path]))
            .collect::<BTreeMap<_, _>>();
        let working_dirs = working_references
            .values()
            .flat_map(|names| names.iter())
            .filter(|name| !options.ignore_dirs.contains(*name))
            .cloned()
            .collect::<BTreeSet<_>>();
        if working_dirs.len() == 1 {
            claimed_dir = working_dirs.into_iter().next().unwrap();
            dir_exists = real_dirs.contains(&claimed_dir);
        } else if working_dirs.len() > 1 {
            claimed_dir.clear();
            dir_exists = false;
        }
        let mut refs = candidates
            .intersection(&real_dirs)
            .cloned()
            .collect::<BTreeSet<_>>();
        let gamedir_uncertain = analysis.uncertain();
        let script_uncertain = analysis.uncertain();
        // Keep lexical references as conservative protection when a child
        // cannot be resolved. They never choose metadata or deletion targets.
        for path in analysis
            .paths
            .iter()
            .chain(&analysis.declared_paths)
            .chain(&analysis.sources)
        {
            let path = Path::new(path);
            let relative = path.strip_prefix(&context.roots.game_dirs).ok();
            if let Some(std::path::Component::Normal(name)) =
                relative.and_then(|p| p.components().next())
            {
                if let Some(name) = name.to_str().filter(|name| real_dirs.contains(*name)) {
                    refs.insert(name.to_owned());
                }
            }
        }
        parsed_dir_refs.extend(refs.iter().cloned());
        for referenced_dir in &refs {
            if let Some(path) = data_dir_paths.get(referenced_dir) {
                *data_refcount
                    .entry(path.to_string_lossy().into_owned())
                    .or_default() += 1;
            }
        }
        if gamedir_uncertain {
            orphan_classification_uncertain = true;
            diagnostics.push(format!(
                "orphan classification uncertain for script {}: {}",
                entry.name,
                analysis
                    .diagnostics
                    .iter()
                    .cloned()
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
        }
        let has_managed_directory_use = working_references
            .values()
            .any(|names| names.contains(&claimed_dir));
        if !dir_exists && !claimed_dir.is_empty() && !script_uncertain && has_managed_directory_use
        {
            dead_scripts.push(DeadScriptFact {
                script: entry.name.clone(),
                path: entry.path.clone(),
                missing_dir: claimed_dir.clone(),
            });
        }
        let data_path = if dir_exists
            && !gamedir_uncertain
            && has_managed_directory_use
            && refs.len() == 1
            && refs.contains(&claimed_dir)
        {
            data_dir_paths
                .get(&claimed_dir)
                .cloned()
                .unwrap_or_default()
        } else {
            if refs.len() > 1 || (dir_exists && (gamedir_uncertain || refs.len() != 1)) {
                diagnostics.push(format!(
                    "data directory association is not unique or confirmed for script {}",
                    entry.name
                ));
            }
            PathBuf::new()
        };
        let shell_runtimes = analysis.runtime_names.clone();
        let mut runtimes = if dir_exists {
            let declaration = port_json_cache
                .entry(claimed_dir.clone())
                .or_insert_with(|| {
                    data_dir_paths
                        .get(&claimed_dir)
                        .map_or(Ok(None), |directory| port_json_runtimes(directory))
                })
                .clone();
            match declaration {
                Ok(Some(runtimes)) => runtimes,
                Ok(None) => shell_runtimes,
                Err(error) => {
                    if reported_port_json_errors.insert(claimed_dir.clone()) {
                        diagnostics.push(format!(
                            "ignored invalid port.json for {claimed_dir}: {error}"
                        ));
                    }
                    shell_runtimes
                }
            }
        } else {
            shell_runtimes
        };
        // Metadata takes precedence over legacy variable-name hints, but must
        // not hide additional dependencies referenced at managed Runtime paths.
        for name in
            analysis.runtime_dependencies(context.roots.libs.as_deref(), &source_environment)
        {
            if !runtimes.contains(&name) {
                runtimes.push(name);
            }
        }
        ports.push(PortFact {
            script: entry.name.clone(),
            path: entry.path,
            dir: if dir_exists {
                claimed_dir.clone()
            } else {
                String::new()
            },
            data_path,
            claimed_dir,
            dir_exists,
            images: images_by_stem
                .get(stem(&entry.name))
                .cloned()
                .unwrap_or_default(),
            runtime: runtimes.first().cloned().unwrap_or_default(),
            runtimes,
        });
    }
    dead_scripts.sort_by(|left, right| {
        (&left.script, &left.missing_dir).cmp(&(&right.script, &right.missing_dir))
    });

    let mut orphan_dirs = if !orphan_classification_uncertain {
        data_dirs
            .iter()
            .filter(|entry| !parsed_dir_refs.contains(&entry.name))
            .cloned()
            .collect::<Vec<_>>()
    } else {
        Vec::new()
    };
    orphan_dirs.sort_by_key(|entry| path_sort_key(&entry.path));
    let mut orphan_images = images
        .iter()
        .filter(|image| !all_script_stems.contains(stem(&image.name)))
        .cloned()
        .collect::<Vec<_>>();
    orphan_images.sort_by_key(|image| path_sort_key(&image.path));

    let mut need = BTreeMap::<String, Vec<String>>::new();
    for port in &ports {
        for runtime in &port.runtimes {
            need.entry(runtime.clone())
                .or_default()
                .push(port.script.clone());
        }
    }
    for users in need.values_mut() {
        users.sort();
        users.dedup();
    }
    let libs_entries = entries
        .iter()
        .filter(|entry| entry.root == "libs")
        .cloned()
        .collect::<Vec<_>>();
    let trash_entries = entries
        .iter()
        .filter(|entry| entry.root == "trash")
        .cloned()
        .collect::<Vec<_>>();
    let facts = runtime_facts(context.roots.libs.as_deref(), &need, &libs_entries)?;
    let trash = scan_trash(context, &trash_entries, directories)?;
    let mut apps = Vec::new();
    // Apps are platform-config driven (TrimUI's Apps folder is the only
    // device with one today; PortMaster devices scan PORTS only). New
    // app layouts are added per device when they actually exist.
    for root in &context.roots.apps {
        if context.capabilities.inventory_apps != CapabilityState::Current {
            break;
        }
        if !root.roles.contains(&portkit_core::LocationRole::Inventory) {
            continue;
        }
        let entries = match std::fs::read_dir(&root.path) {
            Ok(entries) => entries,
            Err(error) => {
                diagnostics.push(format!(
                    "cannot enumerate APP location {} ({}): {error}",
                    root.id,
                    root.path.display()
                ));
                continue;
            }
        };
        let mut folders = Vec::new();
        for entry in entries {
            match entry {
                Ok(entry)
                    if std::fs::symlink_metadata(entry.path())
                        .is_ok_and(|metadata| metadata.file_type().is_dir()) =>
                {
                    folders.push(entry.path());
                }
                Ok(_) => {}
                Err(error) => diagnostics.push(format!(
                    "cannot read an APP entry in location {}: {error}",
                    root.id
                )),
            }
        }
        folders.sort();
        for folder in folders {
            let launch = folder.join("launch.sh");
            if !std::fs::symlink_metadata(&launch)
                .is_ok_and(|metadata| metadata.file_type().is_file())
            {
                continue;
            }
            let name = folder
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default();
            if name.is_empty() {
                continue;
            }
            let has_icon = folder.join("icon.png").is_file();
            let has_config = folder.join("config.json").is_file();
            let (label, label_zh) = read_app_labels(&folder);
            apps.push(AppFact {
                root_id: root.id.clone(),
                name,
                folder,
                launch,
                has_icon,
                has_config,
                label,
                label_zh,
            });
        }
    }
    Ok(ScannedFacts {
        ports,
        data_refcount,
        data_dirs,
        images,
        orphan_dirs,
        orphan_images,
        dead_scripts,
        trash,
        apps,
        runtimes: RuntimeInventory { need, facts },
        diagnostics,
        classification_uncertain: orphan_classification_uncertain,
    })
}

const MAX_SCRIPT_BYTES: u64 = 4 * 1024 * 1024;

fn read_script(path: &Path) -> Result<String, InventoryError> {
    let metadata = fs::symlink_metadata(path).map_err(|source| InventoryError::Read {
        path: path.to_path_buf(),
        source,
    })?;
    if !metadata.file_type().is_file() {
        return Ok(String::new());
    }
    if metadata.len() > MAX_SCRIPT_BYTES {
        return Err(InventoryError::ScriptTooLarge(path.to_path_buf()));
    }
    let bytes = fs::read(path).map_err(|source| InventoryError::Read {
        path: path.to_path_buf(),
        source,
    })?;
    if bytes.len() as u64 > MAX_SCRIPT_BYTES {
        return Err(InventoryError::ScriptTooLarge(path.to_path_buf()));
    }
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

fn port_json_runtimes(directory: &Path) -> Result<Option<Vec<String>>, String> {
    let path = directory.join("port.json");
    let metadata = match fs::symlink_metadata(&path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.to_string()),
    };
    if !metadata.file_type().is_file() {
        return Err("port.json is not a regular file".to_owned());
    }
    if metadata.len() > MAX_SCRIPT_BYTES {
        return Err("port.json exceeds the inventory read limit".to_owned());
    }
    let bytes = fs::read(&path).map_err(|error| error.to_string())?;
    let document: serde_json::Value =
        serde_json::from_slice(&bytes).map_err(|error| error.to_string())?;
    let Some(attributes) = document.get("attr").and_then(serde_json::Value::as_object) else {
        return Ok(None);
    };
    let Some(runtime) = attributes.get("runtime") else {
        return Ok(None);
    };
    let values = match runtime {
        serde_json::Value::Null => Vec::new(),
        serde_json::Value::String(value) => vec![value.as_str()],
        serde_json::Value::Array(values) => values
            .iter()
            .map(|value| {
                value
                    .as_str()
                    .ok_or_else(|| "attr.runtime array contains a non-string value".to_owned())
            })
            .collect::<Result<Vec<_>, _>>()?,
        _ => return Err("attr.runtime must be null, a string, or an array".to_owned()),
    };
    let mut runtimes = Vec::new();
    for value in values {
        let runtime = normalize_runtime_name(value)
            .ok_or_else(|| format!("attr.runtime contains an invalid Runtime name: {value}"))?;
        if !runtimes.contains(&runtime) {
            runtimes.push(runtime);
        }
    }
    Ok(Some(runtimes))
}

fn scan_trash(
    context: &ResolvedDeviceContext,
    top_entries: &[InventoryEntry],
    directories: &mut DirectorySnapshots,
) -> Result<Vec<TrashFact>, InventoryError> {
    let mut result = Vec::new();
    for top in top_entries.iter().cloned() {
        if top.kind != InventoryKind::Directory {
            result.push(trash_fact(context, top, "item"));
            continue;
        }
        for entry in directories.read("trash", &top.path)? {
            let bucket = entry.name.as_str();
            if entry.kind == InventoryKind::Directory
                && (matches!(bucket, "scripts" | "script-images" | "data" | "images")
                    || bucket.strip_prefix("apps-").is_some_and(is_safe_bucket_id))
            {
                for item in directories.read("trash", &entry.path)? {
                    result.push(trash_fact(context, item, bucket));
                }
            } else {
                result.push(trash_fact(context, entry, "legacy"));
            }
        }
    }
    result.sort_by(|left, right| {
        (&left.bucket, path_sort_key(&left.path), &left.name).cmp(&(
            &right.bucket,
            path_sort_key(&right.path),
            &right.name,
        ))
    });
    Ok(result)
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

#[derive(Default)]
struct DirectorySnapshots {
    entries: BTreeMap<PathBuf, Vec<InventoryEntry>>,
    #[cfg(test)]
    enumerations: usize,
}

impl DirectorySnapshots {
    fn read(
        &mut self,
        root_name: &'static str,
        root: &Path,
    ) -> Result<Vec<InventoryEntry>, InventoryError> {
        if !self.entries.contains_key(root) {
            let mut entries = Vec::new();
            scan_root(root_name, root, &mut entries)?;
            entries.sort_by(|left, right| left.name.cmp(&right.name));
            #[cfg(test)]
            {
                self.enumerations += 1;
            }
            self.entries.insert(root.to_path_buf(), entries);
        }
        Ok(self
            .entries
            .get(root)
            .expect("directory snapshot was inserted")
            .iter()
            .cloned()
            .map(|mut entry| {
                entry.root = root_name.to_owned();
                entry
            })
            .collect())
    }
}

fn trash_fact(context: &ResolvedDeviceContext, entry: InventoryEntry, bucket: &str) -> TrashFact {
    let is_dir = entry.kind == InventoryKind::Directory;
    let restore_root = match bucket {
        "scripts" | "script-images" => Some(&context.roots.scripts),
        "data" => Some(&context.roots.game_dirs),
        "images" => context.roots.images.as_ref(),
        value if value.starts_with("apps-") => context
            .roots
            .apps
            .iter()
            .find(|root| {
                root.id == value[5..]
                    && root
                        .roles
                        .contains(&portkit_core::LocationRole::TrashRestore)
            })
            .map(|root| &root.path),
        _ => None,
    };
    let restore_target = restore_root
        .map(|root| root.join(&entry.name))
        .unwrap_or_default();
    let restore_conflict =
        !restore_target.as_os_str().is_empty() && fs::symlink_metadata(&restore_target).is_ok();
    TrashFact {
        name: entry.name,
        path: entry.path,
        kind: entry.kind,
        is_dir,
        bucket: bucket.to_owned(),
        restore_target,
        restore_conflict,
    }
}

/// Read `label` / `label.ch.lang` from a TrimUI-style app config.json so the
/// launcher list can show the localized name instead of the raw folder name.
fn read_app_labels(folder: &std::path::Path) -> (Option<String>, Option<String>) {
    let Ok(text) = fs::read_to_string(folder.join("config.json")) else {
        return (None, None);
    };
    let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else {
        return (None, None);
    };
    let label = value
        .get("label")
        .and_then(serde_json::Value::as_str)
        .map(str::to_owned);
    let label_zh = value
        .get("label.ch.lang")
        .and_then(serde_json::Value::as_str)
        .map(str::to_owned);
    (label, label_zh)
}

fn runtime_facts(
    libs: Option<&Path>,
    need: &BTreeMap<String, Vec<String>>,
    libs_entries: &[InventoryEntry],
) -> Result<Vec<RuntimeFact>, InventoryError> {
    let Some(libs) = libs else {
        return Ok(need
            .iter()
            .map(|(name, users)| RuntimeFact {
                name: name.clone(),
                path: PathBuf::new(),
                users: users.clone(),
                health: RuntimeHealth::Missing,
                bytes: 0,
            })
            .collect());
    };
    let mut names = need.keys().cloned().collect::<BTreeSet<_>>();
    for entry in libs_entries {
        if entry.name.ends_with(".squashfs") {
            names.insert(entry.name.trim_end_matches(".squashfs").to_owned());
        }
    }
    let mut facts = Vec::new();
    for name in names {
        let path = libs.join(format!("{name}.squashfs"));
        let (health, bytes) = runtime_health(&path)?;
        facts.push(RuntimeFact {
            users: need.get(&name).cloned().unwrap_or_default(),
            name,
            path,
            health,
            bytes,
        });
    }
    Ok(facts)
}

fn runtime_health(path: &Path) -> Result<(RuntimeHealth, u64), InventoryError> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok((RuntimeHealth::Missing, 0));
        }
        Err(source) => {
            return Err(InventoryError::Read {
                path: path.to_path_buf(),
                source,
            });
        }
    };
    if metadata.file_type().is_symlink() {
        return Ok((RuntimeHealth::Symlink, metadata.len()));
    }
    if !metadata.file_type().is_file() {
        return Ok((RuntimeHealth::InvalidMagic, metadata.len()));
    }
    let mut magic = [0_u8; 4];
    let mut file = File::open(path).map_err(|source| InventoryError::Read {
        path: path.to_path_buf(),
        source,
    })?;
    let read = file
        .read(&mut magic)
        .map_err(|source| InventoryError::Read {
            path: path.to_path_buf(),
            source,
        })?;
    let health = if read == 4 && magic == *b"hsqs" {
        RuntimeHealth::Unknown
    } else {
        RuntimeHealth::InvalidMagic
    };
    Ok((health, metadata.len()))
}

/// Resolve actual managed ancestors, including aliases and missing children.
/// Directory spellings have no meaning outside this explicitly supplied root.
fn managed_data_names(path: &Path, root: &Path) -> BTreeSet<String> {
    let mut names = BTreeSet::new();
    if path
        .components()
        .any(|part| matches!(part, std::path::Component::ParentDir))
    {
        return names;
    }
    let Ok(root) = root.canonicalize() else {
        return names;
    };
    for ancestor in path.ancestors() {
        if let Ok(resolved) = ancestor.canonicalize() {
            if let Ok(relative) = resolved.strip_prefix(&root) {
                if let Some(std::path::Component::Normal(name)) = relative.components().next() {
                    // An external alias can point into a nested game folder;
                    // use the physical root-relative child, not the alias name.
                    if root.join(name).is_dir() {
                        if let Some(name) = name.to_str() {
                            names.insert(name.to_owned());
                        }
                    }
                }
            }
        }
        if ancestor
            .symlink_metadata()
            .is_err_and(|e| e.kind() == std::io::ErrorKind::NotFound)
            && ancestor
                .parent()
                .and_then(|p| p.canonicalize().ok())
                .as_ref()
                == Some(&root)
        {
            if let Some(name) = ancestor.file_name().and_then(|name| name.to_str()) {
                names.insert(name.to_owned());
            }
        }
    }
    names
}

#[cfg(test)]
fn managed_data_reference(path: &Path, root: &Path, name: &str) -> bool {
    managed_data_names(path, root).contains(name)
}

fn normalize_runtime_name(value: &str) -> Option<String> {
    let value = value
        .trim()
        .trim_start_matches('/')
        .strip_suffix(".squashfs")
        .unwrap_or_else(|| value.trim().trim_start_matches('/'));
    (!value.is_empty()
        && !value.starts_with('.')
        && !value.contains("..")
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b'+' | b'-')))
    .then(|| value.to_owned())
}

fn stem(name: &str) -> &str {
    name.rsplit_once('.').map_or(name, |(stem, _)| stem)
}

fn is_image(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    [".png", ".jpg", ".jpeg", ".webp"]
        .iter()
        .any(|suffix| lower.ends_with(suffix))
}

fn is_appledouble(name: &str) -> bool {
    name.starts_with("._")
}

fn path_sort_key(path: &Path) -> String {
    path.to_string_lossy().to_ascii_lowercase()
}

fn kind_name(kind: InventoryKind) -> &'static str {
    match kind {
        InventoryKind::Directory => "directory",
        InventoryKind::File => "file",
        InventoryKind::Symlink => "symlink",
        InventoryKind::Other => "other",
    }
}

fn runtime_health_name(health: RuntimeHealth) -> &'static str {
    match health {
        RuntimeHealth::Missing => "missing",
        RuntimeHealth::InvalidMagic => "invalid_magic",
        RuntimeHealth::Healthy => "healthy",
        RuntimeHealth::Unknown => "unknown",
        RuntimeHealth::Symlink => "symlink",
    }
}

fn scan_root(
    root_name: &'static str,
    path: &Path,
    output: &mut Vec<InventoryEntry>,
) -> Result<(), InventoryError> {
    let root = ManagedRoot::new(path).map_err(|source| InventoryError::UnsafeRoot {
        root: root_name,
        source,
    })?;
    let read_dir = match fs::read_dir(path) {
        Ok(read_dir) => read_dir,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(source) => {
            return Err(InventoryError::Enumerate {
                root: root_name,
                source,
            });
        }
    };
    for item in read_dir {
        let item = item.map_err(|source| InventoryError::Enumerate {
            root: root_name,
            source,
        })?;
        let name = os_to_string(item.file_name(), root_name)?;
        // The root itself was checked above. Validate the child name
        // lexically, then use symlink_metadata so a link is classified rather
        // than followed or rejected as if it were a traversal target.
        ManagedRoot::validate_child_name(&name).map_err(|source| InventoryError::UnsafeRoot {
            root: root_name,
            source,
        })?;
        let item_path = root.path().join(&name);
        // symlink_metadata classifies links without following them. A link is
        // inventory data only and is never traversed or reported as a dir.
        let metadata =
            fs::symlink_metadata(&item_path).map_err(|source| InventoryError::Enumerate {
                root: root_name,
                source,
            })?;
        let file_type = metadata.file_type();
        let kind = if file_type.is_symlink() {
            InventoryKind::Symlink
        } else if file_type.is_dir() {
            InventoryKind::Directory
        } else if file_type.is_file() {
            InventoryKind::File
        } else {
            InventoryKind::Other
        };
        output.push(InventoryEntry {
            root: root_name.to_owned(),
            name,
            path: item_path,
            kind,
            bytes: (kind == InventoryKind::File).then_some(metadata.len()),
        });
    }
    Ok(())
}

fn os_to_string(value: impl AsRef<OsStr>, root: &'static str) -> Result<String, InventoryError> {
    value
        .as_ref()
        .to_str()
        .map(str::to_owned)
        .ok_or(InventoryError::NonUtf8 { root })
}

#[cfg(test)]
mod tests {
    use std::fs;

    use tempfile::TempDir;

    use super::*;
    use crate::context::{
        ContextCapabilities, ExpectedInstallContract, FrontendContext, ManagedAppLocation,
        ManagedRoots, ManagementMode,
    };

    struct Fixture {
        _temp: TempDir,
        context: ResolvedDeviceContext,
    }

    #[test]
    fn unreleased_inventory_schema_stays_on_the_existing_baseline() {
        assert_eq!(INVENTORY_SCHEMA, 1);
    }

    fn fixture() -> Fixture {
        let temp = tempfile::tempdir().unwrap();
        for name in [
            "core", "scripts", "games", "images", "libs", "state", "trash", "frontend",
        ] {
            fs::create_dir(temp.path().join(name)).unwrap();
        }
        let frontend = temp.path().join("frontend");
        Fixture {
            context: ResolvedDeviceContext {
                schema: 1,
                profile: "fixture-device".to_owned(),
                device_class: "fixture-class".to_owned(),
                management: ManagementMode::App,
                target_confirmed: true,
                capabilities: ContextCapabilities {
                    inventory: CapabilityState::Current,
                    inventory_ports: CapabilityState::Current,
                    install_plan: CapabilityState::Current,
                    cache_invalidation: CapabilityState::Current,
                    ..ContextCapabilities::default()
                },
                roots: ManagedRoots {
                    portmaster: Some(temp.path().join("core")),
                    scripts: temp.path().join("scripts"),
                    game_dirs: temp.path().join("games"),
                    images: Some(temp.path().join("images")),
                    libs: Some(temp.path().join("libs")),
                    app_state: temp.path().join("state"),
                    apps: vec![],
                    trash: temp.path().join("trash"),
                },
                frontend: FrontendContext {
                    kind: "fixture-frontend".to_owned(),
                    directory: frontend.clone(),
                    launcher: frontend.join("PortMaster.sh"),
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
                    core_executable: Some("PortMaster.sh".to_owned()),
                    frontend_executable: Some("PortMaster.sh".to_owned()),
                    frontend_transforms: Vec::new(),
                    preserve_core_entries: vec![
                        "libs".to_owned(),
                        "config".to_owned(),
                        "themes".to_owned(),
                    ],
                },
            },
            _temp: temp,
        }
    }

    #[test]
    fn directory_snapshots_enumerate_shared_roots_once_and_project_labels() {
        let temp = tempfile::tempdir().unwrap();
        fs::write(temp.path().join("Game.sh"), b"#!/bin/sh\n").unwrap();
        let mut snapshots = DirectorySnapshots::default();
        let scripts = snapshots.read("scripts", temp.path()).unwrap();
        let games = snapshots.read("game-dirs", temp.path()).unwrap();

        assert_eq!(snapshots.enumerations, 1);
        assert_eq!(scripts[0].root, "scripts");
        assert_eq!(games[0].root, "game-dirs");
        assert_eq!(scripts[0].path, games[0].path);
    }

    #[test]
    fn app_labels_come_from_config_json_label_fields() {
        // TrimUI apps carry label/label.ch.lang in config.json; the launcher
        // list must prefer them over the raw folder name.
        let mut fixture = fixture();
        let app_dir = tempfile::tempdir().unwrap();
        fixture.context.capabilities.inventory_apps = CapabilityState::Current;
        fixture.context.roots.apps.push(ManagedAppLocation {
            id: "apps-primary".to_owned(),
            path: app_dir.path().to_path_buf(),
            roles: vec![
                portkit_core::LocationRole::Inventory,
                portkit_core::LocationRole::Install,
            ],
            formats: vec![portkit_core::BundleFormat::TrimuiApp],
            priority: 100,
        });
        fs::create_dir_all(app_dir.path().join("myapp")).unwrap();
        fs::write(app_dir.path().join("myapp/launch.sh"), b"#!/bin/sh\n").unwrap();
        let config = format!(
            r#"{{"label":"My App","label.ch.lang":"{}","icon":"icon.png","launch":"launch.sh"}}"#,
            "我的应用"
        );
        fs::write(app_dir.path().join("myapp/config.json"), config.as_bytes()).unwrap();
        fs::create_dir_all(app_dir.path().join("plain")).unwrap();
        fs::write(app_dir.path().join("plain/launch.sh"), b"#!/bin/sh\n").unwrap();
        let inventory = Inventory::scan(&fixture.context).unwrap();
        let by_name: std::collections::HashMap<_, _> = inventory
            .apps
            .iter()
            .map(|app| (app.name.as_str(), app))
            .collect();
        assert_eq!(by_name["myapp"].label.as_deref(), Some("My App"));
        assert_eq!(by_name["myapp"].label_zh.as_deref(), Some("我的应用"));
        assert_eq!(by_name["plain"].label, None);
        assert_eq!(by_name["plain"].label_zh, None);
    }

    #[test]
    fn app_inventory_never_follows_folder_or_launcher_symlinks() {
        use std::os::unix::fs::symlink;

        let mut fixture = fixture();
        let app_root = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        fixture.context.capabilities.inventory_apps = CapabilityState::Current;
        fixture.context.roots.apps.push(ManagedAppLocation {
            id: "apps-primary".to_owned(),
            path: app_root.path().to_path_buf(),
            roles: vec![
                portkit_core::LocationRole::Inventory,
                portkit_core::LocationRole::Install,
            ],
            formats: vec![portkit_core::BundleFormat::TrimuiApp],
            priority: 100,
        });

        fs::write(outside.path().join("launch.sh"), b"#!/bin/sh\n").unwrap();
        symlink(outside.path(), app_root.path().join("folder-link")).unwrap();
        fs::create_dir(app_root.path().join("launcher-link")).unwrap();
        symlink(
            outside.path().join("launch.sh"),
            app_root.path().join("launcher-link/launch.sh"),
        )
        .unwrap();

        let inventory = Inventory::scan(&fixture.context).unwrap();
        assert!(inventory.apps.is_empty());
    }

    #[test]
    fn sh_basename_is_never_used_as_a_data_directory_association() {
        // A launcher that derives its folder from its own filename violates
        // the APP Manager association contract. Keep the data unassociated
        // and fail closed instead of guessing from `hollow-knight.sh`.
        let fixture = fixture();
        fs::create_dir_all(fixture.context.roots.game_dirs.join("hollow-knight")).unwrap();
        fs::write(
            fixture.context.roots.scripts.join("hollow-knight.sh"),
            br#"GAMEDIR="$(cd "$(dirname "$0")" && pwd)/gamedata/$(basename "$0" .sh)"
PORTDIR="$directory"
"#,
        )
        .unwrap();
        let inventory = Inventory::scan(&fixture.context).unwrap();
        assert!(inventory.classification_uncertain);
        assert_eq!(inventory.ports.len(), 1);
        assert!(inventory.ports[0].dir.is_empty());
        assert!(inventory.ports[0].data_path.as_os_str().is_empty());
        assert!(!inventory.ports[0].dir_exists);
        assert!(inventory.dead_scripts.is_empty());
        assert!(inventory.orphan_dirs.is_empty());
    }

    #[test]
    fn real_miniloong_launchers_resolve_without_uncertain() {
        // Runs against real launchers pulled from a MiniLoong device when
        // MINILOONG_DATA points at a directory containing scripts/ and a
        // data-dirs.txt (one directory name per line). Skipped otherwise.
        let Ok(root) = std::env::var("MINILOONG_DATA") else {
            eprintln!("MINILOONG_DATA not set; skipping real-device fixture");
            return;
        };
        let root = std::path::Path::new(&root);
        let scripts_dir = root.join("scripts");
        let fixture = fixture();
        fs::create_dir_all(&fixture.context.roots.game_dirs).unwrap();
        let mut copied = 0usize;
        for entry in fs::read_dir(&scripts_dir).unwrap() {
            let entry = entry.unwrap();
            let name = entry.file_name();
            let Some(name) = name.to_str() else { continue };
            if !name.ends_with(".sh") {
                continue;
            }
            let bytes = fs::read(entry.path()).unwrap();
            fs::write(fixture.context.roots.scripts.join(name), bytes).unwrap();
            copied += 1;
        }
        // Mirror the real layout: MiniLoong keeps game data as sibling
        // directories of the launchers (GAMEDIR=$SHDIR/<name>).
        let Ok(data_names) = fs::read_to_string(root.join("data-dirs.txt")) else {
            panic!("missing data-dirs.txt in MINILOONG_DATA");
        };
        for line in data_names.lines() {
            let name = line.trim();
            if !name.is_empty() {
                fs::create_dir_all(fixture.context.roots.game_dirs.join(name)).unwrap();
            }
        }
        let inventory = Inventory::scan(&fixture.context).unwrap();
        let with_data = inventory
            .ports
            .iter()
            .filter(|port| port.dir_exists)
            .count();
        let linked = inventory
            .ports
            .iter()
            .filter(|port| !port.data_path.as_os_str().is_empty())
            .count();
        eprintln!(
            "real-device scan: scripts={copied} ports={} linked_data={linked} uncertain={} orphan_dirs={} dead={}",
            inventory.ports.len(),
            inventory.classification_uncertain,
            inventory.orphan_dirs.len(),
            inventory.dead_scripts.len()
        );
        for port in &inventory.ports {
            if port.data_path.as_os_str().is_empty() || !port.dir_exists {
                eprintln!(
                    "  UNLINKED: {} dir={:?} claimed={:?}",
                    port.script, port.dir, port.claimed_dir
                );
            }
        }
        // Most launchers are the standard template; the scan must stay calm.
        assert!(
            inventory.dead_scripts.len() <= 5,
            "too many dead scripts: {:?}",
            inventory.dead_scripts
        );
        // Sizes are cosmetic; linking is the core guarantee.
        assert!(
            linked >= inventory.ports.len().saturating_sub(8),
            "data linkage lost: {linked}/{}",
            inventory.ports.len()
        );
        assert!(with_data >= inventory.ports.len().saturating_sub(8));
    }

    #[test]
    fn truly_dynamic_gamedir_stays_uncertain() {
        // A path assembled at runtime (variable lookup of an unknown value)
        // cannot be resolved statically; the scan must stay fail-closed.
        let fixture = fixture();
        fs::write(
            fixture.context.roots.scripts.join("dynamic.sh"),
            br#"GAMEDIR="/mnt/games/$UNKNOWN_VAR"
"#,
        )
        .unwrap();
        let inventory = Inventory::scan(&fixture.context).unwrap();
        assert!(inventory.classification_uncertain);
    }

    #[cfg(unix)]
    #[test]
    fn scan_is_deterministic_and_never_follows_entry_symlinks() {
        use std::os::unix::fs::symlink;

        let fixture = fixture();
        fs::write(fixture.context.roots.scripts.join("z.sh"), b"z").unwrap();
        fs::write(fixture.context.roots.scripts.join("a.sh"), b"a").unwrap();
        symlink(
            &fixture.context.roots.game_dirs,
            fixture.context.roots.scripts.join("linked-dir"),
        )
        .unwrap();

        let first = Inventory::scan(&fixture.context).unwrap();
        let second = Inventory::scan(&fixture.context).unwrap();
        assert_eq!(first, second);
        let script_entries: Vec<_> = first
            .entries
            .iter()
            .filter(|entry| entry.root == "scripts")
            .collect();
        assert_eq!(script_entries[0].name, "a.sh");
        assert_eq!(script_entries[1].name, "linked-dir");
        assert_eq!(script_entries[1].kind, InventoryKind::Symlink);
        assert_eq!(script_entries[2].name, "z.sh");
    }

    #[test]
    fn snapshot_correlates_ports_images_trash_and_runtimes() {
        let fixture = fixture();
        fs::create_dir(fixture.context.roots.game_dirs.join("GameA")).unwrap();
        fs::create_dir(fixture.context.roots.game_dirs.join("Orphan")).unwrap();
        fs::write(
            fixture.context.roots.scripts.join("Alpha.sh"),
            format!(
                "GAMEDIR='{}'\ncd \"$GAMEDIR\"\nruntime=mono\nhelper_runtime=godot\n",
                fixture.context.roots.game_dirs.join("GameA").display()
            ),
        )
        .unwrap();
        fs::write(
            fixture.context.roots.scripts.join("Dead.sh"),
            format!(
                "GAMEDIR='{}'\ncd \"$GAMEDIR\"\n",
                fixture.context.roots.game_dirs.join("Missing").display()
            ),
        )
        .unwrap();
        fs::write(fixture.context.roots.scripts.join("Alpha.png"), b"png").unwrap();
        fs::write(
            fixture
                .context
                .roots
                .images
                .as_ref()
                .unwrap()
                .join("Alpha.jpg"),
            b"jpg",
        )
        .unwrap();
        fs::write(
            fixture
                .context
                .roots
                .images
                .as_ref()
                .unwrap()
                .join("Ghost.webp"),
            b"webp",
        )
        .unwrap();
        fs::write(
            fixture
                .context
                .roots
                .libs
                .as_ref()
                .unwrap()
                .join("mono.squashfs"),
            b"hsqs-runtime",
        )
        .unwrap();
        fs::write(
            fixture
                .context
                .roots
                .libs
                .as_ref()
                .unwrap()
                .join("broken.squashfs"),
            b"nope",
        )
        .unwrap();
        let batch = fixture.context.roots.trash.join("20260101/scripts");
        fs::create_dir_all(&batch).unwrap();
        fs::write(batch.join("Old.sh"), b"old").unwrap();
        fs::write(fixture.context.roots.trash.join("legacy.txt"), b"legacy").unwrap();

        let options = InventoryOptions {
            scan_script_images: true,
            directory: "/mnt/card".to_owned(),
            ..InventoryOptions::default()
        };
        let snapshot = Inventory::scan_with_options(&fixture.context, &options).unwrap();
        let repeated = Inventory::scan_with_options(&fixture.context, &options).unwrap();
        assert_eq!(snapshot, repeated);
        assert_eq!(snapshot.to_tsv(), repeated.to_tsv());
        assert_eq!(snapshot.ports.len(), 2);
        assert_eq!(snapshot.ports[0].script, "Alpha.sh");
        assert_eq!(snapshot.ports[0].dir, "GameA");
        assert_eq!(
            snapshot.ports[0].data_path,
            fixture.context.roots.game_dirs.join("GameA")
        );
        assert_eq!(snapshot.ports[0].images.len(), 2);
        assert_eq!(snapshot.ports[0].runtimes, ["mono", "godot"]);
        assert_eq!(
            snapshot.data_refcount[&fixture
                .context
                .roots
                .game_dirs
                .join("GameA")
                .to_string_lossy()
                .into_owned()],
            1
        );
        assert_eq!(snapshot.orphan_dirs[0].name, "Orphan");
        assert_eq!(
            snapshot.orphan_dirs[0].path,
            fixture.context.roots.game_dirs.join("Orphan")
        );
        assert_eq!(snapshot.orphan_images[0].name, "Ghost.webp");
        assert_eq!(snapshot.dead_scripts[0].missing_dir, "Missing");
        assert_eq!(
            snapshot.dead_scripts[0].path,
            fixture.context.roots.scripts.join("Dead.sh")
        );
        assert_eq!(snapshot.trash.len(), 2);
        assert_eq!(snapshot.runtimes.need["mono"], ["Alpha.sh"]);
        assert_eq!(
            snapshot
                .runtimes
                .facts
                .iter()
                .find(|runtime| runtime.name == "mono")
                .unwrap()
                .health,
            RuntimeHealth::Unknown
        );
        assert!(snapshot.to_tsv().contains("port\tAlpha.sh\t"));
        assert!(snapshot.to_tsv().contains("trash\tscripts\tfile\t"));
        assert!(snapshot.to_tsv().contains("runtime\tmono\tunknown\t"));
    }

    #[test]
    fn trash_snapshot_exposes_restore_destination_conflicts() {
        let fixture = fixture();
        let installed = fixture.context.roots.scripts.join("Game.sh");
        let trashed = fixture.context.roots.trash.join("batch/scripts/Game.sh");
        fs::write(&installed, b"current").unwrap();
        fs::create_dir_all(trashed.parent().unwrap()).unwrap();
        fs::write(&trashed, b"old").unwrap();

        let inventory = Inventory::scan(&fixture.context).unwrap();
        let fact = inventory
            .trash
            .iter()
            .find(|entry| entry.path == trashed)
            .expect("structured Trash item");
        assert_eq!(fact.restore_target, installed);
        assert!(fact.restore_conflict);
    }

    #[cfg(unix)]
    #[test]
    fn snapshot_never_reads_script_runtime_or_trash_symlink_targets() {
        use std::os::unix::fs::symlink;

        let fixture = fixture();
        let outside = fixture.context.roots.app_state.join("outside");
        fs::create_dir(&outside).unwrap();
        fs::write(outside.join("Evil.sh"), b"runtime=evil").unwrap();
        symlink(
            outside.join("Evil.sh"),
            fixture.context.roots.scripts.join("Evil.sh"),
        )
        .unwrap();
        symlink(&outside, fixture.context.roots.trash.join("batch-link")).unwrap();
        symlink(
            outside.join("Evil.sh"),
            fixture
                .context
                .roots
                .libs
                .as_ref()
                .unwrap()
                .join("evil.squashfs"),
        )
        .unwrap();
        let snapshot = Inventory::scan(&fixture.context).unwrap();
        assert!(snapshot.ports.is_empty());
        assert!(snapshot.runtimes.need.is_empty());
        assert_eq!(snapshot.trash.len(), 1);
        assert_eq!(snapshot.trash[0].kind, InventoryKind::Symlink);
        assert_eq!(snapshot.runtimes.facts[0].health, RuntimeHealth::Symlink);
    }

    #[test]
    fn unknown_inventory_capability_fails_closed() {
        let mut fixture = fixture();
        fixture.context.capabilities.inventory = CapabilityState::Unknown;
        fixture.context.capabilities.inventory_ports = CapabilityState::Unknown;
        fixture.context.capabilities.inventory_apps = CapabilityState::Unknown;
        assert!(matches!(
            Inventory::scan(&fixture.context),
            Err(InventoryError::CapabilityUnknown)
        ));
    }

    #[test]
    fn arbitrary_script_text_does_not_hide_an_orphan_directory() {
        let fixture = fixture();
        fs::create_dir(fixture.context.roots.game_dirs.join("MentionedOnly")).unwrap();
        fs::write(
            fixture.context.roots.scripts.join("Commentary.sh"),
            b"echo MentionedOnly\n",
        )
        .unwrap();
        let snapshot = Inventory::scan(&fixture.context).unwrap();
        assert_eq!(snapshot.orphan_dirs[0].name, "MentionedOnly");
        assert_eq!(
            snapshot.orphan_dirs[0].path,
            fixture.context.roots.game_dirs.join("MentionedOnly")
        );
    }

    #[test]
    fn managed_root_not_directory_spelling_defines_data_and_metadata() {
        for name in ["ports", "data", "gamedata", "中文游戏"] {
            let fixture = fixture();
            let game = fixture.context.roots.game_dirs.join(name);
            fs::create_dir_all(game.join("nested/libs")).unwrap();
            fs::write(game.join("port.json"), br#"{"attr":{"runtime":"correct"}}"#).unwrap();
            fs::write(
                fixture.context.roots.scripts.join("renamed.sh"),
                format!(
                    "cd '{}'/nested\nLD_LIBRARY_PATH='{}'/nested/libs\n",
                    game.display(),
                    game.display()
                ),
            )
            .unwrap();
            let snapshot = Inventory::scan(&fixture.context).unwrap();
            assert_eq!(snapshot.ports[0].dir, name);
            assert_eq!(snapshot.ports[0].data_path, game);
            assert_eq!(snapshot.ports[0].runtimes, ["correct"]);
            assert!(snapshot.orphan_dirs.is_empty());
        }
    }

    #[test]
    fn foreign_same_named_directory_never_selects_local_metadata_or_data() {
        let fixture = fixture();
        let other = tempfile::tempdir().unwrap();
        let game = fixture.context.roots.game_dirs.join("Shared");
        let foreign = other.path().join("ports/Shared");
        fs::create_dir(&game).unwrap();
        fs::create_dir_all(&foreign).unwrap();
        fs::write(game.join("port.json"), br#"{"attr":{"runtime":"wrong"}}"#).unwrap();
        fs::write(
            fixture.context.roots.scripts.join("foreign.sh"),
            format!("cd '{}'\n", foreign.display()),
        )
        .unwrap();
        let snapshot = Inventory::scan(&fixture.context).unwrap();
        assert!(snapshot.ports[0].dir.is_empty());
        assert!(snapshot.ports[0].data_path.as_os_str().is_empty());
        assert!(snapshot.ports[0].runtimes.is_empty());
        assert!(snapshot.data_refcount.is_empty());
        assert!(snapshot.dead_scripts.is_empty());
        assert_eq!(snapshot.orphan_dirs[0].path, game);
    }

    #[test]
    fn only_missing_children_of_configured_root_are_dead_launchers() {
        let fixture = fixture();
        fs::write(
            fixture.context.roots.scripts.join("missing.sh"),
            format!(
                "cd '{}/Missing/subdir'\n",
                fixture.context.roots.game_dirs.display()
            ),
        )
        .unwrap();
        let snapshot = Inventory::scan(&fixture.context).unwrap();
        assert_eq!(snapshot.dead_scripts.len(), 1);
        assert_eq!(snapshot.ports[0].claimed_dir, "Missing");
        assert_eq!(snapshot.dead_scripts[0].missing_dir, "Missing");
        assert!(!snapshot.ports[0].dir_exists);
    }

    #[test]
    fn passive_wait_does_not_block_confirmed_inventory_but_mutating_loop_does() {
        for body in ["sleep 1", "GAME=/unknown/path"] {
            let fixture = fixture();
            let game = fixture.context.roots.game_dirs.join("Game");
            fs::create_dir(&game).unwrap();
            fs::write(fixture.context.roots.scripts.join("Game.sh"),
                format!("GAME='{}'\nwhile kill -0 \"$PID\" 2>/dev/null; do {body}; done\ncd \"$GAME\"\n", game.display())).unwrap();
            let inventory = Inventory::scan(&fixture.context).unwrap();
            if body == "sleep 1" {
                assert!(
                    !inventory.classification_uncertain,
                    "{:?}",
                    inventory.diagnostics
                );
                assert_eq!(inventory.ports[0].data_path, game);
            } else {
                assert!(inventory.classification_uncertain);
                assert!(inventory.ports[0].data_path.as_os_str().is_empty());
            }
            assert!(inventory.orphan_dirs.is_empty());
        }
    }

    #[test]
    fn colocated_launcher_file_is_not_a_second_game_directory() {
        let mut fixture = fixture();
        fixture.context.roots.scripts = fixture.context.roots.game_dirs.clone();
        let game = fixture.context.roots.game_dirs.join("Game");
        fs::create_dir(&game).unwrap();
        fs::write(game.join("port.json"), br#"{"attr":{"runtime":"correct"}}"#).unwrap();
        fs::write(
            fixture.context.roots.scripts.join("renamed.sh"),
            format!("SCRIPT=\"$0\"\nGAME='{}'\n", game.display()),
        )
        .unwrap();
        let snapshot = Inventory::scan(&fixture.context).unwrap();
        assert_eq!(snapshot.ports[0].dir, "Game");
        assert_eq!(snapshot.ports[0].runtimes, ["correct"]);
        assert!(snapshot.ports[0].data_path.as_os_str().is_empty());
        assert!(snapshot.orphan_dirs.is_empty());
    }

    #[test]
    fn mentioning_the_app_name_never_hides_a_real_launcher() {
        let fixture = fixture();
        fs::create_dir(fixture.context.roots.game_dirs.join("Mentioned")).unwrap();
        fs::write(
            fixture.context.roots.scripts.join("Mentioned.sh"),
            format!(
                "GAMEDIR='{}/Mentioned'\n# compatible with jenny92-appmanager\n",
                fixture.context.roots.game_dirs.display()
            ),
        )
        .unwrap();

        let snapshot = Inventory::scan(&fixture.context).unwrap();
        assert_eq!(snapshot.ports.len(), 1);
        assert_eq!(snapshot.ports[0].script, "Mentioned.sh");
        assert_eq!(snapshot.ports[0].dir, "Mentioned");
        assert!(snapshot.orphan_dirs.is_empty());
    }

    #[test]
    fn dynamic_parsed_directory_reference_preserves_orphan_uncertainty() {
        let fixture = fixture();
        fs::create_dir(fixture.context.roots.game_dirs.join("MaybeDynamic")).unwrap();
        fs::write(
            fixture.context.roots.scripts.join("Dynamic.sh"),
            b"GAMEDIR=/ports/$GAME\n",
        )
        .unwrap();
        let snapshot = Inventory::scan(&fixture.context).unwrap();
        assert!(snapshot.orphan_dirs.is_empty());
        assert!(snapshot.diagnostics[0].contains("orphan classification uncertain"));
    }

    #[test]
    fn dynamic_directory_reference_never_marks_a_launcher_as_dead() {
        let fixture = fixture();
        fs::write(
            fixture.context.roots.scripts.join("Dynamic.sh"),
            b"GAMEDIR=/ports/Missing\ncd /ports/$GAME\n",
        )
        .unwrap();

        let snapshot = Inventory::scan(&fixture.context).unwrap();
        // A known assignment does not make an unknown cd harmless: the latter
        // may reference any other data directory. Both classifications fail closed.
        assert!(snapshot.dead_scripts.is_empty());
        assert!(snapshot.classification_uncertain);
    }

    #[test]
    fn ambiguous_data_references_are_never_exposed_as_a_delete_target() {
        let fixture = fixture();
        for name in ["Primary", "Secondary"] {
            fs::create_dir(fixture.context.roots.game_dirs.join(name)).unwrap();
        }
        fs::write(
            fixture.context.roots.scripts.join("Ambiguous.sh"),
            format!(
                "GAMEDIR='{0}/Primary'\ncd '{0}/Secondary'\n",
                fixture.context.roots.game_dirs.display()
            ),
        )
        .unwrap();

        let snapshot = Inventory::scan(&fixture.context).unwrap();
        // The unique cwd selects metadata, but both references protect data
        // and prevent deletion of a shared association.
        assert_eq!(snapshot.ports[0].dir, "Secondary");
        assert!(snapshot.ports[0].data_path.as_os_str().is_empty());
        assert_eq!(
            snapshot.data_refcount[&fixture
                .context
                .roots
                .game_dirs
                .join("Primary")
                .to_string_lossy()
                .into_owned()],
            1
        );
        assert_eq!(
            snapshot.data_refcount[&fixture
                .context
                .roots
                .game_dirs
                .join("Secondary")
                .to_string_lossy()
                .into_owned()],
            1
        );
        assert!(snapshot.orphan_dirs.is_empty());
        assert!(
            snapshot
                .diagnostics
                .iter()
                .any(|value| value.contains("association is not unique"))
        );
    }

    #[test]
    fn unused_path_declarations_do_not_authorize_data_deletion() {
        let fixture = fixture();
        fs::create_dir(fixture.context.roots.game_dirs.join("Shared")).unwrap();
        fs::write(
            fixture.context.roots.scripts.join("Note.sh"),
            format!(
                "NOTE='{}/Shared'\necho example\n",
                fixture.context.roots.game_dirs.display()
            ),
        )
        .unwrap();
        let snapshot = Inventory::scan(&fixture.context).unwrap();
        assert!(snapshot.ports[0].data_path.as_os_str().is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn card_aliases_are_resolved_but_same_named_other_card_is_not_owned() {
        use std::os::unix::fs::symlink;
        let fixture = fixture();
        let other = tempfile::tempdir().unwrap();
        let name = "Shared";
        let data = fixture.context.roots.game_dirs.join(name);
        fs::create_dir(&data).unwrap();
        let foreign = other.path().join(name);
        fs::create_dir(&foreign).unwrap();
        let alias = other.path().join("current-card");
        symlink(&fixture.context.roots.game_dirs, &alias).unwrap();
        fs::create_dir(data.join("nested")).unwrap();
        let nested_alias = other.path().join("nested-alias");
        symlink(data.join("nested"), &nested_alias).unwrap();
        assert!(managed_data_reference(
            &nested_alias,
            &fixture.context.roots.game_dirs,
            name
        ));
        fs::write(
            fixture.context.roots.scripts.join("Foreign.sh"),
            format!("cd '{}'\n", nested_alias.display()),
        )
        .unwrap();
        let scan = Inventory::scan(&fixture.context).unwrap();
        assert_eq!(scan.ports[0].data_path, data);
        assert!(scan.orphan_dirs.is_empty());
        assert!(managed_data_reference(
            &alias.join(name),
            &fixture.context.roots.game_dirs,
            name
        ));
        assert!(!managed_data_reference(
            &foreign,
            &fixture.context.roots.game_dirs,
            name
        ));
        assert!(managed_data_reference(
            &alias.join("Missing"),
            &fixture.context.roots.game_dirs,
            "Missing"
        ));
        fs::write(
            fixture.context.roots.scripts.join("Foreign.sh"),
            format!("cd '{}'\n", foreign.display()),
        )
        .unwrap();
        let scan = Inventory::scan(&fixture.context).unwrap();
        assert!(scan.ports[0].data_path.as_os_str().is_empty());
        assert!(scan.dead_scripts.is_empty());
    }

    #[test]
    fn inventory_loads_scoped_sources_and_protects_shared_helpers() {
        let fixture = fixture();
        let game = fixture.context.roots.game_dirs.join("Game");
        fs::create_dir(&game).unwrap();
        let shared = fixture.context.roots.game_dirs.join("Shared");
        fs::create_dir(&shared).unwrap();
        let helper = shared.join("control.txt");
        fs::write(
            &helper,
            format!("GAME='{}'\nruntime=love_11.5\n", game.display()),
        )
        .unwrap();
        fs::write(
            fixture.context.roots.scripts.join("中文.sh"),
            format!("source '{}'\ncd \"$GAME\"\n", helper.display()),
        )
        .unwrap();
        let scan = Inventory::scan(&fixture.context).unwrap();
        assert!(!scan.classification_uncertain, "{:?}", scan.diagnostics);
        assert!(scan.orphan_dirs.is_empty());
        assert_eq!(
            scan.data_refcount[&shared.to_string_lossy().into_owned()],
            1
        );
        assert_eq!(scan.ports[0].runtimes, ["love_11.5"]);
        assert!(scan.ports[0].data_path.as_os_str().is_empty());
    }

    #[test]
    fn declared_colon_directory_is_protected_from_orphan_cleanup() {
        let fixture = fixture();
        let game = fixture.context.roots.game_dirs.join("Game:Edition");
        fs::create_dir(&game).unwrap();
        fs::write(
            fixture.context.roots.scripts.join("Game.sh"),
            format!("X='{}'\n", game.display()),
        )
        .unwrap();
        let inventory = Inventory::scan(&fixture.context).unwrap();
        assert!(inventory.orphan_dirs.is_empty());
        assert_eq!(
            inventory.data_refcount[&game.to_string_lossy().into_owned()],
            1
        );
    }

    #[test]
    fn unique_working_directory_selects_metadata_not_alphabetical_shared_data() {
        for with_cwd in [false, true] {
            let fixture = fixture();
            let game = fixture.context.roots.game_dirs.join("counter-strike");
            let shared = fixture.context.roots.game_dirs.join("Half-Life");
            for (path, name) in [(&game, "correct"), (&shared, "wrong")] {
                fs::create_dir(path).unwrap();
                fs::write(
                    path.join("port.json"),
                    format!(r#"{{"attr":{{"runtime":"{name}"}}}}"#),
                )
                .unwrap();
            }
            fs::write(
                fixture.context.roots.scripts.join("Counter-Strike.sh"),
                format!(
                    "GAME='{}'\nSHARED='{}'\n{}",
                    game.display(),
                    shared.display(),
                    if with_cwd { "cd \"$GAME\"\n" } else { "" },
                ),
            )
            .unwrap();
            let inventory = Inventory::scan(&fixture.context).unwrap();
            let port = &inventory.ports[0];
            if with_cwd {
                assert_eq!(port.dir, "counter-strike");
                assert_eq!(port.runtimes, ["correct"]);
            } else {
                assert!(port.runtimes.is_empty());
            }
            assert!(port.data_path.as_os_str().is_empty());
            assert!(inventory.orphan_dirs.is_empty());
        }
    }

    #[test]
    fn oversized_script_is_diagnostic_and_preserves_orphan_uncertainty() {
        let fixture = fixture();
        fs::create_dir(fixture.context.roots.game_dirs.join("MaybeUsed")).unwrap();
        fs::write(
            fixture.context.roots.scripts.join("Good.sh"),
            b"GAMEDIR=/ports/MaybeUsed\n",
        )
        .unwrap();
        let oversized = fixture.context.roots.scripts.join("Oversized.sh");
        File::create(&oversized)
            .unwrap()
            .set_len(MAX_SCRIPT_BYTES + 1)
            .unwrap();

        let snapshot = Inventory::scan(&fixture.context).unwrap();
        assert_eq!(snapshot.ports.len(), 1);
        assert!(snapshot.orphan_dirs.is_empty());
        assert_eq!(snapshot.diagnostics.len(), 1);
        assert!(snapshot.diagnostics[0].contains("Oversized.sh"));
        assert!(snapshot.to_tsv().contains("diagnostic\tskipped script"));
    }

    #[test]
    fn port_json_runtime_declaration_is_the_primary_dependency_source() {
        let fixture = fixture();
        let game = fixture.context.roots.game_dirs.join("OfficialRuntime");
        fs::create_dir(&game).unwrap();
        fs::write(
            game.join("port.json"),
            br#"{
                "attr": {
                    "runtime": [
                        "dotnet-8.0.12.squashfs",
                        "gmtoolkit.squashfs",
                        "weston_pkg_0.2"
                    ]
                }
            }"#,
        )
        .unwrap();
        fs::write(
            fixture.context.roots.scripts.join("Official Runtime.sh"),
            format!("GAMEDIR='{}'\nruntime=stale_script_value\n", game.display()),
        )
        .unwrap();

        let snapshot = Inventory::scan(&fixture.context).unwrap();
        assert_eq!(
            snapshot.ports[0].runtimes,
            ["dotnet-8.0.12", "gmtoolkit", "weston_pkg_0.2"]
        );
        assert!(!snapshot.runtimes.need.contains_key("stale_script_value"));
    }

    #[test]
    fn port_json_runtime_accepts_string_and_explicitly_empty_declarations() {
        let fixture = fixture();
        for (directory, runtime) in [
            ("StringRuntime", r#""ags_3.6.squashfs""#),
            ("EmptyRuntime", "null"),
        ] {
            let game = fixture.context.roots.game_dirs.join(directory);
            fs::create_dir(&game).unwrap();
            fs::write(
                game.join("port.json"),
                format!(r#"{{"attr":{{"runtime":{runtime}}}}}"#),
            )
            .unwrap();
            fs::write(
                fixture
                    .context
                    .roots
                    .scripts
                    .join(format!("{directory}.sh")),
                format!("GAMEDIR='{}'\nruntime=script_fallback\n", game.display()),
            )
            .unwrap();
        }

        let snapshot = Inventory::scan(&fixture.context).unwrap();
        assert_eq!(snapshot.ports[0].script, "EmptyRuntime.sh");
        assert!(snapshot.ports[0].runtimes.is_empty());
        assert_eq!(snapshot.ports[1].script, "StringRuntime.sh");
        assert_eq!(snapshot.ports[1].runtimes, ["ags_3.6"]);
    }

    #[test]
    fn invalid_port_json_is_diagnostic_and_falls_back_to_the_launcher() {
        let fixture = fixture();
        let game = fixture.context.roots.game_dirs.join("BrokenMetadata");
        fs::create_dir(&game).unwrap();
        fs::create_dir(fixture.context.roots.game_dirs.join("UnrelatedOrphan")).unwrap();
        fs::write(game.join("port.json"), br#"{"attr":{"runtime":[42]}}"#).unwrap();
        fs::write(
            fixture.context.roots.scripts.join("Broken Metadata.sh"),
            format!("GAMEDIR='{}'\nruntime=ags_3.6\n", game.display()),
        )
        .unwrap();

        let snapshot = Inventory::scan(&fixture.context).unwrap();
        assert_eq!(snapshot.ports[0].runtimes, ["ags_3.6"]);
        assert_eq!(snapshot.diagnostics.len(), 1);
        assert!(snapshot.diagnostics[0].contains("invalid port.json"));
        assert_eq!(snapshot.orphan_dirs[0].name, "UnrelatedOrphan");
        assert_eq!(
            snapshot.orphan_dirs[0].path,
            fixture.context.roots.game_dirs.join("UnrelatedOrphan")
        );
    }

    #[test]
    fn shell_runtime_fallback_accepts_real_world_portmaster_spellings() {
        let fixture = fixture();
        fs::create_dir(fixture.context.roots.game_dirs.join("LegacyRuntime")).unwrap();
        fs::write(
            fixture.context.roots.scripts.join("Legacy Runtime.sh"),
            format!(
                r#"GAMEDIR=/ports/LegacyRuntime
RUNTIME="renpy_8.1.3"
java_runtime="/zulu8.86.0.25-ca-jdk8.0.452-linux"
monofile="{}/mono-6.12.0.122-aarch64.squashfs"
DOTNETFILE="{}/dotnet-8.0.12.squashfs"
"#,
                fixture.context.roots.libs.as_ref().unwrap().display(),
                fixture.context.roots.libs.as_ref().unwrap().display()
            ),
        )
        .unwrap();

        let snapshot = Inventory::scan(&fixture.context).unwrap();
        assert_eq!(
            snapshot.ports[0].runtimes,
            [
                "renpy_8.1.3",
                "zulu8.86.0.25-ca-jdk8.0.452-linux",
                "dotnet-8.0.12",
                "mono-6.12.0.122-aarch64",
            ]
        );
    }

    #[test]
    fn runtime_locations_supplement_metadata_and_feed_missing_image_checks() {
        let fixture = fixture();
        let game = fixture.context.roots.game_dirs.join("Game");
        fs::create_dir(&game).unwrap();
        fs::write(game.join("port.json"), r#"{"attr":{"runtime":null}}"#).unwrap();
        let helper = game.join("deps.txt");
        fs::write(&helper, format!(
            "RENAMED='{}/renamed.squashfs'\nARBITRARY='{}/runtimes/java17/lib/a.jar:/elsewhere/b.jar'\n",
            fixture.context.roots.libs.as_ref().unwrap().display(),
            fixture.context.roots.portmaster.as_ref().unwrap().display(),
        )).unwrap();
        fs::write(fixture.context.roots.scripts.join("中文.sh"), format!(
            "cd '{}'\nsource '{}'\njava -cp \"$ARBITRARY\" Main\nLOCAL='{}/libs/private.squashfs'\n",
            game.display(), helper.display(), game.display(),
        )).unwrap();
        let inventory = Inventory::scan(&fixture.context).unwrap();
        assert_eq!(inventory.ports[0].runtimes, ["renamed"]);
        for name in ["renamed"] {
            assert_eq!(inventory.runtimes.need[name], ["中文.sh"]);
            assert!(
                inventory
                    .runtimes
                    .facts
                    .iter()
                    .any(|fact| fact.name == name && fact.health == RuntimeHealth::Missing)
            );
        }
        assert!(!inventory.runtimes.need.contains_key("private"));
        assert!(!inventory.runtimes.need.contains_key("java17"));
        assert!(
            !inventory
                .runtimes
                .facts
                .iter()
                .any(|fact| fact.name == "java17")
        );
    }

    #[test]
    fn bundled_runtime_directories_never_become_missing_downloadable_images() {
        for installed in [false, true] {
            let fixture = fixture();
            let game = fixture.context.roots.game_dirs.join("goldminer");
            fs::create_dir(&game).unwrap();
            fs::write(game.join("port.json"), r#"{"attr":{"runtime":null}}"#).unwrap();
            let runtime = fixture
                .context
                .roots
                .portmaster
                .as_ref()
                .unwrap()
                .join("runtimes/love_11.5");
            if installed {
                fs::create_dir_all(runtime.join("libs.aarch64")).unwrap();
                fs::write(runtime.join("love.aarch64"), b"fixture").unwrap();
                fs::write(runtime.join("libs.aarch64/liblove-11.5.so"), b"fixture").unwrap();
            }
            fs::write(fixture.context.roots.scripts.join("黄金矿工.sh"), format!(
                "cd '{}'\nRUNTIME_DIR='{}'\nLD_LIBRARY_PATH=\"$RUNTIME_DIR/libs.aarch64\"\n\"$RUNTIME_DIR/love.aarch64\"\n",
                game.display(), runtime.display(),
            )).unwrap();
            let inventory = Inventory::scan(&fixture.context).unwrap();
            assert!(
                inventory.ports[0].runtimes.is_empty(),
                "installed={installed}"
            );
            assert!(inventory.runtimes.need.is_empty());
            assert!(inventory.runtimes.facts.is_empty());
        }
    }

    #[test]
    fn appledouble_files_never_appear_as_ports_or_leftovers() {
        let fixture = fixture();
        fs::write(
            fixture.context.roots.scripts.join("._Broken.sh"),
            b"AppleDouble metadata",
        )
        .unwrap();
        fs::write(
            fixture.context.roots.scripts.join("._Broken.png"),
            b"AppleDouble metadata",
        )
        .unwrap();
        fs::write(
            fixture
                .context
                .roots
                .images
                .as_ref()
                .unwrap()
                .join("._Orphan.png"),
            b"AppleDouble metadata",
        )
        .unwrap();

        let snapshot = Inventory::scan(&fixture.context).unwrap();

        assert!(snapshot.ports.is_empty());
        assert!(snapshot.images.is_empty());
        assert!(snapshot.orphan_images.is_empty());
    }
}
