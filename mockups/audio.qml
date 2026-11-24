pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

import "modules/common/components"
import "modules/common/mockup"
import "modules/audio"
import "modules/audio/data"
import "modules/shell"

// =============================================================================
// mockups/audio.qml -- the audio popup on the mockup framework: the real AudioPopup and the real AudioService on AudioWorld, a sound system that does not exist. The
// Faults tab breaks it every way the brief names: a hung pactl, a dead server, a move or a port or a profile that is refused or silently ignored, a device that vanishes
// under the hand. Nothing here reaches PipeWire, and nothing is heard.
//
// GRAB=<png>, AUDIO_SECTION=<tab>, AUDIO_FAULT=<hang|dead|paused|...>: a state to grab.
// =============================================================================
MockupWindow {
    id: win

    moduleId: "audio"
    title: "Audio mockup"
    content: popup
    target: popup.style
    lists: ({
            popupParams: win.popupParams,
            rowParams: win.rowParams,
            levelParams: win.levelParams,
            lineParams: win.lineParams,
            styleColors: win.styleColors
        })
    tabDefs: [
        { name: "Run", page: scenePage },
        { name: "Faults", page: faultsPage },
        { name: "Popup", lists: ["popupParams"] },
        { name: "Rows", lists: ["rowParams"] },
        { name: "Level", lists: ["levelParams"] },
        { name: "Lines", subs: [
            { name: "Bay", lists: ["lineParams"], groups: ["Bay", "Gap"] },
            { name: "Rail", lists: ["lineParams"], groups: ["Rail"] },
            { name: "Waves", lists: ["lineParams"], groups: ["Sine", "Layers"] },
            { name: "Colours", lists: ["styleColors"] }
        ] }
    ]

    AudioMock {
        id: mock
        popupOpen: true
        // SHEET_GRAB (the cleanup check's picture): the lines and the balls follow a level clock of their own, so the meters stay off
        settings: win.sheetGrabPath !== "" ? ({ meters: false }) : ({})
    }
    // The shell's one volume step, on the mock.
    VolumeParity {
        id: pill
        visible: false
        pipewire: mock.world
    }

    AudioPopup {
        id: popup
        service: mock
        parity: pill
        fontFamily: "Audiowide"
    }

    // A grab's state: a move that did not take, with its note on the row.
    Timer {
        id: demoNote
        interval: 900
        onTriggered: {
            mock.world.ignoreMove = true;
            const r = mock.rows.playback[0];
            mock.moveStream(r, mock.rows.sinks.filter(d => d.name !== r.device)[0].name);
        }
    }

    Component.onCompleted: {
        const s = Quickshell.env("AUDIO_SECTION");
        if (s)
            popup.section = s;
        const f = Quickshell.env("AUDIO_FAULT");
        if (f === "paused")
            mock.world.setPaused(true);
        else if (f === "vanish")
            mock.world.removeDevice(mock.world.trackedAudioNodes[1].name);
        else if (f === "nodeerror")
            mock.world.setNodeError(mock.world.trackedAudioNodes[1].name, "set_hw_params: Connection timed out");
        else if (f === "didnottake")
            demoNote.start();
        else if (f)
            mock.world[f] = true;
    }

    pages: [
        MockupPage {
            id: faultsPage

            TipGroup {
                title: "The server"
                blurb: "What the popup says when the backend is not well. Every call has a deadline; the banner says what it knows."
            }
            component Fault: TipRow {
                id: fr
                required property string fault
                required property string name
                Layout.fillWidth: true
                Switch {
                    checked: mock.world[fr.fault] === true
                    onToggled: mock.world[fr.fault] = checked
                }
                Label {
                    text: fr.name
                    color: "#6F6F72"
                    font.family: "Audiowide"
                    Layout.fillWidth: true
                }
            }
            Fault { fault: "hang"; name: "pactl hangs"; tip: "Every call stays unanswered: the user's locked USB DAC. The deadline ends it, the banner says what WirePlumber is doing." }
            Fault { fault: "dead"; name: "server dead"; tip: "Connection refused on every call; the binding goes down." }
            Fault { fault: "missing"; name: "pactl not installed"; tip: "exit 127." }
            TipGroup {
                title: "A change that does not take"
                blurb: "`ignore`: the call succeeds and nothing happens, which only reading it back can catch. `refuse`: the call fails."
            }
            Fault { fault: "ignoreMove"; name: "a move is ignored"; tip: "pactl exits 0 and the stream stays where it was." }
            Fault { fault: "refuseMove"; name: "a move is refused"; tip: "pactl: No such entity." }
            Fault { fault: "ignorePort"; name: "a port is ignored"; tip: "pactl exits 0 and the port stays." }
            Fault { fault: "refusePort"; name: "a port is refused"; tip: "pactl: No such entity." }
            Fault { fault: "ignoreProfile"; name: "a profile is ignored"; tip: "pactl exits 0 and the profile stays." }
            Fault { fault: "refuseProfile"; name: "a profile is refused"; tip: "pactl: No such entity." }
            Fault { fault: "ignoreVolume"; name: "a volume is swallowed"; tip: "The node never shows the write." }
            Fault { fault: "ignoreDefault"; name: "the default stays"; tip: "The session manager keeps the old default." }
            Fault { fault: "toneElsewhere"; name: "the tone lands elsewhere"; tip: "The tone's link goes to the first output, whatever was asked." }
            TipRow {
                tip: "How late every answer comes. A device takes tens of ms; a read-back has to survive it."
                Layout.fillWidth: true
                Label {
                    text: "answers after " + mock.world.ackMs + " ms"
                    color: "#6F6F72"
                    font.family: "Audiowide"
                }
                Slider {
                    from: 1
                    to: 1500
                    stepSize: 1
                    value: mock.world.ackMs
                    onMoved: mock.world.ackMs = value
                    Layout.fillWidth: true
                }
            }
        },
        MockupPage {
            id: scenePage

            TipGroup {
                title: "What happens under the hand"
                blurb: "Things the popup does not ask for."
            }
            TipRow {
                tip: "Pull the second output out: its streams fall back to the first."
                Layout.fillWidth: true
                Button {
                    text: "Unplug the DAC"
                    onClicked: mock.world.removeDevice(mock.world._sinks[1].name)
                }
            }
            TipRow {
                tip: "The node goes into error, what pw-dump reports for a locked USB device."
                Layout.fillWidth: true
                Button {
                    text: "Node error"
                    onClicked: mock.world.setNodeError(mock.world._sinks[1].name, "set_hw_params: Connection timed out")
                }
                Button {
                    text: "Clear"
                    onClicked: mock.world.setNodeError(mock.world._sinks[1].name, "")
                }
            }
            TipRow {
                tip: "A new stream starts."
                Layout.fillWidth: true
                Button {
                    text: "New stream"
                    onClicked: mock.world.addStream("Spotify", "Track " + Date.now() % 100, mock.world._sinks[0].name, 0.5)
                }
            }
            TipRow {
                tip: "A pause, what YouTube's pause button does: the sound stops at the source and the last of it runs down the line. Off again, it runs out the same way."
                Layout.fillWidth: true
                Switch {
                    id: pauseAll
                    onToggled: mock.world.setPaused(checked)
                }
                Label {
                    text: "streams paused"
                    color: "#6F6F72"
                    font.family: "Audiowide"
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Puts every stream at this level, what the glow and the lines read."
                Layout.fillWidth: true
                Label {
                    text: "level"
                    color: "#6F6F72"
                    font.family: "Audiowide"
                }
                Slider {
                    from: 0
                    to: 1
                    value: 0.5
                    onMoved: {
                        for (const n of mock.world.trackedAudioNodes)
                            if (n.isStream)
                                n.level = value;
                    }
                    Layout.fillWidth: true
                }
            }
        }
    ]

    readonly property var popupParams: [
        { label: "popup width", prop: "popupWidth", group: "Popup", blurb: "The popup's frame: its width, the list box, the padding and the tab row.", tip: "The popup's width. The list has what the devices' box and the gap leave.", val: 720, from: 560, to: 860, step: 2 },
        { label: "list height", prop: "listHeight", group: "Popup", tip: "The list box. 430 shows five rows without scrolling.", val: 430, from: 280, to: 600, step: 2 },
        { label: "padding", prop: "padding", group: "Popup", tip: "The shell's one padding: around the popup and between its parts.", val: 12, from: 8, to: 20, step: 1 },
        { label: "tab row height", prop: "tabsHeight", group: "Popup", tip: "The tab selector, as on the network popup.", val: 32, from: 26, to: 40, step: 1 },
        { label: "foot height", prop: "footHeight", group: "Popup", tip: "The line under the list: the Show filter and what the service has to say.", val: 28, from: 22, to: 40, step: 1 },
        { label: "list radius", prop: "listRadius", group: "Popup", tip: "The carved list box's corner: 14, the shell's container radius.", val: 14, from: 6, to: 20, step: 1 },
        { label: "fade ms", prop: "fadeMs", group: "Motion", blurb: "The popup's clocks: presence, resizes, the tab's entrance and the default's marker.", tip: "Presence: a row coming or going, the banner. The shell's 160.", val: 160, from: 60, to: 320, step: 10 },
        { label: "resize ms", prop: "resizeMs", group: "Motion", tip: "A row growing under a note, the banner opening. The shell's 260.", val: 260, from: 100, to: 500, step: 10 },
        { label: "entrance stagger ms", prop: "enterStaggerMs", group: "Motion", tip: "A tab's rows fly in one after the other, the network popup's list. Those past the fold are placed.", val: 55, from: 0, to: 120, step: 1 },
        { label: "marker travel ms", prop: "travelMs", group: "Motion", tip: "The one clock of the default's ball and a stream's line when it moves.", val: 420, from: 120, to: 900, step: 10 },
    ]
    readonly property var rowParams: [
        { label: "row padding", prop: "rowPadding", group: "Row", blurb: "One stream's or device's row in the list box.", tip: "Inside a row.", val: 8, from: 4, to: 16, step: 1 },
        { label: "row gap", prop: "rowGap", group: "Row", tip: "Between two rows and to the box's edge.", val: 6, from: 2, to: 14, step: 1 },
        { label: "row radius", prop: "rowRadius", group: "Row", tip: "A row's corner: 10, the compact container radius.", val: 10, from: 4, to: 16, step: 1 },
        { label: "title size", prop: "titleSize", group: "Type", blurb: "The sizes of a row's words and figures.", tip: "An app's or a device's name. The shell's body size.", val: 12, from: 10, to: 14, step: 1 },
        { label: "subtitle size", prop: "subtitleSize", group: "Type", tip: "A stream's title, a channel's name, a state word.", val: 11, from: 9, to: 13, step: 1 },
        { label: "figure size", prop: "figureSize", group: "Type", tip: "The percent and dB figures.", val: 11, from: 9, to: 13, step: 1 },
        { label: "note size", prop: "noteSize", group: "Type", tip: "The sentence under a row when a change did not take.", val: 11, from: 9, to: 13, step: 1 },
        { label: "glyph size", prop: "glyphSize", group: "Type", tip: "The row's device or app glyph.", val: 15, from: 12, to: 20, step: 1 },
        { label: "slider scale", prop: "sliderScale", group: "Slider", blurb: "The volume slider inside a row (GrooveSlider) and its figures' slot.", tip: "GrooveSlider.sizeScale: 0.72 keeps a row to about 72 px.", val: 0.72, from: 0.5, to: 1.4, step: 0.02 },
        { label: "ball", prop: "sliderBall", group: "Slider", tip: "The slider's ball before the scale.", val: 12, from: 8, to: 18, step: 1 },
        { label: "edge padding", prop: "sliderEdge", group: "Slider", tip: "Room at the groove's ends.", val: 6, from: 0, to: 18, step: 1 },
        { label: "figure slot", prop: "figureWidth", group: "Slider", tip: "The fixed slot for \"100 %  -60.0 dB\": figures never jitter.", val: 104, from: 70, to: 140, step: 1 },
        { label: "channel label", prop: "channelLabelWidth", group: "Slider", tip: "The slot for a channel's name when the channels are unlocked.", val: 74, from: 40, to: 110, step: 1 },
        { label: "wheel rest ms", prop: "sliderRestMs", group: "Slider", tip: "Where the list can scroll: how long the pointer rests on a slider before the wheel is the slider's. A scroll never reaches a volume by accident.", val: 450, from: 100, to: 1200, step: 10 },
        { label: "offset step ms", prop: "offsetStepMs", group: "Latency offset", blurb: "The device's latency offset control.", tip: "One click of the latency offset. pavucontrol's spin step is 10.", val: 10, from: 1, to: 50, step: 1 },
    ]
    readonly property var levelParams: [
        { label: "glow on", prop: "glowEnabled", group: "Glow", blurb: "The rows' level glow: one beat for every meter and line, quiet when nothing sounds.", tip: "The level glow in the rows. Off: no capture stream is opened at all, whatever the tab.", val: true },
        { label: "beat ms", prop: "levelBeatMs", group: "Glow", tip: "One beat for every meter and line. 33 is 30 Hz, so the waves flow; each change is a whole-window frame, so more is not free. Silence stops it.", val: 33, from: 16, to: 200, step: 1 },
        { label: "floor", prop: "levelFloor", group: "Glow", tip: "A peak under this is silence: a noise floor must not cost frames.", val: 0.02, from: 0, to: 0.2, step: 0.005 },
        { label: "steps", prop: "levelSteps", group: "Glow", tip: "The glow moves in this many whole steps; a level that barely moves draws nothing.", val: 12, from: 4, to: 48, step: 1 },
        { label: "decay", prop: "levelDecay", group: "Glow", tip: "Per beat, how far a peak falls back. Attack is instant.", val: 0.85, from: 0.3, to: 0.98, step: 0.01 },
        { label: "curve", prop: "glowCurve", group: "Glow", tip: "The exponent on the peak: under 1 lifts a quiet signal into view.", val: 0.55, from: 0.2, to: 1.5, step: 0.01 },
        { label: "strength", prop: "glowMax", group: "Glow", tip: "How far the row's inset goes towards the accent at full level.", val: 0.9, from: 0.2, to: 1, step: 0.01 },
    ]
    readonly property var lineParams: [
        { label: "lines on", prop: "linesEnabled", group: "Bay", blurb: "The patch bay: the devices' box beside the list and its sockets, and each line's plug on its row and ball at its device.", tip: "The patch lines and sockets. Off: the Playback and Recording lists take the whole width.", val: true },
        { label: "devices' box", prop: "socketColumn", group: "Bay", tip: "The devices' box beside the list: the room their names need, always.", val: 210, from: 150, to: 280, step: 2 },
        { label: "socket pitch", prop: "socketPitch", group: "Bay", tip: "From one socket to the next. The rows' own, so socket N stands beside row N; they close up when they would not fit.", val: 78, from: 44, to: 110, step: 1 },
        { label: "line ball", prop: "ballSize", group: "Bay", tip: "The ball at a line's device end: drag it to another socket, click it for the list.", val: 10, from: 6, to: 16, step: 1 },
        { label: "plug", prop: "portSize", group: "Bay", tip: "The dot a line starts from, on the row.", val: 7, from: 3, to: 12, step: 1 },
        { label: "gap, no streams", prop: "gapNone", group: "Gap", blurb: "The room between the list and the devices' box, which widens while a stream sounds.", tip: "Between the boxes with no line to draw: the shell's padding.", val: 12, from: 0, to: 40, step: 1 },
        { label: "gap, calm", prop: "gapIdle", group: "Gap", tip: "With calm lines lying in it: wide enough for an S, and the list keeps the room.", val: 34, from: 12, to: 80, step: 1 },
        { label: "gap, sounding", prop: "gapSounding", group: "Gap", tip: "While a stream sounds: the room the waves live in, taken from the list on one clock.", val: 104, from: 40, to: 180, step: 1 },
        { label: "gap hold ms", prop: "gapHoldMs", group: "Gap", tip: "How long the room stays after the last of the sound has landed: a pause between two songs moves nothing.", val: 1400, from: 0, to: 6000, step: 100 },
        { label: "rail column", prop: "railWidth", group: "Rail", blurb: "The default device's groove: its slots and the ball seated in one.", tip: "The column the default's groove stands in.", val: 16, from: 10, to: 24, step: 1 },
        { label: "rail line", prop: "railLine", group: "Rail", tip: "The groove between two slots.", val: 4, from: 2, to: 8, step: 1 },
        { label: "slot", prop: "railDot", group: "Rail", tip: "A slot, at each place the ball can rest.", val: 12, from: 8, to: 18, step: 1 },
        { label: "rail ball", prop: "railBall", group: "Rail", tip: "The default's ball, seated in its slot.", val: 8, from: 4, to: 14, step: 1 },
        { label: "ball settle", prop: "railSettle", group: "Rail", tip: "How far the ball runs past its slot before it settles, as a share of its way (2.5 px at most). 0: it stops dead.", val: 0.05, from: 0, to: 0.1, step: 0.01 },
        { label: "step px", prop: "lineStep", group: "Sine", blurb: "The waves on a sounding line: their length, depth and how fast the sound runs down it.", tip: "Points of a line. 4 px is smooth at 1x and costs a quarter of the old picker's 2 px... per line, per layer.", val: 4, from: 2, to: 8, step: 1 },
        { label: "wavelength", prop: "lineWavelength", group: "Sine", tip: "The broad layer's wave, px. The waves keep their length while the gap breathes.", val: 46, from: 16, to: 90, step: 1 },
        { label: "depth", prop: "lineAmp", group: "Sine", tip: "The deepest sine in px, at full level. The old picker's broad layer was 12 on a 300 px run.", val: 9, from: 0, to: 20, step: 0.5 },
        { label: "speed", prop: "lineSpeed", group: "Sine", tip: "How fast the sound runs down the line, px/s: the waves' flow, and how long a stop takes to reach the device.", val: 70, from: 20, to: 200, step: 1 },
        { label: "rise", prop: "lineRise", group: "Sine", tip: "Per beat, how far a line's level goes towards a louder sound: the waves swell instead of snapping.", val: 0.3, from: 0.05, to: 1, step: 0.01 },
        { label: "fall", prop: "lineDecay", group: "Sine", tip: "Per beat, what is left of it after a quieter one: how softly a stop tapers along the line.", val: 0.92, from: 0.5, to: 0.99, step: 0.01 },
        { label: "colour gain", prop: "lineColorGain", group: "Sine", tip: "How fast a quiet sound takes the line's colour.", val: 3, from: 1, to: 8, step: 0.1 },
        { label: "calm alpha", prop: "lineCalmAlpha", group: "Layers", blurb: "The three sines a line is drawn as, broad and faint to thin and clear, and how a calm or a dimmed line shows.", tip: "The thin line on a silent stream.", val: 0.8, from: 0.1, to: 1, step: 0.01 },
        { label: "dim", prop: "lineDim", group: "Layers", tip: "The other lines, while the pointer is on one row or socket.", val: 0.3, from: 0, to: 1, step: 0.01 },
        { label: "broad width", prop: "lineThickA", group: "Layers", tip: "The broad, faint sine.", val: 6, from: 1, to: 12, step: 0.5 },
        { label: "mid width", prop: "lineThickB", group: "Layers", tip: "The mid sine.", val: 3.2, from: 1, to: 8, step: 0.1 },
        { label: "thin width", prop: "lineThickC", group: "Layers", tip: "The thin, clear sine.", val: 1.5, from: 0.5, to: 4, step: 0.1 },
        { label: "broad alpha", prop: "lineAlphaA", group: "Layers", tip: "The broad alpha.", val: 0.16, from: 0, to: 1, step: 0.01 },
        { label: "mid alpha", prop: "lineAlphaB", group: "Layers", tip: "The mid alpha.", val: 0.34, from: 0, to: 1, step: 0.01 },
        { label: "thin alpha", prop: "lineAlphaC", group: "Layers", tip: "The thin alpha.", val: 0.95, from: 0, to: 1, step: 0.01 },
    ]
    readonly property var styleColors: [
        { label: "line", prop: "lineColor", group: "Lines", blurb: "The patch lines' colours, and what a row's inset glows with.", tip: "A line where the sound is.", val: "@accent" },
        { label: "quiet line", prop: "lineIdleColor", group: "Lines", tip: "A line where it is not.", val: "@textFaint" },
        { label: "glow", prop: "glowColor", group: "Lines", tip: "What a row's inset takes on at level.", val: "@accent" },
        { label: "note", prop: "noteColor", group: "Rows", blurb: "The rows' own colour: the note under a change that did not take.", tip: "The sentence that says a change did not take.", val: "@errorStrong" },
    ]
}
