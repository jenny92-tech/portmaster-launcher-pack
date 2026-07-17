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
local BODY_TEXT_SCALE = 1.08       -- small handheld readability boost; titles keep their designed size
local MINCS, MAXCS = 0.72, 1.15   -- content scale bounds (readability floor / cap on big screens)
local ROW_MAX_W = 540             -- hard row-width cap (px, does not grow with cs): keeps wide screens narrow

local W, H, realW, realH, offX, offY, letterbox
local port, strings, state = nil, {}, {}
local fonts, bg_img = {}, nil
local pages, page_i = {}, 1
local zone, focus_i, sidebar_i, bar_i = "rows", 1, 1, 1
local scroll_top, scroll_y = 1, 0
local busy, busy_message = false, nil
local dialog_state, dialog_focus = nil, 2
local layout, sidebar_geometry
local input_map, focus_stack = {}, {}
local measurement_cache = setmetatable({}, {__mode="k"})
local layout_cache_stats = {hits=0,misses=0,invalidations=0}

local DEFAULT_INPUT_MAP = {
    up="up", down="down", left="left", right="right",
    ["return"]="confirm", kpenter="confirm", space="confirm", escape="cancel",
    -- These aliases let a future native gamepad adapter dispatch semantic
    -- actions without manufacturing keyboard names.
    confirm="confirm", cancel="cancel",
}

local function is_app() return port and port.theme and port.theme.kind=="app" end
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
local function valid_focus(items,index)
    local row=items and items[index]
    return row and row.focusable and not disabled(row)
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
local function fnt(px)
    px = math.max(9, math.floor(px + 0.5))
    if not fonts[px] then
        -- Normally GAMEDIR/font.ttf (the NotoSansSC the launcher staged). If staging
        -- failed entirely (provide_font gave up), fall back to LÖVE's built-in font:
        -- English still renders, so no black screen and no crash.
        if love.filesystem.getInfo("font.ttf") then
            fonts[px] = love.graphics.newFont("font.ttf", px)
        else
            fonts[px] = love.graphics.newFont(px)
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
local function wrapped_text(value,font,width,max_lines)
    local text=tostring(t(value) or ""); local _,lines=font:getWrap(text,math.max(1,width))
    if #lines==0 then lines={""} end
    local truncated=max_lines and #lines>max_lines
    local count=truncated and max_lines or #lines; local shown={}
    for i=1,count do shown[i]=lines[i] end
    if truncated then shown[count]=clip_ellipsis(shown[count].."…",font,width) end
    return table.concat(shown,"\n"),count,truncated
end
local function vcen(px, h) return (h - body_fnt(px):getHeight())/2 end
local function centred_text_y(px,y,h,optical_offset)
    return y+(h-body_fnt(px):getHeight())/2+(optical_offset or 0)
end

local function panel(x,y,w,h,focused,is_disabled,app)
    if is_disabled then
        love.graphics.setColor(0.20,0.20,0.21,0.92); love.graphics.rectangle("fill",x,y,w,h,7,7)
        love.graphics.setColor(1,1,1,0.16); love.graphics.setLineWidth(1)
        love.graphics.rectangle("line",x,y,w,h,7,7)
    elseif focused then
        love.graphics.setColor(app and 0.36 or 0.55,app and 0.20 or 0.32,app and 0.57 or 0.85,app and 0.96 or 0.55)
        love.graphics.rectangle("fill",x,y,w,h,8,8)
        love.graphics.setColor(1.0,0.85,1.0,1.0); love.graphics.setLineWidth(math.max(2,3))
        love.graphics.rectangle("line",x,y,w,h,8,8)
    else
        love.graphics.setColor(0.10,0.06,0.17,app and 0.96 or 0.72); love.graphics.rectangle("fill",x,y,w,h,8,8)
        love.graphics.setColor(1,1,1,0.22); love.graphics.setLineWidth(1)
        love.graphics.rectangle("line",x,y,w,h,8,8)
    end
end

local function draw_checkbox(x,y,size,checked,focused,is_disabled)
    local radius=math.max(4,size*0.18)
    if is_disabled then
        love.graphics.setColor(0.16,0.16,0.18,0.92)
        love.graphics.rectangle("fill",x,y,size,size,radius,radius)
        love.graphics.setColor(1,1,1,0.18)
        love.graphics.setLineWidth(math.max(1,size*0.055))
        love.graphics.rectangle("line",x,y,size,size,radius,radius)
        return
    end
    if checked then
        -- A light lavender fill stays distinct from both the dark row and the
        -- purple focused-row fill. The dark vector tick remains crisp without
        -- relying on a font containing checkbox glyphs.
        love.graphics.setColor(0.84,0.70,1.00,1)
        love.graphics.rectangle("fill",x,y,size,size,radius,radius)
        love.graphics.setColor(1,0.94,1,focused and 1 or 0.78)
        love.graphics.setLineWidth(math.max(1,size*0.055))
        love.graphics.rectangle("line",x,y,size,size,radius,radius)
        love.graphics.setColor(0.12,0.055,0.20,1)
        love.graphics.setLineWidth(math.max(2,size*0.105))
        love.graphics.line(x+size*0.23,y+size*0.52,x+size*0.43,y+size*0.71,x+size*0.78,y+size*0.30)
    else
        love.graphics.setColor(0.045,0.03,0.07,0.96)
        love.graphics.rectangle("fill",x,y,size,size,radius,radius)
        love.graphics.setColor(0.78,0.68,0.91,focused and 1 or 0.84)
        love.graphics.setLineWidth(math.max(2,size*0.065))
        love.graphics.rectangle("line",x,y,size,size,radius,radius)
    end
