#!/usr/bin/env bash
# INPUT:  恢复项目、静态 overlay、rsync、Python
# OUTPUT: 覆盖后的项目与移除 Sentry 自加载/扩展的配置
# POS:    将 STS2 ARM64 扩展替代文件应用到恢复工程
# Apply StS2-specific patches to a recovered project directory.
# Run after `extract.sh` + `patch_project.py` + `reimport.sh`, before `repack.sh`.
#
# Usage: apply.sh <recovered_dir>

set -euo pipefail

DIR="${1:?usage: apply.sh <recovered_dir>}"
PATCH_DIR="$(cd "$(dirname "$0")" && pwd)"

[ -f "$DIR/project.godot" ] || { echo "no project.godot at $DIR"; exit 1; }

echo "==> overlay files from $PATCH_DIR/overlay/"
rsync -a "$PATCH_DIR/overlay/" "$DIR/"

echo "==> remove SentryInit autoload (gdextension class doesn't exist on arm64)"
python3 -c "
import re, sys
p = sys.argv[1]
s = open(p).read()
s2 = re.sub(r'^SentryInit=\".+?\"\n', '', s, flags=re.MULTILINE)
open(p, 'w').write(s2)
print('  ' + ('removed' if s != s2 else 'already absent'))
" "$DIR/project.godot"

echo "==> drop sentry.gdextension config so godot stops looking for arm64 lib"
rm -f "$DIR/addons/sentry/sentry.gdextension"
rm -f "$DIR/addons/sentry/sentry.gdextension.uid"

echo "==> done"
