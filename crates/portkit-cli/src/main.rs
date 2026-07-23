use portkit_core::github::{Capability, GitHubRegistry, GitHubTransport};
use portkit_core::{
    CandidateSelector, CommandEnvironment, Config, ConfigCandidate, ConfigLoader, ConfigOrigin,
    ConfigRefreshStatus, DetectionContext, DigestAlgorithm, EnvironmentOperation,
    EnvironmentPolicy, Error, LocalFragmentSource, ResolvedSelection, Result, digest_file,
    zip_readable,
};
use serde::Serialize;
use serde_json::json;
use std::collections::BTreeMap;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const EMBEDDED_ROOT: &[u8] = include_bytes!("../../../config/config.json");
const SOURCE_REVISION: &str = match option_env!("PORTKIT_SOURCE_REVISION") {
    Some(value) => value,
    None => "development",
};

pub fn cli_main() {
    match run(std::env::args().skip(1).collect()) {
        Ok(0) => {}
        Ok(exit_code) => std::process::exit(exit_code),
        Err(error) => {
            let payload = json!({"ok": false, "error": error.to_string()});
            eprintln!(
                "{}",
                serde_json::to_string(&payload).unwrap_or_else(|_| "{\"ok\":false}".into())
            );
            std::process::exit(2);
        }
    }
}

fn run(arguments: Vec<String>) -> Result<i32> {
    let Some(command) = arguments.first().map(String::as_str) else {
        return Err(usage());
    };
    match command {
        "config" if arguments.get(1).map(String::as_str) == Some("validate") => {
            config_validate(&arguments[2..]).map(|_| 0)
        }
        "config" if arguments.get(1).map(String::as_str) == Some("select-detail") => {
            config_select_detail(&arguments[2..]).map(|_| 0)
        }
        "config" if arguments.get(1).map(String::as_str) == Some("refresh") => {
            config_refresh(&arguments[2..]).map(|_| 0)
        }
        "detect" | "resolve" => detect(&arguments[1..]).map(|_| 0),
        "health" => health(&arguments[1..]).map(|_| 0),
        "env" if arguments.get(1).map(String::as_str) == Some("resolve") => {
            environment_resolve(&arguments[2..]).map(|_| 0)
        }
        "env" if matches!(arguments.get(1).map(String::as_str), Some("exec" | "run")) => {
            environment_exec(&arguments[2..])
        }
        "github" if arguments.get(1).map(String::as_str) == Some("candidates") => {
            github_candidates(&arguments[2..]).map(|_| 0)
        }
        "github" if arguments.get(1).map(String::as_str) == Some("fetch") => {
            github_fetch(&arguments[2..]).map(|_| 0)
        }
        "file" if arguments.get(1).map(String::as_str) == Some("digest") => {
            file_digest(&arguments[2..]).map(|_| 0)
        }
        "file" if arguments.get(1).map(String::as_str) == Some("zip-readable") => {
            file_zip_readable(&arguments[2..]).map(|_| 0)
        }
        "font" if arguments.get(1).map(String::as_str) == Some("provision") => {
            font_provision(&arguments[2..]).map(|_| 0)
        }
        "version" | "--version" | "-V" => {
            println!("portkit {} {SOURCE_REVISION}", env!("CARGO_PKG_VERSION"));
            Ok(0)
        }
        "help" | "--help" | "-h" => {
            println!("{}", usage_text());
            Ok(0)
        }
        _ => Err(usage()),
    }
}

fn file_digest(arguments: &[String]) -> Result<()> {
    let options = Options::parse(arguments)?;
    let input = Path::new(required_option(&options, "input")?);
    let algorithm = DigestAlgorithm::parse(required_option(&options, "algorithm")?)?;
    let digest = digest_file(input, algorithm)?;
    match options.one("format").unwrap_or("raw") {
        "raw" => println!("{digest}"),
        "json" => print_json(&json!({"ok": true, "digest": digest}))?,
        _ => {
            return Err(Error::InvalidConfig(
                "--format must be raw or json".to_owned(),
            ));
        }
    }
    Ok(())
}

fn file_zip_readable(arguments: &[String]) -> Result<()> {
    let options = Options::parse(arguments)?;
    let input = Path::new(required_option(&options, "input")?);
    if !zip_readable(input)? {
        return Err(Error::InvalidConfig("ZIP archive is empty".to_owned()));
    }
    print_json(&json!({"ok": true, "readable": true}))
}

fn font_provision(arguments: &[String]) -> Result<()> {
    let options = Options::parse(arguments)?;
    let request = portkit_launcher::font::ProvisionRequest {
        candidates: options.many("candidate").map(PathBuf::from).collect(),
        tar_xz_sources: options.many("tar-xz").map(PathBuf::from).collect(),
        zip_sources: options.many("zip").map(PathBuf::from).collect(),
        outputs: options.many("output").map(PathBuf::from).collect(),
        member: options
            .one("member")
            .unwrap_or("NotoSansSC-Regular.ttf")
            .to_owned(),
    };
    let outcome = portkit_launcher::font::provision(&request)?;
    match options.one("format").unwrap_or("raw") {
        "raw" => println!("{}", outcome.path.display()),
        "json" => print_json(&outcome)?,
        _ => {
            return Err(Error::InvalidConfig(
                "--format must be raw or json".to_owned(),
            ));
        }
    }
    Ok(())
}

fn build_registry() -> GitHubRegistry {
    GitHubRegistry::configured()
}

fn github_candidates(arguments: &[String]) -> Result<()> {
    let options = Options::parse(arguments)?;
    let capability = github_capability(&options)?;
    let source = required_option(&options, "source")?;
    let routes = build_registry()
        .candidate_route_ids(capability, source)
        .map_err(github_error)?;
    print_json(&json!({
        "ok": true,
        "capability": capability.as_str(),
        "count": routes.len(),
        "routes": routes,
    }))
}

