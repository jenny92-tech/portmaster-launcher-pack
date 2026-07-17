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
}

-- Design sizes (720p baseline, multiplied by the content scale CS).
local BAR_H, SUB_PX          = 58, 18
local ROW_MAX, ROW_MIN, GAP  = 58, 48, 9
local TITLE_PX, ROW_PX, CRED_PX, BTN_PX = 28, 24, 18, 23
local MINCS, MAXCS = 0.72, 1.15   -- content scale bounds (readability floor / cap on big screens)
local ROW_MAX_W = 540             -- hard row-width cap (px, does not grow with cs): keeps wide screens narrow

local W, H, realW, realH, offX, offY, letterbox
local port, strings, state = nil, {}, {}
local fonts, bg_img = {}, nil
local pages, page_i = {}, 1
local zone, focus_i, sidebar_i, bar_i = "rows", 1, 1, 1
local scroll_top = 1
local busy, busy_message = false, nil
local dialog_state, dialog_focus = nil, 2

local function is_app() return port and port.theme and port.theme.kind=="app" end
local function disabled(row)
    if not row then return false end
    return type(row.disabled)=="function" and row.disabled() or row.disabled==true
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
local function outlined(txt, x, y, px, col, align, limit)
    local f = fnt(px); love.graphics.setFont(f)
    local shadow=is_app() and {{-1,0},{1,0},{0,-1},{0,1}} or {{-2,0},{2,0},{0,-2},{0,2},{-2,-2},{2,2},{-2,2},{2,-2}}
    love.graphics.setColor(0,0,0,is_app() and 0.68 or 0.9)
    for _,d in ipairs(shadow) do
        if align then love.graphics.printf(txt, x+d[1], y+d[2], limit, align)
        else love.graphics.print(txt, x+d[1], y+d[2]) end
    end
    love.graphics.setColor(col[1],col[2],col[3],col[4] or 1)
    if align then love.graphics.printf(txt, x, y, limit, align)
    else love.graphics.print(txt, x, y) end
end
local function vcen(px, h) return (h - fnt(px):getHeight())/2 end

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


-- ── Row factories ────────────────────────────────────────────────────
function kit.picker(l,vals,labels,key) return {kind="picker",label=l,values=vals,labels=labels,key=key,focusable=true} end
function kit.button(l,action,opts)
    local row={kind="button",label=l,action=action,focusable=true}
    for key,value in pairs(opts or {}) do row[key]=value end
    return row
end
function kit.checkbox(l,detail,checked,on_toggle,meta)
    return {kind="checkbox",label=l,detail=detail,checked=checked and true or false,
            on_toggle=on_toggle,meta=meta,focusable=true}
