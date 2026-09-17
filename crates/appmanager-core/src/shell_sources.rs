// INPUT:  显式允许的 source 根目录或离线快照
// OUTPUT: SourceEnvironment、SnapshotEnvironment、FileEnvironment
// POS:    Shell 分析的只读输入边界，不提供任何执行能力

use std::collections::{BTreeMap, BTreeSet};
use std::io::Read;
use std::path::{Component, Path, PathBuf};

pub const MAX_FILE_BYTES: usize = 256 * 1024;

/// All device-dependent operations are explicit and mockable. None executes code.
pub trait SourceEnvironment {
    fn read(&self, path: &Path) -> Result<String, String>;
    fn test(&self, path: &Path, operator: &str) -> Option<bool>;
    fn command_output(&self, _command: &str) -> Option<String> {
        None
    }
    fn command_status(&self, command: &str) -> Option<bool> {
        self.command_output(command).map(|_| true)
    }
    fn canonicalize(&self, _path: &Path) -> Option<PathBuf> {
        None
    }
    /// Resolve an image location including a missing tail, without reading its contents.
    fn runtime_location(&self, _path: &Path) -> Option<PathBuf> {
        None
    }
}

#[derive(Default, Clone)]
pub struct SnapshotEnvironment {
    pub files: BTreeMap<PathBuf, String>,
    pub directories: BTreeSet<PathBuf>,
    pub commands: BTreeMap<String, String>,
    pub statuses: BTreeMap<String, bool>,
    pub links: BTreeMap<PathBuf, PathBuf>,
    /// Only a complete test snapshot can conclude an omitted file is absent.
    pub complete: bool,
}

impl SourceEnvironment for SnapshotEnvironment {
    fn read(&self, path: &Path) -> Result<String, String> {
        let value = self
            .files
            .get(path)
            .ok_or_else(|| format!("missing source: {}", path.display()))?;
        if value.len() > MAX_FILE_BYTES {
            return Err("source size limit".into());
        }
        Ok(value.clone())
    }
    fn test(&self, path: &Path, operator: &str) -> Option<bool> {
        let file = self.files.contains_key(path);
        let dir = self.directories.contains(path)
            || self.files.keys().any(|p| p != path && p.starts_with(path));
        let link = self.links.contains_key(path);
        match operator {
            "-f" if file => Some(true),
            "-d" if dir => Some(true),
            "-e" if file || dir || link => Some(true),
            "-L" | "-h" if link => Some(true),
            "-x" if self.complete && !file && !dir && !link => Some(false),
            "-f" | "-d" | "-e" | "-L" | "-h" if self.complete => Some(false),
            _ => None,
        }
    }
    fn command_output(&self, command: &str) -> Option<String> {
        self.commands.get(command).cloned()
    }
    fn command_status(&self, command: &str) -> Option<bool> {
        self.statuses
            .get(command)
            .copied()
            .or_else(|| self.commands.get(command).map(|_| true))
    }
    fn canonicalize(&self, path: &Path) -> Option<PathBuf> {
        self.links.get(path).cloned()
    }
    fn runtime_location(&self, path: &Path) -> Option<PathBuf> {
        let mut path = path.to_owned();
        for _ in 0..16 {
            if !path.is_absolute() || path.components().any(|c| matches!(c, Component::ParentDir)) {
                return None;
            }
            let alias = path.ancestors().find_map(|prefix| {
                self.links
                    .get(prefix)
                    .map(|target| target.join(path.strip_prefix(prefix).unwrap()))
            });
            match alias {
                Some(target) => path = target,
                None if self.complete => return Some(path.components().collect()),
                None => return None,
            }
        }
        None
    }
}

/// Files under explicitly configured script/runtime roots only. Arbitrary HOME
/// files and system configuration are not read as a side effect of source.
pub struct FileEnvironment {
    roots: Vec<(PathBuf, PathBuf)>,
}

impl FileEnvironment {
    pub fn new(roots: impl IntoIterator<Item = PathBuf>) -> Self {
        let roots = roots
            .into_iter()
            .filter_map(|p| {
                if !p.is_absolute() || p == Path::new("/") {
                    return None;
                }
                let canonical = p.canonicalize().ok()?;
                (canonical.is_dir() && canonical != Path::new("/")).then_some((p, canonical))
            })
            .collect();
        Self { roots }
    }

