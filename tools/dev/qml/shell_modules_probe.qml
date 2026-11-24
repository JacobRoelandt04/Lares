pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/shell"
import "modules/shell/ShellLayout.js" as Layout

// =============================================================================
// shell_modules_probe.qml -- the modules that shell.jsonc switches off (`modules`), on the MOCK shell: ONE ShellServices and ONE
// ShellFrame in an offscreen window, the file written by the runner (tools/dev/shell_modules_probe.sh) before the start, as a user's
// file is there before the shell. Prints ONE line of facts once the frame stands (`SMOD FACTS {json}`), then -- with the file rewritten
// under the running shell, everything on again -- `SMOD HOT {json}`, then presses the keys of the key-opened popups (`SMOD KEYS
// {json}`). The runner judges; this draws no conclusion.
// =============================================================================
ShellRoot {
    id: root

    FloatingWindow {
        id: win
        implicitWidth: 1600
        implicitHeight: 700
        visible: true
        color: "#808080"

        ShellServices {
            id: mockServices
            mode: "mock"
            windowless: true
        }
        Loader {
            id: frameLoader
            anchors.fill: parent
            active: mockServices.ready
            sourceComponent: Component {
                ShellFrame {
                    services: mockServices
                    screenName: "DP-1"
                }
            }
        }
        ShortcutRouter {
            id: router
            services: mockServices
            enabled: false
        }
    }

    readonly property var frame: frameLoader.item
    readonly property var serviceOf: ({ weather: "weather", stocks: "stocks", player: "mpd", volume: "audio", aerial: "aerial", bridge: "bridge",
            panorama: "panorama", silicon: "silicon", clipboard: "clipboard", picker: "picker", wiki: "wiki", screentime: "screentime" })

    function facts(): var {
        const f = root.frame, out = { off: Object.keys(mockServices.shellConfig.modulesOff).sort(), modules: Layout.MODULES, placed: {}, shown: {}, built: {},
                                      zones: f.cfg.zones, lengths: f.lengths, ready: mockServices.ready, cast: !!mockServices.cast,
                                      updatesLive: mockServices.updates.autoStart === true, absent: mockServices.osd.absent };
        for (const id in f.placed)
            out.placed[id] = f.placed[id].width;
        for (const id in f.buttons)
            out.shown[id] = f.buttons[id].visible === true;
        for (const id in root.serviceOf)
            out.built[id] = !!mockServices[root.serviceOf[id]];
        // a mode asked for: what is in force (the auto layer's cause goes through the same expression, after its 3 s)
        mockServices.idle.setMode("normal", false);
        out.idle = { mode: mockServices.idle.mode, hold: mockServices.idle.normalHold, selected: mockServices.idle.selectedMode };
        mockServices.idle.setMode("off", false);
        out.prewarm = f.prewarmEntries().map(e => e.ownerId);
        out.lockUpdates = mockServices.lock.updates !== null;
        return out;
    }

    property int phase: 0
    property double t0: Date.now()
    Timer {
        interval: 100
        repeat: true
        running: true
        onTriggered: {
            const age = Date.now() - root.t0;
            if (root.phase === 0) {
                // the frame stands: its lengths are there and a turn has passed for the file's own (hot) load
                if (root.frame && root.frame.ready && root.frame.lengths.left > 0 && age > 900) {
                    console.log("SMOD FACTS " + JSON.stringify(root.facts()));
                    // the file says everything is on again: a running shell does not move
                    mockServices.shellConfig.write({ modules: {}, font: "Inter" });
                    root.t0 = Date.now();
                    root.phase = 1;
                } else if (age > 20000) {
                    console.log("SMOD FAIL the frame never stood (ready=" + mockServices.ready + " servicesUp=" + mockServices.servicesUp + ")");
                    Qt.exit(1);
                }
            } else if (root.phase === 1) {
                // the hot part of the file has arrived (the face), so the rest of it has been read too
                if (root.frame.cfg.font === "Inter" || age > 4000) {
                    const h = root.facts();
                    h.font = root.frame.cfg.font;
                    console.log("SMOD HOT " + JSON.stringify(h));
                    const keys = {};
                    for (const k of ["notes", "clipboard", "picker", "launcher"]) {
                        router.press(k);
                        const o = mockServices.focusedOwner(k);
                        keys[k] = !!o && o.popupMine === true;
                        if (root.frame.engine.popupOpen)
                            root.frame.engine.close();
                    }
                    console.log("SMOD KEYS " + JSON.stringify(keys));
                    root.phase = 2;
                    Qt.callLater(Qt.quit);
                }
            }
        }
    }
}
