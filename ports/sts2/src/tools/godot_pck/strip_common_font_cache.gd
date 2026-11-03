# INPUT: isolated common FontFile and private output paths
# OUTPUT: pre-rendered size caches removed, metadata and glyph validation
# POS: offline Godot 4.5.1 worker; never opens the game or device
extends SceneTree
const PROPERTIES = ["allow_system_fallback", "antialiasing", "disable_embedded_bitmaps", "fixed_size", "fixed_size_scale_mode", "font_name", "font_stretch", "font_style", "font_weight", "force_autohinter", "generate_mipmaps", "hinting", "keep_rounding_remainders", "modulate_color_glyphs", "msdf_pixel_range", "msdf_size", "multichannel_signed_distance_field", "opentype_feature_overrides", "oversampling", "style_name", "subpixel_positioning"]
const SAMPLE = [0x41,0x61,0x5a,0x7a,0x30,0x39,0x2e,0x21,0x3f,0x25,0x2b,0x23,0x40,0x26]
func _initialize() -> void:
 call_deferred("_run")
func settings(font: FontFile) -> Dictionary:
 var value := {}
 for key in PROPERTIES: value[key] = font.get(key)
 value.fallbacks = []
 for fallback in font.get_fallbacks(): value.fallbacks.append(fallback.resource_path)
 value.language_overrides = {}
 for key in font.get_language_support_overrides(): value.language_overrides[key] = font.get_language_support_override(key)
 value.script_overrides = {}
 for key in font.get_script_support_overrides(): value.script_overrides[key] = font.get_script_support_override(key)
 value.caches = []
 for index in font.get_cache_count():
  value.caches.append({"variation":font.get_variation_coordinates(index), "face":font.get_face_index(index), "embolden":font.get_embolden(index), "transform":str(font.get_transform(index)), "baseline":font.get_extra_baseline_offset(index), "spacing":[font.get_extra_spacing(index,0),font.get_extra_spacing(index,1),font.get_extra_spacing(index,2),font.get_extra_spacing(index,3)]})
 return value
func sizes(font: FontFile) -> Array:
 var result := []
 for index in font.get_cache_count():
  var entries := []
  for size in font.get_size_cache_list(index): entries.append({"size":[size.x,size.y],"pages":font.get_texture_count(index,size)})
  result.append(entries)
 return result
func metrics(font: FontFile) -> Array:
 var result := []
 for size in [16,24,48]:
  for cp in SAMPLE:
   var glyph := font.get_glyph_index(size, cp, 0)
   if glyph == 0 or not font.has_char(cp):
    printerr("Missing expected Latin glyph ",cp)
    quit(1)
    return []
   var advance := font.get_glyph_advance(0,size,glyph)
   result.append({"size":size,"codepoint":cp,"present":font.has_char(cp),"glyph":glyph,"advance":[advance.x,advance.y]})
 return result
func data_sha(data: PackedByteArray) -> String:
 var context := HashingContext.new()
 context.start(HashingContext.HASH_SHA256)
 context.update(data)
 return context.finish().hex_encode()
func save_glyph(font: FontFile, path: String, size: int = 48) -> bool:
 var glyph := font.get_glyph_index(size,0x41,0)
 if glyph == 0: return false
 font.render_glyph(0,Vector2i(size,0),glyph)
 var page := font.get_glyph_texture_idx(0,Vector2i(size,0),glyph)
 var uv := font.get_glyph_uv_rect(0,Vector2i(size,0),glyph)
 var image := font.get_texture_image(0,Vector2i(size,0),page)
 if image == null or uv.size.x <= 0 or uv.size.y <= 0: return false
 return image.get_region(Rect2i(uv)).save_png(path) == OK
func fallback_size(font: FontFile) -> Vector2:
 var variation := FontVariation.new()
 variation.base_font = FontFile.new()
 variation.fallbacks = [font]
 return variation.get_string_size("AV az 09!? @%", HORIZONTAL_ALIGNMENT_LEFT, -1, 48)