/// Streams fetch progress as the UI-compatible 9-field TSV row
/// `1\tdownloading\t<runtime>\t<index>\t<count>\t<current>\t<total>\t<speed>\t<detail>`,
/// written atomically (tmp + rename) so the reader never sees a partial line.
/// Speed is average bytes/sec for bytes transferred by the current route
/// attempt, excluding bytes already present when a resume begins.
struct TsvProgress {
    file: PathBuf,
    runtime: String,
    index: u64,
    count: u64,
    cancel_file: Option<PathBuf>,
    state: std::sync::Mutex<TsvProgressState>,
    #[cfg(not(unix))]
    lock_path: PathBuf,
    _lock: File,
}

struct TsvProgressState {
    start: std::time::Instant,
    base: u64,
    previous: u64,
    last_write: Option<std::time::Instant>,
}

enum FetchProgress {
    Tsv(TsvProgress),
    Cancel(PathBuf),
}

impl portkit_core::github::Progress for FetchProgress {
    fn begin(&self, received: u64, total: u64) -> io::Result<()> {
        match self {
            Self::Tsv(progress) => progress.begin(received, total),
            Self::Cancel(path) => check_cancel_path(path),
        }
    }

    fn update(&self, received: u64, total: u64) -> io::Result<()> {
        match self {
            Self::Tsv(progress) => progress.update(received, total),
            Self::Cancel(path) => check_cancel_path(path),
        }
    }

    fn finish(&self, received: u64, total: u64) -> io::Result<()> {
        match self {
            Self::Tsv(progress) => progress.finish(received, total),
            Self::Cancel(path) => check_cancel_path(path),
        }
    }
}

fn check_cancel_path(path: &Path) -> io::Result<()> {
    if path.exists() {
        Err(io::Error::new(io::ErrorKind::Interrupted, "cancelled"))
    } else {
        Ok(())
    }
}

impl TsvProgress {
    fn new(
        file: PathBuf,
        runtime: String,
        index: u64,
        count: u64,
        cancel_file: Option<PathBuf>,
    ) -> io::Result<Self> {
        reject_progress_symlink(&file)?;
        let lock_path: PathBuf = format!("{}.lock", file.display()).into();
        reject_progress_symlink(&lock_path)?;
        #[cfg(unix)]
        let lock = {
            let lock = std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .truncate(false)
                .open(&lock_path)?;
            try_lock_progress(&lock)?;
            lock
        };
        #[cfg(not(unix))]
        let lock = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&lock_path)
            .map_err(|error| {
                if error.kind() == io::ErrorKind::AlreadyExists {
                    io::Error::new(
                        io::ErrorKind::WouldBlock,
                        "progress writer is already active",
                    )
                } else {
                    error
                }
            })?;
        Ok(Self {
            file,
            runtime,
            index,
            count,
            cancel_file,
            state: std::sync::Mutex::new(TsvProgressState {
                start: std::time::Instant::now(),
                base: 0,
                previous: 0,
                last_write: None,
            }),
            #[cfg(not(unix))]
            lock_path,
            _lock: lock,
        })
    }
}

impl portkit_core::github::Progress for TsvProgress {
    fn begin(&self, received: u64, total: u64) -> io::Result<()> {
        let now = std::time::Instant::now();
        {
            let mut state = self
                .state
                .lock()
                .map_err(|_| io::Error::other("progress lock poisoned"))?;
            state.start = now;
            state.base = received;
            state.previous = received;
            state.last_write = None;
        }
        self.update(received, total)
    }

    fn finish(&self, received: u64, total: u64) -> io::Result<()> {
        self.state
            .lock()
            .map_err(|_| io::Error::other("progress lock poisoned"))?
            .last_write = Some(std::time::Instant::now() - std::time::Duration::from_millis(250));
        self.update(received, total)
    }

    fn update(&self, received: u64, total: u64) -> io::Result<()> {
        if let Some(path) = &self.cancel_file {
            check_cancel_path(path)?;
        }
        let now = std::time::Instant::now();
        let mut state = self
            .state
            .lock()
            .map_err(|_| io::Error::other("progress lock poisoned"))?;
        if received < state.previous {
            state.start = now;
            state.base = received;
            state.last_write = None;
        } else if state.last_write.is_none() {
            state.base = received;
            state.start = now;
        }
        state.previous = received;
        if state
            .last_write
            .is_some_and(|last| now.duration_since(last) < std::time::Duration::from_millis(250))
            && (total == 0 || received != total)
        {
            return Ok(());
        }
        let elapsed = now.duration_since(state.start).as_secs_f64();
        let speed = if elapsed > 0.0 {
            ((received - state.base) as f64 / elapsed) as u64
        } else {
            0
        };
        let row = format!(
            "1\tdownloading\t{}\t{}\t{}\t{}\t{}\t{}\t\n",
            self.runtime, self.index, self.count, received, total, speed
        );
        let tmp: PathBuf = format!("{}.tmp.{}", self.file.display(), std::process::id()).into();
        reject_progress_symlink(&tmp)?;
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&tmp)?;
        file.write_all(row.as_bytes())?;
        file.sync_all()?;
        drop(file);
        reject_progress_symlink(&self.file)?;
        std::fs::rename(&tmp, &self.file).inspect_err(|_| {
            let _ = std::fs::remove_file(&tmp);
        })?;
        state.last_write = Some(now);
        Ok(())
    }
}

impl Drop for TsvProgress {
    fn drop(&mut self) {
        #[cfg(not(unix))]
        let _ = std::fs::remove_file(&self.lock_path);
    }
}

