#!/usr/bin/env python3
"""Package a Port launcher as a TrimUI MainUI application."""

from __future__ import annotations

import json
import os
import re
import shlex
import shutil
import stat
import sys
import tempfile
import zipfile
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(f"trimui app: {message}")


def safe_component(value: object, field: str) -> str:
    if not isinstance(value, str) or not value or value in {".", ".."}:
        fail(f"invalid {field}")
    if "/" in value or "\\" in value or "\0" in value:
        fail(f"invalid {field}: {value!r}")
    return value


def safe_source(root: Path, value: object, field: str) -> Path:
    if not isinstance(value, str) or not value:
        fail(f"invalid {field}")
    relative = Path(value)
    if relative.is_absolute() or root.is_symlink():
        fail(f"invalid {field}: {value!r}")
    unresolved = root
    for component in relative.parts:
        unresolved /= component
        if unresolved.is_symlink():
            fail(f"{field} must not contain a symlink: {value!r}")
    candidate = unresolved.resolve()
    try:
        candidate.relative_to(root.resolve())
    except ValueError:
        fail(f"{field} escapes its source directory: {value!r}")
    return candidate


def copy_clean(source: Path, destination: Path) -> None:
    ignored = shutil.ignore_patterns(
        "._*", ".DS_Store", "__MACOSX", "__pycache__",
        "state", "trash", "cache", "logs",
        "*.log", "*.bak", "*.backup", "*.tmp",
    )
    reject_symlinks(source)
    if source.is_dir():
        shutil.copytree(source, destination, ignore=ignored)
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)


def reject_symlinks(source: Path) -> None:
    """Never dereference a package-input symlink, including descendants."""
    if source.is_symlink():
        fail(f"package input must not be a symlink: {source}")
    if not source.is_dir():
        return
    for directory, names, files in os.walk(source, followlinks=False):
        parent = Path(directory)
        for name in (*names, *files):
            candidate = parent / name
            if candidate.is_symlink():
                fail(f"package input contains a symlink: {candidate}")


def choose_icon(manifest: dict, settings: dict, port_dir: Path, dist: Path) -> Path:
    explicit = settings.get("icon")
    if explicit is not None:
        icon = safe_source(port_dir, explicit, "trimui_app.icon")
        if not icon.is_file():
            fail(f"icon does not exist: {icon}")
        return icon

    local_icon = port_dir / "trimui-app" / "icon.png"
    if local_icon.is_file():
        return local_icon

    image = manifest.get("portmaster", {}).get("image", {})
    for name in image.get("names", []):
        if isinstance(name, str) and name:
            candidate = dist / (name if Path(name).suffix else f"{name}.png")
            if candidate.is_file():
                return candidate

    script = str(manifest.get("script", ""))
    for candidate in (dist / f"{Path(script).stem}.png", dist / "screenshot.png"):
        if candidate.is_file():
            return candidate
    fail("no icon found; add trimui-app/icon.png or trimui_app.icon")


def write_launcher(path: Path, script: str, environment: object) -> None:
    if environment is None:
        environment = {}
    if not isinstance(environment, dict):
        fail("trimui_app.env must be an object")

    lines = [
        "#!/bin/sh",
        "",
        'APP_DIR=$0',
        'case "$APP_DIR" in */*) APP_DIR=${APP_DIR%/*} ;; *) APP_DIR=. ;; esac',
        'APP_DIR=$(CDPATH= cd -- "$APP_DIR" && pwd)',
        'cd "$APP_DIR" || exit 1',
    ]
    for key, value in environment.items():
        if not isinstance(key, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            fail(f"invalid trimui_app.env key: {key!r}")
        if not isinstance(value, str):
            fail(f"trimui_app.env.{key} must be a string")
        rendered = '"$APP_DIR"' if value == "{app_dir}" else shlex.quote(value)
        lines.append(f"export {key}={rendered}")
    lines.extend(("", f'exec "$APP_DIR/{script}" "$@"', ""))
    path.write_text("\n".join(lines), encoding="utf-8")
    path.chmod(0o755)


def add_tree(archive: zipfile.ZipFile, root: Path) -> None:
    for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
        relative = path.relative_to(root.parent).as_posix()
        if path.is_dir():
            info = zipfile.ZipInfo(relative.rstrip("/") + "/")
            info.create_system = 3
            info.external_attr = (stat.S_IFDIR | 0o755) << 16
            archive.writestr(info, b"")
        else:
            archive.write(path, relative)


def main() -> None:
    if len(sys.argv) != 5:
        fail("usage: trimui_app.py <manifest> <dist> <port-dir> <output-dir>")

    manifest_path, dist, port_dir, output_dir = map(Path, sys.argv[1:])
    with manifest_path.open(encoding="utf-8") as handle:
        manifest = json.load(handle)
    settings = manifest.get("trimui_app", {})
    if not isinstance(settings, dict):
        fail("trimui_app must be an object")

    script = safe_component(manifest.get("script"), "script")
    folder = safe_component(settings.get("folder", manifest.get("port_dir") or manifest.get("name")), "trimui_app.folder")
    title = settings.get("label", manifest.get("title") or manifest.get("name") or folder)
    label_zh = settings.get("label_zh", title)
    description = settings.get("description", manifest.get("portmaster", {}).get("desc") or title)
    package = settings.get("package", f"com.jenny92.{re.sub(r'[^a-z0-9]+', '', folder.lower())}")
    for value, field in ((title, "label"), (label_zh, "label_zh"), (description, "description"), (package, "package")):
        if not isinstance(value, str) or not value:
            fail(f"invalid trimui_app.{field}")
    if not re.fullmatch(r"[A-Za-z0-9._-]+", package):
        fail(f"invalid trimui_app.package: {package!r}")

    include = settings.get("include", [script])
    if not isinstance(include, list) or not include:
        fail("trimui_app.include must be a non-empty array")
    include = [safe_component(value, "trimui_app.include item") for value in include]
    if script not in include:
        fail("trimui_app.include must contain the launcher script")

    archive_label = safe_component(settings.get("archive", str(title)), "trimui_app.archive")
    output_dir.mkdir(parents=True, exist_ok=True)
    output = output_dir / f"[TrimUI App] {archive_label}.zip"

    with tempfile.TemporaryDirectory(prefix="trimui-app-") as temporary:
        stage = Path(temporary) / folder
        stage.mkdir()
        for item in include:
            source = safe_source(dist, item, "trimui_app.include item")
            if not source.exists():
                fail(f"dist item does not exist: {source}")
            copy_clean(source, stage / item)

        icon = choose_icon(manifest, settings, port_dir, dist)
        shutil.copy2(icon, stage / "icon.png")
        config = {
            "package": package,
            "label": title,
            "label.ch.lang": label_zh,
            "icon": "icon.png",
            "iconsel": "icon.png",
            "icontop": "icon.png",
            "launch": "launch.sh",
            "description": description,
        }
        (stage / "config.json").write_text(
            json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        write_launcher(stage / "launch.sh", script, settings.get("env"))

        temporary_archive = output.with_name(f".{output.name}.tmp")
        with zipfile.ZipFile(temporary_archive, "w", zipfile.ZIP_DEFLATED, compresslevel=1) as archive:
            add_tree(archive, stage)
        os.replace(temporary_archive, output)

    print(output)


if __name__ == "__main__":
    main()
