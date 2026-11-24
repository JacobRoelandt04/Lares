pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window

import "modules/shell"
import "modules/notes"

// =============================================================================
// tools/dev/qml/key_flourish_probe.qml -- a KEY that OPENS a popup plays its module's bar glyph, as a hover would (ShortcutRouter._keyFlourish).
// tools/dev/idle_auto_causes_probe.sh runs it as its second harness. The router is the real one (its GlobalShortcuts off) over a stand-in `services`
// (two screens' frames, an owner per key whose shortcutPressed() opens or closes), and each screen's glyph is the REAL NotesBarButton, so the entry
// that plays is the one the OLED care sees (FlourishRegistry, group "notes"). Prints `KEYFL ok|FAIL <check>` and `KEYFL RESULT PASS|FAIL (<n>/<n> checks)`.
//
//   the key opens   the focused screen's notes glyph plays ONCE, the other screen's not at all; on the other screen when the focus is there
//   the key closes  nothing plays
//   a play in progress is not restarted (a hover's rule: overlap "ignore")
//   a glyph that is not armed plays nothing; a key whose module has no flourish (launcher) plays nothing; the lock key plays nothing of its own here
// =============================================================================
Window {
    id: win
    visible: true
    width: 200
    height: 100

    property int fails: 0
    property int checks: 0
    function check(name: string, ok: bool, detail: string): void {
        win.checks++;
        if (!ok)
            win.fails++;
        console.log("KEYFL " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }

    // two screens' frames, each with a notes glyph
    Item {
        id: frameA
        width: 100
        height: 40
        NotesBarButton {
            id: glyphA
            x: 10
            y: 10
        }
    }
    Item {
        id: frameB
        y: 50
        width: 100
        height: 40
        NotesBarButton {
            id: glyphB
            x: 10
            y: 10
        }
    }
    property int playsA: 0
    property int playsB: 0
    Connections {
        target: glyphA.flourish
        function onPlayed() { win.playsA++; }
    }
    Connections {
        target: glyphB.flourish
        function onPlayed() { win.playsB++; }
    }

    // an owner per screen and key: what the real ones do at the router's level (open when closed, close when open)
    component FakeOwner: QtObject {
        property bool popupMine: false
        function shortcutPressed(): void { popupMine = !popupMine; }
        function toggle(): void { popupMine = !popupMine; }
    }
    FakeOwner { id: notesA }
    FakeOwner { id: notesB }
    FakeOwner { id: launcherA }
    QtObject {
        id: fakeServices
        property var frames: ({ "A": frameA, "B": frameB })
        property string focus: "A"
        property var fired: []
        property var lock: QtObject { property bool locked: false }
        property var reelActions: QtObject {
            function firePower(what: string): void { fakeServices.fired = fakeServices.fired.concat([what]); }
        }
        function ownerOn(name: string, key: string): var {
            if (key === "notes")
                return name === "A" ? notesA : name === "B" ? notesB : null;
            if (key === "launcher")
                return name === "A" ? launcherA : null;
            return null;
        }
        function focusedOwner(key: string): var { return fakeServices.ownerOn(fakeServices.focus, key); }
    }
    ShortcutRouter {
        id: router
        enabled: false
        services: fakeServices
    }

    // ---- the sequence: each step acts, then waits for its condition (never a time), then judges ---------------------------------------
    property int at: -1
    property int a0: 0
    property int b0: 0
    function mark(): void { win.a0 = win.playsA; win.b0 = win.playsB; }
    readonly property var seq: [
        { act: () => {}, wait: 300, then: () => win.check("rest: nothing plays at load", win.playsA === 0 && win.playsB === 0 && !glyphA.flourish.playing, win.playsA + "/" + win.playsB) },
        { act: () => { win.mark(); router.press("notes"); }, wait: 40,
          then: () => win.check("the key OPENS notes: the focused screen's glyph plays once, the other screen's not at all",
              notesA.popupMine && win.playsA - win.a0 === 1 && win.playsB - win.b0 === 0 && glyphA.flourish.why === "random", notesA.popupMine + " " + win.playsA + "/" + win.playsB + " why " + glyphA.flourish.why) },
        { act: () => { win.mark(); router.press("notes"); }, wait: 40,
          then: () => win.check("the key CLOSES it (while the flourish still runs): nothing plays", !notesA.popupMine && win.playsA === win.a0 && win.playsB === win.b0, win.playsA + "/" + win.playsB) },
        { act: () => {}, until: () => !glyphA.flourish.playing, within: 6000, then: () => win.check("the flourish ends by itself", true, "") },
        { act: () => { win.mark(); router.press("notes"); }, wait: 40,
          then: () => win.check("a second open plays again (one play per open)", notesA.popupMine && win.playsA - win.a0 === 1, String(win.playsA - win.a0)) },
        { act: () => {}, until: () => !glyphA.flourish.playing, within: 6000, then: () => win.check("(it ends)", notesA.popupMine, "") },
        { act: () => { win.mark(); router.press("notes"); }, wait: 40,
          then: () => win.check("the key CLOSES it with the glyph at rest: nothing plays either", !notesA.popupMine && win.playsA === win.a0 && !glyphA.flourish.playing, win.playsA - win.a0 + "") },
        { act: () => { win.mark(); glyphA.flourish.play("hover"); router.press("notes"); }, wait: 40,
          then: () => win.check("a play already in progress (a hover's) is not restarted by the key", notesA.popupMine && win.playsA - win.a0 === 1 && glyphA.flourish.why === "hover", win.playsA - win.a0 + " why " + glyphA.flourish.why) },
        { act: () => { router.press("notes"); }, until: () => !glyphA.flourish.playing, within: 6000, then: () => win.check("(it ends)", !notesA.popupMine, "") },
        { act: () => { glyphA.flourishEnabled = false; win.mark(); router.press("notes"); }, wait: 40,
          then: () => win.check("a glyph whose flourish is off plays nothing", notesA.popupMine && win.playsA === win.a0, String(win.playsA - win.a0)) },
        { act: () => { router.press("notes"); glyphA.flourishEnabled = true; fakeServices.focus = "B"; win.mark(); router.press("notes"); }, wait: 40,
          then: () => win.check("with the focus on the other screen it plays there, and only there", notesB.popupMine && win.playsB - win.b0 === 1 && win.playsA === win.a0, win.playsA - win.a0 + "/" + (win.playsB - win.b0)) },
        { act: () => { router.press("notes"); }, until: () => !glyphB.flourish.playing, within: 6000, then: () => win.check("(it ends)", !notesB.popupMine, "") },
        { act: () => { fakeServices.focus = "A"; win.mark(); router.press("launcher"); }, wait: 40,
          then: () => win.check("a key whose module has no glyph flourish (the launcher) opens it and plays nothing", launcherA.popupMine && win.playsA === win.a0 && win.playsB === win.b0, win.playsA + "/" + win.playsB) },
        { act: () => { win.mark(); router.press("lock"); }, wait: 40,
          then: () => win.check("the lock key goes its own way (the power reel) and plays none of these", fakeServices.fired.join() === "lock" && win.playsA === win.a0 && win.playsB === win.b0, fakeServices.fired.join()) }
    ]
    property double t0: 0
    function next(): void {
        win.at++;
        if (win.at >= win.seq.length) {
            console.log("KEYFL RESULT " + (win.fails === 0 ? "PASS" : "FAIL") + " (" + (win.checks - win.fails) + "/" + win.checks + " checks)");
            Qt.callLater(Qt.quit);
            return;
        }
        win.seq[win.at].act();
        win.t0 = Date.now();
        poll.restart();
    }
    Timer {
        id: poll
        interval: 20
        repeat: true
        onTriggered: {
            const s = win.seq[win.at];
            const el = Date.now() - win.t0;
            if (s.until ? (s.until() || el > s.within) : el >= s.wait) {
                poll.stop();
                if (s.until && el > s.within && !s.until())
                    win.check("did not end within " + s.within + " ms (step " + win.at + ")", false, "");
                else
                    s.then();
                win.next();
            }
        }
    }
    Timer {
        interval: 600
        running: true
        onTriggered: win.next()
    }
    Timer {
        interval: 60000
        running: true
        onTriggered: {
            console.log("KEYFL FAIL the probe did not finish (step " + win.at + ")");
            console.log("KEYFL RESULT FAIL (timeout)");
            Qt.quit();
        }
    }
}
