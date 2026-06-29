# 空洞骑士启动器 — 仅配置。公共骨架见 _kit/launcher_base.gd
# (pck_builder 打包为 res://launcher_base.gd)。
#
# launch_config.env 字段 → launcher.sh stage 2 sed 进 hk.toml:
#   HKL_WIDTH/HEIGHT → [device] displayWidth/Height (= 实际渲染分辨率)
#   HKL_TEXMAX       → [gpu] textureMaxDim (RAM 保险丝)
#   HKL_SWAP_AB/XY   → [input.remap] a/b/x/y

extends "res://launcher_base.gd"

const RESOLUTIONS = ["auto", "640x480", "720x720", "960x540", "960x720", "1280x720"]
# 画面质量 → textureMaxDim: 低=384 / 中=512 / 高=720 / 极致=0 (关 cap)。
const TEXMAX = ["384", "512", "720", "0"]
const SCHEMA_VERSION = 3


func _port_state_file():
	return "user://hk_launcher_state.json"


func _port_state():
	return {
		"schema_version": SCHEMA_VERSION,
		"launch_count":   0,
		"last_action":    "(none)",
		"last_action_at": "",
		"resolution":     "auto",
		"texmax":         "384",
		"swap_ab":        "off",
		"swap_xy":        "off",
		"ui_lang":        "zh",
	}


func _port_strings():
	return {
		"title":  {"en": "Hollow Knight Launcher", "zh": "空洞骑士 启动器"},
		"texmax": {"en": "Graphics:",       "zh": "画面质量:"},
		"q_low":  {"en": "Low (384)",       "zh": "低 (384)"},
		"q_mid":  {"en": "Medium (512)",    "zh": "中 (512)"},
		"q_high": {"en": "High (720)",      "zh": "高 (720)"},
		"q_ultra":{"en": "Ultra (uncapped)","zh": "极致 (不限)"},
	}


func _port_credits():
	return [["credit_dev", "Team Cherry"], ["credit_porter", "Bili 解腻Jenny"]]


func _build_pages():
	var box = _new_page(_t("title"))
	var res_labels = {"auto": _t("res_auto"), "640x480": "640×480", "720x720": "720×720",
		"960x540": "960×540", "960x720": "960×720", "1280x720": "1280×720"}
	var texmax_labels = {"384": _t("q_low"), "512": _t("q_mid"), "720": _t("q_high"), "0": _t("q_ultra")}
	var toggle_labels = {"off": _t("off"), "on": _t("on")}
	box.add_child(_make_row(_t("resolution"), RESOLUTIONS, _state.resolution, res_labels, "resolution"))
	box.add_child(_make_row(_t("texmax"), TEXMAX, _state.texmax, texmax_labels, "texmax"))
	box.add_child(_make_row(_t("swap_ab"), TOGGLES, _state.swap_ab, toggle_labels, "swap_ab"))
	box.add_child(_make_row(_t("swap_xy"), TOGGLES, _state.swap_xy, toggle_labels, "swap_xy"))
	_add_start_quit(box)


func _write_env(f):
	var wh = _resolution_wh()
	f.store_string("HKL_WIDTH=%s\n"        % wh[0])
	f.store_string("HKL_HEIGHT=%s\n"       % wh[1])
	f.store_string("HKL_TEXMAX=%s\n"       % _state.texmax)
	f.store_string("HKL_SWAP_AB=%s\n"      % _state.swap_ab)
	f.store_string("HKL_SWAP_XY=%s\n"      % _state.swap_xy)
	f.store_string("HKL_LAUNCH_COUNT=%d\n" % _state.launch_count)
