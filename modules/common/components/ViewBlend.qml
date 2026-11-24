pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// ViewBlend.qml -- ONE clock for a card that morphs between views.
//
// A card with several views of the same data (the hourly strip, the daily
// list) draws a WEIGHT per view and makes every drawn quantity the weighted
// sum of that quantity in each view: a position, a width, a bar's length, a
// presence, a colour. This is the clock behind those weights, written once:
//
//     ViewBlend {
//         id: blend
//         count: card.views.length
//         target: card.viewIndex          // the cycler's index
//         durationMs: card.transitionMs
//     }
//     x: blend.mix(v => slotOf(v).x)            // a number
//     color: blend.mixColor(v => colourIn(v))   // a colour (null: none there)
//     text: blend.textOf(texts, v => shows(v))  // a text: never blended
//
// THE RULE. `weights[v] = from[v] * (1 - e) + (v === toView) * e`, where
// `from` is the weights the transition started from and e is the clock's
// OutCubic over `durationMs` (the eased value is `progress`). A change of
// `target` SNAPSHOTS THE DRAWN WEIGHTS as `from` and restarts the clock, so a
// second switch while the first is still moving continues from what is on
// screen: nothing jumps.
//
// ONE PUBLISH PER TICK. `weights` is a fresh array each tick (bindings that
// read it re-evaluate once), and `ticked()` fires after `weights`, `progress`
// and `toView` all hold the tick's values -- the hook for a card
// that batches its own per-tick frame (the strip's `_frame`). At rest the
// clock is stopped: nothing ticks and nothing is published.
//
// TEXT is not blended: a text swaps instantly to the target's, and an element
// the target does not show keeps the text of the view that weighed most when
// the transition BEGAN (the order of the others cannot change during it: they
// all decay by the same factor). Those read only `toView` and the starting
// weights,
// so a text binding runs once per switch, not once per tick.
//
// CREATES NOTHING. A switch moves numbers; nothing here is created, destroyed
// or layered, so a wheel event that switches the view is safe (the wheel
// trap). A target that changes before the component is complete is taken at
// rest, without a transition.
//
// HARNESS STILLS. `pin(t)` stops the clock at LINEAR time t (0..1) of the
// current transition; a still of the switch a -> b at t is
// `select(a); pin(1); select(b); pin(t)`.
// =============================================================================
QtObject {
    id: blend

    property int count: 1
    property int target: 0
    property int durationMs: 260

    readonly property alias weights: blend._w
    readonly property alias toView: blend._to
    readonly property alias progress: blend._e

    signal ticked()

    function pin(t) {
        blend._clock.stop();
        const c = Math.max(0, Math.min(1, t));
        if (blend._t === c)
            blend._publish();
        else
            blend._t = c;
    }

    // The weighted sum of a number over the views that weigh anything.
    function mix(fn) {
        const w = blend._w;
        let s = 0;
        for (let v = 0; v < w.length; v++) {
            if (w[v] > 0)
                s += w[v] * fn(v);
        }
        return s;
    }
    // The weighted colour over the views that have one (fn returns null where
    // a view has none), normalised over those.
    function mixColor(fn) {
        const w = blend._w;
        let r = 0, g = 0, b = 0, a = 0, s = 0;
        for (let v = 0; v < w.length; v++) {
            if (!(w[v] > 0))
                continue;
            const c = fn(v);
            if (c === null)
                continue;
            r += w[v] * c.r; g += w[v] * c.g; b += w[v] * c.b; a += w[v] * c.a;
            s += w[v];
        }
        return s > 0 ? Qt.rgba(r / s, g / s, b / s, a / s) : Qt.rgba(0, 0, 0, 0);
    }
    // The view whose text an element shows: the target when `has(target)`,
    // else the view that weighed most, among those that have it, when the
    // transition began; -1 when none did (then the element is absent all the
    // way through). With `list`, a view whose entry is "" does not have it.
    function textView(has, list) {
        const to = blend._to, from = blend._fromW;
        if (has(to) && (!list || list[to] !== ""))
            return to;
        let best = -1, bw = 0;
        for (let v = 0; v < from.length; v++) {
            if (from[v] > bw && has(v) && (!list || list[v] !== "")) {
                bw = from[v];
                best = v;
            }
        }
        return best;
    }
    function textOf(list, has) {
        const v = blend.textView(has, list);
        return v >= 0 ? list[v] : "";
    }

    // ---- The clock ----------------------------------------------------------------
    property var _w: []
    property var _fromW: []
    property int _to: 0
    property real _t: 1
    property real _e: 1
    property bool _ready: false
    property NumberAnimation _clock: NumberAnimation {
        target: blend
        property: "_t"
        from: 0
        to: 1
        duration: blend.durationMs
        easing.type: Easing.Linear
    }
    on_TChanged: blend._publish()
    onTargetChanged: blend._retarget()
    onCountChanged: blend._rest()
    Component.onCompleted: {
        blend._ready = true;
        blend._rest();
    }

    function _onehot(v) {
        const out = new Array(Math.max(0, blend.count)).fill(0);
        if (v >= 0 && v < out.length)
            out[v] = 1;
        return out;
    }
    // At rest on the target: no transition.
    function _rest() {
        blend._clock.stop();
        blend._fromW = blend._onehot(blend.target);
        blend._to = blend.target;
        if (blend._t === 1)
            blend._publish();
        else
            blend._t = 1;
    }
    // From what is drawn to the new target.
    function _retarget() {
        if (!blend._ready) {
            blend._rest();
            return;
        }
        const drawn = blend._w.slice();
        blend._clock.stop();
        blend._fromW = drawn;
        blend._to = blend.target;
        if (blend._t === 0)
            blend._publish();
        else
            blend._t = 0;
        blend._clock.start();
    }
    function _publish() {
        const from = blend._fromW, to = blend._to;
        const u = 1 - Math.max(0, Math.min(1, blend._t));
        const e = 1 - u * u * u;
        const w = new Array(from.length);
        for (let v = 0; v < from.length; v++)
            w[v] = from[v] * (1 - e) + (v === to ? e : 0);
        blend._e = e;
        blend._w = w;
        if (blend._ready)
            blend.ticked();
    }
}
