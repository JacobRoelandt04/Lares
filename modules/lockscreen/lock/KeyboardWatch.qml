pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// =============================================================================
// KeyboardWatch.qml -- does a lock surface hold the keyboard? If none does, get it back.
//
// THE FAULT: after a resume the lock takes no typing.
// A suspend takes the seat's keyboards away (aquamarine: "Disabling seat", every libinput device removed) and gives them
// back on resume. When the seat has no keyboard its clients drop their wl_keyboard and Qt deactivates the window; when one
// returns the client makes a new wl_keyboard, and Hyprland sends it no `enter` -- the focus has not CHANGED, so as far as
// the compositor goes the lock surface has it already. The surface is `Window.active == false` from then on and hears no
// key (a virtual keyboard that goes and comes back reproduces it).
//
// WHAT DOES NOT BRING IT BACK (measured): moving the pointer over the
// same output, a dispatched focus of the monitor, dpms off and on, re-applying the monitor, re-sending the keyboard layout, an
// exclusive keyboard layer of our own above the lock with above_lock = 2 (Hyprland gives no layer the keyboard while the session is
// locked), toggling `visible` (a lock surface's is read-only) and swapping `WlSessionLock.surface` (refused while the lock is
// active). A headless output made and not hopped to does nothing either.
//
// WHAT DOES (measured, 1 and 2 outputs, the screen sampled the whole time: not one frame but the lock's): THE HOP. The focus
// CHANGES when the pointer goes to another output and comes back, so Hyprland sends `enter` to the surface it lands on. With two
// real outputs that is the other one; with ONE there is none, so a HEADLESS output is made for the moment (the lock gives it a
// surface of its own, the pointer is put on it, and back where it was, and the output goes again). `tools/lockscreen/lares-lock-hop`
// does the hyprctl calls; the order is this file's. NOTHING of this is drawn: the lock surface the user sees stays up throughout,
// which is the whole point -- a NEW LOCK leaves the session on Hyprland's lockdead screen, the sad
// face, from the moment the old lock exits until the new one has a surface (0.5 s measured here, 1.1 s on the user's machine), and
// `misc:lockdead_screen_delay` does NOT hold it back (measured: 5000 changed nothing -- it is the delay AFTER the screen appears).
// The new lock is the last resort, `rekey`, for a hop that did not bring the keyboard back twice.
//
// WHEN IT ACTS. Locked (not locking, not unlocking), no surface active for `deadMs` -- counted from the last surface to
// lose the keyboard, from the lock becoming secure and from every resume -- AND the seat has a keyboard (`hyprctl -j
// devices`: acting before they are back would do nothing: there is no wl_keyboard to enter) AND a key sent to the seat
// does not arrive. "Active" is Qt's word and is not the keyboard: when an output goes while locked Qt deactivates the
// window of the surviving one, and the keys still reach it (a new lock there would be asked for nothing). So the last test is the key itself: `wtype -k F24` (a key no keyboard has) is sent, the surfaces
// hand it to `heard()` instead of the password, and it arriving ends the wait -- the keyboard is alive, Qt only lost track.
// Without the tool (or if it fails) the missing activity stands. Without a keyboard in the seat it looks again every
// `recheckMs`. A surface that is active at any time ends the wait. After a hop the whole check is made again (`verifyMs`); the
// second hop that fails asks for the new lock. Nothing here unlocks anything.
// =============================================================================
Scope {
    id: root

    // ---- wiring (LockRoot) -----------------------------------------------------------
    // surfaces holding the keyboard now
    property int holders: 0
    property string phase: "locking"
    // 0: do nothing but log. `rekey` is also off while a rekey is already on its way.
    property bool enabled: true
    property int deadMs: 400
    property int recheckMs: 250
    // THE HOP (see above). Off: the new lock is asked for at once, which exercises the last resort on its own.
    property bool hopEnabled: true
    // screens that have a lock surface now (names)
    property var surfaceNames: []
    // tools/lockscreen/lares-lock-hop; empty: no hop
    property var hopCommand: []
    property string hopName: "LARESLOCK-HOP"
    // how many hops one dead stretch may make before the new lock is asked for
    property int hopMax: 2
    // a surface on a new output needs a moment before the compositor can focus it; the longest wait for the surface to exist
    property int hopSettleMs: 120
    property int hopSurfaceMs: 2500
    // A new output asked for right after a resume is a long compositor frame: on Hyprland 0.57.0-1, which ran realtime, it was the
    // overrun its kernel budget killed it for, 0.9 s after a resume (CLAUDE.md, "HYPRLAND 0.57.0-0.57.1 RAN ITS MAIN THREAD
    // REALTIME"). The output is made no sooner than this after the resume, out of the wake's busiest seconds; a second output needs
    // no new one and hops at once.
    property int hopCreateAfterResumeMs: 3000
    property double _resumedAt: 0
    // on the other output: the longest wait for `enter` before the pointer goes back (it goes at once when one comes)
    property int hopLandMs: 350
    // after a hop: how long until the whole check is made again
    property int verifyMs: 500
    // a seat with no keyboard in it never asks; false: ask whatever the seat says (the compositor cannot be asked)
    property bool askSeat: true
    // the command that lists the seat's keyboards, JSON on stdout (hyprctl -j devices)
    property var devicesCommand: ["hyprctl", "-j", "devices"]
    // the probe key, and how long it has to arrive; an empty command skips the probe
    property var probeCommand: ["setpriv", "--pdeathsig", "TERM", "--", "wtype", "-k", "F24"]
    property int probeMs: 350

    // ---- what it reports -------------------------------------------------------------
    // the lock should be replaced: why
    signal rekey(string why)
    // facts for the post-mortem log
    signal note(string text)

    readonly property bool dead: root.phase === "locked" && root.holders === 0
    property int asked: 0
    // hops made in this dead stretch, and whether one is in the air
    property int hops: 0
    readonly property bool hopping: root._hopStage !== ""
    // the probe key is out: a surface hands it to heard() rather than to the password
    readonly property bool probing: probeWait.running
    // this stretch of "dead" was shown alive by a key: nothing more is asked until a surface holds the keyboard again
    property bool _aliveByKey: false

    onDeadChanged: {
        root._aliveByKey = false;
        if (root.dead && !root.hopping)
            root.hops = 0;
        if (root.dead) {
            root.note("no surface holds the keyboard; waiting " + root.deadMs + " ms");
            wait.restart();
        } else {
            wait.stop();
            recheck.stop();
            probeWait.stop();
            if (root.phase === "locked")
                root.note("a surface holds the keyboard again");
        }
    }

    // The machine came back (or is going): count the dead time from now.
    function resumed() {
        root._aliveByKey = false;
        root._resumedAt = Date.now();
        if (!root.hopping)
            root.hops = 0;
        if (root.dead) {
            root.note("resumed while no surface holds the keyboard; waiting " + root.deadMs + " ms more");
            wait.restart();
            recheck.stop();
        }
    }

    Timer {
        id: wait
        interval: root.deadMs
        onTriggered: root._ask()
    }
    Timer {
        id: recheck
        interval: root.recheckMs
        onTriggered: root._ask()
    }

    // The probe key arrived at a surface.
    function heard() {
        if (!probeWait.running)
            return;
        probeWait.stop();
        root._aliveByKey = true;
        root.note("a key sent to the seat arrived: the keyboard is alive, no surface is active (Qt's word) -- no new lock");
    }

    function _ask() {
        if (!root.dead || root._aliveByKey)
            return;
        if (!root.askSeat) {
            root._probe("no surface holds the keyboard");
            return;
        }
        if (devices.running || probeWait.running || root.hopping)
            return;
        devices.running = true;
    }

    // The seat has a keyboard and no surface is active: send the probe key (or, without a probe, ask at once).
    function _probe(why) {
        if (root.probeCommand.length === 0) {
            root._fire(why);
            return;
        }
        root._why = why;
        probeProc.running = true;
        probeWait.restart();
    }
    property string _why: ""
    Timer {
        id: probeWait
        interval: root.probeMs
        onTriggered: root._fire(root._why + "; a key sent to the seat did not arrive")
    }
    Process {
        id: probeProc
        command: root.probeCommand
    }

    function _fire(why) {
        if (!root.dead || root._aliveByKey || root.hopping)
            return;
        root.asked++;
        // the hop first: nothing of it is drawn. The new lock only when the hop has had its turns (or there is no hop).
        if (root.hopEnabled && root.hopCommand.length > 0 && root.hops < root.hopMax && root._hopsTotal < 3 * root.hopMax) {
            root._hopStart(why);
            return;
        }
        if (!root.enabled) {
            root.note("would ask for a new lock (" + why + ") but re-keying is off");
            return;
        }
        root.rekey(why);
    }

    // ---- THE HOP: the pointer to another output and back (lares-lock-hop does the hyprctl calls) ---------------------------------
    // stages: info (outputs and pointer) -> [create (headless) -> surface (wait for the lock's surface on it) -> settle -> info2] ->
    //         go (pointer there) -> land (wait for `enter`) -> back (pointer where it was) -> [remove] -> verify. A hop always runs
    //         to its end: the pointer is put back and the headless output taken away whatever the keyboard did meanwhile.
    property string _hopStage: ""
    property int _hopsTotal: 0
    property var _hopMons: []
    property var _hopCursor: [0, 0]
    property string _hopTarget: ""
    property bool _hopMade: false
    property double _hopT0: 0

    function _hopStart(why) {
        root.hops++;
        root._hopsTotal++;
        root._hopMade = false;
        root._hopTarget = "";
        root._hopT0 = Date.now();
        root.note("hop " + root.hops + ": " + why);
        root._hopRun("info", ["info"]);
    }
    function _hopRun(stage, args) {
        root._hopStage = stage;
        hopProc.command = root.hopCommand.concat(args);
        hopProc.running = true;
    }
    // `info`'s lines: `cursor X Y`, `mon NAME X Y W H`
    function _hopParse(text) {
        const mons = [];
        let cur = null;
        for (const line of String(text).split("\n")) {
            const f = line.trim().split(/\s+/);
            if (f[0] === "cursor" && f.length === 3)
                cur = [parseInt(f[1]), parseInt(f[2])];
            else if (f[0] === "mon" && f.length === 6)
                mons.push({ name: f[1], x: parseInt(f[2]), y: parseInt(f[3]), w: parseInt(f[4]), h: parseInt(f[5]) });
        }
        return { cursor: cur, mons: mons };
    }
    function _hopFail(why) {
        root.note("hop failed: " + why);
        root._hopCleanup();
    }
    // the way out of a hop, whatever stage it was in: pointer back, headless output gone, then the check again
    function _hopCleanup() {
        if (root._hopMade && root._hopStage !== "removing") {
            root._hopRun("removing", ["remove", root.hopName]);
        } else {
            root._hopDone();
        }
    }
    function _hopDone() {
        root.note("hop " + root.hops + " done in " + (Date.now() - root._hopT0) + " ms");
        root._hopStage = "";
        verify.restart();
    }
    function _hopGo() {
        const m = root._hopMons.find(x => x.name === root._hopTarget);
        if (!m) {
            root._hopFail("no output " + root._hopTarget);
            return;
        }
        root._hopRun("go", ["move", String(m.x + Math.floor(m.w / 2)), String(m.y + Math.floor(m.h / 2))]);
    }

    Process {
        id: hopProc
        stdout: StdioCollector {
            id: hopOut
        }
    }
    Connections {
        target: hopProc
        function onExited(code) {
            const stage = root._hopStage;
            const txt = String(hopOut.text);
            if (stage === "info" || stage === "info2") {
                const r = root._hopParse(txt);
                if (code !== 0 || !r.cursor || r.mons.length === 0) {
                    root._hopFail("outputs and pointer unreadable (exit " + code + ")");
                    return;
                }
                if (stage === "info") {
                    root._hopCursor = r.cursor;
                    root._hopMons = r.mons;
                    // the output the pointer is on
                    const here = r.mons.find(m => r.cursor[0] >= m.x && r.cursor[0] < m.x + m.w && r.cursor[1] >= m.y && r.cursor[1] < m.y + m.h);
                    const other = r.mons.find(m => !here || m.name !== here.name);
                    if (other) {
                        root._hopTarget = other.name;
                        root.note("hop to " + other.name + " and back");
                        root._hopGo();
                    } else {
                        root.note("one output: a headless one for the moment");
                        const hold = root._resumedAt + root.hopCreateAfterResumeMs - Date.now();
                        if (hold > 0) {
                            root.note("the headless output waits " + hold + " ms for the resume to settle");
                            createHold.interval = hold;
                            createHold.restart();
                        } else {
                            root._hopRun("create", ["create", root.hopName]);
                        }
                    }
                } else {
                    root._hopMons = r.mons;
                    root._hopTarget = root.hopName;
                    root._hopGo();
                }
            } else if (stage === "create") {
                if (code !== 0) {
                    root._hopFail("no headless output: " + txt.trim());
                    return;
                }
                root._hopMade = true;
                root.note("hop: the headless output is made after " + (Date.now() - root._hopT0) + " ms");
                root._hopStage = "surface";
                surfaceWait.restart();
                root._hopSurfaceCheck();
            } else if (stage === "go") {
                if (code !== 0) {
                    root._hopFail("the pointer would not move: " + txt.trim());
                    return;
                }
                root._hopStage = "land";
                land.restart();
                root._hopLandCheck();
            } else if (stage === "back") {
                // (a failed move back is still followed by the output's removal)
                if (code !== 0)
                    root.note("the pointer would not go back: " + txt.trim());
                if (root._hopMade)
                    root._hopRun("removing", ["remove", root.hopName]);
                else
                    root._hopDone();
            } else if (stage === "removing") {
                if (code !== 0)
                    root.note("the headless output would not go: " + txt.trim());
                root._hopDone();
            }
        }
    }
    Timer {
        id: createHold
        repeat: false
        onTriggered: {
            if (root.dead)
                root._hopRun("create", ["create", root.hopName]);
            else
                root._hopDone();
        }
    }

    // the lock's surface on the headless output exists
    function _hopSurfaceCheck() {
        if (root._hopStage !== "surface" || root.surfaceNames.indexOf(root.hopName) < 0)
            return;
        surfaceWait.stop();
        root.note("hop: the lock has a surface on " + root.hopName + " after " + (Date.now() - root._hopT0) + " ms");
        root._hopStage = "settle";
        settle.restart();
    }
    onSurfaceNamesChanged: root._hopSurfaceCheck()
    Timer {
        id: surfaceWait
        interval: root.hopSurfaceMs
        onTriggered: root._hopFail("the lock made no surface for " + root.hopName + " in " + root.hopSurfaceMs + " ms")
    }
    Timer {
        id: settle
        interval: root.hopSettleMs
        onTriggered: root._hopRun("info2", ["info"])
    }
    // the pointer is on the other output: the surface there is given the keyboard (`enter`), then the pointer goes back
    function _hopLandCheck() {
        if (root._hopStage !== "land" || root.holders === 0)
            return;
        land.stop();
        root.note("hop: a surface holds the keyboard after " + (Date.now() - root._hopT0) + " ms");
        root._hopBack();
    }
    function _hopBack() {
        root._hopRun("back", ["move", String(root._hopCursor[0]), String(root._hopCursor[1])]);
    }
    onHoldersChanged: root._hopLandCheck()
    Timer {
        id: land
        interval: root.hopLandMs
        onTriggered: {
            root.note("the other output did not get the keyboard in " + root.hopLandMs + " ms");
            root._hopBack();
        }
    }
    // after the hop: look again, as for any dead stretch (the key probe says whether it worked; a surface that holds the keyboard
    // ends it at once)
    Timer {
        id: verify
        interval: root.verifyMs
        onTriggered: {
            if (!root.dead) {
                root.note("hop done: a surface holds the keyboard");
                return;
            }
            root._ask();
        }
    }

    Process {
        id: devices
        command: root.devicesCommand
        stdout: StdioCollector {
            id: out
        }
    }
    Connections {
        target: devices
        function onExited(code) {
            if (!root.dead)
                return;
            // hyprctl's JSON is not JSON where a value is unknown (`"active_layout_index": none,` for a virtual
            // keyboard): count the keyboards' addresses between the lists' names instead of parsing it
            const m = /"keyboards"\s*:\s*\[([\s\S]*?)\]\s*,\s*"tablets"/.exec(String(out.text));
            const n = m ? (m[1].match(/"address"/g) || []).length : -1;
            if (code !== 0 || n < 0) {
                // hyprctl is not there or does not answer: the seat cannot be asked, so the missing keyboard stands
                root._probe("no surface holds the keyboard (the seat could not be asked: exit " + code + ")");
            } else if (n > 0) {
                root._probe("no surface holds the keyboard; the seat has " + n + " keyboard" + (n === 1 ? "" : "s"));
            } else {
                root.note("no surface holds the keyboard and the seat has none yet");
                recheck.restart();
            }
        }
    }
}
