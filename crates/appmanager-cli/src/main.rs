use std::collections::BTreeMap;
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use appmanager_core::{
    AppOwnedPaths, CacheGenerations, FileApplyRequest, InstallPlan, InstallRequest, Inventory,
    InventoryOptions, OperationKind, PendingValidationRequest, ResolvedContextInput,
    ResolvedDeviceContext, RuntimeMetadata, RuntimeRepairRequest, SizeScanRequest, apply_file_plan,
    install_portmaster, plan_contains_only_file_actions, repair_runtimes, scan_size_cache,
    validate_pending_install,
};
use clap::{Parser, Subcommand, ValueEnum};
use portkit_core::github::{Capability, GitHubTransport};
use portkit_core::{
    CandidateSelector, ConfigCandidate, ConfigLoader, ConfigOrigin, DetectionContext,
    DigestAlgorithm, ExclusiveFileLock, LocalFragmentSource, digest_file,
};
use serde::Serialize;
use serde_json::{Value, json};

const EMBEDDED_ROOT: &[u8] = include_bytes!("../../../config/config.json");

#[derive(Debug, Parser)]
#[command(name = "appmanager-cli", version, about)]
struct Cli {
    /// Directory containing the embedded root's platforms/ detail directory.
    #[arg(long, global = true)]
    config_dir: Option<PathBuf>,
    /// Directory containing details referenced by --remote-config.
    #[arg(long, global = true)]
    remote_config_dir: Option<PathBuf>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Clone, Debug)]
