# INPUT: exact shared-variation fixture and font-budget builder
# OUTPUT: fixed identity and byte-level change regression
# POS: offline unit tests; no game execution, private input or device
import hashlib
import importlib.util
import sys
import unittest
from pathlib import Path

TOOLS=Path(__file__).resolve().parents[1]/'ports/sts2/src/tools/godot_pck'
sys.path.insert(0,str(TOOLS))
spec=importlib.util.spec_from_file_location('font_budget_trial',TOOLS/'font_budget_trial.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
SOURCE=(b'[gd_resource type="FontVariation" load_steps=2 format=3 uid="uid://bxphqqry0qswt"]\n\n'
 b'[ext_resource type="FontFile" uid="uid://wcoiw83db02h" path="res://fonts/zhs/SourceHanSerifSC-Bold.otf" id="1_hbd7y"]\n\n'
 b'[resource]\nbase_font = ExtResource("1_hbd7y")\nvariation_transform = Transform2D(0.95, 0, 0, 0.95, 0, 0)\nbaseline_offset = -0.05\n')

class FontBudgetTrialTest(unittest.TestCase):
 def test_expected_fixed_variation_and_no_fallback(self):
  self.assertEqual(hashlib.sha256(SOURCE).hexdigest(),m.BOLD_SHA)
  out=m.patch_bold(SOURCE)
  self.assertEqual(out.count(m.NEW_REF),1)
  self.assertNotIn(m.OLD_REF,out)
  self.assertIn(b'uid="uid://bxphqqry0qswt"',out)
  self.assertIn(b'variation_embolden = 0.3\n',out)
  self.assertIn(b'variation_transform = Transform2D(0.95, 0, 0, 0.95, 0, 0)',out)
  self.assertIn(b'baseline_offset = -0.05',out)
  self.assertNotIn(b'fallback',out)
 def test_unexpected_input_is_rejected(self):
  for x in (SOURCE+b'\n',SOURCE.replace(m.OLD_REF,m.NEW_REF),SOURCE.replace(b'-0.05',b'0.0')):
   with self.assertRaises(ValueError):m.patch_bold(x)

if __name__=='__main__':unittest.main()
