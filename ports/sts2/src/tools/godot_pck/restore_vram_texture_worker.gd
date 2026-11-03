# INPUT: audited installed half-size RGB/RGBA WebP GST2 and private jobs
# OUTPUT: ASTC4x4 GST2 candidates and sampled alpha/color error metrics
# POS: offline CPU codec; no game scripts or scenes
extends SceneTree
const ALPHA_P99_MAX := 0.04
const ALPHA_MAX := 0.25
const RGB_P99_MAX := 0.04

func _initialize() -> void:
 var args := OS.get_cmdline_user_args()
 if args.size() != 1:
  quit(2)
  return
 var jobs = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
 if not jobs is Array:
  quit(2)
  return
 for index in jobs.size():
  var result: Dictionary = convert_job(jobs[index])
  if result.get("status") == "invalid":
   push_error("Invalid texture input at " + str(index))
   quit(1)
   return
  print("VRAM_RESULT\t", index, "\t", JSON.stringify(result))
 quit(0)

func convert_job(job: Dictionary) -> Dictionary:
 var source := FileAccess.get_file_as_bytes(job.input)
 if source.size() < 56 or source.decode_u32(36) != 2 or source.decode_u32(44) != 0 or source.decode_u32(48) not in [4, 5] or source.decode_u32(52) != source.size() - 56:
  return {"status":"invalid"}
 var w := source.decode_u16(40)
 var h := source.decode_u16(42)
 var original := Image.new()
 if original.load_webp_from_buffer(source.slice(56)) != OK or original.get_width() != w or original.get_height() != h:
  return {"status":"invalid"}
 original.convert(Image.FORMAT_RGBA8)
 var padded := Image.create(((w+3)/4)*4, ((h+3)/4)*4, false, Image.FORMAT_RGBA8)
 padded.blit_rect(original,Rect2i(0,0,w,h),Vector2i.ZERO)
 for x in range(w,padded.get_width()):
  padded.blit_rect(original,Rect2i(w-1,0,1,h),Vector2i(x,0))
 for y in range(h,padded.get_height()):
  padded.blit_rect(padded,Rect2i(0,h-1,padded.get_width(),1),Vector2i(0,y))
 if padded.compress(Image.COMPRESS_ASTC,Image.COMPRESS_SOURCE_GENERIC,Image.ASTC_FORMAT_4x4) != OK:
  return {"status":"invalid"}
 var payload := padded.get_data()
 var decoded := padded.duplicate() as Image
 if decoded.decompress() != OK:
  return {"status":"invalid"}
 var step := maxi(1, int(ceil(sqrt(float(w*h)/65536.0))))
 var alpha: Array[float] = []
 var rgb: Array[float] = []
 for y in range(step / 2,h,step):
  for x in range(step / 2,w,step):
   var a := original.get_pixel(x,y)
   var b := decoded.get_pixel(x,y)
   alpha.append(absf(a.a-b.a))
   if a.a > 0.05:
    rgb.append((absf(a.r-b.r)+absf(a.g-b.g)+absf(a.b-b.b))/3.0)
 if alpha.is_empty(): return {"status":"invalid"}
 alpha.sort()
 rgb.sort()
 var ap: float = alpha[int((alpha.size()-1)*0.99)]
 var am: float = alpha[-1]
 var rp: float = rgb[int((rgb.size()-1)*0.99)] if not rgb.is_empty() else 0.0
 var accepted := ap <= ALPHA_P99_MAX and am <= ALPHA_MAX and rp <= RGB_P99_MAX
 var result := {"status":"accepted" if accepted else "quality_rejected", "sample_step":step,
  "sample_count":alpha.size(), "visible_samples":rgb.size(), "alpha_p99":ap, "alpha_max":am,
  "visible_rgb_p99":rp, "limits":{"alpha_p99":ALPHA_P99_MAX,"alpha_max":ALPHA_MAX,"visible_rgb_p99":RGB_P99_MAX}}
 if accepted:
  source.resize(52)
  source.encode_u32(36,0)
  source.encode_u32(48,Image.FORMAT_ASTC_4x4)
  source.append_array(payload)
  var output := FileAccess.open(job.output,FileAccess.WRITE)
  if output == null: return {"status":"invalid"}
  output.store_buffer(source)
  output.close()
 return result