end

local function draw_select(x,y,w,h,value,focused,is_disabled,cs)
    local radius=math.max(5,8*cs)
    if is_disabled then
        love.graphics.setColor(0.16,0.16,0.18,0.92)
        love.graphics.rectangle("fill",x,y,w,h,radius,radius)
        love.graphics.setColor(1,1,1,0.18)
    else
        -- Match Checkbox's dark surface and lavender outline so form controls
        -- read as one family, even when the containing row is focused purple.
        love.graphics.setColor(0.045,0.03,0.07,0.96)
        love.graphics.rectangle("fill",x,y,w,h,radius,radius)
        love.graphics.setColor(0.78,0.68,0.91,focused and 1 or 0.84)
    end
    love.graphics.setLineWidth(math.max(1,2*cs))
    love.graphics.rectangle("line",x,y,w,h,radius,radius)

    local cy=y+h/2
    local arrow_dx,arrow_dy=6*cs,7*cs
    local left_x,right_x=x+18*cs,x+w-18*cs
    love.graphics.setColor(is_disabled and 0.45 or 0.84,is_disabled and 0.45 or 0.74,is_disabled and 0.47 or 1,
        is_disabled and 0.5 or 1)
    love.graphics.setLineWidth(math.max(2,2.4*cs))
    love.graphics.line(left_x+arrow_dx,cy-arrow_dy,left_x,cy,left_x+arrow_dx,cy+arrow_dy)
    love.graphics.line(right_x-arrow_dx,cy-arrow_dy,right_x,cy,right_x-arrow_dx,cy+arrow_dy)

    local font=body_fnt(19*cs)
    local text_x,text_w=x+32*cs,math.max(1,w-64*cs)
    value=clip_ellipsis(tostring(t(value) or ""),font,text_w)
    plain(value,text_x,y+(h-font:getHeight())/2,19*cs,
        is_disabled and {0.55,0.55,0.57} or {0.98,0.96,1},"center",text_w)
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
function kit.info(l,value,meta) return {kind="info",label=l,value=value,meta=meta,focusable=true} end
function kit.list_item(value,opts)
    return apply_options({kind="list_item",value=value,focusable=true,compact=true},opts)
end
function kit.textview(l,value,opts)
    local row={kind="textview",label=l,value=value,focusable=true,max_lines=2,expanded_lines=8,expandable=true}
    for key,option in pairs(opts or {}) do row[key]=option end
    return row
