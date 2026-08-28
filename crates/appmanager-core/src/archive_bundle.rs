use std::borrow::Cow;
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::Path;

use sevenz_rust2::{Archive, ArchiveReader, EncoderMethod, Error as SevenZError, Password};
use zip::result::ZipError;
use zip::{CompressionMethod, ZipArchive};

pub(crate) const PASSWORD_REQUIRED: &str = "archive_password_required";
pub(crate) const INVALID_PASSWORD: &str = "archive_invalid_password";
pub(crate) const UNSUPPORTED_METHOD: &str = "archive_unsupported_method";
pub(crate) const UNSUPPORTED_FEATURE: &str = "archive_unsupported_feature";
pub(crate) const RESOURCE_LIMIT: &str = "archive_resource_limit";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ArchiveFormat {
    Zip,
    SevenZ,
}

impl ArchiveFormat {
    pub(crate) fn name(self) -> &'static str {
        match self {
            Self::Zip => "zip",
            Self::SevenZ => "7z",
        }
    }
}

#[derive(Debug, Clone)]
pub(crate) struct ArchiveEntry {
    pub(crate) name: String,
    pub(crate) directory: bool,
    pub(crate) size: u64,
    pub(crate) anti_item: bool,
}

#[derive(Debug, Clone)]
pub(crate) struct ArchiveCatalog {
    pub(crate) format: ArchiveFormat,
    pub(crate) entries: Vec<ArchiveEntry>,
    pub(crate) encrypted: bool,
}

pub(crate) fn detect_format(file: &mut File, label: &str) -> Result<ArchiveFormat, String> {
    file.seek(SeekFrom::Start(0))
        .map_err(|error| format!("seek {label}: {error}"))?;
    let mut signature = [0_u8; 6];
    let count = file
        .read(&mut signature)
        .map_err(|error| format!("read archive signature {label}: {error}"))?;
    file.seek(SeekFrom::Start(0))
        .map_err(|error| format!("seek {label}: {error}"))?;
    if count >= 4 && signature[..2] == *b"PK" {
        return Ok(ArchiveFormat::Zip);
    }
    if count == 6 && signature == [b'7', b'z', 0xbc, 0xaf, 0x27, 0x1c] {
        return Ok(ArchiveFormat::SevenZ);
    }
    Err("只支持 ZIP 或 7z 压缩包".to_owned())
}

pub(crate) fn catalog(
    file: &mut File,
    label: &str,
    password: Option<&str>,
) -> Result<ArchiveCatalog, String> {
    match detect_format(file, label)? {
        ArchiveFormat::Zip => zip_catalog(file, label),
        ArchiveFormat::SevenZ => sevenz_catalog(file, label, password),
    }
}

fn zip_catalog(file: &mut File, label: &str) -> Result<ArchiveCatalog, String> {
    file.seek(SeekFrom::Start(0))
        .map_err(|error| format!("seek {label}: {error}"))?;
    let mut archive = ZipArchive::new(file).map_err(|error| format!("{label}: {error}"))?;
    let mut entries = Vec::with_capacity(archive.len());
    let mut encrypted = false;
    for index in 0..archive.len() {
        let entry = archive
            .by_index_raw(index)
            .map_err(|error| map_zip_error(error, false))?;
        let name = std::str::from_utf8(entry.name_raw())
            .unwrap_or_else(|_| entry.name())
            .to_owned();
        #[allow(deprecated)]
        if !is_ignored_metadata_path(&name)
            && let CompressionMethod::Unsupported(method) = entry.compression()
        {
            return Err(format!(
                "{UNSUPPORTED_METHOD}: zip:{}",
                zip_method_description(method)
            ));
        }
        encrypted |= entry.encrypted();
        entries.push(ArchiveEntry {
            directory: entry.is_dir() || name.ends_with('/'),
            size: entry.size(),
            anti_item: false,
            name,
        });
    }
    Ok(ArchiveCatalog {
        format: ArchiveFormat::Zip,
        entries,
        encrypted,
    })
}

