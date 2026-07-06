#!/usr/bin/env python3
from __future__ import annotations

import sys
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: steam-login-url.py URL HOST PORT", file=sys.stderr)
        return 2

    url, host, port = sys.argv[1:]
    callback = f"http://{host}:{port}"
    split = urlsplit(url)
    query = []
    for key, value in parse_qsl(split.query, keep_blank_values=True):
        if key in {"openid.return_to", "openid.realm"}:
            value = callback
        query.append((key, value))
    print(urlunsplit((split.scheme, split.netloc, split.path, urlencode(query), split.fragment)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
