# INPUT: source-bound Mono/Medium FontFiles in an isolated Godot project
# OUTPUT: extracted vectors or serialized Mono subset with canonical Medium fallback
# POS: offline worker; does not load game scenes or touch the device
extends SceneTree
const MONO="res://fonts/zhs/NotoSansMonoCJKsc-Regular.otf"
const MEDIUM="res://fonts/zhs/SourceHanSerifSC-Medium.otf"
const PROPERTIES=["allow_system_fallback","antialiasing","disable_embedded_bitmaps","fixed_size","fixed_size_scale_mode","font_name","font_stretch","font_style","font_weight","force_autohinter","generate_mipmaps","hinting","keep_rounding_remainders","modulate_color_glyphs","msdf_pixel_range","msdf_size","multichannel_signed_distance_field","opentype_feature_overrides","oversampling","style_name","subpixel_positioning"]
func _initialize():call_deferred("run")
func sha(data:PackedByteArray)->String:
 var h=HashingContext.new();h.start(HashingContext.HASH_SHA256);h.update(data);return h.finish().hex_encode()
func settings(f:FontFile)->Dictionary:
 var d={}
 for key in PROPERTIES:d[key]=f.get(key)
 d.language={};d.script={};d.caches=[]
 for k in f.get_language_support_overrides():d.language[k]=f.get_language_support_override(k)
 for k in f.get_script_support_overrides():d.script[k]=f.get_script_support_override(k)
 for i in f.get_cache_count():d.caches.append({"variation":f.get_variation_coordinates(i),"face":f.get_face_index(i),"embolden":f.get_embolden(i),"transform":str(f.get_transform(i)),"baseline":f.get_extra_baseline_offset(i),"spacing":[f.get_extra_spacing(i,0),f.get_extra_spacing(i,1),f.get_extra_spacing(i,2),f.get_extra_spacing(i,3)]})
 return d
func pages(f:FontFile)->int:
 var n=0
 for i in f.get_cache_count():
  for sz in f.get_size_cache_list(i):n+=f.get_texture_count(i,sz)
 return n
func put(path:String,data:PackedByteArray)->void:
 var f=FileAccess.open(path,FileAccess.WRITE);f.store_buffer(data)
func run():
 var args=OS.get_cmdline_user_args()
 if args.size()!=1:quit(1);return
 var mono=load(MONO) as FontFile;var medium=load(MEDIUM) as FontFile
 if mono==null or medium==null or sha(mono.data)!="2b1dbdc50df666a00c50ecd77377e2394c6babd35a71e37505ab411ff55c7906" or sha(medium.data)!="210dc788c6cc15ed693c8ecde93ee83bf7714b759befa6aead042d6f6e1b878a" or not mono.fallbacks.is_empty() or not mono.allow_system_fallback or pages(mono)!=0:printerr("Unexpected input fonts");quit(2);return
 if args[0]=="extract":
  put("res://mono.otf",mono.data);put("res://medium.otf",medium.data);print("MONO_EXTRACT_OK");quit();return
 if args[0]!="produce":quit(3);return
 var data=FileAccess.get_file_as_bytes("res://subset.otf")
 if data.is_empty():quit(4);return
 var original=settings(mono)
 var fallback=FontVariation.new();fallback.base_font=medium;fallback.variation_transform=Transform2D(Vector2(.95,0),Vector2(0,.95),Vector2.ZERO);fallback.baseline_offset=-.05
 mono.data=data;mono.fallbacks=[fallback]
 for i in mono.get_cache_count():mono.clear_size_cache(i)
 if ResourceSaver.save(mono,"res://candidate.res",ResourceSaver.FLAG_COMPRESS)!=OK:printerr("Save failed");quit(5);return
 var restored=ResourceLoader.load("res://candidate.res","",ResourceLoader.CACHE_MODE_IGNORE) as FontFile
 if restored==null or sha(restored.data)!=sha(data) or settings(restored)!=original or pages(restored)!=0 or restored.fallbacks.size()!=1:printerr("Subset reload mismatch");quit(6);return
 var f=restored.fallbacks[0] as FontVariation
 if f==null or not is_same(f.base_font,medium) or not is_equal_approx(f.baseline_offset,-.05) or f.variation_transform!=fallback.variation_transform or not restored.allow_system_fallback:printerr("Fallback mismatch");quit(7);return
 print("MONO_CANDIDATE\t",JSON.stringify({"vector_sha256":sha(data),"original_settings":original,"restored_settings":settings(restored),"pages":pages(restored),"fallback_base":f.base_font.resource_path,"same_medium":is_same(f.base_font,medium),"system_fallback":restored.allow_system_fallback,"fallback_baseline":f.baseline_offset,"dependencies":ResourceLoader.get_dependencies("res://candidate.res")}));quit()
