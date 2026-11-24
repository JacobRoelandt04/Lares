.pragma library

class Particle {
    constructor() {
        this.active = false;
        this.x = 0;
        this.y = 0;
        this.vx = 0;
        this.vy = 0;
        this.history = [];
        this.maxHistory = 5;
        this.age = 0;
        this.lifetime = 1000;

        this.sizeStart = 2;
        this.sizeEnd = 2;

        // Colors stored as [R, G, B, A] for easy interpolation
        this.colorStart = [255, 255, 255, 1];
        this.colorEnd = [255, 255, 255, 0];

        this.drag = 0;
        this.forceField = null;
        // Fraction of lifetime at the end during which alpha linearly fades to 0. 0 disables.
        this.deathFadeFraction = 0;

        // Optional "reach a point" mechanic. When arrivalTarget = {x,y,threshold} is set,
        // the particle lives past its nominal lifetime (up to maxLifetime) until it enters
        // the threshold sphere around the target. maxLifetime is a hard cap for particles
        // that get stuck in a swirl and never reach target.
        this.arrivalTarget = null;
        this.maxLifetime = 0;

        // First layer of defense against visible despawn: distance-based fade. When
        // set (> 0) and arrivalTarget present, alpha fades linearly from 1 at
        // `distance = fadeStartDistance` to 0 at `distance = arrivalTarget.threshold`.
        // Position-driven, not time-driven — so fade behavior is robust across watts,
        // drag, lifetime changes. 0 disables: particle stays fully opaque until the
        // second/third layers (mask + dying-fade-on-arrival) take over.
        this.fadeStartDistance = 0;

        // Graceful-death tail fade (mandatory, not param-dependent). When any death
        // condition fires — arrival, lifetime, maxLifetime — the particle enters a
        // "dying" state instead of instantly deactivating: physics + history keep
        // running so old trail entries scroll out of range, and render alpha fades to
        // 0 over dyingFadeMs. Only after the fade completes does the particle go
        // inactive. This is what guarantees no visible pop at deactivation regardless
        // of param tuning — either the mask hides the tail by then (history rolled
        // over to interior-only positions) or the fade does (alpha reaches 0).
        this.dying = false;
        this.dyingAge = 0;
        this.dyingFadeMs = 250;

        // Speed-reactive glow. When glowSpeedRef > 0 the renderer brightens and
        // fattens a particle in proportion to how fast it is actually moving,
        // so a particle being dragged along by something reads as energetic
        // rather than as a dot that happens to be elsewhere next frame. This is
        // what lets a particle fight its own death fade: accelerating hard near
        // the end of its life makes it flare instead of quietly vanishing.
        this.glowSpeedRef = 0;
        this.glowMax = 1.0;
        this.glowSizeGain = 0.0;
    }

    spawn(config) {
        this.active = true;
        this.x = config.x || 0;
        this.y = config.y || 0;
        this.vx = config.vx || 0;
        this.vy = config.vy || 0;
        this.age = 0;
        this.lifetime = config.lifetime || 1000;
        this.history = [{x: this.x, y: this.y}];
        this.maxHistory = config.maxHistory || 5;

        this.sizeStart = config.sizeStart !== undefined ? config.sizeStart : 2;
        this.sizeEnd = config.sizeEnd !== undefined ? config.sizeEnd : 2;

        this.colorStart = config.colorStart || [255, 255, 255, 1];
        this.colorEnd = config.colorEnd || [255, 255, 255, 0];

        this.drag = config.drag || 0;
        this.forceField = config.forceField || null;
        this.deathFadeFraction = config.deathFadeFraction || 0;

        this.arrivalTarget = config.arrivalTarget || null;
        this.maxLifetime = config.maxLifetime || this.lifetime * 3;
        this.fadeStartDistance = config.fadeStartDistance || 0;

        this.dying = false;
        this.dyingAge = 0;
        this.dyingFadeMs = config.dyingFadeMs !== undefined ? config.dyingFadeMs : 250;

        this.glowSpeedRef = config.glowSpeedRef || 0;
        this.glowMax = config.glowMax !== undefined ? config.glowMax : 1.0;
        this.glowSizeGain = config.glowSizeGain || 0;
    }

    // Current speed in px/s, for the renderer's glow term.

