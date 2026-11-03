# INPUT:  Nine source-bound FontFile resources and unique localization codepoints
# OUTPUT: Six externally linked fallback FontFiles and private coverage evidence
# POS:    Isolated Godot host worker for the Chinese-only fallback candidate
extends SceneTree

const PROPERTIES = ["allow_system_fallback", "antialiasing", "disable_embedded_bitmaps", "fixed_size", "fixed_size_scale_mode", "font_name", "font_stretch", "font_style", "font_weight", "force_autohinter", "generate_mipmaps", "hinting", "keep_rounding_remainders", "modulate_color_glyphs", "msdf_pixel_range", "msdf_size", "multichannel_signed_distance_field", "opentype_feature_overrides", "oversampling", "style_name", "subpixel_positioning"]
const LATIN = [0x41, 0x61, 0x5a, 0x7a, 0x30, 0x39, 0x2e, 0x21, 0x3f, 0x25, 0x2b, 0x23, 0x40, 0x26]

func _initialize() -> void:
 call_deferred("_run")

func data_sha(data: PackedByteArray) -> String:
 var context := HashingContext.new()
 context.start(HashingContext.HASH_SHA256)
 context.update(data)
 return context.finish().hex_encode()

func settings(font: FontFile) -> Dictionary:
 var result := {}
 for name in PROPERTIES: result[name] = font.get(name)
 result.caches = []
 for i in font.get_cache_count():
  var sizes := []
  for size in font.get_size_cache_list(i):
   sizes.append({"size": [size.x, size.y], "pages": font.get_texture_count(i, size)})
  result.caches.append({"sizes": sizes, "variation": font.get_variation_coordinates(i),
   "face": font.get_face_index(i), "embolden": font.get_embolden(i),
   "transform": str(font.get_transform(i)), "baseline": font.get_extra_baseline_offset(i),
   "spacing": [font.get_extra_spacing(i, 0), font.get_extra_spacing(i, 1), font.get_extra_spacing(i, 2), font.get_extra_spacing(i, 3)]})
 result.language = {}
 for key in font.get_language_support_overrides(): result.language[key] = font.get_language_support_override(key)
 result.script = {}
 for key in font.get_script_support_overrides(): result.script[key] = font.get_script_support_override(key)
 return result

func metrics(font: FontFile) -> Array:
 var result := []
 for size in [16, 24, 48]:
  for cp in LATIN:
   var glyph := font.get_glyph_index(size, cp, 0)
   if glyph == 0 or not font.has_char(cp): return []
   var advance := font.get_glyph_advance(0, size, glyph)
   result.append([size, cp, glyph, advance.x, advance.y])
 return result

func fail(message: String) -> void:
 printerr(message)
 quit(1)

