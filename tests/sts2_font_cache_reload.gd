# INPUT: original and candidate FontFile paths from a private isolated fixture
# OUTPUT: checks source font bytes, cache pages, native settings and glyph metrics
# POS: Godot headless only; no game scene, device or user input
extends SceneTree
const KEYS = ["allow_system_fallback","antialiasing","disable_embedded_bitmaps","fixed_size","fixed_size_scale_mode","font_name","font_stretch","font_style","font_weight","force_autohinter","generate_mipmaps","hinting","keep_rounding_remainders","modulate_color_glyphs","msdf_pixel_range","msdf_size","multichannel_signed_distance_field","opentype_feature_overrides","oversampling","style_name","subpixel_positioning"]
func _initialize() -> void:
 call_deferred("_run")
func _run() -> void:
 var args := OS.get_cmdline_user_args()
 if args.size()!=2: quit(2);return
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
 for cp in [0x41,0x5b57,0x6740,0x5854,0x3002,0xff0c,0x9ad4,0x9f8d,0x10ffff]:
  var x:=a.get_glyph_index(48,cp,0);var y:=b.get_glyph_index(48,cp,0)
  if x!=y or a.has_char(cp)!=b.has_char(cp) or (x!=0 and a.get_glyph_advance(0,48,x)!=b.get_glyph_advance(0,48,y)): printerr("glyph metrics changed ",cp);quit(1);return
 print("FONT_RELOAD_OK")
 quit(0)
