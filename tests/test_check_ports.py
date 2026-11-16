"""Synthetic source/artwork fixtures; no game, device, package or personal files."""
import importlib.util
import hashlib
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('check_ports', ROOT / '_kit/check_ports.py')
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


def png(width=1, height=1):
    def chunk(kind, raw):
        return struct.pack('>I', len(raw)) + kind + raw + struct.pack('>I', zlib.crc32(kind + raw) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b'\0' + b'\xff' * width * 4)) + chunk(b'IEND', b'')


class CheckPortsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.port = self.root / 'ports/example'
        (self.port / 'src').mkdir(parents=True)
        (self.port / 'src/launcher.sh').write_text('#!/bin/bash\ntrue\n')
        self.manifest = {'script':'Je-Example.sh','port_dir':'example','launcher_sh':'src/launcher.sh'}
        self.write_manifest()

    def write_manifest(self):
        (self.port / 'manifest.json').write_text(json.dumps(self.manifest))

    def findings(self, rule):
        return [x for x in checker.audit(self.root)['findings'] if x['rule'] == rule]

    def test_missing_cover_is_visible_and_audit_does_not_write_into_source(self):
        before = set(self.root.rglob('*'))
        self.assertEqual(self.findings('entry')[0]['status'], 'pass')
        self.assertEqual(self.findings('artwork')[0]['status'], 'warning')
        self.assertEqual(set(self.root.rglob('*')), before)

    def test_explicit_image_missing_crc_corruption_and_non_square_app_icon_fail(self):
        self.manifest.update(portmaster={'image':{'screenshot':'screenshot.png'}},trimui_app={'icon':'icon.png'})
        self.write_manifest()
        self.assertTrue(all(x['status']=='error' for x in self.findings('artwork')))
        (self.port/'screenshot.png').write_bytes(png())
        (self.port/'icon.png').write_bytes(png(2,1))
        self.assertEqual([x['status'] for x in self.findings('artwork')],['pass','error'])
        (self.port/'screenshot.png').write_bytes(png()[:-1]+b'!')
        self.assertEqual(self.findings('artwork')[0]['status'],'error')

    def test_debug_and_source_traversal_are_rejected_but_python_is_a_dependency_warning(self):
        (self.port/'src/launcher.sh').write_text('#!/bin/bash\nexec python3 helper.py\n')
        self.assertEqual(self.findings('runtime-python')[0]['status'],'warning')
        for body in ['exec /kit/portkit-debug-launch run', 'exec python3 "$ROOT/guest-exec-view.py"']:
            (self.port/'src/launcher.sh').write_text('#!/bin/bash\n'+body+'\n')
            self.assertEqual(self.findings('release/debug')[0]['status'],'error')
        (self.port/'src/launcher.sh').write_text('#!/bin/bash\nif then; fi\n')
        self.assertTrue(self.findings('manifest/entry'))
        self.manifest['launcher_sh']='../../outside.sh';self.write_manifest()
        self.assertTrue(self.findings('manifest/entry'))

    def test_explicit_bundled_runtime_and_appmanager_name_are_not_blanket_banned(self):
        self.manifest['script']='APP Manager.sh';self.write_manifest()
        (self.port/'src/launcher.sh').write_text('#!/bin/bash\nexec "$ROOT/runtime/python3" "$ROOT/app.py"\n')
        self.assertEqual(self.findings('entry')[0]['status'],'pass')

    def test_declared_wrong_optional_types_are_not_treated_as_missing(self):
        for patch in [{'launcher_sh':[]},{'launcher_sh':False},{'portmaster':{'image':[]}},{'trimui_app':False}]:
            with self.subTest(patch=patch):
                original=self.manifest.copy();self.manifest.update(patch);self.write_manifest()
                self.assertTrue(self.findings('manifest/entry'))
                self.manifest=original

    def test_monthly_report_requires_correct_types_paired_markdown_and_contract_scope(self):
        markdown=b'complete report\n'
        report={'root':str(self.root),'checked_at':'2026-11-01T10:00:00+08:00','counts':{'error':2},'contracts_requested':False,'checker_sha256':checker.CHECKER_SHA256,'markdown_sha256':hashlib.sha256(markdown).hexdigest()}
        reusable=lambda value,contracts=False,body=markdown:checker.reusable_report(value,self.root,'2026-11',contracts,body)
        self.assertTrue(reusable(report))
        self.assertFalse(reusable(report,True))
        report['contracts_requested']=True
        self.assertTrue(reusable(report,True))
        self.assertFalse(reusable(report,True,b'incomplete markdown'))
        self.assertFalse(reusable(dict(report,checker_sha256='old rules')))
        for counts in [None,[],'invalid',{'error':True},{'error':'1'}]:
            self.assertFalse(reusable(dict(report,counts=counts)))
        for stamp in [None,17,'2026-11-broken']:
            self.assertFalse(reusable(dict(report,checked_at=stamp)))
        self.assertFalse(reusable([]))

    def test_debug_product_with_matching_source_revision_is_rejected(self):
        kit=self.root/'_kit';(kit/'runtime').mkdir(parents=True)
        revision='a'*64
        (kit/'portkit_launcher_revision.py').write_text('print('+repr(revision)+')\n')
        (kit/'portkit-launcher-revision.txt').write_text(revision+'\n')
        raw=bytearray(64);raw[:7]=b'\x7fELF\x02\x01\x01';struct.pack_into('<H',raw,18,183)
        (kit/'runtime/portkit-launcher.aarch64').write_bytes(raw+revision.encode()+b'portkit-launcher 1\0portkit-debug-launch 1\0')
        self.assertEqual(self.findings('release-identity')[0]['status'],'error')
        (kit/'runtime/portkit-launcher.aarch64').write_bytes(raw+revision.encode()+b'portkit-launcher 1\0')
        self.assertEqual(self.findings('release-identity')[0]['status'],'pass')


if __name__ == '__main__':
    unittest.main()
