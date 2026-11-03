# INPUT: isolated parent FontFiles and source-bound localization codepoints
# OUTPUT: three range-16 FontFiles and coverage/metric validation evidence
# POS: private offline trial; does not load game scenes, invoke logic, or touch a device
extends SceneTree
const PROPERTIES = ["allow_system_fallback", "antialiasing", "disable_embedded_bitmaps", "fixed_size", "fixed_size_scale_mode", "font_name", "font_stretch", "font_style", "font_weight", "force_autohinter", "generate_mipmaps", "hinting", "keep_rounding_remainders", "modulate_color_glyphs", "msdf_pixel_range", "msdf_size", "multichannel_signed_distance_field", "opentype_feature_overrides", "oversampling", "style_name", "subpixel_positioning"]
func _initialize(): call_deferred("run")
func sha(data: PackedByteArray) -> String:
 var h=HashingContext.new();h.start(HashingContext.HASH_SHA256);h.update(data);return h.finish().hex_encode()
func settings(f: FontFile) -> Dictionary:
 var d={}
 for key in PROPERTIES:d[key]=f.get(key)
 d.fallbacks=[]
 for item in f.fallbacks:d.fallbacks.append(item.resource_path)
 d.language={};d.script={};d.caches=[]
 for key in f.get_language_support_overrides():d.language[key]=f.get_language_support_override(key)
 for key in f.get_script_support_overrides():d.script[key]=f.get_script_support_override(key)
 for i in f.get_cache_count():d.caches.append({"variation":f.get_variation_coordinates(i),"face":f.get_face_index(i),"embolden":f.get_embolden(i),"transform":str(f.get_transform(i)),"baseline":f.get_extra_baseline_offset(i),"spacing":[f.get_extra_spacing(i,0),f.get_extra_spacing(i,1),f.get_extra_spacing(i,2),f.get_extra_spacing(i,3)]})
 return d
func pages(f: FontFile) -> int:
 var n=0
 for i in f.get_cache_count():
  for sz in f.get_size_cache_list(i):n+=f.get_texture_count(i,sz)
 return n
func variation(f: FontFile, embolden: float=0.0) -> FontVariation:
 var v=FontVariation.new();v.base_font=f;v.variation_embolden=embolden;v.variation_transform=Transform2D(Vector2(.95,0),Vector2(0,.95),Vector2.ZERO);v.baseline_offset=-.05;return v
func measure(f: Font) -> Dictionary:
 var d={}
 for size in [13,16,20,24,32,48,72]:
  var a=[]
  for ch in ["字","龙","杀","W","i","0","1","2","3","4","5","6","7","8","9","，"]:a.append(f.get_string_size(ch,HORIZONTAL_ALIGNMENT_LEFT,-1,size).x)
  d[str(size)]={"widths":a,"height":f.get_height(size),"ascent":f.get_ascent(size),"descent":f.get_descent(size)}
 return d
