# INPUT: dedicated 0700 isolated directory, fake controls and explicit flags
# OUTPUT: verifies viewport mouse routing and rejects invalid fixed-file requests
# POS: Linux ARM64 headless fixture only; never opens a game or device
extends SceneTree
var clicks := 0
var downs := 0
var ups := 0
func _initialize() -> void:
 call_deferred("_run")
func write_request(path: String, contents: String) -> void:
 var f := FileAccess.open(path, FileAccess.WRITE)
 f.store_string(contents)
 f.close()
func _run() -> void:
 var test_root := OS.get_environment("SLL_DIAG_XDG_ROOT")
 var path := test_root + "/ui-control.json"
 root.size = Vector2i(640,480)
 root.content_scale_size = Vector2i(1920,1080)
 root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
 root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
 var parent := Control.new()
 parent.position = Vector2(20,30)
 parent.scale = Vector2(2,2)
 root.add_child(parent)
 var button := Button.new()
 button.position = Vector2(40,50)
 button.size = Vector2(100,60)
 button.pressed.connect(func(): clicks += 1)
 button.button_down.connect(func(): downs += 1)
 button.button_up.connect(func(): ups += 1)
 parent.add_child(button)
 var spy := Node.new()
 var spy_script := GDScript.new()
 spy_script.source_code = "extends Node\nvar buttons = 0\nvar last_motion = null\nfunc _input(event):\n if event is InputEventMouseButton: buttons += 1\n if event is InputEventMouseMotion: last_motion = event\n"
 if spy_script.reload()!=OK: quit(1);return
 spy.set_script(spy_script)
 root.add_child(spy)
 var diag = load("res://ui_diagnostic.gd").new()
 root.add_child(diag)
 await process_frame
 var vp: Viewport = root
 var pos: Vector2 = button.get_global_transform_with_canvas() * Vector2(50,30)
 var physical: Vector2 = vp.get_final_transform() * pos
 if physical.is_equal_approx(pos):
  printerr("fixture lacks window scaling");quit(1);return
 if not vp.get_visible_rect().has_point(pos):
  printerr("fixture button outside viewport ", vp.get_visible_rect(), " point ", pos)
  quit(1)
  return
 var click := '{"seq":1,"action":"click","x":%s,"y":%s}' % [pos.x,pos.y]
 write_request(path, click)
 OS.set_environment("SLL_UI_CONTROL", "0")
 await diag._control_once()
 if clicks != 0 or diag._last_control_seq != -1:
  printerr("missing control flag enabled input")
  quit(1)
  return
 OS.set_environment("SLL_UI_CONTROL", "1")
 OS.set_environment("SLL_DIAG_XDG_ROOT", "/tmp/sts2-memory-diag-fake")
 await diag._control_once()
 OS.set_environment("SLL_DIAG_XDG_ROOT", test_root)
 if clicks != 0 or diag._last_control_seq != -1:
  printerr("fake isolated root enabled input")
  quit(1)
  return
 await diag._control_once()
 await process_frame
 if clicks != 1 or diag._last_control_seq != 1:
  printerr("valid transformed click did not reach button: ",clicks)
  quit(1)
  return
 await diag._control_once()
 write_request(path, '{"seq":1,"action":"click","x":%s,"y":%s} ' % [pos.x,pos.y])
 await diag._control_once()
 if clicks != 1:
  printerr("replayed click accepted")
  quit(1)
  return
 write_request(path, '{"seq":2,"action":"click","x":999999,"y":1}')
 await diag._control_once()
 write_request(path, '{"seq":3,"action":"click","x":1,"y":1,"extra":true}')
 await diag._control_once()
 write_request(path, '{"seq":3,"seq":4,"action":"click","x":1,"y":1}')
 await diag._control_once()
 write_request(path, "x".repeat(513))
 await diag._control_once()
 if clicks != 1 or diag._last_control_seq != 2:
  printerr("invalid request accepted")
  quit(1)
  return
 write_request(path, '{"seq":3,"action":"mouse_move","x":%s,"y":%s}' % [pos.x,pos.y])
 if FileAccess.set_unix_permissions(test_root, 493) != OK:
  printerr("could not weaken test directory permissions")
  quit(1)
  return
 await diag._control_once()
 if diag._last_control_seq != 2:
  printerr("non-private directory accepted")
  quit(1)
  return
 FileAccess.set_unix_permissions(test_root, 448)
 await diag._control_once()
 await process_frame
 if diag._last_control_seq != 3 or clicks != 1:
  printerr("valid mouse move not accepted")
  quit(1)
  return
 var event: InputEventMouseMotion = spy.get("last_motion")
 if event == null or event.window_id != root.get_window_id() or not event.position.is_equal_approx(pos) or not event.global_position.is_equal_approx(pos):
  printerr("Incorrect transformed motion or window ID");quit(1);return
 DirAccess.remove_absolute(path)
 var fs := DirAccess.open(test_root)
 if fs.create_link("data/SlayTheSpire2", "ui-control.json") != OK:
  printerr("could not create test symlink")
  quit(1)
  return
 await diag._control_once()
 if clicks != 1 or diag._last_control_seq != 3:
  printerr("symlink accepted")
  quit(1)
  return
 DirAccess.remove_absolute(path)
 var button_events_before: int = spy.get("buttons")
 for i in 30:
  write_request(path, '{"seq":%d,"action":"click","x":%s,"y":%s}' % [i+4,pos.x,pos.y])
  await diag._control_once()
  await process_frame
  if clicks != i+2 or downs != i+2 or ups != i+2:
   printerr("Duplicate or missing input in click ",i," counts=",[clicks,downs,ups]);quit(1);return
 if int(spy.get("buttons")) - button_events_before != 60:
  printerr("Wrong number of button events");quit(1);return
 if not vp.get_mouse_position().is_equal_approx(pos) or not button.get_global_mouse_position().is_equal_approx(pos):
  printerr("Mouse state did not follow event: ",vp.get_mouse_position()," / ",button.get_global_mouse_position()," expected ",pos);quit(1);return
 print("LINUX_UI_CONTROL_FIXTURE_OK")
 quit(0)
