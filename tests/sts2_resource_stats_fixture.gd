# INPUT: native enum constants and scripted fake objects in an isolated SceneTree
# OUTPUT: safe unavailable results, validated counters and bounded scheduler contract
# POS: headless fixture; no device, game, FMOD or GPU allocation
extends SceneTree
func _initialize() -> void:
 call_deferred("_run")
func _run() -> void:
 if Performance.RENDER_VIDEO_MEM_USED != 14 or Performance.RENDER_TEXTURE_MEM_USED != 15 or Performance.RENDER_BUFFER_MEM_USED != 16 or not Performance.has_method("get_monitor"):
  printerr("Unexpected Performance enum or native API");quit(1);return
 var stats = load("res://port_diagnostics/resource_stats.gd").new()
 var keys: Array = stats.CONFIG_KEYS
 ProjectSettings.set_setting(keys[0],1)
 ProjectSettings.set_setting(keys[1],16)
 ProjectSettings.set_setting(keys[2],16)
 ProjectSettings.set_setting(stats.OVERRIDE_KEY,"")
 var feature := "linux" if OS.has_feature("linux") else "macos"
 if not OS.has_feature(feature): printerr("Missing test platform feature");quit(1);return
 ProjectSettings.set_setting(keys[0]+"."+feature,7)
 OS.set_environment("SLL_MEMORY_TRIAL","worker1")
 var config: Dictionary = stats.startup_config()
 if config.status != "invalid" or config.values[keys[0]] != 7 or "trial_mismatch" not in config.reasons:
  printerr("Feature override ignored ",config);quit(1);return
 ProjectSettings.set_setting(keys[0]+"."+feature,1)
 config = stats.startup_config()
 if config.status != "valid" or config.override_nonempty != false or config.trial != "worker1":
  printerr("Correct trial rejected ",config);quit(1);return
 for mode in ["descriptor16","staging16"]:
  OS.set_environment("SLL_MEMORY_TRIAL",mode)
  if stats.startup_config().status != "valid": printerr("Correct trial rejected ",mode);quit(1);return
 ProjectSettings.set_setting(stats.OVERRIDE_KEY,"user://conflict.cfg")
 config = stats.startup_config()
 if config.status != "invalid" or not config.override_nonempty or "project_override_present" not in config.reasons:
  printerr("Project override not rejected ",config);quit(1);return
 ProjectSettings.set_setting(stats.OVERRIDE_KEY,"")
 OS.set_environment("SLL_MEMORY_TRIAL","")
 if stats.startup_config().status != "baseline": printerr("Baseline rejected");quit(1);return
 OS.set_environment("SLL_MEMORY_TRIAL","unsupported")
 if stats.startup_config().status != "invalid": printerr("Unknown trial accepted");quit(1);return
 OS.set_environment("SLL_MEMORY_TRIAL","")
 var actual: Dictionary = stats.collect()
 var later: Dictionary = stats.collect()
 if typeof(actual.get("ticks_msec")) != TYPE_INT or actual.ticks_msec < 0 or later.ticks_msec < actual.ticks_msec or later.ticks_msec > Time.get_ticks_msec():
  printerr("Invalid monotonic process timestamp");quit(1);return
 if not actual.has("rendering_device") or not actual.has("fmod") or actual.rendering_device.status != "unavailable" or actual.fmod.status != "unavailable":
  printerr("Unexpected headless report ",actual);quit(1);return
 if stats._rd_values(8192,4096,2048) != {"status":"ok","total_allocation_bytes":8192,"textures_bytes":4096,"buffers_bytes":2048} or stats._rd_values(-1,0,0).reason != "invalid_counter" or stats._read_renderer("vulkan",false).reason != "rendering_device_missing":
  printerr("RD counters or missing device invalid");quit(1);return
 if stats._fmod_values(1024,2048) != {"status":"ok","current_bytes":1024,"peak_bytes":2048} or stats._fmod_values(0,0).reason != "zero_unconfirmed" or stats._fmod_values(5,4).reason != "invalid_counter" or stats._fmod_values(1.0,2).reason != "invalid_counter":
  printerr("FMOD counter validation invalid");quit(1);return
 var fake := RefCounted.new()
 var script := GDScript.new()
 script.source_code = "extends RefCounted\n@warning_ignore(\"native_method_override\")\nfunc get_class():\n Engine.set_meta(\"unsafe_getter\",true)\n return \"FmodServer\"\nfunc get_performance_data():\n Engine.set_meta(\"unsafe_getter\",true)\n return self\n"
 if script.reload()!=OK:quit(1);return
 fake.set_script(script)
 var rejected: Dictionary = stats._read_fmod(fake)
 if rejected.reason != "unexpected_singleton_class" or Engine.has_meta("unsafe_getter"):
  printerr("Scripted fake or getter executed");quit(1);return
 var runner = load("res://port_diagnostics/texture_diagnostic_runner.gd").new()
 root.add_child(runner) # Its _ready emits configuration immediately.
 if runner.MAX_SAMPLES != 12 or runner.INTERVAL_SECONDS != 20.0 or runner.MAX_STATS_SAMPLES != 20 or runner.STATS_INTERVAL_SECONDS != 30.0:
  printerr("Scheduler bounds changed");quit(1);return
 runner._stats_done = true
 runner._finish_if_done()
 if runner.is_queued_for_deletion(): printerr("Stats prematurely stopped texture scans");quit(1);return
 runner._texture_done = true
 runner._finish_if_done()
 if not runner.is_queued_for_deletion(): printerr("Runner did not stop when both loops finished");quit(1);return
 print("RESOURCE_STATS_FIXTURE_OK")
 quit(0)
