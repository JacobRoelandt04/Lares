pragma ComponentBehavior: Bound

import QtQuick

import "../theme"

// =============================================================================
// SkeletonBar.qml
//
// One silhouette bar standing in for a string that does not exist yet, pulsing
// while it is waited for. The single-line counterpart of `ListSkeleton`, which
// draws a whole list's worth; this is for the places where exactly one piece of
// text is missing -- an answer's title while the model is still writing it, a
// conversation's name before its first answer has been titled.
//
// THE RULE IT EXISTS TO ENFORCE: no word stands in for a title that has not
// been written. A placeholder ("Untitled", "…", the first few words of the
// question) is a claim, and it is wrong twice -- once while it shows and once
// when it is replaced by something else. A bar is honestly nothing.
//
// The pulse is the same 900 ms InOutSine either way that `ListSkeleton` uses,
// so two skeletons on screen at once breathe together. `pulse: false` freezes
// it, which is what a render comparison needs: with the pulse running no two
// grabs of the same state are the same picture.
//
// THE BREATH IS A DISTANCE, NOT A RATIO. A `scale` is a multiplier: on three
// bars of 724, 681 and 449 px the same 0.965 moves their ends 12.7, 11.9 and
// 7.9 px, so the long line visibly pulses 61 % harder than the short one and
// the column reads as uneven. `pulseTravel` is instead the number of PIXELS
// each end travels, so bars of any length breathe by the same visible amount;
// left at -1 it falls back to `pulseFraction` of the bar's own width (0.0175
// per end == 0.965 about the centre) for every caller that does not ask to be
// equalised.
//
// The SHORT axis stays proportional. A 724 x 15 bar cannot take 8 px off its
// height and still be that bar, and bars stacked in a column share a height
// anyway, so their vertical motion is already equal -- what needed equalising
// was the axis the lengths differ on.
//
// `pulsePhaseMs` delays one bar's clock against another's, which is how a
// column breathes top to bottom instead of blinking as one block. It is a
// one-off pause ahead of the loop, not a pause inside it: inside, it would add
// dead time to every cycle and stretch the period. The period itself is not
// staggered, so every skeleton on screen still shares one clock, and `breath`
// -- the 0..1 fraction the geometry is made of -- is what a probe reads to
// prove it.
//
// Geometry comes from the caller, measured off the real text it replaces, so
// the bar resolves in place rather than jumping when the string arrives.
// =============================================================================
Item {
    id: bar

    // The bar's own colour, and the ground it lies on. Both are handed in: a
    // skeleton inside a header box takes the list's tone, one lying on the list
    // takes the box's -- the same inversion `ListSkeleton` documents.
    property color barColor: Theme.headerBox
    property color groundColor: Theme.listBox

    property bool pulse: true
    // Pixels each END of the bar travels inward at the trough. -1 means "an
    // amount proportional to my own width" (the fallback below), which is what
    // every caller that has not thought about it gets.
    property real pulseTravel: -1
    // The proportional fallback, and the short axis always: 0.0175 per end is
    // a scale of 0.965 taken about the centre, to the pixel.
    property real pulseFraction: 0.0175
    // The stagger, in ms, of this bar's clock against an unstaggered one.
    property int  pulsePhaseMs: 0
    // Half a breath -- in, then out. `ListSkeleton` uses the same 900.
    property int  pulseHalfMs: 900
    // The breath itself: 0 at full size, 1 at the trough. Readable so a probe
    // can prove two skeletons share a clock without inferring it from pixels.
    readonly property real breath: bar._breath
    property real _breath: 0
    // Presence, so a skeleton can fade out as the real text fades in rather
    // than being cut. The caller keeps the item alive for `fadeMs` after the
    // string arrives if it wants that.
    property bool showing: true
    property int fadeMs: 160
    property real radius: Math.min(height / 2, 4)

    // The guard is not a taste decision: a bar narrower than twice its travel
    // would invert. It binds only under 2 * pulseTravel px of width, i.e. never
    // on a line, and a caller that hands a mark a line's travel gets a mark
    // that stays a mark.
    readonly property real _travelX: bar.pulseTravel >= 0
        ? Math.min(bar.pulseTravel, bar.width * 0.4)
        : bar.width * bar.pulseFraction
    readonly property real _travelY: bar.height * bar.pulseFraction

    implicitWidth: 120
    implicitHeight: 10

    Rectangle {
        id: slab
        // Inset from the bar's own box by the breath, so the bar's declared
        // geometry stays the RESTING one: the real text lands where the
        // silhouette sat at full size, and a still frame (`pulse: false`) is
        // pixel for pixel the full-size bar.
        x: bar._travelX * bar._breath
        y: bar._travelY * bar._breath
        width: bar.width - 2 * slab.x
        height: bar.height - 2 * slab.y
        radius: bar.radius
        color: bar.barColor

        opacity: bar.showing ? 1 : 0
        Behavior on opacity {
            NumberAnimation {
                duration: bar.fadeMs
                easing.type: Easing.OutCubic
            }
        }
    }

    // Waiting reads as motion. Driven on GEOMETRY rather than on `opacity` so
    // it does not fight the presence fade above -- two animations on one
    // property is the bug this shell keeps finding -- and because geometry is
    // antialiased: a fill and its ground can be nine 8-bit levels apart and the
    // motion is still continuous, where the same breath in opacity is five
    // pictures and reads as a jitter.
    SequentialAnimation {
        id: breathe
        running: bar.pulse && bar.showing && bar.visible
        PauseAnimation { duration: bar.pulsePhaseMs }
        SequentialAnimation {
            loops: Animation.Infinite
            NumberAnimation {
                target: bar
                property: "_breath"
                to: 1
                duration: bar.pulseHalfMs
                easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: bar
                property: "_breath"
                to: 0
                duration: bar.pulseHalfMs
                easing.type: Easing.InOutSine
            }
        }
        // A frozen bar is a bar at full size, not one stopped wherever the
        // breath happened to be: a render taken with `pulse: false` has to be
        // the same picture every time.
        onRunningChanged: if (!breathe.running) bar._breath = 0;
    }
}
