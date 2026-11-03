# INPUT: isolated audited CTEX files and expected logical sizes from private manifest
# OUTPUT: native Godot logical dimensions and atlas endpoint checks
# POS: CPU/headless resource loader only; no game, Spine runtime or GPU claim
extends SceneTree
func _initialize() -> void:
 var args := OS.get_cmdline_user_args()
 if args.size()!=1: quit(1);return
 var entries = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
 if not entries is Array or entries.is_empty(): quit(2);return
 for e in entries:
  var tex := ResourceLoader.load(e.path,"",ResourceLoader.CACHE_MODE_IGNORE) as Texture2D
  if tex == null or tex.get_width()!=int(e.logical[0]) or tex.get_height()!=int(e.logical[1]): quit(3);return
  var atlas := AtlasTexture.new();atlas.atlas=tex
  var w := minf(20,tex.get_width());var h := minf(10,tex.get_height())
  atlas.region=Rect2(tex.get_width()-w,tex.get_height()-h,w,h)
  if atlas.region.end/tex.get_size()!=Vector2.ONE or atlas.get_size()!=Vector2(w,h): quit(4);return
 print("QUARTER_NATIVE_RELOAD_OK ",entries.size())
 quit(0)
