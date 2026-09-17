#!/usr/bin/env python3
# INPUT:  argparse, json, pathlib；平台配置、运行库清单与目标 fixture 根
# OUTPUT: main()；最小识别夹具、fixture.json 与观测到的启动路径
# POS:    从正式配置构造用户态测试所需事实而不维护第二份设备规则
"""Materialize only the Config recognition facts needed by a lab profile."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
PROFILE_IDS = ("trimui", "miniloong", "miniloong-loongos", "rocknix")


def fixture_path(root: Path, device_path: str) -> Path:
    path = Path(device_path)
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError(f"unsafe device path in Config: {device_path}")
    return root.joinpath(*path.parts[1:])


def apply_recognition(
    predicate: dict[str, Any], root: Path, os_release: dict[str, str]
) -> bool:
    kind = predicate.get("kind")
    if kind == "always":
        return True
    if kind == "directory_exists":
        fixture_path(root, predicate["path"]).mkdir(parents=True, exist_ok=True)
        return True
    if kind == "file_exists":
        path = fixture_path(root, predicate["path"])
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch(exist_ok=True)
        return True
    if kind in {"os_release_equals", "os_release_version_at_least"}:
        os_release[str(predicate["field"])] = str(predicate["value"])
        return True
    if kind == "all":
        return all(
            apply_recognition(child, root, os_release)
            for child in predicate.get("predicates", [])
        )
    if kind == "any":
        for child in predicate.get("predicates", []):
            if apply_recognition(child, root, os_release):
                return True
        return False
    return False


def write_os_release(root: Path, values: dict[str, str]) -> None:
    if not values:
        return
    path = fixture_path(root, "/etc/os-release")
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = []
    for name, value in sorted(values.items()):
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        lines.append(f'{name}="{escaped}"')
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_card_mount(root: Path, card_root: str) -> None:
    mount = Path(card_root)
    if not mount.is_absolute() or ".." in mount.parts:
        raise ValueError(f"unsafe card root: {card_root}")
    fixture_path(root, card_root).mkdir(parents=True, exist_ok=True)
    mounts = fixture_path(root, "/proc/mounts")
    mounts.parent.mkdir(parents=True, exist_ok=True)
    mounts.write_text(f"/dev/pamcard {card_root} ext4 rw 0 0\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", choices=PROFILE_IDS, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runtime-manifest", type=Path, required=True)
    parser.add_argument("--card-root")
    args = parser.parse_args()

    config_path = REPO_ROOT / "config" / "src" / "platforms" / f"{args.profile}.json"
    config = json.loads(config_path.read_text(encoding="utf-8"))
    runtime = json.loads(args.runtime_manifest.read_text(encoding="utf-8"))
    launchers = runtime.get("appmanager_launchers", [])
    if not launchers:
        raise SystemExit("runtime manifest has no observed APP Manager launcher")

    args.output.mkdir(parents=True, exist_ok=True)
    os_release: dict[str, str] = {}
    if not apply_recognition(config["recognition"], args.output, os_release):
        raise SystemExit(f"cannot materialize recognition for {args.profile}")
    write_os_release(args.output, os_release)
    if args.card_root:
        write_card_mount(args.output, args.card_root)

    launcher = str(launchers[0])
    summary = {
        "format": "jenny92.device-fixture",
        "profile": args.profile,
        "launcher": launcher,
        "config": str(config_path),
    }
    (args.output / "fixture.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(launcher)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
