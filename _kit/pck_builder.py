#!/usr/bin/env python3
# SPDX-License-Identifier: CC-BY-NC-SA-4.0
# Copyright (c) 2025-2026 jenny92-tech
"""
Build a Godot pck from a manifest. Supports both Godot 3 (format_version=1,
absolute offsets) and Godot 4 (format_version=3, file_base relative offsets).

Manifest is a JSON with this shape:

    {
      "godot_version": "4.5",            # or "3.5.2"
      "project_godot": "project.godot",  # absolute or repo-relative path
      "files": [
        { "res_path": "res://launcher_ui.gd", "src_path": "launcher_ui.gd" },
        { "res_path": "res://launcher_bg.png", "src_path": "assets/launcher_bg.png" },
        ...
      ],
      "output": "build/bootstrap.pck"
    }

Designed to replace the per-port make-bootstrap-pck.py copies in
hk-launcher / heishenhua-launcher / sts2-linux-launcher. Each port now
ships a manifest.json and calls:

    python3 ../../_kit/pck_builder.py manifest.json

Usage:
    python3 _kit/pck_builder.py <manifest.json>
"""

import hashlib
import json
import os
import struct
import sys

MAGIC = 0x43504447  # "GDPC"
ALIGNMENT = 32


def align(offset, alignment=ALIGNMENT):
    return (offset + alignment - 1) & ~(alignment - 1)


def pad_string(s):
    encoded = s.encode("utf-8")
    padded_len = len(encoded) + ((4 - len(encoded) % 4) % 4)
    return padded_len, encoded


def build_dir_entry_v4(path, data, offset):
    """Godot 4 (format_version=3) entry: path_len, padded path, offset, size,
    md5, flags."""
    padded_len, path_bytes = pad_string(path)
    entry = struct.pack("<I", padded_len)
    entry += path_bytes + b"\x00" * (padded_len - len(path_bytes))
    entry += struct.pack("<Q", offset)
    entry += struct.pack("<Q", len(data))
    entry += hashlib.md5(data).digest()
    entry += struct.pack("<I", 0)  # flags
    return entry


def build_dir_entry_v3(path, data, offset):
    """Godot 3 (format_version=1) entry: same field shape minus flags."""
    padded_len, path_bytes = pad_string(path)
    entry = struct.pack("<I", padded_len)
    entry += path_bytes + b"\x00" * (padded_len - len(path_bytes))
    entry += struct.pack("<Q", offset)
    entry += struct.pack("<Q", len(data))
    entry += hashlib.md5(data).digest()
    return entry


def build_v4(files, godot_major, godot_minor, godot_patch, output):
    """Godot 4 pck: format_version=3, header has file_base + dir_base offsets,
    file offsets relative to file_base."""
    FORMAT_VERSION = 3
    PACK_REL_FILEBASE = 0x02
    HEADER_SIZE = 4 + 4 + 4 + 4 + 4 + 4 + 8 + 8 + (16 * 4)  # 104

    file_base = align(HEADER_SIZE)
    entries = []
    file_blob = bytearray()
    cursor = 0
    for path, data in files:
        padding = align(cursor) - cursor
        file_blob.extend(b"\x00" * padding)
        cursor += padding
        entries.append(build_dir_entry_v4(path, data, cursor))
        file_blob.extend(data)
        cursor += len(data)

    file_end = file_base + len(file_blob)
    dir_base = align(file_end)

    header = struct.pack("<I", MAGIC)
    header += struct.pack("<I", FORMAT_VERSION)
    header += struct.pack("<I", godot_major)
    header += struct.pack("<I", godot_minor)
    header += struct.pack("<I", godot_patch)
    header += struct.pack("<I", PACK_REL_FILEBASE)
    header += struct.pack("<Q", file_base)
    header += struct.pack("<Q", dir_base)
    header += b"\x00" * (16 * 4)
    assert len(header) == HEADER_SIZE

    dir_section = struct.pack("<I", len(files))
    for e in entries:
        dir_section += e

    with open(output, "wb") as f:
        f.write(header)
        f.write(b"\x00" * (file_base - HEADER_SIZE))
        f.write(file_blob)
        f.write(b"\x00" * (dir_base - file_end))
        f.write(dir_section)


def build_v3(files, godot_major, godot_minor, godot_patch, output):
    """Godot 3 pck: format_version=1, no file_base/dir_base, file offsets
    absolute from file start."""
    FORMAT_VERSION = 1
    HEADER_SIZE = 4 + 4 + 4 + 4 + 4 + (16 * 4)  # 84

    # Pre-compute dir section size for absolute offset math
    dir_section_size = 4  # file_count
    for path, _ in files:
        padded_len, _ = pad_string(path)
        dir_section_size += 4 + padded_len + 8 + 8 + 16

    file_base = align(HEADER_SIZE + dir_section_size)

    entries = []
    file_blob = bytearray()
    cursor = file_base
    for path, data in files:
        padding = align(cursor) - cursor
        file_blob.extend(b"\x00" * padding)
        cursor += padding
        entries.append(build_dir_entry_v3(path, data, cursor))
        file_blob.extend(data)
        cursor += len(data)

    header = struct.pack("<I", MAGIC)
    header += struct.pack("<I", FORMAT_VERSION)
    header += struct.pack("<I", godot_major)
    header += struct.pack("<I", godot_minor)
    header += struct.pack("<I", godot_patch)
    header += b"\x00" * (16 * 4)
    assert len(header) == HEADER_SIZE

    dir_section = struct.pack("<I", len(files))
    for e in entries:
        dir_section += e

    written = HEADER_SIZE + len(dir_section)
    with open(output, "wb") as f:
        f.write(header)
        f.write(dir_section)
        f.write(b"\x00" * (file_base - written))
        f.write(file_blob)


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: pck_builder.py <manifest.json>")
    manifest_path = sys.argv[1]
    with open(manifest_path) as f:
        manifest = json.load(f)

    root = os.path.dirname(os.path.abspath(manifest_path))
    godot_version = manifest["godot_version"]
    parts = [int(x) for x in godot_version.split(".")]
    while len(parts) < 3:
        parts.append(0)
    major, minor, patch = parts[0], parts[1], parts[2]
    output = os.path.join(root, manifest["output"])

    # Optional embedded project.godot / bootstrap.tscn override
    files = []
    if manifest.get("project_godot"):
        with open(os.path.join(root, manifest["project_godot"]), "rb") as f:
            files.append(("res://project.godot", f.read()))
    if manifest.get("bootstrap_tscn"):
        with open(os.path.join(root, manifest["bootstrap_tscn"]), "rb") as f:
            files.append(("res://bootstrap.tscn", f.read()))

    for entry in manifest.get("files", []):
        src = os.path.join(root, entry["src_path"])
        if not os.path.exists(src):
            print(f"  warn: missing {src}, skipping", file=sys.stderr)
            continue
        with open(src, "rb") as f:
            files.append((entry["res_path"], f.read()))

    os.makedirs(os.path.dirname(output), exist_ok=True)
    if major >= 4:
        build_v4(files, major, minor, patch, output)
    else:
        build_v3(files, major, minor, patch, output)

    size = os.path.getsize(output)
    print(f"Built godot-{major} pck: {output} ({size:,} bytes)")
    for path, data in files:
        print(f"    - {path}: {len(data):,} B")


if __name__ == "__main__":
    main()
