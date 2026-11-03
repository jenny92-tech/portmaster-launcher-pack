# INPUT:  实际 RenderingServer 信息、兼容资源表及游戏侧桥接调用
# OUTPUT: 材质替换、房间预热、特效接管和资源保护接口
# POS:    共用 Vulkan/OpenGL 适配入口，以事件驱动批处理材质和当前房间预热
extends Node

signal effects_requested
signal startup_effects_finished(success: bool)
const BundledFontTrial = preload("res://port_compat/bundled_font_trial.gd")
const ShaderAdapter = preload("res://port_compat/shader_compat.gd")
const CombatWarmup = preload("res://port_compat/combat_warmup.gd")
const StartupEffectPreload = preload("res://port_compat/startup_effect_preload.gd")
const PerformanceOverlay = preload("res://addons/portkit_performance/overlay.gd")
var _shader_adapter: RefCounted
var _warmup: Node
var _startup_effects: Node
var _policy: Dictionary = {}
var _pending: Array[Node] = []
var _pending_ids: Dictionary = {}
var _flush_queued = false
var _ready_for_calls = false
var _pins: Dictionary = {}
var _pin_paths: Dictionary = {}

static func build_policy(method: String, driver: String, adapter: String, platform: String) -> Dictionary:
	var supported = (method in ["mobile", "forward_plus"] and driver.to_lower() == "vulkan") or (method == "gl_compatibility" and driver.to_lower() in ["opengl3", "gles3"])
	return {"method": method, "driver": driver, "adapter": adapter, "platform": platform,
		"shaders": supported, "warmup": supported and driver != "dummy",
		"maleoon_gl_energy": platform == "Android" and method == "gl_compatibility" and driver.to_lower() in ["opengl3", "gles3"] and adapter.to_lower().contains("maleoon")}

func _ready() -> void:
	BundledFontTrial.install()
	PerformanceOverlay.install(get_tree())
	var profile = JSON.parse_string(FileAccess.get_file_as_string("res://port_compat/render-compat.json"))
	if not profile is Dictionary:
		push_error("[RENDER-COMPAT] Missing resource identity profile")
		return
	_policy = build_policy(RenderingServer.get_current_rendering_method(), RenderingServer.get_current_rendering_driver_name(), RenderingServer.get_video_adapter_name(), OS.get_name())
	_policy.quality = OS.get_environment("SLL_QUALITY").strip_edges().to_lower()
	_policy.shaders = _policy.shaders and OS.get_environment("SLL_SHADER_COMPAT") != "off"
	_policy.warmup = _policy.warmup and OS.get_environment("SLL_COMBAT_WARMUP") != "off" and DisplayServer.get_name() != "headless"
	_shader_adapter = ShaderAdapter.new(profile, _policy)
	_warmup = CombatWarmup.new()
	add_child(_warmup)
	_warmup.configure(self, _shader_adapter, _policy)
	if _policy.shaders or _policy.quality in ["smooth", "fluent", "performance"]:
		get_tree().node_added.connect(_on_node_added)
		_queue_existing(get_tree().root)
	_ready_for_calls = true
	if simple_effects_enabled():
		_startup_effects = StartupEffectPreload.new()
		add_child(_startup_effects)
		_startup_effects.finished.connect(_on_startup_effects_finished)
		_startup_effects.prepare()
	print("[RENDER-COMPAT] active actual=", _policy.method, "/", _policy.driver, " adapter=", _policy.adapter, " shaders=", _policy.shaders, " warmup=", _policy.warmup, " quality=", _policy.quality)

func is_compat_ready() -> bool:
	return _ready_for_calls

func simple_effects_enabled() -> bool:
	return FileAccess.file_exists("res://port_compat/simple_effects_enabled.txt")

func is_startup_effects_ready() -> bool:
	return not simple_effects_enabled() or (is_instance_valid(_startup_effects) and _startup_effects.is_done())

func is_startup_effects_successful() -> bool:
	return is_instance_valid(_startup_effects) and _startup_effects.succeeded()

func prepare_startup() -> void:
	if is_instance_valid(_startup_effects):
		_startup_effects.prepare()

func _on_startup_effects_finished(success: bool) -> void:
	startup_effects_finished.emit(success)

func _on_node_added(node: Node) -> void:
	_shader_adapter.apply_particle_rule(node)
	if not _policy.shaders or not node is CanvasItem or _pending_ids.has(node.get_instance_id()):
		return
	_pending_ids[node.get_instance_id()] = true
	_pending.append(node)
	if not _flush_queued:
		_flush_queued = true
		_flush_materials.call_deferred()

func _queue_existing(node: Node) -> void:
	_on_node_added(node)
	for index in node.get_child_count():
		_queue_existing(node.get_child(index))

func _flush_materials() -> void:
	var batch = _pending
	_pending = []
	_pending_ids.clear()
	_flush_queued = false
	for node in batch:
		_shader_adapter.apply_node(node)

func remap_material(material: Material, path: String = "") -> Material:
	if not _ready_for_calls:
		return material
	return _shader_adapter.remap(material, path)

func prepare_room(room, actors: Array, vfx_container) -> void:
	if _ready_for_calls and _policy.warmup:
		_warmup.prepare_room.call_deferred(room, actors, vfx_container)

func get_preparing_room() -> Node:
	return _warmup.current_room() if is_instance_valid(_warmup) else null

func receive_hit_effects(effects: Array) -> void:
	if is_instance_valid(_warmup):
		_warmup.receive_effects(effects)
	else:
		for effect in effects:
			if effect is Node and is_instance_valid(effect) and effect.get_parent() == null:
				effect.queue_free()

func pin_resource(path: String) -> Resource:
	if _pin_paths.has(path):
		return _pin_paths[path]
	if _pin_paths.size() >= 256:
		return null
	var resource = load(path)
	if resource is Resource:
		_pin_paths[path] = resource
		_pins[resource.get_instance_id()] = resource
	return resource

func protect_dependencies(path: String, depth: int = 0) -> void:
	if depth > 6 or _pin_paths.size() >= 256:
		return
	for dependency in ResourceLoader.get_dependencies(path):
		var fields = dependency.split("::")
		var target: String = fields[fields.size() - 1]
		if not target.begins_with("res://") or _pin_paths.has(target):
			continue
		if target.get_extension() not in ["tscn", "tres", "res", "ctex", "gdshader", "png", "webp"]:
			continue
		if pin_resource(target) != null:
			protect_dependencies(target, depth + 1)

func filter_evicted(resource: Resource) -> Resource:
	if resource != null and _pins.has(resource.get_instance_id()) and OS.get_environment("SLL_CACHE_PROTECT") != "off":
		return null
	return resource

func is_resource_protected(resource: Resource) -> bool:
	return resource != null and _pins.has(resource.get_instance_id()) and OS.get_environment("SLL_CACHE_PROTECT") != "off"

func clear_room_pins() -> void:
	# Unreference borrowed resources; never explicitly free the live game's data.
	_pins.clear()
	_pin_paths.clear()
