# INPUT: optimized resumable uploader and simulated remote filesystem
# OUTPUT: chunk integrity, interruption recovery and linear-read checks
# POS: local transport only; no device or player game is contacted
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from tests import test_sts2_texture_upload as fixture

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('build_upload',ROOT/'ports/sts2/src/tools/device_tools/upload_build.py')
upload=importlib.util.module_from_spec(spec);spec.loader.exec_module(upload)


class LostWriteTransport(fixture.LocalTransport):
    def __init__(self):super().__init__();self.lose_once=True
    def run(self,command,data=None):
        result=super().run(command,data)
        if data and self.lose_once:
            self.lose_once=False
            raise RuntimeError('simulated lost write response')
        return result


class BuildUploadTest(unittest.TestCase):
    def test_lost_response_recovers_and_corruption_fails(self):
        old_module=fixture.upload;old_chunk=upload.CHUNK_SIZE;fixture.upload=upload;upload.CHUNK_SIZE=16
        self.addCleanup(setattr,fixture,'upload',old_module);self.addCleanup(setattr,upload,'CHUNK_SIZE',old_chunk)
        with tempfile.TemporaryDirectory() as d:
            root=Path(d).resolve();source=root/'source';source.write_bytes(bytes(range(45)))
            report=root/'report';report.write_text(json.dumps({'output_sha256':hashlib.sha256(source.read_bytes()).hexdigest()}))
            state=root/'state';state.mkdir();proc=root/'proc';proc.mkdir()
            transport=LostWriteTransport();transport.proc=proc
            out=Path(upload.upload(transport,source,report,str(root/'remote'),state))
            self.assertEqual(out.read_bytes(),source.read_bytes())
            self.assertNotIn('file_hash(f) != prefix_hash',upload.REMOTE)
            self.assertIn('file_hash(f, offset, length) != chunk_hash',upload.REMOTE)
            other=fixture.LocalTransport();other.proc=proc;other.corrupt_once=True
            with self.assertRaises(RuntimeError):upload.upload(other,source,report,str(root/'other'),state)


if __name__=='__main__':unittest.main()
