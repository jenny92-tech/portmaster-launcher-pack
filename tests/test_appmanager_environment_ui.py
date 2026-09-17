#!/usr/bin/env python3
# INPUT:  APP Manager Lua 模块、共享 kit、lupa、模拟环境与库存快照
# OUTPUT: 启动状态、环境管理与交互流程的可执行契约断言结果
# POS:    APP Manager 界面能力门禁、任务反馈和环境页面的回归测试
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
assert operations_source.index("model.apply_snapshot") < operations_source.index("page_builders.reset_selection")
assert "model.invalidate_all()" in operations_source
assert 'L("Reason: ","原因：")..reason' in operations_source
assert "Port App Manager 使用自带 UI 环境，因此仍可运行" not in source
assert "无法启动提权操作助手" not in source
assert "SquashFS 镜像" not in source
assert "kit.info" not in source
assert 'L("The PortMaster directory was not found. Install it to manage Port games.","未找到 PortMaster 目录，请安装后再管理 Port 游戏。")' in source
assert 'L("PortMaster needs attention. See Environment Management.","PortMaster 需要注意，请查看环境管理。")' in source
assert 'L("Managed by system · Available","系统管理 · 当前可用")' in source
assert "PortMaster 由系统维护。" in source
assert 'model.native.start,"config-refresh-if-newer"' in source
assert 'model.native.start,"initial-snapshot"' in source
assert "if initial_task or operations.config_restart_pending then return 0.1 end" in source
assert 'kit.set_busy(true,L("Preparing device information' not in source
assert 'L("Device support updated","设备适配已更新")' in source
assert 'value.status~="progress" and value.status~="complete" and value.status~="error"' in source
assert 'checkbox={label=L("Delete permanently instead of using Trash","直接删除，不放入回收站"),' in source
assert 'checked=false,danger=true}' in source
assert 'if checked then for _,item in ipairs(plan) do item.kind="DELETE_MANAGED" end end' in source
assert 'action_kind="RESTORE_REPLACE"' in source
assert 'replace_existing=replace_existing==true' in source
assert 'L("Replace and restore","覆盖并还原")' in source
assert '"覆盖同名 APP 或游戏数据目录"' in source
assert 'model.native.start,"inventory-refresh"' in source
assert 'model.native.start,"update-check-if-stale"' in source
assert "operations.background_task=" in source
assert "operations.finish_background_update(data.update)" in source
assert "operations.request_forced_update()" in source
assert 'kind="update-check-wait"' not in source
assert 'model.native.start,"update-check",{}' in source
assert "function self.apply_update_result(update)" in source
assert 'model.native.start,"scan-sizes"' not in source
assert 'L("Rescan","重新扫描")' in source
assert 'checkbox={label=L("Delete permanently instead of using Trash","直接删除，不放入回收站"),danger=true,checked=true}' not in source
assert "请继续等待。" in source
assert 'cancel=L("Stay","暂不退出")' in source
assert "focusable=false" in source
assert "surface=false" in source
for clear_copy in (
    "当前设备暂不支持安装 PortMaster。",
    "无法确定 PortMaster 安装位置，未进行任何修改。",
    "这台设备尚未实测。确认后可以继续。",
    "PortMaster 尚未支持这台设备。请确认安装位置。",
    "自动勾选的是确认没用的内容，拿不准的一律不勾。勾选后移入回收站，可以反悔。",
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
    "未配套的启动项和数据目录会默认选中。多个启动项共用同一目录时不会默认选中，请确认后处理。选中内容会移入回收站。",
    "应用会退出，让游戏接管屏幕",
    "normally the folder of $0",
):
    assert verbose_copy not in source, verbose_copy
for contract in (
    'id="manage:latest"', 'id="manage:check"', 'id="manage:update"',
    'L("Update now","立即更新")', 'L("Up to date","已是最新版")',
    'L("Reinstall","重新安装")', 'model.native.start,"update-check"',
    'local actions={', 'sidebar_title=L("Maintenance","维护")',
    'sidebar=actions', 'row_layout={mode="grid",columns=2}',
    'id="manage:sh-dir"', 'id="manage:data-dir"',
    'info("device:name"', 'info("device:manufacturer"',
    'info("device:submodel"', 'info("device:system"',
    'info("device:system-version"',
    'for _,item in ipairs(self.confirm_plan)', 'item.kind=="INSTALL_PORTMASTER"',
    'L("Cached","使用缓存")', 'L("Downloading…","下载中…")',
):
    assert contract in source, contract

try:
    from lupa import LuaRuntime
