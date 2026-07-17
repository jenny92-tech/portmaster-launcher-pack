#!/usr/bin/env python3
"""Executable shared-Lua contract tests (uses lupa when available)."""
from pathlib import Path
import json
import os
import tempfile
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    print("love Lua module tests: SKIP (lupa unavailable)")
    raise SystemExit(0)

root = Path(__file__).resolve().parents[1]

mock = r'''
love = {graphics={}, filesystem={}, event={}}
local font = {getHeight=function() return 20 end,getWidth=function(_,text) return #text*10 end}
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
'''

expected_env = {
    "heishenhua": (5, ("HSH_WIDTH=auto", "HSH_TEXMAX=480", "HSH_DMG=1.0", "HSH_LAUNCH_COUNT=1")),
    "hk": (4, ("HKL_WIDTH=auto", "HKL_TEXMAX=384", "HKL_SWAP_AB=off", "HKL_LAUNCH_COUNT=1")),
    "sts2": (4, ("SLL_PCK_VARIANT=8x8", "SLL_LANGUAGE=zh_CN", "SLL_SWAP_AB=on", "SLL_LAUNCH_COUNT=1")),
    "terraria": (4, ("TER_WIDTH=auto", "TER_LANGUAGE=7", "TER_SWAP_AB=off", "TER_LAUNCH_COUNT=1")),
    "vampiresurvivors114": (2, ("VS_WIDTH=auto", "VS_HEIGHT=auto", "VS_SWAP_AB=off", "VS_LAUNCH_COUNT=1")),
}

for port in ("heishenhua", "hk", "sts2", "terraria", "vampiresurvivors114"):
    with tempfile.TemporaryDirectory() as source:
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().SOURCE = source
        lua.execute(mock)
        lua.execute(f"package.path={str(root / '_kit/love' / '?.lua')!r}..';'..package.path")
        lua.execute(f"dofile({str(root / 'ports' / port / 'love/main.lua')!r})")
        lua.execute("love.load(); love.draw()")
        downs, required = expected_env[port]
        for _ in range(downs):
            lua.execute("love.keypressed('down')")
        lua.execute("love.keypressed('return')")
        assert lua.globals().LAST_QUIT == 42, port
        text = (Path(source) / "launch_config.env").read_text(encoding="utf-8")
        for line in required:
            assert line in text, (port, line, text)

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("arg = {[1]=...}", str(root / "ports/appmanager/love"))
lua.execute(f"dofile({str(root / 'ports/appmanager/tests/test_scan.lua')!r})")