func run():
 var manifest=JSON.parse_string(FileAccess.get_file_as_string("res://manifest.json"))
 if manifest.codepoints.size()!=2493:printerr("Unexpected corpus");quit(1);return
 var before=[];var after=[];var results=[]
 for i in range(3):
  var f=ResourceLoader.load(manifest.fonts[i].input,"",ResourceLoader.CACHE_MODE_IGNORE) as FontFile
  if f==null or sha(f.data)!=manifest.fonts[i].data_sha or f.msdf_pixel_range!=24 or f.msdf_size!=48 or not f.multichannel_signed_distance_field or not f.allow_system_fallback or pages(f)!=0:printerr("Unexpected parent font");quit(2);return
  var original=settings(f);var data_hash=sha(f.data)
  f.msdf_pixel_range=16
  for idx in f.get_cache_count():f.clear_size_cache(idx)
  if ResourceSaver.save(f,manifest.fonts[i].output,ResourceSaver.FLAG_COMPRESS)!=OK:printerr("Cannot save");quit(3);return
  var output=ResourceLoader.load(manifest.fonts[i].output,"",ResourceLoader.CACHE_MODE_IGNORE) as FontFile
  var expected=original.duplicate(true);expected.msdf_pixel_range=16
  if output==null or sha(output.data)!=data_hash or settings(output)!=expected or pages(output)!=0:printerr("Font data/settings changed");quit(4);return
  var old=ResourceLoader.load(manifest.fonts[i].input,"",ResourceLoader.CACHE_MODE_IGNORE) as FontFile
  before.append(old);after.append(output)
  results.append({"input":manifest.fonts[i].input,"output":manifest.fonts[i].output,"font_data_sha256":data_hash,"before_settings":original,"after_settings":settings(output),"output_pages":0})
 var corpus=manifest.codepoints.duplicate()
 for cp in range(0x20,0x7f):if cp not in corpus:corpus.append(cp)
 for cp in range(0x3000,0x3040):if cp not in corpus:corpus.append(cp)
 for cp in range(0x4e00,0xa000):if cp not in corpus:corpus.append(cp)
 var comparison=[]
 for i in range(3):
  var source=before[i];var candidate=after[0] if i==1 else after[i]
  var losses=[];var game_loss=[];var old_missing=[];var gained=0
  for cp in corpus:
   var a=source.has_char(int(cp));var b=candidate.has_char(int(cp))
   if a and not b:losses.append(cp)
   if b and not a:gained+=1
  for cp in manifest.codepoints:
   var a=source.has_char(int(cp));var b=candidate.has_char(int(cp))
   if not a:old_missing.append(cp)
   if a and not b:game_loss.append(cp)
  if not losses.is_empty() or not game_loss.is_empty():printerr("Coverage loss");quit(5);return
  var old_m=measure(variation(source));var new_m=measure(variation(candidate,.3 if i==1 else 0.0))
  if i!=1 and old_m!=new_m:printerr("Unexpected metrics difference");quit(6);return
  var digits=new_m["48"].widths.slice(5,15)
  if i==2:
   for d in digits:
    if d!=digits[0]:printerr("Mono digits unequal");quit(7);return
  comparison.append({"game_count":manifest.codepoints.size(),"extended_count":corpus.size(),"old_missing_game":old_missing,"coverage_losses":losses,"gained":gained,"before_metrics":old_m,"after_metrics":new_m,"numeric_advances_48":digits})
 # The canonical imports are checked after serialization, without replacing the source PCK.
 for item in manifest.fonts:
  var err=DirAccess.copy_absolute(ProjectSettings.globalize_path(item.output),ProjectSettings.globalize_path(item.input))
  if err!=OK:printerr("Cannot stage serialized candidate");quit(8);return
 var bold=ResourceLoader.load("res://bold-shared.tres") as FontVariation
 var medium=ResourceLoader.load("res://themes/fonts/zhs/source_han_serif_sc_medium_shared.tres") as FontVariation
 var mono=ResourceLoader.load("res://themes/fonts/zhs/noto_sans_mono_cjksc_regular_shared.tres") as FontVariation
 if bold==null or medium==null or mono==null or not is_same(bold.base_font,medium.base_font):printerr("Shared canonical font is not reused");quit(9);return
 if bold.base_font.resource_path!="res://fonts/zhs/SourceHanSerifSC-Medium.otf" or mono.base_font.resource_path!="res://fonts/zhs/NotoSansMonoCJKsc-Regular.otf" or not is_equal_approx(bold.variation_embolden,.3) or not bold.fallbacks.is_empty():printerr("Unexpected shared resource settings ",bold.base_font.resource_path," ",mono.base_font.resource_path," ",bold.variation_embolden," ",bold.fallbacks);quit(10);return
 for font in [bold,medium,mono]:
  if font.variation_transform!=Transform2D(Vector2(.95,0),Vector2(0,.95),Vector2.ZERO) or not is_equal_approx(font.baseline_offset,-.05):printerr("Shared layout changed");quit(11);return
 if ResourceLoader.has_cached("res://fonts/zhs/SourceHanSerifSC-Bold.otf"):printerr("Bold source cached unexpectedly");quit(12);return
 var shared={"canonical_medium_same_instance":true,"bold_canonical_path":bold.base_font.resource_path,"mono_canonical_path":mono.base_font.resource_path,"bold_not_cached_in_isolated_fixture":true,"embolden":bold.variation_embolden,"transform":"0.95 scale","baseline":bold.baseline_offset,"bold_fallbacks":[],"system_fallback":bold.base_font.allow_system_fallback}
 print("FONT_BUDGET_RESULT\t",JSON.stringify({"fonts":results,"comparison":comparison,"shared_validation":shared}));quit()
