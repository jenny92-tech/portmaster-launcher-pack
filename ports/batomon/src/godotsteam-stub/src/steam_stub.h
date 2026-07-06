#ifndef BATOMON_GODOTSTEAM_STUB_STEAM_STUB_H
#define BATOMON_GODOTSTEAM_STUB_STEAM_STUB_H

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/variant.hpp>

class Steam : public godot::Object {
    GDCLASS(Steam, godot::Object);

protected:
    static void _bind_methods();

public:
    Steam() = default;
    ~Steam() = default;

    godot::Variant stub_call(
            const godot::Variant **p_args,
            GDExtensionInt p_arg_count,
            GDExtensionCallError &r_error);

    godot::Dictionary steamInitEx(int p_app_id = 0, bool p_embed_callbacks = false);
    bool steamInit(bool p_embed_callbacks = false);
    void run_callbacks();
    void runCallbacks();
    bool isSteamRunning();
    bool loggedOn();
    uint64_t getSteamID();
    godot::String getPersonaName();
};

#endif
