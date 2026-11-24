pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

import "modules/common/mockup"
import "modules/common/theme"
import "modules/bridge"
import "modules/bridge/data"
import "modules/bridge/data/BridgeScenarios.js" as Scenarios

// =============================================================================
// mockups/bridge.qml -- the bridge's popup on the mockup framework: the PHONE whose screen is the control panel
// (modules/bridge/BridgePopup.qml), alone on the stage at its own implicit size (320 x 664), over a BridgeService that is NOT
// live: it starts nothing and reads the scenarios of BridgeScenarios (docs/contracts/bridge.md). There is no live switch here:
// the real tool is the user's, behind SHELL_SERVICES, and this mockup never reaches the machine.
//
// THE PANEL. Run drives the content (a scenario, the phone's turn, the pages, a drop, the calls the popup made). Body is the
// phone: the stage's own numbers (size, camera, the turns, the light that follows the pointer) and the body's lamps, strip
// light, room, shadow and materials. Screen is every number of the display and of the device sheet (BridgeStyle). Motion is the
// screen's durations. Colours is the device sheet's inks (the plate is the phone's own paint, so they are fixed colours).
//
// Env (this file's own; the framework's GRAB / GRAB_MS apply), applied once, 400 ms after load, for renders:
//   BRIDGE_SCENARIO=none|pairing|asleep|wifi|wired|mirroring|mounted|transfer|error   (default wired)
//   BRIDGE_PAGE=mirror|files|pair|device   open that page
//   BRIDGE_FACE=back                       turn to the back
//   BRIDGE_POSE=<turns>                    hold the body at that many turns (0 the front, 0.5 the back)
//   BRIDGE_TILT=<degrees>                  ... tipped by this much (90 the bottom wall, -90 the top one)
//   BRIDGE_FLIP=1                          play the open's full turn (off by default in a render)
//   BRIDGE_MENU=1                          open the device menu
//
//   quickshell -p mockups/bridge.qml
// =============================================================================
MockupWindow {
    id: win

    moduleId: "bridge"
    title: "Bridge mockup"
    stageLabel: "BridgePopup (drop-in for the bar's popup)"
    content: stageItem
    stageColor: Theme.surface
    target: popup.stage
    targets: ({
            stageParams: popup.stage,
            bodyParams: popup.stage.body,
            screenParams: popup.style,
            motionParams: popup.style
        })

    lists: ({
            stageParams: win.stageParams,
            bodyParams: win.bodyParams,
            screenParams: win.screenParams,
            motionParams: win.motionParams
        })

    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        {
            name: "Body",
            subs: [
                {
                    name: "Stage",
                    lists: ["stageParams"]
                },
                {
                    name: "Light",
                    lists: ["bodyParams"],
                    groups: ["Lamps", "Strip light"]
                },
                {
                    name: "Surface",
                    lists: ["bodyParams"],
                    groups: ["Room", "Shadow", "Materials"]
                }
            ]
        },
        {
            name: "Screen",
            subs: [
                {
                    name: "Display",
                    lists: ["screenParams"],
                    groups: ["Display", "Status bar", "Cell bars", "Battery", "Home indicator"]
                },
                {
                    name: "Home",
                    lists: ["screenParams"],
                    groups: ["Heading", "Tiles", "Send figures"]
                },
                {
                    name: "Pages",
                    lists: ["screenParams"],
                    groups: ["Page frame", "Page type", "Rows and buttons", "Mirror page", "Files page", "Pairing", "Device menu"]
                },
                {
                    name: "Details",
                    lists: ["screenParams"],
                    groups: ["Device sheet"]
                }
            ]
        },
        {
            name: "Motion",
            lists: ["motionParams"]
        }
    ]

    // =====================================================================
    //  THE DROP-IN CONTENT
    // =====================================================================
    Item {
        id: stageItem

        implicitWidth: popup.implicitWidth
        implicitHeight: popup.implicitHeight

        // The mock service: nothing runs, the scenario's lines go through the real parser. A render's pacing is instant.
        BridgeService {
            id: svc
            live: false
            scenario: win._envScenario
            mockLineMs: win._rendering ? 0 : 1200
            mockStepMs: win._rendering ? 0 : 700
        }
        BridgePopup {
            id: popup
            anchors.fill: parent
            service: svc
            flipOnOpen: win._envFlip || (!win._rendering && svc.settings.flip.onOpen)
            freeLookHold: win.freeLook
        }
    }

    // ---- the env hooks -----------------------------------------------------------------------------------------------
    readonly property string _envScenario: Quickshell.env("BRIDGE_SCENARIO") || "wired"
    readonly property bool _rendering: (Quickshell.env("GRAB") || Quickshell.env("PANEL_GRAB") || Quickshell.env("SHEET_GRAB") || "") !== ""
    readonly property bool _envFlip: Quickshell.env("BRIDGE_FLIP") === "1"
    // the Run tab's free look: holds the popup's look without the key (in the popup: Alt, held)
    property bool freeLook: false
    Timer {
        interval: 400
        running: win._rendering || (Quickshell.env("BRIDGE_PAGE") || Quickshell.env("BRIDGE_FACE") || Quickshell.env("BRIDGE_POSE") || Quickshell.env("BRIDGE_TILT") || Quickshell.env("BRIDGE_MENU")) !== ""
        onTriggered: {
            const page = Quickshell.env("BRIDGE_PAGE") || "";
            if (page !== "")
                popup.screenFace.openPage(page);
            if ((Quickshell.env("BRIDGE_FACE") || "") === "back")
                popup.stage.flipTo("back");
            const pose = Quickshell.env("BRIDGE_POSE") || "";
            if (pose !== "")
                popup.stage.pinTurn = parseFloat(pose);
            const tilt = Quickshell.env("BRIDGE_TILT") || "";
            if (tilt !== "") {
                popup.stage.pinTilt = parseFloat(tilt);
                if (pose === "")
                    popup.stage.pinTurn = 0;
            }
            if (Quickshell.env("BRIDGE_MENU") === "1")
                popup.openMenu();
        }
    }

    // =====================================================================
    //  THE MODULE'S OWN PANEL PAGES
    // =====================================================================
    pages: [
        MockupPage {
            id: runPage

            TipGroup {
                title: "Scenarios"
                blurb: "One click puts the mock service in a state; the screen follows what the lines say."
            }
            TipRow {
                tip: "Which of the mock's named states the service is in: no device, a phone asking to pair, asleep, on Wi-Fi, on the cable, mirroring, mounted, sending, or a failed call with the tool's own reasons. Each plays through the real parser; nothing touches a phone."
                Layout.fillWidth: true
                Flow {
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: Scenarios.names()
                        Button {
                            id: pick
                            required property string modelData
                            text: pick.modelData
                            highlighted: svc.scenario === pick.modelData
                            onClicked: svc.scenario = pick.modelData
                        }
                    }
                }
            }

            TipGroup {
                title: "Phone"
                blurb: "The body's own motions: the turns, and a pose held for a look."
            }
            TipRow {
                tip: "Flourish plays the whole turn that opens the popup, landing where it started. Turn flips to the other face by itself, as a lift past a third of a swipe does."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: "Flourish"
                    onClicked: popup.stage.flourish()
                }
                Button {
                    text: popup.stage.face === "front" ? "Turn to the back" : "Turn to the front"
                    onClicked: popup.stage.flipTo(popup.stage.face === "front" ? "back" : "front")
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Holds the body at this many turns (0 the front, 0.5 the back) so a pose can be looked at; the left end lets it go (free). While it is held, the faces are drawn live under the projection."
                Layout.fillWidth: true
                spacing: 8
                Label {
                    text: "pose"
                }
                Slider {
                    id: pose
                    Layout.fillWidth: true
                    from: -0.01
                    to: 1
                    stepSize: 0.01
                    value: popup.stage.pinTurn
                    onMoved: popup.stage.pinTurn = pose.value < 0 ? -1 : pose.value
                }
                Label {
                    Layout.preferredWidth: 44
                    horizontalAlignment: Text.AlignRight
                    text: popup.stage.pinTurn < 0 ? "free" : popup.stage.pinTurn.toFixed(2)
                    color: "#8A8A8C"
                }
            }
            TipRow {
                tip: "Tips the held body about its horizontal axis, degrees: 90 brings the bottom wall to the front (the port, the SIM tray, the speaker), -90 the top one (the jack, the infrared window, the grille). With the pose above it reaches every side. It only acts while the pose is held."
                Layout.fillWidth: true
                spacing: 8
                Label {
                    text: "tilt"
                }
                Slider {
                    id: tilt
                    Layout.fillWidth: true
                    from: -180
                    to: 180
                    stepSize: 1
                    value: popup.stage.pinTilt
                    onMoved: {
                        popup.stage.pinTilt = tilt.value;
                        if (popup.stage.pinTurn < 0)
                            popup.stage.pinTurn = 0;
                    }
                }
                Label {
                    Layout.preferredWidth: 44
                    horizontalAlignment: Text.AlignRight
                    text: Math.round(popup.stage.pinTilt) + "°"
                    color: "#8A8A8C"
                }
            }
            TipRow {
                tip: "Free look, as the popup does it: with the pointer over the phone hold Alt and move the pointer (nothing pressed); let go and the phone goes back to the face it showed. This switch holds the look without the key, so it can be tuned with both hands free (the Phone tab, group Free look). In the shell the pointer is hidden and kept in place meanwhile; a mockup moves nobody's pointer."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: win.freeLook ? "Free look: held (move over the phone)" : "Free look (or hold Alt)"
                    highlighted: win.freeLook
                    onClicked: win.freeLook = !win.freeLook
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "Pages"
                blurb: "The pages that grow out of the tiles, and the way back."
            }
            TipRow {
                tip: "Opens a page the way a click on its tile does (the tile grows into it), or goes back to the home screen. The page lives in the service, as it does in the shell."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: "Mirror page"
                    onClicked: popup.screenFace.openPage("mirror")
                }
                Button {
                    text: "Files page"
                    onClicked: popup.screenFace.openPage("files")
                }
                Button {
                    text: "Pair page"
                    onClicked: popup.screenFace.openPage("pair")
                }
                Button {
                    text: "Details page"
                    onClicked: popup.screenFace.openPage("device")
                }
                Button {
                    text: "Home"
                    onClicked: popup.screenFace.goBack()
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "Calls"
                blurb: "What the popup asks of the service."
            }
            TipRow {
                tip: "Drops two files on the display, as a drag from a file manager would: a send to the current device when the tool says it can, else the drop mark shakes. Opens the device menu as a click on the name does."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: "Drop two files"
                    onClicked: popup.dropped(["/home/demo/Pictures/IMG_2041.jpg", "/home/demo/Documents/notes.pdf"])
                }
                Button {
                    text: "Device menu"
                    onClicked: popup.openMenu()
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WrapAnywhere
                text: win._callsText
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 11
            }

            TipGroup {
                title: "State"
                blurb: "What the content believes right now."
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: "scenario: " + svc.scenario + "   screen: " + popup.screenFace.kind + "   page: " + (svc.page || "-") + "   face: " + popup.stage.face + (popup.stage.flipping ? " (turning)" : "") + "   size: " + popup.implicitWidth + " x " + popup.implicitHeight
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
            }
        }
    ]
    // the last calls the popup made, newest last
    readonly property string _callsText: {
        const c = svc.calls;
        const out = [];
        for (let i = Math.max(0, c.length - 6); i < c.length; i++)
            out.push(c[i].action + " " + c[i].key.replace(/^kdc:/, "") + (JSON.stringify(c[i].args) !== "{}" ? " " + JSON.stringify(c[i].args) : ""));
        return out.length > 0 ? "calls\n" + out.join("\n") : "calls: none yet";
    }

    // =====================================================================
    //  VALUES
    // =====================================================================
    readonly property var stageParams: [
        {
            label: "px per mm",
            prop: "pxPerMm",
            group: "Size",
            blurb: "How big the phone is and where it stands in the popup.",
            tip: "How big the phone is drawn: stage px per millimetre of the real body. 3.7 puts the 76 mm wide body into the 320 px popup with a little air round it.",
            val: 3.7,
            from: 2.5,
            to: 5,
            step: 0.05
        },
        {
            label: "top margin px",
            prop: "topMargin",
            group: "Size",
            tip: "Space between the popup's top edge and the phone's top edge, px; the foot has the same. 30 keeps a turn inside the popup: mid-turn the phone's near edge is nearer the camera and taller (tools/dev/bridge_body_probe.sh, `aligned`).",
            val: 30,
            from: 0,
            to: 60,
            step: 1
        },
        {
            label: "camera distance px",
            prop: "camDist",
            group: "Camera",
            blurb: "The viewer's eye: perspective of the turn.",
            tip: "How far the pinhole camera stands from the phone, stage px. Near makes the turn dramatic (strong perspective), far makes it flat; 2000 is far enough that the body is not distorted at rest.",
            val: 2000,
            from: 500,
            to: 6000,
            step: 50
        },
        {
            label: "half turn ms",
            prop: "halfTurnMs",
            group: "Turns",
            blurb: "The two motions of the body: the half turn and the whole turn.",
            tip: "The duration of a half turn to the other face by itself (a lift that commits one), ms. A scrub by the fingers follows them but never faster than this runs. 560 is slow enough to read as an object turning and short enough not to be waited for.",
            val: 560,
            from: 200,
            to: 1500,
            step: 10
        },
        {
            label: "flourish ms",
            prop: "flourishMs",
            group: "Turns",
            tip: "The duration of the whole turn that plays at every open, ms. It eases out (OutQuart), so most of the turn is spent in the first half; 950 lands it before the eye settles on the screen.",
            val: 950,
            from: 300,
            to: 2500,
            step: 10
        },
        {
            label: "nod deg",
            prop: "nodDeg",
            group: "Turns",
            tip: "How far the body nods about its horizontal axis at the middle of a turn, degrees. A turn about a perfectly vertical axis looks like a card flipping; a small nod makes it an object. 6 keeps the tipped top inside the popup.",
            val: 6,
            from: 0,
            to: 20,
            step: 0.5
        },
        {
            label: "lift px",
            prop: "liftPx",
            group: "Turns",
            tip: "How far the body comes towards the viewer at the middle of a turn, px. More is livelier and taller: past about 16 the near edge leaves the popup.",
            val: 14,
            from: 0,
            to: 60,
            step: 1
        },
        {
            label: "relight settle ms",
            prop: "relightSettleMs",
            group: "Light",
            blurb: "The light that follows the pointer.",
            tip: "How long the body stays live after the pointer last moved, ms, so the light that follows the pointer has settled before the picture is cached again.",
            val: 160,
            from: 0,
            to: 600,
            step: 10
        },
        {
            label: "look turn px",
            prop: "lookTurnPx",
            group: "Free look",
            tip: "Free look: how far the pointer goes sideways for one whole turn of the phone, px (at zoom 1). 520 is a little more than the popup's width: a relaxed sweep of the hand shows every side.",
            val: 520,
            from: 150,
            to: 1500,
            step: 10
        },
        {
            label: "look tilt px",
            prop: "lookTiltPx",
            group: "Free look",
            tip: "Free look: how far the pointer goes up or down for a quarter turn (the head's or the foot's wall facing you), px. 190 keeps the tip a little heavier than the turn, so a sideways sweep stays level.",
            val: 190,
            from: 60,
            to: 800,
            step: 10
        },
        {
            label: "look back ms",
            prop: "lookBackMs",
            group: "Free look",
            tip: "Free look: how long the phone takes back to the face it showed once the key is let go, ms (one clock for the turn, the tip and the lift, easing out). 420 reads as the phone settling; under 200 it snaps.",
            val: 420,
            from: 0,
            to: 1500,
            step: 10
        },
        {
            label: "look lift px",
            prop: "lookLiftPx",
            group: "Free look",
            tip: "Free look: how far the phone lifts off towards you while it is held, px, with a small springy settle. It is the cue that the key took. 9 is seen at once and changes the phone's size by under one percent.",
            val: 9,
            from: 0,
            to: 30,
            step: 0.5
        },
        {
            label: "look lift ms",
            prop: "lookLiftMs",
            group: "Free look",
            tip: "Free look: how long the lift's springy settle takes, ms.",
            val: 320,
            from: 0,
            to: 1000,
            step: 10
        },
        {
            label: "look glint ms",
            prop: "lookGlintMs",
            group: "Free look",
            tip: "Free look: how long the glint takes that runs out across the glass and back as the key goes down, ms.",
            val: 620,
            from: 100,
            to: 2000,
            step: 10
        },
        {
            label: "relight catch ms",
            prop: "relightCatchMs",
            group: "Light",
            tip: "How long the light takes to catch a pointer that came in far from it, ms: it sets off slowly and gathers speed all the way (an ease-in), then follows the pointer. 420 is a clear chase that is over before it is in the way; 0 jumps.",
            val: 420,
            from: 0,
            to: 1200,
            step: 10
        },
        {
            label: "relight jump",
            prop: "relightJump",
            group: "Light",
            tip: "How far from the light the pointer must appear for the light to chase it instead of following at once, as a share of the stage's half extent. 0.18 leaves ordinary motion direct and catches every re-entry from another side.",
            val: 0.18,
            from: 0.02,
            to: 1,
            step: 0.02
        },
        {
            label: "key press ms",
            prop: "pressMs",
            group: "Keys",
            blurb: "The body's keys, which act.",
            tip: "How long a press of the phone's own key sinks, ms: it goes in over 40 % of this and comes back over all of it.",
            val: 120,
            from: 40,
            to: 400,
            step: 5
        }
    ]

    readonly property var bodyParams: [
        {
            label: "key angle deg",
            prop: "keyAngleDeg",
            group: "Lamps",
            blurb: "Two lamps light the metal and the glass: a strong key and a softer fill.",
            tip: "Where the key lamp stands round the body: 0 from the right, 90 from above, degrees. 118 is above and a little to the left, so the frame's right edge and the glass's top catch it.",
            val: 118,
            from: -180,
            to: 180,
            step: 1
        },
        {
            label: "key elevation",
            prop: "keyElevation",
            group: "Lamps",
            tip: "How far the key lamp stands towards the eye, 0 (grazing) to 1 (head on). 0.55 gives the rounded edge a bright line without flattening the frame.",
            val: 0.55,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "key strength",
            prop: "keyStrength",
            group: "Lamps",
            tip: "The key lamp's strength, 0 to 2. 1 is the reference the other lights were set against.",
            val: 1.0,
            from: 0,
            to: 2,
            step: 0.01
        },
        {
            label: "fill angle deg",
            prop: "fillAngleDeg",
            group: "Lamps",
            tip: "Where the fill lamp stands round the body, degrees. -35 is low on the right, opposite the key, so the shadow side of the frame is not black.",
            val: -35,
            from: -180,
            to: 180,
            step: 1
        },
        {
            label: "fill elevation",
            prop: "fillElevation",
            group: "Lamps",
            tip: "How far the fill lamp stands towards the eye, 0 to 1.",
            val: 0.62,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "fill strength",
            prop: "fillStrength",
            group: "Lamps",
            tip: "The fill lamp's strength, 0 to 2. 0.42 lifts the shadow side without competing with the key.",
            val: 0.42,
            from: 0,
            to: 2,
            step: 0.01
        },
        {
            label: "strip angle deg",
            prop: "stripAngleDeg",
            group: "Strip light",
            blurb: "The long strip light mirrored in the glass: its place, length and edge.",
            tip: "Where the long light the glass mirrors stands round the body, degrees. It is the bright band you see slide across a phone's screen.",
            val: 100,
            from: -180,
            to: 180,
            step: 1
        },
        {
            label: "glint reach",
            prop: "glintReach",
            group: "Strip light",
            tip: "Free look's glint: how far the strip light runs across the glass at the glint's peak (the same unit as the pointer's slide). 0.55 crosses most of the back.",
            val: 0.55,
            from: 0,
            to: 1.5,
            step: 0.01
        },
        {
            label: "glint gain",
            prop: "glintGain",
            group: "Strip light",
            tip: "Free look's glint: how much brighter the strip is at the glint's peak, as a share of its own strength. 0.7 is a clear flash that does not clip.",
            val: 0.7,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "film height mm",
            prop: "filmHeightMm",
            group: "Materials",
            tip: "How far the printed film (the line art, the wordmark) stands over the lined plate, mm: the length of the shadow it casts on the plate, away from the strip light. 0.24 is a fringe under one pixel at rest that moves as the light does.",
            val: 0.24,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "film shadow",
            prop: "filmShadow",
            group: "Materials",
            tip: "How dark the printed film's shadow on the plate is, 0 to 1. 0.30 is seen beside the lines without doubling them; 0 turns the shadow (and its texture read) off.",
            val: 0.3,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "film valley gain",
            prop: "filmValleyGain",
            group: "Materials",
            tip: "How much longer the film's shadow runs in a ruled line's valley (the plate's dark lines lie lower), as a share of its length. 0.8 gives the shadow the faintly toothed edge of the real one.",
            val: 0.8,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "strip elevation",
            prop: "stripElevation",
            group: "Strip light",
            tip: "How far the strip stands towards the eye, 0 to 1. High, so its reflection lands on the glass rather than past it.",
            val: 0.8,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "strip tilt deg",
            prop: "stripTiltDeg",
            group: "Strip light",
            tip: "The strip's slant, degrees; 0 is level, 16 reads as a window frame seen from above.",
            val: 16,
            from: -90,
            to: 90,
            step: 1
        },
        {
            label: "strip half length",
            prop: "stripHalfLength",
            group: "Strip light",
            tip: "Half the strip's length, as a fraction of the room, 0 to 1.5. A longer strip spreads the reflection over more of the glass.",
            val: 0.62,
            from: 0,
            to: 1.5,
            step: 0.01
        },
        {
            label: "strip strength",
            prop: "stripStrength",
            group: "Strip light",
            tip: "How bright the strip's reflection is, 0 to 2. 0.85 keeps it visible without washing out the screen's content.",
            val: 0.85,
            from: 0,
            to: 2,
            step: 0.01
        },
        {
            label: "strip sharpness",
            prop: "stripSharpness",
            group: "Strip light",
            tip: "How sharp the reflection's edge is: the exponent of its falloff, 10 to 300. 90 is a soft but clear edge; higher is a hard line.",
            val: 90,
            from: 10,
            to: 300,
            step: 1
        },
        {
            label: "slide reach",
            prop: "lightSlideReach",
            group: "Strip light",
            tip: "How far the pointer slides the strip across the room, 0 to 1. at 0 the reflection stays where it is.",
            val: 0.32,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "room strength",
            prop: "roomStrength",
            group: "Room",
            blurb: "The room the metal and glass reflect: the popup's own colours.",
            tip: "How much of the popup's own surface and shadow the glass and frame mirror, 0 to 1.5. The room is the popup's surface above and its deep shadow below, so the phone belongs to it.",
            val: 0.92,
            from: 0,
            to: 1.5,
            step: 0.01
        },
        {
            label: "horizon softness",
            prop: "horizonSoftness",
            group: "Room",
            tip: "How soft the line between the room's sky and its ground is, 0 to 1. 0.38 blurs it enough that no hard horizon shows in the frame.",
            val: 0.38,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "shadow strength",
            prop: "shadowStrength",
            group: "Shadow",
            blurb: "The soft shadow the phone casts on the popup.",
            tip: "How dark the phone's shadow on the popup's surface is, 0 to 1. a soft shadow that sits the phone on the surface.",
            val: 0.42,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "shadow offset x px",
            prop: "shadowOffsetX",
            group: "Shadow",
            tip: "Where the shadow falls sideways, px. 0 is straight down: the light is above.",
            val: 0,
            from: -30,
            to: 30,
            step: 0.5
        },
        {
            label: "shadow offset y px",
            prop: "shadowOffsetY",
            group: "Shadow",
            tip: "Where the shadow falls downwards, px. 5 lifts the phone off the surface by a hand's thickness.",
            val: 5,
            from: -30,
            to: 30,
            step: 0.5
        },
        {
            label: "shadow softness px",
            prop: "shadowSoftness",
            group: "Shadow",
            tip: "How far the shadow's edge is blurred, px. 13 is a diffuse shadow that does not read as a second outline.",
            val: 13,
            from: 0,
            to: 40,
            step: 0.5
        },
        {
            label: "shadow height px",
            prop: "shadowHeight",
            group: "Shadow",
            tip: "How high the phone's middle stands over the surface, px: with the offset it is the light's slant. Every part's shadow falls by its own height, so an edge turned towards you throws its shadow further, and the phone lifted for a turn or a free look casts a shadow that falls away, softer and fainter. 26 keeps the back a few px clear of the surface.",
            val: 26,
            from: 4,
            to: 120,
            step: 1
        },
        {
            label: "frame roughness",
            prop: "frameRoughness",
            group: "Materials",
            blurb: "How the materials answer light.",
            tip: "How rough the aluminium frame is, 0 (a mirror) to 1 (chalk). The satin frame of this phone is about a third.",
            val: 0.36,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "frame mirror",
            prop: "frameMirror",
            group: "Materials",
            tip: "How much of the room the frame's metal mirrors, 0 to 1; the rest is its own brightness. 0.62 keeps a silver frame silver in a dark popup.",
            val: 0.62,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "glass reflectivity",
            prop: "glassReflectivity",
            group: "Materials",
            tip: "How strongly the glass mirrors the room, 0 to 2. 1 is the glass as measured on the phone.",
            val: 1.0,
            from: 0,
            to: 2,
            step: 0.01
        },
        {
            label: "display glare",
            prop: "displayGlare",
            group: "Materials",
            tip: "How much of the strip's reflection lies over the display, 0 to 1. 0.55 keeps the glass visible and the control panel readable.",
            val: 0.55,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "line contrast",
            prop: "lineContrast",
            group: "Materials",
            tip: "How far a ruled line on the lined plate and its neighbour differ in colour, 0 to 0.4. The X's stripes and rings follow at their own, stronger share (set per surface in tools/bridge/make_decor.py). 0.15 reads as lines at popup size without the plate turning stripy.",
            val: 0.15,
            from: 0,
            to: 0.4,
            step: 0.005
        },
        {
            label: "groove lean",
            prop: "grooveLean",
            group: "Materials",
            tip: "How far a groove's two flanks lean apart, 0 to 0.8: what smears a light across the brushed duct and gives the lined plate's two halves their different sheen. 0.3 is a clear sheen that still reads as one surface.",
            val: 0.30,
            from: 0,
            to: 0.8,
            step: 0.01
        }
    ]

    readonly property var screenParams: [
        {
            label: "padding px",
            prop: "padding",
            group: "Display",
            blurb: "The glass the screens are drawn on: the space round every screen and how far an asleep device dims.",
            tip: "Space between the display's edge and the content of every screen, px. The shell's popup padding is 12; the display's rounded glass takes 2 more.",
            val: 14,
            from: 0,
            to: 30,
            step: 1
        },
        {
            label: "asleep dim",
            prop: "asleepDim",
            group: "Display",
            tip: "How far an asleep device's display is dimmed: the share of the way from the display's ground to the deep shadow, 0 to 1. A third reads as switched off without going black.",
            val: 0.35,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "page top gap px",
            prop: "pageTopGap",
            group: "Display",
            tip: "From the status bar's foot to where the screens and pages begin, px.",
            val: 8,
            from: 0,
            to: 18,
            step: 1
        },
        {
            label: "status inset px",
            prop: "statusInset",
            group: "Status bar",
            blurb: "The strip along the top: where it stands and its type.",
            tip: "Space between a status bar's ends and the display's edge, px. 18 clears the corners' arcs (their radius is about 21).",
            val: 18,
            from: 0,
            to: 40,
            step: 1
        },
        {
            label: "status top px",
            prop: "statusTop",
            group: "Status bar",
            tip: "From the display's top edge to the status bar, px.",
            val: 8,
            from: 0,
            to: 18,
            step: 1
        },
        {
            label: "status height px",
            prop: "statusHeight",
            group: "Status bar",
            tip: "The status bar's height, px: a line of 11 px type with room above and below.",
            val: 22,
            from: 0,
            to: 48,
            step: 1
        },
        {
            label: "status gap px",
            prop: "statusGap",
            group: "Status bar",
            tip: "Space between the parts of the right-hand group (link, bolt, percent, battery) and between the cell bars and their type, px.",
            val: 6,
            from: 0,
            to: 14,
            step: 1
        },
        {
            label: "status size px",
            prop: "statusSize",
            group: "Status bar",
            tip: "The status bar's type, px. 11 is the shell's figure size.",
            val: 11,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "cell bars",
            prop: "cellBars",
            group: "Cell bars",
            blurb: "The cellular bars on the left of the status bar.",
            tip: "How many bars; the tool's strength (0 to 4) is spread over them. Five is a phone's usual.",
            val: 5,
            from: 2,
            to: 8,
            step: 1
        },
        {
            label: "cell bar width px",
            prop: "cellBarWidth",
            group: "Cell bars",
            tip: "One bar's width, px.",
            val: 3,
            from: 0,
            to: 10,
            step: 1
        },
        {
            label: "cell bar gap px",
            prop: "cellBarGap",
            group: "Cell bars",
            tip: "The gap between bars, px.",
            val: 2,
            from: 0,
            to: 10,
            step: 1
        },
        {
            label: "cell bar min px",
            prop: "cellBarMin",
            group: "Cell bars",
            tip: "The first (shortest) bar's height, px.",
            val: 4,
            from: 0,
            to: 10,
            step: 1
        },
        {
            label: "cell bar max px",
            prop: "cellBarMax",
            group: "Cell bars",
            tip: "The last (tallest) bar's height, px; the bars in between rise evenly.",
            val: 11,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "battery width px",
            prop: "batteryWidth",
            group: "Battery",
            blurb: "The small carved battery cell on the right of the status bar.",
            tip: "The carved cell's body width, px.",
            val: 22,
            from: 0,
            to: 48,
            step: 1
        },
        {
            label: "battery height px",
            prop: "batteryHeight",
            group: "Battery",
            tip: "The cell's height, px: 11 sits between the percent's cap height and its line.",
            val: 11,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "battery nub px",
            prop: "batteryNub",
            group: "Battery",
            tip: "How far the nub on the cell's right end reaches, px.",
            val: 3,
            from: 0,
            to: 10,
            step: 1
        },
        {
            label: "battery radius px",
            prop: "batteryRadius",
            group: "Battery",
            tip: "The body's corner radius, px.",
            val: 3,
            from: 0,
            to: 10,
            step: 1
        },
        {
            label: "battery inset px",
            prop: "batteryInset",
            group: "Battery",
            tip: "Space between the carved edge and the fill, px: the carve's shadow lives in it.",
            val: 2,
            from: 0,
            to: 10,
            step: 1
        },
        {
            label: "low percent",
            prop: "lowPercent",
            group: "Battery",
            tip: "The charge at or under which the fill turns to the low colour, percent.",
            val: 15,
            from: 0,
            to: 50,
            step: 1
        },
        {
            label: "indicator width px",
            prop: "indicatorWidth",
            group: "Home indicator",
            blurb: "The carved pill at the foot of the display.",
            tip: "The pill's width, px.",
            val: 96,
            from: 0,
            to: 212,
            step: 1
        },
        {
            label: "indicator height px",
            prop: "indicatorHeight",
            group: "Home indicator",
            tip: "The pill's height, px.",
            val: 5,
            from: 0,
            to: 12,
            step: 1
        },
        {
            label: "indicator bottom px",
            prop: "indicatorBottom",
            group: "Home indicator",
            tip: "From the display's bottom edge to the pill, px: clears the corners' arcs.",
            val: 10,
            from: 0,
            to: 22,
            step: 1
        },
        {
            label: "indicator gap px",
            prop: "indicatorGap",
            group: "Home indicator",
            tip: "From the pill up to the last thing above it, px.",
            val: 10,
            from: 0,
            to: 22,
            step: 1
        },
        {
            label: "indicator hit width px",
            prop: "indicatorHitWidth",
            group: "Home indicator",
            tip: "The width of the pill's click area, px: wider than the pill, which is too thin to hit.",
            val: 140,
            from: 0,
            to: 252,
            step: 1
        },
        {
            label: "indicator hit up px",
            prop: "indicatorHitUp",
            group: "Home indicator",
            tip: "How far the click area reaches above the pill, px.",
            val: 10,
            from: 0,
            to: 22,
            step: 1
        },
        {
            label: "home bias",
            prop: "homeBias",
            group: "Heading",
            blurb: "The device's name and its one line, and where the whole group stands on the home screen.",
            tip: "Where the group of name, line and tiles stands in the room between the status bar and the indicator: 0 at the top, 0.5 in the middle (space above equals space below), 1 at the foot.",
            val: 0.5,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "name size px",
            prop: "nameSize",
            group: "Heading",
            tip: "The device's name, px bold. 16 is the shell's title size.",
            val: 16,
            from: 0,
            to: 36,
            step: 1
        },
        {
            label: "name gap px",
            prop: "nameGap",
            group: "Heading",
            tip: "Between the name and the one line under it, px.",
            val: 4,
            from: 0,
            to: 10,
            step: 1
        },
        {
            label: "state size px",
            prop: "stateSize",
            group: "Heading",
            tip: "The one state line under the name, px. 12 is the shell's body size.",
            val: 12,
            from: 0,
            to: 26,
            step: 1
        },
        {
            label: "chevron size px",
            prop: "chevronSize",
            group: "Heading",
            tip: "The small chevron after a name and the page's back chevron, px. 12 reads at the size of the words beside it.",
            val: 12,
            from: 6,
            to: 24,
            step: 1
        },
        {
            label: "header gap px",
            prop: "headerGap",
            group: "Heading",
            tip: "Between a chevron and its words, px.",
            val: 5,
            from: 0,
            to: 12,
            step: 1
        },
        {
            label: "header hit slack px",
            prop: "headerHitSlack",
            group: "Heading",
            tip: "How far a heading's click area reaches past its words, px.",
            val: 6,
            from: 0,
            to: 14,
            step: 1
        },
        {
            label: "header to tiles px",
            prop: "headerToTiles",
            group: "Heading",
            tip: "From the state line to the first row of tiles, px.",
            val: 22,
            from: 0,
            to: 48,
            step: 1
        },
        {
            label: "tile size px",
            prop: "tileSize",
            group: "Tiles",
            blurb: "The six raised tiles of the home screen.",
            tip: "A tile's side, px. 68 puts three in the display's width with room between them.",
            val: 68,
            from: 0,
            to: 150,
            step: 1
        },
        {
            label: "tile radius px",
            prop: "tileRadius",
            group: "Tiles",
            tip: "A tile's corner radius, px. 14 is the shell's container radius.",
            val: 14,
            from: 0,
            to: 30,
            step: 1
        },
        {
            label: "tile glyph size px",
            prop: "tileGlyphSize",
            group: "Tiles",
            tip: "The glyph's size on a tile, px.",
            val: 28,
            from: 0,
            to: 62,
            step: 1
        },
        {
            label: "tile label size px",
            prop: "tileLabelSize",
            group: "Tiles",
            tip: "The word under a tile, px. 11 is the shell's figure size.",
            val: 11,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "tile label gap px",
            prop: "tileLabelGap",
            group: "Tiles",
            tip: "From a tile to its label, px.",
            val: 6,
            from: 0,
            to: 14,
            step: 1
        },
        {
            label: "tile row gap px",
            prop: "tileRowGap",
            group: "Tiles",
            tip: "Between the two rows of tiles, from one label to the next tile, px.",
            val: 16,
            from: 0,
            to: 36,
            step: 1
        },
        {
            label: "stats gap px",
            prop: "statsGap",
            group: "Send figures",
            blurb: "The line of figures under the tiles while a send runs.",
            tip: "From the tiles to the figures line, px.",
            val: 12,
            from: 0,
            to: 26,
            step: 1
        },
        {
            label: "stats height px",
            prop: "statsHeight",
            group: "Send figures",
            tip: "The line's reserved height, px: the grid never moves when a send starts.",
            val: 16,
            from: 0,
            to: 36,
            step: 1
        },
        {
            label: "stats size px",
            prop: "statsSize",
            group: "Send figures",
            tip: "The figures' type, px.",
            val: 11,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "page gap px",
            prop: "pageGap",
            group: "Page frame",
            blurb: "The spacing every page is built on.",
            tip: "Between the blocks of a page, and from a page's header to its first block, px. 12 is the shell's gap between a tab row and the first card.",
            val: 12,
            from: 0,
            to: 26,
            step: 1
        },
        {
            label: "page header height px",
            prop: "pageHeaderHeight",
            group: "Page frame",
            tip: "The back chevron and title strip's height, px.",
            val: 34,
            from: 0,
            to: 74,
            step: 1
        },
        {
            label: "page bottom pad px",
            prop: "pageBottomPad",
            group: "Page frame",
            tip: "From a page's last block to the room of the home indicator, px.",
            val: 4,
            from: 0,
            to: 10,
            step: 1
        },
        {
            label: "title size px",
            prop: "titleSize",
            group: "Page type",
            blurb: "The type sizes of the pages and screens.",
            tip: "A page's title and a screen's heading, px bold. 16 is the shell's title size.",
            val: 16,
            from: 0,
            to: 36,
            step: 1
        },
        {
            label: "body size px",
            prop: "bodySize",
            group: "Page type",
            tip: "Body text of pages, px. 12 is the shell's body size.",
            val: 12,
            from: 0,
            to: 26,
            step: 1
        },
        {
            label: "note size px",
            prop: "noteSize",
            group: "Page type",
            tip: "Notes, reasons and small figures, px. 11 is the shell's figure size.",
            val: 11,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "note lines",
            prop: "noteLines",
            group: "Page type",
            tip: "The lines a page's muted note keeps room for, so a long reason never moves what is under it.",
            val: 3,
            from: 1,
            to: 6,
            step: 1
        },
        {
            label: "box radius px",
            prop: "boxRadius",
            group: "Rows and buttons",
            blurb: "Carved rows and the raised buttons in them.",
            tip: "A carved row's corner radius, px. 10 is the shell's compact radius.",
            val: 10,
            from: 0,
            to: 22,
            step: 1
        },
        {
            label: "box padding px",
            prop: "boxPadding",
            group: "Rows and buttons",
            tip: "Inside a carved row, px: the shell's card padding is 12.",
            val: 12,
            from: 0,
            to: 26,
            step: 1
        },
        {
            label: "button height px",
            prop: "buttonHeight",
            group: "Rows and buttons",
            tip: "A page's main button height, px.",
            val: 32,
            from: 0,
            to: 70,
            step: 1
        },
        {
            label: "small button height px",
            prop: "smallButtonHeight",
            group: "Rows and buttons",
            tip: "A button inside a row, px.",
            val: 28,
            from: 0,
            to: 62,
            step: 1
        },
        {
            label: "button gap px",
            prop: "buttonGap",
            group: "Rows and buttons",
            tip: "Between buttons of one row, px.",
            val: 8,
            from: 0,
            to: 18,
            step: 1
        },
        {
            label: "row gap px",
            prop: "rowGap",
            group: "Rows and buttons",
            tip: "Between rows of a list, px.",
            val: 8,
            from: 0,
            to: 18,
            step: 1
        },
        {
            label: "mode height px",
            prop: "modeHeight",
            group: "Mirror page",
            blurb: "The Mirror page's mode selector and toggles.",
            tip: "The mode selector's height, px: four icons, each named by its tip.",
            val: 44,
            from: 0,
            to: 66,
            step: 1
        },
        {
            label: "mode icon size px",
            prop: "modeIconSize",
            group: "Mirror page",
            tip: "The mode icons' size, px: large enough to read at a glance.",
            val: 20,
            from: 0,
            to: 32,
            step: 1
        },
        {
            label: "toggle row height px",
            prop: "toggleRowHeight",
            group: "Mirror page",
            tip: "One toggle row's height, px.",
            val: 38,
            from: 0,
            to: 84,
            step: 1
        },
        {
            label: "file row height px",
            prop: "fileRowHeight",
            group: "Files page",
            blurb: "The Files page's mount rows and storage line.",
            tip: "A mount row's height, px. It never changes: the room of its action (below) is reserved.",
            val: 112,
            from: 0,
            to: 201,
            step: 1
        },
        {
            label: "file action height px",
            prop: "fileActionHeight",
            group: "Files page",
            tip: "The room a row keeps for its button, or for the tool's reason when it cannot, px: a button or three lines of reason.",
            val: 42,
            from: 0,
            to: 92,
            step: 1
        },
        {
            label: "storage height px",
            prop: "storageHeight",
            group: "Files page",
            tip: "The storage line's height, px.",
            val: 20,
            from: 0,
            to: 44,
            step: 1
        },
        {
            label: "pair row height px",
            prop: "pairRowHeight",
            group: "Pairing",
            blurb: "The rows of phones asking to be paired.",
            tip: "One phone row's height, px: a name and a key above, the buttons below.",
            val: 74,
            from: 0,
            to: 162,
            step: 1
        },
        {
            label: "pair max rows",
            prop: "pairMaxRows",
            group: "Pairing",
            tip: "How many phones are listed before \"and N more\".",
            val: 4,
            from: 1,
            to: 8,
            step: 1
        },
        {
            label: "menu width px",
            prop: "menuWidth",
            group: "Device menu",
            blurb: "The floating list of devices.",
            tip: "The floating list's width, px: a name and how the phone is linked (\"REDMAGIC 10S Pro  ·  On the cable and Wi-Fi\" is the longest line to fit).",
            val: 276,
            from: 160,
            to: 320,
            step: 2
        },
        {
            label: "sheet label size px",
            prop: "backLabelSize",
            group: "Device sheet",
            blurb: "The Details page: the device's sheet behind the device menu.",
            tip: "The small-caps labels, px.",
            val: 10,
            from: 0,
            to: 20,
            step: 1
        },
        {
            label: "sheet figure size px",
            prop: "backFigureSize",
            group: "Device sheet",
            tip: "The sheet's figures and words, px.",
            val: 12,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "sheet row gap px",
            prop: "backRowGap",
            group: "Device sheet",
            tip: "Between the sheet's rows, px.",
            val: 8,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "sheet gauge height px",
            prop: "backGaugeHeight",
            group: "Device sheet",
            tip: "The storage gauge's thickness, px.",
            val: 5,
            from: 0,
            to: 12,
            step: 1
        },
        {
            label: "sheet hint groups",
            prop: "backHintGroups",
            group: "Device sheet",
            tip: "How many reasons the tool gave are shown under the controls.",
            val: 2,
            from: 0,
            to: 4,
            step: 1
        },
        {
            label: "sheet hint lines",
            prop: "backHintLines",
            group: "Device sheet",
            tip: "How many lines each of them keeps room for.",
            val: 3,
            from: 1,
            to: 6,
            step: 1
        }
    ]

    readonly property var motionParams: [
        {
            label: "morph ms ms",
            prop: "morphMs",
            group: "Motion",
            blurb: "The durations of the screen's motions.",
            tip: "A tile growing into its page, and back, ms. 320 is the notes popup's.",
            val: 320,
            from: 0,
            to: 1200,
            step: 10
        },
        {
            label: "fade ms ms",
            prop: "fadeMs",
            group: "Motion",
            tip: "A presence fade, ms. 160 is the shell's.",
            val: 160,
            from: 0,
            to: 600,
            step: 10
        },
        {
            label: "hover ms ms",
            prop: "hoverMs",
            group: "Motion",
            tip: "A hover fade, ms. 120 is the shell's.",
            val: 120,
            from: 0,
            to: 400,
            step: 10
        }
    ]
}
