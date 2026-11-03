# INPUT: synthetic immutable build manifests and texture-only delta PCK
# OUTPUT: local merge, source/selector guards and interruption rejection
# POS: offline temporary directories; no device connection or game start
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'ports/sts2/src/tools/godot_pck'),str(ROOT/'ports/sts2/src/tools/device_tools')]
import low_texture_overlay as low
import merge_texture_pck as merge
import merge_v110_delta as device


class DeltaInstallTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve();self.builds=self.root/'builds';self.builds.mkdir()
        self.name='.godot/imported/test.ctex';self.source=self.pack('source',{self.name:b'old','opaque':b'unchanged'})
        self.delta=self.pack('delta',{self.name:b'new'});self.oldsha=low.file_hash(self.source);self.deltasha=low.file_hash(self.delta)
        self.adapter={'source_sha256':self.oldsha,'output_sha256':self.deltasha,
                      'resources':[{'path':self.name,'output_md5':hashlib.md5(b'new').hexdigest()}]}
        adapter=self.root/'adapter.json';adapter.write_text(json.dumps(self.adapter))
        self.wanted=merge.prepare(self.source,self.delta,adapter,self.root/'reference').stem
        self.oldid=self.make_manifest({'main_sha256':self.oldsha,'source_pck_sha256':'a'*64})
        self.newid=self.make_manifest({'main_sha256':self.wanted,'source_pck_sha256':'a'*64,'runtime_binding':{},'baseline_files':{},'extension_files':{}})
        self.old=self.builds/self.oldid;self.new=self.builds/self.newid
        (self.old/'main.pck').write_bytes(self.source.read_bytes())
        st=(self.old/'main.pck').stat()
        (self.old/'main.stat.json').write_text(json.dumps({'build_sha256':self.oldid,'main_sha256':self.oldsha,'size':st.st_size,'mtime_ns':st.st_mtime_ns}))
        (self.new/'restore-delta.pck').write_bytes(self.delta.read_bytes())
        (self.new/'restore-adapter.json').write_text(json.dumps(self.adapter))
        (self.root/'active-build').write_text(self.oldid+'\n')

    def pack(self, name, items):
        files=[]
        for i,(key,value) in enumerate(items.items()):
            p=self.root/(name+str(i));p.write_bytes(value);files.append((key,p))
        p=self.root/(name+'.pck');low.write_pack(files,p);return p

    def make_manifest(self, value):
        raw=(json.dumps(value,sort_keys=True)+'\n').encode();identity=hashlib.sha256(raw).hexdigest()
        d=self.builds/identity;d.mkdir();(d/'manifest.json').write_bytes(raw);return identity

    def run_merge(self):
        return device.prepare(str(self.root),self.oldid,self.newid,self.oldsha,self.deltasha,self.wanted)

    def test_merge_and_idempotent_recovery(self):
        self.assertEqual(self.run_merge(),self.wanted)
        self.assertEqual(low.file_hash(self.new/'main.pck'),self.wanted)
        self.assertEqual(low.file_hash(self.old/'main.pck'),self.oldsha)
        self.assertEqual(self.run_merge(),self.wanted)
        self.assertEqual((self.root/'active-build').read_text().strip(),self.oldid)

    def test_foreign_and_incomplete_inputs_fail_closed(self):
        (self.new/'main.pck').write_bytes(b'foreign')
        with self.assertRaises(ValueError):self.run_merge()
        (self.new/'main.pck').unlink()
        (self.new/'restore-output').mkdir()
        (self.new/'restore-output'/'.texture-merge-interrupted.incoming').write_bytes(b'partial')
        with self.assertRaisesRegex(ValueError,'inspection'):self.run_merge()
        self.assertEqual(low.file_hash(self.old/'main.pck'),self.oldsha)

    def test_delta_symlink_rejected(self):
        (self.new/'restore-delta.pck').unlink();os.symlink(self.delta,self.new/'restore-delta.pck')
        with self.assertRaises(ValueError):self.run_merge()
        self.assertFalse((self.new/'main.pck').exists())

    def test_staged_main_symlink_rejected(self):
        stage=self.new/'restore-output';stage.mkdir()
        os.symlink(self.root/'reference'/(self.wanted+'.pck'),stage/(self.wanted+'.pck'))
        (stage/(self.wanted+'.json')).write_text('{}')
        with self.assertRaisesRegex(ValueError,'unsafe staged'):self.run_merge()
        self.assertFalse((self.new/'main.pck').exists())

    def test_quarter_mode_requires_fixed_identities_and_texture_set(self):
        args=(str(self.root),self.oldid,self.newid,self.oldsha,self.deltasha,self.wanted,'quarter')
        with self.assertRaisesRegex(ValueError,'audited identities'):device.prepare(*args)
        with patch.object(device,'COMMON_MAIN_SHA',self.oldsha),patch.object(device,'QUARTER_DELTA_SHA',self.deltasha), \
             patch.object(device,'QUARTER_MAIN_SHA',self.wanted),patch.object(device,'QUARTER_COUNT',1):
            self.assertEqual(device.prepare(*args),self.wanted)
        self.assertEqual(low.file_hash(self.new/'main.pck'),self.wanted)
        self.assertEqual(low.file_hash(self.old/'main.pck'),self.oldsha)
        self.assertEqual((self.root/'active-build').read_text().strip(),self.oldid)

    def test_quarter_mode_rejects_duplicate_or_non_texture_paths(self):
        args=(str(self.root),self.oldid,self.newid,self.oldsha,self.deltasha,self.wanted,'quarter')
        with patch.object(device,'COMMON_MAIN_SHA',self.oldsha),patch.object(device,'QUARTER_DELTA_SHA',self.deltasha), \
             patch.object(device,'QUARTER_MAIN_SHA',self.wanted),patch.object(device,'QUARTER_COUNT',2):
            self.adapter['resources']*=2
            (self.new/'restore-adapter.json').write_text(json.dumps(self.adapter))
            with self.assertRaisesRegex(ValueError,'audited texture set'):device.prepare(*args)
        self.assertFalse((self.new/'main.pck').exists())

    def test_refinement_mode_enforces_pinned_lineage_and_closed_set(self):
        args=(str(self.root),self.oldid,self.newid,self.oldsha,self.deltasha,self.wanted,'refinement')
        with self.assertRaisesRegex(ValueError,'audited identities'):device.prepare(*args)
        with patch.object(device,'QUARTER_MAIN_SHA',self.oldsha),patch.object(device,'REFINEMENT_DELTA_SHA',self.deltasha), \
             patch.object(device,'REFINEMENT_MAIN_SHA',self.wanted),patch.object(device,'REFINEMENT_COUNT',1):
            self.assertEqual(device.prepare(*args),self.wanted)
        self.assertEqual(low.file_hash(self.new/'main.pck'),self.wanted)
        self.assertEqual(low.file_hash(self.old/'main.pck'),self.oldsha)

    def test_refinement_rejects_non_texture_and_duplicates(self):
        args=(str(self.root),self.oldid,self.newid,self.oldsha,self.deltasha,self.wanted,'refinement')
        with patch.object(device,'QUARTER_MAIN_SHA',self.oldsha),patch.object(device,'REFINEMENT_DELTA_SHA',self.deltasha), \
             patch.object(device,'REFINEMENT_MAIN_SHA',self.wanted),patch.object(device,'REFINEMENT_COUNT',2):
            self.adapter['resources']*=2
            (self.new/'restore-adapter.json').write_text(json.dumps(self.adapter))
            with self.assertRaisesRegex(ValueError,'audited texture set'):device.prepare(*args)
        self.assertFalse((self.new/'main.pck').exists())

    def test_cleanup_checks_open_files_and_only_removes_intermediates(self):
        self.run_merge();main=self.new/'main.pck';st=main.stat()
        (self.new/'main.stat.json').write_text(json.dumps({'build_sha256':self.newid,'main_sha256':self.wanted,'size':st.st_size,'mtime_ns':st.st_mtime_ns}))
        (self.root/'active-build').write_text(self.newid+'\n')
        for name in ('entry.sh','release_info.json'):(self.new/name).write_text(name)
        for name in ('data','patch'):(self.new/name).mkdir()
        original=self.root/'original';(original/'gamedata/pcks').mkdir(parents=True)
        (original/'gamedata/pcks/SlayTheSpire2.pck').write_bytes(b'original')
        proc=self.root/'proc';(proc/'123/fd').mkdir(parents=True);(proc/'123/maps').write_text('')
        os.symlink(self.new/'restore-delta.pck',proc/'123/fd/0')
        adapter_sha=low.file_hash(self.new/'restore-adapter.json')
        args=(str(self.root),str(original),self.newid,self.deltasha,adapter_sha,self.wanted)
        with self.assertRaisesRegex(ValueError,'open'):device.cleanup(*args,proc=proc)
        (proc/'123/fd/0').unlink()
        with patch.object(device.os,'rmdir',side_effect=InterruptedError('fixture interruption')):
            with self.assertRaises(InterruptedError):device.cleanup(*args,proc=proc)
        self.assertTrue((self.new/'.vram-merge.lock').exists())
        self.assertEqual(device.cleanup(*args,proc=proc),1)
        self.assertEqual(low.file_hash(main),self.wanted)
        self.assertFalse((self.new/'restore-delta.pck').exists())
        self.assertFalse((self.new/'restore-output').exists())
        self.assertEqual(device.cleanup(*args,proc=proc),0)


if __name__=='__main__':unittest.main()
