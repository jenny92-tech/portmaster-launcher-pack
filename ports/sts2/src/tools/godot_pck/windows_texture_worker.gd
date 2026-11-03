# INPUT:  Godot 4.5.1 CPU Image codecs and validated Windows BC texture jobs
# OUTPUT: GST2 textures with preserved logical size, converted to ASTC or RGBA
# POS:    Offline data conversion; no game scene or script is loaded
extends SceneTree

func _initialize() -> void:
 var args := OS.get_cmdline_user_args()
 if args.size() != 1:
  quit(2)
  return
 var jobs: Variant = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
 if not jobs is Array:
  quit(2)
  return
 for index in range(jobs.size()):
  if not convert_texture(jobs[index]):
   push_error("Windows texture conversion failed: " + str(index))
   quit(1)
   return
  print("TEXTURE_DONE\t", index)
 quit(0)

func convert_texture(job: Dictionary) -> bool:
 var source := FileAccess.get_file_as_bytes(job["input"])
 if source.size() < 52 or source.decode_u32(36) != 0 or source.decode_u32(44) != 0:
  return false
 var width := source.decode_u16(40)
 var height := source.decode_u16(42)
 var original_format := source.decode_u32(48)
 if original_format not in [17, 19, 22]:
  return false
 var image := Image.create_from_data(width, height, false, original_format, source.slice(52))
 if image == null or image.is_empty() or image.decompress() != OK:
  return false
 image.convert(Image.FORMAT_RGBA8)
 var scale := 2 if job["halve"] else 1
 var target_width := maxi(1, width / scale)
 var target_height := maxi(1, height / scale)
 if scale == 2:
  image.resize(target_width, target_height, Image.INTERPOLATE_LANCZOS)
 if job["astc"]:
  var padded_width := ((target_width + 7) / 8) * 8
  var padded_height := ((target_height + 7) / 8) * 8
  if padded_width != target_width or padded_height != target_height:
   var padded := Image.create(padded_width, padded_height, false, Image.FORMAT_RGBA8)
   padded.blit_rect(image, Rect2i(0, 0, target_width, target_height), Vector2i.ZERO)
   for x in range(target_width, padded_width):
    padded.blit_rect(image, Rect2i(target_width - 1, 0, 1, target_height), Vector2i(x, 0))
   for y in range(target_height, padded_height):
    padded.blit_rect(padded, Rect2i(0, target_height - 1, padded_width, 1), Vector2i(0, y))
   image = padded
  if image.compress(Image.COMPRESS_ASTC, Image.COMPRESS_SOURCE_GENERIC, Image.ASTC_FORMAT_8x8) != OK or image.get_format() != Image.FORMAT_ASTC_8x8:
   return false
 var payload := image.get_data()
 source.resize(52)
 source.encode_u16(40, target_width)
 source.encode_u16(42, target_height)
 source.encode_u32(48, image.get_format())
 source.append_array(payload)
 var out := FileAccess.open(job["output"], FileAccess.WRITE)
 if out == null:
  return false
 out.store_buffer(source)
 out.close()
 return true
