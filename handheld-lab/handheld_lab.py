#!/usr/bin/env python3
"""APP-independent controller for real and virtual Linux handheld targets."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import uuid
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence


COMPONENT_ROOT = Path(__file__).resolve().parent
AGENT_PATH = COMPONENT_ROOT / "agent" / "handheld-agent.sh"
DEFAULT_TIMEOUT = 120


@dataclass
class Result:
    command: list[str]
    returncode: int
    stdout: bytes
    stderr: bytes
    duration_ms: int

    def text_stdout(self) -> str:
        return self.stdout.decode("utf-8", errors="replace")

    def text_stderr(self) -> str:
        return self.stderr.decode("utf-8", errors="replace")


def run_process(
    command: Sequence[str],
    *,
    stdin: bytes | None = None,
    timeout: int = DEFAULT_TIMEOUT,
) -> Result:
    started = time.monotonic()
    try:
        completed = subprocess.run(
            list(command),
            input=stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError as error:
        return Result(
            list(command),
            127,
            b"",
            f"command unavailable: {error}\n".encode(),
            round((time.monotonic() - started) * 1000),
        )
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout if isinstance(error.stdout, bytes) else b""
        stderr = error.stderr if isinstance(error.stderr, bytes) else b""
        return Result(
            list(command),
            124,
            stdout,
            stderr + f"timed out after {timeout}s\n".encode(),
            round((time.monotonic() - started) * 1000),
        )
    return Result(
        list(command),
        completed.returncode,
        completed.stdout,
        completed.stderr,
        round((time.monotonic() - started) * 1000),
    )


class Transport:
    def __init__(self, endpoint: str | None):
        self.endpoint = endpoint

    def describe(self) -> dict[str, str]:
        raise NotImplementedError

    def agent(self, arguments: Sequence[str], timeout: int = DEFAULT_TIMEOUT) -> Result:
        raise NotImplementedError

    def execute(self, arguments: Sequence[str], timeout: int = DEFAULT_TIMEOUT) -> Result:
        return self.agent(["exec", "--", *arguments], timeout=timeout)

    def push(self, source: Path, destination: str) -> Result:
        raise NotImplementedError

    def pull(self, source: str, destination: Path) -> Result:
        raise NotImplementedError

    def provider_for(self, capability: str) -> "Transport":
        return self

    def close(self) -> None:
        pass


class LocalTransport(Transport):
    def __init__(self) -> None:
        super().__init__(None)

    def describe(self) -> dict[str, str]:
        return {"transport": "local", "endpoint": "local"}

    def agent(self, arguments: Sequence[str], timeout: int = DEFAULT_TIMEOUT) -> Result:
        return run_process(
            ["sh", "-s", "--", *arguments],
            stdin=AGENT_PATH.read_bytes(),
            timeout=timeout,
        )

    def push(self, source: Path, destination: str) -> Result:
        started = time.monotonic()
        try:
            copy_path(source, Path(destination))
            return Result(
                ["copy", str(source), destination],
                0,
                b"",
                b"",
                round((time.monotonic() - started) * 1000),
            )
        except OSError as error:
            return Result(
                ["copy", str(source), destination],
                1,
                b"",
                f"{error}\n".encode(),
                round((time.monotonic() - started) * 1000),
            )

    def pull(self, source: str, destination: Path) -> Result:
        return self.push(Path(source), str(destination))


class DockerTransport(Transport):
    def describe(self) -> dict[str, str]:
        return {"transport": "docker", "endpoint": required_endpoint(self.endpoint)}

    def agent(self, arguments: Sequence[str], timeout: int = DEFAULT_TIMEOUT) -> Result:
        return run_process(
            [
                "docker",
                "exec",
                "-i",
                required_endpoint(self.endpoint),
                "sh",
                "-s",
                "--",
                *arguments,
            ],
            stdin=AGENT_PATH.read_bytes(),
            timeout=timeout,
        )

    def push(self, source: Path, destination: str) -> Result:
        return run_process(
            ["docker", "cp", str(source), f"{required_endpoint(self.endpoint)}:{destination}"],
            timeout=600,
        )

    def pull(self, source: str, destination: Path) -> Result:
        return run_process(
            ["docker", "cp", f"{required_endpoint(self.endpoint)}:{source}", str(destination)],
            timeout=600,
        )


def endpoint_host_port(endpoint: str, default_port: int) -> tuple[str, int]:
    host, separator, port_text = endpoint.rpartition(":")
    if not separator:
        return endpoint, default_port
    if not host or not port_text.isdigit():
        raise ValueError(f"invalid endpoint: {endpoint}")
    port = int(port_text)
    if not 1 <= port <= 65535:
        raise ValueError(f"invalid endpoint port: {port}")
    return host, port


class SshTransport(Transport):
    def __init__(self, endpoint: str, user: str):
        super().__init__(endpoint)
        self.user = user
        self.host, self.port = endpoint_host_port(endpoint, 22)
        self.control_directory = tempfile.TemporaryDirectory(
            prefix="hdt-", dir="/tmp"
        )
        self.control_path = str(Path(self.control_directory.name) / "control")

    def describe(self) -> dict[str, str]:
        return {
            "transport": "ssh",
            "endpoint": f"{self.host}:{self.port}",
            "user": self.user,
        }

    def ssh_options(self) -> list[str]:
        return [
            "-F",
            "/dev/null",
            "-o",
            "IdentityFile=/dev/null",
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "PubkeyAuthentication=no",
            "-o",
            "PreferredAuthentications=password,keyboard-interactive",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-o",
            "GlobalKnownHostsFile=/dev/null",
            "-o",
            "ConnectTimeout=8",
            "-o",
            "ControlMaster=auto",
            "-o",
            "ControlPersist=30",
            "-o",
            f"ControlPath={self.control_path}",
        ]

    def ssh_base(self) -> list[str]:
        return [
            "ssh",
            *self.ssh_options(),
            "-p",
            str(self.port),
            f"{self.user}@{self.host}",
        ]

    def agent(self, arguments: Sequence[str], timeout: int = DEFAULT_TIMEOUT) -> Result:
        remote = "sh -s -- " + " ".join(shlex.quote(word) for word in arguments)
        return run_process(
            [*self.ssh_base(), remote],
            stdin=AGENT_PATH.read_bytes(),
            timeout=timeout,
        )

    def push(self, source: Path, destination: str) -> Result:
        return run_process(
            [
                "scp",
                *self.ssh_options(),
                "-P",
                str(self.port),
                "-r",
                str(source),
                f"{self.user}@{self.host}:{destination}",
            ],
            timeout=600,
        )

    def pull(self, source: str, destination: Path) -> Result:
        return run_process(
            [
                "scp",
                *self.ssh_options(),
                "-P",
                str(self.port),
                "-r",
                f"{self.user}@{self.host}:{source}",
                str(destination),
            ],
            timeout=600,
        )

    def close(self) -> None:
        if Path(self.control_path).exists():
            run_process(
                [
                    "ssh",
                    *self.ssh_options(),
                    "-O",
                    "exit",
                    "-p",
                    str(self.port),
                    f"{self.user}@{self.host}",
                ],
                timeout=10,
            )
        self.control_directory.cleanup()


class AdbTransport(Transport):
    def describe(self) -> dict[str, str]:
        return {"transport": "adb", "endpoint": required_endpoint(self.endpoint)}

    def adb_base(self) -> list[str]:
        return ["adb", "-s", required_endpoint(self.endpoint)]

    def agent(self, arguments: Sequence[str], timeout: int = DEFAULT_TIMEOUT) -> Result:
        remote = "sh -s -- " + " ".join(shlex.quote(word) for word in arguments)
        return run_process(
            [*self.adb_base(), "exec-out", "sh", "-c", remote],
            stdin=AGENT_PATH.read_bytes(),
            timeout=timeout,
        )

    def push(self, source: Path, destination: str) -> Result:
        return run_process(
            [*self.adb_base(), "push", str(source), destination], timeout=600
        )

    def pull(self, source: str, destination: Path) -> Result:
        return run_process(
            [*self.adb_base(), "pull", source, str(destination)], timeout=600
        )


IO_CAPABILITIES = {
    "capture",
    "input",
    "input-info",
    "input-start",
    "input-stop",
    "input-watch",
    "render-info",
}
DEBUG_CAPABILITIES = {"core", "trace"}
IO_REPORTED_CAPABILITIES = {"capture", "input", "input-observe", "render-observe"}
DEBUG_REPORTED_CAPABILITIES = {"core-dump", "syscall-trace", "toolchain"}


class RoutedTransport(Transport):
    """One logical Target composed from runtime, I/O, and debug providers."""

    def __init__(
        self,
        primary: Transport,
        io: Transport | None = None,
        debug: Transport | None = None,
    ) -> None:
        super().__init__(primary.endpoint)
        self.primary = primary
        self.io = io
        self.debug = debug

    def describe(self) -> dict[str, str]:
        description = self.primary.describe()
        if self.io is not None:
            description["io_endpoint"] = self.io.describe()["endpoint"]
        if self.debug is not None:
            description["debug_endpoint"] = self.debug.describe()["endpoint"]
        return description

    def provider_for(self, capability: str) -> Transport:
        if capability in IO_CAPABILITIES and self.io is not None:
            return self.io
        if capability in DEBUG_CAPABILITIES and self.debug is not None:
            return self.debug
        return self.primary

    def agent(self, arguments: Sequence[str], timeout: int = DEFAULT_TIMEOUT) -> Result:
        command = arguments[0] if arguments else ""
        if command == "capabilities":
            return self.combined_capabilities(timeout)
        return self.provider_for(command).agent(arguments, timeout=timeout)

    def execute(self, arguments: Sequence[str], timeout: int = DEFAULT_TIMEOUT) -> Result:
        return self.primary.execute(arguments, timeout=timeout)

    def push(self, source: Path, destination: str) -> Result:
        return self.primary.push(source, destination)

    def pull(self, source: str, destination: Path) -> Result:
        return self.primary.pull(source, destination)

    def combined_capabilities(self, timeout: int) -> Result:
        started = time.monotonic()
        primary = self.primary.agent(["capabilities"], timeout=timeout)
        if primary.returncode != 0:
            return primary
        merged = capability_lines(primary.text_stdout())
        stderr = primary.stderr
        commands = [*primary.command]
        for provider, names in (
            (self.io, IO_REPORTED_CAPABILITIES),
            (self.debug, DEBUG_REPORTED_CAPABILITIES),
        ):
            if provider is None:
                continue
            result = provider.agent(["capabilities"], timeout=timeout)
            commands.extend(result.command)
            stderr += result.stderr
            if result.returncode != 0:
                return Result(
                    commands,
                    result.returncode,
                    b"",
                    stderr,
                    round((time.monotonic() - started) * 1000),
                )
            facts = capability_lines(result.text_stdout())
            for name in names:
                if name in facts:
                    merged[name] = facts[name]
        output = "".join("\t".join(fields) + "\n" for fields in merged.values()).encode()
        return Result(
            commands,
            0,
            output,
            stderr,
            round((time.monotonic() - started) * 1000),
        )

    def close(self) -> None:
        self.primary.close()
        if self.io is not None:
            self.io.close()
        if self.debug is not None:
            self.debug.close()


def capability_lines(output: str) -> dict[str, tuple[str, str, str, str]]:
    lines: dict[str, tuple[str, str, str, str]] = {}
    for line in output.splitlines():
        fields = line.split("\t", 3)
        if len(fields) == 4:
            lines[fields[0]] = (fields[0], fields[1], fields[2], fields[3])
    return lines


def required_endpoint(endpoint: str | None) -> str:
    if not endpoint:
        raise ValueError("this transport requires --endpoint")
    return endpoint


def copy_path(source: Path, destination: Path) -> None:
    if source.is_dir():
        if destination.exists():
            raise FileExistsError(f"destination already exists: {destination}")
        shutil.copytree(source, destination)
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)


def make_transport(args: argparse.Namespace) -> Transport:
    if args.transport == "local":
        return LocalTransport()
    endpoint = required_endpoint(args.endpoint)
    if args.transport == "docker":
        primary = DockerTransport(endpoint)
        io = DockerTransport(args.io_endpoint) if args.io_endpoint else None
        debug = DockerTransport(args.debug_endpoint) if args.debug_endpoint else None
        if io is not None or debug is not None:
            return RoutedTransport(primary, io=io, debug=debug)
        return primary
    if args.io_endpoint or args.debug_endpoint:
        raise ValueError("--io-endpoint and --debug-endpoint currently require Docker transport")
    if args.transport == "ssh":
        return SshTransport(endpoint, args.user)
    if args.transport == "adb":
        return AdbTransport(endpoint)
    raise ValueError(f"unsupported transport: {args.transport}")


def parse_capabilities(output: str) -> list[dict[str, str | bool]]:
    capabilities: list[dict[str, str | bool]] = []
    for line in output.splitlines():
        fields = line.split("\t", 3)
        if len(fields) != 4:
            continue
        name, available, provider, detail = fields
        capabilities.append(
            {
                "name": name,
                "available": available == "yes",
                "provider": provider,
                "detail": detail,
            }
        )
    return capabilities


def capability_available(capabilities: list[dict[str, Any]], name: str) -> bool:
    return any(item["name"] == name and item["available"] for item in capabilities)


def write_result(directory: Path, name: str, result: Result) -> dict[str, Any]:
    stdout_path = directory / f"{name}.stdout.txt"
    stderr_path = directory / f"{name}.stderr.txt"
    stdout_path.write_bytes(result.stdout)
    stderr_path.write_bytes(result.stderr)
    return {
        "name": name,
        "command": result.command,
        "exit_code": result.returncode,
        "duration_ms": result.duration_ms,
        "stdout": stdout_path.name,
        "stderr": stderr_path.name,
    }


def unique_directory(root: Path) -> Path:
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    directory = root / timestamp
    suffix = 1
    while directory.exists():
        directory = root / f"{timestamp}-{suffix}"
        suffix += 1
    directory.mkdir(parents=True)
    return directory


def capture_to(
    transport: Transport, destination: Path, *, timeout: int = DEFAULT_TIMEOUT
) -> Result:
    remote_path = f"/tmp/handheld-devtools-{uuid.uuid4().hex}.png"
    provider = transport.provider_for("capture")
    capture = provider.agent(["capture", remote_path], timeout=timeout)
    if capture.returncode != 0:
        return capture
    destination.parent.mkdir(parents=True, exist_ok=True)
    pulled = provider.pull(remote_path, destination)
    cleanup = provider.agent(["cleanup-temp", remote_path]) if pulled.returncode == 0 else None
    if pulled.returncode == 0 and cleanup is not None and cleanup.returncode == 0:
        normalize_capture(destination)
    final_code = pulled.returncode if pulled.returncode != 0 else (cleanup.returncode if cleanup else 0)
    return Result(
        ["capture", remote_path, str(destination)],
        final_code,
        capture.stdout + pulled.stdout + (cleanup.stdout if cleanup else b""),
        capture.stderr + pulled.stderr + (cleanup.stderr if cleanup else b""),
        capture.duration_ms + pulled.duration_ms + (cleanup.duration_ms if cleanup else 0),
    )


def png_chunk(kind: bytes, data: bytes) -> bytes:
    payload = kind + data
    return struct.pack(">I", len(data)) + payload + struct.pack(">I", zlib.crc32(payload) & 0xFFFFFFFF)


def normalize_capture(path: Path) -> None:
    """Convert the tiny target-side PPM format to PNG without host dependencies."""
    content = path.read_bytes()
    if not content.startswith(b"P6\n"):
        return
    try:
        _magic, dimensions, maximum, pixels = content.split(b"\n", 3)
        width_text, height_text = dimensions.split()
        width = int(width_text)
        height = int(height_text)
        if maximum != b"255" or width <= 0 or height <= 0 or len(pixels) != width * height * 3:
            raise ValueError
    except (ValueError, TypeError):
        raise ValueError(f"invalid PPM capture: {path}") from None
    scanlines = b"".join(
        b"\x00" + pixels[row * width * 3 : (row + 1) * width * 3]
        for row in range(height)
    )
    png = b"\x89PNG\r\n\x1a\n"
    png += png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += png_chunk(b"IDAT", zlib.compress(scanlines, 6))
    png += png_chunk(b"IEND", b"")
    path.write_bytes(png)


def generated_remote_path(suffix: str) -> str:
    return f"/tmp/handheld-devtools-{uuid.uuid4().hex}{suffix}"


def core_to(transport: Transport, pid: int, destination: Path) -> Result:
    remote_prefix = generated_remote_path(".core")
    provider = transport.provider_for("core")
    dumped = provider.agent(["core", str(pid), remote_prefix], timeout=600)
    if dumped.returncode != 0:
        return dumped
    lines = [line for line in dumped.text_stdout().splitlines() if line]
    if not lines:
        return Result(dumped.command, 70, dumped.stdout, dumped.stderr + b"core path missing\n", dumped.duration_ms)
    destination.parent.mkdir(parents=True, exist_ok=True)
    pulled = provider.pull(lines[-1], destination)
    cleanup = provider.agent(["cleanup-temp", lines[-1]]) if pulled.returncode == 0 else None
    final_code = pulled.returncode if pulled.returncode != 0 else (cleanup.returncode if cleanup else 0)
    return Result(
        ["core", str(pid), str(destination)],
        final_code,
        dumped.stdout + pulled.stdout + (cleanup.stdout if cleanup else b""),
        dumped.stderr + pulled.stderr + (cleanup.stderr if cleanup else b""),
        dumped.duration_ms + pulled.duration_ms + (cleanup.duration_ms if cleanup else 0),
    )


def trace_to(transport: Transport, pid: int, seconds: int, destination: Path) -> Result:
    remote_path = generated_remote_path(".strace")
    provider = transport.provider_for("trace")
    traced = provider.agent(["trace", str(pid), str(seconds), remote_path], timeout=seconds + 30)
    if traced.returncode != 0:
        return traced
    destination.parent.mkdir(parents=True, exist_ok=True)
    pulled = provider.pull(remote_path, destination)
    cleanup = provider.agent(["cleanup-temp", remote_path]) if pulled.returncode == 0 else None
    final_code = pulled.returncode if pulled.returncode != 0 else (cleanup.returncode if cleanup else 0)
    return Result(
        ["trace", str(pid), str(seconds), str(destination)],
        final_code,
        traced.stdout + pulled.stdout + (cleanup.stdout if cleanup else b""),
        traced.stderr + pulled.stderr + (cleanup.stderr if cleanup else b""),
        traced.duration_ms + pulled.duration_ms + (cleanup.duration_ms if cleanup else 0),
    )


def diagnose(
    transport: Transport,
    output_root: Path,
    pid: int | None,
    *,
    include_logs: bool = False,
) -> tuple[dict[str, Any], Path]:
    directory = unique_directory(output_root)
    results: list[dict[str, Any]] = []

    capabilities_result = transport.agent(["capabilities"])
    results.append(write_result(directory, "capabilities", capabilities_result))
    capabilities = parse_capabilities(capabilities_result.text_stdout())

    snapshot = transport.agent(["snapshot"])
    results.append(write_result(directory, "snapshot", snapshot))

    if include_logs:
        logs = transport.agent(["logs"])
        results.append(write_result(directory, "logs", logs))

    if capability_available(capabilities, "render-observe"):
        render = transport.agent(["render-info"])
        results.append(write_result(directory, "render-info", render))

    if pid is not None:
        process = transport.agent(["process", str(pid)])
        results.append(write_result(directory, f"process-{pid}", process))

    if capability_available(capabilities, "capture"):
        capture = capture_to(transport, directory / "screen.png")
        results.append(write_result(directory, "capture", capture))

    manifest = {
        "kind": "handheld-devtools-evidence",
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "target": transport.describe(),
        "pid": pid,
        "capabilities": capabilities,
        "results": results,
        "status": "pass" if all(item["exit_code"] == 0 for item in results) else "partial",
    }
    (directory / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    return manifest, directory


def safe_step_name(index: int, action: str, configured: Any) -> str:
    if isinstance(configured, str) and configured:
        cleaned = "".join(char if char.isalnum() or char in "-_" else "_" for char in configured)
        if cleaned:
            return f"{index:03d}-{cleaned}"
    return f"{index:03d}-{action}"


def require_string_list(value: Any, field: str) -> list[str]:
    if not isinstance(value, list) or not value or not all(isinstance(item, str) for item in value):
        raise ValueError(f"{field} must be a non-empty string array")
    return value


def scenario_timeout(value: Any, index: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= 3600:
        raise ValueError(f"scenario step {index}: timeout must be between 1 and 3600 seconds")
    return value


def scenario_artifact_path(directory: Path, configured: str, index: int) -> Path:
    relative = Path(configured)
    if relative.is_absolute() or not relative.parts or ".." in relative.parts:
        raise ValueError(f"scenario step {index}: destination must stay inside artifacts")
    root = directory.resolve()
    destination = (root / relative).resolve()
    if destination == root or root not in destination.parents:
        raise ValueError(f"scenario step {index}: destination must stay inside artifacts")
    return destination


def validate_scenario_step(step: Any, index: int) -> None:
    if not isinstance(step, dict) or not isinstance(step.get("action"), str):
        raise ValueError(f"scenario step {index} must contain an action")
    action = step["action"]
    if action == "wait":
        seconds = step.get("seconds", 1)
        if (
            isinstance(seconds, bool)
            or not isinstance(seconds, (int, float))
            or not 0 <= seconds <= 300
        ):
            raise ValueError(f"scenario step {index}: seconds must be between 0 and 300")
    elif action == "exec":
        require_string_list(step.get("argv"), f"step {index}.argv")
        scenario_timeout(step.get("timeout", DEFAULT_TIMEOUT), index)
    elif action == "input":
        button = step.get("button")
        hold_ms = step.get("hold_ms", 80)
        if not isinstance(button, str) or not button:
            raise ValueError(f"scenario step {index}: button is required")
        if (
            isinstance(hold_ms, bool)
            or not isinstance(hold_ms, int)
            or not 0 <= hold_ms <= 10000
        ):
            raise ValueError(f"scenario step {index}: invalid hold_ms")
    elif action == "input-start":
        if step.get("mode", "gamepad") not in {"gamepad", "keyboard"}:
            raise ValueError(f"scenario step {index}: invalid input mode")
    elif action in {
        "input-stop",
        "capture",
        "observe",
        "render-info",
        "input-info",
    }:
        pass
    elif action in {"process", "core"}:
        if isinstance(step.get("pid"), bool) or not isinstance(step.get("pid"), int) or step["pid"] <= 0:
            raise ValueError(f"scenario step {index}: positive pid is required")
    elif action == "start":
        require_string_list(step.get("argv"), f"step {index}.argv")
        remote_log = step.get("log")
        if remote_log is not None and (not isinstance(remote_log, str) or not remote_log):
            raise ValueError(f"scenario step {index}: log must be a remote path")
    elif action == "signal":
        signal_name = step.get("signal", "TERM")
        if isinstance(step.get("pid"), bool) or not isinstance(step.get("pid"), int) or step["pid"] <= 0:
            raise ValueError(f"scenario step {index}: positive pid and signal are required")
        if signal_name not in {"TERM", "INT", "HUP", "USR1", "USR2", "CONT", "STOP", "KILL"}:
            raise ValueError(f"scenario step {index}: unsupported signal")
    elif action == "trace":
        pid = step.get("pid")
        seconds = step.get("seconds", 5)
        if (
            isinstance(pid, bool)
            or not isinstance(pid, int)
            or pid <= 0
            or isinstance(seconds, bool)
            or not isinstance(seconds, int)
            or not 1 <= seconds <= 300
        ):
            raise ValueError(f"scenario step {index}: positive pid and bounded seconds are required")
    elif action in {"push", "pull"}:
        source = step.get("source")
        destination = step.get("destination")
        if not isinstance(source, str) or not source or not isinstance(destination, str) or not destination:
            raise ValueError(f"scenario step {index}: source and destination are required")
        if action == "pull":
            relative = Path(destination)
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError(f"scenario step {index}: destination must stay inside artifacts")
    else:
        raise ValueError(f"scenario step {index}: unsupported action {action!r}")

    expected_exit = step.get("expect_exit", 0)
    if (
        isinstance(expected_exit, bool)
        or not isinstance(expected_exit, int)
        or not 0 <= expected_exit <= 255
    ):
        raise ValueError(f"scenario step {index}: expect_exit must be between 0 and 255")
    expected_stdout = step.get("stdout_contains")
    if expected_stdout is not None and not isinstance(expected_stdout, str):
        raise ValueError(f"scenario step {index}: stdout_contains must be a string")
    if "continue_on_failure" in step and not isinstance(step["continue_on_failure"], bool):
        raise ValueError(f"scenario step {index}: continue_on_failure must be boolean")


def run_scenario(transport: Transport, scenario_path: Path, artifacts_root: Path) -> tuple[dict[str, Any], Path]:
    scenario = json.loads(scenario_path.read_text(encoding="utf-8"))
    if not isinstance(scenario, dict):
        raise ValueError("scenario must be an object")
    steps = scenario.get("steps")
    if not isinstance(steps, list):
        raise ValueError("scenario.steps must be an array")
    for index, step in enumerate(steps, start=1):
        validate_scenario_step(step, index)
    directory = unique_directory(artifacts_root)
    step_results: list[dict[str, Any]] = []
    failed = False

    for index, step in enumerate(steps, start=1):
        action = step["action"]
        name = safe_step_name(index, action, step.get("name"))
        started = time.monotonic()

        if action == "wait":
            seconds = step.get("seconds", 1)
            if not isinstance(seconds, (int, float)) or seconds < 0 or seconds > 300:
                raise ValueError(f"scenario step {index}: seconds must be between 0 and 300")
            time.sleep(seconds)
            result = Result(["wait", str(seconds)], 0, b"", b"", round((time.monotonic() - started) * 1000))
        elif action == "exec":
            result = transport.execute(
                require_string_list(step.get("argv"), f"step {index}.argv"),
                timeout=scenario_timeout(step.get("timeout", DEFAULT_TIMEOUT), index),
            )
        elif action == "input":
            button = step.get("button")
            if not isinstance(button, str) or not button:
                raise ValueError(f"scenario step {index}: button is required")
            hold_ms = step.get("hold_ms", 80)
            if not isinstance(hold_ms, int) or hold_ms < 0 or hold_ms > 10000:
                raise ValueError(f"scenario step {index}: invalid hold_ms")
            result = transport.agent(["input", button, str(hold_ms)])
        elif action == "input-start":
            mode = step.get("mode", "gamepad")
            if mode not in {"gamepad", "keyboard"}:
                raise ValueError(f"scenario step {index}: invalid input mode")
            result = transport.agent(["input-start", mode])
        elif action == "input-stop":
            result = transport.agent(["input-stop"])
        elif action == "capture":
            result = capture_to(transport, directory / f"{name}.png")
        elif action == "observe":
            result = transport.agent(["snapshot"])
        elif action == "render-info":
            result = transport.agent(["render-info"])
        elif action == "input-info":
            result = transport.agent(["input-info"])
        elif action == "process":
            pid = step.get("pid")
            if not isinstance(pid, int) or pid <= 0:
                raise ValueError(f"scenario step {index}: positive pid is required")
            result = transport.agent(["process", str(pid)])
        elif action == "start":
            argv = require_string_list(step.get("argv"), f"step {index}.argv")
            remote_log = step.get("log", f"/tmp/handheld-devtools-{uuid.uuid4().hex}.log")
            if not isinstance(remote_log, str) or not remote_log:
                raise ValueError(f"scenario step {index}: log must be a remote path")
            result = transport.agent(["start", remote_log, "--", *argv])
        elif action == "signal":
            pid = step.get("pid")
            signal_name = step.get("signal", "TERM")
            if not isinstance(pid, int) or pid <= 0 or not isinstance(signal_name, str):
                raise ValueError(f"scenario step {index}: positive pid and signal are required")
            result = transport.agent(["signal", str(pid), signal_name])
        elif action == "core":
            pid = step.get("pid")
            if not isinstance(pid, int) or pid <= 0:
                raise ValueError(f"scenario step {index}: positive pid is required")
            result = core_to(transport, pid, directory / f"{name}.core")
        elif action == "trace":
            pid = step.get("pid")
            seconds = step.get("seconds", 5)
            if not isinstance(pid, int) or pid <= 0 or not isinstance(seconds, int) or not 1 <= seconds <= 300:
                raise ValueError(f"scenario step {index}: positive pid and bounded seconds are required")
            result = trace_to(transport, pid, seconds, directory / f"{name}.strace")
        elif action == "push":
            source = Path(step["source"])
            if not source.is_absolute():
                source = scenario_path.parent / source
            destination = step.get("destination")
            result = transport.push(source.resolve(), destination)
        elif action == "pull":
            source = step.get("source")
            destination = step.get("destination")
            local_destination = scenario_artifact_path(directory, destination, index)
            local_destination.parent.mkdir(parents=True, exist_ok=True)
            result = transport.pull(source, local_destination)
        else:
            raise ValueError(f"scenario step {index}: unsupported action {action!r}")

        record = write_result(directory, name, result)
        expected_exit = step.get("expect_exit", 0)
        expected_stdout = step.get("stdout_contains")
        passed = result.returncode == expected_exit
        if expected_stdout is not None:
            passed = passed and expected_stdout in result.text_stdout()
        record["action"] = action
        record["passed"] = passed
        record["expected_exit"] = expected_exit
        step_results.append(record)
        if not passed:
            failed = True
            if step.get("continue_on_failure") is not True:
                break

    manifest = {
        "kind": "handheld-devtools-scenario",
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "name": scenario.get("name", scenario_path.stem),
        "target": transport.describe(),
        "status": "fail" if failed else "pass",
        "steps": step_results,
    }
    (directory / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    return manifest, directory


def emit_result(result: Result) -> int:
    sys.stdout.buffer.write(result.stdout)
    sys.stderr.buffer.write(result.stderr)
    return result.returncode


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="devtools", description=__doc__)
    parser.add_argument(
        "--transport", choices=("local", "docker", "ssh", "adb"), default="local"
    )
    parser.add_argument("--endpoint", help="container, SSH host[:port], or ADB serial")
    parser.add_argument("--io-endpoint", help="Docker container providing input and display I/O")
    parser.add_argument("--debug-endpoint", help="Docker toolbox joined to the Target PID namespace")
    parser.add_argument("--user", default="root", help="SSH user")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("probe")
    commands.add_parser("snapshot")
    commands.add_parser("logs")
    process = commands.add_parser("process")
    process.add_argument("pid", type=int)
    commands.add_parser("render-info")
    commands.add_parser("input-info")
    input_watch = commands.add_parser("input-watch")
    input_watch.add_argument("name")
    input_watch.add_argument("--timeout-ms", type=int, default=5000)
    input_watch.add_argument("--count", type=int, default=4)
    input_command = commands.add_parser("input")
    input_command.add_argument("button")
    input_command.add_argument("--hold-ms", type=int, default=80)
    input_start = commands.add_parser("input-start")
    input_start.add_argument("--mode", choices=("gamepad", "keyboard"), default="gamepad")
    commands.add_parser("input-stop")
    capture = commands.add_parser("capture")
    capture.add_argument("output", type=Path)
    core = commands.add_parser("core")
    core.add_argument("pid", type=int)
    core.add_argument("output", type=Path)
    trace = commands.add_parser("trace")
    trace.add_argument("pid", type=int)
    trace.add_argument("seconds", type=int)
    trace.add_argument("output", type=Path)
    start = commands.add_parser("start")
    start.add_argument("--log", required=True)
    start.add_argument("argv", nargs=argparse.REMAINDER)
    signal_command = commands.add_parser("signal")
    signal_command.add_argument("pid", type=int)
    signal_command.add_argument("--signal", default="TERM")
    execute = commands.add_parser("exec")
    execute.add_argument("argv", nargs=argparse.REMAINDER)
    push = commands.add_parser("push")
    push.add_argument("source", type=Path)
    push.add_argument("destination")
    pull = commands.add_parser("pull")
    pull.add_argument("source")
    pull.add_argument("destination", type=Path)
    diagnose_command = commands.add_parser("diagnose")
    diagnose_command.add_argument("--output", type=Path, required=True)
    diagnose_command.add_argument("--pid", type=int)
    diagnose_command.add_argument(
        "--include-logs",
        action="store_true",
        help="collect bounded kernel and journal output explicitly",
    )
    scenario = commands.add_parser("scenario")
    scenario.add_argument("file", type=Path)
    scenario.add_argument("--artifacts", type=Path, required=True)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    transport: Transport | None = None
    try:
        transport = make_transport(args)
        if args.command == "probe":
            result = transport.agent(["capabilities"])
            if result.returncode != 0:
                return emit_result(result)
            report = {
                "target": transport.describe(),
                "capabilities": parse_capabilities(result.text_stdout()),
            }
            print(json.dumps(report, ensure_ascii=False, indent=2))
            return 0
        if args.command == "snapshot":
            return emit_result(transport.agent(["snapshot"]))
        if args.command == "logs":
            return emit_result(transport.agent(["logs"]))
        if args.command == "process":
            return emit_result(transport.agent(["process", str(args.pid)]))
        if args.command == "render-info":
            return emit_result(transport.agent(["render-info"]))
        if args.command == "input-info":
            return emit_result(transport.agent(["input-info"]))
        if args.command == "input-watch":
            return emit_result(
                transport.agent(
                    ["input-watch", args.name, str(args.timeout_ms), str(args.count)],
                    timeout=max(DEFAULT_TIMEOUT, args.timeout_ms // 1000 + 10),
                )
            )
        if args.command == "input":
            return emit_result(transport.agent(["input", args.button, str(args.hold_ms)]))
        if args.command == "input-start":
            return emit_result(transport.agent(["input-start", args.mode]))
        if args.command == "input-stop":
            return emit_result(transport.agent(["input-stop"]))
        if args.command == "capture":
            return emit_result(capture_to(transport, args.output.resolve()))
        if args.command == "core":
            return emit_result(core_to(transport, args.pid, args.output.resolve()))
        if args.command == "trace":
            return emit_result(trace_to(transport, args.pid, args.seconds, args.output.resolve()))
        if args.command == "start":
            argv = args.argv[1:] if args.argv[:1] == ["--"] else args.argv
            if not argv:
                parser.error("start requires a command argument vector")
            return emit_result(transport.agent(["start", args.log, "--", *argv]))
        if args.command == "signal":
            return emit_result(transport.agent(["signal", str(args.pid), args.signal]))
        if args.command == "exec":
            argv = args.argv[1:] if args.argv[:1] == ["--"] else args.argv
            if not argv:
                parser.error("exec requires a command argument vector")
            return emit_result(transport.execute(argv))
        if args.command == "push":
            return emit_result(transport.push(args.source.resolve(), args.destination))
        if args.command == "pull":
            return emit_result(transport.pull(args.source, args.destination.resolve()))
        if args.command == "diagnose":
            manifest, directory = diagnose(
                transport,
                args.output.resolve(),
                args.pid,
                include_logs=args.include_logs,
            )
            print(directory)
            return 0 if manifest["status"] == "pass" else 1
        if args.command == "scenario":
            manifest, directory = run_scenario(
                transport, args.file.resolve(), args.artifacts.resolve()
            )
            print(directory)
            return 0 if manifest["status"] == "pass" else 1
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"handheld-devtools: {error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("handheld-devtools: interrupted", file=sys.stderr)
        return 130
    finally:
        if transport is not None:
            transport.close()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
