# 像素黑神话启动器 — 仅配置。公共骨架见 _kit/launcher_base.gd
# (pck_builder 打包为 res://launcher_base.gd)。主页 + 二级"修改/作弊"页。
#
# launch_config.env 字段 → launcher.sh stage 2 改写 wsm.toml:
#   HSH_WIDTH/HEIGHT → [device] displayWidth/Height
#   HSH_TEXMAX       → [gpu] textureMaxDim
#   HSH_DMG          → [[il2cpp_patch]] 承伤倍率 (减伤)
#   HSH_INF_*/SKILL_CD → freeze / force_return 类作弊
#   HSH_SWAP_AB/XY   → [input.remap] a/b/x/y

extends "res://launcher_base.gd"

const RESOLUTIONS = ["auto", "640x480", "720x720", "960x540", "960x720", "1280x720"]
# 画面质量 → textureMaxDim: 低=384 / 中=480 (512 部分场景闪退→480) / 高=720 / 极致=0。
const TEXMAX = ["384", "480", "720", "0"]
# 减伤% → 承伤倍率 (减伤100%=0=无敌)。
const REDUCE      = ["0", "20", "40", "60", "80", "100"]
const REDUCE_MULT = {"0": "1.0", "20": "0.8", "40": "0.6", "60": "0.4", "80": "0.2", "100": "0.0"}
const SCHEMA_VERSION = 9


func _port_state_file():
	return "user://heishenhua_launcher_state.json"


func _port_state():
	return {
		"schema_version": SCHEMA_VERSION,
		"launch_count":   0,
		"last_action":    "(none)",
		"last_action_at": "",
		"resolution":     "auto",
		"texmax":         "480",
		"swap_ab":        "off",
		"swap_xy":        "off",
		"reduce":         "0",
		"inf_mp":         "off",
		"inf_sta":        "off",
		"inf_wine":       "off",
		"skill_cd":       "off",
		"ui_lang":        "zh",
	}


func _port_strings():
	return {
		"title":      {"en": "Pixel Wukong Launcher", "zh": "像素黑神话 启动器"},
		"texmax":     {"en": "Graphics:",        "zh": "画面质量:"},
		"q_low":      {"en": "Low (384)",        "zh": "低 (384)"},
		"q_mid":      {"en": "Medium (480)",     "zh": "中 (480)"},
		"q_high":     {"en": "High (720)",       "zh": "高 (720)"},
		"q_ultra":    {"en": "Ultra (uncapped)", "zh": "极致 (不限)"},
		"cheats":     {"en": "Cheats",           "zh": "修改 / 作弊"},
		"cheat_title":{"en": "Cheats",           "zh": "修改 / 作弊"},
		"back":       {"en": "Back",             "zh": "返回"},
		"reduce":     {"en": "Damage Cut:",      "zh": "减伤:"},
		"r_0":        {"en": "Off",              "zh": "关"},
		"r_20":       {"en": "Cut 20%",          "zh": "减伤 20%"},
		"r_40":       {"en": "Cut 40%",          "zh": "减伤 40%"},
		"r_60":       {"en": "Cut 60%",          "zh": "减伤 60%"},
		"r_80":       {"en": "Cut 80%",          "zh": "减伤 80%"},
		"r_100":      {"en": "Invincible",       "zh": "无敌 (减伤100%)"},
		"inf_mp":     {"en": "Inf. Mana:",       "zh": "无限法力:"},
		"inf_sta":    {"en": "Inf. Stamina:",    "zh": "无限气力:"},
		"inf_wine":   {"en": "Inf. Wine:",       "zh": "无限酒:"},
		"skill_cd":   {"en": "No Immobilize CD:","zh": "定身术无冷却:"},
	}


func _port_credits():
	return [["credit_dev", "Bili 火山哥哥"],
			["credit_art", "Bili 林学学LinkLin"],
			["credit_porter", "Bili 解腻Jenny"]]


