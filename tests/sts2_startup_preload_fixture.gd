# INPUT:  synthetic manifest, PackedScene resources and startup preloader
# OUTPUT: verifies success, failure, duplicate, timeout and tree cleanup
# POS:    headless standalone fixture; never instantiates a game scene
extends SceneTree
const Preloader = preload("res://port_compat/startup_effect_preload.gd")
var count := 0
var last := false
func _initialize() -> void:
    run.call_deferred()
func completed(success: bool) -> void:
    count += 1
    last = success
func fail(message: String) -> void:
    printerr("FAIL: ", message)
    quit(1)
func run() -> void:
    var mode = OS.get_environment("PRELOAD_TEST_MODE")
    var path = "res://scenes/vfx/test.tscn"
    var entries = [{"path": path}, {"path": "res://scenes/vfx/test2.tscn"}]
    if mode == "duplicate":
        entries = [{"path": path}, {"path": path}]
    if mode == "missing":
        entries = [{"path": path}, {"path": "res://scenes/vfx/missing.tscn"}]
    var manifest = FileAccess.open("res://port_compat/simple_effects_manifest.json", FileAccess.WRITE)
    manifest.store_string(JSON.stringify({"scenes": entries}))
    manifest.close()
    var preloader = Preloader.new()
    root.add_child(preloader)
    preloader.finished.connect(completed)
    preloader.prepare()
    preloader.prepare()
    while preloader._scenes.is_empty() and not preloader.is_done():
        await process_frame
    if mode == "timeout":
        OS.delay_msec(5100)
    elif mode == "cleanup":
        root.remove_child(preloader)
        if not preloader._scenes.is_empty():
            fail("tree exit did not clear cached scenes")
            return
        preloader.free()
        await process_frame
        if count != 0:
            fail("cancelled preload emitted completion")
            return
        print("STARTUP_PRELOAD_OK")
        quit()
        return
    while not preloader.is_done():
        await process_frame
    var expected = mode == "success"
    if count != 1 or last != expected or preloader.succeeded() != expected:
        fail("incorrect terminal status or signal")
        return
    if preloader._scenes.size() != (2 if expected else 0):
        fail("incorrect retained scene cache")
        return
    preloader.prepare()
    await process_frame
    if count != 1:
        fail("repeated prepare emitted another signal")
        return
    preloader.queue_free()
    await process_frame
    print("STARTUP_PRELOAD_OK")
    quit()
