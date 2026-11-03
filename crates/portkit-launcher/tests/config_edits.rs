// INPUT:  portkit_launcher 配置/Runtime/同步接口、serde_json 与临时目录
// OUTPUT: 配置编辑、自然版本选择和增量同步的集成回归测试
// POS:    验证游戏启动辅助操作保留未知数据并拒绝无效变更
use std::fs;

use portkit_launcher::json::merge_file;
use portkit_launcher::runtime::latest_love;
use portkit_launcher::sync::{SyncRequest, sync_newer};
use portkit_launcher::unity::{ConfigureRequest, configure};
use serde_json::json;

#[test]
fn json_merge_preserves_unknown_values_and_updates_nested_objects() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("prefs.json");
    fs::write(
        &path,
        r#"{"unknown":9,"ints":{"keep":3,"width":1},"list":[1,2]}"#,
    )
    .unwrap();

    merge_file(&path, &json!({"ints":{"width":640,"height":480}})).unwrap();

    let value: serde_json::Value = serde_json::from_slice(&fs::read(path).unwrap()).unwrap();
    assert_eq!(value["unknown"], 9);
    assert_eq!(value["ints"]["keep"], 3);
    assert_eq!(value["ints"]["width"], 640);
    assert_eq!(value["ints"]["height"], 480);
    assert_eq!(value["list"], json!([1, 2]));
}

#[test]
fn latest_love_uses_natural_version_order() {
    let temp = tempfile::tempdir().unwrap();
    for version in ["love_11.9", "love_11.10", "love_invalid"] {
        let directory = temp.path().join(version);
        fs::create_dir(&directory).unwrap();
        if version != "love_invalid" {
            fs::write(directory.join("love.txt"), version).unwrap();
        }
    }

    assert_eq!(
        latest_love(temp.path()).unwrap(),
        temp.path().join("love_11.10/love.txt")
    );
}

#[test]
fn sync_newer_filters_extensions_and_does_not_replace_a_newer_destination() {
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("source");
    let destination = temp.path().join("destination");
    fs::create_dir(&source).unwrap();
    fs::create_dir(&destination).unwrap();
    fs::write(source.join("game.dll"), b"source").unwrap();
    fs::write(source.join("ignored.txt"), b"ignored").unwrap();

    let request = SyncRequest {
        source: source.clone(),
        destination: destination.clone(),
        extensions: vec!["dll".into(), "json".into()],
    };
    assert_eq!(sync_newer(&request).unwrap(), 1);
    assert_eq!(fs::read(destination.join("game.dll")).unwrap(), b"source");
    assert!(!destination.join("ignored.txt").exists());

    fs::write(destination.join("game.dll"), b"newer-destination").unwrap();
    let newer = std::fs::FileTimes::new().set_modified(std::time::SystemTime::now());
    fs::File::open(destination.join("game.dll"))
        .unwrap()
        .set_times(newer)
        .unwrap();
    assert_eq!(sync_newer(&request).unwrap(), 0);
    assert_eq!(
        fs::read(destination.join("game.dll")).unwrap(),
        b"newer-destination"
    );
}

#[test]
fn json_merge_rejects_invalid_existing_content_without_touching_it() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("prefs.json");
    fs::write(&path, b"not-json").unwrap();

    assert!(merge_file(&path, &json!({"Language":7})).is_err());
    assert_eq!(fs::read(path).unwrap(), b"not-json");
}

fn toml_document(path: &std::path::Path) -> toml_edit::DocumentMut {
    fs::read_to_string(path).unwrap().parse().unwrap()
}

