use crate::config::{Config, ConfigLoader, ParserLimits, validate_literal_path};
use crate::predicate::Predicate;
use crate::{Error, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Component, Path, PathBuf};

pub const REQUIRED_CAPABILITIES: &[&str] = &[
    "install_portmaster",
    "update_portmaster",
    "repair_runtimes",
    "manage_portmaster",
    "manage_ports",
    "inventory_ports",
    "install_ports",
    "inventory_apps",
    "manage_apps",
    "install_apps",
    "manage_artwork",
    "manage_frontend",
    "manage_images",
    "trash",
    "leftovers",
    "cleanup_appledouble",
    "scan_script_images",
];

pub const PORT_LOCATION_KINDS: &[&str] = &["port_scripts", "port_data", "port_images"];

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct PathStrategy {
    pub strategy: String,
    #[serde(flatten)]
    pub arguments: BTreeMap<String, serde_json::Value>,
}

impl PathStrategy {
    pub fn validate(&self, limits: &ParserLimits) -> Result<()> {
        match self.strategy.as_str() {
            "literal" => {
                self.require_arguments(&["value"])?;
                validate_absolute_path(self.string("value")?, limits, "literal path")
            }
            "first_existing" => {
                self.require_arguments(&["candidates", "expected_type", "on_missing"])?;
                let candidates = self.strings("candidates")?;
                if candidates.is_empty() {
                    return Err(Error::InvalidConfig(
                        "first_existing path requires candidates".into(),
                    ));
                }
                for candidate in candidates {
                    validate_absolute_path(candidate, limits, "first_existing candidate")?;
                }
                if self
                    .arguments
                    .get("on_missing")
                    .is_some_and(|value| value.as_str() != Some("unresolved"))
                {
                    return Err(Error::InvalidConfig(
                        "first_existing on_missing must be \"unresolved\"".into(),
                    ));
                }
                self.expected_type().map(|_| ())
            }
            "launcher_dir" | "platform_core" => self.require_arguments(&[]),
            "rom_root_from_launcher" => {
                self.require_arguments(&["levels", "suffix", "value"])?;
                self.validate_levels(limits)?;
                validate_literal_path(self.string_any(&["suffix", "value"])?, limits)
            }
            "xdg_data_home" => {
                self.require_arguments(&["suffix"])?;
                if let Some(suffix) = self
                    .arguments
                    .get("suffix")
                    .and_then(serde_json::Value::as_str)
                {
                    validate_literal_path(suffix, limits)?;
                }
                Ok(())
            }
            "literal_by_launcher_prefix" => {
                self.require_arguments(&["prefix", "matched", "fallback"])?;
                validate_absolute_path(self.string("prefix")?, limits, "launcher prefix")?;
                validate_absolute_path(self.string("matched")?, limits, "matched path")?;
                let fallback = self.strings("fallback")?;
                if fallback.is_empty() {
                    return Err(Error::InvalidConfig(
                        "launcher prefix fallback cannot be empty".into(),
                    ));
                }
                for value in fallback {
                    validate_absolute_path(value, limits, "launcher prefix fallback")?;
                }
                Ok(())
            }
            "parent" => {
                self.require_arguments(&["path", "of", "base", "levels"])?;
                self.string_any(&["path", "of", "base"])?;
                self.validate_levels(limits)?;
                Ok(())
            }
            "relative_to" => {
                self.require_arguments(&[
                    "base",
                    "path",
                    "relative",
                    "value",
                    "suffix",
                    "canonicalize_existing",
                ])?;
                self.string_any(&["base", "path"])?;
                let relative = self.string_any(&["relative", "value", "suffix"])?;
                validate_literal_path(relative, limits)?;
                if self
                    .arguments
                    .get("canonicalize_existing")
                    .is_some_and(|value| !value.is_boolean())
                {
                    return Err(Error::InvalidConfig(
                        "relative_to canonicalize_existing must be a boolean".into(),
                    ));
                }
                Ok(())
            }
            other => Err(Error::InvalidConfig(format!(
                "unsupported path strategy {other:?}"
            ))),
        }
    }

