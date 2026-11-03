#!/usr/bin/env bash
# INPUT:  wine-loongos 源码、manifest、截图及 _kit 元数据/组装工具
# OUTPUT: 含私有启动环境、运行器代码和说明的 dist 暂存目录
# POS:    接入共享构建身份流程，交给 dist-zip.py 封装为 SD 卡布局
set -euo pipefail
SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT_ROOT="$(cd "$SRC_ROOT/.." && pwd)"
REPO_ROOT="$(cd "$PORT_ROOT/../.." && pwd)"
DIST="$PORT_ROOT/dist"
APP="$DIST/wine-loongos"
BOOTSTRAP="${WINE_BOOTSTRAP_DIR:-$REPO_ROOT/dist/wine-bootstrap-pack}"
[ -f "$BOOTSTRAP/bootstrap-aarch64.squashfs" ] && [ -f "$BOOTSTRAP/bootstrap.sha256" ] || {
    echo "Build the private launcher environment with src/scripts/build-bootstrap.py first." >&2; exit 78;
}
rm -rf "$DIST"
mkdir -p "$APP"
bash "$REPO_ROOT/_kit/assemble.sh" "$SRC_ROOT/launcher.sh" "$DIST/Je-Wine.sh"
cp "$SRC_ROOT/launcher.py" "$SRC_ROOT/bootstrap.sh" "$SRC_ROOT/wine_ui.py" "$SRC_ROOT/wine_input.py" "$SRC_ROOT/wine_session.py" "$SRC_ROOT/run.sh" "$SRC_ROOT/runtime_mount.py" "$SRC_ROOT/runtime_install.py" "$SRC_ROOT/wine_package.py" "$SRC_ROOT/wine_catalog.py" "$SRC_ROOT/wine_game.py" "$SRC_ROOT/wine_layout.py" "$SRC_ROOT/wine_bottle.py" "$SRC_ROOT/desktop.gptk" "$APP/"
cp "$BOOTSTRAP/bootstrap-aarch64.squashfs" "$BOOTSTRAP/bootstrap.sha256" "$PORT_ROOT/bootstrap-sources.json" "$APP/"
mkdir -p "$APP/runtime-patches"
cp "$SRC_ROOT/runtime-patches/"*.patch "$SRC_ROOT/runtime-patches/"*.h "$SRC_ROOT/runtime-patches/Dockerfile.wine" "$SRC_ROOT/runtime-patches/BUILD.md" "$APP/runtime-patches/"
cp "$SRC_ROOT/wine-game.example.json" "$APP/"
cp "$SRC_ROOT/bottle.example.json" "$APP/"
for category in devices environments components; do
    mkdir -p "$APP/$category"
    while IFS= read -r source; do
        relative="${source#"$SRC_ROOT/$category/"}"
        mkdir -p "$APP/$category/$(dirname "$relative")"
        cp "$source" "$APP/$category/$relative"
    done < <(find "$SRC_ROOT/$category" -type f -name '*.json' | sort)
done
cp "$SRC_ROOT/games-README.txt" "$APP/games-README.txt"
cp "$PORT_ROOT/README.md" "$PORT_ROOT/LICENSE" "$PORT_ROOT/runtime-sources.json" "$APP/"
cp "$PORT_ROOT/wsi-ext-timestamps.patch" "$APP/"
cp "$PORT_ROOT/screenshot.png" "$DIST/screenshot.png"
cp "$PORT_ROOT/screenshot.png" "$DIST/Je-Wine.png"
chmod 755 "$DIST/Je-Wine.sh" "$APP/run.sh"
python3 "$REPO_ROOT/_kit/port_json.py" "$PORT_ROOT/manifest.json" "$DIST" wine-loongos
python3 "$REPO_ROOT/_kit/build_info.py" "$PORT_ROOT/manifest.json" "$DIST"
bash -n "$DIST/Je-Wine.sh" "$APP/run.sh"
echo ">>> packaged wine-loongos -> $DIST"
