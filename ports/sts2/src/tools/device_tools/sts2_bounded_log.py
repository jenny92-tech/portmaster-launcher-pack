#!/usr/bin/env python3
# INPUT: diagnostic on/off, owned log path, one launcher command.
# OUTPUT: bounded recent log on request or error; exit status of the command.
import os, pathlib, signal, subprocess, sys, tempfile

LIMIT=128*1024

def main():
 if len(sys.argv)<5 or sys.argv[1] not in ('on','off') or sys.argv[3]!='--':
  raise ValueError('expected on|off LOG -- COMMAND...')
 mode,path=sys.argv[1],pathlib.Path(sys.argv[2])
 if path.is_symlink() or (path.exists() and not path.is_file()):raise ValueError('unsafe log target')
 proc=subprocess.Popen(sys.argv[4:],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True)
 def forward(sig,frame):
  try:os.killpg(proc.pid,sig)
  except ProcessLookupError:pass
 old={sig:signal.signal(sig,forward) for sig in (signal.SIGTERM,signal.SIGINT,signal.SIGHUP)}
 tail=bytearray(); marker=b''; error=False; first_error=b''
 try:
  while True:
   block=proc.stdout.read(4096)
   if not block:break
   check=(marker+block).lower()
   found=any(x in check for x in (b'error:',b'[error]',b'[fatal]',b'fatal:'))
   if found and not error:first_error=block[:4096]
   error|=found
   marker=check[-16:];tail.extend(block)
   if len(tail)>LIMIT-len(first_error):del tail[:-(LIMIT-len(first_error))]
  code=proc.wait()
 finally:
  for sig,handler in old.items():signal.signal(sig,handler)
 if mode=='on' or code or error:
  fd,name=tempfile.mkstemp(prefix='.sts2-log-',dir=path.parent)
  try:
   with os.fdopen(fd,'wb') as out:out.write(first_error);out.write(tail);out.flush();os.fsync(out.fileno())
   os.replace(name,path)
  finally:
   if os.path.exists(name):os.unlink(name)
 return code if code>=0 else 128-code
if __name__=='__main__':
 try:raise SystemExit(main())
 except (OSError,ValueError) as error:
  print('[ERROR] bounded log:',error,file=sys.stderr);raise SystemExit(1)
