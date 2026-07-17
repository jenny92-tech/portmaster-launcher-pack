# 掌机启动器共用 base — Godot 3.5 / frt。hk + heishenhua 的 launcher_ui.gd
# `extends "res://launcher_base.gd"`, 只覆写下面这几个钩子提供差异部分;
# 公共骨架(背景/遮罩/居中/署名/EN中切换/标题/开始返回/焦点/存档/字体/描边/
# input_remap/竖屏旋转/手柄绑定/页面切换)都在这里。pck_builder 把本文件和
# 各 port 的 launcher_ui.gd 一起打进 bootstrap.pck (res://launcher_base.gd)。
#
# 退出码 (launcher.sh stage 2 消费): 42 开始游戏 / 0 返回主菜单。

extends Control

const EXIT_START_GAME   = 42
const EXIT_QUIT_TO_MENU = 0
const TOGGLES = ["off", "on"]
const ENV_FILE = "user://launch_config.env"
const CONTACT_TEXT = "QQ 群 1047158975"

# 公共 UI 文本。专有名词不翻。子类用 _port_strings() 追加/覆盖。
const BASE_STRINGS = {
	"detected":   {"en": "Detected %d×%d", "zh": "检测到 %d×%d"},
	"start_game": {"en": "Start Game",     "zh": "开始游戏"},
	"quit_menu":  {"en": "Quit to Menu",   "zh": "返回主菜单"},
	"off":        {"en": "Off",            "zh": "关"},
	"on":         {"en": "On",             "zh": "开"},
	"swap_ab":    {"en": "Swap A/B:",      "zh": "交换 A/B:"},
	"swap_xy":    {"en": "Swap X/Y:",      "zh": "交换 X/Y:"},
	"resolution": {"en": "Resolution:",    "zh": "渲染分辨率:"},
	"res_auto":   {"en": "Native",         "zh": "跟随系统"},
	"credit_dev": {"en": "Developer",      "zh": "游戏作者"},
	"credit_art": {"en": "Artist",         "zh": "美术作者"},
	"credit_porter": {"en": "Porter",      "zh": "移植作者"},
}

var _state          = {}
var _strings        = {}
var _pages          = []      # 所有页面 (CenterContainer), 切 visible 显隐
var _home_page      = null    # 首页 / B 键回退目标
var _center         = null    # 填满屏的容器, 各页面是它的子节点
var _credits        = null
var _ui_lang_button = null


# ── 子类钩子 (覆写) ──────────────────────────────────────────────────
func _port_state():      return {"schema_version": 1, "ui_lang": "zh"}  # 默认 state
func _port_state_file(): return "user://launcher_state.json"
func _port_strings():    return {}     # 该 port 额外 STRINGS
func _port_credits():    return []     # [[翻译键, 固定名], ...]
func _build_pages():     pass          # 子类用 _new_page / _make_row / _add_start_quit 搭页面
func _write_env(_f):     pass          # 子类往打开的 File 写 env 行


func _ready():
	_state = _port_state()
	_strings = BASE_STRINGS.duplicate(true)
	for k in _port_strings():
		_strings[k] = _port_strings()[k]
	_load_state()
	_install_font()
	_write_input_remap_cfg()
	_fix_joypad_action_bindings()
	set_anchors_and_margins_preset(Control.PRESET_WIDE)

	var win = OS.get_window_size()
	if win.y > win.x:
		_portrait_rotate(win)

	_add_background()

	_credits = _build_credits()
	add_child(_credits)
	add_child(_build_contact_label())

	_center = Control.new()
	_center.set_anchors_and_margins_preset(Control.PRESET_WIDE)
	add_child(_center)
	_build_pages()
	if _home_page == null and _pages.size() > 0:
		_home_page = _pages[0]
	if _home_page:
		_show_page(_home_page)

	_add_lang_toggle()
	set_process_input(true)
	call_deferred("_grab_initial_focus")
	push_warning("[%s] LauncherUI mounted (lang=%s)" % [_port_state_file(), _state.ui_lang])


func _t(key):
	var pair = _strings.get(key, {})
	return pair.get(_state.ui_lang, pair.get("en", key))


# 作弊页按 B 回首页 (其余 ui_cancel 不处理)。
func _input(event):
	if event.is_action_pressed("ui_cancel") and _home_page and not _home_page.visible:
		_show_page(_home_page)
		get_tree().set_input_as_handled()


# ── 背景 + 遮罩 ──────────────────────────────────────────────────────
func _add_background():
	var bg = null
	var f = File.new()
	if f.file_exists("res://launcher_bg.png"):
		var img = Image.new()
		if img.load("res://launcher_bg.png") == OK:
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


