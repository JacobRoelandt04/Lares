pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "popup"
import "LockProtocol.js" as Proto

// =============================================================================
// LockOwner.qml -- the shell's side of the lock: it listens for the lock
// process, mirrors its state, and shows LockPopup in the real bar's popup slot
// on every screen while the session is locked.
//
// The lock is a SEPARATE process (lock/shell.qml) that owns the keyboard, the
// password and the session lock. The shell only draws: Hyprland's `above_lock`
// layer rule puts the shell's bar layers (namespace `lares-bar`) over the lock
// surface, they take no input, and the popup that hangs from them is what the
// user reads while typing. Nothing here can unlock anything: the wire's shell ->
// lock messages are `shown`, `hints` and `retracted`, and the lock releases on
// its own authentication (or 600 ms after `unlocking` whatever it is told).
//
// THE SOCKET. A SocketServer at LockProtocol.socketPath(XDG_RUNTIME_DIR,
// WAYLAND_DISPLAY), always listening (the directory is made first, 0700; a
// stale socket file is replaced by the server when it starts listening). ONE
// lock connection at a time: the newest wins and the older is closed -- a
// lock that crashed and came back is the newer. Every line is parsed and
// validated by LockProtocol.parse; what does not parse, or is not a lock -> shell
// message, is counted (`ignoredLines`) and dropped.
//
// THE POPUP. The assembly registers each screen's engine (`register`); while
// `wantPopup` (connected, the first state received, phase locking or locked --
// or an orphan hold, below) the owner opens LockPopup in each engine, hanging
// from that screen's bar at `anchorItem`'s centre, and opens it AGAIN if
// something else takes thePopup while locked. It closes only its own: another
// module's popup is never touched.
//   phase "unlocking" -> every engine's popup closes (the gooey retract) and
//     `retracted` is sent when they have all closed, or after `retractFailsafeMs`
//     whatever they are doing (the lock does not wait longer than 600 ms).
//   `bye` -> the popups close quietly, nothing is sent back.
//   the lock's connection drops with no `unlocking` and no `bye` (it crashed:
//     the supervisor is relaunching it or hyprlock is taking over) -> the popup
//     stays, showing what it last knew, until a new connection or `orphanMs`.
//     THE SESSION IS STILL LOCKED, though: the supervisor may have fallen back to
//     hyprlock, and the shell's layer (above_lock) must not take input, nor show a
//     toast, over it. So `locked` outlives the popup: it holds from the drop until
//     `orphanMs` has passed AND the supervisor has let go of its flock
//     ($XDG_RUNTIME_DIR/lares-lock.lock -- it holds it for the whole of the Lares lock, its
//     relaunch and the hyprlock fallback). The flock is read from the kernel's table
//     (/proc/locks; `flock -n` would TAKE it for an instant and a lock starting then
//     would find it held and never lock), once a second and ONLY while orphaned.
//
// WHAT IT TELLS THE LOCK. `shown` (the screens where the popup is visible now:
// the lock hides its own fallback card there) and `hints` per screen (the bar's
// and the popup's rects in screen-local logical px, for the step-down captures
// to mask; resent, coalesced to one per frame, as the popup resizes and moves)
// and `targets` per screen (the password field's rect, which key ripples start
// from; sent with the hints, on the same coalescing, when the popup's content moves or resizes).
// All are sent on change and again on a new connection.
//
// WHAT IT TELLS THE ASSEMBLY. `locked`: true from the moment a popup is wanted
// until the retract is over -- and, for a lock that vanished without a word, until
// its supervisor has let go of the session (see above). The assembly binds its bar
// windows' keyboard focus to none and their input region to nothing while it is
// true, brings the bars up, releases its idle inhibitor and holds notifications
// (modules/shell: ShellScreen, ShellFrame, ShellServices); this file wires none of
// it.
//
// IN A SCALED SHELL. Every rect it sends is the window's (screen-local logical px):
// the shell draws inside a ScaleRoot, so both corners of a rect are mapped and a
// size scales with them, and the popup's `renderScale` is its screen's engine's
// (device px per content px), never the attached Screen's integer ratio.
//
// GREETING NAME. `greetingName` when set, else the first word of the account's
// full name (getent passwd $USER, the GECOS field), else nothing.
// =============================================================================
Item {
    id: owner

    visible: false

    // ---- what the assembly sets ------------------------------------------------
    property string ownerId: "lock"
    property string greetingName: ""
    // lockscreen.jsonc: what the popup shows (LockPopup has the words), and what takes the pointer while the session is locked
    // ("idle", "volume", "player": ShellScreen's region).
    property var bandOrder: ["battery", "weather", "updates", "screen"]
    property var footOrder: ["music", "wiki"]
    property string greets: "boot"
    property var lockedControls: ["idle", "volume", "player"]
    // Handed to every popup (each may be null: its cell is then absent).
    property var battery: null
    property var weather: null
    property var updates: null
    // The screentime daemon's client (ScreentimeService): the band's figures
    // of today and of the session the lock just ended. null: no cell.
    property var screentime: null
    property var mpd: null
    property var wikiService: null
    property var locale: null
    // A test's own socket path; empty derives it from the environment.
    property string socketPathOverride: ""
    // false: no server at all (a MOCK shell has no lock to talk to: a server of its own would meet a stale file of the last run
    // and warn "Deleted existing file ... to create socket")
    property bool listen: true
    property int orphanMs: 6000
    // The supervisor's lock file, and how often an orphaned shell asks the kernel whether it is still held.
    property string lockFile: (Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/" + Quickshell.env("UID")) + "/lares-lock.lock"
    // Until `lares cleanup-old-name` a lock of the OLD name (an old snapshot's) holds this one instead: held when either is.
    readonly property string oldLockFile: owner.lockFile.replace(/lares-lock\.lock$/, "qs-lock.lock")
    property int heldPollMs: 1000
    property int retractFailsafeMs: 700
    // Milliseconds between the hints' sends at most (one per frame).
    property int hintCoalesceMs: 16

    // ---- what it reports -------------------------------------------------------
    readonly property alias lockState: mirror
    readonly property string socketPath: owner.socketPathOverride !== "" ? owner.socketPathOverride
        : Proto.socketPath(Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/" + Quickshell.env("UID"), Quickshell.env("WAYLAND_DISPLAY"))
    readonly property bool connected: owner._conn !== null
    // A popup is wanted on every screen: a lock is up and has spoken (or has
    // just gone quiet and is being waited for).
    readonly property bool wantPopup: (owner.connected && owner._gotState && !owner._bye && mirror.phase !== "unlocking") || owner._orphan
    // The session is locked as far as the shell is concerned (see the header).
    readonly property bool locked: owner.wantPopup || owner._retracting || owner._orphanHold
    // Screens whose popup is visible now (names).
    readonly property var shownScreens: owner._shown
    readonly property string effectiveName: owner.greetingName !== "" ? owner.greetingName : owner._derivedName
    // Counters, for probes.
    property int ignoredLines: 0
    property int linesSeen: 0
    property int retractedSent: 0

    signal retractDone()

    // The player's buttons on a screen's popup, or null when there are none to press (no popup, or no track): the shell
    // (ShellScreen) adds this item to the input region it keeps while locked. Reads what it depends on, so a binding on it follows
    // the popup coming, going and showing or hiding its card.
    function controlsFor(screenName) {
        for (const t of owner._targets) {
            if (t.screenName !== String(screenName) || !t.isMine())
                continue;
            const c = t.body.contentItem;
            const m = c && c.mediaControls ? c.mediaControls : null;
            return m && m.visible && m.enabled && m.width > 0 ? m : null;
        }
        return null;
    }

    // ---- registering screens -----------------------------------------------------
    // One call per screen, when its engine and bar exist. `anchorItem` is what
    // the popup hangs from (its centre along the bar); null centres it on the bar.
    function register(screenName, engine, bar, barId, anchorItem) {
        owner.unregister(screenName);
        const t = targetComp.createObject(owner, {
            screenName: String(screenName),
            engine: engine,
            bar: bar,
            barId: barId,
            anchorItem: anchorItem
        });
        owner._targets = owner._targets.concat([t]);
        owner._syncAll();
    }
    function unregister(screenName) {
        const keep = [];
        for (const t of owner._targets) {
            if (t.screenName === String(screenName))
                t.destroy();
            else
                keep.push(t);
        }
        owner._targets = keep;
        owner._noteShown();
    }

    // ---- internals -----------------------------------------------------------------
    property var _targets: []
    property var _conn: null
    property bool _gotState: false
    property bool _bye: false
    property bool _orphan: false
    // The lock vanished without a word and its supervisor may still hold the session (see the header).
    property bool _orphanHold: false
    property bool _retracting: false
    property var _shown: []
    property string _derivedName: ""
    property string _sentShown: ""

    LockState {
        id: mirror
    }

    // ---- one screen -----------------------------------------------------------------------
    Component {
        id: targetComp
        Item {
            id: t
            property string screenName: ""
            property var engine: null
            property var bar: null
            property string barId: ""
            property var anchorItem: null

            // The popup, at THIS screen's engine's renderScale (device px per popup content px: the shell's configured scale x
            // the popup ratio). Not the attached Screen's ratio, which at a fractional Hyprland scale is the INTEGER wl_output's.
            readonly property Component popupComponent: Component {
                LockPopup {
                    lockState: mirror
                    battery: owner.battery
                    weather: owner.weather
                    updates: owner.updates
                    screentime: owner.screentime
                    mpd: owner.mpd
                    wikiService: owner.wikiService
                    locale: owner.locale
                    greetingName: owner.effectiveName
                    bandOrder: owner.bandOrder
                    footOrder: owner.footOrder
                    greets: owner.greets
                    active: mirror.awake
                    renderScale: t.engine && t.engine.renderScale > 0 ? t.engine.renderScale : 1
                }
            }

            readonly property var body: t.engine ? t.engine.thePopup : null
            // The popup on this screen is ours (opening, open, moving or closing).
            readonly property bool mine: !!t.engine && t.engine.popupOwnerId === owner.ownerId
                && !!t.body && t.body.phase !== "closed"
            readonly property bool live: !!t.engine && t.engine.popupOpen && t.engine.popupOwnerId === owner.ownerId
            readonly property bool visibleNow: t.live && !!t.body && t.body.popH > 8 && t.body.popW > 8

            // Read live: a handler that runs on a phase change may run before
            // the `mine` binding has re-evaluated (a stale answer held the
            // retract until its failsafe).
            function isMine() {
                const b = t.engine ? t.engine.thePopup : null;
                return !!b && t.engine.popupOwnerId === owner.ownerId && b.phase !== "closed";
            }
            function centre() {
                if (t.anchorItem && t.bar)
                    return t.anchorItem.mapToItem(t.bar, t.anchorItem.width / 2, t.anchorItem.height / 2).x;
                return t.bar ? t.bar.width / 2 : 0;
            }
            function open() {
                if (!t.engine || !t.bar)
                    return;
                t.engine.open(owner.ownerId, t.barId, t.centre(), null, null, false, t.popupComponent, 1);
            }
            // Bring this screen in line with what the owner wants.
            function sync() {
                if (!t.engine)
                    return;
                if (owner.wantPopup) {
                    if (!t.live)
                        t.open();
                } else if (t.isMine() && t.body.phase !== "closing") {
                    t.engine.close();
                }
            }
            // A rect of `item`'s own coordinates as a rect of the window (screen-local logical px): BOTH corners map, because the shell
            // draws inside a scaled frame (a ScaleRoot of the configured scale over the window's ratio) and a width is scaled too.
            function inWindow(item, x, y, w, h) {
                const a = item.mapToItem(null, x, y);
                const b = item.mapToItem(null, x + w, y + h);
                const x0 = Math.round(a.x);
                const y0 = Math.round(a.y);
                return [x0, y0, Math.round(b.x) - x0, Math.round(b.y) - y0];
            }
            // Where the popup's field is, screen-local logical px; null
            // while this screen's popup is not up with its content.
            function targetRects() {
                const eng = t.engine;
                const c = t.isMine() ? t.body.contentItem : null;
                if (!eng || !c || c.fieldRect === undefined)
                    return null;
                const r = c.fieldRect;
                return { field: r ? t.inWindow(c, r[0], r[1], r[2], r[3]) : null };
            }

            // The rects the compositor-side captures must leave out: every bar of this screen that has an area (the islands and the
            // slim bars are all the shell's surfaces over the lock), the clock's own first, and the popup.
            function rects() {
                const out = [];
                const eng = t.engine;
                if (!eng)
                    return out;
                const bars = [];
                if (t.bar)
                    bars.push(t.bar);
                for (const b of eng.barsList) {
                    if (b && b !== t.bar)
                        bars.push(b);
                }
                for (const b of bars) {
                    if (b.absW > 0 && b.absH > 0)
                        out.push(t.inWindow(eng, b.absX, b.absY, b.absW, b.absH));
                }
                const p = t.popupRect();
                if (p)
                    out.push(p);
                return out;
            }
            // The two the veil reads, NAMED (Proto.hints): the bar the popup hangs from, and the popup while it is ours.
            function barRect() {
                const b = t.bar, eng = t.engine;
                return eng && b && b.absW > 0 && b.absH > 0 ? t.inWindow(eng, b.absX, b.absY, b.absW, b.absH) : null;
            }
            function popupRect() {
                const eng = t.engine;
                return eng && t.isMine() && t.body.popW > 0 && t.body.popH > 0 ? t.inWindow(eng, t.body.popX, t.body.popY, t.body.popW, t.body.popH) : null;
            }

            Connections {
                target: t.engine
                ignoreUnknownSignals: true
                // Something took the popup slot (or it closed under us): a
                // locked session shows its popup again.
                function onPopupOwnerIdChanged() {
                    Qt.callLater(t.sync);
                    owner._noteChange();
                }
                function onPopupOpenChanged() {
                    Qt.callLater(t.sync);
                    owner._noteChange();
                }
            }
            Connections {
                target: t.body
                ignoreUnknownSignals: true
                function onPhaseChanged() {
                    owner._noteChange();
                }
                function onPopXChanged() { owner._noteHints(); }
                function onPopYChanged() { owner._noteHints(); }
                function onPopWChanged() { owner._noteHints(); }
                function onPopHChanged() { owner._noteHints(); }
                function onContentItemChanged() { owner._noteHints(); }
            }
            // The content's own geometry: the field's and the glyph's rects move
            // with it (a resize, a face appearing) without the box moving.
            Connections {
                target: t.body ? t.body.contentItem : null
                ignoreUnknownSignals: true
                function onFieldRectChanged() { owner._noteHints(); }
                function onFaceRectChanged() { owner._noteHints(); }
                function onXChanged() { owner._noteHints(); }
                function onYChanged() { owner._noteHints(); }
                function onWidthChanged() { owner._noteHints(); }
                function onHeightChanged() { owner._noteHints(); }
            }
        }
    }

    function _syncAll() {
        for (const t of owner._targets)
            t.sync();
    }
    // Something about who shows what changed: shown, hints and the retract.
    function _noteChange() {
        owner._noteShown();
        owner._noteHints();
        owner._checkRetract();
    }
    function _noteShown() {
        const names = [];
        for (const t of owner._targets) {
            if (t.visibleNow)
                names.push(t.screenName);
        }
        names.sort();
        if (JSON.stringify(names) !== JSON.stringify(owner._shown))
            owner._shown = names;
        shownTimer.restart();
    }
    // ONE handler for wantPopup: a second `onWantPopupChanged:` in the same object is "Property value set multiple times"
    // and the file does not load. As the lock comes up the band's screen time is taken, first, so the request is out
    // before the popups show: it is a snapshot, the service takes one per session and listens to nothing in between
    // (screentime CONTRACT §9). Then the popups follow wantPopup, and the change is told.
    onWantPopupChanged: {
        if (owner.wantPopup && owner.screentime)
            owner.screentime.refresh();
        owner._syncAll();
        owner._noteChange();
    }
    onLockedChanged: if (!owner.locked)
        owner._noteChange()

    // ---- the wire ---------------------------------------------------------------------------
    function _send(line) {
        const c = owner._conn;
        if (!c || !c.connected)
            return;
        c.write(line + "\n");
        c.flush();
    }
    function _sendShown() {
        const line = Proto.shown(owner._shown);
        if (line === owner._sentShown)
            return;
        owner._sentShown = line;
        owner._send(line);
    }
    Timer {
        id: shownTimer
        interval: 0
        onTriggered: owner._sendShown()
    }

    property var _sentHints: ({})
    property var _sentTargets: ({})
    function _noteHints() {
        hintTimer.start();
    }
    Timer {
        id: hintTimer
        interval: owner.hintCoalesceMs
        onTriggered: owner._sendHints(false)
    }
    function _sendHints(all) {
        for (const t of owner._targets) {
            const line = Proto.hints(t.screenName, t.rects(), t.barRect(), t.popupRect());
            if (all || owner._sentHints[t.screenName] !== line) {
                owner._sentHints[t.screenName] = line;
                owner._send(line);
            }
            const tr = t.targetRects();
            if (tr) {
                const tl = Proto.targets(t.screenName, tr.field);
                if (all || owner._sentTargets[t.screenName] !== tl) {
                    owner._sentTargets[t.screenName] = tl;
                    owner._send(tl);
                }
            }
        }
    }

    function _onLine(conn, line) {
        if (conn !== owner._conn)
            return;
        owner.linesSeen++;
        const r = Proto.parse(line);
        if (!r.ok) {
            owner.ignoredLines++;
            return;
        }
        const m = r.msg;
        switch (m.t) {
        case "hello":
            owner._send(Proto.hello());
            owner._sentShown = "";
            owner._sendShown();
            owner._sendHints(true);
            break;
        case "state":
            Proto.applyState(mirror, m.s);
            owner._gotState = true;
            owner._syncAll();
            break;
        case "bye":
            owner._bye = true;
            owner._orphan = false;
            owner._endOrphanHold();
            orphanTimer.stop();
            owner._syncAll();
            // The lock is about to go: close from THIS end, or the shell's
            // long-lived log gets a PeerClosedError at every unlock (Quickshell
            // logs a close from the peer's end as an error; whoever closes
            // decides which log has it, and the lock drops its end too).
            Qt.callLater(() => { if (conn) conn.connected = false; });
            break;
        default:
            // shown / hints / retracted go the other way: not ours to act on.
            owner.ignoredLines++;
        }
    }

    function _adopt(conn) {
        const old = owner._conn;
        owner._conn = conn;
        owner._gotState = false;
        owner._bye = false;
        owner._orphan = false;
        owner._endOrphanHold();
        orphanTimer.stop();
        if (old && old !== conn)
            old.connected = false;
    }
    function _gone(conn) {
        if (conn !== owner._conn)
            return;
        owner._conn = null;
        // No unlocking and no bye: the lock died. Hold what it last showed.
        if (!owner._bye && owner._gotState && mirror.phase !== "unlocking") {
            owner._orphan = true;
            owner._orphanHold = true;
            heldPoll.stop();
            orphanTimer.restart();
        }
        owner._gotState = false;
    }
    Timer {
        id: orphanTimer
        interval: owner.orphanMs
        onTriggered: {
            // The popup goes (what it shows is a dead lock's last picture); `locked` stays while the supervisor holds the session.
            owner._orphan = false;
            owner._syncAll();
            owner._askHeld();
            heldPoll.start();
        }
    }
    // After orphanMs, once a second and only while orphaned: is the supervisor's flock still held?
    Timer {
        id: heldPoll
        interval: owner.heldPollMs
        repeat: true
        onTriggered: owner._askHeld()
    }
    function _askHeld() {
        if (!heldProc.running)
            heldProc.running = true;
    }
    function _endOrphanHold() {
        heldPoll.stop();
        if (owner._orphanHold)
            owner._orphanHold = false;
    }
    // The kernel's table, which takes nothing: a FLOCK line whose MAJ:MIN:INO is the lock file's (hex major:minor, decimal inode).
    // Exit 0 = held, 1 = free (a lock file that is not there is free).
    Process {
        id: heldProc
        command: ["sh", "-c", 'for f in "$1" "$2"; do [ -e "$f" ] || continue; k=$(printf "%02x:%02x:%d" $(stat -c "%Hd %Ld %i" -- "$f")) || continue; grep -F -- " $k " /proc/locks | grep -q FLOCK && exit 0; done; exit 1',
                  "sh", owner.lockFile, owner.oldLockFile]
        onExited: exitCode => {
            // A late answer to a question nobody is asking any more (a new lock connected meanwhile) is nothing.
            if (exitCode !== 0 && heldPoll.running)
                owner._endOrphanHold();
        }
    }

    // ---- the retract --------------------------------------------------------------------------
    Connections {
        target: mirror
        function onPhaseChanged() {
            if (mirror.phase === "unlocking" && owner.connected)
                owner._beginRetract();
        }
    }
    function _beginRetract() {
        owner._retracting = true;
        owner._syncAll();
        failsafe.restart();
        owner._checkRetract();
    }
    function _checkRetract() {
        if (!owner._retracting)
            return;
        for (const t of owner._targets) {
            if (t.isMine())
                return;
        }
        owner._finishRetract();
    }
    function _finishRetract() {
        failsafe.stop();
        if (!owner._retracting)
            return;
        owner._retracting = false;
        owner.retractedSent++;
        owner._send(Proto.retracted());
        owner.retractDone();
    }
    Timer {
        id: failsafe
        interval: owner.retractFailsafeMs
        onTriggered: owner._finishRetract()
    }

    // ---- the server ------------------------------------------------------------------------------
    Process {
        id: mkdir
        command: ["mkdir", "-p", "-m", "700", Proto.socketDir(Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/" + Quickshell.env("UID"))]
        running: owner.listen && owner.socketPathOverride === ""
        onRunningChanged: if (!mkdir.running)
            server.active = true
    }
    // A test's own path: its directory is the test's to make.
    Component.onCompleted: {
        if (owner.listen && owner.socketPathOverride !== "")
            server.active = true;
    }
    SocketServer {
        id: server
        active: false
        path: owner.socketPath
        handler: Socket {
            id: conn
            parser: SplitParser {
                onRead: line => owner._onLine(conn, line)
            }
            onConnectedChanged: {
                if (!conn.connected)
                    owner._gone(conn);
            }
            Component.onCompleted: owner._adopt(conn)
        }
    }

    // ---- the name -----------------------------------------------------------------------------------
    Process {
        id: nameProc
        command: ["getent", "passwd", Quickshell.env("USER") || ""]
        running: owner.greetingName === "" && (Quickshell.env("USER") || "") !== ""
        stdout: StdioCollector {
            onStreamFinished: {
                // name:passwd:uid:gid:GECOS:home:shell -- GECOS "Full Name,room,..."
                const f = this.text.trim().split(":");
                const full = f.length > 4 ? f[4].split(",")[0].trim() : "";
                owner._derivedName = full.length > 0 ? full.split(/\s+/)[0] : "";
            }
        }
    }
}
