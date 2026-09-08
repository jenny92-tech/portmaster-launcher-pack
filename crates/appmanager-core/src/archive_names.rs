// INPUT:  zip 目录元数据、chardetng 统计检测器、encoding_rs 严格解码
// OUTPUT: ZIP 条目按归档顺序解析后的 Unicode 文件名
// POS:    扫描、选择读取和解压共用的自动文件名编码边界
use std::io::{Read, Seek};

use chardetng::{EncodingDetector, Iso2022JpDetection, Utf8Detection};
use encoding_rs::{GB18030, GBK, WINDOWS_1252};
use zip::{HasZipMetadata, ZipArchive};

use crate::archive_bundle::is_ignored_metadata_path;

// Detection only needs names, never file contents. Bound work even for archives
// with many entries, and never cut a multibyte name at the sampling boundary.
const SAMPLE_BYTES: usize = 64 * 1024;

struct ZipName {
    raw: Vec<u8>,
    fallback: String,
    unicode: bool,
    dos: bool,
}

pub(crate) fn zip_entry_names<R: Read + Seek>(
    archive: &mut ZipArchive<R>,
) -> Result<Vec<String>, String> {
    let mut names = Vec::with_capacity(archive.len());
    for index in 0..archive.len() {
        let entry = archive
            .by_index_raw(index)
            .map_err(|error| error.to_string())?;
        let metadata = entry.get_metadata();
        names.push(ZipName {
            raw: entry.name_raw().to_vec(),
            fallback: entry.name().to_owned(),
            // zip validates Unicode Path extra-field CRCs and sets is_utf8
            // after applying them, just as it does for the UTF-8 header bit.
            unicode: metadata.is_utf8,
            dos: u8::from(metadata.system) == 0,
        });
    }
    decode_names(names)
}

