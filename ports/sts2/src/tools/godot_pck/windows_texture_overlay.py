#!/usr/bin/env python3
# INPUT: audited Windows Godot PCK, Godot 4.5.1 CPU codecs, private cache
# OUTPUT: texture and import replacements plus a source/output-bound report
# POS: convert desktop BC textures for Mali while preserving logical dimensions
import argparse
import hashlib
import json
import re
import struct
import subprocess
import sys
from pathlib import Path
import low_texture_overlay as low

WORKER = Path(__file__).with_name('windows_texture_worker.gd')
BC_BYTES = {17: 8, 19: 16, 22: 16}


def windows_import_map(stream, entries):
    mapping = {}
    spine_dirs = {str(Path(name).parent) for name in entries if name.endswith('.atlas.import')}
    font_dirs = {str(Path(name).parent) for name in entries if name.endswith(('.fnt', '.fnt.import', '.fontdata.import'))}
    imports = {}
    for name, entry in entries.items():
        if not name.endswith('.import'): continue
        raw = low.entry_bytes(stream, entry)
        data = raw.decode('utf-8')
        paths = re.findall(r'^path(?:\.(bptc|s3tc))?="res://(\.godot/imported/[^"\n]+\.ctex)"', data, re.M)
        if not paths: continue
        if len(paths) != 1: raise ValueError('ambiguous texture import: ' + name)
        variant, target = paths[0]
        source = name[:-len('.import')]
        explicit = re.findall(r'^source_file="res://([^"\n]+)"', data, re.M)
        if explicit and explicit != [source]: raise ValueError('texture source_file mismatch: ' + name)
        source_hash = hashlib.md5(('res://' + source).encode('utf-8')).hexdigest()
        expected = '.godot/imported/' + Path(source).name + '-' + source_hash + ('.' + variant if variant else '') + '.ctex'
        if target != expected: raise ValueError('texture import identity mismatch: ' + name)
        if target not in entries or target in mapping: raise ValueError('missing or duplicate imported texture: ' + target)
        mapping[target] = (source, data)
        imports[target] = (name, raw, variant)
    missing = sorted(n for n in entries if n.endswith('.ctex') and n not in mapping)
    if missing: raise ValueError('texture import mapping missing: ' + ', '.join(missing[:5]))
    return mapping, imports, spine_dirs, font_dirs


def rewrite_import(raw, variant, target):
    if variant not in ('bptc', 's3tc'): raise ValueError('unsupported desktop import variant')
    data = raw.decode('utf-8')
    old = f'path.{variant}="res://{target}"'
    if data.count(old) != 1 or re.search(r'^path\.astc=', data, re.M):
        raise ValueError('unexpected desktop texture import path')
    data = data.replace(old, f'path.astc="res://{target}"', 1)
    pattern = r'("imported_formats"\s*:\s*)\["s3tc_bptc",\s*"etc2_astc"\]'
    data, count = re.subn(pattern, r'\1["etc2_astc"]', data)
    if count != 1: raise ValueError('unexpected texture imported_formats metadata')
    return data.encode('utf-8')


