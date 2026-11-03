#!/usr/bin/env python3
# INPUT: pinned Windows source, installed main PCK, audited texture inventory and Godot
# OUTPUT: independent original-quarter ASTC8 texture delta and identity/quality report
# POS: offline optional profile; never changes installed packs or normal profile
"""Build a source-bound, conservative quarter-resolution visual texture delta."""
import argparse
import json
import math
import re
import subprocess
import tempfile
from pathlib import Path
import low_texture_overlay as low
import windows_texture_overlay as windows

SOURCE_SHA = 'f526ef85cd5b7cf653defb545a8ba22196c72e6a0e95ad66f78f2f3a168b28c9'
MAIN_SHA = '3abccf4a75ea347b0d4cece05d376beeaf42b4f34a3af1ccc17644bd2762203d'
REPORT_SHA = '3425926d411bc1337bbfa8118430baad284434e63ea11bae5b56fedaaee02bb7'
SPECS_SHA = '95d9d334bb86d2b85f4e337f54306d1b63ee621e21ae1843ffa2478ecb1805b9'
SPECS = Path(__file__).resolve().parents[2] / 'scripts/vram_texture_specs.json'
WORKER = Path(__file__).with_name('quarter_texture_worker.gd')
ROLES = ['card_atlas', 'card_portrait', 'room', 'spine_atlas_page', 'visual_vfx_texture']
PROFILE = {'source_scale_denominator':4, 'astc_block':[8,8], 'min_short':128, 'min_long':192, 'roles':ROLES}
LIMITS = {'alpha_p99':0.08, 'alpha_max':0.35, 'visible_rgb_p99':0.18}
CARD_ATLASES = {'res://images/atlases/card_atlas_0.png','res://images/atlases/card_atlas_1.png'}
PROTECTED = {'sensitive data, mask, noise or font name', 'referenced as a shader parameter', 'protected font, LUT, normal or data texture'}

