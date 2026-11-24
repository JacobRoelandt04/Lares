import QtQuick
import Quickshell
import Quickshell.Hyprland

import "modules/osd/data/sources"

// tools/dev/qml/osd_layout_probe.qml -- the layout OSD's source (tools/dev/osd_layout_probe.sh runs it).
//
//   OLP_MODE=live   on a REAL Hyprland (inside tools/dev/lock_env.sh): prints every layout / keyboard event heard
//                   (OLP raw ...) and every card the source asks for (OLP card <code>); the runner adds a keyboard
//                   (a virtual keyboard: Hyprland makes it `main`, as it does a USB headset's HID keys) and reads the lines.
//   OLP_MODE=sim    live: false -- the user's own device list (`hyprctl -j devices` of 2026-11-06) and `activelayout`
//                   payloads fed by hand, in the order a plug / a real switch / an unplug make them. Prints
//                   "OLP ok|FAIL <name>" and "OLP RESULT PASS|FAIL (n/n checks)".
Scope {
    id: root
    readonly property string mode: Quickshell.env("OLP_MODE") || "sim"
    property var cards: []
    property int fails: 0
    property int checks: 0
    function check(name: string, ok: bool, detail: string): void {
        root.checks++;
        if (!ok)
            root.fails++;
        console.log("OLP " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }

    LayoutSource {
        id: src
        live: root.mode === "live"
        onRequest: req => {
            root.cards = root.cards.concat([req.layout.name]);
            console.log("OLP card " + req.layout.code + " (" + req.layout.name + ")");
        }
    }
    Connections {
        enabled: root.mode === "live"
        target: Hyprland
        function onRawEvent(ev) {
            if (ev.name === "activelayout")
                console.log("OLP raw " + ev.name + ">>" + ev.data);
        }
    }

    // `hyprctl -j devices` keyboards of the user's laptop: the physical keyboard is main; `extra` adds a headset's HID keys
    function devices(mainName: string, extra: var): string {
        const names = ["video-bus", "power-button", "asus-wmi-hotkeys", "huawei-wmi-hotkeys", "at-translated-set-2-keyboard"].concat(extra || []);
        return JSON.stringify({ keyboards: names.map(n => ({ name: n, layout: "us,be", variant: "", options: "grp:alts_toggle",
                                                              active_keymap: n === "audeze-maxwell-hid" ? "error" : "English (US)", main: n === mainName })) });
    }
    readonly property string kb: "at-translated-set-2-keyboard"
    property int step: 0
    function run() {
        const n = root.cards.length;
        const since = () => root.cards.length - n;
        switch (root.step) {
        case 0:  // the session starts: the list is read once, nothing has switched
            src.simulateDevices(root.devices(root.kb));
            src.simulateEvent(root.kb + ",English (US)");           // the physical keyboard says what it already is
            root.check("start: the layout it already is is no change", root.cards.length === 0, root.cards.join());
            break;
        case 1:  // the headset is plugged: Hyprland makes its keyboard main and it reports English (US) then error
            src.simulateEvent("audeze-maxwell-hid,English (US)");
            src.simulateEvent("audeze-maxwell-hid,error");
            src.simulateDevices(root.devices("audeze-maxwell-hid", ["audeze-maxwell-hid"]));
            root.check("plug: no card", root.cards.length === 0, root.cards.join());
            src.simulateEvent("audeze-maxwell-hid,English (US)");   // the tail of its add, once it is known
            root.check("plug: its own later event shows nothing either", root.cards.length === 0, root.cards.join());
            break;
        case 2:  // a REAL switch on the physical keyboard while the headset is plugged (and main)
            src.simulateEvent(root.kb + ",French (Belgian)");
            src.simulateEvent("video-bus,French (Belgian)");
            src.simulateEvent("audeze-maxwell-hid,French (Belgian)");
            root.check("a real switch while plugged shows ONE card", root.cards.length === 1 && root.cards[0] === "French (Belgian)", root.cards.join());
            break;
        case 3:  // the headset is unplugged (no event); a new keyboard is plugged and the switch back is real too
            src.simulateEvent("some-usb-keyboard,English (US)");
            src.simulateDevices(root.devices("some-usb-keyboard", ["some-usb-keyboard"]));
            root.check("a second plug (Belgian in force): still no card", root.cards.length === 1, root.cards.join());
            src.simulateEvent(root.kb + ",English (US)");
            root.check("the switch back shows", root.cards.length === 2 && root.cards[1] === "English (US)", root.cards.join());
            break;
        case 4:  // the same layout again, and another keyboard's report, are nothing
            src.simulateEvent(root.kb + ",English (US)");
            src.simulateEvent("video-bus,French (Belgian)");
            root.check("the same layout twice and another keyboard's: nothing", root.cards.length === 2, root.cards.join());
            break;
        case 5:  // the primary itself goes (a re-plug of the only keyboard): the next list names the new main
            src.simulateEvent("replacement-kb,English (US)");
            src.simulateDevices(JSON.stringify({ keyboards: [{ name: "replacement-kb", layout: "us,be", active_keymap: "English (US)", main: true }] }));
            src.simulateEvent("replacement-kb,French (Belgian)");
            root.check("when the primary is gone the new main is the primary: its real switch shows", root.cards.length === 3 && root.cards[2] === "French (Belgian)", root.cards.join());
            break;
        default:
            console.log("OLP RESULT " + (root.fails === 0 ? "PASS" : "FAIL") + " (" + (root.checks - root.fails) + "/" + root.checks + " checks)");
            Qt.quit();
            return;
        }
        root.step++;
    }
    Timer {
        interval: 160                     // past dedupeMs (100): each step is its own moment
        repeat: true
        running: root.mode === "sim"
        onTriggered: root.run()
    }
    Timer {
        interval: 100
        running: root.mode === "live"
        onTriggered: console.log("OLP ready")
    }
}
