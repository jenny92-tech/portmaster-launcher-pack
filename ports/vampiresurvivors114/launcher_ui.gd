# 吸血鬼幸存者启动器 — 仅配置。公共骨架见 _kit/launcher_base.gd
# (pck_builder 打包为 res://launcher_base.gd)。
#
# launch_config.env 字段 → launcher.sh stage 2 改写 vs.toml:
#   VS_WIDTH/HEIGHT → auto, launcher.sh 跟随设备分辨率
#   VS_GAME_LANG    → [locale] tag + PlayerPrefs "I2 Language"
#   VS_SWAP_AB/XY   → [input.remap] a/b/x/y
#
# textureMaxDim 在本游戏会影响视角/人物位置, launcher.sh 固定为 0, 不进菜单。

extends "res://launcher_base.gd"

const GAME_LANGS = ["zh-CN", "en"]
const SCHEMA_VERSION = 2


func _port_state_file():
	return "user://vs_launcher_state.json"


func _port_state():
	return {
		"schema_version": SCHEMA_VERSION,
		"launch_count":   0,
		"last_action":    "(none)",
		"last_action_at": "",
		"resolution":     "auto",
		"game_lang":      "zh-CN",
		"swap_ab":        "off",
		"swap_xy":        "off",
		"ui_lang":        "zh",
	}


func _port_strings():
	return {
		"title":     {"en": "Vampire Survivors 1.14 Launcher", "zh": "吸血鬼幸存者 1.14 启动器"},
		"game_lang": {"en": "Language:",       "zh": "语言:"},
		"lang_zh":   {"en": "中文",             "zh": "中文"},
		"lang_en":   {"en": "English",         "zh": "English"},
	}


func _port_credits():
	return [["credit_dev", "poncle"], ["credit_porter", "Bili 解腻Jenny"]]


func _build_pages():
	var box = _new_page(_t("title"))
	var lang_labels = {"zh-CN": _t("lang_zh"), "en": _t("lang_en")}
	var toggle_labels = {"off": _t("off"), "on": _t("on")}
	box.add_child(_make_row(_t("game_lang"), GAME_LANGS, _state.game_lang, lang_labels, "game_lang"))
	box.add_child(_make_row(_t("swap_ab"), TOGGLES, _state.swap_ab, toggle_labels, "swap_ab"))
	box.add_child(_make_row(_t("swap_xy"), TOGGLES, _state.swap_xy, toggle_labels, "swap_xy"))
	_add_start_quit(box)


func _write_env(f):
	f.store_string("VS_WIDTH=auto\n")
	f.store_string("VS_HEIGHT=auto\n")
	f.store_string("VS_GAME_LANG=%s\n"    % _state.game_lang)
	f.store_string("VS_SWAP_AB=%s\n"      % _state.swap_ab)
	f.store_string("VS_SWAP_XY=%s\n"      % _state.swap_xy)
	f.store_string("VS_LAUNCH_COUNT=%d\n" % _state.launch_count)
