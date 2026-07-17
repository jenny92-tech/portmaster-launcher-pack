# APP Manager — PortMaster 端口管理器 UI。
#
# 主页是标准横屏 APP 结构: 顶栏、中间可滚动列表、右侧快捷操作区。列表项用两行同时
# 说清脚本、数据目录、图片数和这个 SH 自己缺少的 Runtime。残留清理和精简后的
# 详情各自一页。
#
# 复用 _kit/launcher_base.gd 里天然通用的部分(字体/中英切换/手柄绑定/描边/
# 竖屏旋转/状态存档), 但不用它那套"开始游戏/返回主菜单"的启动器页面模型。
#
# 删除不在 Godot 里做: 卡是 exFAT 以 uid=0 挂的, port 脚本靠 $ESUDO 提权, 而
# Godot 是它的子进程拿不到 root。UI 只产出一份 plan.txt，再调用 launcher.sh 的
# 受控执行模式用 $ESUDO 落地；FRT 保持运行，完成后只重扫数据并替换列表。每次操作仍有
# 可审计的纯文本计划和 log.txt。

extends "res://launcher_base.gd"

const Scan = preload("res://scan.gd")

const SCHEMA_VERSION = 1

var _env    = {}
var _scan   = null
var _sc     = null
var _plan   = []
var _result = []
var _detail_btn = null
var _ui_scale = 1.0
var _edge = 14
var _header_h = 52
var _footer_h = 44
var _row_h = 60
var _check_off = null
var _check_on = null
var _uninstall_btn = null
var _junk_clean_btn = null
var _trash_restore_btn = null
var _trash_delete_btn = null
var _nav_hold_action = ""
var _nav_repeat_left = 0.0
var _font_data_cache = null
var _font_cache = {}
var _apply_pid = -1
var _apply_return_to = ""
var _apply_plan_path = ""
var _size_cache = {}
var _size_pid = -1
var _size_rescan_requested = false

const NAV_REPEAT_DELAY = 0.36
const NAV_REPEAT_INTERVAL = 0.09
const MIN_VIEWPORT = Vector2(640, 480)
const MAX_LAYOUT_SCALE = 1.50
const LARGE_SCREEN_GROWTH = 0.50

var _home  = null   # APP 列表页
var _junk  = null   # 残留清理页
var _trash = null   # 回收站页
var _envp  = null   # 环境详情页
var _conf  = null   # 确认页
var _confirm_back = null


func _port_state_file():
	return "user://appmanager_state.json"


func _port_state():
	return {"schema_version": SCHEMA_VERSION, "ui_lang": "zh"}


func _port_credits():
	return []


func _port_strings():
	return {
		"title":      {"en": "APP Manager",       "zh": "APP Manager"},
		"junk_title": {"en": "Clean Leftovers",   "zh": "残留清理"},
		"trash_title":{"en": "Trash",             "zh": "回收站"},
		"env_title":  {"en": "PortMaster Environment", "zh": "PortMaster 环境"},
		"conf_title": {"en": "Confirm",           "zh": "确认"},
		"detail":     {"en": "Details",           "zh": "详情"},
		"uninstall":  {"en": "Uninstall (%d)",    "zh": "卸载 (%d)"},
		"uninstall_sized":{"en": "Uninstall (%d · %s)", "zh": "卸载 (%d · %s)"},
		"go_junk":    {"en": "Leftovers (%d)",    "zh": "残留清理 (%d)"},
		"go_trash":   {"en": "Trash (%d)",        "zh": "回收站 (%d)"},
		"go_trash_marked":{"en": "Trash (%d)  ●", "zh": "回收站 (%d)  ●"},
		"clean_now":  {"en": "Clean Selected",    "zh": "清理选中"},
		"clean_sized":{"en": "Clean %d · %s", "zh": "清理 %d · %s"},
		"sel_all":    {"en": "Select All",       "zh": "全选"},
		"sel_none":   {"en": "Select None",       "zh": "全不选"},
		"back":       {"en": "Back",              "zh": "返回"},
		"quit":       {"en": "Quit",              "zh": "退出"},
		"ok":         {"en": "Yes, do it",        "zh": "确认执行"},
		"cancel":     {"en": "Cancel",            "zh": "取消"},
		"no_ports":   {"en": "No ports found.",   "zh": "没有找到任何端口。"},
		"no_junk":    {"en": "No leftovers found.",
		               "zh": "没有发现可清理的残留项。"},
		"no_trash":   {"en": "Trash is empty.",    "zh": "回收站是空的。"},
		"nothing":    {"en": "Nothing selected.", "zh": "没有选中任何项目。"},
		"no_dir":     {"en": "No game data required", "zh": "无需游戏数据"},
		"game_files_missing":{"en": "Game files missing", "zh": "游戏文件缺失"},
		"orphan_dir": {"en": "Leftover folders",  "zh": "残留目录"},
		"orphan_img": {"en": "Leftover images",   "zh": "残留图片"},
		"will_trash": {"en": "Move to trash (recoverable):",
		               "zh": "以下项目将移入回收站（可恢复）："},
		"will_inst":  {"en": "Repair Jenny game launcher:",
		               "zh": "将修复 Jenny 移植游戏启动器："},
		"will_empty": {"en": "Permanently empty trash:",
		               "zh": "将永久清空回收站："},
		"will_restore":{"en": "Restore everything in Trash:",
		               "zh": "将放回回收站内的全部内容："},
		"will_restore_selected":{"en": "Restore selected items:",
		               "zh": "将放回选中项目："},
		"trash_note": {"en": "Items go to Trash first.",
		               "zh": "删除内容会先进入回收站。"},
		"result":     {"en": "Action needed",     "zh": "操作未完成"},
		"fail_move":  {"en": "Could not remove: %s", "zh": "无法删除：%s"},
		"fail_repair":{"en": "Launcher repair failed. Please retry.",
		               "zh": "启动器修复失败，请重试。"},
		"fail_repair_files":{"en": "Launcher repair files are missing.",
		               "zh": "启动器修复文件缺失。"},
		"fail_empty_trash":{"en": "Trash could not be emptied. Please retry.",
		               "zh": "回收站无法清空，请重试。"},
		"fail_restore":{"en": "Could not restore: %s. The item remains in Trash.",
		               "zh": "无法放回：%s，内容仍保留在回收站。"},
		"fail_delete":{"en": "Could not permanently delete: %s.",
		               "zh": "无法彻底删除：%s。"},
		"fail_operation":{"en": "The operation could not be completed. Please retry.",
		               "zh": "操作无法完成，请重试。"},
		"empty_trash":{"en": "Empty Trash",       "zh": "清空回收站"},
		"restore_trash":{"en": "Restore All",      "zh": "全部放回"},
		"restore_selected":{"en": "Restore Selected", "zh": "放回选中"},
		"restore_selected_count":{"en": "Restore Selected (%d)", "zh": "放回选中 (%d)"},
		"delete_selected":{"en": "Delete Permanently", "zh": "彻底删除选中"},
		"delete_selected_sized":{"en": "Delete %d · %s", "zh": "彻底删除 %d · %s"},
		"will_delete_selected":{"en": "Permanently delete selected items:",
		               "zh": "将彻底删除选中项目（无法恢复）："},
		"clear_all":   {"en": "Clear All",        "zh": "全部清除"},
		"clear_all_sized":{"en": "Clear All · %s", "zh": "全部清除 · %s"},
		"size_about": {"en": "About %s",          "zh": "约 %s"},
		"size_calculating":{"en": "Calculating size…", "zh": "正在计算大小…"},
		"trash_script":{"en": "Launcher",          "zh": "启动项"},
		"trash_data": {"en": "Game data",         "zh": "游戏数据"},
		"trash_image":{"en": "Image",             "zh": "图片"},
		"working":    {"en": "Working…",          "zh": "处理中…"},
		"folder":     {"en": "Folder",            "zh": "目录"},
		"images":     {"en": "Images",            "zh": "图片"},
		"ports_count":{"en": "Apps",              "zh": "APP 数量"},
		"junk_count": {"en": "Leftovers",         "zh": "残留项"},
		"scripts_dir":{"en": "SH folder ($0 folder)", "zh": "SH 目录（$0 目录）"},
		"data_dir":   {"en": "Data folder (directory/ports)", "zh": "Data 目录（directory/ports）"},
		"portmaster_dir":{"en": "PortMaster folder (controlfolder)", "zh": "PortMaster 目录（controlfolder）"},
		"runtime_dir":{"en": "Runtime folder (controlfolder/libs)", "zh": "Runtime 目录（controlfolder/libs）"},
		"key_paths": {"en": "Key paths",          "zh": "关键路径"},
		"environment_values":{"en": "Environment values", "zh": "环境变量"},
		"cfw_env":   {"en": "Firmware (CFW_NAME)", "zh": "固件（CFW_NAME）"},
		"resolution_env":{"en": "Display resolution", "zh": "显示分辨率"},
		"device_arch_env":{"en": "Architecture (DEVICE_ARCH)", "zh": "设备架构（DEVICE_ARCH）"},
		"device_env":{"en": "Controller ID (DEVICE)", "zh": "手柄 ID（DEVICE）"},
		"param_device_env":{"en": "Device profile (param_device)", "zh": "设备配置（param_device）"},
		"analog_sticks_env":{"en": "Analog sticks (ANALOGSTICKS)", "zh": "摇杆数（ANALOGSTICKS）"},
		"lowres_env":{"en": "Low resolution mode (LOWRES)", "zh": "低分辨率（LOWRES）"},
		"cur_tty_env":{"en": "Display terminal (CUR_TTY)", "zh": "显示终端（CUR_TTY）"},
		"sdl_controller_file_env":{"en": "Controller database (SDL_GAMECONTROLLERCONFIG_FILE)", "zh": "手柄库（SDL_GAMECONTROLLERCONFIG_FILE）"},
		"esudo_env": {"en": "Privilege helper (ESUDO)", "zh": "提权命令（ESUDO）"},
		"gptokeyb_env":{"en": "Controller helper (GPTOKEYB)", "zh": "手柄映射（GPTOKEYB）"},
		"path_env":  {"en": "Command search path (PATH)", "zh": "命令搜索（PATH）"},
		"ld_library_path_env":{"en": "Library search path (LD_LIBRARY_PATH)", "zh": "动态库搜索（LD_LIBRARY_PATH）"},
		"xdg_config_home_env":{"en": "Config root (XDG_CONFIG_HOME)", "zh": "配置根（XDG_CONFIG_HOME）"},
		"xdg_data_home_env":{"en": "Data root (XDG_DATA_HOME)", "zh": "数据根（XDG_DATA_HOME）"},
		"free_space":{"en": "Free space",         "zh": "剩余空间"},
		"installed_runtimes":{"en": "Installed Runtimes", "zh": "已安装 Runtime"},
		"none_installed":{"en": "None",           "zh": "无"},
		"unavailable":{"en": "Unavailable",       "zh": "无法获取"},
		"runtime_info":{"en": "Jenny Port Launcher\nRepair", "zh": "Jenny 移植游戏\n启动器修复"},
		"maintenance":{"en": "Quick Tools",       "zh": "快捷工具"},
		"actions":    {"en": "Actions",           "zh": "操作"},
		"missing_runtime":{"en": "Missing Runtime: %s", "zh": "缺少 Runtime: %s"},
		"repair_launcher":{"en": "Repair Launcher", "zh": "修复启动器"},
	}


