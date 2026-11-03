# INPUT:  stage-payload.py、临时 PCK 与共享图形归档
# OUTPUT: 负载闭集、WSI 配置和非法 PCK 拒绝的回归断言
# POS:    在主机验证余烬灯塔打包边界，不加载原生库或游戏
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

PORT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('emberward_stage', PORT / 'src/scripts/stage-payload.py')
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)


class PackageTests(unittest.TestCase):
    def test_explicit_pck_does_not_collect_adjacent_user_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            pck = root / 'export.pck'
            pck.write_bytes(b'GDPC' + bytes(64))
            (root / 'save.json').write_text('private player state')
            data = root / 'payload'
            stage.stage(data, pck)
            self.assertEqual((data / 'emberward.pck').read_bytes(), pck.read_bytes())
            self.assertFalse((data / 'save.json').exists())
            self.assertFalse((data / 'conf').exists())
            files = {p.relative_to(data).as_posix() for p in data.rglob('*') if p.is_file()}
            self.assertEqual(files, {'emberward.pck', 'emberward.gptk',
                'compat/loong-egl-compat.so', 'compat/loong-egl-compat.json',
                'compat/NOTICE.txt', 'compat/xwayland-shm.sh',
                'compat/vulkan-wsi/libVkLayer_window_system_integration.so',
                'compat/vulkan-wsi/LICENSE', 'compat/vulkan-wsi/source.json',
                'compat/vulkan-wsi/layer-template.json'})
            layer = json.loads((data / 'compat/vulkan-wsi/layer-template.json').read_text())['layer']
            self.assertEqual(layer['enable_environment'], {'EMBERWARD_VULKAN_WSI': '1'})
            self.assertEqual(layer['library_path'], '@EMBERWARD_WSI_LIBRARY@')

    def test_launcher_only_and_reject_invalid_or_linked_exports(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            data = root / 'payload'
            stage.stage(data)
            self.assertFalse((data / 'emberward.pck').exists())
            bad = root / 'bad.pck'
            bad.write_bytes(b'not a game pack')
            with self.assertRaises(ValueError):
                stage.stage(data, bad)
            good = root / 'good.pck'
            good.write_bytes(b'GDPC')
            linked = root / 'linked.pck'
            linked.symlink_to(good)
            with self.assertRaises(ValueError):
                stage.stage(data, linked)


if __name__ == '__main__':
    unittest.main()
