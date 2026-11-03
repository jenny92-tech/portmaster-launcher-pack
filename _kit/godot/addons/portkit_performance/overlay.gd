# INPUT:  Godot SceneTree、输入动作、时间与性能采集脚本
# OUTPUT: install(tree)、set_enabled(enabled)、toggle()；PortKitPerformance 浮层
# POS:    跨场景、暂停时仍可运行且隐藏时不采样的性能显示
extends CanvasLayer

const Metrics = preload("res://addons/portkit_performance/metrics.gd")
const NODE_NAME := "PortKitPerformance"
const ACTION := "portkit_perf_toggle"

@onready var panel: PanelContainer = $Panel
@onready var label: Label = $Panel/Label

var _enabled := false
var _last_tick := 0
var _elapsed := 0.0
var _frame_us := 0
var _frame_count := 0
var _rss_elapsed := 1.0
var _rss_bytes := -1
var _graphics := ""


static func install(tree: SceneTree) -> Node:
	var existing := tree.root.get_node_or_null(NODE_NAME)
	if existing != null:
		if existing.get_script() == load("res://addons/portkit_performance/overlay.gd"):
			return existing
		push_warning("PortKitPerformance name is already in use; overlay not installed")
		return null
	var scene: PackedScene = load("res://addons/portkit_performance/overlay.tscn")
	var overlay := scene.instantiate()
	overlay.name = NODE_NAME
	tree.root.add_child(overlay)
	return overlay


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_graphics = Metrics.graphics_info()
	get_viewport().size_changed.connect(_fit_panel)
	_fit_panel()
	set_enabled(OS.get_environment("PORTKIT_PERF_OVERLAY") == "1")


func _fit_panel() -> void:
	panel.offset_left = -minf(538.0, maxf(8.0, get_viewport().get_visible_rect().size.x - 8.0))


func set_enabled(enabled: bool) -> void:
	_enabled = enabled
	visible = enabled
	set_process(enabled)
	if enabled:
		_last_tick = Time.get_ticks_usec()
		_elapsed = 0.0
		_frame_us = 0
		_frame_count = 0
		_rss_elapsed = 1.0
		label.text = "Collecting performance...\n" + _graphics


func toggle() -> void:
	set_enabled(not _enabled)


func _input(event: InputEvent) -> void:
	if InputMap.has_action(ACTION) and event.is_action_pressed(ACTION) and not event.is_echo():
		toggle()


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	var interval := maxi(now - _last_tick, 0)
	_last_tick = now
	_frame_us += interval
	_frame_count += 1
	var seconds := interval / 1000000.0
	_elapsed += seconds
	_rss_elapsed += seconds
	if _rss_elapsed >= 1.0:
		_rss_bytes = Metrics.process_rss_bytes()
		_rss_elapsed = 0.0
	if _elapsed >= 0.5:
		var frame_ms := (_frame_us / 1000.0) / _frame_count
		label.text = "FPS %d  Frame %.1f ms\n%s\n%s" % [
			Engine.get_frames_per_second(), frame_ms, Metrics.memory_text(_rss_bytes), _graphics]
		_elapsed = 0.0
		_frame_us = 0
		_frame_count = 0
