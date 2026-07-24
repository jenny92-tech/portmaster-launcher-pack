#![recursion_limit = "256"]

use std::collections::BTreeMap;
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use appmanager_core::{
    FileApplyRequest, InstallPlan, InstallRequest, Inventory, InventoryOptions,
    ResolvedContextInput, ResolvedDeviceContext,
    RuntimeMetadata, RuntimeRepairRequest, SizeScanRequest, apply_file_plan, install_portmaster,
    plan_contains_only_file_actions, repair_runtimes, scan_size_cache,
};
use clap::{Parser, Subcommand, ValueEnum};
use portkit_core::{DigestAlgorithm, digest_file};
use serde::Serialize;
use serde_json::{Value, json};

#[cfg(test)]
use portkit_core::ExclusiveFileLock;

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
pub(crate) struct ConfigDirectories {
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
    /// Run one explicit diagnostic or compatibility operation.
    LauncherSession {
        #[arg(long)]
        source_dir: PathBuf,
        #[arg(long)]
        launcher: PathBuf,
        #[arg(long)]
        app_root: PathBuf,
        #[arg(last = true, allow_hyphen_values = true)]
        entry_arguments: Vec<String>,
    },
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

pub fn cli_main() -> ExitCode {
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
    if let Command::LauncherSession {
        source_dir,
        launcher,
        app_root,
        entry_arguments,
    } = &cli.command
    {
        return appmanager_service::run_diagnostic(
            source_dir.clone(),
            launcher.clone(),
            app_root.clone(),
            cli.config_dir.clone(),
            cli.remote_config_dir.clone(),
            entry_arguments.clone(),
        );
    }
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
        Command::LauncherSession { .. } => unreachable!("handled before command dispatch"),
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
            let context = read_context(name, &context)?;
            let options = inventory_options(
                scan_script_images,
                ignore_dirs,
                ignore_scripts,
                self_port,
                directory,
                controlfolder,
                home,
            );
            let inventory = Inventory::scan_with_options(&context, &options)
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
                cancel_token: None,
                progress_channel: None,
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
    }
}

#[cfg(test)]
type StableRelease = appmanager_core::StableRelease;

#[cfg(test)]
fn parse_stable_manifest(command: &'static str, bytes: &[u8]) -> Result<StableRelease, CliError> {
    appmanager_core::parse_stable_manifest(bytes)
        .map_err(|error| domain_error(command, "invalid-stable-manifest", error))
}

fn fetch_stable_release(
    source: String,
    archive_name: String,
    output: PathBuf,
) -> Result<(&'static str, Value), CliError> {
    const NAME: &str = "fetch-stable-release";
    let outcome = appmanager_core::fetch_stable_release(&appmanager_core::StableReleaseRequest {
        manifest_url: source,
        archive_name,
        output,
    })
    .map_err(|error| domain_error(NAME, "stable-release-failed", error))?;
    let stable = outcome.release;
    Ok((
        NAME,
        json!({
            "version": stable.version,
            "url": stable.url,
            "md5": stable.md5,
            "route": outcome.route,
            "output": outcome.output,
        }),
    ))
}

#[cfg(test)]
fn validate_stable_release_route(
    source: &str,
    archive_name: &str,
    stable: &StableRelease,
) -> Result<(), CliError> {
    appmanager_core::validate_stable_release_route(source, archive_name, stable)
        .map_err(|error| domain_error("fetch-stable-release", "invalid-stable-release", error))
}

fn refresh_stable_cache(
    source: String,
    cache: PathBuf,
    force: bool,
) -> Result<(&'static str, Value), CliError> {
    const NAME: &str = "refresh-stable-cache";
    let outcome = appmanager_core::refresh_stable_cache(&appmanager_core::StableCacheRequest {
        manifest_url: source,
        cache: cache.clone(),
        force,
    })
    .map_err(|error| domain_error(NAME, "stable-manifest-download-failed", error))?;
    let status = if outcome.status == appmanager_core::CacheRefreshStatus::Cached {
        "cached"
    } else {
        "ok"
    };
    Ok((
        NAME,
        json!({
            "status": status,
            "latest": outcome.latest,
            "route": outcome.route,
            "cache": cache,
        }),
    ))
}

fn refresh_runtime_metadata(
    source: String,
    json_cache: PathBuf,
    tsv_cache: PathBuf,
    force: bool,
) -> Result<(&'static str, Value), CliError> {
    const NAME: &str = "refresh-runtime-metadata";
    let outcome =
        appmanager_core::refresh_runtime_metadata(&appmanager_core::RuntimeMetadataRequest {
            source,
            json_cache,
            tsv_cache: Some(tsv_cache),
            force,
        })
        .map_err(|error| domain_error(NAME, "runtime-metadata-download-failed", error))?;
    Ok((
        NAME,
        json!({"status": outcome.status.as_str(), "route": outcome.route}),
    ))
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

#[cfg(test)]
fn stable_cache_row_valid(path: &Path) -> bool {
    appmanager_core::stable_cache_row_valid(path)
}

#[cfg(test)]
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

#[cfg(test)]
fn atomic_write(
    path: &Path,
    bytes: &[u8],
    command: &'static str,
    code: &'static str,
) -> Result<(), CliError> {
    portkit_core::atomic_write(path, bytes).map_err(|error| domain_error(command, code, error))
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
    let inventory = Inventory::scan_with_options(&resolved.context, &options)
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
        cancel_token: None,
        progress_channel: None,
        probe_root: root,
        plan,
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

type DeviceResolution = appmanager_core::DeviceResolution;

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
        environment,
        config: appmanager_core::DeviceConfigSources {
            embedded_root: EMBEDDED_ROOT.to_vec(),
            embedded_dir,
            remote_root: remote_config,
            remote_dir: config_directories.remote.clone(),
        },
    })
    .map_err(|error| domain_error(command, "device-resolution-failed", error))
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
        let images = temp.path().join("mnt/SDCARD/Imgs/PORTS");
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
            OutputFormat::Tsv,
            options,
            &test_config_directories(),
        )
        .unwrap();
        assert!(data["tsv"].as_str().unwrap().contains("port\tAlpha.sh\t"));
    }
}
