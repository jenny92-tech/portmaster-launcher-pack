// INPUT:  std 文件系统、Linux 挂载表/sysfs 与可选探测根目录
// OUTPUT: StorageVolume、mounted_storage_roots()
// POS:    从真实块设备挂载及 /mnt 别名发现用户存储，不猜测配置回退路径
//! Removable-storage detection.
//!
//! Handheld Linux builds mount the SD/TF card at vendor-specific places
//! (`/mnt/sdcard`, `/mnt/sdcard/mmcblk1p1`, `/mnt/SDCARD`, …) that are not
//! portable. What *is* standard Linux is the mount table itself. Some SD-boot
//! devices expose the card as `mmcblk0`, while USB readers, NVMe adapters, and
//! encrypted volumes use other names, so device names are never a whitelist.
//!
//! This module finds mounted block-backed data volumes (plus `/mnt` symlink
//! aliases vendors use as a friendly root). It deliberately has no platform
//! Config fallback: an unavailable mount table is reported as no discoverable
//! storage instead of guessing a path.

use std::fs;
use std::path::{Path, PathBuf};

/// A mounted removable volume and the user-visible root(s) for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StorageVolume {
    pub device: PathBuf,
    pub mount_point: PathBuf,
    /// `mount_point` plus any symlink aliases found under `/mnt` that point
    /// at it (e.g. TrimUI's `/mnt/SDCARD -> /mnt/sdcard/mmcblk1p1`).
    pub roots: Vec<PathBuf>,
}

/// Parse one `/proc/mounts` line. Returns `None` for pseudo filesystems.
fn parse_mount_line(line: &str) -> Option<(PathBuf, PathBuf)> {
    let mut fields = line.split_whitespace();
    let device = fields.next()?;
    let mount_point = fields.next()?;
    if !device.starts_with("/dev/") {
        return None;
    }
    Some((
        PathBuf::from(decode_mount_field(device)?),
        PathBuf::from(decode_mount_field(mount_point)?),
    ))
}

fn decode_mount_field(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'\\' && index + 3 < bytes.len() {
            let octal = &bytes[index + 1..index + 4];
            if octal.iter().all(|byte| matches!(byte, b'0'..=b'7')) {
                let value = (octal[0] - b'0') * 64 + (octal[1] - b'0') * 8 + octal[2] - b'0';
                decoded.push(value);
                index += 4;
                continue;
            }
        }
        decoded.push(bytes[index]);
        index += 1;
    }
    String::from_utf8(decoded).ok()
}

fn is_system_mount(path: &Path) -> bool {
    const SYSTEM_ROOTS: &[&str] = &[
        "/",
        "/boot",
        "/boot/efi",
        "/dev",
        "/etc",
        "/proc",
        "/sys",
        "/system",
        "/usr",
        "/var",
        "/vendor",
    ];
    SYSTEM_ROOTS.iter().any(|root| {
        let root = Path::new(root);
        path == root || (root != Path::new("/") && path.starts_with(root))
    }) || (path == Path::new("/run") || path.starts_with("/run") && !path.starts_with("/run/media"))
}

fn unsupported_block_device(device: &Path) -> bool {
    device
        .file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| {
            name.starts_with("loop")
                || name.starts_with("zram")
                || name.starts_with("ram")
                || name.starts_with("mtdblock")
        })
}

fn user_media_namespace(path: &Path) -> bool {
    let lower = path.to_string_lossy().to_ascii_lowercase();
    lower == "/roms"
        || lower.starts_with("/roms/")
        || lower == "/roms2"
        || lower.starts_with("/roms2/")
        || lower.contains("sdcard")
        || lower.starts_with("/media/")
        || lower.starts_with("/run/media/")
        || lower == "/storage"
        || lower.starts_with("/storage/")
        || lower == "/mnt/mmc"
        || lower.starts_with("/mnt/mmc/")
}

fn known_firmware_internal_mount(path: &Path) -> bool {
    let lower = path.to_string_lossy().to_ascii_lowercase();
    matches!(lower.as_str(), "/mnt/udisk" | "/secord")
}

fn rooted_mount_point(probe_root: Option<&Path>, mount_point: &Path) -> PathBuf {
    probe_root.map_or_else(
        || mount_point.to_path_buf(),
        |root| root.join(mount_point.strip_prefix("/").unwrap_or(mount_point)),
    )
}

fn sysfs_removable(probe_root: Option<&Path>, device: &Path) -> bool {
    let Some(name) = device.file_name().and_then(|name| name.to_str()) else {
        return false;
    };
    let sys = probe_root.map_or_else(
        || PathBuf::from("/sys/class/block"),
        |root| root.join("sys/class/block"),
    );
    let mut candidates = vec![name.to_owned()];
    if let Some((disk, _)) = name.rsplit_once('p').filter(|(_, suffix)| {
        !suffix.is_empty() && suffix.bytes().all(|byte| byte.is_ascii_digit())
    }) {
        candidates.push(disk.to_owned());
    } else {
        let disk = name.trim_end_matches(|character: char| character.is_ascii_digit());
        if disk != name && !disk.is_empty() {
            candidates.push(disk.to_owned());
        }
    }
    candidates.into_iter().any(|candidate| {
        fs::read_to_string(sys.join(candidate).join("removable"))
            .is_ok_and(|value| value.trim() == "1")
    })
}

