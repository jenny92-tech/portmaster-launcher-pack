use std::path::{Component, Path, PathBuf};

use thiserror::Error;

#[derive(Debug, Error)]
pub enum PathSafetyError {
    #[error("path must be absolute")]
    NotAbsolute,
    #[error("filesystem root is not a managed root")]
    FilesystemRoot,
    #[error("path contains `.` or `..`")]
    Traversal,
    #[error("path contains an empty or unsafe component")]
    UnsafeComponent,
    #[error("existing path component is a symlink: {0}")]
    Symlink(PathBuf),
    #[error("path is outside managed root {root}")]
    OutsideRoot { root: PathBuf },
    #[error("path must be a direct child of managed root {root}")]
    NotDirectChild { root: PathBuf },
    #[error("path component is not valid UTF-8")]
    NonUtf8,
    #[error("cannot inspect path component {path}: {source}")]
    Inspect {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManagedRoot {
    configured: PathBuf,
    resolved: PathBuf,
}

impl ManagedRoot {
    pub fn new(path: impl AsRef<Path>) -> Result<Self, PathSafetyError> {
        let path = path.as_ref();
        validate_absolute(path)?;
        match std::fs::symlink_metadata(path) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                return Err(PathSafetyError::Symlink(path.to_path_buf()));
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(source) => {
                return Err(PathSafetyError::Inspect {
                    path: path.to_path_buf(),
                    source,
                });
            }
        }
        let resolved = resolve_without_managed_symlink(path)?;
        Ok(Self {
            configured: path.to_path_buf(),
            resolved,
        })
    }

    pub fn path(&self) -> &Path {
        &self.configured
    }

    pub(crate) fn resolved_path(&self) -> &Path {
        &self.resolved
    }

    pub fn validate_descendant(&self, path: impl AsRef<Path>) -> Result<PathBuf, PathSafetyError> {
        let path = path.as_ref();
        validate_absolute(path)?;
        if path == self.configured || !path.starts_with(&self.configured) {
            return Err(PathSafetyError::OutsideRoot {
                root: self.configured.clone(),
            });
        }
        let relative = path.strip_prefix(&self.configured).expect("prefix checked");
        reject_relative_symlinks(&self.resolved, relative)?;
        Ok(path.to_path_buf())
    }

    pub fn validate_direct_child(
        &self,
        path: impl AsRef<Path>,
    ) -> Result<PathBuf, PathSafetyError> {
        let path = self.validate_descendant(path)?;
        if path.parent() != Some(self.configured.as_path()) {
            return Err(PathSafetyError::NotDirectChild {
                root: self.configured.clone(),
            });
        }
        Ok(path)
    }

    pub fn join_child(&self, name: &str) -> Result<PathBuf, PathSafetyError> {
        Self::validate_child_name(name)?;
        self.validate_direct_child(self.configured.join(name))
    }

    pub fn validate_child_name(name: &str) -> Result<(), PathSafetyError> {
        if name.is_empty()
            || name == "."
            || name == ".."
            || name.contains(['/', '\\', '\0', '\t', '\r', '\n'])
        {
            return Err(PathSafetyError::UnsafeComponent);
        }
        let path = Path::new(name);
        let mut components = path.components();
        match (components.next(), components.next()) {
            (Some(Component::Normal(_)), None) => Ok(()),
            _ => Err(PathSafetyError::UnsafeComponent),
        }
    }
}

fn validate_absolute(path: &Path) -> Result<(), PathSafetyError> {
    if !path.is_absolute() {
        return Err(PathSafetyError::NotAbsolute);
    }
    let text = path.to_str().ok_or(PathSafetyError::NonUtf8)?;
    if text.contains("//") || text.contains(['\0', '\t', '\r', '\n']) {
        return Err(PathSafetyError::UnsafeComponent);
    }
    if path.parent().is_none() {
        return Err(PathSafetyError::FilesystemRoot);
    }
    for component in path.components() {
        match component {
            Component::RootDir | Component::Prefix(_) | Component::Normal(_) => {}
            Component::CurDir | Component::ParentDir => return Err(PathSafetyError::Traversal),
        }
    }
    Ok(())
}

/// Resolve only the pre-existing parent chain. Platform aliases such as
/// macOS `/tmp -> /private/tmp` are allowed, while the managed root itself is
/// never allowed to be a symlink.
fn resolve_without_managed_symlink(path: &Path) -> Result<PathBuf, PathSafetyError> {
    let mut existing = path;
    let mut missing = Vec::new();
    loop {
        match std::fs::symlink_metadata(existing) {
            Ok(_) => break,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                let name = existing
                    .file_name()
                    .ok_or(PathSafetyError::FilesystemRoot)?;
                missing.push(name.to_os_string());
                existing = existing.parent().ok_or(PathSafetyError::FilesystemRoot)?;
            }
            Err(source) => {
                return Err(PathSafetyError::Inspect {
                    path: existing.to_path_buf(),
                    source,
                });
            }
        }
    }
    let mut resolved =
        std::fs::canonicalize(existing).map_err(|source| PathSafetyError::Inspect {
            path: existing.to_path_buf(),
            source,
        })?;
    for name in missing.into_iter().rev() {
        resolved.push(name);
    }
    Ok(resolved)
}

fn reject_relative_symlinks(root: &Path, relative: &Path) -> Result<(), PathSafetyError> {
    let mut current = root.to_path_buf();
    for component in relative.components() {
        current.push(component.as_os_str());
        match std::fs::symlink_metadata(&current) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                return Err(PathSafetyError::Symlink(current));
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => break,
            Err(source) => {
                return Err(PathSafetyError::Inspect {
                    path: current,
                    source,
                });
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::fs;

    use tempfile::tempdir;

    use super::*;

    #[test]
    fn rejects_root_and_lexical_traversal() {
        assert!(matches!(
            ManagedRoot::new("/"),
            Err(PathSafetyError::FilesystemRoot)
        ));
        assert!(matches!(
            ManagedRoot::new("/tmp/managed/../escape"),
            Err(PathSafetyError::Traversal)
        ));
        assert!(matches!(
            ManagedRoot::new("/tmp//managed"),
            Err(PathSafetyError::UnsafeComponent)
        ));
    }

    #[cfg(unix)]
    #[test]
    fn rejects_symlink_root_and_symlink_descendant() {
        use std::os::unix::fs::symlink;

        let temp = tempdir().unwrap();
        let real = temp.path().join("real");
        fs::create_dir(&real).unwrap();
        let linked = temp.path().join("linked");
        symlink(&real, &linked).unwrap();
        assert!(matches!(
            ManagedRoot::new(&linked),
            Err(PathSafetyError::Symlink(_))
        ));

        let root = ManagedRoot::new(&real).unwrap();
        let outside = temp.path().join("outside");
        fs::create_dir(&outside).unwrap();
        symlink(&outside, real.join("child")).unwrap();
        assert!(matches!(
            root.validate_descendant(real.join("child/file")),
            Err(PathSafetyError::Symlink(_))
        ));
    }

    #[test]
    fn direct_child_never_accepts_a_nested_path() {
        let temp = tempdir().unwrap();
        let root = ManagedRoot::new(temp.path()).unwrap();
        assert!(root.join_child("port.sh").is_ok());
        assert!(root.join_child("nested/port.sh").is_err());
        assert!(matches!(
            root.validate_direct_child(temp.path().join("nested/port.sh")),
            Err(PathSafetyError::NotDirectChild { .. })
        ));
    }
}