    pub fn resolve(
        &self,
        name: &str,
        context: &DetectionContext,
        already_resolved: &BTreeMap<String, PathBuf>,
    ) -> Result<PathBuf> {
        let result =
            match self.strategy.as_str() {
                "literal" => context.rooted_path(self.string("value")?)?,
                "first_existing" => {
                    let candidates = self.strings("candidates")?;
                    let mut resolved = candidates.iter().map(|value| context.rooted_path(value));
                    let mut fallback = None;
                    let mut existing = None;
                    for candidate in resolved.by_ref() {
                        let candidate = candidate?;
                        fallback.get_or_insert_with(|| candidate.clone());
                        if self.matches_expected_type(&candidate)? {
                            existing = Some(candidate);
                            break;
                        }
                    }
                    existing.or(fallback).ok_or_else(|| {
                        Error::Resolution(format!("path {name:?} has no candidates"))
                    })?
                }
                "launcher_dir" => {
                    let parent = context.launcher_path.parent().ok_or_else(|| {
                        Error::Resolution("launcher has no parent directory".into())
                    })?;
                    context.rooted_path(&parent.to_string_lossy())?
                }
                "literal_by_launcher_prefix" => {
                    let value = if context.launcher_path.starts_with(self.string("prefix")?) {
                        self.string("matched")?
                    } else {
                        *self.strings("fallback")?.first().ok_or_else(|| {
                            Error::Resolution(format!("path {name:?} has no fallback"))
                        })?
                    };
                    context.rooted_path(value)?
                }
                "parent" => {
                    let base_name = self.string_any(&["path", "of", "base"])?;
                    let base = already_resolved.get(base_name).ok_or_else(|| {
                        Error::Resolution(format!(
                            "path {name:?} references unresolved path {base_name:?}"
                        ))
                    })?;
                    let levels = self
                        .arguments
                        .get("levels")
                        .and_then(serde_json::Value::as_u64)
                        .unwrap_or(1);
                    let mut value = base.as_path();
                    for _ in 0..levels {
                        value = value.parent().ok_or_else(|| {
                            Error::Resolution(format!("path {name:?} walks above its root"))
                        })?;
                    }
                    value.to_path_buf()
                }
                "platform_core" => already_resolved
                    .get("portmaster_core")
                    .or_else(|| already_resolved.get("platform_core"))
                    .cloned()
                    .ok_or_else(|| Error::Resolution("platform core path is unresolved".into()))?,
                "relative_to" => {
                    let base_name = self.string_any(&["base", "path"])?;
                    let base = already_resolved.get(base_name).ok_or_else(|| {
                        Error::Resolution(format!(
                            "path {name:?} references unresolved path {base_name:?}"
                        ))
                    })?;
                    safe_join(base, self.string_any(&["relative", "value", "suffix"])?)?
                }
                "rom_root_from_launcher" => {
                    let levels = self
                        .arguments
                        .get("levels")
                        .and_then(serde_json::Value::as_u64)
                        .unwrap_or(1);
                    let mut value = context.launcher_path.parent().ok_or_else(|| {
                        Error::Resolution("launcher has no parent directory".into())
                    })?;
                    for _ in 0..levels {
                        value = value.parent().ok_or_else(|| {
                            Error::Resolution("launcher path is too shallow for ROM root".into())
                        })?;
                    }
                    let value = context.rooted_path(&value.to_string_lossy())?;
                    safe_join(&value, self.string_any(&["suffix", "value"])?)?
                }
                "xdg_data_home" => context
                    .environment
                    .get("XDG_DATA_HOME")
                    .map(PathBuf::from)
                    .or_else(|| {
                        context
                            .environment
                            .get("HOME")
                            .map(|home| Path::new(home).join(".local/share"))
                    })
                    .map(|base| {
                        self.arguments
                            .get("suffix")
                            .and_then(serde_json::Value::as_str)
                            .map(|suffix| safe_join(&base, suffix))
                            .unwrap_or(Ok(base))
                    })
                    .transpose()?
                    .ok_or_else(|| Error::Resolution("XDG data home is unavailable".into()))?,
                other => {
                    return Err(Error::Resolution(format!(
                        "unsupported path strategy {other:?}"
                    )));
                }
            };
        if self
            .arguments
            .get("canonicalize_existing")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false)
        {
            match std::fs::canonicalize(&result) {
                Ok(canonical) => Ok(canonical),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(result),
                Err(error) => Err(Error::Resolution(format!(
                    "cannot resolve existing path {result:?}: {error}"
                ))),
            }
        } else {
            Ok(result)
        }
    }

    fn string(&self, name: &str) -> Result<&str> {
        self.arguments
            .get(name)
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| {
                Error::InvalidConfig(format!(
                    "{} path strategy requires string {name:?}",
                    self.strategy
                ))
            })
    }

    fn string_any(&self, names: &[&str]) -> Result<&str> {
        names
            .iter()
            .find_map(|name| {
                self.arguments
                    .get(*name)
                    .and_then(serde_json::Value::as_str)
            })
            .ok_or_else(|| {
                Error::InvalidConfig(format!(
                    "{} path strategy requires one of {:?}",
                    self.strategy, names
                ))
            })
    }

    fn strings(&self, name: &str) -> Result<Vec<&str>> {
        self.arguments
            .get(name)
            .and_then(serde_json::Value::as_array)
            .ok_or_else(|| {
                Error::InvalidConfig(format!(
                    "{} path strategy requires array {name:?}",
                    self.strategy
                ))
            })?
            .iter()
            .map(|value| {
                value.as_str().ok_or_else(|| {
                    Error::InvalidConfig(format!("{} path values must be strings", self.strategy))
                })
            })
            .collect()
    }

    fn expected_type(&self) -> Result<&str> {
        let value = self.string("expected_type")?;
        if matches!(value, "directory" | "file") {
            Ok(value)
        } else {
            Err(Error::InvalidConfig(format!(
                "first_existing path has unsupported expected_type {value:?}"
            )))
        }
    }

    fn matches_expected_type(&self, path: &Path) -> Result<bool> {
        let Ok(metadata) = std::fs::symlink_metadata(path) else {
            return Ok(false);
        };
        if metadata.file_type().is_symlink() {
            return Ok(false);
        }
        Ok(match self.expected_type()? {
            "directory" => metadata.file_type().is_dir(),
            "file" => metadata.file_type().is_file(),
            _ => unreachable!("validated expected_type"),
        })
    }

    fn validate_levels(&self, limits: &ParserLimits) -> Result<()> {
        let Some(value) = self.arguments.get("levels") else {
            return Ok(());
        };
        let levels = value.as_u64().filter(|levels| *levels > 0).ok_or_else(|| {
            Error::InvalidConfig(format!(
                "{} path levels must be a positive integer",
                self.strategy
            ))
        })?;
        if levels as u128 > limits.max_depth as u128 {
            return Err(Error::InvalidConfig(format!(
                "{} path levels exceed max_depth {}",
                self.strategy, limits.max_depth
            )));
        }
        Ok(())
    }

    fn require_arguments(&self, allowed: &[&str]) -> Result<()> {
        if let Some(name) = self
            .arguments
            .keys()
            .find(|name| !allowed.contains(&name.as_str()))
        {
            return Err(Error::InvalidConfig(format!(
                "{} path strategy contains unsupported field {name:?}",
                self.strategy
            )));
        }
        Ok(())
    }
}

