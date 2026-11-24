import QtQuick

// a component two modules use (alpha and beta): SHARED
Rectangle {
    id: root
    property real gap: 6
    property real radiusPx: 14
    property int tintCount: 3
    property bool bevel: true
    property string label: "box"
    property color accent: Theme.accent
    property color fill: "#E6E9F0"
    property real ratio: root.gap * 2
    property real auto: -1          // -1: the config decides
    readonly property real fixed: 5
    property alias inner: innerRect
    property real noDefault
    Rectangle {
        id: innerRect
        radius: root.radiusPx
    }
}
