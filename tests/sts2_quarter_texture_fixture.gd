# INPUT: synthetic quarter-size ASTC GST2 from the CPU-only worker
# OUTPUT: logical size, atlas endpoint, and decoded alpha sanity assertions
# POS: isolated fake resources; no game resources or device
extends SceneTree
func _initialize() -> void:
 var args := OS.get_cmdline_user_args()
 if args.size() == 2 and args[0] == "generate-bc":
  var img := Image.create(264,152,false,Image.FORMAT_RGBA8)
  img.fill(Color(0.25,0.5,0.75,0.5))
  if img.compress(Image.COMPRESS_S3TC,Image.COMPRESS_SOURCE_GENERIC)!=OK or img.get_format() not in [17,19,22]: quit(5);return
  var data := PackedByteArray();data.resize(52)
  data[0]=71;data[1]=83;data[2]=84;data[3]=50
  data.encode_u32(4,1);data.encode_u32(8,260);data.encode_u32(12,150)
  data.encode_u32(16,0x0c000000);data.encode_u32(20,0xffffffff)
  data.encode_u16(40,264);data.encode_u16(42,152);data.encode_u32(48,img.get_format())
  data.append_array(img.get_data())
  var f := FileAccess.open(args[1],FileAccess.WRITE);f.store_buffer(data);f.close()
  quit(0);return
 if args.size() == 2 and args[0] == "generate-edge":
  var image := Image.create(256,256,false,Image.FORMAT_RGBA8)
  image.fill(Color(0,0,0,0))
  image.fill_rect(Rect2i(64,64,128,128),Color(0.25,0.5,0.75,1))
  var payload := image.save_webp_to_buffer(true)
  var data := PackedByteArray(); data.resize(56)
  data[0]=71;data[1]=83;data[2]=84;data[3]=50
  data.encode_u32(4,1);data.encode_u32(8,256);data.encode_u32(12,256)
  data.encode_u32(16,0x0c000000);data.encode_u32(20,0xffffffff);data.encode_u32(36,2)
  data.encode_u16(40,256);data.encode_u16(42,256);data.encode_u32(48,Image.FORMAT_RGBA8)
  data.encode_u32(52,payload.size());data.append_array(payload)
  var f := FileAccess.open(args[1],FileAccess.WRITE);f.store_buffer(data);f.close()
  quit(0);return
 if args.size() == 1 and args[0] == "check-edge":
  var raw := FileAccess.get_file_as_bytes("res://edge-out.ctex")
  var edge := Image.create_from_data(64,64,false,Image.FORMAT_ASTC_8x8,raw.slice(52))
  if edge.decompress()!=OK or edge.get_pixel(1,1).a>0.08 or edge.get_pixel(32,32).a<0.92: quit(4);return
  print("QUARTER_EDGE_OK");quit(0);return
 var bytes := FileAccess.get_file_as_bytes("res://quarter.ctex")
 var w := bytes.decode_u16(40)
 var h := bytes.decode_u16(42)
 var img := Image.create_from_data(((w+7)/8)*8,((h+7)/8)*8,false,Image.FORMAT_ASTC_8x8,bytes.slice(52))
 if img.decompress()!=OK or absf(img.get_pixel(30,20).a-0.5)>0.08: quit(1); return
 var tex := load("res://quarter.ctex") as Texture2D
 if tex == null or tex.get_size()!=Vector2(260,150): quit(2); return
 var atlas := AtlasTexture.new()
 atlas.atlas=tex; atlas.region=Rect2(240,140,20,10)
 if atlas.get_size()!=Vector2(20,10) or atlas.region.end / tex.get_size()!=Vector2.ONE: quit(3); return
 print("QUARTER_FIXTURE_OK")
 quit(0)
