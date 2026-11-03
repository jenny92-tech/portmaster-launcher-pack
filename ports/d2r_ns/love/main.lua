-- INPUT:  launcher 共享声明式启动器框架
-- OUTPUT: D2R NS 开始/退出页面与独立启动次数配置
-- POS:    保留已验证游戏预设的轻量 PortMaster 界面
local launcher = require("launcher")

launcher.define {
    id = "d2r_ns",
    title = {en = "Diablo II: Resurrected (NS)", zh = "暗黑破坏神II：狱火重生（NS）"},
    credits = {
        {"credit_dev", "Blizzard Entertainment / Vicarious Visions"},
        {"credit_porter", "Bili 解腻Jenny"},
    },
    fields = {},
    pages = {{title = "title", actions = {"start", "quit"}}},
    launch_count_env = "D2R_NS_LAUNCH_COUNT",
}
