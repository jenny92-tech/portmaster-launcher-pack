# INPUT: synthetic frozen launcher and ELF headers
# OUTPUT: private VMA entry generation and fail-closed regressions
# POS: no device, engine execution or player data
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'ports/sts2/src/tools'))
import vma_trial_entry as v

class VmaTrialTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.p=Path(self.tmp.name)
        self.entry=self.p/'entry.sh';self.entry.write_text('''#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec > "$TESTDIR/log.txt" 2>&1
cache_root="/tmp/sts2-vk-test-$(id -u)"
engine_hash='''+v.OLD_ENGINE+'''
if digest(Path(image)) != image_hash:
  pass
  configure_memory_trial || exit 1
''')
        self.engine=self.p/'engine';self.engine.write_bytes(b'\x7fELF\x02\x01'+bytes(10)+(3).to_bytes(2,'little')+(183).to_bytes(2,'little')+b'payload')
        self.ep=patch.object(v,'ENTRY_SHA',hashlib.sha256(self.entry.read_bytes()).hexdigest());self.ep.start();self.addCleanup(self.ep.stop)
        self.gp=patch.object(v,'ENGINE_SHA',hashlib.sha256(self.engine.read_bytes()).hexdigest());self.gp.start();self.addCleanup(self.gp.stop)
        self.lab='/tmp/sts2-vma-lab-0123456789abcdef'
    def test_trial_is_scoped_and_does_not_touch_official_entry(self):
        before=self.entry.read_bytes();s=v.generate(self.entry,self.engine,self.lab)
        self.assertIn('case "${SLL_VMA_TRIAL:-}" in 0|32|64)',s)
        self.assertIn('SCRIPT_DIR="/mnt/sdcard/roms/ports"',s)
        self.assertIn('rendering_device/vulkan/log_memory_statistics=true',s)
        self.assertIn('MAIN_PACK_ARG="$GAME/SlayTheSpire2.pck"',s)
        self.assertIn('missing or changed isolated candidate engine',s)
        self.assertEqual(self.entry.read_bytes(),before)
    def test_malformed_lab_and_changed_inputs_rejected(self):
        for lab in ['/tmp/sts2-vma-lab-../../other','/tmp/sts2-vma-lab-x','/sd/sts2-vma-lab-0123456789abcdef']:
            with self.assertRaises(ValueError):v.generate(self.entry,self.engine,lab)
        self.entry.write_text('changed')
        with self.assertRaises(ValueError):v.generate(self.entry,self.engine,self.lab)
    def test_wrong_architecture_and_symlink_rejected(self):
        self.engine.write_bytes(b'\x7fELF\x02\x01'+bytes(10)+(3).to_bytes(2,'little')+(62).to_bytes(2,'little'))
        with patch.object(v,'ENGINE_SHA',hashlib.sha256(self.engine.read_bytes()).hexdigest()):
            with self.assertRaises(ValueError):v.generate(self.entry,self.engine,self.lab)
        link=self.p/'link';link.symlink_to(self.engine)
        with self.assertRaises(ValueError):v.generate(self.entry,link,self.lab)

if __name__=='__main__':unittest.main()
