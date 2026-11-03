#!/usr/bin/env python3
# INPUT: verified pure-Python FontTools wheel and two SHA-bound original font vectors
# OUTPUT: deterministic Mono subset and exact Unicode/advance partition evidence
# POS: offline unprivileged container worker; font bytes remain private
import hashlib
import json
import sys
import unicodedata
from pathlib import Path

WHEEL_SHA='73cf92eeda67cf6ff10c8af56fc8f4f07c1647d989a979be9e388a49be26552a'
MONO_SHA='2b1dbdc50df666a00c50ecd77377e2394c6babd35a71e37505ab411ff55c7906'
MEDIUM_SHA='210dc788c6cc15ed693c8ecde93ee83bf7714b759befa6aead042d6f6e1b878a'
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()

def can_delegate(cp,glyphs,medium_glyph,mono_metrics,medium_metrics,mono_units,medium_units,variation_bases):
 cjk=unicodedata.name(chr(cp),'').startswith(('CJK UNIFIED IDEOGRAPH-','CJK COMPATIBILITY IDEOGRAPH-'))
 return bool(cjk and medium_glyph is not None and cp not in variation_bases and glyphs and
  all(mono_metrics[g][0]*medium_units==medium_metrics[medium_glyph][0]*mono_units for g in glyphs))

def main():
 wheel,mono,medium,out,report=map(Path,sys.argv[1:])
 if [sha(p) for p in (wheel,mono,medium)]!=[WHEEL_SHA,MONO_SHA,MEDIUM_SHA]:raise ValueError('font or wheel identity mismatch')
 sys.path.insert(0,str(wheel))
 from fontTools import __version__,subset
 from fontTools.ttLib import TTFont
 if __version__!='4.60.2':raise ValueError('unexpected fontTools version')
 m=TTFont(mono,recalcTimestamp=False);s=TTFont(medium,recalcTimestamp=False)
 best=m.getBestCmap();other=s.getBestCmap();unit=m['head'].unitsPerEm;unit2=s['head'].unitsPerEm
 # All cmap entries and variation-sequence bases that cannot be safely replaced remain in Mono.
 unicode_tables=[t for t in m['cmap'].tables if t.isUnicode() and t.format!=14]
 all_cmap=set().union(*(set(t.cmap) for t in unicode_tables));vary=set()
 for table in m['cmap'].tables:
  if table.format==14:
   for seq in table.uvsDict.values():vary.update(cp for cp,glyph in seq)
 keep=set();delegated=set()
 for cp in all_cmap:
  matches=[t.cmap[cp] for t in unicode_tables if cp in t.cmap]
  target=other.get(cp) if cp in best else None
  if can_delegate(cp,matches,target,m['hmtx'],s['hmtx'],unit,unit2,vary):delegated.add(cp)
  else:keep.add(cp)
 original={cp:m['hmtx'][g] for cp,g in best.items() if cp in keep}
 opts=subset.Options();opts.layout_features=['*'];opts.name_IDs=['*'];opts.name_legacy=True;opts.name_languages=['*'];opts.notdef_outline=True;opts.recommended_glyphs=True
 tool=subset.Subsetter(options=opts);tool.populate(unicodes=keep);tool.subset(m)
 m['head'].modified=0;m.recalcTimestamp=False;m.save(out,reorderTables=True)
 result=TTFont(out,recalcTimestamp=False);new=result.getBestCmap()
 if set(new)!=set(best)&keep or any(result['hmtx'][new[cp]]!=v for cp,v in original.items()):raise ValueError('retained cmap or metrics changed')
 for t in result['cmap'].tables:
  if t.isUnicode() and t.format!=14 and any(cp not in keep for cp in t.cmap):raise ValueError('unexpected cmap output')
 if not all(cp in other for cp in delegated) or set(keep)|set(delegated)!=all_cmap:raise ValueError('incomplete cmap partition')
 result_report={'fonttools_version':__version__,'wheel_sha256':WHEEL_SHA,'unicode_version':unicodedata.unidata_version,
  'mono_sha256':MONO_SHA,'medium_sha256':MEDIUM_SHA,'subset_sha256':sha(out),'subset_bytes':out.stat().st_size,
  'unicode_cmap_count':len(all_cmap),'best_cmap_count':len(best),'retained':len(keep),'delegated':len(delegated),
  'variation_bases_retained':len(vary&all_cmap),'fixed_head_modified':0,'units_per_em':[unit,unit2],
  'limitations':['Advance and codepoint coverage are not proof of identical outlines, GSUB/GPOS shaping, vertical layout, or device RSS.']}
 report.write_text(json.dumps(result_report,indent=2)+'\n');print(json.dumps(result_report))
if __name__=='__main__':main()
