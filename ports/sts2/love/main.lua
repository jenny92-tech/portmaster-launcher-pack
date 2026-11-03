-- INPUT:  launcher 共享 UI 模块与 Shell 提供的图形后端能力
-- OUTPUT: launcher.define 注册的 STS2 设置页和 SLL_* 环境交接
-- POS:    STS2 的图形、语言、画质与高级设置声明
local launcher = require("launcher")

local initial_language = os.getenv("SLL_INITIAL_LANGUAGE")
if initial_language ~= "en_US" and initial_language ~= "zh_CN" then initial_language = "zh_CN" end
local initial_quality = os.getenv("SLL_INITIAL_QUALITY")
if initial_quality ~= "smooth" and initial_quality ~= "balanced" and initial_quality ~= "quality" then
    initial_quality = "balanced"
end

local available = {
    vulkan = os.getenv("SLL_VULKAN_AVAILABLE") == "1",
    gles = os.getenv("SLL_GLES_AVAILABLE") == "1",
}
local preferred = os.getenv("SLL_GRAPHICS_PREFERRED")
local graphics = {}
-- Keep a saved explicit selection even when this device cannot use it.
function graphics.supports(api) return api == "auto" or api == "gles" or api == "vulkan" end
function graphics.default_api() return "auto" end
function graphics.resolve(state)
    local api = state.graphics_api or graphics.default_api()
    if api == "auto" then
        if available[preferred] then api = preferred
        elseif available.gles then api = "gles"
        elseif available.vulkan then api = "vulkan" end
    end
    local usable = available[api] == true
    return {api = api, available = usable, controls = {}, features = {
        button_remap = false,
        weston_composition = usable and api == "vulkan" and os.getenv("SLL_WESTON_COMPOSITION_AVAILABLE") == "1",
    }}
end
function graphics.validate(state)
    if not graphics.resolve(state).available then
        return false, {en = "The selected graphics backend is unavailable.", zh = "所选图形后端暂不可用。"}
    end
    return true
end

local port = launcher.define {
    id = "sts2",
    title = {en = "STS2 Linux Launcher", zh = "杀戮尖塔2 启动器"},
    credits = {
        {"credit_dev", "Mega Crit"},
        {"credit_porter", "Bili 解腻Jenny"},
    },
    fields = {
        launcher.select {
            key = "language", label = {en = "Language:", zh = "语言:"}, default = initial_language, env = "SLL_LANGUAGE",
            options = {{"en_US", {en = "English", zh = "英文"}}, {"zh_CN", {en = "Chinese", zh = "中文"}}},
        },
        launcher.select {
            key = "quality", label = {en = "Quality:", zh = "画质:"}, default = initial_quality, env = "SLL_QUALITY",
            options = {
                {"smooth", {en = "Smooth", zh = "流畅"}}, {"balanced", {en = "Balanced", zh = "均衡"}},
                {"quality", {en = "Fidelity", zh = "画质"}},
            },
        },
        launcher.select {
            key = "graphics_api", label = {en = "Graphics Backend:", zh = "图形后端:"},
            default = graphics.default_api(), env = "SLL_GRAPHICS_API", graphics = graphics,
            disabled_values = {vulkan = not available.vulkan, gles = not available.gles},
            options = {
                {"auto", {en = "Auto (recommended)", zh = "自动（设备推荐）"}},
                {"gles", {en = "SDL2 (OpenGL)", zh = "SDL2（OpenGL）"}},
                {"vulkan", {en = "Vulkan", zh = "Vulkan"}},
            },
        },
        launcher.toggle {
            key = "swap_ab", label = {en = "Swap A/B (unavailable):", zh = "交换 A/B（暂不支持）:"},
            default = "on", env = "SLL_SWAP_AB", requires_feature = "button_remap", unavailable_value = "off",
        },
        launcher.toggle {
            key = "swap_xy", label = {en = "Swap X/Y (unavailable):", zh = "交换 X/Y（暂不支持）:"},
            env = "SLL_SWAP_XY", requires_feature = "button_remap", unavailable_value = "off",
        },
        launcher.toggle {
            key = "weston_composition", label = {en = "Force Composition:", zh = "强制合成:"},
            default = "on", env = "SLL_WESTON_COMPOSITION",
            requires_feature = "weston_composition", unavailable_value = "off",
        },
        launcher.toggle {key = "perf_overlay", label = {en = "Performance Info:", zh = "性能信息:"}, env = "SLL_PERF_OVERLAY"},
        launcher.toggle {key = "diagnostics", label = {en = "Diagnostic Log:", zh = "诊断日志:"}, env = "SLL_DIAGNOSTICS"},
    },
    pages = {
        {title = "title", rows = {"language", "quality", launcher.button("advanced", "page:2")}},
        {title = "advanced_title", fields = {"graphics_api", "swap_ab", "swap_xy", "weston_composition", "perf_overlay", "diagnostics"}, actions = {"start", "back"}},
    },
    static_env = {{"SLL_PCK_VARIANT", "8x8"}},
    legacy = {
        path = "../conf/godot/app_userdata/STS2 Linux Launcher/launch_config.env",
        state_path = "../conf/godot/app_userdata/STS2 Linux Launcher/linux_launcher_state.json",
    },
    launch_count_env = "SLL_LAUNCH_COUNT",
}

-- The regular arrow picker skips disabled values entirely. A dropdown keeps
-- all backends visible, with unavailable choices dimmed.
local build_pages = port.build_pages
port.build_pages = function(k)
    local add_page = k.add_page
    k.add_page = function(title, rows, ...)
        for _, row in ipairs(rows) do
            if row.key == "graphics_api" then
                row.dropdown = true
            end
        end
        return add_page(title, rows, ...)
    end
    local ok, err = pcall(build_pages, k)
    k.add_page = add_page
    if not ok then error(err, 0) end
end
