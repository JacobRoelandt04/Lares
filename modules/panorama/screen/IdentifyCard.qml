import QtQuick

import "../../common/theme"
import "../../common/components"
import ".."

// =============================================================================
// IdentifyCard.qml -- docs/contracts/panorama.md section 7. An Item laid over a screen's `lares-bar` window while
// `service.identify === screenName`: an accent ring at the screen's edge and a centred card (label, W x H @ Hz, scale). A presence fade
// (`style.fadeMs`) -- no window, no remap -- and nothing is built while it is gone. The host skips it while its window is frozen.
// =============================================================================
Item {
    id: root

    property var service: null
    property string screenName: ""
    property PanoramaStyle style: PanoramaStyle {}
    property string fontFamily: "Inter"

    readonly property bool wanted: !!root.service && root.screenName !== "" && root.service.identify === root.screenName
    readonly property var out: root.service && root.service.displays ? (root.service.displays.find(d => d.name === root.screenName) ?? null) : null
    property real presence: root.wanted ? 1 : 0
    Behavior on presence {
        NumberAnimation {
            duration: root.style.fadeMs
            easing.type: Easing.OutCubic
        }
    }
    visible: root.presence > 0.001
    opacity: root.presence
    enabled: false

    Rectangle {
        anchors.fill: parent
        color: "transparent"
        border.width: root.style.identifyRing
        border.color: Theme.accent
    }

    readonly property string _modeText: {
        if (!root.out) return "";
        return root.out.width + " × " + root.out.height + " @ " + (Math.round(root.out.refresh * 100) / 100) + " Hz  ·  ×" + (Math.round(root.out.scale * 1000) / 1000);
    }

    ShadowBox {
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        width: root.style.identifyCardW
        height: root.style.identifyCardH
        raised: true
        baseRadius: root.style.cardRadius
        bevelWidth: 1.5
        shadowWidth: 5
        surfaceColor: Theme.surface
        backgroundColor: Theme.buttonPlateau
        bevelColor: Theme.buttonBevel
        shadowColor: Theme.buttonShadow
        shadowToAlpha: true
        Column {
            anchors.centerIn: parent
            spacing: 6
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.out ? root.out.label : root.screenName
                color: Theme.textPrimary
                font.family: root.fontFamily
                font.pixelSize: root.style.identifyNameSize
                font.bold: true
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root._modeText
                color: Theme.textMuted
                font.family: root.fontFamily
                font.pixelSize: root.style.bodySize
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.screenName
                color: Theme.textFaint
                font.family: root.fontFamily
                font.pixelSize: root.style.figureSize
            }
        }
    }
}
