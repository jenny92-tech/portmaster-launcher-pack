#!/usr/bin/env python3
# INPUT: exact original Windows PCK and approved 8a main, six common font identities
# OUTPUT: source-bound six-font delta, per-font evidence and private preview images
# POS: reuses the SC codec unchanged; never changes the current main or device
import argparse
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path
from PIL import Image
import strip_font_cache as base

MAIN='8a4d8a475bb7bcb7eb4b94c3691ca8564306c25a630516248e31eaed143c0996'
COMMON={
 'bitter_medium_italic.ttf-92c479ff6780df2f74f735b7f108e0e9.fontdata':('fonts/bitter_medium_italic.ttf.import','021b61ec6ffe4e921b029fbcaf6db2aca58bbefd28d7341e6fee57e1e6715d4e','47cc5e5f495533afeb3dddbf9cbb17be94043dbca41a11c8930e64fe2934ec3a'),
 'kreon_bold.ttf-a39b3c2b8efde4e39050a84b27e67a76.fontdata':('fonts/kreon_bold.ttf.import','7a3e3911f7b942bff4a76bac91ca487d0aa44469a49ea86932b6c7953a908f59','3c37ceea51cc36b9a955a040a8261c827f364b0b443e5ebddf7d84300cb01fc2'),
 'kreon_regular.ttf-a20220d5ba8adf850addcf353acfb496.fontdata':('fonts/kreon_regular.ttf.import','d1afbadb7e8ecceb64f3ab9fdcdc6ef2c87698d54ae665dc993976a55a512482','8974f79cb50e543aa96d115356752b5ad81bdf1e23aa43dbe7fe6a07551cc53f'),
 'source_code_pro_medium.ttf-42cc704cdf728adbe8d0ac6480960df4.fontdata':('fonts/source_code_pro_medium.ttf.import','e0a1f371ee06f94991252baf6e09a4c11262ea2abbbf28ba8ed2e9ea7f46acb7','f9dbc746f60c83f5cb1503b19f90729d8195cab6bb67f2b861d4eb257ed86536'),
 'source_code_pro_semibold.ttf-d97019f12ae606d07c23e8b03c8070e7.fontdata':('fonts/source_code_pro_semibold.ttf.import','1c2ee7f683ba76c20ea03205d677575f60befcdc75bd9bff00db89ce2c03fdc6','6d1b964de7b931da548108b41e2a2815f9da83a509fe3367f7f3f094cf991ff9'),
 'spectral_bold.ttf-e378b9e7ebaebc8fb5ecb687a6943388.fontdata':('fonts/spectral_bold.ttf.import','691a1191d783a2f4eebe50c1f55554e645ec097bb21c88526ae818a8605900f1','45823891ebbaa696d0d890f63598155278e6e49d3edc98475b7049242e1ca58b')}
SC_OUTPUTS={
 'SourceHanSerifSC-Bold.otf-04194762e7aa80a4d47a9f4f008eea67.fontdata':'dbafe081ed0ac4a4fb24c0e794e7525e6733bce18559155cb26fc9e6012c9612',
 'SourceHanSerifSC-Medium.otf-8b1ba143f94f2163fdbd47c3f56634f6.fontdata':'940bd61b8e9938c5a197810d413666736332a121893b57c3da46179989e9fc13',
 'NotoSansMonoCJKsc-Regular.otf-305974efdd77ba2d99a45c70df2b9c8e.fontdata':'2cc2c294a936072b9028cdf7aadfd8bca0902d4e64e4dc8bc200b575e8626fa4'}
COMMON_OUTPUTS={
 'bitter_medium_italic.ttf-92c479ff6780df2f74f735b7f108e0e9.fontdata':'a4dba3cad0ef3509d8ee661512314971459511cadf30eec56272b5d40e6aa5d7',
 'kreon_bold.ttf-a39b3c2b8efde4e39050a84b27e67a76.fontdata':'cf40a67659a3d75ddc03033c7cec8b5a3ccd795b06eefd1a249756344fd013a8',
 'kreon_regular.ttf-a20220d5ba8adf850addcf353acfb496.fontdata':'1b68507c4cb976085a5e7af24f9479475aa7da14b4a5e9fabf2058257b9c6b12',
 'source_code_pro_medium.ttf-42cc704cdf728adbe8d0ac6480960df4.fontdata':'8932ecff7d7d50e9899c57b09d964f2090110d8e0a7b38a56e1b02b98055e741',
 'source_code_pro_semibold.ttf-d97019f12ae606d07c23e8b03c8070e7.fontdata':'5beac7b5f8df7be059a926d6895aedb4a64b39200c49f4801ea16e29b185eaaf',
 'spectral_bold.ttf-e378b9e7ebaebc8fb5ecb687a6943388.fontdata':'1b2d6a881f14f1ecf784de29855589837942821cb46ac8c195879b91375020f7'}
DELTA_SHA='3280be91f4b8b2b8d8af56b4f82350fe9d6cdeb1411c319668e135aece4f3bfa'

