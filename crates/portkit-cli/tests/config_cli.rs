use std::fs;
use std::process::Command;

#[test]
fn select_detail_is_root_only_and_has_fixed_tsv_fields() {
    let fixture =
        std::env::temp_dir().join(format!("portkit-select-detail-{}", std::process::id()));
    let _ = fs::remove_dir_all(&fixture);
    fs::create_dir_all(&fixture).unwrap();
    let root = fixture.join("remote-root.json");
    fs::write(&root, include_bytes!("../../../config/config.json")).unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_portkit"))
        .args([
            "config",
            "select-detail",
            "--config",
            root.to_str().unwrap(),
            "--launcher",
            "/mnt/SDCARD/Roms/PORTS/Test.sh",
            "--env",
            "CFW_NAME=TrimUI",
            "--format",
            "tsv",
        ])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let rows: Vec<_> = String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .map(|line| line.split_once('\t').unwrap().0.to_owned())
        .collect();
    assert_eq!(
        rows,
        [
            "schema",
            "config_version",
            "platform_id",
            "detail_ref",
            "detail_sha256"
        ]
    );
    let _ = fs::remove_dir_all(fixture);
}

#[test]
fn unreadable_optional_remote_config_uses_packaged_fallback() {
    let config_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../config");
    let missing = std::env::temp_dir().join(format!(
        "portkit-missing-remote-{}-config.json",
        std::process::id()
    ));
    let _ = fs::remove_file(&missing);
    let output = Command::new(env!("CARGO_BIN_EXE_portkit"))
        .args([
            "detect",
            "--config-dir",
            config_dir.to_str().unwrap(),
            "--remote-config",
            missing.to_str().unwrap(),
            "--launcher",
            "/mnt/SDCARD/Roms/PORTS/Test.sh",
            "--env",
            "CFW_NAME=TrimUI",
        ])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let value: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(value["config_origin"], "embedded");
    assert_eq!(value["resolution"]["platform_id"], "trimui");
}