#[cfg(unix)]
fn try_lock_progress(file: &File) -> io::Result<()> {
    use std::os::fd::AsRawFd;

    unsafe extern "C" {
        fn flock(file_descriptor: i32, operation: i32) -> i32;
    }
    // SAFETY: `file` owns a live descriptor for the duration of this call.
    if unsafe { flock(file.as_raw_fd(), 2 | 4) } == 0 {
        Ok(())
    } else {
        let error = io::Error::last_os_error();
        if error.kind() == io::ErrorKind::WouldBlock {
            Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "progress writer is already active",
            ))
        } else {
            Err(error)
        }
    }
}

fn reject_progress_symlink(path: &Path) -> io::Result<()> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("progress path is a symlink: {}", path.display()),
        )),
        Ok(_) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

fn github_fetch(arguments: &[String]) -> Result<()> {
    let options = Options::parse(arguments)?;
    let capability = github_capability(&options)?;
    let source = required_option(&options, "source")?;
    let output = Path::new(required_option(&options, "output")?);
    let number = |name: &str, default: u64| -> Result<u64> {
        options.one(name).map_or(Ok(default), |value| {
            value.parse::<u64>().map_err(|_| {
                Error::InvalidConfig(format!("--{name} must be a non-negative integer"))
            })
        })
    };
    let progress = options
        .one("progress")
        .map(|file| {
            TsvProgress::new(
                PathBuf::from(file),
                options
                    .one("progress-runtime")
                    .unwrap_or("Runtime")
                    .to_owned(),
                number("progress-index", 1)?,
                number("progress-count", 1)?,
                options.one("cancel-file").map(PathBuf::from),
            )
            .map(FetchProgress::Tsv)
            .map_err(Error::Io)
        })
        .transpose()?
        .or_else(|| {
            options
                .one("cancel-file")
                .map(|path| FetchProgress::Cancel(PathBuf::from(path)))
        });
    let max_bytes = options
        .one("max-bytes")
        .map(|value| {
            value
                .parse::<u64>()
                .map_err(|_| Error::InvalidConfig("--max-bytes must be a positive integer".into()))
        })
        .transpose()?;
    if max_bytes == Some(0) {
        return Err(Error::InvalidConfig(
            "--max-bytes must be a positive integer".into(),
        ));
    }
    let validator = options.one("validator").unwrap_or("nonempty");
    if !matches!(validator, "nonempty" | "json" | "config-root") {
        return Err(Error::InvalidConfig(
            "--validator must be nonempty, json, or config-root".into(),
        ));
    }
    let expected_sha256 = options.one("expected-sha256");
    if let Some(expected) = expected_sha256 {
        if expected.len() != 64
            || !expected
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err(Error::InvalidConfig(
                "--expected-sha256 must be a lowercase SHA-256 digest".into(),
            ));
        }
    }
    let expected_md5 = options.one("expected-md5");
    if let Some(expected) = expected_md5 {
        if expected.len() != 32
            || !expected
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err(Error::InvalidConfig(
                "--expected-md5 must be a lowercase MD5 digest".into(),
            ));
        }
    }
    if expected_sha256.is_some() && expected_md5.is_some() {
        return Err(Error::InvalidConfig(
            "--expected-sha256 and --expected-md5 cannot be combined".into(),
        ));
    }
    if validator != "nonempty" && (expected_sha256.is_some() || expected_md5.is_some()) {
        return Err(Error::InvalidConfig(
            "--validator and an expected digest cannot be combined".into(),
        ));
    }
    let mut transport = GitHubTransport::with_registry(build_registry());
    if let Some(value) = options.one("batch-size") {
        let batch_size = value.parse::<usize>().map_err(|_| {
            Error::InvalidConfig("--batch-size must be an integer from 1 through 10".into())
        })?;
        transport.set_batch_size(batch_size).map_err(github_error)?;
    }
    let outcome = transport
        .fetch(
            capability,
            source,
            output,
            |path| {
                if let Some(expected) = expected_sha256 {
                    return digest_file(path, DigestAlgorithm::Sha256)
                        .is_ok_and(|value| value == expected);
                }
                if let Some(expected) = expected_md5 {
                    return digest_file(path, DigestAlgorithm::Md5)
                        .is_ok_and(|value| value == expected);
                }
                match validator {
                    "config-root" => std::fs::read(path)
                        .is_ok_and(|bytes| ConfigLoader::default().parse_root(&bytes).is_ok()),
                    "json" => std::fs::read(path).is_ok_and(|bytes| {
                        serde_json::from_slice::<serde_json::Value>(&bytes).is_ok()
                    }),
                    _ => path.metadata().is_ok_and(|metadata| metadata.len() > 0),
                }
            },
            progress
                .as_ref()
                .map(|value| value as &dyn portkit_core::github::Progress),
            max_bytes,
        )
        .map_err(github_error)?;
    print_json(&json!({
        "ok": true,
        "capability": capability.as_str(),
        "route": outcome.route_id(),
    }))
}

fn github_capability(options: &Options) -> Result<Capability> {
    required_option(options, "capability")?
        .parse()
        .map_err(github_error)
}

fn required_option<'a>(options: &'a Options, name: &str) -> Result<&'a str> {
    options
        .one(name)
        .ok_or_else(|| Error::InvalidConfig(format!("option --{name} is required")))
}

fn github_error(error: portkit_core::github::GitHubError) -> Error {
    Error::InvalidConfig(error.to_string())
}

fn config_validate(arguments: &[String]) -> Result<()> {
    let options = Options::parse(arguments)?;
    let loader = ConfigLoader::default();
    let (config, origin) = load_config(&loader, &options)?;
    let adapters = options
        .one("platform")
        .map(|platform| loader.validate_resolved_closure(&config, platform))
        .transpose()?;
    print_json(&json!({
        "ok": true,
        "origin": origin,
        "format": config.format,
        "schema_version": config.schema_version,
        "config_version": config.config_version,
        "platform": options.one("platform"),
        "adapters": adapters,
    }))
}

