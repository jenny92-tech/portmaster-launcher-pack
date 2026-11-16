// INPUT: Audited GNU/Linux clients, PortMaster Weston image and literal command.
// OUTPUT: One bounded private compositor session, cleaned before returning status.
// POS: Supply missing Wayland capabilities without changing the system GPU stack or VT.
use crate::{
    process::{self, Owned, Signals},
    session,
};
use serde::Deserialize;
use std::{
    collections::BTreeMap,
    env,
    error::Error,
    ffi::{CString, OsString},
    fs::{self, File, OpenOptions},
    os::unix::{
        ffi::OsStringExt,
        fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt},
        io::AsRawFd,
    },
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant},
};
type Result<T> = std::result::Result<T, Box<dyn Error>>;

#[derive(Deserialize)]
struct Manifest {
    minimum_glibc: String,
    files: BTreeMap<String, Entry>,
}
#[derive(Deserialize)]
struct Entry {
    size: u64,
    sha256: String,
}
fn version(value: &str) -> Result<(u32, u32)> {
    let mut parts = value.trim().split('.');
    Ok((
        parts.next().ok_or("missing libc major")?.parse()?,
        parts.next().ok_or("missing libc minor")?.parse()?,
    ))
}
fn regular(path: &Path) -> Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err(format!("not a regular runtime input: {}", path.display()).into());
    }
    Ok(())
}
fn system_glibc() -> Result<(u32, u32)> {
    // This helper is static musl. Its own libc cannot identify the GNU ABI
    // required by the separately executed SDL/Vulkan clients.
    let mut command = Command::new("getconf");
    command.arg("GNU_LIBC_VERSION");
    let output = process::run_bounded(command, Duration::from_secs(3));
    if let Ok(output) = output {
        if output.exit_code == 0 {
            let text = String::from_utf8(output.tail)?;
            if let Some(v) = text.strip_prefix("glibc ") {
                return version(v);
            }
        }
    }
    let mut command = Command::new("/lib/ld-linux-aarch64.so.1");
    command.arg("--version");
    let output = process::run_bounded(command, Duration::from_secs(3))?;
    if output.exit_code == 0 {
        let text = String::from_utf8(output.tail)?;
        if let Some(v) = text
            .lines()
            .next()
            .and_then(|s| s.split_whitespace().last())
        {
            return version(v);
        }
    }
    Err("cannot establish system GNU libc version".into())
}
pub fn check(runtime: &Path, image: &Path) -> Result<()> {
    if !cfg!(all(target_os = "linux", target_arch = "aarch64")) {
        return Err("portable Wayland requires ARM64 Linux".into());
    }
    if unsafe { libc::geteuid() } != 0 {
        return Err("portable Weston requires private mount permission".into());
    }
    let clients = runtime.join("portable-wayland");
    regular(&clients.join("manifest.json"))?;
    let manifest: Manifest = serde_json::from_slice(&fs::read(clients.join("manifest.json"))?)?;
    if system_glibc()? < version(&manifest.minimum_glibc)? {
        return Err(format!("portable clients require glibc {}", manifest.minimum_glibc).into());
    }
    for (name, entry) in &manifest.files {
        if name.is_empty()
            || name.contains(['/', '\\', '\0', '\r', '\n'])
            || matches!(name.as_str(), "." | ".." | "manifest.json")
        {
            return Err("invalid client manifest path".into());
        }
        let file = clients.join(name);
        regular(&file)?;
        if fs::metadata(&file)?.len() != entry.size || session::digest(&file)? != entry.sha256 {
            return Err(format!("changed private client: {name}").into());
        }
    }
    if !["libSDL2-2.0.so.0", "libvulkan.so.1"]
        .iter()
        .all(|n| manifest.files.contains_key(*n))
    {
        return Err("incomplete private client manifest".into());
    }
    regular(image)?;
    if !Path::new("/dev/dri/card0").exists() {
        return Err("DRM card0 is missing".into());
    }
    for name in [
        "libVkLayer_window_system_integration.so",
        "VkLayer_window_system_integration.json",
    ] {
        regular(&runtime.join("vulkan-wsi").join(name))?;
    }
    Ok(())
}
fn server(runtime: &Path, xdg: &Path, logs: &Path) -> Result<Command> {
    let libraries = runtime.join("lib_aarch64");
    let mut modules = BTreeMap::new();
    for name in [
        "drm-backend",
        "headless-backend",
        "wayland-backend",
        "gl-renderer",
    ] {
        modules.insert(
            name,
            libraries.join("libweston-14").join(format!("{name}.so")),
        );
    }
    modules.insert("kiosk-shell", libraries.join("weston/kiosk-shell.so"));
    // Squashfs libraries may contain legitimate relative SONAME links. The
    // immutable mounted package is trusted; the client manifest stays strict.
    for file in std::iter::once(runtime.join("wp_weston")).chain(modules.values().cloned()) {
        if !file.is_file() {
            return Err(format!("incomplete Weston package: {}", file.display()).into());
        }
    }
    let map = modules
        .iter()
        .map(|(n, p)| format!("{n}.so={};", p.display()))
        .collect::<String>();
    let mut command = Command::new(runtime.join("wp_weston"));
    command
        .env_clear()
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin:/usr/trimui/bin")
        .env(
            "LD_LIBRARY_PATH",
            format!("{}:/usr/lib", libraries.display()),
        )
        .env("XDG_RUNTIME_DIR", xdg)
        .env("WESTON_MODULE_MAP", map)
        .env("WESTON_DATA_DIR", runtime.join("data"))
        .env("WESTON_LIBEXEC_DIR", runtime.join("libexec"))
        .env("XKB_CONFIG_ROOT", runtime.join("share/xkb"))
        .env("LIBSEAT_BACKEND", "builtin");
    if env::var("RUDROID_WAYLAND_FORCE_RENDERER").as_deref() == Ok("1") {
        command.env("WESTON_FORCE_RENDERER", "1");
    }
    command
        .args([
            "--backend=drm",
            "--drm-device=card0",
            "--renderer=gl",
            "--shell=kiosk-shell.so",
            "--socket=rudroid-vulkan",
            "--no-config",
            "--idle-time=0",
            "--continue-without-input",
            "--current-mode",
        ])
        .arg(format!("--log={}", logs.join("weston.log").display()));
    let output = File::create(logs.join("weston-stderr.log"))?;
    command
        .stdin(Stdio::null())
        .stdout(output.try_clone()?)
        .stderr(output);
    Ok(command)
}
fn client(runtime: &Path, package: &Path, root: &Path, argv: &[OsString]) -> Result<Command> {
    let mut command = Command::new(&argv[0]);
    command.args(&argv[1..]);
    let mut paths = vec![
        runtime.join("portable-wayland"),
        package.join("lib_aarch64"),
        package.join("lib_aarch64/extra_wayland"),
    ];
    if let Some(inherited) = env::var_os("LD_LIBRARY_PATH") {
        paths.extend(env::split_paths(&inherited));
    }
    command
        .env("LD_LIBRARY_PATH", env::join_paths(paths)?)
        .env("SDL_VIDEODRIVER", "wayland")
        .env("WAYLAND_DISPLAY", root.join("xdg/rudroid-vulkan"))
        .env("PORTKIT_WAYLAND_SESSION_ROOT", root)
        .env("DISABLE_WSI_LAYER", "1")
        .env("XKB_CONFIG_ROOT", package.join("share/xkb"))
        .env("VK_LAYER_PATH", runtime.join("vulkan-wsi"))
        .env(
            "RUDROID_VULKAN_WSI_LIBRARY",
            runtime.join("vulkan-wsi/libVkLayer_window_system_integration.so"),
        )
        .env_remove("LIBGL_FB");
    Ok(command)
}
fn bounded(program: &str, args: &[&std::ffi::OsStr]) -> Result<()> {
    bounded_with_signals(program, args, &mut Signals::new()?)
}
fn bounded_with_signals(
    program: &str,
    args: &[&std::ffi::OsStr],
    signals: &mut Signals,
) -> Result<()> {
    let mut command = Command::new(program);
    command.args(args);
    let result = process::run_bounded_with_signals(command, Duration::from_secs(10), signals)?;
    if result.exit_code != 0 {
        return Err(format!(
            "private session {program} failed ({}): {}",
            result.exit_code,
            String::from_utf8_lossy(&result.tail)
        )
        .into());
    }
    Ok(())
}
struct Root {
    path: PathBuf,
    mounted: bool,
}
impl Root {
    fn new() -> Result<Self> {
        let base = env::temp_dir().canonicalize()?;
        let template = base.join("rudroid-wayland-XXXXXX");
        let mut bytes =
            CString::new(template.as_os_str().as_encoded_bytes())?.into_bytes_with_nul();
        if unsafe { libc::mkdtemp(bytes.as_mut_ptr().cast()) }.is_null() {
            return Err(std::io::Error::last_os_error().into());
        }
        bytes.pop();
        let path = PathBuf::from(OsString::from_vec(bytes));
        Ok(Self {
            path,
            mounted: false,
        })
    }
    fn cleanup(&mut self) -> Result<()> {
        // A timed-out mount command may still have completed its mount. Never
        // walk a mounted runtime merely because the subprocess failed first.
        if let (Ok(package), Ok(root)) = (
            fs::metadata(self.path.join("weston")),
            fs::metadata(&self.path),
        ) {
            self.mounted |= package.dev() != root.dev();
        }
        if self.mounted {
            bounded("umount", &[self.path.join("weston").as_os_str()])?;
            self.mounted = false;
        }
        fs::remove_dir_all(&self.path)?;
        Ok(())
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        if self.path.exists() {
            if let Err(e) = self.cleanup() {
                eprintln!("[WAYLAND] retained owned root after cleanup failure: {e}");
            }
        }
    }
}

