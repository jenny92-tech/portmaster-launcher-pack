local Environment = {}

function Environment.new(model,operations,pages_ui)
    local kit,L=model.kit,model.L
    local env,page=model.env,model.pages
    local self={}
    local device_risk_ack,device_support_ack=false,false
    local function button(label,action,opts) return kit.button(label,action,opts) end
    local function system_managed() return env.portmaster_management=="system" end
    local function enabled(name) return env[name]~=false end
    local function can_install() return not system_managed() and enabled("capability_manage_portmaster") and
        enabled("capability_install_portmaster") and env.portmaster_release_install_allowed~=false end
    local function can_update() return can_install() and enabled("capability_update_portmaster") end
    local function note(label,value,id)
        return kit.textview(label,value,{id=id,focusable=false,expandable=false,max_lines=4,
            expanded_lines=4,label_px=18,value_px=20,surface=false})
    end

    local function health_label()
        if system_managed() then
            if env.portmaster_health=="healthy" then return L("Managed by system · Available","系统管理 · 当前可用") end
            if env.portmaster_health=="damaged" then return L("Managed by system · Needs repair","系统管理 · 需要修复") end
            return L("Managed by system · Not available","系统管理 · 当前不可用")
        end
        if env.portmaster_health=="healthy" then return L("Healthy","正常") end
        if env.portmaster_health=="damaged" then return L("Needs repair","需要修复") end
        return L("Not installed","未安装")
    end

    local function confirm_environment_repair(plan)
        local healthy=env.portmaster_health=="healthy"
        local state=model.update_state()
        local title,message
        if healthy and state=="update" then
            title=L("Update PortMaster","更新 PortMaster")
            message=L("Update from "..tostring(env.portmaster_version or "?").." to "..tostring(env.portmaster_latest or "?")..". Runtimes and personal settings will be kept.",
                "将从 "..tostring(env.portmaster_version or "?").." 更新到 "..tostring(env.portmaster_latest or "?").."。Runtime 和个人设置会保留。")
        elseif healthy then
            title=L("Reinstall PortMaster","重新安装 PortMaster")
            message=L("Reinstall the current version. Runtimes and personal settings will be kept.",
                "将重新安装当前版本。Runtime 和个人设置会保留。")
        elseif env.portmaster_health=="damaged" then
            title=L("Repair PortMaster","修复 PortMaster")
            message=L("Download and reinstall PortMaster. Runtimes and personal settings will be kept.",
                "将下载并重新安装 PortMaster。Runtime 和个人设置会保留。")
        else
            title=L("Install PortMaster","安装 PortMaster")
            message=L("Download and install PortMaster.","将下载并安装 PortMaster。")
        end
        kit.dialog({
            title=title,
            message=message,confirm=L("Continue","继续"),cancel=L("Cancel","取消"),danger=false,
            on_confirm=function()
                operations.start_plan(plan or {{kind="INSTALL_PORTMASTER",arg="stable"}},page.MANAGE)
            end,
        })
    end

    function self.repair_environment()
        if system_managed() then
            kit.dialog({title=L("Managed by system","由系统管理"),
                message=L("PortMaster is maintained by the system. Use the system update or recovery tools if it stops working.",
                    "PortMaster 由系统维护。无法使用时，请通过系统更新或恢复。"),
                confirm=L("OK","知道了"),cancel=L("Back","返回"),danger=false})
            return
        end
        if not can_install() then
            kit.toast(L("This device does not support PortMaster installation here.",
                "当前设备暂不支持安装 PortMaster。"),{kind="info"})
            return
        end
        local class=tostring(env.device_class or "unknown-path")
        if class=="tested" then confirm_environment_repair(); return end
        if env.target_confirmed~="1" or not env.portmaster_target or env.portmaster_target=="" or class=="unknown-path" then
            kit.dialog({title=L("Installation path unavailable","无法确定安装位置"),
                message=L("The PortMaster install location could not be found. Nothing was changed.",
                    "无法确定 PortMaster 安装位置，未进行任何修改。"),
                confirm=L("Back","返回"),cancel=L("Cancel","取消"),danger=false})
            return
        end
        device_risk_ack,device_support_ack=false,false
        local function build_gate(preserve)
            local rows={
                note(L("Before continuing","继续前确认"),
                    class=="official-untested" and
                        L("This device has not been tested. Confirm to continue.",
                            "这台设备尚未实测。确认后可以继续。") or
                        L("PortMaster does not support this device yet. Confirm the install location.",
                            "PortMaster 尚未支持这台设备。请确认安装位置。"),"risk:note"),
                kit.checkbox(L("I understand this device has not been tested","我知道这台设备尚未实测"),{
                    id="risk:modify",checked=device_risk_ack,on_change=function(value) device_risk_ack=value; build_gate(true) end}),
            }
            if class=="unsupported-known" then
                rows[#rows+1]=kit.checkbox(L("I confirm the device and install location","我已确认设备和安装位置"),{
                    id="risk:support",detail=env.portmaster_target,checked=device_support_ack,
                    on_change=function(value) device_support_ack=value; build_gate(true) end})
            end
            local ready=device_risk_ack and (class~="unsupported-known" or device_support_ack)
            rows[#rows+1]=button(L("Continue","继续"),function()
                local plan={{kind="ACK_DEVICE_RISK",arg=class}}
                if class=="unsupported-known" then plan[#plan+1]={kind="ACK_DEVICE_SUPPORT",arg=env.portmaster_target} end
                plan[#plan+1]={kind="INSTALL_PORTMASTER",arg="stable"}
                confirm_environment_repair(plan)
            end,{id="risk:continue",disabled=not ready})
            rows[#rows+1]=button(L("Back","返回"),function() self.build_manage(); kit.goto_page(page.MANAGE) end,{id="risk:back"})
            kit.set_page(page.MANAGE,L("Confirm device","确认设备"),rows,
                {preserve_focus=preserve,sidebar={},row_layout={mode="flow",max_columns=1,min_width=420}})
        end
        build_gate(false); kit.goto_page(page.MANAGE)
    end

    function self.start_update_check()
        if system_managed() then
            kit.toast(L("PortMaster updates are managed by the system.","PortMaster 更新由系统管理。"),{kind="info"}); return
        end
        if not can_update() then
            kit.toast(L("This device does not support PortMaster updates here.",
                "当前设备暂不支持更新 PortMaster。"),{kind="info"}); return
        end
        env.update_status="checking"; env.portmaster_latest=""
        kit.toast(L("Checking for updates…","正在检查更新……"),{kind="info"})
        local ok,task_id=pcall(model.native.start,"update-check",{})
        if not ok then
            env.update_status="error"
            kit.toast(L("Cannot check right now. Try again later.","暂时无法检查，请稍后再试。"),{kind="error"}); return
        end
        operations.task={id=task_id,kind="update-check",elapsed=0,poll=0,timeout=35}
    end

    function self.build_manage(preserve)
        local state=model.update_state()
        local managed=system_managed()
        local latest=managed and L("Managed by system","由系统管理") or
            (env.portmaster_latest and env.portmaster_latest~="" and env.portmaster_latest or L("Not checked","尚未检查"))
        local primary_label,primary_disabled
        if env.portmaster_health=="missing" then primary_label=L("Install PortMaster","安装 PortMaster")
        elseif env.portmaster_health~="healthy" then primary_label=L("Repair PortMaster","修复 PortMaster")
        elseif state=="update" then primary_label=L("Update now","立即更新")
        elseif state=="current" then primary_label=L("Up to date","已是最新版"); primary_disabled=true
        else primary_label=L("Reinstall","重新安装") end
        local rows={
            kit.section(L("PortMaster environment","PortMaster 环境"),{font_px=22}),
            kit.textview(L("Current version","当前版本"),model.provided(env.portmaster_version),{id="manage:current",label_px=18,value_px=20}),
            kit.textview(managed and L("PortMaster updates","PortMaster 更新") or L("Latest stable","最新稳定版"),latest,
                {id="manage:latest",label_px=18,value_px=20}),
            kit.textview(L("Status","状态"),health_label(),{id="manage:health",label_px=18,value_px=20,expandable=false}),
            kit.textview(L("PortMaster path","PortMaster 路径"),model.provided(env.portmaster_target or env.controlfolder),{id="manage:path",label_px=18,value_px=20}),
            kit.textview(L("SH directory","SH 目录"),model.provided(env.scripts_dir),{id="manage:sh-dir",label_px=18,value_px=20}),
            kit.textview(L("Data directory","Data 目录"),model.provided(env.gamedirs_dir),{id="manage:data-dir",label_px=18,value_px=20}),
        }
        if managed then
            rows[#rows+1]=note(L("Maintenance","维护方式"),
                L("PortMaster is maintained by the system. Runtime repair and game management are still available here.",
                    "PortMaster 由系统维护。这里仍可修复 Runtime 和管理游戏。"),"manage:system")
        end
        local actions={}
        if not managed and can_update() then
            actions[#actions+1]=button(L("Check for updates","检查更新"),self.start_update_check,{id="manage:check"})
        end
        if not managed and can_install() then
            actions[#actions+1]=button(primary_label,self.repair_environment,{id="manage:update",disabled=primary_disabled})
        end
        if not managed and can_install() and state=="current" and env.portmaster_health=="healthy" then
            actions[#actions+1]=button(L("Reinstall current stable","重装当前稳定版"),self.repair_environment,{id="manage:reinstall"})
        end
        if enabled("capability_repair_runtimes") then
            actions[#actions+1]=button(function()
                local count=model.runtime_issue_count()
                return kit.get_state().ui_lang=="zh" and string.format("Runtime 修复 (%d)",count) or string.format("Runtime repair (%d)",count)
            end,function() pages_ui.build_runtime(); kit.push_page(page.RUNTIME) end,{id="manage:runtimes"})
        end
        actions[#actions+1]=button(L("Environment details","环境详情"),function() pages_ui.build_env(); kit.push_page(page.ENV) end,{id="manage:details"})
        kit.set_page(page.MANAGE,L("Environment Management","环境管理"),rows,
            {preserve_focus=preserve,sidebar_title=L("Maintenance","维护"),sidebar=actions,row_layout={mode="grid",columns=2}})
    end

    function self.build_repair_gate()
        local damaged=env.portmaster_health=="damaged"
        local page_title=damaged and L("Repair PortMaster","修复 PortMaster") or
            L("PortMaster required","需要安装 PortMaster")
        local rows={
            note(L("Status","状态"),damaged and
                L("PortMaster needs repair. Repair it to continue.","PortMaster 需要修复，请先处理。") or
                L("PortMaster is not installed. Install it to continue.","未安装 PortMaster，请先安装。"),"repair:note"),
        }
        if can_install() then rows[#rows+1]=button(L("Repair PortMaster","修复 PortMaster"),self.repair_environment,{id="repair:open"})
        else rows[#rows+1]=note(L("Install","安装"),L(
            "PortMaster installation is not available on this device.",
            "当前设备暂不支持安装 PortMaster。"),"repair:unavailable") end
        rows[#rows+1]=button(L("Exit","退出"),operations.show_exit_dialog,{id="repair:exit"})
        kit.set_page(page.HOME,page_title,rows,{sidebar={},row_layout={mode="flow",max_columns=1,min_width=420}})
    end

    function self.validation_result(result)
        if type(result)~="table" then return nil,nil end
        return result.status,nil
    end

    function self.start_pending_validation()
        kit.set_page(page.HOME,L("Checking PortMaster","检查 PortMaster"),{
            note(L("Please wait","请稍候"),
                L("Checking PortMaster. App Manager will continue automatically.",
                    "正在检查 PortMaster，完成后会自动继续。"),"validation:running"),
        },{sidebar={},row_layout={mode="flow",max_columns=1,min_width=420}})
        kit.set_busy(true,L("Checking PortMaster…","正在检查 PortMaster……"),{
            indeterminate=true,progress=0,
            stage=L("Checking PortMaster","正在检查 PortMaster"),
            detail="",footer_left="",footer_right=L("Please wait…","请稍候……"),
        })
        local ok,task_id=pcall(model.native.start,"validate-pending",{})
        if not ok then
            self.finish_validation("interrupted"); return
        end
        operations.task={id=task_id,kind="validation",elapsed=0,poll=0,timeout=120}
    end

    function self.finish_validation(status,detail)
        kit.set_busy(false); operations.task=nil
        model.load_env(); model.invalidate_all()
        if status=="valid" then
            pages_ui.reset_selection(); pages_ui.build_home(); kit.goto_page(page.HOME)
            kit.toast(L("PortMaster check completed.","PortMaster 检查完成。"),{kind="success"})
        elseif status=="restored" then
            local message=L("The previous PortMaster version has been restored. Please exit App Manager.",
                "已恢复原来的 PortMaster。请退出 APP。")
            kit.set_page(page.HOME,L("Previous PortMaster restored","已恢复原来的 PortMaster"),{
                note(L("Status","状态"),message,"validation:restored"),
                button(L("Exit","退出"),operations.show_exit_dialog,{id="validation:exit"}),
            },{sidebar={},row_layout={mode="flow",max_columns=1,min_width=420}})
            kit.goto_page(page.HOME)
            kit.dialog({title=L("Previous PortMaster restored","已恢复原来的 PortMaster"),
                message=message,confirm=L("Exit now","立即退出"),cancel=L("Stay","暂不退出"),
                default_focus="cancel",danger=false,on_confirm=kit.quit})
        elseif status=="no-usable" then
            local message=L("Installation did not finish. Exit App Manager, reopen it, and try again.",
                "安装未完成。请退出 APP，重新打开后再试。")
            kit.set_page(page.HOME,L("PortMaster installation failed","PortMaster 安装失败"),{
                note(L("Status","状态"),message,"validation:no-usable"),
                button(L("Exit","退出"),operations.show_exit_dialog,{id="validation:exit"}),
            },{sidebar={},row_layout={mode="flow",max_columns=1,min_width=420}})
            kit.goto_page(page.HOME)
            kit.dialog({title=L("PortMaster installation failed","PortMaster 安装失败"),
                message=message,confirm=L("Exit now","立即退出"),cancel=L("Stay","暂不退出"),
                default_focus="cancel",danger=false,on_confirm=kit.quit})
        elseif status=="timeout" then
            kit.set_page(page.HOME,L("PortMaster check is still running","PortMaster 仍在检查"),{
                note(L("Status","状态"),detail or L(
                    "The check is not finished. Keep waiting or reopen App Manager later.",
                    "检查尚未完成。可以继续等待，或稍后重新打开 APP。"),"validation:timeout"),
                button(L("Keep waiting","继续等待"),self.start_pending_validation,{id="validation:wait"}),
                button(L("Exit","退出"),operations.show_exit_dialog,{id="validation:exit"}),
            },{sidebar={},row_layout={mode="flow",max_columns=1,min_width=420}})
            kit.goto_page(page.HOME)
        else
            kit.set_page(page.HOME,L("PortMaster check was interrupted","PortMaster 检查已中断"),{
                note(L("Status","状态"),L(
                    "The check stopped. Try again, or reopen App Manager.",
                    "检查已停止。请重试，或重新打开 APP。"),"validation:interrupted"),
                button(L("Retry","重试"),self.start_pending_validation,{id="validation:retry"}),
                button(L("Exit","退出"),operations.show_exit_dialog,{id="validation:exit"}),
            },{sidebar={},row_layout={mode="flow",max_columns=1,min_width=420}})
            kit.goto_page(page.HOME)
        end
    end

    function self.start_active_repair_wait()
        kit.set_page(page.HOME,L("Installing PortMaster","正在安装 PortMaster"),{
            note(L("Please wait","请稍候"),
                L("Installation is still running. App Manager will continue automatically.",
                    "安装仍在进行，完成后会自动继续。"),"install:running"),
        },{sidebar={},row_layout={mode="flow",max_columns=1,min_width=420}})
        kit.set_busy(true,L("Installing PortMaster…","正在安装 PortMaster……"),{
            indeterminate=true,progress=0,
            stage=L("Installing PortMaster","正在安装 PortMaster"),
            detail="",footer_left="",footer_right=L("Please wait…","请稍候……"),
        })
        operations.task={kind="active-repair",elapsed=0,poll=0,timeout=1800}
    end

    function self.start_active_operation_wait()
        kit.set_page(page.HOME,L("Finishing operation","正在完成操作"),{
            note(L("Please wait","请稍候"),
                L("The previous operation is still running. App Manager will continue automatically.",
                    "上一次操作仍在进行，完成后会自动继续。"),"operation:running"),
        },{sidebar={},row_layout={mode="flow",max_columns=1,min_width=420}})
        kit.set_busy(true,L("Finishing operation…","正在完成操作……"),{
            indeterminate=true,progress=0,
            stage=L("Processing files","正在处理文件"),
            detail="",footer_left="",footer_right=L("Please wait…","请稍候……"),
        })
        operations.task={kind="active-operation",elapsed=0,poll=0,timeout=1800}
    end

    return self
end

return Environment
