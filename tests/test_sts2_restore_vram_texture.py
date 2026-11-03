# INPUT: synthetic imports, pixel data and official Godot CPU codecs
# OUTPUT: restore role protection, ASTC quality gate, and atlas invariants
# POS: offline fake resources only; no player content or GPU performance claim
import json
import hashlib
from unittest.mock import patch
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
TOOLS=ROOT/'ports/sts2/src/tools/godot_pck'
sys.path.insert(0,str(TOOLS))
import low_texture_overlay as low
import restore_vram_texture_inventory as inventory
import restore_vram_texture as restore
DEFAULT=ROOT/'.cache/sts2-vulkan-trial/build-tools/godot-4.5.1-macos/Godot.app/Contents/MacOS/Godot'

class RestoreVramTests(unittest.TestCase):
    def test_material_dependency_classification_and_sensitive_names(self):
        with tempfile.TemporaryDirectory() as t:
            p=Path(t);scene=p/'scene'
            scene.write_bytes(b'[gd_scene format=3]\n[ext_resource type="Texture2D" path="res://visual.png" id="1"]\n[ext_resource type="Texture2D" path="res://data.png" id="2"]\n[node name="n" type="Sprite2D"]\ntexture = ExtResource("1")\nshader_parameter/noise = ExtResource("2")\n')
            pack=p/'test.pck';low.write_pack([('scene.tscn',scene)],pack)
            with pack.open('rb') as stream:
                result=inventory.usage_metadata(stream,low.read_pack(pack),{'visual.png','data.png','unknown.png'})
            self.assertEqual(result['visual.png'],{'texture'})
            self.assertEqual(result['data.png'],{'shader_parameter/noise'})
            self.assertEqual(result['unknown.png'],set())
            for s in ('assets/noise.png','normal_map.png','asset_mask.png','glyph.png','lut.png'):
                self.assertTrue(inventory.SENSITIVE.search(s))

    def test_quality_cache_rejects_forged_decisions(self):
        info={'gpu':[8,8]}
        q={'status':'accepted','sample_step':1,'sample_count':64,'visible_samples':64,
           'alpha_p99':0.01,'alpha_max':0.02,'visible_rgb_p99':0.01,
           'limits':{'alpha_p99':0.04,'alpha_max':0.25,'visible_rgb_p99':0.04},'output_sha256':'a'*64}
        restore.validate_quality(q,info)
        for changed in (dict(q,alpha_p99=0.05,alpha_max=0.1), dict(q,alpha_max=float('nan')),
                        dict(q,visible_rgb_p99=0.2),dict(q,sample_count=63),dict(q,status='quality_rejected')):
            with self.assertRaises(ValueError):restore.validate_quality(changed,info)

    def test_astc_codec_preserves_logical_size_alpha_and_atlas(self):
        godot=Path(os.environ.get('STS2_TEST_GODOT',str(DEFAULT)))
        if not godot.is_file():self.skipTest('Godot 4.5.1 unavailable')
        with tempfile.TemporaryDirectory() as t:
            p=Path(t);(p/'project.godot').write_text('[application]\nconfig/name="Texture restore fixture"\n')
            shutil.copy(ROOT/'tests/sts2_low_texture_fixture.gd',p/'generate.gd')
            shutil.copy(ROOT/'tests/sts2_restore_vram_fixture.gd',p/'verify.gd')
            def run(script,*args):
                r=subprocess.run([str(godot),'--headless','--path',str(p),'--script',script,'--',*map(str,args)],capture_output=True,text=True,timeout=30)
                self.assertEqual(r.returncode,0,r.stdout+r.stderr)
                return r.stdout+r.stderr
            run('res://generate.gd','generate',p)
            inp=p/'webp.ctex';out=p/'restored.ctex';jobs=p/'jobs.json';jobs.write_text(json.dumps([{'input':str(inp),'output':str(out)}]))
            log=run(str(TOOLS/'restore_vram_texture_worker.gd'),jobs)
            self.assertIn('"status":"accepted"',log)
            original=low.parse_texture(inp.read_bytes());converted=restore.verify_output(out.read_bytes(),original)
            self.assertEqual(converted['gpu'],original['gpu'])
            self.assertEqual(converted['logical'],original['logical'])
            self.assertIn('RESTORED_TEXTURE_FIXTURE_OK',run('res://verify.gd'))
            random_input=p/'random.ctex';random_out=p/'random-restored.ctex'
            self.assertIn('ADVERSARIAL_WEBP_FIXTURE_OK',run('res://verify.gd','generate-random',random_input))
            jobs.write_text(json.dumps([{'input':str(random_input),'output':str(random_out)}]))
            log=run(str(TOOLS/'restore_vram_texture_worker.gd'),jobs)
            self.assertIn('"status":"quality_rejected"',log)
            self.assertFalse(random_out.exists())
            with self.assertRaises(ValueError):restore.verify_output(out.read_bytes(),dict(original,logical=[1,1]))

    def test_source_bound_delta_matches_report(self):
        godot=Path(os.environ.get('STS2_TEST_GODOT',str(DEFAULT)))
        if not godot.is_file():self.skipTest('Godot 4.5.1 unavailable')
        with tempfile.TemporaryDirectory() as t:
            p=Path(t);(p/'project.godot').write_text('[application]\nconfig/name="Delta fixture"\n')
            shutil.copy(ROOT/'tests/sts2_low_texture_fixture.gd',p/'generate.gd')
            r=subprocess.run([str(godot),'--headless','--path',str(p),'--script','res://generate.gd','--','generate',str(p)],capture_output=True,text=True,timeout=20)
            self.assertEqual(r.returncode,0,r.stdout+r.stderr)
            content=(p/'webp.ctex').read_bytes();target='.godot/imported/example.ctex'
            source=p/'source.pck';base=p/'base.pck';low.write_pack([(target,p/'webp.ctex')],source);low.write_pack([(target,p/'webp.ctex')],base)
            source_sha=low.file_hash(source);base_sha=low.file_hash(base);sha=hashlib.sha256(content).hexdigest();md5=hashlib.md5(content).hexdigest()
            item={'source':'res://example.png','target':'res://'+target,'source_sha256':sha,'source_md5':md5,'old_sibling_sha256':sha,'installed_md5':md5,'input':low.parse_texture(content),'eligible':True,'retained_reasons':[]}
            specs=p/'specs.json';specs.write_text(json.dumps({'old_pck_sha256':'a'*64,'source_pck_sha256':source_sha,'texture_overlay_sha256':base_sha,'resources':[item]}))
            base_report=p/'base.json';base_report.write_text(json.dumps({'source_sha256':source_sha,'output_sha256':base_sha}))
            delta=p/'delta.pck';report=p/'report.json';cache=p/'cache'
            args=['restore','--source-pck',str(source),'--base-texture',str(base),'--texture-report',str(base_report),'--godot',str(godot),'--cache',str(cache),'--output',str(delta),'--report',str(report)]
            with patch.object(restore,'SPECS',specs), patch.object(sys,'argv',args):restore.main()
            result=json.loads(report.read_text());self.assertEqual(result['accepted_count'],1)
            self.assertEqual(result['delta_sha256'],low.file_hash(delta))
            self.assertEqual(result['specs_sha256'],low.file_hash(specs))
            self.assertEqual(result['texture_report_sha256'],low.file_hash(base_report))
            self.assertEqual(result['resources'][0]['base_entry_sha256'],sha)
            index=low.read_pack(delta)
            with delta.open('rb') as stream:data=low.entry_bytes(stream,index[target])
            self.assertEqual(hashlib.sha256(data).hexdigest(),result['resources'][0]['output_sha256'])
            self.assertEqual(low.file_hash(source),source_sha)
            base_report.write_text(json.dumps({'source_sha256':'0'*64,'output_sha256':base_sha}))
            args[-3:]=[str(p/'bad.pck'),'--report',str(p/'bad.json')]
            with patch.object(restore,'SPECS',specs), patch.object(sys,'argv',args), self.assertRaisesRegex(ValueError,'identity'):
                restore.main()
            self.assertFalse((p/'bad.pck').exists())

if __name__=='__main__':unittest.main()
