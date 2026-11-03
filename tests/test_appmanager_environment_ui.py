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
assert "function self.show_failure_details()" in operations_source
assert "Port App Manager 使用自带 UI 环境，因此仍可运行" not in source
assert "无法启动提权操作助手" not in source
assert "SquashFS 镜像" not in source
assert "kit.info" not in source
assert 'L("The PortMaster directory was not found. Install it to manage Port games.","未找到 PortMaster 目录，请安装后再管理 Port 游戏。")' in source
assert 'L("PortMaster needs attention. See Environment.","PortMaster 需要注意，请查看运行环境。")' in source
assert 'L("Managed by system · Available","系统管理 · 当前可用")' in source
assert "PortMaster 由系统维护。" in source
assert 'model.native.start,"config-refresh-if-newer"' in source
assert 'model.native.start,"initial-snapshot"' in source
assert "if initial_task or operations.config_restart_pending then return 0.1 end" in source
assert 'kit.set_busy(true,L("Preparing device information' not in source
assert 'L("Device support updated","设备适配已更新")' in source
assert 'value.status~="progress" and value.status~="complete" and value.status~="error"' in source
assert 'items=items,item_groups=groups' in source
assert 'plan[#plan+1]={kind="DELETE_MANAGED",arg=path}' in source
assert 'checkbox={label=L("Delete permanently instead of using Trash","直接删除，不放入回收站"),' not in source
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
assert 'confirm=L("Confirm","确定"),cancel=L("Cancel","取消")' in source
assert "focusable=false" in source
assert "surface=false" in source
for clear_copy in (
    "当前设备暂不支持安装 PortMaster。",
    "无法确定 PortMaster 安装位置，未进行任何修改。",
    "这台设备尚未实测。确认后可以继续。",
    "PortMaster 尚未支持这台设备。请确认安装位置。",
    "存放菜单里的游戏启动脚本。",
    "启动数据加载失败，请查看下方具体原因，处理后重新加载。",
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
    'id="system:runtimes"', 'id="system:details"',
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
love.graphics.circle=function() end
love.graphics.polygon=function() end
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
            if payload.kind==START_ERROR_KIND then
                return {ok=false,error={code="io",message=START_ERROR_REASON}}
            end
            if not BACKGROUND_TASKS and (payload.kind=="config-refresh-if-newer" or payload.kind=="update-check-if-stale") then
                return {ok=false,error={code="offline",message="offline fixture"}}
            end
            TASK_ID=(TASK_ID or 0)+1
            if payload.kind=="initial-snapshot" then
                if STARTUP_ERROR then
                    POLL_EVENT={task_id=TASK_ID,kind="initial-snapshot",status="error",
                        data={message=STARTUP_ERROR}}
                else
                    POLL_EVENT={task_id=TASK_ID,kind="initial-snapshot",status="complete",
                        data={snapshot=APP_SNAPSHOT}}
                end
            end
            return {ok=true,value=TASK_ID}
        end
        if method=="poll" then
            local event=POLL_EVENT
            if event then POLL_EVENT=nil; return {ok=true,value=event} end
            return {ok=true}
        end
        if method=="cancel" then CANCEL_CALLS=(CANCEL_CALLS or 0)+1; return {ok=true,value=true} end
        if method=="web-set" then
            LAST_WEB_SET=payload
            WEB_SET_CALLS=(WEB_SET_CALLS or 0)+1
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
    background_tasks: bool = False,
    screen_size: tuple[int, int] = (960, 720),
    startup_error: str | None = None,
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
        lua.globals().BACKGROUND_TASKS = background_tasks
        lua.globals().STARTUP_ERROR = startup_error
        lua.globals().APP_SNAPSHOT = lua.table_from({
            "env": env,
            "inventory": inventory or {"schema": 1, "ports": [], "data_refcount": {}, "orphan_dirs": [],
                "orphan_images": [], "dead_scripts": [], "trash": [],
                "runtimes": {"need": {}, "facts": []}},
            "revision": "a" * 64, "sizes": {}, "runtime_metadata": {},
        }, recursive=True)
        lua.execute(LOVE_MOCK)
        lua.execute(f"love.graphics.getDimensions=function() return {screen_size[0]},{screen_size[1]} end")
        lua.execute(f"package.path={str(APP / '?.lua')!r}..';'..{str(KIT / '?.lua')!r}..';'..package.path")
        lua.execute(f"dofile({str(APP / 'main.lua')!r})")
        lua.execute("love.load()")
        lua.execute("love.update(0.2)")
        lua.execute(r'''
            function focus_row(id)
                local k=require("kit")
                local target
                for i,key in ipairs(k.debug_page().row_ids) do if key==id then target=i; break end end
                assert(target,"missing row: "..id)
                for _=1,80 do
                    local f=k.debug_focus()
                    if f.zone=="bar" then k.input("down")
                    elseif f.zone=="sidebar" then k.input(k.debug_layout().navigation and "right" or "left")
                    elseif f.focus_i==target then return
                    else
                        local geometry=k.debug_layout().geometry
                        local a,b=geometry[f.focus_i],geometry[target]
                        if b.content_y<a.content_y then k.input("up")
                        elseif b.content_y>a.content_y then k.input("down")
                        else k.input(b.x<a.x and "left" or "right") end
                    end
                end
                error("cannot focus row: "..id)
            end
            function activate(id) focus_row(id); require("kit").input("confirm") end
            function row_index(id)
                for i,key in ipairs(require("kit").debug_page().row_ids) do if key==id then return i end end
                error("missing row: "..id)
            end
        ''')
        return lua


def row_value(page, row_id):
    index = next(i for i in range(1, page["row_count"] + 1) if page["row_ids"][i] == row_id)
    return page["row_values"][index]


def row_labels(page):
    return [page["row_labels"][i] for i in range(1, page["row_count"] + 1)]


def open_feature(lua, label):
    # Primary destinations are stable; page actions are reached inside them.
    destination, action = {
        "PortMaster 管理": ("nav:system", "system:portmaster"),
        "Port Runtime": ("nav:system", "system:runtimes"),
        "环境详情": ("nav:system", "system:details"),
        "远程管理": ("nav:remote", None),
        "批量卸载": ("nav:library", "library:manage"),
        "垃圾清理": ("nav:storage", "storage:leftovers"),
        "回收站": ("nav:storage", "storage:trash"),
        "清理 ._ 文件": ("nav:storage", "storage:appledouble"),
        "重新看教程": ("nav:settings", "settings:tutorial"),
        "设置": ("nav:settings", None),
        "一键安装": ("nav:install", "zip-rescan"),
    }[label]
    lua.globals().TARGET_DESTINATION = destination
    lua.execute(r'''
        local k=require("kit")
        k.goto_page(1); k.input("left")
        assert(k.debug_focus().zone=="sidebar")
        for _=1,6 do
            local p=k.debug_page()
            if p.sidebar_ids[k.debug_focus().sidebar_i]==TARGET_DESTINATION then break end
            k.input("down")
        end
        assert(k.debug_page().sidebar_ids[k.debug_focus().sidebar_i]==TARGET_DESTINATION)
        k.input("confirm")
        assert(k.debug_page().root and k.debug_navigation().depth==0)
    ''')
    if action:
        lua.globals().TARGET_ACTION = action
        lua.execute('focus_row(TARGET_ACTION); require("kit").input("confirm")')


def goto_manage(lua):
    open_feature(lua, "PortMaster 管理")


# Back dismisses a stalled-task prompt without terminating the app or scan.
stuck_return = run_case("healthy", persisted_state={"ui_lang": "zh", "onboarding_seen": "1"})
stuck_return.execute(r'''
    local k=require("kit")
    focus_row("library:refresh"); k.input("confirm")
    love.update(241)
    assert(k.debug_dialog().open and k.debug_dialog().title=="任务可能卡住")
    assert(k.debug_busy().busy and LAST_QUIT==nil)
    k.input("cancel")
    assert(not k.debug_dialog().open and k.debug_busy().busy and LAST_QUIT==nil)
''')


# Mixed setting controls share a row height and stay reachable on small screens.
for screen_size in ((320,240),(640,480),(1280,720)):
    settings_height=run_case("healthy",screen_size=screen_size,
        persisted_state={"ui_lang":"zh","onboarding_seen":"1"})
    open_feature(settings_height,"设置")
    settings_height.execute(r'''
        local k=require("kit")
        local page=k.debug_page()
        local layout=k.debug_layout()
        local height=layout.geometry[1].h
        for i,id in ipairs(page.row_ids) do
            local row=layout.geometry[i]
            assert(math.abs(row.h-height)<.01,"Settings row height differs: "..id)
            if i>1 then
                local previous=layout.geometry[i-1]
                assert(math.abs(row.content_y-previous.content_y-height-layout.gap)<.01,
                    "Settings row spacing differs: "..id)
            end
            focus_row(id)
            layout=k.debug_layout();row=layout.geometry[i]
            assert(row.y>=layout.band_top-.01 and row.y+row.h<=layout.band_top+layout.band+.01,
                "Settings row must scroll fully into view: "..id)
        end
    ''')

# Exit reuses About information and keeps its question/actions below the log.
for screen_size in ((320,240),(640,480),(1280,720)):
    for language in ("zh","en"):
        exit_case=run_case("healthy",screen_size=screen_size,
            extra={"app_root":"/mnt/SDCARD/Apps/jenny92-appmanager/jenny92-appmanager"},
            persisted_state={"ui_lang":language,"onboarding_seen":"1"})
        open_feature(exit_case,"设置")
        exit_case.execute(r'''
            local k=require("kit")
            focus_row("settings:about");k.input("confirm")
            local about=k.debug_page()
            k.input("cancel");k.input("cancel");k.input("cancel")
            love.draw()
            local d=k.debug_dialog();local g=d.geometry
            assert(d.open and d.focus=="confirm" and not d.danger)
            assert(d.identity.title==about.row_labels[1] and d.identity.subtitle==about.row_values[1])
            assert(d.identity.thumbnail=="../share/appmanager.png")
            assert(d.message:find(about.row_values[2],1,true) and d.message:find(about.row_values[3],1,true))
            assert(not d.message:find("…",1,true))
            assert(g.top>=0 and g.bottom<=select(2,love.graphics.getDimensions()))
            assert(g.identity_bottom<=g.content_y and g.message_bottom<=g.title_y,
                "About content and exit question must not overlap")
            local visible_lines=(g.message_bottom-g.content_y)/g.message_line_height
            assert(math.abs(visible_lines-math.floor(visible_lines+.5))<.01,
                "Exit information must clip only at complete text lines")
            assert(g.title_bottom<g.action_y and g.action_bottom<g.bottom)
            assert(g.cancel_x<g.confirm_x and LAST_QUIT==nil)
            k.input("cancel")
            assert(not k.debug_dialog().open and LAST_QUIT==nil and k.debug_focus().zone=="sidebar")
            k.input("cancel");k.input("left");k.input("confirm")
            assert(not k.debug_dialog().open and LAST_QUIT==nil)
            k.get_state().web_enabled="1"
            k.input("cancel");k.input("confirm")
            assert(LAST_QUIT==0 and LAST_WEB_SET==false and k.get_state().web_enabled=="0")
        ''')

# Button layout is applied on load, saved immediately, and restored on restart.
with tempfile.TemporaryDirectory() as preferences_root:
    preferences=run_case("healthy")
    preferences.globals().SOURCE=preferences_root
    preferences.execute('require("kit").close_guide()')
    open_feature(preferences,"设置")
    preferences.execute(r'''
        local k=require("kit")
        assert(not pam_input_layout.swap_ab and not pam_input_layout.swap_xy)
        activate("settings:swap-ab")
        assert(k.get_state().swap_ab=="1" and pam_input_layout.swap_ab and not pam_input_layout.swap_xy)
        assert(k.debug_page().row_ids[k.debug_focus().focus_i]=="settings:swap-ab")
        activate("settings:swap-xy")
        assert(k.get_state().swap_xy=="1" and pam_input_layout.swap_ab and pam_input_layout.swap_xy)
    ''')
    saved=dict(line.split("=",1) for line in (Path(preferences_root)/"state.txt").read_text().splitlines())
    assert saved["swap_ab"]==saved["swap_xy"]=="1"
    cold_preferences=run_case("healthy",persisted_state=saved)
    cold_preferences.execute(r'''
        local k=require("kit")
        assert(k.get_state().swap_ab=="1" and k.get_state().swap_xy=="1")
        assert(pam_input_layout.swap_ab and pam_input_layout.swap_xy,
            "a fresh runtime must restore button correction from the saved file")
    ''')
    preferences.execute(r'''
        love.load();love.update(.2)
        local k=require("kit")
        assert(k.get_state().swap_ab=="1" and k.get_state().swap_xy=="1")
        assert(pam_input_layout.swap_ab and pam_input_layout.swap_xy)
        k.close_guide()
    ''')
    open_feature(preferences,"设置")
    preferences.execute(r'''
        local k=require("kit")
        local persist=k.persist_state
        k.persist_state=function() return false,"read only" end
        activate("settings:swap-ab")
        assert(k.get_state().swap_ab=="1" and pam_input_layout.swap_ab)
        assert(k.debug_toast().kind=="error","a failed save must not claim a remembered setting")
        k.persist_state=persist
        activate("settings:swap-ab");activate("settings:swap-xy")
        assert(not pam_input_layout.swap_ab and not pam_input_layout.swap_xy)
    ''')

healthy = run_case("healthy")
assert healthy.eval('require("kit").debug_page().title') == "已安装"
guide = healthy.eval('require("kit").debug_guide()')
assert guide["open"]
assert guide["title"] == "欢迎使用 Port App Manager"
assert "六个功能分区" in guide["message"]
assert guide["confirm"] == "开始使用"
assert guide["callout_count"] == 6

remote_restored = run_case(
    "healthy",
    extra={"web_url": "http://192.168.255.255"},
    persisted_state={"ui_lang": "zh", "onboarding_seen": "1", "web_enabled": "1", "web_port": "9876", "web_code": "654321"},
)
assert remote_restored.globals().LAST_WEB_SET is None
assert remote_restored.eval('require("kit").get_state().web_enabled') == "0"
remote_restored.execute('require("kit").close_guide(); require("kit").close_dialog()')
open_feature(remote_restored,"远程管理")
remote_restored.execute(r'''
    local k=require("kit")
    assert(k.debug_page().title=="远程管理")
    assert(k.debug_page().row_count==2 and LAST_WEB_SET==nil)
    assert(k.debug_page().row_kinds[1]=="button" and k.debug_page().row_labels[1]=="开启远程管理")
    assert(k.get_state().web_port==nil and k.get_state().web_code==nil)
    k.input("confirm") -- Only the explicit switch starts the service.
    assert(LAST_WEB_SET==true and WEB_SET_CALLS==1)
    local page=k.debug_page()
    assert(page.row_labels[1]=="关闭远程管理")
    local found=0
    local expected
    for i,label in ipairs(page.row_labels) do
        assert(label~="配对码")
        if page.row_ids[i]=="remote:url" then
            expected=page.row_values[i]
            assert(expected=="http://192.168.255.255:8080/123456")
            assert(page.row_max_lines[i]==1)
            found=found+1
        end
    end
    assert(found==1)
    local drawn=false
    love.graphics.printf=function(text,x,y,width)
        if text==expected then assert(width>=60); drawn=true end
    end
    love.draw()
    assert(drawn,"complete pairing URL must be drawn")
''')

# Each screen starts a fresh runtime: Kit reads physical dimensions at load.
previous_qr_side=0
for screen_size in ((320,240),(480,320),(640,480),(720,720),(1280,720),(1920,1080)):
    sized_remote=run_case("healthy",extra={"web_url":"http://192.168.255.255"},
        persisted_state={"ui_lang":"zh","onboarding_seen":"1"},screen_size=screen_size)
    open_feature(sized_remote,"远程管理")
    sized_remote.execute(r'''
    local k=require("kit")
    k.input("confirm")
    local expected="http://192.168.255.255:8080/123456"
    local qr=require("qr_view")
    local draw_qr=qr.draw
    local paper
    qr.draw=function(...)
        local rectangle=love.graphics.rectangle
        paper=nil
        love.graphics.rectangle=function(mode,x,y,w,h,...)
            if not paper then paper={x=x,y=y,w=w,h=h} end
            return rectangle(mode,x,y,w,h,...)
        end
        draw_qr(...)
        love.graphics.rectangle=rectangle
    end
    love.draw()
    local layout=k.debug_layout()
    local code,address
    for i,id in ipairs(k.debug_page().row_ids) do
        if id=="remote:qr" then code=layout.geometry[i]
        elseif id=="remote:url" then address=layout.geometry[i] end
    end
    assert(not layout.scroll,"QR and address fit together without scrolling: "..layout.total_h.." / "..layout.band)
    assert(code.y>=layout.band_top-.01 and code.y+code.h<=address.y)
    assert(address.y+address.h<=layout.band_top+layout.band+.01)
    assert(paper and paper.w==paper.h)
    local modules=#qr.matrix(expected)+4
    local available=math.min(code.w,layout.band-address.h-layout.gap)
    assert(paper.w<=available+.01 and available-paper.w<modules,"QR uses the largest complete module size that fits")
    assert(paper.w/modules==math.floor(paper.w/modules))
    QR_DRAWN_SIDE=paper.w
    ''')
    qr_side=sized_remote.globals().QR_DRAWN_SIDE
    assert qr_side>previous_qr_side,(screen_size,qr_side,previous_qr_side)
    previous_qr_side=qr_side


# Browsing another feature does not start another server or close a manual one.
open_feature(remote_restored,"PortMaster 管理")
open_feature(remote_restored,"远程管理")
remote_restored.execute(r'''
    local k=require("kit")
    assert(k.get_state().web_enabled=="1" and WEB_SET_CALLS==1)
    focus_row("remote:switch"); k.input("confirm")
    assert(k.get_state().web_enabled=="0" and WEB_SET_CALLS==2)
    assert(k.debug_page().row_labels[1]=="开启远程管理")
''')

remote_toggle = run_case(
    "healthy",
    persisted_state={"ui_lang": "zh", "onboarding_seen": "1", "web_enabled": "0"},
)
open_feature(remote_toggle,"远程管理")
remote_toggle.execute(r'''
    local k=require("kit")
    assert(k.debug_page().title=="远程管理")
    assert(LAST_WEB_SET==nil and k.get_state().web_enabled=="0")
    k.input("confirm")
    assert(LAST_WEB_SET==true)
    assert(k.get_state().web_enabled=="1" and k.get_state().web_port=="8080")
    k.input("confirm")
    assert(LAST_WEB_SET==false)
    assert(k.get_state().web_enabled=="0" and k.get_state().web_port==nil)
''')
# A failed service toggle restores the displayed Off state and never publishes a QR.
remote_toggle.execute(r'''
    local original=appmanager.request
    appmanager.request=function(method,payload)
        if method=="web-set" then return {ok=false,error={code="offline",message="fixture"}} end
        return original(method,payload)
    end
    local k=require("kit")
    k.input("confirm")
    assert(k.get_state().web_enabled=="0" and k.get_state().web_port==nil)
    assert(k.debug_toast().kind=="error")
    appmanager.request=original
''')
assert guide["step"] == 1
assert guide["target"] == "nav:library"
healthy.execute('require("kit").input("confirm")')
assert healthy.eval('require("kit").debug_guide().step') == 2
healthy.execute('require("kit").input("cancel")')
assert healthy.eval('require("kit").debug_guide().step') == 1
healthy.execute('require("kit").input("confirm"); require("kit").input("confirm")')
assert healthy.eval('require("kit").debug_guide().step') == 3
assert healthy.eval('require("kit").debug_guide().target') == "nav:storage"
healthy.execute('require("kit").input("confirm"); require("kit").input("confirm"); require("kit").input("confirm")')
guide = healthy.eval('require("kit").debug_guide()')
assert guide["step"] == 6
assert guide["callout_title"] == "设置与帮助"
assert "QQ 群 1047158975" in guide["body"]
assert guide["body"].endswith("/log.txt")
healthy.execute('require("kit").input("confirm")')
assert not healthy.eval('require("kit").debug_guide().open')
assert healthy.eval('require("kit").get_state().onboarding_seen') == "1"
# Home is the feature matrix; PortMaster manager is the last card.
goto_manage(healthy)
page = healthy.eval('require("kit").debug_page()')
assert page["title"] == "PortMaster 维护"
assert page["section_count"] == 0
assert page["row_count"] == 6
assert page["sidebar_count"] == 7
# PortMaster support is stated explicitly on the Environment Management page.
assert "设备适配" in row_labels(page)
assert row_value(page,"manage:support") == "支持"
assert healthy.eval('require("kit").debug_navigation().depth') == 1

# PortMaster owns only its core; Runtime and details are sibling features.
healthy.execute(r'''
    local k=require("kit")
    for _,id in ipairs(k.debug_page().sidebar_ids) do
        assert(id~="manage:runtimes" and id~="manage:details")
    end
    for _,id in ipairs(k.debug_page().row_ids) do
        assert(id~="manage:sh-dir" and id~="manage:data-dir")
    end
    k.input("cancel")
    assert(k.debug_page().index==12 and k.debug_navigation().depth==0)
    focus_row("system:runtimes"); k.input("confirm")
    assert(k.debug_page().title=="修复游戏 Runtime" and k.debug_navigation().depth==1)
    assert(k.debug_focus().zone=="sidebar","an empty Runtime page has no fake content focus")
    k.input("cancel")
    assert(k.debug_page().index==12 and k.debug_navigation().depth==0)
    assert(k.debug_page().row_ids[k.debug_focus().focus_i]=="system:runtimes")
    focus_row("system:portmaster"); k.input("confirm")
    for _=1,10 do
        if k.debug_focus().zone=="bar" then break end
        k.input("up")
    end
    assert(k.debug_focus().zone=="bar")
    k.input("confirm")
    assert(k.debug_page().index==12 and k.debug_navigation().depth==0)
    focus_row("system:details"); k.input("confirm")
    assert(k.debug_page().title=="环境诊断" and k.debug_navigation().depth==1)
    k.input("cancel")
    assert(k.debug_page().index==12 and k.debug_navigation().depth==0)
    assert(k.debug_page().row_ids[k.debug_focus().focus_i]=="system:details")
''')

missing = run_case("missing")
missing.execute('require("kit").close_guide()')  # first-run guide overlays input
page = missing.eval('require("kit").debug_page()')
# Game management no longer depends on a working PortMaster core: the feature
# matrix home opens with an install banner instead of a blocking repair gate.
assert page["title"] == "已安装"
assert page["root"] and page["sidebar_count"] == 7
missing_labels = [page["row_labels"][i] for i in range(1, page["row_count"] + 1)]
assert "library:empty" in [page["row_ids"][i] for i in range(1,page["row_count"]+1)]
assert "library:environment-issue" in [page["row_ids"][i] for i in range(1,page["row_count"]+1)]
# Environment maintenance belongs to its own section, and remains accessible.
goto_manage(missing)
missing.execute(r'''
    local k=require("kit")
    activate("manage:update")
    assert(k.debug_dialog().open and k.debug_dialog().title=="安装 PortMaster")
''')
# The Runtime page explains instead of failing when PortMaster is missing.
missing.execute('require("kit").close_dialog()')
open_feature(missing, "Port Runtime")
page = missing.eval('require("kit").debug_page()')
assert page["title"] == "修复游戏 Runtime"
assert page["row_count"] == 2
assert page["row_kinds"][1] == "textview"  # Runtime page has no web switch

# A damaged PortMaster keeps game management usable: the app opens Home,
# warns, and Environment Management offers Repair as its primary action.
damaged = run_case("damaged")
page = damaged.eval('require("kit").debug_page()')
assert page["title"] == "已安装"
damaged.execute('require("kit").close_guide()')
goto_manage(damaged)
page = damaged.eval('require("kit").debug_page()')
assert page["title"] == "PortMaster 维护"
assert row_value(page,"manage:support") == "支持"
damaged_sidebar = row_labels(page)
assert "修复 PortMaster" in damaged_sidebar

# Devices whose config forbids installing PortMaster say so up front.
disabled = run_case("healthy", extra={"capability_install_portmaster": False})
disabled.execute('require("kit").close_guide()')
goto_manage(disabled)
page = disabled.eval('require("kit").debug_page()')
assert page["title"] == "PortMaster 维护"
assert row_value(page,"manage:support") == "配置未启用"
assert page["row_count"] == 6
disabled_values = [page["row_values"][i] for i in range(1, page["row_count"] + 1)]
disabled_sidebar = row_labels(page)
assert "当前设备暂不支持安装 PortMaster。" in disabled_values
assert "检查更新" not in disabled_sidebar
assert "安装 PortMaster" not in disabled_sidebar

system_managed = run_case("missing", management="system")
page = system_managed.eval('require("kit").debug_page()')
assert page["title"] == "已安装"
# Home has no header action any more; the system-managed badge now lives on
# the PortMaster manager feature card.
system_managed.execute('require("kit").close_guide()')
goto_manage(system_managed)
page = system_managed.eval('require("kit").debug_page()')
assert page["title"] == "PortMaster 维护"
assert page["row_count"] == 6
assert page["sidebar_count"] == 7
assert page["row_kinds"][6] == "textview"
assert row_value(page,"manage:support") == "由系统管理"
open_feature(system_managed,"Port Runtime")
assert system_managed.eval('require("kit").debug_page().title') == "修复游戏 Runtime"

# Exercise the shipped TrimUI policy, not just a synthetic management flag.
trimui_config = json.loads((ROOT / "config/platforms/trimui.json").read_text(encoding="utf-8"))
root_config = json.loads((ROOT / "config/config.json").read_text(encoding="utf-8"))
trimui_env = {"capability_" + key: value for key, value in trimui_config["capabilities"].items()}
trimui_env["portmaster_release_install_allowed"] = root_config["sources"]["release_routes"][
    trimui_config["source_route"]
]["install_allowed"]
for health in ("missing", "damaged", "healthy"):
    trimui = run_case(health, management=trimui_config["frontend"]["management"], extra=trimui_env)
    assert trimui.eval('require("kit").debug_page().title') == "已安装"
    assert trimui.eval("LAST_START_KIND") != "update-check-if-stale"
    trimui.execute('require("kit").close_guide()')
    goto_manage(trimui)
    page = trimui.eval('require("kit").debug_page()')
    assert row_value(page,"manage:support") == "由系统管理"
    assert page["sidebar_count"] == 7  # System-managed core has no unrelated actions.

# Support is stated by support model: our own build (MiniLoong), the official
# release, and unknown devices that fell back to the generic profile.
custom = run_case("healthy", extra={"portmaster_release_channel": "miniloong-custom", "device_class": "tested"})
custom.execute('require("kit").close_guide()')
goto_manage(custom)
page = custom.eval('require("kit").debug_page()')
assert row_value(page,"manage:support") == "定制版（Jenny92）"

official = run_case("healthy", extra={"portmaster_release_channel": "official", "device_class": "tested"})
official.execute('require("kit").close_guide()')
goto_manage(official)
page = official.eval('require("kit").debug_page()')
assert row_value(page,"manage:support") == "官方支持"

generic = run_case("healthy", extra={"portmaster_release_channel": "official", "device_class": "unsupported-known"})
generic.execute('require("kit").close_guide()')
goto_manage(generic)
page = generic.eval('require("kit").debug_page()')
assert row_value(page,"manage:support") == "未知设备（需确认）"
generic_values = [page["row_values"][i] for i in range(1, page["row_count"] + 1)]
assert any("安装完成会自动检查能否正常使用" in value for value in generic_values)

# Device acknowledgement is a child of its entry point, including Runtime.
for health,entry,source_page in (("damaged","manage:update",6),("missing","runtime:install-pm",5)):
    risk_case=run_case(health,extra={"portmaster_release_channel":"official","device_class":"unsupported-known"})
    risk_case.execute('require("kit").close_guide()')
    if source_page==6:
        goto_manage(risk_case)
    else:
        open_feature(risk_case,"Port Runtime")
    risk_case.globals().RISK_ENTRY=entry
    risk_case.globals().RISK_SOURCE=source_page
    risk_case.execute(r'''
        local k=require("kit")
        activate(RISK_ENTRY)
        assert(k.debug_page().index==16 and k.debug_navigation().depth==2)
        k.input("cancel")
        assert(k.debug_page().index==RISK_SOURCE and k.debug_navigation().depth==1)
        assert(k.debug_page().row_ids[k.debug_focus().focus_i]==RISK_ENTRY)
        activate(RISK_ENTRY)
        activate("risk:modify");activate("risk:support");activate("risk:continue")
        assert(k.debug_dialog().open and k.debug_dialog().focus=="cancel")
        k.input("cancel")
        assert(k.debug_page().index==16 and k.debug_navigation().depth==2)
        activate("risk:back")
        assert(k.debug_page().index==RISK_SOURCE and k.debug_navigation().depth==1)
        assert(k.debug_page().row_ids[k.debug_focus().focus_i]==RISK_ENTRY)
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
check_sidebar = row_labels(page)
assert "检查更新" in check_sidebar
assert "重新安装" not in check_sidebar
check.execute(r'''
    local k=require("kit")
    activate("manage:update")
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
assert page["title"] == "PortMaster 维护"
post_sidebar = row_labels(page)
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
    local shell=require("app_shell").new(model,operations)
    local pages=require("app_pages").new(model,operations,shell)
    local environment=require("app_environment").new(model,operations,shell)
    shell.bind(pages)
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
    open_feature(lua,"环境详情")


env_page = run_case("healthy")
open_env(env_page)
page = env_page.eval('require("kit").debug_page()')
assert page["title"] == "环境诊断"
assert row_value(page,"diagnostic:score") == "100 / 100"
assert page["section_labels"][1].startswith("正常或无需处理")
assert page["section_labels"][2] == "全部详情"
assert row_value(page,"diagnostic:clear") == "未发现已知问题。"
env_rows = {page["row_labels"][i]: page["row_values"][i] for i in range(1, page["row_count"] + 1)}
assert env_rows["设备识别"] == "MiniLoong Pocket One"
assert env_rows["设备适配"] == "支持"
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
assert gen_rows["设备适配"] == "未知设备（需确认）"
assert gen_rows["能否安装"] == "可安装（需确认安装位置）"
assert gen_rows["系统运行库"] == "缺少：libGLESv2.so"
assert "未检测到部分系统运行库，可能无法运行" in gen_rows["结论"]
assert row_value(page,"diagnostic:libraries") == "libGLESv2.so"
assert row_value(page,"diagnostic:device") == "未知设备（需确认）"

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
assert row_value(page,"diagnostic:clear") == "未发现已知问题。"
assert row_value(page,"diagnostic:score") == "100 / 100"

# Diagnosis reports actual failed facts before details, without flagging normal
# system ownership, supported custom builds, or passed checks as errors.
diagnosed = run_case("damaged", extra={
    "portmaster_health_checks": [
        {"kind": "required_file", "passed": True},
        {"kind": "required_file", "passed": False},
        {"kind": "required_file", "passed": False},
        {"kind": "executable_file", "passed": True},
    ],
    "portmaster_python_ok": False,
    "portmaster_python_imports": "pygame, sdl2",
    "library_groups": [{"name": "gles", "ok": False, "missing": ["libGLESv2.so"]}],
}, inventory={
    "schema": 1, "ports": [], "apps": [], "data_refcount": {}, "orphan_dirs": [],
    "orphan_images": [], "dead_scripts": [], "trash": [], "entries": [],
    "runtimes": {"need": {"missing.squashfs": ["Game.sh"], "ready.squashfs": ["Other.sh"]},
        "facts": [{"name": "ready.squashfs", "health": "ok", "bytes": 4096}]},
})
open_env(diagnosed)
page = diagnosed.eval('require("kit").debug_page()')
assert row_value(page,"diagnostic:score") == "69 / 100"
assert page["section_labels"][1] == "可能影响游玩（1）"
assert page["section_labels"][2] == "PortMaster 管理问题（3）"
assert row_value(page,"diagnostic:python") == "模块导入检查未通过：pygame, sdl2"
assert row_value(page,"diagnostic:runtime:missing.squashfs") == "missing.squashfs\n关联游戏：Game"
diagnostic_ids=[page["row_ids"][i] for i in range(1,page["row_count"]+1)]
assert diagnostic_ids.count("diagnostic:core:required_file") == 1
assert row_value(page,"diagnostic:core:required_file") == "未找到必需的文件。"
assert row_value(page,"diagnostic:core:executable_file") == "检查通过。"
assert row_value(page,"diagnostic:runtime:ready.squashfs") == "ready.squashfs\n关联游戏：Other"
assert diagnostic_ids.index("diagnostic:runtime:missing.squashfs") < diagnostic_ids.index("diagnostic:core:required_file")
assert max(i for i,key in enumerate(diagnostic_ids) if key.startswith("diagnostic:")) < diagnostic_ids.index("readiness:device")
for management in ("app", "system"):
    normal = run_case("healthy", management=management, extra={
        "portmaster_release_channel": "miniloong-custom",
        "portmaster_python_ok": True,
        "portmaster_health_checks": [{"kind": "required_file", "passed": True}],
    })
    open_env(normal)
    assert row_value(normal.eval('require("kit").debug_page()'),"diagnostic:score") == "100 / 100"

unused_runtime = run_case("healthy", inventory={
    "schema": 1, "ports": [], "apps": [], "data_refcount": {}, "orphan_dirs": [],
    "orphan_images": [], "dead_scripts": [], "trash": [], "entries": [],
    "runtimes": {"need": {}, "facts": [{"name": "unused.squashfs", "health": "invalid_magic", "bytes": 8}]},
})
open_env(unused_runtime)
page=unused_runtime.eval('require("kit").debug_page()')
assert row_value(page,"diagnostic:score") == "100 / 100"
assert "文件检查异常，但未发现当前游戏引用。" in row_value(page,"diagnostic:runtime:unused.squashfs")

many_missing = run_case("healthy", inventory={
    "schema": 1, "ports": [], "apps": [], "data_refcount": {}, "orphan_dirs": [],
    "orphan_images": [], "dead_scripts": [], "trash": [], "entries": [],
    "runtimes": {"need": {f"runtime-{i}.squashfs": [f"Game-{i}.sh"] for i in range(5)}, "facts": []},
})
open_env(many_missing)
assert row_value(many_missing.eval('require("kit").debug_page()'),"diagnostic:score") == "0 / 100"

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
assert severe.eval('require("kit").debug_toast().message') == "PortMaster 需要注意，请查看运行环境。"
# The repair badge now lives on the PortMaster manager tool in the Home sidebar.
home_side = [severe.eval(f'require("kit").debug_page().sidebar_labels[{i}]') for i in range(1, severe.eval('require("kit").debug_page().sidebar_count') + 1)]
assert "运行环境" in home_side

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
assert "hollow-knight" in home_labels  # library stays usable with no core
# The game list lives in the Uninstall manager tool (sidebar).
open_feature(with_inventory, "批量卸载")
page = with_inventory.eval('require("kit").debug_page()')
assert page["title"] == "批量卸载"
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
open_feature(generic_junk, "垃圾清理")
page = generic_junk.eval('require("kit").debug_page()')
assert page["title"] == "残留清理"
generic_junk_labels = [page["row_labels"][i] for i in range(1, page["row_count"] + 1)]
assert "通用布局提醒" in generic_junk_labels
assert "other-system-roms/" in generic_junk_labels
generic_junk_sidebar = row_labels(page)
assert any(label.startswith("删除 (0)") for label in generic_junk_sidebar)  # nothing pre-selected

# The same leftover on a known platform stays pre-selected and un-warned.
known_junk = run_case("healthy", inventory=junk_inventory)
known_junk.execute('require("kit").close_guide()')
open_feature(known_junk, "垃圾清理")
page = known_junk.eval('require("kit").debug_page()')
known_junk_labels = [page["row_labels"][i] for i in range(1, page["row_count"] + 1)]
assert "通用布局提醒" not in known_junk_labels
known_junk_sidebar = row_labels(page)
assert any(label.startswith("删除 (2)") for label in known_junk_sidebar)  # pre-selected as before
known_junk.execute(r'''
    LAST_START_ACTIONS=nil
    local k=require("kit")
    activate("leftovers-remove")
    local d=k.debug_dialog()
    assert(d.open and d.title=="删除所选残留" and d.danger and d.focus=="cancel")
    assert(d.item_count==2 and d.scroll_items and d.message:find("永久删除",1,true))
    assert(not d.message:find("回收站",1,true))
    local preview={[d.current_item]=true}
    k.input("down");preview[k.debug_dialog().current_item]=true
    assert(preview["/Roms/exact-orphan"] and preview["/Roms/exact-dead.sh"])
    k.input("confirm") -- Default Cancel must not submit permanent deletion.
    assert(not k.debug_dialog().open and LAST_START_ACTIONS==nil)
    activate("leftovers-remove")
    k.input("right")
    k.input("confirm")
    assert(LAST_START_KIND=="apply")
    assert(LAST_START_REVISION==string.rep("a",64))
    assert(#LAST_START_ACTIONS==2)
    local selected={}
    for _,item in ipairs(LAST_START_ACTIONS or {}) do
        assert(item.kind=="DELETE_MANAGED","leftovers must be deleted rather than moved to Trash")
        selected[item.arg]=true
    end
    assert(selected["/Roms/exact-orphan"])
    assert(selected["/Roms/exact-dead.sh"])
    assert(not selected["/Roms/wrong-name-search-result"])
    assert(not selected["/Roms/wrong-dead-search-result.sh"])
    POLL_EVENT={task_id=TASK_ID,kind="apply",status="complete",data={
        operation={handled=2,failed=false},snapshot=APP_SNAPSHOT}}
    k.update(.2)
    assert(not k.debug_busy().busy and k.debug_page().title=="残留清理")
    assert(k.debug_toast().kind=="success" and k.debug_toast().message=="已删除 2 项。")
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
open_feature(uncertain, "批量卸载")
uncertain.execute(r'''
    local k=require("kit")
    if k.debug_guide().open then k.input("cancel") end  -- skip page tour
    k.input("confirm")  -- select the game (default focus is the first row)
    activate("uninstall")  -- Review the selected item.
''')
# With classification_uncertain the uninstall keeps the data folder: the
# confirm dialog must list the launcher only (1 item), never the shared dir.
d = uncertain.eval('require("kit").debug_dialog()')
assert d.open
assert d.title == "卸载所选项目"
assert d.item_count == 1  # script only; data folder was skipped


# ── Guide: cancel on the first step skips the tour; a sidebar entry replays it ──
tour = run_case("healthy")
assert tour.eval('require("kit").debug_guide().open')
tour.execute('require("kit").input("cancel")')  # skip on first step
assert not tour.eval('require("kit").debug_guide().open')
assert tour.eval('require("kit").get_state().onboarding_seen') == "1"
open_feature(tour, "重新看教程")
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
    assert rows["设备适配"] == want_support, (dclass, rows["设备适配"])
    assert rows["官方兼容性"] == want_official, (dclass, rows["官方兼容性"])
    assert rows["是否魔改"] == want_fork, (dclass, rows["是否魔改"])

system_rows = run_case("healthy", extra={"portmaster_management": "system", "device_class": "official-untested"})
open_env(system_rows)
page = system_rows.eval('require("kit").debug_page()')
srows = {page["row_labels"][i]: page["row_values"][i] for i in range(1, page["row_count"] + 1)}
assert srows["设备适配"] == "由系统管理"
assert srows["官方兼容性"] == "由系统管理"
assert srows["是否魔改"] == "系统内置"


# ── Bundle install page: scan task lists recognized zips ─────────────────────
zip_case = run_case("healthy")
zip_case.execute('require("kit").close_guide()')
open_feature(zip_case, "一键安装")
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
assert page["title"] == "安装游戏"
assert page["row_kinds"][3] == "checkbox"
assert zip_case.eval('require("kit").debug_focus().focus_i') == 3
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
    focus_row("zip:/mnt/sdcard/game.zip"); k.input("confirm")
    focus_row("zip-install"); k.input("confirm")
    assert(k.debug_dialog().open and not k.debug_dialog().checkbox_checked)
    k.input("right"); k.input("confirm")
    assert(LAST_START_KIND=="install-zips")
    assert(#LAST_START_ACTIONS==1)
    assert(LAST_START_ACTIONS[1].arg=="/mnt/sdcard/game.zip")
    assert(LAST_START_ACTIONS[1].source_identity=="scan-id-game")
    assert(LAST_START_ACTIONS[1].replace_existing==false)
    assert(k.debug_busy().busy)
''')

zip_replace = run_case("healthy")
zip_replace.execute('require("kit").close_guide()')
open_feature(zip_replace, "一键安装")
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
    focus_row("zip:/mnt/sdcard/existing.zip"); k.input("confirm")
    focus_row("zip-install"); k.input("confirm")
    assert(k.debug_dialog().open)
    k.input("up"); k.input("confirm") -- explicit replace checkbox
    assert(k.debug_dialog().checkbox_checked and k.debug_dialog().danger)
    assert(k.debug_dialog().message:find("重复的 SH 启动项仍会自动添加数字编号",1,true))
    k.input("down"); k.input("right"); k.input("confirm")
    assert(LAST_START_KIND=="install-zips")
    assert(#LAST_START_ACTIONS==1 and LAST_START_ACTIONS[1].replace_existing==true)
    assert(LAST_START_ACTIONS[1].arg=="/mnt/sdcard/existing.zip")
''')

zip_password = run_case("healthy")
zip_password.execute('require("kit").close_guide()')
open_feature(zip_password, "一键安装")
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
    focus_row("zip:/mnt/sdcard/encrypted.7z"); k.input("confirm")
    focus_row("zip-install"); k.input("confirm")
    k.input("right"); k.input("confirm")
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
open_feature(zip_unsupported, "一键安装")
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
    assert(page.title=="安装游戏")
    assert(page.row_labels[3]=="ppmd.zip")
    focus_row("zip:/mnt/sdcard/ppmd.zip")
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
assert page["title"] == "已安装"
launcher_rows = [page["row_labels"][i] for i in range(1, page["row_count"] + 1)]
assert "我的应用" in launcher_rows
assert "Z_植物大战僵尸年度版[中]" in launcher_rows
launcher_sidebar = [page["sidebar_labels"][i] for i in range(1,page["sidebar_count"]+1)]
assert launcher_sidebar == ["已安装", "安装游戏", "存储清理", "运行环境", "远程管理", "设置", "退出"]
assert "刷新" in launcher_rows
launcher_case.execute(r'''
    local k=require("kit")
    focus_row("library:app:unknown:myapp"); k.input("confirm")
    assert(k.debug_page().index==14 and not k.debug_dialog().open)
    assert(k.debug_focus().zone=="rows" and k.debug_page().row_ids[k.debug_focus().focus_i]=="item:launch")
    k.input("confirm")
''')
d = launcher_case.eval('require("kit").debug_dialog()')
assert d["open"]
assert "启动" in d["title"]
assert d["focus"] == "confirm"
launcher_case.execute(r'''
    local k=require("kit")
    k.input("right"); k.input("confirm")
    assert(LAST_RUN_PATH=="/mnt/SDCARD/Apps/myapp/launch.sh")
    assert(LAST_QUIT==42)
''')


# ── Destructive confirmation is pinned to its inventory revision ─────────────
revision_case = run_case("healthy")
revision_case.execute(r'''
    local k=require("kit")
    k.close_guide(); k.close_dialog()
    START_REVISION=nil
    local model={kit=k,env={},pages={HOME=1,RUNTIME=5,TRASH=3,JUNK=2,ZIP=7,GAMES=8,STORAGE=11,SYSTEM=12},
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
    assert(state.web_enabled=="0")
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
open_feature(protected_case, "批量卸载")
protected_case.execute(r'''
    local k=require("kit")
    k.close_guide()
    local page=k.debug_page()
    assert(page.row_labels[row_index("home:app:/mnt/SDCARD/Apps/PortMaster")]=="PortMaster")
    assert(page.row_labels[row_index("home:app:/mnt/SDCARD/Apps/jenny92-appmanager")]=="jenny92-appmanager")
    assert(page.row_labels[row_index("home:app:/mnt/SDCARD/Apps/Clock")]=="Clock")
    -- Default focus skips both disabled protected rows and lands on Clock.
    assert(k.debug_focus().focus_i==row_index("home:app:/mnt/SDCARD/Apps/Clock"))
    k.input("confirm")
    assert(k.debug_page().row_labels[row_index("uninstall")]=="卸载 (1)")
    activate("uninstall")
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
open_feature(exact_uninstall, "批量卸载")
exact_uninstall.execute(r'''
    local k=require("kit")
    k.close_guide()
    activate("select-all")
    assert(k.debug_page().title=="批量卸载")
    assert(k.debug_page().row_labels[row_index("uninstall")]=="卸载 (2)")
    k.input("right")
    assert(k.debug_focus().focus_i==row_index("select-none"))
    k.input("confirm")
    assert(k.debug_page().title=="批量卸载")
    assert(k.debug_page().row_labels[row_index("uninstall")]=="卸载 (0)")
    activate("home:/Roms/ports/Game.sh")
    activate("uninstall")
    assert(k.debug_dialog().open and k.debug_dialog().item_count==2)
    assert(k.debug_dialog().group_count==1 and k.debug_dialog().focus=="cancel")
    assert(k.debug_dialog().groups[1].title=="Game")
    assert(k.debug_dialog().groups[1].items[1]=="/Roms/ports/Game.sh")
    k.input("down")
    assert(k.debug_dialog().groups[1].items[2]=="/Roms/ports/DataA/" and k.debug_dialog().focus=="cancel")
    k.input("right"); k.input("confirm")
    assert(LAST_START_KIND=="apply")
    assert(LAST_START_REVISION==string.rep("a",64))
    assert(#LAST_START_ACTIONS==2)
    local selected={}
    for _,item in ipairs(LAST_START_ACTIONS) do
        assert(item.kind=="DELETE_MANAGED")
        selected[item.arg]=true
    end
    assert(selected["/Roms/ports/Game.sh"] and selected["/Roms/ports/DataA"])
    assert(not selected["/Roms/ports/Game Extra.sh"] and not selected["/Roms/ports/DataB"])
''')

exact_delete = run_case("healthy", inventory=exact_inventory)
exact_delete.execute('require("kit").close_guide()')
open_feature(exact_delete, "批量卸载")
exact_delete.execute(r'''
    local k=require("kit")
    k.close_guide()
    k.input("confirm")
    activate("uninstall")
    assert(k.debug_dialog().danger and k.debug_dialog().focus=="cancel")
    LAST_START_ACTIONS=nil
    k.input("confirm") -- Cancel is the default: it must never start deletion.
    assert(not k.debug_dialog().open and LAST_START_ACTIONS==nil)
    k.input("confirm") -- Reopen the same selection.
    assert(k.debug_dialog().scroll_y==0 and k.debug_dialog().group_count==1)
    k.input("down")
    assert(k.debug_dialog().groups[1].items[2]=="/Roms/ports/DataA/")
    k.input("right"); k.input("confirm")
    assert(#LAST_START_ACTIONS==2)
    for _,item in ipairs(LAST_START_ACTIONS) do assert(item.kind=="DELETE_MANAGED") end
''')

shared_inventory = {
    "schema": 1,
    "ports": [
        {"script": name + ".sh", "path": "/scripts/" + name + ".sh", "dir": "Shared",
         "data_path": "/data/Shared", "dir_exists": True,
         "images": [{"path": "/images/shared.png"}]} for name in ("A", "B")
    ],
    "data_refcount": {"/data/Shared": 2}, "orphan_dirs": [], "orphan_images": [],
    "dead_scripts": [], "trash": [], "apps": [], "entries": [],
    "runtimes": {"need": {}, "facts": []},
}
for select_all in (False, True):
    shared_uninstall = run_case("healthy", inventory=shared_inventory)
    shared_uninstall.globals().SELECT_ALL = select_all
    shared_uninstall.execute('require("kit").close_guide()')
    open_feature(shared_uninstall, "批量卸载")
    shared_uninstall.execute(r'''
        local k=require("kit")
        k.close_guide()
        if SELECT_ALL then activate("select-all")
        else k.input("confirm") end
        activate("uninstall")
        local d=k.debug_dialog()
        assert(d.danger and d.group_count==(SELECT_ALL and 2 or 1) and d.focus=="cancel")
        assert(d.item_count==(SELECT_ALL and 4 or 1))
        local preview={}
        for index,group in ipairs(d.groups) do
            assert(group.title==(index==1 and 'A' or 'B'))
            assert(group.items[1]=='/scripts/'..group.title..'.sh')
            assert(#group.items==(SELECT_ALL and 3 or 1))
            for _,path in ipairs(group.items) do preview[path:gsub("/$","")]=true end
        end
        k.input("right"); k.input("confirm")
        assert(#LAST_START_ACTIONS==d.item_count)
        for _,item in ipairs(LAST_START_ACTIONS) do
            assert(item.kind=="DELETE_MANAGED" and preview[item.arg])
            preview[item.arg]=nil -- Shared paths appear in both groups but are deleted only once.
        end
        assert(next(preview)==nil)
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
open_feature(trash_restore, "回收站")
trash_restore.execute(r'''
    local k=require("kit")
    assert(k.debug_page().title=="回收站")
    k.input("confirm")
    activate("trash-restore")
    local d=k.debug_dialog()
    assert(d.open and d.danger and d.message:find("当前同名项目会先移入回收站",1,true))
    k.input("right"); k.input("confirm")
    assert(#LAST_START_ACTIONS==1)
    assert(LAST_START_ACTIONS[1].kind=="RESTORE_REPLACE")
    assert(LAST_START_ACTIONS[1].arg=="/trash/scripts/Game.sh")
''')

trash_delete = run_case("healthy", inventory=trash_inventory)
trash_delete.execute('require("kit").close_guide()')
open_feature(trash_delete, "回收站")
trash_delete.execute(r'''
    local k=require("kit")
    assert(k.debug_page().title=="回收站")
    k.input("confirm")
    activate("trash-delete")
    assert(k.debug_dialog().open and k.debug_dialog().danger)
    k.input("right"); k.input("confirm")
    assert(#LAST_START_ACTIONS==1)
    assert(LAST_START_ACTIONS[1].kind=="DELETE_ITEM")
    assert(LAST_START_ACTIONS[1].arg=="/trash/scripts/Game.sh")
''')

appledouble = run_case("healthy")
appledouble.execute('require("kit").close_guide()')
open_feature(appledouble, "清理 ._ 文件")
appledouble.execute(r'''
    local k=require("kit")
    assert(k.debug_dialog().open and k.debug_dialog().danger)
    k.input("right"); k.input("confirm")
    assert(LAST_START_KIND=="apply" and #LAST_START_ACTIONS==1)
    assert(LAST_START_ACTIONS[1].kind=="CLEAN_APPLEDOUBLE")
''')

# Primary destinations own navigation; item operations stay within the library.
functional_inventory = dict(exact_inventory, apps=[{
    "name": "Clock", "label": "Clock", "label_zh": "时钟",
    "folder": "/Apps/Clock", "launch": "/Apps/Clock/launch.sh",
}])
functional = run_case("healthy", inventory=functional_inventory,
    persisted_state={"ui_lang": "zh", "onboarding_seen": "1", "onboarding_games": "1"})
functional.execute(r'''
    local k=require("kit")
    local ids={'nav:library','nav:install','nav:storage','nav:system','nav:remote','nav:settings'}
    local function section(id)
        k.goto_page(1); k.input('left')
        for _=1,6 do
            if k.debug_page().sidebar_ids[k.debug_focus().sidebar_i]==id then break end
            k.input('down')
        end
        assert(k.debug_page().sidebar_ids[k.debug_focus().sidebar_i]==id)
        k.input('confirm')
    end
    for index,id in ipairs(ids) do
        section(id)
        local p=k.debug_page()
        assert(p.root and p.sidebar_count==7 and k.debug_navigation().depth==0)
        for i,key in ipairs(ids) do
            assert(p.sidebar_ids[i]==key and p.sidebar_active[i]==(i==index))
        end
        assert(p.sidebar_ids[7]=='nav:quit' and p.sidebar_labels[7]=='退出')
        assert(not k.debug_dialog().open)
    end
    -- About is secondary, and returns to the same Settings row.
    focus_row('settings:about'); k.input('confirm')
    assert(k.debug_page().title=='关于' and k.debug_navigation().depth==1)
    k.input('cancel')
    assert(k.debug_page().row_ids[k.debug_focus().focus_i]=='settings:about')
    section('nav:library')
    focus_row('library:filter'); k.input('confirm')
    assert(k.debug_dialog().select and k.debug_dialog().selected_value=='all')
    k.input('down'); assert(k.get_state().library_filter=='all')
    k.input('cancel')
    assert(not k.debug_dialog().open and k.get_state().library_filter=='all')
    assert(k.debug_page().row_ids[k.debug_focus().focus_i]=='library:filter')
    k.input('confirm'); k.input('down'); k.input('down'); k.input('confirm')
    assert(k.get_state().library_filter=='app')
    local p=k.debug_page()
    local app,game=false,false
    for _,id in ipairs(p.row_ids) do
        app=app or id=='library:app:unknown:Clock'
        game=game or id:match('^library:game:')~=nil
    end
    assert(app and not game)
    focus_row('library:filter'); k.input('confirm')
    k.input('up'); k.input('up'); k.input('confirm')
    focus_row('library:game:/Roms/ports/Game.sh'); k.input('confirm')
    assert(k.debug_page().index==14 and k.debug_navigation().depth==1)
    assert(k.debug_focus().zone=='rows' and k.debug_page().row_ids[k.debug_focus().focus_i]=='item:launch')
    focus_row('item:uninstall'); k.input('confirm')
    local d=k.debug_dialog()
    assert(d.open and d.focus=='cancel' and d.group_count==1 and d.item_count==2)
    assert(d.groups[1].items[1]=='/Roms/ports/Game.sh')
    assert(d.groups[1].items[2]=='/Roms/ports/DataA/')
    k.input('cancel'); k.input('cancel')
    assert(k.debug_page().index==1 and not k.debug_dialog().open)
''')

# Delayed background results must not take focus from the navigation being used.
for destination in range(1, 7):
    background_nav = run_case("healthy", inventory=functional_inventory, background_tasks=True,
        persisted_state={"ui_lang": "zh", "onboarding_seen": "1"})
    background_nav.globals().DESTINATION = destination
    background_nav.execute(r'''
        local k=require("kit")
        k.input('left')
        -- Move slowly in both directions, drawing each destination before the
        -- pending configuration/update requests finish.
        for _,direction in ipairs({'down','down','down','down','down','up','up','up','up','up'}) do
            k.input(direction); love.update(0.7); love.draw()
            assert(k.debug_focus().zone=='sidebar')
        end
        for _=2,DESTINATION do k.input('down'); love.update(0.7); love.draw() end
        local before=k.debug_focus()
        local page=k.debug_page()
        local id=page.sidebar_ids[before.sidebar_i]
        local function unchanged()
            love.draw()
            local f,p=k.debug_focus(),k.debug_page()
            assert(p.index==page.index and f.zone=='sidebar' and p.sidebar_ids[f.sidebar_i]==id,
                'background result moved the current page/navigation focus')
        end
        POLL_EVENT={task_id=TASK_ID,kind='config-refresh-if-newer',status='complete',
            data={config_refresh={status='current'}}}
        love.update(0.7); unchanged()
        assert(LAST_START_KIND=='update-check-if-stale')
        POLL_EVENT={task_id=TASK_ID,kind='update-check-if-stale',status='complete',
            data={update={update_status='ok',portmaster_latest='2026.09',update_checked=1789000000}}}
        love.update(0.7); unchanged()
        for _=1,12 do love.update(0.7); unchanged() end
        assert(not k.debug_dialog().open and not k.debug_busy().busy)
    ''')

read_only = run_case("healthy", inventory=exact_inventory, extra={
    "capability_manage_ports": False, "capability_manage_apps": False,
    "capability_install_ports": False, "capability_install_apps": False,
}, persisted_state={"ui_lang": "zh", "onboarding_seen": "1"})
read_only.execute(r'''
    local k=require("kit")
    for _,id in ipairs(k.debug_page().row_ids) do assert(id~='library:manage') end
    focus_row('library:game:/Roms/ports/Game.sh'); k.input('confirm')
    for _,id in ipairs(k.debug_page().row_ids) do assert(id~='item:uninstall') end
    k.input('cancel'); k.input('left'); k.input('down'); k.input('confirm')
    local p=k.debug_page()
    assert(p.title=='安装游戏' and p.root and p.row_count==1 and p.row_ids[1]=='zip:unavailable')
    assert(not k.debug_busy().busy)
''')

# Progress events must preserve the cancel action installed when the task began.
progress_case = run_case("healthy", inventory={
    "schema": 1, "ports": [{"script": "Game.sh", "path": "/ports/Game.sh", "runtimes": ["godot_test"]}],
    "apps": [], "data_refcount": {}, "orphan_dirs": [], "orphan_images": [], "dead_scripts": [], "trash": [],
    "entries": [], "runtimes": {"need": {"godot_test": ["Game.sh"]}, "facts": [{"name": "godot_test", "health": "missing", "bytes": 0}]},
})
progress_case.execute('require("kit").close_guide()')
open_feature(progress_case,"Port Runtime")
progress_case.execute(r'''
    local k=require("kit")
    activate("runtime-repair")
    k.input("right"); k.input("confirm")
    assert(LAST_START_KIND=="apply" and k.debug_busy().cancellable)
    POLL_EVENT={task_id=TASK_ID,kind="apply",status="progress",data={
        phase="downloading",runtime="godot_test",index=1,count=1,current=20,total=100,speed=10}}
    love.update(0.2)
    assert(k.debug_busy().cancellable and not k.debug_busy().cancel_requested)
    k.input("confirm")
    assert(CANCEL_CALLS==1 and k.debug_busy().cancel_requested)
    POLL_EVENT={task_id=TASK_ID,kind="apply",status="progress",data={
        phase="downloading",runtime="godot_test",index=1,count=1,current=21,total=100,speed=10}}
    love.update(0.2)
    assert(k.debug_busy().cancel_requested)
    k.input("confirm"); assert(CANCEL_CALLS==1)
''')

# Explicit native failures survive page rebuilds; a successful retry clears
# that operation's banner. Both the cause and the complete log path are readable.
for size in ((320, 240), (640, 480), (960, 720)):
    failure_case = run_case("healthy", persisted_state={"ui_lang": "zh", "onboarding_seen": "1"}, screen_size=size)
    failure_case.execute(r'''
        local k=require("kit")
        activate("library:refresh")
        FAILURE_REASON="cannot enumerate inventory root `images` at /mnt/card/ports/images: Not a directory (os error 20)"
        POLL_EVENT={task_id=TASK_ID,kind="inventory-refresh",status="error",
            data={message=FAILURE_REASON,snapshot=APP_SNAPSHOT}}
        love.update(.2)
        local d=k.debug_dialog()
        assert(d.open and d.title=="文件扫描失败" and d.current_item==FAILURE_REASON)
        assert(d.message:find("原因不明确",1,true) and d.message:find(k.CONTACT,1,true))
        k.input("down")
        assert(k.debug_dialog().current_item:find(APP_SNAPSHOT.env.gamedir.."/log.txt",1,true))
        k.close_dialog()
        local p=k.debug_page()
        assert(p.row_values[row_index("library:failure")]==FAILURE_REASON)
        -- Rebuilding the Home page must not make the failure disappear.
        activate("library:filter"); k.input("cancel")
        activate("library:failure-details")
        assert(k.debug_dialog().current_item==FAILURE_REASON)
        k.close_dialog()
        activate("library:refresh")
        POLL_EVENT={task_id=TASK_ID,kind="inventory-refresh",status="complete",data={snapshot=APP_SNAPSHOT}}
        love.update(.2)
        for _,id in ipairs(k.debug_page().row_ids) do assert(id~="library:failure") end
        assert(k.debug_toast().kind=="success")
        -- Starting a task can also fail before any completion event exists.
        START_ERROR_KIND="inventory-refresh"; START_ERROR_REASON="cannot open /mnt/card/state: Permission denied"
        activate("library:refresh")
        assert(not k.debug_busy().busy and k.debug_dialog().open)
        assert(k.debug_dialog().current_item:find(START_ERROR_REASON,1,true))
        k.close_dialog();START_ERROR_KIND=nil
        activate("library:refresh")
        POLL_EVENT={task_id=TASK_ID,kind="inventory-refresh",status="error",data={snapshot=APP_SNAPSHOT}}
        love.update(.2)
        assert(k.debug_dialog().current_item:find("未返回具体原因",1,true))
        k.input("down")
        assert(k.debug_dialog().current_item:find(APP_SNAPSHOT.env.gamedir.."/log.txt",1,true))
    ''')

# No initial snapshot is needed to locate logs or retry a failed startup.
startup = run_case("healthy", startup_error="PortMaster recovery failed at /mnt/card/PortMaster: Permission denied",
    persisted_state={"ui_lang": "zh", "onboarding_seen": "1"}, screen_size=(320, 240))
startup_page = startup.eval('require("kit").debug_page()')
assert "/mnt/card/PortMaster" in row_value(startup_page, "startup:details")
assert row_value(startup_page, "startup:log").endswith("/log.txt")
assert row_value(startup_page, "startup:log") != "/log.txt"
startup.execute(r'''
    STARTUP_ERROR=nil
    activate("startup:retry")
    love.update(.2)
    assert(require("kit").debug_page().title=="已安装")
    for _,id in ipairs(require("kit").debug_page().row_ids) do assert(id~="library:failure") end
    local model=require("app_model").new(require("kit"),{})
    local getenv=os.getenv
    os.getenv=function(name) if name=="app_root" then return "/bootstrap/app" end return getenv(name) end
    assert(model.log_path()=="/bootstrap/app/log.txt")
    os.getenv=getenv
    model.record_failure("inventory-refresh","Scan failed","missing /card/file")
    model.apply_snapshot(APP_SNAPSHOT)
    assert(model.failure.reason=="missing /card/file")
    model.clear_failure("update-check");assert(model.failure)
    model.clear_failure("inventory-refresh");assert(not model.failure)
''')

# A Runtime task with only a top-level error must never announce success.
runtime_failure = run_case("healthy", inventory={
    "schema": 1, "ports": [{"script": "Game.sh", "path": "/ports/Game.sh", "runtimes": ["godot_test"]}],
    "apps": [], "data_refcount": {}, "orphan_dirs": [], "orphan_images": [], "dead_scripts": [], "trash": [],
    "entries": [], "runtimes": {"need": {"godot_test": ["Game.sh"]}, "facts": [{"name": "godot_test", "health": "missing", "bytes": 0}]},
}, persisted_state={"ui_lang": "zh", "onboarding_seen": "1"})
open_feature(runtime_failure,"Port Runtime")
runtime_failure.execute(r'''
    local k=require("kit")
    activate("runtime-repair"); k.input("right"); k.input("confirm")
    POLL_EVENT={task_id=TASK_ID,kind="apply",status="error",data={
        message="cannot create /mnt/card/PortMaster/libs: Read-only file system",snapshot=APP_SNAPSHOT}}
    love.update(.2)
    assert(not k.debug_busy().busy)
    assert(k.debug_toast().kind=="error" and k.debug_dialog().title=="Runtime 修复失败")
    assert(k.debug_dialog().current_item:find("Read-only file system",1,true))
''')
progress_case.execute(r'''
    local k=require("kit")
    POLL_EVENT={task_id=TASK_ID,kind="apply",status="error",data={
        message="operation cancelled",snapshot=APP_SNAPSHOT}}
    love.update(.2)
    assert(k.debug_toast().message=="操作已取消。" and not k.debug_dialog().open)
''')

# Partial installs keep full source paths, and an unsuccessful rescan must
# retain the last usable list instead of replacing it with an empty result.
zip_case.execute(r'''
    local k=require("kit")
    POLL_EVENT={task_id=TASK_ID,kind="install-zips",status="complete",data={zip_install={
        installed_bundles=0,failed_bundles=1,conflicted_bundles=0,
        failures={{path="/mnt/sdcard/game.zip",message="cannot write /mnt/card/ports: Permission denied"}}}}}
    love.update(.2)
    assert(k.debug_dialog().title=="部分安装包未安装")
    assert(k.debug_dialog().current_item:find("/mnt/sdcard/game.zip",1,true))
    assert(k.debug_dialog().current_item:find("/mnt/card/ports",1,true))
    k.input("down")
    assert(k.debug_dialog().current_item:find(APP_SNAPSHOT.env.gamedir.."/log.txt",1,true))
    k.close_dialog()
    activate("zip-rescan")
    POLL_EVENT={task_id=TASK_ID,kind="scan-zips",status="error",data={
        message="cannot scan /mnt/card: Input/output error"}}
    love.update(.2)
    assert(k.debug_dialog().current_item=="cannot scan /mnt/card: Input/output error")
    k.close_dialog()
    row_index("zip:/mnt/sdcard/game.zip");row_index("zip:/mnt/sdcard/myapp.zip")
    k.goto_page(1)
    assert(k.debug_page().row_values[row_index("library:failure")]:find("Input/output error",1,true))
''')

print("appmanager environment UI tests: PASS")
