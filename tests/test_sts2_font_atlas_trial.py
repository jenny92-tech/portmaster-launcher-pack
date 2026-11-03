# INPUT: synthetic atlas settings and fixed candidate evidence
# OUTPUT: rejected metric, fallback and target tampering
# POS: host-only regression; no game input or device
import copy
from pathlib import Path
import sys
import unittest
from unittest import mock
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'ports/sts2/src/tools/godot_pck'))
import merge_font_atlas_trial as gate
import font_atlas_corpus as corpus

class FontAtlasTrialTest(unittest.TestCase):
 def evidence(self):
  t=gate.trial
  return {'source_sha256':t.SOURCE,'base_main_sha256':t.BASE,'delta_sha256':gate.DELTA,'metrics_report_sha256':t.METRICS,
   'builder_sha256':'test','worker_sha256':'test','uid_fixture_sha256':'test',
   'resources':[{'target':t.TARGET,'source_sha256':t.SOURCE_ENTRY,'base_sha256':t.BASE_ENTRY,'output_sha256':gate.OUTPUT,'output_md5':gate.OUTPUT_MD5,'import_path':t.IMPORT,'import_sha256':gate.IMPORT_SHA}],
   'serialization':{'before':{'msdf_size':48,'msdf_pixel_range':16,'other':True},'after':{'msdf_size':40,'msdf_pixel_range':14,'other':True},'pages':0,'vector_sha256':'210dc788c6cc15ed693c8ecde93ee83bf7714b759befa6aead042d6f6e1b878a'},
   'uid_validation':{'same_medium':True,'system_fallback':True,'canonical':'res://fonts/zhs/SourceHanSerifSC-Medium.otf','mono_size':48,'mono_range':16,'msdf_size':40,'msdf_range':14},
   'metrics_summary':{'source_size':48,'source_range':16,'output_size':40,'output_range':14,'fixed_500_medium':{'glyphs':500,'baseline':{'rgba8_nominal_bytes':15728640},'candidate':{'rgba8_nominal_bytes':11534336}}}}
 def test_gate_rejects_changed_settings_uid_and_target(self):
  r=self.evidence()
  with mock.patch.object(gate.low,'file_hash',return_value='test'):
   self.assertEqual(gate.validate_evidence(r),r['resources'][0])
   for mutate in (lambda d:d['serialization']['after'].update(other=False),lambda d:d['uid_validation'].update(same_medium=False),lambda d:d['resources'].append(d['resources'][0])):
    bad=copy.deepcopy(r);mutate(bad)
    with self.assertRaises(ValueError):gate.validate_evidence(bad)
 def test_localized_corpus_only_collects_values(self):
  out=[];corpus.collect({'key':'hello','nested':['字',{'id':'世界'}]},out)
  self.assertEqual(out,['hello','字','世界'])

if __name__=='__main__':unittest.main()
