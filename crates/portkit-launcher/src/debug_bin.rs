// INPUT: Explicit remote-debug roots and literal command argv.
// OUTPUT: A private executable view with same-PID command handoff.
// POS: Developer-only binary; never linked into or staged beside the player launcher.
mod exec_view;
use std::{error::Error, ffi::OsString, path::PathBuf, process::ExitCode};
const REVISION: &str = match option_env!("PORTKIT_LAUNCHER_SOURCE_REVISION") {
    Some(s) => s,
    None => "development",
};
fn run() -> Result<(), Box<dyn Error>> {
    let mut args = std::env::args_os().skip(1).peekable();
    if args
        .peek()
        .is_some_and(|a| a == "version" || a == "--version")
    {
        args.next();
        if args.next().is_some() {
            return Err("version takes no arguments".into());
        }
        println!(
            "portkit-debug-launch {} {REVISION}",
            env!("CARGO_PKG_VERSION")
        );
        return Ok(());
    }
    let mut roots = Vec::<PathBuf>::new();
    let mut quiet = false;
    let mut command = Vec::<OsString>::new();
    while let Some(arg) = args.next() {
        match arg.to_str() {
            Some("--root") => {
                roots.push(PathBuf::from(args.next().ok_or("--root requires a path")?))
            }
            Some("--quiet") => quiet = true,
            Some("--") => {
                command.extend(args);
                break;
            }
            _ => return Err(
                "usage: portkit-debug-launch --root DIR [--root DIR] [--quiet] -- COMMAND [ARG...]"
                    .into(),
            ),
        }
    }
    exec_view::exec_view(&roots, &command, quiet)
}
fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("portkit-debug-launch: {error}");
            ExitCode::FAILURE
        }
    }
}