fn sevenz_catalog(
    file: &mut File,
    label: &str,
    password: Option<&str>,
) -> Result<ArchiveCatalog, String> {
    file.seek(SeekFrom::Start(0))
        .map_err(|error| format!("seek {label}: {error}"))?;
    let password_value = password.map_or_else(Password::empty, Password::new);
    let archive = Archive::read(file, &password_value)
        .map_err(|error| map_sevenz_error(error, password.is_some()))?;
    let encrypted = archive.blocks.iter().any(|block| {
        block
            .coders
            .iter()
            .any(|coder| coder.encoder_method_id() == EncoderMethod::ID_AES256_SHA256)
    });
    let entries = archive
        .files
        .iter()
        .map(|entry| ArchiveEntry {
            name: entry.name.clone(),
            directory: entry.is_directory,
            size: entry.size,
            anti_item: entry.is_anti_item,
        })
        .collect();
    Ok(ArchiveCatalog {
        format: ArchiveFormat::SevenZ,
        entries,
        encrypted,
    })
}

pub(crate) fn read_selected(
    file: &mut File,
    label: &str,
    catalog: &ArchiveCatalog,
    selected: &BTreeMap<String, u64>,
    password: Option<&str>,
    cancel: &dyn Fn() -> bool,
) -> Result<BTreeMap<String, Vec<u8>>, String> {
    match catalog.format {
        ArchiveFormat::Zip => read_selected_zip(file, label, selected, password, cancel),
        ArchiveFormat::SevenZ => read_selected_sevenz(file, label, selected, password, cancel),
    }
}

fn read_selected_zip(
    file: &mut File,
    label: &str,
    selected: &BTreeMap<String, u64>,
    password: Option<&str>,
    cancel: &dyn Fn() -> bool,
) -> Result<BTreeMap<String, Vec<u8>>, String> {
    file.seek(SeekFrom::Start(0))
        .map_err(|error| format!("seek {label}: {error}"))?;
    let mut archive = ZipArchive::new(file).map_err(|error| format!("{label}: {error}"))?;
    let mut output = BTreeMap::new();
    for index in 0..archive.len() {
        if cancel() {
            return Err("archive inspection cancelled".to_owned());
        }
        let (name, encrypted) = {
            let entry = archive
                .by_index_raw(index)
                .map_err(|error| map_zip_error(error, password.is_some()))?;
            let raw = std::str::from_utf8(entry.name_raw()).unwrap_or_else(|_| entry.name());
            (normalize_name(raw), entry.encrypted())
        };
        let Some(limit) = selected.get(&name).copied() else {
            continue;
        };
        let mut entry = if encrypted {
            let Some(password) = password else {
                return Err(PASSWORD_REQUIRED.to_owned());
            };
            archive
                .by_index_decrypt(index, password.as_bytes())
                .map_err(|error| map_zip_error(error, true))?
        } else {
            archive
                .by_index(index)
                .map_err(|error| map_zip_error(error, password.is_some()))?
        };
        let mut bytes = Vec::with_capacity(entry.size().min(limit) as usize);
        let copied = entry
            .by_ref()
            .take(limit.saturating_add(1))
            .read_to_end(&mut bytes)
            .map_err(|error| {
                if encrypted && password.is_some() {
                    format!("{INVALID_PASSWORD}: {error}")
                } else {
                    format!("cannot read {name:?}: {error}")
                }
            })? as u64;
        if copied > limit {
            return Err(format!("archive metadata changed while reading {name:?}"));
        }
        output.insert(name, bytes);
    }
    Ok(output)
}

