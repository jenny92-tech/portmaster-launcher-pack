use std::fs;
use std::process::Command;

#[test]
fn json_merge_command_updates_a_file() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("config.json");
    fs::write(&path, r#"{"keep":true,"Language":1}"#).unwrap();

    let status = Command::new(env!("CARGO_BIN_EXE_portkit-launcher"))
        .args([
            "json",
            "merge",
            "--file",
            path.to_str().unwrap(),
            "--patch",
            r#"{"Language":7}"#,
        ])
        .status()
        .unwrap();

    assert!(status.success());
    let value: serde_json::Value = serde_json::from_slice(&fs::read(path).unwrap()).unwrap();
    assert_eq!(value["keep"], true);
    assert_eq!(value["Language"], 7);
}

#[test]
fn unity_command_requires_a_complete_button_mapping() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("config.toml");
    fs::write(&path, "displayWidth=1\n").unwrap();

    let status = Command::new(env!("CARGO_BIN_EXE_portkit-launcher"))
        .args([
            "unity",
            "configure",
            "--file",
            path.to_str().unwrap(),
            "--a",
            "BUTTON_A",
        ])
        .status()
        .unwrap();

    assert!(!status.success());
    assert_eq!(fs::read_to_string(path).unwrap(), "displayWidth=1\n");
}
