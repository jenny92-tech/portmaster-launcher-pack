# INPUT: synthetic ASTC GST2 produced by the offline restoration worker
# OUTPUT: logical size, AtlasTexture region and alpha validation
# POS: fake image only; headless load is not a GPU performance test
extends SceneTree
func _initialize() -> void:
 var args := OS.get_cmdline_user_args()
 if args.size() == 2 and args[0] == "generate-random":
  var rng := RandomNumberGenerator.new()
  rng.seed = 1234
  var image := Image.create(64,64,false,Image.FORMAT_RGBA8)
  for y in 64:
   for x in 64:
    image.set_pixel(x,y,Color(rng.randf(),rng.randf(),rng.randf(),rng.randf()))
  var payload := image.save_webp_to_buffer(true)
  var source := PackedByteArray()
  source.resize(56)
  source[0] = 71
  source[1] = 83
  source[2] = 84
  source[3] = 50
  source.encode_u32(4,1)
  source.encode_u32(8,64)
  source.encode_u32(12,64)
  source.encode_u32(16,0x0c000000)
  source.encode_u32(20,0xffffffff)
  source.encode_u32(36,2)
  source.encode_u16(40,64)
  source.encode_u16(42,64)
  source.encode_u32(48,Image.FORMAT_RGBA8)
  source.encode_u32(52,payload.size())
  source.append_array(payload)
  var f := FileAccess.open(args[1],FileAccess.WRITE)
  f.store_buffer(source)
  f.close()
  print("ADVERSARIAL_WEBP_FIXTURE_OK")
  quit(0)
  return
 var data := FileAccess.get_file_as_bytes("res://restored.ctex")
 var w := data.decode_u16(40)
 var h := data.decode_u16(42)
 var image := Image.create_from_data(((w+3)/4)*4,((h+3)/4)*4,false,Image.FORMAT_ASTC_4x4,data.slice(52))
 if image.decompress() != OK or absf(image.get_pixel(30,30).a - 0.5) > 0.04:
  quit(1)
  return
 var texture: Texture2D = load("res://restored.ctex")
 if texture == null or texture.get_width() != 260 or texture.get_height() != 150:
  quit(1)
  return
 var atlas := AtlasTexture.new()
 atlas.atlas = texture
 atlas.region = Rect2(240, 140, 20, 10)
 if atlas.region.end.x / texture.get_width() != 1.0 or atlas.region.end.y / texture.get_height() != 1.0:
  quit(1)
  return
 print("RESTORED_TEXTURE_FIXTURE_OK")
 quit(0)