fn read_selected_sevenz(
    file: &mut File,
    label: &str,
    selected: &BTreeMap<String, u64>,
    password: Option<&str>,
    cancel: &dyn Fn() -> bool,
) -> Result<BTreeMap<String, Vec<u8>>, String> {
    file.seek(SeekFrom::Start(0))
        .map_err(|error| format!("seek {label}: {error}"))?;
    let password_value = password.map_or_else(Password::empty, Password::new);
    let mut archive = ArchiveReader::new(&mut *file, password_value)
        .map_err(|error| map_sevenz_error(error, password.is_some()))?;
    let mut output = BTreeMap::new();
    if archive.archive().is_solid {
        archive
            .for_each_entries(|entry, reader| {
                if cancel() {
                    return Err(sevenz_io_error("archive inspection cancelled"));
                }
                let name = normalize_name(entry.name());
                let Some(limit) = selected.get(&name).copied() else {
                    copy_with_cancel(reader, &mut io::sink(), cancel)
                        .map_err(|error| sevenz_io_error(error.to_string()))?;
                    return Ok(true);
                };
                let mut bytes = Vec::with_capacity(entry.size.min(limit) as usize);
                let copied = reader
                    .take(limit.saturating_add(1))
                    .read_to_end(&mut bytes)
                    .map_err(|error| sevenz_io_error(error.to_string()))?
                    as u64;
                if copied > limit {
                    return Err(sevenz_io_error(format!(
                        "archive metadata changed while reading {name:?}"
                    )));
                }
                output.insert(name, bytes);
                Ok(output.len() < selected.len())
            })
            .map_err(|error| map_sevenz_error(error, password.is_some()))?;
    } else {
        for (target, limit) in selected {
            if cancel() {
                return Err("archive inspection cancelled".to_owned());
            }
            let raw_name = archive
                .archive()
                .files
                .iter()
                .find(|entry| normalize_name(&entry.name) == *target)
                .map(|entry| entry.name.clone())
                .ok_or_else(|| format!("archive entry disappeared: {target:?}"))?;
            let bytes = archive
                .read_file(&raw_name)
                .map_err(|error| map_sevenz_error(error, password.is_some()))?;
            if bytes.len() as u64 > *limit {
                return Err(format!("archive metadata changed while reading {target:?}"));
            }
            output.insert(target.clone(), bytes);
        }
    }
    if output.len() != selected.len() {
        return Err("archive entries changed during inspection".to_owned());
    }
    Ok(output)
}

pub(crate) fn extract(
    file: &mut File,
    label: &str,
    target: &Path,
    password: Option<&str>,
    cancel: &dyn Fn() -> bool,
) -> Result<(), String> {
    match detect_format(file, label)? {
        ArchiveFormat::Zip => extract_zip(file, label, target, password, cancel),
        ArchiveFormat::SevenZ => extract_sevenz(file, label, target, password, cancel),
    }
}

fn extract_zip(
    file: &mut File,
    label: &str,
    target: &Path,
    password: Option<&str>,
    cancel: &dyn Fn() -> bool,
) -> Result<(), String> {
    file.seek(SeekFrom::Start(0))
        .map_err(|error| format!("seek {label}: {error}"))?;
    let mut archive = ZipArchive::new(file).map_err(|error| format!("{label}: {error}"))?;
    for index in 0..archive.len() {
        if cancel() {
            return Err("archive extraction cancelled".to_owned());
        }
        let (raw, encrypted) = {
            let entry = archive
                .by_index_raw(index)
                .map_err(|error| map_zip_error(error, password.is_some()))?;
            let raw = std::str::from_utf8(entry.name_raw())
                .unwrap_or_else(|_| entry.name())
                .to_owned();
            (raw, entry.encrypted())
        };
        let relative = normalize_name(&raw);
        if is_ignored_metadata_path(&relative) {
            continue;
        }
        let mut entry = if encrypted {
            let Some(password) = password else {
                return Err(PASSWORD_REQUIRED.to_owned());
            };
            archive
                .by_index_decrypt(index, password.as_bytes())
                .map_err(|error| map_zip_error(error, true))?
        } else {
            archive
                .by_index(index)
                .map_err(|error| map_zip_error(error, password.is_some()))?
        };
        let output = target.join(relative.trim_end_matches('/'));
        if entry.is_dir() || raw.ends_with('/') {
            fs::create_dir_all(&output).map_err(|error| error.to_string())?;
            continue;
        }
        if let Some(parent) = output.parent() {
            fs::create_dir_all(parent).map_err(|error| error.to_string())?;
        }
        let mut destination = File::create(&output).map_err(|error| error.to_string())?;
        copy_with_cancel(&mut entry, &mut destination, cancel).map_err(|error| {
            if encrypted && password.is_some() {
                format!("{INVALID_PASSWORD}: {error}")
            } else {
                error.to_string()
            }
        })?;
    }
    Ok(())
}

