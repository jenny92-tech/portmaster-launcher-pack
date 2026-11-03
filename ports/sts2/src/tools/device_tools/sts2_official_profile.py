#!/usr/bin/env python3
# INPUT: one of the two installed official-Vulkan device profiles.
# OUTPUT: fail-closed identity, runtime, and display prerequisites before UI.
# POS: read-only device capability check; it never starts a display or game.
import hashlib,os,pathlib,platform,re,select,socket,stat,sys

IMAGE='94710ab1955d41158937088dd026fb83fe15762c37fa264b63a83ec63ea2be14'
PROFILES={
 '90':{'model':b'Rockchip RK3566 RK817 MINILOONG LP4X Board\0','compatible':b'rockchip,rk3566-rk817-tablet\0rockchip,rk3566\0','kernel':'5.10.209','marker':'d5f76b3ec8feee6e42e2c20b4cc276121321119f44cbb49f3e2ab9651fe575bc'},
 '91':{'model':b'sun55iw3\0','compatible':b'allwinner,a523\0arm,sun55iw3p1\0','kernel':'5.15.147','marker':'f0a99723319d4f1e778b4d22cf7123ee1e41ca63650fa7b772b74ca56a314c01'}}

def check_identity(device,model,compatible,kernel,machine):
 p=PROFILES[device]
 if (model,compatible,kernel,machine)!=(p['model'],p['compatible'],p['kernel'],'aarch64'):raise ValueError('unverified hardware or firmware')
