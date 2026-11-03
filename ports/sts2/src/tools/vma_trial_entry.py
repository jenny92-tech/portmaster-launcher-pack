#!/usr/bin/env python3
# INPUT: exact installed v0.110.1 entry, audited RC engine and a private device lab path
# OUTPUT: separate non-menu 0/32/64 VMA trial launcher; never changes the device
# POS: reproducible isolation wrapper; normal launcher and game data are untouched
import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import stat

ENTRY_SHA = '86c154d626817b5245ca762e680a807895f9d3558e262ae919f1332985ff2fa1'
ENGINE_SHA = '50a01ff328a1270f630056f317f58639468df46649a6d8fc587c8681d7f8875e'
BUILD = 'bf5a3e3ec1ead4afc5ac71cd1369d6500371e7cc4db4da16b790e4fe55ed1fbc'
OLD_ENGINE = 'bf9e9620201f030e587c6006f0d9d488c91312e43dddebdc96b20f0dbe07935d'


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda: f.read(1024 * 1024), b''): h.update(b)
    return h.hexdigest()


def replace_once(text, old, new):
    if text.count(old) != 1: raise ValueError('unexpected entry template layout')
    return text.replace(old, new, 1)


def generate(entry, engine, lab):
    entry, engine = Path(entry), Path(engine)
    if entry.is_symlink() or engine.is_symlink() or not entry.is_file() or not engine.is_file():
        raise ValueError('entry and engine must be regular non-symlink files')
    if sha(entry) != ENTRY_SHA or sha(engine) != ENGINE_SHA: raise ValueError('entry or engine identity mismatch')
    with engine.open('rb') as f: header = f.read(20)
    if len(header) != 20 or header[:6] != b'\x7fELF\x02\x01' or int.from_bytes(header[16:18], 'little') != 3 or int.from_bytes(header[18:20], 'little') != 183:
        raise ValueError('engine must be little-endian ELF64 AArch64 PIE')
    p = PurePosixPath(lab)
    if p.parent != PurePosixPath('/tmp') or not re.fullmatch(r'sts2-vma-lab-[0-9a-f]{16}', p.name):
        raise ValueError('lab must be a unique /tmp/sts2-vma-lab-<16 hex> directory')
    s = entry.read_text()
    s = replace_once(s, 'SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"', 'SCRIPT_DIR="/mnt/sdcard/roms/ports"')
    s = replace_once(s, 'exec > "$TESTDIR/log.txt" 2>&1', '''case "${SLL_VMA_TRIAL:-}" in 0|32|64) ;; *) echo "invalid VMA trial" >&2; exit 1;; esac
set -o noclobber
exec > "''' + str(p) + '''/run-${SLL_VMA_TRIAL}.log" 2>&1 || exit 1
set +o noclobber''')
    s = replace_once(s, 'cache_root="/tmp/sts2-vk-test-$(id -u)"', 'cache_root="' + str(p) + '/execview"')
    s = replace_once(s, 'engine_hash='+OLD_ENGINE, 'engine_hash='+ENGINE_SHA)
    s = replace_once(s, 'if digest(Path(image)) != image_hash:', 'raise SystemExit("[STS2-VK] missing or changed isolated candidate engine")\nif digest(Path(image)) != image_hash:')
    marker = '  configure_memory_trial || exit 1\n'
    insert = '''  configure_memory_trial || exit 1
  [ "$BUILD_ID" = "''' + BUILD + '''" ] && [ -n "${SLL_DIAG_XDG_ROOT:-}" ] && [ "${SLL_TEXTURE_DIAG:-0}" = 1 ] && [ -z "${SLL_MEMORY_TRIAL:-}" ] || { echo "[STS2-VK] VMA experiment identity or isolation mismatch"; exit 1; }
  python3 - "$GAME/SlayTheSpire2.pck" "$MAIN_PACK" <<'VERIFY_VMA_PACK' || exit 1
import os,sys
from pathlib import Path
link,main=map(Path,sys.argv[1:])
if not link.is_symlink() or main.is_symlink() or not main.is_file() or os.readlink(link)!=str(main) or link.resolve(strict=True)!=main.resolve(strict=True):
 raise ValueError('VMA trial main link does not match verified active main')
VERIFY_VMA_PACK
  printf '\\n[rendering]\\nrendering_device/vulkan/preferred_large_heap_block_size_mb=%s\\nrendering_device/vulkan/log_memory_statistics=true\\n' "$SLL_VMA_TRIAL" >> "$GAME/override.cfg" || exit 1
  MAIN_PACK_ARG="$GAME/SlayTheSpire2.pck"
'''
    return replace_once(s, marker, insert)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('entry','engine','output'): p.add_argument('--'+name,required=True,type=Path)
    p.add_argument('--device-lab',required=True)
    a=p.parse_args(); data=generate(a.entry,a.engine,a.device_lab).encode()
    fd=os.open(a.output,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o700)
    with os.fdopen(fd,'wb') as f: f.write(data); f.flush(); os.fsync(f.fileno())
    print(hashlib.sha256(data).hexdigest())

if __name__=='__main__': main()
