# INPUT:  three canonical SC fonts, embedded Open Sans, fixed zhs corpus manifest
# OUTPUT: per-font missing codepoints and in-memory inherited-fallback validation
# POS:    host-only evidence; never modifies or saves the game's font resources
extends SceneTree

func _initialize() -> void:
	var manifest = JSON.parse_string(FileAccess.get_file_as_string("res://manifest.json"))
	if manifest.codepoints.size() != 2493:
		printerr("SC_COVERAGE_FAIL inventory")
		quit(1)
		return
	var original = ThemeDB.get_default_theme().default_font
	var expected = [287, 305, 322]
	for stem in ["SourceHanSerifSC-Medium", "SourceHanSerifSC-Bold", "NotoSansMonoCJKsc-Regular"]:
		var path = "res://fonts/zhs/" + stem + ".otf"
		var font = ResourceLoader.load(path) as FontFile
		if font == null or not font.get_fallbacks().is_empty() or not font.allow_system_fallback:
			printerr("SC_COVERAGE_FAIL source identity")
			quit(1)
			return
		var missing = []
		for cp in manifest.codepoints:
			if not font.has_char(int(cp)):
				missing.append(int(cp))
		if missing != expected:
			printerr("SC_COVERAGE_FAIL unexpected missing set")
			quit(1)
			return
		font.fallbacks = [original] # This fixture process never saves the resource.
		var variation = FontVariation.new()
		variation.base_font = font
		var missing_after = 0
		for cp in manifest.codepoints:
			if not variation.has_char(int(cp)):
				missing_after += 1
		var probe = String.chr(0x011f) + String.chr(0x0131) + String.chr(0x0142)
		var dimensions = variation.get_string_size(probe, HORIZONTAL_ALIGNMENT_LEFT, -1, 32)
		if missing_after != 0 or dimensions.x <= 0 or dimensions.y <= 0 or not font.allow_system_fallback:
			printerr("SC_COVERAGE_FAIL inherited fallback")
			quit(1)
			return
		print("SC_COVERAGE_OK name=", stem, " missing_before=3 missing_after=0")
	quit(0)
