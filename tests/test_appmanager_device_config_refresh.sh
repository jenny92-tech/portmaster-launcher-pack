#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
server_pid=""
lock_pid=""
cleanup() {
  [ -z "$lock_pid" ] || kill "$lock_pid" 2>/dev/null || true
  [ -z "$lock_pid" ] || wait "$lock_pid" 2>/dev/null || true
  [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
  [ -z "$server_pid" ] || wait "$server_pid" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

cargo build --quiet --manifest-path "$ROOT/Cargo.toml" -p portkit-cli
grep -Fq 'config refresh' "$ROOT/ports/appmanager/src/launcher.sh"
! grep -Eq '^(pam_config_refresh_session_matches|pam_config_version_is_newer|pam_valid_config_version)\(\)' \
  "$ROOT/ports/appmanager/src/launcher.sh"
mkdir -p "$TMP/source" "$TMP/app/bin" "$TMP/state" "$TMP/served/platforms"
cp -R "$ROOT/config" "$TMP/app/config"
make_config_version() {
  python3 - "$ROOT/config/config.json" "$ROOT/config/platforms/trimui.json" "$1" "$2" "$3" <<'PY'
import hashlib, json, sys
root_path, detail_path, version, root_out, detail_out = sys.argv[1:]
root = json.load(open(root_path, encoding="utf-8"))
detail = json.load(open(detail_path, encoding="utf-8"))
root["config_version"] = version
detail["config_version"] = version
detail_bytes = (json.dumps(detail, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()
root["platforms"]["trimui"]["sha256"] = hashlib.sha256(detail_bytes).hexdigest()
open(detail_out, "wb").write(detail_bytes)
open(root_out, "w", encoding="utf-8").write(json.dumps(root, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")
PY
}
make_config_version 1.1.1 "$TMP/newer.json" "$TMP/newer-detail.json"
make_config_version 1.1.2 "$TMP/newest.json" "$TMP/newest-detail.json"

cat > "$TMP/server.py" <<'PY'
import http.server, os, pathlib, socketserver, sys, time
root = pathlib.Path(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self): self.serve(False)
    def do_HEAD(self): self.serve(True)
    def serve(self, head):
        delay = root / "delay"
        time.sleep(float(delay.read_text() if delay.exists() else "0"))
        if self.path.endswith("/platforms/trimui.json"):
            path = root / "platforms/trimui.json"
        elif self.path.endswith("/config.json"):
            path = root / "config.json"
        else:
            self.send_error(404); return
        body = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if not head:
            try: self.wfile.write(body)
            except BrokenPipeError: pass
with socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler) as server:
    print(server.server_address[1], flush=True)
    server.serve_forever()
PY
PAM_TEST_CONFIG_DELAY=0 python3 "$TMP/server.py" "$TMP/served" > "$TMP/port" &
server_pid=$!
for _ in $(seq 1 50); do [ -s "$TMP/port" ] && break; sleep 0.02; done
port=$(cat "$TMP/port")

run_refresh() {
  cp "$1" "$TMP/served/config.json"
  cp "$2" "$TMP/served/platforms/trimui.json"
  printf '%s\n' "${PAM_TEST_CONFIG_DELAY:-0}" > "$TMP/served/delay"
  env PAM_TOOL_MODE=system PAM_PORTKIT_BIN_OVERRIDE="$ROOT/target/debug/portkit" \
    PORTKIT_GITHUB_ROUTES="http://127.0.0.1:$port" \
    PAM_DEVICE_CONFIG_URL="https://raw.githubusercontent.com/jenny92-tech/appmanager-config-test-fixture/main/config/config.json" \
    PAM_NATIVE_LAUNCHER_OVERRIDE='/mnt/SDCARD/Roms/PORTS/APP Manager.sh' CFW_NAME=TrimUI \
    PAM_SOURCE_DIR="$TMP/source" PAM_APP_ROOT_OVERRIDE="$TMP/app" PAM_STATE_DIR_OVERRIDE="$TMP/state" \
    bash "$ROOT/ports/appmanager/src/launcher.sh" --refresh-device-config
}

run_refresh "$TMP/newer.json" "$TMP/newer-detail.json"
cmp "$TMP/newer.json" "$TMP/state/device-config/config.json"
cmp "$TMP/newer-detail.json" "$TMP/state/device-config/platforms/trimui.json"
grep -Fxq $'1\tupdated' "$TMP/state/config-refresh.tsv"

run_refresh "$TMP/newer.json" "$TMP/newer-detail.json"
grep -Fxq $'1\tunchanged' "$TMP/state/config-refresh.tsv"

# An older or same-version response never replaces the last-known-good cache.
run_refresh "$ROOT/config/config.json" "$ROOT/config/platforms/trimui.json"
grep -Fxq $'1\tunchanged' "$TMP/state/config-refresh.tsv"
cmp "$TMP/newer.json" "$TMP/state/device-config/config.json"

# The UI gives refresh a bounded startup window. A download that outlives that
# window must never promote its staged file over the active configuration.
cp "$TMP/state/device-config/config.json" "$TMP/active-before.json"
SECONDS=0
if PAM_TEST_CONFIG_DELAY=2 PAM_CONFIG_REFRESH_TIMEOUT_SECONDS=1 run_refresh "$TMP/newest.json" "$TMP/newest-detail.json"; then
  echo "expired device config refresh unexpectedly succeeded" >&2
  exit 1
fi
[ "$SECONDS" -le 2 ] || { echo "device config refresh did not honor its global deadline" >&2; exit 1; }
grep -Fxq $'1\terror' "$TMP/state/config-refresh.tsv"
cmp "$TMP/active-before.json" "$TMP/state/device-config/config.json"

# Only one refresh may select and promote a generation at a time.
python3 - "$TMP/state/.device-config-refresh.lock" "$TMP/lock-ready" <<'PY' &
import fcntl, pathlib, sys, time
lock = open(sys.argv[1], "a+")
fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
pathlib.Path(sys.argv[2]).write_text("ready")
time.sleep(10)
PY
lock_pid=$!
for _ in $(seq 1 50); do [ -s "$TMP/lock-ready" ] && break; sleep 0.02; done
if run_refresh "$TMP/newest.json" "$TMP/newest-detail.json"; then
  echo "concurrent device config refresh unexpectedly succeeded" >&2
  exit 1
fi
grep -Fxq $'1\terror' "$TMP/state/config-refresh.tsv"
kill "$lock_pid" 2>/dev/null || true
wait "$lock_pid" 2>/dev/null || true
lock_pid=""

printf '{"format":"broken"}\n' > "$TMP/broken.json"
if run_refresh "$TMP/broken.json" "$ROOT/config/platforms/trimui.json"; then
  echo "invalid remote device config was accepted" >&2
  exit 1
fi
grep -Fxq $'1\terror' "$TMP/state/config-refresh.tsv"
cmp "$TMP/newer.json" "$TMP/state/device-config/config.json"

echo "appmanager device config refresh tests: PASS"
