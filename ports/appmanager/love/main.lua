-- INPUT:  kit、app_native、app_model、app_operations、app_shell、app_pages、app_environment、app_input
-- OUTPUT: kit.run(port) 应用入口、可重试的启动失败页与原生任务事件轮询
-- POS:    APP Manager 界面启动、模块装配和前后台任务调度入口
local kit = require("kit")
local native = require("app_native").new()
local model = require("app_model").new(kit,native)
local operations = require("app_operations").new(model)
local shell = require("app_shell").new(model,operations)
local pages = require("app_pages").new(model,operations,shell)
local environment = require("app_environment").new(model,operations,shell)

shell.bind(pages)
pages.bind_environment(environment)
operations.bind(pages,environment)

local L,page,env=model.L,model.pages,model.env
local finish_initial_load,start_background_update
local initial_task
local start_initial_load

local function show_startup_error(reason)
    reason=tostring(reason or "Initial snapshot returned no usable data")
    model.record_failure("initial-snapshot",L("Startup information failed","启动信息读取失败"),reason)
    print("[PAM] startup.error message="..string.format("%q",reason))
    kit.set_page(page.HOME,L("Cannot start Port App Manager","Port App Manager 启动失败"),{
        kit.textview(L("Status","状态"),L(
            "Could not load startup data. Read the reason below, correct it and reload. If the cause is unclear or it still fails, send the log file to "..kit.CONTACT..".",
            "启动数据加载失败，请查看下方具体原因，处理后重新加载。原因不明确或仍失败时，请将日志文件反馈到 "..kit.CONTACT.."。"),{id="startup:error",focusable=false,
            expandable=false,max_lines=4,expanded_lines=4,surface=false}),
        kit.textview(L("Error details","错误详情"),reason,{id="startup:details",
            focusable=true,expandable=true,max_lines=3,surface=false}),
        kit.textview(L("Log file","日志文件"),model.log_path(),{id="startup:log",
            focusable=true,expandable=true,max_lines=2,surface=false}),
        kit.button(L("Reload","重新加载"),function() start_initial_load() end,{id="startup:retry"}),
        kit.button(L("Exit","退出"),operations.show_exit_dialog,{id="startup:exit"}),
    },{sidebar={},row_layout={mode="flow",max_columns=1,min_width=420}})
end

