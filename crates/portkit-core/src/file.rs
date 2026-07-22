use std::fs::File;
use std::io::Read;
use std::path::Path;

use sha2::{Digest as _, Sha256};

use crate::{Error, Result};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DigestAlgorithm {
    Md5,
    Sha256,
}

impl DigestAlgorithm {
    pub fn parse(value: &str) -> Result<Self> {
        match value {
            "md5" => Ok(Self::Md5),
            "sha256" => Ok(Self::Sha256),
            _ => Err(Error::InvalidConfig(
                "digest algorithm must be md5 or sha256".to_owned(),
            )),
        }
    }
}

pub fn digest_file(path: &Path, algorithm: DigestAlgorithm) -> Result<String> {
    let mut file = File::open(path)?;
    let mut buffer = [0_u8; 64 * 1024];
    match algorithm {
        DigestAlgorithm::Md5 => {
            let mut digest = md5::Context::new();
            loop {
                let read = file.read(&mut buffer)?;
                if read == 0 {
                    break;
                }
                digest.consume(&buffer[..read]);
            }
            Ok(format!("{:x}", digest.compute()))
        }
        DigestAlgorithm::Sha256 => {
            let mut digest = Sha256::new();
            loop {
                let read = file.read(&mut buffer)?;
                if read == 0 {
                    break;
                }
                digest.update(&buffer[..read]);
            }
            Ok(format!("{:x}", digest.finalize()))
        }
    }
}

pub fn zip_readable(path: &Path) -> Result<bool> {
    let file = File::open(path)?;
    let mut archive = zip::ZipArchive::new(file)
        .map_err(|error| Error::InvalidConfig(format!("invalid ZIP archive: {error}")))?;
    if archive.is_empty() {
        return Ok(false);
    }
    for index in 0..archive.len() {
        archive
            .by_index_raw(index)
            .map_err(|error| Error::InvalidConfig(format!("invalid ZIP entry: {error}")))?;
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn streams_standard_file_digests() {
        let temp = tempfile::NamedTempFile::new().unwrap();
        std::fs::write(temp.path(), b"abc").unwrap();
        assert_eq!(
            digest_file(temp.path(), DigestAlgorithm::Md5).unwrap(),
            "900150983cd24fb0d6963f7d28e17f72"
        );
        assert_eq!(
            digest_file(temp.path(), DigestAlgorithm::Sha256).unwrap(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn zip_probe_requires_a_nonempty_readable_directory() {
        let temp = tempfile::NamedTempFile::new().unwrap();
        {
            let mut archive = zip::ZipWriter::new(temp.reopen().unwrap());
            archive
                .start_file("file.txt", zip::write::SimpleFileOptions::default())
                .unwrap();
            archive.write_all(b"body").unwrap();
            archive.finish().unwrap();
        }
        assert!(zip_readable(temp.path()).unwrap());
        std::fs::write(temp.path(), b"not a zip").unwrap();
        assert!(zip_readable(temp.path()).is_err());
    }
}
