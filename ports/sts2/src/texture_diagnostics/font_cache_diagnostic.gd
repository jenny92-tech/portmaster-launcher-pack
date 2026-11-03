# INPUT: existing ResourceLoader cache paths from the source-bound manifest
# OUTPUT: bounded native FontFile configuration and cache slot counts
# POS: opt-in observation; never loads a resource, obtains a RID or reads pixels
extends RefCounted
const PATH_LIMIT := 512
const OBJECT_LIMIT := 256
const DEPTH_LIMIT := 8
const RECORD_LIMIT := 128
var _seen: Dictionary = {}
var _records: Array[Dictionary] = []
var _skipped := 0
var _truncated := false

func scan(paths: Variant) -> Dictionary:
 _seen.clear()
 _records.clear()
 _skipped = 0
 _truncated = false
 if not paths is Array or paths.size() > PATH_LIMIT:
  return {"status":"invalid_manifest"}
 var examined := 0
 var hits := 0
 for value in paths:
  if not value is String or _safe_path(value) != value:
   return {"status":"invalid_path"}
  examined += 1
  if ResourceLoader.has_cached(value):
   var borrowed: Resource = ResourceLoader.get_cached_ref(value)
   if borrowed is Font:
    hits += 1
    _walk(borrowed)
   borrowed = null
  if _seen.size() >= OBJECT_LIMIT:
   _truncated = true
   break
 var result := {"status":"ok", "candidates":paths.size(), "examined":examined,
  "cached_hits":hits, "objects":_seen.size(), "skipped":_skipped,
  "truncated":_truncated, "record_limit":RECORD_LIMIT, "records":_records.slice(0,RECORD_LIMIT),
  "limitations":"Only already-cached source/import/shared-font paths and reachable safe FontFile/FontVariation objects. Cache slots may contain invalid RIDs. Page count, texture size and bytes unavailable without potentially creating a cache; these are not RSS."}
 _seen.clear()
 _records.clear()
 return result

func _walk(first: Font) -> void:
 var pending: Array[Dictionary] = [{"font":first, "depth":0}]
 while not pending.is_empty():
  var item: Dictionary = pending.pop_back()
  var value: Variant = item.font
  if not value is Font or not is_instance_valid(value):
   continue
  var obj: Object = value
  if obj.get_script() != null or obj.get_class() not in ["FontFile", "FontVariation"]:
   _skipped += 1
   continue
  var id := obj.get_instance_id()
  if _seen.has(id):
   continue
  if _seen.size() >= OBJECT_LIMIT:
   _truncated = true
   break
  _seen[id] = true
  var font: Font = value
  if font is FontFile:
   var file: FontFile = font
   var resource: Resource = file
   _records.append({"path":_safe_path(resource.resource_path), "class":"FontFile",
    "cache_slots":file.get_cache_count(), "msdf":file.is_multichannel_signed_distance_field(),
    "msdf_pixel_range":file.get_msdf_pixel_range(), "msdf_size":file.get_msdf_size(),
    "fixed_size":file.get_fixed_size(), "system_fallback":file.is_allow_system_fallback(),
    "size_caches":null, "pages":null, "texture_bytes":null})
  if item.depth >= DEPTH_LIMIT:
   _truncated = true
   continue
  if font is FontVariation:
   var variation: FontVariation = font
   var base: Font = variation.get_base_font()
   if base != null: pending.append({"font":base, "depth":item.depth + 1})
  for fallback in font.get_fallbacks():
   if fallback is Font: pending.append({"font":fallback, "depth":item.depth + 1})
  if pending.size() > OBJECT_LIMIT:
   pending.resize(OBJECT_LIMIT)
   _truncated = true

func _safe_path(path: String) -> String:
 if not path.begins_with("res://") or path.length() <= 6 or path.length() > 4096 or path.contains("\\"):
  return "<anonymous>"
 for part in path.trim_prefix("res://").split("/", true):
  if part in ["", ".", ".."]: return "<anonymous>"
 for i in path.length():
  var code := path.unicode_at(i)
  if code < 32 or (code >= 127 and code <= 159): return "<anonymous>"
 return path
