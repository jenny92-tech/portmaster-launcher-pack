# INPUT: synthetic cmap glyphs, normalized advances and variation bases
# OUTPUT: conservative CJK delegation decisions
# POS: host-only test; no game files, font packages or device access
import importlib.util
from pathlib import Path
import unittest
import copy
from unittest import mock
import sys
import hashlib
import json
import tempfile
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'ports/sts2/src/tools/godot_pck'))
import merge_mono_subset_trial as gate
import mono_subset_device_merge as device
import low_texture_overlay as low
P=Path(__file__).resolve().parents[1]/'ports/sts2/src/tools/godot_pck/subset_mono_font_worker.py'
spec=importlib.util.spec_from_file_location('mono_worker',P);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class PartitionTests(unittest.TestCase):
 def test_only_equal_cjk_is_delegated(self):
  mono={'a':(1000,0),'b':(1000,10),'different':(900,0)};medium={'x':(2000,0)}
  def check(cp,glyphs,target='x',vary=frozenset()):return m.can_delegate(cp,glyphs,target,mono,medium,1000,2000,vary)
  self.assertTrue(check(0x4e2d,['a','b']))
  self.assertFalse(check(ord('A'),['a']))
  self.assertFalse(check(0x4e2d,['a'],None))
  self.assertFalse(check(0x4e2d,['a','different']))
  self.assertFalse(check(0x4e2d,['a'],'x',{0x4e2d}))
  self.assertFalse(check(0x4e2d,[]))

class EvidenceGateTests(unittest.TestCase):
 def test_rejects_lost_chars_and_fallback_changes(self):
  expected={'target':gate.candidate.MONO,'source_sha256':gate.candidate.MONO_SOURCE,'base_sha256':gate.candidate.MONO_BASE,
   'output_sha256':gate.OUTPUT,'output_md5':gate.OUTPUT_MD5,'import_path':gate.IMPORT}
  uid={'game_count':2493,'compared_count':2490,'original_supported_count':44682,'coverage_losses':[],'all_font_losses':[],
   'width_mismatches':[],'string_differences':[],'same_medium_instance':True,'system_fallback':True,'fallback_count':1,
   'medium_path':'res://fonts/zhs/SourceHanSerifSC-Medium.otf','digit_widths':[24.0]*10,'line_metrics':[[16,24,24,18,18,6,6]]}
  r={'source_sha256':gate.candidate.SOURCE,'base_main_sha256':gate.candidate.BASE,'delta_sha256':gate.DELTA,
   'builder_sha256':'x','worker_sha256':'x','subset_worker_sha256':'x','uid_fixture_sha256':'x','resources':[expected],
   'uid_validation':uid,'subset':{'wheel_sha256':gate.candidate.WHEEL,'delegated':28513,'retained':16170},
   'serialization':{'original_settings':{},'restored_settings':{},'pages':0,'same_medium':True,'system_fallback':True}}
  with mock.patch.object(gate.low,'file_hash',return_value='x'):
   self.assertEqual(gate.verify_evidence(r),expected)
   bad=copy.deepcopy(r);bad['uid_validation']['all_font_losses']=[0x4e2d]
   with self.assertRaisesRegex(ValueError,'validation evidence'):gate.verify_evidence(bad)
   bad=copy.deepcopy(r);bad['uid_validation']['fallback_count']=2
   with self.assertRaisesRegex(ValueError,'validation evidence'):gate.verify_evidence(bad)
   bad=copy.deepcopy(r);bad['resources'].append(expected)
   with self.assertRaisesRegex(ValueError,'target mismatch'):gate.verify_evidence(bad)

class DeviceMergeTests(unittest.TestCase):
 def test_only_bound_parent_and_single_font_merge(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d).resolve();name=device.TARGET;old=b'original-font';new=b'subset-font';other=b'keep'
   def pack(label,values):
    files=[]
    for i,(n,v) in enumerate(sorted(values.items())):
     f=root/(label+str(i));f.write_bytes(v);files.append((n,f))
    target=root/(label+'.pck');low.write_pack(files,target);return target
   source=pack('source',{name:old,'other':other});delta=pack('delta',{name:new})
   oldsha=hashlib.sha256(old).hexdigest();newsha=hashlib.sha256(new).hexdigest();base=low.file_hash(source);dh=low.file_hash(delta)
   adapter=root/'reference-adapter.json';adapter.write_text(json.dumps({'source_sha256':base,'output_sha256':dh,'resources':[{'path':name,'kind':'audited_font','source_sha256':oldsha,'output_sha256':newsha,'output_md5':hashlib.md5(new).hexdigest()}]}))
   approval={name:oldsha}
   with mock.patch.object(device.m,'AUDITED_FONT_SOURCE_SHA256',approval):
    expected=device.m.prepare(source,delta,adapter,root/'reference',approved_font_hashes=approval).stem
   raw=b'{"fixture":true}';active=hashlib.sha256(raw).hexdigest();(root/'active-build').write_text(active+'\n');(root/'builds'/active).mkdir(parents=True);(root/'builds'/active/'manifest.json').write_bytes(raw)
   side=source.with_suffix('.json');st=source.stat();value={'source_sha256':'a'*64,'overlay_sha256':'b'*64,'merged_sha256':base,'merged_stat':{'size':st.st_size,'mtime_ns':st.st_mtime_ns}}
   side.write_text(json.dumps(value));out=root/'trial'
   with mock.patch.multiple(device,ACTIVE=active,BASE=base,BASE_PARENT='a'*64,BASE_DELTA='b'*64,DELTA=dh,EXPECTED=expected,OLD=oldsha,NEW=newsha,root=root,source=source,sidecar=side,delta=delta,out=out),mock.patch.object(device.m,'AUDITED_FONT_SOURCE_SHA256',approval):
    bad=dict(value,overlay_sha256='c'*64);side.write_text(json.dumps(bad))
    with self.assertRaisesRegex(ValueError,'parent sidecar'):device.main()
    self.assertFalse(out.exists());side.write_text(json.dumps(value));device.main()
    self.assertEqual(low.file_hash(out/'packs'/(expected+'.pck')),expected)
    self.assertEqual((root/'active-build').read_text().strip(),active)

if __name__=='__main__':unittest.main()
