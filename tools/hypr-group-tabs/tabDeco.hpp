#pragma once

#define WLR_USE_UNSTABLE

#include <hyprland/src/render/decorations/IHyprWindowDecoration.hpp>
#include <hyprland/src/render/pass/BorderPassElement.hpp>
#include <hyprland/src/devices/IPointer.hpp>
#include <hyprland/src/helpers/memory/Memory.hpp>
#include <hyprland/src/config/ConfigValue.hpp>
#include <optional>

// A window group's tabs, drawn as part of the window's BORDER and reserving nothing.
//
// Drawing: not here. A grouped window's border is drawn by Hyprland's own border pass element, through a hook on its render step
// (main.cpp -> drawGroupBorder): the same box, the same shader, the same border width, only split by clip rectangles so the selected
// tab's segment of the top edge gets a gradient of its own. Nothing is laid over the border, so nothing can stand a pixel off it.
//
// This decoration is the per-window part: it says which windows get tabs (wanted) and takes the pointer
// on the top border band (a drag with the move bind pulls that tab's window out of the group, a click selects it), as the vanilla
// groupbar does on its bar. Positioning: STICKY on the top edge, ABOVE the border in priority and NON_SOLID, with reserved = false: the
// positioner puts its box exactly on the border's top band, the border is not moved by it, and the layout never reserves anything for it.
//
// The forced border: a window a rule leaves without a border (border_size = 0) gets the configured general:border_size while it is in a
// group, so its tab can be seen and used; out of the group the rule is back. It is written where `hyprctl setprop border_size` writes (the
// window's border_size property, set-prop priority), so Hyprland itself draws the border, reserves it and lays the window out with it: a
// tiled member is then exactly the size of its bordered siblings.
class CGroupTabs : public IHyprWindowDecoration {
  public:
    CGroupTabs(PHLWINDOW);
    virtual ~CGroupTabs();

    virtual SDecorationPositioningInfo getPositioningInfo() override;
    virtual void                       onPositioningReply(const SDecorationPositioningReply& reply) override;
    virtual void                       draw(Render::CRenderContext& ctx, PHLMONITOR, const float& a, const Render::SWindowRenderPresentation& presentation) override;
    virtual eDecorationType            getDecorationType() override;
    virtual void                       updateWindow(PHLWINDOW) override;
    virtual void                       damageEntire() override;
    virtual bool                       onInputOnDeco(const eInputType, const Vector2D&, std::any = {}) override;
    virtual eDecorationLayer           getDecorationLayer() override;
    virtual uint64_t                   getDecorationFlags() override;
    virtual std::string                getDisplayName() override;
    virtual void                       onWindowFocus() override;

    bool eligible(); // the tabs' own conditions (a group, the plugin on, decorations), whatever the border's width
    bool wanted();   // eligible, with a border to draw them on

  private:
    PHLWINDOWREF          m_window;
    int                   m_reportedBand = 0; // the band height last handed to the positioner (logical px)

    struct {
        bool                           active = false;
        Config::INTEGER                value  = 0;   // what was written into the set-prop slot
        std::optional<Config::INTEGER> previous;     // what the slot held before (a `hyprctl setprop`), put back on release
    } m_forced;

    void                  syncForcedBorder();
    bool                  giveBackForcedBorder(); // the slot back as it was; true when the window's border width changed

    int                   bandHeight();
    std::optional<size_t> tabAt(const Vector2D& pos);
    bool                  onDragStart(const Vector2D& pos);
    bool                  onButton(const Vector2D& pos, const IPointer::SButtonEvent& e);
};

// The grouped border: draws `data` (a border pass element's data) with the tab segment, or returns false for the vanilla draw.
bool drawGroupBorder(Render::CRenderContext& ctx, const CBorderPassElement::SBorderData& data);
