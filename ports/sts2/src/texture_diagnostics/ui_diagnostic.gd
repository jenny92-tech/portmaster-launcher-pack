# INPUT: explicitly enabled isolated test SceneTree and statically bound native Control methods
# OUTPUT: bounded JSON snapshots of visible built-in controls, including scripted wrappers
# POS: isolated observer; optional fixed-file mouse input, never reads editable text
extends Node

const INTERVAL_SECONDS = 3.0
const DEADLINE_MS = 600000
const NODE_LIMIT = 10000
const CONTROL_LIMIT = 160
const PRIORITY_LIMIT = 80
const TEXT_LIMIT = 96
const PATH_LIMIT = 160
const CONTROL_CLASSES = ["Control", "Label", "Button", "TextureButton", "RichTextLabel"]
var _started := false
var _last_control_seq := -1
var _last_control_bytes := PackedByteArray()

# The runner invokes this only after both the opt-in flag and the isolated-root
# identity checks pass. Merely mounting/instantiating is inert.
func start_isolated() -> void:
 if _started or not is_inside_tree():
  return
 _started = true
 _run.call_deferred()
 if OS.get_environment("SLL_UI_CONTROL") == "1" and _control_isolation_valid():
  _control_loop.call_deferred()

func _control_isolation_valid() -> bool:
 if OS.get_environment("SLL_UI_CONTROL") != "1" or OS.get_environment("SLL_UI_DIAG") != "1" or OS.get_environment("SLL_TEXTURE_DIAG") != "1":
  return false
 var test_root := OS.get_environment("SLL_DIAG_XDG_ROOT")
 var pattern := RegEx.new()
 if pattern.compile("^/tmp/sts2-memory-diag-[A-Za-z0-9]+$") != OK or pattern.search(test_root) == null:
  return false
 var data := test_root + "/data"
 var user := data + "/SlayTheSpire2"
 if OS.get_environment("XDG_DATA_HOME").simplify_path() != data or OS.get_user_data_dir().simplify_path() != user or ProjectSettings.globalize_path("user://").simplify_path() != user:
  return false
 var fs := DirAccess.open("/")
 if fs == null or FileAccess.get_unix_permissions(test_root) != 448:
  return false
 for path in [test_root, data, user]:
  if not DirAccess.dir_exists_absolute(path) or fs.is_link(path):
   return false
 return true

func _control_loop() -> void:
 var started := Time.get_ticks_msec()
 while is_inside_tree() and Time.get_ticks_msec() - started < DEADLINE_MS:
  await get_tree().create_timer(0.2, true, false, true).timeout
  if not is_inside_tree() or not _control_isolation_valid():
   return
  await _control_once()

func _control_once() -> void:
 if not _control_isolation_valid():
  return
 var path := OS.get_environment("SLL_DIAG_XDG_ROOT") + "/ui-control.json"
 var fs := DirAccess.open("/")
 if fs == null or fs.is_link(path) or not FileAccess.file_exists(path):
  return
 var file := FileAccess.open(path, FileAccess.READ)
 if file == null or file.get_length() > 512:
  return
 var bytes := file.get_buffer(file.get_length())
 file.close()
 if fs.is_link(path) or not _control_isolation_valid() or bytes == _last_control_bytes:
  return
 _last_control_bytes = bytes
 # A canonical key order excludes duplicate/escaped/unknown keys. Values remain
 # ordinary JSON numbers; the parser and finite/bounds checks reject bad values.
 var json := bytes.get_string_from_utf8()
 var shape := RegEx.new()
 if shape.compile('^\\s*\\{\\s*"seq"\\s*:\\s*[0-9]+\\s*,\\s*"action"\\s*:\\s*"(?:mouse_move|click)"\\s*,\\s*"x"\\s*:\\s*-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\\s*,\\s*"y"\\s*:\\s*-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\\s*\\}\\s*$') != OK or shape.search(json) == null:
  return
 var request: Variant = JSON.parse_string(json)
 if not request is Dictionary or request.size() != 4 or not request.has_all(["seq", "action", "x", "y"]):
  return
 var seq: Variant = request.seq
 if typeof(seq) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(seq) or seq != floor(seq) or seq < 0 or seq > 9007199254740991:
  return
 seq = int(seq)
 var ok := false
 if seq > _last_control_seq:
  _last_control_seq = seq
  var x: Variant = request.x
  var y: Variant = request.y
  var viewport: Window = get_tree().root
  if typeof(x) in [TYPE_INT, TYPE_FLOAT] and typeof(y) in [TYPE_INT, TYPE_FLOAT] and is_finite(x) and is_finite(y) and request.action in ["mouse_move", "click"] and viewport.get_visible_rect().has_point(Vector2(x,y)) and _control_isolation_valid():
   var position: Vector2 = viewport.get_final_transform() * Vector2(x,y)
   var motion := InputEventMouseMotion.new()
   motion.window_id = viewport.get_window_id()
   motion.position = position
   motion.global_position = position
   Input.parse_input_event(motion)
   if request.action == "click":
    var press := InputEventMouseButton.new()
    press.window_id = viewport.get_window_id()
    press.position = position
    press.global_position = position
    press.button_index = MOUSE_BUTTON_LEFT
    press.pressed = true
    press.button_mask = MOUSE_BUTTON_MASK_LEFT
    Input.parse_input_event(press)
    await get_tree().process_frame
    if is_instance_valid(viewport):
     var release := InputEventMouseButton.new()
     release.window_id = viewport.get_window_id()
     release.position = position
     release.global_position = position
     release.button_index = MOUSE_BUTTON_LEFT
     release.pressed = false
     Input.parse_input_event(release)
   ok = true
 print("[UI-CONTROL] ", JSON.stringify({"seq":seq, "ok":ok}))

