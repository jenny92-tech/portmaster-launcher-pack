// INPUT:  EnvironmentPolicy、Platform、Predicate、serde、SHA-256 与配置片段
// OUTPUT: Config/RootConfig、ConfigLoader、FragmentSource 及契约验证接口
// POS:    两层设备配置的解析、完整性验证和选中平台闭包加载层
use crate::environment::EnvironmentPolicy;
use crate::platform::Platform;
use crate::predicate::Predicate;
use crate::{Error, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Component, Path, PathBuf};

pub const CONFIG_FORMAT: &str = "jenny92.appmanager-config";

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Config {
    pub format: String,
    pub schema_version: u32,
    pub config_version: String,
    pub metadata: Metadata,
    #[serde(default)]
    pub parser_limits: ParserLimits,
    #[serde(default)]
    pub bootstrap: serde_json::Value,
    #[serde(default)]
    pub sources: BTreeMap<String, serde_json::Value>,
    #[serde(alias = "environment_policy")]
    pub environment: EnvironmentPolicy,
    #[serde(default)]
    pub adapters: BTreeMap<String, Adapter>,
    pub platforms: BTreeMap<String, Platform>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, serde_json::Value>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Metadata {
    pub generated_at: String,
    pub source_revision: String,
    #[serde(flatten)]
    pub extra: BTreeMap<String, serde_json::Value>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ParserLimits {
    #[serde(default = "default_max_depth")]
    pub max_depth: usize,
    #[serde(default = "default_max_path_bytes")]
    pub max_path_bytes: usize,
    #[serde(default = "default_max_string_bytes")]
    pub max_string_bytes: usize,
    #[serde(default = "default_max_collection_items")]
    pub max_collection_items: usize,
    #[serde(flatten)]
    pub extra: BTreeMap<String, serde_json::Value>,
}

const fn default_max_depth() -> usize {
    32
}
const fn default_max_path_bytes() -> usize {
    4096
}
const fn default_max_string_bytes() -> usize {
    65536
}
const fn default_max_collection_items() -> usize {
    4096
}

impl Default for ParserLimits {
    fn default() -> Self {
        Self {
            max_depth: default_max_depth(),
            max_path_bytes: default_max_path_bytes(),
            max_string_bytes: default_max_string_bytes(),
            max_collection_items: default_max_collection_items(),
            extra: BTreeMap::new(),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Adapter {
    pub kind: String,
    pub contract_version: u32,
    #[serde(default, alias = "depends_on")]
    pub requires: Vec<String>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, serde_json::Value>,
}

#[derive(Clone, Debug)]
pub struct SupportedContract {
    pub minimum_schema: u32,
    pub maximum_schema: u32,
    /// Maximum supported contract version by adapter kind.
    pub adapters: BTreeMap<String, u32>,
}

impl Default for SupportedContract {
    fn default() -> Self {
        let adapters = ["predicate", "path", "frontend", "library", "python"]
            .into_iter()
            .map(|kind| (kind.to_owned(), 1))
            .collect();
        Self {
            minimum_schema: 1,
            maximum_schema: 1,
            adapters,
        }
    }
}

/// Root config.json: global blocks + thin platform entries used only for
/// detection, each pointing at its detail file via a `detail` ref.
#[derive(Clone, Debug, Deserialize)]
pub struct RootConfig {
    pub format: String,
    pub schema_version: u32,
    pub config_version: String,
    pub metadata: Metadata,
    #[serde(default)]
    pub parser_limits: ParserLimits,
    #[serde(default)]
    pub bootstrap: serde_json::Value,
    #[serde(default)]
    pub sources: BTreeMap<String, serde_json::Value>,
    #[serde(alias = "environment_policy")]
    pub environment: EnvironmentPolicy,
    #[serde(default)]
    pub adapters: BTreeMap<String, Adapter>,
    pub platforms: BTreeMap<String, PlatformEntry>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, serde_json::Value>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct PlatformEntry {
    pub priority: i32,
    pub recognition: Predicate,
    pub detail: DetailArtifact,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DetailArtifact {
    #[serde(rename = "ref")]
    pub ref_path: String,
    pub sha256: String,
    pub bytes: u64,
}

/// Resolves a config fragment reference (e.g. "./platforms/miniloong.json") to
/// its bytes. Remote and local sources share this surface; the ref is either an
/// absolute URL (used directly) or a path resolved against the source base.
pub trait FragmentSource {
    fn read(&self, ref_path: &str) -> Result<Vec<u8>>;
}

/// Reads fragments from a local directory (the package config dir, or a test
/// fixture). Relative refs are joined under `base_dir`.
pub struct LocalFragmentSource {
    base_dir: PathBuf,
}

impl LocalFragmentSource {
    pub fn new(base_dir: impl Into<PathBuf>) -> Self {
        Self {
            base_dir: base_dir.into(),
        }
    }
}

impl FragmentSource for LocalFragmentSource {
    fn read(&self, ref_path: &str) -> Result<Vec<u8>> {
        let relative = Path::new(ref_path.strip_prefix("./").unwrap_or(ref_path));
        if relative.as_os_str().is_empty()
            || relative.is_absolute()
            || relative.components().any(|component| {
                matches!(
                    component,
                    Component::ParentDir | Component::RootDir | Component::Prefix(_)
                )
            })
        {
            return Err(Error::InvalidConfig(format!(
                "only local relative refs are supported here: {ref_path:?}"
            )));
        }
        let base = self
            .base_dir
            .canonicalize()
            .map_err(|_| Error::InvalidConfig("local config directory is unavailable".into()))?;
        let path = base
            .join(relative)
            .canonicalize()
            .map_err(|_| Error::InvalidConfig(format!("config fragment not found: {ref_path}")))?;
        if !path.starts_with(&base) {
            return Err(Error::InvalidConfig(format!(
                "config fragment escapes its base directory: {ref_path:?}"
            )));
        }
        fs::read(path).map_err(Error::from)
    }
}

#[derive(Clone, Debug, Default)]
pub struct ConfigLoader {
    pub supported: SupportedContract,
}

impl ConfigLoader {
    pub fn validate(&self, config: &Config) -> Result<()> {
        if !config.extra.is_empty()
            || !config.metadata.extra.is_empty()
            || !config.parser_limits.extra.is_empty()
        {
            return Err(Error::InvalidConfig(
                "Config v1 contains unknown top-level or metadata fields".into(),
            ));
        }
        if config.format != CONFIG_FORMAT {
            return Err(Error::InvalidConfig(format!(
                "format must be {CONFIG_FORMAT:?}"
            )));
        }
        parse_config_version(&config.config_version)?;
        if !(self.supported.minimum_schema..=self.supported.maximum_schema)
            .contains(&config.schema_version)
        {
            return Err(Error::Incompatible(format!(
                "schema {} is outside supported range {}..={}",
                config.schema_version, self.supported.minimum_schema, self.supported.maximum_schema
            )));
        }
        config.environment.validate()?;
        validate_limits(&config.parser_limits)?;
        validate_bootstrap(&config.bootstrap)?;
        validate_sources(&config.sources)?;
        if config.platforms.is_empty() {
            return Err(Error::InvalidConfig("platforms cannot be empty".into()));
        }
        for id in config.platforms.keys() {
            validate_identifier("platform", id)?;
        }
        for platform in config.platforms.values() {
            platform.validate(&config.parser_limits)?;
            for model in &platform.models {
                if model.extra.contains_key("inherits") {
                    return Err(Error::InvalidConfig(format!(
                        "model {:?} must not declare inherits; its parent platform is implicit",
                        model.id
                    )));
                }
            }
        }
        Ok(())
    }

    /// Parses the two-tier root config.json (global blocks + thin platform
    /// entries) without loading any detail. Detection runs off the thin entries.
    pub fn parse_root(&self, bytes: &[u8]) -> Result<RootConfig> {
        let raw: serde_json::Value = serde_json::from_slice(bytes)?;
        let limits: ParserLimits = raw
            .get("parser_limits")
            .cloned()
            .map(serde_json::from_value)
            .transpose()?
            .unwrap_or_default();
        validate_limits(&limits)?;
        validate_json_limits(&raw, &limits, 1)?;
        let root: RootConfig = serde_json::from_value(raw)?;
        self.validate_root(&root)?;
        Ok(root)
    }

    pub fn validate_root(&self, root: &RootConfig) -> Result<()> {
        if !root.extra.is_empty()
            || !root.metadata.extra.is_empty()
            || !root.parser_limits.extra.is_empty()
        {
            return Err(Error::InvalidConfig(
                "Config v1 root contains unknown top-level or metadata fields".into(),
            ));
        }
        if root.format != CONFIG_FORMAT {
            return Err(Error::InvalidConfig(format!(
                "format must be {CONFIG_FORMAT:?}"
            )));
        }
        parse_config_version(&root.config_version)?;
        if !(self.supported.minimum_schema..=self.supported.maximum_schema)
            .contains(&root.schema_version)
        {
            return Err(Error::Incompatible(format!(
                "schema {} is outside supported range {}..={}",
                root.schema_version, self.supported.minimum_schema, self.supported.maximum_schema
            )));
        }
        if root.platforms.is_empty() {
            return Err(Error::InvalidConfig("platforms cannot be empty".into()));
        }
        validate_bootstrap(&root.bootstrap)?;
        validate_sources(&root.sources)?;
        for (id, entry) in &root.platforms {
            validate_identifier("platform", id)?;
            entry
                .recognition
                .validate(1, root.parser_limits.max_depth)?;
            if entry.detail.ref_path.trim().is_empty()
                || entry.detail.ref_path.contains(char::is_whitespace)
            {
                return Err(Error::InvalidConfig(format!(
                    "platform {id:?} has an invalid detail ref"
                )));
            }
            if entry.detail.ref_path.len() > root.parser_limits.max_path_bytes {
                return Err(Error::InvalidConfig(format!(
                    "platform {id:?} detail ref exceeds max_path_bytes"
                )));
            }
            if entry.detail.bytes == 0 {
                return Err(Error::InvalidConfig(format!(
                    "platform {id:?} detail byte length must be positive"
                )));
            }
            if entry.detail.sha256.len() != 64
                || !entry
                    .detail
                    .sha256
                    .bytes()
                    .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
            {
                return Err(Error::InvalidConfig(format!(
                    "platform {id:?} detail sha256 must be 64 lowercase hexadecimal characters"
                )));
            }
        }
        root.environment.validate()?;
        Ok(())
    }

    /// Detects a platform using only the thin root entries.
    pub fn detect_root(
        &self,
        root: &RootConfig,
        context: &crate::DetectionContext,
    ) -> Result<String> {
        let mut matches = Vec::new();
        for (id, entry) in &root.platforms {
            if entry.recognition.evaluate(context)? {
                matches.push((id, entry));
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
        matches
            .first()
            .map(|(id, _)| (*id).clone())
            .ok_or_else(|| Error::Resolution("no platform recognition predicate matched".into()))
    }

    /// Parses one selected detail and binds it to the root by
    /// format/schema/config-version/platform identity.
    pub fn load_platform(
        &self,
        root: RootConfig,
        platform_id: &str,
        details: &dyn FragmentSource,
    ) -> Result<Config> {
        let entry = root
            .platforms
            .get(platform_id)
            .ok_or_else(|| Error::Resolution(format!("unknown platform {platform_id:?}")))?;
        let bytes = details.read(&entry.detail.ref_path)?;
        if bytes.len() as u64 != entry.detail.bytes {
            return Err(Error::InvalidConfig(format!(
                "platform {platform_id:?} detail byte length does not match root"
            )));
        }
        let actual_digest = format!("{:x}", Sha256::digest(&bytes));
        if actual_digest != entry.detail.sha256 {
            return Err(Error::InvalidConfig(format!(
                "platform {platform_id:?} detail sha256 does not match root"
            )));
        }
        let mut raw: serde_json::Value = serde_json::from_slice(&bytes).map_err(|error| {
            Error::InvalidConfig(format!(
                "platform {platform_id:?} detail is invalid: {error}"
            ))
        })?;
        validate_json_limits(&raw, &root.parser_limits, 1)?;
        let object = raw.as_object_mut().ok_or_else(|| {
            Error::InvalidConfig(format!("platform {platform_id:?} detail must be an object"))
        })?;
        require_detail_identity(object, "format", &root.format, platform_id)?;
        require_detail_identity(object, "config_version", &root.config_version, platform_id)?;
        let detail_schema = object
            .remove("schema_version")
            .and_then(|value| value.as_u64())
            .ok_or_else(|| detail_identity_error(platform_id, "schema_version"))?;
        if detail_schema != u64::from(root.schema_version) {
            return Err(detail_identity_error(platform_id, "schema_version"));
        }
        require_detail_identity(object, "platform_id", platform_id, platform_id)?;
        if object.contains_key("priority") || object.contains_key("recognition") {
            return Err(Error::InvalidConfig(format!(
                "platform {platform_id:?} detail duplicates root detection fields"
            )));
        }
        object.insert("priority".into(), entry.priority.into());
        object.insert(
            "recognition".into(),
            serde_json::to_value(&entry.recognition)?,
        );
        let platform: Platform = serde_json::from_value(raw).map_err(|error| {
            Error::InvalidConfig(format!(
                "platform {platform_id:?} detail is invalid: {error}"
            ))
        })?;
        let platforms = [(platform_id.to_owned(), platform)].into_iter().collect();
        let config = Config {
            format: root.format,
            schema_version: root.schema_version,
            config_version: root.config_version,
            metadata: root.metadata,
            parser_limits: root.parser_limits,
            bootstrap: root.bootstrap,
            sources: root.sources,
            environment: root.environment,
            adapters: root.adapters,
            platforms,
            extra: root.extra,
        };
        self.validate(&config)?;
        Ok(config)
    }

    /// Detects from the root and loads only the selected platform detail.
    pub fn load_for_context(
        &self,
        root_bytes: &[u8],
        details: &dyn FragmentSource,
        context: &crate::DetectionContext,
    ) -> Result<Config> {
        let root = self.parse_root(root_bytes)?;
        let platform_id = self.detect_root(&root, context)?;
        self.load_platform(root, &platform_id, details)
    }

    /// Strictly validates only adapters reachable from the selected device.
    /// This permits a newer config to carry adapters unused on this engine.
    pub fn validate_resolved_closure(
        &self,
        config: &Config,
        platform_id: &str,
    ) -> Result<Vec<String>> {
        let platform = config
            .platforms
            .get(platform_id)
            .ok_or_else(|| Error::Resolution(format!("unknown platform {platform_id:?}")))?;
        platform.validate(&config.parser_limits)?;
        for scope in &platform.environment_scopes {
            if !config.environment.scopes.contains_key(scope) {
                return Err(Error::InvalidConfig(format!(
                    "platform {platform_id:?} references unknown environment scope {scope:?}"
                )));
            }
        }
        let route_exists = config
            .sources
            .get("release_routes")
            .and_then(serde_json::Value::as_object)
            .is_some_and(|routes| routes.contains_key(&platform.source_route));
        if !route_exists {
            return Err(Error::InvalidConfig(format!(
                "platform {platform_id:?} references unknown source route {:?}",
                platform.source_route
            )));
        }
        let mut visiting = BTreeSet::new();
        let mut visited = BTreeSet::new();
        let mut ordered = Vec::new();
        for adapter in &platform.required_adapters {
            self.visit_adapter(
                config,
                adapter,
                1,
                &mut visiting,
                &mut visited,
                &mut ordered,
            )?;
        }
        Ok(ordered)
    }

    fn visit_adapter(
        &self,
        config: &Config,
        id: &str,
        depth: usize,
        visiting: &mut BTreeSet<String>,
        visited: &mut BTreeSet<String>,
        ordered: &mut Vec<String>,
    ) -> Result<()> {
        if depth > config.parser_limits.max_depth {
            return Err(Error::InvalidConfig(format!(
                "adapter dependency depth exceeds {}",
                config.parser_limits.max_depth
            )));
        }
        if visited.contains(id) {
            return Ok(());
        }
        if !visiting.insert(id.into()) {
            return Err(Error::InvalidConfig(format!(
                "adapter dependency cycle at {id:?}"
            )));
        }
        let adapter = config.adapters.get(id).ok_or_else(|| {
            Error::InvalidConfig(format!("required adapter {id:?} is not defined"))
        })?;
        let maximum = self.supported.adapters.get(&adapter.kind).ok_or_else(|| {
            Error::Incompatible(format!(
                "adapter {id:?} uses unsupported kind {:?}",
                adapter.kind
            ))
        })?;
        if adapter.contract_version == 0 || adapter.contract_version > *maximum {
            return Err(Error::Incompatible(format!(
                "adapter {id:?} contract {} exceeds supported {}",
                adapter.contract_version, maximum
            )));
        }
        for dependency in &adapter.requires {
            self.visit_adapter(config, dependency, depth + 1, visiting, visited, ordered)?;
        }
        visiting.remove(id);
        visited.insert(id.into());
        ordered.push(id.into());
        Ok(())
    }
}

fn validate_bootstrap(value: &serde_json::Value) -> Result<()> {
    let object = value
        .as_object()
        .ok_or_else(|| Error::InvalidConfig("bootstrap must be an object".to_owned()))?;
    require_exact_object_keys(
        object,
        &[
            "policy",
            "config_url",
            "fallback",
            "transport",
            "required_format",
        ],
        "bootstrap",
    )?;
    let string = |name: &str| {
        object
            .get(name)
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| Error::InvalidConfig(format!("bootstrap.{name} must be a string")))
    };
    if string("policy")? != "remote_then_embedded"
        || string("fallback")? != "embedded_root_then_local_dir"
        || string("transport")? != "github_https"
        || string("required_format")? != CONFIG_FORMAT
    {
        return Err(Error::InvalidConfig(
            "bootstrap policy is unsupported by this engine".to_owned(),
        ));
    }
    let url = string("config_url")?;
    if !url.starts_with("https://raw.githubusercontent.com/") || url.contains(char::is_whitespace) {
        return Err(Error::InvalidConfig(
            "bootstrap.config_url must be a GitHub raw HTTPS URL".to_owned(),
        ));
    }
    Ok(())
}

fn validate_sources(sources: &BTreeMap<String, serde_json::Value>) -> Result<()> {
    let expected_source_keys = ["endpoints", "release_routes", "runtime", "transport"]
        .into_iter()
        .collect::<BTreeSet<_>>();
    if sources.keys().map(String::as_str).collect::<BTreeSet<_>>() != expected_source_keys {
        return Err(Error::InvalidConfig(
            "sources must contain exactly endpoints, release_routes, runtime and transport".into(),
        ));
    }
    let object = |name: &str| {
        sources
            .get(name)
            .and_then(serde_json::Value::as_object)
            .ok_or_else(|| Error::InvalidConfig(format!("sources.{name} must be an object")))
    };
    let endpoints = object("endpoints")?;
    if endpoints.is_empty() {
        return Err(Error::InvalidConfig(
            "sources.endpoints cannot be empty".to_owned(),
        ));
    }
    for (id, value) in endpoints {
        validate_identifier("source endpoint", id)?;
        let url = value.as_str().ok_or_else(|| {
            Error::InvalidConfig(format!("source endpoint {id:?} must be a string"))
        })?;
        if !url.starts_with("https://github.com/") || url.contains(char::is_whitespace) {
            return Err(Error::InvalidConfig(format!(
                "source endpoint {id:?} must be a GitHub HTTPS URL"
            )));
        }
    }

    let routes = object("release_routes")?;
    if routes.is_empty() {
        return Err(Error::InvalidConfig(
            "sources.release_routes cannot be empty".to_owned(),
        ));
    }
    for (id, value) in routes {
        validate_identifier("release route", id)?;
        let route = value.as_object().ok_or_else(|| {
            Error::InvalidConfig(format!("release route {id:?} must be an object"))
        })?;
        let mut route_keys = vec!["manifest", "channel", "archive_name", "checksum"];
        if route.contains_key("install_allowed") {
            route_keys.push("install_allowed");
        }
        require_exact_object_keys(route, &route_keys, &format!("release route {id:?}"))?;
        let manifest = route
            .get("manifest")
            .and_then(serde_json::Value::as_str)
            .filter(|manifest| endpoints.contains_key(*manifest))
            .ok_or_else(|| {
                Error::InvalidConfig(format!(
                    "release route {id:?} references an unknown manifest endpoint"
                ))
            })?;
        let _ = manifest;
        if route.get("channel").and_then(serde_json::Value::as_str) != Some("stable")
            || route.get("checksum").and_then(serde_json::Value::as_str)
                != Some("md5_from_manifest")
        {
            return Err(Error::InvalidConfig(format!(
                "release route {id:?} has an unsupported channel or checksum contract"
            )));
        }
        let archive = route
            .get("archive_name")
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| {
                Error::InvalidConfig(format!("release route {id:?} has no archive_name"))
            })?;
        if archive.is_empty()
            || archive.contains(['/', '\\', '\t', '\r', '\n'])
            || matches!(archive, "." | "..")
        {
            return Err(Error::InvalidConfig(format!(
                "release route {id:?} has an unsafe archive_name"
            )));
        }
        if route
            .get("install_allowed")
            .is_some_and(|value| !value.is_boolean())
        {
            return Err(Error::InvalidConfig(format!(
                "release route {id:?} install_allowed must be boolean"
            )));
        }
    }

    let runtime = object("runtime")?;
    require_exact_object_keys(
        runtime,
        &["metadata", "architectures", "verification"],
        "sources.runtime",
    )?;
    let metadata = runtime
        .get("metadata")
        .and_then(serde_json::Value::as_str)
        .filter(|metadata| endpoints.contains_key(*metadata))
        .ok_or_else(|| {
            Error::InvalidConfig(
                "sources.runtime.metadata references an unknown endpoint".to_owned(),
            )
        })?;
    let _ = metadata;
    let architectures = runtime
        .get("architectures")
        .and_then(serde_json::Value::as_array)
        .filter(|architectures| !architectures.is_empty())
        .ok_or_else(|| {
            Error::InvalidConfig("sources.runtime.architectures must be a non-empty array".into())
        })?;
    let mut architecture_ids = BTreeSet::new();
    let mut system_names = BTreeSet::new();
    for architecture in architectures {
        let architecture = architecture.as_object().ok_or_else(|| {
            Error::InvalidConfig("Runtime architecture entries must be objects".into())
        })?;
        require_exact_object_keys(
            architecture,
            &["id", "system_names"],
            "Runtime architecture",
        )?;
        let id = architecture
            .get("id")
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| Error::InvalidConfig("Runtime architecture has no id".into()))?;
        validate_identifier("Runtime architecture", id)?;
        if !architecture_ids.insert(id) {
            return Err(Error::InvalidConfig(format!(
                "duplicate Runtime architecture {id:?}"
            )));
        }
        let aliases = architecture
            .get("system_names")
            .and_then(serde_json::Value::as_array)
            .filter(|aliases| !aliases.is_empty())
            .ok_or_else(|| {
                Error::InvalidConfig(format!("Runtime architecture {id:?} has no system_names"))
            })?;
        for alias in aliases {
            let alias = alias
                .as_str()
                .filter(|alias| safe_arch_name(alias))
                .ok_or_else(|| {
                    Error::InvalidConfig(format!(
                        "Runtime architecture {id:?} has an unsafe system name"
                    ))
                })?;
            if !system_names.insert(alias) {
                return Err(Error::InvalidConfig(format!(
                    "Runtime system architecture {alias:?} is mapped more than once"
                )));
            }
        }
    }
    let verification = runtime
        .get("verification")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| {
            Error::InvalidConfig("sources.runtime.verification must be an array".to_owned())
        })?;
    let verification_count = verification.len();
    let verification = verification
        .iter()
        .map(|value| {
            value.as_str().ok_or_else(|| {
                Error::InvalidConfig(
                    "sources.runtime.verification entries must be strings".to_owned(),
                )
            })
        })
        .collect::<Result<BTreeSet<_>>>()?;
    let required = ["url", "size", "md5", "squashfs_magic"]
        .into_iter()
        .collect::<BTreeSet<_>>();
    if verification_count != required.len() || verification != required {
        return Err(Error::InvalidConfig(
            "sources.runtime.verification does not match the implemented security contract"
                .to_owned(),
        ));
    }

    let transport = object("transport")?;
    require_exact_object_keys(
        transport,
        &[
            "proxy_registry_ref",
            "probe_batch_limit",
            "capabilities",
            "routes",
            "cache_scope",
            "resume_requires_same_formatted_endpoint",
        ],
        "sources.transport",
    )?;
    if transport
        .get("proxy_registry_ref")
        .and_then(serde_json::Value::as_str)
        != Some("embedded://github-proxy-registry/v1")
        || transport
            .get("resume_requires_same_formatted_endpoint")
            .and_then(serde_json::Value::as_bool)
            != Some(true)
        || transport
            .get("cache_scope")
            .and_then(serde_json::Value::as_str)
            != Some("process")
    {
        return Err(Error::InvalidConfig(
            "sources.transport has an unsupported security contract".to_owned(),
        ));
    }
    let batch = transport
        .get("probe_batch_limit")
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(0);
    if !(1..=32).contains(&batch) {
        return Err(Error::InvalidConfig(
            "sources.transport.probe_batch_limit must be between 1 and 32".to_owned(),
        ));
    }
    let capabilities = transport
        .get("capabilities")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| {
            Error::InvalidConfig("sources.transport.capabilities must be an array".into())
        })?;
    let capability_count = capabilities.len();
    let capabilities = capabilities
        .iter()
        .map(|value| {
            value.as_str().ok_or_else(|| {
                Error::InvalidConfig(
                    "sources.transport.capabilities entries must be strings".into(),
                )
            })
        })
        .collect::<Result<BTreeSet<_>>>()?;
    let required_capabilities = ["release", "raw", "archive", "api", "gist", "clone"]
        .into_iter()
        .collect::<BTreeSet<_>>();
    if capability_count != required_capabilities.len() || capabilities != required_capabilities {
        return Err(Error::InvalidConfig(
            "sources.transport.capabilities does not match the engine transport".into(),
        ));
    }
    let route_map = transport
        .get("routes")
        .and_then(serde_json::Value::as_object)
        .ok_or_else(|| Error::InvalidConfig("sources.transport.routes must be an object".into()))?;
    if route_map.keys().collect::<BTreeSet<_>>() != endpoints.keys().collect::<BTreeSet<_>>() {
        return Err(Error::InvalidConfig(
            "sources.transport.routes must map every endpoint exactly once".into(),
        ));
    }
    for endpoint in endpoints.keys() {
        if route_map.get(endpoint).and_then(serde_json::Value::as_str) != Some("release") {
            return Err(Error::InvalidConfig(format!(
                "source endpoint {endpoint:?} has no release transport route"
            )));
        }
    }
    Ok(())
}

fn safe_arch_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'_' | b'.' | b'-')
        })
}

