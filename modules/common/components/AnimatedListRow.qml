pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// AnimatedListRow.qml
//
// Generic staggered slide wrapper for one row of a list. Entering rows fly in
// from the LEFT, leaving rows fly out to the RIGHT, on a top-down stagger.
//
// Driven by three properties set from the delegate's model:
//   rowState     "rest" | "entering" | "leaving" | "collapsed"
//   staggerIdx   rank within the wave; row N starts N * staggerMs after row 0
//   startDelayMs what the whole wave waits first; 0 unless it is a turn-around
//
// HEIGHT MOVES WITH THE SLIDE
// ---------------------------
// The row's height is animated on exactly the same clock as its x — same
// delay, same duration, same easing. This is what makes whatever sits BELOW
// the list track the incoming rows instead of jumping out of the way.
//
// Animating only x and letting each row take its full height the moment it is
// created would make every row claim its space at once, so on expanding a
// category the content underneath would be shoved its entire final distance
// in a single frame while the rows were still sliding in — the list would
// appear to fly off screen and then get slowly filled in behind it. Tying
// height to the same fraction as the slide means row 5 arriving pushes the
// content below by exactly row 5's height, at the moment it arrives.
//
// "collapsed" is the instant form of "leaving": zero height, no animation, no
// slide. It exists so a caller can retire rows that are outside the viewport
// without paying for animation the user cannot see — see UpdateCategorySection
// for why that matters for long lists.
//
// `startDelayMs` IS ONE WAVE'S HEAD START, and it is what lets a list aim an
// interrupted wave at ONE instant. When a collapse is reversed while it is
// still running, each row that was in the air finishes the flight it started,
// and the returning wave may not begin until the last of them has landed -- so
// every row of the return has to wait a DIFFERENT amount (what is left of its
// own flight) before the shared stagger applies. That is one number per row on
// top of `staggerIdx * staggerMs`, not a second clock: the kick still lands
// exactly once, at `startDelayMs + staggerIdx * staggerMs`. 0 for every
// ordinary wave. See docs/contracts/list_animation.md, "Interrupting".
//
// Motion is IMPERATIVE (NumberAnimations targeting properties) rather than
// Behavior-driven. Qt's Behavior semantics skip the initial binding
// evaluation, so a binding-driven version leaves the first row (staggerIdx 0,
// zero delay) with a no-op slide and flashes other rows at their resting
// position for a frame before they jump off-screen to start.
//
// Content contract: exactly one child, anchored left/right (or with explicit
// width) and reporting a meaningful implicitHeight. Do NOT anchor the content
// vertically or use anchors.fill — the wrapper measures the content to size
// itself, so filling would be circular. Set `contentHeight` to bypass: it
// sizes BOTH the wrapper and the holder the content fills, so the height then
// comes from the caller and the cycle cannot form.
// =============================================================================
Item {
    id: rowWrap

    // ---- Inputs ----
    property string rowState: "rest"   // rest | entering | leaving | collapsed
    property int    staggerIdx: 0
    // Added to this row's stagger before the kick. See the header.
    property int    startDelayMs: 0

    // ---- Tuning ----
    property int  animDuration: 240
    property int  staggerMs: 55
    property int  animEasing: Easing.OutCubic
    property real offscreenMargin: 40
    property real virtualSpacing: 6
    // Set false to keep full height throughout (x slides, layout does not
    // reflow). Useful when the list itself is being replaced wholesale.
    property bool animateHeight: true

    // Escape hatch: >= 0 bypasses measuring the content.
    property real contentHeight: -1

    // OPTIONAL: a StaggerClock. With one, the row waits its stagger on THAT clock (what was drawn, a frame never
    // counting for more than its `maxStepMs`) instead of on a wall-clock Timer, so a frame that stalls does not
    // fire every pending row of a wave in one turn. The Timer stays as a backstop, three times as long. Null:
    // the row waits on the Timer alone.
    property var waveClock: null


    // The row is about to move (its turn in the wave): a host that builds its content late builds it here, while the
    // row is still flat.
    signal kicked()

    default property alias rowContent: holder.data

    width: parent ? parent.width : 0

    readonly property real _measured:
        contentHeight >= 0 ? contentHeight : holder.childrenRect.height
    readonly property real _fullHeight: _measured + virtualSpacing

    // 0 → no space claimed, 1 → full space. Animated in lock-step with x.
    property real _extent: 1

    // A ROW FLIPPED MID-FLIGHT RESUMES FROM WHERE IT IS, instead of snapping to
    // its new state's start. OPT-IN, and off by default on purpose: the snap is
    // what makes an entering row show off-screen and flat on its first rendered
    // frame, and every list that retires rows in a stagger depends on it.
    //
    // It exists for a gap that MOVES. The queue's drop gap is a phantom row,
    // and moving it one slot flips the old phantom to "leaving" and inserts a
    // new one. With the snap, a phantom that was 20 % grown would jump to 100 %
    // for a frame before collapsing -- so every slot change would instantly add
    // up to a whole row pitch to the column, and every row below the finger
    // would be shoved down and back. Drag across the list at a row every 50 ms
    // and three or four of those overlap: one entire half of the list jitters.
    //
    // Resuming is what makes PlayerQueue's `_reslot` contract true: the one
    // that is there collapses while the new one grows, on the same clock, so
    // their sum never changes.
    property bool resumeOnStateChange: false

    implicitHeight: rowWrap.animateHeight
        ? rowWrap._extent * rowWrap._fullHeight
        : rowWrap._fullHeight

    // Content fades with the last of the extent so a row that is nearly
    // collapsed does not show a sliver of clipped text.
    readonly property real _contentOpacity:
        rowWrap.animateHeight ? Math.min(1, rowWrap._extent * 2.5) : 1

    readonly property real _offRight: width + offscreenMargin
    readonly property real _offLeft: -width - offscreenMargin

    // What THIS kick takes. A plain property with NO binding of its own, for
    // two reasons: assigning to an animation's `duration` from JS would destroy
    // its binding to `animDuration` for good, and giving this one a binding
    // would only move the same trap one property along. 0 means "not kicked
    // yet", and the animations fall back to `animDuration` until it is.
    property int _kickMs: 0

    NumberAnimation {
        id: slideAnim
        target: rowWrap
        property: "x"
        duration: rowWrap._kickMs > 0 ? rowWrap._kickMs : rowWrap.animDuration
        easing.type: rowWrap.animEasing
    }
    NumberAnimation {
        id: extentAnim
        target: rowWrap
        property: "_extent"
        duration: rowWrap._kickMs > 0 ? rowWrap._kickMs : rowWrap.animDuration
        easing.type: rowWrap.animEasing
    }

    Timer { id: kickTimer; repeat: false; onTriggered: { rowWrap._unwait(); rowWrap._kick(); } }

    Component.onCompleted: {
        _snapToStart();
        _scheduleKick();
    }
    onRowStateChanged: {
        // Clean handoff when a row is flipped mid-flight.
        slideAnim.stop();
        extentAnim.stop();
        _snapToStart();
        _scheduleKick();
    }

    // Snap to the state's starting values BEFORE any kick, so the first
    // rendered frame shows an entering row off-screen and flat rather than
    // briefly at its resting position and full height.
    function _snapToStart() {
        // `collapsed` is the INSTANT form and is never resumed: its whole
        // purpose is to retire a row outside the viewport without animation.
        if (rowWrap.resumeOnStateChange && rowState !== "collapsed"
            && rowWrap._started)
            return;
        rowWrap._started = true;
        switch (rowState) {
            case "entering":  x = _offLeft; _extent = 0; break;
            case "leaving":   x = 0;        _extent = 1; break;
            case "collapsed": x = 0;        _extent = 0; break;
            default:          x = 0;        _extent = 1; break;   // rest
        }
    }

    // A resuming row still has to snap ONCE -- on the way in, before its first
    // frame -- or it would enter at whatever `_extent` defaults to.
    property bool _started: false

    // The clock's due time while the row waits on it (-1: not waiting). Released exactly once.
    property real _kickDue: -1
    function _unwait() {
        if (rowWrap._kickDue >= 0) {
            rowWrap._kickDue = -1;
            if (rowWrap.waveClock) rowWrap.waveClock.release();
        }
    }
    Connections {
        target: rowWrap.waveClock
        enabled: rowWrap._kickDue >= 0
        function onNowChanged() {
            if (rowWrap._kickDue >= 0 && rowWrap.waveClock.now >= rowWrap._kickDue) {
                kickTimer.stop();
                rowWrap._unwait();
                rowWrap._kick();
            }
        }
    }
    Component.onDestruction: rowWrap._unwait()

    function _scheduleKick() {
        kickTimer.stop();
        rowWrap._unwait();
        if (rowState === "entering" || rowState === "leaving") {
            // At least one frame at the start position before moving off it.
            const delay = Math.max(16, rowWrap.startDelayMs
                                       + rowWrap.staggerIdx * rowWrap.staggerMs);
            if (rowWrap.waveClock) {
                rowWrap._kickDue = rowWrap.waveClock.now + delay;
                rowWrap.waveClock.hold();
                kickTimer.interval = delay * 3 + 700;
            } else {
                kickTimer.interval = delay;
            }
            kickTimer.restart();
        }
    }

    function _kick() {
        slideAnim.stop();
        extentAnim.stop();
        rowWrap.kicked();
        if (rowState === "entering")      { slideAnim.to = 0;         extentAnim.to = 1; }
        else if (rowState === "leaving")  { slideAnim.to = _offRight; extentAnim.to = 0; }
        else return;
        // A resumed row has less of the journey left, so it is given
        // proportionally less time: the gap then moves at ONE speed however
        // often it is re-aimed, instead of easing over the full duration from
        // wherever it happened to have got to.
        rowWrap._kickMs = rowWrap.resumeOnStateChange
            ? Math.max(16, Math.round(rowWrap.animDuration
                                      * Math.min(1, Math.abs(extentAnim.to - rowWrap._extent))))
            : rowWrap.animDuration;
        slideAnim.start();
        extentAnim.start();
    }


    Item {
        id: holder
        anchors.left: parent.left
        anchors.right: parent.right
        y: rowWrap.virtualSpacing / 2
        // HEIGHT COMES FROM `contentHeight` WHEN THE CALLER SUPPLIED ONE.
        //
        // `implicitHeight: childrenRect.height` in every case would be a
        // cycle for exactly the content the `contentHeight` escape hatch
        // exists to serve: content that fills the holder takes its height
        // FROM the holder, and the holder would take its height from the
        // content. Qt breaks such a cycle by dropping one evaluation and
        // warns -- "Binding loop detected for property implicitHeight" on
        // this line. PlayerQueue and PlayerLibrary both set `contentHeight`,
        // so it wins here.
        //
        // With no `contentHeight` the holder still measures its children, and
        // that is not a cycle: the contract for that case is content anchored
        // left/right with its own implicitHeight, which never reads back the
        // holder's height.
        height: rowWrap.contentHeight >= 0 ? rowWrap.contentHeight
                                           : childrenRect.height
        opacity: rowWrap._contentOpacity
    }
}
