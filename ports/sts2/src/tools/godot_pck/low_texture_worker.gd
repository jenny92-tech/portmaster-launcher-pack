# INPUT:  Godot 4.5.1 Image CPU codecs 与 JSON 任务清单
# OUTPUT: 保留纹理逻辑尺寸和标志的半尺寸 GST2 文件
# POS:    在无窗口进程中转换纹理的实际像素数据
extends SceneTree

func _initialize() -> void:
 var args := OS.get_cmdline_user_args()
 if args.size() != 1:
  push_error("expected job JSON path")
  quit(2)
  return
 var jobs: Variant = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
 if not jobs is Array:
  push_error("invalid job JSON")
  quit(2)
  return
 for index in range(jobs.size()):
  var job: Dictionary = jobs[index]
  var started := Time.get_ticks_usec()
  if not convert_texture(job):
   push_error("texture conversion failed: " + str(job))
   quit(1)
   return
  print("TEXTURE_DONE\t", index, "\t", Time.get_ticks_usec() - started)
 quit(0)

func convert_texture(job: Dictionary) -> bool:
 var source := FileAccess.get_file_as_bytes(job["input"])
 if source.size() < 52:
  return false
 var dtype: int = source.decode_u32(36)
 var width: int = source.decode_u16(40)
 var height: int = source.decode_u16(42)
 var mips: int = source.decode_u32(44)
 var format: int = source.decode_u32(48)
 var image: Image
 if dtype == 0:
  image = Image.create_from_data(width, height, mips > 0, format, source.slice(52))
  if image == null or image.is_empty() or image.decompress() != OK:
   return false
 elif dtype == 2 and mips == 0:
  var length := source.decode_u32(52)
  if length != source.size() - 56:
   return false
  image = Image.new()
  if image.load_webp_from_buffer(source.slice(56)) != OK:
   return false
  if image.get_width() != width or image.get_height() != height:
   return false
  image.convert(format)
 else:
  return false
 var target_width := maxi(1, width / 2)
 var target_height := maxi(1, height / 2)
 image.resize(target_width, target_height, Image.INTERPOLATE_LANCZOS)
 if mips != 0:
  return false
 var payload: PackedByteArray
 if dtype == 0:
  var block := 8 if format == Image.FORMAT_ASTC_8x8 else 4
  # Godot's encoder resizes unaligned images. Pad by extending edge pixels
  # ourselves so the stored header can describe the exact half-size image.
  var padded_width := ((target_width + block - 1) / block) * block
  var padded_height := ((target_height + block - 1) / block) * block
  if padded_width != target_width or padded_height != target_height:
   var padded := Image.create(padded_width, padded_height, false, image.get_format())
   padded.blit_rect(image, Rect2i(0, 0, target_width, target_height), Vector2i.ZERO)
   for x in range(target_width, padded_width):
    padded.blit_rect(image, Rect2i(target_width - 1, 0, 1, target_height), Vector2i(x, 0))
   for y in range(target_height, padded_height):
    padded.blit_rect(padded, Rect2i(0, target_height - 1, padded_width, 1), Vector2i(0, y))
   image = padded
  var astc_mode := Image.ASTC_FORMAT_8x8 if format == Image.FORMAT_ASTC_8x8 else Image.ASTC_FORMAT_4x4
  if image.compress(Image.COMPRESS_ASTC, Image.COMPRESS_SOURCE_GENERIC, astc_mode) != OK or image.get_format() != format:
   return false
  payload = image.get_data()
 else:
  # WebP encoder accepts RGB/RGBA; the loader restores the recorded format.
  image.convert(Image.FORMAT_RGBA8 if format in [1, 5] else Image.FORMAT_RGB8)
  var webp := image.save_webp_to_buffer(false)
  if webp.is_empty():
   return false
  payload.resize(4)
  payload.encode_u32(0, webp.size())
  payload.append_array(webp)
 source.resize(52)
 source.encode_u16(40, target_width)
 source.encode_u16(42, target_height)
 source.encode_u32(44, image.get_mipmap_count())
 source.append_array(payload)
 var out := FileAccess.open(job["output"], FileAccess.WRITE)
 if out == null:
  return false
 out.store_buffer(source)
 out.close()
 return true
