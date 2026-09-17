#!/usr/bin/env bash
# INPUT:  共享 kit.lua、各端口 Lua 入口与 portmaster_common.sh
# OUTPUT: 联系方式、共享 UI 引用和中文字体供应断言结果
# POS:    启动器公共联系信息与中文显示依赖的静态回归测试
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTACT="QQ 群 1047158975"

grep -Fq "$CONTACT" "$ROOT/_kit/love/kit.lua" || {
  echo "_kit/love/kit.lua: missing launcher contact text: $CONTACT" >&2
  exit 1
}

for main in "$ROOT"/ports/*/love/main.lua; do
  grep -Eq 'require\("(launcher|kit)"\)' "$main" || {
    echo "${main#$ROOT/}: does not load the shared LÖVE layer" >&2
    exit 1
  }
done

grep -Fq 'NotoSansSC-Regular.ttf' "$ROOT/_kit/portmaster_common.sh" || {
  echo "shared love launcher no longer provisions the CJK font" >&2
  exit 1
}
