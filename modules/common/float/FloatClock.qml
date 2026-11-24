pragma ComponentBehavior: Bound

import QtQuick

import "../theme"
import "FloatMotion.js" as Float

// =============================================================================
// FloatClock.qml -- the ONE clock of a popup's floating cards (FloatCard). Every card registers with it and is stepped by it; nothing else in a card
// runs a clock (CLAUDE.md: one clock per motion; a FrameAnimation per card would be N clocks and N wakes).
//
//   running          the host's word that the cards are on screen: the popup present, not parked, its window shown. False: no tick at all, every card
//                    holds where it is (a closed or parked popup costs nothing).
//   holdOnCrossfade  stand still while Theme.crossfading: the crossfade fades out a STILL picture of the frame before, so anything that keeps moving
//                    under it is a second copy of itself. A popup that is a theme island (the theme popup) keeps moving and says false.
//   restHz           0: a tick every frame for as long as it runs (the theme popup's strands flow at that rate). > 0: every frame only while
//                    something moves fast -- a deal, a spring the pointer pulled, the calm easing in or out -- and this many ticks a second while
//                    only the slow sway moves (2.7 px/s at most: 0.14 px a tick at 20). Every tick is a frame of the whole window, so the rate
//                    is the cost (the notes, offscreen: 5.5 % of a core at 30 Hz, 3 % at 20). A popup whose window already redraws on a beat
//                    of its own hands that beat in with beat() (the weather backdrop's 30 Hz), so the sway adds no frame of its own.
//   calm             the cards ease to rest (FloatStyle.calmMs) and stop: a drag, a reorder, a scroll. Let go, the sway comes back (resumeMs).
//   style            the calm's timing (any FloatStyle; the cards carry their own for the rest)
//   bareDeals        places the host deals with dealLeftAt() and no card (the weather popup's hero, strip and list: presence only), orders
//                    0 .. bareDeals - 1: the clock stays on every frame until they have landed
//
//   live             running, as the cards may rely on it (a sheet's HOLD pins it false)
//   layers           live, one turn later: what a card's held face follows (below). Never flipped inside an event's delivery (CLAUDE.md:
//                    a layer.enabled that flips there destroys items the delivery agent is walking).
//   dealAge          seconds since the deal began (restartDeal(): an open of a recycled popup; skipDeal(): a popup that opens on another page)
//   sway             1 - the calm, eased: what the cards multiply their sway by
//   wake()           a card's asks changed (the pointer came, went, moved): every frame again, at once
//   beat()           the host's beat, for the rest ticks (ignored while the clock runs every frame, or holds)
//   ticked(dt)       emitted at every tick before the cards are stepped (the theme popup's strands flow on it)
// =============================================================================
Item {
    id: clock

    property bool running: false
    property bool holdOnCrossfade: true
    property real restHz: 0
    property bool calm: false
    property FloatStyle style: FloatStyle {}
    property int bareDeals: 0

    property real dealAge: 0
    property real calmF: 0
    // Which tick this is (a card steps a shared sway once a tick)
    property int tickNo: 0
    readonly property real sway: 1 - clock.calmF * clock.calmF * (3 - 2 * clock.calmF)

    signal ticked(real dt)

    // For a probe: whether it ticks at all, and whether every frame.
    readonly property bool ticking: fastClock.running || restClock.running
    readonly property bool everyFrame: fastClock.running
    readonly property int cardCount: clock._count
    // Where the ticks came from, counted in place (an instrument, not a property anything binds to): every frame, the clock's own rest
    // timer, the host's beat.
    readonly property var stats: clock._stats
    property var _stats: ({
            frames: 0,
            own: 0,
            beats: 0
        })

    // The gate. sheet_render's HOLDS pins the first line false in its copy: the sheet's pictures are the cards at rest, unlayered.
    readonly property bool live: clock.running
    readonly property bool _on: clock.live && !(clock.holdOnCrossfade && Theme.crossfading)
    // A FLOATING CARD'S FACE IS ONE HELD TEXTURE while the clock runs (the theme card's rule, measured again for the notes: a tick that moves
    // ten tiles' text and boxes cost 9 % of a core at a 30 Hz rest beat, 1 % with the poses frozen, 5.5 % with each face a layer, offscreen).
    // A card's face is drawn into its layer when its content changes, and the float moves a quad. At rest (not live) the plain scene graph.
    property bool layers: false
    onLiveChanged: Qt.callLater(() => clock.layers = clock.live)
    Component.onCompleted: clock.layers = clock.live
    // Every frame (a deal starts the clock), and how many quiet ticks it has had since something last moved fast: it slows after a few, so a
    // spring hovering about its threshold does not flap between the two timers.
    property bool _fast: true
    property int _quiet: 0
    // Calm and still: nothing to step until the calm is let go or something wakes it.
    property bool _idle: false
    property real _last: 0
    // The clock has stepped since the deal began: until then a place dealt without a card stands at rest, as a card does until its first step
    // (a clock that never runs -- held, or a sheet's picture -- draws the page as it is, not frozen at the deal's start).
    property bool _dealSeen: false
    // The cards, mutated in place: a list nothing binds to (a count read by a binding would be a dependency of every tick).
    property var _cards: []
    property int _count: 0
    // The sways kept by key (FloatCard.stateKey), mutated in place
    property var _states: ({})

    function register(card: Item): void {
        if (clock._cards.indexOf(card) < 0) {
            clock._cards.push(card);
            clock._count = clock._cards.length;
        }
    }
    function unregister(card: Item): void {
        const i = clock._cards.indexOf(card);
        if (i >= 0) {
            clock._cards.splice(i, 1);
            clock._count = clock._cards.length;
        }
    }

    function stateKept(key: string): var {
        return clock._states[key] || null;
    }
    function stateFor(key: string, seed: int, s: FloatStyle): var {
        let st = clock._states[key];
        if (!st) {
            st = Float.make(seed, s);
            clock._states[key] = st;
        }
        return st;
    }

    function wake(): void {
        clock._quiet = 0;
        clock._fast = true;
        clock._idle = false;
    }
    function restartDeal(): void {
        clock.dealAge = 0;
        clock._dealSeen = false;
        clock.wake();
    }
    function skipDeal(): void {
        clock.dealAge = 1e6;
    }
    // How far the deal still has to bring place `order` (1 -> 0, overshooting once), on this clock. A function a binding may call: it reads
    // `dealAge` and the style's numbers, which are its dependencies.
    function dealLeftAt(order: int, s: FloatStyle): real {
        return clock._dealSeen ? Float.dealLeft(clock.dealAge, order * s.dealStaggerMs / 1000, s.dealMs / 1000) : 0;
    }

    function beat(): void {
        if (!restClock.running)
            return;
        clock._stats.beats++;
        clock._tick(clock._wallDt());
        // Held off for a period and a half: while the host's beats come, the clock's own never fires.
        restClock.beaten = true;
        restClock.restart();
    }

    onCalmChanged: clock.wake()
    on_OnChanged: {
        clock._last = Date.now();
        if (clock._on)
            clock.wake();
    }

    function _wallDt(): real {
        const now = Date.now();
        const dt = clock._last > 0 ? Math.min(0.1, Math.max(0, (now - clock._last) / 1000)) : 1 / Math.max(1, clock.restHz);
        return dt;
    }

    function _tick(dt: real): void {
        clock._last = Date.now();
        const target = clock.calm ? 1 : 0;
        if (clock.calmF !== target) {
            const ms = clock.calm ? clock.style.calmMs : clock.style.resumeMs;
            const step = ms > 0 ? dt * 1000 / ms : 1;
            clock.calmF = target > clock.calmF ? Math.min(target, clock.calmF + step) : Math.max(target, clock.calmF - step);
        }
        clock.dealAge += dt;
        clock._dealSeen = true;
        clock.tickNo++;
        clock.ticked(dt);
        let lively = clock.calmF !== target || (clock.bareDeals > 0 && clock.dealAge < ((clock.bareDeals - 1) * clock.style.dealStaggerMs + clock.style.dealMs) / 1000);
        const cards = clock._cards;
        for (let i = 0; i < cards.length; i++) {
            const c = cards[i];
            if (c.visible && c.advance(dt))
                lively = true;
        }
        if (lively) {
            clock._quiet = 0;
            clock._fast = true;
        } else if (clock._fast && ++clock._quiet >= 6) {
            clock._fast = false;
        }
        clock._idle = clock.calm && clock.calmF >= 1 && !lively;
    }

    FrameAnimation {
        id: fastClock
        running: clock._on && !clock._idle && (clock.restHz <= 0 || clock._fast)
        onTriggered: {
            clock._stats.frames++;
            clock._tick(Math.min(fastClock.frameTime, 0.05));
        }
    }
    Timer {
        id: restClock
        property bool beaten: false
        readonly property int period: Math.max(8, Math.round(1000 / Math.max(1, clock.restHz)))
        interval: restClock.beaten ? Math.round(restClock.period * 1.5) : restClock.period
        repeat: true
        running: clock._on && !clock._idle && clock.restHz > 0 && !clock._fast
        onTriggered: {
            restClock.beaten = false;
            clock._stats.own++;
            clock._tick(clock._wallDt());
        }
    }
}
