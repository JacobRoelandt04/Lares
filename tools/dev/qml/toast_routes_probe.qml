pragma ComponentBehavior: Bound

import QtQuick
import QtTest
import Quickshell

import "modules/shell"

// =============================================================================
// toast_routes_probe.qml -- how three behaviours are TIED, on the real ShellServices (mock services) and TWO real ShellFrames
// (screens "eDP-1" and "DP-2"), offscreen. Run by tools/dev/toast_routes_probe.sh. Without TOAST_ROUTES=1 in the environment (a bare
// `smoke.sh --all` load) it quits at once.
//
//   R1  a toast's body click (NotificationService.activate, what the card's click calls) for a countdown, a pomodoro and an alarm
//       ring (TimerService._ring, the real posting path) opens the clock popup of the FOCUSED screen on its Timers tab, on the
//       view of that kind (timers.js KIND_VIEW); the other screen's clock stays shut; with the focus moved, it follows
//   R2  a body click on a network failure toast (AerialMock._fail -> AerialToasts -> DesktopNotifier -> the bus) opens the
//       network popup of the focused screen, and only there
//   R3  a RIGHT click on the player's bar disc, synthesised on the window, plays / pauses the mpd (one toggle each, no popup); a
//       left click still opens the player popup and does not toggle
// Prints `TOASTR ok|FAIL <check>` and `TOASTR RESULT PASS|FAIL (<n>/<n> checks)`.
// =============================================================================
ShellRoot {
    id: root

    readonly property bool armed: Quickshell.env("TOAST_ROUTES") === "1"
    property int checks: 0
    property int fails: 0
    function check(name: string, ok: bool, detail: string): void {
        root.checks++;
        if (!ok)
            root.fails++;
        console.log("TOASTR " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }

    FloatingWindow {
        id: winA
        implicitWidth: 1400
        implicitHeight: 700
        visible: root.armed
        color: "#808080"
        ShellServices {
            id: mockServices
            mode: "mock"
            windowless: true
        }
        Loader {
            id: loadA
            anchors.fill: parent
            active: root.armed && mockServices.ready
            sourceComponent: Component {
                ShellFrame {
                    services: mockServices
                    screenName: "eDP-1"
                }
            }
        }
    }
    FloatingWindow {
        id: winB
        implicitWidth: 1400
        implicitHeight: 700
        visible: root.armed
        color: "#808080"
        Loader {
            id: loadB
            anchors.fill: parent
            active: root.armed && mockServices.ready && !!loadA.item
            sourceComponent: Component {
                ShellFrame {
                    services: mockServices
                    screenName: "DP-2"
                }
            }
        }
    }
    TestCase {
        id: tc
        name: "toastr"
        when: false
        visible: false
    }

    readonly property var fa: loadA.item
    readonly property var fb: loadB.item
    readonly property var notes: mockServices.notifications

    function bothUp(): bool {
        return !!root.fa && !!root.fb && root.fa.ready && root.fb.ready && !!root.fa.owners.clock && !!root.fb.owners.clock;
    }
    function allClosed(f: var): bool {
        const e = f.engine;
        return e.thePopup.phase === "closed" && e.theReel.phase === "closed" && e.theReelChild.phase === "closed";
    }
    function recFor(source: string, key: string): var {
        const all = root.notes.store.all();
        for (let i = all.length - 1; i >= 0; i--)
            if (all[i].sourceId === source && all[i].key === key)
                return all[i];
        return null;
    }
    function click(win: var, item: Item, button: int): void {
        const p = item.mapToItem(win.contentItem, item.width / 2, item.height / 2);
        tc.mouseMove(win.contentItem, p.x - 3, p.y);
        tc.mouseMove(win.contentItem, p.x, p.y);
        tc.mouseClick(win.contentItem, p.x, p.y, button);
    }

    // ---- the sequencer: a condition (polled), the deadline counted in live time ----
    property var _q: []
    property var _cur: null
    property real _spent: 0
    property real _lastTick: 0
    function step(label: string, run: var, until: var, ms: int): void {
        root._q = root._q.concat([{ label: label, run: run, until: until, ms: ms || 8000 }]);
    }
    Timer {
        interval: 25
        repeat: true
        running: root.armed
        onTriggered: {
            const now = Date.now();
            const dt = root._lastTick > 0 ? Math.min(now - root._lastTick, 100) : 0;
            root._lastTick = now;
            if (!root._cur) {
                if (root._q.length === 0) {
                    console.log("TOASTR RESULT " + (root.fails === 0 && root.checks > 0 ? "PASS" : "FAIL") + " (" + (root.checks - root.fails) + "/" + root.checks + " checks)");
                    Qt.quit();
                    return;
                }
                root._cur = root._q[0];
                root._q = root._q.slice(1);
                root._spent = 0;
                try {
                    root._cur.run();
                } catch (e) {
                    root.check(root._cur.label + " (threw)", false, String(e));
                    root._cur = null;
                }
                return;
            }
            root._spent += dt;
            let done = false;
            try {
                done = !root._cur.until || root._cur.until();
            } catch (e) {
                done = false;
            }
            if (done) {
                root._cur = null;
            } else if (root._spent > root._cur.ms) {
                root.check(root._cur.label + " (waited)", false, "timed out");
                root._cur = null;
            }
        }
    }

    // a clock popup of one screen is up / shut
    function clockUp(f: var): bool {
        return f.owners.clock.popupMine;
    }
    function closeAll(): void {
        for (const f of [root.fa, root.fb]) {
            if (f.engine.popupOpen)
                f.engine.close();
        }
    }
    function quiet(): bool {
        return root.allClosed(root.fa) && root.allClosed(root.fb);
    }

    // one ring + click on the focused screen `focus` (the other is `other`)
    function ringAndClick(kind: string, focus: string, here: var, other: var): void {
        const view = { countdown: 0, pomodoro: 1, alarm: 3 }[kind];
        root.step("R1 " + kind + " ring on " + focus, () => {
            mockServices.focus.setFocused(focus);
            mockServices.timers._ring(kind, { late: false }, { title: kind + " rang", body: "probe", urgency: "normal" }, "", false);
        }, () => !!root.recFor("clock", kind));
        root.step("R1 " + kind + " click", () => {
            const r = root.recFor("clock", kind);
            root.check("R1 the " + kind + " toast is the clock's, with a body-click default", !!r && r.hasDefault === true, JSON.stringify(r));
            root.notes.activate(r.uid);
        }, () => root.clockUp(here));
        root.step("R1 " + kind + " judged", () => {
            const o = here.owners.clock;
            root.check("R1 " + kind + ": the click opens the clock on " + focus + ", on the Timers tab", root.clockUp(here) && o.currentTab === "timers", "mine " + root.clockUp(here) + " tab " + o.currentTab);
            root.check("R1 " + kind + ": ...on that kind's view (" + view + ")", !!o.viewRequest && o.viewRequest.view === view, JSON.stringify(o.viewRequest));
            root.check("R1 " + kind + ": ...and not on the other screen", !root.clockUp(other), "other mine " + root.clockUp(other));
            mockServices.timers.dismiss(kind);
            root.closeAll();
        }, () => root.quiet());
    }

    Component.onCompleted: {
        if (!root.armed) {
            Qt.callLater(Qt.quit);
            return;
        }
        root.step("frames up", () => {}, () => root.bothUp(), 30000);
        root.step("settled", () => {}, () => mockServices.settled && root.quiet(), 60000);
        root.step("pinned", () => {
            console.log("TOASTR screens " + JSON.stringify(mockServices.screenNames));
            root.check("both screens registered with the services", mockServices.screenNames.length === 2, JSON.stringify(mockServices.screenNames));
        });

        for (const kind of ["countdown", "pomodoro", "alarm"])
            root.ringAndClick(kind, "DP-2", root.fb, root.fa);
        root.ringAndClick("countdown", "eDP-1", root.fa, root.fb);

        // ---- R2 the network toast ----
        for (const pair of [["DP-2", "fb", "fa"], ["eDP-1", "fa", "fb"]]) {
            const focus = pair[0], hereKey = pair[1], otherKey = pair[2];
            root.step("R2 failure on " + focus, () => {
                mockServices.focus.setFocused(focus);
                mockServices.aerial._fail("connect", "Cafe-" + focus, "The password was not accepted.");
            }, () => !!root.aerialRec());
            root.step("R2 click on " + focus, () => {
                const r = root.aerialRec();
                root.check("R2 the network failure is one toast of the aerial source, with a body-click default", !!r && r.hasDefault === true, JSON.stringify(r));
                root.notes.activate(r.uid);
            }, () => root[hereKey].owners.aerial.popupMine);
            root.step("R2 judged " + focus, () => {
                root.check("R2 the click opens the network popup on " + focus, root[hereKey].owners.aerial.popupMine, "");
                root.check("R2 ...and not on the other screen", !root[otherKey].owners.aerial.popupMine, "");
                root.closeAll();
            }, () => root.quiet());
        }

        // ---- R3 the disc ----
        const mpd = () => mockServices.mpd;
        root.step("R3 the mock queue", () => mockServices.focus.setFocused("eDP-1"), () => mpd().queueLength > 0 && root.fa.buttons.player.width > 0, 20000);
        root.step("R3 right click 1", () => {
            root._st0 = mpd().playState;
            root.click(winA, root.fa.buttons.player, Qt.RightButton);
        }, () => mpd().playState !== root._st0, 4000);
        root.step("R3 judged 1", () => {
            root.check("R3 a right click on the disc plays (from " + root._st0 + ")", mpd().playState === "play", mpd().playState);
            root.check("R3 ...with no popup", !root.fa.engine.popupOpen, "popup open");
            root.click(winA, root.fa.buttons.player, Qt.RightButton);
        }, () => mpd().playState !== "play", 4000);
        root.step("R3 judged 2", () => {
            root.check("R3 a second right click pauses (one toggle per click)", mpd().playState === "pause", mpd().playState);
            root.check("R3 ...still no popup", !root.fa.engine.popupOpen, "popup open");
            root.click(winA, root.fa.buttons.player, Qt.LeftButton);
        }, () => root.fa.engine.popupOpen, 6000);
        root.step("R3 judged 3", () => {
            root.check("R3 a left click opens the player popup and does not toggle", root.fa.engine.popupOpen && mpd().playState === "pause", "open " + root.fa.engine.popupOpen + " " + mpd().playState);
            root.closeAll();
        }, () => root.quiet());
    }
    property string _st0: ""
    function aerialRec(): var {
        const all = root.notes.store.all();
        for (let i = all.length - 1; i >= 0; i--)
            if (all[i].sourceId === "aerial")
                return all[i];
        return null;
    }

    Timer {
        interval: 240000
        running: root.armed
        onTriggered: {
            console.log("TOASTR RESULT FAIL (timeout)");
            Qt.quit();
        }
    }
}
