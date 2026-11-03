# INPUT:  Original and patched native-only map scenes extracted from the pinned PCK
# OUTPUT: Headless checks of physical/logical sizes, line coordinates and viewport transforms
# POS:    Isolated geometry fixture; no game scripts, device, pixel readback or player data
extends SceneTree
var failed := false

func _initialize():
	call_deferred("run")

func check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		printerr(message)

func make_scene(path: String) -> Control:
	var packed = load(path) as PackedScene
	check(packed != null, "scene missing")
	if packed == null:
		return null
	var scene = packed.instantiate() as Control
	check(scene != null, "wrong root")
	if scene == null:
		return null
	root.add_child(scene)
	scene.set_anchors_preset(Control.PRESET_TOP_LEFT)
	scene.size = Vector2(1920, 3240)
	return scene

func run():
	var original = make_scene("res://original.tscn")
	var candidate = make_scene("res://candidate.tscn")
	if original == null or candidate == null:
		quit(1)
		return
	await process_frame
	await process_frame
	var before = original.get_node("DrawViewport") as SubViewport
	var after = candidate.get_node("DrawViewport") as SubViewport
	check(before.size == Vector2i(960, 1620), "original physical size")
	check(after.size == Vector2i(480, 810), "candidate physical size")
	check(after.size_2d_override == Vector2i(960, 1620) and after.size_2d_override_stretch, "logical override")
	check(before.get_visible_rect().size == after.get_visible_rect().size, "logical extent changed")
	var points = PackedVector2Array([Vector2(1, 1), Vector2(480, 810), Vector2(959, 1619)])
	for width in [4.0, 12.0]:
		var a = Line2D.new()
		var b = Line2D.new()
		a.points = points
		b.points = points
		a.width = width
		b.width = width
		before.add_child(a)
		after.add_child(b)
		await process_frame
		for point in points:
			var old_pixel = a.get_viewport_transform() * point
			var new_pixel = b.get_viewport_transform() * point
			check(new_pixel.is_equal_approx(old_pixel * 0.5), "raster transform changed logical position")
		check(a.points == b.points and a.width == b.width, "line model changed")
		var saved = b.points.duplicate()
		b.queue_free()
		await process_frame
		var restored = Line2D.new()
		restored.points = saved
		restored.width = width
		after.add_child(restored)
		check(restored.points == points, "point roundtrip changed")
	check((original.get_node("DrawViewportTextureRect") as TextureRect).size == (candidate.get_node("DrawViewportTextureRect") as TextureRect).size, "display extent changed")
	if not failed:
		print("MAP_CANVAS_RESULT ", JSON.stringify({"physical_before": [960,1620], "physical_after": [480,810], "logical": [960,1620], "line_model_roundtrip": true, "pixel_scale": 0.5, "limitations": "No rendered pixels, actual input, game serialization, LAN or RSS tested."}))
	original.queue_free()
	candidate.queue_free()
	await process_frame
	quit(1 if failed else 0)
