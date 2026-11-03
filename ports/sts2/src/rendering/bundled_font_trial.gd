# INPUT:  explicit Chinese trial flag, Godot default theme and bundled SC font
# OUTPUT: default-theme font substitutions sharing the game's canonical resource
# POS:    opt-in experiment before the main menu; leaves custom overrides untouched
extends RefCounted

const SOURCE = "res://fonts/zhs/SourceHanSerifSC-Medium.otf"

static func install() -> bool:
	if OS.get_environment("SLL_BUNDLED_THEME_FONT") != "1":
		return false
	var theme = ThemeDB.get_default_theme()
	if theme == null:
		return false
	var original = theme.default_font
	if not original is FontFile or not original.resource_path.is_empty() or original.get_font_name() != "Open Sans SemiBold":
		print("[BUNDLED-THEME-FONT] skipped: default font is not the embedded Open Sans")
		return false
	var bundled = ResourceLoader.load(SOURCE) as FontFile
	if bundled == null or not bundled.allow_system_fallback or not bundled.has_char(0x4e2d):
		print("[BUNDLED-THEME-FONT] skipped: bundled source font unavailable")
		return false
	# Preserve Latin glyphs that the bundled CJK face lacks, without changing
	# either shared font or reloading the embedded Open Sans resource.
	var combined = FontVariation.new()
	combined.base_font = bundled
	combined.fallbacks = [original]
	var replacements = []
	# The RC default theme has three explicit variants. Other font slots are
	# empty and must stay empty to preserve theme fallback and inheritance.
	for name in ["bold_font", "italics_font", "bold_italics_font"]:
		var current = theme.get_font(name, "RichTextLabel")
		if current is FontVariation and is_same(current.base_font, original):
			var replacement = current.duplicate() as FontVariation
			if replacement == null:
				print("[BUNDLED-THEME-FONT] skipped: variation copy failed")
				return false
			replacement.base_font = combined
			replacements.append([name, "RichTextLabel", replacement])
	var replace_fallback = is_same(ThemeDB.fallback_font, original)
	theme.default_font = combined
	if replace_fallback:
		ThemeDB.fallback_font = combined
	for entry in replacements:
		theme.set_font(entry[0], entry[1], entry[2])
	print("[BUNDLED-THEME-FONT] enabled source=", SOURCE, " slots=", replacements.size(), " fallback_replaced=", replace_fallback)
	return true