#[test]
fn unity_configure_keeps_root_orphans_and_writes_fixed_tables() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("config.toml");
    fs::write(&path, "displayWidth=1\nkeep=3\n[paths]\ngame_files='./gamedata/'\n[input.remap]\na='OLD'\n[other]\nx=1\n").unwrap();
    configure(&ConfigureRequest {
        path: path.clone(),
        width: Some(640),
        height: Some(480),
        buttons: Some([
            "BUTTON_B".into(),
            "BUTTON_A".into(),
            "BUTTON_Y".into(),
            "BUTTON_X".into(),
        ]),
        ..Default::default()
    })
    .unwrap();
    let doc = toml_document(&path);
    assert_eq!(doc["displayWidth"].as_integer(), Some(1));
    assert_eq!(doc["device"]["displayWidth"].as_integer(), Some(640));
    assert_eq!(doc["device"]["displayHeight"].as_integer(), Some(480));
    assert_eq!(doc["input"]["remap"]["a"].as_str(), Some("BUTTON_B"));
    assert_eq!(doc["paths"]["game_files"].as_str(), Some("./gamedata/"));
    assert_eq!(doc["other"]["x"].as_integer(), Some(1));
}

#[test]
fn unity_configure_handles_quoted_headers_comments_arrays_and_multiline_strings() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("config.toml");
    let original = "banner = '''\n[device]\ndisplayWidth=999\n'''\n[\"device\"] # actual device\ndisplayWidth = 1280 # retain comment\ndisplayHeight=720\n[gpu] # render settings\nitems = [\n  '[paths]',\n]\n[paths] # keep the resource root\ngame_files='./gamedata/'\n";
    fs::write(&path, original).unwrap();
    configure(&ConfigureRequest {
        path: path.clone(),
        width: Some(960),
        height: Some(720),
        render_scale_percent: Some(75),
        ..Default::default()
    })
    .unwrap();
    let text = fs::read_to_string(&path).unwrap();
    let doc = toml_document(&path);
    assert_eq!(doc["banner"].as_str(), Some("[device]\ndisplayWidth=999\n"));
    assert_eq!(doc["device"]["displayWidth"].as_integer(), Some(960));
    assert_eq!(doc["gpu"]["items"][0].as_str(), Some("[paths]"));
    assert_eq!(doc["paths"]["game_files"].as_str(), Some("./gamedata/"));
    assert!(text.contains("# retain comment") && text.contains("# actual device"));
}

#[test]
fn unity_configure_rejects_duplicate_keys_instead_of_rewriting_invalid_toml() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("config.toml");
    let original = "[device]\ndisplayWidth=960\ndisplayWidth=640\ndisplayHeight=480\n";
    fs::write(&path, original).unwrap();
    let result = configure(&ConfigureRequest {
        path: path.clone(),
        width: Some(960),
        height: Some(720),
        ..Default::default()
    });
    assert_eq!(result.unwrap_err().kind(), std::io::ErrorKind::InvalidData);
    assert_eq!(fs::read_to_string(&path).unwrap(), original);
}

#[test]
fn unity_configure_rejects_wrong_sections_and_incomplete_dimensions() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("config.toml");
    let original = "displayWidth=1\n[device]\ndisplayWidth=2\n";
    fs::write(&path, original).unwrap();
    for section in ["gpu", "deivce", ""] {
        assert!(
            configure(&ConfigureRequest {
                path: path.clone(),
                section: Some(section.into()),
                width: Some(640),
                height: Some(480),
                ..Default::default()
            })
            .is_err()
        );
        assert_eq!(fs::read_to_string(&path).unwrap(), original);
    }
    for (width, height) in [
        (Some(640), None),
        (Some(0), Some(480)),
        (Some(32769), Some(480)),
    ] {
        assert!(
            configure(&ConfigureRequest {
                path: path.clone(),
                width,
                height,
                ..Default::default()
            })
            .is_err()
        );
        assert_eq!(fs::read_to_string(&path).unwrap(), original);
    }
}

