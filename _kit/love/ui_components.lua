-- INPUT:  Vendored LUIS widgets, shared theme and Kit semantic activation
-- OUTPUT: surface/checkbox/switch drawing, activate and reset component adapter
-- POS:    Pixel-native LUIS component backend; Kit remains the sole focus owner
local unpack = unpack or table.unpack
local theme = require("ui_theme")
local Button = require("luis.widgets.button")
local CheckBox = require("luis.widgets.checkBox")
local Switch = require("luis.widgets.switch")
local flux = require("luis.3rdparty.flux")
local context = {gridSize=1,theme={text={}},flux=flux}
Button.setluis(context); CheckBox.setluis(context); Switch.setluis(context)
local components = {}
local owners, surfaces, cursor

function components.reset()
    owners=setmetatable({}, {__mode="k"})
    surfaces={}; cursor=0
    -- Widgets settle during semantic input; no animation timer survives a page.
    for i=#flux.tweens,1,-1 do flux.remove(i) end
end
components.reset()

local function control(owner,kind)
    local bundle=owners[owner]
    if not bundle then bundle={}; owners[owner]=bundle end
    if not bundle[kind] then
        local style={}
        if kind=="checkbox" then
            theme.checkbox(style,false,false,1)
            bundle[kind]=CheckBox.new(false,1,nil,1,1,style)
        elseif kind=="switch" then
            theme.switch(style,false)
            bundle[kind]=Switch.new(false,1,1,nil,1,1,style)
        else
            theme.button(style,false,false,false,1)
            bundle[kind]=Button.new("",1,1,nil,nil,1,1,style)
        end
    end
    return bundle[kind]
end

function components.begin_frame() cursor=0 end

function components.surface(x,y,w,h,focused,is_disabled,owner,danger,appearance)
    if not owner then
        cursor=cursor+1
        surfaces[cursor]=surfaces[cursor] or {}
        owner=surfaces[cursor]
    end
    local widget=control(owner,"button")
    theme.button(widget.theme,focused,is_disabled,danger,h,appearance)
    widget.position.x,widget.position.y=x,y
    widget.width,widget.height=w,h
    widget.focused=focused and not is_disabled
    widget.colorR,widget.colorG,widget.colorB,widget.colorA=unpack(widget.theme.color)
    widget:draw()
end

function components.checkbox(owner,x,y,size,value,is_disabled)
    local widget=control(owner,"checkbox")
    widget.position.x,widget.position.y=x,y
    widget.width,widget.height=size,size
    widget.value,widget.checkScale=value,value and 1 or 0
    widget.focused=false -- The containing row draws the single focus ring.
    theme.checkbox(widget.theme,value,is_disabled,size)
    widget:draw()
end

function components.switch(owner,x,y,w,h,value,is_disabled)
    local widget=control(owner,"switch")
    widget.position.x,widget.position.y=x,y
    widget.width,widget.height=w,h
    widget.value,widget.focused=value,false
    theme.switch(widget.theme,is_disabled)
    widget:draw()
end

-- Kit supplies one completed confirm action, including key-repeat semantics.
-- Route it through LUIS once, rather than polling another controller/focus loop.
function components.activate(owner,kind,value,callback)
    local widget=control(owner,kind)
    widget.value,widget.focused=value,true
    if kind=="button" then
        widget.onRelease=callback
        widget:gamepadpressed(1,"a")
        widget:gamepadreleased(1,"a")
        widget.onRelease=nil
    else
        widget.onChange=callback
        widget:gamepadpressed(1,"a")
        widget.onChange=nil
    end
    -- Handheld actions are immediate. Finish the library tween now so an idle
    -- page never starts polling or continuously redrawing for component effects.
    flux.update(1)
end

return components