func _run() -> void:
 var started := Time.get_ticks_msec()
 var sample := 0
 while is_inside_tree() and Time.get_ticks_msec() - started < DEADLINE_MS and sample < 200:
  await get_tree().create_timer(INTERVAL_SECONDS, true, false, true).timeout
  if not is_inside_tree() or Time.get_ticks_msec() - started >= DEADLINE_MS:
   break
  var scan_started := Time.get_ticks_msec()
  var snapshot: Dictionary = await capture(get_tree(), started + DEADLINE_MS)
  if not is_inside_tree():
   return
  if Time.get_ticks_msec() - started >= DEADLINE_MS:
   break
  sample += 1
  snapshot.sample = sample
  snapshot.scan_ms = Time.get_ticks_msec() - scan_started
  snapshot.elapsed_ms = Time.get_ticks_msec() - started
  print("[UI-DIAG] ", JSON.stringify(snapshot))
 queue_free()

func capture(tree: SceneTree, deadline_ms: int = 0) -> Dictionary:
 var root: Window = tree.root
 var report := {"nodes_examined": 0, "controls": [], "scripted_controls": 0,
  "skipped_editable": 0, "skipped_unsupported": 0, "truncated": false, "focus_path": "<unavailable>", "viewport": {}}
 if not is_instance_valid(root) or root.get_script() != null:
  report.truncated = true
  return report
 var viewport: Viewport = root
 var window := root.get_size()
 report.viewport = _viewport_metadata(viewport)
 report.viewport.window_size = [window.x, window.y]
 report.viewport.window_focused = root.has_focus()
 var focus: Control = root.gui_get_focus_owner()
 if _allowed(focus) and focus.is_visible_in_tree():
  report.focus_path = _node_path(focus)
 var focused: Array[Dictionary] = []
 var interactive: Array[Dictionary] = []
 var focused_labels: Array[Dictionary] = []
 var labels: Array[Dictionary] = []
 var other: Array[Dictionary] = []
 var eligible := 0
 var stack: Array[Node] = [root]
 while not stack.is_empty() and report.nodes_examined < NODE_LIMIT:
  if deadline_ms > 0 and Time.get_ticks_msec() >= deadline_ms:
   report.truncated = true
   break
  var node: Node = stack.pop_back()
  if not is_instance_valid(node) or node.is_queued_for_deletion():
   continue
  report.nodes_examined += 1
  for child in node.get_children():
   if child is Node:
    if report.nodes_examined + stack.size() >= NODE_LIMIT:
     report.truncated = true
     break
    stack.append(child)
  if node is Control:
   # All calls below are on explicit native types: GDScript emits MethodBind
   # calls rather than script dispatch. Never use .get(), .call() or properties.
   var control: Control = node
   if control is LineEdit or control is TextEdit:
    report.skipped_editable += 1
   elif node.get_class() not in CONTROL_CLASSES:
    report.skipped_unsupported += 1
   elif control.is_visible_in_tree():
    var rect: Rect2 = control.get_global_rect()
    if is_finite(rect.position.x) and is_finite(rect.position.y) and is_finite(rect.size.x) and is_finite(rect.size.y):
     var has_focus: bool = control.has_focus()
     var focusable: bool = control.get_focus_mode() != Control.FOCUS_NONE
     var scripted: bool = node.get_script() != null
     var local_size: Vector2 = control.get_size()
     var canvas_transform: Transform2D = control.get_global_transform_with_canvas()
     var control_viewport: Viewport = node.get_viewport()
     var record := {"class":node.get_class(), "path":_node_path(node),
      "rect":[rect.position.x,rect.position.y,rect.size.x,rect.size.y],
      "local_size":_vector(local_size), "local_to_viewport":_transform(canvas_transform),
      "root_viewport":control_viewport == root,
      "focused":has_focus, "focusable":focusable, "scripted":scripted, "disabled":null}
     if control is BaseButton:
      var native_button: BaseButton = control
      record.disabled = native_button.is_disabled()
     if control is Button:
      var button: Button = control
      record.text = _safe_text(button.get_text(),TEXT_LIMIT)
     elif control is Label:
      var label: Label = control
      record.text = _safe_text(label.get_text(),TEXT_LIMIT)
     elif control is RichTextLabel:
      var rich: RichTextLabel = control
      record.text = _safe_text(rich.get_parsed_text(),TEXT_LIMIT)
     if scripted: report.scripted_controls += 1
     eligible += 1
     if has_focus:
      if focused.size() < CONTROL_LIMIT: focused.append(record)
     elif control is BaseButton or focusable:
      if interactive.size() < CONTROL_LIMIT: interactive.append(record)
     elif control is Label or control is RichTextLabel:
      if report.focus_path != "<unavailable>" and record.path.begins_with(report.focus_path + "/"):
       if focused_labels.size() < CONTROL_LIMIT: focused_labels.append(record)
      elif labels.size() < CONTROL_LIMIT: labels.append(record)
     elif other.size() < CONTROL_LIMIT:
      other.append(record)
  if report.nodes_examined % 128 == 0:
   await tree.process_frame
 if not stack.is_empty() or eligible > CONTROL_LIMIT:
  report.truncated = true
 # Reserve space for labels even when many focusable controls exist; then fill
 # any remaining slots with the rest. Focused nodes always come first.
 var records: Array = report.controls
 for group in [focused, focused_labels, interactive.slice(0,PRIORITY_LIMIT), labels.slice(0,PRIORITY_LIMIT), interactive.slice(PRIORITY_LIMIT), labels.slice(PRIORITY_LIMIT), other]:
  for record in group:
   if records.size() >= CONTROL_LIMIT:
    break
   records.append(record)
 return report

