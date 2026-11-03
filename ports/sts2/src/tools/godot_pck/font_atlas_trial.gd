# INPUT: isolated 9caf Medium FontFile with validated complete vector data
# OUTPUT: 40/14 MSDF candidate, exact settings/data and cache evidence
# POS: offline host worker; never executes game logic or modifies the parent pack
extends SceneTree
const PROPS=["allow_system_fallback","antialiasing","disable_embedded_bitmaps","fixed_size","fixed_size_scale_mode","font_name","font_stretch","font_style","font_weight","force_autohinter","generate_mipmaps","hinting","keep_rounding_remainders","modulate_color_glyphs","msdf_pixel_range","msdf_size","multichannel_signed_distance_field","opentype_feature_overrides","oversampling","style_name","subpixel_positioning"]
func _initialize():call_deferred("run")
func sha(b:PackedByteArray)->String:
 var h=HashingContext.new();h.start(HashingContext.HASH_SHA256);h.update(b);return h.finish().hex_encode()
func settings(f:FontFile)->Dictionary:
 var d={}
 for k in PROPS:d[k]=f.get(k)
 d.fallbacks=[];d.language={};d.script={};d.caches=[]
 for x in f.fallbacks:d.fallbacks.append(x.resource_path)
 for k in f.get_language_support_overrides():d.language[k]=f.get_language_support_override(k)
 for k in f.get_script_support_overrides():d.script[k]=f.get_script_support_override(k)
 for i in f.get_cache_count():d.caches.append({"variation":f.get_variation_coordinates(i),"face":f.get_face_index(i),"embolden":f.get_embolden(i),"transform":str(f.get_transform(i)),"baseline":f.get_extra_baseline_offset(i),"spacing":[f.get_extra_spacing(i,0),f.get_extra_spacing(i,1),f.get_extra_spacing(i,2),f.get_extra_spacing(i,3)]})
 return d
func pages(f:FontFile)->int:
 var n=0
 for i in f.get_cache_count():
  for sz in f.get_size_cache_list(i):n+=f.get_texture_count(i,sz)
 return n
func run():
 var f=ResourceLoader.load("res://medium.res","",ResourceLoader.CACHE_MODE_IGNORE) as FontFile
 if f==null or sha(f.data)!="210dc788c6cc15ed693c8ecde93ee83bf7714b759befa6aead042d6f6e1b878a" or f.msdf_size!=48 or f.msdf_pixel_range!=16 or not f.multichannel_signed_distance_field or not f.allow_system_fallback or pages(f)!=0:printerr("Parent font mismatch");quit(1);return
 var before=settings(f);f.msdf_size=40;f.msdf_pixel_range=14
 for i in f.get_cache_count():f.clear_size_cache(i)
 if ResourceSaver.save(f,"res://candidate.res",ResourceSaver.FLAG_COMPRESS)!=OK:quit(2);return
 var result=ResourceLoader.load("res://candidate.res","",ResourceLoader.CACHE_MODE_IGNORE) as FontFile
 var expected=before.duplicate(true);expected.msdf_size=40;expected.msdf_pixel_range=14
 if result==null or sha(result.data)!=sha(f.data) or settings(result)!=expected or pages(result)!=0:printerr("Unexpected serialized font");quit(3);return
 print("FONT_ATLAS_RESULT\t",JSON.stringify({"vector_sha256":sha(result.data),"before":before,"after":settings(result),"pages":pages(result)}));quit()
