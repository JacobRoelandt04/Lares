pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"

// =============================================================================
// TipLabel.qml -- the name of a setting, and what it is on hover. Nothing announces the tip but the
// pointer: the label stays a label. The tip floats in the panel's overlay (a tip inside a block is
// clipped by whatever scrolls and painted under the next one), ABOVE the words, so it never covers
// the label it explains (to the right of a wide label it would: the panel is only so wide), and
// HoverTip puts it below where there is no room above. Its lines are broken by hand: HoverTip does
// not wrap.
// =============================================================================
Text {
    id: label

    property SecondaryStyle look: null
    property Item overlay: null
    property string tip: ""
    // The room the words may take before they elide; the label is as wide as its words, so the
    // hover area is the words and the tip opens beside them.
    property real maxWidth: 1e6

    width: Math.min(label.implicitWidth, label.maxWidth)
    color: Theme.textPrimary
    font.family: label.look ? label.look.fontFamily : "Inter"
    font.pixelSize: label.look ? label.look.bodySize : 12
    textFormat: Text.PlainText
    elide: Text.ElideRight

    HoverHandler {
        id: hover
        enabled: label.tip.length > 0
    }
    HoverTip {
        show: hover.hovered
        anchorItem: label
        overlayItem: label.overlay
        side: "above"
        gap: 4
        text: label.tip
        fontFamily: label.font.family
        fontPixelSize: label.look ? label.look.figureSize : 11
    }
}
