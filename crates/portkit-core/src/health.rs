use crate::{Error, Resolution, Result, zip_readable};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Component, Path, PathBuf};

pub const HEALTH_CONTRACT: &str = "portkit.health.v1";
pub const HEALTH_REQUIRED_KINDS: &str =
    "required_file,executable_file,one_of_files,archive_or_nonempty_directory";

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum HealthStatus {
    Healthy,
    Damaged,
    Unresolved,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct HealthCheck {
    pub index: usize,
    pub kind: String,
    pub passed: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct HealthReport {
    pub contract: &'static str,
    pub platform_id: String,
    pub status: HealthStatus,
    pub healthy: bool,
    pub checks: Vec<HealthCheck>,
    pub python_mode: String,
    pub python_imports: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub python_runtime: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub python_runtime_image: Option<PathBuf>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub python_ready: Option<bool>,
}

pub fn evaluate_health(resolution: &Resolution) -> Result<HealthReport> {
    let python_mode = resolution
        .python
        .get("mode")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("")
        .to_owned();
    let mut python_imports = resolution
        .python
        .get("imports")
        .and_then(serde_json::Value::as_array)
        .map(|imports| parse_python_imports(imports, "python imports"))
        .transpose()?
        .unwrap_or_default();
    let mut python_runtime = None;
    for (index, rule) in resolution.health.iter().enumerate() {
        let Some(object) = rule.as_object() else {
            continue;
        };
        if object.get("kind").and_then(serde_json::Value::as_str)
            != Some("python_imports_or_runtime")
        {
            continue;
        }
        if let Some(imports) = object.get("imports").and_then(serde_json::Value::as_array) {
            python_imports = parse_python_imports(imports, "health python imports")?;
        }
        if let Some(runtime) = object.get("runtime") {
            let runtime = runtime.as_str().ok_or_else(|| {
                Error::InvalidConfig(format!("health rule {index} runtime is not a string"))
            })?;
            validate_runtime_name(runtime)?;
            python_runtime = Some(runtime.to_owned());
        }
    }
    let python_runtime_image = python_runtime.as_ref().and_then(|runtime| {
        resolution
            .paths
            .get("portmaster_core")
            .map(|core| core.join("libs").join(format!("{runtime}.squashfs")))
    });

    if !resolution.target_confirmed || !resolution.paths.contains_key("portmaster_core") {
        return Ok(HealthReport {
            contract: HEALTH_CONTRACT,
            platform_id: resolution.platform_id.clone(),
            status: HealthStatus::Unresolved,
            healthy: false,
            checks: Vec::new(),
            python_mode,
            python_imports,
            python_runtime,
            python_runtime_image,
            python_ready: None,
        });
    }

    let mut checks = Vec::new();
    for (index, rule) in resolution.health.iter().enumerate() {
        let object = rule
            .as_object()
            .ok_or_else(|| Error::InvalidConfig(format!("health rule {index} is not an object")))?;
        let kind = object
            .get("kind")
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| {
                Error::InvalidConfig(format!("health rule {index} has no string kind"))
            })?;
        let passed = match kind {
            "required_file" => health_path(object, "path", &resolution.paths)?.is_file(),
            "executable_file" => {
                let path = health_path(object, "path", &resolution.paths)?;
                executable_file(&path)
            }
            "one_of_files" => object
                .get("paths")
                .and_then(serde_json::Value::as_array)
                .ok_or_else(|| Error::InvalidConfig(format!("health rule {index} requires paths")))?
                .iter()
                .map(|value| {
                    let template = value.as_str().ok_or_else(|| {
                        Error::InvalidConfig(format!("health rule {index} path is not a string"))
                    })?;
                    Ok(expand_health_path(template, &resolution.paths)?.is_file())
                })
                .collect::<Result<Vec<_>>>()?
                .into_iter()
                .any(|exists| exists),
            "archive_or_nonempty_directory" => {
                let archive = health_path(object, "archive", &resolution.paths)?;
                let directory = health_path(object, "directory", &resolution.paths)?;
                zip_readable(&archive).unwrap_or(false)
                    || directory
                        .read_dir()
                        .is_ok_and(|mut entries| entries.next().is_some())
            }
            "python_imports_or_runtime" => {
                continue;
            }
            other => {
                return Err(Error::InvalidConfig(format!(
                    "unsupported health rule kind {other:?}"
                )));
            }
        };
        checks.push(HealthCheck {
            index,
            kind: kind.into(),
            passed,
        });
    }
    let healthy = checks.iter().all(|check| check.passed);
    Ok(HealthReport {
        contract: HEALTH_CONTRACT,
        platform_id: resolution.platform_id.clone(),
        status: if healthy {
            HealthStatus::Healthy
        } else {
            HealthStatus::Damaged
        },
        healthy,
        checks,
        python_mode,
        python_imports,
        python_runtime,
        python_runtime_image,
        python_ready: None,
    })
}

fn parse_python_imports(values: &[serde_json::Value], owner: &str) -> Result<Vec<String>> {
    values
        .iter()
        .map(|value| {
            let import = value.as_str().ok_or_else(|| {
                Error::InvalidConfig(format!("{owner} must contain only strings"))
            })?;
            if !is_python_dotted_identifier(import) {
                return Err(Error::InvalidConfig(format!(
                    "unsafe Python import name {import:?}"
                )));
            }
            Ok(import.to_owned())
        })
        .collect()
}

fn is_python_dotted_identifier(value: &str) -> bool {
    value.split('.').all(|part| {
        let mut bytes = part.bytes();
        bytes
            .next()
            .is_some_and(|byte| byte.is_ascii_alphabetic() || byte == b'_')
            && bytes.all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
    })
}

fn validate_runtime_name(runtime: &str) -> Result<()> {
    if runtime.is_empty()
        || matches!(runtime, "." | "..")
        || !runtime
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b'-'))
    {
        return Err(Error::InvalidConfig(format!(
            "unsafe Python runtime name {runtime:?}"
        )));
    }
    Ok(())
}

