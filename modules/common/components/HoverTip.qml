pragma ComponentBehavior: Bound

import QtQuick

import "../theme"

// =============================================================================
// HoverTip.qml
//
// A small floating label that names the thing under the pointer: the category
// an icon stands for, the capability a dot marks. The shell's rule is that
// nothing announces an affordance but the pointer -- this is the counterpart
// rule for MARKS: a mark that cannot be read (an icon, a dot) may explain
// itself on hover, in words, once, and in the quietest possible material.
//
// It is a semi-transparent carved box: the fill lets the content underneath
// show through, while the bevel and the inset shadow stay opaque, so what
// appears reads as an edge drawn onto the air rather than a card. Body text at
// figure size, no title, no arrow, no interaction -- it takes no input and
// casts none.
//
// WHY IT MUST LIVE IN AN OVERLAY. Two reasons, both measured in this repo:
//   - paint: a tip near the edge of a scrolling list is clipped by the list's
//     own Flickable, and a tip inside row 3 paints UNDER row 4, because z only
//     orders siblings.
//   - input (why the model picker's rows live in the overlay): Qt
//     Quick prunes POINTER DELIVERY at ancestor bounds -- an item that paints
//     outside its parents' bounds never receives a click there. A tip takes no
//     input, but anything interactive hosted the same way does.
// So the popup owns one `overlayItem` at its root, above everything, and every
// floating thing -- tips, the model list -- is reparented into it. A HoverTip
// with no `overlayItem` falls back to its own parent, which is fine for a
// harness and wrong for a list.
//
// The HOST owns the hover state (rows already track it for their wash), so the
// contract is one bool:
//
//     HoverTip {
//         show: rowArea.containsMouse
//         anchorItem: categoryIcon
//         overlayItem: root.overlayItem
//         text: "System"
//     }
// =============================================================================
Item {
    id: tip

    // ---- Contract ----
    property Item anchorItem: tip.parent
    property Item overlayItem: null
    property string text: ""
    property bool show: false
    // Rich content instead of the label: a Component the HOST declares (so it
    // closes over the host's own properties -- an image preview, a code
    // excerpt, a waveform). The label is not drawn when this is set. The
    // component is only INSTANTIATED while the tip is arming or open, so a
    // heavy preview costs nothing until it is asked for.
    property Component contentComponent: null
    // Margin between the bubble's edge and rich content: an image floats
    // inside the rounded edge, never flush against it.
    property real contentPadding: 4
    // Where the bubble sits relative to the anchor: "above" (the default),
    // "below" when the anchor hugs a top edge, or "right"/"left" when the tip
    // would otherwise cover what it explains -- a control panel's sliders,
    // say. Every side still flips to its opposite rather than leave the host.
    property string side: "above"

    // Device pixels per logical pixel at the anchor: the product of every
    // render-transform scale above it (a mockup stage zoom, a nested
    // magnifier) times the screen's devicePixelRatio. Rich content that
    // RASTERISES at a fixed size -- an Image's sourceSize, a mask layer's
    // textureSize -- multiplies its logical size by this so it stays sharp at
    // any zoom. Measured from two scene-mapped points a unit apart, not
    // plumbed from the host, so it is right in whatever the tip is nested in.
    readonly property real renderScale: bubble._rs

    // ---- Tuning ----
    property int delayMs: 350
    property int fadeMs: 160
    property real gap: 6
    property real padH: 8
    property real padV: 5
    property real radius: 8
    property string fontFamily: "Inter"
    property int fontPixelSize: 10
    // The fill's transparency. The edges stay opaque -- that is the look.
    property real fillOpacity: 0.88

    // ---- Palette ----
    property color surfaceColor: Theme.surface
    property color bevelColor: Theme.bevel
    property color shadowColor: Theme.border
    property color textColor: Theme.textPrimary

    visible: false   // the tip itself renders nothing where it is declared

    readonly property bool _armed: tip.show && (tip.text.length > 0 || tip.contentComponent !== null)

    on_ArmedChanged: {
        if (tip._armed) {
            bubble._rs = tip._measureScale();
            delay.restart();
        } else {
            delay.stop();
            tip._open = false;
        }
    }

    property bool _open: false
    Timer {
        id: delay
        interval: tip.delayMs
        onTriggered: {
            tip._place();
            tip._open = true;
        }
    }

    function _host() {
        return tip.overlayItem ? tip.overlayItem : tip.parent;
    }

    // The WINDOW's pixel ratio, not the attached Screen's: at a fractional Hyprland scale (1.25, 1.5) the Screen answers the integer 2.
    readonly property real _dpr: tip.Window.window && tip.Window.window.devicePixelRatio > 0 ? tip.Window.window.devicePixelRatio : 1

    function _measureScale() {
        const a = tip.anchorItem;
        if (!a)
            return 1;
        const p0 = a.mapToItem(null, 0, 0);
        const p1 = a.mapToItem(null, 1, 0);
        const s = Math.hypot(p1.x - p0.x, p1.y - p0.y);
        return (isFinite(s) && s > 0 ? s : 1) * tip._dpr;
    }

    // Mapped once, when the tip opens. A pointer that stays on the mark long
    // enough to read this is not also scrolling the list under it; the moment
    // the anchor moves away the hover breaks and the tip goes with it.
    function _place() {
        const host = tip._host();
        const a = tip.anchorItem;
        if (!host || !a) return;
        // A tip armed during the host's first frame (a popup opening with the
        // pointer already over a mark) would clamp to the corner, because the
        // host has no size yet. Come back once it does.
        if (host.width <= 0 || host.height <= 0) {
            Qt.callLater(tip._place);
            return;
        }
        bubble._rs = tip._measureScale();
        bubble.parent = host;
        const c = a.mapToItem(host, a.width / 2, 0);
        const w = bubble.implicitWidth;
        const h = bubble.implicitHeight;
        let x, y;
        if (tip.side === "right" || tip.side === "left") {
            // Beside the anchor, centred on it vertically. The horizontal
            // flip is the same rule the vertical sides use: if the chosen
            // side does not fit inside the host, take the other one.
            const mid = a.mapToItem(host, a.width / 2, a.height / 2);
            const rightX = a.mapToItem(host, a.width, 0).x + tip.gap;
            const leftX = a.mapToItem(host, 0, 0).x - tip.gap - w;
            x = tip.side === "right" ? rightX : leftX;
            if (x + w > host.width - 2)
                x = leftX;
            if (x < 2)
                x = rightX;
            x = Math.max(2, Math.min(host.width - w - 2, x));
            y = Math.max(2, Math.min(host.height - h - 2, mid.y - h / 2));
        } else {
            x = c.x - w / 2;
            x = Math.max(2, Math.min(host.width - w - 2, x));
            y = tip.side === "below"
                ? a.mapToItem(host, 0, a.height).y + tip.gap
                : c.y - h - tip.gap;
            if (y < 2)
                y = a.mapToItem(host, 0, a.height).y + tip.gap;
            if (y + h > host.height - 2)
                y = c.y - h - tip.gap;
        }
        bubble.x = Math.round(x);
        bubble.y = Math.round(y);
    }


    Item {
        id: bubble
        property real _rs: 1
        readonly property Item content: contentLoader.item as Item
        // Sized from the label ITEM, not from a TextMetrics of the string:
        // metrics measure one line, so a tip with a newline in it would open a
        // one-line bubble with its second line hanging out the bottom. The
        // label's implicit size is what it will actually paint.
        implicitWidth: bubble.content ? Math.ceil(bubble.content.implicitWidth) + tip.contentPadding * 2 : Math.ceil(label.implicitWidth) + tip.padH * 2
        implicitHeight: bubble.content ? Math.ceil(bubble.content.implicitHeight) + tip.contentPadding * 2 : Math.ceil(label.implicitHeight) + tip.padV * 2
        // An async preview (an Image still decoding) resolves its size after
        // the tip has opened; follow it rather than pinning the first guess.
        onImplicitWidthChanged: if (tip._open) tip._place()
        onImplicitHeightChanged: if (tip._open) tip._place()
        width: implicitWidth
        height: implicitHeight
        z: 1000

        opacity: tip._open ? 1 : 0
        visible: opacity > 0
        Behavior on opacity {
            NumberAnimation {
                duration: tip.fadeMs
                easing.type: Easing.OutCubic
            }
        }

        ShadowBox {
            anchors.fill: parent
            baseRadius: tip.radius
            // The ground outside the edge is whatever the tip floats over, so
            // it has to be no colour at all; the shader blends the bevel and
            // shadow toward it, which is what lets the edge sit on anything.
            surfaceColor: "transparent"
            bevelColor: tip.bevelColor
            shadowColor: tip.shadowColor
            backgroundColor: Qt.rgba(tip.surfaceColor.r, tip.surfaceColor.g, tip.surfaceColor.b, tip.fillOpacity)
            bevelWidth: 1
            shadowWidth: 3
        }

        Text {
            id: label
            anchors.centerIn: parent
            // A declared contentComponent OWNS the bubble: the label may not
            // stand in for it, not even for the frame between the loader
            // unloading and the fade finishing -- that frame would be a visible
            // name-only tip flashing at close.
            visible: !bubble.content && tip.contentComponent === null
            text: tip.text
            color: tip.textColor
            font.family: tip.fontFamily
            font.pixelSize: tip.fontPixelSize
        }

        Loader {
            id: contentLoader
            anchors.centerIn: parent
            // Armed, not open: created during the hover delay, so the preview
            // has its 350 ms head start and the bubble opens at its real
            // size. Kept while the bubble is still fading OUT, so the preview
            // never vanishes from under a visible tip.
            active: (tip._armed || bubble.visible) && tip.contentComponent !== null
            sourceComponent: tip.contentComponent
        }
    }
}
