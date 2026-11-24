#include "tabDeco.hpp"

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/config/ConfigValue.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/types/OverridableVar.hpp>
#include <hyprland/src/desktop/view/Group.hpp>
#include <hyprland/src/desktop/view/window/Window.hpp>
#include <hyprland/src/desktop/view/window/WindowGroupMembership.hpp>
#include <hyprland/src/desktop/view/window/WindowPresentation.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/layout/supplementary/DragController.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/render/Context.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/WindowRenderPresentation.hpp>

#include <linux/input-event-codes.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <numbers>

#include "globals.hpp"

using namespace Render;

CGroupTabs::CGroupTabs(PHLWINDOW pWindow) : IHyprWindowDecoration(pWindow), m_window(pWindow) {
    ;
}

CGroupTabs::~CGroupTabs() {
    // A forced border still out when the decoration goes (PLUGIN_EXIT gives them all back first, through syncForcedBorder): the property
    // only. This runs inside Hyprland erasing the window's decoration list, so nothing here may walk it; Hyprland measures the window's
    // decorations again right after the erase.
    const auto W = m_window.lock();
    if (giveBackForcedBorder() && W)
        W->presentation().invalidateBorderSize();
}

// ---------------------------------------------------------------------------------------------------------------------------------------
// Which windows, and the pointer on the band

static int borderSizeOf(const PHLWINDOW& W) {
    static auto PBORDERSIZE = CConfigValue<Config::INTEGER>("general:border_size");
    return W->m_ruleApplicator->borderSize().valueOr(*PBORDERSIZE);
}

bool CGroupTabs::eligible() {
    static auto PDISABLEWHENONLY = CConfigValue<Config::BOOL>("group:groupbar:disable_when_only");

    const auto  W = m_window.lock();
    // After PLUGIN_EXIT the state is gone while Hyprland still calls the decorations it is removing (see globals.hpp).
    if (!W || !g_pGlobalState || !g_pGlobalState->enabled->value())
        return false;

    const auto GROUP = W->grouping().group();
    if (!GROUP || GROUP->windows().empty())
        return false;

    if (*PDISABLEWHENONLY && GROUP->windows().size() < 2)
        return false;

    // The switches of the border it is part of that are not its width: no decorations at all (a `decorate = false` rule), or an X11 window's
    // own no-border hint. The border decoration draws nothing for either whatever the width says, so neither is forced.
    if (!W->m_ruleApplicator->decorate().valueOrDefault() || W->backend().traits().suggestsNoBorder)
        return false;

    return true;
}

bool CGroupTabs::wanted() {
    const auto W = m_window.lock();
    if (!W || !eligible() || borderSizeOf(W) <= 0)
        return false;
    if (Fullscreen::controller()->getFullscreenModes(W).internal == Fullscreen::FSMODE_FULLSCREEN)
        return false;

    return true;
}

// ---------------------------------------------------------------------------------------------------------------------------------------
// The forced border

using Desktop::Types::PRIORITY_SET_PROP;
using BorderVar = Desktop::Types::COverridableVar<Config::INTEGER>;

static bool slotHolds(const BorderVar& v, Config::INTEGER x) {
    return v.hasValue() && v.getPriority() == PRIORITY_SET_PROP && v.value() == x;
}

// The set-prop slot back to what it held before the plugin wrote it. Writes the property only; true when it did (the window's border width
// changed). A `hyprctl setprop border_size` written since owns the slot and is left alone.
bool CGroupTabs::giveBackForcedBorder() {
#ifdef GROUP_TABS_ARM_NO_RELEASE // the ARM build of test.sh: a forced border is never given back
    return false;
#endif
    if (!m_forced.active)
        return false;

    const auto FORCED = m_forced;
    m_forced          = {};

    const auto W = m_window.lock();
    if (!W || !W->m_ruleApplicator)
        return false;

    auto& var = W->m_ruleApplicator->borderSize();
    if (!slotHolds(var, FORCED.value))
        return false;

    if (FORCED.previous)
        var.set(*FORCED.previous, PRIORITY_SET_PROP);
    else
        var.unset(PRIORITY_SET_PROP);
    return true;
}

