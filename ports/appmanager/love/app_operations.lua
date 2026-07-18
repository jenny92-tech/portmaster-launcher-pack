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

    local function write_plan(items)
        local path=env.plan_file or ""; local f=io.open(path,"wb")
        if not f then return false end
        f:write("# APP Manager plan — validated and applied by launcher.sh\n")
        for _,item in ipairs(items) do
            if tostring(item.arg):find("[\t\r\n]") then f:close(); os.remove(path); return false end
            f:write(item.kind,"\t",item.arg,"\n")
        end
        f:close(); return true
    end

    function self.finish_task()
        kit.set_busy(false)
        local completed_task=self.task
        self.task=nil
        if env.progress_file and env.progress_file~="" then os.remove(env.progress_file) end
        local result=model.read_all(env.result_file or "")
        local failed=result and result:match("FAIL")
        if failed then
            kit.toast(L("The operation reported a failure. See log.txt.","操作有项目失败，请查看 log.txt。"),{kind="error"})
        else
            kit.toast(L("Operation completed.","操作已完成。"),{kind="success"})
        end
        model.load_env(); model.refresh_scan(); page_builders.reset_selection()
        if completed_task and completed_task.kind=="portmaster" then
            if failed then
                environment.build_manage(); kit.goto_page(pages.MANAGE)
                kit.dialog({title=L("PortMaster installation failed","PortMaster 安装失败"),
                    message=L("The new PortMaster installation was not activated. Check log.txt, then retry when the connection is available.",
                        "新的 PortMaster 没有启用。请查看 log.txt，并在网络可用后重试。"),
                    confirm=L("Retry later","稍后重试"),cancel=L("Back","返回"),danger=false})
            else
                kit.dialog({title=L("Installation complete","安装完成"),
                    message=L("PortMaster was installed and is waiting for validation. Exit Port App Manager, then reopen it to finish the check.",
                        "PortMaster 已安装并等待校验。请退出 Port App Manager，再重新打开以完成检查。"),
                    confirm=L("Exit now","立即退出"),cancel=L("Exit","退出"),default_focus="confirm",danger=false,
                    on_confirm=kit.quit,on_cancel=kit.quit})
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
        local f=io.open(env.cancel_file or "","wb")
        if f then f:write("cancel\n"); f:close() end
    end

    function self.start_apply()
        if not self.confirm_plan or #self.confirm_plan==0 then return end
        if not write_plan(self.confirm_plan) or not env.apply_script or env.apply_script=="" then
            kit.toast(L("Cannot start the privileged helper.","无法启动提权操作助手。"),{kind="error"})
            kit.goto_page(self.confirm_return); return
        end
        if env.progress_file and env.progress_file~="" then os.remove(env.progress_file) end
        local portmaster=false
        for _,item in ipairs(self.confirm_plan) do
            if item.kind=="INSTALL_PORTMASTER" then portmaster=true; break end
        end
        if portmaster then
            if env.cancel_file and env.cancel_file~="" then os.remove(env.cancel_file) end
            kit.set_busy(true,L("Installing PortMaster…","正在安装 PortMaster…"),{
                progress=0,stage=L("Preparing PortMaster","正在准备 PortMaster"),detail="",
                footer_left="0%",footer_right=L("Preparing…","准备中…"),
                cancel=L("Cancel before installation","安装前取消"),on_cancel=self.request_portmaster_cancel})
        elseif self.confirm_return==pages.RUNTIME then
            kit.set_busy(true,L("Repairing Runtimes…","正在修复 Runtime…"),{
                progress=0,stage=L("Starting repair","正在启动修复"),detail="",
                footer_left=L("Preparing…","准备中…"),footer_right=L("Preparing…","准备中…")})
        else
            kit.set_busy(true,L("Working…","处理中…"))
        end
        os.execute(model.shquote(env.apply_script).." --apply-plan >/dev/null 2>&1 &")
        self.task={elapsed=0,poll=0,timeout=(self.confirm_return==pages.RUNTIME or portmaster) and 1800 or 45,
            kind=portmaster and "portmaster" or "operation"}
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
