pragma ComponentBehavior: Bound

import QtQuick

import "GooeyGeometry.js" as Geo

// =============================================================================
// ReelCast -- THE REEL PASS (GooeyEngine, THE REEL SLOT; shaders/gooey_field.frag, THE REEL PASS): the field's own surface, ring and
// halo for a reel-slot body that lies over a popup.
//
// The field draws its ring and halo only outside its union, and a strip over a popup is inside it: no ring, no halo, and no fillet
// where the strip leaves the bar. This layer draws them with THE FIELD'S OWN SHADER, baked a second time (gooey_reel.frag.qsb), from
// THE FIELD'S OWN SHAPE of the same frame: GooeyField calls `feed(out)` with every shape it draws (the bodies, fillets and seams
// GooeyGeometry returned, the very objects its own uniforms are written from), and the engine has said before that layout which of
// the bodies are the reel group, which the bars and which the popups (`plan`). Nothing here has a geometry of its own that could lag
// a frame or stand off the drawn strip.
//
// While it draws it sits between the popups (z 1) and the reel slot (z 2, its chain 1.3 .. 1.5): over the popups' content, under the strip's. The
// FILL is the card's ground (the surface over the popup's content, fillets included), so the strip needs none of its own. With no
// popup under the group the pass has no tile and the effect is not in the scene. (`warm()` draws it for a few frames with no tile, so
// its pipeline is built when the shell is idle and not in the middle of a strip's first opening over a popup.)
//
//   plan      { group: [4 body indices: the strip, its levels; -1 for one that is not out], bars: [indices], pops: [indices] }, or
//             null: the engine's, written before it hands the field its bodies
//   feed(out) the field's, at the end of every shape
//   warm()    THE WARM-UP: the effect drawn for a few frames with no tile, so its pipeline is built (the engine's prewarm calls it)
//   count     how many popups the pass draws on (0: off); ink, the group's ink by slot; warming; for the gates
// =============================================================================
Item {
    id: cast

    required property var engine
    required property var field

    anchors.fill: parent
    enabled: false
    // Over the popups and under the reel slot while it draws; under everything of the host layer, right over the field, for THE
    // WARM-UP's frames: a node that draws nothing is still one the renderer cannot merge its neighbours across, and there no node
    // is merged across anyway.
    z: cast._count > 0 ? 1.2 : -2000

    property var plan: null

    readonly property int count: cast._count
    readonly property bool warming: cast._warmLeft > 0
    readonly property vector4d ink: Qt.vector4d(cast._inkOf(0), cast._inkOf(1), cast._inkOf(2), cast._inkOf(3))
    // What the last feed drew, for the gates: the tiles of both kinds and the classes' sizes.
    readonly property var drawn: cast._drawn

    property int _count: 0
    // THE WARM-UP (below): frames the effect is still to be drawn for with no tile.
    property int _warmLeft: 0
    property var _drawn: ({ shape: 0, halo: 0, group: 0, bars: 0, pops: 0, fillets: 0, popFillets: 0, seams: 0 })
    // Which of the group (0 the strip, 1 .. 3 its levels) each of the first slots holds; -1 none.
    property var _slotMember: [-1, -1, -1, -1]
    // (the field's own bookkeeping of uniform writes: only what changed is written, GooeyField._put)
    property var _written: ({})
    property var _used: ({ b: 0, f: 0, s: 0, t: 0, ts: 0 })
    property var _gxy: []
    property var _lanes: ({})
    readonly property var _names: {
        const mk = (p, n) => Array.from({ length: n }, (_, i) => p + i);
        const F = cast.field;
        return { b: mk("b", F.maxBodies), x: mk("x", F.maxBodies), y: mk("y", F.maxBodies), u: mk("u", F.maxBodies), v: mk("v", F.maxBodies),
                 f: mk("f", F.maxFillets), k: mk("k", F.maxFillets), g: mk("g", F.maxFillets), s: mk("s", F.maxSeams),
                 t: mk("t", F.maxTiles + F.maxShadowTiles) };
    }

    // Each body's ink: its content's fade while it comes or goes (a body that is not out has none). Only then: a strip that travels to
    // another reel's cell, or a level whose content is swapped in place, fades one content out and the next in while the BODY stands --
    // the field keeps its ring through that, and so does the pass (it blinked off and on in the middle of every switch).
    function _inkOf(member: int): real {
        if (member < 0)
            return 0;
        const S = member === 0 ? cast.engine.theReel : cast.engine.reelChildPopups[member - 1];
        if (!S)
            return 0;
        return S.phase === "opening" || S.phase === "closing" ? S.contentOpacity : 1;
    }
    readonly property vector4d _slotInk: Qt.vector4d(cast._inkOf(cast._slotMember[0]), cast._inkOf(cast._slotMember[1]),
                                                     cast._inkOf(cast._slotMember[2]), cast._inkOf(cast._slotMember[3]))
    on_SlotInkChanged: {
        if (cast._count > 0)
            cast._writeLanes();
    }

    function _put(name, a, b, c, d) {
        const o = cast._written[name];
        if (o && o[0] === a && o[1] === b && o[2] === c && o[3] === d)
            return;
        cast._written[name] = [a, b, c, d];
        fx[name] = Qt.vector4d(a, b, c, d);
    }
    // g<i> = (the fillet bleed's x, y, the pass's lanes in z, w).
    function _writeG(i) {
        const xy = cast._gxy[i] || [0, 0];
        const nm = i < fx.packNames.length ? fx.packNames[i] : null;
        const L = cast._lanes;
        cast._put(cast._names.g[i], xy[0], xy[1], nm && nm[0] ? (L[nm[0]] || 0) : 0, nm && nm[1] ? (L[nm[1]] || 0) : 0);
    }
    function _writeLanes() {
        const L = cast._lanes, k = cast._slotInk;
        L.reelInk0 = k.x;
        L.reelInk1 = k.y;
        L.reelInk2 = k.z;
        L.reelInk3 = k.w;
        for (let i = 0; i < fx.packNames.length; i++)
            cast._writeG(i);
    }

    // THE WARM-UP. The pass's pipeline is built at the effect's first DRAW, and it is half the field's size: ~50 ms from a warm driver
    // cache, seconds from a cold one -- a frame of that length in the middle of a strip's opening, the first time a reel lies over
    // a popup. warm() draws the effect for a few frames with no tile (nothing is rasterised, not a pixel moves), so the pipeline is
    // built when the caller chooses: the engine calls it at the end of its own prewarm, when the shell is up and idle.
    function warm(frames) {
        cast._warmLeft = Math.max(cast._warmLeft, frames > 0 ? frames : 3);
    }
    FrameAnimation {
        running: cast._warmLeft > 0
        onTriggered: cast._warmLeft--
    }

    // No tile: nothing is drawn (the vertex shader collapses every row onto one point).
    function _off() {
        if (cast._count === 0)
            return;
        cast._count = 0;
        fx.tileCount = 0;
        fx.shadowTiles = 0;
        cast._drawn = { shape: 0, halo: 0, group: 0, bars: 0, pops: 0, fillets: 0, popFillets: 0, seams: 0 };
    }

    // The two bodies a fillet or a seam joins, from its key ("<id>|<id>|<axis>...", a pocket's with "pocket|" before it).
    function _ends(key) {
        const p = String(key || "").split("|");
        const o = p[0] === "pocket" ? 1 : 0;
        return [p[o] || "", p[o + 1] || ""];
    }

    // THE FEED (header): this frame's shape, sorted by class into the pass's own uniforms.
    function feed(out) {
        const P = cast.plan, F = cast.field;
        const bw = F._bw, haloOn = F._shadowOn;
        if (!P || !(bw > 0 || haloOn)) {
            cast._off();
            return;
        }
        const B = out.bodies;
        const solid = i => i >= 0 && i < B.length && B[i].solid;
        const members = [];
        let gb = null;
        for (let m = 0; m < 4; m++) {
            const i = P.group[m];
            if (!solid(i))
                continue;
            members.push({ member: m, body: B[i] });
            const b = B[i];
            gb = gb ? { x0: Math.min(gb.x0, b.x0), y0: Math.min(gb.y0, b.y0), x1: Math.max(gb.x1, b.x1), y1: Math.max(gb.y1, b.y1) }
                    : { x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y1 };
        }
        if (!gb) {
            cast._off();
            return;
        }
        // How far from the group anything is drawn: the halo's fall ends where the smooth union's distance reaches spread + reach
        // (shadowParam.z), and a smooth union lies up to k/4 outside the hard one; the ring and its ramp; the tiles' own margin.
        const k = F.shadowBlend;
        const haloR = haloOn ? Math.max(0, F._spread + F._reach + bw + k / 4) + 1 : 0;
        const ringR = Math.max(F._tileMargin, bw + 1.5);
        const reach = Math.max(haloR, ringR);
        const near = (r, m) => r.x1 > gb.x0 - m && r.x0 < gb.x1 + m && r.y1 > gb.y0 - m && r.y0 < gb.y1 + m;
        // (the pass's shader evaluates fx.passBodies bodies: the group first, then the bars and the popups, each by how much of it
        // lies near the group, so what is dropped past the count is what matters least)
        const share = r => Math.max(0, Math.min(r.x1, gb.x1 + reach) - Math.max(r.x0, gb.x0 - reach))
                         * Math.max(0, Math.min(r.y1, gb.y1 + reach) - Math.max(r.y0, gb.y0 - reach));
        const byShare = (a, b) => share(b) - share(a);
        const pops = P.pops.filter(i => solid(i) && near(B[i], reach)).map(i => B[i]).sort(byShare);
        if (!pops.length) {
            cast._off();
            return;
        }
        // The bars the share can see: within the blend of what is drawn.
        const blend = Math.max(1, F.blendRadius);
        const room = Math.max(0, fx.passBodies - members.length);
        const bars = P.bars.filter(i => solid(i) && near(B[i], reach + 2 * blend)).map(i => B[i]).sort(byShare).slice(0, Math.max(0, room - 1));
        pops.length = Math.min(pops.length, Math.max(1, room - bars.length));

        const N = cast._names, used = cast._used;
        const list = members.map(m => m.body).concat(bars, pops).slice(0, fx.passBodies);
        const n = list.length;
        for (let i = 0; i < Math.max(n, used.b); i++) {
            const b = i < n ? list[i] : null;
            if (b) {
                cast._put(N.b[i], b.x0, b.y0, b.x1, b.y1);
                cast._put(N.x[i], b.ex[0], b.ex[1], b.ex[2], b.ex[3]);
                cast._put(N.y[i], b.ey[0], b.ey[1], b.ey[2], b.ey[3]);
                cast._put(N.u[i], b.ix[0], b.ix[1], b.ix[2], b.ix[3]);
                cast._put(N.v[i], b.iy[0], b.iy[1], b.iy[2], b.iy[3]);
            } else {
                cast._put(N.b[i], -1e5, -1e5, -1e5, -1e5);
                cast._put(N.x[i], 0, 0, 0, 0);
                cast._put(N.y[i], 0, 0, 0, 0);
                cast._put(N.u[i], 0, 0, 0, 0);
                cast._put(N.v[i], 0, 0, 0, 0);
            }
        }
        // The fillets by class: both ends in the union (the group and its bars), or an end in a popup.
        const idU = {}, idP = {};
        for (const m of members)
            idU[m.body.id] = true;
        for (const b of bars)
            idU[b.id] = true;
        for (const b of pops)
            idP[b.id] = true;
        const rectOf = f => ({ x0: Math.min(f.vx, f.vx + f.ex), y0: Math.min(f.vy, f.vy + f.ey),
                               x1: Math.max(f.vx, f.vx + f.ex), y1: Math.max(f.vy, f.vy + f.ey) });
        const fu = [], fp = [];
        for (const f of out.fillets) {
            const e = cast._ends(f.key);
            if (!near(rectOf(f), reach))
                continue;
            if (idU[e[0]] && idU[e[1]])
                fu.push(f);
            else if (idP[e[0]] || idP[e[1]])
                fp.push(f);
        }
        // (the union's own first: a popup's fillet only shapes the cut)
        const fl = fu.slice(0, fx.passFillets - Math.min(2, fp.length)).concat(fp).slice(0, fx.passFillets);
        const nf = fl.length, nfu = Math.min(fu.length, fx.passFillets - Math.min(2, fp.length), nf);
        for (let i = 0; i < Math.max(nf, used.f); i++) {
            const f = i < nf ? fl[i] : null;
            if (f) {
                cast._put(N.f[i], f.vx, f.vy, f.ex, f.ey);
                cast._put(N.k[i], f.kx, f.ky, f.krx, f.kry);
                cast._gxy[i] = [f.bx, f.by];
            } else {
                cast._put(N.f[i], 0, 0, 0, 0);
                cast._put(N.k[i], 0, 0, 0, 0);
                cast._gxy[i] = [0, 0];
            }
            if (i >= fx.packNames.length)
                cast._writeG(i);
        }
        const sl = out.seams.filter(s => {
            const e = cast._ends(s.key);
            return idU[e[0]] && idU[e[1]] && near(s, reach);
        }).slice(0, fx.passSeams);
        const ns = sl.length;
        for (let i = 0; i < Math.max(ns, used.s); i++) {
            const s = i < ns ? sl[i] : null;
            if (s)
                cast._put(N.s[i], s.x0, s.y0, s.x1, s.y1);
            else
                cast._put(N.s[i], 0, 0, 0, 0);
        }

        // The tiles, cut to the popups (a pixel wider: their coverage's ramp): the shape's over the group and the union's fillets,
        // the halo's as far round the group as it falls. The halo's are drawn first, under the shape's (gooey_field.vert).
        const clip = { x0: 0, y0: 0, x1: F.width, y1: F.height };
        const grown = (r, g) => ({ x0: r.x0 - g, y0: r.y0 - g, x1: r.x1 + g, y1: r.y1 + g });
        const over = rects => {
            const o = [];
            for (const r of rects)
                for (const p of pops) {
                    const x0 = Math.max(r.x0, p.x0 - 1), y0 = Math.max(r.y0, p.y0 - 1), x1 = Math.min(r.x1, p.x1 + 1), y1 = Math.min(r.y1, p.y1 + 1);
                    if (x1 > x0 && y1 > y0)
                        o.push({ x0: x0, y0: y0, x1: x1, y1: y1 });
                }
            return o;
        };
        const groupRects = members.map(m => m.body);
        const shape = Geo.tiles(over(groupRects.concat(fu.slice(0, nfu).map(rectOf)).map(r => grown(r, ringR))), clip, F.maxTiles);
        const halo = haloOn ? Geo.tiles(over(groupRects.map(r => grown(r, haloR))), clip, F.maxShadowTiles) : [];
        if (!shape.length && !halo.length) {
            cast._off();
            return;
        }
        const nt = shape.length, nr = halo.length, base = F.maxShadowTiles;
        for (let i = 0; i < Math.max(nr, used.ts); i++) {
            const t = i < nr ? halo[i] : null;
            if (t)
                cast._put(N.t[i], t.x0, t.y0, t.x1, t.y1);
            else
                cast._put(N.t[i], 0, 0, 0, 0);
        }
        for (let i = 0; i < Math.max(nt, used.t); i++) {
            const t = i < nt ? shape[i] : null;
            if (t)
                cast._put(N.t[base + i], t.x0, t.y0, t.x1, t.y1);
            else
                cast._put(N.t[base + i], 0, 0, 0, 0);
        }
        cast._used = { b: n, f: nf, s: ns, t: nt, ts: nr };

        const sm = [-1, -1, -1, -1];
        for (let i = 0; i < members.length && i < 4; i++)
            sm[i] = members[i].member;
        if (sm.some((v, i) => v !== cast._slotMember[i]))
            cast._slotMember = sm;
        cast._lanes = { smoothK: Math.max(0.001, k), reelR: Math.min(members.length, n), reelB: Math.max(0, Math.min(bars.length, n - members.length)),
                        reelFM: nfu, reelBlend: blend };
        cast._writeLanes();
        fx.bodyCount = n;
        fx.filletCount = nf;
        fx.seamCount = ns;
        fx.tileCount = nt;
        fx.shadowTiles = nr;
        cast._count = pops.length;
        cast._drawn = { shape: nt, halo: nr, group: members.length, bars: bars.length, pops: pops.length, fillets: nfu, popFillets: nf - nfu, seams: ns };
    }

    ShaderEffect {
        id: fx
        anchors.fill: parent
        // In the scene only while it has a tile, or for THE WARM-UP's frames. (Left in the scene for good it was compiled with the
        // field at every start and again for every pipeline state the window came to: seconds more of a cold start, in each window.)
        visible: cast._count > 0 || cast._warmLeft > 0
        blending: true
        // The field's own mesh and vertex shader (the tiles; GooeyField), and its fragment source baked with REEL_PASS.
        mesh: GridMesh {
            resolution: Qt.size(1, 383)
        }
        vertexShader: "shaders/gooey_field.vert.qsb"
        fragmentShader: "shaders/gooey_reel.frag.qsb"

        // The field's ink, as it writes its own (GooeyField._updateEdge): no aura here.
        property color fieldColor: cast.field.color
        property real bodyCount: 0
        property real filletCount: 0
        property real seamCount: 0
        property real tileCount: 0
        property real showTiles: cast.field.showTiles ? 1 : 0
        property color shadowColor: cast.field._shadowOn ? Qt.rgba(cast.field.shadowColor.r, cast.field.shadowColor.g, cast.field.shadowColor.b,
                                                                   cast.field._strength) : Qt.rgba(0, 0, 0, 0)
        property color borderColor: cast.field._bw > 0 ? cast.field.borderColor : Qt.rgba(0, 0, 0, 0)
        property vector4d shadowParam: Qt.vector4d(0, 0, cast.field._shadowOn ? cast.field._reach + cast.field._bw : 1, cast.field._bw)
        property vector4d shadowShape: Qt.vector4d(cast.field._spread, cast.field._softness, 0, 0)
        property real shadowTiles: 0

        // @@PROPS-BEGIN (generated by tools/dev/gooey_field_ubo.py -- edit there)
        property vector4d b0
        property vector4d b1
        property vector4d b2
        property vector4d b3
        property vector4d b4
        property vector4d b5
        property vector4d b6
        property vector4d b7
        property vector4d b8
        property vector4d b9
        property vector4d b10
        property vector4d b11
        property vector4d x0
        property vector4d x1
        property vector4d x2
        property vector4d x3
        property vector4d x4
        property vector4d x5
        property vector4d x6
        property vector4d x7
        property vector4d x8
        property vector4d x9
        property vector4d x10
        property vector4d x11
        property vector4d y0
        property vector4d y1
        property vector4d y2
        property vector4d y3
        property vector4d y4
        property vector4d y5
        property vector4d y6
        property vector4d y7
        property vector4d y8
        property vector4d y9
        property vector4d y10
        property vector4d y11
        property vector4d u0
        property vector4d u1
        property vector4d u2
        property vector4d u3
        property vector4d u4
        property vector4d u5
        property vector4d u6
        property vector4d u7
        property vector4d u8
        property vector4d u9
        property vector4d u10
        property vector4d u11
        property vector4d v0
        property vector4d v1
        property vector4d v2
        property vector4d v3
        property vector4d v4
        property vector4d v5
        property vector4d v6
        property vector4d v7
        property vector4d v8
        property vector4d v9
        property vector4d v10
        property vector4d v11
        property vector4d f0
        property vector4d f1
        property vector4d f2
        property vector4d f3
        property vector4d f4
        property vector4d f5
        property vector4d f6
        property vector4d f7
        property vector4d f8
        property vector4d f9
        property vector4d f10
        property vector4d f11
        property vector4d f12
        property vector4d f13
        property vector4d f14
        property vector4d f15
        property vector4d f16
        property vector4d f17
        property vector4d f18
        property vector4d f19
        property vector4d f20
        property vector4d f21
        property vector4d f22
        property vector4d f23
        property vector4d k0
        property vector4d k1
        property vector4d k2
        property vector4d k3
        property vector4d k4
        property vector4d k5
        property vector4d k6
        property vector4d k7
        property vector4d k8
        property vector4d k9
        property vector4d k10
        property vector4d k11
        property vector4d k12
        property vector4d k13
        property vector4d k14
        property vector4d k15
        property vector4d k16
        property vector4d k17
        property vector4d k18
        property vector4d k19
        property vector4d k20
        property vector4d k21
        property vector4d k22
        property vector4d k23
        property vector4d g0
        property vector4d g1
        property vector4d g2
        property vector4d g3
        property vector4d g4
        property vector4d g5
        property vector4d g6
        property vector4d g7
        property vector4d g8
        property vector4d g9
        property vector4d g10
        property vector4d g11
        property vector4d g12
        property vector4d g13
        property vector4d g14
        property vector4d g15
        property vector4d g16
        property vector4d g17
        property vector4d g18
        property vector4d g19
        property vector4d g20
        property vector4d g21
        property vector4d g22
        property vector4d g23
        property vector4d s0
        property vector4d s1
        property vector4d s2
        property vector4d s3
        property vector4d s4
        property vector4d s5
        property vector4d s6
        property vector4d s7
        property vector4d s8
        property vector4d s9
        property vector4d s10
        property vector4d s11
        property vector4d s12
        property vector4d s13
        property vector4d s14
        property vector4d s15
        property vector4d s16
        property vector4d s17
        property vector4d s18
        property vector4d s19
        property vector4d s20
        property vector4d s21
        property vector4d s22
        property vector4d s23
        property vector4d t0
        property vector4d t1
        property vector4d t2
        property vector4d t3
        property vector4d t4
        property vector4d t5
        property vector4d t6
        property vector4d t7
        property vector4d t8
        property vector4d t9
        property vector4d t10
        property vector4d t11
        property vector4d t12
        property vector4d t13
        property vector4d t14
        property vector4d t15
        property vector4d t16
        property vector4d t17
        property vector4d t18
        property vector4d t19
        property vector4d t20
        property vector4d t21
        property vector4d t22
        property vector4d t23
        property vector4d t24
        property vector4d t25
        property vector4d t26
        property vector4d t27
        property vector4d t28
        property vector4d t29
        property vector4d t30
        property vector4d t31
        property vector4d t32
        property vector4d t33
        property vector4d t34
        property vector4d t35
        property vector4d t36
        property vector4d t37
        property vector4d t38
        property vector4d t39
        property vector4d t40
        property vector4d t41
        property vector4d t42
        property vector4d t43
        property vector4d t44
        property vector4d t45
        property vector4d t46
        property vector4d t47
        property vector4d t48
        property vector4d t49
        property vector4d t50
        property vector4d t51
        property vector4d t52
        property vector4d t53
        property vector4d t54
        property vector4d t55
        property vector4d t56
        property vector4d t57
        property vector4d t58
        property vector4d t59
        property vector4d t60
        property vector4d t61
        property vector4d t62
        property vector4d t63
        property vector4d t64
        property vector4d t65
        property vector4d t66
        property vector4d t67
        property vector4d t68
        property vector4d t69
        property vector4d t70
        property vector4d t71
        property vector4d t72
        property vector4d t73
        property vector4d t74
        property vector4d t75
        property vector4d t76
        property vector4d t77
        property vector4d t78
        property vector4d t79
        property vector4d t80
        property vector4d t81
        property vector4d t82
        property vector4d t83
        property vector4d t84
        property vector4d t85
        property vector4d t86
        property vector4d t87
        property vector4d t88
        property vector4d t89
        property vector4d t90
        property vector4d t91
        property vector4d t92
        property vector4d t93
        property vector4d t94
        property vector4d t95
        property real tintIdA: -1
        property real tintIdB: -1
        property real tintIdC: -1
        property color tintA: "transparent"
        property color tintB: "transparent"
        property color tintC: "transparent"
        property real tintReach: 1
        property vector4d auraC0
        property vector4d auraC1
        property vector4d auraC2
        property vector4d auraC3
        property vector4d auraRect
        property vector4d auraFrame
        property vector4d auraChain
        property vector4d auraMid
        property vector4d auraChainMid
        property vector4d auraJoinA
        property vector4d auraJoinC
        readonly property var packNames: [["", "smoothK"], ["reelR", "reelB"], ["reelFM", "reelBlend"], ["reelInk0", "reelInk1"], ["reelInk2", "reelInk3"]]
        readonly property int passBodies: 8
        readonly property int passFillets: 12
        readonly property int passSeams: 8
        // @@PROPS-END
    }
}
