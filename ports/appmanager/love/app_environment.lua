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
            if env.portmaster_health=="damaged" then return L("Managed by system · Needs system repair","系统管理 · 需要系统修复") end
            return L("Managed by system · Core not detected","系统管理 · 暂未检测到核心")
        end
        if env.portmaster_health=="healthy" then return L("Healthy","正常") end
        if env.portmaster_health=="damaged" then return L("Damaged","已损坏") end
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
                message=L("PortMaster is integrated and maintained by this system. Port App Manager will not install, reinstall, or replace it. If PortMaster cannot start, use the system update or recovery tools.",
                    "PortMaster 已集成到当前系统，并由系统负责维护。Port App Manager 不会安装、重装或覆盖它；如果无法启动，请使用系统更新或恢复功能。"),
                confirm=L("OK","知道了"),cancel=L("Back","返回"),danger=false})
            return
        end
        if not can_install() then
            kit.toast(L("PortMaster installation is disabled for this device profile.",
                "当前设备配置未启用 PortMaster 安装。"),{kind="info"})
            return
        end
        local class=tostring(env.device_class or "unknown-path")
        if class=="tested" then confirm_environment_repair(); return end
        if env.target_confirmed~="1" or not env.portmaster_target or env.portmaster_target=="" or class=="unknown-path" then
            kit.dialog({title=L("Installation path unavailable","无法确定安装路径"),
                message=L("App Manager cannot safely determine the PortMaster target on this device. No files will be changed.",
                    "APP Manager 无法安全确定此设备的 PortMaster 安装路径，因此不会修改任何文件。"),
                confirm=L("Back","返回"),cancel=L("Cancel","取消"),danger=false})
            return
        end
        device_risk_ack,device_support_ack=false,false
        local function build_gate(preserve)
            local rows={
                note(L("Before continuing","继续前确认"),
                    class=="official-untested" and
                        L("This device has not been tested with Port App Manager. Confirm the risk before continuing.",
                            "此设备尚未经过 Port App Manager 实测，请确认风险后继续。") or
                        L("PortMaster does not officially support this device. Confirm the device and install path before continuing.",
                            "PortMaster 尚未正式支持此机型，请确认机型和安装路径后继续。"),"risk:note"),
                kit.checkbox(L("I understand this will modify the PortMaster environment","我已了解此操作会修改 PortMaster 环境"),{
                    id="risk:modify",checked=device_risk_ack,on_change=function(value) device_risk_ack=value; build_gate(true) end}),
            }
            if class=="unsupported-known" then
                rows[#rows+1]=kit.checkbox(L("I confirm the unsupported device and proposed path","我确认该机型未获官方支持，并确认建议路径"),{
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
            kit.toast(L("PortMaster updates are disabled for this device profile.",
                "当前设备配置未启用 PortMaster 更新。"),{kind="info"}); return
        end
        env.update_status="checking"; env.portmaster_latest=""
        kit.toast(L("Checking for updates…","正在检查更新……"),{kind="info"})
        local ok,task_id=pcall(model.native.start,"update-check",{})
        if not ok then
            env.update_status="error"
            kit.toast(L("Cannot check for updates.","无法检查更新。"),{kind="error"}); return
        end
        operations.task={id=task_id,kind="update-check",elapsed=0,poll=0,timeout=35}
    end

    function self.build_manage(preserve)
        local state=model.update_state()
        local managed=system_managed()
        local latest=managed and L("Managed by system","由系统管理") or
            (env.portmaster_latest and env.portmaster_latest~="" and env.portmaster_latest or L("Check required","需要检查"))
        local primary_label,primary_disabled
        if env.portmaster_health=="missing" then primary_label=L("Install PortMaster","安装 PortMaster")
        elseif env.portmaster_health~="healthy" then primary_label=L("Repair PortMaster","修复 PortMaster")
        elseif state=="update" then primary_label=L("Update now","立即更新")
        elseif state=="current" then primary_label=L("Up to date","已是最新版"); primary_disabled=true
        else primary_label=L("Reinstall","重新安装") end
        local rows={
            kit.section(L("PortMaster environment","PortMaster 环境"),{font_px=22}),
            kit.textview(L("Current version","当前版本"),model.provided(env.portmaster_version),{id="manage:current",label_px=18,value_px=20}),
            kit.textview(managed and L("Core updates","核心更新") or L("Latest stable","最新稳定版"),latest,
                {id="manage:latest",label_px=18,value_px=20}),
            kit.textview(L("Status","状态"),health_label(),{id="manage:health",label_px=18,value_px=20,expandable=false}),
            kit.textview(L("Device","设备"),model.provided(env.device_name or env.param_device),{id="manage:device",label_px=18,value_px=20}),
            kit.textview(L("Manufacturer","设备厂商"),model.provided(env.device_manufacturer),{id="manage:manufacturer",label_px=18,value_px=20}),
            kit.textview(L("Submodel","具体型号"),model.provided(env.device_submodel),{id="manage:submodel",label_px=18,value_px=20}),
            kit.textview(L("System","系统"),model.provided(env.system_name),{id="manage:system-name",label_px=18,value_px=20}),
            kit.textview(L("System version","系统版本"),model.provided(env.system_version),{id="manage:system-version",label_px=18,value_px=20}),
            kit.textview(L("PortMaster path","PortMaster 路径"),model.provided(env.portmaster_target or env.controlfolder),{id="manage:path",label_px=18,value_px=20}),
        }
        if managed then
            rows[#rows+1]=note(L("Maintenance","维护方式"),
                L("PortMaster is integrated with this system. Installation and core updates stay under system control; Runtime repair and Port game management remain available.",
                    "PortMaster 已集成到当前系统。安装和核心更新继续由系统负责，Runtime 修复与 Port 游戏管理仍可正常使用。"),"manage:system")
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
                L("PortMaster is damaged. Repair it first.","PortMaster 已损坏，请先修复。") or
                L("PortMaster is not installed. Repair it first.","未安装 PortMaster，请先修复。"),"repair:note"),
        }
        if can_install() then rows[#rows+1]=button(L("Repair PortMaster","修复 PortMaster"),self.repair_environment,{id="repair:open"})
        else rows[#rows+1]=note(L("Availability","可用性"),L(
            "This device profile does not allow PortMaster installation. Use the system maintenance tools or update the device configuration.",
            "当前设备配置不允许安装 PortMaster。请使用系统维护工具，或更新设备配置。"),"repair:unavailable") end
        rows[#rows+1]=button(L("Exit","退出"),operations.show_exit_dialog,{id="repair:exit"})
        kit.set_page(page.HOME,page_title,rows,{sidebar={},row_layout={mode="flow",max_columns=1,min_width=420}})
    end

    function self.validation_result(result)
        if type(result)~="table" then return nil,nil end
        return result.status,result.detail
    end

    function self.start_pending_validation()
        kit.set_page(page.HOME,L("Checking PortMaster","检查 PortMaster"),{
            note(L("Please wait","请稍候"),
                L("Checking the installed PortMaster. Home will open automatically when it finishes.",
                    "正在检查刚安装的 PortMaster。完成后会自动进入首页。"),"validation:running"),
        },{sidebar={},row_layout={mode="flow",max_columns=1,min_width=420}})
        kit.set_busy(true,L("Checking PortMaster…","正在检查 PortMaster……"),{
            indeterminate=true,progress=0,
            stage=L("Checking installed files","正在检查已安装文件"),
            detail=L("Please wait. App Manager will continue automatically.","请稍候，检查完成后会自动继续。"),
            footer_left=L("Automatic check","自动检查"),footer_right=L("Please wait…","请稍候……"),
        })
        local ok,task_id=pcall(model.native.start,"validate-pending",{})
        if not ok then
            self.finish_validation("interrupted",L("Cannot start the PortMaster check. Reopen App Manager and try again.",
                "无法开始检查 PortMaster，请重新打开 APP 后重试。")); return
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
            local message=L("The new installation could not be used, so the previous version was restored. You may now exit App Manager.",
                "新安装无法使用，已恢复原来的版本。现在可以退出 APP。")
            kit.set_page(page.HOME,L("Previous PortMaster restored","已恢复原来的 PortMaster"),{
                note(L("Status","状态"),message,"validation:restored"),
                button(L("Exit","退出"),operations.show_exit_dialog,{id="validation:exit"}),
            },{sidebar={},row_layout={mode="flow",max_columns=1,min_width=420}})
            kit.goto_page(page.HOME)
            kit.dialog({title=L("Previous PortMaster restored","已恢复原来的 PortMaster"),
                message=message,confirm=L("Exit now","立即退出"),cancel=L("Stay","暂不退出"),
                default_focus="cancel",danger=false,on_confirm=kit.quit})
        elseif status=="no-usable" then
            local message=L("The unusable installation was removed. Exit and reopen App Manager before trying again.",
                "无法使用的安装已清理。再次尝试前，请退出并重新打开 APP。")
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
                note(L("What to do","请执行"),model.provided(detail),"validation:timeout"),
                button(L("Keep waiting","继续等待"),self.start_pending_validation,{id="validation:wait"}),
                button(L("Exit","退出"),operations.show_exit_dialog,{id="validation:exit"}),
            },{sidebar={},row_layout={mode="flow",max_columns=1,min_width=420}})
            kit.goto_page(page.HOME)
        else
            kit.set_page(page.HOME,L("PortMaster check was interrupted","PortMaster 检查已中断"),{
                note(L("Status","状态"),model.provided(detail),"validation:interrupted"),
                button(L("Retry","重试"),self.start_pending_validation,{id="validation:retry"}),
                button(L("Exit","退出"),operations.show_exit_dialog,{id="validation:exit"}),
            },{sidebar={},row_layout={mode="flow",max_columns=1,min_width=420}})
            kit.goto_page(page.HOME)
        end
    end

    function self.start_active_repair_wait()
        kit.set_page(page.HOME,L("Installing PortMaster","正在安装 PortMaster"),{
            note(L("Please wait","请稍候"),
                L("PortMaster is still installing. Home will open automatically when it finishes.",
                    "PortMaster 仍在安装。完成后会自动进入首页。"),"install:running"),
        },{sidebar={},row_layout={mode="flow",max_columns=1,min_width=420}})
        kit.set_busy(true,L("Installing PortMaster…","正在安装 PortMaster……"),{
            indeterminate=true,progress=0,
            stage=L("Waiting for installation","正在等待安装完成"),
            detail=L("App Manager will continue automatically.","安装完成后会自动继续。"),
            footer_left=L("Installation in progress","正在安装"),footer_right=L("Please wait…","请稍候……"),
        })
        operations.task={kind="active-repair",elapsed=0,poll=0,timeout=1800}
    end

    function self.start_active_operation_wait()
        kit.set_page(page.HOME,L("Finishing the previous operation","正在完成上一次操作"),{
            note(L("Please wait","请稍候"),
                L("App Manager is still updating files. Home will open automatically when it finishes.",
                    "APP 仍在处理文件，完成后会自动进入首页。"),"operation:running"),
        },{sidebar={},row_layout={mode="flow",max_columns=1,min_width=420}})
        kit.set_busy(true,L("Finishing operation…","正在完成操作……"),{
            indeterminate=true,progress=0,
            stage=L("Updating files safely","正在安全更新文件"),
            detail=L("Do not start another operation.","请勿重复执行操作。"),
            footer_left=L("Operation in progress","正在处理"),footer_right=L("Please wait…","请稍候……"),
        })
        operations.task={kind="active-operation",elapsed=0,poll=0,timeout=1800}
    end

    return self
end

return Environment
