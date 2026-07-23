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

#[test]
fn unity_configure_upserts_resolution_and_remap_without_losing_other_sections() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("config.toml");
    fs::write(
        &path,
        "displayWidth=1\ndisplayHeight=2\nkeep=3\n\n[input.remap]\na = \"OLD\"\n\n[other]\nx=1\n",
    )
    .unwrap();

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
    })
    .unwrap();

    let contents = fs::read_to_string(path).unwrap();
    assert!(contents.contains("displayWidth=640\n"));
    assert!(contents.contains("displayHeight=480\n"));
    assert!(contents.contains("keep=3\n"));
    assert!(contents.contains(
        "[input.remap]\na       = \"BUTTON_B\"\nb       = \"BUTTON_A\"\nx       = \"BUTTON_Y\"\ny       = \"BUTTON_X\"\n"
    ));
    assert!(contents.contains("[other]\nx=1\n"));
}
