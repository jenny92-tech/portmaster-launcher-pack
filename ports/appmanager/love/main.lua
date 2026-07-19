local kit = require("kit")
local model = require("app_model").new(kit,require("json"),require("scan"))
local operations = require("app_operations").new(model)
local pages = require("app_pages").new(model,operations)
local environment = require("app_environment").new(model,operations,pages)

pages.bind_environment(environment)
operations.bind(pages,environment)

local L,page,env=model.L,model.pages,model.env

local function blocking_notice(title,message,id)
    kit.set_busy(false)
    kit.set_page(page.HOME,title,{
        kit.textview(L("What to do","请执行"),message,{id=id..":note",focusable=false,
            expandable=false,max_lines=4,expanded_lines=4,label_px=16,value_px=20,surface=false}),
        kit.button(L("Exit","退出"),kit.quit,{id=id..":exit"}),
    },{sidebar={},row_layout={mode="flow",max_columns=1,min_width=420}})
    kit.goto_page(page.HOME)
end

local function poll_task(dt)
    local task=operations.task
    if not task then return end
    task.elapsed=task.elapsed+dt; task.poll=task.poll+dt
    if task.poll<0.25 then return end
    task.poll=0

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
            kit.set_busy(false); operations.task=nil; model.load_env()
            if model.file_exists(env.pending_install) or model.file_exists(env.install_transaction) then
                environment.start_pending_validation()
            else
                model.refresh_scan(); pages.reset_selection()
                if env.portmaster_health=="healthy" then pages.build_home(); kit.goto_page(page.HOME)
                else environment.build_repair_gate(); kit.goto_page(page.HOME) end
            end
        elseif task.elapsed>(task.timeout or 1800) then
            operations.task=nil
            blocking_notice(L("PortMaster is still installing","PortMaster 仍在安装"),
                L("Exit and reopen App Manager later. Do not start another installation.",
                    "请退出并稍后重新打开 APP，不要重复安装。"),"install-timeout")
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
    elseif task.elapsed>(task.timeout or 45) then
        kit.set_busy(false); operations.task=nil
        if task.kind=="portmaster" then
            blocking_notice(L("PortMaster is still installing","PortMaster 仍在安装"),
                L("Exit and reopen App Manager later. Do not start another installation.",
                    "请退出并稍后重新打开 APP，不要重复安装。"),"install-timeout")
        elseif operations.confirm_return==page.RUNTIME then
            kit.toast(L("The operation timed out. Try again later.","操作超时，请稍后重试。"),{kind="error"})
            pages.build_runtime(); kit.goto_page(page.RUNTIME)
        else pages.build_home(); kit.goto_page(page.HOME) end
    elseif operations.confirm_return==page.RUNTIME or task.kind=="portmaster" then
        local progress=model.runtime_progress()
        if progress then
            if task.kind=="portmaster" then
                progress.cancel=L("Cancel installation","取消安装")
                progress.on_cancel=operations.request_portmaster_cancel
                progress.cancel_requested=task.cancel_requested==true
                progress.cancelling_label=L("Cancelling…","正在取消…")
                progress.cancel_disabled=progress.phase=="installing" or progress.phase=="complete"
                kit.set_busy(true,L("Installing PortMaster…","正在安装 PortMaster…"),progress)
            else
                kit.set_busy(true,L("Repairing Runtimes…","正在修复 Runtime…"),progress)
            end
        end
    end
end

local port={
    theme={kind="app",background_dim=0.94},
    state={ui_lang="zh"},
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
        if model.file_exists(env.pending_install) or model.file_exists(env.install_transaction) then
            environment.start_pending_validation()
        elseif model.file_exists(env.portmaster_active) then
            environment.start_active_repair_wait()
        else
            model.refresh_scan(); pages.reset_selection()
            if env.portmaster_health=="healthy" then
                pages.build_home()
                if env.apply_script and env.apply_script~="" then
                    os.execute(model.shquote(env.apply_script).." --check-pm-update >/dev/null 2>&1 &")
                end
            else
                environment.build_repair_gate()
            end
        end
        if env.apply_script and env.apply_script~="" then
            os.execute(model.shquote(env.apply_script).." --scan-sizes >/dev/null 2>&1 &")
            os.execute(model.shquote(env.apply_script).." --refresh-runtime-metadata >/dev/null 2>&1 &")
        end
    end,
    update=poll_task,
}

kit.run(port)
