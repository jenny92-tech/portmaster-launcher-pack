local Environment = {}

function Environment.new(model,operations,pages_ui)
    local kit,L=model.kit,model.L
    local env,page=model.env,model.pages
    local self={}
    local device_risk_ack,device_support_ack=false,false
    local function button(label,action,opts) return kit.button(label,action,opts) end

    local function health_label()
        if env.portmaster_health=="healthy" then return L("Healthy","正常") end
        if env.portmaster_health=="damaged" then return L("Damaged","已损坏") end
        return L("Not installed","未安装")
    end

    local function confirm_environment_repair(plan)
        local healthy=env.portmaster_health=="healthy"
        local state=model.update_state()
        local message
        if healthy and state=="update" then
            message=L("PortMaster will be updated from "..tostring(env.portmaster_version or "?").." to "..tostring(env.portmaster_latest or "?")..". Shared Runtimes and personal settings are not changed.",
                "将把 PortMaster 从 "..tostring(env.portmaster_version or "?").." 更新到 "..tostring(env.portmaster_latest or "?").."。共享 Runtime 和个人设置不会改变。")
        elseif healthy then
            message=L("This reinstalls the current PortMaster release. A newer or modified local version may be replaced. Shared Runtimes and personal settings are not changed.",
                "这会重新安装当前 PortMaster。本地较新或修改过的版本可能被替换；共享 Runtime 和个人设置不会改变。")
        else
            message=L("App Manager will download, check and install PortMaster. Shared Runtimes and personal settings are not changed.",
                "APP Manager 将下载、校验并安装 PortMaster。共享 Runtime 和个人设置不会改变。")
        end
        kit.dialog({
            title=healthy and L("Update or reinstall PortMaster","更新或重装 PortMaster") or L("Install PortMaster","安装 PortMaster"),
            message=message,confirm=L("Continue","继续"),cancel=L("Cancel","取消"),danger=false,
            on_confirm=function()
                operations.start_plan(plan or {{kind="INSTALL_PORTMASTER",arg="stable"}},page.MANAGE)
            end,
        })
    end

    function self.repair_environment()
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
                kit.info(L("Device confirmation required","需要确认设备风险"),
                    class=="official-untested" and
                        L("This device is supported by PortMaster but has not been tested with this App Manager flow.",
                            "此设备受 PortMaster 官方支持，但尚未实测本 APP 的环境修改流程。") or
                        L("This device is not in the maintained official model list. Confirm both warnings before continuing.",
                            "此设备不在当前维护的官方机型列表中。继续前需分别确认两项风险。")),
                kit.checkbox(L("I understand this will modify the PortMaster environment","我已了解此操作会修改 PortMaster 环境"),{
                    id="risk:modify",checked=device_risk_ack,on_change=function(value) device_risk_ack=value; build_gate(true) end}),
            }
            if class=="unsupported-known" then
                rows[#rows+1]=kit.checkbox(L("I confirm the unsupported device and proposed path","我确认该机型未获官方支持，并确认建议路径"),{
                    id="risk:support",detail=env.portmaster_target,checked=device_support_ack,
                    on_change=function(value) device_support_ack=value; build_gate(true) end})
            end
            local ready=device_risk_ack and (class~="unsupported-known" or device_support_ack)
            rows[#rows+1]=button(L("Continue to repair","继续修复"),function()
                local plan={{kind="ACK_DEVICE_RISK",arg=class}}
                if class=="unsupported-known" then plan[#plan+1]={kind="ACK_DEVICE_SUPPORT",arg=env.portmaster_target} end
                plan[#plan+1]={kind="INSTALL_PORTMASTER",arg="stable"}
                confirm_environment_repair(plan)
            end,{id="risk:continue",disabled=not ready})
            rows[#rows+1]=button(L("Back","返回"),function() self.build_manage(); kit.goto_page(page.MANAGE) end,{id="risk:back"})
            kit.set_page(page.MANAGE,L("Confirm device risk","确认设备风险"),rows,
                {preserve_focus=preserve,row_layout={mode="flow",max_columns=1,min_width=420}})
        end
        build_gate(false); kit.goto_page(page.MANAGE)
    end

    function self.start_update_check()
        if not env.apply_script or env.apply_script=="" then
            kit.toast(L("Update helper is unavailable.","更新助手不可用。"),{kind="error"}); return
        end
        if env.update_cache_file then os.remove(env.update_cache_file) end
        env.update_status="checking"; env.portmaster_latest=""
        kit.toast(L("Checking this project's stable release…","正在检查本项目的稳定版……"),{kind="info"})
        os.execute(model.shquote(env.apply_script).." --check-pm-update-force >/dev/null 2>&1 &")
        operations.task={kind="update-check",elapsed=0,poll=0,timeout=35}
    end

    function self.build_manage(preserve)
        local state=model.update_state()
        local latest=env.portmaster_latest and env.portmaster_latest~="" and env.portmaster_latest or L("Check required","需要检查")
        local primary_label,primary_disabled
        if env.portmaster_health~="healthy" then primary_label=L("Install or repair PortMaster","安装或修复 PortMaster")
        elseif state=="update" then primary_label=L("Update now","立即更新")
        elseif state=="current" then primary_label=L("Up to date","已是最新版"); primary_disabled=true
        else primary_label=L("Reinstall","重新安装") end
        local rows={
            kit.section(L("PortMaster environment","PortMaster 环境"),{font_px=22}),
            kit.textview(L("Current version","当前版本"),model.provided(env.portmaster_version),{id="manage:current",label_px=18,value_px=20}),
            kit.textview(L("Latest stable","最新稳定版"),latest,{id="manage:latest",label_px=18,value_px=20}),
            kit.textview(L("Status","状态"),health_label(),{id="manage:health",label_px=18,value_px=20,expandable=false}),
            kit.textview(L("Device","设备"),model.provided(env.device_name or env.param_device),{id="manage:device",label_px=18,value_px=20}),
            kit.textview(L("PortMaster path","PortMaster 路径"),model.provided(env.portmaster_target or env.controlfolder),{id="manage:path",label_px=18,value_px=20}),
        }
        local actions={
            button(L("Check for updates","检查更新"),self.start_update_check,{id="manage:check"}),
            button(primary_label,self.repair_environment,{id="manage:update",disabled=primary_disabled}),
        }
        if state=="current" and env.portmaster_health=="healthy" then
            actions[#actions+1]=button(L("Reinstall current stable","重装当前稳定版"),self.repair_environment,{id="manage:reinstall"})
        end
        actions[#actions+1]=button(function()
            local count=model.runtime_issue_count()
            return kit.get_state().ui_lang=="zh" and string.format("Runtime 修复 (%d)",count) or string.format("Runtime repair (%d)",count)
        end,function() pages_ui.build_runtime(); kit.goto_page(page.RUNTIME) end,{id="manage:runtimes"})
        actions[#actions+1]=button(L("Environment details","环境详情"),function() pages_ui.build_env(); kit.goto_page(page.ENV) end,{id="manage:details"})
        kit.set_page(page.MANAGE,L("Environment Management","环境管理"),rows,
            {preserve_focus=preserve,sidebar_title=L("Maintenance","维护"),sidebar=actions,row_layout={mode="grid",columns=2}})
    end

    function self.build_repair_gate()
        local rows={
            kit.info(env.portmaster_health=="damaged" and L("PortMaster is damaged","PortMaster 环境已损坏") or L("PortMaster is not installed","尚未安装 PortMaster"),
                L("Port App Manager can still run because it carries its own UI environment. Repair PortMaster before managing ports.",
                    "Port App Manager 使用自带 UI 环境，因此仍可运行。请先修复 PortMaster，再管理游戏端口。")),
            button(L("Install or repair PortMaster","安装或修复 PortMaster"),function() self.build_manage(); kit.goto_page(page.MANAGE) end,{id="repair:open"}),
            button(L("Exit","退出"),operations.show_exit_dialog,{id="repair:exit"}),
        }
        kit.set_page(page.HOME,L("PortMaster required","需要安装 PortMaster"),rows,{row_layout={mode="flow",max_columns=1,min_width=420}})
    end

    function self.validation_result()
        local text=model.read_all(env.validation_result_file or "")
        if not text then return nil,nil end
        local status,detail=text:match("^1\t([^\t\r\n]+)\t([^\r\n]*)")
        return status,detail
    end

    function self.start_pending_validation()
        if not env.apply_script or env.apply_script=="" then
            kit.set_page(page.HOME,L("Environment validation","环境校验"),{
                kit.info(L("Validation cannot start","无法开始校验"),
                    L("The validation helper is unavailable. Exit without modifying the pending installation.",
                        "校验助手不可用。请退出；待校验安装不会被修改。")),
                button(L("Exit","退出"),kit.quit,{id="validation:exit"}),
            },{row_layout={mode="flow",max_columns=1,min_width=420}})
            return
        end
        if env.validation_result_file then os.remove(env.validation_result_file) end
        kit.set_page(page.HOME,L("Validating environment","正在校验环境"),{
            kit.info(L("Checking PortMaster","正在检查 PortMaster"),
                L("App Manager is checking files, version information, device detection and startup commands. Shared Runtimes are not checked here.",
                    "APP Manager 正在检查文件、版本信息、设备识别和启动命令；这里不会检查共享 Runtime。")),
        },{row_layout={mode="flow",max_columns=1,min_width=420}})
        kit.set_busy(true,L("Checking PortMaster…","正在检查 PortMaster…"),{
            progress=0.35,stage=L("Checking the new environment","正在检查新环境"),
            detail=L("Home remains locked until validation finishes.","校验完成前不能进入首页。"),
            footer_left=L("Automatic validation","自动校验"),footer_right="—",cancel_disabled=true})
        os.execute(model.shquote(env.apply_script).." --validate-pending >/dev/null 2>&1 &")
        operations.task={kind="validation",elapsed=0,poll=0,timeout=120}
    end

    function self.finish_validation(status,detail)
        kit.set_busy(false); operations.task=nil
        model.load_env()
        if status=="valid" then
            model.refresh_scan(); pages_ui.reset_selection(); pages_ui.build_home(); kit.goto_page(page.HOME)
            kit.toast(L("PortMaster environment validated.","PortMaster 环境校验完成。"),{kind="success"})
        elseif status=="restored" then
            kit.dialog({title=L("Original environment restored","已恢复原来的环境"),
                message=L("The new PortMaster installation did not pass the check. The previous version has been restored. Please exit App Manager.",
                    "新安装的 PortMaster 未通过检查，已经恢复原来的版本。请退出 APP。"),
                confirm=L("Exit","退出"),cancel=L("Exit now","立即退出"),default_focus="confirm",danger=false,
                on_confirm=kit.quit,on_cancel=kit.quit})
        elseif status=="no-usable" then
            kit.dialog({title=L("No usable environment remains","当前没有可用环境"),
                message=L("The incomplete installation was removed. Exit and reopen App Manager to install PortMaster again.",
                    "未完成的安装已经清理。请退出并重新打开 APP，再次安装 PortMaster。"),
                confirm=L("Exit","退出"),cancel=L("Exit now","立即退出"),default_focus="confirm",danger=false,
                on_confirm=kit.quit,on_cancel=kit.quit})
        elseif status=="timeout" then
            kit.dialog({title=L("Validation is still running","环境校验仍在进行"),message=model.provided(detail),
                confirm=L("Exit","退出"),cancel=L("Exit now","立即退出"),default_focus="confirm",danger=false,
                on_confirm=kit.quit,on_cancel=kit.quit})
        else
            kit.dialog({title=L("Validation was interrupted","校验已中断"),message=model.provided(detail),
                confirm=L("Retry","重试"),cancel=L("Exit","退出"),default_focus="confirm",danger=false,
                on_confirm=self.start_pending_validation,on_cancel=kit.quit})
        end
    end

    function self.start_active_repair_wait()
        kit.set_page(page.HOME,L("Installing PortMaster","正在安装 PortMaster"),{
            kit.info(L("PortMaster installation is already running","PortMaster 正在安装"),
                L("An earlier App Manager instance is still installing PortMaster. Home remains locked until it finishes.",
                    "之前打开的 APP Manager 仍在安装 PortMaster。安装完成前不能进入首页。")),
        },{row_layout={mode="flow",max_columns=1,min_width=420}})
        kit.set_busy(true,L("Installing PortMaster…","正在安装 PortMaster…"),{
            progress=0,stage=L("Waiting for installation","正在等待安装完成"),detail="",
            footer_left=L("Background operation","后台操作"),footer_right="—",cancel_disabled=true})
        operations.task={kind="active-repair",elapsed=0,poll=0,timeout=1800}
    end

    return self
end

return Environment
