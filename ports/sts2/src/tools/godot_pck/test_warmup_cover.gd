# INPUT:  isolated RC engine, original or revised warmup script and bundled SC font
# OUTPUT: font identity, no-font fallback and warmup lifecycle assertions
# POS:    controlled host fixture; no game scenes, user input or font data output
extends SceneTree

class Coordinator extends Node:
	signal effects_requested
	var _pins = {}
	func clear_room_pins() -> void:
		_pins.clear()
	func simple_effects_enabled() -> bool:
		return true
	func is_startup_effects_successful() -> bool:
		return true

var failed = false
func check(ok: bool, message: String) -> void:
	if not ok:
		printerr("WARMUP_COVER_FAIL ", message)
		failed = true

func _initialize() -> void:
	call_deferred("run_test")

func run_test() -> void:
	var mode = OS.get_cmdline_user_args()[0]
	var warm_script = load("res://port_compat/combat_warmup_old.gd" if mode == "old" else "res://port_compat/combat_warmup.gd")
	var coordinator = Coordinator.new()
	root.add_child(coordinator)
	var warm = warm_script.new()
	coordinator.add_child(warm)
	warm.configure(coordinator, null, {"method": "test", "driver": "dummy"})
	var room = Node2D.new()
	root.add_child(room)
	room.add_child(Control.new()) # Old implementation selects this default theme font.
	var chosen: Font
	if mode in ["label", "rich", "old", "lifecycle"]:
		chosen = ResourceLoader.load("res://fonts/zhs/SourceHanSerifSC-Medium.otf") as FontFile
		check(chosen != null, "missing canonical test font")
		if mode == "rich":
			var variation = FontVariation.new()
			variation.base_font = chosen
			chosen = variation
			var rich = RichTextLabel.new()
			rich.add_theme_font_override("normal_font", chosen)
			room.add_child(rich)
		else:
			var existing = Label.new()
			existing.add_theme_font_override("font", chosen)
			room.add_child(existing)
	elif mode in ["system", "system_variation", "system_fallback"]:
		var system = SystemFont.new()
		var existing = Label.new()
		var system_candidate: Font = system
		if mode == "system_variation":
			var variation = FontVariation.new()
			variation.base_font = system
			system_candidate = variation
		elif mode == "system_fallback":
			var variation = FontVariation.new()
			variation.base_font = ResourceLoader.load("res://fonts/zhs/SourceHanSerifSC-Medium.otf")
			variation.fallbacks = [system]
			system_candidate = variation
		existing.add_theme_font_override("font", system_candidate)
		room.add_child(existing)
	else:
		room.add_child(Label.new()) # Open Sans lacks the controlled Chinese title.
	if mode == "lifecycle":
		var vfx = Node2D.new()
		room.add_child(vfx)
		warm.prepare_room(room, [], vfx)
		for i in range(8):
			await process_frame
		check(not warm.get("_warming"), "warmup did not complete")
		check(warm.get("_mask") == null, "mask not released")
		check(not warm.is_processing_input(), "input still intercepted")
	else:
		warm._create_mask(room)
		var cover = warm.get("_mask").get_child(0)
		var labels = []
		var bars = []
		for child in cover.get_children():
			if child is Label: labels.append(child)
			if child is ProgressBar: bars.append(child)
		check(bars.size() == 1, "progress bar missing")
		if mode in ["label", "rich"]:
			check(labels.size() == 1, "expected one title")
			if labels.size() == 1:
				check(is_same(labels[0].get_theme_font("font"), chosen), "font identity not shared")
				check(labels[0].text == "准备战斗…", "title text")
				check(labels[0].get_minimum_size().x > 0, "title did not shape")
		elif mode == "old":
			check(labels.size() == 1, "old title missing")
			if labels.size() == 1:
				check(not is_same(labels[0].get_theme_font("font"), chosen), "old title unexpectedly reused font")
				labels[0].get_minimum_size()
		else:
			check(labels.is_empty(), "uncovered or SystemFont should not create title")
		await process_frame
		warm._finish()
		await process_frame
		check(warm.get("_mask") == null, "mask cleanup")
	if failed:
		quit(1)
		return
	print("WARMUP_COVER_OK mode=", mode)
	quit(0)
