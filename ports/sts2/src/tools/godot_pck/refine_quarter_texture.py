#!/usr/bin/env python3
# INPUT: pinned source, quarter parent, audited reports, Godot and ARM astcenc sources
# OUTPUT: independent smaller quality-checked texture delta and per-attempt report
# POS: offline optional refinement; never modifies the earlier profile or installed pack
"""Refine rejected visual textures without changing the existing quarter profile."""
import argparse
import json
import math
import platform
import struct
import subprocess
import tempfile
from pathlib import Path
import low_texture_overlay as low
import quarter_texture_overlay as quarter
import windows_texture_overlay as windows

SOURCE_SHA=quarter.SOURCE_SHA
MAIN_SHA='7ec4bb3f96fd01dc42bde20b6daa2f98cd16f09cec3b8ef404efd53f089615f1'
DELTA_SHA='49dc4dcb42e4fceb74e74d340e8bdfa5a0bec1c8d132fb1ee570d78521620c09'
PREVIOUS_REPORT_SHA='098e3a99f952c2f426df32586d403c260e8f0c4d46396cc7ce2e45c7cd1f75f0'
ASTC_SOURCE_SHA='fffcbfd78efea6cf1fd963ee088cc9c5e5e0810a1be451993d8ee2d2be7c72fc'
WORKER=Path(__file__).with_suffix('.gd')
ENCODER=Path(__file__).with_name('refine_quarter_astc.cpp')
UI_PATHS={'res://images/timeline/epoch_portraits/ironclad2_epoch.png','res://images/ui/reward_screen/reward_banner.png','res://images/potions/potion_pop_up/potion_popup.png','res://images/ui/combat/energy_star_flash_glow.png'}
ROLES={'spine_atlas_page','room','visual_vfx_texture'}
MODES=[(8,60),(8,98),(4,60),(4,98)]

def source_identity(path):
    files=sorted([*path.glob('*.cpp'),*path.glob('*.h')])
    if len(files)!=34 or len(list(path.glob('*.cpp')))!=22: raise ValueError('unexpected astcenc source list')
    import hashlib
    h=hashlib.sha256()
    for f in files: h.update(f.name.encode()+b'\0'+bytes.fromhex(low.file_hash(f)))
    return h.hexdigest()

