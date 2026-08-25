import json
import sys
import tempfile
import unittest
from pathlib import Path


LAB_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LAB_DIR))

import pam_lab


class PamLabTests(unittest.TestCase):
    def test_checked_in_device_bindings_match(self):
        snapshot = pam_lab.config_snapshot(pam_lab.REPO_ROOT)
        self.assertTrue(snapshot["bindings_match"])
        self.assertEqual(
            [profile["id"] for profile in snapshot["profiles"]],
            list(pam_lab.PROFILE_IDS),
        )

    def test_command_check_records_success_and_failure_logs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            passed = pam_lab.run_check(
                "passed",
                "Passed",
                [sys.executable, "-c", "print('aarch64')"],
                root,
                root,
                stdout_contains="aarch64",
            )
            failed = pam_lab.run_check(
                "failed",
                "Failed",
                [sys.executable, "-c", "raise SystemExit(7)"],
                root,
                root,
            )
            self.assertEqual(passed["status"], "pass")
            self.assertEqual(failed["status"], "fail")
            self.assertIn("aarch64", (root / "passed.log").read_text())

    def test_summary_names_missing_userspace_without_failing_checks(self):
        report = {
            "checks": [
                {
                    "id": "ok",
                    "title": "OK",
                    "status": "pass",
                    "duration_ms": 1,
                    "log": "logs/ok.log",
                }
            ],
            "config": {
                "profiles": [
                    {"id": profile_id, "binding_matches": True}
                    for profile_id in pam_lab.PROFILE_IDS
                ]
            },
            "userspace": {
                "profiles": [
                    {"id": profile_id, "collected": False}
                    for profile_id in pam_lab.PROFILE_IDS
                ]
            },
        }
        summary = pam_lab.render_summary(report)
        self.assertIn("Result: **PASS**", summary)
        self.assertIn("miniloong-loongos", summary)
        self.assertIn("Exact userspace has not been collected", summary)

    def test_report_is_json_serializable(self):
        snapshot = {
            "host": pam_lab.host_snapshot(pam_lab.REPO_ROOT),
            "config": pam_lab.config_snapshot(pam_lab.REPO_ROOT),
            "artifact": pam_lab.artifact_snapshot(pam_lab.REPO_ROOT),
        }
        json.dumps(snapshot)


if __name__ == "__main__":
    unittest.main()