fn config_refresh(arguments: &[String]) -> Result<()> {
    let options = Options::parse(arguments)?;
    let result_path = PathBuf::from(required_option(&options, "result")?);
    write_config_refresh_status(&result_path, "running")?;
    match config_refresh_inner(&options) {
        Ok(status) => {
            write_config_refresh_status(&result_path, status.as_str())?;
            print_json(&json!({"ok": true, "status": status}))
        }
        Err(error) => {
            let _ = write_config_refresh_status(&result_path, "error");
            Err(error)
        }
    }
}

fn config_refresh_inner(options: &Options) -> Result<ConfigRefreshStatus> {
    let source = required_option(options, "source")?.to_owned();
    let packaged_root = PathBuf::from(required_option(options, "config")?);
    let packaged_dir = PathBuf::from(required_option(options, "config-dir")?);
    let cached_root = PathBuf::from(required_option(options, "cache")?);
    let cache_dir = PathBuf::from(required_option(options, "cache-dir")?);
    let timeout = options
        .one("timeout-seconds")
        .unwrap_or("40")
        .parse::<u64>()
        .map_err(|_| Error::InvalidConfig("--timeout-seconds must be an integer".into()))?;
    let context = detection_context(options)?;
    portkit_core::refresh_config(&portkit_core::ConfigRefreshRequest {
        source,
        packaged_root,
        packaged_dir,
        cached_root,
        cache_dir,
        timeout: std::time::Duration::from_secs(timeout),
        detection: context,
    })
}

fn write_config_refresh_status(path: &Path, status: &str) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| Error::InvalidConfig("config refresh result has no parent".into()))?;
    fs::create_dir_all(parent)?;
    for counter in 0_u16..1000 {
        let temporary = parent.join(format!(
            ".config-refresh-{}-{counter}.tmp",
            std::process::id()
        ));
        let mut file = match fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
        {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error.into()),
        };
        let result = (|| -> io::Result<()> {
            writeln!(file, "1\t{status}")?;
            file.sync_all()?;
            drop(file);
            fs::rename(&temporary, path)
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        return result.map_err(Error::Io);
    }
    Err(Error::InvalidConfig(
        "unable to allocate config refresh temporary file".into(),
    ))
}

fn config_select_detail(arguments: &[String]) -> Result<()> {
    let options = Options::parse(arguments)?;
    let path = Path::new(required_option(&options, "config")?);
    let loader = ConfigLoader::default();
    let root = loader.parse_root(&std::fs::read(path)?)?;
    let context = detection_context(&options)?;
    let fields = selected_detail_fields(&loader, &root, &context)?;
    match options.one("format").unwrap_or("json") {
        "tsv" => {
            for (name, value) in fields {
                println!("{name}\t{value}");
            }
            Ok(())
        }
        "json" => print_json(&json!({
            "ok": true,
            "schema": fields[0].1.clone(),
            "config_version": fields[1].1.clone(),
            "platform_id": fields[2].1.clone(),
            "detail_ref": fields[3].1.clone(),
            "detail_sha256": fields[4].1.clone(),
        })),
        _ => Err(Error::InvalidConfig("--format must be json or tsv".into())),
    }
}

fn selected_detail_fields(
    loader: &ConfigLoader,
    root: &portkit_core::RootConfig,
    context: &DetectionContext,
) -> Result<Vec<(&'static str, String)>> {
    let platform_id = loader.detect_root(root, context)?;
    let entry = &root.platforms[&platform_id];
    let fields = vec![
        ("schema", root.schema_version.to_string()),
        ("config_version", root.config_version.clone()),
        ("platform_id", platform_id),
        ("detail_ref", entry.detail.clone()),
        ("detail_sha256", entry.sha256.clone()),
    ];
    for (name, value) in &fields {
        if value.contains(['\t', '\r', '\n']) {
            return Err(Error::InvalidConfig(format!(
                "selected detail field {name:?} contains a line delimiter"
            )));
        }
    }
    Ok(fields)
}

fn detect(arguments: &[String]) -> Result<()> {
    let options = Options::parse(arguments)?;
    let loader = ConfigLoader::default();
    let context = detection_context(&options)?;
    let selected = select_config_for_context(loader, &options, &context)?;
    if options.one("format") == Some("tsv") {
        return print_resolution_tsv(&selected.resolution, &selected.selected.config);
    }
    if options.one("format").is_some_and(|format| format != "json") {
        return Err(Error::InvalidConfig("--format must be json or tsv".into()));
    }
    print_json(
        &json!({"ok": true, "config_origin": selected.selected.origin, "resolution": selected.resolution}),
    )
}

fn health(arguments: &[String]) -> Result<()> {
    let options = Options::parse(arguments)?;
    let loader = ConfigLoader::default();
    let context = detection_context(&options)?;
    let selected = select_config_for_context(loader, &options, &context)?;
    let mut report = portkit_core::evaluate_health(&selected.resolution)?;
    let python_ready = python_ready(
        &report,
        options.one("python-executable").unwrap_or("python3"),
    )?;
    report.python_ready = Some(python_ready);
    if report.status != portkit_core::HealthStatus::Unresolved && !python_ready {
        report.status = portkit_core::HealthStatus::Damaged;
        report.healthy = false;
    }
    match options.one("format").unwrap_or("json") {
        "json" => print_json(&json!({
            "ok": true,
            "config_origin": selected.selected.origin,
            "report": report,
        })),
        "tsv" => print_health_tsv(&report),
        _ => Err(Error::InvalidConfig("--format must be json or tsv".into())),
    }
}

