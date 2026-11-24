#pragma once

#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/helpers/memory/Memory.hpp>
#include <hyprland/src/config/values/types/BoolValue.hpp>
#include <hyprland/src/config/values/types/FloatValue.hpp>

inline HANDLE PHANDLE = nullptr;

struct SGlobalState {
    SP<Config::Values::CBoolValue>  enabled;
    SP<Config::Values::CFloatValue> fade;
};

// Freed in PLUGIN_EXIT. Hyprland calls PLUGIN_EXIT FIRST and only then removes the plugin's hooks and decorations (each decoration removed
// repositions the group and calls the other members' decorations), so everything that can run after it checks this for null.
inline UP<SGlobalState> g_pGlobalState;

// The hook on the border's render step (main.cpp). Owned by Hyprland's hook system, which removes it at unload after PLUGIN_EXIT, so it
// lives outside the state: the hook must always be able to call the original.
class CFunctionHook;
inline CFunctionHook* g_pBorderDrawHook = nullptr;
