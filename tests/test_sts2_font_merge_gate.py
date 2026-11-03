# INPUT: synthetic Godot PCK and a hypothetical audited font replacement
# OUTPUT: default-deny font paths and exact per-entry hash gate regressions
# POS: offline temporary fixtures; no game, player assets or device
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'ports/sts2/src/tools/godot_pck'))
import low_texture_overlay as low
import merge_texture_pck as merge

class FontMergeGateTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.name='.godot/imported/audited.fontdata'
        self.source=self.pack('source',{self.name:b'font-source','opaque':b'untouched'})
        self.delta=self.pack('delta',{self.name:b'font-output'})
        self.allowed={self.name:hashlib.sha256(b'font-source').hexdigest()}
        self.record={'path':self.name,'kind':'audited_font','source_sha256':self.allowed[self.name],
                     'output_sha256':hashlib.sha256(b'font-output').hexdigest(),'output_md5':hashlib.md5(b'font-output').hexdigest()}
        self.report=self.root/'report.json';self.write_report()

    def pack(self,name,items):
        pairs=[]
        for i,(key,value) in enumerate(items.items()):
            p=self.root/(name+str(i));p.write_bytes(value);pairs.append((key,p))
        p=self.root/(name+'.pck');low.write_pack(pairs,p);return p

    def write_report(self):
        self.report.write_text(json.dumps({'source_sha256':low.file_hash(self.source),'output_sha256':low.file_hash(self.delta),'resources':[self.record]}))

    def test_only_explicit_exact_audit_can_replace_font(self):
        with patch.object(merge,'AUDITED_FONT_SOURCE_SHA256',self.allowed):
            with self.assertRaises(ValueError):merge.prepare(self.source,self.delta,self.report,self.root/'denied')
            with self.assertRaises(ValueError):merge.prepare(self.source,self.delta,self.report,self.root/'wrong',approved_font_hashes={self.name:'0'*64})
            result=merge.prepare(self.source,self.delta,self.report,self.root/'valid',approved_font_hashes=self.allowed)
            entries=low.read_pack(result)
            with result.open('rb') as stream:
                self.assertEqual(low.entry_bytes(stream,entries[self.name]),b'font-output')
                self.assertEqual(low.entry_bytes(stream,entries['opaque']),b'untouched')

    def test_forged_per_entry_digest_fails_without_touching_inputs(self):
        original=self.source.read_bytes();replacement=self.delta.read_bytes()
        with patch.object(merge,'AUDITED_FONT_SOURCE_SHA256',self.allowed):
            for field in ('source_sha256','output_sha256'):
                old=self.record[field];self.record[field]='0'*64;self.write_report()
                with self.assertRaises(ValueError):merge.prepare(self.source,self.delta,self.report,self.root/field,approved_font_hashes=self.allowed)
                self.record[field]=old
        self.assertEqual(self.source.read_bytes(),original);self.assertEqual(self.delta.read_bytes(),replacement)

if __name__=='__main__':unittest.main()