def nominal(header):
    w,h=header['gpu']; dtype=header['data_format']; fmt=header['image_format']
    if dtype==2 and fmt in (4,5): return w*h*(3 if fmt==4 else 4)
    if dtype==0 and fmt in (35,37):
        b=4 if fmt==35 else 8
        return ((w+b-1)//b)*((h+b-1)//b)*16
    raise ValueError('unsupported current texture')

def candidate_records(previous, texture_report, specs):
    s={x['target'][6:]:x for x in specs['resources']}; t={x['path']:x for x in texture_report['resources'] if x.get('kind')=='texture'}
    if len(s)!=len(specs['resources']) or len(t)!=sum(x.get('kind')=='texture' for x in texture_report['resources']): raise ValueError('duplicate inventory')
    selected=[]
    for old in previous['resources']:
        if old['role'] not in ROLES or old['quality']['status']!='quality_rejected':continue
        path=old['target'][6:]; spec=s[path]; item=t[path]
        if quarter.classify(spec,item)!=old['role']:raise ValueError('prior candidate no longer matches audited policy')
        selected.append((old['source'],path,old['role'],4,old))
    for source in sorted(UI_PATHS):
        matches=[(path,item) for path,item in t.items() if 'res://'+item['source_path']==source]
        if len(matches)!=1:raise ValueError('missing or ambiguous UI texture')
        path,item=matches[0];spec=s[path]
        if spec['source']!=source or set(spec['direct_fields'])!={'texture'} or any(x in quarter.PROTECTED or x=='unknown or non-visual direct dependency' for x in spec['retained_reasons']):raise ValueError('unsafe UI texture')
        selected.append((source,path,'ui_visual',2,None))
    if len({x[1] for x in selected})!=len(selected):raise ValueError('duplicate target')
    return selected,t,s

def quality(src,decoded,w,h,pw):
    step=max(1,math.ceil(math.sqrt(w*h/16384.0))); alpha=[];rgb=[]
    for y in range(step//2,h,step):
        for x in range(step//2,w,step):
            a=(y*w+x)*4;b=(y*pw+x)*4
            alpha.append(abs(src[a+3]-decoded[b+3])/255.0)
            if src[a+3]>12.75:rgb.append(sum(abs(src[a+c]-decoded[b+c]) for c in range(3))/765.0)
    alpha.sort();rgb.sort()
    q={'alpha_p99':alpha[int((len(alpha)-1)*.99)],'alpha_max':alpha[-1], 'visible_rgb_p99':rgb[int((len(rgb)-1)*.99)] if rgb else 0.0,'sample_step':step,'sample_count':len(alpha),'visible_samples':len(rgb),'limits':quarter.LIMITS}
    q['status']='accepted' if all(q[k]<=v for k,v in quarter.LIMITS.items()) else 'quality_rejected'
    quarter.validate_quality(q,{'gpu':[w*4,h*4]})
    return q

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for k in ('source-pck','base-main','previous-delta','previous-report','texture-report','godot','astcenc-dir','compiler','cache','output','report'):p.add_argument('--'+k,type=Path,required=True)
    a=p.parse_args()
    low.ensure_distinct_paths((a.source_pck,a.base_main,a.previous_delta,a.previous_report,a.texture_report,a.output,a.report))
    if a.output.exists() or a.report.exists() or a.output.is_symlink() or a.report.is_symlink() or a.cache.is_symlink():raise ValueError('fresh output and safe cache required')
    for path,expected in ((a.source_pck,SOURCE_SHA),(a.base_main,MAIN_SHA),(a.previous_delta,DELTA_SHA),(a.previous_report,PREVIOUS_REPORT_SHA),(a.texture_report,quarter.REPORT_SHA),(quarter.SPECS,quarter.SPECS_SHA)):
        if low.file_hash(path)!=expected:raise ValueError('input identity mismatch: '+str(path))
    if source_identity(a.astcenc_dir)!=ASTC_SOURCE_SHA:raise ValueError('unrecognized astcenc sources')
    if platform.machine() not in ('arm64','aarch64'):raise ValueError('this audited helper requires ARM64 NEON')
    version=subprocess.run([str(a.godot),'--version'],capture_output=True,text=True,check=True).stdout.strip()
    if not version.startswith('4.5.1.stable.official'):raise ValueError('unexpected Godot')
    previous=json.loads(a.previous_report.read_text()); report=json.loads(a.texture_report.read_text());specs=json.loads(quarter.SPECS.read_text())
    if previous['delta_sha256']!=DELTA_SHA or previous['base_main_sha256']!=quarter.MAIN_SHA or previous['source_sha256']!=SOURCE_SHA:raise ValueError('previous chain mismatch')
    candidates,textures,sm=candidate_records(previous,report,specs)
    original=low.read_pack(a.source_pck);parent=low.read_pack(a.base_main);old_delta=low.read_pack(a.previous_delta)
    if set(old_delta)!={r['target'][6:] for r in previous['resources'] if r['quality']['status']=='accepted'}:raise ValueError('previous delta closed set mismatch')
    a.cache.mkdir(parents=True,exist_ok=True);a.cache=a.cache.resolve();a.output.parent.mkdir(parents=True,exist_ok=True);a.report.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='refine-quarter-',dir=a.cache) as t, a.source_pck.open('rb') as src, a.base_main.open('rb') as base:
        tmp=Path(t);(tmp/'project.godot').write_text('[application]\nconfig/name="Offline texture refinement"\n')
        exe=tmp/'astc-helper';cpp=sorted(a.astcenc_dir.glob('*.cpp'))
        command=[str(a.compiler),'-O2','-std=c++17','-DASTCENC_NEON=1','-I',str(a.astcenc_dir.resolve()),str(ENCODER.resolve()),*[str(x.resolve()) for x in cpp],'-o',str(exe)]
        subprocess.run(command,check=True,capture_output=True,text=True,timeout=300)
        records=[];out_files=[]
        for offset in range(0,len(candidates),16):
            batch=candidates[offset:offset+16];jobs=[];temporary=[]
            for i,(name,path,role,scale,old) in enumerate(batch):
                item=textures[path];spec=sm[path]
                if path in old_delta or path not in original or path not in parent:raise ValueError('target missing or already replaced')
                raw=low.entry_bytes(src,original[path]);current=low.entry_bytes(base,parent[path]);ih=low.texture_header(raw);bh=low.parse_texture(current)
                if low.digest(raw)!=item['source_sha256'] or low.digest(raw)!=spec['source_sha256'] or ih!=item['input'] or bh!=item.get('output',item['input']) or low.digest(current,'md5')!=item.get('output_md5',item['source_md5']):raise ValueError('entry identity mismatch')
                if old and low.digest(current)!=old['base_sha256']:raise ValueError('prior parent entry mismatch')
                if ih['mipmaps'] or bh['mipmaps']:raise ValueError('unexpected mip chain')
                if ih['data_format']==2:low.parse_texture(raw)
                elif ih['data_format']==0 and ih['image_format'] in windows.BC_BYTES:
                    w,h=ih['gpu']
                    if len(raw)!=52+((w+3)//4)*((h+3)//4)*windows.BC_BYTES[ih['image_format']]:raise ValueError('invalid BC data')
                else:raise ValueError('unsupported original texture')
                w,h=(max(1,n//scale) for n in ih['gpu'])
                if scale==2 and [w,h]!=bh['gpu']:raise ValueError('UI physical size mismatch')
                inp=tmp/(str(i)+'.ctex');rgba=tmp/(str(i)+'.rgba');inp.write_bytes(raw)
                jobs.append({'input':str(inp),'output':str(rgba),'width':w,'height':h})
                rec={'source':name,'target':'res://'+path,'role':role,'source_sha256':low.digest(raw),'source_md5':low.digest(raw,'md5'),'base_sha256':low.digest(current),'base_md5':low.digest(current,'md5'),'input':ih,'base':bh,'base_nominal_bytes':nominal(bh),'scale_denominator':scale,'attempts':[]}
                records.append(rec);temporary.append((rec,raw,rgba,w,h,path))
            jf=tmp/'jobs.json';jf.write_text(json.dumps(jobs))
            run=subprocess.run([str(a.godot),'--headless','--path',str(tmp),'--script',str(WORKER.resolve()),'--',str(jf)],capture_output=True,text=True,timeout=600)
            if run.returncode or sum(x.startswith('REFINE_DECODED\t') for x in run.stdout.splitlines())!=len(jobs):raise RuntimeError('Godot decode failed: '+run.stdout+run.stderr)
            for rec,raw,rgba,w,h,path in temporary:
                source_pixels=rgba.read_bytes()
                if len(source_pixels)!=w*h*4:raise ValueError('invalid RGBA size')
                chosen=None
                for block,preset in MODES:
                    payload_size=((w+block-1)//block)*((h+block-1)//block)*16
                    # Avoid zero/insignificant savings and avoid replacing half-size ASTC8 with same-size quarter ASTC4.
                    if payload_size*100>=rec['base_nominal_bytes']*95:continue
                    compressed=tmp/'encoded.astc';decoded=tmp/'decoded.rgba'
                    result=subprocess.run([str(exe),str(rgba),str(w),str(h),str(block),str(preset),'4','1',str(compressed),str(decoded)],capture_output=True,text=True,timeout=600)
                    if result.returncode:raise RuntimeError('ASTC encoder failed: '+result.stderr)
                    pw,ph,n=(int(x) for x in result.stdout.split())
                    encoded=compressed.read_bytes();pixels=decoded.read_bytes()
                    if (pw,ph,n)!=(((w+block-1)//block)*block,((h+block-1)//block)*block,payload_size) or len(encoded)!=n or len(pixels)!=pw*ph*4:raise ValueError('invalid encoder payload')
                    q=quality(source_pixels,pixels,w,h,pw);attempt={'block':block,'preset':preset,'alpha_weight':4,'alpha_weight_flag':True,'payload_bytes':n,'quality':q};rec['attempts'].append(attempt)
                    if q['status']=='accepted':chosen=(block,encoded,attempt);break
                if chosen:
                    block,encoded,attempt=chosen;out=bytearray(raw[:52]);struct.pack_into('<IHHII',out,36,0,w,h,0,37 if block==8 else 35);out.extend(encoded)
                    parsed=low.parse_texture(out)
                    if parsed['logical']!=rec['input']['logical'] or any(parsed[k]!=rec['input'][k] for k in ('flags','limit')):raise ValueError('header changed')
                    data=bytes(out);op=a.cache/(low.digest(data)+'.ctex');op.write_bytes(data)
                    rec.update({'status':'accepted','output':parsed,'output_nominal_bytes':len(encoded),'output_sha256':low.digest(data),'output_md5':low.digest(data,'md5'),'selected':attempt,'reason':'smallest supported payload passing fixed quality and savings gates'})
                    out_files.append((path,op))
                else:rec.update({'status':'quality_rejected','reason':'no smaller supported format passed fixed quality gate'})
            print('processed',min(offset+16,len(candidates)),'/',len(candidates),flush=True)
        if not out_files:raise ValueError('no eligible outputs')
        op=tmp/'delta.pck';low.write_pack(sorted(out_files),op);idx=low.read_pack(op)
        expected={x['target'][6:]:x['output_sha256'] for x in records if x['status']=='accepted'}
        if set(idx)!=set(expected):raise ValueError('delta closed set mismatch')
        with op.open('rb') as f:
            for path in idx:
                if low.digest(low.entry_bytes(f,idx[path]))!=expected[path]:raise ValueError('delta entry mismatch')
        data={'source_sha256':SOURCE_SHA,'base_main_sha256':MAIN_SHA,'previous_delta_sha256':DELTA_SHA,'previous_report_sha256':PREVIOUS_REPORT_SHA,'texture_report_sha256':quarter.REPORT_SHA,'specs_sha256':quarter.SPECS_SHA,'astc_source_sha256':ASTC_SOURCE_SHA,'godot_sha256':low.file_hash(a.godot),'compiler_sha256':low.file_hash(a.compiler),'builder_sha256':low.file_hash(Path(__file__)),'worker_sha256':low.file_hash(WORKER),'encoder_source_sha256':low.file_hash(ENCODER),'encoder_binary_sha256':low.file_hash(exe),'compiler_command':command[:-1]+['<private-output>'],'godot_version':version,'delta_sha256':low.file_hash(op),'candidate_count':len(records),'accepted_count':len(out_files),'rejected_count':len(records)-len(out_files),'resources':records,'limitations':'CPU sampled quality; dynamic shader use, target GPU rendering, actual memory and atlas bleed are not verified.'}
        op.replace(a.output);a.report.write_text(json.dumps(data,indent=2)+'\n')
    print('wrote',len(out_files),'refined textures')

if __name__=='__main__':main()