fn require_exact_object_keys(
    object: &serde_json::Map<String, serde_json::Value>,
    expected: &[&str],
    path: &str,
) -> Result<()> {
    let actual = object.keys().map(String::as_str).collect::<BTreeSet<_>>();
    let expected = expected.iter().copied().collect::<BTreeSet<_>>();
    if actual != expected {
        return Err(Error::InvalidConfig(format!(
            "{path} has unexpected or missing fields"
        )));
    }
    Ok(())
}

fn require_detail_identity(
    object: &mut serde_json::Map<String, serde_json::Value>,
    field: &str,
    expected: &str,
    platform_id: &str,
) -> Result<()> {
    let actual = object
        .remove(field)
        .and_then(|value| value.as_str().map(str::to_owned))
        .ok_or_else(|| detail_identity_error(platform_id, field))?;
    if actual != expected {
        return Err(detail_identity_error(platform_id, field));
    }
    Ok(())
}

fn detail_identity_error(platform_id: &str, field: &str) -> Error {
    Error::InvalidConfig(format!(
        "platform {platform_id:?} detail has mismatched {field}"
    ))
}

pub(crate) fn validate_identifier(kind: &str, value: &str) -> Result<()> {
    let mut bytes = value.bytes();
    if value.len() > 128
        || !matches!(bytes.next(), Some(b'a'..=b'z'))
        || !bytes.all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'-' | b'_' | b'.')
        })
    {
        return Err(Error::InvalidConfig(format!(
            "invalid {kind} identifier {value:?}"
        )));
    }
    Ok(())
}

