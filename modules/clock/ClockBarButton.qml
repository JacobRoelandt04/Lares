pragma ComponentBehavior: Bound

import QtQuick
import "../common/components"
import "../common/theme"

// =============================================================================
// ClockBarButton.qml
//
// Bar-module clock button. Drops into a horizontal OR vertical bar — when the
// bar is horizontal the time renders as "12:34" on one line; when the bar is
// vertical the hour and minute stack upright ("12" above "34") so the glyphs
// don't rotate, matching the vision in docs/clock.md.
//
// The button itself is a transparent hit area with the figures; the actual
// bevelled pill around it is the clock split of the Workspaces groove (the shell
// places the button on `Workspaces.clockSlot`: the figures are centred in whatever
// size the host gives, and `implicitWidth` / `implicitHeight` are what they need).
// In the mockup we just render the text, plus an optional background for
// visibility.
//
// THE FIGURES STAND IN A FIXED SLOT, EACH IN ITS OWN ADVANCE (DigitCells, `proportional`). Audiowide has no tabular
// figures, so "11:11" is narrower than "00:00" and a clock whose box followed its digits would shiver every minute. The box is the
// widest layout's (`_hSlotW`: four widest digits and the colon) whatever the minute is, and the figures are centred in it on whole
// pixels. A cell as wide as the widest digit EACH would put a "1" three or four pixels away from the figure
// beside it, so each figure takes the face's own advance (as the stocks portfolio total and the screentime durations do).
// The figures are also centred on their INK, not on the font's line box: the
// digits of Audiowide sit 0.5-1.2 px above the line box's middle (measured at
// 9-18 px, monospace up to 2 px), which in a pill 14 px high is a lopsided clock.
//
//   fontFamily   "" keeps the button's own look (monospace on one line, Audiowide
//                stacked); the shell dresses both in its face ("Audiowide")
//
// THE MINUTE COMES FROM THE SHELL'S ONE BoundaryClock, NOT FROM A SystemClock. A SystemClock sleeps on a timer that stands still while
// the machine is suspended, so after a resume the bar would show the minute the lid closed at until the timer's own old interval ran out.
// The BoundaryClock is asked for each minute's boundary and
// re-reads the wall the moment logind says the machine resumed (and at least once a minute whatever happens, which also catches the
// clock being stepped); while the button is not on screen nothing is armed at all.
//
// THE SECONDS. Hovering the clock brings the seconds in on its right and the hours and minutes
// give way to them, centred on the whole: what the pointer sees is hh:mm sliding left by half the seconds' width while ":ss" comes in
// on the minutes' edge. ONE fraction runs all of it (`secondsFraction`, 260 ms OutCubic, the shell's resize) -- the room, and the
// presence of every glyph of the seconds, which is no clock of its own: each of the three (the colon, the tens, the units) comes in
// over its own slice of the room, as that slice opens, so the colon is there first, then the tens, then the units, and they leave
// in the reverse order as the room closes (each glyph appears when enough room has been made by the expanding workspaces
// assembly, and goes as it closes). `extraWidth` -- the seconds' reserved width times that
// fraction -- is what a host that makes room reads: the Workspaces assembly widens the clock's slot by it and the dots on either
// side move out (`Workspaces.clockExtra`), in the same frame, so the figures keep the margin they have at rest. A horizontal clock
// only (the stacked one has no row to extend). While the seconds are shown the BoundaryClock is asked for each second's boundary and
// for nothing else, so the bar still presents no frame between the ticks it shows.
//
// THE FLOURISH. A figure that changes rolls: DigitCells' roll, the lock screen's -- the old digit
// rises out and the new one in, units first and carrying into the tens and the hours as an odometer does ("12:59" -> "13:00").
// Each minute, and each second while they are shown; a few frames each and nothing between them.
// =============================================================================
Item {
    id: root

    // "horizontal" | "vertical"
    property string orientation: "horizontal"

    property string fontFamily: ""
    property color textColor: BarText.ink
    property int horizontalPixelSize: 18
    property int verticalPixelSize: 16
    property real verticalLineSpacing: 2

    // Allow mocks to override time for frozen-clock screenshots; real usage
    // follows the BoundaryClock below.
    property var overrideDate: null

    // ---- the seconds on hover ---------------------------------------------------------
    property bool secondsEnabled: true
    // Hold the seconds out as if hovered (clock.jsonc `seconds` "always", the mockup's switch, a probe).
    property bool forceSeconds: false
    // The seconds tick only while this is true (a host says false while its bar is out of sight): held out, they keep their room and
    // stand at the second they last showed, and the clock asks for the minute.
    property bool secondsTick: true
    readonly property bool hovered: hover.hovered
    readonly property bool _wantSeconds: root.secondsEnabled && !root._vertical && (root.hovered || root.forceSeconds)
    // 0 -> 1: the geometry (the slot widening, hh:mm giving way). 260 ms OutCubic, the shell's resize.
    property real secondsFraction: root._wantSeconds ? 1 : 0
    Behavior on secondsFraction {
        NumberAnimation {
            duration: 260
            easing.type: Easing.OutCubic
        }
    }
    // How much of the seconds is in, as a whole: the fraction itself (a glyph's own presence is its slice of it, `_secondsAlpha`). A
    // number of its own only so that a harness can hold the seconds at a state.
    property real secondsOpacity: root.secondsFraction
    // The room the seconds (":ss") take at full -- reserved, whatever the figures are, so that the room a host gives never follows a
    // digit -- and the part of it given so far: what a host that makes room follows.
    readonly property real secondsWidth: root._colonW + 2 * root._digitW
    readonly property real extraWidth: root.secondsFraction * root.secondsWidth
    // Each glyph of ":ss" is as present as the room has opened over its slice of the reserved width: 0 before it, 1 once it is all
    // open, a smooth ease between (the room is itself eased by the one clock).
    readonly property var _secondsAlpha: {
        const room = root.extraWidth;
        const lefts = [0, root._colonW, root._colonW + root._digitW], widths = [root._colonW, root._digitW, root._digitW];
        return lefts.map((l, i) => {
            const t = Math.max(0, Math.min(1, (room - l) / Math.max(1, widths[i])));
            return t * t * (3 - 2 * t);
        });
    }
    // The figures' roll: a digit's length and the cascade's step.
    property int rollMs: 320
    property int rollStaggerMs: 50

    // The clock the figures follow, and the figures themselves (a probe reads their state).
    readonly property alias clock: tick

    signal clicked()

    BoundaryClock {
        id: tick
    }
    // The next minute's start, asked for again EVERY time the clock publishes: the reader's half of the BoundaryClock's protocol. Not
    // only when the minute changes -- a clock shown after it was built hidden publishes the wall once, inside the same minute, and a
    // reader that waited for its minute to change would never ask again: the bar's clock would stand still from the shell's start.
    // The unit asked for is the second while the seconds are on show (or on their way in or out), the minute otherwise.
    readonly property bool _ticksSeconds: (root._wantSeconds || root.secondsFraction > 0) && root.secondsTick
    function _ask() {
        const unit = root._ticksSeconds ? 1000 : 60000;
        tick.request(Math.floor(tick.now / unit) * unit + unit);
    }
    // The seconds are wanted: publish the wall at once (the figures must not wait up to a second on a stale reading); the
    // reading's change asks for the next second.
    on_WantSecondsChanged: {
        if (root._wantSeconds && root.secondsTick)
            tick.request(0);
    }
    onSecondsTickChanged: {
        if (root.secondsTick && root._wantSeconds)
            tick.request(0);
    }
    Connections {
        target: tick
        function onNowChanged() {
            root._ask();
        }
    }
    Component.onCompleted: root._ask()

    readonly property var _now: overrideDate ? overrideDate : new Date(tick.now)
    readonly property bool _vertical: orientation === "vertical"
    readonly property string _ss: root._vertical ? "" : ":" + Qt.formatDateTime(_now, "ss")
    // Only the layout on show is formatted and laid out.
    readonly property string _hh: root._vertical ? Qt.formatDateTime(_now, "hh") : ""
    readonly property string _mm: root._vertical ? Qt.formatDateTime(_now, "mm") : ""
    readonly property string _flat: root._vertical ? "" : Qt.formatDateTime(_now, "hh:mm")

    readonly property string _hFamily: root.fontFamily !== "" ? root.fontFamily : "monospace"
    readonly property string _vFamily: root.fontFamily !== "" ? root.fontFamily : "Audiowide"

    // Where the digits' ink lies in the line box, from the box's top (fractional): the digits stand on the
    // baseline, and their height is read at 100 px and scaled (a tight bounding rect at the real size is
    // rounded to whole pixels and comes out a pixel too tall). The metrics' own `font` is read inside: a
    // method call alone captures nothing, and would keep the answer taken before the family applied.
    FontMetrics {
        id: hMetrics
        font.family: root._hFamily
        font.pixelSize: root.horizontalPixelSize
        font.bold: true
    }
    FontMetrics {
        id: hRef
        font.family: root._hFamily
        font.pixelSize: 100
        font.bold: true
    }
    FontMetrics {
        id: vMetrics
        font.family: root._vFamily
        font.pixelSize: root.verticalPixelSize
        font.bold: true
    }
    FontMetrics {
        id: vRef
        font.family: root._vFamily
        font.pixelSize: 100
        font.bold: true
    }
    function _ink(m, ref, px) {
        const a = m.font;
        const b = ref.font;
        const r = ref.tightBoundingRect("0123456789");
        return {
            top: m.ascent + r.y * px / 100,
            bottom: m.ascent + (r.y + r.height) * px / 100
        };
    }
    // The widest digit's advance and the colon's: what the reserved slots are made of (DigitCells' own measure, read the same way:
    // the metrics' own `font` inside the helper, since a method call alone captures nothing).
    function _widest(m) {
        const f = m.font;
        let w = 0;
        for (let d = 0; d <= 9; d++)
            w = Math.max(w, m.advanceWidth(String(d)));
        return Math.ceil(w);
    }
    function _colon(m) {
        const f = m.font;
        return Math.ceil(m.advanceWidth(":"));
    }
    // THE INK OF EACH GLYPH IN ITS CELL, for centring on what is SEEN (the figures are
    // in cells of their own advances, and a cell is not its glyph's ink -- a "1" starts 3 px in, a "5" ends 1 px short of its cell -- so "11:11:55" would stand
    // a few pixels off the middle of the slot). `left`: the ink's first column from the cell's left; `right`: the room from the ink's last column to
    // the cell's right (the cell is the advance rounded up, DigitCells.cellWidth). Read at 100 px, where the tight bounding rect is accurate to a
    // hundredth of the size, and scaled; the metrics' own `font` read inside (a method call alone captures nothing).
    function _glyphInk(m, ref, px) {
        const f = m.font;
        const g = ref.font;
        const out = {};
        for (const c of "0123456789:") {
            const r = ref.tightBoundingRect(c);
            out[c] = { left: r.x * px / 100, right: Math.ceil(m.advanceWidth(c)) - (r.x + r.width) * px / 100 };
        }
        return out;
    }
    readonly property var _hGlyphInk: root._glyphInk(hMetrics, hRef, root.horizontalPixelSize)
    // What ":ss" is expected to be, the seconds being unknown until they are shown: the colon and two digits of the digits' MEAN advance, the last
    // digit's room the mean of the digits'. The figures are placed once per minute from this (see `_hInkX`), never per second.
    readonly property var _secTypical: {
        const f = hMetrics.font;
        let adv = 0, right = 0;
        for (let d = 0; d <= 9; d++) {
            adv += Math.ceil(hMetrics.advanceWidth(String(d)));
            right += root._hGlyphInk[String(d)].right;
        }
        return { width: root._colonW + 2 * adv / 10, right: right / 10 };
    }
    readonly property real _digitW: root._widest(hMetrics)
    readonly property real _colonW: root._colon(hMetrics)
    // hh:mm's slot: four widest digits and the colon, whatever the minute is
    readonly property real _hSlotW: 4 * root._digitW + root._colonW
    readonly property real _vDigitW: root._widest(vMetrics)
    readonly property var _hInk: root._ink(hMetrics, hRef, root.horizontalPixelSize)
    readonly property var _vInk: root._ink(vMetrics, vRef, root.verticalPixelSize)
    // The figures' top, in whole pixels, so that the middle of their ink is the button's middle.
    readonly property real _hTop: Math.round(root.height / 2 - (root._hInk.top + root._hInk.bottom) / 2)
    readonly property real _vStep: vhr.implicitHeight + root.verticalLineSpacing
    readonly property real _vTop: Math.round(root.height / 2 - (root._vInk.top + root._vStep + root._vInk.bottom) / 2)

    implicitWidth: root._vertical
        ? 2 * root._vDigitW
        : root._hSlotW + root.extraWidth
    implicitHeight: root._vertical
        ? vhr.implicitHeight + vmn.implicitHeight + root.verticalLineSpacing
        : hCells.implicitHeight

    // The ink's left edge and the room right of its last column for the hh:mm on show, eased when the first or last digit changes (a "09" -> "10").
    readonly property var _hhmmInk: {
        const t = root._flat;
        if (t.length < 2)
            return { left: 0, right: 0 };
        return { left: root._hGlyphInk[t.charAt(0)].left, right: root._hGlyphInk[t.charAt(t.length - 1)].right };
    }
    property real _inkLeft: root._hhmmInk.left
    property real _inkRight: root._hhmmInk.right
    property bool _inkArmed: false
    Timer {
        running: true
        interval: 0
        onTriggered: root._inkArmed = true
    }
    Behavior on _inkLeft {
        enabled: root._inkArmed
        NumberAnimation {
            duration: root.rollMs
            easing.type: Easing.InOutQuad
        }
    }
    Behavior on _inkRight {
        enabled: root._inkArmed
        NumberAnimation {
            duration: root.rollMs
            easing.type: Easing.InOutQuad
        }
    }
    // The ink's width: hh:mm's cells less the room before its first and after its last column, plus the seconds' typical ink as they come in (the
    // last column then being the seconds'). The cells' width is the gliding one.
    readonly property real _hInkW: {
        const f = root.secondsFraction;
        const right = root._inkRight + (root._secTypical.right - root._inkRight) * f;
        return hCells.implicitWidth + f * root._secTypical.width - root._inkLeft - right;
    }
    readonly property real _hInkX: Math.round((root.width - root._hInkW) / 2 - root._inkLeft)

    // Horizontal rendering
    DigitCells {
        id: hCells
        visible: !root._vertical
        text: root._flat
        fontFamily: root._hFamily
        pixelSize: root.horizontalPixelSize
        color: root.textColor
        proportional: true
        glide: true
        rolling: true
        rollMs: root.rollMs
        staggerMs: root.rollStaggerMs
        // THE INK of the whole (hh:mm, and ":ss" as far as it has come in) is centred in the slot, on whole pixels -- not its advance box. The seconds
        // count as their TYPICAL ink (`_secTypical`) so that nothing is placed by a second: the figures move when the MINUTE changes (the cells glide
        // on the roll's own clock, and this follows hCells.implicitWidth, which glides with them; the edges' own change, the first digit's, eases
        // over the same length) and never when a second ticks. A given second is a few pixels either way of the middle (the widest and the
        // narrowest pair differ by about 4 px).
        x: root._hInkX
        y: root._hTop
    }
    // ":ss", on the minutes' right edge, a glyph at a time as the room for it opens (`_secondsAlpha`). Its figures roll once it is
    // fully on show: a reading that lands while it is still coming in (the stale one the hover found, replaced by the wall's) swaps in
    // place.
    DigitCells {
        id: sCells
        visible: !root._vertical && root.secondsFraction > 0
        text: root._ss
        fontFamily: root._hFamily
        pixelSize: root.horizontalPixelSize
        color: root.textColor
        proportional: true
        glide: true
        glyphAlpha: root._secondsAlpha
        rolling: root.secondsOpacity >= 1
        rollMs: root.rollMs
        staggerMs: root.rollStaggerMs
        x: Math.round(hCells.x + hCells.implicitWidth)
        y: root._hTop
    }

    // Vertical rendering — two stacked, upright lines, each centred on the button's width.
    DigitCells {
        id: vhr
        visible: root._vertical
        text: root._hh
        fontFamily: root._vFamily
        pixelSize: root.verticalPixelSize
        color: root.textColor
        proportional: true
        glide: true
        rolling: true
        rollMs: root.rollMs
        staggerMs: root.rollStaggerMs
        x: Math.round((root.width - vhr.implicitWidth) / 2)
        y: root._vTop
    }
    DigitCells {
        id: vmn
        visible: root._vertical
        text: root._mm
        fontFamily: root._vFamily
        pixelSize: root.verticalPixelSize
        color: root.textColor
        proportional: true
        glide: true
        rolling: true
        rollMs: root.rollMs
        staggerMs: root.rollStaggerMs
        x: Math.round((root.width - vmn.implicitWidth) / 2)
        y: root._vTop + root._vStep
    }

    // Passive: it hears the pointer and takes nothing from the click area below or from the module's swipe.
    HoverHandler {
        id: hover
        enabled: root.secondsEnabled
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
