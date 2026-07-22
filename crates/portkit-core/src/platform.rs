use crate::config::{Config, ConfigLoader, ParserLimits, validate_literal_path};
use crate::predicate::Predicate;
use crate::{Error, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Component, Path, PathBuf};

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct PathStrategy {
    pub strategy: String,
    #[serde(flatten)]
    pub arguments: BTreeMap<String, serde_json::Value>,
}

impl PathStrategy {
    pub fn validate(&self, limits: &ParserLimits) -> Result<()> {
        match self.strategy.as_str() {
            "literal" => validate_literal_path(self.string("value")?, limits),
            "first_existing" => {
                let candidates = self.strings("candidates")?;
                if candidates.is_empty() {
                    return Err(Error::InvalidConfig(
                        "first_existing path requires candidates".into(),
                    ));
                }
                for candidate in candidates {
                    validate_literal_path(candidate, limits)?;
                }
                Ok(())
            }
            "launcher_dir" | "platform_core" => Ok(()),
            "rom_root_from_launcher" => {
                self.validate_levels(limits)?;
                validate_literal_path(self.string_any(&["suffix", "value"])?, limits)
            }
            "xdg_data_home" => {
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
                validate_literal_path(self.string("prefix")?, limits)?;
                validate_literal_path(self.string("matched")?, limits)?;
                let fallback = self.strings("fallback")?;
                if fallback.is_empty() {
                    return Err(Error::InvalidConfig(
                        "launcher prefix fallback cannot be empty".into(),
                    ));
                }
                for value in fallback {
                    validate_literal_path(value, limits)?;
                }
                Ok(())
            }
            "parent" => {
                self.string_any(&["path", "of", "base"])?;
                self.validate_levels(limits)?;
                Ok(())
            }
            "relative_to" => {
                self.string_any(&["base", "path"])?;
                let relative = self.string_any(&["relative", "value", "suffix"])?;
                validate_literal_path(relative, limits)
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
        let result = match self.strategy.as_str() {
            "literal" => context.rooted_path(self.string("value")?)?,
            "first_existing" => {
                let candidates = self.strings("candidates")?;
                let mut resolved = candidates.iter().map(|value| context.rooted_path(value));
                let mut fallback = None;
                let mut existing = None;
                for candidate in resolved.by_ref() {
                    let candidate = candidate?;
                    fallback.get_or_insert_with(|| candidate.clone());
                    if candidate.exists() {
                        existing = Some(candidate);
                        break;
                    }
                }
                existing
                    .or(fallback)
                    .ok_or_else(|| Error::Resolution(format!("path {name:?} has no candidates")))?
            }
            "launcher_dir" => context
                .launcher_path
                .parent()
                .ok_or_else(|| Error::Resolution("launcher has no parent directory".into()))?
                .to_path_buf(),
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
                let mut value = context
                    .launcher_path
                    .parent()
                    .ok_or_else(|| Error::Resolution("launcher has no parent directory".into()))?;
                for _ in 0..levels {
                    value = value.parent().ok_or_else(|| {
                        Error::Resolution("launcher path is too shallow for ROM root".into())
                    })?;
                }
                safe_join(value, self.string_any(&["suffix", "value"])?)?
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
        Ok(result)
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

    fn validate_levels(&self, limits: &ParserLimits) -> Result<()> {
        if self
            .arguments
            .get("levels")
            .and_then(serde_json::Value::as_u64)
            .is_some_and(|levels| levels as u128 > limits.max_depth as u128)
        {
            return Err(Error::InvalidConfig(format!(
                "{} path levels exceed max_depth {}",
                self.strategy, limits.max_depth
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

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Platform {
    pub display_name: String,
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
    pub managed_roots: Vec<serde_json::Value>,
    #[serde(default)]
    pub capabilities: BTreeMap<String, bool>,
    #[serde(default)]
    pub environment_scopes: Vec<String>,
    pub lifecycle: serde_json::Value,
    pub display: serde_json::Value,
    pub input: serde_json::Value,
    #[serde(default)]
    pub models: BTreeMap<String, Model>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, serde_json::Value>,
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
        self.recognition.validate(1, limits.max_depth)?;
        for path in self.paths.values() {
            path.validate(limits)?;
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
    pub display_name: String,
    pub recognition: Predicate,
    #[serde(default)]
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
        self.recognition.validate(1, limits.max_depth)
    }
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

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct Resolution {
    pub platform_id: String,
    pub platform_display_name: String,
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
    pub managed_roots: Vec<serde_json::Value>,
    pub lifecycle: serde_json::Value,
    pub environment_scopes: Vec<String>,
    pub display: serde_json::Value,
    pub input: serde_json::Value,
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
        let (platform_id, platform) = matches
            .first()
            .copied()
            .ok_or_else(|| Error::Resolution("no platform recognition predicate matched".into()))?;

        let mut model_matches = Vec::new();
        for (id, model) in &platform.models {
            if model.recognition.evaluate(context)? {
                model_matches.push((id, model));
            }
        }
        model_matches.sort_by_key(|(id, _)| *id);
        let model = model_matches.first().copied();

        let adapters = loader.validate_resolved_closure(self, platform_id)?;
        let paths = resolve_paths(&platform.paths, context)?;
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
        Ok(Resolution {
            platform_id: platform_id.clone(),
            platform_display_name: platform.display_name.clone(),
            device_class: if target_confirmed {
                platform.support.device_class.clone()
            } else {
                "unknown-path".into()
            },
            target_confirmed,
            model_id: model.map(|(id, _)| id.clone()),
            model_display_name: model.map(|(_, model)| model.display_name.clone()),
            adapters,
            paths,
            source_route: platform.source_route.clone(),
            capabilities: platform.capabilities.clone(),
            frontend: platform.frontend.clone(),
            libraries: platform.libraries.clone(),
            python: platform.python.clone(),
            health: platform.health.clone(),
            preserved_dirs: platform.preserved_dirs.clone(),
            managed_roots: platform.managed_roots.clone(),
            lifecycle: platform.lifecycle.clone(),
            environment_scopes: platform.environment_scopes.clone(),
            display: merged_model_value(
                &platform.display,
                model.map(|(_, model)| &model.display),
                model.and_then(|(_, model)| model.overrides.display.as_ref()),
            ),
            input: model
                .and_then(|(_, model)| model.overrides.input.clone())
                .unwrap_or_else(|| platform.input.clone()),
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
            if name == "portmaster_core" {
                if let Some(target) = &context.target_override {
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
            }
            if strategy.strategy == "first_existing"
                && strategy
                    .arguments
                    .get("on_missing")
                    .and_then(serde_json::Value::as_str)
                    == Some("unresolved")
                && !strategy
                    .strings("candidates")?
                    .into_iter()
                    .map(|value| context.rooted_path(value))
                    .collect::<Result<Vec<_>>>()?
                    .iter()
                    .any(|path| path.exists())
            {
                remaining.remove(name);
                continue;
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
}
