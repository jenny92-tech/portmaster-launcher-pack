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
operations_source = (APP / "app_operations.lua").read_text(encoding="utf-8")
assert operations_source.index("model.invalidate_for_plan") < operations_source.index("model.apply_snapshot")
assert "Port App Manager 使用自带 UI 环境，因此仍可运行" not in source
assert "无法启动提权操作助手" not in source
assert "SquashFS 镜像" not in source
assert "kit.info" not in source
assert 'L("PortMaster is not installed. Install it to continue.","未安装 PortMaster，请先安装。")' in source
assert 'L("PortMaster needs repair. Repair it to continue.","PortMaster 需要修复，请先处理。")' in source
assert 'L("Managed by system · Available","系统管理 · 当前可用")' in source
assert "PortMaster 由系统维护。" in source
assert 'L("Checking PortMaster","检查 PortMaster")' in source
assert "正在检查 PortMaster，完成后会自动继续。" in source
assert "return result.status,nil" in source
assert "result.status,result.detail" not in source
assert 'checkbox={label=L("Delete permanently instead of using Trash","直接删除，不放入回收站"),danger=true}' in source
assert 'if checked then for _,item in ipairs(plan) do item.kind="DELETE_MANAGED" end end' in source
assert 'checkbox={label=L("Delete permanently instead of using Trash","直接删除，不放入回收站"),danger=true,checked=true}' not in source
assert 'indeterminate=true' in source
assert 'L("Keep waiting","继续等待")' in source
assert 'cancel=L("Stay","暂不退出")' in source
assert "focusable=false" in source
assert "surface=false" in source
for clear_copy in (
    "当前设备暂不支持安装 PortMaster。",
    "无法确定 PortMaster 安装位置，未进行任何修改。",
    "这台设备尚未实测。确认后可以继续。",
    "PortMaster 尚未支持这台设备。请确认安装位置。",
    "安装未完成。请退出 APP，重新打开后再试。",
    "未配套的启动项和数据目录会默认选中。多个启动项共用同一目录时不会默认选中，请确认后处理。选中内容会移入回收站。",
    "存放菜单里的游戏启动脚本。",
    "Port App Manager 无法启动。请重新安装后再试。",
):
    assert clear_copy in source, clear_copy
for verbose_copy in (
    "当前设备配置未启用 PortMaster 安装",
    "APP Manager 无法安全确定此设备的 PortMaster 安装路径",
    "我已了解此操作会修改 PortMaster 环境",
    "当前设备配置不允许安装 PortMaster",
    "无法使用的安装已清理",
    "正在安全更新文件",
    "普通的孤儿 SH 与孤儿数据目录",
    "受管游戏依赖",
    "这里是 directory/ports",
    "这里是 controlfolder",
    "配置档",
    "请查看 log.txt 后重试",
    "A mismatched binary cannot run",
    "missing .so errors",
    "squashfs",
    "normally the folder of $0",
):
    assert verbose_copy not in source, verbose_copy
