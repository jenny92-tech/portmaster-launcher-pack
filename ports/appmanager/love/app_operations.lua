local Operations = {}

function Operations.new(model)
    local kit,L=model.kit,model.L
    local env,pages=model.env,model.pages
    local self={confirm_plan=nil,confirm_revision=nil,confirm_return=pages.HOME,task=nil,background_task=nil,
        pending_update=nil,forced_update_pending=false,config_restart_pending=false}
    local page_builders,environment

    function self.bind(builders,environment_pages)
        page_builders,environment=builders,environment_pages
    end

    function self.refresh_home()
        page_builders.build_home(true)
    end

    -- A destructive confirmation belongs to the exact inventory revision that
    -- produced its paths. Background snapshots may arrive while the dialog is
    -- open; close and discard that dialog instead of silently pairing its old
    -- plan with the new revision.
    function self.apply_snapshot(snapshot,preserve_confirmation)
        local ok,message=model.apply_snapshot(snapshot)
        if ok and not preserve_confirmation and self.confirm_revision and
            self.confirm_revision~=model.inventory_revision then
            self.confirm_plan=nil
            self.confirm_labels=nil
            self.confirm_revision=nil
            kit.close_dialog()
            kit.toast(L("Files changed. Select the items again.","文件已发生变化，请重新选择。"),{kind="warning"})
        end
        return ok,message
    end

    function self.merge_pending_update()
        local update=self.pending_update
        self.pending_update=nil
        if update then return model.apply_update_result(update) end
        return false
    end

    function self.accept_background_update(update)
        if type(update)~="table" then return end
        if self.task then
            self.pending_update=update
            return
        end
        if model.apply_update_result(update) then
            self.refresh_home()
            if environment then environment.build_manage(true) end
        end
    end

    function self.request_forced_update()
        self.forced_update_pending=true
    end

    function self.try_start_forced_update()
        if not self.forced_update_pending or self.task or self.background_task or not environment then
            return false
        end
        self.forced_update_pending=false
        environment.start_forced_update_check()
        return true
    end

    function self.finish_background_update(update)
        self.background_task=nil
        if self.forced_update_pending then
            if not self.try_start_forced_update() then
                kit.set_busy(false)
                env.update_status="error"
                kit.toast(L("Cannot check right now. Try again later.","暂时无法检查，请稍后再试。"),{kind="error"})
            end
            return
        end
        self.accept_background_update(update)
    end

    function self.queue_config_restart()
        self.config_restart_pending=true
    end

    function self.restart_for_config()
        local st=kit.get_state()
        local restart_web=st.web_enabled=="1"
        if restart_web then
            -- Stop the server pinned to the old resolved device contract, but
            -- retain the user's enabled intent for the next APP process.
            pcall(model.native.web_set,false)
            st.web_enabled="1"
            st.web_port=nil
            st.web_code=nil
            kit.persist_state()
        end
        kit.quit()
    end

    function self.maybe_show_config_restart()
        if not self.config_restart_pending or self.task or self.background_task then return false end
        if kit.debug_busy().busy or kit.debug_dialog().open or kit.debug_guide().open then return false end
        self.config_restart_pending=false
        kit.dialog({
            title=L("Device support updated","设备适配已更新"),
            message=L(
                "Restart Port App Manager to use the updated device settings.",
                "重新打开 Port App Manager 后，将使用新的设备适配设置。"),
            confirm=L("Exit now","现在退出"),cancel=L("Dismiss","不再提示"),
            danger=false,on_confirm=self.restart_for_config,
        })
        return true
    end

    local function rebuild_return_page(return_page)
        self.refresh_home()
        if return_page==pages.RUNTIME then page_builders.build_runtime(true)
        elseif return_page==pages.TRASH then page_builders.build_trash(true)
        elseif return_page==pages.JUNK then page_builders.build_junk(true)
        elseif return_page==pages.LAUNCHER then page_builders.build_launcher(true)
        elseif return_page==pages.ZIP then page_builders.build_zip_install(true)
        elseif return_page==pages.GAMES then page_builders.build_games(true) end
        kit.goto_page(return_page or pages.HOME)
    end

    function self.show_exit_dialog()
        kit.dialog({
            title=L("Exit Port App Manager?","退出 Port App Manager？"),
            message=L("Return to the system menu?","将返回系统菜单。"),
            confirm=L("Exit","退出"),cancel=L("Stay","暂不退出"),danger=false,
            on_confirm=function() self.quit_app() end,
        })
    end

    -- Exit the app and stop the remote web service first, so the port is
    -- released immediately instead of lingering with the process.
    function self.quit_app()
        local st=kit.get_state()
        if st.web_enabled=="1" then
            local ok=pcall(model.native.web_set,false)
            if ok then
                st.web_enabled="0"; st.web_port=nil; st.web_code=nil
            end
            kit.persist_state()
        end
        kit.quit()
    end

    function self.finish_task(event)
        kit.set_busy(false)
        local completed_task=self.task
        self.task=nil
        local data=event and event.data or {}
        local result=type(data.operation)=="table" and data.operation or {}
        local failed=event and event.status=="error" or result.failed==true
        -- Every task completion (including failures) carries a snapshot of
        -- the world as the service now sees it; render that, never a stale
        -- guess. Without one, drop all caches instead of trusting them.
        if type(data.snapshot)=="table" then
            self.apply_snapshot(data.snapshot,true)
        else
            model.invalidate_all()
            self.confirm_plan={}
        end
        self.merge_pending_update()
        if completed_task and completed_task.kind=="portmaster" then
            -- The blocking result dialog below already gives the next step.
        elseif completed_task and completed_task.kind=="operation" and self.confirm_return==pages.RUNTIME then
            local handled=tonumber(result.handled) or 0
            local failures=type(result.failures)=="table" and result.failures or {}
            if #failures>0 then
                kit.dialog({
                    title=L("Some Runtimes were not repaired","部分 Runtime 修复失败"),
                    message=L(string.format("Repaired %d Runtime(s). Failed items:",handled),
                        string.format("已修复 %d 个 Runtime，以下项目失败：",handled)),
                    items=failures,confirm=L("OK","知道了"),cancel=L("Back","返回"),danger=false,
                })
            elseif handled>0 then
                kit.toast(L(string.format("Repaired %d Runtimes.",handled),
                    string.format("已处理 %d 个 Runtime。",handled)),{kind="success"})
            else
                kit.toast(L("Operation completed.","操作已完成。"),{kind="success"})
            end
        elseif failed then
            if completed_task and completed_task.cancel_requested==true then
                kit.toast(L("Operation cancelled.","操作已取消。"),{kind="info"})
            elseif tostring(data.message or ""):find("selection changed",1,true) then
                kit.toast(L("Files changed. Rescan and try again.","文件已发生变化，请重新扫描后再试。"),{kind="warning"})
            else
                kit.toast(L("The operation failed. Please try again.","操作失败，请重试。"),{kind="error"})
            end
        elseif completed_task and completed_task.kind=="appledouble" then
            local count=tonumber(result.appledouble_removed) or 0
            kit.toast(L(string.format("Removed %d ._Files.",count),
                string.format("已清理 %d 个 ._Files。",count)),{kind="success"})
        elseif completed_task and completed_task.kind=="inventory-refresh" then
            kit.toast(L("Scan completed.","扫描完成。"),{kind="success"})
        elseif completed_task and completed_task.kind=="operation" then
            local count=#(self.confirm_labels or {})
            local restored,deleted=false,false
            for _,item in ipairs(self.confirm_plan or {}) do
                if item.kind=="RESTORE_ITEM" or item.kind=="RESTORE_REPLACE" then restored=true elseif item.kind=="DELETE_ITEM" or item.kind=="DELETE_MANAGED" then deleted=true end
            end
            if self.confirm_return==pages.TRASH and restored then
                kit.toast(L(string.format("Restored %d item%s.",count,count==1 and "" or "s"),
                    string.format("已放回 %d 项。",count)),{kind="success"})
            elseif self.confirm_return==pages.TRASH and deleted then
                kit.toast(L(string.format("Deleted %d item%s.",count,count==1 and "" or "s"),
                    string.format("已删除 %d 项。",count)),{kind="success"})
            elseif self.confirm_return==pages.JUNK then
                kit.toast(L(string.format("Moved %d item%s to Trash.",count,count==1 and "" or "s"),
                    string.format("已移入回收站 %d 项。",count)),{kind="success"})
            else
                kit.toast(L(string.format("Uninstalled %d game%s.",count,count==1 and "" or "s"),
                    string.format("已卸载 %d 个游戏。",count)),{kind="success"})
            end
        else
            kit.toast(L("Operation completed.","操作已完成。"),{kind="success"})
        end
        self.confirm_plan=nil
        self.confirm_labels=nil
        self.confirm_revision=nil
        page_builders.reset_selection()
        if completed_task and completed_task.kind=="portmaster" then
            if failed then
                environment.build_manage(); kit.goto_page(pages.MANAGE)
                if result.cancelled==true then
                    kit.dialog({title=L("PortMaster installation cancelled","PortMaster 安装已取消"),
                        message=L("Nothing was changed. You can install again any time.","未做任何修改，可随时重新安装。"),
                        confirm=L("OK","知道了"),cancel=L("Back","返回"),danger=false})
                else
                    kit.dialog({title=L("PortMaster installation failed","PortMaster 安装失败"),
                        message=L("Please try again later.","请稍后重试。"),
                        confirm=L("OK","知道了"),cancel=L("Back","返回"),danger=false})
                end
            else
                environment.build_manage(); kit.goto_page(pages.MANAGE)
                kit.dialog({title=L("PortMaster installed","PortMaster 已安装"),
                    message=L("PortMaster is ready to use.","PortMaster 已可以使用。"),
                    confirm=L("OK","知道了"),cancel=L("Back","返回"),danger=false})
            end
            self.try_start_forced_update()
            return
        end
        rebuild_return_page(self.confirm_return)
        self.try_start_forced_update()
    end

    function self.request_portmaster_cancel()
        local ok=pcall(model.native.cancel)
        -- Only report cancelling when the service actually received it; a
        -- failed call must keep the cancel button usable instead of showing
        -- a permanent "Cancelling…" with no way out.
        if ok then self.task.cancel_requested=true end
        return ok
    end

    -- Escape hatch shown while a non-cancellable task blocks the UI: B opens
    -- this over-busy confirmation so a hung scan / check cannot trap the user
    -- with no way out other than killing the process.
    function self.busy_exit()
        kit.dialog({
            title=L("Exit Port App Manager?","退出 Port App Manager？"),
            message=L("A task is still running. Exiting now will stop the app without finishing it.",
                "任务仍在进行。现在退出将不会完成当前任务。"),
            confirm=L("Exit","退出"),cancel=L("Keep waiting","继续等待"),danger=false,
            over_busy=true,on_confirm=function() self.quit_app() end,
        })
    end

    function self.start_apply()
        if not self.confirm_plan or #self.confirm_plan==0 then return end
        if self.task then
            kit.toast(L("Another task is still running. Please wait.",
                "其他任务仍在进行，请稍候。"),{kind="info"})
            return
        end
        local portmaster,appledouble=false,false
        for _,item in ipairs(self.confirm_plan) do
            if item.kind=="INSTALL_PORTMASTER" then portmaster=true; break end
            if item.kind=="CLEAN_APPLEDOUBLE" then appledouble=true end
        end
        if portmaster then
            kit.set_busy(true,L("Installing PortMaster…","正在安装 PortMaster…"),{
                progress=0,indeterminate=true,stage=L("Preparing PortMaster","正在准备 PortMaster"),detail="",
                footer_left="0%",footer_right=L("Preparing…","准备中…"),
                cancel=L("Cancel installation","取消安装"),
                cancel_label=L("Cancel installation","取消安装"),
                on_cancel=self.request_portmaster_cancel,
                on_exit=self.busy_exit})
        elseif self.confirm_return==pages.RUNTIME then
            kit.set_busy(true,L("Repairing Runtimes…","正在修复 Runtime…"),{
                progress=0,indeterminate=true,stage=L("Starting repair","正在启动修复"),detail="",
                footer_left=L("Preparing…","准备中…"),footer_right=L("Preparing…","准备中…"),
                cancel=L("Cancel repair","取消修复"),cancel_label=L("Cancel repair","取消修复"),
                on_cancel=self.request_portmaster_cancel,
                on_exit=self.busy_exit})
        elseif appledouble then
            kit.set_busy(true,L("Cleaning ._Files…","正在清理 ._Files…"),{
                progress=0,indeterminate=true,
                stage=L("Scanning files","正在扫描文件"),detail="",
                footer_left=L("0 files","0 个文件"),footer_right=L("Scanning…","扫描中…"),
                cancel=L("Cancel cleanup","取消清理"),cancel_label=L("Cancel cleanup","取消清理"),
                on_cancel=self.request_portmaster_cancel,
                on_exit=self.busy_exit})
        else
            local stage
            if self.confirm_return==pages.TRASH then stage=L("Working…","正在处理回收站…")
            elseif self.confirm_return==pages.JUNK then stage=L("Working…","正在清理残留…")
            else stage=L("Working…","正在卸载…") end
            kit.set_busy(true,L("Working…","处理中…"),{
                progress=0,indeterminate=true,stage=stage,
                cancel=L("Cancel","取消"),cancel_label=L("Cancel","取消"),
                on_cancel=self.request_portmaster_cancel,
                on_exit=self.busy_exit})
        end
        if not self.confirm_revision or self.confirm_revision~=model.inventory_revision then
            self.confirm_plan=nil
            self.confirm_labels=nil
            self.confirm_revision=nil
            kit.set_busy(false)
            kit.toast(L("Files changed. Select the items again.","文件已发生变化，请重新选择。"),{kind="warning"})
            kit.goto_page(self.confirm_return)
            return
        end
        local ok,task_id=pcall(model.native.start,"apply",self.confirm_plan,self.confirm_revision)
        if not ok then
            kit.set_busy(false)
            kit.toast(L("Cannot start the operation.","无法开始操作。"),{kind="error"})
            kit.goto_page(self.confirm_return); return
        end
        self.task={id=task_id,elapsed=0,poll=0,timeout=(self.confirm_return==pages.RUNTIME or portmaster or appledouble) and 1800 or 45,
            kind=portmaster and "portmaster" or appledouble and "appledouble" or "operation",plan=self.confirm_plan}
    end

    function self.start_plan(plan,return_page)
        self.confirm_plan,self.confirm_revision,self.confirm_return=plan,model.inventory_revision,return_page or pages.HOME
        self.start_apply()
    end

    function self.refresh_inventory(return_page)
        if self.task then
            kit.toast(L("Another task is still running. Please wait.",
                "其他任务仍在进行，请稍候。"),{kind="info"})
            return
        end
        self.confirm_plan={}
        self.confirm_return=return_page or pages.HOME
        kit.set_busy(true,L("Scanning files…","正在扫描文件……"),{
            progress=0,indeterminate=true,
            stage=L("Scanning files…","正在扫描文件……"),
            detail=L("Scanning the Port folders.","正在扫描 Port 目录。"),
            footer_left=L("Scanning…","扫描中…"),footer_right=L("Scanning…","扫描中…"),
            on_exit=self.busy_exit})
        local ok,task_id=pcall(model.native.start,"inventory-refresh")
        if not ok then
            kit.set_busy(false)
            if tostring(task_id):find("already running") then
                kit.toast(L("Another task is still running. Please rescan again later.","其他任务仍在进行，请稍后再扫描。"),{kind="warning"})
            else
                kit.toast(L("Cannot start the scan.","无法开始扫描。"),{kind="error"})
            end
            return
        end
        self.task={id=task_id,elapsed=0,poll=0,timeout=120,kind="inventory-refresh",plan={}}
    end

    function self.scan_zip_bundles(return_page)
        if self.task then
            kit.toast(L("Another task is still running. Please wait.",
                "其他任务仍在进行，请稍候。"),{kind="info"})
            return
        end
        self.confirm_plan={}
        self.confirm_return=return_page or pages.ZIP
        kit.set_busy(true,L("Scanning storage cards…","正在扫描存储卡……"),{
            progress=0,indeterminate=true,
            stage=L("Scanning storage cards…","正在扫描存储卡……"),
            detail=L("Looking for ZIP install packages in the card roots.","正在存储卡根目录查找 ZIP 安装包。"),
            footer_left=L("Scanning…","扫描中…"),footer_right=L("Scanning…","扫描中…"),
            on_cancel=self.request_portmaster_cancel,on_exit=self.busy_exit})
        local ok,task_id=pcall(model.native.start,"scan-zips")
        if not ok then
            kit.set_busy(false)
            kit.toast(L("Cannot start the scan.","无法开始扫描。"),{kind="error"})
            return
        end
        self.task={id=task_id,elapsed=0,poll=0,timeout=90,kind="scan-zips",plan={}}
    end

    function self.install_zip_bundles(bundles,replace_existing)
        if self.task then
            kit.toast(L("Another task is still running. Please wait.",
                "其他任务仍在进行，请稍候。"),{kind="info"})
            return false
        end
        local plan={}
        for _,bundle in ipairs(bundles or {}) do
            if type(bundle.path)=="string" and bundle.path~="" then
                plan[#plan+1]={
                    kind="INSTALL_ZIP",arg=bundle.path,
                    source_identity=tostring(bundle.source_identity or ""),
                    replace_existing=replace_existing==true,
                }
            end
        end
        if #plan==0 then return false end
        self.confirm_plan=plan
        self.confirm_return=pages.ZIP
        kit.set_busy(true,L("Installing bundles…","正在安装压缩包……"),{
            progress=0,indeterminate=true,
            stage=L("Validating and installing selected bundles…","正在校验并安装所选压缩包……"),
            detail=L("Large bundles may take several minutes. The interface will remain responsive.",
                "大容量压缩包可能需要数分钟，界面会保持响应。"),
            footer_left=L(string.format("%d selected",#plan),string.format("已选择 %d 个",#plan)),
            footer_right=L("Working…","处理中……"),
            on_cancel=self.request_portmaster_cancel,on_exit=self.busy_exit})
        local ok,task_id=pcall(model.native.start,"install-zips",plan)
        if not ok then
            kit.set_busy(false)
            kit.toast(L("Cannot start bundle installation.","无法开始安装压缩包。"),{kind="error"})
            return false
        end
        self.task={id=task_id,elapsed=0,poll=0,timeout=1800,kind="install-zips",plan=plan}
        return true
    end

    function self.show_confirm(title,plan,labels,return_page,opts)
        opts=opts or {}
        self.confirm_plan,self.confirm_revision,self.confirm_return=plan,model.inventory_revision,return_page or pages.HOME
        self.confirm_labels=labels
        local count=#(labels or {})
        kit.dialog({
            title=title,title_checked=opts.title_checked,
            message=opts.message or L(string.format("%d item%s selected.",count,count==1 and "" or "s"),
                string.format("已选择 %d 个项目。",count)),
            message_checked=opts.message_checked,items=labels,
            confirm=opts.confirm or L("Confirm","确认"),confirm_checked=opts.confirm_checked,
            cancel=L("Cancel","取消"),danger=opts.danger~=false,checkbox=opts.checkbox,
            on_confirm=opts.on_confirm and function(_,checked) opts.on_confirm(checked) end or self.start_apply,
            on_cancel=function(...)
                self.confirm_plan=nil
                self.confirm_labels=nil
                self.confirm_revision=nil
                if opts.on_cancel then return opts.on_cancel(...) end
            end,
        })
    end

    return self
end

return Operations
