# INPUT:  STS2 resumable uploader and synthetic local transport
# OUTPUT: binary chunk transfer, resume and filesystem-safety regressions
# POS:    local fixture; never connects to a device
import hashlib
import importlib.util
import json
import os
import shlex
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'ports/sts2/src/tools/device_tools/upload_texture.py'
spec = importlib.util.spec_from_file_location('texture_upload', SCRIPT)
upload = None
if SCRIPT.exists():
    upload = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(upload)


class LocalTransport:
    """Execute remote shell operations locally; no ADB or device involved."""
    def __init__(self):
        self.target = 'fixture-device'
        self.commands = []
        self.interrupt_index = None
        self.corrupt_once = False
        self.reconnects = 0
        self.force_fallback = False
        self.interrupt_after_publish = False
        self.interrupt_before_owner_cleanup = False
        self.proc = None

    def run(self, command, data=None):
        self.commands.append(command)
        args = shlex.split(command)
        operation = args[3]
        if self.proc is not None:
            args[2] = args[2].replace("proc = '/proc'", 'proc = ' + repr(str(self.proc)))
        if operation == 'publish' and self.interrupt_before_owner_cleanup:
            self.interrupt_before_owner_cleanup = False
            args[2] = args[2].replace("    os.close(f)\n    owner = safe_open", "    os.close(f)\n    raise RuntimeError('simulated crash before owner cleanup')\n    owner = safe_open")
        if operation == 'publish' and self.force_fallback:
            args[2] = args[2].replace('result = rename(fd, os.fsencode(name), fd, os.fsencode(final), no_replace)', 'ctypes.set_errno(errno.EINVAL); result = -1')
        if self.interrupt_index is not None and operation == 'write' and int(args[6]) == self.interrupt_index * upload.CHUNK_SIZE:
            self.interrupt_index = None
            partial = Path(args[4]) / args[5]
            with partial.open('r+b') as out:
                out.seek(int(args[6]))
                out.write(data[:5])
            raise RuntimeError('simulated disconnection')
        if self.corrupt_once and operation == 'write':
            self.corrupt_once = False
            data = b'x' * len(data)
        result = subprocess.run(args, input=data, capture_output=True)
        if result.returncode:
            raise RuntimeError(result.stderr.decode())
        if operation == 'publish' and self.interrupt_after_publish:
            self.interrupt_after_publish = False
            raise RuntimeError('simulated post-publish disconnect')
        return result.stdout.decode().strip()

    def reconnect(self, attempt):
        self.reconnects += 1


class UploadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.overlay = self.root / 'overlay.pck'
        self.content = bytes(range(42))
        self.overlay.write_bytes(self.content)
        self.sha = hashlib.sha256(self.content).hexdigest()
        self.report = self.root / 'report.json'
        self.report.write_text(json.dumps({'output_sha256': self.sha}))
        self.remote_dir, self.old_size = str(self.root / 'remote'), upload.CHUNK_SIZE
        self.state_dir = self.root / 'state'
        self.state_dir.mkdir()
        upload.CHUNK_SIZE = 16
        self.addCleanup(self.restore)
        self.transport = LocalTransport()
        self.transport.proc = self.root / 'proc'
        self.transport.proc.mkdir()

    def restore(self):
        upload.CHUNK_SIZE = self.old_size

    def go(self):
        return Path(upload.upload(self.transport, self.overlay, self.report, self.remote_dir, self.state_dir))

    def test_interrupt_resume_revalidates_prefix(self):
        self.transport.interrupt_index = 1
        with self.assertRaisesRegex(RuntimeError, 'disconnection'):
            self.go()
        partial = Path(self.remote_dir) / (self.sha + '.partial')
        self.assertTrue(partial.exists())
        self.assertEqual(partial.read_bytes(), self.content[:21])
        final = self.go()
        self.assertEqual(final.read_bytes(), self.content)
        self.assertEqual(self.overlay.read_bytes(), self.content)
        self.assertFalse(partial.exists())

    def test_bad_report_never_contacts_transport(self):
        self.report.write_text(json.dumps({'output_sha256': '0' * 64}))
        with self.assertRaises(ValueError):
            self.go()
        self.assertEqual(self.transport.commands, [])

    def test_reupload_after_published_final_removed(self):
        final = self.go()
        final.unlink()
        self.assertEqual(self.go().read_bytes(), self.content)

    def test_resume_after_publish_response_lost(self):
        self.transport.interrupt_after_publish = True
        with self.assertRaisesRegex(RuntimeError, 'post-publish disconnect'):
            self.go()
        final = Path(self.remote_dir) / (self.sha + '.pck')
        self.assertEqual(self.go(), final)
        final.unlink()
        self.assertEqual(self.go().read_bytes(), self.content)

    def test_resume_after_publish_before_owner_cleanup(self):
        self.transport.interrupt_before_owner_cleanup = True
        with self.assertRaisesRegex(RuntimeError, 'simulated crash'):
            self.go()
        marker = Path(self.remote_dir) / (self.sha + '.partial.owner')
        self.assertTrue(marker.exists())
        final = self.go()
        self.assertFalse(marker.exists())
        final.unlink()
        self.assertEqual(self.go().read_bytes(), self.content)

    def test_publish_recovery_rejects_foreign_same_hash_inode(self):
        self.transport.interrupt_after_publish = True
        with self.assertRaisesRegex(RuntimeError, 'post-publish disconnect'):
            self.go()
        final = Path(self.remote_dir) / (self.sha + '.pck')
        final.rename(final.with_suffix('.old'))
        final.write_bytes(self.content)
        with self.assertRaisesRegex(RuntimeError, 'published file does not match owner'):
            self.go()
        self.assertEqual(final.read_bytes(), self.content)

    def test_complete_state_does_not_claim_foreign_partial(self):
        final = self.go()
        final.unlink()
        partial = Path(self.remote_dir) / (self.sha + '.partial')
        partial.write_bytes(self.content[:16])
        with self.assertRaises(RuntimeError):
            self.go()
        self.assertEqual(partial.read_bytes(), self.content[:16])

    def test_existing_final_is_immutable(self):
        final = self.go()
        self.assertEqual(final.read_bytes(), self.content)
        count = len(self.transport.commands)
        self.assertEqual(self.go(), final)
        self.assertFalse(any(shlex.split(c)[3] == 'write' for c in self.transport.commands[count:]))
        final.write_bytes(b'foreign content')
        with self.assertRaisesRegex(RuntimeError, 'refusing to overwrite'):
            self.go()
        self.assertEqual(final.read_bytes(), b'foreign content')

    def test_existing_mismatched_prefix_is_never_modified(self):
        remote = Path(self.remote_dir); remote.mkdir()
        partial = remote / (self.sha + '.partial')
        for index, data in enumerate((b'', self.content[:16], b'foreign', self.content[:16] + b'bad', self.content + b'extra')):
            self.state_dir = self.root / f'state-{index}'
            self.state_dir.mkdir()
            partial.write_bytes(data)
            with self.subTest(data=data), self.assertRaises(RuntimeError):
                self.go()
            self.assertEqual(partial.read_bytes(), data)

    def test_missing_local_owner_state_refuses_matching_partial(self):
        self.transport.interrupt_index = 1
        with self.assertRaisesRegex(RuntimeError, 'disconnection'):
            self.go()
        partial = Path(self.remote_dir) / (self.sha + '.partial')
        content = partial.read_bytes()
        self.state_dir = self.root / 'other-state'
        self.state_dir.mkdir()
        with self.assertRaises(RuntimeError):
            self.go()
        self.assertEqual(partial.read_bytes(), content)

    def test_refuses_replaced_owned_partial_or_token(self):
        self.transport.interrupt_index = 1
        with self.assertRaisesRegex(RuntimeError, 'disconnection'):
            self.go()
        partial = Path(self.remote_dir) / (self.sha + '.partial')
        old = partial.read_bytes()
        partial.rename(partial.with_suffix('.other'))
        partial.write_bytes(old)
        with self.assertRaisesRegex(RuntimeError, 'inode'):
            self.go()
        self.assertEqual(partial.read_bytes(), old)
        partial.unlink()
        partial.with_suffix('.other').rename(partial)
        marker = Path(str(partial) + '.owner')
        marker.write_text('foreign token')
        with self.assertRaisesRegex(RuntimeError, 'token'):
            self.go()
        self.assertEqual(partial.read_bytes(), old)

    def test_corrupted_transfer_is_not_repaired(self):
        self.transport.corrupt_once = True
        with self.assertRaisesRegex(RuntimeError, 'failed verification'):
            self.go()
        partial = Path(self.remote_dir) / (self.sha + '.partial')
        original = partial.read_bytes()
        with self.assertRaisesRegex(RuntimeError, 'prefix'):
            self.go()
        self.assertEqual(partial.read_bytes(), original)

    def test_partial_open_or_mapped_by_process_is_never_modified(self):
        remote = Path(self.remote_dir); remote.mkdir()
        partial = remote / (self.sha + '.partial')
        self.transport.interrupt_index = 1
        with self.assertRaisesRegex(RuntimeError, 'disconnection'):
            self.go()
        saved = partial.read_bytes()
        process = self.transport.proc / '123'; (process / 'fd').mkdir(parents=True)
        (process / 'maps').write_text('')
        handle = process / 'fd' / '5'; handle.symlink_to(partial)
        with self.assertRaisesRegex(RuntimeError, 'open by PID'):
            self.go()
        self.assertEqual(partial.read_bytes(), saved)
        handle.unlink()
        st = partial.stat()
        (process / 'maps').write_text(f'0-1 r--p 0 {os.major(st.st_dev):x}:{os.minor(st.st_dev):x} {st.st_ino} /alias\n')
        with self.assertRaisesRegex(RuntimeError, 'mapped by PID'):
            self.go()
        self.assertEqual(partial.read_bytes(), saved)

    def test_hostile_partial_symlink_and_hardlink_are_rejected(self):
        remote = Path(self.remote_dir)
        remote.mkdir()
        partial = remote / (self.sha + '.partial')
        victim = self.root / 'victim'
        victim.write_bytes(b'untouched')
        for link in ('symlink', 'hardlink'):
            with self.subTest(link=link):
                self.state_dir = self.root / ('state-' + link)
                self.state_dir.mkdir()
                if link == 'symlink':
                    partial.symlink_to(victim)
                else:
                    os.link(victim, partial)
                with self.assertRaises(RuntimeError):
                    self.go()
                self.assertEqual(victim.read_bytes(), b'untouched')
                partial.unlink()

    def test_hostile_final_and_directory_symlinks_are_rejected(self):
        remote = Path(self.remote_dir)
        remote.mkdir()
        victim = self.root / 'victim'
        victim.write_bytes(b'untouched')
        (remote / (self.sha + '.pck')).symlink_to(victim)
        with self.assertRaises(RuntimeError):
            self.go()
        self.assertEqual(victim.read_bytes(), b'untouched')
        remote.rename(self.root / 'previous')
        remote.symlink_to(self.root / 'previous', target_is_directory=True)
        with self.assertRaises(RuntimeError):
            self.go()
        self.assertEqual(victim.read_bytes(), b'untouched')

    def test_unsupported_noreplace_uses_and_recovers_reservation(self):
        self.transport.force_fallback = True
        remote = Path(self.remote_dir)
        remote.mkdir()
        final = remote / (self.sha + '.pck')
        final.write_bytes(('STS2_TEXTURE_UPLOAD_PENDING_V1:' + self.sha).encode())
        self.assertEqual(self.go().read_bytes(), self.content)

    def test_unsupported_noreplace_creates_reservation(self):
        self.transport.force_fallback = True
        self.assertEqual(self.go().read_bytes(), self.content)

    def test_incomplete_reservation_is_never_overwritten(self):
        remote = Path(self.remote_dir)
        remote.mkdir()
        final = remote / (self.sha + '.pck')
        final.write_bytes(b'')
        with self.assertRaisesRegex(RuntimeError, 'refusing to overwrite'):
            self.go()
        self.assertEqual(final.read_bytes(), b'')

    def test_adb_uses_non_pty_binary_transport(self):
        from unittest.mock import patch
        class Result:
            stdout = b'ok'
        with patch.object(upload.subprocess, 'run', return_value=Result()) as run:
            self.assertEqual(upload.Adb('serial').run('command', b'\x00\r\n\xff'), 'ok')
            self.assertEqual(run.call_args.args[0], ['adb', '-s', 'serial', 'shell', '-T', 'command'])
            self.assertEqual(run.call_args.kwargs['input'], b'\x00\r\n\xff')



