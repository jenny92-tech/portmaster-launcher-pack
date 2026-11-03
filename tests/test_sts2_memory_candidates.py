# INPUT: synthetic PCK resources and texture conversion metadata
# OUTPUT: bounded static texture closure and identity validation
# POS: does not execute game assets or inspect a live process
import json
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1] / 'ports/sts2/src/tools/godot_pck'
sys.path.insert(0, str(TOOLS))
import low_texture_overlay as low
import scan_memory_candidates as scanner

class MemoryCandidateTests(unittest.TestCase):
    def test_texture_estimates_use_physical_size_and_block_padding(self):
        info = {'gpu':[17,9], 'data_format':0, 'image_format':37, 'mipmaps':0}
        self.assertEqual(scanner.texture_estimate(info)['nominal_min_bytes'], 3*2*16)
        info.update(data_format=2, image_format=4, mipmaps=1)
        result=scanner.texture_estimate(info)
        self.assertEqual((result['nominal_min_bytes'],result['nominal_max_bytes']),((17*9+8*4)*3,(17*9+8*4)*4))
        info['image_format']=99
        self.assertIsNone(scanner.texture_estimate(info))

    def test_closure_deduplicates_and_reports_missing_and_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); source=root/'fixture.pck';entries=[]
            for i,(path,data) in enumerate({
                'scenes/scene.tscn':b'[gd_scene]\n[ext_resource path="res://data/shared.tres"]\n[ext_resource path="res://images/a.png"]\n',
                'data/shared.tres':b'[gd_resource]\n[ext_resource path="res://images/a.png"]\n[ext_resource path="res://missing.tres"]\n[ext_resource path="res://images/a.atlas"]\n',
                'images/a.atlas.import':b'[remap]\npath="res://.godot/imported/a.spatlas"\n',
                '.godot/imported/a.spatlas':json.dumps({'source_path':'res://images/a.atlas','atlas_data':'a.png\nsize: 64,64\nfilter: Linear,Linear\n'}).encode(),
                '.godot/imported/a.ctex':b'opaque'}.items()):
                p=root/str(i);p.write_bytes(data);entries.append((path,p))
            low.write_pack(sorted(entries),source)
            info={'logical':[64,64],'gpu':[32,32],'data_format':0,'image_format':37,'mipmaps':0}
            report={'source_sha256':low.file_hash(source),'output_sha256':'1'*64,'resources':[{'kind':'texture','source_path':'images/a.png','path':'.godot/imported/a.ctex','input':info,'output':info}]}
            result=scanner.scan(source,report,['res://scenes/scene.tscn'])
            self.assertEqual(result['texture_count'],1)
            self.assertEqual(result['texture_bytes_nominal_min'],256)
            self.assertEqual(result['missing_or_non_pck_paths'],['res://missing.tres'])
            with self.assertRaises(ValueError): scanner.scan(source,dict(report,source_sha256='0'*64),[])
            with self.assertRaises(ValueError): scanner.scan(source,report,['res://../escape'])
            with self.assertRaises(ValueError): scanner.scan(source,dict(report,resources=report['resources']*2),[])

if __name__=='__main__': unittest.main()
