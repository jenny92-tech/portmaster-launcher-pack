#!/usr/bin/env python3
# INPUT: exact v0.110.1 source and base main PCKs plus official Godot 4.5.1
# OUTPUT: isolated three-font delta and identity/metric report
# POS: offline private build; no source rewrite, game execution or device access
import argparse
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path
import low_texture_overlay as low
from PIL import Image, ImageChops

SOURCE_SHA='f526ef85cd5b7cf653defb545a8ba22196c72e6a0e95ad66f78f2f3a168b28c9'
MAIN_SHA='a9c61d767c577ea066010af452f6e706ae2c0925f41b800b0bfe0c4d3f835daa'
WORKER=Path(__file__).with_suffix('.gd')
FONTS={
 'SourceHanSerifSC-Bold.otf-04194762e7aa80a4d47a9f4f008eea67.fontdata':('fonts/zhs/SourceHanSerifSC-Bold.otf.import','cf9d9a2948cf582e73a27c3c4d6f225c1483495057f4fffa66df9242b65d29ce'),
 'SourceHanSerifSC-Medium.otf-8b1ba143f94f2163fdbd47c3f56634f6.fontdata':('fonts/zhs/SourceHanSerifSC-Medium.otf.import','e73efe426dd1f713e31b58ee34544bb0567949645b51d14059486c604478494e'),
 'NotoSansMonoCJKsc-Regular.otf-305974efdd77ba2d99a45c70df2b9c8e.fontdata':('fonts/zhs/NotoSansMonoCJKsc-Regular.otf.import','89b8497ad0ca58e9e53e45e522ef2a345fa944f6a26fbdebf3c3261eb9b28df9')}

def digest(data,algorithm='sha256'):
 return hashlib.new(algorithm,data).hexdigest()

