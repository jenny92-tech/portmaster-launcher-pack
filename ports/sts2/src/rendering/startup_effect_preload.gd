# INPUT:  audited simple-effects manifest and its generated PackedScenes
# OUTPUT: bounded startup loading, a shaderless offscreen draw, and completion status
# POS:    keeps tiny scenes alive without instantiating game-owned C# roots
extends Node

signal finished(success: bool)

const MANIFEST = "res://port_compat/simple_effects_manifest.json"
const MAX_SCENES = 256
const TIMEOUT_MS = 5000
var _scenes: Dictionary = {}
var _done = false
var _success = false
var _running = false
var _preview: SubViewport

func is_done() -> bool:
	return _done

func succeeded() -> bool:
	return _done and _success

func prepare() -> void:
	if _done or _running:
		return
	_running = true
	_run.call_deferred()

func _run() -> void:
	var started = Time.get_ticks_msec()
	var manifest = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	if not manifest is Dictionary or not manifest.get("scenes") is Array or manifest.scenes.size() > MAX_SCENES:
		_finish(false, started, "invalid manifest")
		return
	print("[SIMPLE-STARTUP] begin count=", manifest.scenes.size())
	for item in manifest.scenes:
		if not item is Dictionary or not item.get("path") is String:
			_finish(false, started, "invalid entry")
			return
		var path: String = item.path
		if not path.begins_with("res://scenes/vfx/") or not path.ends_with(".tscn") or _scenes.has(path):
			_finish(false, started, "invalid or duplicate path")
			return
		var scene = ResourceLoader.load(path)
		if not scene is PackedScene:
			_finish(false, started, "scene load failed: " + path)
			return
		_scenes[path] = scene
		if Time.get_ticks_msec() - started >= TIMEOUT_MS:
			_finish(false, started, "timeout")
			return
		await get_tree().process_frame
		if not is_inside_tree():
			return
	if DisplayServer.get_name() != "headless":
		_preview = SubViewport.new()
		_preview.size = Vector2i(64, 64)
		_preview.transparent_bg = true
		_preview.render_target_update_mode = SubViewport.UPDATE_ONCE
		var polygon = Polygon2D.new()
		polygon.polygon = PackedVector2Array([Vector2(4, 28), Vector2(60, 28), Vector2(60, 36), Vector2(4, 36)])
		_preview.add_child(polygon)
		add_child(_preview)
		await get_tree().process_frame
		if not is_inside_tree():
			return
	_finish(Time.get_ticks_msec() - started < TIMEOUT_MS, started, "")

func _finish(success: bool, started: int, reason: String) -> void:
	if is_instance_valid(_preview):
		_preview.queue_free()
	_preview = null
	if not success:
		_scenes.clear()
	_running = false
	_done = true
	_success = success
	print("[SIMPLE-STARTUP] complete success=", success, " count=", _scenes.size(), " elapsed_ms=", Time.get_ticks_msec() - started, " reason=", reason)
	finished.emit(success)

func _exit_tree() -> void:
	if is_instance_valid(_preview):
		_preview.queue_free()
	_preview = null
	_scenes.clear()