#[test]
fn unity_memory_modes_only_write_runtime_and_keep_explicit_overrides() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("config.toml");
    let original = "[runtime] # runtime owns this\nstream_buffer_bytes=1024\n[gpu]\nmemory_mode='unrelated'\n[paths]\ngame_files='./gamedata/'\n";
    for mode in ["low_memory", "balanced", "performance"] {
        fs::write(&path, original).unwrap();
        configure(&ConfigureRequest {
            path: path.clone(),
            memory_mode: Some(mode.into()),
            ..Default::default()
        })
        .unwrap();
        let doc = toml_document(&path);
        assert_eq!(doc["runtime"]["memory_mode"].as_str(), Some(mode));
        assert_eq!(
            doc["runtime"]["stream_buffer_bytes"].as_integer(),
            Some(1024)
        );
        assert_eq!(doc["gpu"]["memory_mode"].as_str(), Some("unrelated"));
        assert_eq!(doc["paths"]["game_files"].as_str(), Some("./gamedata/"));
    }
    let before = fs::read(&path).unwrap();
    assert!(
        configure(&ConfigureRequest {
            path: path.clone(),
            memory_mode: Some("high".into()),
            ..Default::default()
        })
        .is_err()
    );
    assert_eq!(fs::read(&path).unwrap(), before);
}

#[test]
fn unity_explicit_render_scale_clears_exact_dimensions_and_preserves_linear_filter() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("config.toml");
    fs::write(&path,"[device]\ndisplayWidth=960\ndisplayHeight=720\n[gpu] # gpu\nrenderScaleSharp=false\nrenderScaleDivisor=4\nrenderScaleLinear=true\ntextureMaxDim=384\nrenderWidth=800\nrenderHeight=600\n").unwrap();
    let dimensions = configure(&ConfigureRequest {
        path: path.clone(),
        render_scale_percent: Some(75),
        ..Default::default()
    })
    .unwrap();
    let doc = toml_document(&path);
    assert_eq!(
        (dimensions.render_width, dimensions.render_height),
        (720, 540)
    );
    assert_eq!(doc["gpu"]["renderScaleSharp"].as_bool(), Some(false));
    assert_eq!(doc["gpu"]["renderWidth"].as_integer(), Some(0));
    assert_eq!(doc["gpu"]["renderHeight"].as_integer(), Some(0));
    assert_eq!(doc["gpu"]["textureMaxDim"].as_integer(), Some(384));
    assert!(doc["gpu"].get("renderScaleDivisor").is_none());
    assert!(doc["gpu"].get("renderScaleLinear").is_none());
}

#[test]
fn game_preset_preserves_640_by_480_rendering_on_a_960_by_720_output() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("config.toml");
    fs::write(
        &path,
        "[gpu]\nrenderWidth=640\nrenderHeight=480\nrenderScaleSharp=true\n",
    )
    .unwrap();
    let dimensions = configure(&ConfigureRequest {
        path: path.clone(),
        width: Some(960),
        height: Some(720),
        memory_mode: Some("balanced".into()),
        ..Default::default()
    })
    .unwrap();
    assert_eq!(
        (dimensions.output_width, dimensions.output_height),
        (960, 720)
    );
    assert_eq!(
        (dimensions.render_width, dimensions.render_height),
        (640, 480)
    );
    assert_eq!(
        toml_document(&path)["gpu"]["renderWidth"].as_integer(),
        Some(640)
    );
}

#[test]
fn wayland_native_keeps_exact_buffers_and_rejects_implicit_filter_changes() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("config.toml");
    let original = "[device]\ndisplayWidth=960\ndisplayHeight=720\n[gpu]\npresentationBackend='wayland_native'\nrenderWidth=640\nrenderHeight=480\nrenderScaleSharp=false\n";
    fs::write(&path, original).unwrap();
    configure(&ConfigureRequest {
        path: path.clone(),
        render_scale_percent: Some(75),
        ..Default::default()
    })
    .unwrap();
    let doc = toml_document(&path);
    assert_eq!(doc["gpu"]["renderWidth"].as_integer(), Some(720));
    assert_eq!(doc["gpu"]["renderHeight"].as_integer(), Some(540));
    assert_eq!(doc["gpu"]["renderScaleSharp"].as_bool(), Some(false));
    let invalid = original.replace("renderScaleSharp=false", "renderScaleSharp=true");
    fs::write(&path, &invalid).unwrap();
    assert!(
        configure(&ConfigureRequest {
            path: path.clone(),
            render_scale_percent: Some(75),
            ..Default::default()
        })
        .is_err()
    );
    assert_eq!(fs::read_to_string(&path).unwrap(), invalid);
}

