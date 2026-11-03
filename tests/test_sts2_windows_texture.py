# INPUT: synthetic import/overlay and compatibility PCK fixtures
# OUTPUT: narrow Windows texture mapping and pre-start merge validation
# POS: host-only integrity checks; no device or commercial resources
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT/'ports/sts2/src/tools/godot_pck'
sys.path.insert(0, str(TOOLS))
import low_texture_overlay as low
import windows_texture_overlay as windows


class WindowsTextureTests(unittest.TestCase):
    def test_import_source_identity_and_collisions(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);source='images/test.png'; digest=hashlib.md5(('res://'+source).encode()).hexdigest()
            target=f'.godot/imported/test.png-{digest}.bptc.ctex'
            def make(data,extra=None):
                items=[]
                for i,(name,value) in enumerate({source+'.import':data,target:b'fake',**(extra or {})}.items()):
                    path=root/('item'+str(i));path.write_bytes(value);items.append((name,path))
                pack=root/'source.pck';low.write_pack(items,pack);return pack
            raw=f'[remap]\npath.bptc="res://{target}"\n'.encode();pack=make(raw)
            with pack.open('rb') as stream:
                mapping,_,_,_=windows.windows_import_map(stream,low.read_pack(pack))
            self.assertEqual(mapping[target][0],source)
            for invalid in (raw.replace(digest.encode(),b'0'*32),raw+b'source_file="res://other.png"\n'):
                pack=make(invalid)
                with pack.open('rb') as stream:
                    with self.assertRaises(ValueError):windows.windows_import_map(stream,low.read_pack(pack))
            pack=make(raw,{'images/other.png.import':raw})
            with pack.open('rb') as stream:
                with self.assertRaises(ValueError):windows.windows_import_map(stream,low.read_pack(pack))

    def test_import_rewrite_preserves_other_fields(self):
        target = '.godot/imported/test-0123456789abcdef0123456789abcdef.bptc.ctex'
        raw = (f'[remap]\npath.bptc="res://{target}"\nmetadata={{\n"imported_formats": ["s3tc_bptc", "etc2_astc"],\n"vram_texture": true\n}}\n').encode()
        changed = windows.rewrite_import(raw, 'bptc', target)
        self.assertIn(f'path.astc="res://{target}"'.encode(), changed)
        self.assertIn(b'"imported_formats": ["etc2_astc"]', changed)
        self.assertIn(b'"vram_texture": true', changed)
        for invalid in (raw.replace(b'path.bptc', b'path.s3tc'), raw + b'path.astc="x"\n', raw.replace(b'"etc2_astc"', b'"unknown"')):
            with self.assertRaises(ValueError): windows.rewrite_import(invalid, 'bptc', target)

    def test_texture_import_and_early_compat_are_bound_to_source(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); source=root/'source.pck'; overlay=root/'overlay.pck'; compat=root/'compat.pck'
            target='.godot/imported/a-0123456789abcdef0123456789abcdef.s3tc.ctex'; imp='a.png.import'
            old=(f'[remap]\npath.s3tc="res://{target}"\nmetadata={{\n"imported_formats": ["s3tc_bptc", "etc2_astc"]\n}}\n').encode()
            new=windows.rewrite_import(old,'s3tc',target)
            def pack(path, data):
                items=[]
                for i,(name,blob) in enumerate(data.items()):
                    p=root/(path.stem+str(i));p.write_bytes(blob);items.append((name,p))
                low.write_pack(sorted(items),path)
            pack(source,{target:b'old BC',imp:old,'scene.tscn':b'old scene','opaque':b'untouched'})
            pack(overlay,{target:b'new ASTC',imp:new})
            pack(compat,{'scene.tscn':b'new scene','port_compat/a.gd':b'new script'})
            sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
            md5=lambda b:hashlib.md5(b).hexdigest()
            report=root/'report.json';report.write_text(json.dumps({'source_sha256':sha(source),'output_sha256':sha(overlay),'resources':[{'path':target,'kind':'texture','output_md5':md5(b'new ASTC')},{'path':imp,'kind':'import','source_md5':md5(old),'output_md5':md5(new)}]}))
            cr=root/'compat.json';cr.write_text(json.dumps({'source_pck_sha256':sha(source),'overlay_sha256':sha(compat),'resources':['res://scene.tscn','res://port_compat/a.gd']}))
            command=[sys.executable,str(TOOLS/'merge_texture_pck.py'),'--source',str(source),'--overlay',str(overlay),'--report',str(report),'--compat',str(compat),'--compat-report',str(cr),'--output-dir',str(root/'out')]
            run=subprocess.run(command,capture_output=True,text=True);self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            merged=next((root/'out').glob('*.pck')); index=low.read_pack(merged)
            with merged.open('rb') as stream:
                for name,expected in ((target,b'new ASTC'),(imp,new),('scene.tscn',b'new scene'),('opaque',b'untouched'),('port_compat/a.gd',b'new script')):
                    self.assertEqual(low.entry_bytes(stream,index[name]),expected)
            bad=json.loads(cr.read_text());bad['source_pck_sha256']='0'*64;cr.write_text(json.dumps(bad))
            run=subprocess.run(command[:-1]+[str(root/'bad')],capture_output=True,text=True)
            self.assertNotEqual(run.returncode,0)
            self.assertFalse((root/'bad').exists())


if __name__=='__main__': unittest.main()
