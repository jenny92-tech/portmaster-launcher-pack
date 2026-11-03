# INPUT: synthetic images and fixed refinement policy
# OUTPUT: quality gating, nominal-size checks and isolated original decode fixture
# POS: offline host only; no game, device or installation
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from sts2_test_inputs import external_file

ROOT=Path(__file__).resolve().parents[1]
TOOLS=ROOT/'ports/sts2/src/tools/godot_pck';sys.path.insert(0,str(TOOLS))
import refine_quarter_texture as refine

class RefinementTests(unittest.TestCase):
 def test_nominal_and_quality_gates(self):
  self.assertEqual(refine.nominal({'gpu':[200,100],'data_format':2,'image_format':5}),80000)
  self.assertEqual(refine.nominal({'gpu':[200,100],'data_format':0,'image_format':37}),5200)
  with self.assertRaises(ValueError):refine.nominal({'gpu':[1,1],'data_format':0,'image_format':15})
  data=bytes([30,60,90,255])*64
  q=refine.quality(data,data,8,8,8);self.assertEqual(q['status'],'accepted')
  altered=bytearray(data);altered[3]=0
  q=refine.quality(data,altered,8,8,8);self.assertEqual(q['status'],'quality_rejected')
 def test_source_mismatch_fails_before_build(self):
  with tempfile.TemporaryDirectory() as t:
   p=Path(t)
   for n in ('source','main','delta','prior','tex'): (p/n).write_bytes(b'not a validated pack')
   cmd=[sys.executable,str(TOOLS/'refine_quarter_texture.py'),'--source-pck',str(p/'source'),'--base-main',str(p/'main'),'--previous-delta',str(p/'delta'),'--previous-report',str(p/'prior'),'--texture-report',str(p/'tex'),'--godot','/not-run','--astcenc-dir','/not-read','--compiler','/not-run','--cache',str(p/'cache'),'--output',str(p/'out'),'--report',str(p/'report')]
   r=subprocess.run(cmd,text=True,capture_output=True,timeout=10)
   self.assertNotEqual(r.returncode,0);self.assertIn('input identity mismatch',r.stderr);self.assertFalse((p/'cache').exists())
 def test_decode_original_webp(self):
  GODOT=external_file(self,'STS2_TEST_GODOT')
  with tempfile.TemporaryDirectory() as t:
   p=Path(t);(p/'project.godot').write_text('[application]\nconfig/name="Refinement test"\n')
   args=[str(GODOT),'--headless','--path',str(p),'--script',str(ROOT/'tests/sts2_quarter_texture_fixture.gd'),'--','generate-edge',str(p/'in.ctex')]
   a=subprocess.run(args,text=True,capture_output=True,timeout=60);self.assertEqual(a.returncode,0,a.stdout+a.stderr)
   jobs=p/'jobs.json';jobs.write_text(json.dumps([{'input':str(p/'in.ctex'),'output':str(p/'out.rgba'),'width':64,'height':64}]))
   b=subprocess.run([str(GODOT),'--headless','--path',str(p),'--script',str(refine.WORKER),'--',str(jobs)],text=True,capture_output=True,timeout=60)
   self.assertEqual(b.returncode,0,b.stdout+b.stderr);self.assertIn('REFINE_DECODED\t0',b.stdout);self.assertEqual((p/'out.rgba').stat().st_size,64*64*4)

if __name__=='__main__':unittest.main()
