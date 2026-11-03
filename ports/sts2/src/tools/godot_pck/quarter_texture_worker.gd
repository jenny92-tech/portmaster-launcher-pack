# INPUT: audited original Windows GST2 WebP or BC single-level texture jobs
# OUTPUT: original-quarter ASTC8 GST2 and bounded alpha/color quality metadata
# POS: offline Godot CPU codecs only; no game scenes, device, or resource loading
extends SceneTree
const LIMITS := {"alpha_p99": 0.08, "alpha_max": 0.35, "visible_rgb_p99": 0.18}

func _initialize() -> void:
 var args := OS.get_cmdline_user_args()
 if args.size() != 1: quit(2); return
 var jobs = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
 if not jobs is Array: quit(2); return
 for i in jobs.size():
  var result: Dictionary = convert_job(jobs[i])
  if result.get("status") == "invalid": push_error("invalid quarter texture " + str(i)); quit(1); return
  print("QUARTER_RESULT\t", i, "\t", JSON.stringify(result))
 quit(0)

func convert_job(job: Dictionary) -> Dictionary:
 var source := FileAccess.get_file_as_bytes(job.input)
 if source.size() < 56 or source.decode_u32(44) != 0: return {"status":"invalid"}
 var w := source.decode_u16(40)
 var h := source.decode_u16(42)
 var dtype := source.decode_u32(36)
 var fmt := source.decode_u32(48)
 var image: Image
 if dtype == 2 and fmt in [4, 5] and source.decode_u32(52) == source.size() - 56:
  image = Image.new()
  if image.load_webp_from_buffer(source.slice(56)) != OK: return {"status":"invalid"}
 elif dtype == 0 and fmt in [17, 19, 22]:
  image = Image.create_from_data(w,h,false,fmt,source.slice(52))
  if image == null or image.is_empty() or image.decompress() != OK: return {"status":"invalid"}
 else: return {"status":"invalid"}
 if image.get_width() != w or image.get_height() != h: return {"status":"invalid"}
 image.convert(Image.FORMAT_RGBA8)
 w = maxi(1, w / 4)
 h = maxi(1, h / 4)
 image.resize(w,h,Image.INTERPOLATE_LANCZOS)
 var padded := Image.create(((w+7)/8)*8,((h+7)/8)*8,false,Image.FORMAT_RGBA8)
 padded.blit_rect(image,Rect2i(0,0,w,h),Vector2i.ZERO)
 for x in range(w,padded.get_width()): padded.blit_rect(image,Rect2i(w-1,0,1,h),Vector2i(x,0))
 for y in range(h,padded.get_height()): padded.blit_rect(padded,Rect2i(0,h-1,padded.get_width(),1),Vector2i(0,y))
 if padded.compress(Image.COMPRESS_ASTC,Image.COMPRESS_SOURCE_GENERIC,Image.ASTC_FORMAT_8x8) != OK: return {"status":"invalid"}
 var payload := padded.get_data()
 var decoded := padded.duplicate() as Image
 if decoded.decompress() != OK: return {"status":"invalid"}
 var step := maxi(1,int(ceil(sqrt(float(w*h)/16384.0))))
 var alpha: Array[float] = []
 var rgb: Array[float] = []
 for y in range(step/2,h,step):
  for x in range(step/2,w,step):
   var a := image.get_pixel(x,y)
   var b := decoded.get_pixel(x,y)
   alpha.append(absf(a.a-b.a))
   if a.a > 0.05: rgb.append((absf(a.r-b.r)+absf(a.g-b.g)+absf(a.b-b.b))/3.0)
 if alpha.is_empty(): return {"status":"invalid"}
 alpha.sort(); rgb.sort()
 var ap: float = alpha[int((alpha.size()-1)*0.99)]
 var am: float = alpha[-1]
 var rp: float = rgb[int((rgb.size()-1)*0.99)] if not rgb.is_empty() else 0.0
 var accepted := ap <= LIMITS.alpha_p99 and am <= LIMITS.alpha_max and rp <= LIMITS.visible_rgb_p99
 var result := {"status":"accepted" if accepted else "quality_rejected", "sample_step":step, "sample_count":alpha.size(), "visible_samples":rgb.size(), "alpha_p99":ap, "alpha_max":am, "visible_rgb_p99":rp, "limits":LIMITS}
 if accepted:
  source.resize(52)
  source.encode_u32(36,0)
  source.encode_u16(40,w); source.encode_u16(42,h)
  source.encode_u32(48,Image.FORMAT_ASTC_8x8)
  source.append_array(payload)
  var f := FileAccess.open(job.output,FileAccess.WRITE)
  if f == null: return {"status":"invalid"}
  f.store_buffer(source); f.close()
 return result
