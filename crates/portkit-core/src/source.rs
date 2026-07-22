use crate::config::parse_config_version;
use crate::{Config, ConfigLoader, DetectionContext, Error, FragmentSource, Resolution, Result};
use serde::Serialize;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ConfigOrigin {
    Embedded,
    Remote,
}

#[derive(Clone, Debug)]
pub struct ConfigCandidate {
    pub origin: ConfigOrigin,
    pub bytes: Vec<u8>,
}
impl ConfigCandidate {
    pub fn embedded(bytes: impl Into<Vec<u8>>) -> Self {
        Self {
            origin: ConfigOrigin::Embedded,
            bytes: bytes.into(),
        }
    }
    pub fn remote(bytes: impl Into<Vec<u8>>) -> Self {
        Self {
            origin: ConfigOrigin::Remote,
            bytes: bytes.into(),
        }
    }
}

#[derive(Clone, Debug)]
pub struct SelectedConfig {
    pub origin: ConfigOrigin,
    pub config: Config,
}

#[derive(Clone, Debug)]
pub struct ResolvedSelection {
    pub selected: SelectedConfig,
    pub resolution: Resolution,
}

#[derive(Clone, Debug)]
pub struct CandidateSelector {
    pub loader: ConfigLoader,
}

impl CandidateSelector {
    /// Loads one explicitly named platform for config validation. Remote roots
    /// are accepted only when strictly newer and their selected detail passes
    /// all digest/identity/compatibility checks.
    pub fn select_root_platform(
        &self,
        embedded: ConfigCandidate,
        embedded_details: &dyn FragmentSource,
        remote: Option<(ConfigCandidate, &dyn FragmentSource)>,
        platform_id: &str,
    ) -> Result<SelectedConfig> {
        if embedded.origin != ConfigOrigin::Embedded {
            return Err(Error::InvalidConfig(
                "fallback candidate must have embedded origin".into(),
            ));
        }
        let embedded_root = self.loader.parse_root(&embedded.bytes)?;
        let embedded_config =
            self.loader
                .load_platform(embedded_root, platform_id, embedded_details)?;
        if let Some((remote, remote_details)) = remote {
            if remote.origin != ConfigOrigin::Remote {
                return Err(Error::InvalidConfig(
                    "optional candidate must have remote origin".into(),
                ));
            }
            if let Ok(remote_root) = self.loader.parse_root(&remote.bytes) {
                let newer = compare_config_versions(
                    &remote_root.config_version,
                    &embedded_config.config_version,
                )
                .is_ok_and(|ordering| ordering.is_gt());
                if newer {
                    if let Ok(config) =
                        self.loader
                            .load_platform(remote_root, platform_id, remote_details)
                    {
                        if self
                            .loader
                            .validate_resolved_closure(&config, platform_id)
                            .is_ok()
                        {
                            return Ok(SelectedConfig {
                                origin: ConfigOrigin::Remote,
                                config,
                            });
                        }
                    }
                }
            }
        }
        Ok(SelectedConfig {
            origin: ConfigOrigin::Embedded,
            config: embedded_config,
        })
    }

    /// Selects a root without downgrading, detects from that root, and loads
    /// only its selected detail. Any remote parse/fetch/compatibility/policy
    /// failure falls back to the embedded root plus local details.
    pub fn select_root_for_context(
        &self,
        embedded: ConfigCandidate,
        embedded_details: &dyn FragmentSource,
        remote: Option<(ConfigCandidate, &dyn FragmentSource)>,
        context: &DetectionContext,
    ) -> Result<ResolvedSelection> {
        if embedded.origin != ConfigOrigin::Embedded {
            return Err(Error::InvalidConfig(
                "fallback candidate must have embedded origin".into(),
            ));
        }
        let embedded_root = self.loader.parse_root(&embedded.bytes)?;
        let embedded_config =
            self.loader
                .load_for_context(&embedded.bytes, embedded_details, context)?;
        let embedded_resolution = embedded_config.detect_and_resolve(&self.loader, context)?;

        if let Some((remote, remote_details)) = remote {
            if remote.origin != ConfigOrigin::Remote {
                return Err(Error::InvalidConfig(
                    "optional candidate must have remote origin".into(),
                ));
            }
            if let Ok(remote_root) = self.loader.parse_root(&remote.bytes) {
                let newer = compare_config_versions(
                    &remote_root.config_version,
                    &embedded_root.config_version,
                )
                .is_ok_and(|ordering| ordering.is_gt());
                if newer {
                    if let Ok(remote_config) =
                        self.loader
                            .load_for_context(&remote.bytes, remote_details, context)
                    {
                        if let Ok(remote_resolution) =
                            remote_config.detect_and_resolve(&self.loader, context)
                        {
                            return Ok(ResolvedSelection {
                                selected: SelectedConfig {
                                    origin: ConfigOrigin::Remote,
                                    config: remote_config,
                                },
                                resolution: remote_resolution,
                            });
                        }
                    }
                }
            }
        }
        Ok(ResolvedSelection {
            selected: SelectedConfig {
                origin: ConfigOrigin::Embedded,
                config: embedded_config,
            },
            resolution: embedded_resolution,
        })
    }
}

fn compare_config_versions(left: &str, right: &str) -> Result<std::cmp::Ordering> {
    Ok(parse_config_version(left)?.cmp(&parse_config_version(right)?))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn numeric_versions_do_not_sort_lexically() {
        assert!(compare_config_versions("1.10.0", "1.9.0").unwrap().is_gt());
        assert!(compare_config_versions("2.0.0", "1.99.0").unwrap().is_gt());
        assert!(compare_config_versions("tomorrow", "1.0.0").is_err());
    }
}
