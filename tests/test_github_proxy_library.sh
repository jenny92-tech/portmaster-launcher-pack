#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=../_kit/github_proxy.sh
source "$ROOT/_kit/github_proxy.sh"

# The reusable module owns a non-empty bundled default registry. Applications
# consume it without carrying their own proxy data.
[ "${#GITHUB_PROXY_CUSTOM_ROUTES}" -gt 200 ]
[ "${#GITHUB_PROXY_FULL_ROUTES}" -gt 1000 ]
default_registry=$(github_proxy_registry)
[ "$(grep -c '^c' <<< "$default_registry")" -ge 4 ]
[ "$(grep -c '^g' <<< "$default_registry")" -ge 30 ]
grep -Fq $'origin\tdirect\t' <<< "$default_registry"

GITHUB_PROXY_REGISTRY_OVERRIDE=$(printf '%s\n' \
  $'full-a\tfull\trelease,raw,archive,clone,gist\thttps://full.example' \
  $'mirror-a\tmirror\trelease,raw,archive\thttps://mirror.example' \
  $'cdn-a\tjsdelivr\traw\thttps://cdn.example/gh' \
  $'clone-a\tgitclone\tclone\thttps://clone.example' \
  $'origin\tdirect\trelease,raw,archive,clone,api,gist\t')

release='https://github.com/acme/demo/releases/download/v1/demo.zip'
raw='https://raw.githubusercontent.com/acme/demo/main/path/file.txt'
archive='https://github.com/acme/demo/archive/refs/heads/main.zip'
clone='https://github.com/acme/demo.git'
api='https://api.github.com/repos/acme/demo/releases/latest'

assert_eq() {
  [ "$1" = "$2" ] || { printf 'expected: %s\nactual:   %s\n' "$1" "$2" >&2; exit 1; }
}

assert_eq 'https://full.example/https://github.com/acme/demo/releases/download/v1/demo.zip' \
  "$(github_proxy_format_url release full https://full.example "$release")"
assert_eq 'https://mirror.example/acme/demo/releases/download/v1/demo.zip' \
  "$(github_proxy_format_url release mirror https://mirror.example "$release")"
assert_eq 'https://mirror.example/acme/demo/raw/main/path/file.txt' \
  "$(github_proxy_format_url raw mirror https://mirror.example "$raw")"
assert_eq 'https://cdn.example/gh/acme/demo@main/path/file.txt' \
  "$(github_proxy_format_url raw jsdelivr https://cdn.example/gh "$raw")"
assert_eq 'https://clone.example/github.com/acme/demo.git' \
  "$(github_proxy_format_url clone gitclone https://clone.example "$clone")"
assert_eq "$api" "$(github_proxy_format_url api direct '' "$api")"
assert_eq 'https://full.example/https://github.com/acme/demo/archive/refs/heads/main.zip' \
  "$(github_proxy_format_url archive full https://full.example "$archive")"

# Capability filtering is declarative: a Raw-only CDN must never be offered
# for a Release, while API currently stays on the origin route.
release_candidates=$(github_proxy_candidates release "$release")
grep -Fq $'full-a\thttps://full.example/' <<< "$release_candidates"
grep -Fq $'mirror-a\thttps://mirror.example/' <<< "$release_candidates"
grep -Fq $'origin\thttps://github.com/' <<< "$release_candidates"
! grep -Fq $'cdn-a\t' <<< "$release_candidates"
! grep -Fq $'clone-a\t' <<< "$release_candidates"
assert_eq $'origin\thttps://api.github.com/repos/acme/demo/releases/latest' \
  "$(github_proxy_candidates api "$api")"

# A successful range probe does not establish content validity. The first
# batch here probes successfully but all full downloads are poisoned. Fetch
# must continue to the next bounded batch and accept its validated payload.
GITHUB_PROXY_BATCH_SIZE=2
GITHUB_PROXY_STATE_DIR="$TMP/state"
mkdir -p "$GITHUB_PROXY_STATE_DIR"
PROBE_LOG="$TMP/probes.log"
TRANSFER_LOG="$TMP/transfers.log"

github_proxy_probe_hook() {
  case "$1" in https://raw.githubusercontent.com/*) sleep 0.05 ;; esac
  printf '%s\n' "$1" >> "$PROBE_LOG"
  printf 'probe' > "$2"
}

github_proxy_transfer_hook() {
  local url="$1" out="$2"
  printf '%s\n' "$url" >> "$TRANSFER_LOG"
  case "$url" in
    https://cdn.example/*) printf 'VALID payload\n' > "$out" ;;
    *) printf 'proxy error page\n' > "$out" ;;
  esac
}

validate_payload() { grep -Fq 'VALID payload' "$1"; }

