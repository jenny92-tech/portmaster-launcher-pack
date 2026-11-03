# INPUT: isolated diagnostic PCK built entirely from project-owned resources
# OUTPUT: validates non-overriding mount and scene instantiation only
# POS: host-only fixture, no player assets
extends SceneTree
func _initialize() -> void:
 var args := OS.get_cmdline_user_args()
 if args.size() != 1 or not ProjectSettings.load_resource_pack(args[0], false):
  quit(1)
  return
 var scene = load("res://port_diagnostics/texture_diagnostic.tscn")
 if not scene is PackedScene:
  quit(1)
  return
 var node = scene.instantiate()
 if not node is Node:
  quit(1)
  return
 node.free()
 var ui_scene = load("res://port_diagnostics/ui_diagnostic.tscn")
 if not ui_scene is PackedScene:
  quit(1)
  return
 var ui = ui_scene.instantiate()
 if ui == null or ui._started:
  quit(1)
  return
 ui.free()
 print("DIAGNOSTIC_MOUNT_OK")
 quit(0)
