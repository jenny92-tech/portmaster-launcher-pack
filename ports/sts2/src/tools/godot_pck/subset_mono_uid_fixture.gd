# INPUT: full parent PCK, one-font candidate delta and original Mono resource
# OUTPUT: UID/cache identity, known-codepoint coverage and full sampled text metrics
# POS: isolated headless Linux Godot process; no real game root or logic
extends SceneTree
const MONO="res://fonts/zhs/NotoSansMonoCJKsc-Regular.otf"
const MEDIUM="res://fonts/zhs/SourceHanSerifSC-Medium.otf"
const SHARED="res://themes/fonts/zhs/noto_sans_mono_cjksc_regular_shared.tres"
const MEDIUM_SHARED="res://themes/fonts/zhs/source_han_serif_sc_medium_shared.tres"
func _initialize():call_deferred("run")
func vary(f:Font)->FontVariation:
 var v=FontVariation.new();v.base_font=f;v.variation_transform=Transform2D(Vector2(.95,0),Vector2(0,.95),Vector2.ZERO);v.baseline_offset=-.05;return v
func run():
 var old=ResourceLoader.load("res://original.res","",ResourceLoader.CACHE_MODE_IGNORE) as FontFile
 if old==null or not ProjectSettings.load_resource_pack("/parent.pck",true) or not ProjectSettings.load_resource_pack("/delta.pck",true):printerr("fixture input failed");quit(1);return
 var id=ResourceUID.text_to_id("uid://odbxx5stx1as")
 if not ResourceUID.has_id(id) or ResourceUID.get_id_path(id)!=MEDIUM:printerr("parent UID cache missing");quit(2);return
 var m=load(MEDIUM_SHARED) as FontVariation;var v=load(SHARED) as FontVariation
 if m==null or v==null or v.base_font==null:quit(3);return
 var font=v.base_font as FontFile
 if font==null or font.resource_path!=MONO or font.fallbacks.size()!=1:printerr("wrong mono font");quit(4);return
 var fallback=font.fallbacks[0] as FontVariation
 if fallback==null or not is_same(fallback.base_font,m.base_font) or fallback.base_font.resource_path!=MEDIUM or not font.allow_system_fallback:printerr("wrong fallback instance");quit(5);return
 var original=vary(old);var cps=JSON.parse_string(FileAccess.get_file_as_string("/fixture/manifest.json")).codepoints
 var losses=[];var mismatches=[];var count=0
 for cp in cps:
  var c=int(cp)
  if original.has_char(c) and not v.has_char(c):losses.append(c)
  if old.has_char(c):
   count+=1
   for size in [16,32,48]:
    var a=original.get_string_size(String.chr(c),HORIZONTAL_ALIGNMENT_LEFT,-1,size).x
    var b=v.get_string_size(String.chr(c),HORIZONTAL_ALIGNMENT_LEFT,-1,size).x
    if a!=b:
     if mismatches.size()<32:mismatches.append([c,size,a,b])
     break
 var all_font_losses=[];var original_chars=old.get_supported_chars()
 for ch in original_chars:
  var cp=ch.unicode_at(0)
  if not v.has_char(cp):
   if all_font_losses.size()<32:all_font_losses.append(cp)
 var longtail={}
 for cp in [0x279c,0xe0044,0x20000,0x1f600,0x9fff]:longtail[str(cp)]=[original.has_char(cp),v.has_char(cp)]
 var string_diffs=[]
 for text in ["0123456789","AVATAR","杀戮尖塔，准备战斗！","力量 1234567890","龍龘龥","𠀀龘繁體abc0123","user_2026"]:
  for size in [16,32,48]:
   var a=original.get_string_size(text,HORIZONTAL_ALIGNMENT_LEFT,-1,size);var b=v.get_string_size(text,HORIZONTAL_ALIGNMENT_LEFT,-1,size)
   if a!=b:string_diffs.append([text,size,str(a),str(b)])
 var digits=[]
 for d in range(10):digits.append(v.get_string_size(str(d),HORIZONTAL_ALIGNMENT_LEFT,-1,48).x)
 var metrics=[]
 for sz in [16,32,48]:metrics.append([sz,original.get_height(sz),v.get_height(sz),original.get_ascent(sz),v.get_ascent(sz),original.get_descent(sz),v.get_descent(sz)])
 var result={"game_count":cps.size(),"compared_count":count,"coverage_losses":losses,"original_supported_count":original_chars.length(),"all_font_losses":all_font_losses,"longtail":longtail,"width_mismatches":mismatches,"string_differences":string_diffs,"digit_widths":digits,"line_metrics":metrics,"mono_path":font.resource_path,"medium_path":fallback.base_font.resource_path,"same_medium_instance":is_same(fallback.base_font,m.base_font),"canonical_medium_cached":ResourceLoader.has_cached(MEDIUM),"system_fallback":font.allow_system_fallback,"fallback_count":font.fallbacks.size()}
 print("MONO_UID_RESULT\t",JSON.stringify(result))
 if not losses.is_empty() or not all_font_losses.is_empty() or not mismatches.is_empty() or not string_diffs.is_empty() or digits.any(func(x):return x!=digits[0]):quit(6);return
 for row in metrics:
  if row[1]!=row[2] or row[3]!=row[4] or row[5]!=row[6]:quit(7);return
 quit()
