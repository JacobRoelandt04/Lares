pragma ComponentBehavior: Bound

import QtQuick
import QtQml
import Quickshell
import Quickshell.Io

import "../../common/components"
import "../../common/osd"
import "../../common/system"
import "../cast"
import "BridgeModel.js" as Model
import "BridgeScenarios.js" as Scenarios

// =============================================================================
// BridgeService.qml -- the phone / device bridge, the shell's part (docs/contracts/bridge.md section 6). ONE per shell.
//
// Everything that knows a device, a link or a verdict is the tool's (tools/bridge/lares-bridge): which devices exist, how each is
// linked, what each action can do right now and why not (`can`), every argv. This service only says WHEN (`watch` while it runs, a
// one-shot per action), keeps the model the popup reads, and talks to the user (toasts). It decides nothing about availability and
// makes up no reason: `can.<x>.why` / `.hint` and a job's `reason` are the tool's words and are passed through.
//
//   live: true     `lares-bridge watch` as ONE SupervisedStream (restarted with backoff); each line goes through
//                  BridgeModel.parseLine; every action is a one-shot through ActionRunner (one at a time per device).
//   live: false    (the default: a host that forgets cannot reach the machine) nothing is started and no Process exists. Lines
//                  come from BridgeScenarios (`scenario`), through the same parser; every action is appended to `calls` and
//                  answered by BridgeScenarios.react a turn later; a mock send's figures step on a timer.
//
// WHAT A LINE DOES, in this order (the model publishes its identity last, CLAUDE.md): the rows of `devices` (the same `rec`
// objects for ever: `d` re-assigned when it changed, rows added and removed by key, `move` for a new order), then `current`,
// `pairing`, `jobs`, `env`, then the acts, the toasts and the idle facts, then `ready`, and `serial` LAST. A handler on
// `serialChanged` sees the new devices AND jobs.
//
// `acts` (the current device's actions, the 12 keys of `can`): idle -> busy at a call -> done | failed when the one-shot answers
// -> idle again when the device changes, the action's `can` changes or a new call starts; one `acted` per answer. A NEW object
// per change.
//
// TOASTS (through `notifier`, a DesktopNotifier; every one null-safe):
//   a send           ONE `live` progress toast ("Sending to <name>", plain totals before anything moved, never "0 / 3")
//                    REPLACED IN THE SAME TURN by ONE closing toast ("3 files sent to <name>" / the failure's reason and hint):
//                    the closing one is posted, then the progress withdrawn (the toast stack hands the room over)
//   a mirror / mount that failed   one toast with the tool's reason and hint
//   nothing while the popup is open and shows the same fact (`popupOpen`), except a send's closing toast
//   nothing for what KDE Connect posts itself (pair requests, received files, pings)
//   a shot goes to the OSD's capture card (OsdBus), else one toast
// An ended job is acknowledged (`ack <id>`) after its toast -- also a job that ended while no shell ran (the first line carries it).
//
// INJECTED, all optional: `notifier`, `runner` (a CommandRunner: openFiles), `clipboard` (a ClipboardService: copyText), `osd`
// (default the OsdBus singleton).
// =============================================================================
Item {
    id: root

    // ---- the contract ------------------------------------------------------------------------------------------------
    property bool live: false
    // Not live: a key of BridgeScenarios ("none", "pairing", "asleep", "wifi", "wired", "mirroring", "mounted", "transfer", "error").
    property string scenario: ""
    // Written by the host: ONE writer, the OR over the screens.
    property bool popupOpen: false
    property string configPath:
        (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/quickshell/config/bridge.jsonc"
    property string toolPath: RepoRoot.dir + "/tools/bridge/lares-bridge"
    property string python: "python3"
    property var launcher: ["setpriv", "--pdeathsig", "TERM", "--"]
    // A probe's seam: when > 0 it is the deadline of every one-shot (BridgeModel.timeoutOf gives the real ones).
    property int timeoutOverrideMs: 0
    // The portal's file picker (prints the picked paths NUL-separated; exit 1 = cancelled).
    property string pickerPath: RepoRoot.dir + "/tools/notes/portal_pick.py"

    property var notifier: null
    property var runner: null
    property var clipboard: null
    property var osd: OsdBus

    // "" | "mirror" | "files": the page on show. It lives here because a popup's content is per screen and destroyed on close.
    property string page: ""

    // The mock's clocks (ms): a scenario's later lines, a send's steps, the answer to an action (0 = the next turn).
    property int mockLineMs: 1200
    property int mockStepMs: 700
    property int mockAnswerMs: 0
    // What the mock's file picker "picks".
    property var mockPicks: ["/home/demo/Pictures/IMG_2041.jpg", "/home/demo/Documents/notes.pdf", "/home/demo/Videos/clip.mp4"]

    readonly property bool ready: root._ready
    readonly property int serial: root._serial
    readonly property var env: root._env
    readonly property ListModel devices: ListModel {
        id: devicesModel
    }
    readonly property int count: devicesModel.count
    readonly property string currentKey: root._currentKey
    readonly property var current: root._current
    readonly property var pairing: root._pairing
    readonly property var jobs: root._jobs
    // a Wireless debugging pairing in progress or just ended: { key, name, state: waiting|paired|failed|expired, reason, png } | null
    readonly property var wifiPair: root._wifiPair
    readonly property bool busy: Model.busyOf(root._jobs)
    readonly property var settings: cfg.settings
    // the config itself (a probe hands it an object: `config.apply({...})`)
    readonly property alias config: cfg
    readonly property var acts: root._acts
    readonly property var calls: root._calls
    // Beyond the contract: why the last line was refused ("" after a good one); bumps when the ROWS' order or membership changed;
    // the file picker is open.
    readonly property string lastError: root._lastError
    readonly property int rowSerial: root._rowSerial
    readonly property bool picking: root._picking

    signal acted(string key, string action, bool ok, string why)

    function device(key: string): var {
        return Object.prototype.hasOwnProperty.call(root._byKey, key) ? root._byKey[key].d : null;
    }

    // The live job of that kind for that device (starting or running), or null.
    function job(key: string, kind: string): var {
        const js = root._jobs;
        for (let i = 0; i < js.length; i++)
            if (js[i].device === key && js[i].kind === kind && (js[i].phase === "starting" || js[i].phase === "running"))
                return js[i];
        return null;
    }

    // ---- the actions -------------------------------------------------------------------------------------------------
    // Each returns false when the request is malformed or the same action is already out for that device; true = asked.
    function select(key: string): bool {
        return key !== root._currentKey ? root._ask("select", key, {}) : false;
    }
    function mirror(key: string, opts: var): bool {
        const o = opts || {};
        return root._ask("mirror", key, { mode: o.mode, screenOff: o.screenOff === true, record: o.record === true });
    }
    function stopJob(id: string): bool {
        const js = root._jobs;
        let key = "";
        for (let i = 0; i < js.length; i++)
            if (js[i].id === id)
                key = js[i].device;
        return root._ask("stop", key, { id: id });
    }
    function mount(key: string, which: string): bool {
        return root._ask("mount", key, { which: which });
    }
    function unmount(key: string, which: string): bool {
        return root._ask("unmount", key, { which: which });
    }
    function send(key: string, paths: var): bool {
        const p = [];
        for (let i = 0; paths && i < paths.length; i++)
            p.push(String(paths[i]));
        return root._ask("send", key, { paths: p });
    }
    function shot(key: string): bool {
        return root._ask("shot", key, {});
    }
    function ring(key: string): bool {
        return root._ask("ring", key, {});
    }
    function clip(key: string): bool {
        return root._ask("clip", key, {});
    }
    function pressKey(key: string, name: string): bool {
        return root._ask("key", key, { name: name });
    }
    function pair(key: string): bool {
        return root._ask("pair", key, {});
    }
    function accept(key: string): bool {
        return root._ask("accept", key, {});
    }
    function reject(key: string): bool {
        return root._ask("reject", key, {});
    }
    function unpair(key: string): bool {
        return root._ask("unpair", key, {});
    }
    // Beyond the contract: the tool's `arm` / `disarm` (`can.arm`).
    // Starts a Wireless debugging pairing: the tool writes a QR code (`wifiPair.png`) for the phone's "Pair device with QR code"
    function wifiPair(key: string): bool {
        return root._ask("wifipair", key, {});
    }
    // Takes the code away; the tool's waiter sees its record gone and ends
    function wifiPairCancel(): void {
        const k = root._wifiPair ? root._wifiPair.key : "";
        root._wifiPair = null;
        if (k !== "")
            root._ask("wifipair", k, { cancel: true });
    }
    function arm(key: string): bool {
        return root._ask("arm", key, {});
    }
    function disarm(key: string): bool {
        return root._ask("disarm", key, {});
    }
    function refresh(): bool {
        return root._ask("refresh", "", {});
    }
    // UNLOCK (the user's decision, 2026-11-19): the PIN is kept in the login keyring and typed over adb into the phone's lock
    // screen by the tool, which types only when the lock screen has the keys and tries a PIN once (a failure waits for a new
    // one). ONLY FOR A CAST (the user, 2026-11-21: "it should only unlock when I request casting"; mounting and browsing work
    // with the screen dark): at a Mirror's start (`castprep --unlock`) and on the first touch of a dark or locked picture
    // (`castUnlock`). Opening the popup wakes nothing (round 5 unlocked at every open and the phone was lit for nothing).
    // The PIN goes to the tool on stdin and nowhere else: not in argv, not in `calls`, not in an answer.
    function setPin(key: string, pin: string): bool {
        const p = String(pin || "");
        if (!/^[0-9A-Za-z]{4,16}$/.test(p))
            return false;
        return root._ask("pin", key, { op: "set" }, p + "\n");
    }
    function forgetPin(key: string): bool {
        return root._ask("pin", key, { op: "forget" });
    }
    function setPref(key: string, name: string, value: var): bool {
        return root._ask("set", key, { name: name, value: value });
    }
    // Reads the device's facts over adb (model, Android, storage, battery health); the next line carries them. Asked from the
    // popup's open and by hand, never from a getter.
    function loadFacts(key: string): bool {
        const d = root.device(key);
        return d !== null && Model.canOf(d, "facts").ok ? root._ask("facts", key, {}) : false;
    }

    // `files.open` with {path} replaced, started detached through the injected CommandRunner. The mount point is the tool's.
    function openFiles(key: string, which: string): bool {
        if (which !== "usb" && which !== "wifi")
            return false;
        const d = root.device(key);
        let point = d ? (d.mounts[which].open || d.mounts[which].point) : "";
        if (point === "" && which === "usb")
            point = root.settings.files.usbMount;
        if (point === "")
            return false;
        const argv = Model.openArgv(root.settings.files.open, point);
        root._record("openFiles", key, { which: which, point: point, argv: argv });
        if (root.live && root.runner)
            root.runner.run(argv, { detached: true });
        return true;
    }

    // Puts a text (a path the popup shows) on the clipboard, through the injected ClipboardService.
    function copyText(text: string): void {
        const t = text === undefined || text === null ? "" : String(text);
        root._record("copyText", "", { text: t });
        if (root.live && root.clipboard)
            root.clipboard.paste([], { mode: "copy", text: t, via: "copy" });
    }

    // The portal's file picker, then `send` with what it picked. Not live, the mock's `mockPicks`.
    function pickAndSend(key: string): bool {
        if (root._picking || key === "")
            return false;
        if (!root.live) {
            root._record("pickAndSend", key, {});
            return root.send(key, root.mockPicks);
        }
        const d = root.device(key);
        // bridge.jsonc files.pickDir: where the chooser starts (`~/` is the home)
        const home = Quickshell.env("HOME") || "/";
        const from = String(root.settings.files.pickDir || "~").replace(/^~(?=\/|$)/, home);
        const argv = root.launcher.concat([root.pickerPath, from, "Send to " + (d ? d.name : key)]);
        root._record("pickAndSend", key, { argv: argv });
        root._picking = true;
        const pk = pickComp.createObject(root, { devKey: key, argv: argv });
        pk.proc.running = true;
        return true;
    }

    // ---- state (private writers) -------------------------------------------------------------------------------------
    property bool _ready: false
    property int _serial: 0
    property var _env: Model.normalise({}).env
    property string _currentKey: ""
    property var _current: null
    property var _pairing: []
    property var _jobs: []
    property var _wifiPair: null
    property var _acts: Model.idleActs()
    property var _calls: []
    property string _lastError: ""
    property int _rowSerial: 0
    property bool _picking: false
    property bool _started: false
    property bool _haveTool: false
    property var _line: null
    property var _keys: []
    property var _byKey: ({})
    property var _sigs: ({})
    property var _warned: ({})

    function _record(action: string, key: string, args: var): void {
        const next = root._calls.concat([{ action: action, key: key, args: JSON.parse(JSON.stringify(args === undefined ? {} : args)) }]);
        root._calls = next.length > 200 ? next.slice(next.length - 200) : next;
    }

    // ---- the config --------------------------------------------------------------------------------------------------
    BridgeConfig {
        id: cfg
        live: root.live
        configPath: root.configPath
    }

    // ---- the tool ----------------------------------------------------------------------------------------------------
    // Is there a tool to run? (a Process whose program is missing emits neither started nor exited: look first)
    FileView {
        id: toolFile
        path: root.toolPath
        printErrors: false
        watchChanges: root.live
        onLoaded: root._haveTool = true
        onLoadFailed: error => {
            root._haveTool = false;
            if (root.live && root._started)
                root._complain("the tool is missing: " + root.toolPath + " (" + error + ")");
        }
    }
    // ---- the cast: the phone's screen on the phone's own display (tools/bridge/lares-cast through cast/CastSession) ---------
    // ONE session per shell, here because a popup's content is destroyed on close: the cast goes on behind a closed popup for
    // `cast.closeAfterS`, then stops. `castprep` walks the transport (the cable, then Wi-Fi) first; the picture's size follows
    // the room the popup gives it (castWantRoom, in device pixels), in buckets, capped by the link's `mirror.<link>.maxSize`.
    // Two modes: "mirror" (the phone's own screen) and "desktop" (a second, virtual screen of the phone's, made at the room's
    // shape and laid out like the phone: lares-cast --new-display). A resized MIRROR restarts its stream at the new bucket
    // (`cast.reloadOnResize`): the page holds the last frame blurred while it does (castHolding "Resizing", castHoldReady); a
    // desktop never restarts for a size (its apps would go): its virtual screen is resized live (`flex`, session.resize).
    // A session that ends without being asked to (the phone's USB switched, a lock, a dropped link) is brought back by itself:
    // phase "reconnecting" (castprep again, then start; tries after 0.5, 1, 2, 4 s), held as "Reconnecting".
    // the session exists only for a live service (a mock builds no Process and starts nothing); null otherwise
    readonly property var castSession: castLoader.item
    readonly property string _csState: castLoader.item ? castLoader.item.state : "idle"
    readonly property string castKey: root._castKey
    // the cast's mode: "mirror" | "desktop"
    readonly property string castMode: root._castMode
    // the cast records (the Mirror page's Record): castprep --record names the file, lares-cast --record writes it; the end's toast
    // says where it went (or which part was kept)
    readonly property bool castRecording: root._castRecord
    // THE HOLD: the page freezes its last frame blurred under a title while something is under way. castHoldWhy says what:
    // "Resizing" (a restart for a new size: from the ask, the page grabs its last frame first, to the new stream's live),
    // "Reconnecting" (the session ended by itself: until the new stream is live) or "Unlocking" (until the unlock's answer, at
    // the next frame); "" = no hold.
    readonly property bool castHolding: root._castHoldWhy !== ""
    readonly property string castHoldWhy: root._castHoldWhy
    // an unlock the cast page asked for is out: the picture takes no input meanwhile
    readonly property bool castUnlocking: root._castUnlocking
    // idle | connecting | starting | live | reconnecting | failed ("ended" is never "starting": it reconnects, or fails once the tries are spent)
    readonly property string castPhase: root._castReconnecting && root._castKey !== "" && root._castFail === "" ? "reconnecting"
        : (root._castPrep ? "connecting"
        : (root._castFail !== "" ? "failed"
        : (root._castKey === "" ? "idle"
        : (root._csState === "live" || root._csState === "starting" || root._csState === "failed" ? root._csState
        : (root._csState === "ended" ? "reconnecting" : "starting")))))
    readonly property bool casting: root.castPhase === "connecting" || root.castPhase === "starting" || root.castPhase === "live" || root.castPhase === "reconnecting"
    readonly property string castReason: root._castFail !== "" ? root._castFail : ((root._csState === "failed" || root._csState === "ended") ? castLoader.item.reason : "")
    // the popup's size while the cast shows, as a multiple of its resting size (session only)
    property real castScale: 1
    // and how far off its icon along the bar (the resizer's held edge), carried in and out like the size
    property real castShift: 0
    // the phone on show is turning (written by the cast page: a free look, the popup's opening turn): a size asked for meanwhile waits
    // until it has landed -- a restart blurs the picture, a desktop's resize lays its apps out again
    property bool castTurning: false
    onCastTurningChanged: {
        if (!root.castTurning && (root._reloadWanted() || root._deskResizeWanted()))
            castResize.restart();
    }
    readonly property var castBuckets: [720, 1080, 1440, 1920, 2400]

    function castStart(key: string, mode: string, record: bool): bool {
        const m = mode === "desktop" ? "desktop" : "mirror";
        const d = root.device(key);
        if (!d || !Model.canOf(d, "mirror").ok)
            return false;
        if (root._castKey === key && root.casting && root._castMode === m && root._castRecord === record)
            return true;
        // another phone's cast ENDS (its hold back, its sleep); this phone's, in another mode, is only halted: the new castprep
        // takes the hold over (a Desktop gives it back) and the sleep owed at the end is kept
        if (root._castKey !== "" && root._castKey !== key)
            root.castStop();
        else
            root._castHalt();
        root._castMode = m;
        root._castRecord = record;
        root._castFail = "";
        root._castTries = 0;
        root._castWasLive = false;
        root._castReconnecting = false;
        // connecting from the first change of the key (not a turn of "starting" in between)
        root._castPrep = root.live;
        root._castKey = key;
        if (!root.live) {
            root._castFail = "The mockup has no phone to cast";
            return true;
        }
        // a Desktop never unlocks the phone: Android keeps the new display usable while the phone is locked, and the lock screen's
        // focus is display 0's, so the tool would refuse to type anyway (measured on the user's phone, 2026-11-21)
        // bridge.jsonc cast.unlock: "start" in it, or the PIN is not typed at the start
        root._castPrepRun(key, m === "mirror" && d.pin === "set" && root.settings.cast.unlock.indexOf("start") >= 0);
        return true;
    }
    // castprep walks the transport; at a cast START, when a PIN is kept, it types it into a locked phone first (a cast started on a
    // locked phone shows its lock screen otherwise). A reconnect never does: nobody asked for it, and a phone that locked meanwhile
    // stays locked until the user clicks its picture (the user's rule, round 6). A Mirror HOLDS the phone's screen on (`--hold`:
    // its own timeout raised, recorded on this computer, given back by castend); a Desktop gives a hold back. A recording cast asks
    // for the file's name too (`--record`: the tool's one rule for where recordings go); a reconnect's session records into a new one.
    function _castPrepRun(key: string, unlock: bool): void {
        root._castPrep = true;
        toolRunner.run(key, Model.argvOf("castprep", key, { unlock: unlock, hold: root._castMode === "mirror", record: root._castRecord }), res => root._castPrepared(key, res),
                       { timeoutMs: Model.timeoutOf("castprep") });
    }
    // THE END OF A CAST (Stop, the popup closed for `cast.closeAfterS`, another phone's cast): the hold goes back, and a phone that was
    // dark when the cast began -- or that the cast's picture woke -- is put back to sleep (the user, 2026-11-21: "only wake physically
    // when needed"). Into scrcpy's window (castDetach) the phone stays as it is: the window still shows it.
    function castStop(): void {
        const k = root._castKey;
        root._castHalt();
        root._castEnd(k, root._castSleepOwed);
    }
    function _castEnd(key: string, sleep: bool): void {
        root._castSleepOwed = false;
        if (key === "" || !root.live)
            return;
        // bridge.jsonc cast.sleepAtEnd false: a phone the cast lit stays lit
        toolRunner.run(key, Model.argvOf("castend", key, { sleep: sleep && root.settings.cast.sleepAtEnd !== false }), res => {}, { timeoutMs: Model.timeoutOf("castend") });
    }
    // the picture woke a dark phone: it goes back to sleep at the end
    function castWoke(): void {
        if (root._castKey !== "")
            root._castSleepOwed = true;
    }
    property bool _castSleepOwed: false
    function _castHalt(): void {
        root._castPrep = false;
        root._castKey = "";
        root._castDeskPend = null;
        castStable.stop();
        root._castHoldWhy = "";
        root._castUnlocking = false;
        root._castReconnecting = false;
        castReconnect.stop();
        castResize.stop();
        castHoldWait.stop();
        if (castLoader.item)
            castLoader.item.stop();
    }
    // Into scrcpy's own window: the cast stops (its recording is finished), a window mirror starts -- recording too when the cast did.
    function castDetach(): bool {
        const k = root._castKey;
        if (k === "")
            return false;
        const m = root._castMode;
        const rec = root._castRecord;
        root._castHalt();
        root._castEnd(k, false);
        if (root.page === "cast")
            root.page = "";
        return root.mirror(k, { mode: m, record: rec });
    }
    function castSetAudio(on: bool): void {
        const k = root._castKey !== "" ? root._castKey : root._currentKey;
        if (k !== "")
            root.setPref(k, "castAudio", on);
        const cs = castLoader.item;
        if (cs && root._castKey !== "" && cs.audio !== on) {
            cs.audio = on;
            if (cs.state === "live" || cs.state === "starting")
                cs.restart();
        }
    }
    // The picture's room in device pixels (`dpr` the window's real ratio); a mirror whose bucket changes restarts once the size
    // has settled, a desktop's virtual screen follows the room by a live resize (castResize decides).
    function castWantRoom(w: real, h: real, dpr: real): void {
        root._castRoomW = Math.round(w);
        root._castRoomH = Math.round(h);
        root._castDpr = dpr > 0 ? dpr : 1;
        root._castWantPx = Math.max(root._castRoomW, root._castRoomH);
        castRoomStill.restart();
        if (root._reloadWanted() || root._deskResizeWanted())
            castResize.restart();
    }
    // The page has the last frame (or there is no page to hold it): the restart goes ahead.
    function castHoldReady(): void {
        if (root._castHoldWhy !== "Resizing" || !castHoldWait.running)
            return;
        castHoldWait.stop();
        root._castReloadGo();
    }
    // The first touch or key on the picture of a dark or locked phone (the page has swallowed it and woken the screen): the
    // PIN is typed (`unlock --auto`: an unlocked phone is left alone). True = an unlock is out; the picture takes no input and
    // the page holds "Unlocking" until its answer.
    function castUnlock(key: string): bool {
        if (root._castUnlocking)
            return true;
        const d = root.device(key);
        if (root._castKey === "" || !d || !Model.canOf(d, "unlock").ok)
            return false;
        root._castUnlocking = true;
        if (root._castHoldWhy === "")
            root._castHoldWhy = "Unlocking";
        // false = one is already out (the popup's own): its answer ends this too
        root._ask("unlock", key, { auto: true });
        return true;
    }
    function _castUnlockDone(): void {
        root._castUnlocking = false;
        if (root._castHoldWhy === "Unlocking")
            root._castHoldWhy = "";
    }

    property string _castKey: ""
    property string _castMode: "mirror"
    property bool _castRecord: false
    property string _castHoldWhy: ""
    property bool _castUnlocking: false
    property bool _castReconnecting: false
    property bool _castWasLive: false
    property int _castTries: 0
    readonly property var _castBackoff: [500, 1000, 2000, 4000]
    property int _castRoomW: 0
    property int _castRoomH: 0
    property real _castDpr: 1
    // a desktop's screen: the factor from the room to the screen (kept from the start) and the size it has now
    property real _castDeskK: 0
    property int _castDeskW: 0
    property int _castDeskH: 0
    property bool _castPrep: false
    property string _castFail: ""
    property int _castCap: 0
    property int _castWantPx: 0
    function _castSize(): int {
        const want = root._castWantPx > 0 ? root._castWantPx : 1440;
        let b = root.castBuckets[root.castBuckets.length - 1];
        for (const x of root.castBuckets) {
            if (x >= want) {
                b = x;
                break;
            }
        }
        return root._castCap > 0 ? Math.min(b, root._castCap) : b;
    }
    // A desktop's screen (BridgeModel.desktopScreen): laptop-sized, at the room's shape; before a page has a room, a phone's shape.
    function _castScreen(): var {
        const w = root._castRoomW > 0 ? root._castRoomW : 412;
        const h = root._castRoomH > 0 ? root._castRoomH : 915;
        return Model.desktopScreen(w, h, root._castDpr, root.settings.cast);
    }
    // A recording mirror is never restarted for a new size: a restart cuts the recording into two files.
    function _reloadWanted(): bool {
        const cs = castLoader.item;
        return cs !== null && cs.state === "live" && root._castMode === "mirror" && root.settings.cast.reloadOnResize === true
            && !root._castRecord && root._castSize() !== cs.maxSize;
    }
    // The room's new size on the desktop's screen (the start's factor kept), whole multiples of 8, at most 2400
    function _deskSize(): var {
        const r8 = x => Math.min(2400, Model.round8(x * root._castDeskK));
        return { w: r8(root._castRoomW), h: r8(root._castRoomH) };
    }
    function _deskResizeWanted(): bool {
        const cs = castLoader.item;
        if (cs === null || cs.state !== "live" || root._castMode !== "desktop" || root._castDeskK <= 0 || root._castRoomW <= 0 || root._castRoomH <= 0)
            return false;
        const t = root._deskSize();
        return t.w !== root._castDeskW || t.h !== root._castDeskH;
    }
    function _castReloadGo(): void {
        const cs = castLoader.item;
        if (!cs || root._castHoldWhy !== "Resizing")
            return;
        cs.maxSize = root._castSize();
        cs.restart();
    }
    // The session ended (or died after being live) without our asking: bring it back, after a growing wait, or say it failed.
    function _castReconnectDone(): void {
        const cs = castLoader.item;
        if (cs !== null && cs.state === "live")
            root._castReconnecting = false;
    }
    function _castLost(why: string): void {
        if (root._castKey === "")
            return;
        castStable.stop();
        root._castWasLive = false;
        if (root._castTries >= root._castBackoff.length) {
            root._castFail = why !== "" ? why : "The cast ended";
            root._castReconnecting = false;
            root._castHoldWhy = "";
            return;
        }
        root._castReconnecting = true;
        root._castHoldWhy = "Reconnecting";
        castReconnect.interval = root._castBackoff[root._castTries];
        root._castTries++;
        castReconnect.restart();
    }
    function _castPrepared(key: string, res: var): void {
        if (root._castKey !== key || !root._castPrep)
            return;
        root._castPrep = false;
        if (res.ok !== true) {
            const why = Model.words(String(res.reason || "Could not reach the phone"), String(res.hint || ""));
            if (root._castReconnecting)
                root._castLost(why);
            else
                root._castFail = why;
            return;
        }
        const a = res.answer || {};
        if (a.asleep === true)
            root._castSleepOwed = true;
        if (root._castMode === "desktop" && castRoomStill.running) {
            root._castDeskPend = { key: key, a: a };
            return;
        }
        root._castLaunch(key, a);
    }
    property var _castDeskPend: null
    // the room has stood still: a Desktop that waited for it starts
    Timer {
        id: castRoomStill
        interval: 250
        onTriggered: {
            const p = root._castDeskPend;
            root._castDeskPend = null;
            if (p !== null && p.key === root._castKey)
                root._castLaunch(p.key, p.a);
        }
    }
    function _castLaunch(key: string, a: var): void {
        const d = root.device(key);
        root._castCap = Number(a.maxSize) || 0;
        const cs = castLoader.item;
        if (!cs)
            return;
        cs.serial = String(a.serial || "");
        cs.bitRate = String(a.bitRate || "");
        cs.maxFps = Number(a.maxFps) || 0;
        cs.maxSize = root._castSize();
        if (root._castMode === "desktop") {
            const scr = root._castScreen();
            cs.newDisplay = scr.w + "x" + scr.h + "/" + scr.dpi;
            cs.flex = true;
            root._castDeskK = scr.k;
            root._castDeskW = scr.w;
            root._castDeskH = scr.h;
        } else {
            cs.newDisplay = "";
            cs.flex = false;
            root._castDeskK = 0;
        }
        cs.audio = d !== null && d.prefs.castAudio === true;
        cs.record = root._castRecord ? String(a.record || "") : "";
        cs.start();
    }
    Loader {
        id: castLoader
        active: root.live
        sourceComponent: Component {
            CastSession {
                id: castSess
                // Screen off (the Mirror page's switch) darkens the phone once the picture runs
                onStateChanged: {
                    const d = root.device(root._castKey);
                    if (castSess.state === "live" && d !== null && d.prefs.screenOff === true)
                        castSess.screen(false);
                    root._castSessionState(castSess.state, castSess.reason);
                }
                // the file of a recording cast is finished (after the session's end, a stop's too): where it went
                onRecorded: ev => root._castRecorded(ev)
            }
        }
    }
    // A recording's end, told: where the file went (a toast, the popup open or not: nothing in it says so), or why it could not be
    // finished and which part is kept; a cast that recorded nothing says nothing.
    function _castRecorded(ev: var): void {
        const t = Model.recordToast(ev);
        if (t !== null && root.notifier)
            root.notifier.notify("rec-" + String(ev.path || ev.kept || "error"), t);
    }
    // What the session's state means for the hold and the reconnect: a reload / a reconnect ends when the new stream is live (the
    // page holds its frame until a picture shows) or goes wrong; an end nobody asked for reconnects.
    function _castSessionState(st: string, why: string): void {
        if (root._castKey === "")
            return;
        if (st === "live") {
            root._castWasLive = true;
            castStable.restart();
            // the phase reads `state` through a binding that has not caught up with this handler: the flag goes a turn later
            Qt.callLater(root._castReconnectDone);
            if (root._castHoldWhy === "Resizing" || root._castHoldWhy === "Reconnecting")
                root._castHoldWhy = "";
        } else if (st === "ended" || st === "failed") {
            if (root._castHoldWhy === "Resizing")
                root._castHoldWhy = "";
            if (st === "ended" || root._castWasLive || root._castReconnecting)
                root._castLost(why);
            else if (root._castHoldWhy === "Reconnecting")
                root._castHoldWhy = "";
        }
    }
    // the size has settled: a mirror asks the page for its last frame, then restarts (castHoldReady, or by itself after a moment:
    // a closed popup holds nothing); a desktop resizes its screen where it is
    Timer {
        id: castResize
        interval: 700
        onTriggered: {
            if (root.castTurning)
                return;
            if (root._deskResizeWanted()) {
                const t = root._deskSize();
                root._castDeskW = t.w;
                root._castDeskH = t.h;
                castLoader.item.resize(t.w, t.h);
                return;
            }
            if (!root._reloadWanted())
                return;
            root._castHoldWhy = "Resizing";
            castHoldWait.restart();
        }
    }
    // a session that stayed live this long gives the reconnect its tries back
    Timer {
        id: castStable
        interval: 10000
        onTriggered: root._castTries = 0
    }
    // the wait of a reconnect is over: walk the transport again, then start
    Timer {
        id: castReconnect
        onTriggered: {
            if (root._castKey !== "" && root._castReconnecting && !root._castPrep)
                root._castPrepRun(root._castKey, false);
        }
    }
    Timer {
        id: castHoldWait
        interval: 250
        onTriggered: root._castReloadGo()
    }
    // the cast goes on behind a closed popup for a while, then stops (and the page goes home)
    Timer {
        id: castExpiry
        interval: Math.max(5, root.settings.cast.closeAfterS) * 1000
        running: root._castKey !== "" && !root.popupOpen
        onTriggered: {
            root.castStop();
            if (root.page === "cast")
                root.page = "";
        }
    }

    ActionRunner {
        id: toolRunner
        toolPath: root.toolPath
        python: root.python
        launcher: root.launcher
        toolPresent: root._haveTool
        timeoutOverrideMs: root.timeoutOverrideMs
    }
    // The watcher exists only while live: not live, no Process object is anywhere in this service.
    Instantiator {
        model: root.live ? 1 : 0
        delegate: SupervisedStream {
            what: "BridgeService: `lares-bridge watch`"
            enabled: root.live && root._haveTool
            command: root.launcher.concat([root.python, "-u", root.toolPath, "watch"])
            onLine: text => root._onLine(text)
        }
    }

    function _complain(what: string): void {
        if (root._warned[what] === true)
            return;
        root._warned[what] = true;
        console.warn("BridgeService: " + what);
    }

    // ---- a line ------------------------------------------------------------------------------------------------------
    // One line of `watch` (or of a scenario). A line the parser refuses changes nothing; the first of each kind is logged.
    function _onLine(text: string): bool {
        if (String(text).trim() === "")
            return false;
        const r = Model.parseLine(text);
        if (!r.ok) {
            root._lastError = r.error;
            root._complain("a line was refused (" + r.error + ")");
            return false;
        }
        root._accept(r.line);
        return true;
    }

    function _accept(line: var): void {
        root._line = line;
        root._syncRows(line.devices);
        root._currentKey = line.current;
        root._current = root.device(line.current);
        root._pairing = line.pairing;
        root._jobs = line.jobs;
        root._wifiPair = line.wifiPair;
        root._env = line.env;
        root._lastError = "";
        root._reconcileActs(line.current);
        root._reconcileJobs(line.jobs);
        root._factsAsk();
        root._usbAsk();
        // at the shell's start no cast runs: a hold a crash left on a phone goes back (the tool keeps the record until it can)
        if (!root._ready && root.live)
            toolRunner.run("", Model.argvOf("castend", "", { all: true }), res => {}, { timeoutMs: Model.timeoutOf("castend") });
        root._ready = true;
        root._serial++;
    }

    Component {
        id: rowRecord
        QtObject {
            property var d: ({})
        }
    }

    function _rowIndex(key: string): int {
        for (let i = 0; i < devicesModel.count; i++)
            if (devicesModel.get(i).key === key)
                return i;
        return -1;
    }

    // The rows follow the line by key: a row that stays keeps its `rec` (a Repeater over `devices` regenerates nothing), `d` is
    // re-assigned only when it differs, a new order is `move`s.
    function _syncRows(devs: var): void {
        const keys = devs.map(d => d.key);
        const diff = Model.diffKeys(root._keys, keys);
        for (let r = 0; r < diff.removed.length; r++) {
            const k = diff.removed[r];
            const idx = root._rowIndex(k);
            if (idx >= 0) {
                const dead = devicesModel.get(idx).rec;
                devicesModel.remove(idx);
                dead.destroy();
            }
            delete root._byKey[k];
            delete root._sigs[k];
        }
        for (let i = 0; i < devs.length; i++) {
            const d = devs[i];
            const sig = JSON.stringify(d);
            if (!Object.prototype.hasOwnProperty.call(root._byKey, d.key)) {
                const fresh = rowRecord.createObject(root, { d: d });
                devicesModel.insert(i, { key: d.key, rec: fresh });
                root._byKey[d.key] = fresh;
                root._sigs[d.key] = sig;
                continue;
            }
            if (i < devicesModel.count && devicesModel.get(i).key !== d.key)
                devicesModel.move(root._rowIndex(d.key), i, 1);
            if (sig !== root._sigs[d.key]) {
                root._byKey[d.key].d = d;
                root._sigs[d.key] = sig;
            }
        }
        root._keys = keys;
        if (diff.changed)
            root._rowSerial++;
    }

    // ---- the acts ----------------------------------------------------------------------------------------------------
    property var _inflight: ({})       // "<device key>|<act>" -> true while its one-shot is out
    property var _actCan: ({})         // act -> the JSON of the `can` entry it settled on
    property string _actsKey: ""

    function _setAct(ak: string, state: string, why: string, hint: string): void {
        const a = Object.assign({}, root._acts);
        a[ak] = { state: state, why: why, hint: hint, at: Date.now() };
        root._acts = a;
        if (state === "done" || state === "failed")
            root._actCan[ak] = JSON.stringify(Model.canOf(root._current, ak));
        else
            delete root._actCan[ak];
    }

    // The device changed: everything idle, and what is out for the new current device is busy.
    function _rebuildActs(): void {
        const a = Model.idleActs();
        for (const f in root._inflight) {
            const at = f.lastIndexOf("|");
            if (f.slice(0, at) === root._currentKey && a[f.slice(at + 1)] !== undefined)
                a[f.slice(at + 1)] = { state: "busy", why: "", hint: "", at: Date.now() };
        }
        root._acts = a;
        root._actCan = ({});
    }

    // A settled act goes back to idle when the `can` it settled on changes.
    function _reconcileActs(current: string): void {
        if (root._actsKey !== current) {
            root._actsKey = current;
            root._rebuildActs();
            return;
        }
        let a = null;
        for (const ak in root._actCan) {
            if (JSON.stringify(Model.canOf(root._current, ak)) === root._actCan[ak])
                continue;
            if (a === null)
                a = Object.assign({}, root._acts);
            a[ak] = { state: "idle", why: "", hint: "", at: Date.now() };
            delete root._actCan[ak];
        }
        if (a !== null)
            root._acts = a;
    }

    // ---- asking the tool ---------------------------------------------------------------------------------------------
    function _ask(action: string, key: string, args: var, stdin: var): bool {
        const k = key === undefined || key === null ? "" : String(key);
        const ak = Model.actKey(action, args ? args.which : undefined);
        const argv = Model.argvOf(action, k, args);
        if (argv === null)
            return false;
        const flight = ak !== "" ? k + "|" + ak : "";
        if (flight !== "" && root._inflight[flight] === true)
            return false;
        root._record(action, k, args);
        if (flight !== "") {
            root._inflight[flight] = true;
            if (k === root._currentKey)
                root._setAct(ak, "busy", "", "");
        }
        if (!root.live) {
            root._mockQueue.push({ action: action, key: k, args: args, ak: ak, flight: flight });
            mockAnswer.restart();
            return true;
        }
        toolRunner.run(k, argv, res => root._answered(action, k, args, ak, flight, res),
                       { timeoutMs: Model.timeoutOf(action), stdin: typeof stdin === "string" ? stdin : undefined });
        return true;
    }

    // The one-shot's answer: { ok, reason, hint, answer }.
    function _answered(action: string, key: string, args: var, ak: string, flight: string, res: var): void {
        if (flight !== "")
            delete root._inflight[flight];
        const ok = res.ok === true;
        const why = ok ? "" : String(res.reason || "");
        const hint = ok ? "" : String(res.hint || "");
        if (ak !== "" && key === root._currentKey)
            root._setAct(ak, ok ? "done" : "failed", why, hint);
        if (ok && action === "shot")
            root._showShot(key, String((res.answer && res.answer.path) || ""));
        // A send over KDE Connect is no job (the daemon takes the files and reports nothing back): its one toast is
        // posted here, and says what is known -- handed over, not arrived.
        if (ok && action === "send" && res.answer && res.answer.via === "kdeconnect" && root.notifier) {
            const n = args && args.paths ? args.paths.length : 0;
            root.notifier.notify("sent-" + key, { title: (n === 1 ? "1 file" : n + " files") + " handed to " + root._nameOf(key),
                                                 body: "Over Wi-Fi", urgency: "low", timeoutMs: 6000 });
        }
        if (action === "unlock" && root._castUnlocking)
            Qt.callLater(root._castUnlockDone);
        // the USB setting changed: read the phone's facts again (the Details row)
        if (ok && action === "usbcalm")
            root.loadFacts(key);
        if (!ok)
            root._failed(action, ak, key, why, hint);
        if (action !== "ack")
            root.acted(key, ak !== "" ? ak : action, ok, why);
    }

    function _nameOf(key: string): string {
        const d = root.device(key);
        return d ? d.name : key;
    }

    // A one-shot that failed: a mirror or a mount is one toast (not while the popup shows it), a send is its closing toast.
    function _failed(action: string, ak: string, key: string, why: string, hint: string): void {
        if (!root.notifier)
            return;
        const name = root._nameOf(key);
        if (action === "send") {
            const t = Model.failureWords("Could not send to " + name, why, hint);
            root.notifier.notify("sent-" + key, t);
        } else if (action === "unlock" && root._unlockToastable(why)) {
            root.notifier.notify("fail-" + key + "-unlock", Model.failureWords("Could not unlock " + name, why, hint));
        } else if (!root.popupOpen && (action === "mirror" || action === "mount")) {
            const w = Model.failureWords(action === "mirror" ? "Could not mirror " + name : "Could not mount " + name, why, hint);
            root.notifier.notify("fail-" + key + "-" + ak, w);
        }
    }

    // An unlock's failure is told when it is news: the PIN failed, or the lock screen would not take it. A phone out of reach, a
    // locked keyring or no PIN kept are what the Details page says, and an unlock already under way is no failure.
    function _unlockToastable(why: string): bool {
        return why === "The PIN did not unlock the phone" || why === "The lock screen did not take the keys";
    }

    // A shot: the OSD's capture card where there is an OSD, else one toast.
    function _showShot(key: string, path: string): void {
        if (path === "")
            return;
        const req = { kind: "capture", key: "shot", source: "bridge", capture: { what: "shot", path: path, thumb: Model.fileUrl(path), copied: false, label: "" } };
        let shown = false;
        if (root.osd) {
            try {
                shown = root.osd.show(req) === true;
            } catch (e) {
                shown = false;
            }
        }
        if (!shown && root.notifier && !root.popupOpen)
            root.notifier.notify("shot-" + key, { title: "Screenshot of " + root._nameOf(key), body: path, urgency: "low", timeoutMs: 5000 });
    }

    // ---- jobs: toasts and acknowledgements ---------------------------------------------------------------------------
    property var _handled: ({})        // ended job id -> true: told and acknowledged
    property var _progressUp: ({})     // running send id -> the body its toast shows

    function _reconcileJobs(jobs: var): void {
        const present = {};
        for (let i = 0; i < jobs.length; i++) {
            const j = jobs[i];
            present[j.id] = true;
            if (j.phase === "starting" || j.phase === "running") {
                if (j.kind === "send")
                    root._progress(j);
                continue;
            }
            if (root._handled[j.id] === true)
                continue;
            root._handled[j.id] = true;
            root._ended(j);
        }
        for (const id in root._handled)
            if (present[id] !== true)
                delete root._handled[id];
        // a send that went without ending (the record vanished): its progress toast goes
        for (const id in root._progressUp)
            if (present[id] !== true) {
                delete root._progressUp[id];
                if (root.notifier)
                    root.notifier.withdraw("send-" + id);
            }
    }

    // The progress of a running send, in place; none while the popup shows it.
    function _progress(j: var): void {
        if (!root.notifier || root.popupOpen)
            return;
        const body = Model.sendBody(j);
        if (root._progressUp[j.id] === body)
            return;
        root._progressUp[j.id] = body;
        root.notifier.notify("send-" + j.id, { live: true, title: "Sending to " + root._nameOf(j.device), body: body, urgency: "low", timeoutMs: 0 });
    }

    // A job ended: its toast, then its acknowledgement.
    function _ended(j: var): void {
        const t = Model.endedToast(j, root._nameOf(j.device), root.device(j.device));
        if (root.notifier) {
            if (j.kind === "send" && t !== null) {
                // the closing toast takes the progress toast's place in ONE turn: posted, then the progress withdrawn
                root.notifier.notify("sent-" + j.id, t);
                if (root._progressUp[j.id] !== undefined) {
                    delete root._progressUp[j.id];
                    root.notifier.withdraw("send-" + j.id);
                }
            } else if (t !== null && !root.popupOpen) {
                root.notifier.notify("fail-" + j.id, t);
            }
        }
        root._ask("ack", "", { id: j.id });
    }

    // The popup opened: its own page shows the transfer, so the progress toast goes; closed: the running sends are told again.
    onPopupOpenChanged: {
        if (!root._started)
            return;
        if (root.popupOpen) {
            for (const id in root._progressUp) {
                delete root._progressUp[id];
                if (root.notifier)
                    root.notifier.withdraw("send-" + id);
            }
            root._usbDue = true;
            root._usbAsk();
            root._factsDue = true;
            root._factsAsk();
        } else {
            root._factsDue = false;
            root._usbDue = false;
            for (let i = 0; i < root._jobs.length; i++)
                if (root._jobs[i].kind === "send" && (root._jobs[i].phase === "starting" || root._jobs[i].phase === "running"))
                    root._progress(root._jobs[i]);
        }
    }

    // ---- the phone's USB at an unlock ----------------------------------------------------------------------------------
    // "Default USB configuration = File transfer" makes Android switch the USB functions at every lock and unlock, which restarts
    // adbd and drops every adb connection (a cast ends). The bridge turns it off itself: once per popup open, when the phone's
    // facts say it is on and the user has not chosen it on (Details: `prefs.usbUnlockMtp`), never again in that open (a failure
    // included).
    property bool _usbDue: false
    function _usbAsk(): void {
        if (!root._usbDue || !root.popupOpen || !root._ready || root._currentKey === "")
            return;
        const d = root._current;
        if (!d || !d.facts || d.facts.usbUnlocked === "" || d.facts.usbUnlocked === "none" || d.prefs.usbUnlockMtp === true)
            return;
        if (!Model.canOf(d, "facts").ok)
            return;
        root._usbDue = false;
        root._ask("usbcalm", root._currentKey, { on: false });
    }
    // By hand (Details): on = the phone's own "File transfer", off = the bridge's default
    function usbCalm(key: string, on: bool): bool {
        return root._ask("usbcalm", key, { on: on });
    }

    // ---- facts at the popup's open -----------------------------------------------------------------------------------
    property bool _factsDue: false
    function _factsAsk(): void {
        if (!root._factsDue || !root.popupOpen || !root._ready || root._currentKey === "")
            return;
        if (root.loadFacts(root._currentKey))
            root._factsDue = false;
    }

    // ---- the file picker ---------------------------------------------------------------------------------------------
    Component {
        id: pickComp
        Item {
            id: pk
            property string devKey: ""
            property var argv: []
            readonly property alias proc: pp
            Process {
                id: pp
                command: pk.argv
                stdout: StdioCollector {
                    id: po
                }
            }
            Connections {
                target: pp
                function onExited(code) {
                    root._picked(pk.devKey, code, String(po.text || ""));
                    pk.destroy();
                }
            }
        }
    }

    function _picked(key: string, code: int, out: string): void {
        root._picking = false;
        if (code === 1)
            return;     // cancelled
        if (code !== 0) {
            root._answered("pickAndSend", key, {}, "send", "", { ok: false, reason: "the file picker failed (exit " + code + ")", hint: "", answer: ({}) });
            return;
        }
        const paths = out.split("\u0000").filter(p => p !== "");
        if (paths.length > 0)
            root.send(key, paths);
    }

    // ---- the mock ----------------------------------------------------------------------------------------------------
    property var _mockQueue: []
    property var _seq: []

    // The mock's answer to an action: where the device can do it, the scenario's reaction moves the state; where it cannot, the
    // answer is the tool's own `can` words (a button that is disabled is never asked, but a key may).
    Timer {
        id: mockAnswer
        interval: root.mockAnswerMs
        onTriggered: {
            const q = root._mockQueue;
            root._mockQueue = [];
            for (let i = 0; i < q.length; i++)
                root._mockOne(q[i]);
        }
    }
    function _mockOne(c: var): void {
        const d = root.device(c.key);
        const can = c.ak !== "" && d ? Model.canOf(d, c.ak) : null;
        let res = null;
        if (c.ak !== "" && !d) {
            res = { ok: false, reason: "there is no such device", hint: "", answer: ({}) };
        } else if (can && !can.ok) {
            res = { ok: false, reason: can.why, hint: can.hint, answer: ({}) };
        } else {
            if (root._line)
                root._onLine(JSON.stringify(Scenarios.react(root._line, c.action, c.key, c.args)));
            const ans = { ok: true };
            if (c.action === "shot")
                ans.path = String(root.settings.shots.dir).replace(/^~/, Quickshell.env("HOME") || "") + "/phone-mock.png";
            res = { ok: true, reason: "", hint: "", answer: ans };
        }
        root._answered(c.action, c.key, c.args, c.ak, c.flight, res);
    }

    // A mock send's figures step while it runs.
    Timer {
        interval: root.mockStepMs
        repeat: true
        running: !root.live && root.mockStepMs > 0 && root.busy
        onTriggered: {
            const n = root._line ? Scenarios.step(root._line) : null;
            if (n)
                root._onLine(JSON.stringify(n));
        }
    }

    // A scenario's lines after the first arrive one per `mockLineMs`.
    Timer {
        id: seqTimer
        interval: Math.max(1, root.mockLineMs)
        repeat: true
        onTriggered: root._nextSeq()
    }
    function _nextSeq(): void {
        if (root._seq.length === 0) {
            seqTimer.stop();
            return;
        }
        const t = root._seq[0];
        root._seq = root._seq.slice(1);
        root._onLine(t);
        if (root._seq.length === 0)
            seqTimer.stop();
    }
    function _feedScenario(): void {
        seqTimer.stop();
        root._seq = [];
        if (root.live || root.scenario === "")
            return;
        const ls = Scenarios.lines(root.scenario);
        if (ls === null) {
            root._complain("there is no scenario " + root.scenario);
            return;
        }
        root._onLine(ls[0]);
        root._seq = ls.slice(1);
        if (root._seq.length === 0)
            return;
        if (root.mockLineMs > 0)
            seqTimer.restart();
        else
            while (root._seq.length > 0)
                root._nextSeq();
    }
    onScenarioChanged: if (root._started) root._feedScenario()
    onLiveChanged: if (root._started) root._feedScenario()

    // Idempotent; the first look is the build's own completion.
    function ensureLoaded(): void {
        if (root._started)
            return;
        root._started = true;
        cfg.ensureLoaded();
        root._feedScenario();
    }
    Component.onCompleted: root.ensureLoaded()
}
