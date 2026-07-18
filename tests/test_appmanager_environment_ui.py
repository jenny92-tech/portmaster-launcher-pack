#!/usr/bin/env python3
"""Executable startup-state and Environment Management UI contracts."""

import json
import os
from pathlib import Path
import tempfile

ROOT = Path(__file__).resolve().parents[1]
KIT = ROOT / "_kit" / "love"
APP = ROOT / "ports" / "appmanager" / "love"

source = "\n".join(path.read_text(encoding="utf-8") for path in sorted(APP.glob("*.lua")))
for contract in (
    'id="manage:latest"', 'id="manage:check"', 'id="manage:update"',
    'L("Update now","立即更新")', 'L("Up to date","已是最新版")',
    'L("Reinstall","重新安装")', '--check-pm-update-force',
    'local actions={', 'sidebar_title=L("Maintenance","维护")',
    'sidebar=actions', 'row_layout={mode="grid",columns=2}',
    'for _,item in ipairs(self.confirm_plan)', 'item.kind=="INSTALL_PORTMASTER"',
    'file_exists(env.install_transaction)', 'file_exists(env.portmaster_active)',
    'operations.task={kind="active-repair"',
    'L("Cached","使用缓存")', 'L("Downloading…","下载中…")',
):
    assert contract in source, contract

try:
    from lupa import LuaRuntime
except ImportError:
    print("appmanager environment UI tests: SKIP (lupa unavailable)")
    raise SystemExit(0)

LOVE_MOCK = r'''
love = {graphics={}, filesystem={}, event={}}
local font = {
    getHeight=function() return 20 end,
    getWidth=function(_,text) return #tostring(text)*10 end,
    getWrap=function(_,text,limit) return math.min(#tostring(text)*10,limit),{tostring(text)} end,
}
love.graphics.getDimensions=function() return 960,720 end
love.graphics.setBackgroundColor=function() end
love.graphics.newFont=function() return font end
love.graphics.newImage=function() return {getDimensions=function() return 1280,720 end} end
love.graphics.setFont=function() end
love.graphics.setColor=function() end
love.graphics.rectangle=function() end
love.graphics.line=function() end
love.graphics.setLineWidth=function() end
love.graphics.printf=function() end
love.graphics.print=function() end
love.graphics.draw=function() end
love.graphics.push=function() end
love.graphics.pop=function() end
love.graphics.translate=function() end
love.graphics.setScissor=function() end
love.filesystem.getInfo=function() return nil end
love.filesystem.getSource=function() return SOURCE end
love.event.quit=function(code) LAST_QUIT=code end
package.loaded.scan = {
    run=function() return {ports={},refcount={},orphan_dirs={},orphan_images={},dead_scripts={},
        runtimes={have={},need={},missing={}}} end,
    entries=function() return {} end,
    runtime_file_health=function() return "missing",0 end,
    basename=function(path) return path:match("([^/]+)$") or path end,
}
'''


def run_case(health: str):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        for name in ("scripts", "games", "images", "libs", "state", "trash"):
            (root / name).mkdir()
        env_path = root / "state" / "env.json"
        env_path.write_text(
            json.dumps(
                {
                    "controlfolder": str(root / "PortMaster"),
                    "scripts_dir": str(root / "scripts"),
                    "gamedirs_dir": str(root / "games"),
                    "images_dir": str(root / "images"),
                    "libs_dir": str(root / "libs"),
                    "gamedir": str(root),
                    "directory": str(root),
                    "home": str(root),
                    "portmaster_target": str(root / "PortMaster"),
                    "portmaster_health": health,
                    "portmaster_version": "2026.07" if health == "healthy" else "",
                    "device_name": "MiniLoong Pocket One",
                    "device_class": "tested",
                    "device_arch": "aarch64",
                    "plan_file": str(root / "state" / "plan.txt"),
                    "result_file": str(root / "state" / "result.txt"),
                    "progress_file": str(root / "state" / "progress.tsv"),
                    "size_file": str(root / "state" / "sizes.tsv"),
                    "runtime_metadata_file": str(root / "state" / "runtime-metadata.tsv"),
                    "apply_script": "",
                    "ignore_dirs": ["PortMaster", "images", "appmanager"],
                    "ignore_scripts": ["PortMaster.sh", "APP Manager.sh", ".port.sh"],
                    "self_port": "appmanager",
                }
            ),
            encoding="utf-8",
        )
        previous = os.environ.get("PAM_ENV")
        os.environ["PAM_ENV"] = str(env_path)
        try:
            lua = LuaRuntime(unpack_returned_tuples=True)
            lua.globals().SOURCE = str(APP)
            lua.execute(LOVE_MOCK)
            lua.execute(f"package.path={str(APP / '?.lua')!r}..';'..{str(KIT / '?.lua')!r}..';'..package.path")
            lua.execute(f"dofile({str(APP / 'main.lua')!r})")
            lua.execute("love.load()")
            return lua
        finally:
            if previous is None:
                os.environ.pop("PAM_ENV", None)
            else:
                os.environ["PAM_ENV"] = previous


healthy = run_case("healthy")
assert healthy.eval('require("kit").debug_page().title') == "Port App Manager"
healthy.execute('require("kit").input("up"); require("kit").input("confirm")')
page = healthy.eval('require("kit").debug_page()')
assert page["title"] == "环境管理"
assert page["section_count"] == 1
assert page["row_count"] == 6

for state in ("missing", "damaged"):
    runtime = run_case(state)
    page = runtime.eval('require("kit").debug_page()')
    assert page["title"] == "需要安装 PortMaster", state
    assert page["row_count"] == 3, state

with tempfile.TemporaryDirectory() as temporary:
    progress_path = Path(temporary) / "progress.tsv"
    healthy.globals().PROGRESS_PATH = str(progress_path)

    progress_path.write_text(
        "1\tdownloading\tPortMaster\t1\t1\t22\t100\t4096\tDownloading verified release assets\n",
        encoding="utf-8",
    )
    healthy.execute(r'''
        local model=require("app_model").new(require("kit"),require("json"),require("scan"))
        model.env.progress_file=PROGRESS_PATH
        local progress=model.runtime_progress()
        assert(progress.stage.zh=="正在下载 PortMaster")
        assert(progress.footer_right.zh=="4.0 KB/秒")
        assert(progress.detail=="")
    ''')

    progress_path.write_text(
        "1\tdownloading\tPortMaster\t1\t1\t78\t100\t0\tUsing local cache\n",
        encoding="utf-8",
    )
    healthy.execute(r'''
        local model=require("app_model").new(require("kit"),require("json"),require("scan"))
        model.env.progress_file=PROGRESS_PATH
        local progress=model.runtime_progress()
        assert(progress.stage.zh=="正在下载 PortMaster")
        assert(progress.footer_right.zh=="使用缓存")
    ''')

print("appmanager environment UI tests: PASS")