func _build_pages():
	var toggle_labels = {"off": _t("off"), "on": _t("on")}

	# 主页: 画面/换键 + [修改/作弊] + 开始/返回主菜单。
	var main = _new_page(_t("title"))
	var res_labels = {"auto": _t("res_auto"), "640x480": "640×480", "720x720": "720×720",
		"960x540": "960×540", "960x720": "960×720", "1280x720": "1280×720"}
	var texmax_labels = {"384": _t("q_low"), "480": _t("q_mid"), "720": _t("q_high"), "0": _t("q_ultra")}
	main.add_child(_make_row(_t("resolution"), RESOLUTIONS, _state.resolution, res_labels, "resolution"))
	main.add_child(_make_row(_t("texmax"), TEXMAX, _state.texmax, texmax_labels, "texmax"))
	main.add_child(_make_row(_t("swap_ab"), TOGGLES, _state.swap_ab, toggle_labels, "swap_ab"))
	main.add_child(_make_row(_t("swap_xy"), TOGGLES, _state.swap_xy, toggle_labels, "swap_xy"))
	main.add_child(_make_separator())

	# 作弊页 (先建拿到页引用, 主页导航按钮指向它)。
	var cheat = _build_cheat_page(toggle_labels)
	main.add_child(_make_button(_t("cheats") + "  >", "_show_page", [cheat.get_parent()]))
	_add_start_quit(main)
	_set_home(main.get_parent())


func _build_cheat_page(toggle_labels):
	var box = _new_page(_t("cheat_title"), false)
	var reduce_labels = {"0": _t("r_0"), "20": _t("r_20"), "40": _t("r_40"),
		"60": _t("r_60"), "80": _t("r_80"), "100": _t("r_100")}
	var reduce_row = _make_row(_t("reduce"), REDUCE, _state.reduce, reduce_labels, "reduce")
	box.add_child(reduce_row)
	box.add_child(_make_row(_t("inf_mp"),   TOGGLES, _state.inf_mp,   toggle_labels, "inf_mp"))
	box.add_child(_make_row(_t("inf_sta"),  TOGGLES, _state.inf_sta,  toggle_labels, "inf_sta"))
	box.add_child(_make_row(_t("inf_wine"), TOGGLES, _state.inf_wine, toggle_labels, "inf_wine"))
	box.add_child(_make_row(_t("skill_cd"), TOGGLES, _state.skill_cd, toggle_labels, "skill_cd"))
	box.add_child(_make_separator())
	box.add_child(_make_button(_t("start_game"), "_on_start_game"))
	box.add_child(_make_button(_t("back"), "_on_back_to_main"))
	# 进作弊页就能直接左右调减伤 (减伤行的按钮 = HBox 第 2 个子)。
	_set_page_focus(box, reduce_row.get_child(1))
	return box


func _on_back_to_main():
	if _home_page:
		_show_page(_home_page)


func _write_env(f):
	var wh = _resolution_wh()
	f.store_string("HSH_WIDTH=%s\n"        % wh[0])
	f.store_string("HSH_HEIGHT=%s\n"       % wh[1])
	f.store_string("HSH_TEXMAX=%s\n"       % _state.texmax)
	f.store_string("HSH_DMG=%s\n"          % REDUCE_MULT.get(_state.reduce, "1.0"))
	f.store_string("HSH_SWAP_AB=%s\n"      % _state.swap_ab)
	f.store_string("HSH_SWAP_XY=%s\n"      % _state.swap_xy)
	f.store_string("HSH_INF_MP=%s\n"       % _state.inf_mp)
	f.store_string("HSH_INF_STA=%s\n"      % _state.inf_sta)
	f.store_string("HSH_INF_WINE=%s\n"     % _state.inf_wine)
	f.store_string("HSH_SKILL_CD=%s\n"     % _state.skill_cd)
	f.store_string("HSH_LAUNCH_COUNT=%d\n" % _state.launch_count)
