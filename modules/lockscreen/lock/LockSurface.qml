pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

import "../../common/components"
import "../../common/locale"
import "../../common/theme"
// The veils are loaded by URL, and a directory's own types resolve in them
// only while some import names the directory: without this line a veil's own
// types do not resolve ("SkyData is not a type") and the veil draws nothing.
// It also types `_veil` below.
import "../veil"
import "../../common/system"

// =============================================================================
// LockSurface.qml -- what covers ONE output while the session is locked.
//
// TRIVIALLY CREATABLE, ON PURPOSE. Quickshell UNLOCKS the session ("Aborting
// lock") when the surface component fails to create on a hotplugged output
// on a hotplugged output. So this root has no required property, and every
// piece that can fail -- the desktop layer, the veil, the fallback
// card and the popup inside it -- is in a Loader: a broken one is an empty
// Loader and a log line, never an unlocked session. `ctx` (LockRoot) is set by
// the surface Component; with it null the surface still covers the screen.
//
// From bottom to top:
//   DesktopLayer  the held desktop frame (S0), blur-in, the unlock hold + fade
//   LockVeil      the veil proposal over it (`still` = the layer's frame)
//   fallback card the lock's own clock + dots + face state, shown only while
//                 the shell's popup is not (see below)
//   a key sink    one Item with focus; every surface forwards keys to the ONE
//                 buffer in AuthController, so it does not matter which surface
//                 the compositor gives the keyboard to (it follows the pointer)
//
// THE FALLBACK. The shell draws the real popup over the lock (above_lock) and
// tells us which screens it shows it on (`shown`). This card exists for when it
// does not: no shell, a shell that has not connected yet, a shell that died, a
// screen the shell does not know. It appears when the shell has not reported
// this screen for fallbackDelayMs -- at BOOT for bootFallbackDelayMs (30 s: the
// shell starts seconds after the lock, and the user asked for the veil alone
// until it is there, never a card of the lock's own first) -- and at once on a
// failed attempt the shell's popup is not there to show. It stands where the
// shell's popup hangs (top centre), never detached in the middle of the screen.
// THE HAND-OVER: the card goes the moment the shell has connected and named its
// bar on this screen (its hints), which is before its popup is built and opens,
// so the two are never on screen together; a popup that does not follow within
// handoverGraceMs brings the card back. Keys go to the ONE buffer whatever shows
// (the key sink below): typed before any card or popup, they are in the dots the
// popup shows when it comes, and Return unlocks with nothing shown at all.
//
// THE FIRST FRAMES AT BOOT. The screen stays the tty's black until the veil's floor is on it, whole: before the lock
// asks, Hyprland's --locked-cmd black; while it asks, LockRoot's cover (THE COVER: Hyprland draws the workspace in that
// span); then this surface, opaque BLACK from its first frame until the veil has risen. That first frame is a bare one
// (the veil is built after `secure`, as on every lock), so the lock is secure one frame after it asks, whatever the
// veil's shaders cost to compile; the black holds while they do, and the rise starts only once the veil exists. A boot
// veil is opaque and draws its whole floor in its first frame (each veil's `opaque`): nothing is ever seen through it.
// =============================================================================
WlSessionLockSurface {
    id: root

    // LockRoot; null until set (see above).
    property var ctx: null
    readonly property string screenName: root.screen ? root.screen.name : ""
    // This surface's desktop layer has finished fading (or has none).
    property bool unlockDone: false
    // The compositor has given this surface the keyboard (Qt: the window is active). LockRoot counts the surfaces that
    // hold it -- KeyboardWatch asks for a new lock when none does -- and logs every change.
    readonly property bool keyboardActive: keySink.Window.active
    onScreenChanged: if (root.ctx) console.log("LARESLOCK fact surface: " + root.screenName + " is on its screen")
    onKeyboardActiveChanged: if (root.ctx) root.ctx.surfaceKeyboard(root.screenName, root.keyboardActive)

    // Opaque black at boot until the veil has risen (THE FIRST FRAMES AT BOOT); clear otherwise: a normal lock's first
    // frame shows the live desktop through it (THE FIRST FRAMES ARE BARE ONES, below), and an unlock fades to the desktop
    // beneath, long after the veil is up.
    color: root._boot && !root.veilUp ? "black" : "transparent"

    // ---- the desktop layer's answers ---------------------------------------------------
    readonly property var _desk: deskLoader.item
    readonly property LockVeil _veil: veilLoader.item as LockVeil
    readonly property bool _deskThere: deskLoader.status === Loader.Ready
    readonly property bool _boot: root.ctx ? root.ctx.lockState.boot : false
    // "Not loaded YET" is not a go: counting it as one would start the veil's rise
    // in the first frames of every lock, before the layer exists, and the rise
    // would run on to 1 over the desktop's blur-in. Only a
    // layer that FAILED to load lets the veil rise at once.
    //
    // THE SIGNAL: the layer's `veilRise` -- true the moment S0 is on screen and
    // the blur-in begins (the veil starts with it, nothing waits). A
    // layer without it (a probe's stub) falls back to `settled`.
    // A boot veil rises the moment it EXISTS (it is built after `secure`; until then the surface is the bare black): a
    // rise timed from anything earlier could run out before the veil had drawn, and the black go with nothing over it.
    readonly property bool _rises: {
        if (root._boot)
            return veilLoader.status === Loader.Ready || veilLoader.status === Loader.Error;
        if (deskLoader.status === Loader.Error)
            return true;
        if (!root._deskThere)
            return false;
        return typeof root._desk.veilRise !== "undefined" ? root._desk.veilRise === true : root._desk.settled === true;
    }

    // The veil rises 0 -> 1 over `veilRiseMs`, over the blur-in. One clock.
    property real _presence: 0
    NumberAnimation {
        id: rise
        target: root
        property: "_presence"
        to: 1
        duration: root.ctx ? root.ctx.config.veilRiseMs : 1600
        easing.type: Easing.OutCubic
    }
    on_RisesChanged: if (root._rises) rise.restart()
    // the veil has (all but) risen here: LockRoot says so once every surface has (LockState.veilAt)
    readonly property bool veilUp: root._presence >= 0.97
    onVeilUpChanged: if (root.veilUp && root.ctx) root.ctx.surfaceVeilUp()

    // ---- unlock ---------------------------------------------------------------------------
    property bool _unlocking: false
    function beginUnlock() {
        if (root._unlocking)
            return;
        root._unlocking = true;
        if (root._deskThere && typeof root._desk.beginUnlock === "function") {
            try {
                root._desk.beginUnlock();
            } catch (e) {
                console.log("lock: DesktopLayer.beginUnlock failed: " + e);
                root._finishUnlock();
            }
        } else {
            // no layer: nothing holds the unlock, but the desktop must be drawn
            // beneath the surface while it goes
            if (root.ctx)
                root.ctx._hypr("prepareUnlock");
            root._finishUnlock();
        }
    }
    function _finishUnlock() {
        if (root.unlockDone)
            return;
        root.unlockDone = true;
        if (root.ctx)
            root.ctx._maybeRelease();
    }
    Connections {
        target: root._deskThere ? root._desk : null
        ignoreUnknownSignals: true
        function onUnlockFaded() {
            root._finishUnlock();
        }
    }

    // THE FIRST FRAMES ARE BARE ONES. From the instant the lock asks for the session the compositor draws no layer that carries the above_lock rule until this surface
    // has a buffer, which is why the supervisor gives the bars that rule only once the lock is secure (tools/lockscreen/lares-lock, the header): until then they are
    // ordinary layers under xray, and this surface must stay CLEAR over them. What this window does in the span is its length: the desktop layer (a shader pyramid, a ScreencopyView) and the veil's whole scene, built
    // synchronously in the first frame, put `locked` 100-250 ms after the request (median 130, the test Hyprland);
    // a surface that builds nothing before it is locked gets it in ~45. Building them in the turn after a bare first frame does not do
    // it (the build shares the CPU with the compositor's frame that says `locked`: 90-280). So the surface commits a clear frame, stays
    // idle until `locked` has come (the lock's phase leaves "locking"), and then fills the two loaders (`_build`, one turn after the
    // phase change; a failsafe timer if `locked` never comes). What waits for them is the S0 capture and the veil; the desktop beneath shows through the clear surface in the meantime, as it does before S0 anyway.
    // A boot / relaunched lock waits the same way, for another reason: its first frame is the bare black, so Hyprland hears
    // it drawn one frame after the request (THE FIRST FRAMES AT BOOT); a veil built into that frame made the span as long as
    // the veil's cold compile -- over a second nested, where Hyprland's lockdead screen came up in it. A surface that
    // appears when the session is locked already (a hotplugged output) builds at once.
    property bool _built: false
    function _build(): void {
        if (root._built || !root.ctx)
            return;
        root._built = true;
        const c = root.ctx;
        deskLoader.setSource("DesktopLayer.qml", {
            "screen": root.screen,
            "boot": root._boot,
            "lockState": c.lockState,
            "config": c.config,
            "hints": c.link.hints[root.screenName] ? c.link.hints[root.screenName] : [],
            "shellAt": c.link.activeAt,
            "veilHost": null,
            "hypr": c.hyprSettings
        });
        veilLoader.setSource(Qt.resolvedUrl("../veil/LockVeil.qml"), {
            "proposal": c.veilName,
            "opaque": root._boot,
            "presence": 0,
            "awake": true,
            "fps": c.awake.fps
        });
    }
    readonly property bool _lockedNow: root.ctx ? root.ctx.lockState.phase !== "locking" : false
    on_LockedNowChanged: if (root._lockedNow) Qt.callLater(root._build)
    Timer {
        id: buildFailsafe
        interval: 400
        onTriggered: root._build()
    }

    Component.onCompleted: {
        if (root.ctx)
            root.ctx.registerSurface(root);
        if (root.ctx) {
            if (root._lockedNow)
                root._build();
            else
                buildFailsafe.start();
        }
        if (!root._reported)
            fallbackDelay.start();
    }
    Component.onDestruction: {
        if (root.ctx)
            root.ctx.unregisterSurface(root);
    }

    // ---- layers --------------------------------------------------------------------------
    Item {
        id: stage
        anchors.fill: parent

        Loader {
            id: deskLoader
            anchors.fill: parent
            // built after `locked` (see `_build`), in slices between frames: a cold compile of the layer holds the thread for a second
            asynchronous: !root._boot
        }
        // The surface's screen arrives after its Component.onCompleted (the
        // initial property was null there): without this the layer's captures
        // have no source and fail ("no recording context"), and it settles
        // on black.
        Binding {
            target: deskLoader.item
            property: "screen"
            value: root.screen
            when: root._deskThere
            restoreMode: Binding.RestoreNone
        }
        Binding {
            target: deskLoader.item
            property: "hints"
            value: root.ctx && root.ctx.link.hints[root.screenName] ? root.ctx.link.hints[root.screenName] : []
            when: root._deskThere
            restoreMode: Binding.RestoreNone
        }
        Binding {
            target: deskLoader.item
            property: "shellAt"
            value: root.ctx ? root.ctx.link.activeAt : 0
            when: root._deskThere
            restoreMode: Binding.RestoreNone
        }
        Binding {
            target: deskLoader.item
            property: "veilHost"
            value: veilLoader.item
            when: root._deskThere
            restoreMode: Binding.RestoreNone
        }

        Loader {
            id: veilLoader
            anchors.fill: parent
            asynchronous: !root._boot
            // The unlock fade takes the veil out with the lock.
            opacity: root._deskThere && root._desk.fadeOut !== undefined ? 1 - root._desk.fadeOut : 1
        }
        Binding {
            target: veilLoader.item
            property: "still"
            value: root._deskThere ? root._desk.still : null
            when: veilLoader.status === Loader.Ready
            restoreMode: Binding.RestoreNone
        }
        Binding {
            target: veilLoader.item
            property: "presence"
            value: root._presence
            when: veilLoader.status === Loader.Ready
            restoreMode: Binding.RestoreNone
        }
        Binding {
            target: veilLoader.item
            property: "awake"
            value: root.ctx ? root.ctx.awake.awake : true
            when: veilLoader.status === Loader.Ready
            restoreMode: Binding.RestoreNone
        }
        Binding {
            target: veilLoader.item
            property: "fps"
            value: root.ctx ? root.ctx.awake.fps : 60
            when: veilLoader.status === Loader.Ready
            restoreMode: Binding.RestoreNone
        }
        Binding {
            target: veilLoader.item
            property: "popupRect"
            // The shell's popup when it has one here, else the fallback card
            // while that shows: a veil that wraps the popup (the
            // gooey union) would wrap the stage silhouette's stand-in geometry
            // at boot, beside the real card.
            value: root._parts.popup.width > 0 ? root._parts.popup
                 : root._unlocking && root._lastPopup.width > 0 ? root._goneRect
                 : (root._fallbackShown && fallbackLoader.item
                    ? Qt.rect(fallbackLoader.x, fallbackLoader.y, fallbackLoader.width, fallbackLoader.height)
                    : Qt.rect(0, 0, 0, 0))
            when: veilLoader.status === Loader.Ready
            restoreMode: Binding.RestoreNone
        }
        Binding {
            target: veilLoader.item
            property: "barRect"
            value: root._parts.bar
            when: veilLoader.status === Loader.Ready
            restoreMode: Binding.RestoreNone
        }
        Binding {
            target: veilLoader.item
            property: "renderScale"
            value: stage.Screen.devicePixelRatio
            when: veilLoader.status === Loader.Ready
            restoreMode: Binding.RestoreNone
        }
        Binding {
            target: veilLoader.item
            property: "pointer"
            value: hover.hovered ? ({
                    "x": hover.point.position.x,
                    "y": hover.point.position.y
                }) : null
            when: veilLoader.status === Loader.Ready
            restoreMode: Binding.RestoreNone
        }
        Connections {
            target: root.ctx
            ignoreUnknownSignals: true
            function onPulse(kind) {
                const v = root._veil;
                if (!v || typeof v.pulse !== "function")
                    return;
                // From the password field, where the user's hands are in the
                // picture; the veil's centre only when nothing says where it is.
                const o = root._fieldOrigin();
                if (o)
                    v.pulse(kind, o.x, o.y);
                else
                    v.pulse(kind);
            }
        }

        HoverHandler {
            id: hover
            // The shell's layers are not interactive, so the lock hears the
            // pointer. `pointChanged` also fires when the scene moves under a RESTING
            // pointer (Qt re-delivers a synthetic hover every frame the veil
            // draws), so only a changed position counts as input: otherwise a
            // pointer left on the lock keeps it awake for ever, and the veil that
            // never rests keeps the frames coming.
            onPointChanged: {
                const p = hover.point.position;
                if (p.x !== root._lastX || p.y !== root._lastY) {
                    root._lastX = p.x;
                    root._lastY = p.y;
                    if (root.ctx)
                        root.ctx.pointerMoved();
                }
            }
        }

        // ---- the fallback card -----------------------------------------------------------------
        // Where the shell's popup hangs: the place it had this lock, else from the top centre at the foot of where a
        // 40 px bar would be.
        Loader {
            id: fallbackLoader
            active: root._fallbackShown
            x: Math.round((parent.width - fallbackLoader.width) / 2)
            y: root._lastPopup.width > 0 ? Math.round(root._lastPopup.y) : 40
            // it goes with the veil in the unlock fade
            opacity: veilLoader.opacity
            sourceComponent: fallbackCard
        }
    }

    // ---- where the field is ------------------------------------------------
    // The shell's `targets` for this screen when it has sent them; else the
    // fallback card's own popup; else (pulses only) an estimate from the popup's
    // rect. All as {x, y, w, h} in this surface's coordinates, or null.
    function _asRect(a) {
        return a ? { "x": a[0], "y": a[1], "w": a[2], "h": a[3] } : null;
    }
    // The popup inside the fallback card while that shows (the card sets it).
    property var _fallbackPopup: null
    function _fallbackRect() {
        const pop = root._fallbackPopup;
        const r = pop ? pop.fieldRect : null;
        if (!r)
            return null;
        const p = pop.mapToItem(stage, r[0], r[1]);
        return { "x": p.x, "y": p.y, "w": r[2], "h": r[3] };
    }
    // The shell's popup, when it reports this screen, owns the answer: the
    // fallback card is hidden then, and a stale rect must not outlive it.
    function _fieldTarget() {
        const t = root.ctx ? root.ctx.link.targets[root.screenName] : undefined;
        if (t && root._reported)
            return root._asRect(t.field);
        return root._fallbackRect();
    }
    function _fieldOrigin() {
        const f = root._fieldTarget();
        if (f && f.w > 0)
            return { "x": f.x + f.w / 2, "y": f.y + f.h / 2 };
        const p = root._parts.popup;
        if (p.width > 0)
            return { "x": p.x + p.width / 2, "y": p.y + 0.6 * p.height };
        return null;
    }
    property real _lastX: -1
    property real _lastY: -1

    // THE POPUP HAS GONE (the unlock). The shell's hints follow its retract down to
    // nothing and then say no popup at all -- and a veil reads "no popup rect" as
    // "draw the stage's default stone" (gooey's slab) for the rest
    // of the hold and the fade. So once the popup has been seen and the unlock is
    // under way, a vanished popup is a rect of no height and one pixel of width at
    // the bar's foot where it was: nothing to draw, but still "a rect".
    property rect _lastPopup: Qt.rect(0, 0, 0, 0)
    on_PartsChanged: {
        if (root._parts.popup.width > 0)
            root._lastPopup = root._parts.popup;
    }
    readonly property rect _goneRect: Qt.rect(root._lastPopup.x + root._lastPopup.width / 2 - 0.5, root._lastPopup.y, 1, 0)

    // The shell's hints for this screen, split for the veil: the bar and the popup, both zero rects while the shell has said
    // nothing. A shell that NAMES them is taken at its word (the assembled shell's islands are no full-edge strips, and a
    // retracting popup grows smaller than an island); one that does not is guessed: the bar a thin rect along a full edge,
    // the popup the largest rect that is not the bar.
    readonly property var _parts: {
        const rects = root.ctx && root.ctx.link.hints[root.screenName] ? root.ctx.link.hints[root.screenName] : [];
        const named = root.ctx && root.ctx.link.hintParts[root.screenName] ? root.ctx.link.hintParts[root.screenName] : null;
        if (named) {
            const b = named.bar, p = named.popup;
            return {
                "bar": b ? Qt.rect(b[0], b[1], b[2], b[3]) : Qt.rect(0, 0, 0, 0),
                "popup": p ? Qt.rect(p[0], p[1], p[2], p[3]) : Qt.rect(0, 0, 0, 0)
            };
        }
        const w = root.width, h = root.height;
        let bar = null, popup = null;
        for (const r of rects) {
            const isBar = (r[2] >= 0.8 * w && r[3] <= 0.2 * h) || (r[3] >= 0.8 * h && r[2] <= 0.2 * w);
            if (isBar) {
                if (!bar || r[2] * r[3] > bar[2] * bar[3])
                    bar = r;
            } else if (!popup || r[2] * r[3] > popup[2] * popup[3]) {
                popup = r;
            }
        }
        return {
            "bar": bar ? Qt.rect(bar[0], bar[1], bar[2], bar[3]) : Qt.rect(0, 0, 0, 0),
            "popup": popup ? Qt.rect(popup[0], popup[1], popup[2], popup[3]) : Qt.rect(0, 0, 0, 0)
        };
    }

    // ---- when the fallback shows (THE FALLBACK, THE HAND-OVER) ----------------------------------------------------------
    readonly property bool _reported: root.ctx ? (root.ctx.link.connected && root.ctx.link.shownScreens.indexOf(root.screenName) >= 0) : false
    // The shell is connected and has named its bar on this screen: its popup is on its way.
    readonly property bool _shellComing: {
        if (!root.ctx || !root.ctx.link.connected)
            return false;
        const n = root.ctx.link.hintParts[root.screenName];
        return !!n && !!n.bar;
    }
    // The wait is over (or a failed attempt cut it short) and the shell has not shown its popup since.
    property bool _due: false
    // The shell came and its popup did not follow within handoverGraceMs.
    property bool _handoverLate: false
    readonly property bool _fallbackShown: root._due && !root._reported && (!root._shellComing || root._handoverLate)
    // A boot lock (not a relaunch: a shell is running behind one) waits for the shell's start.
    readonly property int _waitMs: root.ctx ? (root.ctx.lockState.boot && !root.ctx.relaunch ? root.ctx.config.bootFallbackDelayMs : root.ctx.config.fallbackDelayMs) : 2000
    on_FallbackShownChanged: console.log("LARESLOCK fallback " + root.screenName + " " + (root._fallbackShown ? "shown" : "hidden") + " at " + Date.now())
    on_ReportedChanged: {
        if (root._reported) {
            fallbackDelay.stop();
            handoverGrace.stop();
            root._due = false;
            root._handoverLate = false;
        } else {
            fallbackDelay.restart();
            // a shell that is still here and lost its popup gets the grace again, not for ever
            if (root._shellComing)
                handoverGrace.restart();
        }
    }
    on_ShellComingChanged: {
        root._handoverLate = false;
        if (root._shellComing && !root._reported)
            handoverGrace.restart();
        else
            handoverGrace.stop();
    }
    Timer {
        id: fallbackDelay
        interval: root._waitMs
        onTriggered: root._due = !root._reported
    }
    Timer {
        id: handoverGrace
        interval: root.ctx ? root.ctx.config.handoverGraceMs : 3000
        onTriggered: root._handoverLate = !root._reported
    }
    // A failed attempt with no popup to say so: the card comes at once (the user is typing blind).
    Connections {
        target: root.ctx ? root.ctx.lockState : null
        function onAuthChanged() {
            if (root.ctx.lockState.auth === "failed" && !root._reported && !root._due) {
                fallbackDelay.stop();
                root._due = true;
            }
        }
    }

    Component {
        id: fallbackCard
        ShadowBox {
            id: card
            readonly property var _popup: popupLoader.item
            baseWidth: card._popup ? card._popup.implicitWidth + 24 : 360
            baseHeight: card._popup ? card._popup.implicitHeight + 24 : 200
            baseRadius: 14
            raised: true
            shadowToAlpha: true
            surfaceColor: Theme.surface
            backgroundColor: Theme.surface
            bevelColor: Theme.buttonBevel
            shadowColor: Theme.border
            bevelWidth: 1.5
            shadowWidth: 5
            opacity: 0
            Binding {
                target: root
                property: "_fallbackPopup"
                value: card._popup
            }
            NumberAnimation {
                target: card
                property: "opacity"
                to: 1
                duration: 160
                running: true
            }

            // The popup's time and date formats.
            LocaleConfig {
                id: locale
            }

            // The battery cell of the popup: read here, only while the fallback is shown.
            BatteryData {
                id: battery
                polling: true
            }

            Loader {
                id: popupLoader
                x: 12
                y: 12
                Component.onCompleted: {
                    if (root.ctx) {
                        popupLoader.setSource("../popup/LockPopup.qml", {
                            "fallback": true,
                            "lockState": root.ctx.lockState,
                            "battery": battery,
                            "locale": locale,
                            "greetingName": root.ctx.config.greetingName,
                            "greets": root.ctx.config.greeting,
                            "bandOrder": root.ctx.config.popupBand
                        });
                    }
                }
            }
            // The lock's own minimal card, while there is no popup to host.
            Loader {
                active: popupLoader.status !== Loader.Ready
                anchors.fill: parent
                sourceComponent: minimalCard
            }
        }
    }

    Component {
        id: minimalCard
        Item {
            id: mini
            readonly property var st: root.ctx ? root.ctx.lockState : null
            property date now: new Date()
            Timer {
                interval: 1000
                repeat: true
                running: true
                onTriggered: mini.now = new Date()
            }
            Text {
                id: clock
                anchors.horizontalCenter: parent.horizontalCenter
                y: 22
                text: Qt.formatTime(mini.now, "hh:mm")
                color: Theme.textPrimary
                font.pixelSize: 54
                font.bold: true
            }
            Row {
                id: dots
                anchors.horizontalCenter: parent.horizontalCenter
                y: 104
                height: 14
                spacing: 8
                Repeater {
                    model: Math.min(24, mini.st ? mini.st.dots : 0)
                    Rectangle {
                        width: 12
                        height: 12
                        radius: 6
                        color: mini.st && mini.st.auth === "failed" ? Theme.error : Theme.accent
                    }
                }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                y: 140
                color: Theme.textMuted
                font.pixelSize: 12
                text: {
                    const s = mini.st;
                    if (!s)
                        return "";
                    if (s.auth === "checking")
                        return "checking";
                    if (s.auth === "failed")
                        return "wrong password";
                    switch (s.face) {
                    case "absent":
                        return s.faceReason === "keyring" ? "password once after a restart, it opens your keyring" : "type your password";
                    case "scanning":
                        return "looking for your face";
                    case "failed":
                        return "face not recognised";
                    case "dark":
                        return "too dark to see you";
                    case "busy":
                        return "camera busy";
                    case "unavailable":
                        return "face unlock unavailable";
                    case "misconfigured":
                        return "face unlock misconfigured";
                    }
                    return "type your password";
                }
            }
        }
    }

    // ---- keys ------------------------------------------------------------------------------
    Item {
        id: keySink
        anchors.fill: parent
        focus: true
        Keys.onPressed: event => {
            if (root.ctx)
                root.ctx.keyPressed(event);
            event.accepted = true;
        }
        Keys.onReleased: event => {
            if (root.ctx)
                root.ctx.keyReleased(event);
            event.accepted = true;
        }
    }
}
