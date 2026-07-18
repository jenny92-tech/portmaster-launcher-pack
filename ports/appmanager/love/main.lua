local kit = require("kit")
local model = require("app_model").new(kit,require("json"),require("scan"))
local operations = require("app_operations").new(model)
local pages = require("app_pages").new(model,operations)
local environment = require("app_environment").new(model,operations,pages)

pages.bind_environment(environment)
operations.bind(pages,environment)

local L,page,env=model.L,model.pages,model.env

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
                kit.toast(L("Stable release check completed.","稳定版检查完成。"),{kind="success"})
            else
                kit.toast(L("Unable to check the stable release. Normal App Manager use is still available.",
                    "无法检查稳定版；APP Manager 的其他功能仍可正常使用。"),{kind="error"})
            end
        elseif task.elapsed>(task.timeout or 35) then
            operations.task=nil; environment.build_manage(true); kit.goto_page(page.MANAGE)
            kit.toast(L("Update check timed out.","更新检查超时。"),{kind="error"})
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
            kit.set_busy(false); operations.task=nil
            kit.dialog({title=L("PortMaster installation is still running","PortMaster 仍在安装"),
                message=L("Exit App Manager and reopen it later. Home will remain unavailable until PortMaster finishes installing.",
                    "请退出 APP，稍后重新打开。PortMaster 安装完成前不能进入首页。"),
                confirm=L("Exit","退出"),cancel=L("Exit now","立即退出"),default_focus="confirm",danger=false,
                on_confirm=kit.quit,on_cancel=kit.quit})
        else
            local progress=model.runtime_progress()
            if progress then progress.cancel_disabled=true; kit.set_busy(true,L("Installing PortMaster…","正在安装 PortMaster…"),progress) end
        end
        return
    end

    if task.kind=="validation" then
        local status,detail=environment.validation_result()
        if status=="valid" or status=="restored" or status=="no-usable" or status=="interrupted" then
            environment.finish_validation(status,detail)
        elseif task.elapsed>(task.timeout or 120) then
            environment.finish_validation("timeout",L("Validation is taking longer than expected. Exit App Manager and reopen it later; do not start another repair while the background check finishes.",
                "校验耗时超出预期。请退出 APP，稍后重新打开；后台检查完成前不要再次开始修复。"))
        end
        return
    end

    if not model.file_exists(env.plan_file) then
        operations.finish_task()
    elseif task.elapsed>(task.timeout or 45) then
        kit.set_busy(false); operations.task=nil
        if task.kind=="portmaster" then
            kit.dialog({title=L("PortMaster installation is still running","PortMaster 仍在安装"),
                message=L("Exit App Manager and reopen it later. Do not start another repair while the background installation finishes.",
                    "请退出 APP，稍后重新打开；后台安装完成前不要再次开始修复。"),
                confirm=L("Exit","退出"),cancel=L("Exit now","立即退出"),default_focus="confirm",danger=false,
                on_confirm=kit.quit,on_cancel=kit.quit})
        elseif operations.confirm_return==page.RUNTIME then
            kit.toast(L("Operation timed out; no further action was taken by the UI.","操作超时；界面未继续执行其他动作。"),{kind="error"})
            pages.build_runtime(); kit.goto_page(page.RUNTIME)
        else pages.build_home(); kit.goto_page(page.HOME) end
    elseif operations.confirm_return==page.RUNTIME or task.kind=="portmaster" then
        local progress=model.runtime_progress()
        if progress then
            if task.kind=="portmaster" then
                progress.cancel=L("Cancel before installation","安装前取消")
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
        for _=1,6 do k.add_page(L("Loading…","正在加载…"),{k.info("Port App Manager",L("Scanning…","正在扫描…"))}) end
    end,
    on_load=function()
        local ok,err=model.load_env()
        if not ok then
            kit.set_page(page.HOME,{en="Port App Manager",zh="Port App Manager"},{kit.info(L("Startup error","启动失败"),err)},
                {sidebar_title=L("Quick Tools","快捷工具"),
                sidebar_footer={lines={L("Developer: Bili 解腻Jenny","开发: Bili 解腻Jenny"),kit.CONTACT}},
                sidebar={kit.button(L("Quit","退出"),operations.show_exit_dialog,{group="bottom"})}})
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