# ── 生命周期 ─────────────────────────────────────────────────────────
func _build_pages():
	_update_metrics()
	_load_check_icons()
	set_process(true)
	if _scan == null:
		_load_env()
		_load_result()
		_sc = Scan.new()
		_sc.setup(_env)
		_scan = _sc.scan()
		_dump_scan()
		_load_size_cache()

	_plan = []
	# 切换语言时 base 会释放所有页面再调一次这里；不清空引用会打开已 queue_free 的旧页面。
	_home = null
	_junk = null
	_trash = null
	_envp = null
	_conf = null
	_confirm_back = null
	_uninstall_btn = null
	_junk_clean_btn = null
	_trash_restore_btn = null
	_trash_delete_btn = null
	_build_home()
	_set_home(_pg(_home))
	_add_detail_button()
	_start_size_scan()


# Godot/FRT 默认只在按下那一刻做一次 GUI 焦点导航；部分掌机的 D-pad
# 又不产生键盘 echo。自己跟踪按住状态，让主列表和残留列表能持续移动；
# ScrollContainer.follow_focus 会随新焦点自动滚动。
func _input(event):
	if _apply_pid > 0:
		# helper 在后台运行时页面持续绘制“处理中”，但不接受第二次操作。
		get_tree().set_input_as_handled()
		return
	if event.is_action_pressed("ui_cancel") and is_instance_valid(_confirm_back) and _home_page != _pg(_home):
		_cancel_confirm()
		get_tree().set_input_as_handled()
		return
	._input(event)
	if event.is_action_pressed("ui_up"):
		_start_nav_hold("ui_up")
	elif event.is_action_pressed("ui_down"):
		_start_nav_hold("ui_down")
	elif _nav_hold_action != "" and event.is_action_released(_nav_hold_action):
		_nav_hold_action = ""


func _start_nav_hold(action):
	# gptokeyb 的 repeat 会继续送同一方向的 pressed 事件。只在方向刚开始时
	# 设置首次延迟，否则每个重复事件都把 360ms 计时器重置，永远不会连续移动。
	if _nav_hold_action == action:
		return
	_nav_hold_action = action
	_nav_repeat_left = NAV_REPEAT_DELAY


func _process(delta):
	_poll_size_process()
	if _apply_pid > 0:
		_poll_apply_process()
		return
	if _nav_hold_action == "":
		return
	if not Input.is_action_pressed(_nav_hold_action):
		_nav_hold_action = ""
		return
	_nav_repeat_left -= delta
	if _nav_repeat_left <= 0.0:
		_repeat_list_focus(-1 if _nav_hold_action == "ui_up" else 1)
		_nav_repeat_left = NAV_REPEAT_INTERVAL


func _repeat_list_focus(direction):
	var current = get_viewport().gui_get_focus_owner()
	if current == null or not (current is Button):
		return
	# 右栏使用独立的显式焦点链。按住上/下时沿右栏连续移动，遇到禁用按钮会跳过，
	# 到两端停住；绝不按几何距离横跳进左侧列表。
	var nav_key = "nav_up" if direction < 0 else "nav_down"
	if current.has_meta(nav_key):
		var candidate = current.get_meta(nav_key)
		while is_instance_valid(candidate) and candidate != current and candidate.disabled:
			candidate = candidate.get_meta(nav_key) if candidate.has_meta(nav_key) else current
		if is_instance_valid(candidate) and not candidate.disabled:
			candidate.grab_focus()
		return
	if not current.has_meta("list_nav"):
		return
	var siblings = current.get_parent().get_children()
	var index = siblings.find(current) + direction
	while index >= 0 and index < siblings.size():
		var candidate = siblings[index]
		if candidate is Button and candidate.visible and not candidate.disabled and candidate.has_meta("list_nav"):
			candidate.grab_focus()
			return
		index += direction


# 启动器 base 默认在右下角放 QQ 群，这里是工具型 APP，不显示这个角标。
func _build_contact_label():
	var spacer = Control.new()
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return spacer


