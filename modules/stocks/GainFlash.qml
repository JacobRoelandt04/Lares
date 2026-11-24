pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"

// =============================================================================
// GainFlash.qml -- the real flip's flash behind ONE gain figure.
//
// Declared INSIDE the figure's Text (`target: parent`): a pale accent pill
// under the text's own ink -- as tall as the line, round to its height, a few
// px of air either side of what the text actually draws (its contentWidth,
// placed by its alignment), never a pixel of the text moved. A child at
// z: -1 is drawn under its Text's glyphs and over everything the Text is
// laid on (CLAUDE.md: a negative z goes behind the PARENT -- here that is
// the point, and a Text is not opaque).
//
// `strength` is the service's `realFlash` (0..1, ONE clock for the popup and
// the detail: 1 on the flip, down to a faint hold while real stays on, out on
// leave). The pill is the accent at `peak * strength` over whatever ground the
// figure sits on, which is the ground mixed toward the accent by that much --
// no colour is animated, the fraction is the clock (CLAUDE.md motion rules).
// =============================================================================
Rectangle {
    id: flash

    required property Text target
    property real strength: 0
    // How far toward the accent the ground goes at the flash's peak. A flash,
    // not a highlight: under a quarter.
    property real peak: 0.22
    // Air either side of the ink, px.
    property real hPad: 3

    readonly property real _cx: {
        const t = flash.target;
        if (t.horizontalAlignment === Text.AlignRight)
            return t.width - t.contentWidth;
        if (t.horizontalAlignment === Text.AlignHCenter)
            return (t.width - t.contentWidth) / 2;
        return 0;
    }
    // Whole pixels at the edges (CLAUDE.md: a box's edges, not its centre).
    x: Math.floor(flash._cx - flash.hPad)
    width: Math.ceil(flash._cx + flash.target.contentWidth + flash.hPad) - flash.x
    height: Math.min(flash.target.height, Math.ceil(flash.target.contentHeight))
    y: Math.round((flash.target.height - flash.height) / 2)
    z: -1
    radius: flash.height / 2
    color: Theme.accent
    opacity: Math.max(0, Math.min(1, flash.peak * flash.strength))
    visible: flash.opacity > 0.002 && flash.target.text.length > 0
}
