# INPUT:  Godot Performance、RenderingServer、OS；Linux/Android 的 /proc/self/status
# OUTPUT: 图形设备信息、引擎与纹理统计和当前进程 RSS
# POS:    性能浮层的低频指标采集
extends RefCounted

const MIB := 1048576.0
const STATUS_LIMIT := 65536


static func graphics_info() -> String:
	var parts: Array[String] = []
	for method in ["get_current_rendering_method", "get_current_rendering_driver_name", "get_video_adapter_name"]:
		var value := ""
		if RenderingServer.has_method(method):
			value = str(RenderingServer.call(method)).strip_edges()
		parts.append(value if not value.is_empty() else "N/A")
	# Long GPU names must not push the overlay outside a small viewport.
	if parts[2].length() > 28:
		parts[2] = parts[2].substr(0, 25) + "..."
	return "%s / %s\n%s" % parts


static func memory_text(rss_bytes: int) -> String:
	# MEMORY_STATIC is documented as debug-only; a release zero is not a measurement.
	var engine := "N/A"
	if OS.is_debug_build():
		engine = "%.1f" % (Performance.get_monitor(Performance.MEMORY_STATIC) / MIB)
	var texture := Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / MIB
	var rss := "N/A" if rss_bytes < 0 else "%.1f" % (rss_bytes / MIB)
	return "RSS %s  Engine %s MiB\nTEX %.1f MiB (estimate)" % [rss, engine, texture]


static func process_rss_bytes() -> int:
	if OS.get_name() not in ["Linux", "Android"]:
		return -1
	var file := FileAccess.open("/proc/self/status", FileAccess.READ)
	if file == null:
		return -1
	# A single bounded read; no other process or file is inspected.
	var content := file.get_buffer(STATUS_LIMIT).get_string_from_utf8()
	for line in content.split("\n"):
		if line.begins_with("VmRSS:"):
			var value := line.trim_prefix("VmRSS:").strip_edges().split(" ", false)
			if value.size() == 2 and value[0].is_valid_int() and value[1] == "kB":
				return int(value[0]) * 1024
	return -1