for contract in (
    'id="manage:latest"', 'id="manage:check"', 'id="manage:update"',
    'L("Update now","立即更新")', 'L("Up to date","已是最新版")',
    'L("Reinstall","重新安装")', 'model.native.start,"update-check"',
    'local actions={', 'sidebar_title=L("Maintenance","维护")',
    'sidebar=actions', 'row_layout={mode="grid",columns=2}',
    'id="manage:manufacturer"', 'id="manage:submodel"',
    'id="manage:system-name"', 'id="manage:system-version"',
    'for _,item in ipairs(self.confirm_plan)', 'item.kind=="INSTALL_PORTMASTER"',
    'env.install_transaction_exists', 'env.portmaster_active_exists',
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
appmanager = {
    snapshot=function() return APP_SNAPSHOT end,
    start=function(kind)
        if kind=="config-refresh" then error("offline fixture") end
        return 1
    end,
    poll=function() return nil end,
    cancel=function() end,
}
'''


def run_case(health: str, pending: bool = False, management: str = "app"):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        for name in ("scripts", "games", "images", "libs", "state", "trash"):
            (root / name).mkdir()
        env_path = root / "state" / "env.json"
        pending_path = root / "state" / "pending-install.tsv"
        if pending:
            pending_path.write_text("pending\n", encoding="utf-8")
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
                    "portmaster_management": management,
                    "portmaster_version": "2026.07" if health == "healthy" else "",
                    "device_name": "MiniLoong Pocket One",
                    "device_manufacturer": "MiniLoong",
                    "device_submodel": "Pocket One",
                    "system_name": "LoongOS",
                    "system_version": "1.0",
                    "device_class": "tested",
                    "device_arch": "aarch64",
                    "size_cache_ready": False,
                    "pending_install_exists": pending,
                    "install_transaction_exists": False,
                    "portmaster_active_exists": False,
                    "operation_active_exists": False,
                    "ignore_dirs": ["PortMaster", "images", "jenny92-appmanager"],
                    "ignore_scripts": ["PortMaster.sh", "APP Manager.sh", ".port.sh"],
                    "self_port": "jenny92-appmanager",
                }
            ),
            encoding="utf-8",
        )
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().SOURCE = str(APP)
        lua.globals().APP_SNAPSHOT = lua.table_from({
            "env": json.loads(env_path.read_text(encoding="utf-8")),
            "inventory": {"schema": 2, "ports": [], "refcount": {}, "orphan_dirs": [],
                "orphan_images": [], "dead_scripts": [], "trash": [],
                "runtimes": {"need": {}, "facts": []}},
            "sizes": {}, "runtime_metadata": {},
        }, recursive=True)
        lua.execute(LOVE_MOCK)
        lua.execute(f"package.path={str(APP / '?.lua')!r}..';'..{str(KIT / '?.lua')!r}..';'..package.path")
        lua.execute(f"dofile({str(APP / 'main.lua')!r})")
        lua.execute("love.load()")
        return lua


healthy = run_case("healthy")
assert healthy.eval('require("kit").debug_page().title') == "Port App Manager"
guide = healthy.eval('require("kit").debug_guide()')
assert guide["open"]
assert guide["title"] == "欢迎使用 Port App Manager"
assert "Port 游戏维护工具" in guide["message"]
assert guide["confirm"] == "开始使用"
assert guide["callout_count"] == 5
assert guide["step"] == 1
assert guide["target"] == "header"
healthy.execute('require("kit").input("confirm")')
assert healthy.eval('require("kit").debug_guide().step') == 2
healthy.execute('require("kit").input("cancel")')
assert healthy.eval('require("kit").debug_guide().step') == 3
assert healthy.eval('require("kit").debug_guide().target') == "leftovers"
healthy.execute('require("kit").input("confirm"); require("kit").input("confirm"); require("kit").input("confirm")')
assert not healthy.eval('require("kit").debug_guide().open')
assert healthy.eval('require("kit").get_state().onboarding_seen') == "1"
healthy.execute('require("kit").input("up"); require("kit").input("confirm")')
page = healthy.eval('require("kit").debug_page()')
assert page["title"] == "环境管理"
assert page["section_count"] == 1
assert page["row_count"] == 10
assert page["sidebar_count"] == 4
assert healthy.eval('require("kit").debug_navigation().depth') == 1

# Environment Management is a parent page: opening Runtime repair and using
# either the header/cancel action must return to it, not skip back to Home.
healthy.execute(r'''
    local k=require("kit")
    for _=1,4 do
        if k.debug_focus().zone=="sidebar" then break end
        k.input("right")
    end
    assert(k.debug_focus().zone=="sidebar")
    while k.debug_focus().sidebar_i<3 do k.input("down") end
    k.input("confirm")
    assert(k.debug_page().title=="Runtime 修复")
    assert(k.debug_navigation().depth==2)
    k.input("cancel")
    assert(k.debug_page().title=="环境管理")
    assert(k.debug_navigation().depth==1)

    -- The visible top-left Back control uses the same stack.
    while k.debug_focus().zone~="sidebar" do k.input("right") end
    while k.debug_focus().sidebar_i<3 do k.input("down") end
    k.input("confirm")
    k.input("up")
    assert(k.debug_focus().zone=="bar")
    k.input("confirm")
    assert(k.debug_page().title=="环境管理")
    assert(k.debug_navigation().depth==1)
''')

for state, expected_title in (
    ("missing", "需要安装 PortMaster"),
    ("damaged", "修复 PortMaster"),
):
    runtime = run_case(state)
    page = runtime.eval('require("kit").debug_page()')
    assert page["title"] == expected_title, state
    assert page["row_count"] == 3, state
    assert page["sidebar_count"] == 0, state
    assert page["row_kinds"][1] == "textview", state
    layout = runtime.eval('require("kit").debug_layout()')
    assert not layout["has_sidebar"], state
    assert layout["columns"] == 1, state
    focus = runtime.eval('require("kit").debug_focus()')
    assert focus["zone"] == "rows", state
    assert focus["focus_i"] == 2, state
    runtime.execute('require("kit").input("confirm")')
    dialog = runtime.eval('require("kit").debug_dialog()')
    assert dialog["open"], state
    assert dialog["title"] == ("修复 PortMaster" if state == "damaged" else "安装 PortMaster"), state

system_managed = run_case("missing", management="system")
page = system_managed.eval('require("kit").debug_page()')
assert page["title"] == "Port App Manager"
system_managed.execute('require("kit").close_guide(); require("kit").input("up"); require("kit").input("confirm")')
page = system_managed.eval('require("kit").debug_page()')
assert page["title"] == "环境管理"
assert page["row_count"] == 11
assert page["sidebar_count"] == 2
assert page["row_kinds"][11] == "textview"
system_managed.execute('require("kit").input("right"); require("kit").input("confirm")')
assert system_managed.eval('require("kit").debug_page().title') == "Runtime 修复"

pending = run_case("healthy", pending=True)
page = pending.eval('require("kit").debug_page()')
assert page["title"] == "检查 PortMaster"
assert page["row_count"] == 1
assert page["sidebar_count"] == 0
assert page["row_kinds"][1] == "textview"
layout = pending.eval('require("kit").debug_layout()')
assert not layout["has_sidebar"]
assert layout["columns"] == 1
busy = pending.eval('require("kit").debug_busy()')
assert busy["busy"]
assert busy["indeterminate"]
pending.execute('require("kit").input("confirm"); require("kit").input("cancel")')
assert pending.eval('LAST_QUIT == nil')

with tempfile.TemporaryDirectory() as temporary:
    progress_path = Path(temporary) / "progress.tsv"
    healthy.globals().PROGRESS_PATH = str(progress_path)

    progress_path.write_text(
        "1\tdownloading\tPortMaster\t1\t1\t22\t100\t4096\tDownloading verified release assets\n",
        encoding="utf-8",
    )
    healthy.execute(r'''
        local model=require("app_model").new(require("kit"),require("json"),{})
        local progress=model.runtime_progress({phase="downloading",runtime="PortMaster",index=1,count=1,
            current=22,total=100,speed=4096,detail="Downloading verified release assets"})
        assert(progress.stage.zh=="正在下载 PortMaster")
        assert(progress.footer_right.zh=="4.0 KB/秒")
        assert(progress.detail=="")
    ''')

    progress_path.write_text(
        "1\tdownloading\tPortMaster\t1\t1\t78\t100\t0\tUsing local cache\n",
        encoding="utf-8",
    )
    healthy.execute(r'''
        local model=require("app_model").new(require("kit"),require("json"),{})
        local progress=model.runtime_progress({phase="downloading",runtime="PortMaster",index=1,count=1,
            current=78,total=100,speed=0,detail="Using local cache"})
        assert(progress.stage.zh=="正在下载 PortMaster")
        assert(progress.footer_right.zh=="使用缓存")
    ''')

print("appmanager environment UI tests: PASS")
