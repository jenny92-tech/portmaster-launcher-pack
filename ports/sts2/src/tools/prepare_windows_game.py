#!/usr/bin/env python3
# INPUT: audited Windows game DLL/deps, Linux runtime deps and GodotSharp
# OUTPUT: private ARM64 pure-IL input, Linux deps, version and dependency report
# POS: convert metadata only; never execute a Windows or game executable
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import sys


def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''): h.update(block)
    return h.hexdigest()


def inspect_managed(raw):
    data=bytearray(raw)
    if data[:2]!=b'MZ' or len(data)<64: raise ValueError('not a PE assembly')
    pe=struct.unpack_from('<I',data,0x3c)[0]
    if data[pe:pe+4]!=b'PE\0\0': raise ValueError('invalid PE signature')
    coff=pe+4; machine,sections=struct.unpack_from('<HH',data,coff)
    size=struct.unpack_from('<H',data,coff+16)[0]; optional=coff+20
    magic=struct.unpack_from('<H',data,optional)[0]
    if (machine,magic) not in ((0x8664,0x20b),(0xaa64,0x20b),(0x14c,0x10b)):
        raise ValueError('unsupported managed architecture')
    cli_rva=struct.unpack_from('<I',data,optional+(112 if magic==0x20b else 96)+14*8)[0]; table=optional+size
    cli=None
    for i in range(sections):
        off=table+i*40;vsize,va,rawsize,rawptr=struct.unpack_from('<4I',data,off+8)
        if va<=cli_rva and cli_rva+72<=va+rawsize and rawptr+(cli_rva-va)+72<=len(data):
            cli=rawptr+(cli_rva-va);break
    if cli is None or cli+72>len(data): raise ValueError('invalid CLI header')
    flags=struct.unpack_from('<I',data,cli+16)[0]; native_rva,native_size=struct.unpack_from('<II',data,cli+64)
    if not flags & 1 or flags & (2|0x10|0x20000) or native_rva or native_size:
        raise ValueError('DLL is not architecture-neutral pure IL')
    return machine,coff,flags


def patch_pure_il(raw):
    data=bytearray(raw)
    machine,coff,_=inspect_managed(data)
    if machine!=0x8664: raise ValueError('expected x86-64 PE32+ managed DLL')
    struct.pack_into('<H',data,coff,0xaa64)
    return bytes(data)


def rebind_deps(new, baseline):
    win=new['runtimeTarget']['name'];linux=baseline['runtimeTarget']['name']
    if win!='.NETCoreApp,Version=v9.0/win-x64' or linux!='.NETCoreApp,Version=v9.0/linux-arm64':
        raise ValueError('unexpected .NET runtime targets')
    old_key='runtimepack.Microsoft.NETCore.App.Runtime.win-x64/9.0.7'
    new_key='runtimepack.Microsoft.NETCore.App.Runtime.linux-arm64/9.0.7'
    if old_key not in new['targets'][win] or new_key not in baseline['targets'][linux] or new_key not in baseline['libraries']:
        raise ValueError('runtime pack version mismatch')
    data=json.loads(json.dumps(new)); target=data['targets'].pop(win)
    target.pop(old_key); target[new_key]=baseline['targets'][linux][new_key]
    dependencies=target['sts2/0.1.0']['dependencies']
    if dependencies.pop('runtimepack.Microsoft.NETCore.App.Runtime.win-x64',None)!='9.0.7':
        raise ValueError('unexpected application runtime dependency')
    dependencies['runtimepack.Microsoft.NETCore.App.Runtime.linux-arm64']='9.0.7'
    data['targets'][linux]=target;data['runtimeTarget']['name']=linux
    if old_key not in data['libraries']:raise ValueError('Windows runtime pack library missing')
    data['libraries'].pop(old_key);data['libraries'][new_key]=baseline['libraries'][new_key]
    return data


