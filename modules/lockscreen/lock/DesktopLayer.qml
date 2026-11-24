pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

import "../../common/components"


// =============================================================================
// DesktopLayer.qml -- what the lock shows of the desktop beneath it, from the
// moment it locks until it unlocks. One per screen (LockSurface creates it
// through a Loader).
//
// WHAT IS POSSIBLE. The lock is a session-lock surface: the compositor draws
// the desktop beneath it (xray) or nothing. It never hands the lock the pixels
// beneath, except through an output capture (ScreencopyView), which contains
// whatever the lock itself has on screen at that moment. Everything here is
// built from that.
//
// THE CHOREOGRAPHY (non-boot; the veil starts AT ONCE)
//   0. prepareLock (HyprSettings, before locked=true): the surface is clear,
//      xray on, lock blur off: the first lock frame IS the live sharp desktop.
//   1. after `secure`: capture S0 (the sharp desktop) with the surface clear
//      and show it opaque -- identical to what is beneath, so no jump. NOT WHILE
//      THE SHELL'S POPUP MOVES (else a ghost popup appears, still and fainter,
//      behind the sliding one): the popup the shell draws
//      above the lock opens from the first state, usually still sliding when
//      `secure` comes, and the hints that mask it out of S0 are the rects of a
//      frame or more ago -- so what the capture holds of a popup in motion is
//      bigger or elsewhere than the hole that is filled, and the rest of it is
//      blurred in as a faint second popup. The capture waits until the hints have
//      been still for captureQuietMs (120), at most captureMaxWaitMs (500) after
//      `secure`; the surface is clear and the live desktop shows through (xray on)
//      all that while, which is what the first lock frame is anyway. With no shell
//      (no hint ever changed) it does not wait at all.
//   2. two presented frames later S0 is what the screen shows: `veilRise` turns
//      true and the BLUR-IN starts, in the same instant. DesktopBlur draws the
//      compositor's blur algorithm (kawase, contrast, grain) over S0 from sharp
//      to full strength in blurInMs; the veil rises over it. xray goes OFF
//      (the compositor stops drawing the desktop for the rest of the lock; its
//      own blur is never used) only once the VEIL IS UP (presence 0.97, ~1.1 s
//      later): a frame Qt has swapped is not yet on the compositor's side (it
//      holds a commit for its GPU fence, and swap signals can arrive queued from
//      frames drawn before S0), while the xray switch acts at once -- timed on
//      the swaps it blinked the screen black for a frame or two between "S0 on
//      screen" and the compositor showing it (the sleep film caught it at every
//      other lock under load). The surface is opaque from S0 on, so xray beneath
//      it shows nothing; by the time the veil is up S0 has long been applied.
//   3. when the ramp has finished `settled` says the picture will not change
//      again; the blurred picture stays live (hint rectangles may still move).
//   The picture the veil samples (`still`) is a copy of the blur's output, taken
//   every frame of the ramp and again whenever the hints change.
//   Hint rectangles (the real bars and popup, which the compositor draws above
//   the lock and which S0 contains) are rebuilt from their surroundings
//   (DesktopInpaint) in S0 BEFORE it is blurred, so no ghost of a popup that
//   later changes size stays in the blur.
//
//   UNLOCK (the hold): `beginUnlock` holds everything as it is for
//   unlockHoldMs -- the veil at full presence, its `ok` playing -- then
//   switches xray on beneath the (opaque) lock a moment before the fade, and
//   fades the lock over unlockMs to the live SHARP desktop, `unlockFaded`. Before
//   the veil is up (nothing to admire) there is no hold. Boot: nothing to
//   capture: settled and veilRise at once, no still; the unlock holds too.
//
// OBSCURED WINDOWS (Obscurer) are covered from the first frame; S0 is taken of
// the output with the placeholders on it.
//
// THE CHECK. S0 is judged before it is shown (PictureProbe): a copy that came
// out EMPTY -- all transparent or all black -- would be a black screen the
// moment xray goes off, under the rising veil and again under the unlock. An
// empty S0 is asked again with a fresh view (`_s0Gen`), up to three
// copies, each logged `LARESLOCK fact desktop <out>: S0 empty (<n>)`; then there
// is NO S0: xray stays on, the veil rises over the live desktop (what the
// first lock frame shows anyway), and xray goes off once the veil is up and
// covers it (the veil is opaque without a still).
//
// FACTS. A ScreencopyView fed straight into hidden layered passes
// reads as BLACK: it is always copied through a ShaderEffectSource. The pyramid
// of passes is built at creation, drawn at an opacity that rounds to nothing,
// so S0 can start its blur-in a frame after it is on screen.
//
// TIMING. Animations and timers run on the render loop, but the waits count
// FRAMES PRESENTED (frameSwapped), never milliseconds alone: S0 must be on the
// screen before xray goes off, or the desktop blinks black. The compositor
// copies at its next output frame (~19 ms measured in the test Hyprland).
//
// INTERFACE (fixed by the contract; `hypr`, `trace`, `veilRise` are additions)
//   screen, boot, lockState, config, hints, veilHost
//   still, settled, veilRise, fadeOut, beginUnlock(), unlockFaded()
//   hypr: the lock's one HyprSettings; xray goes off only when every screen has
//   S0 on screen. Null -> this layer makes its own (a single-screen lock).
// =============================================================================
Item {
    id: root

    // ---- interface ----------------------------------------------------------------
    property var screen: null
    property bool boot: false
    property var lockState: null
    // { blurInMs, unlockHoldMs, unlockMs, obscure, ... }
    property var config: ({})
    // [[x, y, w, h], ...] in this screen's logical px
    property var hints: []
    property Item veilHost: null
    // additions
    property var hypr: null
    property bool trace: false
    // hint rectangles are grown by this much before they are filled (px)
    property real hintPad: 6

    readonly property Item still: root._stillOn ? stillTex : null
    readonly property bool settled: root._settled
    // true from the moment the veil may begin to rise: S0 is on screen
    readonly property bool veilRise: root._veilRise
    readonly property real fadeOut: root._fade
    // where the choreography is (probes read it): "wait" "s0" "blurin" "settled"
    // "holding" "unlocking"
    readonly property string stage: root._st

    signal unlockFaded

    function beginUnlock(): void {
        root._beginUnlock();
    }

    // ---- config with defaults -----------------------------------------------------
    function _c(key: string, dflt: var): var {
        const v = root.config ? root.config[key] : undefined;
        return v === undefined || v === null ? dflt : v;
    }
    readonly property real _blurInMs: root._c("blurInMs", 250)
    readonly property real _holdMs: root._c("unlockHoldMs", 600)
    readonly property real _unlockMs: root._c("unlockMs", 400)
    readonly property real _settleMs: root._c("captureSettleMs", 30)
    readonly property real _quietMs: root._c("captureQuietMs", 120)
    readonly property real _maxWaitMs: root._c("captureMaxWaitMs", 500)
    // a probe's ARM: capture at `secure` whatever the hints are doing
    readonly property bool _armNoWait: root._c("armNoWait", false)
    readonly property real _blurSize: root._c("blurSize", 10)
    readonly property var _obscure: root._c("obscure", [])
    // ARMS: a probe breaks one thing at a time to prove its check can fail
    readonly property bool _armNoMask: root._c("armNoMask", false)
    // the veil waits for the end of the blur-in
    readonly property bool _armVeilLate: root._c("armVeilLate", false)
    // the unlock fades at once, without the hold
    readonly property bool _armNoHold: root._c("armNoHold", false)
    // the fade starts without waiting for xray to come on (black beneath it)
    readonly property bool _armUnlockBare: root._c("armUnlockBare", false)
    // xray goes off the moment S0 is captured, and S0 covers 500 ms later: black between
    readonly property bool _armCoverLate: root._c("armCoverLate", false)

    // ---- state ----------------------------------------------------------------------
    property string _st: "wait"
    property bool _settled: false
    property bool _veilRise: false
    property real _fade: 0
    property bool _blurActive: false
    property bool _stillOn: false
    property real _blurT: 0
    property real _s0Alpha: 0
    // THE CHECK: the view's generation (a fresh view per re-ask), the empty copies so far, how many may come out empty
    property int _s0Gen: 0
    property int _s0Empty: 0
    readonly property int _s0EmptyAsks: 3
    readonly property ScreencopyView _s0View: s0Loader.item as ScreencopyView
    // S0 (or no S0) is on screen: xray goes off once the veil is up
    property bool _xrayAfterVeil: false
    // the blur pyramid exists from the creation of the layer, drawn at an opacity
    // that rounds to nothing, so its shaders and framebuffers are built before
    // S0 is there to cover the surface
    property bool _warm: false
    property bool _unlocking: false
    property real _t0: Date.now()
    readonly property var _hs: root.hypr ? root.hypr : ownHypr
    readonly property string _name: root.screen ? root.screen.name : ""
    readonly property bool _secure: root.lockState !== null && root.lockState.phase !== "locking"
    readonly property real _dpr: root.Window.window ? root.Window.window.devicePixelRatio : 1

    // The steps of the engage, always (the lock's persistent log is a post-mortem's only record of what the screen did)
    function _fact(msg: string): void {
        console.log("LARESLOCK fact desktop " + root._name + ": " + msg);
    }
    function _log(msg: string): void {
        if (root.trace)
            console.log("DESKTOP " + root._name + " " + (Date.now() - root._t0).toFixed(0) + " " + msg);
    }

    HyprSettings {
        id: ownHypr
    }

    // ---- what draws ----------------------------------------------------------------------
    Item {
        id: content
        anchors.fill: parent
        opacity: 1 - root._fade

        // The sharp desktop, captured with the surface clear. Never drawn itself
        // (the Loader is at opacity 0): the inpaint reads it through s0tex. One
        // view per generation: an S0 that came out empty is asked again with a
        // fresh one.
        Loader {
            id: s0Loader
            anchors.fill: parent
            opacity: 0
            sourceComponent: root._s0Gen % 2 === 0 ? s0Even : s0Odd
        }
        Component {
            id: s0Even
            ScreencopyView {
                captureSource: root.screen
                live: false
            }
        }
        Component {
            id: s0Odd
            ScreencopyView {
                captureSource: root.screen
                live: false
            }
        }

        Timer {
            id: s0Retry
            interval: 25
            onTriggered: root._captureS0()
        }

        // (the inpaint samples it blurred, mip level 2.5)
        ShaderEffectSource {
            id: s0tex
            anchors.fill: parent
            sourceItem: s0Loader
            live: false
            mipmap: true
            visible: false
        }

        // does the copy hold anything (THE CHECK)
        PictureProbe {
            id: s0probe
            source: s0tex
            file: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/lares-lock-s0-" + (root._name !== "" ? root._name : "none") + ".xpm"
            onJudged: (verdict, inked, samples) => root._s0Judged(verdict, inked, samples)
        }

        // S0 with the hints rebuilt: the sharp source of the blur. A layer, hidden.
        DesktopInpaint {
            id: inpaint
            anchors.fill: parent
            visible: false
            src: s0tex
            rects: root._armNoMask ? [] : root.hints
            pad: root.hintPad
            layer.enabled: root._blurActive || root._warm
            layer.smooth: true
            layer.textureSize: Qt.size(Math.round(inpaint.width * root._dpr), Math.round(inpaint.height * root._dpr))
        }

        // The blurred picture's copy: what the veil samples. Under the blur (it is
        // drawn, tiny cost, because a source nobody draws may not be grabbed), live
        // through the ramp, then only when the hints move.
        ShaderEffectSource {
            id: stillTex
            anchors.fill: parent
            sourceItem: blurLoader
            live: root._st === "blurin"
            visible: root._stillOn
            textureSize: Qt.size(Math.round(stillTex.width * root._dpr), Math.round(stillTex.height * root._dpr))
        }

        Loader {
            id: blurLoader
            anchors.fill: parent
            active: root._blurActive || root._warm
            opacity: root._warm ? 0.0011 : root._s0Alpha
            sourceComponent: DesktopBlur {
                source: inpaint
                strength: root._blurT
                size: root._blurSize
                grain: root._c("blurNoise", 0.1)
            }
        }

        Obscurer {
            id: obscurer
            anchors.fill: parent
            screen: root.screen
            obscure: root._obscure
            live: !root._settled
        }
    }

    // the veil samples the still
    Binding {
        target: root.veilHost
        property: "still"
        value: root.still
        when: root.veilHost !== null
    }
    // a hint that moves after the ramp: the blur is rebuilt, the copy follows
    // The last moment the shell did something that moves its popup: connected, said where it shows it (ShellLink.activeAt), or changed
    // a hint. The popup opens on the lock's first state, so a lock that has just heard from the shell has a popup on its way whose hints
    // are not here yet -- capturing then holds the whole popup, unmasked.
    property real shellAt: 0
    onShellAtChanged: {
        root._hintsAt = Math.max(root._hintsAt, root.shellAt);
        root._log("shell active");
    }
    property real _hintsAt: 0
    property real _secureAt: 0
    // (a binding that yields a new empty array again is not a change: only a different rect list counts)
    property string _hintsKey: "[]"
    onHintsChanged: {
        const key = JSON.stringify(root.hints);
        if (key !== root._hintsKey) {
            root._hintsKey = key;
            root._hintsAt = Date.now();
            root._log("hints");
        }
        if (root._stillOn && root._st !== "blurin")
            stillTex.scheduleUpdate();
    }

    // ---- frame accounting ---------------------------------------------------------------
    property int _swapWait: 0
    property var _swapFn: null

    // Run fn after `n` frames of the window have been presented (and, when
    // minMs > 0, that long after now). window.update() guarantees the frames
    // exist even when nothing else changes. A swap counts only once a frame has
    // BEGUN since the call (afterAnimating, on this thread, before the frame's
    // sync): frameSwapped arrives queued, and swaps of frames drawn before the
    // call -- delivered right after a call made from a callback, as the picture
    // check's answer is -- would end the wait with nothing of the call drawn
    // (S0 "on screen" 3 ms after it was set, under load).
    property bool _swapFrameBegun: false
    function _afterSwaps(n: int, minMs: real, fn: var): void {
        root._swapWait = n;
        root._swapFn = fn;
        root._swapFrameBegun = false;
        swapGuard.restart();
        if (root.Window.window)
            root.Window.window.update();
        minTimer.interval = Math.max(1, minMs);
        minTimer.restart();
        root._minDone = false;
    }
    property bool _minDone: true
    function _tryFire(): void {
        if (root._swapFn === null || root._swapWait > 0 || !root._minDone)
            return;
        const fn = root._swapFn;
        root._swapFn = null;
        swapGuard.stop();
        fn();
    }
    Connections {
        target: root.Window.window
        function onAfterAnimating() {
            if (root._swapFn !== null)
                root._swapFrameBegun = true;
        }
        function onFrameSwapped() {
            if (root._swapFn !== null) {
                if (!root._swapFrameBegun) {
                    if (root.Window.window)
                        root.Window.window.update();
                    return;
                }
                if (root._swapWait > 0)
                    root._swapWait--;
                if (root._swapWait > 0 && root.Window.window)
                    root.Window.window.update();
                root._tryFire();
            }
        }
    }
    Timer {
        id: minTimer
        onTriggered: {
            root._minDone = true;
            root._tryFire();
        }
    }
    // A wait that never completes (a window that presents nothing) must not stop
    // the lock: go on, and say so.
    Timer {
        id: swapGuard
        interval: 400
        onTriggered: {
            root._log("WARN swap wait timed out in " + root._st);
            root._swapWait = 0;
            root._minDone = true;
            root._tryFire();
        }
    }
    // ---- the choreography -----------------------------------------------------------------
    Component.onCompleted: {
        root._log("created boot=" + root.boot + " hs.frozen=" + root._hs.frozen + " epoch=" + root._t0);
        // A screen that appears after the desktop has gone dark (hotplug), like
        // a boot lock, has nothing beneath it to capture: it takes no part in
        // deciding when xray goes off.
        if (root.boot || root._hs.frozen) {
            root._st = "settled";
            root._settled = true;
            root._veilRise = true;
            return;
        }
        root._register();
        root._warm = true;
        // A layer made after `locked` (LockSurface builds it then) was told so by its first properties, before this handler, with
        // the shell's popup already in the hints: that is where the shell stands, not a movement of it (what moved before is in
        // `shellAt`, which the surface hands over too). Nothing is captured before the view has been in the window for two frames.
        root._hintsKey = JSON.stringify(root.hints);
        root._hintsAt = root.shellAt;
        root._created = true;
        if (root._st === "s0") {
            root._secureAt = Date.now();
            root._log("secure -> capture S0 once the shell's popup is still (born locked)");
            root._fact("secure, the shell last moved " + (root._hintsAt > 0 ? Math.round(Date.now() - root._hintsAt) + " ms ago" : "never"));
            // (30 ms past the frames: building the layer held this thread, and whatever the shell sent meanwhile -- its popup's hints --
            // is read from the socket right after; deciding before it would capture a moving popup)
            root._afterSwaps(2, 30, root._awaitQuiet);
            return;
        }
        root._maybeStart();
    }
    // The screen may arrive a moment after the layer (initial properties are
    // applied in order): a registration under an empty name would leave the
    // real one unsettled for ever, and xray on.
    property bool _registered: false
    function _register(): void {
        if (root._registered || root._name === "")
            return;
        root._registered = true;
        root._hs.register(root._name);
    }
    on_NameChanged: {
        if (root._st !== "settled")
            root._register();
    }
    on_SecureChanged: root._maybeStart()
    onScreenChanged: root._maybeStart()
    function _maybeStart(): void {
        if (root._secure && root.screen && root._st === "wait" && !root._unlocking && !root._settled)
            root._onSecure();
    }

    // A ScreencopyView needs a moment after its source is set before it can
    // capture ("Cannot capture frame, as no recording context is ready"): the
    // capture is retried until a frame is there, and nothing proceeds without
    // one -- a missing S0 shows nothing, and settling on it shows black.
    property int _s0Tries: 0
    function _onSecure(): void {
        root._st = "s0";
        if (root._created)
            root._secureGo();
    }
    function _secureGo(): void {
        root._s0Tries = 0;
        root._secureAt = Date.now();
        root._log("secure -> capture S0 once the shell's popup is still");
        root._fact("secure, the shell last moved " + (root._hintsAt > 0 ? Math.round(Date.now() - root._hintsAt) + " ms ago" : "never"));
        root._awaitQuiet();
    }
    // Component.onCompleted has run (a layer born after `locked` is started by its first properties, before it)
    property bool _created: false
    // The capture waits for a popup in motion (see the header): until the hints are still, never past the cap.
    function _awaitQuiet(): void {
        if (root._unlocking || root._st !== "s0")
            return;
        const now = Date.now();
        const quietIn = root._quietMs - (now - root._hintsAt);
        const left = root._maxWaitMs - (now - root._secureAt);
        if (!root._armNoWait && root._hintsAt > 0 && quietIn > 0 && left > 0) {
            quietTimer.interval = Math.max(1, Math.min(quietIn, left));
            quietTimer.restart();
            return;
        }
        root._log("capture S0");
        root._fact("capture S0, " + Math.round(Date.now() - root._secureAt) + " ms after secure");
        root._captureS0();
    }
    Timer {
        id: quietTimer
        onTriggered: root._awaitQuiet()
    }
    function _captureS0(): void {
        root._s0Tries++;
        if (root._s0View)
            root._s0View.captureFrame();
        root._afterSwaps(2, root._settleMs, root._s0Arrived);
    }

    function _s0Arrived(): void {
        if (root._unlocking)
            return;
        if (!(root._s0View && root._s0View.hasContent) && root._s0Tries < 40) {
            s0Retry.start();
            return;
        }
        // the copy is judged before it is shown (THE CHECK); the probe's pass takes it
        s0tex.scheduleUpdate();
        s0probe.judge();
    }
    function _s0Judged(verdict: string, inked: int, samples: int): void {
        if (root._unlocking || root._st !== "s0")
            return;
        if (verdict === "empty") {
            root._s0Empty++;
            root._fact("S0 empty (" + root._s0Empty + ")");
            if (root._s0Empty < root._s0EmptyAsks) {
                // a fresh view, in the window two frames before it is asked
                root._s0Gen++;
                root._afterSwaps(2, 0, root._captureS0);
                return;
            }
            root._noS0();
            return;
        }
        if (verdict !== "ink")
            root._fact("S0 not checked (" + verdict + "): shown");
        root._log("S0 held");
        root._st = "blurin";
        // the copy again, in the frame that first draws it (the view holds the same frame: the same pixels the check judged), so
        // the inpaint and the blur take S0 in that frame as they did before there was a check; the check's own pass took it
        // between two frames of the window
        s0tex.scheduleUpdate();
        root._blurT = 0;
        if (root._armCoverLate) {
            root._hs.screenSettled(root._name);
            armCover.start();
        } else {
            root._s0Alpha = 1;
        }
        root._blurActive = true;
        root._warm = false;
        root._stillOn = true;
        // Until a frame with S0 is presented the surface is still clear: xray
        // goes off, the veil and the blur-in begin, only from there.
        root._afterSwaps(2, 0, root._covered);
    }

    Timer {
        id: armCover
        interval: 500
        onTriggered: root._s0Alpha = 1
    }

    // No S0 (every copy came out empty): never a black screen for the desktop. Nothing is
    // shown of a picture; xray stays on, so the veil rises over the LIVE desktop, and
    // xray goes off once the veil is up (it is opaque without a still). The unlock holds
    // and fades as ever.
    function _noS0(): void {
        root._fact("no S0: " + root._s0Empty + " copies came out empty; the veil rises over the live desktop");
        root._st = "settled";
        root._settled = true;
        root._warm = false;
        root._veilRise = true;
        root._xrayAfterVeil = true;
        root._xrayOffWhenUp();
    }
    // xray goes off once the veil is up (step 2 of the header; the no-S0 path the same).
    // With no veil to watch (a host that hands none), once the picture has settled.
    function _xrayOffWhenUp(): void {
        if (!root._xrayAfterVeil || root._unlocking)
            return;
        // qmllint disable missing-property
        // (`presence` is LockVeil's; veilHost is typed Item)
        const up = root.veilHost !== null ? root.veilHost.presence >= 0.97 : root._settled;
        // qmllint enable missing-property
        if (!up)
            return;
        root._xrayAfterVeil = false;
        root._fact("the veil is up: xray off");
        root._hs.screenSettled(root._name);
    }
    Connections {
        target: root.veilHost
        ignoreUnknownSignals: true
        function onPresenceChanged() {
            root._xrayOffWhenUp();
        }
    }

    function _covered(): void {
        if (root._unlocking)
            return;
        root._log("S0 on screen: veil rises, blur-in");
        root._fact("S0 on screen: veil rises, blur-in");
        if (!root._armVeilLate)
            root._veilRise = true;
        blurRamp.start();
        root._xrayAfterVeil = true;
        root._xrayOffWhenUp();
    }

    NumberAnimation {
        id: blurRamp
        target: root
        property: "_blurT"
        from: 0
        to: 1
        duration: Math.max(1, root._blurInMs)
        easing.type: Easing.InOutQuad
        onFinished: root._rampFinished()
    }

    function _rampFinished(): void {
        root._log("fully blurred");
        if (root._unlocking)
            return;
        // the copy takes the last frame of the ramp, then it rests
        root._afterSwaps(2, 0, root._settledNow);
    }

    function _settledNow(): void {
        if (root._unlocking)
            return;
        root._st = "settled";
        root._settled = true;
        if (root._armVeilLate)
            root._veilRise = true;
        root._log("settled");
        root._xrayOffWhenUp();
    }

    // ---- unlock -----------------------------------------------------------------------------------
    // The hold: nothing changes for unlockHoldMs (the veil's `ok` is playing over
    // the full veil); xray comes on shortly before the end, beneath the opaque
    // lock; then the lock fades. With no veil up there is nothing to admire.
    function _beginUnlock(): void {
        if (root._unlocking)
            return;
        root._unlocking = true;
        const prev = root._st;
        root._log("unlock from " + prev);
        s0Retry.stop();
        root._swapFn = null;
        swapGuard.stop();
        minTimer.stop();
        const hold = root._veilRise && !root._armNoHold ? Math.max(0, root._holdMs) : 0;
        if (hold <= 0) {
            // before the veil: the surface is clear or S0 is only just there; the
            // blur stops where it is
            blurRamp.stop();
            root._st = "unlocking";
            root._unlockSwitch();
            return;
        }
        root._st = "holding";
        prepTimer.interval = Math.max(1, hold - 150);
        prepTimer.restart();
        holdTimer.interval = hold;
        holdTimer.restart();
    }
    Timer {
        id: prepTimer
        onTriggered: {
            root._log("xray on beneath the lock");
            if (!root._armUnlockBare)
                root._hs.prepareUnlock();
        }
    }
    Timer {
        id: holdTimer
        onTriggered: root._unlockSwitch()
    }
    // the compositor's call returned and it has drawn a few frames of the sharp
    // desktop beneath the (still opaque) lock: the fade may start. A call that
    // never returns must not hold the unlock: 300 ms at most.
    property real _unlockAskedAt: 0
    function _unlockSwitch(): void {
        root._st = "unlocking";
        if (root._armUnlockBare) {
            fadeAnim.start();
            return;
        }
        root._hs.prepareUnlock();
        root._unlockAskedAt = Date.now();
        unlockGo.interval = 30;
        unlockGo.restart();
    }
    Timer {
        id: unlockGo
        onTriggered: {
            if (root._hs.busy && Date.now() - root._unlockAskedAt < 300) {
                unlockGo.interval = 20;
                unlockGo.restart();
                return;
            }
            root._log("fade starts");
            fadeAnim.start();
        }
    }
    NumberAnimation {
        id: fadeAnim
        target: root
        property: "_fade"
        from: 0
        to: 1
        duration: Math.max(1, root._unlockMs)
        easing.type: Easing.InOutQuad
        onFinished: {
            root._log("faded");
            root.unlockFaded();
        }
    }
}
