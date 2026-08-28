use std::fs;
use std::io::{Read as _, Write as _};
use std::net::{Shutdown, TcpStream};
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use appmanager_service::{EmbeddedAction, EmbeddedRequest, EmbeddedService, ServiceEvent};
use serde_json::{Value, json};

fn rooted(root: &Path, device_path: &Path) -> PathBuf {
    assert!(device_path.is_absolute(), "device path must be absolute");
    root.join(device_path.strip_prefix("/").unwrap())
}

fn event(service: &EmbeddedService, task_id: u64) -> ServiceEvent {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        if let Some(event) = service.poll()
            && event.task_id == task_id
            && event.status != "progress"
        {
            return event;
        }
        assert!(Instant::now() < deadline, "task {task_id} did not finish");
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn run(service: &EmbeddedService, kind: &str) -> ServiceEvent {
    let task_id = service.start(kind, None).unwrap();
    event(service, task_id)
}

fn apply(service: &EmbeddedService, actions: Vec<EmbeddedAction>, revision: &str) -> ServiceEvent {
    let task_id = service
        .start_at_revision("apply", Some(actions), Some(revision.to_owned()))
        .unwrap();
    event(service, task_id)
}

fn action(kind: &str, path: impl AsRef<Path>) -> EmbeddedAction {
    EmbeddedAction {
        kind: kind.to_owned(),
        arg: path.as_ref().to_string_lossy().into_owned(),
        source_identity: None,
        replace_existing: false,
        password: None,
    }
}

fn snapshot(service: &EmbeddedService) -> Value {
    service.snapshot().unwrap()
}

fn revision(snapshot: &Value) -> &str {
    snapshot["revision"].as_str().unwrap()
}

fn make_zip(path: &Path, entries: &[(&str, &[u8])]) {
    let file = fs::File::create(path).unwrap();
    let mut zip = zip::ZipWriter::new(file);
    let options = zip::write::SimpleFileOptions::default();
    for (name, bytes) in entries {
        zip.start_file(*name, options).unwrap();
        zip.write_all(bytes).unwrap();
    }
    zip.finish().unwrap();
}

fn install_candidate(
    service: &EmbeddedService,
    candidate: &Value,
    replace_existing: bool,
) -> ServiceEvent {
    let task_id = service
        .start(
            "install-zips",
            Some(vec![EmbeddedAction {
                kind: "INSTALL_ZIP".to_owned(),
                arg: candidate["path"].as_str().unwrap().to_owned(),
                source_identity: Some(candidate["source_identity"].as_str().unwrap().to_owned()),
                replace_existing,
                password: None,
            }]),
        )
        .unwrap();
    event(service, task_id)
}

fn http(port: u16, request: Vec<u8>) -> Vec<u8> {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    stream.write_all(&request).unwrap();
    stream.shutdown(Shutdown::Write).unwrap();
    let mut response = Vec::new();
    stream.read_to_end(&mut response).unwrap();
    response
}

fn request(method: &str, path: &str, token: Option<&str>, body: &[u8]) -> Vec<u8> {
    let mut head = format!(
        "{method} {path} HTTP/1.1\r\nHost: localhost\r\nContent-Length: {}\r\n",
        body.len()
    );
    if let Some(token) = token {
        head.push_str(&format!("X-AppManager-Token: {token}\r\n"));
    }
    head.push_str("\r\n");
    let mut request = head.into_bytes();
    request.extend_from_slice(body);
    request
}

fn status(response: &[u8]) -> u16 {
    let line = response.split(|byte| *byte == b'\n').next().unwrap();
    std::str::from_utf8(line)
        .unwrap()
        .split_whitespace()
        .nth(1)
        .unwrap()
        .parse()
        .unwrap()
}

fn response_json(response: &[u8]) -> Value {
    let offset = response
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .unwrap()
        + 4;
    serde_json::from_slice(&response[offset..]).unwrap()
}

fn web_snapshot(port: u16, token: &str) -> Value {
    let response = http(port, request("GET", "/api/snapshot", Some(token), b""));
    assert_eq!(
        status(&response),
        200,
        "{}",
        String::from_utf8_lossy(&response)
    );
    response_json(&response)
}

fn upload(port: u16, token: &str, filename: &str, bytes: &[u8], replace_existing: bool) -> Vec<u8> {
    let mut head = format!(
        "POST /api/upload HTTP/1.1\r\nHost: localhost\r\nX-AppManager-Token: {token}\r\nX-Filename: {filename}\r\nX-AppManager-Replace: {}\r\nContent-Length: {}\r\n\r\n",
        u8::from(replace_existing),
        bytes.len(),
    )
    .into_bytes();
    head.extend_from_slice(bytes);
    http(port, head)
}

fn web_manage(
    port: u16,
    token: &str,
    action: &str,
    paths: Vec<String>,
    revision: &Value,
) -> Vec<u8> {
    let body = serde_json::to_vec(&json!({
        "action": action,
        "revision": revision,
        "paths": paths,
    }))
    .unwrap();
    http(port, request("POST", "/api/manage", Some(token), &body))
}

#[test]
fn every_public_business_path_runs_in_the_selected_device_profile() {
    let Ok(profile) = std::env::var("PAM_LAB_PROFILE") else {
        eprintln!("PAM_LAB_PROFILE is not set; device-profile E2E is a lab-only test");
        return;
    };
    assert!(matches!(profile.as_str(), "trimui" | "miniloong"));
    let root = PathBuf::from(std::env::var("PAM_NATIVE_ROOT").unwrap());
    let launcher = PathBuf::from(std::env::var("PAM_LAB_LAUNCHER").unwrap());
    let card = PathBuf::from(std::env::var("PAM_LAB_CARD_ROOT").unwrap());
    let launcher_on_disk = rooted(&root, &launcher);
    fs::create_dir_all(launcher_on_disk.parent().unwrap()).unwrap();
    fs::write(&launcher_on_disk, b"#!/bin/sh\n").unwrap();

    let app_root = root.join("pam-app");
    for relative in ["bin", "share", "state", "trash", "love_ui"] {
        fs::create_dir_all(app_root.join(relative)).unwrap();
    }
    let helper = app_root.join("bin/gptokeyb");
    fs::write(&helper, b"#!/bin/sh\nsleep 30\n").unwrap();
    fs::set_permissions(&helper, fs::Permissions::from_mode(0o755)).unwrap();

    let config = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../config");
    let service = EmbeddedService::new(EmbeddedRequest {
        source_dir: launcher.parent().unwrap().to_path_buf(),
        launcher: launcher.clone(),
        app_root: app_root.clone(),
        config_dir: Some(config),
        remote_config_dir: None,
    })
    .unwrap();

    let initial = snapshot(&service);
    assert_eq!(initial["env"]["param_device"], profile);
    assert_eq!(initial["env"]["capability_install_ports"], true);
    assert_eq!(
        initial["env"]["capability_install_apps"],
        Value::Bool(profile == "trimui")
    );
    let scripts = PathBuf::from(initial["env"]["scripts_dir"].as_str().unwrap());
    let games = PathBuf::from(initial["env"]["gamedirs_dir"].as_str().unwrap());
    let frontend = PathBuf::from(initial["env"]["portmaster_frontend_dir"].as_str().unwrap());
    fs::create_dir_all(&scripts).unwrap();
    fs::create_dir_all(&games).unwrap();
    // TrimUI's configured APP root is the parent of its PortMaster frontend.
    // Materialize the real Config-resolved parent instead of teaching this
    // test a second copy of the device path.
    fs::create_dir_all(&frontend).unwrap();

    // The launcher name is presentation only. Its data association comes
    // exclusively from the script body and deliberately uses another name.
    let original_script = scripts.join("Z_Custom.Name [CN].sh");
    let original_data = games.join("TotallyUnrelatedData");
    fs::create_dir_all(&original_data).unwrap();
    fs::write(original_data.join("save.dat"), b"save").unwrap();
    fs::write(
        &original_script,
        b"#!/bin/sh\nGAMEDIR=\"$directory/ports/TotallyUnrelatedData\"\n",
    )
    .unwrap();
    let refresh = run(&service, "inventory-refresh");
    assert_eq!(refresh.status, "complete", "{}", refresh.data);
    let current = snapshot(&service);
    let port = current["inventory"]["ports"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["path"] == original_script.to_string_lossy().as_ref())
        .unwrap();
    assert_eq!(port["script"], "Z_Custom.Name [CN].sh");
    assert_eq!(port["data_path"], original_data.to_string_lossy().as_ref());

    service
        .run_script(original_script.to_string_lossy().into_owned())
        .unwrap();
    assert_eq!(
        fs::read_to_string(app_root.join("game_to_launch.txt")).unwrap(),
        original_script.to_string_lossy()
    );
    let unmanaged = scripts.join("not-in-inventory.txt");
    fs::write(&unmanaged, b"no").unwrap();
    assert!(
        service
            .run_script(unmanaged.to_string_lossy().into_owned())
            .is_err()
    );

    service
        .start_input_helper("pam-device-profile-e2e")
        .unwrap();
    service.stop_input_helper();

    // A changed inventory must reject an old selection without touching it.
    let stale = revision(&current).to_owned();
    fs::create_dir_all(games.join("new-orphan")).unwrap();
    let rejected = apply(
        &service,
        vec![
            action("TRASH", &original_script),
            action("TRASH", &original_data),
        ],
        &stale,
    );
    assert_eq!(rejected.status, "error");
    assert!(original_script.is_file());
    assert!(original_data.is_dir());

    run(&service, "inventory-refresh");
    let current = snapshot(&service);
    let removed = apply(
        &service,
        vec![
            action("TRASH", &original_script),
            action("TRASH", &original_data),
        ],
        revision(&current),
    );
    assert_eq!(removed.status, "complete", "{}", removed.data);
    assert_eq!(removed.data["operation"]["failed"], false);
    assert!(!original_script.exists());
    assert!(!original_data.exists());

    let trashed = snapshot(&service);
    let trash_paths = trashed["inventory"]["trash"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| PathBuf::from(item["path"].as_str().unwrap()))
        .collect::<Vec<_>>();
    assert!(trash_paths.len() >= 2);
    fs::write(&original_script, b"replacement").unwrap();
    run(&service, "inventory-refresh");
    let conflict_snapshot = snapshot(&service);
    let script_in_trash = conflict_snapshot["inventory"]["trash"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| PathBuf::from(item["path"].as_str().unwrap()))
        .find(|path| path.file_name() == original_script.file_name())
        .unwrap();
    let conflict = apply(
        &service,
        vec![action("RESTORE_ITEM", &script_in_trash)],
        revision(&conflict_snapshot),
    );
    assert_eq!(conflict.status, "complete");
    assert_eq!(conflict.data["operation"]["failed"], true);
    assert_eq!(fs::read(&original_script).unwrap(), b"replacement");

    let conflicted = snapshot(&service);
    let replace = apply(
        &service,
        vec![action("RESTORE_REPLACE", &script_in_trash)],
        revision(&conflicted),
    );
    assert_eq!(replace.status, "complete", "{}", replace.data);
    assert_ne!(fs::read(&original_script).unwrap(), b"replacement");
    let restore_all = snapshot(&service);
    let restored = apply(
        &service,
        vec![action("RESTORE_TRASH", Path::new("-"))],
        revision(&restore_all),
    );
    assert_eq!(restored.status, "complete", "{}", restored.data);
    assert!(original_data.is_dir());

    let apple_script = scripts.join("._script");
    let apple_data = games.join("._data");
    fs::write(&apple_script, b"junk").unwrap();
    fs::write(&apple_data, b"junk").unwrap();
    run(&service, "inventory-refresh");
    let before_cleanup = snapshot(&service);
    let cleaned = apply(
        &service,
        vec![action("CLEAN_APPLEDOUBLE", Path::new("-"))],
        revision(&before_cleanup),
    );
    assert_eq!(cleaned.status, "complete", "{}", cleaned.data);
    assert_eq!(
        cleaned.data["operation"]["failed"], false,
        "{}",
        cleaned.data
    );
    assert!(!apple_script.exists(), "{}", cleaned.data);
    assert!(!apple_data.exists(), "{}", cleaned.data);

    // Storage scan sees only the top-level card ZIPs. Duplicate launcher
    // names get a numeric suffix; their unrelated data name is never changed.
    fs::create_dir_all(&card).unwrap();
    let duplicate = scripts.join("Duplicate_Source.sh");
    fs::write(&duplicate, b"existing").unwrap();
    let port_zip = card.join("standard-port.zip");
    make_zip(
        &port_zip,
        &[
            (
                "Duplicate_Source.sh",
                b"#!/bin/sh\nGAMEDIR=/ports/BundleData\n",
            ),
            ("BundleData/data.bin", b"first"),
        ],
    );
    let unknown_zip = card.join("unknown.zip");
    make_zip(&unknown_zip, &[("README.txt", b"not an app")]);
    let app_zip = card.join("trimui-app.zip");
    make_zip(
        &app_zip,
        &[
            ("LabApp/launch.sh", b"#!/bin/sh\n"),
            ("LabApp/config.json", br#"{"label":"Lab App"}"#),
            ("LabApp/icon.png", b"png"),
        ],
    );

    let scanned = run(&service, "scan-zips");
    assert_eq!(scanned.status, "complete", "{}", scanned.data);
    let bundles = scanned.data["bundles"].as_array().unwrap();
    assert!(bundles.iter().any(|item| item["kind"] == "unknown"));
    let port_candidate = bundles
        .iter()
        .find(|item| {
            item["path"]
                .as_str()
                .unwrap()
                .ends_with("standard-port.zip")
        })
        .unwrap();
    assert_eq!(port_candidate["kind"], "port");
    let installed = install_candidate(&service, port_candidate, false);
    assert_eq!(installed.status, "complete", "{}", installed.data);
    assert_eq!(
        installed.data["zip_install"]["installed_bundles"], 1,
        "{}",
        installed.data
    );
    assert!(scripts.join("Duplicate_Source1.sh").is_file());
    assert_eq!(
        fs::read(games.join("BundleData/data.bin")).unwrap(),
        b"first"
    );

    let scanned = run(&service, "scan-zips");
    let app_candidate = scanned.data["bundles"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["path"].as_str().unwrap().ends_with("trimui-app.zip"))
        .unwrap()
        .clone();
    assert_eq!(app_candidate["kind"], "trimui_app");
    let app_result = install_candidate(&service, &app_candidate, false);
    assert_eq!(app_result.status, "complete", "{}", app_result.data);
    if profile == "trimui" {
        assert_eq!(app_result.data["zip_install"]["installed_bundles"], 1);
        assert!(
            snapshot(&service)["inventory"]["apps"]
                .as_array()
                .unwrap()
                .iter()
                .any(|app| app["name"] == "LabApp")
        );
    } else {
        assert_eq!(app_result.data["zip_install"]["failed_bundles"], 1);
        assert!(app_zip.is_file());
    }

    // The actual LAN server owns pairing, authenticated snapshots, upload,
    // exact-item management, stale-revision rejection, cancel, and shutdown.
    let endpoint = service.enable_web().unwrap();
    assert!(service.web_on());
    let index = http(endpoint.port, request("GET", "/", None, b""));
    assert_eq!(status(&index), 200);
    let unauthorized = http(endpoint.port, request("GET", "/api/snapshot", None, b""));
    assert_eq!(status(&unauthorized), 401);
    let paired = http(
        endpoint.port,
        request("POST", "/api/session", None, endpoint.code.as_bytes()),
    );
    assert_eq!(status(&paired), 200);
    let token = response_json(&paired)["token"].as_str().unwrap().to_owned();
    let authenticated = web_snapshot(endpoint.port, &token);
    assert_eq!(authenticated["ok"], true);
    let listed = http(
        endpoint.port,
        request("GET", "/api/list", Some(&token), b""),
    );
    assert_eq!(status(&listed), 200);
    assert_eq!(
        response_json(&listed)["revision"],
        authenticated["revision"]
    );

    let upload_file = tempfile::NamedTempFile::new().unwrap();
    make_zip(
        upload_file.path(),
        &[
            ("WebOnly.sh", b"#!/bin/sh\nGAMEDIR=/ports/WebOnlyData\n"),
            ("WebOnlyData/data.bin", b"web"),
        ],
    );
    let upload_bytes = fs::read(upload_file.path()).unwrap();
    let uploaded = upload(endpoint.port, &token, "WebOnly.zip", &upload_bytes, false);
    assert_eq!(
        status(&uploaded),
        200,
        "{}",
        String::from_utf8_lossy(&uploaded)
    );
    let web = web_snapshot(endpoint.port, &token);
    let item = web["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["raw_name"] == "WebOnly.sh")
        .unwrap();
    let webonly_paths = item["paths"]
        .as_array()
        .unwrap()
        .iter()
        .map(|path| path.as_str().unwrap().to_owned())
        .collect::<Vec<_>>();
    let managed = web_manage(
        endpoint.port,
        &token,
        "uninstall",
        webonly_paths.clone(),
        &web["revision"],
    );
    assert_eq!(
        status(&managed),
        200,
        "{}",
        String::from_utf8_lossy(&managed)
    );
    let stale = web_manage(
        endpoint.port,
        &token,
        "uninstall",
        webonly_paths,
        &web["revision"],
    );
    assert_eq!(status(&stale), 409, "{}", String::from_utf8_lossy(&stale));

    let in_trash = web_snapshot(endpoint.port, &token);
    let restore_paths = in_trash["trash"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|item| matches!(item["name"].as_str(), Some("WebOnly.sh" | "WebOnlyData")))
        .map(|item| item["path"].as_str().unwrap().to_owned())
        .collect::<Vec<_>>();
    assert_eq!(restore_paths.len(), 2, "{}", in_trash);
    let restored = web_manage(
        endpoint.port,
        &token,
        "restore",
        restore_paths,
        &in_trash["revision"],
    );
    assert_eq!(
        status(&restored),
        200,
        "{}",
        String::from_utf8_lossy(&restored)
    );
    assert!(scripts.join("WebOnly.sh").is_file());
    assert_eq!(
        fs::read(games.join("WebOnlyData/data.bin")).unwrap(),
        b"web"
    );

    // The browser asks about replacement before uploading and sends that
    // decision with the bytes. A conflict without consent changes nothing;
    // the same upload with consent replaces only the declared data target.
    let conflict_data = games.join("ConflictData");
    fs::create_dir_all(&conflict_data).unwrap();
    fs::write(conflict_data.join("old.bin"), b"old").unwrap();
    let conflict_upload = tempfile::NamedTempFile::new().unwrap();
    make_zip(
        conflict_upload.path(),
        &[
            ("Conflict.sh", b"#!/bin/sh\nGAMEDIR=/ports/ConflictData\n"),
            ("ConflictData/new.bin", b"new"),
        ],
    );
    let conflict_bytes = fs::read(conflict_upload.path()).unwrap();
    let refused = upload(
        endpoint.port,
        &token,
        "Conflict.zip",
        &conflict_bytes,
        false,
    );
    assert_eq!(
        status(&refused),
        200,
        "{}",
        String::from_utf8_lossy(&refused)
    );
    assert_eq!(
        response_json(&refused)["result"]["conflicts"]
            .as_array()
            .unwrap()
            .len(),
        1,
    );
    assert!(conflict_data.join("old.bin").is_file());
    assert!(!scripts.join("Conflict.sh").exists());
    let replaced = upload(endpoint.port, &token, "Conflict.zip", &conflict_bytes, true);
    assert_eq!(
        status(&replaced),
        200,
        "{}",
        String::from_utf8_lossy(&replaced)
    );
    assert!(scripts.join("Conflict.sh").is_file());
    assert!(!conflict_data.join("old.bin").exists());
    assert_eq!(fs::read(conflict_data.join("new.bin")).unwrap(), b"new");

    let installed_web = web_snapshot(endpoint.port, &token);
    let webonly = installed_web["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["raw_name"] == "WebOnly.sh")
        .unwrap();
    let webonly_paths = webonly["paths"]
        .as_array()
        .unwrap()
        .iter()
        .map(|path| path.as_str().unwrap().to_owned())
        .collect::<Vec<_>>();
    let removed_again = web_manage(
        endpoint.port,
        &token,
        "uninstall",
        webonly_paths,
        &installed_web["revision"],
    );
    assert_eq!(
        status(&removed_again),
        200,
        "{}",
        String::from_utf8_lossy(&removed_again)
    );
    fs::write(scripts.join("WebOnly.sh"), b"replacement").unwrap();
    let restore_conflict = web_snapshot(endpoint.port, &token);
    let script_in_trash = restore_conflict["trash"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["name"] == "WebOnly.sh")
        .unwrap();
    assert_eq!(script_in_trash["restore_conflict"], true);
    let replace_restored = web_manage(
        endpoint.port,
        &token,
        "restore_replace",
        vec![script_in_trash["path"].as_str().unwrap().to_owned()],
        &restore_conflict["revision"],
    );
    assert_eq!(
        status(&replace_restored),
        200,
        "{}",
        String::from_utf8_lossy(&replace_restored)
    );
    assert_ne!(
        fs::read(scripts.join("WebOnly.sh")).unwrap(),
        b"replacement"
    );

    let before_web_delete = web_snapshot(endpoint.port, &token);
    let delete_path = before_web_delete["trash"]
        .as_array()
        .unwrap()
        .first()
        .unwrap()["path"]
        .as_str()
        .unwrap()
        .to_owned();
    let deleted = web_manage(
        endpoint.port,
        &token,
        "delete",
        vec![delete_path],
        &before_web_delete["revision"],
    );
    assert_eq!(
        status(&deleted),
        200,
        "{}",
        String::from_utf8_lossy(&deleted)
    );
    let before_web_empty = web_snapshot(endpoint.port, &token);
    let emptied = web_manage(
        endpoint.port,
        &token,
        "empty_trash",
        Vec::new(),
        &before_web_empty["revision"],
    );
    assert_eq!(
        status(&emptied),
        200,
        "{}",
        String::from_utf8_lossy(&emptied)
    );
    assert!(
        web_snapshot(endpoint.port, &token)["trash"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    let cancelled = http(
        endpoint.port,
        request("POST", "/api/cancel", Some(&token), b""),
    );
    assert_eq!(status(&cancelled), 200);
    assert_eq!(response_json(&cancelled)["cancelled"], false);
    let missing = http(endpoint.port, request("GET", "/missing", Some(&token), b""));
    assert_eq!(status(&missing), 404);
    service.disable_web().unwrap();
    assert!(!service.web_on());
    assert!(TcpStream::connect(("127.0.0.1", endpoint.port)).is_err());

    // Permanent deletion and empty-trash are kept until the end so earlier
    // restore and Web management checks can inspect their exact entries.
    run(&service, "inventory-refresh");
    let before_delete = snapshot(&service);
    let permanently_deleted = apply(
        &service,
        vec![action("DELETE_MANAGED", &original_script)],
        revision(&before_delete),
    );
    assert_eq!(
        permanently_deleted.status, "complete",
        "{}",
        permanently_deleted.data
    );
    assert!(!original_script.exists());
    let before_empty = snapshot(&service);
    let emptied = apply(
        &service,
        vec![action("EMPTY_TRASH", Path::new("-"))],
        revision(&before_empty),
    );
    assert_eq!(emptied.status, "complete", "{}", emptied.data);
    assert!(
        snapshot(&service)["inventory"]["trash"]
            .as_array()
            .unwrap()
            .is_empty()
    );

    service.cancel().unwrap();
    assert!(service.start("unsupported", None).is_err());
    assert!(service.start("apply", Some(Vec::new())).is_err());
}
