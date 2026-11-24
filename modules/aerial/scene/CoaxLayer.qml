pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes

import "AerialCamera.js" as Cam

// =============================================================================
// CoaxLayer.qml -- the two coax cables (MAIN black, AUX grey), each ONE short arch from its MHF4 connector into a grommet in the board right behind the card: a smooth cubic Bezier in board
// space (it leaves the connector's back side rising, tilts with the card, and goes straight down into the hole), projected through the scene's camera and stroked in four
// passes (a soft contact shadow on the board, the jacket, a lighter core, a thin highlight toward the light) so the section reads round. Boxes could only draw it as a staircase.
// It stands over the board and under the holograms: the globe and the dome lie in FRONT of the cable (the cable is behind them in the picture's depth), the card's label is above it.
// THE CARD HIDES WHAT IS BEHIND IT (round 6, the user: "the cables should bend up and around the card"): a stretch of cable whose ray toward the camera meets the card (its
// PCB slab or the RF shield, in the card's own frame) is not drawn. Lifted, the arch runs down behind the raised edge and the card covers its bend; seated, the card covers
// a sliver where the cable drops behind its back edge. The cut is found by bisection on the curve (a 1/2048 of it), so it lands on the card's silhouette, not on a sample.
// A few Shapes, nothing animated by itself: it follows `cardTilt` and the camera only.
// =============================================================================
Item {
    id: root

    property var geo: null
    property var cam: ({ s: 5, ox: 0, oy: 0 })
    property real cardTilt: 0
    property color mainColour: "#1c1c1e"
    property color auxColour: "#8a8c90"
    property real power: 1
    property vector2d lightShift: Qt.vector2d(-0.5, -0.85)     // the screen direction the highlight leans to (toward the light)

    readonly property int _n: 30
    readonly property real _w: root.geo ? Math.max(2, 2 * root.geo.COAX.r * root.cam.s) : 4

    // the centre line of one cable in board mm at n + 1 samples (0 main, 1 aux): ONE arch -- out of the connector's back, rising (in the card's own frame, so it tilts with the
    // card), over and straight down into its grommet in the board behind the card. A lifted card pulls more cable out of the hole: the arch grows with the distance.
    function line3(which: int): var {
        const out = [];
        for (let i = 0; i <= root._n; i++)
            out.push(root.at(which, i / root._n));
        // (what is under the board is not drawn: the cable ends at the grommet's mouth)
        return out.filter(p => p[1] >= -0.05);
    }
    // the curve itself at t (0 the connector .. 1 the grommet), board mm (line3 samples it)
    function at(which: int, t: real): var {
        const G = root.geo, C = G.CARD, cx = which === 0 ? G.MHF.main : G.MHF.aux, h = G.CUTS.grommets[which];
        const yTop = C.yPcb + C.pcb;
        const p0 = Cam.tilt(G, [C.x0 + cx[0], yTop + 0.42, C.z0 + cx[1] - G.MHF.body / 2 + 0.2], root.cardTilt);
        const p3 = [h[0], -0.6, h[1]];
        const dist = Math.hypot(p0[0] - p3[0], p0[1], p0[2] - p3[2]);
        const d = Cam.tiltDir([0, 0.5, -0.866], root.cardTilt), k = 1.3 + 0.3 * dist;
        const p1 = [p0[0] + d[0] * k, p0[1] + d[1] * k, p0[2] + d[2] * k];
        const p2 = [p3[0], 1.4 + 0.42 * dist, p3[2] - 0.25];
        const u = 1 - t, a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, f = t * t * t;
        return [a * p0[0] + b * p1[0] + c * p2[0] + f * p3[0], a * p0[1] + b * p1[1] + c * p2[1] + f * p3[1], a * p0[2] + b * p1[2] + c * p2[2] + f * p3[2]];
    }
    // is a board point hidden by the card? Its ray toward the camera, in the card's own (untilted) frame, against the PCB slab and the shield's box
    readonly property var _toCam: Cam.tiltDir(Cam.C, -root.cardTilt)
    function hidden(p: var): bool {
        const G = root.geo, C = G.CARD, S = G.SHIELD, yTop = C.yPcb + C.pcb, q = Cam.tilt(G, p, -root.cardTilt), v = root._toCam;
        const boxes = [[C.x0, C.yPcb, C.z0, C.x0 + C.w, yTop, C.z0 + C.h],
                       [C.x0 + S.x0, yTop, C.z0 + S.y0, C.x0 + S.x1, yTop + S.h, C.z0 + S.y1]];
        for (let i = 0; i < boxes.length; i++) {
            const b = boxes[i];
            let t0 = 1e-4, t1 = 1e9, ok = true;
            for (let k = 0; k < 3 && ok; k++) {
                const lo = b[k], hi = b[k + 3];
                if (Math.abs(v[k]) < 1e-9) {
                    if (q[k] < lo || q[k] > hi)
                        ok = false;
                } else {
                    let ta = (lo - q[k]) / v[k], tb = (hi - q[k]) / v[k];
                    if (ta > tb) { const x = ta; ta = tb; tb = x; }
                    t0 = Math.max(t0, ta);
                    t1 = Math.min(t1, tb);
                    if (t0 > t1)
                        ok = false;
                }
            }
            if (ok)
                return true;
        }
        return false;
    }
    // what is drawn of a point: under the board's face, or behind the card, is not
    function _shown(p: var): bool {
        return p[1] >= -0.05 && !root.hidden(p);
    }
    // THE VISIBLE RUNS of one cable: lists of board points, the cuts bisected onto the card's silhouette (or the board's face). `ground`: only the foot near the board (y < 1.1),
    // projected straight down onto it (the contact shadow; a shadow behind the card is hidden too)
    function runs3(which: int, ground: bool): var {
        if (!root.geo)
            return [];
        const pt = t => {
            const p = root.at(which, t);
            return ground ? [p[0], 0, p[2]] : p;
        };
        const ok = t => {
            const p = root.at(which, t);
            if (ground && p[1] >= 1.1)
                return false;
            return root._shown(ground ? [p[0], 0, p[2]] : p) && p[1] >= -0.05;
        };
        const cut = (ta, tb, va) => {
            for (let i = 0; i < 11; i++) {
                const m = (ta + tb) / 2;
                if (ok(m) === va) ta = m; else tb = m;
            }
            return va ? ta : tb;
        };
        const out = [];
        let cur = null, prevT = 0, prevV = ok(0);
        if (prevV)
            cur = [pt(0)];
        for (let i = 1; i <= root._n; i++) {
            const t = i / root._n, v = ok(t);
            if (v !== prevV) {
                const tc = cut(prevT, t, prevV);
                if (prevV) {
                    cur.push(pt(tc));
                    out.push(cur);
                    cur = null;
                } else {
                    cur = [pt(tc)];
                }
            }
            if (v)
                cur.push(pt(t));
            prevT = t;
            prevV = v;
        }
        if (cur && cur.length > 1)
            out.push(cur);
        return out;
    }
    function runs(which: int, dx: real, dy: real, ground: bool): var {
        if (!root.geo || !(root.cam.s > 1))
            return [];
        return root.runs3(which, ground).map(run => run.map(p => {
            const q = Cam.project(p, root.cam);
            return Qt.point(q.x + dx, q.y + dy);
        }));
    }
    // the projected polyline, moved by (dx, dy) px; ground = true projects each sample straight down onto the board (the whole curve, hidden stretches too: the probes' measure)
    function path(which: int, dx: real, dy: real, ground: bool): var {
        if (!root.geo || !(root.cam.s > 1))
            return [];
        // (the contact shadow is only where the cable is near the board: the foot at its grommet. A shadow under the whole arch was a grey bar on the board -- the user's
        // "gray serrated shape" beside the cables)
        return root.line3(which).filter(p => !ground || p[1] < 1.1).map(p => {
            const q = Cam.project(ground ? [p[0], 0, p[2]] : p, root.cam);
            return Qt.point(q.x + dx, q.y + dy);
        });
    }
    function _tint(c: color, a: real): color {
        return Qt.tint(c, Qt.rgba(1, 1, 1, a));
    }
    readonly property var _pm: [root.runs(0, 0, 0, false), root.runs(1, 0, 0, false)]
    readonly property var _sh: [root.runs(0, 0.35 * root._w, 0.3 * root._w, true), root.runs(1, 0.35 * root._w, 0.3 * root._w, true)]
    readonly property var _hi: [root.runs(0, root.lightShift.x * 0.22 * root._w, root.lightShift.y * 0.22 * root._w, false), root.runs(1, root.lightShift.x * 0.22 * root._w, root.lightShift.y * 0.22 * root._w, false)]
    readonly property var _mid: [root.runs(0, root.lightShift.x * 0.12 * root._w, root.lightShift.y * 0.12 * root._w, false), root.runs(1, root.lightShift.x * 0.12 * root._w, root.lightShift.y * 0.12 * root._w, false)]

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        opacity: Math.max(0, Math.min(1, root.power * 1.4))
        // contact shadows
        ShapePath {
            fillColor: "transparent"
            strokeColor: Qt.rgba(0, 0, 0, 0.13)
            strokeWidth: root._w * 1.25
            capStyle: ShapePath.FlatCap
            joinStyle: ShapePath.RoundJoin
            PathMultiline { paths: root._sh[0] }
        }
        ShapePath {
            fillColor: "transparent"
            strokeColor: Qt.rgba(0, 0, 0, 0.13)
            strokeWidth: root._w * 1.25
            capStyle: ShapePath.FlatCap
            joinStyle: ShapePath.RoundJoin
            PathMultiline { paths: root._sh[1] }
        }
        // AUX (behind: it lies further from the viewer's side of MAIN)
        ShapePath {
            fillColor: "transparent"
            strokeColor: Qt.darker(root.auxColour, 1.12)
            strokeWidth: root._w
            capStyle: ShapePath.FlatCap
            joinStyle: ShapePath.RoundJoin
            PathMultiline { paths: root._pm[1] }
        }
        ShapePath {
            fillColor: "transparent"
            strokeColor: root.auxColour
            strokeWidth: root._w * 0.66
            capStyle: ShapePath.FlatCap
            joinStyle: ShapePath.RoundJoin
            PathMultiline { paths: root._mid[1] }
        }
        ShapePath {
            fillColor: "transparent"
            strokeColor: root._tint(root.auxColour, 0.5)
            strokeWidth: root._w * 0.22
            capStyle: ShapePath.FlatCap
            joinStyle: ShapePath.RoundJoin
            PathMultiline { paths: root._hi[1] }
        }
        // MAIN
        ShapePath {
            fillColor: "transparent"
            strokeColor: Qt.darker(root.mainColour, 1.2)
            strokeWidth: root._w
            capStyle: ShapePath.FlatCap
            joinStyle: ShapePath.RoundJoin
            PathMultiline { paths: root._pm[0] }
        }
        ShapePath {
            fillColor: "transparent"
            strokeColor: root._tint(root.mainColour, 0.12)
            strokeWidth: root._w * 0.66
            capStyle: ShapePath.FlatCap
            joinStyle: ShapePath.RoundJoin
            PathMultiline { paths: root._mid[0] }
        }
        ShapePath {
            fillColor: "transparent"
            strokeColor: root._tint(root.mainColour, 0.38)
            strokeWidth: root._w * 0.22
            capStyle: ShapePath.FlatCap
            joinStyle: ShapePath.RoundJoin
            PathMultiline { paths: root._hi[0] }
        }
    }
}