def verify_output(data, info, scale, output_format):
    out = low.texture_header(data)
    expected = [max(1, n // scale) for n in info['gpu']]
    if (out['logical'] != info['logical'] or out['gpu'] != expected or
        out['flags'] != info['flags'] or out['limit'] != info['limit'] or
        out['data_format'] != info['data_format'] or out['mipmaps'] != (info['mipmaps'] - 1 if info['mipmaps'] > 1 else 0) or
        out['image_format'] != output_format):
        raise ValueError('converted texture header mismatch')
    if out['data_format'] == 0 and output_format == 5:
        if len(data) != 52 + expected[0] * expected[1] * 4: raise ValueError('invalid RGBA texture length')
    else:
        low.parse_texture(data)
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('base','godot','cache','output','report'): parser.add_argument('--'+name, type=Path, required=True)
    parser.add_argument('--expected-source-sha256', required=True)
    parser.add_argument('--allow-spine-half', action='store_true', help='accept unverified installed Spine binary identity')
    parser.add_argument('--batch-size', type=int, default=256)
    args = parser.parse_args()
    if not re.fullmatch('[0-9a-f]{64}', args.expected_source_sha256) or args.batch_size < 1: raise ValueError('invalid source SHA or batch size')
    temp = args.output.with_name(args.output.name + '.tmp')
    low.ensure_distinct_paths((args.base, args.output, args.report, temp))
    if args.output.exists() or args.report.exists() or temp.exists(): raise ValueError('output/report/temp already exists')
    version = subprocess.run([str(args.godot), '--version'], capture_output=True, text=True, check=True).stdout.strip()
    if not version.startswith('4.5.1.stable.official'): raise ValueError('official Godot 4.5.1 required')
    source_sha = low.file_hash(args.base)
    if source_sha != args.expected_source_sha256: raise ValueError('source PCK SHA mismatch')
    encoder = low.digest((low.file_hash(args.godot)+low.file_hash(WORKER)+low.file_hash(low.WORKER)+low.file_hash(Path(__file__))).encode())
    args.cache.mkdir(parents=True, exist_ok=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    entries = low.read_pack(args.base); records=[]; jobs=[]; items=[]; imports_out={}; pending=set()
    with args.base.open('rb') as stream:
        mapping, imports, spine_dirs, font_dirs = windows_import_map(stream, entries)
        names=sorted(mapping)
        for index, name in enumerate(names, 1):
            raw=low.entry_bytes(stream,entries[name]); info=low.texture_header(raw)
            record={'path':name,'kind':'texture','source_md5':entries[name][2], 'source_sha256':low.digest(raw),'input':info,'source_path':mapping[name][0]}
            reason=low.protected(name,mapping,spine_dirs,font_dirs,args.allow_spine_half)
            if info['data_format']==0 and info['image_format']==15:
                record['skip_reason']='HDR/data texture retained'; records.append(record); continue
            if info['data_format']==0 and info['image_format'] in BC_BYTES:
                if info['mipmaps'] != 0: raise ValueError('unsupported Windows BC mip chain: '+name)
                width,height=info['gpu']; block=BC_BYTES[info['image_format']]
                if len(raw)!=52+((width+3)//4)*((height+3)//4)*block: raise ValueError('invalid BC length: '+name)
                scale=1 if reason else 2; output_format=5 if reason else 37
                import_name, original_import, variant=imports[name]
                rewritten=rewrite_import(original_import,variant,name)
                imports_out[import_name]=(original_import,rewritten)
                worker=WORKER; mode={'halve':scale==2,'astc':output_format==37}
                record['strategy']='BC decode to full-size RGBA for protected data' if reason else 'BC decode to half-size ASTC 8x8'
            elif info['data_format']==2:
                low.parse_texture(raw)
                if reason or info['gpu']==[1,1] or info['mipmaps']==1:
                    record['skip_reason']=reason or ('already 1x1' if info['gpu']==[1,1] else 'tiny mip chain retained');records.append(record);continue
                scale=2;output_format=info['image_format'];worker=low.WORKER;mode={}
                record['strategy']='drop highest WebP mip' if info['mipmaps']>1 else 'WebP CPU decode and half-size resize'
            else: raise ValueError('unsupported source texture format: '+name)
            key=low.digest((encoder+record['source_sha256']+str(scale)+str(output_format)).encode())
            src=args.cache/(key+'.source.ctex');dst=args.cache/(key+'.ctex');checksum=args.cache/(key+'.sha256')
            if dst.exists() and checksum.exists():
                result=dst.read_bytes()
                if low.digest(result)!=checksum.read_text().strip(): raise ValueError('cached result checksum mismatch')
                verify_output(result,info,scale,output_format)
            elif info['data_format']==2 and info['mipmaps']>1:
                top=4+struct.unpack_from('<I',raw,52)[0];reduced=bytearray(raw[:52]+raw[52+top:])
                struct.pack_into('<HHI',reduced,40,max(1,info['gpu'][0]//2),max(1,info['gpu'][1]//2),info['mipmaps']-1)
                verify_output(reduced,info,scale,output_format);dst.write_bytes(reduced);checksum.write_text(low.digest(reduced)+'\n')
            elif key not in pending:
                src.write_bytes(raw)
                jobs.append({'name':name,'input':str(src.resolve()),'output':str((args.cache/(key+'.pending.ctex')).resolve()),'final':str(dst.resolve()),'checksum':str(checksum.resolve()),'worker':str(worker.resolve()),**mode})
                pending.add(key)
            record.update({'cache':str(dst),'scale':scale,'output_format':output_format})
            if reason:record['protected_reason']=reason
            records.append(record);items.append((name,dst))
            if index%256==0 or index==len(names): print(f'scanned {index}/{len(names)} textures',flush=True)
    for worker in (WORKER.resolve(), low.WORKER.resolve()):
        selected=[j for j in jobs if j['worker']==str(worker)]
        for offset in range(0,len(selected),args.batch_size):
            batch=selected[offset:offset+args.batch_size];jobfile=args.cache/'windows-jobs.json';jobfile.write_text(json.dumps(batch),encoding='utf-8')
            command=[str(args.godot),'--headless','--path',str(args.cache.resolve()),'--script',str(worker),'--',str(jobfile.resolve())]
            completed=set()
            with subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1) as process:
                for line in process.stdout:
                    if not line.startswith('TEXTURE_DONE\t'):
                        print(line,end='',flush=True);continue
                    fields=line.strip().split('\t');i=int(fields[1])
                    if i<0 or i>=len(batch) or i in completed: raise ValueError('invalid worker completion')
                    job=batch[i];pending=Path(job['output']);data=pending.read_bytes()
                    pending.replace(job['final']);Path(job['checksum']).write_text(low.digest(data)+'\n');completed.add(i)
                if process.wait() or len(completed)!=len(batch): raise ValueError('Godot worker failed or omitted jobs')
            print(f'converted {min(offset+len(batch),len(selected))}/{len(selected)} with {worker.name}',flush=True)
    for record in records:
        if 'cache' not in record:continue
        data=Path(record.pop('cache')).read_bytes()
        record['output']=verify_output(data,record['input'],record['scale'],record['output_format'])
        record['output_md5']=low.digest(data,'md5')
    for name,(original,data) in sorted(imports_out.items()):
        out=args.cache/(low.digest(data)+'.import');out.write_bytes(data);items.append((name,out))
        records.append({'path':name,'kind':'import','source_md5':low.digest(original,'md5'),'output_md5':low.digest(data,'md5')})
    if not items:raise ValueError('no convertible textures')
    directory=low.write_pack(sorted(items),temp); packed=low.read_pack(temp)
    if set(packed)!=set(directory):raise ValueError('overlay directory mismatch')
    with temp.open('rb') as stream:
        for name,entry in packed.items():
            low.entry_bytes(stream,entry)
            if entry[2]!=directory[name]:raise ValueError('overlay entry checksum mismatch')
    temp.replace(args.output)
    report={'source_sha256':source_sha,'output_sha256':low.file_hash(args.output),'godot':version,'encoder_sha256':encoder,
            'verified_spine_loader':args.allow_spine_half,'texture_count':len(names),'converted_count':len(items)-len(imports_out),
            'import_replacements':len(imports_out),'resources':records}
    args.report.write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
    print(f'Wrote {args.output}: {report["converted_count"]} textures, {len(imports_out)} imports',flush=True)


if __name__=='__main__':
    try:main()
    except (OSError,ValueError,KeyError,TypeError,UnicodeError,subprocess.CalledProcessError) as exc:
        print('Windows texture build failed: '+str(exc),file=sys.stderr);sys.exit(1)
