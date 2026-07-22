use serde_json::Value;
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

static SEQUENCE: AtomicU64 = AtomicU64::new(0);

fn test_directory(name: &str) -> PathBuf {
    let sequence = SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let path = std::env::temp_dir().join(format!(
        "portkit-cli-github-{}-{sequence}-{name}",
        std::process::id()
    ));
    fs::create_dir_all(&path).unwrap();
    path
}

#[test]
fn candidates_json_contains_route_ids_but_no_endpoints() {
    let source = "https://github.com/o/r/releases/download/v/f";
    let output = Command::new(env!("CARGO_BIN_EXE_portkit"))
        .args([
            "github",
            "candidates",
            "--capability",
            "release",
            "--source",
            source,
        ])
        .output()
        .unwrap();
    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    let value: Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(value["ok"], true);
    assert!(value["count"].as_u64().unwrap() > 1);
    assert!(
        value["routes"]
            .as_array()
            .unwrap()
            .iter()
            .all(Value::is_string)
    );
    assert!(!stdout.contains("https://"));
    assert!(!stdout.contains(source));
}

#[test]
fn mismatched_capability_error_does_not_echo_source() {
    let source = "https://github.com/o/r/releases/download/v/f";
    let output = Command::new(env!("CARGO_BIN_EXE_portkit"))
        .args([
            "github",
            "candidates",
            "--capability",
            "raw",
            "--source",
            source,
        ])
        .output()
        .unwrap();
    assert!(!output.status.success());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains("source does not match the raw capability"));
    assert!(!stderr.contains(source));
}

#[test]
fn fetch_downloads_via_native_transport_and_returns_machine_json() {
    let root = test_directory("fetch");
    let port = local_server(b"artifact");
    let artifact = root.join("artifact.bin");
    let source = "https://github.com/o/r/releases/download/v/f";
    let output = Command::new(env!("CARGO_BIN_EXE_portkit"))
        .env("PORTKIT_GITHUB_ROUTES", format!("http://127.0.0.1:{port}"))
        .args([
            "github",
            "fetch",
            "--capability",
            "release",
            "--source",
            source,
            "--output",
        ])
        .arg(&artifact)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8(output.stdout).unwrap();
    let value: Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(value["route"], "r1");
    assert!(!stdout.contains("https://"));
    assert_eq!(fs::read(&artifact).unwrap(), b"artifact");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn fetch_validates_md5_without_an_external_hash_program() {
    let root = test_directory("md5");
    let port = local_server(b"artifact");
    let artifact = root.join("artifact.bin");
    let output = Command::new(env!("CARGO_BIN_EXE_portkit"))
        .env("PORTKIT_GITHUB_ROUTES", format!("http://127.0.0.1:{port}"))
        .args([
            "github",
            "fetch",
            "--capability",
            "release",
            "--source",
            "https://github.com/o/r/releases/download/v/f",
            "--output",
        ])
        .arg(&artifact)
        .args(["--expected-md5", "8e5b948a454515dbabfc7eb718daa52f"])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(fs::read(&artifact).unwrap(), b"artifact");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn domain_validator_rejects_a_bad_route_and_uses_the_next_one() {
    let root = test_directory("validated-fallback");
    let invalid_port = local_server(b"not-json");
    let valid = include_bytes!("../../../config/config.json");
    let valid_port = local_server(valid);
    let artifact = root.join("config.json");
    let output = Command::new(env!("CARGO_BIN_EXE_portkit"))
        .env(
            "PORTKIT_GITHUB_ROUTES",
            format!("http://127.0.0.1:{invalid_port}\nhttp://127.0.0.1:{valid_port}"),
        )
        .args([
            "github",
            "fetch",
            "--capability",
            "raw",
            "--source",
            "https://raw.githubusercontent.com/o/r/main/config.json",
            "--output",
        ])
        .arg(&artifact)
        .args(["--validator", "config-root"])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let value: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(value["route"], "r2");
    assert_eq!(fs::read(&artifact).unwrap(), valid);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn fetch_rejects_clone_capability_as_a_file_operation() {
    let output = Command::new(env!("CARGO_BIN_EXE_portkit"))
        .args([
            "github",
            "fetch",
            "--capability",
            "clone",
            "--source",
            "https://github.com/o/r.git",
            "--output",
            "/tmp/must-not-write-portkit-clone",
        ])
        .output()
        .unwrap();
    assert!(!output.status.success());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains("clone capability cannot be fetched as a file"));
}

#[test]
fn fetch_enforces_max_bytes_and_writes_machine_progress() {
    let root = test_directory("bounded-progress");
    let port = local_server(b"artifact");
    let artifact = root.join("artifact.bin");
    let progress = root.join("progress.tsv");
    let source = "https://github.com/o/r/releases/download/v/f";
    let output = Command::new(env!("CARGO_BIN_EXE_portkit"))
        .env("PORTKIT_GITHUB_ROUTES", format!("http://127.0.0.1:{port}"))
        .args([
            "github",
            "fetch",
            "--capability",
            "release",
            "--source",
            source,
            "--output",
        ])
        .arg(&artifact)
        .args(["--max-bytes", "8", "--progress"])
        .arg(&progress)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        fs::read_to_string(&progress).unwrap().split('\t').nth(5),
        Some("8")
    );

    let cancelled = root.join("cancelled.bin");
    let cancel_file = root.join("cancel.request");
    fs::write(&cancel_file, b"cancel").unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_portkit"))
        .env("PORTKIT_GITHUB_ROUTES", format!("http://127.0.0.1:{port}"))
        .args([
            "github",
            "fetch",
            "--capability",
            "release",
            "--source",
            source,
            "--output",
        ])
        .arg(&cancelled)
        .arg("--cancel-file")
        .arg(&cancel_file)
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(!cancelled.exists());

    let too_large = root.join("too-large.bin");
    let output = Command::new(env!("CARGO_BIN_EXE_portkit"))
        .env("PORTKIT_GITHUB_ROUTES", format!("http://127.0.0.1:{port}"))
        .args([
            "github",
            "fetch",
            "--capability",
            "release",
            "--source",
            source,
            "--output",
        ])
        .arg(&too_large)
        .args(["--max-bytes", "7"])
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(!too_large.exists());
    fs::remove_dir_all(root).unwrap();
}

// Minimal local HTTP/1.0 server returning a fixed body for any request.
fn local_server(body: &'static [u8]) -> u16 {
    use std::io::{Read, Write};
    use std::net::TcpListener;
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut buf = [0u8; 1024];
            let _ = stream.read(&mut buf);
            let header = format!("HTTP/1.0 200 OK\r\nContent-Length: {}\r\n\r\n", body.len());
            let _ = stream.write_all(header.as_bytes());
            let _ = stream.write_all(body);
        }
    });
    port
}
