pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import "../../common/components"
import "../../common/osd"
import "../../common/system"
import "sources"
import "OsdKinds.js" as Kinds
import "OsdPointer.js" as Pointer

// =============================================================================
// OsdService.qml -- the OSD's one brain (CONTRACT section 3).
//
// The shell owns the keys: it CHANGES the values itself (volume, mic,
// brightness, keyboard light) and WATCHES the things that change without it
// (apps on the audio defaults, the Fn key, the layout, the theme, MPD, Bluetooth,
// Wi-Fi/VPN, the battery). Every one of them says the same thing, a request,
// and everything goes through show():
//
//   source.request(req) -> show(req)
//   show(req): fill the defaults (kind, key, serial, source, user, ms), apply the
//     kind's ROUTE from osd.jsonc --
//        "osd"          emit `request(req)` for the owner(s)
//        "notification" post it through DesktopNotifier ("<title>", "<body>")
//        "off"          nothing (nor for one of its events that `events` leaves out: OsdKinds.eventOf)
//   and return whether the request was HANDLED: false only for nothing shown, an
//   unknown kind or a request that is not an object. A "notification" route
//   counts as handled (a caller that falls back on false would post a second
//   notification).
//
// `live: false` is the mockup and the probes: no Process, Pipewire, Hyprland,
// FileView, DesktopNotifier or Theme singleton is touched, the sources simulate,
// and `notified(kind, spec)` says what a notification route WOULD post. Nothing
// else differs -- one code path.
//
// HELD KEYS. A global shortcut gives one press and one release (the compositor
// does not repeat it), so the repeat is ours: press-<verb> steps once, after
// the compositor's own repeat delay steps at its repeat rate, release-<verb>
// stops. A release that never comes (a `hyprctl dispatch` gives a press only,
// a lock screen ate it) cannot run for ever: a hold is cut after `holdMaxMs`.
//
// The service registers itself on OsdBus (`registerOnBus`) and clears it again
// when it goes away.
//
// SHELL-HOSTED (CONTRACT section 4). The shell builds this service ONCE and hands its
// sources the shell's own backends -- `audioBackend` (PipewireService), `mpdBackend`
// (MpdService), `aerialBackend` (the AerialService: the net and bluetooth sources both read it) and
// `batteryBackend` (the silicon battery adapter: percent, eventLowCharge,
// eventFullyCharged). A source given one reads it and builds NOTHING; with `shellHosted`
// a source given none stays absent and says so once in the log (the battery's own would be
// a BatteryData reading the EC every second) -- never a service of its own. Without
// `shellHosted` (the mockup, the probes) a source with no backend builds its own, as ever --
// but only after it has completed, so a backend handed in through a binding is never raced by a
// transient fallback -- and the battery's only on request (`ownBattery`).
// =============================================================================
Item {
    id: root

    property bool live: true
    property bool registerOnBus: true
    // OsdConfig; the default is this service's own, which reads osd.jsonc when live.
    property var config: ownConfig
    property string screen: ""
    property bool shellHosted: false
    property var audioBackend: null
    property var mpdBackend: null
    property var aerialBackend: null
    property var batteryBackend: null
    // The backends a host leaves out ON PURPOSE ("mpd", "aerial": a module that is switched off): their sources are not live, and say nothing about it.
    property var absent: []
    // The battery source builds a BatteryData of its own only when asked (it reads the EC every
    // second): a standalone host that has no battery reader of its own to hand in sets this.
    property bool ownBattery: false
    // The player module is open on some screen (mini, normal, with its side panel): the OR of
    // every screen's owner, which the shell writes ONCE (CONTRACT section 4). The owners hold the
    // now-playing card back while it is true (OsdKinds.suppressedBy); nothing else reads it.
    property bool playerOpen: false
    // The session is locked (the shell's lock owner, written ONCE by the host like playerOpen): the lock screen shows what plays, so the
    // owners hold the now-playing card back while it is true (OsdKinds.suppressedBy). Nothing else reads it.
    property bool locked: false
    // The display module (Panorama's service or its mock; null = the brightness keys are the laptop's backlight, as ever). The
    // brightness keys act on the DISPLAY UNDER THE POINTER (osd.jsonc brightness.target "pointer"; "focused": the focused screen's, "panel":
    // the laptop's own, and neither asks for the pointer): at a gesture's press one `hyprctl -j cursorpos` is read (150 ms at most) and the
    // monitor whose logical rect holds the point is the target; with no answer, or no rect holding it, the FOCUSED screen
    // (`focusedScreen`, written by the host) is. `monitorRects` is the host's list: FocusedScreen.outputs (x, y, width, height in pixels,
    // scale, transform) or ready logical rects (OsdPointer.js). One target per key gesture, kept `gestureKeepMs` past its last press.
    property var displayBackend: null
    property string focusedScreen: ""
    property var monitorRects: []
    property string hyprctl: "hyprctl"
    property bool pointerLive: root.live
    property int pointerWaitMs: 150
    property int gestureKeepMs: 400
    // The laptop panel for the display module's popup (BacklightSource owns it): bump-read `panelRev` first in a binding.
    readonly property int panelRev: root._panelRev
    property int _panelRev: 0

    readonly property var sources: ({
        audio: audio, backlight: backlight, ddcBrightness: ddcBrightness, kbd: kbdLight, lockKeys: lockKeys, layout: layoutSource,
        theme: themeSource, mpd: mpdSource, bt: btSource, net: netSource, capture: captureSource, battery: batterySource
    })

    // An accepted request for the owner(s).
    signal request(var req)
    // What a "notification" route posts (also emitted when not live, where
    // nothing is posted).
    signal notified(string kind, var spec)
    // `dismiss` (IPC): the owner closes whatever is shown.
    signal dismissRequested()
    // A screenshot was deleted (CaptureSource.deleted, said by the trash helper): the owner takes down its card if it is up.
    signal shotDeleted(string path)
    // A card that is over before its time (the dictation's caption, when the take ends): the owner takes it out of the queue and
    // down if it is up (`withdraw`).
    signal withdrawRequested(string kind, string key)

    // A held key is cut after this long without its release.
    property int holdMaxMs: 8000

    readonly property var _c: root.config && root.config.config ? root.config.config : Kinds.defaultConfig()
    property int _serial: 0
    property int _autoDelay: 600
    property int _autoRate: 25

    OsdConfig {
        id: ownConfig
        live: root.live
    }

    // ---- show ---------------------------------------------------------------------
    function show(req) {
        if (!req || typeof req !== "object" || Array.isArray(req))
            return false;
        const kind = req.kind === undefined || req.kind === null || req.kind === "" ? "generic" : String(req.kind);
        const info = Kinds.kindInfo(kind);
        if (info === null)
            return false;
        const kc = root._c.kinds[kind];
        if (!kc || kc.route === "off")
            return false;
        const r = Object.assign({}, req);
        r.kind = kind;
        const ev = kc.events ? Kinds.eventOf(r) : "";
        if (ev !== "" && kc.events.indexOf(ev) < 0)
            return false;
        r.key = r.key === undefined || r.key === null || r.key === "" ? Kinds.defaultKey(kind) : String(r.key);
        r.serial = ++root._serial;
        r.source = r.source === undefined || r.source === "" ? "mock" : String(r.source);
        r.user = r.user === undefined ? info.user : !!r.user;
        // The request's own time, else the kind's from osd.jsonc, else (an
        // event kind) the table's; 0 = osd.jsonc's dismissMs (the owner's).
        const ms = Number(r.ms);
        r.ms = ms > 0 ? ms : (kc.ms > 0 ? kc.ms : (info.user ? 0 : info.defaultMs));
        if (kc.route === "notification") {
            root._post(r);
            return true;
        }
        root.request(r);
        return true;
    }

    function _post(r) {
        const t = Kinds.notificationText(r);
        const spec = { title: t.title, body: t.body, urgency: "low", timeoutMs: r.ms > 0 ? r.ms : root._c.dismissMs };
        root.notified(r.kind, spec);
        if (root.live)
            notifier.notify(r.kind, spec);
    }

    DesktopNotifier {
        id: notifier
        appName: "OSD"
        keys: Kinds.kindIds()
    }

    function dismiss() {
        root.dismissRequested();
    }

    // Swallow external audio changes for `ms` (a script about to set the volume itself).
    function quiet(ms) {
        audio.quiet(ms);
    }

    // ---- actions -------------------------------------------------------------------
    function volume(verb) {
        return root._act("volume", verb);
    }
    function mic(verb) {
        return root._act("mic", verb);
    }
    function brightness(verb) {
        return root._act("brightness", verb);
    }
    function kbd(verb) {
        return root._act("kbd", verb);
    }
    function lockkeys() {
        lockKeys.press();
        return true;
    }
    function lockkeysReleased() {
        lockKeys.release();
    }
    function media(verb) {
        return mpdSource.media(verb);
    }
    function capture(what, a, b) {
        return captureSource.capture(what, a, b);
    }

    // From the content of an interactive OSD.
    function userValue(kind, v) {
        if (kind === "volume")
            audio.setValue("out", v);
        else if (kind === "mic")
            audio.setValue("in", v);
        else if (kind === "brightness") {
            if (root._cardDdc)
                ddcBrightness.setValue(v);
            else
                backlight.setValue(v);
        }
    }
    // ---- the laptop panel, for the display module's popup ----
    // { capable (a backlight device is known and was read), value (0..1, the card's own figure: the ladder's rung over its count) }
    function panelBrightness() {
        void root._panelRev;
        const ok = backlight.device !== "" && backlight.known;
        return { capable: ok, value: ok ? backlight.levelNow() : -1 };
    }
    // read the panel now (the popup opens): a read of a file, then `panelRev` moves
    function refreshPanel() {
        backlight.refresh();
        root._panelRev++;
    }
    // a slider on the ladder; never writes 0 (BacklightSource.setValue: the bottom rung is the end, whatever PanelBacklight's zeroIsBlack says)
    function setPanelBrightness(v01) {
        backlight.setValue(v01);
        root._panelRev++;
    }
    function userToggleMute(kind) {
        if (kind === "volume" || kind === "mic")
            audio.toggleMute(kind === "volume" ? "out" : "in");
    }
    function userToggleBoost(kind) {
        if (kind === "volume")
            audio.toggleBoost();
    }

    // A plausible request of `kind` (IPC `test`, the mockup's buttons).
    // The card of this kind and key is over: wherever it is (on show, waiting for the swap, in the queue), it goes.
    function withdraw(kind, key) {
        root.withdrawRequested(String(kind), key === undefined || key === null ? "" : String(key));
    }

    function test(kind) {
        const r = Kinds.sampleRequest(kind);
        if (r === null)
            return false;
        r.source = "ipc";
        return root.show(r);
    }

    // verb: "up" | "down" | "up-fine" | "down-fine" | "mute", or the same as
    // "press-<verb>" / "release-<verb>" (a held key).
    function _act(kind, verb) {
        const m = /^(press|release)-(.+)$/.exec(String(verb));
        const phase = m ? m[1] : "tap";
        const v = m ? m[2] : String(verb);
        if (v === "mute") {
            if (phase === "release")
                return true;
            if (kind === "volume" || kind === "mic")
                return audio.toggleMute(kind === "volume" ? "out" : "in");
            return false;
        }
        const fine = v.indexOf("-fine") > 0;
        // a brightness gesture's display is decided at its press and kept to its release (a pointer or focus change mid-hold keeps it)
        const target = kind === "brightness" && phase !== "release" ? root._brightnessGesture() : null;
        const dir = v.indexOf("up") === 0 ? 1 : (v.indexOf("down") === 0 ? -1 : 0);
        if (dir === 0)
            return false;
        if (phase === "tap") {
            const a = root._step(kind, dir, fine, "press", target);
            root._step(kind, dir, fine, "release", target);
            return a;
        }
        if (phase === "press") {
            if (root._held !== null)
                root._stopHold();
            root._held = { kind: kind, verb: v, dir: dir, fine: fine, target: target };
            const ok = root._step(kind, dir, fine, "press", target);
            if (ok && kind !== "kbd") {
                delayTimer.interval = root._delay();
                delayTimer.restart();
                holdLimit.restart();
            }
            return ok;
        }
        // release: only the key that is down ends the hold
        const h = root._held;
        if (h !== null && h.kind === kind && h.verb === v)
            root._stopHold();
        return true;
    }

    property var _held: null

    function _stopHold() {
        const h = root._held;
        root._held = null;
        delayTimer.stop();
        repeatTimer.stop();
        holdLimit.stop();
        if (h !== null)
            root._step(h.kind, h.dir, h.fine, "release", h.target);
    }

    // The brightness gesture of this press: { at, resolved, screen, target, queue }. A press within `gestureKeepMs` of the last one
    // belongs to the same gesture; the steps taken before the pointer's answer wait in `queue` and run in order when it lands.
    property var _bGesture: null
    property var _bAsking: null

    function _brightnessGesture() {
        const now = Date.now();
        const g = root._bGesture;
        if (g !== null && now - g.at < root.gestureKeepMs) {
            g.at = now;
            return g;
        }
        const ng = { at: now, resolved: false, screen: "", target: null, queue: [] };
        root._bGesture = ng;
        root._ask(ng);
        return ng;
    }

    function _ask(g) {
        const want = root._c.brightness.target;
        if (root.displayBackend === null || !root.pointerLive || want !== "pointer") {
            root._resolved(g, want === "panel" ? "" : root.focusedScreen);
            return;
        }
        // an ask still out is over (cannot happen inside gestureKeepMs; never leave a queue waiting)
        if (root._bAsking !== null)
            root._resolved(root._bAsking, root.focusedScreen);
        root._bAsking = g;
        cursorTimer.interval = root.pointerWaitMs;
        cursorTimer.restart();
        cursorProc.command = ["sh", "-c", "command -v \"$1\" > /dev/null 2>&1 || exit 127; exec \"$1\" -j cursorpos", "sh", root.hyprctl];
        cursorProc.running = false;
        cursorProc.running = true;
    }

    // the cursor's answer (or the wait's end): the monitor under it, else the focused screen
    function _answered(text) {
        const g = root._bAsking;
        if (g === null)
            return;
        const pt = Pointer.parseCursor(text);
        const name = pt !== null ? Pointer.monitorAt(root.monitorRects, pt.x, pt.y) : "";
        root._resolved(g, name !== "" ? name : root.focusedScreen);
    }

    function _resolved(g, name) {
        if (g.resolved)
            return;
        cursorTimer.stop();
        if (root._bAsking === g)
            root._bAsking = null;
        g.resolved = true;
        g.screen = name;
        g.target = root._targetOf(name);
        const q = g.queue;
        g.queue = [];
        q.forEach(e => root._brightnessStep(g, e.dir, e.fine, e.phase));
    }

    // null = the laptop's backlight (the panel, or no display module), else { connector, label } of an external
    function _targetOf(name) {
        const b = root.displayBackend;
        if (b === null || name === "")
            return null;
        const t = b.brightnessTarget(name);
        if (!t || (t.kind !== "ddc" && t.kind !== "pending"))
            return null;
        return { connector: t.connector || name, label: t.label || name };
    }

    function _brightnessStep(g, dir, fine, phase) {
        g.at = Date.now();
        if (!g.resolved) {
            g.queue.push({ dir: dir, fine: fine, phase: phase });
            return true;
        }
        return g.target ? ddcBrightness.adjust(g.target, dir, fine, phase) : backlight.adjust(dir, fine, phase);
    }

    Process {
        id: cursorProc
        stdout: StdioCollector {
            onStreamFinished: root._answered(this.text)
        }
    }
    Timer {
        id: cursorTimer
        onTriggered: {
            if (root._bAsking !== null)
                root._resolved(root._bAsking, root.focusedScreen);
        }
    }
    // The card on screen names a DDC display (a drag on its slider sets that display).
    property bool _cardDdc: false

    function _step(kind, dir, fine, phase, target) {
        if (kind === "volume")
            return audio.adjust("out", dir, phase);
        if (kind === "mic")
            return audio.adjust("in", dir, phase);
        if (kind === "brightness")
            return root._brightnessStep(target, dir, fine, phase);
        if (kind === "kbd")
            return phase === "release" ? true : kbdLight.adjust(dir);
        return false;
    }

    function _delay() {
        const d = root._c.repeat.delayMs;
        return d === "auto" ? root._autoDelay : d;
    }
    function _rate() {
        const r = root._c.repeat.rateHz;
        return r === "auto" ? root._autoRate : r;
    }

    Timer {
        id: delayTimer
        onTriggered: {
            repeatTimer.interval = Math.max(1, Math.round(1000 / root._rate()));
            repeatTimer.start();
            root._repeat();
        }
    }
    Timer {
        id: repeatTimer
        repeat: true
        onTriggered: root._repeat()
    }
    Timer {
        id: holdLimit
        interval: root.holdMaxMs
        onTriggered: root._stopHold()
    }
    function _repeat() {
        const h = root._held;
        if (h !== null)
            root._step(h.kind, h.dir, h.fine, "repeat", h.target);
    }

    // The compositor's own repeat settings (`hyprctl getoption input:repeat_delay`
    // -> "int: 600"); the defaults stand when not live or when it does not answer.
    Process {
        id: delayProc
        command: ["hyprctl", "getoption", "input:repeat_delay"]
        stdout: StdioCollector {
            onStreamFinished: {
                const n = Kinds.parseIntOption(this.text);
                if (n > 0)
                    root._autoDelay = n;
            }
        }
    }
    Process {
        id: rateProc
        command: ["hyprctl", "getoption", "input:repeat_rate"]
        stdout: StdioCollector {
            onStreamFinished: {
                const n = Kinds.parseIntOption(this.text);
                if (n > 0)
                    root._autoRate = n;
            }
        }
    }

    // ---- the sources -----------------------------------------------------------------
    AudioSource {
        id: audio
        live: root.live
        backend: root.audioBackend
        shellHosted: root.shellHosted
        step: root._c.volume.step
        boostMax: root._c.volume.boostMax
        micStep: root._c.mic.step
        onRequest: req => root.show(req)
    }
    BacklightSource {
        id: backlight
        live: root.live
        device: root._c.brightness.device || PanelBacklight.device
        zeroOpens: PanelBacklight.zeroBlackOf(backlight.device)
        stepFrac: root._c.brightness.step
        fineStepFrac: root._c.brightness.fineStep
        gamma: root._c.brightness.gamma
        floorRaw: root._c.brightness.floorRaw
        onRequest: req => {
            root._cardDdc = false;
            root.show(req);
        }
        onRawChanged: root._panelRev++
    }
    DdcBrightnessSource {
        id: ddcBrightness
        backend: root.displayBackend
        stepFrac: root._c.brightness.step
        fineStepFrac: root._c.brightness.fineStep
        onRequest: req => {
            root._cardDdc = true;
            root.show(req);
        }
    }
    KbdLightSource {
        id: kbdLight
        live: root.live
        device: root._c.kbd.device
        onRequest: req => root.show(req)
    }
    LockKeysSource {
        id: lockKeys
        live: root.live
        shown: root._c.lockkeys.keys
        onRequest: req => root.show(req)
    }
    LayoutSource {
        id: layoutSource
        live: root.live
        keyboard: root._c.layout.keyboard
        codes: root._c.layout.codes
        onRequest: req => root.show(req)
    }
    ThemeSource {
        id: themeSource
        live: root.live
        onRequest: req => root.show(req)
    }
    MpdSource {
        id: mpdSource
        live: root.live && root.absent.indexOf("mpd") < 0
        others: root.live && root._c.media.keys === "auto"
        backend: root.mpdBackend
        shellHosted: root.shellHosted
        onRequest: req => root.show(req)
    }
    BtSource {
        id: btSource
        live: root.live && root.absent.indexOf("aerial") < 0
        backend: root.aerialBackend
        shellHosted: root.shellHosted
        onRequest: req => root.show(req)
    }
    NetSource {
        id: netSource
        live: root.live && root.absent.indexOf("aerial") < 0
        backend: root.aerialBackend
        shellHosted: root.shellHosted
        onRequest: req => root.show(req)
    }
    CaptureSource {
        id: captureSource
        live: root.live          // a mock shell launches no swappy
        openCommand: root._c.capture.openCommand
        editCommand: root._c.capture.editCommand
        onRequest: req => root.show(req)
        onDeleted: path => root.shotDeleted(path)
    }
    BatterySource {
        id: batterySource
        live: root.live
        backend: root.batteryBackend
        ownBackend: root.ownBattery
        shellHosted: root.shellHosted
        onRequest: req => root.show(req)
    }

    // ---- the bus ------------------------------------------------------------------------
    Component.onCompleted: {
        if (root.config && root.config.ensureLoaded)
            root.config.ensureLoaded();
        if (root.live) {
            delayProc.running = true;
            rateProc.running = true;
        }
        if (root.registerOnBus)
            OsdBus.service = root;
    }
    Component.onDestruction: {
        root._stopHold();
        if (OsdBus.service === root)
            OsdBus.service = null;
    }
}