# ── 页面框架 ─────────────────────────────────────────────────────────
# 新建一页: CenterContainer 居中一个 VBox, 自带标题(+检测分辨率副标题)+分隔线。
# 返回 box 供子类继续 add picker 行 / 按钮。
func _new_page(title_text, with_detected = true):
	var page = CenterContainer.new()
	page.set_anchors_and_margins_preset(Control.PRESET_WIDE)
	page.visible = false
	var box = VBoxContainer.new()
	box.rect_min_size = Vector2(576, 540)
	box.alignment = BoxContainer.ALIGN_CENTER
	box.add_constant_override("separation", 10)
	box.add_child(_make_title(title_text))
	if with_detected:
		box.add_child(_make_subtitle(_t("detected") % [OS.get_window_size().x, OS.get_window_size().y]))
	box.add_child(_make_separator())
	page.add_child(box)
	_center.add_child(page)
	_pages.append(page)
	return box


# 给页面加"开始游戏 / 返回主菜单", 并把首焦点设为开始按钮。
func _add_start_quit(box):
	var start_btn = _make_button(_t("start_game"), "_on_start_game")
	box.add_child(start_btn)
	box.add_child(_make_button(_t("quit_menu"), "_on_quit_menu"))
	box.get_parent().set_meta("first_focus", start_btn)


# 指定首页 / B 回退目标 (默认 _pages[0])。
func _set_home(page):
	_home_page = page


# 设某页的首焦点 (作弊页想进去就能调减伤行)。
func _set_page_focus(box, control):
	box.get_parent().set_meta("first_focus", control)


func _show_page(page):
	for p in _pages:
		p.visible = (p == page)
	if page.has_meta("first_focus"):
		var ff = page.get_meta("first_focus")
		if is_instance_valid(ff):
			ff.grab_focus()


# ── 控件工厂 ─────────────────────────────────────────────────────────
func _apply_outline(node, size = 4):
	node.add_color_override("font_outline_modulate", Color.black)
	node.add_constant_override("outline_size", size)
	node.add_color_override("font_color_shadow", Color(0, 0, 0, 0.55))
	node.add_constant_override("shadow_offset_x", 2)
	node.add_constant_override("shadow_offset_y", 2)


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


# picker 行: 左侧标签 + 右侧 "< 值 >" 循环按钮。cycle 状态存按钮 meta;
# _cycle 改 _state[state_key]。values/labels 用 meta 带进回调。
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


# 用 btn.accept_event() 吃掉左右键 (不是 set_input_as_handled): 否则事件没被
# GUI 标记已处理, Godot 会再拿它做几何焦点导航 → 焦点跳到右上角 EN/中 toggle。
func _on_cycle_gui_input(event, btn):
	if event.is_action_pressed("ui_right"):
		_cycle(btn, 1)
		btn.accept_event()
	elif event.is_action_pressed("ui_left"):
		_cycle(btn, -1)
		btn.accept_event()


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


# 普通按钮: pressed 连到 self 的 method (binds 透传, 给导航按钮带目标页)。
func _make_button(text, method_name, binds = []):
	var btn = Button.new()
	btn.text = text
	btn.rect_min_size = Vector2(224, 50)
	btn.focus_mode = Control.FOCUS_ALL
	_apply_outline(btn)
	_apply_button_theme(btn)
	btn.connect("pressed", self, method_name, binds)
	return btn


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


func _install_font():
	var df = _font(22)
	if df == null:
		return
	var t = Theme.new()
	t.default_font = df
	self.theme = t


# ── 署名 (左下角) ────────────────────────────────────────────────────
func _build_credits():
	var c = VBoxContainer.new()
	c.add_constant_override("separation", 2)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for _entry in _port_credits():
		var lbl = Label.new()
		lbl.add_font_override("font", _font(24))
		lbl.add_color_override("font_color", Color(1, 1, 1, 0.9))
		_apply_outline(lbl, 3)
		c.add_child(lbl)
	c.set_anchors_and_margins_preset(Control.PRESET_BOTTOM_LEFT)
	c.margin_left = 18
	c.margin_top = -18 - 26 * _port_credits().size()
	c.margin_right = 560
	c.margin_bottom = -14
	_credits = c
	_refresh_credits()
	return c


# 切语言只更新署名标签文本 (标签翻译, 名字不变)。
func _refresh_credits():
	if not is_instance_valid(_credits):
		return
	var creds = _port_credits()
	var kids = _credits.get_children()
	for i in range(creds.size()):
		kids[i].text = _t(creds[i][0]) + ": " + creds[i][1]


# ── 联系方式 (右下角) ────────────────────────────────────────────────
func _build_contact_label():
	var lbl = Label.new()
	lbl.text = CONTACT_TEXT
	lbl.align = Label.ALIGN_RIGHT
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.add_font_override("font", _font(22))
	lbl.add_color_override("font_color", Color(1, 1, 1, 0.9))
	_apply_outline(lbl, 3)
	lbl.set_anchors_and_margins_preset(Control.PRESET_BOTTOM_RIGHT)
	lbl.margin_left = -360
	lbl.margin_top = -48
	lbl.margin_right = -18
	lbl.margin_bottom = -14
	return lbl


