// INPUT:  Hash-pinned installation manifest, declarative launch environment and shared process runner.
// OUTPUT: Native installation check, persistent profile selection, graphics probe and owned game session.
// POS:    Reusable device-side session policy; title-specific flags remain package data.
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::env;
use std::error::Error;
use std::ffi::{CString, OsString};
use std::fs::{self, File, OpenOptions};
use std::io::Read;
use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt};
use std::os::unix::io::AsRawFd;
use std::os::unix::process::CommandExt;
use std::path::{Component, Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

type Result<T> = std::result::Result<T, Box<dyn Error>>;

#[derive(Deserialize)]
pub struct Installation {
    pub files: BTreeMap<String, String>,
    pub profile: PathBuf,
    pub session: SessionSpec,
    #[serde(default)]
    pub runtime_identity: Option<Value>,
    #[serde(default)]
    pub title_id: Option<String>,
    #[serde(default)]
    pub game_build: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SessionSpec {
    pub id: String,
    pub program: String,
    pub args: Vec<String>,
    pub working_directory: String,
    pub environment: BTreeMap<String, String>,
    pub presentations: BTreeMap<String, BTreeMap<String, String>>,
    pub default_presentation: String,
    pub default_aspect: String,
    pub aspects: Vec<String>,
    pub default_video_driver: String,
    pub directories: Vec<String>,
    pub profile_candidates: Vec<PathBuf>,
    pub storage_roots: Vec<PathBuf>,
    pub clear_env_prefixes: Vec<String>,
    pub clear_env_keys: Vec<String>,
    pub error_prefixes: Vec<String>,
    pub runtime_directory: String,
    pub probe: ProbeSpec,
    #[serde(default)]
    pub low_memory: Option<LowMemorySpec>,
    #[serde(default)]
    pub diagnostics: Option<DiagnosticsSpec>,
    #[serde(default)]
    pub backends: BTreeMap<String, BackendSpec>,
    #[serde(default)]
    pub default_backend: String,
    #[serde(default)]
    pub render_scales: BTreeMap<String, String>,
    #[serde(default)]
    pub default_render_scale: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BackendSpec {
    pub program: String,
    pub args: Vec<String>,
    pub environment: BTreeMap<String, String>,
    pub presentations: Vec<String>,
    pub video_drivers: Vec<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProbeSpec {
    pub program: String,
    pub wsi_library: String,
    pub wsi_manifest: String,
    pub wsi_library_env: String,
    pub layer: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LowMemorySpec {
    pub below_mib: u64,
    pub minimum_free_mib: u64,
    pub environment: BTreeMap<String, String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DiagnosticsSpec {
    pub enable_env: String,
    pub environment: BTreeMap<String, String>,
    pub directories: Vec<String>,
}

#[derive(Default)]
pub struct LaunchOptions {
    pub profile: Option<PathBuf>,
    pub aspect: Option<String>,
    pub presentation: Option<String>,
    pub video_driver: Option<String>,
    pub private_wayland: bool,
    pub backend: Option<String>,
    pub render_scale: Option<String>,
}

pub fn digest(path: &Path) -> Result<String> {
    let mut input = File::open(path)?;
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 65536];
    loop {
        let read = input.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hash.update(&buffer[..read]);
    }
    Ok(format!("{:x}", hash.finalize()))
}

fn relative(value: &str) -> Result<&Path> {
    let path = Path::new(value);
    if value.is_empty()
        || value.contains(['\0', '\r', '\n'])
        || path.is_absolute()
        || path
            .components()
            .any(|p| !matches!(p, Component::Normal(_)))
        || path.to_string_lossy() != value
        || value
            .split('/')
            .any(|p| p.is_empty() || p == "." || p == "..")
    {
        return Err(format!("unsafe installation path: {value}").into());
    }
    Ok(path)
}

fn checked_file(root: &Path, name: &str) -> Result<PathBuf> {
    let mut path = root.to_owned();
    for component in relative(name)?.components() {
        path.push(component);
        if fs::symlink_metadata(&path)?.file_type().is_symlink() {
            return Err(format!("linked installation input: {name}").into());
        }
    }
    if !path.is_file() {
        return Err(format!("missing installation input: {name}").into());
    }
    Ok(path)
}

pub fn checked_profile(path: &Path) -> Result<PathBuf> {
    let text = path.to_str().ok_or("profile path must be UTF-8")?;
    if !path.is_absolute()
        || path == Path::new("/")
        || text.contains(['\0', '\r', '\n'])
        || path
            .components()
            .any(|p| matches!(p, Component::ParentDir | Component::CurDir))
    {
        return Err("profile must be an absolute persistent path below /".into());
    }
    for ancestor in path.ancestors() {
        match fs::symlink_metadata(ancestor) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                return Err("linked profile path".into());
            }
            Ok(_) => (),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
            Err(error) => return Err(error.into()),
        }
    }
    Ok(path.to_owned())
}

pub fn load(root: &Path) -> Result<(PathBuf, Installation)> {
    if fs::symlink_metadata(root)?.file_type().is_symlink() {
        return Err("linked installation root".into());
    }
    let root = root.canonicalize()?;
    let manifest: Installation =
        serde_json::from_slice(&fs::read(checked_file(&root, "installation.json")?)?)?;
    let spec = &manifest.session;
    if spec.id.is_empty()
        || !spec
            .id
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'_' | b'-'))
    {
        return Err("invalid session identifier".into());
    }
    if let Some(identity) = &manifest.runtime_identity {
        if identity.get("profile").and_then(Value::as_str) != Some("Release") {
            return Err("installation requires a Release runtime".into());
        }
        for (key, expected) in [
            ("title_id", &manifest.title_id),
            ("game_build", &manifest.game_build),
        ] {
            if let Some(expected) = expected {
                if identity.get(key).and_then(Value::as_str) != Some(expected) {
                    return Err("runtime identity mismatch".into());
                }
            }
        }
    }
    for (name, hash) in &manifest.files {
        relative(name)?;
        if hash.len() != 64
            || !hash
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(format!("invalid installation hash: {name}").into());
        }
    }
    for name in [
        &spec.program,
        &spec.probe.program,
        &spec.probe.wsi_library,
        &spec.probe.wsi_manifest,
    ] {
        relative(name)?;
        if !manifest.files.contains_key(name) {
            return Err(format!("unlisted session input: {name}").into());
        }
    }
    relative(&spec.runtime_directory)?;
    if !spec.backends.is_empty() && !spec.backends.contains_key(&spec.default_backend) {
        return Err("missing default renderer".into());
    }
    for (name, backend) in &spec.backends {
        if name.is_empty() || !name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_') {
            return Err("invalid renderer identifier".into());
        }
        relative(&backend.program)?;
        if !manifest.files.contains_key(&backend.program) {
            return Err("unlisted renderer program".into());
        }
    }
    if !spec.render_scales.is_empty() && !spec.render_scales.contains_key(&spec.default_render_scale) {
        return Err("missing default render scale".into());
    }
    for directory in &spec.directories {
        relative(directory)?;
    }
    Ok((root, manifest))
}

