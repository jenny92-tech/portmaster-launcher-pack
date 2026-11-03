# INPUT: isolated Linux Godot process and explicit diagnostic opt-in flags
# OUTPUT: verifies actual user:// mapping and isolated observer installation
# POS: fake scene only; simulates the existing bridge's texture flag gate
extends SceneTree
func _initialize() -> void:
 call_deferred("_run")
func _run() -> void:
 var args := OS.get_cmdline_user_args()
 if args.size() != 2:
  quit(1)
  return
 var test_root: String = args[0]
 var expected := args[1] == "enabled"
 var expected_user := test_root + "/data/SlayTheSpire2"
 if OS.get_user_data_dir().simplify_path() != expected_user or ProjectSettings.globalize_path("user://").simplify_path() != expected_user:
  printerr("Linux user directory did not match isolated path")
  quit(1)
  return
 var runner: Node = null
 if OS.get_environment("SLL_TEXTURE_DIAG") == "1":
  runner = load("res://port_diagnostics/texture_diagnostic_runner.gd").new()
  root.add_child(runner)
 var observer := root.get_node_or_null("PortUiDiagnostic")
 if (observer != null) != expected or (observer != null and not observer._started):
  printerr("Unexpected isolated diagnostic enabled state")
  quit(1)
  return
 if observer != null: observer.queue_free()
 if runner != null: runner.queue_free()
 print("LINUX_UI_DIAGNOSTIC_GATE_OK ",args[1])
 quit(0)