struct ConfigDirectories {
    embedded: Option<PathBuf>,
    remote: Option<PathBuf>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
enum OutputFormat {
    Json,
    Tsv,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Refresh the official Runtime JSON and canonical TSV caches.
    RefreshRuntimeMetadata {
        #[arg(long)]
        source: String,
        #[arg(long)]
        json_cache: PathBuf,
        #[arg(long)]
        tsv_cache: PathBuf,
        #[arg(long)]
        force: bool,
    },
    /// Read one Runtime entry from the canonical JSON metadata.
    RuntimeMetadataEntry {
        #[arg(long)]
        metadata: PathBuf,
        #[arg(long)]
        runtime: String,
        #[arg(long)]
        arch: String,
        /// When supplied, fail unless this image matches the metadata entry.
        #[arg(long)]
        image: Option<PathBuf>,
    },
    /// Download and resolve the stable PortMaster release asset.
    FetchStableRelease {
        #[arg(long)]
        source: String,
        #[arg(long)]
        archive_name: String,
        #[arg(long)]
        output: PathBuf,
    },
    /// Refresh the daily stable-version cache consumed by the UI.
    RefreshStableCache {
        #[arg(long)]
        source: String,
        #[arg(long)]
        cache: PathBuf,
        #[arg(long)]
        force: bool,
    },
    /// Enumerate direct children of managed roots without following symlinks.
    Inventory {
        /// PortKit resolution plus app-owned paths JSON, or `-` for stdin.
        #[arg(long)]
        context: PathBuf,
        /// Optional cache generation JSON file.
        #[arg(long)]
        cache_state: Option<PathBuf>,
        #[arg(long, value_enum, default_value_t = OutputFormat::Json)]
        format: OutputFormat,
        #[arg(long)]
        scan_script_images: bool,
        #[arg(long = "ignore-dir")]
        ignore_dirs: Vec<String>,
        #[arg(long = "ignore-script")]
        ignore_scripts: Vec<String>,
        #[arg(long)]
        self_port: Option<String>,
        #[arg(long, default_value = "")]
        directory: String,
        #[arg(long, default_value = "")]
        controlfolder: String,
        #[arg(long, default_value = "/root")]
        home: String,
    },
    /// Resolve the device and produce one reusable read-only inventory snapshot.
    DeviceInventory {
        #[arg(long)]
        launcher: PathBuf,
        #[arg(long)]
        app_state: PathBuf,
        #[arg(long)]
        trash: PathBuf,
        #[arg(long)]
        remote_config: Option<PathBuf>,
        #[arg(long)]
        target_override: Option<PathBuf>,
        #[arg(long)]
        root: Option<PathBuf>,
        #[arg(long = "env")]
        environment: Vec<String>,
        #[arg(long)]
        cache_state: Option<PathBuf>,
        #[arg(long, value_enum, default_value_t = OutputFormat::Json)]
        format: OutputFormat,
        #[arg(long)]
        scan_script_images: bool,
        #[arg(long = "ignore-dir")]
        ignore_dirs: Vec<String>,
        #[arg(long = "ignore-script")]
        ignore_scripts: Vec<String>,
        #[arg(long)]
        self_port: Option<String>,
        #[arg(long, default_value = "")]
        directory: String,
        #[arg(long, default_value = "")]
        controlfolder: String,
        #[arg(long, default_value = "/root")]
        home: String,
    },
    /// Validate a launcher-generated PortMaster install-plan TSV.
    ValidateInstallPlan {
        /// PortKit resolution plus app-owned paths JSON, or `-` for stdin.
        #[arg(long)]
        context: PathBuf,
        /// Install-plan TSV file. Cannot also be stdin when context is stdin.
        #[arg(long)]
        plan: PathBuf,
    },
    /// Resolve the device and validate an install plan in one read-only call.
    ValidateDeviceInstallPlan {
        #[arg(long)]
        plan: PathBuf,
        #[arg(long)]
        launcher: PathBuf,
        #[arg(long)]
        app_state: PathBuf,
        #[arg(long)]
        trash: PathBuf,
        #[arg(long)]
        remote_config: Option<PathBuf>,
        #[arg(long)]
        target_override: Option<PathBuf>,
        #[arg(long)]
        root: Option<PathBuf>,
        /// Add or replace one detection variable as a literal NAME=VALUE.
        #[arg(long = "env")]
        environment: Vec<String>,
    },
    /// Resolve the device and safely generate its PortMaster install plan.
    GenerateDeviceInstallPlan {
        #[arg(long)]
        launcher: PathBuf,
        #[arg(long)]
        app_state: PathBuf,
        #[arg(long)]
        trash: PathBuf,
        #[arg(long)]
        remote_config: Option<PathBuf>,
        #[arg(long)]
        target_override: Option<PathBuf>,
        #[arg(long)]
        root: Option<PathBuf>,
        #[arg(long = "env")]
        environment: Vec<String>,
        #[arg(long, value_enum, default_value_t = OutputFormat::Json)]
        format: OutputFormat,
    },
    /// Resolve the device and execute a rollback-safe PortMaster installation.
    InstallPortmaster {
        #[arg(long)]
        archive: PathBuf,
        #[arg(long)]
        launcher: PathBuf,
        #[arg(long)]
        app_state: PathBuf,
        #[arg(long)]
        trash: PathBuf,
        #[arg(long)]
        remote_config: Option<PathBuf>,
        #[arg(long)]
        target_override: Option<PathBuf>,
        #[arg(long)]
        root: Option<PathBuf>,
        #[arg(long = "env")]
        environment: Vec<String>,
        #[arg(long)]
        cancel_file: Option<PathBuf>,
    },
    /// Validate or roll back the PortMaster transaction left by installation.
    ValidatePendingInstall {
        #[arg(long)]
        launcher: PathBuf,
        #[arg(long)]
        app_state: PathBuf,
        #[arg(long)]
        trash: PathBuf,
        #[arg(long)]
        remote_config: Option<PathBuf>,
        #[arg(long)]
        target_override: Option<PathBuf>,
        #[arg(long)]
        root: Option<PathBuf>,
        #[arg(long = "env")]
        environment: Vec<String>,
        /// Config-derived health status: healthy, damaged, or missing.
        #[arg(long)]
        core_health: String,
        #[arg(long, hide = true)]
        test_interrupt_before_mutation: bool,
        #[arg(long, hide = true)]
        test_fail_restore_after: Option<usize>,
    },
    /// Repair official PortMaster Runtime images with strict validation.
    RepairRuntimes {
        /// Official PortMaster `ports.json` metadata file.
        #[arg(long)]
        metadata: PathBuf,
        /// Runtime name without the `.squashfs` suffix. May be repeated.
        #[arg(long = "runtime", required = true)]
        runtimes: Vec<String>,
        /// Runtime architecture from official metadata.
        #[arg(long)]
        arch: String,
        /// PortMaster libs directory containing Runtime squashfs images.
        #[arg(long)]
        libs_root: PathBuf,
        /// UI-compatible Runtime progress TSV file.
        #[arg(long)]
        progress: PathBuf,
        /// Optional presence-based cancellation file.
        #[arg(long)]
        cancel_file: Option<PathBuf>,
    },
    /// Apply a game-management file plan inside config-resolved managed roots.
    ApplyFilePlan {
        #[arg(long)]
        plan: PathBuf,
        #[arg(long)]
        result: PathBuf,
        #[arg(long)]
        size_cache: Option<PathBuf>,
        #[arg(long)]
        progress: Option<PathBuf>,
        #[arg(long)]
        self_launcher: PathBuf,
        #[arg(long)]
        self_port: String,
        /// Optional sudo/doas-style command used only when a validated mutation needs elevation.
        #[arg(long)]
        privilege_command: Option<PathBuf>,
        /// Argument passed to the privilege command before the validated filesystem command.
        #[arg(long = "privilege-arg", requires = "privilege_command")]
        privilege_arguments: Vec<String>,
        #[arg(long)]
        launcher: PathBuf,
        #[arg(long)]
        app_state: PathBuf,
        #[arg(long)]
        trash: PathBuf,
        #[arg(long)]
        remote_config: Option<PathBuf>,
        #[arg(long)]
        target_override: Option<PathBuf>,
        #[arg(long)]
        root: Option<PathBuf>,
        #[arg(long = "env")]
        environment: Vec<String>,
    },
    /// Rebuild the allocated-size cache for managed Port items.
    ScanDeviceSizes {
        #[arg(long)]
        output: PathBuf,
        #[arg(long)]
        self_port: String,
        #[arg(long)]
        launcher: PathBuf,
        #[arg(long)]
        app_state: PathBuf,
        #[arg(long)]
        trash: PathBuf,
        #[arg(long)]
        remote_config: Option<PathBuf>,
        #[arg(long)]
        target_override: Option<PathBuf>,
        #[arg(long)]
        root: Option<PathBuf>,
        #[arg(long = "env")]
        environment: Vec<String>,
    },
    /// Calculate the next cache generations; does not modify any file.
    CacheInvalidate {
        /// PortKit resolution plus app-owned paths JSON, or `-` for stdin.
        #[arg(long)]
        context: PathBuf,
        /// Operation plan JSON file containing `["TRASH", ...]`.
        #[arg(long)]
        operations: PathBuf,
        /// Optional current cache generation JSON file.
        #[arg(long)]
        cache_state: Option<PathBuf>,
    },
}

#[derive(Debug, Serialize)]
struct Envelope<T: Serialize> {
    ok: bool,
    command: &'static str,
    data: Option<T>,
    error: Option<ErrorBody>,
}

#[derive(Debug, Serialize)]
struct ErrorBody {
    code: &'static str,
    message: String,
}

fn main() -> ExitCode {
    let cli = match Cli::try_parse() {
        Ok(cli) => cli,
        Err(error) => {
            print_json(&Envelope::<Value> {
                ok: false,
                command: "cli",
                data: None,
                error: Some(ErrorBody {
                    code: "invalid-arguments",
                    message: error.to_string(),
                }),
            });
            return ExitCode::from(2);
        }
    };
    let raw_tsv = matches!(
        &cli.command,
        Command::GenerateDeviceInstallPlan {
            format: OutputFormat::Tsv,
            ..
        } | Command::Inventory {
            format: OutputFormat::Tsv,
            ..
        } | Command::DeviceInventory {
            format: OutputFormat::Tsv,
            ..
        } | Command::RuntimeMetadataEntry { .. }
    );
    let config_directories = ConfigDirectories {
        embedded: cli.config_dir,
        remote: cli.remote_config_dir,
    };
    match run(cli.command, &config_directories) {
        Ok((command, data)) => {
            if raw_tsv {
                if let Some(tsv) = data.get("tsv").and_then(Value::as_str) {
                    print!("{tsv}");
                } else {
                    print_json(&Envelope::<Value> {
                        ok: false,
                        command,
                        data: None,
                        error: Some(ErrorBody {
                            code: "serialization",
                            message: "generated TSV is missing".to_owned(),
                        }),
                    });
                    return ExitCode::from(2);
                }
            } else {
                print_json(&Envelope {
                    ok: true,
                    command,
                    data: Some(data),
                    error: None,
                });
            }
            ExitCode::SUCCESS
        }
        Err(error) => {
            print_json(&Envelope::<Value> {
                ok: false,
                command: error.command,
                data: None,
                error: Some(ErrorBody {
                    code: error.code,
                    message: error.message,
                }),
            });
            ExitCode::from(2)
        }
    }
}

#[derive(Debug)]
struct CliError {
    command: &'static str,
    code: &'static str,
    message: String,
}

fn run(
    command: Command,
    config_directories: &ConfigDirectories,
) -> Result<(&'static str, Value), CliError> {
    match command {
        Command::RefreshRuntimeMetadata {
            source,
            json_cache,
            tsv_cache,
            force,
        } => refresh_runtime_metadata(source, json_cache, tsv_cache, force),
        Command::RuntimeMetadataEntry {
            metadata,
            runtime,
            arch,
            image,
        } => runtime_metadata_entry(metadata, runtime, arch, image),
        Command::FetchStableRelease {
            source,
            archive_name,
            output,
        } => fetch_stable_release(source, archive_name, output),
        Command::RefreshStableCache {
            source,
            cache,
            force,
        } => refresh_stable_cache(source, cache, force),
        Command::Inventory {
            context,
            cache_state,
            format,
            scan_script_images,
            ignore_dirs,
            ignore_scripts,
            self_port,
            directory,
            controlfolder,
            home,
        } => {
            let name = "inventory";
            if cache_state.as_deref() == Some(Path::new("-")) && context == Path::new("-") {
                return Err(CliError {
                    command: name,
                    code: "ambiguous-stdin",
                    message: "stdin can supply only one input".to_owned(),
                });
            }
            let context = read_context(name, &context)?;
            let generations = match cache_state {
                Some(path) => read_json(name, &path, "invalid-cache-state")?,
                None => CacheGenerations::default(),
            };
            let options = inventory_options(
                scan_script_images,
                ignore_dirs,
                ignore_scripts,
                self_port,
                directory,
                controlfolder,
                home,
            );
            let inventory = Inventory::scan_with_options(&context, generations, &options)
                .map_err(|error| domain_error(name, "inventory-rejected", error))?;
            match format {
                OutputFormat::Json => Ok((name, json!(inventory))),
                OutputFormat::Tsv => Ok((name, json!({"tsv": inventory.to_tsv()}))),
            }
        }
        Command::ValidateInstallPlan { context, plan } => {
            let name = "validate-install-plan";
            reject_double_stdin(name, &context, &plan)?;
            let context = read_context(name, &context)?;
            let bytes = read_bytes(name, &plan, "invalid-plan")?;
            let plan = InstallPlan::parse_tsv(&bytes)
                .map_err(|error| domain_error(name, "invalid-plan", error))?;
            let validated = plan
                .validate(&context)
                .map_err(|error| domain_error(name, "plan-rejected", error))?;
            Ok((name, json!(validated)))
        }
        Command::DeviceInventory {
            launcher,
            app_state,
            trash,
            remote_config,
            target_override,
            root,
            environment,
            cache_state,
            format,
            scan_script_images,
            ignore_dirs,
            ignore_scripts,
            self_port,
            directory,
            controlfolder,
            home,
        } => device_inventory(
            launcher,
            app_state,
            trash,
            remote_config,
            target_override,
            root,
            environment,
            cache_state,
            format,
            inventory_options(
                scan_script_images,
                ignore_dirs,
                ignore_scripts,
                self_port,
                directory,
                controlfolder,
                home,
            ),
            config_directories,
        ),
        Command::ValidateDeviceInstallPlan {
            plan,
            launcher,
            app_state,
            trash,
            remote_config,
            target_override,
            root,
            environment,
        } => validate_device_install_plan(
            plan,
            launcher,
            app_state,
            trash,
            remote_config,
            target_override,
            root,
            environment,
            config_directories,
        ),
        Command::GenerateDeviceInstallPlan {
            launcher,
            app_state,
            trash,
            remote_config,
            target_override,
            root,
            environment,
            format: _,
        } => generate_device_install_plan(
            launcher,
            app_state,
            trash,
            remote_config,
            target_override,
            root,
            environment,
            config_directories,
        ),
        Command::InstallPortmaster {
            archive,
            launcher,
            app_state,
            trash,
            remote_config,
            target_override,
            root,
            environment,
            cancel_file,
        } => install_device_portmaster(
            archive,
            launcher,
            app_state,
            trash,
            remote_config,
            target_override,
            root,
            environment,
            cancel_file,
            config_directories,
        ),
        Command::ValidatePendingInstall {
            launcher,
            app_state,
            trash,
            remote_config,
            target_override,
            root,
            environment,
            core_health,
            test_interrupt_before_mutation,
            test_fail_restore_after,
        } => validate_device_pending_install(
            launcher,
            app_state,
            trash,
            remote_config,
            target_override,
            root,
            environment,
            core_health,
            test_interrupt_before_mutation,
            test_fail_restore_after,
            config_directories,
        ),
        Command::RepairRuntimes {
            metadata,
            runtimes,
            arch,
            libs_root,
            progress,
            cancel_file,
        } => {
            let name = "repair-runtimes";
            let metadata = read_bytes(name, &metadata, "invalid-runtime-metadata")?;
            let outcome = repair_runtimes(&RuntimeRepairRequest {
                metadata,
                runtime_names: runtimes,
                arch,
                libs_root,
                progress_file: progress,
                cancel_file,
            })
            .map_err(|error| domain_error(name, "runtime-repair-failed", error))?;
            Ok((name, json!(outcome)))
        }
        Command::ApplyFilePlan {
            plan,
            result,
            size_cache,
            progress,
            self_launcher,
            self_port,
            privilege_command,
            privilege_arguments,
            launcher,
            app_state,
            trash,
            remote_config,
            target_override,
            root,
            environment,
        } => {
            let name = "apply-file-plan";
            if !plan_contains_only_file_actions(&plan)
                .map_err(|error| domain_error(name, "invalid-file-plan", error))?
            {
                return Err(CliError {
                    command: name,
                    code: "mixed-operation-plan",
                    message: "file-plan execution does not accept network operations".to_owned(),
                });
            }
            let resolved = resolve_device_context(
                name,
                launcher,
                app_state,
                trash,
                remote_config,
                target_override,
                root,
                environment,
                config_directories,
            )?;
            let outcome = apply_file_plan(&FileApplyRequest {
                context: &resolved.context,
                plan: &plan,
                result: &result,
                size_cache: size_cache.as_deref(),
                self_launcher: &self_launcher,
                self_port: &self_port,
                privilege_command: privilege_command.as_deref(),
                privilege_arguments: &privilege_arguments,
                progress_file: progress.as_deref(),
            })
            .map_err(|error| domain_error(name, "file-operation-failed", error))?;
            Ok((
                name,
                json!({
                    "config_origin": resolved.config_origin,
                    "platform_id": resolved.context.profile,
                    "model_id": resolved.model_id,
                    "operations": outcome,
                }),
            ))
        }
        Command::ScanDeviceSizes {
            output,
            self_port,
            launcher,
            app_state,
            trash,
            remote_config,
            target_override,
            root,
            environment,
        } => {
            let name = "scan-device-sizes";
            let resolved = resolve_device_context(
                name,
                launcher,
                app_state,
                trash,
                remote_config,
                target_override,
                root,
                environment,
                config_directories,
            )?;
            let outcome = scan_size_cache(&SizeScanRequest {
                context: &resolved.context,
                output: &output,
                self_port: &self_port,
            })
            .map_err(|error| domain_error(name, "size-scan-failed", error))?;
            Ok((
                name,
                json!({
                    "config_origin": resolved.config_origin,
                    "platform_id": resolved.context.profile,
                    "model_id": resolved.model_id,
                    "scan": outcome,
                }),
            ))
        }
        Command::CacheInvalidate {
            context,
            operations,
            cache_state,
        } => {
            let name = "cache-invalidate";
            reject_double_stdin(name, &context, &operations)?;
            if cache_state.as_deref() == Some(Path::new("-"))
                && (context == Path::new("-") || operations == Path::new("-"))
            {
                return Err(CliError {
                    command: name,
                    code: "ambiguous-stdin",
                    message: "stdin can supply only one input".to_owned(),
                });
            }
            let context = read_context(name, &context)?;
            let operation_names: Vec<String> = read_json(name, &operations, "invalid-operations")?;
            let operations: Vec<_> = operation_names
                .iter()
                .map(|value| OperationKind::parse(value))
                .collect();
            let generations = match cache_state {
                Some(path) => read_json(name, &path, "invalid-cache-state")?,
                None => CacheGenerations::default(),
            };
            generations
                .validate()
                .map_err(|error| domain_error(name, "invalid-cache-state", error))?;
            let result =
                generations.invalidate(context.capabilities.cache_invalidation, &operations);
            Ok((name, json!(result)))
        }
    }
}

#[derive(Debug, serde::Deserialize, Serialize)]
struct StableRelease {
    version: String,
    url: String,
    md5: String,
}

#[derive(Debug, serde::Deserialize)]
struct StableManifest {
    stable: StableRelease,
}

fn parse_stable_manifest(command: &'static str, bytes: &[u8]) -> Result<StableRelease, CliError> {
    let manifest: StableManifest = serde_json::from_slice(bytes).map_err(|error| CliError {
        command,
        code: "invalid-stable-manifest",
        message: error.to_string(),
    })?;
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
            return Err(CliError {
                command,
                code: "invalid-stable-manifest",
                message: format!("stable {field} is empty or contains a control separator"),
            });
        }
    }
    if !stable
        .version
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        return Err(CliError {
            command,
            code: "invalid-stable-manifest",
            message: "stable version contains unsupported characters".to_owned(),
        });
    }
    if stable.md5.len() != 32 || !stable.md5.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(CliError {
            command,
            code: "invalid-stable-manifest",
            message: "stable md5 is not a 32-character hexadecimal digest".to_owned(),
        });
    }
    let Some(release_path) = stable.url.strip_prefix("https://github.com/") else {
        return Err(CliError {
            command,
            code: "invalid-stable-manifest",
            message: "stable URL is not a GitHub HTTPS release asset".to_owned(),
        });
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
        return Err(CliError {
            command,
            code: "invalid-stable-manifest",
            message: "stable URL is not a GitHub release asset".to_owned(),
        });
    }
    stable.md5.make_ascii_lowercase();
    Ok(stable)
}