# ── EN / 中 切换 ─────────────────────────────────────────────────────
func _add_lang_toggle():
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


# 切语言: 翻转 lang, 重建所有页面 (回首页), 刷新署名。焦点留在 toggle —— 否则
# 下一帧用户按 A 会被刚抓焦点的开始按钮接走 → 直接开始游戏。
func _on_ui_lang_toggle():
	_state.ui_lang = "zh" if _state.ui_lang == "en" else "en"
	_save_state()
	_ui_lang_button.text = "中" if _state.ui_lang == "en" else "EN"
	for child in _center.get_children():
		child.queue_free()
	_pages = []
	_home_page = null
	_build_pages()
	if _home_page == null and _pages.size() > 0:
		_home_page = _pages[0]
	if _home_page:
		_home_page.visible = true
	_refresh_credits()
	call_deferred("_grab_lang_toggle_focus")


func _grab_lang_toggle_focus():
	if is_instance_valid(_ui_lang_button):
		_ui_lang_button.grab_focus()


func _grab_initial_focus():
	if _home_page and _home_page.has_meta("first_focus"):
		var ff = _home_page.get_meta("first_focus")
		if is_instance_valid(ff):
			ff.grab_focus()


# ── 输入: 竖屏旋转 + 手柄绑定 ────────────────────────────────────────
func _portrait_rotate(win):
	anchor_right = 0
	anchor_bottom = 0
	rect_size = Vector2(win.y, win.x)
	rect_rotation = 90
	rect_position = Vector2(win.x, 0)


# 先清 ui_accept/cancel 上的 joypad button events 再绑, 防 frt 默认让 B 也确定。
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


# ── 动作 + 持久化 ────────────────────────────────────────────────────
func _on_start_game():
	_on_action("StartGame", EXIT_START_GAME)


func _on_quit_menu():
	_on_action("QuitToMenu", EXIT_QUIT_TO_MENU)


func _on_action(action, exit_code):
	if _state.has("launch_count"):
		_state.launch_count += 1
	_state.last_action = action
	var dt = OS.get_datetime()
	_state.last_action_at = "%04d-%02d-%02d %02d:%02d:%02d" % [
		dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second]
	_save_state()
	if exit_code == EXIT_START_GAME:
		_write_env_file()
	get_tree().quit(exit_code)


func _load_state():
	var f = File.new()
	if not f.file_exists(_port_state_file()):
		return
	if f.open(_port_state_file(), File.READ) != OK:
		return
	var text = f.get_as_text()
	f.close()
	var parsed = JSON.parse(text)
	if parsed.error != OK:
		return
	var d = parsed.result
	if typeof(d) != TYPE_DICTIONARY:
		return
	if int(d.get("schema_version", 0)) != int(_state.get("schema_version", -1)):
		return
	for k in d:
		if _state.has(k):
			_state[k] = d[k]


func _save_state():
	var f = File.new()
	if f.open(_port_state_file(), File.WRITE) != OK:
		return
	f.store_string(JSON.print(_state, "  "))
	f.close()


# 打开 env 文件, 写公共表头 + 分辨率, 再调子类 _write_env(f) 写 port 专属行。
func _write_env_file():
	var f = File.new()
	if f.open(ENV_FILE, File.WRITE) != OK:
		return
	f.store_string("# Generated by launcher; sourced by launcher.sh on exit 42.\n")
	_write_env(f)
	f.close()


# 分辨率 -> [w, h] (auto 直传 "auto")。子类 _write_env 里调。
func _resolution_wh():
	if not _state.has("resolution") or _state.resolution == "auto":
		return ["auto", "auto"]
	var wh = _state.resolution.split("x")
	return [wh[0], wh[1]]


# launcher UI 自己的 input_remap.cfg (任天堂布局, 跟游戏映射无关): silkscreen-A =
# 右脸键, fork 默认当 JoyButton B, 故 a/b 互换让 A 驱动 ui_accept; X/Y 直通。
func _write_input_remap_cfg():
	var godot_dir = OS.get_executable_path().get_base_dir()
	var f = File.new()
	if f.open(godot_dir + "/input_remap.cfg", File.WRITE) != OK:
		return
	f.store_string("# Generated by launcher (任天堂布局 UI 映射, 跟游戏映射无关).\n\n")
	f.store_string("[buttons]\n")
	f.store_string("a = BUTTON_B\n")
	f.store_string("b = BUTTON_A\n")
	f.store_string("x = BUTTON_X\n")
	f.store_string("y = BUTTON_Y\n")
	f.close()
