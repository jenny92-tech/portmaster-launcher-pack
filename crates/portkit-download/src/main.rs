// INPUT:  Command-line URL/output arguments and portkit_core::github
// OUTPUT: Downloaded file, terminal progress and process exit status
// POS:    Thin desktop CLI over the existing GitHub transport
use portkit_core::github::{Capability, GitHubError, GitHubTransport, Progress};
use std::{
    ffi::OsString,
    io::{self, Write},
    path::PathBuf,
    process::ExitCode,
};

const USAGE: &str = "Usage: portkit-download <GitHub URL> -o <output file>\nExisting files may be replaced. Downloads use the shared mirror/SOCKS routes.\nNo publisher checksum is verified; verify trusted checksums before running downloads.";

fn arguments(args: Vec<OsString>) -> Result<Option<(String, PathBuf)>, String> {
    if args.len() == 1 && (args[0] == "--help" || args[0] == "-h") {
        return Ok(None);
    }
    if args.len() != 3 || args[1] != "-o" || args[2].is_empty() {
        return Err(USAGE.into());
    }
    let url = args[0]
        .clone()
        .into_string()
        .map_err(|_| "URL must be UTF-8")?;
    Ok(Some((url, PathBuf::from(&args[2]))))
}

fn capability(transport: &GitHubTransport, url: &str) -> Result<Capability, &'static str> {
    [
        Capability::Release,
        Capability::Raw,
        Capability::Archive,
        Capability::Api,
        Capability::Gist,
    ]
    .into_iter()
    .find(|kind| {
        matches!(
            transport.candidate_route_ids(*kind, url),
            Ok(_) | Err(GitHubError::NoCandidates)
        )
    })
    .ok_or("Unsupported GitHub file URL (repository pages and git clone are not downloads)")
}

struct Terminal;
impl Progress for Terminal {
    fn update(&self, received: u64, total: u64) -> io::Result<()> {
        let mut out = io::stderr().lock();
        write!(out, "\r{received} / {total} bytes   ")?;
        out.flush()
    }
}

fn run() -> Result<(), String> {
    let Some((url, output)) = arguments(std::env::args_os().skip(1).collect())? else {
        println!("{USAGE}");
        return Ok(());
    };
    let transport = GitHubTransport::new();
    let kind = capability(&transport, &url)?;
    eprintln!("Selecting download route…");
    let result = transport.fetch(
        kind,
        &url,
        &output,
        |path| path.is_file(),
        Some(&Terminal),
        None,
    );
    eprintln!();
    result.map_err(|error| error.to_string())?;
    println!("Saved: {}", output.display());
    Ok(())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("portkit-download: {error}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn minimal_arguments() {
        assert!(arguments(vec!["--help".into()]).unwrap().is_none());
        assert!(arguments(vec![]).is_err());
        let parsed = arguments(vec![
            "https://github.com/a/b/releases/download/v/a.zip".into(),
            "-o".into(),
            "文件 a.zip".into(),
        ])
        .unwrap()
        .unwrap();
        assert_eq!(parsed.1, PathBuf::from("文件 a.zip"));
        assert!(arguments(vec!["url".into(), "--bad".into(), "out".into()]).is_err());
    }
    #[test]
    fn classification_reuses_core_validation() {
        let transport = GitHubTransport::new();
        assert_eq!(
            capability(
                &transport,
                "https://github.com/a/b/releases/download/v/a.zip"
            )
            .unwrap(),
            Capability::Release
        );
        assert_eq!(
            capability(
                &transport,
                "https://raw.githubusercontent.com/a/b/main/a.txt"
            )
            .unwrap(),
            Capability::Raw
        );
        assert!(capability(&transport, "https://example.com/a.zip").is_err());
        assert!(capability(&transport, "https://github.com/a/b").is_err());
    }
    #[test]
    fn lock_excludes_second_owner_and_releases() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("download.lock");
        let first = portkit_core::ExclusiveFileLock::try_acquire(&path).unwrap();
        assert!(portkit_core::ExclusiveFileLock::try_acquire(&path).is_err());
        drop(first);
        assert!(portkit_core::ExclusiveFileLock::try_acquire(&path).is_ok());
    }
}
