// INPUT:  Explicit Linux Vulkan driver directory and required source revision.
// OUTPUT: Offline Release/ELF/import/manifest/hash validation without loading a driver.
// POS:    Shared native driver audit used before an independent graphics preflight.
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::error::Error;
use std::fs;
use std::path::Path;

type Result<T> = std::result::Result<T, Box<dyn Error>>;

fn bytes(data: &[u8], offset: u64, count: u64) -> Result<&[u8]> {
    let end = offset.checked_add(count).ok_or("ELF range overflow")?;
    data.get(usize::try_from(offset)?..usize::try_from(end)?)
        .ok_or_else(|| "truncated driver ELF".into())
}
fn u16_at(data: &[u8], offset: u64) -> Result<u16> {
    Ok(u16::from_le_bytes(bytes(data, offset, 2)?.try_into()?))
}
fn u32_at(data: &[u8], offset: u64) -> Result<u32> {
    Ok(u32::from_le_bytes(bytes(data, offset, 4)?.try_into()?))
}
fn u64_at(data: &[u8], offset: u64) -> Result<u64> {
    Ok(u64::from_le_bytes(bytes(data, offset, 8)?.try_into()?))
}

struct Segment {
    kind: u32,
    flags: u32,
    offset: u64,
    address: u64,
    size: u64,
    memory_size: u64,
}

pub fn check(root: &Path, source_revision: &str) -> Result<()> {
    let text = root.to_str().ok_or("driver path must be UTF-8")?;
    if !root.is_absolute()
        || text.contains([':', '\r', '\n', '\0'])
        || root.is_symlink()
        || !root.is_dir()
    {
        return Err("driver directory must be an absolute local single-ICD path".into());
    }
    for name in ["mali_icd.json", "sources.json", "libvulkan_malisx2.so"] {
        let path = root.join(name);
        if path.is_symlink() || !path.is_file() {
            return Err("missing regular Linux driver file".into());
        }
    }
    let source: Value = serde_json::from_slice(&fs::read(root.join("sources.json"))?)?;
    if source["platform"] != "linux-aarch64"
        || source["profile"] != "Release"
        || source["source_revision"] != source_revision
    {
        return Err("driver source/platform/Release identity mismatch".into());
    }
    let manifest: Value = serde_json::from_slice(&fs::read(root.join("mali_icd.json"))?)?;
    if manifest["ICD"]["library_path"] != "./libvulkan_malisx2.so" {
        return Err("driver manifest must select its local library".into());
    }
    let data = fs::read(root.join("libvulkan_malisx2.so"))?;
    if data.len() < 64
        || !data.starts_with(b"\x7fELF\x02\x01")
        || u16_at(&data, 16)? != 3
        || u16_at(&data, 18)? != 183
    {
        return Err("driver requires an AArch64 Linux shared library".into());
    }
    let offset = u64_at(&data, 32)?;
    let count = u16_at(&data, 56)?;
    if u16_at(&data, 52)? != 64 || u16_at(&data, 54)? != 56 || count == 0 || count > 256 {
        return Err("incomplete driver ELF headers".into());
    }
    bytes(&data, offset, u64::from(count) * 56)?;
    let mut segments = Vec::new();
    for index in 0..count {
        let at = offset + u64::from(index) * 56;
        let segment = Segment {
            kind: u32_at(&data, at)?,
            flags: u32_at(&data, at + 4)?,
            offset: u64_at(&data, at + 8)?,
            address: u64_at(&data, at + 16)?,
            size: u64_at(&data, at + 32)?,
            memory_size: u64_at(&data, at + 40)?,
        };
        bytes(&data, segment.offset, segment.size)?;
        if segment.size > segment.memory_size {
            return Err("truncated driver ELF segment".into());
        }
        segments.push(segment);
    }
    if !segments
        .iter()
        .any(|s| s.kind == 1 && s.flags & 1 != 0 && s.size != 0)
    {
        return Err("driver has no executable load segment".into());
    }
    let dynamic: Vec<_> = segments.iter().filter(|s| s.kind == 2).collect();
    if dynamic.len() != 1 || dynamic[0].size % 16 != 0 {
        return Err("invalid driver dynamic table".into());
    }
    let dynamic = dynamic[0];
    let mut entries = Vec::new();
    let mut terminated = false;
    for at in (dynamic.offset..dynamic.offset + dynamic.size).step_by(16) {
        let key = u64_at(&data, at)?;
        let value = u64_at(&data, at + 8)?;
        if key == 0 {
            terminated = true;
            break;
        }
        entries.push((key, value));
    }
    if !terminated {
        return Err("unterminated driver dynamic table".into());
    }
    let address = entries
        .iter()
        .rev()
        .find(|(key, _)| *key == 5)
        .map(|(_, v)| *v)
        .unwrap_or(0);
    let size = entries
        .iter()
        .rev()
        .find(|(key, _)| *key == 10)
        .map(|(_, v)| *v)
        .unwrap_or(0);
    let end = address
        .checked_add(size)
        .ok_or("invalid driver dynamic strings")?;
    let loads: Vec<_> = segments
        .iter()
        .filter(|s| {
            s.kind == 1
                && s.address <= address
                && s.address.checked_add(s.size).is_some_and(|v| end <= v)
        })
        .collect();
    if size == 0 || loads.len() != 1 {
        return Err("invalid driver dynamic strings".into());
    }
    let string_offset = loads[0]
        .offset
        .checked_add(address - loads[0].address)
        .ok_or("invalid driver string offset")?;
    let strings = bytes(&data, string_offset, size)?;
    let mut needed = Vec::new();
    for (_, index) in entries.iter().filter(|(key, _)| *key == 1) {
        let start = usize::try_from(*index)?;
        let tail = strings.get(start..).ok_or("invalid driver import name")?;
        let end = tail
            .iter()
            .position(|b| *b == 0)
            .ok_or("invalid driver import name")?;
        needed.push(&tail[..end]);
    }
    if !needed.contains(&b"libc.so.6".as_slice())
        || needed.contains(&b"liblog.so".as_slice())
        || needed.contains(&b"libc.so".as_slice())
    {
        return Err("Android/Bionic driver is not a Linux build".into());
    }
    let checksum = format!("{:x}", Sha256::digest(&data));
    if source["library_sha256"].as_str() != Some(checksum.as_str()) {
        return Err("driver checksum mismatch".into());
    }
    Ok(())
}
