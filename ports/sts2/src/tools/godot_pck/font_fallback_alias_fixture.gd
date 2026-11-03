# INPUT:  original imported FontFile and its source-path .import mapping
# OUTPUT: cache object identity for two caller-specified paths
# POS:    reproduce Godot source/imported alias behavior in fresh processes
extends SceneTree
func _initialize() -> void:
 var args = OS.get_cmdline_user_args()
 if args.size() != 2:
  quit(1)
  return
 var first = ResourceLoader.load(args[0])
 var second = ResourceLoader.load(args[1])
 if first == null or second == null:
  printerr("FAILED to load both paths")
  quit(1)
  return
 print("ALIAS_RESULT first=", args[0], " second=", args[1], " same=", is_same(first, second), " first_path=", first.resource_path, " second_path=", second.resource_path)
 quit(0)
