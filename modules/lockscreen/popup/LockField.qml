pragma ComponentBehavior: Bound

import QtQuick

import "../../common/components"
import "../../common/components/Mix.js" as Mix
import "../../common/components/Sweep.js" as Sweep
import ".."
import "../../common/theme"

// =============================================================================
// LockField.qml -- the password field: carved, dots in the middle, the face
// glyph at its end.
//
// The lock process owns the keyboard and the password; this only draws what
// LockState says (`dots`, `auth`, `caps`, `face`). Nothing here is clickable.
//
// THE INSET SHADOW IS THE FIELD'S ONE VOICE, as it is the system update's
// category headers': every state is a colour in the carve, never a second mark.
//
//   idle      the plain carve
//   checking  an accent band crosses the inset, over and over: "still working"
//             (pam_unix answers a wrong password after ~2 s, so this is what
//             the user watches). One clock `_f`, gated on `active`
//   failed    the inset flushes to the error colour and eases back (one
//             fraction, a one-shot); the words stay under the field until the
//             next key
//   ok        the inset settles to the ok colour
//   caps      the inset holds the warn colour while caps lock is on
//
// Colours are mixed from themed tokens by eased FRACTIONS (Mix.js) -- never a
// Behavior on a colour, so a light/dark switch is still one clock.
//
// DOTS. One repeater over the visible CAP (a number), each dot a delegate that
// grows with a single eased count `_n`: a key press eases the row's width, and
// the row stays centred on the field, so every dot lands where the next
// centring puts it. The cap is what fits between the two reserved side slots
// (the face glyph's, mirrored on the left so the dots are centred whether the
// glyph is there or not) up to `maxDots`; past it the row holds its width, its
// first dots fade out and the last dot pulses on each key, so typing is still
// answered.
// =============================================================================
Item {
    id: root

    property LockState lockState: null
    property bool active: true

    property real fieldHeight: 64
    property real radius: 32
    property real dotSize: 10
    property real dotGap: 6
    property int maxDots: 32
    property real glyphSize: 40
    property bool placeholderGlyph: true
    property string iconFamily: "Symbols Nerd Font"
    property int checkSweepMs: 1600
    property real sweepHead: 0.7
    property real sweepTail: 0.7
    property int stateFadeMs: 160
    property int failFlushMs: 140
    property int failReturnMs: 800
    property int dotGrowMs: 120
    // The ground the field is carved into (its rim is drawn from this towards
    // the bevel): the lock's surface by default; the auth toast's card
    // (Theme.listBox) passes its own.
    property color surfaceColor: Theme.surface

    implicitWidth: 560
    implicitHeight: root.fieldHeight

    readonly property alias faceGlyph: faceGlyph
    readonly property int dots: root.lockState ? root.lockState.dots : 0
    readonly property string auth: root.lockState ? root.lockState.auth : "idle"
    readonly property bool caps: root.lockState ? root.lockState.caps : false
    readonly property string face: root.lockState ? root.lockState.face : "absent"

    // The glyph's square sits one padding from the field's end on every side.
    readonly property real _pad: Math.round((root.fieldHeight - root.glyphSize) / 2)
    readonly property real _side: root._pad * 2 + root.glyphSize
    readonly property real _pitch: root.dotSize + root.dotGap
    readonly property int cap: Math.max(1, Math.min(root.maxDots,
        Math.floor((root.width - 2 * root._side + root.dotGap) / root._pitch)))
    readonly property int _visibleDots: Math.min(root.dots, root.cap)
    readonly property bool _overflow: root.dots > root.cap

    // ---- the eased fractions -------------------------------------------------
    property real _n: root._visibleDots
    Behavior on _n {
        NumberAnimation {
            duration: root.dotGrowMs
            easing.type: Easing.OutCubic
        }
    }
    property real _capsF: root.caps ? 1 : 0
    property real _okF: root.auth === "ok" ? 1 : 0
    property real _bandF: root.auth === "checking" ? 1 : 0
    property real _hintF: root.dots === 0 && root.auth !== "checking" && root.auth !== "ok" ? 1 : 0
    Behavior on _capsF {
        NumberAnimation {
            duration: root.stateFadeMs
            easing.type: Easing.OutCubic
        }
    }
    Behavior on _okF {
        NumberAnimation {
            duration: root.stateFadeMs
            easing.type: Easing.OutCubic
        }
    }
    Behavior on _bandF {
        NumberAnimation {
            duration: root.stateFadeMs
            easing.type: Easing.OutCubic
        }
    }
    Behavior on _hintF {
        NumberAnimation {
            duration: root.stateFadeMs
            easing.type: Easing.OutCubic
        }
    }

    // A wrong password: flush to the error colour, ease back.
    property real _failF: 0
    SequentialAnimation {
        id: failFlush
        NumberAnimation {
            target: root
            property: "_failF"
            to: 1
            duration: root.failFlushMs
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: root
            property: "_failF"
            to: 0
            duration: root.failReturnMs
            easing.type: Easing.InOutQuad
        }
    }
    onAuthChanged: {
        if (root.auth === "failed")
            failFlush.restart();
    }

    // The dot pulse of an overflowing row: 0 -> 1 on each key.
    property real _pulse: 1
    NumberAnimation {
        id: pulseAnim
        target: root
        property: "_pulse"
        from: 0
        to: 1
        duration: 140
        easing.type: Easing.OutCubic
    }
    onDotsChanged: {
        if (root._overflow && root.active)
            pulseAnim.restart();
    }

    // The checking band's phase: parks at 0 once the band has faded out.
    property real _f: 0
    readonly property bool _running: root.active && (root.auth === "checking" || root._bandF > 0) && !Theme.crossfading
    NumberAnimation on _f {
        from: 0
        to: 1
        duration: root.checkSweepMs
        loops: Animation.Infinite
        running: root._running
    }
    on_BandFChanged: if (root._bandF === 0 && root.auth !== "checking") root._f = 0

    // ---- the carve -----------------------------------------------------------
    ShadowBox {
        id: box
        anchors.fill: parent
        baseRadius: root.radius
        surfaceColor: root.surfaceColor
        backgroundColor: Theme.listBox
        bevelColor: Theme.bevel
        bevelWidth: 1
        shadowWidth: 3
        // The band shares the plain carve's depth in every state.
        progressIdleWidth: 3
        progressActiveWidth: 3
        shadowColor: Mix.c(Mix.c(Mix.c(Theme.border, Theme.warn, root._capsF), Theme.ok, root._okF), Theme.error, root._failF)
        shadowProgress: Sweep.lead(root._f, root.sweepHead)
        shadowProgressTail: Sweep.trail(root._f, root.sweepTail)
        shadowProgressColor: Mix.c(box.shadowColor, Theme.accent, root._bandF)
    }

    // The placeholder: the key, faint, until the first character.
    Text {
        visible: root.placeholderGlyph && root._hintF > 0
        opacity: root._hintF
        x: Math.round((root.width - implicitWidth) / 2)
        y: Math.round((root.height - implicitHeight) / 2)
        text: "\u{F0306}"
        color: Theme.textFaint
        font.family: root.iconFamily
        font.pixelSize: Math.round(root.fieldHeight * 0.36)
    }

    // The dots.
    Repeater {
        model: root.cap
        delegate: Rectangle {
            id: dot
            required property int index
            // How present this dot is: 0 not typed, 1 typed; grows with `_n`.
            readonly property real f: Math.max(0, Math.min(1, root._n - dot.index))
            readonly property bool last: dot.index === root.cap - 1
            readonly property real lead: root._overflow && dot.index < 2 ? (dot.index + 1) / 3 : 1
            readonly property real bump: root._overflow && dot.last ? 1 + 0.35 * (1 - root._pulse) : 1
            readonly property real d: root.dotSize * dot.f * dot.bump
            width: dot.d
            height: dot.d
            radius: dot.d / 2
            visible: dot.f > 0
            opacity: dot.f * dot.lead
            color: Theme.textPrimary
            x: (root.width - (root._n * root._pitch - root.dotGap)) / 2 + dot.index * root._pitch
               + (root.dotSize - dot.d) / 2
            y: (root.height - dot.d) / 2
        }
    }

    FaceGlyph {
        id: faceGlyph
        x: root.width - root._pad - root.glyphSize
        y: root._pad
        size: root.glyphSize
        face: root.face
        active: root.active
    }
}
