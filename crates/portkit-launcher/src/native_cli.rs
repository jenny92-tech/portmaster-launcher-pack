// INPUT:  Native session CLI arguments and the shared PortKit launcher modules.
// OUTPUT: Optional native-command dispatch, preserving command exit status.
// POS:    Keep process/session options separate from the existing configuration-editing CLI.
use portkit_launcher::{driver, process, session, wayland_session};
use std::collections::BTreeMap;
use std::error::Error;
use std::ffi::OsString;
use std::path::{Path, PathBuf};

type Result<T> = std::result::Result<T, Box<dyn Error>>;

#[derive(Default)]
struct Arguments {
    options: BTreeMap<String, Vec<String>>,
    command: Vec<OsString>,
}

impl Arguments {
    fn parse(
        args: &[String],
        values: &[&str],
        switches: &[&str],
        repeated: &[&str],
    ) -> Result<Self> {
        let mut result = Self::default();
        let mut index = 0;
        while index < args.len() {
            if args[index] == "--" {
                result.command = args[index + 1..].iter().map(OsString::from).collect();
                break;
            }
            let name = args[index]
                .strip_prefix("--")
                .ok_or("expected a named option or -- command separator")?;
            if result.options.contains_key(name) && !repeated.contains(&name) {
                return Err(format!("duplicate option --{name}").into());
            }
            let value = if values.contains(&name) {
                index += 1;
                let value = args
                    .get(index)
                    .ok_or_else(|| format!("--{name} requires a value"))?;
                if value.starts_with("--") {
                    return Err(format!("--{name} requires a value").into());
                }
                value.clone()
            } else if switches.contains(&name) {
                "true".to_owned()
            } else {
                return Err(format!("unknown option --{name}").into());
            };
            result
                .options
                .entry(name.to_owned())
                .or_default()
                .push(value);
            index += 1;
        }
        Ok(result)
    }

    fn value(&self, name: &str) -> Option<&str> {
        self.options
            .get(name)
            .and_then(|v| v.last())
            .map(String::as_str)
    }
    fn required(&self, name: &str) -> Result<&str> {
        self.value(name)
            .ok_or_else(|| format!("--{name} is required").into())
    }
    fn flag(&self, name: &str) -> bool {
        self.options.contains_key(name)
    }
}

pub fn dispatch(args: &[String]) -> Option<Result<i32>> {
    match args.first().map(String::as_str) {
        Some("wayland") => Some(wayland(&args[1..])),
        Some("session") => Some(session(&args[1..])),
        Some("driver-check") => Some(driver_check(&args[1..])),
        Some("bounded") => Some(bounded(&args[1..])),
        _ => None,
    }
}

fn bounded(args: &[String]) -> Result<i32> {
    let arguments = Arguments::parse(args, &["seconds"], &[], &[])?;
    let seconds: u64 = arguments.required("seconds")?.parse()?;
    if !(1..=3600).contains(&seconds) || arguments.command.is_empty() {
        return Err("bounded requires 1..3600 seconds and a command after --".into());
    }
    let mut command = std::process::Command::new(&arguments.command[0]);
    command.args(&arguments.command[1..]);
    let output = process::run_bounded(command, std::time::Duration::from_secs(seconds))?;
    use std::io::Write;
    std::io::stdout().write_all(&output.tail)?;
    Ok(output.exit_code)
}

fn driver_check(args: &[String]) -> Result<i32> {
    let arguments = Arguments::parse(args, &["directory", "source-revision"], &[], &[])?;
    if !arguments.command.is_empty() {
        return Err("driver-check does not start a command".into());
    }
    driver::check(
        Path::new(arguments.required("directory")?),
        arguments.required("source-revision")?,
    )?;
    Ok(0)
}

fn wayland(args: &[String]) -> Result<i32> {
    let arguments = Arguments::parse(
        args,
        &["runtime", "weston-image", "log-dir"],
        &["check"],
        &[],
    )?;
    let runtime = Path::new(arguments.required("runtime")?);
    let image = Path::new(arguments.required("weston-image")?);
    if arguments.flag("check") {
        if !arguments.command.is_empty() {
            return Err("--check does not start a command".into());
        }
        wayland_session::check(runtime, image)?;
        return Ok(0);
    }
    let logs = Path::new(arguments.required("log-dir")?);
    if arguments.command.is_empty() {
        return Err("wayland needs a command after --".into());
    }
    wayland_session::run(runtime, image, logs, &arguments.command)
}

fn session(args: &[String]) -> Result<i32> {
    let arguments = Arguments::parse(
        args,
        &["root", "profile", "aspect", "presentation", "video-driver", "backend", "render-scale"],
        &[
            "check",
            "print-profile",
            "graphics-probe",
            "private-wayland",
        ],
        &["profile", "aspect", "presentation", "video-driver", "backend", "render-scale"],
    )?;
    if !arguments.command.is_empty() {
        return Err("session command is declared by the installation manifest".into());
    }
    if ["check", "print-profile", "graphics-probe"]
        .iter()
        .filter(|name| arguments.flag(name))
        .count()
        > 1
    {
        return Err("choose one session action".into());
    }
    let root = Path::new(arguments.required("root")?);
    let profile = arguments.value("profile").map(PathBuf::from);
    if arguments.flag("check") {
        session::check(root, profile.as_deref())?;
        println!("Native installation preflight passed; game was not started.");
        return Ok(0);
    }
    if arguments.flag("print-profile") {
        let (_, manifest) = session::load(root)?;
        println!(
            "{}",
            session::select_profile(&manifest, profile.as_deref())?.display()
        );
        return Ok(0);
    }
    if arguments.flag("graphics-probe") {
        session::graphics_probe(root)?;
        return Ok(0);
    }
    session::run(
        root,
        &session::LaunchOptions {
            profile,
            aspect: arguments.value("aspect").map(str::to_owned),
            presentation: arguments.value("presentation").map(str::to_owned),
            video_driver: arguments.value("video-driver").map(str::to_owned),
            private_wayland: arguments.flag("private-wayland"),
            backend: arguments.value("backend").map(str::to_owned),
            render_scale: arguments.value("render-scale").map(str::to_owned),
        },
    )
}