fn validate_limits(limits: &ParserLimits) -> Result<()> {
    if limits.max_depth == 0
        || limits.max_path_bytes == 0
        || limits.max_string_bytes == 0
        || limits.max_collection_items == 0
    {
        return Err(Error::InvalidConfig(
            "parser limits must be positive".into(),
        ));
    }
    Ok(())
}

pub(crate) fn parse_config_version(value: &str) -> Result<[u64; 3]> {
    let parts: Vec<_> = value.split('.').collect();
    if parts.len() != 3
        || parts
            .iter()
            .any(|part| part.is_empty() || !part.bytes().all(|byte| byte.is_ascii_digit()))
    {
        return Err(Error::InvalidConfig(format!(
            "config_version {value:?} is not numeric semantic versioning"
        )));
    }
    let mut result = [0; 3];
    for (index, part) in parts.into_iter().enumerate() {
        result[index] = part.parse().map_err(|_| {
            Error::InvalidConfig(format!("config_version component in {value:?} overflows"))
        })?;
    }
    Ok(result)
}

fn validate_json_limits(
    value: &serde_json::Value,
    limits: &ParserLimits,
    depth: usize,
) -> Result<()> {
    if depth > limits.max_depth {
        return Err(Error::InvalidConfig(format!(
            "JSON nesting exceeds max_depth {}",
            limits.max_depth
        )));
    }
    match value {
        serde_json::Value::String(value) => {
            if value.len() > limits.max_string_bytes {
                return Err(Error::InvalidConfig(format!(
                    "string exceeds max_string_bytes {}",
                    limits.max_string_bytes
                )));
            }
        }
        serde_json::Value::Array(values) => {
            if values.len() > limits.max_collection_items {
                return Err(Error::InvalidConfig(format!(
                    "array exceeds max_collection_items {}",
                    limits.max_collection_items
                )));
            }
            for value in values {
                validate_json_limits(value, limits, depth + 1)?;
            }
        }
        serde_json::Value::Object(values) => {
            if values.len() > limits.max_collection_items {
                return Err(Error::InvalidConfig(format!(
                    "object exceeds max_collection_items {}",
                    limits.max_collection_items
                )));
            }
            for (key, value) in values {
                if key.len() > limits.max_string_bytes {
                    return Err(Error::InvalidConfig(format!(
                        "object key exceeds max_string_bytes {}",
                        limits.max_string_bytes
                    )));
                }
                validate_json_limits(value, limits, depth + 1)?;
            }
        }
        _ => {}
    }
    Ok(())
}

pub(crate) fn validate_literal_path(value: &str, limits: &ParserLimits) -> Result<()> {
    if value.len() > limits.max_path_bytes {
        return Err(Error::InvalidConfig("path exceeds max_path_bytes".into()));
    }
    if value.as_bytes().contains(&0) {
        return Err(Error::InvalidConfig("path contains NUL".into()));
    }
    if Path::new(value)
        .components()
        .any(|component| matches!(component, std::path::Component::ParentDir))
    {
        return Err(Error::InvalidConfig(format!(
            "path {value:?} contains parent traversal"
        )));
    }
    Ok(())
}
