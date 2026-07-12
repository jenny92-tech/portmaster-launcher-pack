#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for port in batomon heishenhua hk terraria sts2 vampiresurvivors114; do
  license="$ROOT/ports/$port/LICENSE"
  [ -s "$license" ] || {
    echo "$port: missing LICENSE" >&2
    exit 1
  }
  grep -Fq "CC BY-NC-SA 4.0" "$license" || {
    echo "$port: LICENSE does not mention CC BY-NC-SA 4.0" >&2
    exit 1
  }
  grep -Fq "Game files are NOT covered" "$license" || {
    echo "$port: LICENSE missing separate game-files notice" >&2
    exit 1
  }
done
