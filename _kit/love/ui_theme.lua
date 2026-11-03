-- INPUT:  Control focus, disabled/danger states and physical-pixel geometry
-- OUTPUT: Shared UI palette, App content scale and LUIS control theme tables
-- POS:    Purple-cat component palette for launchers and App Manager
local theme = {}
theme.background = {0.098,0.098,0.122,1}
theme.navigation_background = {0.071,0.071,0.090,1}
theme.divider = {0.188,0.188,0.224,1}
theme.surface = {0.137,0.133,0.169,1}
theme.review_surface = {0.173,0.161,0.204,1}
theme.review_header = theme.review_surface
theme.review_border = {0.333,0.314,0.369,1}
theme.focused = {0.23,0.15,0.34,0.98}
theme.app_focused = {0.165,0.145,0.212,1}
theme.border = {0.227,0.216,0.263,1}
theme.focus_border = {0.796,0.710,0.929,1}
theme.disabled = {0.13,0.13,0.15,0.92}
theme.disabled_border = {0.34,0.33,0.38,0.48}
theme.text = {0.953,0.941,0.973,1}
theme.muted = {0.635,0.616,0.671,1}
theme.accent = {0.816,0.729,0.969,1}

function theme.scale(width,height)
    if width<600 then return math.min(math.max(0.60,math.min(0.80,height/480)),width/480,height/320) end
    return math.min(math.max(0.80,math.min(1,height/720)),width/640,height/480)
end

function theme.button(style,focused,is_disabled,danger,height,appearance)
    local color,border=theme.surface,theme.border
    if appearance=="list" then color,border={0,0,0,0},{0,0,0,0} end
    if appearance=="navigation" or appearance=="tab" or appearance=="quiet" then color,border={0,0,0,0},{0,0,0,0} end
    if appearance=="selected" then color,border={0.141,0.125,0.184,1},{0,0,0,0} end
    if appearance=="tab_active" then color,border={0.16,0.12,0.23,1},{0,0,0,0} end
    if appearance=="action" or appearance=="secondary" then color,border={0.153,0.145,0.176,1},theme.border end
    if appearance=="primary" then color,border={0.38,0.25,0.57,1},{0,0,0,0} end
    if appearance=="toolbar" then color,border={0.227,0.200,0.282,1},{0.345,0.306,0.404,1} end
    if focused then color,border=appearance and theme.app_focused or theme.focused,theme.focus_border end
    if focused and appearance=="primary" then color={0.45,0.30,0.66,1} end
    if focused and appearance=="toolbar" then color={0.294,0.243,0.376,1} end
    if danger then
        color=focused and {0.34,0.19,0.23,1} or {0.259,0.180,0.216,1}
        border=focused and {1,0.65,0.69,1} or {0.502,0.325,0.373,1}
    end
    if is_disabled then color,border=theme.disabled,theme.disabled_border end
    style.color,style.hoverColor,style.pressedColor=color,color,color
    style.borderColor=border
    style.borderWidth=focused and not is_disabled and 2 or 1
    style.cornerRadius=math.max(4,math.min(10,height*0.20))
    style.elevation,style.elevationHover,style.elevationPressed=0,0,0
    style.transitionDuration=0.10
    style.textColor,style.align=theme.text,"left"
end

function theme.checkbox(style,checked,is_disabled,size)
    style.boxColor=is_disabled and theme.disabled or checked and {0.84,0.70,1,1} or {0.045,0.03,0.07,0.96}
    style.borderColor=is_disabled and theme.disabled_border or theme.focus_border
    style.checkColor=is_disabled and theme.disabled or {0.12,0.055,0.20,1}
    style.cornerRadius=math.max(3,size*0.18)
    style.borderWidth=math.max(1,size*0.055)
    style.vectorCheck=true
end

function theme.switch(style,is_disabled)
    style.onColor=is_disabled and theme.disabled or {0.475,0.314,0.694,1}
    style.offColor={0.24,0.23,0.28,1}
    style.knobColor=is_disabled and {0.48,0.47,0.51,1} or theme.text
end

return theme
