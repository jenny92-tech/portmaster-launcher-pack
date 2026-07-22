#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCES="$ROOT/ports/appmanager/src/appmanager_sources.sh"

bash -n "$SOURCES"

(
  source "$SOURCES"
  [ "$PAM_FORK_RELEASES_URL" = "https://github.com/jenny92-tech/PortMaster-GUI/releases" ]
  [ "$PAM_OFFICIAL_RELEASES_URL" = "https://github.com/PortsMaster/PortMaster-GUI/releases" ]
  [ "$PAM_RUNTIME_RELEASES_URL" = "https://github.com/PortsMaster/PortMaster-New/releases" ]
  [ "$PAM_CUSTOM_VERSION_URL" = "$PAM_FORK_RELEASES_URL/latest/download/version.json" ]
  [ "$PAM_OFFICIAL_VERSION_URL" = "$PAM_OFFICIAL_RELEASES_URL/latest/download/version.json" ]
  [ "$PAM_DEVICE_CONFIG_URL" = "https://raw.githubusercontent.com/jenny92-tech/portmaster-launcher-pack/main/config/config.json" ]
  [ "$RUNTIME_METADATA_URL" = "$PAM_RUNTIME_RELEASES_URL/latest/download/ports.json" ]
)

(
  PAM_GITHUB_WEB_ORIGIN=https://mirror.example
  PAM_GITHUB_RAW_ORIGIN=https://raw.example
  PAM_FORK_REPOSITORY=owner/fork
  PAM_OFFICIAL_REPOSITORY=owner/upstream
  PAM_RUNTIME_REPOSITORY=owner/runtimes
  source "$SOURCES"
  [ "$PAM_FORK_RELEASES_URL" = "https://mirror.example/owner/fork/releases" ]
  [ "$PAM_OFFICIAL_RELEASES_URL" = "https://mirror.example/owner/upstream/releases" ]
  [ "$PAM_RUNTIME_RELEASES_URL" = "https://mirror.example/owner/runtimes/releases" ]
  [ "$PAM_DEVICE_CONFIG_URL" = "https://raw.example/jenny92-tech/portmaster-launcher-pack/main/config/config.json" ]
)

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"$ROOT/_kit/assemble.sh" "$ROOT/ports/appmanager/src/launcher.sh" "$TMP/appmanager.sh" >/dev/null
grep -Fq 'PAM_FORK_REPOSITORY=' "$TMP/appmanager.sh"
! grep -Fq 'source "$PORT_SRC/appmanager_sources.sh"' "$TMP/appmanager.sh"
bash -n "$TMP/appmanager.sh"

echo "appmanager publication sources: PASS"
