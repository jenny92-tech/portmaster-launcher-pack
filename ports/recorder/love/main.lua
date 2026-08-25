-- Screen Recorder — standalone handheld recording app.
-- LÖVE UIKit page: state + Start / Stop & Assemble / Refresh.
-- The engine is the shell CLI at $REC_ENGINE (record_screen.sh); this UI only
-- calls it with status/start/stop and renders the machine-parseable status.

local kit = require("kit")

local ENGINE = os.getenv("REC_ENGINE") or ""
local HOME = 1
local poll_elapsed = 0
local start_recording, stop_recording

local function engine(args)
    if ENGINE == "" then return false, "REC_ENGINE not set" end
    local f = io.popen(string.format('"%s" %s 2>&1', ENGINE, args), "r")
    if not f then return false, "cannot run engine" end
    local out = f:read("*a") or ""
    f:close()
    return true, out
end

local function parse_status(out)
    local st = {}
    for line in (out or ""):gmatch("[^\r\n]+") do
        local key, value = line:match("^([a-z_]+)=(.*)$")
        if key then st[key] = value end
    end
    return st
end

local function extract_saved(out)
    for line in (out or ""):gmatch("[^\r\n]+") do
        local path = line:match("^saved: (.*)$")
        if path then return path end
    end
    return (out or ""):gsub("%s+$", "")
end

local function refresh()
    local ok, out = engine("status")
    local st = parse_status(ok and out or "state=error")
    local rows = {}

    rows[#rows + 1] = kit.section({en = "Recorder", zh = "录屏助手"})
    if st.state == "recording" then
        rows[#rows + 1] = kit.info({en = "State", zh = "状态"},
            {en = "● Recording", zh = "● 录制中"}, {id = "state"})
        rows[#rows + 1] = kit.info({en = "Session", zh = "会话"}, st.session or "-")
        rows[#rows + 1] = kit.info({en = "Frames", zh = "帧数"}, st.frames or "0", {id = "frames"})
        rows[#rows + 1] = kit.info({en = "Rate", zh = "帧率"}, (st.fps or "5") .. " fps")
        rows[#rows + 1] = kit.button({en = "Stop & Assemble", zh = "停止并合成"}, stop_recording,
            {id = "stop", half = false})
        rows[#rows + 1] = kit.textview(
            {en = "Tip", zh = "提示"},
            {en = "Press B to return to the menu and start a game. Recording continues in the background.",
             zh = "按 B 返回主菜单开始游戏,录制会继续在后台进行。"},
            {focusable = false, expandable = false, surface = false, max_lines = 3, expanded_lines = 3})
    else
        rows[#rows + 1] = kit.info({en = "State", zh = "状态"},
            {en = "Idle", zh = "空闲"}, {id = "state"})
        rows[#rows + 1] = kit.button({en = "Start Recording", zh = "开始录制"}, start_recording,
            {action = "start", id = "start"})
        if st.last_video and st.last_video ~= "" then
            rows[#rows + 1] = kit.info({en = "Last video", zh = "上次视频"}, st.last_video)
        end
    end
    rows[#rows + 1] = kit.button({en = "Refresh", zh = "刷新"}, refresh, {id = "refresh"})

    kit.set_page(HOME, {en = "Screen Recorder", zh = "录屏助手"}, rows, {preserve_focus = true})
end

start_recording = function()
    local ok, out = engine("start")
    if ok and not out:find("ERROR", 1, true) then
        kit.toast(
            {en = "Recording started. Press B to return and play your game.",
             zh = "已开始录制。按 B 返回主菜单开始游戏。"},
            {kind = "success", duration = 6})
    else
        kit.dialog({
            title = {en = "Start failed", zh = "启动失败"},
            message = out,
            confirm = {en = "OK", zh = "确定"},
        })
    end
    refresh()
end

stop_recording = function()
    -- stop() kills the capture and assembles the MP4; short clips take a few
    -- seconds, so keep the busy overlay honest.
    local ok, out = engine("stop")
    if ok and not out:find("ERROR", 1, true) then
        local path = extract_saved(out)
        kit.dialog({
            title = {en = "Video saved", zh = "视频已保存"},
            message = {en = "Saved to:\n" .. path, zh = "已保存到:\n" .. path},
            confirm = {en = "OK", zh = "确定"},
        })
    else
        kit.dialog({
            title = {en = "Stop failed", zh = "停止失败"},
            message = out,
            confirm = {en = "OK", zh = "确定"},
        })
    end
    refresh()
end

local function on_home_cancel()
    kit.dialog({
        title = {en = "Exit", zh = "退出"},
        message = {en = "Exit Screen Recorder?", zh = "退出录屏助手?"},
        confirm = {en = "Exit", zh = "退出"},
        cancel = {en = "Stay", zh = "取消"},
        on_confirm = function() kit.quit() end,
    })
end

local function update(dt)
    poll_elapsed = poll_elapsed + (dt or 0)
    if poll_elapsed >= 2 then
        poll_elapsed = 0
        if not kit.debug_dialog().open then refresh() end
    end
end

local port = {
    theme = {kind = "app", background_dim = 0.94},
    state = {ui_lang = "zh"},
    strings = {},
    on_home_cancel = on_home_cancel,
    build_pages = function(k)
        k.add_page({en = "Screen Recorder", zh = "录屏助手"}, {
            k.textview({en = "Status", zh = "状态"},
                {en = "Loading…", zh = "正在加载……"},
                {focusable = false, expandable = false, surface = false}),
        })
    end,
    on_load = function() refresh() end,
    update = update,
    wake_interval = function() return 2.0 end,
}

kit.run(port)
