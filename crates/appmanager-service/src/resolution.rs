use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

const EMBEDDED_ROOT: &[u8] = include_bytes!("../../../config/config.json");

pub(crate) type DeviceResolution = appmanager_core::DeviceResolution;

#[derive(Clone, Debug)]
pub(crate) struct ConfigDirectories {
    pub embedded: Option<PathBuf>,
    pub remote: Option<PathBuf>,
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn resolve_device_context(
    launcher: PathBuf,
    app_state: PathBuf,
    trash: PathBuf,
    remote_config: Option<PathBuf>,
    target_override: Option<PathBuf>,
    root: Option<PathBuf>,
    config_directories: &ConfigDirectories,
) -> Result<DeviceResolution, String> {
    let embedded_dir = config_directories
        .embedded
        .clone()
        .or_else(|| std::env::var_os("PAM_CONFIG_DIR_OVERRIDE").map(PathBuf::from))
        .or_else(|| {
            let directory = std::env::current_exe().ok()?.parent()?.to_path_buf();
            if directory.join("platforms").is_dir() {
                return Some(directory);
            }
            let config = directory.parent()?.join("config");
            config.join("platforms").is_dir().then_some(config)
        })
        .unwrap_or_else(|| Path::new(env!("CARGO_MANIFEST_DIR")).join("../../config"));
    appmanager_core::resolve_device(appmanager_core::DeviceResolutionRequest {
        launcher,
        app_state,
        trash,
        target_override,
        probe_root: root,
        environment: BTreeMap::new(),
        config: appmanager_core::DeviceConfigSources {
            embedded_root: EMBEDDED_ROOT.to_vec(),
            embedded_dir,
            remote_root: remote_config,
            remote_dir: config_directories.remote.clone(),
        },
    })
    .map_err(|error| error.to_string())
}