end
function kit.section(l) return {kind="section",label=l,focusable=false} end
function kit.badge(text_,color) return {text=text_,color=color} end
function kit.add_page(title,rows,opts)
    local page=opts or {}; page.title=title; page.rows=rows or {}; page.sidebar=page.sidebar or {}
    pages[#pages+1]=page; return #pages
end
function kit.invalidate_layout(page)
    if page then measurement_cache[page]=nil
    else measurement_cache=setmetatable({}, {__mode="k"}) end
    layout_cache_stats.invalidations=layout_cache_stats.invalidations+1
end
function kit.set_page(index,title,rows,opts)
    local old_page=pages[index]
    local old_row_id=old_page and zone=="rows" and row_identity(old_page.rows and old_page.rows[focus_i]) or nil
    local old_sidebar_id=old_page and zone=="sidebar" and row_identity(old_page.sidebar and old_page.sidebar[sidebar_i]) or nil
    if old_page then kit.invalidate_layout(old_page) end
    local page=opts or {}; page.title=title; page.rows=rows or {}; page.sidebar=page.sidebar or {}
    pages[index]=page
    if page_i==index then
        if page.preserve_focus then
            if zone=="rows" then focus_i=find_focus_identity(page.rows,old_row_id) or nearest_focus(page.rows,focus_i) end
            if zone=="sidebar" then sidebar_i=find_focus_identity(page.sidebar,old_sidebar_id) or nearest_focus(page.sidebar,sidebar_i) end
        else
            zone="rows"; focus_i=first_focusable(page.rows); sidebar_i=first_focusable(page.sidebar); bar_i=1; scroll_top=1; scroll_y=0
        end
    end
    return index
end
function kit.set_busy(value,message) busy=value and true or false; busy_message=message end
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
    dialog_focus=opts.default_focus=="confirm" and 1 or 2
    return true
end
function kit.close_dialog()
    if not dialog_state then return false end
    dialog_state=nil; dialog_focus=2
    local snapshot=table.remove(focus_stack)
    restore_focus(snapshot)
    return true
end
function kit.debug_dialog()
    return {open=dialog_state~=nil,focus=dialog_focus==1 and "confirm" or "cancel",
        item_count=dialog_state and #(dialog_state.items or {}) or 0,
        danger=dialog_state and dialog_state.danger==true or false,scope_depth=#focus_stack}
end
function kit.debug_focus()
    return {zone=zone,focus_i=focus_i,sidebar_i=sidebar_i,bar_i=bar_i,scroll_top=scroll_top,scroll_y=scroll_y}
end
function kit.debug_page()
    local rows=pages[page_i] and pages[page_i].rows or {}; local sections=0
    local section_labels,row_kinds={},{}
    for index,row in ipairs(rows) do
        row_kinds[index]=row.kind
        if row.kind=="section" then
            sections=sections+1
            section_labels[sections]=t(row.label)
        end
    end
    return {index=page_i,row_count=#rows,section_count=sections,
        section_labels=section_labels,row_kinds=row_kinds}
end
function kit.debug_layout_cache()
    return {hits=layout_cache_stats.hits,misses=layout_cache_stats.misses,
        invalidations=layout_cache_stats.invalidations}
end
function kit.get_state() return state end
function kit.translate(key) return t(key) end
local function cur() return pages[page_i].rows end
local function sidebar() return pages[page_i].sidebar or {} end
local function focusables(items)
    local o={}; for i,r in ipairs(items or {}) do if r.focusable and not disabled(r) then o[#o+1]=i end end; return o
end


-- ── Header focus items (secondary pages: back + lang; home: lang only) ──
local function bar_items()
    local b = {}
    if page_i ~= 1 then b[#b+1] = "back" end
    if page_i == 1 and pages[page_i].header_action then b[#b+1] = "header" end
    b[#b+1] = "lang"
    return b
end


-- ── Focus navigation ─────────────────────────────────────────────────
local function spatial_row(dx,dy)
    local page=pages[page_i]
    if not page or not page.row_layout or not layout then return nil end
    local L=layout(); local from=L.geometry and L.geometry[focus_i]
    if not from then return nil end
    local fx,fy=from.x+from.w/2,from.content_y+from.h/2
    local best,best_score
    for _,index in ipairs(focusables(cur())) do
        if index~=focus_i then
            local g=L.geometry[index]
            if g then
                local vx=(g.x+g.w/2)-fx; local vy=(g.content_y+g.h/2)-fy
                local overlaps_y=g.content_y<from.content_y+from.h and g.content_y+g.h>from.content_y
                local eligible=(dx>0 and vx>1 and overlaps_y) or (dx<0 and vx < -1 and overlaps_y)
                    or (dy>0 and vy>1) or (dy<0 and vy < -1)
                if eligible then
                    local primary=dx~=0 and math.abs(vx) or math.abs(vy)
                    local secondary=dx~=0 and math.abs(vy) or math.abs(vx)
                    local score=primary*10000+secondary
                    if not best_score or score<best_score then best,best_score=index,score end
                end
            end
        end
    end
    return best
end

local function spatial_sidebar(dx,dy)
    if not layout or not sidebar_geometry then return nil end
    local L=layout(); local geometry=sidebar_geometry(L); local from=geometry[sidebar_i]
    if not from then return nil end
    local fx,fy=from.x+from.w/2,from.y+from.h/2
    local best,best_score
    for _,index in ipairs(focusables(sidebar())) do
        if index~=sidebar_i then
            local g=geometry[index]
            if g then
                local vx=(g.x+g.w/2)-fx; local vy=(g.y+g.h/2)-fy
                local overlaps_y=g.y<from.y+from.h and g.y+g.h>from.y
                local eligible=(dx>0 and vx>1 and overlaps_y) or (dx<0 and vx < -1 and overlaps_y)
                    or (dy>0 and vy>1) or (dy<0 and vy < -1)
                if eligible then
                    local primary=dx~=0 and math.abs(vx) or math.abs(vy)
                    local secondary=dx~=0 and math.abs(vy) or math.abs(vx)
                    local score=primary*10000+secondary
                    if not best_score or score<best_score then best,best_score=index,score end
                end
            end
        end
    end
    return best
end

local function nearest_sidebar_for_row()
    if not layout or not sidebar_geometry then return nil end
    local L=layout(); local from=L.geometry and L.geometry[focus_i]
    if not from then
        if focus_i<L.first or focus_i>L.last then return nil end
        from={x=L.x,y=L.top+(focus_i-L.first)*(L.rh+L.gap),w=L.w,h=L.rh}
    end
    local geometry=sidebar_geometry(L); local fx,fy=from.x+from.w/2,from.y+from.h/2
    local best,best_score
    for _,index in ipairs(focusables(sidebar())) do
        local g=geometry[index]
        if g then
            local vx=(g.x+g.w/2)-fx; local vy=(g.y+g.h/2)-fy
            local score=math.abs(vy)*10000+math.abs(vx)
            if not best_score or score<best_score then best,best_score=index,score end
        end
    end
    return best
end

local function move_v(d)
    if zone == "bar" then
        if d > 0 then
            local rows=focusables(cur())
            if #rows>0 then zone="rows"; focus_i=rows[1]
            else local side=focusables(sidebar()); zone="sidebar"; sidebar_i=side[1] or 1 end
        end
        return
    end
    if zone=="sidebar" then
        local next_index=spatial_sidebar(0,d)
        if next_index then sidebar_i=next_index
        elseif d<0 then zone="bar"; bar_i=1 end
        return
    elseif zone=="rows" and pages[page_i].row_layout then
        local next_index=spatial_row(0,d)
        if next_index then focus_i=next_index
        elseif d<0 then zone="bar"; bar_i=1 end
        return
    end
    local items = cur()
    local fs = focusables(items); local current = focus_i; local pos=1
    for i,idx in ipairs(fs) do if idx==current then pos=i end end
    pos = pos + d
    if pos < 1 then zone="bar"; bar_i=1; return
    elseif pos > #fs then pos=#fs end
    focus_i=fs[pos]
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
    if zone == "bar" then
        local n = #bar_items()
        bar_i = math.max(1, math.min(n, bar_i + d))
    elseif zone == "sidebar" then
        local next_index=spatial_sidebar(d,0)
        if next_index then sidebar_i=next_index
        elseif d<0 and #focusables(cur())>0 then
            local fs=focusables(cur()); local nearest=fs[1]
            if pages[page_i].row_layout and layout and sidebar_geometry then
                local L=layout(); local sg=sidebar_geometry(L)[sidebar_i]
                if sg then
                    local tx,ty=sg.x,sg.y+sg.h/2; local best_score
                    for _,index in ipairs(fs) do
                        local g=L.geometry and L.geometry[index]
                        if g then
                            local dx_=(g.x+g.w/2)-tx; local dy_=(g.y+g.h/2)-ty
                            local score=dx_*dx_+dy_*dy_
                            if not best_score or score<best_score then nearest,best_score=index,score end
                        end
                    end
                end
            end
            zone="rows"; focus_i=nearest
        end
    else
        local r = cur()[focus_i]
        if r and r.kind=="switch" then
            set_switch(r,d>0)
        elseif r and r.kind=="picker" then
            local v=r.values; local idx=1
            for i,x in ipairs(v) do if x==state[r.key] then idx=i end end
            state[r.key]=v[((idx-1+d)%#v)+1]
        elseif pages[page_i].row_layout then
            local next_index=spatial_row(d,0)
            if next_index then focus_i=next_index
            elseif d>0 and #focusables(sidebar())>0 then
                zone="sidebar"; sidebar_i=nearest_sidebar_for_row() or focusables(sidebar())[1]
            end
        elseif d>0 and #focusables(sidebar())>0 then
            zone="sidebar"; sidebar_i=nearest_sidebar_for_row() or focusables(sidebar())[1]
        end
    end
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
        if port.write_env then port.write_env(f,state,kit) end
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
    page_i=n; zone="rows"; focus_i=focusables(cur())[1] or 1; sidebar_i=focusables(sidebar())[1] or 1; bar_i=1; scroll_top=1; scroll_y=0
end
function kit.goto_page(n) goto_page(n) end
local function toggle_lang()
    state.ui_lang=(state.ui_lang=="en") and "zh" or "en"
    kit.invalidate_layout()
    save_state()
end
function kit.quit() save_state(); love.event.quit(kit.EXIT_QUIT) end
local function do_action(a)
    if a=="start" then
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
    elseif type(a)=="string" and a:match("^page:") then goto_page(tonumber(a:match("%d+")))
    elseif type(a)=="function" then a(kit) end
end

local function finish_dialog(confirm)
    local current=dialog_state
    kit.close_dialog()
    if not current then return end
    local callback=confirm and current.on_confirm or current.on_cancel
    if callback then callback(kit) end
end


-- ── LÖVE callbacks ───────────────────────────────────────────────────
function kit.run(cfg)
    port=cfg; love.load=kit.load; love.draw=kit.draw; love.update=kit.update; love.keypressed=kit.keypressed
end
function kit.load()
    realW, realH = love.graphics.getDimensions()
    local fw,fh = tonumber(os.getenv("PAM_FORCE_W")), tonumber(os.getenv("PAM_FORCE_H"))
    if fw and fh then W,H=fw,fh; offX,offY=math.floor((realW-fw)/2),math.floor((realH-fh)/2); letterbox=true
    else W,H=realW,realH; offX,offY=0,0; letterbox=false end
    love.graphics.setBackgroundColor(0.02,0.02,0.03)
    dialog_state,dialog_focus=nil,2; focus_stack={}
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
end

function kit.update(dt)
    if port and port.update then port.update(dt,kit,state) end
end


-- Adaptive density: pick the largest content scale CS that still fits. Returns a layout table.
layout=function()
    local rows = cur(); local n = #rows; local count=math.max(1,n)
    if is_app() then
        local cs=math.max(0.72,math.min(1,H/720))
        local margin=18*cs
        local side_w=math.min(280*cs,W*0.27)
        local side_gap=37*cs
        local w=math.max(260*cs,W-margin*2-side_w-side_gap)
        local side_x=margin+w+side_gap
        local content_top=97*cs
        local bottom=20*cs
        local band=H-content_top-bottom
        local rh,gap=74*cs,9*cs
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
            local signature=table.concat({tostring(W),tostring(H),tostring(state.ui_lang or ""),mode,
                tostring(columns),tostring(n),tostring(cs),tostring(w),tostring(band),
                tostring(cell_w),tostring(gap)},"|")
            local cached=measurement_cache[page]
            local geometry,total_h
            if cached and cached.signature==signature then
                geometry,total_h=cached.geometry,cached.total_h
                layout_cache_stats.hits=layout_cache_stats.hits+1
            else
                geometry={}; local content_y=0; local i=1
                local function measured_height(row,width)
                    if row.kind=="section" then return 49*cs end
                    if row.kind=="list_item" then return (row.height or 50)*cs end
                    if row.kind~="textview" then return rh end
                    local pad=12*cs
                    local label_font,value_font=body_fnt(15*cs),body_fnt(17*cs); local inner_w=width-pad*2
                    local _,label_lines=wrapped_text(row.label,label_font,inner_w,2)
                    local label_h=label_lines*label_font:getHeight()
                    local requested=row.expanded and row.expanded_lines or row.max_lines
                    local max_fit=math.max(1,math.floor((band-pad*2-label_h-5*cs)/value_font:getHeight()))
                    local _,value_lines=wrapped_text(row.value,value_font,inner_w,math.min(requested,max_fit))
                    local value_h=value_lines*value_font:getHeight()
                    return math.max(rh,pad+label_h+5*cs+value_h+pad)
                end
                while i<=n do
                    if rows[i].kind=="section" then
                        local h=measured_height(rows[i],w)
                        geometry[i]={x=margin,content_y=content_y,w=w,h=h,column=1}
                        content_y=content_y+h+gap; i=i+1
                    else
                        local group={}
                        while i<=n and rows[i].kind~="section" and #group<columns do
                            group[#group+1]=i; i=i+1
                        end
                        local h=0
                        for _,index in ipairs(group) do h=math.max(h,measured_height(rows[index],cell_w)) end
                        for column,index in ipairs(group) do
                            geometry[index]={x=margin+(column-1)*(cell_w+gap),content_y=content_y,
                                w=cell_w,h=h,column=column}
                        end
                        content_y=content_y+h+gap
                    end
                end
                total_h=math.max(0,content_y-gap)
                measurement_cache[page]={signature=signature,geometry=geometry,total_h=total_h}
                layout_cache_stats.misses=layout_cache_stats.misses+1
            end
            local focused=zone=="rows" and geometry[focus_i] or nil
            if focused then
                if focused.content_y<scroll_y then scroll_y=focused.content_y
                elseif focused.content_y+focused.h>scroll_y+band then scroll_y=focused.content_y+focused.h-band end
            end
            scroll_y=math.max(0,math.min(scroll_y,math.max(0,total_h-band)))
            local first,last=n,1
            for index,g in pairs(geometry) do
                g.y=content_top+g.content_y-scroll_y
                if g.y+g.h>content_top and g.y<content_top+band then
                    first=math.min(first,index); last=math.max(last,index)
                end
            end
            if last<first then first,last=1,0 end
            return {app=true,dim=port.theme.background_dim or 0.94,cs=cs,x=margin,w=w,
                side_x=side_x,side_w=side_w,divider_x=side_x-13*cs,top=content_top,
                rh=rh,gap=gap,first=first,last=last,band=band,band_top=content_top,n=n,
                scroll=total_h>band,has_sidebar=true,geometry=geometry,total_h=total_h,
                scroll_y=scroll_y,row_layout_mode=mode,columns=columns}
        end
        local per=math.max(1,math.floor((band+gap)/(rh+gap)))
        if focus_i and focus_i<scroll_top then scroll_top=focus_i end
        if focus_i and focus_i>scroll_top+per-1 then scroll_top=focus_i-per+1 end
        scroll_top=math.max(1,math.min(scroll_top,math.max(1,n-per+1)))
        local first,last=scroll_top,math.min(n,scroll_top+per-1)
        return {app=true,dim=port.theme.background_dim or 0.94,cs=cs,x=margin,w=w,
            side_x=side_x,side_w=side_w,divider_x=side_x-13*cs,top=content_top,
            rh=rh,gap=gap,first=first,last=last,band=band,band_top=content_top,n=n,
            scroll=n>per,has_sidebar=true}
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
    local secondary = (page_i ~= 1)
    if L.app then
        local page=pages[page_i]
        local pad,bh=18*cs,72*cs
        local items=bar_items()
        local left=secondary and kit.button("back") or page.header_action
        if left then
            local bw,bh_button=145*cs,54*cs
            local focused=zone=="bar" and (items[bar_i]=="back" or items[bar_i]=="header")
            panel(pad,18*cs,bw,bh_button,focused,disabled(left),true)
            local label=secondary and t("back") or t(left.label)
            plain((secondary and "‹ " or "")..label,pad,18*cs+vcen(26*cs,bh_button),26*cs,
                disabled(left) and {0.58,0.58,0.60} or {1,1,1},"center",bw)
        end
        local lw,lh=90*cs,54*cs; local lx=W-lw-pad
        panel(lx,18*cs,lw,lh,zone=="bar" and items[bar_i]=="lang",false,true)
        plain(state.ui_lang=="en" and "中" or "EN",lx,18*cs+vcen(27*cs,lh),27*cs,{1,1,1},"center",lw)
        local title_x=pad+157*cs; local title_w=math.max(120*cs,W-title_x*2)
        local title=t(page.title); local title_px=40; local font=fnt(title_px*cs)
        while title_px>24 and font:getWidth(title)>title_w do
            title_px=title_px-2; font=fnt(title_px*cs)
        end
        title=clip_ellipsis(title,font,title_w)
        outlined(title,title_x,(bh-fnt(title_px*cs):getHeight())/2+4*cs,title_px*cs,{1,1,1},"center",title_w)
        love.graphics.setColor(1,1,1,0.46); love.graphics.setLineWidth(1)
        love.graphics.line(pad,89*cs,W-pad,89*cs)
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

sidebar_geometry=function(L)
    local side,geometry=sidebar(),{}
    local rh,gap=48*L.cs,8*L.cs
    if not L.app then
        local total=#side*rh+math.max(0,#side-1)*gap
        local y=L.band_top+math.max(0,(L.band-total)/2)
        for i=1,#side do geometry[i]={x=L.side_x,y=y+(i-1)*(rh+gap),w=L.side_w,h=rh} end
        return geometry
    end
    rh=50*L.cs
    local bottom_y=L.band_top+L.band
    for i=#side,1,-1 do
        if side[i].group=="bottom" then
            bottom_y=bottom_y-rh
            geometry[i]={x=L.side_x,y=bottom_y,w=L.side_w,h=rh}
            bottom_y=bottom_y-gap
        end
    end
    local y=L.band_top+45*L.cs; local i=1
    while i<=#side do
        local row=side[i]
        if row.group=="bottom" then i=i+1
        elseif row.half and side[i+1] and side[i+1].half and side[i+1].group~="bottom" then
            local half=(L.side_w-gap)/2
            geometry[i]={x=L.side_x,y=y,w=half,h=rh}
            geometry[i+1]={x=L.side_x+half+gap,y=y,w=half,h=rh}
            y=y+rh+gap; i=i+2
        else
            geometry[i]={x=L.side_x,y=y,w=L.side_w,h=rh}
            y=y+rh+gap; i=i+1
        end
    end
    return geometry
end

local function draw_dialog(L)
    local d=dialog_state
    if not d then return end
    local cs=math.max(0.72,math.min(1,H/720))
    local items=d.items or {}; local shown=math.min(4,#items)
    local message_h=d.message and 48*cs or 0
    local more_h=#items>shown and 24*cs or 0
    local dw=math.min(W-36*cs,640*cs)
    local dh=math.max(230*cs,112*cs+message_h+shown*32*cs+more_h+70*cs)
    dh=math.min(dh,H-44*cs)
    local dx,dy=(W-dw)/2,(H-dh)/2

    love.graphics.setColor(0,0,0,0.76); love.graphics.rectangle("fill",0,0,W,H)
    love.graphics.setColor(0.055,0.035,0.085,0.995); love.graphics.rectangle("fill",dx,dy,dw,dh,10,10)
    love.graphics.setColor(1,1,1,0.48); love.graphics.setLineWidth(1)
    love.graphics.rectangle("line",dx,dy,dw,dh,10,10)
    if d.danger then
        love.graphics.setColor(0.72,0.18,0.22,1); love.graphics.rectangle("fill",dx,dy,dw,5*cs,10,10)
    end

    local pad=26*cs; local content_y=dy+24*cs
    outlined(t(d.title or {en="Confirm action",zh="确认操作"}),dx+pad,content_y,28*cs,
        d.danger and {1,0.72,0.72} or {1,1,1},"left",dw-pad*2)
    content_y=content_y+43*cs
    if d.message then
        plain(t(d.message),dx+pad,content_y,18*cs,{0.82,0.82,0.88},"left",dw-pad*2)
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
    for i=1,shown do
        local label=clip_line("• "..t(items[i]),19*cs,dw-pad*2)
        plain(label,dx+pad,content_y+(i-1)*32*cs,19*cs,{0.94,0.94,0.97},"left",dw-pad*2)
    end
    content_y=content_y+shown*32*cs
    if #items>shown then
        local more=#items-shown
        local label=state.ui_lang=="zh" and string.format("另有 %d 项",more) or string.format("%d more items",more)
        plain(label,dx+pad,content_y,17*cs,{0.68,0.68,0.76},"left",dw-pad*2)
    end

    local gap=12*cs; local bw=(dw-pad*2-gap)/2; local bh=50*cs; local by=dy+dh-pad-bh
    local function draw_button(index,x,label,danger)
        local focused=dialog_focus==index
        if danger then
            love.graphics.setColor(focused and 0.66 or 0.42,0.10,0.14,0.98)
            love.graphics.rectangle("fill",x,by,bw,bh,8,8)
            love.graphics.setColor(focused and 1 or 0.85,focused and 0.78 or 0.35,focused and 0.80 or 0.40,1)
            love.graphics.setLineWidth(focused and 3 or 1); love.graphics.rectangle("line",x,by,bw,bh,8,8)
        else panel(x,by,bw,bh,focused,false,L.app) end
        plain(t(label),x,by+vcen(20*cs,bh),20*cs,{1,1,1},"center",bw)
    end
    draw_button(1,dx+pad,d.confirm or {en="Confirm",zh="确认"},d.danger)
    draw_button(2,dx+pad+bw+gap,d.cancel or {en="Cancel",zh="取消"},false)
end


function kit.draw()
    if letterbox then love.graphics.push(); love.graphics.translate(offX,offY); love.graphics.setScissor(offX,offY,W,H) end

    local L = layout()
    if bg_img then
        local iw,ih=bg_img:getDimensions(); local sc=math.max(W/iw,H/ih)
        love.graphics.setColor(1,1,1,1); love.graphics.draw(bg_img,(W-iw*sc)/2,(H-ih*sc)/2,0,sc,sc)
    end
    love.graphics.setColor(0,0,0,L.dim); love.graphics.rectangle("fill",0,0,W,H)

    draw_bar(L)
    if L.app then
        love.graphics.setColor(1,1,1,0.42); love.graphics.setLineWidth(1)
        love.graphics.line(L.divider_x,L.band_top,L.divider_x,L.band_top+L.band)
        love.graphics.line(18*L.cs,L.band_top+L.band,W-18*L.cs,L.band_top+L.band)
    end

    local function meta_badge(r)
        return r.badge or (r.meta and r.meta.badge) or nil
    end
    if L.geometry then love.graphics.setScissor(offX+L.x,offY+L.band_top,L.w,L.band) end
    local rows = cur(); local yi=0
    for i=L.first,L.last do
        local r=rows[i]; local g=L.geometry and L.geometry[i]
        local x=g and g.x or L.x; local y=g and g.y or (L.top+yi*(L.rh+L.gap)); yi=yi+1
        local rw=g and g.w or L.w; local row_h=g and g.h or L.rh
        local focused = (zone=="rows" and i==focus_i)
        local ty = y + vcen(ROW_PX*L.cs, row_h)
        if r.kind=="section" then
            plain(t(r.label),x+4*L.cs,ty,21*L.cs,{1.0,0.78,0.36},"left",rw-8*L.cs)
            love.graphics.setColor(1.0,0.78,0.36,0.42); love.graphics.setLineWidth(1)
            love.graphics.line(x,y+row_h-8*L.cs,x+rw,y+row_h-8*L.cs)
        else
            panel(x,y,rw,row_h,focused,disabled(r),L.app)
        if r.kind=="picker" then
            local select_w=math.min((L.app and 260 or 230)*L.cs,rw*0.48)
            local select_h=(L.app and 42 or 38)*L.cs
            local select_x=x+rw-select_w-16*L.cs
            local select_y=y+(row_h-select_h)/2
            local label_w=math.max(1,select_x-x-30*L.cs)
            local label=clip_ellipsis(tostring(t(r.label) or ""),body_fnt(ROW_PX*L.cs),label_w)
            plain(label,x+18*L.cs,ty,ROW_PX*L.cs,{1,1,1})
            local disp=r.labels and r.labels[state[r.key]]
            disp = disp and (strings[disp] and t(disp) or disp) or state[r.key]
            draw_select(select_x,select_y,select_w,select_h,disp,focused,disabled(r),L.cs)
        elseif r.kind=="checkbox" then
            local check_size=(L.app and 32 or 28)*L.cs
            local check_x=x+(L.app and 20 or 15)*L.cs
            local check_y=y+(row_h-check_size)/2
            draw_checkbox(check_x,check_y,check_size,r.checked,focused,disabled(r))
            local tx=x+(L.app and 70 or 56)*L.cs
            if r.detail then
                plain(t(r.label),tx,y+(L.app and 10 or 7)*L.cs,(L.app and 22 or 20)*L.cs,{1,1,1})
                plain(t(r.detail),tx,y+(L.app and 39 or 31)*L.cs,(L.app and 18 or 14)*L.cs,{0.78,0.78,0.84})
            else
                plain(t(r.label),tx,ty,ROW_PX*L.cs,{1,1,1})
            end
        elseif r.kind=="switch" then
            local raw=switch_current(r)
            local on=raw==r.on_value
            local track_w,track_h=68*L.cs,30*L.cs
            local track_x=x+rw-track_w-18*L.cs
            local track_y=y+(row_h-track_h)/2
            local optical_y=0
            local label_px=ROW_PX*L.cs
            local label_y=centred_text_y(label_px,y,row_h,optical_y)
            plain(t(r.label),x+18*L.cs,label_y,label_px,{1,1,1})
            love.graphics.setColor(on and 0.48 or 0.24,on and 0.25 or 0.24,on and 0.72 or 0.28,1)
            love.graphics.rectangle("fill",track_x,track_y,track_w,track_h,track_h/2,track_h/2)
            local knob=24*L.cs
            local knob_x=on and track_x+track_w-knob-3*L.cs or track_x+3*L.cs
            love.graphics.setColor(0.98,0.98,1,1)
            love.graphics.rectangle("fill",knob_x,track_y+3*L.cs,knob,knob,knob/2,knob/2)
        elseif r.kind=="info" then
            plain(t(r.label),x+16*L.cs,y+6*L.cs,16*L.cs,{0.72,0.72,0.82})
            plain(t(r.value),x+16*L.cs,y+27*L.cs,18*L.cs,{1,1,1},"left",rw-32*L.cs)
        elseif r.kind=="list_item" then
            local px=18*L.cs; local inner_w=math.max(1,rw-32*L.cs); local font=body_fnt(px)
            local value=clip_ellipsis(tostring(t(r.value) or ""),font,inner_w)
            plain(value,x+16*L.cs,centred_text_y(px,y,row_h,0.5*L.cs),px,
                disabled(r) and {0.55,0.55,0.57} or {0.96,0.94,1},"left",inner_w)
        elseif r.kind=="textview" then
            local pad=12*L.cs; local label_font,value_font=body_fnt(15*L.cs),body_fnt(17*L.cs); local inner_w=rw-pad*2
            local label,label_lines=wrapped_text(r.label,label_font,inner_w,2)
            local label_h=label_lines*label_font:getHeight()
            local requested=r.expanded and r.expanded_lines or r.max_lines
            local max_fit=math.max(1,math.floor((row_h-pad*2-label_h-5*L.cs)/value_font:getHeight()))
            local value=wrapped_text(r.value,value_font,inner_w,math.min(requested,max_fit))
            plain(label,x+pad,y+pad,15*L.cs,{0.72,0.72,0.82},"left",inner_w)
            plain(value,x+pad,y+pad+label_h+5*L.cs,17*L.cs,{1,1,1},"left",inner_w)
        else
            plain(t(r.label),x,ty,ROW_PX*L.cs,{1,1,1},"center",rw)
        end
        local badge=meta_badge(r)
        if badge then
            local color=badge.color or {1,0.78,0.35}
            plain(t(badge.text),x,y+7*L.cs,14*L.cs,color,"right",rw-14*L.cs)
        end
        end
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

    if L.has_sidebar then
        local side=sidebar(); local geometry=sidebar_geometry(L)
        if L.app then
            outlined(t(pages[page_i].sidebar_title or {en="Quick Tools",zh="快捷工具"}),L.side_x,L.band_top,
                28*L.cs,{1,1,1},"center",L.side_w)
            love.graphics.setColor(1,1,1,0.42); love.graphics.setLineWidth(1)
            love.graphics.line(L.side_x,L.band_top+37*L.cs,L.side_x+L.side_w,L.band_top+37*L.cs)
        end
        for i,r in ipairs(side) do
            local g=geometry[i]
            panel(g.x,g.y,g.w,g.h,zone=="sidebar" and i==sidebar_i,disabled(r),L.app)
            plain(t(r.label),g.x,g.y+vcen((L.app and 20 or 19)*L.cs,g.h),(L.app and 20 or 19)*L.cs,
                disabled(r) and {0.55,0.55,0.57} or {1,1,1},"center",g.w)
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

    if dialog_state then draw_dialog(L) end

    if busy then
        love.graphics.setColor(0,0,0,0.72); love.graphics.rectangle("fill",0,0,W,H)
        local bw,bh=math.min(W*0.72,520),110*L.cs; local bx,by=(W-math.min(W*0.72,520))/2,(H-bh)/2
        panel(bx,by,bw,bh,true,false,L.app)
        plain(t(busy_message or "working"),bx,by+vcen(22*L.cs,bh),22*L.cs,{1,1,1},"center",bw)
    end

    if letterbox then
        love.graphics.setScissor(); love.graphics.pop()
        love.graphics.setColor(1,1,1,0.5); love.graphics.setLineWidth(1)
        love.graphics.rectangle("line",offX,offY,W,H)
        plain(W.."×"..H.." preview",offX+8,offY+4,14,{1,1,0.6})
    end
end


function kit.input(action)
    if busy then return false end
    if dialog_state then
        if action=="left" or action=="up" then dialog_focus=1
        elseif action=="right" or action=="down" then dialog_focus=2
        elseif action=="confirm" then finish_dialog(dialog_focus==1)
        elseif action=="cancel" then finish_dialog(false)
        else return false end
        return true
    end
    if action=="up" then move_v(-1)
    elseif action=="down" then move_v(1)
    elseif action=="left" then move_h(-1)
    elseif action=="right" then move_h(1)
    elseif action=="confirm" then
        if zone=="bar" then
            local it=bar_items()[bar_i]
            if it=="back" then goto_page(1)
            elseif it=="header" then
                local action=pages[page_i].header_action
                if action and not disabled(action) then do_action(action.action) end
            elseif it=="lang" then toggle_lang() end
        elseif zone=="sidebar" then
            local r=sidebar()[sidebar_i]; if r and r.kind=="button" and not disabled(r) then do_action(r.action) end
        else
            local r=cur()[focus_i]
            if r and r.kind=="button" and not disabled(r) then do_action(r.action)
            elseif r and r.kind=="checkbox" and not disabled(r) then
                r.checked=not r.checked
                if r.on_toggle then r.on_toggle(r.checked,r.meta,r) end
            elseif r and r.kind=="switch" and not disabled(r) then
                set_switch(r,switch_current(r)~=r.on_value)
            elseif r and r.kind=="textview" and r.expandable~=false and not disabled(r) then
                r.expanded=not r.expanded
                kit.invalidate_layout(pages[page_i])
            end
        end
    elseif action=="cancel" then
        if page_i~=1 then goto_page(1)
        elseif port.on_home_cancel then port.on_home_cancel(kit,state)
        else kit.quit() end
    else return false end
    return true
end

function kit.keypressed(key)
    local action=input_map[key]
    if not action then return false end
    return kit.input(action)
end

return kit