func _run() -> void:
 var args := OS.get_cmdline_user_args()
 if args.size() == 3 and args[0] in ["eager", "preload"]:
  if ResourceLoader.has_cached(args[2]): fail("fallback already cached"); return
  var preloaded: Resource
  if args[0] == "preload":
   preloaded = ResourceLoader.load(args[2])
   if preloaded == null: fail("source fallback preload failed"); return
  var fresh := ResourceLoader.load(args[1]) as FontFile
  if fresh == null or fresh.get_fallbacks().size() != 1 or not ResourceLoader.has_cached(args[2]):
   fail("external fallback was not eagerly loaded"); return
  var from_source := ResourceLoader.load(args[2])
  if from_source == null or not is_same(fresh.get_fallbacks()[0], from_source):
   fail("candidate does not share canonical source-path cache"); return
  if preloaded != null and not is_same(preloaded, from_source):
   fail("preloaded source-path cache identity changed"); return
  print("FONT_FALLBACK_EAGER_OK")
  quit(0)
  return
 if args.size() != 1: fail("expected manifest path"); return
 var manifest = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
 if typeof(manifest) != TYPE_DICTIONARY or manifest.fonts.size() != 6:
  fail("invalid manifest"); return
 var results := []
 for item in manifest.fonts:
  var original := ResourceLoader.load(item.original, "", ResourceLoader.CACHE_MODE_IGNORE) as FontFile
  var fallback := ResourceLoader.load(item.fallback) as FontFile
  if original == null or fallback == null or original.data.is_empty() or fallback.data.is_empty():
   fail("font input not loadable"); return
  if not original.get_fallbacks().is_empty() or not fallback.get_fallbacks().is_empty():
   fail("unexpected preexisting fallback or cycle risk"); return
  if not ResourceLoader.get_dependencies(item.fallback).is_empty():
   fail("SC font has external dependencies; cycle cannot be excluded"); return
  var before := settings(original)
  var original_hash := data_sha(original.data)
  var fallback_hash := data_sha(fallback.data)
  if original_hash != item.original_data_sha256 or fallback_hash != item.fallback_data_sha256:
   fail("font data mismatch"); return
  original.set_fallbacks([fallback])
  if original.get_fallbacks().size() != 1 or original.get_fallbacks()[0] != fallback:
   fail("fallback assignment failed"); return
  var err := ResourceSaver.save(original, item.output, ResourceSaver.FLAG_COMPRESS)
  if err != OK: fail("candidate save failed: " + str(err)); return
  var deps := ResourceLoader.get_dependencies(item.output)
  if deps.size() != 1 or not str(deps[0]).ends_with(item.fallback):
   fail("external fallback dependency mismatch: " + str(deps)); return
  var baseline := ResourceLoader.load(item.original, "", ResourceLoader.CACHE_MODE_IGNORE) as FontFile
  var candidate := ResourceLoader.load(item.output, "", ResourceLoader.CACHE_MODE_IGNORE) as FontFile
  if baseline == null or candidate == null or settings(baseline) != before or settings(candidate) != before:
   fail("font settings or caches changed"); return
  if data_sha(candidate.data) != original_hash or candidate.get_fallbacks().size() != 1 or candidate.get_fallbacks()[0] != fallback:
   fail("font data or shared external fallback changed"); return
  var before_metrics := metrics(baseline)
  var after_metrics := metrics(candidate)
  if before_metrics.size() != LATIN.size() * 3 or before_metrics != after_metrics:
   fail("Latin glyph metrics changed"); return
  var latin_before := baseline.get_string_size("AV az 09!? @%", HORIZONTAL_ALIGNMENT_LEFT, -1, 48)
  var latin_after := candidate.get_string_size("AV az 09!? @%", HORIZONTAL_ALIGNMENT_LEFT, -1, 48)
  if latin_before != latin_after: fail("Latin shaping dimensions changed"); return
  var chinese_sample := candidate.get_string_size("简体中文，回合结束！", HORIZONTAL_ALIGNMENT_LEFT, -1, 48)
  if chinese_sample.x <= 0 or chinese_sample.y <= 0: fail("Chinese sample did not shape"); return
  var old_missing := []
  var new_missing := []
  var added := 0
  for raw_cp in manifest.codepoints:
   var cp := int(raw_cp)
   var had := baseline.has_char(cp)
   var sc_has := fallback.has_char(cp)
   var actual := candidate.has_char(cp)
   if actual != (had or sc_has): fail("fallback coverage inconsistent for " + str(cp)); return
   if not had: old_missing.append(cp)
   if not actual: new_missing.append(cp)
   if not had and actual: added += 1
  results.append({"original": item.original, "fallback": item.fallback, "output": item.output,
   "font_data_sha256": original_hash, "fallback_data_sha256": fallback_hash,
   "dependencies": deps, "settings_preserved": true, "latin_metric_samples": before_metrics.size(),
   "latin_shaping_size": [latin_after.x, latin_after.y], "chinese_sample_size": [chinese_sample.x, chinese_sample.y],
   "codepoints_examined": manifest.codepoints.size(), "missing_before": old_missing,
   "missing_after": new_missing, "covered_by_added_fallback": added})
 print("FONT_FALLBACK_RESULT\t", JSON.stringify({"resources": results}))
 quit(0)