fn python_ready(report: &portkit_core::HealthReport, executable: &str) -> Result<bool> {
    if report.status == portkit_core::HealthStatus::Unresolved {
        return Ok(false);
    }
    match report.python_mode.as_str() {
        "system" => {
            if executable.is_empty() {
                return Err(Error::InvalidConfig(
                    "--python-executable must not be empty".into(),
                ));
            }
            const CHECK_IMPORTS: &str =
                "import importlib, sys\nfor name in sys.argv[1:]: importlib.import_module(name)";
            Ok(Command::new(executable)
                .arg("-c")
                .arg(CHECK_IMPORTS)
                .args(&report.python_imports)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .is_ok_and(|status| status.success()))
        }
        "runtime_mount" => Ok(report
            .python_runtime_image
            .as_deref()
            .is_some_and(squashfs_has_magic)),
        mode => Err(Error::InvalidConfig(format!(
            "unsupported Python health mode {mode:?}"
        ))),
    }
}

fn squashfs_has_magic(path: &Path) -> bool {
    let Ok(metadata) = path.symlink_metadata() else {
        return false;
    };
    if !metadata.file_type().is_file() {
        return false;
    }
    let mut magic = [0_u8; 4];
    let Ok(mut file) = File::open(path) else {
        return false;
    };
    file.read_exact(&mut magic).is_ok() && magic == *b"hsqs"
}

fn print_health_tsv(report: &portkit_core::HealthReport) -> Result<()> {
    let status = match report.status {
        portkit_core::HealthStatus::Healthy => "healthy",
        portkit_core::HealthStatus::Damaged => "damaged",
        portkit_core::HealthStatus::Unresolved => "unresolved",
    };
    for import in &report.python_imports {
        if import.is_empty()
            || import.contains([',', '\t', '\r', '\n'])
            || !import
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.'))
        {
            return Err(Error::InvalidConfig(format!(
                "unsafe Python import name {import:?}"
            )));
        }
    }
    let fields = [
        ("schema", "1".to_owned()),
        ("health_contract", report.contract.to_owned()),
        (
            "health_required",
            portkit_core::health::HEALTH_REQUIRED_KINDS.to_owned(),
        ),
        ("platform_id", report.platform_id.clone()),
        ("health_status", status.to_owned()),
        ("health_healthy", report.healthy.to_string()),
        ("health_checks_total", report.checks.len().to_string()),
        (
            "health_checks_passed",
            report
                .checks
                .iter()
                .filter(|check| check.passed)
                .count()
                .to_string(),
        ),
        ("python_mode", report.python_mode.clone()),
        ("python_imports", report.python_imports.join(",")),
        (
            "python_ready",
            report.python_ready.unwrap_or(false).to_string(),
        ),
    ];
    for (name, value) in fields {
        if value.contains(['\t', '\r', '\n']) {
            return Err(Error::InvalidConfig(format!(
                "health TSV field {name:?} contains a line delimiter"
            )));
        }
        println!("{name}\t{value}");
    }
    Ok(())
}

fn environment_resolve(arguments: &[String]) -> Result<()> {
    let options = Options::parse(arguments)?;
    let prepared = prepare_environment(&options)?;
    let resolved = prepared
        .command_environment
        .resolve(&prepared.policy, std::env::vars_os())?;
    print_json(&json!({
        "ok": true, "config_origin": prepared.origin, "platform_id": prepared.platform_id,
        "scope": prepared.scope, "environment": resolved,
    }))
}

fn environment_exec(arguments: &[String]) -> Result<i32> {
    let separator = arguments
        .iter()
        .position(|argument| argument == "--")
        .ok_or_else(|| {
            Error::InvalidConfig("env exec requires `--` before the child command".into())
        })?;
    let command_arguments = &arguments[separator + 1..];
    let program = command_arguments.first().ok_or_else(|| {
        Error::InvalidConfig("env exec requires a child command after `--`".into())
    })?;
    let options = Options::parse(&arguments[..separator])?;
    let prepared = prepare_environment(&options)?;
    let mut command = Command::new(program);
    command.args(&command_arguments[1..]);
    prepared.command_environment.apply_to_command(
        &mut command,
        &prepared.policy,
        std::env::vars_os(),
    )?;
    let status = command.status()?;
    Ok(child_exit_code(status))
}

struct PreparedEnvironment {
    origin: ConfigOrigin,
    platform_id: String,
    scope: String,
    policy: EnvironmentPolicy,
    command_environment: CommandEnvironment,
}

fn prepare_environment(options: &Options) -> Result<PreparedEnvironment> {
    let loader = ConfigLoader::default();
    let context = detection_context(options)?;
    let selected = select_config_for_context(loader, options, &context)?;
    let config = selected.selected.config;
    let origin = selected.selected.origin;
    let resolution = selected.resolution;
    let scope = options.one("scope").unwrap_or("appmanager").to_owned();

    if !config.platforms[&resolution.platform_id]
        .environment_scopes
        .iter()
        .any(|item| item == &scope)
    {
        return Err(Error::Environment(format!(
            "scope {scope:?} is not enabled for platform {:?}",
            resolution.platform_id
        )));
    }
    let mut variables = options.assignments("var")?;
    variables
        .entry("platform_id".into())
        .or_insert_with(|| resolution.platform_id.clone());
    for (name, path) in &resolution.paths {
        let value = path.to_string_lossy().into_owned();
        variables
            .entry(name.clone())
            .or_insert_with(|| value.clone());
        variables.entry(format!("{name}_dir")).or_insert(value);
    }
    let mut command_environment = config
        .environment
        .command_environment_for_scope(&scope, &variables)?;
    command_environment.clear = options.flag("clean");
    for assignment in options.many("set") {
        let (name, value) = split_assignment(assignment)?;
        command_environment
            .operations
            .push(EnvironmentOperation::Set {
                name: name.into(),
                value: value.into(),
            });
    }
    for name in options.many("unset") {
        command_environment
            .operations
            .push(EnvironmentOperation::Unset { name: name.clone() });
    }
    Ok(PreparedEnvironment {
        origin,
        platform_id: resolution.platform_id,
        scope,
        policy: config.environment,
        command_environment,
    })
}

