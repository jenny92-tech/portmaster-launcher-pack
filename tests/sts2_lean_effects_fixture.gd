# INPUT:  lightweight effect script, synthetic roots and a timer-owned healing root
# OUTPUT: verifies green flash cleanup, root lifetime and retained healing timer
# POS:    no game content, GPU particles or live actors are needed
extends SceneTree

class TimedRoot extends Node2D:
    func _ready() -> void:
        var timer = Timer.new()
        timer.one_shot = true
        timer.wait_time = 0.8
        timer.timeout.connect(queue_free)
        add_child(timer)
        timer.start()

func _initialize() -> void:
    run.call_deferred()

func make_flash(parent: Node2D, green: bool, free_root: bool) -> Polygon2D:
    var flash = Polygon2D.new()
    flash.name = "PortSimpleEffect"
    flash.color = Color(0.31, 1, 0.46, 1) if green else Color.WHITE
    flash.polygon = PackedVector2Array([Vector2(-4, -4), Vector2(4, -4), Vector2(0, 4)])
    flash.set_script(load("res://port_compat/simple_effect.gd"))
    flash.set("free_root_on_finish", free_root)
    parent.add_child(flash)
    return flash

func run() -> void:
    var roots = []
    for green in [false, false, true]:
        var effect_root = Node2D.new()
        make_flash(effect_root, green, true)
        roots.append(effect_root)
        root.add_child(effect_root)
    var heal = TimedRoot.new()
    var heal_flash = make_flash(heal, true, false)
    root.add_child(heal)
    await create_timer(0.4).timeout
    for effect_root in roots:
        if is_instance_valid(effect_root):
            printerr("simple effect root was not freed")
            quit(1)
            return
    if not is_instance_valid(heal) or is_instance_valid(heal_flash):
        printerr("healing flash must release itself while leaving its timed root alive")
        quit(1)
        return
    await create_timer(0.7).timeout
    if is_instance_valid(heal):
        printerr("healing timer did not free its root")
        quit(1)
        return
    print("STS2_LEAN_EFFECT_OK")
    quit()
