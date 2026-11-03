#!/usr/bin/env python3
# INPUT: the verified TrimUI runner and MainUI, and the fixed official entry.
# OUTPUT: a private UI/game session followed by restoration of that runner.
# POS: 91 display handoff only; never changes shared launcher or system files.
import ctypes,os,pathlib,secrets,select,signal,sys,time

ENTRY='/mnt/SDCARD/Roms/PORTS/Je-杀戮尖塔2[中].sh'
lib=ctypes.CDLL(None,use_errno=True)

def proc(pid):
 text=pathlib.Path('/proc',str(pid),'stat').read_text();f=text[text.rfind(')')+2:].split()
 return f[0],int(f[1]),int(f[19])
def identity(pid,start,exe):
 state,ppid,actual=proc(pid)
 if actual!=start or os.readlink('/proc/%d/exe'%pid)!=exe:raise ValueError('process identity changed')
 return state,ppid
def pidfd_open(pid):
 fd=lib.syscall(434,pid,0)
 if fd<0:raise OSError(ctypes.get_errno(),'pidfd_open')
 return fd
def pidfd_signal(fd,sig):
 if lib.syscall(424,fd,int(sig),0,0)<0:raise OSError(ctypes.get_errno(),'pidfd_send_signal')
def root_runner(runners):
 # Bash can fork a shebang-less frontend command while retaining runtrimui's
 # original exe and argv; only the verified direct child is treated as a copy.
 roots=[r for r in runners if r[1]==1]
 if len(roots)!=1 or len(runners)>2:return None
 root=roots[0]
 if any(r!=root and r[1]!=root[0] for r in runners):return None
 return root
def find_frontend():
 runners=[];frontends=[]
 for p in pathlib.Path('/proc').iterdir():
  if not p.name.isdecimal():continue
  try:
   exe=os.readlink(str(p/'exe'));args=(p/'cmdline').read_bytes()
   if exe=='/bin/bash' and args==b'/bin/sh\0/usr/trimui/bin/runtrimui.sh\0':
    state,ppid,start=proc(int(p.name));runners.append((int(p.name),ppid,start))
   if exe=='/usr/trimui/bin/MainUI':frontends.append((int(p.name),proc(int(p.name))[1],proc(int(p.name))[2]))
   name=os.path.basename(exe).lower()
   if 'godot' in name or name.startswith('love') or name in ('unityloader','wp_weston'):raise ValueError('game or settings UI already active')
  except PermissionError:raise ValueError('cannot inspect display processes')
  except FileNotFoundError:continue
 runner=root_runner(runners)
 if runner is None or len(frontends)>1 or (frontends and frontends[0][1]!=runner[0]):raise ValueError('unverified frontend relationship')
 return (runner[0],runner[2]),frontends[0] if frontends else None

