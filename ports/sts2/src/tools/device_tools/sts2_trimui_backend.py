#!/usr/bin/env python3
# INPUT: fixed TrimUI STS2 v0.110.1 install, selected renderer and shared profile.
# OUTPUT: one GLES session or a Vulkan session with private Weston and mounts.
# POS: invoked only after the port's LÖVE settings UI returns a validated choice.
import ctypes,hashlib,json,os,pathlib,select,shutil,signal,subprocess,sys,tempfile,time
B=pathlib.Path('/mnt/SDCARD/Data/ports/sts2-v110')
S=B/'vulkan-support'
P=pathlib.Path('/mnt/UDISK/sts2-vulkan-game-profile-20261030')
MANIFEST='b1fa62e9518a807e3085a3c48b2f78ecce9e8f889459ca6e91c6c82c9b6025fa'
ENGINE='bf9e9620201f030e587c6006f0d9d488c91312e43dddebdc96b20f0dbe07935d'
REQUIRED={
 B/'.install-manifest.json':MANIFEST,
 B/'data_sts2_linuxbsd_arm64/sts2.dll':'543110f1286d71b7391c4a5fcc1df75212fcc3b74c763a09f4413e57acfc0b67',
 B/'data_sts2_linuxbsd_arm64/sts2_compat.dll':'df88e6ae4bbb546786f078f9d3368eb064539a7ae7893f89b6a69f4aa75f9d21',
 B/'data_sts2_linuxbsd_arm64/GodotSharp.dll':'f25b38747f64bc2fef5b5cd9097851dbc1fefb910dc0110bc61da7b37fa07594',
 B/'port_compat.pck':'ced8446fe95c212b26181fc61f27ebe2f6b4f2e8066968a72df03ed68beab3bc'}
GLES={
 B/'godot.mono':'d916065a05ef24aedcd66af08862638577fda54d172c89df1e83183e11304645',
 B/'gamedata/libs/libSDL2-2.0.so.0':'dc5e0118948e2a9e38978bb469c9db98f8083c21c928c56ab204bfd59b219166'}
VK={
 S/'godot_4.5.mono.aarch64.squashfs':'94710ab1955d41158937088dd026fb83fe15762c37fa264b63a83ec63ea2be14',
 S/'bin/wayland-session-sts2-v2.py':'baf048382f47955222b748038c09d68c81d22379dd2506c1acfa4e59c2e7b13a',
 S/'portable-wayland/manifest.json':'e3fe9d785df76a8c34e77b50a8a68a517786b02833ba235c31e570e84606833b',
 S/'portable-wayland/libvulkan.so.1':'5e6763d9f8bf2a1984d01222bddc2f6c46663a5b46f6bd945ee457a7d63471fa',
 S/'portable-wayland/libSDL2-2.0.so.0':'81f629d6b07d603e00702c02ab02ebf9d6ee5690e8a4d3a8b3eed28816c37fb7',
 S/'vulkan-wsi/libVkLayer_window_system_integration.so':'2b0084f9cf6f17d142d5c75b4900e82a30cafb1b7cfa75515024cb974025c58c',
 S/'vulkan-wsi/VkLayer_window_system_integration.json':'4d40c4b5a2366237cff3b7d366b8aee1766226abf6a7bd9f1846a0dd2382fb82',
 pathlib.Path('/mnt/SDCARD/Apps/PortMaster/PortMaster/libs/weston_pkg_0.2.squashfs'):'0bccaeebc11296bb1fe4278c9677cb82965c5a04bcd63745fa09d78228bc1a93'}