def digest(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for block in iter(lambda:f.read(1048576),b''):h.update(block)
 return h.hexdigest()
def checked(p,expected):
 if p.is_symlink() or not p.is_file() or p.stat().st_nlink!=1 or digest(p)!=expected:raise ValueError('runtime identity mismatch: '+str(p))
def available(files,executable=None):
 try:
  for path,sha in files.items():checked(path,sha)
  if executable is not None and not os.access(executable,os.X_OK):return False
  return True
 except (OSError,ValueError):return False
def graphics_capabilities(gles_files,vulkan_files,executable):
 return available(gles_files,executable),available(vulkan_files)
def no_game():
 for p in pathlib.Path('/proc').iterdir():
  if not p.name.isdecimal():continue
  try:name=os.path.basename(os.readlink(str(p/'exe'))).lower()
  except PermissionError:raise ValueError('cannot inspect processes')
  except OSError:continue
  if 'godot' in name or name in ('unityloader','wp_weston'):raise ValueError('another game or compositor is active')
def consume_lease():
 value=os.environ.get('SLL_TRIMUI_LEASE_FD','')
 if not value:return False
 token=os.environ.get('SLL_TRIMUI_LEASE_TOKEN','')
 if not value.isdecimal() or not re.fullmatch('[0-9a-f]{64}',token):raise ValueError('invalid display handoff token')
 fd=int(value)
 if fd<3 or not stat.S_ISFIFO(os.fstat(fd).st_mode) or os.getppid()!=1:raise ValueError('invalid display handoff process')
 cmd=pathlib.Path('/proc/1/cmdline').read_bytes().split(b'\0')
 if cmd[:2]!=[b'/bin/bash',b'/mnt/SDCARD/Roms/PORTS/Je-\xe6\x9d\x80\xe6\x88\xae\xe5\xb0\x96\xe5\xa1\x942[\xe4\xb8\xad].sh']:
  raise ValueError('invalid display handoff parent')
 if not select.select([fd],[],[],2)[0]:raise ValueError('display handoff token unavailable')
 received=os.read(fd,64);os.close(fd)
 if received!=token.encode('ascii'):raise ValueError('display handoff token mismatch')
 return True
def frontend_observation(proc_root,runners,frontends):
 def summarize(pids):
  rows=[]
  for pid in pids[:8]:
   try:
    fields=(proc_root/str(pid)/'stat').read_text().rsplit(')',1)[1].split()
    rows.append('%d:%s:%s'%(pid,fields[1],fields[19]))
   except (OSError,IndexError):rows.append('%d:gone'%pid)
  return ','.join(rows) or '-'
 return ' runners=%d[%s] frontends=%d[%s]'%(len(runners),summarize([p[0] for p in runners]),len(frontends),summarize([p[0] for p in frontends]))
def root_runner(runners):
 # A directly executed, shebang-less command is interpreted by a fork of
 # runtrimui's Bash, retaining its parent's exe and cmdline until it exits.
 roots=[r for r in runners if r[1]==1]
 if len(roots)!=1 or len(runners)>2:return None
 root=roots[0]
 if any(r!=root and r[1]!=root[0] for r in runners):return None
 return root
def frontend_state(proc_root=pathlib.Path('/proc'),leased=False):
 runners=[];frontends=[]
 for proc in proc_root.iterdir():
  if not proc.name.isdecimal():continue
  try:
   exe=os.readlink(str(proc/'exe'))
   args=(proc/'cmdline').read_bytes()
  except PermissionError:raise ValueError('cannot inspect display processes')
  except OSError:continue
  if exe=='/bin/bash' and args==b'/bin/sh\0/usr/trimui/bin/runtrimui.sh\0':
   fields=(proc/'stat').read_text().rsplit(')',1)[1].split()
   runners.append((int(proc.name),int(fields[1]),int(fields[19])))
  if exe=='/usr/trimui/bin/MainUI':
   fields=(proc/'stat').read_text().rsplit(')',1)[1].split()
   frontends.append((int(proc.name),int(fields[1])))
  try:
   with os.scandir(proc/'fd') as fds:
    for fd in fds:
     try:
      if os.readlink(fd.path)=='/dev/dri/card0' and exe not in ('/usr/trimui/bin/MainUI','/usr/trimui/osd/trimui_osdd'):
       raise ValueError('display is held by an unverified process')
     except PermissionError:raise ValueError('cannot inspect display ownership')
     except FileNotFoundError:continue
  except PermissionError:raise ValueError('cannot inspect display ownership')
  except FileNotFoundError:continue
 if leased:
  if frontends:raise ValueError('front-end still holds display after handoff')
  return 'leased'
 runner=root_runner(runners)
 if runner is None or len(frontends)>1 or (frontends and frontends[0][1]!=runner[0]):raise ValueError('unverified front-end runner relationship'+frontend_observation(proc_root,runners,frontends))
 return 'handoff-required'
def main():
 if len(sys.argv)!=2 or sys.argv[1] not in PROFILES:raise ValueError('unknown installed device profile')
 device=sys.argv[1];p=PROFILES[device]
 check_identity(device,pathlib.Path('/proc/device-tree/model').read_bytes(),pathlib.Path('/proc/device-tree/compatible').read_bytes(),platform.release(),platform.machine())
 no_game()
 if device=='90':
  base=pathlib.Path('/roms/ports/sts2-vk-test')
  checked(base/'official-vulkan-profile.json',p['marker'])
  release=pathlib.Path('/etc/os-release').read_text()
  if 'ID=loong\n' not in release or 'VERSION_ID="1.4.0.36"' not in release:raise ValueError('unverified Loong firmware')
  if (base/'active-build').read_text().strip()!='9b9c64f7ae05b8cd8a4a212716eeae4dd2a08b7a5f7f8a0640cbaa3e8c2e9e1d':raise ValueError('active build changed')
  files={pathlib.Path('/roms/ports/PortMaster/libs/godot_4.5.mono.squashfs'):IMAGE,base/'libVkLayer_window_system_integration.so':'ed454d770a5908d94875ab5cf60b6b0d428fe9b31b8e87311ed0c1f928db0cc8',base/'godot-implicit-template.json':'2add1e2852f6ff783e79e2ec39af12f14cb49971dce3e947f871b634d13bfd26',base/'launch_exec_view.py':'2b02371d969da2e84c108ad77947667deae9147a2a28b68adc28a6b38e0ca0e0'}
  for path,sha in files.items():checked(path,sha)
  wayland=pathlib.Path('/run/wayland-0')
  if not stat.S_ISSOCK(wayland.stat().st_mode):raise ValueError('native Wayland socket missing')
  with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as client:
   client.settimeout(2);client.connect(str(wayland))
  print('PROFILE_OK native-wayland Vulkan',flush=True)
 else:
  if os.geteuid()!=0:raise ValueError('private Weston requires root')
  release=pathlib.Path('/etc/os-release').read_text()
  if 'ID=buildroot\n' not in release or 'VERSION_ID=2022.05\n' not in release:raise ValueError('unverified TrimUI firmware')
  base=pathlib.Path('/mnt/SDCARD/Data/ports/sts2-v110');support=base/'vulkan-support'
  checked(base/'official-vulkan-profile.json',p['marker'])
  common={base/'.install-manifest.json':'b1fa62e9518a807e3085a3c48b2f78ecce9e8f889459ca6e91c6c82c9b6025fa',pathlib.Path('/usr/trimui/bin/MainUI'):'801a8a5945a046d89bd400bae3b2a6fe2be175914a5ba638019b80d02699f4c6',pathlib.Path('/usr/trimui/bin/runtrimui.sh'):'beaf8704baf489291b5a073665ad04eca0f06dc10ff40950f2257669b16df996',base/'data_sts2_linuxbsd_arm64/sts2.dll':'543110f1286d71b7391c4a5fcc1df75212fcc3b74c763a09f4413e57acfc0b67',base/'data_sts2_linuxbsd_arm64/sts2_compat.dll':'df88e6ae4bbb546786f078f9d3368eb064539a7ae7893f89b6a69f4aa75f9d21',base/'data_sts2_linuxbsd_arm64/GodotSharp.dll':'f25b38747f64bc2fef5b5cd9097851dbc1fefb910dc0110bc61da7b37fa07594',base/'port_compat.pck':'ced8446fe95c212b26181fc61f27ebe2f6b4f2e8066968a72df03ed68beab3bc'}
  for path,sha in common.items():checked(path,sha)
  gles_files={base/'godot.mono':'d916065a05ef24aedcd66af08862638577fda54d172c89df1e83183e11304645',base/'gamedata/libs/libSDL2-2.0.so.0':'dc5e0118948e2a9e38978bb469c9db98f8083c21c928c56ab204bfd59b219166'}
  files={support/'godot_4.5.mono.aarch64.squashfs':IMAGE,support/'portable-wayland/manifest.json':'e3fe9d785df76a8c34e77b50a8a68a517786b02833ba235c31e570e84606833b',support/'portable-wayland/libvulkan.so.1':'5e6763d9f8bf2a1984d01222bddc2f6c46663a5b46f6bd945ee457a7d63471fa',support/'portable-wayland/libSDL2-2.0.so.0':'81f629d6b07d603e00702c02ab02ebf9d6ee5690e8a4d3a8b3eed28816c37fb7',support/'vulkan-wsi/libVkLayer_window_system_integration.so':'2b0084f9cf6f17d142d5c75b4900e82a30cafb1b7cfa75515024cb974025c58c',support/'vulkan-wsi/VkLayer_window_system_integration.json':'4d40c4b5a2366237cff3b7d366b8aee1766226abf6a7bd9f1846a0dd2382fb82',pathlib.Path('/mnt/SDCARD/Apps/PortMaster/PortMaster/libs/weston_pkg_0.2.squashfs'):'0bccaeebc11296bb1fe4278c9677cb82965c5a04bcd63745fa09d78228bc1a93'}
  files[support/'bin/wayland-session-sts2-v2.py']='baf048382f47955222b748038c09d68c81d22379dd2506c1acfa4e59c2e7b13a'
  gles,vulkan=graphics_capabilities(gles_files,files,base/'godot.mono')
  if not (gles or vulkan):raise ValueError('no verified graphics backend available')
  card=pathlib.Path('/dev/dri/card0')
  if not stat.S_ISCHR(card.stat().st_mode) or not os.access(card,os.R_OK|os.W_OK):raise ValueError('DRM device unavailable')
  state=frontend_state(leased=consume_lease())
  print('CAPS gles='+str(int(gles))+' vulkan='+str(int(vulkan)),flush=True)
if __name__=='__main__':
 try:main()
 except (OSError,ValueError,KeyError) as error:print('[ERROR] Vulkan profile:',error,file=sys.stderr);raise SystemExit(1)