end
function kit.info(l,value,meta) return {kind="info",label=l,value=value,meta=meta,focusable=true} end
function kit.section(l) return {kind="section",label=l,focusable=false} end
function kit.badge(text_,color) return {text=text_,color=color} end
function kit.add_page(title,rows,opts)
    local page=opts or {}; page.title=title; page.rows=rows or {}; page.sidebar=page.sidebar or {}
    pages[#pages+1]=page; return #pages
end
function kit.set_page(index,title,rows,opts)
    local page=opts or {}; page.title=title; page.rows=rows or {}; page.sidebar=page.sidebar or {}
    pages[index]=page
    if page_i==index then
        local function first(items)
            for i,r in ipairs(items or {}) do if r.focusable and not disabled(r) then return i end end
            return 1
        end
        local function valid(items,index_)
            local row=items and items[index_]
            return row and row.focusable and not disabled(row)
        end
        if page.preserve_focus then
            if zone=="rows" and not valid(page.rows,focus_i) then focus_i=first(page.rows) end
            if zone=="sidebar" and not valid(page.sidebar,sidebar_i) then sidebar_i=first(page.sidebar) end
        else
            zone="rows"; focus_i=first(page.rows); sidebar_i=first(page.sidebar); bar_i=1; scroll_top=1
        end
    end
    return index
end
function kit.set_busy(value,message) busy=value and true or false; busy_message=message end
function kit.dialog(opts)
    if type(opts)~="table" then return false end
    dialog_state=opts
    dialog_focus=opts.default_focus=="confirm" and 1 or 2
    return true
end
function kit.close_dialog() dialog_state=nil; dialog_focus=2 end
function kit.debug_dialog()
    return {open=dialog_state~=nil,focus=dialog_focus==1 and "confirm" or "cancel",
        item_count=dialog_state and #(dialog_state.items or {}) or 0,
        danger=dialog_state and dialog_state.danger==true or false}
end
function kit.debug_focus()
    return {zone=zone,focus_i=focus_i,sidebar_i=sidebar_i,bar_i=bar_i,scroll_top=scroll_top}
end
function kit.debug_page()
    local rows=pages[page_i] and pages[page_i].rows or {}; local sections=0
    for _,row in ipairs(rows) do if row.kind=="section" then sections=sections+1 end end
    return {index=page_i,row_count=#rows,section_count=sections}
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
local function move_v(d)
    if zone == "bar" then
        if d > 0 then
            local rows=focusables(cur())
            if #rows>0 then zone="rows"; focus_i=rows[1]
            else local side=focusables(sidebar()); zone="sidebar"; sidebar_i=side[1] or 1 end
        end
        return
    end
    local items = zone=="sidebar" and sidebar() or cur()
    local fs = focusables(items); local current = zone=="sidebar" and sidebar_i or focus_i; local pos=1
    for i,idx in ipairs(fs) do if idx==current then pos=i end end
    pos = pos + d
    if pos < 1 then zone="bar"; bar_i=1; return
    elseif pos > #fs then pos=#fs end
    if zone=="sidebar" then sidebar_i=fs[pos] else focus_i=fs[pos] end
end
local function move_h(d)
    if zone == "bar" then
        local n = #bar_items()
        bar_i = math.max(1, math.min(n, bar_i + d))
    elseif zone == "sidebar" then
        local side=sidebar(); local row=side[sidebar_i]
        if row and row.half and d>0 and side[sidebar_i+1] and side[sidebar_i+1].half then
            sidebar_i=sidebar_i+1
        elseif row and row.half and d<0 and side[sidebar_i-1] and side[sidebar_i-1].half then
            sidebar_i=sidebar_i-1
        elseif d<0 and #focusables(cur())>0 then
            zone="rows"; focus_i=focusables(cur())[1]
        end
    else
        local r = cur()[focus_i]
        if r and r.kind=="picker" then
            local v=r.values; local idx=1
            for i,x in ipairs(v) do if x==state[r.key] then idx=i end end
            state[r.key]=v[((idx-1+d)%#v)+1]
        elseif d>0 and #focusables(sidebar())>0 then
            zone="sidebar"; sidebar_i=focusables(sidebar())[1]
        end
    end
end


-- ── State save / env ─────────────────────────────────────────────────
local function spath() return love.filesystem.getSource().."/state.txt" end
local function save_state()
    local f=io.open(spath(),"w"); if not f then return end
    for k,v in pairs(state) do f:write(k.."="..tostring(v).."\n") end; f:close()
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
    local f=io.open(spath(),"r")
    if f then
        for line in f:lines() do local k,v=line:match("^([%w_]+)=(.*)$"); if k and state[k]~=nil then state[k]=v end end
        f:close(); return
    end
    if import_legacy_state() then save_state() end
end
local function write_env()
    local f=io.open(love.filesystem.getSource().."/launch_config.env","w"); if not f then return end
    f:write("# generated by love launcher\n"); if port.write_env then port.write_env(f,state,kit) end; f:close()
end
function kit.resolution_wh(key)
    local r=state[key or "resolution"]
    if not r or r=="auto" then return "auto","auto" end
    local w,h=r:match("^(%d+)x(%d+)$"); return w or "auto", h or "auto"
end


-- ── Actions ──────────────────────────────────────────────────────────
local function goto_page(n)
    if not pages[n] then return end
    page_i=n; zone="rows"; focus_i=focusables(cur())[1] or 1; sidebar_i=focusables(sidebar())[1] or 1; bar_i=1; scroll_top=1
end
function kit.goto_page(n) goto_page(n) end
local function toggle_lang() state.ui_lang=(state.ui_lang=="en") and "zh" or "en"; save_state() end
function kit.quit() save_state(); love.event.quit(kit.EXIT_QUIT) end
local function do_action(a)
    if a=="start" then
        state.launch_count=(tonumber(state.launch_count) or 0)+1
        save_state(); write_env(); love.event.quit(kit.EXIT_START)
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
    dialog_state,dialog_focus=nil,2
    strings={}; for k,v in pairs(kit.BASE_STRINGS) do strings[k]=v end
    for k,v in pairs(port.strings or {}) do strings[k]=v end
    load_state()
    if love.filesystem.getInfo("launcher_bg.png") then bg_img=love.graphics.newImage("launcher_bg.png") end
    pages={}; port.build_pages(kit,state); goto_page(1)
    if port.on_load then port.on_load(kit,state) end
end

function kit.update(dt)
    if port and port.update then port.update(dt,kit,state) end
end


-- Adaptive density: pick the largest content scale CS that still fits. Returns a layout table.
local function layout()
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
            outlined((secondary and "‹ " or "")..label,pad,18*cs+vcen(26*cs,bh_button),26*cs,
                disabled(left) and {0.58,0.58,0.60} or {1,1,1},"center",bw)
        end
        local lw,lh=90*cs,54*cs; local lx=W-lw-pad
        panel(lx,18*cs,lw,lh,zone=="bar" and items[bar_i]=="lang",false,true)
        outlined(state.ui_lang=="en" and "中" or "EN",lx,18*cs+vcen(27*cs,lh),27*cs,{1,1,1},"center",lw)
        local title=t(page.title); local title_px=#title>28 and 26 or (#title>18 and 32 or 40)
        local title_x=pad+157*cs; local title_w=math.max(120*cs,W-title_x*2)
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
        outlined("‹ "..t("back"), pad, (bh-44*cs)/2+vcen(BTN_PX*cs,44*cs), BTN_PX*cs, {1,1,1}, "center", bw)
    end
    -- Language: always top-right (back sits left on secondary pages, language right)
    local lw = 84*cs
    local lx = W - lw - pad
    local lfocused = (zone=="bar" and items[bar_i]=="lang")
    panel(lx, (bh-44*cs)/2, lw, 44*cs, lfocused)
    outlined(state.ui_lang=="en" and "中" or "EN", lx, (bh-44*cs)/2+vcen(BTN_PX*cs,44*cs), BTN_PX*cs, {1,1,1}, "center", lw)
    -- Centred title
    outlined(t(pages[page_i].title), 0, (bh-fnt(TITLE_PX*cs):getHeight())/2, TITLE_PX*cs, {1,1,1}, "center", W)
    -- Detected resolution (small type)
    outlined(string.format(t("detected"), realW, realH), 0, bh+2*cs, SUB_PX*cs, {1,1,1,0.7}, "center", W)
end

local function sidebar_geometry(L)
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
        outlined(t(d.message),dx+pad,content_y,18*cs,{0.82,0.82,0.88},"left",dw-pad*2)
        content_y=content_y+message_h
    end
    local function clip_line(value,px,max_w)
        value=t(value); local font=fnt(px)
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
        outlined(label,dx+pad,content_y+(i-1)*32*cs,19*cs,{0.94,0.94,0.97},"left",dw-pad*2)
    end
    content_y=content_y+shown*32*cs
    if #items>shown then
        local more=#items-shown
        local label=state.ui_lang=="zh" and string.format("另有 %d 项",more) or string.format("%d more items",more)
        outlined(label,dx+pad,content_y,17*cs,{0.68,0.68,0.76},"left",dw-pad*2)
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
        outlined(t(label),x,by+vcen(20*cs,bh),20*cs,{1,1,1},"center",bw)
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
        return r.meta and r.meta.badge or nil
    end
    local rows = cur(); local yi=0
    for i=L.first,L.last do
        local r=rows[i]; local y=L.top+yi*(L.rh+L.gap); yi=yi+1
        local focused = (zone=="rows" and i==focus_i)
        local ty = y + vcen(ROW_PX*L.cs, L.rh)
        if r.kind=="section" then
            outlined(t(r.label),L.x+4*L.cs,ty,21*L.cs,{1.0,0.78,0.36},"left",L.w-8*L.cs)
            love.graphics.setColor(1.0,0.78,0.36,0.42); love.graphics.setLineWidth(1)
            love.graphics.line(L.x,y+L.rh-8*L.cs,L.x+L.w,y+L.rh-8*L.cs)
        else
            panel(L.x,y,L.w,L.rh,focused,disabled(r),L.app)
        if r.kind=="picker" then
            outlined(t(r.label), L.x+18*L.cs, ty, ROW_PX*L.cs, {1,1,1})
            local disp=r.labels[state[r.key]]
            disp = disp and (strings[disp] and t(disp) or disp) or state[r.key]
            outlined("< "..tostring(disp).." >", L.x, ty, ROW_PX*L.cs, {1,1,1}, "right", L.w-18*L.cs)
        elseif r.kind=="checkbox" then
            local check_px=L.app and 31 or ROW_PX
            outlined(r.checked and "✓" or "□", L.x+(L.app and 20 or 14)*L.cs, y+vcen(check_px*L.cs,L.rh), check_px*L.cs,
                r.checked and {0.75,1,0.75} or {0.8,0.8,0.85})
            local tx=L.x+(L.app and 70 or 48)*L.cs
            if r.detail then
                outlined(t(r.label),tx,y+(L.app and 10 or 7)*L.cs,(L.app and 22 or 20)*L.cs,{1,1,1})
                outlined(t(r.detail),tx,y+(L.app and 39 or 31)*L.cs,(L.app and 18 or 14)*L.cs,{0.78,0.78,0.84})
            else
                outlined(t(r.label),tx,ty,ROW_PX*L.cs,{1,1,1})
            end
        elseif r.kind=="info" then
            outlined(t(r.label),L.x+16*L.cs,y+6*L.cs,16*L.cs,{0.72,0.72,0.82})
            outlined(t(r.value),L.x+16*L.cs,y+27*L.cs,18*L.cs,{1,1,1},"left",L.w-32*L.cs)
        else
            outlined(t(r.label), L.x, ty, ROW_PX*L.cs, {1,1,1}, "center", L.w)
        end
        local badge=meta_badge(r)
        if badge then
            local color=badge.color or {1,0.78,0.35}
            outlined(t(badge.text),L.x,L.y or (y+7*L.cs),14*L.cs,color,"right",L.w-14*L.cs)
        end
        end
    end
    if L.scroll then
        if L.app then
            local track_x=L.x+L.w+4*L.cs
            love.graphics.setColor(0.18,0.18,0.20,0.92); love.graphics.rectangle("fill",track_x,L.band_top,9*L.cs,L.band)
            local visible=math.max(1,L.last-L.first+1)
            local thumb_h=math.max(46*L.cs,L.band*visible/math.max(visible,L.n))
            local travel=L.band-thumb_h
            local thumb_y=L.band_top+(L.n>visible and travel*(L.first-1)/(L.n-visible) or 0)
            love.graphics.setColor(0.42,0.42,0.45,0.94); love.graphics.rectangle("fill",track_x+1*L.cs,thumb_y,7*L.cs,thumb_h,4,4)
        else
            if L.first>1 then outlined("▲",0,L.band_top-2*L.cs,SUB_PX*L.cs,{1,1,1,0.7},"center",W) end
            if L.last<L.n then outlined("▼",0,L.band_top+L.band-14*L.cs,SUB_PX*L.cs,{1,1,1,0.7},"center",W) end
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
            outlined(t(r.label),g.x,g.y+vcen((L.app and 20 or 19)*L.cs,g.h),(L.app and 20 or 19)*L.cs,
                disabled(r) and {0.55,0.55,0.57} or {1,1,1},"center",g.w)
        end
    end

    -- Credits bottom-left / QQ bottom-right
    if not L.app and port.credits then
        local cy = H - 16*L.cs - #port.credits*24*L.cs
        for i,c in ipairs(port.credits) do
            outlined(t(c[1])..": "..c[2], 16*L.cs, cy+(i-1)*24*L.cs, CRED_PX*L.cs, {1,1,1,0.9})
        end
    end
    if not L.app then outlined(kit.CONTACT, 0, H-32*L.cs, CRED_PX*L.cs, {1,1,1,0.9}, "right", W-16*L.cs) end

    if dialog_state then draw_dialog(L) end

    if busy then
        love.graphics.setColor(0,0,0,0.72); love.graphics.rectangle("fill",0,0,W,H)
        local bw,bh=math.min(W*0.72,520),110*L.cs; local bx,by=(W-math.min(W*0.72,520))/2,(H-bh)/2
        panel(bx,by,bw,bh,true,false,L.app)
        outlined(t(busy_message or "working"),bx,by+vcen(22*L.cs,bh),22*L.cs,{1,1,1},"center",bw)
    end

    if letterbox then
        love.graphics.setScissor(); love.graphics.pop()
        love.graphics.setColor(1,1,1,0.5); love.graphics.setLineWidth(1)
        love.graphics.rectangle("line",offX,offY,W,H)
        outlined(W.."×"..H.." preview", offX+8, offY+4, 14, {1,1,0.6})
    end
end


function kit.keypressed(key)
    if busy then return end
    if dialog_state then
        if key=="left" or key=="up" then dialog_focus=1
        elseif key=="right" or key=="down" then dialog_focus=2
        elseif key=="return" or key=="kpenter" then finish_dialog(dialog_focus==1)
        elseif key=="escape" then finish_dialog(false) end
        return
    end
    if key=="up" then move_v(-1)
    elseif key=="down" then move_v(1)
    elseif key=="left" then move_h(-1)
    elseif key=="right" then move_h(1)
    elseif key=="return" or key=="kpenter" then
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
            end
        end
    elseif key=="escape" then
        if page_i~=1 then goto_page(1)
        elseif port.on_home_cancel then port.on_home_cancel(kit,state)
        else kit.quit() end
    end
end

return kit
