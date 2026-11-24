pragma ComponentBehavior: Bound

import QtQuick

import "../../common/components"
import "../../common/particles"
import "../../common/theme"

// =============================================================================
// TimerDial.qml -- the timers card's dial: a CarvedRing with its marks, the
// figures in its middle, and the winding.
//
// It draws what it is handed. The card blends every number here between the
// four views (ViewBlend: one clock), so the ring's gap, its fill slots, the
// ticks' presence and the marks all move together when the view changes.
//
// WINDING. Dragging round the ring turns it like a kitchen timer's dial: the
// angle accumulates across any number of turns and is reported as `wound`
// (degrees, clockwise positive) between `windStarted` and `windEnded`. The
// press is only taken on the groove itself (the containment mask is the
// annulus, a few px of slack either side), and only while `windable`.
// =============================================================================
Item {
    id: dial

    // ---- Geometry ----------------------------------------------------------
    property real radius: 150
    property real lineThickness: 6
    property real sizeScale: 2
    property real grabSlack: 8          // px either side of the groove a press still winds

    // ---- What to draw (blended by the card) -------------------------------
    property real gapDeg: 0
    property color fillA: Theme.timerRun
    property color fillB: Theme.timerBreak
    property var aStarts: [0, 0, 0, 0]
    property var aEnds: [0, 0, 0, 0]
    property var bStarts: [0, 0, 0, 0]
    property var bEnds: [0, 0, 0, 0]
    property real fillHeadBulge: 1.0
    property real fillMergePx: 3 * dial.lineThickness * dial.sizeScale / 2
    // The ground the ring is carved into (the card's fill, not the popup's
    // surface: a rim that fades from the wrong colour reads as a pale band),
    // and how far the rim reaches towards the bevel colour.
    property color groundColor: Theme.listBox
    property real bevelStrength: 1
    property var bevelEasing: [0.15, 0.1, 0.25, 1.0]
    // Presence of the tick families, 0..1.
    property real evenTicks: 1          // every 30 degrees
    property real oddTicks: 0           // the ones between (the 24 h dial)
    property real hourLabels: 0         // 0 / 6 / 12 / 18 (the 24 h dial)
    // Marks on the rim: [{ angle, strong }] and their presence.
    property var marks: []
    property real marksShown: 0
    // The now-hand (angle, presence).
    property real handAngle: 0
    property real handShown: 0

    property string figure: ""
    property string caption: ""
    property string fontFamily: "Audiowide"
    property real figureSize: 44
    property real captionSize: 13
    // The figures' block sits this far above the centre, leaving the lower
    // half of the ring's inside to the view's main action.
    property real figureOffsetY: -24

    // ---- Winding -----------------------------------------------------------
    property bool windable: false
    readonly property bool winding: windArea.pressed && dial.windable
    signal windStarted()
    signal wound(real deltaDeg, int modifiers)
    signal windEnded()

    implicitWidth: ring.implicitWidth + 2 * 28
    implicitHeight: implicitWidth

    // The ring, centred by hand on a whole pixel (anchors.centerIn rounds, and
    // the marks around it must agree with it exactly).
    readonly property real cx: Math.round(dial.width / 2)
    readonly property real cy: Math.round(dial.height / 2)

    CarvedRing {
        id: ring
        x: dial.cx - width / 2
        y: dial.cy - height / 2
        width: implicitWidth
        height: implicitHeight
        radius: dial.radius
        lineThickness: dial.lineThickness
        sizeScale: dial.sizeScale
        gapDeg: dial.gapDeg
        fillA: dial.fillA
        fillB: dial.fillB
        aStarts: dial.aStarts
        aEnds: dial.aEnds
        bStarts: dial.bStarts
        bEnds: dial.bEnds
        fillHeadBulge: dial.fillHeadBulge
        fillMergePx: dial.fillMergePx
        surfaceColor: dial.groundColor
        grooveBevelStrength: dial.bevelStrength
        grooveBevelEasing: dial.bevelEasing
    }

    readonly property real _rimIn: dial.radius - ring.halfLine - ring.bevelPx
    readonly property real _rimOut: dial.radius + ring.halfLine + ring.bevelPx

    // Ticks inside the ring: 24 positions, every other one a 30-degree mark.
    Repeater {
        model: 24
        delegate: Rectangle {
            id: tick
            required property int index
            readonly property bool even: tick.index % 2 === 0
            readonly property bool major: tick.index % 6 === 0
            readonly property real p: tick.even ? dial.evenTicks : dial.oddTicks
            readonly property real len: tick.major ? 9 : 5
            readonly property real a: tick.index * 15 * Math.PI / 180
            readonly property real rr: dial._rimIn - 7 - tick.len / 2
            width: 2
            height: tick.len
            radius: 1
            color: Theme.textFaint
            x: dial.cx + tick.rr * Math.sin(tick.a) - width / 2
            y: dial.cy - tick.rr * Math.cos(tick.a) - height / 2
            rotation: tick.index * 15
            opacity: tick.p * tick.p * (tick.major ? 0.9 : 0.6)
            scale: tick.p
            visible: tick.p > 0.001
        }
    }

    // The 24 h dial's hour figures.
    Repeater {
        model: 4
        delegate: Text {
            id: hl
            required property int index
            readonly property real a: hl.index * 90 * Math.PI / 180
            readonly property real rr: dial._rimIn - 30
            text: String(hl.index * 6)
            color: Theme.textFaint
            font.family: dial.fontFamily
            font.pixelSize: 11
            x: Math.round(dial.cx + hl.rr * Math.sin(hl.a) - implicitWidth / 2)
            y: Math.round(dial.cy - hl.rr * Math.cos(hl.a) - implicitHeight / 2)
            opacity: dial.hourLabels * dial.hourLabels
            visible: dial.hourLabels > 0.001
        }
    }

    // Marks on the outer rim: alarms, laps.
    Repeater {
        model: dial.marks.length
        delegate: Rectangle {
            id: mk
            required property int index
            readonly property var m: dial.marks[mk.index] || { angle: 0, strong: false }
            readonly property real a: mk.m.angle * Math.PI / 180
            readonly property real rr: dial._rimOut + 6
            readonly property real d: mk.m.strong ? 9 : 6
            width: mk.d
            height: mk.d
            radius: mk.d / 2
            color: mk.m.strong ? Theme.accent : Theme.textMuted
            x: dial.cx + mk.rr * Math.sin(mk.a) - width / 2
            y: dial.cy - mk.rr * Math.cos(mk.a) - height / 2
            opacity: dial.marksShown * dial.marksShown
            scale: dial.marksShown
            visible: dial.marksShown > 0.001
        }
    }

    // Now, on the 24 h dial: a short hand just inside the rim.
    Rectangle {
        readonly property real a: dial.handAngle * Math.PI / 180
        readonly property real rr: dial._rimIn - 12
        width: 3
        height: 14
        radius: 1.5
        color: Theme.textPrimary
        x: dial.cx + rr * Math.sin(a) - width / 2
        y: dial.cy - rr * Math.cos(a) - height / 2
        rotation: dial.handAngle
        opacity: dial.handShown * dial.handShown
        scale: dial.handShown
        visible: dial.handShown > 0.001
    }

    // Completion dust: off an arc of the ring, drifting outward and fading.
    ParticleSystem {
        id: dust
        anchors.fill: parent
        maxParticles: 200
        // Not while the dial is out of sight (its tab is not the shown one, or its popup is parked: GooeyEngine, THE PARKED
        // CONTENT): a running system is a running clock. Stopping one destroys its particles, so none is held to resume.
        running: !Theme.crossfading && dial.visible
    }
    property int burstCount: 34
    property real burstLifetimeMs: 1800
    function burst(fromDeg, toDeg, color) {
        const span = Math.max(1, toDeg - fromDeg);
        for (let i = 0; i < dial.burstCount; i++) {
            const deg = fromDeg + Math.random() * span;
            const a = deg * Math.PI / 180;
            const side = Math.random() < 0.6 ? 1 : -1;       // most go outward
            const r = dial.radius + side * ring.halfLine * Math.random();
            const sp = 8 + Math.random() * 18;
            dust.emit({
                x: dial.cx + r * Math.sin(a),
                y: dial.cy - r * Math.cos(a),
                vx: side * sp * Math.sin(a) + (Math.random() - 0.5) * 6,
                vy: -side * sp * Math.cos(a) + (Math.random() - 0.5) * 6,
                lifetime: dial.burstLifetimeMs * (0.7 + Math.random() * 0.5),
                maxHistory: 1,
                sizeStart: 2.4 * dial.sizeScale,
                sizeEnd: 0.6 * dial.sizeScale,
                colorStart: color.toString(),
                colorEnd: "transparent",
                drag: 1.1,
                deathFadeFraction: 0.5
            }, 1);
        }
    }

    // The figures fit the ring's inside: a figure whose SHAPE is wider than
    // the chord at its height ("00:00.0" of the stopwatch) takes a smaller
    // size. Widths scale with the pixel size, so one measurement at the full
    // size says which size fits; the metrics' own font is read in the helper
    // (an advanceWidth() call alone captures nothing -- CLAUDE.md).
    FontMetrics {
        id: figMetrics
        font.family: dial.fontFamily
        font.pixelSize: dial.figureSize
        font.bold: true
    }
    function _shapeWidth(text) {
        const f = figMetrics.font;
        let digit = 0;
        for (let d = 0; d <= 9; d++)
            digit = Math.max(digit, figMetrics.advanceWidth(String(d)));
        let w = 0;
        for (let i = 0; i < text.length; i++) {
            const ch = text.charAt(i);
            w += ch >= "0" && ch <= "9" ? Math.ceil(digit) : Math.ceil(figMetrics.advanceWidth(ch));
        }
        return w;
    }
    // The chord of the ticks' inner circle at the figures' top and bottom.
    readonly property real figureRoom: {
        const r = dial._rimIn - 20;
        const dy = Math.abs(dial.figureOffsetY) + dial.figureSize * 0.6;
        return 2 * Math.sqrt(Math.max(0, r * r - dy * dy));
    }
    readonly property real fittedFigureSize: {
        const w = dial._shapeWidth(dial.figure.replace(/[0-9]/g, "0"));
        return w <= 0 ? dial.figureSize : Math.floor(dial.figureSize * Math.min(1, dial.figureRoom / w));
    }

    // The figures: whole pixels, centred by hand.
    DigitCells {
        id: fig
        text: dial.figure
        fontFamily: dial.fontFamily
        pixelSize: dial.fittedFigureSize
        x: Math.round(dial.cx - implicitWidth / 2)
        y: Math.round(dial.cy + dial.figureOffsetY - implicitHeight / 2)
    }
    Text {
        text: dial.caption
        color: Theme.textMuted
        font.family: dial.fontFamily
        font.pixelSize: dial.captionSize
        x: Math.round(dial.cx - implicitWidth / 2)
        y: Math.round(fig.y + fig.implicitHeight + 2)
    }

    // ---- The winding hand --------------------------------------------------
    property real _lastAng: 0
    function _angleAt(px, py) {
        return Math.atan2(px - dial.cx, -(py - dial.cy)) * 180 / Math.PI;
    }
    MouseArea {
        id: windArea
        anchors.fill: parent
        enabled: dial.windable
        preventStealing: true
        hoverEnabled: true
        cursorShape: dial.windable && (windArea.pressed || windArea.containsMouse) ? (windArea.pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor) : Qt.ArrowCursor
        containmentMask: QtObject {
            // Typed: an untyped JS function is not seen as invokable here.
            function contains(point: point): bool {
                const r = Math.hypot(point.x - dial.cx, point.y - dial.cy);
                return Math.abs(r - dial.radius) <= ring.halfLine + ring.bevelPx + dial.grabSlack;
            }
        }
        onPressed: mouse => {
            dial._lastAng = dial._angleAt(mouse.x, mouse.y);
            dial.windStarted();
        }
        onPositionChanged: mouse => {
            if (!windArea.pressed)
                return;
            // Too close to the centre the angle is noise.
            if (Math.hypot(mouse.x - dial.cx, mouse.y - dial.cy) < 12)
                return;
            const a = dial._angleAt(mouse.x, mouse.y);
            let d = a - dial._lastAng;
            d -= 360 * Math.round(d / 360);
            dial._lastAng = a;
            if (d !== 0)
                dial.wound(d, mouse.modifiers);
        }
        onReleased: dial.windEnded()
        onCanceled: dial.windEnded()
    }
}
