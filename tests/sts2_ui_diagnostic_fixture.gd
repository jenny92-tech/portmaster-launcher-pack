# INPUT: fake controls and hostile scripted overrides of native getters
# OUTPUT: bounded native-only UI metadata, focus priority and editable exclusion
# POS: synthetic controls only; no game or screenshots
extends SceneTree
func _initialize() -> void:
 call_deferred("_run")
func _run() -> void:
 var parent := Control.new()
 root.add_child(parent)
 var label := Label.new()
 label.name = "SafeLabel"
 label.text = "title\nline\u001b[31m"
 parent.add_child(label)
 var button := Button.new()
 button.name = "ActionButton"
 button.text = "Click"
 button.disabled = false
 parent.add_child(button)
 var edit := LineEdit.new()
 edit.name = "Password"
 edit.text = "sensitive-value"
 parent.add_child(edit)
 var custom := Label.new()
 custom.name = "ScriptedLabel"
 var script := GDScript.new()
 script.source_code = "extends Label\n@warning_ignore(\"native_method_override\")\nfunc get_text():\n get_tree().root.set_meta(\"override_executed\",true)\n return \"evil text\"\n"
 if script.reload() != OK:
  quit(1)
  return
 custom.text = "Native-scripted-label"
 custom.set_script(script)
 parent.add_child(custom)
 var hostile_button := Button.new()
 hostile_button.name = "HostileButton"
 hostile_button.text = "Native button"
 hostile_button.disabled = false
 var button_script := GDScript.new()
 button_script.source_code = "extends Button\n@warning_ignore(\"native_method_override\")\nfunc get_text():\n get_tree().root.set_meta(\"override_executed\",true)\n return \"evil text\"\n@warning_ignore(\"native_method_override\")\nfunc is_disabled():\n get_tree().root.set_meta(\"override_executed\",true)\n return true\n"
 if button_script.reload() != OK:
  quit(1)
  return
 hostile_button.set_script(button_script)
 parent.add_child(hostile_button)
 var hostile_rich := RichTextLabel.new()
 hostile_rich.name = "HostileRichText"
 hostile_rich.text = "Native rich"
 var rich_script := GDScript.new()
 rich_script.source_code = "extends RichTextLabel\n@warning_ignore(\"native_method_override\")\nfunc get_parsed_text():\n get_tree().root.set_meta(\"override_executed\",true)\n return \"evil text\"\n"
 if rich_script.reload() != OK:
  quit(1)
  return
 hostile_rich.set_script(rich_script)
 parent.add_child(hostile_rich)
 var scripted_parent := Control.new()
 scripted_parent.name = "ScriptedNButton"
 scripted_parent.position = Vector2(50,80)
 scripted_parent.size = Vector2(180,60)
 scripted_parent.focus_mode = Control.FOCUS_ALL
 var override_script := GDScript.new()
 override_script.source_code = "extends Control\n@warning_ignore(\"native_method_override\")\nfunc get_children(include_internal = false):\n get_tree().root.set_meta(\"override_executed\",true)\n return []\n@warning_ignore(\"native_method_override\")\nfunc get_global_rect():\n get_tree().root.set_meta(\"override_executed\",true)\n return Rect2(999,999,1,1)\n@warning_ignore(\"native_method_override\")\nfunc is_visible_in_tree():\n get_tree().root.set_meta(\"override_executed\",true)\n return false\n@warning_ignore(\"native_method_override\")\nfunc has_focus():\n get_tree().root.set_meta(\"override_executed\",true)\n return false\n@warning_ignore(\"native_method_override\")\nfunc get_focus_mode():\n get_tree().root.set_meta(\"override_executed\",true)\n return 0\n@warning_ignore(\"native_method_override\")\nfunc get_path():\n get_tree().root.set_meta(\"override_executed\",true)\n return NodePath(\"/root/evil\")\n@warning_ignore(\"native_method_override\")\nfunc get_class():\n get_tree().root.set_meta(\"override_executed\",true)\n return \"Control\"\n@warning_ignore(\"native_method_override\")\nfunc get_script():\n get_tree().root.set_meta(\"override_executed\",true)\n return null\n@warning_ignore(\"native_method_override\")\nfunc is_queued_for_deletion():\n get_tree().root.set_meta(\"override_executed\",true)\n return true\n@warning_ignore(\"native_method_override\")\nfunc get_global_transform_with_canvas():\n get_tree().root.set_meta(\"override_executed\",true)\n return Transform2D()\n@warning_ignore(\"native_method_override\")\nfunc get_size():\n get_tree().root.set_meta(\"override_executed\",true)\n return Vector2(999,999)\n@warning_ignore(\"native_method_override\")\nfunc get_viewport():\n get_tree().root.set_meta(\"override_executed\",true)\n return null\n"
 if override_script.reload() != OK:
  quit(1)
  return
 scripted_parent.set_script(override_script)
 parent.add_child(scripted_parent)
 var child := Label.new()
 child.name = "NativeChild"
 child.text = "reachable"
 scripted_parent.add_child(child)
 scripted_parent.grab_focus()
 var diag = load("res://ui_diagnostic.gd").new()
 root.add_child(diag)
 if diag._started:
  printerr("Diagnostic enabled without isolated bridge")
  quit(1)
  return
 var report: Dictionary = await diag.capture(self)
 var records: Array = report.controls
 var labels = records.filter(func(item): return item.path.ends_with("/SafeLabel"))
 var buttons = records.filter(func(item): return item.path.ends_with("/ActionButton"))
 var wrappers = records.filter(func(item): return item.path.ends_with("/ScriptedNButton"))
 var scripted_labels = records.filter(func(item): return item.path.ends_with("/ScriptedLabel"))
 var hostile_buttons = records.filter(func(item): return item.path.ends_with("/HostileButton"))
 var hostile_richs = records.filter(func(item): return item.path.ends_with("/HostileRichText"))
 if labels.size()!=1 or labels[0].text!="title line [31m" or buttons.size()!=1 or buttons[0].disabled!=false or wrappers.size()!=1 or not wrappers[0].focused or not wrappers[0].scripted or wrappers[0].rect != [50.0,80.0,180.0,60.0] or not report.focus_path.ends_with("/ScriptedNButton") or scripted_labels.size()!=1 or scripted_labels[0].text!="Native-scripted-label" or hostile_buttons.size()!=1 or hostile_buttons[0].text!="Native button" or hostile_buttons[0].disabled!=false or hostile_richs.size()!=1 or hostile_richs[0].text!="Native rich":
  printerr("Unexpected UI records ", report)
  quit(1)
  return
 # Known affine mapping includes parent scaling and child position, independent
 # of the legacy global rect. The viewport mouse and screen transform are native.
 parent.position = Vector2(30,40)
 parent.scale = Vector2(2,3)
 var mapped: Dictionary = await diag.capture(self)
 var wrapped = mapped.controls.filter(func(item): return item.path.ends_with("/ScriptedNButton"))
 if wrapped.size()!=1 or wrapped[0].local_size != [180.0,60.0] or wrapped[0].local_to_viewport != [2.0,0.0,0.0,3.0,130.0,280.0] or not wrapped[0].root_viewport:
  printerr("Incorrect control coordinate mapping ", wrapped)
  quit(1)
  return
 var native_root: Viewport = root
 if mapped.viewport.mouse_position != [native_root.get_mouse_position().x,native_root.get_mouse_position().y] or mapped.viewport.screen_transform != diag._transform(native_root.get_screen_transform()) or mapped.viewport.visible_size != [native_root.get_visible_rect().size.x,native_root.get_visible_rect().size.y] or not mapped.viewport.has("window_focused"):
  printerr("Incorrect viewport coordinate metadata ", mapped.viewport)
  quit(1)
  return
 # A scripted viewport must not intercept any metadata getter.
 var hostile_viewport := SubViewport.new()
 var viewport_script := GDScript.new()
 viewport_script.source_code = "extends SubViewport\n@warning_ignore(\"native_method_override\")\nfunc get_mouse_position():\n get_tree().root.set_meta(\"override_executed\",true)\n return Vector2(999,999)\n@warning_ignore(\"native_method_override\")\nfunc get_visible_rect():\n get_tree().root.set_meta(\"override_executed\",true)\n return Rect2(999,999,1,1)\n@warning_ignore(\"native_method_override\")\nfunc get_final_transform():\n get_tree().root.set_meta(\"override_executed\",true)\n return Transform2D()\n@warning_ignore(\"native_method_override\")\nfunc get_screen_transform():\n get_tree().root.set_meta(\"override_executed\",true)\n return Transform2D()\n"
 if viewport_script.reload() != OK:
  quit(1)
  return
 hostile_viewport.set_script(viewport_script)
 root.add_child(hostile_viewport)
 var sub_metadata: Dictionary = diag._viewport_metadata(hostile_viewport)
 if sub_metadata.mouse_position == [999.0,999.0] or sub_metadata.visible_position == [999.0,999.0] or root.has_meta("override_executed"):
  printerr("Scripted viewport getter was called")
  quit(1)
  return
 hostile_viewport.queue_free()
 var encoded := JSON.stringify(report)
 if "sensitive-value" in encoded or "evil text" in encoded or report.skipped_editable != 1 or report.scripted_controls < 2 or root.has_meta("override_executed") or not encoded.contains("NativeChild"):
  printerr("Unsafe UI getter executed")
  quit(1)
  return
 if diag._safe_text("a\u2028b\n" + "x".repeat(200), 8).length() != 9:
  printerr("Text limit not enforced")
  quit(1)
  return
 var expired: Dictionary = await diag.capture(self, Time.get_ticks_msec())
 if not expired.truncated or not expired.controls.is_empty():
  printerr("UI deadline not enforced")
  quit(1)
  return
 for i in 170:
  var extra := Label.new()
  extra.text = "fixture"
  parent.add_child(extra)
 var bounded: Dictionary = await diag.capture(self)
 if bounded.controls.size()!=160 or not bounded.truncated or not bounded.controls[0].path.ends_with("/ScriptedNButton") or not JSON.stringify(bounded.controls).contains("NativeChild"):
  printerr("UI priority or control limit not enforced")
  quit(1)
  return
 print("UI_DIAGNOSTIC_FIXTURE_OK")
 diag.queue_free()
 parent.queue_free()
 quit(0)