except ImportError:
    if os.environ.get("PAM_REQUIRE_LUPA") == "1":
        raise SystemExit("appmanager environment UI tests: FAIL (lupa is required)")
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
    request=function(method,payload)
        if method=="snapshot" then return {ok=true,value=APP_SNAPSHOT} end
        if method=="start" then
            LAST_START_KIND=payload.kind
            LAST_START_ACTIONS=payload.actions
            LAST_START_PASSWORD=payload.actions and payload.actions[1] and payload.actions[1].password
            LAST_START_REVISION=payload.revision
            if payload.kind=="config-refresh-if-newer" or payload.kind=="update-check-if-stale" then
                return {ok=false,error={code="offline",message="offline fixture"}}
            end
            TASK_ID=(TASK_ID or 0)+1
            if payload.kind=="initial-snapshot" then
                POLL_EVENT={task_id=TASK_ID,kind="initial-snapshot",status="complete",
                    data={snapshot=APP_SNAPSHOT}}
            end
            return {ok=true,value=TASK_ID}
        end
        if method=="poll" then
            local event=POLL_EVENT
            if event then POLL_EVENT=nil; return {ok=true,value=event} end
            return {ok=true}
        end
        if method=="cancel" then return {ok=true,value=true} end
        if method=="web-set" then
            LAST_WEB_SET=payload
            return {ok=true,value={port=8080,code="123456"}}
        end
        if method=="run" then LAST_RUN_PATH=payload; return {ok=true,value=true} end
        return {ok=false,error={code="unsupported_method",message="unsupported method"}}
    end,
}
'''


def run_case(
    health: str,
    management: str = "app",
    extra: dict | None = None,
    inventory: dict | None = None,
    persisted_state: dict[str, str] | None = None,
):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        for name in ("scripts", "games", "images", "libs", "state", "trash"):
            (root / name).mkdir()
        env_path = root / "state" / "env.json"
        if persisted_state:
            (root / "state.txt").write_text(
                "".join(f"{key}={value}\n" for key, value in persisted_state.items()),
                encoding="utf-8",
            )
        env = {
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
            "target_confirmed": "1",
            "device_name": "MiniLoong Pocket One",
            "device_manufacturer": "MiniLoong",
            "device_submodel": "Pocket One",
            "system_name": "LoongOS",
            "system_version": "1.0",
            "device_class": "tested",
            "device_arch": "aarch64",
            "ignore_dirs": ["PortMaster", "images", "jenny92-appmanager"],
            "protected_app_names": ["PortMaster", "images", "jenny92-appmanager"],
            "ignore_scripts": ["PortMaster.sh", "APP Manager.sh", ".port.sh"],
            "self_port": "jenny92-appmanager",
            # The native snapshot is fail-closed: every feature exercised by
            # this UI fixture must be enabled explicitly.
            "capability_inventory_ports": True,
            "capability_manage_ports": True,
            "capability_install_ports": True,
            "capability_inventory_apps": True,
            "capability_manage_apps": True,
            "capability_install_apps": True,
            "capability_manage_portmaster": True,
            "capability_install_portmaster": True,
            "capability_update_portmaster": True,
            "capability_repair_runtimes": True,
            "capability_trash": True,
            "capability_leftovers": True,
            "capability_cleanup_appledouble": True,
        }
        if extra:
            env.update(extra)
        env_path.write_text(json.dumps(env), encoding="utf-8")
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().SOURCE = str(root)  # keep persisted state.txt out of the repo
        lua.globals().POLL_EVENT = None
        lua.globals().TASK_ID = 0
        lua.globals().APP_SNAPSHOT = lua.table_from({
            "env": env,
            "inventory": inventory or {"schema": 1, "ports": [], "data_refcount": {}, "orphan_dirs": [],
                "orphan_images": [], "dead_scripts": [], "trash": [],
                "runtimes": {"need": {}, "facts": []}},
            "revision": "a" * 64, "sizes": {}, "runtime_metadata": {},
        }, recursive=True)
        lua.execute(LOVE_MOCK)
        lua.execute(f"package.path={str(APP / '?.lua')!r}..';'..{str(KIT / '?.lua')!r}..';'..package.path")
        lua.execute(f"dofile({str(APP / 'main.lua')!r})")
        lua.execute("love.load()")
        lua.execute("love.update(0.2)")
        return lua


def goto_sidebar_tool(lua, label):
    # Home launcher: the five management tools live in the sidebar. Enter it,
    # rewind to the top, then walk down to the target tool.
    import json as _json
    target = _json.dumps(label, ensure_ascii=False)
    lua.execute((
        "local k=require(\"kit\")\n"
        "for _=1,6 do\n"
        "    if k.debug_focus().zone==\"sidebar\" then break end\n"
        "    k.input(\"right\")\n"
        "end\n"
        "while k.debug_focus().sidebar_i>1 do k.input(\"up\") end\n"
        "for _=1,8 do\n"
        "    local p=k.debug_page()\n"
        "    if p.sidebar_labels[k.debug_focus().sidebar_i]==" + target + " then break end\n"
        "    k.input(\"down\")\n"
        "end\n"
        "k.input(\"confirm\")\n"
    ))



def goto_manage(lua):
    goto_sidebar_tool(lua, "PortMaster 管理")
healthy = run_case("healthy")
assert healthy.eval('require("kit").debug_page().title') == "Port App Manager"
guide = healthy.eval('require("kit").debug_guide()')
assert guide["open"]
assert guide["title"] == "欢迎使用 Port App Manager"
assert "Port 游戏维护工具" in guide["message"]
assert guide["confirm"] == "开始使用"
assert guide["callout_count"] == 6

remote_restored = run_case(
    "healthy",
    persisted_state={"ui_lang": "zh", "onboarding_seen": "1", "web_enabled": "1"},
)
assert remote_restored.globals().LAST_WEB_SET is True
assert remote_restored.eval('require("kit").get_state().web_enabled') == "1"
remote_restored.execute(r'''
    local k=require("kit")
    k.close_guide(); k.close_dialog()
    local page=k.debug_page()
    local found=0
    local expected
    for i,label in ipairs(page.row_labels) do
        assert(label~="配对码")
        if label=="远程管理，用电脑浏览器打开" then
            expected=page.row_values[i]
            assert(expected:match(":8080\n配对码 123456$"))
            assert(page.row_max_lines[i]>=2)
            found=found+1
        end
    end
    assert(found==1)
    -- Unlike the default mock, preserve explicit newlines during wrapping.
    love.graphics.newFont().getWrap=function(_,text,limit)
        local lines={}
        for line in (text.."\n"):gmatch("(.-)\n") do lines[#lines+1]=line end
        return limit,lines
    end
    for _,size in ipairs({{640,480},{720,720},{1280,720}}) do
        love.graphics.getDimensions=function() return size[1],size[2] end
        local drawn=false
        love.graphics.printf=function(text,x,y,width)
            if text==expected then assert(width>=60); drawn=true end
        end
        love.draw()
        assert(drawn,"complete pairing code must be drawn on small screens")
    end
''')

remote_toggle = run_case(
    "healthy",
    persisted_state={"ui_lang": "zh", "onboarding_seen": "1", "web_enabled": "0"},
)
remote_toggle.execute(r'''
    local k=require("kit")
    k.input("up")
    assert(k.debug_focus().zone=="bar" and k.debug_focus().bar_i==1)
    k.input("confirm")
    assert(LAST_WEB_SET==true)
    assert(k.get_state().web_enabled=="1" and k.get_state().web_port=="8080")
    k.input("confirm")
    assert(LAST_WEB_SET==false)
    assert(k.get_state().web_enabled=="0" and k.get_state().web_port==nil)
''')
assert guide["step"] == 1
assert guide["target"] == "home:games"
healthy.execute('require("kit").input("confirm")')
assert healthy.eval('require("kit").debug_guide().step') == 2
healthy.execute('require("kit").input("cancel")')
assert healthy.eval('require("kit").debug_guide().step') == 3
assert healthy.eval('require("kit").debug_guide().target') == "home:junk"
healthy.execute('require("kit").input("confirm"); require("kit").input("confirm"); require("kit").input("confirm")')
guide = healthy.eval('require("kit").debug_guide()')
assert guide["step"] == 6
assert guide["callout_title"] == "开发与反馈"
assert "QQ 群 1047158975" in guide["body"]
assert guide["body"].endswith("/log.txt")
healthy.execute('require("kit").input("confirm")')
assert not healthy.eval('require("kit").debug_guide().open')
assert healthy.eval('require("kit").get_state().onboarding_seen') == "1"
# Home is the feature matrix; PortMaster manager is the last card.
goto_manage(healthy)
page = healthy.eval('require("kit").debug_page()')
assert page["title"] == "环境管理"
assert page["section_count"] == 1
assert page["row_count"] == 8
assert page["sidebar_count"] == 3
# PortMaster support is stated explicitly on the Environment Management page.
assert page["row_labels"][2] == "PortMaster 支持"
assert page["row_values"][2] == "支持"
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
    while k.debug_focus().sidebar_i<2 do k.input("down") end
    k.input("confirm")
    assert(k.debug_page().title=="Runtime 修复")
    assert(k.debug_navigation().depth==2)
    k.input("cancel")
    assert(k.debug_page().title=="环境管理")
    assert(k.debug_navigation().depth==1)

    -- The visible top-left Back control uses the same stack.
    while k.debug_focus().zone~="sidebar" do k.input("right") end
    while k.debug_focus().sidebar_i<2 do k.input("down") end
    k.input("confirm")
    k.input("up")
    assert(k.debug_focus().zone=="bar")
    k.input("confirm")
    assert(k.debug_page().title=="环境管理")
    assert(k.debug_navigation().depth==1)
''')

missing = run_case("missing")
missing.execute('require("kit").close_guide()')  # first-run guide overlays input
page = missing.eval('require("kit").debug_page()')
# Game management no longer depends on a working PortMaster core: the feature
# matrix home opens with an install banner instead of a blocking repair gate.
assert page["title"] == "Port App Manager"
assert page["row_count"] == 2  # banner + install (web switch lives in the header)
assert page["row_kinds"][1] == "textview"  # banner is the first row (web switch is in the header)
missing_labels = [page["row_labels"][i] for i in range(1, page["row_count"] + 1)]
assert "PortMaster 未安装" in missing_labels
assert "安装 PortMaster" in missing_labels
focus = missing.eval('require("kit").debug_focus()')
assert focus["zone"] == "rows"
assert focus["focus_i"] == 2  # the install banner action
missing.execute('require("kit").input("confirm")')
dialog = missing.eval('require("kit").debug_dialog()')
assert dialog["open"]
assert dialog["title"] == "安装 PortMaster"
# The Runtime page explains instead of failing when PortMaster is missing.
missing.execute('require("kit").close_dialog()')
goto_sidebar_tool(missing, "Port Runtime")
page = missing.eval('require("kit").debug_page()')
assert page["title"] == "Runtime 修复"
assert page["row_count"] == 3
assert page["row_kinds"][1] == "textview"  # Runtime page has no web switch