fn safe_join(base: &Path, relative: &str) -> Result<PathBuf> {
    let relative = Path::new(relative);
    if relative.is_absolute()
        || relative.components().any(|part| {
            matches!(
                part,
                Component::ParentDir | Component::RootDir | Component::Prefix(_)
            )
        })
    {
        return Err(Error::Resolution(format!(
            "unsafe relative path {relative:?}"
        )));
    }
    Ok(base.join(relative))
}

fn validate_absolute_path(value: &str, limits: &ParserLimits, kind: &str) -> Result<()> {
    validate_literal_path(value, limits)?;
    let path = Path::new(value);
    if !path.is_absolute()
        || path.components().any(|part| {
            matches!(
                part,
                Component::ParentDir | Component::CurDir | Component::Prefix(_)
            )
        })
    {
        return Err(Error::InvalidConfig(format!(
            "{kind} must be a normalized absolute path"
        )));
    }
    Ok(())
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Platform {
    pub display_name: String,
    #[serde(default)]
    pub device_manufacturer: Option<String>,
    pub priority: i32,
    pub recognition: Predicate,
    #[serde(default)]
    pub required_adapters: Vec<String>,
    pub paths: BTreeMap<String, PathStrategy>,
    pub source_route: String,
    #[serde(default)]
    pub support: SupportPolicy,
    pub frontend: serde_json::Value,
    #[serde(default)]
    pub libraries: BTreeMap<String, serde_json::Value>,
    pub python: serde_json::Value,
    #[serde(default)]
    pub health: Vec<serde_json::Value>,
    #[serde(default)]
    pub preserved_dirs: Vec<String>,
    #[serde(default)]
    pub locations: Vec<Location>,
    #[serde(default)]
    pub capabilities: BTreeMap<String, bool>,
    #[serde(default)]
    pub environment_scopes: Vec<String>,
    pub display: serde_json::Value,
    pub input: serde_json::Value,
    #[serde(default)]
    pub models: Vec<Model>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, serde_json::Value>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum LocationKind {
    PortScripts,
    PortData,
    PortImages,
    Apps,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum LocationRole {
    Inventory,
    Install,
    Manage,
    Trash,
    TrashRestore,
    CleanupAppleDouble,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BundleFormat {
    Port,
    TrimuiApp,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Location {
    pub id: String,
    pub kind: LocationKind,
    /// Stable key into the platform's named path strategy graph.
    pub path: String,
    pub roles: Vec<LocationRole>,
    pub formats: Vec<BundleFormat>,
    pub priority: i32,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct SupportPolicy {
    #[serde(default = "default_device_class")]
    pub device_class: String,
    #[serde(default = "default_target_confirmation")]
    pub target_confirmation: String,
    #[serde(flatten)]
    pub extra: BTreeMap<String, serde_json::Value>,
}

fn default_device_class() -> String {
    "unsupported-known".into()
}
fn default_target_confirmation() -> String {
    "existing_core_or_override".into()
}

impl Default for SupportPolicy {
    fn default() -> Self {
        Self {
            device_class: default_device_class(),
            target_confirmation: default_target_confirmation(),
            extra: BTreeMap::new(),
        }
    }
}

impl Platform {
    pub fn validate(&self, limits: &ParserLimits) -> Result<()> {
        if !self.extra.is_empty() || !self.support.extra.is_empty() {
            return Err(Error::InvalidConfig(
                "platform contains unknown Config v1 fields".into(),
            ));
        }
        if self
            .device_manufacturer
            .as_deref()
            .is_some_and(|value| value.trim().is_empty())
        {
            return Err(Error::InvalidConfig(
                "device manufacturer must not be empty".into(),
            ));
        }
        let missing_capabilities = REQUIRED_CAPABILITIES
            .iter()
            .filter(|name| !self.capabilities.contains_key(**name))
            .copied()
            .collect::<Vec<_>>();
        if !missing_capabilities.is_empty() {
            return Err(Error::InvalidConfig(format!(
                "missing explicit capabilities {missing_capabilities:?}"
            )));
        }
        if self.locations.len() < 2 {
            return Err(Error::InvalidConfig(
                "platform requires at least two locations".into(),
            ));
        }
        self.recognition.validate(1, limits.max_depth)?;
        let mut model_ids = std::collections::BTreeSet::new();
        for model in &self.models {
            let id = &model.id;
            crate::config::validate_identifier("model", id)?;
            if !model_ids.insert(id.as_str()) {
                return Err(Error::InvalidConfig(format!("duplicate model id {id:?}")));
            }
            model.validate(limits).map_err(|error| match error {
                Error::InvalidConfig(message) => {
                    Error::InvalidConfig(format!("model {id:?}: {message}"))
                }
                other => other,
            })?;
            if !model.extra.is_empty() || !model.overrides.extra.is_empty() {
                return Err(Error::InvalidConfig(format!(
                    "model {id:?} contains unknown Config v1 fields"
                )));
            }
        }
        for path in self.paths.values() {
            path.validate(limits)?;
        }
        crate::health::validate_health_rules(&self.health, self.paths.keys())?;
        let mut location_ids = std::collections::BTreeSet::new();
        for location in &self.locations {
            crate::config::validate_identifier("location", &location.id)?;
            if !location_ids.insert(location.id.as_str()) {
                return Err(Error::InvalidConfig(format!(
                    "duplicate location id {:?}",
                    location.id
                )));
            }
            if !self.paths.contains_key(&location.path) {
                return Err(Error::InvalidConfig(format!(
                    "location {:?} references unknown path {:?}",
                    location.id, location.path
                )));
            }
            if location.roles.is_empty() {
                return Err(Error::InvalidConfig(format!(
                    "location {:?} has no roles",
                    location.id
                )));
            }
            let unique_roles = location
                .roles
                .iter()
                .collect::<std::collections::BTreeSet<_>>();
            if unique_roles.len() != location.roles.len() {
                return Err(Error::InvalidConfig(format!(
                    "location {:?} has duplicate roles",
                    location.id
                )));
            }
            let unique_formats = location
                .formats
                .iter()
                .collect::<std::collections::BTreeSet<_>>();
            if unique_formats.len() != location.formats.len() {
                return Err(Error::InvalidConfig(format!(
                    "location {:?} has duplicate formats",
                    location.id
                )));
            }
            match location.kind {
                LocationKind::Apps => {
                    if location.roles.contains(&LocationRole::Install)
                        && !location.formats.contains(&BundleFormat::TrimuiApp)
                    {
                        return Err(Error::InvalidConfig(format!(
                            "APP location {:?} must accept trimui_app",
                            location.id
                        )));
                    }
                }
                LocationKind::PortScripts | LocationKind::PortData => {
                    if location.roles.contains(&LocationRole::Install)
                        && !location.formats.contains(&BundleFormat::Port)
                    {
                        return Err(Error::InvalidConfig(format!(
                            "Port location {:?} must accept port",
                            location.id
                        )));
                    }
                }
                LocationKind::PortImages => {}
            }
        }
        for kind in [
            LocationKind::PortScripts,
            LocationKind::PortData,
            LocationKind::PortImages,
            LocationKind::Apps,
        ] {
            let candidates = self
                .locations
                .iter()
                .filter(|location| location.kind == kind)
                .collect::<Vec<_>>();
            let kind_required = match kind {
                LocationKind::PortScripts | LocationKind::PortData => true,
                LocationKind::PortImages => {
                    ["scan_script_images", "manage_artwork", "manage_images"]
                        .into_iter()
                        .any(|name| self.capabilities.get(name) == Some(&true))
                }
                LocationKind::Apps => ["inventory_apps", "manage_apps", "install_apps"]
                    .into_iter()
                    .any(|name| self.capabilities.get(name) == Some(&true)),
            };
            if kind_required && candidates.is_empty() {
                return Err(Error::InvalidConfig(format!(
                    "platform is missing a {kind:?} location"
                )));
            }
            unique_highest_location(&candidates, kind, false)?;

            let required_roles = required_location_roles(kind, &self.capabilities);
            let required_format = required_location_format(kind, &self.capabilities);
            let eligible = candidates
                .into_iter()
                .filter(|location| {
                    required_roles
                        .iter()
                        .all(|role| location.roles.contains(role))
                        && required_format.is_none_or(|format| location.formats.contains(&format))
                })
                .collect::<Vec<_>>();
            if kind_required && eligible.is_empty() {
                return Err(Error::InvalidConfig(format!(
                    "no {kind:?} location supports enabled roles"
                )));
            }
            if !eligible.is_empty() {
                unique_highest_location(&eligible, kind, true)?;
            }
        }
        let has_apps = self
            .locations
            .iter()
            .any(|location| location.kind == LocationKind::Apps);
        let app_capabilities_enabled = ["inventory_apps", "manage_apps", "install_apps"]
            .into_iter()
            .any(|name| self.capabilities.get(name) == Some(&true));
        if has_apps != app_capabilities_enabled {
            return Err(Error::InvalidConfig(
                "APP capabilities must match configured APP locations".into(),
            ));
        }
        if self.capabilities.get("install_apps") == Some(&true) {
            let eligible = self
                .locations
                .iter()
                .filter(|location| {
                    location.kind == LocationKind::Apps
                        && location.roles.contains(&LocationRole::Install)
                        && location.formats.contains(&BundleFormat::TrimuiApp)
                })
                .collect::<Vec<_>>();
            if eligible.is_empty() {
                return Err(Error::InvalidConfig(
                    "install_apps requires an APP install location".into(),
                ));
            }
            unique_highest_location(&eligible, LocationKind::Apps, true)?;
        }
        for (child, parent) in [
            ("install_portmaster", "manage_portmaster"),
            ("update_portmaster", "manage_portmaster"),
            ("install_ports", "manage_ports"),
            ("install_apps", "manage_apps"),
        ] {
            if self.capabilities.get(child) == Some(&true)
                && self.capabilities.get(parent) != Some(&true)
            {
                return Err(Error::InvalidConfig(format!(
                    "capability {child:?} requires {parent:?}"
                )));
            }
        }
        for directory in &self.preserved_dirs {
            validate_literal_path(directory, limits)?;
        }
        if !matches!(
            self.support.device_class.as_str(),
            "tested" | "official-untested" | "unsupported-known"
        ) {
            return Err(Error::InvalidConfig(format!(
                "unsupported device class {:?}",
                self.support.device_class
            )));
        }
        if !matches!(
            self.support.target_confirmation.as_str(),
            "detected" | "existing_core_or_override"
        ) {
            return Err(Error::InvalidConfig(format!(
                "unsupported target confirmation {:?}",
                self.support.target_confirmation
            )));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Model {
    pub id: String,
    #[serde(default)]
    pub priority: i32,
    pub display_name: String,
    #[serde(default)]
    pub device_manufacturer: Option<String>,
    pub recognition: Predicate,
    pub display: serde_json::Value,
    #[serde(default)]
    pub overrides: ModelOverrides,
    #[serde(flatten)]
    pub extra: BTreeMap<String, serde_json::Value>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct ModelOverrides {
    #[serde(default)]
    pub display: Option<serde_json::Value>,
    #[serde(default)]
    pub input: Option<serde_json::Value>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, serde_json::Value>,
}

impl Model {
    pub fn validate(&self, limits: &ParserLimits) -> Result<()> {
        if self
            .device_manufacturer
            .as_deref()
            .is_some_and(|value| value.trim().is_empty())
        {
            return Err(Error::InvalidConfig(
                "model device manufacturer must not be empty".into(),
            ));
        }
        if !self.display.is_object() {
            return Err(Error::InvalidConfig(
                "model display must be an object".into(),
            ));
        }
        for (name, value) in [
            ("display", self.overrides.display.as_ref()),
            ("input", self.overrides.input.as_ref()),
        ] {
            if value.is_some_and(|value| !value.is_object()) {
                return Err(Error::InvalidConfig(format!(
                    "model {name} override must be an object"
                )));
            }
        }
        self.recognition.validate(1, limits.max_depth)
    }
}

pub fn required_location_roles(
    kind: LocationKind,
    capabilities: &BTreeMap<String, bool>,
) -> Vec<LocationRole> {
    let mut roles = Vec::new();
    let mut push = |capability: &str, role: LocationRole| {
        if capabilities.get(capability) == Some(&true) && !roles.contains(&role) {
            roles.push(role);
        }
    };
    match kind {
        LocationKind::PortScripts | LocationKind::PortData => {
            push("inventory_ports", LocationRole::Inventory);
            push("install_ports", LocationRole::Install);
            push("manage_ports", LocationRole::Manage);
        }
        LocationKind::PortImages => {
            push("scan_script_images", LocationRole::Inventory);
            push("manage_artwork", LocationRole::Manage);
            push("manage_images", LocationRole::Manage);
        }
        LocationKind::Apps => {
            push("inventory_apps", LocationRole::Inventory);
            push("install_apps", LocationRole::Install);
            push("manage_apps", LocationRole::Manage);
        }
    }
    push("trash", LocationRole::Trash);
    push("trash", LocationRole::TrashRestore);
    push("cleanup_appledouble", LocationRole::CleanupAppleDouble);
    roles
}

pub fn required_location_format(
    kind: LocationKind,
    capabilities: &BTreeMap<String, bool>,
) -> Option<BundleFormat> {
    if matches!(kind, LocationKind::PortScripts | LocationKind::PortData)
        && capabilities.get("install_ports") == Some(&true)
    {
        Some(BundleFormat::Port)
    } else if kind == LocationKind::Apps && capabilities.get("install_apps") == Some(&true) {
        Some(BundleFormat::TrimuiApp)
    } else {
        None
    }
}

fn unique_highest_location(
    candidates: &[&Location],
    kind: LocationKind,
    eligible: bool,
) -> Result<()> {
    let Some(highest) = candidates.iter().map(|location| location.priority).max() else {
        return Ok(());
    };
    if candidates
        .iter()
        .filter(|location| location.priority == highest)
        .count()
        != 1
    {
        let qualifier = if eligible { "eligible " } else { "" };
        return Err(Error::InvalidConfig(format!(
            "ambiguous {qualifier}{kind:?} location at priority {highest}"
        )));
    }
    Ok(())
}

#[derive(Clone, Debug)]
pub struct DetectionContext {
    pub root: Option<PathBuf>,
    pub launcher_path: PathBuf,
    pub environment: BTreeMap<String, String>,
    pub os_release: BTreeMap<String, String>,
    /// Explicit operator-provided PortMaster core target. This is data, never shell code.
    pub target_override: Option<PathBuf>,
}

impl DetectionContext {
    pub fn current(launcher_path: impl Into<PathBuf>) -> Self {
        Self {
            root: None,
            launcher_path: launcher_path.into(),
            environment: std::env::vars().collect(),
            os_release: read_os_release(Path::new("/etc/os-release")),
            target_override: None,
        }
    }

    pub fn rooted_path(&self, value: &str) -> Result<PathBuf> {
        let path = Path::new(value);
        if path
            .components()
            .any(|part| matches!(part, Component::ParentDir))
        {
            return Err(Error::Resolution(format!("path traversal in {value:?}")));
        }
        match (&self.root, path.is_absolute()) {
            (Some(root), true) => Ok(root.join(path.strip_prefix("/").unwrap_or(path))),
            (Some(root), false) => Ok(root.join(path)),
            (None, _) => Ok(path.to_path_buf()),
        }
    }

    fn display_dimensions(&self) -> Option<(u64, u64)> {
        // fb*/modes describes the active scanout and, unlike virtual_size,
        // cannot accidentally report a double-buffered height (640x960 for a
        // 640x480 panel). Prefer it before the DRM connector mode list.
        let graphics = self.rooted_path("/sys/class/graphics").ok()?;
        if let Some(dimensions) = display_dimensions_in(&graphics, "fb", |entry| {
            std::fs::read_to_string(entry.join("modes")).ok()
        }) {
            return Some(dimensions);
        }

        let drm = self.rooted_path("/sys/class/drm").ok()?;
        display_dimensions_in(&drm, "card", |entry| {
            let name = entry.file_name()?.to_str()?;
            if !name.contains('-') {
                return None;
            }
            let status = std::fs::read_to_string(entry.join("status")).ok()?;
            if status.trim() != "connected" {
                return None;
            }
            if let Ok(enabled) = std::fs::read_to_string(entry.join("enabled"))
                && enabled.trim() == "disabled"
            {
                return None;
            }
            std::fs::read_to_string(entry.join("modes")).ok()
        })
    }
}

fn display_dimensions_in(
    directory: &Path,
    prefix: &str,
    read_modes: impl Fn(&Path) -> Option<String>,
) -> Option<(u64, u64)> {
    let mut entries = std::fs::read_dir(directory)
        .ok()?
        .filter_map(std::result::Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with(prefix))
        })
        .collect::<Vec<_>>();
    entries.sort();
    for entry in entries {
        if let Some(dimensions) = read_modes(&entry)
            .as_deref()
            .and_then(|modes| modes.lines().find_map(parse_display_mode))
        {
            return Some(dimensions);
        }
    }
    None
}

fn parse_display_mode(value: &str) -> Option<(u64, u64)> {
    let bytes = value.as_bytes();
    for (separator, byte) in bytes.iter().enumerate() {
        if *byte != b'x' {
            continue;
        }
        let width_start = bytes[..separator]
            .iter()
            .rposition(|byte| !byte.is_ascii_digit())
            .map_or(0, |index| index + 1);
        let height_end = bytes[separator + 1..]
            .iter()
            .position(|byte| !byte.is_ascii_digit())
            .map_or(bytes.len(), |index| separator + 1 + index);
        if width_start == separator || height_end == separator + 1 {
            continue;
        }
        let width = value[width_start..separator].parse::<u64>().ok()?;
        let height = value[separator + 1..height_end].parse::<u64>().ok()?;
        if width > 0 && height > 0 {
            return Some((width, height));
        }
    }
    None
}

fn read_os_release(path: &Path) -> BTreeMap<String, String> {
    let Ok(contents) = std::fs::read_to_string(path) else {
        return BTreeMap::new();
    };
    contents
        .lines()
        .filter_map(|line| {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                return None;
            }
            let (name, value) = line.split_once('=')?;
            Some((name.into(), value.trim_matches(['\'', '"']).into()))
        })
        .collect()
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Resolution {
    pub platform_id: String,
    pub platform_display_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_manufacturer: Option<String>,
    pub device_class: String,
    pub target_confirmed: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_display_name: Option<String>,
    pub adapters: Vec<String>,
    pub paths: BTreeMap<String, PathBuf>,
    pub source_route: String,
    pub capabilities: BTreeMap<String, bool>,
    pub frontend: serde_json::Value,
    pub libraries: BTreeMap<String, serde_json::Value>,
    pub python: serde_json::Value,
    pub health: Vec<serde_json::Value>,
    pub preserved_dirs: Vec<String>,
    #[serde(default)]
    pub locations: Vec<ResolvedLocation>,
    pub environment_scopes: Vec<String>,
    pub display: serde_json::Value,
    pub input: serde_json::Value,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ResolvedLocation {
    pub id: String,
    pub kind: LocationKind,
    pub path: PathBuf,
    pub roles: Vec<LocationRole>,
    pub formats: Vec<BundleFormat>,
    pub priority: i32,
}

impl Config {
    pub fn detect_and_resolve(
        &self,
        loader: &ConfigLoader,
        context: &DetectionContext,
    ) -> Result<Resolution> {
        let mut matches = Vec::new();
        for (id, platform) in &self.platforms {
            if platform.recognition.evaluate(context)? {
                matches.push((id, platform));
            }
        }
        matches.sort_by(|(left_id, left), (right_id, right)| {
            right
                .priority
                .cmp(&left.priority)
                .then_with(|| left_id.cmp(right_id))
        });
        if matches.len() > 1 && matches[0].1.priority == matches[1].1.priority {
            return Err(Error::Resolution(format!(
                "ambiguous platform recognition at priority {}: {:?} and {:?}",
                matches[0].1.priority, matches[0].0, matches[1].0
            )));
        }
        let (platform_id, platform) = matches
            .first()
            .copied()
            .ok_or_else(|| Error::Resolution("no platform recognition predicate matched".into()))?;

        let mut model_matches = Vec::new();
        for model in &platform.models {
            if model.recognition.evaluate(context)? {
                model_matches.push(model);
            }
        }
        model_matches.sort_by(|left, right| {
            right
                .priority
                .cmp(&left.priority)
                .then_with(|| left.id.cmp(&right.id))
        });
        if model_matches.len() > 1 && model_matches[0].priority == model_matches[1].priority {
            return Err(Error::Resolution(format!(
                "ambiguous model recognition at priority {}: {:?} and {:?}",
                model_matches[0].priority, model_matches[0].id, model_matches[1].id
            )));
        }
        let model = model_matches.first().copied();

        let adapters = loader.validate_resolved_closure(self, platform_id)?;
        let paths = resolve_paths(&platform.paths, context)?;
        let locations = platform
            .locations
            .iter()
            .map(|location| {
                let path = paths.get(&location.path).cloned().ok_or_else(|| {
                    Error::Resolution(format!(
                        "location {:?} references unresolved path {:?}",
                        location.id, location.path
                    ))
                })?;
                Ok(ResolvedLocation {
                    id: location.id.clone(),
                    kind: location.kind,
                    path,
                    roles: location.roles.clone(),
                    formats: location.formats.clone(),
                    priority: location.priority,
                })
            })
            .collect::<Result<Vec<_>>>()?;
        let target_confirmed = match platform.support.target_confirmation.as_str() {
            "detected" => true,
            "existing_core_or_override" => {
                context.target_override.is_some()
                    || paths
                        .get("portmaster_core")
                        .is_some_and(|path| path.is_dir() && path.join("control.txt").is_file())
            }
            _ => false,
        };
        let mut display = merged_model_value(
            &platform.display,
            model.map(|model| &model.display),
            model.and_then(|model| model.overrides.display.as_ref()),
        );
        if let (Some((width, height)), Some(display)) =
            (context.display_dimensions(), display.as_object_mut())
        {
            display.insert("default_width".into(), width.into());
            display.insert("default_height".into(), height.into());
        }
        Ok(Resolution {
            platform_id: platform_id.clone(),
            platform_display_name: platform.display_name.clone(),
            device_manufacturer: model
                .and_then(|model| model.device_manufacturer.clone())
                .or_else(|| platform.device_manufacturer.clone()),
            device_class: if target_confirmed {
                platform.support.device_class.clone()
            } else {
                "unknown-path".into()
            },
            target_confirmed,
            model_id: model.map(|model| model.id.clone()),
            model_display_name: model.map(|model| model.display_name.clone()),
            adapters,
            paths,
            source_route: platform.source_route.clone(),
            capabilities: platform.capabilities.clone(),
            frontend: platform.frontend.clone(),
            libraries: platform.libraries.clone(),
            python: platform.python.clone(),
            health: platform.health.clone(),
            preserved_dirs: platform.preserved_dirs.clone(),
            locations,
            environment_scopes: platform.environment_scopes.clone(),
            display,
            input: merged_model_value(
                &platform.input,
                None,
                model.and_then(|model| model.overrides.input.as_ref()),
            ),
        })
    }
}

fn merged_model_value(
    base: &serde_json::Value,
    model: Option<&serde_json::Value>,
    overrides: Option<&serde_json::Value>,
) -> serde_json::Value {
    let mut result = base.clone();
    for value in [model, overrides].into_iter().flatten() {
        if let (Some(target), Some(additions)) = (result.as_object_mut(), value.as_object()) {
            target.extend(additions.clone());
        } else {
            result = value.clone();
        }
    }
    result
}

fn resolve_paths(
    strategies: &BTreeMap<String, PathStrategy>,
    context: &DetectionContext,
) -> Result<BTreeMap<String, PathBuf>> {
    let mut resolved = BTreeMap::new();
    let mut remaining: BTreeMap<_, _> = strategies.iter().collect();
    while !remaining.is_empty() {
        let before = remaining.len();
        let names: Vec<_> = remaining.keys().cloned().collect();
        for name in names {
            let strategy = remaining[name];
            if name == "portmaster_core"
                && let Some(target) = &context.target_override
            {
                if !target.is_absolute()
                    || target
                        .components()
                        .any(|part| matches!(part, Component::ParentDir))
                {
                    return Err(Error::Resolution(format!(
                        "unsafe target override {target:?}"
                    )));
                }
                let target = context.rooted_path(&target.to_string_lossy())?;
                resolved.insert(name.clone(), target);
                remaining.remove(name);
                continue;
            }
            if strategy.strategy == "first_existing"
                && strategy
                    .arguments
                    .get("on_missing")
                    .and_then(serde_json::Value::as_str)
                    == Some("unresolved")
            {
                let matches = strategy
                    .strings("candidates")?
                    .into_iter()
                    .map(|value| context.rooted_path(value))
                    .collect::<Result<Vec<_>>>()?
                    .iter()
                    .map(|path| strategy.matches_expected_type(path))
                    .collect::<Result<Vec<_>>>()?;
                if !matches.into_iter().any(|value| value) {
                    remaining.remove(name);
                    continue;
                }
            }
            match strategy.resolve(name, context, &resolved) {
                Ok(value) => {
                    resolved.insert(name.clone(), value);
                    remaining.remove(name);
                }
                Err(Error::Resolution(message))
                    if message.contains("unresolved path")
                        || message.contains("platform core path is unresolved") => {}
                Err(error) => return Err(error),
            }
        }
        if remaining.len() == before {
            return Err(Error::Resolution(format!(
                "path strategy dependency cycle or missing reference: {:?}",
                remaining.keys().collect::<Vec<_>>()
            )));
        }
    }
    Ok(resolved)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn root_maps_absolute_device_paths_into_a_fixture() {
        let context = DetectionContext {
            root: Some(PathBuf::from("/fixture")),
            launcher_path: "/Roms/PORTS/a.sh".into(),
            environment: BTreeMap::new(),
            os_release: BTreeMap::new(),
            target_override: None,
        };
        assert_eq!(
            context.rooted_path("/opt/system").unwrap(),
            PathBuf::from("/fixture/opt/system")
        );
        assert!(context.rooted_path("/tmp/../etc").is_err());
    }

    #[test]
    fn detects_active_framebuffer_mode_without_using_virtual_buffer_size() {
        let fixture = tempfile::tempdir().unwrap();
        let fb = fixture.path().join("sys/class/graphics/fb0");
        std::fs::create_dir_all(&fb).unwrap();
        std::fs::write(fb.join("modes"), "U:640x480p-0\n").unwrap();
        std::fs::write(fb.join("virtual_size"), "640,960\n").unwrap();
        let context = DetectionContext {
            root: Some(fixture.path().to_path_buf()),
            launcher_path: "/storage/roms/ports/App.sh".into(),
            environment: BTreeMap::new(),
            os_release: BTreeMap::new(),
            target_override: None,
        };
        assert_eq!(context.display_dimensions(), Some((640, 480)));
    }

    #[test]
    fn detects_enabled_connected_drm_mode_as_secondary_source() {
        let fixture = tempfile::tempdir().unwrap();
        let connector = fixture.path().join("sys/class/drm/card0-DSI-1");
        std::fs::create_dir_all(&connector).unwrap();
        std::fs::write(connector.join("status"), "connected\n").unwrap();
        std::fs::write(connector.join("enabled"), "enabled\n").unwrap();
        std::fs::write(connector.join("modes"), "720x720\n640x480\n").unwrap();
        let context = DetectionContext {
            root: Some(fixture.path().to_path_buf()),
            launcher_path: "/storage/roms/ports/App.sh".into(),
            environment: BTreeMap::new(),
            os_release: BTreeMap::new(),
            target_override: None,
        };
        assert_eq!(context.display_dimensions(), Some((720, 720)));
    }

    #[test]
    fn display_mode_parser_accepts_kernel_and_drm_formats() {
        assert_eq!(parse_display_mode("U:640x480p-0"), Some((640, 480)));
        assert_eq!(parse_display_mode("1920x1080"), Some((1920, 1080)));
        assert_eq!(parse_display_mode("640,960"), None);
    }

    #[test]
    fn first_existing_directory_skips_files_and_symlinks() {
        use std::os::unix::fs::symlink;

        let fixture = tempfile::tempdir().unwrap();
        std::fs::create_dir(fixture.path().join("valid")).unwrap();
        std::fs::write(fixture.path().join("file"), b"not a directory").unwrap();
        symlink(fixture.path().join("valid"), fixture.path().join("link")).unwrap();
        let strategy: PathStrategy = serde_json::from_value(serde_json::json!({
            "strategy": "first_existing",
            "expected_type": "directory",
            "candidates": ["/file", "/link", "/valid"]
        }))
        .unwrap();
        strategy.validate(&ParserLimits::default()).unwrap();
        let context = DetectionContext {
            root: Some(fixture.path().to_path_buf()),
            launcher_path: "/launcher.sh".into(),
            environment: BTreeMap::new(),
            os_release: BTreeMap::new(),
            target_override: None,
        };
        assert_eq!(
            strategy
                .resolve("data", &context, &BTreeMap::new())
                .unwrap(),
            fixture.path().join("valid")
        );
    }
}
