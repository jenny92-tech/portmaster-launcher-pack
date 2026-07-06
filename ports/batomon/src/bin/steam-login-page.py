#!/usr/bin/env python3
from __future__ import annotations

import html
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class LoginPage(BaseHTTPRequestHandler):
    url_path = Path("/tmp/batomon_steam_login_url.txt")
    log_path = Path("/tmp/batomon_steam_login_page.log")

    def log_message(self, fmt: str, *args) -> None:
        with self.log_path.open("a", encoding="utf-8") as fh:
            fh.write((fmt % args) + "\n")

    def do_GET(self) -> None:
        url = self.url_path.read_text(encoding="utf-8").strip()
        if self.path == "/go":
            self.send_response(302)
            self.send_header("Location", url)
            self.end_headers()
            return
        body = f"""<!doctype html>
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Batormon Steam Login</title>
<body style="font-family:sans-serif;line-height:1.4;padding:24px">
<h1>Batormon Steam Login</h1>
<p>Open the Steam login below. After Steam signs in, it will return to the handheld.</p>
<p><a href="/go" style="font-size:20px">Continue with Steam</a></p>
<p style="word-break:break-all"><small>{html.escape(url)}</small></p>
</body>""".encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main() -> int:
    if len(sys.argv) != 5:
        print("usage: steam-login-page.py BIND_HOST PORT URL_FILE LOG", file=sys.stderr)
        return 2
    bind_host, port, url_file, log_file = sys.argv[1], int(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4])
    LoginPage.url_path = url_file
    LoginPage.log_path = log_file
    try:
        server = ThreadingHTTPServer((bind_host, port), LoginPage)
    except OSError as exc:
        log_file.write_text(f"page not started: {exc}\n", encoding="utf-8")
        return 0
    log_file.write_text(f"page listening on {bind_host}:{port}\n", encoding="utf-8")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
