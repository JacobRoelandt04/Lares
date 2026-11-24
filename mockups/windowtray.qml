//@ pragma IconTheme Papirus
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

import "modules/common/mockup"
import "modules/common/theme"
import "modules/common/components"
import "modules/bar/gooey"
import "modules/windowtray"
import "modules/windowtray/data"
import "modules/launcher/data"

// =============================================================================
// mockups/windowtray.qml -- the window title + tray module on the REAL bar engine.
//
// A section of the screen over the real wallpaper with three bars -- a top bar,
// a left bar under it, a bottom bar -- each carrying the module: the focused
// window's mark and title, the strip of tray icons hung out of the bar from the
// mark's cell, and the name label / the item's menu as the engine's secondary.
// One style object (and the power reel's IconReelStyle for the strip's
// geometry) is shared by all three, so a value moves in every orientation at
// once; there is one thePopup, so opening another bar's tray moves it.
//
// THE DATA is a mock by default: scripted titles (Claude Code's spinner, cwd
// edits in kitty, an app switch, an empty workspace, a long title, emoji) and a
// mock tray with the session's two real items (their captured menus) plus a
// chat app that can ask for attention. LIVE puts the real Hyprland and the real
// tray behind the same module -- two clicks, the user's only; nothing selects it
// from the environment. Live, a menu pick REALLY triggers the app's entry.
//
// Env (renders and probes): OPEN=<top|left|bottom> opens that bar's strip at
// start, HOVER=<n> labels icon n, MENU=<n> opens icon n's menu
// (SUB=<row label> then opens that row's submenu, the tertiary), ATTN=1 raises
// the chat app's attention, SCRIPT=<name> plays a title script, TITLE=<t> +
// CLS=<class> set the window, EMPTY=1 empties the tray, AUDIOWIDE=1, TOPEND=1
// (the top module at its bar's end), PLACE=bar, MARK=flat, INK=colour,
// MORPH=wipe; STAGE_GRAB=<png> + GRAB_MS: the stage alone, then quit;
// FILM=<grow|corner|sub> + FILM_OUT=<dir> (+ FILM_FRAMES): the stage on every frame
// of one motion -- grow: icon 1's label grows into its menu (with HOVER=1); corner:
// the label of the icon HOVER names opens; sub: the submenu SUB names opens out of
// MENU's menu.
// =============================================================================
MockupWindow {
    id: win

    moduleId: "windowtray"
    title: "Window title + tray"
    stageLabel: "A section of the screen at 1:1 -- a top, a left and a bottom bar, each with the title; the tray hangs from the mark"
    content: scene
    target: wstyle
    targets: ({ reelParams: rstyle })
    stageColor: "#1F2229"
    zoom: 1.0
    panelWidth: 460
    fitContent: true

    lists: ({
            titleParams: win.titleParams,
            stripParams: win.stripParams,
            sideParams: win.sideParams,
            reelParams: win.reelParams
        })

    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        {
            name: "Title",
            lists: ["titleParams"]
        },
        {
            name: "Strip",
            lists: ["stripParams", "reelParams"]
        },
        {
            name: "Side",
            lists: ["sideParams"]
        }
    ]

    // ---- the shared style objects (the panel's targets) ---------------------------
    WindowTrayStyle {
        id: wstyle
    }
    // The strip's geometry is the power reel's: the same object type, so the
    // tray and the power/idle-inhibit reels stay one material.
    IconReelStyle {
        id: rstyle
    }
    // Dress the module in Audiowide (the user's mockup face); Inter ships.
    property bool dressAudiowide: false
    onDressAudiowideChanged: wstyle.titleFamily = win.dressAudiowide ? "Audiowide" : "Inter"

    // ---- the data: mock, or the real desktop --------------------------------------
    property bool live: false
    property bool armedLive: false
    readonly property var winSvc: win.live ? liveWindow : mockWindow
    readonly property var traySvc: win.live ? liveTray : mockTray
    readonly property var cfg: win.live ? liveConfig.config : win.mockConfig

    AppLookup {
        id: lookup
    }
    // How long a kitty title change waits before the bar shows it (windowtray.jsonc terminalTitleMs; the Run tab).
    property int terminalMs: 150
    readonly property var mockConfig: ({
            follow: "focus",
            stripSuffix: true,
            rewrites: [],
            classIcons: [],
            trayOrder: [],
            trayHide: [],
            trayRename: {},
            trayIconMode: "ink",
            terminalClasses: ["kitty"],
            terminalTitleMs: win.terminalMs
        })
    ActiveWindowMock {
        id: mockWindow
        config: win.mockConfig
        appLookup: lookup
    }
    TrayMock {
        id: mockTray
        config: win.mockConfig
        appLookup: lookup
    }
    WindowTrayConfig {
        id: liveConfig
        live: win.live
    }
    ActiveWindowService {
        id: liveWindow
        live: win.live
        follow: "focus"
        config: liveConfig.config
        appLookup: lookup
    }
    TrayService {
        id: liveTray
        live: win.live
        config: liveConfig.config
        appLookup: lookup
    }

    // ---- the wallpaper (mockups/power.qml's: the real one, following the theme) ----------
    MockupWallpaper {
        id: stageWall
    }
    readonly property string wallpaper: stageWall.source

    // Where the top bar's module sits: near its start, or at its END (the
    // secondary then opens on the other side: there is no room towards the end).
    property bool topAtEnd: false

    // =====================================================================
    //  THE STAGE
    // =====================================================================
    Item {
        id: scene
        clip: true
        implicitWidth: 1100
        implicitHeight: 700

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

        GooeyEngine {
            id: engine
            anchors.fill: parent
            renderScale: win.stage.zoom
            surfaceColor: Theme.surface
            barsList: [topBar, leftBar, bottomBar]

            GooeyBar {
                id: topBar
                engine: engine
                barId: "top"
                edge: "top"
                rawPos: 0
                rawLen: engine.w
                WindowTitleButton {
                    id: topButton
                    objectName: "titleTop"
                    x: win.topAtEnd ? topBar.width - 40 - width : 160
                    owner: topOwner
                    window: win.winSvc
                    tray: win.traySvc
                    appLookup: lookup
                    thickness: topBar.height
                    barRotation: topBar.rotation
                    renderScale: engine.renderScale
                    ground: engine.surfaceColor
                }
                Text {
                    x: topBar.width / 2 - width / 2
                    y: (topBar.height - height) / 2
                    text: "13:37"
                    color: Theme.textMuted
                    font.family: "Audiowide"
                    font.pixelSize: 15
                }
            }
            GooeyBar {
                id: leftBar
                engine: engine
                barId: "left"
                edge: "left"
                rawPos: topBar.thickness
                rawLen: engine.h - topBar.thickness - bottomBar.thickness
                // The bar's own x runs from its FAR end back: 140 px under the
                // top bar on the screen is local x = rawLen - 140 - width.
                WindowTitleButton {
                    id: leftButton
                    objectName: "titleLeft"
                    x: leftBar.width - 140 - width
                    owner: leftOwner
                    window: win.winSvc
                    tray: win.traySvc
                    appLookup: lookup
                    thickness: leftBar.height
                    barRotation: leftBar.rotation
                    renderScale: engine.renderScale
                    ground: engine.surfaceColor
                }
            }
            GooeyBar {
                id: bottomBar
                engine: engine
                barId: "bottom"
                edge: "bottom"
                rawPos: 0
                rawLen: engine.w
                // Rotated 180: local x runs from the screen's right. The module
                // grows away from its mark, which sits 300 px from the left.
                WindowTitleButton {
                    id: bottomButton
                    objectName: "titleBottom"
                    x: bottomBar.width - 300 - width
                    owner: bottomOwner
                    window: win.winSvc
                    tray: win.traySvc
                    appLookup: lookup
                    thickness: bottomBar.height
                    barRotation: bottomBar.rotation
                    renderScale: engine.renderScale
                    ground: engine.surfaceColor
                }
            }
        }

        WindowTrayOwner {
            id: topOwner
            engine: engine
            bar: topBar
            barId: "top"
            ownerId: "windowtray-top"
            window: win.winSvc
            tray: win.traySvc
            appLookup: lookup
            config: win.cfg
            style: wstyle
            reelStyle: rstyle
        }
        WindowTrayOwner {
            id: leftOwner
            engine: engine
            bar: leftBar
            barId: "left"
            ownerId: "windowtray-left"
            window: win.winSvc
            tray: win.traySvc
            appLookup: lookup
            config: win.cfg
            style: wstyle
            reelStyle: rstyle
        }
        WindowTrayOwner {
            id: bottomOwner
            engine: engine
            bar: bottomBar
            barId: "bottom"
            ownerId: "windowtray-bottom"
            window: win.winSvc
            tray: win.traySvc
            appLookup: lookup
            config: win.cfg
            style: wstyle
            reelStyle: rstyle
        }
    }
    readonly property var owners: ({ top: topOwner, left: leftOwner, bottom: bottomOwner })
    readonly property var activeOwner: topOwner.popupMine ? topOwner : leftOwner.popupMine ? leftOwner
        : bottomOwner.popupMine ? bottomOwner : null

    // ---- env-driven start (renders and probes) -----------------------------------------
    Timer {
        id: startTimer
        running: true
        interval: 300
        onTriggered: {
            const e = n => Quickshell.env(n) || "";
            if (e("AUDIOWIDE") === "1")
                win.dressAudiowide = true;
            if (e("TOPEND") === "1")
                win.topAtEnd = true;
            if (e("PLACE") === "bar")
                wstyle.labelPlace = 1;
            if (e("INK") === "colour")
                wstyle.trayIconMode = "colour";
            if (e("MORPH") === "wipe")
                wstyle.morphMode = 1;
            if (e("EMPTY") === "1")
                mockTray.clear();
            if (e("TITLE") === "" && e("CLS") === "" && e("SCRIPT") === "")
                mockWindow.setWindow({ cls: "kitty", title: "~/.config/quickshell", initialTitle: "kitty" });
            if (e("TITLE") !== "" || e("CLS") !== "")
                mockWindow.setWindow({ cls: e("CLS") || "kitty", title: e("TITLE"),
                    initialTitle: ({ kitty: "kitty", zen: "Zen Browser", "com.microsoft.VSCode": "Visual Studio Code" })[e("CLS") || "kitty"] || "" });
            const script = Quickshell.env("SCRIPT") || "";
            if (script !== "")
                mockWindow.play(script);
            if (Quickshell.env("ATTN") === "1")
                mockTray.setStatus("chat", "NeedsAttention");
            openTimer.start();
        }
    }
    // After the window's title has landed: an open strip holds the title's width.
    Timer {
        id: openTimer
        interval: 400
        onTriggered: {
            // Opened with no pointer anywhere, a strip closes after the grace:
            // a render holds it.
            const o = win.owners[Quickshell.env("OPEN") || ""];
            if (o) {
                o.pinnedOpen = true;
                o.open();
            }
        }
    }
    Timer {
        id: afterOpen
        running: !!win.activeOwner && !!win.activeOwner.strip
        interval: 600
        onTriggered: {
            const o = win.activeOwner;
            const hov = Quickshell.env("HOVER") || "";
            const men = Quickshell.env("MENU") || "";
            if (hov !== "" && o) {
                const r = win.traySvc.rows.get(Number(hov));
                if (r)
                    o.cellHover(r.rec.key, Number(hov), true);
            }
            if (men !== "" && o) {
                const r = win.traySvc.rows.get(Number(men));
                if (r)
                    o.openMenu(r.rec.key);
                if (Quickshell.env("SUB"))
                    subTimer.start();
            }
        }
    }
    // ---- the film: the stage grabbed on every frame of one motion ----------------
    // Offscreen a rendered frame advances the animations a fixed 16 ms (CLAUDE.md),
    // and each grab asks for the next frame: one cell per 16 ms of the motion.
    readonly property string film: Quickshell.env("FILM") || ""
    readonly property int filmFrames: Number(Quickshell.env("FILM_FRAMES") || 40)
    // Slow motion for the film (FILM_SLOW, default 1): a grab of the stage takes
    // about half a second, and the animations advance by the wall clock between
    // two, so at 1 a 400 ms growth falls between cells. The engine's child
    // clocks and the key swap's, scaled alike on every tree filmed.
    readonly property real filmSlow: win.film !== "" ? Math.max(1, Number(Quickshell.env("FILM_SLOW") || 1)) : 1
    Component.onCompleted: {
        const k = win.filmSlow;
        if (!(k > 1))
            return;
        engine.childMs *= k;
        engine.childSlideMs *= k;
        engine.contentFadeMs *= k;
        engine.migrateMs *= k;
    }
    property int _filmK: -1
    property int _filmLanded: 0
    onFrameSwapped: {
        if (win._filmK < 0 || win._filmK >= win.filmFrames)
            return;
        const k = win._filmK++;
        scene.grabToImage(r => {
            r.saveToFile(Quickshell.env("FILM_OUT") + "/f" + String(k).padStart(3, "0") + ".png");
            if (++win._filmLanded === win.filmFrames) {
                console.log("FILM done " + win.filmFrames);
                quitTimer.start();
            }
        });
    }
    // corner: from the frame the label is asked for; sub: the submenu's level.
    Connections {
        target: win.activeOwner
        ignoreUnknownSignals: true
        function onSideOpenChanged() {
            if (win.film === "corner" && win.activeOwner.sideOpen && win._filmK < 0)
                win._filmK = 0;
        }
        function onLevelOpenChanged() {
            if (win.film === "sub" && win.activeOwner.levelOpen[1] === true && win._filmK < 0)
                win._filmK = 0;
        }
    }
    // grow: the label at rest, then its menu asked for.
    Timer {
        running: win.film === "grow" && win._filmK < 0 && !!win.activeOwner && win.activeOwner.sideOpen
        // The label's (slowed) open has landed.
        interval: 900 * win.filmSlow
        onTriggered: {
            const r = win.traySvc.rows.get(Number(Quickshell.env("HOVER") || 1));
            win._filmK = 0;
            win.activeOwner.openMenu(r.rec.key);
        }
    }
    // A submenu row of the open menu, by its label, picked as a click would.
    Timer {
        id: subTimer
        // The menu's (slowed, in a film) open has landed.
        interval: 700 * win.filmSlow
        onTriggered: {
            const o = win.activeOwner;
            if (!o || !o.menuOpen)
                return;
            const m = o.menuModelOf(0, o.levelSlot[0]);
            for (let i = 0; i < m.rows.count; i++) {
                const d = m.rows.get(i).rec.d;
                if (d.label === Quickshell.env("SUB")) {
                    o.menuPick(0, o.levelSlot[0], i, d, o._keyRowY(0, i));
                    return;
                }
            }
        }
    }
    readonly property string stageGrab: Quickshell.env("STAGE_GRAB") || ""
    Timer {
        running: win.stageGrab !== ""
        interval: Number(Quickshell.env("GRAB_MS") || 2500)
        onTriggered: scene.grabToImage(r => {
            r.saveToFile(win.stageGrab);
            console.log("GRAB " + win.stageGrab);
            quitTimer.start();
        })
    }
    Timer {
        id: quitTimer
        interval: 0
        onTriggered: Qt.quit()
    }

    // =====================================================================
    //  PAGES
    // =====================================================================
    pages: [
        MockupPage {
            id: runPage

            TipGroup {
                title: "The data"
                blurb: "A mock by default. Live is the real Hyprland and the real tray."
            }
            TipRow {
                tip: "Live: the focused window from the real Hyprland (read-only) and the real tray items. A menu pick then REALLY triggers that app's entry (Quit quits it). Two clicks: Arm, then Confirm. Mock: scripted titles and the session's two captured items plus a chat app."
                Layout.fillWidth: true
                spacing: 8
                Label {
                    text: win.live ? "Live" : "Mock"
                    font.bold: true
                }
                Button {
                    text: win.live ? "Back to mock" : win.armedLive ? "Confirm: use the real desktop" : "Arm live"
                    onClicked: {
                        if (win.live) {
                            win.live = false;
                            win.armedLive = false;
                        } else if (win.armedLive) {
                            win.live = true;
                        } else {
                            win.armedLive = true;
                        }
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "The title"
                blurb: "What the window does; the bar shows it."
            }
            TipRow {
                tip: "Play a scripted sequence of titles on the mock window: Claude Code's spinner (~1.2 changes a second: each morph plays out, the next waits), cwd edits in kitty (only the changed letters move), commands in kitty (the title is the command while it runs: ls and git status are over before the terminal wait is, so the bar never shows them, cargo build is named), a tab switch, an app switch (the whole title and the mark), an empty workspace, a long title (it fades at the max width), emoji (never cut in two)."
                Layout.fillWidth: true
                spacing: 8
                ComboBox {
                    id: scriptBox
                    Layout.fillWidth: true
                    model: mockWindow.scripts
                }
                Button {
                    text: "Play"
                    enabled: !win.live
                    onClicked: mockWindow.play(scriptBox.currentText)
                }
                Button {
                    text: "Stop"
                    onClicked: mockWindow.stop()
                }
            }
            TipRow {
                tip: "How long a terminal's title change waits before the bar shows it (windowtray.jsonc terminalTitleMs, default 150; the mock lists kitty). A shell sets the title to the command and back to the directory when it ends, so `ls` would flash ~, ls, ~ across the bar; a title that comes back within the wait never shows, and one that stays is shown when the wait is over. 0: no wait."
                Layout.fillWidth: true
                spacing: 8
                Label {
                    text: "Terminal wait"
                }
                SpinBox {
                    from: 0
                    to: 1000
                    stepSize: 10
                    editable: true
                    value: win.terminalMs
                    onValueModified: win.terminalMs = value
                }
                Label {
                    text: "ms"
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Set the mock window yourself: its class (the mark and the app's name) and its raw title (the bar strips the app's name off its end)."
                Layout.fillWidth: true
                spacing: 8
                ComboBox {
                    id: clsBox
                    Layout.preferredWidth: 150
                    model: ["kitty", "zen", "com.microsoft.VSCode", "org.quickshell", "no.such.app"]
                }
                TextField {
                    id: titleField
                    Layout.fillWidth: true
                    text: "~/.config/quickshell"
                }
                Button {
                    text: "Set"
                    enabled: !win.live
                    onClicked: mockWindow.setWindow({ cls: clsBox.currentText, title: titleField.text,
                        initialTitle: ({ kitty: "kitty", zen: "Zen Browser", "com.microsoft.VSCode": "Visual Studio Code" })[clsBox.currentText] || "" })
                }
            }
            TipRow {
                tip: "Dress the title in Audiowide (the mockups' face) instead of Inter (what ships)."
                Layout.fillWidth: true
                Switch {
                    text: "Audiowide"
                    checked: win.dressAudiowide
                    onToggled: win.dressAudiowide = checked
                }
                Switch {
                    text: "Top module at the bar's end"
                    checked: win.topAtEnd
                    onToggled: win.topAtEnd = checked
                }
            }

            TipGroup {
                title: "The tray"
                blurb: "The mock tray: its items, their status, their menus."
            }
            TipRow {
                tip: "Open or close the strip on a bar, as a click on that bar's title does (an empty tray: the title is inert, nothing opens)."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: "Top"
                    onClicked: topOwner.toggle()
                }
                Button {
                    text: "Left"
                    onClicked: leftOwner.toggle()
                }
                Button {
                    text: "Bottom"
                    onClicked: bottomOwner.toggle()
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "The chat app asks for attention (NeedsAttention): its icon peeks into every bar beside the window's mark, in warn ink, until it stops asking. Passive: it says it is not important now (faint ink)."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: "Chat: attention"
                    enabled: !win.live
                    onClicked: mockTray.setStatus("chat", "NeedsAttention")
                }
                Button {
                    text: "Chat: calm"
                    enabled: !win.live
                    onClicked: mockTray.setStatus("chat", "Active")
                }
                Button {
                    text: "Chat: passive"
                    enabled: !win.live
                    onClicked: mockTray.setStatus("chat", "Passive")
                }
            }
            TipRow {
                tip: "Remove the chat app from the tray, or bring it back; empty the tray (the title goes inert) and refill it."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: "Remove chat"
                    enabled: !win.live
                    onClicked: mockTray.remove("chat")
                }
                Button {
                    text: "Add chat"
                    enabled: !win.live
                    onClicked: mockTray.add(mockTray.chatSpec)
                }
                Button {
                    text: "Empty"
                    enabled: !win.live
                    onClicked: mockTray.clear()
                }
                Button {
                    text: "Refill"
                    enabled: !win.live
                    onClicked: mockTray.reset()
                }
            }
            TipRow {
                tip: "What the mock tray was last asked to do (activate, secondary activate, scroll, a menu entry triggered) -- what the real app would have been told."
                Layout.fillWidth: true
                Label {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    text: "Last: " + (mockTray.log.length > 0 ? mockTray.log[mockTray.log.length - 1] : "nothing yet")
                }
            }
        }
    ]

    // =====================================================================
    //  VALUES
    // =====================================================================
    readonly property var titleParams: [
        {
            label: "font",
            prop: "titleFamily",
            group: "Type",
            blurb: "The title's face and size. The module ships Inter; the Audiowide switch on Run dresses it.",
            tip: "The title's font family. Inter is the shell's module default (CLAUDE.md).",
            val: "Inter",
            kind: "text"
        },
        {
            label: "size",
            prop: "titlePixelSize",
            group: "Type",
            tip: "The title's pixel size. 13 fits a 40 px bar with room above and below; waybar's Audiowide was 20.",
            val: 13,
            from: 9,
            to: 22,
            step: 1
        },
        {
            label: "bold",
            prop: "titleBold",
            group: "Type",
            tip: "Bold title. Audiowide has no bold: Qt synthesizes one, laid out a pixel wider (the morph measures with the real layout, so it does not drift).",
            val: true
        },
        {
            label: "max width",
            prop: "maxTitleWidth",
            group: "Truncation",
            blurb: "Where a long title is cut. The brief leaves the number to the deployment.",
            tip: "The title's room in the bar, in px; past it the end fades into the bar. Pixels, not characters: Inter's letters are not one width.",
            val: 360,
            from: 80,
            to: 800,
            step: 1
        },
        {
            label: "end fade",
            prop: "endFade",
            group: "Truncation",
            tip: "Over how many px a cut title fades into the bar. 0: an ellipsis instead -- and then a title that does not fit swaps at once rather than morphing (the ellipsis would jump).",
            val: 24,
            from: 0,
            to: 60,
            step: 1
        },
        {
            label: "end pad",
            prop: "titleEndPad",
            group: "Truncation",
            tip: "Space between the title's end and the module's end.",
            val: 10,
            from: 0,
            to: 30,
            step: 1
        },
        {
            label: "mode",
            prop: "morphMode",
            group: "Morph",
            blurb: "How a changed title moves: only the letters that changed, on one clock.",
            tip: "drift: the old letters lift a few px and fade, the new settle in from below, the rest slides to its place. wipe: a soft front sweeps the changed letters. swap: no motion.",
            val: 0,
            choices: ["drift", "wipe", "swap"]
        },
        {
            label: "duration ms",
            prop: "morphMs",
            group: "Morph",
            tip: "One morph, OutCubic. Short on purpose: the bar redraws whole while anything in it moves (Qt Quick has no damage regions).",
            val: 220,
            from: 80,
            to: 600,
            step: 10
        },
        {
            label: "drift px",
            prop: "driftPx",
            group: "Morph",
            tip: "How far the changed letters lift out and settle in (drift mode), and how far the mark moves when the app changes.",
            val: 3,
            from: 0,
            to: 10,
            step: 0.5
        },
        {
            label: "overlap",
            prop: "morphOverlap",
            group: "Morph",
            tip: "How much of the clock the leaving and the arriving letters share (drift). At 0.2 both are faint for ~44 ms of a 220 ms morph; at 0 the old letters are gone before the new ones come (no two words on one place, but an empty instant between).",
            val: 0.2,
            from: 0,
            to: 0.6,
            step: 0.05
        },
        {
            label: "mark size",
            prop: "markSize",
            group: "Mark",
            blurb: "The focused app's mark in the bar.",
            tip: "The mark's size in px, centred in a cell as wide as the strip.",
            val: 20,
            from: 12,
            to: 32,
            step: 1
        },
        {
            label: "hover tint",
            prop: "hoverTint",
            group: "Hover",
            blurb: "The title under the pointer.",
            tip: "How far the title's ink goes towards the accent under the pointer (and while the strip is open). Nothing else announces the button.",
            val: 0.55,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "hover ms",
            prop: "hoverMs",
            group: "Hover",
            tip: "The hover fade, for the title and the tray icons alike.",
            val: 120,
            from: 0,
            to: 400,
            step: 10
        },
        {
            label: "boot text",
            prop: "bootText",
            group: "Boot lock",
            blurb: "The title while the boot lock is still up.",
            tip: "What the title says while the session has been locked since it began (the boot lock); the island is born at its length. A later lock says \"<name> is away\".",
            val: "New session",
            kind: "text"
        }
    ]
    readonly property var stripParams: [
        {
            label: "icon size",
            prop: "trayIconSize",
            group: "Icons",
            blurb: "The tray's icons in the strip.",
            tip: "A tray icon's size in px. The pitch between them is the reel's (below).",
            val: 18,
            from: 12,
            to: 28,
            step: 1
        },
        {
            label: "peek size",
            prop: "peekSize",
            group: "Attention",
            blurb: "An item asking for attention peeks into the bar beside the window's mark.",
            tip: "The peeking icon's size in px.",
            val: 16,
            from: 10,
            to: 24,
            step: 1
        },
        {
            label: "peek gap",
            prop: "peekGap",
            group: "Attention",
            tip: "Space after a peeking icon.",
            val: 6,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "peek ms",
            prop: "peekMs",
            group: "Attention",
            tip: "How long a peek takes to come in or leave (its width and its ink, one fraction).",
            val: 260,
            from: 0,
            to: 800,
            step: 10
        },
        {
            label: "peek max",
            prop: "peekMax",
            group: "Attention",
            tip: "At most this many items peek at once; the rest wait in the strip.",
            val: 3,
            from: 1,
            to: 6,
            step: 1
        }
    ]
    readonly property var reelParams: [
        {
            label: "thickness",
            prop: "thickness",
            group: "The reel's strip (shared with power)",
            blurb: "The strip IS the power reel's: these move the power and idle-inhibit reels too.",
            tip: "The strip's width, and the cell in the bar it continues. Half of it is the round end's radius (the engine's maxR).",
            val: 40,
            from: 28,
            to: 56,
            step: 1
        },
        {
            label: "pitch",
            prop: "cellPitch",
            group: "The reel's strip (shared with power)",
            tip: "Distance between two icons along the strip.",
            val: 36,
            from: 24,
            to: 56,
            step: 1
        },
        {
            label: "close grace ms",
            prop: "closeGraceMs",
            group: "The reel's strip (shared with power)",
            tip: "How long after the pointer left the strip closes: the pointer crosses from cell to strip to label through a frame where none has it.",
            val: 160,
            from: 0,
            to: 800,
            step: 10
        },
        {
            label: "width from",
            prop: "popupWidthFrom",
            group: "The reel's strip (shared with power)",
            tip: "The fraction of its width the strip starts at as it comes out. 1: it slides out at full width, so the icons stand still while it grows.",
            val: 1,
            from: 0.3,
            to: 1,
            step: 0.05
        }
    ]
    readonly property var sideParams: [
        {
            label: "label delay ms",
            prop: "labelDelayMs",
            group: "Label",
            blurb: "The hovered icon's name, beside the strip (the engine's secondary).",
            tip: "How long the pointer rests on an icon before its name comes out. Once out it follows the pointer from icon to icon at once (the engine slides it).",
            val: 220,
            from: 0,
            to: 800,
            step: 10
        },
        {
            label: "label grace ms",
            prop: "labelGraceMs",
            group: "Label",
            tip: "How long the name stays after the pointer left every icon.",
            val: 180,
            from: 0,
            to: 800,
            step: 10
        },
        {
            label: "label place",
            prop: "labelPlace",
            group: "Label",
            tip: "beside: the name comes out beside the strip, joined to it. bar: the bar's own title morphs into the hovered item's name instead (no secondary until a menu).",
            val: 0,
            choices: ["beside", "bar"]
        },
        {
            label: "pad x",
            prop: "labelPadX",
            group: "Label",
            tip: "The label's padding left and right of its words.",
            val: 12,
            from: 4,
            to: 24,
            step: 1
        },
        {
            label: "pad y",
            prop: "labelPadY",
            group: "Label",
            tip: "The label's padding above and below its words. With one line the label is 27 px tall at the defaults.",
            val: 7,
            from: 2,
            to: 16,
            step: 1
        },
        {
            label: "name size",
            prop: "labelNameSize",
            group: "Label",
            tip: "The item's name, bold.",
            val: 12,
            from: 9,
            to: 18,
            step: 1
        },
        {
            label: "status size",
            prop: "labelStatusSize",
            group: "Label",
            tip: "The status line under the name: the item's tooltip (\"Bluetooth Disabled\"), markup stripped.",
            val: 11,
            from: 8,
            to: 16,
            step: 1
        },
        {
            label: "flush gap",
            prop: "flushGap",
            group: "Label",
            tip: "A label or menu that would come within this many px of the bar face lies against it instead: a few px of wallpaper between them read as a sliver (the side spike, 0.md).",
            val: 12,
            from: 0,
            to: 30,
            step: 1
        },
        {
            label: "menu width",
            prop: "menuWidth",
            group: "Menu",
            blurb: "The item's menu: the same secondary, grown out of the label.",
            tip: "The menu's width. Fixed, so where it opens can be decided before it exists.",
            val: 240,
            from: 160,
            to: 400,
            step: 1
        },
        {
            label: "row height",
            prop: "menuRowHeight",
            group: "Menu",
            tip: "A menu row's height (FloatingMenu's material: 26).",
            val: 26,
            from: 18,
            to: 40,
            step: 1
        },
        {
            label: "font size",
            prop: "menuFontSize",
            group: "Menu",
            tip: "A menu row's text size. 11, a step under the shell's other menus: tray apps write long rows (round 2).",
            val: 11,
            from: 9,
            to: 18,
            step: 1
        },
        {
            label: "head height",
            prop: "menuHeadHeight",
            group: "Menu",
            tip: "The menu's head row (the item's name), which the menu lines up with the icon.",
            val: 32,
            from: 20,
            to: 48,
            step: 1
        },
        {
            label: "max height",
            prop: "menuMaxHeight",
            group: "Menu",
            tip: "The tallest a menu gets (never more than the screen between the bars); past it its rows scroll, with the shell's edge fades.",
            val: 460,
            from: 160,
            to: 900,
            step: 10
        },
        {
            label: "pad",
            prop: "menuPad",
            group: "Menu",
            tip: "The menu's padding inside the secondary.",
            val: 6,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "side room",
            prop: "sideRoom",
            group: "Menu",
            tip: "The room a menu needs beside the strip; with less towards the bar's end it opens on the other side (decided when the strip opens).",
            val: 280,
            from: 120,
            to: 600,
            step: 10
        },
        {
            label: "load timeout ms",
            prop: "menuLoadTimeoutMs",
            group: "Menu",
            tip: "A menu whose rows have not arrived opens anyway after this (with 'Nothing to show'). The stub answers in ~30 ms; a real app may take longer.",
            val: 600,
            from: 100,
            to: 3000,
            step: 50
        }
    ]
}
