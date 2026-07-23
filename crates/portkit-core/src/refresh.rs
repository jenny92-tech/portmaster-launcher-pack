//! Typed device-configuration refresh service.
//!
//! The optional CLI and embedded APP process both call this layer. Status-file
//! rendering is deliberately left to adapters instead of being part of the
//! download and validation transaction.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde::Serialize;

use crate::config::parse_config_version;
use crate::github::{Capability, GitHubTransport};
use crate::{
    ConfigLoader, DetectionContext, Error, ExclusiveFileLock, LocalFragmentSource, Result,
};

#[derive(Clone, Debug)]
pub struct ConfigRefreshRequest {
    pub source: String,
    pub packaged_root: PathBuf,
    pub packaged_dir: PathBuf,
    pub cached_root: PathBuf,
    pub cache_dir: PathBuf,
    pub timeout: Duration,
    pub detection: DetectionContext,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ConfigRefreshStatus {
    Updated,
    Unchanged,
}

impl ConfigRefreshStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Updated => "updated",
            Self::Unchanged => "unchanged",
        }
    }
}

pub fn refresh_config(request: &ConfigRefreshRequest) -> Result<ConfigRefreshStatus> {
    if request.timeout < Duration::from_secs(1) || request.timeout > Duration::from_secs(44) {
        return Err(Error::InvalidConfig(
            "config refresh timeout must be from 1 through 44 seconds".into(),
        ));
    }
    reject_directory_symlink(&request.cache_dir)?;
    reject_directory_symlink(&request.cache_dir.join("platforms"))?;
    let cache_parent = request
        .cache_dir
        .parent()
        .ok_or_else(|| Error::InvalidConfig("cache directory has no parent".into()))?;
    fs::create_dir_all(cache_parent)?;
    let _refresh_lock =
        ExclusiveFileLock::try_acquire(&cache_parent.join(".device-config-refresh.lock"))?;
    let stage = unique_stage_directory(cache_parent)?;
    let _stage = TemporaryDirectory(stage.clone());
    fs::create_dir(stage.join("platforms"))?;
    let staged_root = stage.join("config.json");
    let deadline = Instant::now()
        .checked_add(request.timeout)
        .ok_or_else(|| Error::InvalidConfig("invalid device config refresh deadline".into()))?;
    let transport = GitHubTransport::new();
    transport
        .fetch_with_timeout(
            Capability::Raw,
            &request.source,
            &staged_root,
            |path| {
                fs::read(path).is_ok_and(|bytes| ConfigLoader::default().parse_root(&bytes).is_ok())
            },
            None,
            Some(4 * 1024 * 1024),
            remaining(deadline)?,
        )
        .map_err(|error| Error::InvalidConfig(error.to_string()))?;

    let loader = ConfigLoader::default();
    let root = loader.parse_root(&fs::read(&staged_root)?)?;
    let platform = loader.detect_root(&root, &request.detection)?;
    let entry = root
        .platforms
        .get(&platform)
        .ok_or_else(|| Error::Resolution("selected platform detail is missing".into()))?;
    let expected_ref = format!("./platforms/{platform}.json");
    if entry.detail != expected_ref {
        return Err(Error::InvalidConfig(
            "selected platform detail ref is not canonical".into(),
        ));
    }
    let source_base = request
        .source
        .rsplit_once('/')
        .map(|(base, _)| base)
        .ok_or_else(|| Error::InvalidConfig("config source has no filename".into()))?;
    let detail_source = format!("{source_base}/{}", entry.detail.trim_start_matches("./"));
    let staged_detail = stage.join("platforms").join(format!("{platform}.json"));
    transport
        .fetch_with_timeout(
            Capability::Raw,
            &detail_source,
            &staged_detail,
            |path| fs::read(path).is_ok(),
            None,
            Some(4 * 1024 * 1024),
            remaining(deadline)?,
        )
        .map_err(|error| Error::InvalidConfig(error.to_string()))?;
    let candidate = loader.load_platform(root, &platform, &LocalFragmentSource::new(&stage))?;
    loader.validate_resolved_closure(&candidate, &platform)?;

    let packaged_version = validated_version(
        &loader,
        &request.packaged_root,
        &request.packaged_dir,
        &request.detection,
    )?;
    let mut baseline = packaged_version;
    if request.cached_root.is_file() {
        if let Ok(version) = validated_version(
            &loader,
            &request.cached_root,
            &request.cache_dir,
            &request.detection,
        ) {
            if compare_versions(&version, &baseline)?.is_gt() {
                baseline = version;
            }
        }
    }
    if !compare_versions(&candidate.config_version, &baseline)?.is_gt() {
        return Ok(ConfigRefreshStatus::Unchanged);
    }
    remaining(deadline)?;
    fs::create_dir_all(request.cache_dir.join("platforms"))?;
    fs::rename(
        &staged_detail,
        request
            .cache_dir
            .join("platforms")
            .join(format!("{platform}.json")),
    )?;
    fs::rename(&staged_root, &request.cached_root)?;
    Ok(ConfigRefreshStatus::Updated)
}

fn validated_version(
    loader: &ConfigLoader,
    root_path: &Path,
    detail_dir: &Path,
    context: &DetectionContext,
) -> Result<String> {
    let root = loader.parse_root(&fs::read(root_path)?)?;
    let platform = loader.detect_root(&root, context)?;
    let config = loader.load_platform(root, &platform, &LocalFragmentSource::new(detail_dir))?;
    loader.validate_resolved_closure(&config, &platform)?;
    Ok(config.config_version)
}

fn compare_versions(left: &str, right: &str) -> Result<std::cmp::Ordering> {
    Ok(parse_config_version(left)?.cmp(&parse_config_version(right)?))
}

fn remaining(deadline: Instant) -> Result<Duration> {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|remaining| !remaining.is_zero())
        .ok_or_else(|| {
            Error::InvalidConfig("device config refresh exceeded its startup deadline".into())
        })
}

fn reject_directory_symlink(path: &Path) -> Result<()> {
    match path.symlink_metadata() {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(Error::InvalidConfig(format!(
            "config cache path is a symlink: {}",
            path.display()
        ))),
        Ok(_) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

fn unique_stage_directory(parent: &Path) -> Result<PathBuf> {
    for counter in 0_u16..1000 {
        let path = parent.join(format!(
            ".device-config-stage-{}-{counter}",
            std::process::id()
        ));
        match fs::create_dir(&path) {
            Ok(()) => return Ok(path),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error.into()),
        }
    }
    Err(Error::InvalidConfig(
        "unable to allocate config staging directory".into(),
    ))
}

struct TemporaryDirectory(PathBuf);

impl Drop for TemporaryDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_order_is_numeric_and_timeout_is_bounded() {
        assert!(compare_versions("1.10.0", "1.9.0").unwrap().is_gt());
        assert!(compare_versions("1.0", "1.0.0").is_err());
    }
}
