pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

import "../"
import "../../common/system"
import "VeilBag.js" as VeilBag

// =============================================================================
// LockRoot.qml -- the lock process: one WlSessionLock, its surfaces, and the
// objects that decide when it may open (contract sections 2-6).
//
// WHAT MAKES IT SAFE:
//  - `locked: true` is a literal. Nothing binds it to anything that can be
//    false before authentication succeeded.
//  - The ONE place `locked` is written false is _release(), reached only from
//    the unlock sequence that AuthController.succeeded starts.
//  - Nothing the shell says (ShellLink) starts, skips or shortens that
//    sequence beyond the 600 ms floor; the whole thing is capped at 800 ms.
//  - The surface component (LockSurface) is trivially creatable: Quickshell
//    UNLOCKS the session if it fails to create on a hotplugged output.
//  - The lock does not reload (settings.watchFiles false in shell.qml).
//
// THE ORDER of a lock: HyprSettings.prepareLock() first (a normal lock wants
// the live desktop showing through a clear surface for its first frame:
// session_lock_xray on), then the WlSessionLock once that call has returned
// (HyprSettings.applied; a LazyLoader gate, at most 400 ms after it). At `secure` the
// state becomes "locked", `LARESLOCK secure` is printed for the supervisor and the
// face scan may start.
//
// THE COVER (a boot, a relaunched or a replaced lock: `boot`). From a locker's request until its surface has drawn on
// every output, Hyprland draws the session's WORKSPACE under it -- the wallpaper at a boot, the live desktop behind a
// relaunch -- and a compositor busy with its own start draws frames in that span (the user filmed 3-7 of the wallpaper at
// every boot). So such a lock first maps BootCover (an opaque black layer on every output) and asks only once Hyprland has
// MAPPED every cover (lists it: a swapped frame waits for its GPU fence before it is applied) -- 500 ms at most: the lock
// comes whatever happens to the cover; the workspace drawn in that span is the cover's black. At `secure` the workspace is no longer drawn and the cover goes. The surface's own first frame is a bare
// black one (LockSurface builds the veil after `secure`), so the span is one frame long, far inside Hyprland's
// lockdead_screen_delay, however long the veil's shaders take to compile.
//
// THE UNLOCK: AuthController.succeeded -> phase "unlocking" (the shell hears
// it and retracts its popup), HyprSettings.prepareUnlock(), every surface's
// DesktopLayer begins fading to the live desktop; the session is released when
// the shell says `retracted` OR 600 ms have passed (whichever first) AND every
// layer has faded, but never later than 800 ms after the win. Then
// `locked = false`, `LARESLOCK unlocked`, `bye`, and the process quits 200 ms
// later: an unlock_and_destroy that is not flushed leaves the session lockdead.
// =============================================================================
Scope {
    id: root

    readonly property bool boot: Quickshell.env("LARES_LOCK_BOOT") === "1"
    // The supervisor's second launch (the first lock died). Its desktop is the
    // lockdead screen, so it is a boot for the VEIL (`boot`), but the user may
    // well be sitting there: for the FACE it is a deliberate lock.
    readonly property bool relaunch: Quickshell.env("LARES_LOCK_RELAUNCH") === "1"
    // THE KEYBOARD RE-KEY (KeyboardWatch): the supervisor's LARES_LOCK_REKEY is the number of locks it has already replaced
    // because none held the keyboard ("0": none), or "off" once it has given up asking.
    readonly property string rekeyEnv: Quickshell.env("LARES_LOCK_REKEY") || "0"
    readonly property bool rekeyed: root.rekeyEnv !== "0" && root.rekeyEnv !== "off"
    // The face may scan at once only when nobody chose this lock (a boot) -- or when this lock replaces one that had no
    // keyboard, which is what the machine coming back from sleep does: whoever is there now is not who locked it.
    readonly property bool faceAtStart: (root.boot && !root.relaunch) || root.rekeyed
    // THE REPLACEMENT, PRE-STARTED (tools/lockscreen/lares-lock): LARES_LOCK_AFTER is the pid of the lock this one takes over from. It loads
    // everything, says `LARESLOCK ready`, and asks for the session lock only when that process is gone, so the compositor's lockdead
    // screen is up for the time it takes to ask and draw -- not for a whole start of Quickshell (0.5 s here, 1.1 s on the user's machine).
    readonly property int afterPid: parseInt(Quickshell.env("LARES_LOCK_AFTER") || "0")
    // This lock's veil (LockConfig.pickVeil), chosen once in Component.onCompleted.
    property string veilName: "relief"

    readonly property alias lockState: stateObj
    readonly property alias config: configObj
    readonly property alias auth: authObj
    readonly property alias link: linkObj
    readonly property alias awake: awakeObj
    readonly property alias keys: keysObj
    // HyprSettings' one instance per lock (null when the file is absent); every
    // DesktopLayer is handed it.
    readonly property var hyprSettings: hyprObj.item

    // Surfaces register here; a surface may appear at any time (hotplug).
    property var surfaces: []
    // Pulses the veils answer with: "key", "fail", "ok", "wake".
    signal pulse(string kind)

    // surface (screen name) -> holds the keyboard, and how many do (KeyboardWatch asks)
    property var _kbd: ({})
    property int kbdHolders: 0
    property bool _unlocking: false
    property bool _released: false
    property bool _retracted: false
    property bool _floorPassed: false
    property real _wonAt: 0

    LockState {
        id: stateObj
        boot: root.boot
        caps: keysObj.caps
        awake: awakeObj.awake
    }
    LockConfig {
        id: configObj
    }
    AwakeClock {
        id: awakeObj
        idleSeconds: configObj.idleSeconds
        baseFps: configObj.fps
        batteryFpsRatio: configObj.batteryFpsRatio
        onWoke: root.pulse("wake")
    }
    LockKeys {
        id: keysObj
    }
    FaceAvailability {
        id: faceAvail
        mode: configObj.face
        keyringPassword: configObj.keyringPassword
        bootFallback: root.boot && !root.relaunch
    }
    AuthController {
        id: authObj
        lockState: stateObj
        awake: awakeObj
        faceAvailability: faceAvail.face
        faceReason: faceAvail.reason
        howdyWorkaround: faceAvail.howdyWorkaround
        howdyTimeoutMs: faceAvail.howdyTimeoutMs
        faceRearmCooldownMs: configObj.faceRearmCooldownMs
        faceAtStart: root.faceAtStart && configObj.faceWhen.indexOf("boot") >= 0
        faceOnReturn: configObj.faceWhen.indexOf("return") >= 0
        secure: root.secure
        onSucceeded: root._unlockSequence()
    }
    // The machine came back from sleep: the face may look again.
    Connections {
        target: Sleep.watcher
        function onAboutToSleep() {
            console.log("LARESLOCK fact sleep: the machine is going to sleep");
        }
        function onResumed() {
            console.log("LARESLOCK fact sleep: the machine resumed (" + root.kbdHolders + " surface(s) hold the keyboard)");
            if (configObj.faceWhen.indexOf("resume") >= 0)
                authObj.resumed();
            kbdWatch.resumed();
        }
    }
    // THE KEYBOARD (see KeyboardWatch): when no surface holds it, a new lock gets it back.
    KeyboardWatch {
        id: kbdWatch
        enabled: root.rekeyEnv !== "off"
        hopEnabled: Quickshell.env("LARES_LOCK_HOP") !== "off"
        hopCommand: [RepoRoot.dir + "/tools/lockscreen/lares-lock-hop"]
        surfaceNames: root.surfaces.map(s => s.screenName)
        holders: root.kbdHolders
        phase: stateObj.phase
        onNote: text => console.log("LARESLOCK fact keyboard: " + text)
        onRekey: why => root._rekey(why)
    }
    // Outputs coming and going while locked: a surface for each is the compositor's and Quickshell's business, the log is ours.
    Connections {
        target: Quickshell
        function onScreensChanged() {
            const names = [];
            for (const s of Quickshell.screens)
                names.push(s.name);
            console.log("LARESLOCK fact screens: " + names.join(","));
        }
    }
    // The veil bag (VeilBag.js): which veils are still to come in this round and which one the last lock showed, kept across locks, restarts
    // of the lock and of the shell. Read once; the directory may not exist yet (a first lock), and the write makes it.
    FileView {
        id: veilBagFile
        path: root._stateDir + "/veil-bag.json"
        blockLoading: true
        printErrors: false
    }
    readonly property string _stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/lares/lock"
    Process {
        id: veilBagWrite
        property string text: ""
        command: ["sh", "-c", "mkdir -p \"$1\" && printf %s \"$2\" > \"$1/veil-bag.json.tmp\" && mv \"$1/veil-bag.json.tmp\" \"$1/veil-bag.json\"", "sh", root._stateDir, veilBagWrite.text]
    }
    function _chooseVeil() {
        let bag = VeilBag.empty();
        try {
            bag = VeilBag.parse(veilBagFile.text());
        } catch (e) {}
        const last = bag.last;
        const pick = configObj.pickVeil(bag, Math.random);
        root.veilName = pick.name;
        console.log("LARESLOCK veil " + root.veilName + " (previous '" + last + "') still to come: " + pick.state.remaining.join(","));
        veilBagWrite.text = VeilBag.serialize(pick.state);
        veilBagWrite.running = true;
    }
    ShellLink {
        id: linkObj
        lockState: stateObj
        onRetracted: {
            root._retracted = true;
            root._maybeRelease();
        }
    }
    // Hyprland's own settings while locked. A direct instance:
    // behind a LazyLoader its item does not exist yet when Component.onCompleted
    // calls prepareLock(), the call is skipped, xray never comes on, and the
    // lock captures and settles on BLACK. If the
    // file were missing the lock would not load at all, and the supervisor's
    // relaunch / hyprlock fallback takes over -- which is the right failure.
    HyprSettings {
        id: hyprInst
    }
    QtObject {
        id: hyprObj
        readonly property var item: hyprInst
    }

    // ---- THE COVER (see the header) --------------------------------------------------
    // gone at `secure`; never made for a normal lock (its first frame IS the desktop, on purpose)
    property bool _coverDone: false
    on_CoverDoneChanged: if (root._coverDone && root.boot) console.log("LARESLOCK fact cover: gone")
    // the cover's failsafe ran out: the lock asks without it
    property bool _coverWaited: false
    readonly property bool _coverUp: coverGate.item ? coverGate.item.ready === true : false
    LazyLoader {
        id: coverGate
        active: root.boot && !root._coverDone
        BootCover {}
    }
    Timer {
        id: coverWait
        interval: 500
        onTriggered: root._coverWaited = true
    }

    // ---- the lock itself -----------------------------------------------------------
    readonly property var lock: lockGate.item
    readonly property bool secure: root.lock ? root.lock.secure : false

    LazyLoader {
        id: lockGate
        active: false
        WlSessionLock {
            locked: true
            onSecureChanged: root._onSecure()
            surface: Component {
                LockSurface {
                    ctx: root
                }
            }
        }
    }
    // WlSessionLock appears once Hyprland's settings are prepared: a normal lock asks when prepareLock's call has RETURNED
    // (xray on). Asked before that, Hyprland draws the surface's clear first frames over NOTHING -- black for as long as the
    // call takes; 40 ms blind was too short for a busy compositor (tools/dev/sleep_lockenv_film.sh ARM=slowxray). lockDelay is
    // the failsafe: a call that does not return does not hold the lock.
    readonly property int _prepareCapMs: 400
    property real _preparedAt: 0
    Timer {
        id: lockDelay
        interval: 400
        onTriggered: root._askLock(false)
    }
    Connections {
        target: hyprInst
        function onApplied(name: string, reply: string) {
            if (name === "prepareLock" && root._asked && !root.boot)
                root._askLock(true);
        }
    }
    function _askLock(applied: bool): void {
        if (lockGate.active)
            return;
        lockDelay.stop();
        if (!root.boot)
            console.log("LARESLOCK fact xray: " + (applied ? "on" : "NOT on") + " after " + Math.round(Date.now() - root._preparedAt) + " ms" + (applied ? "; asking" : ": asking without it"));
        lockGate.active = true;
    }
    Process {
        id: afterWait
        command: ["sh", "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.01; done", "sh", String(root.afterPid)]
        onExited: {
            console.log("LARESLOCK fact after: lock " + root.afterPid + " is gone");
            root._afterGone = true;
        }
    }

    // THE REQUEST: once the lock this one replaces is gone (a pre-started replacement) and, for a boot, the cover is up.
    property bool _afterGone: root.afterPid <= 0
    property bool _asked: false
    readonly property bool _mayAsk: root._afterGone && (!root.boot || root._coverUp || root._coverWaited)
    on_MayAskChanged: root._maybeAsk()
    function _maybeAsk(): void {
        if (root._asked || !root._mayAsk)
            return;
        root._asked = true;
        coverWait.stop();
        if (root.boot) {
            const c = coverGate.item;
            console.log("LARESLOCK fact cover: " + (root._coverUp ? "up (its frame " + Math.round(c.swappedMs) + " ms, mapped " + Math.round(c.mappedMs) + " ms after it was made)"
                                                               : "NOT up after " + coverWait.interval + " ms: asking without it"));
        }
        root._preparedAt = Date.now();
        root._hypr("prepareLock", root.boot);
        // (a boot lock's prepareLock changes nothing in Hyprland: nothing to wait for)
        lockDelay.interval = root.boot ? 1 : root._prepareCapMs;
        lockDelay.start();
    }

    // A call into HyprSettings, if it is there. Whatever it does or
    // throws, the lock's own sequence goes on.
    function _hypr(name, arg) {
        try {
            const h = hyprObj.item;
            if (h && typeof h[name] === "function")
                h[name](arg);
        } catch (e) {
            console.log("lock: HyprSettings." + name + " failed: " + e);
        }
    }

    // THE SHELL IS OVER THE LOCK AND KNOWS IT: connected, in the locked phase, and its popup shown on every surface's screen (`shown` is
    // sent once the shell has taken its locked input region). The supervisor reads `LARESLOCK shell on|off` and makes the `lares-bar` layer
    // INTERACTIVE above the lock (above_lock 2) only then -- the idle reel, the volume wheel and the player's buttons need the pointer --
    // and not interactive (1) in every other moment, so a shell that is not lock-aware can never be clicked over a locked screen.
    readonly property bool shellOver: root.link.connected && stateObj.phase === "locked" && root.surfaces.length > 0
        && root.surfaces.every(s => root.link.shownScreens.indexOf(s.screenName) >= 0)
    onShellOverChanged: console.log("LARESLOCK shell " + (root.shellOver ? "on" : "off"))

    function _onSecure() {
        if (!root.lock || !root.lock.secure || stateObj.phase !== "locking")
            return;
        stateObj.lockedAt = Date.now();
        stateObj.veilAt = 0;
        stateObj.phase = "locked";
        console.log("LARESLOCK secure");
        // Hyprland has drawn the lock on every output and draws no workspace from now on: the cover is not seen again
        root._coverDone = true;
    }

    // ---- input from the surfaces --------------------------------------------------------
    function keyPressed(event) {
        // KeyboardWatch's probe key: it only says the keys arrive. It is not input (no poke, no password, no pulse).
        if (event.key === Qt.Key_F24 && kbdWatch.probing) {
            kbdWatch.heard();
            return;
        }
        awakeObj.poke();
        keysObj.keyPressed(event.key);
        authObj.handleKey(event);
        if (event.text !== "" && event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter)
            root.pulse("key");
    }
    function keyReleased(event) {
        keysObj.keyReleased(event.key);
    }
    function pointerMoved() {
        awakeObj.poke();
    }

    // A surface heard the compositor give or take the keyboard (Qt: the window became active / inactive).
    function surfaceKeyboard(name, active) {
        const was = root._kbd[name] === true;
        if (was === active)
            return;
        const k = Object.assign({}, root._kbd);
        if (active)
            k[name] = true;
        else
            delete k[name];
        root._kbd = k;
        root.kbdHolders = Object.keys(k).length;
        console.log("LARESLOCK fact keyboard: " + (active ? "enter " : "leave ") + name + " (" + root.kbdHolders + " of " + root.surfaces.length + " surface(s) hold it)");
    }

    // Replace this lock with a new one, which the compositor hands the keyboard to. The session stays locked (the process
    // goes, the lock object with it, and Hyprland keeps the session locked: it is lockdead until the supervisor's next lock
    // takes over). Nothing here unlocks; nothing here runs during or after an unlock.
    function _rekey(why) {
        if (root._unlocking || root._released || rekeyQuit.running)
            return;
        console.log("LARESLOCK rekey " + why);
        rekeyQuit.start();
    }
    Timer {
        id: rekeyQuit
        // The supervisor starts the replacement and ends this process (SIGTERM) when it is ready; this is the end if it never
        // does (the log line is out long before).
        interval: 4000
        onTriggered: Qt.quit()
    }

    function surfaceVeilUp() {
        if (stateObj.veilAt > 0 || !root.surfaces.every(s => s.veilUp))
            return;
        stateObj.veilAt = Date.now();
        console.log("LARESLOCK veil up");
    }
    function registerSurface(s) {
        console.log("LARESLOCK fact surface: registered (" + (root.surfaces.length + 1) + " surface(s))");
        if (root.surfaces.indexOf(s) < 0)
            root.surfaces = root.surfaces.concat([s]);
        if (root._unlocking)
            s.beginUnlock();
    }
    function unregisterSurface(s) {
        console.log("LARESLOCK fact surface: " + s.screenName + " gone");
        root.surfaceKeyboard(s.screenName, false);
        root.surfaces = root.surfaces.filter(x => x !== s);
        root._maybeRelease();
    }

    Connections {
        target: stateObj
        function onAuthChanged() {
            if (stateObj.auth === "failed")
                root.pulse("fail");
            else if (stateObj.auth === "ok")
                root.pulse("ok");
        }
    }

    // ---- the unlock sequence (the only path to _release) -----------------------------------
    function _unlockSequence() {
        if (root._unlocking)
            return;
        root._unlocking = true;
        root._wonAt = Date.now();
        stateObj.phase = "unlocking";
        // Timers first: nothing optional below may keep the release from coming.
        floor.start();
        cap.start();
        // (xray comes on in each DesktopLayer, shortly before its fade: beneath a
        // lock that is still opaque. A surface with no layer asks for it itself.)
        for (const s of root.surfaces) {
            try {
                s.beginUnlock();
            } catch (e) {
                console.log("lock: surface beginUnlock failed: " + e);
            }
        }
    }
    function _facesDone() {
        return root.surfaces.every(s => s.unlockDone);
    }
    function _maybeRelease() {
        if (!root._unlocking || root._released)
            return;
        if ((root._retracted || root._floorPassed) && root._facesDone())
            root._release(root._retracted ? "retracted" : "floor");
    }
    Timer {
        id: floor
        // the hold: the earliest the release may come (the faces are not done before)
        interval: configObj.unlockHoldMs
        onTriggered: {
            root._floorPassed = true;
            root._maybeRelease();
        }
    }
    Timer {
        id: cap
        // THE FAIL-SAFE: the hold, the fade and a margin. Whatever stalls (a
        // layer that never fades, a call that never returns), the session is
        // released by then.
        interval: configObj.unlockHoldMs + configObj.unlockMs + 400
        onTriggered: root._release("cap")
    }
    // `why` (retracted | floor | cap) is only for the log and the probes.
    function _release(why) {
        if (root._released)
            return;
        root._released = true;
        floor.stop();
        cap.stop();
        // (No lock object yet -- a password answered inside the first 40 ms --
        // means there is nothing to release, and the process just goes.)
        if (root.lock)
            root.lock.locked = false;
        console.log("LARESLOCK unlocked");
        console.log("LARESLOCK release " + why);
        linkObj.sendBye();
        root._hypr("restore");
        quitTimer.start();
    }
    Timer {
        id: quitTimer
        interval: 200
        onTriggered: Qt.quit()
    }

    Component.onCompleted: {
        console.log("LARESLOCK fact start: boot=" + root.boot + " relaunch=" + root.relaunch + " rekey=" + root.rekeyEnv + " session=" + (Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "?"));
        configObj.load();
        root._chooseVeil();
        faceAvail.start();
        keysObj.refresh();
        authObj.begin();
        if (root.afterPid > 0) {
            console.log("LARESLOCK ready: waiting for lock " + root.afterPid + " to go");
            afterWait.running = true;
        }
        if (root.boot)
            coverWait.start();
        root._maybeAsk();
    }
}
