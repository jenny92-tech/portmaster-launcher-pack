# 像素黑神话启动器 — Godot 3.5 / frt_aarch64_3.5.2 兼容版。
# 走 PortMaster 自带的 Godot 3.5 frt fork, 不需要 port 自带 60 MB godot.mono binary。
#
# 退出码 (由 launcher.sh stage 2 消费):
#   42  开始游戏
#    0  返回主菜单

extends Control

const EXIT_START_GAME    = 42
const EXIT_QUIT_TO_MENU  = 0

const RESOLUTIONS = ["auto", "640x480", "720x720", "960x540", "960x720", "1280x720"]
# 画面质量 → wsm.toml [gpu] textureMaxDim
# 低=384 (最稳) / 中=480 (默认甜点) / 高=720 / 极致=0 (关 cap; 1 GB 设备会 OOM)
# 中档原为 512,部分场景闪退 → 降到 480。
const TEXMAX = ["384", "480", "720", "0"]
const TOGGLES = ["off", "on"]
# 减伤 (二级"修改/作弊"页) → wsm.toml [[il2cpp_patch]] mult (玩家承伤倍率)。
# 减伤百分比 → 倍率 = (100-减伤)/100; 减伤100% = 倍率0 = 无敌。unityloader 框架缩放伤害。
const REDUCE      = ["0", "20", "40", "60", "80", "100"]
const REDUCE_MULT = {
	"0": "1.0", "20": "0.8", "40": "0.6", "60": "0.4", "80": "0.2", "100": "0.0",
}

const STATE_FILE = "user://heishenhua_launcher_state.json"
const ENV_FILE   = "user://launch_config.env"

# v4: 新增 difficulty (dmg),首次默认正常(1.0);升版强制 re-default。
# v5: 中档 texmax 512→480(512 部分场景闪退);旧存档的 512 不在列表里,升版重置。
# v6: 难度移入二级"修改/作弊"页, 改为"减伤%"(reduce); 无敌=减伤100%。旧 dmg 字段废弃。
# v7: 二级页新增资源类作弊开关 (无限血量/法力/气力/酒); freeze 模式。
# v8: 新增定身术无冷却 (skill_cd); force_return 模式 (强制 _IsOk_定身术 getter=true)。
# v9: 删掉无限血量 (inf_hp) — 护血用减伤·无敌即可, 更干净 (freeze 血量会闪一下)。
const SCHEMA_VERSION = 9

var _state = {
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
}

# 主菜单 / 二级作弊页 (两个 CenterContainer, 切换 visible)。
var _main_page  = null
var _cheat_page = null
var _main_first_focus  = null
var _cheat_first_focus = null
var _first_focus = null


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
	# Godot 3 的 Image.load 需要导入过的资源, 没导入用 File 读 buffer + load_png_from_buffer。
	var bg_path = "res://launcher_bg.png"
	var bg = null
	var f = File.new()
	if f.file_exists(bg_path):
		var img = Image.new()
		var err = img.load(bg_path)
		if err == OK:
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

	# 左下角 credits — 作者名按原文保留, 不翻译。
	var credits = VBoxContainer.new()
	credits.add_constant_override("separation", 2)
	credits.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lines = ["游戏作者: Bili 火山哥哥",
				 "美术作者: Bili 林学学LinkLin",
				 "移植作者: Bili 解腻Jenny"]
	for line in lines:
		var lbl = Label.new()
		lbl.text = line
		lbl.add_color_override("font_color", Color(1, 1, 1, 0.9))
		_apply_outline(lbl, 3)
		credits.add_child(lbl)
	credits.set_anchors_and_margins_preset(Control.PRESET_BOTTOM_LEFT)
	credits.margin_left = 18
	credits.margin_top = -118
	credits.margin_right = 560
	credits.margin_bottom = -14
	add_child(credits)

	_main_page = CenterContainer.new()
	_main_page.set_anchors_and_margins_preset(Control.PRESET_WIDE)
	add_child(_main_page)
	_main_page.add_child(_build_main_page())

	_cheat_page = CenterContainer.new()
	_cheat_page.set_anchors_and_margins_preset(Control.PRESET_WIDE)
	_cheat_page.visible = false
	add_child(_cheat_page)
	_cheat_page.add_child(_build_cheat_page())

	_first_focus = _main_first_focus

	set_process_input(true)
	call_deferred("_grab_initial_focus")
	push_warning("[HSH] LauncherUI mounted (launch_count=%d, last=%s)" % [
		_state.launch_count, _state.last_action])
	# 诊断: 列出当前所有 connected joypad, godot 看不到就是 input 没接通。
	push_warning("[HSH] connected joypads: %s" % str(Input.get_connected_joypads()))


