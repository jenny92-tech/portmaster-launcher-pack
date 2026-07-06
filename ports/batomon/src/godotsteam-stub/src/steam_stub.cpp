#include "steam_stub.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/method_bind.hpp>
#include <godot_cpp/variant/string.hpp>

using namespace godot;

namespace {

Variant default_return_for(const StringName &p_method) {
    const String method = String(p_method);

    if (method.begins_with("is") || method.begins_with("has") || method.begins_with("was") ||
            method.begins_with("can") || method.begins_with("did") || method == "loggedOn" ||
            method == "steamInit" || method == "restartAppIfNecessary") {
        return false;
    }

    if (method.begins_with("get") || method.begins_with("create") || method.begins_with("find") ||
            method.begins_with("request") || method.begins_with("send") || method.begins_with("upload") ||
            method.begins_with("download")) {
        return 0;
    }

    return Variant();
}

void bind_stub_method(const char *p_name) {
    MethodInfo method_info;
    method_info.name = p_name;
    ClassDB::bind_vararg_method(METHOD_FLAGS_DEFAULT, p_name, &Steam::stub_call, method_info);
}

} // namespace

Variant Steam::stub_call(const Variant **p_args, GDExtensionInt p_arg_count, GDExtensionCallError &r_error) {
    (void)p_args;
    (void)p_arg_count;
    r_error.error = GDEXTENSION_CALL_OK;
    static thread_local StringName last_method;
    if (p_arg_count > 0 && p_args != nullptr && p_args[0] != nullptr) {
        StringName name = *p_args[0];
        if (name != StringName()) {
            last_method = name;
        }
    }
    return Variant();
}

Dictionary Steam::steamInitEx(int p_app_id, bool p_embed_callbacks) {
    (void)p_app_id;
    (void)p_embed_callbacks;
    Dictionary result;
    result["status"] = 1;  // k_ESteamAPIInitResult_OK
    result["verbal"] = "Steam connected (PortMaster offline mode)";
    return result;
}

bool Steam::steamInit(bool p_embed_callbacks) {
    (void)p_embed_callbacks;
    return true;
}

void Steam::run_callbacks() {}

void Steam::runCallbacks() {}

bool Steam::isSteamRunning() {
    return true;
}

bool Steam::loggedOn() {
    return true;
}

uint64_t Steam::getSteamID() {
    return 76561198000000001ULL;
}

String Steam::getPersonaName() {
    return "Player";
}

void Steam::_bind_methods() {
    ClassDB::bind_method(D_METHOD("steamInitEx", "app_id", "embed_callbacks"), &Steam::steamInitEx, DEFVAL(0), DEFVAL(false));
    ClassDB::bind_method(D_METHOD("steamInit", "embed_callbacks"), &Steam::steamInit, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("run_callbacks"), &Steam::run_callbacks);
    ClassDB::bind_method(D_METHOD("runCallbacks"), &Steam::runCallbacks);
    ClassDB::bind_method(D_METHOD("isSteamRunning"), &Steam::isSteamRunning);
    ClassDB::bind_method(D_METHOD("loggedOn"), &Steam::loggedOn);
    ClassDB::bind_method(D_METHOD("getSteamID"), &Steam::getSteamID);
    ClassDB::bind_method(D_METHOD("getPersonaName"), &Steam::getPersonaName);

    // Additional GodotSteam methods and constants are generated into this include
    // from GodotSteam's doc_classes/Steam.xml by build-godotsteam-stub.sh.
#include "steam_stub_bindings.gen.inc"
}
