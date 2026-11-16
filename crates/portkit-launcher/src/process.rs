// INPUT: Literal native command, optional diagnostic log and spawn receipt callback.
// OUTPUT: Owned/reaped process group, normalized status and a bounded output tail.
// POS: Shared session supervision; EOF never releases cancellation or child ownership.
use std::{
    error::Error,
    fs::File,
    io::{Read, Write},
    os::unix::{
        io::{AsRawFd, FromRawFd},
        process::{CommandExt, ExitStatusExt},
    },
    path::Path,
    process::{Child, Command, Stdio},
    sync::{
        Mutex, MutexGuard,
        atomic::{AtomicI32, Ordering},
    },
    time::{Duration, Instant},
};

type Result<T> = std::result::Result<T, Box<dyn Error>>;
static SERIAL: Mutex<()> = Mutex::new(());
static WAKE: AtomicI32 = AtomicI32::new(-1);
static CANCEL: AtomicI32 = AtomicI32::new(0);
extern "C" fn signal(sig: i32) {
    #[cfg(target_os = "linux")]
    let errno = unsafe { libc::__errno_location() };
    #[cfg(target_os = "macos")]
    let errno = unsafe { libc::__error() };
    let saved = unsafe { *errno };
    if sig != libc::SIGCHLD {
        CANCEL.store(sig, Ordering::SeqCst);
    }
    let fd = WAKE.load(Ordering::SeqCst);
    if fd >= 0 {
        unsafe {
            libc::write(fd, [1u8].as_ptr().cast(), 1);
        }
    }
    unsafe {
        *errno = saved;
    }
}

pub(crate) struct Signals {
    read: File,
    _write: File,
    previous: Vec<(i32, libc::sigaction)>,
    _serial: MutexGuard<'static, ()>,
}
fn pipe() -> std::io::Result<(File, File)> {
    let mut fds = [-1; 2];
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    let files = unsafe { (File::from_raw_fd(fds[0]), File::from_raw_fd(fds[1])) };
    for fd in fds {
        if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
            return Err(std::io::Error::last_os_error());
        }
    }
    Ok(files)
}
fn nonblocking(fd: i32) -> std::io::Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}
impl Signals {
    pub(crate) fn new() -> Result<Self> {
        let serial = SERIAL.lock().map_err(|_| "session signal lock poisoned")?;
        let (read, write) = pipe()?;
        nonblocking(read.as_raw_fd())?;
        nonblocking(write.as_raw_fd())?;
        CANCEL.store(0, Ordering::SeqCst);
        WAKE.store(write.as_raw_fd(), Ordering::SeqCst);
        let mut result = Self {
            read,
            _write: write,
            previous: Vec::new(),
            _serial: serial,
        };
        for sig in [libc::SIGINT, libc::SIGTERM, libc::SIGHUP, libc::SIGCHLD] {
            let mut old = unsafe { std::mem::zeroed() };
            let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
            action.sa_sigaction = signal as *const () as usize;
            unsafe {
                libc::sigemptyset(&mut action.sa_mask);
            }
            if unsafe { libc::sigaction(sig, &action, &mut old) } != 0 {
                return Err(std::io::Error::last_os_error().into());
            }
            result.previous.push((sig, old));
        }
        Ok(result)
    }
    pub(crate) fn cancelled(&self) -> i32 {
        CANCEL.load(Ordering::SeqCst)
    }
    pub(crate) fn wait(&mut self, output: Option<i32>, timeout: i32) -> Result<()> {
        let mut fds = [
            libc::pollfd {
                fd: self.read.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: output.unwrap_or(-1),
                events: libc::POLLIN,
                revents: 0,
            },
        ];
        if unsafe { libc::poll(fds.as_mut_ptr(), 2, timeout) } < 0
            && std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted
        {
            return Err(std::io::Error::last_os_error().into());
        }
        let mut bytes = [0; 128];
        while self.read.read(&mut bytes).is_ok_and(|n| n > 0) {}
        Ok(())
    }
}
impl Drop for Signals {
    fn drop(&mut self) {
        WAKE.store(-1, Ordering::SeqCst);
        for (sig, old) in &self.previous {
            unsafe {
                libc::sigaction(*sig, old, std::ptr::null_mut());
            }
        }
    }
}

