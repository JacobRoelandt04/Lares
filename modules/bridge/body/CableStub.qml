pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"

// =============================================================================
// CableStub.qml -- the cable in the phone's port: a plug seated under the port and its cord running off the foot of
// the stage. PhoneStage places it (the port's middle, the body's foot) and says how far it is in (`seat`, 0 out ..
// 1 home: ONE eased fraction; the plug travels and fades on it).
//
// It is drawn in the shell's own material -- a raised plug, a cord in the border's tone -- and not by the body's
// shader: it lies outside the body's outline, and it is the one part of the phone that moves while the phone rests
// (a part eased on the body's cached picture would re-trace the whole phone on every frame of its travel).
// =============================================================================
Item {
    id: stub

    // 0 out of the port .. 1 home.
    property real seat: 0
    property real plugWidth: 30
    property real plugHeight: 17
    property real cordWidth: 6
    // how far below its seat the plug starts
    property real travel: 9
    property color ground: Theme.surface

    width: stub.plugWidth
    visible: stub.seat > 0.002
    opacity: Math.min(1, stub.seat * 1.6)

    // the plug's tongue, what goes into the port
    Rectangle {
        x: Math.round((stub.width - width) / 2)
        y: Math.round((1 - stub.seat) * stub.travel) - 3
        width: Math.round(stub.plugWidth * 0.62)
        height: 6
        radius: 2
        color: Theme.shadowDeep
    }
    ShadowBox {
        id: plug
        x: 0
        y: Math.round((1 - stub.seat) * stub.travel) + 2
        width: stub.plugWidth
        height: stub.plugHeight
        raised: true
        baseRadius: 5
        surfaceColor: stub.ground
        backgroundColor: Theme.buttonPlateau
        shadowWidth: 4
        bevelWidth: 1.5
    }
    Rectangle {
        x: Math.round((stub.width - stub.cordWidth) / 2)
        y: plug.y + plug.height - 1
        width: stub.cordWidth
        height: Math.max(0, stub.height - y)
        color: Theme.border
    }
}