def verify_dependencies(paths, expected):
    windows = set(paths)-{'GodotSharp.dll'}
    if windows != set(expected): raise ValueError('Windows managed dependency inventory mismatch')
    for name in sorted(windows):
        if sha(paths[name]) != expected[name]: raise ValueError('Windows managed dependency identity mismatch: '+name)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('windows-dir','linux-runtime-deps','linux-godotsharp','release-info','output-dir'):p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--dll-sha256',required=True);p.add_argument('--deps-sha256',required=True)
    args=p.parse_args();windows=args.windows_dir.resolve(strict=True);out=args.output_dir.resolve()
    if out.exists() or any(out==x or out in x.parents for x in (windows,args.linux_runtime_deps.resolve(),args.linux_godotsharp.resolve(),args.release_info.resolve())):
        raise ValueError('output must be new and cannot contain inputs')
    dll=windows/'sts2.dll';deps=windows/'sts2.deps.json'
    if sha(dll)!=args.dll_sha256 or sha(deps)!=args.deps_sha256:raise ValueError('Windows DLL/deps SHA mismatch')
    original=json.loads(deps.read_text());baseline=json.loads(args.linux_runtime_deps.read_text());release=json.loads(args.release_info.read_text())
    updated=rebind_deps(original,baseline);patched=patch_pure_il(dll.read_bytes())
    target=original['targets'][original['runtimeTarget']['name']]; names=set()
    for key,values in target.items():
        if key.startswith(('runtimepack.','sts2/')):continue
        for item in values.get('runtime',{}):
            name=Path(item).name
            if not name.endswith('.dll') or name in names:raise ValueError('unsupported or duplicate managed dependency: '+name)
            names.add(name)
    paths={n:(args.linux_godotsharp if n=='GodotSharp.dll' else windows/n) for n in names}
    for name,path in paths.items():
        if not path.is_file() or path.is_symlink():raise ValueError('missing dependency: '+name)
    profile=json.loads(Path(__file__).with_name('handheld_low_v110_profile.json').read_text())
    verify_dependencies(paths,profile['windows_dependency_sha256'])
    out.mkdir(mode=0o700,parents=True);(out/'sts2.dll').write_bytes(patched)
    (out/'sts2.deps.json').write_text(json.dumps(updated,indent=2)+'\n')
    shutil.copyfile(args.release_info,out/'release_info.json')
    converted=[]
    for name,path in sorted(paths.items()):
        raw=path.read_bytes();original_sha=hashlib.sha256(raw).hexdigest()
        machine,_,flags=inspect_managed(raw)
        if machine==0x8664:
            if name not in profile['arm64_dependency_sha256']:raise ValueError('unreviewed x86-64 managed dependency: '+name)
            raw=patch_pure_il(raw);converted.append(name)
        elif machine!=0x14c:raise ValueError('unexpected dependency architecture: '+name)
        expected=profile['arm64_dependency_sha256'].get(name,original_sha)
        if hashlib.sha256(raw).hexdigest()!=expected:raise ValueError('prepared dependency checksum mismatch: '+name)
        (out/name).write_bytes(raw)
        if sha(path)!=original_sha:raise ValueError('dependency changed while staging: '+name)
    report={'windows_dll_sha256':args.dll_sha256,'windows_deps_sha256':args.deps_sha256,
            'linux_runtime_deps_sha256':sha(args.linux_runtime_deps),'linux_godotsharp_sha256':sha(args.linux_godotsharp),
            'release_info_sha256':sha(args.release_info),'release_info_unverified':release,
            'prepared_files':{p.name:sha(p) for p in sorted(out.iterdir()) if p.is_file()},
            'method':'verify every managed dependency is pure IL without 32-bit/native-entry/R2R constraints; change audited x86-64 PE machine fields to ARM64; preserve AnyCPU bytes; rebind Windows .NET 9.0.7 runtime metadata to supplied Linux ARM64 runtime',
            'converted_dependencies':converted,
            'runtime_libraries':'Linux ARM64 runtime files are external and must be independently verified at deployment'}
    (out/'prepare-report.json').write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
    print('Prepared',len(names),'managed dependencies in',out)


if __name__=='__main__':
    try:main()
    except (OSError,ValueError,KeyError,TypeError,struct.error) as exc:
        print('Windows game preparation failed:',exc,file=sys.stderr);sys.exit(1)