/// Collect symlink aliases under `<root>/mnt` that resolve to `mount_point`.
fn mnt_aliases(probe_root: Option<&Path>, mount_point: &Path) -> Vec<PathBuf> {
    let mnt = match probe_root {
        Some(root) => root.join("mnt"),
        None => PathBuf::from("/mnt"),
    };
    let Ok(entries) = fs::read_dir(&mnt) else {
        return Vec::new();
    };
    let mount_point = mount_point.strip_prefix("/").unwrap_or(mount_point);
    let mut out = Vec::new();
    for entry in entries.flatten() {
        let Ok(meta) = entry.path().symlink_metadata() else {
            continue;
        };
        if !meta.file_type().is_symlink() {
            continue;
        }
        if let Ok(target) = fs::read_link(entry.path()) {
            let absolute_target = if target.is_absolute() {
                match probe_root {
                    Some(root) => root.join(target.strip_prefix("/").unwrap_or(&target)),
                    None => target,
                }
            } else {
                entry.path().parent().unwrap_or(&mnt).join(target)
            };
            let expected = match probe_root {
                Some(root) => root.join(mount_point.strip_prefix("/").unwrap_or(mount_point)),
                None => PathBuf::from("/").join(mount_point),
            };
            let canonical_match = match (
                fs::canonicalize(&absolute_target),
                fs::canonicalize(&expected),
            ) {
                (Ok(actual), Ok(expected)) => actual == expected,
                _ => false,
            };
            let lexical_match = match probe_root {
                Some(root) => absolute_target
                    .strip_prefix(root)
                    .ok()
                    .is_some_and(|target| {
                        target == mount_point.strip_prefix("/").unwrap_or(mount_point)
                    }),
                None => absolute_target == expected,
            };
            if canonical_match || lexical_match {
                out.push(entry.path());
            }
        }
    }
    out
}