pub fn check(root: &Path, profile: Option<&Path>) -> Result<()> {
    let (root, manifest) = load(root)?;
    for (name, expected) in &manifest.files {
        if digest(&checked_file(&root, name)?)? != *expected {
            return Err(format!("changed installation input: {name}").into());
        }
    }
    checked_profile(profile.unwrap_or(&manifest.profile))?;
    Ok(())
}

pub fn select_profile(manifest: &Installation, explicit: Option<&Path>) -> Result<PathBuf> {
    if let Some(explicit) = explicit {
        return checked_profile(explicit);
    }
    let mut candidates = vec![manifest.profile.clone()];
    for candidate in &manifest.session.profile_candidates {
        if !candidates.contains(candidate) {
            candidates.push(candidate.clone());
        }
    }
    let mut existing = Vec::new();
    for candidate in &candidates {
        if candidate.is_dir() {
            existing.push(checked_profile(candidate)?);
        }
    }
    if existing.len() > 1 {
        return Err("multiple existing profiles; select --profile explicitly".into());
    }
    if let Some(profile) = existing.pop() {
        return Ok(profile);
    }
    for candidate in candidates {
        checked_profile(&candidate)?;
        for storage in &manifest.session.storage_roots {
            if storage != Path::new("/") && candidate.starts_with(storage) && storage.is_dir() {
                let name = CString::new(storage.as_os_str().as_encoded_bytes())?;
                if unsafe { libc::access(name.as_ptr(), libc::W_OK) } == 0 {
                    return Ok(candidate);
                }
            }
        }
    }
    if let Some(data) = env::var_os("XDG_DATA_HOME") {
        return checked_profile(
            &PathBuf::from(data)
                .join(&manifest.session.id)
                .join("profile"),
        );
    }
    Err("no persistent profile location; select --profile explicitly".into())
}

