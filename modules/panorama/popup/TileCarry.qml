import QtQuick

// =============================================================================
// TileCarry.qml -- where one tile is DRAWN: its target plus an offset that eases to nothing on ONE clock (`f`, 0 -> 1).
//
//   place(x, y, w, h)       the first placement: no ease
//   moveTo(x, y, w, h, ms)  a new target: the picture stays where it is drawn and glides to it (a drop, a resize, a snap)
//   follow(x, y)            a carried tile's target follows the pointer; whatever offset is left keeps fading, so a tile that
//                           leaves the magnet is eased off it and the pointer's motion is never the thing eased
//
// The offset is kept RELATIVE to the target, so a target that moves every frame (the pointer) still reads the one clock; a
// Behavior on x would restart on every frame and never tick (CLAUDE.md: "A Behavior whose binding changes every frame").
// =============================================================================
Item {
    id: carry

    visible: false
    width: 0
    height: 0

    property real tx: 0
    property real ty: 0
    property real tw: 0
    property real th: 0
    property real ox: 0
    property real oy: 0
    property real ow: 0
    property real oh: 0
    property real f: 1

    readonly property real cx: carry.tx + carry.ox * (1 - carry.f)
    readonly property real cy: carry.ty + carry.oy * (1 - carry.f)
    readonly property real cw: carry.tw + carry.ow * (1 - carry.f)
    readonly property real ch: carry.th + carry.oh * (1 - carry.f)
    readonly property bool moving: anim.running

    function place(x: real, y: real, w: real, h: real): void {
        anim.stop();
        carry.tx = x; carry.ty = y; carry.tw = w; carry.th = h;
        carry.ox = 0; carry.oy = 0; carry.ow = 0; carry.oh = 0;
        carry.f = 1;
    }

    function moveTo(x: real, y: real, w: real, h: real, ms: int): void {
        const dx = carry.cx, dy = carry.cy, dw = carry.cw, dh = carry.ch;
        anim.stop();
        carry.tx = x; carry.ty = y; carry.tw = w; carry.th = h;
        carry.ox = dx - x; carry.oy = dy - y; carry.ow = dw - w; carry.oh = dh - h;
        carry.f = 0;
        anim.duration = Math.max(1, ms);
        anim.restart();
    }

    function follow(x: real, y: real): void {
        carry.tx = x;
        carry.ty = y;
    }

    NumberAnimation {
        id: anim
        target: carry
        property: "f"
        from: 0
        to: 1
        easing.type: Easing.OutCubic
    }
}
