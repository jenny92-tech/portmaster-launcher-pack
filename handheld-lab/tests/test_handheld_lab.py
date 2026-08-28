from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


COMPONENT_ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = COMPONENT_ROOT / "handheld_lab.py"
SPEC = importlib.util.spec_from_file_location("handheld_lab", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
handheld_lab = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = handheld_lab
SPEC.loader.exec_module(handheld_lab)


class RecordingTransport(handheld_lab.Transport):
    def __init__(self, name: str, capabilities: str):
        super().__init__(name)
        self.name = name
        self.capabilities = capabilities.encode()
        self.calls: list[tuple[str, ...]] = []
        self.pulls: list[str] = []

    def describe(self) -> dict[str, str]:
        return {"transport": "recording", "endpoint": self.name}

    def agent(self, arguments, timeout=handheld_lab.DEFAULT_TIMEOUT):
        del timeout
        self.calls.append(tuple(arguments))
        if arguments[0] == "capabilities":
            stdout = self.capabilities
        elif arguments[0] == "core":
            stdout = b"/tmp/generated.core\n"
        else:
            stdout = b""
        return handheld_lab.Result(list(arguments), 0, stdout, b"", 1)

    def push(self, source: Path, destination: str):
        return handheld_lab.Result(["push", str(source), destination], 0, b"", b"", 1)

    def pull(self, source: str, destination: Path):
        self.pulls.append(source)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(b"\x89PNG\r\n\x1a\n")
        return handheld_lab.Result(["pull", source, str(destination)], 0, b"", b"", 1)


class ControllerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.transport = handheld_lab.LocalTransport()

    def test_capabilities_are_machine_readable(self) -> None:
        result = self.transport.agent(["capabilities"])
        self.assertEqual(result.returncode, 0, result.text_stderr())
        capabilities = handheld_lab.parse_capabilities(result.text_stdout())
        names = {item["name"] for item in capabilities}
        self.assertIn("exec", names)
        self.assertIn("input", names)
        self.assertIn("capture", names)
        self.assertTrue(handheld_lab.capability_available(capabilities, "exec"))

    def test_exec_preserves_argument_boundaries(self) -> None:
        result = self.transport.execute(["printf", "%s|%s", "a b", "$(not-a-shell)"])
        self.assertEqual(result.returncode, 0, result.text_stderr())
        self.assertEqual(result.stdout, b"a b|$(not-a-shell)")

    def test_process_observation_is_bounded_and_omits_environment(self) -> None:
        if not Path("/proc/self/status").is_file():
            self.skipTest("procfs process observation is a Linux capability")
        result = self.transport.agent(["process", str(os.getpid())])
        self.assertEqual(result.returncode, 0, result.text_stderr())
        output = result.text_stdout()
        self.assertIn("===== memory-map =====", output)
        self.assertIn("===== threads =====", output)
        self.assertNotIn("/environ", output)

    def test_invalid_pid_fails_closed(self) -> None:
        result = self.transport.agent(["process", "not-a-pid"])
        self.assertEqual(result.returncode, 64)
        self.assertIn("invalid PID", result.text_stderr())

    def test_configured_capture_provider_is_pulled_to_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            helper = root / "capture-helper"
            helper.write_text(
                "#!/bin/sh\nprintf 'P6\\n1 1\\n255\\n\\000\\000\\000' >\"$1\"\n",
                encoding="utf-8",
            )
            helper.chmod(0o755)
            output = root / "screen.png"
            with mock.patch.dict(os.environ, {"HANDHELD_DEVTOOLS_CAPTURE_HELPER": str(helper)}):
                result = handheld_lab.capture_to(self.transport, output)
            self.assertEqual(result.returncode, 0, result.text_stderr())
            self.assertTrue(output.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"))

    def test_scenario_records_success_and_stops_on_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scenario = root / "scenario.json"
            scenario.write_text(
                json.dumps(
                    {
                        "name": "unit",
                        "steps": [
                            {
                                "action": "exec",
                                "argv": ["printf", "%s", "ok"],
                                "stdout_contains": "ok",
                            },
                            {"action": "exec", "argv": ["false"]},
                            {"action": "wait", "seconds": 0},
                        ],
                    }
                ),
                encoding="utf-8",
            )
            manifest, directory = handheld_lab.run_scenario(
                self.transport, scenario, root / "artifacts"
            )
            self.assertEqual(manifest["status"], "fail")
            self.assertEqual(len(manifest["steps"]), 2)
            self.assertTrue((directory / "manifest.json").is_file())

    def test_diagnose_creates_evidence_without_core_dump(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with mock.patch.dict(
                os.environ,
                {"PATH": "/usr/bin:/bin", "DISPLAY": "", "WAYLAND_DISPLAY": ""},
            ):
                manifest, directory = handheld_lab.diagnose(
                    self.transport, root / "evidence", os.getpid()
                )
            self.assertIn(manifest["status"], {"pass", "partial"})
            self.assertTrue((directory / "manifest.json").is_file())
            self.assertFalse(any(path.suffix == ".core" for path in directory.iterdir()))

    def test_diagnose_does_not_collect_system_logs_unless_requested(self) -> None:
        transport = RecordingTransport("target", "exec\tyes\tsh\tok\n")
        with tempfile.TemporaryDirectory() as temporary:
            handheld_lab.diagnose(transport, Path(temporary), None)
        self.assertNotIn(("logs",), transport.calls)

    def test_scenario_pull_cannot_escape_artifact_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scenario = root / "scenario.json"
            scenario.write_text(
                json.dumps(
                    {
                        "steps": [
                            {
                                "action": "pull",
                                "source": "/tmp/result",
                                "destination": "../outside",
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "stay inside artifacts"):
                handheld_lab.run_scenario(
                    self.transport, scenario, root / "artifacts"
                )

    def test_scenario_timeout_is_bounded(self) -> None:
        with self.assertRaisesRegex(ValueError, "between 1 and 3600"):
            handheld_lab.scenario_timeout(0, 1)
        with self.assertRaisesRegex(ValueError, "between 1 and 3600"):
            handheld_lab.scenario_timeout(True, 1)

    def test_scenario_validates_every_step_before_execution(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            marker = root / "must-not-exist"
            scenario = root / "scenario.json"
            scenario.write_text(
                json.dumps(
                    {
                        "steps": [
                            {
                                "action": "exec",
                                "argv": ["touch", str(marker)],
                            },
                            {"action": "unsupported"},
                        ]
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "unsupported action"):
                handheld_lab.run_scenario(
                    self.transport, scenario, root / "artifacts"
                )
            self.assertFalse(marker.exists())

    def test_ssh_transport_disables_local_authentication_stores(self) -> None:
        transport = handheld_lab.SshTransport("example.test:2222", "root")
        command = transport.ssh_base()
        try:
            self.assertIn("/dev/null", command)
            self.assertIn("IdentityFile=/dev/null", command)
            self.assertIn("UserKnownHostsFile=/dev/null", command)
            self.assertIn("PubkeyAuthentication=no", command)
            self.assertNotIn("StrictHostKeyChecking=accept-new", command)
            self.assertIn("ControlMaster=auto", command)
            self.assertIn("ControlPersist=30", command)
            self.assertTrue(
                any(value.startswith("ControlPath=") for value in command)
            )
        finally:
            transport.close()

    def test_adb_agent_uses_noninteractive_shell_command(self) -> None:
        transport = handheld_lab.AdbTransport("device:5555")
        completed = handheld_lab.Result([], 0, b"ok\n", b"", 1)
        with mock.patch.object(handheld_lab, "run_process", return_value=completed) as run:
            result = transport.agent(["snapshot"])
        self.assertEqual(result.returncode, 0)
        command = run.call_args.args[0]
        self.assertEqual(command[:4], ["adb", "-s", "device:5555", "shell"])
        self.assertEqual(command[4], "sh -s -- snapshot")
        self.assertNotIn("exec-out", command)
        self.assertEqual(run.call_args.kwargs["stdin"], handheld_lab.AGENT_PATH.read_bytes())

    def test_composite_target_routes_capabilities_and_artifacts(self) -> None:
        common = (
            "exec\tyes\tsh\tok\n"
            "input\tno\tnone\tmissing\n"
            "capture\tno\tnone\tmissing\n"
            "core-dump\tno\tnone\tmissing\n"
            "syscall-trace\tno\tnone\tmissing\n"
            "toolchain\tno\tnone\tmissing\n"
        )
        primary = RecordingTransport("runtime", common)
        io = RecordingTransport(
            "io",
            common.replace("input\tno\tnone\tmissing", "input\tyes\tuinput\tok").replace(
                "capture\tno\tnone\tmissing", "capture\tyes\tfb\tok"
            ),
        )
        debug = RecordingTransport(
            "debug",
            common.replace("core-dump\tno\tnone\tmissing", "core-dump\tyes\tgdb\tok")
            .replace("syscall-trace\tno\tnone\tmissing", "syscall-trace\tyes\tstrace\tok")
            .replace("toolchain\tno\tnone\tmissing", "toolchain\tyes\tcc\tok"),
        )
        routed = handheld_lab.RoutedTransport(primary, io=io, debug=debug)
        capabilities = handheld_lab.parse_capabilities(
            routed.agent(["capabilities"]).text_stdout()
        )
        self.assertTrue(handheld_lab.capability_available(capabilities, "input"))
        self.assertTrue(handheld_lab.capability_available(capabilities, "core-dump"))

        routed.agent(["input", "south", "80"])
        self.assertIn(("input", "south", "80"), io.calls)
        self.assertNotIn(("input", "south", "80"), primary.calls)

        with tempfile.TemporaryDirectory() as temporary:
            screen = Path(temporary) / "screen.png"
            core = Path(temporary) / "process.core"
            self.assertEqual(handheld_lab.capture_to(routed, screen).returncode, 0)
            self.assertEqual(handheld_lab.core_to(routed, 42, core).returncode, 0)
        self.assertTrue(io.pulls)
        self.assertEqual(debug.pulls, ["/tmp/generated.core"])
        self.assertTrue(any(call[0] == "cleanup-temp" for call in io.calls))
        self.assertIn(("cleanup-temp", "/tmp/generated.core"), debug.calls)


class CliTests(unittest.TestCase):
    def test_help_uses_the_stable_devtools_name(self) -> None:
        result = subprocess.run(
            [str(COMPONENT_ROOT / "devtools"), "--help"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith("usage: devtools "), result.stdout)

    def test_local_probe_cli(self) -> None:
        result = subprocess.run(
            ["python3", str(MODULE_PATH), "--transport", "local", "probe"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["target"]["transport"], "local")


if __name__ == "__main__":
    unittest.main()