#[test]
fn unity_invalid_render_or_table_conflict_never_publishes_partial_output() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("config.toml");
    for original in ["[gpu]\nrenderScalePercent=100\n", "gpu=false\n"] {
        fs::write(&path, original).unwrap();
        assert!(
            configure(&ConfigureRequest {
                path: path.clone(),
                width: Some(960),
                height: Some(720),
                render_scale_percent: Some(60),
                ..Default::default()
            })
            .is_err()
        );
        assert_eq!(fs::read_to_string(&path).unwrap(), original);
    }
    fs::write(&path, "gpu=false\n").unwrap();
    assert!(
        configure(&ConfigureRequest {
            path: path.clone(),
            width: Some(960),
            height: Some(720),
            render_scale_percent: Some(75),
            ..Default::default()
        })
        .is_err()
    );
    assert_eq!(fs::read_to_string(&path).unwrap(), "gpu=false\n");
}

#[test]
fn unity_geometry_matches_rudroid_numeric_and_filter_conversions() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("config.toml");
    fs::write(&path, "[device]\ndisplayWidth=960.0\ndisplayHeight=720.0\n[gpu]\nrenderWidth=false\nrenderHeight=0.0\nrenderScalePercent=75.0\nrenderScaleSharp=0\n").unwrap();
    let dimensions = configure(&ConfigureRequest {
        path: path.clone(),
        memory_mode: Some("balanced".into()),
        ..Default::default()
    })
    .unwrap();
    assert_eq!(
        (dimensions.render_width, dimensions.render_height),
        (720, 540)
    );
    configure(&ConfigureRequest {
        path: path.clone(),
        render_scale_percent: Some(50),
        ..Default::default()
    })
    .unwrap();
    assert_eq!(
        toml_document(&path)["gpu"]["renderScaleSharp"].as_bool(),
        Some(false)
    );
}

#[test]
fn unity_invalid_backend_or_filter_never_changes_the_selected_config() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("config.toml");
    for original in [
        "gpu=false\n",
        "[gpu]\npresentationBackend='guess'\n",
        "[gpu]\nrenderScaleSharp='false'\n",
        "[gpu]\nrenderScalePercent=75.5\n",
    ] {
        fs::write(&path, original).unwrap();
        assert!(
            configure(&ConfigureRequest {
                path: path.clone(),
                memory_mode: Some("balanced".into()),
                ..Default::default()
            })
            .is_err()
        );
        assert_eq!(fs::read_to_string(&path).unwrap(), original);
    }
}

#[test]
fn unity_graphics_switch_preserves_paths_arguments_and_other_intent_values() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("config.toml");
    fs::write(&path, "[paths]\ngame_files='./gamedata/'\n[package.mainIntentBundle]\nkeep=7\nunity='-logFile \"a  b.log\" -force-gles30 -force-vulkan -force-gfx-mt -label=not-force-vulkan'\n").unwrap();
    for (selection, api, flag) in [
        ("vulkan", "vulkan", "-force-vulkan"),
        ("gles30", "gles", "-force-gles30"),
        ("gles32", "gles", "-force-gles32"),
    ] {
        for _ in 0..2 {
            configure(&ConfigureRequest {
                path: path.clone(),
                graphics_api: Some(selection.into()),
                ..Default::default()
            })
            .unwrap();
            let doc = toml_document(&path);
            assert_eq!(doc["gpu"]["graphicsApi"].as_str(), Some(api));
            assert_eq!(
                doc["package"]["mainIntentBundle"]["unity"].as_str(),
                Some(
                    format!("-logFile \"a  b.log\" -force-gfx-mt -label=not-force-vulkan {flag}")
                        .as_str()
                )
            );
            assert_eq!(
                doc["package"]["mainIntentBundle"]["keep"].as_integer(),
                Some(7)
            );
            assert_eq!(doc["paths"]["game_files"].as_str(), Some("./gamedata/"));
        }
    }
}

