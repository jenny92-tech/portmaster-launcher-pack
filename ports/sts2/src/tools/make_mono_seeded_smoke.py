#!/usr/bin/env python3
# INPUT: audited formal entry and previously reviewed isolated seed block
# OUTPUT: private seeded smoke entry with the same formal artifacts
# POS: diagnostic-only launcher; never edits the normal entry or player settings
import hashlib
from pathlib import Path
import sys

ENTRY='9a46cc88f86463173258945a69f1ba62de50a1643348c3f802488492154a2ca2'
ACTIVE='9b9c64f7ae05b8cd8a4a212716eeae4dd2a08b7a5f7f8a0640cbaa3e8c2e9e1d'
LAB='/tmp/sts2-mono-release-smoke-a1'
ROOT='/tmp/sts2-memory-diag-monoreleasea1'
SEED_SHA='09dd7849cd4fe31792192931ec4ac7e0e94d246cb8c98fc5f61d843182518bb1'

def main(entry, prior, output):
 raw=Path(entry).read_bytes()
 if hashlib.sha256(raw).hexdigest()!=ENTRY:raise ValueError('unexpected formal entry')
 prior=Path(prior).read_text();start=prior.index('  python3 - "$SLL_DIAG_XDG_ROOT" "/tmp/sts2-vma-lab-cf80222427b25a70/settings-seed.json" <<\'SEED_ISOLATED_ZHS\'')
 end=prior.index('SEED_ISOLATED_ZHS\n',start)+len('SEED_ISOLATED_ZHS\n')
 block=prior[start:end]
 if hashlib.sha256(block.encode()).hexdigest()!='0e5cb496143cfc5e682ec0089e9c6cd88d748a033bfd949e6112d644406443b3':raise ValueError('seed block identity mismatch')
 if block.count(SEED_SHA)!=1 or block.count('/tmp/sts2-memory-diag-cf80222427b25a70')!=1:raise ValueError('unexpected seed fixture')
 block=block.replace('/tmp/sts2-vma-lab-cf80222427b25a70/settings-seed.json',LAB+'/settings-seed.json').replace('/tmp/sts2-memory-diag-cf80222427b25a70',ROOT)
 gate='  [ "$BUILD_ID" = "'+ACTIVE+'" ] && [ "${SLL_DIAG_XDG_ROOT:-}" = "'+ROOT+'" ] && [ "${SLL_TEXTURE_DIAG:-0}" = 1 ] || { echo "[STS2-VK] seeded smoke isolation mismatch"; exit 1; }\n'
 text=raw.decode();changes={
  'SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"':'SCRIPT_DIR="/mnt/sdcard/roms/ports"',
  'cache_root="/tmp/sts2-vk-test-$(id -u)"':'cache_root="/tmp/sts2-vk-mono-smoke-a1-$(id -u)"',
  'exec > "$TESTDIR/log.txt" 2>&1':'exec > "'+LAB+'/log.txt" 2>&1',
  '  configure_memory_trial || exit 1':gate+block+'  configure_memory_trial || exit 1',
 }
 for old,new in changes.items():
  if text.count(old)!=1:raise ValueError('entry seam mismatch')
  text=text.replace(old,new,1)
 with Path(output).open('x') as f:f.write(text)

if __name__=='__main__':main(*sys.argv[1:])
