#!/usr/bin/env python3
"""Build the canonical, minified App Manager configuration from fragments."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


CONFIG_DIR = Path(__file__).resolve().parents[1]
SOURCE_DIR = CONFIG_DIR / "src"
ROOT_OUTPUT = CONFIG_DIR / "config.json"
PLATFORMS_OUTPUT = CONFIG_DIR / "platforms"

# Keys that live in the root config.json (everything except the per-platform
# detail, which is split out into platforms/<id>.json).
ROOT_KEYS = (
    "format",
    "schema_version",
    "config_version",
    "metadata",
    "parser_limits",
    "bootstrap",
    "sources",
    "environment",
    "adapters",
)


def build() -> dict:
    result: dict = {}
    fragments = sorted(SOURCE_DIR.glob("*.json"))
    if not fragments:
        raise ValueError(f"no source fragments found under {SOURCE_DIR}")
    for path in fragments:
        value = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(value, dict):
            raise ValueError(f"{path}: fragment must be a JSON object")
        duplicate = set(result).intersection(value)
        if duplicate:
            raise ValueError(f"{path}: duplicate top-level keys: {sorted(duplicate)}")
        result.update(value)
    # Per-platform source fragments live under src/platforms/<id>.json and merge
    # into a single "platforms" object keyed by filename stem.
    platform_dir = SOURCE_DIR / "platforms"
    platforms: dict = {}
    for path in sorted(platform_dir.glob("*.json")):
        platform = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(platform, dict):
            raise ValueError(f"{path}: platform fragment must be a JSON object")
        platform_id = path.stem
        if platform_id in platforms:
            raise ValueError(f"{path}: duplicate platform id: {platform_id}")
        platforms[platform_id] = platform
    if platforms:
        if "platforms" in result:
            raise ValueError("platforms must come only from src/platforms/*.json")
        result["platforms"] = platforms
    return result


def encode(value: dict) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        + "\n"
    ).encode("utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail if any output is stale")
    args = parser.parse_args()
    try:
        config = build()
        sys.path.insert(0, str(CONFIG_DIR / "scripts"))
        from validate import validate

        validate(config)
        outputs: dict = {}
        # Detail files carry their own contract identity, while detection stays
        # exclusively in the root.
        detail_outputs: dict[str, bytes] = {}
        for pid, platform in config["platforms"].items():
            detail = {
                "format": config["format"],
                "schema_version": config["schema_version"],
                "config_version": config["config_version"],
                "platform_id": pid,
                **{
                    key: value
                    for key, value in platform.items()
                    if key not in {"priority", "recognition"}
                },
            }
            rendered = encode(detail)
            detail_outputs[pid] = rendered
            outputs[PLATFORMS_OUTPUT / f"{pid}.json"] = rendered
        # Root config.json: global keys + thin platform entries used only for
        # detection, each pointing at its detail file.
        root = {key: config[key] for key in ROOT_KEYS if key in config}
        root["platforms"] = {
            pid: {
                "priority": platform["priority"],
                "recognition": platform["recognition"],
                "detail": f"./platforms/{pid}.json",
            }
            for pid, platform in config["platforms"].items()
        }
        outputs[ROOT_OUTPUT] = encode(root)
        if args.check:
            stale = [
                str(path)
                for path, rendered in outputs.items()
                if not path.exists() or path.read_bytes() != rendered
            ]
            stale.extend(
                str(path)
                for path in sorted(PLATFORMS_OUTPUT.glob("*.json"))
                if path not in outputs
            )
            if stale:
                print(f"stale generated config: {', '.join(stale)}", file=sys.stderr)
                return 1
        else:
            PLATFORMS_OUTPUT.mkdir(parents=True, exist_ok=True)
            for path, rendered in outputs.items():
                path.write_bytes(rendered)
    except (OSError, ValueError) as error:
        print(f"generation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
