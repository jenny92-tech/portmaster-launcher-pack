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
local ROW_MAX, ROW_MIN, GAP  = 58, 40, 9
local TITLE_PX, ROW_PX, CRED_PX, BTN_PX = 28, 24, 18, 23
local MINCS, MAXCS = 0.72, 1.15   -- content scale bounds (readability floor / cap on big screens)
local ROW_MAX_W = 540             -- hard row-width cap (px, does not grow with cs): keeps wide screens narrow

local W, H, realW, realH, offX, offY, letterbox
local port, strings, state = nil, {}, {}
local fonts, bg_img = {}, nil
local pages, page_i = {}, 1
local zone, focus_i, bar_i = "rows", 1, 1   -- zone: "rows"|"bar"
local scroll_top = 1


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
    local p = strings[key]; if not p then return key end
    return p[state.ui_lang] or p.en or key
end
local function outlined(txt, x, y, px, col, align, limit)
    local f = fnt(px); love.graphics.setFont(f)
    love.graphics.setColor(0,0,0,0.9)
    for _,d in ipairs({{-2,0},{2,0},{0,-2},{0,2},{-2,-2},{2,2},{-2,2},{2,-2}}) do
        if align then love.graphics.printf(txt, x+d[1], y+d[2], limit, align)
        else love.graphics.print(txt, x+d[1], y+d[2]) end
    end
    love.graphics.setColor(col[1],col[2],col[3],col[4] or 1)
    if align then love.graphics.printf(txt, x, y, limit, align)
    else love.graphics.print(txt, x, y) end
end
local function vcen(px, h) return (h - fnt(px):getHeight())/2 end

local function panel(x,y,w,h,focused)
    if focused then
        love.graphics.setColor(0.55,0.32,0.85,0.55); love.graphics.rectangle("fill",x,y,w,h,8,8)
        love.graphics.setColor(1.0,0.85,1.0,1.0); love.graphics.setLineWidth(math.max(2,3))
        love.graphics.rectangle("line",x,y,w,h,8,8)
    else
        love.graphics.setColor(0.12,0.08,0.20,0.72); love.graphics.rectangle("fill",x,y,w,h,8,8)
        love.graphics.setColor(1,1,1,0.22); love.graphics.setLineWidth(1)
        love.graphics.rectangle("line",x,y,w,h,8,8)
    end
end


