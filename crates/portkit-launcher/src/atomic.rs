//! Local copy of the atomic file primitives this helper needs. Keeping them
//! here avoids linking `portkit-core` (and its TLS/HTTP dependency tree) into
//! a binary that is shipped inside every game port package.

use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

/// Durably replaces one ordinary file without exposing a partially-written
/// destination. Callers retain responsibility for validating that `path` is
/// inside their managed root before invoking this filesystem primitive.
pub fn atomic_write(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| std::io::Error::other("output path has no parent directory"))?;
    fs::create_dir_all(parent)?;
    let temporary = unique_sibling(path, "atomic-write");
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temporary, path)?;
        // Some removable-media filesystems reject directory fsync even after
        // the rename has committed. Do not turn a complete replacement into
        // a reported failure; the file itself was synced before the rename.
        let _ = File::open(parent).and_then(|directory| directory.sync_all());
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

/// Copies one regular file and atomically promotes the complete copy.
pub fn atomic_copy(source: &Path, destination: &Path) -> std::io::Result<()> {
    let parent = destination
        .parent()
        .ok_or_else(|| std::io::Error::other("destination path has no parent directory"))?;
    fs::create_dir_all(parent)?;
    let temporary = unique_sibling(destination, "atomic-copy");
    let result = (|| {
        fs::copy(source, &temporary)?;
        File::open(&temporary)?.sync_all()?;
        fs::rename(&temporary, destination)?;
        let _ = File::open(parent).and_then(|directory| directory.sync_all());
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn unique_sibling(path: &Path, label: &str) -> PathBuf {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let sequence = NEXT.fetch_add(1, Ordering::Relaxed);
    let mut name = path
        .file_name()
        .map_or_else(|| "output".into(), |value| value.to_os_string());
    name.push(format!(".{label}.{}.{}.tmp", std::process::id(), sequence));
    path.with_file_name(name)
}