fn health_path(
    object: &serde_json::Map<String, serde_json::Value>,
    name: &str,
    paths: &BTreeMap<String, PathBuf>,
) -> Result<PathBuf> {
    let template = object
        .get(name)
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| Error::InvalidConfig(format!("health rule requires string {name:?}")))?;
    expand_health_path(template, paths)
}

fn expand_health_path(template: &str, paths: &BTreeMap<String, PathBuf>) -> Result<PathBuf> {
    let rest = template.strip_prefix('{').ok_or_else(|| {
        Error::InvalidConfig(format!(
            "health path {template:?} must start with a placeholder"
        ))
    })?;
    let close = rest.find('}').ok_or_else(|| {
        Error::InvalidConfig(format!("health path {template:?} has no path placeholder"))
    })?;
    let key = &rest[..close];
    let base = paths.get(key).ok_or_else(|| {
        Error::Resolution(format!("health path references unresolved path {key:?}"))
    })?;
    let suffix = &rest[close + 1..];
    let relative = Path::new(suffix.trim_start_matches('/'));
    if relative.components().any(|component| {
        matches!(
            component,
            Component::ParentDir | Component::RootDir | Component::Prefix(_)
        )
    }) || suffix.contains(['{', '}'])
    {
        return Err(Error::InvalidConfig(format!(
            "unsafe health path {template:?}"
        )));
    }
    Ok(base.join(relative))
}

#[cfg(unix)]
fn executable_file(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    path.metadata()
        .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}

#[cfg(not(unix))]
fn executable_file(path: &Path) -> bool {
    path.is_file()
}

#[cfg(test)]
mod tests {
    use super::is_python_dotted_identifier;

    #[test]
    fn python_imports_are_ascii_dotted_identifiers() {
        for valid in ["sys", "encodings.aliases", "_private.module_2"] {
            assert!(is_python_dotted_identifier(valid), "{valid:?}");
        }
        for invalid in [
            "",
            ".sys",
            "sys.",
            "a..b",
            "1module",
            "foo-bar",
            "foo bar",
            "sys;print(1)",
            "$(touch marker)",
        ] {
            assert!(!is_python_dotted_identifier(invalid), "{invalid:?}");
        }
    }
}