# A damaged PortMaster keeps game management usable: the app opens Home,
# warns, and Environment Management offers Repair as its primary action.
damaged = run_case("damaged")
page = damaged.eval('require("kit").debug_page()')
assert page["title"] == "Port App Manager"
damaged.execute('require("kit").close_guide()')
goto_manage(damaged)
page = damaged.eval('require("kit").debug_page()')
assert page["title"] == "环境管理"
assert page["row_values"][2] == "支持"
damaged_sidebar = [page["sidebar_labels"][i] for i in range(1, page["sidebar_count"] + 1)]
assert "修复 PortMaster" in damaged_sidebar

# Devices whose config forbids installing PortMaster say so up front.
disabled = run_case("healthy", extra={"capability_install_portmaster": False})
disabled.execute('require("kit").close_guide()')
goto_manage(disabled)
page = disabled.eval('require("kit").debug_page()')
assert page["title"] == "环境管理"
assert page["row_values"][2] == "配置未启用"
assert page["row_count"] == 9
disabled_values = [page["row_values"][i] for i in range(1, page["row_count"] + 1)]
disabled_sidebar = [page["sidebar_labels"][i] for i in range(1, page["sidebar_count"] + 1)]
assert "当前设备暂不支持安装 PortMaster。" in disabled_values
assert "检查更新" not in disabled_sidebar
assert "安装 PortMaster" not in disabled_sidebar

system_managed = run_case("missing", management="system")
page = system_managed.eval('require("kit").debug_page()')
assert page["title"] == "Port App Manager"
# Home has no header action any more; the system-managed badge now lives on
# the PortMaster manager feature card.
system_managed.execute('require("kit").close_guide()')
goto_manage(system_managed)
page = system_managed.eval('require("kit").debug_page()')
assert page["title"] == "环境管理"
assert page["row_count"] == 9
assert page["sidebar_count"] == 2
assert page["row_kinds"][9] == "textview"
assert page["row_values"][2] == "由系统管理"
system_managed.execute(r'''
    local k=require("kit")
    for _=1,6 do
        if k.debug_focus().zone=="sidebar" then break end
        k.input("right")
    end
    assert(k.debug_focus().zone=="sidebar")
    k.input("confirm")
''')
assert system_managed.eval('require("kit").debug_page().title') == "Runtime 修复"

# Exercise the shipped TrimUI policy, not just a synthetic management flag.
trimui_config = json.loads((ROOT / "config/platforms/trimui.json").read_text(encoding="utf-8"))
root_config = json.loads((ROOT / "config/config.json").read_text(encoding="utf-8"))
trimui_env = {"capability_" + key: value for key, value in trimui_config["capabilities"].items()}
trimui_env["portmaster_release_install_allowed"] = root_config["sources"]["release_routes"][
    trimui_config["source_route"]
]["install_allowed"]
for health in ("missing", "damaged", "healthy"):
    trimui = run_case(health, management=trimui_config["frontend"]["management"], extra=trimui_env)
    assert trimui.eval('require("kit").debug_page().title') == "Port App Manager"
    assert trimui.eval("LAST_START_KIND") != "update-check-if-stale"
    trimui.execute('require("kit").close_guide()')
    goto_manage(trimui)
    page = trimui.eval('require("kit").debug_page()')
    assert page["row_values"][2] == "由系统管理"
    assert page["sidebar_count"] == 2  # Only Runtime repair and environment details.
    assert page["sidebar_labels"][1].startswith("Runtime 修复")
    assert page["sidebar_labels"][2] == "环境详情"

# Support is stated by support model: our own build (MiniLoong), the official
# release, and unknown devices that fell back to the generic profile.
custom = run_case("healthy", extra={"portmaster_release_channel": "miniloong-custom", "device_class": "tested"})
custom.execute('require("kit").close_guide()')
goto_manage(custom)
page = custom.eval('require("kit").debug_page()')
assert page["row_values"][2] == "定制版（Jenny92）"

official = run_case("healthy", extra={"portmaster_release_channel": "official", "device_class": "tested"})
official.execute('require("kit").close_guide()')
goto_manage(official)
page = official.eval('require("kit").debug_page()')
assert page["row_values"][2] == "官方支持"

generic = run_case("healthy", extra={"portmaster_release_channel": "official", "device_class": "unsupported-known"})
generic.execute('require("kit").close_guide()')
goto_manage(generic)
page = generic.eval('require("kit").debug_page()')
assert page["row_values"][2] == "未知设备（需确认）"
generic_values = [page["row_values"][i] for i in range(1, page["row_count"] + 1)]
assert any("安装完成会自动检查能否正常使用" in value for value in generic_values)

healthy.execute(r'''
    local native={snapshot=function() return {env={
        portmaster_health="healthy", portmaster_management="app",
        target_confirmed="1", portmaster_target="/mnt/PortMaster",
        portmaster_release_install_allowed=true,
        capability_manage_portmaster=true, capability_install_portmaster=true,
        capability_update_portmaster=true,
    },inventory={},runtime_metadata={}} end,
        start=function() return 1 end,poll=function() return nil end,cancel=function() return true end}
    local model=require("app_model").new(require("kit"),native,{})
    local progress=model.runtime_progress({phase="downloading",runtime="PortMaster",index=1,count=1,
        current=22,total=100,speed=4096,detail="Downloading verified release assets"})
    assert(progress.stage.zh=="正在下载 PortMaster")
    assert(progress.footer_right.zh=="4.0 KB/秒")
    assert(progress.detail=="")
''')

healthy.execute(r'''
    local native={snapshot=function() return {env={
        portmaster_health="healthy", portmaster_management="app",
        target_confirmed="1", portmaster_target="/mnt/PortMaster",
        portmaster_release_install_allowed=true,
        capability_manage_portmaster=true, capability_install_portmaster=true,
        capability_update_portmaster=true,
    },inventory={},runtime_metadata={}} end,
        start=function() return 1 end,poll=function() return nil end,cancel=function() return true end}
    local model=require("app_model").new(require("kit"),native,{})
    local progress=model.runtime_progress({phase="downloading",runtime="PortMaster",index=1,count=1,
        current=78,total=100,speed=0,detail="Using local cache"})
    assert(progress.stage.zh=="正在下载 PortMaster")
    assert(progress.footer_right.zh=="使用缓存")
''')

# ── Single-threaded waiting operations show a blocking spinner ────────────────
# The primary action on a healthy-but-unchecked environment is Check for updates,
# and it must block input behind an indeterminate busy overlay instead of letting
# the user start other operations that would then fail.
check = run_case("healthy")
check.execute('require("kit").close_guide()')
goto_manage(check)
page = check.eval('require("kit").debug_page()')
check_sidebar = [page["sidebar_labels"][i] for i in range(1, page["sidebar_count"] + 1)]
assert "检查更新" in check_sidebar
assert "重新安装" not in check_sidebar
check.execute(r'''
    local k=require("kit")
    for _=1,6 do
        if k.debug_focus().zone=="sidebar" then break end
        k.input("right")
    end
    k.input("confirm")
''')
busy = check.eval('require("kit").debug_busy()')
assert busy["busy"]
assert busy["message"] == "正在检查更新……"
assert busy["indeterminate"]
# Non-cancellable tasks (update check) show no button and swallow ALL input
# (confirm and Back/Escape): exiting is a deliberate Home-Quit action only.
check.execute('require("kit").input("confirm")')
assert check.eval('require("kit").debug_busy().busy')
assert not check.eval('require("kit").debug_dialog().open')
check.execute('require("kit").input("cancel")')
assert check.eval('require("kit").debug_busy().busy')
assert not check.eval('require("kit").debug_dialog().open')
# Completion clears the overlay and refreshes the page to Up to date.
# The background stale-check already claimed id 1; the foreground check got the
# latest id, so target exactly that task.
check.globals().POLL_EVENT = check.table_from({
    "task_id": check.globals().TASK_ID, "kind": "update-check", "status": "complete",
    "data": {"update": {"update_status": "ok", "portmaster_latest": "2026.07",
        "update_checked": 1789000000}},
}, recursive=True)
check.execute('require("kit").update(0.2)')
assert not check.eval('require("kit").debug_busy().busy')
page = check.eval('require("kit").debug_page()')
assert page["title"] == "环境管理"
post_sidebar = [page["sidebar_labels"][i] for i in range(1, page["sidebar_count"] + 1)]
assert "已是最新版" in post_sidebar

