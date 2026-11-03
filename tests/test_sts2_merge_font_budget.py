# INPUT: synthetic font delta and isolated PCK fixtures
# OUTPUT: fixed target/report gate and byte-preserving merge regression
# POS: host-only test; no commercial data, device, or game execution
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[1];TOOLS=ROOT/'ports/sts2/src/tools/godot_pck';sys.path.insert(0,str(TOOLS))
import low_texture_overlay as low
spec=importlib.util.spec_from_file_location('merge_font_budget_trial',TOOLS/'merge_font_budget_trial.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

def digest(data):return hashlib.sha256(data).hexdigest()

class FontBudgetMergeTest(unittest.TestCase):
 def test_fixed_four_entry_merge_and_report_rejection(self):
  with tempfile.TemporaryDirectory() as temp:
   root=Path(temp);old={name:('old-'+name).encode() for name in m.EXPECTED};old['untouched']=b'unchanged'
   for name in m.EXPECTED-{m.trial.BOLD}:old[name+'.import']=('import-'+name).encode()
   new={name:('new-'+name).encode() for name in m.EXPECTED}
   def pack(name,items):
    files=[]
    for i,(key,data) in enumerate(sorted(items.items())):
     p=root/(name+str(i));p.write_bytes(data);files.append((key,p))
    p=root/(name+'.pck');low.write_pack(files,p);return p
   src=pack('source',old);base=pack('base',old);delta=pack('delta',new)
   items=[]
   for name in sorted(m.EXPECTED):
    r={'target':name,'source_sha256':digest(old[name]),'base_sha256':digest(old[name]),'output_sha256':digest(new[name]),'output_md5':hashlib.md5(new[name]).hexdigest()}
    if name!=m.trial.BOLD:
     r.update(import_path=name+'.import',import_sha256=digest(old[name+'.import']),font_data_sha256='data',
      validation={'before_settings':{'msdf_pixel_range':24},'after_settings':{'msdf_pixel_range':16},'output_pages':0,'font_data_sha256':'data'},
      coverage_metrics={'game_count':2493,'extended_count':23644,'coverage_losses':[],'old_missing_game':[287,305,322]})
    items.append(r)
   report={'source_sha256':low.file_hash(src),'base_main_sha256':m.trial.MAIN_SHA,'delta_sha256':low.file_hash(delta),
    'builder_sha256':m.merge.sha256_file(Path(m.trial.__file__)),'worker_sha256':m.merge.sha256_file(m.trial.WORKER),'resources':items,
    'shared_validation':{'canonical_medium_same_instance':True,'system_fallback':True,'bold_fallbacks':[],
      'bold_canonical_path':'res://fonts/zhs/SourceHanSerifSC-Medium.otf','mono_canonical_path':'res://fonts/zhs/NotoSansMonoCJKsc-Regular.otf'}}
   rp=root/'report.json';rp.write_text(json.dumps(report))
   with mock.patch.object(m,'SOURCE',low.file_hash(src)),mock.patch.object(m,'BASE',low.file_hash(base)),mock.patch.object(m,'DELTA',low.file_hash(delta)),mock.patch.object(m,'REPORT',low.file_hash(rp)):
    output=m.prepare(src,base,delta,rp,root/'out');entries=low.read_pack(output)
    with output.open('rb') as f:
     for key in old:self.assertEqual(low.entry_bytes(f,entries[key]),new.get(key,old[key]))
    bad=dict(report);bad['resources']=report['resources'][:-1]
    with self.assertRaisesRegex(ValueError,'target count'):m.validate_report(bad)
    bad=dict(report);bad['shared_validation']=dict(report['shared_validation'],bold_fallbacks=['unexpected'])
    with self.assertRaisesRegex(ValueError,'shared instance'):m.validate_report(bad)

if __name__=='__main__':unittest.main()
