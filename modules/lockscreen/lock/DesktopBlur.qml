pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// DesktopBlur.qml -- Hyprland's own lock blur, drawn by us, so the desktop can
// be blurred BEFORE the compositor's blur takes over and nothing shows at the
// handover.
//
// The lock's first frame is the live sharp desktop, and the compositor's blur
// (session_lock_blur) cannot animate: it is on or off. So the blur-in is drawn
// here over a capture of the sharp desktop (S0), from sharp to the strength the
// compositor's blur has, and then S0 is faded away onto the compositor's live
// blur. For that to be invisible the two must be the same picture, which is why
// this is not MultiEffect (its blur reaches ~10 px; the compositor's reaches
// ~150): it is the compositor's algorithm, dual Kawase, size `size`, four
// passes, then its contrast and grain -- see shaders/lock_kawase_*.frag.
//
// Four downsamples (1/2 .. 1/16 of the device pixels), three upsamples, and the
// last upsample IS this item (it carries the grade and the mix with the sharp
// source). Intermediate passes are layers, hidden: a ShaderEffect source item
// is rendered while invisible.
//
// `strength` 0..1 drives both the tap radius and the share of the sharp source,
// so the picture defocuses rather than dissolves; at 0 it IS the source
// (opaque, pixel for pixel), at 1 it is the compositor's blur. Nothing here
// animates: the host animates `strength`.
// =============================================================================
Item {
    id: root

    // The picture to blur: a texture provider (a ScreencopyView).
    property Item source: null
    // 0..1
    property real strength: 0
    // decoration:blur:size of the user's config (the test config: 10)
    property real size: 10
    // Hyprland's blur-finish defaults (contrast) and the config's noise
    property real contrast: 0.8916
    property real grain: 0.1
    // share of the sharp source left at strength 1 (0 = the pure blur)
    readonly property real _mix: Math.min(1, root.strength * 3)

    readonly property real _dpr: root.Window.window ? root.Window.window.devicePixelRatio : 1
    readonly property real _pw: Math.max(16, Math.round(root.width * root._dpr))
    readonly property real _ph: Math.max(16, Math.round(root.height * root._dpr))
    readonly property real _radius: root.size * root.strength

    function _tw(level: int): real {
        return Math.max(1, Math.ceil(root._pw / Math.pow(2, level)));
    }
    function _th(level: int): real {
        return Math.max(1, Math.ceil(root._ph / Math.pow(2, level)));
    }

    component Down: ShaderEffect {
        required property int level
        property Item src: null
        property vector2d halfpixel: Qt.vector2d(0.5 / root._tw(level), 0.5 / root._th(level))
        property real radius: root._radius
        anchors.fill: parent
        visible: false
        layer.enabled: true
        layer.smooth: true
        layer.textureSize: Qt.size(root._tw(level), root._th(level))
        fragmentShader: "../shaders/lock_kawase_down.frag.qsb"
    }

    component Up: ShaderEffect {
        required property int level
        property Item src: null
        property Item sharp: null
        property vector2d halfpixel: Qt.vector2d(0.5 / root._tw(level), 0.5 / root._th(level))
        property real radius: root._radius
        property real grade: level === 0 ? 1 : 0
        property real mixw: root._mix
        property real contrast: root.contrast
        property real grain: root.grain
        property vector2d texSize: Qt.vector2d(root._pw, root._ph)
        anchors.fill: parent
        fragmentShader: "../shaders/lock_kawase_up.frag.qsb"
    }

    Down {
        id: d1
        level: 1
        src: root.source
    }
    Down {
        id: d2
        level: 2
        src: d1
    }
    Down {
        id: d3
        level: 3
        src: d2
    }
    Down {
        id: d4
        level: 4
        src: d3
    }
    Up {
        id: u3
        level: 3
        src: d4
        sharp: root.source
        visible: false
        layer.enabled: true
        layer.smooth: true
        layer.textureSize: Qt.size(root._tw(3), root._th(3))
    }
    Up {
        id: u2
        level: 2
        src: u3
        sharp: root.source
        visible: false
        layer.enabled: true
        layer.smooth: true
        layer.textureSize: Qt.size(root._tw(2), root._th(2))
    }
    Up {
        id: u1
        level: 1
        src: u2
        sharp: root.source
        visible: false
        layer.enabled: true
        layer.smooth: true
        layer.textureSize: Qt.size(root._tw(1), root._th(1))
    }
    Up {
        level: 0
        src: u1
        sharp: root.source
    }
}