# A manual check requested while the automatic background check is running must
# show the spinner immediately and defer the real check until the lane frees up.
healthy.execute(r'''
    local k=require("kit")
    local native={snapshot=function() return {env={
        portmaster_health="healthy", portmaster_management="app",
        target_confirmed="1", portmaster_target="/mnt/PortMaster",
        portmaster_release_install_allowed=true,
        capability_manage_portmaster=true, capability_install_portmaster=true,
        capability_update_portmaster=true,
    },inventory={},runtime_metadata={}} end,
        start=function() return 1 end,poll=function() return nil end,cancel=function() return true end}
    local model=require("app_model").new(k,native,{})
    model.load_env()
    local operations=require("app_operations").new(model)
    local pages=require("app_pages").new(model,operations)
    local environment=require("app_environment").new(model,operations,pages)
    pages.bind_environment(environment)
    operations.bind(pages,environment)
    operations.background_task={id=9,kind="update-check-background",elapsed=0,poll=0}
    environment.start_update_check()
    assert(k.debug_busy().busy)
    assert(k.debug_busy().indeterminate)
    assert(operations.forced_update_pending)
    -- The lane frees: the forced check now starts and keeps the overlay.
    operations.finish_background_update({})
    assert(k.debug_busy().busy)
    assert(operations.task.kind=="update-check")
''')

# ── Environment Details acts as a readiness report ───────────────────────────

def open_env(lua):
    lua.execute('require("kit").close_guide()')
    goto_manage(lua)
    lua.execute(r'''
        local k=require("kit")
        for _=1,6 do
            if k.debug_focus().zone=="sidebar" then break end
            k.input("right")
        end
        for _=1,6 do
            if k.debug_focus().zone=="sidebar" and k.debug_focus().sidebar_i>=3 then break end
            k.input("down")
        end
        k.input("confirm")
    ''')

env_page = run_case("healthy")
open_env(env_page)
page = env_page.eval('require("kit").debug_page()')
assert page["title"] == "环境详情"
assert page["section_labels"][1] == "PortMaster 可用性"
env_rows = {page["row_labels"][i]: page["row_values"][i] for i in range(1, page["row_count"] + 1)}
assert env_rows["设备识别"] == "MiniLoong Pocket One"
assert env_rows["支持方式"] == "支持"
assert env_rows["能否安装"] == "可以安装"
assert env_rows["系统运行库"] == "无特殊要求"
assert env_rows["Python 环境"] == "可用"
assert env_rows["PortMaster 状态"] == "正常 · 2026.07"
assert "可以安装 PortMaster" not in env_rows["结论"]
assert env_rows["结论"] == "PortMaster 已安装且可正常使用。"

# Library pre-check: a generic device missing GLES/SDL2 is told it cannot run.
gen = run_case("healthy", extra={
    "portmaster_release_channel": "official",
    "device_class": "unsupported-known",
    "library_groups": [
        {"name": "gles", "ok": False, "selected": None, "missing": ["libGLESv2.so"]},
        {"name": "system_sdl2", "ok": True, "selected": "/usr/lib", "missing": []},
    ],
})
open_env(gen)
page = gen.eval('require("kit").debug_page()')
gen_rows = {page["row_labels"][i]: page["row_values"][i] for i in range(1, page["row_count"] + 1)}
assert gen_rows["支持方式"] == "未知设备（需确认）"
assert gen_rows["能否安装"] == "可安装（需确认安装位置）"
assert gen_rows["系统运行库"] == "缺少：libGLESv2.so"
assert "未检测到部分系统运行库，可能无法运行" in gen_rows["结论"]

# Library pre-check: all groups ready shows the green Ready badge.
ready = run_case("healthy", extra={
    "library_groups": [
        {"name": "gles", "ok": True, "selected": "/usr/lib", "missing": []},
        {"name": "sdl2", "ok": True, "selected": "/usr/lib", "missing": []},
    ],
})
open_env(ready)
page = ready.eval('require("kit").debug_page()')
ready_rows = {page["row_labels"][i]: page["row_values"][i] for i in range(1, page["row_count"] + 1)}
assert ready_rows["系统运行库"] == "就绪：gles · sdl2"

# ── Startup prompting is tiered: only a certainly-broken core nags ───────────
severe = run_case("damaged", extra={
    "portmaster_health_checks": [
        {"kind": "required_file", "passed": False},
        {"kind": "one_of_files", "passed": True},
        {"kind": "archive_or_nonempty_directory", "passed": True},
    ],
})
assert severe.eval('require("kit").debug_toast().open')
assert severe.eval('require("kit").debug_toast().kind') == "warning"
assert severe.eval('require("kit").debug_toast().message') == "PortMaster 需要注意，请查看环境管理。"
# The repair badge now lives on the PortMaster manager tool in the Home sidebar.
home_side = [severe.eval(f'require("kit").debug_page().sidebar_labels[{i}]') for i in range(1, severe.eval('require("kit").debug_page().sidebar_count') + 1)]
assert "PortMaster 管理" in home_side

# A damaged core with only soft issues (pylibs) must stay quiet at startup:
# PortMaster may still happen to work, so do not nag.
soft = run_case("damaged", extra={
    "portmaster_health_checks": [
        {"kind": "required_file", "passed": True},
        {"kind": "one_of_files", "passed": True},
        {"kind": "archive_or_nonempty_directory", "passed": False},
    ],
})
assert not soft.eval('require("kit").debug_toast().open')

# ── Official compatibility and custom-build rows on the details page ────────
official_rows = run_case("healthy", extra={"portmaster_release_channel": "miniloong-custom", "device_class": "tested"})
open_env(official_rows)
page = official_rows.eval('require("kit").debug_page()')
compat = {page["row_labels"][i]: page["row_values"][i] for i in range(1, page["row_count"] + 1)}
assert compat["官方兼容性"] == "官方不兼容（使用定制版）"  # MiniLoong ships our own build
assert compat["是否魔改"] == "定制版（miniloong-custom）"

# ── Game management works with a missing core when games are present ────────
with_inventory = run_case("missing", inventory={
    "schema": 1,
    "ports": [{
        "script": "hollow-knight.sh",
        "path": "/Roms/ports/hollow-knight.sh",
        "dir": "hollow-knight",
        "data_path": "/Roms/ports/gamedata/hollow-knight",
        "claimed_dir": "hollow-knight",
        "dir_exists": True,
        "images": [{"name": "hollow-knight.png", "path": "/Roms/ports/images/hollow-knight.png"}],
        "runtime": "love_11.5", "runtimes": [],
    }],
    "data_refcount": {"/Roms/ports/gamedata/hollow-knight": 1}, "orphan_dirs": [], "orphan_images": [],
    "dead_scripts": [], "trash": [],
    "runtimes": {"need": {"love_11.5": ["hollow-knight.sh"]}, "facts": []},
})
with_inventory.execute('require("kit").close_guide()')
page = with_inventory.eval('require("kit").debug_page()')
home_labels = [page["row_labels"][i] for i in range(1, page["row_count"] + 1)]
assert "PortMaster 未安装" in home_labels  # banner stays on the launcher home
# The game list lives in the Uninstall manager tool (sidebar).
goto_sidebar_tool(with_inventory, "卸载管理")
page = with_inventory.eval('require("kit").debug_page()')
assert page["title"] == "卸载管理"
with_labels = [page["row_labels"][i] for i in range(1, page["row_count"] + 1)]
assert "hollow-knight" in with_labels  # Only the .sh suffix is hidden

