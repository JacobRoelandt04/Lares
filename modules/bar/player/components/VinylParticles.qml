pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects

import "../../../common/particles"
import "../../../common/theme"
import "../../../common/components"

// =============================================================================
// VinylParticles.qml
//
// The popup's acknowledgement burst: a small ring of sparks thrown from a point,
// fired by hand.
//
//     burst(x, y, strength)
//
// The one burst is fired from the sidebar, to say "I queued that". The record's
// own landings throw no sparks.
//
// COORDINATES
//   This item's own, in px. There is no mapping: the caller maps into
//   whatever item this fills before it calls.
//
// OVERSCAN AND THE EDGE
//   The particle Canvas clips to its own bounds with no warning, so the pool is
//   grown `particleMargin` past this item on every side and the whole layer --
//   canvas plus bloom -- is faded out toward that boundary by
//   `shaders/edge_fade.frag`. A spark leaving the popup dims away instead of
//   ending on a straight line. Same block as PhaseRail's, minus the rail.
//
// WHAT IS DELIBERATELY NOT GATED
//   The pool runs unconditionally. Its own 16 ms timer is already gated on
//   there being live particles, and gating `running` on `enabled` instead would
//   freeze a cloud mid-flight: `hasParticles` is cleared only inside
//   `Canvas.onPaint`, so a pool stopped with particles alive latches the flag
//   true forever and every downstream gate with it. `enabled` therefore blocks
//   EMISSION and hides the layer, and whatever is already in the air drains
//   normally -- under a second -- and clears itself.
// =============================================================================
Item {
    id: root

    // Device px per design px here (the nearest ScaleRoot's, else the window's): the layers below are made at the glass's resolution.
    DeviceScale {
        id: dev
    }

    // ======================================================================
    // PUBLIC API
    // ======================================================================

    // The tone every spark is drawn in. A property, not a literal, and never
    // eased: the theme is already one clock, so a Behavior here would lag the
    // switch. Alpha is applied per particle by `_toHex`, which is why this is a
    // colour and not a hex string.
    property color sparkColor: Theme.accent

    // Emission gate: Item's OWN `enabled`, deliberately not redeclared. It is
    // already a bool that defaults true, redeclaring it shadows the base
    // member (qmllint says so), and an overlay with no input items has no
    // other use for it. The host sets `enabled: false` when the popup closes,
    // so no sparks are thrown behind a closed popup, and an overlay that lands
    // inside a disabled subtree goes quiet with it, which is right.

    // The pool. READ ONCE, at the pool's Component.onCompleted
    // (ParticleSystem.qml) -- a control panel that binds a slider to it
    // changes nothing after load, with no warning. A pool size is a
    // construction-time number, not a knob.
    property int maxParticles: 220

    // Is anything alive? A host gates its own expensive passes on this; it is
    // false again within a second of the last burst.
    readonly property bool active: pool.hasParticles

    // How many particles are actually in the air. Reaching into the pool's
    // `_system` is what a probe needs and what `active` cannot give: a count
    // that says the burst was the size it claims to be.
    function liveCount() { return pool._system ? pool._system.getActiveParticles().length : 0; }

    // Fire a burst, in this item's own coordinates.
    function burst(x, y, strength) { root._emit(x, y, strength); }

    // ======================================================================
    // LOOK
    // ======================================================================
    property real particleSizeScale: 1.0

    // Overscan: how far past this item the pool extends, and where the fade to
    // nothing sits inside that overscan. Defaults match PhaseRail's, which are
    // tuned for the eva-light surface.
    property real particleMargin: 46
    property real particleEdgeLeft: root.particleMargin
    property real particleEdgeRight: root.particleMargin
    property real particleEdgeTop: root.particleMargin
    property real particleEdgeBottom: root.particleMargin
    property real particleFadeWidth: 18

    // Speed glow: a spark leaving fast flares, which is the whole reading of a
    // burst. Same numbers as the rail's, so the two look like one material.
    property real glowSpeedRef: 2600
    property real glowMax: 2.6
    property real glowSizeGain: 0.7

    // Bloom. 0.85 brightness is the LIGHT-surface value; the battery's 1.2 is
    // for its dark mockup and washes out here.
    property real bloomBlur: 22
    property real bloomStrength: 0.32
    property real bloomBrightness: 0.85

    // The burst itself: a ring, evenly spaced and jittered, quiet in every term
    // that is energy. It is being PLACED, not thrown -- the numbers are the
    // "settle" tier's, which is the shape of the queue's acknowledgement.
    property int burstCount: 16
    property real burstSpeedMin: 90
    property real burstSpeedMax: 190
    property real burstSpreadDeg: 26         // jitter around the radial direction
    property int burstLifetimeMs: 460
    property int burstHistoryLen: 5
    property real burstDrag: 3.0
    property real burstSizeStart: 2.2
    property real burstSizeEnd: 0.5
    property real burstDeathFadeFraction: 0.4
    // px of radial scatter on the ring, OUTWARD only. A jitter that went both
    // ways would put a quarter of the ring on the far side of the point from the
    // direction it is thrown in -- a spark travelling back across its own
    // origin, which is the one thing a burst may not do. It would read as noise
    // at the centre.
    property real burstJitter: 5
    property real burstAngleJitter: 0.7      // fraction of the even angular spacing
    property real burstGravity: 200          // px/s^2 down, so the ring settles

    // ======================================================================
    // EMISSION
    // ======================================================================

    // Alpha-first hex, the form particles.js actually parses. Anything that is
    // not #RRGGBB or #AARRGGBB silently becomes opaque white in that parser,
    // which is why the tone never travels as a bare string.
    function _hex2(n) {
        const v = Math.max(0, Math.min(255, Math.round(n)));
        return (v < 16 ? "0" : "") + v.toString(16);
    }
    function _toHex(col, alpha) {
        return "#" + root._hex2(alpha * 255)
                   + root._hex2(col.r * 255)
                   + root._hex2(col.g * 255)
                   + root._hex2(col.b * 255);
    }

    // A constant downward acceleration, as ONE object shared by the whole
    // burst: particles.js only reads `.x`/`.y` off what the closure returns,
    // so allocating a fresh one per particle per frame would be pure garbage.
    readonly property var _gravity: ({ x: 0, y: root.burstGravity })
    function _gravityField() {
        if (root.burstGravity === 0)
            return null;
        const f = root._gravity;
        return function(px, py, t) { return f; };
    }

    // Evenly spaced so the circle actually reads as one, jittered so it is not
    // a cog. Each particle is its own `emit(cfg, 1)` -- `emit(cfg, N)` would
    // spawn N IDENTICAL particles, which is a spoke.
    function _emit(x, y, strength) {
        if (!root.enabled || !pool)
            return;

        // Strength scales the count linearly -- a weaker burst is FEWER sparks,
        // which is what the eye reads -- and the speed only sub-linearly, so a
        // small one still leaves the point rather than dribbling.
        const n = Math.max(0, Math.round(root.burstCount * Math.max(0, strength)));
        if (n === 0)
            return;
        const speedScale = 0.65 + 0.35 * Math.max(0, strength);

        const cx = x + root.particleMargin;
        const cy = y + root.particleMargin;
        const colStart = root._toHex(root.sparkColor, 1.0);
        const colEnd = root._toHex(root.sparkColor, 0.0);
        const field = root._gravityField();
        const sizeK = root.particleSizeScale;
        const step = 2 * Math.PI / n;
        const spread = root.burstSpreadDeg * Math.PI / 180;

        for (let i = 0; i < n; i++) {
            const a = i * step + (Math.random() - 0.5) * step * root.burstAngleJitter;
            const r = Math.random() * root.burstJitter;
            const spd = (root.burstSpeedMin + Math.random() * (root.burstSpeedMax - root.burstSpeedMin)) * speedScale;
            const va = a + (Math.random() - 0.5) * 2 * spread;
            pool.emit({
                x: cx + Math.cos(a) * r, y: cy + Math.sin(a) * r,
                vx: Math.cos(va) * spd, vy: Math.sin(va) * spd,
                lifetime: root.burstLifetimeMs,
                maxHistory: root.burstHistoryLen,
                sizeStart: root.burstSizeStart * sizeK, sizeEnd: root.burstSizeEnd * sizeK,
                colorStart: colStart, colorEnd: colEnd,
                drag: root.burstDrag,
                deathFadeFraction: root.burstDeathFadeFraction,
                forceField: field,
                glowSpeedRef: root.glowSpeedRef,
                glowMax: root.glowMax,
                glowSizeGain: root.glowSizeGain
            }, 1);
        }
    }

    // ======================================================================
    // THE LAYER
    // ======================================================================
    Item {
        id: particleLayer
        x: -root.particleMargin
        y: -root.particleMargin
        width: root.width + root.particleMargin * 2
        height: root.height + root.particleMargin * 2

        // `enabled` hides the layer rather than stopping the pool; see the
        // header. Opacity, not `visible`, because a Cooperative Canvas that is
        // made visible again shows one garbage frame.
        opacity: root.enabled ? 1 : 0

        // Inset of each fade-zero line from the layer's own edge, px. An edge
        // AT the margin sits on the layer's boundary (inset 0); a smaller one
        // moves inward. Clamped so an edge past the margin lands on it.
        readonly property real _insetL: Math.max(0, root.particleMargin - root.particleEdgeLeft)
        readonly property real _insetR: Math.max(0, root.particleMargin - root.particleEdgeRight)
        readonly property real _insetT: Math.max(0, root.particleMargin - root.particleEdgeTop)
        readonly property real _insetB: Math.max(0, root.particleMargin - root.particleEdgeBottom)
        readonly property real _w: Math.max(1, particleLayer.width)
        readonly property real _h: Math.max(1, particleLayer.height)

        layer.enabled: root.enabled && root.active
        layer.textureSize: dev.texSize(particleLayer._w, particleLayer._h)
        layer.effect: ShaderEffect {
            property var source
            property vector4d edges: Qt.vector4d(
                particleLayer._insetL / particleLayer._w,
                particleLayer._insetT / particleLayer._h,
                1 - particleLayer._insetR / particleLayer._w,
                1 - particleLayer._insetB / particleLayer._h)
            property vector2d fade: Qt.vector2d(
                root.particleFadeWidth / particleLayer._w,
                root.particleFadeWidth / particleLayer._h)
            fragmentShader: "../../../common/components/shaders/edge_fade.frag.qsb"
        }

        ParticleSystem {
            id: pool
            anchors.fill: parent
            maxParticles: root.maxParticles
            z: 3
        }

        // A SIBLING MultiEffect, not a layer.effect: as a sibling it draws a
        // blurred copy over the still-visible canvas, which is the additive
        // glow. As a layer.effect it would REPLACE the sparks with their own
        // blur. Gated on particles existing, not merely on the feature being
        // on -- a MultiEffect keeps blurring a blank canvas every frame.
        MultiEffect {
            source: pool
            anchors.fill: parent
            blurEnabled: true
            blurMax: root.bloomBlur
            blur: root.bloomStrength
            brightness: root.bloomBrightness
            // Off, and it costs nothing to have it off. With auto-padding on, a
            // MultiEffect grows its own rect by the blur radius and renders
            // that much more of a blur chain -- 22 px on every side of a
            // 628 x 619 layer, which is 15 % more pixels through every pass.
            // Every one of them is then thrown away: `particleLayer` is a
            // layer, and a layer's FBO is the ITEM's rect, so anything a child
            // draws outside it is clipped whether it was rendered or not.
            autoPaddingEnabled: false
            z: 4
            visible: root.enabled && pool.hasParticles
        }
    }
}
