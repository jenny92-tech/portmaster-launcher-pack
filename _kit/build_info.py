#!/usr/bin/env python3
# INPUT:  manifest、已组装的 dist 文件和 UTC 日期
# OUTPUT: build-info.json 与启动脚本内的构建日志
# POS:    所有端口共享的最终负载构建身份生成器
"""Stamp the actual staged payload, not the repository's unrelated changes."""
from __future__ import annotations

import datetime
import hashlib
import json
from pathlib import Path
import shlex
import sys

MARKER = "#@BUILD-LOG"
BEGIN = "#@BUILD-INFO-BEGIN"
END = "#@BUILD-INFO-END"


def packaging_info(data: bytes, kind: str) -> bytes:
    info = json.loads(data)
    info["packaging"] = kind
    return (json.dumps(info, ensure_ascii=False, indent=2) + "\n").encode()


def unstamp(text: str) -> str:
    lines = text.splitlines(keepends=True)
    result = []
    inside = False
    for line in lines:
        if line.strip() == BEGIN:
            if inside:
                raise ValueError("nested build stamp")
            inside = True
            result.append(MARKER + "\n")
        elif line.strip() == END:
            if not inside:
                raise ValueError("unexpected build stamp end")
            inside = False
        elif not inside:
            result.append(MARKER + "\n" if line.strip() == MARKER else line)
    if inside:
        raise ValueError("unterminated build stamp")
    return "".join(result)


def stamp(manifest_path: Path, dist: Path, date: str | None = None) -> dict:
    manifest = json.loads(manifest_path.read_text())
    script = manifest.get("script") or manifest.get("dist", {}).get("script") or manifest_path.parent.name + ".sh"
    folder = manifest.get("portable_dir") or ""
    for name in (script, folder):
        if name and (Path(name).name != name or name in {".", ".."} or "\\" in name):
            raise ValueError("unsafe package path")
    if dist.is_symlink() or not dist.is_dir():
        raise ValueError("dist must be a real directory")
    paths = sorted(dist.rglob("*"))
    if any(path.is_symlink() for path in paths):
        raise ValueError("package payload must not contain symlinks")
    launcher = dist / script
    source = unstamp(launcher.read_text())
    if sum(line.strip() == MARKER for line in source.splitlines()) != 1:
        raise ValueError("launcher must contain exactly one build log marker")
    metadata = dist / folder / "build-info.json"
    if not metadata.parent.is_dir():
        raise ValueError("missing package data directory")
    digest = hashlib.sha256()
    digest.update(manifest_path.read_bytes())
    for path in paths:
        if path == metadata or not path.is_file():
            continue
        name = path.relative_to(dist).as_posix().encode()
        digest.update(len(name).to_bytes(8, "big") + name)
        digest.update((path.stat().st_mode & 0o777).to_bytes(4, "big"))
        content = hashlib.sha256()
        if path == launcher:
            content.update(source.encode())
        else:
            with path.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    content.update(chunk)
        digest.update(content.digest())
    revision = digest.hexdigest()
    date = date or datetime.datetime.now(datetime.timezone.utc).strftime("%Y.%m.%d")
    datetime.datetime.strptime(date, "%Y.%m.%d")
    info = {"package": manifest.get("name", manifest_path.parent.name),
            "build_version": date + "-" + revision[:12],
            "payload_revision": revision, "build_date_utc": date}
    message = "[BUILD] package=" + str(info["package"]) + " build.version=" + info["build_version"]
    block = BEGIN + "\nprintf '%s\\n' " + shlex.quote(message) + "\n" + END + "\n"
    launcher.write_text("".join(block if line.strip() == MARKER else line
                                for line in source.splitlines(keepends=True)))
    metadata.write_text(json.dumps(info, ensure_ascii=False, indent=2) + "\n")
    return info


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: build_info.py <manifest> <dist>")
    print(json.dumps(stamp(Path(sys.argv[1]), Path(sys.argv[2])), ensure_ascii=False))