# ── Generic devices never pre-select leftover folders (best-effort paths) ─────
junk_inventory = {
    "schema": 1,
    "ports": [],
    "data_refcount": {},
    "orphan_dirs": [{"root": "game-dirs", "name": "other-system-roms",
        "path": "/Roms/exact-orphan", "kind": "directory"}],
    "orphan_images": [],
    "dead_scripts": [{"script": "Dead.sh", "path": "/Roms/exact-dead.sh",
        "missing_dir": "missing-data"}],
    "trash": [],
    "entries": [{"root": "game-dirs", "name": "other-system-roms",
        "path": "/Roms/wrong-name-search-result", "kind": "directory"},
        {"root": "scripts", "name": "Dead.sh",
        "path": "/Roms/wrong-dead-search-result.sh", "kind": "file"}],
    "runtimes": {"need": {}, "facts": []},
}
generic_junk = run_case("healthy", extra={"portmaster_release_channel": "official", "device_class": "unsupported-known"}, inventory=junk_inventory)
generic_junk.execute('require("kit").close_guide()')
goto_sidebar_tool(generic_junk, "垃圾清理")
page = generic_junk.eval('require("kit").debug_page()')
assert page["title"] == "残留清理"
generic_junk_labels = [page["row_labels"][i] for i in range(1, page["row_count"] + 1)]
assert "通用布局提醒" in generic_junk_labels
assert "other-system-roms/" in generic_junk_labels
generic_junk_sidebar = [page["sidebar_labels"][i] for i in range(1, page["sidebar_count"] + 1)]
assert any(label.startswith("移入回收站 (0)") for label in generic_junk_sidebar)  # nothing pre-selected

# The same leftover on a known platform stays pre-selected and un-warned.
known_junk = run_case("healthy", inventory=junk_inventory)
known_junk.execute('require("kit").close_guide()')
goto_sidebar_tool(known_junk, "垃圾清理")
page = known_junk.eval('require("kit").debug_page()')
known_junk_labels = [page["row_labels"][i] for i in range(1, page["row_count"] + 1)]
assert "通用布局提醒" not in known_junk_labels
known_junk_sidebar = [page["sidebar_labels"][i] for i in range(1, page["sidebar_count"] + 1)]
assert any(label.startswith("移入回收站 (2)") for label in known_junk_sidebar)  # pre-selected as before
known_junk.execute(r'''
    LAST_START_ACTIONS=nil
    local k=require("kit")
    for _=1,6 do if k.debug_focus().zone=="sidebar" then break end; k.input("right") end
    while k.debug_focus().sidebar_i>1 do k.input("up") end
    k.input("confirm")
    assert(k.debug_dialog().open)
    k.input("left")
    k.input("confirm")
    assert(LAST_START_KIND=="apply")
    local selected={}
    for _,item in ipairs(LAST_START_ACTIONS or {}) do selected[item.arg]=true end
    assert(selected["/Roms/exact-orphan"])
    assert(selected["/Roms/exact-dead.sh"])
    assert(not selected["/Roms/wrong-name-search-result"])
    assert(not selected["/Roms/wrong-dead-search-result.sh"])
''')



# ── Adversarial-review fixes: version compare, busy escape, uncertain flag ─────
healthy.execute(r'''
    local k=require("kit")
    local native={snapshot=function() return {env={},inventory={},runtime_metadata={}} end,
        start=function() return 1 end,poll=function() return nil end,cancel=function() return true end}
    local model=require("app_model").new(k,native,{})
    local e=model.env
    e.update_status="ok"
    e.portmaster_version="2026.07.01-0011"; e.portmaster_latest="2026.07.15-0020"
    assert(model.update_state()=="update")
    e.portmaster_version="2026.07.15-0020"; e.portmaster_latest="2026.07.01-0011"
    assert(model.update_state()=="reinstall")  -- local build newer than stable
    e.portmaster_version="2026.7"; e.portmaster_latest="2026.8"  -- format change
    assert(model.update_state()=="update")
    e.portmaster_version="2026.07.01"; e.portmaster_latest="2026.07.02"  -- no build token
    assert(model.update_state()=="update")
    e.portmaster_version="1.0.0"; e.portmaster_latest="1.0.0"
    assert(model.update_state()=="current")
''')

healthy.execute(r'''
    local k=require("kit")
    local native={snapshot=function() return {env={},inventory={},runtime_metadata={}} end,
        start=function() return 1 end,poll=function() return nil end,cancel=function() return true end}
    local model=require("app_model").new(k,native,{})
    local operations=require("app_operations").new(model)
    operations.refresh_inventory()
    assert(k.debug_busy().busy)
    -- All input is swallowed while a non-cancellable task runs; exiting is a
    -- deliberate Home-Quit action only, never reachable from inside a task.
    k.input("confirm")
    assert(k.debug_busy().busy)
    k.input("cancel")
    assert(k.debug_busy().busy)
    assert(not k.debug_dialog().open)
''')

uncertain = run_case("healthy", inventory={
    "schema": 1,
    "ports": [{
        "script": "game-a.sh", "path": "/Roms/ports/game-a.sh", "dir": "shared",
        "data_path": "/Roms/ports/gamedata/shared", "claimed_dir": "shared",
        "dir_exists": True, "images": [], "runtime": "", "runtimes": [],
    }],
    "data_refcount": {"/Roms/ports/gamedata/shared": 1}, "orphan_dirs": [], "orphan_images": [],
    "dead_scripts": [], "trash": [],
    "entries": [{"root": "game-dirs", "name": "shared",
        "path": "/Roms/ports/gamedata/shared", "kind": "directory"}],
    "runtimes": {"need": {}, "facts": []},
    "classification_uncertain": True,
})
uncertain.execute('require("kit").close_guide()')
goto_sidebar_tool(uncertain, "卸载管理")
uncertain.execute(r'''
    local k=require("kit")
    if k.debug_guide().open then k.input("cancel") end  -- skip page tour
    k.input("confirm")  -- select the game (default focus is the first row)
    for _=1,6 do
        if k.debug_focus().zone=="sidebar" then break end
        k.input("right")
    end
    k.input("confirm")  -- Uninstall (1)
''')
# With classification_uncertain the uninstall keeps the data folder: the
# confirm dialog must list the launcher only (1 item), never the shared dir.
d = uncertain.eval('require("kit").debug_dialog()')
assert d.open
assert d.title == "卸载所选游戏"
assert d.item_count == 1  # script only; data folder was skipped


# ── Guide: cancel on the first step skips the tour; a sidebar entry replays it ──
tour = run_case("healthy")
assert tour.eval('require("kit").debug_guide().open')
tour.execute('require("kit").input("cancel")')  # skip on first step
assert not tour.eval('require("kit").debug_guide().open')
assert tour.eval('require("kit").get_state().onboarding_seen') == "1"
goto_sidebar_tool(tour, "重新看教程")
assert tour.eval('require("kit").debug_guide().open')
assert tour.eval('require("kit").debug_guide().step') == 1
tour.execute('require("kit").close_guide()')


