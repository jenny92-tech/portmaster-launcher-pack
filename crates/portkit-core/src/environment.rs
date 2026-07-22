use crate::{Error, Result};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsStr;
use std::path::PathBuf;
use std::process::Command;

const NATIVE_BLOCKED_NAMES: &[&str] = &[
    "LD_PRELOAD",
    "LD_AUDIT",
    "GCONV_PATH",
    "BASH_ENV",
    "ENV",
    "SHELLOPTS",
    "BASHOPTS",
    "IFS",
    "PS4",
];
const NATIVE_BLOCKED_PREFIXES: &[&str] = &["BASH_FUNC_"];

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct EnvironmentPolicy {
    #[serde(default = "default_inherit")]
    pub inherit: String,
    #[serde(default = "default_value_handling")]
    pub value_handling: String,
    #[serde(default = "default_blocked_names")]
    pub blocked_names: BTreeSet<String>,
    #[serde(default = "default_blocked_prefixes")]
    pub blocked_prefixes: Vec<String>,
    #[serde(default)]
    pub operation_kinds: Vec<String>,
    #[serde(default)]
    pub profiles: BTreeMap<String, Vec<EnvironmentOperation>>,
    #[serde(default)]
    pub scopes: BTreeMap<String, EnvironmentScope>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, serde_json::Value>,
}

fn default_inherit() -> String {
    "all_except_blocked".into()
}
fn default_value_handling() -> String {
    "literal".into()
}
fn default_blocked_names() -> BTreeSet<String> {
    NATIVE_BLOCKED_NAMES
        .iter()
        .map(|name| (*name).into())
        .collect()
}
fn default_blocked_prefixes() -> Vec<String> {
    NATIVE_BLOCKED_PREFIXES
        .iter()
        .map(|prefix| (*prefix).into())
        .collect()
}

impl Default for EnvironmentPolicy {
    fn default() -> Self {
        Self {
            inherit: default_inherit(),
            value_handling: default_value_handling(),
            blocked_names: default_blocked_names(),
            blocked_prefixes: default_blocked_prefixes(),
            operation_kinds: vec![
                "set".into(),
                "prepend".into(),
                "append".into(),
                "unset".into(),
            ],
            profiles: BTreeMap::new(),
            scopes: BTreeMap::new(),
            extra: BTreeMap::new(),
        }
    }
}

impl EnvironmentPolicy {
    pub fn validate(&self) -> Result<()> {
        if self.inherit != "all_except_blocked" {
            return Err(Error::Environment(format!(
                "unsupported inheritance policy {:?}",
                self.inherit
            )));
        }
        if self.value_handling != "literal" {
            return Err(Error::Environment(format!(
                "unsupported value handling {:?}",
                self.value_handling
            )));
        }
        if self.blocked_names != default_blocked_names() {
            return Err(Error::Environment(
                "blocked_names must exactly match the native dangerous-variable set".into(),
            ));
        }
        if self.blocked_prefixes != default_blocked_prefixes() {
            return Err(Error::Environment(
                "blocked_prefixes must exactly match the native dangerous-variable set".into(),
            ));
        }
        for (profile, operations) in &self.profiles {
            for operation in operations {
                self.validate_operation(profile, operation)?;
            }
        }
        for (scope, definition) in &self.scopes {
            for profile in &definition.profiles {
                if !self.profiles.contains_key(profile) {
                    return Err(Error::Environment(format!(
                        "scope {scope:?} references unknown profile {profile:?}"
                    )));
                }
            }
            for operation in &definition.operations {
                self.validate_operation(scope, operation)?;
            }
        }
        Ok(())
    }

    pub fn allows(&self, name: &str) -> bool {
        valid_name(name)
            && !NATIVE_BLOCKED_NAMES.contains(&name)
            && !NATIVE_BLOCKED_PREFIXES
                .iter()
                .any(|prefix| name.starts_with(prefix))
    }

