# INPUT: explicitly requested live scene tree and RenderingServer metadata
# OUTPUT: bounded, deduplicated texture paths/formats/sizes and renderer totals
# POS: optional diagnostic; never loads resources, reads pixels or changes game state
extends RefCounted

const NODE_LIMIT = 20000
const TEXTURE_LIMIT = 4096
const RECORD_LIMIT = 80
const FRAME_LIMIT = 128
const CACHE_CANDIDATE_LIMIT = 30000
const CACHE_MANIFEST = "res://port_diagnostics/texture_candidates.json"
const FontDiagnostic = preload("res://port_diagnostics/font_cache_diagnostic.gd")
var _nodes = 0
var _truncated = false
var _seen: Dictionary = {}
var _records: Array[Dictionary] = []
var _viewports: Array[Dictionary] = []
var _canvas_groups = 0
var _rd: RenderingDevice

func scan(tree: SceneTree) -> Dictionary:
 _nodes = 0
 _truncated = false
 _seen.clear()
 _records.clear()
 _viewports.clear()
 _canvas_groups = 0
 _rd = RenderingServer.get_rendering_device()
 var stack: Array[Node] = [tree.root]
 while not stack.is_empty() and _nodes < NODE_LIMIT and _seen.size() < TEXTURE_LIMIT:
  var node: Node = stack.pop_back()
  if not is_instance_valid(node) or node.is_queued_for_deletion():
   continue
  _nodes += 1
  _inspect_node(node)
  for child in node.get_children():
   if child is Node:
    if _nodes + stack.size() >= NODE_LIMIT:
     _truncated = true
     break
    stack.append(child)
  if _nodes % 128 == 0:
   await tree.process_frame
 if not stack.is_empty() or _seen.size() >= TEXTURE_LIMIT:
  _truncated = true
 var cache_report: Dictionary = await _scan_cached(tree)
 _records.sort_custom(func(a, b): return a.area > b.area)
 var font_report: Dictionary = {"status": "dependency_failed", "cache_status": cache_report.get("status", "missing_status")}
 if cache_report.get("status") == "ok":
  font_report = FontDiagnostic.new().scan(cache_report.font_paths)
 cache_report.erase("font_paths")
 var report := {"nodes": _nodes, "textures": _seen.size(), "truncated": _truncated,
  "record_limit": RECORD_LIMIT, "records": _records.slice(0, RECORD_LIMIT),
  "viewports": _viewports, "canvas_groups": _canvas_groups, "cache": cache_report, "fonts":font_report,
  "format_summary": summarize_formats(_records),
  "renderer_texture_bytes": Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED),
  "limitations": "Scene-tree and listed existing cache paths only; excludes other caches, fonts and unnamed render targets. Format totals count only base levels of observed RIDs; omit mipmaps, layers, hidden targets and other caches. They are not allocation or RSS."}
 _rd = null
 _seen.clear()
 _records.clear()
 _viewports = []
 return report

func summarize_formats(records: Array) -> Dictionary:
 # RenderingDevice.DataFormat enum values in Godot 4.5, not Image.Format.
 var names := {36: "RGBA8_UNORM", 42: "RGBA8_SRGB", 96: "RGBA16F", 170: "ASTC_8x8_UNORM", 171: "ASTC_8x8_SRGB"}
 var summary: Dictionary = {}
 for record in records:
  var format: int = record.rd_format
  var key := str(format)
  if not summary.has(key):
   summary[key] = {"format": names.get(format, "unknown"), "textures": 0,
    "physical_pixels": 0, "nominal_base_bytes": 0 if names.has(format) else null,
    "missing_dimensions": 0}
  var item: Dictionary = summary[key]
  item.textures += 1
  var w: int = record.physical[0]
  var h: int = record.physical[1]
  if w <= 0 or h <= 0:
   item.missing_dimensions += 1
   continue
  item.physical_pixels += w * h
  if format in [170, 171]:
   item.nominal_base_bytes += ((w + 7) / 8) * ((h + 7) / 8) * 16
  elif format in [36, 42]:
   item.nominal_base_bytes += w * h * 4
  elif format == 96:
   item.nominal_base_bytes += w * h * 8
 return summary