# ── Full support-matrix contract: support / official / fork per device class ───
support_matrix = [
    ("miniloong-custom", "tested", "unsupported-known" if False else "tested", "定制版（Jenny92）", "官方不兼容（使用定制版）", "定制版（miniloong-custom）"),
    ("official", "tested", "tested", "官方支持", "官方已支持（收录）", "官方原版"),
    ("official", "official-untested", "official-untested", "官方未实测（可尝试）", "官方未实测", "官方原版"),
    ("official", "unsupported-known", "unsupported-known", "未知设备（需确认）", "未收录官方列表", "官方原版"),
    ("official", "unknown-path", "unknown-path", "无法确定", "无法确定", "官方原版"),
]
for channel, dclass, _unused, want_support, want_official, want_fork in support_matrix:
    lua = run_case("healthy", extra={
        "portmaster_release_channel": channel, "device_class": dclass,
        "target_confirmed": "1" if dclass != "unknown-path" else "0",
        "portmaster_target": "/x" if dclass != "unknown-path" else "",
    })
    open_env(lua)
    page = lua.eval('require("kit").debug_page()')
    rows = {page["row_labels"][i]: page["row_values"][i] for i in range(1, page["row_count"] + 1)}
    assert rows["支持方式"] == want_support, (dclass, rows["支持方式"])
    assert rows["官方兼容性"] == want_official, (dclass, rows["官方兼容性"])
    assert rows["是否魔改"] == want_fork, (dclass, rows["是否魔改"])

system_rows = run_case("healthy", extra={"portmaster_management": "system", "device_class": "official-untested"})
open_env(system_rows)
page = system_rows.eval('require("kit").debug_page()')
srows = {page["row_labels"][i]: page["row_values"][i] for i in range(1, page["row_count"] + 1)}
assert srows["支持方式"] == "由系统管理"
assert srows["官方兼容性"] == "由系统管理"
assert srows["是否魔改"] == "系统内置"


# ── Bundle install page: scan task lists recognized zips ─────────────────────
zip_case = run_case("healthy")
zip_case.execute('require("kit").close_guide()')
goto_sidebar_tool(zip_case, "一键安装")
# The entry kicks off the scan: busy overlay on Home, then the completion
# event navigates into the Bundle install page with the results.
assert zip_case.eval('require("kit").debug_busy().busy')
zip_case.globals().POLL_EVENT = zip_case.table_from({
    "task_id": zip_case.globals().TASK_ID, "kind": "scan-zips", "status": "complete",
    "data": {"bundles": [
        {"path": "/mnt/sdcard/game.zip", "size": 1048576, "kind": "port",
         "source_identity": "scan-id-game", "entry_script": "game.sh", "entry_data": "game", "app_name": "", "diagnostic": ""},
        {"path": "/mnt/sdcard/myapp.zip", "size": 2048, "kind": "trimui_app",
         "source_identity": "scan-id-app", "entry_script": "myapp/launch.sh", "entry_data": "", "app_name": "myapp", "diagnostic": ""},
    ]},
}, recursive=True)
zip_case.execute('require("kit").update(0.2)')
assert not zip_case.eval('require("kit").debug_busy().busy')
page = zip_case.eval('require("kit").debug_page()')
assert page["title"] == "压缩包安装"
assert page["row_max_lines"][1] == 5
zip_case.execute('require("kit").draw()')
layout = zip_case.eval('require("kit").debug_layout()')
assert layout["row_layout_mode"] == "flow"
assert layout["columns"] == 1
zip_labels = [page["row_labels"][i] for i in range(1, page["row_count"] + 1)]
assert "game.zip" in zip_labels
assert "myapp.zip" in zip_labels
zip_case.execute(r'''
    local k=require("kit")
    LAST_START_KIND=nil; LAST_START_ACTIONS=nil
    k.input("confirm") -- select game.zip
    k.input("right")
    while k.debug_focus().sidebar_i>1 do k.input("up") end
    k.input("confirm") -- Install
    assert(k.debug_dialog().open and not k.debug_dialog().checkbox_checked)
    k.input("left"); k.input("confirm")
    assert(LAST_START_KIND=="install-zips")
    assert(#LAST_START_ACTIONS==1)
    assert(LAST_START_ACTIONS[1].arg=="/mnt/sdcard/game.zip")
    assert(LAST_START_ACTIONS[1].source_identity=="scan-id-game")
    assert(LAST_START_ACTIONS[1].replace_existing==false)
    assert(k.debug_busy().busy)
''')

zip_replace = run_case("healthy")
zip_replace.execute('require("kit").close_guide()')
goto_sidebar_tool(zip_replace, "一键安装")
zip_replace.globals().POLL_EVENT = zip_replace.table_from({
    "task_id": zip_replace.globals().TASK_ID, "kind": "scan-zips", "status": "complete",
    "data": {"bundles": [
        {"path": "/mnt/sdcard/existing.zip", "size": 4096, "kind": "port",
         "source_identity": "scan-id-existing", "entry_script": "existing.sh",
         "entry_data": "existing", "app_name": "", "diagnostic": ""},
    ]},
}, recursive=True)
zip_replace.execute(r'''
    local k=require("kit")
    k.update(0.2)
    LAST_START_KIND=nil; LAST_START_ACTIONS=nil
    k.input("confirm")
    k.input("right")
    while k.debug_focus().sidebar_i>1 do k.input("up") end
    k.input("confirm")
    assert(k.debug_dialog().open)
    k.input("up"); k.input("confirm") -- explicit replace checkbox
    assert(k.debug_dialog().checkbox_checked and k.debug_dialog().danger)
    assert(k.debug_dialog().message:find("重复的 SH 启动项仍会自动添加数字编号",1,true))
    k.input("down"); k.input("left"); k.input("confirm")
    assert(LAST_START_KIND=="install-zips")
    assert(#LAST_START_ACTIONS==1 and LAST_START_ACTIONS[1].replace_existing==true)
    assert(LAST_START_ACTIONS[1].arg=="/mnt/sdcard/existing.zip")
''')

zip_password = run_case("healthy")
zip_password.execute('require("kit").close_guide()')
goto_sidebar_tool(zip_password, "一键安装")
zip_password.globals().POLL_EVENT = zip_password.table_from({
    "task_id": zip_password.globals().TASK_ID, "kind": "scan-zips", "status": "complete",
    "data": {"bundles": [
        {"path": "/mnt/sdcard/encrypted.7z", "size": 8192, "format": "7z",
         "password_required": True, "kind": "locked", "source_identity": "scan-id-locked",
         "entry_script": "", "entry_data": "", "app_name": "",
         "diagnostic": "压缩包已加密，需要输入密码后识别"},
    ]},
}, recursive=True)
zip_password.execute(r'''
    local k=require("kit")
    k.update(0.2)
    LAST_START_KIND=nil; LAST_START_ACTIONS=nil; LAST_START_PASSWORD=nil
    k.input("confirm")
    k.input("right")
    while k.debug_focus().sidebar_i>1 do k.input("up") end
    k.input("confirm")
    k.input("left"); k.input("confirm")
    assert(k.debug_password_dialog().open)
    k.input("confirm"); k.input("right"); k.input("confirm")
    k.input("down"); k.input("down"); k.input("down"); k.input("down")
    k.input("right"); k.input("right"); k.input("right"); k.input("confirm")
    assert(LAST_START_KIND=="install-zips" and LAST_START_PASSWORD=="12")
    assert(LAST_START_ACTIONS[1].arg=="/mnt/sdcard/encrypted.7z")
    assert(LAST_START_ACTIONS[1].password==nil)
    assert(k.debug_busy().busy and not k.debug_password_dialog().open)
''')

