pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/components/Mix.js" as Mix
import "../common/scroll"

// =============================================================================
// StockRangeChips.qml -- a chart's range chips (1D 5D 1M ...), and the swipe
// that steps them. The summary card's and the detail's, one component.
//
//   ranges    ["1D", "5D", ...] in order
//   current   the range in effect (the host's; this only asks)
//   picked(range)   a click, or a swipe step
//
// A chip is as wide as its label in BOLD plus `chipPad`, whichever chip is
// current -- the current one is bold, and a width that followed the weight
// would shift the whole row by a pixel on every pick. Given a `maxWidth`
// narrower than that, the pad shrinks (not below `minPad`) so the row fits.
//
// THE SWIPE (docs/contracts/gestures.md). A two-finger SIDEWAYS swipe over the
// row steps the range by one per detent: a wheel, read by a MouseArea that
// takes no buttons (never a WheelHandler), under the chips so their clicks
// and hover are untouched. The first events that clearly lead (x
// `axisLead`) latch the gesture's axis until the fingers lift (the
// zero-delta event) or `gestureIdleEndMs` of silence. Sideways: WheelStepper
// counts it (a mouse notch is one step, a touchpad -- any event carrying a
// pixel delta -- counts against the touchpad detent, a cooldown between
// steps) and the event is TAKEN, drift and all, so the box under the row
// does not scroll while the fingers go sideways. Vertical, or not yet
// decided: passed on untouched, to the detail's ScrollDressing or the popup.
// Positive x is the next range (TabSelector's sign); the ends clamp.
//
// A HOST THAT READS THE WHEEL ITSELF (the detail, whose body scrolls under
// the row) sets `wheelEnabled: false` and offers each event to `wheel(angle,
// pixel)`, scrolling by what it is handed back (false) -- one reader of one
// event (CLAUDE.md), so a sideways swipe's drift never scrolls the body.
// `gestureActive` says a gesture has latched its axis here and is not over.
// =============================================================================
Item {
    id: chips

    property var ranges: []
    property string current: ""
    property string fontFamily: "Inter"
    property int pixelSize: 11
    property real chipPad: 10
    property real minPad: 4
    property real spacing: 2
    // 0 = no limit.
    property real maxWidth: 0

    // The detent and the gesture's life (the shell's numbers: WeatherDetail).
    property real swipeNotchThreshold: 120
    property real swipePixelThreshold: 1000
    property int swipeStepCooldownMs: 200
    property real swipePixelToAngle: 2.5
    property int gestureIdleEndMs: 260
    property real axisLead: 1.2
    // false: this row's own reader is off and the host offers it `wheel()`.
    property bool wheelEnabled: true
    readonly property bool gestureActive: chips._axis !== ""

    signal picked(string range)

    // ---- widths: every label measured bold, once per font -----------------------
    FontMetrics {
        id: boldM
        font.family: chips.fontFamily
        font.pixelSize: chips.pixelSize
        font.bold: true
    }
    // Reads the metrics' own font first: that read is the dependency, and
    // the guarantee the measure runs after the font changed (CLAUDE.md).
    readonly property var _textW: {
        void boldM.font;
        return (chips.ranges || []).map(r => Math.ceil(boldM.advanceWidth(String(r))));
    }
    readonly property real _textSum: chips._textW.reduce((a, b) => a + b, 0)
    readonly property int _n: (chips.ranges || []).length
    readonly property real _gaps: Math.max(0, chips._n - 1) * chips.spacing
    readonly property real pad: {
        if (chips.maxWidth <= 0 || chips._n === 0)
            return chips.chipPad;
        const fit = Math.floor((chips.maxWidth - chips._textSum - chips._gaps) / chips._n);
        return Math.max(chips.minPad, Math.min(chips.chipPad, fit));
    }

    implicitWidth: chips._textSum + chips._n * chips.pad + chips._gaps
    implicitHeight: Math.ceil(chips.pixelSize * 1.6)

    // ---- the swipe ----------------------------------------------------------------
    WheelStepper {
        id: stepper
        notchThreshold: chips.swipeNotchThreshold
        pixelThreshold: chips.swipePixelThreshold
        stepCooldownMs: chips.swipeStepCooldownMs
    }
    property string _axis: ""
    Timer {
        id: idleEnd
        interval: chips.gestureIdleEndMs
        onTriggered: chips._end()
    }
    function _end() {
        idleEnd.stop();
        stepper.end();
        chips._axis = "";
    }
    function step(n) {
        const i = chips.ranges.indexOf(chips.current);
        if (i < 0 || n === 0)
            return;
        const j = Math.max(0, Math.min(chips._n - 1, i + n));
        if (j !== i)
            chips.picked(chips.ranges[j]);
    }
    // One wheel event (WheelHub's); returns whether it was
    // used -- the host accepts it then, and passes it on otherwise.
    function wheel(ev) {
        const ad = ev.angleDelta, pd = ev.pixelDelta;
        // a mouse: a sideways notch is a range (an upright one is the page's)
        if (ev.device === "wheel") {
            if (ad.x === 0)
                return false;
            chips.step(ev.steps);
            return true;
        }
        const dx = ad.x !== 0 ? ad.x : pd.x * chips.swipePixelToAngle;
        const dy = ad.y !== 0 ? ad.y : pd.y * chips.swipePixelToAngle;
        if (dx === 0 && dy === 0) {
            chips._end();
            return false;
        }
        idleEnd.restart();
        if (chips._axis === "") {
            if (Math.abs(dx) > Math.abs(dy) * chips.axisLead)
                chips._axis = "x";
            else if (Math.abs(dy) > Math.abs(dx) * chips.axisLead)
                chips._axis = "y";
        }
        if (chips._axis !== "x")
            return false;
        if (dx !== 0)
            chips.step(stepper.feed(dx, pd.x !== 0));
        return true;
    }
    WheelArea {
        id: swipeArea
        objectName: "rangeSwipeArea"
        anchors.fill: parent
        enabled: chips.wheelEnabled
        turned: ev => ev.accepted = chips.wheel(ev)
    }

    // ---- the chips ----------------------------------------------------------------
    Row {
        id: row
        height: chips.height
        spacing: chips.spacing
        Repeater {
            model: chips._n
            delegate: Item {
                id: chip
                required property int index
                readonly property string range: String(chips.ranges[chip.index])
                readonly property bool on: chips.current === chip.range
                property real hoverF: chipArea.containsMouse ? 1 : 0
                Behavior on hoverF {
                    NumberAnimation {
                        duration: 120
                        easing.type: Easing.OutCubic
                    }
                }
                width: (chips._textW[chip.index] || 0) + chips.pad
                height: row.height
                Text {
                    anchors.fill: parent
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: chip.range
                    color: chip.on ? Theme.accent : Mix.c(Theme.textFaint, Theme.accent, chip.hoverF)
                    font.family: chips.fontFamily
                    font.pixelSize: chips.pixelSize
                    font.bold: chip.on
                }
                MouseArea {
                    id: chipArea
                    objectName: "rangeChip_" + chip.range
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (!chip.on)
                            chips.picked(chip.range);
                    }
                }
            }
        }
    }
}
