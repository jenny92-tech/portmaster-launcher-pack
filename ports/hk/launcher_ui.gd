# Hollow Knight 启动器 — Godot 3.5 / frt_aarch64_3.5.2 兼容版。
# 走 PortMaster 自带的 Godot 3.5 frt fork (与 heishenhua 统一), 不再用 godot.mono。
#
# 所有游戏参数写进 hk.toml; 本 UI 只收集选择并写 launch_config.env,
# launcher.sh stage 2 据此 sed hk.toml:
#   HKL_WIDTH/HKL_HEIGHT → [device] displayWidth/displayHeight (= 实际渲染分辨率)
#   HKL_SWAP_AB/HKL_SWAP_XY → [input.remap] a/b/x/y
#   HKL_TEXMAX → [gpu] textureMaxDim (运行时贴图上限, RAM 保险丝)
#
# 退出码 (由 launcher.sh stage 2 消费):
#   42  开始游戏
#    0  返回主菜单

extends Control

const EXIT_START_GAME    = 42
const EXIT_QUIT_TO_MENU  = 0

const RESOLUTIONS = ["auto", "640x480", "720x720", "960x540", "960x720", "1280x720"]
# 画面质量 → hk.toml [gpu] textureMaxDim (RAM 保险丝)。低=384 / 中=512 / 高=720 /
# 极致=0 (关 cap, 1 GB 设备会 OOM)。与黑神话同参数。
const TEXMAX = ["384", "512", "720", "0"]
const TOGGLES = ["off", "on"]

const STATE_FILE = "user://hk_launcher_state.json"
const ENV_FILE   = "user://launch_config.env"

# v3: texmax 从二元低内存开关改为四档画面质量 (384/512/720/0); 升版强制 re-default。
const SCHEMA_VERSION = 3

var _state = {
	"schema_version": SCHEMA_VERSION,
	"launch_count":   0,
	"last_action":    "(none)",
	"last_action_at": "",
	"resolution":     "auto",
	"texmax":         "384",
	"swap_ab":        "off",
	"swap_xy":        "off",
	"ui_lang":        "zh",   # launcher UI 语言, "en" or "zh"
}

# UI 文本翻译。专有名词 (Hollow Knight, jenny92) 不翻。
const STRINGS = {
	"detected":   {"en": "Detected %d×%d", "zh": "检测到 %d×%d"},
	"resolution": {"en": "Resolution:",    "zh": "渲染分辨率:"},
	"texmax":     {"en": "Graphics:",      "zh": "画面质量:"},
	"swap_ab":    {"en": "Swap A/B:",      "zh": "换 A/B:"},
	"swap_xy":    {"en": "Swap X/Y:",      "zh": "换 X/Y:"},
	"start_game": {"en": "Start Game",     "zh": "开始游戏"},
	"quit_menu":  {"en": "Quit to Menu",   "zh": "返回主菜单"},
	"off":        {"en": "Off",            "zh": "关"},
	"on":         {"en": "On",             "zh": "开"},
	"q_low":      {"en": "Low (384)",      "zh": "低 (384)"},
	"q_mid":      {"en": "Medium (512)",   "zh": "中 (512)"},
	"q_high":     {"en": "High (720)",     "zh": "高 (720)"},
	"q_ultra":    {"en": "Ultra (uncapped)", "zh": "极致 (不限)"},
	"res_auto":   {"en": "Native",         "zh": "跟随系统"},
}

func _t(key):
	var pair = STRINGS.get(key, {})
	return pair.get(_state.ui_lang, pair.get("en", key))

var _first_focus    = null
var _center         = null
var _ui_lang_button = null


