use std::fs::File;
use std::io::{self, Read};
use std::path::{Path, PathBuf};

use lzma_rust2::XzReader;
use serde::Serialize;

const MIN_FONT_BYTES: u64 = 1_000_001;
const MAX_FONT_BYTES: u64 = 64 * 1024 * 1024;
const MAX_NESTED_XZ_BYTES: u64 = 128 * 1024 * 1024;
const MAX_TAR_STREAM_BYTES: u64 = 512 * 1024 * 1024;

#[derive(Clone, Debug)]
pub(crate) struct ProvisionRequest {
    pub candidates: Vec<PathBuf>,
    pub tar_xz_sources: Vec<PathBuf>,
    pub zip_sources: Vec<PathBuf>,
    pub outputs: Vec<PathBuf>,
    pub member: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum ProvisionSource {
    Existing,
    TarXz,
    Zip,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub(crate) struct ProvisionOutcome {
    pub path: PathBuf,
    pub source: ProvisionSource,
}

pub(crate) fn provision(request: &ProvisionRequest) -> io::Result<ProvisionOutcome> {
    validate_member(&request.member)?;
    for path in &request.candidates {
        if valid_font(path) {
            return Ok(ProvisionOutcome {
                path: path.clone(),
                source: ProvisionSource::Existing,
            });
        }
    }
    if request.outputs.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "font provision requires at least one output",
        ));
    }

    let mut last_error = None;
    for source in &request.tar_xz_sources {
        if !source.is_file() {
            continue;
        }
        match File::open(source).and_then(|file| extract_tar_xz_member(file, &request.member)) {
            Ok(font) => return write_first(&request.outputs, &font, ProvisionSource::TarXz),
            Err(error) => last_error = Some(error),
        }
    }
    for source in &request.zip_sources {
        if !source.is_file() {
            continue;
        }
        match extract_nested_tar_xz(source, &request.member) {
            Ok(font) => return write_first(&request.outputs, &font, ProvisionSource::Zip),
            Err(error) => last_error = Some(error),
        }
    }
    Err(last_error.unwrap_or_else(|| {
        io::Error::new(io::ErrorKind::NotFound, "no usable font source was found")
    }))
}

fn validate_member(member: &str) -> io::Result<()> {
    if member.is_empty()
        || matches!(member, "." | "..")
        || member.contains(['/', '\\', '\0', '\t', '\r', '\n'])
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "font member must be one safe file name",
        ));
    }
    Ok(())
}

fn valid_font(path: &Path) -> bool {
    let Ok(metadata) = path.metadata() else {
        return false;
    };
    if !metadata.is_file() || metadata.len() < MIN_FONT_BYTES || metadata.len() > MAX_FONT_BYTES {
        return false;
    }
    let mut magic = [0_u8; 4];
    File::open(path)
        .and_then(|mut file| file.read_exact(&mut magic))
        .is_ok()
        && font_magic_valid(&magic)
}

fn font_magic_valid(magic: &[u8; 4]) -> bool {
    matches!(magic, b"OTTO" | b"ttcf" | b"true") || magic == &[0, 1, 0, 0]
}

fn extract_nested_tar_xz(path: &Path, member: &str) -> io::Result<Vec<u8>> {
    let file = File::open(path)?;
    let mut archive = zip::ZipArchive::new(file).map_err(invalid_data)?;
    for index in 0..archive.len() {
        let mut entry = archive.by_index(index).map_err(invalid_data)?;
        let name = Path::new(entry.name())
            .file_name()
            .and_then(|value| value.to_str());
        if name != Some("NotoSans.tar.xz") {
            continue;
        }
        if !entry.is_file() || entry.size() == 0 || entry.size() > MAX_NESTED_XZ_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "nested NotoSans.tar.xz has an invalid size",
            ));
        }
        return extract_tar_xz_member((&mut entry).take(MAX_NESTED_XZ_BYTES + 1), member);
    }
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        "ZIP does not contain NotoSans.tar.xz",
    ))
}

fn extract_tar_xz_member(reader: impl Read, member: &str) -> io::Result<Vec<u8>> {
    let decoder = XzReader::new(reader, false);
    let limited = decoder.take(MAX_TAR_STREAM_BYTES);
    let mut archive = tar::Archive::new(limited);
    for entry in archive.entries()? {
        let mut entry = entry?;
        if !entry.header().entry_type().is_file() {
            continue;
        }
        let path = entry.path()?;
        if path.file_name().and_then(|value| value.to_str()) != Some(member) {
            continue;
        }
        let size = entry.size();
        if !(MIN_FONT_BYTES..=MAX_FONT_BYTES).contains(&size) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "font member has an invalid size",
            ));
        }
        let mut font = Vec::with_capacity(size as usize);
        (&mut entry)
            .take(MAX_FONT_BYTES + 1)
            .read_to_end(&mut font)?;
        if font.len() as u64 != size || !font_magic_valid(font[..4].try_into().unwrap()) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "font member failed validation",
            ));
        }
        return Ok(font);
    }
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        "font member is missing from NotoSans.tar.xz",
    ))
}