# APP Manager must use the same renderer against a real dynamic scan result.
with tempfile.TemporaryDirectory() as source:
    base = Path(source)
    scripts = base / "scripts"
    data = base / "data"
    app = data / "appmanager"
    for directory in (scripts, data / "GameData", app / "conf", app / "trash", base / "libs", base / "images"):
        directory.mkdir(parents=True, exist_ok=True)
    (scripts / "Game.sh").write_text('GAMEDIR="/' + str(data).lstrip('/') + '/GameData"\n', encoding="utf-8")
    env_path = app / "conf/env.json"
    env_path.write_text(json.dumps({
        "controlfolder": str(base / "PortMaster"), "scripts_dir": str(scripts),
        "gamedirs_dir": str(data), "images_dir": str(base / "images"),
        "libs_dir": str(base / "libs"), "gamedir": str(app), "directory": str(data).lstrip('/'),
        "home": str(base), "cfw": "test", "free_bytes": 1024,
        "display_width": "960", "display_height": "720", "device_arch": "aarch64",
        "device": "test", "plan_file": str(app / "conf/plan.txt"),
        "result_file": str(app / "conf/result.txt"), "apply_script": "",
        "size_file": str(app / "conf/sizes.tsv"), "ignore_dirs": ["PortMaster", "images", "appmanager"],
        "ignore_scripts": ["PortMaster.sh", "APP Manager.sh", ".port.sh"], "self_port": "appmanager"
    }), encoding="utf-8")
    previous = os.environ.get("PAM_ENV")
    os.environ["PAM_ENV"] = str(env_path)
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().SOURCE = str(app / "love_ui")
    lua.execute(mock)
    lua.execute(
        f"package.path={str(root / '_kit/love' / '?.lua')!r}..';'.."
        f"{str(root / 'ports/appmanager/love' / '?.lua')!r}..';'..package.path"
    )
    fixture = {
        str(data): [{"name": "GameData", "path": str(data / "GameData"), "is_dir": True}],
        str(scripts): [{"name": "Game.sh", "path": str(scripts / "Game.sh"), "is_dir": False}],
        str(base / "images"): [], str(base / "libs"): [], str(app / "trash"): [],
    }
    lua.globals().SCAN_FIXTURE = json.dumps(fixture)
    lua.execute(r'''
        local rows=require("json").decode(SCAN_FIXTURE)
        require("scan").set_list_provider(function(path,want_dirs)
            local result={}
            for _,entry in ipairs(rows[path] or {}) do
                if want_dirs==nil or entry.is_dir==want_dirs then result[#result+1]=entry end
            end
            return result
        end)
    ''')
    lua.execute(f"dofile({str(root / 'ports/appmanager/love/main.lua')!r})")
    lua.execute(
        "love.load(); local L=require('kit').debug_layout(); "
        "assert(L.app and L.x <= 20 and L.w > L.side_w * 2 and L.rh >= 70 and L.dim >= 0.90)"
    )
    # Dialogs trap focus, default to the safe cancel action, and close before
    # calling either callback. Escape/B always follows the cancel path.
    lua.execute(r'''
        local k=require("kit")
        DIALOG_CONFIRM,DIALOG_CANCEL=0,0
        k.dialog({title={en="Confirm",zh="确认"},message="Review this action",
            items={"One","Two","A very long selected item name that must stay on one line","Four","Five"},
            confirm="Delete",cancel="Cancel",danger=true,
            on_confirm=function() DIALOG_CONFIRM=DIALOG_CONFIRM+1 end,
            on_cancel=function() DIALOG_CANCEL=DIALOG_CANCEL+1 end})
        local D=k.debug_dialog()
        assert(D.open and D.focus=="cancel" and D.item_count==5 and D.danger)
        love.draw(); love.keypressed("left"); love.keypressed("return")
        assert(DIALOG_CONFIRM==1 and DIALOG_CANCEL==0 and not k.debug_dialog().open)
        k.dialog({title="Confirm",on_cancel=function() DIALOG_CANCEL=DIALOG_CANCEL+1 end})
        love.keypressed("escape")
        assert(DIALOG_CANCEL==1 and not k.debug_dialog().open)
    ''')
    # Rebuilding a dynamic selection page must not throw focus back to the
    # first row. Select All/None stay on the same sidebar controls.
    lua.execute(r'''
        local k=require("kit")
        love.keypressed("right")
        local before=k.debug_focus()
        assert(before.zone=="sidebar" and before.sidebar_i==2)
        love.keypressed("return")
        local selected=k.debug_focus()
        assert(selected.zone==before.zone and selected.sidebar_i==before.sidebar_i)
        love.keypressed("right"); love.keypressed("return")
        local cleared=k.debug_focus()
        assert(cleared.zone=="sidebar" and cleared.sidebar_i==3)
        love.keypressed("left"); love.keypressed("left")
        assert(k.debug_focus().zone=="rows")
    ''')
    # Environment details restore the old three sections: 4 key paths,
    # 16 environment values, and one no-runtime row in this fixture.
    lua.execute(r'''
        local k=require("kit")
        love.keypressed("up"); love.keypressed("return")
        local page=k.debug_page()
        assert(page.index==4 and page.section_count==3 and page.row_count==24)
        assert(k.debug_focus().zone=="rows" and k.debug_focus().focus_i==2)
        love.draw(); love.keypressed("escape")
    ''')
    # Toggle a real scanned port, move into the shared sidebar, open the
    # confirmation dialog, then cancel without leaving the dynamic home page.
    lua.execute(
        "love.draw(); love.keypressed('return'); "
        "love.keypressed('right'); love.keypressed('return'); "
        "assert(require('kit').debug_dialog().open); love.draw(); "
        "love.keypressed('escape'); love.draw(); "
        "love.keypressed('up'); love.keypressed('return'); love.draw(); "
        "love.keypressed('escape'); love.draw()"
    )
    # APP Manager never exits directly from the home B/Escape action. It opens
    # a non-dangerous dialog, defaults to Cancel, and exits only after Confirm.
    lua.execute(r'''
        local k=require("kit")
        LAST_QUIT=nil
        love.keypressed("escape")
        local exit_dialog=k.debug_dialog()
        assert(exit_dialog.open and exit_dialog.focus=="cancel" and not exit_dialog.danger)
        love.keypressed("return")
        assert(LAST_QUIT==nil and not k.debug_dialog().open)
        love.keypressed("escape"); love.keypressed("left"); love.keypressed("return")
        assert(LAST_QUIT==k.EXIT_QUIT and not k.debug_dialog().open)
    ''')
    if previous is None:
        os.environ.pop("PAM_ENV", None)
    else:
        os.environ["PAM_ENV"] = previous

print("love Lua module tests: PASS")
