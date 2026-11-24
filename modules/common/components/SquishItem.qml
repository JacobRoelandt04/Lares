pragma ComponentBehavior: Bound

import QtQuick

// ==========================================================================
// SquishItem.qml
//
// Kinetic ball renderer with two draw modes and a unified collision model.
//
// Draw modes:
//   - Free mode (`usePath: false`): ball is drawn as a rotated ellipse whose
//     axes are modulated by velocity (cartoon stretch along motion). Any
//     number of `collisions` carve soft flattened regions into the ellipse.
//   - Path mode (`usePath: true`): ball is drawn as a "kinked pill" whose
//     centerline follows `pathFunc(trackPos)`. Collisions are ignored in
//     this mode.
//
// Collision model (shared contact):
//   Each `collisions` entry is `{ dir, depth, wallFunc }`:
//     - `dir`   (degrees): direction from ball center toward the wall
//                          (0 = +x, 90 = +y).
//     - `depth` (pixels):  nominal overlap of ball into wall before any
//                          deformation.
//     - `wallFunc(s)`:     optional. Given tangent offset `s`, returns the
//                          wall's rest distance from ball center along
//                          `dir`. Null = flat wall at `(R_dir - depth)`.
//   The `pressure` property (0..1) splits the total overlap into ball
//   flattening (`depth * (1 - pressure)`) and wall bulging (`depth *
//   pressure`). The contact surface is the same curve from both sides, so
//   walls / foils can query `contactPoint(i, s)` to draw a perfectly
//   matching bulge with zero gap.
// ==========================================================================
Item {
    id: root

    // ======================================================================
    // PUBLIC API
    // ======================================================================

    // Inner content placed at the logical center of the ball.
    default property alias content: container.data

    // --- Shape ---
    property real baseWidth: 14
    property real baseHeight: 14
    property color color: "#4480F4"

    // --- Mode config ---
    property bool usePath: false
    // function(pos) -> { x: real, y: real, angle: real_degrees }
    property var pathFunc: null
    property real trackPos: 0

    // --- Free-mode shape overrides ---
    // If > 0, bypass the internal velocity-derived squish dimensions.
    property real overrideWidth: 0
    property real overrideHeight: 0

    // --- 2D velocity tracking (free mode) ---
    property real trackX: x + width / 2
    property real trackY: y + height / 2

    // --- Physics tuning (free mode) ---
    property real maxSpeedThreshold: 30.0
    property real maxSquishRatio: 0.5
    property real recoverySpringStiffness: 2.5
    property real recoverySpringDamping: 0.2

    // --- Collisions ---
    // [{ dir: deg, depth: px, wallFunc: null | function(s) -> dist_from_center }]
    property var collisions: []

    // 0 = fully squishy (ball flattens, wall stays put).
    // 1 = fully rigid   (ball stays round, wall bulges to match).
    property real pressure: 0.5

    // --- Visuals ---
    property color shadowColor: "#4480F4"
    property real shadowOpacity: 0.55
    property real shadowBlur: 12.0
    property real shadowOffsetX: 0
    property real shadowOffsetY: 0

    // ======================================================================
    // INTERNAL STATE
    // ======================================================================
    property real _lastX: trackX
    property real _lastY: trackY
    property real _lastTime: Date.now()
    property real _movementAngle: 0
    property real _targetSquish: 1.0
    property real _currentSquish: 1.0
    // Angular momentum of `_movementAngle` (deg per 16ms tick). Carries the
    // squish rotation forward during stop / spring recovery so a U-turn leaves
    // a residual fluid-like swirl, not an instant snap to the last vector.
    property real _angVel: 0

    implicitWidth: baseWidth
    implicitHeight: baseHeight

    // THE TICKER SLEEPS AT REST. One that ran at 60 Hz for the life of the
    // item, whether or not anything moved, would have every slider, rail and
    // reel in the shell waking the CPU sixty times a second to compute a
    // squish of 1.0 from a velocity of 0. It wakes on the
    // first change of the tracked position and sleeps again half a second
    // after the last motion has settled, so a parked ball costs nothing.
    property bool _physicsAwake: false
    property int  _idleTicks: 0
    function _wake() {
        if (root._physicsAwake)
            return;
        // The first tick must see the delta that woke it, not a dt of hours.
        root._lastTime = Date.now() - 16;
        root._idleTicks = 0;
        root._physicsAwake = true;
    }
    onTrackXChanged: root._wake()
    onTrackYChanged: root._wake()

    Timer {
        id: physicsTicker
        interval: 16
        running: !root.usePath && root._physicsAwake
        repeat: true
        onTriggered: {
            let now = Date.now();
            let dt = Math.max(1, now - root._lastTime);

            let dx = root.trackX - root._lastX;
            let dy = root.trackY - root._lastY;

            let speed = Math.sqrt(dx * dx + dy * dy) / dt * 16.0;

            let prevAngle = root._movementAngle;

            if (speed > 0.1) {
                let newAngle = Math.atan2(dy, dx) * 180 / Math.PI;
                let diff = newAngle - root._movementAngle;
                while (diff < -180) diff += 360;
                while (diff > 180) diff -= 360;

                if (root._targetSquish > 0.95) {
                    // Ball was at rest — snap to new direction, but seed
                    // angular velocity so immediate path changes still feel
                    // continuous rather than teleported.
                    root._movementAngle = newAngle;
                } else {
                    // In-flight heading update blends toward new direction;
                    // the residual of `diff` feeds into `_angVel` below so a
                    // tight turn leaves a rotational inertia tail.
                    root._movementAngle += diff * 0.4;
                }

                let speedFactor = Math.min(1.0, speed / root.maxSpeedThreshold);
                let easedFactor = 1.0 - Math.pow(1.0 - speedFactor, 3);
                root._targetSquish = 1.0 - (1.0 - root.maxSquishRatio) * easedFactor;
            } else {
                // No input — let angular momentum continue rotating the squish
                // profile, decaying over time. This produces a tide-like
                // swirl after a sharp U-turn.
                root._movementAngle += root._angVel * 0.5;
                root._targetSquish = 1.0;
            }

            let frameDAng = root._movementAngle - prevAngle;
            while (frameDAng > 180) frameDAng -= 360;
            while (frameDAng < -180) frameDAng += 360;
            root._angVel = root._angVel * 0.82 + frameDAng * 0.28;
            if (speed <= 0.1) root._angVel *= 0.88;

            root._lastX = root.trackX;
            root._lastY = root.trackY;
            root._lastTime = now;

            // Nothing moving, nothing swirling, the spring home: sleep.
            const still = speed <= 0.1 && Math.abs(root._angVel) < 0.01
                       && Math.abs(root._currentSquish - 1.0) < 0.002;
            root._idleTicks = still ? root._idleTicks + 1 : 0;
            if (root._idleTicks > 30)
                root._physicsAwake = false;
        }
    }

    Behavior on _currentSquish {
        SpringAnimation {
            spring: root.recoverySpringStiffness
            damping: root.recoverySpringDamping
            mass: 1.0
        }
    }

    Binding {
        target: root
        property: "_currentSquish"
        value: root._targetSquish
        when: !root.usePath
    }

    // ======================================================================
    // DERIVED SHAPE PARAMS
    //
    // Cartoon stretch: when moving fast, ball elongates ALONG motion and
    // squishes perpendicular. Overshoot (squish > 1.0) flips the axes and
    // adds 90° to the draw angle for the classic elastic-bounce beat.
    // ======================================================================
    readonly property real _cw: overrideWidth > 0
        ? overrideWidth
        : baseWidth * (root._currentSquish <= 1.0 ? 1.0 / Math.max(0.01, root._currentSquish) : root._currentSquish)
    readonly property real _ch: overrideHeight > 0
        ? overrideHeight
        : baseHeight * (root._currentSquish <= 1.0 ? root._currentSquish : 1.0 / root._currentSquish)
    readonly property real _drawAngle:
        root._movementAngle + ((overrideWidth <= 0 && root._currentSquish > 1.0) ? 90 : 0)
    readonly property real _drawAngleRad: _drawAngle * Math.PI / 180

    // ======================================================================
    // SHARED MATH HELPERS
    // ======================================================================
    function _smin(a, b, k) {
        if (k <= 1e-4) return Math.min(a, b);
        let h = Math.max(0.0, Math.min(1.0, 0.5 + 0.5 * (b - a) / k));
        return b * (1.0 - h) + a * h - k * h * (1.0 - h);
    }

    // Ellipse radius in world-angle direction `worldAngleRad`.
    function _ellipseR(worldAngleRad) {
        let wd = _cw / 2;
        let ht = _ch / 2;
        let la = worldAngleRad - _drawAngleRad;
        let c = Math.cos(la), s = Math.sin(la);
        let denom = Math.sqrt((ht * c) * (ht * c) + (wd * s) * (wd * s));
        return denom < 1e-6 ? 0 : (wd * ht) / denom;
    }

    // For a given collision index, return { R_dir, dir_rad, depth, wallFunc, k }.
    // `k` is the optional per-collision smin smoothing width override.
    function _colliderInfo(i) {
        let cols = root.collisions || [];
        if (i < 0 || i >= cols.length) return null;
        let c = cols[i];
        let dir_rad = (c.dir || 0) * Math.PI / 180;
        return {
            dir_rad: dir_rad,
            depth: Math.max(0, c.depth || 0),
            wallFunc: c.wallFunc || null,
            k: (c.k !== undefined && c.k !== null) ? c.k : null,
            R_dir: _ellipseR(dir_rad)
        };
    }

    // ======================================================================
    // PUBLIC QUERIES (for walls / foils to draw matching contact)
    //
    // Both functions return world coordinates in the SquishItem's own frame
    // (origin at this Item's top-left). Callers that draw in a different
    // parent must use `mapFromItem(squishItem, pt.x, pt.y)` to translate.
    // ======================================================================

    // World-coord center of the ball (from which all collisions are measured).
    // In free mode this is simply the midpoint of the Item; in path mode it's
    // `pathFunc(trackPos).{x, y}`.
    function ballCenter() {
        if (usePath && pathFunc) {
            let p = pathFunc(trackPos);
            return { x: p.x, y: p.y };
        }
        return { x: width / 2, y: height / 2 };
    }

    // Point on the shared contact surface for collision `i` at tangent offset
    // `s` (pixels; s=0 is the contact center, |s|=contactHalfWidth(i) is the
    // edge of contact). Returns null if the collision has no overlap.
    function contactPoint(i, s) {
        let info = _colliderInfo(i);
        if (!info || info.depth <= 0) return null;

        let R = info.R_dir;
        let abs_s = Math.abs(s);
        let u_ball_rest = abs_s < R ? Math.sqrt(R * R - s * s) : 0;
        let u_wall_rest = info.wallFunc
            ? info.wallFunc(s)
            : (R - info.depth);
        let p = Math.max(0, Math.min(1, pressure));
        let u = p * u_ball_rest + (1 - p) * u_wall_rest;

        let c = ballCenter();
        let dx = Math.cos(info.dir_rad), dy = Math.sin(info.dir_rad);
        let tx = -Math.sin(info.dir_rad), ty = Math.cos(info.dir_rad);
        return { x: c.x + u * dx + s * tx, y: c.y + u * dy + s * ty };
    }

    // Half-width (in pixels) of the contact region along the wall's tangent.
    // Where ball's rest surface meets wall's rest surface.
    function contactHalfWidth(i) {
        let info = _colliderInfo(i);
        if (!info || info.depth <= 0) return 0;
        let R = info.R_dir;
        let d = info.depth;
        if (d >= R) return R;
        if (info.wallFunc) {
            // Numerical root-find: largest |s| where ball_rest(s) >= wall_rest(s).
            let hi = R;
            let lo = 0;
            for (let k = 0; k < 24; k++) {
                let mid = 0.5 * (lo + hi);
                let br = Math.sqrt(Math.max(0, R * R - mid * mid));
                let wr = info.wallFunc(mid);
                if (br > wr) lo = mid; else hi = mid;
            }
            return lo;
        }
        return Math.sqrt(Math.max(0, 2 * R * d - d * d));
    }

    // ======================================================================
    // CONTOUR GENERATION
    // ======================================================================
    readonly property var _contour: usePath && pathFunc ? _buildPathContour() : _buildRadialContour()

    function _buildRadialContour() {
        let wd = _cw / 2;
        let ht = _ch / 2;
        let cx = width / 2;
        let cy = height / 2;

        if (wd < 0.1 || ht < 0.1) {
            return { radial: true, pts: [], bx: cx, by: cy, bw: 0, bh: 0, cx: cx, cy: cy };
        }

        let N = 96;
        let pts = [];
        let mnX = Infinity, mnY = Infinity, mxX = -Infinity, mxY = -Infinity;

        // Precompute collision data once per frame.
        let cols = root.collisions || [];
        let colData = [];
        for (let i = 0; i < cols.length; i++) {
            let info = _colliderInfo(i);
            if (info && info.depth > 0) colData.push(info);
        }
        let p = Math.max(0, Math.min(1, pressure));

        for (let i = 0; i < N; i++) {
            let alpha = (2 * Math.PI * i) / N;
            let cosA = Math.cos(alpha), sinA = Math.sin(alpha);
            let r = _ellipseR(alpha);

            // ------------------------------------------------------------
            // VOLUME-PRESERVING LATERAL BULGE
            //
            // Material flattened by each collision has to go somewhere. We
            // add an additive bulge with a sin²(δ) profile so it peaks on
            // the flanks perpendicular to the collision normal and is zero
            // on the cut side itself (and mostly zero on the opposite
            // side). The total extra perimeter area is tuned to match the
            // chord-cut area lost on a circle of radius R_d:
            //   lost = R²·acos(1 − d/R) − (R − d)·√(2Rd − d²)
            // Spread as K·sin²(δ) around the ring:   ∫K·sin²(δ)·R dδ ≈ πRK
            // ------------------------------------------------------------
            let totalBulge = 0;
            for (let j = 0; j < colData.length; j++) {
                let c = colData[j];
                if (c.wallFunc) continue;
                let delta = alpha - c.dir_rad;
                while (delta > Math.PI) delta -= 2 * Math.PI;
                while (delta < -Math.PI) delta += 2 * Math.PI;

                let R_d = c.R_dir;
                let d = c.depth * (1 - p);
                if (d <= 0 || R_d <= 0) continue;
                let dClamped = Math.min(d, R_d * 0.999);

                let arg = Math.max(-1, Math.min(1, 1 - dClamped / R_d));
                let lost = R_d * R_d * Math.acos(arg)
                         - (R_d - dClamped) * Math.sqrt(Math.max(0,
                             2 * R_d * dClamped - dClamped * dClamped));
                if (!isFinite(lost) || lost <= 0) continue;

                let K = lost / (R_d * Math.PI);
                let sinD = Math.sin(delta);
                totalBulge += K * sinD * sinD;
            }
            r += totalBulge;

            // ------------------------------------------------------------
            // COLLISION CUTS
            //
            // Tangent offset `s` is solved by fixed-point iteration on
            //   tan(δ) = s / u_contact(s)
            // not the approximation `s ≈ r·sin(δ)` — using the
            // rotated-ellipse radius there distorts the flat surface when
            // the velocity-squish axes are not perpendicular to the wall
            // (the "pie with a slice cut out" artifact during sliding).
            // ------------------------------------------------------------
            for (let j = 0; j < colData.length; j++) {
                let c = colData[j];
                let delta = alpha - c.dir_rad;
                while (delta > Math.PI) delta -= 2 * Math.PI;
                while (delta < -Math.PI) delta += 2 * Math.PI;

                let cos_delta = Math.cos(delta);
                if (cos_delta <= 0.01) continue;
                let sin_delta = Math.sin(delta);
                let tanD = sin_delta / cos_delta;

                let R_d = c.R_dir;
                if (R_d <= 0) continue;

                let s = 0;
                for (let it = 0; it < 4; it++) {
                    let uW = c.wallFunc ? c.wallFunc(s) : (R_d - c.depth);
                    let uB = (Math.abs(s) < R_d)
                           ? Math.sqrt(R_d * R_d - s * s) : 0;
                    let uC = p * uB + (1 - p) * uW;
                    if (uC < 0) uC = 0;
                    let sNew = uC * tanD;
                    if (Math.abs(sNew) >= R_d) {
                        s = Math.sign(sNew || 1) * R_d * 0.999;
                        break;
                    }
                    s = sNew;
                }

                let uWf = c.wallFunc ? c.wallFunc(s) : (R_d - c.depth);
                let uBf = (Math.abs(s) < R_d)
                        ? Math.sqrt(R_d * R_d - s * s) : 0;

                if (uWf >= uBf) continue;
                // Curved walls: skip when wall is past center (curved
                // away, not a real contact from this direction). Flat
                // walls: only skip at full anti-extent (deep uniform
                // penetration past center is a valid cut).
                if (c.wallFunc ? uWf <= 0 : uWf <= -uBf) continue;

                let u_contact = p * uBf + (1 - p) * uWf;
                if (u_contact < 0) u_contact = 0;

                let r_cut = u_contact / cos_delta;

                // Smoothing width scales with radius AND pressure: a rigid
                // ball (pressure→1) has more internal pressure so its
                // surface resists sharp creases more, giving a visibly
                // rounded contact edge. Callers can override per-collision
                // by setting `c.k` — useful when the wallFunc already
                // delivers a smooth C⁰/C¹ shape and further smin rounding
                // would only introduce a concave dip at the corner.
                let k_sm = (c.k !== null)
                    ? c.k
                    : Math.max(2.0,
                          R_d * (0.12 + p * 0.35) + c.depth * 0.25);
                r = _smin(r, r_cut, k_sm);
            }

            let x = cx + r * cosA;
            let y = cy + r * sinA;
            pts.push(x); pts.push(y);

            if (x < mnX) mnX = x;
            if (x > mxX) mxX = x;
            if (y < mnY) mnY = y;
            if (y > mxY) mxY = y;
        }

        let pad = shadowBlur * 2 + Math.max(Math.abs(shadowOffsetX), Math.abs(shadowOffsetY)) + 2;
        return {
            radial: true,
            pts: pts,
            bx: mnX - pad, by: mnY - pad,
            bw: (mxX - mnX) + 2 * pad, bh: (mxY - mnY) + 2 * pad,
            cx: cx, cy: cy
        };
    }

    function _buildPathContour() {
        let cw = _cw, ch = _ch;
        let halfW = cw / 2, halfH = ch / 2;

        if (halfW < 0.1 || halfH < 0.1) {
            return { radial: false, top: [], bot: [], bx: 0, by: 0, bw: 0, bh: 0, cx: width / 2, cy: height / 2 };
        }

        let N = 32;
        let capR = Math.min(halfW, halfH);
        let straight = Math.max(0, halfW - capR);

        let top = [];
        let bot = [];
        let mnX = Infinity, mnY = Infinity, mxX = -Infinity, mxY = -Infinity;
        let centerX = width / 2;
        let centerY = height / 2;

        for (let i = 0; i <= N; i++) {
            let d = -halfW * Math.cos(Math.PI * i / N);
            let xy = pathFunc(trackPos + d);

            if (i === N / 2) {
                centerX = xy.x;
                centerY = xy.y;
            }

            let ang = xy.angle * Math.PI / 180;
            let px = -Math.sin(ang);
            let py = Math.cos(ang);

            let absd = Math.abs(d);
            let lh;
            if (absd <= straight) {
                lh = halfH;
            } else {
                let cd = absd - straight;
                lh = (cd >= capR) ? 0 : capR * Math.sqrt(1 - (cd / capR) * (cd / capR));
            }

            let tx = xy.x + px * lh;
            let ty = xy.y + py * lh;
            let bx = xy.x - px * lh;
            let by = xy.y - py * lh;

            top.push(tx); top.push(ty);
            bot.push(bx); bot.push(by);

            mnX = Math.min(mnX, tx, bx);
            mnY = Math.min(mnY, ty, by);
            mxX = Math.max(mxX, tx, bx);
            mxY = Math.max(mxY, ty, by);
        }

        let pad = shadowBlur * 2 + Math.max(Math.abs(shadowOffsetX), Math.abs(shadowOffsetY)) + 2;
        return {
            radial: false,
            top: top, bot: bot,
            bx: mnX - pad, by: mnY - pad,
            bw: (mxX - mnX) + 2 * pad, bh: (mxY - mnY) + 2 * pad,
            cx: centerX, cy: centerY
        };
    }

    // ======================================================================
    // CANVAS RENDERER
    //
    // THE BALL DOES NOT REDRAW ITSELF TO MOVE.
    //
    // `onPaint` takes `ox, oy` from the canvas's own x/y and draws every point
    // as `pt - ox`, so the drawing is ALREADY in canvas-local coordinates and
    // the whole of a translation is carried by the Item's position. When the
    // ball only slides along a straight track, the pixels it would paint are
    // the pixels already on it.
    //
    // A repaint triggered by `onCRefChanged` on a `var` holding a FRESH OBJECT
    // each evaluation would fire every frame, whether or not anything about
    // the drawing had changed. What it would fire is a ~66-point polygon fill
    // with `ctx.shadowBlur` set, which is the expensive kind, on the GUI
    // thread, at the frame rate.
    //
    // So the trigger is a CHECK. `_paintInputs` notifies on every change of
    // anything the paint reads; what it starts is a comparison against the
    // outline last actually painted, in local coordinates, and the raster only
    // runs when that comparison fails. Sixty-six float compares instead of a
    // shadowed fill.
    //
    // It is honest by construction rather than by assumption: the test is the
    // geometry that WOULD be drawn, not a proxy for it. On a curved path -- the
    // gooey bar's ball going round a corner, Workspaces.qml -- the local
    // outline really does change as it travels, the comparison fails, and it
    // repaints. Same for the squish, for a moving
    // `overrideWidth`/`overrideHeight`, and for the ends of the audio rail
    // where `_ballH` is still on its smoothstep.
    //
    // The epsilon is not optional. `(trackPos + dx) + d` and `trackPos + d` do
    // not round identically, so an exact test would never match and the gate
    // would silently never fire -- which looks exactly like working.
    // ======================================================================
    // While the physics is awake a ball that has stopped going anywhere still rings on its spring for seconds, a change of hundredths of a pixel per frame, and every paint
    // is a software shadow blur (~3 ms): 16 ms of polish a frame with an audio popup's rows at rest. Awake the paint follows at a twentieth of a pixel, and the rest is exact:
    // the last paint when it falls asleep is what stays.
    readonly property real _samePx: !root.usePath && root._physicsAwake ? 0.05 : 0.001
    on_PhysicsAwakeChanged: {
        if (!root._physicsAwake)
            root._paintIfStale();
    }
    // THE FIRST PAINT IS THE ITEM'S OWN, NOT THE PHYSICS'. `_paintInputs` notifies on a CHANGE, and a ball made with its inputs already final (a slider
    // opening, a tab's rows coming back) never has one: the canvas stayed 0 x 0 until the ticker had woken, run its 30 idle ticks and slept (~0.5 s), so the
    // ball came in when the opening ended. A ball is painted when it is made.
    Component.onCompleted: root._paintIfStale()
    // The box follows the paint: a canvas repaints when it is resized, which would undo the gate above.
    property real _boxW: 0
    property real _boxH: 0
    function _paintIfStale() {
        if (root._paintIsCurrent() && root._boxW > 0)
            return;
        const c = root._contour;
        root._boxW = c.bw;
        root._boxH = c.bh;
        ballCanvas.requestPaint();
    }

    // The outline last actually painted, local to the canvas, plus every other
    // value `onPaint` reads. Null until the first paint.
    property var _painted: null

    function _localOf(arr, ox, oy) {
        if (!arr)
            return null;
        const out = new Array(arr.length);
        for (let i = 0; i < arr.length; i += 2) {
            out[i] = arr[i] - ox;
            out[i + 1] = arr[i + 1] - oy;
        }
        return out;
    }

    function _sameLocal(now, was, ox, oy) {
        if (!now || !was || now.length !== was.length)
            return false;
        const e = root._samePx;
        for (let i = 0; i < now.length; i += 2) {
            if (Math.abs((now[i] - ox) - was[i]) > e)
                return false;
            if (Math.abs((now[i + 1] - oy) - was[i + 1]) > e)
                return false;
        }
        return true;
    }

    function _paintIsCurrent() {
        const p = root._painted;
        const c = root._contour;
        if (!p || !c)
            return false;
        const e = root._samePx;
        if (!!c.radial !== !!p.radial)
            return false;
        if (Math.abs(c.bw - p.bw) > e || Math.abs(c.bh - p.bh) > e)
            return false;
        if (p.color !== String(root.color) || p.shadowColor !== String(root.shadowColor))
            return false;
        if (Math.abs(p.shadowOpacity - root.shadowOpacity) > e
            || Math.abs(p.shadowBlur - root.shadowBlur) > e
            || Math.abs(p.shadowOffsetX - root.shadowOffsetX) > e
            || Math.abs(p.shadowOffsetY - root.shadowOffsetY) > e)
            return false;
        // Against the origin the NEW drawing would use, which is the contour's
        // own corner -- the canvas's x/y follow it by binding.
        if (c.radial)
            return root._sameLocal(c.pts, p.pts, c.bx, c.by);
        return root._sameLocal(c.top, p.top, c.bx, c.by)
            && root._sameLocal(c.bot, p.bot, c.bx, c.by);
    }

    // Everything `onPaint` reads. A `var` returning a fresh object notifies on
    // every change of any of them, which is what makes this the CHECK's
    // trigger; `color` is in here rather than on its own Connections because
    // the paint reads it and the gate has to know that.
    readonly property var _paintInputs: ({
            contour: root._contour,
            color: String(root.color),
            shadowColor: String(root.shadowColor),
            shadowOpacity: root.shadowOpacity,
            shadowBlur: root.shadowBlur,
            shadowOffsetX: root.shadowOffsetX,
            shadowOffsetY: root.shadowOffsetY
        })

    ScaledCanvas {
        id: ballCanvas
        x: root._contour.bx
        y: root._contour.by
        width: root._boxW
        height: root._boxH
        antialiasing: true

        Connections {
            target: root
            function on_PaintInputsChanged() {
                root._paintIfStale();
            }
        }

        onDraw: (ctx, cw, ch) => {
            let c = root._contour;
            if (!c) return;

            let ox = x, oy = y;

            ctx.shadowColor = Qt.rgba(
                root.shadowColor.r, root.shadowColor.g, root.shadowColor.b, root.shadowOpacity);
            ctx.shadowBlur = root.shadowBlur;
            ctx.shadowOffsetX = root.shadowOffsetX;
            ctx.shadowOffsetY = root.shadowOffsetY;

            ctx.beginPath();
            if (c.radial) {
                let pts = c.pts;
                if (pts.length < 4) return;
                ctx.moveTo(pts[0] - ox, pts[1] - oy);
                for (let i = 2; i < pts.length; i += 2)
                    ctx.lineTo(pts[i] - ox, pts[i + 1] - oy);
            } else {
                let t = c.top, b = c.bot;
                if (t.length < 2) return;
                ctx.moveTo(t[0] - ox, t[1] - oy);
                for (let i = 2; i < t.length; i += 2)
                    ctx.lineTo(t[i] - ox, t[i + 1] - oy);
                for (let i = b.length - 2; i >= 0; i -= 2)
                    ctx.lineTo(b[i] - ox, b[i + 1] - oy);
            }
            ctx.closePath();

            ctx.fillStyle = root.color;
            ctx.fill();

            // What is now ON the canvas, in the coordinates it was drawn in, so
            // the next contour can be compared against the drawing rather than
            // against the numbers that produced it.
            root._painted = {
                radial: !!c.radial,
                bw: c.bw,
                bh: c.bh,
                top: c.radial ? null : root._localOf(c.top, ox, oy),
                bot: c.radial ? null : root._localOf(c.bot, ox, oy),
                pts: c.radial ? root._localOf(c.pts, ox, oy) : null,
                color: String(root.color),
                shadowColor: String(root.shadowColor),
                shadowOpacity: root.shadowOpacity,
                shadowBlur: root.shadowBlur,
                shadowOffsetX: root.shadowOffsetX,
                shadowOffsetY: root.shadowOffsetY
            };
        }
    }

    // ======================================================================
    // LOGICAL CENTER CONTAINER
    // ======================================================================
    Item {
        id: container
        x: root._contour.cx - width / 2
        y: root._contour.cy - height / 2
        width: root.baseWidth
        height: root.baseHeight
    }
}
