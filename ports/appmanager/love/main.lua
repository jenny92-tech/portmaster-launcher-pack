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

local function blocking_notice(title,message,id,on_wait)
    kit.set_busy(false)
    local rows={
        kit.textview(L("Status","状态"),message,{id=id..":note",focusable=false,
            expandable=false,max_lines=4,expanded_lines=4,label_px=18,value_px=20,surface=false}),
    }
    if on_wait then rows[#rows+1]=kit.button(L("Keep waiting","继续等待"),on_wait,{id=id..":wait"}) end
    rows[#rows+1]=kit.button(L("Exit","退出"),operations.show_exit_dialog,{id=id..":exit"})
    kit.set_page(page.HOME,title,rows,{sidebar={},row_layout={mode="flow",max_columns=1,min_width=420}})
    kit.goto_page(page.HOME)
end

local function poll_task(dt)
    local task=operations.task
    if not task then return end
    task.elapsed=task.elapsed+dt; task.poll=task.poll+dt
    if task.poll<0.1 then return end
    task.poll=0

    local poll_ok,event=pcall(model.native.poll)
    if not poll_ok then
        event={task_id=task.id,kind=task.kind,status="error",data={}}
    end
    if type(event)=="table" and event.task_id==task.id then
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
        if type(data.snapshot)=="table" then model.apply_snapshot(data.snapshot) end
        if task.kind=="config-refresh" then
            operations.task=nil; kit.set_busy(false)
            local status=type(data.config_refresh)=="table" and data.config_refresh.status or nil
            finish_initial_load(true)
            if status=="updated" then kit.toast(L("Device information updated.","设备信息已更新。"),{kind="success"}) end
        elseif task.kind=="update-check" or task.kind=="update-check-background" then
            operations.task=nil; kit.set_busy(false)
            if event.status=="error" then env.update_status="error" end
            operations.refresh_home()
            if task.kind=="update-check" then environment.build_manage(true); kit.goto_page(page.MANAGE) end
            if event.status=="error" then
                kit.toast(L("Cannot check for updates right now. Try again later.","暂时无法检查更新，请稍后再试。"),{kind="error"})
            elseif task.kind=="update-check" then
                kit.toast(L("Update check completed.","更新检查完成。"),{kind="success"})
            end
            if task.kind=="update-check-background" and not env.size_cache_ready then
                local ok,task_id=pcall(model.native.start,"scan-sizes",{})
                if ok then operations.task={id=task_id,kind="scan-sizes",elapsed=0,poll=0,timeout=120} end
            end
        elseif task.kind=="scan-sizes" then
            operations.task=nil
            operations.refresh_home()
        else operations.finish_task(event) end
        return
    end

    if not task.timeout_notified and task.elapsed>(task.timeout or 45) then
        task.timeout_notified=true; kit.set_busy(false)
        if task.kind=="portmaster" then
            blocking_notice(L("PortMaster is still installing","PortMaster 仍在安装"),
                L("Keep waiting, or reopen App Manager later to see the result.",
                    "请继续等待，或稍后重新打开 APP 查看结果。"),"install-timeout")
        elseif task.kind=="config-refresh" then
            operations.task=nil; finish_initial_load(true)
        elseif task.kind=="update-check" then
            operations.task=nil; env.update_status="error"; operations.refresh_home()
            environment.build_manage(true); kit.goto_page(page.MANAGE)
            kit.toast(L("Cannot check for updates right now. Try again later.","暂时无法检查更新，请稍后再试。"),{kind="error"})
        elseif task.kind=="inventory-refresh" then
            operations.task=nil; pages.build_junk(); kit.goto_page(page.JUNK)
            kit.toast(L("The scan timed out. Please try again.","扫描超时，请重试。"),{kind="error"})
        elseif operations.confirm_return==page.RUNTIME then
            operations.task=nil; pages.build_runtime(); kit.goto_page(page.RUNTIME)
            kit.toast(L("The operation timed out. Try again later.","操作超时，请稍后重试。"),{kind="error"})
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
    if env.portmaster_health=="healthy" or env.portmaster_management=="system" then
        pages.build_home()
        if env.portmaster_management~="system" then
            local ok,task_id=pcall(model.native.start,"update-check-if-stale",{})
            if ok then operations.task={id=task_id,kind="update-check-background",elapsed=0,poll=0,timeout=35} end
        end
    else
        environment.build_repair_gate()
    end
    if not operations.task and not env.size_cache_ready then
        local ok,task_id=pcall(model.native.start,"scan-sizes",{})
        if ok then operations.task={id=task_id,kind="scan-sizes",elapsed=0,poll=0,timeout=120} end
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
