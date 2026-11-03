#!/usr/bin/env python3
# INPUT: selected SFX and its SHA-256, local 7zz and pinned official UnRAR
# OUTPUT: new private data-only directory and per-file size, CRC and SHA report
# POS: sandboxed macOS extraction; never executes SFX commands or game content
import argparse, hashlib, json, os, re, shutil, subprocess, sys, unicodedata, zlib
from pathlib import Path

UNRAR_SHA256 = '99720d63484b8db77db43477db095f198d52b34515938d4ee7b165c59fa1cbe9'
ARCHIVE_SHA256 = '68b393c000758d477fde43c955ff7542f12f76f3f5e87cdda923152fc791bd4d'

def source_id(source):
    s = source.stat()
    return (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns)

def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
    return h.hexdigest()

def sandbox_profile(source, unrar):
    # Literal paths are escaped as Scheme strings; no shell command expansion.
    source = json.dumps(str(source), ensure_ascii=False)
    unrar = json.dumps(str(unrar), ensure_ascii=False)
    return f'''(version 1)
(allow default)
(deny network*)
(deny file-read-data (subpath "/Users") (subpath "/Volumes") (subpath "/private") (subpath "/Library"))
(deny file-write*)
(deny process-exec)
(allow process-exec (literal "/bin/cat") (literal "/usr/bin/nc") (literal {unrar}))
(allow process-fork)
(allow mach-lookup)
(allow signal (target self))
(allow process-info*)
(allow ipc-posix-shm)
(allow sysctl-read)
(allow file-read-metadata)
(allow file-read-data (subpath "/private/var/db/dyld") (literal {unrar}) (literal {source}))
'''

def main():
    parser=argparse.ArgumentParser(description='Safely extract a RAR5 SFX as data on macOS, without running its executable.')
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--source-sha256', required=True)
    parser.add_argument('--output-dir', type=Path, required=True, help='new private directory')
    parser.add_argument('--unrar', type=Path, required=True, help='official macOS ARM64 UnRAR 7.23 binary')
    parser.add_argument('--seven', type=Path, default=Path('/opt/homebrew/bin/7zz'))
    args=parser.parse_args()
    if sys.platform!='darwin': raise ValueError('macOS sandbox-exec is required')
    if not re.fullmatch('[0-9a-f]{64}', args.source_sha256): raise ValueError('source SHA-256 must be 64 lowercase hex digits')
    source=args.source.resolve(strict=True); unrar=args.unrar.resolve(strict=True); seven=args.seven.resolve(strict=True)
    root=args.output_dir.absolute()
    if root.exists() or root.is_symlink(): raise ValueError('output directory must not already exist')
    if any(any(ord(c)<32 for c in str(p)) for p in (source,unrar,root)): raise ValueError('control characters in paths are unsupported')
    if digest(unrar)!=UNRAR_SHA256: raise ValueError('UnRAR does not match pinned official 7.23 binary SHA-256')
    before=source_id(source)
    if digest(source)!=args.source_sha256 or source_id(source)!=before: raise ValueError('source identity changed or SHA mismatch')
    listing=subprocess.run([str(seven),'l','-slt','--',str(source)],capture_output=True,text=True,check=True).stdout
    if listing.count('----------')!=1: raise ValueError('unexpected archive listing')
    body=listing.split('----------',1)[1]
    entries=[dict(line.split(' = ',1) for line in block.strip().splitlines() if ' = ' in line) for block in body.strip().split('\n\n')]
    seen=set(); files=[]; total=0
    for item in entries:
        raw=item['Path']; parts=raw.split('/')
        if not parts or any(not p or p in ('.','..') or any(c in p for c in ('\\',':','*','?')) or any(ord(c)<32 for c in p) for p in parts): raise ValueError('unsafe member path')
        normalized=unicodedata.normalize('NFC',raw).casefold()
        if normalized in seen: raise ValueError('duplicate or case-equivalent paths')
        seen.add(normalized)
        if item.get('Folder') not in ('+','-') or item.get('Encrypted')!='-' or item.get('Alternate Stream')!='-' or any(item.get(k) for k in ('Symbolic Link','Hard Link','Copy Link')): raise ValueError('unsupported archive member')
        size=int(item['Size'])
        if size<0: raise ValueError('negative member size')
        if item['Folder']=='-':
            if len(item.get('CRC',''))!=8: raise ValueError('missing file CRC')
            files.append((raw,parts,size,item['CRC'].upper()));total+=size
    if shutil.disk_usage(root.parent).free < total+1024*1024*1024: raise ValueError('insufficient free space including 1 GiB margin')
    root.mkdir(mode=0o700)
    sandbox=root/'unrar.sb'
    sandbox.write_text(sandbox_profile(source, unrar), encoding='utf8')
    out=root/'files';out.mkdir(mode=0o700)
    rootfd=os.open(out,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    results=[]
    try:
        for i,(raw,parts,size,crc) in enumerate(files,1):
            fd=os.dup(rootfd)
            try:
                for part in parts[:-1]:
                    try: os.mkdir(part,mode=0o700,dir_fd=fd)
                    except FileExistsError: pass
                    new=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd);os.close(fd);fd=new
                target=os.open(parts[-1],os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=fd)
                with os.fdopen(target,'wb') as dest:
                    proc=subprocess.Popen(['/usr/bin/sandbox-exec','-f',str(sandbox),str(unrar),'p','-inul','-cfg-','-@','-p-','--',str(source),raw],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
                    h=hashlib.sha256(); check=0; written=0
                    while True:
                        block=proc.stdout.read(1024*1024)
                        if not block: break
                        written+=len(block)
                        if written>size: proc.kill();proc.wait();raise ValueError('member exceeds reported size: '+raw)
                        dest.write(block);h.update(block);check=zlib.crc32(block,check)
                    status=proc.wait()
                    if status or written!=size or f'{check & 0xffffffff:08X}'!=crc: raise ValueError('member extraction or CRC failed: '+raw)
                    results.append({'path':raw,'bytes':written,'crc32':crc,'sha256':h.hexdigest()})
            finally: os.close(fd)
            if i%25==0 or i==len(files): print(f'extracted {i}/{len(files)}',flush=True)
    finally: os.close(rootfd)
    if source_id(source)!=before or digest(source)!=args.source_sha256 or source_id(source)!=before: raise ValueError('source changed during extraction')
    report={'source':str(source),'source_sha256':args.source_sha256,'archive':'RAR5 SFX; wrapper commands not run','listing_tool':str(seven), 'extractor':'official UnRAR 7.23 macOS ARM64', 'extractor_source':'https://www.rarlab.com/rar/rarmacos-arm-723.tar.gz', 'extractor_archive_expected_sha256':ARCHIVE_SHA256,'extractor_binary_sha256':digest(unrar), 'method':'sandboxed unrar p per validated exact member; no-follow exclusive file creation; independent length, CRC32 and SHA256; no game executable run', 'sandbox':'sandbox-exec denies network and writes; restricts reads in /Users, /Volumes, /private and /Library except selected input, UnRAR and dyld cache', 'entries':len(entries),'files':len(files),'total_bytes':total,'files_manifest':results}
    with (root/'extraction-report.json').open('x',encoding='utf8') as f: json.dump(report,f,indent=2,ensure_ascii=False);f.write('\n')
    print('complete',flush=True)

if __name__=='__main__':
    try: main()
    except (ValueError,OSError,KeyError,subprocess.SubprocessError) as e: print('extraction failed:',e,file=sys.stderr);sys.exit(1)
