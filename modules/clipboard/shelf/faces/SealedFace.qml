pragma ComponentBehavior: Bound

import QtQuick

import "../../../common/theme"
import "../../../common/components"
import "../../../common/components/Mix.js" as Mix
import "../../data/ClipboardModel.js" as Model

// =============================================================================
// SealedFace.qml -- a secret object: never its text, never its length.
//
// Eight fixed dots (ClipboardModel.secretView), the reason it was sealed in
// words, and a CarvedRing counting down from `t` to `expiresAt`. A heuristic
// seal carries a small raised Keep (the detector may be wrong; the others were
// sealed by their app or by the user, and are not the detector's to second
// guess). `peekText` replaces the dots while the user holds the peek -- the
// only way the text is ever drawn.
//
//   reason hint | app | manual   the source app's name
//   reason heuristic             "Looks like a password"
// =============================================================================
Item {
    id: face

    property var rec: null              // the secret: {key, mime, reason, source, t, expiresAt}
    property real fw: 0
    property real fh: 0
    property var apps: null             // AppLookup
    property double now: Date.now()
    property real ringSize: 22
    property string peekText: ""
    property color ground: Theme.listBox

    signal keepClicked()

    readonly property var view: Model.secretView(face.rec)
    readonly property bool heuristic: face.view.reason === "heuristic"
    readonly property string appName: {
        const a = face.apps && face.view.source ? (face.apps.serial >= 0 ? face.apps.app(face.view.source.cls) : null) : null;
        return a ? a.name : (face.view.source ? String(face.view.source.cls || "") : "");
    }
    readonly property string reasonText: face.heuristic ? "Looks like a password" : face.appName
    readonly property real span: face.rec ? Math.max(1, face.rec.expiresAt - face.rec.t) : 1
    readonly property real frac: face.rec ? Math.max(0, Math.min(1, (face.rec.expiresAt - face.now) / face.span)) : 0
    // Whole degrees; a quarter of the span left and the ring warms to warn.
    readonly property real deg: Math.round(face.frac * 360)
    readonly property bool peeking: face.peekText !== ""

    Text {
        x: 0
        y: 0
        width: face.fw - face.ringSize - 8
        height: 24
        visible: !face.peeking
        text: face.view.mask
        color: Theme.textPrimary
        font.family: "Inter"
        font.pixelSize: 20
        font.letterSpacing: 2
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }
    Text {
        x: 0
        y: 0
        width: face.fw - face.ringSize - 8
        height: 3 * 16
        visible: face.peeking
        text: face.peekText.slice(0, 160)
        textFormat: Text.PlainText
        wrapMode: Text.WrapAnywhere
        maximumLineCount: 3
        elide: Text.ElideRight
        color: Theme.textPrimary
        font.family: "Consolas"
        font.bold: true
        font.pixelSize: 12
        lineHeight: 16
        lineHeightMode: Text.FixedHeight
    }

    CarvedRing {
        x: face.fw - face.ringSize
        y: 0
        width: face.ringSize
        height: face.ringSize
        radius: (face.ringSize - 2) / 2 - 2.5
        lineThickness: 3
        sizeScale: 1
        grooveShadowWidth: 1.5
        grooveBevelWidth: 1
        surfaceColor: face.ground
        fillA: Mix.c(Theme.accent, Theme.warn, Math.max(0, Math.min(1, (0.25 - face.frac) / 0.15)))
        aStarts: [0, 0, 0, 0]
        aEnds: [face.deg, 0, 0, 0]
    }

    Row {
        x: 0
        y: 36
        spacing: 6
        Text {
            text: ""
            font.family: "Symbols Nerd Font"
            font.pixelSize: 11
            color: Theme.textMuted
            anchors.verticalCenter: reasonLabel.verticalCenter
        }
        Text {
            id: reasonLabel
            width: Math.min(implicitWidth, face.fw - 20)
            text: face.reasonText
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: Theme.textMuted
            font.family: "Inter"
            font.pixelSize: 12
        }
    }

    RaisedButton {
        visible: face.heuristic
        x: face.fw - width
        y: face.fh - height
        width: 52
        height: 24
        minWidth: 52
        radius: 7
        text: "Keep"
        fontPixelSize: 11
        horizontalPadding: 8
        surfaceColor: face.ground
        plateauColor: Theme.buttonPlateau
        plateauHoverColor: Theme.buttonPlateauHover
        bevelColor: Theme.buttonBevel
        shadowColor: Theme.buttonShadow
        accentColor: Theme.accent
        accentHoverColor: Theme.accentHover
        accentBevelColor: Theme.accentBevel
        onClicked: face.keepClicked()
    }
}
