# INPUT:  当前战斗房间与特效容器、只读角色骨架、常见 VFX 场景及渲染策略
# OUTPUT: prepare_room()、current_room()、receive_effects() 与有界预热记录
# POS:    在遮罩后真实绘制独立预览，隔离活体角色、生命周期和游戏结算
extends Node

const VFX_PATHS = ["res://scenes/vfx/vfx_attack_slash.tscn", "res://scenes/vfx/vfx_attack_blunt.tscn"]
const SimpleEffect = preload("res://port_compat/simple_effect.gd")
var _coordinator: Node
var _shader_adapter: RefCounted
var _policy: Dictionary
var _room: Node
var _vfx_container: Node
var _generation = 0
var _seen_rooms: Dictionary = {}
var _previews: Array[Dictionary] = []
var _effects: Array[Node] = []
var _mask: CanvasLayer
var _bar: ProgressBar
var _watchdog: Timer
var _warming = false
var _frames = 2
var _simple_warmed = false
const COVER_TEXT = "准备战斗…"
const COVER_FONT_LIMIT = 16
const COVER_CONTROL_LIMIT = 256

func configure(coordinator: Node, shader_adapter: RefCounted, policy: Dictionary) -> void:
	_coordinator = coordinator
	_shader_adapter = shader_adapter
	_policy = policy
	var configured = OS.get_environment("SLL_WARMUP_FRAMES")
	_frames = clampi(configured.to_int(), 1, 6) if not configured.is_empty() else 2
	set_process_input(false)

func current_room() -> Node:
	return _room if is_instance_valid(_room) and _warming else null

func _input(_event: InputEvent) -> void:
	if _warming:
		get_viewport().set_input_as_handled()

