pragma ComponentBehavior: Bound

import QtQuick
import QtTest
import Quickshell

import "modules/common/theme"
import "modules/common/components"
import "modules/bar/gooey"
import "modules/bar/reel"
import "modules/idle"
import "modules/windowtray"
import "modules/windowtray/data"
import "modules/launcher/data"
import "modules/shell/ReelItems.js" as ReelItems

// =============================================================================
// reel_ring_sheet.qml -- the reel slot's strips over a popup and over none, for the BEFORE / AFTER sheet of THE REEL'S CAST
// (tools/dev/reel_ring_sheet.sh runs it in a sandbox copy of ANY tree, offscreen; it touches only API both revisions have).
// A real GooeyEngine with the shell's edge on as shell.jsonc's halo + border (reach 28, strength 0.3, spread -20, softness 0.6, blend 12,
// ring 3), one top bar, the power and idle reels and the window title + tray over mocks, and a popup in one of two looks: `pop`, sky-blue
// (the weather's colours, so the dark halo and the ring read), and `list`, the shell's own surface with a carved list (the clipboard's
// look: a halo on a light popup). Every cell opens its scene, lets it settle (the content's fade at 1) and grabs the window 1:1 to
// $GRAB_DIR/<cell>.png; a merge cell closes the strip and freezes it at MERGE_T (0.25) of its close clock, the content's fade written to
// the share a 160 ms fade has reached at 400 ms.
//   <pop|list|none>_<idle|power|tray>_<rest|merge>     the strip over the popup, or over none
//   <pop|list|none>_<label|menu>_rest                  the tray's label / menu level (the reel's chain)
//   poke_tray_rest  a popup shorter than the strip: the seam where the field's own ring takes over
// (The reel at an island's end, on the slim bar, and the shell's real popups: tools/dev/reel_shell_sheet.sh.)
// Prints `SHEET cell <name> <png>` per cell and `SHEET RESULT PASS`. CELLS=a,b limits the run.
// BENCH=<n> (the pass's cost, tools/dev/reel_ring_sheet.sh): after a rest cell's picture, eight blocks of n grabs of the scene, none
// saved, at BENCH_SCALE (4) times its size -- each renders the engine's subtree again into a texture 16 times the scene and reads it back,
// so the GPU's fragment work is in the time, well over the grab's own floor --, the blocks alternately WITH the reel's layer over the
// popup (engine.reelCast) and with it at opacity 0 (not rendered): `SHEET bench <cell> n=<n> scale=<k> on=<mean ms per grab> off=<mean>
// layer=<(on - off) / k^2: the layer's cost for one frame of the scene at 1:1, ms>`.
// =============================================================================
ShellRoot {
    FloatingWindow {
        id: win
        implicitWidth: 760
        implicitHeight: 420
        visible: true
        color: "#7A7A86"

        TestCase {
            id: tc
            when: false
        }

        IconReelStyle {
            id: sharedStyle
        }
        WindowTrayStyle {
            id: trayStyle
        }
        AppLookup {
            id: lookup
        }
        readonly property var trayConfig: ({ follow: "focus", stripSuffix: true, rewrites: [], classIcons: [], trayOrder: [],
                                             trayHide: [], trayRename: {}, trayIconMode: "ink", terminalClasses: ["kitty"],
                                             terminalTitleMs: 0 })
        ActiveWindowMock {
            id: mockWindow
            config: win.trayConfig
            appLookup: lookup
        }
        TrayMock {
            id: mockTray
            config: win.trayConfig
            appLookup: lookup
        }

        GooeyEngine {
            id: engine
            anchors.fill: parent
            surfaceColor: Theme.surface
            shadowReach: 28
            shadowStrength: 0.3
            shadowSpread: -20
            shadowSoftness: 0.6
            shadowBlend: 12
            borderWidth: 3
            barsList: [topBar]

            GooeyBar {
                id: topBar
                engine: engine
                barId: "topBar"
                edge: "top"
                rawPos: 0
                rawLen: engine.w

                ReelBarModule {
                    id: powerMod
                    x: 270
                    engine: engine
                    bar: topBar
                    barId: "topBar"
                    ownerId: "power"
                    style: sharedStyle
                    items: ReelItems.POWER
                }
                ReelBarModule {
                    id: idleMod
                    x: 200
                    engine: engine
                    bar: topBar
                    barId: "topBar"
                    ownerId: "idle"
                    style: sharedStyle
                    items: ReelItems.IDLE
                    leftClickActivates: true
                    burstOnActivate: false
                }
                WindowTitleButton {
                    id: titleButton
                    x: 520
                    owner: trayOwner
                    window: mockWindow
                    tray: mockTray
                    appLookup: lookup
                    style: trayStyle
                    thickness: topBar.height
                    barRotation: topBar.rotation
                    ground: engine.surfaceColor
                }
            }
        }

        WindowTrayOwner {
            id: trayOwner
            engine: engine
            bar: topBar
            barId: "topBar"
            ownerId: "windowtray"
            window: mockWindow
            tray: mockTray
            appLookup: lookup
            config: win.trayConfig
            style: trayStyle
            reelStyle: sharedStyle
        }
        IdleService {
            id: svc
            live: false
        }

        // the popup: the weather's sky and a few cards (what the strip's ring and halo must read against)
        property real popupH: 300
        property string popupLook: "pop"
        Component {
            id: popupComp
            Item {
                implicitWidth: 460
                implicitHeight: win.popupH
                // `pop`: the weather's sky and a few cards
                Item {
                    anchors.fill: parent
                    visible: win.popupLook === "pop"
                    Rectangle {
                        anchors.fill: parent
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: "#8FBDF2" }
                            GradientStop { position: 1.0; color: "#D6E6F8" }
                        }
                    }
                    Repeater {
                        model: 3
                        Rectangle {
                            required property int index
                            x: 20 + index * 140
                            y: 190
                            width: 120
                            height: 80
                            radius: 10
                            color: "#F2F7FD"
                        }
                    }
                    Text {
                        x: 24
                        y: 150
                        text: "18°  Partly cloudy"
                        font.pixelSize: 20
                        color: "#2B4A70"
                    }
                }
                // `list`: the shell's surface (the field's own, nothing painted) with a carved list, as the clipboard's
                Item {
                    anchors.fill: parent
                    visible: win.popupLook === "list"
                    Rectangle {
                        x: 12
                        y: 12
                        width: parent.width - 24
                        height: parent.height - 24
                        radius: 14
                        color: Theme.listBox
                        border.width: 1
                        border.color: Theme.border
                        Column {
                            x: 6
                            y: 6
                            width: parent.width - 12
                            spacing: 4
                            Repeater {
                                model: 7
                                Rectangle {
                                    required property int index
                                    width: parent.width
                                    height: 32
                                    radius: 8
                                    color: index === 1 ? Theme.panelSunk : "transparent"
                                    Text {
                                        x: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: ["git status --short", "https://quickshell.org/docs/", "the reel's ring", "#4480F4", "18°  Partly cloudy", "sudo pacman -Syu", "Deep menus"][index]
                                        font.pixelSize: 12
                                        color: Theme.textPrimary
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        readonly property var deepSpec: ({
            id: "sheet-deep", title: "Deep menus", icon: "", status: "Active", category: "ApplicationStatus",
            menu: [{ text: "Header", enabled: false }, { isSeparator: true },
                   { text: "_Available networks", children: [{ text: "Network 2" }, { text: "Network 3" }] },
                   { text: "Edit Connections…" }]
        })
        property string deepKey: ""

        readonly property string grabDir: Quickshell.env("GRAB_DIR") || ""
        readonly property real mergeT: Number(Quickshell.env("MERGE_T") || 0.25)
        readonly property var cells: {
            const out = [];
            for (const pop of ["pop", "list", "none"]) {
                for (const reel of ["idle", "power", "tray"])
                    for (const at of ["rest", "merge"])
                        out.push({ n: pop + "_" + reel + "_" + at, pop: pop, reel: reel, at: at });
                out.push({ n: pop + "_label_rest", pop: pop, reel: "tray", at: "rest", label: true });
                out.push({ n: pop + "_menu_rest", pop: pop, reel: "tray", at: "rest", menu: true });
            }
            out.push({ n: "poke_tray_rest", pop: "pop", reel: "tray", at: "rest", h: 110 });
            return out;
        }
        readonly property var want: (Quickshell.env("CELLS") || "").split(",").filter(s => s !== "")

        function centreOf(it: Item): point {
            return it.mapToItem(win.contentItem, it.width / 2, it.height / 2);
        }
        function hoverOn(it: Item): void {
            const p = win.centreOf(it);
            tc.mouseMove(win.contentItem, p.x - 3, p.y);
            tc.mouseMove(win.contentItem, p.x, p.y);
        }
        function away(): void {
            tc.mouseMove(win.contentItem, 740, 410);
        }

        // ---- the sequence: per cell, a list of steps run by one timer --------------------------------------------------
        property int cellAt: -1
        property var steps: []
        property int stepAt: 0
        property bool acted: false
        property int ticks: 0
        property var cell: null
        property var frozen: null
        readonly property var idle0: ({})

        function reelOut(): bool {
            return engine.reelOpen && engine.reelPhase === "open" && engine.theReel.contentOpacity >= 0.999;
        }
        function allClosed(): bool {
            return engine.reelPhase === "closed" && !engine.popupOpen && engine.thePopup.phase === "closed";
        }
        function build(c): var {
            const S = [];
            S.push({ act: () => { win.popupH = c.h || 300; win.popupLook = c.pop === "list" ? "list" : "pop"; }, wait: 1 });
            if (c.pop !== "none")
                S.push({ act: () => engine.open("probe", "topBar", 390, null, null, false, popupComp, 0.5),
                         cond: () => engine.popupOpen && engine.thePopup.phase === "open" && engine.thePopup.contentOpacity >= 0.999 });
            S.push({ act: () => win.hoverOn(c.reel === "idle" ? idleMod : c.reel === "power" ? powerMod : titleButton.iconCell), cond: () => win.reelOut() });
            if (c.label)
                S.push({ act: () => trayOwner.cellHover(win.deepKey, trayOwner.rowIndexOf(win.deepKey), true),
                         cond: () => engine.reelChildPopups[0].phase === "open" && engine.reelChildPopups[0].contentOpacity >= 0.999 });
            if (c.menu)
                S.push({ act: () => trayOwner.openMenu(win.deepKey), cond: () => trayOwner.menuOpen && engine.reelChildPopups[0].phase === "open"
                                                                   && engine.reelChildPopups[0].contentOpacity >= 0.999 });
            if (c.at === "merge") {
                S.push({ act: () => win.away(), cond: () => engine.reelPhase === "closing" && engine.theReel.t >= win.mergeT });
                S.push({ act: () => {
                             const R = engine.theReel;
                             R.stop();
                             R.t = win.mergeT;
                             R.contentOpacity = Math.max(0, 1 - win.mergeT * 400 / 160);
                             win.frozen = { slot: R, t: win.mergeT, o: R.contentOpacity };
                             engine.layout();
                         }, wait: 4 });
            }
            S.push({ act: () => {}, wait: 12 });
            S.push({ act: () => {
                         const f = win.grabDir + "/" + c.n + ".png";
                         win.grabbed = "";
                         engine.grabToImage(r => {
                             console.log("SHEET cell " + c.n + " " + (r.saveToFile(f) ? f : "FAILED"));
                             win.grabbed = c.n;
                         });
                     }, cond: () => win.grabbed === c.n });
            if (win.bench > 0 && c.at === "rest") {
                S.push({ act: () => {
                             win.benchSum = [0, 0];
                             win.benchBlock = 0;
                             win.benchDone = false;
                             win.benchStart(c.n);
                         }, cond: () => win.benchDone, max: 15000 });
            }
            S.push({ act: () => { if (win.frozen) { const R = win.frozen.slot; win.frozen = null; R.fadeTo(0, 1); R.runTo(1, 20); } win.away(); }, cond: () => win.allClosed() || (win.ticks > 60 && win.forceClose()) });
            return S;
        }
        property string grabbed: ""
        // BENCH (header)
        readonly property int bench: Number(Quickshell.env("BENCH") || 0)
        readonly property real benchScale: Number(Quickshell.env("BENCH_SCALE") || 4)
        property int benchLeft: 0
        property int benchBlock: 0
        property real benchT0: 0
        property var benchSum: [0, 0]
        property bool benchDone: false
        function benchStart(name: string): void {
            const off = win.benchBlock % 2 === 1;
            engine.reelCast.opacity = off ? 0 : 1;
            win.benchLeft = win.bench;
            win.benchT0 = Date.now();
            win.benchStep(name);
        }
        function benchStep(name: string): void {
            engine.grabToImage(r => {
                if (--win.benchLeft > 0) {
                    win.benchStep(name);
                    return;
                }
                win.benchSum[win.benchBlock % 2] += Date.now() - win.benchT0;
                if (++win.benchBlock < 8) {
                    win.benchStart(name);
                    return;
                }
                engine.reelCast.opacity = 1;
                const on = win.benchSum[0] / (4 * win.bench), off = win.benchSum[1] / (4 * win.bench);
                console.log("SHEET bench " + name + " n=" + win.bench + " scale=" + win.benchScale + " on=" + on.toFixed(3) + " off=" + off.toFixed(3)
                            + " layer=" + ((on - off) / (win.benchScale * win.benchScale)).toFixed(4));
                win.benchDone = true;
            }, Qt.size(Math.round(engine.width * win.benchScale), Math.round(engine.height * win.benchScale)));
        }
        // a popup left open after the pointer is away is closed by hand
        function forceClose(): bool {
            if (engine.popupOpen && engine.thePopup.phase === "open")
                engine.close();
            return win.allClosed();
        }

        function next(): void {
            win.cellAt++;
            const list = win.cells.filter(c => win.want.length === 0 || win.want.indexOf(c.n) >= 0);
            if (win.cellAt >= list.length) {
                console.log("SHEET RESULT PASS");
                quitT.start();
                return;
            }
            win.cell = list[win.cellAt];
            win.steps = win.build(win.cell);
            win.stepAt = 0;
            win.acted = false;
        }
        Timer {
            id: quitT
            interval: 200
            onTriggered: Qt.quit()
        }
        Timer {
            interval: 20
            repeat: true
            running: true
            onTriggered: {
                // a clock restarted under a frozen merge is stopped again where it stood
                if (win.frozen && win.frozen.slot.t !== win.frozen.t) {
                    win.frozen.slot.stop();
                    win.frozen.slot.t = win.frozen.t;
                    win.frozen.slot.contentOpacity = win.frozen.o;
                }
                if (win.cellAt < 0) {
                    if (!(engine.w > 0 && topBar.thickness > 0))
                        return;
                    if (win.deepKey === "") {
                        mockWindow.setWindow({ cls: "kitty", title: "~/.config/quickshell", initialTitle: "kitty" });
                        win.deepKey = mockTray.add(win.deepSpec);
                    }
                    if (mockTray.empty)
                        return;
                    win.next();
                    return;
                }
                if (win.cellAt >= 0 && win.stepAt >= win.steps.length) {
                    win.next();
                    return;
                }
                const s = win.steps[win.stepAt];
                if (!win.acted) {
                    win.acted = true;
                    win.ticks = 0;
                    s.act();
                    return;
                }
                win.ticks++;
                const ready = s.cond ? s.cond() : win.ticks >= (s.wait || 1);
                if (!ready && win.ticks < (s.max || 400))
                    return;
                if (!ready)
                    console.log("SHEET FAIL " + win.cell.n + " step " + win.stepAt + " timed out: reel " + engine.reelPhase + " popup " + engine.thePopup.phase);
                win.stepAt++;
                win.acted = false;
            }
        }
    }
}