zip_unsupported = run_case("healthy")
zip_unsupported.execute('require("kit").close_guide()')
goto_sidebar_tool(zip_unsupported, "一键安装")
zip_unsupported.globals().POLL_EVENT = zip_unsupported.table_from({
    "task_id": zip_unsupported.globals().TASK_ID, "kind": "scan-zips", "status": "complete",
    "data": {"bundles": [
        {"path": "/mnt/sdcard/ppmd.zip", "size": 4096, "format": "zip",
         "password_required": False, "kind": "invalid", "source_identity": "scan-id-ppmd",
         "entry_script": "", "entry_data": "", "app_name": "",
         "diagnostic": "压缩包使用了当前版本不支持的压缩算法：PPMd (method 98)",
         "issue": {"code": "unsupported_method", "format": "zip",
                   "summary": "压缩包使用了当前版本不支持的压缩算法",
                   "detail": "PPMd (method 98)", "report": "copyable report"}},
    ]},
}, recursive=True)
zip_unsupported.execute(r'''
    local k=require("kit")
    k.update(0.2)
    local page=k.debug_page()
    assert(page.title=="压缩包安装")
    assert(page.row_labels[2]=="ppmd.zip")
    k.input("confirm")
    local dialog=k.debug_dialog()
    assert(dialog.open and dialog.focus=="confirm")
    assert(dialog.title=="安装包诊断")
    assert(dialog.message:find("PPMd (method 98)",1,true))
    assert(dialog.item_count==3)
''')


# ── App launcher merges games and standalone apps, launch asks to quit ────────
launcher_case = run_case("healthy", inventory={
    "schema": 1,
    "ports": [{
        "script": "Z_植物大战僵尸年度版[中].sh", "path": "/Roms/ports/Z_植物大战僵尸年度版[中].sh",
        "dir": "hollow-knight", "data_path": "/Roms/ports/hollow-knight", "claimed_dir": "hollow-knight",
        "dir_exists": True, "images": [], "runtime": "", "runtimes": [],
    }],
    "data_refcount": {}, "orphan_dirs": [], "orphan_images": [], "dead_scripts": [], "trash": [],
    "apps": [{"name": "myapp", "label": "My App", "label_zh": "我的应用",
        "folder": "/mnt/SDCARD/Apps/myapp", "launch": "/mnt/SDCARD/Apps/myapp/launch.sh",
        "has_icon": True, "has_config": True}],
    "entries": [], "runtimes": {"need": {}, "facts": []},
})
launcher_case.execute('require("kit").close_guide()')
# Home IS the app launcher: games and apps are listed right here.
page = launcher_case.eval('require("kit").debug_page()')
assert page["title"] == "Port App Manager"
launcher_rows = [page["row_labels"][i] for i in range(1, page["row_count"] + 1)]
assert "我的应用" in launcher_rows
assert "Z_植物大战僵尸年度版[中]" in launcher_rows
launcher_sidebar = [page["sidebar_labels"][i] for i in range(1, page["sidebar_count"] + 1)]
assert "刷新" in launcher_sidebar  # refresh lives in the Home sidebar
launcher_case.execute(r'''
    local k=require("kit")
    -- first launcher row (myapp) is the default focus
    k.input("confirm")
''')
d = launcher_case.eval('require("kit").debug_dialog()')
assert d["open"]
assert "启动" in d["title"]
assert d["focus"] == "confirm"
launcher_case.execute(r'''
    local k=require("kit")
    k.input("left"); k.input("confirm")
    assert(LAST_RUN_PATH=="/mnt/SDCARD/Apps/myapp/launch.sh")
    assert(LAST_QUIT==42)
''')


# ── Destructive confirmation is pinned to its inventory revision ─────────────
revision_case = run_case("healthy")
revision_case.execute(r'''
    local k=require("kit")
    k.close_guide(); k.close_dialog()
    START_REVISION=nil
    local model={kit=k,env={},pages={HOME=1,RUNTIME=5,TRASH=3,JUNK=2,LAUNCHER=9,ZIP=7,GAMES=8},
        inventory_revision="revision-a"}
    function model.L(en,zh) return {en=en,zh=zh} end
    function model.apply_snapshot(snapshot)
        model.inventory_revision=snapshot.inventory_revision
        return true
    end
    model.native={start=function(kind,plan,revision)
        assert(kind=="apply")
        START_REVISION=revision
        return 77
    end}
    local operations=require("app_operations").new(model)

    operations.show_confirm({en="Confirm",zh="确认"},{{kind="TRASH",arg="/old"}},{"old"},1)
    assert(operations.confirm_revision=="revision-a")
    assert(k.debug_dialog().open)
    operations.apply_snapshot({inventory_revision="revision-b"})
    assert(not k.debug_dialog().open)
    assert(operations.confirm_plan==nil and operations.confirm_revision==nil)
    assert(START_REVISION==nil)

    model.inventory_revision="revision-c"
    operations.show_confirm({en="Confirm",zh="确认"},{{kind="TRASH",arg="/stale"}},{"stale"},1)
    k.close_dialog()
    model.inventory_revision="revision-d"
    operations.start_apply()
    assert(START_REVISION==nil)
    assert(operations.task==nil)

    model.inventory_revision="revision-e"
    operations.show_confirm({en="Confirm",zh="确认"},{{kind="TRASH",arg="/current"}},{"current"},1)
    k.close_dialog()
    operations.start_apply()
    assert(START_REVISION=="revision-e")
    assert(operations.task and operations.task.id==77)
''')

restart_case = run_case("healthy")
restart_case.execute(r'''
    local k=require("kit")
    k.close_guide(); k.close_dialog()
    local state=k.get_state()
    state.web_enabled="1"
    state.web_port="8080"
    state.web_code="123456"
    WEB_STOPPED=false
    local model={kit=k,env={},pages={HOME=1},L=function(en,zh) return {en=en,zh=zh} end,
        native={web_set=function(enabled) assert(enabled==false); WEB_STOPPED=true end}}
    local operations=require("app_operations").new(model)
    operations.restart_for_config()
    assert(WEB_STOPPED)
    assert(state.web_enabled=="1")
    assert(state.web_port==nil and state.web_code==nil)
    assert(LAST_QUIT~=nil)
''')


# ── Protected system APPs remain visible for launch but cannot be selected ───
protected_case = run_case("healthy", inventory={
    "schema": 1, "ports": [], "data_refcount": {}, "orphan_dirs": [], "orphan_images": [],
    "dead_scripts": [], "trash": [], "entries": [],
    "apps": [
        {"name": "PortMaster", "folder": "/mnt/SDCARD/Apps/PortMaster",
         "launch": "/mnt/SDCARD/Apps/PortMaster/launch.sh"},
        {"name": "jenny92-appmanager", "folder": "/mnt/SDCARD/Apps/jenny92-appmanager",
         "launch": "/mnt/SDCARD/Apps/jenny92-appmanager/launch.sh"},
        {"name": "Clock", "folder": "/mnt/SDCARD/Apps/Clock",
         "launch": "/mnt/SDCARD/Apps/Clock/launch.sh"},
    ],
    "runtimes": {"need": {}, "facts": []},
})
protected_case.execute('require("kit").close_guide()')
goto_sidebar_tool(protected_case, "卸载管理")
protected_case.execute(r'''
    local k=require("kit")
    k.close_guide()
    local page=k.debug_page()
    assert(page.row_labels[1]=="PortMaster")
    assert(page.row_labels[2]=="jenny92-appmanager")
    assert(page.row_labels[3]=="Clock")
    -- Default focus skips both disabled protected rows and lands on Clock.
    assert(k.debug_focus().focus_i==3)
    k.input("confirm")
    while k.debug_focus().zone~="sidebar" do k.input("right") end
    assert(k.debug_page().sidebar_labels[1]=="卸载 (1)")
    k.input("confirm")
    assert(k.debug_dialog().open and k.debug_dialog().item_count==1)
''')