    pub fn require_allowed(&self, name: &str) -> Result<()> {
        if self.allows(name) {
            Ok(())
        } else {
            Err(Error::Environment(format!(
                "environment name {name:?} is invalid or blocked"
            )))
        }
    }

    fn validate_operation(&self, owner: &str, operation: &EnvironmentOperation) -> Result<()> {
        self.require_allowed(operation.name())?;
        if operation
            .separator()
            .is_some_and(|separator| separator.is_empty() || separator.contains('\0'))
        {
            return Err(Error::Environment(format!(
                "environment operation in {owner:?} has invalid separator"
            )));
        }
        Ok(())
    }

    pub fn command_environment_for_scope(
        &self,
        scope: &str,
        variables: &BTreeMap<String, String>,
    ) -> Result<CommandEnvironment> {
        let definition = self
            .scopes
            .get(scope)
            .ok_or_else(|| Error::Environment(format!("unknown environment scope {scope:?}")))?;
        let mut operations = Vec::new();
        for profile in &definition.profiles {
            for operation in &self.profiles[profile] {
                operations.push(operation.expand(variables)?);
            }
        }
        for operation in &definition.operations {
            operations.push(operation.expand(variables)?);
        }
        Ok(CommandEnvironment {
            clear: false,
            operations,
        })
    }
}

fn valid_name(name: &str) -> bool {
    let mut chars = name.bytes();
    matches!(chars.next(), Some(b'A'..=b'Z' | b'a'..=b'z' | b'_'))
        && chars.all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "operation", rename_all = "snake_case")]
pub enum EnvironmentOperation {
    Set {
        name: String,
        value: String,
    },
    SetDefault {
        name: String,
        value: String,
    },
    Unset {
        name: String,
    },
    #[serde(alias = "prepend_path")]
    Prepend {
        name: String,
        value: String,
        #[serde(default)]
        separator: Option<String>,
    },
    #[serde(alias = "append_path")]
    Append {
        name: String,
        value: String,
        #[serde(default)]
        separator: Option<String>,
    },
}

