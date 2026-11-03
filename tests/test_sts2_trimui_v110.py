# INPUT:  STS2 TrimUI SDL launcher template
# OUTPUT: Independent launcher and default-off diagnostics assertions
# POS:    Host-only template contract without migration tools or device access
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]

class TrimuiV110Test(unittest.TestCase):
    def test_launcher_is_explicitly_independent_and_diagnostics_default_off(self):
        s=(ROOT/'ports/sts2/love/trimui-v110.sh.template').read_text()
        for text in ('/mnt/SDCARD/Data/ports/sts2-v110','--display-driver sdl2','--rendering-driver opengl3',
                     'SLL_TEXTURE_DIAG=0','SLL_UI_DIAG=0','SLL_UI_CONTROL=0','SLL_INPUT_DIAG=0'):
            self.assertIn(text,s)
        self.assertNotIn('--verbose',s)
        self.assertNotIn('settings.save',s)
        self.assertEqual(s.count('SLL_LOONG_FOCUS_COMPAT=1'),1)
        self.assertNotIn('SLL_LOONG_FOCUS_COMPAT=0',s)

if __name__ == "__main__":
    unittest.main()
