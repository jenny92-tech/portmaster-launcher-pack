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
            "always" => require_empty_children(self),
            "all" | "any" => {
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
                self.string_argument_any(&["path", "value", "prefix"])?;
                Ok(())
            }
            "env_equals" => {
                require_empty_children(self)?;
                self.string_argument("name")?;
                self.string_argument("value")?;
                Ok(())
            }
            "os_release_equals" => {
                require_empty_children(self)?;
                self.string_argument_any(&["field", "name", "key"])?;
                self.string_argument("value")?;
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
}

fn compare(actual: &str, expected: &str, case_insensitive: bool) -> bool {
    if case_insensitive {
        actual.eq_ignore_ascii_case(expected)
    } else {
        actual == expected
    }
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
