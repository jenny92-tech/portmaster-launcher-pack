#!/usr/bin/env python3
# INPUT: source-bound quarter build plus separately audited refined main, maskfix, compat and ARM64 engine
# OUTPUT: new complete host build for the existing transactional installer
# POS: offline release assembly only; never touches a device or existing build
import argparse,hashlib,json,os,shlex,shutil,struct,subprocess,sys
from pathlib import Path
import optimize_handheld as o
sys.path.insert(0,str(Path(__file__).resolve().parent/'godot_pck'))
import low_texture_overlay as low

EXPECTED={'base_report':'52a207e880f8a10ebcd857a872229214e3c3fbcc52dee1413d7ed0a78eeb9efb','refined_main':'099bb1f8e7b3985b30617365335d0e5534d2b426e2e7774cbd59d68c7e5db14c','refinement':'5550e729b78fd56e96e7d8ce90803261b0f92b780562c1eb6ff148f6219d5319','delta':'447f1186d5a86495d8b0b5276c95eb1b514413433220fd01bea29abf1939cf16','delta_report':'b76fee5473211b9106282a9e34cd1893589fd326acf6a405fc0806d72db9cce3','overlay':'ced8446fe95c212b26181fc61f27ebe2f6b4f2e8066968a72df03ed68beab3bc','mask_report':'f02a2af9428e544b4b6e31335f789d2b335cef077ab640bbfa81afa4c3fd5c84','compat':'96da217412e7011e2f8050fbdfcad948a425021ad358dec674775dbb33d68546','engine':'93d0952f7b082e221b15eb2f060b20c0237aabf9fea6ec2639cf31d415ce7e9e'}
BASE_MAIN='7ec4bb3f96fd01dc42bde20b6daa2f98cd16f09cec3b8ef404efd53f089615f1'
BASE_OVERLAY='b6d49aadc25d02007c50eeae571ddea9fe5dbea0b555ba25d68b7e9d3d845d95'