#[test]
fn unity_vulkan_rejects_unsupported_filters_legacy_presentation_and_bad_arguments_atomically() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("config.toml");
    for original in [
        "[gpu]\nvulkanRenderFilter='sharp'\n",
        "[gpu]\nvulkanRenderFilter=true\n",
        "[gpu]\nrenderScaleDivisor=2\n",
        "[gpu]\npresentationBackend='wayland_native'\nrenderWidth=640\nrenderHeight=480\nrenderScaleSharp=false\n",
        "[package.mainIntentBundle]\nunity=42\n",
        "[package.mainIntentBundle]\nunity='-label \"unfinished'\n",
        "[package.mainIntentBundle]\nunity='unfinished\\'\n",
    ] {
        fs::write(&path, original).unwrap();
        assert!(
            configure(&ConfigureRequest {
                path: path.clone(),
                graphics_api: Some("vulkan".into()),
                memory_mode: Some("performance".into()),
                ..Default::default()
            })
            .is_err(),
            "{original}"
        );
        assert_eq!(fs::read_to_string(&path).unwrap(), original);
    }
    fs::write(
        &path,
        "[gpu]\nrenderWidth=640\nrenderHeight=480\nrenderScalePercent=75\n",
    )
    .unwrap();
    configure(&ConfigureRequest {
        path: path.clone(),
        graphics_api: Some("vulkan".into()),
        render_scale_percent: Some(100),
        ..Default::default()
    })
    .unwrap();
    assert_eq!(
        toml_document(&path)["gpu"]["renderWidth"].as_integer(),
        Some(0)
    );
}

#[test]
fn typed_patch_preserves_resource_paths_after_hud_and_hook_sections() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("config.toml");
    fs::write(&path,"[ui_layout]\nclass='old'\nkeep=true\n[[il2cpp_patch]]\nclass='old'\n[paths]\ngame_files='./gamedata/'\ninternal_data_path='./conf'\n[package]\npackageName='game'\n").unwrap();
    portkit_launcher::toml::merge_file(
        &path,
        &json!({
            "ui_layout":{"class":"UI_InGame_Main","hide":[184,192]},
            "il2cpp_patch":[{"class":"PlayerController","field":16,"mult":0.2}],
            "runtime":{"memory_mode":"performance"}
        }),
    )
    .unwrap();
    let doc = toml_document(&path);
    assert_eq!(doc["paths"]["game_files"].as_str(), Some("./gamedata/"));
    assert_eq!(doc["paths"]["internal_data_path"].as_str(), Some("./conf"));
    assert_eq!(doc["package"]["packageName"].as_str(), Some("game"));
    assert_eq!(doc["ui_layout"]["keep"].as_bool(), Some(true));
    assert_eq!(doc["il2cpp_patch"][0]["mult"].as_float(), Some(0.2));
}

#[test]
fn typed_patch_rejects_invalid_data_without_creating_or_modifying_files() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("config.toml");
    assert!(
        portkit_launcher::toml::merge_file(&path, &json!({"gpu":{"textureMaxDim":384}})).is_err()
    );
    assert!(!path.exists());
    let original = "[runtime]\nmemory_mode='balanced'\n";
    fs::write(&path, original).unwrap();
    for patch in [
        json!({"runtime":{"memory_mode":"performance"},"z":u64::MAX}),
        json!({"runtime":{"memory_mode":"performance"},"z":[null]}),
        json!([1, 2]),
    ] {
        assert!(portkit_launcher::toml::merge_file(&path, &patch).is_err());
        assert_eq!(fs::read_to_string(&path).unwrap(), original);
    }
}

#[test]
fn typed_patch_deletes_only_named_obsolete_keys_and_keeps_inline_tables() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("config.toml");
    fs::write(&path,"runtime={memory_mode='balanced',keep=3}\n[unity]\nframe_sync_interval_us=22222\nkeep=true\n").unwrap();
    portkit_launcher::toml::merge_file(&path,&json!({"runtime":{"memory_mode":"low_memory"},"unity":{"frame_sync_interval_us":null,"target_fps":45},"loader":{"file_backed_elf":null}})).unwrap();
    let doc = toml_document(&path);
    assert_eq!(doc["runtime"]["keep"].as_integer(), Some(3));
    assert_eq!(doc["runtime"]["memory_mode"].as_str(), Some("low_memory"));
    assert_eq!(doc["unity"]["target_fps"].as_integer(), Some(45));
    assert!(doc["unity"].get("frame_sync_interval_us").is_none());
    assert!(doc.get("loader").is_none());
}