func _inspect_node(node: Node) -> void:
 if node is Viewport and _viewports.size() < 128:
  var viewport: Viewport = node
  var viewport_size := viewport.get_visible_rect().size
  var info := {"class": viewport.get_class(), "scene": _safe_path(viewport.scene_file_path),
   "size": [viewport_size.x, viewport_size.y], "msaa_2d": viewport.get_msaa_2d(),
   "msaa_3d": viewport.get_msaa_3d(), "hdr_2d": viewport.is_using_hdr_2d(),
   "disable_3d": viewport.is_3d_disabled(), "visible_rect_size":[viewport_size.x,viewport_size.y],
   "actual_size":null, "content_scale_size":null}
  var obj: Object = viewport
  if obj.get_script() == null and obj.get_class() == "SubViewport":
   var sub: SubViewport = viewport
   var actual := sub.get_size()
   info.actual_size = [actual.x,actual.y]
  elif obj.get_script() == null and obj.get_class() == "Window":
   var window: Window = viewport
   var actual := window.get_size()
   var scale := window.get_content_scale_size()
   info.actual_size = [actual.x,actual.y]
   info.content_scale_size = [scale.x,scale.y]
  _viewports.append(info)
  _texture(viewport.get_texture())
 elif node is Viewport:
  _truncated = true
 if node is CanvasGroup:
  _canvas_groups += 1
 if node is Sprite2D or node is TextureRect or node is NinePatchRect or node is Polygon2D:
  _texture(node.texture)
 if node is TextureButton:
  _texture(node.texture_normal)
  _texture(node.texture_pressed)
  _texture(node.texture_hover)
  _texture(node.texture_disabled)
  _texture(node.texture_focused)
 if node is TextureProgressBar:
  _texture(node.texture_under)
  _texture(node.texture_progress)
  _texture(node.texture_over)
 if node is AnimatedSprite2D and node.sprite_frames != null:
  var frames: SpriteFrames = node.sprite_frames
  var remaining := FRAME_LIMIT
  for animation in frames.get_animation_names():
   for frame in mini(frames.get_frame_count(animation), remaining):
    _texture(frames.get_frame_texture(animation, frame))
    remaining -= 1
   if remaining <= 0:
    _truncated = true
    break
 if node is CanvasItem and node.material is ShaderMaterial:
  var material: ShaderMaterial = node.material
  if material.shader != null:
   for uniform in material.shader.get_shader_uniform_list():
    _texture(material.get_shader_parameter(uniform.name))
 if node.is_class("SpineSprite") and node.has_method("get_skeleton_data_res"):
  var data = node.call("get_skeleton_data_res")
  if is_instance_valid(data) and data.is_class("SpineSkeletonDataResource") and data.has_method("get_atlas_res"):
   var atlas = data.call("get_atlas_res")
   if is_instance_valid(atlas) and atlas.is_class("SpineAtlasResource"):
    for method in ["get_textures", "get_normal_maps", "get_specular_maps"]:
     if atlas.has_method(method):
      var pages = atlas.call(method)
      if pages is Array:
       for page in pages:
        _texture(page)

func _scan_cached(tree: SceneTree) -> Dictionary:
 var manifest = JSON.parse_string(FileAccess.get_file_as_string(CACHE_MANIFEST))
 if not manifest is Dictionary or not manifest.get("paths") is Array or manifest.paths.size() > CACHE_CANDIDATE_LIMIT or not manifest.get("font_paths") is Array:
  return {"status": "invalid_manifest"}
 var paths: Array = manifest.paths
 var result := {"status": "ok", "source_sha256": manifest.get("source_sha256", ""),
  "texture_overlay_sha256": manifest.get("texture_overlay_sha256", ""), "candidates": paths.size(),
  "examined": 0, "cached_hits": 0, "cached_texture_hits": 0, "truncated": false,
  "font_paths":manifest.get("font_paths", [])}
 for value in paths:
  if not value is String or _safe_path(value) != value:
   result.status = "invalid_path"
   return result
  result.examined += 1
  if ResourceLoader.has_cached(value):
   result.cached_hits += 1
   var borrowed: Resource = ResourceLoader.get_cached_ref(value)
   if borrowed is Texture2D and borrowed.get_script() == null:
    result.cached_texture_hits += 1
    _texture(borrowed, "cache")
   borrowed = null
  if _seen.size() >= TEXTURE_LIMIT:
   result.truncated = true
   _truncated = true
   break
  if result.examined % 128 == 0:
   await tree.process_frame
 return result

func _texture(value: Variant, origin: String = "scene") -> void:
 if not value is Texture2D or not is_instance_valid(value):
  return
 var texture: Texture2D = value
 if texture.get_script() != null:
  return
 if texture is AtlasTexture and texture.atlas != null:
  texture = texture.atlas
  if texture.get_script() != null:
   return
 var rid := texture.get_rid()
 if not rid.is_valid():
  return
 if _seen.has(rid):
  var prior: Dictionary = _seen[rid]
  if not origin in prior.origins:
   prior.origins.append(origin)
  return
 if _seen.size() >= TEXTURE_LIMIT:
  _truncated = true
  return
 var physical := Vector2i.ZERO
 var format := -1
 if _rd != null:
  var rd_rid := RenderingServer.texture_get_rd_texture(rid)
  if rd_rid.is_valid():
   var info := _rd.texture_get_format(rd_rid)
   if info != null:
    physical = Vector2i(info.width, info.height)
    format = info.format
 var path := _safe_path(texture.resource_path)
 var record := {"path": path, "logical": [texture.get_width(), texture.get_height()],
  "physical": [physical.x, physical.y], "rd_format": format,
  "area": physical.x * physical.y, "origins": [origin]}
 _seen[rid] = record
 _records.append(record)

func _safe_path(path: String) -> String:
 if not path.begins_with("res://") or path.length() <= 6 or path.length() > 4096 or path.contains("\\"):
  return "<anonymous>"
 for part in path.trim_prefix("res://").split("/", true):
  if part in ["", ".", ".."]:
   return "<anonymous>"
 for i in path.length():
  var code := path.unicode_at(i)
  if code < 32 or (code >= 127 and code <= 159):
   return "<anonymous>"
 return path