# Reorder the registry so the only good Raw route is in batch two.
GITHUB_PROXY_REGISTRY_OVERRIDE=$(printf '%s\n' \
  $'bad-a\tfull\traw\thttps://bad-a.example' \
  $'bad-b\tmirror\traw\thttps://bad-b.example' \
  $'cdn-a\tjsdelivr\traw\thttps://cdn.example/gh' \
  $'origin\tdirect\traw\t')
out="$TMP/file.txt"
github_proxy_fetch raw "$raw" "$out" validate_payload
grep -Fq 'VALID payload' "$out"
[ "$GITHUB_PROXY_LAST_RAW" = "cdn-a" ]
[ "$(wc -l < "$PROBE_LOG" | tr -d ' ')" = 4 ]
[ "$(wc -l < "$TRANSFER_LOG" | tr -d ' ')" = 3 ]
grep -Fq 'bad-a.example' "$TRANSFER_LOG"
grep -Fq 'bad-b.example' "$TRANSFER_LOG"
grep -Fq 'cdn.example' "$TRANSFER_LOG"

# The validated route is preferred again only inside this shell process. It is
# kept separately per capability and no preference file is written.
: > "$PROBE_LOG"; : > "$TRANSFER_LOG"
out="$TMP/file-cached.txt"
github_proxy_fetch raw "$raw" "$out" validate_payload
grep -Fq 'VALID payload' "$out"
[ "$(wc -l < "$TRANSFER_LOG" | tr -d ' ')" = 1 ]
grep -Fq 'cdn.example' "$TRANSFER_LOG"
[ -z "${GITHUB_PROXY_LAST_RELEASE:-}" ]
! find "$GITHUB_PROXY_STATE_DIR" -maxdepth 1 -name 'github-proxy-preferred.*' | grep -q .

# A remembered route is only a hint. If it stops validating, the same call
# continues through normal batches and replaces the hint with the new winner.
GITHUB_PROXY_LAST_RAW=bad-a
: > "$PROBE_LOG"; : > "$TRANSFER_LOG"
out="$TMP/file-failover.txt"
github_proxy_fetch raw "$raw" "$out" validate_payload
grep -Fq 'bad-a.example' "$TRANSFER_LOG"
grep -Fq 'cdn.example' "$TRANSFER_LOG"
[ "$GITHUB_PROXY_LAST_RAW" = "cdn-a" ]

# Resume state belongs to one route only. Switching route IDs discards bytes
# from the previous endpoint instead of combining two potentially different
# responses into one file.
printf 'old partial' > "$TMP/switch.part"
printf 'old-route\n' > "$TMP/switch.part.route"
github_proxy_transfer_one new-route https://cdn.example/gh/x "$TMP/switch" validate_payload
grep -Fxq 'VALID payload' "$TMP/switch"
[ ! -e "$TMP/switch.part.route" ]

# Clone has its own smart-HTTP execution path. Raw-only and Release-only
# routes are excluded before probing, and a failed responsive clone falls
# through to the next Clone-capable implementation.
CLONE_PROBE_LOG="$TMP/clone-probes.log"
CLONE_ATTEMPT_LOG="$TMP/clone-attempts.log"
GITHUB_PROXY_REGISTRY_OVERRIDE=$(printf '%s\n' \
  $'raw-only\tjsdelivr\traw\thttps://cdn.example/gh' \
  $'clone-bad\tgitclone\tclone\thttps://clone-bad.example' \
  $'clone-good\tfull\tclone\thttps://clone-good.example')
github_proxy_clone_probe_hook() {
  case "$1" in https://clone-good.example/*) sleep 0.05 ;; esac
  printf '%s\n' "$1" >> "$CLONE_PROBE_LOG"
  printf 'git-upload-pack' > "$2"
}
github_proxy_clone_hook() {
  printf '%s\n' "$1" >> "$CLONE_ATTEMPT_LOG"
  case "$1" in
    https://clone-good.example/*) mkdir -p "$2/.git" ;;
    *) return 1 ;;
  esac
}
github_proxy_clone "$clone" "$TMP/clone"
[ -d "$TMP/clone/.git" ]
[ "$GITHUB_PROXY_LAST_CLONE" = "clone-good" ]
[ "$(wc -l < "$CLONE_PROBE_LOG" | tr -d ' ')" = 2 ]
[ "$(wc -l < "$CLONE_ATTEMPT_LOG" | tr -d ' ')" = 2 ]
! grep -Fq 'cdn.example' "$CLONE_PROBE_LOG"

for invalid in \
  'https://example.com/file.zip' \
  'http://github.com/acme/demo/releases/download/v1/demo.zip'; do
  ! github_proxy_validate_source release "$invalid"
done

echo 'github proxy library tests: PASS'