fn fetch_stable_release(
    source: String,
    archive_name: String,
    output: PathBuf,
) -> Result<(&'static str, Value), CliError> {
    const NAME: &str = "fetch-stable-release";
    let parent = output.parent().ok_or_else(|| CliError {
        command: NAME,
        code: "invalid-stable-output",
        message: "stable release output has no parent directory".to_owned(),
    })?;
    fs::create_dir_all(parent)
        .map_err(|error| domain_error(NAME, "stable-release-write-failed", error))?;
    let manifest = parent.join(format!(
        ".stable-release-manifest-{}.json",
        std::process::id()
    ));
    let _download = DownloadGuard(manifest.clone());
    let outcome = GitHubTransport::new()
        .fetch(
            Capability::Release,
            &source,
            &manifest,
            |path| {
                fs::read(path)
                    .ok()
                    .and_then(|bytes| parse_stable_manifest(NAME, &bytes).ok())
                    .is_some()
            },
            None,
            None,
        )
        .map_err(|error| domain_error(NAME, "stable-manifest-download-failed", error))?;
    let bytes = read_bytes(NAME, &manifest, "invalid-stable-manifest")?;
    let stable = parse_stable_manifest(NAME, &bytes)?;
    validate_stable_release_route(&source, &archive_name, &stable)?;
    let row = format!("{}\t{}\t{}\n", stable.version, stable.url, stable.md5);
    atomic_write(&output, row.as_bytes(), NAME, "stable-release-write-failed")?;
    Ok((
        NAME,
        json!({
            "version": stable.version,
            "url": stable.url,
            "md5": stable.md5,
            "route": outcome.route_id(),
            "output": output,
        }),
    ))
}