func _update_metrics():
	var physical = OS.get_window_size()
	if physical.y > physical.x:
		physical = Vector2(physical.y, physical.x)
	if physical.x <= 0 or physical.y <= 0:
		physical = MIN_VIEWPORT
	# 画布直接使用设备原生分辨率，字体由 DynamicFont 按最终像素尺寸生成，
	# 不再缩放一张 640×480 的字体贴图。物理尺寸每增加 100%，控件只增加
	# 50%，剩余空间用于显示更多 Item。960×720 约为 125%，1024×960 约为 130%。
	var raw_scale = max(1.0, min(physical.x / MIN_VIEWPORT.x,
		physical.y / MIN_VIEWPORT.y))
	var desired_growth = 1.0 + (raw_scale - 1.0) * LARGE_SCREEN_GROWTH
	_ui_scale = clamp(desired_growth, 1.0, MAX_LAYOUT_SCALE)
	_edge = _scaled(14, 10)
	_header_h = _scaled(52, 42)
	_footer_h = _scaled(44, 36)
	_row_h = _scaled(60, 48)


func _scaled(value, minimum = 1):
	return max(minimum, int(round(value * _ui_scale)))


# 环境详情可能有几十个 Runtime Item。base 每次 _font() 都新建一个
# DynamicFont，会让同一份 13MB 中文字体为每个 Label 重复建立字形缓存；
# TrimUI 1GB 内存上会直接触发 OOM。此 APP 按字号共享 DynamicFont，不改全局 base。
func _font(size):
	var key = int(size)
	if _font_cache.has(key):
		return _font_cache[key]
	if _font_data_cache == null:
		var path = "res://launcher_font_zh.ttf"
		var file = File.new()
		if not file.file_exists(path):
			return null
		_font_data_cache = DynamicFontData.new()
		_font_data_cache.font_path = path
		_font_data_cache.antialiased = true
	var font = DynamicFont.new()
	font.font_data = _font_data_cache
	font.size = key
	_font_cache[key] = font
	return font


# 手工 PCK 没有编辑器产生的 .stex，原图不能 preload；跟 base 加载背景一样直接读 Image。
func _load_check_icons():
	if _check_off != null and _check_on != null:
		return
	_check_off = _image_texture("res://check_off.png")
	_check_on = _image_texture("res://check_on.png")


func _image_texture(path):
	var image = Image.new()
	if image.load(path) != OK:
		return null
	var texture = ImageTexture.new()
	texture.create_from_image(image)
	return texture


func _load_env():
	var path = OS.get_environment("PAM_ENV")
	if path == "":
		return
	var f = File.new()
	if f.open(path, File.READ) != OK:
		return
	var parsed = JSON.parse(f.get_as_text())
	f.close()
	if parsed.error == OK and typeof(parsed.result) == TYPE_DICTIONARY:
		_env = parsed.result


# 大游戏目录在真机上遍历需要数秒，由 Shell helper 在后台用 du
# 统计。UI 只读原子替换后的 TSV 缓存，永远不在渲染线程遍历目录。
func _load_size_cache():
	var path = str(_env.get("size_file", ""))
	if path == "":
		return
	var f = File.new()
	if f.open(path, File.READ) != OK:
		return
	var next_cache = {}
	for line in f.get_as_text().split("\n"):
		var tab = line.find("\t")
		if tab <= 0:
			continue
		var raw_size = line.substr(0, tab)
		var item_path = line.substr(tab + 1, line.length() - tab - 1)
		if raw_size.is_valid_integer() and item_path != "":
			next_cache[item_path] = int(raw_size)
	f.close()
	_size_cache = next_cache


func _start_size_scan():
	if _size_pid > 0:
		return
	if not _size_rescan_requested and not _has_unknown_size_paths():
		return
	var helper = str(_env.get("apply_script", ""))
	var helper_file = File.new()
	if helper == "" or not helper_file.file_exists(helper):
		return
	_size_rescan_requested = false
	_size_pid = OS.execute("/bin/bash", PoolStringArray([helper, "--scan-sizes"]), false)
	if _size_pid <= 0:
		_size_pid = -1
		return
	print("[PAM] size scan started pid=%d" % _size_pid)


func _poll_size_process():
	if _size_pid <= 0 or OS.is_process_running(_size_pid):
		return
	print("[PAM] size scan finished pid=%d" % _size_pid)
	_size_pid = -1
	_load_size_cache()
	_refresh_size_labels()
	_refresh_counts()
	if _size_rescan_requested:
		_start_size_scan()


# 把扫描结果落盘。这是这个 APP 唯一会毁数据的判定, "跑起来了"不等于"判对了" ——
# 有了这份 dump 才能拿设备上的真实结果去对账(也方便用户报错时把它发过来)。
func _dump_scan():
	var gd = _env.get("gamedir", "")
	if gd == "":
		return
	var owns = {}
	for p in _scan.ports:
		owns[p.script] = p.dir
	var f = File.new()
	if f.open(gd + "/conf/scan_debug.json", File.WRITE) != OK:
		return
	f.store_string(JSON.print({
		"owns": owns,
		"refcount": _scan.refcount,
		"orphan_dirs": _scan.orphan_dirs,
		"orphan_images": _scan.orphan_images,
		"dead_scripts": _scan.dead_scripts,
		"runtimes_have": _scan.runtimes.have,
		"runtimes_missing": _scan.runtimes.missing,
	}, "  "))
	f.close()


func _load_result():
	var path = _env.get("result_file", "")
	if path == "":
		return
	var f = File.new()
	if not f.file_exists(path):
		return
	if f.open(path, File.READ) != OK:
		return
	for line in f.get_as_text().split("\n"):
		var raw = line.strip_edges()
		if _result_message(raw) != "":
			_result.append(raw)
	f.close()
	Directory.new().remove(path)     # 成功记录不展示；失败只展示一次


func _result_message(line):
	if line == "":
		return ""
	var parts = line.split("\t", false)
	if parts.size() >= 2 and parts[0] == "FAIL":
		match parts[1]:
			"trash":
				return _t("fail_move") % (_display_port_name(parts[2]) if parts.size() >= 3 else "")
			"repair":
				return _t("fail_repair")
			"repair_files":
				return _t("fail_repair_files")
			"empty_trash":
				return _t("fail_empty_trash")
			"restore":
				return _t("fail_restore") % (_display_port_name(parts[2]) if parts.size() >= 3 else "")
			"delete":
				return _t("fail_delete") % (_display_port_name(parts[2]) if parts.size() >= 3 else "")
			_:
				return _t("fail_operation")
	# 兼容旧版本留下的 FAIL 文本；旧的成功明细直接忽略并刷新。
	return _t("fail_operation") if line.begins_with("FAIL") else ""


# ── 主页: APP 列表 + 底部动作条 ──────────────────────────────────────
func _build_home():
	var box = _page(_t("title"), true)
	_home = box

	if _result.size() > 0:
		box.add_child(_label(_t("result") + ":", 18, Color(1.0, 0.55, 0.48)))
		for raw in _result:
			box.add_child(_label("  " + _result_message(raw), 16, Color(1.0, 0.72, 0.68)))
		box.add_child(_make_separator())

	if _scan.ports.empty():
		box.add_child(_label(_t("no_ports"), 20))

	var first = null
	for p in _scan.ports:
		var info = ""
		var warning = false
		if p.claimed_dir != "" and not p.dir_exists:
			info = _t("game_files_missing")
			warning = true
		elif p.dir == "":
			info = _t("no_dir")
		else:
			info = "%s: %s/" % [_t("folder"), p.dir]
		if p.images.size() > 0:
			info += "  ·  %s: %d" % [_t("images"), p.images.size()]
		var missing_rt = _missing_runtime_for_script(p.script)
		if missing_rt != "":
			info += "  ·  " + (_t("missing_runtime") % missing_rt)
			warning = true
		var size_paths = [_env.scripts_dir + "/" + p.script]
		for image in p.images:
			size_paths.append(_env.images_dir + "/" + image)
		if p.dir != "" and p.dir_exists:
			size_paths.append(_env.gamedirs_dir + "/" + p.dir)
		var b = _check_btn(_display_port_name(p.script), info,
			{"port": p, "size_paths": size_paths}, warning)
		box.add_child(b)
		if first == null:
			first = b

	var side_first = _add_home_sidebar(box)
	# 首焦点直接记住第一个端口按钮, 不要靠 child_count 减偏移量去数 —— 动作条多加
	# 一个提示 label 就会错位, 最坏情况首焦点落在"退出"上, 用户一按 A 就直接退了。
	if first != null:
		_focus(box, first)
	else:
		_focus(box, side_first)
	_open(box)


