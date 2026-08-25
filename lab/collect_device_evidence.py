#!/usr/bin/env python3
"""Run the bounded APP Manager evidence probe against one handheld."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
PROBE_PATH = REPO_ROOT / "lab" / "device-probe.sh"
PROFILE_IDS = ("trimui", "miniloong", "miniloong-loongos", "rocknix")
RUNTIME_LIBRARY_PREFIXES = (
    "/lib/",
    "/lib64/",
    "/usr/lib/",
    "/usr/lib64/",
    "/usr/trimui/lib/",
    "/mnt/SDCARD/System/lib/",
)


def split_endpoint(endpoint: str, default_port: int) -> tuple[str, int]:
    host, separator, port_text = endpoint.rpartition(":")
    if not separator:
        return endpoint, default_port
    if not host or not port_text.isdigit():
        raise ValueError(f"invalid endpoint: {endpoint}")
    port = int(port_text)
    if not 1 <= port <= 65535:
        raise ValueError(f"invalid endpoint port: {port}")
    return host, port


def run_probe(
    transport: str,
    endpoint: str,
    user: str,
    probe: bytes,
) -> tuple[subprocess.CompletedProcess[bytes], str]:
    if transport == "adb":
        connection = subprocess.run(
            ["adb", "connect", endpoint],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=15,
            check=False,
        )
        command = ["adb", "-s", endpoint, "shell", "sh", "-s"]
        connection_log = connection.stdout.decode("utf-8", errors="replace")
    else:
        host, port = split_endpoint(endpoint, 22)
        command = [
            "ssh",
            "-F",
            "/dev/null",
            "-o",
            "IdentityFile=/dev/null",
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "PubkeyAuthentication=no",
            "-o",
            "PreferredAuthentications=none",
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-o",
            "ConnectTimeout=8",
            "-p",
            str(port),
            f"{user}@{host}",
            "sh",
            "-s",
        ]
        connection_log = "SSH authentication stores and host files disabled.\n"

    result = subprocess.run(
        command,
        input=probe,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=180,
        check=False,
    )
    return result, connection_log


def transport_command(
    transport: str, endpoint: str, user: str, remote_command: list[str]
) -> list[str]:
    if transport == "adb":
        return ["adb", "-s", endpoint, "exec-out", *remote_command]
    host, port = split_endpoint(endpoint, 22)
    return [
        "ssh",
        "-F",
        "/dev/null",
        "-o",
        "IdentityFile=/dev/null",
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "PubkeyAuthentication=no",
        "-o",
        "PreferredAuthentications=none",
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "ConnectTimeout=8",
        "-p",
        str(port),
        f"{user}@{host}",
        *remote_command,
    ]


def loader_library_paths(evidence: str) -> list[str]:
    marker = "===== appmanager-loader-resolution ====="
    if marker not in evidence:
        return []
    section = evidence.split(marker, 1)[1].split("=====", 1)[0]
    paths = set(re.findall(r"(?:=>\s+)?(/[^\s()]+)\s+\(", section))
    return sorted(
        path
        for path in paths
        if path.startswith(RUNTIME_LIBRARY_PREFIXES)
        and (".so" in Path(path).name or Path(path).name.startswith("ld-linux-"))
    )


def appmanager_launcher_paths(evidence: str) -> list[str]:
    marker = "===== appmanager-launchers ====="
    if marker not in evidence:
        return []
    section = evidence.split(marker, 1)[1].split("=====", 1)[0]
    return list(
        dict.fromkeys(re.findall(r"^--- (/.*/APP Manager\.sh) ---$", section, re.M))
    )


def collect_runtime_libraries(
    transport: str,
    endpoint: str,
    user: str,
    profile: str,
    evidence: str,
    output_root: Path,
) -> dict[str, object]:
    library_dir = output_root / profile / "runtime-libs"
    library_dir.mkdir(parents=True, exist_ok=True)
    entries = []
    for source_path in loader_library_paths(evidence):
        result = subprocess.run(
            transport_command(transport, endpoint, user, ["cat", source_path]),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=60,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"failed to read {source_path}: "
                + result.stderr.decode("utf-8", errors="replace").strip()
            )
        destination = library_dir / Path(source_path).name
        destination.write_bytes(result.stdout)
        mode = 0o755 if destination.name.startswith("ld-linux-") else 0o644
        destination.chmod(mode)
        entries.append(
            {
                "source": source_path,
                "file": destination.name,
                "bytes": len(result.stdout),
                "sha256": hashlib.sha256(result.stdout).hexdigest(),
                "mode": f"{mode:04o}",
            }
        )
    manifest = {
        "format": "jenny92.runtime-library-closure",
        "profile": profile,
        "transport": transport,
        "endpoint": endpoint,
        "appmanager_launchers": appmanager_launcher_paths(evidence),
        "libraries": entries,
    }
    (library_dir.parent / "runtime-libs.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return {"path": str(library_dir), "libraries": entries}


def create_report_dir(output_root: Path, profile: str) -> Path:
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    report_dir = output_root / f"{timestamp}-{profile}"
    suffix = 1
    while report_dir.exists():
        report_dir = output_root / f"{timestamp}-{profile}-{suffix}"
        suffix += 1
    report_dir.mkdir(parents=True)
    return report_dir


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--transport", choices=("adb", "ssh"), required=True)
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--profile", choices=PROFILE_IDS, required=True)
    parser.add_argument("--user", default="root")
    parser.add_argument("--collect-runtime-libs", action="store_true")
    parser.add_argument(
        "--output-root",
        type=Path,
        default=REPO_ROOT / ".pam-lab" / "device-evidence",
    )
    args = parser.parse_args()

    probe = PROBE_PATH.read_bytes()
    try:
        result, connection_log = run_probe(
            args.transport, args.endpoint, args.user, probe
        )
    except (OSError, subprocess.TimeoutExpired, ValueError) as error:
        print(f"device probe failed: {error}", file=sys.stderr)
        return 2

    report_dir = create_report_dir(args.output_root, args.profile)
    evidence = result.stdout.decode("utf-8", errors="replace")
    error_output = result.stderr.decode("utf-8", errors="replace")
    (report_dir / "evidence.txt").write_text(evidence, encoding="utf-8")
    (report_dir / "connection.log").write_text(
        connection_log + error_output, encoding="utf-8"
    )
    runtime_libraries = None
    runtime_libraries_error = None
    if result.returncode == 0 and args.collect_runtime_libs:
        try:
            runtime_libraries = collect_runtime_libraries(
                args.transport,
                args.endpoint,
                args.user,
                args.profile,
                evidence,
                REPO_ROOT / ".pam-lab" / "userspace",
            )
        except (OSError, subprocess.TimeoutExpired, RuntimeError) as error:
            runtime_libraries_error = str(error)
            (report_dir / "runtime-libs-error.txt").write_text(
                f"{error}\n", encoding="utf-8"
            )

    metadata = {
        "format": "jenny92.device-evidence",
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "profile": args.profile,
        "transport": args.transport,
        "endpoint": args.endpoint,
        "probe_sha256": hashlib.sha256(probe).hexdigest(),
        "exit_code": result.returncode,
        "evidence_bytes": len(result.stdout),
        "evidence_sha256": hashlib.sha256(result.stdout).hexdigest(),
        "runtime_libraries": runtime_libraries,
        "runtime_libraries_error": runtime_libraries_error,
        "appmanager_launchers": appmanager_launcher_paths(evidence),
    }
    (report_dir / "report.json").write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    status = (
        "PASS"
        if result.returncode == 0 and runtime_libraries_error is None
        else "FAIL"
    )
    (report_dir / "summary.md").write_text(
        "# Device evidence summary\n\n"
        f"Result: **{status}**\n\n"
        f"Profile: `{args.profile}`\n\n"
        f"Transport: `{args.transport}`\n\n"
        "The probe is read-only, bounded to configured paths, and does not dump "
        "the device environment.\n",
        encoding="utf-8",
    )
    print(f"{status} {args.profile}: {report_dir}")
    return 0 if status == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
