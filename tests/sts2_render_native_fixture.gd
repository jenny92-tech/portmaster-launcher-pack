# INPUT:  Synthetic Godot nodes, resources and native STS2 rendering scripts
# OUTPUT: Headless policy, material, cache and room lifecycle assertions
# POS:    Standalone fixture that does not load player game data
extends SceneTree
const Coordinator = preload("res://port_compat/render_compat.gd")
const Adapter = preload("res://port_compat/shader_compat.gd")
const Warmup = preload("res://port_compat/combat_warmup.gd")
var failures = 0

class EffectParent extends Node2D:
    var observed_turbulence = null
    var observed_material = null
    var observed_amount = 0
    var observed_fps = 0
    func _ready() -> void:
        var particles = get_child(0) as GPUParticles2D
        observed_material = particles.process_material
        observed_turbulence = particles.process_material.turbulence_enabled
        observed_amount = particles.amount
        observed_fps = particles.fixed_fps

func make_particle_effect(scene: String, particle_name: String, material: ParticleProcessMaterial) -> EffectParent:
    var effect = EffectParent.new()
    effect.scene_file_path = scene
    var particles = GPUParticles2D.new()
    particles.name = particle_name
    particles.emitting = false
    particles.amount = 12
    particles.fixed_fps = 60
    particles.lifetime = 2.75
    particles.speed_scale = 1.5
    particles.explosiveness = 0.35
    particles.one_shot = true
    particles.interpolate = false
    particles.process_material = material
    effect.add_child(particles)
    return effect

func check(value: bool, message: String):
    if not value:
        failures += 1
        printerr("FAIL: ", message)
func _initialize():
    run.call_deferred()