fn write_first(
    outputs: &[PathBuf],
    font: &[u8],
    source: ProvisionSource,
) -> io::Result<ProvisionOutcome> {
    let mut last_error = None;
    for output in outputs {
        match portkit_core::atomic_write(output, font) {
            Ok(()) if valid_font(output) => {
                return Ok(ProvisionOutcome {
                    path: output.clone(),
                    source,
                });
            }
            Ok(()) => {
                last_error = Some(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "written font failed validation",
                ));
            }
            Err(error) => last_error = Some(error),
        }
    }
    Err(last_error.unwrap_or_else(|| {
        io::Error::new(
            io::ErrorKind::PermissionDenied,
            "no font output is writable",
        )
    }))
}

fn invalid_data(error: impl std::fmt::Display) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Cursor, Write};

    fn font() -> Vec<u8> {
        let mut value = vec![0_u8; MIN_FONT_BYTES as usize];
        value[..4].copy_from_slice(&[0, 1, 0, 0]);
        value
    }

    fn tar_xz(member: &str, bytes: &[u8]) -> Vec<u8> {
        let mut tar_bytes = Vec::new();
        {
            let mut archive = tar::Builder::new(&mut tar_bytes);
            let mut header = tar::Header::new_gnu();
            header.set_size(bytes.len() as u64);
            header.set_mode(0o644);
            header.set_cksum();
            archive
                .append_data(&mut header, member, Cursor::new(bytes))
                .unwrap();
            archive.finish().unwrap();
        }
        let mut writer =
            lzma_rust2::XzWriter::new(Vec::new(), lzma_rust2::XzOptions::with_preset(1)).unwrap();
        writer.write_all(&tar_bytes).unwrap();
        writer.finish().unwrap()
    }

    #[test]
    fn provisions_from_direct_tar_xz_without_system_archive_tools() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("NotoSans.tar.xz");
        let output = temp.path().join("font.ttf");
        let expected = font();
        std::fs::write(
            &source,
            tar_xz("resources/NotoSansSC-Regular.ttf", &expected),
        )
        .unwrap();
        let outcome = provision(&ProvisionRequest {
            candidates: Vec::new(),
            tar_xz_sources: vec![source],
            zip_sources: Vec::new(),
            outputs: vec![output.clone()],
            member: "NotoSansSC-Regular.ttf".into(),
        })
        .unwrap();
        assert_eq!(outcome.source, ProvisionSource::TarXz);
        assert_eq!(std::fs::read(output).unwrap(), expected);
    }

    #[test]
    fn provisions_from_nested_zip_and_reuses_a_valid_candidate() {
        let temp = tempfile::tempdir().unwrap();
        let zip_path = temp.path().join("pylibs.zip");
        let expected = font();
        {
            let file = File::create(&zip_path).unwrap();
            let mut archive = zip::ZipWriter::new(file);
            archive
                .start_file(
                    "pylibs/resources/NotoSans.tar.xz",
                    zip::write::SimpleFileOptions::default(),
                )
                .unwrap();
            archive
                .write_all(&tar_xz("NotoSansSC-Regular.ttf", &expected))
                .unwrap();
            archive.finish().unwrap();
        }
        let output = temp.path().join("font.ttf");
        let outcome = provision(&ProvisionRequest {
            candidates: Vec::new(),
            tar_xz_sources: Vec::new(),
            zip_sources: vec![zip_path],
            outputs: vec![output.clone()],
            member: "NotoSansSC-Regular.ttf".into(),
        })
        .unwrap();
        assert_eq!(outcome.source, ProvisionSource::Zip);
        let reused = provision(&ProvisionRequest {
            candidates: vec![output.clone()],
            tar_xz_sources: Vec::new(),
            zip_sources: Vec::new(),
            outputs: vec![temp.path().join("unused.ttf")],
            member: "NotoSansSC-Regular.ttf".into(),
        })
        .unwrap();
        assert_eq!(reused.source, ProvisionSource::Existing);
        assert_eq!(reused.path, output);
    }

    #[test]
    fn rejects_unsafe_member() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("NotoSans.tar.xz");
        std::fs::write(&source, tar_xz("font.ttf", b"tiny")).unwrap();
        let request = ProvisionRequest {
            candidates: Vec::new(),
            tar_xz_sources: vec![source],
            zip_sources: Vec::new(),
            outputs: vec![temp.path().join("font.ttf")],
            member: "../font.ttf".into(),
        };
        assert_eq!(
            provision(&request).unwrap_err().kind(),
            io::ErrorKind::InvalidInput
        );
    }

    #[test]
    fn rejects_invalid_font_contents() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("NotoSans.tar.xz");
        std::fs::write(
            &source,
            tar_xz(
                "NotoSansSC-Regular.ttf",
                &vec![0_u8; MIN_FONT_BYTES as usize],
            ),
        )
        .unwrap();
        let request = ProvisionRequest {
            candidates: Vec::new(),
            tar_xz_sources: vec![source],
            zip_sources: Vec::new(),
            outputs: vec![temp.path().join("font.ttf")],
            member: "NotoSansSC-Regular.ttf".into(),
        };
        assert_eq!(
            provision(&request).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
    }
}
