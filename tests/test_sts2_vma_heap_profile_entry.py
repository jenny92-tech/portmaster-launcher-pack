# INPUT: synthetic VMA launcher and profiler identities
# OUTPUT: fail-closed isolated preload insertion checks
# POS: no device, executable code or player data
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'ports/sts2/src/tools'))
import vma_heap_profile_entry as g

class ProfileEntryTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);p=Path(self.tmp.name)
  self.entry=p/'entry';self.entry.write_text('  launcher_platform_exec python3 "$TESTDIR/launch_exec_view.py" -- \\\n    /bin/bash -c \'exec -a unityloader "$@"\' sts2-vk "$GAME/godot.mono" \\\n')
  self.pre=p/'pre';self.pre.write_bytes(b'preload');self.unwind=p/'unwind';self.unwind.write_bytes(b'unwind')
  for name,file in (('ENTRY_SHA',self.entry),('PRELOAD_SHA',self.pre),('UNWIND_SHA',self.unwind)):
   x=patch.object(g,name,hashlib.sha256(file.read_bytes()).hexdigest());x.start();self.addCleanup(x.stop)
  self.out='/userdata/sts2-native-profile-0123456789abcdef'
 def test_preload_occurs_only_after_exec_view(self):
  s=g.generate(self.entry,self.pre,self.unwind,self.out);self.assertEqual(s.count('LD_PRELOAD='),1)
  self.assertLess(s.index('launcher_platform_exec python3'),s.index('export DUMP_HEAPTRACK_OUTPUT'))
  self.assertIn('umask 077',s);self.assertIn('/trace.raw',s);self.assertIn('libunwind.so.8',s)
 def test_foreign_paths_and_modified_inputs_rejected(self):
  for out in ('/tmp/sts2-native-profile-0123456789abcdef','/userdata/sts2-native-profile-../../other'):
   with self.assertRaises(ValueError):g.generate(self.entry,self.pre,self.unwind,out)
  self.pre.write_bytes(b'changed')
  with self.assertRaises(ValueError):g.generate(self.entry,self.pre,self.unwind,self.out)
 def test_reviewed_16_frame_identity_is_independently_accepted(self):
  other=Path(self.tmp.name)/'other';other.write_bytes(b'sixteen');h=hashlib.sha256(other.read_bytes()).hexdigest()
  with patch.object(g,'PRELOAD_16_SHA',h):
   result=g.generate(self.entry,other,self.unwind,self.out)
   self.assertIn(h,result)
 def test_existing_preload_rejected(self):
  self.entry.write_text(self.entry.read_text()+'LD_PRELOAD=other\n')
  with patch.object(g,'ENTRY_SHA',hashlib.sha256(self.entry.read_bytes()).hexdigest()):
   with self.assertRaises(ValueError):g.generate(self.entry,self.pre,self.unwind,self.out)
if __name__=='__main__':unittest.main()
