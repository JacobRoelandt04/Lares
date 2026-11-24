#define WLR_USE_UNSTABLE

#include <algorithm>
#include <stdexcept>

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/window/Window.hpp>
#include <hyprland/src/desktop/view/window/WindowPresentation.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/plugins/HookSystem.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/pass/BorderPassElement.hpp>

#include "globals.hpp"
#include "tabDeco.hpp"

extern "C" {
#include <lua.h>
}

#define GROUP_TABS_VERSION "0.3.1"

// Do NOT change this function.
APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

static void onNewWindow(PHLWINDOW window) {
    if (std::ranges::any_of(window->presentation().decorations(), [](const auto& d) { return d->getDisplayName() == "GroupTabs"; }))
        return;

    HyprlandAPI::addWindowDecoration(PHANDLE, window, makeShared<CGroupTabs>(window));
}

// hl.plugin.group_tabs.version(): exists only while the plugin is loaded, so a Lua config can ask
// `if hl.plugin.group_tabs then ... end` (and keep the vanilla groupbar when it is not).
static int luaVersion(lua_State* L) {
    lua_pushstring(L, GROUP_TABS_VERSION);
    return 1;
}

// The border's render step, Render::GL::CGLElementRenderer::draw(ctx, WP<CBorderPassElement>, damage). A grouped window's border is drawn
// here with its tab segment (drawGroupBorder); every other border, and every border once the plugin is gone, goes to the original.
typedef void (*origBorderDraw)(void*, Render::CRenderContext&, WP<CBorderPassElement>, const CRegion&);
static void hkBorderDraw(void* thisptr, Render::CRenderContext& ctx, WP<CBorderPassElement> element, const CRegion& damage) {
    if (element && drawGroupBorder(ctx, element->m_data))
        return;
    ((origBorderDraw)g_pBorderDrawHook->m_original)(thisptr, ctx, element, damage);
}

static void fail(const std::string& why) {
    HyprlandAPI::addNotification(PHANDLE, "[hypr-group-tabs] " + why, CHyprColor{1.0, 0.2, 0.2, 1.0}, 5000);
    throw std::runtime_error("[hypr-group-tabs] " + why);
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    PHANDLE = handle;

    const std::string HASH        = __hyprland_api_get_hash();
    const std::string CLIENT_HASH = __hyprland_api_get_client_hash();

    if (HASH != CLIENT_HASH)
        fail("Version mismatch (headers are not the running Hyprland)");

    // The hook first: a Hyprland whose border render step moved or changed its signature refuses the plugin here, before anything is
    // registered, and the vanilla groupbar stays (the config guard in CHEATSHEET.md).
    void* target = nullptr;
    for (const auto& fn : HyprlandAPI::findFunctionsByName(PHANDLE, "draw")) {
        if (fn.demangled.contains("CGLElementRenderer::draw") && fn.demangled.contains("CBorderPassElement")) {
            target = fn.address;
            break;
        }
    }
    if (!target)
        fail("Render::GL::CGLElementRenderer::draw(..., CBorderPassElement, ...) not found in this Hyprland");
    g_pBorderDrawHook = HyprlandAPI::createFunctionHook(PHANDLE, target, (void*)&hkBorderDraw);
    if (!g_pBorderDrawHook || !g_pBorderDrawHook->hook())
        fail("could not hook the border's render step");

    g_pGlobalState          = makeUnique<SGlobalState>();
    // `enabled` asks Hyprland for a window refresh when it changes, so every window's decoration hears it at once (the forced border comes and
    // goes with it, and the band's input with the tabs)
    g_pGlobalState->enabled = makeShared<Config::Values::CBoolValue>("plugin:group_tabs:enabled", "Draw the group's tabs on the window border", true,
                                                                     Config::Values::SBoolValueOptions{.refresh = Config::Supplementary::REFRESH_WINDOW_STATES});
    g_pGlobalState->fade    = makeShared<Config::Values::CFloatValue>(
        "plugin:group_tabs:fade", "Share of the selected tab's segment, from each end, over which it runs from the border colour to the tab colour (0.5 = a peak in the middle, 0 = flat)", 0.5F);
    HyprlandAPI::addConfigValueV2(PHANDLE, g_pGlobalState->enabled);
    HyprlandAPI::addConfigValueV2(PHANDLE, g_pGlobalState->fade);

    HyprlandAPI::addLuaFunction(PHANDLE, "group_tabs", "version", ::luaVersion);

    static auto P = Event::bus()->m_events.window.open.listen([&](PHLWINDOW w) { onNewWindow(w); });

    // every mapped window, the hidden members of a group too: each shows its own tabs when its turn comes
    for (auto& w : Desktop::windowState()->windows()) {
        if (validMapped(w))
            onNewWindow(w);
    }

    HyprlandAPI::reloadConfig();

    return {"hypr-group-tabs", "Group tabs drawn as part of the window border, reserving no space.", "Jacob Roelandt", GROUP_TABS_VERSION};
}

APICALL EXPORT void PLUGIN_EXIT() {
    g_pGlobalState.reset();

    // Every forced border goes back to its rule now, through the decoration's own path, while everything is in place: with the state gone
    // no window is eligible. (The decorations are removed after this returns; their destructors find nothing left to give back.)
    const std::vector<PHLWINDOW> WINDOWS = Desktop::windowState()->windows();
    for (const auto& w : WINDOWS) {
        if (!validMapped(w))
            continue;
        const std::vector<SP<IHyprWindowDecoration>> DECOS{w->presentation().decorations().begin(), w->presentation().decorations().end()};
        for (const auto& d : DECOS) {
            if (d->getDisplayName() == "GroupTabs")
                d->updateWindow(w);
        }
    }
}
