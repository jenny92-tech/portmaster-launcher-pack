#!/usr/bin/env python3
# INPUT: exact 9caf game pack and a fresh private output path
# OUTPUT: en/zhs codepoint sets and bounded representative strings for atlas fixture
# POS: offline metadata extraction; private game text stays outside the repository
import argparse
import json
import unicodedata
from pathlib import Path
import low_texture_overlay as low

BASE='9caf3fa8448a7729dc11fa4897b9756e30fcdeadb56acbdb1cba9acc3e7b6fad'
def collect(value,out):
 if isinstance(value,str):out.append(value)
 elif isinstance(value,dict):
  for x in value.values():collect(x,out)
 elif isinstance(value,list):
  for x in value:collect(x,out)
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--pack',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
 if a.pack.is_symlink() or a.output.exists() or a.output.is_symlink() or low.file_hash(a.pack)!=BASE:raise ValueError('unexpected corpus input or output')
 entries=low.read_pack(a.pack);values={'zhs':[],'eng':[]};points={'zhs':set(),'eng':set()};samples=[]
 with a.pack.open('rb') as stream:
  for lang in values:
   files=sorted(x for x in entries if x.startswith('localization/'+lang+'/') and x.endswith('.json'))
   if len(files)!=46:raise ValueError('unexpected locale file count')
   for name in files:
    found=[];collect(json.loads(low.entry_bytes(stream,entries[name]).decode('utf-8-sig')),found);values[lang]+=found
    for s in found:points[lang].update(ord(x) for x in s)
    if name.endswith(('cards.json','main_menu_ui.json','combat_messages.json','settings_ui.json')):
     selected=[x for x in found if 12<=len(x)<=110 and '\n' not in x and '[' not in x and '{' not in x and '}' not in x]
     selected.sort(key=lambda x:(-len(x),x))
     samples.extend({'lang':lang,'category':name.rsplit('/',1)[-1],'text':x} for x in selected[:3])
 for lang in points:points[lang]=sorted(x for x in points[lang] if unicodedata.category(chr(x)) not in ('Cc','Cf'))
 if len(points['zhs'])!=2493 or len(points['eng'])!=104:raise ValueError('unexpected locale corpus')
 a.output.write_text(json.dumps({'codepoints':points,'samples':samples},ensure_ascii=False))
 print(json.dumps({'zhs_codepoints':len(points['zhs']),'eng_codepoints':len(points['eng']),'sample_count':len(samples)}))
if __name__=='__main__':main()