def main():
 p=argparse.ArgumentParser(description=__doc__)
 for name in ('source-pck','base-main','godot','output','report','evidence-dir'):p.add_argument('--'+name,type=Path,required=True)
 args=p.parse_args()
 low.ensure_distinct_paths((args.source_pck,args.base_main,args.output,args.report))
 if any(p.exists() or p.is_symlink() for p in (args.output,args.report,args.evidence_dir)): raise ValueError('fresh output, report and evidence directory required')
 if low.file_hash(args.source_pck)!=SOURCE_SHA or low.file_hash(args.base_main)!=MAIN_SHA: raise ValueError('source/base PCK identity mismatch')
 version=subprocess.run([str(args.godot),'--version'],capture_output=True,text=True,check=True).stdout.strip()
 if not version.startswith('4.5.1.stable.official'):raise ValueError('official Godot 4.5.1 required')
 source=low.read_pack(args.source_pck);base=low.read_pack(args.base_main)
 args.output.parent.mkdir(parents=True,exist_ok=True);args.report.parent.mkdir(parents=True,exist_ok=True)
 records=[]
 with tempfile.TemporaryDirectory(prefix='fontcache-',dir=args.output.parent) as tmp:
  tmp=Path(tmp);(tmp/'project.godot').write_text('[application]\nconfig/name="isolated font cache worker"\n')
  files=[]
  with args.source_pck.open('rb') as src,args.base_main.open('rb') as main_stream:
   for index,(name,(import_path,expected)) in enumerate(FONTS.items()):
    target='.godot/imported/'+name
    if any(k not in index_map for index_map in (source,base) for k in (target,import_path)): raise ValueError('missing font/import entry')
    original=low.entry_bytes(src,source[target]);installed=low.entry_bytes(main_stream,base[target])
    orig_import=low.entry_bytes(src,source[import_path]);main_import=low.entry_bytes(main_stream,base[import_path])
    if digest(original)!=expected or original!=installed or orig_import!=main_import or ('res://'+target).encode() not in orig_import: raise ValueError('font or import identity mismatch: '+target)
    srcfile=tmp/(str(index)+'-original.res');dstfile=tmp/(str(index)+'-output.res');rawfile=tmp/(str(index)+'-font.otf')
    srcfile.write_bytes(original)
    prefix=tmp/(str(index)+'-glyph')
    command=[str(args.godot),'--headless','--path',str(tmp.resolve()),'--script',str(WORKER.resolve()),'--',str(srcfile.resolve()),str(dstfile.resolve()),str(rawfile.resolve()),str(prefix.resolve())]
    run=subprocess.run(command,capture_output=True,text=True,timeout=180)
    if run.returncode:raise RuntimeError('Godot font worker failed: '+run.stdout+'\n'+run.stderr)
    values=[x.partition('\t')[2] for x in run.stdout.splitlines() if x.startswith('FONT_RESULT\t')]
    if len(values)!=1 or not dstfile.is_file() or not rawfile.is_file():raise ValueError('invalid Godot font worker result')
    result=json.loads(values[0]);output=dstfile.read_bytes()
    if digest(rawfile.read_bytes())!=result['font_data_sha256'] or not output.startswith(b'RSCC'):raise ValueError('font output or data identity mismatch')
    before_image=Image.open(str(prefix)+'-before.png').convert('RGB')
    after_image=Image.open(str(prefix)+'-after.png').convert('RGB')
    if before_image.size!=after_image.size:raise ValueError('glyph image dimensions changed')
    diff=ImageChops.difference(before_image,after_image)
    if diff.getbbox() is not None:raise ValueError('representative glyph image changed')
    result['glyph_image']={'codepoint':23383,'size':list(before_image.size),'exact_pixels':diff.getbbox() is None}
    # MSDF atlas pixels are converted to a simple median-threshold preview;
    # this is not a GPU shader or a substitute for device text QA.
    preview=Image.new('RGB',(before_image.width*8+24,before_image.height*4+24),'white')
    for side,img in enumerate((before_image,after_image)):
     a=Image.new('L',img.size)
     a.putdata([max(0,min(255,(sorted(rgb)[1]-112)*8)) for rgb in img.getdata()])
     mask=a.resize((img.width*4,img.height*4),Image.Resampling.NEAREST)
     preview.paste('black',(8+side*(img.width*4+8),8),mask)
    preview.save(tmp/(str(index)+'-preview.png'))
    result['status']='verified'
    records.append({'target':target,'import_path':import_path,'import_sha256':digest(orig_import),'source_sha256':expected,'source_md5':digest(original,'md5'),'base_sha256':digest(installed),'output_sha256':digest(output),'output_md5':digest(output,'md5'),'source_bytes':len(original),'output_bytes':len(output),'font_data_sha256':result['font_data_sha256'],'validation':result})
    files.append((target,dstfile))
  temp=tmp/'delta.pck';low.write_pack(sorted(files),temp);check=low.read_pack(temp)
  if set(check)!={r['target'] for r in records}:raise ValueError('unexpected delta contents')
  with temp.open('rb') as f:
   for rec in records:
    if digest(low.entry_bytes(f,check[rec['target']]))!=rec['output_sha256']:raise ValueError('delta content mismatch')
  report={'source_sha256':SOURCE_SHA,'base_main_sha256':MAIN_SHA,'delta_sha256':low.file_hash(temp),'godot_sha256':low.file_hash(args.godot),'godot_version':version,'builder_sha256':low.file_hash(Path(__file__)),'worker_sha256':low.file_hash(WORKER),'resources':records,'limitations':'Offline headless glyph metrics and short cold sample; rendering latency and memory on target are unmeasured.'}
  args.evidence_dir.mkdir(parents=True)
  for index in range(len(records)):
   (args.evidence_dir/(str(index)+'-glyph.png')).write_bytes((tmp/(str(index)+'-preview.png')).read_bytes())
  temp.replace(args.output);args.report.write_text(json.dumps(report,ensure_ascii=True,indent=2)+'\n')
 print('Wrote',args.output,'sha256',report['delta_sha256'])
if __name__=='__main__':main()
