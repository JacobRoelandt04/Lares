pragma ComponentBehavior: Bound

import QtQuick

import "../../common/glyphs"
import "../../common/components"

// =============================================================================
// IconReel.qml -- the ring itself. State and rules; no pixels.
//
// A ring of icons that turns through the bar. One icon at a time sits in the
// bar's own cell -- that one is SELECTED -- and the rest of the ring hangs out
// of the bar in thePopup. Turning brings another icon into the bar cell; icons
// that pass over it come back at the far end, so the ring never runs out.
//
// WHY THIS IS NOT AN ITEM. The ring is drawn in TWO places at once -- the bar
// cell and the popup are different items, in different windows' worth of
// geometry -- and both must show the same ring, continuous across the join,
// or an icon sliding into the bar would vanish at one edge and appear at the
// other. So the ring is state, `IconReelView` is a clipped window onto it, and
// a module hangs two windows off one ring (see modules/bar/reel/).
//
// GEOMETRY IS ONE AXIS. Everything is placed by `a`, the distance from the
// bar's OUTER edge (the screen edge) inward: the bar cell is a in [0, barCell]
// and the popup carries on from there. A view knows which slice of `a` it
// shows and which way `a` runs on screen; the ring does not care.
//
// ONE CLOCK PER MOTION:
//   reelPos   cells, unwrapped, eased. `selectedIndex` is read off the
//             COMMITTED target, never off this, so nothing flickers mid-turn.
//   motion    |reelPos - reelTarget|, which is what fades the fog at the
//             bar's edge in while the reel turns and out when it lands.
//   The opening and closing of the strip is NOT a clock here: that is
//   thePopup's own growth, owned by the bar engine.
//
// THE DETENT. A wheel notch is one step. A two-finger swipe -- which arrives
// as a WHEEL on the axis it was made on, never as a drag -- accumulates
// against a threshold of its own: the ring gives up to `swipeMaxPull` of a
// cell and snaps when the threshold is crossed, and the gesture ends on the
// touchpad's zero-delta scroll-end event rather than on a timer.
// docs/contracts/gestures.md is that rule.
//
// It knows nothing about what an item DOES: it emits `activated` and the host
// decides. That is what lets a mockup of a power menu be safe.
// =============================================================================
Item {
    id: root

    // =====================================================================
    //  DATA
    // =====================================================================
    // [{ id, glyph, label, tint }] -- `tint` names a role of the bar's hue
    // table (see tintOf), never a colour, so a theme switch does not rebuild the model
    // and destroy every delegate once a frame for the whole crossfade.
    property var items: []
    readonly property int count: root.items ? root.items.length : 0

    // Power: a right click on the selected icon is the only way to fire, and
    // that is the safety. The idle inhibitor has nothing to lose by being
    // switched by accident, so it takes a left click on the selected icon too.
    property bool leftClickActivates: false

    // Does firing the selected item throw the radial burst of sparks (the power reel's: a right click that fired something)? The idle
    // reel's selected icon IS the mode in force, so a click on it fires nothing new to celebrate: its reel says false, and keeps the
    // sparks a turn throws.
    property bool burstOnActivate: true

    // Is the reel OPEN (its strip is out of the bar)? The selected icon shows its own colour while it is, not only under the pointer.
    // The host sets it from the engine's popup, so the icon keeps its colour while the pointer is down in the
    // strip, and goes back to rest when the strip goes.
    property bool open: false

    // Is the pointer on the BAR's cell? Only the icon in the bar can be fired,
    // so that is the only icon that lights up -- and the highlight has to be a
    // fact about the RING, not about one view's delegate, or the two views
    // disagree and an icon crossing the seam is cut in half by its own colour.
    // The host sets this from the bar cell's hover.
    property bool pointerOnBarCell: false

    // Which item is being pressed, or -1. On the ring for the same reason the
    // highlight is: the same icon has a delegate in each view and they must
    // agree, or a press shows on one half of an icon that straddles the seam.
    property int pressedIndex: -1

    // THE ITEM IN THE CELL WAS PUT THERE BY SOMETHING ELSE (the idle reel while the auto layer holds the mode): the selected icon
    // keeps its own colour with the strip closed -- the mark that it was automatic -- and the ring takes no click and no scroll
    // unless Ctrl is held (`lastInputOverride` tells the host so). Hover still opens the strip.
    property bool autoHeld: false
    // The ring is deaf to its own input while it travels by itself (`travel`). A held ring (autoHeld) is NOT deaf: it takes plain
    // input at or above its floor (below) and refuses what is under it.
    readonly property bool inputLocked: root.traveling
    // THE FLOOR (the idle reel while an auto cause holds a mode: IdleService.floorMode): the id of the lowest item plain input may go to
    // ("" = none). Items carry a `rank`; one under the floor's is REFUSED -- the ring does not turn and `refuse()` plays the shake
    // -- unless Ctrl is held (the user's way past an automatic mode).
    property string floorId: ""
    readonly property int floorRank: {
        const it = root.items;
        if (!it || root.floorId === "")
            return -1;
        for (let i = 0; i < it.length; i++)
            if (it[i].id === root.floorId && it[i].rank !== undefined)
                return it[i].rank;
        return -1;
    }
    readonly property bool floorActive: root.floorRank >= 0
    // The click or scroll the view is passing on was made with Ctrl (set by the view right before it steps, swipes or activates).
    property bool inputCtrl: false
    // ... and it was made with Ctrl over a reel with a floor: the host sets the holders aside (IdleService.setMode(m, true)).
    property bool lastInputOverride: false
    // The refusal's shake: the selected icon's offset across the strip, in px, ONE animated property (see refuse()).
    property real shakeX: 0
    property real refuseShakePx: 3
    signal refusedStep(int index, var item)

    // Every number the ring and its views are drawn by. Shared between the
    // reels of one bar; a lone reel makes its own.
    property IconReelStyle style: IconReelStyle {}

    // The items' flourishes (a flourish set: ReelFlourishes the power reel's, IdleFlourishes the idle reel's), or null for a reel whose glyphs only sit there. On the RING, like
    // the highlight: the same icon has a delegate in each view, and both read one clock.
    property var flourishes: null

    signal activated(int index, var item)
    signal selectionChanged(int index, var item)
    // A turn, for whichever view is drawing sparks. `dir` is +1 toward the
    // next item.
    signal sparked(int dir)

    // The ring is state, not a picture.
    visible: false
    width: 0
    height: 0

    // =====================================================================
    //  THE RING
    // =====================================================================
    property int reelTarget: 0
    property bool _snap: false
    property real reelPos: root.reelTarget
    // A TRAVEL (`travel`) is the same clock, slower and eased in and out: the ring turning by itself, the long way, for the eye.
    property int _travelMs: 0
    readonly property bool traveling: root._travelMs > 0
    Behavior on reelPos {
        enabled: !root._snap
        NumberAnimation {
            duration: root._travelMs > 0 ? root._travelMs : root.style.stepMs
            easing.type: root._travelMs > 0 ? Easing.InOutCubic : root.style.stepOvershoot > 0 ? Easing.OutBack : Easing.OutCubic
            easing.overshoot: Math.max(0.0001, root.style.stepOvershoot)
        }
    }
    Timer {
        id: travelEnd
        onTriggered: root._travelMs = 0
    }

    readonly property int selectedIndex: root.count > 0
        ? ((root.reelTarget % root.count) + root.count) % root.count : 0
    readonly property var selectedItem: root.count > 0 ? root.items[root.selectedIndex] : null

    // Where the last icon sits, and where the strip therefore ends: at that
    // icon, not past it.
    readonly property real lastA: root.style.barCell / 2 + Math.max(0, root.count - 1) * root.style.cellPitch
    readonly property real endA: root.lastA + root.style.tailFraction * root.style.cellPitch
    // What the popup is asked for: how far the ring reaches out of the bar.
    readonly property real popupLength: Math.max(1, root.endA - root.style.barCell)

    // =====================================================================
    //  THE SWIPE
    //
    // A TWO-FINGER SWIPE ARRIVES AS A WHEEL on the axis it was made on. The
    // view turns the event into one number and hands it here; this is the
    // same machinery TabSelector uses, in cells instead of pixels, so the
    // ring resists like the rest of the shell. docs/contracts/gestures.md is
    // the rule.
    // =====================================================================
    property real _swipeAccum: 0        // wheel units
    property real _swipeVelocity: 0     // units per second, smoothed
    property real _swipeLastMs: 0
    property bool _swipeCooling: false
    property bool gestureLive: false

    // Cells the ring is pulled out of its slot by while the gesture is under
    // way. Fast at the start and tapering toward the threshold, so what is
    // left of the gesture reads as effort rather than as a slide -- and it
    // saturates below half a cell, so the pull can never complete a step by
    // itself and there is always something for the detent to snap.
    property real swipePull: 0

    readonly property real reelAt: root.reelPos + root.swipePull
    readonly property real motion: Math.min(1, Math.abs(root.reelAt - root.reelTarget) * root.style.motionGain)

    NumberAnimation {
        id: pullReturn
        target: root
        property: "swipePull"
        to: 0
        duration: root.style.swipeReturnMs
        // Slight overshoot on the way home reads as the spring releasing.
        easing.type: Easing.OutBack
        easing.overshoot: 0.9
    }
    Timer {
        id: swipeIdle
        interval: root.style.swipeIdleResetMs
        onTriggered: root._releaseSwipe()
    }
    Timer {
        id: swipeCooldown
        interval: root.style.swipeCooldownMs
        onTriggered: root._swipeCooling = false
    }

    function _pullFor(accum) {
        const st = root.style;
        if (st.swipeThreshold <= 0 || root.count === 0)
            return 0;
        const dir = accum > 0 ? 1 : -1;
        const t = Math.min(1, Math.abs(accum) / st.swipeThreshold);
        const eased = 1 - Math.pow(1 - t, st.swipePullTaper);
        return dir * eased * st.swipeMaxPull;
    }

    // =====================================================================
    //  THE FLASH
    // =====================================================================
    // What says the thing fired: the icon goes to its own colour and comes
    // back. One property, eased once.
    property real flash: 0
    NumberAnimation {
        id: flashAnim
        target: root
        property: "flash"
        from: 1
        to: 0
        duration: root.style.flashMs
        easing.type: Easing.OutCubic
    }

    // =====================================================================
    //  API
    // =====================================================================
    // Turn the ring by k cells. Positive brings the NEXT item into the bar.
    // Is the item `k` cells on under the floor, for plain input?
    function _underFloor(k) {
        if (!root.floorActive || root.inputCtrl || root.count <= 0)
            return false;
        const n = root.count;
        const it = root.items[(((root.selectedIndex + k) % n) + n) % n];
        return !!it && it.rank !== undefined && it.rank < root.floorRank;
    }

    // The ring will not go there: it stays, and the selected icon shakes across the strip (one property, OutCubic out and back with
    // a small OutBack settle). Says `refusedStep` for the host's reason.
    function refuse() {
        root._releaseSwipe();
        shakeAnim.restart();
        root.refusedStep(root.selectedIndex, root.selectedItem);
    }
    SequentialAnimation {
        id: shakeAnim
        NumberAnimation { target: root; property: "shakeX"; to: root.refuseShakePx; duration: 55; easing.type: Easing.OutCubic }
        NumberAnimation { target: root; property: "shakeX"; to: -root.refuseShakePx; duration: 90; easing.type: Easing.OutCubic }
        NumberAnimation { target: root; property: "shakeX"; to: root.refuseShakePx * 0.5; duration: 80; easing.type: Easing.OutCubic }
        NumberAnimation { target: root; property: "shakeX"; to: 0; duration: 140; easing.type: Easing.OutBack; easing.overshoot: 1.6 }
    }

    function step(k) {
        if (root.count <= 0 || k === 0)
            return;
        if (root._underFloor(k)) {
            root.refuse();
            return;
        }
        root.reelTarget += k;
        root._releaseSwipe();
        root.sparked(k > 0 ? 1 : -1);
        root.selectionChanged(root.selectedIndex, root.selectedItem);
    }

    // A mouse's whole notches (> 0 toward the next item): one icon each, at once -- no detent, no cooldown.
    function notch(n) {
        if (n === 0 || root.count <= 0)
            return;
        if (root._swipeAccum !== 0 || root.swipePull !== 0)
            root._releaseSwipe();
        for (let i = 0; i < Math.abs(n); i++)
            root._commit(n > 0 ? 1 : -1);
    }

    // Feed one wheel delta into the gesture. Positive is toward the next
    // item; the view has already folded in which axis and which direction
    // that is. ZERO IS THE GESTURE ENDING -- a touchpad sends a zero-delta
    // wheel event when the fingers lift, and that, not a timer, is what lets
    // the ring spring home.
    function applySwipe(dv) {
        if (dv === 0) {
            root._endSwipeGesture();
            return;
        }
        if (root.count <= 0 || root._swipeCooling)
            return;

        const st = root.style;
        const now = Date.now();
        const dt = Math.max(1, now - root._swipeLastMs);
        root._swipeLastMs = now;
        root._swipeVelocity = root._swipeVelocity * 0.6 + (Math.abs(dv) / (dt / 1000)) * 0.4;

        root.gestureLive = true;
        pullReturn.stop();
        root._swipeAccum += dv;
        swipeIdle.restart();

        // Commit as many steps as the accumulation covers. Normally one, and
        // the remainder is dropped. A fast swipe keeps its remainder and skips
        // the cooldown, so a flick carries through the middle of the ring
        // instead of stalling on it.
        let stepped = 0;
        while (Math.abs(root._swipeAccum) >= st.swipeThreshold) {
            const dir = root._swipeAccum > 0 ? 1 : -1;
            root._commit(dir);
            stepped += 1;
            if (root._swipeVelocity >= st.swipeMomentumRate) {
                root._swipeAccum -= dir * st.swipeThreshold;
            } else {
                root._swipeAccum = 0;
                break;
            }
        }

        if (stepped > 0 && root._swipeVelocity < st.swipeMomentumRate) {
            root._releaseSwipe();
            root._swipeCooling = true;
            swipeCooldown.restart();
            return;
        }

        root.swipePull = root._pullFor(root._swipeAccum);
    }

    function _endSwipeGesture() {
        if (root._swipeAccum !== 0 || root.swipePull !== 0)
            root._releaseSwipe();
    }

    function _releaseSwipe() {
        root._swipeAccum = 0;
        root._swipeVelocity = 0;
        root.gestureLive = false;
        swipeIdle.stop();
        pullReturn.stop();
        pullReturn.from = root.swipePull;
        pullReturn.start();
    }

    function _commit(dir) {
        if (root._underFloor(dir)) {
            root.refuse();
            return;
        }
        root.reelTarget += dir;
        root.sparked(dir);
        root.selectionChanged(root.selectedIndex, root.selectedItem);
    }

    // Turn to item i BY ITSELF (a host following what is in force): no `selectionChanged`, which is the user's word. The short
    // way at the step's pace; `longWay` the other way round, as one eased motion of `ms` (the cinematic travel: past every item
    // between, so the eye sees where it went). The ring takes no input until it lands.
    function turnTo(i, longWay, ms) {
        const n = root.count;
        if (n <= 0 || i < 0 || i >= n)
            return 0;
        let k = ((i - root.selectedIndex) % n + n) % n;
        if (k === 0)
            return 0;
        const shortK = k <= n / 2 ? k : k - n;
        const longK = shortK > 0 ? shortK - n : shortK + n;
        const steps = longWay === true ? longK : shortK;
        root._releaseSwipe();
        if (longWay === true && ms > 0) {
            root._travelMs = ms;
            travelEnd.interval = ms;
            travelEnd.restart();
        }
        root.reelTarget += steps;
        return steps;
    }

    // Put index i in the bar cell without turning: for a host restoring what
    // was selected last time.
    // (reelPos follows reelTarget by its own binding, with its Behavior off for the moment: ASSIGNING reelPos here would break that binding for
    // good, and the bar's cell would stay where it was put while the selection went on turning -- the power reel, which snaps to Lock at
    // start, would show Lock for ever.)
    function snapTo(i) {
        root._snap = true;
        root.reelTarget = i;
        root._snap = false;
    }

    // Fire the selected item. The host decides what that means.
    function activate() {
        if (root.count <= 0)
            return;
        flashAnim.restart();
        if (root.burstOnActivate)
            root.sparked(0);
        root.activated(root.selectedIndex, root.selectedItem);
    }

    // Where item i sits, in cells from the bar cell. Fractional while
    // turning. The lead is what keeps the wrap out of sight: an item leaves
    // the top, and only once it is past the bar's outer edge does it become
    // the one at the far end.
    function slotOf(i) {
        const n = root.count;
        if (n <= 0)
            return 0;
        const lead = root.style.wrapLead;
        let s = (i - root.reelAt + lead) % n;
        if (s < 0)
            s += n;
        return s - lead;
    }

    // Which item is at this distance from the bar's outer edge, or -1. The
    // views hit-test by arithmetic rather than by giving every icon its own
    // mouse area: the icons are drawn into a texture so the popup's end can be
    // cut to its curve, and a captured item receives no input.
    function indexAt(a) {
        let best = -1;
        let bestD = root.style.cellPitch / 2;
        for (let i = 0; i < root.count; i++) {
            const d = Math.abs(root.aOf(i) - a);
            if (d < bestD) {
                bestD = d;
                best = i;
            }
        }
        return best;
    }

    // Where item i sits, in `a`.
    function aOf(i) {
        return root.style.barCell / 2 + root.slotOf(i) * root.style.cellPitch;
    }

    // An item's own colour. A NAME rather than a colour (a role of the bar's hue table, "power.sleep", or a Theme token's old
    // reel name), so a theme switch reaches it through this binding instead of through `items` (BarHues.tint).
    function tintOf(item) {
        return BarHues.tint(item && item.tint ? item.tint : "accent");
    }
}
