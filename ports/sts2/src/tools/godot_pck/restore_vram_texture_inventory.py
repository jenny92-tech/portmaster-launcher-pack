#!/usr/bin/env python3
# INPUT: audited old/new player PCKs and the new source-bound texture report
# OUTPUT: metadata-only candidate/retention identities; no original assets
# POS: explicitly audits old effective import, byte-identical source and visual role
import argparse
import hashlib
import json
import re
from pathlib import Path
import low_texture_overlay as low
import windows_texture_overlay as windows
from scan_memory_candidates import spine_atlas_pages

OLD_SHA = 'd220c699aa60eeb22e22aebf9e34a3f7f350b58427c979ad2ccd75c25750b528'
NEW_SHA = 'f526ef85cd5b7cf653defb545a8ba22196c72e6a0e95ad66f78f2f3a168b28c9'
SENSITIVE = re.compile(r'font|glyph|charset|sdf|lut|lookup|normal|roughness|metal|height|displace|occlusion|noise|mask|gradient|curve|ramp|distort|erosion|flow|vector|depth|palette|channel|data', re.I)
EXT = re.compile(rb'(?m)^\[ext_resource\b[^\r\n]*\]')
FIELD = re.compile(rb'(?ms)^([\w/.-]+)\s*=\s*(.*?)(?=^[\w/.-]+\s*=|^\[|\Z)')

def usage_metadata(stream, entries, candidates):
    usage = {x:set() for x in candidates}
    for name in sorted(entries):
        if not name.endswith(('.tscn', '.tres')): continue
        data = low.entry_bytes(stream, entries[name])
        ext = {}
        for match in EXT.finditer(data):
            header=match.group()
            path=re.search(rb'\bpath="res://([^"\r\n]+)"',header)
            ident=re.search(rb'\bid="([^"\r\n]+)"',header)
            if path and ident and path.group(1).decode('utf8') in usage:
                ext[ident.group(1)] = path.group(1).decode('utf8')
        if not ext: continue
        for field in FIELD.finditer(data):
            for ident in re.findall(rb'ExtResource\("([^"\r\n]+)"\)',field.group(2)):
                if ident in ext: usage[ext[ident]].add(field.group(1).decode('utf8'))
    return usage