func prepare_room(room, actors: Array, vfx_container) -> void:
	if not is_instance_valid(room) or not room.is_inside_tree() or room.is_queued_for_deletion() or _seen_rooms.has(room.get_instance_id()):
		return
	_generation += 1
	_finish()
	_coordinator.clear_room_pins()
	var generation = _generation
	_room = room
	_vfx_container = vfx_container if is_instance_valid(vfx_container) and room.is_ancestor_of(vfx_container) else null
	_seen_rooms[room.get_instance_id()] = true
	room.tree_exiting.connect(_room_exiting.bind(room.get_instance_id()), CONNECT_ONE_SHOT)
	_warming = true
	set_process_input(true)
	_create_mask(room)
	_watchdog = Timer.new()
	_watchdog.one_shot = true
	_watchdog.wait_time = 90.0
	_watchdog.timeout.connect(_timeout, CONNECT_ONE_SHOT)
	add_child(_watchdog)
	_watchdog.start()
	var started = Time.get_ticks_msec()
	await get_tree().process_frame
	await get_tree().process_frame
	if not _valid_job(room, generation):
		return
	var sprites: Array[Node] = []
	for actor in actors:
		if is_instance_valid(actor):
			_collect_spine(actor, sprites)
	if sprites.is_empty():
		_collect_spine(room, sprites)
	var clips = 0
	var progress = 0
	print("[RENDER-WARMUP] begin renderer=", _policy.method, "/", _policy.driver, " quality=", _policy.get("quality", ""), " sprites=", sprites.size(), " frames_per_clip=", _frames, " cover_ms=", Time.get_ticks_msec() - started)
	var spine_started = Time.get_ticks_msec()
	for source in sprites.slice(0, 8):
		if not _valid_job(room, generation):
			return
		var preview_started = Time.get_ticks_msec()
		var preview = _make_preview(source)
		if preview.is_empty():
			continue
		_previews.append(preview)
		room.add_child(preview.node)
		preview.node.global_transform = source.global_transform
		var names = _animation_names(preview.data)
		print("[RENDER-WARMUP] preview setup_ms=", Time.get_ticks_msec() - preview_started, " animations=", names.size())
		var chosen: Array[String] = []
		for animation_name in names:
			var lower: String = animation_name.to_lower()
			if OS.get_environment("SLL_COMBAT_WARMUP") == "all" or lower.contains("attack") or lower.contains("hurt") or lower.contains("hit") or lower.contains("cast") or lower.contains("block") or lower.contains("idle"):
				chosen.append(animation_name)
		var maximum = 128 if OS.get_environment("SLL_COMBAT_WARMUP") == "all" else 8
		for animation_name in chosen.slice(0, maximum):
			if not _valid_job(room, generation) or not is_instance_valid(preview.node):
				return
			var clip_started = Time.get_ticks_msec()
			preview.track = preview.state.call("set_animation", animation_name, false, 0)
			if not _has_methods(preview.track, ["set_track_time", "set_mix_duration", "get_animation_end"]) or not preview.track.is_class("SpineTrackEntry"):
				continue
			preview.track.call("set_mix_duration", 0.0)
			var duration_value = preview.track.call("get_animation_end")
			if not (duration_value is float or duration_value is int):
				continue
			var duration: float = duration_value
			for sample in _frames:
				if not _valid_job(room, generation):
					return
				var ratio = 0.05 if _frames == 1 else lerpf(0.05, 0.85, float(sample) / float(_frames - 1))
				preview.track.call("set_track_time", maxf(0.0, duration * ratio))
				preview.node.call("update_skeleton", 0.0)
				await get_tree().process_frame
			clips += 1
			print("[RENDER-WARMUP] clip=", animation_name, " frames=", _frames, " elapsed_ms=", Time.get_ticks_msec() - clip_started)
			preview.track = null
		progress += 1
		if is_instance_valid(_bar):
			_bar.value = 70.0 * float(progress) / float(maxi(1, sprites.size()))
		_release_preview(preview)
		_previews.erase(preview)
	if not _valid_job(room, generation):
		return
	print("[RENDER-WARMUP] spine elapsed_ms=", Time.get_ticks_msec() - spine_started, " clips=", clips)
	var effects_started = Time.get_ticks_msec()
	# The bridge creates visual-only hit sparks/numbers and plays FMOD samples
	# at volume zero, after the loading cover has actually been drawn.
	if is_instance_valid(_vfx_container) and _vfx_container.is_inside_tree():
		_coordinator.effects_requested.emit()
		print("[RENDER-WARMUP] bridge effects_ms=", Time.get_ticks_msec() - effects_started)
	var simple = _coordinator.simple_effects_enabled()
	if simple and not _coordinator.is_startup_effects_successful() and not _simple_warmed and is_instance_valid(_vfx_container):
		var root = Node2D.new()
		var flash = Polygon2D.new()
		flash.name = "PortSimpleEffect"
		flash.polygon = PackedVector2Array([Vector2(-28, -3), Vector2(28, -3), Vector2(28, 3), Vector2(-28, 3)])
		flash.set_script(SimpleEffect)
		root.add_child(flash)
		_effects.append(root)
		_vfx_container.add_child(root)
		_simple_warmed = true
	for path in ([] if simple else VFX_PATHS):
		if not is_instance_valid(_vfx_container) or not _vfx_container.is_inside_tree():
			break
		var path_started = Time.get_ticks_msec()
		var packed = _coordinator.pin_resource(path)
		var pin_done = Time.get_ticks_msec()
		if packed is PackedScene:
			_coordinator.protect_dependencies(path)
			var dependencies_done = Time.get_ticks_msec()
			var effect = packed.instantiate()
			var instantiate_done = Time.get_ticks_msec()
			_vfx_container.add_child(effect)
			var attached_done = Time.get_ticks_msec()
			if effect is Node2D:
				for actor in actors:
					if is_instance_valid(actor) and actor is Node2D:
						effect.global_position = actor.global_position
						break
			_effects.append(effect)
			_apply_subtree(effect)
			print("[RENDER-WARMUP] effect path=", path, " pin_ms=", pin_done - path_started, " dependencies_ms=", dependencies_done - pin_done, " instantiate_ms=", instantiate_done - dependencies_done, " attach_ms=", attached_done - instantiate_done, " adapt_ms=", Time.get_ticks_msec() - attached_done)
	print("[RENDER-WARMUP] effects setup_ms=", Time.get_ticks_msec() - effects_started, " count=", _effects.size())
	var effects_draw_started = Time.get_ticks_msec()
	var draw_frames = _frames if simple else maxi(12, _frames)
	for frame in draw_frames:
		if not _valid_job(room, generation):
			return
		if is_instance_valid(_bar):
			_bar.value = 70.0 + 30.0 * float(frame + 1) / float(draw_frames)
		await get_tree().process_frame
	print("[RENDER-WARMUP] effects draw_ms=", Time.get_ticks_msec() - effects_draw_started, " frames=", draw_frames)
	print("[RENDER-WARMUP] complete clips=", clips, " effects=", _effects.size(), " retained=", _coordinator.get("_pins").size(), " elapsed_ms=", Time.get_ticks_msec() - started)
	_finish()

func receive_effects(effects: Array) -> void:
	if not is_instance_valid(_room) or not _warming or not is_instance_valid(_vfx_container) or not _vfx_container.is_inside_tree():
		for effect in effects:
			if effect is Node and is_instance_valid(effect) and effect.get_parent() == null:
				effect.queue_free()
		return
	# Take ownership of every unattached node before invoking any scene callbacks.
	var accepted: Array[Node] = []
	for effect in effects:
		if effect is Node and is_instance_valid(effect) and effect.get_parent() == null:
			accepted.append(effect)
			_effects.append(effect)
	for effect in accepted:
		if _warming and is_instance_valid(effect) and not effect.is_queued_for_deletion() and is_instance_valid(_vfx_container):
			var attach_started = Time.get_ticks_msec()
			_vfx_container.add_child(effect)
			var attached_done = Time.get_ticks_msec()
			_apply_subtree(effect)
			print("[RENDER-WARMUP] bridge effect=", effect.get_class(), " attach_ms=", attached_done - attach_started, " adapt_ms=", Time.get_ticks_msec() - attached_done)

