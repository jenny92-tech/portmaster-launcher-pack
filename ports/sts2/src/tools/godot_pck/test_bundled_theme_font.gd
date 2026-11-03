# INPUT:  exact RC engine, canonical SC font and bundled-font trial script
# OUTPUT: opt-in, cache identity, default-theme and custom-override assertions
# POS:    headless isolated fixture without game content or user data
extends SceneTree

const Trial = preload("res://bundled_font_trial.gd")
const SOURCE = "res://fonts/zhs/SourceHanSerifSC-Medium.otf"
const STYLES = ["bold_font", "italics_font", "bold_italics_font"]
var failures = 0

func _initialize() -> void:
	call_deferred("run_test")

func check(condition: bool, message: String) -> void:
	if not condition:
		printerr("FAIL: ", message)
		failures += 1

func check_label_default_slot(theme: Theme) -> void:
	var saved = theme.default_font
	var marker = FontVariation.new()
	marker.base_font = saved
	theme.default_font = marker
	check(is_same(theme.get_font("font", "Label"), marker), "Label follows default font, no explicit slot")
	theme.default_font = saved

func run_test() -> void:
	var mode = OS.get_cmdline_user_args()[0]
	var theme = ThemeDB.get_default_theme()
	var original = theme.default_font
	check_label_default_slot(theme)
	check(original is FontFile and original.get_font_name() == "Open Sans SemiBold", "expected embedded default")
	check(is_same(ThemeDB.fallback_font, original), "expected initial fallback")
	if mode == "custom_default":
		var replacement = FontVariation.new()
		replacement.base_font = original
		theme.default_font = replacement
		check(not Trial.install(), "custom default should skip")
		check(is_same(theme.default_font, replacement), "custom default preserved")
		check(is_same(ThemeDB.fallback_font, original), "custom default did not change fallback")
		check(not ResourceLoader.has_cached(SOURCE), "custom default did not load bundled font")
		if failures:
			quit(1)
			return
		print("BUNDLED_THEME_FIXTURE_OK mode=", mode)
		quit(0)
		return
	var variations = []
	for name in STYLES:
		var font = theme.get_font(name, "RichTextLabel")
		check(font is FontVariation and is_same(font.base_font, original), "expected original variation")
		variations.append(font)
	var custom = FontVariation.new()
	custom.base_font = original
	var override_label = Label.new()
	override_label.add_theme_font_override("font", custom)
	root.add_child(override_label)
	var custom_theme = Theme.new()
	custom_theme.set_font("font", "Label", custom)
	var themed_label = Label.new()
	themed_label.theme = custom_theme
	root.add_child(themed_label)
	var plain_label = Label.new()
	plain_label.text = "简体中文，准备战斗！"
	root.add_child(plain_label)
	check(not ResourceLoader.has_cached(SOURCE), "source unexpectedly cached before test")
	var preloaded: Resource
	var custom_fallback: FontVariation
	if mode == "custom_fallback":
		custom_fallback = FontVariation.new()
		custom_fallback.base_font = original
		ThemeDB.fallback_font = custom_fallback
	if mode == "preload":
		preloaded = ResourceLoader.load(SOURCE)
		check(preloaded != null, "preloading source")
	var enabled = Trial.install()
	if mode == "off":
		check(not enabled and is_same(theme.default_font, original), "disabled changed default")
		check(is_same(ThemeDB.fallback_font, original), "disabled changed fallback")
		check(not ResourceLoader.has_cached(SOURCE), "disabled loaded SC")
	else:
		check(enabled, "trial did not install")
		var bundled = ResourceLoader.load(SOURCE)
		var combined = theme.default_font as FontVariation
		check(combined != null and is_same(combined.base_font, bundled), "default wraps canonical source")
		check(combined.get_fallbacks().size() == 1 and is_same(combined.get_fallbacks()[0], original), "embedded original retained as fallback")
		if mode == "custom_fallback":
			check(is_same(custom_fallback, ThemeDB.fallback_font), "custom fallback preserved")
		else:
			check(is_same(combined, ThemeDB.fallback_font), "fallback shares combined font")
		if preloaded != null:
			check(is_same(preloaded, bundled), "preloaded identity")
		check(bundled.allow_system_fallback and bundled.has_char(0x4e2d), "coverage/system fallback")
		check(is_same(plain_label.get_theme_font("font"), combined), "plain Label resolves combined font")
		check(plain_label.get_minimum_size().x > 0.0, "Chinese Label layout")
		var tested_fonts: Array[Font] = [combined]
		for i in STYLES.size():
			var replacement = theme.get_font(STYLES[i], "RichTextLabel")
			check(replacement is FontVariation and not is_same(replacement, variations[i]), "independent variation copy")
			check(is_same(replacement.base_font, combined), "variation base is combined font")
			check(replacement.variation_embolden == variations[i].variation_embolden, "embolden preserved")
			check(replacement.variation_transform == variations[i].variation_transform, "italic transform preserved")
			tested_fonts.append(replacement)
		var corpus = JSON.parse_string(FileAccess.get_file_as_string("res://manifest.json"))
		check(corpus.codepoints.size() == 2493, "expected localization codepoint inventory")
		for font in tested_fonts:
			var missing = 0
			for cp in corpus.codepoints:
				if not font.has_char(int(cp)):
					missing += 1
			check(missing == 0, "combined font localization coverage")
	check(is_same(override_label.get_theme_font("font"), custom), "node override preserved")
	check(is_same(themed_label.get_theme_font("font"), custom), "custom Theme preserved")
	check(is_same(custom.base_font, original), "custom font object not changed")
	check_label_default_slot(theme)
	if failures:
		quit(1)
		return
	print("BUNDLED_THEME_FIXTURE_OK mode=", mode)
	quit(0)