# 横屏的常用操作都放在右侧：列表焦点按一次右即可进入，不必一直
# 往下走到列表尾部。两两成行保证 854×480 也能一屏放下。
func _add_home_sidebar(box):
	_footer(box).visible = false
	var side = _sidebar(box)
	var rt = _env.get("bundled_runtime", "frt_3.6")
	var have = rt in _scan.runtimes.have
	var n_junk = _scan.orphan_dirs.size() + _scan.orphan_images.size()

	var heading = _label(_t("maintenance"), 20)
	heading.align = Label.ALIGN_CENTER
	side.add_child(heading)
	side.add_child(_make_separator())

	_uninstall_btn = _side_btn(_t("uninstall") % 0, "_confirm_uninstall", [box])
	_uninstall_btn.set_meta("counter", true)
	_uninstall_btn.disabled = true
	side.add_child(_uninstall_btn)
	var selection = _side_pair()
	var select_all = _side_btn(_t("sel_all"), "_sel_all", [box])
	selection.add_child(select_all)
	var select_none = _side_btn(_t("sel_none"), "_sel_none", [box])
	selection.add_child(select_none)
	side.add_child(selection)
	side.add_child(_make_separator())

	var junk_btn = _side_btn(_t("go_junk") % n_junk, "_go_junk")
	side.add_child(junk_btn)
	var trash_count = _trash_entries().size()
	var trash_btn = _side_btn(
		(_t("go_trash_marked") if trash_count > 0 else _t("go_trash")) % trash_count,
		"_go_trash")
	if trash_count > 0:
		trash_btn.add_color_override("font_color", Color(1.0, 0.82, 0.46))
	side.add_child(trash_btn)

	var spacer = Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side.add_child(spacer)
	var repair = _side_btn(_t("runtime_info"), "_confirm_rt", [rt])
	repair.rect_min_size.y = _scaled(52, 44)
	if not have:
		repair.add_color_override("font_color", Color(1.0, 0.72, 0.52))
	side.add_child(repair)
	var quit = _side_btn(_t("quit"), "_on_quit")
	side.add_child(quit)

	# Godot 的自动几何导航在右栏底部找不到“下一个”时，会横跳回左侧 Item。
	# 显式定义垂直顺序并让两端停住；成对按钮无论从哪一列向下都进入同一项。
	_bind_vertical_column([_uninstall_btn, select_all, junk_btn, trash_btn, repair, quit])
	_set_vertical_neighbors(select_none, _uninstall_btn, junk_btn)
	select_all.focus_neighbour_right = select_none.get_path()
	select_none.focus_neighbour_left = select_all.get_path()
	return select_all


func _bind_vertical_column(buttons):
	for i in range(buttons.size()):
		var up = buttons[max(0, i - 1)]
		var down = buttons[min(buttons.size() - 1, i + 1)]
		_set_vertical_neighbors(buttons[i], up, down)


func _set_vertical_neighbors(button, up, down):
	button.focus_neighbour_top = up.get_path()
	button.focus_neighbour_bottom = down.get_path()
	button.set_meta("nav_up", up)
	button.set_meta("nav_down", down)


func _dir_entries(path):
	var out = []
	var d = Directory.new()
	if d.open(path) != OK:
		return out
	d.list_dir_begin(true, false)
	while true:
		var name = d.get_next()
		if name == "":
			break
		out.append({"name": name, "dir": d.current_is_dir()})
	d.list_dir_end()
	return out


# 回收站页只展示用户能理解的直接项，不展开游戏目录内部文件。
# 与 SH 同名的图片是附属资源，合并到该启动项，避免用户看到重复项。
func _trash_entries():
	var out = []
	var gamedir = str(_env.get("gamedir", "")).strip_edges()
	if gamedir == "":
		return out
	var root = gamedir + "/trash"
	for top in _dir_entries(root):
		var path = root + "/" + top.name
		if top.dir:
			_append_trash_batch(out, path)
		else:
			_append_trash_entry(out, path, top.name, false, "")
	return out


func _append_trash_batch(out, path):
	var probe = Directory.new()
	var script_entries = {}
	var structured = false
	for bucket in ["scripts", "data", "images"]:
		if probe.dir_exists(path + "/" + bucket):
			structured = true

	if structured:
		for item in _dir_entries(path + "/scripts"):
			var entry = _append_trash_entry(out, path + "/scripts/" + item.name,
				item.name, item.dir, "data" if item.dir else "script")
			if not item.dir:
				script_entries[_trash_stem(item.name)] = entry
		for item in _dir_entries(path + "/data"):
			_append_trash_entry(out, path + "/data/" + item.name,
				item.name, item.dir, "data")
		for item in _dir_entries(path + "/images"):
			var stem = _trash_stem(item.name)
			var image_path = path + "/images/" + item.name
			if script_entries.has(stem):
				script_entries[stem].paths.append(image_path)
			else:
				_append_trash_entry(out, image_path, item.name, item.dir, "image")

	var legacy = _dir_entries(path)
	for item in legacy:
		if structured and item.dir and item.name in ["scripts", "data", "images"]:
			continue
		if item.name.to_lower().ends_with(".sh"):
			var entry = _append_trash_entry(out, path + "/" + item.name,
				item.name, item.dir, "script")
			script_entries[_trash_stem(item.name)] = entry
	for item in legacy:
		if structured and item.dir and item.name in ["scripts", "data", "images"]:
			continue
		if item.name.to_lower().ends_with(".sh"):
			continue
		if item.dir:
			_append_trash_entry(out, path + "/" + item.name, item.name, true, "data")
		else:
			var stem = _trash_stem(item.name)
			var image_path = path + "/" + item.name
			if script_entries.has(stem):
				script_entries[stem].paths.append(image_path)
			else:
				_append_trash_entry(out, image_path, item.name, false, "image")


func _append_trash_entry(out, path, name, is_dir, kind):
	if kind == "":
		kind = "data" if is_dir else ("script" if name.to_lower().ends_with(".sh") else "image")
	var title = _display_port_name(name) if kind == "script" else name + ("/" if is_dir else "")
	var entry = {"title": title, "detail": _t("trash_" + kind), "paths": [path]}
	out.append(entry)
	return entry


func _trash_stem(name):
	var dot = name.find_last(".")
	return (name.substr(0, dot) if dot > 0 else name).to_lower()


func _missing_runtime_for_script(script):
	var names = []
	for m in _scan.runtimes.missing:
		if script in m.users:
			names.append(str(m.name))
	names.sort()
	return PoolStringArray(names).join(", ")


# 左上角常驻按钮: 首页进精简详情，其他页返回首页。
func _add_detail_button():
	if is_instance_valid(_detail_btn):
		_detail_btn.text = _t("detail")
		return
	_detail_btn = Button.new()
	_detail_btn.text = _t("detail")
	_detail_btn.rect_min_size = Vector2(_scaled(116, 86), _scaled(44, 38))
	_detail_btn.focus_mode = Control.FOCUS_ALL
	_detail_btn.add_font_override("font", _font(_scaled(20, 15)))
	_apply_outline(_detail_btn, _scaled(3, 2))
	_apply_button_theme(_detail_btn)
	_detail_btn.set_anchors_and_margins_preset(Control.PRESET_TOP_LEFT)
	_detail_btn.margin_left = _edge
	_detail_btn.margin_top = _edge
	_detail_btn.margin_right = _edge + _detail_btn.rect_min_size.x
	_detail_btn.margin_bottom = _edge + _detail_btn.rect_min_size.y
	_detail_btn.connect("pressed", self, "_on_header_left")
	add_child(_detail_btn)