func _apply_subtree(node) -> void:
	if not is_instance_valid(node) or node.is_queued_for_deletion():
		return
	_shader_adapter.apply_node(node)
	for index in node.get_child_count():
		_apply_subtree(node.get_child(index))

func _collect_spine(node: Node, result: Array[Node], depth: int = 0) -> void:
	if depth > 16 or result.size() >= 8 or not is_instance_valid(node):
		return
	if node.is_class("SpineSprite") and node is Node2D and node.is_visible_in_tree():
		result.append(node)
		return
	for index in node.get_child_count():
		_collect_spine(node.get_child(index), result, depth + 1)

func _has_methods(object: Variant, methods: Array) -> bool:
	if typeof(object) != TYPE_OBJECT or not is_instance_valid(object):
		return false
	for method in methods:
		if not object.has_method(method):
			return false
	return true

func _make_preview(source: Node) -> Dictionary:
	if not ClassDB.can_instantiate("SpineSprite") or not _has_methods(source, ["get_skeleton_data_res", "get_skeleton"]):
		return {}
	var data = source.call("get_skeleton_data_res")
	if not _has_methods(data, ["is_skeleton_data_loaded", "get_animations"]) or not data.is_class("SpineSkeletonDataResource"):
		return {}
	var loaded = data.call("is_skeleton_data_loaded")
	if not loaded is bool or not loaded:
		return {}
	var original_skeleton = source.call("get_skeleton")
	if not _has_methods(original_skeleton, ["get_skin"]) or not original_skeleton.is_class("SpineSkeleton"):
		return {}
	var node = ClassDB.instantiate("SpineSprite") as Node2D
	if node == null:
		return {}
	if not _has_methods(node, ["set_update_mode", "set_skeleton_data_res", "get_skeleton", "get_animation_state", "update_skeleton", "new_skin"]):
		node.queue_free()
		return {}
	node.call("set_update_mode", 2)
	node.call("set_skeleton_data_res", data)
	var skeleton = node.call("get_skeleton")
	var state = node.call("get_animation_state")
	if not _has_methods(skeleton, ["set_skin", "set_slots_to_setup_pose"]) or not skeleton.is_class("SpineSkeleton") or not _has_methods(state, ["set_animation"]) or not state.is_class("SpineAnimationState"):
		skeleton = null
		state = null
		node.queue_free()
		return {}
	for pair in [["get_normal_material", "set_normal_material"], ["get_additive_material", "set_additive_material"], ["get_multiply_material", "set_multiply_material"], ["get_screen_material", "set_screen_material"]]:
		if source.has_method(pair[0]) and node.has_method(pair[1]):
			node.call(pair[1], source.call(pair[0]))
	for property in ["color", "x", "y", "scale_x", "scale_y"]:
		if original_skeleton.has_method("get_" + property) and skeleton.has_method("set_" + property):
			skeleton.call("set_" + property, original_skeleton.call("get_" + property))
	var skin = null
	var original_skin = original_skeleton.call("get_skin")
	if original_skin != null:
		if not _has_methods(original_skin, ["get_name"]) or not original_skin.is_class("SpineSkin"):
			skeleton = null
			state = null
			node.queue_free()
			return {}
		var skin_name = original_skin.call("get_name")
		if not skin_name is String:
			skeleton = null
			state = null
			node.queue_free()
			return {}
		skin = node.call("new_skin", skin_name)
		if not _has_methods(skin, ["add_skin"]) or not skin.is_class("SpineSkin"):
			skin = null
			skeleton = null
			state = null
			node.queue_free()
			return {}
		skin.call("add_skin", original_skin)
		skeleton.call("set_skin", skin)
		skeleton.call("set_slots_to_setup_pose")
	original_skin = null
	original_skeleton = null
	for property in ["modulate", "self_modulate", "visible", "texture_filter", "texture_repeat", "light_mask", "visibility_layer", "show_behind_parent", "clip_children", "material", "use_parent_material"]:
		node.set(property, source.get(property))
	node.z_index = 0
	node.z_as_relative = false
	var preview = {"node": node, "data": data, "skeleton": skeleton, "state": state, "skin": skin, "track": null}
	node.tree_exiting.connect(_preview_exiting.bind(preview), CONNECT_ONE_SHOT)
	return preview