fn verify_input(root: &Path, manifest: &Installation, name: &str) -> Result<PathBuf> {
    let path = checked_file(root, name)?;
    if manifest.files.get(name) != Some(&digest(&path)?) {
        return Err(format!("changed session input: {name}").into());
    }
    Ok(path)
}

fn private_libraries(runtime: &Path) -> Result<OsString> {
    let endpoint =
        PathBuf::from(env::var_os("WAYLAND_DISPLAY").ok_or("missing private Wayland endpoint")?);
    let xdg = endpoint
        .parent()
        .ok_or("invalid private Wayland endpoint")?;
    let owned = xdg.parent().ok_or("invalid private Wayland endpoint")?;
    let advertised =
        env::var_os("PORTKIT_WAYLAND_SESSION_ROOT").ok_or("missing owned Wayland root")?;
    if !endpoint.is_absolute()
        || endpoint.file_name().and_then(|n| n.to_str()) != Some("rudroid-vulkan")
        || xdg.file_name().and_then(|n| n.to_str()) != Some("xdg")
        || owned != Path::new(&advertised)
        || !owned
            .file_name()
            .and_then(|n| n.to_str())
            .is_some_and(|n| n.starts_with("rudroid-wayland-"))
        || !fs::metadata(&endpoint)?.file_type().is_socket()
    {
        return Err("not a shared private Wayland endpoint".into());
    }
    let package = owned.join("weston");
    // The helper mounts a separate squashfs filesystem, never a same-device
    // bind mount. Verify its actual mount and the three paths it advertised.
    if fs::metadata(&package)?.dev() == fs::metadata(owned)?.dev() {
        return Err("private Wayland package is not mounted".into());
    }
    let paths = [
        runtime.join("portable-wayland"),
        package.join("lib_aarch64"),
        package.join("lib_aarch64/extra_wayland"),
    ];
    let inherited: Vec<_> =
        env::split_paths(&env::var_os("LD_LIBRARY_PATH").unwrap_or_default()).collect();
    if !runtime.join("portable-wayland/manifest.json").is_file()
        || inherited.get(..3) != Some(paths.as_slice())
    {
        return Err("incomplete private Wayland client environment".into());
    }
    Ok(env::join_paths(paths)?)
}

pub fn graphics_probe(root: &Path) -> Result<()> {
    let (root, manifest) = load(root)?;
    let probe = &manifest.session.probe;
    let program = verify_input(&root, &manifest, &probe.program)?;
    let mut command = Command::new(program);
    command
        .env_remove("LD_LIBRARY_PATH")
        .env_remove("LD_PRELOAD");
    if env::var_os("PORTKIT_WAYLAND_SESSION_ROOT").is_some() {
        command.env(
            "LD_LIBRARY_PATH",
            private_libraries(&root.join(&manifest.session.runtime_directory))?,
        );
    }
    if let Some(selected) = env::var_os(&probe.wsi_library_env) {
        let expected = verify_input(&root, &manifest, &probe.wsi_library)?;
        verify_input(&root, &manifest, &probe.wsi_manifest)?;
        let selected = PathBuf::from(selected);
        if !selected.is_absolute() || selected.canonicalize()? != expected {
            return Err("unexpected probe WSI library".into());
        }
        command
            .env(&probe.wsi_library_env, &expected)
            .env("VK_LAYER_PATH", expected.parent().unwrap());
        command
            .arg("--wsi")
            .arg(expected)
            .arg("--layer")
            .arg(&probe.layer);
    }
    Err(command.exec().into())
}

fn expand(
    value: &str,
    root: &Path,
    profile: &Path,
    trace: Option<&Path>,
    aspect: &str,
    video: &str,
    scale: &str,
) -> Result<String> {
    let root = root.to_str().ok_or("installation path must be UTF-8")?;
    let profile = profile.to_str().ok_or("profile path must be UTF-8")?;
    let trace = trace.and_then(Path::to_str).unwrap_or("");
    let value = value
        .replace("{root}", root)
        .replace("{profile}", profile)
        .replace("{trace}", trace)
        .replace("{aspect}", aspect)
        .replace("{render_scale}", scale)
        .replace("{video_driver}", video);
    if value.contains('\0') {
        return Err("NUL in launch value".into());
    }
    Ok(value)
}

