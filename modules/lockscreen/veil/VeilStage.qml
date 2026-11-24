pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/system"

// =============================================================================
// VeilStage.qml -- a veil proposal on a stand-in lock screen, for mockups
// (test_lockveil*.qml) and renders. NOT part of the lock: the lock composes
// the same layers itself (still, veil, and the shell's popup above).
//
//   black ground            what Hyprland shows behind a lock with nothing drawn
//   the held still          desktop_<mode>_blur.png from the lockscreen fixtures
//                           under mockups/: the user's own wallpaper with two tiled windows,
//                           blurred like the lock blur
//   the veil                LockVeil (the clock) + the proposal
//   the popup silhouette    where the real bar + lock popup will sit, so a
//                           veil is judged with them on top
//
// At the real size (2880 x 1620, the laptop panel at scale 1): a mockup
// shows it through its zoom, so a veil's features read at their true size.
//
// Two ways to show a proposal:
//   VeilStage { proposal: "relief" }                     the host loads it
//   VeilStage { proposal: ""; VeilRelief { host: s.veil } }
//                                                        a mockup declares it,
//                                                        so its panel can
//                                                        target it at creation
// =============================================================================
Item {
    id: stage

    implicitWidth: 2880
    implicitHeight: 1620
    // A lock surface is its screen: nothing a veil draws exists past it.
    clip: true

    // A declared veil goes here (see above).
    default property alias external: slot.data

    property string proposal: "relief"
    // Boot: nothing behind the lock -- no still, the veil opaque.
    property bool boot: false
    property bool showPopup: true
    property real presence: 1
    // Idle: `autoIdle` rests the veil after `idleSeconds` without input, as
    // the lock does; off, `awake` is set by hand.
    property bool autoIdle: true
    property int idleSeconds: 30
    property bool awake: true
    property real fps: 60
    // Renders stop the clock and seek it (LockVeil.seek).
    property bool clockRunning: true
    property bool onBattery: false
    property real batteryFpsRatio: 0.5

    // THE UNLOCK'S RETRACT. In the lock the `ok` is also the moment the shell's popup
    // closes into the bar (LockOwner: phase "unlocking" -> engine.close()), and every veil
    // that follows `popupRect` (dials, gooey) follows it in. With `retractOnOk` the
    // silhouette does the same, from the newest `ok` the host holds, as a pure function of
    // the host's time and pulses (a seeked film is exact): the popup's foot rises to its
    // top over `retractMs` on the engine's own close curve (GooeyEngine: openMs 400,
    // OutBack, overshoot 1.2 -- the close of `engine.close()` with no options; the popup
    // keeps its width and top, GooeyBody `originBox` of a widthFrom-1 popup is full width
    // and no height, and an overshoot past zero height is no height). Once it has no
    // height the host gets what LockSurface gives it, `_goneRect`: one pixel wide, no
    // height, at the popup's top centre. Off by default: a mockup that pulses `ok` keeps
    // its popup.
    property bool retractOnOk: false
    property real retractMs: 400
    property real retractOvershoot: 1.2
    // 0 = open, 1 = the clock's end (the curve itself overshoots past it).
    readonly property real retract: stage._retractAt(host.time, host.pulses)
    // the popup's height now, in px, 0 once collapsed
    readonly property real popupHeight: {
        if (stage.arrival < 1)
            return Math.max(0, popup.height * stage._outBack(stage.arrival, stage.retractOvershoot));
        const e = stage._outBack(Math.min(1, stage.retract), stage.retractOvershoot);
        return stage.retract > 0 ? Math.max(0, popup.height * (1 - e)) : popup.height;
    }
    readonly property bool _popupShown: stage.showPopup && stage.arrived
    function _outBack(t, s) {
        const u = t - 1;
        return u * u * ((s + 1) * u + s) + 1;
    }
    function _retractAt(time, pulses) {
        if (!stage.retractOnOk || !pulses)
            return 0;
        let at = -1;
        for (const p of pulses)
            if (p.kind === "ok" && p.t <= time && p.t > at)
                at = p.t;
        return at < 0 ? 0 : Math.min(1, (time - at) * 1000 / Math.max(1, stage.retractMs));
    }

    // THE SHELL ARRIVING (a boot: the veil is up seconds before the shell). Before `arriveAt` (veil seconds) there is
    // no popup and no bar -- the veil's popupRect and barRect are empty, as the lock's are before the shell's first
    // hints -- and from it the popup comes out of the bar on the engine's open curve (GooeyEngine: openMs 400, OutBack,
    // overshoot 1.2), as a pure function of the host's time. -1: there from the start.
    property real arriveAt: -1
    property real arriveMs: 400
    readonly property bool arrived: stage.arriveAt < 0 || host.time >= stage.arriveAt
    // 0 = just arrived, 1 = open
    readonly property real arrival: stage.arriveAt < 0 ? 1 : Math.max(0, Math.min(1, (host.time - stage.arriveAt) * 1000 / Math.max(1, stage.arriveMs)))

    readonly property alias veil: host
    readonly property bool dark: host.dark

    function pulse(kind, x, y) { stage._input(); host.pulse(kind, x, y); }
    function wake() { stage._input(); }
    function rest() { stage.awake = false; idle.stop(); }

    // Where the popup's password field sits on the silhouette: key pulses
    // start there, as they will on the lock.
    readonly property point fieldPoint: Qt.point(stage.width / 2, popup.y + popup.height * 0.62)

    function _input() {
        if (!stage.awake)
            host.pulse("wake", stage.fieldPoint.x, stage.fieldPoint.y);
        stage.awake = true;
        if (stage.autoIdle)
            idle.restart();
    }
    Timer {
        id: idle
        interval: stage.idleSeconds * 1000
        running: stage.autoIdle
        onTriggered: stage.awake = false
    }

    Rectangle {
        anchors.fill: parent
        color: "black"
    }
    Image {
        id: stillImage
        anchors.fill: parent
        visible: !stage.boot
        source: "file://" + RepoRoot.dir + "/mockups/fixtures/lockscreen/desktop_" + (stage.dark ? "dark" : "light") + "_blur.png"
        smooth: true
        mipmap: false
        fillMode: Image.Stretch
        asynchronous: false
    }

    LockVeil {
        id: host
        anchors.fill: parent
        proposal: stage.proposal
        presence: stage.presence
        opaque: stage.boot
        still: stage.boot ? null : stillImage
        awake: stage.awake
        running: stage.clockRunning
        fps: stage.onBattery ? stage.fps * stage.batteryFpsRatio : stage.fps
        pointer: hover.hovered ? ({ x: hover.point.position.x, y: hover.point.position.y }) : null
        popupRect: !stage._popupShown ? Qt.rect(0, 0, 0, 0)
                 : stage.popupHeight >= 0.5 ? Qt.rect(popup.x, popup.y, popup.width, stage.popupHeight)
                 : Qt.rect(popup.x + popup.width / 2 - 0.5, popup.y, 1, 0)
        barRect: stage._popupShown ? Qt.rect(bar.x, bar.y, bar.width, bar.height) : Qt.rect(0, 0, 0, 0)
    }
    Item {
        id: slot
        anchors.fill: parent
    }

    // The popup silhouette: a top bar and the lock popup hanging from it.
    Item {
        anchors.fill: parent
        visible: stage._popupShown
        Rectangle {
            id: bar
            x: (parent.width - width) / 2
            y: 0
            width: 1600
            height: 40
            color: Theme.surface
            radius: 20
            Rectangle { anchors { left: parent.left; right: parent.right; top: parent.top } height: 20; color: Theme.surface }
        }
        // The popup's place and full size (what `fieldPoint` is measured on); `popupShape`
        // is what is drawn, which a retract shortens.
        Item {
            id: popup
            x: (parent.width - width) / 2
            y: 24
            width: 560
            height: 660
        }
        Rectangle {
            x: popup.x
            y: popup.y
            width: popup.width
            height: stage.popupHeight
            visible: stage.popupHeight >= 0.5
            radius: Math.min(28, height / 2)
            color: Theme.surface
        }
    }

    HoverHandler {
        id: hover
        // A pointer that did not move is not input: offscreen the handler
        // reports its unchanged point again right after rest(), which wakes
        // the stage at once.
        property point _last: Qt.point(-1, -1)
        onPointChanged: {
            const p = hover.point.position;
            if (p.x === hover._last.x && p.y === hover._last.y)
                return;
            hover._last = Qt.point(p.x, p.y);
            stage._input();
        }
    }
    TapHandler {
        onTapped: (ev) => stage.pulse("key", ev.position.x, ev.position.y)
    }
    focus: true
    Keys.onPressed: (e) => {
        if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter)
            stage.pulse("fail", stage.fieldPoint.x, stage.fieldPoint.y);
        else
            stage.pulse("key", stage.fieldPoint.x, stage.fieldPoint.y);
    }
}