pub(crate) fn group(pid: u32, sig: i32) {
    unsafe {
        libc::kill(-(pid as i32), sig);
    }
}
pub(crate) struct Owned(pub Child);
impl Owned {
    pub(crate) fn spawn(command: &mut Command) -> Result<Self> {
        #[cfg(target_os = "linux")]
        let parent = unsafe { libc::getpid() };
        unsafe {
            command.pre_exec(move || {
                if libc::setsid() < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                for sig in [
                    libc::SIGINT,
                    libc::SIGTERM,
                    libc::SIGHUP,
                    libc::SIGCHLD,
                    libc::SIGPIPE,
                ] {
                    libc::signal(sig, libc::SIG_DFL);
                }
                #[cfg(target_os = "linux")]
                {
                    if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) < 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                    if libc::getppid() != parent {
                        return Err(std::io::Error::other("session parent exited"));
                    }
                }
                Ok(())
            });
        }
        Ok(Self(command.spawn()?))
    }
    pub(crate) fn stop(&mut self) {
        group(self.0.id(), libc::SIGTERM);
        let deadline = Instant::now() + Duration::from_secs(5);
        while self.0.try_wait().ok().flatten().is_none() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        // Also terminate descendants after the group leader exits. Only this
        // session's setsid-created group is owned by this helper.
        group(self.0.id(), libc::SIGKILL);
        let _ = self.0.wait();
    }
}
impl Drop for Owned {
    fn drop(&mut self) {
        self.stop();
    }
}
pub struct RunOutput {
    pub exit_code: i32,
    pub tail: Vec<u8>,
    pub pid: u32,
}

pub fn run_owned(
    command: Command,
    full_log: Option<&Path>,
    on_spawn: impl FnOnce(u32) -> Result<()>,
) -> Result<RunOutput> {
    run_with_signals(command, full_log, on_spawn, &mut Signals::new()?, None)
}

pub(crate) fn run_with_signals(
    command: Command,
    full_log: Option<&Path>,
    on_spawn: impl FnOnce(u32) -> Result<()>,
    signals: &mut Signals,
    peer: Option<&mut Owned>,
) -> Result<RunOutput> {
    run_limited(command, full_log, on_spawn, signals, peer, None)
}

// Firmware may have neither coreutils timeout nor the BusyBox applet. Reuse
// owned groups and the signal poll deadline; do not add a runtime dependency.
pub fn run_bounded(command: Command, duration: Duration) -> Result<RunOutput> {
    run_bounded_with_signals(command, duration, &mut Signals::new()?)
}

pub(crate) fn run_bounded_with_signals(
    command: Command,
    duration: Duration,
    signals: &mut Signals,
) -> Result<RunOutput> {
    run_limited(command, None, |_| Ok(()), signals, None, Some(duration))
}