pub fn run(runtime: &Path, image: &Path, logs: &Path, argv: &[OsString]) -> Result<i32> {
    if argv.is_empty() {
        return Err("private session requires command argv".into());
    }
    if let Some(display) = env::var_os("WAYLAND_DISPLAY") {
        let endpoint = PathBuf::from(display);
        let endpoint = if endpoint.is_absolute() {
            endpoint
        } else {
            env::var_os("XDG_RUNTIME_DIR")
                .map(PathBuf::from)
                .unwrap_or_default()
                .join(endpoint)
        };
        if fs::metadata(endpoint).is_ok_and(|m| m.file_type().is_socket()) {
            return Err("private Wayland must not replace an existing display".into());
        }
    }
    let runtime = runtime.canonicalize()?;
    let image = image.canonicalize()?;
    check(&runtime, &image)?;
    if !logs.is_absolute()
        || logs
            .components()
            .any(|p| matches!(p, std::path::Component::ParentDir))
        || fs::symlink_metadata(logs).is_ok_and(|m| m.file_type().is_symlink())
    {
        return Err("invalid private session log directory".into());
    }
    fs::create_dir_all(logs)?;
    // Firmware storage aliases are allowed; only our freshly allocated mount
    // root below is subject to ownership and unmount/removal operations.
    let logs = logs.canonicalize()?;
    let lock = OpenOptions::new()
        .write(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open("/tmp/rudroid-wayland-session.lock")?;
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err("another private Wayland session is active".into());
    }
    #[cfg(target_os = "linux")]
    {
        if unsafe { libc::unshare(libc::CLONE_NEWNS) } != 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        let slash = CString::new("/")?;
        if unsafe {
            libc::mount(
                std::ptr::null(),
                slash.as_ptr(),
                std::ptr::null(),
                libc::MS_REC | libc::MS_PRIVATE,
                std::ptr::null(),
            )
        } != 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
    }
    let mut root = Root::new()?;
    // Drop this guard before Root's cleanup creates a fresh one. Reusing it
    // for mount avoids nested signal guards; cleanup must survive cancellation.
    let mut signals = Signals::new()?;
    let result = (|| -> Result<i32> {
        let package = root.path.join("weston");
        let xdg = root.path.join("xdg");
        fs::create_dir(&package)?;
        fs::create_dir(&xdg)?;
        fs::set_permissions(&xdg, fs::Permissions::from_mode(0o700))?;
        bounded_with_signals(
            "mount",
            &[
                std::ffi::OsStr::new("-o"),
                std::ffi::OsStr::new("loop,ro,exec,nosuid,nodev"),
                image.as_os_str(),
                package.as_os_str(),
            ],
            &mut signals,
        )?;
        root.mounted = true;
        if signals.cancelled() != 0 {
            return Err("private session cancelled".into());
        }
        let mut server_command = server(&package, &xdg, &logs)?;
        let mut compositor = Owned::spawn(&mut server_command)?;
        drop(server_command);
        let endpoint = xdg.join("rudroid-vulkan");
        let deadline = Instant::now() + Duration::from_secs(8);
        loop {
            if signals.cancelled() != 0 {
                return Err("private session cancelled".into());
            }
            if compositor.0.try_wait()?.is_some() || Instant::now() >= deadline {
                return Err("Weston did not establish its private display".into());
            }
            if fs::metadata(&endpoint).is_ok_and(|m| m.file_type().is_socket()) {
                break;
            }
            signals.wait(None, 50)?;
        }
        let output = process::run_with_signals(
            client(&runtime, &package, &root.path, argv)?,
            None,
            |pid| {
                let _ = fs::write(format!("/proc/{pid}/oom_score_adj"), "0");
                Ok(())
            },
            &mut signals,
            Some(&mut compositor),
        )?;
        // Probe receipts and errors must remain visible to the calling Shell.
        use std::io::Write;
        std::io::stdout().write_all(&output.tail)?;
        compositor.stop();
        Ok(output.exit_code)
    })();
    drop(signals);
    root.cleanup()?;
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn glibc_versions() {
        assert_eq!(version("2.33\n").unwrap(), (2, 33));
        assert!(version("musl").is_err());
    }
}
