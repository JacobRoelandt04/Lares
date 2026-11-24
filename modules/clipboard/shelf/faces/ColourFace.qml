pragma ComponentBehavior: Bound

import QtQuick

import "../../../common/theme"
import "../../../common/components"
import "ClipParse.js" as Parse

// =============================================================================
// ColourFace.qml -- a copied CSS colour: a carved swatch well filled with the
// colour, and the value as it was copied under it.
//
// THE SWATCH COLOUR IS DATA. It is what the user copied, not a theme token, so
// it is the one place a card holds a colour that does not follow light / dark.
// =============================================================================
Item {
    id: face

    property var rec: null
    property real fw: 0
    property real fh: 0
    property int lines: 5
    property real radius: 8
    // What the swatch is carved into (the card's fill).
    property color ground: Theme.listBox

    readonly property var c: Parse.colour(face.rec ? face.rec.text : "")
    readonly property color value: Qt.rgba(face.c.r, face.c.g, face.c.b, face.c.a)
    readonly property real wellH: Math.max(24, Math.floor(face.fh - 22))

    ShadowBox {
        id: well
        x: 0
        y: 0
        width: face.fw
        height: face.wellH
        baseWidth: width
        baseHeight: height
        baseRadius: face.radius
        surfaceColor: face.ground
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        backgroundColor: face.c.ok && face.c.a >= 0.999 ? face.value : Theme.panelSunk
        bevelWidth: 1
        shadowWidth: 3
    }
    // A translucent colour is laid over the well's own ground (the sunk grey),
    // so its alpha reads as what it is: a tint of the ground it would sit on.
    Rectangle {
        visible: face.c.ok && face.c.a < 0.999
        x: 3
        y: 3
        width: face.fw - 6
        height: face.wellH - 6
        radius: Math.max(0, face.radius - 3)
        color: face.value
    }

    Text {
        x: 0
        y: face.wellH + 4
        width: face.fw
        text: face.rec ? String(face.rec.text || "").trim() : ""
        textFormat: Text.PlainText
        elide: Text.ElideRight
        maximumLineCount: 1
        color: Theme.textPrimary
        font.family: "Consolas"
        font.bold: true
        font.pixelSize: 12
    }
}