def assemble(a):
    base=Path(a.base_build).resolve(strict=True);out=Path(a.output).absolute();out=out.parent.resolve(strict=True)/out.name
    inputs={k:Path(getattr(a,k)).resolve(strict=True) for k in ('refined_main','refinement','delta','delta_report','overlay','mask_report','compat','engine')}
    for k,p in inputs.items():
        if not p.is_file() or o.sha(p)!=EXPECTED[k]:raise ValueError('release input identity mismatch: '+k)
    if not base.is_dir() or o.sha(base/'build-report.json')!=EXPECTED['base_report'] or o.sha(base/'merged'/f'{BASE_MAIN}.pck')!=BASE_MAIN or o.sha(base/'port_compat.pck')!=BASE_OVERLAY:raise ValueError('base build identity mismatch')
    if out.exists() or out.is_symlink() or out==base or out in base.parents or base in out.parents or any(out==p or out in p.parents for p in inputs.values()):raise ValueError('release output must be new and separate')
    h=inputs['engine'].read_bytes()[:20]
    if len(h)!=20 or h[:6]!=b'\x7fELF\x02\x01' or int.from_bytes(h[16:18],'little')!=3 or int.from_bytes(h[18:20],'little')!=183:raise ValueError('engine is not AArch64 PIE')
    baseline=low.read_pack(base/'port_compat.pck');candidate=low.read_pack(inputs['overlay'])
    if set(baseline)!=set(candidate) or len(candidate)!=178:raise ValueError('maskfix overlay inventory mismatch')
    with (base/'port_compat.pck').open('rb') as old,inputs['overlay'].open('rb') as new:
        changed=[n for n in baseline if low.entry_bytes(old,baseline[n])!=low.entry_bytes(new,candidate[n])]
        if changed!=['port_compat/combat_warmup.gd'] or low.digest(low.entry_bytes(new,candidate[changed[0]]))!='66ced536fda060f5599bc01f330a57d7cee5a70f44eab2e9813c66d3fc93c636':raise ValueError('maskfix overlay content mismatch')
    ref=json.loads(inputs['refinement'].read_text());mask=json.loads(inputs['mask_report'].read_text());old=json.loads((base/'build-report.json').read_text())
    compat_evidence=o.REPO/'.cache/sts2-vulkan-trial/bundled-trim-candidate/manifest.json'
    if o.sha(compat_evidence)!='a94af3dcaf82332970b6cf03503e0a74f1e79c828bdc85f7430807ccad45c8dd' or json.loads(compat_evidence.read_text()).get('candidate_compat_sha256')!=EXPECTED['compat']:raise ValueError('compat build evidence mismatch')
    if (ref.get('base_main_sha256')!=BASE_MAIN or ref.get('delta_sha256')!=EXPECTED['delta'] or ref.get('delta_report_sha256')!=EXPECTED['delta_report'] or ref.get('merged_sha256')!=EXPECTED['refined_main'] or ref.get('accepted_count')!=85 or mask.get('base_sha256')!=BASE_OVERLAY or mask.get('candidate_sha256')!=EXPECTED['overlay'] or mask.get('replaced')!=['port_compat/combat_warmup.gd'] or old.get('merged_sha256')!=BASE_MAIN):raise ValueError('release provenance mismatch')
    before=o.source_identities(o.WINDOWS_PROFILE)
    out.mkdir();build=out/'build'
    # APFS clones preserve a self-contained build without a second physical copy.
    result=subprocess.run(['cp','-cR',str(base),str(build)],capture_output=True,text=True)
    if result.returncode:
        if build.exists():shutil.rmtree(build)
        shutil.copytree(base,build)
    (build/'merged').rename(build/'refinement-base-merged');(build/'merged').mkdir()
    def clone(src,dst):
        p=subprocess.run(['cp','-c',str(src),str(dst)],capture_output=True)
        if p.returncode:shutil.copyfile(src,dst)
    clone(inputs['refined_main'],build/'merged'/f"{EXPECTED['refined_main']}.pck")
    refined_side=inputs['refined_main'].with_suffix('.json')
    if not refined_side.is_file():raise ValueError('refined main sidecar missing')
    side=json.loads(refined_side.read_text())
    if side.get('source_sha256')!=BASE_MAIN or side.get('overlay_sha256')!=EXPECTED['delta'] or side.get('merged_sha256')!=EXPECTED['refined_main']:raise ValueError('refined main sidecar mismatch')
    shutil.copyfile(refined_side,build/'merged'/refined_side.name)
    (build/'port_compat.pck').rename(build/'main-port_compat.pck');clone(inputs['overlay'],build/'port_compat.pck')
    shutil.copyfile(inputs['mask_report'],build/'maskfix-overlay-report.json');shutil.copyfile(inputs['delta'],build/'refinement-delta.pck');shutil.copyfile(inputs['delta_report'],build/'refinement-report.json')
    shutil.copyfile(base/'build-report.json',build/'base-build-report.json');shutil.copyfile(compat_evidence,build/'compat-build-evidence.json')
    (build/'refinement-merge').mkdir();shutil.copyfile(inputs['refinement'],build/'refinement-merge/report.json');clone(inputs['engine'],build/'engine.bin')
    patch=build/'patch';(patch/'port_compat.pck').unlink();(patch/'sts2_compat.dll').unlink();clone(inputs['overlay'],patch/'port_compat.pck');clone(inputs['compat'],patch/'sts2_compat.dll')
    manifest=json.loads((patch/'manifest.json').read_text());manifest['files']['port_compat.pck']=EXPECTED['overlay'];manifest['files']['sts2_compat.dll']=EXPECTED['compat'];raw=(json.dumps(manifest,indent=2)+'\n').encode();(patch/'manifest.json').write_bytes(raw)
    entry=build/'vulkan-entry.sh';entry.unlink();subprocess.run([str(o.REPO/'_kit/assemble.sh'),str(o.SRC.parent/'love/vulkan-trial.sh.template'),str(entry)],check=True)
    if before!=o.source_identities(o.WINDOWS_PROFILE):raise ValueError('release sources changed during assembly')
    old.update({'assembly_source_sha256':before,'patch_manifest_sha256':hashlib.sha256(raw).hexdigest(),'patch_files':manifest['files'],'merged_sha256':EXPECTED['refined_main'],'merged_bytes':inputs['refined_main'].stat().st_size,'refinement':ref,'engine_sha256':EXPECTED['engine'],'main_compat_sha256':BASE_OVERLAY,'maskfix_overlay_report':str(build/'maskfix-overlay-report.json'),'entry_sha256':o.sha(entry),'reproduce_command':shlex.join(sys.argv),'release_components':{'compat_sha256':EXPECTED['compat'],'compat_build_evidence_sha256':'a94af3dcaf82332970b6cf03503e0a74f1e79c828bdc85f7430807ccad45c8dd','overlay_sha256':EXPECTED['overlay'],'overlay_report_sha256':EXPECTED['mask_report'],'base_build_report_sha256':EXPECTED['base_report'],'engine_vma_patch_sha256':'d37865aaa81fd92bd61c61f8e423d523d4e8d47cafeac37eb4b6b07789f8a97b','diagnostic_pck_sha256':'da287051fcd6fa2e54a713d586c4ae1a1a1bcbe6a4dd1395be65eedd540b8eb4'}})
    old['release_components']['engine_richtext_patch_sha256']='61c4df3329d6618264e46a346647c7d2ee18c884a570f9201ac87bb5b45e3a99'
    (build/'build-report.json').write_text(json.dumps(old,indent=2,ensure_ascii=False)+'\n');print(json.dumps({'build':str(build),'entry_sha256':old['entry_sha256'],'patch_sha256':old['patch_manifest_sha256'],'main_sha256':old['merged_sha256'],'engine_sha256':old['engine_sha256']}));return build

if __name__=='__main__':
    try:
        p=argparse.ArgumentParser(description=__doc__)
        for name in ('base-build','refined-main','refinement','delta','delta-report','overlay','mask-report','compat','engine','output'):p.add_argument('--'+name,required=True,type=Path)
        assemble(p.parse_args())
    except (OSError,ValueError,KeyError,TypeError,subprocess.CalledProcessError) as e:sys.exit('release assembly failed: '+str(e))