# 诊断: log 所有 input 事件, 排查 "按了没反应" 是 SDL/godot 没收到 event,
# 还是收到但 InputMap action 没命中。
func _input(event):
	# 作弊页按 B(ui_cancel) = 返回主菜单。
	if event.is_action_pressed("ui_cancel") and _cheat_page and _cheat_page.visible:
		_on_back_to_main()
		get_tree().set_input_as_handled()
		return
	if event is InputEventJoypadButton:
		push_warning("[HSH] JoypadButton device=%d button=%d pressed=%s" % [
			event.device, event.button_index, str(event.pressed)])
	elif event is InputEventJoypadMotion:
		if abs(event.axis_value) > 0.5:
			push_warning("[HSH] JoypadMotion device=%d axis=%d value=%.2f" % [
				event.device, event.axis, event.axis_value])
	elif event is InputEventKey:
		push_warning("[HSH] Key scancode=%d pressed=%s" % [event.scancode, str(event.pressed)])


# 主菜单页: 画面设置 + 换键 + [修改/作弊▸] + 开始 + 返回主菜单。难度已移入作弊页。
func _build_main_page():
	var box = VBoxContainer.new()
	box.rect_min_size = Vector2(576, 540)
	box.alignment = BoxContainer.ALIGN_CENTER
	box.add_constant_override("separation", 10)

	box.add_child(_make_title("像素黑神话启动器"))
	box.add_child(_make_subtitle("检测到 %d×%d" % [OS.get_window_size().x, OS.get_window_size().y]))
	box.add_child(_make_separator())

	var res_labels = {"auto": "跟随系统", "640x480": "640×480",
		"720x720": "720×720", "960x540": "960×540", "960x720": "960×720",
		"1280x720": "1280×720"}
	var texmax_labels = {"384": "低 (384)", "480": "中 (480)",
		"720": "高 (720)", "0": "极致 (不限)"}
	var toggle_labels = {"off": "关", "on": "开"}

	box.add_child(_make_row("渲染分辨率:", RESOLUTIONS, _state.resolution, res_labels, "resolution"))
	box.add_child(_make_row("画面质量:", TEXMAX, _state.texmax, texmax_labels, "texmax"))
	box.add_child(_make_row("换 A/B:", TOGGLES, _state.swap_ab, toggle_labels, "swap_ab"))
	box.add_child(_make_row("换 X/Y:", TOGGLES, _state.swap_xy, toggle_labels, "swap_xy"))

	box.add_child(_make_separator())
	box.add_child(_make_button("修改 / 作弊  ▶", "_on_open_cheats"))
	var start_btn = _make_button("开始游戏", "_on_start_game")
	box.add_child(start_btn)
	box.add_child(_make_button("返回主菜单", "_on_quit_menu"))

	_main_first_focus = start_btn
	return box


# 二级"修改/作弊"页: 减伤(含无敌=100%) + 开始(直接启动) + 返回上一页。
# 资源类作弊(无限血/法力/气力/酒/豆)逐项验证后追加到这里。
func _build_cheat_page():
	var box = VBoxContainer.new()
	box.rect_min_size = Vector2(576, 540)
	box.alignment = BoxContainer.ALIGN_CENTER
	box.add_constant_override("separation", 10)

	box.add_child(_make_title("修改 / 作弊"))
	box.add_child(_make_separator())

	var reduce_labels = {"0": "关", "20": "减伤 20%", "40": "减伤 40%",
		"60": "减伤 60%", "80": "减伤 80%", "100": "无敌 (减伤100%)"}
	var toggle_labels = {"off": "关", "on": "开"}
	var reduce_row = _make_row("减伤:", REDUCE, _state.reduce, reduce_labels, "reduce")
	box.add_child(reduce_row)
	box.add_child(_make_row("无限法力:", TOGGLES, _state.inf_mp,   toggle_labels, "inf_mp"))
	box.add_child(_make_row("无限气力:", TOGGLES, _state.inf_sta,  toggle_labels, "inf_sta"))
	box.add_child(_make_row("无限酒:",   TOGGLES, _state.inf_wine, toggle_labels, "inf_wine"))
	box.add_child(_make_row("定身术无冷却:", TOGGLES, _state.skill_cd, toggle_labels, "skill_cd"))

	box.add_child(_make_separator())
	box.add_child(_make_button("开始游戏", "_on_start_game"))
	box.add_child(_make_button("返回", "_on_back_to_main"))

	# 首焦点 = 减伤行的按钮 (HBox 第 2 个子节点), 进页面就能左右调。
	_cheat_first_focus = reduce_row.get_child(1)
	return box


# 主菜单 → 作弊页。
func _on_open_cheats():
	_main_page.visible = false
	_cheat_page.visible = true
	if _cheat_first_focus:
		_cheat_first_focus.grab_focus()


# 作弊页 → 主菜单 (返回按钮 / B 键)。
func _on_back_to_main():
	_cheat_page.visible = false
	_main_page.visible = true
	if _main_first_focus:
		_main_first_focus.grab_focus()


