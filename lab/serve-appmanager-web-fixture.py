#!/usr/bin/env python3
"""Serve the real APP Manager web UI with deterministic evaluation data.

This fixture intentionally does not reproduce install, trash, or restore
business rules. Those rules belong to the Rust device-profile E2E suite. It
only supplies stable HTTP states so a browser can evaluate the shipped HTML,
responsive layout, pairing flow, and exact item-path payloads.
"""

from __future__ import annotations

import argparse
import json
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
INDEX = ROOT / "crates" / "appmanager-service" / "src" / "web" / "index.html"
PAIRING_CODE = "123456"
TOKEN = "appmanager-browser-fixture"


SNAPSHOT: dict[str, Any] = {
    "ok": True,
    "revision": "browser-fixture",
    "device": {"name": "DevTools Fixture", "platform": "trimui"},
    "capabilities": {"install": True, "trash": True},
    "items": [
        {
            "kind": "port",
            "name": "Z_PVZ_年度版",
            "paths": ["/roms/ports/Z_PVZ_年度版.sh"],
            "manageable": True,
            "keeps_shared_data": True,
        },
        {
            "kind": "app",
            "name": "文件管理器",
            "paths": ["/mnt/SDCARD/Apps/FileManager"],
            "manageable": True,
            "keeps_shared_data": False,
        },
    ],
    "trash": [
        {
            "bucket": "scripts",
            "name": "旧启动项.sh",
            "path": "/mnt/SDCARD/.appmanager-trash/scripts/旧启动项.sh",
            "is_dir": False,
            "restorable": True,
            "restore_conflict": False,
        },
        {
            "bucket": "data",
            "name": "pvz",
            "path": "/mnt/SDCARD/.appmanager-trash/data/pvz",
            "is_dir": True,
            "restorable": True,
            "restore_conflict": True,
        },
    ],
}


class Handler(BaseHTTPRequestHandler):
    server_version = "AppManagerWebFixture"

    def log_message(self, message: str, *args: object) -> None:
        print(f"{self.address_string()} - {message % args}")

    def _json(self, status: HTTPStatus, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self) -> bool:
        if self.headers.get("X-AppManager-Token") == TOKEN:
            return True
        self._json(HTTPStatus.UNAUTHORIZED, {"ok": False, "error": "请重新配对"})
        return False

    def _read_body(self) -> bytes:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        return self.rfile.read(max(0, length))

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path in ("/", "/index.html"):
            body = INDEX.read_bytes()
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/api/status":
            self._json(HTTPStatus.OK, {"ok": True, "service": "port-app-manager"})
            return
        if self.path == "/api/snapshot":
            if self._authorized():
                self._json(HTTPStatus.OK, SNAPSHOT)
            return
        self._json(HTTPStatus.NOT_FOUND, {"ok": False, "error": "not found"})

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path == "/api/session":
            code = self._read_body().decode("utf-8", errors="replace")
            if code == PAIRING_CODE:
                self._json(HTTPStatus.OK, {"ok": True, "token": TOKEN})
            else:
                self._json(HTTPStatus.UNAUTHORIZED, {"ok": False, "error": "配对码错误"})
            return
        if self.path in ("/api/manage", "/api/cancel"):
            if not self._authorized():
                return
            body = self._read_body()
            if self.path == "/api/manage":
                try:
                    request = json.loads(body or b"{}")
                except json.JSONDecodeError:
                    self._json(HTTPStatus.BAD_REQUEST, {"ok": False, "error": "invalid json"})
                    return
                if request.get("revision") != SNAPSHOT["revision"]:
                    self._json(HTTPStatus.CONFLICT, {"ok": False, "error": "inventory changed"})
                    return
            self._json(HTTPStatus.OK, {"ok": True})
            return
        if self.path == "/api/upload":
            if not self._authorized():
                return
            self._read_body()
            self._json(
                HTTPStatus.OK,
                {"ok": True, "result": {"installed": ["browser-fixture"], "conflicts": []}},
            )
            return
        self._json(HTTPStatus.NOT_FOUND, {"ok": False, "error": "not found"})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8766)
    args = parser.parse_args()
    if not INDEX.is_file():
        parser.error(f"web UI not found: {INDEX}")
    server = ThreadingHTTPServer((args.bind, args.port), Handler)
    print(f"APP Manager browser fixture: http://{args.bind}:{args.port}/")
    print(f"Pairing code: {PAIRING_CODE}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
