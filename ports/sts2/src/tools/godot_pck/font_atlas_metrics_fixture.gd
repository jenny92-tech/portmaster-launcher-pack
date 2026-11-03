# INPUT: fixed full parent PCK and privately extracted localized corpus
# OUTPUT: fixed-glyph atlas metadata, coverage and sampled text metrics
# POS: isolated headless Godot process; no game scene or device
extends SceneTree
const MEDIUM="res://fonts/zhs/SourceHanSerifSC-Medium.otf"
const MONO="res://fonts/zhs/NotoSansMonoCJKsc-Regular.otf"
const COMMON=["res://fonts/bitter_medium_italic.ttf","res://fonts/kreon_bold.ttf","res://fonts/kreon_regular.ttf","res://fonts/source_code_pro_medium.ttf","res://fonts/source_code_pro_semibold.ttf","res://fonts/spectral_bold.ttf"]
const SIZES=[13,16,20,24,32,48,72]
func _initialize():call_deferred("run")
func vary(f:Font,weight:float=0.0)->FontVariation:
 var v=FontVariation.new();v.base_font=f;v.variation_embolden=weight;v.variation_transform=Transform2D(Vector2(.95,0),Vector2(0,.95),Vector2.ZERO);v.baseline_offset=-.05;return v
func pages(f:FontFile)->Dictionary:
 var n=0;var b=0;var formats={}
 for i in f.get_cache_count():
  for size in f.get_size_cache_list(i):
   for j in f.get_texture_count(i,size):
    var img=f.get_texture_image(i,size,j)
    if img:
     n+=1
     var key=str(img.get_width())+"x"+str(img.get_height())+"/"+str(img.get_format());formats[key]=formats.get(key,0)+1
     if img.get_format()==Image.FORMAT_RGBA8:b+=img.get_width()*img.get_height()*4
 return {"pages":n,"rgba8_nominal_bytes":b,"formats":formats}
func details(f:FontFile)->Dictionary:return {"size":f.msdf_size,"range":f.msdf_pixel_range,"msdf":f.multichannel_signed_distance_field,"pages":pages(f)}
func run():
 var args=OS.get_cmdline_user_args();var target_size=int(args[0]);var target_range=int(args[1])
 var corpus=JSON.parse_string(FileAccess.get_file_as_string("/fixture/corpus.json"))
 if not ProjectSettings.load_resource_pack("/parent.pck",true):quit(1);return
 var medium=load(MEDIUM) as FontFile;var mono=load(MONO) as FontFile
 if medium==null or mono==null or medium.msdf_size!=48 or medium.msdf_pixel_range!=16 or mono.msdf_size!=48 or mono.msdf_pixel_range!=16:printerr("baseline mismatch");quit(2);return
 var baseline={"medium":details(medium),"mono":details(mono),"common":{}}
 for path in COMMON:
  var f=load(path) as FontFile
  if f==null:printerr("common missing");quit(3);return
  baseline.common[path]=details(f)
 var newmedium=medium.duplicate(true) as FontFile;newmedium.msdf_size=target_size;newmedium.msdf_pixel_range=target_range
 var newmono=mono.duplicate(true) as FontFile
 var fallback=vary(newmedium);newmono.fallbacks=[fallback]
 var oldfonts=[vary(medium),vary(medium,.3),vary(mono)];var newfonts=[vary(newmedium),vary(newmedium,.3),vary(newmono)]
 # Same ordered 500 actual simplified Chinese glyphs in both font atlases.
 var generated=0
 for cp in corpus.codepoints.zhs:
  if cp>=0x4e00 and cp<=0x9fff and medium.has_char(cp):
   var oldindex=medium.get_glyph_index(48,cp,0);var newindex=newmedium.get_glyph_index(48,cp,0)
   medium.render_glyph(0,Vector2i(48,0),oldindex);newmedium.render_glyph(0,Vector2i(48,0),newindex)
   generated+=1
   if generated==500:break
 var page_compare={"baseline":pages(medium),"candidate":pages(newmedium),"glyphs":generated}
 var comparisons=[]
 var all=[]
 for cp in corpus.codepoints.zhs:if cp not in all:all.append(cp)
 for cp in corpus.codepoints.eng:if cp not in all:all.append(cp)
 for role in range(3):
  var diffs=0;var max_diff=0.0;var examples=[];var count=0;var coverage_losses=[];var lines=[];var string_diff=[]
  for cp in all:
   if oldfonts[role].has_char(cp) and not newfonts[role].has_char(cp):coverage_losses.append(cp)
   if not oldfonts[role].has_char(cp):continue
   count+=1
   for size in SIZES:
    var a=oldfonts[role].get_string_size(String.chr(cp),HORIZONTAL_ALIGNMENT_LEFT,-1,size).x
    var b=newfonts[role].get_string_size(String.chr(cp),HORIZONTAL_ALIGNMENT_LEFT,-1,size).x
    if a!=b:
     diffs+=1;max_diff=max(max_diff,abs(a-b))
     if examples.size()<8:examples.append([cp,size,a,b])
  for size in SIZES:lines.append([size,oldfonts[role].get_height(size),newfonts[role].get_height(size),oldfonts[role].get_ascent(size),newfonts[role].get_ascent(size),oldfonts[role].get_descent(size),newfonts[role].get_descent(size)])
  for sample in corpus.samples:
   for size in [16,24,32,48]:
    var a=oldfonts[role].get_string_size(sample.text,HORIZONTAL_ALIGNMENT_LEFT,-1,size);var b=newfonts[role].get_string_size(sample.text,HORIZONTAL_ALIGNMENT_LEFT,-1,size)
    if a!=b:string_diff.append({"language":sample.lang,"category":sample.category,"chars":sample.text.length(),"size":size,"width_delta":b.x-a.x,"height_delta":b.y-a.y})
  comparisons.append({"role":["medium","synthetic_bold","mono"][role],"compared_codepoints":count,"width_mismatch_count":diffs,"max_width_delta":max_diff,"width_examples":examples,"coverage_losses":coverage_losses,"line_metrics":lines,"string_diff_count":string_diff.size(),"string_diff_examples":string_diff.slice(0,8)})
 print("ATLAS_RESULT\t",JSON.stringify({"msdf_size":target_size,"range":target_range,"baseline_metadata":baseline,"fixed_500_medium":page_compare,"comparisons":comparisons,"candidate_medium_same_instance":is_same(fallback.base_font,newmedium),"corpus_sizes":[corpus.codepoints.zhs.size(),corpus.codepoints.eng.size()],"sample_string_count":corpus.samples.size()}));quit()