# ── Virtual-button business closures: exact uninstall and Trash actions ──────
exact_inventory = {
    "schema": 1,
    "ports": [
        {"script": "Game.sh", "path": "/Roms/ports/Game.sh", "dir": "DataA",
         "data_path": "/Roms/ports/DataA", "claimed_dir": "DataA", "dir_exists": True,
         "images": [], "runtime": "", "runtimes": []},
        {"script": "Game Extra.sh", "path": "/Roms/ports/Game Extra.sh", "dir": "DataB",
         "data_path": "/Roms/ports/DataB", "claimed_dir": "DataB", "dir_exists": True,
         "images": [], "runtime": "", "runtimes": []},
    ],
    "data_refcount": {"/Roms/ports/DataA": 1, "/Roms/ports/DataB": 1},
    "orphan_dirs": [], "orphan_images": [], "dead_scripts": [], "trash": [], "apps": [],
    "entries": [], "runtimes": {"need": {}, "facts": []},
}

exact_uninstall = run_case("healthy", inventory=exact_inventory)
exact_uninstall.execute('require("kit").close_guide()')
goto_sidebar_tool(exact_uninstall, "卸载管理")
exact_uninstall.execute(r'''
    local k=require("kit")
    k.close_guide()
    k.input("right")
    for _=1,8 do
        if k.debug_page().sidebar_labels[k.debug_focus().sidebar_i]=="全选" then break end
        k.input("down")
    end
    assert(k.debug_page().sidebar_labels[k.debug_focus().sidebar_i]=="全选")
    k.input("confirm") -- Select all must stay on this page.
    assert(k.debug_page().title=="卸载管理")
    assert(k.debug_page().sidebar_labels[1]=="卸载 (2)")
    k.input("right")
    assert(k.debug_page().sidebar_labels[k.debug_focus().sidebar_i]=="全不选")
    k.input("confirm") -- Select none also stays here.
    assert(k.debug_page().title=="卸载管理")
    assert(k.debug_page().sidebar_labels[1]=="卸载 (0)")
    for _=1,4 do if k.debug_focus().zone=="rows" then break end; k.input("left") end
    assert(k.debug_focus().zone=="rows")
    for _=1,4 do if k.debug_focus().focus_i==1 then break end; k.input("up") end
    assert(k.debug_focus().focus_i==1)
    k.input("confirm") -- select Game.sh only
    k.input("right")
    for _=1,8 do if k.debug_focus().sidebar_i==1 then break end; k.input("up") end
    assert(k.debug_focus().sidebar_i==1)
    k.input("confirm")
    assert(k.debug_dialog().open and k.debug_dialog().item_count==1)
    k.input("left"); k.input("confirm")
    assert(LAST_START_KIND=="apply")
    assert(LAST_START_REVISION==string.rep("a",64))
    assert(#LAST_START_ACTIONS==2)
    local selected={}
    for _,item in ipairs(LAST_START_ACTIONS) do
        assert(item.kind=="TRASH")
        selected[item.arg]=true
    end
    assert(selected["/Roms/ports/Game.sh"] and selected["/Roms/ports/DataA"])
    assert(not selected["/Roms/ports/Game Extra.sh"] and not selected["/Roms/ports/DataB"])
''')

exact_delete = run_case("healthy", inventory=exact_inventory)
exact_delete.execute('require("kit").close_guide()')
goto_sidebar_tool(exact_delete, "卸载管理")
exact_delete.execute(r'''
    local k=require("kit")
    k.close_guide()
    k.input("confirm")
    k.input("right")
    for _=1,8 do if k.debug_focus().sidebar_i==1 then break end; k.input("up") end
    assert(k.debug_focus().sidebar_i==1)
    k.input("confirm")
    k.input("up"); k.input("confirm") -- permanent-delete checkbox
    assert(k.debug_dialog().checkbox_checked and k.debug_dialog().danger)
    k.input("down"); k.input("left"); k.input("confirm")
    assert(#LAST_START_ACTIONS==2)
    for _,item in ipairs(LAST_START_ACTIONS) do assert(item.kind=="DELETE_MANAGED") end
''')

trash_inventory = {
    "schema": 1, "ports": [], "apps": [], "data_refcount": {}, "orphan_dirs": [],
    "orphan_images": [], "dead_scripts": [], "entries": [],
    "trash": [{"name": "Game.sh", "path": "/trash/scripts/Game.sh", "bucket": "scripts",
        "is_dir": False, "restore_target": "/Roms/ports/Game.sh", "restore_conflict": True}],
    "runtimes": {"need": {}, "facts": []},
}

trash_restore = run_case("healthy", inventory=trash_inventory)
trash_restore.execute('require("kit").close_guide()')
goto_sidebar_tool(trash_restore, "卸载管理")
trash_restore.execute(r'''
    local k=require("kit")
    k.close_guide()
    for _=1,4 do if k.debug_focus().zone=="sidebar" then break end; k.input("right") end
    assert(k.debug_focus().zone=="sidebar")
    for _=1,8 do
        if k.debug_page().sidebar_labels[k.debug_focus().sidebar_i]:find("回收站",1,true) then break end
        k.input("down")
    end
    k.input("confirm")
    assert(k.debug_page().title=="回收站")
    k.input("confirm"); k.input("right")
    for _=1,8 do if k.debug_focus().sidebar_i==1 then break end; k.input("up") end
    assert(k.debug_focus().sidebar_i==1)
    k.input("confirm")
    local d=k.debug_dialog()
    assert(d.open and d.danger and d.message:find("当前同名项目会先移入回收站",1,true))
    k.input("left"); k.input("confirm")
    assert(#LAST_START_ACTIONS==1)
    assert(LAST_START_ACTIONS[1].kind=="RESTORE_REPLACE")
    assert(LAST_START_ACTIONS[1].arg=="/trash/scripts/Game.sh")
''')

trash_delete = run_case("healthy", inventory=trash_inventory)
trash_delete.execute('require("kit").close_guide()')
goto_sidebar_tool(trash_delete, "卸载管理")
trash_delete.execute(r'''
    local k=require("kit")
    k.close_guide()
    for _=1,4 do if k.debug_focus().zone=="sidebar" then break end; k.input("right") end
    assert(k.debug_focus().zone=="sidebar")
    for _=1,8 do
        if k.debug_page().sidebar_labels[k.debug_focus().sidebar_i]:find("回收站",1,true) then break end
        k.input("down")
    end
    k.input("confirm")
    k.input("confirm"); k.input("right")
    for _=1,4 do if k.debug_focus().sidebar_i==2 then break end; k.input("down") end
    assert(k.debug_focus().sidebar_i==2)
    k.input("confirm")
    assert(k.debug_dialog().open and k.debug_dialog().danger)
    k.input("left"); k.input("confirm")
    assert(#LAST_START_ACTIONS==1)
    assert(LAST_START_ACTIONS[1].kind=="DELETE_ITEM")
    assert(LAST_START_ACTIONS[1].arg=="/trash/scripts/Game.sh")
''')

appledouble = run_case("healthy")
appledouble.execute('require("kit").close_guide()')
goto_sidebar_tool(appledouble, "垃圾清理")
appledouble.execute(r'''
    local k=require("kit")
    for _=1,4 do if k.debug_focus().zone=="sidebar" then break end; k.input("right") end
    assert(k.debug_focus().zone=="sidebar")
    for _=1,10 do
        if k.debug_page().sidebar_labels[k.debug_focus().sidebar_i]=="清理 ._Files" then break end
        k.input("down")
    end
    assert(k.debug_page().sidebar_labels[k.debug_focus().sidebar_i]=="清理 ._Files")
    k.input("confirm")
    assert(k.debug_dialog().open and k.debug_dialog().danger)
    k.input("left"); k.input("confirm")
    assert(LAST_START_KIND=="apply" and #LAST_START_ACTIONS==1)
    assert(LAST_START_ACTIONS[1].kind=="CLEAN_APPLEDOUBLE")
''')

print("appmanager environment UI tests: PASS")
