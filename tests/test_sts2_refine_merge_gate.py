# INPUT: synthetic source/base/previous/refinement PCKs and reports
# OUTPUT: source-bound closed-set, quality, protected and rejected-entry regressions
# POS: local test; no user assets or devices
from contextlib import ExitStack
import copy,json,struct,sys,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'ports/sts2/src/tools/godot_pck'))
import low_texture_overlay as low
import merge_texture_pck as merge
import merge_refined_quarter as gate


def texture(w,h):
 b=bytearray(52);struct.pack_into('<4s5I',b,0,b'GST2',1,512,768,0,0);struct.pack_into('<IHHII',b,36,0,w,h,0,37)
 return bytes(b)+bytes(((w+7)//8)*((h+7)//8)*16)

class RefineGateTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name).resolve()
  self.names=['.godot/imported/a.ctex','.godot/imported/b.ctex'];self.sources=['images/a.png','images/b.png'];self.raw=texture(512,768);self.basebytes=texture(256,384);self.after=texture(128,192)
  self.source=self.pack('source',{n:self.raw for n in self.names}|{'opaque':b'original'});self.base=self.pack('base',{n:self.basebytes for n in self.names}|{'opaque':b'unchanged'});self.previous_delta=self.pack('previous',{});self.delta=self.pack('delta',{self.names[0]:self.after})
  self.godot=self.root/'godot';self.godot.write_bytes(b'engine');self.compiler=self.root/'compiler';self.compiler.write_bytes(b'compiler');self.astc=self.root/'astc';self.astc.mkdir()
  self.spec=self.root/'spec.json';sp=[{'source':'res://'+s,'target':'res://'+n,'source_sha256':low.digest(self.raw)} for n,s in zip(self.names,self.sources)];self.spec.write_text(json.dumps({'source_pck_sha256':low.file_hash(self.source),'resources':sp}))
  h=low.texture_header(self.raw);base=low.parse_texture(self.basebytes);after=low.parse_texture(self.after)
  tx=[{'kind':'texture','path':n,'source_path':s,'source_sha256':low.digest(self.raw),'source_md5':low.digest(self.raw,'md5'),'input':h,'output':base,'output_md5':low.digest(self.basebytes,'md5')} for n,s in zip(self.names,self.sources)]
  self.texture_report=self.root/'texture.json';self.texture_report.write_text(json.dumps({'source_sha256':low.file_hash(self.source),'resources':tx}))
  self.prev_report=self.root/'previous.json';self.prev_report.write_text(json.dumps({'source_sha256':low.file_hash(self.source),'base_main_sha256':'b'*64,'delta_sha256':low.file_hash(self.previous_delta),'resources':[]}))
  q={'status':'accepted','limits':gate.quarter.LIMITS,'sample_step':2,'sample_count':6144,'visible_samples':6144,'alpha_p99':0,'alpha_max':0,'visible_rgb_p99':0};bad=dict(q,status='quality_rejected',alpha_max=0.9)
  def att(preset,quality):return {'block':8,'preset':preset,'alpha_weight':4,'alpha_weight_flag':True,'payload_bytes':6144,'quality':quality}
  good=att(60,q);self.records=[]
  for n,s in zip(self.names,self.sources):self.records.append({'source':'res://'+s,'target':'res://'+n,'role':'visual_vfx_texture','scale_denominator':4,'source_sha256':low.digest(self.raw),'source_md5':low.digest(self.raw,'md5'),'base_sha256':low.digest(self.basebytes),'base_md5':low.digest(self.basebytes,'md5'),'input':h,'base':base,'base_nominal_bytes':gate.refine.nominal(base)})
  self.records[0].update(status='accepted',attempts=[good],selected=good,output=after,output_nominal_bytes=6144,output_sha256=low.digest(self.after),output_md5=low.digest(self.after,'md5'))
  self.records[1].update(status='quality_rejected',attempts=[att(60,bad),att(98,bad)])
  self.outreport=self.root/'refine.json';self.stack=ExitStack();self.addCleanup(self.stack.close)
  for obj,name,val in [(gate.refine,'SOURCE_SHA',low.file_hash(self.source)),(gate.refine,'MAIN_SHA',low.file_hash(self.base)),(gate.refine,'DELTA_SHA',low.file_hash(self.previous_delta)),(gate.refine,'PREVIOUS_REPORT_SHA',low.file_hash(self.prev_report)),(gate.refine,'ASTC_SOURCE_SHA','c'*64),(gate.quarter,'MAIN_SHA','b'*64),(gate.quarter,'REPORT_SHA',low.file_hash(self.texture_report)),(gate.quarter,'SPECS_SHA',low.file_hash(self.spec)),(gate.quarter,'SPECS',self.spec),(gate,'DELTA_SHA',low.file_hash(self.delta))]:self.stack.enter_context(patch.object(obj,name,val))
  candidates=[('res://'+s,n,'visual_vfx_texture',4,None) for n,s in zip(self.names,self.sources)];self.stack.enter_context(patch.object(gate.refine,'candidate_records',return_value=(candidates,{x['path']:x for x in tx},{n:x for n,x in zip(self.names,sp)})))
  self.stack.enter_context(patch.object(gate.refine,'source_identity',return_value='c'*64));self.stack.enter_context(patch.object(gate.windows,'windows_import_map',return_value=({n:(s,) for n,s in zip(self.names,self.sources)},{},set(),set())));self.stack.enter_context(patch.object(gate.low,'protected',return_value=False));self.write_report()
 def pack(self,name,items):
  files=[]
  for i,(n,data) in enumerate(items.items()):p=self.root/(name+str(i));p.write_bytes(data);files.append((n,p))
  out=self.root/(name+'.pck');low.write_pack(files,out);return out
 def write_report(self):
  d={'source_sha256':low.file_hash(self.source),'base_main_sha256':low.file_hash(self.base),'previous_delta_sha256':low.file_hash(self.previous_delta),'previous_report_sha256':low.file_hash(self.prev_report),'texture_report_sha256':low.file_hash(self.texture_report),'specs_sha256':low.file_hash(self.spec),'astc_source_sha256':'c'*64,'godot_sha256':low.file_hash(self.godot),'compiler_sha256':low.file_hash(self.compiler),'builder_sha256':low.file_hash(Path(gate.refine.__file__)),'worker_sha256':low.file_hash(gate.refine.WORKER),'encoder_source_sha256':low.file_hash(gate.refine.ENCODER),'delta_sha256':low.file_hash(self.delta),'candidate_count':2,'accepted_count':1,'rejected_count':1,'resources':self.records};self.outreport.write_text(json.dumps(d))
 def run_gate(self,name):
  adapter=self.root/(name+'-adapter.json');adapter.write_text(json.dumps({'source_sha256':low.file_hash(self.base),'output_sha256':low.file_hash(self.delta),'resources':[{'path':self.names[0],'output_md5':low.digest(self.after,'md5')}]}));ref=merge.prepare(self.base,self.delta,adapter,self.root/(name+'-reference'))
  with patch.object(gate,'REPORT_SHA',low.file_hash(self.outreport)),patch.object(gate,'MAIN_SHA',ref.stem):return gate.prepare(self.source,self.base,self.previous_delta,self.prev_report,self.texture_report,self.delta,self.outreport,self.godot,self.compiler,self.astc,self.root/name)
 def test_accept_and_reject_preserve_nonselected_data(self):
  p=self.run_gate('good');entries=low.read_pack(p)
  with p.open('rb') as f:self.assertEqual(low.entry_bytes(f,entries[self.names[0]]),self.after);self.assertEqual(low.entry_bytes(f,entries[self.names[1]]),self.basebytes);self.assertEqual(low.entry_bytes(f,entries['opaque']),b'unchanged')
 def test_forged_attempt_and_rejected_output_fail(self):
  self.records[0]['attempts'][0]['alpha_weight']=3;self.write_report()
  with self.assertRaises(ValueError):self.run_gate('bad-attempt')
  self.records[0]['attempts'][0]['alpha_weight']=4;self.records[1]['output_sha256']='0'*64;self.write_report()
  with self.assertRaises(ValueError):self.run_gate('bad-reject')
 def test_protected_input_and_duplicate_report_fail(self):
  with patch.object(gate.low,'protected',return_value=True):
   with self.assertRaises(ValueError):self.run_gate('protected')
  self.records.append(copy.deepcopy(self.records[0]));self.write_report()
  with self.assertRaises(ValueError):self.run_gate('duplicate')
if __name__=='__main__':unittest.main()
