-- Declarative launcher schema built on the shared UI kit.
-- A port describes fields/pages/env bindings; this module derives state,
-- validation, legacy imports, widgets and launch_config.env serialization.

local kit = require("kit")
local launcher = {}

local DEFAULT_RESOLUTIONS = {"auto", "640x480", "720x720", "960x540", "960x720", "1280x720"}
local DEFAULT_RESOLUTION_LABELS = {
    auto = "res_auto",
    ["640x480"] = "640×480",
    ["720x720"] = "720×720",
    ["960x540"] = "960×540",
    ["960x720"] = "960×720",
    ["1280x720"] = "1280×720",
}

local function copy(value)
    local out = {}
    for k, v in pairs(value or {}) do out[k] = v end
    return out
end

local function field(kind, spec)
    spec = copy(spec)
    spec.kind = kind
    assert(spec.key, kind .. " field needs key")
    return spec
end

function launcher.select(spec)
    return field("select", spec)
end

function launcher.toggle(spec)
    spec = copy(spec)
    spec.values = {"off", "on"}
    spec.labels = {off = "off", on = "on"}
    spec.default = spec.default or "off"
    return field("select", spec)
end

function launcher.resolution(spec)
    spec = copy(spec)
    spec.key = spec.key or "resolution"
    spec.label = spec.label or "resolution"
    spec.values = spec.values or DEFAULT_RESOLUTIONS
    spec.labels = spec.labels or DEFAULT_RESOLUTION_LABELS
    spec.default = spec.default or "auto"
    spec.env_kind = "resolution"
    return field("select", spec)
end

function launcher.button(label, action)
    return {kind = "button", label = label, action = action}
end

local function add_localized(strings, key, value)
    if type(value) == "table" and (value.en or value.zh) then
        strings[key] = value
        return key
    end
    return value
end

local function normalize_options(strings, f)
    if f.options then
        f.values, f.labels = {}, {}
        for index, option in ipairs(f.options) do
            local value = tostring(option.value or option[1])
            local label = option.label or option[2] or value
            local label_key = "field_" .. f.key .. "_option_" .. index
            f.values[#f.values + 1] = value
            f.labels[value] = add_localized(strings, label_key, label)
        end
    end
    f.values = f.values or {}
    f.labels = f.labels or {}
end

local function encoded_value(f, value)
    if type(f.encode) == "function" then return f.encode(value) end
    if type(f.encode) == "table" then return f.encode[value] or value end
    return value
end

local function write_pair(out, name, value)
    out:write(name .. "=" .. tostring(value) .. "\n")
end

function launcher.define(spec)
    local port = {state = {ui_lang = "zh", launch_count = 0}, strings = {}, credits = spec.credits}
    local fields, by_key = {}, {}

    port.strings.title = spec.title
    for key, value in pairs(spec.strings or {}) do port.strings[key] = value end

    for _, original in ipairs(spec.fields or {}) do
        local f = copy(original)
        normalize_options(port.strings, f)
        f.label_key = add_localized(port.strings, "field_" .. f.key .. "_label", f.label or f.key)
        f.default = tostring(f.default or f.values[1] or "")
        port.state[f.key] = f.default
        fields[#fields + 1] = f
        by_key[f.key] = f
    end

    if spec.legacy then
        port.legacy_env = {path = spec.legacy.path, state_path = spec.legacy.state_path, fields = {}}
        for _, f in ipairs(fields) do
            local legacy = {allowed = f.values, map = f.legacy_map}
            if f.env_kind == "resolution" then
                legacy.width, legacy.height = f.env[1], f.env[2]
            elseif type(f.env) == "string" then
                legacy.name = f.env
            end
            if legacy.name or legacy.width then port.legacy_env.fields[f.key] = legacy end
        end
    end

    port.build_pages = function(k)
        local default_order={}; for _,f in ipairs(fields) do default_order[#default_order+1]=f.key end
        local pages = spec.pages or {{title = "title", fields = spec.field_order or default_order}}
        for page_index, page in ipairs(pages) do
            local rows = {}
            for _, entry in ipairs(page.rows or page.fields or {}) do
                local f = type(entry) == "string" and by_key[entry] or nil
                if f then
                    rows[#rows + 1] = k.picker(f.label_key, f.values, f.labels, f.key)
                elseif type(entry) == "table" and entry.kind == "button" then
                    local key = add_localized(port.strings, "page_" .. page_index .. "_button_" .. (#rows + 1), entry.label)
                    rows[#rows + 1] = k.button(key, entry.action)
                end
            end
            for _, action in ipairs(page.actions or {"start", "quit"}) do
                if action == "start" then rows[#rows + 1] = k.button("start_game", "start")
                elseif action == "quit" then rows[#rows + 1] = k.button("quit_menu", "quit")
                elseif action == "back" then rows[#rows + 1] = k.button("back", "page:1")
                elseif type(action) == "table" then
                    local key = add_localized(port.strings, "page_" .. page_index .. "_action_" .. (#rows + 1), action.label)
                    rows[#rows + 1] = k.button(key, action.action)
                end
            end
            local title = add_localized(port.strings, "page_" .. page_index .. "_title", page.title or "title")
            k.add_page(title, rows)
        end
    end

    port.write_env = function(out, state, k)
        for _, item in ipairs(spec.static_env or {}) do write_pair(out, item[1], item[2]) end
        for _, f in ipairs(fields) do
            if f.env_kind == "resolution" then
                local w, h = k.resolution_wh(f.key)
                write_pair(out, f.env[1], w)
                write_pair(out, f.env[2], h)
            elseif type(f.env) == "string" then
                write_pair(out, f.env, encoded_value(f, state[f.key]))
            end
        end
        if spec.launch_count_env then write_pair(out, spec.launch_count_env, state.launch_count) end
        if spec.write_env then spec.write_env(out, state, k) end
    end

    kit.run(port)
    return port
end

return launcher
