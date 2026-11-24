import QtQuick

import "../components"

// =============================================================================
// AppIcon.qml -- an app's mark: the icon the active icon theme gives it, as it is drawn (AppIcons / IconResolve.js choose which).
//
//   AppIcon { size: 40; icon: facts.icon; kind: facts.kind; appId: facts.desktopId }       // a launcher row
//   AppIcon { size: 22; cls: row.cls; appId: info.desktopId; icon: info.icon }             // a window class (screentime, the title)
//
// A plain Image of the file the theme names, decoded at the size it is seen at (`DeviceScale`: the glass's pixels, never the design's).
// No processing, no cache of ours: the pixmap cache is Qt's. `~desktop` and `~locked` are the Arch mark; a name the theme lacks is the
// one fallback icon (never Quickshell's checkerboard). `ready` is true once the picture is decoded.
// =============================================================================
Item {
    id: root

    // The window class ("~desktop": no window; "~locked": the locked face), the desktop id, the Icon= value / `# icon:` header, and the
    // launcher's row kind. Any may be empty.
    property string cls: ""
    property string appId: ""
    property string icon: ""
    property string kind: ""
    // Nothing resolved -> the Arch mark, not the generic fallback (the window title).
    property bool archFallback: false
    property int size: 40
    // Decode synchronously (the default: a row shows its icon in the frame it appears) or on the image thread.
    property bool asynchronous: false
    // Device pixels per item pixel; -1 finds it (DeviceScale).
    property real renderScale: -1

    readonly property var _r: AppIcons.resolve({ cls: root.cls, appId: root.appId, icon: root.icon, kind: root.kind, archFallback: root.archFallback })
    readonly property string source: root._r.url
    readonly property string how: root._r.how
    readonly property bool ready: img.status === Image.Ready
    readonly property alias image: img

    implicitWidth: root.size
    implicitHeight: root.size

    DeviceScale {
        id: dev
    }
    readonly property real _scale: root.renderScale > 0 ? root.renderScale : dev.value
    readonly property int _px: Math.max(1, Math.ceil(root.size * root._scale - 1e-3))

    Image {
        id: img
        anchors.fill: parent
        source: root.source
        sourceSize: Qt.size(root._px, root._px)
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: false
        asynchronous: root.asynchronous
        cache: true
    }
}