    update(dt) {
        if (!this.active) return;

        this.age += dt;

        // Death conditions trigger dying state (not instant deactivation). Physics
        // and history keep running during dying so the trail scrolls over naturally;
        // alpha fade in render handles the final invisibility.
        if (!this.dying) {
            if (this.arrivalTarget) {
                const dx = this.x - this.arrivalTarget.x;
                const dy = this.y - this.arrivalTarget.y;
                const th = this.arrivalTarget.threshold || 10;
                if (dx*dx + dy*dy <= th*th || this.age >= this.maxLifetime) {
                    this.dying = true;
                    this.dyingAge = this.age;
                }
            } else if (this.age >= this.lifetime) {
                this.dying = true;
                this.dyingAge = this.age;
            }
        }

        if (this.dying && (this.age - this.dyingAge) >= this.dyingFadeMs) {
            this.active = false;
            return;
        }

        // Clamp t at 1 so forceField behaviour and lerps stabilise past nominal lifetime
        // (only meaningful when arrivalTarget extends life past `lifetime`).
        let t = Math.min(1, this.age / this.lifetime);

        let ax = 0;
        let ay = 0;
        if (this.forceField) {
            let f = this.forceField(this.x, this.y, t);
            ax = f.x || 0;
            ay = f.y || 0;
        }

        // dt is in ms, convert to seconds for physics math
        let dtSec = dt / 1000;

        this.vx += ax * dtSec;
        this.vy += ay * dtSec;

        if (this.drag > 0) {
            // Decelerate based on drag coefficient
            this.vx -= this.vx * this.drag * dtSec;
            this.vy -= this.vy * this.drag * dtSec;
        }

        this.x += this.vx * dtSec;
        this.y += this.vy * dtSec;

        this.history.push({x: this.x, y: this.y});
        if (this.history.length > this.maxHistory) {
            this.history.shift();
        }
    }
}

class ParticleSystem {
    constructor(maxParticles) {
        this.particles = Array.from({length: maxParticles}, () => new Particle());
    }
    
    emit(config, count = 1) {
        let emitted = 0;
        for (let i = 0; i < this.particles.length; i++) {
            if (!this.particles[i].active) {
                this.particles[i].spawn(config);
                emitted++;
                if (emitted >= count) break;
            }
        }
    }
    
    update(dt) {
        for (let i = 0; i < this.particles.length; i++) {
            this.particles[i].update(dt);
        }
    }
    
    getActiveParticles() {
        return this.particles.filter(p => p.active);
    }

    // Shift every live particle, trail included, by a fixed offset.
    //
    // For hosts whose emitter moves because the LAYOUT moved rather than
    // because anything travelled: applying the same delta to the particles
    // keeps the whole cloud rigid relative to the emitter, so it arrives in
    // its new place having visibly done nothing. Without it the cloud is left
    // behind and then chases, which reads as an event that did not happen.
    //
    // History is offset too — skipping it would leave every trail anchored to
    // where the particle used to be and drawn as a long streak to the new
    // position.
    translate(dx, dy) {
        if (dx === 0 && dy === 0) return;
        for (let i = 0; i < this.particles.length; i++) {
            const p = this.particles[i];
            if (!p.active) continue;
            p.x += dx;
            p.y += dy;
            const h = p.history;
            for (let j = 0; j < h.length; j++) {
                h[j].x += dx;
                h[j].y += dy;
            }
        }
    }
}

function createSystem(maxParticles) {
    return new ParticleSystem(maxParticles);
}

// Convert a QML color hex string into [r, g, b, a]
function parseColor(c) {
    c = String(c);
    if (c.startsWith('#')) {
        if (c.length === 9) { // #AARRGGBB format typical in Qt
            let a = parseInt(c.slice(1, 3), 16) / 255;
            let r = parseInt(c.slice(3, 5), 16);
            let g = parseInt(c.slice(5, 7), 16);
            let b = parseInt(c.slice(7, 9), 16);
            return [r, g, b, a];
        } else if (c.length === 7) { // #RRGGBB format
            let r = parseInt(c.slice(1, 3), 16);
            let g = parseInt(c.slice(3, 5), 16);
            let b = parseInt(c.slice(5, 7), 16);
            return [r, g, b, 1];
        }
    }
    return [255, 255, 255, 1]; // fallback
}

function lerpColor(c1, c2, t) {
    return [
        c1[0] + (c2[0] - c1[0]) * t,
        c1[1] + (c2[1] - c1[1]) * t,
        c1[2] + (c2[2] - c1[2]) * t,
        c1[3] + (c2[3] - c1[3]) * t
    ];
}

function formatColor(rgba) {
    return `rgba(${Math.floor(rgba[0])}, ${Math.floor(rgba[1])}, ${Math.floor(rgba[2])}, ${rgba[3]})`;
}