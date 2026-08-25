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
    pub identity: DeviceIdentity,
    pub config: Config,
    pub resolution: Resolution,
    pub context: ResolvedDeviceContext,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DeviceIdentity {
    pub manufacturer: Option<String>,
    pub submodel: Option<String>,
    pub system_name: Option<String>,
    pub system_version: Option<String>,
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
        detection.os_release = if os_release.is_file() {
            parse_os_release(&fs::read(os_release)?)?
        } else {
            BTreeMap::new()
        };
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
    let selector = CandidateSelector {
        loader: ConfigLoader::default(),
    };
    let embedded_root = request.config.embedded_root;
    let mut selected = selector.select_root_for_context(
        ConfigCandidate::embedded(embedded_root.clone()),
        &embedded_details,
        remote,
        &detection,
    )?;
    let app_owned = AppOwnedPaths {
        state: request.app_state,
        trash: request.trash,
    };
    let mut context = ResolvedDeviceContext::try_from(ResolvedContextInput {
        resolution: selected.resolution.clone(),
        app_owned: app_owned.clone(),
    });
    // A remote candidate is not committed until APP Manager's complete
    // domain context validates. PortKit intentionally does not depend on this
    // crate, so this final fallback belongs at the application boundary.
    if context.is_err() && selected.selected.origin == ConfigOrigin::Remote {
        selected = selector.select_root_for_context(
            ConfigCandidate::embedded(embedded_root),
            &embedded_details,
            None,
            &detection,
        )?;
        context = ResolvedDeviceContext::try_from(ResolvedContextInput {
            resolution: selected.resolution.clone(),
            app_owned,
        });
    }
    let config_origin = selected.selected.origin;
    let config = selected.selected.config;
    let resolution = selected.resolution;
    let model_id = resolution.model_id.clone();
    let identity = detect_identity(
        &detection,
        &resolution.platform_display_name,
        resolution.model_id.as_deref(),
    );
    let context = context.map_err(|error| DeviceResolutionError::Context(error.to_string()))?;
    Ok(DeviceResolution {
        config_origin,
        model_id,
        identity,
        config,
        resolution,
        context,
    })
}

fn detect_identity(
    context: &DetectionContext,
    platform_display_name: &str,
    model_id: Option<&str>,
) -> DeviceIdentity {
    DeviceIdentity {
        manufacturer: first_value([
            context.environment.get("DEVICE_MANUFACTURER").cloned(),
            context.environment.get("MANUFACTURER").cloned(),
            read_probe(context, "/sys/class/dmi/id/sys_vendor"),
        ]),
        submodel: first_value([
            context.environment.get("DEVICE").cloned(),
            model_id.map(str::to_owned),
            read_probe(context, "/sys/firmware/devicetree/base/model"),
            read_probe(context, "/proc/device-tree/model"),
            read_probe(context, "/sys/class/dmi/id/product_name"),
        ]),
        system_name: first_value([
            context.environment.get("CFW_NAME").cloned(),
            context.os_release.get("PRETTY_NAME").cloned(),
            context.os_release.get("NAME").cloned(),
            context.os_release.get("OS_NAME").cloned(),
            context.os_release.get("ID").cloned(),
            Some(platform_display_name.to_owned()),
        ]),
        system_version: first_value([
            context.environment.get("CFW_VERSION").cloned(),
            context.os_release.get("VERSION_ID").cloned(),
            context.os_release.get("VERSION").cloned(),
            context.os_release.get("BUILD_ID").cloned(),
            read_probe(context, "/loong/loong_version"),
            read_probe(context, "/etc/batocera-version"),
        ]),
    }
}

fn first_value<const N: usize>(values: [Option<String>; N]) -> Option<String> {
    values.into_iter().flatten().find_map(|value| {
        let value = value.trim_matches(['\0', ' ', '\t', '\r', '\n']);
        (!value.is_empty()).then(|| value.to_owned())
    })
}