fn child_exit_code(status: std::process::ExitStatus) -> i32 {
    if let Some(code) = status.code() {
        return code;
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        status.signal().map_or(1, |signal| 128 + signal)
    }
    #[cfg(not(unix))]
    1
}

fn load_config(loader: &ConfigLoader, options: &Options) -> Result<(Config, ConfigOrigin)> {
    let candidates = config_candidates(options)?;
    let embedded_details = LocalFragmentSource::new(&candidates.embedded_dir);
    let remote_details = candidates.remote_dir.as_ref().map(LocalFragmentSource::new);
    let remote = candidates.remote.zip(
        remote_details
            .as_ref()
            .map(|source| source as &dyn portkit_core::FragmentSource),
    );
    let platform = options.one("platform").unwrap_or("generic");
    let selected = CandidateSelector {
        loader: loader.clone(),
    }
    .select_root_platform(candidates.embedded, &embedded_details, remote, platform)?;
    Ok((selected.config, selected.origin))
}

struct RootCandidates {
    embedded: ConfigCandidate,
    embedded_dir: PathBuf,
    remote: Option<ConfigCandidate>,
    remote_dir: Option<PathBuf>,
}

fn config_candidates(options: &Options) -> Result<RootCandidates> {
    let (embedded, default_embedded_dir) =
        if let Some(path) = options.one("config").map(PathBuf::from) {
            let directory = path.parent().unwrap_or(Path::new(".")).to_path_buf();
            (ConfigCandidate::embedded(std::fs::read(&path)?), directory)
        } else {
            (
                ConfigCandidate::embedded(EMBEDDED_ROOT),
                default_config_dir()?,
            )
        };
    let embedded_dir = options
        .one("config-dir")
        .map(PathBuf::from)
        .unwrap_or(default_embedded_dir);
    let remote_path = options.one("remote-config").map(PathBuf::from);
    // The packaged config is authoritative fallback. An optional cache may be
    // concurrently replaced, unreadable, or partially removed; treat that as
    // no remote candidate instead of preventing the application from starting.
    let remote = remote_path
        .as_ref()
        .and_then(|path| std::fs::read(path).ok())
        .map(ConfigCandidate::remote);
    let remote_dir = remote_path.map(|path| {
        options
            .one("remote-config-dir")
            .map(PathBuf::from)
            .unwrap_or_else(|| path.parent().unwrap_or(Path::new(".")).to_path_buf())
    });
    Ok(RootCandidates {
        embedded,
        embedded_dir,
        remote,
        remote_dir,
    })
}

