#!/usr/bin/env python3
# INPUT: audited texture identities, player source PCK, base overlay, Godot CPU codec
# OUTPUT: source-bound ASTC4x4 delta and per-texture private quality report
# POS: offline candidate build; no game assets or device execution
import argparse
import hashlib
import json
import math
import re
import subprocess
from pathlib import Path
import low_texture_overlay as low

WORKER = Path(__file__).with_name('restore_vram_texture_worker.gd')
SPECS = Path(__file__).resolve().parents[2] / 'scripts/vram_texture_specs.json'

def verify_output(data, expected):
    out=low.parse_texture(data)
    for key in ('logical','gpu','flags','limit','mipmaps'):
        if out[key]!=expected[key]: raise ValueError('restored texture header mismatch: '+key)
    if out['data_format']!=0 or out['image_format']!=35:
        raise ValueError('restored texture is not ASTC4x4')
    return out

def validate_quality(quality, info, require_output_hash=True):
    if not isinstance(quality,dict) or quality.get('status') not in ('accepted','quality_rejected'):
        raise ValueError('invalid cached quality result')
    limits={'alpha_p99':0.04,'alpha_max':0.25,'visible_rgb_p99':0.04}
    if quality.get('limits') != limits: raise ValueError('unexpected quality limits')
    width,height=info['gpu']
    step=max(1,math.ceil(math.sqrt(width*height/65536.0)))
    count=len(range(step//2,width,step))*len(range(step//2,height,step))
    if (type(quality.get('sample_step')) is not int or quality['sample_step']!=step or
        type(quality.get('sample_count')) is not int or quality['sample_count']!=count or
        type(quality.get('visible_samples')) is not int or not 0<=quality['visible_samples']<=count):
        raise ValueError('invalid quality sample metadata')
    values={}
    for name in limits:
        value=quality.get(name)
        if type(value) not in (int,float) or not math.isfinite(value) or not 0<=value<=1:
            raise ValueError('invalid quality metric: '+name)
        values[name]=value
    if values['alpha_p99']>values['alpha_max'] or (quality['visible_samples']==0 and values['visible_rgb_p99']!=0):
        raise ValueError('inconsistent quality metrics')
    accepted=all(values[name]<=limit for name,limit in limits.items())
    if accepted != (quality['status']=='accepted'):raise ValueError('quality decision contradicts metrics')
    if quality['status']=='accepted' and require_output_hash and not re.fullmatch(r'[0-9a-f]{64}',quality.get('output_sha256','')):
        raise ValueError('invalid accepted output hash')
    return quality

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for k in ('source-pck','base-texture','texture-report','godot','cache','output','report'):p.add_argument('--'+k,type=Path,required=True)
    a=p.parse_args()
    temp=a.output.with_name(a.output.name+'.tmp')
    low.ensure_distinct_paths((a.source_pck,a.base_texture,a.texture_report,a.output,a.report,temp))
    if any(x.exists() or x.is_symlink() for x in (a.output,a.report,temp)):raise ValueError('output, report and temporary output must be fresh')
    specs=json.loads(SPECS.read_text());base=json.loads(a.texture_report.read_text())
    if (low.file_hash(a.source_pck)!=specs['source_pck_sha256'] or base.get('source_sha256')!=specs['source_pck_sha256'] or
        low.file_hash(a.base_texture)!=specs['texture_overlay_sha256'] or base.get('output_sha256')!=specs['texture_overlay_sha256']):
        raise ValueError('source or base texture identity mismatch')
    version=subprocess.run([str(a.godot),'--version'],capture_output=True,text=True,check=True).stdout.strip()
    if not version.startswith('4.5.1.stable.official'):raise ValueError('official Godot 4.5.1 required')
    source_index=low.read_pack(a.source_pck);base_index=low.read_pack(a.base_texture)
    a.cache.mkdir(parents=True,exist_ok=True)
    project=a.cache/'worker-project'
    if project.is_symlink():raise ValueError('worker project must not be a symlink')
    project.mkdir(exist_ok=True)
    project_file=project/'project.godot'
    project_content='[application]\nconfig/name="STS2 offline texture codec"\n'
    if project_file.is_symlink() or (project_file.exists() and project_file.read_text()!=project_content):
        raise ValueError('unexpected worker project configuration')
    if not project_file.exists():project_file.write_text(project_content)
    jobs=[];records=[];cache_keys=set()
    encoder=low.digest((low.file_hash(a.godot)+low.file_hash(WORKER)).encode())
    with a.source_pck.open('rb') as src,a.base_texture.open('rb') as overlay:
        for item in specs['resources']:
            record=dict(item)
            if not item['eligible']:
                records.append(record);continue
            target=item['target'].removeprefix('res://')
            if target not in source_index or target not in base_index:raise ValueError('candidate texture missing')
            source=low.entry_bytes(src,source_index[target])
            if (hashlib.sha256(source).hexdigest()!=item['source_sha256'] or hashlib.md5(source).hexdigest()!=item['source_md5'] or
                item['old_sibling_sha256']!=item['source_sha256']):raise ValueError('candidate source hash mismatch')
            blob=low.entry_bytes(overlay,base_index[target])
            if hashlib.md5(blob).hexdigest()!=item['installed_md5'] or low.parse_texture(blob)!=item['input']:
                raise ValueError('candidate base overlay mismatch')
            before=hashlib.sha256(blob).hexdigest()
            key=low.digest((encoder+before).encode())
            if key not in cache_keys:
                cache_keys.add(key)
                input_path=a.cache/(key+'.webp.ctex');out_path=a.cache/(key+'.astc.ctex');quality_path=a.cache/(key+'.quality.json')
                if quality_path.exists():
                    quality=json.loads(quality_path.read_text())
                    validate_quality(quality,item['input'])
                    if quality['status']=='accepted':
                        data=out_path.read_bytes();verify_output(data,item['input'])
                        if low.digest(data)!=quality.get('output_sha256'):raise ValueError('cached ASTC checksum mismatch')
                else:
                    input_path.write_bytes(blob)
                    jobs.append({'input':str(input_path.resolve()),'output':str(out_path.resolve()),'quality':str(quality_path.resolve()),'expected':item['input']})
            record.update({'base_entry_sha256':before,'cache_key':key})
            records.append(record)
    for offset in range(0,len(jobs),128):
        batch=jobs[offset:offset+128];jobfile=a.cache/'restore-vram-jobs.json';jobfile.write_text(json.dumps(batch))
        command=[str(a.godot),'--headless','--path',str(project.resolve()),'--script',str(WORKER.resolve()),'--',str(jobfile.resolve())]
        seen=set()
        with subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1) as proc:
            for line in proc.stdout:
                if not line.startswith('VRAM_RESULT\t'):
                    print(line,end='',flush=True);continue
                _,idx,raw=line.rstrip('\n').split('\t',2);idx=int(idx)
                if idx<0 or idx>=len(batch) or idx in seen:raise ValueError('invalid codec result index')
                job=batch[idx];quality=json.loads(raw)
                validate_quality(quality,job['expected'],require_output_hash=False)
                if quality['status']=='accepted':
                    data=Path(job['output']).read_bytes();verify_output(data,job['expected']);quality['output_sha256']=low.digest(data)
                Path(job['quality']).write_text(json.dumps(quality,sort_keys=True)+'\n');seen.add(idx)
            if proc.wait() or len(seen)!=len(batch):raise ValueError('codec failed or omitted results')
        print(f'converted {offset+len(batch)}/{len(jobs)}',flush=True)
    files=[]
    for item in records:
        key=item.pop('cache_key',None)
        if key is None:continue
        quality=validate_quality(json.loads((a.cache/(key+'.quality.json')).read_text()),item['input']);item['quality']=quality
        if quality['status']=='accepted':
            path=a.cache/(key+'.astc.ctex');data=path.read_bytes();verify_output(data,item['input'])
            if low.digest(data)!=quality['output_sha256']:raise ValueError('ASTC output checksum mismatch')
            item['output_sha256']=low.digest(data);item['output_md5']=low.digest(data,'md5')
            item['output']=low.texture_header(data);item['strategy']='preserve half-size pixels and logical dimensions; ASTC4x4'
            files.append((item['target'].removeprefix('res://'),path))
        else:
            item['retained_reasons'].append('sampled ASTC quality threshold exceeded')
    if not files:raise ValueError('no candidates passed sampled quality gate')
    a.output.parent.mkdir(parents=True,exist_ok=True);a.report.parent.mkdir(parents=True,exist_ok=True)
    written=low.write_pack(sorted(files),temp)
    written_index=low.read_pack(temp)
    if set(written)!=set(written_index):raise ValueError('delta directory mismatch')
    with temp.open('rb') as stream:
        for path,entry in written_index.items():
            if low.digest(low.entry_bytes(stream,entry),'md5')!=written[path]:raise ValueError('delta entry checksum mismatch')
    temp.replace(a.output)
    result={'source_sha256':specs['source_pck_sha256'],'old_source_sha256':specs['old_pck_sha256'],
      'base_texture_sha256':specs['texture_overlay_sha256'],'delta_sha256':low.file_hash(a.output),'encoder_sha256':encoder,
      'specs_sha256':low.file_hash(SPECS), 'builder_sha256':low.file_hash(Path(__file__)),
      'texture_report_sha256':low.file_hash(a.texture_report), 'godot_sha256':low.file_hash(a.godot),
      'accepted_count':len(files),'quality_rejected_count':sum(x.get('quality',{}).get('status')=='quality_rejected' for x in records),
      'scope':'candidate texture delta only; installation, load ordering and runtime efficacy require separate validation',
      'limitations':['Visual quality gate samples a grid; it does not prove full-frame visual equivalence.',
        'Static exclusions cannot discover dynamically constructed shader use.',
        'ASTC hardware fallback and allocation are device dependent; this is not RSS or VRAM measurement.'],
      'resources':records}
    a.report.write_text(json.dumps(result,indent=2)+'\n')
    print('wrote',len(files),'restored textures')
if __name__=='__main__':main()
