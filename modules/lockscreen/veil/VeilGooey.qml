pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"

// =============================================================================
// VeilGooey.qml -- GOOEY TIDE, a lock veil (contract section 7).
//
// The bar's own material, rising. Blobs of Theme.surface -- raised, with the
// shell's soft drop shadow and bevel highlight -- join by smooth unions exactly
// as the bar and its popups do: they well up from the bottom edge, drift like a
// lava lamp in slow motion, are drawn gently toward the popup (the shell's
// centre of gravity), slide beneath it and, reaching the bar, merge into its
// underside. The popup and the bar are members of the same union, so a blob
// necks out of them. Between the blobs the desktop is dimmed and tinted toward
// the material, so popup and blobs read as one substance.
//
//   keys    a bud swells from the popup's edge and draws back (sixteen at once;
//           past that the oldest shrinks away over `budFade` rather than vanishing)
//   fail    the blobs recoil from the field and shiver, error-tinted, then settle
//   ok      the clear: the material flows up into the bar, blob after blob (1 s, starting at once), and as the
//           last of it goes the dimmed, tinted ground drains with it, the desktop coming back as the tide goes out
//   wake    one slow swell
//   pointer the blobs lean toward it
//   presence  the material POURS in: a front sweeps out of the bar and the popup across the
//             screen (the desktop goes to full veil behind it within a few tens of ms), and
//             each blob swells from a point as the front reaches it
//   opaque  boot: the ground is a quiet sunk tone, the blobs on it
//   no shell  no popup rect (a boot lock before the shell has started; a shell that never comes): nothing to wrap
//           and nothing to be drawn toward, so the blobs keep to their own paths across the screen, and keys only
//           swell them. When a popup arrives the shell JOINS on one clock (`_attach`, OutCubic over
//           `attachSeconds` of veil time): the blobs lean in toward it, each by its own share of the pull, and
//           the shell swells into the union out of nothing (`shellInset`), so the necks reach the popup's edges
//           as it opens. A popup there in the veil's first moments was there from the start (no clock). A popup
//           that GOES takes the shell's silhouette with it in the same frame (the veil draws it under the popup:
//           eased out it is a ghost of the card where the card was); only the blobs' lean eases out.
//
// A pure function of `host` (time, speed, presence, pulses, pointer, opaque,
// dark): it runs no clock of its own, so a resting host renders nothing. One
// ShaderEffect, no arrays. Where each blob is (its path, the pulses' pushes, the welling
// up) is worked out here, once per frame, and handed to the VERTEX stage
// (shaders/veil_gooey.vert) as two vec4 a blob. It evaluates the blobs' smooth distance
// field at the vertices of a coarse grid (a texture would be cheaper still to read but a
// source that re-grabs every tick makes Qt render a second frame per tick), and the
// fragment shader (shaders/veil_gooey.frag) rebuilds the field between them to third
// order and adds what is sharp at full resolution: the popup, the bar and the buds.
// =============================================================================
Item {
    id: root

    // `var`, not LockVeil: the lock loads a veil by URL, and a directory's
    // types resolve there only while some `import` names that directory
    // (LockSurface imports "../veil" for that); `var` keeps a veil loadable
    // either way.
    property var host: null

    // ---- where the shell is (the lock feeds the real popup's rect later) ----
    // The popup (the main stone) and its bar: the host's, else the stage
    // silhouette's geometry.
    property rect stoneRect: root.host && root.host.popupRect.width > 0 ? root.host.popupRect
                                                                        : Qt.rect((root.width - 560) / 2, 24, 560, 660)
    property real stoneRadius: 28
    property rect barRect: root.host && root.host.barRect.width > 0 ? root.host.barRect
                                                                    : Qt.rect((root.width - 1600) / 2, 0, 1600, 40)
    property real barRadius: 20

    // ---- blobs ----
    // The blobs' field is evaluated once to every `fieldCell` x `fieldCell` DEVICE pixels, in the
    // vertex stage, and rebuilt between the vertices to third order (see veil_gooey.vert): the
    // error is under 0.01 px at 10, and a coarser grid shades fewer quads twice.
    property real fieldCell: 16
    // A GridMesh indexes its vertices with 16 bits: at most 65 535 of them, so a larger screen
    // takes a coarser grid (the cell only ever grows).
    readonly property real _cell: Math.max(root.fieldCell, Math.sqrt(root.width * root.height * root._scale * root._scale / 60000))
    property real blobCount: 9
    property real blobScale: 1
    property real wobble: 1
    property real driftScale: 1
    property real smoothK: 190
    property real stoneBlend: 0.8
    property real joinK: 18
    property real pull: 0.55
    // Veil seconds the shell takes to join the union when it arrives (no shell -> shell, and back).
    property real attachSeconds: 1.8
    property real pourSpan: 160
    property real pourFeather: 70

    // ---- lighting ----
    property real shadowSpread: 34
    property real shadowStrength: 0.55
    property real shadowDrop: 10
    property real bevelWidth: 3
    property real bevelStrength: 0.9
    property real lightBias: 0.6
    property real pillow: 0.24

    // ---- ground ----
    property real groundShade: 0.5
    property real groundAlpha: 0.7
    property real groundAlphaDark: 0.6
    property real vignette: 0.5
    property real haloReach: 150
    property real haloStrength: 0.35

    // ---- pulses ----
    property real budSize: 100
    property real budReach: 150
    property real budLife: 2.6
    property real budFade: 0.45
    property real keySwell: 0.04
    property real recoil: 26
    property real shiver: 9
    property real failTint: 0.6
    property real failLife: 1.8
    property real okSeconds: 1.0
    // ---- details (each behind its own switch: strength 0 leaves it out) ----
    property real sheen: 0.7
    property real sheenWidth: 16
    property real sheenTurn: 0.25
    property real wakeSwell: 1
    property real wakeLife: 4.5
    property real pointerLean: 16
    property real pointerReach: 420

    // ---- colours (the shell's tokens) ----
    property color materialColor: Theme.surface
    property color groundColor: Theme.panelSunk
    property color edgeColor: Theme.border
    property color bevelColor: Theme.buttonBevel
    property color shadowColor: Theme.buttonShadow
    property color errorColor: Theme.errorTint

    // ---- what the host says ----
    readonly property real _t: root.host ? root.host.time : 0
    readonly property real _presence: root.host ? root.host.presence : 1
    // The clear's last third runs the entrance's pour backwards: the veil draws only out to a radius from the shell that
    // closes in, so what the blobs leave behind (the bar's own shadow, the halo) goes with them and the veil ends as
    // nothing at all.
    readonly property real _presenceOut: Math.min(root._presence, 1 - root._smooth(0.55, 1, root._fx.ok))
    readonly property bool _opaque: root.host ? root.host.opaque : false
    readonly property bool _dark: root.host ? root.host.dark : false
    readonly property var _pointer: root.host ? root.host.pointer : null
    readonly property real _unit: root.height / 1620
    readonly property real _scale: root.host ? Math.max(0.25, root.host.renderScale) : 1
    // Sixteen buds are drawn; the newest eleven whole, five more are on their way out.
    readonly property int _budSlots: 16
    readonly property int _budFull: 11
    readonly property var _fx: root._compute(root._t, root.host ? root.host.pulses : [])

    // ---- the shell arriving (see "no shell" above) ----
    // A pure function of veil time and the last flip: where the clock stood (from), where it goes (to) and when.
    readonly property bool _shellThere: !!root.host && root.host.popupRect.width > 0
    property real _attachFrom: 1
    property real _attachTo: 1
    property real _attachAt: -1e9
    function _attachAtTime(t) {
        const x = Math.max(0, Math.min(1, (t - root._attachAt) / Math.max(0.05, root.attachSeconds)));
        return root._attachFrom + (root._attachTo - root._attachFrom) * (1 - Math.pow(1 - x, 3));
    }
    readonly property real _attach: root._attachAtTime(root._t)
    // How far the shell's boxes are drawn in (px): beyond half the popup's smaller side plus the merge radius it is gone,
    // and no blob is drawn toward it; 0 once the shell has joined. The entrance's front pours out of the boxes drawn in
    // too: with no shell, out of the top centre rather than a popup's silhouette.
    readonly property real _shellGone: 0.5 * Math.min(root.stoneRect.width, root.stoneRect.height) + root.smoothK * root._unit * root.stoneBlend + 2
    readonly property real _shellInset: root._attachTo === 1 ? (1 - root._attach) * root._shellGone : root._shellGone
    // the shell's own share (the buds that grow out of it): eased in, gone at once
    readonly property real _shellHere: root._attachTo === 1 ? root._attach : 0
    // (the host's time is read itself, never through _t: a handler runs before the bindings on what changed)
    on_ShellThereChanged: {
        const t = root.host ? root.host.time : 0;
        const to = root._shellThere ? 1 : 0;
        // The lock hands the popup rect over a turn after the veil is built: a popup there in the first moments, before
        // any flip, was there from the start.
        if (to === 1 && root._attachAt < -1e8 && t < 0.3) {
            root._attachFrom = 1;
            root._attachTo = 1;
            return;
        }
        const now = root._attachAtTime(t);
        root._attachFrom = now;
        root._attachTo = to;
        root._attachAt = t;
    }
    Component.onCompleted: {
        root._attachFrom = root._shellThere ? 1 : 0;
        root._attachTo = root._attachFrom;
    }

    function _hash(x) {
        const s = Math.sin(x * 127.1 + 311.7) * 43758.5453;
        return s - Math.floor(s);
    }

    // What the pulses ask of the field right now: the buds, the fail, the ok, the
    // wake. A bud's slot is one of `_budSlots`; the newest `_budFull` are drawn whole,
    // and a key older than that shrinks away over `budFade` from the moment the key
    // that crowded it out arrived (so a burst of typing retires the oldest smoothly,
    // never in one frame), and only then loses its slot. Pulses whose time lies ahead
    // of the clock (a seek backwards) count for nothing.
    function _compute(t, pulses) {
        const u = root._unit;
        const sr = root.stoneRect;
        const out = {
            buds: [], budPad: 0, keyEnergy: 0, failPhase: 0, failRecoil: 0, failShiver: 0, failTint: 0,
            ok: 0, wake: 0, field: Qt.point(sr.x + sr.width / 2, sr.y + sr.height * 0.62)
        };
        let seenFail = false, seenOk = false, seenWake = false;
        const keys = [];
        for (let i = (pulses ? pulses.length : 0) - 1; i >= 0; i--) {
            const p = pulses[i];
            const age = t - p.t;
            if (age < 0)
                continue;
            if (p.kind === "key") {
                if (age < root.budLife)
                    keys.push(p);
            } else if (p.kind === "fail" && !seenFail && age < root.failLife) {
                seenFail = true;
                const env = Math.min(1, age / 0.12) * Math.exp(-age / 0.55);
                out.failRecoil = root.recoil * env;
                out.failShiver = root.shiver * env;
                out.failPhase = 2 * Math.PI * 5 * age;
                out.failTint = root.failTint * env;
                out.field = Qt.point(p.x, p.y);
            } else if (p.kind === "ok" && !seenOk) {
                seenOk = true;
                const x = Math.min(1, age / Math.max(0.1, root.okSeconds));
                out.ok = 1 - (1 - x) * (1 - x);      // out-quad: it starts at once and eases to rest, so it reads inside the hold and runs on through the fade
            } else if (p.kind === "wake" && !seenWake && age < root.wakeLife) {
                seenWake = true;
                out.wake = root.wakeSwell * (0.5 - 0.5 * Math.cos(2 * Math.PI * age / root.wakeLife));
            }
        }
        // `keys` is newest first. Key j is crowded out once `_budFull` newer ones exist,
        // that is when key j - _budFull arrived.
        for (let j = 0; j < keys.length && out.buds.length < root._budSlots; j++) {
            const p = keys[j];
            let w = 1;
            if (j >= root._budFull)
                w = 1 - root._smooth(0, Math.max(0.05, root.budFade), t - keys[j - root._budFull].t);
            if (w <= 0)
                continue;
            const x = (t - p.t) / root.budLife;
            const grow = Math.sin(Math.PI * Math.pow(x, 0.6)) * w;
            const h1 = root._hash(p.t), h2 = root._hash(p.t + 7.3), h3 = root._hash(p.t + 3.1);
            let ax, ay, dx, dy;
            if (h1 < 0.3) {
                ax = sr.x; ay = sr.y + sr.height * (0.25 + 0.65 * h2); dx = -1; dy = 0;
            } else if (h1 < 0.6) {
                ax = sr.x + sr.width; ay = sr.y + sr.height * (0.25 + 0.65 * h2); dx = 1; dy = 0;
            } else {
                ax = sr.x + sr.width * (0.15 + 0.7 * h2); ay = sr.y + sr.height; dx = 0; dy = 1;
            }
            // (out of a shell that is there: no buds while it is not)
            const r = root.budSize * u * grow * (0.75 + 0.5 * h3) * root._shellHere;
            const off = root.budReach * u * grow * 0.6;
            out.buds.push(Qt.vector4d(ax + dx * off, ay + dy * off, r, 0));
            out.budPad = Math.max(out.budPad, off + r);
            out.keyEnergy += grow;
            if (!seenFail)
                out.field = Qt.point(p.x, p.y);
        }
        return out;
    }

    // The nine blobs: home x, home y (fractions of the item), sway x, sway y (px at
    // 1620 high), radius, angular rate, phase, stretch, rank (0..1: the order they
    // well up in). The two big low ones make the tide along the bottom edge.
    readonly property var _table: [
        [0.16, 1.06, 160, 170, 420, 0.057, 0.6, 1.10, 0.0],
        [0.86, 1.08, 170, 190, 470, 0.048, 2.4, 1.00, 0.125],
        [0.28, 0.72, 220, 520, 200, 0.0748, 4.1, 1.2, 0.25],
        [0.74, 0.62, 230, 560, 240, 0.064, 1.3, 0.9, 0.375],
        [0.52, 1.00, 280, 300, 340, 0.052, 3.3, 1.1, 0.5],
        [0.07, 0.48, 120, 460, 140, 0.09, 5.5, 1.3, 0.625],
        [0.94, 0.40, 110, 500, 170, 0.083, 0.2, 1.1, 0.75],
        [0.36, 0.30, 240, 600, 120, 0.098, 2.9, 0.85, 0.875],
        [0.64, 0.86, 200, 520, 170, 0.07, 4.8, 1.2, 1.0]
    ]

    function _smooth(a, b, x) {
        const t = Math.max(0, Math.min(1, (x - a) / (b - a)));
        return t * t * (3 - 2 * t);
    }

    // One blob's place at veil time t: its path, drawn toward the popup, breathing,
    // swelling on a wake, flowing into the bar on an ok, recoiling from the field
    // and shivering on a fail, leaning to the pointer, welling up from below.
    // Returns [cx, cy, r, stretch, cos tilt, sin tilt]; r 0 = not drawn.
    function _blob(i, t, fxs) {
        const row = root._table[i];
        if (i >= root.blobCount)
            return Qt.vector4d(0, 0, 0, 1);
        const u = root._unit, W = root.width, H = root.height;
        const hx = row[0], hy = row[1], ax = row[2], ay = row[3], w = row[5], ph = row[6], rank = row[8];
        const sr = root.stoneRect, br = root.barRect;
        const scx = sr.x + sr.width / 2;
        let cx = W * hx + ax * u * Math.sin(w * 0.83 * t + ph * 1.7);
        let cy = H * hy + ay * u * (Math.sin(w * t + ph) + 0.28 * Math.sin(w * 2.6 * t + ph * 2.3));
        const pl = root.pull * root._attach * (0.5 + 0.5 * Math.sin(w * 0.37 * t + ph * 3.1));
        cx += (scx + (hx - 0.5) * sr.width * 1.5 - cx) * pl;
        let r = row[4] * u * root.blobScale * (1 + 0.07 * root.wobble * Math.sin(w * 2.1 * t + ph * 5)) * (1 + 0.16 * fxs.wake) * (1 + root.keySwell * Math.min(1, fxs.keyEnergy));
        cy -= 26 * u * fxs.wake * (0.4 + rank);

        // Accepted: the material flows up and into the bar, blob after blob.
        const e = root._smooth(rank * 0.45, rank * 0.45 + 0.55, fxs.ok);
        cy += (br.y + br.height + r * 0.45 - cy) * e;
        cx += (scx + (hx - 0.5) * br.width * 0.5 - cx) * e * 0.6;
        // ...and once it has arrived it is taken up into the bar, its radius running out as the blob joins the union
        r *= 1 - root._smooth(0.55, 1, e);

        // Failed: recoil from the field, then a shiver that dies away.
        const fdx = cx - fxs.field.x, fdy = cy - fxs.field.y;
        const fl = Math.max(Math.hypot(fdx, fdy), 1);
        const ax_ = fdx / fl, ay_ = fdy / fl;
        const sh = Math.sin(fxs.failPhase + rank * 9 + ph);
        cx += ax_ * fxs.failRecoil * u - ay_ * fxs.failShiver * u * sh;
        cy += ay_ * fxs.failRecoil * u + ax_ * fxs.failShiver * u * sh;

        // Pointer: a lean, largest at the reach from it.
        const pt = root._pointer;
        if (pt) {
            const reach = Math.max(root.pointerReach * u, 1);
            const pdx = pt.x - cx, pdy = pt.y - cy;
            const k = root.pointerLean * u * Math.exp(-Math.hypot(pdx, pdy) / reach) / reach;
            cx += pdx * k;
            cy += pdy * k;
        }

        // Pouring in (presence): the front's radius out of the shell, and this blob swelling
        // from a point as the front reaches its centre.
        if (root._presence < 0.9999) {
            const fr = root._presence * (Math.hypot(W, H) + root.pourFeather * u);
            const sb = root.stoneRect, bb = root.barRect;
            const dst = Math.min(root._boxDist(cx, cy, sb, root._shellInset), root._boxDist(cx, cy, bb, root._shellInset));
            r *= root._smooth(0, 1, (fr - dst) / Math.max(1, root.pourSpan * u + 0.5 * r));
        }

        const sy = (1 + (row[7] - 1) * root.wobble) * (1 + 0.05 * root.wobble * Math.sin(w * 1.7 * t + ph));
        return Qt.vector4d(cx, cy, r, sy);
    }
    // The distance from a box drawn in by `inset` on every side (a box drawn in past its half size is its centre line).
    function _boxDist(x, y, rc, inset) {
        const hw = Math.max(0, rc.width / 2 - inset), hh = Math.max(0, rc.height / 2 - inset);
        const dx = Math.max(Math.abs(x - rc.x - rc.width / 2) - hw, 0), dy = Math.max(Math.abs(y - rc.y - rc.height / 2) - hh, 0);
        return Math.hypot(dx, dy);
    }
    function _tilt(i, t) {
        const row = root._table[i];
        const ang = 0.5 * root.wobble * Math.sin(row[5] * 0.9 * t + row[6] * 2);
        return Qt.vector4d(Math.cos(ang), Math.sin(ang), 0, 0);
    }
    readonly property var _blobs: {
        const t = root._t * root.driftScale, fxs = root._fx, out = [];
        for (let i = 0; i < 9; i++)
            out.push({ b: root._blob(i, t, fxs), t: root._tilt(i, t) });
        return out;
    }

    function _mix(a, b, f) {
        return Qt.rgba(a.r + (b.r - a.r) * f, a.g + (b.g - a.g) * f, a.b + (b.b - a.b) * f, 1);
    }

    // The buds the slots read: a fresh array every tick while one lives; none, the same empty one, so the sixteen slots'
    // bindings do not run again (a fresh object runs them all).
    readonly property var _buds: root._fx.buds.length > 0 ? root._fx.buds : root._noBuds
    readonly property var _noBuds: []
    function _bud(i) {
        const b = root._buds;
        return i < b.length ? b[i] : Qt.vector4d(0, 0, 0, 0);
    }

    ShaderEffect {
        id: fx
        anchors.fill: parent
        visible: root._opaque || root._presenceOut > 0.001
        blending: true
        fragmentShader: "../shaders/veil_gooey.frag.qsb"
        // The blobs' field is evaluated at the vertices of a coarse grid (veil_gooey.vert), one
        // vertex to every `fieldCell` device pixels, and rebuilt between them in the fragment.
        vertexShader: "../shaders/veil_gooey.vert.qsb"
        mesh: GridMesh {
            resolution: Qt.size(Math.max(2, Math.ceil(root.width * root._scale / root._cell) + 1), Math.max(2, Math.ceil(root.height * root._scale / root._cell) + 1))
        }

        property vector2d size: Qt.vector2d(root.width, root.height)
        property vector4d stone: Qt.vector4d(root.stoneRect.x, root.stoneRect.y, root.stoneRect.x + root.stoneRect.width, root.stoneRect.y + root.stoneRect.height)
        // The bar continues above the item so its top corners are never met.
        property vector4d bar: Qt.vector4d(root.barRect.x, Math.min(root.barRect.y, 0) - 400, root.barRect.x + root.barRect.width, root.barRect.y + root.barRect.height)
        property real unit: root._unit
        property real presence: root._presenceOut
        property real pourFeather: root.pourFeather
        property real opaqueMode: root._opaque ? 1 : 0
        property real stoneR: root.stoneRadius
        property real barR: root.barRadius
        property real joinK: root.joinK
        property real smoothK: root.smoothK * root._unit
        property real stoneBlend: root.stoneBlend
        property real shellInset: root._shellInset
        property vector4d light1: Qt.vector4d(root.shadowSpread, root.shadowStrength, root.bevelWidth, root.bevelStrength)
        property vector4d light2: Qt.vector4d(root.lightBias, root.pillow, root.shadowDrop, 0)
        // the ground drains as the tide goes: the dimming, the halo round the shell and the vignette follow the blobs' last third
        readonly property real _keep: 1 - root._smooth(0.3, 0.95, root._fx.ok)
        property vector4d ground1: Qt.vector4d((root._dark ? root.groundAlphaDark : root.groundAlpha) * fx._keep, root.vignette, root.haloReach, root.haloStrength * fx._keep)
        property color cMat: root.materialColor
        property color cBevel: root.bevelColor
        property color cShadow: root.shadowColor
        property color cGround: root._mix(root.groundColor, root.edgeColor, root.groundShade)
        property color cEdge: root._mix(root.groundColor, root.edgeColor, Math.min(1, root.groundShade + 0.4))
        property color cErr: root.errorColor
        property vector4d bud0: root._bud(0)
        property vector4d bud1: root._bud(1)
        property vector4d bud2: root._bud(2)
        property vector4d bud3: root._bud(3)
        property vector4d bud4: root._bud(4)
        property vector4d bud5: root._bud(5)
        property vector4d bud6: root._bud(6)
        property vector4d bud7: root._bud(7)
        property vector4d bud8: root._bud(8)
        property vector4d bud9: root._bud(9)
        property vector4d bud10: root._bud(10)
        property vector4d bud11: root._bud(11)
        property vector4d bud12: root._bud(12)
        property vector4d bud13: root._bud(13)
        property vector4d bud14: root._bud(14)
        property vector4d bud15: root._bud(15)
        property real failTint: root._fx.failTint
        property real budCount: root._buds.length
        // How far from the shell's boxes a bud can reach (its centre's distance from the stone's
        // edge plus its radius, plus the merge radius): the shell is evaluated that far out.
        property vector4d sheen: Qt.vector4d(Math.cos(root.sheenTurn * root._t), Math.sin(root.sheenTurn * root._t), root.sheen, root.sheenWidth)
        property real budPad: root._fx.buds.length > 0 ? root._fx.budPad + root.smoothK * root._unit * root.stoneBlend + 4 : 0
        property vector4d b0: root._blobs[0].b
        property vector4d t0: root._blobs[0].t
        property vector4d b1: root._blobs[1].b
        property vector4d t1: root._blobs[1].t
        property vector4d b2: root._blobs[2].b
        property vector4d t2: root._blobs[2].t
        property vector4d b3: root._blobs[3].b
        property vector4d t3: root._blobs[3].t
        property vector4d b4: root._blobs[4].b
        property vector4d t4: root._blobs[4].t
        property vector4d b5: root._blobs[5].b
        property vector4d t5: root._blobs[5].t
        property vector4d b6: root._blobs[6].b
        property vector4d t6: root._blobs[6].t
        property vector4d b7: root._blobs[7].b
        property vector4d t7: root._blobs[7].t
        property vector4d b8: root._blobs[8].b
        property vector4d t8: root._blobs[8].t
    }
}
