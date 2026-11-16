// INPUT:  Explicit executable/resource roots, original argv and Linux mount facts.
// OUTPUT: exec_view() replaces its own PID in a private executable mount view.
// POS:    Native bootstrap for noexec media; never change the frontend's mount namespace.
#[cfg(any(target_os = "linux", test))]
use std::collections::BTreeSet;
use std::error::Error;
use std::ffi::OsString;
#[cfg(any(target_os = "linux", test))]
use std::os::unix::ffi::OsStringExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
#[cfg(target_os = "linux")]
use std::{ffi::CString, fs};

type Result<T> = std::result::Result<T, Box<dyn Error>>;

#[cfg(any(target_os = "linux", test))]
fn unescape(value: &str) -> Result<PathBuf> {
    let source = value.as_bytes();
    let mut bytes = Vec::new();
    let mut i = 0;
    while i < source.len() {
        if source[i] == b'\\' {
            let digits = source.get(i + 1..i + 4).ok_or("invalid mountinfo escape")?;
            if !digits.iter().all(|b| (b'0'..=b'7').contains(b)) {
                return Err("invalid mountinfo escape".into());
            }
            let number = u16::from(digits[0] - b'0') * 64
                + u16::from(digits[1] - b'0') * 8
                + u16::from(digits[2] - b'0');
            if number == 0 || number > 255 {
                return Err("invalid mountinfo escape".into());
            }
            bytes.push(number as u8);
            i += 4;
        } else {
            bytes.push(source[i]);
            i += 1;
        }
    }
    let path = PathBuf::from(OsString::from_vec(bytes));
    if !path.is_absolute() {
        return Err("mount point is not absolute".into());
    }
    Ok(path)
}

#[cfg(any(target_os = "linux", test))]
fn targets(roots: &[PathBuf], contents: &str) -> Result<Vec<PathBuf>> {
    let mut points = BTreeSet::new();
    for line in contents.lines() {
        let fields: Vec<_> = line.split_whitespace().collect();
        if fields.len() < 10 || !fields.contains(&"-") {
            return Err("invalid mountinfo record".into());
        }
        points.insert(unescape(fields[4])?);
    }
    let mut selected = BTreeSet::new();
    for root in roots {
        let parent = points
            .iter()
            .filter(|p| root.starts_with(p))
            .max_by_key(|p| p.components().count())
            .ok_or("no mount found for executable root")?;
        selected.insert(parent.clone());
        selected.extend(points.iter().filter(|p| p.starts_with(root)).cloned());
    }
    Ok(selected.into_iter().collect())
}

#[cfg(target_os = "linux")]
fn flags(path: &Path) -> Result<libc::c_ulong> {
    let name = CString::new(path.as_os_str().as_encoded_bytes())?;
    let mut state: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(name.as_ptr(), &mut state) } != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(state.f_flag)
}

#[cfg(target_os = "linux")]
fn remount_flags(old: libc::c_ulong) -> libc::c_ulong {
    // Linux statfs ABI flag, omitted from libc's musl constant exports.
    const ST_RELATIME: libc::c_ulong = 4096;
    let mut flags = libc::MS_BIND | libc::MS_REMOUNT;
    // statvfs ST_RELATIME and mount MS_RELATIME use different bits. Passing
    // f_flag directly would silently change atime policy on ordinary cards.
    for (stat, mount) in [
        (libc::ST_RDONLY, libc::MS_RDONLY),
        (libc::ST_NOSUID, libc::MS_NOSUID),
        (libc::ST_NODEV, libc::MS_NODEV),
        (libc::ST_SYNCHRONOUS, libc::MS_SYNCHRONOUS),
        (libc::ST_MANDLOCK, libc::MS_MANDLOCK),
        (libc::ST_NOATIME, libc::MS_NOATIME),
        (libc::ST_NODIRATIME, libc::MS_NODIRATIME),
        (ST_RELATIME, libc::MS_RELATIME),
    ] {
        if old & stat != 0 {
            flags |= mount;
        }
    }
    if old & (libc::ST_NOATIME | ST_RELATIME) == 0 {
        flags |= libc::MS_STRICTATIME;
    }
    flags
}

