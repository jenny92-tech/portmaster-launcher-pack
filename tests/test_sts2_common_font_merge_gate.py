# INPUT: synthetic common-font delta with an exact per-entry audit
# OUTPUT: separate default-deny and mixed-set rejection checks
# POS: isolated fixture for the common-font merge gate
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

class CommonFontGateTests(unittest.TestCase):
    def test_exact_common_only_and_original_unchanged(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); name='.godot/imported/common.fontdata'
            def pack(path, entries):
                files=[]
                for i,(n,data) in enumerate(entries.items()):
                    p=root/(path+str(i));p.write_bytes(data);files.append((n,p))
                dest=root/(path+'.pck');low.write_pack(files,dest);return dest
            source=pack('source',{name:b'old','opaque':b'unchanged'});delta=pack('delta',{name:b'new'})
            allowed={name:hashlib.sha256(b'old').hexdigest()}
            r={'source_sha256':low.file_hash(source),'output_sha256':low.file_hash(delta),'resources':[{'path':name,'kind':'audited_font','source_sha256':allowed[name],'output_sha256':hashlib.sha256(b'new').hexdigest(),'output_md5':hashlib.md5(b'new').hexdigest()}]}
            report=root/'report.json';report.write_text(json.dumps(r)); original=source.read_bytes()
            with patch.object(merge,'AUDITED_COMMON_FONT_SOURCE_SHA256',allowed):
                with self.assertRaises(ValueError):merge.prepare(source,delta,report,root/'default')
                with self.assertRaises(ValueError):merge.prepare(source,delta,report,root/'combined',approved_font_hashes={**allowed,**merge.AUDITED_FONT_SOURCE_SHA256})
                result=merge.prepare(source,delta,report,root/'approved',approved_font_hashes=allowed)
                entries=low.read_pack(result)
                with result.open('rb') as f:
                    self.assertEqual(low.entry_bytes(f,entries[name]),b'new')
                    self.assertEqual(low.entry_bytes(f,entries['opaque']),b'unchanged')
            self.assertEqual(source.read_bytes(),original)

if __name__=='__main__':unittest.main()