def main():
 if len(sys.argv)!=1 or os.geteuid()!=0:raise ValueError('display lease requires the verified root profile')
 (runner,start),frontend=find_frontend()
 rfd=pidfd_open(runner);mfd=pidfd_open(frontend[0]) if frontend else None
 if identity(runner,start,'/bin/bash')[0] in ('T','t'):raise ValueError('runner already stopped')
 if ((runner,start),frontend) != find_frontend():raise ValueError('frontend changed')
 read_fd,watch_w=os.pipe();ack_r,ack_w=os.pipe();lease_r,lease_w=os.pipe();token=secrets.token_hex(32);guardian=os.fork()
 if guardian==0:
  # The startup logger forwards termination to its child's process group.
  # Leave that group before stopping the runner so the guardian can restore it.
  os.setsid()
  os.close(watch_w);os.close(ack_r);os.close(lease_r);stopped=False;message=b''
  try:
   if os.read(read_fd,1)!=b'S':os._exit(0)
   if identity(runner,start,'/bin/bash')[0] in ('T','t'):os._exit(2)
   pidfd_signal(rfd,signal.SIGSTOP);stopped=True
   deadline=time.monotonic()+5
   while identity(runner,start,'/bin/bash')[0] not in ('T','t'):
    if time.monotonic()>deadline:raise ValueError('runner did not stop')
    time.sleep(.05)
   os.write(lease_w,token.encode('ascii'));os.close(lease_w)
   os.write(ack_w,b'K');os.close(ack_w)
   while True:
    data=os.read(read_fd,128)
    if not data:break
    message+=data
  finally:
   if message:
    try:
     pid,started=map(int,message.split());state,_,actual=proc(pid)
     if actual==started and state not in ('Z','X'):
      fd=pidfd_open(pid)
      if proc(pid)[2]==started:
       poll=select.poll();poll.register(fd,select.POLLIN);pidfd_signal(fd,signal.SIGTERM)
       if not poll.poll(15000):
        pidfd_signal(fd,signal.SIGKILL)
        if not poll.poll(10000):
         print('[ERROR] waiting for private display session to exit',flush=True)
         while not poll.poll(10000):pass
      os.close(fd)
    except FileNotFoundError:pass
    except (OSError,ValueError) as error:
     print('[ERROR] display guardian:',error,flush=True)
     if 'pid' in locals() and 'started' in locals():
      while True:
       try:
        state,_,actual=proc(pid)
        if actual!=started or state in ('Z','X'):break
       except FileNotFoundError:break
       except (OSError,ValueError):pass
       time.sleep(1)
   if stopped:
    try:pidfd_signal(rfd,signal.SIGCONT)
    except OSError as error:print('[ERROR] runner resume:',error,flush=True)
   os._exit(0)
 os.close(read_fd);os.close(ack_w);os.close(lease_w);child=None
 def interrupt(sig,frame):raise SystemExit(128+sig)
 old={sig:signal.signal(sig,interrupt) for sig in (signal.SIGTERM,signal.SIGINT,signal.SIGHUP)}
 try:
  os.write(watch_w,b'S')
  if os.read(ack_r,1)!=b'K':raise ValueError('runner handoff failed')
  os.close(ack_r)
  if ((runner,start),frontend) != find_frontend():raise ValueError('frontend changed during handoff')
  if frontend:
   pidfd_signal(mfd,signal.SIGTERM);deadline=time.monotonic()+5
   while time.monotonic()<deadline:
    try:state,_=identity(frontend[0],frontend[2],'/usr/trimui/bin/MainUI')
    except (OSError,ValueError):break
    if state in ('Z','X'):break
    time.sleep(.05)
   else:
    pidfd_signal(mfd,signal.SIGKILL)
    poll=select.poll();poll.register(mfd,select.POLLIN)
    if not poll.poll(5000):raise ValueError('frontend did not exit')
  owner=os.getpid();child=os.fork()
  if child==0:
   os.setsid()
   if lib.prctl(1,signal.SIGKILL,0,0,0)!=0 or os.getppid()!=owner:os._exit(125)
   if lib.unshare(0x20000000)!=0:os._exit(125)
   parent_host=int(os.readlink('/proc/self'));init=os.fork()
   if init==0:
    if lib.prctl(1,signal.SIGKILL,0,0,0)!=0:os._exit(125)
    status=pathlib.Path('/proc/self/status').read_text()
    if int(next(line.split()[1] for line in status.splitlines() if line.startswith('PPid:')))!=parent_host:os._exit(125)
    pid=int(os.readlink('/proc/self'));os.write(watch_w,('%d %d\n'%(pid,proc(pid)[2])).encode());os.close(watch_w)
    if lib.unshare(0x00020000)!=0 or lib.mount(None,b'/',None,0x44000,None)!=0 or lib.mount(b'proc',b'/proc',b'proc',0x0e,None)!=0:os._exit(125)
    os.set_inheritable(lease_r,True)
    env=dict(os.environ);env['SLL_TRIMUI_LEASE_FD']=str(lease_r);env['SLL_TRIMUI_LEASE_TOKEN']=token
    os.execvpe('/bin/bash',['/bin/bash',ENTRY],env)
   os.close(watch_w);os.close(lease_r)
   def forward(sig,frame):
    try:os.kill(init,sig)
    except ProcessLookupError:pass
   for sig in (signal.SIGTERM,signal.SIGINT,signal.SIGHUP):signal.signal(sig,forward)
   while True:
    try:_,status=os.waitpid(init,0);break
    except InterruptedError:continue
   code=os.waitstatus_to_exitcode(status);os._exit(code if code>=0 else 128-code)
  os.close(lease_r);lease_r=None
  while True:
   try:_,status=os.waitpid(child,0);child=None;break
   except InterruptedError:continue
  return os.waitstatus_to_exitcode(status)
 finally:
  for sig,handler in old.items():signal.signal(sig,handler)
  if child:
   try:os.kill(child,signal.SIGTERM)
   except ProcessLookupError:pass
   deadline=time.monotonic()+15
   while time.monotonic()<deadline:
    try:done,_=os.waitpid(child,os.WNOHANG)
    except ChildProcessError:done=child
    if done:break
    time.sleep(.1)
   else:
    try:os.kill(child,signal.SIGKILL)
    except ProcessLookupError:pass
    try:os.waitpid(child,0)
    except ChildProcessError:pass
  if lease_r is not None:os.close(lease_r)
  os.close(watch_w);os.waitpid(guardian,0);os.close(rfd)
  if mfd is not None:os.close(mfd)
if __name__=='__main__':
 try:raise SystemExit(main())
 except (OSError,ValueError) as error:print('[ERROR] display lease:',error,file=sys.stderr);raise SystemExit(1)