impl EnvironmentOperation {
    fn name(&self) -> &str {
        match self {
            Self::Set { name, .. }
            | Self::SetDefault { name, .. }
            | Self::Unset { name }
            | Self::Prepend { name, .. }
            | Self::Append { name, .. } => name,
        }
    }
    fn separator(&self) -> Option<&str> {
        match self {
            Self::Prepend { separator, .. } | Self::Append { separator, .. } => {
                separator.as_deref()
            }
            _ => None,
        }
    }
    fn expand(&self, variables: &BTreeMap<String, String>) -> Result<Self> {
        Ok(match self {
            Self::Set { name, value } => Self::Set {
                name: name.clone(),
                value: expand_placeholders(value, variables)?,
            },
            Self::SetDefault { name, value } => Self::SetDefault {
                name: name.clone(),
                value: expand_placeholders(value, variables)?,
            },
            Self::Unset { name } => Self::Unset { name: name.clone() },
            Self::Prepend {
                name,
                value,
                separator,
            } => Self::Prepend {
                name: name.clone(),
                value: expand_placeholders(value, variables)?,
                separator: separator.clone(),
            },
            Self::Append {
                name,
                value,
                separator,
            } => Self::Append {
                name: name.clone(),
                value: expand_placeholders(value, variables)?,
                separator: separator.clone(),
            },
        })
    }
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct EnvironmentScope {
    #[serde(default)]
    pub profiles: Vec<String>,
    #[serde(default)]
    pub operations: Vec<EnvironmentOperation>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, serde_json::Value>,
}

fn expand_placeholders(value: &str, variables: &BTreeMap<String, String>) -> Result<String> {
    let mut output = String::with_capacity(value.len());
    let mut remainder = value;
    while let Some(open) = remainder.find('{') {
        output.push_str(&remainder[..open]);
        let after_open = &remainder[open + 1..];
        let close = after_open
            .find('}')
            .ok_or_else(|| Error::Environment(format!("unterminated placeholder in {value:?}")))?;
        let name = &after_open[..close];
        if !valid_name(name) {
            return Err(Error::Environment(format!("invalid placeholder {name:?}")));
        }
        output.push_str(variables.get(name).ok_or_else(|| {
            Error::Environment(format!("missing placeholder value for {name:?}"))
        })?);
        remainder = &after_open[close + 1..];
    }
    if remainder.contains('}') {
        return Err(Error::Environment(format!(
            "unmatched closing brace in {value:?}"
        )));
    }
    output.push_str(remainder);
    Ok(output)
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct CommandEnvironment {
    #[serde(default)]
    pub clear: bool,
    #[serde(default)]
    pub operations: Vec<EnvironmentOperation>,
}

impl CommandEnvironment {
    pub fn resolve<I, K, V>(
        &self,
        policy: &EnvironmentPolicy,
        inherited: I,
    ) -> Result<BTreeMap<String, String>>
    where
        I: IntoIterator<Item = (K, V)>,
        K: AsRef<OsStr>,
        V: AsRef<OsStr>,
    {
        policy.validate()?;
        let mut resolved = BTreeMap::new();
        if !self.clear {
            for (name, value) in inherited {
                let Some(name) = name.as_ref().to_str() else {
                    continue;
                };
                if policy.allows(name) {
                    resolved.insert(
                        name.to_owned(),
                        value.as_ref().to_string_lossy().into_owned(),
                    );
                }
            }
        }
        for operation in &self.operations {
            match operation {
                EnvironmentOperation::Set { name, value } => {
                    policy.require_allowed(name)?;
                    resolved.insert(name.clone(), value.clone());
                }
                EnvironmentOperation::SetDefault { name, value } => {
                    policy.require_allowed(name)?;
                    resolved
                        .entry(name.clone())
                        .or_insert_with(|| value.clone());
                }
                EnvironmentOperation::Unset { name } => {
                    policy.require_allowed(name)?;
                    resolved.remove(name);
                }
                EnvironmentOperation::Prepend {
                    name,
                    value,
                    separator,
                } => {
                    policy.require_allowed(name)?;
                    let joined = join_value(value, resolved.get(name), true, separator.as_deref())?;
                    resolved.insert(name.clone(), joined);
                }
                EnvironmentOperation::Append {
                    name,
                    value,
                    separator,
                } => {
                    policy.require_allowed(name)?;
                    let joined =
                        join_value(value, resolved.get(name), false, separator.as_deref())?;
                    resolved.insert(name.clone(), joined);
                }
            }
        }
        Ok(resolved)
    }

    /// Applies literal values directly to a process. No shell or evaluation is involved.
    pub fn apply_to_command<I, K, V>(
        &self,
        command: &mut Command,
        policy: &EnvironmentPolicy,
        inherited: I,
    ) -> Result<()>
    where
        I: IntoIterator<Item = (K, V)>,
        K: AsRef<OsStr>,
        V: AsRef<OsStr>,
    {
        let resolved = self.resolve(policy, inherited)?;
        command.env_clear();
        command.envs(resolved);
        Ok(())
    }
}

fn join_value(
    value: &str,
    previous: Option<&String>,
    prepend: bool,
    separator: Option<&str>,
) -> Result<String> {
    if let Some(separator) = separator {
        return Ok(
            match (prepend, previous.filter(|value| !value.is_empty())) {
                (_, None) => value.to_owned(),
                (true, Some(previous)) => format!("{value}{separator}{previous}"),
                (false, Some(previous)) => format!("{previous}{separator}{value}"),
            },
        );
    }
    let mut paths = Vec::<PathBuf>::new();
    if prepend {
        paths.push(value.into());
    }
    if let Some(previous) = previous {
        paths.extend(std::env::split_paths(previous));
    }
    if !prepend {
        paths.push(value.into());
    }
    std::env::join_paths(paths)
        .map(|value| value.to_string_lossy().into_owned())
        .map_err(|error| Error::Environment(format!("invalid path-list value: {error}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn policy_is_default_open_but_blocks_loader_and_shell_vectors() {
        let policy = EnvironmentPolicy::default();
        assert!(policy.allows("GAME_DATA_DIR"));
        assert!(!policy.allows("LD_PRELOAD"));
        assert!(!policy.allows("BASH_FUNC_payload%%"));
        assert!(!policy.allows("not-valid"));
    }
    #[test]
    fn operations_are_literal_and_ordered() {
        let environment = CommandEnvironment {
            clear: false,
            operations: vec![
                EnvironmentOperation::SetDefault {
                    name: "MODE".into(),
                    value: "default".into(),
                },
                EnvironmentOperation::Set {
                    name: "PAYLOAD".into(),
                    value: "$(touch /tmp/must-not-run)".into(),
                },
                EnvironmentOperation::Prepend {
                    name: "PATH".into(),
                    value: "/portable/bin".into(),
                    separator: Some(":".into()),
                },
            ],
        };
        let result = environment
            .resolve(
                &EnvironmentPolicy::default(),
                [
                    ("MODE", "custom"),
                    ("PATH", "/usr/bin"),
                    ("LD_AUDIT", "bad"),
                ],
            )
            .unwrap();
        assert_eq!(result["MODE"], "custom");
        assert_eq!(result["PAYLOAD"], "$(touch /tmp/must-not-run)");
        assert_eq!(result["PATH"], "/portable/bin:/usr/bin");
        assert!(!result.contains_key("LD_AUDIT"));
    }
    #[test]
    fn blocked_names_cannot_be_added_back() {
        let environment = CommandEnvironment {
            clear: false,
            operations: vec![EnvironmentOperation::Set {
                name: "LD_PRELOAD".into(),
                value: "/tmp/inject.so".into(),
            }],
        };
        assert!(
            environment
                .resolve(
                    &EnvironmentPolicy::default(),
                    std::iter::empty::<(&str, &str)>()
                )
                .is_err()
        );
    }

    #[test]
    fn config_cannot_expand_or_shrink_the_native_denylist() {
        let mut policy = EnvironmentPolicy::default();
        policy.blocked_names.insert("HARMLESS_USER_SETTING".into());
        assert!(policy.validate().is_err());

        let mut policy = EnvironmentPolicy::default();
        policy.blocked_names.remove("LD_PRELOAD");
        assert!(policy.validate().is_err());

        let mut policy = EnvironmentPolicy::default();
        policy.blocked_prefixes.push("USER_".into());
        assert!(policy.validate().is_err());

        let mut policy = EnvironmentPolicy::default();
        policy.blocked_prefixes.clear();
        assert!(policy.validate().is_err());
    }

    #[test]
    fn applied_command_environment_excludes_inherited_native_dangers() {
        let policy = EnvironmentPolicy::default();
        let environment = CommandEnvironment::default();
        let mut command = Command::new("child");
        environment
            .apply_to_command(
                &mut command,
                &policy,
                [
                    ("SAFE_VALUE", "kept"),
                    ("LD_PRELOAD", "blocked"),
                    ("LD_AUDIT", "blocked"),
                    ("BASH_FUNC_payload", "blocked"),
                ],
            )
            .unwrap();
        let applied: BTreeMap<_, _> = command
            .get_envs()
            .filter_map(|(name, value)| Some((name.to_str()?, value?.to_str()?)))
            .collect();
        assert_eq!(applied.get("SAFE_VALUE"), Some(&"kept"));
        assert!(!applied.contains_key("LD_PRELOAD"));
        assert!(!applied.contains_key("LD_AUDIT"));
        assert!(!applied.keys().any(|name| name.starts_with("BASH_FUNC_")));
    }
}
