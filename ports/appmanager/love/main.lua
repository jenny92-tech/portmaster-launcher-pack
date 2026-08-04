local kit = require("kit")
local native = require("app_native").new()
local model = require("app_model").new(kit,native)
local operations = require("app_operations").new(model)
local pages = require("app_pages").new(model,operations)
local environment = require("app_environment").new(model,operations,pages)

pages.bind_environment(environment)
operations.bind(pages,environment)

local L,page,env=model.L,model.pages,model.env
local finish_initial_load,start_background_update

local function poll_task(dt)
    operations.maybe_show_config_restart()
    local task=operations.task
    local background=operations.background_task
    if not task and not background then return end
    local timer=task or background
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
                confirm=L("Retry","重试"),cancel=L("Return","返回"),danger=false,
                over_busy=true,
                on_confirm=function()
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
    if type(event)=="table" and background and event.task_id==background.id then
        local data=event.data or {}
        if background.kind=="config-refresh-background" then
            operations.background_task=nil
            local status=type(data.config_refresh)=="table" and data.config_refresh.status or nil
            if status=="updated" then operations.queue_config_restart() end
            if operations.forced_update_pending then
                operations.try_start_forced_update()
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
                if task.kind=="portmaster" then
                    progress.cancel=L("Cancel installation","取消安装")
                    progress.on_cancel=operations.request_portmaster_cancel
                    progress.cancel_requested=task.cancel_requested==true
                    progress.cancelling_label=L("Cancelling…","正在取消…")
                    progress.cancel_disabled=progress.phase=="installing" or progress.phase=="complete"
                    kit.set_busy(true,L("Installing PortMaster…","正在安装 PortMaster…"),progress)
                elseif task.kind=="appledouble" then
                    kit.set_busy(true,L("Cleaning ._Files…","正在清理 ._Files…"),progress)
                else kit.set_busy(true,L("Repairing Runtimes…","正在修复 Runtime…"),progress) end
            end
            return
        end

        local data=event.data or {}
        if task.kind=="update-check" then
            if type(data.snapshot)=="table" then model.apply_snapshot(data.snapshot)
            elseif type(data.update)=="table" then model.apply_update_result(data.update) end
            operations.merge_pending_update()
            operations.task=nil; kit.set_busy(false)
            if event.status=="error" then env.update_status="error" end
            operations.refresh_home()
            environment.build_manage(true)
            if event.status=="error" then
                kit.toast(L("Cannot check for updates right now. Try again later.","暂时无法检查更新，请稍后再试。"),{kind="error"})
            else
                kit.toast(L("Update check completed.","更新检查完成。"),{kind="success"})
            end
        else operations.finish_task(event) end
        return
    end

    if task and not task.timeout_notified and task.elapsed>(task.timeout or 45) then
        task.timeout_notified=true
        if task.kind=="portmaster" then
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
end

start_background_update=function()
    if env.portmaster_health~="missing" and env.portmaster_management~="system" and
        env.capability_update_portmaster~=false and env.portmaster_release_install_allowed~=false and
        not operations.background_task then
        local ok,task_id=pcall(model.native.start,"update-check-if-stale",{})
        if ok then
            operations.background_task={id=task_id,kind="update-check-background",elapsed=0,poll=0}
        end
    end
end

finish_initial_load=function()
    pages.reset_selection()
    if env.portmaster_health=="missing" and env.portmaster_management~="system" then
        environment.build_repair_gate()
    else
        pages.build_home()
        if env.portmaster_health=="damaged" or env.portmaster_python_ok==false then
            kit.toast(L("PortMaster needs attention. See Environment Management.","PortMaster 需要注意，请查看环境管理。"),{kind="warn"})
        end
    end
    local ok,task_id=pcall(model.native.start,"config-refresh-if-newer",{})
    if ok then
        operations.background_task={id=task_id,kind="config-refresh-background",elapsed=0,poll=0}
    else
        start_background_update()
    end
end

local port={
    theme={kind="app",background_dim=0.94},
    state={ui_lang="zh",onboarding_seen="0"},
    strings={working=L("Working…","处理中…")},
    on_home_cancel=operations.show_exit_dialog,
    build_pages=function(k)
        for _=1,6 do k.add_page(L("Loading…","正在加载…"),{
            k.textview(L("Status","状态"),L("Loading…","正在加载……"),{focusable=false,expandable=false,surface=false})}) end
    end,
    on_load=function()
        local ok=model.load_env()
        if not ok then
            kit.set_page(page.HOME,L("Cannot start Port App Manager","Port App Manager 启动失败"),{
                kit.textview(L("Status","状态"),L(
                    "Port App Manager could not start. Reinstall it and try again.",
                    "Port App Manager 无法启动。请重新安装后再试。"),{id="startup:error",focusable=false,
                    expandable=false,max_lines=4,expanded_lines=4,surface=false}),
                kit.button(L("Exit","退出"),operations.show_exit_dialog,{id="startup:exit"}),
            },{sidebar={},row_layout={mode="flow",max_columns=1,min_width=420}})
            return
        end
        finish_initial_load()
    end,
    update=poll_task,
}

kit.run(port)