# Godot 3 用 add_color_override / add_constant_override (无 theme 前缀)。
func _apply_outline(node, size = 4):
	# Godot 3 outline modulate; Label 3.5 用 font_color_shadow + outline_size。
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
	label.add_color_override("font_color", Color.white)
	# 标题用更大的字号 (单独 DynamicFont, 不影响主题默认 22)。
	var path = "res://launcher_font_zh.ttf"
	var f = File.new()
	if f.file_exists(path):
		var dd = DynamicFontData.new()
		dd.font_path = path
		dd.antialiased = false
		var df = DynamicFont.new()
		df.font_data = dd
		df.size = 40
		df.use_filter = false
		label.add_font_override("font", df)
	_apply_outline(label, 6)
	return label


func _make_subtitle(text):
	var label = Label.new()
	label.text = text
	label.align = Label.ALIGN_CENTER
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


# Godot 3 字体: DynamicFontData (持 ttf bytes) + DynamicFont (size + AA)。
# 像素字体 antialiased = false + use_filter = false, 保留 1-px 边缘。
func _install_font():
	var path = "res://launcher_font_zh.ttf"
	var f = File.new()
	if not f.file_exists(path):
		return
	var dyn_data = DynamicFontData.new()
	dyn_data.font_path = path
	dyn_data.antialiased = false
	var dyn = DynamicFont.new()
	dyn.font_data = dyn_data
	dyn.size = 22
	dyn.use_filter = false
	var t = Theme.new()
	t.default_font = dyn
	self.theme = t


func _portrait_rotate(win):
	anchor_right = 0
	anchor_bottom = 0
	rect_size = Vector2(win.y, win.x)
	rect_rotation = 90
	rect_position = Vector2(win.x, 0)
	push_warning("[HSH] portrait panel %dx%d → UI rotated 90°" % [win.x, win.y])


# 关键: 先清掉所有 joypad button events on ui_accept/cancel, 再绑我们要的。
# Godot 3 default + frt 自带可能让 B 也触发 ui_accept = "AB 都确定"。
# 同 Godot 4 版本的策略, API 略不同。
func _fix_joypad_action_bindings():
	var bindings = {
		"ui_accept": JOY_BUTTON_0,        # A in Godot 3 (Xbox A / Switch B 物理键, 取决于布局)
		"ui_cancel": JOY_BUTTON_1,        # B
		"ui_up":     JOY_DPAD_UP,
		"ui_down":   JOY_DPAD_DOWN,
		"ui_left":   JOY_DPAD_LEFT,
		"ui_right":  JOY_DPAD_RIGHT,
	}
	for action in bindings:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		# 清 joypad button 类型, 保留 Key fallback
		for ev in InputMap.get_action_list(action):
			if ev is InputEventJoypadButton:
				InputMap.action_erase_event(action, ev)
		var btn_idx = bindings[action]
		var event = InputEventJoypadButton.new()
		event.button_index = btn_idx
		event.device = -1
		InputMap.action_add_event(action, event)
	push_warning("[HSH] joypad action bindings installed (cleared defaults first)")


func _grab_initial_focus():
	if _first_focus:
		_first_focus.grab_focus()


func _on_start_game():
	push_warning("[HSH] Start Game pressed")
	_on_action("StartGame", EXIT_START_GAME)


func _on_quit_menu():
	push_warning("[HSH] Quit to Menu pressed")
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
	f.store_string("# 像素黑神话启动器 生成; launcher.sh 在退出码 42 时 source.\n")
	f.store_string("HSH_WIDTH=%s\n"        % w)
	f.store_string("HSH_HEIGHT=%s\n"       % h)
	f.store_string("HSH_TEXMAX=%s\n"       % _state.texmax)
	# 减伤% → 玩家承伤倍率 (减伤100%=0.0=无敌); launcher.sh 写入 [[il2cpp_patch]] mult。
	f.store_string("HSH_DMG=%s\n"          % REDUCE_MULT.get(_state.reduce, "1.0"))
	f.store_string("HSH_SWAP_AB=%s\n"      % _state.swap_ab)
	f.store_string("HSH_SWAP_XY=%s\n"      % _state.swap_xy)
	# 资源类作弊开关 → launcher.sh 写 freeze 类 [[il2cpp_patch]] stanza。
	f.store_string("HSH_INF_MP=%s\n"       % _state.inf_mp)
	f.store_string("HSH_INF_STA=%s\n"      % _state.inf_sta)
	f.store_string("HSH_INF_WINE=%s\n"     % _state.inf_wine)
	f.store_string("HSH_SKILL_CD=%s\n"     % _state.skill_cd)
	f.store_string("HSH_LAUNCH_COUNT=%d\n" % _state.launch_count)
	f.close()


func _write_input_remap_cfg():
	var godot_dir = OS.get_executable_path().get_base_dir()
	var path = godot_dir + "/input_remap.cfg"
	var f = File.new()
	if f.open(path, File.WRITE) != OK:
		return
	f.store_string("# 像素黑神话启动器 生成 (任天堂布局 UI 映射, 跟游戏映射无关).\n\n")
	f.store_string("[buttons]\n")
	f.store_string("a = BUTTON_B\n")
	f.store_string("b = BUTTON_A\n")
	f.store_string("x = BUTTON_X\n")
	f.store_string("y = BUTTON_Y\n")
	f.close()
