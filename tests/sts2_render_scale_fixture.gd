# INPUT:  合成根窗口、画布伸缩、相机变换与渲染比例脚本
# OUTPUT: 渲染目标、重复绘制、窗口变化、布局及输入不变量的无头断言
# POS:    不加载游戏，不以无头尺寸断言代替 GPU 帧率及画面验收
extends SceneTree
const Scale = preload("res://render_scale.gd")

func _initialize():
	call_deferred("run")

func run():
	root.size = Vector2i(1280, 720)
	root.content_scale_size = Vector2i(1920, 1080)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	var logical := root.get_visible_rect()
	var transform := root.get_final_transform()
	for percent in [100, 75, 50]:
		assert(Scale.scaled_size(Vector2i(1280, 720), percent) == {100:Vector2i(1280,720),75:Vector2i(960,540),50:Vector2i(640,360)}[percent])
		OS.set_environment("SLL_RENDER_SCALE", str(percent))
		var scaler = Scale.new()
		root.add_child(scaler)
		if percent == 100:
			assert(not RenderingServer.frame_pre_draw.is_connected(scaler._apply_frame))
		else:
			assert(scaler.native_size() == Vector2i(1280, 720))
			assert(scaler.render_size == Scale.scaled_size(Vector2i(1280,720),percent))
			for frame in 3:
				scaler._apply_frame()
				assert(scaler.render_size == Scale.scaled_size(Vector2i(1280,720),percent), "scale must not compound")
		assert(root.size == Vector2i(1280,720) and root.get_visible_rect() == logical)
		assert(root.get_final_transform() == transform, "input and logical stretch must stay native")
		root.remove_child(scaler)
		assert(not RenderingServer.frame_pre_draw.is_connected(scaler._apply_frame))
		scaler.free()
	OS.set_environment("SLL_RENDER_SCALE", "50")
	var scaler = Scale.new()
	root.add_child(scaler)
	root.size = Vector2i(1920,1080)
	root.global_canvas_transform = Transform2D(0.0,Vector2(17,29))
	var camera_transform := root.get_final_transform()
	scaler._apply_frame()
	assert(scaler.render_size == Vector2i(960,540))
	assert(root.get_visible_rect() == logical and root.get_final_transform() == camera_transform)
	root.size = Vector2i(1280,800)
	scaler._apply_frame()
	assert(scaler.render_size == Vector2i(640,360), "letterbox area, not the whole display, is scaled")
	assert(root.size == Vector2i(1280,800) and root.get_visible_rect() == logical)
	root.remove_child(scaler)
	scaler.free()
	assert(Scale.scaled_size(Vector2i(1333,751),75) == Vector2i(999,563))
	print("STS2_RENDER_SCALE_OK")
	quit()