// The border a window in a group gets when a rule leaves it none: written while the tabs are eligible and the window's own width (its
// property without this write) is 0, given back as soon as either stops. Called from updateWindow, which Hyprland calls on every change
// that matters here: a window joining or leaving a group (before it is unmapped too), its rules re-applied, a config change (the plugin's
// `enabled` asks for a window refresh), and from PLUGIN_EXIT.
void CGroupTabs::syncForcedBorder() {
    static auto PBORDERSIZE = CConfigValue<Config::INTEGER>("general:border_size");

    const auto  W = m_window.lock();
    if (!W || !W->m_ruleApplicator)
        return;

    auto& var = W->m_ruleApplicator->borderSize();
    if (m_forced.active && !slotHolds(var, m_forced.value))
        m_forced = {}; // a setprop took the slot since: it is the user's (and forced over below only if it says 0)

    BorderVar without = var;
    if (m_forced.active) {
        if (m_forced.previous)
            without.set(*m_forced.previous, PRIORITY_SET_PROP);
        else
            without.unset(PRIORITY_SET_PROP);
    }

    Config::INTEGER target = 0;
#ifndef GROUP_TABS_ARM_NO_FORCE // the ARM build of test.sh: a borderless window stays borderless in a group
    if (eligible() && without.valueOr(*PBORDERSIZE) <= 0)
        target = std::max<Config::INTEGER>(*PBORDERSIZE, 0);
#endif
    if (target == (m_forced.active ? m_forced.value : 0))
        return;

    // the extents before the change: a border taken off a floating window leaves its ring outside the window's own box
    g_pHyprRenderer->damageWindow(W);

    giveBackForcedBorder();
    if (target > 0) {
        m_forced.previous = var.hasValue() && var.getPriority() == PRIORITY_SET_PROP ? std::optional{var.value()} : std::nullopt;
        var.set(target, PRIORITY_SET_PROP);
        m_forced.active = true;
        m_forced.value  = target;
    }

    // Hyprland's own path for a border width that changed (setprop): the border measures its width again, the positioner every decoration,
    // and the layout places the window again when what they reserve changed (a tiled member: its siblings' size)
    W->presentation().invalidateBorderSize();
    g_pDecorationPositioner->forceRecalcFor(W);
    g_pDecorationPositioner->onWindowUpdate(W);
    g_pHyprRenderer->damageWindow(W);
}

// The pointer's band: the border's top rows, in logical px. 0 when the window has no tabs, so the positioner gives the decoration no box
// and the window's input is the vanilla one.
int CGroupTabs::bandHeight() {
    const auto W = m_window.lock();
    return W && wanted() ? borderSizeOf(W) : 0;
}

SDecorationPositioningInfo CGroupTabs::getPositioningInfo() {
    // STICKY on the top edge and above the border (priority 10000) in the order, so it is placed first, right on the window's top edge:
    // its box is the border's top band. NON_SOLID (getDecorationFlags), so the border is not pushed outward by it; not reserved, so the
    // layout gives the window the geometry of an ungrouped one.
    SDecorationPositioningInfo info;
    info.policy         = DECORATION_POSITION_STICKY;
    info.edges          = DECORATION_EDGE_TOP;
    info.priority       = 10001;
    info.reserved       = false;
    m_reportedBand      = bandHeight();
    info.desiredExtents = {{0.0, (double)m_reportedBand}, {0.0, 0.0}};
    return info;
}

void CGroupTabs::onPositioningReply(const SDecorationPositioningReply&) {
    ;
}

eDecorationType CGroupTabs::getDecorationType() {
    return DECORATION_CUSTOM;
}

eDecorationLayer CGroupTabs::getDecorationLayer() {
    return DECORATION_LAYER_OVER;
}

uint64_t CGroupTabs::getDecorationFlags() {
    return DECORATION_ALLOWS_MOUSE_INPUT | DECORATION_NON_SOLID;
}

std::string CGroupTabs::getDisplayName() {
    return "GroupTabs";
}

void CGroupTabs::draw(CRenderContext&, PHLMONITOR, const float&, const SWindowRenderPresentation&) {
    // nothing: the tabs are part of the border's own draw (drawGroupBorder)
}

void CGroupTabs::updateWindow(PHLWINDOW) {
    syncForcedBorder();

    // A window that joins or leaves a group is recalculated by Hyprland (addDecoration / removeDecoration of the vanilla groupbar force a
    // recalc of every decoration's positioning info); a band that changed for another reason (the plugin switched off, the border width
    // changed by a rule) is handed over here.
    if (bandHeight() != m_reportedBand)
        g_pDecorationPositioner->repositionDeco(this);
    damageEntire();
}