fn write_json(path: &Path, value: &Value) -> Result<()> {
    let pending = path.with_extension("pending");
    for name in [path, pending.as_path()] {
        if fs::symlink_metadata(name).is_ok_and(|m| m.file_type().is_symlink()) {
            return Err("linked session report".into());
        }
    }
    fs::write(&pending, serde_json::to_vec_pretty(value)?)?;
    fs::rename(pending, path)?;
    Ok(())
}

fn low_memory(spec: &SessionSpec, private: bool) -> bool {
    let Some(policy) = &spec.low_memory else {
        return false;
    };
    let memory = fs::read_to_string("/proc/meminfo").ok().and_then(|text| {
        text.lines().find_map(|line| {
            line.strip_prefix("MemTotal:")
                .and_then(|v| v.split_whitespace().next())
                .and_then(|v| v.parse::<u64>().ok())
        })
    });
    memory
        .map(|kib| kib < policy.below_mib.saturating_mul(1024))
        .unwrap_or(private)
}

fn check_space(profile: &Path, minimum_mib: u64) -> Result<()> {
    let existing = profile
        .ancestors()
        .find(|p| p.exists())
        .ok_or("no profile storage ancestor")?;
    let name = CString::new(existing.as_os_str().as_encoded_bytes())?;
    let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(name.as_ptr(), &mut stat) } != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    if (stat.f_bavail as u128) * (stat.f_frsize as u128) < (minimum_mib as u128) * 1048576 {
        return Err(
            format!("low-memory mode needs at least {minimum_mib} MiB free storage").into(),
        );
    }
    Ok(())
}