func _ready():
	_load_state()
	_install_font()
	_write_input_remap_cfg()
	_fix_joypad_action_bindings()
	set_anchors_and_margins_preset(Control.PRESET_WIDE)

	var win = OS.get_window_size()
	if win.y > win.x:
		_portrait_rotate(win)

	# 背景: 有 launcher_bg.png 就用 PNG, 没有降级深色面板。
	var bg_path = "res://launcher_bg.png"
	var bg = null
	var f = File.new()
	if f.file_exists(bg_path):
		var img = Image.new()
		if img.load(bg_path) == OK:
			var tex = ImageTexture.new()
			tex.create_from_image(img)
			var tex_rect = TextureRect.new()
			tex_rect.texture = tex
			tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
			bg = tex_rect
	if bg == null:
		var color_rect = ColorRect.new()
		color_rect.color = Color(0.07, 0.07, 0.09)
		bg = color_rect
	bg.set_anchors_and_margins_preset(Control.PRESET_WIDE)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var overlay = ColorRect.new()
	overlay.set_anchors_and_margins_preset(Control.PRESET_WIDE)
	overlay.color = Color(0, 0, 0, 0.35)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(overlay)

	# 左下角署名 — 作者名按原文保留, 不翻译。
	var credits = VBoxContainer.new()
	credits.add_constant_override("separation", 2)
	credits.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for line in ["游戏作者: Team Cherry", "移植作者: Bili 解腻Jenny"]:
		var lbl = Label.new()
		lbl.text = line
		lbl.add_font_override("font", _font(24))
		lbl.add_color_override("font_color", Color(1, 1, 1, 0.9))
		_apply_outline(lbl, 3)
		credits.add_child(lbl)
	credits.set_anchors_and_margins_preset(Control.PRESET_BOTTOM_LEFT)
	credits.margin_left = 18
	credits.margin_top = -64
	credits.margin_right = 560
	credits.margin_bottom = -14
	add_child(credits)

	_center = CenterContainer.new()
	_center.set_anchors_and_margins_preset(Control.PRESET_WIDE)
	add_child(_center)
	_center.add_child(_build_layout())

	# 右上角 EN / 中 切 launcher UI 语言。
	_ui_lang_button = Button.new()
	_ui_lang_button.text = "中" if _state.ui_lang == "en" else "EN"
	_ui_lang_button.rect_min_size = Vector2(64, 44)
	_ui_lang_button.focus_mode = Control.FOCUS_ALL
	_apply_outline(_ui_lang_button, 3)
	_apply_button_theme(_ui_lang_button)
	_ui_lang_button.set_anchors_and_margins_preset(Control.PRESET_TOP_RIGHT)
	_ui_lang_button.margin_left = -84
	_ui_lang_button.margin_top = 16
	_ui_lang_button.margin_right = -20
	_ui_lang_button.margin_bottom = 60
	_ui_lang_button.connect("pressed", self, "_on_ui_lang_toggle")
	add_child(_ui_lang_button)

	set_process_input(true)
	call_deferred("_grab_initial_focus")
	push_warning("[HKL] LauncherUI mounted (launch_count=%d, last=%s)" % [
		_state.launch_count, _state.last_action])


func _input(event):
	if event is InputEventJoypadButton:
		push_warning("[HKL] JoypadButton device=%d button=%d pressed=%s" % [
			event.device, event.button_index, str(event.pressed)])
	elif event is InputEventJoypadMotion:
		if abs(event.axis_value) > 0.5:
			push_warning("[HKL] JoypadMotion device=%d axis=%d value=%.2f" % [
				event.device, event.axis, event.axis_value])
	elif event is InputEventKey:
		push_warning("[HKL] Key scancode=%d pressed=%s" % [event.scancode, str(event.pressed)])


func _build_layout():
	var box = VBoxContainer.new()
	box.rect_min_size = Vector2(576, 540)
	box.alignment = BoxContainer.ALIGN_CENTER
	box.add_constant_override("separation", 10)

	# 专有名词, 不翻译。
	box.add_child(_make_title("Hollow Knight Launcher"))
	box.add_child(_make_subtitle(_t("detected") % [
		OS.get_window_size().x, OS.get_window_size().y]))
	box.add_child(_make_separator())

	var res_labels = {"auto": _t("res_auto"), "640x480": "640×480",
		"720x720": "720×720", "960x540": "960×540", "960x720": "960×720",
		"1280x720": "1280×720"}
	var texmax_labels = {"384": _t("q_low"), "512": _t("q_mid"),
		"720": _t("q_high"), "0": _t("q_ultra")}
	var toggle_labels = {"off": _t("off"), "on": _t("on")}

	box.add_child(_make_row(_t("resolution"), RESOLUTIONS, _state.resolution, res_labels, "resolution"))
	box.add_child(_make_row(_t("texmax"), TEXMAX, _state.texmax, texmax_labels, "texmax"))
	box.add_child(_make_row(_t("swap_ab"), TOGGLES, _state.swap_ab, toggle_labels, "swap_ab"))
	box.add_child(_make_row(_t("swap_xy"), TOGGLES, _state.swap_xy, toggle_labels, "swap_xy"))

	var start_btn = _make_button(_t("start_game"), "_on_start_game")
	box.add_child(start_btn)
	box.add_child(_make_button(_t("quit_menu"), "_on_quit_menu"))

	_first_focus = start_btn
	return box