void CGroupTabs::onWindowFocus() {
    damageEntire();
}

void CGroupTabs::damageEntire() {
    if (!wanted())
        return;

    const auto W = m_window.lock();
    if (!W)
        return;

    const int  BORDER = borderSizeOf(W);
    const auto PRES   = W->presentation().renderPresentation();
    CBox       wb     = W->getWindowMainSurfaceBox();
    wb.translate(PRES.workspaceOffset);

    // the band above the window, padded for the device rounding
    CBox box = {wb.x - BORDER - 3, wb.y - BORDER - 3, wb.w + 2.0 * (BORDER + 3), BORDER + 6.0};
    box.translate(PRES.floatingOffset);
    g_pHyprRenderer->damageBox(box);
}

// The tab under `pos` (layout px): the band's columns along the straight part of the top edge, cut in N equal shares, as they are drawn.
std::optional<size_t> CGroupTabs::tabAt(const Vector2D& pos) {
    const auto W = m_window.lock();
    if (!W || !wanted())
        return std::nullopt;

    const auto GROUP = W->grouping().group();
    const auto N     = GROUP->windows().size();
    const CBox WB    = W->getWindowMainSurfaceBox();
    const int  B     = borderSizeOf(W);
    if (pos.y < WB.y - B || pos.y >= WB.y)
        return std::nullopt;

    const double R    = W->presentation().rounding();
    const double LEFT = WB.x + R, WIDTH = WB.w - 2 * R;
    if (WIDTH <= 0 || pos.x < LEFT || pos.x >= LEFT + WIDTH)
        return std::nullopt;

    return std::clamp<size_t>((size_t)std::floor((pos.x - LEFT) * N / WIDTH), 0, N - 1);
}

bool CGroupTabs::onInputOnDeco(const eInputType type, const Vector2D& pos, std::any data) {
    switch (type) {
        case INPUT_TYPE_DRAG_START: return onDragStart(pos);
        case INPUT_TYPE_BUTTON: return onButton(pos, std::any_cast<const IPointer::SButtonEvent&>(data));
        default: return false;
    }
}

// The move bind pressed on a tab: that tab's window leaves the group and is dragged, as on the vanilla groupbar
// (CHyprGroupBarDecoration::onBeginWindowDragOnDeco). A group of one, or a press off the tabs (the corners), moves the whole window.
bool CGroupTabs::onDragStart(const Vector2D& pos) {
    const auto W   = m_window.lock();
    const auto IDX = tabAt(pos);
    if (!W || !IDX)
        return false;

    const auto GROUP = W->grouping().group();
    if (!GROUP || GROUP->size() < 2)
        return false;

    const PHLWINDOW pWindow = GROUP->fromIndex(*IDX);
    if (!pWindow)
        return false;

    GROUP->remove(pWindow);

    g_layoutManager->dragController()->dragBegin(pWindow->layoutTarget(), MBIND_MOVE);

    if (!Desktop::focusState()->isWindowActive(pWindow))
        Desktop::focusState()->rawWindowFocus(pWindow, Desktop::FOCUS_REASON_CLICK);

    return true;
}

// A left click on a tab selects it (CHyprGroupBarDecoration::onMouseButtonOnDeco, without its middle-click close: on a band three pixels
// tall a stray middle click would close a window).
bool CGroupTabs::onButton(const Vector2D& pos, const IPointer::SButtonEvent& e) {
    static auto PFOLLOWMOUSE = CConfigValue<Config::INTEGER>("input:follow_mouse");

    const auto W   = m_window.lock();
    const auto IDX = e.button == BTN_LEFT ? tabAt(pos) : std::nullopt;
    if (!W || !IDX)
        return false;

    // the release that ends a press taken here is taken too
    if (e.state != WL_POINTER_BUTTON_STATE_PRESSED)
        return true;

    const auto      GROUP   = W->grouping().group();
    const PHLWINDOW pWindow = GROUP->fromIndex(*IDX);
    if (!pWindow)
        return true;

    if (pWindow != W)
        GROUP->setCurrent(pWindow);

    if (!Desktop::focusState()->isWindowActive(pWindow) && *PFOLLOWMOUSE != 3)
        Desktop::focusState()->rawWindowFocus(pWindow, Desktop::FOCUS_REASON_CLICK_DOWN);

    if (pWindow->isFloating())
        Desktop::windowState()->raise(pWindow);

    return true;
}

