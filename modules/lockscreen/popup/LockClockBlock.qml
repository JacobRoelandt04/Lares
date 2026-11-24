pragma ComponentBehavior: Bound

import QtQuick

import "../../common/components"
import "../../common/components/RelTime.js" as RelTime
import "../../common/theme"

// =============================================================================
// LockClockBlock.qml -- the hero: the time, and under it one line that says
// what this lock is.
//
//   time      Audiowide, large, in LockDigits (fixed slots that lean on the
//             colon) so a minute turning never shifts a digit and "16:06"
//             still reads as one group (Audiowide has no tabular figures); the
//             whole group is centred by its INK, eased when a minute changes
//             it. The format is the locale file's (`timeFormat`, 24 h by
//             default); the digits are the cells' own
//   line 1    first unlock of the session (`boot`): "Good morning, Sam" --
//             the greeting follows the hour, the name is `greetingName` (left
//             out, with its comma, when the host has none). Any other lock:
//             the date, in the locale file's `dateFormat`
//   line 2    a boot lock shows the date here; any other lock says how long
//             ago it was locked ("Locked 4 min ago", RelTime's own boundaries)
//
// ONE CLOCK, TICKING ON THE BOUNDARY IT SHOWS. Every text here is a function of
// `clock.now`, and `clock` (BoundaryClock) wakes at the earliest of the next
// minute and the relative time's next change -- never once a second, never
// while nothing is on screen, and after a suspend at once (its Sleep watcher).
// The block asks again from the change handler of what it read, so nothing
// ticks that no text depends on. It is the ONE thing a resting lock keeps
// running. A format with seconds is not supported: the clock ticks by the
// minute (the contract's clock).
//
// All three lines are reserved: the block's height does not depend on which
// text is shown. Text swaps are instant.
// =============================================================================
Item {
    id: root

    property string timeFormat: "HH:mm"
    property string dateFormat: "dddd d MMMM"
    property bool boot: false
    // ms since epoch when the lock was confirmed; 0 = unknown
    property real lockedAt: 0
    property string greetingName: ""
    property string fontFamily: "Audiowide"
    property real heroSize: 104
    // Digits packed from the colon (tight groups) or in fixed slots (LockDigits).
    property bool anchoredDigits: true
    // Centre the figures by their ink (off: by their advances, the colon at the centre).
    property bool centreByInk: true
    // A changed digit rolls (LockDigits): on/off, one digit's ms, the cascade's
    // step, the travel as a fraction of the hero size.
    property bool rollDigits: true
    property int rollMs: 420
    property int rollStaggerMs: 70
    property real rollTravel: 0.18
    // Device pixels per logical pixel (the host's), for resting on whole device pixels.
    property real renderScale: 1
    property real dateSize: 20
    property real subSize: 12
    // Gaps between the three lines.
    property real dateGap: 10
    property real subGap: 2

    // Host-supplied wall clock for a mockup that moves time by hand (ms since
    // epoch; 0 = follow the real clock).
    property real fixedNow: 0

    implicitWidth: heroCells.implicitWidth
    implicitHeight: root._inkH + root.dateGap + Math.ceil(dateFm.height) + root.subGap + Math.ceil(subFm.height)

    readonly property real _now: root.fixedNow > 0 ? root.fixedNow : clock.now

    BoundaryClock {
        id: clock
        // The host's visibility gates it; at rest the lock still shows a
        // minute clock, so it is deliberately not tied to `active`.
    }

    // The digits' own ink, not their line box: Audiowide's ascent leaves ~40
    // px over the figures at this size, which would put the popup's padding
    // four times further from the hero than from anything else. The cells are
    // drawn up by that much, and the block is as tall as the figures are.
    FontMetrics {
        id: heroFm
        font.family: root.fontFamily
        font.pixelSize: root.heroSize
    }
    readonly property var _ink: {
        const f = heroFm.font;
        const r = heroFm.tightBoundingRect("0123456789:");
        return { top: Math.floor(heroFm.ascent + r.y), h: Math.ceil(r.height) };
    }
    readonly property real _inkH: root._ink.h

    FontMetrics {
        id: dateFm
        font.family: root.fontFamily
        font.pixelSize: root.dateSize
    }
    FontMetrics {
        id: subFm
        font.family: root.fontFamily
        font.pixelSize: root.subSize
    }

    readonly property string timeText: Qt.formatDateTime(new Date(root._now), root.timeFormat)
    readonly property string dateText: Qt.formatDateTime(new Date(root._now), root.dateFormat)

    readonly property string greeting: {
        const h = new Date(root._now).getHours();
        const word = h >= 5 && h < 12 ? "Good morning" : (h >= 12 && h < 18 ? "Good afternoon" : (h >= 18 && h < 22 ? "Good evening" : "Good night"));
        return root.greetingName.length > 0 ? word + ", " + root.greetingName : word;
    }

    // "Locked 4 min ago": RelTime's words, its own next boundary.
    readonly property var _rel: root.lockedAt > 0
        ? RelTime.format(root.lockedAt, root._now, { justNow: "just now", suffix: " ago", dates: false })
        : ({ text: "", nextMs: -1 })
    readonly property string lockedText: root._rel.text.length > 0 ? "Locked " + root._rel.text : ""

    // When the greeting is said: "boot" (the boot lock) | "always" | "never".
    property string greets: "boot"
    readonly property bool _greeting: root.greets === "always" || (root.greets !== "never" && root.boot)
    readonly property string line1: root._greeting ? root.greeting : root.dateText
    readonly property string line2: !root._greeting ? root.lockedText
        : root.boot || root.lockedText.length === 0 ? root.dateText : root.dateText + ", locked " + root._rel.text

    // The minute after `_now`, and the relative time's next change: whichever
    // comes first is when the clock next wakes (it keeps the earliest).
    function _ask() {
        clock.request((Math.floor(root._now / 60000) + 1) * 60000);
        const rel = root._rel;
        if (rel)
            clock.request(rel.nextMs);
    }
    on_NowChanged: root._ask()
    on_RelChanged: root._ask()
    Component.onCompleted: {
        root._ask();
        Qt.callLater(() => { root._easeShift = true; });
    }

    // The ink correction: one clock (a minute turning moves the ink's middle by
    // a few px; the whole figure eases there). It snaps while the block is
    // being built and while the text's shape is unchanged.
    property real _shift: heroCells.inkOffset
    property bool _easeShift: false
    Behavior on _shift {
        enabled: root._easeShift
        NumberAnimation {
            duration: 260
            easing.type: Easing.OutCubic
        }
    }

    LockDigits {
        id: heroCells
        // Centred by its INK (LockDigits.inkOffset), not by its advances; the
        // correction eases when a minute turns and the figures' ink changes.
        // At rest on whole device pixels (glyphs raster the same way every run);
        // while the shift eases the position is fractional, which is fine moving.
        x: Math.round(((root.width - width) / 2 - (root.centreByInk ? root._shift : 0) * heroCells.scale) * root.renderScale) / root.renderScale
        y: -root._ink.top
        // A block narrower than the figures (a narrow popup) shrinks them to fit.
        transformOrigin: Item.Top
        scale: heroCells.implicitWidth > root.width && root.width > 0 ? root.width / heroCells.implicitWidth : 1
        text: root.timeText
        fontFamily: root.fontFamily
        pixelSize: root.heroSize
        anchored: root.anchoredDigits
        rolling: root.rollDigits
        rollMs: root.rollMs
        staggerMs: root.rollStaggerMs
        rollDistance: Math.round(root.heroSize * root.rollTravel)
        color: Theme.textPrimary
    }
    Text {
        y: root._inkH + root.dateGap
        width: root.width
        height: Math.ceil(dateFm.height)
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        text: root.line1
        color: Theme.textPrimary
        font.family: root.fontFamily
        font.pixelSize: root.dateSize
    }
    Text {
        y: root._inkH + root.dateGap + Math.ceil(dateFm.height) + root.subGap
        width: root.width
        height: Math.ceil(subFm.height)
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        text: root.line2
        color: Theme.textMuted
        font.family: root.fontFamily
        font.pixelSize: root.subSize
    }
}