func _on_header_left():
	if _home != null and _pg(_home).visible:
		_go_env()
	elif _conf != null and _pg(_conf).visible:
		_cancel_confirm()
	else:
		_go_home()


# base 的语言按钮尺寸和边距是固定像素，这里与左上角按钮使用同一套自适应尺寸。
func _add_lang_toggle():
	_ui_lang_button = Button.new()
	_ui_lang_button.text = "中" if _state.ui_lang == "en" else "EN"
	_ui_lang_button.rect_min_size = Vector2(_scaled(72, 58), _scaled(44, 38))
	_ui_lang_button.focus_mode = Control.FOCUS_ALL
	_ui_lang_button.add_font_override("font", _font(_scaled(20, 15)))
	_apply_outline(_ui_lang_button, _scaled(3, 2))
	_apply_button_theme(_ui_lang_button)
	_ui_lang_button.set_anchors_and_margins_preset(Control.PRESET_TOP_RIGHT)
	_ui_lang_button.margin_left = -_edge - _ui_lang_button.rect_min_size.x
	_ui_lang_button.margin_top = _edge
	_ui_lang_button.margin_right = -_edge
	_ui_lang_button.margin_bottom = _edge + _ui_lang_button.rect_min_size.y
	_ui_lang_button.connect("pressed", self, "_on_ui_lang_toggle")
	add_child(_ui_lang_button)


# ── 残留清理页: 默认全选, 一键清掉 ───────────────────────────────────
func _go_junk():
	if _junk == null:
		var box = _page(_t("junk_title"), true)
		_junk = box
		var any = false
		var first = null

		if not _scan.orphan_dirs.empty():
			for d in _scan.orphan_dirs:
				var path = _env.gamedirs_dir + "/" + d
				var dir_button = _check_btn(d + "/", _t("orphan_dir"),
					{"path": path, "label": d + "/", "checked": true,
					 "size_paths": [path]})
				box.add_child(dir_button)
				if first == null:
					first = dir_button
				any = true

		if not _scan.orphan_images.empty():
			for img in _scan.orphan_images:
				var image_path = _env.images_dir + "/" + img
				var image_button = _check_btn(img, _t("orphan_img"),
					{"path": image_path, "label": "images/" + img,
					 "checked": true, "size_paths": [image_path]})
				box.add_child(image_button)
				if first == null:
					first = image_button
				any = true

		if not any:
			box.add_child(_label(_t("no_junk"), 21, Color(0.6, 1.0, 0.6)))

		_footer(box).visible = false
		var side = _sidebar(box)
		var heading = _label(_t("actions"), 20)
		heading.align = Label.ALIGN_CENTER
		side.add_child(heading)
		side.add_child(_make_separator())
		_junk_clean_btn = _side_btn(_t("clean_now"), "_confirm_junk", [box])
		var select_all = _side_btn(_t("sel_all"), "_sel_all", [box])
		var select_none = _side_btn(_t("sel_none"), "_sel_none", [box])
		var back = _side_btn(_t("back"), "_go_home")
		_junk_clean_btn.disabled = not any
		select_all.disabled = not any
		select_none.disabled = not any
		side.add_child(_junk_clean_btn)
		side.add_child(select_all)
		side.add_child(select_none)
		var spacer = Control.new()
		spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
		side.add_child(spacer)
		side.add_child(back)
		_bind_vertical_column([_junk_clean_btn, select_all, select_none, back])
		_focus(box, first if first != null else back)
	_refresh_counts()
	_start_size_scan()
	_open(_junk)


# 回收站与残留清理使用同一套勾选模型：放回选中或彻底删除选中，
# 两个操作都不能绕开当前勾选。
func _go_trash():
	if _trash == null:
		var entries = _trash_entries()
		var box = _page("%s (%d)" % [_t("trash_title"), entries.size()], true)
		_trash = box
		var first = null
		if entries.empty():
			box.add_child(_label(_t("no_trash"), 21, Color(0.78, 0.78, 0.84)))
		else:
			for entry in entries:
				var item = {"restore_paths": entry.paths, "label": entry.title,
					"checked": false, "size_paths": entry.paths}
				var button = _check_btn(entry.title, entry.detail, item)
				box.add_child(button)
				if first == null:
					first = button

		_footer(box).visible = false
		var side = _sidebar(box)
		var heading = _label(_t("actions"), 20)
		heading.align = Label.ALIGN_CENTER
		side.add_child(heading)
		side.add_child(_make_separator())
		_trash_restore_btn = _side_btn(_t("restore_selected"),
			"_confirm_restore_selected", [box])
		_trash_delete_btn = _side_btn(_t("delete_selected"),
			"_confirm_delete_selected", [box])
		var selection = _side_pair()
		var select_all = _side_btn(_t("sel_all"), "_sel_all", [box])
		var select_none = _side_btn(_t("sel_none"), "_sel_none", [box])
		selection.add_child(select_all)
		selection.add_child(select_none)
		var back = _side_btn(_t("back"), "_go_home")
		_trash_restore_btn.disabled = true
		_trash_delete_btn.disabled = true
		select_all.disabled = entries.empty()
		select_none.disabled = entries.empty()
		side.add_child(_trash_restore_btn)
		side.add_child(_trash_delete_btn)
		side.add_child(selection)
		var spacer = Control.new()
		spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
		side.add_child(spacer)
		side.add_child(back)
		_bind_vertical_column([_trash_restore_btn, _trash_delete_btn, select_all, back])
		_set_vertical_neighbors(select_none, _trash_delete_btn, back)
		select_all.focus_neighbour_right = select_none.get_path()
		select_none.focus_neighbour_left = select_all.get_path()
		_focus(box, first if first != null else back)
	_refresh_counts()
	_start_size_scan()
	_open(_trash)


# ── 环境详情 ─────────────────────────────────────────────────────────
func _go_env():
	if _envp == null:
		var box = _page(_t("env_title"), true)
		_envp = box
		var first = null
		var runtime_names = _installed_runtime_names()
		var runtime_rows = []
		if runtime_names.empty():
			runtime_rows.append(["Runtime", _t("none_installed")])
		else:
			for index in range(runtime_names.size()):
				runtime_rows.append([
					"Runtime " + str(index + 1) + "/" + str(runtime_names.size()),
					runtime_names[index],
				])
		var sections = [
			[_t("key_paths"), [
				[_t("scripts_dir"), _env_path("scripts_dir")],
				[_t("data_dir"), _env_path("gamedirs_dir")],
				[_t("portmaster_dir"), _env_path("controlfolder")],
				[_t("runtime_dir"), _env_path("libs_dir")],
			]],
			[_t("environment_values"), [
				[_t("cfw_env"), _env_value("cfw")],
				[_t("resolution_env"), _display_resolution()],
				[_t("device_arch_env"), _env_value("device_arch")],
				[_t("device_env"), _env_value("device")],
				[_t("param_device_env"), _env_value("param_device")],
				[_t("analog_sticks_env"), _env_value("analog_sticks")],
				[_t("lowres_env"), _env_value("lowres")],
				[_t("cur_tty_env"), _env_value("cur_tty")],
				[_t("sdl_controller_file_env"), _env_value("sdl_controller_file")],
				[_t("esudo_env"), _env_value("esudo")],
				[_t("gptokeyb_env"), _env_value("gptokeyb")],
				[_t("path_env"), _env_value("path")],
				[_t("ld_library_path_env"), _env_value("ld_library_path")],
				[_t("xdg_config_home_env"), _env_value("xdg_config_home")],
				[_t("xdg_data_home_env"), _env_value("xdg_data_home")],
				[_t("free_space"), _human(int(_env.get("free_bytes", 0)))],
			]],
			[_t("installed_runtimes"), runtime_rows],
		]
		for section in sections:
			var heading = _label(section[0], 19, Color(1.0, 0.85, 0.5))
			box.add_child(heading)
			for row in section[1]:
				var item = _info_btn(row[0], row[1])
				box.add_child(item)
				if first == null:
					first = item

		_footer(box).visible = false
		var side = _sidebar(box)
		var action_heading = _label(_t("actions"), 20)
		action_heading.align = Label.ALIGN_CENTER
		side.add_child(action_heading)
		side.add_child(_make_separator())
		var back = _side_btn(_t("back"), "_go_home")
		side.add_child(back)
		_bind_vertical_column([back])
		_focus(box, first if first != null else back)
	_open(_envp)