def classify(spec, entry):
    """Only audited direct visual roles; dynamic or mixed shader uses stay out."""
    if any(reason in PROTECTED for reason in spec['retained_reasons']): return None
    source=spec['source']; fields=set(spec['direct_fields']); role=spec['role']
    if source in CARD_ATLASES and fields == {'atlas'}: role='card_atlas'
    elif role in ('card_portrait','spine_atlas_page','visual_vfx_texture') and 'unknown or non-visual direct dependency' not in spec['retained_reasons']: pass
    elif source.startswith('res://images/rooms/') and fields and fields.issubset({'texture','_frames'}): role='room'
    else: return None
    original=entry['input']; current=entry.get('output',original)
    if original['mipmaps'] or current['mipmaps']: return None
    if (original['data_format'],original['image_format']) not in ((2,4),(2,5),(0,17),(0,19),(0,22)): return None
    if (current['data_format'],current['image_format']) not in ((2,4),(2,5),(0,35),(0,37)): return None
    w,h=(max(1,n//4) for n in original['gpu'])
    if min(w,h)<128 or max(w,h)<192: return None
    return role

def verify_output(blob, original):
    out=low.parse_texture(blob)
    if any(out[k]!=original[k] for k in ('logical','flags','limit')) or out['gpu'] != [max(1,n//4) for n in original['gpu']] or (out['data_format'],out['image_format'],out['mipmaps']) != (0,37,0):
        raise ValueError('quarter output header mismatch')
    return out

def validate_quality(q, original):
    if not isinstance(q,dict) or q.get('status') not in ('accepted','quality_rejected') or q.get('limits')!=LIMITS: raise ValueError('invalid quality result')
    w,h=(max(1,n//4) for n in original['gpu']); step=max(1,math.ceil(math.sqrt(w*h/16384.0)))
    count=len(range(step//2,w,step))*len(range(step//2,h,step))
    if type(q.get('sample_step')) is not int or q['sample_step']!=step or type(q.get('sample_count')) is not int or q['sample_count']!=count or type(q.get('visible_samples')) is not int or not 0<=q['visible_samples']<=count: raise ValueError('invalid quality sampling')
    for k in LIMITS:
        if type(q.get(k)) not in (int,float) or not math.isfinite(q[k]) or not 0<=q[k]<=1: raise ValueError('invalid quality measurement')
    if q['alpha_p99']>q['alpha_max'] or (not q['visible_samples'] and q['visible_rgb_p99']!=0): raise ValueError('inconsistent quality measurement')
    if (q['status']=='accepted') != all(q[k]<=v for k,v in LIMITS.items()): raise ValueError('quality decision mismatch')

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for key in ('source-pck','base-main','texture-report','godot','cache','output','report'): p.add_argument('--'+key,type=Path,required=True)
    p.add_argument('--batch-size',type=int,default=32)
    a=p.parse_args()
    if not 1<=a.batch_size<=128: raise ValueError('invalid batch size')
    low.ensure_distinct_paths((a.source_pck,a.base_main,a.texture_report,a.output,a.report))
    if a.output.exists() or a.report.exists() or a.output.is_symlink() or a.report.is_symlink(): raise ValueError('fresh outputs required')
    for path,expected in ((a.source_pck,SOURCE_SHA),(a.base_main,MAIN_SHA),(a.texture_report,REPORT_SHA),(SPECS,SPECS_SHA)):
        if low.file_hash(path)!=expected: raise ValueError('input identity mismatch: '+str(path))
    version=subprocess.run([str(a.godot),'--version'],capture_output=True,text=True,check=True).stdout.strip()
    if not version.startswith('4.5.1.stable.official'): raise ValueError('official Godot 4.5.1 required')
    report=json.loads(a.texture_report.read_text()); specs=json.loads(SPECS.read_text())
    if report['source_sha256']!=SOURCE_SHA or specs['source_pck_sha256']!=SOURCE_SHA: raise ValueError('source mismatch')
    source=low.read_pack(a.source_pck); mainpack=low.read_pack(a.base_main)
    s={x['target'][6:]:x for x in specs['resources']}; records=[]; candidates=[]
    if len(s)!=len(specs['resources']): raise ValueError('duplicate specs')
    with a.source_pck.open('rb') as src,a.base_main.open('rb') as base:
        mapping,imports,spines,fonts=windows.windows_import_map(src,source)
        textures=[x for x in report['resources'] if x.get('kind')=='texture']
        if len({x['path'] for x in textures})!=len(textures) or set(s)!=set(mapping): raise ValueError('texture inventory mismatch')
        for item in textures:
            target=item['path']; spec=s.get(target)
            if spec is None: raise ValueError('unknown texture in report')
            role=classify(spec,item)
            if not role: continue
            if target not in mainpack or mapping[target][0]!=item['source_path'] or spec['source']!='res://'+item['source_path']: raise ValueError('mapping mismatch')
            if low.protected(target,mapping,spines,fonts,True): raise ValueError('protected texture')
            raw=low.entry_bytes(src,source[target]); current=low.entry_bytes(base,mainpack[target])
            if low.digest(raw)!=spec['source_sha256'] or low.digest(raw)!=item['source_sha256'] or low.digest(raw,'md5')!=item['source_md5']: raise ValueError('source entry mismatch')
            h=low.texture_header(raw); now=low.parse_texture(current)
            if h!=item['input'] or now!=item.get('output',item['input']) or low.digest(current,'md5')!=item.get('output_md5',item['source_md5']): raise ValueError('main texture mismatch')
            if h['data_format']==2: low.parse_texture(raw)
            elif len(raw)!=52+((h['gpu'][0]+3)//4)*((h['gpu'][1]+3)//4)*windows.BC_BYTES[h['image_format']]: raise ValueError('invalid BC payload')
            rec={'source':spec['source'],'target':'res://'+target,'role':role,'source_sha256':low.digest(raw),'source_md5':low.digest(raw,'md5'),'base_sha256':low.digest(current),'base_md5':low.digest(current,'md5'),'input':h,'base':now}
            records.append(rec);candidates.append((rec,target))
    if not candidates: raise ValueError('no candidates')
    if a.cache.is_symlink(): raise ValueError('cache symlink')
    a.cache.mkdir(parents=True,exist_ok=True); a.output.parent.mkdir(parents=True,exist_ok=True); a.report.parent.mkdir(parents=True,exist_ok=True)
    encoder=low.digest((low.file_hash(a.godot)+low.file_hash(WORKER)).encode()); files=[]
    with tempfile.TemporaryDirectory(prefix='quarter-worker-',dir=a.cache) as tmp, a.source_pck.open('rb') as src:
        tmp=Path(tmp); (tmp/'project.godot').write_text('[application]\nconfig/name="Offline quarter texture"\n')
        for offset in range(0,len(candidates),a.batch_size):
            jobs=[]; pending=[]
            for rec,target in candidates[offset:offset+a.batch_size]:
                key=low.digest((encoder+rec['source_sha256']).encode()); out=a.cache/(key+'.ctex'); qc=a.cache/(key+'.quality.json')
                if qc.exists():
                    q=json.loads(qc.read_text());validate_quality(q,rec['input'])
                    if q['status']=='accepted':
                        data=out.read_bytes();verify_output(data,rec['input'])
                        if q.get('output_sha256')!=low.digest(data): raise ValueError('cache output SHA mismatch')
                else:
                    inp=tmp/(str(len(jobs))+'.ctex'); inp.write_bytes(low.entry_bytes(src,source[target]))
                    jobs.append({'input':str(inp.resolve()),'output':str(out.resolve())});pending.append((rec,out,qc))
            if jobs:
                jf=tmp/'jobs.json';jf.write_text(json.dumps(jobs))
                cmd=[str(a.godot),'--headless','--path',str(tmp.resolve()),'--script',str(WORKER.resolve()),'--',str(jf.resolve())]
                run=subprocess.run(cmd,capture_output=True,text=True,timeout=1800)
                if run.returncode: raise RuntimeError('codec failed: '+run.stdout+'\n'+run.stderr)
                seen=set()
                for line in run.stdout.splitlines():
                    if not line.startswith('QUARTER_RESULT\t'): continue
                    _,num,body=line.split('\t',2); i=int(num)
                    if i in seen or not 0<=i<len(pending): raise ValueError('invalid worker index')
                    rec,out,qc=pending[i];q=json.loads(body);validate_quality(q,rec['input'])
                    if q['status']=='accepted': q['output_sha256']=low.digest(out.read_bytes());verify_output(out.read_bytes(),rec['input'])
                    qc.write_text(json.dumps(q,sort_keys=True)+'\n');seen.add(i)
                if len(seen)!=len(pending): raise ValueError('worker omitted results')
            for rec,target in candidates[offset:offset+a.batch_size]:
                key=low.digest((encoder+rec['source_sha256']).encode());out=a.cache/(key+'.ctex');q=json.loads((a.cache/(key+'.quality.json')).read_text());validate_quality(q,rec['input']);rec['quality']=q
                if q['status']=='accepted':
                    data=out.read_bytes();rec['output']=verify_output(data,rec['input']);rec['output_sha256']=low.digest(data);rec['output_md5']=low.digest(data,'md5')
                    if rec['output_sha256']!=q['output_sha256']: raise ValueError('output SHA mismatch')
                    files.append((target,out))
            print('processed',min(offset+a.batch_size,len(candidates)),'/',len(candidates),flush=True)
        if not files: raise ValueError('no candidates passed quality gate')
        temp=tmp/'delta.pck';low.write_pack(sorted(files),temp); idx=low.read_pack(temp)
        if set(idx)!={x[0] for x in files}: raise ValueError('delta entries mismatch')
        with temp.open('rb') as f:
            expected={r['target'][6:]:r['output_sha256'] for r in records if r['quality']['status']=='accepted'}
            for path in idx:
                if low.digest(low.entry_bytes(f,idx[path]))!=expected[path]: raise ValueError('delta verification failed')
        result={'source_sha256':SOURCE_SHA,'base_main_sha256':MAIN_SHA,'texture_report_sha256':REPORT_SHA,'specs_sha256':SPECS_SHA,'godot_sha256':low.file_hash(a.godot),'godot_version':version,'builder_sha256':low.file_hash(Path(__file__)),'worker_sha256':low.file_hash(WORKER),'delta_sha256':low.file_hash(temp),'profile':PROFILE,'candidate_count':len(records),'accepted_count':len(files),'quality_rejected_count':len(records)-len(files),'resources':records,'limitations':'Sampled quality is not full visual equivalence. Static usage cannot prove dynamic shader safety. Headless loading is not GPU/RSS measurement.'}
        temp.replace(a.output);a.report.write_text(json.dumps(result,indent=2)+'\n')
    print('wrote',len(files),'quarter textures')

if __name__=='__main__':main()
