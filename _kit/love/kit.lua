-- INPUT:  LÖVE 接口、LUIS 组件适配器、focus_view 与端口页面声明
-- OUTPUT: kit 组件、页面导航、对话框、状态持久化及绘制/输入/更新接口
-- POS:    为普通启动器与 App Manager 提供共享的手柄优先 UI 骨架
-- kit.lua —— shared launcher skeleton for handhelds (LÖVE).
--
-- What the skeleton provides (ports never reimplement this):
--  · Header bar: "‹ Back" top-left on secondary pages, centred title, language key.
--  · Adaptive density: take the largest content size that still fits —— small screens
--    fill up with minimal margins; large screens cap the content and turn the surplus
--    into margins. There is a readability floor; only then shrink rows, then scroll.
--  · Outlined text / rounded panels / picker rows / focus ring (header included) /
--    EN/ZH toggle / credits / QQ / state save / env write-out.
--    A port only supplies strings / state / pages.
--
-- Preview: PAM_FORCE_W/H force rendering at a given resolution, letterboxed and
-- centred, so small-screen layout can be eyeballed on a big-screen device.
-- Exit codes: 42 start / 0 back to main menu.

local components = require("ui_components")
local ui_theme = require("ui_theme")
local ui_icons = require("ui_icons")
local qr_view = require("qr_view")
local kit = {}
kit.EXIT_START, kit.EXIT_QUIT = 42, 0
kit.CONTACT = "QQ 群 1047158975"

kit.BASE_STRINGS = {
    start_game   = {en="Start Game",   zh="开始游戏"},
    quit_menu    = {en="Quit to Menu", zh="返回主菜单"},
    back         = {en="Back",         zh="返回"},
    off          = {en="Off",          zh="关"},
    on           = {en="On",           zh="开"},
    resolution   = {en="Resolution:",  zh="渲染分辨率:"},
    res_auto     = {en="Native",       zh="跟随系统"},
    detected     = {en="Detected %d×%d", zh="检测到 %d×%d"},
    credit_dev   = {en="Developer",    zh="游戏作者"},
    credit_art   = {en="Artist",       zh="美术作者"},
    credit_porter= {en="Porter",       zh="移植作者"},
    save_failed  = {en="Could not save settings", zh="无法保存设置"},
    save_failed_message={en="Nothing was launched. Check free space, then try again.",zh="尚未启动游戏。请检查剩余空间后重试。"},
    retry        = {en="Try again",    zh="重试"},
    stay         = {en="Stay",         zh="暂不启动"},
}

-- Design sizes (720p baseline, multiplied by the content scale CS).
local BAR_H, SUB_PX          = 58, 18
local ROW_MAX, ROW_MIN, GAP  = 58, 48, 9
local TITLE_PX, ROW_PX, CRED_PX, BTN_PX = 28, 24, 18, 23
local SIDEBAR_FOOTER_PRIMARY_PX, SIDEBAR_FOOTER_SECONDARY_PX = 19, 18
local SIDEBAR_FOOTER_LINE_H, SIDEBAR_FOOTER_PAD = 25, 12
local DIALOG_BODY_PX, DIALOG_ITEM_PX, DIALOG_AUX_PX, TOAST_PX = 20, 20, 19, 21
local BODY_TEXT_SCALE = 1.08       -- small handheld readability boost; titles keep their designed size
local APP_MINCS = 0.80             -- 480p APP geometry and typography scale together
local MINCS, MAXCS = 0.72, 1.15   -- content scale bounds (readability floor / cap on big screens)
local ROW_MAX_W = 540             -- hard row-width cap (px, does not grow with cs): keeps wide screens narrow

local W, H, realW, realH, offX, offY, letterbox
local function app_content_scale()
    return ui_theme.scale(W,H)
end
local port, strings, state = nil, {}, {}
local fonts, bg_img = {}, nil
local thumbnails, thumbnail_order = {}, {}
local external_font_data, external_font_checked = nil, false
local pages, page_i = {}, 1
local navigation_stack = {}
local zone, focus_i, sidebar_i, bar_i = "rows", 1, 1, 1
local scroll_top, scroll_y = 1, 0
local busy, busy_message, busy_info, busy_elapsed = false, nil, nil, 0
local busy_display_progress = 0
local toast_state = nil
local dialog_state, dialog_focus = nil, 2
local password_state = nil
local guide_state = nil
local text_scroll_active,text_scroll_elapsed=false,0
local layout, sidebar_geometry, current_sidebar_detail
local input_map, focus_stack = {}, {}
local measurement_cache = setmetatable({}, {__mode="k"})
local layout_cache_stats = {hits=0,misses=0,invalidations=0}
-- love-lite host reads this for true event-driven redraws. Stock LÖVE ignores it.
local needs_redraw = true

local DEFAULT_INPUT_MAP = {
    up="up", down="down", left="left", right="right",
    pageup="page_up", pagedown="page_down",
    ["return"]="confirm", kpenter="confirm", space="confirm", escape="cancel",
    -- These aliases let a future native gamepad adapter dispatch semantic
    -- actions without manufacturing keyboard names.
    confirm="confirm", cancel="cancel",
}

local function is_app() return port and port.theme and port.theme.kind=="app" end
local function app_input_hint(password)
    if password then
        return state.ui_lang=="zh" and "A 输入 · B 返回 · L1/R1 切换字符" or
            "A Type · B Back · L1/R1 Characters"
    end
    return state.ui_lang=="zh" and "A 确认    B 返回" or "A Confirm    B Back"
end
local function tools_visible()
    local page=pages[page_i]
    return is_app() and W and W<600 and (zone=="sidebar" or (zone=="bar" and page and page.header_return=="sidebar"))
end
local function secondary_page()
    return page_i~=1 and not (is_app() and pages[page_i] and pages[page_i].root)
end
local function disabled(row)
    if not row then return false end
    return type(row.disabled)=="function" and row.disabled() or row.disabled==true
end
local function row_identity(row)
    if not row then return nil end
    if row.id~=nil then return row.id end
    if row.key~=nil then return row.key end
    if row.meta then
        if row.meta.id~=nil then return row.meta.id end
        if row.meta.path~=nil then return row.meta.path end
        if row.meta.paths and row.meta.paths[1]~=nil then return row.meta.paths[1] end
    end
    return nil
end
local function first_focusable(items)
    for i,row in ipairs(items or {}) do
        if row.focusable and not disabled(row) then return i end
    end
    return 1
end
local function default_sidebar_index(page)
    if page and page.navigation then
        for i,row in ipairs(page.sidebar or {}) do
            if row.active and row.focusable and not disabled(row) then return i end
        end
    end
    return first_focusable(page and page.sidebar)
end
local function default_focus_index(items)
    for i,row in ipairs(items or {}) do
        if row.default_focus and row.focusable and not disabled(row) then return i end
    end
    -- Default focus for a freshly entered page: prefer the "start" button so
    -- the player can confirm and launch with a single press. Falls back to
    -- the first focusable row on pages that have no start button (sub-pages).
    -- This is ONLY the default — capture_focus/restore_focus still win when
    -- returning to a page the player already navigated within.
    for i = #(items or {}), 1, -1 do
        local row = items[i]
        if row and row.focusable and not disabled(row) and row.action == "start" then
            return i
        end
    end
    -- Switches are auxiliary controls: never land on one by default, or a
    -- confirm press would flip it (e.g. the home-page remote switch).
    local first = first_focusable(items)
    if first and items[first] and items[first].kind == "switch" then
        for i = first + 1, #(items or {}) do
            local row = items[i]
            if row and row.focusable and not disabled(row) then return i end
        end
        return first
    end
    return first_focusable(items)
end
local function valid_focus(items,index)
    local row=items and items[index]
    return row and row.focusable and not disabled(row)
end
-- A page owns two child focus scopes. Empty/display-only scopes never own
-- focus; fall back to the sibling scope, then to the page header.
local function normalize_focus()
    local page=pages[page_i]
    if not page then return end
    if zone=="rows" and not valid_focus(page.rows,focus_i) then
        focus_i=first_focusable(page.rows)
        if not valid_focus(page.rows,focus_i) then zone="sidebar" end
    end
    if zone=="sidebar" and not valid_focus(page.sidebar,sidebar_i) then
        sidebar_i=default_sidebar_index(page)
        if not valid_focus(page.sidebar,sidebar_i) then
            focus_i=first_focusable(page.rows)
            zone=valid_focus(page.rows,focus_i) and "rows" or "bar"
        end
    end
end
local function nearest_focus(items,index)
    local count=#(items or {})
    index=math.max(1,math.min(index or 1,math.max(1,count)))
    for distance=0,count do
        local left,right=index-distance,index+distance
        if left>=1 and valid_focus(items,left) then return left end
        if right<=count and right~=left and valid_focus(items,right) then return right end
    end
    return first_focusable(items)
end
local function find_focus_identity(items,id)
    if id==nil then return nil end
    for i,row in ipairs(items or {}) do
        if row_identity(row)==id and row.focusable and not disabled(row) then return i end
    end
end


-- ── Fonts / text ─────────────────────────────────────────────────────
local function load_external_font()
    if external_font_checked then return external_font_data end
    external_font_checked=true
    local path=os.getenv("LOVE_FONT_PATH")
    if not path or path=="" then return nil end
    local file=io.open(path,"rb")
    if not file then return nil end
    local contents=file:read("*a"); file:close()
    if not contents or contents=="" then return nil end
    local name=path:match("([^/\\]+)$") or "NotoSansSC-Regular.ttf"
    local ok,data=pcall(love.filesystem.newFileData,contents,name)
    if ok then
        external_font_data=data
        -- Upgrade cleanup happens only after the shared file is safely in
        -- memory. If the direct read fails, the old local copy remains usable.
        local source=love.filesystem.getSource()
        local local_path=source and source:gsub("/+$","").."/font.ttf" or nil
        if local_path and path~=local_path then os.remove(local_path) end
    end
    return external_font_data
end
local function fnt(px)
    px = math.max(9, math.floor(px + 0.5))
    if not fonts[px] then
        -- APP Manager's self-contained LOVE-lite runtime can read the bundled
        -- font directly. Regular LÖVE launchers keep the portable FileData
        -- path below and are unaffected.
        local direct_path=os.getenv("LOVE_LITE_RENDERER") and os.getenv("LOVE_FONT_PATH") or nil
        if direct_path and direct_path~="" then
            local ok,font=pcall(love.graphics.newFont,direct_path,px)
            if ok and font then fonts[px]=font end
        end
        -- The shell resolves PortMaster's real NotoSansSC path across firmware
        -- layouts. Load it once as shared FileData so every size uses that exact
        -- system file without creating a per-launcher disk copy.
        if not fonts[px] then
            local data=load_external_font()
            if data then
                fonts[px] = love.graphics.newFont(data,px)
            elseif love.filesystem.getInfo("font.ttf") then
                -- Upgrade/degraded fallback for a device whose shared font could
                -- not be repaired. English still renders if this is absent too.
                fonts[px] = love.graphics.newFont("font.ttf", px)
            else
                fonts[px] = love.graphics.newFont(px)
            end
        end
    end
    return fonts[px]
end
local function t(key)
    if type(key)=="function" then key=key() end
    if type(key)=="table" then return key[state.ui_lang] or key.en or "" end
    local p = strings[key]; if not p then return key end
    return p[state.ui_lang] or p.en or key
end
local function snapped_text_box(x,y,limit)
    local right=limit and math.floor(x+limit+0.5) or nil
    x=math.floor(x+0.5); y=math.floor(y+0.5)
    if right then limit=math.max(1,right-x) end
    return x,y,limit
end
local function outlined(txt, x, y, px, col, align, limit)
    x,y,limit=snapped_text_box(x,y,limit)
    local f = fnt(px); love.graphics.setFont(f)
    love.graphics.setColor(0,0,0,is_app() and 0.45 or 0.60)
    if align then love.graphics.printf(txt,x+1,y+1,limit,align)
    else love.graphics.print(txt,x+1,y+1) end
    love.graphics.setColor(col[1],col[2],col[3],col[4] or 1)
    if align then love.graphics.printf(txt, x, y, limit, align)
    else love.graphics.print(txt, x, y) end
end
local function body_fnt(px) return fnt(px*BODY_TEXT_SCALE) end
local function plain(txt,x,y,px,col,align,limit)
    x,y,limit=snapped_text_box(x,y,limit)
    local f=body_fnt(px); love.graphics.setFont(f)
    love.graphics.setColor(col[1],col[2],col[3],col[4] or 1)
    txt=tostring(txt or "")
    if align then love.graphics.printf(txt,x,y,limit,align)
    else love.graphics.print(txt,x,y) end
end
local function clip_ellipsis(text,font,max_w)
    if font:getWidth(text)<=max_w then return text end
    local out=""
    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if font:getWidth(out..char.."…")>max_w then break end
        out=out..char
    end
    return out.."…"
