# INPUT:  精确路径/代码身份表、实际后端策略与原始材质
# OUTPUT: remap()、apply_node()、精确粒子策略与替代 Shader 的有界缓存
# POS:    为 Vulkan/OpenGL 保留材质语义并隔离每个实例的可写参数
extends RefCounted

const PARTICLE_RULES = {
	"res://scenes/vfx/hit_spark_vfx.tscn": {"vfx_common_specks_bright": ["ParticleProcessMaterial_1pf1r", 4], "vfx_common_specks": ["ParticleProcessMaterial_stade", 3]},
	"res://scenes/vfx/ui/vfx_debuff_applied.tscn": {"vfx_common_specks": ["ParticleProcessMaterial_2eh7x", 4]}
}
var _particle_rule_count = 0
var _profile: Dictionary
var _policy: Dictionary
var _shaders: Dictionary = {}
var _logged: Dictionary = {}

func _init(profile: Dictionary, policy: Dictionary) -> void:
	_profile = profile
	_policy = policy

func remap(source: Material, owner_path: String = "") -> Material:
	if not _policy.get("shaders", false) or not source is ShaderMaterial:
		return source
	var original = source as ShaderMaterial
	if original.shader == null:
		return source
	var shader_path: String = original.shader.resource_path
	if shader_path.begins_with("res://shaders/mobile_compat/"):
		return source
	var provenance = original.resource_path if not original.resource_path.is_empty() else owner_path
	if shader_path.begins_with("res://mods/") or provenance.begins_with("res://mods/") or provenance.begins_with("res://user/") or owner_path.begins_with("res://mods/") or owner_path.begins_with("res://user/"):
		return source
	# The Ancient mask is a different compositing contract, even when a cache
	# field happens to be named like the ordinary card blur.
	if original.get_shader_parameter("mask") == true:
		return source
	# Keep globally simplified shader code instead of replacing it with an
	# older, more expensive path-based variant in the low quality profiles.
	if _policy.get("quality", "") in ["smooth", "fluent", "performance"]:
		var code = original.shader.code.replace("\r\n", "\n").replace("\r", "\n")
		if code.sha256_text() in _profile.get("global_simplified_code_hashes", []):
			return source
	var replacement_path: String = _profile.get("material_paths", {}).get(provenance, "")
	if replacement_path.is_empty():
		if shader_path in _profile.get("excluded_shader_paths", []):
			return source
		replacement_path = _profile.get("shader_paths", {}).get(shader_path, "")
	if replacement_path.is_empty():
		var builtin = false
		var identity_path = shader_path if not shader_path.is_empty() else provenance
		for prefix in _profile.get("builtin_prefixes", []):
			if identity_path.begins_with(prefix):
				builtin = true
				break
		if not builtin:
			return source
		var code = original.shader.code.replace("\r\n", "\n").replace("\r", "\n")
		replacement_path = _profile.get("embedded_codes", {}).get(code.sha256_text(), "")
	if replacement_path.is_empty():
		return source
	if replacement_path == "res://shaders/mobile_compat/radial_blur_compat.gdshader" and _policy.get("quality", "") in ["smooth", "fluent", "performance"]:
		replacement_path = "res://shaders/mobile_compat/radial_blur_smooth.gdshader"
	if not _shaders.has(replacement_path):
		var loaded = load(replacement_path)
		if not loaded is Shader:
			push_warning("[RENDER-COMPAT] Missing shader: " + replacement_path)
			return source
		_shaders[replacement_path] = loaded
	var copy = original.duplicate(false) as ShaderMaterial
	if copy == null:
		return source
	# Only the material is writable; texture resources and the replacement
	# Shader are shared read-only. No generated sampler aliases are invented.
	var parameters: Dictionary = {}
	for uniform in original.shader.get_shader_uniform_list():
		var name: String = uniform.name
		parameters[name] = original.get_shader_parameter(name)
	copy.shader = _shaders[replacement_path]
	for uniform in copy.shader.get_shader_uniform_list():
		var name: String = uniform.name
		if parameters.has(name) and parameters[name] != null:
			copy.set_shader_parameter(name, parameters[name])
	if not _logged.has(replacement_path):
		_logged[replacement_path] = true
		print("[RENDER-COMPAT] variant ", replacement_path, " from=", provenance)
	return copy

# Called synchronously on node_added, before the effect root's _Ready restarts
# its particles. Copy only known game subresources; other scenes retain theirs.
func apply_particle_rule(node: Node) -> void:
	if _policy.get("quality", "") not in ["smooth", "fluent", "performance"] or not node is GPUParticles2D:
		return
	var parent = node.get_parent()
	if not is_instance_valid(parent):
		return
	var scene: String = parent.scene_file_path
	var rule: Array = PARTICLE_RULES.get(scene, {}).get(String(node.name), [])
	if rule.is_empty():
		return
	var material = node.process_material as ParticleProcessMaterial
	if material == null or material.resource_path != scene + "::" + rule[0]:
		return
	var had_turbulence = material.turbulence_enabled
	if had_turbulence:
		var copy = material.duplicate(false) as ParticleProcessMaterial
		if copy == null:
			return
		copy.turbulence_enabled = false
		node.process_material = copy
	var old_amount = node.amount
	var old_fps = node.fixed_fps
	node.amount = mini(node.amount, rule[1])
	if node.fixed_fps == 60:
		node.fixed_fps = 20
	var key = scene + "::" + String(node.name)
	if not _logged.has(key):
		_logged[key] = true
		_particle_rule_count += 1
		print("[RENDER-COMPAT] smooth particle scene=", scene, " node=", node.name, " turbulence=", had_turbulence, "->false amount=", old_amount, "->", node.amount, " fixed_fps=", old_fps, "->", node.fixed_fps, " rule_count=", _particle_rule_count)

func apply_node(node: Node) -> void:
	if not is_instance_valid(node) or not node.is_inside_tree() or node.is_queued_for_deletion():
		return
	if node is CanvasItem:
		var owner_path = node.scene_file_path
		if owner_path.is_empty() and is_instance_valid(node.owner):
			owner_path = node.owner.scene_file_path
		var replacement = self.remap(node.material, owner_path)
		if replacement != node.material:
			node.material = replacement
	if node is GPUParticles2D and _policy.get("maleoon_gl_energy", false):
		_apply_energy_rule(node)

func _apply_energy_rule(particles: GPUParticles2D) -> void:
	if particles.scene_file_path != "res://scenes/vfx/fire_impact/vfx_fire_embers_straight.tscn" or particles.get_script() != null:
		return
	var front = particles.get_parent()
	var counter = front.get_parent() if is_instance_valid(front) else null
	if not is_instance_valid(front) or not is_instance_valid(counter):
		return
	if front.scene_file_path != "res://scenes/vfx/energy/ironclad/ironclad_energy_vfx_front.tscn" or counter.scene_file_path != "res://scenes/combat/energy_counters/ironclad_energy_counter.tscn":
		return
	var material = particles.process_material as ParticleProcessMaterial
	if material == null or not particles.one_shot or not material.turbulence_enabled:
		return
	if not material.resource_path.begins_with(front.scene_file_path + "::"):
		return
	var copy = material.duplicate(false) as ParticleProcessMaterial
	copy.turbulence_enabled = false
	particles.process_material = copy
	if not _logged.has("maleoon-energy"):
		_logged["maleoon-energy"] = true
		print("[RENDER-COMPAT] Android Maleoon OpenGL energy turbulence disabled on instance only")