fn decode_names(names: Vec<ZipName>) -> Result<Vec<String>, String> {
    let mut detector = EncodingDetector::new(Iso2022JpDetection::Deny);
    let mut sampled = 0;
    for name in &names {
        if std::str::from_utf8(&name.raw).is_ok() {
            continue;
        }
        if name.unicode {
            // A malformed explicit declaration is not permission to silently
            // replace bytes or reinterpret a potentially dangerous path.
            return Err("archive filename declares UTF-8 but contains invalid bytes".to_owned());
        }
        if !is_ignored_metadata_path(&name.fallback) && sampled + name.raw.len() + 1 <= SAMPLE_BYTES
        {
            detector.feed(&name.raw, false);
            detector.feed(b"\n", false);
            sampled += name.raw.len() + 1;
        }
    }
    detector.feed(b"", true);
    let guessed = detector.guess(None, Utf8Detection::Deny);
    // chardetng calls the entire GB18030 family GBK. Use the superset decoder.
    let encoding = if guessed == GBK { GB18030 } else { guessed };

    names
        .into_iter()
        .map(|name| {
            if let Ok(unicode) = std::str::from_utf8(&name.raw) {
                return Ok(unicode.to_owned());
            }
            // A detector of Web encodings has no CP437 candidate. Keep ZIP's
            // OEM default for DOS-produced names when the detector only offers
            // its ambiguous Western fallback, rather than corrupting café.zip.
            if sampled == 0 || (name.dos && encoding == WINDOWS_1252) {
                return Ok(name.fallback);
            }
            Ok(encoding
                .decode_without_bom_handling_and_without_replacement(&name.raw)
                .map(|value| value.into_owned())
                .unwrap_or(name.fallback))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::{self, File};
    use std::io::{Cursor, Write};
    use std::path::Path;

    use crate::archive_bundle;
    use crate::port_zip::{self, BundleLimits};

    fn legacy(raw: Vec<u8>, fallback: &str) -> ZipName {
        ZipName {
            raw,
            fallback: fallback.to_owned(),
            unicode: false,
            dos: true,
        }
    }

    #[test]
    fn detects_shared_port_names_in_east_asian_encodings() {
        for (encoding, expected) in [
            (GBK, "S_除虫大战-美版【横版动作】.sh"),
            (encoding_rs::BIG5, "遊戲資料/繁體中文遊戲說明文件.txt"),
            (
                encoding_rs::SHIFT_JIS,
                "ゲームデータ/日本語の説明と設定ファイル.txt",
            ),
            (encoding_rs::EUC_KR, "게임자료/게임설명과설정파일.txt"),
        ] {
            let (raw, _, errors) = encoding.encode(expected);
            assert!(!errors);
            let decoded = decode_names(vec![legacy(raw.into_owned(), "wrong")]).unwrap();
            assert_eq!(decoded, [expected], "{}", encoding.name());
        }
    }

    #[test]
    fn keeps_dos_cp437_names() {
        let decoded = decode_names(vec![legacy(
            b"caf\x82/na\x8bve.txt".to_vec(),
            "café/naïve.txt",
        )])
        .unwrap();
        assert_eq!(decoded, ["café/naïve.txt"]);
    }

    #[test]
    fn unicode_and_unmarked_utf8_are_not_reinterpreted_by_legacy_detection() {
        let (gbk, _, _) = GBK.encode("S_除虫大战-美版【横版动作】.sh");
        let names = vec![
            legacy(gbk.into_owned(), "wrong"),
            ZipName {
                raw: "明确的中文.sh".as_bytes().to_vec(),
                fallback: "wrong".into(),
                unicode: true,
                dos: true,
            },
            legacy("未标记的中文.txt".as_bytes().to_vec(), "wrong"),
        ];
        assert_eq!(
            decode_names(names).unwrap(),
            [
                "S_除虫大战-美版【横版动作】.sh",
                "明确的中文.sh",
                "未标记的中文.txt"
            ]
        );
    }

    // ZipWriter emits UTF-8. Replace only fixture header names (equal-length
    // ASCII placeholders) and their encoding bits, leaving payload CRCs/AES
    // records intact. No production archive parsing is reimplemented here.
    fn write_raw_zip(path: &Path, entries: &[(&[u8], bool, &[u8])], password: Option<&str>) {
        let mut writer = zip::ZipWriter::new(Cursor::new(Vec::new()));
        for (index, (raw, _, content)) in entries.iter().enumerate() {
            let mut placeholder = format!("{index:0width$}", width = raw.len());
            let mut options = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Stored);
            if let Some(password) = password {
                options = options.with_aes_encryption(zip::AesMode::Aes256, password);
            }
            if raw.ends_with(b"/") {
                placeholder.pop();
                placeholder.push('/');
                writer.add_directory(placeholder, options).unwrap();
            } else {
                writer.start_file(placeholder, options).unwrap();
                writer.write_all(content).unwrap();
            }
        }
        let mut bytes = writer.finish().unwrap().into_inner();
        let offsets = {
            let mut archive = ZipArchive::new(Cursor::new(&bytes)).unwrap();
            (0..archive.len())
                .map(|index| {
                    let entry = archive.by_index_raw(index).unwrap();
                    (
                        entry.header_start() as usize,
                        entry.central_header_start() as usize,
                    )
                })
                .collect::<Vec<_>>()
        };
        for ((local, central), (raw, utf8, _)) in offsets.into_iter().zip(entries) {
            bytes[local + 30..local + 30 + raw.len()].copy_from_slice(raw);
            bytes[central + 46..central + 46 + raw.len()].copy_from_slice(raw);
            bytes[central + 5] = 0; // DOS ZIP, like the real legacy sample.
            for offset in [local + 6, central + 8] {
                let flags = u16::from_le_bytes(bytes[offset..offset + 2].try_into().unwrap());
                let flags = (flags & !0x800) | if *utf8 { 0x800 } else { 0 };
                bytes[offset..offset + 2].copy_from_slice(&flags.to_le_bytes());
            }
        }
        fs::write(path, bytes).unwrap();
    }

    #[test]
    fn gbk_scanning_selected_reads_and_installation_use_the_same_names() {
        // Exact filename bytes from 除虫大战.zip, without copying game data.
        let raw_script = b"S_\xb3\xfd\xb3\xe6\xb4\xf3\xd5\xbd-\xc3\xc0\xb0\xe6\xa1\xbe\xba\xe1\xb0\xe6\xb6\xaf\xd7\xf7\xa1\xbf.sh";
        let expected_script = "S_除虫大战-美版【横版动作】.sh";
        let (raw_data, _, errors) = GBK.encode("bugscraper/中文资料/游戏说明文件.txt");
        assert!(!errors);
        let launcher = b"#!/bin/sh\nGAMEDIR=/ports/bugscraper\n";
        for password in [None, Some("fixture-password")] {
            let temp = tempfile::tempdir().unwrap();
            let path = temp.path().join("legacy.zip");
            write_raw_zip(
                &path,
                &[
                    (raw_script, false, launcher),
                    (&raw_data, false, b"payload"),
                ],
                password,
            );
            let bundle =
                port_zip::inspect_archive_bundle_with_password(&path, password, &|| false).unwrap();
            assert_eq!(bundle.entry_script, expected_script);
            assert_eq!(bundle.entry_data, "bugscraper");
            let roots = ["scripts", "games", "trash", "work"].map(|name| temp.path().join(name));
            for root in &roots {
                fs::create_dir(root).unwrap();
            }
            port_zip::install_bundle_replacing_with_password(
                &bundle,
                &roots[0],
                &roots[1],
                &[],
                &roots[2],
                &roots[3],
                &BundleLimits::default(),
                false,
                password,
                &|| false,
            )
            .unwrap();
            assert_eq!(fs::read(roots[0].join(expected_script)).unwrap(), launcher);
            assert_eq!(
                fs::read(roots[1].join("bugscraper/中文资料/游戏说明文件.txt")).unwrap(),
                b"payload"
            );
        }
    }

    #[test]
    fn rejects_invalid_declared_utf8_instead_of_writing_lossy_names() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("invalid-utf8.zip");
        write_raw_zip(&path, &[(b"invalid-\xff.sh", true, b"payload")], None);
        let mut file = File::open(path).unwrap();
        let error = archive_bundle::catalog(&mut file, "invalid-utf8.zip", None).unwrap_err();
        assert!(error.contains("declares UTF-8"), "{error}");
    }

    #[test]
    fn decoded_names_cannot_collide_or_escape_the_install_root() {
        let expected = "游戏文件说明.txt";
        let (legacy, _, errors) = GBK.encode(expected);
        assert!(!errors);
        for bad_entries in [
            vec![
                (legacy.as_ref(), false, b"first".as_slice()),
                (expected.as_bytes(), true, b"second".as_slice()),
            ],
            vec![(b"../outside.txt".as_slice(), false, b"outside".as_slice())],
        ] {
            let temp = tempfile::tempdir().unwrap();
            let path = temp.path().join("unsafe.zip");
            let mut entries = vec![
                (
                    b"game.sh".as_slice(),
                    false,
                    b"GAMEDIR=/ports/game\n".as_slice(),
                ),
                (b"game/data.bin".as_slice(), false, b"payload".as_slice()),
            ];
            entries.extend(bad_entries);
            write_raw_zip(&path, &entries, None);
            let bundle = port_zip::inspect_zip_bundle(&path, &|| false).unwrap();
            let roots = ["scripts", "games", "trash", "work"].map(|name| temp.path().join(name));
            for root in &roots {
                fs::create_dir(root).unwrap();
            }
            let error = port_zip::install_bundle_replacing(
                &bundle,
                &roots[0],
                &roots[1],
                &[],
                &roots[2],
                &roots[3],
                &BundleLimits::default(),
                false,
                &|| false,
            )
            .unwrap_err();
            assert!(
                error.contains("duplicate entry") || error.contains("unsafe path"),
                "{error}"
            );
            assert_eq!(fs::read_dir(&roots[0]).unwrap().count(), 0);
            assert_eq!(fs::read_dir(&roots[1]).unwrap().count(), 0);
            assert!(!temp.path().join("outside.txt").exists());
        }
    }

    #[test]
    fn shift_jis_trail_backslash_is_not_a_directory_separator() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("shift-jis.zip");
        let name = "ゲームの日本語説明表";
        let (raw, _, errors) = encoding_rs::SHIFT_JIS.encode(name);
        assert!(!errors);
        assert!(raw.ends_with(b"\\"));
        write_raw_zip(&path, &[(&raw, false, b"payload")], None);
        let mut file = File::open(path).unwrap();
        let catalog = archive_bundle::catalog(&mut file, "shift-jis.zip", None).unwrap();
        assert_eq!(catalog.entries[0].name, name);
        assert!(!catalog.entries[0].directory);
        let target = temp.path().join("extracted");
        archive_bundle::extract(&mut file, "shift-jis.zip", &target, None, &|| false).unwrap();
        assert_eq!(fs::read(target.join(name)).unwrap(), b"payload");
    }
}