// ---------------------------------------------------------------------------------------------------------------------------------------
// The grouped border

using OkLabA = std::array<float, 4>;

static OkLabA mixOk(const OkLabA& a, const OkLabA& b, double t) {
    OkLabA r;
    for (size_t i = 0; i < 4; ++i)
        r[i] = (float)(a[i] + (b[i] - a[i]) * t);
    return r;
}

static OkLabA firstStop(const Config::CGradientValueData& g) {
    const auto& v = g.m_colorsOkLabA;
    return v.size() < 4 ? OkLabA{} : OkLabA{v[0], v[1], v[2], v[3]};
}

// A gradient's colour (OkLab + alpha) at a normalised coordinate of the border's box: gradient.glsl's getOkColorForCoordArray1, with the
// angle handed over the way renderBorder hands it to the shader (whole degrees).
static OkLabA okAt(const Config::CGradientValueData& g, double nx, double ny) {
    const auto& v = g.m_colorsOkLabA;
    const int   N = v.size() / 4;
    if (N <= 0)
        return {};
    if (N < 2)
        return firstStop(g);

    const double ANGLE = (int)(g.m_angle / (std::numbers::pi / 180.0)) % 360 * (std::numbers::pi / 180.0);
    double       fin   = ANGLE;
    if (ANGLE > 4.71) {
        ny  = 1.0 - ny;
        fin = 6.28 - ANGLE;
    } else if (ANGLE > 3.14) {
        nx  = 1.0 - nx;
        ny  = 1.0 - ny;
        fin = ANGLE - 3.14;
    } else if (ANGLE > 1.57) {
        nx  = 1.0 - nx;
        fin = 3.14 - ANGLE;
    }

    const double SINE     = std::sin(fin);
    const double PROGRESS = std::clamp((ny * SINE + nx * (1.0 - SINE)) * (N - 1), 0.0, (double)(N - 1));
    const int    BOTTOM   = std::min((int)std::floor(PROGRESS), N - 2);
    const double T        = PROGRESS - BOTTOM;
    OkLabA       r;
    for (int i = 0; i < 4; ++i)
        r[i] = (float)(v[BOTTOM * 4 + i] * (1.0 - T) + v[(BOTTOM + 1) * 4 + i] * T);
    return r;
}

static bool sameColours(const Config::CGradientValueData& a, const Config::CGradientValueData& b) {
    return a.m_colorsOkLabA == b.m_colorsOkLabA;
}

