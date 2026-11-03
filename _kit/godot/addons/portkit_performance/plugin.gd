# INPUT:  Godot EditorPlugin 与项目 autoload 设置
# OUTPUT: 编辑器插件启停时管理本插件的 autoload
# POS:    为普通 Godot 项目提供可选编辑器安装入口
@tool
extends EditorPlugin

const AUTOLOAD_NAME := "PortKitPerformance"
const AUTOLOAD_PATH := "res://addons/portkit_performance/overlay.tscn"
const OWNER_SETTING := "portkit_performance/editor/owns_autoload"


func _enable_plugin() -> void:
	var key := "autoload/" + AUTOLOAD_NAME
	if not ProjectSettings.has_setting(key):
		add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
		ProjectSettings.set_setting(OWNER_SETTING, true)
		ProjectSettings.save()


func _disable_plugin() -> void:
	var key := "autoload/" + AUTOLOAD_NAME
	if ProjectSettings.get_setting(OWNER_SETTING, false):
		if ProjectSettings.get_setting(key, "") == "*" + AUTOLOAD_PATH:
			remove_autoload_singleton(AUTOLOAD_NAME)
		ProjectSettings.set_setting(OWNER_SETTING, null)
		ProjectSettings.save()
