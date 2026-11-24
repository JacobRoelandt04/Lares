pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components/Mix.js" as Mix

// 1D soft-body wavefield along the top + bottom edges of a battery fill half.
// Driven at the bar-adjacent end by the charge-limit bar pushing into the fill
// as it rises (the gap it opens displaces the liquid: a bulge) and letting go
// as it sinks (the liquid flows back: a dip). Wave propagates
// along x with damping, reflects off the far edge (fixed Dirichlet = 0). Positive
// displacement = bulge (outward past the fill's edge), negative = cavity (inward
// into the fill). Renders two Canvas overlays (top + bottom) that paint the
// bulge extension above/below the fill's natural rounded top/bottom and the
// cavity pressing into the fill.
//
// Physical model: standard discrete wave equation
//     a[i] = c^2 · (y[i-1] - 2·y[i] + y[i+1]) / dx^2
//     v[i] += a[i] · dt;  v[i] *= exp(-damp · dt);  y[i] += v[i] · dt
// Inner edge (bar-adjacent) is a driven Dirichlet boundary — chases a drive
// target via exponential lerp. The target is impulseGain × the speed at which
// `pushPx` (how far the bar has pushed this half's edge back) is changing,
// clamped: the fast start of the rise injects a big bulge, the fast end of the
// sink a big dip. When the bar stops the target is 0, the edge swings back,
// ripples propagate outward, reflect, damp to stillness -- and `settled` goes
// true, which is what lets the body join the two halves again.
//
// Overflow redirect: when `fillPadding` is small (or zero), outward bulge may
// exceed `maxOutwardPx`. The overflow is redirected to the inward channel, so
// with no padding the bulge manifests as a cavity (negative space).
//
// Painting: overlays do NOT emulate ShadowBox's inset shading — the fill body
// retains its native shading. The overlay traces the fill's natural rounded top
// (or bottom) contour via bezier sampling and paints:
//   - Bulge polygon: from wave-top (natural shifted outward by outs[x]) down to
//     natural-top. Fills with fillColor — extends the fill's visible shape.
//   - Cavity polygon: from natural-top down to (natural + ins[x]). Fills with
//     grooveBg — eats into the fill body.
// Because both polygons follow the natural corner curve, bulge extends the
// corner smoothly (no gap between corner end and bulge start) and cavity
// shifts the corner down uniformly (no partial-corner contour lines).
Item {
    id: root

    // === Fill geometry (local parent coords) ===
    property real fillX: 0
    property real fillY: 0
    property real fillWidth: 200
    property real fillHeight: 140

    // === Switch ===
    // Off, nothing is simulated or drawn. The host keeps it on while the fill
    // is split -- and until the wave has settled after the bar sank.
    property bool active: true
    // True while nothing is moving: the frame clock is off and the overlays
    // draw nothing. Starts true -- a fill at rest is flat -- and a half that
    // is switched off is settled too (onActiveChanged flattens it), since it
    // has no shape left to ring. Not `!active || _flat`: the host's `active`
    // is derived from this, and reading it back here is a binding loop.
    readonly property bool settled: root._flat
    property bool _flat: true

    // === The numbers (shared by both halves) ===
    property BatteryWaveStyle style: null
    // The two clip depths, read off the style once for the painters below.
    readonly property real maxOutwardPx: root.style ? root.style.maxOutwardPx : 0
    readonly property real maxInwardPx: root.style ? root.style.maxInwardPx : 0

    // === Colors ===
    property color fillColor: Theme.batteryIdle
    property color grooveBgColor: Theme.listBox
    // The fill's own inset shadow, repainted by the bulge so the edge keeps
    // its shading while it moves.
    property real fillShadowWidth: 0
    property color fillShadowColor: Theme.shadowDeep

    // === Which side is the bar on ("left" | "right") ===
    // Left-fill has bar on its right end (driveIdx = gridN).
    // Right-fill has bar on its left end  (driveIdx = 0).
    property string barSide: "right"

    // === The drive ===
    // How far the bar has pushed this half's bar-side edge back, px. Only its
    // RATE of change drives the wave.
    property real pushPx: 0
    // Whether the liquid reaches the bar at all. A fill that ends short of the
    // bar is not pushed by it.
    property bool contact: true
    onPushPxChanged: {
        if (root.active && root.contact && root.style && root.style.enabled)
            root._flat = false;
    }

    // === Corner radii of the underlying fill's ShadowBox ===
    // The overlay traces the same rounded shape so bulge/cavity follow the
    // corner curves continuously (no rectangular overshoot, no gap at corner end).
    property real topLeftCornerRadius: 0
    property real topRightCornerRadius: 0
    property real bottomRightCornerRadius: 0
    property real bottomLeftCornerRadius: 0

    function _clampR(r) {
        const fw = Math.max(1, fillWidth);
        const fh = Math.max(1, fillHeight);
        return Math.max(0, Math.min(r, fw * 0.5, fh * 0.5));
    }

    // Bezier evaluator for the fill's rounded-corner curves. Uses the same
    // k = 0.55228 (circular bezier constant) and curveProfile=1.0 convention as
    // ShadowBox so the overlay traces the identical path.
    //
    // _tlAt(s): TL top-left corner. s=0 → (0, baseY + tlR); s=1 → (tlR, baseY).
    //           Traversing the corner left-to-right along the fill's top.
    // _trAt(s): TR top-right corner. s=0 → (w - trR, baseY); s=1 → (w, baseY + trR).
    // _blAt(s): BL bottom-left corner. s=0 → (blR, baseY); s=1 → (0, baseY - blR).
    //           NOTE: for left-to-right traversal of the bottom edge, iterate s 1→0.
    // _brAt(s): BR bottom-right corner. s=0 → (w - brR, baseY); s=1 → (w, baseY - brR).
    readonly property real _kBez: 0.55228

    function _tlAt(s, r, baseY) {
        const t = 1 - s;
        const mt = s;
        const k = root._kBez;
        const x = r * (mt * mt * mt + 3 * mt * mt * t * (1 - k));
        const y = baseY + r * t * t * (3 * mt * (1 - k) + t);
        return [x, y];
    }

    function _trAt(s, w, r, baseY) {
        const t = s;
        const mt = 1 - t;
        const k = root._kBez;
        const x = w - r * (mt * mt * mt + 3 * mt * mt * t * (1 - k));
        const y = baseY + r * t * t * (3 * mt * (1 - k) + t);
        return [x, y];
    }

    function _blAt(s, r, baseY) {
        const t = s;
        const mt = 1 - t;
        const k = root._kBez;
        const x = r * (mt * mt * mt + 3 * mt * mt * t * (1 - k));
        const y = baseY - r * t * t * (3 * mt * (1 - k) + t);
        return [x, y];
    }

    function _brAt(s, w, r, baseY) {
        const t = s;
        const mt = 1 - t;
        const k = root._kBez;
        const x = w - r * (mt * mt * mt + 3 * mt * mt * t * (1 - k));
        const y = baseY - r * t * t * (3 * mt * (1 - k) + t);
        return [x, y];
    }

    // Matches ShadowBox's shadowEasing bezier [0.15, 0.60, 0.35, 1.0] so the
    // overlay's concentric shadow rings land on the same color as ShadowBox's
    // native sub-shapes at the corresponding depth.
    function _shadowEase(x) {
        if (x <= 0) return 0;
        if (x >= 1) return 1;
        const x1 = 0.15, y1 = 0.60, x2 = 0.35, y2 = 1.0;
        let t = x;
        for (let i = 0; i < 8; i++) {
            const t2 = t * t, mt = 1 - t, mt2 = mt * mt;
            const bx = 3 * mt2 * t * x1 + 3 * mt * t2 * x2 + t2 * t;
            const dbx = 3 * mt2 * x1 + 6 * mt * t * (x2 - x1) + 3 * t2 * (1 - x2);
            if (Math.abs(dbx) < 1e-6) break;
            const dt = (bx - x) / dbx;
            t -= dt;
            if (Math.abs(dt) < 1e-5) break;
        }
        t = Math.max(0, Math.min(1, t));
        const t2 = t * t, mt = 1 - t, mt2 = mt * mt;
        return 3 * mt2 * t * y1 + 3 * mt * t2 * y2 + t2 * t;
    }

    // === Internal state ===
    property var _y: null
    property var _v: null
    // The drive target the edge chases, and the push it was derived from on
    // the previous frame.
    property real _drive: 0
    property real _prevPush: 0

    function resetState() {
        const n = root.style ? root.style.gridN + 1 : 2;
        root._y = Array.from({length: n}, () => 0);
        root._v = Array.from({length: n}, () => 0);
        root._drive = 0;
        root._prevPush = root.pushPx;
    }

    Component.onCompleted: resetState()
    Connections {
        target: root.style
        function onGridNChanged() {
            root.resetState();
        }
    }

    // Flat whenever switched, either way: a half that goes (the right one,
    // when the bar's gap swallows it) takes its shape with it, and one that
    // comes back never starts from a stale one.
    onActiveChanged: {
        root.resetState();
        root._flat = true;
    }

    // Safety clamp on raw state magnitude — if the sim diverges despite CFL
    // sub-stepping, values stay bounded rather than blowing up to Infinity / NaN.
    readonly property real _stateSanityLimit: 400

    function step(dtSec) {
        const st = root.style;
        const N = st.gridN;
        if (!root._y || root._y.length !== N + 1)
            root.resetState();
        const totalDt = Math.min(0.033, dtSec);

        // The drive: the push's rate of change, per frame.
        const vel = (root.pushPx - root._prevPush) / Math.max(1e-3, totalDt);
        root._prevPush = root.pushPx;
        const raw = root.contact ? st.impulseGain * vel : 0;
        root._drive = Math.max(-st.maxAmplitudePx, Math.min(st.maxAmplitudePx, raw));

        const fw = Math.max(1, root.fillWidth);
        const c = st.waveSpeedNorm * fw;
        const dx = fw / N;

        // CFL stability: symplectic-Euler on the wave equation requires
        //   c · dt_sub / dx < 1
        // Violating this grows the spatial high-frequency (checkerboard) mode
        // exponentially — the "zigzag glitch". Target 0.4 of the
        // CFL limit so the sim stays stable at any tuned speed.
        const cflSafeDt = 0.4 * dx / Math.max(1e-6, c);
        const numSubSteps = Math.max(1, Math.min(64, Math.ceil(totalDt / cflSafeDt)));
        const subDt = totalDt / numSubSteps;

        for (let s = 0; s < numSubSteps; s++)
            root._stepOnce(subDt, N, c, dx);

        // NaN / Inf defense — reset once so the sim recovers rather than
        // freezing at a stuck state.
        if (!isFinite(root._y[0]) || !isFinite(root._v[1]) || !isFinite(root._y[N]))
            root.resetState();
    }

    function _stepOnce(dt, N, c, dx) {
        const st = root.style;
        const y = root._y;
        const v = root._v;
        const c2_over_dx2 = (c * c) / (dx * dx);
        const decay = Math.exp(-st.dampingPerSec * dt);

        const driveIdx = (root.barSide === "right") ? N : 0;
        const farIdx = (root.barSide === "right") ? 0 : N;

        // Chase the drive target at the driven edge (Dirichlet-driven BC)
        const alpha = 1 - Math.exp(-st.driveLerpPerSec * dt);
        y[driveIdx] = y[driveIdx] + (root._drive - y[driveIdx]) * alpha;
        v[driveIdx] = 0;

        // Fixed far end
        y[farIdx] = 0;
        v[farIdx] = 0;

        // Symplectic Euler — update velocities from current positions, then positions.
        const sanity = root._stateSanityLimit;
        for (let i = 1; i < N; i++) {
            const a = c2_over_dx2 * (y[i - 1] - 2 * y[i] + y[i + 1]);
            v[i] = (v[i] + a * dt) * decay;
        }
        for (let i = 1; i < N; i++) {
            let yi = y[i] + v[i] * dt;
            if (yi > sanity)
                yi = sanity;
            else if (yi < -sanity)
                yi = -sanity;
            y[i] = yi;
        }
    }

    function _isStill() {
        if (Math.abs(root._drive) >= 0.1)
            return false;
        const y = root._y;
        const v = root._v;
        if (!y || !v)
            return true;
        for (let i = 0; i < y.length; i++) {
            if (Math.abs(y[i]) > 0.1 || Math.abs(v[i]) > 0.1)
                return false;
        }
        return true;
    }

    function sampleAt(xNorm) {
        const y = root._y;
        if (!y || y.length < 2)
            return 0;
        const N = y.length - 1;
        const idxF = Math.max(0, Math.min(1, xNorm)) * N;
        const i0 = Math.floor(idxF);
        const i1 = Math.min(N, i0 + 1);
        const frac = idxF - i0;
        return y[i0] * (1 - frac) + y[i1] * frac;
    }

    // The frame clock: one step per rendered frame, only while something
    // moves. HELD while the theme crossfades -- the switch is a still picture
    // of the frame before, and an edge that keeps rippling under it is two
    // edges for the length of the fade.
    FrameAnimation {
        running: root.active && !root._flat && root.style !== null && !Theme.crossfading
        onTriggered: {
            root.step(frameTime);
            if (root._isStill()) {
                // Snap the last tenth of a pixel to exactly flat, draw that
                // once, then stop.
                root.resetState();
                root._flat = true;
            }
            topOverlay.requestPaint();
            bottomOverlay.requestPaint();
        }
    }

    // ======================================================================
    // Overlays
    // ======================================================================

    // Decompose displacement `d` (signed px) into [outward, inward]. Strict
    // sign split — positive d is only bulge (clamped), negative d is only cavity
    // (clamped). The overflow redirect (positive → inward) is reserved for the
    // no-padding "negative space" case; with padding it caused concurrent push
    // and pull to paint on the same x when wave amplitude exceeded maxOutwardPx.
    function _decompose(d) {
        if (d >= 0) {
            if (root.maxOutwardPx > 0) {
                return [Math.min(d, root.maxOutwardPx), 0];
            }
            return [0, Math.min(d, root.maxInwardPx)];
        }
        return [0, Math.min(-d, root.maxInwardPx)];
    }

    // Extra height past the flat maxInwardPx so the cavity polygon at inner/outer
    // corners (where curve_y can reach baseY + cornerRadius) can fully extend
    // baseY + cornerR + ins[x] = baseY + cornerR + maxInward without being
    // clipped by the Canvas bottom. Without this, at max pull the polygon got
    // cropped to a horizontal flat at the canvas edge, giving sharp 90° corners
    // where it met the fill's vertical side edge — the "indent limit" artifact.
    readonly property real _topCornerMax: Math.max(_clampR(topLeftCornerRadius), _clampR(topRightCornerRadius))
    readonly property real _bottomCornerMax: Math.max(_clampR(bottomLeftCornerRadius), _clampR(bottomRightCornerRadius))

    // Horizontal margin past the fill's side edges so the cavity polygon's radial
    // outward shift (which at corner endpoints points horizontally) can land
    // outside the fill body. Without this margin the shifted top vertex got
    // clipped at the canvas edge and the polygon's closure ran diagonally back
    // through the fill body's right-edge shadow area — a thin vertical contour
    // line blended into visibility by polygon AA.
    readonly property real _xMargin: 1

    Canvas {
        id: topOverlay
        x: root.fillX - root._xMargin
        y: root.fillY - root.maxOutwardPx
        width: root.fillWidth + 2 * root._xMargin
        height: root.maxOutwardPx + root.maxInwardPx + root._topCornerMax
        antialiasing: true
        renderStrategy: Canvas.Immediate
        visible: root.active

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            const w = width;
            if (w <= 0) return;

            const xM = root._xMargin;
            const fw = w - 2 * xM;  // fill width (canvas-local range is [xM, xM+fw])
            if (fw <= 0) return;
            const baseY = root.maxOutwardPx;  // fill's actual top edge, canvas-local
            const tlR = root._clampR(root.topLeftCornerRadius);
            const trR = root._clampR(root.topRightCornerRadius);
            const N_CORNER = 16;
            const stepFlat = 2;

            // Sample contour vertices in FILL-LOCAL x coords (0..fw). Convert to
            // canvas coords by adding xM when painting the path.
            const xs = [], nys = [], outs = [], ins = [];

            // Taper bulge amplitude (outs) to zero at corner endpoints where
            // the outward normal is horizontal. Polygon top uses vertical-only
            // shift (to keep bulge bounded by fill's horizontal extent) while
            // polygon bottom uses radial inward-by-sw (to align with fill
            // body's d=sw sub-shape). With full outs at endpoints, the two
            // edges diverge by (sw, outs) at the corner, producing a diagonal
            // left edge that cuts through fill body's natural shadow gradient
            // (d=0 shadow → d=sw fill), showing as a visible color seam.
            // Tapering outs to 0 at endpoints collapses the polygon there so
            // fill body's natural corner renders untouched. Smooth ramp to
            // full amplitude at the corner/flat transition so the bulge stays
            // visible across the flat region.
            for (let i = 0; i <= N_CORNER; i++) {
                const s = i / N_CORNER;
                const p = root._tlAt(s, tlR, baseY);
                const d = root.sampleAt(p[0] / fw);
                const pair = root._decompose(d);
                xs.push(p[0]); nys.push(p[1]); outs.push(pair[0] * s); ins.push(pair[1]);
            }

            const flatStart = tlR;
            const flatEnd = fw - trR;
            for (let fx = flatStart + stepFlat; fx < flatEnd; fx += stepFlat) {
                const d = root.sampleAt(fx / fw);
                const pair = root._decompose(d);
                xs.push(fx); nys.push(baseY); outs.push(pair[0]); ins.push(pair[1]);
            }

            for (let i = 0; i <= N_CORNER; i++) {
                const s = i / N_CORNER;
                const p = root._trAt(s, fw, trR, baseY);
                const d = root.sampleAt(p[0] / fw);
                const pair = root._decompose(d);
                xs.push(p[0]); nys.push(p[1]); outs.push(pair[0] * (1 - s)); ins.push(pair[1]);
            }

            const n = xs.length;

            // Outward-normal lookup — flat top uses (0,-1); TL/TR corners use the
            // radial direction from the corner's effective center. Also used for
            // cavity AA shift and shadow-ring inward progression.
            const tlCx = tlR, tlCy = baseY + tlR;
            const trCx = fw - trR, trCy = baseY + trR;
            function _nOut(i) {
                const cx = xs[i], cy = nys[i];
                if (cx <= tlR) {
                    const dx = cx - tlCx, dy = cy - tlCy;
                    const m = Math.sqrt(dx * dx + dy * dy) || 1;
                    return [dx / m, dy / m];
                } else if (cx >= fw - trR) {
                    const dx = cx - trCx, dy = cy - trCy;
                    const m = Math.sqrt(dx * dx + dy * dy) || 1;
                    return [dx / m, dy / m];
                }
                return [0, -1];  // flat top
            }

            // Detect whether there's any push this frame. When idle, skip both bulge
            // polygon and shadow rings so fill body's native ShadowBox shading
            // renders un-perturbed.
            let anyPush = false;
            for (let i = 0; i < n; i++) if (outs[i] > 0.1) { anyPush = true; break; }

            const sw = root.fillShadowWidth;

            if (anyPush) {
                // Bulge body polygon. Top edge = wave-top, shifted purely
                // vertically. At corner endpoints the outward normal is
                // horizontal, so radial shift there pushed the bulge past the
                // fill's vertical inner edge into the bar gap — visible as a
                // horizontal protrusion into the charge-limit-bar area during
                // push. Vertical-only shift keeps the bulge bounded by the
                // fill's natural horizontal extent.
                // Bottom edge = natural contour shifted INWARD by sw
                // (equivalent to ShadowBox's d=sw inner sub-shape), hides the
                // fill body's static top-shadow band so the overlay owns the
                // edge shading during push.
                ctx.beginPath();
                ctx.moveTo(xs[0] + xM, nys[0] - outs[0]);
                for (let i = 1; i < n; i++) ctx.lineTo(xs[i] + xM, nys[i] - outs[i]);
                for (let i = n - 1; i >= 0; i--) {
                    const nv = _nOut(i);
                    ctx.lineTo(xs[i] - nv[0] * sw + xM, nys[i] - nv[1] * sw);
                }
                ctx.closePath();
                ctx.fillStyle = root.fillColor.toString();
                ctx.fill();

                // Concentric shadow rings. Each ring spans [d0, d1] inward from the
                // wave-top along the outward normal, colored per ShadowBox's
                // shadowEasing bezier. Stepping at 0.25px matches ShadowBox's own
                // sub-shape step so the rendering is pixel-close at rest (where
                // wave-top = natural and the overlay reproduces fill body's native
                // inset shadow).
                if (sw > 0) {
                    const subStep = 0.25;
                    const N_rings = Math.max(1, Math.ceil(sw / subStep));
                    for (let ri = 0; ri < N_rings; ri++) {
                        const d0 = ri * subStep;
                        const d1 = Math.min(d0 + subStep, sw);
                        const dMid = (d0 + d1) * 0.5;
                        const f = root._shadowEase(dMid / sw);
                        const color = Mix.c(root.fillShadowColor, root.fillColor, f);

                        ctx.beginPath();
                        // Outer edge at depth d0 from wave-top.
                        //   pos(i) = natural(i) + norm(i) * (outs[i] - d0)
                        for (let i = 0; i < n; i++) {
                            const nv = _nOut(i);
                            const shift = outs[i] - d0;
                            const x = xs[i] + nv[0] * shift + xM;
                            const y = nys[i] + nv[1] * shift;
                            if (i === 0) ctx.moveTo(x, y);
                            else ctx.lineTo(x, y);
                        }
                        // Inner edge at depth d1, right-to-left.
                        for (let i = n - 1; i >= 0; i--) {
                            const nv = _nOut(i);
                            const shift = outs[i] - d1;
                            const x = xs[i] + nv[0] * shift + xM;
                            const y = nys[i] + nv[1] * shift;
                            ctx.lineTo(x, y);
                        }
                        ctx.closePath();
                        ctx.fillStyle = color;
                        ctx.fill();
                    }
                }
            }

            ctx.beginPath();
            const n0 = _nOut(0);
            const off0 = Math.min(1, ins[0]);
            ctx.moveTo(xs[0] + n0[0] * off0 + xM, nys[0] + n0[1] * off0);
            for (let i = 1; i < n; i++) {
                const nv = _nOut(i);
                const o = Math.min(1, ins[i]);
                ctx.lineTo(xs[i] + nv[0] * o + xM, nys[i] + nv[1] * o);
            }
            for (let i = n - 1; i >= 0; i--) {
                const nv = _nOut(i);
                const o = Math.min(1, ins[i]);
                ctx.lineTo(xs[i] + nv[0] * o + xM, nys[i] + ins[i] + nv[1] * o);
            }
            ctx.closePath();
            ctx.fillStyle = root.grooveBgColor.toString();
            ctx.fill();
        }
    }

    Canvas {
        id: bottomOverlay
        x: root.fillX - root._xMargin
        y: root.fillY + root.fillHeight - root.maxInwardPx - root._bottomCornerMax
        width: root.fillWidth + 2 * root._xMargin
        height: root.maxInwardPx + root._bottomCornerMax + root.maxOutwardPx
        antialiasing: true
        renderStrategy: Canvas.Immediate
        visible: root.active

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            const w = width;
            if (w <= 0) return;

            const xM = root._xMargin;
            const fw = w - 2 * xM;
            if (fw <= 0) return;
            const baseY = root.maxInwardPx + root._bottomCornerMax;  // fill's actual bottom edge, canvas-local
            const blR = root._clampR(root.bottomLeftCornerRadius);
            const brR = root._clampR(root.bottomRightCornerRadius);
            const N_CORNER = 16;
            const stepFlat = 2;

            // Sample contour vertices in FILL-LOCAL x coords (0..fw). Taper
            // bulge amplitude to zero at corner endpoints — see top overlay
            // for the reasoning; same seam issue applies symmetrically here.
            const xs = [], nys = [], outs = [], ins = [];

            for (let i = 0; i <= N_CORNER; i++) {
                const s = 1 - i / N_CORNER;
                const p = root._blAt(s, blR, baseY);
                const d = root.sampleAt(p[0] / fw);
                const pair = root._decompose(d);
                xs.push(p[0]); nys.push(p[1]); outs.push(pair[0] * (1 - s)); ins.push(pair[1]);
            }

            const flatStart = blR;
            const flatEnd = fw - brR;
            for (let fx = flatStart + stepFlat; fx < flatEnd; fx += stepFlat) {
                const d = root.sampleAt(fx / fw);
                const pair = root._decompose(d);
                xs.push(fx); nys.push(baseY); outs.push(pair[0]); ins.push(pair[1]);
            }

            for (let i = 0; i <= N_CORNER; i++) {
                const s = i / N_CORNER;
                const p = root._brAt(s, fw, brR, baseY);
                const d = root.sampleAt(p[0] / fw);
                const pair = root._decompose(d);
                xs.push(p[0]); nys.push(p[1]); outs.push(pair[0] * (1 - s)); ins.push(pair[1]);
            }

            const n = xs.length;

            // Outward-normal lookup. Flat bottom = (0,1); corners radial from
            // bottom-corner centers.
            const blCx = blR, blCy = baseY - blR;
            const brCx = fw - brR, brCy = baseY - brR;
            function _nOutBot(i) {
                const cx = xs[i], cy = nys[i];
                if (cx <= blR) {
                    const dx = cx - blCx, dy = cy - blCy;
                    const m = Math.sqrt(dx * dx + dy * dy) || 1;
                    return [dx / m, dy / m];
                } else if (cx >= fw - brR) {
                    const dx = cx - brCx, dy = cy - brCy;
                    const m = Math.sqrt(dx * dx + dy * dy) || 1;
                    return [dx / m, dy / m];
                }
                return [0, 1];  // flat bottom
            }

            let anyPush = false;
            for (let i = 0; i < n; i++) if (outs[i] > 0.1) { anyPush = true; break; }

            const sw = root.fillShadowWidth;

            if (anyPush) {
                // Bulge body: top edge = natural shifted INWARD by sw (into fill,
                // opposite to outward normal), bottom edge = wave-shifted
                // downward purely vertically. At corner endpoints the outward
                // normal is horizontal — radial shift there extended the bulge
                // past the fill's vertical inner edge into the bar gap.
                // Vertical-only keeps it bounded by the fill's natural extent.
                ctx.beginPath();
                for (let i = 0; i < n; i++) {
                    const nv = _nOutBot(i);
                    const x = xs[i] - nv[0] * sw + xM;
                    const y = nys[i] - nv[1] * sw;
                    if (i === 0) ctx.moveTo(x, y);
                    else ctx.lineTo(x, y);
                }
                for (let i = n - 1; i >= 0; i--) {
                    ctx.lineTo(xs[i] + xM, nys[i] + outs[i]);
                }
                ctx.closePath();
                ctx.fillStyle = root.fillColor.toString();
                ctx.fill();

                // Concentric shadow rings — same stepping/bezier as top overlay.
                //   pos(i, d) = natural(i) + norm(i) * (outs[i] - d)
                // outer at d0, inner at d1 = d0 + 0.25.
                if (sw > 0) {
                    const subStep = 0.25;
                    const N_rings = Math.max(1, Math.ceil(sw / subStep));
                    for (let ri = 0; ri < N_rings; ri++) {
                        const d0 = ri * subStep;
                        const d1 = Math.min(d0 + subStep, sw);
                        const dMid = (d0 + d1) * 0.5;
                        const f = root._shadowEase(dMid / sw);
                        const color = Mix.c(root.fillShadowColor, root.fillColor, f);

                        ctx.beginPath();
                        for (let i = 0; i < n; i++) {
                            const nv = _nOutBot(i);
                            const shift = outs[i] - d0;
                            const x = xs[i] + nv[0] * shift + xM;
                            const y = nys[i] + nv[1] * shift;
                            if (i === 0) ctx.moveTo(x, y);
                            else ctx.lineTo(x, y);
                        }
                        for (let i = n - 1; i >= 0; i--) {
                            const nv = _nOutBot(i);
                            const shift = outs[i] - d1;
                            const x = xs[i] + nv[0] * shift + xM;
                            const y = nys[i] + nv[1] * shift;
                            ctx.lineTo(x, y);
                        }
                        ctx.closePath();
                        ctx.fillStyle = color;
                        ctx.fill();
                    }
                }
            }

            ctx.beginPath();
            const n0 = _nOutBot(0);
            const off0 = Math.min(1, ins[0]);
            ctx.moveTo(xs[0] + n0[0] * off0 + xM, nys[0] - ins[0] + n0[1] * off0);
            for (let i = 1; i < n; i++) {
                const nv = _nOutBot(i);
                const o = Math.min(1, ins[i]);
                ctx.lineTo(xs[i] + nv[0] * o + xM, nys[i] - ins[i] + nv[1] * o);
            }
            for (let i = n - 1; i >= 0; i--) {
                const nv = _nOutBot(i);
                const o = Math.min(1, ins[i]);
                ctx.lineTo(xs[i] + nv[0] * o + xM, nys[i] + nv[1] * o);
            }
            ctx.closePath();
            ctx.fillStyle = root.grooveBgColor.toString();
            ctx.fill();
        }
    }
}
