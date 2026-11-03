# INPUT: synthetic original/base PCK, audited font delta and evidence
# OUTPUT: source/import/output binding and fail-closed main merge
# POS: offline fixture; never reads player files or a device
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
TOOLS=ROOT/'ports/sts2/src/tools/godot_pck';sys.path.insert(0,str(TOOLS))
import low_texture_overlay as low
import merge_texture_pck as merge
import merge_font_cache as font
sys.path.insert(0,str(ROOT/'ports/sts2/src/tools/device_tools'))
import merge_v110_delta as device

def sha(b):return hashlib.sha256(b).hexdigest()

class FontMainTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name).resolve()
        self.name='.godot/imported/example.fontdata';self.imp='fonts/zhs/example.otf.import'
        self.source=self.pack('source',{self.name:b'original',self.imp:b'import', 'opaque':b'unchanged'})
        self.base=self.pack('base',{self.name:b'original',self.imp:b'import', 'opaque':b'unchanged'})
        self.delta=self.pack('delta',{self.name:b'cleared'});self.godot=self.root/'godot';self.godot.write_bytes(b'fixture-engine')
        self.allow={self.name:sha(b'original')}
        self.record={'target':self.name,'import_path':self.imp,'import_sha256':sha(b'import'),
          'source_sha256':sha(b'original'),'source_md5':hashlib.md5(b'original').hexdigest(),
          'base_sha256':sha(b'original'),'output_sha256':sha(b'cleared'),'output_md5':hashlib.md5(b'cleared').hexdigest(),
          'font_data_sha256':'a'*64,'validation':{'status':'verified','font_data_sha256':'a'*64,
             'glyph_image':{'exact_pixels':True},'before_sizes':[[{'pages':65}]],'after_sizes':[[{'pages':0}]]}}
        self.report=self.root/'report.json';self.write_report()

    def pack(self,name,items):
        entries=[]
        for i,(key,data) in enumerate(items.items()):
            p=self.root/(name+str(i));p.write_bytes(data);entries.append((key,p))
        result=self.root/(name+'.pck');low.write_pack(entries,result);return result

    def write_report(self):
        self.report.write_text(json.dumps({'source_sha256':low.file_hash(self.source),'base_main_sha256':low.file_hash(self.base),
          'delta_sha256':low.file_hash(self.delta),'godot_sha256':low.file_hash(self.godot),
          'builder_sha256':low.file_hash(TOOLS/'strip_font_cache.py'),'worker_sha256':low.file_hash(TOOLS/'strip_font_cache.gd'),
          'resources':[self.record]}))

    def run_merge(self,name):
        with patch.object(font,'SOURCE',low.file_hash(self.source)),patch.object(font,'BASE',low.file_hash(self.base)), \
             patch.object(font,'DELTA',low.file_hash(self.delta)),patch.object(font,'REPORT',low.file_hash(self.report)), \
             patch.object(merge,'AUDITED_FONT_SOURCE_SHA256',self.allow):
            return font.prepare(self.source,self.base,self.delta,self.report,self.godot,self.root/name)

    def test_exact_report_and_import_are_bound(self):
        result=self.run_merge('result');entries=low.read_pack(result)
        with result.open('rb') as f:
            self.assertEqual(low.entry_bytes(f,entries[self.name]),b'cleared')
            self.assertEqual(low.entry_bytes(f,entries[self.imp]),b'import')
            self.assertEqual(low.entry_bytes(f,entries['opaque']),b'unchanged')

    def test_forged_validation_or_import_is_rejected(self):
        for field in ('import_sha256','font_data_sha256'):
            old=self.record[field];self.record[field]='0'*64;self.write_report()
            with self.subTest(field=field),self.assertRaises(ValueError):self.run_merge('bad-'+field)
            self.record[field]=old

    def test_device_font_mode_requires_audited_main_and_entries(self):
        desired=self.run_merge('device-reference');wanted=low.file_hash(desired)
        root=self.root/'device';(root/'builds').mkdir(parents=True)
        def bundle(value):
            raw=(json.dumps(value,sort_keys=True)+'\n').encode();ident=sha(raw);d=root/'builds'/ident;d.mkdir();(d/'manifest.json').write_bytes(raw);return ident,d
        oldid,old=bundle({'source_pck_sha256':'a'*64,'main_sha256':low.file_hash(self.base)})
        newid,new=bundle({'source_pck_sha256':'a'*64,'main_sha256':wanted})
        (old/'main.pck').write_bytes(self.base.read_bytes());s=(old/'main.pck').stat()
        (old/'main.stat.json').write_text(json.dumps({'build_sha256':oldid,'main_sha256':low.file_hash(self.base),'size':s.st_size,'mtime_ns':s.st_mtime_ns}))
        (new/'restore-delta.pck').write_bytes(self.delta.read_bytes())
        adapter={'source_sha256':low.file_hash(self.base),'output_sha256':low.file_hash(self.delta),'resources':[
          {'path':self.name,'kind':'audited_font','source_sha256':sha(b'original'),'output_sha256':sha(b'cleared'),'output_md5':hashlib.md5(b'cleared').hexdigest()}]}
        (new/'restore-adapter.json').write_text(json.dumps(adapter));(root/'active-build').write_text(oldid+'\n')
        args=(str(root),oldid,newid,low.file_hash(self.base),low.file_hash(self.delta),wanted,'font')
        with self.assertRaisesRegex(ValueError,'audited identities'):device.prepare(*args)
        with patch.object(device,'FONT_BASE_SHA',low.file_hash(self.base)),patch.object(device,'FONT_DELTA_SHA',low.file_hash(self.delta)), \
             patch.object(device,'FONT_MAIN_SHA',wanted),patch.object(merge,'AUDITED_FONT_SOURCE_SHA256',self.allow):
            self.assertEqual(device.prepare(*args),wanted)
        self.assertEqual(low.file_hash(new/'main.pck'),wanted)
        self.assertEqual((root/'active-build').read_text().strip(),oldid)

if __name__=='__main__':unittest.main()
