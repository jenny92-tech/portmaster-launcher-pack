use std::path::PathBuf;

use portkit_core::{
    LocationKind, Resolution, ResolvedLocation, required_location_format, required_location_roles,
};
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
    apps: Vec<ResolvedLocation>,
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
        let selected_location =
            |kind: LocationKind| -> Result<Option<PathBuf>, ResolutionConversionError> {
                let required_roles = required_location_roles(kind, &resolution.capabilities);
                let required_format = required_location_format(kind, &resolution.capabilities);
                let candidates = resolution
                    .locations
                    .iter()
                    .filter(|location| {
                        location.kind == kind
                            && required_roles
                                .iter()
                                .all(|role| location.roles.contains(role))
                            && required_format
                                .is_none_or(|format| location.formats.contains(&format))
                    })
                    .collect::<Vec<_>>();
                let Some(highest) = candidates.iter().map(|location| location.priority).max()
                else {
                    return Ok(None);
                };
                let selected = candidates
                    .into_iter()
                    .filter(|location| location.priority == highest)
                    .collect::<Vec<_>>();
                if selected.len() != 1 {
                    return Err(ResolutionConversionError::Frontend(format!(
                        "ambiguous {kind:?} location at priority {highest}"
                    )));
                }
                Ok(Some(selected[0].path.clone()))
            };
        let scripts = selected_location(LocationKind::PortScripts)?
            .ok_or(ResolutionConversionError::MissingPath("scripts location"))?;
        let game_dirs = selected_location(LocationKind::PortData)?
            .ok_or(ResolutionConversionError::MissingPath("game data location"))?;
        let frontend_dir = path("frontend")?;
        let images = selected_location(LocationKind::PortImages)?;

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
                inventory: capability_any(
                    &resolution.capabilities,
                    &["inventory_ports", "inventory_apps"],
                ),
                install_plan: capability(&resolution.capabilities, "install_portmaster"),
                cache_invalidation: capability_any(
                    &resolution.capabilities,
                    &["manage_ports", "manage_apps"],
                ),
                inventory_ports: capability(&resolution.capabilities, "inventory_ports"),
                manage_ports: capability(&resolution.capabilities, "manage_ports"),
                install_ports: capability(&resolution.capabilities, "install_ports"),
                inventory_apps: capability(&resolution.capabilities, "inventory_apps"),
                manage_apps: capability(&resolution.capabilities, "manage_apps"),
                install_apps: capability(&resolution.capabilities, "install_apps"),
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
            apps: resolution
                .locations
                .iter()
                .filter(|location| location.kind == LocationKind::Apps)
                .cloned()
                .collect(),
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
                apps: self
                    .apps
                    .into_iter()
                    .map(|location| crate::context::ManagedAppLocation {
                        id: location.id,
                        path: location.path,
                        roles: location.roles,
                        formats: location.formats,
                        priority: location.priority,
                    })
                    .collect(),
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

fn capability_any(
    capabilities: &std::collections::BTreeMap<String, bool>,
    names: &[&str],
) -> CapabilityState {
    if names
        .iter()
        .any(|name| capabilities.get(*name) == Some(&true))
    {
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
                locations: vec![
                    ResolvedLocation {
                        id: "ports-scripts".to_owned(),
                        kind: LocationKind::PortScripts,
                        path: temp.path().join("scripts"),
                        roles: vec![portkit_core::LocationRole::Inventory],
                        formats: vec![portkit_core::BundleFormat::Port],
                        priority: 100,
                    },
                    ResolvedLocation {
                        id: "ports-data".to_owned(),
                        kind: LocationKind::PortData,
                        path: temp.path().join("games"),
                        roles: vec![portkit_core::LocationRole::Inventory],
                        formats: vec![portkit_core::BundleFormat::Port],
                        priority: 100,
                    },
                    ResolvedLocation {
                        id: "ports-images".to_owned(),
                        kind: LocationKind::PortImages,
                        path: temp.path().join("images"),
                        roles: vec![portkit_core::LocationRole::Inventory],
                        formats: Vec::new(),
                        priority: 100,
                    },
                ],
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

    #[test]
    fn inventory_only_location_never_replaces_the_install_and_manage_root() {
        let mut fixture = fixture();
        let required_roles = vec![
            portkit_core::LocationRole::Inventory,
            portkit_core::LocationRole::Install,
            portkit_core::LocationRole::Manage,
        ];
        for location in &mut fixture.resolution.locations {
            if matches!(
                location.kind,
                LocationKind::PortScripts | LocationKind::PortData
            ) {
                location.roles = required_roles.clone();
            }
        }
        fixture.resolution.capabilities.extend([
            ("inventory_ports".to_owned(), true),
            ("install_ports".to_owned(), true),
            ("manage_ports".to_owned(), true),
        ]);
        let inventory_only = fixture._temp.path().join("inventory-only");
        fs::create_dir(&inventory_only).unwrap();
        fixture.resolution.locations.push(ResolvedLocation {
            id: "ports-scripts-inventory".to_owned(),
            kind: LocationKind::PortScripts,
            path: inventory_only,
            roles: vec![portkit_core::LocationRole::Inventory],
            formats: vec![portkit_core::BundleFormat::Port],
            priority: 200,
        });

        let context = ResolvedPlatformContext::try_from(&fixture.resolution)
            .unwrap()
            .with_app_owned_paths(fixture.app_owned)
            .unwrap();
        assert_eq!(context.roots.scripts, fixture._temp.path().join("scripts"));
    }

    #[test]
    fn eligible_port_location_priority_ties_are_rejected() {
        let mut fixture = fixture();
        fixture
            .resolution
            .capabilities
            .insert("inventory_ports".to_owned(), true);
        let second = fixture._temp.path().join("scripts-second");
        fs::create_dir(&second).unwrap();
        fixture.resolution.locations.push(ResolvedLocation {
            id: "ports-scripts-second".to_owned(),
            kind: LocationKind::PortScripts,
            path: second,
            roles: vec![portkit_core::LocationRole::Inventory],
            formats: vec![portkit_core::BundleFormat::Port],
            priority: 100,
        });

        let error = ResolvedPlatformContext::try_from(&fixture.resolution).unwrap_err();
        assert!(error.to_string().contains("ambiguous PortScripts location"));
    }

    #[test]
    fn trimui_apps_root_may_contain_appmanager_private_state() {
        let mut fixture = fixture();
        let apps = fixture._temp.path().join("Apps");
        let app_root = apps.join("jenny92-appmanager");
        let state = app_root.join("state");
        let trash = app_root.join("trash");
        fs::create_dir_all(&state).unwrap();
        fs::create_dir(&trash).unwrap();
        fixture.resolution.capabilities.extend([
            ("inventory_apps".to_owned(), true),
            ("manage_apps".to_owned(), true),
            ("install_apps".to_owned(), true),
        ]);
        fixture.resolution.locations.push(ResolvedLocation {
            id: "apps-primary".to_owned(),
            kind: LocationKind::Apps,
            path: apps.clone(),
            roles: vec![
                portkit_core::LocationRole::Inventory,
                portkit_core::LocationRole::Install,
                portkit_core::LocationRole::Manage,
            ],
            formats: vec![portkit_core::BundleFormat::TrimuiApp],
            priority: 100,
        });
        fixture.app_owned = AppOwnedPaths { state, trash };

        let context = ResolvedPlatformContext::try_from(&fixture.resolution)
            .unwrap()
            .with_app_owned_paths(fixture.app_owned)
            .unwrap();
        assert_eq!(context.roots.apps[0].path, apps);
    }
}
