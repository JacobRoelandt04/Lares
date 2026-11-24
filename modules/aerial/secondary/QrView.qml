pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes

import "../../common/components"
import "../../common/theme"
import "QrCode.js" as Qr

// =============================================================================
// QrView.qml -- a QR code on a carved light ground, drawn as ONE path (one Shape, a run of dark modules per row). `text` is encoded
// by our own encoder (QrCode.js: byte mode, ECC M, versions 1-10); `ok` is false when the text is empty or too long, and then
// nothing is drawn (the host says why). The code is DARK ON LIGHT whatever the theme: a phone reads a dark module on a light quiet
// zone, so these two colours are the one place the panels hold a literal (they are the scanner's, not the shell's).
//
// SHARP: a module is a whole number of DEVICE pixels (never under 3), so every edge of the path lies on a pixel boundary and two rows
// never meet on a fraction (two antialiased shapes that meet on a line do not sum to one). The code fits `maxSize` x `maxSize`.
// =============================================================================
Item {
    id: qr

    property string text: ""
    property real maxSize: 188
    property int quiet: 4
    property color ink: "#101014"
    property color paper: "#FFFFFF"
    // a probe's handle: force a mask (the encoder's own choice by default)
    property int forceMask: -1

    readonly property var code: qr.text === "" ? null : Qr.encode(qr.text, qr.forceMask >= 0 ? qr.forceMask : undefined)
    readonly property bool ok: !!qr.code && qr.code.ok === true
    readonly property int version: qr.ok ? qr.code.version : 0
    readonly property int modules: qr.ok ? qr.code.size : 0
    readonly property string why: !qr.code ? "" : (qr.code.ok ? "" : qr.code.why)

    readonly property real _dpr: dev.value
    readonly property real _m: qr.ok ? Math.max(3, Math.floor(qr.maxSize * qr._dpr / (qr.modules + 2 * qr.quiet))) / qr._dpr : 0
    readonly property real _side: qr.ok ? (qr.modules + 2 * qr.quiet) * qr._m : 0

    implicitWidth: Math.ceil(qr._side)
    implicitHeight: Math.ceil(qr._side)
    visible: qr.ok

    DeviceScale { id: dev }

    ShadowBox {
        anchors.fill: parent
        baseRadius: 8
        surfaceColor: Theme.listBox
        backgroundColor: qr.paper
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        bevelWidth: 1
        shadowWidth: 2
        shadowFalloff: 1
    }
    Shape {
        objectName: "qrShape"
        anchors.fill: parent
        preferredRendererType: Shape.GeometryRenderer
        ShapePath {
            fillColor: qr.ink
            strokeWidth: -1
            fillRule: ShapePath.WindingFill
            PathSvg {
                path: qr.ok ? Qr.svgPath(qr.code, qr._m, qr.quiet * qr._m, qr.quiet * qr._m) : ""
            }
        }
    }
}
