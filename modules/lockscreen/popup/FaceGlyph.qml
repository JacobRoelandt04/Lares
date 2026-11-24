pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes

import "../../common/components"
import "../../common/components/Mix.js" as Mix
import "../../common/components/Sweep.js" as Sweep
import "../../common/theme"

// =============================================================================
// FaceGlyph.qml -- face unlock, as a small carved plate at the end of the
// password field.
//
// A round plate carved into the field (ShadowBox), a face drawn on it in two
// dots and a mouth. The STATE is told by the plate's inset shadow, the
// material's one voice for "something is happening here":
//
//   absent          nothing is drawn, and the field is symmetric without it
//   idle            the face in the muted ink, the plain carve
//   scanning        the accent colour sweeps round the inset (a band, the LLM
//                   turn's indeterminate bar on a circle); one clock, `_f`
//   ok              the inset settles to the ok colour
//   failed          the inset settles to the error colour, the mouth flat
//   dark            plain carve, the mouth flat: it could not see you
//   busy, unavailable, misconfigured
//                   the same face at half strength: not now, not here
//
// ONE CLOCK PER MOTION. `_f` is the sweep's phase, a linear 0 -> 1 loop that
// runs only while the band is showing AND `active` (a lock at rest ticks
// nothing). The band's presence (`_bandF`), ok and failed are eased FRACTIONS
// that mix themed colours (Mix.js) -- never a Behavior on a colour, so a
// theme switch stays one clock, and the band is faded out before the phase is
// parked, so it is never cut. The whole glyph fades in and out with `absent`.
//
// Nothing here is clickable: the shell's layers hear no input while locked.
// =============================================================================
Item {
    id: root

    // "absent" | "idle" | "scanning" | "ok" | "failed" | "dark" | "busy"
    // | "unavailable" | "misconfigured"
    property string face: "absent"
    property bool active: true
    property real size: 40
    // Sweep: one trip round the plate.
    property int sweepMs: 1500
    property real sweepHead: 0.7
    property real sweepTail: 0.7
    property int fadeMs: 160
    // How much of the glyph's ink a "not now" state keeps.
    property real faintOpacity: 0.5
    // The plate's rim, in device-independent px.
    property real plateBevel: 1
    property real plateShadow: 3

    implicitWidth: root.size
    implicitHeight: root.size

    readonly property bool _shown: root.face !== "absent"
    readonly property bool _faint: root.face === "busy" || root.face === "unavailable" || root.face === "misconfigured"
    readonly property bool _scanning: root.face === "scanning"

    // Eased fractions.
    property real _presence: root._shown ? 1 : 0
    property real _bandF: root._scanning ? 1 : 0
    property real _okF: root.face === "ok" ? 1 : 0
    property real _failF: root.face === "failed" ? 1 : 0
    Behavior on _presence {
        NumberAnimation {
            duration: root.fadeMs
            easing.type: Easing.OutCubic
        }
    }
    Behavior on _bandF {
        NumberAnimation {
            duration: root.fadeMs
            easing.type: Easing.OutCubic
        }
    }
    Behavior on _okF {
        NumberAnimation {
            duration: root.fadeMs
            easing.type: Easing.OutCubic
        }
    }
    Behavior on _failF {
        NumberAnimation {
            duration: root.fadeMs
            easing.type: Easing.OutCubic
        }
    }

    // The sweep's phase: runs while the band shows, parks at 0 once it has
    // faded out (so it never restarts under ink).
    property real _f: 0
    readonly property bool _running: root.active && (root._scanning || root._bandF > 0) && !Theme.crossfading
    NumberAnimation on _f {
        from: 0
        to: 1
        duration: root.sweepMs
        loops: Animation.Infinite
        running: root._running
    }
    on_BandFChanged: if (root._bandF === 0 && !root._scanning) root._f = 0

    visible: root._presence > 0
    opacity: root._presence * (root._faint ? root.faintOpacity : 1)

    ShadowBox {
        id: plate
        anchors.fill: parent
        baseRadius: root.size / 2
        surfaceColor: Theme.listBox
        backgroundColor: Theme.listBox
        bevelColor: Theme.bevel
        bevelWidth: root.plateBevel
        shadowWidth: root.plateShadow
        // One inset depth in every state: the band's own depth defaults are
        // the header's (7 px), far too deep for a 40 px plate.
        progressIdleWidth: root.plateShadow
        progressActiveWidth: root.plateShadow
        progressActiveFeatherPx: 7
        progressIdleFeatherPx: 7
        shadowColor: Mix.c(Mix.c(Theme.border, Theme.ok, root._okF), Theme.error, root._failF)
        shadowProgress: Sweep.lead(root._f, root.sweepHead)
        shadowProgressTail: Sweep.trail(root._f, root.sweepTail)
        shadowProgressColor: Mix.c(plate.shadowColor, Theme.accent, root._bandF)
    }

    // The face. Two dots and a mouth: enough to read as a face at 40 px and
    // nothing that could be taken for a person.
    readonly property color _ink: root.face === "ok" ? Theme.ok
        : (root.face === "failed" || root.face === "dark" || root._faint ? Theme.textFaint : Theme.textMuted)
    // -1 frown .. 0 flat .. 1 smile
    readonly property real _mouth: root.face === "failed" ? -0.7 : (root.face === "dark" ? 0 : 1)

    Repeater {
        model: 2
        delegate: Rectangle {
            id: eye
            required property int index
            readonly property real d: Math.max(3, Math.round(root.size * 0.11))
            width: eye.d
            height: eye.d
            radius: eye.d / 2
            x: Math.round(root.size * (eye.index === 0 ? 0.33 : 0.67) - eye.d / 2)
            y: Math.round(root.size * 0.38 - eye.d / 2)
            color: root._ink
        }
    }
    Shape {
        id: mouth
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeColor: root._ink
            strokeWidth: Math.max(2, Math.round(root.size * 0.055))
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            startX: root.size * 0.33
            startY: root.size * 0.64
            PathQuad {
                x: root.size * 0.67
                y: root.size * 0.64
                controlX: root.size * 0.5
                controlY: root.size * 0.64 + root._mouth * root.size * 0.22
            }
        }
    }
}
