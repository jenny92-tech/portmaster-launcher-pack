use std::collections::BTreeMap;
use std::path::PathBuf;
use std::process::ExitCode;

use portkit_launcher::font::{ProvisionRequest, provision};
use portkit_launcher::unity::{ConfigureRequest, configure};

const SOURCE_REVISION: &str = match option_env!("PORTKIT_LAUNCHER_SOURCE_REVISION") {
    Some(value) => value,
    None => "development",
};

fn main() -> ExitCode {
    match run(std::env::args().skip(1).collect()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("portkit-launcher: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run(arguments: Vec<String>) -> Result<(), Box<dyn std::error::Error>> {
    match arguments.as_slice() {
        [command] if matches!(command.as_str(), "version" | "--version" | "-V") => {
            println!(
                "portkit-launcher {} {SOURCE_REVISION}",
                env!("CARGO_PKG_VERSION")
            );
            Ok(())
        }
        [group, command, rest @ ..] if group == "artwork" && command == "probe" => {
            let options = Options::parse(rest)?;
            let script_dir = required(&options, "script-dir")?;
            match portkit_launcher::artwork::probe_image_dir(
                script_dir.as_ref(),
                &portkit_launcher::artwork::ProbeMarkers::default(),
            ) {
                Some(dir) => println!("{}", dir.display()),
                None => println!(),
            }
            Ok(())
        }
        [group, command, rest @ ..] if group == "artwork" && command == "sync" => {
            let options = Options::parse(rest)?;
            let script_dir = required(&options, "script-dir")?;
            let launcher = required(&options, "launcher")?;
            let source_dir = required(&options, "source-dir")?;
            let outcome = portkit_launcher::artwork::sync_launcher_artwork(
                script_dir.as_ref(),
                launcher.as_ref(),
                source_dir.as_ref(),
                &portkit_launcher::artwork::ProbeMarkers::default(),
            )?;
            match outcome {
                portkit_launcher::artwork::SyncOutcome::Copied(path) => {
                    println!("copied	{}", path.display());
                }
                portkit_launcher::artwork::SyncOutcome::Existing(path) => {
                    println!("existing	{}", path.display());
                }
                portkit_launcher::artwork::SyncOutcome::Skipped(reason) => {
                    println!("skipped	{reason}");
                }
            }
            Ok(())
        }
        [group, command, rest @ ..] if group == "font" && command == "provision" => {
            let options = Options::parse(rest)?;
            let outcome = provision(&ProvisionRequest {
                candidates: options.many("candidate").map(PathBuf::from).collect(),
                tar_xz_sources: options.many("tar-xz").map(PathBuf::from).collect(),
                zip_sources: options.many("zip").map(PathBuf::from).collect(),
                outputs: options.many("output").map(PathBuf::from).collect(),
                member: options
                    .one("member")
                    .unwrap_or("NotoSansSC-Regular.ttf")
                    .to_owned(),
            })?;
            println!("{}", outcome.path.display());
            Ok(())
        }
        [group, command, rest @ ..] if group == "json" && command == "merge" => {
            let options = Options::parse(rest)?;
            let path = required(&options, "file")?;
            let patch = serde_json::from_str(required(&options, "patch")?)?;
            portkit_launcher::json::merge_file(path.as_ref(), &patch)?;
            Ok(())
        }
        [group, command, rest @ ..] if group == "unity" && command == "configure" => {
            let options = Options::parse(rest)?;
            let button_values = ["a", "b", "x", "y"].map(|name| options.one(name));
            let buttons = if button_values.iter().all(Option::is_none) {
                None
            } else if button_values.iter().all(Option::is_some) {
                let values = button_values.map(|value| value.unwrap().to_owned());
                if values.iter().any(|value| !safe_button(value)) {
                    return Err("button values may contain only A-Z, 0-9 and underscore".into());
                }
                Some(values)
            } else {
                return Err("--a, --b, --x and --y must be supplied together".into());
            };
            let width = optional_u32(&options, "width")?;
            let height = optional_u32(&options, "height")?;
            if width.is_none() && height.is_none() && buttons.is_none() {
                return Err("unity configure requires dimensions or button mappings".into());
            }
            configure(&ConfigureRequest {
                path: required(&options, "file")?.into(),
                width,
                height,
                buttons,
            })?;
            Ok(())
        }
        [group, command, rest @ ..] if group == "runtime" && command == "latest-love" => {
            let options = Options::parse(rest)?;
            let path =
                portkit_launcher::runtime::latest_love(required(&options, "root")?.as_ref())?;
            println!("{}", path.display());
            Ok(())
        }
        [group, command, rest @ ..] if group == "file" && command == "sync-newer" => {
            let options = Options::parse(rest)?;
            let copied =
                portkit_launcher::sync::sync_newer(&portkit_launcher::sync::SyncRequest {
                    source: required(&options, "source")?.into(),
                    destination: required(&options, "destination")?.into(),
                    extensions: options.many("extension").cloned().collect(),
                })?;
            println!("{copied}");
            Ok(())
        }
        _ => Err(usage().into()),
    }
}

#[derive(Default)]
struct Options {
    values: BTreeMap<String, Vec<String>>,
}

impl Options {
    fn parse(arguments: &[String]) -> Result<Self, String> {
        let mut options = Self::default();
        let mut index = 0;
        while index < arguments.len() {
            let name = arguments[index].strip_prefix("--").ok_or_else(usage)?;
            let value = arguments
                .get(index + 1)
                .ok_or_else(|| format!("option --{name} requires a value"))?;
            if value.starts_with("--") {
                return Err(format!("option --{name} requires a value"));
            }
            options
                .values
                .entry(name.to_owned())
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
}

fn required<'a>(options: &'a Options, name: &str) -> Result<&'a str, String> {
    options
        .one(name)
        .ok_or_else(|| format!("option --{name} is required"))
}

fn optional_u32(options: &Options, name: &str) -> Result<Option<u32>, String> {
    options
        .one(name)
        .map(|value| {
            value
                .parse::<u32>()
                .map_err(|_| format!("--{name} must be an unsigned integer"))
        })
        .transpose()
}

fn safe_button(value: &str) -> bool {
    !value.is_empty()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'_')
}

fn usage() -> String {
    "usage: portkit-launcher artwork sync --script-dir DIR --launcher FILE --source-dir DIR
       portkit-launcher artwork probe --script-dir DIR
       portkit-launcher font provision [--candidate FILE] [--tar-xz FILE] [--zip FILE] --output FILE [--output FALLBACK] [--member FILE]\n       portkit-launcher json merge --file FILE --patch JSON\n       portkit-launcher unity configure --file FILE [--width N --height N] [--a NAME --b NAME --x NAME --y NAME]\n       portkit-launcher runtime latest-love --root DIR\n       portkit-launcher file sync-newer --source DIR --destination DIR --extension EXT [--extension EXT]".into()
}