# 白字 + 黑描边 + drop shadow, 在任何背景上都清晰。
func _apply_outline(node, size = 4):
	node.add_color_override("font_outline_modulate", Color.black)
	node.add_constant_override("outline_size", size)
	node.add_color_override("font_color_shadow", Color(0, 0, 0, 0.55))
	node.add_constant_override("shadow_offset_x", 2)
	node.add_constant_override("shadow_offset_y", 2)


# Button: 深紫半透卡片 + 白字; Focus 亮紫。
func _apply_button_theme(btn):
	btn.add_color_override("font_color",          Color.white)
	btn.add_color_override("font_color_hover",    Color(1.0, 0.95, 1.0))
	btn.add_color_override("font_color_pressed",  Color(0.95, 0.90, 1.0))
	btn.add_color_override("font_color_focus",    Color.white)
	btn.add_color_override("font_color_disabled", Color(0.6, 0.6, 0.6))

	var normal = StyleBoxFlat.new()
	normal.bg_color = Color(0.12, 0.08, 0.20, 0.72)
	normal.border_color = Color(1, 1, 1, 0.22)
	normal.border_width_left = 1
	normal.border_width_right = 1
	normal.border_width_top = 1
	normal.border_width_bottom = 1
	normal.corner_radius_top_left = 8
	normal.corner_radius_top_right = 8
	normal.corner_radius_bottom_left = 8
	normal.corner_radius_bottom_right = 8
	btn.add_stylebox_override("normal", normal)

	var hover = normal.duplicate()
	hover.bg_color = Color(0.18, 0.12, 0.28, 0.85)
	btn.add_stylebox_override("hover", hover)

	var pressed = normal.duplicate()
	pressed.bg_color = Color(0.30, 0.18, 0.42, 0.92)
	btn.add_stylebox_override("pressed", pressed)

	var focus = normal.duplicate()
	focus.bg_color = Color(0.55, 0.32, 0.85, 0.55)
	focus.border_color = Color(1.0, 0.85, 1.0, 1.0)
	focus.border_width_left = 3
	focus.border_width_right = 3
	focus.border_width_top = 3
	focus.border_width_bottom = 3
	btn.add_stylebox_override("focus", focus)


# Godot 3 没 lambda — cycle state 存 meta, 触发时 named method 读 meta。
func _make_row(label_text, values, current, labels, state_key):
	var row = HBoxContainer.new()
	row.rect_min_size = Vector2(512, 50)
	row.add_constant_override("separation", 16)

	var label = Label.new()
	label.text = label_text
	label.rect_min_size = Vector2(176, 0)
	label.valign = Label.VALIGN_CENTER
	label.add_color_override("font_color", Color.white)
	_apply_outline(label)
	row.add_child(label)

	var btn = Button.new()
	btn.rect_min_size = Vector2(224, 48)
	btn.focus_mode = Control.FOCUS_ALL
	_apply_outline(btn)
	_apply_button_theme(btn)
	# ASCII 箭头 — unicode ◀ / ▶ 不在默认字体里, 在掌机上渲染成豆腐块。
	btn.text = "< %s >" % (labels[current] if labels.has(current) else current)
	btn.set_meta("values", values)
	btn.set_meta("labels", labels)
	btn.set_meta("state_key", state_key)
	btn.set_meta("current", current)

	btn.connect("pressed", self, "_on_cycle_pressed", [btn])
	btn.connect("gui_input", self, "_on_cycle_gui_input", [btn])

	row.add_child(btn)
	return row


func _on_cycle_pressed(btn):
	_cycle(btn, 1)


