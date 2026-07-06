#!/usr/bin/env python3
"""Prepare Batomon's Godot PCK for PortMaster.

Reads a Godot 4 PCK, decrypts encrypted directory/files when --key is
provided, optionally patches GodotSteam's .gdextension for linux arm64, and
writes an unencrypted format-v2 PCK that the bundled Godot runtime can load.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import struct
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

MAGIC = 0x43504447
FORMAT_V2 = 2
FORMAT_V3 = 3
PACK_DIR_ENCRYPTED = 1 << 0
PACK_REL_FILEBASE = 1 << 1
PACK_FILE_ENCRYPTED = 1 << 0
ALIGNMENT = 32

GODOTSTEAM_PATH = "res://addons/godotsteam/godotsteam.gdextension"
LOGIN_STATE_REMAP_PATH = "res://game/states/login_state.tscn.remap"
TITLE_STATE_REMAP_PATH = "res://game/states/title_state.tscn.remap"
GODOTSTEAM_ARM64_LINE = (
    'linux.release.arm64 = '
    '"res://addons/godotsteam/linuxarm64/libgodotsteam.linux.template_release.arm64.so"'
)


@dataclass
class Entry:
    path: str
    offset: int
    size: int
    flags: int
    md5: bytes


def align(value: int, alignment: int = ALIGNMENT) -> int:
    return (value + alignment - 1) & ~(alignment - 1)


def parse_key(value: str | None) -> bytes | None:
    if not value:
        return None
    key = value.strip().lower()
    if key.startswith("0x"):
        key = key[2:]
    if len(key) != 64:
        raise SystemExit("--key must be 64 hex characters")
    try:
        return bytes.fromhex(key)
    except ValueError as exc:
        raise SystemExit("--key must be valid hex") from exc


def crypto_backend():
    try:
        from Crypto.Cipher import AES  # type: ignore

        return ("pycryptodome", AES)
    except ModuleNotFoundError as exc:
        openssl = shutil.which("openssl")
        if openssl:
            return ("openssl", openssl)
        raise SystemExit(
            "Encrypted PCK input requires PyCryptodome or openssl."
        ) from exc


def decrypt_blob(blob: bytes, key: bytes) -> bytes:
    if len(blob) < 40:
        raise ValueError("encrypted blob is too short")
    expected_md5 = blob[:16]
    length = struct.unpack_from("<Q", blob, 16)[0]
    iv = blob[24:40]
    padded = length + ((16 - length % 16) % 16)
    ciphertext = blob[40 : 40 + padded]
    if len(ciphertext) != padded:
        raise ValueError("encrypted blob is truncated")
    backend, impl = crypto_backend()
    if backend == "pycryptodome":
        data = impl.new(key, impl.MODE_CFB, iv=iv, segment_size=128).decrypt(ciphertext)[:length]
    else:
        proc = subprocess.run(
            [
                impl,
                "enc",
                "-aes-256-cfb",
                "-d",
                "-K",
                key.hex(),
                "-iv",
                iv.hex(),
                "-nopad",
            ],
            input=ciphertext,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if proc.returncode != 0:
            raise ValueError(proc.stderr.decode("utf-8", "replace").strip())
        data = proc.stdout[:length]
    actual_md5 = hashlib.md5(data).digest()
    if actual_md5 != expected_md5:
        raise ValueError("decrypted MD5 mismatch; wrong key or corrupt PCK")
    return data


def read_header(data: bytes):
    if len(data) < 96:
        raise SystemExit("input is too small to be a Godot 4 PCK")
    magic, version, major, minor, patch, flags = struct.unpack_from("<IIIIII", data, 0)
    if magic != MAGIC:
        raise SystemExit("input is not a Godot PCK (missing GDPC magic)")
    if version not in (FORMAT_V2, FORMAT_V3):
        raise SystemExit(f"unsupported PCK format version: {version}")
    file_base = struct.unpack_from("<Q", data, 24)[0]
    dir_offset = None
    if version == FORMAT_V3:
        dir_offset = struct.unpack_from("<Q", data, 32)[0]
    return version, major, minor, patch, flags, file_base, dir_offset


def read_directory(data: bytes, key: bytes | None):
    version, major, minor, patch, flags, file_base, dir_offset = read_header(data)
    rel_filebase = bool(flags & PACK_REL_FILEBASE) or version == FORMAT_V3
    absolute_file_base = file_base

    if version == FORMAT_V2:
        dir_pos = 4 + 4 + 4 + 4 + 4 + 4 + 8 + (16 * 4)
    else:
        dir_pos = dir_offset or 0
        absolute_file_base = file_base

    if rel_filebase:
        absolute_file_base += 0
        if version == FORMAT_V3:
            dir_pos += 0

    count = struct.unpack_from("<I", data, dir_pos)[0]
    pos = dir_pos + 4
    if flags & PACK_DIR_ENCRYPTED:
        if key is None:
            raise SystemExit("input PCK has an encrypted directory; pass --key")
        encrypted_dir = data[pos:]
        directory = decrypt_blob(encrypted_dir, key)
        pos = 0
    else:
        directory = data

    entries: list[Entry] = []
    for _ in range(count):
        path_len = struct.unpack_from("<I", directory, pos)[0]
        pos += 4
        path_raw = directory[pos : pos + path_len]
        pos += path_len
        path = path_raw.rstrip(b"\0").decode("utf-8")
        offset, size = struct.unpack_from("<QQ", directory, pos)
        pos += 16
        md5 = directory[pos : pos + 16]
        pos += 16
        file_flags = struct.unpack_from("<I", directory, pos)[0]
        pos += 4
        entries.append(Entry(path, absolute_file_base + offset, size, file_flags, md5))

    return (major, minor, patch), entries


def read_file(data: bytes, entry: Entry, key: bytes | None) -> bytes:
    if entry.flags & PACK_FILE_ENCRYPTED:
        if key is None:
            raise SystemExit(f"{entry.path}: encrypted file requires --key")
        padded = entry.size + ((16 - entry.size % 16) % 16)
        blob = data[entry.offset : entry.offset + 40 + padded]
        return decrypt_blob(blob, key)

    blob = data[entry.offset : entry.offset + entry.size]
    if hashlib.md5(blob).digest() != entry.md5:
        raise SystemExit(f"{entry.path}: MD5 mismatch in input PCK")
    return blob


def patch_godotsteam(text: str) -> str:
    if "linux.release.arm64" in text:
        return text
    marker = "[libraries]"
    if marker not in text:
        return text.rstrip() + "\n\n[libraries]\n" + GODOTSTEAM_ARM64_LINE + "\n"
    lines = text.splitlines()
    insert_at = None
    for i, line in enumerate(lines):
        if line.strip() == marker:
            insert_at = i + 1
            continue
        if insert_at is not None and line.startswith("[") and line.strip() != marker:
            insert_at = i
            break
    if insert_at is None:
        insert_at = len(lines)
    while insert_at < len(lines) and lines[insert_at].strip().startswith("linux."):
        insert_at += 1
    lines.insert(insert_at, GODOTSTEAM_ARM64_LINE)
    return "\n".join(lines) + "\n"


def collect_files(
    data: bytes,
    entries: list[Entry],
    key: bytes | None,
    patch_arm64: bool,
    redirect_login_to_title: bool,
):
    title_state_remap = None
    if redirect_login_to_title:
        for entry in entries:
            if entry.path == TITLE_STATE_REMAP_PATH:
                title_state_remap = read_file(data, entry, key)
                break
        if title_state_remap is None:
            raise SystemExit(f"{TITLE_STATE_REMAP_PATH}: missing title scene remap")

    files: list[tuple[str, bytes]] = []
    for entry in entries:
        payload = read_file(data, entry, key)
        if patch_arm64 and entry.path == GODOTSTEAM_PATH:
            payload = patch_godotsteam(payload.decode("utf-8")).encode("utf-8")
        if redirect_login_to_title and entry.path == LOGIN_STATE_REMAP_PATH:
            payload = title_state_remap
        files.append((entry.path, payload))
    return files


def dir_entry(path: str, payload: bytes, offset: int) -> bytes:
    encoded = path.encode("utf-8")
    padded_len = len(encoded) + ((4 - len(encoded) % 4) % 4)
    out = struct.pack("<I", padded_len)
    out += encoded + b"\0" * (padded_len - len(encoded))
    out += struct.pack("<Q", offset)
    out += struct.pack("<Q", len(payload))
    out += hashlib.md5(payload).digest()
    out += struct.pack("<I", 0)
    return out


def write_unencrypted_v2(output: Path, version_tuple, files: list[tuple[str, bytes]]) -> None:
    major, minor, patch = version_tuple
    header_size = 4 + 4 + 4 + 4 + 4 + 4 + 8 + (16 * 4)
    dir_size = 4
    for path, _ in files:
        encoded_len = len(path.encode("utf-8"))
        padded_len = encoded_len + ((4 - encoded_len % 4) % 4)
        dir_size += 4 + padded_len + 8 + 8 + 16 + 4

    file_base = align(header_size + dir_size)
    file_blob = bytearray()
    entries = []
    cursor = file_base
    for path, payload in files:
        padding = align(cursor) - cursor
        file_blob.extend(b"\0" * padding)
        cursor += padding
        entries.append(dir_entry(path, payload, cursor - file_base))
        file_blob.extend(payload)
        cursor += len(payload)

    header = struct.pack("<IIIIIIQ", MAGIC, FORMAT_V2, major, minor, patch, 0, file_base)
    header += b"\0" * (16 * 4)
    directory = struct.pack("<I", len(files)) + b"".join(entries)

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("wb") as fh:
        fh.write(header)
        fh.write(directory)
        fh.write(b"\0" * (file_base - len(header) - len(directory)))
        fh.write(file_blob)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--key", default=os.environ.get("BATOMON_PCK_KEY"))
    parser.add_argument("--patch-godotsteam-arm64", action="store_true")
    parser.add_argument(
        "--redirect-login-to-title",
        action="store_true",
        help="Point login_state.tscn at the packaged title_state scene for offline handheld use.",
    )
    args = parser.parse_args()

    key = parse_key(args.key)
    data = args.input.read_bytes()
    version_tuple, entries = read_directory(data, key)
    files = collect_files(
        data,
        entries,
        key,
        args.patch_godotsteam_arm64,
        args.redirect_login_to_title,
    )
    write_unencrypted_v2(args.output, version_tuple, files)
    print(f"Wrote {args.output} ({args.output.stat().st_size:,} bytes, {len(files)} files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
