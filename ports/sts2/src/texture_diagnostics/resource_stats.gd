# INPUT: cached Performance counters and existing FMOD native singleton
# OUTPUT: bounded read-only aggregate allocation statistics in bytes
# POS: explicit independent diagnostic pack; never loads resources or calls FMOD update
extends RefCounted
const TRIAL_SETTINGS = {
 "worker1":["threading/worker_pool/max_threads",1],
 "descriptor16":["rendering/rendering_device/vulkan/max_descriptors_per_pool",16],
 "staging16":["rendering/rendering_device/staging_buffer/max_size_mb",16],
}
const CONFIG_KEYS = ["threading/worker_pool/max_threads", "rendering/rendering_device/vulkan/max_descriptors_per_pool", "rendering/rendering_device/staging_buffer/max_size_mb"]
const OVERRIDE_KEY = "application/config/project_settings_override"

func startup_config() -> Dictionary:
 var values := {}
 for key in CONFIG_KEYS:
  var value: Variant = ProjectSettings.get_setting_with_override(key) if ProjectSettings.has_setting(key) else null
  values[key] = value if typeof(value) == TYPE_INT else null
 var override: Variant = ProjectSettings.get_setting_with_override(OVERRIDE_KEY) if ProjectSettings.has_setting(OVERRIDE_KEY) else null
 var trial := OS.get_environment("SLL_MEMORY_TRIAL")
 var result := _validate_config(trial,values,override)
 result.ticks_msec = Time.get_ticks_msec()
 result.limitations = "Values are read after initialization; they do not independently prove earlier renderer or worker initialization."
 return result

func _validate_config(trial: String, values: Dictionary, override: Variant) -> Dictionary:
 var result := {"trial":trial if trial in TRIAL_SETTINGS else ("baseline" if trial == "" else "unknown"), "values":values, "override_nonempty":null, "status":"invalid", "reasons":[]}
 if typeof(override) != TYPE_STRING:
  result.reasons.append("override_unavailable")
 else:
  result.override_nonempty = not override.is_empty()
  if result.override_nonempty: result.reasons.append("project_override_present")
 for key in CONFIG_KEYS:
  if typeof(values.get(key)) != TYPE_INT:
   result.reasons.append("setting_unavailable")
   break
 if trial != "" and trial not in TRIAL_SETTINGS:
  result.reasons.append("unknown_trial")
 elif trial in TRIAL_SETTINGS:
  var expected: Array = TRIAL_SETTINGS[trial]
  if values.get(expected[0]) != expected[1]: result.reasons.append("trial_mismatch")
 if result.reasons.is_empty(): result.status = "baseline" if trial == "" else "valid"
 return result

func collect() -> Dictionary:
 var renderer := _read_renderer(RenderingServer.get_current_rendering_driver_name(), RenderingServer.get_rendering_device() != null)
 var fmod := {"status":"unavailable", "reason":"singleton_missing"}
 if Engine.has_singleton("FmodServer"):
  var server: Object = Engine.get_singleton("FmodServer")
  fmod = _read_fmod(server)
 return {"ticks_msec":Time.get_ticks_msec(),"rendering_device":renderer,"fmod":fmod,
  "limitations":"Cached Vulkan total is VMA allocationBytes, not blockBytes, resident bytes or RSS; texture/buffer counters and total must not be subtracted to infer ownership. FMOD values may overlap process memory."}

func _read_renderer(driver: String, has_device: bool) -> Dictionary:
 if driver != "vulkan": return {"status":"unavailable", "reason":"non_vulkan"}
 if not has_device: return {"status":"unavailable", "reason":"rendering_device_missing"}
 var total: float = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)
 var textures: float = Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)
 var buffers: float = Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED)
 return _rd_values(total,textures,buffers)

func _rd_values(total: float, textures: float, buffers: float) -> Dictionary:
 if not is_finite(total) or not is_finite(textures) or not is_finite(buffers) or total < 0 or textures < 0 or buffers < 0 or maxf(total,maxf(textures,buffers)) > 9007199254740991.0:
  return {"status":"unavailable", "reason":"invalid_counter"}
 if total == 0:
  return {"status":"unavailable", "reason":"zero_unconfirmed"}
 return {"status":"ok", "total_allocation_bytes":int(total), "textures_bytes":int(textures), "buffers_bytes":int(buffers)}

func _read_fmod(server: Object) -> Dictionary:
 if not is_instance_valid(server): return {"status":"unavailable", "reason":"singleton_missing"}
 if server.get_class() != "FmodServer" or server.get_script() != null:
  return {"status":"unavailable", "reason":"unexpected_singleton_class"}
 if not ClassDB.class_exists("FmodServer") or not ClassDB.class_has_method("FmodServer","get_performance_data"):
  return {"status":"unavailable", "reason":"native_method_missing"}
 var performance: Variant = server.call("get_performance_data")
 if not performance is Object or not is_instance_valid(performance):
  return {"status":"unavailable", "reason":"performance_missing"}
 var native: Object = performance
 if native.get_class() != "FmodPerformanceData" or native.get_script() != null:
  return {"status":"unavailable", "reason":"unexpected_performance_class"}
 if not ClassDB.class_exists("FmodPerformanceData") or not ClassDB.class_has_method("FmodPerformanceData","get_currently_allocated") or not ClassDB.class_has_method("FmodPerformanceData","get_max_allocated"):
  return {"status":"unavailable", "reason":"native_method_missing"}
 return _fmod_values(native.call("get_currently_allocated"),native.call("get_max_allocated"))

func _fmod_values(current: Variant, peak: Variant) -> Dictionary:
 if typeof(current) != TYPE_INT or typeof(peak) != TYPE_INT or current < 0 or peak < current:
  return {"status":"unavailable", "reason":"invalid_counter"}
 if current == 0:
  return {"status":"unavailable", "reason":"zero_unconfirmed"}
 return {"status":"ok", "current_bytes":current, "peak_bytes":peak}