pub fn run(root: &Path, options: &LaunchOptions) -> Result<i32> {
    let (root, manifest) = load(root)?;
    let profile = select_profile(&manifest, options.profile.as_deref())?;
    check(&root, Some(&profile))?;
    let spec = &manifest.session;
    let aspect = options.aspect.as_deref().unwrap_or(&spec.default_aspect);
    let presentation = options
        .presentation
        .as_deref()
        .unwrap_or(&spec.default_presentation);
    let video = options
        .video_driver
        .as_deref()
        .unwrap_or(&spec.default_video_driver);
    let backend_name = options.backend.as_deref().unwrap_or(&spec.default_backend);
    let backend = if spec.backends.is_empty() && backend_name.is_empty() {
        None
    } else {
        Some(spec.backends.get(backend_name).ok_or("unsupported renderer")?)
    };
    if let Some(backend) = backend {
        if !backend.presentations.iter().any(|p| p == presentation)
            || !backend.video_drivers.iter().any(|v| v == video)
        {
            return Err("renderer does not support this display route".into());
        }
    }
    let scale_name = options.render_scale.as_deref().unwrap_or(&spec.default_render_scale);
    let scale = if spec.render_scales.is_empty() && scale_name.is_empty() {
        ""
    } else {
        spec.render_scales.get(scale_name).ok_or("unsupported render scale")?
    };
    if !spec.aspects.iter().any(|a| a == aspect) {
        return Err("unsupported title aspect".into());
    }
    let presentation_env = spec
        .presentations
        .get(presentation)
        .ok_or("unsupported presentation route")?;
    if video == "wayland" {
        let display = env::var_os("WAYLAND_DISPLAY").ok_or("no active Wayland display")?;
        let mut endpoint = PathBuf::from(display);
        if !endpoint.is_absolute() {
            endpoint = PathBuf::from(
                env::var_os("XDG_RUNTIME_DIR").ok_or("no Wayland runtime directory")?,
            )
            .join(endpoint);
        }
        if !fs::metadata(endpoint)?.file_type().is_socket() {
            return Err("Wayland endpoint is not a live socket".into());
        }
    } else if !(video == "x11" && presentation == "native" && env::var_os("DISPLAY").is_some()
        || video.eq_ignore_ascii_case("kmsdrm") && presentation == "native" && backend.is_some()) {
        return Err("no validated display backend".into());
    }
    let libraries = if options.private_wayland {
        Some(private_libraries(&root.join(&spec.runtime_directory))?)
    } else {
        None
    };
    let low_memory = low_memory(spec, options.private_wayland);
    if low_memory {
        check_space(&profile, spec.low_memory.as_ref().unwrap().minimum_free_mib)?;
    }
    unsafe {
        libc::umask(0o077);
    }
    checked_profile(&profile)?;
    fs::create_dir_all(&profile)?;
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(profile.join("session.lock"))?;
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err("profile already in use".into());
    }
    for directory in &spec.directories {
        let path = profile.join(relative(directory)?);
        checked_profile(&path)?;
        fs::create_dir_all(path)?;
    }
    let diagnostics = spec
        .diagnostics
        .as_ref()
        .filter(|d| env::var(&d.enable_env).as_deref() == Ok("1"));
    let trace = if diagnostics.is_some() {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let trace = profile.join(format!("logs/run-{stamp}"));
        fs::create_dir(&trace)?;
        for directory in &diagnostics.unwrap().directories {
            fs::create_dir(trace.join(relative(directory)?))?;
        }
        Some(trace)
    } else {
        None
    };
    let program = backend.map_or(&spec.program, |b| &b.program);
    let arguments = backend.map_or(&spec.args, |b| &b.args);
    let mut command = Command::new(root.join(program));
    for argument in arguments {
        command.arg(expand(
            argument,
            &root,
            &profile,
            trace.as_deref(),
            aspect,
            video,
            scale,
        )?);
    }
    command.current_dir(expand(
        &spec.working_directory,
        &root,
        &profile,
        trace.as_deref(),
        aspect,
        video,
        scale,
    )?);
    for (name, _) in env::vars_os() {
        if spec.clear_env_keys.iter().any(|key| name == key.as_str())
            || spec
                .clear_env_prefixes
                .iter()
                .any(|prefix| name.to_string_lossy().starts_with(prefix))
        {
            command.env_remove(name);
        }
    }
    if let Some(libraries) = libraries {
        command.env("LD_LIBRARY_PATH", libraries);
    }
    for environment in std::iter::once(&spec.environment)
        .chain(std::iter::once(presentation_env))
        .chain(backend.map(|b| &b.environment))
        .chain(
            spec.low_memory
                .as_ref()
                .filter(|_| low_memory)
                .map(|p| &p.environment),
        )
        .chain(diagnostics.map(|d| &d.environment))
    {
        for (name, value) in environment {
            if name.is_empty() || !name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_') {
                return Err("invalid launch environment name".into());
            }
            command.env(
                name,
                expand(value, &root, &profile, trace.as_deref(), aspect, video, scale)?,
            );
        }
    }
    let mut report = json!({"active":true,"kind":"portkit-native-session","parent_pid":std::process::id(),
        "runtime":root.join(program),"runtime_sha256":manifest.files[program],"title_id":manifest.title_id,
        "backend":backend_name,"render_scale":scale_name,"aspect":aspect,"video_driver":video,
        "run":trace,"boot_id":fs::read_to_string("/proc/sys/kernel/random/boot_id").ok().map(|s|s.trim().to_owned())});
    let full_log = trace.as_ref().map(|p| p.join("stdout.log"));
    let result = crate::process::run_owned(command, full_log.as_deref(), |pid| {
        report["pid"] = json!(pid);
        if let Some(trace) = &trace {
            write_json(&trace.join("session.json"), &report)?;
            write_json(&profile.join("logs/current-session.json"), &report)?;
        }
        Ok(())
    })?;
    if let Some(trace) = &trace {
        report["active"] = json!(false);
        report["returncode"] = json!(result.exit_code);
        report["owned_child_reaped"] = json!(true);
        write_json(
            &trace.join("exit.json"),
            &json!({"returncode":result.exit_code,"owned_child_reaped":true}),
        )?;
        write_json(&profile.join("logs/current-session.json"), &report)?;
    }
    let failed_line = result.tail.split(|b| *b == b'\n').any(|line| {
        spec.error_prefixes
            .iter()
            .any(|prefix| line.starts_with(prefix.as_bytes()))
    });
    if result.exit_code != 0 || failed_line {
        let path = profile.join("logs/last-error.log");
        if fs::symlink_metadata(&path).is_ok_and(|m| m.file_type().is_symlink()) {
            return Err("linked error log".into());
        }
        fs::write(&path, &result.tail)?;
        eprintln!("game session failed; log: {}", path.display());
    }
    drop(lock);
    Ok(result.exit_code)
}
