# INPUT:  Godot 4.5.1 headless Image 与合成的 GST2 文件
# OUTPUT: 合成 ASTC/WebP 样本或纹理逻辑尺寸及 AtlasTexture 验证
# POS:    检验低清覆盖包在原生纹理加载器中的契约
extends SceneTree

func _initialize() -> void:
 var args := OS.get_cmdline_user_args()
 if args[0] == "generate":
  for spec in [["astc.ctex", 0, false], ["mips.ctex", 0, true], ["webp.ctex", 2, false], ["webp_mips.ctex", 2, true]]:
   var image := Image.create(264, 152, false, Image.FORMAT_RGBA8)
   image.fill(Color(0.25, 0.5, 0.75, 0.5))
   if spec[2]:
    image.generate_mipmaps()
   var data := PackedByteArray()
   data.resize(52)
   data[0] = 71
   data[1] = 83
   data[2] = 84
   data[3] = 50
   data.encode_u32(4, 1)
   data.encode_u32(8, 260)
   data.encode_u32(12, 150)
   data.encode_u32(16, 0x0c800000 if spec[2] else 0x0c000000)
   data.encode_u32(20, 0xffffffff)
   data.encode_u32(36, spec[1])
   data.encode_u16(40, 264)
   data.encode_u16(42, 152)
   if spec[1] == 0:
    if image.compress(Image.COMPRESS_ASTC, Image.COMPRESS_SOURCE_GENERIC, Image.ASTC_FORMAT_8x8) != OK:
     quit(2)
     return
    data.encode_u32(44, image.get_mipmap_count())
    data.encode_u32(48, image.get_format())
    data.append_array(image.get_data())
   else:
    data.encode_u32(44, image.get_mipmap_count())
    data.encode_u32(48, Image.FORMAT_RGBA8)
    var pixels := image.get_data()
    for level in range(image.get_mipmap_count() + 1):
     var width := maxi(1, 264 >> level)
     var height := maxi(1, 152 >> level)
     var offset := image.get_mipmap_offset(level)
     var mip := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, pixels.slice(offset, offset + width * height * 4))
     var bytes := mip.save_webp_to_buffer(false)
     var length := PackedByteArray()
     length.resize(4)
     length.encode_u32(0, bytes.size())
     data.append_array(length)
     data.append_array(bytes)
   var file := FileAccess.open(args[1].path_join(spec[0]), FileAccess.WRITE)
   file.store_buffer(data)
  quit(0)
 else:
  if not ProjectSettings.load_resource_pack(args[1]):
   push_error("failed to mount overlay PCK")
   quit(7)
   return
  for name in ["astc.ctex", "mips.ctex", "webp.ctex", "webp_mips.ctex"]:
   var resource: String = "res://.godot/imported/" + name
   var bytes := FileAccess.get_file_as_bytes(resource)
   var image: Image
   if bytes.decode_u32(36) == 0:
    var block_size := ((bytes.decode_u16(40) + 7) / 8) * ((bytes.decode_u16(42) + 7) / 8) * 16
    image = Image.create_from_data(bytes.decode_u16(40), bytes.decode_u16(42), false, bytes.decode_u32(48), bytes.slice(52, 52 + block_size))
    if image.decompress() != OK:
     quit(5)
     return
   else:
    image = Image.new()
    if image.load_webp_from_buffer(bytes.slice(56, 56 + bytes.decode_u32(52))) != OK:
     quit(5)
     return
   if image.get_width() != 132 or image.get_height() != 76 or absf(image.get_pixel(40, 30).a - 0.5) > 0.04:
    push_error("CPU dimensions or alpha mismatch: " + name)
    quit(6)
    return
   var texture: Texture2D = load(resource)
   if texture == null or texture.get_width() != 260 or texture.get_height() != 150:
    push_error("logical size mismatch: " + name)
    quit(3)
    return
   var atlas := AtlasTexture.new()
   atlas.atlas = texture
   atlas.region = Rect2(240, 140, 20, 10)
   if atlas.get_width() != 20 or atlas.get_height() != 10 or atlas.region.end.x / texture.get_width() != 1.0 or atlas.region.end.y / texture.get_height() != 1.0:
    push_error("atlas size mismatch")
    quit(4)
    return
  print("logical and atlas sizes OK")
  quit(0)
