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
local font = {
    getHeight=function() return 20 end,
    getWidth=function(_,text) return #text*10 end,
    getWrap=function(_,text,limit)
        local count=math.max(1,math.floor(limit/10)); local lines={}
        for i=1,#text,count do lines[#lines+1]=text:sub(i,i+count-1) end
        return math.min(#text*10,limit),lines
    end,
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
'''

expected_env = {
    "heishenhua": (5, ("HSH_WIDTH='auto'", "HSH_TEXMAX='480'", "HSH_DMG='1.0'", "HSH_LAUNCH_COUNT='1'")),
    "hk": (4, ("HKL_WIDTH='auto'", "HKL_TEXMAX='384'", "HKL_SWAP_AB='off'", "HKL_LAUNCH_COUNT='1'")),
    "sts2": (4, ("SLL_PCK_VARIANT='8x8'", "SLL_LANGUAGE='zh_CN'", "SLL_SWAP_AB='on'", "SLL_LAUNCH_COUNT='1'")),
    "terraria": (4, ("TER_WIDTH='auto'", "TER_LANGUAGE='7'", "TER_SWAP_AB='off'", "TER_LAUNCH_COUNT='1'")),
    "vampiresurvivors114": (2, ("VS_WIDTH='auto'", "VS_HEIGHT='auto'", "VS_SWAP_AB='off'", "VS_LAUNCH_COUNT='1'")),
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

# Persisted picker values are untrusted input: invalid values must fall back to
# defaults and generated shell environments must quote every value.
with tempfile.TemporaryDirectory() as source:
    marker = Path(source) / "would-run"
    (Path(source) / "state.txt").write_text(
        f"ui_lang=invalid\nlaunch_count=0\nquality=$(touch {marker})\n", encoding="utf-8"
    )
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().SOURCE = source
    lua.execute(mock)
    lua.execute(f"package.path={str(root / '_kit/love' / '?.lua')!r}..';'..package.path")
    lua.execute(r'''
        require("launcher").define({title={en="Test",zh="测试"},static_env={{"TEXT","it's safe"}},fields={
            require("launcher").select({key="quality",default="safe",
                options={{value="safe",label="Safe"},{value="fast",label="Fast"}},env="QUALITY"})
        }})
        love.load()
        local state=require("kit").get_state()
        assert(state.ui_lang=="zh" and state.quality=="safe")
        love.keypressed("down"); love.keypressed("return")
    ''')
    text = (Path(source) / "launch_config.env").read_text(encoding="utf-8")
    assert "QUALITY='safe'" in text and "TEXT='it'\"'\"'s safe'" in text, text
    assert "$(touch" not in text and not marker.exists(), text

# A failed atomic environment write keeps the launcher open and reports an
# ordinary retry/stay dialog instead of returning EXIT_START with stale config.
lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().SOURCE = "/definitely/missing/port/source"
lua.execute(mock)
lua.execute(f"package.path={str(root / '_kit/love' / '?.lua')!r}..';'..package.path")
lua.execute(r'''
    local k=require("kit")
    k.run({state={ui_lang="en",launch_count=0},
        build_pages=function() k.add_page("Test",{k.button("Start","start")}) end,
        write_env=function(out) out:write("VALUE=ok\n") end})
    love.load(); love.keypressed("return")
    assert(LAST_QUIT==nil and k.debug_dialog().open and k.debug_dialog().focus=="cancel")
''')

# A writer exception leaves the previous complete environment in place and
# removes the temporary file.
with tempfile.TemporaryDirectory() as source:
    old_env = Path(source) / "launch_config.env"
    old_env.write_text("OLD='complete'\n", encoding="utf-8")
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().SOURCE = source
    lua.execute(mock)
    lua.execute(f"package.path={str(root / '_kit/love' / '?.lua')!r}..';'..package.path")
    lua.execute(r'''
        local k=require("kit")
        k.run({state={ui_lang="en",launch_count=0},
            build_pages=function() k.add_page("Test",{k.button("Start","start")}) end,
            write_env=function() error("simulated write failure") end})
        love.load(); love.keypressed("return")
        assert(LAST_QUIT==nil and k.debug_dialog().open)
    ''')
    assert old_env.read_text(encoding="utf-8") == "OLD='complete'\n"
    assert not Path(str(old_env) + ".tmp").exists()

# The shared component API stays small but explicit: Select is the named form
# of the existing picker, Checkbox accepts an options table, and physical keys
# are translated to semantic actions before widgets see them.
with tempfile.TemporaryDirectory() as source:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().SOURCE = source
    lua.execute(mock)
    lua.execute(f"package.path={str(root / '_kit/love' / '?.lua')!r}..';'..package.path")
    lua.execute(r'''
        local k=require("kit")
        local changed=nil
        local select_row=k.select("Quality",{"safe","fast"},{safe="Safe",fast="Fast"},"quality",{id="quality"})
        local check_row=k.checkbox("Enabled",{id="enabled",detail="Optional feature",checked=false,
            on_change=function(value) changed=value end})
        local text_row=k.textview("Path","/roms",{label_px=16,value_px=18})
        local section_row=k.section("Paths",{font_px=22})
        assert(select_row.kind=="picker" and select_row.id=="quality")
        assert(check_row.kind=="checkbox" and check_row.id=="enabled" and check_row.detail=="Optional feature")
        assert(text_row.label_px==16 and text_row.value_px==18 and section_row.font_px==22)
        k.run({state={ui_lang="en",quality="safe"},input_map={z="confirm",x="cancel"},
            build_pages=function()
                k.add_page("Home",{select_row,check_row,k.button("Dialog",function()
                    k.dialog({title="Confirm",on_cancel=function() changed="cancelled" end})
                end,{id="dialog"})})
                k.add_page("Other",{k.button("Other",function() end,{id="other"})})
            end})
        love.load()
        love.keypressed("down"); love.keypressed("z")
        assert(check_row.checked and changed==true)
        love.keypressed("down"); love.keypressed("z")
        local before=k.debug_focus()
        assert(k.debug_dialog().open and k.debug_dialog().scope_depth==1)
        -- A programmatic page change cannot steal the modal's return target.
        k.set_page(1,"Home",{k.button("Inserted",function() end,{id="inserted"}),
            select_row,check_row,k.button("Dialog",function() end,{id="dialog"})},{preserve_focus=true})
        k.goto_page(2); k.close_dialog()
        local after=k.debug_focus()
        assert(k.debug_page().index==1 and after.zone==before.zone and after.focus_i==before.focus_i+1)
        k.dialog({title="Confirm",on_cancel=function() changed="cancelled" end})
        love.keypressed("x")
        assert(changed=="cancelled" and not k.debug_dialog().open)
        k.input("up")
        assert(k.debug_focus().focus_i==3)
    ''')

# Checkbox visuals are drawn as a real control, not font-dependent square/check
# glyphs. The selected state adds a vector checkmark to the custom box.
with tempfile.TemporaryDirectory() as source:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().SOURCE = source
    lua.execute(mock)
    lua.execute(f"package.path={str(root / '_kit/love' / '?.lua')!r}..';'..package.path")
    lua.execute(r'''
        local printed={}
        local line_calls=0
        love.graphics.print=function(value) printed[#printed+1]=tostring(value) end
        love.graphics.line=function() line_calls=line_calls+1 end
        local k=require("kit")
        local row=k.checkbox("Port",{detail="Required by several games with long names that must wrap onto more than one line",detail_max_lines=3,height=96,checked=false})
        k.run({state={ui_lang="en"},theme={kind="app"},build_pages=function()
            k.add_page("Manager",{row},{row_layout={mode="flow",max_columns=1,min_width=300}})
        end})
        love.load(); love.draw()
        local layout=k.debug_layout()
        assert(layout.geometry[1].h>layout.rh)
        for _,value in ipairs(printed) do
            assert(not value:find("□",1,true) and not value:find("✓",1,true))
        end
        local unchecked_lines=line_calls
        printed={}; line_calls=0
        k.input("confirm"); love.draw()
        assert(row.checked and line_calls>unchecked_lines)
        for _,value in ipairs(printed) do
            assert(not value:find("□",1,true) and not value:find("✓",1,true))
        end
    ''')

# Select renders its value once as crisp centred text inside a custom control,
# with vector chevrons instead of fuzzy font characters around the value.
with tempfile.TemporaryDirectory() as source:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().SOURCE = source
    lua.execute(mock)
    lua.execute(f"package.path={str(root / '_kit/love' / '?.lua')!r}..';'..package.path")
    lua.execute(r'''
        local printed={}
        local line_calls,rectangle_calls=0,0
        love.graphics.printf=function(value) printed[#printed+1]=tostring(value) end
        love.graphics.line=function() line_calls=line_calls+1 end
        love.graphics.rectangle=function() rectangle_calls=rectangle_calls+1 end
        local k=require("kit")
        local row=k.select("Quality",{"safe","fast"},{safe="Safe",fast="Fast"},"quality")
        k.run({state={ui_lang="en",quality="safe"},build_pages=function()
            k.add_page("Launcher",{row})
        end})
        love.load(); love.draw()
        local value_count=0
        for _,value in ipairs(printed) do
            if value=="Safe" then value_count=value_count+1 end
            assert(value~="< Safe >")
        end
        assert(value_count==1 and line_calls>=2 and rectangle_calls>=4)
    ''')

# Body typography renders once on integer pixel coordinates. Only the large
# page title keeps one light shadow pass plus its foreground pass.
with tempfile.TemporaryDirectory() as source:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().SOURCE = source
    lua.execute(mock)
    lua.execute(f"package.path={str(root / '_kit/love' / '?.lua')!r}..';'..package.path")
    lua.execute(r'''
        local draws={}
        local current_font=nil
        love.graphics.newFont=function(size)
            local f={size=tonumber(size) or 20}
            f.getHeight=function(self) return self.size end
            f.getWidth=function(self,text) return #text*self.size*0.5 end
            f.getWrap=function(self,text,limit) return limit,{text} end
            return f
        end
        love.graphics.setFont=function(font) current_font=font end
        local function record(value,x,y)
            value=tostring(value)
            draws[value]=draws[value] or {}
            draws[value][#draws[value]+1]={x=x,y=y,size=current_font.size}
        end
        love.graphics.print=record
        love.graphics.printf=function(value,x,y) record(value,x,y) end
        local k=require("kit")
        k.run({state={ui_lang="en",feature="on"},theme={kind="app"},build_pages=function()
            k.add_page("Manager",{
                k.section("Installed"),
                k.list_item("frt_3.6"),k.list_item("godot_4.5"),
                k.switch("Feature","feature"),
                k.checkbox("Port",{checked=false}),
            },{row_layout={mode="grid",columns=2}})
        end})
        love.load(); love.draw()
        assert(#(draws.Manager or {})==2)
        assert(draws.Manager[2].size==40)
        assert(draws.Installed[1].size==23)
        assert(draws["frt_3.6"][1].size==19)
        assert(draws.Feature[1].size==26 and draws.Port[1].size==26)
        for _,value in ipairs({"Installed","frt_3.6","godot_4.5","Feature","Port"}) do
            local items=draws[value] or {}
            assert(#items==1,value)
            assert(items[1].x==math.floor(items[1].x) and items[1].y==math.floor(items[1].y),value)
        end
    ''')

# The launcher passes the validated PortMaster font's real path. Kit reads it
# once as FileData and shares that same object across every requested size,
# instead of requiring a copied font.ttf inside each launcher directory.
with tempfile.TemporaryDirectory() as source:
    local_copy = Path(source) / "font.ttf"
    local_copy.write_bytes(b"old-per-launcher-copy")
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().SOURCE = source
    lua.execute(mock)
    lua.execute(f"package.path={str(root / '_kit/love' / '?.lua')!r}..';'..package.path")
    lua.execute(r'''
        local system_font="/PortMaster/resources/NotoSansSC-Regular.ttf"
        local original_getenv,original_open=os.getenv,io.open
        local reads,new_fonts=0,0
        local shared_data=nil
        os.getenv=function(key)
            if key=="LOVE_FONT_PATH" then return system_font end
            return original_getenv(key)
        end
        io.open=function(path,mode)
            if path==system_font then
                return {read=function() reads=reads+1; return "validated-font-data" end,
                    close=function() end}
            end
            return original_open(path,mode)
        end
        love.filesystem.newFileData=function(contents,name)
            assert(contents=="validated-font-data" and name:match("%.ttf$"))
            shared_data={kind="font-data"}; return shared_data
        end
        local font={getHeight=function() return 20 end,getWidth=function(_,text) return #text*10 end,
            getWrap=function(_,text,limit) return limit,{text} end}
        love.graphics.newFont=function(source,size)
            assert(source==shared_data and type(size)=="number")
            new_fonts=new_fonts+1; return font
        end
        love.filesystem.getInfo=function(path)
            assert(path~="font.ttf","system font must not require a local copy")
            return nil
        end
        local k=require("kit")
        k.run({state={ui_lang="en"},build_pages=function()
            k.add_page("Font",{k.button("One",function() end),k.info("Two","Value")})
        end})
        love.load(); love.draw()
        assert(reads==1 and new_fonts>1)
    ''')
    assert not local_copy.exists()

# Measured Grid/Flow geometry is cached independently of focus and scroll.
# Expanding a TextView invalidates the measurement and produces a new height.
with tempfile.TemporaryDirectory() as source:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().SOURCE = source
    lua.execute(mock)
    lua.execute(f"package.path={str(root / '_kit/love' / '?.lua')!r}..';'..package.path")
    lua.execute(r'''
        local k=require("kit")
        local row=k.textview("Long",string.rep("long value ",80),{id="long"})
        k.run({state={ui_lang="en"},theme={kind="app"},build_pages=function()
            k.add_page("Cache",{row},{row_layout={mode="grid",columns=2}})
        end})
        love.load()
        local before=k.debug_layout_cache()
        local compact=k.debug_layout()
        local measured=k.debug_layout_cache()
        k.debug_layout()
        local reused=k.debug_layout_cache()
        assert(measured.misses==before.misses+1 and reused.hits==measured.hits+1)
        k.input("confirm")
        local expanded=k.debug_layout()
        local invalidated=k.debug_layout_cache()
        assert(invalidated.misses==reused.misses+1)
        assert(expanded.geometry[1].h>compact.geometry[1].h)
        k.invalidate_layout()
        k.debug_layout()
        assert(k.debug_layout_cache().misses==invalidated.misses+1)
    ''')

# Sidebar context is resolved from the focused row's stable key, never its
# current array position. Inserting a row while preserving focus keeps the
# matching explanation.
with tempfile.TemporaryDirectory() as source:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().SOURCE = source
    lua.execute(mock)
    lua.execute(f"package.path={str(root / '_kit/love' / '?.lua')!r}..';'..package.path")
    lua.execute(r'''
        local k=require("kit")
        local details={a={title="A",body="About A"},b={title="B",body="About B"}}
        local page
        k.run({state={ui_lang="en"},theme={kind="app"},build_pages=function()
            page=k.add_page("Keyed",{k.textview("A","1",{id="a"}),k.textview("B","2",{id="b"})},
                {sidebar_details=details})
        end})
        love.load(); k.input("down")
        assert(k.debug_sidebar_detail().key=="b")
        k.set_page(page,"Keyed",{k.textview("Inserted","0",{id="new"}),
            k.textview("A","1",{id="a"}),k.textview("B","2",{id="b"})},
            {preserve_focus=true,sidebar_details=details})
        local detail=k.debug_sidebar_detail()
        assert(k.debug_focus().focus_i==3 and detail.key=="b" and detail.body=="About B")
    ''')

# Switch is a state-bound boolean control: Left/Right set an exact value and
# Confirm toggles it. Declarative launcher.toggle fields render through it.
with tempfile.TemporaryDirectory() as source:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().SOURCE = source
    lua.execute(mock)
    lua.execute(f"package.path={str(root / '_kit/love' / '?.lua')!r}..';'..package.path")
    lua.execute(r'''
        local k=require("kit")
        local changes={}
        local switch_row=k.switch("Feature","feature",{id="feature",off_value="disabled",on_value="enabled",
            on_change=function(on,value) changes[#changes+1]={on,value} end})
        assert(switch_row.kind=="switch" and switch_row.id=="feature")
        k.run({state={ui_lang="en",feature="disabled"},build_pages=function()
            k.add_page("Switch",{switch_row})
        end})
        love.load(); love.draw()
        k.input("right")
        assert(k.get_state().feature=="enabled" and changes[1][1]==true and changes[1][2]=="enabled")
        k.input("left")
        assert(k.get_state().feature=="disabled" and changes[2][1]==false and changes[2][2]=="disabled")
        k.input("confirm")
        assert(k.get_state().feature=="enabled" and changes[3][1]==true)
        switch_row.disabled=true
        k.input("left")
        assert(k.get_state().feature=="enabled" and #changes==3)
    ''')

with tempfile.TemporaryDirectory() as source:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().SOURCE = source
    lua.execute(mock)
    lua.execute(f"package.path={str(root / '_kit/love' / '?.lua')!r}..';'..package.path")
    lua.execute(r'''
        local k=require("kit")
        local original=k.switch
        local switch_calls=0
        k.switch=function(...) switch_calls=switch_calls+1; return original(...) end
        require("launcher").define({title="Toggle",fields={
            require("launcher").toggle({key="enabled",label="Enabled",default="on",env="ENABLED"})
        }})
        love.load()
        assert(switch_calls==1 and k.get_state().enabled=="on")
    ''')

# Switch needs no redundant On/Off copy: its label, track and knob share one
# centre line, while position and colour communicate the boolean state.
with tempfile.TemporaryDirectory() as source:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().SOURCE = source
    lua.execute(mock)
    lua.execute(f"package.path={str(root / '_kit/love' / '?.lua')!r}..';'..package.path")
    lua.execute(r'''
        local current_font=nil
        local label_y,label_h,track_cy,knob_cy
        local status_seen=false
        love.graphics.newFont=function(size)
            local f={size=tonumber(size) or 20}
            f.getHeight=function(self) return self.size end
            f.getWidth=function(self,text) return #text*self.size*0.5 end
            f.getWrap=function(self,text,limit) return limit,{text} end
            return f
        end
        love.graphics.setFont=function(font) current_font=font end
        love.graphics.print=function(value,x,y)
            if value=="Feature" then label_y,label_h=y,current_font.size end
        end
        love.graphics.printf=function(value,x,y)
            if value=="On" or value=="Off" then status_seen=true end
        end
        love.graphics.rectangle=function(mode,x,y,w,h)
            if mode=="fill" and w/h>2 and w/h<2.5 then track_cy=y+h/2 end
            if mode=="fill" and math.abs(w-h)<0.01 and w<40 then knob_cy=y+h/2 end
        end
        local k=require("kit")
        k.run({state={ui_lang="en",feature="on"},theme={kind="app"},build_pages=function()
            k.add_page("Switch",{k.switch("Feature","feature")})
        end})
        love.load(); love.draw()
        assert(label_y and track_cy and knob_cy)
        assert(not status_seen)
        assert(math.abs((label_y+label_h/2)-track_cy)<=0.75)
        assert(math.abs(knob_cy-track_cy)<0.01)
    ''')

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
    (base / "libs" / "frt_3.6.squashfs").write_bytes(b"hsqs")
    (base / "libs" / "godot_4.5.squashfs").write_bytes(b"hsqs")
    (scripts / "Game.sh").write_text(
        'GAMEDIR="/' + str(data).lstrip('/') + '/GameData"\nruntime=godot_4.6.3\n',
        encoding="utf-8",
    )
    (scripts / "Installed.sh").write_text(
        'GAMEDIR="/' + str(data).lstrip('/') + '/GameData"\nruntime=godot_4.5\n',
        encoding="utf-8",
    )
    env_path = app / "conf/env.json"
    env_path.write_text(json.dumps({
        "controlfolder": str(base / "PortMaster"), "scripts_dir": str(scripts),
        "gamedirs_dir": str(data), "images_dir": str(base / "images"),
        "libs_dir": str(base / "libs"), "gamedir": str(app), "directory": str(data).lstrip('/'),
        "home": str(base), "cfw": "test", "free_bytes": 1024,
        "display_width": "960", "display_height": "720", "device_arch": "aarch64",
        "device": "test", "plan_file": str(app / "conf/plan.txt"),
        "result_file": str(app / "conf/result.txt"), "apply_script": "",
        "size_file": str(app / "conf/sizes.tsv"),
        "runtime_catalog_file": str(root / "ports/appmanager/love/runtime_catalog.tsv"),
        "ignore_dirs": ["PortMaster", "images", "appmanager"],
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
        str(scripts): [
            {"name": "Game.sh", "path": str(scripts / "Game.sh"), "is_dir": False},
            {"name": "Installed.sh", "path": str(scripts / "Installed.sh"), "is_dir": False},
        ],
        str(base / "images"): [],
        str(base / "libs"): [
            {"name": "frt_3.6.squashfs", "path": str(base / "libs" / "frt_3.6.squashfs"), "is_dir": False},
            {"name": "godot_4.5.squashfs", "path": str(base / "libs" / "godot_4.5.squashfs"), "is_dir": False},
        ],
        str(app / "trash"): [],
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
    lua.execute(r'''
        local page=require("kit").debug_page()
        assert(page.title=="Port App Manager")
        assert(#page.sidebar_footer_lines==2)
        assert(page.sidebar_footer_lines[1]=="开发: Bili 解腻Jenny")
        assert(page.sidebar_footer_lines[2]=="QQ 群 1047158975")
    ''')
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
    # Permanent deletion is a one-shot, explicit sidebar checkbox. It changes
    # the uninstall dialog to an irreversible warning; Select All/None still
    # retain their stable sidebar focus when the dynamic page rebuilds.
    lua.execute(r'''
        local k=require("kit")
        love.keypressed("right")
        local before=k.debug_focus()
        assert(before.zone=="sidebar" and before.sidebar_i==2)
        love.keypressed("return")
        assert(k.debug_focus().sidebar_i==2)
        love.keypressed("left"); love.keypressed("return"); love.keypressed("right")
        assert(k.debug_focus().sidebar_i==1)
        love.keypressed("return")
        local direct=k.debug_dialog()
        assert(direct.open and direct.danger and direct.title=="永久删除所选端口")
        assert(direct.message:find("无法恢复",1,true))
        -- Cancelling clears the one-shot option; the same uninstall is now reversible.
        love.keypressed("escape"); love.keypressed("return")
        local reversible=k.debug_dialog()
        assert(reversible.open and not reversible.danger and reversible.title=="将所选端口移入回收站")
        love.keypressed("escape")
        -- Move past Trash to the paired Select All / Select None row.
        love.keypressed("down"); love.keypressed("down"); love.keypressed("down")
        before=k.debug_focus()
        assert(before.zone=="sidebar" and before.sidebar_i==4)
        love.keypressed("return")
        local selected=k.debug_focus()
        assert(selected.zone==before.zone and selected.sidebar_i==before.sidebar_i)
        love.keypressed("right"); love.keypressed("return")
        local cleared=k.debug_focus()
        assert(cleared.zone=="sidebar" and cleared.sidebar_i==5)
        love.keypressed("left"); love.keypressed("left")
        assert(k.debug_focus().zone=="rows")
    ''')
    # Environment details use three sections: 4 key paths, 16 environment
    # values, then a counted compact list of installed runtimes.
    lua.execute(r'''
        local k=require("kit")
        love.keypressed("up"); love.keypressed("return")
        local page=k.debug_page()
        assert(page.index==4 and page.section_count==3 and page.row_count==25)
        assert(page.section_labels[3]=="已安装 Runtime（2）")
        assert(page.row_kinds[24]=="list_item" and page.row_kinds[25]=="list_item")
        assert(page.row_font_px[1]==22 and page.row_label_px[2]==16 and page.row_value_px[2]==18)
        assert(page.row_font_px[24]==19)
        assert(k.debug_focus().zone=="rows" and k.debug_focus().focus_i==2)
        local detail=k.debug_sidebar_detail()
        assert(detail.key=="path:scripts" and detail.title=="SH 启动脚本目录")
        assert(detail.body:find("启动脚本",1,true))
        local layout=k.debug_layout()
        assert(layout.row_layout_mode=="grid" and layout.columns==2)
        assert(layout.geometry[2].x < layout.geometry[3].x)
        assert(layout.geometry[2].y == layout.geometry[3].y)
        assert(layout.geometry[2].h == layout.geometry[3].h)
        assert(layout.geometry[24].h < layout.rh and layout.geometry[25].h < layout.rh)
        love.keypressed("right")
        assert(k.debug_focus().focus_i==3)
        detail=k.debug_sidebar_detail()
        assert(detail.key=="path:data" and detail.title=="游戏数据目录")
        assert(detail.body:find("游戏数据",1,true))
        love.keypressed("down")
        assert(k.debug_focus().focus_i==5)
        love.draw(); love.keypressed("escape")
    ''')
    # Missing Runtimes have their own selectable repair page. The official
    # catalog controls whether the current architecture can repair each item.
    lua.execute(r'''
        local k=require("kit")
        k.goto_page(1); love.keypressed("right")
        for _=1,12 do
            local focus=k.debug_focus()
            if focus.zone=="sidebar" and focus.sidebar_i==7 then break end
            love.keypressed("down")
        end
        assert(k.debug_focus().sidebar_i==7)
        love.keypressed("return")
        local page=k.debug_page()
        assert(page.index==5 and page.title=="Runtime 修复" and page.row_count==4)
        assert(page.section_count==2 and page.section_labels[1]=="需要修复（1）")
        assert(page.section_labels[2]=="已安装（1）")
        assert(page.row_kinds[1]=="section" and page.row_kinds[2]=="checkbox")
        assert(page.row_kinds[3]=="section" and page.row_kinds[4]=="checkbox")
        local layout=k.debug_layout()
        assert(layout.row_layout_mode=="flow" and layout.columns==1)
        assert(layout.geometry[2].h>layout.rh and k.debug_focus().focus_i==2)
        -- The missing item starts selected, so Repair immediately confirms one.
        love.keypressed("right")
        local repair_focus=k.debug_focus()
        assert(repair_focus.zone=="sidebar" and repair_focus.sidebar_i==1,
            "Runtime row should enter the primary Repair action")
        love.keypressed("return")
        local dialog=k.debug_dialog()
        assert(dialog.open and not dialog.danger and dialog.item_count==1,
            "missing Runtime should be the only default repair")
        -- An installed item is opt-in; selecting it adds a second forced repair.
        love.keypressed("escape"); love.keypressed("left"); love.keypressed("down")
        assert(k.debug_focus().focus_i==4)
        love.keypressed("return"); love.keypressed("right")
        repair_focus=k.debug_focus()
        if repair_focus.sidebar_i~=1 then love.keypressed("up") end
        love.keypressed("return")
        dialog=k.debug_dialog()
        assert(dialog.open and dialog.item_count==2,"installed Runtime should be an opt-in repair")
        love.keypressed("escape"); k.goto_page(1)
    ''')
    # Flow layout derives its column count from the available width, while all
    # cards in one visual row share the tallest wrapped TextView height.
    lua.execute(r'''
        local k=require("kit")
        local flow=k.add_page("Flow",{
            k.textview("Long","This value is deliberately long enough to wrap across several lines inside a card."),
            k.textview("Short","OK"),
            k.textview("Third","Another card"),
        },{row_layout={mode="flow",min_width=250}})
        k.goto_page(flow)
        local L=k.debug_layout()
        assert(L.row_layout_mode=="flow" and L.columns==2)
        assert(L.geometry[1].y==L.geometry[2].y and L.geometry[1].h==L.geometry[2].h)
        assert(L.geometry[1].h>L.rh)
        love.keypressed("right"); assert(k.debug_focus().focus_i==2)
        love.keypressed("down"); assert(k.debug_focus().focus_i==3)
        love.keypressed("right"); assert(k.debug_focus().focus_i==3)
        k.goto_page(1)
    ''')
    # Moving right from the lowest grid row chooses the spatially closest
    # bottom sidebar action rather than jumping to its first action.
    lua.execute(r'''
        local k=require("kit"); local rows={}
        for i=1,12 do rows[i]=k.textview("Row "..i,"Value") end
        local cross=k.add_page("Cross",rows,{row_layout={mode="grid",columns=2},sidebar={
            k.button("Top",function() end),k.button("Bottom",function() end,{group="bottom"})}})
        k.goto_page(cross); love.keypressed("right")
        for _=1,5 do love.keypressed("down") end
        assert(k.debug_focus().focus_i==12)
        love.keypressed("right")
        assert(k.debug_focus().zone=="sidebar" and k.debug_focus().sidebar_i==2)
        k.goto_page(1)
    ''')
    # Sidebar navigation follows visual rows: Down skips the right half of the
    # current row, while Right still crosses between paired half buttons.
    lua.execute(r'''
        local k=require("kit")
        local sidebar_page=k.add_page("Sidebar",{k.button("Row",function() end)},{sidebar={
            k.button("Full",function() end),k.button("Left",function() end,{half=true}),
            k.button("Right",function() end,{half=true}),k.button("Next",function() end)}})
        k.goto_page(sidebar_page); love.keypressed("right"); love.keypressed("down")
        assert(k.debug_focus().sidebar_i==2)
        love.keypressed("down"); assert(k.debug_focus().sidebar_i==4)
        love.keypressed("up"); assert(k.debug_focus().sidebar_i==2)
        love.keypressed("right"); assert(k.debug_focus().sidebar_i==3)
        k.goto_page(1)
    ''')
    # preserve_focus follows a stable row id across insertions rather than
    # retaining an index that now names another action.
    lua.execute(r'''
        local k=require("kit")
        local function b(name) return k.button(name,function() LAST_ACTION=name end,{id=name}) end
        local stable=k.add_page("Stable",{b("A"),b("B"),b("C")})
        k.goto_page(stable); love.keypressed("down")
        k.set_page(stable,"Stable",{b("X"),b("A"),b("B"),b("C")},{preserve_focus=true})
        love.keypressed("return"); assert(LAST_ACTION=="B" and k.debug_focus().focus_i==3)
        love.keypressed("down")
        k.set_page(stable,"Stable",{b("A"),b("B")},{preserve_focus=true})
        love.keypressed("return"); assert(LAST_ACTION=="B" and k.debug_focus().focus_i==2)
        k.goto_page(1)
    ''')
    # TextViews default to a compact two-line value, expose an ellipsis, and
    # expand on A without ever becoming taller than the viewport.
    lua.execute(r'''
        local k=require("kit"); local long=string.rep("very long value ",400)
        local text_page=k.add_page("Text",{k.textview("Long",long)},{row_layout={mode="grid",columns=2}})
        k.goto_page(text_page); local compact=k.debug_layout()
        assert(compact.geometry[1].h<compact.band/2)
        love.keypressed("return"); local expanded=k.debug_layout()
        assert(expanded.geometry[1].h>compact.geometry[1].h and expanded.geometry[1].h<=expanded.band)
        love.keypressed("return"); assert(k.debug_layout().geometry[1].h==compact.geometry[1].h)
        k.goto_page(1)
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