func _preview_exiting(preview: Dictionary) -> void:
	# Parent teardown can precede a suspended coroutine's next frame.
	preview.track = null
	preview.state = null
	preview.skeleton = null
	preview.skin = null
	preview.data = null

func _animation_names(data: Object) -> Array[String]:
	var names: Array[String] = []
	var animations = data.call("get_animations")
	if animations is Array:
		for animation in animations:
			if _has_methods(animation, ["get_name"]) and animation.is_class("SpineAnimation"):
				var animation_name = animation.call("get_name")
				if animation_name is String:
					names.append(animation_name)
		# The returned collection may be borrowed. Release references without
		# changing the source data's animation collection.
		animations = null
	return names

func _release_preview(preview: Dictionary) -> void:
	var node = preview.get("node")
	# Drop preview-only wrappers before their native owner leaves the tree.
	preview.track = null
	preview.state = null
	preview.skeleton = null
	preview.skin = null
	preview.data = null
	if is_instance_valid(node) and not node.is_queued_for_deletion():
		node.queue_free()
	preview.node = null

func _valid_job(room, generation: int) -> bool:
	return _warming and generation == _generation and is_instance_valid(room) and room.is_inside_tree() and not room.is_queued_for_deletion()

func _room_exiting(identity: int) -> void:
	_seen_rooms.erase(identity)
	if is_instance_valid(_room) and _room.get_instance_id() == identity:
		_generation += 1
		_finish()
		_room = null
		_coordinator.clear_room_pins()

func _exit_tree() -> void:
	_generation += 1
	_finish()
	if is_instance_valid(_coordinator):
		_coordinator.clear_room_pins()

func _timeout() -> void:
	print("[RENDER-WARMUP] timed out; restoring game input and cover")
	_generation += 1
	_finish()
	_coordinator.clear_room_pins()

func _finish() -> void:
	_warming = false
	_vfx_container = null
	set_process_input(false)
	for preview in _previews:
		_release_preview(preview)
	_previews.clear()
	for effect in _effects:
		if is_instance_valid(effect) and not effect.is_queued_for_deletion():
			effect.queue_free()
	_effects.clear()
	if is_instance_valid(_watchdog):
		_watchdog.stop()
		_watchdog.queue_free()
	_watchdog = null
	if is_instance_valid(_mask):
		_mask.queue_free()
	_mask = null
	_bar = null

func _cover_font_graph_safe(font: Font, visited: Dictionary, depth: int = 0) -> bool:
	if font == null or not (font is FontFile or font is FontVariation) or depth > 8:
		return false
	var identity = font.get_instance_id()
	if visited.has(identity):
		return true
	visited[identity] = true
	if font is FontVariation and not _cover_font_graph_safe(font.base_font, visited, depth + 1):
		return false
	for fallback in font.get_fallbacks():
		if not _cover_font_graph_safe(fallback, visited, depth + 1):
			return false
	return true

func _find_cover_font(room: Node) -> Font:
	var seen = {}
	var controls = room.find_children("*", "Control", true, false)
	for control in controls.slice(0, COVER_CONTROL_LIMIT):
		var font: Font
		if control is Label:
			font = control.get_theme_font("font")
		elif control is RichTextLabel:
			font = control.get_theme_font("normal_font")
		else:
			continue
		if font == null or seen.has(font.get_instance_id()):
			continue
		seen[font.get_instance_id()] = true
		if not _cover_font_graph_safe(font, {}):
			if seen.size() >= COVER_FONT_LIMIT:
				break
			continue
		var covers = true
		for i in COVER_TEXT.length():
			if not font.has_char(COVER_TEXT.unicode_at(i)):
				covers = false
				break
		if covers:
			return font
		if seen.size() >= COVER_FONT_LIMIT:
			break
	return null

func _create_mask(room: Node) -> void:
	_mask = CanvasLayer.new()
	_mask.layer = 120
	add_child(_mask)
	var cover = ColorRect.new()
	cover.color = Color(0.035, 0.045, 0.06, 1.0)
	cover.mouse_filter = Control.MOUSE_FILTER_STOP
	cover.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_mask.add_child(cover)
	var title_font = _find_cover_font(room)
	if title_font != null:
		var label = Label.new()
		label.add_theme_font_override("font", title_font)
		label.add_theme_font_size_override("font_size", 28)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
		label.position = Vector2(-180, -55)
		label.size = Vector2(360, 50)
		cover.add_child(label)
		# Enter the tree with empty text so Label's theme cache sees the override.
		label.text = COVER_TEXT
	_bar = ProgressBar.new()
	_bar.show_percentage = false
	_bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_bar.position = Vector2(-180, 15)
	_bar.size = Vector2(360, 10)
	cover.add_child(_bar)