fn default_config_dir() -> Result<PathBuf> {
    if let Some(path) = std::env::var_os("PAM_CONFIG_DIR_OVERRIDE") {
        return Ok(path.into());
    }
    if let Some(directory) = std::env::current_exe()?.parent() {
        if directory.join("platforms").is_dir() {
            return Ok(directory.to_path_buf());
        }
        if let Some(app_root) = directory.parent() {
            let config = app_root.join("config");
            if config.join("platforms").is_dir() {
                return Ok(config);
            }
        }
    }
    Ok(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../config"))
}

fn select_config_for_context(
    loader: ConfigLoader,
    options: &Options,
    context: &DetectionContext,
) -> Result<ResolvedSelection> {
    let candidates = config_candidates(options)?;
    let embedded_details = LocalFragmentSource::new(&candidates.embedded_dir);
    let remote_details = candidates.remote_dir.as_ref().map(LocalFragmentSource::new);
    let remote = candidates.remote.zip(
        remote_details
            .as_ref()
            .map(|source| source as &dyn portkit_core::FragmentSource),
    );
    CandidateSelector { loader }.select_root_for_context(
        candidates.embedded,
        &embedded_details,
        remote,
        context,
    )
}

fn print_resolution_tsv(resolution: &portkit_core::Resolution, config: &Config) -> Result<()> {
    for (name, value) in resolution_tsv_fields(resolution, config)? {
        println!("{name}\t{value}");
    }
    Ok(())
}

fn resolution_tsv_fields(
    resolution: &portkit_core::Resolution,
    config: &Config,
) -> Result<Vec<(&'static str, String)>> {
    let path = |name: &str| {
        resolution
            .paths
            .get(name)
            .map(|path| path.to_string_lossy().into_owned())
            .unwrap_or_default()
    };
    let frontend_management = resolution
        .frontend
        .get("management")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("");
    let frontend_kind = resolution
        .frontend
        .get("kind")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("");
    let frontend_primary = resolution
        .frontend
        .get("primary")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("");
    let python_mode = resolution
        .python
        .get("mode")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("");
    let frontend_names = resolution
        .frontend
        .get("names")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| Error::Resolution("frontend names are not an array".into()))?
        .iter()
        .map(|value| {
            value
                .as_str()
                .ok_or_else(|| Error::Resolution("frontend name is not a string".into()))
        })
        .collect::<Result<Vec<_>>>()?;
    for name in frontend_names
        .iter()
        .copied()
        .chain(std::iter::once(frontend_primary))
    {
        if name.is_empty()
            || matches!(name, "." | "..")
            || name.contains(['/', '\\', ',', '\t', '\r', '\n'])
        {
            return Err(Error::Resolution(format!(
                "unsafe frontend child name {name:?}"
            )));
        }
    }
    let display_width = required_integer(&resolution.display, "default_width", "display")?;
    let display_height = required_integer(&resolution.display, "default_height", "display")?;
    let analog_sticks = required_integer(&resolution.input, "analog_sticks", "input")?;
    let capability = |name: &str| {
        resolution
            .capabilities
            .get(name)
            .copied()
            .unwrap_or(false)
            .to_string()
    };
    let release_routes = config
        .sources
        .get("release_routes")
        .and_then(serde_json::Value::as_object)
        .ok_or_else(|| Error::InvalidConfig("sources.release_routes is not an object".into()))?;
    let route = release_routes
        .get(&resolution.source_route)
        .and_then(serde_json::Value::as_object)
        .ok_or_else(|| {
            Error::InvalidConfig(format!(
                "source route {:?} is not an object",
                resolution.source_route
            ))
        })?;
    let manifest_id = route
        .get("manifest")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| Error::InvalidConfig("source route manifest is missing".into()))?;
    let source_manifest_url = config
        .sources
        .get("endpoints")
        .and_then(serde_json::Value::as_object)
        .and_then(|endpoints| endpoints.get(manifest_id))
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| {
            Error::InvalidConfig(format!(
                "source manifest endpoint {manifest_id:?} is missing"
            ))
        })?;
    let source_archive_name = route
        .get("archive_name")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| Error::InvalidConfig("source route archive_name is missing".into()))?;
    if source_archive_name.is_empty()
        || matches!(source_archive_name, "." | "..")
        || source_archive_name.contains(['/', '\\', ',', '\t', '\r', '\n'])
    {
        return Err(Error::InvalidConfig("source archive_name is unsafe".into()));
    }
    if !source_manifest_url.starts_with("https://")
        || source_manifest_url.chars().any(char::is_whitespace)
    {
        return Err(Error::InvalidConfig(
            "source manifest endpoint is unsafe".into(),
        ));
    }
    let (source_base, _) = source_manifest_url
        .rsplit_once('/')
        .ok_or_else(|| Error::InvalidConfig("source manifest endpoint has no filename".into()))?;
    let source_archive_url = format!("{source_base}/{source_archive_name}");
    let source_install_allowed = route
        .get("install_allowed")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(true);
    let fields = vec![
        ("schema", "1".to_owned()),
        ("platform_id", resolution.platform_id.clone()),
        (
            "platform_display_name",
            resolution.platform_display_name.clone(),
        ),
        ("device_class", resolution.device_class.clone()),
        ("target_confirmed", resolution.target_confirmed.to_string()),
        ("model_id", resolution.model_id.clone().unwrap_or_default()),
        ("source_route", resolution.source_route.clone()),
        ("frontend_management", frontend_management.to_owned()),
        ("frontend_kind", frontend_kind.to_owned()),
        ("frontend_names", frontend_names.join(",")),
        ("frontend_primary", frontend_primary.to_owned()),
        ("python_mode", python_mode.to_owned()),
        ("display_width", display_width),
        ("display_height", display_height),
        ("analog_sticks", analog_sticks),
        (
            "capability_install_portmaster",
            capability("install_portmaster"),
        ),
        (
            "capability_update_portmaster",
            capability("update_portmaster"),
        ),
        ("capability_repair_runtimes", capability("repair_runtimes")),
        ("capability_manage_ports", capability("manage_ports")),
        (
            "capability_manage_portmaster",
            capability("manage_portmaster"),
        ),
        ("capability_manage_frontend", capability("manage_frontend")),
        ("capability_manage_images", capability("manage_images")),
        ("capability_manage_artwork", capability("manage_artwork")),
        ("capability_trash", capability("trash")),
        ("capability_leftovers", capability("leftovers")),
        (
            "capability_cleanup_appledouble",
            capability("cleanup_appledouble"),
        ),
        ("source_manifest_url", source_manifest_url.to_owned()),
        ("source_archive_url", source_archive_url),
        ("source_archive_name", source_archive_name.to_owned()),
        ("source_install_allowed", source_install_allowed.to_string()),
        (
            "health_contract",
            portkit_core::health::HEALTH_CONTRACT.to_owned(),
        ),
        (
            "health_required",
            portkit_core::health::HEALTH_REQUIRED_KINDS.to_owned(),
        ),
        ("scripts", path("scripts")),
        ("launcher_directory", path("launcher_directory")),
        ("game_data", path("game_data")),
        ("portmaster_core", path("portmaster_core")),
        ("frontend", path("frontend")),
        ("images", path("images")),
    ];
    for (name, value) in &fields {
        if value.contains(['\t', '\r', '\n']) {
            return Err(Error::Resolution(format!(
                "TSV field {name:?} contains a line delimiter"
            )));
        }
    }
    Ok(fields)
}

fn required_integer(value: &serde_json::Value, name: &str, owner: &str) -> Result<String> {
    value
        .get(name)
        .and_then(serde_json::Value::as_u64)
        .map(|value| value.to_string())
        .ok_or_else(|| Error::InvalidConfig(format!("{owner}.{name} is not an unsigned integer")))
}

fn detection_context(options: &Options) -> Result<DetectionContext> {
    let launcher = options
        .one("launcher")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("PAM_LAUNCHER_PATH").map(PathBuf::from))
        .unwrap_or(std::env::current_exe()?);
    let mut context = DetectionContext::current(launcher);
    context.root = options.one("root").map(PathBuf::from);
    context.target_override = options.one("target-override").map(PathBuf::from);
    context.environment.extend(options.assignments("env")?);
    if let Some(path) = options.one("os-release") {
        context.os_release = parse_os_release(Path::new(path))?;
    } else if let Some(root) = &context.root {
        let fixture = root.join("etc/os-release");
        if fixture.is_file() {
            context.os_release = parse_os_release(&fixture)?;
        }
    }
    Ok(context)
}

fn parse_os_release(path: &Path) -> Result<BTreeMap<String, String>> {
    let contents = std::fs::read_to_string(path)?;
    Ok(contents
        .lines()
        .filter_map(|line| {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                return None;
            }
            let (name, value) = line.split_once('=')?;
            Some((name.into(), value.trim_matches(['\'', '"']).into()))
        })
        .collect())
}

fn split_assignment(value: &str) -> Result<(&str, &str)> {
    value
        .split_once('=')
        .ok_or_else(|| Error::InvalidConfig(format!("expected NAME=VALUE, got {value:?}")))
}

#[derive(Default)]
struct Options {
    values: BTreeMap<String, Vec<String>>,
}

