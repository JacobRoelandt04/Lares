pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

import "modules/common/mockup"
import "modules/common/system"
import "modules/common/theme"
import "modules/bar/gooey"
import "modules/launcher"
import "modules/launcher/FlourishFrame.js" as FF

// =============================================================================
// mockups/launcher.qml -- the application launcher mockup, on the REAL bar engine.
//
// A slice of the screen at 1:1: a GooeyEngine with a 40 px top bar and the
// launcher's slim 6 px bottom bar across the whole edge (LauncherBar), and
// thePopup the launcher grows into -- the drop-in as it will run. Hover the
// bottom bar to open it the way the desktop will; the Run page opens it as
// the Alt+Space shortcut does.
//
// NOTHING IS LAUNCHED unless "Launch for real" is armed and confirmed: the
// service runs dry and the Run page shows the command it would have run. The
// apps are this machine's own (DesktopEntries); the scripts root is a SCRATCH
// COPY of mockups/fixtures/launcher_scripts in $XDG_RUNTIME_DIR ("Reset
// scripts" makes it again), and launcher.jsonc, the favourites and the
// frecency are the mockup's own under $XDG_STATE_HOME/lares/
// launcher-mockup -- your real ones are never read or written. Icons are the
// icon theme's (QS_ICON_THEME at start; Papirus when the mockup is started by the test runners).
//
// THE CONFIRM FLOURISH (round 3): Enter plays it for real (dry: nothing is
// launched); the Run page's Confirm (dry) does the same on the highlighted
// row, "Skip ahead" opens another popup (a popup opening while it plays drops the ball
// at once). Round 6, the audio player's transport: pause / resume and 0.25x..4x
// hold or slow EVERYTHING the flourish shows (the launcher's held close, the
// ripple and the droplets too); every frame's result is recorded (only while it
// changes) and played back forwards, backwards, one frame at a time or
// scrubbed, with a readout; Replay runs the last row again from its start.
// Every number is on the Confirm tab.
//
// Run it: quickshell -p mockups/launcher.qml (in the sandbox when a shell is
// running here: tools/dev/sandbox.sh quickshell -p mockups/launcher.qml).
// Env: LAUNCHER_NO_OPEN=1 (start closed), LAUNCHER_OPEN_BY=hover|shortcut,
// LAUNCHER_CONFIRM=<ms> (Confirm (dry) that long after the load; with
// LAUNCHER_PIN=<0..1> POSED there on the flourish's course -- for a GRAB
// mid-flourish).
// =============================================================================
MockupWindow {
    id: win

    moduleId: "launcher"
    title: "Launcher"
    stageLabel: "A section of the screen at 1:1 -- a top bar, the slim bottom bar, thePopup"
    content: scene
    target: tun
    targets: ({
            engineParams: launcherBar
        })
    stageColor: "#1F2229"
    zoom: 1.0
    panelWidth: 460

    lists: ({
            iconParams: win.iconParams,
            layoutParams: win.layoutParams,
            motionParams: win.motionParams,
            answerParams: win.answerParams,
            confirmParams: win.confirmParams,
            engineParams: win.engineParams
        })

    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        {
            name: "Answers",
            page: answersPage
        },
        {
            name: "Answer look",
            lists: ["answerParams"]
        },
        {
            name: "Layout",
            lists: ["layoutParams"]
        },
        {
            name: "Icons",
            lists: ["iconParams"]
        },
        {
            name: "Motion",
            lists: ["motionParams"]
        },
        {
            name: "Confirm",
            subs: [
                {
                    name: "Card",
                    lists: ["confirmParams"],
                    groups: ["Card"]
                },
                {
                    name: "Lift",
                    lists: ["confirmParams"],
                    groups: ["Lift and neck"]
                },
                {
                    name: "Rise",
                    lists: ["confirmParams"],
                    groups: ["Rise and fall", "Ball and fall"]
                },
                {
                    name: "Impact",
                    lists: ["confirmParams"],
                    groups: ["Impact"]
                },
                {
                    name: "Skip",
                    lists: ["confirmParams"],
                    groups: ["Skip ahead", "Shift+Enter"]
                }
            ]
        },
        {
            name: "Bar",
            lists: ["engineParams"]
        }
    ]

    // ---- The mockup's own files ---------------------------------------------------------------------
    readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || ((Quickshell.env("HOME") || "") + "/.local/state")) + "/lares/launcher-mockup"
    readonly property string scratchScripts: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/lares-launcher-mockup/scripts"
    readonly property string fixtureScripts: RepoRoot.dir + "/mockups/fixtures/launcher_scripts"
    property bool scriptsReady: false
    property bool launchForReal: false
    property bool armedReal: false
    property bool dressAudiowide: true
    // Where a copy of an answer goes while the launcher is dry (the file's content is the last thing copied).
    readonly property string lastCopyPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/lares-launcher-mockup/last-copy"

    Process {
        id: copyFixtures
        property bool force: false
        command: ["sh", "-c", 'if [ "$3" = 1 ] || [ ! -d "$1" ]; then rm -rf -- "$1" && mkdir -p -- "$(dirname -- "$1")" && cp -a -- "$2" "$1"; fi', "sh", win.scratchScripts, win.fixtureScripts, copyFixtures.force ? "1" : "0"]
    }
    Connections {
        target: copyFixtures
        function onExited(code) {
            win.scriptsReady = true;
        }
    }
    Component.onCompleted: copyFixtures.running = true

    function resetScripts() {
        if (win._owner)
            win._owner.close();
        win.scriptsReady = false;
        copyFixtures.force = true;
        copyFixtures.running = true;
    }

    // ---- Tunables (the panel's target; the owner builds the popup with them) -------------------------
    LauncherTune {
        id: tun
        fontFamily: win.dressAudiowide ? "Audiowide" : "Inter"
    }

    // =====================================================================
    //  THE STAGE
    // =====================================================================
    Item {
        id: scene
        implicitWidth: 1180
        implicitHeight: 800

        Rectangle {
            anchors.fill: parent
            color: win.stageColor
        }

        GooeyEngine {
            id: gooeyEngine
            anchors.fill: parent
            renderScale: win.stage.zoom
            surfaceColor: Theme.surface
            barsList: [topBar, launcherBar]

            GooeyBar {
                id: topBar
                engine: gooeyEngine
                barId: "topBar"
                edge: "top"
                rawPos: 0
                rawLen: gooeyEngine.w
                Text {
                    x: topBar.width - width - 18
                    y: (topBar.height - height) / 2
                    text: "13:37"
                    color: Theme.textMuted
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
            }

            LauncherBar {
                id: launcherBar
                engine: gooeyEngine
                barId: "launcherBar"
                rawPos: 0
                rawLen: gooeyEngine.w
                owner: ownerLoader.item
            }
        }

        Loader {
            id: ownerLoader
            active: win.scriptsReady
            sourceComponent: LauncherBarOwner {
                engine: gooeyEngine
                bar: launcherBar
                barId: "launcherBar"
                // qmllint sees this type twice -- once through the mockup's `modules` link, once at its real path -- and calls the two
                // incompatible; the engine follows the link and sees one (mockups/modules: RepoRoot.qml).
                // qmllint disable incompatible-type
                tune: tun
                // qmllint enable incompatible-type
                configPath: win.stateDir + "/launcher.json"
                favoritesPath: win.stateDir + "/launcher_favorites.json"
                favoritesLegacyPath: ""
                statePath: win.stateDir + "/state.json"
                scriptsRootOverride: win.scratchScripts
                dryRun: !win.launchForReal
                // The answers come from the stand-in child (canned replies, one per kind; LAUNCHER_ANSWERS=real asks the real one) and a
                // copy goes to a file, not the clipboard, unless "Launch for real" is armed.
                answerCommand: Quickshell.env("LAUNCHER_ANSWERS") === "real" ? [] : ["python3", RepoRoot.dir + "/tools/dev/fixtures/launcher_answers_stub.py"]
                copyCommand: win.launchForReal ? ["wl-copy", "--"] : ["sh", "-c", 'mkdir -p -- "$(dirname -- "$1")" && printf "%s" "$2" > "$1"', "sh", win.lastCopyPath]
                // A mockup never registers the desktop's shortcut.
                shortcutEnabled: false
            }
            onLoaded: Qt.callLater(() => {
                if (win._owner && Quickshell.env("LAUNCHER_NO_OPEN") !== "1")
                    win._owner.open(Quickshell.env("LAUNCHER_OPEN_BY") || "shortcut");
            })
        }
    }

    // tools/dev/perf/launcher_scroll.sh TARGET=mockup: the list scrolled without a
    // pause, in the mockup as the user runs it (mockups/launcher_scroll_driver.qml).
    Loader {
        id: scrollPerf
        active: Quickshell.env("LAUNCHER_SCROLL_PERF") === "1"
        source: Qt.resolvedUrl("launcher_scroll_driver.qml")
        onLoaded: {
            // The driver is loaded by URL: the linter knows the loader's item as a bare QObject.
            // qmllint disable missing-property
            scrollPerf.item.engine = gooeyEngine;
            // qmllint enable missing-property
        }
    }

    // =====================================================================
    //  RUN PAGE
    // =====================================================================
    readonly property LauncherBarOwner _owner: ownerLoader.item as LauncherBarOwner
    readonly property var _svc: win._owner ? win._owner.service : null
    readonly property var _popup: gooeyEngine.thePopup && gooeyEngine.popupOwnerId === "launcher" ? gooeyEngine.thePopup.contentItem : null
    readonly property var _fl: win._owner ? win._owner.flourish : null

    // ---- The flourish's tools -------------------------------------------------------------------------
    // The flourish publishes every frame's result and asks this mockup to open
    // the launcher when a replay or a scrub back needs it.
    Binding {
        target: win._fl
        property: "record"
        value: true
        when: !!win._fl
    }
    // Replay compares runs: a dry launch must not move the row (frecency).
    Binding {
        target: win._svc
        property: "dryRecords"
        value: false
        when: !!win._svc
    }
    Connections {
        target: win._fl
        function onOpenLauncherRequested() {
            win._owner.open("shortcut");
        }
    }
    // The audio player's recorder on the flourish's frame (FlourishFrame.js): the
    // flourish is the live writer, frozen while a take is played back
    // (enterReplay), and a gap longer than a pause is stored short.
    PoseRecorder {
        id: rec
        target: win._fl ? win._fl.frame : null
        props: win._fl ? win._fl.frameKeys : []
        maxGapMs: 150
        onBeforeScrub: win._fl.enterReplay()
    }
    // A new run is a new take.
    Connections {
        target: win._fl
        function onPlayingChanged() {
            if (win._fl.playing && !win._fl.replaying)
                rec.arm();
        }
    }
    // ---- The walk-through, pinned under every tab (round 7) -----------------------------------------
    // The recorder's controls and readout, in the panel's footer: whatever tab is open (the
    // Confirm tab's sliders above all), the take can be stepped and scrubbed without leaving it.
    readonly property string walkText: {
        const n = rec.frameCount;
        if (n < 2)
            return "nothing recorded yet -- press Confirm (dry) on the Run tab";
        const ph = FF.PHASES[Math.max(0, Math.min(FF.PHASES.length - 1, Math.round(rec.valueAt("ph"))))];
        const at = k => rec.valueAt(k);
        return "frame " + (rec.frameIndex + 1) + " / " + n + "   " + rec.position.toFixed(0) + " / " + rec.spanMs.toFixed(0) + " ms" + (rec.scrubbing ? (win._fl && win._fl.takeReposed ? "   (re-posed with current values)" : "   (scrubbing)") : "   (recording)") + "\n" + "run " + at("el").toFixed(0) + " ms   " + ph + " " + at("pt").toFixed(0) + " ms   released " + (at("rel") >= 0.999 ? "yes" : "no") + "   gap " + at("gap").toFixed(1) + " px   travel " + at("trv").toFixed(3) + "\n" + "waist " + at("nqU").toFixed(1) + " px   kJoin " + at("nkJoin").toFixed(1) + (at("neckOn") >= 0.999 ? "" : " (no neck)") + "   launcher t " + at("hostT").toFixed(3) + (at("hostOn") >= 0.999 ? "" : " (gone)") + "   effects " + (at("fxOn") >= 0.999 ? at("fxT").toFixed(3) + " s" : "-") + "   group k " + at("groupK").toFixed(1);
    }
    footer: Component {
        Rectangle {
            id: walk
            implicitHeight: walkCol.implicitHeight + 16
            color: "#EAEDF5"
            radius: 16
            border.color: "#CED1D7"
            border.width: 1
            ColumnLayout {
                id: walkCol
                anchors.fill: parent
                anchors.margins: 8
                spacing: 5
                TipRow {
                    tip: "Walk through what it did. The recorder keeps every frame's result, one sample a frame and only while something moves (a held run records nothing). Playing it back writes those frames into the engine -- the card, the neck, the launcher's held close, the ripple and the droplets -- so what you scrub through is what you saw. The live run is frozen while you are in there; hand back lets a held run go on from its last frame, and leaves a finished one idle."
                    Label {
                        text: "Walk through what it did"
                        color: "#5D5D5F"
                        font.family: "Audiowide"
                        font.pixelSize: 14
                        font.bold: true
                    }
                    Item {
                        Layout.fillWidth: true
                    }
                }
                TipRow {
                    tip: "start jumps to the first recorded frame; rewind plays the take backwards; play runs it forwards from where the head is; end jumps to the last frame. Frames that have the launcher's held close bring the launcher back first (a moment, once)."
                    spacing: 4
                    Repeater {
                        model: [
                            {
                                t: "|<",
                                a: 0
                            },
                            {
                                t: "<<",
                                a: 1
                            },
                            {
                                t: "play",
                                a: 2
                            },
                            {
                                t: ">|",
                                a: 3
                            }
                        ]
                        Button {
                            required property var modelData
                            text: modelData.a === 2 ? (rec.playing ? "||" : ">") : modelData.t
                            enabled: rec.frameCount > 1
                            padding: 4
                            font.pixelSize: 13
                            Layout.preferredWidth: 38
                            onClicked: {
                                if (modelData.a === 0)
                                    rec.seek(0);
                                else if (modelData.a === 1)
                                    rec.play(-1);
                                else if (modelData.a === 2)
                                    rec.playing ? rec.pause() : rec.play(1);
                                else
                                    rec.seek(rec.spanMs);
                            }
                        }
                    }
                    Item {
                        Layout.fillWidth: true
                    }
                }
                TipRow {
                    tip: "One recorded frame at a time -- about 16 ms of the run at 1x. Hand back ends the playback: a run that was held goes on from its last frame, a finished take leaves nothing behind (no body, group, neck, ripple or held close)."
                    spacing: 4
                    Button {
                        text: "-1 frame"
                        enabled: rec.frameCount > 1
                        padding: 4
                        font.pixelSize: 13
                        onClicked: rec.step(-1)
                    }
                    Button {
                        text: "+1 frame"
                        enabled: rec.frameCount > 1
                        padding: 4
                        font.pixelSize: 13
                        onClicked: rec.step(1)
                    }
                    Button {
                        text: "hand back"
                        enabled: rec.scrubbing
                        padding: 4
                        font.pixelSize: 13
                        onClicked: win.handBack()
                    }
                    Item {
                        Layout.fillWidth: true
                    }
                }
                TipRow {
                    tip: "The whole take as one line. Dragging it writes the frame for that moment, interpolated between the two recorded either side. The take's time is wall time at the speed it was run, a pause squeezed to a blink."
                    spacing: 8
                    Label {
                        text: "scrub"
                        color: "#8A8A8C"
                        font.family: "Audiowide"
                        font.pixelSize: 12
                    }
                    Slider {
                        Layout.fillWidth: true
                        implicitHeight: 22
                        from: 0
                        to: Math.max(1, rec.spanMs)
                        value: rec.position
                        onMoved: rec.seek(value)
                    }
                }
                TipRow {
                    tip: "How fast playback runs, independently of the run's own speed: the take is already made, so this only changes how quickly you are walked through it."
                    spacing: 8
                    Label {
                        text: "playback  " + rec.speed.toFixed(2) + "x"
                        color: "#8A8A8C"
                        font.family: "Audiowide"
                        font.pixelSize: 12
                    }
                    Slider {
                        Layout.fillWidth: true
                        implicitHeight: 22
                        from: 0.05
                        to: 2
                        value: rec.speed
                        onMoved: rec.speed = value
                    }
                }
                Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 11
                    text: win.walkText
                }
            }
        }
    }

    // LAUNCHER_FOOTER_PROBE=1: visit every tab
    // and print what the pinned walk-through looks like there -- the footer must stand in the
    // same place at the panel's foot on all of them, every control under a hover tip.
    function _descend(item, fn) {
        if (!item)
            return;
        fn(item);
        for (let i = 0; i < item.children.length; i++)
            win._descend(item.children[i], fn);
    }
    Timer {
        id: footerProbe
        interval: 350
        repeat: true
        running: Quickshell.env("LAUNCHER_FOOTER_PROBE") === "1"
        property int i: 0
        onTriggered: {
            if (footerProbe.i >= win.allTabs.length) {
                footerProbe.stop();
                console.log("FOOTER PROBE END");
                Qt.quit();
                return;
            }
            win.panel.tabIndex = footerProbe.i;
            let loader = null;
            win._descend(win.panel, it => {
                if (!loader && it.sourceComponent !== undefined && it.item)
                    loader = it;
            });
            const name = win.allTabs[footerProbe.i].name;
            if (!loader || !loader.item || !loader.item.visible) {
                console.log("FOOTER PROBE tab=" + name + " footer=none");
            } else {
                let controls = 0, tipped = 0, labelled = false;
                win._descend(loader.item, it => {
                    if (it.pressed !== undefined && it.clicked !== undefined || it.moved !== undefined) {
                        controls++;
                        let a = it;
                        while (a && a.tip === undefined)
                            a = a.parent;
                        if (a && a.tip !== "")
                            tipped++;
                    }
                    if (it.text === "Walk through what it did")
                        labelled = true;
                });
                const f = loader;
                console.log("FOOTER PROBE tab=" + name + " footer=yes y=" + Math.round(f.y) + " h=" + Math.round(f.height) + " bottomGap=" + Math.round(win.panel.height - f.y - f.height) + " controls=" + controls + " tipped=" + tipped + " title=" + labelled);
            }
            footerProbe.i++;
        }
    }
    function handBack() {
        rec.pause();
        win._fl.handBack();
        rec.release();
    }
    function replayRow() {
        rec.pause();
        if (win._fl.replay())
            rec.arm();
    }
    // LAUNCHER_PIN, a grab hook: the dry run posed at that fraction of its
    // course (the nominal timeline and the splash after it).
    property real _pin: -1
    readonly property real _scrubMs: win._fl ? win._fl.nominalMs + 800 : 3000
    function _findNamed(item, name) {
        if (!item)
            return null;
        for (let i = 0; i < item.children.length; i++) {
            const c = item.children[i];
            if (c.objectName === name)
                return c;
            const f = win._findNamed(c, name);
            if (f)
                return f;
        }
        return null;
    }
    // Enter on the highlighted row (opening the launcher first).
    function confirmDry() {
        const o = win._owner, f = win._fl;
        if (!o || !f || f.playing || f.replayBusy)
            return;
        if (!o.popupMine || !win._popup) {
            o.open("shortcut");
            confirmLater.restart();
            return;
        }
        const g = win._findNamed(win._popup, "launcherGrid");
        if (!g || g.currentKey === "")
            return;
        // A take being played back ends: the launch is a new one.
        if (f.replaying)
            win.handBack();
        f.posed = win._pin >= 0;
        win._popup.launch(g.currentKey, false);
        if (win._pin >= 0 && f.playing)
            f.poseAt(win._pin * win._scrubMs);
    }
    Timer {
        id: confirmLater
        interval: 700
        onTriggered: win.confirmDry()
    }
    Timer {
        interval: Number(Quickshell.env("LAUNCHER_CONFIRM") || 0)
        running: interval > 0 && !!win._owner
        onTriggered: {
            const pin = Quickshell.env("LAUNCHER_PIN");
            if (pin !== null && pin !== undefined && pin !== "")
                win._pin = Number(pin);
            win.confirmDry();
        }
    }
    // Another module's popup on the top bar: a popup opening while the
    // flourish plays makes it drop at once.
    Component {
        id: otherPopup
        Item {
            implicitWidth: 240
            implicitHeight: 110
            Text {
                anchors.centerIn: parent
                text: "Another popup"
                color: Theme.textMuted
                font.family: "Audiowide"
                font.pixelSize: 13
            }
        }
    }
    function skipAhead() {
        if (gooeyEngine.popupOpen && gooeyEngine.popupOwnerId === "mockup-other")
            gooeyEngine.close();
        else
            gooeyEngine.open("mockup-other", "topBar", gooeyEngine.w - 260, null, null, false, otherPopup, 1);
    }

    // ---- The quick answers ----------------------------------------------------------------------------
    // Sample queries, one per kind of the stand-in child (tools/dev/fixtures/launcher_answers_stub.py).
    readonly property var answerSamples: [
        { label: "math", q: "2+2" },
        { label: "math (long)", q: "12345678901234567890 * 98765432109876543210 * 3" },
        { label: "currency (pending, then landed)", q: "100 usd in eur" },
        { label: "base", q: "0xff" },
        { label: "time", q: "9:30 + 1h45" },
        { label: "unit", q: "5 mi in km" },
        { label: "date", q: "days until 2027-01-01" },
        { label: "zone", q: "time in tokyo" },
        { label: "colour", q: "#4480f4" },
        { label: "percent", q: "15% of 80" },
        { label: "ratio", q: "16:9 to 1080" },
        { label: "resolution", q: "4k" }
    ]
    // The query typed from the panel; LAUNCHER_QUERY=<q> types it a moment after the launcher opens (for a grab).
    function typeQuery(q) {
        const o = win._owner;
        if (!o)
            return;
        if (!o.popupMine)
            o.open("shortcut");
        if (o.service)
            o.service.setQuery(q);
    }
    Timer {
        interval: Quickshell.env("LAUNCHER_QUERY") ? 900 : 0
        running: interval > 0 && !!win._owner
        onTriggered: win.typeQuery(Quickshell.env("LAUNCHER_QUERY"))
    }
    FileView {
        id: lastCopy
        path: win.lastCopyPath
        watchChanges: true
        printErrors: false
        onFileChanged: lastCopy.reload()
        onLoaded: win.lastCopyText = lastCopy.text()
    }
    property string lastCopyText: ""

    pages: [
        MockupPage {
            id: answersPage

            TipGroup {
                title: "Quick answers"
                blurb: "The launcher's first row while the query is something it can answer. These queries go to a stand-in child with one canned reply per kind (the real child is tools/launcher/answers.py: start the mockup with LAUNCHER_ANSWERS=real). Enter copies the main form and closes, Shift+Enter copies and stays, a click on an alt copies that alt; Up on an empty query recalls the queries you copied an answer for."
            }
            Repeater {
                model: win.answerSamples
                delegate: TipRow {
                    id: sample
                    required property var modelData
                    tip: "Types \"" + sample.modelData.q + "\" into the launcher (opening it first): the stand-in child answers it as a " + sample.modelData.label + " answer."
                    Layout.fillWidth: true
                    spacing: 8
                    Button {
                        text: sample.modelData.label
                        onClicked: win.typeQuery(sample.modelData.q)
                    }
                    Label {
                        Layout.fillWidth: true
                        text: sample.modelData.q
                        elide: Text.ElideRight
                        color: "#8A8A8C"
                        font.family: "Audiowide"
                        font.pixelSize: 12
                    }
                }
            }
            TipRow {
                tip: "What the last copy wrote (dry: a file in the runtime dir, not the clipboard; armed 'Launch for real' on the Run tab uses wl-copy)."
                Layout.fillWidth: true
                spacing: 8
                Label {
                    text: "last copy"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 12
                }
                Label {
                    Layout.fillWidth: true
                    text: win.lastCopyText || "-"
                    elide: Text.ElideRight
                    color: "#5D5D5F"
                    font.family: "Audiowide"
                    font.pixelSize: 12
                }
            }
        },
        MockupPage {
            id: runPage

            TipGroup {
                title: "The popup"
                blurb: "Open and close it the ways the desktop will."
            }
            TipRow {
                tip: "Open or close the launcher as the Alt+Space shortcut does: the keyboard is the launcher's at once and it stays open until Escape, a launch or a click outside. Hovering the slim bottom bar opens it as the pointer will (it closes again on leave until you type)."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: win._owner && win._owner.popupMine ? "Close" : "Open (shortcut)"
                    onClicked: {
                        if (win._owner)
                            win._owner.toggle();
                    }
                }
                Button {
                    text: "Open (hover)"
                    enabled: !!win._owner && !win._owner.popupMine
                    onClicked: win._owner.open("hover")
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "The scripts root is a scratch copy of mockups/fixtures/launcher_scripts (two loose scripts, a Utilities folder with a link to kitty, a Dev folder with a link to VS Code). Folders made, renamed or emptied here change only the copy; this makes it again."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: "Reset scripts"
                    onClicked: win.resetScripts()
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "By default nothing is launched: Enter records the launch (frecency moves) and shows the command below. This makes Enter start the app or script for real. Arm, then confirm."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: win.launchForReal ? "Launching for real" : (win.armedReal ? "Confirm: launch for real" : "Launch for real...")
                    enabled: !win.launchForReal
                    onClicked: {
                        if (win.armedReal)
                            win.launchForReal = true;
                        else
                            win.armedReal = true;
                    }
                }
                Button {
                    visible: win.armedReal || win.launchForReal
                    text: win.launchForReal ? "Back to dry" : "Cancel"
                    onClicked: {
                        win.launchForReal = false;
                        win.armedReal = false;
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Dress the launcher in Audiowide, as the other mockups are. The module's face is Inter."
                Layout.fillWidth: true
                spacing: 8
                Switch {
                    text: "Audiowide"
                    checked: win.dressAudiowide
                    onToggled: win.dressAudiowide = checked
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "The confirm flourish"
                blurb: "A launch's row is thrown from the closing launcher: it flies up, has no speed at its apex, and falls back into the slim bar as a ball (round 3; the throw, 2026-10-31). Enter plays it; nothing is launched here unless 'Launch for real' is armed."
            }
            TipRow {
                tip: "Confirm (dry): Enter on the highlighted row, as the keyboard does (the launcher opens first if it is closed). Skip ahead: another module's popup opens on the top bar -- a popup opening while the flourish plays makes it the ball where it is and drops it at once; press again to close that popup."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: "Confirm (dry)"
                    enabled: !!win._fl && !win._fl.playing
                    onClicked: win.confirmDry()
                }
                Button {
                    text: gooeyEngine.popupOpen && gooeyEngine.popupOwnerId === "mockup-other" ? "Close the popup" : "Skip ahead"
                    onClicked: win.skipAhead()
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Replay: the last row again from its start -- whatever is on (a run, a take being played back, a scrub) is taken down, the launcher is opened if it is closed, the row captured last is revealed in it and launched, with the pause and the speed as they are set now. Change a parameter on the Confirm tab, press this, and compare run after run. The list re-sorts on every launch (frecency), so the row may start somewhere else in it."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: "Replay"
                    enabled: !!win._fl && win._fl.lastKey !== ""
                    onClicked: win.replayRow()
                }
                Label {
                    Layout.fillWidth: true
                    text: win._fl ? win._fl.replayNote : ""
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 12
                }
            }

            TipGroup {
                title: "While it runs"
                blurb: "Pause and slow motion hold or stretch EVERYTHING the flourish shows: its own clock, the launcher's held close and its fade, the ripple, the droplets, the rest's timers. A run reads its tune values when it starts, so a slider moved while it is paused changes the next run, not this one."
            }
            TipRow {
                tip: "Holds the run exactly where it is, every value to the digit, and no clock runs while it holds (no frame is drawn). Resume carries on from the same frame. Set before Confirm, the next run starts held on its first frame."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: win._fl && win._fl.paused ? "resume" : "pause"
                    enabled: !!win._fl && !win._fl.replaying
                    onClicked: win._fl.paused = !win._fl.paused
                }
                Label {
                    Layout.fillWidth: true
                    text: !win._fl ? "" : win._fl.replaying ? "a take is being played back" : win._fl.playing ? (win._fl.paused ? "held at: " + win._fl.phase : "running: " + win._fl.phase) : (win._fl.paused ? "the next run starts held" : "idle")
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 12
                }
            }
            TipRow {
                tip: "Multiplies every duration of the run at once -- the phases, the launcher's close, the neck's retraction, the ripple, the droplets, the rest's least and most -- so the SHAPE of the choreography cannot change when its speed does. It is the real animation slowed, not a second one. Takes effect at once, mid-run."
                Layout.fillWidth: true
                spacing: 8
                Label {
                    text: "speed"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 12
                }
                Repeater {
                    model: [0.25, 0.5, 1, 2, 4]
                    Button {
                        required property real modelData
                        text: String(modelData)
                        Layout.preferredWidth: 46
                        enabled: !!win._fl && !win._fl.replaying
                        highlighted: !!win._fl && win._fl.timeScale === modelData
                        onClicked: win._fl.timeScale = modelData
                    }
                }
                Label {
                    Layout.fillWidth: true
                    text: win._fl ? win._fl.timeScale.toFixed(2) + "x" : ""
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 12
                }
            }

            TipGroup {
                title: "State"
                blurb: "What the launcher, its service and its icons believe right now."
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
                text: {
                    const o = win._owner, s = win._svc, p = win._popup;
                    if (!o || !s)
                        return "scripts: " + (win.scriptsReady ? "ready" : "(copying)");
                    const lines = [];
                    lines.push("apps: " + s.appCount + (s.ready ? "" : "   (scanning)") + "   scripts: " + s.scriptsRoot.replace(Quickshell.env("HOME") || "~", "~"));
                    lines.push("sort: " + s.sortMode + (s.sortAscending ? "" : " desc") + "   layout: " + s.layout + (s.folder ? "   folder: " + s.folder : "") + (s.query ? "   query: " + s.query : ""));
                    lines.push("open: " + (o.popupMine ? o.openedBy : "no") + (o.engaged ? "   engaged" : "") + (o.barHovered ? "   bar hovered" : "") + (o.popupHovered ? "   popup hovered" : "") + "   keyboard: " + gooeyEngine.popupKeyboard);
                    if (p && p.implicitWidth !== undefined)
                        lines.push("size: " + Math.round(p.implicitWidth) + " x " + Math.round(p.implicitHeight));
                    lines.push("last launch: " + (s.lastCommand || "-") + (s.dryRun ? "   (dry)" : ""));
                    const f = win._fl;
                    if (f)
                        lines.push("flourish: " + f.phase + (f.replaying ? " (a take played back)" : f.posed ? " (posed)" : "") + (f.paused ? "   paused" : "") + (f.timeScale !== 1 ? "   " + f.timeScale + "x" : "") + (f.windowSeen ? "   window seen" : "") + (f.restWallMs >= 0 ? "   rest " + Math.round(f.restWallMs) + " ms" : "") + (f.skipReason ? "   skipped: " + f.skipReason : "") + (f.rippleRefused ? "   ripple refused" : "") + (f.dropletsThrown > 0 ? "   droplets " + f.dropletsThrown : ""));
                    return lines.join("\n");
                }
            }
        }
    ]

    // =====================================================================
    //  VALUES
    // =====================================================================
    readonly property var iconParams: [
        {
            label: "icon size",
            prop: "iconSize",
            group: "Size",
            blurb: "The icon beside each name, as the icon theme draws it. A row is the icon and a row inset above and below it.",
            tip: "The icon's size in px. 40: the user's starting point. wofi used 70.",
            val: 40,
            from: 20,
            to: 72,
            step: 1
        },
        {
            label: "bevel px",
            prop: "bevelPx",
            group: "Flourish",
            blurb: "The ball the launched icon's plate closes into in the confirm flourish.",
            tip: "The lit rim of the flourish's ball, in px: the ball is the launched icon's plate closed into a circle, and its radius adds this rim. 3: the carve's rim it was tuned with.",
            val: 3,
            from: 0,
            to: 3,
            step: 0.25
        },
        {
            label: "star size",
            prop: "starSize",
            group: "Favourite",
            blurb: "Every icon carries its full colour (round 2); a favourite has a star at its row's right end, and any other row shows a faint one on hover: a click on it toggles the favourite, and the row flies to its new place.",
            tip: "The favourite star's size in px. 12: the body size, so the star sits on the name's line without outweighing it.",
            val: 12,
            from: 8,
            to: 20,
            step: 1
        }
    ]

    readonly property var layoutParams: [
        {
            label: "list width",
            prop: "listWidth",
            group: "Size",
            blurb: "The popup is always `height (rows)` rows tall (launcher.jsonc's `rows`, default 9); it never resizes while you type.",
            tip: "The single list's width. 420: a long app name at 12 px beside a 40 px icon, with the shell's padding either side.",
            val: 420,
            from: 260,
            to: 900,
            step: 1
        },
        {
            label: "height (rows)",
            prop: "rows",
            group: "Size",
            tip: "How many rows tall the popup is, whatever is listed (it never resizes while you type); it resizes at once when changed. 9: launcher.jsonc's `rows` default. The real shell reads launcher.jsonc; the panel's number overrides it here, so Reset (or Save to mockup) is how it travels. Less tall = the confirm flourish's rise starts closer to its end.",
            val: 5,
            from: 3,
            to: 30,
            step: 1
        },
        {
            label: "column width",
            prop: "columnWidth",
            group: "Size",
            tip: "Each column's width in the multi-column layout (launcher.jsonc `columns`, default 2): the popup is then columns x this + the gaps + the padding. 300: a name still fits beside the icon.",
            val: 300,
            from: 180,
            to: 600,
            step: 1
        },
        {
            label: "columns",
            prop: "columns",
            group: "Size",
            tip: "How many columns the Columns layout has (the sort menu's toggle); the popup is then columns x column width + the gaps + the padding wide, at once. 2: launcher.jsonc's `columns` default. The real shell reads launcher.jsonc; the panel's number overrides it here.",
            val: 2,
            from: 1,
            to: 8,
            step: 1
        },
        {
            label: "column gap",
            prop: "columnGap",
            group: "Size",
            tip: "Space between two columns. 12, the shell's one padding number.",
            val: 12,
            from: 0,
            to: 32,
            step: 1
        },
        {
            label: "row inset",
            prop: "rowInset",
            group: "Row",
            blurb: "One row: the highlight well is the row, the icon sits a row inset inside it.",
            tip: "Space above and below the icon, and before it. 6: the shell's list row inset.",
            val: 6,
            from: 2,
            to: 16,
            step: 1
        },
        {
            label: "icon gap",
            prop: "iconGap",
            group: "Row",
            tip: "Space from the icon to its name. 10: a little under the padding, so the name belongs to its icon.",
            val: 10,
            from: 4,
            to: 24,
            step: 1
        },
        {
            label: "name size",
            prop: "nameSize",
            group: "Row",
            tip: "The app name's size. 12, the shell's body size.",
            val: 12,
            from: 10,
            to: 18,
            step: 1
        },
        {
            label: "well radius",
            prop: "wellRadius",
            group: "Row",
            tip: "The highlight well's corner radius. 10: the compact views' container radius; the well is not in a corner, so it does not take the popup's 14.",
            val: 10,
            from: 0,
            to: 20,
            step: 1
        },
        {
            label: "padding",
            prop: "padding",
            group: "Popup",
            blurb: "The popup's frame around the list: its padding and the header row.",
            tip: "The popup's padding on every side and between the header and the rows: as much room above the header as below the last row. 12: the shell's one padding number.",
            val: 12,
            from: 6,
            to: 24,
            step: 1
        },
        {
            label: "header height",
            prop: "headerHeight",
            group: "Popup",
            tip: "The header row above the list (the title or the query, the sort control). 32: a 16 px bold title with room above and below it, the notes header's height.",
            val: 32,
            from: 20,
            to: 64,
            step: 1
        }
    ]

    readonly property var motionParams: [
        {
            label: "glide ms",
            prop: "glideMs",
            group: "Highlight",
            blurb: "The highlight is one carved well gliding between rows on one clock.",
            tip: "How long the well takes to reach the next row. 120: fast enough that holding an arrow key never leaves it behind, long enough to read as motion.",
            val: 120,
            from: 0,
            to: 400,
            step: 10
        },
        {
            label: "reflow ms",
            prop: "reflowMs",
            group: "Rows",
            blurb: "A sort change moves the rows on screen to their new cells; a query or a folder is a page of its own and is placed. A favourite toggled flies instead (the LLM sidebar's flight: lift, travel, land), and the rows make room on the flight's own clock.",
            tip: "How long the rows take to reach their new cells after a sort change. 220: the notes grid's reflow. A favourite's flight keeps its own clock (lift 160, travel 340, land 160 ms: the system update's and the LLM sidebar's).",
            val: 220,
            from: 0,
            to: 600,
            step: 10
        },
        {
            label: "morph ms",
            prop: "morphMs",
            group: "Folders",
            blurb: "A folder row grows into the popup and shrinks back into it: notes' group morph, one clock.",
            tip: "The whole morph, OutCubic. 320: notes' value, so a folder opens like a notes group.",
            val: 320,
            from: 120,
            to: 900,
            step: 10
        },
        {
            label: "swipe distance",
            prop: "swipeBackUnits",
            group: "Folders",
            tip: "Wheel units for a whole two-finger back out of a folder. 900: notes' value, about the view switcher's step threshold (gestures.md).",
            val: 900,
            from: 300,
            to: 3000,
            step: 10
        },
        {
            label: "swipe sign",
            prop: "swipeBackSign",
            group: "Folders",
            tip: "Which horizontal wheel direction is 'fingers to the right'. 1 is notes' derived value, not yet measured on this machine's touchpad; -1 flips it.",
            val: 1,
            from: -1,
            to: 1,
            step: 2
        },
        {
            label: "hover open ms",
            prop: "hoverOpenMs",
            group: "Hover",
            blurb: "Hovering the slim bar opens the launcher; a hover-opened launcher closes on leave until you type, move the highlight or drag.",
            tip: "How long the pointer rests on the bar before the launcher opens. 250: long enough that a pointer crossing the bottom edge on its way somewhere does not open it.",
            val: 250,
            from: 0,
            to: 1000,
            step: 10
        },
        {
            label: "hover close ms",
            prop: "hoverCloseMs",
            group: "Hover",
            tip: "How long the pointer may be off the bar and the popup before an un-engaged, hover-opened launcher closes. 400: a slip past the popup's edge does not close it.",
            val: 400,
            from: 100,
            to: 1500,
            step: 10
        },
        {
            label: "menu scroll close px",
            prop: "menuScrollClosePx",
            group: "Menus",
            blurb: "A row's context menu belongs to its row: scrolling the list under it closes it.",
            tip: "How far the list may scroll under an open row menu before the menu closes, in px. 40: under one wheel notch (120 px), so a real scroll closes it, while the drift of fingers resting on a touchpad does not.",
            val: 40,
            from: 0,
            to: 200,
            step: 1
        }
    ]

    readonly property var confirmParams: [
        {
            label: "grow the icon",
            prop: "confirmGrowIcon",
            group: "Card",
            blurb: "The resting card: the icon centred on top, the title centred under it.",
            tip: "The icon grows from the row's size to the size below during the rise, and the ball forms round the larger icon. On: the user's pick (the icon reads at the centre of the screen).",
            val: true
        },
        {
            label: "icon px",
            prop: "confirmIconPx",
            group: "Card",
            tip: "The icon's size at the rest when it grows. 56: 'about 56 px', the user; the ball round it is then 82 px across.",
            val: 56,
            from: 40,
            to: 96,
            step: 1
        },
        {
            label: "card padding",
            prop: "confirmPadPx",
            group: "Card",
            tip: "Padding round the icon and the title in the card. 12: the shell's one padding number.",
            val: 12,
            from: 4,
            to: 24,
            step: 1
        },
        {
            label: "title gap",
            prop: "confirmTitleGapPx",
            group: "Card",
            tip: "From the icon's foot to the title. 8: a little under the padding, so the title belongs to its icon.",
            val: 8,
            from: 2,
            to: 20,
            step: 1
        },
        {
            label: "card radius",
            prop: "confirmRadiusPx",
            group: "Card",
            tip: "The card's corner radius at the rest. 20: the engine's maxR, every popup's corner.",
            val: 20,
            from: 0,
            to: 40,
            step: 1
        },
        {
            label: "apex clear px",
            prop: "confirmRestClearPx",
            group: "Card",
            tip: "How far past the launcher's face the card's apex stays. This is what gives the launch its speed (sqrt(2 g (1 - detach) H)) and the landing its speed (sqrt(2 g D)), so a tall launcher and a short one are the same throw from a different height; the card goes further if the screen's centre plus 'apex offset' is further, and never past the bar across the screen. 500 (honey and classic; syrup 470, dew 430): 80 px under the top bar on the user's 9 rows at 1296 design px.",
            val: 500,
            from: 0,
            to: 800,
            step: 1
        },
        {
            label: "apex offset px",
            prop: "confirmRestOffsetPx",
            group: "Card",
            tip: "Where the card's apex is, moved from the screen's centre along its bar's normal: positive is further from the bar, negative back towards it. It never comes closer to the launcher's face than 'apex clear px', so a large negative value stops there. 0: the centre.",
            val: 70,
            from: -600,
            to: 600,
            step: 1
        },
        {
            label: "lift ms",
            prop: "confirmLiftMs",
            group: "Lift and neck",
            blurb: "1 LIFT: the row slides out of its cell through the fading launcher and compacts into the card (the face's morph rides this clock); 2 RISE: the card pulls out of the launcher's face on a neck of two capsules, which pinches at the detach share of the travel. The launcher's close is held until then.",
            tip: "How long the row takes to leave its cell and become the card at the launcher's face. 280 (honey; syrup 250, dew 230, classic 240): long enough that the title visibly drops below the icon before the two cross, and no more: the throw itself is what takes the time.",
            val: 280,
            from: 100,
            to: 900,
            step: 10
        },
        {
            label: "lift easing",
            prop: "confirmLiftEasing",
            group: "Lift and neck",
            tip: "The lift's curve. 4 InOutCubic: it leaves the row gently and settles at the face. Easings are the engine's indices: 0 Linear, 1 OutCubic, 2 OutQuint, 3 OutBack, 4 InOutCubic, 5 OutExpo, 6 InQuad, 7 InCubic, 8 InBack.",
            val: 4,
            from: 0,
            to: 8,
            step: 1
        },
        {
            label: "neck inset px",
            prop: "confirmNeckInsetPx",
            group: "Lift and neck",
            tip: "How deep the card's foot is still in the launcher when the rise begins and the neck starts to draw. 6: the card sits on the launcher's face with its corners' notches for the neck to fill.",
            val: 6,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "waist position",
            prop: "confirmNeckMidFrac",
            group: "Lift and neck",
            tip: "Where the neck's waist sits between the card's foot (0) and the launcher's face (1). 0.6 (honey and syrup; dew 0.5, classic 0.9): the meeting is nearer the launcher than the card, so the strand hangs from the card and the pool's side is a short swell; 0.5 would be the middle whatever the curves on either side, which is what the old blend could not do (its waist sat by the flat face).",
            val: 0.6,
            from: 0.1,
            to: 0.9,
            step: 0.01
        },
        {
            label: "detach at (share of travel)",
            prop: "confirmDetachFrac",
            group: "Lift and neck",
            tip: "The share of the rise's CLOCK and of its travel at which the neck pinches and the launcher's close is let go: the pull speeds the card up until then, the freed card slows at a constant rate to its apex (the two agree in speed at the snap only when their shares are the same, so it is both). 0.35 (honey, syrup; dew 0.3, classic 0.4): most of the long climb is free flight you can watch slow; the pull accelerates the card at v0^2 / (2 a H), harder than gravity below 0.5 (a quicker shot off the strand). Higher: a longer strand and a shorter coast.",
            val: 0.35,
            from: 0.1,
            to: 0.95,
            step: 0.01
        },
        {
            label: "waist radius, start px",
            prop: "confirmNeckQStartPx",
            group: "Lift and neck",
            tip: "Half the waist's width as the rise begins. 26: the neck is already thinner than a card. The waist is two capsules' ends that cross, rounded by 'waist blend'.",
            val: 26,
            from: 2,
            to: 80,
            step: 1
        },
        {
            label: "waist radius, pinch px",
            prop: "confirmNeckQPinchPx",
            group: "Lift and neck",
            tip: "Half the waist's width just before it snaps; it thins from the start value to this over the detach share of the travel. 2 (honey; syrup 2.5, dew 3, classic 4): a hair of a thread, so the snap is a thread parting and not a bridge eight pixels wide.",
            val: 2,
            from: 0.5,
            to: 30,
            step: 0.5
        },
        {
            label: "card capsule radius",
            prop: "confirmNeckRUFrac",
            group: "Lift and neck",
            tip: "The radius of the card side's capsule end as a share of the CARD's width; its circle lies inside the card (cut a blend radius deep, so it never touches its other edges) and sets how fast the neck widens toward the card. 0.4: a gentle taper.",
            val: 0.4,
            from: 0.05,
            to: 1,
            step: 0.01
        },
        {
            label: "launcher capsule radius",
            prop: "confirmNeckRLFrac",
            group: "Lift and neck",
            tip: "The same for the launcher's side, as a share of the LAUNCHER's width: the wide curves. 0.15 of a 420 px launcher: a sweep that is still gathering at the waist.",
            val: 0.15,
            from: 0.02,
            to: 0.6,
            step: 0.01
        },
        {
            label: "card blend k",
            prop: "confirmNeckKA",
            group: "Lift and neck",
            tip: "The blend radius that joins the card's foot to the neck: its fillet. 24: a small curve, so the card keeps its corners. Smaller than the launcher's.",
            val: 24,
            from: 1,
            to: 80,
            step: 1
        },
        {
            label: "launcher blend k",
            prop: "confirmNeckKB",
            group: "Lift and neck",
            tip: "The blend radius that joins the launcher's face to the neck: the wide curves. 80: a long sweep out of the face, allowed to be wide.",
            val: 80,
            from: 1,
            to: 200,
            step: 1
        },
        {
            label: "waist blend k",
            prop: "confirmNeckKMid",
            group: "Lift and neck",
            tip: "The blend radius between the two capsules at the waist: how round the waist's corners are (a sharp V at 0). 16: no corner sharper than a few px.",
            val: 16,
            from: 1,
            to: 60,
            step: 1
        },
        {
            label: "join blend k",
            prop: "confirmNeckKJoin",
            group: "Lift and neck",
            tip: "The small radius that rounds the two sides where they meet (they are never blended with each other otherwise: a large value bulges the card's corners towards the launcher). 6.",
            val: 6,
            from: 1,
            to: 40,
            step: 1
        },
        {
            label: "stub bulb px",
            prop: "confirmNeckBulbPx",
            group: "Lift and neck",
            tip: "The radius each half's tip grows to as it retracts after the pinch: a snapped strand recoils and balls up, so a stub is a rounded nub sinking back into its body, never a cone with a point. 14 (honey; syrup 13, dew 11, classic 12): round at the scale of the card's own corners (20); 4 leaves the spikes.",
            val: 14,
            from: 2,
            to: 30,
            step: 0.5
        },
        {
            label: "retract ms",
            prop: "confirmNeckRetractMs",
            group: "Lift and neck",
            tip: "How long each half takes to retract into its body after the pinch, like a snapped strand: exactly this long on the flourish's clock, carrying on into the fall if the coast is shorter. 280 (honey; syrup 220, dew 160, classic 200): the recoil is read while the card is in the air. The launcher's close waits for it (the switch below) and is cut short so that it is over before the ball lands.",
            val: 280,
            from: 40,
            to: 1500,
            step: 10
        },
        {
            label: "retract easing",
            prop: "confirmNeckRetractEasing",
            group: "Lift and neck",
            tip: "The retraction's curve. 0 Linear: the tips part the moment the strand snaps and the motion fills the whole set time (an out-curve lands most of it in the first third, so 600 ms looked like 200; an in-out holds the tips together, so the pinch looks late). Easings are the engine's indices: 0 Linear, 1 OutCubic, 2 OutQuint, 3 OutBack, 4 InOutCubic, 5 OutExpo, 6 InQuad, 7 InCubic, 8 InBack.",
            val: 0,
            from: 0,
            to: 8,
            step: 1
        },
        {
            label: "emergence radius k",
            prop: "confirmNeckEmergeK",
            group: "Lift and neck",
            tip: "The blend between the card and the launcher while the card comes out of it: the concave corners are S-curves like a popup growing out of its bar. k = K p / (p + G) for p px out; K is the value it grows to. 45 with G 2.3 reproduces a real popup's fillet along its bar's face (measured: 24 / 28 / 31 / 33 px at 5 / 10 / 20 / 40 px out; a smooth-min of k reaches 0.78 k).",
            val: 45,
            from: 1,
            to: 80,
            step: 0.5
        },
        {
            label: "emergence half px",
            prop: "confirmNeckEmergeGrowPx",
            group: "Lift and neck",
            tip: "G: the protrusion at which the emergence blend is half of its full radius. Small: the first pixels already have a wide curve, as a popup's. 2.3.",
            val: 2.3,
            from: 0.1,
            to: 30,
            step: 0.1
        },
        {
            label: "emergence fade px",
            prop: "confirmNeckEmergeFadePx",
            group: "Lift and neck",
            tip: "How far the card's foot must clear the launcher's face for the emergence blend to give way to the neck's own blends (the capsules' radii come in over the same distance). 12: the card has cleared the face by about its own corner radius; longer and the two bodies' web has a sharp wing at the foot (corners check).",
            val: 12,
            from: 0,
            to: 120,
            step: 1
        },
        {
            label: "launcher closes after (ms)",
            prop: "confirmHostCloseDelayMs",
            group: "Lift and neck",
            tip: "Milliseconds after the confirm (the click or Enter) before the launcher's close starts at the earliest. 0 (the presets): the close waits only for the recoil (the switch below). 1000 (classic): the old fixed moment. The close never starts before the pinch, and the card waits at the centre until the launcher has closed.",
            val: 0,
            from: 0,
            to: 4000,
            step: 10
        },
        {
            label: "close after the recoil",
            prop: "confirmHostAfterRecoil",
            group: "Lift and neck",
            tip: "The launcher's close is let go only once the strand has finished recoiling. On: the card's stub is drawn against the launcher's body, so a launcher that closes under it pulls it along (the stub stretched after the closing launcher) and takes it away with the body at a pop. Off: the close starts at the pinch or the delay above, whichever is later -- the test of the old coupling.",
            val: true
        },
        {
            label: "launcher close ms",
            prop: "confirmHostCloseMs",
            group: "Lift and neck",
            tip: "The launcher's own close, let go once the neck has pinched. 400: the engine's openMs, the close it always had.",
            val: 400,
            from: 100,
            to: 1200,
            step: 10
        },
        {
            label: "launcher close easing",
            prop: "confirmHostCloseEasing",
            group: "Lift and neck",
            tip: "Its curve. 3 OutBack: the engine's own. Easings are the engine's indices: 0 Linear, 1 OutCubic, 2 OutQuint, 3 OutBack, 4 InOutCubic, 5 OutExpo, 6 InQuad, 7 InCubic, 8 InBack.",
            val: 3,
            from: 0,
            to: 8,
            step: 1
        },
        {
            label: "launcher overshoot",
            prop: "confirmHostOvershoot",
            group: "Lift and neck",
            tip: "OutBack's overshoot for that close, in Qt's units. 1.2: the engine's openOvershoot.",
            val: 1.2,
            from: 0,
            to: 3,
            step: 0.1
        },
        {
            label: "gravity px/s2",
            prop: "confirmGravity",
            group: "Rise and fall",
            blurb: "2 RISE to the apex, the icon growing: pulled out, the snap, then flying free and slowing to no speed at all at the top. 3 FALL on the same gravity. No phase of the throw has a length of its own: all of them follow from this number and the geometry.",
            tip: "The throw's one number: how hard the card is pulled back. It sets the rise (sqrt(2 H / ((1 - detach) g))), the fall (sqrt(2 D / g)) and how long the card is slow: under 200 px/s for 400 / g s and within 8 px of the apex for 2 sqrt(16 / g) s. 3200 (honey and classic: 9.81 m/s^2 with the screen's 1296 design px standing for a 4 m window; syrup 3600 = 3.5 m, dew 4200 = 3 m): 125 ms under 200 px/s, 141 ms within 8 px, against 57 and 96 at 7000. Lower hangs longer and takes longer (2800: 151 ms within 8 px, about 1.9 s to the contact; 4000: 126 ms, about 1.6 s). The speeds come from the apex, not from this.",
            val: 3200,
            from: 400,
            to: 16000,
            step: 50
        },
        {
            label: "ball starts at (share of fall)",
            prop: "confirmBallStart",
            group: "Ball and fall",
            blurb: "While it falls the card closes round the icon into a ball, and lands on the launcher's anchor on its bar.",
            tip: "How far into the fall the card starts closing. Until then it is whole: that is the hang at the apex, the moment it can be read. 0.3: about a tenth of the way down, the speed barely up.",
            val: 0.3,
            from: 0,
            to: 0.8,
            step: 0.01
        },
        {
            label: "ball ms",
            prop: "confirmBallMs",
            group: "Ball and fall",
            tip: "How long the card takes to become the ball. 260: the plan's figure.",
            val: 260,
            from: 60,
            to: 800,
            step: 10
        },
        {
            label: "ball easing",
            prop: "confirmBallEasing",
            group: "Ball and fall",
            tip: "The ball's curve. 4 InOutCubic. Easings are the engine's indices: 0 Linear, 1 OutCubic, 2 OutQuint, 3 OutBack, 4 InOutCubic, 5 OutExpo, 6 InQuad, 7 InCubic, 8 InBack.",
            val: 4,
            from: 0,
            to: 8,
            step: 1
        },
        {
            label: "ball margin px",
            prop: "confirmBallMarginPx",
            group: "Ball and fall",
            tip: "Surface between the icon's plate corner (0.616 of the icon from its centre) plus its lit rim and the ball's outline. 3: the rim never touches the outline.",
            val: 3,
            from: 0,
            to: 12,
            step: 0.5
        },
        {
            label: "cull feather px",
            prop: "confirmCullFeatherPx",
            group: "Ball and fall",
            tip: "The outline's feather as it culls the title, widest halfway through the ball and gone at either end (the icon's edge stays crisp). 6: soft, not a smear.",
            val: 6,
            from: 0,
            to: 16,
            step: 0.5
        },
        {
            label: "sink ms",
            prop: "confirmSinkMs",
            group: "Impact",
            blurb: "6 IMPACT: the ball merges with the bar (the smooth group, eased in by the engine) and sinks into it, cut by the bar's face; the bar ripples and throws droplets that fall back with their own ripples.",
            tip: "How long the ball takes to sink a merge radius under the face. 110 (honey, syrup, classic; dew 100): the sink's OutCubic starts at three times its average speed, so this carries on at the speed the ball lands with (about 2600 px/s). Longer: the bar catches the ball, and the impact goes.",
            val: 110,
            from: 60,
            to: 800,
            step: 10
        },
        {
            label: "sink easing",
            prop: "confirmSinkEasing",
            group: "Impact",
            tip: "Its curve. 1 OutCubic. Easings are the engine's indices: 0 Linear, 1 OutCubic, 2 OutQuint, 3 OutBack, 4 InOutCubic, 5 OutExpo, 6 InQuad, 7 InCubic, 8 InBack.",
            val: 1,
            from: 0,
            to: 8,
            step: 1
        },
        {
            label: "sink shrink",
            prop: "confirmSinkShrink",
            group: "Impact",
            tip: "The ball's size at the end of the sink, as a share of itself. 0.6.",
            val: 0.6,
            from: 0.1,
            to: 1,
            step: 0.05
        },
        {
            label: "merge k",
            prop: "confirmMergeK",
            group: "Impact",
            tip: "The smooth group's blend radius between the ball, the bar and the droplets. 24: the engine probe's merge.",
            val: 24,
            from: 0,
            to: 60,
            step: 1
        },
        {
            label: "ripple A",
            prop: "confirmRippleA",
            group: "Impact",
            tip: "The impact's wave amplitude, px. 5: more than the 6 px bar's half (troughs are floored a pixel above its far side, crests rise freely), so the wave reads as thrown by the ball.",
            val: 5,
            from: 0,
            to: 14,
            step: 0.5
        },
        {
            label: "ripple bulge",
            prop: "confirmRippleB",
            group: "Impact",
            tip: "The bulge standing where the ball went in, px. 10: the surface heaves as the ball goes under.",
            val: 10,
            from: 0,
            to: 24,
            step: 0.5
        },
        {
            label: "bulge width",
            prop: "confirmRippleBulgeW",
            group: "Impact",
            tip: "The bulge's width (its Gaussian's sigma), px. 32: wider than the sunk ball's radius, so it stands round the ball and not under it.",
            val: 32,
            from: 4,
            to: 60,
            step: 1
        },
        {
            label: "ripple onset s",
            prop: "confirmRippleOnset",
            group: "Impact",
            tip: "How fast the impact's waves and bulge come in, s. 0.02: a frame or two: the face does not jump by the whole amplitude at impact (the engine's default 0 does), and it does not lag the ball either.",
            val: 0.02,
            from: 0,
            to: 0.3,
            step: 0.01
        },
        {
            label: "ripple speed",
            prop: "confirmRippleSpeed",
            group: "Impact",
            tip: "The packets' group speed, px/s. 560: faster than GooeyRipple's 420, a harder hit.",
            val: 560,
            from: 100,
            to: 1200,
            step: 10
        },
        {
            label: "ripple damping",
            prop: "confirmRippleDamping",
            group: "Impact",
            tip: "The packets' damping, 1/s. 2.5: they carry a little further than GooeyRipple's 3.",
            val: 2.5,
            from: 0,
            to: 12,
            step: 0.5
        },
        {
            label: "ripple wavelength",
            prop: "confirmRippleWavelength",
            group: "Impact",
            tip: "The carrier's wavelength, px. 30: longer than GooeyRipple's 24, to go with the taller wave.",
            val: 30,
            from: 6,
            to: 80,
            step: 1
        },
        {
            label: "ripple end s",
            prop: "confirmRippleTend",
            group: "Impact",
            tip: "When the ripple is over (the field draws the bar alone again), s. 1.2: GooeyRipple's default.",
            val: 1.2,
            from: 0.3,
            to: 4,
            step: 0.1
        },
        {
            label: "droplets",
            prop: "confirmDroplets",
            group: "Impact",
            tip: "How many beads the splash throws (either side of the ball; a third straight up). 2 (honey, syrup; dew and classic 3): each lands with a ripple of its own -- a ripple holds three sources, the impact's and two. Fewer when the engine has no body index to spare.",
            val: 2,
            from: 0,
            to: 3,
            step: 1
        },
        {
            label: "droplet px",
            prop: "confirmDropletPx",
            group: "Impact",
            tip: "A bead's radius. 6.5 (honey; syrup and classic 5.5, dew 4.5): small beside the ball, big enough to read over the 6 px bar it came from.",
            val: 6.5,
            from: 1,
            to: 10,
            step: 0.5
        },
        {
            label: "droplet sideways",
            prop: "confirmDropletVx",
            group: "Impact",
            tip: "A bead's sideways speed, px/s. 150 (honey; syrup and classic 170, dew 200): they land about three ball widths away.",
            val: 150,
            from: 0,
            to: 400,
            step: 5
        },
        {
            label: "droplet upward",
            prop: "confirmDropletVy",
            group: "Impact",
            tip: "A bead's upward speed, px/s, on the throw's own gravity: the height is vy^2 / (2 g). 760 (honey; classic 800, syrup 820, dew 900): 90 to 100 px, tall enough to read as a splash from a ball that fell a thousand.",
            val: 760,
            from: 50,
            to: 1400,
            step: 5
        },
        {
            label: "droplet delay ms",
            prop: "confirmDropletDelayMs",
            group: "Impact",
            tip: "From the contact to the throw. 30: the splash comes as the ball goes in.",
            val: 30,
            from: 0,
            to: 200,
            step: 5
        },
        {
            label: "skip ball ms",
            prop: "confirmSkipBallMs",
            group: "Skip ahead",
            blurb: "A popup opening while it plays: it becomes the ball where it is and drops at once (no wind-up); a reopen of the launcher waits for the ball to merge, so the ball never falls through it.",
            tip: "How long the card takes to become the ball on a skip. 100.",
            val: 100,
            from: 20,
            to: 400,
            step: 10
        },
        {
            label: "skip fall ms",
            prop: "confirmSkipFallMs",
            group: "Skip ahead",
            tip: "Its fall. 180: 'drops at once' (the flourish caps it at 200).",
            val: 180,
            from: 40,
            to: 200,
            step: 10
        },
        {
            label: "skip sink ms",
            prop: "confirmSkipSinkMs",
            group: "Skip ahead",
            tip: "The sink when a reopen waits for it. 140.",
            val: 140,
            from: 40,
            to: 400,
            step: 10
        },
        {
            label: "reopen hold ms",
            prop: "confirmReopenHoldMaxMs",
            group: "Skip ahead",
            tip: "The most a reopen waits for the merge. 700: the skip's ball, fall and sink with room to spare.",
            val: 700,
            from: 200,
            to: 2000,
            step: 10
        },
        {
            label: "pulse ms",
            prop: "confirmPulseMs",
            group: "Shift+Enter",
            blurb: "Shift+Enter launches and keeps the launcher: no flourish, a pulse of the row.",
            tip: "The pulse: 1 -> the scale below -> 1. 160: the house presence time.",
            val: 160,
            from: 60,
            to: 400,
            step: 10
        },
        {
            label: "pulse scale",
            prop: "confirmPulseScale",
            group: "Shift+Enter",
            tip: "How far the row swells. 1.03: the user's figure.",
            val: 1.03,
            from: 1,
            to: 1.1,
            step: 0.005
        }
    ]

    readonly property var answerParams: [
        {
            label: "value size",
            prop: "answerValueSize",
            group: "Type",
            blurb: "The quick answer's row: the answer in the figure face, what was understood and the small print under it.",
            tip: "The answer's size in px. 16: the shell's title size, so a figure outweighs the app names (12) beside it.",
            val: 16,
            from: 12,
            to: 24,
            step: 1
        },
        {
            label: "sub size",
            prop: "answerSubSize",
            group: "Type",
            tip: "The size of the line under the answer (what was understood, then the small print) and of the alts. 11: the shell's figure size.",
            val: 11,
            from: 9,
            to: 14,
            step: 1
        },
        {
            label: "line gap",
            prop: "answerLineGap",
            group: "Type",
            tip: "Between the answer's line and the one under it, in px. 2: the two lines read as one block centred in the row.",
            val: 2,
            from: 0,
            to: 8,
            step: 1
        },
        {
            label: "glyph size",
            prop: "answerGlyphSize",
            group: "Mark",
            blurb: "The kind's glyph (Symbols Nerd Font) takes the icon's slot; the colour kind shows a carved swatch there instead.",
            tip: "The kind glyph's size in px. 18: reads as an icon beside 40 px app icons without competing with them.",
            val: 18,
            from: 10,
            to: 32,
            step: 1
        },
        {
            label: "swatch size",
            prop: "answerSwatch",
            group: "Mark",
            tip: "The colour answer's carved swatch, in px. 28: a little under the icon slot (40), so it reads as a chip, not an app.",
            val: 28,
            from: 16,
            to: 40,
            step: 1
        },
        {
            label: "swatch radius",
            prop: "answerSwatchRadius",
            group: "Mark",
            tip: "The swatch's corner radius in px. 8: the shell's small radius.",
            val: 8,
            from: 0,
            to: 20,
            step: 1
        },
        {
            label: "alt share",
            prop: "answerAltShare",
            group: "Alts",
            blurb: "Up to three other forms of the answer, plain text at the row's right; a click copies that one.",
            tip: "The alts' share of the row's width. A fixed slot, so the answer never re-elides as the alts come and go. 0.42: room for 'rgb(68 128 244)' beside a 16 px answer in the 420 px list.",
            val: 0.42,
            from: 0.2,
            to: 0.6,
            step: 0.01
        },
        {
            label: "alt line gap",
            prop: "answerAltGap",
            group: "Alts",
            tip: "Space added to each alt line's height, in px. 1: three lines still fit the row's 40 px inside.",
            val: 1,
            from: 0,
            to: 4,
            step: 1
        },
        {
            label: "fade ms",
            prop: "answerFadeMs",
            group: "Motion",
            tip: "The row's presence fade when an answer comes or goes. 160: the house presence time. Text swaps (a pending answer landing) are instant.",
            val: 160,
            from: 60,
            to: 400,
            step: 10
        },
        {
            label: "copied ms",
            prop: "answerCopiedMs",
            group: "Motion",
            tip: "How long the line under the answer says 'Copied' after Shift+Enter. 1200: long enough to read, short enough to be gone before the next key.",
            val: 1200,
            from: 400,
            to: 3000,
            step: 100
        }
    ]

    readonly property var engineParams: [
        {
            label: "thickness",
            prop: "thickness",
            group: "The slim bar",
            blurb: "The bottom bar the launcher grows from. The engine places a popup against each bar's own thickness, so any value works.",
            tip: "The bar's thickness in px. 6: Hyprland's outer gap (gaps_out = 6), so the bar fills the margin tiled windows already leave.",
            val: 6,
            from: 2,
            to: 48,
            step: 1
        },
        {
            label: "reserve",
            prop: "reserve",
            group: "The slim bar",
            tip: "How much of the edge the bar takes from windows (its exclusive zone). 0: it lives inside the gap and windows do not move (the user's choice).",
            val: 0,
            from: 0,
            to: 48,
            step: 1
        }
    ]
}
