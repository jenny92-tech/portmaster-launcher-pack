#!/usr/bin/env python3
# INPUT: fixed f526 source, 9caf parent and audited one-font atlas trial
# OUTPUT: independent candidate main, standard sidecar and source-bound report
# POS: isolated experiment; does not install, launch or change existing packs
import argparse
import importlib.util
import json
from pathlib import Path
import low_texture_overlay as low
import font_atlas_trial as trial

DELTA='62612beae902bf0ce7e3e4145fb477e1034ade2c03674a8681f2b8196c425c45'
REPORT='493870d71eb01820f12104d3b2bbb7cb65281a186cf222875fb42a53f2689c25'
OUTPUT='42b78af56436976770b713811c7e15ab3a43e4a9daf488affa2e85a58984166d'
OUTPUT_MD5='e64bf21daa46250fd49d33e6d7803380'
IMPORT_SHA='367d23ff15382f0bc430f8f198bc10ed591a414ac5a48e8c37b72e82fa615bd0'

def validate_evidence(r):
 if (r.get('source_sha256')!=trial.SOURCE or r.get('base_main_sha256')!=trial.BASE or r.get('delta_sha256')!=DELTA or
     r.get('metrics_report_sha256')!=trial.METRICS or r.get('builder_sha256')!=low.file_hash(Path(trial.__file__)) or
     r.get('worker_sha256')!=low.file_hash(trial.WORKER) or r.get('uid_fixture_sha256')!=low.file_hash(trial.UID)):
  raise ValueError('atlas trial evidence provenance mismatch')
 expected={'target':trial.TARGET,'source_sha256':trial.SOURCE_ENTRY,'base_sha256':trial.BASE_ENTRY,'output_sha256':OUTPUT,'output_md5':OUTPUT_MD5,'import_path':trial.IMPORT,'import_sha256':IMPORT_SHA}
 if r.get('resources')!=[expected]:raise ValueError('atlas candidate target mismatch')
 ser=r['serialization'];before=dict(ser['before']);after=ser['after']
 if before.get('msdf_size')!=48 or before.get('msdf_pixel_range')!=16:raise ValueError('atlas baseline mismatch')
 before['msdf_size']=40;before['msdf_pixel_range']=14
 u=r['uid_validation'];metrics=r['metrics_summary'];page=metrics['fixed_500_medium']
 if (before!=after or ser['pages']!=0 or ser.get('vector_sha256')!='210dc788c6cc15ed693c8ecde93ee83bf7714b759befa6aead042d6f6e1b878a' or u.get('same_medium') is not True or u.get('system_fallback') is not True or
     u.get('canonical')!='res://fonts/zhs/SourceHanSerifSC-Medium.otf' or (u.get('msdf_size'),u.get('msdf_range'))!=(40,14) or (u.get('mono_size'),u.get('mono_range'))!=(48,16) or
     (metrics['source_size'],metrics['source_range'],metrics['output_size'],metrics['output_range'])!=(48,16,40,14) or
     (page['glyphs'],page['baseline']['rgba8_nominal_bytes'],page['candidate']['rgba8_nominal_bytes'])!=(500,15728640,11534336)):
  raise ValueError('atlas trial validation mismatch')
 return expected

def prepare(source,base,delta,report,dest):
 supplied=[Path(x) for x in (source,base,delta,report)]
 if any(x.is_symlink() for x in supplied):raise ValueError('symlink input')
 source,base,delta,report=[x.resolve(strict=True) for x in supplied]
 if any(x.samefile(y) for i,x in enumerate((source,base,delta,report)) for y in (source,base,delta,report)[i+1:]):raise ValueError('inputs must differ')
 dest=Path(dest).absolute();dest=dest.parent.resolve(strict=True)/dest.name
 if dest.exists() or dest.is_symlink() or any(dest==x or dest in x.parents for x in (source,base,delta,report)):raise ValueError('fresh separate destination required')
 for path,want in ((source,trial.SOURCE),(base,trial.BASE),(delta,DELTA),(report,REPORT)):
  if low.file_hash(path)!=want:raise ValueError('atlas trial input mismatch: '+str(path))
 record=validate_evidence(json.loads(report.read_text()));se,be,de=map(low.read_pack,(source,base,delta))
 if set(de)!={trial.TARGET} or any(n not in e for e,n in ((se,trial.TARGET),(be,trial.TARGET),(se,trial.IMPORT),(be,trial.IMPORT))):raise ValueError('atlas closed set mismatch')
 with source.open('rb') as s,base.open('rb') as b,delta.open('rb') as d:
  if (low.digest(low.entry_bytes(s,se[trial.TARGET]))!=trial.SOURCE_ENTRY or low.digest(low.entry_bytes(b,be[trial.TARGET]))!=trial.BASE_ENTRY or
      low.digest(low.entry_bytes(d,de[trial.TARGET]))!=OUTPUT or de[trial.TARGET][2]!=OUTPUT_MD5 or
      low.digest(low.entry_bytes(s,se[trial.IMPORT]))!=IMPORT_SHA or low.digest(low.entry_bytes(b,be[trial.IMPORT]))!=IMPORT_SHA):raise ValueError('atlas entry identity mismatch')
 # Import the existing general merger separately and permit this one fixed
 # source identity only in the short-lived trial process.
 spec=importlib.util.spec_from_file_location('_isolated_atlas_merge',Path(__file__).with_name('merge_texture_pck.py'))
 merge=importlib.util.module_from_spec(spec);spec.loader.exec_module(merge)
 approval={trial.TARGET:trial.BASE_ENTRY};merge.AUDITED_FONT_SOURCE_SHA256=approval
 dest.mkdir();adapter=dest/'merge-input.json'
 adapter.write_text(json.dumps({'source_sha256':trial.BASE,'output_sha256':DELTA,'resources':[{'path':trial.TARGET,'kind':'audited_font',
  'source_sha256':trial.BASE_ENTRY,'output_sha256':OUTPUT,'output_md5':OUTPUT_MD5}]})+'\n')
 out=merge.prepare(base,delta,adapter,dest/'packs',approved_font_hashes=approval)
 provenance={'source_sha256':trial.SOURCE,'base_main_sha256':trial.BASE,'delta_sha256':DELTA,'delta_report_sha256':REPORT,'merged_sha256':out.stem,
  'targets':[trial.TARGET],'merge_source_sha256':low.file_hash(Path(__file__)),'limitations':['40/14 changes measured text advances and line metrics.','Offline nominal atlas page savings are not actual game RSS or GPU use.']}
 (dest/'report.json').write_text(json.dumps(provenance,indent=2)+'\n');print(json.dumps({'main':str(out),'sha256':out.stem,'report':str(dest/'report.json')}));return out
if __name__=='__main__':
 try:
  p=argparse.ArgumentParser(description=__doc__)
  for n in ('source','base','delta','report','output-dir'):p.add_argument('--'+n,type=Path,required=True)
  a=p.parse_args();prepare(a.source,a.base,a.delta,a.report,a.output_dir)
 except (OSError,ValueError,KeyError,TypeError) as e:raise SystemExit('font atlas merge failed: '+str(e))
