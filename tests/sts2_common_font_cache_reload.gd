# INPUT: original FontFile, candidate import path and UID from a private isolated fixture
# OUTPUT: checks source font bytes, UID, cache pages, Latin glyph metrics and image
# POS: Godot headless only; no game scene, device or user input
extends SceneTree
const KEYS = ["allow_system_fallback","antialiasing","disable_embedded_bitmaps","fixed_size","fixed_size_scale_mode","font_name","font_stretch","font_style","font_weight","force_autohinter","generate_mipmaps","hinting","keep_rounding_remainders","modulate_color_glyphs","msdf_pixel_range","msdf_size","multichannel_signed_distance_field","opentype_feature_overrides","oversampling","style_name","subpixel_positioning"]
func _initialize() -> void:
 call_deferred("_run")
func _run() -> void:
 var args := OS.get_cmdline_user_args()
 if args.size()!=3: quit(2);return
 if ResourceLoader.get_resource_uid(args[1]) != ResourceUID.text_to_id(args[2]): printerr("import UID mismatch");quit(1);return
 var a := ResourceLoader.load(args[0],"",ResourceLoader.CACHE_MODE_IGNORE) as FontFile
 var b := ResourceLoader.load(args[1],"",ResourceLoader.CACHE_MODE_IGNORE) as FontFile
 if a==null or b==null or a.data!=b.data or a.get_cache_count()!=b.get_cache_count(): printerr("font data/cache changed");quit(1);return
 for key in KEYS:
  if a.get(key)!=b.get(key): printerr("property changed ",key);quit(1);return
 if a.get_fallbacks()!=b.get_fallbacks() or a.get_language_support_overrides()!=b.get_language_support_overrides() or a.get_script_support_overrides()!=b.get_script_support_overrides(): printerr("fallback/override changed");quit(1);return
 for i in a.get_cache_count():
  if a.get_variation_coordinates(i)!=b.get_variation_coordinates(i) or a.get_face_index(i)!=b.get_face_index(i) or a.get_embolden(i)!=b.get_embolden(i) or a.get_transform(i)!=b.get_transform(i) or a.get_extra_baseline_offset(i)!=b.get_extra_baseline_offset(i): printerr("variation changed");quit(1);return
  for kind in 4:
   if a.get_extra_spacing(i,kind)!=b.get_extra_spacing(i,kind):printerr("spacing changed");quit(1);return
  for size in b.get_size_cache_list(i):
   if b.get_texture_count(i,size)!=0: printerr("cache pages survived");quit(1);return
 for size in [16,24,48]:
  for cp in [0x41,0x61,0x5a,0x7a,0x30,0x39,0x2e,0x21,0x3f,0x25,0x2b,0x23,0x40,0x26]:
   var x:=a.get_glyph_index(size,cp,0);var y:=b.get_glyph_index(size,cp,0)
   if x==0 or not a.has_char(cp) or not b.has_char(cp) or x!=y or a.get_glyph_advance(0,size,x)!=b.get_glyph_advance(0,size,y): printerr("glyph metrics changed ",cp," size ",size);quit(1);return
 for size in [16,48]:
  var ga := a.get_glyph_index(size,0x41,0)
  var gb := b.get_glyph_index(size,0x41,0)
  a.render_glyph(0,Vector2i(size,0),ga)
  b.render_glyph(0,Vector2i(size,0),gb)
  var ua := a.get_glyph_uv_rect(0,Vector2i(size,0),ga)
  var ub := b.get_glyph_uv_rect(0,Vector2i(size,0),gb)
  var ia := a.get_texture_image(0,Vector2i(size,0),a.get_glyph_texture_idx(0,Vector2i(size,0),ga))
  var ib := b.get_texture_image(0,Vector2i(size,0),b.get_glyph_texture_idx(0,Vector2i(size,0),gb))
  if ia==null or ib==null or ua.size!=ub.size or ia.get_region(Rect2i(ua)).get_data()!=ib.get_region(Rect2i(ub)).get_data(): printerr("glyph A pixels changed at size ",size);quit(1);return
 print("COMMON_FONT_RELOAD_OK")
 quit(0)
