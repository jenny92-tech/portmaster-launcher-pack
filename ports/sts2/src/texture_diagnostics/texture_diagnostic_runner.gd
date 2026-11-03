# INPUT: explicitly mounted diagnostic scene in a user-started process
# OUTPUT: bounded scene-tree texture metadata at intervals, then self-removal
# POS: optional, never changes the game's resources, timing or input
extends Node
const Diagnostic = preload("res://port_diagnostics/texture_diagnostic.gd")
const ResourceStats = preload("res://port_diagnostics/resource_stats.gd")
const INTERVAL_SECONDS = 20.0
const MAX_SAMPLES = 12
const STATS_INTERVAL_SECONDS = 30.0
const MAX_STATS_SAMPLES = 20
var _texture_done := false
var _stats_done := false

func _ready() -> void:
 var stats = ResourceStats.new()
 print("[RESOURCE-CONFIG] ", JSON.stringify(stats.startup_config()))
 _start_ui_if_allowed()
 _run.call_deferred()
 _run_stats.call_deferred()

# UI observation is confined to an explicitly opted-in isolated user directory.
func _start_ui_if_allowed() -> void:
 if OS.get_environment("SLL_UI_DIAG") != "1":
  return
 var test_root := OS.get_environment("SLL_DIAG_XDG_ROOT")
 if not _isolated_paths_match(test_root, OS.get_environment("XDG_DATA_HOME"),
   OS.get_user_data_dir(), ProjectSettings.globalize_path("user://")) or not _isolated_dirs_are_real(test_root):
  print("[UI-DIAG] disabled: isolated user directory identity mismatch")
  return
 var scene = load("res://port_diagnostics/ui_diagnostic.tscn")
 if not scene is PackedScene:
  print("[UI-DIAG] disabled: diagnostic scene unavailable")
  return
 var observer = scene.instantiate()
 if not observer is Node or not observer.has_method("start_isolated"):
  if is_instance_valid(observer): observer.free()
  return
 get_tree().root.add_child(observer)
 observer.call("start_isolated")

static func _isolated_paths_match(test_root: String, xdg_data: String, user_dir: String, global_user: String) -> bool:
 var pattern := RegEx.new()
 if pattern.compile("^/tmp/sts2-memory-diag-[A-Za-z0-9]+$") != OK or pattern.search(test_root) == null:
  return false
 var data := test_root + "/data"
 var user := data + "/SlayTheSpire2"
 return xdg_data.simplify_path() == data and user_dir.simplify_path() == user and global_user.simplify_path() == user

static func _isolated_dirs_are_real(test_root: String) -> bool:
 var filesystem := DirAccess.open("/")
 if filesystem == null:
  return false
 for path in [test_root, test_root + "/data", test_root + "/data/SlayTheSpire2"]:
  if not DirAccess.dir_exists_absolute(path) or filesystem.is_link(path):
   return false
 return true

func _run() -> void:
 for sample in MAX_SAMPLES:
  await get_tree().create_timer(INTERVAL_SECONDS, true, false, true).timeout
  if not is_inside_tree():
   return
  var started := Time.get_ticks_msec()
  var diagnostic = Diagnostic.new()
  var report: Dictionary = await diagnostic.scan(get_tree())
  if not is_inside_tree():
   return
  report["sample"] = sample + 1
  report["elapsed_ms"] = Time.get_ticks_msec() - started
  print("[TEXTURE-DIAG] ", JSON.stringify(report))
 _texture_done = true
 _finish_if_done()

func _run_stats() -> void:
 for sample in MAX_STATS_SAMPLES:
  await get_tree().create_timer(STATS_INTERVAL_SECONDS, true, false, true).timeout
  if not is_inside_tree():
   return
  var stats = ResourceStats.new()
  var report: Dictionary = stats.collect()
  report.sample = sample + 1
  print("[RESOURCE-STATS] ", JSON.stringify(report))
 _stats_done = true
 _finish_if_done()

func _finish_if_done() -> void:
 if _texture_done and _stats_done:
  queue_free()
