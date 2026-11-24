pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// WheelStepper.qml -- wheel units in, whole steps out.
//
// The detent behind every "a swipe steps one thing" in this shell that is not
// a rubber band: the card views (CardViewCycler) and the detail's days
// (WeatherDetail). A host's ONE wheel reader latches the gesture's axis and
// feeds the units on that axis; this answers how many steps they complete:
//
//     WheelStepper { id: stepper; notchThreshold: 120; pixelThreshold: 1000; stepCooldownMs: 200 }
//     const steps = stepper.feed(units, fromPixels);   // signed; 0 most of the time
//     stepper.end();                                   // fingers lifted / idle
//
// THE TWO THRESHOLDS. A NOTCH is a mouse wheel's (angleDelta 120, no
// pixelDelta): one notch, one step. A device that reports pixels -- a
// touchpad, which on Wayland sends angle deltas TOO -- sends a stream of small
// angle deltas, and 120 of them is a finger drift of a few millimetres: that
// would overshoot the card views. So the host says which device
// the event came from (`fromPixels`: the event carried a pixel delta on that
// axis) and a touchpad counts against `pixelThreshold` (1000, the view
// switcher's detent, TabSelector.swipeThreshold).
//
// THE COOLDOWN. After a step, feeds are swallowed for `stepCooldownMs` and
// what they carried is dropped, so a fast flick moves one step per cooldown
// instead of racing through the list; with a cooldown a feed completes at
// most ONE step. 0 turns it off (a feed may then complete several). It is the
// FINGERS': a mouse's notches are the user's own count, one step each however
// fast they come.
//
// A reversal drops what was gathered the other way, so a gesture that turns
// back does not have to pay off its own past first. end() drops everything,
// the cooldown included: the next gesture starts clean.
//
// Plain numbers only: nothing binds to the accumulator or the deadline, and
// nothing is created, so a feed inside a wheel delivery is safe.
// =============================================================================
QtObject {
    id: stepper

    property real notchThreshold: 120
    property real pixelThreshold: 1000
    property int stepCooldownMs: 200

    property real _accum: 0
    // Date.now() until which feeds are swallowed.
    property real _coolUntil: 0

    // Units > 0 step forward. Returns the signed number of steps completed.
    function feed(units, fromPixels) {
        if (!(units !== 0) || !isFinite(units))
            return 0;
        const now = Date.now();
        if (fromPixels && now < stepper._coolUntil) {
            stepper._accum = 0;
            return 0;
        }
        const th = Math.max(1, fromPixels ? stepper.pixelThreshold : stepper.notchThreshold);
        if (stepper._accum !== 0 && Math.sign(units) !== Math.sign(stepper._accum))
            stepper._accum = 0;
        stepper._accum += units;
        let steps = 0;
        while (Math.abs(stepper._accum) >= th) {
            const dir = stepper._accum > 0 ? 1 : -1;
            stepper._accum -= dir * th;
            steps += dir;
            if (fromPixels && stepper.stepCooldownMs > 0) {
                stepper._accum = 0;
                stepper._coolUntil = now + stepper.stepCooldownMs;
                break;
            }
        }
        return steps;
    }
    function end() {
        stepper._accum = 0;
        stepper._coolUntil = 0;
    }
}
