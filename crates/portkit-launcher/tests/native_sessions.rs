// INPUT: Synthetic installation manifests and owned short-lived shell children.
// OUTPUT: Native validation, literal argv, lock, bounded logs and cancellation contracts.
// POS: No real game, private runtime, GPU or device is accessed.
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::Path,
    process::{Command, Stdio},
    time::{Duration, Instant},
};
use tempfile::TempDir;

fn helper() -> Command {
    Command::new(env!("CARGO_BIN_EXE_portkit-launcher"))
}

#[test]
fn bounded_cli_needs_no_system_timeout_and_keeps_literal_args_and_status() {
    let empty_path = tempfile::tempdir().unwrap();
    let output = helper()
        .env("PATH", empty_path.path())
        .args([
            "bounded",
            "--seconds",
            "2",
            "--",
            "/bin/sh",
            "-c",
            "printf '%s' \"$1\"; exit 23",
            "fixture",
            "literal $(no_execution) 中文",
        ])
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(23));
    assert_eq!(
        String::from_utf8(output.stdout).unwrap(),
        "literal $(no_execution) 中文"
    );
}

#[test]
fn bounded_cli_rejects_invalid_deadline_before_starting_command() {
    let temp = tempfile::tempdir().unwrap();
    let marker = temp.path().join("started");
    let output = helper()
        .args([
            "bounded",
            "--seconds",
            "0",
            "--",
            "/bin/sh",
            "-c",
            "touch \"$1\"",
            "fixture",
        ])
        .arg(&marker)
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(!marker.exists());
}
fn fixture(script: &str) -> (TempDir, Value) {
    let temp = tempfile::tempdir().unwrap();
    let canonical = temp.path().canonicalize().unwrap();
    let root = canonical.as_path();
    fs::create_dir(root.join("runtime")).unwrap();
    fs::write(root.join("runtime/game"), format!("#!/bin/sh\n{script}\n")).unwrap();
    fs::set_permissions(root.join("runtime/game"), fs::Permissions::from_mode(0o755)).unwrap();
    fs::write(root.join("probe"), "probe").unwrap();
    fs::write(root.join("wsi"), "wsi").unwrap();
    fs::write(root.join("wsi.json"), "{}").unwrap();
    let mut files = serde_json::Map::new();
    for name in ["runtime/game", "probe", "wsi", "wsi.json"] {
        files.insert(
            name.into(),
            json!(portkit_launcher::session::digest(&root.join(name)).unwrap()),
        );
    }
    let manifest = json!({"files":files,"profile":root.join("profile"),"session":{
        "id":"fixture","program":"runtime/game","args":["space 中文","literal $(no_execution)","{aspect}"],"working_directory":"{profile}/cache",
        "environment":{"SESSION_VALUE":"{profile}"},"presentations":{"native":{}},"default_presentation":"native","default_aspect":"4:3","aspects":["4:3","16:9"],"default_video_driver":"x11",
        "directories":["cache","logs"],"profile_candidates":[],"storage_roots":[root],"clear_env_prefixes":[],"clear_env_keys":[],"error_prefixes":["failure:"],"runtime_directory":"runtime",
        "probe":{"program":"probe","wsi_library":"wsi","wsi_manifest":"wsi.json","wsi_library_env":"FIXTURE_WSI","layer":"fixture"},
        "diagnostics":{"enable_env":"FIXTURE_DIAGNOSTICS","environment":{},"directories":[]}
    }});
    write_manifest(root, &manifest);
    (temp, manifest)
}
fn write_manifest(root: &Path, manifest: &Value) {
    fs::write(
        root.join("installation.json"),
        serde_json::to_vec(manifest).unwrap(),
    )
    .unwrap();
}
fn command(root: &Path) -> Command {
    let mut c = helper();
    c.arg("session")
        .arg("--root")
        .arg(root)
        .env("DISPLAY", ":fixture");
    c
}
fn wait_file(path: &Path) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !path.exists() {
        assert!(Instant::now() < deadline, "missing {}", path.display());
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn check_is_read_only_and_detects_tamper() {
    let (temp, _) = fixture("exit 0");
    let root = temp.path();
    assert!(command(root).arg("--check").status().unwrap().success());
    assert!(!root.join("profile").exists());
    fs::write(root.join("runtime/game"), "changed").unwrap();
    assert!(!command(root).arg("--check").status().unwrap().success());
    assert!(!root.join("profile").exists());
}
#[test]
fn literal_arguments_last_explicit_aspect_and_exit_code() {
    let (temp, _) = fixture("printf '%s\\n' \"$@\" > \"$SESSION_VALUE/args\"; exit 7");
    let root = temp.path();
    let output = command(root)
        .args(["--aspect", "4:3", "--aspect", "16:9"])
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(7));
    assert_eq!(
        fs::read_to_string(root.join("profile/args")).unwrap(),
        "space 中文\nliteral $(no_execution)\n16:9\n"
    );
}
#[test]
fn renderer_and_render_scale_select_owned_program_and_environment() {
    let (temp, mut manifest) = fixture("printf 'base' > \"$SESSION_VALUE/chosen\"");
    let root = temp.path();
    fs::write(root.join("runtime/gles"), "#!/bin/sh\nprintf '%s\\n' \"gles:$SCALE\" \"$@\" > \"$SESSION_VALUE/chosen\"\n").unwrap();
    fs::set_permissions(root.join("runtime/gles"), fs::Permissions::from_mode(0o755)).unwrap();
    manifest["files"]["runtime/gles"] = json!(portkit_launcher::session::digest(&root.join("runtime/gles")).unwrap());
    manifest["session"]["default_backend"] = json!("vulkan");
    manifest["session"]["backends"] = json!({
        "vulkan":{"program":"runtime/game","args":[],"environment":{},"presentations":["native"],"video_drivers":["x11"]},
        "gles":{"program":"runtime/gles","args":["{aspect}","{render_scale}"],"environment":{"SCALE":"{render_scale}"},"presentations":["native"],"video_drivers":["kmsdrm"]}
    });
    manifest["session"]["default_render_scale"] = json!("100");
    manifest["session"]["render_scales"] = json!({"100":"1","75":".75","50":".5"});
    write_manifest(root, &manifest);
    for args in [vec!["--backend","missing"],vec!["--render-scale","30"],vec!["--backend","vulkan","--video-driver","kmsdrm"]] {
        assert!(!command(root).args(args).status().unwrap().success());
        assert!(!root.join("profile").exists());
    }
    assert!(command(root).status().unwrap().success());
    assert_eq!(fs::read_to_string(root.join("profile/chosen")).unwrap(),"base");
    for (choice, expected) in [("100","1"),("75",".75"),("50",".5")] {
        assert!(command(root).args(["--backend","gles","--render-scale",choice,"--video-driver","kmsdrm","--aspect","16:9"]).status().unwrap().success());
        assert_eq!(fs::read_to_string(root.join("profile/chosen")).unwrap(),format!("gles:{expected}\n16:9\n{expected}\n"));
    }
    manifest["session"]["backends"]["gles"]["program"] = json!("runtime/unlisted");
    write_manifest(root, &manifest);
    assert!(!command(root).arg("--check").status().unwrap().success());
}
#[test]
fn bounded_tail_and_owned_receipts() {
    let (temp, _) =
        fixture("dd if=/dev/zero bs=1024 count=100 2>/dev/null; printf 'end\\n' >&2; exit 3");
    let root = temp.path();
    assert_eq!(
        command(root)
            .env("FIXTURE_DIAGNOSTICS", "1")
            .status()
            .unwrap()
            .code(),
        Some(3)
    );
    let tail = fs::read(root.join("profile/logs/last-error.log")).unwrap();
    assert_eq!(tail.len(), 65536);
    assert!(tail.ends_with(b"end\n"));
    let receipt: Value =
        serde_json::from_slice(&fs::read(root.join("profile/logs/current-session.json")).unwrap())
            .unwrap();
    assert_eq!(receipt["owned_child_reaped"], true);
    assert_eq!(receipt["returncode"], 3);
}
#[test]
fn eof_does_not_release_signal_ownership_or_profile_lock() {
    let (temp, _) = fixture(
        "exec 1>&- 2>&-; trap 'exit 42' TERM; echo ready > \"$SESSION_VALUE/ready\"; while :; do sleep 1; done",
    );
    let root = temp.path();
    let mut child = command(root)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    wait_file(&root.join("profile/ready"));
    assert!(!command(root).status().unwrap().success());
    unsafe {
        libc::kill(child.id() as i32, libc::SIGTERM);
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            assert_eq!(status.code(), Some(42));
            break;
        }
        if Instant::now() > deadline {
            child.kill().unwrap();
            panic!("supervisor ignored cancellation after EOF");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(command(root).arg("--check").status().unwrap().success());
}
#[test]
fn exec_view_keeps_pid_and_literal_argv() {
    let temp = tempfile::tempdir().unwrap();
    let child = Command::new(env!("CARGO_BIN_EXE_portkit-debug-launch"))
        .arg("--root")
        .arg(temp.path())
        .args([
            "--",
            "/bin/sh",
            "-c",
            "printf '%s\\n' \"$$\" \"$1\"; exit 9",
            "fixture",
            "literal $(no_execution)",
        ])
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let pid = child.id();
    let output = child.wait_with_output().unwrap();
    assert_eq!(output.status.code(), Some(9));
    assert_eq!(
        String::from_utf8(output.stdout).unwrap(),
        format!("{pid}\nliteral $(no_execution)\n")
    );
}

#[test]
fn release_launcher_has_no_debug_execution_command() {
    let temp = tempfile::tempdir().unwrap();
    let marker = temp.path().join("must-not-execute");
    let result = helper()
        .args(["exec-view", "--root"])
        .arg(temp.path())
        .args(["--", "/usr/bin/touch"])
        .arg(&marker)
        .output()
        .unwrap();
    assert!(!result.status.success());
    assert!(!marker.exists());
}
