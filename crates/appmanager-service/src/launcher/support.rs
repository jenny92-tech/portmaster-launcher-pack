use std::env;
use std::ffi::CString;
use std::fs;
use std::io::Read;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::Instant;

use appmanager_core::{DEFAULT_LAUNCHER_SCRIPT_NAME, ProgressChannel, TaskProgress};
use portkit_core::ExclusiveFileLock;
use portkit_core::github::Progress;

pub(super) struct ActivityGuard {
    _lock: ExclusiveFileLock,
}

impl ActivityGuard {
    pub(super) fn acquire(lock: &Path) -> Result<Self, String> {
        let lock = ExclusiveFileLock::try_acquire(lock).map_err(|error| {
            if error.kind() == std::io::ErrorKind::WouldBlock {
                "another APP Manager operation is already running".to_owned()
            } else {
                error.to_string()
            }
        })?;
        Ok(Self { _lock: lock })
    }
}

pub(super) struct DownloadProgress {
    channel: Option<ProgressChannel>,
    runtime: &'static str,
    cancel: Option<appmanager_core::CancellationToken>,
    state: Mutex<(Instant, u64)>,
}

impl DownloadProgress {
    pub(super) fn new(
        channel: Option<ProgressChannel>,
        runtime: &'static str,
        cancel: Option<appmanager_core::CancellationToken>,
    ) -> Self {
        Self {
            channel,
            runtime,
            cancel,
            state: Mutex::new((Instant::now(), 0)),
        }
    }

    fn publish(&self, received: u64, total: u64) -> std::io::Result<()> {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let elapsed = state.0.elapsed().as_secs_f64();
        let speed = if elapsed > 0.25 {
            let speed = ((received.saturating_sub(state.1)) as f64 / elapsed) as u64;
            *state = (Instant::now(), received);
            speed
        } else {
            0
        };
        publish_progress(
            self.channel.as_ref(),
            "downloading",
            self.runtime,
            received,
            total,
            speed,
            self.runtime,
        );
        Ok(())
    }
}

impl Progress for DownloadProgress {
    fn update(&self, received: u64, total: u64) -> std::io::Result<()> {
        if self
            .cancel
            .as_ref()
            .is_some_and(|token| token.is_cancelled())
        {
            // Interrupt the transfer loop so a cancel request actually stops
            // the download instead of running to completion.
            return Err(std::io::Error::new(
                std::io::ErrorKind::Interrupted,
                "PortMaster download cancelled",
            ));
        }
        self.publish(received, total)
    }
}

pub(super) fn publish_task_progress(
    channel: Option<&ProgressChannel>,
    phase: &str,
    current: u64,
    total: u64,
    speed: u64,
    detail: &str,
) -> Result<(), String> {
    publish_progress(channel, phase, "PortMaster", current, total, speed, detail);
    Ok(())
}

fn publish_progress(
    channel: Option<&ProgressChannel>,
    phase: &str,
    runtime: &str,
    current: u64,
    total: u64,
    speed: u64,
    detail: &str,
) {
    if let Some(channel) = channel {
        channel.publish(TaskProgress {
            phase: phase.to_owned(),
            runtime: runtime.to_owned(),
            index: 0,
            count: 1,
            current,
            total,
            speed,
            detail: detail.replace(['\t', '\r', '\n'], " "),
        });
    }
}

pub(super) fn env_path(name: &str) -> Option<PathBuf> {
    env::var_os(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

pub(super) fn normalized_target_override(root: Option<&Path>) -> Option<PathBuf> {
    let target = env_path("PAM_PORTMASTER_DIR_OVERRIDE")?;
    let Some(root) = root else {
        return Some(target);
    };
    target
        .strip_prefix(root)
        .ok()
        .map(|relative| Path::new("/").join(relative))
        .or(Some(target))
}

pub(super) fn launcher_name(path: &Path) -> &str {
    path.file_name()
        .and_then(|value| value.to_str())
        .unwrap_or(DEFAULT_LAUNCHER_SCRIPT_NAME)
}

pub(super) fn path_string(path: Option<&Path>) -> String {
    path.map_or_else(String::new, |value| value.display().to_string())
}

pub(super) fn safe_version(value: &str) -> String {
    value
        .chars()
        .filter(|character| character.is_ascii_alphanumeric() || "._-".contains(*character))
        .collect()
}

pub(super) fn safe_asset_name(value: &str) -> bool {
    !value.is_empty()
        && !matches!(value, "." | "..")
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'+' | b'-'))
}

pub(super) fn device_arch() -> String {
    env::var("DEVICE_ARCH").unwrap_or_else(|_| match env::consts::ARCH {
        "aarch64" => "aarch64".into(),
        "x86_64" => "x86_64".into(),
        value => value.into(),
    })
}

pub(super) fn python_imports_ready(imports: &[String]) -> bool {
    let executable = env::var("PAM_PYTHON3_CMD_OVERRIDE").unwrap_or_else(|_| "python3".into());
    const CHECK: &str =
        "import importlib,sys\nfor name in sys.argv[1:]: importlib.import_module(name)";
    Command::new(executable)
        .arg("-c")
        .arg(CHECK)
        .args(imports)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

pub(super) fn squashfs_has_magic(path: &Path) -> bool {
    let mut magic = [0_u8; 4];
    fs::File::open(path)
        .and_then(|mut file| file.read_exact(&mut magic))
        .is_ok()
        && magic == *b"hsqs"
}

pub(super) fn read_update_cache(path: &Path) -> (u64, String, String) {
    let Ok(value) = fs::read_to_string(path) else {
        return (0, "unknown".into(), String::new());
    };
    let mut fields = value.trim_end().split('\t');
    let checked = fields
        .next()
        .and_then(|value| value.parse().ok())
        .unwrap_or(0);
    let status = match fields.next().unwrap_or("") {
        "ok" => "ok",
        "error" => "error",
        _ => "unknown",
    }
    .to_owned();
    let latest = fields
        .next()
        .filter(|value| {
            value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        })
        .unwrap_or("")
        .to_owned();
    (checked, status, latest)
}

pub(super) fn write_json(path: &Path, value: &impl serde::Serialize) -> Result<(), String> {
    let bytes = serde_json::to_vec_pretty(value).map_err(display_error)?;
    portkit_core::atomic_write(path, &bytes).map_err(display_error)
}

pub(super) fn free_bytes(path: &Path) -> u64 {
    let Ok(path) = CString::new(path.as_os_str().as_bytes()) else {
        return 0;
    };
    let mut value = std::mem::MaybeUninit::<libc::statvfs>::uninit();
    let result = unsafe { libc::statvfs(path.as_ptr(), value.as_mut_ptr()) };
    if result != 0 {
        return 0;
    }
    let value = unsafe { value.assume_init() };
    u64::from(value.f_bavail).saturating_mul(value.f_frsize)
}

pub(super) fn display_error(error: impl std::fmt::Display) -> String {
    error.to_string()
}
