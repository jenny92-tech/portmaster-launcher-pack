use std::path::{Component, Path, PathBuf};

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::path::{ManagedRoot, PathSafetyError};

pub const CONTEXT_SCHEMA: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ManagementMode {
    App,
    System,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum CapabilityState {
    Current,
    Unknown,
}

fn unknown_capability() -> CapabilityState {
    CapabilityState::Unknown
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ContextCapabilities {
    #[serde(default = "unknown_capability")]
    pub inventory: CapabilityState,
    #[serde(default = "unknown_capability")]
    pub install_plan: CapabilityState,
    #[serde(default = "unknown_capability")]
    pub cache_invalidation: CapabilityState,
    #[serde(default = "unknown_capability")]
    pub manage_ports: CapabilityState,
    #[serde(default = "unknown_capability")]
    pub trash: CapabilityState,
    #[serde(default = "unknown_capability")]
    pub leftovers: CapabilityState,
    #[serde(default = "unknown_capability")]
    pub cleanup_appledouble: CapabilityState,
}

impl Default for ContextCapabilities {
    fn default() -> Self {
        Self {
            inventory: CapabilityState::Unknown,
            install_plan: CapabilityState::Unknown,
            cache_invalidation: CapabilityState::Unknown,
            manage_ports: CapabilityState::Unknown,
            trash: CapabilityState::Unknown,
            leftovers: CapabilityState::Unknown,
            cleanup_appledouble: CapabilityState::Unknown,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ManagedRoots {
    pub portmaster: Option<PathBuf>,
    pub scripts: PathBuf,
    pub game_dirs: PathBuf,
    pub images: Option<PathBuf>,
    pub libs: Option<PathBuf>,
    pub app_state: PathBuf,
    pub trash: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FrontendContext {
    pub kind: String,
    pub directory: PathBuf,
    pub launcher: PathBuf,
    #[serde(default)]
    pub names: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FrontendMapEntry {
    pub source: String,
    pub destination: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum FrontendTransform {
    ExportLibraryGroup {
        target: String,
        variable: String,
        candidates: Vec<PathBuf>,
        required_sonames: Vec<String>,
    },
}

/// Config-resolved install policy. Rust validates this data and requires the
/// remote install plan to match it exactly; platform policy is not compiled
/// into this crate.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ExpectedInstallContract {
    pub schema: u32,
    pub frontend_names: Vec<String>,
    pub primary_frontend: String,
    pub control_source: Option<String>,
    pub core_launcher_source: Option<String>,
    pub frontend_map: Vec<FrontendMapEntry>,
    pub remove_core_launcher: bool,
    pub empty_tasksetter: bool,
    pub core_executable: Option<String>,
    pub frontend_executable: Option<String>,
    #[serde(default)]
    pub frontend_transforms: Vec<FrontendTransform>,
    pub preserve_core_entries: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ResolvedDeviceContext {
    pub schema: u32,
    /// Opaque config-derived platform/profile identifier.
    pub profile: String,
    /// Opaque config-derived support classification used by the UI gate.
    pub device_class: String,
    pub management: ManagementMode,
    pub target_confirmed: bool,
    #[serde(default)]
    pub capabilities: ContextCapabilities,
    pub roots: ManagedRoots,
    pub frontend: FrontendContext,
    pub install: ExpectedInstallContract,
}

#[derive(Debug, Error)]
pub enum ContextError {
    #[error("unsupported context schema {actual}; expected {expected}")]
    Schema { actual: u32, expected: u32 },
    #[error("profile identifier is unsafe: {0:?}")]
    UnsafeProfile(String),
    #[error("managed root `{field}` is unsafe: {source}")]
    UnsafeRoot {
        field: &'static str,
        #[source]
        source: PathSafetyError,
    },
    #[error("frontend name is not a safe direct child: {0:?}")]
    FrontendName(String),
    #[error("frontend names must be unique")]
    DuplicateFrontendName,
    #[error("frontend launcher does not equal directory plus primary name")]
    FrontendLauncher,
    #[error("frontend launcher path is unsafe: {0}")]
    UnsafeFrontendLauncher(PathSafetyError),
    #[error("install contract is invalid: {0}")]
    InvalidInstallContract(String),
}

impl ResolvedDeviceContext {
    pub fn validate(&self) -> Result<(), ContextError> {
        if self.schema != CONTEXT_SCHEMA {
            return Err(ContextError::Schema {
                actual: self.schema,
                expected: CONTEXT_SCHEMA,
            });
        }
        if !safe_identifier(&self.profile) {
            return Err(ContextError::UnsafeProfile(self.profile.clone()));
        }
        if !safe_identifier(&self.device_class) {
            return Err(ContextError::InvalidInstallContract(
                "unsafe device class".to_owned(),
            ));
        }

        let roots = [
            ("scripts", &self.roots.scripts),
            ("game_dirs", &self.roots.game_dirs),
            ("app_state", &self.roots.app_state),
            ("trash", &self.roots.trash),
            ("frontend", &self.frontend.directory),
        ];
        for (field, path) in roots {
            ManagedRoot::new(path).map_err(|source| ContextError::UnsafeRoot { field, source })?;
        }
        for (field, path) in [
            ("portmaster", self.roots.portmaster.as_ref()),
            ("libs", self.roots.libs.as_ref()),
        ] {
            if let Some(path) = path {
                ManagedRoot::new(path)
                    .map_err(|source| ContextError::UnsafeRoot { field, source })?;
            }
        }
        if self.target_confirmed && self.roots.portmaster.is_none() {
            return Err(ContextError::InvalidInstallContract(
                "confirmed target is missing the PortMaster root".to_owned(),
            ));
        }
        if let Some(images) = &self.roots.images {
            ManagedRoot::new(images).map_err(|source| ContextError::UnsafeRoot {
                field: "images",
                source,
            })?;
        }

        validate_names(&self.frontend.names)?;
        if self.install.schema != 1 {
            return Err(ContextError::InvalidInstallContract(
                "unsupported schema".to_owned(),
            ));
        }
        let mut preserve = self.install.preserve_core_entries.clone();
        for name in &preserve {
            ManagedRoot::validate_child_name(name).map_err(|_| {
                ContextError::InvalidInstallContract("unsafe preserved entry".to_owned())
            })?;
        }
        preserve.sort();
        preserve.dedup();
        if preserve.len() != self.install.preserve_core_entries.len()
            || ["libs", "config", "themes"]
                .iter()
                .any(|required| !preserve.iter().any(|name| name == required))
        {
            return Err(ContextError::InvalidInstallContract(
                "preserved entries must be unique and include libs, config, and themes".to_owned(),
            ));
        }
        if self.install.frontend_names != self.frontend.names {
            return Err(ContextError::InvalidInstallContract(
                "frontend names disagree with frontend context".to_owned(),
            ));
        }
        if self.management == ManagementMode::App
            && !self
                .install
                .frontend_names
                .contains(&self.install.primary_frontend)
        {
            return Err(ContextError::InvalidInstallContract(
                "primary frontend is not in frontend names".to_owned(),
            ));
        }
        validate_relative(&self.install.primary_frontend, false).map_err(|_| {
            ContextError::InvalidInstallContract("unsafe primary frontend".to_owned())
        })?;
        let expected = self.frontend.directory.join(&self.install.primary_frontend);
        if self.frontend.launcher != expected {
            return Err(ContextError::FrontendLauncher);
        }
        ManagedRoot::new(&self.frontend.directory)
            .and_then(|root| root.validate_direct_child(&self.frontend.launcher))
            .map_err(ContextError::UnsafeFrontendLauncher)?;

        let mut sources = Vec::new();
        let mut destinations = Vec::new();
        for entry in &self.install.frontend_map {
            validate_relative(&entry.source, true).map_err(|_| {
                ContextError::InvalidInstallContract("unsafe frontend map source".to_owned())
            })?;
            ManagedRoot::validate_child_name(&entry.destination).map_err(|_| {
                ContextError::InvalidInstallContract("unsafe frontend map destination".to_owned())
            })?;
            sources.push(entry.source.clone());
            destinations.push(entry.destination.clone());
        }
        sources.sort();
        sources.dedup();
        destinations.sort();
        destinations.dedup();
        let mut names = self.install.frontend_names.clone();
        names.sort();
        if sources.len() != self.install.frontend_map.len()
            || destinations.len() != self.install.frontend_map.len()
            || destinations != names
        {
            return Err(ContextError::InvalidInstallContract(
                "frontend map must map unique sources exactly onto frontend names".to_owned(),
            ));
        }
        for value in [
            self.install.control_source.as_deref(),
            self.install.core_launcher_source.as_deref(),
        ]
        .into_iter()
        .flatten()
        {
            validate_relative(value, true).map_err(|_| {
                ContextError::InvalidInstallContract("unsafe launcher source".to_owned())
            })?;
        }
        for value in [
            self.install.core_executable.as_deref(),
            self.install.frontend_executable.as_deref(),
        ]
        .into_iter()
        .flatten()
        {
            ManagedRoot::validate_child_name(value).map_err(|_| {
                ContextError::InvalidInstallContract("unsafe executable name".to_owned())
            })?;
        }
        for transform in &self.install.frontend_transforms {
            match transform {
                FrontendTransform::ExportLibraryGroup {
                    target,
                    variable,
                    candidates,
                    required_sonames,
                } => {
                    ManagedRoot::validate_child_name(target).map_err(|_| {
                        ContextError::InvalidInstallContract("unsafe transform target".to_owned())
                    })?;
                    if !self.install.frontend_names.contains(target) {
                        return Err(ContextError::InvalidInstallContract(
                            "transform target is not a managed frontend".to_owned(),
                        ));
                    }
                    if variable.is_empty()
                        || !variable.bytes().enumerate().all(|(index, byte)| {
                            byte == b'_'
                                || byte.is_ascii_alphanumeric()
                                    && (index > 0 || !byte.is_ascii_digit())
                        })
                    {
                        return Err(ContextError::InvalidInstallContract(
                            "unsafe transform variable".to_owned(),
                        ));
                    }
                    if candidates.is_empty() || required_sonames.is_empty() {
                        return Err(ContextError::InvalidInstallContract(
                            "library transform has an empty contract".to_owned(),
                        ));
                    }
                    for candidate in candidates {
                        ManagedRoot::new(candidate).map_err(|_| {
                            ContextError::InvalidInstallContract(
                                "unsafe library transform candidate".to_owned(),
                            )
                        })?;
                    }
                    for soname in required_sonames {
                        ManagedRoot::validate_child_name(soname).map_err(|_| {
                            ContextError::InvalidInstallContract(
                                "unsafe required library name".to_owned(),
                            )
                        })?;
                    }
                }
            }
        }
        Ok(())
    }
}

fn validate_names(names: &[String]) -> Result<(), ContextError> {
    let mut unique = names.to_vec();
    unique.sort();
    unique.dedup();
    if unique.len() != names.len() {
        return Err(ContextError::DuplicateFrontendName);
    }
    for name in names {
        ManagedRoot::validate_child_name(name)
            .map_err(|_| ContextError::FrontendName(name.clone()))?;
    }
    Ok(())
}

fn safe_identifier(value: &str) -> bool {
    !value.is_empty()
        && value != "."
        && value != ".."
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

fn validate_relative(value: &str, nested: bool) -> Result<(), PathSafetyError> {
    if value.is_empty()
        || value.starts_with('/')
        || value.contains("//")
        || value.contains(['\\', '\0', '\t', '\r', '\n'])
    {
        return Err(PathSafetyError::UnsafeComponent);
    }
    let mut count = 0;
    for component in Path::new(value).components() {
        match component {
            Component::Normal(_) => count += 1,
            _ => return Err(PathSafetyError::Traversal),
        }
    }
    if count == 0 || (!nested && count != 1) {
        return Err(PathSafetyError::UnsafeComponent);
    }
    Ok(())
}
