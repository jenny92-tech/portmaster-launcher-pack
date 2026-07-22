#!/usr/bin/env python3
"""Content-revision helpers scoped to Cargo dependency closures."""

from __future__ import annotations

import hashlib
import json
import tomllib
from pathlib import Path
from typing import Iterable


def lock_dependency_closure(lock: dict, root_names: Iterable[str]) -> list[dict]:
    packages = lock.get("package", [])
    by_name: dict[str, list[dict]] = {}
    for package in packages:
        by_name.setdefault(package["name"], []).append(package)

    def unique(name: str, version: str | None = None) -> dict:
        candidates = by_name.get(name, [])
        if version is not None:
            candidates = [package for package in candidates if package["version"] == version]
        if len(candidates) != 1:
            detail = f" {version}" if version else ""
            raise ValueError(f"ambiguous Cargo.lock package {name!r}{detail}")
        return candidates[0]

    def resolve(reference: str) -> dict:
        parts = reference.split()
        version = parts[1] if len(parts) >= 2 and parts[1][0].isdigit() else None
        return unique(parts[0], version)

    pending = [unique(name) for name in root_names]
    selected: dict[tuple[str, str, str], dict] = {}
    while pending:
        package = pending.pop()
        identity = (package["name"], package["version"], package.get("source", ""))
        if identity in selected:
            continue
        selected[identity] = package
        pending.extend(resolve(reference) for reference in package.get("dependencies", []))
    return [selected[key] for key in sorted(selected)]


def update_paths(digest: hashlib._Hash, root: Path, files: Iterable[Path]) -> None:
    for path in files:
        if not path.is_file():
            raise SystemExit(f"missing revision source: {path}")
        relative = path.relative_to(root).as_posix().encode("utf-8")
        payload = path.read_bytes()
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        digest.update(len(payload).to_bytes(8, "big"))
        digest.update(payload)


def update_lock_closure(
    digest: hashlib._Hash,
    lock_path: Path,
    root_names: Iterable[str],
    label: str,
) -> None:
    with lock_path.open("rb") as stream:
        closure = lock_dependency_closure(tomllib.load(stream), root_names)
    payload = json.dumps(
        closure, ensure_ascii=True, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    digest.update(f"Cargo.lock:{label}".encode("utf-8"))
    digest.update(len(payload).to_bytes(8, "big"))
    digest.update(payload)


def update_toml_section(
    digest: hashlib._Hash, path: Path, section: tuple[str, ...], label: str
) -> None:
    with path.open("rb") as stream:
        value = tomllib.load(stream)
    for key in section:
        value = value[key]
    payload = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    digest.update(label.encode("utf-8"))
    digest.update(len(payload).to_bytes(8, "big"))
    digest.update(payload)