func _on_cycle_gui_input(event, btn):
	if event.is_action_pressed("ui_right"):
		_cycle(btn, 1)
		get_tree().set_input_as_handled()
	elif event.is_action_pressed("ui_left"):
		_cycle(btn, -1)
		get_tree().set_input_as_handled()


func _cycle(btn, delta):
	var values = btn.get_meta("values")
	var labels = btn.get_meta("labels")
	var state_key = btn.get_meta("state_key")
	var idx = values.find(btn.get_meta("current"))
	if idx < 0:
		idx = 0
	idx = posmod(idx + delta, values.size())
	var next = values[idx]
	btn.set_meta("current", next)
	btn.text = "< %s >" % (labels[next] if labels.has(next) else next)
	_state[state_key] = next


func _make_title(text):
	var label = Label.new()
	label.text = text
	label.align = Label.ALIGN_CENTER
	label.add_font_override("font", _font(36))
	label.add_color_override("font_color", Color.white)
	_apply_outline(label, 5)
	return label


func _make_subtitle(text):
	var label = Label.new()
	label.text = text
	label.align = Label.ALIGN_CENTER
	label.add_font_override("font", _font(18))
	label.add_color_override("font_color", Color.white)
	_apply_outline(label, 3)
	return label


func _make_button(text, on_press_method):
	var btn = Button.new()
	btn.text = text
	btn.rect_min_size = Vector2(224, 50)
	btn.focus_mode = Control.FOCUS_ALL
	_apply_outline(btn)
	_apply_button_theme(btn)
	btn.connect("pressed", self, on_press_method)
	return btn


func _make_separator():
	var sep = HSeparator.new()
	sep.rect_min_size = Vector2(0, 4)
	return sep


# 给定字号造一个 DynamicFont (Godot 3 没有 per-label font_size override)。
func _font(size):
	var path = "res://launcher_font_zh.ttf"
	var f = File.new()
	if not f.file_exists(path):
		return null
	var dd = DynamicFontData.new()
	dd.font_path = path
	dd.antialiased = true
	var df = DynamicFont.new()
	df.font_data = dd
	df.size = size
	return df


# 加载 CJK 字体并设为 theme 默认 (size 22), 所有 Label/Button 通用; 中英文同覆盖。
func _install_font():
	var df = _font(22)
	if df == null:
		return
	var t = Theme.new()
	t.default_font = df
	self.theme = t


# EN ↔ 中 切换 launcher UI 语言。重建 center 的 layout, toggle 按钮文本反转。
# 焦点必须留在 _ui_lang_button (不能交给 Start Game), 否则下一帧用户按 A
# 键的事件会被刚抓到焦点的 Start Game 接走 → 直接开始游戏。
func _on_ui_lang_toggle():
	_state.ui_lang = "zh" if _state.ui_lang == "en" else "en"
	_save_state()
	_ui_lang_button.text = "中" if _state.ui_lang == "en" else "EN"
	for child in _center.get_children():
		child.queue_free()
	_center.add_child(_build_layout())
	call_deferred("_grab_lang_toggle_focus")


func _grab_lang_toggle_focus():
	if is_instance_valid(_ui_lang_button):
		_ui_lang_button.grab_focus()


# 把横屏 UI 旋到竖装面板上 (MiniLoong Pocket One 720×960 竖装, 合成输出转 90°)。
# 若某设备上画面上下颠倒, 翻符号: rotation 90 + (win.x,0) ⇄ -90 + (0,win.y)。
func _portrait_rotate(win):
	anchor_right = 0
	anchor_bottom = 0
	rect_size = Vector2(win.y, win.x)
	rect_rotation = 90
	rect_position = Vector2(win.x, 0)
	push_warning("[HKL] portrait panel %dx%d → UI rotated 90°" % [win.x, win.y])