fn validate_stable_release_route(
    source: &str,
    archive_name: &str,
    stable: &StableRelease,
) -> Result<(), CliError> {
    const NAME: &str = "fetch-stable-release";
    if archive_name.is_empty()
        || matches!(archive_name, "." | "..")
        || archive_name.contains(['/', '\\', '\t', '\r', '\n'])
    {
        return Err(CliError {
            command: NAME,
            code: "invalid-stable-release",
            message: "stable archive name is unsafe".to_owned(),
        });
    }
    let repository = source
        .strip_suffix("/releases/latest/download/version.json")
        .filter(|base| base.starts_with("https://github.com/"))
        .ok_or_else(|| CliError {
            command: NAME,
            code: "invalid-stable-release",
            message: "stable manifest URL is not a GitHub latest-release asset".to_owned(),
        })?;
    let expected = format!(
        "{repository}/releases/download/{}/{}",
        stable.version, archive_name
    );
    if stable.url != expected {
        return Err(CliError {
            command: NAME,
            code: "invalid-stable-release",
            message: "stable archive does not match its manifest repository, version, or name"
                .to_owned(),
        });
    }
    Ok(())
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

fn refresh_stable_cache(
    source: String,
    cache: PathBuf,
    force: bool,
) -> Result<(&'static str, Value), CliError> {
    const NAME: &str = "refresh-stable-cache";
    if !force && update_cache_is_fresh(&cache) && stable_cache_row_valid(&cache) {
        return Ok((NAME, json!({"status": "cached", "cache": cache})));
    }
    let parent = cache.parent().ok_or_else(|| CliError {
        command: NAME,
        code: "invalid-update-cache",
        message: "update cache has no parent directory".to_owned(),
    })?;
    fs::create_dir_all(parent)
        .map_err(|error| domain_error(NAME, "update-cache-write-failed", error))?;
    let manifest = parent.join(format!(".stable-manifest-{}.json", std::process::id()));
    let _download = DownloadGuard(manifest.clone());
    let fetch = GitHubTransport::new().fetch(
        Capability::Release,
        &source,
        &manifest,
        |path| {
            fs::read(path)
                .ok()
                .and_then(|bytes| parse_stable_manifest(NAME, &bytes).ok())
                .is_some()
        },
        None,
        None,
    );
    let checked = epoch_seconds();
    match fetch {
        Ok(outcome) => {
            let bytes = read_bytes(NAME, &manifest, "invalid-stable-manifest")?;
            let stable = parse_stable_manifest(NAME, &bytes)?;
            write_update_cache(&cache, checked, "ok", &stable.version)?;
            Ok((
                NAME,
                json!({
                    "status": "ok",
                    "latest": stable.version,
                    "route": outcome.route_id(),
                    "cache": cache,
                }),
            ))
        }
        Err(error) => {
            let _ = write_update_cache(&cache, checked, "error", "");
            Err(domain_error(NAME, "stable-manifest-download-failed", error))
        }
    }
}

fn refresh_runtime_metadata(
    source: String,
    json_cache: PathBuf,
    tsv_cache: PathBuf,
    force: bool,
) -> Result<(&'static str, Value), CliError> {
    const NAME: &str = "refresh-runtime-metadata";
    if !force
        && update_cache_is_fresh(&json_cache)
        && runtime_tsv_matches_json(&json_cache, &tsv_cache)
    {
        return Ok((NAME, json!({"status": "cached"})));
    }
    let parent = json_cache.parent().ok_or_else(|| CliError {
        command: NAME,
        code: "invalid-runtime-cache",
        message: "Runtime JSON cache has no parent directory".to_owned(),
    })?;
    fs::create_dir_all(parent)
        .map_err(|error| domain_error(NAME, "runtime-cache-write-failed", error))?;
    let _refresh_lock =
        ExclusiveFileLock::try_acquire(&parent.join(".runtime-metadata-refresh.lock"))
            .map_err(|error| domain_error(NAME, "cache-refresh-running", error))?;
    if repair_runtime_tsv_from_json(&json_cache, &tsv_cache)?
        && !force
        && update_cache_is_fresh(&json_cache)
    {
        return Ok((NAME, json!({"status": "cached"})));
    }
    let download = parent.join(format!(".runtime-metadata-{}.json", std::process::id()));
    let _download = DownloadGuard(download.clone());
    let fetched = GitHubTransport::new().fetch(
        Capability::Release,
        &source,
        &download,
        |path| {
            fs::read(path)
                .ok()
                .and_then(|bytes| RuntimeMetadata::parse(&bytes).ok())
                .is_some()
        },
        None,
        None,
    );
    let outcome = match fetched {
        Ok(outcome) => outcome,
        Err(_) if !force && repair_runtime_tsv_from_json(&json_cache, &tsv_cache)? => {
            return Ok((NAME, json!({"status": "cached-stale"})));
        }
        Err(error) => {
            return Err(domain_error(
                NAME,
                "runtime-metadata-download-failed",
                error,
            ));
        }
    };
    let bytes = read_bytes(NAME, &download, "invalid-runtime-metadata")?;
    let metadata = RuntimeMetadata::parse(&bytes)
        .map_err(|error| domain_error(NAME, "invalid-runtime-metadata", error))?;
    atomic_write(&json_cache, &bytes, NAME, "runtime-cache-write-failed")?;
    atomic_write(
        &tsv_cache,
        metadata.to_tsv().as_bytes(),
        NAME,
        "runtime-cache-write-failed",
    )?;
    Ok((
        NAME,
        json!({"status": "updated", "route": outcome.route_id()}),
    ))
}

fn runtime_tsv_matches_json(json_cache: &Path, tsv_cache: &Path) -> bool {
    fs::read(json_cache)
        .ok()
        .and_then(|json| RuntimeMetadata::parse(&json).ok())
        .is_some_and(|metadata| {
            fs::read(tsv_cache).is_ok_and(|tsv| tsv == metadata.to_tsv().as_bytes())
        })
}

fn repair_runtime_tsv_from_json(json_cache: &Path, tsv_cache: &Path) -> Result<bool, CliError> {
    const NAME: &str = "refresh-runtime-metadata";
    let Ok(json) = fs::read(json_cache) else {
        return Ok(false);
    };
    let Ok(metadata) = RuntimeMetadata::parse(&json) else {
        return Ok(false);
    };
    let canonical = metadata.to_tsv();
    if !fs::read(tsv_cache).is_ok_and(|tsv| tsv == canonical.as_bytes()) {
        atomic_write(
            tsv_cache,
            canonical.as_bytes(),
            NAME,
            "runtime-cache-write-failed",
        )?;
    }
    Ok(true)
}

fn runtime_metadata_entry(
    metadata: PathBuf,
    runtime: String,
    arch: String,
    image: Option<PathBuf>,
) -> Result<(&'static str, Value), CliError> {
    const NAME: &str = "runtime-metadata-entry";
    let bytes = read_bytes(NAME, &metadata, "invalid-runtime-metadata")?;
    let metadata = RuntimeMetadata::parse(&bytes)
        .map_err(|error| domain_error(NAME, "invalid-runtime-metadata", error))?;
    let entry = metadata.get(&runtime, &arch).ok_or_else(|| CliError {
        command: NAME,
        code: "runtime-metadata-missing",
        message: format!("Runtime metadata has no {runtime} entry for {arch}"),
    })?;
    if let Some(image) = image {
        let valid = image
            .metadata()
            .is_ok_and(|metadata| metadata.len() == entry.size)
            && fs::File::open(&image)
                .and_then(|mut file| {
                    let mut magic = [0_u8; 4];
                    file.read_exact(&mut magic)?;
                    Ok(magic == *b"hsqs")
                })
                .unwrap_or(false)
            && digest_file(&image, DigestAlgorithm::Md5).is_ok_and(|digest| digest == entry.md5);
        if !valid {
            return Err(CliError {
                command: NAME,
                code: "runtime-image-mismatch",
                message: "Runtime image does not match official metadata".to_owned(),
            });
        }
    }
    Ok((
        NAME,
        json!({"tsv": format!("{}\t{}\t{}\t{}\t{}\n", entry.name, entry.arch, entry.size, entry.md5, entry.url)}),
    ))
}

fn update_cache_is_fresh(path: &Path) -> bool {
    path.metadata()
        .ok()
        .and_then(|metadata| metadata.modified().ok())
        .and_then(|modified| modified.elapsed().ok())
        .is_some_and(|age| age < Duration::from_secs(24 * 60 * 60))
}

fn stable_cache_row_valid(path: &Path) -> bool {
    let Ok(row) = fs::read_to_string(path) else {
        return false;
    };
    let Some(row) = row.strip_suffix('\n') else {
        return false;
    };
    if row.contains(['\n', '\r']) {
        return false;
    }
    let fields = row.split('\t').collect::<Vec<_>>();
    if fields.len() != 3 || fields[0].parse::<u64>().is_err() {
        return false;
    }
    match fields[1] {
        "ok" => {
            !fields[2].is_empty()
                && fields[2]
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        }
        "error" => fields[2].is_empty(),
        _ => false,
    }
}

fn epoch_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn write_update_cache(
    path: &Path,
    checked: u64,
    status: &str,
    latest: &str,
) -> Result<(), CliError> {
    const NAME: &str = "refresh-stable-cache";
    atomic_write(
        path,
        format!("{checked}\t{status}\t{latest}\n").as_bytes(),
        NAME,
        "update-cache-write-failed",
    )
}

fn atomic_write(
    path: &Path,
    bytes: &[u8],
    command: &'static str,
    code: &'static str,
) -> Result<(), CliError> {
    let parent = path.parent().ok_or_else(|| CliError {
        command,
        code,
        message: "output path has no parent directory".to_owned(),
    })?;
    fs::create_dir_all(parent).map_err(|error| domain_error(command, code, error))?;
    for counter in 0_u16..1000 {
        let temporary = parent.join(format!(
            ".appmanager-native-{}-{counter}.tmp",
            std::process::id()
        ));
        let mut file = match fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
        {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(domain_error(command, code, error)),
        };
        let result = (|| -> io::Result<()> {
            file.write_all(bytes)?;
            file.sync_all()?;
            drop(file);
            fs::rename(&temporary, path)
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        return result.map_err(|error| domain_error(command, code, error));
    }
    Err(CliError {
        command,
        code,
        message: "unable to allocate output temporary file".to_owned(),
    })
}

#[allow(clippy::too_many_arguments)]
fn inventory_options(
    scan_script_images: bool,
    ignore_dirs: Vec<String>,
    ignore_scripts: Vec<String>,
    self_port: Option<String>,
    directory: String,
    controlfolder: String,
    home: String,
) -> InventoryOptions {
    InventoryOptions {
        scan_script_images,
        ignore_dirs: ignore_dirs.into_iter().collect(),
        ignore_scripts: ignore_scripts.into_iter().collect(),
        self_port,
        directory,
        controlfolder,
        home,
    }
}

#[allow(clippy::too_many_arguments)]
fn device_inventory(
    launcher: PathBuf,
    app_state: PathBuf,
    trash: PathBuf,
    remote_config: Option<PathBuf>,
    target_override: Option<PathBuf>,
    root: Option<PathBuf>,
    environment: Vec<String>,
    cache_state: Option<PathBuf>,
    format: OutputFormat,
    options: InventoryOptions,
    config_directories: &ConfigDirectories,
) -> Result<(&'static str, Value), CliError> {
    let name = "device-inventory";
    let resolved = resolve_device_context(
        name,
        launcher,
        app_state,
        trash,
        remote_config,
        target_override,
        root,
        environment,
        config_directories,
    )?;
    let generations = match cache_state {
        Some(path) => read_json(name, &path, "invalid-cache-state")?,
        None => CacheGenerations::default(),
    };
    let inventory = Inventory::scan_with_options(&resolved.context, generations, &options)
        .map_err(|error| domain_error(name, "inventory-rejected", error))?;
    match format {
        OutputFormat::Json => Ok((name, json!(inventory))),
        OutputFormat::Tsv => Ok((name, json!({"tsv": inventory.to_tsv()}))),
    }
}

#[allow(clippy::too_many_arguments)]
fn install_device_portmaster(
    archive: PathBuf,
    launcher: PathBuf,
    app_state: PathBuf,
    trash: PathBuf,
    remote_config: Option<PathBuf>,
    target_override: Option<PathBuf>,
    root: Option<PathBuf>,
    environment: Vec<String>,
    cancel_file: Option<PathBuf>,
    config_directories: &ConfigDirectories,
) -> Result<(&'static str, Value), CliError> {
    let name = "install-portmaster";
    let resolved = resolve_device_context(
        name,
        launcher.clone(),
        app_state.clone(),
        trash.clone(),
        remote_config,
        target_override,
        root.clone(),
        environment,
        config_directories,
    )?;
    let plan = InstallPlan::from_context(&resolved.context)
        .map_err(|error| domain_error(name, "install-rejected", error))?;
    let plan = plan
        .validate(&resolved.context)
        .map_err(|error| domain_error(name, "install-rejected", error))?;
    let outcome = install_portmaster(&InstallRequest {
        archive,
        launcher,
        state_dir: app_state,
        trash_dir: trash,
        cancel_file,
        probe_root: root,
        plan,
        fail_after_backup: false,
        fail_restore_after: None,
    })
    .map_err(|error| domain_error(name, "install-failed", error))?;
    Ok((
        name,
        json!({
            "config_origin": resolved.config_origin,
            "platform_id": resolved.context.profile,
            "model_id": resolved.model_id,
            "device_class": resolved.context.device_class,
            "target_confirmed": resolved.context.target_confirmed,
            "installation": outcome,
        }),
    ))
}

#[allow(clippy::too_many_arguments)]
fn validate_device_pending_install(
    launcher: PathBuf,
    app_state: PathBuf,
    trash: PathBuf,
    remote_config: Option<PathBuf>,
    target_override: Option<PathBuf>,
    root: Option<PathBuf>,
    environment: Vec<String>,
    core_health: String,
    test_interrupt_before_mutation: bool,
    test_fail_restore_after: Option<usize>,
    config_directories: &ConfigDirectories,
) -> Result<(&'static str, Value), CliError> {
    let name = "validate-pending-install";
    if !matches!(core_health.as_str(), "healthy" | "damaged" | "missing") {
        return Err(CliError {
            command: name,
            code: "invalid-core-health",
            message: "core health must be healthy, damaged, or missing".to_owned(),
        });
    }
    let resolved = resolve_device_context(
        name,
        launcher,
        app_state.clone(),
        trash,
        remote_config,
        target_override,
        root,
        environment,
        config_directories,
    )?;
    let plan = InstallPlan::from_context(&resolved.context)
        .map_err(|error| domain_error(name, "validation-rejected", error))?
        .validate(&resolved.context)
        .map_err(|error| domain_error(name, "validation-rejected", error))?;
    let outcome = validate_pending_install(&PendingValidationRequest {
        state_dir: app_state,
        plan,
        core_health_healthy: core_health == "healthy",
        interrupt_before_mutation: test_interrupt_before_mutation,
        fail_restore_after: test_fail_restore_after,
    })
    .map_err(|error| domain_error(name, "validation-failed", error))?;
    Ok((
        name,
        json!({
            "config_origin": resolved.config_origin,
            "platform_id": resolved.context.profile,
            "model_id": resolved.model_id,
            "validation": outcome,
        }),
    ))
}

struct DeviceResolution {
    config_origin: ConfigOrigin,
    model_id: Option<String>,
    context: ResolvedDeviceContext,
}

#[allow(clippy::too_many_arguments)]
fn resolve_device_context(
    command: &'static str,
    launcher: PathBuf,
    app_state: PathBuf,
    trash: PathBuf,
    remote_config: Option<PathBuf>,
    target_override: Option<PathBuf>,
    root: Option<PathBuf>,
    environment: Vec<String>,
    config_directories: &ConfigDirectories,
) -> Result<DeviceResolution, CliError> {
    let environment = parse_assignments(command, &environment)?;
    let mut detection = DetectionContext::current(launcher);
    detection.root = root;
    detection.target_override = target_override;
    detection.environment.extend(environment);
    if let Some(root) = &detection.root {
        let os_release = root.join("etc/os-release");
        if os_release.is_file() {
            let bytes = read_bytes(command, &os_release, "invalid-os-release")?;
            detection.os_release = parse_os_release(command, &bytes)?;
        }
    }

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
    let remote_dir = remote_config.as_ref().map(|path| {
        config_directories
            .remote
            .clone()
            .unwrap_or_else(|| path.parent().unwrap_or(Path::new(".")).to_path_buf())
    });
    // A remote config is only an optional cache. Failure to read it must use
    // the embedded contract, not turn a removable-media race into a startup
    // failure.
    let remote = remote_config
        .as_ref()
        .and_then(|path| std::fs::read(path).ok())
        .map(ConfigCandidate::remote);
    let embedded_details = LocalFragmentSource::new(embedded_dir);
    let remote_details = remote_dir.map(LocalFragmentSource::new);
    let remote = remote.zip(
        remote_details
            .as_ref()
            .map(|source| source as &dyn portkit_core::FragmentSource),
    );
    let selected = CandidateSelector {
        loader: ConfigLoader::default(),
    }
    .select_root_for_context(
        ConfigCandidate::embedded(EMBEDDED_ROOT),
        &embedded_details,
        remote,
        &detection,
    )
    .map_err(|error| domain_error(command, "device-resolution-failed", error))?;
    let config_origin = selected.selected.origin;
    let model_id = selected.resolution.model_id.clone();
    let input = ResolvedContextInput {
        resolution: selected.resolution,
        app_owned: AppOwnedPaths {
            state: app_state,
            trash,
        },
    };
    let context = ResolvedDeviceContext::try_from(input)
        .map_err(|error| domain_error(command, "invalid-context", error))?;
    Ok(DeviceResolution {
        config_origin,
        model_id,
        context,
    })
}

#[allow(clippy::too_many_arguments)]
fn validate_device_install_plan(
    plan_path: PathBuf,
    launcher: PathBuf,
    app_state: PathBuf,
    trash: PathBuf,
    remote_config: Option<PathBuf>,
    target_override: Option<PathBuf>,
    root: Option<PathBuf>,
    environment: Vec<String>,
    config_directories: &ConfigDirectories,
) -> Result<(&'static str, Value), CliError> {
    let name = "validate-device-install-plan";
    let resolved = resolve_device_context(
        name,
        launcher,
        app_state,
        trash,
        remote_config,
        target_override,
        root,
        environment,
        config_directories,
    )?;
    let context = resolved.context;
    let bytes = read_bytes(name, &plan_path, "invalid-plan")?;
    let plan = InstallPlan::parse_tsv(&bytes)
        .map_err(|error| domain_error(name, "invalid-plan", error))?;
    let validated = plan
        .validate(&context)
        .map_err(|error| domain_error(name, "plan-rejected", error))?;
    Ok((
        name,
        json!({
            "config_origin": resolved.config_origin,
            "platform_id": context.profile,
            "model_id": resolved.model_id,
            "device_class": context.device_class,
            "target_confirmed": context.target_confirmed,
            "plan": validated,
        }),
    ))
}

#[allow(clippy::too_many_arguments)]
fn generate_device_install_plan(
    launcher: PathBuf,
    app_state: PathBuf,
    trash: PathBuf,
    remote_config: Option<PathBuf>,
    target_override: Option<PathBuf>,
    root: Option<PathBuf>,
    environment: Vec<String>,
    config_directories: &ConfigDirectories,
) -> Result<(&'static str, Value), CliError> {
    let name = "generate-device-install-plan";
    let resolved = resolve_device_context(
        name,
        launcher,
        app_state,
        trash,
        remote_config,
        target_override,
        root,
        environment,
        config_directories,
    )?;
    let plan = InstallPlan::from_context(&resolved.context)
        .map_err(|error| domain_error(name, "plan-rejected", error))?;
    let validated = plan
        .validate(&resolved.context)
        .map_err(|error| domain_error(name, "plan-rejected", error))?;
    let tsv = plan
        .to_tsv()
        .map_err(|error| domain_error(name, "plan-serialization-failed", error))?;
    Ok((
        name,
        json!({
            "config_origin": resolved.config_origin,
            "platform_id": resolved.context.profile,
            "model_id": resolved.model_id,
            "device_class": resolved.context.device_class,
            "target_confirmed": resolved.context.target_confirmed,
            "plan": validated,
            "tsv": tsv,
        }),
    ))
}

fn parse_os_release(
    command: &'static str,
    bytes: &[u8],
) -> Result<BTreeMap<String, String>, CliError> {
    let text = std::str::from_utf8(bytes).map_err(|error| CliError {
        command,
        code: "invalid-os-release",
        message: error.to_string(),
    })?;
    Ok(text
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

fn parse_assignments(
    command: &'static str,
    assignments: &[String],
) -> Result<BTreeMap<String, String>, CliError> {
    let mut result = BTreeMap::new();
    for assignment in assignments {
        let (name, value) = assignment.split_once('=').ok_or_else(|| CliError {
            command,
            code: "invalid-environment",
            message: format!("expected NAME=VALUE, got {assignment:?}"),
        })?;
        if name.is_empty()
            || !name.bytes().enumerate().all(|(index, byte)| {
                byte == b'_'
                    || byte.is_ascii_alphanumeric() && (index > 0 || !byte.is_ascii_digit())
            })
        {
            return Err(CliError {
                command,
                code: "invalid-environment",
                message: format!("invalid environment name {name:?}"),
            });
        }
        result.insert(name.to_owned(), value.to_owned());
    }
    Ok(result)
}

fn read_context(command: &'static str, path: &Path) -> Result<ResolvedDeviceContext, CliError> {
    let input: ResolvedContextInput = read_json(command, path, "invalid-context")?;
    ResolvedDeviceContext::try_from(input)
        .map_err(|error| domain_error(command, "invalid-context", error))
}

fn read_json<T: serde::de::DeserializeOwned>(
    command: &'static str,
    path: &Path,
    code: &'static str,
) -> Result<T, CliError> {
    let bytes = read_bytes(command, path, code)?;
    serde_json::from_slice(&bytes).map_err(|error| CliError {
        command,
        code,
        message: error.to_string(),
    })
}

fn read_bytes(command: &'static str, path: &Path, code: &'static str) -> Result<Vec<u8>, CliError> {
    let result = if path == Path::new("-") {
        let mut bytes = Vec::new();
        io::stdin().read_to_end(&mut bytes).map(|_| bytes)
    } else {
        fs::read(path)
    };
    result.map_err(|error| CliError {
        command,
        code,
        message: error.to_string(),
    })
}

fn reject_double_stdin(command: &'static str, left: &Path, right: &Path) -> Result<(), CliError> {
    if left == Path::new("-") && right == Path::new("-") {
        return Err(CliError {
            command,
            code: "ambiguous-stdin",
            message: "stdin can supply only one input".to_owned(),
        });
    }
    Ok(())
}

fn domain_error(
    command: &'static str,
    code: &'static str,
    error: impl std::fmt::Display,
) -> CliError {
    CliError {
        command,
        code,
        message: error.to_string(),
    }
}

fn print_json(value: &impl Serialize) {
    // Serialization of these owned data structures is infallible. Retain a
    // valid envelope even if a future type breaks that invariant.
    match serde_json::to_string(value) {
        Ok(output) => println!("{output}"),
        Err(error) => println!(
            "{}",
            json!({
                "ok": false,
                "command": "internal",
                "data": null,
                "error": {"code": "serialization", "message": error.to_string()}
            })
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_trimui_plan(root: &Path, plan: &Path) {
        let target = root.join("mnt/SDCARD/Apps/PortMaster/PortMaster");
        let frontend = root.join("mnt/SDCARD/Apps/PortMaster");
        fs::write(
            plan,
            format!(
                concat!(
                    "schema\t1\n",
                    "device\ttrimui\n",
                    "target\t{}\n",
                    "scripts\t/mnt/SDCARD/Roms/PORTS\n",
                    "frontend_dir\t{}\n",
                    "frontend_names\tlaunch.sh,config.json,icon.png\n",
                    "primary_frontend\tlaunch.sh\n",
                    "control_source\ttrimui/control.txt\n",
                    "core_launcher_source\t-\n",
                    "frontend_map\ttrimui/PortMaster.txt=launch.sh,trimui/config.json=config.json,trimui/icon.png=icon.png\n",
                    "remove_core_launcher\t1\n",
                    "empty_tasksetter\t1\n",
                    "core_executable\t-\n",
                    "frontend_executable\tlaunch.sh\n"
                ),
                target.display(),
                frontend.display(),
            ),
        )
        .unwrap();
    }

    #[test]
    fn command_line_accepts_device_validation_options_and_repeated_env() {
        let cli = Cli::try_parse_from([
            "appmanager-cli",
            "inventory",
            "--context",
            "/tmp/context.json",
            "--format",
            "tsv",
            "--scan-script-images",
            "--ignore-dir",
            "PortMaster",
            "--ignore-script",
            "PortMaster.sh",
            "--directory",
            "/mnt/card",
        ])
        .unwrap();
        let Command::Inventory {
            format,
            scan_script_images,
            ignore_dirs,
            ignore_scripts,
            directory,
            ..
        } = cli.command
        else {
            panic!("wrong command")
        };
        assert_eq!(format, OutputFormat::Tsv);
        assert!(scan_script_images);
        assert_eq!(ignore_dirs, ["PortMaster"]);
        assert_eq!(ignore_scripts, ["PortMaster.sh"]);
        assert_eq!(directory, "/mnt/card");

        let cli = Cli::try_parse_from([
            "appmanager-cli",
            "device-inventory",
            "--launcher",
            "/ports/App.sh",
            "--app-state",
            "/tmp/state",
            "--trash",
            "/tmp/trash",
            "--format",
            "json",
        ])
        .unwrap();
        assert!(matches!(cli.command, Command::DeviceInventory { .. }));

        let cli = Cli::try_parse_from([
            "appmanager-cli",
            "validate-device-install-plan",
            "--plan",
            "/tmp/plan.tsv",
            "--launcher",
            "/ports/App.sh",
            "--app-state",
            "/tmp/state",
            "--trash",
            "/tmp/trash",
            "--env",
            "CFW_NAME=TrimUI",
            "--env",
            "DEVICE=brick",
        ])
        .unwrap();
        let Command::ValidateDeviceInstallPlan { environment, .. } = cli.command else {
            panic!("wrong command")
        };
        assert_eq!(environment, ["CFW_NAME=TrimUI", "DEVICE=brick"]);

        let cli = Cli::try_parse_from([
            "appmanager-cli",
            "generate-device-install-plan",
            "--launcher",
            "/ports/App.sh",
            "--app-state",
            "/tmp/state",
            "--trash",
            "/tmp/trash",
            "--format",
            "tsv",
        ])
        .unwrap();
        assert!(matches!(
            cli.command,
            Command::GenerateDeviceInstallPlan {
                format: OutputFormat::Tsv,
                ..
            }
        ));

        let cli = Cli::try_parse_from([
            "appmanager-cli",
            "install-portmaster",
            "--archive",
            "/tmp/PortMaster.zip",
            "--launcher",
            "/ports/App.sh",
            "--app-state",
            "/tmp/state",
            "--trash",
            "/tmp/trash",
            "--cancel-file",
            "/tmp/cancel",
        ])
        .unwrap();
        assert!(matches!(cli.command, Command::InstallPortmaster { .. }));

        let cli = Cli::try_parse_from([
            "appmanager-cli",
            "validate-pending-install",
            "--launcher",
            "/ports/App.sh",
            "--app-state",
            "/tmp/state",
            "--trash",
            "/tmp/trash",
            "--core-health",
            "healthy",
        ])
        .unwrap();
        assert!(matches!(
            cli.command,
            Command::ValidatePendingInstall { .. }
        ));

        let cli = Cli::try_parse_from([
            "appmanager-cli",
            "repair-runtimes",
            "--metadata",
            "/tmp/ports.json",
            "--runtime",
            "godot_4.5",
            "--runtime",
            "mono_6",
            "--arch",
            "aarch64",
            "--libs-root",
            "/opt/PortMaster/libs",
            "--progress",
            "/tmp/progress.tsv",
            "--cancel-file",
            "/tmp/cancel",
        ])
        .unwrap();
        let Command::RepairRuntimes { runtimes, .. } = cli.command else {
            panic!("wrong command")
        };
        assert_eq!(runtimes, ["godot_4.5", "mono_6"]);

        let cli = Cli::try_parse_from([
            "appmanager-cli",
            "apply-file-plan",
            "--plan",
            "/tmp/plan.tsv",
            "--result",
            "/tmp/result.tsv",
            "--self-launcher",
            "/ports/APP Manager.sh",
            "--self-port",
            "jenny92-appmanager",
            "--privilege-command",
            "sudo",
            "--privilege-arg=--preserve-env=DEVICE,SDL_GAMECONTROLLERCONFIG_FILE",
            "--launcher",
            "/ports/APP Manager.sh",
            "--app-state",
            "/tmp/state",
            "--trash",
            "/tmp/trash",
        ])
        .unwrap();
        assert!(matches!(cli.command, Command::ApplyFilePlan { .. }));

        let cli = Cli::try_parse_from([
            "appmanager-cli",
            "scan-device-sizes",
            "--output",
            "/tmp/sizes.tsv",
            "--self-port",
            "jenny92-appmanager",
            "--launcher",
            "/ports/APP Manager.sh",
            "--app-state",
            "/tmp/state",
            "--trash",
            "/tmp/trash",
        ])
        .unwrap();
        assert!(matches!(cli.command, Command::ScanDeviceSizes { .. }));

        let cli = Cli::try_parse_from([
            "appmanager-cli",
            "refresh-stable-cache",
            "--source",
            "https://github.com/example/repo/releases/latest/download/version.json",
            "--cache",
            "/tmp/update.tsv",
            "--force",
        ])
        .unwrap();
        assert!(matches!(
            cli.command,
            Command::RefreshStableCache { force: true, .. }
        ));

        let cli = Cli::try_parse_from([
            "appmanager-cli",
            "fetch-stable-release",
            "--source",
            "https://github.com/example/repo/releases/latest/download/version.json",
            "--archive-name",
            "PortMaster.zip",
            "--output",
            "/tmp/version.tsv",
        ])
        .unwrap();
        assert!(matches!(cli.command, Command::FetchStableRelease { .. }));

        let cli = Cli::try_parse_from([
            "appmanager-cli",
            "refresh-runtime-metadata",
            "--source",
            "https://github.com/PortsMaster/PortMaster-New/releases/latest/download/ports.json",
            "--json-cache",
            "/tmp/ports.json",
            "--tsv-cache",
            "/tmp/runtime.tsv",
        ])
        .unwrap();
        assert!(matches!(
            cli.command,
            Command::RefreshRuntimeMetadata { force: false, .. }
        ));
    }

    #[test]
    fn stable_manifest_parser_rejects_tsv_injection() {
        let valid = br#"{"stable":{"version":"2026.07","url":"https://github.com/example/repo/releases/download/2026.07/PortMaster.zip","md5":"00000000000000000000000000000000"}}"#;
        let parsed = parse_stable_manifest("test", valid).unwrap();
        assert_eq!(parsed.version, "2026.07");

        let invalid = br#"{"stable":{"version":"2026.07\tbad","url":"https://example.test/file","md5":"00000000000000000000000000000000"}}"#;
        assert!(parse_stable_manifest("test", invalid).is_err());
    }

    #[test]
    fn stable_release_is_bound_to_manifest_repository_version_and_asset() {
        let source = "https://github.com/example/repo/releases/latest/download/version.json";
        let valid = StableRelease {
            version: "2026.07".to_owned(),
            url: "https://github.com/example/repo/releases/download/2026.07/PortMaster.zip"
                .to_owned(),
            md5: "0".repeat(32),
        };
        validate_stable_release_route(source, "PortMaster.zip", &valid).unwrap();

        let wrong_repository = StableRelease {
            url: "https://github.com/attacker/repo/releases/download/2026.07/PortMaster.zip"
                .to_owned(),
            ..valid
        };
        assert!(
            validate_stable_release_route(source, "PortMaster.zip", &wrong_repository).is_err()
        );
    }

    #[test]
    fn fresh_stable_cache_skips_the_network_and_atomic_rows_are_well_formed() {
        let temp = tempfile::tempdir().unwrap();
        let cache = temp.path().join("update.tsv");
        write_update_cache(&cache, 123, "ok", "2026.07").unwrap();
        assert_eq!(fs::read_to_string(&cache).unwrap(), "123\tok\t2026.07\n");

        let (_, data) = refresh_stable_cache(
            "not-a-valid-network-source".to_owned(),
            cache.clone(),
            false,
        )
        .unwrap();
        assert_eq!(data["status"], "cached");
        assert_eq!(fs::read_to_string(cache).unwrap(), "123\tok\t2026.07\n");
    }

    #[test]
    fn malformed_stable_cache_does_not_suppress_refresh() {
        let temp = tempfile::tempdir().unwrap();
        let cache = temp.path().join("update.tsv");
        fs::write(&cache, "not-a-cache-row\n").unwrap();

        assert!(
            refresh_stable_cache(
                "not-a-valid-network-source".to_owned(),
                cache.clone(),
                false,
            )
            .is_err()
        );
        assert!(stable_cache_row_valid(&cache));
        assert!(fs::read_to_string(cache).unwrap().contains("\terror\t\n"));
    }

    #[test]
    fn fresh_runtime_json_repairs_derived_tsv_without_the_network() {
        let temp = tempfile::tempdir().unwrap();
        let json_cache = temp.path().join("ports.json");
        let tsv_cache = temp.path().join("runtime.tsv");
        let json = serde_json::to_vec(&json!({
            "utils": {"python": {
                "runtime_name": "python_3.11.squashfs",
                "runtime_arch": "aarch64",
                "size": 4,
                "md5": "00000000000000000000000000000000",
                "url": "https://github.com/PortsMaster/PortMaster-New/releases/download/test/python_3.11.squashfs"
            }}
        }))
        .unwrap();
        let tsv = RuntimeMetadata::parse(&json).unwrap().to_tsv();
        fs::write(&json_cache, json).unwrap();
        fs::write(&tsv_cache, "old generation\n").unwrap();

        let (_, data) = refresh_runtime_metadata(
            "not-a-valid-network-source".to_owned(),
            json_cache,
            tsv_cache.clone(),
            false,
        )
        .unwrap();
        assert_eq!(data["status"], "cached");
        assert_eq!(fs::read_to_string(tsv_cache).unwrap(), tsv);
    }

    #[test]
    fn runtime_entry_validation_uses_json_as_the_single_source_of_truth() {
        let temp = tempfile::tempdir().unwrap();
        let metadata = temp.path().join("ports.json");
        let image = temp.path().join("python_3.11.squashfs");
        fs::write(&image, b"hsqs").unwrap();
        let md5 = digest_file(&image, DigestAlgorithm::Md5).unwrap();
        fs::write(
            &metadata,
            serde_json::to_vec(&json!({
                "utils": {"python": {
                    "runtime_name": "python_3.11.squashfs",
                    "runtime_arch": "aarch64",
                    "size": 4,
                    "md5": md5,
                    "url": "https://github.com/PortsMaster/PortMaster-New/releases/download/test/python_3.11.squashfs"
                }}
            }))
            .unwrap(),
        )
        .unwrap();

        let (_, data) = runtime_metadata_entry(
            metadata.clone(),
            "python_3.11".to_owned(),
            "aarch64".to_owned(),
            Some(image.clone()),
        )
        .unwrap();
        assert!(
            data["tsv"]
                .as_str()
                .unwrap()
                .contains("python_3.11\taarch64\t4\t")
        );
        fs::write(image, b"nope").unwrap();
        assert!(
            runtime_metadata_entry(
                metadata,
                "python_3.11".to_owned(),
                "aarch64".to_owned(),
                Some(temp.path().join("python_3.11.squashfs")),
            )
            .is_err()
        );
    }

    #[test]
    fn runtime_refresh_rejects_a_concurrent_writer() {
        let temp = tempfile::tempdir().unwrap();
        let _lock =
            ExclusiveFileLock::try_acquire(&temp.path().join(".runtime-metadata-refresh.lock"))
                .unwrap();
        assert!(
            refresh_runtime_metadata(
                "not-a-valid-network-source".to_owned(),
                temp.path().join("ports.json"),
                temp.path().join("runtime.tsv"),
                true,
            )
            .is_err()
        );
    }

    #[test]
    fn trimui_device_resolution_accepts_current_install_plan() {
        let temp = tempfile::tempdir().unwrap();
        let state = temp.path().join("state");
        let trash = temp.path().join("trash");
        fs::create_dir(&state).unwrap();
        fs::create_dir(&trash).unwrap();
        let plan = temp.path().join("plan.tsv");
        write_trimui_plan(temp.path(), &plan);

        let (command, data) = validate_device_install_plan(
            plan,
            PathBuf::from("/mnt/SDCARD/Roms/PORTS/APP Manager.sh"),
            state,
            trash,
            None,
            None,
            Some(temp.path().to_path_buf()),
            vec!["CFW_NAME=TrimUI".to_owned()],
            &test_config_directories(),
        )
        .unwrap();
        assert_eq!(command, "validate-device-install-plan");
        assert_eq!(data["config_origin"], "embedded");
        assert_eq!(data["platform_id"], "trimui");
        assert_eq!(data["target_confirmed"], true);
        assert_eq!(data["plan"]["device"], "trimui");
    }

    #[test]
    fn generic_unconfirmed_target_rejects_install_plan() {
        let temp = tempfile::tempdir().unwrap();
        let state = temp.path().join("state");
        let trash = temp.path().join("trash");
        fs::create_dir(&state).unwrap();
        fs::create_dir(&trash).unwrap();
        let plan = temp.path().join("plan.tsv");
        fs::write(
            &plan,
            concat!(
                "schema\t1\n",
                "device\tgeneric\n",
                "target\t/custom/PortMaster\n",
                "scripts\t/unknown/ports\n",
                "frontend_dir\t/unknown/ports\n",
                "frontend_names\tPortMaster.sh\n",
                "primary_frontend\tPortMaster.sh\n",
                "control_source\t-\n",
                "core_launcher_source\t-\n",
                "frontend_map\tPortMaster.sh=PortMaster.sh\n",
                "remove_core_launcher\t0\n",
                "empty_tasksetter\t0\n",
                "core_executable\tPortMaster.sh\n",
                "frontend_executable\tPortMaster.sh\n"
            ),
        )
        .unwrap();

        let error = validate_device_install_plan(
            plan,
            PathBuf::from("/unknown/ports/APP Manager.sh"),
            state,
            trash,
            None,
            None,
            Some(temp.path().to_path_buf()),
            vec!["CFW_NAME=fixture-unknown".to_owned()],
            &test_config_directories(),
        )
        .unwrap_err();
        assert_eq!(error.code, "plan-rejected");
        assert!(error.message.contains("has not been confirmed"));
    }

    fn app_paths(temp: &tempfile::TempDir) -> (PathBuf, PathBuf) {
        let state = temp.path().join("state");
        let trash = temp.path().join("trash");
        fs::create_dir(&state).unwrap();
        fs::create_dir(&trash).unwrap();
        (state, trash)
    }

    fn test_config_directories() -> ConfigDirectories {
        ConfigDirectories {
            embedded: Some(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../config")),
            remote: None,
        }
    }

    #[test]
    fn generates_trimui_plan_as_stable_round_trip_tsv() {
        let temp = tempfile::tempdir().unwrap();
        let (state, trash) = app_paths(&temp);
        let (command, data) = generate_device_install_plan(
            PathBuf::from("/mnt/SDCARD/Roms/PORTS/APP Manager.sh"),
            state,
            trash,
            None,
            None,
            Some(temp.path().to_path_buf()),
            vec!["CFW_NAME=TrimUI".to_owned()],
            &test_config_directories(),
        )
        .unwrap();
        assert_eq!(command, "generate-device-install-plan");
        assert_eq!(data["platform_id"], "trimui");
        let tsv = data["tsv"].as_str().unwrap();
        let parsed = InstallPlan::parse_tsv(tsv.as_bytes()).unwrap();
        assert_eq!(parsed.device, "trimui");
        assert_eq!(
            parsed.frontend_names,
            ["launch.sh", "config.json", "icon.png"]
        );
        assert_eq!(tsv, parsed.to_tsv().unwrap());
    }

    #[test]
    fn generates_miniloong_plan_from_resolution_without_platform_cases() {
        let temp = tempfile::tempdir().unwrap();
        fs::create_dir_all(temp.path().join("loong")).unwrap();
        fs::write(temp.path().join("loong/loong_version"), b"fixture\n").unwrap();
        let (state, trash) = app_paths(&temp);
        let (_, data) = generate_device_install_plan(
            PathBuf::from("/mnt/sdcard/roms/ports/APP Manager.sh"),
            state,
            trash,
            None,
            None,
            Some(temp.path().to_path_buf()),
            Vec::new(),
            &test_config_directories(),
        )
        .unwrap();
        assert_eq!(data["platform_id"], "miniloong");
        let parsed = InstallPlan::parse_tsv(data["tsv"].as_str().unwrap().as_bytes()).unwrap();
        assert_eq!(parsed.device, "miniloong");
        assert_eq!(parsed.frontend_map[0].source, "miniloong/PortMaster.txt");
        assert_eq!(
            parsed.target,
            temp.path().join("mnt/sdcard/roms/ports/PortMaster")
        );
    }

    #[test]
    fn system_managed_resolution_cannot_generate_an_install_plan() {
        let temp = tempfile::tempdir().unwrap();
        fs::create_dir_all(temp.path().join("etc")).unwrap();
        fs::write(temp.path().join("etc/os-release"), b"OS_NAME=ROCKNIX\n").unwrap();
        fs::create_dir_all(temp.path().join("storage/roms/ports")).unwrap();
        let (state, trash) = app_paths(&temp);
        let error = generate_device_install_plan(
            PathBuf::from("/storage/roms/ports/APP Manager.sh"),
            state,
            trash,
            None,
            None,
            Some(temp.path().to_path_buf()),
            Vec::new(),
            &test_config_directories(),
        )
        .unwrap_err();
        assert_eq!(error.code, "plan-rejected");
        assert!(error.message.contains("system-managed"));

        let error = install_device_portmaster(
            temp.path().join("missing.zip"),
            PathBuf::from("/storage/roms/ports/APP Manager.sh"),
            temp.path().join("state-install"),
            temp.path().join("trash-install"),
            None,
            None,
            Some(temp.path().to_path_buf()),
            Vec::new(),
            None,
            &test_config_directories(),
        )
        .unwrap_err();
        assert_eq!(error.code, "install-rejected");
        assert!(error.message.contains("system-managed"));
    }

    #[test]
    fn generic_unconfirmed_resolution_cannot_generate_an_install_plan() {
        let temp = tempfile::tempdir().unwrap();
        let (state, trash) = app_paths(&temp);
        let error = generate_device_install_plan(
            PathBuf::from("/unknown/ports/APP Manager.sh"),
            state,
            trash,
            None,
            None,
            Some(temp.path().to_path_buf()),
            vec!["CFW_NAME=fixture-unknown".to_owned()],
            &test_config_directories(),
        )
        .unwrap_err();
        assert_eq!(error.code, "plan-rejected");
        assert!(error.message.contains("has not been confirmed"));

        let error = install_device_portmaster(
            temp.path().join("missing.zip"),
            PathBuf::from("/unknown/ports/APP Manager.sh"),
            temp.path().join("state-install"),
            temp.path().join("trash-install"),
            None,
            None,
            Some(temp.path().to_path_buf()),
            vec!["CFW_NAME=fixture-unknown".to_owned()],
            None,
            &test_config_directories(),
        )
        .unwrap_err();
        assert_eq!(error.code, "install-rejected");
        assert!(error.message.contains("has not been confirmed"));
    }

    #[test]
    fn model_override_is_reported_without_changing_platform_plan_policy() {
        let temp = tempfile::tempdir().unwrap();
        let (state, trash) = app_paths(&temp);
        let (_, data) = generate_device_install_plan(
            PathBuf::from("/mnt/SDCARD/Roms/PORTS/APP Manager.sh"),
            state,
            trash,
            None,
            None,
            Some(temp.path().to_path_buf()),
            vec!["CFW_NAME=TrimUI".to_owned(), "DEVICE=brick".to_owned()],
            &test_config_directories(),
        )
        .unwrap();
        assert_eq!(data["platform_id"], "trimui");
        assert_eq!(data["model_id"], "brick");
        assert_eq!(data["plan"]["device"], "trimui");
    }

    #[test]
    fn device_inventory_is_a_single_resolution_to_snapshot_call() {
        let temp = tempfile::tempdir().unwrap();
        let launcher = temp.path().join("mnt/SDCARD/Roms/PORTS/APP Manager.sh");
        let scripts = launcher.parent().unwrap();
        let games = temp.path().join("mnt/SDCARD/Data/ports");
        let images = temp.path().join("mnt/SDCARD/Roms/Imgs/PORTS");
        let libs = temp
            .path()
            .join("mnt/SDCARD/Apps/PortMaster/PortMaster/libs");
        for directory in [scripts, &games, &images, &libs] {
            fs::create_dir_all(directory).unwrap();
        }
        fs::write(
            scripts.join("Alpha.sh"),
            b"GAMEDIR=\"$directory/ports/Alpha\"\nruntime=mono\n",
        )
        .unwrap();
        fs::create_dir(games.join("Alpha")).unwrap();
        fs::write(images.join("Alpha.png"), b"image").unwrap();
        fs::write(libs.join("mono.squashfs"), b"hsqs-runtime").unwrap();
        let (state, trash) = app_paths(&temp);
        let options = inventory_options(
            false,
            vec!["PortMaster".to_owned()],
            vec!["PortMaster.sh".to_owned()],
            None,
            "/mnt/SDCARD/Data".to_owned(),
            String::new(),
            "/root".to_owned(),
        );
        let (command, data) = device_inventory(
            launcher.clone(),
            state.clone(),
            trash.clone(),
            None,
            None,
            Some(temp.path().to_path_buf()),
            vec!["CFW_NAME=TrimUI".to_owned()],
            None,
            OutputFormat::Json,
            options.clone(),
            &test_config_directories(),
        )
        .unwrap();
        assert_eq!(command, "device-inventory");
        assert_eq!(data["ports"][0]["script"], "Alpha.sh");
        assert_eq!(data["ports"][0]["dir"], "Alpha");
        assert_eq!(data["ports"][0]["images"][0]["name"], "Alpha.png");
        assert_eq!(data["runtimes"]["facts"][0]["health"], "unknown");

        let (_, data) = device_inventory(
            launcher,
            state,
            trash,
            None,
            None,
            Some(temp.path().to_path_buf()),
            vec!["CFW_NAME=TrimUI".to_owned()],
            None,
            OutputFormat::Tsv,
            options,
            &test_config_directories(),
        )
        .unwrap();
        assert!(data["tsv"].as_str().unwrap().contains("port\tAlpha.sh\t"));
    }
}
