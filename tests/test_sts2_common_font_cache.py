# INPUT: six common font delta and verified original PCK, optional native test engine
# OUTPUT: fail-closed source identity and same-engine UID/font/image validation
# POS: private offline fixtures only; no game or device execution
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from sts2_test_inputs import external_file

ROOT=Path(__file__).resolve().parents[1]
TOOL=ROOT/'ports/sts2/src/tools/godot_pck/strip_common_font_cache.py'
sys.path.insert(0,str(TOOL.parent))
import low_texture_overlay as low
import strip_common_font_cache as common

class CommonFontCacheTests(unittest.TestCase):
 def test_wrong_source_is_rejected(self):
  with tempfile.TemporaryDirectory() as t:
   d=Path(t);(d/'source').write_bytes(b'bad');(d/'base').write_bytes(b'bad')
   cmd=[sys.executable,str(TOOL),'--source-pck',str(d/'source'),'--base-main',str(d/'base'),'--godot','/not-executed','--output',str(d/'out.pck'),'--report',str(d/'report.json'),'--evidence-dir',str(d/'previews')]
   r=subprocess.run(cmd,capture_output=True,text=True,timeout=10)
   self.assertNotEqual(r.returncode,0);self.assertIn('identity mismatch',r.stderr);self.assertFalse((d/'out.pck').exists())
 def test_linux_arm64_exact_six_fonts_and_uid(self):
  SOURCE=external_file(self,'STS2_TEST_SOURCE_PCK')
  DELTA=external_file(self,'STS2_TEST_COMMON_FONT_CACHE_DELTA')
  REPORT=external_file(self,'STS2_TEST_COMMON_FONT_CACHE_REPORT')
  ENGINE=external_file(self,'STS2_TEST_GODOT_ARM64')
  docker=shutil.which('docker')
  if not docker:self.skipTest('Docker is unavailable for the Linux ARM64 fixture')
  image=subprocess.run([docker,'image','inspect','--format','{{.Architecture}}','debian:bookworm-slim'],capture_output=True,text=True,timeout=10)
  if image.returncode or image.stdout.strip()!='arm64':self.skipTest('local ARM64 image unavailable')
  report=json.loads(REPORT.read_text());si=low.read_pack(SOURCE);di=low.read_pack(DELTA)
  self.assertEqual(len(report['resources']),6);self.assertEqual(len(report['previous_sc_verified']),3)
  self.assertEqual(set(di),{x['target'] for x in report['resources']})
  self.assertEqual(low.file_hash(DELTA),common.DELTA_SHA)
  self.assertEqual({x['target'].split('/')[-1]:x['output_sha256'] for x in report['resources']},common.COMMON_OUTPUTS)
  with tempfile.TemporaryDirectory() as temp,SOURCE.open('rb') as source,DELTA.open('rb') as delta:
   root=Path(temp);(root/'project.godot').write_text('[application]\nconfig/name="Common fonts fixture"\n')
   shutil.copy(ROOT/'tests/sts2_common_font_cache_reload.gd',root/'fixture.gd')
   for record in report['resources']:
    target=record['target'];imp=record['import_path'];data=low.entry_bytes(source,si[imp]);uid=re.search(rb'uid="([^"]+)"',data).group(1).decode()
    (root/'original.res').write_bytes(low.entry_bytes(source,si[target]));(root/target).parent.mkdir(parents=True,exist_ok=True);(root/target).write_bytes(low.entry_bytes(delta,di[target]));(root/imp).parent.mkdir(parents=True,exist_ok=True);(root/imp).write_bytes(data)
    cmd=[docker,'run','--rm','--pull=never','--network=none','--read-only','-v',str(ENGINE)+':/godot:ro','-v',str(root)+':/fixture:ro','--tmpfs','/tmp:rw,noexec,nosuid,size=32m','-e','XDG_DATA_HOME=/tmp/godot-data','debian:bookworm-slim','/godot','--headless','--path','/fixture','--script','res://fixture.gd','--','res://original.res','res://'+imp[:-7],uid]
    with self.subTest(font=target):
     run=subprocess.run(cmd,capture_output=True,text=True,timeout=60)
     self.assertEqual(run.returncode,0,run.stdout+run.stderr);self.assertIn('COMMON_FONT_RELOAD_OK',run.stdout)

if __name__=='__main__':unittest.main()