def main():
 p=argparse.ArgumentParser(description=__doc__)
 for name in ('source-pck','base-main','godot','output','report','evidence-dir'):p.add_argument('--'+name,type=Path,required=True)
 args=p.parse_args()
 base.low.ensure_distinct_paths((args.source_pck,args.base_main,args.output,args.report))
 if any(path.exists() or path.is_symlink() for path in (args.output,args.report,args.evidence_dir)):raise ValueError('fresh output, report and evidence directory required')
 if base.low.file_hash(args.source_pck)!=base.SOURCE_SHA or base.low.file_hash(args.base_main)!=MAIN:raise ValueError('source/base identity mismatch')
 source=base.low.read_pack(args.source_pck);main_index=base.low.read_pack(args.base_main);sc_verified=[]
 with args.source_pck.open('rb') as src,args.base_main.open('rb') as current:
  for name,expected in SC_OUTPUTS.items():
   target='.godot/imported/'+name;import_path,original_sha=base.FONTS[name]
   if any(k not in index for index in (source,main_index) for k in (target,import_path)):raise ValueError('missing previous SC resource')
   orig=base.low.entry_bytes(src,source[target]);installed=base.low.entry_bytes(current,main_index[target]);orig_import=base.low.entry_bytes(src,source[import_path]);installed_import=base.low.entry_bytes(current,main_index[import_path])
   if base.digest(orig)!=original_sha or base.digest(installed)!=expected or orig_import!=installed_import:raise ValueError('existing SC verification failed')
   sc_verified.append({'target':target,'source_sha256':original_sha,'base_sha256':expected,'import_sha256':base.digest(orig_import)})
 base.MAIN_SHA=MAIN
 base.FONTS={k:(v[0],v[1]) for k,v in COMMON.items()}
 base.WORKER=Path(__file__).with_suffix('.gd')
 args.output.parent.mkdir(parents=True,exist_ok=True)
 args.report.parent.mkdir(parents=True,exist_ok=True)
 with tempfile.TemporaryDirectory(prefix='common-font-build-',dir=args.output.parent) as tmp:
  tmp=Path(tmp);preview=tmp/'raw-preview';preview.mkdir()
  staged_output=tmp/'delta.pck';staged_report=tmp/'report.json';staged_evidence=tmp/'evidence'
  os.environ['SLL_COMMON_FONT_PREVIEW_DIR']=str(preview.resolve())
  original_argv=sys.argv
  sys.argv=[str(base.__file__),'--source-pck',str(args.source_pck),'--base-main',str(args.base_main),'--godot',str(args.godot),'--output',str(staged_output),'--report',str(staged_report),'--evidence-dir',str(staged_evidence)]
  try:base.main()
  finally:sys.argv=original_argv
  report=json.loads(staged_report.read_text())
  if report['delta_sha256']!=DELTA_SHA:raise ValueError('common delta hash mismatch')
  if len(report['resources'])!=6:raise ValueError('unexpected common resource count')
  for i,item in enumerate(report['resources']):
   name=item['target'].split('/')[-1];v=item['validation']
   if name not in COMMON or item['output_sha256']!=COMMON_OUTPUTS[name] or item['font_data_sha256']!=COMMON[name][2] or len(v['metrics'])!=42 or any(not x['present'] or x['glyph']==0 for x in v['metrics']):raise ValueError('common vector, output or glyph validation failed')
   v['glyph_image']['codepoint']=65
   before=Image.open(Path(preview)/(str(i)+'-glyph-before.png')).convert('RGBA')
   after=Image.open(Path(preview)/(str(i)+'-glyph-after.png')).convert('RGBA')
   if before.size!=after.size or before.tobytes()!=after.tobytes():raise ValueError('common glyph pixel verification failed')
   w,h=before.size;out=Image.new('RGB',(w*4+24,h*2+24),'white')
   for side,img in enumerate((before,after)):
    if v['settings']['multichannel_signed_distance_field']:
     mask=Image.new('L',img.size);mask.putdata([max(0,min(255,(sorted(px[:3])[1]-112)*8)) for px in img.getdata()])
    else: mask=img.getchannel('A')
    out.paste('black',(8+side*(w*2+8),8),mask.resize((w*2,h*2),Image.Resampling.NEAREST))
   out.save(staged_evidence/(str(i)+'-glyph.png'))
  report['common_builder_sha256']=base.low.file_hash(Path(__file__))
  report['previous_sc_verified']=sc_verified
  report['limitations'] += ' Common A glyph atlas pixels are identical; previews are CPU approximations, not device rendering.'
  staged_report.write_text(json.dumps(report,ensure_ascii=True,indent=2)+'\n')
  shutil.copytree(staged_evidence,args.evidence_dir)
  staged_output.replace(args.output)
  staged_report.replace(args.report)
 print('Wrote',args.output,'sha256',report['delta_sha256'])
if __name__=='__main__':main()
