pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

import "modules/common/components"
import "modules/common/mockup"
import "modules/bar/system_update"
import "modules/bar/system_update/components"

// =============================================================================
// mockups/system_update.qml
//
// Mockup for SystemUpdatePopup.qml, on the shared mockup framework
// (modules/common/mockup/, contract in docs/contracts/mockup_framework.md).
// The framework owns the window: the stage on the left that follows the
// popup's implicit size, and the tabbed control panel on the right with the
// * marks, Reset, "Save to mockup" and the profiles. This file provides only
// what is about the system update: the popup and what drives it, the value
// lists, and the Run and Terminal pages.
//
//   quickshell -p mockups/system_update.qml   open it
//   tools/dev/mockup_grab.sh <this> [tab]    render a tab
//   tools/dev/mockup_panel_test.sh <this>    marks / profiles / save round trip
//
// AUTORUN=1 starts the fastest replay (AUTORUN_MODE=quiet|normal|verbose,
// AUTORUN_DELAY) for headless smoke runs; AUTO_SWITCH drives a view-switch
// capture.
// =============================================================================
MockupWindow {
    id: win

    moduleId: "system_update"
    title: "SystemUpdatePopup mockup"
    // Magnified by default: the detail this module is tuned on (particle
    // trails, the groove's inset shading, the ball's squish) is invisible
    // at 1:1 on a 120Hz laptop panel.
    zoom: 2.4
    content: popup
    // The stage stands in for thePopup, which paints the popup's background;
    // the popup itself draws none (it is a drop-in). Without this the
    // surface colour only showed in the ring around the carved boxes.
    stageColor: popup.surfaceColor

    // Every list writes to the popup, except the rail's, which write to the
    // PhaseRail inside it.
    target: popup
    targets: ({
            railParams: popup.rail
        })
    lists: ({
            layoutParams: win.layoutParams,
            cardParams: win.cardParams,
            promptParams: win.promptParams,
            terminalParams: win.terminalParams,
            terminalColors: win.terminalColors,
            swipeParams: win.swipeParams,
            headerParams: win.headerParams,
            listParams: win.listParams,
            railParams: win.railParams,
            popupColors: win.popupColors,
            listColors: win.listColors,
            railColors: win.railColors,
            promptColors: win.promptColors
        })
    // These three lists are the theme's tokens, not the module's own palette.
    themedLists: ["popupColors", "listColors", "promptColors", "railColors", "terminalColors"]

    // One tab per component, so everything that shapes the status card is on
    // the Card tab, everything for the rail on the Rail tab, and so on. The
    // rail carries forty-odd values, so its tab is split by what they do.
    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        {
            name: "Popup",
            lists: ["layoutParams", "popupColors"]
        },
        {
            name: "Card",
            lists: ["cardParams"]
        },
        {
            name: "Rail",
            subs: [
                {
                    name: "Swirl",
                    lists: ["railParams"],
                    groups: ["Glow", "Idle swirl", "Chase"]
                },
                {
                    name: "Sparks",
                    lists: ["railParams"],
                    groups: ["Grind sparks", "Bloom", "Sizes"]
                },
                {
                    name: "Ball",
                    lists: ["railParams"],
                    groups: ["Ball", "Pacing", "Canvas", "Geometry"]
                },
                {
                    name: "Colours",
                    lists: ["railColors"]
                }
            ]
        },
        {
            name: "Prompt",
            lists: ["promptParams", "promptColors"]
        },
        {
            name: "List",
            subs: [
                {
                    name: "Box",
                    lists: ["listParams"],
                    groups: ["List box", "Package groups", "Arch mark"]
                },
                {
                    name: "Headers",
                    lists: ["headerParams"]
                },
                {
                    name: "Flights",
                    lists: ["listParams"],
                    groups: ["Favourite flight", "Header flight"]
                },
                {
                    name: "Colours",
                    lists: ["listColors"]
                }
            ]
        },
        {
            name: "Terminal",
            subs: [
                {
                    name: "Terminal",
                    lists: ["terminalParams", "terminalColors"],
                    groups: ["Terminal", "Terminal surface"]
                },
                {
                    name: "ANSI",
                    lists: ["terminalColors"],
                    groups: ["ANSI", "ANSI bright"]
                }
            ],
            page: terminalPage
        },
        {
            name: "Swipe",
            lists: ["swipeParams"]
        }
    ]

    // =====================================================================
    //  THE DROP-IN CONTENT
    //
    // Exactly what goes into thePopup: sized by its own implicitWidth /
    // implicitHeight per view mode, wired to a backend, a parser and the
    // updates service. The stage gives it nothing but a surface to sit on.
    // =====================================================================
    SystemUpdatePopup {
        id: popup
        diagnostics: true   // the Run page's readout reads the wheel counters
        backend: mockRunToggle.checked ? mockRun.backend : svc.backend
        parser: mockRunToggle.checked ? mockRun.parser : svc.parser
        availableUpdates: svc.avail
        // The snapshots: a stand-in service behind the Run page's "Mock snapshots" (null = none, the popup as it was).
        snapshots: mockSnapToggle.checked ? mockSnaps : null
        // The service serves the askpass socket, as in the bar.
        askpassServer: svc.askpassServer
        railEnabled: railToggle.checked
        railParticles: particleToggle.checked
        tabsAutoHide: tabsAutoToggle.checked
        verbosityMode: modeSwitch.mode
        // Host-level typeface choice. The module keeps its own default;
        // this is the mockup dressing it to match the clock surface.
        fontFamily: "Audiowide"
        terminalWrapLines: wrapToggle.checked
        sectionFlightEnabled: sectionFlightToggle.checked
        onStartUpdateRequested: win.startUpdate()
        // The snapshot stopped the run and the user goes on without one: the mock plays the update on.
        onStartWithoutSnapshotRequested: {
            failStep.currentIndex = 0;
            mockRun.undo = false;
            mockRun.start();
        }
        // The page's undo: the synthetic undo run (the real one is the service's startUndo).
        onUndoRequested: short => win.playUndo()
        onRefreshRequested: svc.refreshIfStale()
        // The recorder reads what this popup believes, as it does in the bar.
        Component.onCompleted: svc.registerPopup(popup)

        // The snapshots page, drawn beside the popup where the engine would hang it (a drop-in secondary: the same
        // component, at its own size). Only the mock stands it on the stage's right; the engine's side is "start".
        Loader {
            id: snapPageHost
            active: popup.secondaryOpen
            sourceComponent: popup.secondaryComponent
            x: popup.width + 12
            y: 0
        }
    }

    // A stand-in SnapshotService for the popup's notch, line and page: ready, a newest row (or none), and the rule's
    // answer (40 packages or more, or a critical name).
    QtObject {
        id: mockSnaps
        readonly property bool live: false
        readonly property bool ready: true
        readonly property bool busy: false
        readonly property var rows: mockSnapEmpty.checked ? [] : [{
                short: "6a493314", timeMs: Date.now() - mockSnapAge.value * 60000, title: "Before 112 packages: linux, mesa",
                reason: "update", changed: [], notable: ["linux", "mesa"], count: 112, state: "done", keep: false,
                addedBytes: 812345678, offsite: false, unfinished: false
            }]
        function wantsFor(names) {
            return { want: names.length >= 40, count: names.length, critical: [] };
        }
        function refresh() {}
    }
    function playUndo() {
        mockRunToggle.checked = true;
        mockRun.undo = true;
        mockRun.start();
    }

    // =====================================================================
    //  THE MODULE'S OWN PANEL PAGES
    // =====================================================================
    pages: [
        // The Run page: replay, real run, the synthetic run and its per-step
        // jumps, the data source, and what the popup draws.
        MockupPage {
            id: runPage


        TipRow {
            tip: "Replays the captured yay -Syu transcript through the real TerminalBackend and parser. Exercises the actual parsing path, unlike Mock run which bypasses it entirely."
            Layout.fillWidth: true
            spacing: 8
            Button {
                text: "▶ Replay"
                enabled: !svc.backend.running
                onClicked: win.startReplay()
            }
            Button {
                text: "⏹ Stop"
                enabled: svc.backend.running
                onClicked: svc.backend.stop()
            }
            Button {
                text: "Reset"
                onClicked: svc.parser.reset()
            }
            Item {
                Layout.fillWidth: true
            }
        }

        TipRow {
            tip: "Seconds between replayed lines. 0 replays as fast as possible; raise it to watch a phase transition in slow motion."
            Layout.fillWidth: true
            spacing: 8
            Label {
                text: "Line delay"
                color: "#5D5D5F"
                font.family: "Audiowide"
                font.pixelSize: 15
            }
            Slider {
                id: delaySlider
                from: 0.005
                to: 0.25
                value: 0.03
                Layout.fillWidth: true
            }
            Label {
                text: delaySlider.value.toFixed(3) + "s"
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 15
            }
        }

        // -- Real-run toggle: when checked, the popup's own "Run
        //    update" button kicks `yay -Syu` instead of replay.
        //    First click arms (4s window), second confirms — that
        //    way a misclick doesn't immediately invoke pacman.
        TipRow {
            tip: "Runs a genuine system update. This really installs packages — everything else in this panel is simulated."
            Layout.fillWidth: true
            spacing: 8
            CheckBox {
                id: realRunToggle
                text: "Real run (yay -Syu)"
                checked: false
                font.family: "Audiowide"
                font.pixelSize: 15
                contentItem: Label {
                    text: realRunToggle.text
                    color: realRunToggle.checked ? "#EC0000" : "#5D5D5F"
                    font.family: "Audiowide"
                    font.pixelSize: 15
                    leftPadding: realRunToggle.indicator.width + 6
                    verticalAlignment: Text.AlignVCenter
                }
            }
            Item {
                Layout.fillWidth: true
            }
            Label {
                visible: win.realRunArmed
                text: "click ‘Run update’ again to confirm"
                color: "#EC0000"
                font.family: "Audiowide"
                font.pixelSize: 14
                font.bold: true
            }
        }

        Label {
            text: "running: " + svc.backend.running + "   lines: " + svc.backend.linesModel.count
            color: "#8A8A8C"
            font.family: "Audiowide"
            font.pixelSize: 15
        }

        TipGroup {
            title: "Mode"
        }

        TipRow {
            id: modeSwitch
            tip: "Forces the popup into quiet, normal or verbose regardless of the tab selector, for comparing layouts at a fixed state."
            property string mode: "normal"
            Layout.fillWidth: true
            spacing: 4
            Label {
                text: "Mode (override)"
                color: "#5D5D5F"
                font.family: "Audiowide"
                font.pixelSize: 14
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
            Button {
                text: "quiet"
                checkable: true
                checked: modeSwitch.mode === "quiet"
                onClicked: modeSwitch.mode = "quiet"
            }
            Button {
                text: "normal"
                checkable: true
                checked: modeSwitch.mode === "normal"
                onClicked: modeSwitch.mode = "normal"
            }
            Button {
                text: "verbose"
                checkable: true
                checked: modeSwitch.mode === "verbose"
                onClicked: modeSwitch.mode = "verbose"
            }
        }

        TipGroup {
            title: "Synthetic run"
            blurb: "Drives every phase with no process or parsing. Use this for visuals."
        }

        // ---- Synthetic run (visual review) ----
        TipRow {
            tip: "Drives the popup through every phase with no process, no PTY and no parsing. This is the one to use for looking at visuals; the replay spends almost all its time in a single phase."
            Layout.fillWidth: true
            spacing: 8
            CheckBox {
                id: mockRunToggle
                text: "Mock run"
                checked: false
                font.family: "Audiowide"
                font.pixelSize: 15
                onCheckedChanged: if (!checked)
                    mockRun.reset()
            }
            Button {
                text: mockRun.running ? "⏸ Pause" : "▶ Play"
                enabled: mockRunToggle.checked
                font.pixelSize: 13
                padding: 5
                onClicked: {
                    if (!mockRun.running)
                        mockRun.undo = false;
                    mockRun.running ? mockRun.stop() : mockRun.start();
                }
            }
            Button {
                text: "▶ Undo"
                enabled: mockRunToggle.checked && !mockRun.running
                font.pixelSize: 13
                padding: 5
                onClicked: win.playUndo()
            }
            Button {
                text: "⟲ Reset"
                enabled: mockRunToggle.checked
                font.pixelSize: 13
                padding: 5
                onClicked: mockRun.reset()
            }
            Button {
                // What closing the popup does in the bar: lets
                // go of the finished run's overview.
                text: "Dismiss overview"
                enabled: popup._runHeld
                font.pixelSize: 13
                padding: 5
                onClicked: popup.dismissRunOverview()
            }
            Item {
                Layout.fillWidth: true
            }
        }

        TipRow {
            tip: "Stands a mock SnapshotService under the popup: the Snapshot notch (the synthetic run takes a snapshot between the integrity checks and the install; 'fail at' snapshot stops it there), the idle line under the headline, and the page it opens. Off, the popup has no snapshots at all."
            Layout.fillWidth: true
            spacing: 8
            CheckBox {
                id: mockSnapToggle
                text: "Mock snapshots"
                checked: false
                font.family: "Audiowide"
                font.pixelSize: 15
            }
            CheckBox {
                id: mockSnapEmpty
                text: "none yet"
                enabled: mockSnapToggle.checked
                font.family: "Audiowide"
                font.pixelSize: 15
            }
            Label {
                text: "age " + mockSnapAge.value + " min"
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 14
            }
            Slider {
                id: mockSnapAge
                from: 0
                to: 4000
                stepSize: 10
                value: 180
                enabled: mockSnapToggle.checked
                Layout.fillWidth: true
            }
        }

        TipRow {
            tip: "Playback speed of the synthetic run. Below 1 holds each phase longer, which is what looking at a transition needs."
            Layout.fillWidth: true
            spacing: 8
            Label {
                text: "speed"
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 14
                Layout.preferredWidth: 138
            }
            Slider {
                id: mockSpeed
                from: 0.15
                to: 4.0
                value: 1.0
                Layout.fillWidth: true
            }
            Label {
                text: mockSpeed.value.toFixed(2) + "×"
                color: "#5D5D5F"
                font.family: "Audiowide"
                font.pixelSize: 14
                Layout.preferredWidth: 56
                horizontalAlignment: Text.AlignRight
            }
        }

        // Jump straight to any phase and hold it there. This is
        // the point of the whole mock: a real run flashes through
        // integrity and hooks in under a second each.
        TipRow {
            tip: "Jumps the synthetic run straight to a step and holds it there (while the synthetic run is on): a real run passes integrity and hooks in under a second each, too fast to look at. The step on show is highlighted."
            Flow {
                Layout.fillWidth: true
                spacing: 4
                Repeater {
                    model: mockRun.stepNames
                    delegate: Button {
                        required property string modelData
                        required property int index
                        text: modelData
                        enabled: mockRunToggle.checked
                        highlighted: mockRun.stepName === modelData
                        font.pixelSize: 14
                        padding: 4
                        onClicked: mockRun.gotoStep(index)
                    }
                }
            }
        }

        TipRow {
            tip: "Injects a failure when the run reaches this step, so error styling can be inspected. Works when scrubbing to a step as well as during playback."
            Layout.fillWidth: true
            spacing: 8
            Label {
                text: "fail at"
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 14
            }
            ComboBox {
                id: failStep
                model: mockSnapToggle.checked ? ["none", "download", "snapshot", "install", "hooks", "aur-build"]
                                              : ["none", "download", "install", "hooks", "aur-build"]
                currentIndex: 0
                Layout.preferredWidth: 152
                font.pixelSize: 14
            }
            Label {
                // What the parser believes, in its own words, so a real
                // run can be cross-read against the UI log; the mock adds
                // its step counter. No enum names.
                text: {
                    const pp = popup.parser;
                    const phase = pp && pp.phaseLabel ? pp.phaseLabel : "";
                    const sub = pp && pp.subPhaseLabel ? pp.subPhaseLabel : "";
                    const live = phase + (sub.length > 0 ? "  ·  " + sub : "");
                    return mockRunToggle.checked
                        ? ("step " + (mockRun.stepIndex + 1) + "/" + mockRun.stepCount
                           + "  ·  " + mockRun.stepName.replace(/[_-]/g, " ")
                           + (live.length > 0 ? "  ·  " + live : ""))
                        : (live.length > 0 ? live : "no run");
                }
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 14
                Layout.fillWidth: true
                elide: Text.ElideRight
            }
        }

        TipGroup {
            title: "Data"
            blurb: "What the idle list is populated from."
        }

        // ---- Mock dataset ----
        // Feeds the SAME service that drives real data, so the
        // lists exercise identical categorisation, ordering,
        // favourite and animation code. Sizes are picked to cover
        // the interesting cases: one category far taller than any
        // viewport, a couple of mid-size ones, and small ones that
        // fit entirely on screen.
        TipRow {
            tip: "Replaces checkupdates / yay / flatpak output with a fixed dataset: one category far taller than any viewport, a couple of mid-size ones, and small ones that fit entirely on screen."
            Layout.fillWidth: true
            spacing: 8
            CheckBox {
                id: mockToggle
                text: "Mock data"
                checked: false
                font.family: "Audiowide"
                font.pixelSize: 15
                onCheckedChanged: svc.mockAvailable = checked
            }
            Label {
                text: mockToggle.checked ? "core 9 · extra 180 · multilib 14 · aur 6 · flatpak 5" : "live (checkupdates / yay / flatpak)"
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 14
                Layout.fillWidth: true
                elide: Text.ElideRight
            }
        }

        TipGroup {
            title: "Header reorder"
            blurb: "The category order the AUR step imposes, and the flight that carries a header from one place in the list to another."
        }

        TipRow {
            tip: "Forces the order the run would impose. AUR leads while it is building -- it is the only category doing anything and the others are shut, so leaving it under three closed headers buries the one list that is moving -- and trails at every other step. Auto hands the decision back to the run. This works with no run at all, which is the only practical way to look at it: a real update reorders exactly twice, minutes apart."
            Layout.fillWidth: true
            spacing: 8
            Label {
                text: "Category order"
                font.family: "Audiowide"
                font.pixelSize: 14
            }
            Button {
                text: "AUR leads"
                checkable: true
                checked: popup.categoryOrderOverride === "aur-first"
                font.pixelSize: 13
                padding: 5
                onClicked: popup.categoryOrderOverride = "aur-first"
            }
            Button {
                text: "AUR trails"
                checkable: true
                checked: popup.categoryOrderOverride === "aur-last"
                font.pixelSize: 13
                padding: 5
                onClicked: popup.categoryOrderOverride = "aur-last"
            }
            Button {
                text: "Auto"
                checkable: true
                checked: popup.categoryOrderOverride === ""
                font.pixelSize: 13
                padding: 5
                onClicked: popup.categoryOrderOverride = ""
            }
            Item {
                Layout.fillWidth: true
            }
        }

        TipRow {
            tip: "Turns the header flight off, so a reorder jumps the way it used to. This is the A/B: press an order button with it off for the before picture, and the list must settle in exactly the same place either way -- the flight is a way of getting there, not a different destination."
            Layout.fillWidth: true
            spacing: 8
            CheckBox {
                id: sectionFlightToggle
                text: "Fly header moves"
                checked: true
                font.family: "Audiowide"
                font.pixelSize: 15
            }
            Label {
                text: popup.categoryOrderText
                    + (popup.sectionFlightActive ? "   [flying " + popup.sectionFlightKey + "]" : "")
                font.family: "Audiowide"
                font.pixelSize: 13
                color: popup.sectionFlightActive ? "#4480F4" : "#6F6F72"
                Layout.fillWidth: true
                elide: Text.ElideRight
            }
        }

        TipGroup {
            title: "View"
            blurb: "What the popup draws."
        }

        TipRow {
            tip: "What the popup draws. The rail and its particles are the expensive part of an idle popup, so being able to take each away is how their cost is judged. Hide tabs when away is the bar's behaviour: the quiet / normal / verbose row is shown only while the pointer is over the popup (and for a moment after a view switch or a swipe) and the content refits into the freed room; switch it off to tune from this panel without the popup resizing every time the pointer comes here. Magnification and the frame counter live on the stage's own toolbar."
            Layout.fillWidth: true
            spacing: 8
            CheckBox {
                id: railToggle
                text: "Rail"
                checked: true
                font.family: "Audiowide"
                font.pixelSize: 15
            }
            CheckBox {
                id: particleToggle
                text: "Particles"
                checked: true
                font.family: "Audiowide"
                font.pixelSize: 15
            }
            CheckBox {
                id: tabsAutoToggle
                text: "Hide tabs when away"
                checked: true
                font.family: "Audiowide"
                font.pixelSize: 15
            }
            Item {
                Layout.fillWidth: true
            }
        }

        TipGroup {
            title: "Diagnostics"
            blurb: "Live wheel events and the gesture latch, for confirming input reaches the popup."
        }

        // ---- Wheel diagnostics ----
        // Shows what the popup actually receives from the
        // touchpad. If a horizontal two-finger swipe leaves
        // angleX and pixelX at 0, the gesture is not reaching Qt
        // at all and no amount of tuning in QML will help.
        Label {
            Layout.fillWidth: true
            text: "wheel #" + popup.wheelEventCount + "   angle " + Math.round(popup.lastWheelAngleX) + "," + Math.round(popup.lastWheelAngleY) + "   pixel " + Math.round(popup.lastWheelPixelX) + "," + Math.round(popup.lastWheelPixelY) + "   swipe accum " + Math.round(popup.lastSwipeAccum) + (popup.swipeGestureActive ? (popup.gestureOwnedByTerminal ? "   [gesture: TERMINAL]" : "   [gesture: TABS]") : "   [gesture: idle]")
            color: popup.lastWheelAngleX !== 0 || popup.lastWheelPixelX !== 0 ? "#44C145" : "#8A8A8C"
            font.family: "Audiowide"
            font.pixelSize: 14
            wrapMode: Text.Wrap
        }
        },

        // The terminal's one non-numeric option.
        MockupPage {
            id: terminalPage

        TipRow {
            tip: "Wraps long terminal lines instead of scrolling horizontally. Also disables the swipe exception: with nothing cut off, a horizontal gesture over the terminal changes tabs again."
            Layout.fillWidth: true
            spacing: 8
            CheckBox {
                id: wrapToggle
                text: "Wrap terminal"
                checked: false
                font.family: "Audiowide"
                font.pixelSize: 15
            }
        }
        }
    ]

    // =====================================================================
    //  VALUES
    //
    // One array per component, each entry a control on the panel. `val` is
    // this file's default for that property: pushed into the target on load,
    // restored by Reset, compared against for the * marks, and rewritten in
    // place by "Save to mockup". Every entry carries a `tip`.
    // =====================================================================
    readonly property var railParams: [
        {
            label: "glow speed ref",
            prop: "glowSpeedRef",
            group: "Glow",
            blurb: "How a particle brightens and thickens with its speed.",
            tip: "Speed (px/ms) at which a particle glows at full strength. Glow scales linearly from 0 up to this, then clamps. Set it FAR above orbit speeds so an idle swirl stays almost uniform \u2014 only particles being dragged after the ball should flare. At 420 the whole swirl was past the ceiling and rendered white.",
            val: 6000,
            from: 100,
            to: 6000,
            step: 50
        },
        {
            label: "glow max",
            prop: "glowMax",
            group: "Glow",
            tip: "Alpha multiplier at full speed. 1 = no brightening. 2.6 means a particle at glowSpeedRef draws 2.6x its normal opacity (clamped at fully opaque).",
            val: 2.4,
            from: 1,
            to: 5,
            step: 0.1
        },
        {
            label: "glow size gain",
            prop: "glowSizeGain",
            group: "Glow",
            tip: "Thickness gain at full speed. 0.7 = a particle at glowSpeedRef draws 70% fatter. These render as trails, so this is the streak's line width, and it multiplies on top of the sizeStart\u2192sizeEnd taper.",
            val: 1.7,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "orbit radius",
            prop: "orbitRadius",
            group: "Idle swirl",
            blurb: "The ring of particles orbiting the ball while it rests.",
            tip: "Target distance from the ball each swirl particle settles at. Each particle randomises 0.75\u20131.25x of this, which is what gives the ring thickness instead of a hard circle.",
            val: 10,
            from: 3,
            to: 40,
            step: 1
        },
        {
            label: "orbit speed",
            prop: "orbitSpeed",
            group: "Idle swirl",
            tip: "Tangential drive \u2014 how fast particles travel AROUND the ball. This alone would fling them outward; the spring below supplies the centripetal force that turns it into an orbit.",
            val: 18,
            from: 2,
            to: 140,
            step: 2
        },
        {
            label: "orbit spring",
            prop: "orbitRadialK",
            group: "Idle swirl",
            tip: "Spring stiffness pulling each particle to its target radius (Hooke: force = (distance \u2212 radius) \u00d7 k). High = tight, snappy ring that can jitter. Low = loose, smeary cloud. Pairs with orbit drag: damping ratio = drag / (2\u00b7\u221ak), so critical damping here is drag \u2248 5.3.",
            val: 6.5,
            from: 0.5,
            to: 24,
            step: 0.5
        },
        {
            label: "orbit drag",
            prop: "orbitDrag",
            group: "Idle swirl",
            tip: "Velocity damping on swirl particles. Without it the spring oscillates forever and particles breathe in and out. Raise this before lowering the spring if the ring looks jittery.",
            val: 1.1,
            from: 0,
            to: 8,
            step: 0.1
        },
        {
            label: "orbit spawn ms",
            prop: "orbitSpawnMs",
            group: "Idle swirl",
            tip: "Interval between swirl emissions while the ball rests in a notch. Lower = denser swirl and more particles alive at once.",
            val: 75,
            from: 20,
            to: 600,
            step: 10
        },
        {
            label: "orbit lifetime",
            prop: "orbitLifetime",
            group: "Idle swirl",
            tip: "Base lifetime of a swirl particle in ms (a random extra is added on top). Also caps its max life, so it dies on schedule rather than orbiting forever.",
            val: 2000,
            from: 200,
            to: 6000,
            step: 100
        },
        {
            label: "orbit seed",
            prop: "orbitSeedCount",
            group: "Idle swirl",
            tip: "Particles emitted in one burst when a run starts, so a popup opened mid-update shows a swirl already established instead of one streaking into place.",
            val: 14,
            from: 0,
            to: 40,
            step: 1
        },
        {
            label: "chase strength",
            prop: "chaseStrength",
            group: "Chase",
            blurb: "Particles trailing the ball while it travels, and settling back after.",
            tip: "Extra pull toward the ball while it travels between notches, on top of the orbit spring. This is what makes particles trail the ball. Too high overshoots; too low and they get left behind.",
            val: 420,
            from: 0,
            to: 2500,
            step: 20
        },
        {
            label: "chase falloff",
            prop: "chaseFalloffMs",
            group: "Chase",
            tip: "How long the chase pull decays over after the ball stops. Lets survivors settle back into orbit instead of piling onto the ball.",
            val: 380,
            from: 60,
            to: 1500,
            step: 20
        },
        {
            label: "chase arrive r",
            prop: "chaseArriveRadius",
            group: "Chase",
            tip: "Distance at which a chasing particle counts as having reached the ball and starts its death fade. Keep it below orbit radius, or resting particles would die immediately.",
            val: 7,
            from: 1,
            to: 30,
            step: 1
        },
        {
            label: "chase fade ms",
            prop: "chaseArriveFadeMs",
            group: "Chase",
            tip: "Fade-out duration once a particle reaches the ball. Physics keeps running during the fade so the trail scrolls out naturally rather than popping.",
            val: 260,
            from: 60,
            to: 900,
            step: 20
        },
        {
            label: "spark gate spd",
            prop: "sparkSpeedThreshold",
            group: "Grind sparks",
            blurb: "The sparks the ball sheds as it moves.",
            tip: "Minimum ball speed (px/ms) that sheds any spark at all \u2014 the on/off gate. Measured creep: download sustains 0.020, install 0.020, hooks 0.005 but peaks at 0.899 because it jumps in eight discrete steps. Set below the sustained creep so continuous progress qualifies; a parked ball is exactly 0 and never does.",
            val: 0.012,
            from: 0.0,
            to: 0.5,
            step: 0.002
        },
        {
            label: "spark creep spd",
            prop: "sparkCreepSpeed",
            group: "Grind sparks",
            tip: "Boundary between 'creeping through a step' (throttled by spark creep ms) and 'travelling between notches' (a spark every frame). Notch travel measures 2.5\u20133.7 px/ms and the fastest creep is 0.9, so 1.2 sits between the two populations.",
            val: 1.2,
            from: 0.05,
            to: 4.0,
            step: 0.05
        },
        {
            label: "spark amount",
            prop: "sparkAmountMultiplier",
            group: "Grind sparks",
            tip: "Sparks emitted per unit of ball speed. Higher = a denser shower during fast notch-to-notch travel.",
            val: 3.0,
            from: 0,
            to: 12,
            step: 0.2
        },
        {
            label: "spark scatter",
            prop: "sparkScatter",
            group: "Grind sparks",
            tip: "Random velocity spread added to each spark, in px/s. This is what fans the shower out instead of firing one tight jet backwards.",
            val: 100,
            from: 0,
            to: 300,
            step: 5
        },
        {
            label: "spark lifetime",
            prop: "sparkLifetimeBase",
            group: "Grind sparks",
            tip: "Base spark lifetime in ms; a random extra is added. Sparks are debris \u2014 they are not attracted to the ball and simply fade where they land.",
            val: 700,
            from: 100,
            to: 3000,
            step: 50
        },
        {
            label: "spark drag",
            prop: "sparkDrag",
            group: "Grind sparks",
            tip: "Air resistance on sparks. High = they slow quickly and drop close to the rail; low = they fly far.",
            val: 2.0,
            from: 0,
            to: 8,
            step: 0.1
        },
        {
            label: "spark creep ms",
            prop: "sparkCreepIntervalMs",
            group: "Grind sparks",
            tip: "Minimum gap between spark emissions while the ball is creeping through a measurable step. 220 ms \u2248 4\u20135 sparks a second. This is the knob for 'only a few particles per second on slow bars'.",
            val: 220,
            from: 0,
            to: 1200,
            step: 20
        },
        {
            label: "edge fade px",
            prop: "particleFadeWidth",
            group: "Grind sparks",
            tip: "How far inside the card's edge a particle has fully faded out. One mask over the whole particle layer, not a per-particle thing; the card clips flush with its edge, so without this a spark that flies past it is cut off hard.",
            val: 18,
            from: 0,
            to: 60,
            step: 1
        },
        {
            label: "bloom blur",
            prop: "bloomBlur",
            group: "Bloom",
            blurb: "The glow pass over the whole particle canvas.",
            tip: "Blur radius of the glow pass over the whole particle canvas. Large values are soft and hazy; small values keep streaks crisp.",
            val: 22,
            from: 0,
            to: 64,
            step: 1
        },
        {
            label: "bloom strength",
            prop: "bloomStrength",
            group: "Bloom",
            tip: "How much of the blurred pass is mixed in. 0 disables the bloom entirely.",
            val: 0.32,
            from: 0,
            to: 1,
            step: 0.02
        },
        {
            label: "bloom bright",
            prop: "bloomBrightness",
            group: "Bloom",
            tip: "Overall brightness of the bloom layer. Compounds with glow max, so raising both quickly washes particles to white.",
            val: 0.50,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "particle size",
            prop: "particleSizeScale",
            group: "Sizes",
            blurb: "Particle widths and trails: one multiplier over all, then each kind at birth and at death.",
            tip: "Global multiplier over every particle size, both types and both ends. Scales the whole effect without re-balancing the four numbers below.",
            val: 1.0,
            from: 0.2,
            to: 4,
            step: 0.05
        },
        {
            label: "orbit size in",
            prop: "orbitSizeStart",
            group: "Sizes",
            tip: "Swirl particle width at birth. These draw as trails, so this is the line width of the streak, not a dot diameter.",
            val: 3.0,
            from: 0.2,
            to: 10,
            step: 0.1
        },
        {
            label: "orbit size out",
            prop: "orbitSizeEnd",
            group: "Sizes",
            tip: "Swirl particle width at end of life. Interpolates from the start value across the lifetime; lower = tapering threads.",
            val: 1.3,
            from: 0.0,
            to: 10,
            step: 0.1
        },
        {
            label: "spark size in",
            prop: "sparkSizeStart",
            group: "Sizes",
            tip: "Spark width at birth. Sparks are usually chunkier than swirl particles since they are debris rather than a haze.",
            val: 3.0,
            from: 0.2,
            to: 12,
            step: 0.1
        },
        {
            label: "spark size out",
            prop: "sparkSizeEnd",
            group: "Sizes",
            tip: "Spark width at end of life.",
            val: 1.0,
            from: 0.0,
            to: 12,
            step: 0.1
        },
        {
            label: "orbit trail",
            prop: "particleMaxHistory",
            group: "Sizes",
            tip: "Trail length for swirl particles, in retained positions. 1 renders a dot instead of a streak; higher values leave longer ribbons and cost slightly more to draw.",
            val: 6,
            from: 1,
            to: 24,
            step: 1
        },
        {
            label: "spark trail",
            prop: "sparkMaxHistory",
            group: "Sizes",
            tip: "Trail length for sparks. Longer reads as a fast-moving ember.",
            val: 8,
            from: 1,
            to: 24,
            step: 1
        },
        {
            label: "ball stretch",
            prop: "ballStretchMax",
            group: "Ball",
            blurb: "The ball: its stretch in the groove, its light and shadow, and the filled groove behind it.",
            tip: "Longest the ball may stretch while TRAVELLING between notches, as a multiple of its diameter. Area conservation alone gives a very long ball in the narrow channel; this caps it.",
            val: 2.5,
            from: 1.0,
            to: 6.0,
            step: 0.1
        },
        {
            label: "ball stretch prog",
            prop: "ballStretchMaxProgress",
            group: "Ball",
            tip: "Same cap while CREEPING through download or install. Kept shorter than the travel cap: a long ball reads as speed, which looks silly on a bar that is barely moving.",
            val: 1.1,
            from: 1.0,
            to: 6.0,
            step: 0.1
        },
        {
            label: "ball groove bleed",
            prop: "ballGrooveBleed",
            group: "Ball",
            tip: "Extra height beyond the channel when fully squished, in px. Matching the channel exactly leaves the groove's darker edge showing as a hairline above and below the ball, because both shapes are antialiased and each gives up part of its outermost pixel.",
            val: 1.0,
            from: 0.0,
            to: 6.0,
            step: 0.25
        },
        {
            label: "fill darken",
            prop: "fillDarken",
            group: "Ball",
            tip: "How much darker the groove's FILLED part is than the run tone. The channel is recessed and takes more shadow, so it should sit below the ball, not above it.",
            val: 1.4,
            from: 1.0,
            to: 3.0,
            step: 0.05
        },
        {
            label: "fill shadow dk",
            prop: "fillShadowDarken",
            group: "Ball",
            tip: "Darkening of the filled groove's inset shadow ring \u2014 the deepest part of the engraving.",
            val: 1.9,
            from: 1.0,
            to: 4.0,
            step: 0.05
        },
        {
            label: "ball lighten",
            prop: "ballLighten",
            group: "Ball",
            tip: "How much lighter the ball is than the run tone. Raise it if the ball blends into the filled groove and its squish becomes hard to read.",
            val: 1.12,
            from: 0.5,
            to: 2.5,
            step: 0.02
        },
        {
            label: "ball shadow op",
            prop: "ballShadowOpacity",
            group: "Ball",
            tip: "Opacity of the ball's contact shadow. Neutral dark rather than a coloured glow, so the ball reads as sitting IN the channel.",
            val: 0.55,
            from: 0.0,
            to: 1.0,
            step: 0.05
        },
        {
            label: "ball shadow blur",
            prop: "ballShadowBlur",
            group: "Ball",
            tip: "Softness of the ball's contact shadow. Tight = hard contact; wide = floating.",
            val: 12,
            from: 0,
            to: 48,
            step: 1
        },
        {
            label: "min dwell ms",
            prop: "minDwellMs",
            group: "Pacing",
            blurb: "How long the ball rests in a notch and how fast it may travel to the next.",
            tip: "Shortest time the ball rests in a notch after seating before it may leave for the NEXT notch. Progress creep inside a step is exempt and starts at once. A step that finishes in a blink (two pre-transaction hooks) is still seen to have happened. While it waits the ball holds where it is and catches up with the latest target in one move, so it never replays a stale sequence and never goes backwards.",
            val: 1000, from: 0, to: 4000, step: 50
        },
        {
            label: "max travel px/ms",
            prop: "maxTravelPxPerMs",
            group: "Pacing",
            tip: "Cap on the AVERAGE speed of a step change, in px per ms (the OutQuart easing peaks at about four times this). Notches sit ~84px apart, so at 0.35 a one-notch hop stays at the base duration and a four-notch skip takes about a second. Progress creep inside a step is not affected. 0 disables the cap.",
            val: 0.35, from: 0, to: 3, step: 0.05
        },
        {
            label: "step move ms",
            prop: "stepMoveMs",
            group: "Pacing",
            tip: "Base duration of a step change before the speed cap is applied; the longer of the two wins.",
            val: 460, from: 100, to: 2000, step: 20
        },
        {
            label: "canvas margin",
            prop: "particleMargin",
            group: "Canvas",
            blurb: "The particle canvas around the rail.",
            tip: "How far the particle canvas extends beyond the rail on every side, in px. The canvas culls to its own bounds and the rail's box is only as tall as the groove plus labels, so too small a margin clips the top of every orbit.",
            val: 46,
            from: 0,
            to: 160,
            step: 4
        },
        {
            label: "size scale",
            prop: "sizeScale",
            group: "Geometry",
            blurb: "The rail's own box: groove, notches, ball and labels.",
            tip: "Multiplier over the groove, the notches, the ball and the paddings together. Labels keep their own size.",
            val: 1.0, from: 0.5, to: 2.0, step: 0.05
        },
        {
            label: "line thickness",
            prop: "lineThickness",
            group: "Geometry",
            tip: "Height of the groove channel in px. The ball squishes down to this while travelling between notches.",
            val: 6, from: 2, to: 16, step: 0.5
        },
        {
            label: "dot size",
            prop: "dotSize",
            group: "Geometry",
            tip: "Diameter of each notch in the groove.",
            val: 13, from: 6, to: 24, step: 0.5
        },
        {
            label: "ball size",
            prop: "ballSize",
            group: "Geometry",
            tip: "Diameter of the ball at rest in a notch. Between notches it flattens to the channel and stretches to conserve its area.",
            val: 15, from: 8, to: 28, step: 0.5
        },
        {
            label: "edge padding",
            prop: "edgePadding",
            group: "Geometry",
            tip: "Distance from either end of the rail to its first and last notch.",
            val: 20, from: 0, to: 48, step: 1
        },
        {
            label: "label size",
            prop: "labelSize",
            group: "Geometry",
            tip: "Pixel size of the step labels under the groove.",
            val: 10, from: 7, to: 16, step: 1
        },
        {
            label: "label gap",
            prop: "labelGap",
            group: "Geometry",
            tip: "Gap between the groove and the labels.",
            val: 7, from: 0, to: 20, step: 1
        },
        {
            label: "min label width",
            prop: "minLabelWidth",
            group: "Geometry",
            tip: "Width reserved per label, so short and long step names are spaced evenly rather than by their text.",
            val: 54, from: 20, to: 120, step: 2
        },
        {
            label: "tone fade ms",
            prop: "toneFadeMs",
            group: "Geometry",
            tip: "How long the rail's tone takes to settle into green or red when a run ends, instead of snapping. Groove fill, ball and particles all read the same tone, so they change together.",
            val: 900, from: 0, to: 3000, step: 50
        }
    ]

    // Tab-selector swipe physics, bound to the popup.
    readonly property var swipeParams: [
        {
            prop: "swipeThreshold",
            group: "Gestures",
            blurb: "Two-finger swipe physics for the tab selector.",
            label: "swipe threshold",
            tip: "Horizontal wheel delta that must accumulate before the view changes. Higher = a longer, more deliberate two-finger swipe. This is the clock popup's proven value; a much lower guess felt twitchy.",
            from: 400,
            to: 2500,
            step: 50,
            val: 1500
        },
        {
            prop: "swipePullTaper",
            group: "Gestures",
            label: "pull taper",
            tip: "Shape of the pill's displacement as you swipe. The pull follows 1\u2212(1\u2212t)^k, so a higher exponent front-loads the movement: the pill responds immediately, then eases as it nears the commit point.",
            from: 1.0,
            to: 6.0,
            step: 0.1,
            val: 2.5
        },
        {
            prop: "swipeMaxPull",
            group: "Gestures",
            label: "max pull",
            tip: "Furthest the pill can be dragged before committing, as a fraction of one tab slot. Clamped to zero at the ends of the tab list so there is no pull toward a tab that does not exist.",
            from: 0.1,
            to: 0.9,
            step: 0.02,
            val: 0.42
        },
        {
            prop: "swipeMomentumRate",
            group: "Gestures",
            label: "momentum rate",
            tip: "Accumulation speed above which one gesture crosses more than one tab. A fast flick from quiet straight to verbose skips the middle tab instead of stopping at it.",
            from: 800,
            to: 8000,
            step: 100,
            val: 2400
        },
        {
            prop: "squishMax",
            group: "Gestures",
            label: "squish max",
            tip: "Peak squash-and-stretch of the pill while it moves, as a fraction. Area is conserved, so stretching along the travel direction narrows it across.",
            from: 0.0,
            to: 0.5,
            step: 0.01,
            val: 0.18
        },
        {
            prop: "squishVelocityRef",
            group: "Gestures",
            label: "squish vel ref",
            tip: "Pill speed at which squash reaches squish max. Lower makes the pill deform on gentle movement; higher reserves it for fast flicks.",
            from: 200,
            to: 3000,
            step: 50,
            val: 850
        },
        {
            prop: "swipeCooldownMs",
            group: "Gestures",
            label: "cooldown ms",
            tip: "Gap between slow-swipe commits, so one long two-finger drag steps through the tabs one at a time instead of racing to the end.",
            from: 0,
            to: 1000,
            step: 10,
            val: 320
        }
    ]

    // Status card parameters, bound to the popup.
    readonly property var cardParams: [
        {
            label: "download name cycle ms",
            prop: "downloadNameCycleMs",
            group: "Status card",
            blurb: "The card's surface and inset are the popup palette and the list box colour; see the Popup and List tabs.",
            tip: "How long each window of package names is held on the operation line while pacman downloads several files at once. ParallelDownloads is 20 here, so the line can never show them all: it fits as many as the figures leave room for and winds on to the next window at this interval. Nothing cycles when they all fit, because rotating a complete list would be movement for its own sake. 2000 is about as fast as a name can be read without the line feeling restless.",
            val: 2000, from: 500, to: 8000, step: 100
        },
        {
            label: "subtitle delay ms",
            prop: "idleSubtextDelayMs",
            group: "Status card",
            tip: "How long after the update check completes the 'N official · M non-official' line appears. A beat late on purpose: the headline is read first, and the list's silhouette finishes becoming the list before the card grows a line and shifts everything under it.",
            val: 1200, from: 0, to: 4000, step: 100
        },
        {
            label: "steps settle ms",
            prop: "stepsSettleMs",
            group: "Status card",
            tip: "How long the package model must be quiet before the ball may leave Sync for Resolve. yay's upgrade list can add the Sources and AUR notches, and re-spacing the rail while the ball is already travelling sent it backwards. Everything keyed off the current step waits with it.",
            val: 400, from: 0, to: 2000, step: 50
        }
    ]

    // Popup layout parameters, bound to the popup.
    readonly property var layoutParams: [
        {
            label: "popup padding px",
            prop: "padding",
            group: "Layout",
            blurb: "The popup's frame: its padding, the card's padding, the rail's gap and the card's resize.",
            tip: "The popup's inner padding on every side, and the gap between the tab row and the card. One number, so the space above the tabs equals the space below them and the space at the foot. Quiet mode's height is built from it, so the stage follows.",
            val: 12, from: 0, to: 30, step: 1
        },
        {
            label: "card padding px",
            prop: "cardPadding",
            group: "Layout",
            tip: "Clearance between the status card's edge and its texts, rail and prompt. The card clips at its edge (so the rail's particles can fade out exactly there); this is what keeps the content off it.",
            val: 12, from: 4, to: 24, step: 1
        },
        {
            label: "rail gap px",
            prop: "railGap",
            group: "Layout",
            tip: "Gap between the text block and the rail, and between the rail and an open prompt. The rail is glued to the card's bottom edge; this is how far above that edge the texts stop.",
            val: 8, from: 0, to: 20, step: 1
        },
        {
            label: "card resize ms",
            prop: "containerResizeMs",
            group: "Layout",
            tip: "How long the status card takes to settle when its content changes size — a subtitle appearing, the rail fading in, the prompt banner opening. The rail's fade and the banner's height run on the same clock, so the card grows as one.",
            val: 260, from: 0, to: 1000, step: 10
        },
        {
            label: "tab selector px",
            prop: "tabSelectorWidth",
            group: "Layout",
            tip: "Width of the quiet / normal / verbose pill row at the top of the popup.",
            val: 400, from: 200, to: 500, step: 10
        },
        {
            label: "list scale normal",
            prop: "normalListScale",
            group: "List density",
            blurb: "Row scale for the package list, independently per view.",
            tip: "Row density for the package list in normal view. Every size and the animation maths follow it, so the stagger stays correct at any scale.",
            val: 1.2, from: 0.6, to: 2.0, step: 0.05
        },
        {
            label: "list scale verbose",
            prop: "verboseListScale",
            group: "List density",
            tip: "Row density for the package list in verbose view, where the list shares width with the terminal.",
            val: 1.1, from: 0.6, to: 2.0, step: 0.05
        }
    ]

    // Prompt banner parameters, bound to the popup.
    readonly property var promptParams: [
        {
            label: "input height",
            prop: "promptInputHeight",
            group: "Prompt",
            blurb: "The buttons stand on the list box colour (List tab); their own colours are below.",
            tip: "Height of the prompt's carved field and its raised buttons alike. They sit level: one surface with a groove and a plateau.",
            val: 30, from: 22, to: 44, step: 1
        },
        {
            label: "button shadow px",
            prop: "promptButtonShadowWidth",
            group: "Prompt",
            tip: "Spread of the drop shadow a raised button throws on the card, strongest at its edge. Falls into the gap beside the carved field, which is what carries the surface from groove to plateau.",
            val: 5, from: 0, to: 14, step: 0.5
        },
        {
            label: "button bevel px",
            prop: "promptButtonBevelWidth",
            group: "Prompt",
            tip: "Width of the highlight just inside a raised button's edge, easing into its plateau. Thinner than the shadow on purpose: a highlight is a line, a shadow spreads.",
            val: 1.5, from: 0, to: 6, step: 0.5
        },
        {
            label: "button radius px",
            prop: "promptButtonRadius",
            group: "Prompt",
            tip: "Corner radius of the prompt's field and buttons.",
            val: 8, from: 2, to: 15, step: 1
        }
    ]

    // Terminal (verbose view) parameters, bound to the popup.
    readonly property var promptColors: [
        {
            label: "button plateau",
            prop: "promptButtonColor",
            group: "Button colours",
            blurb: "The raised buttons beside the carved field. The accent (default answer) plateau is the popup's accent colour on the Popup tab.",
            tip: "Plateau of a plain raised button at rest.",
            val: "#EAEDF5"
        },
        {
            label: "button hover",
            prop: "promptButtonHoverColor",
            group: "Button colours",
            tip: "Plateau of a plain raised button under the pointer.",
            val: "#F2F4F9"
        },
        {
            label: "button bevel",
            prop: "promptButtonBevelColor",
            group: "Button colours",
            tip: "Highlight just inside a plain button's edge, easing into the plateau.",
            val: "#FFFFFF"
        },
        {
            label: "button shadow",
            prop: "promptButtonShadowColor",
            group: "Button colours",
            tip: "Deepest tone of the drop shadow a raised button throws on the card.",
            val: "#AAADB4"
        },
        {
            label: "accent bevel",
            prop: "promptAccentBevelColor",
            group: "Button colours",
            tip: "Highlight inside an accent (default answer) button's edge.",
            val: "#8DB3F8"
        }
    ]

    readonly property var terminalParams: [
        {
            label: "terminal font px",
            prop: "terminalFontSize",
            group: "Terminal",
            blurb: "The verbose view's terminal: its type size and its two-finger scroll.",
            tip: "Pixel size of the terminal's monospace text in verbose view. Consolas Bold, as in kitty. The PTY is 120 columns wide regardless, so a smaller font shows more of each row.",
            val: 12, from: 8, to: 18, step: 1
        },
        {
            label: "axis lock ratio",
            prop: "terminalAxisLockRatio",
            group: "Terminal",
            tip: "How far ahead one axis of a two-finger motion must be before the terminal commits to it and ignores the other for the rest of the motion. 1.4 = 40% ahead. Fingers never move on one axis alone, and without the lock a vertical read drifts unwrapped output sideways. Lower locks sooner and can pick the wrong axis on a diagonal start; 1 locks on the first event.",
            val: 1.4, from: 1.0, to: 3.0, step: 0.1
        }
    ]

    readonly property var terminalColors: [
        {
            label: "background",
            prop: "terminalBg",
            group: "Terminal surface",
            blurb: "The box the scrollback is drawn in.",
            tip: "Ground of the scrollback box. Its own token rather than the popup's sunk panel: a terminal is a window onto another program, and a theme may want to give it a ground of its own.",
            val: "#E1E4EB"
        },
        {
            label: "foreground",
            prop: "terminalFg",
            group: "Terminal surface",
            tip: "Colour of unstyled output -- most of a run. It is set on the text item itself rather than written into every span, so it is the one terminal colour that DOES follow a live theme switch through existing scrollback.",
            val: "#5D5D5F"
        },
        {
            label: "selection",
            prop: "terminalSelection",
            group: "Terminal surface",
            tip: "Fill behind dragged-over text. kitty selection_background.",
            val: "#A4BEE6"
        },
        {
            label: "selected text",
            prop: "terminalSelectionText",
            group: "Terminal surface",
            tip: "Text colour inside a selection. kitty selection_foreground.",
            val: "#5D5D5F"
        },
        {
            label: "black",
            prop: "ansiBlack",
            group: "ANSI",
            blurb: "The eight base SGR slots, verbatim from ~/.config/kitty/themes/eva*.conf -- so this popup's terminal and a real kitty window colour yay's output identically. A colour is baked into a line when the line is parsed, so an edit here (or a theme switch) applies to output that arrives after it; scrollback keeps the ink it was written in.",
            tip: "SGR 30/40. kitty color0. On the light theme it is the text colour rather than true black, which is what keeps an SGR-30 line legible on a light ground.",
            val: "#5D5D5F"
        },
        {
            label: "red",
            prop: "ansiRed",
            group: "ANSI",
            tip: "SGR 31/41. kitty color1. pacman/yay use it for errors and for a failed hook.",
            val: "#F14C4C"
        },
        {
            label: "green",
            prop: "ansiGreen",
            group: "ANSI",
            tip: "SGR 32/42. kitty color2. yay's ':: ' prefixes and the extra repo.",
            val: "#48D148"
        },
        {
            label: "yellow",
            prop: "ansiYellow",
            group: "ANSI",
            tip: "SGR 33/43. kitty color3. eva's yellow is an amber-orange; it is also the core repo's colour.",
            val: "#FF6D12"
        },
        {
            label: "blue",
            prop: "ansiBlue",
            group: "ANSI",
            tip: "SGR 34/44. kitty color4. Package names and the AUR.",
            val: "#4D91F8"
        },
        {
            label: "magenta",
            prop: "ansiMagenta",
            group: "ANSI",
            tip: "SGR 35/45. kitty color5.",
            val: "#EF8ED8"
        },
        {
            label: "cyan",
            prop: "ansiCyan",
            group: "ANSI",
            tip: "SGR 36/46. kitty color6. The multilib repo.",
            val: "#00D6DE"
        },
        {
            label: "white",
            prop: "ansiWhite",
            group: "ANSI",
            tip: "SGR 37/47. kitty color7. Equal to the foreground on the light theme -- plain white would vanish on it.",
            val: "#5D5D5F"
        },
        {
            label: "bright black",
            prop: "ansiBrightBlack",
            group: "ANSI bright",
            blurb: "The eight high-intensity slots (SGR 90-97 / 100-107). yay uses these for most of its own chrome.",
            tip: "SGR 90/100. kitty color8. What dimmed detail lines are written in.",
            val: "#424242"
        },
        {
            label: "bright red",
            prop: "ansiBrightRed",
            group: "ANSI bright",
            tip: "SGR 91/101. kitty color9.",
            val: "#EC0000"
        },
        {
            label: "bright green",
            prop: "ansiBrightGreen",
            group: "ANSI bright",
            tip: "SGR 92/102. kitty color10. A finished step.",
            val: "#44C145"
        },
        {
            label: "bright yellow",
            prop: "ansiBrightYellow",
            group: "ANSI bright",
            tip: "SGR 93/103. kitty color11. Warnings.",
            val: "#F0AA0B"
        },
        {
            label: "bright blue",
            prop: "ansiBrightBlue",
            group: "ANSI bright",
            tip: "SGR 94/104. kitty color12. The same blue as the popup's accent.",
            val: "#4480F4"
        },
        {
            label: "bright magenta",
            prop: "ansiBrightMagenta",
            group: "ANSI bright",
            tip: "SGR 95/105. kitty color13. Flatpak.",
            val: "#C838C6"
        },
        {
            label: "bright cyan",
            prop: "ansiBrightCyan",
            group: "ANSI bright",
            tip: "SGR 96/106. kitty color14.",
            val: "#00BEC4"
        },
        {
            label: "bright white",
            prop: "ansiBrightWhite",
            group: "ANSI bright",
            tip: "SGR 97/107. kitty color15.",
            val: "#888888"
        }
    ]

    // Category-header inset parameters. Bound straight to the popup, which
    // plumbs them down to ListSectionHeader -> ShadowBox.
    //
    // Width, edge alpha and falloff are three separate controls and it is
    // worth being clear that width and falloff are NOT the same thing: width
    // is how far the shadow reaches inward, falloff is how it decays over
    // that distance. Everything here comes in an idle/under-way pair, and the
    // box moves between the two as a function of PROGRESS, not of time.
    readonly property var headerParams: [
        {
            label: "pad horizontal",
            prop: "headerBoxPadding",
            group: "Header box",
            blurb: "The category header's box: the room between its edge and its text.",
            tip: "Gap between the header box's edge and its text. Has to clear the inset shadow, not just the border \u2014 the inset is several px deep and reads as an edge in its own right, so text laid too close looks like it is falling off the box. Headers no longer share a row's footprint because of this, which is fine: a header is not a row.",
            val: 11,
            from: 0,
            to: 28,
            step: 1
        },
        {
            label: "pad vertical",
            prop: "headerBoxPaddingV",
            group: "Header box",
            tip: "Clearance above the title and below the subtitle, inside the box. Adds to the header's height rather than squeezing the text.",
            val: 8,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "idle width px",
            prop: "headerIdleWidthPx",
            group: "Header inset \u2014 idle",
            blurb: "The category's colour in the header's inset while the category waits: a sliver at the left.",
            tip: "Width of the coloured sliver an idle category shows at the left of its inset, in px (times the view's list scale). Constant in px rather than a fraction of the header, so it is the same mark in the wide normal list and the narrow verbose one \u2014 the old accent stripe's job. Progress sweeps the colour rightward from here.",
            val: 12,
            from: 0,
            to: 40,
            step: 1
        },
        {
            label: "idle feather px",
            prop: "headerIdleFeatherPx",
            group: "Header inset \u2014 idle",
            tip: "Half-width of the crossover from the category colour into the plain grey shadow, in px, while parked. This is the 'tightness' of the idle mark: keep it short so the colour ends decisively rather than looking like a bar stuck at one percent. It is about the colour\u2192grey transition along the edge, NOT about how far the shadow reaches inward.",
            val: 12.0,
            from: 0,
            to: 20,
            step: 0.5
        },
        {
            label: "idle depth",
            prop: "headerIdleWidth",
            group: "Header inset \u2014 idle",
            tip: "How far the inset reaches inward, in px, while parked. Geometry only \u2014 where the shadow STOPS, not how strong it is on the way. Defaults to the same value as the under-way depth: how deep the inset goes is not meant to depend on whether the category is idle.",
            val: 7.5,
            from: 0,
            to: 20,
            step: 0.5
        },
        {
            label: "idle edge alpha",
            prop: "headerIdleEdgeAlpha",
            group: "Header inset \u2014 idle",
            tip: "Strength of the inset at the very edge of the box, 0\u20131, while parked. 1 is the full shadow colour; lower washes it toward the box background without moving where it ends. Same default as under way.",
            val: 0.55,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "idle falloff",
            prop: "headerIdleFalloff",
            group: "Header inset \u2014 idle",
            tip: "Exponent on how the inset decays across its depth, while parked. 1 leaves the easing curve alone; above 1 hugs the edge and clears the middle quickly; below 1 lingers. Same default as under way \u2014 this is NOT the idle tightness, that is the feather.",
            val: 0.9,
            from: 0.3,
            to: 6,
            step: 0.1
        },
        {
            label: "blend end",
            prop: "headerProgressBlendEnd",
            group: "Header inset \u2014 under way",
            blurb: "The same inset once the category is under way, blended in from the idle look by its progress.",
            tip: "Progress (0\u20131) at which the idle look has fully given way to the under-way one. The blend starts the moment the sweep leaves the idle mark. Driven by PROGRESS, never by a clock \u2014 a timed version would still be relaxing after progress had stopped and would lag behind a jump.",
            val: 0.32,
            from: 0.05,
            to: 1,
            step: 0.01
        },
        {
            label: "active feather px",
            prop: "headerActiveFeatherPx",
            group: "Header inset \u2014 under way",
            tip: "Half-width of the colour\u2192grey crossover, in px, once the category is moving. Wider than idle: a hard split on a moving boundary reads as a seam.",
            val: 12,
            from: 0,
            to: 40,
            step: 0.5
        },
        {
            label: "active depth",
            prop: "headerActiveWidth",
            group: "Header inset \u2014 under way",
            tip: "How far the inset reaches inward, in px, once moving. Same default as idle.",
            val: 7,
            from: 0,
            to: 20,
            step: 0.5
        },
        {
            label: "active edge alpha",
            prop: "headerActiveEdgeAlpha",
            group: "Header inset \u2014 under way",
            tip: "Strength at the edge while moving. Same default as idle.",
            val: 1.0,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "active falloff",
            prop: "headerActiveFalloff",
            group: "Header inset \u2014 under way",
            tip: "Decay exponent while moving. Same default as idle.",
            val: 1.0,
            from: 0.3,
            to: 6,
            step: 0.1
        }
    ]

    // List box and favourite-flight parameters, bound to the popup.
    readonly property var listParams: [
        {
            label: "box radius",
            prop: "listBoxRadius",
            group: "List box",
            blurb: "The carved list container: its radius, the rows' inset, the foot's fade, the rows' motion and the wheel's speed.",
            tip: "Corner radius of the carved list container in normal view. Every header box takes the same radius, so the corners read as one curve.",
            val: 14, from: 4, to: 30, step: 1
        },
        {
            label: "box radius compact",
            prop: "listBoxRadiusCompact",
            group: "List box",
            tip: "Radius in verbose view, where the compact headers are a third shorter and the normal radius looked over-round on them.",
            val: 10, from: 2, to: 24, step: 1
        },
        {
            label: "row inset px",
            prop: "listInset",
            group: "List box",
            tip: "Breathing room between the box's carved edge and the rows inside it. Applied to the rows, not the viewport, so a header's own box can still sit flush against the container's edges and share its corner.",
            val: 6, from: 0, to: 20, step: 1
        },
        {
            label: "fade height px",
            prop: "listFadeHeight",
            group: "List box",
            tip: "Height of the dissolve at the foot of the list box, where the lower rows fade into the edge instead of being cut off by it.",
            val: 34, from: 0, to: 80, step: 2
        },
        {
            label: "row anim ms",
            prop: "rowAnimDuration",
            group: "List box",
            tip: "Duration of a row's move or collapse. Shared with the favourite clone, so a row leaving a collapsing list and a clone leaving the screen travel at the same speed.",
            val: 240, from: 60, to: 800, step: 10
        },
        {
            label: "scroll speed",
            prop: "scrollSpeed",
            group: "List box",
            tip: "Wheel step multiplier for the lists, applied to the raw angle delta.",
            val: 1.0, from: 0.2, to: 4.0, step: 0.1
        },
        {
            label: "group by prefix",
            prop: "groupPackages",
            group: "Package groups",
            blurb: "Packages of one category that share a prefix (python-*, haskell-*, lib32-*) fold under an expandable header, one level in. A favourite is pulled out of its group; a group of favourites only sits at the top, as a favourite; a right click on a header favourites (or un-favourites) the whole group. The idle list only: a run lists what the transaction does, package by package.",
            tip: "Off, the list is flat, as it was.",
            val: true
        },
        {
            label: "smallest group",
            prop: "groupMin",
            group: "Package groups",
            tip: "How many packages of one prefix make a group. 3: two would save no row once the header is counted. Counted over every package of the category, favourites included, so starring one never makes a group come or go.",
            val: 3, from: 2, to: 8, step: 1
        },
        {
            label: "indent px",
            prop: "groupIndent",
            group: "Package groups",
            tip: "How far a group's packages step in against the rows beside it, px (before the list's scale).",
            val: 14, from: 0, to: 40, step: 1
        },
        {
            label: "empty-list mark px",
            prop: "archLogoSize",
            group: "Arch mark",
            blurb: "The Arch logo, carved into whatever ground it sits on -- the list container when there is nothing to list, and the terminal's own ground in verbose view.",
            tip: "How wide the mark is in the list container's empty state. It is the mark's own width, not the texture's: the bake leaves a margin around it for the outer bevel, which is drawn past the item.",
            val: 150, from: 60, to: 320, step: 10
        },
        {
            label: "terminal mark px",
            prop: "terminalLogoSize",
            group: "Arch mark",
            tip: "How wide the mark is behind the terminal in verbose view. Bigger than the list's: it is a GROUND there, not an empty state, and output renders over it rather than replacing it.",
            val: 260, from: 80, to: 480, step: 10
        },
        {
            label: "terminal mark contrast",
            prop: "terminalLogoContrast",
            group: "Arch mark",
            tip: "How far the terminal's own ground is pushed toward the theme's rim and shadow to carve the mark into it. 1 is exactly the rim the list container uses; lower sinks the mark further into the terminal's shade. The terminal is a darker shade than the list box, so it cannot borrow the list's tokens outright.",
            val: 1.0, from: 0.0, to: 1.0, step: 0.05
        },
        {
            label: "lift ms",
            prop: "flightLiftMs",
            group: "Favourite flight",
            blurb: "A row starred or unstarred lifts off the list, travels to its new slot and drops in.",
            tip: "The lift: how long the clone takes to rise off the list before it travels.",
            val: 160, from: 40, to: 600, step: 10
        },
        {
            label: "travel ms",
            prop: "flightTravelMs",
            group: "Favourite flight",
            tip: "The travel, constant except for short hops, which scale down so a two-row move is not padded out to the full duration.",
            val: 340, from: 60, to: 1200, step: 10
        },
        {
            label: "land ms",
            prop: "flightLandMs",
            group: "Favourite flight",
            tip: "The drop into the new slot.",
            val: 160, from: 40, to: 600, step: 10
        },
        {
            label: "lift scale",
            prop: "flightLiftScale",
            group: "Favourite flight",
            tip: "How much the clone grows while lifted. With the soft shadow under it, the growth is what reads as height.",
            val: 1.055, from: 1.0, to: 1.3, step: 0.005
        },
        {
            label: "blur max",
            prop: "flightBlurMax",
            group: "Favourite flight",
            tip: "Peak motion blur on the list underneath while it scrolls to bring the destination on screen. 0 disables it.",
            val: 0.55, from: 0, to: 1, step: 0.05
        },
        {
            label: "pre-move delay",
            prop: "flightPreMoveDelayMs",
            group: "Favourite flight",
            tip: "Beat between the lift and the travel, so the lift registers as a step of its own rather than one continuous slide.",
            val: 100, from: 0, to: 500, step: 10
        },
        {
            label: "pre-drop delay",
            prop: "flightPreDropDelayMs",
            group: "Favourite flight",
            tip: "Beat before the clone drops into place.",
            val: 100, from: 0, to: 500, step: 10
        },
        {
            label: "section gap",
            prop: "sectionGap",
            group: "Header flight",
            blurb: "A category changing its place in the list -- AUR taking the lead while it builds, and giving it back -- lifts its header off, travels, and drops it into the new slot while the space migrates underneath.",
            tip: "Space between category sections. A per-section margin rather than the layout's spacing, so a section giving up its slot gives up its gap with it and the swap at the end of a flight is pixel-exact.",
            val: 6, from: 0, to: 24, step: 1
        },
        {
            label: "lift ms",
            prop: "sectionFlightLiftMs",
            group: "Header flight",
            tip: "The lift: how long the header takes to rise off the list before it travels.",
            val: 160, from: 40, to: 600, step: 10
        },
        {
            label: "travel ms",
            prop: "sectionFlightTravelMs",
            group: "Header flight",
            tip: "The travel. A whole section is a heavier object than a row, so it moves a little more deliberately than a favourite does.",
            val: 420, from: 60, to: 1200, step: 10
        },
        {
            label: "land ms",
            prop: "sectionFlightLandMs",
            group: "Header flight",
            tip: "The drop into the new slot.",
            val: 180, from: 40, to: 600, step: 10
        },
        {
            label: "lift scale",
            prop: "sectionFlightLiftScale",
            group: "Header flight",
            tip: "How much the header grows while lifted. Less than a row's: a full-width box magnifies its own edges, so the same factor reads as much more.",
            val: 1.03, from: 1.0, to: 1.3, step: 0.005
        },
        {
            label: "short distance",
            prop: "sectionFlightShortDistance",
            group: "Header flight",
            tip: "Below this distance the travel time scales down, so a one-slot swap is not padded out to the full duration.",
            val: 220, from: 40, to: 800, step: 10
        },
        {
            label: "pre-move ms",
            prop: "sectionFlightPreMoveDelayMs",
            group: "Header flight",
            tip: "Beat after the lift and before the travel, so the lift reads as a distinct step.",
            val: 100, from: 0, to: 500, step: 10
        },
        {
            label: "pre-drop ms",
            prop: "sectionFlightPreDropDelayMs",
            group: "Header flight",
            tip: "Beat before the header drops into place.",
            val: 100, from: 0, to: 500, step: 10
        }
    ]

    // ---- Colours -------------------------------------------------------
    // Hex strings, as the components declare them. `val` is the component's
    // own default, so loading this file changes nothing until a field is
    // edited.
    readonly property var popupColors: [
        {
            label: "surface",
            prop: "surfaceColor",
            group: "Palette",
            blurb: "The eva-light surface set; the rail's own colours are bound to these by the popup.",
            tip: "The popup's background -- painted by the host, which here is the stage behind it -- the outside of every carved box, and the rail's surface.",
            val: "#EAEDF5"
        },
        {
            label: "panel",
            prop: "panelColor",
            group: "Palette",
            tip: "Sunk panels and hover fills (the terminal's backing in verbose view).",
            val: "#E1E4EB"
        },
        {
            label: "bevel",
            prop: "bevelColor",
            group: "Palette",
            tip: "Light upper edge of the status card and the list box.",
            val: "#EEF0F7"
        },
        {
            label: "border",
            prop: "borderColor",
            group: "Palette",
            tip: "Inset borders and divider lines, and the status card's shadow ring.",
            val: "#CED1D7"
        },
        {
            label: "primary text",
            prop: "primaryText",
            group: "Text",
            blurb: "The three inks of the popup's text.",
            tip: "Headline, package names, the rail's step labels.",
            val: "#5D5D5F"
        },
        {
            label: "muted text",
            prop: "mutedText",
            group: "Text",
            tip: "Secondary text: subtitles, counts, the prompt's detail line. Darker than the theme's #8A8A8C to keep 4.5:1 on the surface.",
            val: "#6F6F72"
        },
        {
            label: "faint text",
            prop: "faintText",
            group: "Text",
            tip: "Version numbers and other tertiary text.",
            val: "#8A8A8C"
        },
        {
            label: "accent",
            prop: "accent",
            group: "Accent & states",
            blurb: "The accent and the run's state colours.",
            tip: "The selected pill, links, and the rail's tone while a run is under way (kitty color12).",
            val: "#4480F4"
        },
        {
            label: "accent hover",
            prop: "accentHover",
            group: "Accent & states",
            tip: "Hover state of accented fills (kitty color4).",
            val: "#4D91F8"
        },
        {
            label: "warn strong",
            prop: "warnStrongColor",
            group: "Accent & states",
            tip: "The status line while a run waits on a prompt, and the title of a non-password prompt (kitty color3).",
            val: "#FF6D12"
        },
        {
            label: "ok",
            prop: "okColor",
            group: "Accent & states",
            tip: "A finished run: the status line and the rail's done tone (kitty color10).",
            val: "#44C145"
        },
        {
            label: "error",
            prop: "errColor",
            group: "Accent & states",
            tip: "A failed run: the status line, the error rows' cross, and the rail's error tone (kitty color9).",
            val: "#EC0000"
        },
        {
            label: "error tint",
            prop: "errTint",
            group: "Accent & states",
            tip: "Soft background behind an error row in the run summary.",
            val: "#FDE4E7"
        }
    ]

    readonly property var listColors: [
        {
            label: "list box",
            prop: "listBoxColor",
            group: "List box colour",
            blurb: "The fill the list box, the card's inset and the header boxes stand on.",
            tip: "Fill of the carved list container and of the status card's inset -- and therefore what the prompt's buttons stand on, and what the header boxes stand on.",
            val: "#E6E9F0"
        },
        {
            label: "header box",
            prop: "headerBoxColor",
            group: "Header box colours",
            blurb: "Each category header's carved box. It stands on the list box colour above.",
            tip: "Fill of a header's box, a shade darker than the list it sits in.",
            val: "#DCDFE6"
        },
        {
            label: "header bevel",
            prop: "headerBoxBevelColor",
            group: "Header box colours",
            tip: "The light rim just outside a header box's edge.",
            val: "#EEF0F7"
        },
        {
            label: "header shadow",
            prop: "headerBoxShadowColor",
            group: "Header box colours",
            tip: "Deepest tone of the inset shadow inside a header box's edge; the category colour replaces it as the step progresses.",
            val: "#AAADB4"
        },
        {
            label: "core",
            prop: "repoCoreColor",
            group: "Categories",
            blurb: "Matched to how yay highlights each repo in the terminal, so the list and the scrollback read as the same information.",
            tip: "core repo: amber-orange, kitty color3.",
            val: "#FF6D12"
        },
        {
            label: "extra",
            prop: "repoExtraColor",
            group: "Categories",
            tip: "extra repo: green, kitty color10.",
            val: "#44C145"
        },
        {
            label: "multilib",
            prop: "repoMultilibColor",
            group: "Categories",
            tip: "multilib repo: cyan, kitty color14.",
            val: "#00BEC4"
        },
        {
            label: "aur",
            prop: "aurCategoryColor",
            group: "Categories",
            tip: "AUR packages: blue, kitty color12.",
            val: "#4480F4"
        },
        {
            label: "flatpak",
            prop: "flatpakColor",
            group: "Categories",
            tip: "Flatpak updates: magenta, kitty color13.",
            val: "#C838C6"
        }
    ]

    // The rail's own colour. Everything else it wears comes from the popup's
    // palette (Popup tab): text, muted, faint, accent, done, error, surface,
    // and now the groove's fill, rim and inset, which the rail forwards to
    // GrooveTrack -- that was the last light-theme literal left on the card.
    readonly property var railColors: [
        {
            label: "ball shadow",
            prop: "ballShadowColor",
            group: "Rail colours",
            blurb: "The rail's text, accent, done, error and surface colours follow the popup palette (Popup tab); the groove fill and the ball are darkened and lightened from the run tone (Ball sub-tab).",
            tip: "Colour of the ball's contact shadow. Neutral dark rather than a tint of the run tone, so the ball reads as sitting IN the channel. Its opacity and blur are on the Ball sub-tab.",
            val: "#2A2C31"
        }
    ]

    // =====================================================================
    //  WHAT DRIVES THE POPUP
    // =====================================================================
    // ---- Scripted view switching ------------------------------------------
    // Off unless AUTO_SWITCH is set in the environment, so the mockup is
    // untouched in normal use. With it set: starts the mock run, parks it in
    // the download step, then flips normal <-> verbose every PERIOD_MS while
    // logging the worst frame gap around each switch, and quits. The capture
    // script records this window off the compositor at the same time so a
    // presented black frame can be found instead of described.
    readonly property bool autoSwitch: (Quickshell.env("AUTO_SWITCH") || "") !== ""
    property real _asLastFrame: 0
    property real _asWorstGap: 0
    property int _asBigGaps: 0
    property bool _asArmed: false
    property int _asDone: 0
    FrameAnimation {
        running: win.autoSwitch
        onTriggered: {
            const now = Date.now();
            if (win._asLastFrame > 0 && win._asArmed) {
                const gap = now - win._asLastFrame;
                if (gap > win._asWorstGap)
                    win._asWorstGap = gap;
                if (gap > 40)
                    win._asBigGaps++;
            }
            win._asLastFrame = now;
        }
    }
    Timer {
        interval: 400
        repeat: true
        running: win.autoSwitch && mockRunToggle.checked
        onTriggered: if (mockRun.stepName !== "download")
            mockRun.gotoStep(mockRun.indexOfStep("download"))
    }
    Timer {
        interval: Number(Quickshell.env("PERIOD_MS") || 2500)
        repeat: true
        running: win.autoSwitch
        onTriggered: {
            const total = Number(Quickshell.env("SWITCHES") || 4);
            if (win._asDone === 0 && !mockRunToggle.checked) {
                mockRunToggle.checked = true;
                mockRun.start();
                console.log("SWITCH t0=" + Date.now());
                return;
            }
            if (win._asDone >= total) {
                console.log("SWITCH done");
                Qt.quit();
                return;
            }
            if (win._asArmed)
                console.log("SWITCH #" + win._asDone + " -> " + modeSwitch.mode + " worstGap=" + win._asWorstGap.toFixed(0) + "ms gaps>40ms=" + win._asBigGaps);
            win._asWorstGap = 0;
            win._asBigGaps = 0;
            win._asArmed = true;
            modeSwitch.mode = modeSwitch.mode === "normal" ? "verbose" : "normal";
            win._asDone++;
            console.log("SWITCH at=" + Date.now() + " to=" + modeSwitch.mode);
        }
    }

    // ---- The synthetic run ----
    // Synthetic run for visual review. Drives the popup through every phase
    // with no process and no parsing, so each state can be held still and
    // looked at — a real captured run spends almost all its time in one phase
    // and never shows a failure, an AUR build or kernel work.
    MockUpdateRun {
        id: mockRun
        spec: ({
                core: 9,
                extra: 40,
                multilib: 14,
                aur: 6
            })
        speed: mockSpeed.value
        snapshotStep: mockSnapToggle.checked
        failAtStep: failStep.currentText === "none" ? "" : failStep.currentText
    }

    // The whole run -- the backend and parser that read it, the log rotation, the
    // available updates, the recorder, the askpass pair, and the marker/attach logic
    // of a run that is not ours -- is the SERVICE the bar mounts once per shell
    // (modules/bar/system_update/SystemUpdateService.qml). This mockup hosts it the
    // way the bar does and adds what only a mockup needs: the panel's controls and
    // the arm in front of the real run.
    //
    // `live`: the real run exists here (startUpdate), behind the Run page's
    // "Real run" box and its two-click arm below; every other start is a replay.
    // Under AUTORUN the mockup drives the replay itself and the service neither
    // reattaches nor refreshes on its own.
    SystemUpdateService {
        id: svc
        live: true
        autoStart: Quickshell.env("AUTORUN") !== "1"
        // Skipped during AUTORUN replay (the captured log doesn't actually change the system).
        refreshAfterRun: Quickshell.env("AUTORUN") !== "1"
        // SHEET_GRAB (the cleanup check's picture): the simulated set, never this machine's checkupdates and yay
        mockAvailable: win.sheetGrabPath !== ""
    }

    // -- Helpers driving the popup's startUpdateRequested signal. The real-run
    // toggle decides whether the popup's "Run update" button kicks off the
    // captured-log replay or an actual `yay -Syu`. Real-run requires an extra
    // click on the confirmation strip so we can't invoke pacman by accident.
    property bool realRunArmed: false

    function startReplay() {
        svc.replayDelay = delaySlider.value;
        svc.startReplay();
    }
    function startUpdate() {
        if (realRunToggle.checked) {
            if (!realRunArmed) {
                realRunArmed = true;
                armTimer.restart();
                return;
            }
            realRunArmed = false;
            svc.startUpdate();
        } else {
            startReplay();
        }
    }
    Timer {
        id: armTimer
        interval: 4000
        onTriggered: win.realRunArmed = false
    }

    // Smoke-run auto-start: AUTORUN=1 launches the fastest replay so we can
    // exercise every phase in a short headless run. Mode can be overridden
    // with AUTORUN_MODE=quiet|normal|verbose to test each panel path.
    Component.onCompleted: {
        if (Quickshell.env("AUTORUN") === "1") {
            const m = Quickshell.env("AUTORUN_MODE");
            if (m && m.length > 0)
                modeSwitch.mode = m;
            // Fast path by default so the smoke run completes; prompt-pause
            // is only honoured when delay > 0. Override via AUTORUN_DELAY for
            // a manual prompt-UI exercise.
            svc.replayDelay = Number(Quickshell.env("AUTORUN_DELAY") || 0);
            svc.startReplay();
        }
        // Otherwise the service starts itself (autoStart): a run of ours still
        // going is reattached, else a scan gives the idle panel something to show.
        if (win.mockStart.length > 0)
            mockStartTimer.start();
    }

    // SU_MOCK=<token,...> puts the synthetic run into a state for a render (the grabs): `snapshots` (the mock
    // service), `empty` (it holds no snapshot), `undo`, `step:<name>` (the synthetic run held at that step),
    // `fail:<name>` (a failure injected there), `page` (the snapshots page open), `mode:<quiet|normal|verbose>`.
    readonly property var mockStart: (Quickshell.env("SU_MOCK") || "").split(",").filter(t => t.length > 0)
    Timer {
        id: mockStartTimer
        interval: 250
        onTriggered: {
            for (const t of win.mockStart) {
                if (t === "snapshots") mockSnapToggle.checked = true;
                else if (t === "empty") mockSnapEmpty.checked = true;
                else if (t === "undo") mockRun.undo = true;
                else if (t === "page") popup.secondaryOpen = true;
                else if (t.indexOf("mode:") === 0) modeSwitch.mode = t.substring(5);
            }
            // the combo's model follows the switches above: its index is set once it has
            mockStartLate.start();
        }
    }
    Timer {
        id: mockStartLate
        interval: 300
        onTriggered: {
            let step = "";
            for (const t of win.mockStart) {
                if (t.indexOf("fail:") === 0) failStep.currentIndex = Math.max(0, failStep.model.indexOf(t.substring(5)));
                else if (t.indexOf("step:") === 0) step = t.substring(5);
            }
            if (step.length > 0) {
                mockRunToggle.checked = true;
                mockRun.gotoStep(mockRun.indexOfStep(step));
            }
        }
    }
}
