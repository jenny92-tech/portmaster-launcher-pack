# INPUT:  Polygon2D child of a generated lightweight VFX root
# OUTPUT: brief shaderless flash and cleanup of the child or its owned root
# POS:    replaces visuals of audited Smooth VFX scenes
extends Polygon2D

@export var free_root_on_finish := true

func _ready() -> void:
	var tween = create_tween().set_parallel(true)
	tween.tween_property(self, "scale", Vector2(1.45, 1.45), 0.18)
	tween.tween_property(self, "modulate:a", 0.0, 0.18)
	tween.chain().tween_callback(get_parent().queue_free if free_root_on_finish else queue_free)
