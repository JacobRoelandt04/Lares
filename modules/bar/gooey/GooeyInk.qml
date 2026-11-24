pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

// =============================================================================
// GooeyInk.qml -- where a gooey engine's window has ink: the window's VISIBLE REGION (shell.jsonc `workarounds.visibleInk`).
//
//     PanelWindow { HyprlandWindow.visibleMask: ink.ready ? ink : null;  GooeyInk { id: ink; engine: e; on: true } }
//
// The bar window is one transparent surface over the whole output, and Hyprland blends all of it under every commit. Told
// where the ink is (hyprland_surface_v1 set_visible_region: the compositor's clip for drawing this one surface), it blends that
// and skips the rest. Ink left OUT of the region is cut away by the compositor, so the region is built to hold every pixel the
// engine can write, from what draws them:
//   - THE BANDS: every screen edge that has a bar, its whole length, as deep as its deepest bar's far face plus the reach (below):
//     an island that moves along its edge (the title's motion) never changes the region.
//   - THE SLOTS: every popup, child, reel level, the lane and the OSD that is out, as the engine's input rect of it (a box at rest;
//     for a whole transition the union of where it came from and where it goes, its overshoot included: GooeyEngine._maskRectOf),
//     grown by the reach. One region for a whole motion.
//   - THE TILES: the field writes pixels in its tiles and nowhere else (GooeyField: the shadow's and the shape's), and a body's
//     content is clipped to its body. Every tile no band or slot holds -- a droplet, a flourish, a neck, a ripple's crest, a join
//     stretched past the reach -- is added, merged with its neighbours into what is left of the pool.
//   - THE PREWARM'S STAGE in the window's corner, while a content is built there.
// The reach: the field's own (halo at its farthest, ring, the tiles' margin) plus the joint (blendRadius: a fillet beside a box).
// Everything is padded by `padPx` window px and rounded outward (the compositor scales the region to device px).
// `ready` is false until the field has handed over its first tiles; the host keeps the whole window then, and whenever something
// draws outside the engine (ShellScreen).
//
// COST: it is worked out when the field's tiles change (every frame of a motion, nothing at rest), in engine px, and a proxy is
// written only where its rect moved, so a motion that keeps its bands and slots sends nothing to the compositor.
// =============================================================================
Region {
    id: root

    property var engine: null
    property bool on: false
    // window px of slack round every rect (>= 2 device px at any ratio >= 1)
    property real padPx: 2
    // the rects as last made, window px: [{ x, y, w, h }] (the probe reads them)
    readonly property var rects: root._rects
    readonly property bool ready: root.on && root._haveTiles
    // how many times the region was worked out (the probe's serial)
    property int serial: 0

    readonly property int pool: 12
    property var _rects: []
    property bool _haveTiles: false
    readonly property var _field: root.engine ? root.engine.inkField : null

    Region { id: r0 }
    Region { id: r1 }
    Region { id: r2 }
    Region { id: r3 }
    Region { id: r4 }
    Region { id: r5 }
    Region { id: r6 }
    Region { id: r7 }
    Region { id: r8 }
    Region { id: r9 }
    Region { id: r10 }
    Region { id: r11 }
    readonly property var _proxies: [r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11]

    // The engine and the field keep what this reads only while it is on.
    function _sync(): void {
        if (root.engine)
            root.engine.inkWanted = root.on;
        if (root._field)
            root._field.inkWanted = root.on;
        if (!root.on)
            root._haveTiles = false;
        else if (root.engine)
            root.engine.layout();
    }
    onOnChanged: root._sync()
    on_FieldChanged: root._sync()
    Component.onCompleted: root._sync()

    property Connections _onField: Connections {
        target: root.on ? root._field : null
        function onInkSerialChanged() {
            root._build();
        }
    }
    property Connections _onEngine: Connections {
        target: root.on ? root.engine : null
        function onInkBoxesChanged() {
            root._build();
        }
        function onInkStageChanged() {
            root._build();
        }
    }
    property Connections _onStage: Connections {
        target: root.on && root.engine ? root.engine.inkStage : null
        function onWidthChanged() {
            root._build();
        }
        function onHeightChanged() {
            root._build();
        }
    }

    function _within(t, R, n) {
        for (let i = 0; i < n; i++) {
            const r = R[i];
            if (t.x0 >= r.x0 && t.y0 >= r.y0 && t.x1 <= r.x1 && t.y1 <= r.y1)
                return true;
        }
        return false;
    }

    // Merge the two rects of `R` whose bounding box wastes least, until no more than `max` are left.
    function _squeeze(R, max) {
        while (R.length > max) {
            let bi = 0, bj = 1, bw = Infinity;
            for (let i = 0; i < R.length; i++) {
                const a = R[i], aa = (a.x1 - a.x0) * (a.y1 - a.y0);
                for (let j = i + 1; j < R.length; j++) {
                    const b = R[j];
                    const w = (Math.max(a.x1, b.x1) - Math.min(a.x0, b.x0)) * (Math.max(a.y1, b.y1) - Math.min(a.y0, b.y0))
                        - aa - (b.x1 - b.x0) * (b.y1 - b.y0);
                    if (w < bw) {
                        bw = w;
                        bi = i;
                        bj = j;
                    }
                }
            }
            const a = R[bi], b = R[bj];
            R[bi] = { x0: Math.min(a.x0, b.x0), y0: Math.min(a.y0, b.y0), x1: Math.max(a.x1, b.x1), y1: Math.max(a.y1, b.y1) };
            R.splice(bj, 1);
        }
        return R;
    }

    function _build() {
        const E = root.engine, F = root._field;
        if (!root.on || !E || !F || !F.inkTiles)
            return;
        const W = E.width, H = E.height;
        const reach = F.inkReach + Math.max(E.blendRadius, E._blendRadius || 0);
        const base = [];
        // THE BANDS
        const depth = { top: 0, bottom: 0, left: 0, right: 0 };
        const boxes = E.inkBoxes || [];
        for (let i = 0; i < boxes.length; i++) {
            const b = boxes[i];
            if (b.edge !== undefined) {
                if (b.depth > depth[b.edge])
                    depth[b.edge] = b.depth;
            } else {
                base.push({ x0: b.x0 - reach, y0: b.y0 - reach, x1: b.x1 + reach, y1: b.y1 + reach });
            }
        }
        if (depth.top > 0)
            base.push({ x0: -reach, y0: -reach, x1: W + reach, y1: depth.top + reach });
        if (depth.bottom > 0)
            base.push({ x0: -reach, y0: H - depth.bottom - reach, x1: W + reach, y1: H + reach });
        if (depth.left > 0)
            base.push({ x0: -reach, y0: -reach, x1: depth.left + reach, y1: H + reach });
        if (depth.right > 0)
            base.push({ x0: W - depth.right - reach, y0: -reach, x1: W + reach, y1: H + reach });
        // THE TILES no band or slot holds
        const tiles = F.inkTiles, nb = base.length;
        const extra = [];
        const ring = tiles.ring || [];
        for (let i = 0; i < ring.length; i++)
            if (!root._within(ring[i], base, nb))
                extra.push({ x0: ring[i].x0, y0: ring[i].y0, x1: ring[i].x1, y1: ring[i].y1 });
        const shape = tiles.shape || [];
        for (let i = 0; i < tiles.n; i++)
            if (!root._within(shape[i], base, nb))
                extra.push({ x0: shape[i].x0, y0: shape[i].y0, x1: shape[i].x1, y1: shape[i].y1 });
        let all = base.concat(extra);
        // engine px -> window px
        const o = E.mapToItem(null, 0, 0), q = E.mapToItem(null, 1000, 1000);
        const sx = (q.x - o.x) / 1000, sy = (q.y - o.y) / 1000;
        const out = [];
        for (let i = 0; i < all.length; i++) {
            const r = all[i];
            out.push({ x0: o.x + r.x0 * sx, y0: o.y + r.y0 * sy, x1: o.x + r.x1 * sx, y1: o.y + r.y1 * sy });
        }
        // THE PREWARM'S STAGE (window px: it is scaled)
        const st = E.inkStage;
        if (st && st.width > 0 && st.height > 0) {
            const a = st.mapToItem(null, 0, 0), b = st.mapToItem(null, st.width, st.height);
            out.push({ x0: Math.min(a.x, b.x), y0: Math.min(a.y, b.y), x1: Math.max(a.x, b.x), y1: Math.max(a.y, b.y) });
        }
        root._squeeze(out, root.pool);
        const win = E.Window.window;
        const ww = win ? win.width : 1e6, wh = win ? win.height : 1e6;
        const p = root.padPx, R = [];
        for (let i = 0; i < out.length; i++) {
            const r = out[i];
            const x0 = Math.max(0, Math.floor(r.x0 - p)), y0 = Math.max(0, Math.floor(r.y0 - p));
            const x1 = Math.min(ww, Math.ceil(r.x1 + p)), y1 = Math.min(wh, Math.ceil(r.y1 + p));
            if (x1 > x0 && y1 > y0)
                R.push({ x: x0, y: y0, w: x1 - x0, h: y1 - y0 });
        }
        let changed = R.length !== root._rects.length;
        for (let i = 0; i < root.pool; i++) {
            const m = root._proxies[i];
            const r = i < R.length ? R[i] : null;
            const x = r ? r.x : 0, y = r ? r.y : 0, w = r ? r.w : 0, h = r ? r.h : 0;
            if (m.x !== x || m.y !== y || m.width !== w || m.height !== h) {
                changed = true;
                m.x = x;
                m.y = y;
                m.width = w;
                m.height = h;
            }
        }
        if (changed)
            root._rects = R;
        root._haveTiles = true;
        root.serial++;
    }
}