local function poll_task(dt)
    operations.maybe_show_config_restart()
    local task=operations.task
    local background=operations.background_task
    if not initial_task and not task and not background then return end
    local timer=initial_task or task or background
    timer.elapsed=timer.elapsed+dt; timer.poll=timer.poll+dt
    if timer.poll<0.1 then return end
    timer.poll=0

    local poll_ok,event=pcall(model.native.poll)
    if not poll_ok then
        timer.poll_errors=(timer.poll_errors or 0)+1
        if timer.poll_errors>=3 and not timer.bridge_dialog_shown then
            timer.bridge_dialog_shown=true
            kit.dialog({
                title=L("Connection interrupted","连接暂时中断"),
                message=L(
                    "Port App Manager could not read the current task. Retry the connection or return and wait.",
                    "暂时无法读取当前任务。可以重试连接，或返回后继续等待。"),
                confirm=L("Retry","重试"),cancel=L("Keep waiting","继续等待"),danger=false,
                items={tostring(event),L("Log file:\n"..model.log_path(),"日志文件：\n"..model.log_path())},scroll_items=true,
                over_busy=true,
                on_confirm=function()
                    timer.poll_errors=0
                    timer.bridge_dialog_shown=false
                end,
                on_cancel=function()
                    -- Returning is not a dead end: reset the error counter so
                    -- the prompt can reappear if the bridge stays down, instead
                    -- of falling permanently silent.
                    timer.poll_errors=0
                    timer.bridge_dialog_shown=false
                end,
            })
        end
        return
    end
    timer.poll_errors=0
    if timer.bridge_dialog_shown and not kit.debug_dialog().open then
        timer.bridge_dialog_shown=false
    end
    if type(event)=="table" and initial_task and event.task_id==initial_task.id then
        initial_task=nil
        local data=event.data or {}
        if event.status=="complete" and type(data.snapshot)=="table" then
            local ok=model.apply_snapshot(data.snapshot)
            if ok then finish_initial_load() else show_startup_error("Invalid startup snapshot") end
        else
            show_startup_error(data.message)
        end
        return
    end
    if type(event)=="table" and background and event.task_id==background.id then
        local data=event.data or {}
        if background.kind=="config-refresh-background" then
            operations.background_task=nil
            local status=type(data.config_refresh)=="table" and data.config_refresh.status or nil
            if status=="updated" then operations.queue_config_restart() end
            if operations.forced_update_pending then
                if not operations.try_start_forced_update() then
                    kit.set_busy(false)
                    env.update_status="error"
                    kit.toast(L("Cannot check right now. Try again later.","暂时无法检查，请稍后再试。"),{kind="error"})
                end
            else
                start_background_update()
            end
        else
            operations.finish_background_update(data.update)
        end
        return
    end
    task=operations.task
    if type(event)=="table" and task and event.task_id==task.id then
        if event.status=="progress" then
            local progress=model.runtime_progress(event.data)
            if progress then
                progress.on_cancel=operations.request_portmaster_cancel
                progress.on_exit=operations.busy_exit
                progress.cancel_requested=task.cancel_requested==true
                progress.cancel_label=L("Cancel","取消")
                progress.cancelling_label=L("Cancelling…","正在取消…")
                if task.kind=="portmaster" then
                    progress.cancel=L("Cancel installation","取消安装")
                    progress.cancel_label=progress.cancel
                    progress.cancel_disabled=progress.phase=="installing" or progress.phase=="complete"
                    kit.set_busy(true,L("Installing PortMaster…","正在安装 PortMaster…"),progress)
                elseif task.kind=="appledouble" then
                    kit.set_busy(true,L("Cleaning ._Files…","正在清理 ._Files…"),progress)
                else
                    kit.set_busy(true,L("Repairing Runtimes…","正在修复 Runtime…"),progress) end
            end
            return
        end

        local data=event.data or {}
        if task.kind=="update-check" then
            if type(data.snapshot)=="table" then operations.apply_snapshot(data.snapshot)
            elseif type(data.update)=="table" then model.apply_update_result(data.update) end
            operations.merge_pending_update()
            operations.task=nil; kit.set_busy(false)
            if event.status=="error" then env.update_status="error" end
            if event.status~="error" then model.clear_failure("update-check") end
            operations.refresh_home()
            environment.build_manage(true)
            if event.status=="error" then
                operations.report_failure("update-check",L("Update check failed","更新检查失败"),data.message)
            else
                kit.toast(L("Update check completed.","更新检查完成。"),{kind="success"})
            end
        elseif task.kind=="scan-zips" then
            operations.task=nil; kit.set_busy(false)
            if event.status=="error" then
                operations.report_failure("scan-zips",L("Bundle scan failed","压缩包扫描失败"),data.message)
            else
                model.apply_zip_bundles(data.bundles)
                model.clear_failure("scan-zips")
                operations.refresh_home()
                kit.toast(L("Bundle scan completed.","压缩包扫描完成。"),{kind="success"})
            end
            if operations.confirm_return==page.ZIP then
                pages.build_zip_install(true)
                kit.goto_page(page.ZIP)
            elseif kit.debug_page().index==page.ZIP then
                pages.build_zip_install(true)
            end
        elseif task.kind=="install-zips" then
            if type(data.snapshot)=="table" then operations.apply_snapshot(data.snapshot) end
            if type(data.bundles)=="table" then model.apply_zip_bundles(data.bundles) end
            operations.task=nil; kit.set_busy(false)
            local summary=type(data.zip_install)=="table" and data.zip_install or {}
            local installed=tonumber(summary.installed_bundles) or 0
            local conflicts=tonumber(summary.conflicted_bundles) or 0
            local failed=tonumber(summary.failed_bundles) or 0
            local failure_rows={}
            if event.status~="error" then model.selected_zip={} end
            for _,failure in ipairs(type(summary.failures)=="table" and summary.failures or {}) do
                local path=tostring(failure.path or "")
                failure_rows[#failure_rows+1]=path..": "..tostring(failure.message or "Unknown error")
                if path~="" then model.selected_zip["zip:"..path]=true end
            end
            if event.status=="error" then
                operations.report_failure("install-zips",L("Bundle installation failed","压缩包安装失败"),data.message)
            elseif conflicts>0 or failed>0 then
                model.record_failure("install-zips",L("Some packages were not installed","部分安装包未安装"),table.concat(failure_rows,"\n"))
                kit.toast(L(
                    string.format("Installed %d bundle(s); %d conflicted, %d failed.",installed,conflicts,failed),
                    string.format("已安装 %d 个压缩包；%d 个冲突，%d 个失败。",installed,conflicts,failed)),
                    {kind=installed>0 and "warning" or "error"})
                operations.show_failure_details()
            else
                model.clear_failure("install-zips")
                kit.toast(L(string.format("Installed %d bundle(s).",installed),
                    string.format("已安装 %d 个压缩包。",installed)),{kind="success"})
            end
            operations.refresh_home()
            pages.build_zip_install(true)
            kit.goto_page(page.ZIP)
        else operations.finish_task(event) end
        return
    end

    -- Foreground tasks and background lanes both get a one-shot elapsed
    -- notice; neither should ever leave the user staring at a silent lock.
    local active=task or background
    -- Network tasks (update checks / remote config refresh) must stay silent:
    -- on these handhelds the upstream hosts are often unreachable, a failure
    -- is expected, and nagging about it is noise. Local tasks still nudge.
    local net_kind=active and (active.kind or "")
    local network=net_kind and (net_kind:find("update") or net_kind:find("config") or net_kind:find("check"))
    if active and not network and not active.timeout_notified and active.elapsed>(active.timeout or 60) then
        active.timeout_notified=true
        if background then
            kit.toast(L("A background task is still running. Please keep waiting.",
                "后台任务仍在进行，请继续等待。"),{kind="info"})
        elseif task.kind=="portmaster" then
            kit.toast(L("PortMaster is still installing. Please keep waiting.",
                "PortMaster 仍在安装，请继续等待。"),{kind="info"})
        elseif task.kind=="update-check" then
            kit.toast(L("The update check is taking longer than usual.",
                "更新检查耗时较长，请继续等待。"),{kind="info"})
        elseif task.kind=="inventory-refresh" then
            kit.toast(L("The file scan is still running. Please keep waiting.",
                "文件扫描仍在进行，请继续等待。"),{kind="info"})
        else
            kit.toast(L("The operation is still running. Please keep waiting.",
                "操作仍在进行，请继续等待。"),{kind="info"})
        end
    end
    -- Second threshold: a task that ran far past its expected time is likely
    -- stuck. Network tasks are different: a slow link means "still waiting",
    -- not a deadlock, so they only nudge with a toast instead of an alarmist
    -- dialog. Local file/scan tasks get the stuck dialog and an exit escape.
    if active and not network and not active.hard_timeout_shown and active.elapsed>((active.timeout or 60)*2) then
        active.hard_timeout_shown=true
        kit.dialog({
            title=L("Task appears stuck","任务可能卡住"),
            message=L("This task is taking much longer than expected. Keep waiting, or exit and try again later.",
                "任务耗时远超预期。可以继续等待，或退出后稍后再试。"),
            confirm=L("Exit","退出"),cancel=L("Keep waiting","继续等待"),danger=false,
            over_busy=true,on_confirm=function() operations.quit_app() end,
        })
    end
end

start_background_update=function()
    if env.portmaster_health~="missing" and env.portmaster_management~="system" and
        env.capability_update_portmaster~=false and env.portmaster_release_install_allowed~=false and
        not operations.background_task then
        local ok,task_id=pcall(model.native.start,"update-check-if-stale",{})
        if ok then
            operations.background_task={id=task_id,kind="update-check-background",elapsed=0,poll=0,timeout=140}
        end
    end
end

start_initial_load=function()
    kit.set_page(page.HOME,L("Loading…","正在加载…"),{
        kit.textview(L("Status","状态"),L("Reading device and file information…","正在读取设备和文件信息……"),
            {focusable=false,expandable=false,surface=false}),
    },{sidebar={},row_layout={mode="flow",max_columns=1}})
    local ok,task_id=pcall(model.native.start,"initial-snapshot",{})
    if ok then
        initial_task={id=task_id,kind="initial-snapshot",elapsed=0,poll=0,timeout=120}
    else show_startup_error(task_id) end
end

finish_initial_load=function()
    model.clear_failure("initial-snapshot")
    pages.reset_selection()
    -- A new app process always requires an explicit Remote-page opt-in.
    local st=kit.get_state()
    st.web_enabled="0"; st.web_port=nil; st.web_code=nil
    kit.persist_state()
    pages.build_home()
    -- Game management never depends on a working PortMaster core, so the
    -- home page always opens. Only prompt when the problem is certain, and
    -- let the home banner drive the install flow when PortMaster is missing.
    if env.portmaster_management~="system" and model.severe_health_issue() then
        kit.toast(L("PortMaster needs attention. See Environment.","PortMaster 需要注意，请查看运行环境。"),{kind="warning"})
    end
    local ok,task_id=pcall(model.native.start,"config-refresh-if-newer",{})
    if ok then
        operations.background_task={id=task_id,kind="config-refresh-background",elapsed=0,poll=0,timeout=80}
    else
        start_background_update()
    end
end

local port={
    theme={kind="app",background_dim=0.94},
    state={ui_lang="zh",onboarding_seen="0",web_enabled="0",library_filter="all",swap_ab="0",swap_xy="0"},
    strings={working=L("Working…","处理中…")},
    on_home_cancel=operations.show_exit_dialog,
    build_pages=function(k)
        for _=1,6 do k.add_page(L("Loading…","正在加载…"),{
            k.textview(L("Status","状态"),L("Loading…","正在加载……"),{focusable=false,expandable=false,surface=false})}) end
    end,
    on_load=function()
        local st=kit.get_state()
        require("app_native").input_layout(st.swap_ab=="1",st.swap_xy=="1")
        start_initial_load()
    end,
    update=poll_task,
    -- Keep the host waking while native tasks need polling; otherwise block on input.
    wake_interval=function()
        -- Keep waking while a queued device-config restart dialog is pending;
        -- otherwise it only appears after the next button press.
        if initial_task or operations.config_restart_pending then return 0.1 end
        if operations.task or operations.background_task then return 0.1 end
        return nil
    end,
}

kit.run(port)
require("app_input").install(require("app_native"),kit)