def digest(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
def check(entries):
 for p,h in entries.items():
  if p.is_symlink() or not p.is_file() or digest(p)!=h:raise ValueError('runtime identity mismatch: '+str(p))
def no_running_game():
 for p in pathlib.Path('/proc').iterdir():
  if not p.name.isdecimal():continue
  try:name=os.path.basename(os.readlink(str(p/'exe'))).lower()
  except OSError:continue
  if name=='mainui' or 'godot' in name or name in ('unityloader','wp_weston'):raise ValueError('display or game already in use: '+name)
def implicit_manifest(source,library):
 layer=json.loads(source.read_text())
 if layer['layer']['name']!='VK_LAYER_RUDROID_wayland':raise ValueError('unexpected WSI layer')
 layer['layer']['library_path']=str(library)
 layer['layer']['enable_environment']={'SLL_GODOT_WSI':'1'};layer['layer']['disable_environment']={'SLL_GODOT_WSI_DISABLE':'1'}
 return layer
def xdg_data_dirs(share):
 return str(share)+':/usr/local/share:/usr/share'
def apply_weston_composition(env):
 mode=env.get('SLL_WESTON_COMPOSITION','on')
 if mode not in ('on','off'):raise ValueError('invalid Weston composition selection')
 if mode=='off':env.pop('RUDROID_WAYLAND_FORCE_RENDERER',None)
 else:env['RUDROID_WAYLAND_FORCE_RENDERER']='1'
def configure_gles(env):
 for name in tuple(env):
  if name.startswith('VK_') or name in ('WAYLAND_DISPLAY','WAYLAND_SOCKET','RUDROID_WAYLAND_FORCE_RENDERER','RUDROID_VULKAN_WSI_LIBRARY','SLL_GODOT_WSI','SLL_GODOT_WSI_DISABLE','DISABLE_WSI_LAYER'):env.pop(name,None)
 env['SDL_VIDEODRIVER']='kmsdrm';env['LD_LIBRARY_PATH']=str(B/'gamedata/libs')+':'+str(B/'data_sts2_linuxbsd_arm64')+':/usr/lib:/usr/lib64:/usr/trimui/lib:/mnt/SDCARD/System/lib'
def prepare_gles_view(view):
 # Keep res:// external libraries available from the private input cwd.
 for name in ('SlayTheSpire2.pck','data_sts2_linuxbsd_arm64','GodotSharp','addons','bootstrap.pck','port_compat.pck','release_info.json','libsteam_api64.so'):
  os.symlink(str(B/name),str(view/name))
 (view/'input_remap.cfg').write_text('[buttons]\na = BUTTON_A\nb = BUTTON_B\nx = BUTTON_X\ny = BUTTON_Y\n')
def run_forwarded(command,cwd,env):
 process=subprocess.Popen(command,cwd=cwd,env=env)
 def forward(sig,frame):
  if process.poll() is None:process.send_signal(sig)
 old={sig:signal.signal(sig,forward) for sig in (signal.SIGTERM,signal.SIGHUP,signal.SIGINT)}
 try:return process.wait()
 finally:
  for sig,handler in old.items():signal.signal(sig,handler)
def run_isolated_session(command, cwd, env):
 # A PID namespace makes the Weston and game sessions children of one owned
 # init. A guardian kills/waits for that init if the launcher disappears.
 libc=ctypes.CDLL(None,use_errno=True)
 read_fd,write_fd=os.pipe()
 guardian=os.fork()
 if guardian==0:
  # Keep the guardian alive when the bounded logger signals the owner group.
  os.setsid()
  os.close(write_fd); data=b''
  try:
   while True:
    chunk=os.read(read_fd,128)
    if not chunk:break
    data+=chunk
   if data:
    pid,start=map(int,data.split())
    fields=pathlib.Path('/proc',str(pid),'stat').read_text().rsplit(')',1)[1].split()
    if int(fields[19])==start:
     fd=libc.syscall(434,pid,0)
     if fd<0:raise OSError(ctypes.get_errno(),'pidfd_open')
     fields=pathlib.Path('/proc',str(pid),'stat').read_text().rsplit(')',1)[1].split()
     if int(fields[19])==start:
      if libc.syscall(424,fd,signal.SIGTERM,0,0)<0:raise OSError(ctypes.get_errno(),'pidfd_send_signal')
      poll=select.poll();poll.register(fd,select.POLLIN)
      if not poll.poll(15000):
       if libc.syscall(424,fd,signal.SIGKILL,0,0)<0:raise OSError(ctypes.get_errno(),'pidfd_send_signal')
       if not poll.poll(10000):
        print('[ERROR] waiting for owned compositor to exit before returning to frontend',flush=True)
        while not poll.poll(10000):pass
     os.close(fd)
  except FileNotFoundError:
   pass # The namespace init already exited normally.
  except (OSError,ValueError) as error:
   print('[ERROR] compositor guardian:',error,flush=True)
   # Never return the display while the identified init may still be alive.
   if data and 'pid' in locals() and 'start' in locals():
    while True:
     try:
      fields=pathlib.Path('/proc',str(pid),'stat').read_text().rsplit(')',1)[1].split()
      if int(fields[19])!=start or fields[0] in ('Z','X'):break
     except FileNotFoundError:break
     except (OSError,ValueError,IndexError):pass
     time.sleep(1)
  os._exit(0)
 os.close(read_fd); owner=os.getpid(); child=os.fork()
 if child==0:
  os.setsid();os.chdir(cwd)
  if libc.prctl(1,signal.SIGKILL,0,0,0)!=0 or os.getppid()!=owner:os._exit(125)
  if libc.unshare(0x20000000)!=0:os._exit(125)
  intermediate_pid=int(os.readlink('/proc/self'))
  init=os.fork()
  if init==0:
   if libc.prctl(1,signal.SIGKILL,0,0,0)!=0:os._exit(125)
   status=pathlib.Path('/proc/self/status').read_text()
   if int(next(line.split()[1] for line in status.splitlines() if line.startswith('PPid:')))!=intermediate_pid:os._exit(125)
   pid=int(os.readlink('/proc/self'))
   start=pathlib.Path('/proc',str(pid),'stat').read_text().rsplit(')',1)[1].split()[19]
   os.write(write_fd,('%d %s\n'%(pid,start)).encode());os.close(write_fd)
   if libc.unshare(0x00020000)!=0:os._exit(125)
   if libc.mount(None,b'/',None,0x44000,None)!=0:os._exit(125)
   if libc.mount(b'proc',b'/proc',b'proc',0x0e,None)!=0:os._exit(125)
   os.execvpe(command[0],command,env)
  os.close(write_fd)
  def forward(sig,frame):
   try:os.kill(init,sig)
   except ProcessLookupError:pass
  for sig in (signal.SIGTERM,signal.SIGHUP,signal.SIGINT):signal.signal(sig,forward)
  while True:
   try:_,status=os.waitpid(init,0);break
   except InterruptedError:continue
  code=os.waitstatus_to_exitcode(status);os._exit(code if code>=0 else 128-code)
 # Keep this endpoint open while the owner and game are alive. EOF tells the
 # guardian the owner has exited or the child has completed.
 def forward(sig,frame):
  try:os.kill(child,sig)
  except ProcessLookupError:pass
 previous={sig:signal.signal(sig,forward) for sig in (signal.SIGTERM,signal.SIGHUP,signal.SIGINT)}
 try:
  while True:
   try:_,status=os.waitpid(child,0);break
   except InterruptedError:continue
 finally:
  for sig,handler in previous.items():signal.signal(sig,handler)
  os.close(write_fd)
  _,guardian_status=os.waitpid(guardian,0)
 if os.waitstatus_to_exitcode(guardian_status)!=0:raise RuntimeError('owned compositor did not exit')
 return os.waitstatus_to_exitcode(status)

def main():
 if len(sys.argv)!=2 or sys.argv[1] not in ('vulkan','gles'):raise ValueError('invalid graphics selection')
 mode=sys.argv[1]
 check(REQUIRED)
 manifest=json.loads((B/'.install-manifest.json').read_text());main_pack=B/'SlayTheSpire2.pck'
 if main_pack.is_symlink() or not main_pack.is_file() or main_pack.stat().st_size!=727335372 or manifest['files']['SlayTheSpire2.pck']['sha256']!='9caf3fa8448a7729dc11fa4897b9756e30fcdeadb56acbdb1cba9acc3e7b6fad':raise ValueError('main pack not the installed release')
 if any(p.is_symlink() or not p.is_dir() for p in (P,P/'data',P/'data/SlayTheSpire2')):raise ValueError('shared game profile missing')
 for p in (P/'config',P/'cache'):
  p.mkdir(mode=0o700,exist_ok=True)
  if p.is_symlink() or not p.is_dir():raise ValueError('unsafe profile directory: '+str(p))
 no_running_game()
 env=dict(os.environ)
 if mode=='vulkan':apply_weston_composition(env)
 env.update(XDG_DATA_HOME=str(P/'data'),XDG_CONFIG_HOME=str(P/'config'),XDG_CACHE_HOME=str(P/'cache'),
  DOTNET_SYSTEM_GLOBALIZATION_INVARIANT='1',SLL_LOONG_FOCUS_COMPAT='1',SLL_HEAP_TRIM='1',
  SLL_UI_DIAG='0',SLL_UI_CONTROL='0',SLL_TEXTURE_DIAG='0',SLL_ASSET_DIAG='0',SLL_MALLOC_DIAG='0',SLL_INPUT_DIAG='0',SLL_FIRST_CARD_TRACE='0',SLL_DEBUG='0')
 overlay=env.get('SLL_PERF_OVERLAY','off')
 if overlay not in ('on','off') or env.get('SLL_DIAGNOSTICS','off') not in ('on','off'):raise ValueError('invalid diagnostic selection')
 env['PORTKIT_PERF_OVERLAY']='1' if overlay=='on' else '0'
 for name in ('VK_INSTANCE_LAYERS','VK_LAYER_PATH','VK_ADD_LAYER_PATH','VK_DRIVER_FILES','VK_ICD_FILENAMES','SLL_GODOT_WSI','SLL_GODOT_WSI_DISABLE','RUDROID_VULKAN_WSI_LIBRARY','VK_LOADER_DEBUG','DISABLE_WSI_LAYER','LD_PRELOAD'):
  env.pop(name,None)
 for k in ('SLL_GPU_PARTICLES','SLL_SHADER_COMPAT','SLL_COMBAT_WARMUP','SLL_WARMUP_FRAMES','SLL_CACHE_PROTECT'):
  env.setdefault(k,{'SLL_GPU_PARTICLES':'on','SLL_SHADER_COMPAT':'on','SLL_COMBAT_WARMUP':'safe','SLL_WARMUP_FRAMES':'2','SLL_CACHE_PROTECT':'on'}[k])
 if mode=='gles':
  check(GLES)
  if not os.access(B/'godot.mono',os.X_OK):raise ValueError('SDL engine not executable')
  configure_gles(env)
  print('[STS2] engine=SDL Godot renderer=OpenGL ES 3',flush=True)
  with tempfile.TemporaryDirectory(prefix='sts2-gles-',dir='/tmp') as tmp:
   view=pathlib.Path(tmp)
   prepare_gles_view(view)
   return run_forwarded([str(B/'godot.mono'),'--display-driver','sdl2','--rendering-driver','opengl3','--rendering-method','gl_compatibility','--resolution','1280x720','--main-pack',str(view/'SlayTheSpire2.pck'),'--force-steam','off'],cwd=tmp,env=env)
 check(VK)
 libc=ctypes.CDLL(None,use_errno=True)
 if libc.unshare(0x00020000)!=0:raise OSError(ctypes.get_errno(),'unshare mount namespace')
 subprocess.run(['mount','--make-rprivate','/'],check=True,timeout=10)
 root=pathlib.Path(tempfile.mkdtemp(prefix='sts2-vulkan-',dir='/tmp'));view=root/'view';image=root/'image';logs=root/'logs';share=root/'share'
 for p in (view,image,logs,share):p.mkdir(mode=0o700)
 helper=None
 try:
  subprocess.run(['mount','-o','loop,ro,exec,nosuid,nodev',str(S/'godot_4.5.mono.aarch64.squashfs'),str(image)],check=True,timeout=15)
  for name in ('SlayTheSpire2.pck','data_sts2_linuxbsd_arm64','GodotSharp','addons','bootstrap.pck','port_compat.pck','release_info.json','libsteam_api64.so'):
   os.symlink(str(B/name),str(view/name))
  exe=view/'godot.mono';exe.touch(mode=0o700)
  subprocess.run(['mount','--bind',str(image/'godot45.mono.aarch64'),str(exe)],check=True,timeout=10)
  if digest(exe)!=ENGINE:raise ValueError('official engine identity mismatch')
  (view/'override.cfg').write_text('[rendering]\nrenderer/rendering_method="mobile"\nrenderer/rendering_method.mobile="mobile"\nrendering_device/fallback_to_opengl3=false\n')
  implicit=share/'vulkan/implicit_layer.d';implicit.mkdir(parents=True,mode=0o700)
  layer=implicit_manifest(S/'vulkan-wsi/VkLayer_window_system_integration.json',S/'vulkan-wsi/libVkLayer_window_system_integration.so')
  (implicit/'sts2-wsi.json').write_text(json.dumps(layer,sort_keys=True)+'\n')
  # Retain the standard system data directories: the Vulkan loader finds the
  # device's ICD manifest in /usr/share/vulkan/icd.d.
  env.update(XDG_DATA_DIRS=xdg_data_dirs(share),SLL_GODOT_WSI='1',DISABLE_WSI_LAYER='1',LD_LIBRARY_PATH=str(B/'data_sts2_linuxbsd_arm64')+':/usr/lib:/usr/trimui/lib')
  cmd=['python3','-u',str(S/'bin/wayland-session-sts2-v2.py'),'--runtime',str(S),'--weston-image','/mnt/SDCARD/Apps/PortMaster/PortMaster/libs/weston_pkg_0.2.squashfs','--log-dir',str(logs),'--',str(exe),'--display-driver','wayland','--rendering-method','mobile','--rendering-driver','vulkan','--resolution','1280x720','--main-pack',str(view/'SlayTheSpire2.pck'),'--force-steam','off']
  print('[STS2] engine=PortMaster Godot 4.5 RC renderer=Vulkan Mobile composition='+env.get('SLL_WESTON_COMPOSITION','on')+' force-renderer='+('1' if env.get('RUDROID_WAYLAND_FORCE_RENDERER')=='1' else '0'),flush=True)
  result=run_isolated_session(cmd,str(view),env)
  return result
 finally:
  # Keep only short Weston error context in the caller's bounded log.
  for name in ('weston.log','weston-stderr.log'):
   p=logs/name
   if p.is_file() and (locals().get('result',1)!=0 or os.environ.get('SLL_DIAGNOSTICS')=='on'):
    print('[WESTON] '+p.read_text(errors='replace')[-20000:],flush=True)
  for target in (view/'godot.mono',image):
   if os.path.ismount(target) and libc.umount2(os.fsencode(target),0)!=0:print('[ERROR] private unmount failed '+str(target),flush=True)
  if any(os.path.ismount(p) for p in (view/'godot.mono',image)):print('[ERROR] private mounts remain '+str(root),flush=True)
  else:shutil.rmtree(root)
if __name__=='__main__':
 try:raise SystemExit(main())
 except (OSError,ValueError,KeyError,TypeError,subprocess.SubprocessError) as error:
  print('[ERROR] STS2 backend: '+str(error),file=sys.stderr,flush=True);raise SystemExit(1)