/// Detect mounted, block-backed storage roots from the Linux mount table.
pub fn mounted_storage_roots(probe_root: Option<&Path>) -> Vec<PathBuf> {
    let mounts_path = match probe_root {
        Some(root) => root.join("proc/mounts"),
        None => PathBuf::from("/proc/mounts"),
    };
    let mut volumes: Vec<StorageVolume> = Vec::new();
    if let Ok(contents) = fs::read_to_string(&mounts_path) {
        let mut seen: std::collections::BTreeSet<PathBuf> = Default::default();
        for line in contents.lines() {
            let Some((device, mount_point)) = parse_mount_line(line) else {
                continue;
            };
            if is_system_mount(&mount_point)
                || known_firmware_internal_mount(&mount_point)
                || unsupported_block_device(&device)
            {
                continue;
            }
            // Prefer kernel removable identity. Standard Linux user-media
            // namespaces are the fallback for filesystems (device mapper,
            // FUSE and older vendor kernels) that do not expose it.
            if !sysfs_removable(probe_root, &device) && !user_media_namespace(&mount_point) {
                continue;
            }
            if !seen.insert(mount_point.clone()) {
                continue;
            }
            // A probe root is a filesystem namespace boundary. Return paths
            // inside that namespace just like Config resolution does; mixing
            // rooted aliases with unrooted mount points makes fixture scans
            // escape the fixture and can manufacture false EXDEV failures.
            let mut roots = vec![rooted_mount_point(probe_root, &mount_point)];
            let aliases = mnt_aliases(probe_root, &mount_point);
            roots.extend(aliases);
            volumes.push(StorageVolume {
                device,
                mount_point,
                roots,
            });
        }
    }
    if !volumes.is_empty() {
        let mut roots: Vec<PathBuf> = Vec::new();
        for volume in &volumes {
            roots.extend(volume.roots.iter().cloned());
        }
        roots.sort();
        roots.dedup();
        return roots;
    }
    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn fixture_with_mounts(mounts: &str, mnt_links: &[(&str, &str)]) -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        fs::create_dir_all(dir.path().join("proc")).unwrap();
        fs::write(dir.path().join("proc/mounts"), mounts).unwrap();
        fs::create_dir_all(dir.path().join("mnt")).unwrap();
        for (name, target) in mnt_links {
            let _ = std::os::unix::fs::symlink(
                Path::new("/").join(target),
                dir.path().join("mnt").join(name),
            );
        }
        dir
    }

    #[test]
    fn trimui_style_mounts_find_the_card_and_alias() {
        let dir = fixture_with_mounts(
            "/dev/root / ext4 rw 0 0\n\
             /dev/mmcblk0p6 /mnt/UDISK ext4 rw 0 0\n\
             /dev/mmcblk1p1 /mnt/sdcard/mmcblk1p1 vfat rw 0 0\n",
            &[("SDCARD", "mnt/sdcard/mmcblk1p1")],
        );
        let roots = mounted_storage_roots(Some(dir.path()));
        assert_eq!(
            roots,
            vec![
                dir.path().join("mnt/SDCARD"),
                dir.path().join("mnt/sdcard/mmcblk1p1"),
            ]
        );
    }

    #[test]
    fn miniloong_style_mounts_find_the_card() {
        let dir = fixture_with_mounts(
            "/dev/root / ext4 rw 0 0\n\
             /dev/mmcblk0p11 /secord ext4 rw 0 0\n\
             /dev/mmcblk1p1 /mnt/sdcard fuseblk rw 0 0\n",
            &[],
        );
        let roots = mounted_storage_roots(Some(dir.path()));
        assert_eq!(roots, vec![dir.path().join("mnt/sdcard")]);
    }

    #[test]
    fn second_card_is_found_too() {
        let dir = fixture_with_mounts(
            "/dev/mmcblk1p1 /mnt/sdcard vfat rw 0 0\n\
             /dev/mmcblk2p1 /mnt/sdcard2 vfat rw 0 0\n",
            &[],
        );
        let roots = mounted_storage_roots(Some(dir.path()));
        assert_eq!(
            roots,
            vec![
                dir.path().join("mnt/sdcard"),
                dir.path().join("mnt/sdcard2"),
            ]
        );
    }

    #[test]
    fn usb_nvme_and_mapper_backed_cards_are_not_name_whitelisted() {
        let dir = fixture_with_mounts(
            "/dev/sda1 /media/usb-sd vfat rw 0 0\n\
             /dev/nvme0n1p5 /media/nvme ext4 rw 0 0\n\
             /dev/mapper/cryptsd /media/crypt ext4 rw 0 0\n",
            &[],
        );
        assert_eq!(
            mounted_storage_roots(Some(dir.path())),
            vec![
                dir.path().join("media/crypt"),
                dir.path().join("media/nvme"),
                dir.path().join("media/usb-sd"),
            ]
        );
    }

    #[test]
    fn mount_table_octal_escapes_are_decoded() {
        let dir = fixture_with_mounts("/dev/sda1 /media/My\\040Card vfat rw 0 0\n", &[]);
        assert_eq!(
            mounted_storage_roots(Some(dir.path())),
            vec![dir.path().join("media/My Card")]
        );
    }

    #[test]
    fn standard_run_media_and_primary_mmc_media_namespaces_are_discovered() {
        let dir = fixture_with_mounts(
            "/dev/sda1 /run/media/player/SDCARD vfat rw 0 0\n\
             /dev/mmcblk0p3 /storage ext4 rw 0 0\n\
             /dev/mmcblk0p4 /mnt/mmc ext4 rw 0 0\n\
             /dev/mmcblk0p5 /roms2 ext4 rw 0 0\n",
            &[],
        );
        assert_eq!(
            mounted_storage_roots(Some(dir.path())),
            vec![
                dir.path().join("mnt/mmc"),
                dir.path().join("roms2"),
                dir.path().join("run/media/player/SDCARD"),
                dir.path().join("storage"),
            ]
        );
    }

    #[test]
    fn internal_and_virtual_mounts_are_not_reported_as_cards() {
        let dir = fixture_with_mounts(
            "/dev/mmcblk1p2 /userdata ext4 rw 0 0\n\
             /dev/loop0 /opt/image squashfs ro 0 0\n\
             /dev/nvme0n1p2 /home ext4 rw 0 0\n\
             /dev/zram0 /data ext4 rw 0 0\n\
             /dev/mmcblk0p7 /mnt/vendor ext4 rw 0 0\n",
            &[],
        );
        assert!(mounted_storage_roots(Some(dir.path())).is_empty());
    }

    #[test]
    fn sd_boot_card_on_mmcblk0_is_not_discarded() {
        let dir = fixture_with_mounts(
            "/dev/mmcblk0p1 /boot vfat rw 0 0\n\
             /dev/mmcblk0p2 / ext4 rw 0 0\n\
             /dev/mmcblk0p3 /roms ext4 rw 0 0\n",
            &[],
        );
        fs::create_dir_all(dir.path().join("sys/class/block/mmcblk0")).unwrap();
        fs::write(dir.path().join("sys/class/block/mmcblk0/removable"), "1\n").unwrap();
        let roots = mounted_storage_roots(Some(dir.path()));
        assert_eq!(roots, vec![dir.path().join("roms")]);
    }

    #[test]
    fn configured_mmcblk0_data_partition_is_kept_without_sysfs() {
        let dir = fixture_with_mounts("/dev/mmcblk0p3 /roms ext4 rw 0 0\n", &[]);
        let roots = mounted_storage_roots(Some(dir.path()));
        assert_eq!(roots, vec![dir.path().join("roms")]);
    }

    #[test]
    fn no_mount_table_does_not_guess_platform_roots() {
        let dir = tempfile::tempdir().unwrap();
        let roots = mounted_storage_roots(Some(dir.path()));
        assert!(roots.is_empty());
    }
}
