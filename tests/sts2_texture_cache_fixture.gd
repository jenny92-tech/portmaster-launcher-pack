# INPUT: synthetic resource-cache entries and Godot ResourceLoader APIs
# OUTPUT: verifies absent queries do not load and borrowed refs do not pin
# POS: no game assets, pixels, device, or cache mutation by diagnostics
extends SceneTree
func _initialize() -> void:
 var missing := "res://fixture_that_does_not_exist.png"
 if ResourceLoader.has_cached(missing) or ResourceLoader.get_cached_ref(missing) != null or ResourceLoader.has_cached(missing):
  printerr("Absent path unexpectedly loaded")
  quit(1)
  return
 var image := Image.create(8, 8, false, Image.FORMAT_RGBA8)
 var texture := ImageTexture.create_from_image(image)
 var path := "res://cached_texture.png"
 texture.take_over_path(path)
 if not ResourceLoader.has_cached(path):
  printerr("Fixture texture was not cached")
  quit(1)
  return
 var borrowed := ResourceLoader.get_cached_ref(path)
 if borrowed != texture:
  printerr("Cached reference mismatch")
  quit(1)
  return
 var weak: WeakRef = weakref(texture)
 borrowed = null
 texture = null
 image = null
 if weak.get_ref() != null or ResourceLoader.has_cached(path):
  printerr("Read-only cache lookup pinned the texture")
  quit(1)
  return
 print("TEXTURE_CACHE_FIXTURE_OK")
 quit(0)
