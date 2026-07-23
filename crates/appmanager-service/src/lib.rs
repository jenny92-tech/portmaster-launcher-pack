#![recursion_limit = "256"]

mod launcher;
mod resolution;

use std::path::PathBuf;
use std::process::ExitCode;

pub use launcher::{EmbeddedAction, EmbeddedRequest, EmbeddedService, ServiceEvent};

pub fn run_diagnostic(
    source_dir: PathBuf,
    launcher: PathBuf,
    app_root: PathBuf,
    config_dir: Option<PathBuf>,
    remote_config_dir: Option<PathBuf>,
    entry_arguments: Vec<String>,
) -> ExitCode {
    launcher::run(launcher::Request {
        source_dir,
        launcher,
        app_root,
        entry_arguments,
        config_directories: resolution::ConfigDirectories {
            embedded: config_dir,
            remote: remote_config_dir,
        },
        cancel_token: None,
        progress_channel: None,
    })
}