#[test]
fn unity_vulkan_scales_preserve_gles_filter_and_return_to_the_same_render_policy() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("config.toml");
    for percent in [100, 75, 50] {
        fs::write(&path,"[device]\ndisplayWidth=960\ndisplayHeight=720\n[gpu]\nrenderScaleSharp=true\n[package.mainIntentBundle]\nunity='-logFile \"keep two words\" -force-gles30'\n").unwrap();
        for api in ["vulkan", "gles", "vulkan"] {
            configure(&ConfigureRequest {
                path: path.clone(),
                graphics_api: Some(api.into()),
                render_scale_percent: Some(percent),
                memory_mode: Some("performance".into()),
                ..Default::default()
            })
            .unwrap();
            let doc = toml_document(&path);
            assert_eq!(doc["gpu"]["graphicsApi"].as_str(), Some(api));
            assert_eq!(
                doc["gpu"]["renderScalePercent"].as_integer(),
                Some(i64::from(percent))
            );
            assert_eq!(doc["gpu"]["renderScaleSharp"].as_bool(), Some(true));
            assert_eq!(doc["gpu"]["vulkanRenderFilter"].as_str(), Some("linear"));
            assert_eq!(doc["runtime"]["memory_mode"].as_str(), Some("performance"));
        }
    }
    fs::write(
        &path,
        "[package.mainIntentBundle]\nunity='-force-gles20 -force-vulkan -other'\n",
    )
    .unwrap();
    configure(&ConfigureRequest {
        path: path.clone(),
        graphics_api: Some("gles".into()),
        ..Default::default()
    })
    .unwrap();
    assert_eq!(
        toml_document(&path)["package"]["mainIntentBundle"]["unity"].as_str(),
        Some("-force-gles20 -other")
    );
    fs::write(
        &path,
        "[gpu]\nrenderWidth=640\nrenderHeight=480\nrenderScalePercent=75\n",
    )
    .unwrap();
    configure(&ConfigureRequest {
        path: path.clone(),
        graphics_api: Some("vulkan".into()),
        ..Default::default()
    })
    .unwrap();
    assert_eq!(
        toml_document(&path)["gpu"]["renderWidth"].as_integer(),
        Some(640)
    );
}

#[test]
fn scale_filter_selection_preserves_each_backends_settings_and_rejects_atomically() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("config.toml");
    fs::write(
        &path,
        "[gpu]\nrenderScaleSharp=false\n[paths]\ngame_files='keep/'\n",
    )
    .unwrap();
    let apply = |api: &str, filter: &str| {
        configure(&ConfigureRequest {
            path: path.clone(),
            graphics_api: Some(api.into()),
            render_filter: Some(filter.into()),
            ..Default::default()
        })
    };
    apply("gles", "sharp").unwrap();
    apply("vulkan", "linear").unwrap();
    assert_eq!(
        toml_document(&path)["gpu"]["renderScaleSharp"].as_bool(),
        Some(true)
    );
    assert_eq!(
        toml_document(&path)["gpu"]["vulkanRenderFilter"].as_str(),
        Some("linear")
    );
    for (api, filter) in [("gles", "bad"), ("vulkan", "sharp")] {
        let before = fs::read(&path).unwrap();
        assert!(apply(api, filter).is_err());
        assert_eq!(fs::read(&path).unwrap(), before);
    }
    apply("gles", "config").unwrap();
    assert_eq!(
        toml_document(&path)["gpu"]["renderScaleSharp"].as_bool(),
        Some(true)
    );
    apply("gles", "linear").unwrap();
    assert_eq!(
        toml_document(&path)["gpu"]["renderScaleSharp"].as_bool(),
        Some(false)
    );
    assert_eq!(
        toml_document(&path)["paths"]["game_files"].as_str(),
        Some("keep/")
    );
}
