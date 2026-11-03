# INPUT: synthetic scene tree and the optional texture diagnostic
# OUTPUT: deduplicated reachable texture metadata without pixel reads
# POS: host-only fixture, no player assets or device
extends SceneTree
class ScriptedViewport extends SubViewport:
 var touched := false
 @warning_ignore("native_method_override")
 func get_size() -> Vector2i:
  touched = true
  return Vector2i(999, 999)

func _initialize() -> void:
 call_deferred("_run")

func _run() -> void:
 DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://port_diagnostics"))
 var manifest := FileAccess.open("res://port_diagnostics/texture_candidates.json", FileAccess.WRITE)
 manifest.store_string(JSON.stringify({"source_sha256": "fixture", "texture_overlay_sha256": "fixture", "paths": ["res://fixture_texture.png", "res://cached_only.png", "res://not_there.png"], "font_paths": []}))
 manifest.close()
 var image := Image.create(16, 8, false, Image.FORMAT_RGBA8)
 image.fill(Color(0.5, 0.2, 0.1, 0.7))
 var texture := ImageTexture.create_from_image(image)
 texture.resource_path = "res://fixture_texture.png"
 var cache_only := ImageTexture.create_from_image(image)
 cache_only.take_over_path("res://cached_only.png")
 var cache_weak: WeakRef = weakref(cache_only)
 var parent := Node2D.new()
 root.add_child(parent)
 var sprite := Sprite2D.new()
 sprite.texture = texture
 parent.add_child(sprite)
 var rect := TextureRect.new()
 rect.texture = texture
 parent.add_child(rect)
 var viewport := SubViewport.new()
 viewport.size = Vector2i(100, 80)
 viewport.msaa_2d = Viewport.MSAA_2X
 viewport.scene_file_path = "user://private"
 parent.add_child(viewport)
 var newline_viewport := SubViewport.new()
 newline_viewport.scene_file_path = "res://bad\nname.tscn"
 parent.add_child(newline_viewport)
 var scripted_viewport := ScriptedViewport.new()
 parent.add_child(scripted_viewport)
 var diag = load("res://texture_diagnostic.gd").new()
 if diag._safe_path("res://" + "a".repeat(4097)) != "<anonymous>":
  printerr("Oversized resource path was not redacted")
  quit(1)
  return
 var summary: Dictionary = diag.summarize_formats([
  {"rd_format":170, "physical":[17,9]}, {"rd_format":36, "physical":[16,8]},
  {"rd_format":96, "physical":[16,8]}, {"rd_format":999, "physical":[4,4]},
  {"rd_format":170, "physical":[0,0]}])
 if summary["170"].textures != 2 or summary["170"].nominal_base_bytes != 96 or summary["170"].missing_dimensions != 1 or summary["36"].nominal_base_bytes != 512 or summary["96"].nominal_base_bytes != 1024 or summary["999"].nominal_base_bytes != null:
  printerr("Unexpected format summary ", summary)
  quit(1)
  return
 var report: Dictionary = await diag.scan(self)
 if report.format_summary["-1"].textures != report.textures:
  printerr("Format summary is not deduplicated")
  quit(1)
  return
 var matches = report.records.filter(func(record): return record.path == "res://fixture_texture.png")
 var viewport_matches = report.viewports.filter(func(item): return item.msaa_2d == Viewport.MSAA_2X and item.size == [100.0, 80.0] and item.actual_size == [100,80] and item.visible_rect_size == [100.0,80.0])
 var cache_matches = report.records.filter(func(record): return record.path == "res://cached_only.png")
 if scripted_viewport.touched:
  printerr("Diagnostic invoked scripted viewport getter")
  quit(1); return
 if matches.size() != 1 or cache_matches.size() != 1 or matches[0].origins.size() != 2 or cache_matches[0].origins != ["cache"] or viewport_matches.size() != 1 or viewport_matches[0].scene != "<anonymous>" or report.truncated or report.cache.cached_texture_hits != 2 or report.cache.examined != 3:
  printerr("Unexpected diagnostic result ", report)
  quit(1)
  return
 for item in report.viewports:
  if item.scene != "<anonymous>":
   printerr("Unexpected viewport path ", item)
   quit(1)
   return
 if diag._safe_path("res://normal/path.png") != "res://normal/path.png" or diag._safe_path("res://bad\nname.png") != "<anonymous>" or diag._safe_path("user://private.png") != "<anonymous>" or diag._safe_path("res://../escape.png") != "<anonymous>":
  printerr("Unexpected diagnostic result ", report)
  quit(1)
  return
 var font := FontFile.new()
 font.take_over_path("res://existing-font.fontdata")
 var font_caches := font.get_cache_count()
 for bad_manifest in [
  {"paths": ["res://uncached.png"]},
  {"paths": ["user://invalid.png"], "font_paths": ["res://existing-font.fontdata", "res://uncached-font.fontdata"]}]:
  manifest = FileAccess.open("res://port_diagnostics/texture_candidates.json", FileAccess.WRITE)
  manifest.store_string(JSON.stringify(bad_manifest))
  manifest.close()
  var bad_report: Dictionary = await diag.scan(self)
  var expected := "invalid_manifest" if not bad_manifest.has("font_paths") else "invalid_path"
  if bad_report.cache.status != expected or bad_report.fonts.status != "dependency_failed" or bad_report.fonts.cache_status != expected or bad_report.fonts.has("candidates"):
   printerr("Invalid cache manifest incorrectly reported font success ", bad_report)
   quit(1); return
  if font.get_cache_count() != font_caches or ResourceLoader.has_cached("res://uncached-font.fontdata") or ResourceLoader.has_cached("res://uncached.png"):
   printerr("Failed diagnostic scan changed font or resource caches")
   quit(1); return
 cache_only = null
 if cache_weak.get_ref() != null or ResourceLoader.has_cached("res://cached_only.png"):
  printerr("Diagnostic pinned a cached texture")
  quit(1)
  return
 parent.queue_free()
 print("TEXTURE_DIAGNOSTIC_FIXTURE_OK")
 quit(0)
