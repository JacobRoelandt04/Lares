pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// SwipeSteps.qml -- the shell's ONE sticky swipe: wheel units in, whole steps
// out, a rubber band between. The feel the system update's tab selector is
// tuned to, shared with TabSelector so that the workspaces' ball steps with
// exactly the same numbers and nothing is copied.
//
//     SwipeSteps { id: swipe; count: tabs.length; index: current
//                  onStepped: (dir, to) => select(to) }
//     swipe.feed(dx)        one signed delta of the gesture (> 0 steps forward)
//     swipe.feed(0)         the fingers lifted (libinput's scroll-end)
//     swipe.notch(n)        a mouse's wheel: n whole steps
//     swipe.pull            the lean, in positions: signed, |pull| <= maxPull
//
// A swipe is a WHEEL (docs/contracts/gestures.md):
// the host reads it with a MouseArea (never a WheelHandler), picks the axis and
// feeds the units on it. This is the detent behind that reader:
//
//   ACCUMULATE against `threshold` (1500 units): a swipe is thousands of units,
//     and the failure it guards against is a flick of a few millimetres
//     skipping two items.
//   GIVE with a taper: `1 - (1 - t)^pullTaper` of `maxPull` positions, most of
//     the lean early and then resistance, so what is left of the gesture reads
//     as effort. It saturates below half a position: the lean can never
//     complete a step by itself, or the detent would have nothing to snap.
//   MOMENTUM: above `momentumRate` units a second the surplus of a step is
//     kept and the cooldown skipped, so a flick carries through the middle of a
//     list instead of stalling on it.
//   COOLDOWN: `cooldownMs` between committed steps otherwise, so one long slow
//     swipe steps once at a time -- the precise stop.
//   LIFT: a zero delta releases the band (the lean springs home on an OutBack,
//     `returnMs`); `idleResetMs` is only the fallback for a device that never
//     sends one, deliberately far longer than a person holds still.
//   NOTHING THAT WAY: no position to step to and the lean stays 0 -- leaning
//     into empty track would suggest a move that could never happen.
//
// THE HOST MAY ANSWER LATE. `index` is where the host IS; a step is announced
// with `stepped(dir, to)` and the engine counts from `to` until the host's
// `index` has got there (or `answerMs` have passed), so a compositor that
// takes a few milliseconds to say the workspace changed does not lose the
// second step of a flick -- nor repeat the first when the flick runs past the
// end of the list and is released there. A host that moves at once (the tab
// selector) is the same case with no wait.
//
// The numbers below ARE the shell's defaults: every host that wants the shell's
// feel leaves them alone.
//
// An Item only to own its Timers; it is never drawn, never laid out and takes
// no slot wherever it is declared (BoundaryClock's reason).
// =============================================================================
Item {
    id: root

    visible: false
    width: 0
    height: 0

    // ---- what the host says -----------------------------------------------------
    // How many positions there are, and which one the host is on. `enabled` (the
    // Item's own) false: the swipe is ignored altogether.
    property int count: 0
    property int index: 0

    // ---- the feel (the shell's; see the note above) -----------------------------
    // Accumulated wheel units that commit one step. Higher = more deliberate.
    property real threshold: 1500
    // How far the lean may leave its position while the gesture is under way, as
    // a fraction of one position.
    property real maxPull: 0.42
    // How sharply the lean tapers: >1 front-loads the travel.
    property real pullTaper: 2.5
    // Units per second above which a swipe carries enough momentum to cross more
    // than one position.
    property real momentumRate: 2400
    // The least spacing between committed steps of a slow swipe.
    property int cooldownMs: 320
    // The spring the lean takes home when the gesture ends or commits.
    property int returnMs: 320
    // Fallback only: see LIFT above.
    property int idleResetMs: 6000
    // The longest a host may take to move to a position it was told to go to. A step
    // it never makes (a refused focus) stops being counted from after this.
    property int answerMs: 600

    // ---- what it says -------------------------------------------------------------
    // The lean, in positions (signed: > 0 toward the next one). The host turns it
    // into whatever it moves -- a pill's pixels, a ball's along-line distance.
    readonly property real pull: root._pull
    // The wheel units held toward the next step.
    readonly property real accum: root._accum
    // A gesture is under way: units are held, or the lean is not home yet.
    readonly property bool active: root._accum !== 0 || root._pull !== 0 || pullReturn.running
    // A step the host is to take: `dir` is +1 / -1, `to` the position it lands on.
    signal stepped(int dir, int to)

    // Feed one delta of the gesture; 0 is the fingers lifting.
    function feed(d: real): void {
        if (d === 0)
            root._lift();
        else
            root._feed(d);
    }

    // `n` whole steps of a mouse's wheel (signed, > 0 forward: WheelHub's `steps`): taken at once, one a notch. A notch has no way to lean
    // and no momentum to hold back, so neither the threshold nor the cooldown is asked.
    function notch(n: int): void {
        if (!root.enabled || n === 0)
            return;
        if (root._accum !== 0 || root._pull !== 0)
            root._release();
        for (let i = 0; i < Math.abs(n); i++)
            if (!root._step(n > 0 ? 1 : -1))
                return;
    }

    // ---- the engine -----------------------------------------------------------------
    property real _pull: 0
    property real _accum: 0
    property real _velocity: 0
    property real _lastMs: 0
    property bool _cooling: false
    // The position the last step ordered, while the host has not yet got there (-1: none),
    // and when. A release does NOT forget it: a flick released at the end of the list is
    // released while the host is still answering, and a count from the stale `index` would
    // order the same steps again.
    property int _ordered: -1
    property real _orderedAt: 0

    onIndexChanged: {
        if (root._ordered >= 0 && root.index === root._ordered)
            root._ordered = -1;
    }

    // Where the host will be: read live, in a function, so that no binding can be a
    // generation behind the `index` that just changed.
    function _base(): int {
        if (root._ordered >= 0 && Date.now() - root._orderedAt < root.answerMs)
            return root._ordered;
        return root.index;
    }

    function _pullFor(accum: real): real {
        if (root.threshold <= 0 || root.count === 0)
            return 0;
        const dir = accum > 0 ? 1 : -1;
        const next = root._base() + dir;
        if (next < 0 || next >= root.count)
            return 0;
        // 1 - (1 - t)^k puts most of the displacement in the first part of the
        // gesture; tanh is near enough to linear over this range to read as a
        // plain slide.
        const t = Math.min(1, Math.abs(accum) / root.threshold);
        return dir * (1 - Math.pow(1 - t, root.pullTaper)) * root.maxPull;
    }

    function _step(dir: int): bool {
        const next = root._base() + dir;
        if (root.count === 0 || next < 0 || next >= root.count) {
            root._release();
            return false;
        }
        // Held BEFORE the signal: a host that moves at once changes `index` inside it.
        root._ordered = next;
        root._orderedAt = Date.now();
        root.stepped(dir, next);
        return true;
    }

    function _release(): void {
        root._accum = 0;
        root._velocity = 0;
        idle.stop();
        pullReturn.stop();
        pullReturn.from = root._pull;
        pullReturn.start();
    }

    // A zero delta is the touchpad saying the fingers have left the surface. That, not
    // a timeout, is what lets the band go: a timeout would spring a held partial lean
    // back after a second although the gesture is still in progress.
    function _lift(): void {
        if (root._accum !== 0 || root._pull !== 0)
            root._release();
    }

    function _feed(d: real): void {
        // (A delta that is not a number would poison the held units for ever: no wheel sends one, a host's arithmetic can.)
        if (!root.enabled || d === 0 || !isFinite(d))
            return;
        if (root._cooling)
            return;

        // Rate of accumulation, smoothed: does the gesture carry the momentum to cross
        // more than one position?
        const now = Date.now();
        const dt = Math.max(1, now - root._lastMs);
        root._lastMs = now;
        root._velocity = root._velocity * 0.6 + (Math.abs(d) / (dt / 1000)) * 0.4;

        pullReturn.stop();
        root._accum += d;
        idle.restart();

        // As many steps as the accumulation covers. Normally one, and the remainder is
        // dropped. A fast swipe keeps its remainder and skips the cooldown: the lean
        // has the momentum to clear a middle position, so it should.
        let stepped = 0;
        while (Math.abs(root._accum) >= root.threshold) {
            const dir = root._accum > 0 ? 1 : -1;
            if (!root._step(dir))
                break;
            stepped += 1;
            const fast = root._velocity >= root.momentumRate;
            root._accum = fast ? root._accum - dir * root.threshold : 0;
            if (!fast)
                break;
        }

        if (stepped > 0 && root._velocity < root.momentumRate) {
            root._release();
            root._cooling = true;
            cooldown.restart();
            return;
        }

        root._pull = root._pullFor(root._accum);
    }

    NumberAnimation {
        id: pullReturn
        target: root
        property: "_pull"
        to: 0
        duration: root.returnMs
        // A slight overshoot on the way home reads as the spring releasing.
        easing.type: Easing.OutBack
        easing.overshoot: 0.9
    }
    Timer {
        id: idle
        interval: root.idleResetMs
        repeat: false
        onTriggered: root._release()
    }
    Timer {
        id: cooldown
        interval: root.cooldownMs
        repeat: false
        onTriggered: root._cooling = false
    }
}
