local Model = {}

local function clear(values)
    for key in pairs(values) do values[key]=nil end
end

local function replace(target,source)
    clear(target)
    for key,value in pairs(source or {}) do target[key]=value end
end

function Model.new(kit,json,scanner)
    local self={
        env={},report={},size_map={},runtime_metadata={},
        pages={HOME=1,JUNK=2,TRASH=3,ENV=4,RUNTIME=5,MANAGE=6},
    }

    function self.L(en,zh) return {en=en,zh=zh} end
    function self.join(parts,sep) return table.concat(parts,sep or " · ") end
    function self.shquote(value) return "'"..tostring(value):gsub("'","'\\''").."'" end

    function self.file_exists(path)
        local f=path and io.open(path,"rb")
        if f then f:close(); return true end
        return false
    end

    function self.read_all(path)
        local f=path and io.open(path,"rb"); if not f then return nil end
        local text=f:read("*a"); f:close(); return text
    end

    function self.load_env()
        local path=os.getenv("PAM_ENV") or ""
        local text=self.read_all(path)
        if not text then return false,"PAM_ENV is unavailable" end
        local ok,value=pcall(json.decode,text)
        if not ok or type(value)~="table" then return false,tostring(value) end
        replace(self.env,value)
        return true
    end

    local function load_sizes()
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

    function self.load_runtime_metadata()
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
    end

    function self.human(bytes)
        bytes=tonumber(bytes) or 0
        if bytes>=1024^3 then return string.format("%.1f GB",bytes/1024^3) end
        if bytes>=1024^2 then return string.format("%.1f MB",bytes/1024^2) end
        if bytes>=1024 then return string.format("%.1f KB",bytes/1024) end
        return tostring(bytes).." B"
    end

    function self.runtime_progress()
        local L=self.L
        local text=self.read_all(self.env.progress_file or "")
        if not text then return nil end
        local fields={}
        for value in (text:gsub("[\r\n]+$","").."\t"):gmatch("(.-)\t") do fields[#fields+1]=value end
        if fields[1]~="1" or #fields<9 then return nil end
        local phase,runtime=fields[2],fields[3]
        local index,count=tonumber(fields[4]) or 0,tonumber(fields[5]) or 0
        local current,total,speed=tonumber(fields[6]) or 0,tonumber(fields[7]) or 0,tonumber(fields[8]) or 0
        local portmaster=runtime=="PortMaster"
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

    function self.refresh_scan()
        load_sizes()
        self.load_runtime_metadata()
        replace(self.report,scanner.run(self.env))
    end

    function self.missing_runtime(script)
        local out={}
        for _,item in ipairs(self.report.runtimes.missing or {}) do
            for _,user in ipairs(item.users or {}) do if user==script then out[#out+1]=item.name end end
        end
        table.sort(out); return table.concat(out,", ")
    end

    function self.required_runtimes()
        local out={}
        for name,users in pairs(self.report.runtimes.need or {}) do
            local health,bytes=scanner.runtime_file_health((self.env.libs_dir or "").."/"..name..".squashfs")
            out[#out+1]={name=name,users=users,health=health,bytes=bytes,
                missing=health=="missing",damaged=health=="invalid_magic",
                needs_repair=health=="missing" or health=="invalid_magic"}
        end
        table.sort(out,function(a,b) return a.name<b.name end)
        return out
    end

    function self.runtime_issue_count()
        local count=0
        for _,item in ipairs(self.required_runtimes()) do if item.needs_repair then count=count+1 end end
        return count
    end

    function self.load_update_cache()
        local text=self.read_all(self.env.update_cache_file or "")
        if not text then return self.env.update_status,self.env.portmaster_latest end
        local _,status,latest=text:match("^(%d+)\t([^\t\r\n]+)\t([^\r\n]*)")
        if status then self.env.update_status=status; self.env.portmaster_latest=latest or "" end
        return self.env.update_status,self.env.portmaster_latest
    end

    function self.update_state()
        self.load_update_cache()
        local current=tostring(self.env.portmaster_version or "")
        local latest=tostring(self.env.portmaster_latest or "")
        if self.env.update_status~="ok" or latest=="" then return "unknown" end
        if current==latest then return "current" end
        if current:match("^20%d%d[%.%-]%d%d[%.%-]%d%d%-%d%d%d%d$") and
           latest:match("^20%d%d[%.%-]%d%d[%.%-]%d%d%-%d%d%d%d$") and current<latest then return "update" end
        return "reinstall"
    end

    return self
end

return Model