// A grouped window's border, drawn by the border's own pass element. `D` is exactly what Hyprland would draw (its box, its colours mid-fade,
// its width, its alpha); this draws the same border with the same calls, only cut by clip rectangles into the top edge's selected-tab segment
// and the rest. Every piece is the border shader on the border's box with the border's width, so every piece covers exactly the pixels the
// border covers: the tab cannot stand a pixel off the border, at any scale, position or render transform. Outside the segment the pixels
// are the vanilla border's; inside it the colour runs from the border's own colour at its ends to the tab colour.
bool drawGroupBorder(CRenderContext& ctx, const CBorderPassElement::SBorderData& D) {
    static auto PBORDERACTIVE         = CConfigValue<Config::IComplexConfigValue>("group:col.border_active");
    static auto PBORDERINACTIVE       = CConfigValue<Config::IComplexConfigValue>("group:col.border_inactive");
    static auto PBORDERLOCKEDACTIVE   = CConfigValue<Config::IComplexConfigValue>("group:col.border_locked_active");
    static auto PBORDERLOCKEDINACTIVE = CConfigValue<Config::IComplexConfigValue>("group:col.border_locked_inactive");
    static auto PTABACTIVE            = CConfigValue<Config::IComplexConfigValue>("group:groupbar:col.active");
    static auto PTABINACTIVE          = CConfigValue<Config::IComplexConfigValue>("group:groupbar:col.inactive");
    static auto PTABLOCKEDACTIVE      = CConfigValue<Config::IComplexConfigValue>("group:groupbar:col.locked_active");
    static auto PTABLOCKEDINACTIVE    = CConfigValue<Config::IComplexConfigValue>("group:groupbar:col.locked_inactive");

    if (!g_pGlobalState || !g_pGlobalState->enabled->value() || D.borderSize < 1)
        return false;

    const auto W = D.window.lock();
    if (!W)
        return false;

    SP<CGroupTabs> deco;
    for (const auto& d : W->presentation().decorations()) {
        if (d->getDisplayName() == "GroupTabs") {
            deco = dynamicPointerCast<CGroupTabs>(d);
            break;
        }
    }
    if (!deco || !deco->wanted())
        return false;

    const auto  GROUP   = W->grouping().group();
    const auto& MEMBERS = GROUP->windows();
    const auto  IT      = std::ranges::find_if(MEMBERS, [&](const auto& m) { return m.lock() == W; });
    const auto  MONITOR = ctx.m_data.pMonitor.lock();
    if (IT == MEMBERS.end() || !MONITOR)
        return false;

    const int N   = MEMBERS.size();
    const int IDX = IT - MEMBERS.begin();

    // ---- where, in the element's own space (device px, monitor-local, before the render transform), exactly as renderBorder works it out
    const CBox   INNER = D.box;
    const int    SBS   = (int)std::round(D.borderSize * MONITOR->m_scale);
    const CBox   OUTER = INNER.copy().expand(SBS);
    // The straight part of the top edge: the corner arcs end `round` px in from the window's edges (border.glsl: radius = round + border,
    // measured from the outer box). The tabs share it in N equal parts, whole pixels.
    const double SPANL = INNER.x + D.round, SPANW = INNER.w - 2.0 * D.round;
    const double X0 = std::round(SPANL + IDX * SPANW / N), X1 = std::round(SPANL + (IDX + 1) * SPANW / N);
    // A segment too narrow for its two gradient halves is plain border: each half is drawn on a box two border widths narrower than the
    // half (renderBorder takes the box INSIDE the border), and a box with no width is an assertion in Hyprland.
    if (X1 - X0 < 4.0 * SBS + 8)
        return false;

    // ---- the tab colour, and the profile from the border colour at the segment's ends to it in the middle
    const bool  FOCUSED = Desktop::focusState()->window() == W;
    const bool  LOCKED  = GROUP->locked() || Desktop::windowState()->groupsLocked();
    const auto  borderOf = [&](bool f, bool l) -> const Config::CGradientValueData& {
        return *sc<Config::CGradientValueData*>((l ? (f ? PBORDERLOCKEDACTIVE : PBORDERLOCKEDINACTIVE) : (f ? PBORDERACTIVE : PBORDERINACTIVE)).ptr());
    };
    const auto  tabOf = [&](bool f, bool l) -> OkLabA {
        return firstStop(*sc<Config::CGradientValueData*>((l ? (f ? PTABLOCKEDACTIVE : PTABLOCKEDINACTIVE) : (f ? PTABACTIVE : PTABINACTIVE)).ptr()));
    };
    // The tab colour fades on the border's own clock: while the border fades from the colour of another state (focus came or went, the group
    // was locked), the tab colour fades from that state's tab colour with the same progress. The state is told by the colour the border
    // fades from; one that matches none (a window rule's colour) does not fade.
    OkLabA TAB = tabOf(FOCUSED, LOCKED);
    if (D.hasGrad2) {
        for (const auto& [f, l] : {std::pair{!FOCUSED, LOCKED}, std::pair{FOCUSED, !LOCKED}, std::pair{!FOCUSED, !LOCKED}}) {
            if (sameColours(D.grad1, borderOf(f, l))) {
                TAB = mixOk(tabOf(f, l), TAB, D.lerp);
                break;
            }
        }
    }

    const double FADE    = std::clamp((double)g_pGlobalState->fade->value(), 0.0, 0.5);
    const auto   profile = [&](double u) { // 0 at the segment's ends, 1 from `fade` in (a smoothstep)
        if (FADE <= 0.0)
            return 1.0;
        const double E = std::clamp(std::min(u, 1.0 - u) / FADE, 0.0, 1.0);
        return E * E * (3.0 - 2.0 * E);
    };
    // the border's own colour at a column of its top band (mid-fade too: the same mix of its two gradients the shader makes)
    const double NY       = (SBS / 2.0) / OUTER.h;
    const auto   borderAt = [&](double x) -> OkLabA {
        const double NX = (x - OUTER.x) / OUTER.w;
        const OkLabA C1 = okAt(D.grad1, NX, NY);
        if (!D.hasGrad2 || D.grad2.m_colorsOkLabA.empty())
            return C1;
        return mixOk(C1, okAt(D.grad2, NX, NY), D.lerp);
    };

    // ---- the clip rectangles, in the space the border region is cut in (after the render transform), whole pixels, sharing every edge
    auto&      MODIF = ctx.m_data.renderModif;
    const auto POST  = [&](CBox b) {
        MODIF.applyToBox(b);
        return b;
    };
    const CBox PIN   = POST(INNER);
    const CBox POUT  = PIN.copy().expand(std::round(SBS * MODIF.combinedScale()));
    const CBox PSEG  = POST(CBox{X0, INNER.y, X1 - X0, 1});
    const int  CX0 = (int)std::round(PSEG.x), CX1 = (int)std::round(PSEG.x + PSEG.w), CTOP = (int)std::round(PIN.y);
    const int  L = (int)std::floor(POUT.x) - 1, T = (int)std::floor(POUT.y) - 1, R = (int)std::ceil(POUT.x + POUT.w) + 1, B = (int)std::ceil(POUT.y + POUT.h) + 1;
    if (CX1 <= CX0 || CTOP <= T)
        return false;

    const auto PREVCLIP = ctx.m_data.clipBox;
    const auto clipTo   = [&](int x0, int y0, int x1, int y1) {
        ctx.m_data.clipBox = CBox{(double)x0, (double)y0, (double)(x1 - x0), (double)(y1 - y0)};
        return x1 > x0 && y1 > y0;
    };
    const GL::CHyprOpenGLImpl::SBorderRenderData RD = {.round = D.round, .roundingPower = D.roundingPower, .borderSize = D.borderSize, .a = D.a, .outerRound = D.outerRound};
    const auto vanilla = [&]() { // CGLElementRenderer::draw(border), cut by the clip in force
        if (D.hasGrad2)
            GL::g_pHyprOpenGL->renderBorder(ctx, D.box, D.grad1, D.grad2, D.lerp, RD);
        else
            GL::g_pHyprOpenGL->renderBorder(ctx, D.box, D.grad1, RD);
    };

    // the border: left of the segment, right of it, and below the band under it
    if (clipTo(L, T, CX0, B))
        vanilla();
    if (clipTo(CX1, T, R, B))
        vanilla();
    if (clipTo(CX0, CTOP, CX1, B))
        vanilla();

    // The segment, in two halves (each a gradient of 9 stops: the shader takes 10 at most, 9 put one on the middle): the border shader on a
    // box that runs from the half's columns (a pixel more each side, so the clip, not the box, is the edge) and has the border's own rows,
    // with no rounding -- on the straight edge the border is fully covered rows, so this covers exactly the border's band rows.
    constexpr int STOPS = 9;
    const double  MID   = std::round((X0 + X1) / 2.0);
    for (const auto& [H0, H1] : {std::pair{X0, MID}, std::pair{MID, X1}}) {
        const double                FX0 = H0 - 1, FX1 = H1 + 1;
        Config::CGradientValueData  grad;
        grad.m_angle = 0;
        for (int i = 0; i < STOPS; ++i) {
            const double X = FX0 + (FX1 - FX0) * i / (STOPS - 1.0);
            const auto   C = mixOk(borderAt(X), TAB, profile(std::clamp((X - X0) / (X1 - X0), 0.0, 1.0)));
            grad.m_colorsOkLabA.insert(grad.m_colorsOkLabA.end(), C.begin(), C.end());
        }
        const CBox PH = POST(CBox{H0, INNER.y, H1 - H0, 1});
        if (!clipTo((int)std::round(PH.x), T, (int)std::round(PH.x + PH.w), CTOP))
            continue;
        const CBox FAKE = {FX0 + SBS, INNER.y, (FX1 - FX0) - 2.0 * SBS, INNER.h};
        GL::g_pHyprOpenGL->renderBorder(ctx, FAKE, grad, {.round = 0, .roundingPower = D.roundingPower, .borderSize = D.borderSize, .a = D.a, .outerRound = -1});
    }

    ctx.m_data.clipBox = PREVCLIP;
    return true;
}