func _env_path(key):
	var value = str(_env.get(key, "")).strip_edges()
	return value if value != "" else _t("unavailable")


func _env_value(key):
	var value = str(_env.get(key, "")).strip_edges()
	return value if value != "" else _t("unavailable")


func _display_resolution():
	var width = str(_env.get("display_width", "")).strip_edges()
	var height = str(_env.get("display_height", "")).strip_edges()
	return width + " × " + height if width != "" and height != "" else _t("unavailable")


func _installed_runtime_names():
	var names = []
	for runtime in _scan.runtimes.have:
		names.append(str(runtime))
	names.sort()
	return names


# ── 计划 + 确认 ──────────────────────────────────────────────────────
func _confirm_uninstall(box):
	_confirm_back = box
	_plan = []
	var selected = _checked_items(box)
	var selected_by_dir = {}
	for it in selected:
		var p = it.port
		if p.dir != "":
			selected_by_dir[p.dir] = selected_by_dir.get(p.dir, 0) + 1

	var planned_dirs = {}
	for it in selected:
		var p = it.port
		_plan.append({"kind": "TRASH", "arg": _env.scripts_dir + "/" + p.script,
		              "label": _display_port_name(p.script), "visible": true})
		for img in p.images:
			_plan.append({"kind": "TRASH", "arg": _env.images_dir + "/" + img,
			              "label": img, "visible": false})
		# 共用目录: 选一部分时只删它们的 SH；关联 SH 全选时才删目录，且只计划一次。
		var owners = _scan.refcount.get(p.dir, 0)
		var all_owners_selected = owners > 0 and selected_by_dir.get(p.dir, 0) >= owners
		if all_owners_selected and not planned_dirs.has(p.dir):
			planned_dirs[p.dir] = true
	# 游戏目录最后处理：所有关联 SH 先成功移走，执行层才允许移动目录。这样某个 SH
	# 失败时不会留下“启动项还在、游戏文件却没了”的半完成状态。
	for dir_ in planned_dirs.keys():
		_plan.append({"kind": "TRASH", "arg": _env.gamedirs_dir + "/" + dir_,
		              "label": dir_ + "/", "visible": false})
	_go_confirm()


func _confirm_junk(box):
	_confirm_back = box
	_plan = []
	for it in _checked_items(box):
		_plan.append({"kind": "TRASH", "arg": it.path, "label": it.label, "visible": true})
	_go_confirm()


func _confirm_rt(rt):
	_confirm_back = _home
	_plan = [{"kind": "INSTALL_RT", "arg": rt, "label": _t("runtime_info")}]
	_go_confirm()


func _confirm_restore_selected(box):
	_confirm_back = box
	_plan = []
	for item in _checked_items(box):
		for i in range(item.restore_paths.size()):
			_plan.append({"kind": "RESTORE_ITEM", "arg": item.restore_paths[i],
				"label": item.label, "visible": i == 0})
	_go_confirm()


func _confirm_delete_selected(box):
	_confirm_back = box
	_plan = []
	for item in _checked_items(box):
		for i in range(item.restore_paths.size()):
			_plan.append({"kind": "DELETE_ITEM", "arg": item.restore_paths[i],
				"label": item.label, "visible": i == 0})
	_go_confirm()


func _go_confirm():
	if not is_instance_valid(_confirm_back):
		_confirm_back = _home
	# base 的 B 键会返回 _home_page；确认页期间临时把它指向操作来源页。
	_set_home(_pg(_confirm_back))
	if _conf != null:
		_pages.erase(_pg(_conf))
		_pg(_conf).queue_free()
		_conf = null
	var box = _page(_t("conf_title"))
	_conf = box

	if _plan.empty():
		box.add_child(_label(_t("nothing"), 21))
		var b = _bar_btn(_t("back"), "_cancel_confirm")
		_footer(box).add_child(b)
		_focus(box, b)
		_open(box)
		return

	var trashing = []
	var installing = []
	var emptying = []
	var restoring = []
	var restoring_selected = []
	var deleting_selected = []
	for p in _plan:
		if p.kind == "TRASH":
			trashing.append(p)
		elif p.kind == "INSTALL_RT":
			installing.append(p)
		elif p.kind == "EMPTY_TRASH":
			emptying.append(p)
		elif p.kind == "RESTORE_TRASH":
			restoring.append(p)
		elif p.kind == "RESTORE_ITEM":
			restoring_selected.append(p)
		elif p.kind == "DELETE_ITEM":
			deleting_selected.append(p)

	if not trashing.empty():
		box.add_child(_label(_t("will_trash"), 19, Color(1.0, 0.85, 0.5)))
		for p in trashing:
			if p.get("visible", true):
				box.add_child(_label("   " + p.label, 18))
		box.add_child(_label(_t("trash_note"), 16, Color(0.8, 0.8, 0.85)))
	if not installing.empty():
		box.add_child(_label(_t("will_inst"), 19, Color(0.6, 1.0, 0.6)))
	if not emptying.empty():
		box.add_child(_label(_t("will_empty"), 19, Color(1.0, 0.65, 0.55)))
	if not restoring.empty():
		box.add_child(_label(_t("will_restore"), 19, Color(0.65, 1.0, 0.65)))
	if not restoring_selected.empty():
		box.add_child(_label(_t("will_restore_selected"), 19, Color(0.65, 1.0, 0.65)))
		for p in restoring_selected:
			if p.get("visible", true):
				box.add_child(_label("   " + p.label, 18))
	if not deleting_selected.empty():
		box.add_child(_label(_t("will_delete_selected"), 19, Color(1.0, 0.65, 0.55)))
		for p in deleting_selected:
			if p.get("visible", true):
				box.add_child(_label("   " + p.label, 18))

	var bar = _footer(box)
	bar.add_child(_bar_btn(_t("ok"), "_apply"))
	var cancel = _bar_btn(_t("cancel"), "_cancel_confirm")
	bar.add_child(cancel)
	# 首焦点给"取消": 这一页按下去就动文件了, 默认落在安全的那个上。
	_focus(box, cancel)
	_open(box)


func _apply():
	var path = _env.get("plan_file", "")
	if path == "":
		_show_apply_error()
		return
	var f = File.new()
	if f.open(path, File.WRITE) != OK:
		_show_apply_error()
		return
	f.store_string("# APP Manager plan — applied by launcher.sh with $ESUDO\n")
	for p in _plan:
		f.store_string("%s\t%s\n" % [p.kind, p.arg])
	f.close()
	_save_state()

	var helper = str(_env.get("apply_script", ""))
	var helper_file = File.new()
	if helper == "" or not helper_file.file_exists(helper):
		# 不再用退出码重启兜底；缺 helper 就留在当前页面明确报错。
		_show_apply_error()
		return

	var return_to = "home"
	if _confirm_back == _trash:
		return_to = "trash"
	elif _confirm_back == _junk:
		return_to = "junk"
	elif _confirm_back == _envp:
		return_to = "env"
	_set_apply_busy(true)
	# 先让“处理中”实际画到屏幕，再在后台调用受控 Shell。blocking=false
	# 返回子进程 PID，主渲染线程继续出帧，不会在 TrimUI 上闪黑。
	yield(get_tree(), "idle_frame")
	yield(get_tree(), "idle_frame")
	_apply_pid = OS.execute("/bin/bash", PoolStringArray([helper, "--apply-plan"]), false)
	if _apply_pid <= 0:
		_apply_pid = -1
		_set_apply_busy(false)
		_show_apply_error()
		return
	_apply_return_to = return_to
	_apply_plan_path = path
	print("[PAM] apply helper started pid=%d" % _apply_pid)


