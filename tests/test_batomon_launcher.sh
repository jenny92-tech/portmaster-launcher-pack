#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="$ROOT/ports/batomon"
MANIFEST="$PORT/manifest.json"
SCRIPT="$PORT/src/launcher.sh"
OFFLINE_SCRIPT="$PORT/src/launcher-offline.sh"
DIST_SCRIPT="$PORT/src/scripts/dist-port.sh"
PREP_SCRIPT="$PORT/src/scripts/prepare-batomon-pck.py"

[ -f "$MANIFEST" ] || { echo "missing manifest: $MANIFEST" >&2; exit 1; }
[ -f "$SCRIPT" ] || { echo "missing launcher: $SCRIPT" >&2; exit 1; }
[ -x "$OFFLINE_SCRIPT" ] || { echo "missing executable offline launcher: $OFFLINE_SCRIPT" >&2; exit 1; }
[ -x "$PORT/src/bin/xdg-open" ] || { echo "missing executable xdg-open helper" >&2; exit 1; }
[ -x "$PORT/src/bin/steam-login-url.py" ] || { echo "missing executable Steam login URL helper" >&2; exit 1; }
[ -x "$PORT/src/bin/steam-login-relay.py" ] || { echo "missing executable Steam login relay helper" >&2; exit 1; }
[ -x "$PORT/src/bin/steam-login-page.py" ] || { echo "missing executable Steam login page helper" >&2; exit 1; }
[ -x "$DIST_SCRIPT" ] || { echo "missing executable dist script: $DIST_SCRIPT" >&2; exit 1; }
[ -x "$PREP_SCRIPT" ] || { echo "missing executable prepare script: $PREP_SCRIPT" >&2; exit 1; }

python3 - "$MANIFEST" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    manifest = json.load(fh)

assert manifest["port_dir"] == "batomon"
assert manifest["script"] == "Batomon Showdown.sh"
assert manifest["engine"].startswith("Godot 4")
PY

grep -Fq 'GAME_PCK="$GAMEDIR/gamedata/batomon_showdown.pck"' "$SCRIPT" || {
  echo "launcher does not target gamedata/batomon_showdown.pck" >&2
  exit 1
}

grep -Fq './godot.mono' "$SCRIPT" || {
  echo "launcher does not use bundled godot.mono" >&2
  exit 1
}

grep -Fq 'BATOMON_SCENE' "$SCRIPT" || {
  echo "launcher does not support an explicit scene override" >&2
  exit 1
}

grep -Fq 'GAMEDIR/bin' "$SCRIPT" || {
  echo "launcher does not prepend bundled helper directory to PATH" >&2
  exit 1
}

if grep -Fq 'BATOMON_SCENE' "$OFFLINE_SCRIPT"; then
  echo "offline launcher should use the prepared PCK rather than direct scene loading" >&2
  exit 1
fi

grep -Fq 'libsteam_api64.so' "$DIST_SCRIPT" || {
  echo "dist script does not package Steam API stub" >&2
  exit 1
}

grep -Fq 'Batomon Showdown Offline.sh' "$DIST_SCRIPT" || {
  echo "dist script does not package offline launcher" >&2
  exit 1
}

grep -Fq 'cp -R "$SRC_ROOT/bin"' "$DIST_SCRIPT" || {
  echo "dist script does not package helper scripts" >&2
  exit 1
}

grep -Fq 'addons/godotsteam/linuxarm64' "$DIST_SCRIPT" || {
  echo "dist script does not create GodotSteam linuxarm64 layout" >&2
  exit 1
}

if grep -Eq '[0-9a-f]{64}' "$PREP_SCRIPT"; then
  echo "prepare script must not hard-code the Batomon encryption key" >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

python3 - "$tmpdir/input.pck" <<'PY'
import hashlib
import struct
import sys

out = sys.argv[1]
magic = 0x43504447
version = 2
major, minor, patch = 4, 3, 0
flags = 0
header_size = 4 + 4 + 4 + 4 + 4 + 4 + 8 + 16 * 4
files = [
    ("res://addons/godotsteam/godotsteam.gdextension", b'[libraries]\nlinux.release.x86_64 = "x86.so"\n'),
    (
        "res://game/states/login_state.tscn.remap",
        b'[remap]\n\npath="res://.godot/exported/login.scn"\n',
    ),
    (
        "res://game/states/title_state.tscn.remap",
        b'[remap]\n\npath="res://.godot/exported/title.scn"\n',
    ),
    ("res://hello.txt", b"hello\n"),
]

dir_size = 4
entries_meta = []
for path, data in files:
    encoded = path.encode("utf-8")
    padded_len = len(encoded) + ((4 - len(encoded) % 4) % 4)
    dir_size += 4 + padded_len + 8 + 8 + 16 + 4
    entries_meta.append((encoded, padded_len, data))

file_base = (header_size + dir_size + 31) & ~31
cursor = file_base
dir_section = bytearray(struct.pack("<I", len(files)))
file_blob = bytearray()
for encoded, padded_len, data in entries_meta:
    pad = ((cursor + 31) & ~31) - cursor
    file_blob.extend(b"\0" * pad)
    cursor += pad
    dir_section += struct.pack("<I", padded_len)
    dir_section += encoded + b"\0" * (padded_len - len(encoded))
    dir_section += struct.pack("<Q", cursor - file_base)
    dir_section += struct.pack("<Q", len(data))
    dir_section += hashlib.md5(data).digest()
    dir_section += struct.pack("<I", 0)
    file_blob.extend(data)
    cursor += len(data)

header = struct.pack("<IIIIIIQ", magic, version, major, minor, patch, flags, file_base)
header += b"\0" * (16 * 4)
with open(out, "wb") as fh:
    fh.write(header)
    fh.write(dir_section)
    fh.write(b"\0" * (file_base - len(header) - len(dir_section)))
    fh.write(file_blob)
PY

python3 "$PREP_SCRIPT" \
  --input "$tmpdir/input.pck" \
  --output "$tmpdir/output.pck" \
  --patch-godotsteam-arm64 \
  --redirect-login-to-title

python3 - "$tmpdir/output.pck" <<'PY'
import struct
import sys

data = open(sys.argv[1], "rb").read()
magic, version, major, minor, patch, flags, file_base = struct.unpack_from("<IIIIIIQ", data, 0)
assert magic == 0x43504447
assert version == 2
assert (major, minor, patch) == (4, 3, 0)
assert flags == 0
assert file_base % 32 == 0

pos = 4 + 4 + 4 + 4 + 4 + 4 + 8 + 16 * 4
count = struct.unpack_from("<I", data, pos)[0]
pos += 4
assert count == 4
paths = {}
for _ in range(count):
    path_len = struct.unpack_from("<I", data, pos)[0]
    pos += 4
    path = data[pos:pos + path_len].rstrip(b"\0").decode("utf-8")
    pos += path_len
    offset, size = struct.unpack_from("<QQ", data, pos)
    pos += 16
    pos += 16
    file_flags = struct.unpack_from("<I", data, pos)[0]
    pos += 4
    assert file_flags == 0
    paths[path] = data[file_base + offset:file_base + offset + size]

gdext = paths["res://addons/godotsteam/godotsteam.gdextension"].decode("utf-8")
assert "linux.release.arm64" in gdext
assert "res://addons/godotsteam/linuxarm64/libgodotsteam.linux.template_release.arm64.so" in gdext
assert paths["res://game/states/login_state.tscn.remap"] == paths["res://game/states/title_state.tscn.remap"]
assert b"title.scn" in paths["res://game/states/login_state.tscn.remap"]
assert paths["res://hello.txt"] == b"hello\n"
PY
