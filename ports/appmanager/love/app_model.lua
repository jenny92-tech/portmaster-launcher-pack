local Model = {}

local function clear(values)
    for key in pairs(values) do values[key]=nil end
end

local function replace(target,source)
    clear(target)
    for key,value in pairs(source or {}) do target[key]=value end
end

function Model.new(kit,native)
    local self={
        kit=kit,native=native,
        env={},report={},runtime_metadata={},missing_by_script={},native_inventory=nil,
        cache={},report_version=0,
        pages={HOME=1,JUNK=2,TRASH=3,ENV=4,RUNTIME=5,MANAGE=6,ZIP=7,GAMES=8,LAUNCHER=9},
    }

    local function cached(key,token,loader,force)
        local entry=self.cache[key]
        if force or not entry or entry.token~=token then
            entry={token=token,valid=false,loading=false,waiters={}}
            self.cache[key]=entry
        end
        if entry.valid then return entry.value end
        if entry.loading then return entry.value end -- synchronous callers wait in the LÖVE event queue
        entry.loading=true
        local ok,value=pcall(loader)
        entry.loading=false
        if not ok then
            entry.error=tostring(value)
            return nil,entry.error
        end
        entry.value=value; entry.valid=true; entry.error=nil
        local waiters=entry.waiters; entry.waiters={}
        for _,waiter in ipairs(waiters) do pcall(waiter,value,nil) end
        return value
    end

    function self.invalidate(...)
        for i=1,select("#",...) do self.cache[select(i,...)]=nil end
    end

    function self.invalidate_all()
        clear(self.cache)
    end

    function self.L(en,zh) return {en=en,zh=zh} end
    function self.join(parts,sep) return table.concat(parts,sep or " · ") end

    -- Support model shared by Environment Management and Environment Details.
    local function enabled(name) return self.env[name]==true end
    function self.system_managed() return self.env.portmaster_management=="system" end
    function self.can_install()
        if self.system_managed() then return false end
        if not enabled("capability_manage_portmaster") or not enabled("capability_install_portmaster") then return false end
        if self.env.portmaster_release_install_allowed==false then return false end
        -- An install needs a place to go. Devices whose PortMaster location is
        -- unknown (unknown-path / unconfirmed) cannot install: hide the entry
        -- instead of letting the user hit a guaranteed-fail dialog.
        if self.env.target_confirmed~="1" or not self.env.portmaster_target or self.env.portmaster_target=="" then
            return false
        end
        return true
    end
    function self.can_update()
        return self.can_install() and enabled("capability_update_portmaster")
    end

    function self.health_label()
        local L=self.L
        if self.system_managed() then
            if self.env.portmaster_health=="healthy" then return L("Managed by system · Available","系统管理 · 当前可用") end
            if self.env.portmaster_health=="damaged" then return L("Managed by system · Needs repair","系统管理 · 需要修复") end
            return L("Managed by system · Not available","系统管理 · 当前不可用")
        end
        if self.env.portmaster_health=="healthy" and self.env.portmaster_python_ok~=false then return L("Healthy","正常") end
        if self.env.portmaster_health=="healthy" then return L("Healthy · Python issue","正常 · Python 问题") end
        if self.env.portmaster_health=="damaged" then return L("Needs repair","需要修复") end
        return L("Not installed","未安装")
    end

    -- Only prompt about a damaged core when the problem is certain: a file the
    -- installer itself requires is missing. Permissions, the pugwash/
    -- harbourmaster launchers (absent from pre-2024 cores) and Python imports
    -- can fail while PortMaster still happens to work, so those stay visible
    -- in the details pages instead of nagging at startup.
    function self.severe_health_issue()
        if self.env.portmaster_health~="damaged" then return false end
        for _,check in ipairs(self.env.portmaster_health_checks or {}) do
            if check.passed==false and tostring(check.kind or "")=="required_file" then
                return true
            end
        end
        return false
    end

    function self.support_label()
        local L=self.L
        local env=self.env
        if self.system_managed() then return L("Managed by system","由系统管理") end
        if env.target_confirmed~="1" or not env.portmaster_target or env.portmaster_target=="" then
            return L("Cannot determine","无法确定")
        end
        if not self.can_install() then return L("Not enabled","配置未启用") end
        local channel=tostring(env.portmaster_release_channel or "")
        local class=tostring(env.device_class or "unknown-path")
        -- A custom release channel (e.g. miniloong-custom) means this device is
        -- supported by our own build, not by the official PortMaster release.
        if channel~="" and channel~="official" and channel~="system" then
            return L("Custom build (Jenny92)","定制版（Jenny92）")
        end
        if class=="tested" then
            if channel=="official" then return L("Officially supported","官方支持") end
            return L("Supported","支持")
        end
        if class=="official-untested" then return L("Not officially tested · can try","官方未实测（可尝试）") end
        if class=="unsupported-known" then return L("Unknown device · needs confirmation","未知设备（需确认）") end
        return L("Unknown","未知")
    end

    function self.support_explanation()
        local L=self.L
        local env=self.env
        if self.system_managed() then return nil end
        if env.target_confirmed~="1" or not env.portmaster_target or env.portmaster_target=="" then
            return L("The PortMaster install location could not be determined, so it cannot be installed.",
                "无法确定 PortMaster 安装位置，暂不能安装。")
        end
        if not self.can_install() then
            return L("PortMaster installation is not supported on this device.",
                "当前设备暂不支持安装 PortMaster。")
        end
        local class=tostring(env.device_class or "unknown-path")
        if class=="tested" then return nil end
        if class=="official-untested" then
            return L("This device has not been tested by the official release yet. You can try installing after confirming the risk.",
                "官方版本尚未实测这台设备。确认风险后可以尝试安装。")
        end
        if class=="unsupported-known" then
            return L("This device is not in the official support list. Install after confirming the location; the app self-checks whether PortMaster works when the install finishes, and an existing PortMaster is checked directly.",
                "这台设备不在官方支持列表中。确认安装位置后可以安装；安装完成会自动检查能否正常使用，已有 PortMaster 会直接检测当前状态。")
        end
        return nil
    end
    function self.apply_snapshot(snapshot)
        if type(snapshot)~="table" or type(snapshot.env)~="table" then
            return false,"APP Manager service returned no environment"
        end
        replace(self.env,snapshot.env)
        self.native_inventory=type(snapshot.inventory)=="table" and snapshot.inventory or nil
        self.inventory_revision=type(snapshot.revision)=="string" and snapshot.revision or ""
        replace(self.runtime_metadata,type(snapshot.runtime_metadata)=="table" and snapshot.runtime_metadata or {})
        self.invalidate_all()
        return true
    end

    function self.apply_update_result(update)
        if type(update)~="table" then return false end
        local status=tostring(update.update_status or "")
        if status~="ok" and status~="error" and status~="unknown" then return false end
        self.env.update_checked=tonumber(update.update_checked) or 0
        self.env.update_status=status
        self.env.portmaster_latest=tostring(update.portmaster_latest or "")
        return true
    end

    function self.apply_zip_bundles(bundles)
        if type(bundles)~="table" then self.zip_bundles={} return true end
        local out={}
        for _,bundle in ipairs(bundles) do
            out[#out+1]={
                path=tostring(bundle.path or ""),
                size=tonumber(bundle.size) or 0,
                source_identity=tostring(bundle.source_identity or ""),
                kind=tostring(bundle.kind or "unknown"),
                entry_script=tostring(bundle.entry_script or ""),
                entry_data=tostring(bundle.entry_data or ""),
                app_name=tostring(bundle.app_name or ""),
                diagnostic=tostring(bundle.diagnostic or ""),
            }
        end
        self.zip_bundles=out
        return true
    end

    function self.load_env()
        local ok,snapshot=pcall(self.native.snapshot)
        if not ok then return false,tostring(snapshot) end
        return self.apply_snapshot(snapshot)
    end

    local function collect_trash_snapshot()
        local native=self.load_native_inventory()
        if native and type(native.trash)=="table" then return native.trash end
        return {}
    end

    local function collect_required_runtimes()
        local out={}
        clear(self.missing_by_script)
        local native=self.load_native_inventory()
        local native_facts={}
        if native and native.runtimes and type(native.runtimes.facts)=="table" then
            for _,fact in ipairs(native.runtimes.facts) do native_facts[fact.name]=fact end
        end
        for name,users in pairs((self.report.runtimes or {}).need or {}) do
            local fact=native_facts[name]
            local health,bytes
            if fact then health,bytes=fact.health,tonumber(fact.bytes) or 0
            else health,bytes="missing",0 end
            local needs_repair=health=="missing" or health=="invalid_magic" or health=="symlink"
            out[#out+1]={name=name,users=users,health=health,bytes=bytes,
                missing=health=="missing",damaged=health=="invalid_magic",
                needs_repair=needs_repair}
            if needs_repair then
                for _,script in ipairs(users or {}) do
                    self.missing_by_script[script]=self.missing_by_script[script] or {}
                    self.missing_by_script[script][#self.missing_by_script[script]+1]=name
                end
            end
        end
        table.sort(out,function(a,b) return a.name<b.name end)
        for _,names in pairs(self.missing_by_script) do table.sort(names) end
        return out
    end

    function self.human(bytes)
        bytes=tonumber(bytes) or 0
        if bytes>=1024^3 then return string.format("%.1f GB",bytes/1024^3) end
        if bytes>=1024^2 then return string.format("%.1f MB",bytes/1024^2) end
        if bytes>=1024 then return string.format("%.1f KB",bytes/1024) end
        return tostring(bytes).." B"
    end

    function self.runtime_progress(data)
        local L=self.L
        local fields={}
        if type(data)=="table" then
            fields={"1",tostring(data.phase or ""),tostring(data.runtime or ""),
                tostring(data.index or 0),tostring(data.count or 0),tostring(data.current or 0),
                tostring(data.total or 0),tostring(data.speed or 0),tostring(data.detail or "")}
        else
            return nil
        end
        if fields[1]~="1" or #fields<9 then return nil end
        local phase,runtime=fields[2],fields[3]
        local index,count=tonumber(fields[4]) or 0,tonumber(fields[5]) or 0
        local current,total,speed=tonumber(fields[6]) or 0,tonumber(fields[7]) or 0,tonumber(fields[8]) or 0
        local portmaster=runtime=="PortMaster"
        local appledouble=runtime=="AppleDouble"
        if appledouble then
            local stages={
                scanning=L("Scanning files","正在扫描文件"),
                cleaning=L("Removing ._Files","正在清理 ._Files"),
                indexing=L("Updating file list","正在更新文件列表"),
                complete=L("Cleanup completed","清理完成"),
            }
            -- Unknown total: show an indeterminate bar, with the live file count in the footer.
            local done=phase=="complete"
            return {progress=done and 1 or 0,indeterminate=not done,
                stage=stages[phase] or L("Cleaning ._Files","正在清理 ._Files"),
                detail="",footer_left=L(string.format("%d files",current),string.format("%d 个文件",current)),
                footer_right=done and L("Done","完成")
                    or phase=="cleaning" and L("Cleaning…","清理中…")
                    or phase=="indexing" and L("Updating…","更新中…")
                    or L("Scanning…","扫描中…"),
                phase=phase}
        end
        local stages=portmaster and {
            preparing=L("Preparing PortMaster","正在准备 PortMaster"),probing=L("Checking network","正在检查网络"),
            connected=L("Network connected","网络连接成功"),downloading=L("Downloading PortMaster","正在下载 PortMaster"),
            verifying=L("Checking downloaded files","正在检查下载文件"),installing=L("Installing PortMaster","正在安装 PortMaster"),
            failed=L("PortMaster installation failed","PortMaster 安装失败"),cancelled=L("Installation cancelled","已取消安装"),
            complete=L("PortMaster installed","PortMaster 已安装"),
        } or {
            preparing=L("Preparing download","正在准备下载"),probing=L("Checking connection","正在检查网络"),
            connected=L("Connection ready","网络连接成功"),downloading=L("Downloading","正在下载"),
            verifying=L("Checking Runtime file","正在检查 Runtime 文件"),installing=L("Installing Runtime","正在安装 Runtime"),
            finished=L("Runtime completed","当前 Runtime 完成"),
            failed=L("Runtime repair failed","Runtime 修复失败"),complete=L("Finishing Runtime repair","正在完成 Runtime 修复"),
        }
        local stage=stages[phase] or L("Working","处理中")
        local name=runtime~="" and runtime or L("Runtime repair","Runtime 修复")
        local left
        if portmaster then
            left=L(string.format("%d%%",total>0 and math.floor(current*100/total) or 0),
                string.format("%d%%",total>0 and math.floor(current*100/total) or 0))
        else
            left=count>0 and L(string.format("Runtime %d/%d · %s / %s",index,count,self.human(current),self.human(total)),
                string.format("Runtime %d/%d · %s / %s",index,count,self.human(current),self.human(total))) or ""
        end
        local right
        if phase=="downloading" then
            if fields[9]=="Using local cache" then right=L("Cached","使用缓存")
            elseif speed>0 then right=L(self.human(speed).."/s",self.human(speed).."/秒")
            else right=L("Downloading…","下载中…") end
        elseif phase=="probing" then right=L("Checking…","检查中…")
        else right="—" end
        local detail=""
        local display_stage=stage
        if not portmaster then
            display_stage=L(stage.en.." · "..(type(name)=="table" and name.en or name),
                stage.zh.." · "..(type(name)=="table" and name.zh or name))
        end
        return {progress=total>0 and math.max(0,math.min(1,current/total)) or 0,
            stage=display_stage,
            detail=detail,footer_left=left,footer_right=right,phase=phase}
    end

    function self.provided(value)
        if type(value)=="table" or type(value)=="function" then return value end
        if value==nil or tostring(value)=="" then return self.L("Unknown","未识别") end
        return tostring(value)
    end

    function self.display_name(name)
        -- Port launchers are user-owned filenames. Prefixes such as `Z_`,
        -- region tags and every other character remain exactly as they appear
        -- on the storage card; only the launcher extension is hidden.
        return (tostring(name or ""):gsub("%.sh$",""))
    end

    -- Localized display name for a standalone app: prefer config.json
    -- label/label.ch.lang (TrimUI convention), falling back to the folder
    -- name. Follows the current UI language live.
    function self.app_label(app)
        local zh = kit.get_state().ui_lang=="zh"
        if zh and app.label_zh and app.label_zh~="" then return app.label_zh end
        if app.label and app.label~="" then return app.label end
        return tostring(app.name or "")
    end

    function self.app_manageable(app)
        local name=tostring(app and app.name or "")
        for _,protected in ipairs(self.env.protected_app_names or {}) do
            if name==protected then return false end
        end
        return true
    end

    function self.selected_count(values)
        local n=0; for _,value in pairs(values) do if value then n=n+1 end end; return n
    end

    function self.dynamic_count(en,zh,values)
        return function()
            local n=self.selected_count(values)
            return kit.get_state().ui_lang=="zh" and string.format(zh,n) or string.format(en,n)
        end
    end

    function self.load_runtime_metadata(force)
        return self.runtime_metadata
    end

    function self.load_native_inventory(force)
        if force then
            local ok,snapshot=pcall(self.native.snapshot)
            if ok and type(snapshot)=="table" then self.apply_snapshot(snapshot) end
        end
        return self.native_inventory
    end

    function self.ensure_report(force)
        if force then self.invalidate("required-runtimes") end
        local token=table.concat({self.env.scripts_dir or "",self.env.gamedirs_dir or "",
            self.env.images_dir or "",tostring(self.env.scan_script_images==true),
            self.env.directory or "",self.env.controlfolder or ""},"\0")
        return cached("ports",token,function()
            local native=self.load_native_inventory(force)
            replace(self.report,native or {ports={},data_refcount={},orphan_dirs={},orphan_images={},dead_scripts={},runtimes={need={},facts={}}})
            self.report_version=self.report_version+1
            return self.report
        end,force)
    end

    function self.trash_items(force)
        local root=(self.env.gamedir or "").."/trash"
        return cached("trash",root,collect_trash_snapshot,force) or {}
    end

    function self.missing_runtime(script)
        self.required_runtimes()
        return table.concat(self.missing_by_script[script] or {},", ")
    end

    function self.required_runtimes(force)
        self.ensure_report()
        local token=(self.env.libs_dir or "").."\0"..tostring(self.report_version)
        return cached("required-runtimes",token,collect_required_runtimes,force) or {}
    end

    function self.runtime_issue_count()
        local count=0
        for _,item in ipairs(self.required_runtimes()) do if item.needs_repair then count=count+1 end end
        return count
    end

    function self.installed_runtimes(force)
        return cached("installed-runtimes",self.env.libs_dir or "",function()
            local native=self.load_native_inventory(force)
            if native and native.runtimes and type(native.runtimes.facts)=="table" then
                local out={}
                for _,fact in ipairs(native.runtimes.facts) do
                    if fact.health~="missing" and fact.health~="symlink" then out[#out+1]=fact.name end
                end
                table.sort(out)
                return out
            end
            return {}
        end,force) or {}
    end

    function self.load_update_cache()
        return self.env.update_status,self.env.portmaster_latest
    end

    local function version_tokens(value)
        local out={}
        for token in tostring(value):gmatch("%d+") do out[#out+1]=tonumber(token) end
        return out
    end
    local function compare_versions(left,right)
        local a,b=version_tokens(left),version_tokens(right)
        if #a==0 or #b==0 then
            return tostring(left)==tostring(right) and 0 or nil
        end
        for i=1,math.max(#a,#b) do
            local x,y=a[i] or 0,b[i] or 0
            if x~=y then return x<y and -1 or 1 end
        end
        return 0
    end

    function self.update_state()
        local current=tostring(self.env.portmaster_version or "")
        local latest=tostring(self.env.portmaster_latest or "")
        if self.env.update_status~="ok" or latest=="" then return "unknown" end
        if current==latest then return "current" end
        -- Numeric-token comparison, tolerant of version format changes by the
        -- official project. Unparseable versions fall back to reinstall rather
        -- than guessing an update.
        local cmp=compare_versions(current,latest)
        if cmp==0 then return "current" end
        if cmp==-1 then return "update" end
        return "reinstall"
    end

    return self
end

return Model