# Both transforms use column vectors: [x.x, x.y, y.x, y.y, origin.x, origin.y].
# local_to_viewport maps a control point into its viewport; screen_transform maps
# root viewport coordinates into the containing window's screen coordinates.
# A non-root viewport needs its own embedding transform and is explicitly marked.
func _viewport_metadata(viewport: Viewport) -> Dictionary:
 var visible: Rect2 = viewport.get_visible_rect()
 return {"visible_size":_vector(visible.size), "visible_position":_vector(visible.position),
  "mouse_position":_vector(viewport.get_mouse_position()),
  "final_transform":_transform(viewport.get_final_transform()),
  "screen_transform":_transform(viewport.get_screen_transform())}

func _vector(value: Vector2) -> Array:
 return [value.x,value.y] if is_finite(value.x) and is_finite(value.y) else []

func _transform(value: Transform2D) -> Array:
 if not value.is_finite():
  return []
 return [value.x.x,value.x.y,value.y.x,value.y.y,value.origin.x,value.origin.y]

func _allowed(value: Variant) -> bool:
 if not is_instance_valid(value) or not value is Control:
  return false
 var node: Node = value
 var control: Control = value
 return not control is LineEdit and not control is TextEdit and node.get_class() in CONTROL_CLASSES

func _node_path(node: Node) -> String:
 var path := str(node.get_path())
 if not path.begins_with("/root/") or path.contains("user://"):
  return "<redacted>"
 return _safe_text(path,PATH_LIMIT)

func _safe_text(value: String, limit: int) -> String:
 var out := ""
 var n := mini(value.length(),limit)
 for index in n:
  var code := value.unicode_at(index)
  out += " " if code < 32 or (code >= 127 and code <= 159) or code in [0x2028,0x2029] else value.substr(index,1)
 if value.length() > limit:
  out += "…"
 return out
