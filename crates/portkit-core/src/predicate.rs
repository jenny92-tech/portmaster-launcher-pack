use crate::platform::DetectionContext;
use crate::{Error, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Predicate {
    pub kind: String,
    #[serde(default)]
    pub predicates: Vec<Predicate>,
    #[serde(flatten)]
    pub arguments: BTreeMap<String, serde_json::Value>,
}

impl Predicate {
    pub fn validate(&self, depth: usize, maximum_depth: usize) -> Result<()> {
        if depth > maximum_depth {
            return Err(Error::InvalidConfig(format!(
                "predicate nesting exceeds {maximum_depth}"
            )));
        }
        match self.kind.as_str() {
            "always" => {
                require_empty_children(self)?;
                self.require_arguments(&[])
            }
            "all" | "any" => {
                self.require_arguments(&[])?;
                if self.predicates.is_empty() {
                    return Err(Error::InvalidConfig(format!(
                        "{} predicate must contain at least one child",
                        self.kind
                    )));
                }
                for predicate in &self.predicates {
                    predicate.validate(depth + 1, maximum_depth)?;
                }
                Ok(())
            }
            "directory_exists" | "file_exists" | "launcher_path_prefix" => {
                require_empty_children(self)?;
                self.require_arguments(&["path", "value", "prefix"])?;
                self.string_argument_any(&["path", "value", "prefix"])?;
                Ok(())
            }
            "env_equals" => {
                require_empty_children(self)?;
                self.require_arguments(&["name", "value", "case_insensitive"])?;
                self.validate_case_insensitive()?;
                self.string_argument("name")?;
                self.string_argument("value")?;
                Ok(())
            }
            "os_release_equals" => {
                require_empty_children(self)?;
                self.require_arguments(&["field", "name", "key", "value", "case_insensitive"])?;
                self.validate_case_insensitive()?;
                self.string_argument_any(&["field", "name", "key"])?;
                self.string_argument("value")?;
                Ok(())
            }
            "os_release_version_at_least" => {
                require_empty_children(self)?;
                self.require_arguments(&["field", "value"])?;
                self.string_argument("field")?;
                parse_numeric_version(self.string_argument("value")?)?;
                Ok(())
            }
            other => Err(Error::InvalidConfig(format!(
                "unsupported predicate kind {other:?}"
            ))),
        }
    }

    pub fn evaluate(&self, context: &DetectionContext) -> Result<bool> {
        match self.kind.as_str() {
            "always" => Ok(true),
            "all" => {
                for predicate in &self.predicates {
                    if !predicate.evaluate(context)? {
                        return Ok(false);
                    }
                }
                Ok(true)
            }
            "any" => {
                for predicate in &self.predicates {
                    if predicate.evaluate(context)? {
                        return Ok(true);
                    }
                }
                Ok(false)
            }
            "directory_exists" => Ok(context
                .rooted_path(self.string_argument_any(&["path", "value"])?)?
                .is_dir()),
            "file_exists" => Ok(context
                .rooted_path(self.string_argument_any(&["path", "value"])?)?
                .is_file()),
            "launcher_path_prefix" => Ok(context
                .launcher_path
                .starts_with(self.string_argument_any(&["prefix", "path", "value"])?)),
            "env_equals" => {
                let expected = self.string_argument("value")?;
                Ok(context
                    .environment
                    .get(self.string_argument("name")?)
                    .is_some_and(|value| compare(value, expected, self.case_insensitive())))
            }
            "os_release_equals" => Ok(context
                .os_release
                .get(self.string_argument_any(&["field", "name", "key"])?)
                .is_some_and(|value| {
                    compare(
                        value,
                        self.string_argument("value").unwrap_or_default(),
                        self.case_insensitive(),
                    )
                })),
            "os_release_version_at_least" => {
                let Some(actual) = context.os_release.get(self.string_argument("field")?) else {
                    return Ok(false);
                };
                let Some(actual) = parse_numeric_version_for_detection(actual) else {
                    return Ok(false);
                };
                let expected = parse_numeric_version(self.string_argument("value")?)?;
                Ok(compare_numeric_versions(&actual, &expected).is_ge())
            }
            // A future predicate cannot match on an older engine. If its
            // platform wins by another known predicate, selected-platform
            // validation will still reject the unsupported closure.
            _ => Ok(false),
        }
    }

    pub fn string_argument(&self, name: &str) -> Result<&str> {
        self.arguments
            .get(name)
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| {
                Error::InvalidConfig(format!(
                    "{} predicate requires string field {name:?}",
                    self.kind
                ))
            })
    }

    fn string_argument_any(&self, names: &[&str]) -> Result<&str> {
        for name in names {
            if let Some(value) = self
                .arguments
                .get(*name)
                .and_then(serde_json::Value::as_str)
            {
                return Ok(value);
            }
        }
        Err(Error::InvalidConfig(format!(
            "{} predicate requires one of {:?}",
            self.kind, names
        )))
    }

    fn case_insensitive(&self) -> bool {
        self.arguments
            .get("case_insensitive")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false)
    }

    fn validate_case_insensitive(&self) -> Result<()> {
        if self
            .arguments
            .get("case_insensitive")
            .is_some_and(|value| !value.is_boolean())
        {
            return Err(Error::InvalidConfig(format!(
                "{} predicate case_insensitive must be a boolean",
                self.kind
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
                "{} predicate contains unsupported field {name:?}",
                self.kind
            )));
        }
        Ok(())
    }
}

fn compare(actual: &str, expected: &str, case_insensitive: bool) -> bool {
    if case_insensitive {
        actual.eq_ignore_ascii_case(expected)
    } else {
        actual == expected
    }
}

fn parse_numeric_version(value: &str) -> Result<Vec<u64>> {
    parse_numeric_version_for_detection(value).ok_or_else(|| {
        Error::InvalidConfig(format!(
            "numeric OS version must contain 1 to 8 dot-separated integers: {value:?}"
        ))
    })
}

fn parse_numeric_version_for_detection(value: &str) -> Option<Vec<u64>> {
    let parts = value.split('.').collect::<Vec<_>>();
    if parts.is_empty() || parts.len() > 8 || parts.iter().any(|part| part.is_empty()) {
        return None;
    }
    parts
        .into_iter()
        .map(|part| {
            part.bytes()
                .all(|byte| byte.is_ascii_digit())
                .then_some(())?;
            part.parse::<u64>().ok()
        })
        .collect()
}

fn compare_numeric_versions(left: &[u64], right: &[u64]) -> std::cmp::Ordering {
    let width = left.len().max(right.len());
    (0..width)
        .map(|index| {
            left.get(index)
                .copied()
                .unwrap_or_default()
                .cmp(&right.get(index).copied().unwrap_or_default())
        })
        .find(|ordering| !ordering.is_eq())
        .unwrap_or(std::cmp::Ordering::Equal)
}

fn require_empty_children(predicate: &Predicate) -> Result<()> {
    if predicate.predicates.is_empty() {
        Ok(())
    } else {
        Err(Error::InvalidConfig(format!(
            "{} predicate cannot have child predicates",
            predicate.kind
        )))
    }
}
