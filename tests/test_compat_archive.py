#!/usr/bin/env python3
# INPUT:  已归档 WSI、artifact.json、静态验证器与隔离临时副本
# OUTPUT: 真实产物、损坏文件、错架构、LFS 指针、路径逃逸和额外文件断言
# POS:    校验可复用兼容产物的完整性，不加载 ELF 或操作设备
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / '_kit/compat/vulkan-wsi-arm64-wayland'
SPEC = importlib.util.spec_from_file_location('compat_archive_verify', ROOT / '_kit/compat/verify.py')
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)


class CompatArchiveTests(unittest.TestCase):
    def fixture(self):
        temp = tempfile.TemporaryDirectory(prefix='compat-archive-')
        self.addCleanup(temp.cleanup)
        root = Path(temp.name) / 'artifact'
        shutil.copytree(ARCHIVE, root)
        return root

    def test_frozen_archive_matches_known_binary_identity(self):
        result = VERIFY.verify_archive(ARCHIVE)
        self.assertEqual(result['binary_bytes'], 352096)
        self.assertEqual(result['binary_sha256'], 'ed454d770a5908d94875ab5cf60b6b0d428fe9b31b8e87311ed0c1f928db0cc8')
        record = json.loads((ARCHIVE / 'artifact.json').read_text())
        self.assertEqual(record['requires']['max_required_symbol_versions']['GLIBC'], '2.30')
        self.assertTrue(record['role']['connects_from'] and record['role']['connects_to'])
        template = json.loads((ARCHIVE / record['integration']['godot_manifest']).read_text())
        self.assertEqual(template['layer']['library_path'], '@PORTKIT_WSI_LIBRARY@')
        self.assertEqual(template['layer']['enable_environment'], {'PORTKIT_GODOT_WSI': '1'})

    def test_binary_corruption_is_rejected(self):
        root = self.fixture()
        library = root / 'libVkLayer_window_system_integration.so'
        data = bytearray(library.read_bytes())
        data[-1] ^= 1
        library.write_bytes(data)
        with self.assertRaisesRegex(ValueError, 'SHA256 mismatch'):
            VERIFY.verify_archive(root)

    def test_changed_patch_is_rejected(self):
        root = self.fixture()
        (root / 'patches/wsi-ext-timestamps.patch').write_text('unrecorded patch')
        with self.assertRaisesRegex(ValueError, 'SHA256 mismatch'):
            VERIFY.verify_archive(root)

    def test_lfs_pointer_has_a_specific_restore_message(self):
        root = self.fixture()
        (root / 'libVkLayer_window_system_integration.so').write_text('version https://git-lfs.github.com/spec/v1\noid sha256:fixture\nsize 352096\n')
        with self.assertRaisesRegex(ValueError, 'git lfs pull'):
            VERIFY.verify_archive(root)

    def test_wrong_architecture_is_rejected_even_with_updated_hashes(self):
        root = self.fixture()
        record = json.loads((root / 'artifact.json').read_text())
        library = root / record['binary']['path']
        data = bytearray(library.read_bytes())
        data[18:20] = (62).to_bytes(2, 'little')
        library.write_bytes(data)
        record['binary']['sha256'] = hashlib.sha256(data).hexdigest()
        record['files'][library.name]['sha256'] = record['binary']['sha256']
        (root / 'artifact.json').write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError, 'AArch64'):
            VERIFY.verify_archive(root)

    def test_extra_binary_file_is_rejected(self):
        root = self.fixture()
        (root / 'unrecorded.so').write_bytes(b'unrecorded')
        with self.assertRaisesRegex(ValueError, 'file list'):
            VERIFY.verify_archive(root)

    def test_paths_and_links_cannot_escape_archive(self):
        root = self.fixture()
        with self.assertRaisesRegex(ValueError, 'escapes'):
            VERIFY.archive_file(root, '../outside')
        (root / 'linked').symlink_to(root.parent)
        with self.assertRaisesRegex(ValueError, 'escapes'):
            VERIFY.archive_file(root, 'linked/outside')


if __name__ == '__main__':
    unittest.main()
