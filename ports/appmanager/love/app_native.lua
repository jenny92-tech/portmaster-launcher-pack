local Native = {}

function Native.new(json)
    assert(type(appmanager)=="table","APP Manager Rust service is unavailable")
    local self={}

    local function decode(value)
        if value==nil then return nil end
        local ok,result=pcall(json.decode,tostring(value))
        if not ok or type(result)~="table" then error("invalid Rust service response") end
        return result
    end

    function self.snapshot()
        return decode(appmanager.snapshot())
    end

    function self.start(kind,payload)
        return appmanager.start(kind,json.encode(payload or {}))
    end

    function self.poll()
        return decode(appmanager.poll())
    end

    function self.cancel()
        return appmanager.cancel()
    end

    return self
end

return Native
