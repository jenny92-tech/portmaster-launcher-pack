# INPUT: isolated test paths and the optional texture/UI diagnostic runner
# OUTPUT: opt-in and user-directory identity checks; symlinks fail closed
# POS: synthetic filesystem only; never touches a user profile
extends SceneTree
func _initialize() -> void:
 call_deferred("_run")
func _run() -> void:
 var args := OS.get_cmdline_user_args()
 if args.size() != 2:
  quit(1)
  return
 var script = load("res://port_diagnostics/texture_diagnostic_runner.gd")
 var runner = script.new()
 var valid: String = args[0]
 var linked: String = args[1]
 var data := valid + "/data"
 var user := data + "/SlayTheSpire2"
 if not runner._isolated_paths_match(valid,data+"/",user+"/",user) or not runner._isolated_dirs_are_real(valid):
  printerr("Valid isolated root rejected: ", valid, " path=", runner._isolated_paths_match(valid,data+"/",user+"/",user), " dirs=", runner._isolated_dirs_are_real(valid))
  quit(1)
  return
 if runner._isolated_dirs_are_real(linked):
  printerr("Symlink root accepted")
  quit(1)
  return
 for bad in ["/tmp/sts2-memory-diag-", "/tmp/sts2-memory-diag-a-b", valid+"/", valid+"/../other", "/home/user"]:
  if runner._isolated_paths_match(bad,data,user,user):
   printerr("Invalid root accepted")
   quit(1)
   return
 if runner._isolated_paths_match(valid,data,"/home/user/real",user) or runner._isolated_paths_match(valid,data,user,"/home/user/real"):
  printerr("Mismatched actual user dir accepted")
  quit(1)
  return
 OS.set_environment("SLL_UI_DIAG","0")
 OS.set_environment("SLL_DIAG_XDG_ROOT",valid)
 OS.set_environment("XDG_DATA_HOME",data)
 root.add_child(runner)
 if root.get_node_or_null("PortUiDiagnostic") != null:
  printerr("UI diagnostic enabled without opt-in")
  quit(1)
  return
 OS.set_environment("SLL_UI_DIAG","1")
 runner._start_ui_if_allowed()
 if root.get_node_or_null("PortUiDiagnostic") != null:
  printerr("Fake environment marker enabled real user directory")
  quit(1)
  return
 runner.queue_free()
 print("UI_DIAG_GATE_FIXTURE_OK")
 quit(0)