func _poll_apply_process():
	if OS.is_process_running(_apply_pid):
		return
	print("[PAM] apply helper finished pid=%d" % _apply_pid)
	_apply_pid = -1
	# Godot 3 的非阻塞 execute 没有跨平台退出码 API。helper 只有走完
	# apply_plan 才会删除 plan.txt；仍存在就是中途失败，留在当前页明确报错。
	var plan_file = File.new()
	if _apply_plan_path == "" or plan_file.file_exists(_apply_plan_path):
		_set_apply_busy(false)
		_show_apply_error()
		_apply_return_to = ""
		_apply_plan_path = ""
		return
	var return_to = _apply_return_to
	_apply_return_to = ""
	_apply_plan_path = ""
	_refresh_after_apply(return_to)


# 只替换业务页面并重新扫描，不重载场景、不重建 FRT，也不闪黑屏。成功后回到操作
# 来源页；如果 helper 写了失败结果，则回首页直接展示错误。
func _refresh_after_apply(return_to):
	# 旧确认页保持可见，先在背后建好新页并完成扫描；新页打开后才释放
	# 旧页。这样中间没有“所有页都隐藏”的黑帧，也不重载场景/FRT。
	# 文件移动后缓存路径会变；在重建页面前标记一次强制校准。
	# _build_pages 内只会启动一个 worker，不会重复遍历。
	_size_rescan_requested = true
	var old_pages = _center.get_children()
	_pages = []
	_home_page = null
	_scan = null
	_sc = null
	_result = []
	_build_pages()
	if not _result.empty():
		return_to = "home"
	match return_to:
		"trash":
			_go_trash()
		"junk":
			_go_junk()
		"env":
			_go_env()
		_:
			_go_home()
	for child in old_pages:
		child.visible = false
		child.queue_free()


func _set_apply_busy(busy):
	if _conf == null:
		return
	var buttons = _footer(_conf).get_children()
	for button in buttons:
		if button is Button:
			button.disabled = busy
	if buttons.size() > 0 and buttons[0] is Button:
		buttons[0].text = _t("working") if busy else _t("ok")


func _show_apply_error():
	if _conf == null or _conf.has_meta("apply_error"):
		return
	_conf.set_meta("apply_error", true)
	_conf.add_child(_label(_t("fail_operation"), 17, Color(1.0, 0.55, 0.48)))


func _go_home():
	if _home:
		_set_home(_pg(_home))
		_open(_home)


func _cancel_confirm():
	if is_instance_valid(_confirm_back):
		var target = _confirm_back
		_open(target)
		# base 的 _input 也会收到当前 B 键；等这一轮输入结束后再恢复
		# 真正首页，否则 parent 会在同一帧又跳回首页。
		call_deferred("_restore_home_target")
	else:
		_go_home()


func _restore_home_target():
	if is_instance_valid(_home):
		_set_home(_pg(_home))


func _on_quit():
	_save_state()
	get_tree().quit(0)


# ── 控件 ─────────────────────────────────────────────────────────────
# base 的 _new_page 是给"居中一小块设置项"用的。这里改成占满屏的 APP 框架:
# 固定顶栏 / 中间自适应滚动区 / 固定底栏。
#
# 这里返回的 box 埋在滚动区里。绝不能靠
# 数 get_parent() 的层数去回推页面 —— 数错一层, _show_page() 拿到的节点不在 _pages
# 里, 于是它把所有页面都判成"不是当前页"全部隐藏, 屏幕上只剩背景 = 黑屏(实测踩过)。
# 页面和底栏对象直接挂在 box 的 meta 上, 层级怎么变都不会错。
func _page(title_text, with_sidebar = false):
	var page = Control.new()
	page.set_anchors_and_margins_preset(Control.PRESET_WIDE)
	page.visible = false

	var margin = MarginContainer.new()
	margin.set_anchors_and_margins_preset(Control.PRESET_WIDE)
	margin.add_constant_override("margin_left", _edge)
	margin.add_constant_override("margin_right", _edge)
	margin.add_constant_override("margin_top", _edge)
	margin.add_constant_override("margin_bottom", _edge)

	var outer = VBoxContainer.new()
	outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_constant_override("separation", _scaled(4, 3))

	var header = Control.new()
	header.rect_min_size = Vector2(0, _header_h)
	var title = Label.new()
	title.text = title_text
	title.align = Label.ALIGN_CENTER
	title.valign = Label.VALIGN_CENTER
	title.add_font_override("font", _font(_scaled(32, 23)))
	title.add_color_override("font_color", Color.white)
	title.set_anchors_and_margins_preset(Control.PRESET_WIDE)
	_apply_outline(title, _scaled(4, 3))
	header.add_child(title)
	outer.add_child(header)
	outer.add_child(_make_separator())

	var scroll = ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.follow_focus = true
	scroll.scroll_horizontal_enabled = false
	var box = VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_constant_override("separation", _scaled(6, 4))
	scroll.add_child(box)

	var sidebar = null
	if with_sidebar:
		var content = HBoxContainer.new()
		content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		content.size_flags_vertical = Control.SIZE_EXPAND_FILL
		content.add_constant_override("separation", _scaled(8, 6))
		content.add_child(scroll)
		var divider = VSeparator.new()
		divider.rect_min_size = Vector2(_scaled(4, 2), 0)
		content.add_child(divider)
		sidebar = VBoxContainer.new()
		sidebar.rect_min_size = Vector2(_scaled(200, 160), 0)
		sidebar.size_flags_vertical = Control.SIZE_EXPAND_FILL
		sidebar.add_constant_override("separation", _scaled(4, 3))
		content.add_child(sidebar)
		outer.add_child(content)
	else:
		outer.add_child(scroll)

	var footer = HBoxContainer.new()
	footer.rect_min_size = Vector2(0, _footer_h)
	footer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_constant_override("separation", _scaled(6, 4))
	outer.add_child(_make_separator())
	outer.add_child(footer)

	margin.add_child(outer)
	page.add_child(margin)
	_center.add_child(page)
	_pages.append(page)
	box.set_meta("page", page)
	box.set_meta("footer", footer)
	box.set_meta("sidebar", sidebar)
	return box


func _pg(box):
	return box.get_meta("page")


func _footer(box):
	return box.get_meta("footer")


func _sidebar(box):
	return box.get_meta("sidebar")


# base 的 _set_page_focus 把 meta 挂在 box.get_parent() 上 —— 那在它的页面结构里
# 就是页面, 在我们的结构里却是 ScrollContainer, _show_page 永远读不到 → 手柄没焦点。
func _focus(box, ctrl):
	_pg(box).set_meta("first_focus", ctrl)


func _open(box):
	if is_instance_valid(_detail_btn):
		_detail_btn.text = _t("detail") if box == _home else _t("back")
	_show_page(_pg(box))


func _label(text, size = 19, color = Color.white):
	var l = Label.new()
	l.text = text
	l.add_font_override("font", _font(_scaled(size, 14)))
	l.add_color_override("font_color", color)
	l.autowrap = true
	_apply_outline(l, _scaled(3, 2))
	return l


func _bar_btn(text, method, binds = [], _width = 0):
	var b = _make_button(text, method, binds)
	b.rect_min_size = Vector2(0, _footer_h)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_font_override("font", _font(_scaled(18, 14)))
	b.clip_text = true
	return b


func _side_btn(text, method, binds = []):
	var b = _make_button(text, method, binds)
	b.rect_min_size = Vector2(0, _scaled(40, 34))
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_font_override("font", _font(_scaled(17, 14)))
	b.clip_text = true
	return b


