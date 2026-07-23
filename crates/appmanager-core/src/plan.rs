use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::context::{
    CapabilityState, FrontendMapEntry, FrontendTransform, ManagementMode, ResolvedDeviceContext,
};
use crate::path::{ManagedRoot, PathSafetyError};

const REQUIRED_FIELDS: &[&str] = &[
    "schema",
    "device",
    "target",
    "scripts",
    "frontend_dir",
    "frontend_names",
    "primary_frontend",
    "control_source",
    "core_launcher_source",
    "frontend_map",
    "remove_core_launcher",
    "empty_tasksetter",
    "core_executable",
    "frontend_executable",
];

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InstallPlan {
    pub schema: u32,
    pub device: String,
    pub target: PathBuf,
    pub scripts: PathBuf,
    pub frontend_dir: PathBuf,
    pub frontend_names: Vec<String>,
    pub primary_frontend: String,
    pub control_source: Option<String>,
    pub core_launcher_source: Option<String>,
    pub frontend_map: Vec<FrontendMapEntry>,
    pub remove_core_launcher: bool,
    pub empty_tasksetter: bool,
    pub core_executable: Option<String>,
    pub frontend_executable: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ValidatedInstallPlan {
    pub schema: u32,
    pub device: String,
    pub target: PathBuf,
    pub scripts: PathBuf,
    pub frontend_dir: PathBuf,
    pub frontend_names: Vec<String>,
    pub primary_frontend: String,
    pub control_source: Option<String>,
    pub core_launcher_source: Option<String>,
    pub frontend_map: Vec<FrontendMapEntry>,
    pub remove_core_launcher: bool,
    pub empty_tasksetter: bool,
    pub core_executable: Option<String>,
    pub frontend_executable: Option<String>,
    pub frontend_transforms: Vec<FrontendTransform>,
    pub preserve_core_entries: Vec<String>,
}

#[derive(Debug, Error)]
pub enum PlanError {
    #[error("plan is not valid UTF-8")]
    Utf8,
    #[error("plan line {line} must contain exactly one tab")]
    Row { line: usize },
    #[error("plan line {line} contains an empty key or unsafe control character")]
    UnsafeRow { line: usize },
    #[error("duplicate plan field `{0}`")]
    DuplicateField(String),
    #[error("unknown plan field `{0}`")]
    UnknownField(String),
    #[error("missing plan field `{0}`")]
    MissingField(&'static str),
    #[error("invalid value for plan field `{field}`: {value:?}")]
    Field { field: &'static str, value: String },
    #[error("device context is invalid: {0}")]
    Context(String),
    #[error("install-plan capability is unknown")]
    CapabilityUnknown,
    #[error("PortMaster is system-managed on this device")]
    SystemManaged,
    #[error("the install target has not been confirmed")]
    TargetUnconfirmed,
    #[error("plan field `{field}` does not match the resolved device context")]
    ContextMismatch { field: &'static str },
    #[error("plan does not match the resolved `{profile}` install contract")]
    ContractMismatch { profile: String },
    #[error("unsafe path in plan field `{field}`: {source}")]
    UnsafePath {
        field: &'static str,
        #[source]
        source: PathSafetyError,
    },
    #[error("install plan cannot be represented safely as TSV")]
    Serialization,
}

impl InstallPlan {
    pub fn from_context(context: &ResolvedDeviceContext) -> Result<Self, PlanError> {
        let target = context
            .roots
            .portmaster
            .clone()
            .ok_or(PlanError::TargetUnconfirmed)?;
        let plan = Self {
            schema: context.install.schema,
            device: context.profile.clone(),
            target,
            scripts: context.roots.scripts.clone(),
            frontend_dir: context.frontend.directory.clone(),
            frontend_names: context.install.frontend_names.clone(),
            primary_frontend: context.install.primary_frontend.clone(),
            control_source: context.install.control_source.clone(),
            core_launcher_source: context.install.core_launcher_source.clone(),
            frontend_map: context.install.frontend_map.clone(),
            remove_core_launcher: context.install.remove_core_launcher,
            empty_tasksetter: context.install.empty_tasksetter,
            core_executable: context.install.core_executable.clone(),
            frontend_executable: context.install.frontend_executable.clone(),
        };
        plan.validate(context)?;
        Ok(plan)
    }

    pub fn to_tsv(&self) -> Result<String, PlanError> {
        let names = if self.frontend_names.is_empty() {
            "-".to_owned()
        } else {
            self.frontend_names.join(",")
        };
        let frontend_map = if self.frontend_map.is_empty() {
            "-".to_owned()
        } else {
            self.frontend_map
                .iter()
                .map(|entry| format!("{}={}", entry.source, entry.destination))
                .collect::<Vec<_>>()
                .join(",")
        };
        let rendered = format!(
            concat!(
                "schema\t{}\n",
                "device\t{}\n",
                "target\t{}\n",
                "scripts\t{}\n",
                "frontend_dir\t{}\n",
                "frontend_names\t{}\n",
                "primary_frontend\t{}\n",
                "control_source\t{}\n",
                "core_launcher_source\t{}\n",
                "frontend_map\t{}\n",
                "remove_core_launcher\t{}\n",
                "empty_tasksetter\t{}\n",
                "core_executable\t{}\n",
                "frontend_executable\t{}\n"
            ),
            self.schema,
            self.device,
            path_str(&self.target)?,
            path_str(&self.scripts)?,
            path_str(&self.frontend_dir)?,
            names,
            self.primary_frontend,
            optional_str(&self.control_source),
            optional_str(&self.core_launcher_source),
            frontend_map,
            u8::from(self.remove_core_launcher),
            u8::from(self.empty_tasksetter),
            optional_str(&self.core_executable),
            optional_str(&self.frontend_executable),
        );
        if !matches!(Self::parse_tsv(rendered.as_bytes()), Ok(parsed) if parsed == *self) {
            return Err(PlanError::Serialization);
        }
        Ok(rendered)
    }

    pub fn parse_tsv(bytes: &[u8]) -> Result<Self, PlanError> {
        let text = std::str::from_utf8(bytes).map_err(|_| PlanError::Utf8)?;
        let mut fields = BTreeMap::<String, String>::new();
        for (index, raw) in text.lines().enumerate() {
            let line_number = index + 1;
            if raw.is_empty() || raw.starts_with('#') {
                continue;
            }
            let mut pair = raw.split('\t');
            let key = pair.next().unwrap_or_default();
            let value = pair.next().ok_or(PlanError::Row { line: line_number })?;
            if pair.next().is_some() {
                return Err(PlanError::Row { line: line_number });
            }
            if key.is_empty() || raw.contains(['\r', '\0']) {
                return Err(PlanError::UnsafeRow { line: line_number });
            }
            if !REQUIRED_FIELDS.contains(&key) {
                return Err(PlanError::UnknownField(key.to_owned()));
            }
            if fields.insert(key.to_owned(), value.to_owned()).is_some() {
                return Err(PlanError::DuplicateField(key.to_owned()));
            }
        }
        for key in REQUIRED_FIELDS {
            if !fields.contains_key(*key) {
                return Err(PlanError::MissingField(key));
            }
        }

        let get = |key: &'static str| fields.get(key).cloned().unwrap();
        let schema_text = get("schema");
        let schema = schema_text.parse().map_err(|_| PlanError::Field {
            field: "schema",
            value: schema_text,
        })?;
        let device = get("device");
        let frontend_names = parse_names(&get("frontend_names"), "frontend_names")?;
        let frontend_map = parse_map(&get("frontend_map"))?;

        Ok(Self {
            schema,
            device,
            target: PathBuf::from(get("target")),
            scripts: PathBuf::from(get("scripts")),
            frontend_dir: PathBuf::from(get("frontend_dir")),
            frontend_names,
            primary_frontend: get("primary_frontend"),
            control_source: parse_optional(&get("control_source")),
            core_launcher_source: parse_optional(&get("core_launcher_source")),
            frontend_map,
            remove_core_launcher: parse_bool(&get("remove_core_launcher"), "remove_core_launcher")?,
            empty_tasksetter: parse_bool(&get("empty_tasksetter"), "empty_tasksetter")?,
            core_executable: parse_optional(&get("core_executable")),
            frontend_executable: parse_optional(&get("frontend_executable")),
        })
    }

    pub fn validate(
        &self,
        context: &ResolvedDeviceContext,
    ) -> Result<ValidatedInstallPlan, PlanError> {
        context
            .validate()
            .map_err(|error| PlanError::Context(error.to_string()))?;
        if context.management == ManagementMode::System {
            return Err(PlanError::SystemManaged);
        }
        if context.capabilities.install_plan != CapabilityState::Current {
            return Err(PlanError::CapabilityUnknown);
        }
        if !context.target_confirmed {
            return Err(PlanError::TargetUnconfirmed);
        }
        if self.schema != 1 {
            return Err(PlanError::Field {
                field: "schema",
                value: self.schema.to_string(),
            });
        }
        if self.device != context.profile {
            return Err(PlanError::ContextMismatch { field: "device" });
        }
        let target = context
            .roots
            .portmaster
            .as_deref()
            .ok_or(PlanError::TargetUnconfirmed)?;
        ensure_path("target", &self.target, target)?;
        ensure_path("scripts", &self.scripts, &context.roots.scripts)?;
        ensure_path(
            "frontend_dir",
            &self.frontend_dir,
            &context.frontend.directory,
        )?;
        if self.frontend_names != context.frontend.names {
            return Err(PlanError::ContextMismatch {
                field: "frontend_names",
            });
        }
        let expected_launcher = self.frontend_dir.join(&self.primary_frontend);
        if expected_launcher != context.frontend.launcher {
            return Err(PlanError::ContextMismatch {
                field: "primary_frontend",
            });
        }

        if !matches_contract(self, context) {
            return Err(PlanError::ContractMismatch {
                profile: self.device.clone(),
            });
        }
        validate_relative(&self.primary_frontend, false).map_err(|source| {
            PlanError::UnsafePath {
                field: "primary_frontend",
                source,
            }
        })?;
        for entry in &self.frontend_map {
            validate_relative(&entry.source, true).map_err(|source| PlanError::UnsafePath {
                field: "frontend_map.source",
                source,
            })?;
            ManagedRoot::validate_child_name(&entry.destination).map_err(|source| {
                PlanError::UnsafePath {
                    field: "frontend_map.destination",
                    source,
                }
            })?;
        }

        Ok(ValidatedInstallPlan {
            schema: self.schema,
            device: self.device.clone(),
            target: self.target.clone(),
            scripts: self.scripts.clone(),
            frontend_dir: self.frontend_dir.clone(),
            frontend_names: self.frontend_names.clone(),
            primary_frontend: self.primary_frontend.clone(),
            control_source: self.control_source.clone(),
            core_launcher_source: self.core_launcher_source.clone(),
            frontend_map: self.frontend_map.clone(),
            remove_core_launcher: self.remove_core_launcher,
            empty_tasksetter: self.empty_tasksetter,
            core_executable: self.core_executable.clone(),
            frontend_executable: self.frontend_executable.clone(),
            frontend_transforms: context.install.frontend_transforms.clone(),
            preserve_core_entries: context.install.preserve_core_entries.clone(),
        })
    }
}

fn path_str(path: &Path) -> Result<&str, PlanError> {
    path.to_str().ok_or(PlanError::Serialization)
}

fn optional_str(value: &Option<String>) -> &str {
    value.as_deref().unwrap_or("-")
}

fn ensure_path(field: &'static str, actual: &Path, expected: &Path) -> Result<(), PlanError> {
    ManagedRoot::new(actual).map_err(|source| PlanError::UnsafePath { field, source })?;
    if actual != expected {
        return Err(PlanError::ContextMismatch { field });
    }
    Ok(())
}

fn parse_optional(value: &str) -> Option<String> {
    (value != "-").then(|| value.to_owned())
}

fn parse_bool(value: &str, field: &'static str) -> Result<bool, PlanError> {
    match value {
        "0" => Ok(false),
        "1" => Ok(true),
        _ => Err(PlanError::Field {
            field,
            value: value.to_owned(),
        }),
    }
}

fn parse_names(value: &str, field: &'static str) -> Result<Vec<String>, PlanError> {
    if value == "-" {
        return Ok(Vec::new());
    }
    let names: Vec<_> = value.split(',').map(str::to_owned).collect();
    if names.is_empty() {
        return Err(PlanError::Field {
            field,
            value: value.to_owned(),
        });
    }
    for name in &names {
        ManagedRoot::validate_child_name(name).map_err(|_| PlanError::Field {
            field,
            value: value.to_owned(),
        })?;
    }
    Ok(names)
}

fn parse_map(value: &str) -> Result<Vec<FrontendMapEntry>, PlanError> {
    if value == "-" {
        return Ok(Vec::new());
    }
    value
        .split(',')
        .map(|mapping| {
            let (source, destination) =
                mapping.split_once('=').ok_or_else(|| PlanError::Field {
                    field: "frontend_map",
                    value: value.to_owned(),
                })?;
            if source.is_empty() || destination.is_empty() || destination.contains('=') {
                return Err(PlanError::Field {
                    field: "frontend_map",
                    value: value.to_owned(),
                });
            }
            Ok(FrontendMapEntry {
                source: source.to_owned(),
                destination: destination.to_owned(),
            })
        })
        .collect()
}

fn validate_relative(value: &str, nested: bool) -> Result<(), PathSafetyError> {
    if value.is_empty()
        || value.starts_with('/')
        || value.contains("//")
        || value.contains(['\\', '\0', '\t', '\r', '\n'])
    {
        return Err(PathSafetyError::UnsafeComponent);
    }
    let path = Path::new(value);
    let mut count = 0;
    for component in path.components() {
        match component {
            std::path::Component::Normal(_) => count += 1,
            _ => return Err(PathSafetyError::Traversal),
        }
    }
    if count == 0 || (!nested && count != 1) {
        return Err(PathSafetyError::UnsafeComponent);
    }
    Ok(())
}

fn matches_contract(plan: &InstallPlan, context: &ResolvedDeviceContext) -> bool {
    let expected = &context.install;
    plan.schema == expected.schema
        && plan.frontend_names == expected.frontend_names
        && plan.primary_frontend == expected.primary_frontend
        && plan.control_source == expected.control_source
        && plan.core_launcher_source == expected.core_launcher_source
        && plan.frontend_map == expected.frontend_map
        && plan.remove_core_launcher == expected.remove_core_launcher
        && plan.empty_tasksetter == expected.empty_tasksetter
        && plan.core_executable == expected.core_executable
        && plan.frontend_executable == expected.frontend_executable
}

#[cfg(test)]
mod tests {
    use std::fs;

    use tempfile::TempDir;

    use super::*;
    use crate::context::{
        ContextCapabilities, ExpectedInstallContract, FrontendContext, ManagedRoots,
    };

    struct Fixture {
        _temp: TempDir,
        context: ResolvedDeviceContext,
    }

    fn trimui_fixture() -> Fixture {
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
                profile: "future-handheld".to_owned(),
                device_class: "future-supported".to_owned(),
                management: ManagementMode::App,
                target_confirmed: true,
                capabilities: ContextCapabilities {
                    inventory: CapabilityState::Current,
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
                    trash: temp.path().join("trash"),
                },
                frontend: FrontendContext {
                    kind: "future-frontend".to_owned(),
                    directory: frontend.clone(),
                    launcher: frontend.join("launch.sh"),
                    names: vec![
                        "launch.sh".to_owned(),
                        "config.json".to_owned(),
                        "icon.png".to_owned(),
                    ],
                },
                install: ExpectedInstallContract {
                    schema: 1,
                    frontend_names: vec![
                        "launch.sh".to_owned(),
                        "config.json".to_owned(),
                        "icon.png".to_owned(),
                    ],
                    primary_frontend: "launch.sh".to_owned(),
                    control_source: Some("trimui/control.txt".to_owned()),
                    core_launcher_source: None,
                    frontend_map: vec![
                        FrontendMapEntry {
                            source: "trimui/PortMaster.txt".to_owned(),
                            destination: "launch.sh".to_owned(),
                        },
                        FrontendMapEntry {
                            source: "trimui/config.json".to_owned(),
                            destination: "config.json".to_owned(),
                        },
                        FrontendMapEntry {
                            source: "trimui/icon.png".to_owned(),
                            destination: "icon.png".to_owned(),
                        },
                    ],
                    remove_core_launcher: true,
                    empty_tasksetter: true,
                    core_executable: None,
                    frontend_executable: Some("launch.sh".to_owned()),
                    frontend_transforms: Vec::new(),
                    preserve_core_entries: vec![
                        "libs".to_owned(),
                        "config".to_owned(),
                        "themes".to_owned(),
                        "logs".to_owned(),
                        "cache".to_owned(),
                    ],
                },
            },
            _temp: temp,
        }
    }

    fn trimui_plan(context: &ResolvedDeviceContext) -> String {
        format!(
            concat!(
                "schema\t1\n",
                "device\tfuture-handheld\n",
                "target\t{}\n",
                "scripts\t{}\n",
                "frontend_dir\t{}\n",
                "frontend_names\tlaunch.sh,config.json,icon.png\n",
                "primary_frontend\tlaunch.sh\n",
                "control_source\ttrimui/control.txt\n",
                "core_launcher_source\t-\n",
                "frontend_map\ttrimui/PortMaster.txt=launch.sh,trimui/config.json=config.json,trimui/icon.png=icon.png\n",
                "remove_core_launcher\t1\n",
                "empty_tasksetter\t1\n",
                "core_executable\t-\n",
                "frontend_executable\tlaunch.sh\n"
            ),
            context.roots.portmaster.as_ref().unwrap().display(),
            context.roots.scripts.display(),
            context.frontend.directory.display(),
        )
    }

    #[test]
    fn validates_config_derived_arbitrary_profile_and_publishes_preserve_set() {
        let fixture = trimui_fixture();
        let parsed = InstallPlan::parse_tsv(trimui_plan(&fixture.context).as_bytes()).unwrap();
        let validated = parsed.validate(&fixture.context).unwrap();
        let generated = InstallPlan::from_context(&fixture.context).unwrap();
        assert_eq!(generated, parsed);
        assert_eq!(
            InstallPlan::parse_tsv(generated.to_tsv().unwrap().as_bytes()).unwrap(),
            generated
        );
        assert_eq!(validated.frontend_map.len(), 3);
        for name in ["libs", "config", "themes"] {
            assert!(
                validated
                    .preserve_core_entries
                    .iter()
                    .any(|entry| entry == name)
            );
        }
        assert_eq!(
            serde_json::to_string(&validated).unwrap(),
            serde_json::to_string(&parsed.validate(&fixture.context).unwrap()).unwrap()
        );
    }

    #[test]
    fn rejects_changed_map_traversal_and_system_managed_context() {
        let fixture = trimui_fixture();
        let bad_map = trimui_plan(&fixture.context).replace(
            "trimui/PortMaster.txt=launch.sh",
            "../PortMaster.txt=launch.sh",
        );
        let parsed = InstallPlan::parse_tsv(bad_map.as_bytes()).unwrap();
        assert!(parsed.validate(&fixture.context).is_err());

        let traversal = trimui_plan(&fixture.context).replace(
            &format!(
                "target\t{}",
                fixture.context.roots.portmaster.as_ref().unwrap().display()
            ),
            &format!(
                "target\t{}/../escape",
                fixture.context.roots.portmaster.as_ref().unwrap().display()
            ),
        );
        let parsed = InstallPlan::parse_tsv(traversal.as_bytes()).unwrap();
        assert!(matches!(
            parsed.validate(&fixture.context),
            Err(PlanError::UnsafePath { .. })
        ));

        let parsed = InstallPlan::parse_tsv(trimui_plan(&fixture.context).as_bytes()).unwrap();
        let mut unconfirmed = fixture.context.clone();
        unconfirmed.target_confirmed = false;
        assert!(matches!(
            parsed.validate(&unconfirmed),
            Err(PlanError::TargetUnconfirmed)
        ));

        let mut system = fixture.context.clone();
        system.management = ManagementMode::System;
        assert!(matches!(
            parsed.validate(&system),
            Err(PlanError::SystemManaged)
        ));
    }

    #[test]
    fn unknown_install_capability_fails_closed() {
        let fixture = trimui_fixture();
        let parsed = InstallPlan::parse_tsv(trimui_plan(&fixture.context).as_bytes()).unwrap();
        let mut unknown = fixture.context.clone();
        unknown.capabilities.install_plan = CapabilityState::Unknown;
        assert!(matches!(
            parsed.validate(&unknown),
            Err(PlanError::CapabilityUnknown)
        ));
    }

    #[cfg(unix)]
    #[test]
    fn rejects_an_existing_symlink_frontend_launcher() {
        use std::os::unix::fs::symlink;

        let fixture = trimui_fixture();
        let outside = fixture._temp.path().join("outside-launcher");
        fs::write(&outside, b"outside").unwrap();
        symlink(&outside, &fixture.context.frontend.launcher).unwrap();
        let parsed = InstallPlan::parse_tsv(trimui_plan(&fixture.context).as_bytes()).unwrap();
        assert!(matches!(
            parsed.validate(&fixture.context),
            Err(PlanError::Context(_))
        ));
    }
}