func run():
    check(Coordinator.build_policy("mobile", "vulkan", "Maleoon", "Android").warmup, "mobile supported")
    check(not Coordinator.build_policy("gl_compatibility", "vulkan", "Maleoon", "Android").shaders, "mismatched backend fails closed")
    check(not Coordinator.build_policy("mobile", "dummy", "", "Linux").shaders, "dummy driver fails closed")
    check(not Coordinator.build_policy("gl_compatibility", "vulkan", "Maleoon", "Android").maleoon_gl_energy, "actual driver required")
    check(Coordinator.build_policy("gl_compatibility", "opengl3", "Maleoon 910", "Android").maleoon_gl_energy, "Android GLES Maleoon")
    check(not Coordinator.build_policy("gl_compatibility", "opengl3", "Maleoon", "Linux").maleoon_gl_energy, "platform required")
    var source_shader = Shader.new()
    source_shader.code = "shader_type canvas_item; uniform float amount = 1.0; void fragment() { COLOR *= amount; }"
    source_shader.resource_path = "res://shaders/source.gdshader"
    var source = ShaderMaterial.new()
    source.shader = source_shader
    source.set_shader_parameter("amount", 0.4)
    var profile = {"shader_paths": {source_shader.resource_path: "res://replacement.gdshader"}}
    var adapter = Adapter.new(profile, {"shaders": true})
    var first = adapter.remap(source)
    var second = adapter.remap(source)
    check(first != source and first != second, "material copies are isolated")
    check(is_equal_approx(first.get_shader_parameter("amount"), 0.4), "replacement preserves parameter")
    first.set_shader_parameter("amount", 0.8)
    check(is_equal_approx(source.get_shader_parameter("amount"), 0.4), "source parameters preserved")
    check(adapter.remap(source, "res://mods/foreign_scene.tscn") == source, "mod owner preserved")
    var priority_profile = {"shader_paths": {source_shader.resource_path: "res://replacement.gdshader"}, "global_simplified_code_hashes": [source_shader.code.sha256_text()]}
    var low_priority = Adapter.new(priority_profile, {"shaders": true, "quality": "smooth"})
    var standard_priority = Adapter.new(priority_profile, {"shaders": true, "quality": "balanced"})
    check(low_priority.remap(source) == source, "simplified shader wins over path remap in smooth")
    check(standard_priority.remap(source) != source, "standard retains path remap")
    priority_profile.global_simplified_code_hashes = ["not-the-code"]
    check(low_priority.remap(source) != source, "unrecognized shader still uses path remap")
    var lowered_blur: Shader = load("res://simplified_blur.gdshader")
    var blur_material := ShaderMaterial.new()
    blur_material.shader = lowered_blur
    var blur_profile = {"shader_paths": {lowered_blur.resource_path: "res://replacement.gdshader"}, "global_simplified_code_hashes": [lowered_blur.code.sha256_text()]}
    var blur_smooth = Adapter.new(blur_profile, {"shaders": true, "quality": "smooth"})
    var blur_standard = Adapter.new(blur_profile, {"shaders": true, "quality": "balanced"})
    check(blur_smooth.remap(blur_material).shader == lowered_blur, "seven sample shader survives actual remap")
    check(blur_standard.remap(blur_material).shader != lowered_blur, "standard shader uses existing remap")
    blur_material.set_shader_parameter("mask", true)
    check(blur_standard.remap(blur_material) == blur_material, "mask exemption precedes remapping")
    var embedded = Shader.new()
    embedded.code = "shader_type canvas_item; uniform float amount = 1.0; void fragment() { COLOR *= amount; }"
    var embedded_material = ShaderMaterial.new()
    embedded_material.shader = embedded
    var hash_profile = {"builtin_prefixes": ["res://scenes/"], "embedded_codes": {embedded.code.sha256_text(): "res://replacement.gdshader"}}
    var hash_adapter = Adapter.new(hash_profile, {"shaders": true})
    check(hash_adapter.remap(embedded_material, "res://scenes/test.tscn") != embedded_material, "known embedded code and builtin path match")
    check(hash_adapter.remap(embedded_material, "res://unknown/test.tscn") == embedded_material, "embedded code requires builtin path")
    embedded.code += "\n// changed"
    check(hash_adapter.remap(embedded_material, "res://scenes/test.tscn") == embedded_material, "unknown embedded code preserved")
    var radial = Shader.new()
    radial.code = "shader_type canvas_item; uniform vec2 blur_center; uniform float blur_power; uniform int sampling_count; void fragment() {}"
    radial.resource_path = "res://shaders/radial_blur.gdshader"
    var radial_material = ShaderMaterial.new()
    radial_material.shader = radial
    radial_material.set_shader_parameter("blur_power", 0.3)
    radial_material.set_shader_parameter("sampling_count", 7)
    var radial_profile = {"shader_paths": {radial.resource_path: "res://shaders/mobile_compat/radial_blur_compat.gdshader"}}
    for quality in ["", "balanced", "smooth", "fluent", "performance"]:
        var quality_adapter = Adapter.new(radial_profile, {"shaders": true, "quality": quality})
        var result = quality_adapter.remap(radial_material)
        var expected = "radial_blur_smooth.gdshader" if quality in ["smooth", "fluent", "performance"] else "radial_blur_compat.gdshader"
        check(result != radial_material and result.shader.resource_path.ends_with(expected), "quality chooses correct radial shader: " + quality)
        check(is_equal_approx(result.get_shader_parameter("blur_power"), 0.3) and result.get_shader_parameter("sampling_count") == 7, "radial uniforms survive: " + quality)
    var mask_shader = Shader.new()
    mask_shader.code = "shader_type canvas_item; uniform bool mask = false; void fragment() {}"
    mask_shader.resource_path = "res://shaders/masked.gdshader"
    var masked = ShaderMaterial.new()
    masked.shader = mask_shader
    masked.set_shader_parameter("mask", true)
    var mask_adapter = Adapter.new({"shader_paths": {mask_shader.resource_path: "res://replacement.gdshader"}}, {"shaders": true})
    check(mask_adapter.remap(masked) == masked, "Ancient mask preserved")
    var unknown = ShaderMaterial.new()
    unknown.shader = Shader.new()
    check(adapter.remap(unknown) == unknown, "unknown shader preserved")
    source.resource_path = "res://mods/foreign.tres"
    check(adapter.remap(source) == source, "mod material preserved")
    var coordinator = Coordinator.new()
    root.add_child(coordinator)
    await process_frame
    check(coordinator.is_compat_ready() and coordinator.is_startup_effects_ready(), "standard mode is ready without a startup manifest")
    var overlay = root.get_node_or_null("PortKitPerformance")
    check(overlay != null and overlay.visible and overlay.is_processing(), "coordinator installs enabled shared overlay")
    check(not coordinator._policy.shaders and coordinator._policy.quality == "smooth", "particle rule is active with shader remapping disabled")
    var hit = "res://scenes/vfx/hit_spark_vfx.tscn"
    var debuff = "res://scenes/vfx/ui/vfx_debuff_applied.tscn"
    var rules = [[hit, "vfx_common_specks_bright", "ParticleProcessMaterial_1pf1r", 4],
        [hit, "vfx_common_specks", "ParticleProcessMaterial_stade", 3],
        [debuff, "vfx_common_specks", "ParticleProcessMaterial_2eh7x", 4]]
    var originals = []
    for rule in rules:
        var shared = ParticleProcessMaterial.new()
        shared.turbulence_enabled = true
        shared.resource_path = rule[0] + "::" + rule[2]
        originals.append(shared)
        var first_effect = make_particle_effect(rule[0], rule[1], shared)
        var second_effect = make_particle_effect(rule[0], rule[1], shared)
        root.add_child(first_effect)
        root.add_child(second_effect)
        check(first_effect.observed_turbulence == false and second_effect.observed_turbulence == false, "rule runs before parent _ready: " + rule[1])
        check(first_effect.observed_material != shared and second_effect.observed_material != shared and first_effect.observed_material != second_effect.observed_material, "particle materials are isolated per instance")
        check(shared.turbulence_enabled, "original shared material remains unchanged")
        check(first_effect.observed_amount == rule[3] and first_effect.observed_fps == 20, "particle count and fixed FPS capped before parent _ready")
        var particles = first_effect.get_child(0) as GPUParticles2D
        check(is_equal_approx(particles.lifetime, 2.75) and is_equal_approx(particles.speed_scale, 1.5) and is_equal_approx(particles.explosiveness, 0.35) and particles.one_shot and not particles.interpolate, "particle timing and emission properties preserved")
        shared.turbulence_enabled = false
        var already_off = make_particle_effect(rule[0], rule[1], shared)
        root.add_child(already_off)
        check(already_off.observed_material == shared and already_off.observed_amount == rule[3] and already_off.observed_fps == 20, "already-disabled turbulence still gets count and FPS limits")
        var low = make_particle_effect(rule[0], rule[1], shared)
        var low_particles = low.get_child(0) as GPUParticles2D
        low_particles.amount = 2
        low_particles.fixed_fps = 15
        root.add_child(low)
        check(low.observed_amount == 2 and low.observed_fps == 15, "lower count and FPS are not raised")
        already_off.queue_free()
        low.queue_free()
        shared.turbulence_enabled = true
        first_effect.queue_free()
        second_effect.queue_free()
    var guarded = originals[0]
    var cases = [[hit, "wrong_name", guarded],
        ["res://scenes/vfx/other.tscn", "vfx_common_specks_bright", guarded],
        ["res://mods/hit_spark_vfx.tscn", "vfx_common_specks_bright", guarded]]
    var wrong_material = ParticleProcessMaterial.new()
    wrong_material.turbulence_enabled = true
    wrong_material.resource_path = hit + "::wrong_material"
    cases.append([hit, "vfx_common_specks_bright", wrong_material])
    for guard in cases:
        var effect = make_particle_effect(guard[0], guard[1], guard[2])
        root.add_child(effect)
        check(effect.observed_material == guard[2] and effect.observed_turbulence == true and effect.observed_amount == 12 and effect.observed_fps == 60, "non-matching particle remains unchanged")
        effect.queue_free()
    coordinator._policy.quality = "balanced"
    var balanced = make_particle_effect(hit, "vfx_common_specks_bright", guarded)
    root.add_child(balanced)
    check(balanced.observed_material == guarded and balanced.observed_turbulence == true and balanced.observed_amount == 12 and balanced.observed_fps == 60, "balanced quality retains original particle settings")
    balanced.queue_free()
    coordinator._policy.quality = "smooth"
    var resource = coordinator.pin_resource("res://asset.tres")
    check(resource != null and coordinator.filter_evicted(resource) == null, "pinned resource protected")
    coordinator.clear_room_pins()
    check(coordinator.filter_evicted(resource) == resource, "clear releases protection")
    for i in 256:
        coordinator._pin_paths[str(i)] = resource
    check(coordinator.pin_resource("res://asset.tres") == null, "cache has a fixed bound")
    coordinator.clear_room_pins()
    var warmup = Warmup.new()
    root.add_child(warmup)
    warmup.configure(coordinator, adapter, {"method": "mobile", "driver": "vulkan"})
    var room1 = Node2D.new()
    var room2 = Node2D.new()
    root.add_child(room1)
    root.add_child(room2)
    var container1 = Node2D.new()
    var container2 = Node2D.new()
    room1.add_child(container1)
    room2.add_child(container2)
    warmup.prepare_room(room1, [], container1)
    coordinator.pin_resource("res://asset.tres")
    warmup.prepare_room(room2, [], container2)
    check(not coordinator.is_resource_protected(resource), "switch clears previous pins")
    coordinator.pin_resource("res://asset.tres")
    room1.queue_free()
    await process_frame
    check(coordinator.is_resource_protected(resource), "old room exit does not clear current pins")
    var effect = Node2D.new()
    warmup.receive_effects([effect])
    check(effect.get_parent() == container2, "effect is owned by active room VFX container")
    room2.queue_free()
    await process_frame
    check(warmup.current_room() == null and not coordinator.is_resource_protected(resource), "exit cancels and clears pins")
    check(warmup._mask == null and not warmup._warming, "exit restores cover and input")
    var orphan = Node2D.new()
    warmup.receive_effects([orphan])
    check(orphan.is_queued_for_deletion(), "late effect discarded")
    var room3 = Node2D.new()
    var container3 = Node2D.new()
    root.add_child(room3)
    room3.add_child(container3)
    warmup.prepare_room(room3, [], container3)
    await process_frame
    await process_frame
    await process_frame
    check(warmup._effects.size() == 2 and container3.get_child_count() == 2, "common effects instantiated in VFX container")
    for i in 14:
        await process_frame
    check(not warmup._warming and warmup._mask == null, "completed warmup restores cover and input")
    check(container3.get_child_count() == 0, "completed warmup frees effects")
    var room4 = Node2D.new()
    root.add_child(room4)
    warmup.prepare_room(room4, [], null)
    var rejected = Node2D.new()
    warmup.receive_effects([rejected])
    check(rejected.is_queued_for_deletion(), "missing container discards effects")
    warmup._timeout()
    check(not warmup._warming and warmup._mask == null, "watchdog restores cover and input")
    check(not warmup._has_methods(42, ["get_name"]), "non-object native result fails closed")
    var marker = FileAccess.open("res://port_compat/simple_effects_enabled.txt", FileAccess.WRITE)
    marker.store_string("simple effects enabled\n")
    marker.close()
    var room5 = Node2D.new()
    var container5 = Node2D.new()
    root.add_child(room5)
    room5.add_child(container5)
    warmup.prepare_room(room5, [], container5)
    await process_frame
    await process_frame
    await process_frame
    check(warmup._simple_warmed and warmup._effects.size() == 1 and container5.get_child_count() == 1, "simple mode draws one lightweight effect")
    check(not coordinator.is_resource_protected(load("res://scenes/vfx/vfx_attack_slash.tscn")) and not coordinator.is_resource_protected(load("res://scenes/vfx/vfx_attack_blunt.tscn")), "simple mode does not pin heavy effects")
    room5.queue_free()
    await process_frame
    check(not warmup._warming and warmup._mask == null and warmup._effects.is_empty(), "simple mode room exit cancels and cleans up")
    var ordinary = Node2D.new()
    check(warmup._make_preview(ordinary).is_empty(), "missing Spine capability fails closed")
    ordinary.free()
    room3.queue_free()
    room4.queue_free()
    warmup.queue_free()
    coordinator.queue_free()
    if overlay != null:
        overlay.queue_free()
    await process_frame
    if failures == 0:
        print("STS2_NATIVE_OK")
    quit(1 if failures else 0)
