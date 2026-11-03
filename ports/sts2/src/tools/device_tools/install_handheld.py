#!/usr/bin/env python3
# INPUT: verified handheld build and explicit device paths and entry identity
# OUTPUT: resumable texture transfer and verified, selector-based installation
# POS: host-side installer; never starts or controls the game
"""Install a verified handheld build. --plan is entirely local and read-only."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import stat
import sys

# --plan must not create import caches in the source tree.
sys.dont_write_bytecode = True
import upload_texture as upload

HERE = Path(__file__).resolve().parent
MERGE = HERE.parent / 'godot_pck/merge_texture_pck.py'
PROFILE = HERE.parent / 'handheld_low_profile.json'
ENTRY_TEMPLATE = HERE.parents[2] / 'love/vulkan-trial.sh.template'
FILES = {'sts2.dll', 'sts2.deps.json', 'sts2_compat.dll', 'port_compat.pck'}
HASH = re.compile(r'[0-9a-f]{64}\Z')


def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for b in iter(lambda: f.read(1024 * 1024), b''): h.update(b)
    return h.hexdigest()


def require_hash(value):
    if not isinstance(value, str) or not HASH.fullmatch(value):
        raise ValueError('invalid SHA-256')
    return value


def regular(path):
    p = Path(path)
    if not p.is_file() or p.is_symlink(): raise ValueError('expected regular non-symlink file: ' + str(p))
    return p


def remote_path(value):
    if not value.startswith('/') or value == '/' or any(p in ('', '.', '..') for p in value[1:].split('/')) or '\x00' in value:
        raise ValueError('device paths must be absolute normalized paths')
    return value


def validate(args):
    if not args.target or args.target.startswith('-') or any(c in args.target for c in '\x00\r\n'):
        raise ValueError('invalid explicit target')
    for name in ('device_root', 'device_source_pck', 'device_game_dir', 'device_entry'):
        remote_path(getattr(args, name))
    require_hash(args.entry_sha256)
    state_dir = Path(args.state_dir)
    if not state_dir.is_absolute() or state_dir.is_symlink(): raise ValueError('state directory must be an existing absolute private directory')
    state_info = state_dir.stat()
    if not stat.S_ISDIR(state_info.st_mode) or state_info.st_uid != os.geteuid() or state_info.st_mode & 0o077:
        raise ValueError('state directory must be private and owned by the current user')
    # The verified entry has fixed paths for its root, game directory and PCK.
    entry_parent = PurePosixPath(args.device_entry).parent
    if (PurePosixPath(args.device_root) != entry_parent / 'sts2-vk-test' or
        PurePosixPath(args.device_game_dir) != entry_parent / 'sts2/data_sts2_linuxbsd_arm64' or
        PurePosixPath(args.device_source_pck) != entry_parent / 'sts2/gamedata/pcks/SlayTheSpire2.pck'):
        raise ValueError('device paths do not match the Vulkan entry layout')
    build = Path(args.build_dir)
    if not build.is_dir() or build.is_symlink(): raise ValueError('build directory must exist and not be a symlink')
    report = json.loads(regular(build / 'build-report.json').read_text())
    patch = build / 'patch'
    if not patch.is_dir() or patch.is_symlink() or {p.name for p in patch.iterdir()} != FILES | {'manifest.json'}:
        raise ValueError('patch contents differ from expected closed set')
    manifest_path = regular(patch / 'manifest.json')
    patch_id = require_hash(report['patch_manifest_sha256'])
    if sha(manifest_path) != patch_id: raise ValueError('patch manifest checksum mismatch')
    manifest = json.loads(manifest_path.read_text())
    if set(manifest) != {'files', 'source_files'} or set(manifest['files']) != FILES or set(manifest['source_files']) != {'sts2.dll', 'sts2.deps.json'}:
        raise ValueError('invalid patch manifest')
    if report['patch_files'] != manifest['files']: raise ValueError('build and patch manifest disagree')
    for name, expected in manifest['files'].items():
        if sha(regular(patch / name)) != require_hash(expected): raise ValueError('patch checksum mismatch: ' + name)
    for name, expected in manifest['source_files'].items():
        if sha(regular(build / 'game-input' / name)) != require_hash(expected): raise ValueError('game input mismatch: ' + name)
    inputs = report['input_sha256']
    profile = json.loads(regular(PROFILE).read_text())
    for key in ('source_pck', 'game_dll', 'game_deps'):
        if require_hash(inputs[key]) != require_hash(profile[key + '_sha256']):
            raise ValueError('input differs from trusted handheld profile: ' + key)
    if inputs['game_dll'] != manifest['source_files']['sts2.dll'] or inputs['game_deps'] != manifest['source_files']['sts2.deps.json']:
        raise ValueError('source identities disagree')
    texture, texture_report = regular(report['texture_overlay']), regular(report['texture_report'])
    tr = json.loads(texture_report.read_text())
    spine = tr.get('verified_spine_loader')
    if not isinstance(spine, bool): raise ValueError('texture report must declare Spine selection')
    if spine and not getattr(args, 'allow_unverified_spine_binary', False) and not args.plan:
        raise ValueError('Spine binary is not bound to the audited source; pass --allow-unverified-spine-binary to accept this risk')
    if tr['source_sha256'] != require_hash(inputs['source_pck']) or sha(texture) != require_hash(tr['output_sha256']):
        raise ValueError('texture report identities mismatch')
    if report['texture'] != {k: v for k, v in tr.items() if k != 'resources'}: raise ValueError('texture report differs from build report')
    if report.get('tool_sha256', {}).get('merge') != sha(MERGE): raise ValueError('merge tool differs from build identity')
    merged_id = require_hash(report['merged_sha256'])
    merged = regular(build / 'merged' / (merged_id + '.pck'))
    if sha(merged) != merged_id or merged.stat().st_size != report['merged_bytes']: raise ValueError('merged pack checksum mismatch')
    sidecar = json.loads(regular(build / 'merged' / (merged_id + '.json')).read_text())
    if (set(sidecar) != {'source_sha256', 'overlay_sha256', 'merged_sha256', 'source_stat', 'merged_stat'} or
        sidecar['source_sha256'] != inputs['source_pck'] or sidecar['overlay_sha256'] != tr['output_sha256'] or
        sidecar['merged_sha256'] != merged_id or sidecar['merged_stat'] != {'size': merged.stat().st_size, 'mtime_ns': merged.stat().st_mtime_ns}):
        raise ValueError('local merged sidecar mismatch')
    spec = importlib.util.spec_from_file_location('installer_merge', MERGE)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    overlay_entries = module.read_pack(texture); merged_entries = module.read_pack(merged)
    reported = {}
    for item in tr['resources']:
        if 'output_md5' in item:
            if item.get('category') not in ('spine_page_or_neighbor', 'other_2d'):
                raise ValueError('converted texture lacks a recognized category')
            if not spine and item['category'] == 'spine_page_or_neighbor':
                raise ValueError('texture report includes Spine despite claiming it was excluded')
            if item['path'] in reported: raise ValueError('duplicate texture report entry')
            reported[item['path']] = item['output_md5']
    if not overlay_entries or set(reported) != set(overlay_entries): raise ValueError('texture report does not match pack')
    with texture.open('rb') as src:
        for name, entry in overlay_entries.items():
            if not name.startswith('.godot/imported/') or not name.endswith('.ctex') or entry[2].hex() != reported[name] or name not in merged_entries or merged_entries[name][1:] != entry[1:]:
                raise ValueError('invalid texture entry: ' + name)
            module.transfer(src, entry)
    with merged.open('rb') as src:
        for entry in merged_entries.values(): module.transfer(src, entry)
    template = regular(ENTRY_TEMPLATE).read_text()
    try: block = template.split('patch_id="$(cat "$TESTDIR/active-patch")"', 1)[1].split('# Never apply a late texture overlay', 1)[0]
    except IndexError: raise ValueError('trusted entry template is incompatible')
    return {'entry_block_hash': hashlib.sha256(block.encode()).hexdigest(), 'report': report, 'manifest': manifest, 'patch_id': patch_id, 'merged_id': merged_id,
            'texture': texture, 'texture_report': texture_report, 'patch': patch}


# Runs only after all local validation and transfers. No launcher/game execution.
REMOTE = r'''import ctypes,errno,hashlib,json,os,re,stat,subprocess,sys,tempfile
from pathlib import Path
root,source,game,entry,entry_hash,entry_block_hash,stage,patch_id,merged_id,source_hash,overlay_hash,helper_hash,merge_hash,report_hash,reuse,snapshots = sys.argv[1:]
reuse = reuse == '1'
snapshots=json.loads(snapshots)
H=lambda p: digest(p)
def digest(p):
    h=hashlib.sha256()
    fd=os.open(p,os.O_RDONLY|os.O_NOFOLLOW)
    with os.fdopen(fd,'rb') as f:
        s=os.fstat(f.fileno())
        if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1: raise ValueError('unsafe file: '+p)
        for b in iter(lambda:f.read(1048576),b''): h.update(b)
    return h.hexdigest()
def directory(p):
    fd=os.open('/',os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:
        for part in p[1:].split('/'):
            nxt=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd); os.close(fd); fd=nxt
    finally: os.close(fd)
def regular(p):
    directory(str(Path(p).parent)); s=os.lstat(p)
    if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1: raise ValueError('unsafe file: '+p)
    return s
def contents(p):
    regular(p)
    fd=os.open(p,os.O_RDONLY|os.O_NOFOLLOW)
    with os.fdopen(fd,'rb') as f: return f.read()
def check(p,want):
    regular(p)
    if H(p)!=want: raise ValueError('checksum mismatch: '+p)
def ident(p):
    s=regular(p); return {'size':s.st_size,'mtime_ns':s.st_mtime_ns}
def snapshot(p):
    s=regular(p); return [s.st_dev,s.st_ino,s.st_nlink,s.st_size,s.st_mtime_ns,s.st_ctime_ns]
def stable(p,key):
    if snapshot(p)!=snapshots[key]: raise ValueError('verified main input changed: '+p)
def verify_patch(p,identity):
    directory(p)
    if set(os.listdir(p))!={'manifest.json','sts2.dll','sts2.deps.json','sts2_compat.dll','port_compat.pck'}: raise ValueError('invalid patch contents')
    raw=contents(p+'/manifest.json')
    if hashlib.sha256(raw).hexdigest()!=identity: raise ValueError('patch manifest mismatch')
    m=json.loads(raw)
    if set(m)!={'files','source_files'} or set(m['files'])!={'sts2.dll','sts2.deps.json','sts2_compat.dll','port_compat.pck'} or set(m['source_files'])!={'sts2.dll','sts2.deps.json'}: raise ValueError('invalid patch manifest')
    for n,h in m['files'].items(): check(p+'/'+n,h)
    for n,h in m['source_files'].items(): check(game+'/'+n,h)
    return m
for p in (root,game,stage,root+'/patches',root+'/merged'): directory(p)
if not reuse: directory(root+'/textures')
helper_files = [('install.py',helper_hash)]
if not reuse: helper_files += [('merge.py',merge_hash),('texture-report.json',report_hash)]
for n,h in helper_files: check(stage+'/'+n,h)
check(entry,entry_hash)
e=contents(entry).decode('utf-8')
for marker in ('TESTDIR="$SCRIPT_DIR/sts2-vk-test"','ORIGINAL="$SCRIPT_DIR/sts2"'):
    if marker not in e: raise ValueError('entry lacks required layout: '+marker)
try: block=e.split('patch_id="$(cat "$TESTDIR/active-patch")"',1)[1].split('# Never apply a late texture overlay',1)[0]
except IndexError: raise ValueError('entry lacks required verification block')
if hashlib.sha256(block.encode()).hexdigest()!=entry_block_hash: raise ValueError('entry verification block differs from trusted template')
if reuse: stable(source,'source')
else: check(source,source_hash)
if not reuse: check(root+'/textures/'+overlay_hash+'.pck',overlay_hash)
verify_patch(stage+'/patch',patch_id)
old=contents(root+'/active-patch').decode().strip()
if not re.fullmatch('[0-9a-f]{64}',old): raise ValueError('invalid existing patch selector')
verify_patch(root+'/patches/'+old,old)
# Existing texture, when present, must also be valid for this source.
def verify_texture(identity):
    if not re.fullmatch('[0-9a-f]{64}',identity): raise ValueError('invalid texture selector')
    p=root+'/merged/'+identity+'.pck'; meta=json.loads(contents(root+'/merged/'+identity+'.json'))
    if set(meta)!={'source_sha256','overlay_sha256','merged_sha256','source_stat','merged_stat'} or meta['merged_sha256']!=identity or meta['source_sha256']!=source_hash or meta['source_stat']!=ident(source) or meta['merged_stat']!=ident(p): raise ValueError('invalid texture sidecar')
    if reuse: stable(p,'merged')
    else: check(p,identity)
try: old_texture=contents(root+'/active-texture').decode().strip()
except FileNotFoundError: old_texture=None
if reuse and old_texture!=merged_id: raise ValueError('active texture does not match existing main')
if old_texture is not None: verify_texture(old_texture)
# Reject an existing inconsistent sidecar; do not let the merge replace it.
p=root+'/merged/'+merged_id+'.pck'; side=root+'/merged/'+merged_id+'.json'
if reuse:
    verify_texture(merged_id)
elif os.path.lexists(side):
    verify_texture(merged_id)
else:
    if os.path.lexists(p): check(p,merged_id)
    subprocess.run(['python3',stage+'/merge.py','--source',source,'--overlay',root+'/textures/'+overlay_hash+'.pck','--report',stage+'/texture-report.json','--output-dir',root+'/merged'],check=True)
verify_texture(merged_id)
if json.loads(contents(side))['overlay_sha256']!=overlay_hash: raise ValueError('merged overlay identity mismatch')
# Publish fully written and verified files with no-replace rename. Temporary
# files live in the stage, so a power loss cannot expose a truncated final file.
# Unrecognized or interrupted temporaries are retained for inspection.
dest=root+'/patches/'+patch_id
try: os.mkdir(dest,0o700)
except FileExistsError: directory(dest)
tmpdir=stage+'/patch-tmp'
try: os.mkdir(tmpdir,0o700)
except FileExistsError: directory(tmpdir)
libc=ctypes.CDLL(None,use_errno=True)
if hasattr(libc,'renameat2'): rename,flag=libc.renameat2,1
elif hasattr(libc,'renameatx_np'): rename,flag=libc.renameatx_np,4
else: raise ValueError('safe no-replace rename unavailable')
rename.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_uint]
for n in sorted(('manifest.json','sts2.dll','sts2.deps.json','sts2_compat.dll','port_compat.pck')):
    data=contents(stage+'/patch/'+n); want=hashlib.sha256(data).hexdigest(); target=dest+'/'+n
    if os.path.lexists(target):
        check(target,want)
        continue
    fd,temp=tempfile.mkstemp(prefix='.'+n+'.',suffix='.incoming',dir=tmpdir)
    temp_stat=os.fstat(fd)
    try:
        with os.fdopen(fd,'wb') as f:
            f.write(data); f.flush(); os.fsync(f.fileno())
        check(temp,want)
        tfd=os.open(tmpdir,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
        dfd=os.open(dest,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
        try:
            if rename(tfd,os.fsencode(os.path.basename(temp)),dfd,os.fsencode(n),flag)!=0:
                error=ctypes.get_errno()
                if error==errno.EEXIST: check(target,want)
                else: raise OSError(error,os.strerror(error))
            # The directory entry must reach storage before a selector can commit.
            os.fsync(dfd)
        finally: os.close(tfd); os.close(dfd)
    finally:
        if os.path.lexists(temp):
            current=os.lstat(temp)
            if (current.st_dev,current.st_ino,current.st_nlink)!=(temp_stat.st_dev,temp_stat.st_ino,1): raise ValueError('temporary file changed')
            os.unlink(temp)
# Recheck directory durability even when all final files came from a prior attempt.
dfd=os.open(dest,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
try: os.fsync(dfd)
finally: os.close(dfd)
verify_patch(dest,patch_id)
if reuse: stable(source,'source')
else: check(source,source_hash)
verify_texture(merged_id); check(entry,entry_hash)
if contents(root+'/active-patch').decode().strip()!=old: raise ValueError('patch selector changed during installation')
try: current=contents(root+'/active-texture').decode().strip()
except FileNotFoundError: current=None
if current!=old_texture: raise ValueError('texture selector changed during installation')
# The old patch and new texture have both been validated against the same source.
# This order leaves a compatible pair if the second replacement fails.
def select(name,value):
    temp=root+'/.install-'+name+'-'+value
    data=(value+'\n').encode()
    try: fd=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    except FileExistsError:
        if contents(temp)!=data: raise ValueError('foreign selector temporary')
    else:
        with os.fdopen(fd,'wb') as f: f.write(data); f.flush(); os.fsync(f.fileno())
    # Reject symlink or hardlinked existing selectors before replacement.
    try: regular(root+'/'+name)
    except FileNotFoundError: pass
    os.replace(temp,root+'/'+name)
if not reuse: select('active-texture',merged_id)
select('active-patch',patch_id)
# Stage files are copies, not the published patch. Remove only the exact
# verified stage we created; unexpected entries leave it intact for inspection.
try:
    if set(os.listdir(stage))!=set(n for n,h in helper_files)|{'patch','patch-tmp'}: raise ValueError('unexpected stage contents')
    directory(stage+'/patch-tmp')
    if os.listdir(stage+'/patch-tmp'): raise ValueError('interrupted patch temporaries require inspection')
    if set(os.listdir(stage+'/patch'))!={'manifest.json','sts2.dll','sts2.deps.json','sts2_compat.dll','port_compat.pck'}: raise ValueError('unexpected stage patch contents')
    verify_patch(stage+'/patch',patch_id)
    for n,h in helper_files: check(stage+'/'+n,h)
    for n in ('manifest.json','sts2.dll','sts2.deps.json','sts2_compat.dll','port_compat.pck'): os.unlink(stage+'/patch/'+n)
    os.rmdir(stage+'/patch')
    os.rmdir(stage+'/patch-tmp')
    for n,h in helper_files: os.unlink(stage+'/'+n)
    os.rmdir(stage)
except (OSError,ValueError) as exc:
    print('stage retained for inspection: '+str(exc))
# A running merge may have the uploaded overlay open through any mount alias.
# Match device/inode in both fd links and maps, and fail closed on unreadable
# processes or disappearing entries other than a process that exited.
if not reuse:
    try:
        overlay=root+'/textures/'+overlay_hash+'.pck'
        s=regular(overlay); check(overlay,overlay_hash)
        for pid in os.listdir('/proc'):
            if not pid.isdigit(): continue
            proc='/proc/'+pid
            try:
                for fd in os.listdir(proc+'/fd'):
                    try: fs=os.stat(proc+'/fd/'+fd)
                    except FileNotFoundError: continue
                    if (fs.st_dev,fs.st_ino)==(s.st_dev,s.st_ino): raise ValueError('overlay open by PID '+pid)
                with open(proc+'/maps') as maps:
                    for line in maps:
                        fields=line.split(None,5)
                        if len(fields)<5: raise ValueError('unreadable process map')
                        dev=fields[3].split(':')
                        if len(dev)!=2: raise ValueError('invalid process map device')
                        if (int(dev[0],16),int(dev[1],16),int(fields[4]))==(os.major(s.st_dev),os.minor(s.st_dev),s.st_ino):
                            raise ValueError('overlay mapped by PID '+pid)
            except FileNotFoundError:
                if os.path.exists(proc): raise
        current=regular(overlay)
        if (current.st_dev,current.st_ino)!=(s.st_dev,s.st_ino): raise ValueError('overlay changed during inspection')
        check(overlay,overlay_hash)
        os.unlink(overlay)
        print('verified uploaded overlay removed')
    except (OSError,ValueError) as exc:
        print('uploaded overlay retained for inspection: '+str(exc))
print('installed texture '+merged_id+' and patch '+patch_id)
'''


# Reuse mode never creates a merged pack or uploads a texture. Check on the
# device before transferring anything and repeat in the final helper.
REUSE_CHECK = r'''import hashlib,json,os,stat,sys
from pathlib import Path
root,source,source_hash,overlay_hash,merged_hash=sys.argv[1:]
def directory(p):
    fd=os.open('/',os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:
        for part in p[1:].split('/'):
            nxt=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd); os.close(fd); fd=nxt
    finally: os.close(fd)
def open_file(p):
    directory(str(Path(p).parent))
    fd=os.open(p,os.O_RDONLY|os.O_NOFOLLOW); st=os.fstat(fd)
    if not stat.S_ISREG(st.st_mode) or st.st_nlink!=1:
        os.close(fd); raise ValueError('unsafe file: '+p)
    return fd,st
def snap(st): return [st.st_dev,st.st_ino,st.st_nlink,st.st_size,st.st_mtime_ns,st.st_ctime_ns]
def sha(p):
    fd,st=open_file(p); h=hashlib.sha256()
    with os.fdopen(fd,'rb') as f:
        for b in iter(lambda:f.read(1048576),b''): h.update(b)
        after=os.fstat(f.fileno())
    if snap(st)!=snap(after): raise ValueError('input changed during checksum')
    return h.hexdigest(),snap(after)
def ident(st): return {'size':st.st_size,'mtime_ns':st.st_mtime_ns}
directory(root); merged=root+'/merged/'+merged_hash+'.pck'; side=root+'/merged/'+merged_hash+'.json'
fd,ss=open_file(source); os.close(fd)
fd,ms=open_file(merged); os.close(fd)
fd,_=open_file(side)
with os.fdopen(fd,'rb') as f: metadata=json.load(f)
fd,_=open_file(root+'/active-texture')
with os.fdopen(fd,'rb') as f: active=f.read().decode().strip()
if active!=merged_hash: raise ValueError('active texture does not match existing main')
if set(metadata)!={'source_sha256','overlay_sha256','merged_sha256','source_stat','merged_stat'} or metadata['source_sha256']!=source_hash or metadata['overlay_sha256']!=overlay_hash or metadata['merged_sha256']!=merged_hash or metadata['source_stat']!=ident(ss) or metadata['merged_stat']!=ident(ms): raise ValueError('existing merged sidecar mismatch')
source_actual,source_snapshot=sha(source); merged_actual,merged_snapshot=sha(merged)
if source_actual!=source_hash or merged_actual!=merged_hash or source_snapshot!=snap(ss) or merged_snapshot!=snap(ms): raise ValueError('existing merged or source checksum mismatch')
print(json.dumps({'source':source_snapshot,'merged':merged_snapshot}))
'''


def send_file(adb, directory, name, path, state_dir):
    """Resume chunks and never overwrite an existing foreign final file."""
    expected = sha(path)
    existing = upload.remote_hash(adb, directory, name)
    partial = name + '.' + expected + '.partial'
    if existing == expected:
        upload.finish_transfer(adb, directory, partial, name, expected, state_dir)
        return
    marker_hash = upload.digest(('STS2_TEXTURE_UPLOAD_PENDING_V1:' + expected).encode())
    if existing is not None and existing != marker_hash: raise RuntimeError('foreign staged file: ' + name)
    owner = upload.transfer_partial(adb, directory, partial, path, expected, state_dir)
    upload.remote(adb, directory, 'publish', partial, name, expected, *owner)
    if upload.remote_hash(adb, directory, name) != expected: raise RuntimeError('staged final checksum mismatch')
    upload.finish_transfer(adb, directory, partial, name, expected, state_dir)


def install(args, build, adb):
    if build['report']['texture']['verified_spine_loader'] and not getattr(args, 'allow_unverified_spine_binary', False):
        raise ValueError('Spine binary is not bound to the audited source; explicit opt-in required')
    import tempfile
    root = args.device_root
    # First verify the existing root without creating parent directories.
    probe = 'import os,sys; f=os.open("/",os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW);\nfor p in sys.argv[1][1:].split("/"):\n n=os.open(p,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=f); os.close(f); f=n\nos.close(f)'
    adb.run(shlex.join(['python3', '-c', probe, root]))
    reuse = getattr(args, 'reuse_main', False)
    overlay_id = build['report']['texture']['output_sha256']
    snapshots = {}
    if reuse:
        response = adb.run(shlex.join(['python3', '-c', REUSE_CHECK, root, args.device_source_pck, build['report']['input_sha256']['source_pck'], overlay_id, build['merged_id']]))
        snapshots = json.loads(response)
        if set(snapshots) != {'source', 'merged'} or any(not isinstance(v, list) or len(v) != 6 or not all(isinstance(x, int) for x in v) for v in snapshots.values()):
            raise ValueError('invalid device main identity response')
    else:
        upload.upload(adb, build['texture'], build['texture_report'], root + '/textures', args.state_dir)
    stage = root + '/.install-' + build['patch_id'] + '-' + build['merged_id'] + ('-reuse' if reuse else '')
    # remote_hash creates only the last component after securely traversing parents.
    upload.remote_hash(adb, stage, '.probe')
    upload.remote_hash(adb, stage + '/patch', '.probe')
    # Ensure expected directories exist; never replace an existing file.
    for d in ('patches', 'merged'):
        upload.remote_hash(adb, root + '/' + d, '.probe')
    with tempfile.TemporaryDirectory(prefix='sts2-install-') as tmp:
        helper = Path(tmp) / 'install.py'; helper.write_text(REMOTE)
        helper_files = [('install.py', helper)]
        if not reuse: helper_files += [('merge.py', MERGE), ('texture-report.json', build['texture_report'])]
        for name, path in helper_files: send_file(adb, stage, name, path, args.state_dir)
        for name in sorted(FILES | {'manifest.json'}): send_file(adb, stage + '/patch', name, build['patch'] / name, args.state_dir)
    command = ['python3', stage + '/install.py', root, args.device_source_pck, args.device_game_dir, args.device_entry,
               args.entry_sha256, build['entry_block_hash'], stage, build['patch_id'], build['merged_id'], build['report']['input_sha256']['source_pck'], overlay_id,
               hashlib.sha256(REMOTE.encode()).hexdigest(), sha(MERGE), sha(build['texture_report']), '1' if reuse else '0', json.dumps(snapshots, separators=(',', ':'))]
    return adb.run(shlex.join(command))


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('target', 'device-root', 'device-source-pck', 'device-game-dir', 'device-entry', 'entry-sha256', 'build-dir', 'state-dir'):
        p.add_argument('--' + name, required=True)
    p.add_argument('--plan', action='store_true', help='validate locally without connecting or writing')
    p.add_argument('--reuse-main', action='store_true', help='require existing verified merged pack; transfer only patch and helper')
    p.add_argument('--allow-unverified-spine-binary', action='store_true', help='accept that the installed Spine binary is not bound to the audited source')
    a = p.parse_args(argv)
    try:
        b = validate(a)
        if b['report']['texture']['verified_spine_loader']:
            print('Spine risk: the installed binary has not been bound to the audited source.', file=sys.stderr)
        if a.plan:
            print(json.dumps({'target': a.target, 'root': a.device_root, 'texture_sha256': b['report']['texture']['output_sha256'], 'merged_sha256': b['merged_id'], 'patch_sha256': b['patch_id'], 'reuse_main': a.reuse_main, 'state_dir': a.state_dir, 'activation_order': ['active-patch'] if a.reuse_main else ['active-texture', 'active-patch'], 'cleanup': 'remove verified stage and unused uploaded overlay; old patches require manual inspection'}, indent=2))
        else:
            print(install(a, b, upload.Adb(a.target)))
            print('Old patches are retained; inspect with cleanup_patch.py before any removal.')
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as exc:
        print('install failed: ' + str(exc), file=sys.stderr); return 1
    return 0


if __name__ == '__main__': sys.exit(main())
