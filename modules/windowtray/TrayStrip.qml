pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// TrayStrip.qml -- the tray, hung out of the bar: the engine's REEL SLOT's content (GooeyEngine: THE REEL SLOT), the slot the
// reels' strips use -- out over whatever popup is open, never in its place. The engine paints the surface under it where a popup
// lies beneath (THE GROUND), so it reads as a card laid over that popup.
//
// The power reel's strip without the ring: as
// wide as the reel (`reelStyle.thickness`), it CONTINUES the window icon's
// cell in the bar (`continuesBarCell`: the engine rests it on that cell and
// nowhere else), and its far end is the engine's half-round cap. The icons
// stand at the reel's pitch from the bar face, and the LAST one is concentric
// with the round end: a strip of one is a short stub with its icon in the
// middle of the cap.
//
// It is laid out by DISTANCE FROM THE BAR FACE (`at(d)`), in the engine's own
// unrotated frame, on whichever edge the bar is: down from a top bar, up from
// a bottom one, out to the right of a left bar, to the left of a right one.
//
// THE SECONDARY. The label beside a hovered icon and an item's menu are the
// first level of the reel slot's chain (THE REEL'S CHAIN), swapped by key
// (TraySide); this content only speaks the contract, every value of which is
// the owner's -- the owner outlives the strip (the engine destroys the content
// on close) and holds the menu models.
//
// Hover is reported, never derived: the owner reads `hovered` through the
// pointer this sets on itself (the reel's pattern), and each cell reports its
// own enter and leave.
// =============================================================================
Item {
    id: strip

    property var owner: null
    property var tray: null
    property var style: null            // WindowTrayStyle
    property var reelStyle: null        // IconReelStyle: the strip's geometry
    property string edge: "top"
    property real renderScale: 1

    readonly property bool continuesBarCell: true

    readonly property bool vertical: strip.edge === "top" || strip.edge === "bottom"
    readonly property real thickness: strip.reelStyle ? strip.reelStyle.thickness : 40
    readonly property real pitch: strip.reelStyle ? strip.reelStyle.cellPitch : 36
    readonly property int count: strip.tray ? strip.tray.count : 0
    // The last icon concentric with the half-round end.
    readonly property real length: strip.count > 0
        ? strip.pitch / 2 + (strip.count - 1) * strip.pitch + strip.thickness / 2 : strip.thickness

    implicitWidth: strip.vertical ? strip.thickness : strip.length
    implicitHeight: strip.vertical ? strip.length : strip.thickness

    // ---- the engine's content contract: the secondary --------------------------
    property Component secondaryComponent: strip.owner ? strip.owner.sideComponent : null
    property bool secondaryOpen: !!strip.owner && strip.owner.sideOpen
    property point secondaryAnchor: strip.owner ? strip.owner.sideAnchor : Qt.point(0, 0)
    property string secondarySide: strip.owner ? strip.owner.side : "end"
    property bool secondaryOverhang: true
    property real secondaryInset: 0
    property var secondaryKey: strip.owner ? strip.owner.sideKey : "label"
    // Which point of the label / menu sits on the anchor (and holds still as it
    // grows), and the share of it it opens at: a box against the bar face is
    // anchored there and opens from a point -- out of the corner.
    property real secondaryAnchorAt: strip.owner ? strip.owner.sideAnchorAt : 0.5
    property real secondaryOpenAt: strip.owner ? strip.owner.sideOpenAt : 0.5
    property real secondaryWidthFrom: strip.owner ? strip.owner.sideWidthFrom : 0.5
    // The keyboard only while a menu is out (Escape, the arrows, Enter).
    property string keyboardFocusRequest: strip.owner && strip.owner.menuOpen ? "onDemand" : "none"
    // Escape through the shell's bind while a menu is out (the engine hands it here first: GooeyEngine `pressEscape`).
    function handleEscape(): bool {
        return !!strip.owner && strip.owner.handleEscape();
    }

    readonly property bool hovered: hover.hovered

    // The centre of icon `i`, as a distance from the bar face.
    function centreOf(i) {
        return strip.pitch / 2 + i * strip.pitch;
    }
    // A distance from the bar face (and an offset across the strip, from its
    // middle) to a point of this content's own frame.
    function at(d, across) {
        const c = across === undefined ? 0 : across;
        if (strip.edge === "top")
            return Qt.point(strip.thickness / 2 + c, d);
        if (strip.edge === "bottom")
            return Qt.point(strip.thickness / 2 + c, strip.height - d);
        if (strip.edge === "left")
            return Qt.point(d, strip.thickness / 2 + c);
        return Qt.point(strip.width - d, strip.thickness / 2 + c);
    }

    HoverHandler {
        id: hover
    }

    Repeater {
        model: strip.tray ? strip.tray.rows : null
        delegate: TrayCell {
            id: c
            owner: strip.owner
            style: strip.style
            renderScale: strip.renderScale
            readonly property point centre: strip.at(strip.centreOf(c.index))
            x: Math.round(c.centre.x - c.width / 2)
            y: Math.round(c.centre.y - c.height / 2)
            width: strip.vertical ? strip.thickness : strip.pitch
            height: strip.vertical ? strip.pitch : strip.thickness
        }
    }

    focus: true
    Keys.onPressed: event => {
        if (strip.owner && strip.owner.handleKey(event))
            event.accepted = true;
    }

    Component.onCompleted: {
        if (strip.owner)
            strip.owner.strip = strip;
    }
    Component.onDestruction: {
        if (strip.owner && strip.owner.strip === strip)
            strip.owner.strip = null;
    }
}
