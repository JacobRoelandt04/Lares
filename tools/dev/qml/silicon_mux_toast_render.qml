pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/theme"
import "modules/common/notify"
import "modules/silicon"
import "modules/silicon/data"
import "modules/notifications/data"
import "modules/notifications/parts"
import "modules/notifications/toast"

// =============================================================================
// silicon_mux_toast_render.qml -- the MUX keep prompt TOAST as the shell draws it, rendered: the real SiliconMuxWatcher on a SiliconMock
// (the guard's record awaiting its keep), the real NotificationService, and the real ToastEntry for what the scheduler shows.
// The keep window is WINDOW_S seconds (default 20) so that "mid-countdown" is reached in real time.
//
//   frames: <OUT_DIR>/ask_early.png (just after the figure arrived), ask_mid.png (about half drained), ask_dark.png (the same, dark),
//           back.png (the guard's revert seen happening: Going back to Hybrid, no buttons)
//   prints: `TOASTR <frame> timeLeft <f> expect <f> figure <text>` and one `TOASTR RESULT PASS|FAIL`
//           (PASS: the drain follows the helper's deadline -- timeLeft within 0.08 of (deadline - now) / span -- the figure is the guard's
//           clock, early is fuller than mid, and the frames were written)
// Env: OUT_DIR, WINDOW_S, SCALE (device px per px, default 2)
// =============================================================================
ShellRoot {
    FloatingWindow {
        id: win
        implicitWidth: Math.ceil((toastStyle.toastWidth + 40) * win.zoom)
        implicitHeight: Math.ceil(250 * win.zoom)
        visible: true
        color: Theme.surface

        readonly property real zoom: Math.max(1, Number(Quickshell.env("SCALE") || 2))
        readonly property real windowS: Math.max(6, Number(Quickshell.env("WINDOW_S") || 20))
        readonly property string outDir: Quickshell.env("OUT_DIR") || "/tmp"
        property var fails: []
        property int shots: 0
        // through a var: the harness's import path and the card's own name one type twice to qmllint
        property var styleObj: toastStyle
        property var groupsObj: toastGroups

        NotificationService {
            id: svc
            serverEnabled: false
            registerOnBus: true
            persist: false
            liveSignals: false
            ipcEnabled: false
            configPath: ""
        }
        NotificationStyle {
            id: toastStyle
            renderScale: win.zoom
        }
        GroupPalette {
            id: toastGroups
        }
        SiliconMock {
            id: mock
            playing: false
            promptWindowS: win.windowS
        }
        SiliconMuxWatcher {
            id: watcher
            vm: mock
        }

        Item {
            id: stage
            x: 0
            y: 0
            width: Math.ceil((toastStyle.toastWidth + 40) * win.zoom)
            height: Math.ceil(250 * win.zoom)
            Rectangle {
                anchors.fill: parent
                color: Theme.surface
            }
            Item {
                x: 20 * win.zoom
                y: 20 * win.zoom
                scale: win.zoom
                transformOrigin: Item.TopLeft
                width: toastStyle.toastWidth
                height: 220
                Column {
                    id: lane
                    spacing: 8
                    Repeater {
                        model: svc.toasts.shown
                        delegate: ToastEntry {
                            required property string modelData
                            uid: modelData
                            service: svc
                            style: win.styleObj
                            groups: win.groupsObj
                            cardWidth: toastStyle.toastWidth
                            overlayItem: lane
                        }
                    }
                }
            }
        }

        // the machine at the keep prompt, the way the mockup puts it up (DIALOG=keep)
        function awaiting(): void {
            const st = JSON.parse(JSON.stringify(mock._status));
            st.mux.record = { want: "dgpu", from: "hybrid", state: "awaiting-keep", why: "", requestedAtMs: Date.now() - 20000, bootId: "mock", deadlineMs: Date.now() + 90000 };
            st.mux.wiringNow = "dgpu";
            st.mux.stored = "dgpu";
            mock._status = st;
            mock._compute();
        }
        function expectLeft(): real {
            const r = svc.store.all().filter(x => x.key === "silicon-mux-keep")[0];
            return r && r.deadlineTotalMs > 0 ? Math.max(0, r.deadlineMs - Date.now()) / r.deadlineTotalMs : -1;
        }
        function entry(): var {
            for (let i = 0; i < lane.children.length; i++)
                if (lane.children[i].uid !== undefined && lane.children[i].timeLeft !== undefined)
                    return lane.children[i];
            return null;
        }
        property var lefts: ({})
        function shoot(name: string): void {
            const e = win.entry();
            const left = e ? e.timeLeft : -1;
            const expect = win.expectLeft();
            const fig = watcher.prompt.countdownText;
            win.lefts[name] = left;
            console.log("TOASTR " + name + " timeLeft " + left.toFixed(3) + " expect " + expect.toFixed(3) + " figure " + fig);
            if (name !== "back" && (left < 0 || expect < 0 || Math.abs(left - expect) > 0.08))
                win.fails.push(name + " drain " + left + " vs " + expect);
            stage.grabToImage(r => {
                r.saveToFile(win.outDir + "/" + name + ".png");
                win.shots++;
            });
        }

        // the script: wait for the figure, shoot, wait for half the window, shoot, dark, shoot, the way back, shoot
        property string stage_: "figure"
        function next(stage: string, ms: int): void {
            win.stage_ = stage;
            steps.interval = ms;
            steps.restart();
        }
        Timer {
            id: steps
            repeat: false
            onTriggered: {
                const st = win.stage_;
                if (st === "figure") {
                    if (!(watcher.prompt.figureShown && win.entry() !== null)) {
                        win.next("figure", 250);
                        return;
                    }
                    win.t0 = Date.now();
                    win.next("shot_early", 300);
                } else if (st === "shot_early") {
                    win.next("wait_half", 100);
                    win.shoot("ask_early");
                } else if (st === "wait_half") {
                    win.next("shot_mid", Math.max(50, win.windowS * 500 - (Date.now() - win.t0)));
                } else if (st === "shot_mid") {
                    win.next("dark", 100);
                    win.shoot("ask_mid");
                } else if (st === "dark") {
                    Theme.setMode("dark");
                    win.next("shot_dark", 900);
                } else if (st === "shot_dark") {
                    win.next("light", 100);
                    win.shoot("ask_dark");
                } else if (st === "light") {
                    Theme.setMode("light");
                    // the guard's revert, seen happening (the keep window runs out): the toast says where it is going until the
                    // outcome has been told (the watcher's grace is 30 s). Go back now's chain is the watcher probe's: the mock restarts at once.
                    mock.promptWindowS = 1;
                    mock.muxPromptShown();
                    win.next("shot_back", 3500);
                } else if (st === "shot_back") {
                    win.next("end", 100);
                    win.shoot("back");
                } else if (st === "end") {
                    win.finish();
                }
            }
        }
        property real t0: 0

        function finish(): void {
            const early = win.lefts["ask_early"];
            const mid = win.lefts["ask_mid"];
            if (!(early > mid))
                win.fails.push("early " + early + " not fuller than mid " + mid);
            if (win.shots < 4)
                win.fails.push("only " + win.shots + " frames written");
            console.log("TOASTR RESULT " + (win.fails.length === 0 ? "PASS" : "FAIL (" + win.fails.join("; ") + ")"));
            Qt.quit();
        }

        Timer {
            running: true
            interval: 600
            onTriggered: {
                win.awaiting();
                win.next("figure", 600);
            }
        }
        Timer {
            running: true
            interval: 90000
            onTriggered: {
                win.fails.push("timed out");
                win.finish();
            }
        }
    }
}