DOWNLOAD_SCRIPT = Path(__file__).resolve().parents[1] / 'ports/sts2/src/tools/device_tools/download_resumable.py'
spec = importlib.util.spec_from_file_location('texture_download', DOWNLOAD_SCRIPT)
download = importlib.util.module_from_spec(spec)
spec.loader.exec_module(download)


class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.destination = self.root / 'copy.pck'
        self.report = self.root / 'report.json'
        self.content = bytes(range(42))
        old_size = download.CHUNK_SIZE
        download.CHUNK_SIZE = 16
        self.addCleanup(setattr, download, 'CHUNK_SIZE', old_size)
        class Transport:
            target = 'fixture'
            calls = []
            fail = False
            stat = [42, 1, 2, 3]
            def chunk(inner, source, offset, length):
                inner.calls.append(offset)
                if inner.fail and offset == 16:
                    raise ValueError('disconnected')
                data = self.content[offset:offset + length]
                return {'stat': inner.stat, 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}, data
        self.transport = Transport()

    def go(self):
        return download.download(self.transport, '/source.pck', len(self.content), self.destination, self.report)

    def test_interrupt_resume(self):
        from unittest.mock import patch
        self.transport.fail = True
        with patch.object(download.time, 'sleep'), self.assertRaisesRegex(RuntimeError, 'paused'):
            self.go()
        self.transport.fail = False
        self.transport.calls.clear()
        self.assertEqual(self.go(), hashlib.sha256(self.content).hexdigest())
        self.assertEqual(self.transport.calls, [16, 32])
        self.assertEqual(self.destination.read_bytes(), self.content)
        self.assertEqual(json.loads(self.report.read_text())['size'], len(self.content))

    def test_rejects_corrupt_partial_and_changed_source(self):
        from unittest.mock import patch
        self.transport.fail = True
        with patch.object(download.time, 'sleep'), self.assertRaises(RuntimeError):
            self.go()
        partial = self.destination.with_name(self.destination.name + '.partial')
        partial.write_bytes(b'x' * 16)
        with self.assertRaisesRegex(ValueError, 'saved chunk mismatch'):
            self.go()
        partial.write_bytes(self.content[:16])
        self.transport.fail = False
        self.transport.stat = [42, 9, 2, 3]
        with self.assertRaisesRegex(ValueError, 'source metadata changed'):
            self.go()
        self.assertFalse(self.destination.exists())

    def test_rejects_incompatible_state_and_invalid_chunk(self):
        from unittest.mock import patch
        self.transport.fail = True
        with patch.object(download.time, 'sleep'), self.assertRaises(RuntimeError):
            self.go()
        self.transport.target = 'different-device'
        with self.assertRaisesRegex(ValueError, 'incompatible state'):
            self.go()
        self.transport.target = 'fixture'
        self.transport.fail = False
        self.transport.chunk = lambda source, offset, length: ({'stat': [42, 1, 2, 3], 'size': length, 'sha256': '0' * 64}, b'x' * length)
        with self.assertRaisesRegex(ValueError, 'chunk length/hash mismatch'):
            self.go()
        self.assertFalse(self.destination.exists())

    def test_rejects_hardlinked_partial(self):
        from unittest.mock import patch
        self.transport.fail = True
        with patch.object(download.time, 'sleep'), self.assertRaises(RuntimeError):
            self.go()
        partial = self.destination.with_name(self.destination.name + '.partial')
        victim = self.root / 'victim'
        victim.write_bytes(b'preserve')
        partial.unlink()
        os.link(victim, partial)
        with self.assertRaisesRegex(ValueError, 'unsafe partial'):
            self.go()
        self.assertEqual(victim.read_bytes(), b'preserve')

    def test_refuses_existing_destination(self):
        self.destination.write_bytes(b'keep')
        with self.assertRaisesRegex(ValueError, 'refusing to overwrite'):
            self.go()
        self.assertEqual(self.transport.calls, [])
        self.assertEqual(self.destination.read_bytes(), b'keep')


if __name__ == '__main__':
    unittest.main()
