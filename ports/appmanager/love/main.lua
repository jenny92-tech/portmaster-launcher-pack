local kit = require("kit")
local model = require("app_model").new(kit,require("json"),require("scan"))
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
        kit.textview(L("What to do","请执行"),message,{id=id..":note",focusable=false,
            expandable=false,max_lines=4,expanded_lines=4,label_px=16,value_px=20,surface=false}),
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
    if task.poll<0.25 then return end
    task.poll=0

    if task.kind=="config-refresh" then
        local text=model.read_all(env.config_refresh_result or "")
        local status=text and text:match("^1\t([^\r\n]+)") or nil
        if status=="updated" or status=="unchanged" or status=="error" then
            operations.task=nil; kit.set_busy(false)
            if status=="updated" and env.apply_script and env.apply_script~="" then
                os.execute(model.shquote(env.apply_script).." --write-env >/dev/null 2>&1")
                model.load_env(); model.invalidate_all()
            end
            finish_initial_load(true)
            if status=="updated" then
                kit.toast(L("Device configuration updated.","设备配置已更新。"),{kind="success"})
            elseif status=="error" then
                kit.toast(L("Using the built-in device configuration.","正在使用随包设备配置。"),{kind="info"})
            end
        elseif task.elapsed>(task.timeout or 45) then
            operations.task=nil; kit.set_busy(false); finish_initial_load(true)
            kit.toast(L("Using the cached device configuration.","正在使用已缓存的设备配置。"),{kind="info"})
        end
        return
    end

    if task.kind=="update-check" then
        local status=model.load_update_cache()
        if status=="ok" or status=="error" then
            operations.task=nil; environment.build_manage(true); kit.goto_page(page.MANAGE)
            if status=="ok" then
                kit.toast(L("Update check completed.","更新检查完成。"),{kind="success"})
            else
                kit.toast(L("Update check failed. Try again later.","检查更新失败，请稍后重试。"),{kind="error"})
            end
        elseif task.elapsed>(task.timeout or 35) then
            operations.task=nil; environment.build_manage(true); kit.goto_page(page.MANAGE)
            kit.toast(L("Update check timed out. Try again later.","检查更新超时，请稍后重试。"),{kind="error"})
        end
        return
    end

    if task.kind=="active-repair" then
        if not model.file_exists(env.portmaster_active) then
            kit.set_busy(false); operations.task=nil; model.load_env(); model.invalidate_all()
            if model.file_exists(env.pending_install) or model.file_exists(env.install_transaction) then
                environment.start_pending_validation()
            else
                pages.reset_selection()
                if env.portmaster_health=="healthy" or env.portmaster_management=="system" then pages.build_home(); kit.goto_page(page.HOME)
                else environment.build_repair_gate(); kit.goto_page(page.HOME) end
            end
        elseif task.elapsed>(task.timeout or 1800) then
            operations.task=nil
            blocking_notice(L("PortMaster is still installing","PortMaster 仍在安装"),
                L("Keep waiting, or exit and reopen App Manager later. Do not start another installation.",
                    "请继续等待，或稍后退出并重新打开 APP。不要重复安装。"),"install-timeout",
                environment.start_active_repair_wait)
        end
        return
    end

    if task.kind=="validation" then
        local status,detail=environment.validation_result()
        if status=="valid" or status=="restored" or status=="no-usable" or status=="interrupted" then
            environment.finish_validation(status,detail)
        elseif task.elapsed>(task.timeout or 120) then
            environment.finish_validation("timeout",L("The check is taking longer than expected. Exit and reopen App Manager later. Do not reinstall PortMaster while it is still running.",
                "检查时间较长。请退出并稍后重新打开 APP，检查完成前不要重复安装。"))
        end
        return
    end

    if not model.file_exists(env.plan_file) then
        operations.finish_task()
    elseif not task.timeout_notified and task.elapsed>(task.timeout or 45) then
        task.timeout_notified=true
        kit.set_busy(false)
        if task.kind=="portmaster" then
            blocking_notice(L("PortMaster is still installing","PortMaster 仍在安装"),
                L("Keep waiting, or exit and reopen App Manager later. Do not start another installation.",
                    "请继续等待，或稍后退出并重新打开 APP。不要重复安装。"),"install-timeout",
                environment.start_active_repair_wait)
        elseif operations.confirm_return==page.RUNTIME then
            kit.toast(L("The operation timed out. Try again later.","操作超时，请稍后重试。"),{kind="error"})
            pages.build_runtime(); kit.goto_page(page.RUNTIME)
        else pages.build_home(); kit.goto_page(page.HOME) end
    elseif task.timeout_notified then
        -- The helper is still authoritative after the UI timeout. Keep only
        -- the cheap completion-file poll alive; finish_task will invalidate
        -- the affected caches if the background operation completes later.
        return
    elseif operations.confirm_return==page.RUNTIME or task.kind=="portmaster" or task.kind=="appledouble" then
        local progress=model.runtime_progress()
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
            else
                kit.set_busy(true,L("Repairing Runtimes…","正在修复 Runtime…"),progress)
            end
        end
    end
end

finish_initial_load=function(skip_config_refresh)
    if env.portmaster_management~="system" and
       (model.file_exists(env.pending_install) or model.file_exists(env.install_transaction)) then
        environment.start_pending_validation()
        return
    end
    if env.portmaster_management~="system" and model.file_exists(env.portmaster_active) then
        environment.start_active_repair_wait()
        return
    end
    if not skip_config_refresh and env.apply_script and env.apply_script~="" and
       env.config_refresh_result and env.config_refresh_result~="" then
        os.remove(env.config_refresh_result)
        operations.task={kind="config-refresh",elapsed=0,poll=0,timeout=45}
        kit.set_busy(true,L("Checking device configuration…","正在检查设备配置……"),{
            progress=0,stage=L("Checking device configuration","正在检查设备配置"),
            detail=L("The built-in configuration remains available if the network is unavailable.",
                "网络不可用时会继续使用随包配置。"),footer_left="",footer_right=L("Checking…","检查中……")})
        os.execute(model.shquote(env.apply_script).." --refresh-device-config >/dev/null 2>&1 &")
        return
    end
    pages.reset_selection()
    if env.portmaster_health=="healthy" or env.portmaster_management=="system" then
        pages.build_home()
        if env.portmaster_management~="system" and env.apply_script and env.apply_script~="" then
            os.execute(model.shquote(env.apply_script).." --check-pm-update >/dev/null 2>&1 &")
        end
    else
        environment.build_repair_gate()
    end
    if env.apply_script and env.apply_script~="" and not model.file_exists(env.size_file) then
        os.execute(model.shquote(env.apply_script).." --scan-sizes >/dev/null 2>&1 &")
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
        local ok,err=model.load_env()
        if not ok then
            kit.set_page(page.HOME,L("Cannot start Port App Manager","Port App Manager 启动失败"),{
                kit.textview(L("Error","错误"),model.provided(err),{id="startup:error",focusable=false,
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
