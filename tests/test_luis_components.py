#!/usr/bin/env python3
# INPUT:  Shared Kit/LUIS modules, Lua 5.1/5.4 via lupa and isolated UI payload
# OUTPUT: Real component dispatch, pixel bounds, idle and packaging assertions
# POS:    LUIS integration regression without a device or filesystem operations
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

try:
    from lupa.lua51 import LuaRuntime as Lua51
    from lupa.lua54 import LuaRuntime as Lua54
except ImportError:
    if os.environ.get("PAM_REQUIRE_LUPA") == "1":
        raise SystemExit("LUIS tests require lupa with Lua 5.1 and 5.4")
    raise SystemExit("LUIS tests: SKIP (lupa unavailable)")

ROOT = Path(__file__).resolve().parents[1]
KIT = ROOT / "_kit/love"
DRAW_MOCK = r'''
love={graphics={}}
rects={}; circles={}; lines=0
love.graphics.setColor=function() end
love.graphics.setLineWidth=function() end
love.graphics.rectangle=function(mode,x,y,w,h)
    rects[#rects+1]={mode=mode,x=x,y=y,w=w,h=h}
end
love.graphics.circle=function(mode,x,y,r) circles[#circles+1]={x=x,y=y,r=r} end
love.graphics.line=function() lines=lines+1 end
-- LOVE-lite has neither utf8 nor a real standard LÖVE joystick backend.
package.loaded.utf8=nil; package.preload.utf8=nil
package.preload.utf8=function() error("unused UTF-8 dependency loaded") end
'''


class LuisComponents(unittest.TestCase):
    def runtimes(self):
        for runtime in (Lua51, Lua54):
            lua = runtime(unpack_returned_tuples=True)
            lua.execute(f"package.path={str(KIT / '?.lua')!r}..';'..package.path")
            lua.execute(DRAW_MOCK)
            yield lua

    def test_real_widgets_render_and_dispatch_once(self):
        for lua in self.runtimes():
            lua.execute(r'''
                local buttons=require("luis.widgets.button")
                local checks=require("luis.widgets.checkBox")
                local switches=require("luis.widgets.switch")
                local pressed,drawn=0,0
                for _,module in ipairs({buttons,checks,switches}) do
                    local original=module.new
                    module.new=function(...)
                        local widget=original(...)
                        local press,draw=widget.gamepadpressed,widget.defaultDraw
                        widget.gamepadpressed=function(self,...)
                            pressed=pressed+1; return press(self,...)
                        end
                        widget.defaultDraw=function(self,...)
                            drawn=drawn+1; return draw(self,...)
                        end
                        return widget
                    end
                end
                local c=require("ui_components")
                local action,check,switch={},{},{}
                local actions,check_changes,switch_changes=0,0,0
                c.begin_frame()
                c.surface(10,20,120,40,true,false,action)
                c.checkbox(check,20,30,20,false,false)
                c.switch(switch,30,40,60,24,true,false)
                assert(drawn==3 and pressed==0)
                c.activate(action,"button",nil,function() actions=actions+1 end)
                c.activate(check,"checkbox",false,function(on)
                    assert(on); check_changes=check_changes+1
                end)
                c.activate(switch,"switch",true,function(on)
                    assert(not on); switch_changes=switch_changes+1
                end)
                assert(pressed==3 and actions==1 and check_changes==1 and switch_changes==1)
                -- Repainting a row never invokes the action or restarts a tween.
                for i=1,50 do c.begin_frame(); c.surface(10,20,120,40,true,false,action) end
                assert(actions==1 and pressed==3 and #require("luis.3rdparty.flux").tweens==0)
                c.activate(action,"button",nil,function() actions=actions+10 end)
                assert(actions==11) -- Refreshed callback, not the previous closure.
                c.reset()
                assert(#require("luis.3rdparty.flux").tweens==0)
            ''')

    def test_focus_border_and_controls_stay_inside_bounds(self):
        for lua in self.runtimes():
            lua.execute(r'''
                local c=require("ui_components")
                c.begin_frame(); c.surface(10,20,120,40,true,false,{})
                assert(#rects==2) -- Flat surface, no transparent shadow draw.
                for _,r in ipairs(rects) do
                    assert(r.x>=10 and r.y>=20 and r.x+r.w<=130 and r.y+r.h<=60)
                end
                c.checkbox({},20,30,24,true,false)
                assert(lines==1) -- Real vector check; no font glyph dependency.
                c.switch({},30,40,60,24,true,false)
                local knob=circles[#circles]
                assert(knob.x+knob.r<=90 and knob.x-knob.r>=30)
                assert(knob.y+knob.r<=64 and knob.y-knob.r>=40)
            ''')

    def test_staged_payload_is_self_contained(self):
        with tempfile.TemporaryDirectory() as temp:
            destination = Path(temp) / "love_ui"
            subprocess.run(["bash", str(ROOT / "_kit/stage_love_ui.sh"), str(destination)], check=True)
            self.assertIn("Additional Terms", (destination / "luis/LICENSE").read_text())
            self.assertIn("2016 rxi", (destination / "luis/LICENSE-flux.txt").read_text())
            self.assertIn("Redistribution", (destination / "qrcode/LICENSE").read_text())
            self.assertFalse(list(destination.rglob("AGENTS.md")))
            self.assertFalse(list(destination.rglob("._*")))
            lua = Lua51(unpack_returned_tuples=True)
            lua.execute(f"package.path={str(destination / '?.lua')!r}")
            lua.execute(DRAW_MOCK)
            lua.execute('local c=require("ui_components"); c.begin_frame(); c.surface(0,0,100,30,true,false,{}); assert(#require("qr_view").matrix("http://192.0.2.91:8080/123456")==25)')


if __name__ == "__main__":
    unittest.main()
