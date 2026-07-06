#!/usr/bin/env python3
from __future__ import annotations

import http.client
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Relay(BaseHTTPRequestHandler):
    target_host = "127.0.0.1"
    target_port = 41999
    log_path = Path("/tmp/batomon_steam_login_relay.log")

    def log_message(self, fmt: str, *args) -> None:
        with self.log_path.open("a", encoding="utf-8") as fh:
            fh.write((fmt % args) + "\n")

    def do_GET(self) -> None:
        try:
            conn = http.client.HTTPConnection(self.target_host, self.target_port, timeout=10)
            conn.request("GET", self.path, headers={"Host": f"{self.target_host}:{self.target_port}"})
            res = conn.getresponse()
            body = res.read()
            self.send_response(res.status)
            for key, value in res.getheaders():
                if key.lower() not in {"connection", "transfer-encoding"}:
                    self.send_header(key, value)
            self.end_headers()
            self.wfile.write(body)
        except Exception as exc:
            self.send_response(502)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(f"Batormon Steam login relay failed: {exc}\n".encode("utf-8"))


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: steam-login-relay.py BIND_HOST PORT LOG", file=sys.stderr)
        return 2

    bind_host, port, log_path = sys.argv[1], int(sys.argv[2]), Path(sys.argv[3])
    Relay.target_port = port
    Relay.log_path = log_path

    try:
        server = ThreadingHTTPServer((bind_host, port), Relay)
    except OSError as exc:
        log_path.write_text(f"relay not started: {exc}\n", encoding="utf-8")
        return 0

    log_path.write_text(f"relay listening on {bind_host}:{port}\n", encoding="utf-8")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
