# INPUT: original single-level Windows CTEX and target physical dimensions
# OUTPUT: RGBA bytes from one original decode and one Lanczos resize
# POS: isolated offline Godot CPU codec; no scene, script or device loading
extends SceneTree
func _initialize() -> void:
 var args := OS.get_cmdline_user_args()
 if args.size()!=1:quit(1);return
 var jobs = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
 if not jobs is Array:quit(2);return
 for i in jobs.size():
  var job: Dictionary=jobs[i]
  var s := FileAccess.get_file_as_bytes(job.input)
  if s.size()<56 or s.decode_u32(44)!=0:quit(3);return
  var w:=s.decode_u16(40);var h:=s.decode_u16(42);var dtype:=s.decode_u32(36);var fmt:=s.decode_u32(48)
  var img: Image
  if dtype==2 and fmt in [4,5] and s.decode_u32(52)==s.size()-56:
   img=Image.new()
   if img.load_webp_from_buffer(s.slice(56))!=OK:quit(4);return
  elif dtype==0 and fmt in [17,19,22]:
   img=Image.create_from_data(w,h,false,fmt,s.slice(52))
   if img==null or img.is_empty() or img.decompress()!=OK:quit(5);return
  else:quit(6);return
  if img.get_width()!=w or img.get_height()!=h:quit(7);return
  img.convert(Image.FORMAT_RGBA8)
  img.resize(int(job.width),int(job.height),Image.INTERPOLATE_LANCZOS)
  var f:=FileAccess.open(job.output,FileAccess.WRITE)
  if f==null:quit(8);return
  f.store_buffer(img.get_data());f.close();print("REFINE_DECODED\t",i)
 quit(0)
