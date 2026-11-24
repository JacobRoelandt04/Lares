import QtQuick
import Quickshell
import Quickshell.Io
import "modules/common/system"

// tools/dev/qml/panorama_common_focus.qml -- FocusedScreen's `monitors all` read: `monitors` is what it was, `outputs` is complete,
// outputsChanged is silent for a focus or a workspace move. FocusedScreenOld.qml is the reader as it stood before (the runner
// puts it beside FocusedScreen from git). Prints "PCF ok|FAIL <name>" lines and "PCF RESULT PASS|FAIL".
Scope {
    id: root
    property string fix: Quickshell.env("PCOM_FIX")
    property int fails: 0
    property int checks: 0

    function check(name: string, ok: bool, detail: string): void {
        root.checks++;
        if (!ok)
            root.fails++;
        console.log("PCF " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }
    function j(v: var): string {
        return JSON.stringify(v);
    }

    FileView { id: laptopFile; path: root.bare ? "" : root.fix + "/monitors_all_laptop.json"; blockLoading: true; blockAllReads: true }
    FileView { id: threeFile; path: root.bare ? "" : root.fix + "/monitors_all_three_synthetic.json"; blockLoading: true; blockAllReads: true }

    FileView { id: srcFile; path: root.bare ? "" : Quickshell.env("PCOM_SYS") + "/FocusedScreen.qml"; blockLoading: true; blockAllReads: true }
    FocusedScreen { id: nu }
    // THE BOUNCE (feedback/workspaces.md "Ball x External monitor"): a fake of its own, every published state recorded
    FocusedScreen {
        id: bnc
        onChanged: root.bounceSeen.push({ name: bnc.name, l1: bnc.activeWorkspaceOf("LOCK-1"), l2: bnc.activeWorkspaceOf("LOCK-2") })
    }
    property var bounceSeen: []
    // smoked bare (no runner, no fixtures): build nothing, quit at once
    readonly property bool bare: !root.fix
    // The old reader exists only while the runner runs (it writes FocusedScreenOld.qml beside the new one, so its relative imports
    // resolve): it is loaded by URL, and only then, so a bare load never meets a missing type.
    Loader {
        id: oldLoader
        active: !root.bare
        source: root.bare ? "" : "modules/common/system/FocusedScreenOld.qml"
    }
    readonly property var old: oldLoader.item
    property int outEvents: 0
    property int chgEvents: 0
    Connections {
        target: nu
        function onOutputsChanged() { root.outEvents++; }
        function onChanged() { root.chgEvents++; }
    }

    // what plain `hyprctl -j monitors` printed: no disabled output, no mirroring one
    function plain(allText: string): string {
        return JSON.stringify(JSON.parse(allText).filter(m => m.disabled !== true && (m.mirrorOf === "none" || m.mirrorOf === undefined)));
    }
    function wsText(ids: var, fullscreen: var): string {
        return JSON.stringify(ids.map(i => ({ id: i, name: String(i), hasfullscreen: fullscreen === i })));
    }
    function same(label: string): void {
        root.check(label + ": monitors identical", root.j(nu.monitors) === root.j(root.old.monitors), root.j(nu.monitors) + " vs " + root.j(root.old.monitors));
        root.check(label + ": name and fullscreen identical", nu.name === root.old.name && nu.fullscreen === root.old.fullscreen, nu.name + "/" + root.old.name);
    }
    function both(allText: string, ws: string): void {
        root.old.beginReading();
        nu.beginReading();
        root.check("old reader parsed", root.old.applyReading(root.plain(allText), ws) === true, "");
        root.check("new reader parsed", nu.applyReading(allText, ws) === true, "");
    }
    function ev(name: string, data: string): void {
        root.old.handleEvent(name, data);
        nu.handleEvent(name, data);
    }

    // the steps start a turn later: the old reader's Loader completes after this root (a parent completes first)
    Timer {
        interval: 0
        running: true
        onTriggered: root.bare ? quitTimer.start() : root.run()
    }
    function run(): void {
        const laptop = laptopFile.text();
        const three = threeFile.text();
        root.check("the read asks for monitors all", srcFile.text().indexOf("hyprctl -j monitors all; echo") >= 0, "");
        root.check("fixtures read", laptop.length > 100 && three.length > 100, laptop.length + "/" + three.length);

        // ---- the laptop's real capture
        root.both(laptop, root.wsText([1, 2, 3], -1));
        root.same("laptop");
        root.check("laptop: one monitor, eDP-1, focused", nu.monitors.length === 1 && nu.name === "eDP-1" && nu.monitors[0].focused === true, root.j(nu.monitors));
        const o = nu.outputs;
        root.check("laptop: one output", o.length === 1, root.j(o));
        const e = o.length ? o[0] : {};
        const keys = ["name", "description", "make", "model", "serial", "id", "enabled", "width", "height", "refresh", "x", "y", "scale", "transform", "mirrorOf", "physW", "physH", "modes", "backend", "hdr", "bt2020", "vrrCapable", "vrr", "bitdepth", "cm", "sdrbrightness", "sdrsaturation", "driver"];
        root.check("laptop: every field of the record", keys.every(k => k in e) && Object.keys(e).length === keys.length, Object.keys(e).join(","));
        root.check("laptop: the values", e.name === "eDP-1" && e.make === "Samsung Display Corp." && e.model === "0x4180" && e.enabled === true && e.width === 2880 && e.height === 1620
                   && Math.abs(e.refresh - 120.002) < 1e-9 && e.scale === 1.25 && e.physW === 340 && e.physH === 190 && e.mirrorOf === "" && e.backend === "drm"
                   && e.hdr === true && e.bt2020 === true && e.vrrCapable === false && e.vrr === 0 && e.bitdepth === 10 && e.cm === "srgb" && e.driver === "", root.j(e));
        root.check("laptop: modes parsed, the first preferred", root.j(e.modes) === '[{"w":2880,"h":1620,"r":120,"preferred":true},{"w":2880,"h":1620,"r":60,"preferred":false}]', root.j(e.modes));
        root.check("laptop: outputsChanged fired once", root.outEvents === 1, String(root.outEvents));

        // ---- three outputs: one disabled, one mirroring, and the two names that never count
        const arr = JSON.parse(three);
        const hop = Object.assign({}, arr[1], { id: 7, name: "LARESLOCK-HOP", focused: false });
        const fb = Object.assign({}, arr[1], { id: 8, name: "FALLBACK", focused: false });
        const threePlus = JSON.stringify(arr.concat([hop, fb]));
        root.both(threePlus, root.wsText([1, 3, 4], 3));
        root.same("three");
        root.check("three: `monitors` lacks the disabled and the mirroring output", nu.monitors.map(m => m.name).join(",") === "eDP-1,DP-2,LARESLOCK-HOP,FALLBACK", nu.monitors.map(m => m.name).join(","));
        const names = nu.outputs.map(x => x.name).join(",");
        root.check("three: `outputs` has all four and neither the hop nor FALLBACK", names === "eDP-1,DP-2,HDMI-A-1,DVI-I-1", names);
        const byName = {};
        nu.outputs.forEach(x => { byName[x.name] = x; });
        root.check("three: the disabled one is listed with enabled false", byName["HDMI-A-1"].enabled === false && byName["HDMI-A-1"].transform === 1, root.j(byName["HDMI-A-1"]));
        root.check("three: mirrorOf is the SOURCE'S NAME (id 1 -> DP-2), \"\" otherwise", byName["DVI-I-1"].mirrorOf === "DP-2" && byName["DP-2"].mirrorOf === "", byName["DVI-I-1"].mirrorOf);
        root.check("three: vrr 1, bitdepth 8, mode count", byName["DP-2"].vrr === 1 && byName["DP-2"].bitdepth === 8 && byName["DP-2"].modes.length === 3 && byName["DP-2"].vrrCapable === true, root.j(byName["DP-2"]));

        // ---- shell.jsonc bars.outputs: a screen with no shell window is never the one to show a toast or the OSD on
        const foc = nu.name, other = foc === "eDP-1" ? "DP-2" : "eDP-1";
        nu.shellScreens = [other];
        root.check("displayFor: a screen with no shell window (bars.outputs) gives one that has a window", nu.displayFor("") === other && nu.displayFor(foc) === other
                   && nu.displayFor(other) === other, foc + " -> " + nu.displayFor(""));
        nu.shellScreens = [];
        root.check("... and with every screen a shell's, the word or the focused one", nu.displayFor("") === foc && nu.displayFor(other) === other, nu.displayFor(""));

        // ---- events: the same sequence on both readers
        root.ev("focusedmonv2", "DP-2,3");
        root.same("event focusedmonv2");
        root.ev("activespecialv2", "special:pad,special:pad,DP-2");
        root.ev("fullscreen", "1");
        root.same("event special + fullscreen");
        root.ev("monitorremovedv2", "1,DP-2,LG");
        root.same("event monitor removed");

        // ---- outputsChanged: silent for focus and workspace, loud for a mode
        const base = JSON.parse(three);
        const out0 = root.outEvents;
        root.both(three, root.wsText([1, 3, 4], -1));               // re-read after the removal event: DP-2 is back as far as the read goes
        const settled = root.outEvents;
        const chg0 = root.chgEvents;
        const moved = JSON.parse(three);
        moved[0].focused = false;
        moved[1].focused = true;
        moved[0].activeWorkspace = { id: 2, name: "2" };
        moved[1].activeWorkspace = { id: 5, name: "5" };
        moved[1].specialWorkspace = { address: "", type: "special", name: "special:pad" };
        nu.beginReading();
        nu.applyReading(JSON.stringify(moved), root.wsText([1, 2, 5], 5));
        root.check("a focus + workspace + special move: `changed` fired, `outputsChanged` did not", root.chgEvents > chg0 && root.outEvents === settled, root.chgEvents + "/" + chg0 + " " + root.outEvents + "/" + settled);
        nu.handleEvent("focusedmonv2", "eDP-1,2");
        nu.handleEvent("workspacev2", "9,9");
        nu.handleEvent("fullscreen", "0");
        root.check("focus / workspace / fullscreen EVENTS: outputsChanged silent", root.outEvents === settled, root.outEvents + "/" + settled);
        nu.refresh();
        root.check("refresh() on a fake asks nothing", root.outEvents === settled, "");
        const mode = JSON.parse(three);
        mode[1].width = 2560; mode[1].height = 1440; mode[1].refreshRate = 59.951;
        nu.beginReading();
        nu.applyReading(JSON.stringify(mode), root.wsText([1, 2, 5], -1));
        root.check("a mode change: outputsChanged fired once", root.outEvents === settled + 1, root.outEvents + "/" + settled);
        nu.beginReading();
        nu.applyReading(JSON.stringify(mode), root.wsText([1, 2, 5], -1));
        root.check("the same read again: silent", root.outEvents === settled + 1, String(root.outEvents));
        const sc = JSON.parse(JSON.stringify(mode));
        sc[1].scale = 1.5;
        nu.beginReading();
        nu.applyReading(JSON.stringify(sc), root.wsText([1, 2, 5], -1));
        root.check("a scale change: fired", root.outEvents === settled + 2, String(root.outEvents));
        // held: nothing is published until the release
        nu.held = true;
        const dis = JSON.parse(JSON.stringify(sc));
        dis[1].disabled = true;
        nu.beginReading();
        nu.applyReading(JSON.stringify(dis), root.wsText([1, 2, 5], -1));
        root.check("held: nothing published", root.outEvents === settled + 2 && nu.outputs.filter(x => x.name === "DP-2")[0].enabled === true, String(root.outEvents));
        nu.held = false;
        root.check("released: the held read is published once", root.outEvents === settled + 3 && nu.outputs.filter(x => x.name === "DP-2")[0].enabled === false, String(root.outEvents));

        // ---- the fake
        const n = root.outEvents;
        nu.setOutputs([{ name: "eDP-1", width: 2880, height: 1620 }, { name: "FALLBACK" }, { name: "DP-1", mirrorOf: "eDP-1", enabled: true }]);
        root.check("setOutputs: filled, ignored names left out, one signal", nu.outputs.length === 2 && nu.outputs[1].name === "DP-1" && nu.outputs[1].mirrorOf === "eDP-1" && nu.outputs[0].scale === 1 && root.outEvents === n + 1, root.j(nu.outputs));

        // ---- THE BOUNCE, as Hyprland 0.57.2 sent it (nested, a window under the pointer on LOCK-1): Super+3 for workspace 3, hidden on
        // LOCK-2, while LOCK-1 has the focus. The focus bounces back to LOCK-1 for an instant and workspacev2 comes in that instant
        const two = JSON.parse(laptop);
        const m1 = Object.assign({}, two[0], { id: 0, name: "LOCK-1", x: 0, focused: true, activeWorkspace: { id: 1, name: "1" } });
        const m2 = Object.assign({}, two[0], { id: 1, name: "LOCK-2", x: 2880, focused: false, activeWorkspace: { id: 2, name: "2" } });
        const wss = JSON.stringify([{ id: 1, name: "1", monitor: "LOCK-1" }, { id: 2, name: "2", monitor: "LOCK-2" }, { id: 3, name: "3", monitor: "LOCK-2" }]);
        bnc.beginReading();
        bnc.applyReading(JSON.stringify([m1, m2]), wss);
        root.bounceSeen = [];
        bnc.handleEvent("focusedmonv2", "LOCK-2,2");
        bnc.handleEvent("focusedmonv2", "LOCK-1,1");
        bnc.handleEvent("workspacev2", "3,3");
        bnc.handleEvent("destroyworkspacev2", "2,2");
        // the burst split across two turns, as the nested run delivered it: the focus comes back to LOCK-2 only in the next one, so the
        // workspace's home (the read's `monitor`) must say where 3 is
        bounceTimer.start();
    }
    // the workspace events are decided at the end of the turn they came in: judged a turn later
    property int _bounceStep: 0
    Timer {
        id: bounceTimer
        interval: 0
        onTriggered: {
            const seen = root.bounceSeen;
            if (root._bounceStep === 0) {
                bnc.handleEvent("focusedmonv2", "LOCK-2,3");
                root._bounceStep = 10;
                bounceTimer.start();
            } else if (root._bounceStep === 10) {
                root.check("bounce: LOCK-1's workspace never reads the workspace that opened on LOCK-2", seen.length > 0 && seen.every(x => x.l1 === 1), root.j(seen));
                root.check("bounce: LOCK-2 ends on 3 with the focus", bnc.activeWorkspaceOf("LOCK-2") === 3 && bnc.name === "LOCK-2", bnc.name + " " + bnc.activeWorkspaceOf("LOCK-2"));
                // a NEW workspace that opens on the other monitor (a rule), the same bounce: the burst's last focus says where it is
                root.bounceSeen = [];
                bnc.handleEvent("focusedmonv2", "LOCK-1,1");
                bnc.handleEvent("createworkspacev2", "6,6");
                bnc.handleEvent("focusedmonv2", "LOCK-2,3");
                bnc.handleEvent("focusedmonv2", "LOCK-1,1");
                bnc.handleEvent("workspacev2", "6,6");
                bnc.handleEvent("focusedmonv2", "LOCK-2,6");
                root._bounceStep = 1;
                bounceTimer.start();
            } else if (root._bounceStep === 1) {
                root.check("bounce, a new workspace: LOCK-1 never reads it", seen.length > 0 && seen.every(x => x.l1 === 1) && bnc.activeWorkspaceOf("LOCK-2") === 6, root.j(seen));
                // a plain switch on the focused monitor: a new workspace opens THERE
                bnc.handleEvent("focusedmonv2", "LOCK-1,1");
                bnc.handleEvent("createworkspacev2", "7,7");
                bnc.handleEvent("workspacev2", "7,7");
                root._bounceStep = 2;
                bounceTimer.start();
            } else {
                root.check("a new workspace with no other word opens on the focused monitor", bnc.activeWorkspaceOf("LOCK-1") === 7 && bnc.activeWorkspaceOf("LOCK-2") === 6, bnc.activeWorkspaceOf("LOCK-1") + " " + bnc.activeWorkspaceOf("LOCK-2"));
                console.log("PCF RESULT " + (root.fails === 0 ? "PASS" : "FAIL") + " (" + (root.checks - root.fails) + "/" + root.checks + ")");
                quitTimer.start();
            }
        }
    }
    Timer { id: quitTimer; interval: 0; onTriggered: Qt.quit() }
}