fn run_limited(
    mut command: Command,
    full_log: Option<&Path>,
    on_spawn: impl FnOnce(u32) -> Result<()>,
    signals: &mut Signals,
    mut peer: Option<&mut Owned>,
    duration: Option<Duration>,
) -> Result<RunOutput> {
    let (mut output, writer) = pipe()?;
    nonblocking(output.as_raw_fd())?;
    command
        .stdin(Stdio::null())
        .stdout(writer.try_clone()?)
        .stderr(writer);
    let mut log = full_log.map(File::create).transpose()?;
    let mut child = Owned::spawn(&mut command)?;
    // Command retains its Stdio values after spawn. Closing those copies is
    // essential: otherwise output EOF can never arrive in the parent.
    drop(command);
    let pid = child.0.id();
    on_spawn(pid)?;
    let mut tail = Vec::new();
    let mut eof = false;
    let mut deadline = None;
    let mut status = None;
    let mut peer_failed = false;
    let mut final_drain = None;
    let execution_deadline = duration.map(|d| Instant::now() + d);
    let mut timed_out = false;
    loop {
        let mut bytes = [0; 16384];
        if !eof {
            for _ in 0..64 {
                match output.read(&mut bytes) {
                    Ok(0) => {
                        eof = true;
                        break;
                    }
                    Ok(n) => {
                        if let Some(log) = &mut log {
                            log.write_all(&bytes[..n])?;
                        }
                        tail.extend_from_slice(&bytes[..n]);
                        if tail.len() > 65536 {
                            tail.drain(..tail.len() - 65536);
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                    Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(e) => return Err(e.into()),
                }
            }
        }
        if status.is_none() {
            status = child.0.try_wait()?;
        }
        if status.is_none() && !timed_out && execution_deadline.is_some_and(|d| Instant::now() >= d)
        {
            timed_out = true;
            group(pid, libc::SIGTERM);
            deadline = Some(Instant::now() + Duration::from_secs(1));
        }
        if !peer_failed {
            if let Some(peer) = &mut peer {
                if peer.0.try_wait()?.is_some() {
                    peer_failed = true;
                    group(pid, libc::SIGTERM);
                    deadline = Some(Instant::now() + Duration::from_secs(10));
                }
            }
        }
        let cancellation = signals.cancelled();
        if cancellation != 0 && deadline.is_none() {
            group(pid, cancellation);
            deadline = Some(Instant::now() + Duration::from_secs(20));
        }
        if deadline.is_some_and(|d| Instant::now() >= d) {
            group(pid, libc::SIGKILL);
            deadline = None;
        }
        if status.is_some() {
            if eof {
                break;
            }
            if final_drain.is_none() {
                group(pid, libc::SIGTERM);
                final_drain = Some(Instant::now() + Duration::from_secs(1));
            }
            if final_drain.is_some_and(|d| Instant::now() >= d) {
                group(pid, libc::SIGKILL);
                break;
            }
        }
        let execution_wait = if status.is_none() && !timed_out {
            execution_deadline
        } else {
            None
        };
        let next = deadline
            .into_iter()
            .chain(final_drain)
            .chain(execution_wait)
            .min();
        let timeout = next
            .map(|d| {
                d.saturating_duration_since(Instant::now())
                    .as_millis()
                    .min(i32::MAX as u128) as i32
            })
            .unwrap_or(-1);
        signals.wait(if eof { None } else { Some(output.as_raw_fd()) }, timeout)?;
    }
    let status = status.unwrap();
    let exit_code = if timed_out {
        124
    } else if peer_failed {
        1
    } else {
        status
            .code()
            .unwrap_or_else(|| 128 + status.signal().unwrap_or(1))
    };
    Ok(RunOutput {
        exit_code,
        tail,
        pid,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn deadline_survives_closed_output_and_reaps_term_ignoring_child() {
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "trap '' TERM; exec 1>&- 2>&-; exec sleep 30"]);
        let start = Instant::now();
        let result = run_bounded(command, Duration::from_millis(200)).unwrap();
        assert_eq!(result.exit_code, 124);
        assert!(start.elapsed() < Duration::from_secs(4));
        assert_eq!(unsafe { libc::kill(result.pid as i32, 0) }, -1);
    }
    #[test]
    fn compositor_failure_stops_only_its_owned_client() {
        let mut signals = Signals::new().unwrap();
        let mut peer_command = Command::new("/bin/sh");
        peer_command.args(["-c", "sleep 0.1; exit 9"]);
        let mut peer = Owned::spawn(&mut peer_command).unwrap();
        let mut other_command = Command::new("/bin/sh");
        other_command.args(["-c", "sleep 10"]);
        let mut other = Owned::spawn(&mut other_command).unwrap();
        let mut client = Command::new("/bin/sh");
        client.args(["-c", "sleep 10"]);
        let result =
            run_with_signals(client, None, |_| Ok(()), &mut signals, Some(&mut peer)).unwrap();
        assert_eq!(result.exit_code, 1);
        assert!(other.0.try_wait().unwrap().is_none());
    }
    #[test]
    fn failed_spawn_receipt_reaps_the_child() {
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "sleep 10"]);
        let mut pid = 0;
        assert!(
            run_owned(command, None, |child| {
                pid = child;
                Err("receipt failed".into())
            })
            .is_err()
        );
        assert!(pid > 0);
        assert_eq!(unsafe { libc::kill(pid as i32, 0) }, -1);
    }
    #[test]
    fn lingering_descendant_output_cannot_hold_the_session_open() {
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "sleep 30 & printf done; exit 0"]);
        let start = Instant::now();
        let output = run_owned(command, None, |_| Ok(())).unwrap();
        assert_eq!(output.exit_code, 0);
        assert_eq!(output.tail, b"done");
        assert!(start.elapsed() < Duration::from_secs(4));
    }
}
