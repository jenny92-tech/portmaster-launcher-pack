use serde_json::Value;
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

static SEQUENCE: AtomicU64 = AtomicU64::new(0);

fn test_directory() -> PathBuf {
    let sequence = SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let path = std::env::temp_dir().join(format!(
        "portkit-cli-health-{}-{sequence}",
        std::process::id()
    ));
    fs::create_dir_all(&path).unwrap();
    path
}

fn fake_python(root: &std::path::Path, exit_code: i32) -> PathBuf {
    let executable = root.join(format!("fake-python-{exit_code}"));
    fs::write(&executable, format!("#!/bin/sh\nexit {exit_code}\n")).unwrap();
    #[cfg(unix)]
    {
        let mut permissions = fs::metadata(&executable).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&executable, permissions).unwrap();
    }
    executable
}

fn arguments(root: &std::path::Path, python: &std::path::Path) -> Vec<String> {
    vec![
        "health".into(),
        "--root".into(),
        root.display().to_string(),
        "--launcher".into(),
        "/unknown/ports/Test.sh".into(),
        "--target-override".into(),
        "/custom/PortMaster".into(),
        "--python-executable".into(),
        python.display().to_string(),
    ]
}

#[test]
fn health_reports_configured_filesystem_rules_and_python_metadata() {
    let root = test_directory();
    let python = fake_python(&root, 0);
    let core = root.join("custom/PortMaster");
    fs::create_dir_all(core.join("pylibs")).unwrap();
    let damaged = Command::new(env!("CARGO_BIN_EXE_portkit"))
        .args(arguments(&root, &python))
        .output()
        .unwrap();
    assert!(damaged.status.success());
    let report: Value = serde_json::from_slice(&damaged.stdout).unwrap();
    assert_eq!(report["report"]["status"], "damaged");

    fs::write(core.join("control.txt"), "control").unwrap();
    fs::write(core.join("pugwash"), "helper").unwrap();
    fs::write(core.join("pylibs/module"), "module").unwrap();
    let healthy = Command::new(env!("CARGO_BIN_EXE_portkit"))
        .args(arguments(&root, &python))
        .output()
        .unwrap();
    assert!(
        healthy.status.success(),
        "{}",
        String::from_utf8_lossy(&healthy.stderr)
    );
    let report: Value = serde_json::from_slice(&healthy.stdout).unwrap();
    assert_eq!(report["report"]["status"], "healthy");
    assert_eq!(report["report"]["python_ready"], true);
    assert_eq!(report["report"]["python_mode"], "system");
    assert!(report["report"]["python_imports"].as_array().unwrap().len() >= 4);

    let mut tsv_arguments = arguments(&root, &python);
    tsv_arguments.extend(["--format".into(), "tsv".into()]);
    let tsv = Command::new(env!("CARGO_BIN_EXE_portkit"))
        .args(tsv_arguments)
        .output()
        .unwrap();
    let tsv = String::from_utf8(tsv.stdout).unwrap();
    assert!(tsv.contains("health_contract\tportkit.health.v1\n"));
    assert!(tsv.contains("health_status\thealthy\n"));
    assert!(tsv.contains("python_ready\ttrue\n"));
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn system_python_failure_makes_an_otherwise_healthy_report_damaged() {
    let root = test_directory();
    let python = fake_python(&root, 23);
    let core = root.join("custom/PortMaster");
    fs::create_dir_all(core.join("pylibs")).unwrap();
    fs::write(core.join("control.txt"), "control").unwrap();
    fs::write(core.join("pugwash"), "helper").unwrap();
    fs::write(core.join("pylibs/module"), "module").unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_portkit"))
        .args(arguments(&root, &python))
        .output()
        .unwrap();
    assert!(output.status.success());
    let report: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(report["report"]["python_ready"], false);
    assert_eq!(report["report"]["healthy"], false);
    assert_eq!(report["report"]["status"], "damaged");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn runtime_mount_requires_hsqs_magic_at_the_health_runtime_image() {
    let root = test_directory();
    fs::create_dir_all(root.join("loong")).unwrap();
    fs::write(root.join("loong/loong_version"), "test").unwrap();
    let core = root.join("mnt/sdcard/roms/ports/PortMaster");
    fs::create_dir_all(core.join("pylibs")).unwrap();
    fs::create_dir_all(core.join("libs")).unwrap();
    for name in ["control.txt", "device_info.txt", "funcs.txt", "pugwash"] {
        fs::write(core.join(name), "present").unwrap();
    }
    fs::write(core.join("pylibs/module"), "module").unwrap();
    let launcher = core.join("PortMaster.sh");
    fs::write(&launcher, "#!/bin/sh\n").unwrap();
    #[cfg(unix)]
    {
        let mut permissions = fs::metadata(&launcher).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&launcher, permissions).unwrap();
    }
    let image = core.join("libs/python_3.11.squashfs");
    fs::write(&image, b"nope-runtime").unwrap();
    let args = [
        "health",
        "--root",
        root.to_str().unwrap(),
        "--launcher",
        "/mnt/sdcard/roms/ports/Test.sh",
    ];
    let broken = Command::new(env!("CARGO_BIN_EXE_portkit"))
        .args(args)
        .output()
        .unwrap();
    let report: Value = serde_json::from_slice(&broken.stdout).unwrap();
    assert_eq!(report["report"]["python_runtime"], "python_3.11");
    assert_eq!(report["report"]["python_ready"], false);
    assert_eq!(report["report"]["status"], "damaged");

    fs::write(image, b"hsqs-runtime").unwrap();
    let ready = Command::new(env!("CARGO_BIN_EXE_portkit"))
        .args(args)
        .output()
        .unwrap();
    let report: Value = serde_json::from_slice(&ready.stdout).unwrap();
    assert_eq!(report["report"]["python_ready"], true);
    assert_eq!(report["report"]["status"], "healthy");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn unsafe_python_import_is_rejected_before_the_executable_runs() {
    let root = test_directory();
    let marker = root.join("python-ran");
    let python = root.join("marker-python");
    fs::write(
        &python,
        format!("#!/bin/sh\ntouch '{}'\nexit 0\n", marker.display()),
    )
    .unwrap();
    #[cfg(unix)]
    {
        let mut permissions = fs::metadata(&python).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&python, permissions).unwrap();
    }
    let mut config: Value =
        serde_json::from_str(include_str!("../../../config/config.json")).unwrap();
    let mut detail: Value =
        serde_json::from_str(include_str!("../../../config/platforms/generic.json")).unwrap();
    detail["python"]["imports"] = serde_json::json!(["sys;__import__('os')"]);
    let detail_bytes = serde_json::to_vec(&detail).unwrap();
    config["platforms"]["generic"]["sha256"] =
        portkit_core::config::fragment_sha256(&detail_bytes).into();
    fs::create_dir_all(root.join("platforms")).unwrap();
    fs::write(root.join("platforms/generic.json"), detail_bytes).unwrap();
    let config_path = root.join("unsafe-config.json");
    fs::write(&config_path, serde_json::to_vec(&config).unwrap()).unwrap();

    let mut args = arguments(&root, &python);
    args.extend([
        "--config".into(),
        config_path.display().to_string(),
        "--config-dir".into(),
        root.display().to_string(),
    ]);
    let output = Command::new(env!("CARGO_BIN_EXE_portkit"))
        .args(args)
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&output.stderr).contains("unsafe Python import name"));
    assert!(!marker.exists());
    fs::remove_dir_all(root).unwrap();
}