func _run() -> void:
 var args := OS.get_cmdline_user_args()
 if args.size()!=4: quit(2); return
 var original := ResourceLoader.load(args[0],"",ResourceLoader.CACHE_MODE_IGNORE) as FontFile
 if original == null or original.data.is_empty(): printerr("Missing dynamic FontFile data");quit(1);return
 var before := settings(original)
 var source_data_sha := data_sha(original.data)
 var before_sizes := sizes(original)
 if before.caches.is_empty() or before_sizes.is_empty(): printerr("No precomputed font cache");quit(1);return
 var baseline := metrics(original)
 if baseline.size()!=SAMPLE.size()*3: printerr("Incomplete baseline glyphs");quit(1);return
 var fallback_before := fallback_size(original)
 if not save_glyph(original,args[3]+"-before.png"): printerr("Cannot render source glyph");quit(1);return
 if not save_glyph(original,args[3]+"-before16.png",16): printerr("Cannot render source small glyph");quit(1);return
 for index in original.get_cache_count(): original.clear_size_cache(index)
 var cleared_sizes := sizes(original)
 for entry in cleared_sizes:
  for cache in entry:
   if cache.pages != 0: printerr("Pre-rendered pages survived clear");quit(1);return
 if settings(original)!=before: printerr("Font settings changed on clear");quit(1);return
 var e := ResourceSaver.save(original,args[1],ResourceSaver.FLAG_COMPRESS)
 if e!=OK: printerr("Cannot save font ",e);quit(1);return
 var clean := ResourceLoader.load(args[1],"",ResourceLoader.CACHE_MODE_IGNORE) as FontFile
 if clean==null or data_sha(clean.data)!=source_data_sha or settings(clean)!=before: printerr("Saved font data or settings changed");quit(1);return
 var after_sizes := sizes(clean)
 for entry in after_sizes:
  for cache in entry:
   if cache.pages != 0: printerr("Reopened output has cached pages");quit(1);return
 var started := Time.get_ticks_usec()
 var actual := metrics(clean)
 if actual.size()!=SAMPLE.size()*3: printerr("Incomplete output glyphs");quit(1);return
 for item in actual:
  if item.glyph: clean.render_glyph(0,Vector2i(item.size,0),item.glyph)
 var elapsed := Time.get_ticks_usec()-started
 if not save_glyph(clean,args[3]+"-after.png"): printerr("Cannot render output glyph");quit(1);return
 if not save_glyph(clean,args[3]+"-after16.png",16): printerr("Cannot render output small glyph");quit(1);return
 var original_image := Image.load_from_file(args[3]+"-before.png")
 var clean_image := Image.load_from_file(args[3]+"-after.png")
 if original_image == null or clean_image == null or original_image.get_data() != clean_image.get_data(): printerr("Glyph pixels changed");quit(1);return
 var original_small := Image.load_from_file(args[3]+"-before16.png")
 var clean_small := Image.load_from_file(args[3]+"-after16.png")
 if original_small == null or clean_small == null or original_small.get_data() != clean_small.get_data(): printerr("Small glyph pixels changed");quit(1);return
 var preview_dir := OS.get_environment("SLL_COMMON_FONT_PREVIEW_DIR")
 if not preview_dir.is_empty():
  for side in ["before", "after"]:
   var path: String = args[3]+"-"+side+".png"
   if DirAccess.copy_absolute(path,preview_dir.path_join(path.get_file())) != OK: printerr("Cannot copy preview");quit(1);return
 if actual!=baseline: printerr("Glyph metrics differ: ",JSON.stringify({"before":baseline,"after":actual}));quit(1);return
 if fallback_size(clean)!=fallback_before: printerr("Fallback shaping changed");quit(1);return
 var datafile := FileAccess.open(args[2],FileAccess.WRITE)
 if datafile==null: printerr("Cannot save font bytes");quit(1);return
 datafile.store_buffer(clean.data);datafile.close()
 print("FONT_RESULT\t",JSON.stringify({"font_data_sha256":source_data_sha,"settings":before,"before_sizes":before_sizes,"after_sizes":after_sizes,"metrics":actual,"fallback_size":[fallback_before.x,fallback_before.y],"glyph_pixels_sha256":data_sha(original_image.get_data()),"glyph_16_pixels_sha256":data_sha(original_small.get_data()),"cold_sample_us":elapsed,"sample_scope":"14 required Latin, digit and punctuation codepoints at 16, 24 and 48, forced glyph generation; headless host, not device latency"}))
 quit(0)