fn extract_sevenz(
    file: &mut File,
    label: &str,
    target: &Path,
    password: Option<&str>,
    cancel: &dyn Fn() -> bool,
) -> Result<(), String> {
    file.seek(SeekFrom::Start(0))
        .map_err(|error| format!("seek {label}: {error}"))?;
    let password_value = password.map_or_else(Password::empty, Password::new);
    let mut archive = ArchiveReader::new(&mut *file, password_value)
        .map_err(|error| map_sevenz_error(error, password.is_some()))?;
    archive
        .for_each_entries(|entry, reader| {
            if cancel() {
                return Err(sevenz_io_error("archive extraction cancelled"));
            }
            let relative = normalize_name(entry.name());
            if is_ignored_metadata_path(&relative) {
                copy_with_cancel(reader, &mut io::sink(), cancel)
                    .map_err(|error| sevenz_io_error(error.to_string()))?;
                return Ok(true);
            }
            let output = target.join(relative.trim_end_matches('/'));
            if entry.is_directory() {
                fs::create_dir_all(&output).map_err(|error| sevenz_io_error(error.to_string()))?;
            } else {
                if let Some(parent) = output.parent() {
                    fs::create_dir_all(parent)
                        .map_err(|error| sevenz_io_error(error.to_string()))?;
                }
                let mut destination =
                    File::create(&output).map_err(|error| sevenz_io_error(error.to_string()))?;
                copy_with_cancel(reader, &mut destination, cancel)
                    .map_err(|error| sevenz_io_error(error.to_string()))?;
            }
            Ok(true)
        })
        .map_err(|error| map_sevenz_error(error, password.is_some()))
}

fn copy_with_cancel(
    input: &mut dyn Read,
    output: &mut dyn Write,
    cancel: &dyn Fn() -> bool,
) -> io::Result<u64> {
    let mut copied = 0_u64;
    let mut buffer = [0_u8; 128 * 1024];
    loop {
        if cancel() {
            return Err(io::Error::new(
                io::ErrorKind::Interrupted,
                "archive extraction cancelled",
            ));
        }
        let count = input.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        output.write_all(&buffer[..count])?;
        copied = copied.saturating_add(count as u64);
    }
    Ok(copied)
}

fn sevenz_io_error(message: impl Into<String>) -> SevenZError {
    SevenZError::Io(
        io::Error::other(message.into()),
        Cow::Borrowed("APP Manager archive extraction"),
    )
}

fn map_zip_error(error: ZipError, password_supplied: bool) -> String {
    match error {
        ZipError::UnsupportedArchive(message) if message == ZipError::PASSWORD_REQUIRED => {
            PASSWORD_REQUIRED.to_owned()
        }
        ZipError::UnsupportedArchive(message) => {
            let category = if message.to_ascii_lowercase().contains("compression") {
                UNSUPPORTED_METHOD
            } else {
                UNSUPPORTED_FEATURE
            };
            format!("{category}: zip:{message}")
        }
        ZipError::InvalidPassword => INVALID_PASSWORD.to_owned(),
        other if password_supplied => match &other {
            ZipError::Io(_) | ZipError::InvalidArchive(_) => {
                format!("{INVALID_PASSWORD}: {other}")
            }
            _ => other.to_string(),
        },
        other => other.to_string(),
    }
}

