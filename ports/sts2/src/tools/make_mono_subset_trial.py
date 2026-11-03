#!/usr/bin/env python3
# INPUT: reviewed font-budget trial and fixed 9caf mono subset main
# OUTPUT: private mono-subset trial entry with no normal-entry changes
# POS: one isolated RSS comparison against the dd5c font-budget group
import hashlib
from pathlib import Path
import sys
import make_font_budget_trial as budget
import make_two_language_trial as language

ENTRY='daf9bad4cb80f13b698386893c395b78d7990675c8bb20a4afdf1d7e2a2fff26'
MAIN='9caf3fa8448a7729dc11fa4897b9756e30fcdeadb56acbdb1cba9acc3e7b6fad'
DELTA='7664064d13008ca34d7d67070d2fede95ac28a06129ac26ec2043f7d74f4217f'
BASE='/mnt/sdcard/roms/ports/sts2-vk-test/mono-subset-trial-a1/packs'
ACTIVE='ca236d08f22d406e8361512bcb45208f281b1f2fac79878ad114468c758ba4c9'
ROOT='/tmp/sts2-memory-diag-monosubseta1'

def main(entry, output):
 raw=Path(entry).read_bytes()
 if hashlib.sha256(raw).hexdigest()!=ENTRY:raise ValueError('unexpected font-budget entry')
 text=raw.decode()
 old_gate=language.INSERT.replace('/tmp/sts2-two-language-trial-a1','/tmp/sts2-font-budget-trial-a1').replace('/tmp/sts2-memory-diag-twolanga1','/tmp/sts2-memory-diag-fontbudgeta1')
 if text.count(old_gate)!=1:raise ValueError('two-language trial seam mismatch')
 gate='[ "$BUILD_ID" = "'+ACTIVE+'" ] && [ "${SLL_DIAG_XDG_ROOT:-}" = "'+ROOT+'" ] && [ "${SLL_TEXTURE_DIAG:-0}" = 1 ] || { echo "[STS2-VK] mono trial requires audited build and isolated diagnostics"; exit 1; }\n'
 text=text.replace(old_gate,gate,1)
 verify=budget.VERIFY.replace(budget.MAIN,MAIN).replace(budget.OLD,budget.MAIN).replace(budget.DELTA,DELTA).replace(budget.BASE,BASE).replace('isolated font-budget main verified','isolated mono subset main verified')
 changes={
  '/tmp/sts2-font-budget-trial-a1':'/tmp/sts2-mono-subset-trial-a1',
  '/tmp/sts2-vk-font-budget-a1-':'/tmp/sts2-vk-mono-subset-a1-',
  budget.VERIFY:verify,
 }
 for old,new in changes.items():
  if text.count(old)!=1:raise ValueError('entry seam mismatch: '+old)
  text=text.replace(old,new)
 with Path(output).open('x') as f:f.write(text)

if __name__=='__main__':main(*sys.argv[1:])