fn read_probe(context: &DetectionContext, path: &str) -> Option<String> {
    context
        .rooted_path(path)
        .ok()
        .and_then(|path| fs::read(path).ok())
        .and_then(|bytes| String::from_utf8(bytes).ok())
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

    fn satisfy_predicate(
        predicate: &portkit_core::predicate::Predicate,
        root: &Path,
        context: &mut DetectionContext,
    ) {
        let string = |names: &[&str]| {
            names
                .iter()
                .find_map(|name| predicate.arguments.get(*name)?.as_str())
                .unwrap()
        };
        match predicate.kind.as_str() {
            "always" => {}
            "all" => {
                for child in &predicate.predicates {
                    satisfy_predicate(child, root, context);
                }
            }
            "any" => satisfy_predicate(&predicate.predicates[0], root, context),
            "directory_exists" => {
                let path = string(&["path", "value"]);
                fs::create_dir_all(root.join(path.trim_start_matches('/'))).unwrap();
            }
            "file_exists" => {
                let path = root.join(string(&["path", "value"]).trim_start_matches('/'));
                fs::create_dir_all(path.parent().unwrap()).unwrap();
                fs::write(path, b"fixture\n").unwrap();
            }
            "launcher_path_prefix" => {
                context.launcher_path =
                    Path::new(string(&["prefix", "path", "value"])).join("APP Manager.sh");
            }
            "env_equals" => {
                context.environment.insert(
                    predicate.string_argument("name").unwrap().to_owned(),
                    predicate.string_argument("value").unwrap().to_owned(),
                );
            }
            "os_release_equals" => {
                context.os_release.insert(
                    string(&["field", "name", "key"]).to_owned(),
                    predicate.string_argument("value").unwrap().to_owned(),
                );
            }
            "os_release_version_at_least" => {
                context.os_release.insert(
                    predicate.string_argument("field").unwrap().to_owned(),
                    predicate.string_argument("value").unwrap().to_owned(),
                );
            }
            other => panic!("unsupported fixture predicate {other}"),
        }
    }

    #[test]
    fn os_release_parser_accepts_standard_quotes_and_ignores_comments() {
        let parsed = parse_os_release(b"# comment\nOS_NAME='ROCKNIX'\nVERSION=2026.07\n").unwrap();
        assert_eq!(parsed["OS_NAME"], "ROCKNIX");
        assert_eq!(parsed["VERSION"], "2026.07");
    }

    #[test]
    fn identity_prefers_firmware_and_model_facts_then_uses_platform_fallbacks() {
        let probe = tempfile::tempdir().unwrap();
        let context = DetectionContext {
            // Keep this fallback test independent of the build host's DMI
            // identity (for example QEMU inside the ARM64 lab container).
            root: Some(probe.path().to_path_buf()),
            launcher_path: "/ports/Test.sh".into(),
            environment: BTreeMap::from([
                ("CFW_NAME".into(), "CrossMix".into()),
                ("CFW_VERSION".into(), "1.3.0".into()),
                ("DEVICE".into(), "smart-pro".into()),
            ]),
            os_release: BTreeMap::from([
                ("PRETTY_NAME".into(), "Buildroot".into()),
                ("VERSION_ID".into(), "2024.02".into()),
            ]),
            target_override: None,
        };
        let identity = detect_identity(&context, "TrimUI", Some("smart_pro"));
        assert_eq!(identity.submodel.as_deref(), Some("smart-pro"));
        assert_eq!(identity.manufacturer, None);
        assert_eq!(identity.system_name.as_deref(), Some("CrossMix"));
        assert_eq!(identity.system_version.as_deref(), Some("1.3.0"));
    }

    #[test]
    fn identity_reads_hardware_and_miniloong_version_from_the_probed_root() {
        let root = tempfile::tempdir().unwrap();
        fs::create_dir_all(root.path().join("sys/class/dmi/id")).unwrap();
        fs::create_dir_all(root.path().join("loong")).unwrap();
        fs::write(
            root.path().join("sys/class/dmi/id/sys_vendor"),
            b"Example Devices\n",
        )
        .unwrap();
        fs::write(root.path().join("loong/loong_version"), b"1.2.3\n").unwrap();
        let context = DetectionContext {
            root: Some(root.path().into()),
            launcher_path: "/ports/Test.sh".into(),
            environment: BTreeMap::new(),
            os_release: BTreeMap::new(),
            target_override: None,
        };
        let identity = detect_identity(&context, "MiniLoong Pocket One", None);
        assert_eq!(identity.manufacturer.as_deref(), Some("Example Devices"));
        assert_eq!(
            identity.system_name.as_deref(),
            Some("MiniLoong Pocket One")
        );
        assert_eq!(identity.system_version.as_deref(), Some("1.2.3"));
    }

    #[test]
    fn every_current_platform_reaches_the_app_domain_and_install_boundary() {
        let config_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../config");
        let loader = ConfigLoader::default();
        let root_bytes = fs::read(config_dir.join("config.json")).unwrap();
        let root_config = loader.parse_root(&root_bytes).unwrap();
        for (platform_id, entry) in &root_config.platforms {
            let fixture = tempfile::tempdir().unwrap();
            let root = fixture.path();
            fs::create_dir_all(root.join("launcher")).unwrap();
            let mut detection = DetectionContext {
                root: Some(root.to_path_buf()),
                launcher_path: "/launcher/APP Manager.sh".into(),
                environment: BTreeMap::new(),
                os_release: BTreeMap::new(),
                target_override: Some("/target/PortMaster".into()),
            };
            satisfy_predicate(&entry.recognition, root, &mut detection);
            fs::create_dir_all(root.join("target/PortMaster")).unwrap();
            let config = loader
                .load_platform(
                    loader.parse_root(&root_bytes).unwrap(),
                    platform_id,
                    &LocalFragmentSource::new(&config_dir),
                )
                .unwrap();
            let platform = &config.platforms[platform_id];
            for strategy in platform.paths.values() {
                if strategy.strategy == "first_existing" {
                    let candidate = strategy.arguments["candidates"][0].as_str().unwrap();
                    fs::create_dir_all(root.join(candidate.trim_start_matches('/'))).unwrap();
                }
            }
            let resolution = config.detect_and_resolve(&loader, &detection).unwrap();
            assert_eq!(&resolution.platform_id, platform_id);
            for path in resolution.paths.values() {
                fs::create_dir_all(path).unwrap();
            }
            let state = root.join("owned/state");
            let trash = root.join("owned/trash");
            fs::create_dir_all(&state).unwrap();
            fs::create_dir_all(&trash).unwrap();
            let context = ResolvedDeviceContext::try_from(ResolvedContextInput {
                resolution,
                app_owned: AppOwnedPaths { state, trash },
            })
            .unwrap_or_else(|error| panic!("{platform_id}: {error}"));
            if context.management == crate::ManagementMode::App {
                let plan = crate::InstallPlan::from_context(&context)
                    .unwrap_or_else(|error| panic!("{platform_id}: {error}"));
                plan.validate(&context)
                    .unwrap_or_else(|error| panic!("{platform_id}: {error}"));
            }
        }
    }
}