impl Options {
    fn parse(arguments: &[String]) -> Result<Self> {
        let mut options = Self::default();
        let mut index = 0;
        while index < arguments.len() {
            let argument = &arguments[index];
            let Some(name) = argument.strip_prefix("--") else {
                return Err(Error::InvalidConfig(format!(
                    "unexpected argument {argument:?}"
                )));
            };
            if name == "clean" {
                options.values.entry(name.into()).or_default();
                index += 1;
                continue;
            }
            let value = arguments
                .get(index + 1)
                .ok_or_else(|| Error::InvalidConfig(format!("option --{name} requires a value")))?;
            if value.starts_with("--") {
                return Err(Error::InvalidConfig(format!(
                    "option --{name} requires a value"
                )));
            }
            options
                .values
                .entry(name.into())
                .or_default()
                .push(value.clone());
            index += 2;
        }
        Ok(options)
    }

    fn one(&self, name: &str) -> Option<&str> {
        self.values
            .get(name)
            .and_then(|values| values.last())
            .map(String::as_str)
    }
    fn many(&self, name: &str) -> impl Iterator<Item = &String> {
        self.values.get(name).into_iter().flatten()
    }
    fn flag(&self, name: &str) -> bool {
        self.values.contains_key(name)
    }
    fn assignments(&self, name: &str) -> Result<BTreeMap<String, String>> {
        self.many(name)
            .map(|value| {
                let (name, value) = split_assignment(value)?;
                Ok((name.into(), value.into()))
            })
            .collect()
    }
}

fn print_json(value: &impl Serialize) -> Result<()> {
    println!("{}", serde_json::to_string(value)?);
    Ok(())
}

fn usage() -> Error {
    Error::InvalidConfig(usage_text().into())
}
fn usage_text() -> &'static str {
    "usage: portkit config validate [--config FILE] [--config-dir DIR] [--remote-config FILE] [--remote-config-dir DIR] [--platform ID]\n       portkit config select-detail --config ROOT [--root DIR] [--launcher FILE] [--env NAME=VALUE] [--format json|tsv]\n       portkit config refresh --source URL --config FILE --config-dir DIR --cache FILE --cache-dir DIR --result FILE --launcher FILE [--root DIR] [--timeout-seconds 1..44]\n       portkit detect|resolve [--config FILE] [--config-dir DIR] [--remote-config FILE] [--remote-config-dir DIR] [--root DIR] [--launcher FILE] [--target-override DIR] [--env NAME=VALUE] [--format json|tsv]\n       portkit health [detection options] [--python-executable FILE] [--format json|tsv]\n       portkit env resolve [--scope NAME] [--var NAME=VALUE] [--set NAME=VALUE] [--unset NAME] [--clean]\n       portkit github candidates --capability NAME --source URL\n       portkit github fetch --capability NAME --source URL --output FILE [--batch-size 1..10] [--max-bytes N] [--validator nonempty|json|config-root] [--expected-sha256 HEX|--expected-md5 HEX] [--progress FILE] [--cancel-file FILE]\n       portkit file digest --algorithm md5|sha256 --input FILE [--format raw|json]\n       portkit file zip-readable --input FILE\n       portkit font provision [--candidate FILE] [--tar-xz FILE] [--zip FILE] --output FILE [--output FALLBACK] [--member FILE] [--format raw|json]"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tsv_frontend_fields_are_fixed_and_comma_unambiguous() {
        let loader = ConfigLoader::default();
        let config_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../config");
        let context = DetectionContext {
            root: None,
            launcher_path: "/unknown/ports/Test.sh".into(),
            environment: BTreeMap::new(),
            os_release: BTreeMap::new(),
            target_override: Some("/custom/PortMaster".into()),
        };
        let config = loader
            .load_for_context(
                EMBEDDED_ROOT,
                &LocalFragmentSource::new(config_dir),
                &context,
            )
            .unwrap();
        let mut context = DetectionContext::current("/unknown/ports/Test.sh");
        context.environment.clear();
        context.os_release.clear();
        context.target_override = Some("/custom/PortMaster".into());
        let mut resolution = config.detect_and_resolve(&loader, &context).unwrap();
        let fields = resolution_tsv_fields(&resolution, &config).unwrap();
        let field = |name: &str| {
            fields
                .iter()
                .find_map(|(field, value)| (*field == name).then_some(value.as_str()))
                .unwrap()
        };
        assert!(fields.contains(&("frontend_kind", "script-internal".into())));
        assert!(
            fields
                .iter()
                .any(|(name, value)| *name == "python_mode" && !value.is_empty())
        );
        assert!(fields.iter().any(|(name, _)| *name == "frontend_names"));
        assert_eq!(field("display_width"), "960");
        assert_eq!(field("display_height"), "720");
        assert_eq!(field("analog_sticks"), "2");
        assert_eq!(field("capability_install_portmaster"), "true");
        assert!(field("source_manifest_url").starts_with("https://"));
        assert!(field("source_archive_url").ends_with("/PortMaster.zip"));
        assert_eq!(field("source_archive_name"), "PortMaster.zip");
        assert_eq!(field("source_install_allowed"), "true");
        assert_eq!(field("health_contract"), "portkit.health.v1");

        resolution.frontend["names"] = serde_json::json!(["PortMaster,unsafe.sh"]);
        assert!(resolution_tsv_fields(&resolution, &config).is_err());
    }

    #[test]
    fn github_capability_is_required_and_checked() {
        let missing = Options::parse(&[]).unwrap();
        assert!(github_capability(&missing).is_err());
        let invalid = Options::parse(&["--capability".into(), "packages".into()]).unwrap();
        assert!(github_capability(&invalid).is_err());
        let valid = Options::parse(&["--capability".into(), "release".into()]).unwrap();
        assert_eq!(github_capability(&valid).unwrap(), Capability::Release);
    }
}
