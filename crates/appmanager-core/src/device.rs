//! Resolve one device configuration into APP Manager's validated domain view.
//!
//! This is the shared service boundary used by both the optional diagnostic
//! CLI and the embedded LOVE-lite process. Argument parsing belongs outside.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use portkit_core::{
    CandidateSelector, Config, ConfigCandidate, ConfigLoader, ConfigOrigin, DetectionContext,
    LocalFragmentSource, Resolution,
};
use thiserror::Error;

use crate::{AppOwnedPaths, ResolvedContextInput, ResolvedDeviceContext};

#[derive(Clone, Debug)]
pub struct DeviceConfigSources {
    pub embedded_root: Vec<u8>,
    pub embedded_dir: PathBuf,
    pub remote_root: Option<PathBuf>,
    pub remote_dir: Option<PathBuf>,
}

#[derive(Clone, Debug)]
pub struct DeviceResolutionRequest {
    pub launcher: PathBuf,
    pub app_state: PathBuf,
    pub trash: PathBuf,
    pub target_override: Option<PathBuf>,
    pub probe_root: Option<PathBuf>,
    pub environment: BTreeMap<String, String>,
    pub config: DeviceConfigSources,
}

#[derive(Clone, Debug)]
pub struct DeviceResolution {
    pub config_origin: ConfigOrigin,
    pub model_id: Option<String>,
    pub config: Config,
    pub resolution: Resolution,
    pub context: ResolvedDeviceContext,
}

#[derive(Debug, Error)]
pub enum DeviceResolutionError {
    #[error("device configuration failed: {0}")]
    Config(#[from] portkit_core::Error),
    #[error("device context is invalid: {0}")]
    Context(String),
    #[error("device probe failed: {0}")]
    Probe(#[from] std::io::Error),
    #[error("/etc/os-release is not valid UTF-8: {0}")]
    OsRelease(#[from] std::str::Utf8Error),
}

pub fn resolve_device(
    request: DeviceResolutionRequest,
) -> Result<DeviceResolution, DeviceResolutionError> {
    let mut detection = DetectionContext::current(request.launcher);
    detection.root = request.probe_root;
    detection.target_override = request.target_override;
    detection.environment.extend(request.environment);
    if let Some(root) = &detection.root {
        let os_release = root.join("etc/os-release");
        if os_release.is_file() {
            detection.os_release = parse_os_release(&fs::read(os_release)?)?;
        }
    }

    let embedded_details = LocalFragmentSource::new(request.config.embedded_dir);
    let remote_details = request
        .config
        .remote_root
        .as_ref()
        .map(|path| {
            request
                .config
                .remote_dir
                .clone()
                .unwrap_or_else(|| path.parent().unwrap_or(Path::new(".")).to_path_buf())
        })
        .map(LocalFragmentSource::new);
    // The downloaded root is an optional cache. A removable-media race or a
    // partial deletion must fall back to the packaged contract.
    let remote = request
        .config
        .remote_root
        .as_ref()
        .and_then(|path| fs::read(path).ok())
        .map(ConfigCandidate::remote)
        .zip(
            remote_details
                .as_ref()
                .map(|source| source as &dyn portkit_core::FragmentSource),
        );
    let selected = CandidateSelector {
        loader: ConfigLoader::default(),
    }
    .select_root_for_context(
        ConfigCandidate::embedded(request.config.embedded_root),
        &embedded_details,
        remote,
        &detection,
    )?;
    let config_origin = selected.selected.origin;
    let config = selected.selected.config;
    let resolution = selected.resolution;
    let model_id = resolution.model_id.clone();
    let context = ResolvedDeviceContext::try_from(ResolvedContextInput {
        resolution: resolution.clone(),
        app_owned: AppOwnedPaths {
            state: request.app_state,
            trash: request.trash,
        },
    })
    .map_err(|error| DeviceResolutionError::Context(error.to_string()))?;
    Ok(DeviceResolution {
        config_origin,
        model_id,
        config,
        resolution,
        context,
    })
}

fn parse_os_release(bytes: &[u8]) -> Result<BTreeMap<String, String>, DeviceResolutionError> {
    Ok(std::str::from_utf8(bytes)?
        .lines()
        .filter_map(|line| {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                return None;
            }
            let (name, value) = line.split_once('=')?;
            Some((name.to_owned(), value.trim_matches(['\'', '"']).to_owned()))
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn os_release_parser_accepts_standard_quotes_and_ignores_comments() {
        let parsed = parse_os_release(b"# comment\nOS_NAME='ROCKNIX'\nVERSION=2026.07\n").unwrap();
        assert_eq!(parsed["OS_NAME"], "ROCKNIX");
        assert_eq!(parsed["VERSION"], "2026.07");
    }
}