def build(old, new, report):
    if low.file_hash(old)!=OLD_SHA or low.file_hash(new)!=NEW_SHA or report.get('source_sha256')!=NEW_SHA:
        raise ValueError('unaudited input PCK or texture report identity')
    if not re.fullmatch(r'[0-9a-f]{64}',report.get('output_sha256','')): raise ValueError('invalid texture overlay hash')
    oi=low.read_pack(old);ni=low.read_pack(new)
    texture_records=[r for r in report['resources'] if r.get('kind')=='texture']
    records={r['path']:r for r in texture_records}
    if len(records)!=len(texture_records):raise ValueError('duplicate texture report paths')
    result=[]
    with old.open('rb') as of,new.open('rb') as nf:
        mapping,_,spines,fonts=windows.windows_import_map(nf,ni)
        if set(mapping)!=set(records):raise ValueError('texture report and import mapping differ')
        pages=set()
        for atlas in ni:
            if atlas.endswith('.atlas.import'):
                paths=spine_atlas_pages(atlas[:-7],ni,nf)
                if paths is None: raise ValueError('unknown spine atlas import: '+atlas)
                pages.update(paths)
        usage=usage_metadata(nf,ni,{v[0] for v in mapping.values()})
        for target,(source,_) in sorted(mapping.items()):
            rec=records[target]
            if rec['source_path']!=source:raise ValueError('source mapping mismatch')
            source_sha=hashlib.sha256(low.entry_bytes(nf,ni[target])).hexdigest()
            if source_sha != rec['source_sha256']: raise ValueError('source texture hash mismatch: '+source)
            reasons=[];old_path=None;old_sha=None;old_import_sha=None;old_sibling_sha=None
            if source+'.import' not in oi: reasons.append('no old source import')
            else:
                raw=low.entry_bytes(of,oi[source+'.import']);old_import_sha=hashlib.sha256(raw).hexdigest()
                text=raw.decode('utf8').rstrip('\0')
                source_fields=re.findall(r'^source_file="res://([^"\n]+)"',text,re.M)
                matches=re.findall(r'^path\.astc="res://([^"\n]+\.astc\.ctex)"',text,re.M)
                if source_fields!=[source] or len(matches)!=1 or not re.search(r'"vram_texture"\s*:\s*true',text) or not re.search(r'^compress/mode=2\s*$',text,re.M):
                    reasons.append('old import does not explicitly select ASTC VRAM compression')
                else:
                    old_path=matches[0]
                    if old_path not in oi:raise ValueError('old ASTC import target missing')
                    blob=low.entry_bytes(of,oi[old_path]);h=low.texture_header(blob);old_sha=hashlib.sha256(blob).hexdigest()
                    if (h['data_format'],h['image_format'])!=(0,37):reasons.append('old selected texture is not ASTC8x8')
                    sibling=old_path[:-len('.astc.ctex')]+'.ctex'
                    if sibling not in oi or oi[sibling][2]!=ni[target][2]:reasons.append('old sibling and new source not byte-identical')
                    else:
                        old_sibling_sha=hashlib.sha256(low.entry_bytes(of,oi[sibling])).hexdigest()
                        if old_sibling_sha != source_sha:raise ValueError('source and old sibling SHA-256 disagree')
            if low.protected(target,mapping,spines,fonts,True):reasons.append('protected font, LUT, normal or data texture')
            if SENSITIVE.search(source):reasons.append('sensitive data, mask, noise or font name')
            used=usage[source]
            if any(field.startswith('shader_parameter/') for field in used):reasons.append('referenced as a shader parameter')
            if any(field not in ('texture','_frames') and not field.startswith('shader_parameter/') for field in used):reasons.append('unknown or non-visual direct dependency')
            role = 'card_portrait' if source.startswith('images/packed/card_portraits/') else 'spine_atlas_page' if source in pages else 'visual_vfx_texture' if source.startswith('images/vfx/') and used and used.issubset({'texture','_frames'}) else None
            if role is None:reasons.append('visual role or usage not statically established')
            out=rec.get('output',rec['input'])
            if out['data_format']!=2 or out['image_format'] not in (4,5) or out['mipmaps']!=0:reasons.append('not RGB/RGBA single-level installed WebP')
            result.append({'source':'res://'+source,'target':'res://'+target,'source_md5':ni[target][2], 'source_sha256':source_sha, 'old_sibling_sha256':old_sibling_sha,
              'installed_md5':rec.get('output_md5'), 'old_selected':'res://'+old_path if old_path else None,
              'old_selected_sha256':old_sha,'old_import_sha256':old_import_sha,'role':role,
              'direct_fields':sorted(used),'input':out,'eligible':not reasons,'retained_reasons':reasons})
    return {'old_pck_sha256':OLD_SHA,'source_pck_sha256':NEW_SHA,'texture_overlay_sha256':report['output_sha256'],
      'scope':'explicit old ASTC import and byte-identical new source; static role and data exclusions, not a runtime or visual safety guarantee','resources':result}

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for key in ('old-pck','source-pck','texture-report','output'):p.add_argument('--'+key,type=Path,required=True)
    a=p.parse_args();low.ensure_distinct_paths((a.old_pck,a.source_pck,a.texture_report,a.output))
    if a.output.exists() or a.output.is_symlink():raise ValueError('output already exists')
    obj=build(a.old_pck,a.source_pck,json.loads(a.texture_report.read_text()))
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(obj,indent=2)+'\n')
    print('eligible',sum(x['eligible'] for x in obj['resources']),'of',len(obj['resources']))
if __name__=='__main__':main()
