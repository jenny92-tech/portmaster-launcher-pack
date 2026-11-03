#!/usr/bin/env bash
# INPUT:  config/config.json、APP Manager Shell 入口与 Rust 服务源码
# OUTPUT: 发布源 URL、路由和原生配置归属的静态断言结果
# POS:    APP Manager 配置驱动发布源契约回归测试
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$ROOT/config/config.json"

python3 - "$CONFIG" <<'PY'
import json, sys

config=json.load(open(sys.argv[1], encoding="utf-8"))
sources=config["sources"]
endpoints=sources["endpoints"]
routes=sources["release_routes"]
assert endpoints["jenny92_portmaster"] == "https://github.com/jenny92-tech/PortMaster-GUI/releases/latest/download/version.json"
assert endpoints["official_portmaster"] == "https://github.com/PortsMaster/PortMaster-GUI/releases/latest/download/version.json"
assert endpoints["runtime_metadata"] == "https://github.com/PortsMaster/PortMaster-New/releases/latest/download/ports.json"
assert routes["miniloong-custom"]["manifest"] == "jenny92_portmaster"
assert routes["official"]["manifest"] == "official_portmaster"
assert routes["system"]["install_allowed"] is False
assert sources["runtime"]["metadata"] == "runtime_metadata"
assert config["bootstrap"]["config_url"] == "https://raw.githubusercontent.com/jenny92-tech/portmaster-launcher-pack/main/config/config.json"
PY

[ ! -e "$ROOT/ports/appmanager/src/appmanager_sources.sh" ]
! grep -Fq 'PAM_OFFICIAL_VERSION_URL' "$ROOT/ports/appmanager/src/launcher.sh"
grep -Fq 'release_routes' "$ROOT/crates/appmanager-service/src/launcher.rs"
grep -Fq 'runtime_metadata_url' "$ROOT/crates/appmanager-service/src/launcher.rs"

echo "appmanager publication sources: PASS"