fn map_sevenz_error(error: SevenZError, password_supplied: bool) -> String {
    match error {
        SevenZError::PasswordRequired => PASSWORD_REQUIRED.to_owned(),
        SevenZError::MaybeBadPassword(_) if !password_supplied => PASSWORD_REQUIRED.to_owned(),
        SevenZError::MaybeBadPassword(_) if password_supplied => INVALID_PASSWORD.to_owned(),
        SevenZError::UnsupportedCompressionMethod(method) => {
            format!("{UNSUPPORTED_METHOD}: 7z:{method}")
        }
        SevenZError::ExternalUnsupported => {
            format!("{UNSUPPORTED_METHOD}: 7z:external codec")
        }
        SevenZError::UnsupportedVersion { major, minor } => {
            format!("{UNSUPPORTED_FEATURE}: 7z:format version {major}.{minor}")
        }
        SevenZError::Unsupported(message) => {
            format!("{UNSUPPORTED_FEATURE}: 7z:{message}")
        }
        SevenZError::MaxMemLimited { max_kb, actaul_kb } => format!(
            "{RESOURCE_LIMIT}: 7z:decoder limit {max_kb} KiB, archive requires {actaul_kb} KiB"
        ),
        SevenZError::Io(error, _) if error.kind() == io::ErrorKind::Interrupted => {
            error.to_string()
        }
        SevenZError::ChecksumVerificationFailed if password_supplied => INVALID_PASSWORD.to_owned(),
        other => other.to_string(),
    }
}

fn zip_method_description(method: u16) -> String {
    let name = match method {
        1 => "Shrink",
        2..=5 => "Reduce",
        6 | 10 => "Implode",
        8 => "Deflate",
        9 => "Deflate64",
        12 => "BZip2",
        14 => "LZMA",
        20 => "legacy Zstandard",
        93 => "Zstandard",
        94 => "MP3",
        95 => "XZ",
        96 => "JPEG",
        97 => "WavPack",
        98 => "PPMd",
        99 => "AES",
        _ => "unknown",
    };
    format!("{name} (method {method})")
}

pub(crate) fn normalize_name(value: &str) -> String {
    let mut output = value.replace('\\', "/");
    while output.starts_with("./") {
        output = output[2..].to_owned();
    }
    output.trim_matches('/').to_owned()
}

pub(crate) fn is_ignored_metadata_path(value: &str) -> bool {
    let normalized = value.replace('\\', "/");
    normalized.trim_matches('/').split('/').any(|component| {
        component.starts_with("._")
            || matches!(
                component,
                "__MACOSX"
                    | ".DS_Store"
                    | ".Spotlight-V100"
                    | ".Trashes"
                    | ".fseventsd"
                    | ".TemporaryItems"
                    | ".DocumentRevisions-V100"
                    | "Icon\r"
            )
    })
}

pub(crate) fn validate_catalog_uniqueness(
    entries: &[ArchiveEntry],
) -> Result<BTreeMap<String, bool>, String> {
    let mut paths = BTreeMap::new();
    let mut seen_raw = BTreeSet::new();
    for entry in entries {
        let relative = entry.name.trim_start_matches("./");
        let normalized = relative.trim_end_matches('/').to_owned();
        if !seen_raw.insert(normalized.clone()) {
            return Err(format!("archive contains duplicate entry: {normalized}"));
        }
        paths.insert(normalized, entry.directory);
    }
    Ok(paths)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unsupported_archive_errors_keep_the_actionable_method_or_feature() {
        assert_eq!(
            map_zip_error(
                ZipError::UnsupportedArchive("Compression method not supported"),
                false,
            ),
            "archive_unsupported_method: zip:Compression method not supported"
        );
        assert_eq!(
            map_sevenz_error(
                SevenZError::UnsupportedCompressionMethod("03-01-01".to_owned()),
                false,
            ),
            "archive_unsupported_method: 7z:03-01-01"
        );
        assert_eq!(zip_method_description(98), "PPMd (method 98)");
    }

    #[test]
    fn password_errors_do_not_become_unsupported_archive_reports() {
        assert_eq!(
            map_zip_error(
                ZipError::UnsupportedArchive(ZipError::PASSWORD_REQUIRED),
                false,
            ),
            PASSWORD_REQUIRED
        );
        assert_eq!(
            map_sevenz_error(SevenZError::PasswordRequired, false),
            PASSWORD_REQUIRED
        );
    }
}