#[cfg(target_os = "linux")]
fn prepare(roots: &[PathBuf]) -> Result<Vec<PathBuf>> {
    let contents = fs::read_to_string("/proc/self/mountinfo")?;
    let mut selected = Vec::new();
    for path in targets(roots, &contents)? {
        let old = flags(&path)?;
        if old & libc::ST_NOEXEC != 0 {
            selected.push((path, old));
        }
    }
    if selected.is_empty() {
        return Ok(Vec::new());
    }
    if unsafe { libc::unshare(libc::CLONE_NEWNS) } != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    let slash = CString::new("/")?;
    if unsafe {
        libc::mount(
            std::ptr::null(),
            slash.as_ptr(),
            std::ptr::null(),
            libc::MS_REC | libc::MS_PRIVATE,
            std::ptr::null(),
        )
    } != 0
    {
        return Err(std::io::Error::last_os_error().into());
    }
    let mut changed = Vec::new();
    for (path, old) in selected {
        let name = CString::new(path.as_os_str().as_encoded_bytes())?;
        let wanted = remount_flags(old);
        if unsafe {
            libc::mount(
                std::ptr::null(),
                name.as_ptr(),
                std::ptr::null(),
                wanted,
                std::ptr::null(),
            )
        } != 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        let new = flags(&path)?;
        if new & libc::ST_NOEXEC != 0 || (new & !libc::ST_NOEXEC) != (old & !libc::ST_NOEXEC) {
            return Err("mount flags were not preserved".into());
        }
        changed.push(path);
    }
    Ok(changed)
}

pub fn exec_view(roots: &[PathBuf], argv: &[OsString], quiet: bool) -> Result<()> {
    if roots.is_empty() || argv.is_empty() {
        return Err("provide explicit roots and command argv".into());
    }
    let roots: Vec<_> = roots
        .iter()
        .map(|p| p.canonicalize())
        .collect::<std::io::Result<_>>()?;
    if roots.iter().any(|p| p == Path::new("/")) {
        return Err("executable roots must be below /".into());
    }
    #[cfg(target_os = "linux")]
    let changed = prepare(&roots)?;
    #[cfg(not(target_os = "linux"))]
    let changed: Vec<PathBuf> = Vec::new();
    if !quiet {
        eprintln!("[exec-view] private executable mounts: {changed:?}");
    }
    // Rust ignores SIGPIPE in its own runtime, unlike the native program we
    // are handing control to. Keep normal exec signal semantics and PID.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
        libc::signal(libc::SIGXFSZ, libc::SIG_DFL);
    }
    Err(Command::new(&argv[0]).args(&argv[1..]).exec().into())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(target_os = "linux")]
    #[test]
    fn statvfs_flags_are_translated_to_mount_flags() {
        let flags = remount_flags(4096 | libc::ST_NOEXEC | libc::ST_NOSUID | libc::ST_NODEV);
        assert_ne!(flags & libc::MS_RELATIME, 0);
        assert_ne!(flags & libc::MS_NOSUID, 0);
        assert_ne!(flags & libc::MS_NODEV, 0);
        assert_eq!(flags & (libc::MS_NOEXEC | libc::MS_STRICTATIME), 0);
    }
    #[test]
    fn paths_and_descendant_mounts_are_preserved() {
        let contents = "1 0 0:1 / / rw - rootfs rootfs rw\n2 1 0:2 / /card\\040one rw,noexec - vfat card rw\n3 2 0:3 / /card\\040one/game/runtime rw - tmpfs tmpfs rw\n4 1 0:4 / /other rw - tmpfs tmpfs rw\n";
        assert_eq!(
            targets(&[PathBuf::from("/card one/game")], contents).unwrap(),
            vec![
                PathBuf::from("/card one"),
                PathBuf::from("/card one/game/runtime")
            ]
        );
        assert_eq!(unescape("/a\\134b").unwrap(), PathBuf::from("/a\\b"));
    }
    #[test]
    fn malformed_mount_records_and_escapes_fail() {
        for line in [
            "bad",
            "1 0 0:1 / relative rw - rootfs rootfs rw",
            "1 0 0:1 / /bad\\999 rw - rootfs rootfs rw",
        ] {
            assert!(targets(&[PathBuf::from("/game")], line).is_err());
        }
    }
}
