pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtTest
import Quickshell
import Quickshell.Io

import "modules/common/mockup"
import "modules/common/system"
import "modules/common/theme"
import "modules/common/power"
import "modules/common/notify"
import "modules/bar/gooey"
import "modules/bar/gooey/GooeyGeometry.js" as Geo
import "modules/silicon"
import "modules/silicon/data"
import "modules/notifications/data"
import "modules/notifications/parts"
import "modules/notifications/toast"
import "modules/silicon/data/MockTimeline.js" as TL
import "modules/silicon/data/SiliconModel.js" as Model
import "modules/silicon/scene/IsoCamera.js" as Cam

// =============================================================================
// mockups/silicon.qml -- the silicon popup mockup, on the REAL bar engine.
//
// A slice of the screen at 1:1: a GooeyEngine with a bar carrying the silicon button (BAR=right: a
// right bar, the button stacked), thePopup the silicon content opens in, and the engine's secondary
// the tuning / GPU panels and the two dialogs (the restart card, the question about apps on the dGPU) open in --
// the drop-in as it will run, wired by the real SiliconBarOwner. The keep prompt after a dGPU-only restart is a TOAST (the
// watcher's MuxKeepPrompt, through a real NotificationService the stage hosts): the toasts stand in the stage's top right
// corner as the real ToastEntry draws them (the engine's lane, which stacks them in the shell, is not on this stage).
//
// THE DATA IS SiliconMock unless the user switches to live: a machine as pure functions of time (MockTimeline: desk,
// compile, game, unplug, charge), a simulated device that settles and writes after a delay, and the
// changes only a mock can make (outside changes, refused writes, absent parts). The real service
// calls pkexec and the real helper, so the footer's Live switch (R2 Q1) is ARMED: the first click only
// arms it, a second within 4 s builds the REAL SiliconService (in a Loader, only while live) and the owner
// is fed it; the popup then changes THIS machine's profile, GPU mode and charge limit, and the MUX flow
// (dGPU only, restart) and its guard are real. Nothing but that click selects live: no env, no probe, no
// runner.
//
// The footer is the transport and stays under every tab: the scenario, play / pause, the time
// scrub, and the popup's open / close. The panel's tabs (mockup_framework.md, "The panel standard"): Run (the mock
// machine and what it can be made to do: the MUX flow end to end, its guard, a blocked app, the RAM the board shows),
// Look (the family switch and every silicon Theme token), Layout (the popup's plates, the battery error's tag and type
// sizes), Motion (the popup's director and clock: how fast the films play, how the live values ease, how long the charge
// limit's lock takes, the tempo of the light on the traces, the idle ladder and the MUX breath, with a readout of where
// the ladder stands and the Entrance button that plays the power-on again), Particles (the battery terminals' particles),
// Sounds (the three volumes, the take of each of the four files -- a / b / c, see tools/silicon/make_clicks.py; the panel
// starts on silicon.jsonc's picks -- the debounce, a button for each sound and one for each take), Bar (the button).
//
// Env: BAR=top|right  SCENARIO=<desk|compile|game|unplug|charge>  TIME=<ms into the loop>
//      PLAY=0 (hold the timeline)  FAMILY=material|blueprint (eva still reads as material)  DRESS=audiowide  OPEN=0 (start closed)
//      MACHINE=charge=35,ac=off,dgpu=busy,helper=off,hide=mux (the Machine group's rows, for a render:
//      charge -1..100, ac follow|on|off, dgpu follow|asleep|awake|busy, helper ok|off, hide none|<feature>)
//      SECONDARY=tuning|gpu (that secondary opened once the popup is out)
//      SIDE=far|start|end (where the secondaries open: the Look tab's "secondary side")
//      DIALOG=mux-dgpu|mux-integrated|mux-smart|mux-hybrid|mux-precheck|confirm|confirm-6 (a dialog put up by hand
//      once the popup is out -- for a render: the engine draws its secondary around it); keep|keep-low|keep-login: the machine
//      is at the keep prompt (the guard's record awaits its keep, 107 s / 8 s left): the TOAST comes up by itself, no popup
//      opens for it (keep-login: before the popup is even opened, as at a login)
//      STAGE_GRAB=<png> (the stage alone, GRAB_MS after the start, then quit)  ZOOM
//      WIN_H=<px> (a taller window, to see a long tab whole in a grab)
//      PROBE=owner (the owner probe: SILICONOWNER lines, then SILICONOWNER RESULT PASS|FAIL)
//      STEPS=O11,O12 (with PROBE=owner: only those steps, after the setup; X1 is a repro that only STEPS=X1 runs)
//      WAIT_MS=<ms> (with PROBE=owner: how long an O11 / O12 check waits for its condition; 12000. The ARMs
//      shorten it: they expect to fail, and each failing check costs its whole wait)
//      STUB_LOG=<file> STUB_PWPLAY=<exe> (with PROBE=owner: the runner's stand-ins for pw-play and notify-send, which
//      append "PLAY <argv>" / "NOTIFY <argv>" to that one log. O15's auditions and O16's blocked app read it; without
//      them those checks FAIL, so no run can make a sound or a notification of its own)
//      PROBE=soak (a scripted half minute through every intent, an outside change, a refused write, the
//      MUX flow and the guard's revert (the OSD a stub) with the shell's start that tells it, the entrance,
//      a sound, both families and both modes with a secondary out: the log must stay clean)
//      + the framework's GRAB
//
// Run it: quickshell -p mockups/silicon.qml   (from the config: the Look tab's colours edit themes/eva.json,
//         so they are read-only in a sandbox copy, tools/dev/sandbox.sh, which with private XDG dirs leaves
//         the desktop's own theme alone)
// =============================================================================
MockupWindow {
    id: win

    moduleId: "silicon"
    title: "Silicon"
    stageLabel: "A section of the screen at 1:1 -- a " + win.barEdge + " bar, the silicon button, thePopup and its secondary"
    content: scene
    target: tun
    targets: ({
            machineParams: mach,
            memoryParams: mem,
            deviceParams: mock,
            buttonParams: siliconButton,
            layoutParams: lay,
            directorParams: mot,
            clockParams: mot,
            idleParams: mot,
            sceneParams: mot,
            soundParams: snd,
            particleParams: par
        })
    stageColor: "#1F2229"
    zoom: Number(Quickshell.env("ZOOM") || (win.barEdge === "right" ? 0.75 : 0.62))
    panelWidth: 460
    height: Number(Quickshell.env("WIN_H") || 960)

    readonly property string barEdge: (Quickshell.env("BAR") || "top") === "right" ? "right" : "top"
    // the engine's words for where a secondary hangs (the Look tab's "secondary side" picks one)
    readonly property var sideNames: ["far", "start", "end"]

    lists: ({
            lookParams: win.lookParams,
            siliconColors: win.siliconColors,
            machineParams: win.machineParams,
            memoryParams: win.memoryParams,
            deviceParams: win.deviceParams,
            barParams: win.barParams,
            buttonParams: win.buttonParams,
            layoutParams: win.layoutParams,
            directorParams: win.directorParams,
            clockParams: win.clockParams,
            idleParams: win.idleParams,
            sceneParams: win.sceneParams,
            soundParams: win.soundParams,
            particleParams: win.particleParams
        })
    themedLists: ["siliconColors"]

    tabDefs: [
        {
            name: "Run",
            lists: ["machineParams", "memoryParams", "deviceParams"],
            page: scenarioPage
        },
        {
            name: "Look",
            subs: [
                {
                    name: "Board",
                    lists: ["lookParams"],
                    groups: ["Board", "Secondaries", "Size"]
                },
                {
                    name: "Hues",
                    lists: ["siliconColors"],
                    groups: ["Profile hues", "GPU hues"]
                },
                {
                    name: "Material",
                    lists: ["siliconColors"],
                    groups: ["Material palette"]
                },
                {
                    name: "Blueprint",
                    lists: ["siliconColors"],
                    groups: ["Blueprint palette"]
                },
                {
                    name: "Parts",
                    lists: ["siliconColors"],
                    groups: ["7-segment displays", "Charge limit lock", "Card and memory", "Display ribbon", "Display connector"]
                }
            ]
        },
        {
            name: "Layout",
            lists: ["layoutParams"]
        },
        {
            name: "Motion",
            subs: [
                {
                    name: "Films",
                    lists: ["directorParams"],
                    groups: ["Films", "The card's wait", "Carried-on lift"]
                },
                {
                    name: "Eased values",
                    lists: ["directorParams"],
                    groups: ["Eased values"]
                },
                {
                    name: "Tempo",
                    lists: ["clockParams"]
                },
                {
                    name: "Idle ladder",
                    lists: ["idleParams"]
                },
                {
                    name: "MUX breath",
                    lists: ["sceneParams"]
                }
            ],
            page: motionPage
        },
        {
            name: "Particles",
            subs: [
                {
                    name: "Charging",
                    lists: ["particleParams"],
                    groups: ["Charging: how many", "Charging: motion", "Charging: shape", "Charging: aim", "Charging: floors"]
                },
                {
                    name: "Discharging",
                    lists: ["particleParams"],
                    groups: ["Discharging: how many", "Discharging: motion", "Discharging: shape", "Discharging: aim", "Discharging: floors"]
                }
            ]
        },
        {
            name: "Sounds",
            lists: ["soundParams"],
            page: soundsPage
        },
        {
            name: "Bar",
            subs: [
                {
                    name: "Button",
                    lists: ["barParams"]
                },
                {
                    name: "GPU glyph",
                    lists: ["buttonParams"],
                    groups: ["GPU glyph", "GPU glyph motion"]
                },
                {
                    name: "Face",
                    lists: ["buttonParams"],
                    groups: ["Face", "Motion", "Flourish"]
                }
            ],
            page: barPage
        }
    ]

    // ---- Tunables (the panel's target; the owner and the button bind to them) -------------
    QtObject {
        id: tun
        property int family: 0
        property int secondarySide: 0       // 0 far | 1 start | 2 end (win.sideNames)
        property real sizeScale: 1          // SiliconBarOwner.sizeScale: the popup's own scale on top of its popup ratio
        property bool dressAudiowide: false
        property real iconAlong: 750
    }

    // The Layout tab's target, and the Motion tab's below. The popup is rebuilt on every open, so its own knobs
    // and its director's and clock's live HERE and are pushed into whichever popup is out (the Bindings);
    // a tweak survives a close.
    QtObject {
        id: lay
        property real margin: 12
        property real plateGap: 4
        property real cpuPlateWidth: 240
        property real gpuPlateWidth: 300
        property real errorTagDx: 6
        property real errorTagDy: 22
        property real errorTagMaxWidth: 160
        property real headSize: 16
        property real bodySize: 12
        property real figureSize: 11
    }
    Binding {
        target: win._popup
        property: "margin"
        value: lay.margin
        when: !!win._popup
    }
    Binding {
        target: win._popup
        property: "plateGap"
        value: lay.plateGap
        when: !!win._popup
    }
    Binding {
        target: win._popup
        property: "cpuPlateWidth"
        value: lay.cpuPlateWidth
        when: !!win._popup
    }
    Binding {
        target: win._popup
        property: "gpuPlateWidth"
        value: lay.gpuPlateWidth
        when: !!win._popup
    }
    Binding {
        target: win._popup
        property: "errorTagDx"
        value: lay.errorTagDx
        when: !!win._popup
    }
    Binding {
        target: win._popup
        property: "errorTagDy"
        value: lay.errorTagDy
        when: !!win._popup
    }
    Binding {
        target: win._popup
        property: "errorTagMaxWidth"
        value: lay.errorTagMaxWidth
        when: !!win._popup
    }
    Binding {
        target: win._popup
        property: "headSize"
        value: lay.headSize
        when: !!win._popup
    }
    Binding {
        target: win._popup
        property: "bodySize"
        value: lay.bodySize
        when: !!win._popup
    }
    Binding {
        target: win._popup
        property: "figureSize"
        value: lay.figureSize
        when: !!win._popup
    }

    // The Motion tab's target: the popup's director and clock, its board's MUX breath and the idle ladder's four times (the
    // service's ladder follows them: the Bindings after this object).
    QtObject {
        id: mot
        property real speed: 1
        property real rewindSpeed: 1
        property real holdAt: 0.55
        property real bridgeS: 0.2
        property real coresS: 0.3
        property real fillS: 0.8
        property real flowS: 0.4
        property real awakeS: 0.35
        property real tweakS: 0.35
        property real eventS: 4.0
        property real lockSeconds: 0.34
        property real cpuTempoQuiet: 0.55
        property real cpuTempoPerformance: 1.1
        property real cpuLoadSlow: 0.6
        property real cpuLoadFast: 1.4
        property real gpuTempoIdle: 0.5
        property real gpuTempoBusy: 1.4
        property real flowBase: 14
        property real flowPerWatt: 0.5
        property real flowMax: 60
        property int aliveMs: 16
        property int calmMs: 33
        property real restSeconds: 1.0
        property real wakeSeconds: 0.4
        property real crossfadeHold: 0.4
        property real muxBreathS: 1.6
        property real muxBreathDepth: 0.45
        property real lensStrength: 0.5
        property real fxPlinth: 1
        property real fxTrace: 1
        property real fxOrbits: 1
        property real fxStream: 1
        property int calmAfterMs: 10000
        property int haltAfterMs: 30000
        property int statsHaltedMs: 2000
        property int batteryHaltedMs: 5000
    }
    // the ladder's times to the service's own ladder (the mock's, or the live service's); the halt is never before the calm
    Binding {
        target: win.activeService ? win.activeService.idleLadder : null
        property: "calmAfterMs"
        value: mot.calmAfterMs
        when: !!win.activeService && !!win.activeService.idleLadder
    }
    Binding {
        target: win.activeService ? win.activeService.idleLadder : null
        property: "haltAfterMs"
        value: Math.max(mot.haltAfterMs, mot.calmAfterMs)
        when: !!win.activeService && !!win.activeService.idleLadder
    }
    Binding {
        target: win.activeService ? win.activeService.idleLadder : null
        property: "statsHaltedMs"
        value: mot.statsHaltedMs
        when: !!win.activeService && !!win.activeService.idleLadder
    }
    Binding {
        target: win.activeService ? win.activeService.idleLadder : null
        property: "batteryHaltedMs"
        value: mot.batteryHaltedMs
        when: !!win.activeService && !!win.activeService.idleLadder
    }
    readonly property var _director: win._popup ? win._popup.director : null
    readonly property var _clock: win._popup ? win._popup.clock : null
    readonly property var _board: win._popup ? win._popup.sceneItem : null
    readonly property var _poleField: win._board ? win._board.poleField : null
    readonly property var _sounds: win._popup ? win._popup.sounds : null
    Binding {
        target: win._director
        property: "speed"
        value: mot.speed
        when: !!win._director
    }
    Binding {
        target: win._director
        property: "rewindSpeed"
        value: mot.rewindSpeed
        when: !!win._director
    }
    Binding {
        target: win._director
        property: "holdAt"
        value: mot.holdAt
        when: !!win._director
    }
    Binding {
        target: win._director
        property: "bridgeS"
        value: mot.bridgeS
        when: !!win._director
    }
    Binding {
        target: win._director
        property: "coresS"
        value: mot.coresS
        when: !!win._director
    }
    Binding {
        target: win._director
        property: "fillS"
        value: mot.fillS
        when: !!win._director
    }
    Binding {
        target: win._director
        property: "flowS"
        value: mot.flowS
        when: !!win._director
    }
    Binding {
        target: win._director
        property: "awakeS"
        value: mot.awakeS
        when: !!win._director
    }
    Binding {
        target: win._director
        property: "tweakS"
        value: mot.tweakS
        when: !!win._director
    }
    Binding {
        target: win._director
        property: "eventS"
        value: mot.eventS
        when: !!win._director
    }
    Binding {
        target: win._director
        property: "lockSeconds"
        value: mot.lockSeconds
        when: !!win._director
    }
    Binding {
        target: win._clock
        property: "cpuTempoQuiet"
        value: mot.cpuTempoQuiet
        when: !!win._clock
    }
    Binding {
        target: win._clock
        property: "cpuTempoPerformance"
        value: mot.cpuTempoPerformance
        when: !!win._clock
    }
    Binding {
        target: win._clock
        property: "cpuLoadSlow"
        value: mot.cpuLoadSlow
        when: !!win._clock
    }
    Binding {
        target: win._clock
        property: "cpuLoadFast"
        value: mot.cpuLoadFast
        when: !!win._clock
    }
    Binding {
        target: win._clock
        property: "gpuTempoIdle"
        value: mot.gpuTempoIdle
        when: !!win._clock
    }
    Binding {
        target: win._clock
        property: "gpuTempoBusy"
        value: mot.gpuTempoBusy
        when: !!win._clock
    }
    Binding {
        target: win._clock
        property: "flowBase"
        value: mot.flowBase
        when: !!win._clock
    }
    Binding {
        target: win._clock
        property: "flowPerWatt"
        value: mot.flowPerWatt
        when: !!win._clock
    }
    Binding {
        target: win._clock
        property: "flowMax"
        value: mot.flowMax
        when: !!win._clock
    }
    Binding {
        target: win._clock
        property: "aliveMs"
        value: mot.aliveMs
        when: !!win._clock
    }
    Binding {
        target: win._clock
        property: "calmMs"
        value: mot.calmMs
        when: !!win._clock
    }
    Binding {
        target: win._clock
        property: "restSeconds"
        value: mot.restSeconds
        when: !!win._clock
    }
    Binding {
        target: win._clock
        property: "wakeSeconds"
        value: mot.wakeSeconds
        when: !!win._clock
    }
    Binding {
        target: win._clock
        property: "crossfadeHold"
        value: mot.crossfadeHold
        when: !!win._clock
    }
    Binding {
        target: win._board
        property: "muxBreathS"
        value: mot.muxBreathS
        when: !!win._board
    }
    Binding {
        target: win._board
        property: "muxBreathDepth"
        value: mot.muxBreathDepth
        when: !!win._board
    }
    Binding {
        target: win._board
        property: "lensStrength"
        value: mot.lensStrength
        when: !!win._board
    }
    Binding {
        target: win._board
        property: "fxPlinth"
        value: mot.fxPlinth
        when: !!win._board
    }
    Binding {
        target: win._board
        property: "fxTrace"
        value: mot.fxTrace
        when: !!win._board
    }
    Binding {
        target: win._board
        property: "fxOrbits"
        value: mot.fxOrbits
        when: !!win._board
    }
    Binding {
        target: win._board
        property: "fxStream"
        value: mot.fxStream
        when: !!win._board
    }
    // The Particles tab's target: every number of the two fields at the battery's poles (modules/silicon/scene/ParticleField.qml's charge* and
    // discharge* properties, the scene's `poleField`), pushed into whichever popup is out. The poles' defaults are the component's own.
    QtObject {
        id: par
        property real chargeKneeW: 18
        property real chargeWeak: 0.4
        property real chargeAlpha: 1
        property real chargeLifeMinusS: 1
        property real chargeLifePlusS: 1
        property real chargeReachMinus: 7
        property real chargeReachPlus: 4.4
        property real chargeMouthMinus: 3
        property real chargeMouthPlus: 1
        property real chargeNeck: 0.8
        property real chargeTwist: 0
        property real chargeSize: 1
        property real chargeOriginY: 1.4
        property real chargeOriginPlusY: 1
        property real chargeLeanMinus: 0
        property real chargeLeanPlus: 0
        property real chargeFloor: 0.6
        property real chargeEdge: 0.1
        property real dischargeKneeW: 18
        property real dischargeWeak: 0.4
        property real dischargeAlpha: 1
        property real dischargeLifeMinusS: 1.5
        property real dischargeLifePlusS: 0.9
        property real dischargeReachMinus: 10
        property real dischargeReachPlus: 4.4
        property real dischargeRadiusMinus: 2.2
        property real dischargeRadiusPlus: 1.4
        property real dischargeTurnsMin: 0.5
        property real dischargeTurnsMax: 1.2
        property real dischargeSize: 1
        property real dischargeOriginY: 1
        property real dischargeLeanMinus: 0
        property real dischargeLeanPlus: 0
        property real dischargeFloor: 0.6
        property real dischargeEdge: 0.1
    }
    Binding {
        target: win._poleField
        property: "chargeKneeW"
        value: par.chargeKneeW
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "chargeWeak"
        value: par.chargeWeak
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "chargeAlpha"
        value: par.chargeAlpha
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "chargeLifeMinusS"
        value: par.chargeLifeMinusS
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "chargeLifePlusS"
        value: par.chargeLifePlusS
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "chargeReachMinus"
        value: par.chargeReachMinus
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "chargeReachPlus"
        value: par.chargeReachPlus
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "chargeMouthMinus"
        value: par.chargeMouthMinus
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "chargeMouthPlus"
        value: par.chargeMouthPlus
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "chargeNeck"
        value: par.chargeNeck
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "chargeTwist"
        value: par.chargeTwist
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "chargeSize"
        value: par.chargeSize
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "chargeOriginY"
        value: par.chargeOriginY
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "chargeOriginPlusY"
        value: par.chargeOriginPlusY
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "chargeLeanMinus"
        value: par.chargeLeanMinus
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "chargeLeanPlus"
        value: par.chargeLeanPlus
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "chargeFloor"
        value: par.chargeFloor
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "chargeEdge"
        value: par.chargeEdge
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "dischargeKneeW"
        value: par.dischargeKneeW
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "dischargeWeak"
        value: par.dischargeWeak
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "dischargeAlpha"
        value: par.dischargeAlpha
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "dischargeLifeMinusS"
        value: par.dischargeLifeMinusS
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "dischargeLifePlusS"
        value: par.dischargeLifePlusS
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "dischargeReachMinus"
        value: par.dischargeReachMinus
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "dischargeReachPlus"
        value: par.dischargeReachPlus
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "dischargeRadiusMinus"
        value: par.dischargeRadiusMinus
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "dischargeRadiusPlus"
        value: par.dischargeRadiusPlus
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "dischargeTurnsMin"
        value: par.dischargeTurnsMin
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "dischargeTurnsMax"
        value: par.dischargeTurnsMax
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "dischargeSize"
        value: par.dischargeSize
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "dischargeOriginY"
        value: par.dischargeOriginY
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "dischargeLeanMinus"
        value: par.dischargeLeanMinus
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "dischargeLeanPlus"
        value: par.dischargeLeanPlus
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "dischargeFloor"
        value: par.dischargeFloor
        when: !!win._poleField
    }
    Binding {
        target: win._poleField
        property: "dischargeEdge"
        value: par.dischargeEdge
        when: !!win._poleField
    }
    // The Sounds tab's target: the three volumes, the debounce and the take of each of the four files (0 a, 1 b, 2 c), bound
    // into the popup's own sounds (SiliconSounds: the module's constants). The takes START from the user's picks (latch a, dip a,
    // plug c, plug_out a), not from a fixed "a".
    QtObject {
        id: snd
        readonly property var takes: ["a", "b", "c"]
        property real latch: 0.2
        property real dip: 0.2
        property real plug: 0.2
        property int debounceMs: 80
        property int latchVariant: 0
        property int dipVariant: 0
        property int plugVariant: 2
        property int plugOutVariant: 0
    }
    Binding {
        target: win._sounds
        property: "debounceMs"
        value: snd.debounceMs
        when: !!win._sounds
    }
    Binding {
        target: win._sounds
        property: "latchVolume"
        value: snd.latch
        when: !!win._sounds
    }
    Binding {
        target: win._sounds
        property: "dipVolume"
        value: snd.dip
        when: !!win._sounds
    }
    Binding {
        target: win._sounds
        property: "plugVolume"
        value: snd.plug
        when: !!win._sounds
    }
    Binding {
        target: win._sounds
        property: "latchTake"
        value: snd.takes[snd.latchVariant]
        when: !!win._sounds
    }
    Binding {
        target: win._sounds
        property: "dipTake"
        value: snd.takes[snd.dipVariant]
        when: !!win._sounds
    }
    Binding {
        target: win._sounds
        property: "plugTake"
        value: snd.takes[snd.plugVariant]
        when: !!win._sounds
    }
    Binding {
        target: win._sounds
        property: "plugOutTake"
        value: snd.takes[snd.plugOutVariant]
        when: !!win._sounds
    }

    // The Machine group's target. The mock's machine knobs are strings and a list, which a panel row cannot write
    // (a choice is an index, a switch a bool), so the rows write here and these Bindings push them into the mock.
    readonly property var machineFeatures: ["profile", "epp", "turbo", "governor", "maxPerfPct", "caps", "chargeLimit", "mux"]
    QtObject {
        id: mach
        property int pct: -1
        property int ac: 0
        property int dgpu: 0
        property bool hdmi: false
        property bool helperOk: true
        property int hide: 0
        property bool muxUnit: true
        property int bootWindowS: 300
        property int promptWindowS: 120
    }
    Binding {
        target: mock
        property: "machinePct"
        value: mach.pct
    }
    Binding {
        target: mock
        property: "machineAc"
        value: ["", "on", "off"][mach.ac] ?? ""
    }
    Binding {
        target: mock
        property: "machineDgpu"
        value: ["", "asleep", "awake", "busy"][mach.dgpu] ?? ""
    }
    Binding {
        target: mock
        property: "hdmiConnected"
        value: mach.hdmi
    }
    Binding {
        target: mock
        property: "helperOk"
        value: mach.helperOk
    }
    Binding {
        target: mock
        property: "hiddenFeatures"
        value: mach.hide > 0 ? [win.machineFeatures[mach.hide - 1]] : []
    }
    Binding {
        target: mock
        property: "muxUnitActive"
        value: mach.muxUnit
    }
    Binding {
        target: mock
        property: "bootWindowS"
        value: mach.bootWindowS
    }
    Binding {
        target: mock
        property: "promptWindowS"
        value: mach.promptWindowS
    }

    // The Memory group's target (Run tab). The row pins the MEMORY FACT: ONE Binding puts it on the mock as `memoryOverride`
    // ({ usedFraction }, or null while 'override memory' is off), the mock makes the facts of it, and everything the popup shows follows
    // from those -- the board's RAM display (its printed GiB) and its chips read one source. Nothing writes the scene's `memory` behind the
    // facts' back (O10 proves the display and the chips agree).
    QtObject {
        id: mem
        property bool memOverride: false
        property int memUsedPct: 40
    }
    Binding {
        target: mock
        property: "memoryOverride"
        value: mem.memOverride ? ({ usedFraction: mem.memUsedPct / 100 }) : null
    }

    // ---- the data: the mock, and the REAL service only while the user has switched to live (R2 Q1) ----------
    SiliconMock {
        id: mock
    }

    // "mock" | "live". The ONLY way to live is the footer's switch, which wants a second click within `liveArmMs`: there is no env
    // for it, and no probe or runner selects it. The real service
    // is built in the Loader below and only while live; it calls pkexec and the real helper, so a click in the popup then changes
    // THIS machine's profile, GPU mode and charge limit. A service that did not load leaves `activeService` the mock.
    property string siliconSource: "mock"
    readonly property bool live: win.siliconSource === "live"
    property bool liveArmed: false
    readonly property int liveArmMs: 4000
    Loader {
        id: liveLoader
        active: win.live
        source: win.live ? Qt.resolvedUrl("modules/silicon/data/SiliconService.qml") : ""
    }
    readonly property var liveService: win.live ? liveLoader.item : null
    // what the owner is fed: never null (a null `service` would make the owner start a SiliconService of its own)
    readonly property var activeService: win.liveService ?? mock
    Timer {
        id: liveArmTimer
        interval: win.liveArmMs
        onTriggered: win.liveArmed = false
    }
    function armRealService() {
        if (win.live)
            return;
        win.liveArmed = true;
        liveArmTimer.restart();
    }
    function disarmLive() {
        win.liveArmed = false;
        liveArmTimer.stop();
    }
    // the popup is closed first: a popup built on one service is not carried over to the other
    function confirmRealService() {
        win.disarmLive();
        if (owner.popupMine)
            owner.close();
        win.siliconSource = "live";
    }
    function realServiceClick() {
        if (win.live)
            return;
        if (win.liveArmed)
            win.confirmRealService();
        else
            win.armRealService();
    }
    function useMockService() {
        win.disarmLive();
        if (owner.popupMine)
            owner.close();
        win.siliconSource = "mock";
    }

    readonly property var scenarioNames: TL.SCENARIOS
    readonly property real timelineMs: TL.durationMs("desk")
    readonly property var scenarioWords: ({
            desk: "On the mains, full, idle: a little load, the dGPU asleep (it wakes by itself at 40 s for six seconds: something woke it and nobody uses it).",
            compile: "On the mains, every core busy, the package heating up; a Smart block of blender at 9 s.",
            game: "On battery at 71 %: the dGPU wakes at 3 s for a game (steam, then proton), its own readouts, a heavy draw, and a Smart block at 3.2 s.",
            unplug: "Full on the mains, the charger comes out at 5 s and the pack drains (a time-lapse): the 15 % low mark is crossed at about 45 s.",
            charge: "On battery at 20 %, the charger goes in at 5 s and the pack fills (a time-lapse): constant current, then a taper, full at about 55 s."
        })

    function pickScenario(name) {
        if (TL.SCENARIOS.indexOf(name) < 0)
            return;
        mock.scenario = name;
        mock.timeMs = 0;
    }

    // What the mock said lately: the OSD it would have asked for, a refusal, an event.
    property var events: []
    function note(text) {
        win.events = [text].concat(win.events).slice(0, 7);
    }
    Connections {
        target: mock
        function onOsd(request: var) {
            win.note("OSD asked: " + request.title + " (" + request.detail + ")");
        }
        function onWriteRefused(zone: string, why: string) {
            win.note("refused " + zone + ": " + why);
        }
        function onAppBlocked(app: var) {
            win.note("Smart blocked " + app.comm);
        }
        function onBatteryEvent(kind: string) {
            win.note("battery event: " + kind);
        }
        function onAcChanged(on: bool) {
            win.note("mains " + (on ? "in" : "out"));
        }
        function onGpuPowerChanged(dState: string) {
            win.note("dGPU is now " + dState);
        }
    }

    // ---- the calls the Motion, Sounds and Scenario pages make: one function each, so the probe presses the same thing ----
    // Play the power-on again. A halted popup plays nothing, so the idle ladder is woken first; `opening()` starts a finished
    // power-on over from dark (one cut short carries on), `powerOn()` plays it.
    function replayEntrance() {
        const d = win._director;
        if (!d)
            return;
        mock.touch();
        d.opening();
        d.powerOn();
    }

    // What the Motion tab's readout says: the ladder's rung, the clock, the entrance.
    readonly property string motionText: {
        const c = win._clock, d = win._director;
        if (!c || !d)
            return "the popup is not built: open it to see its clock";
        return "ladder: " + mock.idleState + "   clock: " + (c.parked ? "parked" : "running every " + Number(c.pacedMs).toFixed(1) + " ms (asked " + c.intervalMs + ", display " + Number(1000 / c.vsyncMs).toFixed(0) + " Hz)") + "   live " + Number(c.live).toFixed(2)
               + "\nentrance: " + (d.entranceRunning ? "playing " + Number(d.entrancePower).toFixed(2) : d.entranceDone ? "done" : "waiting");
    }

    // The six sounds the popup's sounds can audition, as the Sounds page lists them.
    readonly property var auditions: [
        { label: "Latch seats", name: "latch", on: true },
        { label: "Latch lets go", name: "latch", on: false },
        { label: "Limit on", name: "dip", on: true },
        { label: "Limit off", name: "dip", on: false },
        { label: "Plug in", name: "plug", on: true },
        { label: "Plug out", name: "plug", on: false }
    ]
    function auditionSound(name, on, variant) {
        if (win._sounds)
            win._sounds.audition(name, on, variant);
    }
    // The takes, as the Sounds page lists them for comparing: the sound, the way it goes, and the three takes' words
    readonly property var takeRows: [
        { label: "Latch", name: "latch", on: true, words: ["a  tick", "b  soft click", "c  snap"] },
        { label: "Switch", name: "dip", on: true, words: ["a  tiny tick", "b  soft click", "c  snap"] },
        { label: "Plug in", name: "plug", on: true, words: ["a  short scrape", "b  long, soft", "c  snap"] },
        { label: "Plug out", name: "plug", on: false, words: ["a  pop, scrape fades", "b  long, soft", "c  snap"] }
    ]

    // The guard's keep window, run out: the keep toast's deadline goes 2 s ahead (the mock's own call for "the prompt is on
    // screen", with its window set to 2 s for that one call), so the guard's revert plays without a wait of minutes.
    function runOutKeepWindow() {
        const keep = mock.promptWindowS;
        mock.promptWindowS = 2;
        const ok = mock.muxPromptShown();
        mock.promptWindowS = keep;
        return ok;
    }
    // The mock never reboots: this is the next shell's start. The watcher looks at the guard's last word again, tells an
    // outcome nobody was told (once), and puts the keep prompt up again when one is due.
    function restartShell() {
        owner.muxWatcher.lookAgain();
    }
    // The shell's notification service as a probe sees it: the stage's own, registered for the run (nothing reaches the user's
    // bus) and emptied; `win.notes(key)` are the records the watcher posted under a key (the stored outcome, the keep prompt).
    function useNotifications(on) {
        if (on) {
            const recs = toastSvc.store.all();
            for (let i = 0; i < recs.length; i++)
                toastSvc.withdrawUid(recs[i].uid);
        }
        NotificationBus.service = on ? toastSvc : null;
    }
    function notes(key) {
        return toastSvc.store.all().filter(r => r.sourceId === "silicon" && r.key === key);
    }
    // The keep prompt's toast: its record, and whether the scheduler has it on the lane.
    function keepToast() {
        const r = win.notes("silicon-mux-keep");
        return r.length > 0 ? r[0] : null;
    }
    function keepToastShown() {
        const r = win.keepToast();
        return !!r && toastSvc.toasts.shown.indexOf(r.uid) >= 0;
    }
    // Smart kept an app off the dGPU: the data layer's own signal, one of four apps in turn (an app is notified once).
    readonly property var blockedApps: [
        { id: "blender", comm: "blender", pid: 41032 },
        { id: "krita", comm: "krita", pid: 41588 },
        { id: "obs", comm: "obs", pid: 42011 },
        { id: "godot", comm: "godot", pid: 42377 }
    ]
    property int _blockedNext: 0
    function emitBlockedApp() {
        const a = win.blockedApps[win._blockedNext % win.blockedApps.length];
        win._blockedNext++;
        mock.appBlocked({
            id: a.id,
            comm: a.comm,
            appId: a.id,
            pid: a.pid,
            gpuId: 1,
            atMs: Date.now()
        });
    }

    // =====================================================================
    //  THE STAGE
    // =====================================================================
    Item {
        id: scene
        // wide enough for the popup to have a whole secondary's room on EACH side of it (the secondary side is a setting: far, start, end)
        implicitWidth: win.barEdge === "right" ? 1300 : 1500
        implicitHeight: win.barEdge === "right" ? 860 : 1240

        Rectangle {
            anchors.fill: parent
            color: win.stageColor
        }

        GooeyEngine {
            id: engine
            anchors.fill: parent
            renderScale: win.stage.zoom
            surfaceColor: Theme.surface
            barsList: [bar]

            GooeyBar {
                id: bar
                engine: engine
                barId: "bar"
                edge: win.barEdge
                rawPos: 0
                rawLen: win.barEdge === "right" ? engine.h : engine.w

                SiliconBarButton {
                    id: siliconButton
                    objectName: "siliconBarButton"
                    x: Math.round((win.barEdge === "right" ? 340 : tun.iconAlong) - width / 2)
                    y: Math.round((bar.height - height) / 2)
                    vertical: win.barEdge === "right"
                    barRotation: bar.rotation
                    fontFamily: tun.dressAudiowide ? "Audiowide" : "Inter"
                }
            }
        }

        // The shell's notification service, as far as the keep prompt needs it: the watcher posts the prompt through
        // NotificationBus (the hands-on mockup registers this one; a probe step does it for its own run) and the lane's stand-in
        // draws what the scheduler shows with the real ToastEntry.
        NotificationService {
            id: toastSvc
            serverEnabled: false
            registerOnBus: false
            persist: false
            liveSignals: false
            ipcEnabled: false
            configPath: ""
        }
        NotificationStyle {
            id: toastStyle
        }
        GroupPalette {
            id: toastGroups
        }

        // The owner wires the button completely (facts, the `active` flag, click, pulse) and builds the popup.
        SiliconBarOwner {
            id: owner
            engine: engine
            bar: bar
            barId: "bar"
            anchorItem: siliconButton
            service: win.activeService
            familyOverride: tun.family
            secondarySideOverride: win.sideNames[Math.max(0, Math.min(2, Math.round(tun.secondarySide)))]
            sizeScale: tun.sizeScale
            fontFamily: tun.dressAudiowide ? "Audiowide" : "Inter"
        }

        // The toasts' lane, stood in: the stack the scheduler shows, newest first, in the top right corner above the engine.
        Column {
            id: toastLane
            objectName: "toastLane"
            x: scene.implicitWidth - toastStyle.toastWidth - 20
            y: 20
            spacing: 8
            z: 20
            Repeater {
                model: toastSvc.toasts.shown
                delegate: ToastEntry {
                    required property string modelData
                    uid: modelData
                    service: toastSvc
                    style: toastStyle
                    groups: toastGroups
                    cardWidth: toastStyle.toastWidth
                    overlayItem: toastLane
                }
            }
        }
    }

    // ---- STAGE_GRAB=<png>: the stage alone, GRAB_MS after the start, then quit ------------
    readonly property string stageGrab: Quickshell.env("STAGE_GRAB") || ""
    Timer {
        running: win.stageGrab !== ""
        interval: Number(Quickshell.env("GRAB_MS") || 2500)
        onTriggered: scene.grabToImage(r => {
            r.saveToFile(win.stageGrab);
            Qt.quit();
        })
    }

    // ---- the env, applied once the owner exists ------------------------------------------
    Timer {
        running: true
        interval: 0
        onTriggered: win.applyEnv()
    }
    Timer {
        id: secondaryTimer
        interval: 900
        onTriggered: {
            if (win._popup && win._popup.openSecondary)
                win._popup.openSecondary(Quickshell.env("SECONDARY"));
        }
    }
    function applyEnv() {
        const sc = Quickshell.env("SCENARIO") || "";
        if (TL.SCENARIOS.indexOf(sc) >= 0)
            mock.scenario = sc;
        if (Quickshell.env("TIME"))
            mock.timeMs = Number(Quickshell.env("TIME"));
        if ((Quickshell.env("PLAY") || "") === "0")
            mock.playing = false;
        const fam = Quickshell.env("FAMILY") || "";
        if (fam === "blueprint")
            tun.family = 1;
        else if (fam === "material" || fam === "eva")
            tun.family = 0;
        const sd = win.sideNames.indexOf(Quickshell.env("SIDE") || "");
        if (sd >= 0)
            tun.secondarySide = sd;
        if ((Quickshell.env("DRESS") || "") === "audiowide")
            tun.dressAudiowide = true;
        const mc = {};
        (Quickshell.env("MACHINE") || "").split(",").forEach(x => {
            const kv = x.trim().split("=");
            if (kv.length === 2)
                mc[kv[0]] = kv[1];
        });
        if (mc.charge !== undefined)
            mach.pct = Math.max(-1, Math.min(100, Math.round(Number(mc.charge))));
        if (mc.ac !== undefined)
            mach.ac = Math.max(0, ["follow", "on", "off"].indexOf(mc.ac));
        if (mc.dgpu !== undefined)
            mach.dgpu = Math.max(0, ["follow", "asleep", "awake", "busy"].indexOf(mc.dgpu));
        if (mc.helper === "off")
            mach.helperOk = false;
        if (mc.hide !== undefined)
            mach.hide = Math.max(0, win.machineFeatures.indexOf(mc.hide) + 1);
        if (win.probeKind !== "")
            return;
        // hands-on: the prompt's toast has a service to be posted through (a probe registers its own, per run)
        NotificationBus.service = toastSvc;
        if ((Quickshell.env("DIALOG") || "") === "keep-login")
            win.showDialog("keep-login");       // before the popup opens: the machine is already at the keep prompt, as at a login
        if ((Quickshell.env("OPEN") || "1") !== "0")
            owner.open();
        if (Quickshell.env("SECONDARY"))
            secondaryTimer.start();
        if (Quickshell.env("DIALOG"))
            dialogTimer.start();
    }
    // AUTOGPU=1: the GPU zone stepped to Integrated and back every 2.5 s once the popup is open (two arrow presses each way, as a person
    // makes them) -- the switch the user measured with the toolbar's FPS toggle (FPS=1 shows it).
    readonly property bool autoGpu: (Quickshell.env("AUTOGPU") || "") === "1"
    property int _autoGpuSteps: 0
    Timer {
        running: win.autoGpu
        interval: 2500
        repeat: true
        onTriggered: {
            if (!win._popup)
                return;
            if (win._autoGpuSteps === 0)
                mock.externalGpuMode(2);
            else {
                const dir = win._autoGpuSteps % 2 === 1 ? -1 : 1;
                win._popup.stepGpu(dir);
                win._popup.stepGpu(dir);
            }
            win._autoGpuSteps++;
        }
    }
    // DIALOG=<state>: a dialog put up by hand, for a render (the popup's own states,
    // here with the engine's own box around it). The mock is put where that dialog would find it, and the popup's own flags do the rest.
    Timer {
        id: dialogTimer
        interval: 1100
        onTriggered: win.showDialog(Quickshell.env("DIALOG") || "")
    }
    // O19's sampler: where the popup is in its opening and whether the engine has its secondary out, every 8 ms
    property var loginSamples: []
    Timer {
        id: loginSampler
        interval: 8
        repeat: true
        onTriggered: win.loginSamples.push({ phase: engine.thePopup.phase, t: Number(engine.thePopup.t),
                                             ext: Geo.ease(engine.thePopup.easingIndex, Number(engine.thePopup.t), engine.thePopup.overshoot),
                                             child: engine.childOpen })
    }
    function showDialog(name) {
        const p = win._popup;
        // (the keep prompt is the facts' alone: a toast needs no popup -- "keep" and "keep-login" are the machine at the prompt)
        if (!p && name.indexOf("keep") !== 0)
            return;
        const queued = (want, after, pre) => {
            const st = JSON.parse(JSON.stringify(mock._status));
            st.mux.record = { want: want, from: want === "dgpu" ? "hybrid" : "dgpu", state: "queued", why: "", requestedAtMs: Date.now(), bootId: "mock", deadlineMs: null };
            if (want === "hybrid") {
                st.mux.wiringNow = "dgpu";
                st.mux.stored = "dgpu";
            }
            if (pre)
                st.prechecks.mux = pre;
            mock._status = st;
            mock._afterMuxMode = after;
            mock._compute();
            p._muxOpen = true;
        };
        const awaiting = ms => {
            const st = JSON.parse(JSON.stringify(mock._status));
            st.mux.record = { want: "dgpu", from: "hybrid", state: "awaiting-keep", why: "", requestedAtMs: Date.now() - 20000, bootId: "mock", deadlineMs: Date.now() + ms };
            st.mux.wiringNow = "dgpu";
            st.mux.stored = "dgpu";
            mock._status = st;
            mock._compute();
        };
        if (name === "mux-dgpu")
            queued("dgpu", null);
        else if (name === "mux-integrated")
            queued("hybrid", 0);
        else if (name === "mux-smart")
            queued("hybrid", 1);
        else if (name === "mux-hybrid")
            queued("hybrid", 2);
        else if (name === "mux-precheck")
            queued("dgpu", null, { ok: false, why: "No DKMS module for the installed kernel 6.18.54-1-lts" });
        else if (name === "keep" || name === "keep-login")
            awaiting(107500);
        else if (name === "keep-low")
            awaiting(8500);
        else if (name === "confirm" || name === "confirm-6") {
            p._confirmStep = name === "confirm" ? 0 : 1;
            p._confirmHolders = name === "confirm" ? ["steam", "proton"] : ["blender", "steam", "proton", "obs", "krita", "godot"];
            p._confirmOpen = true;
        }
    }

    // =====================================================================
    //  THE FOOTER: the transport, under every tab
    // =====================================================================
    footer: Component {
        Rectangle {
            id: transport
            implicitHeight: transportCol.implicitHeight + 16
            color: "#EAEDF5"
            radius: 16
            border.color: "#CED1D7"
            border.width: 1

            ColumnLayout {
                id: transportCol
                anchors.fill: parent
                anchors.margins: 8
                spacing: 5

                TipRow {
                    tip: "Where the popup's data comes from. mock (the default) is a simulated machine and touches nothing. live builds the REAL service: a click in the popup then changes THIS machine's power profile, GPU mode and charge limit through pkexec and the helper, and the MUX flow (dGPU only, Restart now) and its boot guard are real too. Switching to live takes two clicks within 4 s, and only this switch does it: no environment variable, probe or runner can. The popup is closed when you switch, and the mock's timeline, the Run tab's buttons and the Motion / Sounds volumes (live reads silicon.jsonc's own) are off or inert while live."
                    spacing: 6
                    Label {
                        text: "Data"
                        color: "#5D5D5F"
                        font.family: "Audiowide"
                        font.pixelSize: 14
                    }
                    Button {
                        text: "mock"
                        highlighted: !win.live
                        onClicked: win.useMockService()
                    }
                    Button {
                        text: win.live ? "live" : (win.liveArmed ? "click again for the real machine" : "live")
                        highlighted: win.live || win.liveArmed
                        onClicked: win.realServiceClick()
                    }
                    Item {
                        Layout.fillWidth: true
                    }
                }
                Label {
                    Layout.fillWidth: true
                    visible: win.live
                    wrapMode: Text.WordWrap
                    text: "Live: changes the real profile, GPU mode and charge limit" + (win.liveService ? "" : " (the service has not loaded: the popup shows the mock)")
                    color: "#EC0000"
                    font.family: "Audiowide"
                    font.pixelSize: 12
                }
                TipRow {
                    tip: "Which minute-long machine the mock plays (the Run tab says what each does), and the popup as the bar's button opens and closes it. Picking a scenario starts it from 0 s."
                    spacing: 6
                    Label {
                        text: "Scenario"
                        color: "#5D5D5F"
                        font.family: "Audiowide"
                        font.pixelSize: 14
                    }
                    ComboBox {
                        Layout.fillWidth: true
                        enabled: !win.live
                        model: win.scenarioNames
                        currentIndex: Math.max(0, win.scenarioNames.indexOf(mock.scenario))
                        onActivated: i => win.pickScenario(win.scenarioNames[i])
                    }
                    Button {
                        text: owner.popupMine ? "Close popup" : "Open popup"
                        onClicked: owner.toggle()
                    }
                }
                TipRow {
                    tip: "Play or pause the timeline, and scrub it: the sensors (cores, clock, temperature, the iGPU, the dGPU's state and users) and the battery are read from the scenario at this moment. A scrub fires no battery event; running forward does, as the service would. Off while live: the timeline is the mock's."
                    enabled: !win.live
                    spacing: 6
                    Button {
                        text: mock.playing ? "||" : ">"
                        padding: 4
                        font.pixelSize: 13
                        Layout.preferredWidth: 38
                        onClicked: mock.playing = !mock.playing
                    }
                    Slider {
                        Layout.fillWidth: true
                        from: 0
                        to: win.timelineMs
                        value: mock.timeMs
                        onMoved: mock.timeMs = value
                    }
                    Label {
                        text: (mock.timeMs / 1000).toFixed(1) + " s"
                        color: "#8A8A8C"
                        font.family: "Audiowide"
                        font.pixelSize: 13
                        Layout.preferredWidth: 58
                        horizontalAlignment: Text.AlignRight
                    }
                }
            }
        }
    }

    // =====================================================================
    //  PAGES
    // =====================================================================
    readonly property var _popup: engine.thePopup && engine.popupOwnerId === "silicon" ? engine.thePopup.contentItem : null

    function profileName(i) {
        return ["Quiet", "Balanced", "Performance"][Math.max(0, Math.min(2, i))];
    }
    function gpuName(i) {
        return ["Integrated", "Smart", "Hybrid", "dGPU-only"][Math.max(0, Math.min(3, i))];
    }

    pages: [
        MockupPage {
            id: barPage

            TipGroup {
                title: "Edge"
                blurb: "The bar's edge is chosen at launch, as the stocks mockup has it: BAR=top (the default) or BAR=right. On a side bar the button stacks: its face is laid out in the screen frame and counter-rotated against the bar."
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
                text: "this run: a " + win.barEdge + " bar, the button " + Math.round(siliconButton.width) + " x " + Math.round(siliconButton.height) + " px (in the bar's frame)"
            }
        },
        MockupPage {
            id: scenarioPage

            TipGroup {
                title: "The scenario"
                blurb: win.live ? "LIVE: the real service feeds the popup, so the mock's scenario and every row below that drives it are off. The popup's own panels (Tuning, GPU settings) still open." : (win.scenarioWords[mock.scenario] || "")
            }

            TipGroup {
                title: "The popup"
                blurb: "Open it from the bar's button, then drive it by hand: the package opens the tuning card, the card the GPU's settings."
            }
            TipRow {
                tip: "Open a secondary panel by hand, as a click on the package (tuning) or on the card (GPU settings) does, and close it again. The engine hangs it from the popup on the side the popup asks for."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: "Tuning"
                    enabled: !!win._popup
                    onClicked: win._popup.openSecondary("tuning")
                }
                Button {
                    text: "GPU settings"
                    enabled: !!win._popup
                    onClicked: win._popup.openSecondary("gpu")
                }
                Button {
                    text: "Close it"
                    enabled: !!win._popup && win._popup.secondaryOpen
                    onClicked: win._popup.closeSecondary()
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "Outside changes"
                blurb: "A change made outside the popup (asusctl, a key, cardwire's own CLI): the machine moves, the OSD would be asked for (the log under State shows its request), the scene follows."
            }
            TipRow {
                tip: "The power profile changed outside the popup. The profile's linked values are applied and any hold is dropped, as the service does for the real thing."
                Layout.fillWidth: true
                enabled: !win.live
                spacing: 6
                Label {
                    text: "Profile"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    Layout.preferredWidth: 64
                }
                Button {
                    text: "Quiet"
                    onClicked: mock.externalProfile("quiet")
                }
                Button {
                    text: "Balanced"
                    onClicked: mock.externalProfile("balanced")
                }
                Button {
                    text: "Performance"
                    onClicked: mock.externalProfile("performance")
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "cardwire's mode changed outside the popup (dGPU-only is the MUX's, not cardwire's, so it is not here)."
                Layout.fillWidth: true
                enabled: !win.live
                spacing: 6
                Label {
                    text: "GPU"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    Layout.preferredWidth: 64
                }
                Button {
                    text: "Integrated"
                    onClicked: mock.externalGpuMode(0)
                }
                Button {
                    text: "Smart"
                    onClicked: mock.externalGpuMode(1)
                }
                Button {
                    text: "Hybrid"
                    onClicked: mock.externalGpuMode(2)
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "The charge limit changed outside the popup (asusctl, the old battery module). The firmware acts on 80 and 100 only."
                Layout.fillWidth: true
                enabled: !win.live
                spacing: 6
                Label {
                    text: "Limit"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    Layout.preferredWidth: 64
                }
                Button {
                    text: "80 %"
                    onClicked: mock.externalLimit(true)
                }
                Button {
                    text: "100 %"
                    onClicked: mock.externalLimit(false)
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "The popup's intents"
                blurb: "What the popup's chevrons, switch and cards call, from here. Each moves its target at once and writes after the simulated settle; a refusal animates it back."
            }
            TipRow {
                tip: "The profile row: step one profile down or up (an end of the row does nothing), put the tuning back to the profile's own values, or hold one value away from it (turbo off) to see a TWEAKED profile."
                Layout.fillWidth: true
                enabled: !win.live
                spacing: 6
                Label {
                    text: "Profile"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    Layout.preferredWidth: 64
                }
                Button {
                    text: "<"
                    Layout.preferredWidth: 38
                    onClicked: mock.stepProfile(-1)
                }
                Button {
                    text: ">"
                    Layout.preferredWidth: 38
                    onClicked: mock.stepProfile(1)
                }
                Button {
                    text: "Turbo off"
                    onClicked: mock.setTuning({
                        turbo: false
                    })
                }
                Button {
                    text: "Reset"
                    onClicked: mock.resetTuning()
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "The GPU row: step one mode down or up, or ask for one. Integrated and Smart are refused while apps use the dGPU (the game scenario has some), with the apps named: the popup lists them and asks for a confirmation first."
                Layout.fillWidth: true
                enabled: !win.live
                spacing: 6
                Label {
                    text: "GPU"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    Layout.preferredWidth: 64
                }
                Button {
                    text: "<"
                    Layout.preferredWidth: 38
                    onClicked: mock.stepGpuMode(-1)
                }
                Button {
                    text: ">"
                    Layout.preferredWidth: 38
                    onClicked: mock.stepGpuMode(1)
                }
                Button {
                    text: "Integrated"
                    onClicked: mock.setGpuMode(0, {})
                }
                Button {
                    text: "Smart"
                    onClicked: mock.setGpuMode(1, {})
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "The charge limit switch (the DIP lever): 80 % on, 100 % off."
                Layout.fillWidth: true
                enabled: !win.live
                spacing: 6
                Label {
                    text: "Limit"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    Layout.preferredWidth: 64
                }
                Button {
                    text: "80 %"
                    onClicked: mock.setChargeLimit(true)
                }
                Button {
                    text: "100 %"
                    onClicked: mock.setChargeLimit(false)
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "The MUX flow. dGPU-only is asked for through the popup's own path (a GPU step to dGPU-only): the helper records a request that is applied at the next restart, and Hybrid is the way back. The mock's restart is instant: the new wiring is in and the keep prompt is awaiting its answer. Keep makes it stick, Cancel withdraws a request that waits, and the prompt left alone puts the hybrid wiring back when its time is up."
                Layout.fillWidth: true
                enabled: !win.live
                spacing: 6
                Label {
                    text: "MUX"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    Layout.preferredWidth: 64
                }
                Button {
                    text: "dGPU-only"
                    onClicked: mock.setGpuMode(3, {})
                }
                Button {
                    text: "Hybrid"
                    onClicked: mock.muxRequest("hybrid")
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "The rest of the MUX flow: restart now (the mock's is instant), keep the new wiring, or cancel a request that waits."
                Layout.fillWidth: true
                enabled: !win.live
                spacing: 6
                Item {
                    Layout.preferredWidth: 64
                }
                Button {
                    text: "Restart now"
                    onClicked: mock.muxRebootNow()
                }
                Button {
                    text: "Keep"
                    onClicked: mock.muxKeep()
                }
                Button {
                    text: "Cancel"
                    onClicked: mock.muxCancel()
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "The guard's two ends. Run out the keep window: the keep prompt's deadline goes two seconds ahead, so the guard's revert plays at once -- the record says reverted, Hybrid is back and the keep toast says it is going back (it needs a prompt: ask for dGPU-only, then Restart now). Restart the shell: the mock never reboots, so this is the next shell's start. It looks at the guard's last word again and tells an outcome nobody was told, once, as a notification the manager keeps -- and puts the keep toast up again when a keep prompt is due."
                Layout.fillWidth: true
                enabled: !win.live
                spacing: 6
                Label {
                    text: "Guard"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    Layout.preferredWidth: 64
                }
                Button {
                    text: "Run out the keep window"
                    enabled: mock.gpu.mux.state === "awaiting-keep"
                    onClicked: win.runOutKeepWindow()
                }
                Button {
                    text: "Restart the shell"
                    onClicked: win.restartShell()
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Smart mode kept an app off the dGPU: the data layer's own signal, one of four apps in turn. The shell answers with a desktop notification (Allow always / Ignore) only while the GPU is in Smart, and once per app per session: in any other mode, or for an app already shown, nothing happens."
                Layout.fillWidth: true
                enabled: !win.live
                spacing: 6
                Label {
                    text: "Smart"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    Layout.preferredWidth: 64
                }
                Button {
                    text: "Blocked app"
                    onClicked: win.emitBlockedApp()
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "The system update holding the profile at Performance for as long as it runs, and letting go (PowerBus: hold, release). A hold switches the profile and the caption says who holds it; a manual change takes the profile back and drops every hold."
                Layout.fillWidth: true
                enabled: !win.live
                spacing: 6
                Label {
                    text: "Hold"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    Layout.preferredWidth: 64
                }
                Button {
                    text: "Hold Performance"
                    onClicked: PowerBus.hold("system-update", "performance", "a system update is running")
                }
                Button {
                    text: "Release"
                    onClicked: PowerBus.release("system-update")
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "Refused writes"
                blurb: "Arm one: the NEXT write of that zone fails with the helper's (or the daemon's) words. The target animates back and the caption says why."
            }
            TipRow {
                tip: "Arm a refusal for the next write of that zone, then do the thing (a chevron, the lever, the tuning card): the scene plays the way back and the zone's caption shows the reason in the error colour until the next intent there or ten seconds."
                Layout.fillWidth: true
                enabled: !win.live
                spacing: 6
                Label {
                    text: "Refuse"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    Layout.preferredWidth: 64
                }
                Button {
                    text: "CPU"
                    onClicked: mock.refuseNext = "cpu"
                }
                Button {
                    text: "GPU"
                    onClicked: mock.refuseNext = "gpu"
                }
                Button {
                    text: "Limit"
                    onClicked: mock.refuseNext = "battery"
                }
                Button {
                    text: "MUX"
                    onClicked: mock.refuseNext = "mux"
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "State"
                blurb: "What the mock and the popup believe right now."
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
                text: win.stateText
            }
        },
        MockupPage {
            id: motionPage

            TipGroup {
                title: "The popup right now"
                blurb: "Where the idle ladder stands and what the clock and the director are doing, live. Leave the pointer off the popup and the ladder walks down by itself: alive, calm, halt, and the clock parks."
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
                text: win.motionText
            }
            TipRow {
                tip: "Play the power-on again: the board goes dark and powers on over about a second (the traces from the pack, the chips, then the holograms flicker on), the film the popup plays when it is mostly out. Pressed on a clock the ladder has parked it wakes the ladder first, since a halted popup plays nothing; pressed while the power-on is playing it carries on, a power-on cut short is not restarted. The film speed on the Films tab scales it."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: "Entrance"
                    enabled: !!win._director
                    onClicked: win.replayEntrance()
                }
                Item {
                    Layout.fillWidth: true
                }
            }
        },
        MockupPage {
            id: soundsPage

            TipGroup {
                title: "Audition"
                blurb: "The popup's three tactile sounds, played now at the volumes above and the takes picked under Takes (open the popup first): the synthesised click of the latch, of the DIP switch and of the plug. The latch and the switch click the same either way; the plug has its own sound, and its own take, for the way out. While live the volumes are silicon.jsonc's own."
            }
            TipRow {
                tip: "Plays the sound of that part now, at its configured volume, whether or not the popup is shown and without the debounce: the same call the director's moments make, minus the popup's own rules. A volume of 0 plays nothing at all."
                Layout.fillWidth: true
                GridLayout {
                    Layout.fillWidth: true
                    columns: 2
                    columnSpacing: 6
                    rowSpacing: 6
                    Repeater {
                        model: win.auditions
                        delegate: Button {
                            id: audition
                            required property var modelData
                            Layout.fillWidth: true
                            text: audition.modelData.label
                            enabled: !!win._sounds
                            onClicked: win.auditionSound(audition.modelData.name, audition.modelData.on)
                        }
                    }
                }
            }

            TipGroup {
                title: "Compare the takes"
                blurb: "Each sound has three takes (round 2: dry and small, one click each; make_clicks.py). A row has a button per take: press them in turn to compare, whatever is picked above, at the sound's volume. Pick under Takes; the panel starts on silicon.jsonc's own picks (latch a, dip a, plug c, plug out a)."
            }
            Repeater {
                model: win.takeRows
                delegate: TipRow {
                    id: takeRow
                    required property var modelData
                    tip: "The " + takeRow.modelData.label.toLowerCase() + " in its three takes, one button each, at its configured volume and without the debounce. The take that is picked on the panel above is the one the popup itself plays."
                    Layout.fillWidth: true
                    spacing: 6
                    Label {
                        text: takeRow.modelData.label
                        color: "#8A8A8C"
                        font.family: "Audiowide"
                        font.pixelSize: 14
                        Layout.preferredWidth: 64
                    }
                    Repeater {
                        model: takeRow.modelData.words
                        delegate: Button {
                            id: takeButton
                            required property int index
                            required property string modelData
                            Layout.fillWidth: true
                            text: takeButton.modelData
                            enabled: !!win._sounds
                            onClicked: win.auditionSound(takeRow.modelData.name, takeRow.modelData.on, snd.takes[takeButton.index])
                        }
                    }
                }
            }
        }
    ]

    readonly property string stateText: {
        if (win.live) {
            const sv = win.liveService;
            return "LIVE: the real service feeds the popup; the mock's machine is not read.\n" + (sv ? "profile: " + win.profileName(sv.profileIndex) + "   gpu: " + win.gpuName(sv.gpuMode)
                       + "   battery: " + sv.battery.pct + " %" + (sv.battery.limitOn ? ", limit " + sv.battery.limitPct + " %" : ", no limit") : "the service has not loaded: the popup shows the mock");
        }
        const lines = [];
        const c = mock.cpu, g = mock.gpu, b = mock.battery;
        lines.push(mock.scenario + "   t " + (mock.timeMs / 1000).toFixed(1) + " s" + (mock.playing ? "" : "  (paused)") + "   x" + mock.speed + "   polling: " + mock.idleState);
        lines.push("popup: " + (owner.popupMine ? "open" : "closed") + (win._popup && win._popup.secondaryOpen ? "   secondary: " + win._popup.secondaryKey : "")
                   + "   board: " + (owner.family === 1 ? "Blueprint" : "Material") + ", " + Theme.mode);
        lines.push("bar button: " + Math.round(siliconButton.percent) + " %" + (siliconButton.charging ? " charging" : (siliconButton.plugged ? " on mains" : " on battery"))
                   + (siliconButton.limitOn ? ", cap " + siliconButton.limitPercent : "") + ", " + win.profileName(siliconButton.profile) + (siliconButton.tweaked ? " tweaked" : "")
                   + ", " + win.gpuName(siliconButton.gpuMode) + (siliconButton.gpuInUse ? " in use" : "") + (siliconButton.muxPending ? ", MUX pending" : ""));
        lines.push("profile: " + win.profileName(mock.profileIndex) + (mock.profileTarget !== mock.profileIndex ? " -> " + win.profileName(mock.profileTarget) : "")
                   + (c.tweaked ? "   tweaked" : "") + (c.heldBy !== "" ? "   held by " + c.heldBy : ""));
        lines.push("gpu: " + win.gpuName(mock.gpuMode) + (mock.gpuModeTarget !== mock.gpuMode ? " -> " + win.gpuName(mock.gpuModeTarget) : "")
                   + "   " + (g.dState || "no state") + (g.holders.length > 0 ? "   users: " + g.holders.join(", ") : "")
                   + (g.mux.state !== "" ? "   mux: " + g.mux.state : ""));
        lines.push("battery: " + b.pct + " %  " + b.status + (b.ac ? "  mains" : "  battery") + "   limit " + (b.limitOn ? b.limitPct + " %" : "off")
                   + (mock.chargeLimitTarget !== (b.limitOn ? b.limitPct : 100) ? " -> " + mock.chargeLimitTarget : ""));
        const forced = [];
        if (mach.pct >= 0)
            forced.push("charge " + mach.pct + " %");
        if (mach.ac > 0)
            forced.push(mach.ac === 1 ? "mains in" : "mains out");
        if (mach.dgpu > 0)
            forced.push("dGPU " + ["", "asleep", "awake", "busy"][mach.dgpu]);
        if (!mach.helperOk)
            forced.push("helper not answering");
        if (mach.hide > 0)
            forced.push("no " + win.machineFeatures[mach.hide - 1]);
        if (!mach.muxUnit)
            forced.push("silicon-mux.service not running");
        if (mach.bootWindowS !== Model.MUX_BOOT_WINDOW_S)
            forced.push("boot window " + mach.bootWindowS + " s");
        if (mach.promptWindowS !== Model.MUX_PROMPT_WINDOW_S)
            forced.push("keep window " + mach.promptWindowS + " s");
        if (forced.length > 0)
            lines.push("forced: " + forced.join(", "));
        lines.push("captions: " + mock.caption.cpu + " | " + mock.caption.gpu + " | " + mock.caption.battery);
        const errs = [mock.caption.cpuError, mock.caption.gpuError, mock.caption.batteryError].filter(e => e !== "");
        if (errs.length > 0)
            lines.push("errors: " + errs.join(" | "));
        if (mock.refuseNext !== "")
            lines.push("armed: the next " + mock.refuseNext + " write is refused");
        lines.push("log: " + (win.events.length > 0 ? "\n  " + win.events.join("\n  ") : "nothing yet"));
        return lines.join("\n");
    }

    // =====================================================================
    //  VALUES
    // =====================================================================
    readonly property var lookParams: [
        {
            label: "family",
            prop: "family",
            group: "Board",
            blurb: "The board's look. In the shell silicon.jsonc's look.family picks it; here the panel wins.",
            tip: "Which family the board is drawn in. Material is the shell's own material (the board a raised plateau of the popup's surface, the traces carved grooves that carry the light); Blueprint is a drafting sheet (white paper and blue ink by day, a cyanotype at night). The user kept both in the style round (2026-10-03).",
            val: 0,
            choices: ["Material", "Blueprint"]
        },
        {
            label: "secondary side",
            prop: "secondarySide",
            group: "Secondaries",
            blurb: "Where the popup's secondaries hang: the CPU tuning and GPU settings panels, the restart card and the question about apps on the dGPU -- ONE setting for all four. Not final: it depends on how the shell is assembled. In the shell silicon.jsonc's look.secondarySide picks it; here the panel wins.",
            tip: "Which side of the popup a secondary grows from. Away from the bar is the default: below the popup on a top bar, so the two read as one column. Along the bar, start or end, puts it beside the popup (left or right of it on a top bar, above or below it on a side bar), centred on the part that asked. It moves a secondary that is already out.",
            val: 0,
            choices: ["Away from the bar", "Along the bar, start", "Along the bar, end"]
        },
        {
            label: "popup scale",
            prop: "sizeScale",
            group: "Size",
            blurb: "How large the popup is drawn, on top of its popup ratio (shell.jsonc scale.popups.silicon, 1.35: the user's size). The module's own constant (SiliconBarOwner.sizeScale): Save writes it there.",
            tip: "1 is the shell's own popup size; 1.2 draws the whole popup a fifth larger -- the board, the plates and the text with it -- and asks the engine for that much more room. The layers are made at the size they are shown at, so nothing goes soft. The CPU and GPU panels it opens keep the shell's popup size. 0.5 to 2, the shell's own range for a ratio.",
            val: 1,
            from: 0.5,
            to: 2,
            step: 0.05
        }
    ]

    // The tokens are the theme's (themes/eva.json, light and dark); `val` is the light default. Edits write the
    // theme file of the tree the mockup runs from, so from a sandbox copy the rows are read-only.
    readonly property var siliconColors: [
        {
            label: "Quiet",
            prop: "profileQuiet",
            group: "Profile hues",
            blurb: "A CPU profile as a colour: the hologram, its rim, the trace light, the bar's glyph.",
            tip: "Quiet's hue: the leaf, its trace light and the bar glyph. An alias of the OK green in themes/eva.json; a hex typed here writes the literal over the alias in this mode.",
            val: "#44C145"
        },
        {
            label: "Balanced",
            prop: "profileBalanced",
            group: "Profile hues",
            tip: "Balanced's hue: the scales and their trace light. An alias of the accent blue.",
            val: "#4480F4"
        },
        {
            label: "Performance",
            prop: "profilePerformance",
            group: "Profile hues",
            tip: "Performance's hue: the shock and its trace light. An alias of the strong warn orange.",
            val: "#FF6D12"
        },
        {
            label: "Tweaked rim",
            prop: "profileTweak",
            group: "Profile hues",
            tip: "The second rim hue of a tweaked profile (settings held away from the profile's own): the package's rim and the bar's tweak dot. Magenta because it is the one hue free next to green, blue, orange and cyan.",
            val: "#C838C6"
        },
        {
            label: "Integrated",
            prop: "gpuIntegrated",
            group: "GPU hues",
            blurb: "A GPU mode as a colour: the card's hologram, the bar's GPU glyph.",
            tip: "Integrated's hue: the dGPU is off. An alias of the OK green.",
            val: "#44C145"
        },
        {
            label: "Smart",
            prop: "gpuSmart",
            group: "GPU hues",
            tip: "Smart's hue (the Sierpinski tetrahedron): a cyan of its own, the multilib category's.",
            val: "#00BEC4"
        },
        {
            label: "Hybrid",
            prop: "gpuHybrid",
            group: "GPU hues",
            tip: "Hybrid's hue (the Menger sponge). An alias of the accent blue.",
            val: "#4480F4"
        },
        {
            label: "dGPU-only",
            prop: "gpuDgpu",
            group: "GPU hues",
            tip: "dGPU-only's hue (the Mandelbulb), and the dot of a pending MUX switch. An alias of the strong warn orange.",
            val: "#FF6D12"
        },
        {
            label: "Surface",
            prop: "siliconEvaSurface",
            group: "Material palette",
            blurb: "One slot per material (board_materials.glsl names them). The fields show the mode on screen: switch light / dark in the toolbar to edit the other.",
            tip: "The plateau: the board itself, the card's PCB, the pack's tray and the substrates. An alias of the popup's surface, so the board is cut from the same material.",
            val: "#EAEDF5"
        },
        {
            label: "Bevel",
            prop: "siliconEvaBevel",
            group: "Material palette",
            tip: "The light rim on an edge's lit side, and the DIP lever's own colour.",
            val: "#FFFFFF"
        },
        {
            label: "Deep shadow",
            prop: "siliconEvaShadow",
            group: "Material palette",
            tip: "The deepest shade: a groove's wall, a slot's inside, a part's drop shadow.",
            val: "#A0A6B4"
        },
        {
            label: "Groove floor",
            prop: "siliconEvaGroove",
            group: "Material palette",
            tip: "The floor of a carved trace or ring, under the light that runs in it.",
            val: "#D0D4E0"
        },
        {
            label: "Engraving ink",
            prop: "siliconEvaInk",
            group: "Material palette",
            tip: "The silkscreen's ink (the labels) and what a carved line is mixed toward.",
            val: "#6F7587"
        },
        {
            label: "Sunk part",
            prop: "siliconEvaSunk",
            group: "Material palette",
            tip: "A part set into the board: the slot, the jack, the plug and its cable, the memory chips, the DIP switch's body, and part of the GPU die.",
            val: "#D6DAE5"
        },
        {
            label: "Cell well",
            prop: "siliconEvaWell",
            group: "Material palette",
            tip: "The well of a battery cell, the dark the charge lies in.",
            val: "#D0D4E0"
        },
        {
            label: "Metal",
            prop: "siliconEvaMetal",
            group: "Material palette",
            tip: "The terminals and the card's latch.",
            val: "#C4C9D6"
        },
        {
            label: "Paper",
            prop: "siliconBlueprintPaper",
            group: "Blueprint palette",
            blurb: "The drafting sheet: white paper and blue ink by day, a cyanotype by night.",
            tip: "The sheet itself.",
            val: "#F5F8FD"
        },
        {
            label: "Ink",
            prop: "siliconBlueprintInk",
            group: "Blueprint palette",
            tip: "The drawn lines and the lettering.",
            val: "#1F4FA6"
        },
        {
            label: "Faint ink",
            prop: "siliconBlueprintFaint",
            group: "Blueprint palette",
            tip: "Secondary lines and the shading's hatching.",
            val: "#9EB5DE"
        },
        {
            label: "Grid",
            prop: "siliconBlueprintGrid",
            group: "Blueprint palette",
            tip: "The sheet's ruled grid.",
            val: "#DAE4F4"
        },
        {
            label: "Face wash",
            prop: "siliconBlueprintWash",
            group: "Blueprint palette",
            tip: "The light fill laid over a part's faces.",
            val: "#E6EDF8"
        },
        {
            label: "Material window",
            prop: "siliconEvaWindow",
            group: "7-segment displays",
            blurb: "The board's seven-segment displays: the glass the digits are lit on, the unlit segments faint in it, and the module's frame. One set per family; the fields show the mode on screen.",
            tip: "Material's display window, the dark glass a lit digit sits on. Dark in both modes: a lit segment needs a dark ground to read against. A literal in themes/eva.json (light #262A35; the dark mode has its own).",
            val: "#262A35"
        },
        {
            label: "Material ghost",
            prop: "siliconEvaGhost",
            group: "7-segment displays",
            tip: "Material's unlit segments, faintly visible in the window so a display with few digits still reads as a seven-segment display. A shade lighter than the window; the closer it is to the window the emptier a display looks.",
            val: "#3B4150"
        },
        {
            label: "Material bezel",
            prop: "siliconEvaBezel",
            group: "7-segment displays",
            tip: "Material's display module frame, the plastic the window is sunk into. A literal in themes/eva.json.",
            val: "#9CA3B5"
        },
        {
            label: "Blueprint window",
            prop: "siliconBlueprintWindow",
            group: "7-segment displays",
            tip: "The Blueprint family's display window: a deep navy glass in both modes, so a lit digit reads on the pale day sheet as well as on the cyanotype.",
            val: "#13224A"
        },
        {
            label: "Blueprint ghost",
            prop: "siliconBlueprintGhost",
            group: "7-segment displays",
            tip: "The Blueprint family's unlit segments, faint in its window. Lighter than the window, darker than a lit digit.",
            val: "#2E4880"
        },
        {
            label: "Blueprint bezel",
            prop: "siliconBlueprintBezel",
            group: "7-segment displays",
            tip: "The Blueprint family's display module frame. In light mode the same value as the Blueprint face wash.",
            val: "#E6EDF8"
        },
        {
            label: "Material glass",
            prop: "siliconEvaGlass",
            group: "7-segment displays",
            tip: "Material's smoked glass: what it lets through, multiplied into the lit segments (a darker light, a little more saturated) and into the window and the unlit segments seen through it. A lighter tint lets more light through; white would take none away. Dimmer than the old bare segments by design (the user found them too bright): the render gate wants the lit segments at least 25 % below the old ones and still 3:1 against the window. A literal in themes/eva.json (light #C2C9D6; the dark mode has its own).",
            val: "#C2C9D6"
        },
        {
            label: "Blueprint glass",
            prop: "siliconBlueprintGlass",
            group: "7-segment displays",
            tip: "The Blueprint family's smoked glass, drawn: the same filter (what it lets through, multiplied into the lit ink, the window and the unlit segments) under a fine hatch and a pane outline that are drawn in the sheet's own inks. A literal in themes/eva.json.",
            val: "#BEC8DA"
        },
        {
            label: "Lock amber",
            prop: "siliconLock",
            group: "Charge limit lock",
            blurb: "The lock bar that closes over the 4th cell when the charge limit is on. Shared by both families.",
            tip: "The lock bar's hazard stripes and the hue of its screws: the theme's warn amber. An alias of warn in themes/eva.json (the light value, #FF6D12, is shown here); a hex typed here writes the literal over the alias in this mode.",
            val: "#FF6D12"
        },
        {
            label: "Gold",
            prop: "siliconGold",
            group: "Card and memory",
            blurb: "Shared by both families.",
            tip: "The GPU card's gold fingers and the HDMI port's contacts. A literal in themes/eva.json.",
            val: "#D6A93C"
        },
        {
            label: "Memory",
            prop: "siliconMemory",
            group: "Card and memory",
            tip: "The RAM's hue: its lit chips and its display's segments. Catppuccin Latte's pink in light mode (Mocha's in dark).",
            val: "#EA76CB"
        },
        {
            label: "Ribbon film",
            prop: "siliconRibbonFilm",
            group: "Display ribbon",
            blurb: "The flat cable that carries the picture from the GPU to the display connector: a phone's flex cable lying in the board's plane, quiet (it fills the corner, it is not a centrepiece) and carrying no light. Shared by both families.",
            tip: "The ribbon cable's film, a muted low-saturation amber (Kapton, quieted): the ground the conductors are laid in. In Material it is mixed over the board's surface (0.8), in Blueprint it tints the hatched film (0.45). The cable of the AC adapter is the model for how quiet it is.",
            val: "#DBC9A0"
        },
        {
            label: "Ribbon copper",
            prop: "siliconRibbonCopper",
            group: "Display ribbon",
            tip: "The ribbon's conductors, quiet copper lines laid in the film and running concentric through its bends. Material paints them in this colour; Blueprint draws them as ink lines and ignores it.",
            val: "#B58F6A"
        },
        {
            label: "Material latch",
            prop: "siliconEvaLatch",
            group: "Display connector",
            blurb: "The display connector's flip-lock bar, the small latch along its top that locks and releases the ribbon.",
            tip: "Material's flip-lock bar: dark plastic, as a real FPC connector's actuator. An alias of the family's display window in themes/eva.json (a hex typed here writes the literal over the alias in this mode).",
            val: "#262A35"
        },
        {
            label: "Blueprint latch",
            prop: "siliconBlueprintLatch",
            group: "Display connector",
            tip: "The Blueprint family's flip-lock bar: filled in the deep ink of the display windows, a lip line drawn along its front. An alias of the Blueprint window in themes/eva.json.",
            val: "#13224A"
        }
    ]

    readonly property var machineParams: [
        {
            label: "charge",
            prop: "pct",
            group: "Machine",
            blurb: "The machine at will: what the timeline's machine is, overridden. Each knob takes effect at once and plays what the machine's own change would -- an AC change plugs the jack and pulses the pack, a wake reports the D-state.",
            tip: "The pack's charge, 0 to 100 %; -1 follows the timeline. The status follows from it and the plug as the firmware's does: charging below the limit, full at 100, and 'Not charging' on the mains at or over the 80 % limit (the caption then says it is held at 85 %, that the limit does not drain it: switch the limit on in the intents below, then force 85; at 80 or 81 it reads limited to 80 %). Leaving full for a charge pulses the pack.",
            val: -1,
            from: -1,
            to: 100,
            step: 1
        },
        {
            label: "mains",
            prop: "ac",
            group: "Machine",
            tip: "The mains: follow the timeline, or force it plugged in or unplugged. Changing it plugs or unplugs the jack and fires the machine's own events: a charge starting or stopping pulses the pack (below full), and the mains changing is reported.",
            val: 0,
            choices: ["follow the timeline", "plugged in", "unplugged"]
        },
        {
            label: "dGPU",
            prop: "dgpu",
            group: "Machine",
            tip: "Where the dGPU stands: follow the timeline, asleep (D3cold), awake with nobody on it (D0, and no readings: the service asks nvidia-smi only while a real user holds the card), or busy (D0 with steam and proton on it, and the card's own readouts). A change reports the D-state, as the machine's own does.",
            val: 0,
            choices: ["follow the timeline", "asleep", "awake, nobody on it", "busy"]
        },
        {
            label: "HDMI display",
            prop: "hdmi",
            group: "Machine",
            tip: "An external display is connected to the NVIDIA card's HDMI port (the fact display.hdmi): an HDMI plug sits in the card's bracket and its cable runs off the board and fades. It unplugs and fades first when the card leaves (GPU mode Integrated), before the lift and the scatter, and comes back after the card has seated. A DisplayLink dock or a USB-C display is not this fact, so it has no switch: the cable is only ever the HDMI port's. Off by default: nothing is connected.",
            val: false
        },
        {
            label: "helper answers",
            prop: "helperOk",
            group: "Machine",
            tip: "Off: the silicon helper is installed but its status fails (the mock says it speaks another protocol). The CPU zone and the charge limit say why, and every intent for them is refused with the reason in the caption's error -- unlike 'helper installed' below, which is the helper not being there at all.",
            val: true
        },
        {
            label: "hide a feature",
            prop: "hide",
            group: "Machine",
            tip: "A kernel without a knob: hides one of the status's features (profile, epp, turbo, governor, maxPerfPct, caps, chargeLimit, mux), one at a time. The popup hides what a kernel does not have, and the intent for it is refused in words.",
            val: 0,
            choices: ["none"].concat(win.machineFeatures)
        },
        {
            label: "MUX unit running",
            prop: "muxUnit",
            group: "The MUX guard",
            blurb: "What the helper's MUX flow depends on and how long it waits: the mock plays the guard of the real machine (silicon-mux.service writes the queued change at shutdown, the boot guard waits for a click on Keep).",
            tip: "Off: silicon-mux.service is not running. The dGPU-only direction's pre-check fails with the helper's own words and a NEW request in either direction is refused with them (a queued change would never be written at shutdown): the restart card says dGPU only cannot go ahead.",
            val: true
        },
        {
            label: "boot window s",
            prop: "bootWindowS",
            group: "The MUX guard",
            tip: "How long a new wiring waits after the boot for a click on Keep, seconds (the helper's own is 300). The mock's restart puts the deadline this far ahead; the keep toast, once it is on screen, then shortens it to its own window.",
            val: 300,
            from: 10,
            to: 600,
            step: 10
        },
        {
            label: "keep window s",
            prop: "promptWindowS",
            group: "The MUX guard",
            tip: "How long the keep toast waits for an answer once it is on screen, seconds (the helper's own is 120): the drain of its card. Shorten it to watch the guard put Hybrid back without waiting two minutes, or use 'Run out the keep window' on the Scenario page.",
            val: 120,
            from: 10,
            to: 300,
            step: 10
        }
    ]

    readonly property var memoryParams: [
        {
            label: "override memory",
            prop: "memOverride",
            group: "Memory",
            blurb: "The board's RAM display and its chips. The scenarios move the RAM between about 30 and 90 %; this row pins it by hand.",
            tip: "On: the memory fact (the mock's `memoryOverride`) is the row below instead of the scenario's, so the board's RAM display and its chips follow it together. Off: the scenario's memory.",
            val: false
        },
        {
            label: "RAM in use %",
            prop: "memUsedPct",
            group: "Memory",
            tip: "How much of the RAM is in use, per cent: the RAM's chips fill with it. Only while 'override memory' is on. 40 sits a little over the desk scenario's third.",
            val: 40,
            from: 0,
            to: 100,
            step: 1
        }
    ]

    readonly property var deviceParams: [
        {
            label: "playing",
            prop: "playing",
            group: "Timeline",
            blurb: "The scenario runs as a loop a minute long; the footer scrubs it.",
            tip: "Whether the timeline advances by itself. Off holds the machine at the scrubbed moment, which is what a render or a long look wants.",
            val: true
        },
        {
            label: "speed",
            prop: "speed",
            group: "Timeline",
            tip: "How fast the timeline runs against the clock. The battery scenarios are already time-lapses (a whole discharge in under a minute), so 1 is the pace the events were written for; faster skips to the interesting part.",
            val: 1,
            from: 0.25,
            to: 8,
            step: 0.25
        },
        {
            label: "settle ms",
            prop: "settleMs",
            group: "The simulated device",
            blurb: "What the real service does between a click and the machine: a short settle, then a write.",
            tip: "How long an intent waits for a newer one before the write goes out (the real service's is 300 ms). Raise it to watch the scene sit at its target while nothing has happened yet.",
            val: 300,
            from: 0,
            to: 2000,
            step: 10
        },
        {
            label: "write ms",
            prop: "writeMs",
            group: "The simulated device",
            tip: "How long the write itself takes (pkexec and the helper, in the real thing). The facts, and so the bar button, change when it lands.",
            val: 150,
            from: 0,
            to: 2000,
            step: 10
        },
        {
            label: "helper installed",
            prop: "helperPresent",
            group: "Absent parts",
            blurb: "What the popup shows when a part of the machine is missing.",
            tip: "Off: the silicon helper is not installed. The CPU zone and the charge limit grey out with their reason and every intent for them is refused in words.",
            val: true
        },
        {
            label: "cardwire running",
            prop: "cardwirePresent",
            group: "Absent parts",
            tip: "Off: cardwire is not running. The GPU zone greys out with its reason and its intents are refused.",
            val: true
        }
    ]

    readonly property var barParams: [
        {
            label: "along",
            prop: "iconAlong",
            group: "Placement",
            blurb: "The button in the bar: the profile glyph, the battery's figure and the GPU's card, mirrored about the figure.",
            tip: "Where the button sits along a top bar, px (the mockup's own placement; a right bar fixes it). The popup centres on it, kept inside the screen. The default leaves room for a secondary on either side of the popup (the secondary side setting).",
            val: 750,
            from: 120,
            to: 1380,
            step: 1
        },
        {
            label: "Audiowide",
            prop: "dressAudiowide",
            group: "Type",
            blurb: "The face the button and the popup are dressed in.",
            tip: "Dress the button's figure and the popup's text in Audiowide instead of Inter. Inter is the module default (CLAUDE.md); Audiowide has no tabular figures, so every figure sits in a slot sized by its template either way.",
            val: false
        }
    ]

    readonly property var buttonParams: [
        {
            label: "faded",
            prop: "gpuFadeAlpha",
            group: "GPU glyph",
            blurb: "The GPU's mode as one glyph on the figure's far side from the profile glyph, as the GPU sits apart from the CPU on the board: a feather (Integrated), a lightbulb (Smart), layers (Hybrid), fire (dGPU-only), each in its mode's hue. Lit while something real is on the card (dGPU-only always: it is the display), faded when nothing is, the feather always at full strength (the iGPU is the one drawing), and breathing in dGPU-only's hue while a MUX switch waits. Use the Machine tab's dGPU switch: busy lights it, awake and asleep fade it.",
            tip: "How present the glyph is with nothing on the card, 0..1. Asleep and awake-but-idle read the same: it is the use that counts. 0.42 stays readable next to the figure and is plainly not lit.",
            val: 0.42,
            from: 0.1,
            to: 1,
            step: 0.01
        },
        {
            label: "glyph flourish",
            prop: "gpuFlourish",
            group: "GPU glyph motion",
            blurb: "Each mode's glyph does what its object does: the feather is caught by a gust (held by its foot, the free end blown over, shivering, then whipping back), the bulb has its idea (dips, pops, three rays out and back), the stack opens (the upper slab lifts, drops and springs), the fire flares (squats, licks up, two embers). It plays when the pointer comes onto THIS glyph (not the pill: the profile glyph has its own zone), when a mode's glyph arrives, and, a little harder, when the card wakes; going idle only fades. Nothing runs at rest. Its length is the Face tab's flourish length (each glyph its own share of it).",
            tip: "Off, the glyph still changes with the mode and fades with the card, plainly. The icon flourish's master switch (Face) turns this off too.",
            val: true
        },
        {
            label: "light",
            prop: "gpuLitMs",
            group: "GPU glyph motion",
            tip: "How long the glyph takes to light up when the card comes into use, and to fade when it goes idle, ms.",
            val: 420,
            from: 100,
            to: 2000,
            step: 10
        },
        {
            label: "pad along",
            prop: "padAlong",
            group: "Face",
            blurb: "The room round the pill: hit area only (round 3 took the hover plate away; hovering shades the pill itself).",
            tip: "Space either side of the face along the bar, px.",
            val: 6,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "pad across",
            prop: "padAcross",
            group: "Face",
            tip: "Space either side of the face across the bar, px. The pill is 32 px high on a 40 px bar, so 3 leaves it with air above and below.",
            val: 3,
            from: 0,
            to: 8,
            step: 1
        },
        {
            label: "pulse",
            prop: "pulseMs",
            group: "Motion",
            blurb: "Two clocks, both stepped or eased as fractions, never a colour animation.",
            tip: "Length of the one simple coloured pulse a battery event plays (full and charge start green, low and charge stop red), ms.",
            val: 1600,
            from: 200,
            to: 3000,
            step: 10
        },
        {
            label: "colour fade",
            prop: "colourMs",
            group: "Motion",
            tip: "How long the charge's colour takes to change when the state does (plugged in: grey to green; unplugged: back), ms. The same both ways, so the fade reads as a fade and not a switch. Round 3: 600 -> 1400, with the pulse it travels with.",
            val: 1400,
            from: 100,
            to: 3000,
            step: 50
        },
        {
            label: "spark life, shortest",
            prop: "sparkLifeMin",
            group: "Motion",
            tip: "The shortest life of a spark of the plug-in burst, ms. Each spark draws its life between this and the longest; the drag is unchanged, so a longer life is a longer linger, not a farther flight.",
            val: 2000,
            from: 500,
            to: 5000,
            step: 100
        },
        {
            label: "spark life, longest",
            prop: "sparkLifeMax",
            group: "Motion",
            tip: "The longest life of a spark, ms.",
            val: 3200,
            from: 500,
            to: 6000,
            step: 100
        },
        {
            label: "breath",
            prop: "breathMs",
            group: "Motion",
            tip: "Length of one breath of the GPU's glyph while a MUX switch waits for its restart, ms. The breath is stepped at 15 frames a second: the engine has no damage regions, so a smooth one would redraw the whole bar for one small glyph.",
            val: 2400,
            from: 800,
            to: 6000,
            step: 100
        },
        {
            label: "icon flourish",
            prop: "flourishEnabled",
            group: "Flourish",
            blurb: "The profile glyph plays a little motion when something happens -- a profile change, a heavy session starting or clearing, the load swinging -- and when the pointer comes onto IT (once per entry, the rule for every bar glyph's flourish; the pointer on the GPU's glyph plays that one's, under GPU glyph). Nothing runs at rest. The leaf sways on its stem; the scales throw a weight from the left pan to the right, which drops under it and stands tipped until the weight melts away; the bolt's ink runs off downward, narrowing to a point, and a new charge strikes in from above point first, landing with a swell and a bob.",
            tip: "Master switch for both glyphs' flourishes. Off, the two glyphs only change and fade (the charge events' ring and sparks are not part of it and play either way).",
            val: true
        },
        {
            label: "on the CPU's load",
            prop: "flourishLoad",
            group: "Flourish",
            tip: "The part to judge: the glyph's motion when a heavy session starts (hard), when it has cleared (gently) and while the load swings. Off, only the profile's change and the pointer play it. A session is a load held for 'hold' seconds, so a spike starts nothing.",
            val: true
        },
        {
            label: "length",
            prop: "flourishMs",
            group: "Flourish",
            tip: "How long one flourish plays, ms: the bulb's length, and every other glyph runs its own share of it (leaf 1.7, scales 2, bolt 1.25, feather 1.5, layers 0.95, fire 1.1). The motion is damped inside it.",
            val: 900,
            from: 300,
            to: 2500,
            step: 50
        },
        {
            label: "hold",
            prop: "flourishHoldMs",
            group: "Flourish",
            tip: "How long the load has to stand heavy (70 %) to count as a session starting, or calm (25 %) after one to count as cleared, ms. 8000 keeps a spike or a build's pause from playing it.",
            val: 8000,
            from: 500,
            to: 30000,
            step: 500
        }
    ]

    readonly property var layoutParams: [
        {
            label: "margin",
            prop: "margin",
            group: "Plates",
            blurb: "The two name plates (a zone's caption and its arrows, and the GPU's figures while its card is awake) are flat in screen space, each standing on its foot just above the top edge of ITS hologram: a row that comes (a tail, the figures) pushes the head up. The CPU's clock, usage and temperature are displays on the board now, like the battery's.",
            tip: "The popup's padding, px: a plate never rises above it (the tallest plate, the GPU's with its figures and a tail, stands about 56 px over the top edge of its hologram). 12 is the shell's popup padding on every side.",
            val: 12,
            from: 0,
            to: 32,
            step: 1
        },
        {
            label: "gap to hologram",
            prop: "plateGap",
            group: "Plates",
            tip: "How far the foot of a plate's text stands above the top edge of its hologram's plane, px (the plane's corner marks are about 4 px inside that edge, and a line of text has a few px of room under its glyphs). The plate stands on this line whatever rows it has, so a tail appearing under the name moves the name up and never into the hologram. 4 puts the text about 12 px over the corner marks; 0 as close as the plane's own edge.",
            val: 4,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "CPU plate",
            prop: "cpuPlateWidth",
            group: "Plates",
            tip: "Width of the CPU plate, px: the tail's room, centred over the CPU hologram. The arrows' span is fixed, so the arrows hold still whatever the caption says; a tail wider than the plate is elided and its words are a hover tip.",
            val: 240,
            from: 120,
            to: 400,
            step: 2
        },
        {
            label: "GPU plate",
            prop: "gpuPlateWidth",
            group: "Plates",
            tip: "Width of the GPU plate, px, centred over the card's hologram. Wider than the CPU's because its figures are four (use, temperature, power, memory) and its tail names the apps using the card.",
            val: 300,
            from: 120,
            to: 460,
            step: 2
        },
        {
            label: "across",
            prop: "errorTagDx",
            group: "Battery error tag",
            blurb: "A refused charge-limit write (or a kernel without one) puts its reason in a small carved tag beside the DIP switch, for as long as the error stands: the Run tab's Machine group (hide: chargeLimit) and a click on the lever show it. It hangs from the switch's near right corner, below the jack.",
            tip: "How far right of the switch's near right corner the tag's left edge stands, px (negative is left). It must clear the cells, the displays and the switch itself; the plug's cable runs through the lower right when the mains are in.",
            val: 6,
            from: -120,
            to: 200,
            step: 1
        },
        {
            label: "down",
            prop: "errorTagDy",
            group: "Battery error tag",
            tip: "How far below that corner the tag's top edge stands, px (negative is up). 22 puts it just under the jack and its DC IN label.",
            val: 22,
            from: -60,
            to: 120,
            step: 1
        },
        {
            label: "widest",
            prop: "errorTagMaxWidth",
            group: "Battery error tag",
            tip: "The widest the tag grows, px. Words that do not fit wrap to two lines and are elided after them; the whole text is a hover tip. 160 keeps clear of most of the plug's cable.",
            val: 160,
            from: 80,
            to: 400,
            step: 2
        },
        {
            label: "title",
            prop: "headSize",
            group: "Type",
            blurb: "Inter, or Audiowide when the Bar tab dresses it. Every figure sits in a fixed slot sized by its template, so a digit ticking over moves nothing.",
            tip: "Size of a caption's head (Balanced, Hybrid, On battery), px. 16 is the shell's title size.",
            val: 16,
            from: 10,
            to: 24,
            step: 1
        },
        {
            label: "body",
            prop: "bodySize",
            group: "Type",
            tip: "Size of a caption's second line, px. 12 is the shell's body size. (The restart card and the holders question are secondaries since R5 D1, and set their words in the secondaries' own sizes.)",
            val: 12,
            from: 9,
            to: 18,
            step: 1
        },
        {
            label: "figures",
            prop: "figureSize",
            group: "Type",
            tip: "Size of the readouts' figures under each caption, px. 11 is the shell's figure size (10 in compact views).",
            val: 11,
            from: 8,
            to: 16,
            step: 1
        }
    ]

    readonly property var directorParams: [
        {
            label: "film speed",
            prop: "speed",
            group: "Films",
            blurb: "A profile change lifts the package, turns it a quarter per step and sets it down; a GPU change slides the card out of its slot or back, or de-rezzes one hologram into the next. The curves are the style round's films (MotionScripts.js); these are how fast they play.",
            tip: "How fast the films play, as a multiple of their own time. 1 is the pace the user picked in the style round; the live values (loads, charge, flow) have their own time constants and are not scaled by it.",
            val: 1,
            from: 0.25,
            to: 3,
            step: 0.05
        },
        {
            label: "rewind speed",
            prop: "rewindSpeed",
            group: "Films",
            tip: "How fast a film plays the way back, as a multiple of the films' time: a write the helper refused, or a step undone in the air. 1 plays it as it came.",
            val: 1,
            from: 0.25,
            to: 3,
            step: 0.05
        },
        {
            label: "hold at",
            prop: "holdAt",
            group: "The card's wait",
            blurb: "Integrated is chosen while apps still use the dGPU: cardwire blocks only NEW opens, so the card is unlatched and waits half-way out until the last of them has exited. The game scenario has such apps.",
            tip: "How far into the card's way out (seconds of its film) it waits for the apps that still use the dGPU. Short and it barely moves; long and it hangs out of the slot looking half done.",
            val: 0.55,
            from: 0,
            to: 1.5,
            step: 0.05
        },
        {
            label: "bridge",
            prop: "bridgeS",
            group: "Carried-on lift",
            blurb: "A second step the same way while the package is in the air carries the one lift on toward the further profile: one lift, one longer turn.",
            tip: "The longer turn is entered where its quarter turn equals the one the package has now; the two lifts differ a little, and that difference decays over this many seconds instead of jumping.",
            val: 0.2,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "cores",
            prop: "coresS",
            group: "Eased values",
            blurb: "What follows the sensors is eased, never stepped: each value moves toward its fact with one time constant, so a sample that jumps is a glow that swells.",
            tip: "Time constant of the 16 cores' glow, the CPU's load, the graphics tile and the dGPU's utilisation, seconds. The service reads the sensors once a second and the mock every quarter second, so a constant shorter than that steps visibly.",
            val: 0.3,
            from: 0.05,
            to: 2,
            step: 0.05
        },
        {
            label: "charge fill",
            prop: "fillS",
            group: "Eased values",
            tip: "Time constant of the battery cells' fill, seconds. The charge moves in about one percent steps, which a slow ease turns into a tide.",
            val: 0.8,
            from: 0.05,
            to: 3,
            step: 0.05
        },
        {
            label: "flow",
            prop: "flowS",
            group: "Eased values",
            tip: "Time constant of the watts the light on the traces follows, seconds. The battery's power reading is noisy; this is what keeps the light from flickering with it.",
            val: 0.4,
            from: 0.05,
            to: 3,
            step: 0.05
        },
        {
            label: "card awake",
            prop: "awakeS",
            group: "Eased values",
            tip: "Time constant of the card's wakefulness, seconds: it is dark while the dGPU sleeps and lights when something wakes it, which the facts report as a step.",
            val: 0.35,
            from: 0.05,
            to: 2,
            step: 0.05
        },
        {
            label: "tweak rim",
            prop: "tweakS",
            group: "Eased values",
            tip: "Seconds the package's tweak rim takes for its whole travel, in or out, when the profile becomes tweaked or stops being (it moves at a constant rate, not by a time constant).",
            val: 0.35,
            from: 0.05,
            to: 2,
            step: 0.05
        },
        {
            label: "event",
            prop: "eventS",
            group: "Eased values",
            tip: "How long a battery event's age runs, seconds. The event is one calm pulse (55 mm/s, gone at 220 mm, so 4.0 s) running along the traces from the pack while the passive pulse trains fade out under it and come back as it fades. 4.0 is its whole life: below that the event is cut short and the trains jump back, above it nothing more happens but the popup staying awake. The speed and the reach are the glow's constants (tools/dev/silicon_event_walk.js PULSE), not knobs.",
            val: 4.0,
            from: 0.5,
            to: 8,
            step: 0.1
        },
        {
            label: "charge limit lock",
            prop: "lockSeconds",
            group: "Eased values",
            tip: "Seconds the charge limit's lock takes to engage once the DIP lever has landed at 80, and to release when the lever leaves it. The bar and the padlock's shackle are both drawn from one fraction that moves at a constant rate over this time; film speed does not scale it. 0.34 is the pace the lock was designed at (MotionScripts.LOCK_SECONDS).",
            val: 0.34,
            from: 0.1,
            to: 2,
            step: 0.02
        }
    ]

    readonly property var clockParams: [
        {
            label: "CPU, Quiet",
            prop: "cpuTempoQuiet",
            group: "CPU pulse train",
            blurb: "The light that runs on the traces toward the package. Tempo is cycles per second, integrated, so a change of load changes the SPEED of what is in flight and never jumps a phase.",
            tip: "The pulse train's base tempo in Quiet, cycles per second. Quiet to Performance is the scene's package quarter 0 to 2, so the tempo glides through a profile change.",
            val: 0.55,
            from: 0.1,
            to: 2,
            step: 0.05
        },
        {
            label: "CPU, Performance",
            prop: "cpuTempoPerformance",
            group: "CPU pulse train",
            tip: "The base tempo in Performance, cycles per second. 0.9 is what the films ran at, between the two.",
            val: 1.1,
            from: 0.1,
            to: 2,
            step: 0.05
        },
        {
            label: "at no load",
            prop: "cpuLoadSlow",
            group: "CPU pulse train",
            tip: "What the base tempo is multiplied by when the CPU is idle. Under 1 the traces run slow while nothing happens.",
            val: 0.6,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "at full load",
            prop: "cpuLoadFast",
            group: "CPU pulse train",
            tip: "What the base tempo is multiplied by when every core is busy; the multiplier goes linearly between the two.",
            val: 1.4,
            from: 0,
            to: 3,
            step: 0.05
        },
        {
            label: "dGPU, idle",
            prop: "gpuTempoIdle",
            group: "dGPU pulse train",
            blurb: "The pulse train out of the card's slot, while the card is awake.",
            tip: "Tempo with the dGPU awake and doing nothing, cycles per second.",
            val: 0.5,
            from: 0.1,
            to: 3,
            step: 0.05
        },
        {
            label: "dGPU, busy",
            prop: "gpuTempoBusy",
            group: "dGPU pulse train",
            tip: "Tempo at full utilisation, cycles per second.",
            val: 1.4,
            from: 0.1,
            to: 3,
            step: 0.05
        },
        {
            label: "base",
            prop: "flowBase",
            group: "Battery flow",
            blurb: "The light along the copper between the pack, the jack and the chips, in mm per second.",
            tip: "The slowest the flow runs, whatever the draw: a floor that keeps the copper alive at rest.",
            val: 14,
            from: 0,
            to: 60,
            step: 1
        },
        {
            label: "per watt",
            prop: "flowPerWatt",
            group: "Battery flow",
            tip: "How much faster the flow runs per watt flowing, either way (charging or draining).",
            val: 0.5,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "cap",
            prop: "flowMax",
            group: "Battery flow",
            tip: "The fastest the flow runs, so a heavy draw cannot make the copper a blur.",
            val: 60,
            from: 10,
            to: 120,
            step: 1
        }
    ]

    readonly property var idleParams: [
        {
            label: "alive tick",
            prop: "aliveMs",
            group: "Clock rates",
            blurb: "The idle ladder's rungs as the popup's clock plays them: alive while the pointer is active, calm after a while without it, halt (the clock stops and presents no frame at all) after a longer one.",
            tip: "The clock's tick while the ladder is alive, ms: 16 is sixty frames a second. The clock rounds it to whole vsyncs of the display (2 on a 120 Hz panel, 1 on a 60 Hz one) and ticks in step with the frames the window presents, so the pacing is even. The phases are integrated from the measured step, so a slower tick changes the smoothness and never the speed of the light on the traces.",
            val: 16,
            from: 8,
            to: 50,
            step: 1
        },
        {
            label: "calm tick",
            prop: "calmMs",
            group: "Clock rates",
            tip: "The clock's tick on the calm rung, ms: 33 is thirty frames a second (rounded to whole vsyncs, like the alive tick). The popup is still on screen; the pointer has been away for the calm time below.",
            val: 33,
            from: 16,
            to: 200,
            step: 1
        },
        {
            label: "rest over",
            prop: "restSeconds",
            group: "Rest and wake",
            blurb: "The scene's live layer (the particles, the holograms' flicker and scan, the pulse trains on the traces, the MUX breath) eases to rest on the way to halt and back on a wake, so the last frame is a still picture with nothing frozen mid-flight.",
            tip: "How long the live layer takes to ease to rest once the ladder halts, seconds. The tempo of the scene's time and phases follows it down; the clock parks when it has arrived and nothing else is moving.",
            val: 1,
            from: 0.1,
            to: 3,
            step: 0.05
        },
        {
            label: "wake over",
            prop: "wakeSeconds",
            group: "Rest and wake",
            tip: "How long the live layer takes to come back when the ladder leaves halt, seconds: the same ramp and the same tempo, so no particle jumps and no brightness steps on the first frame.",
            val: 0.4,
            from: 0.1,
            to: 2,
            step: 0.05
        },
        {
            label: "calm after",
            prop: "calmAfterMs",
            group: "When it goes quiet",
            blurb: "The idle ladder's times (IdleLadder: the module's constants, Save writes them there), bound into the service's ladder. Shorten the first two to watch alive, calm and halt in seconds; the readout under the tabs says where it stands.",
            tip: "How long the open popup goes without pointer activity before the ladder drops from alive to calm, ms (10 s ships). Moving the pointer over the popup, or a fact the scene plays a motion for, puts it back to alive.",
            val: 10000,
            from: 1000,
            to: 60000,
            step: 500,
            promote: { to: "IdleLadder.calmAfterMs" }
        },
        {
            label: "halt after",
            prop: "haltAfterMs",
            group: "When it goes quiet",
            tip: "How long without activity before the ladder halts, ms (30 s ships): the live layer eases out over the rest time, the clock parks and the popup presents no frame at all. It is never before the calm time, so the panel holds it at the calm time.",
            val: 30000,
            from: 1000,
            to: 120000,
            step: 500,
            promote: { to: "IdleLadder.haltAfterMs" }
        },
        {
            label: "halted stats every",
            prop: "statsHaltedMs",
            group: "When it goes quiet",
            tip: "Once halted, how often the CPU / GPU figures are read, ms (2 s ships): every reading runs on this beat (SiliconModel.cadence).",
            val: 2000,
            from: 250,
            to: 10000,
            step: 250,
            promote: { to: "IdleLadder.statsHaltedMs" }
        },
        {
            label: "halted battery every",
            prop: "batteryHaltedMs",
            group: "When it goes quiet",
            tip: "Once halted, and with the popup closed, how often the battery is read, ms, rounded to a whole number of the stats' beats (5 s: the user's).",
            val: 5000,
            from: 250,
            to: 60000,
            step: 250,
            promote: { to: "IdleLadder.batteryHaltedMs" }
        },
        {
            label: "hold in a switch",
            prop: "crossfadeHold",
            group: "Theme switch",
            blurb: "Round 3's rule for a theme switch the board's island does not take (the island off, the clock halted at the ask, the popup still opening). With the island armed the clock is never held and this does nothing.",
            tip: "The part of a light/dark crossfade (its progress, 0..1) the board is held still for, because the still picture over it is that opaque and anything moving under it would be a second copy of itself. 0.4 is the picture at 60 %; 0 never holds, 1 holds the whole fade.",
            val: 0.4,
            from: 0,
            to: 1,
            step: 0.05
        }
    ]

    readonly property var sceneParams: [
        {
            label: "breath",
            prop: "muxBreathS",
            group: "MUX breath",
            blurb: "While a MUX request waits for its restart the GPU hologram breathes: a slow brightness pulse, one hologram and never the whole field. Ask for dGPU-only on the Run tab to see it.",
            tip: "Length of one breath, seconds. 1.6 is well under 3 Hz; a faster one reads as a flicker. The breath runs on the scene's time, so it stops with the clock.",
            val: 1.6,
            from: 0.5,
            to: 4,
            step: 0.1
        },
        {
            label: "depth",
            prop: "muxBreathDepth",
            group: "MUX breath",
            tip: "How far the hologram's brightness falls at the bottom of a breath, as a share of itself (0.45 is a little under half). 0 is no breath at all.",
            val: 0.45,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "lens",
            prop: "lensStrength",
            group: "Holograms",
            blurb: "The circles at each hologram's foot -- the projector lens on the package, the die and the graphics tile: a soft disc and a thin ring. They follow the idle ladder: they fade out with the motion and are gone at halt.",
            tip: "Their strength, as a share of round 2's: 0.5 because the user asked for them fainter (round 3). 0 takes them away, 1 is round 2's look.",
            val: 0.5,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "scales: plinth",
            prop: "fxPlinth",
            group: "Hologram additions",
            blurb: "One switch per addition to the holograms: 1 on, 0 off. The idle ladder takes every one of them out at halt.",
            tip: "CPU, Balanced (the scales). A horizontal base: a rim, an inner ring and a dial of 36 ticks that turns once in 25 s, with a bead that keeps the time on the rim; the far half is fainter. Round 7: the foot stands on it as two round drums, drawn as the iso camera sees a horizontal circle (the same ellipse as the lens rings: 0.577 as tall as wide on the screen), instead of two frontal slabs. 0 reverts it, foot included.",
            val: 1,
            from: 0,
            to: 1,
            step: 1
        },
        {
            label: "shock: scope trace",
            prop: "fxTrace",
            group: "Hologram additions",
            tip: "CPU, Performance (the bolt). A faint oscilloscope trace behind the bolt, with a fainter line a hair below it as a phosphor's echo: two slow sines (0.11 and 0.22 Hz), livelier the busier the CPU, hidden where the bolt is, fading out toward the plane's sides. Replaces round 6's growing ring. 0 reverts to round 5's bolt.",
            val: 1,
            from: 0,
            to: 1,
            step: 1
        },
        {
            label: "fractals: armillary",
            prop: "fxOrbits",
            group: "Hologram additions",
            tip: "GPU, all three fractals (Smart, Hybrid, dGPU only). Three thin rings about the volume: the equator with a dial of 48 ticks, a hoop that precesses once in 25 s and a meridian ring that turns; each carries a bead. The near half of a ring passes in front of the fractal and the far half behind it. Round 7: a ring turning through edge-on (vertical) stays one smooth thin ellipse and no longer jumps. 0 reverts it.",
            val: 1,
            from: 0,
            to: 1,
            step: 1
        },
        {
            label: "beam: data stream",
            prop: "fxStream",
            group: "Hologram additions",
            tip: "Integrated mode's beam. A slow soft swell of light runs down the beam's core from the graphics tile to the ghost card at 2.4 mm/s: smoothly blended levels, the core varying by 22 % and nothing with an edge (round 6's dashes were 6 mm/s and hard-edged; round 7: 'more subtle and serene'). The idle ladder stops it at halt, so a halted beam is round 5's. 0 reverts it.",
            val: 1,
            from: 0,
            to: 1,
            step: 1
        }
    ]

    readonly property var soundParams: [
        {
            label: "latch",
            prop: "latch",
            group: "Volumes",
            blurb: "The sounds' volumes (SiliconSounds: the module's constants, Save writes them there): the next sound reads them. 0.2 ships, since a click is loud next to a notification.",
            tip: "The card's latch, 0 to 1: the click as it seats in its slot and as it lets go. 0 is silent: no process is started at all, and a silent moment does not arm the debounce.",
            val: 0.2,
            from: 0,
            to: 1,
            step: 0.01,
            promote: { to: "SiliconSounds.latchVolume" }
        },
        {
            label: "DIP switch",
            prop: "dip",
            group: "Volumes",
            tip: "The charge-limit lever, 0 to 1: the click as it passes the middle of its travel, either way. 0 is silent.",
            val: 0.2,
            from: 0,
            to: 1,
            step: 0.01,
            promote: { to: "SiliconSounds.dipVolume" }
        },
        {
            label: "plug",
            prop: "plug",
            group: "Volumes",
            tip: "The charger plug, 0 to 1: a scrape that ends in a thunk as it goes in, a sound of its own on the way out. 0 is silent.",
            val: 0.2,
            from: 0,
            to: 1,
            step: 0.01,
            promote: { to: "SiliconSounds.plugVolume" }
        },
        {
            label: "latch take",
            prop: "latchVariant",
            group: "Takes",
            blurb: "Which of the three takes of each of the four files the popup plays (the buttons under Compare the takes play them side by side). The module's constants (SiliconSounds); the user's picks are where this panel starts.",
            tip: "The card's latch: a is a bright tick, b a softer and lower click, c a snap with a little crack on top. All three are one dry click, 4-7 ms long.",
            val: 0,
            choices: ["a  tick", "b  soft click", "c  snap"],
            promote: { to: "SiliconSounds.latchTake", map: ["a", "b", "c"] }
        },
        {
            label: "DIP switch take",
            prop: "dipVariant",
            group: "Takes",
            tip: "The charge-limit lever: a is a tiny high tick, b a soft click, c a snap. Shorter and higher than the latch, so the two never read as one sound.",
            val: 0,
            choices: ["a  tick", "b  soft click", "c  snap"],
            promote: { to: "SiliconSounds.dipTake", map: ["a", "b", "c"] }
        },
        {
            label: "plug take",
            prop: "plugVariant",
            group: "Takes",
            tip: "The charger plug going IN: a is a short scrape ending in a metal tick, b a longer and softer scrape, c a scrape too short to hear and a snap. c ships.",
            val: 2,
            choices: ["a  short scrape", "b  long, soft", "c  snap"],
            promote: { to: "SiliconSounds.plugTake", map: ["a", "b", "c"] }
        },
        {
            label: "plug out take",
            prop: "plugOutVariant",
            group: "Takes",
            tip: "The charger plug coming OUT, a sound of its own with a take of its own: a is a pop with the scrape dying away, b a longer and softer one, c a snap. a ships.",
            val: 0,
            choices: ["a  pop, scrape fades", "b  long, soft", "c  snap"],
            promote: { to: "SiliconSounds.plugOutTake", map: ["a", "b", "c"] }
        },
        {
            label: "debounce ms",
            prop: "debounceMs",
            group: "Debounce",
            blurb: "One sound that a motion could ask for twice in a breath.",
            tip: "A moment repeated within this many ms of the last one that PLAYED plays once, per sound: a lever dragged across its middle and back, a plug that bounces. The first is heard at once (a sound delayed to see whether another follows would be late); 0 lets every one through. 80 ships.",
            val: 80,
            from: 0,
            to: 300,
            step: 10
        }
    ]

    readonly property var particleParams: [
        {
            label: "density knee W",
            prop: "chargeKneeW",
            group: "Charging: how many",
            blurb: "The funnel drawn into the (+) terminal (the (-) one's is the weak one). How many particles there are and how bright.",
            tip: "The charge rate in watts at which 63 % of the field's particle slots are alive: density = 1 - exp(-W / knee). 18 W is where a laptop charger's worth fills most of the funnel; a lower knee fills it at smaller currents, a higher one keeps a trickle sparse. It scales how many live and how strongly, never their life, size or speed.",
            val: 18,
            from: 1,
            to: 100,
            step: 1
        },
        {
            label: "weak pole share",
            prop: "chargeWeak",
            group: "Charging: how many",
            tip: "The share of the density the pole that is NOT this field's main one ((-)) gets: 0 leaves it dark, 1 makes the two equal. 0.40 keeps the main pole (+) the star and the other a quiet echo.",
            val: 0.4,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "alpha",
            prop: "chargeAlpha",
            group: "Charging: how many",
            tip: "A scale on every particle's alpha of this field, on top of the density and the idle ladder's brightness. 1 is as designed; above 1 the soft ones saturate.",
            val: 1,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "life (-) s",
            prop: "chargeLifeMinusS",
            group: "Charging: motion",
            blurb: "How long a charging particle's inward run lasts, at each terminal.",
            tip: "How long one inward run at the (-) terminal lasts, seconds (each particle's own is 0.7 to 1.3 times it). A particle's speed is its reach over its life, so this is the speed knob: shorter is faster. 1.0 is the old module's pace for this field.",
            val: 1,
            from: 0.3,
            to: 4,
            step: 0.1
        },
        {
            label: "life (+) s",
            prop: "chargeLifePlusS",
            group: "Charging: motion",
            tip: "The same at the (+) terminal. 1.0, as it always was.",
            val: 1,
            from: 0.3,
            to: 4,
            step: 0.1
        },
        {
            label: "reach (-) mm",
            prop: "chargeReachMinus",
            group: "Charging: shape",
            blurb: "The charging funnel at each terminal: how far out its mouth is and how wide it opens.",
            tip: "How far out from the (-) terminal's face the funnel's mouth is, mm. 7 keeps it over the courtyard between the pack and the CPU package.",
            val: 7,
            from: 2,
            to: 20,
            step: 0.5
        },
        {
            label: "reach (+) mm",
            prop: "chargeReachPlus",
            group: "Charging: shape",
            tip: "How far out from the (+) terminal's face the funnel's mouth is, mm. 4.4, as the discharge swirl's: the funnel runs straight out along +x now (round 7), where the charger's chokes start 1.9 mm from the face and its first capacitor 6.7 mm, and the board draws them over a particle, so the mouth stays short and narrow enough to be gone before the parts that would hide it. 10 until round 7, when it leaned 45 degrees.",
            val: 4.4,
            from: 2,
            to: 20,
            step: 0.2
        },
        {
            label: "mouth (-) mm",
            prop: "chargeMouthMinus",
            group: "Charging: shape",
            tip: "The funnel's extra radius at its mouth at the (-) terminal, mm: how wide the cone opens. 3.0 (3.6 until round 6: the user found the swirling a bit too much).",
            val: 3,
            from: 0,
            to: 8,
            step: 0.1
        },
        {
            label: "mouth (+) mm",
            prop: "chargeMouthPlus",
            group: "Charging: shape",
            tip: "The same at the (+) terminal. 1.0, much narrower than the (-) one: the funnel runs straight out along +x, and the charger's first choke stands 2.1 mm to the side of its axis (2.5 until round 7, when it leaned 45 degrees off the charger).",
            val: 1,
            from: 0,
            to: 8,
            step: 0.1
        },
        {
            label: "neck mm",
            prop: "chargeNeck",
            group: "Charging: shape",
            tip: "The funnel's radius at the terminal, mm (where the particles are drawn in to). 0.8 is about the terminal's contact.",
            val: 0.8,
            from: 0.2,
            to: 3,
            step: 0.1
        },
        {
            label: "twist turns",
            prop: "chargeTwist",
            group: "Charging: shape",
            tip: "Turns about the axis a particle makes on the way in. 0 (no twist) is how the funnel always was; a little adds the swirl the discharge has.",
            val: 0,
            from: -3,
            to: 3,
            step: 0.1
        },
        {
            label: "size",
            prop: "chargeSize",
            group: "Charging: shape",
            tip: "A scale on the particles' width (1.2 to 1.9 px at 1, each its own). The streak's length follows its speed.",
            val: 1,
            from: 0.5,
            to: 2.5,
            step: 0.05
        },
        {
            label: "origin height (-) mm",
            prop: "chargeOriginY",
            group: "Charging: aim",
            blurb: "Where on each terminal's face the charging funnel is drawn in, and its lean.",
            tip: "The height up the (-) terminal's face the funnel is drawn into, mm (the face runs 0 to 2). 1.4, where it always was: that funnel hangs above its origin, and the board's cast fades what nears that face (turned away from the camera), so a lower one fades out early.",
            val: 1.4,
            from: 0.1,
            to: 2,
            step: 0.1
        },
        {
            label: "origin height (+) mm",
            prop: "chargeOriginPlusY",
            group: "Charging: aim",
            tip: "The height up the (+) terminal's face the funnel is drawn into, mm (the face runs 0 to 2). 1.0 is the face's vertical centre, where the discharge field leaves from too (the funnel's cross-section is an ellipse centred on it). 1.4 until round 7.",
            val: 1,
            from: 0.1,
            to: 2,
            step: 0.1
        },
        {
            label: "lean (-) deg",
            prop: "chargeLeanMinus",
            group: "Charging: aim",
            tip: "How far the (-) field leans away from the face's normal (straight out along -x), degrees, toward +z (negative: toward -z). 0 is perpendicular to the face.",
            val: 0,
            from: -60,
            to: 60,
            step: 1
        },
        {
            label: "lean (+) deg",
            prop: "chargeLeanPlus",
            group: "Charging: aim",
            tip: "How far the (+) funnel leans away from the face's normal (+x), degrees, toward +z. 0 is perpendicular to the face (the user, round 7: the charging particles must emit perpendicular, like the discharge ones). It was 45 until round 7, to keep it off the charger's chokes, capacitors and FETs; the funnel is short and narrow now instead (V6).",
            val: 0,
            from: -60,
            to: 60,
            step: 1
        },
        {
            label: "alpha floor",
            prop: "chargeFloor",
            group: "Charging: floors",
            blurb: "The faintest a charging particle may be, and the soft edge of the density gate.",
            tip: "The faintest a spawned particle may be (the density gate x the rate's ramp): below it the particle is not spawned at all, because a faint one only reads for the top of its fade and looks like a blink (round 4). 0 brings the blinking back.",
            val: 0.6,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "soft edge",
            prop: "chargeEdge",
            group: "Charging: floors",
            tip: "How wide, at most, the density gate's soft edge is: it keeps a change of load from popping slots in. It is also at most half the density, so the weak pole at 5 W is not all edge. Round 4's 0.10.",
            val: 0.1,
            from: 0,
            to: 0.5,
            step: 0.01
        },
        {
            label: "density knee W",
            prop: "dischargeKneeW",
            group: "Discharging: how many",
            blurb: "The swirl thrown out of the (-) terminal (the (+) one's is the weak one). How many particles there are and how bright.",
            tip: "The discharge rate in watts at which 63 % of the field's particle slots are alive: density = 1 - exp(-W / knee). 18 W is where a laptop charger's worth fills most of the swirl; a lower knee fills it at smaller currents, a higher one keeps a trickle sparse. It scales how many live and how strongly, never their life, size or speed.",
            val: 18,
            from: 1,
            to: 100,
            step: 1
        },
        {
            label: "weak pole share",
            prop: "dischargeWeak",
            group: "Discharging: how many",
            tip: "The share of the density the pole that is NOT this field's main one ((+)) gets: 0 leaves it dark, 1 makes the two equal. 0.40 keeps the main pole (-) the star and the other a quiet echo.",
            val: 0.4,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "alpha",
            prop: "dischargeAlpha",
            group: "Discharging: how many",
            tip: "A scale on every particle's alpha of this field, on top of the density and the idle ladder's brightness. 1 is as designed; above 1 the soft ones saturate.",
            val: 1,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "life (-) s",
            prop: "dischargeLifeMinusS",
            group: "Discharging: motion",
            blurb: "How long a discharging particle's outward throw lasts, at each terminal.",
            tip: "How long one outward throw at the (-) terminal lasts, seconds (each particle's own is 0.7 to 1.3 times it). A particle's speed is its reach over its life, so this is the speed knob: shorter is faster. 1.5 is the old module's pace for this field.",
            val: 1.5,
            from: 0.3,
            to: 4,
            step: 0.1
        },
        {
            label: "life (+) s",
            prop: "dischargeLifePlusS",
            group: "Discharging: motion",
            tip: "The same at the (+) terminal. 0.9, shorter than the (-) one's: the straight (+) swirl is short (4.4 mm), and one that lived 1.5 s barely moved before it faded -- the round-5 complaint of a particle that moves a pixel and vanishes.",
            val: 0.9,
            from: 0.3,
            to: 4,
            step: 0.1
        },
        {
            label: "reach (-) mm",
            prop: "dischargeReachMinus",
            group: "Discharging: shape",
            blurb: "The discharging swirl at each terminal: how far it travels and how wide its ring opens.",
            tip: "How far the swirl travels from the (-) terminal's face, mm; the particle fades out over its life, so the reach is where it is gone. 10 keeps it over the courtyard, clear of the CPU package.",
            val: 10,
            from: 2,
            to: 20,
            step: 0.5
        },
        {
            label: "reach (+) mm",
            prop: "dischargeReachPlus",
            group: "Discharging: shape",
            tip: "How far the weak swirl travels from the (+) terminal's face, mm. It runs straight out along +x, and the charger's first capacitor stands 6.7 mm from the face with its choke 2.1 mm to the side: a baked part cannot hide a particle, so the field fades out BEFORE they hide it (up to 4.6 mm; at 4.8 one is hidden). Raise it to see the particles drawn over the capacitors.",
            val: 4.4,
            from: 2,
            to: 20,
            step: 0.2
        },
        {
            label: "swirl radius (-) mm",
            prop: "dischargeRadiusMinus",
            group: "Discharging: shape",
            tip: "The ring's radius at the end of the throw at the (-) terminal, mm (the start is 0.3, it opens as the particle travels). 2.2; it was 3.2 until round 6, when the user found the swirling a bit too much.",
            val: 2.2,
            from: 0.3,
            to: 6,
            step: 0.1
        },
        {
            label: "swirl radius (+) mm",
            prop: "dischargeRadiusPlus",
            group: "Discharging: shape",
            tip: "The same at the (+) terminal. Narrower: the first choke stands 2.1 mm to the side of the straight swirl's axis and the ring must not reach it (V6).",
            val: 1.4,
            from: 0.3,
            to: 6,
            step: 0.1
        },
        {
            label: "turns, fewest",
            prop: "dischargeTurnsMin",
            group: "Discharging: shape",
            tip: "The fewest turns a particle makes about the axis during its throw (each draws its own between this and the most, and its own direction). 0.5; it was 0.8.",
            val: 0.5,
            from: 0,
            to: 3,
            step: 0.1
        },
        {
            label: "turns, most",
            prop: "dischargeTurnsMax",
            group: "Discharging: shape",
            tip: "The most turns during a throw. 1.2; it was 2.0. Fewer turns read as a drift, more as a spiral.",
            val: 1.2,
            from: 0,
            to: 4,
            step: 0.1
        },
        {
            label: "size",
            prop: "dischargeSize",
            group: "Discharging: shape",
            tip: "A scale on the particles' width (1.2 to 1.9 px at 1, each its own). The streak's length follows its speed.",
            val: 1,
            from: 0.5,
            to: 2.5,
            step: 0.05
        },
        {
            label: "origin height mm",
            prop: "dischargeOriginY",
            group: "Discharging: aim",
            blurb: "Where on the terminal's face the swirl leaves from, and its lean.",
            tip: "The height up the terminal's face the swirl leaves from, mm (the face runs 0 to 2): 1.0 is its vertical centre. It was 1.4 -- 'a tiny bit too high'. The ring is centred on it.",
            val: 1,
            from: 0.1,
            to: 2,
            step: 0.1
        },
        {
            label: "lean (-) deg",
            prop: "dischargeLeanMinus",
            group: "Discharging: aim",
            tip: "How far the (-) field leans away from the face's normal (straight out along -x), degrees, toward +z (negative: toward -z). 0 is perpendicular to the face.",
            val: 0,
            from: -60,
            to: 60,
            step: 1
        },
        {
            label: "lean (+) deg",
            prop: "dischargeLeanPlus",
            group: "Discharging: aim",
            tip: "How far the (+) swirl leans away from the face's normal (+x), degrees, toward +z. 0 is perpendicular to the face, as the user asked (it was 45, which read as 'an angle towards the camera'); the swirl is kept off the charger by its short reach instead.",
            val: 0,
            from: -60,
            to: 60,
            step: 1
        },
        {
            label: "alpha floor",
            prop: "dischargeFloor",
            group: "Discharging: floors",
            blurb: "The faintest a discharging particle may be, and the soft edge of the density gate.",
            tip: "The faintest a spawned particle may be (the density gate x the rate's ramp): below it the particle is not spawned at all, because a faint one only reads for the top of its fade and looks like a blink (round 4). 0 brings the blinking back.",
            val: 0.6,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "soft edge",
            prop: "dischargeEdge",
            group: "Discharging: floors",
            tip: "How wide, at most, the density gate's soft edge is: it keeps a change of load from popping slots in. It is also at most half the density, so the weak pole at 5 W is not all edge. Round 4's 0.10.",
            val: 0.1,
            from: 0,
            to: 0.5,
            step: 0.01
        }
    ]

    // =====================================================================
    //  THE PROBE: PROBE=owner
    //
    // The owner on the real engine, with the real popup and the mock behind it, driven through the
    // mockup's own stage. Each check prints `SILICONOWNER <id> <what>: ok|FAIL`; the last line is
    // `SILICONOWNER RESULT PASS|FAIL`. A check is proved by arming the owner (a sandbox copy of
    // SiliconBarOwner.qml) so that it fails.
    //
    //   O1  the button's facts at the desk: percent, mains, charging, the limit, profile, GPU step,
    //       the dGPU awake, MUX pending (the cap rests at 80 with the limit off, so it fades in place)
    //   O2  the facts follow the timeline (the game: on battery, the dGPU awake; the charge: charging)
    //   O3  gpuMode is the STEP order, not cardwire's number (Smart: step 1, cardwire 3)
    //   O4  profile, a tweak, the charge limit and a pending MUX switch follow the machine
    //   O5  a battery event pulses the button: all four kinds, and one off the real timeline
    //   O6  a real click on the button opens the popup: ours, the service told, the button's `active` on
    //   O7  the popup is built with the vm, the family (live, and from the config), the scale
    //   O8  a second click closes it: not ours, the service told, `active` off, `shown` off at once
    //   O9  open() / close() / toggle() from code, idempotent
    //   O10 the Layout and Motion tabs' values and the Run tab's Memory rows reach
    //       whichever popup is out, and the next one (the popup is rebuilt on every open, the tunables live in the mockup)
    //   O11 the Machine group: a forced charge, the mains (the jack and the pulse), the 80 % limit on the mains
    //       ("Not charging", the caption), the dGPU asleep / awake / busy, a helper that does not answer, a kernel
    //       without the charge limit -- each through the panel's own target, each refused or shown in words
    //   O12 clicks on the board's parts through the REAL engine: the package, the card, the DIP lever, empty
    //       board -- real synthetic events on the window at the projected centres (the popup's own camera), so
    //       the engine's clip and gesture layers are in the chain; the engine's secondary must be out and show
    //       the right panel. STEPS=O11,O12 runs only those (after setup).
    //   O13 the Motion tab's idle ladder: the clock's rates and rest / wake times, the board's MUX breath and the
    //       mock's idle config (a NEW object, the rest of it kept) reach their targets; left alone the ladder walks
    //       alive -> calm -> halt and the clock parks; the tab's readout says so; a touch wakes it
    //   O14 the Entrance button plays the power-on again, from a clock the ladder has parked too (it wakes it): the
    //       board goes dark and powers back on
    //   O15 the Sounds tab: the three volumes are a new config the next sound reads, the debounce and the picked takes
    //       (a / b / c) reach the popup's sounds, each of the six auditions plays its own file at its sound's volume (the
    //       runner's pw-play stub), an audition that names a take plays that one, and at volume 0 not one process starts
    //   O16 the Scenario page's MUX flows: the unit not running (the pre-check's words, a refused request), the
    //       guard's windows, dGPU-only -> Restart now -> the keep prompt -> Run out the keep window (Hybrid is back),
    //       Restart the shell tells the outcome ONCE (a NotificationBus stub, never the user's bus), and a blocked app
    //       notifies only in Smart (the runner's notify-send stub)
    //   O17 the Live switch, up to the switch and never past it: one click ARMS it (still the mock, no service built,
    //       the owner on the mock) and the arming runs out after 4 s. No probe selects live (the runner's static phase
    //       reads this file for that: nothing below the probe marker may name the calls that do)
    //   X1  (a repro, not a gate: STEPS=X1 only, REOPEN_MS=<ms>) a secondary opened a moment after another
    //       closed. TODAY IT FAILS for under ~500 ms: GooeyEngine.openChild takes its fresh path for a child that
    //       is still `closing` and never clears `closeCurve`, so the open runs on the close curve and the child
    //       ends "open" at half width and no height (nothing on screen).
    // =====================================================================
    readonly property string probeKind: Quickshell.env("PROBE") || ""
    TestCase {
        id: tc
        name: "silicon_owner_probe"
        when: false
    }
    property var probeFails: []
    property int probeChecks: 0
    function check(id, what, ok) {
        win.probeChecks++;
        console.log("SILICONOWNER " + id + " " + what + ": " + (ok ? "ok" : "FAIL"));
        if (!ok)
            win.probeFails.push(id + " " + what);
    }

    // The runner's stand-ins for pw-play and notify-send: one log they append to ("PLAY <argv>", "NOTIFY <argv>"), read afresh
    // every time -- a reload, then the read that blockAllReads makes the new bytes.
    readonly property string stubLog: Quickshell.env("STUB_LOG") || ""
    readonly property string stubPlay: Quickshell.env("STUB_PWPLAY") || ""
    FileView {
        id: stubFile
        path: win.probeKind !== "" ? win.stubLog : ""
        printErrors: false
        blockLoading: true
        blockAllReads: true
    }
    function stubLines(prefix) {
        if (win.stubLog === "")
            return [];
        stubFile.reload();
        return (stubFile.text() || "").split("\n").filter(l => l.indexOf(prefix) === 0);
    }

    property var _poll: null
    Timer {
        id: pollTimer
        interval: 25
        repeat: true
        onTriggered: {
            const p = win._poll;
            if (!p) {
                pollTimer.stop();
                return;
            }
            let ok = false;
            try {
                ok = p.cond();
            } catch (e) {
                ok = false;
            }
            if (ok || Date.now() >= p.deadline) {
                pollTimer.stop();
                win._poll = null;
                p.then(ok);
            }
        }
    }
    // Whether the open board is showing this memory (the Run tab's Memory group: the used fraction).
    function memoryIs(used) {
        const m = win._board ? win._board.memory : null;
        return !!m && Math.abs(m.usedFraction - used) < 1e-6;
    }
    // Whether the board's RAM display and its chips agree: the printed GiB is the used memory of the facts, and the chips are told that same
    // memory (the scene's `memory.usedFraction` of the facts' total) -- both from the one source, the mock's facts.
    function ramAgrees() {
        const f = win._board ? win._board.figures : null, m = win._board ? win._board.memory : null, fm = mock.memory;
        if (!f || !m || !fm)
            return false;
        const gib = (fm.totalKiB - fm.availableKiB) / 1048576;
        return f.ram === Model.buildFigures(mock.battery, fm, Date.now()).ram && Math.abs(Number(f.ram) - gib) < 0.06 && Math.abs(m.usedFraction * fm.totalKiB / 1048576 - gib) < 0.06;
    }
    // Call `then(ok)` when `cond()` holds, or after `ms` of wall clock with ok false.
    function waitFor(cond, ms, then) {
        win._poll = {
            cond: cond,
            deadline: Date.now() + ms,
            then: then
        };
        pollTimer.restart();
    }
    function pause(ms, then) {
        win.waitFor(() => false, ms, () => then());
    }

    property var _chain: []
    property int _chainAt: -1
    function runChain(steps) {
        win._chain = steps;
        win._chainAt = -1;
        win.nextStep();
    }
    function nextStep() {
        win._chainAt++;
        if (win._chainAt >= win._chain.length) {
            const f = win.probeFails;
            console.log("SILICONOWNER RESULT " + (f.length === 0 && win.probeChecks > 0 ? "PASS" : "FAIL") + " (" + win.probeChecks + " checks"
                        + (f.length > 0 ? "; failed: " + f.join("; ") : "") + ")");
            Qt.quit();
            return;
        }
        const s = win._chain[win._chainAt];
        console.log("SILICONOWNER STEP " + s[0]);
        try {
            s[1](() => win.nextStep());
        } catch (e) {
            win.check("O0", "step '" + s[0] + "' threw " + e, false);
            win.nextStep();
        }
    }

    Timer {
        running: win.probeKind === "owner" || win.probeKind === "soak"
        interval: 1500
        onTriggered: win.runChain(win.probeKind === "soak" ? win.soakSteps() : win.chosen(win.ownerSteps()))
    }

    // The button's centre in the window, where a real click goes.
    function buttonCentre() {
        return siliconButton.mapToItem(null, siliconButton.width / 2, siliconButton.height / 2);
    }
    function clickButton() {
        const c = win.buttonCentre();
        tc.mouseClick(win.contentItem, c.x, c.y);
    }
    function facts(id, what, want) {
        for (const k of Object.keys(want)) {
            const got = siliconButton[k];
            win.check(id, what + ": " + k + " " + got + (got === want[k] ? "" : " (want " + want[k] + ")"), got === want[k]);
        }
    }
    // Put the mock at (scenario, t) and wait for the button to show `until`.
    function at(scenario, t, until, then) {
        mock.playing = false;
        mock.scenario = scenario;
        mock.timeMs = t;
        win.waitFor(until, 4000, then);
    }

    // items: [[ms to wait after it, fn, until (optional)], ...], run in order; after the wait an item with `until` waits (8 s at most)
    // for it to hold; a step that throws is a failed check.
    function script(items, done) {
        let i = 0;
        const run = () => {
            if (i >= items.length) {
                done();
                return;
            }
            const it = items[i++];
            try {
                it[1]();
            } catch (e) {
                win.check("S0", "script step " + i + " threw " + e, false);
            }
            win.pause(it[0], it[2] ? () => win.waitFor(it[2], 8000, run) : run);
        };
        run();
    }

    // PROBE=soak: everything a reviewer would do, in one run, on the real engine with a secondary out. The
    // runner asserts the log stays free of warnings (a binding loop, a TypeError, an unassignable value),
    // which is what the few checks here sit beside.
    function soakSteps() {
        const m = mock;
        const p = () => win._popup;
        const told = () => win.notes("silicon-mux");
        return [
            ["soak: the whole of it", next => win.script([
                [100, () => {
                    m.playing = false;
                    m.scenario = "game";
                    m.timeMs = 8000;
                }],
                [1500, () => owner.open()],
                [1200, () => p().openSecondary("tuning")],
                [1800, () => m.stepProfile(1)],
                [1800, () => m.stepProfile(1)],
                [300, () => m.stepProfile(-1)],
                [2200, () => m.stepProfile(-1)],
                [1800, () => m.setTuning({ turbo: false })],
                [1500, () => m.resetTuning()],
                [1500, () => p().openSecondary("gpu")],
                [800, () => m.setGpuMode(0, {})],
                [1500, () => m.setGpuMode(0, { confirmHolders: true })],
                [1800, () => {
                    m.scenario = "desk";
                    m.timeMs = 0;
                }],
                [3500, () => m.setGpuMode(1, {})],
                [3000, () => {
                    m.refuseNext = "cpu";
                    m.stepProfile(1);
                }],
                [2500, () => win.check("S1", "a refused write animated the target back to the fact (" + m.profileTarget + " / " + m.profileIndex + ")",
                                       m.profileTarget === m.profileIndex)],
                [100, () => m.externalProfile("performance")],
                [1500, () => m.externalGpuMode(0)],
                [3500, () => m.externalLimit(true)],
                [1500, () => m.setChargeLimit(false)],
                [1500, () => {
                    m.scenario = "charge";
                    m.timeMs = 4500;
                    m.playing = true;
                }],
                [3000, () => {
                    m.playing = false;
                    m.muxRequest("dgpu");
                }],
                [1500, () => m.muxRebootNow()],
                [1500, () => m.muxKeep()],
                [1500, () => win.check("S2", "the MUX flow ended in dGPU-only wiring (step " + m.gpuMode + ")", m.gpuMode === 3)],
                [100, () => {
                    // the stage 5 / 6 calls: the entrance again, the clock's and the breath's knobs, a sound (silent in a
                    // harness), then the guard's revert end to end with the notification service stubbed
                    win.useNotifications(true);
                    win.replayEntrance();
                    mot.aliveMs = 24;
                    mot.calmMs = 50;
                    mot.muxBreathDepth = 0.6;
                    snd.latch = 0.4;
                    snd.debounceMs = 120;
                    win.auditionSound("latch", true);
                    win.auditionSound("plug", false);
                }],
                [1500, () => m.muxRequest("hybrid")],
                [1500, () => m.muxRebootNow()],
                [1500, () => m.muxRequest("dgpu")],
                [1500, () => m.muxRebootNow()],
                [2000, () => win.runOutKeepWindow(), () => m.gpu.mux.state === "reverted"],
                [300, () => win.restartShell()],
                [1500, () => {
                    win.check("S4", "the guard put the Hybrid wiring back and the shell's start told it once (" + m.gpu.mux.state + ", wiring " + m.gpu.mux.wiringNow + ", seen "
                              + m.gpu.mux.outcomeSeen + ", told " + told().length + ")",
                              m.gpu.mux.state === "reverted" && m.gpu.mux.wiringNow === "hybrid" && m.gpu.mux.outcomeSeen === true && told().length === 1);
                    win.useNotifications(false);
                    mot.aliveMs = 16;
                    mot.calmMs = 33;
                    mot.muxBreathDepth = 0.45;
                    snd.latch = 0.2;
                    snd.debounceMs = 80;
                }],
                [100, () => {
                    tun.family = 1;
                }],
                [1500, () => Theme.setMode("dark")],
                [2500, () => Theme.setMode("light")],
                [2500, () => {
                    tun.family = 0;
                }],
                [1500, () => owner.close()],
                [1500, () => win.check("S3", "the popup is closed at the end", !owner.popupMine)]
            ], next)]
        ];
    }

    // STEPS=O11,O12: only those steps (and the setup). A step is named "<id> what".
    function chosen(steps) {
        const want = (Quickshell.env("STEPS") || "").split(",").map(s => s.trim()).filter(s => s !== "");
        const idOf = s => String(s[0]).split(" ")[0].replace(/:$/, "");
        if (want.length === 0)
            return steps.filter(s => !/^X/.test(idOf(s)));        // X1.. are opt-in repros, named by STEPS
        return steps.filter(s => idOf(s) === "setup" || want.indexOf(idOf(s)) >= 0);
    }

    // items: [[group, what, action | null, cond, settle ms (optional), show (optional)], ...]. Do the action, wait
    // the settle (a "nothing happens" check wants one), then wait for the condition: one `<id> <group>: <what>`
    // check each; `show()` is what a failing one says it saw.
    function expect(id, items, done) {
        let i = 0;
        const run = () => {
            if (i >= items.length) {
                done();
                return;
            }
            const it = items[i++];
            const label = it[0] + ": " + it[1];
            try {
                if (it[2])
                    it[2]();
            } catch (e) {
                win.check(id, label + " (threw " + e + ")", false);
                run();
                return;
            }
            const go = () => win.waitFor(it[3], Number(Quickshell.env("WAIT_MS") || 12000), ok => {
                let seen = "";
                if (!ok && it[5]) {
                    try {
                        seen = " [saw " + String(it[5]()).replace(/\s*\n\s*/g, " | ") + "]";        // one line: the runner reads a verdict per line
                    } catch (e) {
                        seen = " [saw nothing: " + e + "]";
                    }
                }
                win.check(id, label + seen, ok);
                run();
            });
            if (it[4])
                win.pause(it[4], go);
            else
                go();
        };
        run();
    }

    // ---- the board's parts, in the window (O12): the popup's own camera and the same arithmetic as
    // test_silicon_popup_probe.qml, then through the scene item into the window's frame
    function boardPt(p) {
        const sc = win._popup.sceneItem;
        const q = Cam.project(p, sc.cam);
        return sc.mapToItem(null, q.x, q.y);
    }
    function pkgPt(p) {                  // a point on the package, as it is drawn at its resting quarter
        const sc = win._popup.sceneItem;
        return win.boardPt(Cam.pkgPoint(sc.geo, p, -sc.pkgQuarter * Math.PI / 2, 0));
    }
    function partTile() {
        const Z = win._popup.sceneItem.geo.ZONE;
        return [Z.cx - 8.1, 2.6, Z.cz - 3.8];
    }
    function partCard() {
        const C = win._popup.sceneItem.geo.CARD;
        return [(C.die[0] + C.die[2]) / 2, C.rest + C.pcb + 1.8, (C.die[1] + C.die[3]) / 2];
    }
    function partLever(high) {
        const G = win._popup.sceneItem.geo;
        return [high ? G.LEVER.xHigh : G.LEVER.xLow, G.DIP.h + G.LEVER.h, (G.DIP.z0 + G.DIP.z1) / 2];
    }
    function clickWin(pt) {
        tc.mouseClick(win.contentItem, pt.x, pt.y);
    }
    function boardSnapshot() {
        const p = win._popup;
        return JSON.stringify({ open: p.secondaryOpen, key: p.secondaryKey, profile: mock.profileTarget, gpu: mock.gpuModeTarget,
                                limit: mock.chargeLimitTarget, child: engine.childOpen });
    }
    function childState() {
        const c = engine.childPopup;
        return "childOpen " + engine.childOpen + ", phase " + c.phase + ", opacity " + Number(c.contentOpacity).toFixed(2) + ", wears "
               + (c.contentItem ? c.contentItem.shownKind + " " + Math.round(c.contentItem.width) + "x" + Math.round(c.contentItem.height) : "no content")
               + "; popup key " + (win._popup ? win._popup.secondaryKey : "?");
    }
    // the engine's secondary is out, has finished fading in, wears the panel of `kind`, has a size, and its middle is
    // inside the window
    function childShown(kind) {
        const c = engine.childPopup;
        if (!engine.childOpen || c.phase !== "open" || c.contentOpacity < 0.99 || !c.contentItem || c.contentItem.shownKind !== kind)
            return false;
        const w = c.contentItem.width, h = c.contentItem.height;
        const m = c.contentItem.mapToItem(null, w / 2, h / 2);
        return w > 0 && h > 0 && m.x > 0 && m.y > 0 && m.x < win.width && m.y < win.height;
    }

    function ownerSteps() {
        let content = null;
        return [
            ["setup: the mock, no real service", next => {
                win.check("O1", "the owner runs on the injected mock", owner.svc === mock);
                win.check("O1", "the owner started no service of its own", owner.ownsService === false);
                win.check("O1", "the data is the mock and the Live switch is off: no real service was built", win.siliconSource === "mock" && win.live === false
                          && win.liveArmed === false && win.liveService === null && liveLoader.item === null && owner.svc === win.activeService);
                win.check("O1", "the popup starts closed", !owner.popupMine && !mock.popupOpen && !siliconButton.active);
                mock.playing = false;
                const c = win.buttonCentre();
                win.check("O6", "the button is inside the window (" + Math.round(c.x) + "," + Math.round(c.y) + ")",
                          c.x > 0 && c.y > 0 && c.x < win.width && c.y < win.height);
                next();
            }],
            ["O1 the desk", next => win.at("desk", 0, () => siliconButton.percent === 100, ok => {
                win.check("O1", "the desk's facts reached the button", ok);
                win.facts("O1", "desk", { percent: 100, plugged: true, charging: false, limitOn: false, limitPercent: 80,
                                          profile: 1, tweaked: false, gpuMode: 2, gpuInUse: false, muxPending: false });
                next();
            })],
            ["O2 the game", next => win.at("game", 10000, () => siliconButton.percent === 71, ok => {
                win.check("O2", "the game's facts reached the button", ok);
                win.facts("O2", "game", { percent: 71, plugged: false, charging: false, gpuInUse: true });
                next();
            })],
            ["O2 the charge", next => win.at("charge", 30000, () => siliconButton.percent === 60, ok => {
                win.check("O2", "the charge's facts reached the button", ok);
                win.facts("O2", "charge", { percent: 60, plugged: true, charging: true });
                next();
            })],
            ["O3 the GPU step order", next => {
                win.at("desk", 0, () => siliconButton.percent === 100, () => {
                    mock.externalGpuMode(1);
                    win.waitFor(() => siliconButton.gpuMode === 1, 4000, ok => {
                        win.check("O3", "Smart is step 1 on the button", ok);
                        win.check("O3", "cardwire's own number for it is 3, not the button's", mock.gpu.mode === 3 && siliconButton.gpuMode !== mock.gpu.mode);
                        mock.externalGpuMode(0);
                        win.waitFor(() => siliconButton.gpuMode === 0, 4000, ok2 => {
                            win.check("O3", "Integrated is step 0", ok2);
                            mock.externalGpuMode(2);
                            win.waitFor(() => siliconButton.gpuMode === 2, 4000, ok3 => {
                                win.check("O3", "Hybrid is step 2", ok3);
                                next();
                            });
                        });
                    });
                });
            }],
            ["O4 profile, tweak, limit, MUX", next => {
                mock.externalProfile("performance");
                win.waitFor(() => siliconButton.profile === 2, 4000, ok => {
                    win.check("O4", "Performance (changed outside) is profile 2", ok);
                    mock.externalProfile("quiet");
                    win.waitFor(() => siliconButton.profile === 0, 4000, ok2 => {
                        win.check("O4", "Quiet is profile 0", ok2);
                        mock.externalProfile("balanced");
                        win.waitFor(() => siliconButton.profile === 1 && !siliconButton.tweaked, 4000, ok3 => {
                            win.check("O4", "Balanced is profile 1, not tweaked", ok3);
                            mock.setTuning({ turbo: false });
                            win.waitFor(() => siliconButton.tweaked, 6000, ok4 => {
                                win.check("O4", "a held-away value makes the button tweaked", ok4);
                                mock.resetTuning();
                                win.waitFor(() => !siliconButton.tweaked, 6000, ok5 => {
                                    win.check("O4", "putting the tuning back clears it", ok5);
                                    mock.setChargeLimit(true);
                                    win.waitFor(() => siliconButton.limitOn && siliconButton.limitPercent === 80, 6000, ok6 => {
                                        win.check("O4", "the limit on: 80 % and its cap", ok6);
                                        mock.externalLimit(false);
                                        win.waitFor(() => !siliconButton.limitOn && siliconButton.limitPercent === 80, 6000, ok7 => {
                                            win.check("O4", "the limit off (changed outside): no cap, and it stays at 80 to fade out in place", ok7);
                                            mock.muxRequest("dgpu");
                                            win.waitFor(() => siliconButton.muxPending, 6000, ok8 => {
                                                win.check("O4", "a queued MUX request is pending on the button", ok8);
                                                mock.muxCancel();
                                                win.waitFor(() => !siliconButton.muxPending, 6000, ok9 => {
                                                    win.check("O4", "cancelling it clears the pending mark", ok9);
                                                    next();
                                                });
                                            });
                                        });
                                    });
                                });
                            });
                        });
                    });
                });
            }],
            ["O5 battery events pulse the button", next => {
                const kinds = ["full", "low", "chargeStart", "chargeStop"];
                let i = 0;
                const one = () => {
                    if (i >= kinds.length) {
                        next();
                        return;
                    }
                    const kind = kinds[i++];
                    mock.batteryEvent(kind);
                    win.check("O5", "a '" + kind + "' event sets the pulse kind (" + siliconButton.pulseKind + ")", siliconButton.pulseKind === kind);
                    win.waitFor(() => siliconButton.pulseProgress < 0.99, 1500, started => {
                        win.check("O5", "'" + kind + "' starts the pulse (progress " + siliconButton.pulseProgress.toFixed(2) + ")", started);
                        win.waitFor(() => siliconButton.pulseProgress >= 0.999, 6000, done => {
                            win.check("O5", "'" + kind + "' pulse runs out", done);
                            one();
                        });
                    });
                };
                one();
            }],
            ["O5 an event off the real timeline", next => {
                // chargeStart: the charge scenario's status turns to Charging at 5 s, running forward
                mock.playing = false;
                mock.scenario = "charge";
                mock.timeMs = 4500;
                siliconButton.pulseKind = "full";
                mock.speed = 1;
                mock.playing = true;
                win.waitFor(() => siliconButton.pulseKind === "chargeStart", 12000, ok => {
                    win.check("O5", "the timeline's own charge start pulsed the button", ok);
                    mock.playing = false;
                    next();
                });
            }],
            ["O6 a click opens the popup", next => {
                win.at("game", 10000, () => siliconButton.percent === 71, () => {
                    win.clickButton();
                    win.waitFor(() => owner.popupMine, 6000, ok => {
                        win.check("O6", "a real click on the button opened the popup", ok);
                        win.check("O6", "the engine's popup is silicon's", engine.popupOwnerId === "silicon");
                        win.check("O6", "the service was told (popupOpen)", mock.popupOpen === true);
                        win.check("O6", "the button knows the popup is ours (active)", siliconButton.active === true);
                        win.waitFor(() => engine.thePopup.phase === "open" && engine.thePopup.contentOpacity >= 0.99, 10000, open => {
                            win.check("O6", "the popup came out and its content is showing", open);
                            content = win._popup;
                            win.check("O6", "the content exists", !!content);
                            next();
                        });
                    });
                });
            }],
            ["O7 what the popup is built with", next => {
                win.check("O7", "vm is the service", !!content && content.vm === mock);
                win.check("O7", "family is the owner's (" + (content ? content.family : "?") + ")", !!content && content.family === owner.family && owner.family === 0);
                win.check("O7", "renderScale is the engine's zoom times the screen's (" + (content ? content.renderScale : "?") + " vs " + owner.renderScale + ")",
                          !!content && Math.abs(content.renderScale - owner.renderScale) < 1e-9
                          && Math.abs(owner.renderScale - engine.renderScale * (win.screen && win.screen.devicePixelRatio > 0 ? win.screen.devicePixelRatio : 1)) < 1e-9);
                win.check("O7", "shown is true while it is out", !!content && content.shown === true);
                tun.family = 1;
                win.waitFor(() => !!content && content.family === 1, 4000, ok => {
                    win.check("O7", "the panel's Blueprint reaches the open popup", ok);
                    tun.family = 0;
                    win.waitFor(() => !!content && content.family === 0, 4000, ok2 => {
                        win.check("O7", "and Material comes back", ok2);
                        // without an override the config's look.family rules
                        owner.familyOverride = -1;
                        const cfg = JSON.parse(JSON.stringify(mock.config));
                        cfg.look.family = "blueprint";
                        mock.config = cfg;
                        win.waitFor(() => !!content && content.family === 1 && owner.family === 1, 4000, ok3 => {
                            win.check("O7", "silicon.json's look.family 'blueprint' reaches the popup", ok3);
                            cfg.look.family = "material";
                            mock.config = JSON.parse(JSON.stringify(cfg));
                            win.waitFor(() => !!content && content.family === 0 && owner.family === 0, 4000, ok4 => {
                                win.check("O7", "and 'material' puts it back", ok4);
                                next();
                            });
                        });
                    });
                });
            }],
            ["O8 a second click closes it", next => {
                win.clickButton();
                win.waitFor(() => !owner.popupMine, 6000, ok => {
                    win.check("O8", "a second click closed the popup", ok);
                    win.check("O8", "the service was told (popupOpen false)", mock.popupOpen === false);
                    win.check("O8", "the button no longer marks the popup as ours (active off)", siliconButton.active === false);
                    win.check("O8", "the owner's `shown` is off at once", owner.popupShown === false);
                    // the content is still on its way out: it must already be told
                    const closing = win._popup;
                    win.check("O8", "the content, still fading out, is told shown is false", !closing || closing.shown === false);
                    win.waitFor(() => engine.thePopup.phase === "closed", 10000, closed => {
                        win.check("O8", "the popup finished closing", closed);
                        next();
                    });
                });
            }],
            ["O9 open, close, toggle from code", next => {
                owner.open();
                win.waitFor(() => owner.popupMine, 6000, ok => {
                    win.check("O9", "open() opens", ok);
                    owner.open();
                    win.check("O9", "open() again is a no-op", owner.popupMine && mock.popupOpen === true);
                    owner.close();
                    win.waitFor(() => !owner.popupMine, 6000, ok2 => {
                        win.check("O9", "close() closes", ok2 && mock.popupOpen === false);
                        owner.close();
                        win.check("O9", "close() again is a no-op", !owner.popupMine);
                        win.waitFor(() => engine.thePopup.phase === "closed", 10000, closed => {
                            owner.toggle();
                            win.waitFor(() => owner.popupMine, 6000, ok3 => {
                                win.check("O9", "toggle() opens when closed", ok3);
                                owner.toggle();
                                win.waitFor(() => !owner.popupMine, 6000, ok4 => {
                                    win.check("O9", "toggle() closes when open", ok4);
                                    next();
                                });
                            });
                        });
                    });
                });
            }],
            ["O10 the Motion tab reaches the popup", next => {
                win.waitFor(() => engine.thePopup.phase === "closed", 10000, () => {
                    owner.open();
                    win.waitFor(() => owner.popupMine && !!win._director && !!win._clock && !!win._board, 8000, ok => {
                        win.check("O10", "an open popup has a director, a clock and a board to push into", ok);
                        win.check("O10", "the director starts at the panel's film speed", !!win._director && win._director.speed === mot.speed);
                        win.check("O10", "the director starts at the panel's lock time", !!win._director && win._director.lockSeconds === mot.lockSeconds);
                        // the scenario's own memory (it moves with the timeline) is what the facts say until the Memory group takes over
                        win.check("O10", "the facts are the scenario's own memory while the Memory group is off, and the board's RAM display and chips agree", mock.memoryOverride === null && mem.memOverride === false && win.ramAgrees());
                        mot.speed = 2;
                        mot.flowMax = 30;
                        lay.headSize = 18;
                        mot.lockSeconds = 0.6;
                        mem.memUsedPct = 70;
                        win.waitFor(() => !!win._director && win._director.speed === 2 && win._clock.flowMax === 30 && win._popup.headSize === 18
                                    && win._director.lockSeconds === 0.6, 4000, ok2 => {
                            win.check("O10", "a tweak reaches the open popup's own knobs, its director and its clock", ok2);
                            win.check("O10", "the lock time reaches the director", !!win._director && win._director.lockSeconds === 0.6);
                            win.check("O10", "the Memory rows alone change nothing while 'override memory' is off", mock.memoryOverride === null && !win.memoryIs(0.7));
                            mem.memOverride = true;
                            win.waitFor(() => win.memoryIs(0.7), 4000, okm => {
                                win.check("O10", "'override memory' puts the rows' memory on the mock's facts, and the board shows it", okm);
                                win.check("O10", "the board's RAM display (the printed GiB) and its chips agree with each other and with the facts under the override", win.ramAgrees() && mock.memory.usedFraction > 0.699 && mock.memory.usedFraction < 0.701);
                                owner.close();
                                win.waitFor(() => engine.thePopup.phase === "closed", 10000, () => {
                                    owner.open();
                                    win.waitFor(() => owner.popupMine && !!win._director && win._director.speed === 2 && win._clock.flowMax === 30 && win._popup.headSize === 18
                                                && !!win._board && win._director.lockSeconds === 0.6 && win.memoryIs(0.7), 8000, ok3 => {
                                        win.check("O10", "the next popup, a new one, comes up with the tweak", ok3);
                                        mot.speed = 1;
                                        mot.flowMax = 60;
                                        lay.headSize = 16;
                                        mot.lockSeconds = 0.34;
                                        mem.memOverride = false;
                                        mem.memUsedPct = 40;
                                        win.waitFor(() => !!win._director && win._director.speed === 1 && win._clock.flowMax === 60 && win._popup.headSize === 16
                                                    && win._director.lockSeconds === 0.34
                                                    && mock.memoryOverride === null && win.ramAgrees() && !win.memoryIs(0.7), 4000, ok4 => {
                                            win.check("O10", "and the panel's defaults put it back, the facts and the board on the scenario's own memory again", ok4);
                                            next();
                                        });
                                    });
                                });
                            });
                        });
                    });
                });
            }],
            ["O11 the machine at will", next => win.at("desk", 0, () => siliconButton.percent === 100, () => {
                const dseen = [];
                mock.gpuPowerChanged.connect(d => dseen.push(d));
                const noLimit = win.machineFeatures.indexOf("chargeLimit") + 1;
                win.expect("O11", [
                    ["pack", "a forced charge of 35 % reaches the button", () => {
                        siliconButton.pulseKind = "full";
                        mach.pct = 35;
                    }, () => siliconButton.percent === 35 && mock.battery.pct === 35],
                    ["pack", "on the mains it is charging: the status follows the charge", null,
                     () => siliconButton.charging === true && siliconButton.plugged === true && mock.battery.status === "Charging"],
                    ["pack", "leaving full for a charge pulses the pack (chargeStart)", null, () => siliconButton.pulseKind === "chargeStart"],
                    ["mains", "unplugged: the jack follows and nothing charges", () => {
                        siliconButton.pulseKind = "full";
                        mach.ac = 2;
                    }, () => siliconButton.plugged === false && siliconButton.charging === false && mock.battery.status === "Discharging"],
                    ["mains", "and the charge stopping pulses the pack (chargeStop)", null, () => siliconButton.pulseKind === "chargeStop"],
                    ["mains", "plugged in: the jack follows and the charge resumes", () => {
                        siliconButton.pulseKind = "full";
                        mach.ac = 1;
                    }, () => siliconButton.plugged === true && siliconButton.charging === true],
                    ["mains", "and it pulses again (chargeStart)", null, () => siliconButton.pulseKind === "chargeStart"],
                    ["limit", "over the 80 % limit on the mains the pack is not charging", () => {
                        mock.externalLimit(true);
                        mach.pct = 85;
                    }, () => mock.battery.status === "Not charging" && siliconButton.charging === false && siliconButton.plugged === true && siliconButton.limitOn === true],
                    ["limit", "and its caption says it is held there, the limit not draining it", null, () => /^Held at 85 % .*does not drain/.test(mock.caption.battery)],
                    ["dGPU", "forced asleep: the card sleeps", () => {
                        mach.dgpu = 1;
                    }, () => siliconButton.gpuInUse === false && mock.gpu.dState === "D3cold"],
                    ["dGPU", "busy: the card is awake, with users and its own readings", () => {
                        mach.dgpu = 3;
                    }, () => siliconButton.gpuInUse === true && mock.gpu.holders.length > 0 && mock.gpu.util !== null],
                    ["dGPU", "the wake is reported (gpuPowerChanged D0)", null, () => dseen.indexOf("D0") >= 0],
                    ["dGPU", "awake with nobody on it: no users and no readings", () => {
                        mach.dgpu = 2;
                    }, () => siliconButton.gpuInUse === false && mock.gpu.awake === true && mock.gpu.holders.length === 0 && mock.gpu.util === null],
                    ["dGPU", "asleep again: the card stays faded and the sleep is reported (D3cold)", () => {
                        mach.dgpu = 1;
                    }, () => siliconButton.gpuInUse === false && dseen.indexOf("D3cold") >= 0],
                    ["helper", "a helper that is installed but does not answer", () => {
                        mach.helperOk = false;
                    }, () => mock.helper.installed === true && mock.helper.ok === false],
                    ["helper", "a profile step is refused, the why in the CPU caption's error", () => {
                        mock.stepProfile(1);
                    }, () => /helper/.test(mock.caption.cpuError)],
                    ["helper", "answering again", () => {
                        mach.helperOk = true;
                    }, () => mock.helper.ok === true],
                    ["features", "a kernel without the charge limit: the feature is gone", () => {
                        mach.hide = noLimit;
                    }, () => mock.helper.features.chargeLimit === false && mock.battery.limitAvailable === false],
                    ["features", "the limit intent is refused, the why in the battery caption's error", () => {
                        mock.setChargeLimit(false);
                    }, () => mock.caption.batteryError !== ""],
                    ["features", "the machine back as it was", () => {
                        mach.hide = 0;
                        mock.externalLimit(false);
                        mach.pct = -1;
                        mach.ac = 0;
                        mach.dgpu = 0;
                    }, () => mock.helper.features.chargeLimit === true && siliconButton.percent === 100 && siliconButton.limitOn === false
                             && siliconButton.plugged === true]
                ], next);
            })],
            ["O12 clicks on the board, through the engine", next => {
                let snap = "";
                win.expect("O12", [
                    ["board", "the popup is out and settled, nothing hung from it", () => {
                        if (!owner.popupMine)
                            owner.open();
                        if (win._popup && win._popup.secondaryOpen)
                            win._popup.closeSecondary();
                    }, () => owner.popupMine && engine.thePopup.phase === "open" && engine.thePopup.contentOpacity >= 0.99 && !!win._popup
                             && !engine.childOpen && win._popup.sceneItem.pkgQuarter === 1 && mock.chargeLimitTarget === 100],
                    ["board", "empty board and the margin answer nothing", () => {
                        snap = win.boardSnapshot();
                        win.clickWin(win.boardPt([-30, 0, -30]));
                        win.clickWin(win.boardPt([10, 6.6, 33]));
                        win.clickWin(win._popup.mapToItem(null, 20, 20));
                    }, () => win.boardSnapshot() === snap, 300],
                    ["package", "a click on the package opens the tuning", () => {
                        win.clickWin(win.pkgPt(win.partTile()));
                    }, () => win._popup.secondaryOpen && win._popup.secondaryKey === "tuning"],
                    ["package", "the engine's secondary is out and shows the tuning panel", null, () => win.childShown("tuning"), 0, win.childState],
                    ["card", "a click on the card while it is out re-keys it to the GPU settings", () => {
                        win.clickWin(win.boardPt(win.partCard()));
                    }, () => win._popup.secondaryOpen && win._popup.secondaryKey === "gpu"],
                    ["card", "the engine's secondary swaps to the GPU panel and shows it", null, () => win.childShown("gpu"), 0, win.childState],
                    ["package", "the package re-keys it back to the tuning", () => {
                        win.clickWin(win.pkgPt(win.partTile()));
                    }, () => win._popup.secondaryKey === "tuning" && win.childShown("tuning"), 0, win.childState],
                    ["package", "the same part again closes it", () => {
                        win.clickWin(win.pkgPt(win.partTile()));
                    }, () => !win._popup.secondaryOpen && engine.childPopup.phase === "closed", 0, win.childState],
                    ["card", "after it has gone a click on the card opens the GPU settings afresh", () => {
                        win.clickWin(win.boardPt(win.partCard()));
                    }, () => win._popup.secondaryKey === "gpu" && win.childShown("gpu"), 0, win.childState],
                    ["card", "the same part again closes it", () => {
                        win.clickWin(win.boardPt(win.partCard()));
                    }, () => !win._popup.secondaryOpen && engine.childPopup.phase === "closed", 0, win.childState],
                    ["lever", "a click on the DIP lever, the limit off, asks for the 80 % limit", () => {
                        win.clickWin(win.boardPt(win.partLever(true)));
                    }, () => mock.chargeLimitTarget === 80],
                    ["lever", "and the limit lands on the machine and on the bar's cap", null, () => mock.battery.limitOn === true && siliconButton.limitOn === true],
                    ["lever", "the lever, now at 80, asks for 100 again", () => {
                        win.clickWin(win.boardPt(win.partLever(false)));
                    }, () => mock.chargeLimitTarget === 100],
                    ["lever", "and that lands too", null, () => mock.battery.limitOn === false && siliconButton.limitOn === false]
                ], next);
            }],
            ["O13 the idle ladder: its knobs reach their targets, it walks down, the readout says where it stands", next => {
                let before = null;
                win.expect("O13", [
                    ["popup", "the popup is out and settled", () => {
                        if (!owner.popupMine)
                            owner.open();
                    }, () => owner.popupMine && engine.thePopup.phase === "open" && engine.thePopup.contentOpacity >= 0.99 && !!win._clock && !!win._board && !!win._sounds],
                    ["clock", "the rates and the rest / wake times reach the open popup's clock", () => {
                        mot.aliveMs = 20;
                        mot.calmMs = 40;
                        mot.restSeconds = 0.5;
                        mot.wakeSeconds = 0.2;
                    }, () => win._clock.aliveMs === 20 && win._clock.calmMs === 40 && win._clock.restSeconds === 0.5 && win._clock.wakeSeconds === 0.2, 0,
                     () => win._clock.aliveMs + " " + win._clock.calmMs + " " + win._clock.restSeconds + " " + win._clock.wakeSeconds],
                    ["scene", "the MUX breath's length and depth reach the board", () => {
                        mot.muxBreathS = 2.4;
                        mot.muxBreathDepth = 0.3;
                    }, () => win._board.muxBreathS === 2.4 && win._board.muxBreathDepth === 0.3, 0, () => win._board.muxBreathS + " " + win._board.muxBreathDepth],
                    ["idle", "the ladder's two times reach the mock's own ladder, its config untouched", () => {
                        before = mock.config;
                        mot.calmAfterMs = 1500;
                        mot.haltAfterMs = 3000;
                    }, () => mock.idleLadder.calmAfterMs === 1500 && mock.idleLadder.haltAfterMs === 3000 && mock.config === before,
                     0, () => mock.idleLadder.calmAfterMs + " " + mock.idleLadder.haltAfterMs],
                    ["ladder", "left alone it goes calm", null, () => mock.idleState === "calm", 0, () => mock.idleState],
                    ["ladder", "then halts, and the clock parks itself on a still picture", null,
                     () => mock.idleState === "halt" && win._clock.parked === true && win._clock.live === 0, 0, () => win.motionText],
                    ["readout", "the Motion tab's readout says halt and parked", null, () => /ladder: halt/.test(win.motionText) && /parked/.test(win.motionText), 0, () => win.motionText],
                    ["ladder", "a touch wakes it: alive, the clock runs again, the readout follows", () => {
                        mock.touch();
                    }, () => mock.idleState === "alive" && win._clock.parked === false && /ladder: alive/.test(win.motionText) && /running every/.test(win.motionText), 0, () => win.motionText],
                    ["panel", "the panel's defaults put every one of them back", () => {
                        mot.aliveMs = 16;
                        mot.calmMs = 33;
                        mot.restSeconds = 1;
                        mot.wakeSeconds = 0.4;
                        mot.muxBreathS = 1.6;
                        mot.muxBreathDepth = 0.45;
                        mot.calmAfterMs = 10000;
                        mot.haltAfterMs = 30000;
                    }, () => win._clock.aliveMs === 16 && win._clock.calmMs === 33 && win._clock.restSeconds === 1 && win._clock.wakeSeconds === 0.4
                             && win._board.muxBreathS === 1.6 && win._board.muxBreathDepth === 0.45
                             && mock.idleLadder.calmAfterMs === 10000 && mock.idleLadder.haltAfterMs === 30000]
                ], next);
            }],
            ["O14 the Entrance button plays the power-on again, from a parked clock too", next => {
                let low = 1;
                win.expect("O14", [
                    ["popup", "the popup is out, powered on, and left alone until its clock parks", () => {
                        if (!owner.popupMine)
                            owner.open();
                        mot.calmAfterMs = 1000;
                        mot.haltAfterMs = 2000;
                        mot.restSeconds = 0.3;
                    }, () => owner.popupMine && engine.thePopup.phase === "open" && !!win._clock && win._clock.parked === true && win._director.entranceDone
                             && win._board.power >= 0.999, 0, () => win.motionText],
                    ["button", "pressed on a parked clock it wakes the ladder and starts the power-on from dark", () => {
                        low = 1;
                        win.replayEntrance();
                    }, () => mock.idleState === "alive" && win._clock.parked === false && win._director.entranceRunning === true, 0, () => win.motionText],
                    ["button", "the board goes dark", null, () => {
                        low = Math.min(low, win._board.power);
                        return low < 0.3;
                    }, 0, () => "lowest power seen " + low],
                    ["button", "and powers back on: the film plays out and the board is at full power", null,
                     () => win._director.entranceDone && win._director.entranceRunning === false && win._board.power >= 0.999, 0, () => win.motionText + ", power " + win._board.power],
                    ["panel", "the ladder's times put back", () => {
                        mot.calmAfterMs = 10000;
                        mot.haltAfterMs = 30000;
                        mot.restSeconds = 1;
                    }, () => mock.idleLadder.calmAfterMs === 10000 && mock.idleLadder.haltAfterMs === 30000 && win._clock.restSeconds === 1]
                ], next);
            }],
            ["O15 the Sounds tab: volumes, debounce, the six auditions through the stub", next => {
                const dir = RepoRoot.dir + "/assets/sounds/silicon/";
                // the takes the panel picks below: latch b, switch c, plug b, plug out c (the way out has a take of its own)
                const files = { "Latch seats": "latch_b.wav", "Latch lets go": "latch_b.wav", "Limit on": "dip_c.wav", "Limit off": "dip_c.wav", "Plug in": "plug_b.wav", "Plug out": "plug_out_c.wav" };
                const level = { latch: 0.5, dip: 0.35, plug: 0.6 };
                let n0 = 0;
                const items = [
                    ["stub", "the runner's pw-play stub is named: a probe never plays a sound itself", null, () => win.stubLog !== "" && win.stubPlay !== ""]
                ];
                if (win.stubLog !== "" && win.stubPlay !== "") {
                    items.push(["popup", "the popup is out", () => {
                        if (!owner.popupMine)
                            owner.open();
                    }, () => owner.popupMine && engine.thePopup.phase === "open" && !!win._sounds]);
                    items.push(["volumes", "the three volumes reach the open popup's sounds", () => {
                        snd.latch = level.latch;
                        snd.dip = level.dip;
                        snd.plug = level.plug;
                    }, () => win._sounds.latchVolume === 0.5 && win._sounds.dipVolume === 0.35 && win._sounds.plugVolume === 0.6, 0,
                       () => win._sounds.latchVolume + " " + win._sounds.dipVolume + " " + win._sounds.plugVolume]);
                    items.push(["debounce", "the debounce reaches the open popup's sounds", () => {
                        snd.debounceMs = 150;
                    }, () => win._sounds.debounceMs === 150]);
                    items.push(["takes", "the panel starts on the module's own picks (the user's: latch a, dip a, plug c, plug out a)", null,
                                () => win._sounds.variants.latch === "a" && win._sounds.variants.dip === "a" && win._sounds.variants.plug === "c" && win._sounds.variants.plug_out === "a",
                                0, () => JSON.stringify(win._sounds.variants)]);
                    items.push(["takes", "a take picked on the panel reaches the open popup's sounds, the plug out's as its own", () => {
                        snd.latchVariant = 1;
                        snd.dipVariant = 2;
                        snd.plugVariant = 1;
                        snd.plugOutVariant = 2;
                    }, () => win._sounds.variants.latch === "b" && win._sounds.variants.dip === "c" && win._sounds.variants.plug === "b" && win._sounds.variants.plug_out === "c", 0, () => JSON.stringify(win._sounds.variants)]);
                    items.push(["stub", "the popup's own player is pointed at the stub (the probe's one hook: offscreen it is otherwise silent)", () => {
                        win._sounds.pwPlay = win.stubPlay;
                    }, () => win._sounds.pwPlay === win.stubPlay]);
                    win.auditions.forEach(a => items.push(["audition", a.label + ": one pw-play, " + files[a.label] + ", at the sound's own volume", () => {
                        n0 = win.stubLines("PLAY ").length;
                        win.auditionSound(a.name, a.on);
                    }, () => {
                        const l = win.stubLines("PLAY ");
                        return l.length === n0 + 1 && l[n0] === "PLAY --volume=" + level[a.name] + " " + dir + files[a.label];
                    }, 0, () => win.stubLines("PLAY ").slice(n0).join(" | ") || "no call"]));
                    items.push(["take", "an audition that names a take plays it, whatever is picked: dip a at the dip's volume", () => {
                        n0 = win.stubLines("PLAY ").length;
                        win.auditionSound("dip", true, "a");
                    }, () => {
                        const l = win.stubLines("PLAY ");
                        return l.length === n0 + 1 && l[n0] === "PLAY --volume=" + level.dip + " " + dir + "dip_a.wav";
                    }, 0, () => win.stubLines("PLAY ").slice(n0).join(" | ") || "no call"]);
                    items.push(["zero", "all three volumes at 0: the popup's sounds say so", () => {
                        snd.latch = 0;
                        snd.dip = 0;
                        snd.plug = 0;
                    }, () => win._sounds.latchVolume === 0 && win._sounds.dipVolume === 0 && win._sounds.plugVolume === 0]);
                    items.push(["zero", "six auditions at volume 0 start no process at all", () => {
                        n0 = win.stubLines("PLAY ").length;
                        win.auditions.forEach(a => win.auditionSound(a.name, a.on));
                    }, () => win.stubLines("PLAY ").length === n0, 800, () => win.stubLines("PLAY ").slice(n0).join(" | ")]);
                    items.push(["zero", "the stub still hears a sound above 0 (the check could have failed)", () => {
                        snd.latch = 0.5;
                        n0 = win.stubLines("PLAY ").length;
                        win.auditionSound("latch", true);
                    }, () => win.stubLines("PLAY ").length === n0 + 1, 0, () => win.stubLines("PLAY ").slice(n0).join(" | ") || "no call"]);
                    items.push(["panel", "the panel's defaults put the sounds back, and the popup's own player is its own again", () => {
                        snd.latch = 0.2;
                        snd.dip = 0.2;
                        snd.plug = 0.2;
                        snd.debounceMs = 80;
                        snd.latchVariant = 0;
                        snd.dipVariant = 0;
                        snd.plugVariant = 2;
                        snd.plugOutVariant = 0;
                        win._sounds.pwPlay = "pw-play";
                    }, () => win._sounds.latchVolume === 0.2 && win._sounds.dipVolume === 0.2 && win._sounds.plugVolume === 0.2
                             && win._sounds.debounceMs === 80 && win._sounds.pwPlay === "pw-play"
                             && JSON.stringify(win._sounds.variants) === JSON.stringify({ latch: "a", dip: "a", plug: "c", plug_out: "a" })]);
                }
                win.expect("O15", items, next);
            }],
            ["O16 the MUX flows: the guard's knobs, restart, the keep window, the shell's start, a blocked app", next => {
                const told = () => win.notes("silicon-mux");
                let n0 = 0;
                win.useNotifications(true);
                const items = [
                    ["popup", "the desk, the popup out, no restart waiting", () => {
                        mock.playing = false;
                        mock.scenario = "desk";
                        mock.timeMs = 0;
                        if (!owner.popupMine)
                            owner.open();
                    }, () => owner.popupMine && engine.thePopup.phase === "open" && siliconButton.percent === 100 && !mock.gpu.mux.pending && mock.gpuMode === 2, 0,
                     () => "mine " + owner.popupMine + " phase " + engine.thePopup.phase + " percent " + siliconButton.percent + " pending " + mock.gpu.mux.pending + " mode " + mock.gpuMode],
                    ["guard", "silicon-mux.service not running: the pre-check says so in the helper's words", () => {
                        mach.muxUnit = false;
                    }, () => mock.gpu.mux.prechecks.ok === false && /silicon-mux\.service is not active/.test(mock.gpu.mux.prechecks.why), 0, () => JSON.stringify(mock.gpu.mux.prechecks)],
                    ["guard", "and a dGPU-only request is refused with them, nothing queued", () => {
                        mock.setGpuMode(3, {});
                    }, () => /silicon-mux\.service is not active/.test(mock.caption.gpuError) && !mock.gpu.mux.pending, 0, () => mock.caption.gpuError + " / pending " + mock.gpu.mux.pending],
                    ["guard", "running again: the pre-check passes", () => {
                        mach.muxUnit = true;
                    }, () => mock.gpu.mux.prechecks.ok === true],
                    ["windows", "the boot and keep windows reach the guard's facts", () => {
                        mach.bootWindowS = 90;
                        mach.promptWindowS = 45;
                    }, () => mock.gpu.mux.bootWindowS === 90 && mock.gpu.mux.promptWindowS === 45, 0, () => mock.gpu.mux.bootWindowS + " / " + mock.gpu.mux.promptWindowS],
                    ["request", "dGPU-only is asked for: queued, and the bar's GPU glyph breathes", () => {
                        mock.setGpuMode(3, {});
                    }, () => mock.gpu.mux.state === "queued" && siliconButton.muxPending, 0, () => mock.gpu.mux.state + " pending " + siliconButton.muxPending],
                    ["restart", "Restart now: the dGPU-only wiring is in and the keep prompt awaits its answer", () => {
                        mock.muxRebootNow();
                    }, () => mock.gpu.mux.state === "awaiting-keep" && mock.gpuMode === 3, 0, () => mock.gpu.mux.state + " step " + mock.gpuMode],
                    ["restart", "the keep prompt is up, as a TOAST: fixed, with Keep and Go back now, and no secondary opened for it", null, () => {
                        const r = win.keepToast();
                        return !!r && r.fixed === true && win.keepToastShown() && r.summary === "Keep dGPU only?"
                               && r.actions.map(a => a.id).join() === "back,keep" && !win._popup.secondaryOpen;
                    }, 0, () => JSON.stringify(win.keepToast())],
                    ["restart", "the helper was told it is on screen, and the keep window is the knob's: the deadline is no further off than 45 s", null, () => {
                        const rem = mock.gpu.mux.deadlineMs - Date.now();
                        return rem > 0 && rem <= 46000;
                    }, 0, () => Math.round((mock.gpu.mux.deadlineMs - Date.now()) / 1000) + " s"],
                    ["restart", "the toast's drain is that deadline (the instant and its span, no further than the knob)", null, () => {
                        const r = win.keepToast();
                        return !!r && Math.abs(r.deadlineMs - mock.gpu.mux.deadlineMs) < 2500 && r.deadlineTotalMs > 0 && r.deadlineTotalMs <= 46500;
                    }, 0, () => JSON.stringify([win.keepToast() && win.keepToast().deadlineMs, mock.gpu.mux.deadlineMs])],
                    ["run out", "Run out the keep window: the guard puts Hybrid back (reverted, step 2)", () => {
                        win.runOutKeepWindow();
                    }, () => mock.gpu.mux.state === "reverted" && mock.gpuMode === 2, 0, () => mock.gpu.mux.state + " step " + mock.gpuMode],
                    ["run out", "and the keep window knob is back where the panel has it", null, () => mock.promptWindowS === 45 && mock.gpu.mux.promptWindowS === 45],
                    ["notice", "the toast says where it is going meanwhile: Going back to Hybrid, its buttons gone", null, () => {
                        const r = win.keepToast();
                        return !!r && r.summary === "Going back to Hybrid" && r.actions.length === 0;
                    }, 0, () => JSON.stringify(win.keepToast())],
                    ["notice", "a revert this shell saw happening is not told at once (a real one reboots first)", null, () => told().length === 0 && mock.gpu.mux.outcomeSeen === false, 300,
                     () => told().length + " told, seen " + mock.gpu.mux.outcomeSeen],
                    ["notice", "Restart the shell: ONE notification (stored in the manager, no OSD card), and the outcome is marked told", () => {
                        win.restartShell();
                    }, () => told().length === 1 && /not kept/.test(told()[0].summary) && mock.gpu.mux.outcomeSeen === true, 0,
                     () => JSON.stringify(told().map(r => r.summary)) + ", seen " + mock.gpu.mux.outcomeSeen],
                    ["notice", "and the keep toast is gone: it was told", null, () => win.keepToast() === null && !win.keepToastShown()],
                    ["notice", "the shell started again tells nothing more (told once)", () => {
                        win.restartShell();
                    }, () => told().length === 1 && win.keepToast() === null, 600, () => told().length + " told"],
                    ["notice", "the notification service goes (the blocked app's checks below read the notify-send stub)", () => {
                        win.useNotifications(false);
                    }, () => NotificationBus.service === null],
                    ["windows", "the guard's windows back to the helper's own", () => {
                        mach.bootWindowS = 300;
                        mach.promptWindowS = 120;
                    }, () => mock.gpu.mux.bootWindowS === 300 && mock.gpu.mux.promptWindowS === 120]
                ];
                if (win.stubLog !== "") {
                    items.push(["blocked", "outside Smart a blocked app notifies nothing", () => {
                        n0 = win.stubLines("NOTIFY ").length;
                        win.emitBlockedApp();
                    }, () => win.stubLines("NOTIFY ").length === n0, 700, () => win.stubLines("NOTIFY ").slice(n0).join(" | ")]);
                    items.push(["blocked", "Smart is on", () => {
                        mock.externalGpuMode(1);
                    }, () => siliconButton.gpuMode === 1]);
                    items.push(["blocked", "in Smart the next app notifies ONCE, through the stub, by its name", () => {
                        n0 = win.stubLines("NOTIFY ").length;
                        win.emitBlockedApp();
                    }, () => {
                        const l = win.stubLines("NOTIFY ");
                        return l.length === n0 + 1 && /krita stayed on the integrated GPU/.test(l[n0]);
                    }, 0, () => win.stubLines("NOTIFY ").slice(n0).join(" | ") || "no call"]);
                    items.push(["blocked", "Hybrid again", () => {
                        mock.externalGpuMode(2);
                    }, () => siliconButton.gpuMode === 2]);
                } else {
                    items.push(["stub", "the runner's notify-send stub is named: a probe never notifies the desktop itself", null, () => false]);
                }
                win.expect("O16", items, () => {
                    win.useNotifications(false);
                    next();
                });
            }],
            ["O17 the Live switch, up to the switch: one click arms it, the arming runs out", next => {
                win.expect("O17", [
                    ["arm", "one click arms the switch and goes no further: still the mock, no real service built, the owner on the mock", () => {
                        win.armRealService();
                    }, () => win.liveArmed === true && win.siliconSource === "mock" && win.live === false && win.liveService === null && liveLoader.item === null
                             && owner.svc === mock && owner.ownsService === false, 0, () => win.liveArmed + " / " + win.siliconSource + " / " + win.liveService],
                    ["timeout", "the arming runs out after " + win.liveArmMs + " ms: disarmed, still the mock", null,
                     () => win.liveArmed === false && win.siliconSource === "mock" && win.liveService === null && owner.svc === mock, win.liveArmMs + 600,
                     () => win.liveArmed + " / " + win.siliconSource + " / " + win.liveService]
                ], next);
            }],
            ["O18 the dialogs are secondaries on the real engine, and where a secondary opens is the user's setting (R5 D1)", next => {
                const pop = () => engine.thePopup;
                // the secondary's box against the popup's (engine coordinates): below it, above it, to its right, to its left
                const settled = () => engine.childOpen && engine.childPopup.phase === "open";
                const below = () => settled() && engine.childY >= pop().popY + pop().popH - 2;
                const above = () => settled() && engine.childY + engine.childH <= pop().popY + 2;
                const rightOf = () => settled() && engine.childX >= pop().popX + pop().popW - 2;
                const leftOf = () => settled() && engine.childX + engine.childW <= pop().popX + 2;
                // the engine's three words for a side, on the bar this run has: far is AWAY from the bar (below a top bar, left of a right one),
                // start and end run ALONG it (left / right of a top bar's popup, above / below a right bar's)
                const right = win.barEdge === "right";
                const far = () => right ? leftOf() : below();
                const alongStart = () => right ? above() : leftOf();
                const alongEnd = () => right ? below() : rightOf();
                // (the stage's top edge cuts a secondary hung above a right bar's popup: its middle is not in the window, which childShown asks)
                const shownAt = kind => (right && owner.secondarySide === "start") || win.childShown(kind);
                const boxes = () => "popup " + [pop().popX, pop().popY, pop().popW, pop().popH].map(Math.round).join(",")
                                    + " child " + [engine.childX, engine.childY, engine.childW, engine.childH].map(Math.round).join(",") + " " + engine.childPopup.phase + " side " + owner.secondarySide;
                // a real click on a button of the dialog the engine is showing (its own centres: laterCentre(), cancelCentre(), ...)
                const clickDialog = name => {
                    const panel = engine.childPopup.contentItem.panel;
                    const c = panel[name]();
                    win.clickWin(panel.mapToItem(null, c.x, c.y));
                };
                const closed = () => !win._popup.secondaryOpen && engine.childPopup.phase === "closed";
                let snap = "";
                win.expect("O18", [
                    ["popup", "the popup is out and settled on a calm desk in Hybrid, nothing hung from it, the secondary's side at its default (far)", () => {
                        tun.secondarySide = 0;
                        mock.playing = false;
                        mock.scenario = "desk";
                        mock.timeMs = 0;
                        mach.dgpu = 0;
                        mock.externalGpuMode(2);
                        if (!owner.popupMine)
                            owner.open();
                        if (win._popup && win._popup.secondaryOpen)
                            win._popup.closeSecondary();
                    }, () => owner.popupMine && engine.thePopup.phase === "open" && engine.thePopup.contentOpacity >= 0.99 && !!win._popup && !engine.childOpen
                             && !mock.gpu.mux.pending && mock.gpuMode === 2 && owner.secondarySide === "far", 0, boxes],
                    ["restart", "a step to dGPU-only queues the request and the restart card opens BY ITSELF, as the engine's secondary", () => {
                        win._popup.stepGpu(1);
                    }, () => win._popup.secondaryKey === "mux" && win.childShown("mux"), 0, win.childState],
                    ["side", "far: it hangs from the popup's far face (away from the bar), never over it", null, () => far(), 0, boxes],
                    ["side", "end: the setting moves the secondary that is out to the popup's end (along the bar)", () => {
                        tun.secondarySide = 2;
                    }, () => alongEnd() && shownAt("mux"), 0, boxes],
                    ["side", "start: ... and to its start", () => {
                        tun.secondarySide = 1;
                    }, () => alongStart() && shownAt("mux"), 0, boxes],
                    ["side", "far again", () => {
                        tun.secondarySide = 0;
                    }, () => far() && shownAt("mux"), 0, boxes],
                    ["restart", "its words: where the request goes (dGPU only), the NVIDIA card, the two minutes", null, () => {
                        const c = engine.childPopup.contentItem.panel;
                        return c.title === "dGPU only needs a restart" && c.body.indexOf("NVIDIA card") >= 0;
                    }, 0, () => engine.childPopup.contentItem.panel.title],
                    ["restart", "Later is a real click on the card's button: the secondary closes, the request stays", () => {
                        clickDialog("laterCentre");
                    }, () => closed() && mock.gpu.mux.state === "queued", 0, win.childState],
                    ["restart", "a click on the card (the GPU part) opens the restart card again, not the GPU panel", () => {
                        win.clickWin(win.boardPt(win.partCard()));
                    }, () => win._popup.secondaryKey === "mux" && win.childShown("mux"), 0, win.childState],
                    ["restart", "Cancel withdraws it: the record is cancelled and the secondary goes", () => {
                        clickDialog("cancelCentre");
                    }, () => mock.gpu.mux.state === "cancelled" && closed(), 0, win.childState],
                    ["panel", "with nothing waiting a click on the card is the GPU panel's again, at the same side", () => {
                        mock.externalGpuMode(2);
                        win.clickWin(win.boardPt(win.partCard()));
                    }, () => win._popup.secondaryKey === "gpu" && win.childShown("gpu") && far(), 0, boxes],
                    ["question", "apps on the dGPU, and a step that would block them: the question takes the secondary over the panel", () => {
                        mach.dgpu = 3;
                    }, () => mock.gpu.holders.length === 2 && mock.gpu.awake, 0, () => JSON.stringify(mock.gpu.holders)],
                    ["question", "... asked by the step itself", () => {
                        win._popup.stepGpu(-1);
                    }, () => win._popup.secondaryKey === "confirm" && win.childShown("confirm") && win._popup._panelKey === "gpu", 0, win.childState],
                    ["question", "it names the apps and the mode", null, () => {
                        const c = engine.childPopup.contentItem.panel;
                        return c.appsText === "steam, proton" && c.modeName === "Smart";
                    }, 0, () => engine.childPopup.contentItem.panel.appsText],
                    ["question", "Cancel is a real click: the question goes, the GPU panel it covered is back, nothing was asked", () => {
                        clickDialog("cancelCentre");
                    }, () => win._popup.secondaryKey === "gpu" && win.childShown("gpu") && mock.gpuModeTarget === 2, 0, win.childState],
                    ["question", "the panel put away, the apps gone", () => {
                        win._popup.closeSecondary();
                        mach.dgpu = 0;
                    }, () => closed() && mock.gpu.holders.length === 0],
                    ["popup", "the machine back as it was (Hybrid, nothing waiting) and the setting at its default", () => {
                        mock._status = TL.defaultStatus();
                        mock._mode = 1;
                        mock._afterMuxMode = null;
                        mock._compute();
                        tun.secondarySide = 0;
                    }, () => mock.gpu.wiring === "hybrid" && mock.gpuMode === 2 && !mock.gpu.mux.pending && closed()]
                ], next);
            }],
            ["O19 the keep prompt at a login is a toast: no popup opens, the helper is told it is on screen, Keep is its action", next => {
                win.useNotifications(true);
                win.expect("O19", [
                    ["popup", "the popup is shut and the machine is calm: Hybrid, nothing waiting", () => {
                        if (owner.popupMine)
                            owner.close();
                        mock._status = TL.defaultStatus();
                        mock._mode = 1;
                        mock._afterMuxMode = null;
                        mock._compute();
                    }, () => !owner.popupMine && engine.thePopup.phase === "closed" && !engine.childOpen && mock.gpu.mux.state === "" && mock.gpuMode === 2 && win.keepToast() === null],
                    ["login", "the machine is at the keep prompt: the toast comes up by itself, and no popup opens for it", () => {
                        win.showDialog("keep-login");
                    }, () => win.keepToastShown() && !owner.popupMine && engine.thePopup.phase === "closed" && !engine.childOpen, 0,
                     () => JSON.stringify(win.keepToast()) + " popup " + owner.popupMine],
                    ["login", "the helper was told it is on screen: the guard's window is the prompt's own, no more than the knob (120 s)", null, () => {
                        const rem = mock.gpu.mux.deadlineMs - Date.now();
                        return rem > 0 && rem <= 121000;
                    }, 0, () => Math.round((mock.gpu.mux.deadlineMs - Date.now()) / 1000) + " s"],
                    ["login", "the drain is the guard's own deadline, and the card has no swipe and no click (fixed)", null, () => {
                        const r = win.keepToast();
                        return !!r && r.fixed === true && r.deadlineMs > 0 && Math.abs(r.deadlineMs - mock.gpu.mux.deadlineMs) < 2500 && r.deadlineTotalMs > 0
                               && !toastSvc.remove(r.uid) && !toastSvc.activate(r.uid);
                    }, 0, () => JSON.stringify(win.keepToast())],
                    ["login", "the figure is the guard's clock", null, () => /^\d:\d\d$/.test(owner.muxWatcher.prompt.countdownText) && owner.muxWatcher.prompt.figureShown,
                     0, () => owner.muxWatcher.prompt.countdownText],
                    ["login", "Keep is the toast's action: the record is kept and the toast goes, nothing else is said", () => {
                        toastSvc.invoke(win.keepToast().uid, "keep");
                    }, () => mock.gpu.mux.state === "kept" && win.keepToast() === null && !win.keepToastShown(), 0, () => mock.gpu.mux.state],
                    ["login", "the lock comes while a prompt is due: nothing is posted under it, and the unlock brings the toast", () => {
                        mock._status = TL.defaultStatus();
                        mock._compute();
                        owner.muxWatcher.locked = true;
                        win.showDialog("keep-login");
                    }, () => win.keepToast() === null && mock.gpu.mux.state === "awaiting-keep", 300, () => JSON.stringify(win.keepToast())],
                    ["login", "... the unlock", () => {
                        owner.muxWatcher.locked = false;
                    }, () => win.keepToastShown(), 0, () => JSON.stringify(win.keepToast())],
                    ["login", "Go back now: Hybrid is asked for and the restart follows (the mock restarts at once)", () => {
                        toastSvc.invoke(win.keepToast().uid, "back");
                    }, () => mock.gpu.wiring === "hybrid" && mock.gpu.mux.state !== "awaiting-keep", 0, () => mock.gpu.mux.state + " / " + mock.gpu.wiring],
                    ["popup", "the machine back as it was", () => {
                        mock._status = TL.defaultStatus();
                        mock._mode = 1;
                        mock._afterMuxMode = null;
                        mock._compute();
                    }, () => mock.gpu.wiring === "hybrid" && mock.gpuMode === 2 && !mock.gpu.mux.pending && win.keepToast() === null]
                ], () => {
                    win.useNotifications(false);
                    next();
                });
            }],
            // X1..: repros, not gates (STEPS=X1 runs one): a secondary opened while the one before it is still closing
            ["X1 a secondary opened a moment after another closed (STEPS=X1; the wait in ms: REOPEN_MS)", next => {
                const wait = Number(Quickshell.env("REOPEN_MS") || 250);
                win.expect("X1", [
                    ["board", "the popup is out and settled, nothing hung from it", () => {
                        if (!owner.popupMine)
                            owner.open();
                        if (win._popup && win._popup.secondaryOpen)
                            win._popup.closeSecondary();
                    }, () => owner.popupMine && engine.thePopup.phase === "open" && engine.thePopup.contentOpacity >= 0.99 && !!win._popup && !engine.childOpen
                             && engine.childPopup.phase === "closed"],
                    ["package", "a click opens the tuning", () => {
                        win.clickWin(win.pkgPt(win.partTile()));
                    }, () => win.childShown("tuning"), 0, win.childState],
                    ["package", "the same part closes it", () => {
                        win.clickWin(win.pkgPt(win.partTile()));
                    }, () => !win._popup.secondaryOpen, wait, win.childState],
                    ["card", "after " + wait + " ms a click on the card opens the GPU settings", () => {
                        win.clickWin(win.boardPt(win.partCard()));
                    }, () => win.childShown("gpu"), 0, win.childState]
                ], next);
            }]
        ];
    }
}
