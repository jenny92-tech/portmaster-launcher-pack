#!/usr/bin/env python3
# INPUT: Prepared installation and system or shared Pack private Wayland session.
# OUTPUT: Hash-verified native session, isolated profile, bounded failure log.
# POS: Title runner; optional compositor lifetime is owned by the shared helper.
from pathlib import Path
import argparse,ctypes,fcntl,hashlib,json,os,re,selectors,shutil,signal,subprocess,sys,time

TITLE='0100a0800b83a000'
BUILD='02242ae4e90dcf439210fe87f692de05'

def checked_file(root,relative):
    part=Path(relative)
    if not isinstance(relative,str) or part.is_absolute() or '..' in part.parts or part.as_posix()!=relative:
        raise ValueError('Unsafe installation file path')
    path=root/part
    if path.is_symlink() or any(p.is_symlink() for p in path.parents if p!=root.parent):
        raise ValueError('Linked installation input: '+relative)
    if not path.is_file():raise ValueError('Missing installation input: '+relative)
    return path

def digest(path):
    value=hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda:stream.read(1024*1024),b''):value.update(block)
    return value.hexdigest()

def checked_profile(value):
    if not isinstance(value,str):raise ValueError('An explicit stable profile path is required')
    profile=Path(value)
    if not profile.is_absolute() or '..' in profile.parts or any(c in value for c in '\0\r\n'):
        raise ValueError('Profile path must be absolute')
    if any(path.is_symlink() for path in [profile,*profile.parents]):raise ValueError('Linked profile path')
    return profile

def existing_profile(default):
    # Prefer this player's existing stable profile, independently of board/GPU.
    # Historical installation paths are data locations, never driver selectors.
    candidates=list(dict.fromkeys([default,'/userdata/soulknight_ns/profile','/mnt/UDISK/soulknight_ns/profile']))
    found=[checked_profile(p)for p in candidates if Path(p).is_dir()]
    if len(found)>1:raise ValueError('Multiple existing profiles; select --profile explicitly')
    if found:return found[0]
    for p in candidates:
        path=checked_profile(p)
        anchor=next((base for base in (Path('/userdata'),Path('/mnt/UDISK')) if path.is_relative_to(base)),None)
        if anchor is None:anchor=next(x for x in path.parents if x.exists())
        # /mnt being writable says nothing about whether UDISK is mounted.
        if anchor!=Path('/') and anchor.is_dir() and os.access(anchor,os.W_OK):return path
    data=os.environ.get('XDG_DATA_HOME')
    if not data:raise ValueError('No persistent profile location; select --profile explicitly')
    return checked_profile(str(Path(data)/'soulknight_ns/profile'))

def preflight(root,profile_override=None):
    if root.is_symlink():raise ValueError('Linked installation root')
    root=root.resolve(strict=True)
    manifest=json.loads(checked_file(root,'installation.json').read_text())
    if manifest['title_id']!=TITLE or manifest['game_build']!=BUILD:raise ValueError('Wrong game identity')
    identity=manifest['runtime_identity']
    if (identity['profile'],identity['kind'],identity['title_id'],identity['game_build'])!=('Release','linux-native-vulkan',TITLE,BUILD):
        raise ValueError('Wrong Release runtime identity')
    files=manifest['files']
    required={'runtime/soulknight-ns','libexec/launch.py','shaders/shader_index.bin','fonts/NotoSansCJKsc-Regular.otf',
              'runtime/vulkan-wsi/libVkLayer_window_system_integration.so','RomFS/Data/globalgamemanagers'}
    required.update('native/'+name+'.'+suffix for name in ('main','subsdk0','sdk') for suffix in ('patched.bin','fixups.tsv','gates.tsv'))
    if not isinstance(files,dict) or not required<=files.keys():raise ValueError('Incomplete prepared installation')
    for relative,wanted in files.items():
        if not isinstance(wanted,str) or not re.fullmatch('[0-9a-f]{64}',wanted) or digest(checked_file(root,relative))!=wanted:
            raise ValueError('Changed installation input: '+relative)
    profile=checked_profile(str(profile_override)if profile_override is not None else manifest.get('profile'))
    return root,profile

def wayland_endpoint(env):
    display=env.get('WAYLAND_DISPLAY','')
    if not display:raise ValueError('No active Wayland session')
    endpoint=Path(display)
    if not endpoint.is_absolute():
        if not env.get('XDG_RUNTIME_DIR'):raise ValueError('No Wayland runtime directory')
        endpoint=Path(env['XDG_RUNTIME_DIR'])/endpoint
    if not endpoint.is_socket():raise ValueError('Wayland endpoint is not a live socket')
    return endpoint

