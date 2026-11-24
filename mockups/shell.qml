//@ pragma IconTheme Papirus
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

import "modules/common/components"
import "modules/common/mockup"
import "modules/common/theme"
import "modules/osd"
import "modules/shell"
import "modules/shell/ShellLayout.js" as ShellLayout

// =============================================================================
// mockups/shell.qml -- the whole shell on ONE screen, at a real output size, over the real wallpaper.
//
// The same ShellFrame the shell's windows host (modules/shell/ShellFrame.qml: the engine, the three islands
// and the three outlets, every module of PLAN.md's table, every owner with its service injected), with the
// shell's MOCK services (ShellServices, mode mock: every module's own mock twin, every path under
// $XDG_STATE_HOME/lares-shell-mock/, every command recorded and none run, no D-Bus name, no polkit
// agent, no tray host, no sound, no notify-send). Nothing here touches the desktop.
//
//   Run          the output's size, the bars toggle, a popup out of every module, toasts, an OSD, the
//                readouts of what the reels and the volume halves did
//   Layout       two sub-tabs. shell.jsonc: FILE-BACKED to the mock config's shell.jsonc -- the islands / continuous
//                switch, the island lengths, the title's slot, the zone order; written as the rows move, the shell
//                reads it hot; "Copy to the desktop's shell.jsonc" (Run) is the user's deliberate act: two clicks.
//                Constants: ShellConfig's own numbers (the island, the slots, the workspaces, the joint, the halo),
//                which Save writes into ShellConfig.qml.
//
// THE STAGE is one screen at its real size, zoomed to fit beside the panel (ZOOM=1 for a render).
//
// Env (renders and probes):  OUT=laptop|ultrawide   STATE=<rest | open:<module> | toasts | osd | hidden |
//      continuous | volume>   (open:<module> also takes wiki: the clock's card)   STAGE_GRAB=<png> GRAB_MS=<ms> (the stage alone, then quit)
//              THEME_SYNC=<dir> (the theme sync's four frames of the window, then quit)
//      ZOOM  WALL=<url>
//      SCALE=<k>          the shell's global scale (shell.jsonc `scale.global`): the frame and the OSD pill sit in a ScaleRoot of k, as in ShellScreen,
//                         so a render shows the screen as the glass would at that scale
//      BAR_RATIO=<r> POPUP_RATIO=<r>   the bar's and the popups' RATIOS on it (shell.jsonc `scale.bar` / `scale.popup`, 1 by default; ShellFrame):
//                         the bar and its modules laid out in their own units and drawn r times larger, every popup's content likewise
// =============================================================================
MockupWindow {
    id: win

    moduleId: "shell"
    title: "Shell"
    stageLabel: "One screen of the shell at its real size over the real wallpaper -- mock services, nothing run"
    content: scene
    sheetGrabItem: scene
    target: layoutKnobs
    targets: ({
            layoutParams: layoutKnobs,
            layoutConsts: shellServices.shellConfig
        })
    fileBackedLists: ({
            layoutParams: "shell.jsonc"
        })
    fitContent: true
    zoom: Number(Quickshell.env("ZOOM") || 0.45)
    panelWidth: 480

    lists: ({
            layoutParams: win.layoutParams,
            layoutConsts: win.layoutConsts
        })

    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        {
            name: "Layout",
            subs: [
                {
                    name: "shell.jsonc",
                    lists: ["layoutParams"]
                },
                {
                    name: "Constants",
                    lists: ["layoutConsts"]
                }
            ]
        }
    ]

    // ---- the output --------------------------------------------------------------------------------------
    readonly property bool ultrawide: (Quickshell.env("OUT") || "") === "ultrawide"
    property bool wide: win.ultrawide
    // the shell's global scale: device px per design px (ShellScreen's ScaleRoot; the pill's own)
    readonly property real shellScale: Math.max(0.5, Number(Quickshell.env("SCALE") || 1))
    // the bar's and the popups' ratios on the frame (ScaleConfig's range)
    readonly property real barRatio: Math.max(0.5, Math.min(2, Number(Quickshell.env("BAR_RATIO") || 1)))
    readonly property real popupRatio: Math.max(0.5, Math.min(2, Number(Quickshell.env("POPUP_RATIO") || 1)))
    readonly property int outW: win.wide ? 3440 : 2880
    readonly property int outH: win.wide ? 1440 : 1620
    readonly property string outName: win.wide ? "DP-3" : "eDP-1"

    // ---- the services: the mock mode, no layer-shell window ----------------------------------------------------
    ShellServices {
        id: shellServices
        mode: "mock"
        windowless: true
    }

    // ---- the wallpaper (mockups/power.qml's: the real one, following the theme) ---------------------------------
    MockupWallpaper {
        id: stageWall
    }
    readonly property string wallpaper: stageWall.source

    // =====================================================================
    //  THE STAGE: one screen
    // =====================================================================
    readonly property var frame: frameLoader.item
    Item {
        id: scene
        implicitWidth: win.outW
        implicitHeight: win.outH

        Rectangle {
            anchors.fill: parent
            color: win.stageColor
        }
        Image {
            anchors.fill: parent
            source: win.wallpaper
            asynchronous: true
            cache: true
            fillMode: Image.PreserveAspectCrop
        }
        // The screen as ShellScreen draws it: everything below is laid out in DESIGN px (the screen's size / k) and drawn k times larger.
        ScaleRoot {
            id: frameRoot
            factor: win.shellScale
            hostWidth: scene.width
            hostHeight: scene.height
            // Built when the services are: an owner made before them builds its own, the real one.
            Loader {
                id: frameLoader
                anchors.fill: parent
                active: shellServices.ready
                sourceComponent: Component {
                    ShellFrame {
                        services: shellServices
                        screenName: win.outName
                        renderScale: (win.stage ? win.stage.zoom : 1) * win.shellScale
                        frameScale: win.shellScale
                        barRatio: win.barRatio
                        popupRatio: win.popupRatio
                        osdPill: pill
                    }
                }
            }
            // The OSD's capsule over a fullscreen window: the shell's OsdPillWindow, here an item on the stage.
            OsdPill {
                id: pill
                z: 50
                style: shellServices.osdStyle
                renderScale: (win.stage ? win.stage.zoom : 1) * win.shellScale
                x: Math.round((frameRoot.width - pill.width) / 2)
                y: Math.round(shellServices.osdStyle.pillTop)
            }
        }
    }

    // =====================================================================
    //  THE RUN PAGE
    // =====================================================================
    // what each module's button opens: [label, owner key]
    readonly property var popupButtons: [
        ["power", "power"], ["idle", "idle"], ["notes", "notes"], ["window", "windowtray"], ["weather", "weather"],
        ["clock", "clock"], ["stocks", "stocks"], ["player", "player"], ["aerial", "aerial"], ["bridge", "bridge"], ["panorama", "panorama"],
        ["silicon", "silicon"], ["update", "update"], ["bell", "notifications"], ["llm", "llm"]
    ]
    function openOwner(key: string): void {
        if (!win.frame)
            return;
        if (key === "wiki") {
            // the wiki's card: the clock popup's secondary, on its Discover face
            win.frame.owners.clock.openWiki("discover");
            win.runStatus = "opened the wiki card";
            return;
        }
        const o = win.frame.owners[key];
        if (!o) {
            win.runStatus = key + ": no such owner";
            return;
        }
        // The cleanup check's sheet (SHEET_GRAB): what moves on a clock of its own stays still. The cards' float, the audio lines' level clock.
        if (key === "theme" && win.sheetGrabPath !== "")
            o.shown = false;
        if (key === "audio" && win.sheetGrabPath !== "")
            shellServices.audio.setSetting("meters", false);
        if (key === "power" || key === "idle") {
            o.pinnedOpen = !o.pinnedOpen;
        } else if (key === "windowtray") {
            // the strip closes when the pointer is not on it: pinned, it stays (a click's toggle() would be closed by its own grace)
            if (o.popupMine) {
                o.pinnedOpen = false;
                o.close();
            } else {
                o.pinnedOpen = true;
                o.open();
            }
        } else {
            o.toggle();
        }
        win.runStatus = "toggled " + key;
    }
    function post(n: int, urgency: string): void {
        const bodies = ["Build finished: 12 warnings.", "Messier 87 is a supergalactic elliptical galaxy.", "Backup completed in 41 s.", "Battery at 79 %.", "A new device was connected."];
        for (let i = 0; i < n; i++)
            shellServices.notifications.post({ source: "shelltest", key: "t" + Date.now() + "-" + i, appName: "Shell test",
                                          title: ["Compile", "Messier 87", "Backup", "Battery", "USB"][i % 5], body: bodies[i % 5],
                                          urgency: urgency, timeoutMs: urgency === "critical" ? -1 : 9000 });
        win.runStatus = "posted " + n + " (" + urgency + ")";
    }
    property string runStatus: "nothing yet"
    property bool armedCopy: false
    Timer {
        id: copyDisarm
        interval: 4000
        onTriggered: win.armedCopy = false
    }

    pages: [
        MockupPage {
            id: runPage

            TipGroup {
                title: "Screen"
                blurb: "One output at its real size; the same frame the shell's windows host."
            }
            TipRow {
                tip: "The output the stage stands for: the laptop's 2880 x 1620 or the ultrawide's 3440 x 1440. The islands' default lengths are computed for each, and the layout's per-output lengths (Layout tab) are keyed by connector name: eDP-1 and DP-3."
                Button {
                    text: "2880 x 1620"
                    highlighted: !win.wide
                    onClicked: win.wide = false
                }
                Button {
                    text: "3440 x 1440"
                    highlighted: win.wide
                    onClicked: win.wide = true
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Super+F2 in the shell: every bar eases to the least thickness the engine takes (2 px), the main bar's reserve is released at the start, a popup that is out is closed. Show reverses it and restores the reserve when it has finished."
                Button {
                    text: shellServices.barsShown ? "Hide the bars" : "Show the bars"
                    onClicked: shellServices.barsShown = !shellServices.barsShown
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "Popups"
                blurb: "What a click on each button does; launcher and clipboard are keys only."
            }
            TipRow {
                tip: "Toggles the owner as its button would: the popup comes out of the outlet the layout table gives it (notes at the left bar's top, the rest under their button). The reels and the window title's strip open on hover; here they are held open."
                Flow {
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: win.popupButtons
                        Button {
                            required property var modelData
                            text: modelData[0]
                            onClicked: win.openOwner(modelData[1])
                        }
                    }
                    Button {
                        text: "close"
                        onClicked: win.frame && win.frame.closeAll()
                    }
                }
            }
            TipRow {
                tip: "The launcher and the clipboard come out of the bottom bar's middle on Alt+Space / Alt+V; the router sends the key to the focused screen's owner (shortcutPressed / toggle). Here the router is called directly -- the compositor's keys are the platform probe's."
                Button {
                    text: "Alt+Space"
                    onClicked: {
                        const o = win.frame ? win.frame.owners.launcher : null;
                        if (o)
                            o.toggle();
                    }
                }
                Button {
                    text: "Alt+V"
                    onClicked: {
                        const o = win.frame ? win.frame.owners.clipboard : null;
                        if (o)
                            o.toggle();
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "Toasts, OSD"
                blurb: "The notification lane hangs from the top bar's right end; the OSD comes out of the right bar's middle."
            }
            TipRow {
                tip: "Posts shell notifications through the in-process service (the mock never reaches D-Bus): one, three, one critical (sticky). They stack at the top bar's right end under the bell."
                Button {
                    text: "1 toast"
                    onClicked: win.post(1, "normal")
                }
                Button {
                    text: "3 toasts"
                    onClicked: win.post(3, "normal")
                }
                Button {
                    text: "critical"
                    onClicked: win.post(1, "critical")
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "A request to the OSD's service, as the keys make them: a card comes out of the right bar at 0.5 of its length (osd.jsonc's spot) and goes after its time; a second kind dips and rises with the new content."
                Button {
                    text: "volume"
                    onClicked: shellServices.osd.test("volume")
                }
                Button {
                    text: "brightness"
                    onClicked: shellServices.osd.test("brightness")
                }
                Button {
                    text: "track"
                    onClicked: shellServices.osd.test("track")
                }
                Button {
                    text: "battery"
                    onClicked: shellServices.osd.test("battery")
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "What it did"
                blurb: "The mock records what a click would have run."
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: Theme.textFaint
                font.family: "Audiowide"
                font.pixelSize: 12
                lineHeight: 1.3
                text: {
                    const calls = shellServices.commands.calls;
                    const last = calls.length > 0 ? calls[calls.length - 1].argv.join(" ") : "-";
                    return "status: " + win.runStatus + "\nlast command: " + last + "  (" + calls.length + " recorded)\nidle: "
                        + shellServices.idle.mode + (shellServices.idle.held ? "  (hard lock would be held)" : "") + "   theme: " + Theme.mode
                        + "   oled: " + (shellServices.oled.on ? "on" : "off")
                        + "\nfocused: " + shellServices.focusedScreen + "   mode: " + shellServices.mode;
                }
            }
            TipRow {
                tip: "Writes the Layout tab's shell.jsonc to the desktop's own ~/.config/quickshell/config/shell.jsonc, which the real shell reads hot. Two clicks within four seconds: the first arms it. The mockup never writes the desktop's file any other way."
                Button {
                    text: win.armedCopy ? "Confirm: copy to the desktop" : "Copy to the desktop's shell.json"
                    onClicked: {
                        if (!win.armedCopy) {
                            win.armedCopy = true;
                            copyDisarm.restart();
                            return;
                        }
                        win.armedCopy = false;
                        desktopFile.setText(JSON.stringify(shellServices.shellConfig.raw, null, 2) + "\n");
                        win.runStatus = "wrote " + desktopFile.activePath;
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }
        }
    ]

    // The desktop's own shell.jsonc: only ever written by the button above.
    ConfigFile {
        id: desktopFile
        path: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/quickshell/config/shell.jsonc"
        watchChanges: false
    }

    // =====================================================================
    //  THE LAYOUT KNOBS: shell.jsonc's keys. The panel writes the mock config's file as they move (only the
    //  keys changed, over what the file held); ShellConfig reads it back hot, and the frame follows.
    // =====================================================================
    QtObject {
        id: layoutKnobs
        // 0 islands, 1 continuous
        property int topMode: 0
        // 0 centred on the screen, 1 equal voids
        property int centreMode: 0
        // The island lengths of the stage's output; 0 = what the modules need.
        property int lengthLeft: 0
        property int lengthCentre: 0
        property int lengthRight: 0
        // The zone orders, as JSON arrays of module ids.
        property string zoneLeft: "[\"power\",\"idle\",\"theme\",\"presets\",\"notes\",\"llm\",\"windowtray\"]"
        property string zoneCentre: "[\"weather\",\"clock\",\"stocks\"]"
        property string zoneRight: "[\"player\",\"volume\",\"aerial\",\"bridge\",\"panorama\",\"silicon\",\"update\",\"notifications\"]"
        // Where notes and the LLM open along the left bar: 0 is its top, under the left island.
        property real notesAlong: 0
        property real llmAlong: 0
    }
    property var _layoutBase: ({})
    property bool _layoutReady: false
    // The shell.jsonc object for the knobs: what the file held, with the knobs' values over it.
    function layoutObject(): var {
        const o = JSON.parse(JSON.stringify(win._layoutBase || {}));
        const d = ShellLayout.defaults();
        const set = (k, v, dv) => {
            if (v === dv)
                delete o[k];
            else
                o[k] = v;
        };
        set("topMode", ["islands", "continuous"][layoutKnobs.topMode], d.topMode);
        set("centre", ["centred", "equal"][layoutKnobs.centreMode], d.centre);
        const isl = Object.assign({}, o.islands || {});
        const mine = {};
        if (layoutKnobs.lengthLeft > 0)
            mine.left = layoutKnobs.lengthLeft;
        if (layoutKnobs.lengthCentre > 0)
            mine.centre = layoutKnobs.lengthCentre;
        if (layoutKnobs.lengthRight > 0)
            mine.right = layoutKnobs.lengthRight;
        if (Object.keys(mine).length > 0)
            isl[win.outName] = mine;
        else
            delete isl[win.outName];
        if (Object.keys(isl).length > 0)
            o.islands = isl;
        else
            delete o.islands;
        const zones = {};
        for (const z of [["left", layoutKnobs.zoneLeft], ["centre", layoutKnobs.zoneCentre], ["right", layoutKnobs.zoneRight]]) {
            try {
                const a = JSON.parse(z[1]);
                if (Array.isArray(a))
                    zones[z[0]] = a;
            } catch (e) {
            }
        }
        if (JSON.stringify(zones) === JSON.stringify(d.zones))
            delete o.zones;
        else
            o.zones = zones;
        const out = {};
        if (layoutKnobs.notesAlong !== 0)
            out.notes = { bar: "left", along: layoutKnobs.notesAlong };
        if (layoutKnobs.llmAlong !== 0)
            out.llm = { bar: "left", along: layoutKnobs.llmAlong };
        if (Object.keys(out).length > 0)
            o.outlets = Object.assign({}, o.outlets || {}, out);
        else
            delete o.outlets;
        return o;
    }
    function layoutTouched(): void {
        if (win._layoutReady)
            layoutWrite.restart();
    }
    Timer {
        id: layoutWrite
        interval: 150
        onTriggered: shellServices.shellConfig.write(win.layoutObject())
    }
    // Read the file into the knobs once the framework has pushed its defaults in; then listen.
    function layoutInit(): void {
        const raw = shellServices.shellConfig.raw || {};
        win._layoutBase = JSON.parse(JSON.stringify(raw));
        const c = shellServices.shellConfig.config;
        layoutKnobs.topMode = c.topMode === "continuous" ? 1 : 0;
        layoutKnobs.centreMode = c.centre === "equal" ? 1 : 0;
        const own = c.islands[win.outName] || {};
        layoutKnobs.lengthLeft = own.left || 0;
        layoutKnobs.lengthCentre = own.centre || 0;
        layoutKnobs.lengthRight = own.right || 0;
        layoutKnobs.zoneLeft = JSON.stringify(c.zones.left);
        layoutKnobs.zoneCentre = JSON.stringify(c.zones.centre);
        layoutKnobs.zoneRight = JSON.stringify(c.zones.right);
        layoutKnobs.notesAlong = c.outlets.notes.along;
        layoutKnobs.llmAlong = c.outlets.llm.along;
        for (const k of ["topMode", "centreMode", "lengthLeft", "lengthCentre", "lengthRight", "zoneLeft", "zoneCentre", "zoneRight", "notesAlong", "llmAlong"])
            (layoutKnobs as QtObject)[k + "Changed"].connect(() => win.layoutTouched());
        win._layoutReady = true;
    }
    Timer {
        running: true
        interval: 0
        onTriggered: win.layoutInit()
    }

    // =====================================================================
    //  THE ENV: a state to render
    // =====================================================================
    function applyState(): void {
        const st = Quickshell.env("STATE") || "rest";
        if (st.indexOf("open:") === 0) {
            win.openOwner(st.substring(5));
        } else if (st === "toasts") {
            win.post(3, "normal");
        } else if (st === "critical") {
            win.post(1, "critical");
        } else if (st === "osd") {
            // held: the card would be dismissed (its own timer) long before a grab at GRAB_MS
            shellServices.osd.config.apply({ dismissMs: 600000 });
            shellServices.osd.test("volume");
        } else if (st === "hidden") {
            shellServices.barsShown = false;
        } else if (st === "continuous") {
            layoutKnobs.topMode = 1;
            win.layoutWriteNow();
        } else if (st === "volume") {
            shellServices.osd.config.apply({ dismissMs: 600000 });
            shellServices.osd.volume("mute");
        }
    }
    function layoutWriteNow(): void {
        shellServices.shellConfig.write(win.layoutObject());
    }
    Timer {
        running: true
        interval: 1200
        onTriggered: win.applyState()
    }

    // ---- THEME_SYNC=<dir>: the theme sync's frames of the WHOLE window ---------------------
    // The mode is switched at syncT0 and the window grabbed mid-fade, just after the fade, and 1.4 s and 2 s after it. The window,
    // not the stage: the light/dark crossfade is a quad over the mockup's body, and a grab of the stage alone would sit under it.
    // Timers, not an animation: a window nobody presents freezes the fade AND the schedule, so the run would hang instead of fail.
    readonly property string themeSync: Quickshell.env("THEME_SYNC") || ""
    readonly property int syncT0: 3500
    property int _synced: 0
    function syncGrab(name: string): void {
        win.contentItem.grabToImage(r => {
            r.saveToFile(win.themeSync + "/" + name + ".png");
            console.log("SYNC grabbed " + name);
            // quit when ALL four are on disk (a heavy frame can finish a grab after the next one was asked for)
            if (++win._synced >= 4)
                syncQuit.start();
        });
    }
    Timer {
        id: syncQuit
        interval: 300
        onTriggered: Qt.quit()
    }
    Timer {
        running: win.themeSync !== ""
        interval: win.syncT0 + Theme.fadeMs + 12000
        onTriggered: {
            console.log("SYNC giving up: only " + win._synced + " of 4 frames were saved");
            Qt.quit();
        }
    }
    Timer {
        running: win.themeSync !== ""
        interval: win.syncT0
        onTriggered: {
            console.log("SYNC fadeMs=" + Theme.fadeMs + " from=" + Theme.mode);
            Theme.toggleMode();
        }
    }
    Timer {
        running: win.themeSync !== ""
        interval: win.syncT0 + Math.round(Theme.fadeMs / 2)
        onTriggered: win.syncGrab("mid")
    }
    Timer {
        running: win.themeSync !== ""
        interval: win.syncT0 + Theme.fadeMs + Number(Quickshell.env("SLACK_MS") || 80)
        onTriggered: win.syncGrab("settle")
    }
    Timer {
        running: win.themeSync !== ""
        interval: win.syncT0 + Theme.fadeMs + 1400
        onTriggered: win.syncGrab("final")
    }
    Timer {
        running: win.themeSync !== ""
        interval: win.syncT0 + Theme.fadeMs + 2000
        onTriggered: win.syncGrab("final2")
    }

    // ---- EYE_FILM=<dir>: the lock's closing of the workspaces' split, frame by frame -------------------------------
    // The eye's clock (ShellFrame.eyeT, what the animation drives) is held by hand and stepped EYE_STEP (default 0.02) from 0 to 1 and back; at each step
    // the stage is grabbed whole into <dir>/c<i>.png (closing) and o<i>.png (opening), and `EYEFRAME <name> <lids> <slots> <dots>` says what it read (the dots in stage px).
    // `EYEFILM DONE` ends it. Every frame of the animation is one of these pictures: the rails, the fills, the dots and the ball read nothing but the clock.
    readonly property string eyeFilm: Quickshell.env("EYE_FILM") || ""
    readonly property real eyeStep: Number(Quickshell.env("EYE_STEP") || 0.02)
    property int eyeI: 0
    property string eyePhase: ""
    function eyeFrame(): var {
        const n = Object.keys(shellServices.frames)[0];
        return shellServices.frames[n];
    }
    function eyeNext(): void {
        const f = win.eyeFrame();
        if (!f)
            return;
        const closing = win.eyePhase === "closing";
        const v = Math.max(0, Math.min(1, closing ? win.eyeI * win.eyeStep : 1 - win.eyeI * win.eyeStep));
        shellServices.eyeSet = v;
        eyeGrab.v = v;
        eyeGrab.restart();
    }
    Timer {
        id: eyeGrab
        property real v: 0
        interval: 120                       // a few frames for the rails to be painted and the clock cut at this fraction
        onTriggered: {
            const closing = win.eyePhase === "closing";
            const name = (closing ? "c" : "o") + String(win.eyeI).padStart(3, "0");
            scene.grabToImage(r => {
                r.saveToFile(win.eyeFilm + "/" + name + ".png");
                const f = win.eyeFrame();
                const x0 = f.workspaces.mapToItem(scene, 0, 0).x;
                console.log("EYEFRAME " + name + " " + f.eyeF.toFixed(4) + " " + f.eyeSlotsF.toFixed(4) + " " + f.workspaces.dotPositions.map(x => (x + x0).toFixed(2)).join(","));
                win.eyeI += 1;
                if (eyeGrab.v >= 0.9999 && closing) {
                    win.eyePhase = "opening";
                    win.eyeI = 0;
                } else if (eyeGrab.v <= 0.0001 && !closing) {
                    console.log("EYEFILM DONE");
                    quitTimer.start();
                    return;
                }
                eyeStepTimer.start();
            });
        }
    }
    Timer {
        id: eyeStepTimer
        interval: 0
        onTriggered: win.eyeNext()
    }
    Timer {
        running: win.eyeFilm !== ""
        interval: 3500
        onTriggered: {
            win.eyePhase = "closing";
            win.eyeI = 0;
            win.eyeNext();
        }
    }

    // ---- STAGE_GRAB=<png>: the stage alone, GRAB_MS after the start, then quit (renders at ZOOM=1) -------------
    readonly property string stageGrab: Quickshell.env("STAGE_GRAB") || ""
    Timer {
        running: win.stageGrab !== ""
        interval: Number(Quickshell.env("GRAB_MS") || 3500)
        onTriggered: scene.grabToImage(r => {
            r.saveToFile(win.stageGrab);
            // LAYOUT_DUMP=1: where the layout stood at the grab -- every bar's place and every module's slot (a render
            // sets the ink of each against it)
            if (Quickshell.env("LAYOUT_DUMP") === "1") {
                const st = shellServices.probeState();
                const n = Object.keys(st.screens)[0];
                const sc = st.screens[n];
                console.log("LAYOUT_DUMP " + JSON.stringify({ screen: n, bars: sc.bars, placed: sc.placed, lengths: sc.lengths }));
            }
            console.log("STAGE_GRAB saved " + win.stageGrab);
            quitTimer.start();
        })
    }
    Timer {
        id: quitTimer
        interval: 0
        onTriggered: Qt.quit()
    }

    // =====================================================================
    //  VALUES
    // =====================================================================
    readonly property var layoutParams: [
        {
            label: "top bar",
            prop: "topMode",
            group: "Top bar",
            blurb: "Islands (the plan's first arrangement) or one continuous bar. The same modules stand in either; none is rebuilt.",
            tip: "islands: three 40 px islands (left, centre, right) with the wallpaper showing between them. continuous: one bar across the whole edge, the three zones laid out along it. Kept in shell.jsonc as topMode.",
            val: 0,
            choices: ["islands", "continuous"]
        },
        {
            label: "centre island",
            prop: "centreMode",
            group: "Top bar",
            tip: "centred: the centre island is centred on the screen and the two voids differ with the islands' lengths. equal: the centre island is placed so both voids are the same. Kept as `centre`.",
            val: 0,
            choices: ["centred", "equal voids"]
        },
        {
            label: "left island px",
            prop: "lengthLeft",
            group: "Lengths of this output",
            blurb: "0 is what the modules need. Per output: the stage's connector name is the key (eDP-1 or DP-3). These and the rows above are shell.jsonc's keys: the panel writes the mock config's file as they move.",
            tip: "The left island's length in px for the stage's output; 0 takes the natural length (the room at the ends, the modules, the gaps and the title's slot).",
            val: 0,
            from: 0,
            to: 1600,
            step: 1
        },
        {
            label: "centre island px",
            prop: "lengthCentre",
            group: "Lengths of this output",
            tip: "The centre island's length for the stage's output; 0 takes the natural length.",
            val: 0,
            from: 0,
            to: 1600,
            step: 1
        },
        {
            label: "right island px",
            prop: "lengthRight",
            group: "Lengths of this output",
            tip: "The right island's length for the stage's output; 0 takes the natural length. Spare room becomes space between the modules.",
            val: 0,
            from: 0,
            to: 1600,
            step: 1
        },
        {
            label: "left zone",
            prop: "zoneLeft",
            group: "Zone order",
            blurb: "JSON arrays of module ids; a module left out comes back in its own zone at the end.",
            tip: "The left island's modules in order. Ids: power idle theme presets notes llm windowtray weather clock stocks player volume aerial bridge panorama silicon update notifications. The last of this zone that is `windowtray` takes the island's remainder.",
            val: "[\"power\",\"idle\",\"theme\",\"presets\",\"notes\",\"llm\",\"windowtray\"]",
            kind: "json",
            shape: "strings"
        },
        {
            label: "centre zone",
            prop: "zoneCentre",
            group: "Zone order",
            tip: "The centre island's modules in order; `clock` is the workspaces' groove with the clock in its split and takes the remainder.",
            val: "[\"weather\",\"clock\",\"stocks\"]",
            kind: "json",
            shape: "strings"
        },
        {
            label: "right zone",
            prop: "zoneRight",
            group: "Zone order",
            tip: "The right island's modules in order (left to right); the bell is last, at the screen's corner.",
            val: "[\"player\",\"volume\",\"aerial\",\"bridge\",\"panorama\",\"silicon\",\"update\",\"notifications\"]",
            kind: "json",
            shape: "strings"
        },
        {
            label: "notes along",
            prop: "notesAlong",
            group: "Outlets",
            blurb: "Where the popups of notes and the LLM come out of the left bar.",
            tip: "0 is the bar's top end, under the left island: the popup rests flush in the corner (THE WALL). 1 is its foot. Kept in shell.jsonc's outlets.",
            val: 0,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "LLM along",
            prop: "llmAlong",
            group: "Outlets",
            tip: "The same for the LLM's popup.",
            val: 0,
            from: 0,
            to: 1,
            step: 0.01
        }
    ]

    // THE LAYOUT'S CONSTANTS: ShellConfig.qml's property defaults, not keys of shell.jsonc. The panel sets them on the mock shell's
    // ShellConfig as they move, and Save writes them into ShellConfig.qml (the module's own file).
    readonly property var layoutConsts: [
        {
            label: "ink gap",
            prop: "inkGap",
            group: "Island",
            blurb: "How the modules stand inside an island. A constant of the shell (ShellConfig.qml), not a key of shell.jsonc: Save writes it there.",
            tip: "THE spacing rule: the clear space between the ink of two neighbouring modules and between an island's first and last glyph and its edge, one number for all of them (ShellLayout.INK says how much room each button leaves inside its own box). 22 is the shell's.",
            val: 22,
            from: 0,
            to: 48,
            step: 1
        },
        {
            label: "least void",
            prop: "minVoid",
            group: "Island",
            tip: "The least clear space between two islands and between an island and a corner. A set of lengths that would leave less is shortened -- the groove first, then the title's slot. 12: the user's.",
            val: 12,
            from: 0,
            to: 80,
            step: 1
        },
        {
            label: "title's slot",
            prop: "titleSlot",
            group: "Slots",
            blurb: "The two modules that take the room an island's length leaves.",
            tip: "The most the window title's slot takes: the left island follows the title up to this, and a longer title fades out inside it. A longer island (Lengths, above) gives the title the difference. 340: the user's.",
            val: 340,
            from: 120,
            to: 800,
            step: 1
        },
        {
            label: "workspaces scale",
            prop: "workspacesScale",
            group: "Workspaces",
            blurb: "The groove with the clock in its split, in the 40 px bar (E2's fitted slot: the clock's slot is 64 x 18 px at every scale).",
            tip: "The groove's drawing scale. 0.6, 0.75 and 0.9 are the three of the wave-1 sheet; 0.9 is the user's pick. The side tracks are pushed out so the clock keeps its 64 x 18 slot whatever the scale.",
            val: 0.9,
            from: 0.4,
            to: 1,
            step: 0.01
        },
        {
            label: "workspaces pitch",
            prop: "workspacesPitch",
            group: "Workspaces",
            tip: "Pixels between the two dots of one half of the groove. The fitted width is 2 * pitch + 64 + 100 * scale: 214 at the user's 30 and 0.9.",
            val: 30,
            from: 24,
            to: 200,
            step: 1
        },
        {
            label: "workspaces' width",
            prop: "workspacesWidth",
            group: "Workspaces",
            tip: "The groove's width in px; 0 is the fitted one (pitch and scale), and so is anything under 100. A width given here wins; the centre island's length is computed from it.",
            val: 0,
            from: 0,
            to: 1000,
            step: 1
        },
        {
            label: "joint rounding",
            prop: "jointRounding",
            group: "Joint",
            blurb: "The bars' concave joints nest a Hyprland window's corner: rounding + border_size, asked of Hyprland (a mock run cannot ask, and draws 14 + 3).",
            tip: "Hyprland's decoration:rounding as the joint takes it, compositor px. -1 asks Hyprland (the default); 0 .. 64 is used instead of what Hyprland says.",
            val: -1,
            from: -1,
            to: 64,
            step: 1,
            promote: { allowSentinel: true }
        },
        {
            label: "joint border",
            prop: "jointBorder",
            group: "Joint",
            tip: "Hyprland's general:border_size as the joint takes it, compositor px. -1 asks Hyprland (the default); 0 .. 64 is used instead.",
            val: -1,
            from: -1,
            to: 64,
            step: 1,
            promote: { allowSentinel: true }
        },
        {
            label: "halo reach",
            prop: "shadowReach",
            group: "Halo",
            blurb: "The shell's edge: the halo round everything the surface is, when shell.jsonc's \"shadow\" turns it on (\"halo\"). The mock shell draws it only in a cfg=user state.",
            tip: "Px past the surface's edge where the halo is gone, 0 .. 96. 28.",
            val: 28,
            from: 0,
            to: 96,
            step: 1
        },
        {
            label: "halo strength",
            prop: "shadowStrength",
            group: "Halo",
            tip: "Its alpha at the edge, 0 .. 1 (the colour's own alpha is not used). 0.3.",
            val: 0.3,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "halo spread",
            prop: "shadowSpread",
            group: "Halo",
            tip: "Px the shape it falls from is grown by (below 0: shrunk), -32 .. 32. -20: the user's, which tucks the band in under the surface.",
            val: -20,
            from: -32,
            to: 32,
            step: 1
        },
        {
            label: "halo softness",
            prop: "shadowSoftness",
            group: "Halo",
            tip: "How much of the reach the fall takes, 0.05 .. 1: 1 all of it (soft); less keeps it dark near the edge and falls over the outer part only. 0.6: the user's.",
            val: 0.6,
            from: 0.05,
            to: 1,
            step: 0.01
        },
        {
            label: "halo blend",
            prop: "shadowBlend",
            group: "Halo",
            tip: "Px over which concave corners and narrow gaps round off in the halo, 0 .. 64. 12: the user's.",
            val: 12,
            from: 0,
            to: 64,
            step: 1
        }
    ]
}