-- ── Row factories ────────────────────────────────────────────────────
function kit.picker(l,vals,labels,key) return {kind="picker",label=l,values=vals,labels=labels,key=key,focusable=true} end
function kit.button(l,action) return {kind="button",label=l,action=action,focusable=true} end
function kit.add_page(title,rows) pages[#pages+1]={title=title,rows=rows}; return #pages end
local function cur() return pages[page_i].rows end
local function focusables()
    local o={}; for i,r in ipairs(cur()) do if r.focusable then o[#o+1]=i end end; return o
end


-- ── Header focus items (secondary pages: back + lang; home: lang only) ──
local function bar_items()
    local b = {}
    if page_i ~= 1 then b[#b+1] = "back" end
    b[#b+1] = "lang"
    return b
end


-- ── Focus navigation ─────────────────────────────────────────────────
local function move_v(d)
    if zone == "bar" then
        if d > 0 then zone="rows"; focus_i = focusables()[1] or 1 end
        return
    end
    local fs = focusables(); local pos=1
    for i,idx in ipairs(fs) do if idx==focus_i then pos=i end end
    pos = pos + d
    if pos < 1 then zone="bar"; bar_i=1; return
    elseif pos > #fs then pos=#fs end
    focus_i = fs[pos]
end
local function move_h(d)
    if zone == "bar" then
        local n = #bar_items()
        bar_i = math.max(1, math.min(n, bar_i + d))
    else
        local r = cur()[focus_i]
        if r and r.kind=="picker" then
            local v=r.values; local idx=1
            for i,x in ipairs(v) do if x==state[r.key] then idx=i end end
            state[r.key]=v[((idx-1+d)%#v)+1]
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
    f:write("# generated by love launcher\n"); port.write_env(f,state,kit); f:close()
end
function kit.resolution_wh()
    local r=state.resolution
    if not r or r=="auto" then return "auto","auto" end
    local w,h=r:match("^(%d+)x(%d+)$"); return w or "auto", h or "auto"
end


-- ── Actions ──────────────────────────────────────────────────────────
local function goto_page(n)
    page_i=n; zone="rows"; focus_i=focusables()[1] or 1; bar_i=1; scroll_top=1
end
local function toggle_lang() state.ui_lang=(state.ui_lang=="en") and "zh" or "en"; save_state() end
local function do_action(a)
    if a=="start" then
        state.launch_count=(tonumber(state.launch_count) or 0)+1
        save_state(); write_env(); love.event.quit(kit.EXIT_START)
    elseif a=="quit" then save_state(); love.event.quit(kit.EXIT_QUIT)
    elseif type(a)=="string" and a:match("^page:") then goto_page(tonumber(a:match("%d+")))
    elseif type(a)=="function" then a(kit) end
end


-- ── LÖVE callbacks ───────────────────────────────────────────────────
function kit.run(cfg)
    port=cfg; love.load=kit.load; love.draw=kit.draw; love.keypressed=kit.keypressed
end
function kit.load()
    realW, realH = love.graphics.getDimensions()
    local fw,fh = tonumber(os.getenv("PAM_FORCE_W")), tonumber(os.getenv("PAM_FORCE_H"))
    if fw and fh then W,H=fw,fh; offX,offY=math.floor((realW-fw)/2),math.floor((realH-fh)/2); letterbox=true
    else W,H=realW,realH; offX,offY=0,0; letterbox=false end
    love.graphics.setBackgroundColor(0.02,0.02,0.03)
    strings={}; for k,v in pairs(kit.BASE_STRINGS) do strings[k]=v end
    for k,v in pairs(port.strings or {}) do strings[k]=v end
    load_state()
    if love.filesystem.getInfo("launcher_bg.png") then bg_img=love.graphics.newImage("launcher_bg.png") end
    pages={}; port.build_pages(kit,state); goto_page(1)
end


-- Adaptive density: pick the largest content scale CS that still fits. Returns a layout table.
local function layout()
    local rows = cur(); local n = #rows
    local n_cred = port.credits and #port.credits or 0
    local function topH(cs)  return (BAR_H + SUB_PX + 12) * cs end
    local function botH(cs)  return (n_cred*24 + 24 + 16) * cs end
    local function fits(cs, rh) return topH(cs)+botH(cs)+n*rh+(n-1)*GAP*cs <= H end

    local cs = math.min(MAXCS, H/720)
    while cs > MINCS and not fits(cs, ROW_MAX*cs) do cs = cs - 0.02 end
    cs = math.max(cs, MINCS)

    local rh = ROW_MAX*cs
    local scroll = false
    if not fits(cs, rh) then                       -- still does not fit at min scale: shrink rows
        rh = (H - topH(cs) - botH(cs) - (n-1)*GAP*cs) / n
        if rh < ROW_MIN*cs then rh = ROW_MIN*cs; scroll = true end
    end

    local gap = GAP*cs
    -- Row width: 78% of screen width on small screens, hard-capped at ROW_MAX_W ——
    -- the cap does not grow with cs, so wide screens never stretch the rows.
    local w = math.min(W*0.78, ROW_MAX_W)
    local x = (W - w)/2
    local content_top = topH(cs)
    local band = (H - botH(cs)) - content_top

    local first, last = 1, n
    local total = n*rh + (n-1)*gap
    local top
    if not scroll then
        top = content_top + (band - total)/2        -- surplus → centre vertically (margins on big screens)
    else
        local per = math.max(1, math.floor((band+gap)/(rh+gap)))
        if focus_i < scroll_top then scroll_top=focus_i end
        if focus_i > scroll_top+per-1 then scroll_top=focus_i-per+1 end
        scroll_top = math.max(1, math.min(scroll_top, n-per+1))
        first, last = scroll_top, math.min(n, scroll_top+per-1)
        top = content_top
    end
    return {cs=cs, x=x, w=w, top=top, rh=rh, gap=gap, first=first, last=last,
            band=band, band_top=content_top, n=n, scroll=scroll}
end


local function draw_bar(cs)
    local secondary = (page_i ~= 1)
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


function kit.draw()
    if letterbox then love.graphics.push(); love.graphics.translate(offX,offY); love.graphics.setScissor(offX,offY,W,H) end

    if bg_img then
        local iw,ih=bg_img:getDimensions(); local sc=math.max(W/iw,H/ih)
        love.graphics.setColor(1,1,1,1); love.graphics.draw(bg_img,(W-iw*sc)/2,(H-ih*sc)/2,0,sc,sc)
    end
    love.graphics.setColor(0,0,0,0.35); love.graphics.rectangle("fill",0,0,W,H)

    local L = layout()
    draw_bar(L.cs)

    local rows = cur(); local yi=0
    for i=L.first,L.last do
        local r=rows[i]; local y=L.top+yi*(L.rh+L.gap); yi=yi+1
        local focused = (zone=="rows" and i==focus_i)
        panel(L.x,y,L.w,L.rh,focused)
        local ty = y + vcen(ROW_PX*L.cs, L.rh)
        if r.kind=="picker" then
            outlined(t(r.label), L.x+18*L.cs, ty, ROW_PX*L.cs, {1,1,1})
            local disp=r.labels[state[r.key]]
            disp = disp and (strings[disp] and t(disp) or disp) or state[r.key]
            outlined("< "..tostring(disp).." >", L.x, ty, ROW_PX*L.cs, {1,1,1}, "right", L.w-18*L.cs)
        else
            outlined(t(r.label), L.x, ty, ROW_PX*L.cs, {1,1,1}, "center", L.w)
        end
    end
    if L.scroll then
        if L.first>1 then outlined("▲",0,L.band_top-2*L.cs,SUB_PX*L.cs,{1,1,1,0.7},"center",W) end
        if L.last<L.n then outlined("▼",0,L.band_top+L.band-14*L.cs,SUB_PX*L.cs,{1,1,1,0.7},"center",W) end
    end

    -- Credits bottom-left / QQ bottom-right
    if port.credits then
        local cy = H - 16*L.cs - #port.credits*24*L.cs
        for i,c in ipairs(port.credits) do
            outlined(t(c[1])..": "..c[2], 16*L.cs, cy+(i-1)*24*L.cs, CRED_PX*L.cs, {1,1,1,0.9})
        end
    end
    outlined(kit.CONTACT, 0, H-32*L.cs, CRED_PX*L.cs, {1,1,1,0.9}, "right", W-16*L.cs)

    if letterbox then
        love.graphics.setScissor(); love.graphics.pop()
        love.graphics.setColor(1,1,1,0.5); love.graphics.setLineWidth(1)
        love.graphics.rectangle("line",offX,offY,W,H)
        outlined(W.."×"..H.." preview", offX+8, offY+4, 14, {1,1,0.6})
    end
end


function kit.keypressed(key)
    if key=="up" then move_v(-1)
    elseif key=="down" then move_v(1)
    elseif key=="left" then move_h(-1)
    elseif key=="right" then move_h(1)
    elseif key=="return" or key=="kpenter" then
        if zone=="bar" then
            local it=bar_items()[bar_i]
            if it=="back" then goto_page(1) elseif it=="lang" then toggle_lang() end
        else
            local r=cur()[focus_i]; if r and r.kind=="button" then do_action(r.action) end
        end
    elseif key=="escape" then
        if page_i~=1 then goto_page(1) else save_state(); love.event.quit(kit.EXIT_QUIT) end
    end
end

return kit
