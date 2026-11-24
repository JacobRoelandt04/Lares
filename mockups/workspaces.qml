pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

import "modules/bar/workspaces"
import "modules/clock"
import "modules/clock/data"
import "modules/common/mockup"

// =============================================================================
// mockups/workspaces.qml -- the workspaces groove of the bar's centre island, with the clock in its slot.
//
// The stage is the groove as the shell mounts it (ShellFrame): its width 2 x pitch + 64 + 100 x scale, the side
// tracks, the clock's slot and the gaps worked out from the same two shell.jsonc numbers (`workspacesScale`,
// `workspacesPitch`; the Run tab's Stage group moves them), and the real ClockBarButton standing in the slot. Nothing
// reaches Hyprland: the workspaces are a stand-in list, and a click on a dot (or a swipe along the groove) lands on
// that list instead of on `hl.dsp.focus`. Hovering the clock brings its seconds in, and the dots move out for them.
//
// The panel tunes what the shell leaves at Workspaces' own defaults (the line, the dots, the ball, the carve, the
// motion, the sparks, the colours); the timers' fills on the groove are tuned on the clock mockup's Bar tab. Save
// writes Workspaces' declarations.
//
//   quickshell -p mockups/workspaces.qml
// =============================================================================
MockupWindow {
    id: win

    moduleId: "workspaces"
    title: "Workspaces mockup"
    stageLabel: "Workspaces + the clock, as the centre island carries them"
    content: island
    target: ws
    zoom: 2.5

    lists: ({
            grooveParams: win.grooveParams,
            grooveColors: win.grooveColors
        })

    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        {
            name: "Groove",
            subs: [
                {
                    name: "Shape",
                    lists: ["grooveParams"],
                    groups: ["Line", "Carve", "Ball shadow", "Motion"]
                },
                {
                    name: "Sparks",
                    lists: ["grooveParams"],
                    groups: ["Sparks", "Bloom", "Burst"]
                },
                {
                    name: "Colours",
                    lists: ["grooveColors"]
                }
            ]
        }
    ]

    // ---- the stand-ins: Hyprland's workspaces and the shell's frame numbers --------
    QtObject {
        id: stand
        // shell.jsonc's workspacesScale and workspacesPitch, at their defaults
        property real k: Number(Quickshell.env("BREAKS_K") || 0.9)
        property int pitch: 30
        property int active: 1
        property var extra: []
        property real lockMerge: 0
        property real lockSpread: 0
        property string lastSend: "(none)"
        // The break nudge's inputs and a stand-in timer (the clock mockup has the real ones).
        property real durationMin: 50
        property real pauseMin: 5
        property real graceSec: 30
        property real rewindPower: 2
        property real stepSec: 60
        property real easeMs: 700
        property real hiddenMin: 10
        property bool idle: false
        property bool locked: false
        property var timerFills: []
        property string lastBreak: "(none)"
        function log(t) { stand.lastBreak = t; }
        function startTimer(sec) {
            const n = bClock.now();
            stand.timerFills = [{ piece: -1, tone: 0, from: 0, to0: 0, to1: 1, t0: n, t1: n + sec * 1000 }];
            timerEnd.interval = Math.max(1, Math.ceil(sec * 1000 / bClock.scale));
            timerEnd.restart();
            stand.log("timer " + sec + " s started");
        }
        function clearTimer() { timerEnd.stop(); stand.timerFills = []; }
        // An idle span of `min` clock-minutes: the monitor fires after the grace, input returns at the end.
        function idleFor(min) {
            idleOn.interval = Math.max(1, Math.ceil(bClock.realDelay(stand.graceSec * 1000)));
            idleOff.interval = Math.max(1, Math.ceil(bClock.realDelay(min * 60000)));
            idleOn.restart();
            idleOff.restart();
            stand.log("idle " + min + " min: rewinds " + Math.round(bm.rewindShare(min * 60) * 100) + " % of the rail");
        }
        // What a click or a swipe sends (`hl.dsp.focus({ workspace = N })`), answered here instead of by Hyprland.
        function send(lua: string): void {
            stand.lastSend = lua;
            const m = /workspace = (\d+)/.exec(lua);
            if (m)
                stand.active = Number(m[1]);
        }
    }

    // BREAKS_STATE=<p0|p50|p99|full|timer|timerend|reveal|step|rewind> (reveal, step and rewind are eased moves: grab ~350 ms into them with GRAB_MS; BREAKS_K scales the rail)
    // BREAKS_STATE=<p0|p50|p99|full|timer|timerend> puts the stage in a state for a grab (BREAKS_STATE alone does nothing else).
    Timer {
        interval: 400
        running: !!Quickshell.env("BREAKS_STATE")
        onTriggered: {
            const st = Quickshell.env("BREAKS_STATE");
            if (st === "p0") bm.seek(0);
            else if (st === "p50") bm.seek(0.5);
            else if (st === "p99") bm.seek(0.99);
            else if (st === "full") bm.seek(1);
            else if (st === "timer") { bm.seek(0.7); const n = bClock.now(); stand.timerFills = [{ piece: -1, tone: 0, from: 0, to0: 0.4, to1: 0.4, t0: n, t1: n }]; }
            else if (st === "timerend") { stand.startTimer(1.5); }
            else if (st === "reveal") bm.seek(0.3);                 // out of the hidden zone: the head eases in from the rail's start
            else if (st === "step" || st === "rewind") { bm.seek(0.5); stage2.start(); }
        }
    }
    // The second move of a sheet state: one more beat's step, or an idle span of 3 minutes (rewinds 0.3086 of the rail).
    Timer {
        id: stage2
        interval: 1500
        repeat: false
        onTriggered: {
            if (Quickshell.env("BREAKS_STATE") === "step") {
                bm.seek(0.52);
            } else {
                stand.idle = true;
                bClock.jump(150000);
                stand.idle = false;
            }
        }
    }

    // ---- the break nudge, on a clock the panel can run faster ---------------------------
    // The shell has the singleton BreakClock (IdleMonitor, Sleep, breaks.jsonc); here the same rules (BreakModel) run on a
    // TimerClock, and the buttons below stand in for what the machine would say (input, a pause, a resume, a timer).
    TimerClock {
        id: bClock
    }
    Timer {
        id: idleOn
        repeat: false
        onTriggered: stand.idle = true
    }
    Timer {
        id: idleOff
        repeat: false
        onTriggered: stand.idle = false
    }
    BreakModel {
        id: bm
        clock: bClock
        durationS: stand.durationMin * 60
        pauseS: stand.pauseMin * 60
        graceS: stand.graceSec
        rewindPower: stand.rewindPower
        stepS: stand.stepSec
        easeMs: stand.easeMs
        hiddenS: stand.hiddenMin * 60
        idle: stand.idle
        locked: stand.locked
        onFilled: stand.log("break nudge: full -> burst")
    }

    // ---- the drop-in content: the island's groove and its clock --------------------
    Item {
        id: island

        readonly property real pad: 12
        implicitWidth: Math.round(2 * stand.pitch + 64 + 100 * stand.k) + 2 * island.pad
        implicitHeight: 40

        Workspaces {
            id: ws
            x: island.pad
            y: 0
            width: island.width - 2 * island.pad
            height: island.height
            // ShellFrame's lines, from the same two numbers
            sizeScale: stand.k
            trackSeparation: (10 + 5 * stand.k) / stand.k
            clockSize: 80 / stand.k
            clockExtra: clockButton.extraWidth / stand.k
            clockCross: 18 / stand.k
            clockGap: 16 / stand.k
            splitOffset: 0
            edgePadding: 10
            showClock: true
            allWorkspaces: stand.extra
            activeWorkspaceId: stand.active
            dispatcher: lua => stand.send(lua)
            lockMerge: stand.lockMerge
            lockSpread: stand.lockSpread
            fills: stand.timerFills
            fillClock: bClock
            breakSource: bm
        }
        Timer {
            id: timerEnd
            repeat: false
            onTriggered: {
                ws.burst(-1, 0);
                stand.log("timer ended -> the same burst");
                timerClear.restart();
            }
        }
        Timer {
            id: timerClear
            interval: 2500
            onTriggered: stand.timerFills = []
        }
        ClockBarButton {
            id: clockButton
            x: ws.x + ws.clockSlot.x
            y: ws.y + ws.clockSlot.y
            width: ws.clockSlot.width
            height: ws.clockSlot.height
            fontFamily: "Audiowide"
            horizontalPixelSize: 13
        }
    }

    // =====================================================================
    //  THE RUN PAGE
    // =====================================================================
    pages: [
        MockupPage {
            id: runPage

            TipGroup {
                title: "Scenarios"
                blurb: "What Hyprland would say: the workspace this bar's monitor shows, and the workspaces that exist past the four the groove always shows."
            }
            TipRow {
                tip: "The active workspace: the ball travels there, through the side track when it crosses the clock. A click on a dot or a swipe along the groove does the same through the stand-in."
                Layout.fillWidth: true
                spacing: 6
                Label {
                    text: "active"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Repeater {
                    model: ws.workspaceList
                    delegate: Button {
                        required property var modelData
                        text: String(modelData.id)
                        checkable: true
                        checked: stand.active === modelData.id
                        onClicked: stand.active = modelData.id
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Workspaces 5 and 6 opened: a dot each, the groove re-spread over them. The four of `workspaceIds` always stand, so the layout does not jump as Hyprland creates and destroys empty ones."
                Layout.fillWidth: true
                CheckBox {
                    text: "workspaces 5 and 6"
                    checked: stand.extra.length > 0
                    onToggled: {
                        stand.extra = checked ? [{ id: 5 }, { id: 6 }] : [];
                        if (!checked && stand.active > 4)
                            stand.active = 1;
                    }
                }
            }
            TipRow {
                tip: "The lock's eye: while the session locks, the two tracks converge into one over the clock (merge) and the dots gather toward it (spread). The shell drives both from the lock's own clock."
                Layout.fillWidth: true
                Label {
                    text: "lock merge"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Slider {
                    Layout.fillWidth: true
                    from: 0
                    to: 1
                    stepSize: 0.01
                    value: stand.lockMerge
                    onMoved: stand.lockMerge = value
                }
                Label {
                    text: "spread"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Slider {
                    Layout.fillWidth: true
                    from: 0
                    to: 1
                    stepSize: 0.01
                    value: stand.lockSpread
                    onMoved: stand.lockSpread = value
                }
            }

            TipGroup {
                title: "Break nudge"
                blurb: "The rail slowly fills while you keep using the system (hidden for the first minutes, one eased step a beat); idle, lock and suspend rewind it on a convex curve; full plays the burst. Timers fill over it. Time here is a TimerClock: speed it up or jump the fill. Nothing reaches the machine."
            }
            TipRow {
                tip: "Jump the break fill to this share of the way, as if you had been at the system that long without a pause. 0 starts it again from now; 100 % is full: the burst plays once."
                Layout.fillWidth: true
                Repeater {
                    model: [0, 25, 50, 99, 100]
                    delegate: Button {
                        required property int modelData
                        text: modelData + " %"
                        onClicked: bm.seek(modelData / 100)
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "How fast the mockup's clock runs (the break fill and a timer share it): 1x is real time, 600x makes the 50 minutes pass in 5 seconds."
                Layout.fillWidth: true
                Label {
                    text: "clock"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Repeater {
                    model: [1, 10, 60, 300, 600]
                    delegate: Button {
                        required property int modelData
                        text: modelData + "x"
                        checkable: true
                        checked: bClock.scale === modelData
                        onClicked: bClock.scale = modelData
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "An idle span (no input): the monitor fires after the grace, input returns after the chosen minutes, and the rail is rewound by the curve (the log line says how much). 'Lock' holds the session locked: locked time is an idle span too. A suspend is one through 'resume' (a span from the last accounting to now)."
                Layout.fillWidth: true
                Repeater {
                    model: [1, 3, 5]
                    delegate: Button {
                        required property int modelData
                        text: "idle " + modelData + " min"
                        onClicked: stand.idleFor(modelData)
                    }
                }
                CheckBox {
                    text: "locked"
                    checked: stand.locked
                    onToggled: stand.locked = checked
                }
                Button {
                    text: "resume from suspend"
                    onClicked: {
                        bm.resume();
                        stand.log("resumed: the gap since the last accounting was an idle span");
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "A stand-in timer filling the whole rail (tone 0, like a countdown). It draws over the break fill; when it ends the same burst plays. The short one ends in 4 clock-seconds."
                Layout.fillWidth: true
                Button {
                    text: "timer 4 s"
                    onClicked: stand.startTimer(4)
                }
                Button {
                    text: "timer 15 min"
                    onClicked: stand.startTimer(900)
                }
                Button {
                    text: "clear timer"
                    onClicked: stand.clearTimer()
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "breaks.jsonc durationMin: minutes of use until the rail is full (default 50). Longer is calmer; the beat and the hidden zone scale with it."
                Layout.fillWidth: true
                Label {
                    text: "full after"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Slider {
                    Layout.fillWidth: true
                    from: 1
                    to: 120
                    stepSize: 1
                    value: stand.durationMin
                    onMoved: stand.durationMin = value
                }
                Label {
                    text: stand.durationMin + " min"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
            }
            TipRow {
                tip: "breaks.jsonc pauseMin: an idle span this long (idle, lock or suspend) empties even a full rail (default 5 min). It sets the curve's end."
                Layout.fillWidth: true
                Label {
                    text: "pause"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Slider {
                    Layout.fillWidth: true
                    from: 1
                    to: 60
                    stepSize: 1
                    value: stand.pauseMin
                    onMoved: stand.pauseMin = value
                }
                Label {
                    text: stand.pauseMin + " min"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
            }
            TipRow {
                tip: "breaks.jsonc idleGraceSec: an idle shorter than this is use and rewinds nothing; it is also the idle monitor's timeout (default 30 s)."
                Layout.fillWidth: true
                Label {
                    text: "grace"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Slider {
                    Layout.fillWidth: true
                    from: 5
                    to: 120
                    stepSize: 5
                    value: stand.graceSec
                    onMoved: stand.graceSec = value
                }
                Label {
                    text: stand.graceSec + " s"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
            }
            TipRow {
                tip: "breaks.jsonc rewindPower: how convex the rewind is. 1 is linear in the idle time; 2 (default) makes small idles cost little and the cost grow the more idle you are."
                Layout.fillWidth: true
                Label {
                    text: "curve"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Slider {
                    Layout.fillWidth: true
                    from: 1
                    to: 4
                    stepSize: 0.25
                    value: stand.rewindPower
                    onMoved: stand.rewindPower = value
                }
                Label {
                    text: stand.rewindPower
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
            }
            TipRow {
                tip: "breaks.jsonc stepSec: the drawn fill moves only on this beat; between beats nothing repaints (default 60 s). Longer is cheaper."
                Layout.fillWidth: true
                Label {
                    text: "beat"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Slider {
                    Layout.fillWidth: true
                    from: 5
                    to: 300
                    stepSize: 5
                    value: stand.stepSec
                    onMoved: stand.stepSec = value
                }
                Label {
                    text: stand.stepSec + " s"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
            }
            TipRow {
                tip: "breaks.jsonc stepEaseMs: how long the head glides to its new place at a beat (default 700 ms, OutCubic). 0 jumps."
                Layout.fillWidth: true
                Label {
                    text: "ease"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Slider {
                    Layout.fillWidth: true
                    from: 0
                    to: 3000
                    stepSize: 100
                    value: stand.easeMs
                    onMoved: stand.easeMs = value
                }
                Label {
                    text: stand.easeMs + " ms"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
            }
            TipRow {
                tip: "breaks.jsonc hiddenMin: minutes of use that are not drawn; the fill eases in from the rail's start once more is banked and back out when a rewind drops under (default 10 min)."
                Layout.fillWidth: true
                Label {
                    text: "hidden"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Slider {
                    Layout.fillWidth: true
                    from: 0
                    to: 45
                    stepSize: 1
                    value: stand.hiddenMin
                    onMoved: stand.hiddenMin = value
                }
                Label {
                    text: stand.hiddenMin + " min"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
            }
            TipRow {
                tip: "The burst on its own, over the rail as it stands (a timer's or the nudge's tone)."
                Layout.fillWidth: true
                Button {
                    text: "burst (break)"
                    onClicked: ws.burst(-1, ws.breakTone)
                }
                Button {
                    text: "burst (timer)"
                    onClicked: ws.burst(-1, 0)
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "Stage"
                blurb: "The shell's numbers the groove is built from (shell.jsonc). The frame decides them, not Workspaces: they are not saved."
            }
            TipRow {
                tip: "workspacesScale: every size of the groove is multiplied by it, and the clock's slot and gaps are divided by it so they stay the same px. 0.9 is the default."
                Layout.fillWidth: true
                Label {
                    text: "scale"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Slider {
                    Layout.fillWidth: true
                    from: 0.6
                    to: 1.5
                    stepSize: 0.05
                    value: stand.k
                    onMoved: stand.k = value
                }
                Label {
                    text: stand.k.toFixed(2)
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
            }
            TipRow {
                tip: "workspacesPitch: what each side of the groove gets per workspace pitch, px; the groove is 2 x pitch + 64 + 100 x scale wide. 30 is the default."
                Layout.fillWidth: true
                Label {
                    text: "pitch"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Slider {
                    Layout.fillWidth: true
                    from: 16
                    to: 60
                    stepSize: 1
                    value: stand.pitch
                    onMoved: stand.pitch = value
                }
                Label {
                    text: stand.pitch
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
            }

            TipGroup {
                title: "State"
                blurb: "What the groove holds now."
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: "active " + ws.activeWorkspaceId + " (slot " + ws.activeIndex + " of " + ws.totalDots + ")   groove " + ws.width.toFixed(0) + " px"
                      + "\nbreak fill " + Math.round(bm.progressAt(bClock.now()) * 100) + " %" + (bm.full ? " (full)" : "") + "   " + stand.lastBreak
                + "\nlast sent: " + stand.lastSend
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
            }
        }
    ]

    readonly property var grooveParams: [
        {
            label: "line px",
            prop: "lineThickness",
            group: "Line",
            blurb: "The carved line the dots and the ball run in. Sizes are px before the size scale.",
            tip: "The groove's width across, px before the size scale (the shell's workspacesScale).",
            val: 6,
            from: 2,
            to: 16,
            step: 0.5
        },
        {
            label: "dot px",
            prop: "dotSize",
            group: "Line",
            tip: "A workspace dot's diameter, px before the size scale.",
            val: 12,
            from: 4,
            to: 24,
            step: 0.5
        },
        {
            label: "ball px",
            prop: "ballSize",
            group: "Line",
            tip: "The active workspace's ball, px before the size scale: 14 is the groove slider's ball too.",
            val: 14,
            from: 6,
            to: 30,
            step: 0.5
        },
        {
            label: "corner px",
            prop: "cornerExtent",
            group: "Line",
            tip: "How far along the groove each corner into a side track runs, px before the size scale.",
            val: 24,
            from: 8,
            to: 60,
            step: 1
        },
        {
            label: "shadow px",
            prop: "grooveShadowWidth",
            group: "Carve",
            blurb: "The groove is carved into the bar: an inset shadow inside its edge, a light bevel outside.",
            tip: "Width of the inset shadow inside the groove's edge, px: 3 is the shell's carve on containers.",
            val: 3,
            from: 0,
            to: 8,
            step: 0.5
        },
        {
            label: "bevel px",
            prop: "grooveBevelWidth",
            group: "Carve",
            tip: "Width of the light bevel outside the groove's edge, px.",
            val: 2,
            from: 0,
            to: 6,
            step: 0.5
        },
        {
            label: "shadow opacity",
            prop: "ballShadowOpacity",
            group: "Ball shadow",
            blurb: "The soft shadow under the ball, in its own colour.",
            tip: "Opacity of the ball's glow, 0 to 1.",
            val: 0.55,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "shadow blur",
            prop: "ballShadowBlur",
            group: "Ball shadow",
            tip: "How far that glow spreads, 0 to 1 (MultiEffect's blur).",
            val: 0.4,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "travel ms",
            prop: "animationDuration",
            group: "Motion",
            blurb: "The ball's trip to a new workspace.",
            tip: "How long the ball takes from one workspace to the next, ms; a trip across the clock takes the side track in the same time.",
            val: 400,
            from: 100,
            to: 1200,
            step: 10
        },
        {
            label: "sparks",
            prop: "sparksEnabled",
            group: "Sparks",
            blurb: "The sparks a fast ball throws behind it; over their last px they fade out, never cut.",
            tip: "On: a fast ball trails sparks.",
            val: true
        },
        {
            label: "speed threshold",
            prop: "sparksSpeedThreshold",
            group: "Sparks",
            tip: "The ball's speed from which it throws sparks.",
            val: 0.3,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "amount",
            prop: "sparksAmountMultiplier",
            group: "Sparks",
            tip: "How many sparks per unit of speed.",
            val: 3,
            from: 0,
            to: 10,
            step: 0.1
        },
        {
            label: "inherited velocity",
            prop: "sparksBaseVelocity",
            group: "Sparks",
            tip: "How much of the ball's velocity a spark carries backwards.",
            val: 0.1,
            from: 0,
            to: 0.5,
            step: 0.01
        },
        {
            label: "scatter",
            prop: "sparksScatter",
            group: "Sparks",
            tip: "The random velocity each spark gets on top.",
            val: 100,
            from: 0,
            to: 300,
            step: 5
        },
        {
            label: "burst dust",
            prop: "burstCount",
            group: "Burst",
            blurb: "The burst that says a break is due (the nudge filled) or a timer ended: the dust, a finer second wave, and the fill flashing once.",
            tip: "Particles in the first wave, spread along the bar.",
            val: 40,
            from: 0,
            to: 120,
            step: 1
        },
        {
            label: "burst life ms",
            prop: "burstLifetimeMs",
            group: "Burst",
            tip: "How long a dust particle lives before it has faded.",
            val: 1600,
            from: 200,
            to: 4000,
            step: 50
        },
        {
            label: "burst rise",
            prop: "burstRise",
            group: "Burst",
            tip: "How fast the dust drifts off the groove, px/s.",
            val: 18,
            from: 0,
            to: 80,
            step: 1
        },
        {
            label: "second wave",
            prop: "burstSecondWave",
            group: "Burst",
            tip: "The second wave's size as a share of the first, rising faster; 0 plays one wave.",
            val: 0.6,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "second wave ms",
            prop: "burstSecondDelayMs",
            group: "Burst",
            tip: "How long after the first wave the second one follows.",
            val: 220,
            from: 0,
            to: 1000,
            step: 10
        },
        {
            label: "flash ms",
            prop: "burstFlashMs",
            group: "Burst",
            tip: "How long the filled groove flashes at full strength and fades back; 0 plays the dust alone. A fade of one painted layer, so it costs no repaint per frame.",
            val: 1100,
            from: 0,
            to: 3000,
            step: 50
        },
        {
            label: "flash strength",
            prop: "burstFlashStrength",
            group: "Burst",
            tip: "How strong the flash is: 1 is the tone's whole inset shadow, the rest of the time the fill shows at its calm strength.",
            val: 1,
            from: 0.2,
            to: 1,
            step: 0.05
        },
        {
            label: "life ms",
            prop: "sparksLifetimeBase",
            group: "Sparks",
            tip: "A spark's base life, ms.",
            val: 700,
            from: 50,
            to: 3000,
            step: 10
        },
        {
            label: "life spread ms",
            prop: "sparksLifetimeVariance",
            group: "Sparks",
            tip: "A random extra on each spark's life, ms.",
            val: 1000,
            from: 0,
            to: 3000,
            step: 10
        },
        {
            label: "trail length",
            prop: "sparksMaxHistory",
            group: "Sparks",
            tip: "How many past positions a spark's trail keeps.",
            val: 8,
            from: 1,
            to: 16,
            step: 1
        },
        {
            label: "size start",
            prop: "sparksSizeStart",
            group: "Sparks",
            tip: "A spark's size when thrown, times the size scale.",
            val: 3,
            from: 0.2,
            to: 8,
            step: 0.1
        },
        {
            label: "size end",
            prop: "sparksSizeEnd",
            group: "Sparks",
            tip: "A spark's size when it dies, times the size scale.",
            val: 1,
            from: 0,
            to: 6,
            step: 0.1
        },
        {
            label: "drag",
            prop: "sparksDrag",
            group: "Sparks",
            tip: "Air resistance on a spark.",
            val: 2,
            from: 0,
            to: 8,
            step: 0.1
        },
        {
            label: "swirl strength",
            prop: "sparksSwirlStr",
            group: "Sparks",
            tip: "How hard a spark swirls at the end of its life.",
            val: 0.4,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "swirl chance",
            prop: "sparksSwirlProb",
            group: "Sparks",
            tip: "The share of sparks that swirl.",
            val: 0.4,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "edge fade px",
            prop: "particleEdgeFade",
            group: "Sparks",
            tip: "Over this many px at the sides and the foot of the particles' room a spark fades out instead of being cut.",
            val: 24,
            from: 0,
            to: 64,
            step: 1
        },
        {
            label: "bloom blur",
            prop: "sparksBloomBlur",
            group: "Bloom",
            blurb: "The glow laid over the sparks.",
            tip: "Blur of the glow over the sparks.",
            val: 24,
            from: 0,
            to: 64,
            step: 1
        },
        {
            label: "bloom strength",
            prop: "sparksBloomStrength",
            group: "Bloom",
            tip: "Strength of that glow.",
            val: 0.3,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "bloom brightness",
            prop: "sparksBloomBrightness",
            group: "Bloom",
            tip: "Brightness of the glow layer.",
            val: 0.85,
            from: 0,
            to: 2,
            step: 0.05
        }
    ]

    readonly property var grooveColors: [
        {
            label: "surface",
            prop: "surfaceColor",
            group: "Groove",
            blurb: "The groove's colours, each a theme token.",
            tip: "The ground the groove is carved into: the bar's surface.",
            val: "@surface"
        },
        {
            label: "groove",
            prop: "grooveColor",
            group: "Groove",
            tip: "The groove's floor: the sunk panel tone.",
            val: "@panelSunk"
        },
        {
            label: "bevel",
            prop: "grooveBevelColor",
            group: "Groove",
            tip: "The light rim outside the groove's edge.",
            val: "@bevel"
        },
        {
            label: "shadow",
            prop: "grooveShadowColor",
            group: "Groove",
            tip: "The inset shadow inside its edge.",
            val: "@border"
        },
        {
            label: "ball",
            prop: "ballColor",
            group: "Ball",
            blurb: "The ball and its glow.",
            tip: "The active workspace's ball, and the sparks: the accent.",
            val: "@accent"
        },
        {
            label: "ball shadow",
            prop: "ballShadowColor",
            group: "Ball",
            tip: "The ball's glow: the accent.",
            val: "@accent"
        }
    ]
}
