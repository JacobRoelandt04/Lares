pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "BodyGeometry.js" as Geo

// =============================================================================
// PhoneStage.qml -- the phone: its body, its two faces, its turn and its keys (docs/contracts/bridge.md section 8).
//
//     PhoneStage {
//         skin: "redmagic-10s-pro-moonlight"
//         front: [ ScreenFace { anchors.fill: parent } ]     // the control panel: lies in the display
//         back:  [ ... ]                                     // items on the back's plate (the popup puts none there)
//     }
//
// THREE LAYERS, bottom up: the FRONT face's items (the display, an opaque ground); the BODY (BodyLayer: one traced
// picture of the whole phone, open where the display is, so the front face shows through it with the display's round
// corners and the glass's glare over it); the BACK face's items (lying on the plate the body draws).
//
// AT REST nothing here moves and nothing is transformed: the face turned to the viewer lies in the camera's own
// plane, where a pixel is a pixel (BodyGeometry.js), so its items are drawn as any popup's are -- sharp, and theirs
// is the pointer. The body is a cached picture; no clock runs.
//
// WHILE IT TURNS the faces are the SAME items under the body's own projection (faceMatrix: the homography of the
// glass they lie on). Nothing is captured into a texture, so there is no hand-over to get wrong: a face's text stays
// text, what moves on it keeps moving, and the pointer is simply kept off both until the turn has landed. The face
// turned away is not drawn.
//
// TWO MOTIONS, never together: the HALF TURN to the other face (a MorphClock: the fingers scrub it, a lift commits
// or springs back) and the FLOURISH (one whole turn, landing where it started). Both nod the body and bring it a
// little towards the viewer on the way.
//
// A turn starts ONE TURN OF THE EVENT LOOP after it is asked for: asking flips the body from its cached layer to a
// live picture, and a layer that flips inside a pointer event's delivery takes down the items the delivery is walking.
// For the same reason the light that follows the pointer makes the body live from a timer, never from the handler.
//
// THE KEYS are zones beside the frame, not items over drawn parts: seen front-on a key is a bump a pixel or two proud.
// =============================================================================
Item {
    id: stage

    // ---- the contract ---------------------------------------------------------------------------------------------
    property string skin: "generic"
    property alias front: frontSlot.data
    property alias back: backSlot.data
    property bool canFlip: true
    property bool relight: true
    property bool wired: false
    property bool busy: false
    property var partEnabled: ({})
    property var partTips: ({})
    property Item overlayItem: null
    // The display's own ground: drawn a hair past the display's outline, under the glass border, so a pixel of the
    // outline that the turning body half covers shows the screen and never the popup's surface.
    property color screenGround: Theme.listBox

    readonly property string face: stage._face
    readonly property bool flipping: stage._moving
    readonly property rect screenRect: Qt.rect(stage._gx + stage._lay.display.x, stage._gy + stage._lay.display.y, stage._lay.display.w, stage._lay.display.h)
    readonly property rect plateRect: Qt.rect(stage._gx + stage._lay.plate.x, stage._gy + stage._lay.plate.y, stage._lay.plate.w, stage._lay.plate.h)
    readonly property real screenRadius: stage._lay.display.r
    readonly property string hoverPart: stage._hoverPart
    // FREE LOOK: while it is held (`lookBegin()` .. `lookEnd()`) the pointer's motion turns the body every way, with
    // nothing pressed; let go, it goes back to the face it showed. `looking` from the hold until the body is back at rest;
    // `lookHeld` only while it is held (the host hides the pointer then). `lookStrayed` asks the host to put the pointer
    // back where the look began (it is hidden: it must never reach the popup's edge); a host that cannot simply does not.
    readonly property bool looking: stage._lookPhase !== 0
    readonly property bool lookHeld: stage._lookPhase === 1
    signal lookStrayed()
    // The pointer moved over the stage, with these keyboard modifiers (the host's free-look key, read off the motion too).
    signal pointerMoved(int modifiers)
    // Nothing of the stage's is moving or about to: the body is its cached picture and no clock of the stage runs.
    readonly property bool atRest: !stage._moving && !stage._lit && stage._gridSame >= 4 && stage._pending === "" && !beginTimer.running && !litOn.running && !litSettle.running && !pressRun.running && !catchRun.running && !stage._lookWant && !glintClock.running && stage._seat === (stage.wired ? 1 : 0)
    signal partClicked(string part)

    // ---- the numbers (the mockup's Body tab) ----------------------------------------------------------------------
    property real pxPerMm: 3.7
    // The body stands this far below the stage's top, and as far above its foot: mid-turn the near edge of the phone
    // is nearer the camera and so taller, and it must stay inside the popup (the foot's room is also the cable's).
    property real topMargin: 30
    property real camDist: 2000
    property int halfTurnMs: 560
    property int flourishMs: 950
    property real nodDeg: 6
    property real liftPx: 14
    property int relightSettleMs: 160
    // The light the pointer leads: a pointer that comes in far from where the light stands does not take it there at
    // once. The light sets off slowly and gathers speed until it has caught the pointer (`relightCatchMs`, an ease-in),
    // and from then on it is the pointer's. "Far" is `relightJump` of the stage's half extent.
    property int relightCatchMs: 420
    property real relightJump: 0.18
    property int pressMs: 120
    // Free look: the pointer's way for one whole turn sideways (px) and for a quarter turn up or down; how long the way
    // back takes; how far the body lifts off while it is held (px, with a springy settle of `lookLiftMs`); how long the
    // glint that says "ready" takes; and how far the hidden pointer may stray before it is put back.
    property real lookTurnPx: 520
    property real lookTiltPx: 190
    property int lookBackMs: 420
    property real lookLiftPx: 9
    property int lookLiftMs: 320
    property int lookGlintMs: 620
    property real lookStrayPx: 48
    // A harness, or the mockup's pose slider, holds the body at this many turns (0 the front, 0.5 the back; -1: free),
    // and, while it is held, tipped by `pinTilt` degrees about the stage's horizontal axis (its head away from the viewer
    // for a positive tilt: 90 shows the bottom wall, -90 the top one), so every side can be looked at.
    property real pinTurn: -1
    property real pinTilt: 0
    readonly property alias body: bodyLayer
    // The whole phone larger, drawn at its new size (never magnified: the body is traced again at the new pixels per mm). The
    // popup's cast sets it while the user resizes; every number above stays the phone at zoom 1.
    property real zoom: 1

    // (the layout's fallback for a stage with no size yet computes the same numbers itself: reading these from it is a loop
    // through the host, which sizes the stage from them)
    implicitWidth: Math.round(320 * stage.zoom)
    implicitHeight: Math.round(664 * stage.zoom)

    // ---- geometry -------------------------------------------------------------------------------------------------
    DeviceScale {
        id: dev
    }
    readonly property var _sk: Geo.skin(stage.skin)
    readonly property var _lay: Geo.layout(stage._sk, stage.width > 0 ? stage.width : 320 * stage.zoom, stage.height > 0 ? stage.height : 664 * stage.zoom, dev.value, {
        pxPerMm: stage.pxPerMm * stage.zoom,
        top: stage.topMargin * stage.zoom,
        camDist: stage.camDist * stage.zoom
    })
    readonly property var _zones: Geo.zones(stage._sk, stage._lay, stage._face)

    // ---- the pose -------------------------------------------------------------------------------------------------
    property string _face: "front"
    property string _startFace: "front"
    property bool _turning: false
    property real _spin: 0
    // what a turn asked before it could start: "" | "to" | "scrub" | "flourish"
    property string _pending: ""
    property real _scrubP: 0
    // the half turn's target while it runs by itself (-1: none): a theme switch holds the clock and gives it back
    property real _runTo: -1

    readonly property bool _pinned: stage.pinTurn >= 0
    // held at a pose: by a harness's pin, or by the free look (which a pin outranks)
    readonly property bool _held: stage._pinned || stage._lookPhase !== 0
    readonly property real _heldTurn: stage._pinned ? stage.pinTurn : (stage._face === "front" ? 0 : 0.5) + stage._lookYawNow
    readonly property real _heldTilt: stage._pinned ? stage.pinTilt : stage._lookPitchNow
    readonly property bool _moving: stage._turning || stage._held
    // How far through its arc a motion is, 0 at either rest and 1 half way: what the nod and the lift follow.
    readonly property real _progress: stage._pinned ? Math.max(Math.abs(Math.sin(2 * Math.PI * stage.pinTurn)), Math.abs(Math.sin(stage.pinTilt * Math.PI / 180))) : (stage._held ? 0 : Math.sin(Math.PI * half.me) + Math.sin(Math.PI * stage._spin))
    readonly property real _turn: stage._held ? stage._heldTurn : (stage._startFace === "front" ? 0 : 0.5) + (stage._startFace === "front" ? 0.5 : -0.5) * half.me + stage._spin
    readonly property var _restAxes: stage._face === "front" ? ({ ex: [1, 0, 0], ey: [0, 1, 0], ez: [0, 0, 1] }) : ({ ex: [-1, 0, 0], ey: [0, 1, 0], ez: [0, 0, -1] })
    // A pose's rest is RETURNED, not computed: cos(pi) is -1 but sin(pi) is not 0.
    readonly property var _axes: stage._moving ? Geo.basis(stage._turn, stage._held ? stage._heldTilt : stage.nodDeg * stage._progress) : stage._restAxes
    readonly property real _lift: stage._moving ? (stage.liftPx * stage._progress + stage.lookLiftPx * stage._lookLiftNow) * stage.zoom : 0
    readonly property bool _frontShown: stage._moving ? Geo.facing(stage._axes) > 0 : stage._face === "front"

    function _matrix(rect: var, back: bool): matrix4x4 {
        const m = Geo.faceMatrix(stage._lay, stage._axes, rect, back, stage._lift);
        return Qt.matrix4x4(m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11], m[12], m[13], m[14], m[15]);
    }
    readonly property matrix4x4 _still: Qt.matrix4x4(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)

    MorphClock {
        id: half
        morphMs: stage.halfTurnMs
        onLanded: stage._landed()
    }
    NumberAnimation {
        id: spinRun
        target: stage
        property: "_spin"
        from: 0
        to: 1
        duration: stage.flourishMs
        easing.type: Easing.OutQuart
        onFinished: {
            // the pose at 1 is the pose at rest: let go first, then put the clock back
            stage._turning = false;
            stage._spin = 0;
        }
    }
    Timer {
        id: beginTimer
        interval: 0
        onTriggered: stage._start()
    }

    function _ask(what: string) {
        stage._pending = what;
        beginTimer.restart();
    }
    function _start() {
        const what = stage._pending;
        stage._pending = "";
        if (what === "" || Theme.crossfading)
            return;
        if (!stage._turning) {
            stage._startFace = stage._face;
            half.mt = 0;
            stage._spin = 0;
            stage._turning = true;
        }
        if (what === "flourish") {
            spinRun.restart();
        } else if (what === "to") {
            stage._runTo = 1;
            half.runTo(1);
        } else if (what === "scrub") {
            half.scrubTo(stage._scrubP);
        }
    }
    function _landed() {
        stage._runTo = -1;
        // Each write leaves a true pose: the face first (the turn reads the face it STARTED from), then the turn is
        // let go (the pose is now the new face's rest, which is where the clock stands), then the clock goes back.
        if (half.mt >= 0.5)
            stage._face = stage._startFace === "front" ? "back" : "front";
        stage._turning = false;
        half.mt = 0;
        stage._startFace = stage._face;
    }

    // The fingers' share of a half turn, 0..1 (SwipeScrub's `scrub`).
    function scrubTo(p: real) {
        if (!stage.canFlip || spinRun.running || stage._runTo >= 0)
            return;
        stage._scrubP = Math.max(0, Math.min(0.999, p));
        if (stage._turning)
            half.scrubTo(stage._scrubP);
        else
            stage._ask("scrub");
    }
    // The lift: on to the other face.
    function commit() {
        if (spinRun.running)
            return;
        if (stage._turning) {
            stage._runTo = 1;
            half.runTo(1);
        } else if (stage.canFlip) {
            stage._ask("to");
        }
    }
    // The lift, short of it: back to the face it left.
    function cancel() {
        stage._pending = "";
        if (stage._turning && !spinRun.running) {
            stage._runTo = 0;
            half.runTo(0);
        }
    }
    function flipTo(face: string) {
        if (face !== stage._face && !stage._turning && stage.canFlip)
            stage._ask("to");
    }
    // One whole turn, landing on the face it started from. Never restarted while one plays.
    function flourish() {
        if (!stage._turning && stage._pending === "")
            stage._ask("flourish");
    }
    // Both of the body's pipelines drawn once: live for a moment, then the cached layer (the engine's prewarm).
    function warm() {
        stage._touch();
    }

    // ---- free look ---------------------------------------------------------------------------------------------------
    // 0 at rest, 1 held (the pointer turns the body), 2 on its way back. The pose is a TURNTABLE: sideways motion turns the
    // body about its own long axis (as far as one likes), up and down tips it about the stage's horizontal (a quarter
    // turn each way: the head's wall, the foot's), and nothing rolls it, so it never hangs crooked. The surface nearest
    // the eye follows the hand. The way back is ONE clock: both angles run `from + (to - from) * t` to the nearest whole
    // turn (the face it showed, the short way round) and level, and the lift comes down on the same clock.
    property int _lookPhase: 0
    property bool _lookWant: false
    property real _lookYaw: 0               // turns from the resting face
    property real _lookPitch: 0             // degrees
    property real _lookLift: 0              // 0..1 (overshoots: a springy settle)
    property real _lookT: 0                 // the way back, 0..1
    property real _lookYaw0: 0
    property real _lookPitch0: 0
    property real _lookLift0: 0
    property real _glint: 0
    readonly property real _lookYawNow: stage._lookPhase === 2 ? stage._lookYaw0 + (Math.round(stage._lookYaw0) - stage._lookYaw0) * stage._lookT : stage._lookYaw
    readonly property real _lookPitchNow: stage._lookPhase === 2 ? stage._lookPitch0 * (1 - stage._lookT) : stage._lookPitch
    readonly property real _lookLiftNow: stage._lookPhase === 2 ? stage._lookLift0 * (1 - stage._lookT) : stage._lookLift
    // where the look began and where the pointer last was (stage px); a put-back has been asked for
    property point _lookAnchor: Qt.point(0, 0)
    property point _lookLast: Qt.point(0, 0)
    property bool _lookWarpDue: false

    NumberAnimation {
        id: lookLiftRun
        target: stage
        property: "_lookLift"
        to: 1
        duration: stage.lookLiftMs
        easing.type: Easing.OutBack
        easing.overshoot: 2.2
    }
    // out across the glass and back: a sine's half wave
    NumberAnimation {
        id: glintClock
        target: glintPhase
        property: "p"
        from: 0
        to: 1
        duration: stage.lookGlintMs
        easing.type: Easing.InOutSine
    }
    QtObject {
        id: glintPhase
        property real p: 0
        onPChanged: stage._glint = Math.sin(Math.PI * glintPhase.p)
    }
    NumberAnimation {
        id: lookBackRun
        target: stage
        property: "_lookT"
        from: 0
        to: 1
        duration: stage.lookBackMs
        easing.type: Easing.OutCubic
        onFinished: {
            // at 1 the pose is the face's own rest: let go first (the rest is RETURNED), then put the clocks back
            stage._lookPhase = 0;
            stage._lookYaw = 0;
            stage._lookPitch = 0;
            stage._lookLift = 0;
            stage._lookT = 0;
        }
    }
    // (from a timer: the hold can come from a pointer's own delivery, and the body's layer must not flip inside one)
    Timer {
        id: lookTimer
        interval: 0
        onTriggered: stage._lookStart()
    }
    // Holds the look. false: not now (a turn is playing, a pin holds the body, a theme switch is under way).
    function lookBegin(): bool {
        if (stage._lookPhase === 1 || stage._lookWant)
            return true;
        if (stage._turning || stage._pending !== "" || stage._pinned || Theme.crossfading)
            return false;
        stage._lookWant = true;
        lookTimer.restart();
        return true;
    }
    function _lookStart() {
        if (!stage._lookWant)
            return;
        stage._lookWant = false;
        if (stage._turning || stage._pending !== "" || stage._pinned || Theme.crossfading)
            return;
        if (stage._lookPhase === 2) {
            // caught on its way back: it carries on from where it is
            const y = stage._lookYawNow, p = stage._lookPitchNow, l = stage._lookLiftNow;
            lookBackRun.stop();
            stage._lookYaw = y;
            stage._lookPitch = p;
            stage._lookLift = l;
            stage._lookT = 0;
        }
        stage._lookAnchor = stage._lastPoint;
        stage._lookLast = stage._lastPoint;
        stage._lookWarpDue = false;
        stage._lookPhase = 1;
        lookLiftRun.from = stage._lookLift;
        lookLiftRun.restart();
        glintClock.restart();
    }
    // The pointer went this far (px): right brings the near surface right, down brings it down.
    function lookBy(dx: real, dy: real) {
        if (stage._lookPhase !== 1 || Theme.crossfading)
            return;
        stage._lookYaw -= dx / Math.max(1, stage.lookTurnPx * stage.zoom);
        stage._lookPitch = Math.max(-90, Math.min(90, stage._lookPitch - dy / Math.max(1, stage.lookTiltPx * stage.zoom) * 90));
    }
    // Lets go: back to the face it showed.
    function lookEnd() {
        stage._lookWant = false;
        if (stage._lookPhase !== 1)
            return;
        lookLiftRun.stop();
        stage._lookYaw0 = stage._lookYaw;
        stage._lookPitch0 = stage._lookPitch;
        stage._lookLift0 = stage._lookLift;
        stage._lookT = 0;
        stage._lookPhase = 2;
        if (stage._lookWarpDue || Math.hypot(stage._lookLast.x - stage._lookAnchor.x, stage._lookLast.y - stage._lookAnchor.y) > 0.5)
            stage.lookStrayed();
        lookBackRun.restart();
    }
    // The hidden pointer moved (the stage's hover): its way turns the body; past `lookStrayPx` from where the look began
    // the host is asked to put it back, and the jump home that follows is no motion of the hand.
    function _lookMoved(pt: point) {
        const ax = stage._lookAnchor.x, ay = stage._lookAnchor.y;
        if (stage._lookWarpDue && Math.hypot(pt.x - ax, pt.y - ay) < 0.4 * stage.lookStrayPx) {
            // put back: the pointer stood at the start, and what it is off it now is the hand's way since (dropping it
            // lost a step of the hand at every put-back: a sixth of a sweep, measured nested)
            stage._lookWarpDue = false;
            stage.lookBy(pt.x - ax, pt.y - ay);
            stage._lookLast = pt;
            return;
        }
        stage.lookBy(pt.x - stage._lookLast.x, pt.y - stage._lookLast.y);
        stage._lookLast = pt;
        if (!stage._lookWarpDue && Math.hypot(pt.x - ax, pt.y - ay) > stage.lookStrayPx) {
            stage._lookWarpDue = true;
            stage.lookStrayed();
        }
    }

    // A theme switch is a still picture of the frame before: what turns on its own clock holds still under it.
    Connections {
        target: Theme
        function onCrossfadingChanged() {
            if (Theme.crossfading) {
                if (spinRun.running)
                    spinRun.pause();
                if (stage._runTo >= 0)
                    half.stop();
                for (const a of [lookBackRun, lookLiftRun, glintClock])
                    if (a.running)
                        a.pause();
            } else {
                if (spinRun.paused)
                    spinRun.resume();
                if (stage._runTo >= 0)
                    half.runTo(stage._runTo);
                for (const a of [lookBackRun, lookLiftRun, glintClock])
                    if (a.paused)
                        a.resume();
            }
        }
    }

    // ---- the light that follows the pointer -----------------------------------------------------------------------
    property bool _lit: false
    // where the pointer leads the light (-1..1 each way), where the light set off from, and how far it has caught up
    property real _aimX: 0
    property real _aimY: 0
    property real _fromX: 0
    property real _fromY: 0
    property real _catch: 1
    readonly property real _slideX: Math.round((stage._fromX + (stage._aimX - stage._fromX) * stage._catch) * 64) / 64
    readonly property real _slideY: Math.round((stage._fromY + (stage._aimY - stage._fromY) * stage._catch) * 64) / 64
    property point _lastPoint: Qt.point(-1, -1)
    NumberAnimation {
        id: catchRun
        target: stage
        property: "_catch"
        from: 0
        to: 1
        duration: stage.relightCatchMs
        easing.type: Easing.InQuart
    }

    function _touch() {
        litOn.restart();
        litSettle.restart();
    }
    Timer {
        id: litOn
        interval: 0
        onTriggered: stage._lit = true
    }
    Timer {
        id: litSettle
        interval: stage.relightSettleMs
        onTriggered: {
            if (pressRun.running || catchRun.running)
                litSettle.restart();
            else
                stage._lit = false;
        }
    }
    // On the stage itself, an ancestor of both faces: a hover handler stacked OVER a face would take its links' hover.
    HoverHandler {
        id: hover
        onPointChanged: {
            const pt = hover.point.position;
            // a resting pointer's point is delivered again with every frame: only one that MOVED counts
            if (Math.abs(pt.x - stage._lastPoint.x) < 0.5 && Math.abs(pt.y - stage._lastPoint.y) < 0.5)
                return;
            stage._lastPoint = pt;
            stage.pointerMoved(hover.point.modifiers);
            // held for a look, the pointer's way turns the body and leads no light
            if (stage._lookPhase === 1) {
                stage._lookMoved(pt);
                return;
            }
            if (!stage.relight)
                return;
            const ax = pt.x / Math.max(1, stage.width) * 2 - 1, ay = pt.y / Math.max(1, stage.height) * 2 - 1;
            // far from where the light stands (the pointer came in at another side): the light sets off after it from
            // where it is. A chase already under way keeps its clock: only its goal moves.
            if (!catchRun.running && Math.hypot(ax - stage._slideX, ay - stage._slideY) > stage.relightJump) {
                const fx = stage._slideX, fy = stage._slideY;
                stage._catch = 0;
                stage._fromX = fx;
                stage._fromY = fy;
                stage._aimX = ax;
                stage._aimY = ay;
                catchRun.restart();
            } else {
                stage._aimX = ax;
                stage._aimY = ay;
            }
            stage._touch();
        }
    }

    // ---- the keys -------------------------------------------------------------------------------------------------
    property string _hoverPart: ""
    property string _pressPart: ""
    property real _pressF: 0
    readonly property var _press: {
        const out = [0, 0, 0, 0];
        const row = stage._pressPart === "" ? -1 : Geo.keyRow(stage._sk, stage._pressPart);
        if (row >= 0)
            out[row] = stage._pressF;
        return out;
    }
    SequentialAnimation {
        id: pressRun
        NumberAnimation { target: stage; property: "_pressF"; to: 1; duration: stage.pressMs * 0.4; easing.type: Easing.OutCubic }
        NumberAnimation { target: stage; property: "_pressF"; to: 0; duration: stage.pressMs; easing.type: Easing.OutCubic }
    }
    function _pressed(part: string) {
        if (stage.partEnabled[part] !== true)
            return;
        stage._pressPart = part;
        stage._touch();
        pressRun.restart();
        stage.partClicked(part);
    }

    // ---- under the body: the cable -----------------------------------------------------------------------------------
    // In while the phone is on the cable and at rest; out (quickly) for a turn: a cable does not turn with a phone.
    property real _seat: stage.wired && !stage._moving ? 1 : 0
    Behavior on _seat {
        NumberAnimation { duration: stage._moving ? 90 : 260; easing.type: Easing.OutCubic }
    }
    // ---- the device grid ----------------------------------------------------------------------------------------------
    // Everything the stage draws is laid out on whole device pixels COUNTED FROM ITS OWN CORNER; where the popup puts
    // that corner is the engine's business, and at a scale of 1.25 a whole design pixel is not a whole device pixel.
    // So the stage's content lies in one item moved by the corner's fraction of a pixel (to the nearest one): the
    // body's edges and the display's are on the glass's own pixels wherever the popup stands. The corner is read
    // after each frame's animations until it has stood still for four frames, and again whenever the stage is told
    // (or can tell) it may have moved.
    property real _gx: 0
    property real _gy: 0
    property int _gridSame: 0
    function regrid() {
        stage._gridSame = 0;
    }
    function _regrid() {
        const win = stage.Window.window;
        if (!win)
            return;
        const o = stage.mapToItem(null, 0, 0);
        // the WINDOW's ratio (the attached Screen's is an integer at a fractional Hyprland scale)
        const dpr = win.devicePixelRatio > 0 ? win.devicePixelRatio : 1;
        const px = o.x * dpr, py = o.y * dpr;
        let fx = px - Math.round(px), fy = py - Math.round(py);
        if (Math.abs(fx) < 1e-3)
            fx = 0;
        if (Math.abs(fy) < 1e-3)
            fy = 0;
        const gx = -fx / dev.value, gy = -fy / dev.value;
        if (Math.abs(gx - stage._gx) < 1e-4 && Math.abs(gy - stage._gy) < 1e-4) {
            stage._gridSame++;
            return;
        }
        stage._gridSame = 0;
        stage._gx = gx;
        stage._gy = gy;
    }
    Connections {
        target: stage._gridSame < 4 ? stage.Window.window : null
        function onAfterAnimating() {
            stage._regrid();
        }
    }
    onWidthChanged: stage.regrid()
    onHeightChanged: stage.regrid()
    onVisibleChanged: stage.regrid()
    on_MovingChanged: stage.regrid()

    // The display's ground runs this far past the display's outline, under the glass border.
    readonly property real _bleed: 2 / dev.value

    Item {
        id: grid
        x: stage._gx
        y: stage._gy
        width: stage.width
        height: stage.height
        CableStub {
            id: cable
            seat: stage._seat
            x: Math.round(stage._lay.cx - width / 2)
            y: stage._lay.body.y + stage._lay.body.h - 2
            height: stage.height - y
        }

        // ---- bottom: the front face -----------------------------------------------------------------------------------
        Item {
            id: frontHost
            x: stage._lay.display.x - stage._bleed
            y: stage._lay.display.y - stage._bleed
            width: stage._lay.display.w + 2 * stage._bleed
            height: stage._lay.display.h + 2 * stage._bleed
            visible: stage._frontShown
            transform: Matrix4x4 {
                matrix: stage._moving ? stage._matrix(frontHost, false) : stage._still
            }
            // The display's ground, round where the display is round: a square corner would stand out past the body's own
            // rounded corner, which is nearer than the display's corner is deep.
            Rectangle {
                anchors.fill: parent
                radius: stage._lay.display.r + stage._bleed
                color: stage.screenGround
            }
            Item {
                id: frontSlot
                x: stage._bleed
                y: stage._bleed
                width: stage._lay.display.w
                height: stage._lay.display.h
            }
        }

        // ---- middle: the body -----------------------------------------------------------------------------------------
        // IN DEVICE PIXELS: the host is scaled back by the device scale, so one unit in it is one pixel of the glass, and
        // it is the stage taken UP to whole pixels. A layer is a texture of whole pixels shown over its item's rect: for
        // an item 652 units tall at 1.5625 (1018.75 px) the cached picture came out squeezed by a quarter pixel from the
        // top down -- soft, and not the picture the live body draws -- whatever texture size was asked for.
        Item {
            id: bodyHost
            scale: 1 / dev.value
            transformOrigin: Item.TopLeft
            width: Math.ceil(stage.width * dev.value - 1e-3)
            height: Math.ceil(stage.height * dev.value - 1e-3)
        }
        BodyLayer {
            id: bodyLayer
            parent: bodyHost
            anchors.fill: parent
            lay: stage._lay
            sk: stage._sk
            skinName: Geo.SKINS[stage.skin] !== undefined ? stage.skin : "generic"
            axes: stage._axes
            lift: stage._lift
            cached: !(stage._moving || stage._lit || glintClock.running)
            press: stage._press
            busy: stage.busy ? 1 : 0
            lightSlideX: stage._slideX
            lightSlideY: stage._slideY
            glint: stage._glint
        }

        // ---- top: the back face ---------------------------------------------------------------------------------------
        Item {
            id: backHost
            x: stage._lay.plate.x
            y: stage._lay.plate.y
            width: stage._lay.plate.w
            height: stage._lay.plate.h
            visible: !stage._frontShown
            transform: Matrix4x4 {
                matrix: stage._moving ? stage._matrix(backHost, true) : stage._still
            }
            Item {
                id: backSlot
                anchors.fill: parent
            }
        }

        // While it turns both faces are deaf: a cover takes every button (`enabled: false` on the faces would be inherited
        // by everything in them, and take the accent off their default buttons).
        MouseArea {
            anchors.fill: parent
            visible: stage._moving
            acceptedButtons: Qt.AllButtons
            hoverEnabled: true
            onWheel: wheel => wheel.accepted = false
        }

        // Held for a look, the pointer is not shown (the host keeps putting it back where the look began). It takes no
        // button: the cover above is what makes the faces deaf, for a look as for a turn.
        MouseArea {
            anchors.fill: parent
            visible: stage._lookPhase === 1
            acceptedButtons: Qt.NoButton
            hoverEnabled: true
            cursorShape: Qt.BlankCursor
            onWheel: wheel => wheel.accepted = false
        }

        // The zones of the keys and of the cable.
        Repeater {
            model: ["power", "volup", "voldown", "cable"]
            MouseArea {
                id: zone
                required property string modelData
                readonly property var box: stage._zones[zone.modelData] || null
                readonly property bool on: stage.partEnabled[zone.modelData] === true
                readonly property bool there: zone.box !== null && !stage._moving && (zone.modelData !== "cable" || stage.wired)
                x: zone.box ? zone.box.x : 0
                y: zone.box ? zone.box.y : 0
                width: zone.box ? zone.box.w : 0
                height: zone.box ? zone.box.h : 0
                visible: zone.there
                hoverEnabled: true
                cursorShape: zone.on ? Qt.PointingHandCursor : Qt.ArrowCursor
                onContainsMouseChanged: {
                    if (zone.containsMouse)
                        stage._hoverPart = zone.modelData;
                    else if (stage._hoverPart === zone.modelData)
                        stage._hoverPart = "";
                }
                onClicked: stage._pressed(zone.modelData)

                HoverTip {
                    anchorItem: zone
                    overlayItem: stage.overlayItem
                    text: stage.partTips[zone.modelData] || ""
                    show: zone.containsMouse && zone.there && (stage.partTips[zone.modelData] || "") !== ""
                    side: zone.modelData === "cable" ? "above" : (stage._face === "back" ? "right" : "left")
                }
            }
        }
    }
}
