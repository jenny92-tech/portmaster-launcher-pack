# INPUT:  isolated 4.5.1 RC runtime, distribution system fonts, fixed codepoint
# OUTPUT: deterministic success or an explicit unavailable result
# POS:    trigger one controlled fallback twice; no user text or font bytes
extends SceneTree

func _initialize() -> void:
	call_deferred("run_test")

func run_test() -> void:
	var cp = 0x05d0 # Hebrew alef, chosen only as a fixed test input.
	var original = ThemeDB.get_default_theme().default_font
	if not OS.has_feature("system_fonts") or original.has_char(cp):
		print("SYSTEM_FONT_FIXTURE_UNAVAILABLE")
		quit(2)
		return
	var paths = OS.get_system_font_path_for_text(original.get_font_name(), String.chr(cp), "en", "", 400, 100, false)
	if paths.is_empty():
		print("SYSTEM_FONT_FIXTURE_UNAVAILABLE")
		quit(2)
		return
	for i in range(2):
		var label = Label.new()
		label.text = String.chr(cp)
		root.add_child(label)
		if label.get_minimum_size().x <= 0:
			printerr("SYSTEM_FONT_FIXTURE_LAYOUT_FAILED")
			quit(1)
			return
		label.queue_free()
		await process_frame
	print("SYSTEM_FONT_FIXTURE_OK")
	quit(0)
