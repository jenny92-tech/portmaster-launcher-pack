// INPUT:  构建后的 portkit-launcher、临时配置文件与 std::process::Command
// OUTPUT: JSON/TOML 合并、固定配置路径和非法参数无写入的 CLI 回归测试
// POS:    从子进程入口验证启动辅助命令的公开行为
use std::fs;
use std::process::Command;

#[test]
fn unity_graphics_cli_keeps_the_selected_file_and_rejects_invalid_choices() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("config.toml");
    let original = "[package]\npackageName='keep'\n";
    fs::write(&path, original).unwrap();
    for api in ["guess", "GLES", "gles99", "vulkan "] {
        let result = Command::new(env!("CARGO_BIN_EXE_portkit-launcher"))
            .args([
                "unity",
                "configure",
                "--file",
                path.to_str().unwrap(),
                "--graphics-api",
                api,
            ])
            .output()
            .unwrap();
        assert!(!result.status.success());
        assert_eq!(fs::read_to_string(&path).unwrap(), original);
    }
    let result = Command::new(env!("CARGO_BIN_EXE_portkit-launcher"))
        .args([
            "unity",
            "configure",
            "--file",
            path.to_str().unwrap(),
            "--graphics-api",
            "vulkan",
        ])
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    let doc: toml_edit::DocumentMut = fs::read_to_string(&path).unwrap().parse().unwrap();
    assert_eq!(doc["gpu"]["graphicsApi"].as_str(), Some("vulkan"));
}

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
fn json_merge_rejects_misspelled_and_duplicate_output_options() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("prefs.json");
    let original = r#"{"Language":1,"keep":true}"#;
    for options in [["--flie", "decoy.json"], ["--file", "decoy.json"]] {
        fs::write(&path, original).unwrap();
        let result = Command::new(env!("CARGO_BIN_EXE_portkit-launcher"))
            .current_dir(temp.path())
            .args([
                "json",
                "merge",
                "--file",
                path.to_str().unwrap(),
                "--patch",
                r#"{"Language":7}"#,
            ])
            .args(options)
            .output()
            .unwrap();
        assert!(!result.status.success());
        assert_eq!(fs::read_to_string(&path).unwrap(), original);
        assert!(!temp.path().join("decoy.json").exists());
    }
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

#[test]
fn unity_command_rejects_an_unsupported_render_percent() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("config.toml");
    fs::write(&path, "[gpu]\nrenderScalePercent = 100\n").unwrap();

    let status = Command::new(env!("CARGO_BIN_EXE_portkit-launcher"))
        .args([
            "unity",
            "configure",
            "--file",
            path.to_str().unwrap(),
            "--render-percent",
            "60",
        ])
        .status()
        .unwrap();

    assert!(!status.success());
    assert_eq!(
        fs::read_to_string(path).unwrap(),
        "[gpu]\nrenderScalePercent = 100\n"
    );
}

#[test]
fn unity_command_uses_the_selected_file_and_reports_preserved_render_dimensions() {
    let temp = tempfile::tempdir().unwrap();
    let game = temp.path().join("game with spaces");
    let decoy = temp.path().join("unrelated cwd");
    fs::create_dir_all(&game).unwrap();
    fs::create_dir_all(&decoy).unwrap();
    let path = game.join("config.toml");
    fs::write(&path, "[paths]\ngame_files='./gamedata/'\n[gpu] # keep exact render size\nrenderWidth=640\nrenderHeight=480\n").unwrap();
    fs::write(decoy.join("config.toml"), "sentinel='leave alone'\n").unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_portkit-launcher"))
        .current_dir(&decoy)
        .args([
            "unity",
            "configure",
            "--file",
            path.to_str().unwrap(),
            "--width",
            "960",
            "--height",
            "720",
            "--memory-mode",
            "low_memory",
            "--print-dimensions",
            "true",
        ])
        .output()
        .unwrap();
    assert!(output.status.success(), "{:?}", output);
    assert_eq!(output.stdout, b"960 720 640 480\n");
    let config = fs::read_to_string(path)
        .unwrap()
        .parse::<toml_edit::DocumentMut>()
        .unwrap();
    assert_eq!(
        config["runtime"]["memory_mode"].as_str(),
        Some("low_memory")
    );
    assert_eq!(config["paths"]["game_files"].as_str(), Some("./gamedata/"));
    assert!(config.get("memory_mode").is_none());
    assert_eq!(
        fs::read_to_string(decoy.join("config.toml")).unwrap(),
        "sentinel='leave alone'\n"
    );
}

#[test]
fn configuration_commands_reject_unknown_duplicate_and_incomplete_options_without_writes() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("config.toml");
    let original = "[runtime]\nmemory_mode='balanced'\n";
    let cases: &[(&str, &str, &[&str])] = &[
        (
            "unity",
            "configure",
            &[
                "--memory-mode",
                "performance",
                "--memory-mdoe",
                "low_memory",
            ],
        ),
        (
            "unity",
            "configure",
            &["--memory-mode", "balanced", "--memory-mode", "performance"],
        ),
        (
            "unity",
            "configure",
            &["--memory-mode", "performance", "--print-dimensions", "yes"],
        ),
        ("unity", "configure", &["--width", "960"]),
        ("toml", "merge", &["--patch", "{}", "--section", "paths"]),
        ("toml", "merge", &["--patch", "{}", "--patch", "{}"]),
    ];
    for (group, command, options) in cases {
        fs::write(&path, original).unwrap();
        let output = Command::new(env!("CARGO_BIN_EXE_portkit-launcher"))
            .args([*group, *command, "--file", path.to_str().unwrap()])
            .args(*options)
            .output()
            .unwrap();
        assert!(!output.status.success(), "accepted {options:?}");
        assert_eq!(fs::read_to_string(&path).unwrap(), original, "{options:?}");
    }
}

#[test]
fn toml_merge_command_preserves_resource_paths_after_the_edited_table() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("config.toml");
    fs::write(
        &path,
        "[ui_layout]\nkeep=true\n[paths] # must survive\ngame_files='./gamedata/'\n",
    )
    .unwrap();
    let status = Command::new(env!("CARGO_BIN_EXE_portkit-launcher"))
        .args([
            "toml",
            "merge",
            "--file",
            path.to_str().unwrap(),
            "--patch",
            r#"{"ui_layout":{"enabled":true},"runtime":{"memory_mode":"performance"}}"#,
        ])
        .status()
        .unwrap();
    assert!(status.success());
    let config = fs::read_to_string(path)
        .unwrap()
        .parse::<toml_edit::DocumentMut>()
        .unwrap();
    assert_eq!(config["paths"]["game_files"].as_str(), Some("./gamedata/"));
    assert_eq!(config["ui_layout"]["keep"].as_bool(), Some(true));
    assert_eq!(config["ui_layout"]["enabled"].as_bool(), Some(true));
}