# 先清掉 ui_accept/cancel 上的 joypad button events 再绑我们要的, 防 frt 默认
# 让 B 也触发 ui_accept。与 heishenhua 同策略。
func _fix_joypad_action_bindings():
	var bindings = {
		"ui_accept": JOY_BUTTON_0,
		"ui_cancel": JOY_BUTTON_1,
		"ui_up":     JOY_DPAD_UP,
		"ui_down":   JOY_DPAD_DOWN,
		"ui_left":   JOY_DPAD_LEFT,
		"ui_right":  JOY_DPAD_RIGHT,
	}
	for action in bindings:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for ev in InputMap.get_action_list(action):
			if ev is InputEventJoypadButton:
				InputMap.action_erase_event(action, ev)
		var event = InputEventJoypadButton.new()
		event.button_index = bindings[action]
		event.device = -1
		InputMap.action_add_event(action, event)
	push_warning("[HKL] joypad action bindings installed (cleared defaults first)")


func _grab_initial_focus():
	if _first_focus:
		_first_focus.grab_focus()


func _on_start_game():
	push_warning("[HKL] Start Game pressed")
	_on_action("StartGame", EXIT_START_GAME)


func _on_quit_menu():
	push_warning("[HKL] Quit to Menu pressed")
	_on_action("QuitToMenu", EXIT_QUIT_TO_MENU)


func _on_action(action, exit_code):
	_state.launch_count += 1
	_state.last_action = action
	var dt = OS.get_datetime()
	_state.last_action_at = "%04d-%02d-%02d %02d:%02d:%02d" % [
		dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second]
	_save_state()
	if exit_code == EXIT_START_GAME:
		_write_env()
	get_tree().quit(exit_code)


# ─── Persistence ──────────────────────────────────────────────────────

func _load_state():
	var f = File.new()
	if not f.file_exists(STATE_FILE):
		return
	if f.open(STATE_FILE, File.READ) != OK:
		return
	var text = f.get_as_text()
	f.close()
	var parsed = JSON.parse(text)
	if parsed.error != OK:
		return
	var d = parsed.result
	if typeof(d) != TYPE_DICTIONARY:
		return
	if int(d.get("schema_version", 0)) != SCHEMA_VERSION:
		return
	for k in d:
		if _state.has(k):
			_state[k] = d[k]


func _save_state():
	var f = File.new()
	if f.open(STATE_FILE, File.WRITE) != OK:
		return
	f.store_string(JSON.print(_state, "  "))
	f.close()


# launcher.sh 在退出码 42 后 source 本文件。键扁平、值裸字 — 掌机 CFW 无 jq,
# bash source KEY=value 最稳。
func _write_env():
	var f = File.new()
	if f.open(ENV_FILE, File.WRITE) != OK:
		return
	var w = "auto"
	var h = "auto"
	if _state.resolution != "auto":
		var wh = _state.resolution.split("x")
		w = wh[0]
		h = wh[1]
	f.store_string("# Hollow Knight 启动器 生成; launcher.sh 在退出码 42 时 source.\n")
	f.store_string("HKL_WIDTH=%s\n"        % w)
	f.store_string("HKL_HEIGHT=%s\n"       % h)
	f.store_string("HKL_TEXMAX=%s\n"       % _state.texmax)
	f.store_string("HKL_SWAP_AB=%s\n"      % _state.swap_ab)
	f.store_string("HKL_SWAP_XY=%s\n"      % _state.swap_xy)
	f.store_string("HKL_LAUNCH_COUNT=%d\n" % _state.launch_count)
	f.close()


# 写 launcher UI 自己的 input_remap.cfg (任天堂布局 UI 映射, 跟游戏映射无关)。
# silkscreen-A = 右脸键 (kernel BTN_EAST), fork 默认当成 JoyButton B, 故 a/b 互换
# 让 silkscreen-A 驱动 ui_accept; X/Y 直通。下次启动器重启生效。
func _write_input_remap_cfg():
	var godot_dir = OS.get_executable_path().get_base_dir()
	var path = godot_dir + "/input_remap.cfg"
	var f = File.new()
	if f.open(path, File.WRITE) != OK:
		return
	f.store_string("# Hollow Knight 启动器 生成 (任天堂布局 UI 映射, 跟游戏映射无关).\n\n")
	f.store_string("[buttons]\n")
	f.store_string("a = BUTTON_B\n")
	f.store_string("b = BUTTON_A\n")
	f.store_string("x = BUTTON_X\n")
	f.store_string("y = BUTTON_Y\n")
	f.close()