    fn resolve(&self, path: &Path) -> Option<(&Path, PathBuf)> {
        if path.components().any(|p| matches!(p, Component::ParentDir)) {
            return None;
        }
        self.roots.iter().find_map(|(logical, canonical)| {
            let relative = path
                .strip_prefix(logical)
                .or_else(|_| path.strip_prefix(canonical))
                .ok()?;
            Some((canonical.as_path(), relative.to_owned()))
        })
    }
}

impl SourceEnvironment for FileEnvironment {
    fn runtime_location(&self, path: &Path) -> Option<PathBuf> {
        // Metadata only; this does not extend the allowlist for source reads.
        if !path.is_absolute() || path.components().any(|c| matches!(c, Component::ParentDir)) {
            return None;
        }
        let mut ancestor = path;
        let mut tail = Vec::new();
        loop {
            match std::fs::symlink_metadata(ancestor) {
                Ok(_) => {
                    let mut resolved = std::fs::canonicalize(ancestor).ok()?;
                    for part in tail.iter().rev() {
                        resolved.push(part);
                    }
                    return Some(resolved);
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    tail.push(ancestor.file_name()?.to_owned());
                    ancestor = ancestor.parent()?;
                }
                Err(_) => return None,
            }
        }
    }
    fn read(&self, path: &Path) -> Result<String, String> {
        // Extending this allowlist requires an explicit non-secret data contract.
        if !matches!(
            path.extension().and_then(|s| s.to_str()),
            Some("txt" | "sh" | "inc")
        ) && !matches!(
            path.file_name().and_then(|s| s.to_str()),
            Some("tasksetter" | "fallback")
        ) {
            return Err(format!("source type not allowed: {}", path.display()));
        }
        let (root, relative) = self
            .resolve(path)
            .ok_or_else(|| format!("source outside allowed roots: {}", path.display()))?;
        #[cfg(unix)]
        {
            use std::ffi::CString;
            use std::os::fd::{AsRawFd, FromRawFd};
            use std::os::unix::ffi::OsStrExt;
            let name = CString::new(root.as_os_str().as_bytes()).map_err(|_| "source NUL")?;
            let fd = unsafe {
                libc::open(
                    name.as_ptr(),
                    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                )
            };
            if fd < 0 {
                return Err(std::io::Error::last_os_error().to_string());
            }
            let mut file = unsafe { std::fs::File::from_raw_fd(fd) };
            let parts = relative
                .components()
                .filter_map(|c| match c {
                    Component::Normal(p) => Some(p),
                    _ => None,
                })
                .collect::<Vec<_>>();
            for (i, part) in parts.iter().enumerate() {
                let name = CString::new(part.as_bytes()).map_err(|_| "source NUL")?;
                let flags = libc::O_RDONLY
                    | libc::O_NOFOLLOW
                    | libc::O_CLOEXEC
                    | libc::O_NONBLOCK
                    | if i + 1 < parts.len() {
                        libc::O_DIRECTORY
                    } else {
                        0
                    };
                let fd = unsafe { libc::openat(file.as_raw_fd(), name.as_ptr(), flags) };
                if fd < 0 {
                    return Err(std::io::Error::last_os_error().to_string());
                }
                file = unsafe { std::fs::File::from_raw_fd(fd) };
            }
            let meta = file.metadata().map_err(|e| e.to_string())?;
            if !meta.is_file() || meta.len() > MAX_FILE_BYTES as u64 {
                return Err("source type/size limit".into());
            }
            let mut bytes = Vec::new();
            file.take(MAX_FILE_BYTES as u64 + 1)
                .read_to_end(&mut bytes)
                .map_err(|e| e.to_string())?;
            if bytes.len() > MAX_FILE_BYTES {
                return Err("source grew beyond limit".into());
            }
            String::from_utf8(bytes).map_err(|_| "source is not UTF-8".into())
        }
        #[cfg(not(unix))]
        {
            let _ = (root, relative);
            Err("secure source loading unavailable".into())
        }
    }
    fn test(&self, path: &Path, operator: &str) -> Option<bool> {
        let (root, relative) = self.resolve(path)?;
        let physical = root.join(relative);
        let canonical = physical.canonicalize().ok()?;
        if !canonical.starts_with(root) {
            return None;
        }
        let meta = std::fs::metadata(&canonical).ok()?;
        match operator {
            "-d" => Some(meta.is_dir()),
            "-f" => Some(meta.is_file()),
            "-e" => Some(true),
            _ => None,
        }
    }
}
