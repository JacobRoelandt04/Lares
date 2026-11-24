pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// DesktopInpaint.qml -- the held desktop frame with the shell's own surfaces
// (the bars, the popup) rebuilt from what lies around them, so the still that
// the veil rises over holds no copy of a popup that later changes size. See
// shaders/lock_inpaint.frag for the rebuild.
//
// `rects` is what the host hands the lock as `hints`: [x, y, w, h] in this
// item's px. At most eight take part; a ninth and beyond are merged into the
// eighth's bounding box (the fill only ever gets larger: it fails closed).
// With `layer` on, this item is a texture provider (the lock's `still`).
// =============================================================================
ShaderEffect {
    id: root

    property Item src: null
    property var rects: []
    // grow every rectangle by this many px: shadows, antialiasing, a popup's
    // rounded corner that the hint rectangle does not follow
    property real pad: 6
    property real grain: 0.1

    readonly property var _r: {
        const out = [];
        for (let i = 0; i < root.rects.length; ++i) {
            const r = root.rects[i];
            if (!r || r.length < 4)
                continue;
            if (out.length < 8) {
                out.push([r[0], r[1], r[2], r[3]]);
            } else {
                const l = out[7];
                const x0 = Math.min(l[0], r[0]);
                const y0 = Math.min(l[1], r[1]);
                const x1 = Math.max(l[0] + l[2], r[0] + r[2]);
                const y1 = Math.max(l[1] + l[3], r[1] + r[3]);
                out[7] = [x0, y0, x1 - x0, y1 - y0];
            }
        }
        return out;
    }
    property vector2d size: Qt.vector2d(root.width, root.height)
    property real count: root._r.length
    function _v(i: int): vector4d {
        const r = root._r[i];
        return r ? Qt.vector4d(r[0], r[1], r[2], r[3]) : Qt.vector4d(0, 0, 0, 0);
    }
    property vector4d r0: root._v(0)
    property vector4d r1: root._v(1)
    property vector4d r2: root._v(2)
    property vector4d r3: root._v(3)
    property vector4d r4: root._v(4)
    property vector4d r5: root._v(5)
    property vector4d r6: root._v(6)
    property vector4d r7: root._v(7)

    // The ROOT of this file: a literal path would resolve against the file that instantiates it, so the path is a Qt.resolvedUrl, and

    // `source` is declared for Qt's built-in shader, which samples it and which the effect can hold before that binding lands.

    property var source: null

    fragmentShader: Qt.resolvedUrl("../shaders/lock_inpaint.frag.qsb")
}
