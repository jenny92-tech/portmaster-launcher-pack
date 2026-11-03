# INPUT: complete 9caf parent and one-entry Medium font candidate
# OUTPUT: canonical UID, cache and Mono shared-fallback identity validation
# POS: isolated headless process; does not instantiate the game
extends SceneTree
const MEDIUM="res://fonts/zhs/SourceHanSerifSC-Medium.otf"
const BOLD="res://themes/fonts/zhs/source_han_serif_sc_bold_shared.tres"
const REGULAR="res://themes/fonts/zhs/source_han_serif_sc_medium_shared.tres"
const MONO="res://themes/fonts/zhs/noto_sans_mono_cjksc_regular_shared.tres"
func _initialize():call_deferred("run")
func run():
 if not ProjectSettings.load_resource_pack("/parent.pck",true) or not ProjectSettings.load_resource_pack("/delta.pck",true):quit(1);return
 var uid=ResourceUID.text_to_id("uid://odbxx5stx1as")
 if not ResourceUID.has_id(uid) or ResourceUID.get_id_path(uid)!=MEDIUM:printerr("UID mismatch");quit(2);return
 var bold=load(BOLD) as FontVariation;var regular=load(REGULAR) as FontVariation;var mono=load(MONO) as FontVariation
 if bold==null or regular==null or mono==null or bold.base_font==null or mono.base_font==null:quit(3);return
 var f=regular.base_font as FontFile;var m=mono.base_font as FontFile
 if f==null or m==null or m.fallbacks.size()!=1:quit(4);return
 var fallback=m.fallbacks[0] as FontVariation
 var same=is_same(bold.base_font,f) and fallback!=null and is_same(fallback.base_font,f)
 var data={"canonical":f.resource_path,"uid":ResourceUID.get_id_path(uid),"same_medium":same,"msdf_size":f.msdf_size,"msdf_range":f.msdf_pixel_range,"mono_size":m.msdf_size,"mono_range":m.msdf_pixel_range,"system_fallback":f.allow_system_fallback and m.allow_system_fallback,"cached":ResourceLoader.has_cached(MEDIUM)}
 if f.resource_path!=MEDIUM or not same or f.msdf_size!=40 or f.msdf_pixel_range!=14 or m.msdf_size!=48 or m.msdf_pixel_range!=16 or not data.system_fallback:printerr("Font cache identity mismatch");quit(5);return
 print("FONT_ATLAS_UID\t",JSON.stringify(data));quit()
