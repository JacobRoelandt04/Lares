import QtQuick

import "../../common/theme"

// =============================================================================
// ForgetButton.qml -- a panel button for a destructive action that has no undo (a saved network and its password, a paired device).
// The first click arms it: the label reads "Forget?" in the warning ink; a second click within 2.5 s acts (`forgetRequested`), else
// it disarms by itself. The wider word's width is reserved so arming never shifts its row. A host that closes the row disarms it
// by `disarm()` (or by turning `live` off).
// =============================================================================
PanelButton {
    id: btn

    signal forgetRequested

    // false while the row it belongs to is closed: the arm never outlives it
    property bool live: true
    property bool armed: false

    function disarm() {
        btn.armed = false;
        disarmTimer.stop();
    }

    text: btn.armed ? "Forget?" : "Forget"
    textColor: btn.armed ? Theme.warn : Theme.textPrimary
    onLiveChanged: if (!btn.live) btn.disarm()
    onVisibleChanged: if (!btn.visible) btn.disarm()
    minWidth: Math.ceil(reserve.advanceWidth) + 2 * btn.horizontalPadding + 2

    TextMetrics {
        id: reserve
        font.family: btn.fontFamily
        font.pixelSize: btn.fontPixelSize
        font.bold: true
        text: "Forget?"
    }

    onClicked: {
        if (!btn.armed) {
            btn.armed = true;
            disarmTimer.restart();
            return;
        }
        btn.disarm();
        btn.forgetRequested();
    }

    Timer {
        id: disarmTimer
        interval: 2500
        onTriggered: btn.armed = false
    }
}
