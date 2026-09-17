#!/usr/bin/env bash
# INPUT:  各游戏与录屏端口的 LICENSE 文件
# OUTPUT: 授权文件存在性和游戏资源独立授权声明断言结果
# POS:    端口发行授权文本完整性的静态检查
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for port in batomon heishenhua hk recorder sunkendragon terraria sts2 vampiresurvivors114; do
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
