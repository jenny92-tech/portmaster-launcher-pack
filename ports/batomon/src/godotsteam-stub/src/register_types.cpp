#include "register_types.h"

#include "steam_stub.h"

#include <gdextension_interface.h>

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

static Steam *steam_singleton = nullptr;

void initialize_godotsteam_stub(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }

    GDREGISTER_CLASS(Steam);
    steam_singleton = memnew(Steam);
    Engine::get_singleton()->register_singleton("Steam", steam_singleton);
}

void uninitialize_godotsteam_stub(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }

    Engine::get_singleton()->unregister_singleton("Steam");
    memdelete(steam_singleton);
    steam_singleton = nullptr;
}

extern "C" {
GDExtensionBool GDE_EXPORT godotsteam_init(
        GDExtensionInterfaceGetProcAddress p_get_proc_address,
        GDExtensionClassLibraryPtr p_library,
        GDExtensionInitialization *r_initialization) {
    godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

    init_obj.register_initializer(initialize_godotsteam_stub);
    init_obj.register_terminator(uninitialize_godotsteam_stub);
    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

    return init_obj.init();
}
}
