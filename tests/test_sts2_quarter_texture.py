# INPUT: synthetic texture policy and isolated Godot image codec fixtures
# OUTPUT: checked identity, quality gate, atlas coordinates and CPU codec behavior
# POS: headless only, no game execution or device access
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from sts2_test_inputs import external_file

ROOT=Path(__file__).resolve().parents[1]
TOOLS=ROOT/'ports/sts2/src/tools/godot_pck'
sys.path.insert(0,str(TOOLS))
import low_texture_overlay as low
import quarter_texture_overlay as quarter

class QuarterTextureTests(unittest.TestCase):
 def test_classification_protects_data_and_small_images(self):
  entry={'input':{'gpu':[1000,760],'data_format':2,'image_format':4,'mipmaps':0}}
  spec={'source':'res://images/packed/card_portraits/a.png','direct_fields':[],'retained_reasons':[],'role':'card_portrait'}
  self.assertEqual(quarter.classify(spec,entry),'card_portrait')
  for reason in quarter.PROTECTED:
   self.assertIsNone(quarter.classify(dict(spec,retained_reasons=[reason]),entry))
  self.assertIsNone(quarter.classify(spec,{'input':dict(entry['input'],gpu=[300,300])}))
  self.assertIsNone(quarter.classify(spec,{'input':dict(entry['input'],mipmaps=1)}))
  self.assertIsNone(quarter.classify(dict(spec,role=None),entry))
  self.assertIsNone(quarter.classify(dict(spec,source='res://images/atlases/card_atlas_0.png',direct_fields=['atlas','shader_parameter/mask_texture'],role=None,retained_reasons=['referenced as a shader parameter']),entry))
 def test_quality_rejects_forged_status(self):
  info={'gpu':[264,152]};q={'status':'accepted','limits':quarter.LIMITS,'sample_step':1,'sample_count':66*38,'visible_samples':66*38,'alpha_p99':0.0,'alpha_max':0.0,'visible_rgb_p99':0.0}
  quarter.validate_quality(q,info)
  for bad in (dict(q,alpha_max=float('nan')),dict(q,alpha_p99=.09,alpha_max=.1),dict(q,visible_rgb_p99=.19),dict(q,sample_count=2),dict(q,status='quality_rejected')):
   with self.assertRaises(ValueError):quarter.validate_quality(bad,info)
 def test_wrong_source_does_not_create_output(self):
  with tempfile.TemporaryDirectory() as t:
   p=Path(t)
   for name in ('source','base','report-in'): (p/name).write_bytes(b'not an audited pack')
   cmd=[sys.executable,str(TOOLS/'quarter_texture_overlay.py'),'--source-pck',str(p/'source'),'--base-main',str(p/'base'),'--texture-report',str(p/'report-in'),'--godot','/not-invoked','--cache',str(p/'cache'),'--output',str(p/'delta'),'--report',str(p/'report')]
   run=subprocess.run(cmd,capture_output=True,text=True,timeout=10)
   self.assertNotEqual(run.returncode,0);self.assertIn('input identity mismatch',run.stderr)
   self.assertFalse((p/'delta').exists());self.assertFalse((p/'cache').exists())
 def test_worker_alpha_and_logical_atlas(self):
  godot=external_file(self,'STS2_TEST_GODOT')
  with tempfile.TemporaryDirectory() as t:
   p=Path(t);(p/'project.godot').write_text('[application]\nconfig/name="Quarter fixture"\n')
   shutil.copy(ROOT/'tests/sts2_low_texture_fixture.gd',p/'generate.gd');shutil.copy(ROOT/'tests/sts2_quarter_texture_fixture.gd',p/'verify.gd')
   def run(script,*args):
    z=subprocess.run([str(godot),'--headless','--path',str(p),'--script',script,'--',*map(str,args)],capture_output=True,text=True,timeout=120)
    self.assertEqual(z.returncode,0,z.stdout+z.stderr);return z.stdout
   run('res://generate.gd','generate',p)
   job=p/'jobs.json';job.write_text(json.dumps([{'input':str(p/'webp.ctex'),'output':str(p/'quarter.ctex')}]))
   log=run(str(quarter.WORKER),job); self.assertIn('"status":"accepted"',log)
   src=low.parse_texture((p/'webp.ctex').read_bytes());out=quarter.verify_output((p/'quarter.ctex').read_bytes(),src)
   self.assertEqual(out['gpu'],[66,38]);self.assertIn('QUARTER_FIXTURE_OK',run('res://verify.gd'))
   with self.assertRaises(ValueError):quarter.verify_output((p/'quarter.ctex').read_bytes(),dict(src,logical=[1,1]))
   run('res://verify.gd','generate-edge',p/'edge.ctex')
   job.write_text(json.dumps([{'input':str(p/'edge.ctex'),'output':str(p/'edge-out.ctex')}]))
   log=run(str(quarter.WORKER),job);self.assertIn('"status":"accepted"',log)
   self.assertIn('QUARTER_EDGE_OK',run('res://verify.gd','check-edge'))
   run('res://verify.gd','generate-bc',p/'bc.ctex')
   job.write_text(json.dumps([{'input':str(p/'bc.ctex'),'output':str(p/'bc-out.ctex')}]))
   log=run(str(quarter.WORKER),job);self.assertIn('"status":"accepted"',log)
   bc=low.texture_header((p/'bc.ctex').read_bytes());quarter.verify_output((p/'bc-out.ctex').read_bytes(),bc)

if __name__=='__main__':unittest.main()
