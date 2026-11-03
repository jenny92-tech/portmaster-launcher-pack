# INPUT: source-bound font cache builder and optional private game resources
# OUTPUT: fail-closed identity check and isolated same-engine font reload
# POS: CPU/headless fixtures only; no game launch or device access
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
TOOL=ROOT/'ports/sts2/src/tools/godot_pck/strip_font_cache.py'
SOURCE=ROOT/'.cache/sts2-vulkan-trial/windows-input-cfa10eacaa2a/files/Slay the Spire 2/SlayTheSpire2.pck'
DELTA=ROOT/'.cache/sts2-vulkan-trial/fontcache-delta-final.pck'
REPORT=ROOT/'.cache/sts2-vulkan-trial/fontcache-report-final.json'
ENGINE=ROOT/'.cache/sts2-vulkan-trial/official45/godot45.mono.aarch64'
sys.path.insert(0,str(TOOL.parent))
import low_texture_overlay as low

class FontCacheTests(unittest.TestCase):
 def test_wrong_source_is_rejected_before_execution(self):
  with tempfile.TemporaryDirectory() as t:
   root=Path(t);(root/'source').write_bytes(b'wrong');(root/'base').write_bytes(b'wrong')
   cmd=[sys.executable,str(TOOL),'--source-pck',str(root/'source'),'--base-main',str(root/'base'),'--godot','/not-executed','--output',str(root/'out.pck'),'--report',str(root/'report.json'),'--evidence-dir',str(root/'preview')]
   run=subprocess.run(cmd,capture_output=True,text=True,timeout=10)
   self.assertNotEqual(run.returncode,0);self.assertIn('identity mismatch',run.stderr)
   self.assertFalse((root/'out.pck').exists())
 def test_linux_arm64_reloads_exact_three_fonts(self):
  docker=shutil.which('docker')
  if not docker or not all(p.is_file() for p in (SOURCE,DELTA,REPORT,ENGINE)):self.skipTest('private font candidate or local Linux engine unavailable')
  img=subprocess.run([docker,'image','inspect','--format','{{.Architecture}}','debian:bookworm-slim'],capture_output=True,text=True,timeout=10)
  if img.returncode or img.stdout.strip()!='arm64':self.skipTest('local Linux ARM64 image unavailable')
  report=json.loads(REPORT.read_text());source=low.read_pack(SOURCE);delta=low.read_pack(DELTA)
  self.assertEqual(len(report['resources']),3);self.assertEqual(set(delta),{r['target'] for r in report['resources']})
  with tempfile.TemporaryDirectory() as t, SOURCE.open('rb') as a, DELTA.open('rb') as b:
   root=Path(t);(root/'project.godot').write_text('[application]\nconfig/name="Font reload fixture"\n')
   shutil.copy(ROOT/'tests/sts2_font_cache_reload.gd',root/'fixture.gd')
   for record in report['resources']:
    name=record['target'];(root/'original.res').write_bytes(low.entry_bytes(a,source[name]));(root/'output.res').write_bytes(low.entry_bytes(b,delta[name]))
    cmd=[docker,'run','--rm','--pull=never','--network=none','--read-only','-v',str(ENGINE)+':/godot:ro','-v',str(root)+':/fixture:ro','--tmpfs','/tmp:rw,noexec,nosuid,size=32m','-e','XDG_DATA_HOME=/tmp/godot-data','debian:bookworm-slim','/godot','--headless','--path','/fixture','--script','res://fixture.gd','--','res://original.res','res://output.res']
    with self.subTest(font=name):
     run=subprocess.run(cmd,capture_output=True,text=True,timeout=120)
     self.assertEqual(run.returncode,0,run.stdout+run.stderr);self.assertIn('FONT_RELOAD_OK',run.stdout)

if __name__=='__main__':unittest.main()
