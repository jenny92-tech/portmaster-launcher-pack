use std::path::PathBuf;

use portkit_core::Resolution;
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::context::{
    CapabilityState, ContextCapabilities, ExpectedInstallContract, FrontendContext,
    FrontendMapEntry, FrontendTransform, ManagedRoots, ManagementMode, ResolvedDeviceContext,
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AppOwnedPaths {
    pub state: PathBuf,
    pub trash: PathBuf,
}

/// CLI input: canonical PortKit resolution plus the two roots owned solely by
/// App Manager. Platform policy is never copied into a parallel input model.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ResolvedContextInput {
    pub resolution: Resolution,
    pub app_owned: AppOwnedPaths,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedPlatformContext {
    profile: String,
    device_class: String,
    target_confirmed: bool,
    capabilities: ContextCapabilities,
    management: ManagementMode,
    roots: PlatformRoots,
    frontend: FrontendContext,
    install: ExpectedInstallContract,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct PlatformRoots {
    portmaster: Option<PathBuf>,
    scripts: PathBuf,
    game_dirs: PathBuf,
    images: Option<PathBuf>,
    libs: Option<PathBuf>,
}

#[derive(Debug, Error)]
pub enum ResolutionConversionError {
    #[error("resolution is missing required path `{0}`")]
    MissingPath(&'static str),
    #[error("invalid frontend contract: {0}")]
    Frontend(String),
    #[error("resolved context is unsafe: {0}")]
    Context(String),
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ResolvedFrontend {
    kind: String,
    management: String,
    names: Vec<String>,
    primary: String,
    install_map: Vec<ResolvedInstallMap>,
    control_source: Option<String>,
    core_launcher_source: Option<String>,
    remove_core_launcher: bool,
    empty_tasksetter: bool,
    core_executable: Option<String>,
    frontend_executable: Option<String>,
    #[serde(default)]
    transforms: Vec<ResolvedFrontendTransform>,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum ResolvedFrontendTransform {
    ExportLibraryGroup {
        target: String,
        variable: String,
        library_group: String,
    },
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ResolvedLibraryGroup {
    candidates: Vec<PathBuf>,
    required_sonames: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ResolvedInstallMap {
    source: String,
    target: String,
    executable: bool,
}

impl TryFrom<&Resolution> for ResolvedPlatformContext {
    type Error = ResolutionConversionError;

    fn try_from(resolution: &Resolution) -> Result<Self, Self::Error> {
        let path = |name: &'static str| {
            resolution
                .paths
                .get(name)
                .cloned()
                .ok_or(ResolutionConversionError::MissingPath(name))
        };
        let portmaster = resolution.paths.get("portmaster_core").cloned();
        if resolution.target_confirmed && portmaster.is_none() {
            return Err(ResolutionConversionError::MissingPath("portmaster_core"));
        }
        let scripts = path("scripts")?;
        let game_dirs = path("game_data")?;
        let frontend_dir = path("frontend")?;
        let images = resolution.paths.get("images").cloned();

        let raw: ResolvedFrontend = serde_json::from_value(resolution.frontend.clone())
            .map_err(|error| ResolutionConversionError::Frontend(error.to_string()))?;
        let management = match raw.management.as_str() {
            "app" => ManagementMode::App,
            "system" => ManagementMode::System,
            other => {
                return Err(ResolutionConversionError::Frontend(format!(
                    "unsupported management mode {other:?}"
                )));
            }
        };
        let frontend_map: Vec<_> = raw
            .install_map
            .iter()
            .map(|entry| FrontendMapEntry {
                source: entry.source.clone(),
                destination: entry.target.clone(),
            })
            .collect();
        let executable_targets: Vec<_> = raw
            .install_map
            .iter()
            .filter(|entry| entry.executable)
            .map(|entry| entry.target.as_str())
            .collect();
        if let Some(executable) = raw.frontend_executable.as_deref() {
            if !executable_targets.contains(&executable) {
                return Err(ResolutionConversionError::Frontend(
                    "frontend_executable is not executable in install_map".to_owned(),
                ));
            }
        } else if !executable_targets.is_empty() {
            return Err(ResolutionConversionError::Frontend(
                "executable install_map target lacks frontend_executable".to_owned(),
            ));
        }

        let library_groups = resolution
            .libraries
            .get("groups")
            .and_then(serde_json::Value::as_object);
        let frontend_transforms = raw
            .transforms
            .iter()
            .map(|transform| match transform {
                ResolvedFrontendTransform::ExportLibraryGroup {
                    target,
                    variable,
                    library_group,
                } => {
                    let value = library_groups
                        .and_then(|groups| groups.get(library_group))
                        .ok_or_else(|| {
                            ResolutionConversionError::Frontend(format!(
                                "frontend transform references missing library group {library_group:?}"
                            ))
                        })?;
                    let group: ResolvedLibraryGroup = serde_json::from_value(value.clone())
                        .map_err(|error| ResolutionConversionError::Frontend(error.to_string()))?;
                    Ok(FrontendTransform::ExportLibraryGroup {
                        target: target.clone(),
                        variable: variable.clone(),
                        candidates: group.candidates,
                        required_sonames: group.required_sonames,
                    })
                }
            })
            .collect::<Result<Vec<_>, ResolutionConversionError>>()?;

        let launcher = frontend_dir.join(&raw.primary);
        Ok(Self {
            profile: resolution.platform_id.clone(),
            device_class: resolution.device_class.clone(),
            target_confirmed: resolution.target_confirmed,
            capabilities: ContextCapabilities {
                inventory: capability(&resolution.capabilities, "manage_ports"),
                install_plan: capability(&resolution.capabilities, "install_portmaster"),
                cache_invalidation: capability(&resolution.capabilities, "manage_ports"),
                manage_ports: capability(&resolution.capabilities, "manage_ports"),
                trash: capability(&resolution.capabilities, "trash"),
                leftovers: capability(&resolution.capabilities, "leftovers"),
                cleanup_appledouble: capability(&resolution.capabilities, "cleanup_appledouble"),
            },
            management,
            roots: PlatformRoots {
                libs: portmaster.as_ref().map(|root| root.join("libs")),
                portmaster,
                scripts,
                game_dirs,
                images,
            },
            frontend: FrontendContext {
                kind: raw.kind,
                directory: frontend_dir,
                launcher,
                names: raw.names.clone(),
            },
            install: ExpectedInstallContract {
                schema: 1,
                frontend_names: raw.names,
                primary_frontend: raw.primary,
                control_source: raw.control_source,
                core_launcher_source: raw.core_launcher_source,
                frontend_map,
                remove_core_launcher: raw.remove_core_launcher,
                empty_tasksetter: raw.empty_tasksetter,
                core_executable: raw.core_executable,
                frontend_executable: raw.frontend_executable,
                frontend_transforms,
                preserve_core_entries: resolution.preserved_dirs.clone(),
            },
        })
    }
}

impl ResolvedPlatformContext {
    pub fn with_app_owned_paths(
        self,
        app_owned: AppOwnedPaths,
    ) -> Result<ResolvedDeviceContext, ResolutionConversionError> {
        let context = ResolvedDeviceContext {
            schema: 1,
            profile: self.profile,
            device_class: self.device_class,
            management: self.management,
            target_confirmed: self.target_confirmed,
            capabilities: self.capabilities,
            roots: ManagedRoots {
                portmaster: self.roots.portmaster,
                scripts: self.roots.scripts,
                game_dirs: self.roots.game_dirs,
                images: self.roots.images,
                libs: self.roots.libs,
                app_state: app_owned.state,
                trash: app_owned.trash,
            },
            frontend: self.frontend,
            install: self.install,
        };
        context
            .validate()
            .map_err(|error| ResolutionConversionError::Context(error.to_string()))?;
        Ok(context)
    }
}

fn capability(
    capabilities: &std::collections::BTreeMap<String, bool>,
    name: &str,
) -> CapabilityState {
    if capabilities.get(name) == Some(&true) {
        CapabilityState::Current
    } else {
        CapabilityState::Unknown
    }
}

impl TryFrom<ResolvedContextInput> for ResolvedDeviceContext {
    type Error = ResolutionConversionError;

    fn try_from(input: ResolvedContextInput) -> Result<Self, Self::Error> {
        ResolvedPlatformContext::try_from(&input.resolution)?.with_app_owned_paths(input.app_owned)
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::fs;

    use serde_json::json;
    use tempfile::TempDir;

    use super::*;

    struct Fixture {
        _temp: TempDir,
        resolution: Resolution,
        app_owned: AppOwnedPaths,
    }

    fn fixture() -> Fixture {
        let temp = tempfile::tempdir().unwrap();
        for name in [
            "core", "scripts", "games", "images", "frontend", "state", "trash",
        ] {
            fs::create_dir(temp.path().join(name)).unwrap();
        }
        let paths = BTreeMap::from([
            ("portmaster_core".to_owned(), temp.path().join("core")),
            ("scripts".to_owned(), temp.path().join("scripts")),
            ("game_data".to_owned(), temp.path().join("games")),
            ("images".to_owned(), temp.path().join("images")),
            ("frontend".to_owned(), temp.path().join("frontend")),
        ]);
        Fixture {
            resolution: Resolution {
                platform_id: "plugin-device-v2".to_owned(),
                platform_display_name: "Plugin device".to_owned(),
                device_manufacturer: None,
                device_class: "official-untested".to_owned(),
                target_confirmed: true,
                model_id: None,
                model_display_name: None,
                adapters: vec!["frontend.v1".to_owned()],
                paths,
                source_route: "fixture".to_owned(),
                capabilities: BTreeMap::from([("install_portmaster".to_owned(), true)]),
                frontend: json!({
                    "kind": "plugin-frontend",
                    "management": "app",
                    "names": ["launch.sh"],
                    "primary": "launch.sh",
                    "install_map": [{
                        "source": "plugin/launch.txt",
                        "target": "launch.sh",
                        "executable": true
                    }],
                    "control_source": "plugin/control.txt",
                    "core_launcher_source": null,
                    "remove_core_launcher": false,
                    "empty_tasksetter": false,
                    "core_executable": "PortMaster.sh",
                    "frontend_executable": "launch.sh"
                }),
                libraries: BTreeMap::new(),
                python: json!({}),
                health: Vec::new(),
                preserved_dirs: vec!["libs".to_owned(), "config".to_owned(), "themes".to_owned()],
                environment_scopes: Vec::new(),
                display: json!({}),
                input: json!({}),
            },
            app_owned: AppOwnedPaths {
                state: temp.path().join("state"),
                trash: temp.path().join("trash"),
            },
            _temp: temp,
        }
    }

    #[test]
    fn arbitrary_portkit_profile_converts_without_a_platform_table() {
        let fixture = fixture();
        let platform = ResolvedPlatformContext::try_from(&fixture.resolution).unwrap();
        let context = platform
            .with_app_owned_paths(fixture.app_owned.clone())
            .unwrap();
        assert_eq!(context.profile, "plugin-device-v2");
        assert_eq!(context.device_class, "official-untested");
        assert!(context.target_confirmed);
        assert_eq!(context.frontend.kind, "plugin-frontend");
        assert_eq!(context.install.frontend_map[0].destination, "launch.sh");
        assert!(
            context
                .install
                .preserve_core_entries
                .iter()
                .any(|entry| entry == "themes")
        );
    }

    #[test]
    fn incomplete_frontend_policy_is_rejected_instead_of_guessed() {
        let mut fixture = fixture();
        fixture
            .resolution
            .frontend
            .as_object_mut()
            .unwrap()
            .remove("remove_core_launcher");
        assert!(matches!(
            ResolvedPlatformContext::try_from(&fixture.resolution),
            Err(ResolutionConversionError::Frontend(_))
        ));
    }

    #[test]
    fn unconfirmed_resolution_without_core_root_remains_read_only_usable() {
        let mut fixture = fixture();
        fixture.resolution.paths.remove("portmaster_core");
        fixture.resolution.device_class = "unknown-path".to_owned();
        fixture.resolution.target_confirmed = false;
        let context = ResolvedPlatformContext::try_from(&fixture.resolution)
            .unwrap()
            .with_app_owned_paths(fixture.app_owned)
            .unwrap();
        assert_eq!(context.device_class, "unknown-path");
        assert!(!context.target_confirmed);
        assert!(context.roots.portmaster.is_none());
        assert!(context.roots.libs.is_none());
    }

    #[test]
    fn resolution_capabilities_fail_closed_in_app_context() {
        let mut fixture = fixture();
        fixture
            .resolution
            .capabilities
            .insert("install_portmaster".to_owned(), false);
        fixture
            .resolution
            .capabilities
            .insert("manage_ports".to_owned(), false);
        let context = ResolvedPlatformContext::try_from(&fixture.resolution)
            .unwrap()
            .with_app_owned_paths(fixture.app_owned)
            .unwrap();
        assert_eq!(context.capabilities.install_plan, CapabilityState::Unknown);
        assert_eq!(context.capabilities.inventory, CapabilityState::Unknown);
        assert_eq!(
            context.capabilities.cache_invalidation,
            CapabilityState::Unknown
        );
        assert!(matches!(
            crate::InstallPlan::from_context(&context),
            Err(crate::PlanError::CapabilityUnknown)
        ));
    }
}
