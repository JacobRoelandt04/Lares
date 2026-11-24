pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

import "modules/common/components"
import "modules/common/mockup"
import "modules/common/theme"
import "modules/aerial/data"
import "modules/aerial/popup"

// =============================================================================
// mockups/aerial.qml -- aerial's board (stage 2): the Intel AX210 in its M.2 slot on a slice of mainboard, every part of the plan's table static in both looks and both
// modes, the live label, the popup skeleton, driven by AerialMock (stream S: the contract's members, scenarios and machine knobs). The popup is the content, at its own size
// on the stage; a click on a part says its intent (`partActivated`), which THIS file answers with the mock's own intents (the owner's job in stage 4).
//
// Tabs: Run (the scenario, what the mock does, the machine knobs, the readout), Look (the family and mode, the card's tokens), Scene (the lamp), Parts (the pose of each
// moving part, held by hand).
//
// Env: SCENARIO=<home|crowd|airplane|hotspot|vpn|portal|pairing|earbuds|nowifi|errors>  FAMILY=material|blueprint (eva still reads as material)  MODE=light|dark  ZOOM=<n> (1 for a grab)
//      HELPER=failed (the network helper is dead: the label and the pill say so)   CABLE=1 (the RJ45 cable in: the plug seats, the green LED, the amber one while traffic runs)   the framework's GRAB / SHEET_GRAB / GRAB_MS take the picture
// Run it: quickshell -p mockups/aerial.qml   (a sheet of every scenario in both families and modes: tools/dev/aerial_scene_sheet.sh)
// =============================================================================
MockupWindow {
    id: win

    moduleId: "aerial"
    title: "Aerial"
    stageLabel: "The popup at its own size: the AX210 on its board"
    content: popup
    target: tun
    targets: ({
            sceneParams: popup.scene,
            cloudParams: popup.cloud,
            restParams: popup.drag,
            copperParams: popup.scene.glowLayer,
            machineParams: mock,
            motionParams: popup,
            soundParams: popup.sounds
        })
    zoom: Number(Quickshell.env("ZOOM") || 1)
    panelWidth: 460
    height: Number(Quickshell.env("WIN_H") || 960)

    lists: ({
            lookParams: win.lookParams,
            aerialColors: win.aerialColors,
            sceneParams: win.sceneParams,
            cloudParams: win.cloudParams,
            restParams: win.restParams,
            copperParams: win.copperParams,
            machineParams: win.machineParams,
            motionParams: win.motionParams,
            soundParams: win.soundParams
        })
    themedLists: ["aerialColors"]

    tabDefs: [
        {
            name: "Run",
            lists: ["machineParams"],
            page: runPage
        },
        {
            name: "Look",
            subs: [
                {
                    name: "Board",
                    lists: ["lookParams"]
                },
                {
                    name: "Card",
                    lists: ["aerialColors"],
                    groups: ["The card", "Cables"]
                }
            ]
        },
        {
            name: "Scene",
            lists: ["sceneParams"]
        },
        {
            name: "Cloud",
            lists: ["cloudParams", "restParams", "copperParams"]
        },
        {
            name: "Parts",
            page: partsPage
        },
        {
            name: "Motion",
            lists: ["motionParams"],
            page: motionPage
        },
        {
            name: "Sounds",
            lists: ["soundParams"],
            page: soundsPage
        }
    ]

    // ---- the panel's own tunables -------------------------------------------------
    QtObject {
        id: tun
        property int family: 0
        // the env's family wins over the panel's row (a render says which look it wants; the row's default would write over it)
        readonly property int familyEnv: Quickshell.env("FAMILY") === "blueprint" ? 1 : (Quickshell.env("FAMILY") === "material" || Quickshell.env("FAMILY") === "eva" ? 0 : -1)
        readonly property int familyShown: tun.familyEnv >= 0 ? tun.familyEnv : tun.family
        property real sizeScale: 1
        property bool animate: true
        property bool halted: false
        property bool open: true
        property bool entrance: true
        property string lastIntent: ""
        property string mode: Quickshell.env("MODE") || ""
    }

    AerialMock {
        id: mock
        live: true
        scenario: Quickshell.env("SCENARIO") || "home"
        popupOpen: true
    }

    AerialPopup {
        id: popup
        service: mock
        family: tun.familyShown
        sizeScale: tun.sizeScale
        animate: tun.animate
        halted: tun.halted
        open: tun.open
        entranceEnabled: tun.entrance
        onPartActivated: intent => {
            tun.lastIntent = intent;
            win.answer(intent);
        }
    }

    // the RJ45 cable: the mock has no wired scenario of its own, so this writes the wired facts as the service would (a link at 1 Gb/s) or takes them away
    property bool cableIn: false
    function cable(on: bool): void {
        win.cableIn = on;
        mock.wired = { jacks: on ? [{ iface: "enp46s0", kind: "rj45", carrier: true, speedMbps: 1000, state: "connected", connected: true, uuid: "", ip4: "192.168.1.20", prefix4: 24, gateway4: "192.168.1.1", dns: [], mac: "" }] : [] };
        mock.serial = mock.serial + 1;
    }

    // what a click does here: the mock's own intents (stage 4's owner does the real thing)
    function answer(intent: string): void {
        if (intent === "screw")
            mock.setAirplane(!mock.airplane.on);
        else if (intent === "dip.wifi")
            mock.setRadio(!mock.wifi.radioOn);
        else if (intent === "dip.bt")
            mock.setBtPowered(!mock.bt.powered);
        else if (intent === "bt.scan")
            mock.btSearch();
        else if (intent === "beacon")
            mock.btVisible();
        else if (intent.indexOf("pad.") === 0)
            mock.testPad(intent.slice(4));
    }

    Component.onCompleted: {
        if (tun.mode === "dark" || tun.mode === "light")
            Theme.setMode(tun.mode);
        if (Quickshell.env("CABLE") === "1")
            win.cable(true);
        if (Quickshell.env("HELPER") === "failed")
            mock.helper = { state: "failed", error: "the network helper exited (1)" };
    }

    // =====================================================================
    //  THE RUN PAGE
    // =====================================================================
    pages: [
        MockupPage {
            id: runPage

            TipGroup {
                title: "Scenarios"
                blurb: "The mock machine's states (AerialMockData.js): one click rebuilds the facts the board shows."
            }
            TipRow {
                tip: "The mock's scenario. home: a Wi-Fi network docked, a cable out; crowd: many networks; airplane: both radios off (the screw out, the card up); hotspot / vpn / portal: the label's third line, the pads; pairing / earbuds: Bluetooth; nowifi: no radio; errors: every error tag."
                Layout.fillWidth: true
                spacing: 6
                Flow {
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: ["home", "crowd", "airplane", "hotspot", "vpn", "portal", "pairing", "earbuds", "nowifi", "errors"]
                        delegate: Button {
                            required property string modelData
                            text: modelData
                            highlighted: mock.scenario === modelData
                            onClicked: mock.scenario = modelData
                        }
                    }
                }
            }

            TipGroup {
                title: "Look"
                blurb: "The board's family and the theme's mode."
            }
            TipRow {
                tip: "Material (the shell's own material) or Blueprint (a drafting sheet). The same switch as silicon's look.family: one setting for both boards."
                Layout.fillWidth: true
                spacing: 8
                Button { text: "Material"; highlighted: tun.familyShown === 0; onClicked: tun.family = 0 }
                Button { text: "Blueprint"; highlighted: tun.familyShown === 1; onClicked: tun.family = 1 }
                Button { text: "Light"; onClicked: Theme.setMode("light") }
                Button { text: "Dark"; onClicked: Theme.setMode("dark") }
                Item { Layout.fillWidth: true }
            }

            TipGroup {
                title: "The card"
                blurb: "What a click on a part does here (the mock's own intents)."
            }
            TipRow {
                tip: "Airplane: the screw lifts out, the card tilts up about its finger end; again seats it. The same as clicking the screw on the board."
                Layout.fillWidth: true
                spacing: 8
                Button { text: "Screw (airplane)"; onClicked: mock.setAirplane(!mock.airplane.on) }
                Button { text: "Wi-Fi DIP"; onClicked: mock.setRadio(!mock.wifi.radioOn) }
                Button { text: "BT DIP"; onClicked: mock.setBtPowered(!mock.bt.powered) }
                Item { Layout.fillWidth: true }
            }
            TipRow {
                tip: "BT SCAN: the button presses and lights while the mock searches (30 s). Beacon: the LED blinks and its ring shrinks while the adapter is visible (3 min)."
                Layout.fillWidth: true
                spacing: 8
                Button { text: "BT SCAN"; onClicked: mock.btSearch() }
                Button { text: "Beacon"; onClicked: mock.btVisible() }
                Button { text: "Test pads"; onClicked: mock.testPad("all") }
                Button { text: "Cable in / out"; onClicked: win.cable(!win.cableIn) }
                Item { Layout.fillWidth: true }
            }

            TipGroup {
                title: "Stage"
                blurb: "How the board moves."
            }
            TipRow {
                tip: "Eased poses (the card, the DIP levers, the plug) play when a fact changes; off, they snap, as a popup does at its open. Halt is the idle ladder's still: the clock stops, nothing blinks, 0 frames."
                Layout.fillWidth: true
                spacing: 8
                Switch { text: "ease poses"; checked: tun.animate; onToggled: tun.animate = checked }
                Switch { text: "halt"; checked: tun.halted; onToggled: tun.halted = checked }
                Item { Layout.fillWidth: true }
            }

            TipGroup {
                title: "State"
                blurb: "What the board believes right now."
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: "scenario " + mock.scenario + "   board " + (tun.familyShown === 1 ? "Blueprint" : "Material") + ", " + Theme.mode
                    + "\nsize " + popup.implicitWidth.toFixed(0) + " x " + popup.implicitHeight.toFixed(0) + "   hover: " + popup.hoverIntent + "   last click: " + tun.lastIntent
                    + "\nrates " + popup.state_.rates.join(",") + "   usage " + popup.state_.usage.join(",") + "   label: " + popup.state_.label.name
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
            }
        },
        MockupPage {
            id: motionPage

            TipGroup {
                title: "The power-on"
                blurb: "Every open plays it: the card's lights come up, the cloud is dealt in over the label from its inner arc out, the globe, the label is typed. One clock (`enter`)."
            }
            TipRow {
                tip: "Close and open the popup (the engine's content is built when it opens and shown parked after a close). The power-on plays again from dark. 'entrance' off: the board is simply on, as a harness has it."
                Layout.fillWidth: true
                spacing: 8
                Button { text: "Replay"; onClicked: { tun.open = false; tun.open = true; } }
                Switch { text: "entrance"; checked: tun.entrance; onToggled: tun.entrance = checked }
                Item { Layout.fillWidth: true }
            }
            TipGroup {
                title: "The idle ladder"
                blurb: "Running, or saving power (as silicon): after the time without the pointer the motion eases to rest over a second and no clock runs, 0 frames. A pointer motion, a press or a network event wakes it."
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: "ladder " + popup.ladder.level + "   enter " + popup.enter.toFixed(2) + (popup.entering ? " (playing)" : "")
                    + "\nsecondary " + (popup.secondaryOpen ? String(popup.secondaryKey) : "none") + "   keys " + popup.keyboardFocusRequest
                    + "\nspeed " + (mock.speed ? mock.speed.state : "") + (mock.speed && mock.speed.refused ? " (refused: " + mock.speed.refused + ")" : "") + "   " + popup.askText
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
            }
        },
        MockupPage {
            id: soundsPage

            TipGroup {
                title: "Audition"
                blurb: "The popup's mechanical sounds (synthesised: tools/aerial/make_sounds.py), played now at the volumes above whether or not the popup is shown. A volume of 0 plays nothing at all; the volume of the card sounds is one for both."
            }
            TipRow {
                tip: "Plays that sound at its configured volume without the debounce. The popup itself plays the screw once per turn of its lift, the card as it springs up and seats, the DIP on either way, the thunk when a hologram docks and the pop when one is pulled off."
                Layout.fillWidth: true
                GridLayout {
                    Layout.fillWidth: true
                    columns: 2
                    columnSpacing: 6
                    rowSpacing: 6
                    Repeater {
                        model: ["screw", "card_up", "card_seat", "dip", "thunk", "pop"]
                        delegate: Button {
                            id: aud
                            required property string modelData
                            Layout.fillWidth: true
                            text: aud.modelData
                            onClicked: popup.sounds.audition(aud.modelData)
                        }
                    }
                }
            }
        },
        MockupPage {
            id: partsPage

            TipGroup {
                title: "Poses"
                blurb: "The moving parts' poses are the facts' (the airplane flag, the radios, the cable); hold one by hand with the mock's own knobs on the Run tab."
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: "card tilt " + popup.scene.cardTilt.toFixed(3) + " rad   screw " + popup.scene.screwLift.toFixed(2) + " mm   plug " + popup.scene.plugPose.toFixed(2)
                    + "   dip " + popup.scene.dipWifiPose.toFixed(2) + " / " + popup.scene.dipBtPose.toFixed(2) + "   patch " + (popup.scene.anyMoving ? "live" : "off")
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
            }
        }
    ]

    // =====================================================================
    //  VALUES
    // =====================================================================
    readonly property var lookParams: [
        {
            label: "family",
            prop: "family",
            group: "Board",
            blurb: "Which look the board is drawn in.",
            tip: "0 Material (the shell's own material: a raised plateau, copper as carved grooves), 1 Blueprint (a drafting sheet in blue ink). Silicon's own setting (look.family): one switch for both boards; the default is Material, as silicon's.",
            val: 0,
            from: 0,
            to: 1,
            step: 1
        },
        {
            label: "popup scale",
            prop: "sizeScale",
            group: "Board",
            tip: "The popup's own scale on top of the shell's popup ratio (PopupStage.sizeScale): the board is a picture with no reading size, so it has a number of its own. 1 is the shell's standard.",
            val: 1,
            from: 0.6,
            to: 1.6,
            step: 0.05
        }
    ]

    readonly property var sceneParams: [
        {
            label: "light angle",
            prop: "lightAngle",
            group: "Lamp",
            blurb: "The lamp the board is lit by (Lighting.js's angle and elevation, fixed in view space).",
            tip: "Where the lamp sits round the view: 0 from the right, 90 from above. 128 is silicon's: up and to the left, so shadows fall toward the viewer's lower right.",
            val: 128,
            from: 0,
            to: 360,
            step: 1
        },
        {
            label: "light elevation",
            prop: "lightElevation",
            group: "Lamp",
            tip: "How far the lamp leans toward the eye (0 grazing, 1 from the viewer). 0.52 is silicon's.",
            val: 0.52,
            from: 0,
            to: 0.95,
            step: 0.01
        },
        {
            label: "shadow strength",
            prop: "shadowStrength",
            group: "Lamp",
            tip: "How dark a part's cast shadow is on the board (Blueprint hatches it). 0.62 is silicon's.",
            val: 0.62,
            from: 0,
            to: 1,
            step: 0.01
        }
    ]

    // The signal fan's own numbers (CloudHolo's field), the pointer's rest before a tag opens (DragController) and the copper's pulse trains (GlowLayer). The tags' float is FloatStyle's
    // (an object with no alias at the cloud's root: out of reach of a Save, tuned in the notes' / weather's mockups where the same material lives).
    readonly property var cloudParams: [
        {
            label: "guides alpha",
            prop: "guideAlpha",
            group: "The fan",
            blurb: "The standing Wi-Fi glyph's dotted arcs.",
            tip: "How strong the dotted guides of the fan's arcs (and the near field's) are drawn, in the accent's hue. One value for both modes: a tint of the accent reads on either ground. 0.24 keeps the arcs a hint behind the names.",
            val: 0.24,
            from: 0,
            to: 0.6,
            step: 0.01
        },
        {
            label: "pulse alpha",
            prop: "pulseAlpha",
            group: "The fan",
            tip: "How strong the pulse is where it leaves the label's centre and runs out through the arcs (names glint as it passes). 0.64 is clearly there without competing with the names.",
            val: 0.64,
            from: 0,
            to: 1,
            step: 0.02
        }
    ]
    readonly property var restParams: [
        {
            label: "tag rest ms",
            prop: "restMs",
            group: "The pointer",
            blurb: "When a tag of the cloud opens.",
            tip: "How long the pointer must REST on a tag before it opens into its facts: a pass over the cloud opens nothing and flickers nothing. 110 ms.",
            val: 110,
            from: 0,
            to: 600,
            step: 10
        }
    ]
    readonly property var copperParams: [
        {
            label: "pulse speed mm/s",
            prop: "pulseSpeed",
            group: "Copper pulses",
            blurb: "The dimmed pulse trains that run along the board's copper from the slot.",
            tip: "How fast a pulse runs along a trace, in board mm a second. Slow on purpose: the trains are a quiet signal that the card is alive, not an animation to watch. 6.",
            val: 6,
            from: 1,
            to: 24,
            step: 0.5
        },
        {
            label: "pulse spacing mm",
            prop: "pulseSpacing",
            group: "Copper pulses",
            tip: "The distance between two pulses of one route (mm of the route's own coordinate). 19: a couple of pulses on the longest bus, never a ladder.",
            val: 19,
            from: 8,
            to: 40,
            step: 1
        },
        {
            label: "pulse width mm",
            prop: "pulseWidth",
            group: "Copper pulses",
            tip: "How long (mm) the glow of one pulse is along the trace. 1.5.",
            val: 1.5,
            from: 0.5,
            to: 4,
            step: 0.1
        }
    ]

    readonly property var machineParams: [
        {
            label: "drift",
            prop: "drift",
            group: "Machine",
            blurb: "What the mock machine does by itself.",
            tip: "dB the networks' signals wander per scan tick (AerialMock). 0 = still, which is what a picture wants; the default.",
            val: 0,
            from: 0,
            to: 8,
            step: 0.5
        },
        {
            label: "traffic Mbit/s",
            prop: "trafficMbps",
            group: "Machine",
            tip: "The carrying link's rate: the left display (down) follows it, the jack's amber LED lights while it is over the activity threshold. 25 is a busy desk.",
            val: 25,
            from: 0,
            to: 900,
            step: 1
        },
        {
            label: "intent settle ms",
            prop: "settleMs",
            group: "Machine",
            tip: "How long a simulated intent takes (a click on the screw, a DIP lever, a pad) before the facts change. 700 ms is a real radio's order; 0 makes a click instant.",
            val: 700,
            from: 0,
            to: 3000,
            step: 50
        }
    ]

    // The card's materials: the Look tab's rows write themes/eva.json for the mode shown (read-only in a sandbox copy)
    readonly property var aerialColors: [
        {
            label: "PCB mask",
            prop: "aerialPcb",
            group: "The card",
            blurb: "The AX210's own colours: materials, the same in every theme file (the shield and the PCB do not change with the theme).",
            tip: "The solder mask of the card (measured ~RGB 63,110,74 on the product photo: a mid green, glossy). Material mixes it 88 % into the surface, Blueprint draws it as a hatch.",
            val: "#3F6E4A"
        },
        {
            label: "shield tin",
            prop: "aerialShield",
            group: "The card",
            tip: "The RF shield's lid: grey tin. The label sits on it.",
            val: "#C9CED6"
        },
        {
            label: "solder rim",
            prop: "aerialSolder",
            group: "The card",
            tip: "The copper-tan solder rim round the shield, and the mask-free band at the fingers.",
            val: "#B58F6A"
        },
        {
            label: "label paper",
            prop: "aerialPaper",
            group: "The card",
            tip: "Intel's label: white paper under black print (the live label's ground; its ink is the MAIN coax's dark).",
            val: "#F4F5F7"
        },
        {
            label: "gold",
            prop: "aerialGold",
            group: "The card",
            tip: "The 22 gold fingers, the connectors' tops, the notch's copper ring, the test pads and the jack's contacts.",
            val: "#D6A93C"
        },
        {
            label: "MAIN coax",
            prop: "aerialCoaxMain",
            group: "Cables",
            tip: "The MAIN antenna cable (the left connector, '2'): black.",
            val: "#2B2D33"
        },
        {
            label: "AUX coax",
            prop: "aerialCoaxAux",
            group: "Cables",
            tip: "The AUX antenna cable (the right connector, '1'): grey.",
            val: "#8A8F99"
        }
        ]

    readonly property var motionParams: [
        {
            label: "power-on ms",
            prop: "powerOnMs",
            group: "Power-on",
            blurb: "The entrance every open plays.",
            tip: "How long the power-on takes: the card's lights, the cloud's field, the globe and the label share this one clock. 600 ms is about one breath; shorter reads as a cut.",
            val: 600,
            from: 150,
            to: 1500,
            step: 10
        },
        {
            label: "still after ms",
            prop: "haltAfterMs",
            group: "Idle ladder",
            blurb: "Running or saving power, nothing between (silicon's time).",
            tip: "Without the pointer for this long the motion eases to rest (a second) and every clock stops: nothing draws a frame until the pointer moves or the network changes. 30 s, as silicon.",
            val: 30000,
            from: 2000,
            to: 120000,
            step: 500
        },
        {
            label: "speed test confirm ms",
            prop: "armMs",
            group: "Speed test",
            tip: "How long the rates display waits for the second click that runs the test after the first asked. 5 s: long enough to read the question, short enough that a stray click is forgotten.",
            val: 5000,
            from: 1000,
            to: 15000,
            step: 250
        }
    ]

    readonly property var soundParams: [
        {
            label: "screw volume",
            prop: "screwVolume",
            group: "Volumes",
            blurb: "0 is silent (no process at all). The shell's player (pw-play --volume), never the file's level.",
            tip: "The ratchet's tick, played once per turn of the screw's lift. A click is loud next to a notification: silicon's clicks are at 0.2.",
            val: 0.2,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "card volume",
            prop: "cardVolume",
            group: "Volumes",
            tip: "The card springing up off its slot and seating again. 0.2, as the screw.",
            val: 0.2,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "DIP volume",
            prop: "dipVolume",
            group: "Volumes",
            tip: "A DIP lever's click, either way. 0.2.",
            val: 0.2,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "thunk volume",
            prop: "thunkVolume",
            group: "Volumes",
            tip: "The soft magnetic thunk of a hologram docking. It is low and round, so a little louder than the clicks: 0.25.",
            val: 0.25,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "pop volume",
            prop: "popVolume",
            group: "Volumes",
            tip: "The pop of a hologram pulled off. 0.2.",
            val: 0.2,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "screw turn",
            prop: "screwTurn",
            group: "Ratchet",
            tip: "How far the screw's lift moves between two ticks of the ratchet (a share of its travel). 0.17 gives about six ticks a turn of the airplane switch.",
            val: 0.17,
            from: 0.05,
            to: 0.5,
            step: 0.01
        },
        {
            label: "debounce ms",
            prop: "debounceMs",
            group: "Ratchet",
            tip: "A sound repeated within this of the last one that played plays once (a lever dragged across its middle and back). The ratchet is exempt: its ticks are the point.",
            val: 80,
            from: 0,
            to: 300,
            step: 5
        }
    ]
}
