use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

static SEQUENCE: AtomicU64 = AtomicU64::new(0);

fn test_directory(name: &str) -> PathBuf {
    let sequence = SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let path = std::env::temp_dir().join(format!(
        "portkit-cli-env-{}-{sequence}-{name}",
        std::process::id()
    ));
    fs::create_dir_all(&path).unwrap();
    path
}

fn base_arguments(action: &str) -> Vec<String> {
    vec![
        "env".into(),
        action.into(),
        "--scope".into(),
        "appmanager".into(),
        "--launcher".into(),
        "/unknown/ports/Test.sh".into(),
        "--target-override".into(),
        "/custom/PortMaster".into(),
        "--var".into(),
        "app_root=/tmp/app root".into(),
        "--var".into(),
        "state_dir=/tmp/state root".into(),
    ]
}

#[test]
fn env_exec_filters_native_dangers_and_keeps_values_literal() {
    let root = test_directory("literal");
    let touched = root.join("must-not-exist");
    let payload = format!("$(touch {})", touched.display());
    let mut arguments = base_arguments("exec");
    arguments.extend([
        "--set".into(),
        format!("PAYLOAD={payload}"),
        "--".into(),
        "/usr/bin/env".into(),
    ]);
    let output = Command::new(env!("CARGO_BIN_EXE_portkit"))
        .args(arguments)
        .env("SAFE_INHERITED", "kept")
        .env("LD_PRELOAD", "")
        .env("LD_AUDIT", "")
        .env("GCONV_PATH", "")
        .env("BASH_ENV", "")
        .env("ENV", "")
        .env("SHELLOPTS", "")
        .env("BASHOPTS", "")
        .env("IFS", "")
        .env("PS4", "")
        .env("BASH_FUNC_payload", "blocked")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let child_environment = String::from_utf8(output.stdout).unwrap();
    assert!(
        child_environment
            .lines()
            .any(|line| line == "SAFE_INHERITED=kept")
    );
    assert!(
        child_environment
            .lines()
            .any(|line| line == format!("PAYLOAD={payload}"))
    );
    for name in [
        "LD_PRELOAD",
        "LD_AUDIT",
        "GCONV_PATH",
        "BASH_ENV",
        "ENV",
        "SHELLOPTS",
        "BASHOPTS",
        "IFS",
        "PS4",
    ] {
        assert!(
            !child_environment
                .lines()
                .any(|line| line.starts_with(&format!("{name}="))),
            "{name} leaked"
        );
    }
    assert!(
        !child_environment
            .lines()
            .any(|line| line.starts_with("BASH_FUNC_"))
    );
    assert!(
        child_environment
            .lines()
            .any(|line| line == "PAM_ENV=/tmp/state root/env.json")
    );
    assert!(!touched.exists());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn env_run_returns_the_child_exit_code() {
    let mut arguments = base_arguments("run");
    arguments.extend(["--".into(), "/bin/sh".into(), "-c".into(), "exit 37".into()]);
    let status = Command::new(env!("CARGO_BIN_EXE_portkit"))
        .args(arguments)
        .status()
        .unwrap();
    assert_eq!(status.code(), Some(37));
}
