# INPUT:  SLL_RENDER_SCALE、根 Window 的原始渲染尺寸与坐标变换
# OUTPUT: 100/75/50% 根画面渲染比例；屏幕输出及游戏逻辑坐标保持原样
# POS:    在绘制前缩小 RenderingServer 目标，避免改变 2D 布局及输入映射
extends Node

var _root: Window
var _percent := 100
var render_size := Vector2i.ZERO

static func scaled_size(size: Vector2i, percent: int) -> Vector2i:
	return Vector2i(maxi(2, floori(size.x * percent / 100.0)), maxi(2, floori(size.y * percent / 100.0)))

func native_size() -> Vector2i:
	# Derive the original target from Window's logical layout and stretch, not
	# ViewportTexture metadata (custom and upstream engines report it differently).
	return Vector2i((_root.get_visible_rect().size * _root.get_stretch_transform().get_scale()).round())

func _ready() -> void:
	var value := OS.get_environment("SLL_RENDER_SCALE")
	if value in ["", "100"]:
		return
	if value not in ["75", "50"]:
		push_warning("[RENDER-SCALE] Unsupported scale; keeping native rendering")
		return
	_percent = int(value)
	_root = get_tree().root
	RenderingServer.frame_pre_draw.connect(_apply_frame)
	_apply_frame()

func _apply_frame() -> void:
	# Window owns the logical viewport, stretch/input transforms and screen rect.
	# Only its server-side target changes. Updating just scaling_3d_scale would
	# leave this game's 2D cards, backgrounds and UI at full rendering resolution.
	var native := native_size()
	if native.x < 2 or native.y < 2:
		return
	var target := scaled_size(native, _percent)
	var ratio := Vector2(target) / Vector2(native)
	var viewport := _root.get_viewport_rid()
	RenderingServer.viewport_set_size(viewport, target.x, target.y)
	# Match Viewport::_update_global_transform(), then scale its final pixels.
	# Reapply before drawing: camera/stretch updates can overwrite this transform.
	RenderingServer.viewport_set_global_canvas_transform(viewport, _root.get_final_transform().scaled(ratio))
	if render_size != target:
		render_size = target
		print("[RENDER-SCALE] ", _percent, "% target=", target, " native=", native, " output=", _root.size)

func _exit_tree() -> void:
	if not RenderingServer.frame_pre_draw.is_connected(_apply_frame):
		return
	RenderingServer.frame_pre_draw.disconnect(_apply_frame)
	if is_instance_valid(_root):
		var native := native_size()
		RenderingServer.viewport_set_size(_root.get_viewport_rid(), native.x, native.y)
		RenderingServer.viewport_set_global_canvas_transform(_root.get_viewport_rid(), _root.get_final_transform())