def portable_library_path(root,env):
    """Accept only the three paths constructed by the shared Pack helper.

    The title normally clears inherited loader paths. Its private session needs
    the verified SDL/Vulkan clients plus the owned mounted Wayland dependencies;
    unrelated inherited directories still must not reach the native game.
    """
    endpoint=wayland_endpoint(env)
    owned=endpoint.parent.parent
    if (not endpoint.is_absolute() or endpoint.parent.name!='xdg'
        or endpoint.name!='rudroid-vulkan' or str(owned)!=env.get('PORTKIT_WAYLAND_SESSION_ROOT')
        or not owned.name.startswith('rudroid-wayland-')):
        raise ValueError('Not a shared Pack private Wayland endpoint')
    package=owned/'weston'
    expected=[str(root/'runtime/portable-wayland'),str(package/'lib_aarch64'),str(package/'lib_aarch64/extra_wayland')]
    if (env.get('LD_LIBRARY_PATH','').split(':')[:3]!=expected
        or not (root/'runtime/portable-wayland/manifest.json').is_file()
        or not os.path.ismount(package)):
        raise ValueError('Incomplete shared Pack client library environment')
    return ':'.join(expected)

def graphics_probe(root):
    # Match the game's loader scope, including the private helper's three
    # audited paths. A probe succeeding with an unrelated inherited SDL would
    # say nothing about the libraries actually used after launch() sanitizes.
    env=dict(os.environ);libraries=None
    endpoint=Path(env.get('WAYLAND_DISPLAY',''))
    if endpoint.is_absolute() and endpoint.parent.name=='xdg' and endpoint.parent.parent.name.startswith('rudroid-wayland-'):
        libraries=portable_library_path(root,env)
    for key in ('LD_LIBRARY_PATH','LD_PRELOAD'):env.pop(key,None)
    if libraries:env['LD_LIBRARY_PATH']=libraries
    manifest=json.loads(checked_file(root,'installation.json').read_text())
    names=['bin/graphics-probe','libexec/graphics-probe.sh']
    if env.get('RUDROID_VULKAN_WSI_LIBRARY'):
        expected=root/'runtime/vulkan-wsi/libVkLayer_window_system_integration.so'
        # Firmware starts through aliases such as /roms/ports or /mnt/SDCARD.
        # Compare the resolved file, just as the runner resolves its root; a
        # different spelling must not reject the same hash-verified library.
        selected=Path(env['RUDROID_VULKAN_WSI_LIBRARY'])
        if not selected.is_absolute() or selected.resolve(strict=True)!=expected:raise ValueError('Unexpected probe WSI library')
        env['RUDROID_VULKAN_WSI_LIBRARY']=str(expected)
        env['VK_LAYER_PATH']=str(expected.parent)
        names+=['runtime/vulkan-wsi/libVkLayer_window_system_integration.so','runtime/vulkan-wsi/VkLayer_window_system_integration.json']
    for name in names:
        if digest(checked_file(root,name))!=manifest['files'].get(name):raise ValueError('Changed graphics probe input: '+name)
    command=['/bin/bash',str(root/'libexec/graphics-probe.sh'),str(root/'bin/graphics-probe')]
    os.execve(command[0],command,env)

def low_memory_mode(portable_session=False):
    try:return int(next(line.split()[1]for line in Path('/proc/meminfo').read_text().splitlines()if line.startswith('MemTotal:')))<1280*1024
    except(OSError,StopIteration,ValueError):return portable_session

def require_temp_storage(profile):
    existing=next(path for path in [profile,*profile.parents] if path.exists())
    if shutil.disk_usage(existing).free<768*1024*1024:
        raise ValueError('低内存模式需要至少 768 MiB 可用存储空间，请清理后重试。')

def portable_command(root,profile,image,aspect,display_check=False):
    try:wayland_endpoint(os.environ)
    except ValueError:pass
    else:raise ValueError('Private Wayland must not replace an existing compositor')
    if low_memory_mode(True):require_temp_storage(profile)
    if not image.is_file():raise ValueError('Missing PortMaster Weston image')
    helper=checked_file(root,'libexec/wayland-session.py')
    checked_file(root,'runtime/portable-wayland/manifest.json')
    client=[sys.executable,str(root/'libexec/launch.py'),str(root),'--profile',str(profile),'--portable-session','--aspect',aspect]
    if display_check:client.append('--display-check')
    return [sys.executable,str(helper),'--runtime',str(root/'runtime'),
            '--weston-image',str(image),'--log-dir',str(profile/'logs/wayland'),'--',*client]

