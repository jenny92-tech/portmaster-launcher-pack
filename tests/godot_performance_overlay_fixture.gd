# INPUT:  Shared overlay, Godot SceneTree and synthetic host input
# OUTPUT: Lifecycle, paused sampling, input propagation, layout and memory assertions
# POS:    Standalone headless fixture with no game resources or device access
extends SceneTree

const Overlay = preload("res://addons/portkit_performance/overlay.gd")
const Metrics = preload("res://addons/portkit_performance/metrics.gd")
const ACTION = "portkit_perf_toggle"
var failures := 0

class InputObserver extends Node:
    var received := false
    func _input(event: InputEvent) -> void:
        if event.is_action_pressed("portkit_perf_toggle"):
            received = true

func check(value: bool, message: String) -> void:
    if not value:
        failures += 1
        printerr("FAIL: ", message)

func _initialize() -> void:
    run.call_deferred()

func run() -> void:
    check(not InputMap.has_action(ACTION), "fixture starts without host mapping")
    var overlay = Overlay.install(self)
    check(overlay != null and Overlay.install(self) == overlay, "install is idempotent")
    check(not InputMap.has_action(ACTION), "install leaves InputMap unchanged")
    var enabled_by_env = OS.get_environment("PORTKIT_PERF_OVERLAY") == "1"
    check(overlay.visible == enabled_by_env and overlay.is_processing() == enabled_by_env, "environment controls initial visibility and sampling")
    overlay.set_enabled(false)
    var frames = overlay._frame_count
    await process_frame
    await process_frame
    check(not overlay.visible and not overlay.is_processing() and overlay._frame_count == frames, "disabled overlay does not sample")
    overlay.set_enabled(true)
    paused = true
    await create_timer(0.65, true).timeout
    check(overlay.is_processing() and overlay.visible and overlay.label.text.contains("FPS "), "sampling continues while paused")
    paused = false
    overlay.set_enabled(false)
    var before = overlay.visible
    var unmapped = InputEventAction.new()
    unmapped.action = ACTION
    unmapped.pressed = true
    Input.parse_input_event(unmapped)
    await process_frame
    check(overlay.visible == before and not InputMap.has_action(ACTION), "unmapped action is ignored")
    InputMap.add_action(ACTION)
    var observer = InputObserver.new()
    root.add_child(observer)
    var action = InputEventAction.new()
    action.action = ACTION
    action.pressed = true
    Input.parse_input_event(action)
    await process_frame
    check(overlay.visible and observer.received, "host mapped action toggles without consuming input")
    check(InputMap.has_action(ACTION) and InputMap.action_get_events(ACTION).is_empty(), "host mapping remains unchanged")
    check(overlay.panel.mouse_filter == Control.MOUSE_FILTER_IGNORE and overlay.label.mouse_filter == Control.MOUSE_FILTER_IGNORE, "overlay allows pointer input through")
    for dimensions in [Vector2i(640, 480), Vector2i(1280, 720)]:
        root.size = dimensions
        await process_frame
        var rect: Rect2 = overlay.panel.get_global_rect()
        check(rect.position.x >= 0 and rect.position.y >= 0 and rect.end.x <= dimensions.x and rect.end.y <= dimensions.y, "panel fits %s: %s" % [dimensions, rect])
    var unavailable = Metrics.memory_text(-1)
    check(unavailable.contains("RSS N/A") and unavailable.contains("MiB"), "unsupported RSS has explicit unavailable state and units")
    check(Metrics.memory_text(1048576).contains("RSS 1.0"), "RSS conversion uses MiB")
    if OS.get_name() not in ["Linux", "Android"]:
        check(Metrics.process_rss_bytes() == -1, "unsupported platform does not invent RSS")
    observer.queue_free()
    overlay.queue_free()
    await process_frame
    check(root.get_node_or_null("PortKitPerformance") == null, "overlay can be freed")
    InputMap.erase_action(ACTION)
    if failures == 0:
        print("PERFORMANCE_OVERLAY_OK")
    quit(1 if failures else 0)
