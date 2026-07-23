local Operations = {}

function Operations.new(model)
    local kit,L=model.kit,model.L
    local env,pages=model.env,model.pages
    local self={confirm_plan=nil,confirm_return=pages.HOME,task=nil}
    local page_builders,environment

    function self.bind(builders,environment_pages)
        page_builders,environment=builders,environment_pages
    end

    function self.show_exit_dialog()
        kit.dialog({
            title=L("Exit Port App Manager?","退出 Port App Manager？"),
            message=L("Return to the system menu?","将返回系统菜单。"),
            confirm=L("Exit","退出"),cancel=L("Stay","暂不退出"),danger=false,on_confirm=kit.quit,
        })
    end

    function self.finish_task(event)
        kit.set_busy(false)
        local completed_task=self.task
        self.task=nil
        local data=event and event.data or {}
        model.invalidate_for_plan(completed_task and completed_task.plan or self.confirm_plan)
        if type(data.snapshot)=="table" then model.apply_snapshot(data.snapshot) end
        local result=type(data.operation)=="table" and data.operation or {}
        local failed=event and event.status=="error" or result.failed==true
        if failed then
            kit.toast(L("The operation failed. See log.txt.","操作失败，请查看 log.txt。"),{kind="error"})
        elseif completed_task and completed_task.kind=="appledouble" then
            local count=tonumber(result.appledouble_removed) or 0
            kit.toast(L(string.format("Removed %d ._Files garbage files.",count),
                string.format("已清理 %d 个 ._Files 垃圾文件。",count)),{kind="success"})
        else
            kit.toast(L("Operation completed.","操作已完成。"),{kind="success"})
        end
        page_builders.reset_selection()
        if completed_task and completed_task.kind=="portmaster" then
            if failed then
                environment.build_manage(); kit.goto_page(pages.MANAGE)
                kit.dialog({title=L("PortMaster installation failed","PortMaster 安装失败"),
                    message=L("Check log.txt, then try again.","请查看 log.txt 后重试。"),
                    confirm=L("Retry later","稍后重试"),cancel=L("Back","返回"),danger=false})
            else
                kit.dialog({title=L("PortMaster installed","PortMaster 已安装"),
                    message=L("Exit and reopen App Manager to finish the check.",
                        "请退出并重新打开 APP，完成最后检查。"),
                    confirm=L("Exit now","立即退出"),cancel=L("Stay","暂不退出"),default_focus="cancel",danger=false,
                    on_confirm=kit.quit})
            end
            return
        end
        if self.confirm_return==pages.RUNTIME then page_builders.build_runtime(); kit.goto_page(pages.RUNTIME)
        else
            page_builders.build_home()
            if self.confirm_return==pages.TRASH then page_builders.build_trash(); kit.goto_page(pages.TRASH)
            elseif self.confirm_return==pages.JUNK then page_builders.build_junk(); kit.goto_page(pages.JUNK)
            else kit.goto_page(pages.HOME) end
        end
    end

    function self.request_portmaster_cancel()
        if self.task then self.task.cancel_requested=true end
        pcall(model.native.cancel)
    end

    function self.start_apply()
        if not self.confirm_plan or #self.confirm_plan==0 then return end
        local portmaster,appledouble=false,false
        for _,item in ipairs(self.confirm_plan) do
            if item.kind=="INSTALL_PORTMASTER" then portmaster=true; break end
            if item.kind=="CLEAN_APPLEDOUBLE" then appledouble=true end
        end
        if portmaster then
            kit.set_busy(true,L("Installing PortMaster…","正在安装 PortMaster…"),{
                progress=0,stage=L("Preparing PortMaster","正在准备 PortMaster"),detail="",
                footer_left="0%",footer_right=L("Preparing…","准备中…"),
                cancel=L("Cancel installation","取消安装"),on_cancel=self.request_portmaster_cancel})
        elseif self.confirm_return==pages.RUNTIME then
            kit.set_busy(true,L("Repairing Runtimes…","正在修复 Runtime…"),{
                progress=0,stage=L("Starting repair","正在启动修复"),detail="",
                footer_left=L("Preparing…","准备中…"),footer_right=L("Preparing…","准备中…")})
        elseif appledouble then
            kit.set_busy(true,L("Cleaning ._Files…","正在清理 ._Files…"),{
                progress=0,stage=L("Scanning Port directories","正在扫描 Port 目录"),detail="",
                footer_left=L("0 files","0 个文件"),footer_right=L("Scanning…","扫描中…")})
        else
            kit.set_busy(true,L("Working…","处理中…"))
        end
        local ok,task_id=pcall(model.native.start,"apply",self.confirm_plan)
        if not ok then
            kit.set_busy(false)
            kit.toast(L("Cannot start the operation.","无法开始操作。"),{kind="error"})
            kit.goto_page(self.confirm_return); return
        end
        self.task={id=task_id,elapsed=0,poll=0,timeout=(self.confirm_return==pages.RUNTIME or portmaster or appledouble) and 1800 or 45,
            kind=portmaster and "portmaster" or appledouble and "appledouble" or "operation",plan=self.confirm_plan}
    end

    function self.start_plan(plan,return_page)
        self.confirm_plan,self.confirm_return=plan,return_page or pages.HOME
        self.start_apply()
    end

    function self.show_confirm(title,plan,labels,return_page,opts)
        opts=opts or {}
        self.confirm_plan,self.confirm_return=plan,return_page or pages.HOME
        local count=#(labels or {})
        kit.dialog({
            title=title,title_checked=opts.title_checked,
            message=opts.message or L(string.format("Review %d selected item%s before continuing.",count,count==1 and "" or "s"),
                string.format("即将处理 %d 个所选项目，请确认后继续。",count)),
            message_checked=opts.message_checked,items=labels,
            confirm=opts.confirm or L("Confirm","确认"),confirm_checked=opts.confirm_checked,
            cancel=L("Cancel","取消"),danger=opts.danger~=false,checkbox=opts.checkbox,
            on_confirm=opts.on_confirm and function(_,checked) opts.on_confirm(checked) end or self.start_apply,
            on_cancel=opts.on_cancel,
        })
    end

    return self
end

return Operations
