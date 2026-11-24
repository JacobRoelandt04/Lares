import QtQuick
import "../components"
import "particles.js" as Logic

Item {
    id: root
    
    property int maxParticles: 500
    property bool running: true
    // A canvas that is bigger than where its particles are meant to be seen lets them leave it softly: over
    // the last `fade*` px of an edge a particle's alpha goes to 0 (a smoothstep; its head, for a trail).
    // 0 -- the default -- is a hard edge. A host whose canvas ends at a screen edge (the top of
    // the bar) leaves that side at 0.
    property real fadeLeft: 0
    property real fadeRight: 0
    property real fadeTop: 0
    property real fadeBottom: 0
    property var _system: null
    property bool _hasParticles: false
    // Public: is anything actually alive? Hosts gate expensive downstream
    // passes (a bloom MultiEffect, say) on this, because those keep costing
    // GPU time every frame over a blank canvas otherwise.
    readonly property bool hasParticles: _hasParticles
    property real lastTime: Date.now()
    
    Component.onCompleted: {
        _system = Logic.createSystem(maxParticles);
    }
    
    function _edge(d, fade) {
        if (fade <= 0)
            return 1;
        const t = d / fade;
        return t <= 0 ? 0 : t >= 1 ? 1 : t * t * (3 - 2 * t);
    }
    // 1 in the middle of the canvas, 0 at an edge that fades, in between over the fade's length.
    function _edgeFade(x, y) {
        return Math.min(root._edge(x, root.fadeLeft), root._edge(root.width - x, root.fadeRight),
                        root._edge(y, root.fadeTop), root._edge(root.height - y, root.fadeBottom));
    }

    function emit(config, count) {
        if (_system) {
            if (!root._hasParticles) {
                root._hasParticles = true;
                root.lastTime = Date.now();
            }

            // Convert string colors to parsed array colors to save doing it per frame
            if (config.colorStart !== undefined) config.colorStart = Logic.parseColor(config.colorStart);
            if (config.colorEnd !== undefined) config.colorEnd = Logic.parseColor(config.colorEnd);
            
            _system.emit(config, count || 1);
        }
    }
    
    // Shift the whole live cloud, for a host whose emitter moved because the
    // layout moved. Cheap: one pass over the active particles only.
    function translateAll(dx, dy) {
        if (_system && root._hasParticles) _system.translate(dx, dy);
    }

    Timer {
        interval: 16 // ~60 FPS
        running: root.running && root._hasParticles
        repeat: true
        onTriggered: {
            if (root._system) {
                var now = Date.now();
                var dt = now - root.lastTime;
                root.lastTime = now;
                
                // Cap dt at 100ms so particles don't explode when the window goes to sleep
                if (dt > 100) dt = 16;
                
                root._system.update(dt);
                canvas.requestPaint();
            }
        }
    }
    
    ScaledCanvas {
        id: canvas
        anchors.fill: parent
        renderStrategy: Canvas.Cooperative

        onDraw: (ctx, cw, ch) => {
            // the canvas is a whole number of device px: clear a little past the item's edge
            ctx.clearRect(0, 0, cw + 2, ch + 2);
            
            if (!root._system) return;
            
            var particles = root._system.getActiveParticles();
            
            for (var i = 0; i < particles.length; i++) {
                var p = particles[i];
                var t = Math.min(1, p.age / p.lifetime);

                var currentSize = p.sizeStart + (p.sizeEnd - p.sizeStart) * t;
                var currentColor = Logic.lerpColor(p.colorStart, p.colorEnd, t);

                var alpha = currentColor[3];

                // Layer 1: distance-based fade. Position-driven — alpha drops from 1 at
                // fadeStartDistance to 0 at arrivalTarget.threshold. Robust across param
                // changes (watts, drag, lifetime) because it only reads the particle's
                // current distance to target, no time dependence.
                if (p.fadeStartDistance > 0 && p.arrivalTarget) {
                    var dxA = p.x - p.arrivalTarget.x;
                    var dyA = p.y - p.arrivalTarget.y;
                    var distA = Math.sqrt(dxA*dxA + dyA*dyA);
                    var fadeEnd = p.arrivalTarget.threshold || 10;
                    if (distA < p.fadeStartDistance) {
                        var range = p.fadeStartDistance - fadeEnd;
                        var fadeMul = range > 0 ? (distA - fadeEnd) / range : 0;
                        if (fadeMul < 0) fadeMul = 0;
                        if (fadeMul > 1) fadeMul = 1;
                        alpha = alpha * fadeMul;
                    }
                }

                if (p.deathFadeFraction > 0 && t > 1 - p.deathFadeFraction) {
                    var fadeT = (t - (1 - p.deathFadeFraction)) / p.deathFadeFraction;
                    alpha = alpha * (1 - fadeT);
                }

                // Layer 3: dying-fade (mandatory safety net on any death condition)
                if (p.dying) {
                    var dFade = Math.min(1, (p.age - p.dyingAge) / p.dyingFadeMs);
                    alpha = alpha * (1 - dFade);
                }
                // Speed glow. Applied AFTER every fade so a particle that is
                // accelerating — being pulled along by a moving attractor —
                // brightens against its own dying fade instead of disappearing
                // mid-chase. Alpha is allowed past 1 only in the sense that it
                // is clamped here, which keeps the additive look without
                // producing invalid colours.
                if (p.glowSpeedRef > 0) {
                    var sp = Math.sqrt(p.vx * p.vx + p.vy * p.vy);
                    var g = sp / p.glowSpeedRef;
                    if (g > 1) g = 1;
                    var boost = 1 + g * (p.glowMax - 1);
                    alpha = Math.min(1, alpha * boost);
                    if (p.glowSizeGain > 0) currentSize = currentSize * (1 + g * p.glowSizeGain);
                }
                if (root.fadeLeft > 0 || root.fadeRight > 0 || root.fadeTop > 0 || root.fadeBottom > 0)
                    alpha = alpha * root._edgeFade(p.x, p.y);
                currentColor = [currentColor[0], currentColor[1], currentColor[2], alpha];
                
                ctx.beginPath();
                
if (p.history.length > 1) {
                    // Draw trail line
                    ctx.moveTo(p.history[0].x, p.history[0].y);
                    for (var j = 1; j < p.history.length; j++) {
                        ctx.lineTo(p.history[j].x, p.history[j].y);
                    }
                    ctx.lineWidth = currentSize;
                    ctx.strokeStyle = Logic.formatColor(currentColor);
                    ctx.lineCap = "round";
                    ctx.lineJoin = "round";
                    ctx.stroke();
                } else {
                    // Draw point
                    ctx.arc(p.x, p.y, currentSize / 2, 0, Math.PI * 2);
                    ctx.fillStyle = Logic.formatColor(currentColor);
                    ctx.fill();
                }
            }
            
            if (particles.length === 0 && root._hasParticles) {
                root._hasParticles = false;
            }
        }
    }
}