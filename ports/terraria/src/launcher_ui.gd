# 泰拉瑞亚启动器 — 仅配置。公共骨架见 _kit/launcher_base.gd。
#
# launch_config.env 字段 → launcher.sh stage 2:
#   TER_WIDTH/HEIGHT → wsm.toml displayWidth/displayHeight
#   TER_LANGUAGE     → Android config.json Language (1=en, 7=zh-Hans, 12=zh-Hant)
#   TER_SWAP_AB/XY   → [input.remap] a/b/x/y

extends "res://launcher_base.gd"

const RESOLUTIONS = ["auto", "640x480", "720x720", "960x540", "960x720", "1280x720"]
const LANG_VALUES = ["1", "7", "12"]
const SCHEMA_VERSION = 1


func _port_state_file():
	return "user://terraria_launcher_state.json"


func _port_state():
	return {
		"schema_version": SCHEMA_VERSION,
		"launch_count":   0,
		"last_action":    "(none)",
		"last_action_at": "",
		"resolution":     "auto",
		"language":       "7",
		"swap_ab":        "off",
		"swap_xy":        "off",
		"ui_lang":        "zh",
	}


func _port_strings():
	return {
		"title":     {"en": "Terraria Launcher",          "zh": "泰拉瑞亚 启动器"},
		"language":  {"en": "Game Language:",             "zh": "游戏语言:"},
		"lang_en":   {"en": "English",                    "zh": "英文"},
		"lang_zh":   {"en": "Chinese (Simplified)",       "zh": "简体中文"},
		"lang_zht":  {"en": "Chinese (Traditional)",      "zh": "繁体中文"},
	}


func _port_credits():
	return [["credit_dev", "Re-Logic / 505 Games"], ["credit_porter", "Bili 解腻Jenny"]]


func _build_pages():
	var box = _new_page(_t("title"))
	var res_labels = {"auto": _t("res_auto"), "640x480": "640×480", "720x720": "720×720",
		"960x540": "960×540", "960x720": "960×720", "1280x720": "1280×720"}
	var lang_labels = {"1": _t("lang_en"), "7": _t("lang_zh"), "12": _t("lang_zht")}
	var toggle_labels = {"off": _t("off"), "on": _t("on")}
	box.add_child(_make_row(_t("resolution"), RESOLUTIONS, _state.resolution, res_labels, "resolution"))
	box.add_child(_make_row(_t("language"), LANG_VALUES, _state.language, lang_labels, "language"))
	box.add_child(_make_row(_t("swap_ab"), TOGGLES, _state.swap_ab, toggle_labels, "swap_ab"))
	box.add_child(_make_row(_t("swap_xy"), TOGGLES, _state.swap_xy, toggle_labels, "swap_xy"))
	_add_start_quit(box)


func _write_env(f):
	var wh = _resolution_wh()
	f.store_string("TER_WIDTH=%s\n"        % wh[0])
	f.store_string("TER_HEIGHT=%s\n"       % wh[1])
	f.store_string("TER_LANGUAGE=%s\n"     % _state.language)
	f.store_string("TER_SWAP_AB=%s\n"      % _state.swap_ab)
	f.store_string("TER_SWAP_XY=%s\n"      % _state.swap_xy)
	f.store_string("TER_LAUNCH_COUNT=%d\n" % _state.launch_count)