func _side_pair():
	var grid = GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_constant_override("hseparation", _scaled(8, 5))
	return grid


func _info_btn(key, value):
	var b = Button.new()
	b.rect_min_size = Vector2(0, _scaled(72, 60))
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.focus_mode = Control.FOCUS_ALL
	b.text = ""
	_apply_outline(b)
	_apply_button_theme(b)
	b.set_meta("list_nav", true)

	var inset = MarginContainer.new()
	inset.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inset.set_anchors_and_margins_preset(Control.PRESET_WIDE)
	inset.add_constant_override("margin_left", _scaled(12, 9))
	inset.add_constant_override("margin_right", _scaled(12, 9))
	inset.add_constant_override("margin_top", _scaled(5, 4))
	inset.add_constant_override("margin_bottom", _scaled(5, 4))

	var copy = VBoxContainer.new()
	copy.alignment = BoxContainer.ALIGN_CENTER
	copy.add_constant_override("separation", _scaled(2, 1))
	var title = _label(key, 15, Color(0.72, 0.72, 0.80))
	title.autowrap = false
	title.clip_text = true
	copy.add_child(title)
	var content = _label(value, 16)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.autowrap = true
	copy.add_child(content)
	inset.add_child(copy)
	b.add_child(inset)
	return b


# 多选 Item: Button 只画背景/焦点，内容用独立图标 + 两个 Label。
# 这样缺 Runtime 时只把第二行染红，不会连 APP 名和勾选框一起变红。
func _check_btn(title_text, detail_text, item, warning = false):
	var b = Button.new()
	b.rect_min_size = Vector2(0, _row_h)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.focus_mode = Control.FOCUS_ALL
	b.text = ""
	_apply_outline(b)
	_apply_button_theme(b)

	var inset = MarginContainer.new()
	inset.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inset.set_anchors_and_margins_preset(Control.PRESET_WIDE)
	inset.add_constant_override("margin_left", _scaled(16, 12))
	inset.add_constant_override("margin_right", _scaled(16, 12))
	inset.add_constant_override("margin_top", _scaled(6, 4))
	inset.add_constant_override("margin_bottom", _scaled(6, 4))

	var row = HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_constant_override("separation", _scaled(12, 8))
	var icon = TextureRect.new()
	icon.rect_min_size = Vector2(_scaled(28, 20), _scaled(28, 20))
	icon.expand = true
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon)

	var copy = VBoxContainer.new()
	copy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	copy.alignment = BoxContainer.ALIGN_CENTER
	copy.add_constant_override("separation", 0)
	var title = _label(title_text, 18)
	title.autowrap = false
	title.clip_text = true
	copy.add_child(title)
	var shown_detail = _detail_with_size(detail_text, item)
	var detail = null
	if shown_detail != "":
		var detail_color = Color(1.0, 0.46, 0.40) if warning else Color(0.82, 0.82, 0.88)
		detail = _label(shown_detail, 16, detail_color)
		detail.autowrap = false
		detail.clip_text = true
		copy.add_child(detail)
	row.add_child(copy)
	inset.add_child(row)
	b.add_child(inset)

	b.set_meta("item", item)
	b.set_meta("detail_base", detail_text)
	b.set_meta("detail_label", detail)
	b.set_meta("checked", item.get("checked", false))
	b.set_meta("check_icon", icon)
	b.set_meta("list_nav", true)
	_refresh_check(b)
	b.connect("pressed", self, "_on_check_toggle", [b])
	return b


func _detail_with_size(base, item):
	var paths = item.get("size_paths", [])
	if paths.empty():
		return base
	var bytes = _size_of_items([item])
	var size_text = _t("size_calculating") if bytes < 0 else (_t("size_about") % _human(bytes))
	return size_text if base == "" else base + "  ·  " + size_text


func _size_of_items(items):
	var total = 0
	var seen = {}
	for item in items:
		for raw_path in item.get("size_paths", []):
			var path = str(raw_path)
			if path == "" or seen.has(path):
				continue
			seen[path] = true
			if not _size_cache.has(path):
				return -1
			total += int(_size_cache[path])
	return total


func _all_items(box):
	var out = []
	if not is_instance_valid(box):
		return out
	for child in box.get_children():
		if child is Button and child.has_meta("item"):
			out.append(child.get_meta("item"))
	return out


func _has_unknown_size_paths():
	for box in [_home, _junk, _trash]:
		for item in _all_items(box):
			if _size_of_items([item]) < 0:
				return true
	return false


func _refresh_size_labels():
	for box in [_home, _junk, _trash]:
		if not is_instance_valid(box):
			continue
		for child in box.get_children():
			if not (child is Button) or not child.has_meta("item"):
				continue
			var detail = child.get_meta("detail_label")
			if is_instance_valid(detail):
				detail.text = _detail_with_size(
					str(child.get_meta("detail_base")), child.get_meta("item"))


func _refresh_check(b):
	var icon = b.get_meta("check_icon")
	icon.texture = _check_on if b.get_meta("checked") else _check_off


func _on_check_toggle(b):
	b.set_meta("checked", not b.get_meta("checked"))
	_refresh_check(b)
	_refresh_counts()


# 各列表页的主操作都随勾选实时刷新。
func _refresh_counts():
	if is_instance_valid(_uninstall_btn):
		var selected_home = _checked_items(_home) if is_instance_valid(_home) else []
		var n = selected_home.size()
		var home_bytes = _size_of_items(selected_home)
		_uninstall_btn.text = (_t("uninstall_sized") % [n, _human(home_bytes)]
			if n > 0 and home_bytes >= 0 else _t("uninstall") % n)
		_uninstall_btn.disabled = n == 0
	if is_instance_valid(_junk_clean_btn):
		var selected_junk = _checked_items(_junk) if is_instance_valid(_junk) else []
		var junk_selected = selected_junk.size()
		var junk_bytes = _size_of_items(selected_junk)
		_junk_clean_btn.text = (_t("clean_sized") % [junk_selected, _human(junk_bytes)]
			if junk_selected > 0 and junk_bytes >= 0 else _t("clean_now"))
		_junk_clean_btn.disabled = junk_selected == 0
	if is_instance_valid(_trash_restore_btn):
		var selected_trash = _checked_items(_trash) if is_instance_valid(_trash) else []
		var selected = selected_trash.size()
		_trash_restore_btn.text = (_t("restore_selected_count") % selected
			if selected > 0 else _t("restore_selected"))
		_trash_restore_btn.disabled = selected == 0
		if is_instance_valid(_trash_delete_btn):
			var selected_bytes = _size_of_items(selected_trash)
			_trash_delete_btn.text = (_t("delete_selected_sized") %
				[selected, _human(selected_bytes)] if selected > 0 and selected_bytes >= 0
				else _t("delete_selected"))
			_trash_delete_btn.disabled = selected == 0


func _checked_items(box):
	var out = []
	for c in box.get_children():
		if c is Button and c.has_meta("checked") and c.get_meta("checked"):
			out.append(c.get_meta("item"))
	return out


func _sel_none(box):
	for c in box.get_children():
		if c is Button and c.has_meta("checked"):
			c.set_meta("checked", false)
			_refresh_check(c)
	_refresh_counts()


func _sel_all(box):
	for c in box.get_children():
		if c is Button and c.has_meta("checked"):
			c.set_meta("checked", true)
			_refresh_check(c)
	_refresh_counts()


func _human(bytes):
	if bytes >= 1073741824:
		return "%.2f GB" % (bytes / 1073741824.0)
	if bytes >= 1048576:
		return "%.1f MB" % (bytes / 1048576.0)
	if bytes >= 1024:
		return "%.0f KB" % (bytes / 1024.0)
	return "%d B" % bytes


func _display_port_name(name):
	return name.substr(0, name.length() - 3) if name.to_lower().ends_with(".sh") else name
