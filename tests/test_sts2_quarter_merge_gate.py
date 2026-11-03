# INPUT: synthetic source/base/delta PCKs and fixed quarter texture identities
# OUTPUT: exact candidate, quality, source/output and no-overwrite regressions
# POS: offline test only; no commercial inputs or device
from contextlib import ExitStack
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'ports/sts2/src/tools/godot_pck'))
import low_texture_overlay as low
import merge_texture_pck as merge
import merge_quarter_texture as gate


def texture(w,h):
 b=bytearray(52);struct.pack_into('<4s5I',b,0,b'GST2',1,512,768,0,0);struct.pack_into('<IHHII',b,36,0,w,h,0,37)
 return bytes(b)+bytes(((w+7)//8)*((h+7)//8)*16)

class QuarterGateTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name).resolve();self.name='.godot/imported/example.ctex';self.path='images/example.png'
  self.original=texture(512,768);self.current=texture(256,384);self.after=texture(128,192)
  self.source=self.pack('source',{self.name:self.original,'opaque':b'original'});self.base=self.pack('base',{self.name:self.current,'opaque':b'unchanged'});self.delta=self.pack('delta',{self.name:self.after})
  h=low.texture_header(self.original);base=low.parse_texture(self.current);after=low.parse_texture(self.after)
  self.spec=self.root/'specs.json';self.spec.write_text(json.dumps({'source_pck_sha256':low.file_hash(self.source),'resources':[{'source':'res://'+self.path,'target':'res://'+self.name,'source_sha256':low.digest(self.original)}]}))
  self.report=self.root/'texture.json';self.report.write_text(json.dumps({'source_sha256':low.file_hash(self.source),'resources':[{'kind':'texture','path':self.name,'source_path':self.path,'source_sha256':low.digest(self.original),'source_md5':low.digest(self.original,'md5'),'input':h,'output':base,'output_md5':low.digest(self.current,'md5')}]}))
  self.godot=self.root/'godot';self.godot.write_bytes(b'fixture-engine')
  q={'status':'accepted','limits':gate.quarter.LIMITS,'sample_step':2,'sample_count':6144,'visible_samples':6144,'alpha_p99':0,'alpha_max':0,'visible_rgb_p99':0,'output_sha256':low.digest(self.after)}
  self.item={'source':'res://'+self.path,'target':'res://'+self.name,'role':'visual_vfx_texture','source_sha256':low.digest(self.original),'source_md5':low.digest(self.original,'md5'),'base_sha256':low.digest(self.current),'base_md5':low.digest(self.current,'md5'),'input':h,'base':base,'output':after,'output_sha256':low.digest(self.after),'output_md5':low.digest(self.after,'md5'),'quality':q}
  self.outreport=self.root/'delta-report.json';self.stack=ExitStack();self.addCleanup(self.stack.close)
  for name,val in [('SOURCE_SHA',low.file_hash(self.source)),('MAIN_SHA',low.file_hash(self.base)),('REPORT_SHA',low.file_hash(self.report)),('SPECS_SHA',low.file_hash(self.spec)),('SPECS',self.spec)]:self.stack.enter_context(patch.object(gate.quarter,name,val))
  self.stack.enter_context(patch.object(gate.quarter,'classify',return_value='visual_vfx_texture'))
  self.stack.enter_context(patch.object(gate.windows,'windows_import_map',return_value=({self.name:(self.path,)},{},set(),set())))
  self.stack.enter_context(patch.object(gate.low,'protected',return_value=False))
  self.stack.enter_context(patch.object(gate,'DELTA_SHA',low.file_hash(self.delta)))
  self.write_report()
 def pack(self,name,items):
  files=[]
  for i,(path,data) in enumerate(items.items()):p=self.root/(name+str(i));p.write_bytes(data);files.append((path,p))
  out=self.root/(name+'.pck');low.write_pack(files,out);return out
 def write_report(self):
  r={'source_sha256':low.file_hash(self.source),'base_main_sha256':low.file_hash(self.base),'texture_report_sha256':low.file_hash(self.report),'specs_sha256':low.file_hash(self.spec),'godot_sha256':low.file_hash(self.godot),'delta_sha256':low.file_hash(self.delta),'builder_sha256':low.file_hash(Path(gate.quarter.__file__)),'worker_sha256':low.file_hash(gate.quarter.WORKER),'profile':gate.quarter.PROFILE,'candidate_count':1,'accepted_count':1,'quality_rejected_count':0,'resources':[self.item]};self.outreport.write_text(json.dumps(r))
 def run_gate(self,name):
  # Predict deterministic merged hash using the same stream writer independently of the gate.
  adapter=self.root/(name+'-adapter.json');adapter.write_text(json.dumps({'source_sha256':low.file_hash(self.base),'output_sha256':low.file_hash(self.delta),'resources':[{'path':self.name,'output_md5':low.digest(self.after,'md5')}]}))
  reference=merge.prepare(self.base,self.delta,adapter,self.root/(name+'-reference'))
  with patch.object(gate,'REPORT_SHA',low.file_hash(self.outreport)),patch.object(gate,'MAIN_SHA',reference.stem):
   return gate.prepare(self.source,self.base,self.report,self.delta,self.outreport,self.godot,self.root/name)
 def test_exact_accepted_texture_preserves_opaque_data(self):
  result=self.run_gate('good');entries=low.read_pack(result)
  with result.open('rb') as f:
   self.assertEqual(low.entry_bytes(f,entries[self.name]),self.after)
   self.assertEqual(low.entry_bytes(f,entries['opaque']),b'unchanged')
 def test_quality_reject_or_forged_output_never_merges(self):
  self.item['quality']['status']='quality_rejected';self.item['quality']['alpha_max']=0.9;self.write_report()
  with self.assertRaises(ValueError):self.run_gate('rejected')
  self.item['quality']['status']='accepted';self.item['quality']['alpha_max']=0;self.item['output_sha256']='0'*64;self.write_report()
  with self.assertRaises(ValueError):self.run_gate('forged')
 def test_unknown_role_and_duplicate_report_rejected(self):
  self.item['role']='room';self.write_report()
  with self.assertRaises(ValueError):self.run_gate('wrongrole')
  self.item['role']='visual_vfx_texture';self.write_report();j=json.loads(self.outreport.read_text());j['resources'].append(self.item);self.outreport.write_text(json.dumps(j))
  with self.assertRaises(ValueError):self.run_gate('duplicate')
if __name__=='__main__':unittest.main()
