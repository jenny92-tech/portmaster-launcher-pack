#!/usr/bin/env python3
# INPUT:  Python 标准库、仓库配置、预置运行时与 lab 测试入口
# OUTPUT: main() doctor/test/diagnose；report.json、summary.md 与分项日志
# POS:    汇总 App Manager 主机条件、配置绑定、用户态输入和评估结果
"""AI-facing evaluator for the APP Manager device matrix."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
PROFILE_IDS = (
    "trimui",
    "miniloong",
    "miniloong-loongos",
    "rocknix",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_check(
    check_id: str,
    title: str,
    command: list[str],
    cwd: Path,
    log_dir: Path,
    *,
    timeout: int = 900,
    stdout_contains: str | None = None,
) -> dict[str, Any]:
    started = time.monotonic()
    try:
        result = subprocess.run(
            command,
            cwd=cwd,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
        status = "pass" if result.returncode == 0 else "fail"
        if stdout_contains is not None and stdout_contains not in result.stdout:
            status = "fail"
        output = f"$ {' '.join(command)}\n\n{result.stdout}{result.stderr}"
        exit_code: int | None = result.returncode
    except FileNotFoundError as error:
        status = "fail"
        output = f"command unavailable: {error}\n"
        exit_code = None
    except subprocess.TimeoutExpired as error:
        status = "fail"
        output = f"timed out after {timeout}s\n{error.stdout or ''}{error.stderr or ''}"
        exit_code = None

    log_path = log_dir / f"{check_id}.log"
    log_path.write_text(output, encoding="utf-8")
    return {
        "id": check_id,
        "title": title,
        "status": status,
        "duration_ms": round((time.monotonic() - started) * 1000),
        "exit_code": exit_code,
        "log": f"logs/{log_path.name}",
    }


def host_snapshot(repo_root: Path) -> dict[str, Any]:
    disk = shutil.disk_usage(repo_root)
    memory_bytes = None
    meminfo = Path("/proc/meminfo")
    if meminfo.is_file():
        for line in meminfo.read_text(encoding="utf-8").splitlines():
            if line.startswith("MemTotal:"):
                memory_bytes = int(line.split()[1]) * 1024
                break
    return {
        "system": platform.system(),
        "release": platform.release(),
        "architecture": platform.machine(),
        "cpu_count": os.cpu_count(),
        "memory_bytes": memory_bytes,
        "disk_total_bytes": disk.total,
        "disk_free_bytes": disk.free,
    }


def config_snapshot(repo_root: Path) -> dict[str, Any]:
    config_dir = repo_root / "config"
    root = json.loads((config_dir / "config.json").read_text(encoding="utf-8"))
    profiles: list[dict[str, Any]] = []
    for profile_id in PROFILE_IDS:
        entry = root.get("platforms", {}).get(profile_id)
        detail = entry.get("detail") if isinstance(entry, dict) else None
        detail_path = None
        actual_hash = None
        actual_bytes = None
        matches = False
        if isinstance(detail, dict) and isinstance(detail.get("ref"), str):
            detail_path = (config_dir / detail["ref"]).resolve()
            if detail_path.is_file():
                actual_hash = sha256(detail_path)
                actual_bytes = detail_path.stat().st_size
                matches = (
                    actual_hash == detail.get("sha256")
                    and actual_bytes == detail.get("bytes")
                )
        profiles.append(
            {
                "id": profile_id,
                "detail": str(detail_path) if detail_path else None,
                "bytes": actual_bytes,
                "sha256": actual_hash,
                "binding_matches": matches,
            }
        )
    return {
        "format": root.get("format"),
        "schema_version": root.get("schema_version"),
        "config_version": root.get("config_version"),
        "profiles": profiles,
        "bindings_match": all(item["binding_matches"] for item in profiles),
    }


def userspace_snapshot(repo_root: Path) -> dict[str, Any]:
    base = Path(
        os.environ.get("PAM_LAB_USERSPACE_DIR", repo_root / ".pam-lab" / "userspace")
    ).expanduser()
    profiles = []
    for profile_id in PROFILE_IDS:
        path = base / profile_id
        collected = path.is_dir() and any(path.iterdir())
        manifest_path = path / "runtime-libs.json"
        runtime_library_count = 0
        if manifest_path.is_file():
            try:
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                runtime_library_count = len(manifest.get("libraries", []))
            except (OSError, json.JSONDecodeError, TypeError):
                runtime_library_count = 0
        profiles.append(
            {
                "id": profile_id,
                "path": str(path),
                "collected": collected,
                "runtime_library_count": runtime_library_count,
            }
        )
    return {"base": str(base), "profiles": profiles}


def artifact_snapshot(repo_root: Path) -> dict[str, Any]:
    path = repo_root / "ports/appmanager/portable/runtime/love.aarch64"
    if not path.is_file():
        return {"path": str(path), "present": False}
    return {
        "path": str(path),
        "present": True,
        "bytes": path.stat().st_size,
        "sha256": sha256(path),
    }


def render_summary(report: dict[str, Any]) -> str:
    checks = report["checks"]
    failed = [check for check in checks if check["status"] != "pass"]
    missing = [
        profile["id"]
        for profile in report["userspace"]["profiles"]
        if not profile["collected"]
    ]
    lines = [
        "# APP Manager diagnostic summary",
        "",
        f"Result: **{'FAIL' if failed else 'PASS'}**",
        "",
        "## Checks",
        "",
        "| Check | Status | Duration | Log |",
        "|---|---:|---:|---|",
    ]
    for check in checks:
        lines.append(
            f"| {check['title']} | {check['status']} | "
            f"{check['duration_ms']} ms | `{check['log']}` |"
        )
    lines.extend(["", "## Device matrix", ""])
    for profile in report["config"]["profiles"]:
        state = "config-ok" if profile["binding_matches"] else "config-broken"
        lines.append(f"- `{profile['id']}`: {state}")
    if missing:
        lines.extend(
            [
                "",
                "## Next evidence",
                "",
                "Exact userspace has not been collected for: " + ", ".join(missing) + ".",
            ]
        )
    if failed:
        lines.extend(
            [
                "",
                "## Failures",
                "",
                *[f"- `{check['id']}`: inspect `{check['log']}`" for check in failed],
            ]
        )
    return "\n".join(lines) + "\n"


def create_report(mode: str, output_root: Path) -> tuple[dict[str, Any], Path]:
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    report_dir = output_root / timestamp
    suffix = 1
    while report_dir.exists():
        report_dir = output_root / f"{timestamp}-{suffix}"
        suffix += 1
    log_dir = report_dir / "logs"
    log_dir.mkdir(parents=True)

    config = config_snapshot(REPO_ROOT)
    userspace = userspace_snapshot(REPO_ROOT)
    checks = [
        run_check(
            "config_generated",
            "Generated Config is current",
            [sys.executable, "config/scripts/generate.py", "--check"],
            REPO_ROOT,
            log_dir,
        ),
        {
            "id": "config_bindings",
            "title": "Device Config bindings",
            "status": "pass" if config["bindings_match"] else "fail",
            "duration_ms": 0,
            "exit_code": 0 if config["bindings_match"] else 1,
            "log": "logs/config_bindings.log",
        },
    ]
    (log_dir / "config_bindings.log").write_text(
        json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    checks.extend(
        [
            run_check(
                "docker_version",
                "Docker engine",
                ["docker", "version", "--format", "{{.Server.Version}}"],
                REPO_ROOT,
                log_dir,
            ),
            run_check(
                "arm64_baseline",
                "ARM64 Bullseye execution",
                [
                    "docker",
                    "run",
                    "--rm",
                    "--platform",
                    "linux/arm64",
                    "debian:bullseye-slim",
                    "uname",
                    "-m",
                ],
                REPO_ROOT,
                log_dir,
                stdout_contains="aarch64",
            ),
        ]
    )
    if mode in {"test", "diagnose"}:
        checks.extend(
            [
                run_check(
                    "appmanager_device_matrix",
                    "APP Manager full TrimUI and MiniLoong matrix",
                    [
                        str(REPO_ROOT / "lab/run-device-function-tests.sh"),
                        "all",
                        "all",
                    ],
                    REPO_ROOT,
                    log_dir,
                    timeout=3600,
                ),
            ]
        )

    report = {
        "format": "jenny92.pam-lab-report",
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "mode": mode,
        "status": "pass" if all(c["status"] == "pass" for c in checks) else "fail",
        "repository": str(REPO_ROOT),
        "host": host_snapshot(REPO_ROOT),
        "config": config,
        "artifact": artifact_snapshot(REPO_ROOT),
        "userspace": userspace,
        "checks": checks,
    }
    (report_dir / "report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (report_dir / "summary.md").write_text(render_summary(report), encoding="utf-8")
    return report, report_dir


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", nargs="?", choices=("doctor", "test", "diagnose"), default="diagnose")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=REPO_ROOT / ".pam-lab" / "reports",
    )
    args = parser.parse_args()
    report, report_dir = create_report(args.mode, args.output_dir.expanduser().resolve())
    print(report_dir / "summary.md")
    print(report_dir / "report.json")
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
