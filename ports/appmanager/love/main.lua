local kit = require("kit")
local native = require("app_native").new()
local model = require("app_model").new(kit,native)
local operations = require("app_operations").new(model)
local pages = require("app_pages").new(model,operations)
local environment = require("app_environment").new(model,operations,pages)

pages.bind_environment(environment)
operations.bind(pages,environment)

local L,page,env=model.L,model.pages,model.env
local finish_initial_load

local function poll_task(dt)
    local task=operations.task
    local background=operations.background_task
    if not task and not background then return end
    local timer=task or background
    timer.elapsed=timer.elapsed+dt; timer.poll=timer.poll+dt
    if timer.poll<0.1 then return end
    timer.poll=0

    local poll_ok,event=pcall(model.native.poll)
    if not poll_ok then
        if task and not task.poll_error_notified then
            task.poll_error_notified=true
            kit.toast(L("Waiting for the background task. Please keep this page open.",
                "正在等待后台任务，请保持当前页面。"),{kind="warning"})
        end
        return
    end
    if type(event)=="table" and background and event.task_id==background.id then
        local data=event.data or {}
        operations.finish_background_update(data.update)
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
        if task.kind=="config-refresh" then
            if type(data.snapshot)=="table" then model.apply_snapshot(data.snapshot) end
            operations.task=nil; kit.set_busy(false)
            local status=type(data.config_refresh)=="table" and data.config_refresh.status or nil
            finish_initial_load(true)
            if status=="updated" then kit.toast(L("Device information updated.","设备信息已更新。"),{kind="success"}) end
        elseif task.kind=="update-check" then
            if type(data.snapshot)=="table" then model.apply_snapshot(data.snapshot)
            elseif type(data.update)=="table" then model.apply_update_result(data.update) end
            operations.merge_pending_update()
            operations.task=nil; kit.set_busy(false)
            if event.status=="error" then env.update_status="error" end
            operations.refresh_home()
            environment.build_manage(true); kit.goto_page(page.MANAGE)
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
        elseif task.kind=="config-refresh" then
            kit.toast(L("Device information is still loading. Please keep waiting.",
                "设备信息仍在加载，请继续等待。"),{kind="info"})
        elseif task.kind=="update-check" or task.kind=="update-check-wait" then
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

finish_initial_load=function(skip_config_refresh)
    if not skip_config_refresh then
        kit.set_busy(true,L("Preparing device information…","正在准备设备信息……"),{
            indeterminate=true,stage=L("Preparing device information","正在准备设备信息"),
            detail="",footer_left="",footer_right=L("Please wait…","请稍候……")})
        local ok,task_id=pcall(model.native.start,"config-refresh",{})
        if ok then
            operations.task={id=task_id,kind="config-refresh",elapsed=0,poll=0,timeout=45}
            return
        end
        kit.set_busy(false)
    end
    pages.reset_selection()
    if env.portmaster_health=="missing" and env.portmaster_management~="system" then
        environment.build_repair_gate()
    else
        pages.build_home()
        if env.portmaster_management~="system" and env.capability_update_portmaster~=false and
            env.portmaster_release_install_allowed~=false and not operations.background_task then
            local ok,task_id=pcall(model.native.start,"update-check-if-stale",{})
            if ok then
                operations.background_task={id=task_id,kind="update-check-background",elapsed=0,poll=0}
            end
        end
        if env.portmaster_health=="damaged" or env.portmaster_python_ok==false then
            kit.toast(L("PortMaster needs attention. See Environment Management.","PortMaster 需要注意，请查看环境管理。"),{kind="warn"})
        end
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
        finish_initial_load(false)
    end,
    update=poll_task,
}

kit.run(port)
