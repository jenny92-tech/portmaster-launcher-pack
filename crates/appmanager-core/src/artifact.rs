//! Downloaded metadata and release artifacts owned by APP Manager.
//!
//! GitHub routing and byte transport remain in `portkit-core`; this module
//! adds the APP-specific manifest contracts and persistent cache policy.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use portkit_core::github::{Capability, GitHubTransport};
use portkit_core::{ExclusiveFileLock, atomic_write};
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::RuntimeMetadata;

const CACHE_MAX_AGE: Duration = Duration::from_secs(24 * 60 * 60);
// Small JSON manifests; a stalled connection must not hold the operation lock.
const MANIFEST_FETCH_TIMEOUT: Duration = Duration::from_secs(120);
const METADATA_FETCH_TIMEOUT: Duration = Duration::from_secs(300);

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct StableRelease {
    pub version: String,
    pub url: String,
    pub md5: String,
}

#[derive(Clone, Debug)]
pub struct StableReleaseRequest {
    pub manifest_url: String,
    pub archive_name: String,
    pub output: PathBuf,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StableReleaseOutcome {
    pub release: StableRelease,
    pub route: String,
    pub output: PathBuf,
}

#[derive(Clone, Debug)]
pub struct StableCacheRequest {
    pub manifest_url: String,
    pub cache: PathBuf,
    pub force: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CacheRefreshStatus {
    Cached,
    CachedStale,
    Updated,
}

impl CacheRefreshStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Cached => "cached",
            Self::CachedStale => "cached-stale",
            Self::Updated => "updated",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StableCacheOutcome {
    pub status: CacheRefreshStatus,
    pub latest: Option<String>,
    pub route: Option<String>,
}

#[derive(Clone, Debug)]
pub struct RuntimeMetadataRequest {
    pub source: String,
    pub json_cache: PathBuf,
    pub tsv_cache: Option<PathBuf>,
    pub force: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeMetadataOutcome {
    pub status: CacheRefreshStatus,
    pub route: Option<String>,
}

#[derive(Debug, Error)]
pub enum ArtifactError {
    #[error("invalid stable release metadata: {0}")]
    InvalidStable(String),
    #[error("artifact path is invalid: {0}")]
    InvalidPath(String),
    #[error("artifact cache is busy: {0}")]
    Busy(#[source] std::io::Error),
    #[error("artifact I/O failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("artifact download failed: {0}")]
    Download(#[from] portkit_core::github::GitHubError),
    #[error("Runtime metadata is invalid: {0}")]
    Runtime(String),
}

#[derive(Debug, Deserialize)]
struct StableManifest {
    stable: StableRelease,
}

pub fn parse_stable_manifest(bytes: &[u8]) -> Result<StableRelease, ArtifactError> {
    let manifest: StableManifest = serde_json::from_slice(bytes)
        .map_err(|error| ArtifactError::InvalidStable(error.to_string()))?;
    let mut stable = manifest.stable;
    for (field, value) in [
        ("version", stable.version.as_str()),
        ("url", stable.url.as_str()),
        ("md5", stable.md5.as_str()),
    ] {
        if value.is_empty()
            || value
                .bytes()
                .any(|byte| matches!(byte, b'\t' | b'\r' | b'\n'))
        {
            return Err(ArtifactError::InvalidStable(format!(
                "stable {field} is empty or contains a control separator"
            )));
        }
    }
    if !stable
        .version
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        return Err(ArtifactError::InvalidStable(
            "stable version contains unsupported characters".into(),
        ));
    }
    if stable.md5.len() != 32 || !stable.md5.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(ArtifactError::InvalidStable(
            "stable md5 is not a 32-character hexadecimal digest".into(),
        ));
    }
    let Some(release_path) = stable.url.strip_prefix("https://github.com/") else {
        return Err(ArtifactError::InvalidStable(
            "stable URL is not a GitHub HTTPS release asset".into(),
        ));
    };
    let segments = release_path.split('/').collect::<Vec<_>>();
    if segments.len() != 6
        || segments[0].is_empty()
        || segments[1].is_empty()
        || segments[2] != "releases"
        || segments[3] != "download"
        || segments[4].is_empty()
        || segments[5].is_empty()
    {
        return Err(ArtifactError::InvalidStable(
            "stable URL is not a GitHub release asset".into(),
        ));
    }
    stable.md5.make_ascii_lowercase();
    Ok(stable)
}

pub fn validate_stable_release_route(
    source: &str,
    archive_name: &str,
    stable: &StableRelease,
) -> Result<(), ArtifactError> {
    if archive_name.is_empty()
        || matches!(archive_name, "." | "..")
        || archive_name.contains(['/', '\\', '\t', '\r', '\n'])
    {
        return Err(ArtifactError::InvalidStable(
            "stable archive name is unsafe".into(),
        ));
    }
    let repository = source
        .strip_suffix("/releases/latest/download/version.json")
        .filter(|base| base.starts_with("https://github.com/"))
        .ok_or_else(|| {
            ArtifactError::InvalidStable(
                "stable manifest URL is not a GitHub latest-release asset".into(),
            )
        })?;
    let expected = format!(
        "{repository}/releases/download/{}/{}",
        stable.version, archive_name
    );
    if stable.url != expected {
        return Err(ArtifactError::InvalidStable(
            "stable archive does not match its manifest repository, version, or name".into(),
        ));
    }
    Ok(())
}

pub fn fetch_stable_release(
    request: &StableReleaseRequest,
) -> Result<StableReleaseOutcome, ArtifactError> {
    let parent = request
        .output
        .parent()
        .ok_or_else(|| ArtifactError::InvalidPath("release output has no parent".into()))?;
    fs::create_dir_all(parent)?;
    let manifest = parent.join(format!(
        ".stable-release-manifest-{}.json",
        std::process::id()
    ));
    let _download = DownloadGuard(manifest.clone());
    let outcome = GitHubTransport::new().fetch_with_timeout(
        Capability::Release,
        &request.manifest_url,
        &manifest,
        |path| {
            fs::read(path)
                .ok()
                .and_then(|bytes| parse_stable_manifest(&bytes).ok())
                .is_some()
        },
        None,
        None,
        MANIFEST_FETCH_TIMEOUT,
    )?;
    let stable = parse_stable_manifest(&fs::read(&manifest)?)?;
    validate_stable_release_route(&request.manifest_url, &request.archive_name, &stable)?;
    atomic_write(
        &request.output,
        format!("{}\t{}\t{}\n", stable.version, stable.url, stable.md5).as_bytes(),
    )?;
    Ok(StableReleaseOutcome {
        release: stable,
        route: outcome.route_id().to_owned(),
        output: request.output.clone(),
    })
}

pub fn refresh_stable_cache(
    request: &StableCacheRequest,
) -> Result<StableCacheOutcome, ArtifactError> {
    if !request.force && cache_is_fresh(&request.cache) && stable_cache_row_valid(&request.cache) {
        let (_, _, latest) = read_stable_cache(&request.cache).ok_or_else(|| {
            ArtifactError::InvalidStable("fresh stable cache is malformed".into())
        })?;
        return Ok(StableCacheOutcome {
            status: CacheRefreshStatus::Cached,
            latest: Some(latest),
            route: None,
        });
    }
    let parent = request
        .cache
        .parent()
        .ok_or_else(|| ArtifactError::InvalidPath("update cache has no parent".into()))?;
    fs::create_dir_all(parent)?;
    let manifest = parent.join(format!(".stable-manifest-{}.json", std::process::id()));
    let _download = DownloadGuard(manifest.clone());
    let fetch = GitHubTransport::new().fetch_with_timeout(
        Capability::Release,
        &request.manifest_url,
        &manifest,
        |path| {
            fs::read(path)
                .ok()
                .and_then(|bytes| parse_stable_manifest(&bytes).ok())
                .is_some()
        },
        None,
        None,
        MANIFEST_FETCH_TIMEOUT,
    );
    let checked = epoch_seconds();
    match fetch {
        Ok(outcome) => {
            let stable = parse_stable_manifest(&fs::read(&manifest)?)?;
            write_update_cache(&request.cache, checked, "ok", &stable.version)?;
            Ok(StableCacheOutcome {
                status: CacheRefreshStatus::Updated,
                latest: Some(stable.version),
                route: Some(outcome.route_id().to_owned()),
            })
        }
        Err(error) => {
            let _ = write_update_cache(&request.cache, checked, "error", "");
            Err(error.into())
        }
    }
}

pub fn refresh_runtime_metadata(
    request: &RuntimeMetadataRequest,
) -> Result<RuntimeMetadataOutcome, ArtifactError> {
    if !request.force
        && cache_is_fresh(&request.json_cache)
        && runtime_cache_valid(&request.json_cache, request.tsv_cache.as_deref())
    {
        return Ok(RuntimeMetadataOutcome {
            status: CacheRefreshStatus::Cached,
            route: None,
        });
    }
    let parent = request
        .json_cache
        .parent()
        .ok_or_else(|| ArtifactError::InvalidPath("Runtime cache has no parent".into()))?;
    fs::create_dir_all(parent)?;
    let _refresh_lock =
        ExclusiveFileLock::try_acquire(&parent.join(".runtime-metadata-refresh.lock"))
            .map_err(ArtifactError::Busy)?;
    if repair_runtime_cache(&request.json_cache, request.tsv_cache.as_deref())?
        && !request.force
        && cache_is_fresh(&request.json_cache)
    {
        return Ok(RuntimeMetadataOutcome {
            status: CacheRefreshStatus::Cached,
            route: None,
        });
    }
    let download = parent.join(format!(".runtime-metadata-{}.json", std::process::id()));
    let _download = DownloadGuard(download.clone());
    let fetched = GitHubTransport::new().fetch_with_timeout(
        Capability::Release,
        &request.source,
        &download,
        |path| {
            fs::read(path)
                .ok()
                .and_then(|bytes| RuntimeMetadata::parse(&bytes).ok())
                .is_some()
        },
        None,
        None,
        METADATA_FETCH_TIMEOUT,
    );
    let outcome = match fetched {
        Ok(outcome) => outcome,
        Err(_) if !request.force => {
            if repair_runtime_cache(&request.json_cache, request.tsv_cache.as_deref())? {
                return Ok(RuntimeMetadataOutcome {
                    status: CacheRefreshStatus::CachedStale,
                    route: None,
                });
            }
            return Err(ArtifactError::Runtime(
                "download failed and no valid cached Runtime metadata exists".into(),
            ));
        }
        Err(error) => return Err(error.into()),
    };
    let bytes = fs::read(&download)?;
    let metadata = RuntimeMetadata::parse(&bytes)
        .map_err(|error| ArtifactError::Runtime(error.to_string()))?;
    atomic_write(&request.json_cache, &bytes)?;
    if let Some(tsv_cache) = &request.tsv_cache {
        atomic_write(tsv_cache, metadata.to_tsv().as_bytes())?;
    }
    Ok(RuntimeMetadataOutcome {
        status: CacheRefreshStatus::Updated,
        route: Some(outcome.route_id().to_owned()),
    })
}

pub fn stable_cache_row_valid(path: &Path) -> bool {
    read_stable_cache(path).is_some_and(|(_, status, latest)| match status.as_str() {
        "ok" => {
            !latest.is_empty()
                && latest
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        }
        "error" => latest.is_empty(),
        _ => false,
    })
}

fn read_stable_cache(path: &Path) -> Option<(u64, String, String)> {
    let row = fs::read_to_string(path).ok()?;
    let row = row.strip_suffix('\n')?;
    if row.contains(['\n', '\r']) {
        return None;
    }
    let fields = row.split('\t').collect::<Vec<_>>();
    if fields.len() != 3 {
        return None;
    }
    Some((
        fields[0].parse().ok()?,
        fields[1].to_owned(),
        fields[2].to_owned(),
    ))
}

fn cache_is_fresh(path: &Path) -> bool {
    path.metadata()
        .ok()
        .and_then(|metadata| metadata.modified().ok())
        .and_then(|modified| modified.elapsed().ok())
        .is_some_and(|age| age < CACHE_MAX_AGE)
}

fn runtime_cache_valid(json_cache: &Path, tsv_cache: Option<&Path>) -> bool {
    fs::read(json_cache)
        .ok()
        .and_then(|json| RuntimeMetadata::parse(&json).ok())
        .is_some_and(|metadata| {
            tsv_cache.is_none_or(|path| {
                fs::read(path).is_ok_and(|tsv| tsv == metadata.to_tsv().as_bytes())
            })
        })
}

fn repair_runtime_cache(
    json_cache: &Path,
    tsv_cache: Option<&Path>,
) -> Result<bool, ArtifactError> {
    let Ok(json) = fs::read(json_cache) else {
        return Ok(false);
    };
    let Ok(metadata) = RuntimeMetadata::parse(&json) else {
        return Ok(false);
    };
    if let Some(tsv_cache) = tsv_cache {
        let canonical = metadata.to_tsv();
        if !fs::read(tsv_cache).is_ok_and(|tsv| tsv == canonical.as_bytes()) {
            atomic_write(tsv_cache, canonical.as_bytes())?;
        }
    }
    Ok(true)
}

fn write_update_cache(
    path: &Path,
    checked: u64,
    status: &str,
    latest: &str,
) -> Result<(), ArtifactError> {
    atomic_write(path, format!("{checked}\t{status}\t{latest}\n").as_bytes())?;
    Ok(())
}

fn epoch_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

struct DownloadGuard(PathBuf);

impl Drop for DownloadGuard {
    fn drop(&mut self) {
        for suffix in ["", ".part", ".part.route"] {
            let mut path = self.0.as_os_str().to_os_string();
            path.push(suffix);
            let _ = fs::remove_file(PathBuf::from(path));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stable_manifest_and_route_are_one_strict_contract() {
        let release = parse_stable_manifest(
            br#"{"stable":{"version":"2026.07","url":"https://github.com/example/repo/releases/download/2026.07/PortMaster.zip","md5":"0123456789abcdef0123456789ABCDEF"}}"#,
        )
        .unwrap();
        assert_eq!(release.md5, "0123456789abcdef0123456789abcdef");
        validate_stable_release_route(
            "https://github.com/example/repo/releases/latest/download/version.json",
            "PortMaster.zip",
            &release,
        )
        .unwrap();
        assert!(
            validate_stable_release_route(
                "https://github.com/other/repo/releases/latest/download/version.json",
                "PortMaster.zip",
                &release,
            )
            .is_err()
        );
    }

    #[test]
    fn stable_cache_accepts_only_canonical_rows() {
        let temp = tempfile::tempdir().unwrap();
        let cache = temp.path().join("update.tsv");
        write_update_cache(&cache, 123, "ok", "2026.07").unwrap();
        assert!(stable_cache_row_valid(&cache));
        fs::write(&cache, "123\tok\t2026.07\textra\n").unwrap();
        assert!(!stable_cache_row_valid(&cache));
    }
}