end
local function wrapped_lines(text,font,width)
    width=math.max(1,width)
    if not text:find("/",1,true) then local _,lines=font:getWrap(text,width); return lines end
    local lines={}
    for paragraph in (text.."\n"):gmatch("(.-)\n") do
        if paragraph:sub(1,1)~="/" then
            local _,part=font:getWrap(paragraph,width)
            for _,line in ipairs(#part>0 and part or {""}) do lines[#lines+1]=line end
        else
            local line,pos="",1
            while pos<=#paragraph do
                local finish=paragraph:find("/",pos,true) or #paragraph
                local token=paragraph:sub(pos,finish)
                pos=finish+1
                if line~="" and font:getWidth(line..token)>width and font:getWidth(token)<=width then
                    lines[#lines+1]=line; line=""
                end
                for char in token:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
                    if line~="" and font:getWidth(line..char)>width then lines[#lines+1]=line; line="" end
                    line=line..char
                end
            end
            lines[#lines+1]=line
        end
    end
    return lines
end
local function wrapped_text(value,font,width,max_lines)
    local text=tostring(t(value) or ""); local lines=wrapped_lines(text,font,width)
    if #lines==0 then lines={""} end
    local truncated=max_lines and #lines>max_lines
    local count=truncated and max_lines or #lines; local shown={}
    for i=1,count do shown[i]=lines[i] end
    if truncated then shown[count]=clip_ellipsis(shown[count].."…",font,width) end
    return table.concat(shown,"\n"),count,truncated
end
local function textview_content(row)
    local value=tostring(t(row.value) or "")
    if row.expanded and row.description then value=value.."\n\n"..tostring(t(row.description) or "") end
    return value
end
local function textview_value(row,width,cs)
    local px=(row.value_px or 19)*cs
    if row.preserve_lines then
        local value=tostring(t(row.value) or "")
        while px>12*cs do
            local fits=true
            for line in (value.."\n"):gmatch("(.-)\n") do
                if body_fnt(px):getWidth(line)>width then fits=false; break end
            end
            if fits then break end
            px=math.max(12*cs,px-cs)
        end
    end
    return px,body_fnt(px)
end

local textview_lines
local function field_layout(row,width,cs)
    local value=textview_content(row)
    local stacked=W<600 or row.expanded or value:find("\n",1,true)~=nil or value:match("^/")~=nil
    local pad=16*cs
    local label_w=math.min(230*cs,width*.37)
    local value_w=math.max(1,width-pad*2-(stacked and 0 or label_w+24*cs))
    local value_px,font=textview_value(row,value_w,cs)
    local label_px=(row.label_px or 18)*cs
    local label_h=body_fnt(label_px):getHeight()
    local lines=math.min(#textview_lines(value,font,value_w,row.preserve_lines),row.expanded and row.expanded_lines or row.max_lines)
    local value_h=lines*font:getHeight()
    local height=stacked and pad*2+label_h+7*cs+value_h or math.max(72*cs,pad*2+math.max(label_h,value_h))
    return {stacked=stacked,pad=pad,label_w=label_w,value_w=value_w,value_px=value_px,font=font,
        label_px=label_px,label_h=label_h,value_h=value_h,h=height}
end

textview_lines=function(value,font,width,preserve_lines)
    local text=tostring(t(value) or "")
    local lines
    if preserve_lines then
        lines={}; for line in (text.."\n"):gmatch("(.-)\n") do lines[#lines+1]=line end
    else lines=wrapped_lines(text,font,width) end
    return #lines>0 and lines or {""}
end

-- TextViews retain their full text. Only genuinely overflowing, visible blocks
-- pan slowly, with a pause at both ends; existing clipping is restored afterwards.
local function draw_textview_text(value,font,px,x,y,width,height,color,L,preserve_lines)
    local lines=textview_lines(value,font,width,preserve_lines)
    local overflow_y=math.max(0,#lines*font:getHeight()-height)
    local overflow_x=0
    for _,line in ipairs(lines) do overflow_x=math.max(overflow_x,font:getWidth(line)-width) end
    local top,bottom=y,y+height
    if L.geometry then top=math.max(top,L.band_top); bottom=math.min(bottom,L.band_top+L.band) end
    if bottom<=top then return end
    local moving=overflow_x>0.5 or overflow_y>0.5
    if moving then text_scroll_active=true end
    local function pan(distance)
        if distance<=0.5 then return 0 end
        local duration=distance/(12*L.cs)
        local phase=text_scroll_elapsed%(duration*2+4)
        if phase<2 then return 0 end
        if phase<2+duration then return (phase-2)*12*L.cs end
        if phase<4+duration then return distance end
        return math.max(0,distance-(phase-4-duration)*12*L.cs)
    end
    love.graphics.setScissor(offX+x,offY+top,width,bottom-top)
    if overflow_x>0.5 then
        for i,line in ipairs(lines) do
            plain(line,x-pan(overflow_x),y+(i-1)*font:getHeight()-pan(overflow_y),px,color)
        end
    -- Wrapping was already measured above. Leave one rounding pixel so the
    -- pixel-snapped printf box cannot wrap a measured line a second time.
    else plain(table.concat(lines,"\n"),x,y-pan(overflow_y),px,color,"left",math.ceil(width)+1) end
    if L.geometry then love.graphics.setScissor(offX+L.x,offY+L.band_top,L.w,L.band)
    elseif letterbox then love.graphics.setScissor(offX,offY,W,H)
    else love.graphics.setScissor() end
end
local function vcen(px, h) return (h - body_fnt(px):getHeight())/2 end
local function centred_text_y(px,y,h,optical_offset)
    return y+(h-body_fnt(px):getHeight())/2+(optical_offset or 0)
end

local function panel(x,y,w,h,focused,is_disabled,app,owner,danger)
    local appearance=app and (owner and owner.kind and (owner.appearance or "list") or "surface") or nil
    if app and owner and owner.active then appearance=appearance=="tab" and "tab_active" or "selected" end
    components.surface(x,y,w,h,focused,is_disabled,owner,danger or (owner and owner.danger),appearance)
end

local function draw_checkbox(x,y,size,checked,focused,is_disabled,owner)
    components.checkbox(owner,x,y,size,checked,is_disabled)
end

-- Inventory paths are read-only artwork. Keep a bounded cache and use the
-- regular icon when an image has disappeared or cannot be decoded.
local function draw_thumbnail(path,x,y,size,fallback)
    if path and thumbnails[path]==nil and love.graphics.newImage then
        local ok,img=pcall(love.graphics.newImage,path)
        local iw,ih
        if ok and img and img.getDimensions then iw,ih=img:getDimensions() end
        if iw and iw>1 and ih>1 then
            thumbnails[path]=img
        else thumbnails[path]=false end
        thumbnail_order[#thumbnail_order+1]=path
        if #thumbnail_order>24 then
            local old=table.remove(thumbnail_order,1)
            local image=thumbnails[old]
            if image and image.release then image:release() end
            thumbnails[old]=nil
        end
    end
    local img=path and thumbnails[path]
    if img then
        local iw,ih=img:getDimensions(); local scale=math.min(size/iw,size/ih)
        love.graphics.setColor(1,1,1,1)
        love.graphics.draw(img,x+(size-iw*scale)/2,y+(size-ih*scale)/2,0,scale,scale)
    elseif fallback then
        if not is_app() then
            love.graphics.setColor(ui_theme.surface)
            love.graphics.rectangle("fill",x,y,size,size,size*.18,size*.18)
        end
        love.graphics.setColor(ui_theme.muted)
        ui_icons.draw(fallback,x+size*.22,y+size*.22,size*.56)
    end
end

local function draw_select(x,y,w,h,value,focused,is_disabled,cs,dropdown,bare)
    local radius=math.max(5,8*cs)
    if bare then
        -- App setting rows own their focus surface; the value stays quiet.
    elseif is_disabled then
        love.graphics.setColor(0.16,0.16,0.18,0.92)
        love.graphics.rectangle("fill",x,y,w,h,radius,radius)
        love.graphics.setColor(1,1,1,0.18)
    else
        -- Match Checkbox's dark surface and lavender outline so form controls
        -- read as one family, even when the containing row is focused purple.
        love.graphics.setColor(dropdown and {0.149,0.145,0.176,1} or {0.045,0.03,0.07,0.96})
        love.graphics.rectangle("fill",x,y,w,h,radius,radius)
        love.graphics.setColor(dropdown and (focused and ui_theme.focus_border or ui_theme.border) or {0.78,0.68,0.91,focused and 1 or 0.84})
    end
    if not bare then
        love.graphics.setLineWidth(math.max(1,2*cs))
        love.graphics.rectangle("line",x,y,w,h,radius,radius)
    end

    local cy=y+h/2
    local arrow_dx,arrow_dy=6*cs,7*cs
    local left_x,right_x=x+18*cs,x+w-18*cs
    love.graphics.setColor(is_disabled and 0.45 or 0.84,is_disabled and 0.45 or 0.74,is_disabled and 0.47 or 1,
        is_disabled and 0.5 or 1)
    love.graphics.setLineWidth(math.max(2,2.4*cs))
    if dropdown then
        love.graphics.line(right_x-arrow_dx,cy-3*cs,right_x,cy+3*cs,right_x+arrow_dx,cy-3*cs)
    else
        love.graphics.line(left_x+arrow_dx,cy-arrow_dy,left_x,cy,left_x+arrow_dx,cy+arrow_dy)
        love.graphics.line(right_x-arrow_dx,cy-arrow_dy,right_x,cy,right_x-arrow_dx,cy+arrow_dy)
    end

    local px=(dropdown and 18 or 19)*cs
    local font=body_fnt(px)
    local text_x,text_w=x+(dropdown and 16 or 32)*cs,math.max(1,w-(dropdown and 48 or 64)*cs)
    value=clip_ellipsis(tostring(t(value) or ""),font,text_w)
    plain(value,text_x,y+(h-font:getHeight())/2,px,
        is_disabled and ui_theme.muted or bare and ui_theme.accent or ui_theme.text,bare and "right" or dropdown and "left" or "center",text_w)
end


-- ── Row factories ────────────────────────────────────────────────────
local function apply_options(row,opts)
    for key,value in pairs(opts or {}) do row[key]=value end
    return row
end
function kit.picker(l,vals,labels,key,opts)
    return apply_options({kind="picker",label=l,values=vals,labels=labels,key=key,focusable=true},opts)
end
-- Select is the public component name; picker remains as a compatibility alias
-- for existing launcher schemas.
function kit.select(l,vals,labels,key,opts) return kit.picker(l,vals,labels,key,opts) end
function kit.button(l,action,opts)
    return apply_options({kind="button",label=l,action=action,focusable=true},opts)
end
function kit.checkbox(l,detail,checked,on_toggle,meta)
    if type(detail)=="table" and checked==nil and on_toggle==nil and meta==nil then
        local opts=detail
        local row=apply_options({kind="checkbox",label=l,focusable=true},opts)
        row.checked=opts.checked and true or false
        row.on_toggle=opts.on_toggle or opts.on_change
        return row
    end
    return {kind="checkbox",label=l,detail=detail,checked=checked and true or false,
        on_toggle=on_toggle,meta=meta,focusable=true}
end
function kit.switch(l,key,opts)
    return apply_options({kind="switch",label=l,key=key,off_value="off",on_value="on",focusable=true},opts)
end
function kit.info(l,value,meta) return {kind="info",label=l,value=value,meta=meta,focusable=false} end
function kit.list_item(value,opts)
    return apply_options({kind="list_item",value=value,focusable=true,compact=true},opts)
end
function kit.textview(l,value,opts)
    local row={kind="textview",label=l,value=value,focusable=true,max_lines=2,expanded_lines=8,expandable=true}
    for key,option in pairs(opts or {}) do row[key]=option end
    if row.expandable==false and (not opts or opts.focusable==nil) then row.focusable=false end
    return row
end
function kit.qrcode(value,opts)
    return apply_options({kind="qrcode",value=value,focusable=true},opts)
end
function kit.empty(value,opts)
    return apply_options({kind="empty",value=value,focusable=false,surface=false},opts)
end
function kit.font(px) return body_fnt(px) end
function kit.section(l,opts)
    return apply_options({kind="section",label=l,focusable=false},opts)
end
function kit.badge(text_,color) return {text=text_,color=color} end
function kit.mark_dirty()
    needs_redraw=true
end
function kit.take_dirty()
    local dirty=needs_redraw
    needs_redraw=false
    return dirty
end
function kit.needs_redraw()
    return needs_redraw==true
end
function kit.add_page(title,rows,opts)
    local page=opts or {}; page.title=title; page.rows=rows or {}; page.sidebar=page.sidebar or {}
    if page.preserve_focus and old_page then
        page.focus_memory=old_page.focus_memory
        page.header_return=old_page.header_return
    end
    -- App-specific pages may reserve sparse numeric IDs. Lua's length operator
    -- is undefined for sparse tables, so #pages + 1 can overwrite a reserved
    -- page or return an existing index. Always append after the largest ID.
    local index=0
    for key in pairs(pages) do
        if type(key)=="number" and key%1==0 and key>index then index=key end
    end
    index=index+1
    pages[index]=page; kit.mark_dirty(); return index
end
function kit.invalidate_layout(page)
    if page then measurement_cache[page]=nil
    else measurement_cache=setmetatable({}, {__mode="k"}) end
    layout_cache_stats.invalidations=layout_cache_stats.invalidations+1
    kit.mark_dirty()
end
function kit.set_page(index,title,rows,opts)
    local old_page=pages[index]
    local old_row_id=old_page and zone=="rows" and row_identity(old_page.rows and old_page.rows[focus_i]) or nil
    local old_sidebar_id=old_page and zone=="sidebar" and row_identity(old_page.sidebar and old_page.sidebar[sidebar_i]) or nil
    if old_page then kit.invalidate_layout(old_page) end
    local page=opts or {}; page.title=title; page.rows=rows or {}; page.sidebar=page.sidebar or {}
    pages[index]=page
    if page.preserve_focus and old_page then
        page.focus_memory=old_page.focus_memory
        page.header_return=old_page.header_return
        page.sidebar_scroll_first=old_page.sidebar_scroll_first
    end
    if page_i==index then
        if page.preserve_focus then
            if zone=="rows" then focus_i=find_focus_identity(page.rows,old_row_id) or nearest_focus(page.rows,focus_i) end
            if zone=="sidebar" then sidebar_i=find_focus_identity(page.sidebar,old_sidebar_id) or nearest_focus(page.sidebar,sidebar_i) end
        else
            zone="rows"; focus_i=default_focus_index(page.rows); sidebar_i=default_sidebar_index(page); bar_i=1; scroll_top=1; scroll_y=0
            text_scroll_elapsed=0
        end
    end
    normalize_focus()
    kit.mark_dirty()
    return index
end
function kit.set_busy(value,message,info)
    local was_busy=busy
    busy=value and true or false
    busy_message=message
    busy_info=busy and type(info)=="table" and info or nil
    if not busy then
        busy_elapsed=0
        busy_display_progress=0
    else
        if not was_busy then busy_elapsed=0 end
        -- Snap to the latest reported value. Host polls ~10 Hz; no 60 FPS easing.
        busy_display_progress=math.max(0,math.min(1,tonumber(busy_info and busy_info.progress) or 0))
    end
    kit.mark_dirty()
end
function kit.debug_busy()
    return {busy=busy,message=t(busy_message or ""),stage=busy_info and t(busy_info.stage or "") or "",
        detail=busy_info and t(busy_info.detail or "") or "",
        progress=busy_info and tonumber(busy_info.progress) or nil,
        indeterminate=busy_info and busy_info.indeterminate==true or false,
        footer_left=busy_info and t(busy_info.footer_left or "") or "",
        footer_right=busy_info and t(busy_info.footer_right or "") or "",
        cancellable=busy_info and type(busy_info.on_cancel)=="function" and not busy_info.cancel_disabled or false,
        cancel_requested=busy_info and busy_info.cancel_requested==true or false,
        geometry=busy_info and busy_info._geometry or nil}
end
function kit.toast(message,opts)
    opts=type(opts)=="table" and opts or {}
    local kind=opts.kind or "info"
    if kind~="success" and kind~="error" and kind~="warning" then kind="info" end
    toast_state={message=message or "",kind=kind,duration=math.max(0.1,tonumber(opts.duration) or 5),elapsed=0}
    kit.mark_dirty()
    return true
end
function kit.dismiss_toast()
    if not toast_state then return false end
    toast_state=nil
    kit.mark_dirty()
    return true
end
function kit.debug_toast()
    return {open=toast_state~=nil,message=toast_state and t(toast_state.message) or "",
        kind=toast_state and toast_state.kind or "",
        duration=toast_state and toast_state.duration or 0,
        remaining=toast_state and math.max(0,toast_state.duration-toast_state.elapsed) or 0}
end
local function capture_focus()
    local page=pages[page_i] or {}
    return {page_i=page_i,zone=zone,focus_i=focus_i,sidebar_i=sidebar_i,bar_i=bar_i,
        row_id=row_identity(page.rows and page.rows[focus_i]),
        sidebar_id=row_identity(page.sidebar and page.sidebar[sidebar_i]),
        scroll_top=scroll_top,scroll_y=scroll_y}
end
local function restore_focus(snapshot)
    if not snapshot or not pages[snapshot.page_i] then return end
    page_i=snapshot.page_i
    local page=pages[page_i]
    focus_i=find_focus_identity(page.rows,snapshot.row_id) or nearest_focus(page.rows,snapshot.focus_i)
    sidebar_i=find_focus_identity(page.sidebar,snapshot.sidebar_id) or nearest_focus(page.sidebar,snapshot.sidebar_i)
    zone=snapshot.zone
    if zone=="rows" and not valid_focus(page.rows,focus_i) then
        zone=valid_focus(page.sidebar,sidebar_i) and "sidebar" or "bar"
    elseif zone=="sidebar" and not valid_focus(page.sidebar,sidebar_i) then
        zone=valid_focus(page.rows,focus_i) and "rows" or "bar"
    end
    bar_i=snapshot.bar_i or 1
    scroll_top=snapshot.scroll_top or 1
    scroll_y=snapshot.scroll_y or 0
end
function kit.dialog(opts)
    if type(opts)~="table" then return false end
    if not dialog_state then focus_stack[#focus_stack+1]=capture_focus() end
    dialog_state=opts
    dialog_state._checkbox_checked=opts.checkbox and opts.checkbox.checked==true or false
    dialog_state._item_index=1
    dialog_state._group_scroll=0
    dialog_focus=(opts.default_focus=="confirm" or (is_app() and opts.single_action)) and 1 or 2
    kit.mark_dirty()
    return true
end
function kit.close_dialog()
    if not dialog_state then return false end
    dialog_state=nil; dialog_focus=2
    local snapshot=table.remove(focus_stack)
    restore_focus(snapshot)
    kit.mark_dirty()
    return true
end
function kit.debug_dialog()
    local checked=dialog_state and dialog_state._checkbox_checked or false
    local checkbox=dialog_state and dialog_state.checkbox or nil
    local danger=dialog_state and (dialog_state.danger==true or
        (checkbox and checkbox.danger==true and checked)) or false
    local groups={}
    for i,group in ipairs(dialog_state and dialog_state.item_groups or {}) do
        local items={}; for n,item in ipairs(group.items or {}) do items[n]=t(item) end
        groups[i]={title=t(group.title),items=items}
    end
    local identity=dialog_state and dialog_state.identity
    return {open=dialog_state~=nil,focus=dialog_focus==1 and "confirm" or dialog_focus==3 and "checkbox" or "cancel",
        identity=identity and {title=t(identity.title),subtitle=t(identity.subtitle),thumbnail=identity.thumbnail} or nil,
        item_count=dialog_state and #(dialog_state.items or {}) or 0,
        item_index=dialog_state and dialog_state._item_index or 0,
        current_item=dialog_state and t((dialog_state.items or {})[dialog_state._item_index] or "") or "",
        scroll_items=dialog_state and dialog_state.scroll_items==true or false,
        select=dialog_state and dialog_state.select_row~=nil or false,
        single_action=dialog_state and dialog_state.single_action==true or false,
        selected_value=dialog_state and dialog_state.select_row and dialog_state.select_row.values[dialog_state._select_index] or nil,
        groups=groups,group_count=#groups,
        scroll_y=dialog_state and dialog_state._group_scroll or 0,
        max_scroll=dialog_state and dialog_state._group_max_scroll or 0,
        viewport_h=dialog_state and dialog_state._group_viewport_h or 0,
        danger=danger,checkbox_checked=checked,checkbox_label=checkbox and t(checkbox.label or "") or "",
        title=dialog_state and t(checked and dialog_state.title_checked or dialog_state.title or "") or "",
        message=dialog_state and t(checked and dialog_state.message_checked or dialog_state.message or "") or "",
        scope_depth=#focus_stack,geometry=dialog_state and dialog_state._geometry or nil}
end
function kit.password_dialog(opts)
    if type(opts)~="table" or type(opts.on_confirm)~="function" then return false end
    if password_state then return false end
    focus_stack[#focus_stack+1]=capture_focus()
    password_state={
        title=opts.title or {en="Archive password",zh="压缩包密码"},
        message=opts.message or {en="Enter the password to continue.",zh="输入密码后继续安装。"},
        value="",focus=1,mode=1,max_length=math.max(1,math.min(1024,tonumber(opts.max_length) or 128)),
        on_confirm=opts.on_confirm,on_cancel=opts.on_cancel,
    }
    kit.mark_dirty()
    return true
end
function kit.close_password_dialog()
    if not password_state then return false end
    password_state.value=""
    password_state=nil
    local snapshot=table.remove(focus_stack)
    restore_focus(snapshot)
    kit.mark_dirty()
    return true
end
function kit.debug_password_dialog()
    return {open=password_state~=nil,focus=password_state and password_state.focus or 0,
        mode=password_state and password_state.mode or 0,
        length=password_state and #password_state.value or 0,scope_depth=#focus_stack,
        geometry=password_state and password_state._geometry or nil}
end
function kit.guide(opts)
    if type(opts)~="table" or type(opts.callouts)~="table" then return false end
    if #opts.callouts==0 then return false end
    opts._index=1
    opts._focus=nil
    guide_state=opts
    kit.mark_dirty()
    return true
end
function kit.close_guide()
    if not guide_state then return false end
    local snapshot=guide_state._focus
    guide_state=nil
    restore_focus(snapshot)
    kit.mark_dirty()
    return true
end
function kit.debug_guide()
    local callout=guide_state and (guide_state.callouts[guide_state._index or 1] or {}) or {}
    return {open=guide_state~=nil,title=guide_state and t(guide_state.title or "") or "",
        message=guide_state and t(guide_state.message or "") or "",
        confirm=guide_state and t(guide_state.confirm or "") or "",
        callout_count=guide_state and #(guide_state.callouts or {}) or 0,
        step=guide_state and (guide_state._index or 1) or 0,
        target=callout.target,callout_title=t(callout.title or ""),body=t(callout.body or ""),
        target_rect=guide_state and guide_state._target_rect or nil}
end
function kit.debug_focus()
    return {zone=zone,focus_i=focus_i,sidebar_i=sidebar_i,bar_i=bar_i,scroll_top=scroll_top,scroll_y=scroll_y}
end
function kit.debug_page()
    local page=pages[page_i] or {}; local rows=page.rows or {}; local sections=0
    local section_labels,row_kinds,row_font_px,row_label_px,row_value_px,row_max_lines={},{},{},{},{},{}
    local row_labels,row_values,row_ids,row_descriptions,row_expanded={},{},{},{},{}
    local footer_lines={}
    local footer=page.sidebar_footer
    for index,line in ipairs(footer and (footer.lines or footer) or {}) do footer_lines[index]=t(line) end
    for index,row in ipairs(rows) do
        row_kinds[index]=row.kind
        row_font_px[index]=row.font_px
        row_label_px[index]=row.label_px
        row_value_px[index]=row.value_px
        row_max_lines[index]=row.max_lines
        row_labels[index]=t(row.label or "")
        row_values[index]=t(row.value or "")
        row_ids[index]=row_identity(row) or ""
        row_descriptions[index]=t(row.description or "")
        row_expanded[index]=row.expanded==true
        if row.kind=="section" then
            sections=sections+1
            section_labels[sections]=t(row.label)
        end
    end
    local header_action=page.header_action
    local sidebar_labels,sidebar_ids,sidebar_active={},{},{}
    for index,row in ipairs(page.sidebar or {}) do
        sidebar_labels[index]=t(row.label or ""); sidebar_ids[index]=row_identity(row) or ""; sidebar_active[index]=row.active==true
    end
    return {index=page_i,title=t(page.title or ""),row_count=#rows,section_count=sections,
        root=page.root==true,row_ids=row_ids,
        section_labels=section_labels,row_kinds=row_kinds,row_font_px=row_font_px,
        row_label_px=row_label_px,row_value_px=row_value_px,row_labels=row_labels,row_values=row_values,
        row_max_lines=row_max_lines,row_descriptions=row_descriptions,row_expanded=row_expanded,
        header_label=header_action and t(header_action.label or "") or nil,
        header_badge=header_action and header_action.badge and t(header_action.badge.text) or nil,
        sidebar_count=#(page.sidebar or {}),
        sidebar_labels=sidebar_labels,sidebar_ids=sidebar_ids,sidebar_active=sidebar_active,
        sidebar_footer_lines=footer_lines}
end
function kit.debug_navigation() return {depth=#navigation_stack} end
function kit.debug_sidebar_geometry()
    if not layout or not sidebar_geometry then return nil end
    local L=layout(); local g=sidebar_geometry(L)
    local out={scroll=g.scroll,first=g.scroll_first,per=g.per,bar=g.scroll_bar,
        total=g.scroll_total,bottom=g.scroll_bottom,
        viewport_top=g.viewport_top,viewport_bottom=g.viewport_bottom}
    out.band_top=L.band_top; out.band=L.band; out.cs=L.cs
    local side=pages[page_i].sidebar or {}
    for i=1,#side do if g[i] then out["y"..i]=g[i].y; out["h"..i]=g[i].h end end
    return out
end

function kit.debug_sidebar_detail()
    local detail,key
    if current_sidebar_detail then detail,key=current_sidebar_detail() end
    if not detail then return nil end
    return {key=key,title=t(detail.title or ""),body=t(detail.body or "")}
end
function kit.debug_layout_cache()
    return {hits=layout_cache_stats.hits,misses=layout_cache_stats.misses,
        invalidations=layout_cache_stats.invalidations}
end
function kit.get_state() return state end
function kit.translate(key) return t(key) end
local function cur() return pages[page_i].rows end
local function sidebar() return pages[page_i].sidebar or {} end
current_sidebar_detail=function()
    local page=pages[page_i]
    if not page or type(page.sidebar_details)~="table" then return nil end
    local row=page.rows and page.rows[focus_i] or nil
    local key=row_identity(row)
    local detail=key~=nil and page.sidebar_details[key] or nil
    if type(detail)=="function" then detail=detail(row,key,state) end
    if detail==nil then return nil end
    if type(detail)~="table" then detail={body=detail} end
    return detail,key
end
local function focusables(items)
    local o={}; for i,r in ipairs(items or {}) do if r.focusable and not disabled(r) then o[#o+1]=i end end; return o
end


-- ── Header focus items (secondary pages: back + lang; home: lang only) ──
local function bar_items()
    local b = {}
    if secondary_page() then b[#b+1] = "back" end
    local header=pages[page_i].header_action
    if page_i == 1 and header and header.focusable~=false and not disabled(header) then b[#b+1] = "header" end
    if is_app() and W<600 and #sidebar()>0 then b[#b+1]="tools" end
    if is_app() and pages[page_i].navigation then
        if W<600 then b[#b+1]="quit" end
    else b[#b+1] = "lang" end
    return b
end


-- ── Focus navigation ─────────────────────────────────────────────────
local focus_view = require("focus_view")

local function move_scope(dx,dy)
    local L=layout()
    local page=pages[page_i]
    local rows={id="rows",children={}}
    if not page.row_layout then rows.axis="y" end
    local side={id="sidebar",children={}}
    for _,index in ipairs(focusables(cur())) do
        local g=L.geometry and L.geometry[index]
        local rect=g and {x=g.x,y=g.y,w=g.w,h=g.h} or
            {x=L.x,y=L.top+(index-L.first)*(L.rh+L.gap),w=L.w,h=L.rh}
        rows.children[#rows.children+1]={id="rows:"..index,zone="rows",index=index,rect=rect,focusable=true}
    end
    local geometry=sidebar_geometry(L)
    for _,index in ipairs(focusables(sidebar())) do
        local g=geometry[index]
        if g then side.children[#side.children+1]={id="sidebar:"..index,zone="sidebar",index=index,
            -- Inside the scroll container use content order, including pinned
            -- actions after the list. Cross-container search uses screen space.
            rect={x=g.x,y=(zone=="sidebar" and dy~=0) and (g.focus_y or g.y) or g.y,w=g.w,h=g.h},focusable=true} end
    end
    local tree={id="page",axis="y",children={
        {id="header",zone="bar",index=1,focusable=#bar_items()>0,rect={x=0,y=0,w=W,h=1}},
        {id="body",axis="x",children={rows,side}},
    }}
    local index=zone=="rows" and focus_i or sidebar_i
    local target=focus_view.move(tree,zone..":"..index,dx,dy)
    if not target then return end
    if target.zone~=zone then
        page.focus_memory=page.focus_memory or {}
        local items=zone=="rows" and cur() or sidebar()
        page.focus_memory[zone]=row_identity(items[index])
        local destination=target.zone=="rows" and cur() or sidebar()
        target.index=find_focus_identity(destination,page.focus_memory[target.zone]) or target.index
    end
    -- Explicit action association remains an override when entering tools.
    if zone=="rows" and target.zone=="sidebar" then
        local row=cur()[focus_i]
        target.index=find_focus_identity(sidebar(),row and row.sidebar_target) or target.index
        if page.navigation then
            for i,item in ipairs(sidebar()) do if item.active then target.index=i; break end end
        end
    end
    if target.zone=="bar" then page.header_return=zone; bar_i=1
    elseif target.zone=="rows" then focus_i=target.index
    else sidebar_i=target.index end
    zone=target.zone
end

local function move_v(d)
    if zone=="bar" then
        if d>0 then
            local page=pages[page_i]
            if page.header_return=="sidebar" and valid_focus(sidebar(),sidebar_i) then
                zone="sidebar"
            elseif page.header_return=="rows" and valid_focus(cur(),focus_i) then
                zone="rows"
            elseif #focusables(cur())>0 then
                zone="rows"; focus_i=focusables(cur())[1]
            elseif #focusables(sidebar())>0 then
                zone="sidebar"; sidebar_i=focusables(sidebar())[1]
            end
        end
        return
    end
    move_scope(0,d)
end

local function focus_position(items,index)
    for position,value in ipairs(items) do
        if value==index then return position end
    end
    return 1
end

local function visible_row_count(items)
    if not layout then return 1 end
    local L=layout()
    if not L then return 1 end
    local count=0
    if L.geometry then
        local top=L.scroll_y or 0
        local bottom=top+(L.band or 0)
        for _,index in ipairs(items) do
            local geometry=L.geometry[index]
            if geometry and geometry.content_y+geometry.h>top and geometry.content_y<bottom then
                count=count+1
            end
        end
    else
        for _,index in ipairs(items) do
            if index>=(L.first or 1) and index<=(L.last or #cur()) then count=count+1 end
        end
    end
    return math.max(1,count)
end

local function move_page(d)
    if zone=="bar" then
        if d>0 then
            local rows=focusables(cur())
            if #rows>0 then zone="rows"; focus_i=rows[1] end
        end
        return
    end
    local items,current,step
    if zone=="sidebar" then
        items=focusables(sidebar())
        current=sidebar_i
        local geometry=layout and sidebar_geometry and sidebar_geometry(layout()) or nil
        step=geometry and geometry.per or #items
    else
        items=focusables(cur())
        current=focus_i
        step=visible_row_count(items)
    end
    if #items==0 then return end
    local position=focus_position(items,current)
    position=math.max(1,math.min(#items,position+d*math.max(1,step)))
    if zone=="sidebar" then sidebar_i=items[position] else focus_i=items[position] end
end
local function switch_current(row)
    if row.key~=nil then return state[row.key] end
    return row.value
end
local function set_switch(row,on)
    if disabled(row) then return false end
    local value
    if on then value=row.on_value else value=row.off_value end
    if switch_current(row)==value then return false end
    if row.key~=nil then state[row.key]=value else row.value=value end
    if row.on_change then row.on_change(on,value,row) end
    return true
end
local function move_h(d)
    if zone=="bar" then
        bar_i=math.max(1,math.min(#bar_items(),bar_i+d))
        return
    end
    local r=zone=="rows" and cur()[focus_i] or nil
    if is_app() and W<600 and #sidebar()>0 then
        if pages[page_i].navigation then
            if zone=="rows" then
                local geometry=layout().geometry
                local current=geometry and geometry[focus_i]
                local target,distance
                for _,index in ipairs(focusables(cur())) do
                    local g=geometry and geometry[index]
                    if g and current and d*(g.x-current.x)>0 and math.abs(g.y-current.y)<1 then
                        local delta=math.abs(g.x-current.x)
                        if not distance or delta<distance then target,distance=index,delta end
                    end
                end
                if target then focus_i=target; return end
            end
            if zone=="rows" and d<0 and (not r or r.kind~="picker" or r.dropdown) then
                for i,item in ipairs(sidebar()) do if item.active then sidebar_i=i; break end end
                zone="sidebar"; return
            elseif zone=="sidebar" and d>0 then zone="rows"; normalize_focus(); return
            elseif zone=="sidebar" then return end
        else
        if zone=="sidebar" then
            local geometry=sidebar_geometry(layout())
            local current=geometry[sidebar_i]
            local target,distance
            for _,index in ipairs(focusables(sidebar())) do
                local g=geometry[index]
                if g and current and d*(g.x-current.x)>0 and math.abs(g.y-current.y)<1 then
                    local delta=math.abs(g.x-current.x)
                    if not distance or delta<distance then target,distance=index,delta end
                end
            end
            if target then sidebar_i=target
            elseif d<0 and valid_focus(cur(),focus_i) then zone="rows" end
            return
        end
        if zone=="rows" and d>0 and (not r or (r.kind~="picker" and r.kind~="switch")) then
            sidebar_i=find_focus_identity(sidebar(),r and r.sidebar_target) or nearest_focus(sidebar(),sidebar_i)
            zone="sidebar"; return
        end
        end
    end
    -- Editable controls consume horizontal input before their parent view.
    if r and r.kind=="switch" and not pages[page_i].row_layout then
        set_switch(r,d>0)
    elseif r and r.kind=="picker" and not r.dropdown and not disabled(r) then
        local v=r.values; local idx=1
        for i,x in ipairs(v) do if x==state[r.key] then idx=i end end
        for offset=1,#v do
            local candidate=v[((idx-1+d*offset)%#v)+1]
            if not r.disabled_values or not r.disabled_values[candidate] then
                if state[r.key]~=candidate then
                    state[r.key]=candidate
                    if r.on_change then r.on_change(candidate,r) end
                end
                break
            end
        end
    else move_scope(d,0) end
end


-- ── State save / env ─────────────────────────────────────────────────
local function spath() return love.filesystem.getSource().."/state.txt" end
local function atomic_write(path,writer)
    local tmp=path..".tmp"
    local f,open_err=io.open(tmp,"w")
    if not f then return false,open_err or "open failed" end
    local called,result,write_err=pcall(writer,f)
    if not called or result==false then
        pcall(function() f:close() end); os.remove(tmp)
        return false,called and (write_err or "write failed") or result
    end
    local closed,close_err=f:close()
    if not closed then os.remove(tmp); return false,close_err or "close failed" end
    local renamed,rename_err=os.rename(tmp,path)
    if not renamed then os.remove(tmp); return false,rename_err or "rename failed" end
    return true
end
local function save_state()
    return atomic_write(spath(),function(f)
        for k,v in pairs(state) do
            local wrote,err=f:write(k.."="..tostring(v).."\n")
            if not wrote then return false,err end
        end
        return true
    end)
end
function kit.persist_state() return save_state() end
local function allowed_value(values, value)
    if not values then return value ~= nil end
    for _,candidate in ipairs(values) do if candidate==value then return true end end
    return false
end
local function import_legacy_state()
    local legacy=port.legacy_env; if not legacy or not legacy.path then return false end
    local function source_path(path)
        if path:sub(1,1)=="/" then return path end
        return love.filesystem.getSource().."/"..path
    end
    local imported=false
    if legacy.state_path then
        local sf=io.open(source_path(legacy.state_path),"r")
        if sf then
            local json=sf:read("*a"); sf:close()
            for state_key,spec in pairs(legacy.fields or {}) do
                local value=json:match('"'..state_key..'"%s*:%s*"([^"]*)"')
                if allowed_value(spec.allowed,value) and state[state_key]~=nil then
                    state[state_key]=value; imported=true
                end
            end
            local lang=json:match('"ui_lang"%s*:%s*"([^"]*)"')
            if lang=="en" or lang=="zh" then state.ui_lang=lang; imported=true end
            local count=tonumber(json:match('"launch_count"%s*:%s*(%d+)'))
            if count then state.launch_count=count; imported=true end
        end
    end
    local f=io.open(source_path(legacy.path),"r"); if not f then return imported end
    local env={}
    for line in f:lines() do
        local k,v=line:match("^([A-Z][A-Z0-9_]*)=([%w_.-]+)$")
        if k then env[k]=v end
    end
    f:close()
    for state_key,spec in pairs(legacy.fields or {}) do
        local value
        if spec.width and spec.height then
            local w,h=env[spec.width],env[spec.height]
            if w=="auto" or h=="auto" then value="auto"
            elseif w and h then value=w.."x"..h end
        else
            value=env[spec.name]
        end
        if spec.map and value then value=spec.map[value] end
        if allowed_value(spec.allowed,value) and state[state_key]~=nil then
            state[state_key]=value; imported=true
        end
    end
    return imported
end
local function load_state()
    state={}; for k,v in pairs(port.state) do state[k]=v end
    local imported=false
    local f=io.open(spath(),"r")
    if f then
        for line in f:lines() do local k,v=line:match("^([%w_]+)=(.*)$"); if k and state[k]~=nil then state[k]=v end end
        f:close()
    else
        imported=import_legacy_state()
    end
    local changed=false
    if state.ui_lang~="en" and state.ui_lang~="zh" then
        local default_lang=port.state.ui_lang
        state.ui_lang=(default_lang=="en" or default_lang=="zh") and default_lang or "zh"
        changed=true
    end
    if state.launch_count~=nil then
        local original=state.launch_count
        local count=tonumber(state.launch_count)
        if not count or count<0 then count=tonumber(port.state.launch_count) or 0; changed=true end
        count=math.floor(count)
        if tostring(original)~=tostring(count) then changed=true end
        state.launch_count=count
    end
    if port.validate_state and port.validate_state(state,kit) then changed=true end
    if changed or imported then save_state() end
end
local function write_env()
    return atomic_write(love.filesystem.getSource().."/launch_config.env",function(f)
        local wrote,err=f:write("# generated by love launcher\n")
        if not wrote then return false,err end
        if port.write_env then
            local ok,err=port.write_env(f,state,kit)
            if ok==false then return false,err end
        end
        return true
    end)
end
local function validate_component_state()
    local changed=false
    for _,page in ipairs(pages) do
        for _,row in ipairs(page.rows or {}) do
            if row.kind=="picker" and row.key and state[row.key]~=nil then
                local valid=false
                for _,value in ipairs(row.values or {}) do if state[row.key]==value then valid=true; break end end
                if not valid and row.values and row.values[1]~=nil then state[row.key]=row.values[1]; changed=true end
            elseif row.kind=="switch" and row.key and state[row.key]~=nil then
                if state[row.key]~=row.off_value and state[row.key]~=row.on_value then
                    state[row.key]=row.off_value; changed=true
                end
            end
        end
    end
    if changed then save_state() end
end
function kit.resolution_wh(key)
    local r=state[key or "resolution"]
    if not r or r=="auto" then return "auto","auto" end
    local w,h=r:match("^(%d+)x(%d+)$"); return w or "auto", h or "auto"
end


-- ── Actions ──────────────────────────────────────────────────────────
local function goto_page(n)
    if not pages[n] then return end
    text_scroll_elapsed=0
    page_i=n; zone="rows"; focus_i=default_focus_index(cur()); sidebar_i=default_sidebar_index(pages[n]); bar_i=1; scroll_top=1; scroll_y=0
    normalize_focus()
    kit.mark_dirty()
end
function kit.goto_page(n)
    if n==1 or (pages[n] and pages[n].root) then navigation_stack={} end
    goto_page(n)
end
function kit.push_page(n)
    if not pages[n] or n==page_i then return false end
    navigation_stack[#navigation_stack+1]=capture_focus()
    goto_page(n)
    return true
end
function kit.back_page()
    local snapshot=table.remove(navigation_stack)
    if snapshot and pages[snapshot.page_i] then
        restore_focus(snapshot)
        kit.mark_dirty()
        return true
    end
    navigation_stack={}
    goto_page(1)
    return false
end
local function toggle_lang()
    state.ui_lang=(state.ui_lang=="en") and "zh" or "en"
    kit.invalidate_layout()
    save_state()
end
function kit.quit(code)
    save_state()
    love.event.quit(code == nil and kit.EXIT_QUIT or code)
end
-- ── Prelaunch gate ────────────────────────────────────────────────
-- A port may declare core_files (all must exist to run) plus a source_glob
-- (a player-supplied package the shell-side patcher will extract). If core
-- files are missing AND no source package is present, the launcher refuses
-- to exit and surfaces missing_msg as a toast instead. The port owns the
-- file lists and message text (see launcher.define prelaunch spec); kit
-- only runs the check. GAMEDIR is the love_ui parent directory.
local function file_exists_at(path)
    local f = io.open(path, "rb")
    if not f then return false end
    f:close()
    return true
end
local function prelaunch_ok()
    local pf = port.prelaunch
    if not pf then return true end
    local base = love.filesystem.getSource().."/.."
    if pf.core_files then
        local all = true
        for _, f in ipairs(pf.core_files) do
            if not file_exists_at(base.."/"..f) then all = false; break end
        end
        if all then return true end
    end
    -- Core incomplete — still ok if the player has dropped in a source package.
    if pf.source_glob then
        local dir, pat = string.match(pf.source_glob, "^(.*)/([^/]+)$")
        dir = dir or "."
        pat = pat or pf.source_glob
        local p = io.popen('ls -1 "'..base.."/"..dir..'/'..pat..'" 2>/dev/null')
        if p then
            local out = p:read("*a")
            p:close()
            if out and #out > 0 then return true end
        end
    end
    return false
end
local function do_action(a)
    if a=="start" then
        if not prelaunch_ok() then
            kit.dialog({
                title = {en = "Game data missing", zh = "缺少游戏资源"},
                message = port.prelaunch.missing_msg,
                confirm = {en = "Stay", zh = "留在启动器"},
                cancel = {en = "Quit", zh = "退出"},
                default_focus = "confirm",
                on_cancel = function() kit.quit() end,
            })
            return
        end
        local previous=state.launch_count
        state.launch_count=(tonumber(previous) or 0)+1
        local ok,err=write_env()
        if ok then ok,err=save_state() end
        if ok then love.event.quit(kit.EXIT_START)
        else
            state.launch_count=previous
            kit.dialog({title="save_failed",message="save_failed_message",items={tostring(err or "write failed")},
                confirm="retry",cancel="stay",danger=false,default_focus="cancel",
                on_confirm=function() do_action("start") end})
        end
    elseif a=="quit" then kit.quit()
    elseif type(a)=="string" and a:match("^page:") then kit.push_page(tonumber(a:match("%d+")))
    elseif type(a)=="function" then a(kit) end
end

local function finish_dialog(confirm)
    local current=dialog_state
    local checked=current and current._checkbox_checked==true or false
    kit.close_dialog()
    if not current then return end
    local callback=confirm and current.on_confirm or current.on_cancel
    if callback then callback(kit,checked) end
end

local function advance_guide(delta)
    local current=guide_state
    if not current then return end
    local count=#(current.callouts or {})
    local next_index=(current._index or 1)+(delta or 1)
    if next_index<1 then current._index=1
    elseif next_index<=count then current._index=next_index
    else
        kit.close_guide()
        if current.on_confirm then current.on_confirm(kit) end
    end
end


-- ── LÖVE callbacks ───────────────────────────────────────────────────
function kit.run(cfg)
    port=cfg; love.load=kit.load; love.draw=kit.draw; love.update=kit.update; love.keypressed=kit.keypressed
    love.isAnimating=kit.is_animating
    love.needsRedraw=kit.needs_redraw
    love.takeDirty=kit.take_dirty
    love.wakeInterval=kit.wake_interval
end
function kit.load()
    realW, realH = love.graphics.getDimensions()
    local fw,fh = tonumber(os.getenv("PAM_FORCE_W")), tonumber(os.getenv("PAM_FORCE_H"))
    if fw and fh then W,H=fw,fh; offX,offY=math.floor((realW-fw)/2),math.floor((realH-fh)/2); letterbox=true
    else W,H=realW,realH; offX,offY=0,0; letterbox=false end
    love.graphics.setBackgroundColor(0.02,0.02,0.03)
    dialog_state,dialog_focus=nil,2; password_state=nil; guide_state=nil; focus_stack={}; navigation_stack={}; toast_state=nil
    busy_elapsed=0; busy_display_progress=0
    needs_redraw=true
    components.reset()
    thumbnails,thumbnail_order={},{}
    input_map={}; for key,action in pairs(DEFAULT_INPUT_MAP) do input_map[key]=action end
    for key,action in pairs(port.input_map or {}) do input_map[key]=action end
    measurement_cache=setmetatable({}, {__mode="k"})
    layout_cache_stats={hits=0,misses=0,invalidations=0}
    strings={}; for k,v in pairs(kit.BASE_STRINGS) do strings[k]=v end
    for k,v in pairs(port.strings or {}) do strings[k]=v end
    load_state()
    if love.filesystem.getInfo("launcher_bg.png") then bg_img=love.graphics.newImage("launcher_bg.png") end
    pages={}; port.build_pages(kit,state); validate_component_state(); goto_page(1)
    if port.on_load then port.on_load(kit,state) end
    kit.mark_dirty()
end

function kit.update(dt)
    dt=tonumber(dt) or 0
    if text_scroll_active and not (busy or (dialog_state and not dialog_state.scroll_items) or password_state) then
        text_scroll_elapsed=text_scroll_elapsed+dt; kit.mark_dirty()
    end
    if busy then busy_elapsed=busy_elapsed+dt end
    if toast_state then
        toast_state.elapsed=toast_state.elapsed+dt
        if toast_state.elapsed>=toast_state.duration then
            toast_state=nil
            kit.mark_dirty()
        end
    end
    if port and port.update then port.update(dt,kit,state) end
end

function kit.is_animating()
    -- Determinate progress redraws only when set_busy publishes a new value (~10 Hz).
    if busy and busy_info and busy_info.indeterminate==true then return true end
    if toast_state then
        local edge=0.22
        return toast_state.elapsed<edge or toast_state.duration-toast_state.elapsed<edge
    end
    return false
end

-- Host wake deadline in seconds. nil means "block on input only".
-- 0 means "wake as soon as the animation FPS budget allows".
function kit.wake_interval()
    if kit.is_animating() then return 0 end
    local text_wake=text_scroll_active and not (busy or (dialog_state and not dialog_state.scroll_items) or password_state) and 1/30 or nil
    if busy then return 0.1 end
    if toast_state then
        local edge=0.22
        local remaining=math.max(0,toast_state.duration-toast_state.elapsed)
        if remaining<=edge then return 0 end
        return math.min(text_wake or remaining-edge,remaining-edge)
    end
    if port and type(port.wake_interval)=="function" then
        local ok,value=pcall(port.wake_interval,kit,state)
        if ok and type(value)=="number" and value>=0 then return math.min(text_wake or value,value) end
    end
    return text_wake
end


-- Adaptive density: pick the largest content scale CS that still fits. Returns a layout table.
layout=function()
    local rows = cur(); local n = #rows; local count=math.max(1,n)
    if is_app() then
        local cs=app_content_scale()
        local margin=math.max(9,24*cs)
        local page=pages[page_i]
        local compact=W<600
        local navigation=page.navigation==true
        local has_sidebar=#sidebar()>0
        local side_w=has_sidebar and (compact and W-margin*2 or math.min((navigation and 184 or 280)*cs,W*0.29)) or 0
        local side_gap=has_sidebar and not compact and (navigation and 54 or 28)*cs or 0
        local w=has_sidebar and not compact and W-margin*2-side_w-side_gap or W-margin*2
        if not has_sidebar or navigation then
            w=math.min(w,((page.row_layout and page.row_layout.max_width) or 760)*cs)
        end
        local content_x=not has_sidebar and (W-w)/2 or margin+(navigation and not compact and (side_w+side_gap) or 0)
        local side_x=compact and margin or navigation and margin or content_x+w+side_gap
        local has_toolbar=false
        for _,row in ipairs(rows) do if row.header_toolbar and row.kind~="switch" then has_toolbar=true; break end end
        local function tool_width(row)
            return math.min(w,row.toolbar_width and row.toolbar_width*cs or
                math.min(300*cs,math.max(72*cs,body_fnt((row.label_px or 18)*cs):getWidth(t(row.label))+
                    (row.icon and 64 or 42)*cs)))
        end
        local tools,total_tools={},0
        for index,row in ipairs(rows) do
            if row.header_toolbar then
                local width=compact and row.kind=="switch" and 132*cs or tool_width(row)
                total_tools=total_tools+(#tools>0 and 10*cs or 0)+width
                tools[#tools+1]={index=index,width=width}
            end
        end
        local title_width=body_fnt(31*cs):getWidth(t(page.title))+24*cs+
            (navigation and secondary_page() and 42*cs or 0)
        local toolbar_row=page.toolbar_row==true
        if page.toolbar_auto and has_toolbar then toolbar_row=compact or title_width+total_tools>w end
        local toolbar_pitch=(page.toolbar_auto and 60 or 50)*cs
        local tool_lines={{items={},width=0}}
        local tools_w=(compact or toolbar_row) and w or math.max(1,w-title_width)
        for _,item in ipairs(tools) do
            local line=tool_lines[#tool_lines]
            if (compact or toolbar_row) and #line.items>0 and line.width+10*cs+item.width>tools_w then
                line={items={},width=0}; tool_lines[#tool_lines+1]=line
            end
            line.width=line.width+(#line.items>0 and 10*cs or 0)+item.width
            line.items[#line.items+1]=item
        end
        local toolbar_rows=#tool_lines
        local header_switch=navigation and rows[1] and rows[1].header_toolbar and rows[1].kind=="switch"
        local compact_tools=page.toolbar_auto and 136 or 120
        local content_top=(compact and (navigation and (has_toolbar and compact_tools or header_switch and 64 or 72) or page.root and 78 or 132) or navigation and (toolbar_row and has_toolbar and 168 or 124) or 90)*cs
        if compact or toolbar_row then content_top=content_top+(toolbar_rows-1)*toolbar_pitch end
        local bottom=navigation and (compact and header_switch and 38 or 45)*cs or math.max(12,20*cs)+body_fnt(16*cs):getHeight()+6*cs
        local band=H-content_top-bottom
        local rh,gap=64*cs,(navigation and 8 or 10)*cs
        local page=pages[page_i]
        local row_layout=page.row_layout
        if row_layout then
            local mode=row_layout.mode or "grid"
            local columns
            if mode=="flow" then
                local min_width=(row_layout.min_width or 260)*cs
                columns=math.max(1,math.floor((w+gap)/(min_width+gap)))
                if row_layout.max_columns then columns=math.min(columns,row_layout.max_columns) end
            else
                columns=math.max(1,math.floor(row_layout.columns or 2))
            end
            columns=math.min(columns,math.max(1,n))
            local cell_w=(w-gap*(columns-1))/columns
            local toolbar_labels={}
            for _,row in ipairs(rows) do
                if row.header_toolbar then toolbar_labels[#toolbar_labels+1]=t(row.label) end
            end
            local signature=table.concat({tostring(W),tostring(H),tostring(state.ui_lang or ""),mode,
                tostring(columns),tostring(n),tostring(cs),tostring(w),tostring(band),
                tostring(cell_w),tostring(gap),tostring(content_x),tostring(toolbar_row),tostring(title_width),
                table.concat(toolbar_labels,";")},"|")
            local cached=measurement_cache[page]
            local geometry,total_h
            if cached and cached.signature==signature then
                geometry,total_h=cached.geometry,cached.total_h
                layout_cache_stats.hits=layout_cache_stats.hits+1
            else
                geometry={}; local content_y=0; local i=1
                local function measured_height(row,width)
                    if row.library_item then return (compact and 72 or 84)*cs end
                    if row.height and ((row.kind=="button" and not row.detail) or
                        (row.kind=="picker" and row.dropdown) or row.kind=="switch") then
                        local height=navigation and compact and not row.inline and math.max(64,row.height*.85) or row.height
                        return height*cs
                    end
                    if row.kind=="qrcode" then
                        local inset=row.centered and compact and not row.label and 0 or 36*cs
                        return math.min(band-inset,(row.centered and compact and 244 or row.size or 264)*cs)
                    end
                    if row.kind=="empty" then
                        local _,lines=wrapped_text(row.value,body_fnt(20*cs),math.max(1,width-40*cs))
                        return math.min(band,32*cs+lines*body_fnt(20*cs):getHeight()+(row.title and body_fnt(26*cs):getHeight()+12*cs or 0))
                    end
                    if row.kind=="button" and not row.detail then return 58*cs end
                    if row.kind=="button" and row.detail then
                        local inner_w=math.max(1,width-62*cs)
                        local label_font=body_fnt((row.label_px or 22)*cs)
                        local detail_font=body_fnt((row.detail_px or 18)*cs)
                        local _,lines=wrapped_text(row.detail,detail_font,inner_w,row.detail_max_lines or 1)
                        local minimum=row.height and row.height*(navigation and compact and .85 or 1)*cs or rh
                        return math.max(minimum,20*cs+label_font:getHeight()+4*cs+lines*detail_font:getHeight())
                    end
                    if row.kind=="switch" then return 58*cs end
                    if row.kind=="section" then return 42*cs end
                    if row.kind=="list_item" then return (row.height or 50)*cs end
                    if row.kind=="checkbox" and row.detail then
                        local min_h=(row.height or 74)*cs
                        local tx=(row.selection_item and (row.thumbnail or row.icon) and 76 or row.selection_item and 18 or 70)*cs
                        local inner_w=math.max(1,width-tx-(row.selection_item and 58 or 18)*cs)
                        local label_font=body_fnt((row.label_px or 22)*cs)
                        local detail_font=body_fnt((row.detail_px or 19)*cs)
                        local _,detail_lines=wrapped_text(row.detail,detail_font,inner_w,row.detail_max_lines or 1)
                        return math.max(min_h,10*cs+label_font:getHeight()+6*cs+
                            detail_lines*detail_font:getHeight()+10*cs)
                    end
                    if row.kind=="checkbox" then
                        local font=body_fnt((row.label_px or 22)*cs)
                        local _,lines=wrapped_text(row.label,font,math.max(1,width-88*cs))
                        return math.max((row.selection_item and 76 or 64)*cs,math.min(band,20*cs+math.min(lines,2)*font:getHeight()))
                    end
                    if row.kind~="textview" then return rh end
                    if row.centered then
                        local _,font=textview_value(row,math.max(1,width),cs)
                        return math.max((compact and 30 or 42)*cs,font:getHeight()+2*cs)
                    end
                    if row.hero then return math.max(102*cs,body_fnt(26*cs):getHeight()+body_fnt(19*cs):getHeight()+32*cs) end
                    if row.metric then return 24*cs+body_fnt(18*cs):getHeight()+
                        6*cs+body_fnt((row.value_px or 32)*cs):getHeight() end
                    if row.form_field then return math.min(band,field_layout(row,width,cs).h) end
                    local pad=12*cs
                    local label_px=(row.label_px or 17)*cs
                    local inner_w=width-pad*2
                    local _,value_font=textview_value(row,inner_w,cs)
                    local label_font=body_fnt(label_px)
                    local _,label_lines=wrapped_text(row.label,label_font,inner_w,2)
                    local label_h=label_lines*label_font:getHeight()
                    local requested=row.expanded and row.expanded_lines or row.max_lines
                    local max_fit=math.max(1,math.floor((band-pad*2-label_h-5*cs)/value_font:getHeight()))
                    local value_lines=math.min(#textview_lines(textview_content(row),value_font,inner_w,row.preserve_lines),requested,max_fit)
                    local value_h=value_lines*value_font:getHeight()
                    return math.max(rh,pad+label_h+5*cs+value_h+pad)
                end
                while i<=n do
                    if rows[i].header_toolbar then i=i+1
                    elseif rows[i].kind=="section" then
                        local h=measured_height(rows[i],w)
                        geometry[i]={x=content_x,content_y=content_y,w=w,h=h,column=1}
                        content_y=content_y+h+gap; i=i+1
                    else
                        local group={}
                        local inline=rows[i].inline
                        local group_columns=inline and (rows[i].inline_columns or 2) or columns
                        -- Inline actions and filters form their own short row;
                        -- lists keep the page's normal column count.
                        local group_w=inline and math.min((w-gap*(group_columns-1))/group_columns,
                            (rows[i].max_width or math.huge)*cs) or cell_w
                        while i<=n and not rows[i].header_toolbar and rows[i].kind~="section" and rows[i].inline==inline and #group<group_columns do
                            group[#group+1]=i; i=i+1
                        end
                        local h=0
                        for _,index in ipairs(group) do h=math.max(h,measured_height(rows[index],group_w)) end
                        for column,index in ipairs(group) do
                            geometry[index]={x=content_x+(column-1)*(group_w+gap),content_y=content_y,
                                w=group_w,h=h,column=column}
                        end
                        content_y=content_y+h+gap
                    end
                end
                total_h=math.max(0,content_y-gap)
                -- A full-width QR uses the space left after the address and
                -- other content rows, keeping the whole pairing view visible.
                for index,row in ipairs(rows) do
                    if row.kind=="qrcode" and row.fit_available and columns==1 and not row.inline then
                        local g=geometry[index]
                        local height=math.max(1,math.min(g.w,band-(total_h-g.h)))
                        local extra=height-g.h
                        for _,other in pairs(geometry) do
                            if other.content_y>g.content_y then other.content_y=other.content_y+extra end
                        end
                        g.h=height; total_h=total_h+extra
                    end
                end
                -- Keep the source order within each aligned group. Wrap whole
                -- controls below the title when the title/actions cannot fit.
                for line_number,line in ipairs(tool_lines) do
                    local right_width,right_count=0,0
                    for _,item in ipairs(line.items) do
                        if rows[item.index].toolbar_align=="right" then
                            right_width=right_width+(right_count>0 and 10*cs or 0)+item.width
                            right_count=right_count+1
                        end
                    end
                    local left=content_x+((compact or toolbar_row) and 0 or title_width)
                    local right=content_x+w-right_width
                    for _,item in ipairs(line.items) do
                        local index=item.index; local row=rows[index]
                        local height=(page.toolbar_auto and 52 or compact and 40 or 44)*cs
                        local y=(compact and (row.kind=="switch" and 10 or 70) or
                            toolbar_row and 102 or page.toolbar_auto and 34 or 38)*cs+
                            (line_number-1)*toolbar_pitch
                        local x
                        if row.toolbar_align=="right" then x=right; right=right+item.width+10*cs
                        else x=left; left=left+item.width+10*cs end
                        geometry[index]={x=x,y=y,content_y=y-content_top,w=item.width,h=height,column=index,fixed=true}
                    end
                end
                if navigation and rows[1] and rows[1].kind=="switch" and total_h<band then
                    local shift=math.max(0,(band-total_h)/2-8*cs)
                    for _,g in pairs(geometry) do if not g.fixed then g.content_y=g.content_y+shift end end
                    total_h=total_h+shift
                end
                local only_empty
                for index,row in ipairs(rows) do
                    if not row.header_toolbar then
                        if only_empty or row.kind~="empty" then only_empty=false; break end
                        only_empty=index
                    end
                end
                if only_empty and total_h<band then
                    local shift=(band-total_h)*.38
                    geometry[only_empty].content_y=geometry[only_empty].content_y+shift
                    total_h=total_h+shift
                end
                measurement_cache[page]={signature=signature,geometry=geometry,total_h=total_h}
                layout_cache_stats.misses=layout_cache_stats.misses+1
            end
            local focused=zone=="rows" and geometry[focus_i] or nil
            if focused and not focused.fixed then
                if focused.content_y<scroll_y then scroll_y=focused.content_y
                elseif focused.content_y+focused.h>scroll_y+band then scroll_y=focused.content_y+focused.h-band end
            end
            scroll_y=math.max(0,math.min(scroll_y,math.max(0,total_h-band)))
            local first,last=n,1
            for index,g in pairs(geometry) do
                if not g.fixed then g.y=content_top+g.content_y-scroll_y end
                if g.fixed or (g.y+g.h>content_top and g.y<content_top+band) then
                    first=math.min(first,index); last=math.max(last,index)
                end
            end
            if last<first then first,last=1,0 end
            return {app=true,compact=compact,navigation=navigation,dim=port.theme.background_dim or 0.94,cs=cs,x=content_x,w=w,
                side_x=side_x,side_w=side_w,divider_x=side_x-13*cs,top=content_top,
                rh=rh,gap=gap,first=first,last=last,band=band,band_top=content_top,n=n,
                scroll=total_h>band,has_sidebar=has_sidebar,geometry=geometry,total_h=total_h,
                scroll_y=scroll_y,row_layout_mode=mode,columns=columns}
        end
        local per=math.max(1,math.floor((band+gap)/(rh+gap)))
        if focus_i and focus_i<scroll_top then scroll_top=focus_i end
        if focus_i and focus_i>scroll_top+per-1 then scroll_top=focus_i-per+1 end
        scroll_top=math.max(1,math.min(scroll_top,math.max(1,n-per+1)))
        local first,last=scroll_top,math.min(n,scroll_top+per-1)
        return {app=true,compact=compact,navigation=navigation,dim=port.theme.background_dim or 0.94,cs=cs,x=content_x,w=w,
            side_x=side_x,side_w=side_w,divider_x=side_x-13*cs,top=content_top,
            rh=rh,gap=gap,first=first,last=last,band=band,band_top=content_top,n=n,
            scroll=n>per,has_sidebar=has_sidebar}
    end
    local n_cred = port.credits and #port.credits or 0
    local function topH(cs)  return (BAR_H + SUB_PX + 12) * cs end
    local function botH(cs)  return (n_cred*24 + 24 + 16) * cs end
    local function fits(cs, rh) return topH(cs)+botH(cs)+count*rh+(count-1)*GAP*cs <= H end

    local cs = math.min(MAXCS, H/720)
    while cs > MINCS and not fits(cs, ROW_MAX*cs) do cs = cs - 0.02 end
    cs = math.max(cs, MINCS)

    local rh = ROW_MAX*cs
    local scroll = false
    if not fits(cs, rh) then                       -- still does not fit at min scale: shrink rows
        rh = (H - topH(cs) - botH(cs) - (count-1)*GAP*cs) / count
        if rh < ROW_MIN*cs then rh = ROW_MIN*cs; scroll = true end
    end

    local gap = GAP*cs
    -- Row width: 78% of screen width on small screens, hard-capped at ROW_MAX_W ——
    -- the cap does not grow with cs, so wide screens never stretch the rows.
    local has_sidebar = #sidebar()>0
    local total_w = has_sidebar and math.min(W*0.92, 900) or math.min(W*0.78, ROW_MAX_W)
    local side_gap = has_sidebar and 14*cs or 0
    local side_w = has_sidebar and math.min(total_w*0.34, 260) or 0
    local w = total_w-side_w-side_gap
    local x = (W-total_w)/2
    local side_x = x+w+side_gap
    local content_top = topH(cs)
    local band = (H - botH(cs)) - content_top

    local first, last = 1, n
    local total = count*rh + (count-1)*gap
    local top
    if not scroll then
        top = content_top + (band - total)/2        -- surplus → centre vertically (margins on big screens)
    else
        local per = math.max(1, math.floor((band+gap)/(rh+gap)))
        if focus_i < scroll_top then scroll_top=focus_i end
        if focus_i > scroll_top+per-1 then scroll_top=focus_i-per+1 end
        scroll_top = math.max(1, math.min(scroll_top, math.max(1,n-per+1)))
        first, last = scroll_top, math.min(n, scroll_top+per-1)
        top = content_top
    end
    return {app=false,dim=(port.theme and port.theme.background_dim) or 0.35,
            cs=cs, x=x, w=w, side_x=side_x, side_w=side_w, top=top, rh=rh, gap=gap,
            first=first, last=last, band=band, band_top=content_top, n=n, scroll=scroll,
            has_sidebar=has_sidebar}
end

function kit.debug_layout() return layout() end


local function draw_bar(L)
    local cs=L.cs
    local secondary = secondary_page()
    if L.app and L.navigation then
        local page=pages[page_i]
        local items=bar_items()
        local title=t(L.compact and (page.compact_title or page.title) or page.title)
        if L.compact then
            local pad=math.max(9,15*cs)
            local height=62*cs
            local x=pad
            if page.brand_icon then
                draw_thumbnail(page.brand_icon,pad,13*cs,35*cs,"app")
                x=x+47*cs
            else
                local px=math.max(13,17*cs)
                local width=body_fnt(px):getWidth("APP Manager")
                plain("APP Manager",x,8*cs+vcen(px,46*cs),px,ui_theme.text,"left",width)
                x=x+width+12*cs
            end
            if secondary then
                panel(x,8*cs,32*cs,46*cs,zone=="bar" and items[bar_i]=="back",false,true,{kind="button"})
                plain("‹",x,8*cs+vcen(28*cs,46*cs),28*cs,ui_theme.text,"center",32*cs)
                x=x+38*cs
            end
            local reserved=60*cs
            for _,row in ipairs(cur()) do
                if row.header_toolbar and row.kind=="switch" then reserved=reserved+142*cs; break end
            end
            local width=math.min(W-pad-x-reserved,body_fnt(27*cs):getWidth(title)+30*cs)
            local focused=zone=="bar" and items[bar_i]=="tools"
            panel(x-5*cs,8*cs,width+8*cs,46*cs,focused,false,true,{kind="button"})
            title=clip_ellipsis(title,body_fnt(27*cs),math.max(1,width-20*cs))
            plain(title,x,8*cs+vcen(27*cs,46*cs),27*cs,ui_theme.text,"left",math.max(1,width-20*cs))
            local ax=x+width-9*cs; local ay=height/2
            love.graphics.setColor(ui_theme.muted); love.graphics.setLineWidth(math.max(1,1.5*cs))
            love.graphics.line(ax-5*cs,ay-2*cs,ax,ay+3*cs,ax+5*cs,ay-2*cs)
            local quit_x=W-pad-54*cs
            panel(quit_x,8*cs,54*cs,46*cs,zone=="bar" and items[bar_i]=="quit",false,true,{kind="button"})
            plain(state.ui_lang=="zh" and "退出" or "Exit",quit_x,8*cs+vcen(18*cs,46*cs),18*cs,ui_theme.muted,"center",54*cs)
            love.graphics.setColor(ui_theme.divider); love.graphics.setLineWidth(1)
            love.graphics.line(0,height,W,height)
        else
            if page.brand_icon then draw_thumbnail(page.brand_icon,26*cs,32*cs,38*cs,"app") end
            plain("APP Manager",(page.brand_icon and 74 or 26)*cs,32*cs+vcen(17*cs,38*cs),17*cs,ui_theme.text,"left",180*cs)
            local x=L.x
            if secondary then
                panel(x-6*cs,34*cs,36*cs,50*cs,zone=="bar" and items[bar_i]=="back",false,true,{kind="button"})
                plain("‹",x-6*cs,34*cs+vcen(30*cs,50*cs),30*cs,ui_theme.muted,"center",36*cs)
                x=x+42*cs
            end
            local width=L.w
            for _,row in ipairs(cur()) do if row.header_toolbar then width=math.min(width,body_fnt(31*cs):getWidth(title)+4*cs); break end end
            title=clip_ellipsis(title,body_fnt(31*cs),width)
            plain(title,x,34*cs+vcen(31*cs,52*cs),31*cs,ui_theme.text,"left",width)
        end
        return
    end
    if L.app then
        local page=pages[page_i]
        local items=bar_items()
        local pad=math.max(10,24*cs)
        local by,bh=14*cs,46*cs
        local left=secondary and kit.button("back") or page.header_action
        local function header_button(id,x,y,width,label,owner)
            local focused=zone=="bar" and items[bar_i]==id
            local blocked=owner and disabled(owner) or false
            panel(x,y,width,bh,focused,blocked,true,owner)
            if owner and owner.kind=="switch" then
                local track_w,track_h=40*cs,24*cs
                local track_x=x+width-track_w-10*cs
                components.switch(owner,track_x,y+(bh-track_h)/2,track_w,track_h,owner.checked==true,blocked)
                local label_w=math.max(1,track_x-x-20*cs)
                local text=clip_ellipsis(tostring(t(label) or ""),body_fnt(20*cs),label_w)
                plain(text,x+10*cs,y+vcen(20*cs,bh),20*cs,blocked and {0.45,0.44,0.49} or ui_theme.text,"left",label_w)
            else
                plain(t(label),x+8*cs,y+vcen(20*cs,bh),20*cs,ui_theme.text,"center",width-16*cs)
            end
        end
        local lang_w=66*cs; local lang_x=W-pad-lang_w
        header_button("lang",lang_x,by,lang_w,state.ui_lang=="en" and "中" or "EN")
        local title_x=L.compact and pad or L.navigation and L.x or pad
        if L.navigation then
            local next_x=L.compact and pad or L.x
            if secondary then
                header_button("back",next_x,by,40*cs,"‹",left)
                next_x=next_x+50*cs
            end
            if L.compact then
                header_button("tools",next_x,by,40*cs,"")
                love.graphics.setColor(ui_theme.text)
                ui_icons.draw("menu",next_x+10*cs,by+13*cs,20*cs)
                next_x=next_x+50*cs
            end
            title_x=next_x
        elseif left then
            local left_w=(left.kind=="switch" and 192 or 118)*cs
            local left_y=L.compact and 72*cs or by
            local id=secondary and "back" or "header"
            header_button(id,pad,left_y,left_w,secondary and {en="‹ Back",zh="‹ 返回"} or left.label,left)
            if not L.compact then title_x=pad+left_w+18*cs end
        end
        if L.compact and L.has_sidebar and not L.navigation then
            local label=tools_visible() and {en="Content ›",zh="返回内容 ›"} or
                page.navigation and {en="‹ Sections",zh="‹ 功能导航"} or {en="Tools ›",zh="操作 ›"}
            local width=136*cs
            header_button("tools",W-pad-width,72*cs,width,label)
        end
        local title_w=math.max(1,lang_x-title_x-18*cs)
        local title_px=L.compact and 28 or 30
        local title=t(page.title)
        while title_px>20 and body_fnt(title_px*cs):getWidth(title)>title_w do title_px=title_px-1 end
        title=clip_ellipsis(title,body_fnt(title_px*cs),title_w)
        plain(title,title_x,by+vcen(title_px*cs,bh),title_px*cs,ui_theme.text,"left",title_w)
        if L.navigation and not L.compact then
            plain("APP Manager",pad,by+vcen(20*cs,bh),20*cs,{0.68,0.64,0.74},"left",L.side_w)
        end
        love.graphics.setColor(ui_theme.divider); love.graphics.setLineWidth(1)
        love.graphics.line(L.navigation and L.x or pad,L.band_top-12*cs,L.navigation and (L.x+L.w) or (W-pad),L.band_top-12*cs)
        return
    end
    local bh = BAR_H*cs
    -- Secondary pages: faint background strip, one step down visually
    if secondary then
        love.graphics.setColor(0,0,0,0.28); love.graphics.rectangle("fill",0,0,W,bh)
        love.graphics.setColor(1,1,1,0.10); love.graphics.setLineWidth(1)
        love.graphics.line(0,bh,W,bh)
    end
    local pad = 14*cs
    local items = bar_items()
    -- Back (left) —— secondary pages only
    if secondary then
        local bw = 108*cs
        local focused = (zone=="bar" and items[bar_i]=="back")
        panel(pad, (bh-44*cs)/2, bw, 44*cs, focused)
        plain("‹ "..t("back"),pad,(bh-44*cs)/2+vcen(BTN_PX*cs,44*cs),BTN_PX*cs,{1,1,1},"center",bw)
    end
    -- Language: always top-right (back sits left on secondary pages, language right)
    local lw = 84*cs
    local lx = W - lw - pad
    local lfocused = (zone=="bar" and items[bar_i]=="lang")
    panel(lx, (bh-44*cs)/2, lw, 44*cs, lfocused)
    plain(state.ui_lang=="en" and "中" or "EN",lx,(bh-44*cs)/2+vcen(BTN_PX*cs,44*cs),BTN_PX*cs,{1,1,1},"center",lw)
    -- Centred title, constrained between Back and language controls.
    local title=t(pages[page_i].title); local right_inset=W-(lx-12*cs)
    local title_inset=secondary and math.max(pad+120*cs,right_inset) or right_inset
    local title_x=title_inset; local title_w=math.max(80*cs,W-title_inset*2)
    local title_px=TITLE_PX; local font=fnt(title_px*cs)
    while title_px>20 and font:getWidth(title)>title_w do title_px=title_px-2; font=fnt(title_px*cs) end
    title=clip_ellipsis(title,font,title_w)
    outlined(title,title_x,(bh-font:getHeight())/2,title_px*cs,{1,1,1},"center",title_w)
    -- Detected resolution (small type)
    plain(string.format(t("detected"),realW,realH),0,bh+2*cs,SUB_PX*cs,{1,1,1,0.7},"center",W)
end

local function sidebar_footer_layout(L)
    if L.compact then return {},0 end
    local footer=pages[page_i].sidebar_footer
    local values=footer and (footer.lines or footer) or {}
    local lines={}; local height=#values>0 and SIDEBAR_FOOTER_PAD*L.cs or 0
    for index,value in ipairs(values) do
        local px=(index==1 and SIDEBAR_FOOTER_PRIMARY_PX or SIDEBAR_FOOTER_SECONDARY_PX)*L.cs
        local font=body_fnt(px); local text=tostring(t(value) or "")
        local _,wrapped=font:getWrap(text,L.side_w)
        local h=math.max(SIDEBAR_FOOTER_LINE_H*L.cs,#wrapped*font:getHeight())
        lines[index]={text=text,px=px,h=h}
        height=height+h
    end
    return lines,height
end

sidebar_geometry=function(L)
    if L.navigation then
        local nav={}; for key,value in pairs(L) do nav[key]=value end
        nav.band_top=(L.compact and 72 or 124)*L.cs
        nav.band=H-nav.band_top-45*L.cs
        L=nav
    end
    local side,geometry=sidebar(),{}
    if L.compact and not L.navigation then
        local rh,gap=math.max(28,44*L.cs),math.max(4,6*L.cs)
        local auto_grid=L.navigation and not pages[page_i].root
        for _,row in ipairs(side) do if row.half then auto_grid=false end end
        local groups={}; local i=1
        while i<=#side do
            local pair=side[i+1] and (auto_grid or (side[i].half and side[i+1].half))
            groups[#groups+1]=pair and {i,i+1} or {i}
            i=i+(pair and 2 or 1)
        end
        local total=#groups*rh+math.max(0,#groups-1)*gap
        local hint_h=total>L.band and math.max(16,22*L.cs) or 0
        local available=L.band-hint_h
        local per=math.max(1,math.floor((available+gap)/(rh+gap)))
        local focused_group=1
        for index,group in ipairs(groups) do
            for _,item in ipairs(group) do if item==sidebar_i then focused_group=index end end
        end
        local page=pages[page_i]
        local first=math.max(1,math.min(page.sidebar_scroll_first or 1,math.max(1,#groups-per+1)))
        if focused_group<first then first=focused_group
        elseif focused_group>=first+per then first=focused_group-per+1 end
        page.sidebar_scroll_first=first
        for index,group in ipairs(groups) do
            local width=(L.side_w-gap*(#group-1))/#group
            for column,item in ipairs(group) do
                geometry[item]={x=L.side_x+(column-1)*(width+gap),
                    y=L.band_top+(index-first)*(rh+gap),w=width,h=rh,
                    focus_y=L.band_top+(index-1)*(rh+gap)}
            end
        end
        geometry.scroll=hint_h>0
        geometry.scroll_first,geometry.scroll_total,geometry.per=first,#groups,per
        geometry.viewport_top,geometry.viewport_bottom=L.band_top,L.band_top+available
        geometry.scroll_bottom=L.band_top+L.band
        geometry.visible_first=groups[first] and groups[first][1] or 1
        local last=groups[math.min(#groups,first+per-1)]
        geometry.visible_last=last and last[#last] or #side
        return geometry
    end
    local rh,gap=48*L.cs,8*L.cs
    if not L.app then
        local total=#side*rh+math.max(0,#side-1)*gap
        local y=L.band_top+math.max(0,(L.band-total)/2)
        for i=1,#side do geometry[i]={x=L.side_x,y=y+(i-1)*(rh+gap),w=L.side_w,h=rh} end
        return geometry
    end
    rh=(L.navigation and (L.compact and 50 or 55) or 50)*L.cs
    if L.navigation and L.compact then rh=math.max(32,rh) end
    gap=(L.compact and 6 or L.navigation and 10 or 8)*L.cs
    -- Pinned bottom group (e.g. Quit) keeps a small margin off the screen edge.
    local bottom_y=L.band_top+L.band-(L.compact and 4 or 24)*L.cs
    for i=#side,1,-1 do
        if side[i].group=="bottom" then
            bottom_y=bottom_y-rh
            geometry[i]={x=L.side_x,y=bottom_y,w=L.side_w,h=rh}
            bottom_y=bottom_y-gap
        end
    end
    -- Ordinary items pack from the top. On short screens the toolbar may not
    -- fit above the footer, so the list scrolls: the focused item is kept
    -- visible and everything else shifts up by whole steps.
    local heading=L.navigation and 0 or 45
    local y=L.band_top+heading*L.cs
    local ordinary={}
    local i=1
    while i<=#side do
        local row=side[i]
        if row.group=="bottom" then i=i+1
        elseif row.half and side[i+1] and side[i+1].half and side[i+1].group~="bottom" then
            local half=(L.side_w-gap)/2
            geometry[i]={x=L.side_x,y=y,w=half,h=rh}
            geometry[i+1]={x=L.side_x+half+gap,y=y,w=half,h=rh}
            ordinary[#ordinary+1]=i; ordinary[#ordinary+1]=i+1
            y=y+rh+gap; i=i+2
        else
            geometry[i]={x=L.side_x,y=y,w=L.side_w,h=rh}
            ordinary[#ordinary+1]=i; y=y+rh+gap; i=i+1
        end
    end
    local page=pages[page_i]
    local _,footer_h=sidebar_footer_layout(L)
    local top_limit=bottom_y-(footer_h>0 and footer_h+L.gap or 0)
    local avail=top_limit-(L.band_top+heading*L.cs)
    -- Half-width siblings share a layout row, not two scroll steps.
    local layout_rows={}
    for _,index in ipairs(ordinary) do
        local g=geometry[index]
        local last=layout_rows[#layout_rows]
        if not last or last.y~=g.y then
            last={y=g.y,indices={}}; layout_rows[#layout_rows+1]=last
        end
        last.indices[#last.indices+1]=index
    end
    local total=#layout_rows*rh+math.max(0,#layout_rows-1)*gap
    for _,index in ipairs(ordinary) do geometry[index].focus_y=geometry[index].y end
    local pinned_y=y
    for index,row in ipairs(side) do
        if row.group=="bottom" then
            geometry[index].focus_y=pinned_y
            pinned_y=pinned_y+rh+gap
        end
    end
    if total>avail and #ordinary>0 then
        local step=rh+gap
        -- Scroll affordance bars (18px each) at the top and bottom of the
        -- button area hold the up/down chevrons; the buttons scroll between.
        local scroll_bar=(L.compact and 10 or 18)*L.cs
        -- Top bar sits above the buttons (they start at +scroll_bar); the
        -- bottom bar uses the leftover space below the last visible button.
        local per=math.max(1,math.floor((avail-2*scroll_bar+gap)/step))
        per=math.min(per,#layout_rows)
        local k
        for idx,row in ipairs(layout_rows) do
            for _,v in ipairs(row.indices) do if v==sidebar_i then k=idx end end
        end
        local scroll_first=math.max(1,math.min(page.sidebar_scroll_first or 1,#layout_rows-per+1))
        if k then
            if k<scroll_first then scroll_first=k
            elseif k>=scroll_first+per then scroll_first=k-per+1 end
        end
        page.sidebar_scroll_first=scroll_first
        local dy=(scroll_first-1)*step
        for idx=1,#ordinary do
            local g=geometry[ordinary[idx]]; g.y=g.y-dy+scroll_bar
        end
        geometry.scroll=step; geometry.per=per
        geometry.scroll_first=scroll_first
        geometry.scroll_bar=scroll_bar
        geometry.scroll_total=#layout_rows
        geometry.scroll_bottom=top_limit
        geometry.viewport_top=L.band_top+heading*L.cs+scroll_bar
        geometry.viewport_bottom=top_limit-scroll_bar
        local last_vis=math.min(scroll_first+per-1,#layout_rows)
        local lg=geometry[layout_rows[last_vis].indices[1]]
        if lg then geometry.scroll_last_y=lg.y+lg.h end
    end
    return geometry
end

local PASSWORD_PAGES={
    "1234567890qwertyuiopasdfghjkl-zxcvbnm_.@",
    "1234567890QWERTYUIOPASDFGHJKL-ZXCVBNM_.@",
    "!@#$%^&*()[]{}<>?/\\|:;\"'`~+=-_ ,01234567",
}

local function password_key(page,index)
    return page:sub(index,index)
end

local function draw_password_dialog(L)
    local d=password_state
    if not d then return end
    local cs=L.app and app_content_scale() or math.max(APP_MINCS,math.min(1,H/720))
    local compact=H<360
    local dw=compact and W or math.min(W-24*cs,760*cs)
    local dh=compact and H or math.min(H-20*cs,470*cs)
    local dx,dy=(W-dw)/2,(H-dh)/2
    local pad,gap=(compact and 16 or 24)*cs,(compact and 5 or 6)*cs
    local inner_w=dw-pad*2
    local title_px,message_px=26*cs,18*cs
    local title_h=body_fnt(title_px):getHeight()
    local message,message_lines=wrapped_text(d.message,body_fnt(message_px),inner_w,compact and 1 or 2)
    local message_h=compact and 0 or message_lines*body_fnt(message_px):getHeight()
    local hint=app_input_hint(true)
    local hint_px=(compact and 14 or 16)*cs
    local hint_h=body_fnt(hint_px):getHeight()
    local input_y=dy+pad+title_h+gap+(message_h>0 and message_h+gap or 0)
    local input_h=(compact and 40 or 46)*cs
    local grid_y=input_y+input_h+8*cs
    local action_h=(compact and 46 or 48)*cs
    local action_y=dy+dh-pad-hint_h-8*cs-action_h
    local kw=(inner_w-gap*9)/10
    local kh=math.min(42*cs,(action_y-10*cs-grid_y-gap*3)/4)

    love.graphics.setColor(0,0,0,0.82); love.graphics.rectangle("fill",0,0,W,H)
    love.graphics.setColor(ui_theme.surface); love.graphics.rectangle("fill",dx,dy,dw,dh,compact and 0 or 14*cs,compact and 0 or 14*cs)
    plain(t(d.title),dx+pad,dy+pad,title_px,ui_theme.text,"left",inner_w)
    if message_h>0 then draw_textview_text(d.message,body_fnt(message_px),message_px,dx+pad,dy+pad+title_h+gap,
        inner_w,message_h,ui_theme.muted,{cs=cs}) end
    love.graphics.setColor(ui_theme.navigation_background)
    love.graphics.rectangle("fill",dx+pad,input_y,inner_w,input_h,6*cs,6*cs)
    local shown=math.min(#d.value,28)
    local masked=string.rep("•",shown)..(#d.value>shown and "…" or "")
    plain(masked,dx+pad+12*cs,input_y+vcen(22*cs,input_h),22*cs,ui_theme.text,"left",inner_w-90*cs)
    local length_label=(state.ui_lang=="zh" and "长度 " or "Length ")..tostring(#d.value)
    plain(length_label,dx+pad,input_y+vcen(16*cs,input_h),16*cs,ui_theme.muted,"right",inner_w-12*cs)

    local page=PASSWORD_PAGES[d.mode]
    for index=1,40 do
        local row=math.floor((index-1)/10)
        local col=(index-1)%10
        local x=dx+pad+col*(kw+gap)
        local y=grid_y+row*(kh+gap)
        panel(x,y,kw,kh,d.focus==index,false,L.app,{appearance="secondary"})
        local label=password_key(page,index)
        if label==" " then label=state.ui_lang=="zh" and "空" or "SP" end
        plain(label,x,y+vcen(20*cs,kh),20*cs,ui_theme.text,"center",kw)
    end
    local aw=(inner_w-gap*3)/4
    local mode_labels={"abc/ABC",{en="Delete",zh="退格"},{en="Clear",zh="清空"},{en="Install",zh="安装"}}
    for action=1,4 do
        local x=dx+pad+(action-1)*(aw+gap)
        panel(x,action_y,aw,action_h,d.focus==40+action,false,L.app,
            {appearance=action==4 and "primary" or "secondary"})
        plain(t(mode_labels[action]),x,action_y+vcen(18*cs,action_h),18*cs,ui_theme.text,"center",aw)
    end
    plain(hint,dx+pad,dy+dh-pad-hint_h,hint_px,ui_theme.muted,"center",inner_w)
    d._geometry={top=dy,bottom=dy+dh,grid_y=grid_y,key_h=kh,
        grid_bottom=grid_y+4*kh+3*gap,action_y=action_y,action_bottom=action_y+action_h,
        hint_y=dy+dh-pad-hint_h}
end

local function draw_dialog_groups(d,x,y,width,height,cs)
    local pad,gap=16*cs,15*cs
    local title_px,path_px=24*cs,(W<600 and 18 or 17)*cs
    local title_font,path_font=body_fnt(title_px),body_fnt(path_px)
    local inner_w=width-pad*2-10*cs
    local cards,total={},0
    for _,group in ipairs(d.item_groups) do
        local title,title_lines=wrapped_text(group.title,title_font,inner_w-48*cs)
        local image_size=(W<600 and 42 or 34)*cs
        local card={y=total,title=title,thumbnail=group.thumbnail,image_size=image_size,
            title_h=math.max(image_size,title_lines*title_font:getHeight()),paths={}}
        card.header_h=pad+card.title_h
        local offset=card.header_h+10*cs
        for _,path in ipairs(group.items or {}) do
            local text,lines=wrapped_text(path,path_font,inner_w)
            card.paths[#card.paths+1]={text=text,y=offset}
            offset=offset+lines*path_font:getHeight()+6*cs
        end
        card.h=offset+pad-6*cs
        cards[#cards+1]=card
        total=total+card.h+gap
    end
    total=math.max(0,total-gap)
    d._group_max_scroll=math.max(0,total-height)
    d._group_scroll=math.max(0,math.min(d._group_scroll,d._group_max_scroll))
    d._group_viewport_h=height
    d._group_scroll_step=math.max(1,math.min(path_font:getHeight()+6*cs,height-path_font:getHeight()))
    love.graphics.setScissor(offX+x,offY+y,width,height)
    for _,card in ipairs(cards) do
        local cy=y+card.y-d._group_scroll
        if cy+card.h>y and cy<y+height then
            local card_w,radius=width-10*cs,8*cs
            love.graphics.setColor(ui_theme.review_surface)
            love.graphics.rectangle("fill",x,cy,card_w,card.h,radius,radius)
            draw_thumbnail(card.thumbnail,x+pad,cy+pad,card.image_size,"games")
            plain(card.title,x+pad+card.image_size+12*cs,cy+pad+(card.title_h-title_font:getHeight())/2,
                title_px,ui_theme.text,"left",math.ceil(inner_w-card.image_size-12*cs)+1)
            for _,path in ipairs(card.paths) do
                plain(path.text,x+pad,cy+path.y,path_px,{0.777,0.745,0.824},"left",math.ceil(inner_w)+1)
            end
        end
    end
    if letterbox then love.graphics.setScissor(offX,offY,W,H) else love.graphics.setScissor() end
    if d._group_max_scroll>0 then
        local thumb_h=math.max(18*cs,height*height/total)
        local thumb_y=y+(height-thumb_h)*d._group_scroll/d._group_max_scroll
        love.graphics.setColor(ui_theme.divider)
        love.graphics.rectangle("fill",x+width-5*cs,y,4*cs,height,2,2)
        love.graphics.setColor(ui_theme.focus_border)
        love.graphics.rectangle("fill",x+width-5*cs,thumb_y,4*cs,thumb_h,2,2)
    end
end

local function draw_app_actions(d,x,y,width,height,cs,danger)
    local gap=13*cs
    local px=(W<600 and 22 or 20)*cs
    local confirm=d._checkbox_checked and d.confirm_checked or d.confirm
    local cancel=t(d.cancel or {en="Cancel",zh="取消"})
    confirm=t(confirm or {en="Confirm",zh="确认"})
    local bw=W<600 and (width-gap)/2 or math.max(145*cs,body_fnt(px):getWidth(confirm)+32*cs)
    bw=math.min(bw,(width-gap)/2)
    local cancel_x=x+width-bw*2-gap
    local confirm_x=cancel_x+bw+gap
    d._buttons=d._buttons or {{},{}}
    d._buttons[1].appearance="primary"; d._buttons[2].appearance="secondary"
    if d.single_action then
        confirm_x=x+width-bw
        panel(confirm_x,y,bw,height,true,false,true,d._buttons[1],danger)
        plain(confirm,confirm_x,y+vcen(px,height),px,ui_theme.text,"center",bw)
        return nil,confirm_x
    end
    panel(cancel_x,y,bw,height,dialog_focus==2,false,true,d._buttons[2])
    panel(confirm_x,y,bw,height,dialog_focus==1,false,true,d._buttons[1],danger)
    plain(cancel,cancel_x,y+vcen(px,height),px,ui_theme.text,"center",bw)
    plain(confirm,confirm_x,y+vcen(px,height),px,danger and {0.945,0.682,0.718} or ui_theme.text,"center",bw)
    return cancel_x,confirm_x
end

local function draw_uninstall_review(d,L)
    local cs=L.cs
    local compact=W<600
    local dw=compact and W or math.min(W-48*cs,742*cs)
    local dh=compact and H or H-100*cs
    local dx,dy=(W-dw)/2,(H-dh)/2
    local pad=(compact and 18 or 28)*cs
    local title_px=(compact and 26 or 27)*cs
    local title=state.ui_lang=="zh" and string.format("卸载 %d 个项目",#d.item_groups) or
        string.format("Uninstall %d items",#d.item_groups)
    local title_h=body_fnt(title_px):getHeight()
    local content_y=dy+pad+title_h+(compact and 12 or 22)*cs
    local bh=(compact and 55 or 49)*cs
    local by=dy+dh-(compact and 92 or 84)*cs
    local hint_px=(compact and 17 or 15)*cs
    local hint_y=by-body_fnt(hint_px):getHeight()-12*cs
    love.graphics.setColor(0.02,0.02,0.035,0.72); love.graphics.rectangle("fill",0,0,W,H)
    love.graphics.setColor(ui_theme.surface)
    love.graphics.rectangle("fill",dx,dy,dw,dh,compact and 0 or 18*cs,compact and 0 or 18*cs)
    if not compact then
        love.graphics.setColor(ui_theme.review_border); love.graphics.setLineWidth(1)
        love.graphics.rectangle("line",dx+.5,dy+.5,dw-1,dh-1,18*cs,18*cs)
    end
    plain(title,dx+pad,dy+pad,title_px,ui_theme.text,"left",dw-pad*2)
    draw_dialog_groups(d,dx+pad,content_y,dw-pad*2,math.max(1,hint_y-content_y-8*cs),cs)
    if d._group_max_scroll>0 then
        plain(state.ui_lang=="zh" and "↑↓ 查看清单" or "↑↓ Review files",dx+pad,hint_y,hint_px,ui_theme.muted,"left",dw-pad*2)
    end
    local cancel_x,confirm_x=draw_app_actions(d,dx+pad,by,dw-pad*2,bh,cs,true)
    local footer_px=(compact and 17 or 14)*cs
    plain(app_input_hint(),dx+pad,dy+dh-body_fnt(footer_px):getHeight()-8*cs,
        footer_px,ui_theme.muted,"right",dw-pad*2)
    d._geometry={top=dy,bottom=dy+dh,title_bottom=dy+pad+title_h,content_y=content_y,action_y=by,
        cancel_x=cancel_x,confirm_x=confirm_x,action_bottom=by+bh}
end

local function draw_app_confirmation(d,L)
    local cs=L.cs; local compact=W<600
    local tight=d.identity and H<360
    local checked=d._checkbox_checked
    local danger=d.danger or (d.checkbox and d.checkbox.danger and checked)
    local title=checked and d.title_checked or d.title
    local message=checked and d.message_checked or d.message
    local dw=math.min(W-24*cs,742*cs)
    local pad=(tight and 12 or compact and 18 or 28)*cs
    local width=dw-pad*2
    local title_px=(compact and 24 or 27)*cs
    local body_px=(compact and 18 or 19)*cs
    local title_font,body_font=body_fnt(title_px),body_fnt(body_px)
    local identity=d.identity
    local image_size=(tight and 60 or 72)*cs
    local identity_width=width-image_size-20*cs
    local identity_title_px,identity_subtitle_px=(tight and 24 or 26)*cs,18*cs
    local identity_text_gap=(tight and 4 or 8)*cs
    local identity_gap=(tight and 6 or 20)*cs
    local question_gap=(tight and 6 or 16)*cs
    local action_gap=(tight and 8 or 14)*cs
    local _,identity_title_lines=wrapped_text(identity and identity.title or "",body_fnt(identity_title_px),identity_width)
    local _,identity_subtitle_lines=wrapped_text(identity and identity.subtitle or "",body_fnt(identity_subtitle_px),identity_width)
    local identity_title_h=identity_title_lines*body_fnt(identity_title_px):getHeight()
    local identity_subtitle_h=identity_subtitle_lines*body_fnt(identity_subtitle_px):getHeight()
    local identity_h=identity and math.max(image_size,identity_title_h+identity_text_gap+identity_subtitle_h) or 0
    local _,title_lines=wrapped_text(title or {en="Confirm",zh="确认"},title_font,width)
    local title_h=title_lines*title_font:getHeight()
    local _,message_lines=wrapped_text(message or "",body_font,width)
    local message_h=message and message_lines*body_font:getHeight() or 0
    local items=d.items or {}
    local total,item_max=0,0
    for _,item in ipairs(items) do
        local _,lines=wrapped_text(item,body_font,width-24*cs)
        local h=lines*body_font:getHeight()+16*cs
        total=total+h+6*cs; item_max=math.max(item_max,h)
    end
    total=math.max(0,total-6*cs)
    local checkbox_h=0
    if d.checkbox then
        local _,lines=wrapped_text(d.checkbox.label,body_font,width-58*cs)
        checkbox_h=math.max(50*cs,lines*body_font:getHeight()+16*cs)
    end
    local bh=(compact and 55 or 49)*cs
    local footer_h=body_fnt(16*cs):getHeight()+12*cs
    local fixed=pad*2+title_h+(message and 12*cs+message_h or 0)+bh+footer_h+20*cs+checkbox_h
    if identity then
        fixed=pad*2+identity_h+identity_gap+message_h+question_gap+title_h+action_gap+bh+footer_h+checkbox_h
    end
    local max_h=H-24*cs
    if #items>4 or fixed+total>max_h then d.scroll_items=true end
    local item_h=d.scroll_items and math.max(body_font:getHeight()+16*cs,math.min(item_max,150*cs)) or total
    local dh=math.min(max_h,math.max(190*cs,fixed+item_h+(#items>0 and 16*cs or 0)))
    local dx,dy=(W-dw)/2,(H-dh)/2
    local by=dy+dh-pad-footer_h-bh
    local option_y=by-10*cs-checkbox_h
    local content_limit=d.checkbox and option_y-10*cs or by-action_gap
    local top=dy+pad
    love.graphics.setColor(0.02,0.02,0.035,.74); love.graphics.rectangle("fill",0,0,W,H)
    love.graphics.setColor(ui_theme.surface)
    love.graphics.rectangle("fill",dx,dy,dw,dh,14*cs,14*cs)
    love.graphics.setColor(ui_theme.review_border); love.graphics.setLineWidth(1)
    love.graphics.rectangle("line",dx+.5,dy+.5,dw-1,dh-1,14*cs,14*cs)
    local title_y=top
    local identity_bottom
    if identity then
        draw_thumbnail(identity.thumbnail,dx+pad,top+(identity_h-image_size)/2,image_size,"app")
        local text_y=top+(identity_h-identity_title_h-identity_text_gap-identity_subtitle_h)/2
        draw_textview_text(identity.title,body_fnt(identity_title_px),identity_title_px,
            dx+pad+image_size+20*cs,text_y,identity_width,identity_title_h,ui_theme.text,{cs=cs})
        draw_textview_text(identity.subtitle,body_fnt(identity_subtitle_px),identity_subtitle_px,
            dx+pad+image_size+20*cs,text_y+identity_title_h+identity_text_gap,identity_width,identity_subtitle_h,ui_theme.muted,{cs=cs})
        identity_bottom=top+identity_h
        top=identity_bottom+identity_gap
        title_y=content_limit-title_h
        content_limit=title_y-question_gap
    else top=top+title_h+12*cs end
    draw_textview_text(title or {en="Confirm",zh="确认"},title_font,title_px,dx+pad,title_y,width,title_h,ui_theme.text,{cs=cs})
    local title_bottom=title_y+title_h
    local content_y=top
    local message_bottom=top
    if message then
        local available=math.max(body_font:getHeight(),content_limit-top-(#items>0 and math.min(item_h,body_font:getHeight()+16*cs)+12*cs or 0))
        local h=math.min(message_h,available)
        if identity then h=math.max(body_font:getHeight(),math.floor(h/body_font:getHeight())*body_font:getHeight()) end
        if message_h>h then d.scroll_items=true end
        draw_textview_text(message,body_font,body_px,dx+pad,top,width,h,ui_theme.muted,{cs=cs})
        message_bottom=top+h
        top=top+h+12*cs
    end
    if #items>0 then
        local available=math.max(1,content_limit-top)
        love.graphics.setColor(ui_theme.review_surface)
        love.graphics.rectangle("fill",dx+pad,top,width,available,8*cs,8*cs)
        if d.scroll_items then
            local item=items[d._item_index or 1]
            local path_h=math.max(body_font:getHeight(),math.floor((available-16*cs)/body_font:getHeight())*body_font:getHeight())
            draw_textview_text(item or "",body_font,body_px,dx+pad+12*cs,top+8*cs,width-24*cs,
                path_h,ui_theme.text,{cs=cs})
        else
            local y=top+8*cs
            for _,item in ipairs(items) do
                local _,lines=wrapped_text(item,body_font,width-24*cs)
                local h=lines*body_font:getHeight()
                plain(wrapped_text(item,body_font,width-24*cs),dx+pad+12*cs,y,body_px,ui_theme.text,"left",width-24*cs)
                y=y+h+22*cs
            end
        end
    end
    if d.checkbox then
        panel(dx+pad,option_y,width,checkbox_h,dialog_focus==3,false,true,{kind="button"})
        draw_checkbox(dx+pad+12*cs,option_y+(checkbox_h-26*cs)/2,26*cs,checked,dialog_focus==3,false,d.checkbox)
        local label,lines=wrapped_text(d.checkbox.label,body_font,width-58*cs)
        plain(label,dx+pad+50*cs,option_y+(checkbox_h-lines*body_font:getHeight())/2,body_px,ui_theme.text,"left",width-58*cs)
    end
    local cancel_x,confirm_x=draw_app_actions(d,dx+pad,by,width,bh,cs,danger)
    local hint_y=by+bh+8*cs
    if d.scroll_items and #items>1 then
        plain(string.format("↑↓  %d / %d",d._item_index or 1,#items),dx+pad,hint_y,16*cs,ui_theme.muted,"left",width)
    end
    plain(app_input_hint(),dx+pad,hint_y,16*cs,ui_theme.muted,"right",width)
    d._geometry={top=dy,bottom=dy+dh,title_y=title_y,title_bottom=title_bottom,content_y=content_y,
        identity_bottom=identity_bottom,message_bottom=message_bottom,message_height=message_h,
        message_line_height=body_font:getHeight(),action_y=by,
        action_bottom=by+bh,cancel_x=cancel_x,confirm_x=confirm_x}
end

local function draw_dropdown(d,L)
    local row,cs=d.select_row,L.cs
    local g=L.geometry and L.geometry[focus_i] or
        {x=L.x,y=L.top+(focus_i-L.first)*(L.rh+L.gap),w=L.w,h=L.rh}
    local width=g.w
    if t(row.label or "")~="" then width=math.min((L.app and 260 or 230)*cs,g.w*0.48) end
    local x=g.x+g.w-width-(t(row.label or "")~="" and 16*cs or 0)
    local pad=6*cs
    local px=18*cs
    local height=math.max(44*cs,body_fnt(px):getHeight()+16*cs)
    local menu_h=pad*2+#row.values*height
    local y=g.y+g.h+6*cs
    if y+menu_h>H-12*cs then y=g.y-menu_h-6*cs end
    y=math.max(12*cs,math.min(y,H-12*cs-menu_h))
    love.graphics.setColor(0,0,0,0.35)
    love.graphics.rectangle("fill",x+3*cs,y+4*cs,width,menu_h,8*cs,8*cs)
    panel(x,y,width,menu_h,false,false,L.app,{kind="button",appearance="secondary"})
    for i,value in ipairs(row.values) do
        local iy=y+pad+(i-1)*height
        local inactive=row.disabled_values and row.disabled_values[value]
        panel(x+pad,iy,width-pad*2,height,i==d._select_index,inactive,L.app,{kind="button",appearance="list"})
        local color=inactive and ui_theme.muted or ui_theme.text
        plain(t(row.labels and row.labels[value] or value),x+16*cs,iy+vcen(px,height),px,
            color,"left",width-46*cs)
        if value==state[row.key] then
            local cx,cy=x+width-20*cs,iy+height/2
            love.graphics.setColor(ui_theme.accent); love.graphics.setLineWidth(math.max(1,2*cs))
            love.graphics.line(cx-5*cs,cy,cx-1*cs,cy+4*cs,cx+6*cs,cy-5*cs)
        end
    end
    d._geometry={top=y,bottom=y+menu_h,left=x,right=x+width,option_height=height}
end

local function draw_dialog(L)
    local d=dialog_state
    if not d then return end
    if d.select_row then draw_dropdown(d,L); return end
    if L.app and d.item_groups then draw_uninstall_review(d,L); return end
    if L.app then draw_app_confirmation(d,L); return end
    local cs=L.app and app_content_scale() or math.max(APP_MINCS,math.min(1,H/720))
    local checked=d._checkbox_checked==true
    local effective_danger=d.danger==true or (d.checkbox and d.checkbox.danger==true and checked)
    local title=checked and d.title_checked or d.title
    local message=checked and d.message_checked or d.message
    local items=d.items or {}
    local grouped=d.item_groups~=nil
    local dw=math.min(W-36*cs,(grouped and 900 or 640)*cs)
    if L.app and not grouped then
        for _,item in ipairs(items) do
            local _,lines=wrapped_text(item,body_fnt(DIALOG_ITEM_PX*cs),dw-52*cs)
            if lines>1 or #items>4 then d.scroll_items=true; break end
        end
    end
    local shown=d.scroll_items and math.min(1,#items) or math.min(4,#items)
    local compact_review=(d.scroll_items or grouped) and H<360
    local pad=(compact_review and 18 or 26)*cs
    local title_px=(compact_review and 24 or 28)*cs
    local title_text,title_lines=wrapped_text(title or {en="Confirm action",zh="确认操作"},fnt(title_px),dw-pad*2,3)
    local title_h=title_lines*fnt(title_px):getHeight()
    local message_text,message_lines="",0
    local message_font=body_fnt(DIALOG_BODY_PX*cs)
    local item_line_h=math.max(33*cs,body_fnt(DIALOG_ITEM_PX*cs):getHeight()+4*cs)
    local more_h=#items>shown and 27*cs or 0
    local checkbox_h=d.checkbox and 62*cs or 0
    if message then message_text,message_lines=wrapped_text(message,message_font,dw-pad*2,compact_review and 2 or 3) end
    local message_h=message and (message_lines*message_font:getHeight()+10*cs) or 0
    local dh=math.max(240*cs,pad*2+title_h+20*cs+message_h+shown*item_line_h+more_h+checkbox_h+72*cs)
    dh=(d.scroll_items or grouped) and H-44*cs or math.min(dh,H-44*cs)
    local dx,dy=(W-dw)/2,(H-dh)/2
    local gap=12*cs; local bw=(dw-pad*2-gap)/2; local bh=50*cs; local by=dy+dh-pad-bh

    love.graphics.setColor(0,0,0,0.76); love.graphics.rectangle("fill",0,0,W,H)
    panel(dx,dy,dw,dh,false,false,L.app,{appearance="secondary"})
    if effective_danger then
        love.graphics.setColor(0.72,0.18,0.22,1); love.graphics.rectangle("fill",dx,dy,dw,5*cs,10,10)
    end

    local content_y=dy+(compact_review and 18 or 24)*cs
    outlined(title_text,dx+pad,content_y,title_px,
        effective_danger and {1,0.72,0.72} or {1,1,1},"left",dw-pad*2)
    local title_bottom=content_y+title_h
    content_y=title_bottom+10*cs
    d._geometry={top=dy,bottom=dy+dh,title_bottom=title_bottom,content_y=content_y,action_y=by}
    if message then
        draw_textview_text(message,message_font,DIALOG_BODY_PX*cs,dx+pad,content_y,dw-pad*2,
            message_h-10*cs,ui_theme.muted,{cs=cs})
        content_y=content_y+message_h
    end
    local function clip_line(value,px,max_w)
        value=t(value); local font=body_fnt(px)
        if not font.getWidth or font:getWidth(value)<=max_w then return value end
        local out=""
        for char in value:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            if font:getWidth(out..char.."…")>max_w then break end
            out=out..char
        end
        return out.."…"
    end
    if grouped then
        local hint_px=16*cs
        local hint_y=by-gap-body_fnt(hint_px):getHeight()
        draw_dialog_groups(d,dx+pad,content_y,dw-pad*2,math.max(1,hint_y-content_y-8*cs),cs)
        local hint=state.ui_lang=="zh" and "↑↓ 滚动查看 · ←→ 选择操作" or "Up/Down: scroll · Left/Right: choose"
        plain(hint,dx+pad,hint_y,hint_px,{0.72,0.72,0.80},"left",dw-pad*2)
    elseif d.scroll_items then
        local index=d._item_index or 1
        if not compact_review then
            plain(string.format("%d / %d",index,#items),dx+pad,content_y,DIALOG_AUX_PX*cs,ui_theme.accent,"left",dw-pad*2)
            content_y=content_y+body_fnt(DIALOG_AUX_PX*cs):getHeight()+8*cs
        end
        local hint=state.ui_lang=="zh" and "↑↓ 查看 · ←→ 选择" or "↑↓ Review · ←→ Choose"
        local hint_px=16*cs; local hint_y=by-gap-body_fnt(hint_px):getHeight()
        local px=DIALOG_ITEM_PX*cs; local font=body_fnt(px)
        local available=hint_y-content_y-8*cs
        local path_h=math.max(font:getHeight(),math.floor(available/font:getHeight())*font:getHeight())
        draw_textview_text(items[index] or "",font,px,dx+pad,content_y,dw-pad*2,
            path_h,{0.94,0.94,0.97},{cs=cs})
        plain(hint,dx+pad,hint_y,hint_px,{0.72,0.72,0.80},"left",dw-pad*2)
        if compact_review then
            plain(string.format("%d/%d",index,#items),dx+pad,hint_y,hint_px,ui_theme.accent,"right",dw-pad*2)
        end
    else
        for i=1,shown do
            local label=clip_line("• "..t(items[i]),DIALOG_ITEM_PX*cs,dw-pad*2)
            plain(label,dx+pad,content_y+(i-1)*item_line_h,DIALOG_ITEM_PX*cs,{0.94,0.94,0.97},"left",dw-pad*2)
        end
        content_y=content_y+shown*item_line_h
        if #items>shown then
            local more=#items-shown
            local label=state.ui_lang=="zh" and string.format("另有 %d 项",more) or string.format("%d more items",more)
            plain(label,dx+pad,content_y,DIALOG_AUX_PX*cs,{0.72,0.72,0.80},"left",dw-pad*2)
        end
    end

    if d.checkbox then
        local option_h=50*cs; local option_y=by-gap-option_h
        panel(dx+pad,option_y,dw-pad*2,option_h,dialog_focus==3,false,L.app)
        local check_size=26*cs; local check_x=dx+pad+14*cs
        draw_checkbox(check_x,option_y+(option_h-check_size)/2,check_size,checked,dialog_focus==3,false,d.checkbox)
        local color=d.checkbox.danger and checked and {1,0.62,0.62} or {0.96,0.94,1}
        local px=18*cs
        local text,lines=wrapped_text(d.checkbox.label or "",body_fnt(px),dw-pad*2-68*cs,2)
        plain(text,check_x+40*cs,option_y+(option_h-lines*body_fnt(px):getHeight())/2,px,
            color,"left",dw-pad*2-68*cs)
    end
    local function draw_button(index,x,label,danger)
        local focused=dialog_focus==index
        d._buttons=d._buttons or {{appearance="primary"},{appearance="secondary"}}
        panel(x,by,bw,bh,focused,false,L.app,d._buttons[index],danger)
        plain(t(label),x,by+vcen(20*cs,bh),20*cs,{1,1,1},"center",bw)
    end
    local confirm_label=checked and d.confirm_checked or d.confirm
    draw_button(1,dx+pad,confirm_label or {en="Confirm",zh="确认"},effective_danger)
    draw_button(2,dx+pad+bw+gap,d.cancel or {en="Cancel",zh="取消"},false)
end

local function guide_target_rect(L,target)
    if target=="header" then return {x=18*L.cs,y=18*L.cs,w=145*L.cs,h=54*L.cs} end
    local page=pages[page_i] or {}
    if target=="footer" then
        local footer=page.sidebar_footer
        local lines=footer and (footer.lines or footer) or nil
        if not lines or #lines==0 then return nil end
        local bottom=L.band_top+L.band
        local side=sidebar(); local geometry=sidebar_geometry(L)
        for index,g in pairs(geometry) do
            if side[index].group=="bottom" then bottom=math.min(bottom,g.y-L.gap) end
        end
        local h=(#lines*SIDEBAR_FOOTER_LINE_H+SIDEBAR_FOOTER_PAD)*L.cs
        return {x=L.side_x,y=bottom-h,w=L.side_w,h=h}
    end
    local side=sidebar(); local geometry=sidebar_geometry(L)
    for index,row in ipairs(side) do
        if row_identity(row)==target then return geometry[index] end
    end
    for index,row in ipairs(cur()) do
        if row_identity(row)==target then
            local g=L.geometry and L.geometry[index]
            if g then return {x=g.x,y=g.y,w=g.w,h=g.h} end
            if index>=L.first and index<=L.last then
                return {x=L.x,y=L.top+(index-L.first)*(L.rh+L.gap),w=L.w,h=L.rh}
            end
        end
    end
end

local function rect_union(rects)
    if #rects==0 then return nil end
    local x1,y1,x2,y2=rects[1].x,rects[1].y,rects[1].x+rects[1].w,rects[1].y+rects[1].h
    for i=2,#rects do
        local r=rects[i]
        x1=math.min(x1,r.x); y1=math.min(y1,r.y)
        x2=math.max(x2,r.x+r.w); y2=math.max(y2,r.y+r.h)
    end
    return {x=x1,y=y1,w=x2-x1,h=y2-y1}
end

local function rect_overlap(a,b,pad)
    pad=pad or 0
    local x=math.max(0,math.min(a.x+a.w,b.x+b.w+pad)-math.max(a.x,b.x-pad))
    local y=math.max(0,math.min(a.y+a.h,b.y+b.h+pad)-math.max(a.y,b.y-pad))
    return x*y
end

local function coach_card_position(target,cw,ch,cs)
    local margin,gap=18*cs,18*cs
    if not target then return (W-cw)/2,(H-ch)/2,"center" end
    local cx,cy=target.x+target.w/2,target.y+target.h/2
    local order
    if cx>W*0.62 then order={"left","above","below","right"}
    elseif cx<W*0.38 and cy<H*0.30 then order={"below","right","left","above"}
    elseif cy>H*0.68 then order={"above","right","left","below"}
    else order={"right","left","below","above"} end
    local ideals={
        left={x=target.x-gap-cw,y=cy-ch/2},
        right={x=target.x+target.w+gap,y=cy-ch/2},
        above={x=cx-cw/2,y=target.y-gap-ch},
        below={x=cx-cw/2,y=target.y+target.h+gap},
    }
    local best,best_score
    for rank,name in ipairs(order) do
        local ideal=ideals[name]
        local x=math.max(margin,math.min(ideal.x,W-margin-cw))
        local y=math.max(margin,math.min(ideal.y,H-margin-ch))
        local card={x=x,y=y,w=cw,h=ch}
        local moved=math.abs(x-ideal.x)+math.abs(y-ideal.y)
        local score=rank*10+moved*4+rect_overlap(card,target,gap)*1000
        if not best_score or score<best_score then best,best_score={x=x,y=y,side=name},score end
    end
    return best.x,best.y,best.side
end

local function coach_arrow(card,target,cs)
    if not target then return end
    local cx,cy=card.x+card.w/2,card.y+card.h/2
    local tx,ty=target.x+target.w/2,target.y+target.h/2
    local dx,dy=tx-cx,ty-cy
    if math.abs(dx)<0.01 and math.abs(dy)<0.01 then return end
    local card_scale=math.min((card.w/2)/math.max(0.01,math.abs(dx)),
        (card.h/2)/math.max(0.01,math.abs(dy)))
    local target_scale=math.min((target.w/2+6*cs)/math.max(0.01,math.abs(dx)),
        (target.h/2+6*cs)/math.max(0.01,math.abs(dy)))
    local sx,sy=cx+dx*card_scale,cy+dy*card_scale
    local ex,ey=tx-dx*target_scale,ty-dy*target_scale
    local length=math.sqrt((ex-sx)^2+(ey-sy)^2)
    if length<8*cs then return end
    local ux,uy=(ex-sx)/length,(ey-sy)/length
    local head=11*cs
    love.graphics.setColor(is_app() and ui_theme.accent or {1.0,0.78,0.36,0.96}); love.graphics.setLineWidth(math.max(2,2*cs))
    love.graphics.line(sx,sy,ex,ey)
    love.graphics.polygon("fill",ex,ey,
        ex-ux*head-uy*head*0.55,ey-uy*head+ux*head*0.55,
        ex-ux*head+uy*head*0.55,ey-uy*head-ux*head*0.55)
end

local function draw_guide(L)
    local guide=guide_state
    if not guide then return end
    if letterbox then love.graphics.setScissor(offX,offY,W,H) else love.graphics.setScissor() end
    local cs=L.cs; local callouts=guide.callouts or {}; local count=#callouts
    local index=math.max(1,math.min(guide._index or 1,count)); local callout=callouts[index]
    local targets=callout.targets or {callout.target}; local rects={}
    for _,target in ipairs(targets) do
        local rect=guide_target_rect(L,target)
        if rect then rects[#rects+1]=rect end
    end
    local target=rect_union(rects); local hole_pad=6*cs
    guide._target_rect=target

    -- Draw one stencil mask for the current semantic target. The real control
    -- remains fully visible through the hole while the rest of the live page is
    -- darkened, so the guide stays correct across resolutions and themes.
    if target and love.graphics.stencil and love.graphics.setStencilTest then
        love.graphics.stencil(function()
            for _,rect in ipairs(rects) do
                love.graphics.rectangle("fill",rect.x-hole_pad,rect.y-hole_pad,
                    rect.w+hole_pad*2,rect.h+hole_pad*2,10*cs,10*cs)
            end
        end,"replace",1,false)
        love.graphics.setStencilTest("equal",0)
        love.graphics.setColor(0,0,0,0.82); love.graphics.rectangle("fill",0,0,W,H)
        love.graphics.setStencilTest()
    else
        love.graphics.setColor(0,0,0,0.82); love.graphics.rectangle("fill",0,0,W,H)
    end

    for _,rect in ipairs(rects) do
        love.graphics.setColor(L.app and ui_theme.accent or {1.0,0.78,0.36,0.98}); love.graphics.setLineWidth(math.max(2,3*cs))
        love.graphics.rectangle("line",rect.x-hole_pad,rect.y-hole_pad,
            rect.w+hole_pad*2,rect.h+hole_pad*2,10*cs,10*cs)
    end

    local pad=22*cs; local cw=math.min(W-36*cs,430*cs); local inner_w=cw-pad*2
    local body_text=t(callout.body or "")
    if index==1 and guide.message and not L.compact then body_text=t(guide.message).."\n"..body_text end
    local body_font=body_fnt(18*cs)
    local _,body_lines=wrapped_text(body_text,body_font,inner_w)
    local title_font=body_fnt(23*cs)
    local title,title_lines=wrapped_text(callout.title or guide.title or "",title_font,inner_w,2)
    local progress_h=23*cs; local title_h=title_lines*title_font:getHeight()
    local button_h=48*cs
    local fixed=pad*2+progress_h+8*cs+title_h+10*cs+18*cs+button_h
    local max_body_h=math.max(body_font:getHeight(),math.floor((H-36*cs-fixed)/body_font:getHeight())*body_font:getHeight())
    local body_h=math.min(body_lines*body_font:getHeight(),max_body_h)
    local ch=fixed+body_h
    local dx,dy=coach_card_position(target,cw,ch,cs)
    local card={x=dx,y=dy,w=cw,h=ch}
    coach_arrow(card,target,cs)

    love.graphics.setColor(L.app and ui_theme.surface or {0.045,0.030,0.070,0.985})
    love.graphics.rectangle("fill",dx,dy,cw,ch,12*cs,12*cs)
    love.graphics.setColor(L.app and ui_theme.review_border or {0.78,0.68,0.91,0.78}); love.graphics.setLineWidth(1)
    love.graphics.rectangle("line",dx,dy,cw,ch,12*cs,12*cs)
    local progress=string.format("%d / %d",index,count)
    plain(progress,dx+pad,dy+pad,16*cs,L.app and ui_theme.accent or {1.0,0.78,0.36},"left",inner_w)
    local title_y=dy+pad+progress_h+8*cs
    outlined(title,dx+pad,title_y,23*cs,{1,1,1},"left",inner_w)
    local body_y=title_y+title_h+10*cs
    draw_textview_text(body_text,body_font,18*cs,dx+pad,body_y,inner_w,body_h,ui_theme.text,{cs=cs})

    local button_y=dy+ch-pad-button_h
    panel(dx+pad,button_y,inner_w,button_h,true,false,true,{appearance="primary"})
    local button_label=index==count and (guide.confirm or {en="Start using",zh="开始使用"}) or
        (guide.next or {en="Next",zh="下一步"})
    plain(t(button_label),dx+pad,button_y+vcen(20*cs,button_h),20*cs,{1,1,1},"center",inner_w)
end

-- Measure each progress section before placing fixed controls below it.
local function draw_busy_overlay(L)
    love.graphics.setColor(0,0,0,0.72); love.graphics.rectangle("fill",0,0,W,H)
    local detailed=busy_info~=nil
    local cancellable=detailed and type(busy_info.on_cancel)=="function"
    local cs=L.cs
    local bw=math.min(W-36*cs,620*cs)
    local pad,gap=24*cs,10*cs
    local inner_w=bw-pad*2
    if not detailed then
        local bh=90*cs
        local bx,by=(W-bw)/2,(H-bh)/2
        panel(bx,by,bw,bh,false,false,L.app,{appearance="secondary"})
        plain(t(busy_message or "working"),bx,by+vcen(22*cs,bh),22*cs,ui_theme.text,"center",bw)
        return
    end
    local title_px,stage_px,detail_px,metric_px=23*cs,19*cs,18*cs,18*cs
    local title,title_lines=wrapped_text(busy_message or "working",body_fnt(title_px),inner_w,2)
    local stage,stage_lines=wrapped_text(busy_info.stage or "",body_fnt(stage_px),inner_w,2)
    local detail,detail_lines=wrapped_text(busy_info.detail or "",body_fnt(detail_px),inner_w,2)
    local title_h=title_lines*body_fnt(title_px):getHeight()
    local stage_h=stage_lines*body_fnt(stage_px):getHeight()
    local detail_h=detail_lines*body_fnt(detail_px):getHeight()
    local left,right=t(busy_info.footer_left or ""),t(busy_info.footer_right or "")
    local metric_font=body_fnt(metric_px)
    local stacked=metric_font:getWidth(left)+metric_font:getWidth(right)+20*cs>inner_w
    local metric_h=metric_font:getHeight()
    local metrics_h=metric_h*(stacked and 2 or 1)+(stacked and 4*cs or 0)
    local track_h=20*cs
    local bh=pad*2+title_h+stage_h+detail_h+gap*4+track_h+metrics_h+(cancellable and 58*cs or 0)
    local bx,by=(W-bw)/2,(H-bh)/2
    panel(bx,by,bw,bh,false,false,L.app,{appearance="secondary"})
    local x,y=bx+pad,by+pad
    plain(title,x,y,title_px,ui_theme.text,"left",inner_w); y=y+title_h+gap
    plain(stage,x,y,stage_px,ui_theme.accent,"left",inner_w); y=y+stage_h+gap/2
    plain(detail,x,y,detail_px,ui_theme.muted,"left",inner_w); y=y+detail_h+gap
    local track_y=y
    local indeterminate=busy_info.indeterminate==true
    local progress=math.max(0,math.min(1,tonumber(busy_info.progress) or busy_display_progress or 0))
    local radius=math.max(4,8*cs)
    love.graphics.setColor(ui_theme.navigation_background)
    love.graphics.rectangle("fill",x,track_y,inner_w,track_h,radius,radius)
    if indeterminate then
        local segment=inner_w*0.28
        local offset=(busy_elapsed*0.38%1)*(inner_w+segment)-segment
        local fill_x=math.max(x,x+offset)
        local fill_right=math.min(x+inner_w,x+offset+segment)
        if fill_right>fill_x then
            love.graphics.setColor(ui_theme.accent)
            love.graphics.rectangle("fill",fill_x,track_y,fill_right-fill_x,track_h,radius,radius)
        end
    elseif progress>0 then
        love.graphics.setColor(0.48,0.32,0.69,1)
        love.graphics.rectangle("fill",x,track_y,inner_w*progress,track_h,radius,radius)
    end
    plain(indeterminate and "…" or string.format("%d%%",math.floor(progress*100+0.5)),
        x,track_y+vcen(16*cs,track_h),16*cs,ui_theme.text,"center",inner_w)
    y=track_y+track_h+gap
    plain(left,x,y,metric_px,ui_theme.muted,"left",inner_w)
    plain(right,x,stacked and y+metric_h+4*cs or y,metric_px,ui_theme.muted,
        stacked and "left" or "right",inner_w)
    y=y+metrics_h+gap
    if cancellable then
        local ch=48*cs
        panel(x,y,inner_w,ch,true,busy_info.cancel_disabled==true,L.app,{appearance="secondary"})
        plain(t(busy_info.cancel_requested and (busy_info.cancelling_label or "Cancelling…") or
            (busy_info.cancel_label or busy_info.cancel or "Cancel")),x,y+vcen(19*cs,ch),19*cs,
            busy_info.cancel_disabled and ui_theme.muted or ui_theme.text,"center",inner_w)
    end
    busy_info._geometry={top=by,bottom=by+bh,stacked_metrics=stacked,
        cancel_y=cancellable and y or nil,metrics_bottom=track_y+track_h+gap+metrics_h}
end


function kit.draw()
    text_scroll_active=false
    components.begin_frame()
    if letterbox then love.graphics.push(); love.graphics.translate(offX,offY); love.graphics.setScissor(offX,offY,W,H) end

    if guide_state and guide_state._prepared_index~=guide_state._index then
        guide_state._focus=guide_state._focus or capture_focus()
        local callout=guide_state.callouts[guide_state._index]
        local target=callout and (callout.target or (callout.targets or {})[1])
        local found=false
        for i,row in ipairs(sidebar()) do
            if row_identity(row)==target then zone="sidebar"; sidebar_i=i; found=true; break end
        end
        if not found then
            for i,row in ipairs(cur()) do
                if row_identity(row)==target then zone="rows"; focus_i=i; break end
            end
        end
        guide_state._prepared_index=guide_state._index
    end
    local L = layout()
    if L.app then
        love.graphics.setColor(ui_theme.background); love.graphics.rectangle("fill",0,0,W,H)
        if L.navigation and not L.compact then
            love.graphics.setColor(ui_theme.navigation_background)
            love.graphics.rectangle("fill",0,0,L.side_x+L.side_w+12*L.cs,H)
        end
    elseif bg_img then
        local iw,ih=bg_img:getDimensions(); local sc=math.max(W/iw,H/ih)
        love.graphics.setColor(1,1,1,1); love.graphics.draw(bg_img,(W-iw*sc)/2,(H-ih*sc)/2,0,sc,sc)
    end
    if not L.app then love.graphics.setColor(0,0,0,L.dim); love.graphics.rectangle("fill",0,0,W,H) end

    draw_bar(L)
    if L.app then
        love.graphics.setColor(ui_theme.divider); love.graphics.setLineWidth(1)
        if L.has_sidebar and not L.compact and not L.navigation then
            local divider=L.navigation and L.side_x+L.side_w+L.gap or L.divider_x
            love.graphics.line(divider,L.band_top,divider,L.band_top+L.band)
        end
    end

    local function meta_badge(r)
        return r.badge or (r.meta and r.meta.badge) or nil
    end
    if L.geometry and not (L.compact and tools_visible()) then love.graphics.setScissor(offX+L.x,offY+L.band_top,L.w,L.band) end
    local rows = cur(); local yi=0
    if not (L.compact and tools_visible()) then
    for i=L.first,L.last do
        local r=rows[i]; local g=L.geometry and L.geometry[i]
        local x=g and g.x or L.x; local y=g and g.y or (L.top+yi*(L.rh+L.gap)); yi=yi+1
        local rw=g and g.w or L.w; local row_h=g and g.h or L.rh
        -- Fixed header tools keep the first index visible. Skip clipped list
        -- rows before drawing so scrolling does not decode every earlier cover.
        if not g or g.fixed or (y+row_h>L.band_top and y<L.band_top+L.band) then
        if L.geometry then
            if g.fixed then
                if letterbox then love.graphics.setScissor(offX,offY,W,H) else love.graphics.setScissor() end
            else love.graphics.setScissor(offX+L.x,offY+L.band_top,L.w,L.band) end
        end
        local focused = (zone=="rows" and i==focus_i)
        local button_hint_w=L.app and r.kind=="button" and not r.inline and r.chevron~=false and not disabled(r) and 30*L.cs or 0
        local ty = y + vcen(ROW_PX*L.cs, row_h)
        if r.kind=="section" then
            local px=(L.app and 17 or r.font_px or 21)*L.cs
            plain(t(r.label),x+(L.app and 16 or 4)*L.cs,y+vcen(px,row_h),px,L.app and ui_theme.muted or {1.0,0.78,0.36},"left",rw-32*L.cs)
            if not L.app then
                love.graphics.setColor(1.0,0.78,0.36,0.42); love.graphics.setLineWidth(1)
                love.graphics.line(x,y+row_h-8*L.cs,x+rw,y+row_h-8*L.cs)
            end
        else
            if r.surface~=false then
                panel(x,y,rw,row_h,focused,disabled(r),L.app,r)
            end
        if r.kind=="picker" then
            local compact_select=r.dropdown and t(r.label or "")==""
            local select_w=compact_select and rw or math.min((L.app and 260 or 230)*L.cs,rw*0.48)
            local select_h=compact_select and row_h or (L.app and 42 or 38)*L.cs
            local select_x=compact_select and x or x+rw-select_w-16*L.cs
            local select_y=y+(row_h-select_h)/2
            local leading=L.app and r.icon and not compact_select and 62*L.cs or 0
            if leading>0 then draw_thumbnail(nil,x+16*L.cs,y+(row_h-48*L.cs)/2,48*L.cs,r.icon) end
            local label_w=math.max(1,select_x-x-30*L.cs-leading)
            local label=clip_ellipsis(tostring(t(r.label) or ""),body_fnt(ROW_PX*L.cs),label_w)
            if not compact_select then plain(label,x+(leading>0 and 16*L.cs+leading or 18*L.cs),ty,ROW_PX*L.cs,{1,1,1}) end
            local disp=r.display_value or (r.labels and r.labels[state[r.key]]) or state[r.key]
            disp=t(disp)
            draw_select(select_x,select_y,select_w,select_h,disp,focused,disabled(r),L.cs,r.dropdown,r.form_field)
        elseif r.kind=="checkbox" then
            if r.selection_item then
                local pad=16*L.cs
                local check_size=27*L.cs
                local check_x=x+rw-pad-check_size
                draw_checkbox(check_x,y+(row_h-check_size)/2,check_size,r.checked,focused,disabled(r),r)
                local leading=(r.thumbnail or r.icon) and 60*L.cs or 0
                if leading>0 then draw_thumbnail(r.thumbnail,x+pad,y+(row_h-48*L.cs)/2,48*L.cs,r.icon or "games") end
                local tx=x+pad+leading
                local badge=meta_badge(r)
                local badge_w=badge and body_fnt(16*L.cs):getWidth(t(badge.text))+18*L.cs or 0
                local width=math.max(1,check_x-14*L.cs-tx)
                local px=(r.label_px or 24)*L.cs
                local detail_px=(r.detail_px or 17)*L.cs
                local label_h=body_fnt(px):getHeight()
                local detail_h=r.detail and body_fnt(detail_px):getHeight()+4*L.cs or 0
                local top=y+(row_h-label_h-detail_h)/2
                local label_width=math.max(1,width-badge_w)
                if focused then draw_textview_text(r.label,body_fnt(px),px,tx,top,label_width,label_h,ui_theme.text,L,true)
                else plain(clip_ellipsis(t(r.label),body_fnt(px),label_width),tx,top,px,ui_theme.text,"left",label_width) end
                if r.detail then
                    draw_textview_text(r.detail,body_fnt(detail_px),detail_px,tx,top+label_h+4*L.cs,width,
                        detail_h-4*L.cs,ui_theme.muted,L,true)
                end
                if badge then plain(t(badge.text),check_x-14*L.cs-badge_w,top+vcen(16*L.cs,label_h),16*L.cs,
                    badge.color or ui_theme.accent,"right",badge_w) end
            else
            local check_size=(L.app and 32 or 28)*L.cs
            local check_x=x+(L.app and 20 or 15)*L.cs
            local check_y=y+(row_h-check_size)/2
            draw_checkbox(check_x,check_y,check_size,r.checked,focused,disabled(r),r)
            local tx=x+(L.app and 70 or 56)*L.cs
            if r.detail then
                local label_px=(r.label_px or (L.app and 22 or 20))*L.cs
                local detail_px=(r.detail_px or (L.app and 19 or 16))*L.cs
                local inner_w=math.max(1,rw-(tx-x)-(L.app and 18 or 12)*L.cs)
                local badge=meta_badge(r); local label_w=inner_w-(badge and 76*L.cs or 0)
                local label=clip_ellipsis(tostring(t(r.label) or ""),body_fnt(label_px),math.max(1,label_w))
                local detail=wrapped_text(r.detail,body_fnt(detail_px),inner_w,r.detail_max_lines or 1)
                plain(label,tx,y+(L.app and 10 or 7)*L.cs,label_px,{1,1,1},"left",math.max(1,label_w))
                local detail_y=L.app and y+10*L.cs+body_fnt(label_px):getHeight()+6*L.cs or y+31*L.cs
                plain(detail,tx,detail_y,detail_px,{0.78,0.78,0.84},"left",inner_w)
            else
                if L.app then
                    local px=(r.label_px or 22)*L.cs
                    local font=body_fnt(px)
                    local inner_w=math.max(1,rw-(tx-x)-18*L.cs)
                    local _,lines=wrapped_text(r.label,font,inner_w)
                    local text_h=math.min(lines*font:getHeight(),row_h-20*L.cs)
                    draw_textview_text(r.label,font,px,tx,y+(row_h-text_h)/2,inner_w,text_h,ui_theme.text,L)
                else plain(t(r.label),tx,ty,ROW_PX*L.cs,{1,1,1}) end
            end
            end
        elseif r.kind=="switch" then
            local raw=switch_current(r)
            local on=raw==r.on_value
            local leading=L.app and r.icon and not r.header_toolbar and 62*L.cs or 0
            if leading>0 then draw_thumbnail(nil,x+16*L.cs,y+(row_h-48*L.cs)/2,48*L.cs,r.icon) end
            local label_x=x+(leading>0 and 16*L.cs+leading or (r.header_toolbar and 4 or 18)*L.cs)
            local track_w,track_h=(r.header_toolbar and 48 or 68)*L.cs,(r.header_toolbar and 26 or 30)*L.cs
            local track_x=x+rw-track_w-(r.header_toolbar and 4 or 18)*L.cs
            local track_y=y+(row_h-track_h)/2
            local label_px=(r.label_px or ROW_PX)*L.cs
            if r.detail then
                -- One combined row: label + live detail on the left, the
                -- switch on the right (e.g. remote management address).
                local detail_px=(r.detail_px or 17)*L.cs
                local tx=label_x
                local inner_w=math.max(1,track_x-tx-12*L.cs)
                local label=clip_ellipsis(tostring(t(r.label) or ""),body_fnt(label_px),inner_w)
                local detail=clip_ellipsis(tostring(t(r.detail) or ""),body_fnt(detail_px),inner_w)
                plain(label,tx,y+8*L.cs,label_px,{1,1,1},"left",inner_w)
                plain(detail,tx,y+8*L.cs+label_px*L.cs+3*L.cs,detail_px,{0.72,0.72,0.82},"left",inner_w)
            else
                local label_y=centred_text_y(label_px,y,row_h,0)
                local label=on and r.on_label or r.off_label
                plain(t(label or r.label),label_x,label_y,label_px,ui_theme.text)
            end
            components.switch(r,track_x,track_y,track_w,track_h,on,disabled(r))
        elseif r.kind=="empty" then
            local px=20*L.cs
            local text,lines=wrapped_text(r.value,body_fnt(px),rw-40*L.cs)
            local text_h=lines*body_fnt(px):getHeight()
            local title_h=r.title and body_fnt(26*L.cs):getHeight()+12*L.cs or 0
            local top=y+math.max(10*L.cs,(row_h-text_h-title_h)/2)
            if r.title then plain(t(r.title),x+20*L.cs,top,26*L.cs,ui_theme.text,"center",rw-40*L.cs); top=top+title_h end
            plain(text,x+20*L.cs,top,px,ui_theme.muted,"center",rw-40*L.cs)
        elseif r.kind=="qrcode" then
            local pad=(r.centered and 0 or 12)*L.cs
            local caption_h=r.label and body_fnt(16*L.cs):getHeight()+8*L.cs or 0
            qr_view.draw(t(r.value),x+pad,y+pad,rw-pad*2,row_h-pad*2-caption_h)
            if r.label then plain(t(r.label),x+pad,y+row_h-pad-caption_h+8*L.cs,16*L.cs,
                focused and ui_theme.accent or ui_theme.muted,"center",rw-pad*2) end
        elseif r.kind=="info" then
            plain(t(r.label),x+16*L.cs,y+6*L.cs,18*L.cs,{0.72,0.72,0.82})
            plain(t(r.value),x+16*L.cs,y+29*L.cs,20*L.cs,{1,1,1},"left",rw-32*L.cs)
        elseif r.kind=="list_item" then
            local px=(r.font_px or 19)*L.cs; local inner_w=math.max(1,rw-32*L.cs); local font=body_fnt(px)
            local value=clip_ellipsis(tostring(t(r.value) or ""),font,inner_w)
            plain(value,x+16*L.cs,centred_text_y(px,y,row_h,0.5*L.cs),px,
                disabled(r) and {0.55,0.55,0.57} or {0.96,0.94,1},"left",inner_w)
        elseif r.kind=="textview" then
            if (r.form_field or r.hero or r.metric) and L.app then
                if r.hero then
                    love.graphics.setColor(ui_theme.surface)
                    love.graphics.rectangle("fill",x,y,rw,row_h,10*L.cs,10*L.cs)
                end
                if focused then panel(x,y,rw,row_h,true,false,true,r) end
                if r.metric then
                    plain(t(r.label),x+16*L.cs,y+12*L.cs,18*L.cs,ui_theme.muted,"left",rw-32*L.cs)
                    plain(t(r.value),x+16*L.cs,y+12*L.cs+body_fnt(18*L.cs):getHeight()+6*L.cs,
                        (r.value_px or 32)*L.cs,ui_theme.text,"left",rw-32*L.cs)
                elseif r.hero then
                    draw_thumbnail(r.thumbnail,x+20*L.cs,y+(row_h-60*L.cs)/2,60*L.cs,"app")
                    local block=body_fnt(26*L.cs):getHeight()+7*L.cs+body_fnt(18*L.cs):getHeight()
                    local top=y+(row_h-block)/2
                    plain(t(r.label),x+100*L.cs,top,26*L.cs,ui_theme.text,"left",rw-116*L.cs)
                    plain(t(r.value),x+100*L.cs,top+body_fnt(26*L.cs):getHeight()+7*L.cs,18*L.cs,ui_theme.muted,"left",rw-116*L.cs)
                else
                    local field=field_layout(r,rw,L.cs)
                    local label_y=field.stacked and y+field.pad or y+(row_h-field.label_h)/2
                    local label_width=field.stacked and rw-field.pad*2 or field.label_w
                    draw_textview_text(r.label,body_fnt(field.label_px),field.label_px,x+field.pad,label_y,
                        label_width,field.label_h,ui_theme.muted,L,true)
                    local vx=field.stacked and x+field.pad or x+rw-field.pad-field.value_w
                    local vy=field.stacked and label_y+field.label_h+7*L.cs or y+(row_h-field.value_h)/2
                    local vh=math.max(1,math.min(field.value_h,y+row_h-field.pad-vy))
                    local value=textview_content(r)
                    if not field.stacked and field.font:getWidth(value)<=field.value_w then
                        plain(value,vx,vy,field.value_px,ui_theme.text,"right",field.value_w)
                    else draw_textview_text(value,field.font,field.value_px,vx,vy,field.value_w,vh,ui_theme.text,L,r.preserve_lines) end
                end
            else
            if focused and L.app and r.surface==false then
                love.graphics.setColor(ui_theme.accent)
                love.graphics.rectangle("fill",x,y+12*L.cs,2*L.cs,row_h-24*L.cs,1,1)
            end
            if r.bg then
                love.graphics.setColor(r.bg[1],r.bg[2],r.bg[3],r.bg[4] or 0.92)
                love.graphics.rectangle("fill",x,y,rw,row_h,8,8)
            end
            local pad=(r.centered and 0 or 12)*L.cs
            local label_px=(r.label_px or 17)*L.cs
            local inner_w=rw-pad*2
            local value_px,value_font=textview_value(r,inner_w,L.cs)
            if r.centered then
                value_px,value_font=textview_value(r,inner_w,L.cs)
                local text=tostring(t(r.value) or "")
                local text_w=value_font:getWidth(text)
                if text_w<=inner_w then
                    plain(text,x,y+vcen(value_px,row_h),value_px,ui_theme.text,"center",rw)
                else
                    draw_textview_text(text,value_font,value_px,x,y,inner_w,row_h,ui_theme.text,L,true)
                end
            else
            local label_font=body_fnt(label_px)
            local _,label_lines=wrapped_text(r.label,label_font,inner_w,2)
            local label_h=label_lines*label_font:getHeight()
            local value_h=math.max(1,row_h-pad*2-label_h-5*L.cs)
            draw_textview_text(r.label,label_font,label_px,x+pad,y+pad,inner_w,label_h,r.heading and ui_theme.text or ui_theme.muted,L)
            draw_textview_text(textview_content(r),value_font,value_px,x+pad,y+pad+label_h+5*L.cs,inner_w,value_h,
                r.heading and ui_theme.muted or ui_theme.text,L,r.preserve_lines)
            end
            end
        elseif r.kind=="button" and r.detail then
            -- Two-line action card (home feature matrix): label on top,
            -- status line below, optional badge top-right.
            local pad=16*L.cs
            local label_px=(r.label_px or (L.app and 22 or 20))*L.cs
            local detail_px=(r.detail_px or (L.app and 18 or 15))*L.cs
            local leading=r.menu_item and r.icon and 62*L.cs or 0
            if leading>0 then draw_thumbnail(nil,x+pad,y+(row_h-48*L.cs)/2,48*L.cs,r.icon) end
            local inner_w=math.max(1,rw-pad*2-button_hint_w-leading)
            local badge=meta_badge(r); local label_w=inner_w-(badge and 76*L.cs or 0)
            local label=clip_ellipsis(tostring(t(r.label) or ""),body_fnt(label_px),math.max(1,label_w))
            local detail=wrapped_text(t(r.detail),body_fnt(detail_px),inner_w,r.detail_max_lines or 1)
            local label_h=body_fnt(label_px):getHeight()
            local detail_h=body_fnt(detail_px):getHeight()
            local top=L.app and y+(row_h-label_h-4*L.cs-detail_h)/2 or y+7*L.cs
            plain(label,x+pad+leading,top,label_px,
                disabled(r) and {0.55,0.53,0.60} or {1,1,1},"left",math.max(1,label_w))
            local detail_y=L.app and top+label_h+4*L.cs or y+31*L.cs
            plain(detail,x+pad+leading,detail_y,detail_px,
                disabled(r) and {0.48,0.47,0.52} or {0.78,0.78,0.84},"left",inner_w)
        else
            local pad=16*L.cs
            local px=(r.library_item and (L.compact and 26 or 25) or r.label_px or (L.app and 22 or ROW_PX))*L.cs
            local icon_w=r.library_item and (L.compact and 65 or 78)*L.cs or r.menu_item and r.icon and 62*L.cs or r.icon and 32*L.cs or 0
            if r.library_item then
                local size=(L.compact and 50 or 58)*L.cs
                draw_thumbnail(r.thumbnail,x+(L.compact and 8 or 12)*L.cs,y+(row_h-size)/2,size,r.icon)
            elseif r.menu_item and r.icon then
                draw_thumbnail(nil,x+pad,y+(row_h-48*L.cs)/2,48*L.cs,r.icon)
            elseif r.icon then
                love.graphics.setColor({0.68,0.64,0.74})
                ui_icons.draw(r.icon,x+pad,y+(row_h-20*L.cs)/2,20*L.cs)
            end
            local badge=meta_badge(r)
            local badge_w=badge and (body_fnt(16*L.cs):getWidth(tostring(t(badge.text) or ""))+12*L.cs) or 0
            local label_w=math.max(1,rw-pad*2-icon_w-badge_w-button_hint_w)
            local label=clip_ellipsis(tostring(t(r.label) or ""),body_fnt(px),label_w)
            local centered=(r.inline or r.header_toolbar) and not r.icon
            local color=disabled(r) and {0.55,0.53,0.60} or r.active and ui_theme.accent or ui_theme.text
            local tx=r.library_item and x+(L.compact and 73 or 90)*L.cs or centered and x+pad or x+pad+icon_w
            plain(label,tx,y+vcen(px,row_h),px,
                color,centered and "center" or "left",centered and (rw-pad*2) or label_w)
            if r.appearance=="tab" and r.active then
                love.graphics.setColor(ui_theme.accent)
                love.graphics.rectangle("fill",x+pad,y+row_h-3*L.cs,rw-pad*2,2*L.cs,1,1)
            end
        end
        if button_hint_w>0 then
            local cx,cy=x+rw-22*L.cs,y+row_h/2
            love.graphics.setColor(focused and ui_theme.focus_border or {0.72,0.65,0.83,1})
            love.graphics.setLineWidth(math.max(1,2*L.cs))
            love.graphics.line(cx-3*L.cs,cy-5*L.cs,cx+3*L.cs,cy,cx-3*L.cs,cy+5*L.cs)
            love.graphics.setLineWidth(1)
        end
        if L.app and not r.inline and r.kind~="qrcode" and r.kind~="empty" and not r.heading and not r.centered then
            love.graphics.setColor(ui_theme.divider); love.graphics.setLineWidth(1)
            love.graphics.line(x+16*L.cs,y+row_h+L.gap/2,x+rw-16*L.cs,y+row_h+L.gap/2)
        end
        local badge=meta_badge(r)
        if badge and not r.selection_item and not r.form_field then
            local color=badge.color or {1,0.78,0.35}
            local badge_y=r.kind=="button" and y+vcen(16*L.cs,row_h) or y+7*L.cs
            plain(t(badge.text),x,badge_y,16*L.cs,color,"right",rw-14*L.cs-button_hint_w)
        end
        end
        end -- Visible content row or fixed header tool.
    end
    if L.geometry then
        if letterbox then love.graphics.setScissor(offX,offY,W,H) else love.graphics.setScissor() end
    end
    if L.scroll then
        if L.app then
            local track_x=L.x+L.w+4*L.cs
            love.graphics.setColor(0.18,0.18,0.20,0.92); love.graphics.rectangle("fill",track_x,L.band_top,9*L.cs,L.band)
            local thumb_h,thumb_y
            if L.geometry then
                thumb_h=math.max(46*L.cs,L.band*L.band/math.max(L.band,L.total_h))
                local travel=L.band-thumb_h; local max_scroll=math.max(0,L.total_h-L.band)
                thumb_y=L.band_top+(max_scroll>0 and travel*L.scroll_y/max_scroll or 0)
            else
                local visible=math.max(1,L.last-L.first+1)
                thumb_h=math.max(46*L.cs,L.band*visible/math.max(visible,L.n))
                local travel=L.band-thumb_h
                thumb_y=L.band_top+(L.n>visible and travel*(L.first-1)/(L.n-visible) or 0)
            end
            love.graphics.setColor(0.42,0.42,0.45,0.94); love.graphics.rectangle("fill",track_x+1*L.cs,thumb_y,7*L.cs,thumb_h,4,4)
        else
            if L.first>1 then plain("▲",0,L.band_top-2*L.cs,SUB_PX*L.cs,{1,1,1,0.7},"center",W) end
            if L.last<L.n then plain("▼",0,L.band_top+L.band-14*L.cs,SUB_PX*L.cs,{1,1,1,0.7},"center",W) end
        end
    end

    end -- Active compact content pane.
    local footer_top=nil
    if L.has_sidebar and (not L.compact or tools_visible()) then
        local side=sidebar(); local geometry=sidebar_geometry(L)
        if L.app and not L.compact then
            local page=pages[page_i]
            if not L.navigation then
                plain(t(page.sidebar_title or {en="Actions",zh="操作"}),L.side_x+10*L.cs,L.band_top,
                    22*L.cs,{0.68,0.64,0.74},"left",L.side_w-20*L.cs)
                love.graphics.setColor(ui_theme.divider); love.graphics.setLineWidth(1)
                love.graphics.line(L.side_x,L.band_top+37*L.cs,L.side_x+L.side_w,L.band_top+37*L.cs)
            end

            local footer_lines,footer_h=sidebar_footer_layout(L)
            if #footer_lines>0 then
                local footer_bottom=L.band_top+L.band
                for index,g in pairs(geometry) do
                    if type(index)=="number" and side[index].group=="bottom" then
                        footer_bottom=math.min(footer_bottom,g.y-L.gap)
                    end
                end
                footer_top=footer_bottom-footer_h
                love.graphics.setColor(1,1,1,0.20); love.graphics.setLineWidth(1)
                love.graphics.line(L.side_x,footer_top,L.side_x+L.side_w,footer_top)
                local line_y=footer_top+7*L.cs
                for index,line in ipairs(footer_lines) do
                    local color=index==1 and {0.86,0.82,0.91} or {1.0,0.78,0.36}
                    plain(line.text,L.side_x,line_y,line.px,color,"center",L.side_w)
                    line_y=line_y+line.h
                end
            end

            local detail=current_sidebar_detail and current_sidebar_detail() or nil
            if detail then
                local detail_top=L.band_top+48*L.cs
                local detail_bottom=L.band_top+L.band
                for index,g in pairs(geometry) do
                    if type(index)=="number" and side[index].group=="bottom" then
                        detail_bottom=math.min(detail_bottom,g.y-L.gap)
                    elseif type(index)=="number" then
                        detail_top=math.max(detail_top,g.y+g.h+L.gap)
                    end
                end
                if footer_top then detail_bottom=math.min(detail_bottom,footer_top-L.gap) end
                local detail_h=detail_bottom-detail_top
                if detail_h>=80*L.cs then
                    love.graphics.setColor(0.075,0.045,0.12,0.92)
                    love.graphics.rectangle("fill",L.side_x,detail_top,L.side_w,detail_h,8,8)
                    love.graphics.setColor(0.78,0.68,0.91,0.45); love.graphics.setLineWidth(1)
                    love.graphics.rectangle("line",L.side_x,detail_top,L.side_w,detail_h,8,8)

                    local pad=14*L.cs; local inner_w=L.side_w-pad*2
                    local title_px=21*L.cs; local title_font=body_fnt(title_px)
                    local title,title_lines=wrapped_text(detail.title or "",title_font,inner_w,2)
                    local title_h=title_lines*title_font:getHeight()
                    plain(title,L.side_x+pad,detail_top+pad,title_px,{1.0,0.78,0.36},"left",inner_w)

                    local body_y=detail_top+pad+title_h+12*L.cs
                    local body_px=20*L.cs; local body_font=body_fnt(body_px)
                    local max_lines=math.max(1,math.floor((detail_top+detail_h-pad-body_y)/body_font:getHeight()))
                    local body=wrapped_text(detail.body or "",body_font,inner_w,max_lines)
                    plain(body,L.side_x+pad,body_y,body_px,{0.92,0.90,0.96},"left",inner_w)
                end
            end
        end
        -- Scroll affordance: when the toolbar scrolls, an up chevron above the
        -- first button hints that more items hide above, and a down chevron
        -- below the last button hints at more below. They vanish at the ends.
        if L.compact and geometry.scroll and not L.navigation then
            local hint=state.ui_lang=="zh" and "↑↓ 更多" or "Up/Down: more"
            hint=hint..string.format("  %d–%d / %d",geometry.visible_first,geometry.visible_last,#side)
            plain(hint,L.side_x,geometry.scroll_bottom-body_fnt(16*L.cs):getHeight(),16*L.cs,
                {0.68,0.64,0.74},"center",L.side_w)
        elseif L.app and geometry.scroll then
            local bar=geometry.scroll_bar or 18*L.cs
            local cs=L.cs
            local bar_y=geometry.viewport_top-bar
            if geometry.scroll_first and geometry.scroll_first>1 then
                love.graphics.setColor(0.10,0.06,0.17,0.95)
                love.graphics.rectangle("fill",L.side_x,bar_y,L.side_w,bar,6,6)
                love.graphics.setColor(0.72,0.66,0.84,1)
                local cx=L.side_x+L.side_w/2
                love.graphics.polygon("fill",cx-6*cs,bar_y+bar*0.76,cx+6*cs,bar_y+bar*0.76,cx,bar_y+bar*0.24)
            end
            local first=geometry.scroll_first or 1
            local last=first+(geometry.per or 1)-1
            if last<(geometry.scroll_total or 0) then
                local bottom=geometry.scroll_bottom or (L.band_top+L.band)
                local last_y=geometry["scroll_last_y"] or (bottom-bar)
                love.graphics.setColor(0.10,0.06,0.17,0.95)
                love.graphics.rectangle("fill",L.side_x,last_y,L.side_w,bottom-last_y,6,6)
                love.graphics.setColor(0.72,0.66,0.84,1)
                local cx=L.side_x+L.side_w/2
                local cy=last_y+(bottom-last_y)/2
                love.graphics.polygon("fill",cx-6*cs,cy-bar*0.24,cx+6*cs,cy-bar*0.24,cx,cy+bar*0.24)
            end
        end

        for i,r in ipairs(side) do
            local g=geometry[i]
            -- Short screens scroll the toolbar: skip items pushed off the band.
            local nav_top=L.navigation and (L.compact and 72 or 124)*L.cs or L.band_top
            local visible=not (L.app and (g.y+g.h<nav_top or g.y>L.band_top+L.band))
            -- Toolbar items must also stop above the sidebar footer, even when
            -- the band is short (footer_top is nil when there is no footer).
            -- The pinned bottom group (e.g. Quit) sits *below* the footer and
            -- must never be filtered by this check.
            if visible and L.app and footer_top and side[i].group~="bottom"
                and g.y+g.h>footer_top-L.gap then visible=false end
            -- When the toolbar scrolls, items outside the scroll window must
            -- not paint over the title or the chevron bars (a partially
            -- visible stray item above the window used to cover the title).
            if visible and L.app and geometry.scroll and side[i].group~="bottom" then
                if g.y<geometry.viewport_top-0.01 or g.y+g.h>geometry.viewport_bottom+0.01 then visible=false end
            end
            if visible then
                panel(g.x,g.y,g.w,g.h,zone=="sidebar" and i==sidebar_i,disabled(r),L.app,r)
                if L.navigation then
                    local icon=r.icon or (r.id or ""):match("home:(.+)") or "quit"
                    local aliases={zip="install",junk="cleanup",pm="settings",tutorial="help",input="settings"}
                    if r.active then
                        love.graphics.setColor(ui_theme.focus_border)
                        love.graphics.rectangle("fill",g.x,g.y+8*L.cs,3*L.cs,g.h-16*L.cs,1,1)
                    end
                    local quit=r.group=="bottom"
                    if quit then
                        love.graphics.setColor(ui_theme.muted)
                        ui_icons.draw(aliases[icon] or icon,g.x+18*L.cs,g.y+(g.h-22*L.cs)/2,22*L.cs)
                    end
                    local badge_w=r.badge and 28*L.cs or 0
                    local label_x=g.x+(quit and 52 or 20)*L.cs
                    local label_w=g.w-(quit and 62 or 32)*L.cs-badge_w
                    local label=clip_ellipsis(tostring(t(r.label) or ""),body_fnt(22*L.cs),label_w)
                    plain(label,label_x,g.y+vcen(22*L.cs,g.h),22*L.cs,
                        disabled(r) and {0.45,0.44,0.49} or r.active and ui_theme.text or ui_theme.muted,"left",label_w)
                    if r.badge then plain(t(r.badge.text),g.x+g.w-badge_w,g.y+vcen(13*L.cs,g.h),
                        13*L.cs,r.badge.color,"center",badge_w) end
                elseif r.kind=="checkbox" then
                    local check_size=(L.app and 26 or 24)*L.cs
                    local check_x=g.x+14*L.cs; local check_y=g.y+(g.h-check_size)/2
                    draw_checkbox(check_x,check_y,check_size,r.checked,zone=="sidebar" and i==sidebar_i,disabled(r),r)
                    local color=disabled(r) and {0.55,0.55,0.57} or
                        (r.danger and r.checked and {1,0.58,0.58} or {1,1,1})
                    plain(t(r.label),g.x+50*L.cs,g.y+vcen((L.app and 19 or 18)*L.cs,g.h),
                        (L.app and 19 or 18)*L.cs,color,"left",g.w-62*L.cs)
                else
                    plain(t(r.label),g.x,g.y+vcen((L.app and 20 or 19)*L.cs,g.h),(L.app and 20 or 19)*L.cs,
                        disabled(r) and {0.55,0.55,0.57} or {1,1,1},"center",g.w)
                end
            end
        end
    end

    -- Credits bottom-left / QQ bottom-right
    if not L.app and port.credits then
        local cy = H - 16*L.cs - #port.credits*24*L.cs
        for i,c in ipairs(port.credits) do
            plain(t(c[1])..": "..c[2],16*L.cs,cy+(i-1)*24*L.cs,CRED_PX*L.cs,{1,1,1,0.9})
        end
    end
    if not L.app then plain(kit.CONTACT,0,H-32*L.cs,CRED_PX*L.cs,{1,1,1,0.9},"right",W-16*L.cs) end

    if L.app and not (guide_state or (dialog_state and not dialog_state.select_row) or busy or password_state) then
        local hint=app_input_hint()
        local px=16*L.cs
        plain(hint,L.x,H-body_fnt(px):getHeight()-7*L.cs,px,{0.68,0.64,0.74},"right",L.w)
    end

    if guide_state then draw_guide(L) end
    if dialog_state and dialog_state.over_busy~=true then draw_dialog(L) end
    if busy then draw_busy_overlay(L) end
    if dialog_state and dialog_state.over_busy==true then draw_dialog(L) end
    if password_state then draw_password_dialog(L) end

    -- Toasts report short-lived outcomes without changing page content or
    -- stealing controller focus. They slide up from the bottom, remain visible
    -- for the configured duration, then leave along the same edge.
    if toast_state then
        local enter_time,exit_time=0.22,0.22
        local remaining=toast_state.duration-toast_state.elapsed
        local visibility=1
        if toast_state.elapsed<enter_time then
            local p=math.max(0,math.min(1,toast_state.elapsed/enter_time))
            visibility=1-(1-p)^3
        elseif remaining<exit_time then
            local p=math.max(0,math.min(1,remaining/exit_time))
            visibility=p*p
        end
        local cs=L.cs
        local tw=math.min(W-36*cs,620*cs)
        local pad_x,pad_y=22*cs,15*cs
        local font=body_fnt(TOAST_PX*cs)
        local text,lines=wrapped_text(toast_state.message,font,tw-pad_x*2,2)
        local th=math.max(58*cs,lines*font:getHeight()+pad_y*2)
        local tx=(W-tw)/2
        local resting_y=H-th-22*cs
        local ty=resting_y+(1-visibility)*(th+32*cs)
        local accents={
            success={0.36,0.86,0.55},error={1.0,0.40,0.38},
            warning={1.0,0.76,0.30},info={0.72,0.56,1.0},
        }
        local accent=accents[toast_state.kind] or accents.info
        love.graphics.setColor(0.045,0.035,0.065,0.98*visibility)
        love.graphics.rectangle("fill",tx,ty,tw,th,10,10)
        love.graphics.setColor(accent[1],accent[2],accent[3],0.96*visibility)
        love.graphics.rectangle("fill",tx,ty,5*cs,th)
        love.graphics.setColor(accent[1],accent[2],accent[3],0.55*visibility)
        love.graphics.setLineWidth(1)
        love.graphics.rectangle("line",tx,ty,tw,th,10,10)
        plain(text,tx+pad_x,ty+(th-lines*font:getHeight())/2,TOAST_PX*cs,{1,1,1,visibility},"left",tw-pad_x*2)
    end

    if letterbox then
        love.graphics.setScissor(); love.graphics.pop()
        love.graphics.setColor(1,1,1,0.5); love.graphics.setLineWidth(1)
        love.graphics.rectangle("line",offX,offY,W,H)
        plain(W.."×"..H.." preview",offX+8,offY+4,14,{1,1,0.6})
    end
end


local function dialog_input(action)
    if dialog_state.select_row then
        local d=dialog_state
        local row=d.select_row
        if action=="up" or action=="down" then
            local direction=action=="up" and -1 or 1
            local index=d._select_index+direction
            while index>=1 and index<=#row.values do
                if not row.disabled_values or not row.disabled_values[row.values[index]] then d._select_index=index; break end
                index=index+direction
            end
        elseif action=="confirm" then
            local value=row.values[d._select_index]
            kit.close_dialog()
            if state[row.key]~=value then
                state[row.key]=value
                if row.on_change then row.on_change(value,row) end
            end
        elseif action=="cancel" then kit.close_dialog() end
        return true
    end
    if dialog_state.item_groups and (action=="up" or action=="down" or action=="page_up" or action=="page_down") then
        local d=dialog_state
        local delta=(action=="up" or action=="page_up") and -1 or 1
        local page=action=="page_up" or action=="page_down"
        local step=page and (d._group_viewport_h or 120)*0.8 or (d._group_scroll_step or 28)
        d._group_scroll=math.max(0,math.min(d._group_max_scroll or math.huge,d._group_scroll+delta*step))
    elseif dialog_state.checkbox and dialog_focus==3 and (action=="up" or action=="down") then
        dialog_focus=2
    elseif dialog_state.scroll_items and (action=="up" or action=="down") then
        local delta=action=="up" and -1 or 1
        local count=#(dialog_state.items or {})
        if action=="down" and dialog_state.checkbox and dialog_state._item_index>=count then
            dialog_focus=3
        else dialog_state._item_index=math.max(1,math.min(count,dialog_state._item_index+delta)) end
        text_scroll_elapsed=0
    elseif is_app() and dialog_state.single_action and
        (action=="left" or action=="right" or action=="up" or action=="down") then dialog_focus=1
    elseif action=="up" and dialog_state.checkbox then dialog_focus=3
    elseif action=="down" and dialog_focus==3 then dialog_focus=2
    elseif action=="left" and dialog_focus~=3 then dialog_focus=is_app() and 2 or 1
    elseif action=="right" and dialog_focus~=3 then dialog_focus=is_app() and 1 or 2
    elseif action=="up" then dialog_focus=1
    elseif action=="down" then dialog_focus=2
    elseif action=="confirm" and dialog_focus==3 then
        local d=dialog_state
        components.activate(d.checkbox,"checkbox",d._checkbox_checked,function(on)
            d._checkbox_checked=on
            if d.checkbox.on_change then d.checkbox.on_change(on,d.checkbox) end
        end)
    elseif action=="confirm" then
        local d,index=dialog_state,dialog_focus
        d._buttons=d._buttons or {{},{}}
        components.activate(d._buttons[index],"button",nil,function() finish_dialog(index==1) end)
    elseif action=="cancel" then finish_dialog(false)
    else return false end
    return true
end

local function password_input(action)
    local d=password_state
    if not d then return false end
    local focus=d.focus
    if action=="page_up" then d.mode=(d.mode+1)%#PASSWORD_PAGES+1
    elseif action=="page_down" then d.mode=d.mode%#PASSWORD_PAGES+1
    elseif action=="left" then
        if focus<=40 then d.focus=math.floor((focus-1)/10)*10+(focus-2)%10+1
        else d.focus=41+(focus-42)%4 end
    elseif action=="right" then
        if focus<=40 then d.focus=math.floor((focus-1)/10)*10+focus%10+1
        else d.focus=41+(focus-40)%4 end
    elseif action=="up" then
        if focus>40 then
            local columns={2,5,7,9}; d.focus=30+columns[focus-40]
        elseif focus>10 then d.focus=focus-10 end
    elseif action=="down" then
        if focus<=30 then d.focus=focus+10
        elseif focus<=40 then d.focus=41+math.min(3,math.floor(((focus-31)*4)/10)) end
    elseif action=="confirm" then
        if focus<=40 then
            if #d.value<d.max_length then d.value=d.value..password_key(PASSWORD_PAGES[d.mode],focus) end
        elseif focus==41 then d.mode=d.mode%#PASSWORD_PAGES+1
        elseif focus==42 then d.value=d.value:sub(1,math.max(0,#d.value-1))
        elseif focus==43 then d.value=""
        else
            local callback,value=d.on_confirm,d.value
            kit.close_password_dialog()
            callback(value)
        end
    elseif action=="cancel" then
        local callback=d.on_cancel
        kit.close_password_dialog()
        if callback then callback() end
    else return false end
    return true
end

local function activate_row(row)
    if not row or disabled(row) then return end
    if row.kind=="button" then
        components.activate(row,"button",nil,function() do_action(row.action) end)
    elseif row.kind=="checkbox" then
        components.activate(row,"checkbox",row.checked,function(on)
            row.checked=on
            if row.on_toggle then row.on_toggle(on,row.meta,row) end
        end)
    elseif row.kind=="switch" then
        components.activate(row,"switch",switch_current(row)==row.on_value,function(on) set_switch(row,on) end)
    elseif row.kind=="picker" and row.dropdown then
        local selected=1
        for i,value in ipairs(row.values) do if value==state[row.key] then selected=i; break end end
        kit.dialog({select_row=row,_select_index=selected,default_focus="confirm"})
    elseif row.kind=="textview" and row.expandable~=false then
        row.expanded=not row.expanded
        kit.invalidate_layout(pages[page_i])
    end
end

local function select_focused_navigation()
    if zone~="sidebar" or busy or dialog_state or guide_state or password_state then return end
    local page=pages[page_i]
    local row=sidebar()[sidebar_i]
    if not (page.navigation and row and row.select_on_focus and tostring(row.id):match("^nav:")) or row.active or disabled(row) then return end
    local id=row_identity(row)
    activate_row(row)
    -- The destination owns its content; the controller stays in navigation
    -- while browsing sections, including the compact menu.
    sidebar_i=find_focus_identity(sidebar(),id) or first_focusable(sidebar())
    zone="sidebar"
    pages[page_i].header_return="sidebar"
    normalize_focus()
end

function kit.input(action)
    text_scroll_elapsed=0
    normalize_focus()
    bar_i=math.max(1,math.min(bar_i,#bar_items()))
    local handled
    if password_state then
        handled=password_input(action)
    elseif dialog_state and dialog_state.over_busy==true then
        handled=dialog_input(action)
    elseif busy then
        if action=="confirm" and busy_info and type(busy_info.on_cancel)=="function" and
           not busy_info.cancel_disabled and not busy_info.cancel_requested then
            busy_info.cancel_requested=true
            busy_info.on_cancel()
            handled=true
        else
            -- Everything else is swallowed while a task runs. Exiting the app
            -- is a deliberate, separate action available only from the Home
            -- Quit entry; it must never be reachable from inside a task.
            handled=false
        end
    elseif guide_state then
        -- Confirm advances; Back revisits the previous step or leaves the tour.
        if action=="cancel" and (guide_state._index or 1)<=1 then
            local guide=guide_state
            kit.close_guide()
            if guide.on_skip then guide.on_skip(kit) end
        elseif action=="confirm" or action=="right" then advance_guide(1)
        elseif action=="cancel" or action=="left" then advance_guide(-1) end
        handled=true
    elseif dialog_state then
        handled=dialog_input(action)
    elseif action=="up" then move_v(-1); handled=true
    elseif action=="down" then move_v(1); handled=true
    elseif action=="page_up" then move_page(-1); handled=true
    elseif action=="page_down" then move_page(1); handled=true
    elseif action=="left" then move_h(-1); handled=true
    elseif action=="right" then move_h(1); handled=true
    elseif action=="confirm" then
        if zone=="bar" then
            local it=bar_items()[bar_i]
            if it=="back" then kit.back_page()
            elseif it=="header" then
                local action=pages[page_i].header_action
                if action and not disabled(action) then
                    if action.kind=="checkbox" or action.kind=="switch" then
                        components.activate(action,action.kind,action.checked==true,function(on)
                            action.checked=on
                            if action.on_toggle then action.on_toggle(on,action.meta,action) end
                        end)
                    else
                        activate_row(action)
                    end
                end
            elseif it=="tools" then
                zone=tools_visible() and "rows" or "sidebar"
                if zone=="sidebar" and pages[page_i].navigation then
                    for i,item in ipairs(sidebar()) do if item.active then sidebar_i=i; break end end
                end
                pages[page_i].header_return=zone
                normalize_focus()
            elseif it=="quit" then
                for _,row in ipairs(sidebar()) do if row.id=="nav:quit" then activate_row(row); break end end
            elseif it=="lang" then toggle_lang() end
        elseif zone=="sidebar" then
            local page=pages[page_i]
            local row=sidebar()[sidebar_i]
            if page.navigation and row and row.select_on_focus and tostring(row.id):match("^nav:") then
                zone="rows"; normalize_focus()
            else activate_row(row) end
        else
            activate_row(cur()[focus_i])
        end
        handled=true
    elseif action=="cancel" then
        if is_app() and pages[page_i].root then
            if zone~="sidebar" and #sidebar()>0 then
                for i,item in ipairs(sidebar()) do if item.active then sidebar_i=i; break end end
                zone="sidebar"
            elseif port.on_home_cancel then port.on_home_cancel(kit,state)
            else kit.quit() end
        elseif is_app() and tools_visible() and valid_focus(cur(),focus_i) then zone="rows"
        elseif page_i~=1 then kit.back_page()
        elseif port.on_home_cancel then port.on_home_cancel(kit,state)
        else kit.quit() end
        handled=true
    else
        handled=false
    end
    if handled then select_focused_navigation(); kit.mark_dirty() end
    return handled
end

function kit.keypressed(key)
    local action=input_map[key]
    if not action then return false end
    return kit.input(action)
end

return kit
