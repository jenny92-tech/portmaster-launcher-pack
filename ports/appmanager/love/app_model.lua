local Model = {}

local function clear(values)
    for key in pairs(values) do values[key]=nil end
end

local function replace(target,source)
    clear(target)
    for key,value in pairs(source or {}) do target[key]=value end
end

function Model.new(kit,json,native)
    local self={
        kit=kit,json=json,native=native,
        env={},report={},size_map={},runtime_metadata={},missing_by_script={},native_inventory=nil,
        cache={},report_version=0,
        pages={HOME=1,JUNK=2,TRASH=3,ENV=4,RUNTIME=5,MANAGE=6},
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
    function self.file_exists(path)
        local f=path and io.open(path,"rb")
        if f then f:close(); return true end
        return false
    end

    function self.read_all(path)
        local f=path and io.open(path,"rb"); if not f then return nil end
        local text=f:read("*a"); f:close(); return text
    end

    function self.basename(path)
        return tostring(path or ""):gsub("/+$",""):match("([^/]+)$") or tostring(path or "")
    end

    function self.apply_snapshot(snapshot)
        if type(snapshot)~="table" or type(snapshot.env)~="table" then
            return false,"APP Manager service returned no environment"
        end
        replace(self.env,snapshot.env)
        self.native_inventory=type(snapshot.inventory)=="table" and snapshot.inventory or nil
        self.invalidate_all()
        return true
    end

    function self.load_env()
        local ok,snapshot=pcall(self.native.snapshot)
        if not ok then return false,tostring(snapshot) end
        return self.apply_snapshot(snapshot)
    end

    local function load_sizes_file()
        clear(self.size_map)
        local f=io.open(self.env.size_file or "","rb"); if not f then return end
        for line in f:lines() do
            local bytes,path=line:match("^(%d+)\t(.+)$")
            if bytes and path then self.size_map[path]=tonumber(bytes) or 0 end
        end
        f:close()
    end

    local function runtime_arch(value)
        value=tostring(value or ""):lower()
        if value=="arm64" or value=="armv8" then return "aarch64" end
        if value=="armv7" or value=="armv7l" then return "armhf" end
        if value=="amd64" then return "x86_64" end
        return value
    end

    local function load_runtime_metadata_file()
        clear(self.runtime_metadata)
        local f=io.open(self.env.runtime_metadata_file or "","rb")
        if not f then return end
        local arch=runtime_arch(self.env.device_arch)
        for line in f:lines() do
            local name,row_arch,bytes,md5,url=line:match("^([^\t]+)\t([^\t]+)\t(%d+)\t([0-9a-f]+)\t([^\t]+)$")
            if name and row_arch==arch then
                self.runtime_metadata[name]={arch=row_arch,bytes=tonumber(bytes),md5=md5,url=url}
            end
        end
        f:close()
        return self.runtime_metadata
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
                scanning=L("Scanning Port directories","正在扫描 Port 目录"),
                cleaning=L("Removing ._Files garbage files","正在清理 ._Files 垃圾文件"),
                indexing=L("Updating size information","正在更新容量信息"),
                complete=L("Cleanup completed","清理完成"),
            }
            return {progress=0,stage=stages[phase] or L("Cleaning ._Files","正在清理 ._Files"),
                detail="",footer_left=L(string.format("%d files",current),string.format("%d 个文件",current)),
                footer_right=phase=="complete" and L("Done","完成") or L("Scanning…","扫描中…"),phase=phase}
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
        local detail=fields[9]
        if portmaster then detail=""
        elseif phase=="probing" or phase=="connected" then detail=""
        elseif phase=="downloading" then
            detail=fields[9]=="Using local cache" and L("Using local cache","正在使用本地缓存") or
                L("Connection ready and in use","连接已就绪，正在使用")
        end
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
        if value==nil or tostring(value)=="" then return self.L("Not provided","未提供") end
        return tostring(value)
    end

    function self.path_size(paths)
        self.load_sizes()
        local total=0
        for _,path in ipairs(paths or {}) do total=total+(self.size_map[path] or 0) end
        return total
    end

    function self.display_name(name)
        return (name:gsub("%.[^.]+$",""):gsub("^%[[^]]+%]",""):gsub("^[A-Z]_",""))
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

    function self.load_sizes(force)
        -- A first-run background scan may still be producing this file. Do
        -- not cache the temporary absence; the next page build can consume
        -- the atomically published snapshot without an explicit invalidation.
        if not self.file_exists(self.env.size_file or "") then
            clear(self.size_map)
            self.invalidate("sizes")
            return self.size_map
        end
        return cached("sizes",self.env.size_file or "",function()
            load_sizes_file(); return self.size_map
        end,force)
    end

    function self.load_runtime_metadata(force)
        return cached("runtime-metadata",(self.env.runtime_metadata_file or "").."\0"..tostring(self.env.device_arch or ""),
            load_runtime_metadata_file,force)
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
            replace(self.report,native or {ports={},refcount={},orphan_dirs={},orphan_images={},dead_scripts={},runtimes={need={},facts={}}})
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

    function self.update_state()
        local current=tostring(self.env.portmaster_version or "")
        local latest=tostring(self.env.portmaster_latest or "")
        if self.env.update_status~="ok" or latest=="" then return "unknown" end
        if current==latest then return "current" end
        if current:match("^20%d%d[%.%-]%d%d[%.%-]%d%d%-%d%d%d%d$") and
           latest:match("^20%d%d[%.%-]%d%d[%.%-]%d%d%-%d%d%d%d$") and current<latest then return "update" end
        return "reinstall"
    end

    function self.invalidate_for_plan(plan)
        local ports,trash,runtimes,sizes,all=false,false,false,false,false
        for _,item in ipairs(plan or {}) do
            local kind=item.kind
            if kind=="INSTALL_PORTMASTER" then all=true
            elseif kind=="INSTALL_RUNTIME" then runtimes=true
            elseif kind=="TRASH" or kind=="DELETE_MANAGED" or kind=="RESTORE_TRASH" or kind=="RESTORE_ITEM" then
                ports=true; trash=true; runtimes=true; sizes=true
            elseif kind=="EMPTY_TRASH" or kind=="DELETE_ITEM" then
                trash=true; sizes=true
            elseif kind=="CLEAN_APPLEDOUBLE" then
                ports=true; sizes=true
            end
        end
        if all then self.invalidate_all(); return end
        if ports or trash or runtimes then
            self.invalidate("native-inventory")
            self.native_inventory=nil
        end
        if ports then
            self.invalidate("ports")
        end
        if trash then
            self.invalidate("trash")
        end
        if runtimes then
            self.invalidate("required-runtimes","installed-runtimes","runtime-metadata")
        end
        if sizes then self.invalidate("sizes") end
    end

    return self
end

return Model
