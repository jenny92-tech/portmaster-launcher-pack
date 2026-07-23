local Native = {}

function Native.new()
    assert(type(appmanager)=="table","APP Manager Rust service is unavailable")
    local self={}

    function self.snapshot()
        return appmanager.snapshot()
    end

    function self.start(kind,payload)
        if kind=="apply" then return appmanager.start(kind,payload or {}) end
        return appmanager.start(kind)
    end

    function self.poll()
        return appmanager.poll()
    end

    function self.cancel()
        return appmanager.cancel()
    end

    return self
end

return Native