def launch(root,profile,aspect='4:3',portable_session=False,presentation='wsi',video_driver='wayland'):
    if aspect not in ('16:9','4:3'):raise ValueError('Aspect must be 16:9 or 4:3')
    if presentation not in ('native','wsi'):raise ValueError('Unknown presentation route')
    if video_driver=='wayland':wayland_endpoint(os.environ)
    elif presentation!='native' or video_driver!='x11' or not os.environ.get('DISPLAY'):
        raise ValueError('No validated native display backend')
    libraries=portable_library_path(root,os.environ) if portable_session else None
    low_memory=low_memory_mode(portable_session)
    if low_memory:require_temp_storage(profile)
    os.umask(0o077)
    for path in reversed([profile,*profile.parents]):
        if path.is_symlink():raise ValueError('Linked profile path')
    profile.mkdir(parents=True,exist_ok=True)
    lock=os.open(profile/'session.lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
    fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    for name in ('save','identity','cache','temp','logs'):
        path=profile/name
        if path.is_symlink():raise ValueError('Linked profile directory')
        path.mkdir(exist_ok=True)
    env={k:v for k,v in os.environ.items() if not k.startswith(('DM_','D2R_'))}
    for key in ('LD_LIBRARY_PATH','LD_PRELOAD','VK_ICD_FILENAMES','VK_LAYER_PATH','VK_INSTANCE_LAYERS'):env.pop(key,None)
    if libraries:env['LD_LIBRARY_PATH']=libraries
    diagnostics=env.get('SOULKNIGHT_DIAGNOSTICS')=='1'
    env.update(DM_SAVE=str(profile/'save'),DM_PROFILE_DIR=str(profile/'identity'),DM_TEMP=str(profile/'temp'),
               DM_ROMFS=str(root/'RomFS'),DM_SHADER_ROOT=str(root/'shaders'),DM_SHARED_FONT=str(root/'fonts/NotoSansCJKsc-Regular.otf'),
               SDL_VIDEODRIVER=video_driver,
               DM_SHADER_IDENTITY_CODE='1',DM_SHADER_IDENTITY_CACHE='1',DM_QUERY_RESET_RANGE='1',
               DM_SOUL_LOW_RESOLUTION='1',DM_OPMODE='0',DM_RENDER_AREA_CLIP='1',DM_UNIFORM_SNAPSHOT='1',
               DM_UNIFORM_SHADER_BARRIER='1',DM_SOUL_ASPECT=aspect)
    if presentation=='wsi':env['DM_WAYLAND_WSI_DIR']=str(root/'runtime/vulkan-wsi')
    if low_memory:
        # Reclaim cold module/guest pages through the owned cache filesystem.
        # Dense buffers retain the accepted uniform snapshot/barrier path;
        # only completed idle upload buffers are eligible for cache eviction.
        env.update(DM_LINUX_MODULE_FILE_BACKING='1',DM_TEMP_CACHE_IDLE_FRAMES='300',
                   DM_LINUX_SNAPSHOT_CACHE=str(profile/'cache'),DM_LINUX_SHADER_FILE_BACKING='1',
                   DM_LINUX_MALLOC_TRIM='1',DM_LINUX_ALIAS_FILE_BACKING=str(profile/'cache'))
    trace=None
    if diagnostics:
        trace=profile/'logs'/('run-'+str(time.monotonic_ns()));trace.mkdir(mode=0o700)
        (trace/'frames').mkdir()
        env.update(DM_FRAME_DIR=str(trace/'frames'),DM_CAPTURE_FRAMES='1',
                   DM_LINUX_INPUT_CONTROL=str(trace/'input-control'),DM_MEMORY_REPORT=str(trace/'memory.json'))
    # Own only this child. Normal signals request the original guest cleanup;
    # abrupt loss of the launcher cannot leave a detached game behind.
    parent=os.getpid()
    def setup():
        if ctypes.CDLL(None).prctl(1,signal.SIGKILL,0,0,0):os._exit(126)
        if os.getppid()!=parent:os._exit(125)
    child=subprocess.Popen([str(root/'runtime/soulknight-ns'),str(root/'native')],cwd=profile/'cache',env=env,
                           stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True,preexec_fn=setup)
    requested=[None]
    def stop(number,frame):
        if child.poll() is None:
            if requested[0] is None:requested[0]=time.monotonic();child.terminate()
    for number in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP):signal.signal(number,stop)
    poll=selectors.DefaultSelector();poll.register(child.stdout,selectors.EVENT_READ)
    tail=bytearray();full=None
    try:
        if diagnostics:
            session={'title_id':TITLE,'kind':'source-matched-release-diagnostics','active':True,'pid':child.pid,
                     'parent_pid':os.getpid(),'run':str(trace),'runtime':str(root/'runtime/soulknight-ns'),
                     'runtime_sha256':digest(root/'runtime/soulknight-ns'),
                     'boot_id':Path('/proc/sys/kernel/random/boot_id').read_text().strip()}
            (trace/'session.json').write_text(json.dumps(session,indent=2)+'\n')
            marker=profile/'logs/current-session.pending';marker.write_text(json.dumps(session,indent=2)+'\n');marker.replace(profile/'logs/current-session.json')
            full=(trace/'stdout.log').open('xb')
        # EOF can precede process exit. Continue owning the child and its
        # cancellation deadline after the final log descriptor closes.
        while poll.get_map() or child.poll() is None:
            if requested[0] is not None and time.monotonic()-requested[0]>20 and child.poll() is None:child.kill()
            for key,_ in poll.select(.1):
                block=os.read(key.fileobj.fileno(),8192)
                if not block:poll.unregister(key.fileobj);continue
                tail.extend(block);del tail[:-65536]
                if full:full.write(block)
        status=child.wait()
        if trace:
            completed={'returncode':status,'owned_child_reaped':True}
            (trace/'exit.json').write_text(json.dumps(completed)+'\n')
            session.update(completed,active=False)
            marker=profile/'logs/current-session.pending';marker.write_text(json.dumps(session,indent=2)+'\n');marker.replace(profile/'logs/current-session.json')
        if status or re.search(rb'(?m)^(?:\[(?:ERROR|FATAL)\]|\[nvn-vulkan\] (?:STOP|ERROR)|LINUX_(?:GUEST_SIGNAL|MEMORY_LIMIT))',tail):
            path=profile/'logs/last-error.log'
            if path.is_symlink():raise ValueError('Linked error log')
            path.write_bytes(bytes(tail))
            print('元气骑士_ns 退出异常；日志：'+str(path))
        return status if status>=0 else 128-status
    finally:
        poll.close()
        if full:full.close()
        if child.poll() is None:
            child.terminate()
            try:child.wait(timeout=20)
            except subprocess.TimeoutExpired:child.kill();child.wait()
        os.close(lock)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('installation',type=Path);parser.add_argument('--check',action='store_true');parser.add_argument('--aspect',choices=('16:9','4:3'),default='4:3')
    parser.add_argument('--wayland-image',type=Path)
    parser.add_argument('--portable-session',action='store_true',help=argparse.SUPPRESS)
    parser.add_argument('--display-check',action='store_true',help='Validate the display round trip without starting the game')
    parser.add_argument('--profile',type=Path)
    parser.add_argument('--print-profile',action='store_true',help='Resolve an existing persistent profile without starting the game')
    parser.add_argument('--probe-graphics',action='store_true',help=argparse.SUPPRESS)
    parser.add_argument('--graphics-probe',action='store_true',help=argparse.SUPPRESS)
    parser.add_argument('--presentation',choices=('native','wsi'),default='wsi')
    parser.add_argument('--video-driver',choices=('wayland','x11'),default='wayland')
    args=parser.parse_args()
    if args.graphics_probe:return graphics_probe(args.installation.resolve(strict=True))
    if args.print_profile:
        manifest=json.loads(checked_file(args.installation.resolve(strict=True),'installation.json').read_text())
        print(checked_profile(str(args.profile))if args.profile else existing_profile(manifest['profile']));return 0
    if args.probe_graphics:raise ValueError('Use the launcher --probe-graphics entry')
    root,profile=preflight(args.installation,args.profile)
    if args.check:print('Soul Knight NS preflight passed; game was not started.');return 0
    if args.wayland_image and not args.portable_session:
        # Replace this preflight-only controller, retaining the shell's cleanup
        # ownership and letting the unchanged shared helper own its children.
        command=portable_command(root,profile,args.wayland_image,args.aspect,args.display_check)
        os.execv(command[0],command)
    if args.display_check:
        if args.portable_session:portable_library_path(root,os.environ)
        else:wayland_endpoint(os.environ)
        time.sleep(2)
        print('Soul Knight NS display check passed; game was not started.')
        return 0
    return launch(root,profile,args.aspect,args.portable_session,args.presentation,args.video_driver)

if __name__=='__main__':
    try:raise SystemExit(main())
    except (OSError,ValueError,KeyError) as error:raise SystemExit('元气骑士_ns：'+str(error))
