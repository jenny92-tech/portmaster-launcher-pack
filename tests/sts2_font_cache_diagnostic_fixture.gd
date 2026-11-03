# INPUT: synthetic cached native and scripted fonts
# OUTPUT: bounded native-only metadata without cache creation or pinning
# POS: headless fixture; no game assets or user data
extends SceneTree
class ScriptedFont extends FontFile:
 var touched := false
 @warning_ignore("native_method_override")
 func get_script():
  touched = true
  return null
 @warning_ignore("native_method_override")
 func get_cache_count() -> int:
  touched = true
  return 999

func _initialize() -> void:
 var file := FontFile.new()
 file.take_over_path("res://test/font.otf")
 var variation := FontVariation.new()
 variation.base_font = file
 variation.take_over_path("res://test/shared.tres")
 var scripted := ScriptedFont.new()
 scripted.take_over_path("res://test/scripted.otf")
 var before := file.get_cache_count()
 var diag = load("res://port_diagnostics/font_cache_diagnostic.gd").new()
 var report: Dictionary = diag.scan(["res://test/shared.tres", "res://test/font.otf", "res://test/scripted.otf", "res://test/absent.otf"])
 if report.status != "ok" or report.examined != 4 or report.cached_hits != 3 or report.records.size() != 1 or report.skipped != 1:
  printerr("Unexpected font metadata: ", report)
  quit(1); return
 var record: Dictionary = report.records[0]
 if record.path != "res://test/font.otf" or record.cache_slots != before or file.get_cache_count() != before or scripted.touched or record.pages != null or record.texture_bytes != null:
  printerr("Font diagnostic changed cache or invoked script: ", report)
  quit(1); return
 if diag.scan(["user://private"]).status != "invalid_path" or ResourceLoader.has_cached("res://test/absent.otf"):
  printerr("Unexpected font path or load")
  quit(1); return
 var weak: WeakRef = weakref(file)
 variation = null
 file = null
 if weak.get_ref() != null or ResourceLoader.has_cached("res://test/font.otf"):
  printerr("Font diagnostic pinned a resource")
  quit(1); return
 print("FONT_CACHE_DIAGNOSTIC_FIXTURE_OK")
 quit(0)
