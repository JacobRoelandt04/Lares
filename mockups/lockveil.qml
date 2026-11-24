pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

import "modules/common/mockup"
import "modules/common/theme"
import "modules/lockscreen/veil"

// =============================================================================
// mockups/lockveil.qml -- the lock's veils, every one of them, on the stand-in lock screen.
//
// The stage is VeilStage: black ground, the held and blurred desktop (the user's own wallpaper with two tiled
// windows), the veil over it, and the silhouette of the bar and the lock popup on top. Boot shows the veil alone and
// opaque, as the first frame after login does. The lock picks one of the config's `veils` at random for every lock;
// here one is shown at a time:
//
//   the veil       picked on the Run tab, or by opening its tab (Relief, Gooey, Dimples, Paper, Louvres, Keycaps,
//                  Dials: every value of that veil, one sub-tab per part); VEIL=<name> at launch
//   Run            the veil, the scene (boot, popup, battery), the pulses the lock sends, the rise, rest and wake,
//                  and the profiles of the veil on show
//   Host           the clock every veil runs on (idle, fps): the stand-in's own values
//
// Each veil's values are its own lists (<veil><Part>Params), so Save writes each one into its own Veil<Name>.qml.
// The Profiles tab keeps whole sets (every veil at once) in mockup_profiles/lockveil/; the Run tab's "Profiles of
// this veil" keeps one veil's values in mockup_profiles/lockveil_<veil>/, in that veil's own list names, where a
// set made for one veil alone has always lived.
//
// Keys on the stage: any key is a keystroke pulse at the field, Enter a failed attempt; a click pulses where it
// lands; hovering wakes.
//
//   quickshell -p mockups/lockveil.qml           (zoom ~0.4: the stage is the real 2880 x 1620)
//   VEIL=dials quickshell -p mockups/lockveil.qml
// =============================================================================
MockupWindow {
    id: win

    moduleId: "lockveil"
    title: "Lock veils"
    content: veilStage
    // The stage's own values (idle, fps): the clock every veil runs on.
    target: veilStage
    targets: ({
            reliefTerrainParams: reliefVeil,
            reliefLightParams: reliefVeil,
            reliefPulseParams: reliefVeil,
            gooeyBlobParams: gooeyVeil,
            gooeyLightParams: gooeyVeil,
            gooeyGroundParams: gooeyVeil,
            gooeyPulseParams: gooeyVeil,
            gooeyColourParams: gooeyVeil,
            dimplesGridParams: dimplesVeil,
            dimplesWaveParams: dimplesVeil,
            dimplesGradeParams: dimplesVeil,
            dimplesPulseParams: dimplesVeil,
            paperSheetsParams: paperVeil,
            paperLightParams: paperVeil,
            paperPulsesParams: paperVeil,
            paperColoursParams: paperVeil,
            louvresGeomParams: louvresVeil,
            louvresWaveParams: louvresVeil,
            louvresLightParams: louvresVeil,
            louvresRiseParams: louvresVeil,
            louvresDetailParams: louvresVeil,
            louvresPulseParams: louvresVeil,
            louvresColourParams: louvresVeil,
            keycapsGeomParams: keycapsVeil,
            keycapsWaveParams: keycapsVeil,
            keycapsLightParams: keycapsVeil,
            keycapsRiseParams: keycapsVeil,
            keycapsDetailParams: keycapsVeil,
            keycapsPulseParams: keycapsVeil,
            keycapsColourParams: keycapsVeil,
            dialsRingParams: dialsVeil,
            dialsTickParams: dialsVeil,
            dialsPulseParams: dialsVeil,
            dialsColourParams: dialsVeil
        })
    zoom: 0.4
    stageLabel: "Lock screen, 2880 x 1620 (" + win.veilTitle + " over the held desktop)"
    stageColor: "black"

    lists: ({
            reliefTerrainParams: win.reliefTerrainParams,
            reliefLightParams: win.reliefLightParams,
            reliefPulseParams: win.reliefPulseParams,
            gooeyBlobParams: win.gooeyBlobParams,
            gooeyLightParams: win.gooeyLightParams,
            gooeyGroundParams: win.gooeyGroundParams,
            gooeyPulseParams: win.gooeyPulseParams,
            gooeyColourParams: win.gooeyColourParams,
            dimplesGridParams: win.dimplesGridParams,
            dimplesWaveParams: win.dimplesWaveParams,
            dimplesGradeParams: win.dimplesGradeParams,
            dimplesPulseParams: win.dimplesPulseParams,
            paperSheetsParams: win.paperSheetsParams,
            paperLightParams: win.paperLightParams,
            paperPulsesParams: win.paperPulsesParams,
            paperColoursParams: win.paperColoursParams,
            louvresGeomParams: win.louvresGeomParams,
            louvresWaveParams: win.louvresWaveParams,
            louvresLightParams: win.louvresLightParams,
            louvresRiseParams: win.louvresRiseParams,
            louvresDetailParams: win.louvresDetailParams,
            louvresPulseParams: win.louvresPulseParams,
            louvresColourParams: win.louvresColourParams,
            keycapsGeomParams: win.keycapsGeomParams,
            keycapsWaveParams: win.keycapsWaveParams,
            keycapsLightParams: win.keycapsLightParams,
            keycapsRiseParams: win.keycapsRiseParams,
            keycapsDetailParams: win.keycapsDetailParams,
            keycapsPulseParams: win.keycapsPulseParams,
            keycapsColourParams: win.keycapsColourParams,
            dialsRingParams: win.dialsRingParams,
            dialsTickParams: win.dialsTickParams,
            dialsPulseParams: win.dialsPulseParams,
            dialsColourParams: win.dialsColourParams,
            stageParams: win.stageParams
        })
    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        {
            name: "Relief",
            veil: "relief",
            subs: [
                {
                    name: "Terrain",
                    lists: ["reliefTerrainParams"]
                },
                {
                    name: "Light",
                    lists: ["reliefLightParams"]
                },
                {
                    name: "Pulses",
                    lists: ["reliefPulseParams"]
                }
            ]
        },
        {
            name: "Gooey",
            veil: "gooey",
            subs: [
                {
                    name: "Blobs",
                    lists: ["gooeyBlobParams"]
                },
                {
                    name: "Light",
                    lists: ["gooeyLightParams"]
                },
                {
                    name: "Ground",
                    lists: ["gooeyGroundParams"]
                },
                {
                    name: "Pulses",
                    lists: ["gooeyPulseParams"]
                },
                {
                    name: "Colours",
                    lists: ["gooeyColourParams"]
                }
            ]
        },
        {
            name: "Dimples",
            veil: "dimples",
            subs: [
                {
                    name: "Grid",
                    lists: ["dimplesGridParams"]
                },
                {
                    name: "Waves",
                    lists: ["dimplesWaveParams"]
                },
                {
                    name: "Grade",
                    lists: ["dimplesGradeParams"]
                },
                {
                    name: "Pulses",
                    lists: ["dimplesPulseParams"]
                }
            ]
        },
        {
            name: "Paper",
            veil: "paper",
            subs: [
                {
                    name: "Sheets",
                    lists: ["paperSheetsParams"]
                },
                {
                    name: "Light",
                    lists: ["paperLightParams"]
                },
                {
                    name: "Pulses",
                    lists: ["paperPulsesParams"]
                },
                {
                    name: "Colours",
                    lists: ["paperColoursParams"]
                }
            ]
        },
        {
            name: "Louvres",
            veil: "louvres",
            subs: [
                {
                    name: "Slats",
                    lists: ["louvresGeomParams"]
                },
                {
                    name: "Wave",
                    lists: ["louvresWaveParams"]
                },
                {
                    name: "Light",
                    lists: ["louvresLightParams"]
                },
                {
                    name: "Entrance",
                    lists: ["louvresRiseParams"]
                },
                {
                    name: "Details",
                    lists: ["louvresDetailParams"]
                },
                {
                    name: "Pulses",
                    lists: ["louvresPulseParams"]
                },
                {
                    name: "Colours",
                    lists: ["louvresColourParams"]
                }
            ]
        },
        {
            name: "Keycaps",
            veil: "keycaps",
            subs: [
                {
                    name: "Caps",
                    lists: ["keycapsGeomParams"]
                },
                {
                    name: "Wave",
                    lists: ["keycapsWaveParams"]
                },
                {
                    name: "Light",
                    lists: ["keycapsLightParams"]
                },
                {
                    name: "Entrance",
                    lists: ["keycapsRiseParams"]
                },
                {
                    name: "Details",
                    lists: ["keycapsDetailParams"]
                },
                {
                    name: "Pulses",
                    lists: ["keycapsPulseParams"]
                },
                {
                    name: "Colours",
                    lists: ["keycapsColourParams"]
                }
            ]
        },
        {
            name: "Dials",
            veil: "dials",
            subs: [
                {
                    name: "Rings",
                    lists: ["dialsRingParams"]
                },
                {
                    name: "Ticks",
                    lists: ["dialsTickParams"]
                },
                {
                    name: "Pulses",
                    lists: ["dialsPulseParams"]
                },
                {
                    name: "Colours",
                    lists: ["dialsColourParams"]
                }
            ]
        },
        {
            name: "Host",
            lists: ["stageParams"]
        }
    ]

    // ---- the veil on show ------------------------------------------------------------------------
    // LockVeil.proposals: every veil the lock can pick.
    readonly property var veilNames: ["relief", "gooey", "dimples", "paper", "louvres", "keycaps", "dials"]
    readonly property var veilTitles: ({relief: "Sunlit relief", gooey: "Gooey tide", dimples: "Dimple field", paper: "Paper layers", louvres: "Louvres", keycaps: "Keycaps", dials: "Dial rings"})
    readonly property var veilBlurbs: ({
        relief: "The surface as a low carved landscape of dune ridges, lit by the real sun (the moon at night) for the local time and place.",
        gooey: "The bar's own material wells up from the bottom edge and drifts like a slow lava lamp; the popup and the bar are part of the same union, so blobs neck out of them.",
        dimples: "A pin-screen of tiny carved wells, lit like small carved boxes, their depths following slow interference waves from three drifting sources.",
        paper: "Four sheets of the shell's material cut along the soft contours of one field, stacked on a deep bed with drop shadows between them; the lowest drifts and each sheet above rides on the one beneath, never crossing its edge.",
        louvres: "Rows of slats like a venetian blind: a slow wave turns them so the light rolls across in bands; a key sends a turning wave out of the field, a wrong password flutters them.",
        keycaps: "A field of raised keycaps in the material, softly lit: slow waves press rows of them down and let them spring back; a key presses the caps outward from the field in a ring.",
        dials: "Concentric carved rings round the popup with engraved ticks, each turning at its own slow rate; keys and attempts turn them."
    })
    // Each veil's lists under the names its own profiles use (mockup_profiles/lockveil_<veil>/): { theirs: ours }.
    readonly property var veilMaps: ({
        relief: { terrainParams: "reliefTerrainParams", lightParams: "reliefLightParams", pulseParams: "reliefPulseParams", stageParams: "stageParams" },
        gooey: { blobParams: "gooeyBlobParams", lightParams: "gooeyLightParams", groundParams: "gooeyGroundParams", pulseParams: "gooeyPulseParams", colourParams: "gooeyColourParams", stageParams: "stageParams" },
        dimples: { gridParams: "dimplesGridParams", waveParams: "dimplesWaveParams", gradeParams: "dimplesGradeParams", pulseParams: "dimplesPulseParams", stageParams: "stageParams" },
        paper: { sheetsParams: "paperSheetsParams", lightParams: "paperLightParams", pulsesParams: "paperPulsesParams", coloursParams: "paperColoursParams", stageParams: "stageParams" },
        louvres: { geomParams: "louvresGeomParams", waveParams: "louvresWaveParams", lightParams: "louvresLightParams", riseParams: "louvresRiseParams", detailParams: "louvresDetailParams", pulseParams: "louvresPulseParams", colourParams: "louvresColourParams", stageParams: "stageParams" },
        keycaps: { geomParams: "keycapsGeomParams", waveParams: "keycapsWaveParams", lightParams: "keycapsLightParams", riseParams: "keycapsRiseParams", detailParams: "keycapsDetailParams", pulseParams: "keycapsPulseParams", colourParams: "keycapsColourParams", stageParams: "stageParams" },
        dials: { ringParams: "dialsRingParams", tickParams: "dialsTickParams", pulseParams: "dialsPulseParams", colourParams: "dialsColourParams", stageParams: "stageParams" }
    })
    readonly property string _envVeil: Quickshell.env("VEIL") || ""
    property string shownVeil: win.veilNames.indexOf(win._envVeil) >= 0 ? win._envVeil : "relief"
    readonly property string veilTitle: win.veilTitles[win.shownVeil] || win.shownVeil
    // A veil comes on with no pulses of another veil's in flight.
    onShownVeilChanged: {
        veilStage.veil.clearPulses();
        veilProfiles.shown();
    }

    // Opening a veil's tab shows that veil.
    Connections {
        target: win.panel
        function onTabIndexChanged() {
            const t = win.allTabs[win.panel.tabIndex];
            if (t && t.veil)
                win.shownVeil = t.veil;
        }
    }
    Component.onCompleted: {
        const t = win.allTabs[win.envTab];
        if (win._envVeil === "" && t && t.veil && t.veil !== win.shownVeil)
            win.shownVeil = t.veil;         // its change lists the veil's profiles
        else
            veilProfiles.shown();
    }

    VeilStage {
        id: veilStage
        proposal: ""
        VeilRelief {
            id: reliefVeil
            // A veil that is not on show has no host: it draws nothing and follows no clock.
            host: win.shownVeil === "relief" ? veilStage.veil : null
            visible: win.shownVeil === "relief"
            anchors.fill: parent
        }
        VeilGooey {
            id: gooeyVeil
            // A veil that is not on show has no host: it draws nothing and follows no clock.
            host: win.shownVeil === "gooey" ? veilStage.veil : null
            visible: win.shownVeil === "gooey"
            anchors.fill: parent
        }
        VeilDimples {
            id: dimplesVeil
            // A veil that is not on show has no host: it draws nothing and follows no clock.
            host: win.shownVeil === "dimples" ? veilStage.veil : null
            visible: win.shownVeil === "dimples"
            anchors.fill: parent
        }
        VeilPaper {
            id: paperVeil
            // A veil that is not on show has no host: it draws nothing and follows no clock.
            host: win.shownVeil === "paper" ? veilStage.veil : null
            visible: win.shownVeil === "paper"
            anchors.fill: parent
        }
        VeilLouvres {
            id: louvresVeil
            // A veil that is not on show has no host: it draws nothing and follows no clock.
            host: win.shownVeil === "louvres" ? veilStage.veil : null
            visible: win.shownVeil === "louvres"
            anchors.fill: parent
        }
        VeilKeycaps {
            id: keycapsVeil
            // A veil that is not on show has no host: it draws nothing and follows no clock.
            host: win.shownVeil === "keycaps" ? veilStage.veil : null
            visible: win.shownVeil === "keycaps"
            anchors.fill: parent
        }
        VeilDials {
            id: dialsVeil
            // A veil that is not on show has no host: it draws nothing and follows no clock.
            host: win.shownVeil === "dials" ? veilStage.veil : null
            visible: win.shownVeil === "dials"
            anchors.fill: parent
        }
    }

    pages: [
        MockupPage {
            id: runPage

            TipGroup {
                title: "Veil"
                blurb: "Which veil is on the stage. The lock picks one of the config's veils at random for every lock, never the same one twice in a row."
            }
            TipRow {
                tip: "The veil on the stage; opening a veil's tab shows it too. The others are built but hidden and have no host, so they draw nothing and follow no clock. Switching clears the pulses in flight, as a new lock starts with none."
                Layout.fillWidth: true
                Label {
                    text: "veil"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                ComboBox {
                    Layout.fillWidth: true
                    model: win.veilNames
                    currentIndex: Math.max(0, win.veilNames.indexOf(win.shownVeil))
                    onActivated: win.shownVeil = currentText
                }
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: win.veilTitle + ": " + (win.veilBlurbs[win.shownVeil] || "")
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
            }

            TipGroup {
                title: "Profiles of this veil"
                blurb: "One veil's values, apart from the whole sets of the Profiles tab: mockup_profiles/lockveil_<veil>/, in the veil's own list names."
            }
            TipRow {
                tip: "The profiles of the veil on show. Load puts a profile's values on this veil's tab and the Host tab's clock; the other veils keep theirs. default is this veil's val: entries, rewritten whenever the veil is shown (never saved over or deleted). Delete asks for a second click."
                Layout.fillWidth: true
                ComboBox {
                    id: vpPick
                    Layout.fillWidth: true
                    model: veilProfiles.names
                }
                Button {
                    text: "Load"
                    enabled: vpPick.currentText !== ""
                    onClicked: veilProfiles.load(vpPick.currentText)
                }
                Button {
                    text: veilProfiles.armed !== "" && veilProfiles.armed === vpPick.currentText ? "Delete?" : "Delete"
                    enabled: vpPick.currentText !== "" && !win.store.isDefaultProfile(vpPick.currentText)
                    onClicked: veilProfiles.remove(vpPick.currentText)
                }
            }
            TipRow {
                tip: "Saves the veil on show (every list of its tab) and the Host tab's clock under this name, beside the veil's other profiles; an existing name is overwritten. Letters, digits, space, dot, dash and underscore; default is refused, it is derived."
                Layout.fillWidth: true
                TextField {
                    id: vpName
                    Layout.fillWidth: true
                    placeholderText: "profile name"
                    onAccepted: if (vpSave.enabled) vpSave.clicked()
                }
                Button {
                    id: vpSave
                    text: "Save as"
                    enabled: win.store.validProfileName(vpName.text) && !win.store.isDefaultProfile(vpName.text)
                    onClicked: veilProfiles.save(vpName.text.trim())
                }
            }
            Label {
                Layout.fillWidth: true
                visible: veilProfiles.status !== ""
                wrapMode: Text.WordWrap
                text: veilProfiles.status
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
            }

            TipGroup {
                title: "Scene"
                blurb: "What the lock puts round the veil."
            }
            TipRow {
                tip: "Boot: the veil alone and opaque, as at login (Hyprland's --locked-cmd: nothing is behind the lock yet); off, a normal lock with the veil over the held, blurred desktop. Popup: the silhouette of the bar and the lock popup the shell draws above the veil, which the veil must let stand out. Shell arrives: the popup and its bar go and come back a second later out of the bar, as a boot's shell does seconds after the veil (the gooey veil wraps nothing until then, the dials centre on the top centre and open out round the popup when it comes). On battery: the clock runs at the Host tab's battery ratio of its fps."
                Layout.fillWidth: true
                CheckBox {
                    text: "boot (nothing behind)"
                    checked: veilStage.boot
                    onToggled: veilStage.boot = checked
                }
                CheckBox {
                    text: "popup"
                    checked: veilStage.showPopup
                    onToggled: veilStage.showPopup = checked
                }
                Button {
                    text: "shell arrives"
                    // the popup and its bar go, and come back a second later out of the bar (a boot's shell starting)
                    onClicked: veilStage.arriveAt = veilStage.veil.time + 1
                }
                CheckBox {
                    text: "on battery"
                    checked: veilStage.onBattery
                    onToggled: veilStage.onBattery = checked
                }
            }

            TipGroup {
                title: "Drive"
                blurb: "Pulses as the lock sends them. Keys on the stage pulse too: any key is a keystroke and Enter a failed attempt, a click pulses where it lands, hovering wakes and moves the pointer."
            }
            TipRow {
                tip: "A key at the password field, five keys 120 ms apart (burst), a failed attempt, the accepted password (the veil's clear), rest (the clock winds down and stops) and a wake after rest."
                Layout.fillWidth: true
                Button { text: "key"; onClicked: veilStage.pulse("key", veilStage.fieldPoint.x, veilStage.fieldPoint.y) }
                Button { text: "burst"; onClicked: { win._burstLeft = 5; burst.start(); } }
                Button { text: "fail"; onClicked: veilStage.pulse("fail", veilStage.fieldPoint.x, veilStage.fieldPoint.y) }
                Button { text: "ok"; onClicked: veilStage.pulse("ok", veilStage.fieldPoint.x, veilStage.fieldPoint.y) }
                Button { text: "rest now"; onClicked: veilStage.rest() }
                Button { text: "wake"; onClicked: veilStage.wake() }
            }

            TipGroup {
                title: "Rise"
                blurb: "How far the veil has risen over the held desktop."
            }
            TipRow {
                tip: "Presence: how far the veil has risen, 0 to 1. The lock raises it once the desktop beneath has stepped down to one held frame; a veil decides how it appears."
                Layout.fillWidth: true
                Label {
                    text: "presence"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Slider {
                    Layout.fillWidth: true
                    from: 0; to: 1; stepSize: 0.01
                    value: veilStage.presence
                    onMoved: veilStage.presence = value
                }
            }
            TipRow {
                tip: "Plays the rise as the lock plays it: presence 0 to 1 through OutCubic. 1.2 s is the lock's veilRiseMs (LockConfig); 0.8 and 1.6 s show the entrance faster and slower."
                Layout.fillWidth: true
                Button { text: "rise 0.8 s"; onClicked: win.playRise(800) }
                Button { text: "rise 1.2 s"; onClicked: win.playRise(1200) }
                Button { text: "rise 1.6 s"; onClicked: win.playRise(1600) }
            }

            TipGroup {
                title: "State"
                blurb: "What the veil's clock is doing now."
            }
            Label {
                Layout.fillWidth: true
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
                text: "awake " + veilStage.awake + "   speed " + veilStage.veil.speed.toFixed(2)
                      + "   t " + veilStage.veil.time.toFixed(1) + " s   "
                      + (veilStage.veil.resting ? "RESTING (0 frames)" : "ticking at " + veilStage.veil.fps.toFixed(0) + " fps")
            }
        }
    ]

    // The rise: the host's presence is the stage's, eased here by hand (a veil never animates itself).
    NumberAnimation {
        id: rise
        target: veilStage
        property: "presence"
        from: 0
        to: 1
        duration: 1200
        easing.type: Easing.OutCubic   // the lock's rise: LockConfig.veilRiseMs, OutCubic
    }
    function playRise(ms: int): void {
        rise.stop();
        rise.duration = ms;
        veilStage.presence = 0;
        rise.start();
    }
    // Five keystrokes 120 ms apart.
    property int _burstLeft: 0
    Timer {
        id: burst
        interval: 120
        repeat: true
        onTriggered: {
            veilStage.pulse("key", veilStage.fieldPoint.x, veilStage.fieldPoint.y);
            if (--win._burstLeft <= 0)
                burst.stop();
        }
    }

    // ---- Profiles of this veil --------------------------------------------------------------------
    // mockup_profiles/lockveil_<veil>/: one veil's values in its own list names ({terrainParams: ...}), through the
    // same store as the Profiles tab (tools/dev/mockup_profiles.py), beside that tab's directory.
    Item {
        id: veilProfiles
        visible: false

        // Functions of the veil, never bindings on it: shown() runs in the change handler of `shownVeil`, before a binding
        // on it would have followed (CLAUDE.md, A CHANGE HANDLER RUNS BEFORE A BINDING).
        function mapOf(v) {
            return win.veilMaps[v] || {};
        }
        function dirOf(v) {
            return String(win.store.profileDir).replace(/\/+$/, "").replace(/\/[^\/]*$/, "") + "/lockveil_" + v;
        }
        property var names: []
        property var profiles: ({})
        property string status: ""
        property string armed: ""
        property var _queue: []
        property var _defaulted: ({})

        // { our list id: values } -> { the veil's own list id: values }, and back
        function toTheirs(v, obj) {
            const map = veilProfiles.mapOf(v);
            const out = {};
            for (const theirs in map)
                if (obj[map[theirs]])
                    out[theirs] = obj[map[theirs]];
            return out;
        }
        function toOurs(v, obj) {
            const map = veilProfiles.mapOf(v);
            const out = {};
            for (const theirs in obj)
                if (map[theirs])
                    out[map[theirs]] = obj[theirs];
            return out;
        }
        // The veil came on the stage: its derived default (once a session, where the framework writes its own), then its list.
        function shown() {
            const v = win.shownVeil;
            veilProfiles.armed = "";
            veilProfiles.names = [];
            veilProfiles.profiles = {};
            if (win.store.writeDefault && !veilProfiles._defaulted[v]) {
                veilProfiles._defaulted[v] = true;
                veilProfiles._push("default", [veilProfiles.dirOf(v), JSON.stringify(veilProfiles.toTheirs(v, win.store.defaultValues()))]);
            }
            veilProfiles._push("list", [veilProfiles.dirOf(v)]);
        }
        function load(name) {
            const p = veilProfiles.profiles[name];
            if (!p) {
                veilProfiles.status = "no profile " + name;
                return;
            }
            win.registry.applyValues(veilProfiles.toOurs(win.shownVeil, p));
            veilProfiles.status = "loaded " + name + " into " + win.veilTitle;
        }
        function save(name) {
            const v = win.shownVeil;
            const map = veilProfiles.mapOf(v);
            const ids = Object.keys(map).map(k => map[k]);
            veilProfiles._push("save", [veilProfiles.dirOf(v), name, JSON.stringify(veilProfiles.toTheirs(v, win.registry.collect(ids, false)))]);
            veilProfiles._push("list", [veilProfiles.dirOf(v)]);
        }
        function remove(name) {
            if (veilProfiles.armed !== name) {
                veilProfiles.armed = name;
                return;
            }
            veilProfiles.armed = "";
            veilProfiles._push("delete", [veilProfiles.dirOf(win.shownVeil), name]);
            veilProfiles._push("list", [veilProfiles.dirOf(win.shownVeil)]);
        }
        function _push(mode, args) {
            veilProfiles._queue = veilProfiles._queue.concat([{ mode: mode, args: args }]);
            veilProfiles._next();
        }
        function _next() {
            if (vpProc.running || veilProfiles._queue.length === 0)
                return;
            const job = veilProfiles._queue[0];
            veilProfiles._queue = veilProfiles._queue.slice(1);
            vpProc.mode = job.mode;
            vpProc.command = ["python3", win.store.scriptsDir + "/mockup_profiles.py", job.mode].concat(job.args);
            vpProc.running = true;
        }
        function _done() {
            const out = vpOut.text.trim();
            const err = vpErr.text.trim();
            if (vpProc.mode === "list") {
                try {
                    const o = JSON.parse(out);
                    veilProfiles.profiles = o.profiles || {};
                    veilProfiles.names = o.names || [];
                } catch (e) {
                    veilProfiles.status = err !== "" ? err : "profile list: " + e;
                }
            } else if (err !== "") {
                veilProfiles.status = err;
            } else if (vpProc.mode !== "default") {
                veilProfiles.status = out;
            }
            Qt.callLater(veilProfiles._next);
        }

        Process {
            id: vpProc
            property string mode: ""
            stdout: StdioCollector {
                id: vpOut
            }
            stderr: StdioCollector {
                id: vpErr
            }
        }
        Connections {
            target: vpProc
            function onExited() {
                veilProfiles._done();
            }
        }
    }

    readonly property var stageParams: [
        {
            label: "idle seconds",
            prop: "idleSeconds",
            group: "Idle",
            blurb: "When the veil rests, as the lock rests it.",
            tip: "Seconds without input before the veil eases to still and stops rendering. 30: long enough to watch, short enough that a lock left alone costs nothing.",
            val: 30,
            from: 3,
            to: 120,
            step: 1
        },
        {
            label: "auto idle",
            prop: "autoIdle",
            group: "Idle",
            tip: "On: rest after the idle seconds, wake on any hover, click or key -- the lock's behaviour. Off: the veil stays awake until 'rest now'.",
            val: true
        },
        {
            label: "fps",
            prop: "fps",
            group: "Clock",
            blurb: "The one clock every veil runs on.",
            tip: "Frames per second while awake, on AC. 60: slow motion looks the same as at the panel's 120 and costs half.",
            val: 60,
            from: 10,
            to: 120,
            step: 1
        },
        {
            label: "battery ratio",
            prop: "batteryFpsRatio",
            group: "Clock",
            tip: "The fps on battery as a fraction of the fps on AC. 0.5 = 30 fps on battery, half the cost where it counts.",
            val: 0.5,
            from: 0.1,
            to: 1,
            step: 0.05
        }
    ]

    readonly property var reliefTerrainParams: [
        {
            label: "amplitude",
            prop: "amplitude",
            group: "Dunes",
            blurb: "The heightfield: a wandering asymmetric dune wave.",
            tip: "How high the ridges stand, in px, at full presence. 90 on 720 px wavelengths is a gentle slope: enough for the light to read as terrain, low enough to stay the same material as the carved boxes.",
            val: 90.0,
            from: 10,
            to: 140,
            step: 1
        },
        {
            label: "wavelength",
            prop: "wavelength",
            group: "Dunes",
            tip: "Distance between dune crests, px. 720 gives four ridges across the 2880 px screen: broad and slow, never busy.",
            val: 720.0,
            from: 300,
            to: 1600,
            step: 10
        },
        {
            label: "wind angle",
            prop: "windAngle",
            group: "Dunes",
            tip: "Direction the crests run across and the wind blows along, radians. 0.42 (24 degrees) keeps the ridges off the screen axes so they never align with the bar or the popup.",
            val: 0.42,
            from: 0,
            to: 3.14,
            step: 0.01
        },
        {
            label: "drift",
            prop: "driftSpeed",
            group: "Dunes",
            tip: "How fast the terrain travels with the wind, px per veil second. 7 moves the shadows visibly within the 30 s the veil is awake, without ever reading as motion at a glance.",
            val: 7.0,
            from: 0,
            to: 30,
            step: 0.5
        },
        {
            label: "warp",
            prop: "warpTurns",
            group: "Dunes",
            tip: "How far the crest lines wander sideways, in wavelengths. 0.9 turns straight stripes into sinuous dunes; 0 is a corrugated roof.",
            val: 0.9,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "swelling",
            prop: "envelopeDepth",
            group: "Dunes",
            tip: "How much the ridges swell and fade along their length, 0 to 1: a dune that thins out and comes back is what stops it looking tiled. Near 1 it dissolves into a plain between swells.",
            val: 0.45,
            from: 0,
            to: 0.95,
            step: 0.05
        },
        {
            label: "crest position",
            prop: "crestPos",
            group: "Crest",
            blurb: "The dune's cross-section.",
            tip: "Where the crest sits across one wavelength, 0..1. 0.76: a long gentle windward face (76 %) meeting a short steep slip face at a crisp crest, the asymmetry that reads as sand.",
            val: 0.76,
            from: 0.55,
            to: 0.9,
            step: 0.01
        },
        {
            label: "crest rim",
            prop: "rimStrength",
            group: "Crest",
            tip: "Strength of the thin bright line along the crest, drawn in whole pixels. 0.9 catches the light on the ridge; 0 removes the line.",
            val: 0.9,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "ripple height",
            prop: "rippleAmp",
            group: "Ripples",
            blurb: "Small ripples across the wind, on the gentle faces only.",
            tip: "Height of the fine wind ripples, px. 0.25 gives a slope of about 0.1: visible at 1:1 as a grain on the windward faces, invisible from across the room's noise. Larger values turn them into stripes.",
            val: 0.25,
            from: 0,
            to: 1.5,
            step: 0.05
        },
        {
            label: "ripple wavelength",
            prop: "rippleWavelength",
            group: "Ripples",
            tip: "Distance between ripple crests, px. 16 is the size of real wind ripples scaled to this screen.",
            val: 16.0,
            from: 8,
            to: 40,
            step: 1
        },
        {
            label: "ripple fade slope",
            prop: "rippleFade",
            group: "Ripples",
            tip: "The dune slope at which ripples have faded out entirely (they start fading at half). 0.45 keeps them off the steep slip faces.",
            val: 0.45,
            from: 0.1,
            to: 1,
            step: 0.05
        }
    ]

    readonly property var reliefLightParams: [
        {
            label: "hour override",
            prop: "hour",
            group: "Sun",
            blurb: "Where the light comes from. -1 = the real sun.",
            tip: "-1 follows the real clock. 0..24 pins the time of day (the sun and moon for today at the location) to judge the light at dawn, noon, dusk and night.",
            val: -1.0,
            from: -1,
            to: 24,
            step: 0.25
        },
        {
            label: "light refresh",
            prop: "lightRefreshS",
            group: "Sun",
            tip: "Veil seconds between re-reads of the wall clock for the sun. 10 is far finer than the sun moves and costs one small JS call; it never wakes a resting veil.",
            val: 10.0,
            from: 1,
            to: 120,
            step: 1
        },
        {
            label: "contrast",
            prop: "contrast",
            group: "Shading",
            blurb: "How the light reads on the relief.",
            tip: "Gain from surface slope to shading. Higher deepens the flanks until they saturate into flat dark and light bands; lower flattens the relief toward the ground. The plateaus stay the ground colour.",
            val: 1.8,
            from: 0.5,
            to: 5,
            step: 0.1
        },
        {
            label: "dark contrast gain",
            prop: "darkLightGain",
            group: "Shading",
            tip: "Extra shading gain in dark mode (1 = same as light). The dark bevel colour is close to the surface, so the highlight is lifted toward the text colour instead; raise this only if the dark relief reads too flat.",
            val: 1.0,
            from: 1,
            to: 3,
            step: 0.05
        },
        {
            label: "dark crest lift",
            prop: "darkLift",
            group: "Shading",
            tip: "How far the highlight colour is lifted from the bevel toward the text colour in dark mode, where the dark bevel is barely lighter than the surface. 0.3 lets crests and rims read against the dark ground.",
            val: 0.3,
            from: 0,
            to: 0.8,
            step: 0.02
        },
        {
            label: "cast shadows",
            prop: "castStrength",
            group: "Shading",
            tip: "Strength of the soft cast shadows that lengthen as the sun goes down. 0 also skips their six taps.",
            val: 0.5,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "shadow alpha",
            prop: "shadowAlpha",
            group: "Shading",
            tip: "Opacity of the shadowDeep layer on the darkest flank. Higher reads deeper on the pale surface; near 1 the darkest flanks go grey.",
            val: 0.85,
            from: 0.1,
            to: 1,
            step: 0.02
        },
        {
            label: "light alpha",
            prop: "lightAlpha",
            group: "Shading",
            tip: "Opacity of the bevel-coloured highlight on the brightest flank. Lower than the shadow because light carries less on a light surface.",
            val: 0.8,
            from: 0,
            to: 1,
            step: 0.02
        },
        {
            label: "over tint",
            prop: "overTint",
            group: "Over the desktop",
            blurb: "The veil as a translucent material over the blurred desktop.",
            tip: "How opaque the surface-colour tint is over the held desktop at full presence. 0.62 lets the wallpaper's colours breathe through while the desktop clearly recedes; boot ignores it (opaque).",
            val: 0.62,
            from: 0.2,
            to: 1,
            step: 0.02
        },
        {
            label: "breath",
            prop: "breath",
            group: "Over the desktop",
            tip: "How much the tint follows the height: crests are more opaque, hollows show more desktop. 0.22 makes the wallpaper glow faintly in the valleys.",
            val: 0.22,
            from: 0,
            to: 0.6,
            step: 0.02
        },
        {
            label: "vignette",
            prop: "vignette",
            group: "Over the desktop",
            tip: "How much the edges of the screen darken toward the shadow colour. 0.35 frames the popup without a visible ring.",
            val: 0.35,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "ground depth",
            prop: "groundDepth",
            group: "Over the desktop",
            tip: "How far the ground tint sits below the surface colour, toward the border colour. 0.3 makes the veil a shade darker than the popup that hangs over it, so the popup stands out and the light has room to lift above the ground. Also the boot ground.",
            val: 0.3,
            from: 0,
            to: 0.8,
            step: 0.02
        },
        {
            label: "sun glints",
            prop: "glints",
            group: "Details",
            blurb: "Two small details, each a strength: 0 switches it off.",
            tip: "Sparse points of light that twinkle slowly on the lit faces of the dunes, like sun on sand. 0 is off; 1 is the default strength.",
            val: 1,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "sand grain",
            prop: "grain",
            group: "Details",
            
            tip: "A fine static tooth in the shading, so the sand has texture at pixel scale while the terrain drifts under it. 0 is off; 1 is the default.",
            val: 1,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "front width",
            prop: "frontWidth",
            group: "Rise",
            blurb: "The entrance: a front sweeping out from the popup.",
            tip: "How wide the front is, as a fraction of the screen diagonal: a point goes from the desktop to the finished veil while the front passes over it. Small is crisp and quick (0.07 = about 100-150 ms at the default speed); large is soft and drifts toward a faint phase, which the entrance rule forbids.",
            val: 0.07,
            from: 0.02,
            to: 0.3,
            step: 0.01
        },
        {
            label: "front reach",
            prop: "frontReach",
            group: "Rise",
            tip: "How much faster than the rise the front travels: it reaches the far corner when the rise is 1 / this of the way through, and the rest is spent finished. 1.6 sweeps the screen in 0.6 of the rise; 1 spends all of it.",
            val: 1.6,
            from: 1,
            to: 3,
            step: 0.05
        },
        {
            label: "rise origin x",
            prop: "originX",
            group: "Rise",
            tip: "Horizontal position of the rise's origin, as a fraction of the width. 0.5: the popup hangs from the middle.",
            val: 0.5,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "rise origin y",
            prop: "originY",
            group: "Rise",
            tip: "Vertical position of the rise's origin, as a fraction of the height. 0.28: about where the password field sits. Used only when the host does not know the popup's rectangle; otherwise the entrance front leaves the popup's whole edge.",
            val: 0.28,
            from: 0,
            to: 1,
            step: 0.01
        }
    ]

    readonly property var reliefPulseParams: [
        {
            label: "amplitude",
            prop: "keyAmp",
            group: "Key",
            blurb: "A keystroke: a pebble in sand, a ring travelling out from the password field.",
            tip: "Height of the pebble ring, px. 26 is a clear ripple that is still visible after it has left the popup's edge (the field sits under the popup) without disturbing the dunes.",
            val: 26.0,
            from: 2,
            to: 40,
            step: 1
        },
        {
            label: "speed",
            prop: "keySpeed",
            group: "Key",
            tip: "How fast the ring travels, px/s. 520 crosses the popup's half-width in ~0.5 s, so it is seen beyond the popup's edge.",
            val: 520.0,
            from: 150,
            to: 1200,
            step: 10
        },
        {
            label: "width",
            prop: "keySigma",
            group: "Key",
            tip: "Width of the ring's crest, px. 42 is a soft wave, not a line.",
            val: 42.0,
            from: 10,
            to: 100,
            step: 1
        },
        {
            label: "life",
            prop: "keyLife",
            group: "Key",
            tip: "Seconds for the ring to die away. 2.0 lets it cross the screen's half-width; fast typing stacks up to 12 rings without turning to noise.",
            val: 2.0,
            from: 0.4,
            to: 4,
            step: 0.1
        },
        {
            label: "amplitude",
            prop: "failAmp",
            group: "Fail",
            blurb: "A wrong password: two brisk rings, noticeable and never alarming.",
            tip: "Height of the shudder rings, px. Stronger than a key's ring, and it tints the shadows toward the error colour.",
            val: 42.0,
            from: 5,
            to: 70,
            step: 1
        },
        {
            label: "speed",
            prop: "failSpeed",
            group: "Fail",
            tip: "Ring speed, px/s. Faster than a key so it reads as a rebuff.",
            val: 900.0,
            from: 300,
            to: 2000,
            step: 10
        },
        {
            label: "width",
            prop: "failSigma",
            group: "Fail",
            tip: "Crest width, px.",
            val: 52.0,
            from: 15,
            to: 140,
            step: 1
        },
        {
            label: "life",
            prop: "failLife",
            group: "Fail",
            tip: "Seconds for it to die away. Brief: 0.5.",
            val: 0.5,
            from: 0.2,
            to: 1.5,
            step: 0.05
        },
        {
            label: "feather",
            prop: "clearFeather",
            group: "Clear",
            blurb: "Accepted: the dunes sink flat, the far edges first, the desktop coming back through the veil (the unlock plays it over about a second).",
            tip: "How soft the sinking front is, as a share of the screen's diagonal. Wide (0.5): the whole terrain is settling at once, which reads as the sun climbing; narrow: a distinct wave closing in on the popup. The entrance's own front is 0.07.",
            val: 0.5,
            from: 0.05,
            to: 1,
            step: 0.05
        },
        {
            label: "amplitude",
            prop: "wakeAmp",
            group: "Wake",
            blurb: "Input after rest: one broad slow swell.",
            tip: "Height of the swell, px.",
            val: 70.0,
            from: 5,
            to: 80,
            step: 1
        },
        {
            label: "speed",
            prop: "wakeSpeed",
            group: "Wake",
            tip: "Swell speed, px/s.",
            val: 380.0,
            from: 100,
            to: 1000,
            step: 10
        },
        {
            label: "width",
            prop: "wakeSigma",
            group: "Wake",
            tip: "Swell width, px. Broad: a breath, not a ring.",
            val: 200.0,
            from: 50,
            to: 400,
            step: 5
        },
        {
            label: "life",
            prop: "wakeLife",
            group: "Wake",
            tip: "Seconds for it to fade.",
            val: 2.2,
            from: 0.5,
            to: 6,
            step: 0.1
        }
    ]

    readonly property var gooeyBlobParams: [
        {
            label: "blob count",
            prop: "blobCount",
            group: "Blobs",
            blurb: "The material's bodies: nine paths, each a deterministic function of the veil clock.",
            tip: "How many of the nine blobs are drawn. The first two are the big low ones that make the tide along the bottom edge; the rest are the mid-screen swimmers, smallest last. Nine is the design; fewer is cheaper and emptier.",
            val: 9,
            from: 2,
            to: 9,
            step: 1
        },
        {
            label: "blob size",
            prop: "blobScale",
            group: "Blobs",
            tip: "Scales every blob's radius. 1 is the design (radii 120 to 470 px at the 1620 px panel height).",
            val: 1,
            from: 0.5,
            to: 1.6,
            step: 0.05
        },
        {
            label: "wobble",
            prop: "wobble",
            group: "Blobs",
            tip: "How alive each blob is: stretch (up to 1.3x), a slow tilt and a breath of a few percent. 0 gives perfect circles; 1 is the design.",
            val: 1,
            from: 0,
            to: 1.5,
            step: 0.05
        },
        {
            label: "drift rate",
            prop: "driftScale",
            group: "Blobs",
            tip: "Multiplies the veil clock for the blobs' paths only (the periods are 65 to 130 seconds at 1). Raise it to judge a path in less time; the design is 1, tens of seconds per swing.",
            val: 1,
            from: 0.2,
            to: 4,
            step: 0.05
        },
        {
            label: "pull to popup",
            prop: "pull",
            group: "Blobs",
            tip: "How far the blobs are drawn toward the popup's centre line, in and out slowly, so they slide beneath it. The popup is the shell's centre of gravity; 0 lets them roam the whole width.",
            val: 0.55,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "shell joins",
            prop: "attachSeconds",
            group: "Blobs",
            tip: "With no popup (a boot lock before the shell has started) the blobs keep to their own paths and there is no shell in the union. When the popup arrives the shell joins over this many seconds of veil time, OutCubic: the blobs lean in toward it, each by its own share of the pull, and the shell swells into the union so the necks reach the popup's edges. Try it with the Run tab's 'shell arrives'. 1.8 s: about four times the popup's own open, so the blobs follow the popup rather than snap to it.",
            val: 1.8,
            from: 0.2,
            to: 6,
            step: 0.1
        },
        {
            label: "pour span",
            prop: "pourSpan",
            group: "Blobs",
            tip: "How far behind the entrance front a blob finishes swelling, px at 1620 high. The front pours out of the bar and the popup; a blob swells from a point as it reaches the blob's centre. Small is a crisp bud, large a slow swell.",
            val: 160,
            from: 20,
            to: 500,
            step: 10
        },
        {
            label: "pour feather",
            prop: "pourFeather",
            group: "Blobs",
            tip: "Soft edge of the entrance front, px at 1620 high: the distance over which the desktop goes to full veil. Under 100 keeps the front a visible edge; the rise then reads as a pour, never a fade.",
            val: 70,
            from: 10,
            to: 200,
            step: 5
        },
        {
            label: "merge radius",
            prop: "smoothK",
            group: "Merging",
            blurb: "The bar's own smooth union, the same quadratic smooth-min.",
            tip: "The smooth-union radius between blobs (px at 1620 high): two surfaces join while they are closer than half of it, the neck narrows to a point and lets go. Larger is gooier and holds on longer.",
            val: 190,
            from: 40,
            to: 400,
            step: 5
        },
        {
            label: "shell merge",
            prop: "stoneBlend",
            group: "Merging",
            tip: "The merge radius between a blob and the popup or the bar, as a fraction of the blob radius above. Lower and blobs touch the shell without necking into it; 0.8 lets them reach out of it.",
            val: 0.8,
            from: 0.05,
            to: 1.5,
            step: 0.05
        },
        {
            label: "popup-bar fillet",
            prop: "joinK",
            group: "Merging",
            tip: "The smooth-union radius between the popup and the bar it hangs from (px). The real shell draws its own S-curve fillet above the veil; keep this small so the two agree.",
            val: 18,
            from: 1,
            to: 60,
            step: 1
        }
    ]

    readonly property var gooeyLightParams: [
        {
            label: "sheen",
            prop: "sheen",
            group: "Details",
            blurb: "A small extra detail: a glint that slides round the blobs' rims as the light turns slowly. Switch it off (0) to see the veil without it.",
            tip: "Strength of the glint, 0 = off. It brightens the rim where the surface faces a slowly turning light and fades a rim's width inside. 0.7 is a few levels in light mode; more reads as wet.",
            val: 0.7,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "sheen width",
            prop: "sheenWidth",
            group: "Details",
            tip: "How far inside the edge the glint reaches, px at 1620 high. Narrow is a thin rim light, wide a soft gloss.",
            val: 16,
            from: 4,
            to: 60,
            step: 1
        },
        {
            label: "sheen turn",
            prop: "sheenTurn",
            group: "Details",
            tip: "How fast the light turns, radians a second of veil time. 0.25 is a lap in 25 s: slow enough to be noticed only as a glint that drifts.",
            val: 0.25,
            from: 0,
            to: 1.5,
            step: 0.05
        },
        {
            label: "shadow spread",
            prop: "shadowSpread",
            group: "Drop shadow",
            blurb: "Raised material: a shadow outside the edge and a highlight inside it, like ShadowBox raised.",
            tip: "How far the raised material's soft shadow reaches on the ground, px. The bar's buttons use 5; a body this big needs a much wider, softer fall.",
            val: 34,
            from: 6,
            to: 90,
            step: 1
        },
        {
            label: "shadow strength",
            prop: "shadowStrength",
            group: "Drop shadow",
            tip: "Opacity of the shadow at the edge. In light mode it is the deep-shadow token over the dimmed desktop; in dark mode the same token is nearly black, so a lower value is enough.",
            val: 0.55,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "shadow drop",
            prop: "shadowDrop",
            group: "Drop shadow",
            tip: "How far the shadow is thrown downward, px: the light comes from the upper left, so the shadow is fuller below and thinner above.",
            val: 10,
            from: 0,
            to: 40,
            step: 1
        },
        {
            label: "bevel width",
            prop: "bevelWidth",
            group: "Bevel",
            blurb: "The bevel highlight riding the inside of the edge.",
            tip: "Width of the highlight inside the edge, px. ShadowBox's raised bevel is 1.5; blobs are large, so 3 reads at the panel's size.",
            val: 3,
            from: 1,
            to: 12,
            step: 0.5
        },
        {
            label: "bevel strength",
            prop: "bevelStrength",
            group: "Bevel",
            tip: "How much of the bevel token the highlight takes at the edge. In dark mode the token is only a few levels above the surface, so the highlight is a fine line either way.",
            val: 0.9,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "light bias",
            prop: "lightBias",
            group: "Bevel",
            tip: "0 lights the whole rim alike (the shell's buttons); 1 lights only the edges that face the upper left and leaves the others bare. The default 0.6 keeps it a rim but gives the material a side.",
            val: 0.6,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "pillow",
            prop: "pillow",
            group: "Bevel",
            tip: "A soft shading inside the edges that face away from the light, so a blob reads as a raised pillow. It fades out toward the popup and the bar, which are drawn flat above the veil and must meet the material in one colour.",
            val: 0.24,
            from: 0,
            to: 0.6,
            step: 0.01
        }
    ]

    readonly property var gooeyGroundParams: [
        {
            label: "ground shade",
            prop: "groundShade",
            group: "Ground",
            blurb: "What lies between the blobs: the desktop dimmed and tinted toward the material.",
            tip: "Mixes the ground between the sunk tone (0) and the border tone (1). It is what the blobs stand out from: darker makes the material lighter by contrast.",
            val: 0.5,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "desktop dim (light)",
            prop: "groundAlpha",
            group: "Ground",
            tip: "Opacity of the ground over the held desktop in light mode. 0.7 lets the desktop's colours breathe through while it recedes; boot ignores it (the ground is opaque there).",
            val: 0.7,
            from: 0.2,
            to: 1,
            step: 0.01
        },
        {
            label: "desktop dim (dark)",
            prop: "groundAlphaDark",
            group: "Ground",
            tip: "The same in dark mode. The desktop is dark already, so less is needed for it to recede.",
            val: 0.6,
            from: 0.2,
            to: 1,
            step: 0.01
        },
        {
            label: "vignette",
            prop: "vignette",
            group: "Ground",
            tip: "How much the ground darkens toward the screen's corners: the quiet frame of the boot look.",
            val: 0.5,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "halo reach",
            prop: "haloReach",
            group: "Halo",
            blurb: "A wide, faint pull of the material's colour into the ground around it.",
            tip: "How far from the material the ground is tinted toward it, px. The tint makes blobs and popup read as one substance rather than shapes laid on a picture.",
            val: 150,
            from: 20,
            to: 400,
            step: 5
        },
        {
            label: "halo strength",
            prop: "haloStrength",
            group: "Halo",
            tip: "How strongly the ground takes the material's colour right at the edge. 0 leaves the shadow alone; the default is a hint.",
            val: 0.35,
            from: 0,
            to: 1,
            step: 0.05
        }
    ]

    readonly property var gooeyPulseParams: [
        {
            label: "bud size",
            prop: "budSize",
            group: "Keys",
            blurb: "A key: a bud swells out of the popup's edge and draws back.",
            tip: "Radius of the bud a keystroke swells from the popup's edge, px at 1620 high (up to sixteen at once, each at a new place on the left, right or bottom edge). It has to clear the popup to be seen: the field is under it.",
            val: 100,
            from: 20,
            to: 200,
            step: 2
        },
        {
            label: "bud reach",
            prop: "budReach",
            group: "Keys",
            tip: "How far the bud's centre travels out of the edge at its peak, px. Larger buds hang lower; the neck is the shell merge above.",
            val: 150,
            from: 20,
            to: 300,
            step: 5
        },
        {
            label: "key swell",
            prop: "keySwell",
            group: "Keys",
            tip: "How much every blob breathes out with a keystroke, as a share of its radius (summed over the live buds, capped at one bud's worth). Typing then moves the whole field a little, not only the popup's edge.",
            val: 0.04,
            from: 0,
            to: 0.15,
            step: 0.005
        },
        {
            label: "bud life",
            prop: "budLife",
            group: "Keys",
            tip: "Seconds from the swell to being drawn back. The swell is quick and the return slow, so a run of keys is a rolling of buds, never a flash.",
            val: 2.6,
            from: 0.8,
            to: 6,
            step: 0.1
        },
        {
            label: "crowd fade",
            prop: "budFade",
            group: "Keys",
            tip: "Seconds a bud takes to shrink away once newer ones have crowded it out of the eleven drawn whole (five more slots hold the shrinking). Short is a quick retire; at 0.45 s the sixteen hold a typist up to about twelve keys a second.",
            val: 0.45,
            from: 0.1,
            to: 1.5,
            step: 0.05
        },
        {
            label: "recoil",
            prop: "recoil",
            group: "Fail",
            blurb: "A wrong password: the blobs recoil and shiver, flushed toward the error tint, then settle.",
            tip: "How far every blob is pushed away from the password field at the first instant of a failed attempt, px. It eases back within about a second.",
            val: 26,
            from: 0,
            to: 80,
            step: 1
        },
        {
            label: "shiver",
            prop: "shiver",
            group: "Fail",
            tip: "Amplitude of the sideways shiver after the recoil, px, at 5 Hz, dying with the recoil. Small on purpose: the brief says never alarming.",
            val: 9,
            from: 0,
            to: 30,
            step: 0.5
        },
        {
            label: "error tint",
            prop: "failTint",
            group: "Fail",
            tip: "How far the material and the ground flush toward the error tint while it lasts. The material near the popup is not tinted (the popup is drawn flat above), so the flush fades toward it.",
            val: 0.6,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "fail seconds",
            prop: "failLife",
            group: "Fail",
            tip: "How long a failed attempt is followed. The envelope is well spent by then; this is only the cut-off.",
            val: 1.8,
            from: 0.6,
            to: 4,
            step: 0.1
        },
        {
            label: "ok seconds",
            prop: "okSeconds",
            group: "Ok",
            blurb: "Accepted: a release. The material flows up into the bar.",
            tip: "Seconds the accepted password takes to flow the material up into the bar and drain the dimmed ground (it starts at once and eases to rest, the blobs leaving one after another). The lock holds the full veil for 0.6 s after the password, then fades over 0.4 s: 1.0 is done as the fade ends.",
            val: 1,
            from: 0.8,
            to: 8,
            step: 0.1
        },
        {
            label: "wake swell",
            prop: "wakeSwell",
            group: "Wake",
            blurb: "Input after rest: a single slow swell.",
            tip: "How much the blobs swell on a wake after rest (their radii up to 16% at 1). One slow breath.",
            val: 1,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "wake seconds",
            prop: "wakeLife",
            group: "Wake",
            tip: "Length of that breath.",
            val: 4.5,
            from: 1,
            to: 10,
            step: 0.1
        },
        {
            label: "pointer lean",
            prop: "pointerLean",
            group: "Pointer",
            blurb: "The pointer over the lock: the blobs lean toward it.",
            tip: "How far the blobs lean toward the pointer, px, largest at the reach below. Slight on purpose; 0 turns it off.",
            val: 16,
            from: 0,
            to: 60,
            step: 1
        },
        {
            label: "pointer reach",
            prop: "pointerReach",
            group: "Pointer",
            tip: "Distance from the pointer at which the lean peaks, px at 1620 high.",
            val: 420,
            from: 100,
            to: 900,
            step: 10
        }
    ]

    readonly property var gooeyColourParams: [
        {
            label: "material",
            prop: "materialColor",
            group: "Material",
            blurb: "The shell's own tokens; the veil holds no literals.",
            tip: "The blobs' colour. Theme.surface: the popup's, the bar's -- one material.",
            val: "@surface"
        },
        {
            label: "bevel",
            prop: "bevelColor",
            group: "Material",
            tip: "The highlight riding inside the edge. The raised buttons' bevel token.",
            val: "@buttonBevel"
        },
        {
            label: "shadow",
            prop: "shadowColor",
            group: "Material",
            tip: "The drop shadow and the pillow's shading. The raised buttons' shadow token.",
            val: "@buttonShadow"
        },
        {
            label: "ground",
            prop: "groundColor",
            group: "Ground",
            blurb: "The ground the blobs stand on.",
            tip: "The ground at its lightest: the sunk panel tone, the quiet colour of boot.",
            val: "@panelSunk"
        },
        {
            label: "ground edge",
            prop: "edgeColor",
            group: "Ground",
            tip: "What the ground is mixed toward by the shade and the vignette.",
            val: "@border"
        },
        {
            label: "error tint",
            prop: "errorColor",
            group: "Fail",
            blurb: "What a failed attempt tints.",
            tip: "The tint of a failed attempt. The error tint token: pink in light mode, a dusky red in dark.",
            val: "@errorTint"
        }
    ]

    readonly property var dimplesGridParams: [
        {
            label: "pitch",
            prop: "pitch",
            group: "Grid",
            blurb: "The pin-screen.",
            tip: "Distance between wells in device px (rounded to an even number so wells and cell edges sit on whole pixels). 24 gives ~120 columns on 2880 px: fine enough to read as a surface, coarse enough that each well is a carved box in miniature.",
            val: 24,
            from: 12,
            to: 48,
            step: 2
        },
        {
            label: "radius",
            prop: "radius",
            group: "Grid",
            tip: "Well diameter as a fraction of the pitch at full depth. 0.66 leaves a plateau wide enough to read as surface between wells.",
            val: 0.66,
            from: 0.3,
            to: 0.9,
            step: 0.01
        },
        {
            label: "min depth",
            prop: "minDepth",
            group: "Grid",
            tip: "Depth of the shallowest wells (0 = gone, 1 = full). 0.04 leaves barely-there dimples in the troughs: the grid is still felt, the bands are what you see.",
            val: 0.04,
            from: 0,
            to: 0.6,
            step: 0.01
        },
        {
            label: "shadow width",
            prop: "shadowWidth",
            group: "Grid",
            blurb: "Lighting: carved like a small ShadowBox.",
            tip: "Reach of the inset shadow inside a full-depth well, px: the ShadowBox shadowWidth for a miniature. 4.5 is most of the well's radius, so a deep well reads as a cup.",
            val: 4.5,
            from: 1,
            to: 9,
            step: 0.5
        },
        {
            label: "bevel width",
            prop: "bevelWidth",
            group: "Grid",
            tip: "Width of the light rim outside the lit side of a well, px. 1.5 is the shell's container bevel scaled down.",
            val: 1.5,
            from: 0.5,
            to: 4,
            step: 0.25
        },
        {
            label: "light angle",
            prop: "lightAngle",
            group: "Grid",
            tip: "Direction toward the light, radians (0 = right, -1.57 = up). -2.36 is the top left, as every carved box in the shell is lit.",
            val: -2.36,
            from: -3.14,
            to: 3.14,
            step: 0.02
        },
        {
            label: "shadow gain",
            prop: "shadowGain",
            group: "Grid",
            tip: "Strength of the inset shadow. 1 matches a ShadowBox at edge alpha 1.",
            val: 1.0,
            from: 0.3,
            to: 2,
            step: 0.05
        },
        {
            label: "bevel gain",
            prop: "bevelGain",
            group: "Grid",
            tip: "Strength of the light rim and of the lit inner wall.",
            val: 1.0,
            from: 0,
            to: 2,
            step: 0.05
        }
    ]

    readonly property var dimplesWaveParams: [
        {
            label: "wavelength",
            prop: "wavelength",
            group: "Waves",
            blurb: "Broad bands sweeping across plus two radial waves of other wavelengths (so it never visibly repeats); a narrow threshold sends the wells from barely-there troughs to full crests.",
            tip: "Distance between depth crests, px. 700 is about 29 wells: broad bands that read at a glance from across the room.",
            val: 700,
            from: 200,
            to: 1600,
            step: 10
        },
        {
            label: "wave speed",
            prop: "waveSpeed",
            group: "Waves",
            tip: "How fast crests travel, px per veil second. 32 gives a ~22 s period: calm, visible within the 30 s the veil is awake.",
            val: 32,
            from: 0,
            to: 100,
            step: 1
        },
        {
            label: "contrast",
            prop: "waveContrast",
            group: "Waves",
            tip: "How strongly the waves swing depth: higher makes wider flat troughs and wider full-depth crests. 1.5 gives clear bands with soft edges.",
            val: 1.5,
            from: 0.5,
            to: 2.5,
            step: 0.05
        }
    ]

    readonly property var dimplesGradeParams: [
        {
            label: "over tint",
            prop: "overTint",
            group: "Over the desktop",
            blurb: "The veil as a translucent material over the blurred desktop.",
            tip: "Opacity of the surface tint between wells over the held desktop. 0.78 lets the wallpaper's colours breathe through while the desktop clearly recedes; boot ignores it.",
            val: 0.78,
            from: 0.2,
            to: 1,
            step: 0.02
        },
        {
            label: "floor glow",
            prop: "floorGlow",
            group: "Over the desktop",
            tip: "How much more transparent a full-depth well floor is than the plateau: the blurred desktop glows in deep wells. 0.62.",
            val: 0.62,
            from: 0,
            to: 1,
            step: 0.02
        },
        {
            label: "ground depth",
            prop: "groundDepth",
            group: "Over the desktop",
            tip: "How far the plateau tint sits below the surface colour toward the border colour. 0.2 makes the field a shade darker than the popup, so the popup stands out. Also the boot ground.",
            val: 0.2,
            from: 0,
            to: 0.8,
            step: 0.02
        },
        {
            label: "rim glint",
            prop: "rimGlint",
            group: "Details",
            blurb: "A detail behind its own switch: 0 switches it off.",
            tip: "A point of light on the lip of each well, on the wall away from the light, where a polished dimple would catch it; deeper wells catch it harder. 0 is off; 1 is the default.",
            val: 1,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "front width",
            prop: "frontWidth",
            group: "Rise",
            blurb: "The entrance: a front sweeping out from the popup.",
            tip: "How wide the front is, as a fraction of the screen diagonal: a point goes from the desktop to the finished veil while the front passes over it. Small is crisp and quick (0.07 = about 100-150 ms at the default speed); large is soft and drifts toward a faint phase, which the entrance rule forbids.",
            val: 0.07,
            from: 0.02,
            to: 0.3,
            step: 0.01
        },
        {
            label: "front reach",
            prop: "frontReach",
            group: "Rise",
            tip: "How much faster than the rise the front travels: it reaches the far corner when the rise is 1 / this of the way through, and the rest is spent finished. 1.6 sweeps the screen in 0.6 of the rise; 1 spends all of it.",
            val: 1.6,
            from: 1,
            to: 3,
            step: 0.05
        },
        {
            label: "rise origin x",
            prop: "originX",
            group: "Rise",
            tip: "Horizontal origin of the entrance front, fraction of the width. Used only when the host does not know the popup's rectangle.",
            val: 0.5,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "rise origin y",
            prop: "originY",
            group: "Rise",
            tip: "Vertical origin of the rise, fraction of the height. 0.28: about the password field. Used only when the host does not know the popup's rectangle; otherwise the entrance front leaves the popup's whole edge.",
            val: 0.28,
            from: 0,
            to: 1,
            step: 0.01
        }
    ]

    readonly property var dimplesPulseParams: [
        {
            label: "amplitude",
            prop: "keyAmp",
            group: "Key",
            blurb: "A keystroke: a depth wave from the password field, a crest then a flat trough.",
            tip: "How far the ring's crest presses wells toward full depth (above 1 saturates, so the ring reads on deep ground too). 1.4.",
            val: 1.4,
            from: 0.2,
            to: 2,
            step: 0.05
        },
        {
            label: "speed",
            prop: "keySpeed",
            group: "Key",
            tip: "px/s. 560 clears the popup's half-width in half a second.",
            val: 560,
            from: 150,
            to: 1200,
            step: 10
        },
        {
            label: "width",
            prop: "keySigma",
            group: "Key",
            tip: "Crest width, px: about three wells.",
            val: 70,
            from: 20,
            to: 160,
            step: 1
        },
        {
            label: "life",
            prop: "keyLife",
            group: "Key",
            tip: "Seconds to die away. 3 lets the wave reach the screen's edge.",
            val: 3.0,
            from: 0.5,
            to: 6,
            step: 0.1
        },
        {
            label: "amplitude",
            prop: "failAmp",
            group: "Fail",
            blurb: "A wrong password: two brisk waves, wells tinted toward error.",
            tip: "Strength of the rejection waves, which also tint the wells toward the error colour.",
            val: 1.5,
            from: 0.2,
            to: 2,
            step: 0.05
        },
        {
            label: "speed",
            prop: "failSpeed",
            group: "Fail",
            tip: "px/s. Faster than a key so it reads as a rebuff.",
            val: 1000,
            from: 300,
            to: 2000,
            step: 10
        },
        {
            label: "width",
            prop: "failSigma",
            group: "Fail",
            tip: "Crest width, px.",
            val: 75,
            from: 20,
            to: 160,
            step: 1
        },
        {
            label: "life",
            prop: "failLife",
            group: "Fail",
            tip: "Seconds to die away. Brief.",
            val: 0.9,
            from: 0.3,
            to: 2,
            step: 0.05
        },
        {
            label: "ring width",
            prop: "clearWidth",
            group: "Clear",
            blurb: "Accepted: a ring of release runs out of the popup and the pins lie flush behind it (the unlock plays it over about a second).",
            tip: "Width of the ring, as a share of the screen's diagonal: the pins go from untouched to flush within it. Narrow: a crisp wave; wide: a soft swell. 0.1: the width the entrance's front has, so the wave is the same size going and coming.",
            val: 0.1,
            from: 0.02,
            to: 0.4,
            step: 0.01
        },
        {
            label: "amplitude",
            prop: "wakeAmp",
            group: "Wake",
            blurb: "Input after rest: one broad ripple.",
            tip: "Strength of the gentle ripple after rest.",
            val: 0.7,
            from: 0.1,
            to: 1.5,
            step: 0.05
        },
        {
            label: "speed",
            prop: "wakeSpeed",
            group: "Wake",
            tip: "px/s.",
            val: 400,
            from: 100,
            to: 1000,
            step: 10
        },
        {
            label: "width",
            prop: "wakeSigma",
            group: "Wake",
            tip: "Ripple width, px: broad.",
            val: 210,
            from: 50,
            to: 500,
            step: 5
        },
        {
            label: "life",
            prop: "wakeLife",
            group: "Wake",
            tip: "Seconds to fade.",
            val: 2.4,
            from: 0.5,
            to: 6,
            step: 0.1
        }
    ]

    readonly property var paperSheetsParams: [
        {
            label: "pattern scale",
            prop: "patternScale",
            group: "Pattern",
            blurb: "The soft contour field the sheets are cut along: every sheet is a level of the same field, so the stack never crosses itself.",
            tip: "Scales the contour pattern: the wavelengths of the field every sheet is cut from. Larger is broader, calmer forms; smaller is a busier topography.",
            val: 1.35,
            from: 0.6,
            to: 3,
            step: 0.05
        },
        {
            label: "lowest level",
            prop: "levelBase",
            group: "Pattern",
            tip: "The level of the lowest cut sheet, in units of the field's spread. Lower covers more of the bed; higher leaves it showing.",
            val: -0.95,
            from: -2,
            to: 1,
            step: 0.05
        },
        {
            label: "level step",
            prop: "levelStep",
            group: "Pattern",
            tip: "How far apart the sheets' levels are: wide steps make broad terraces and few small islands on top, narrow steps crowd the contours.",
            val: 0.62,
            from: 0.2,
            to: 1.2,
            step: 0.02
        },
        {
            label: "detail cell",
            prop: "fieldCell",
            group: "Pattern",
            tip: "One vertex of the field to this many device pixels. Finer follows the contours exactly and costs more; 16 is invisible, 24 shows scallops on the shadows.",
            val: 16,
            from: 8,
            to: 48,
            step: 1
        },
        {
            label: "sheet alpha",
            prop: "sheetAlpha",
            group: "Sheets",
            blurb: "Each sheet is the shell's surface, a little deeper toward the bed.",
            tip: "Opacity of a sheet over what lies below it, light mode. Below 1 lets the desktop breathe through the stack; boot ignores it (opaque).",
            val: 0.74,
            from: 0.2,
            to: 1,
            step: 0.01
        },
        {
            label: "sheet alpha (dark)",
            prop: "sheetAlphaDark",
            group: "Sheets",
            tip: "The same in dark mode.",
            val: 0.78,
            from: 0.2,
            to: 1,
            step: 0.01
        },
        {
            label: "bed alpha",
            prop: "bedAlpha",
            group: "Sheets",
            tip: "Opacity of the bed, the deep wash under every sheet, light mode.",
            val: 0.62,
            from: 0.2,
            to: 1,
            step: 0.01
        },
        {
            label: "bed alpha (dark)",
            prop: "bedAlphaDark",
            group: "Sheets",
            tip: "The same in dark mode.",
            val: 0.66,
            from: 0.2,
            to: 1,
            step: 0.01
        },
        {
            label: "bed tone",
            prop: "bedTone",
            group: "Sheets",
            tip: "How far the bed is tinted toward the deep tone (the border token): the deepest layer.",
            val: 0.9,
            from: 0,
            to: 1.5,
            step: 0.05
        },
        {
            label: "sheet depth",
            prop: "depthTone",
            group: "Sheets",
            tip: "How far the lowest cut sheet is tinted toward the deep tone; the ones above take two thirds, a third and none, so the top sheet is the plain surface.",
            val: 0.55,
            from: 0,
            to: 1.2,
            step: 0.05
        },
        {
            label: "drift speed",
            prop: "driftSpeed",
            group: "Drift",
            blurb: "The cascade: the lowest sheet drifts and every sheet above rides on the one beneath it, swaying against it by a little of its own, so a sheet never crosses the edge beneath it however long the lock runs.",
            tip: "How fast the lowest sheet drifts, px per second at 1620 high; every sheet above rides on it. Slow enough to feel rather than see.",
            val: 5,
            from: 0,
            to: 30,
            step: 0.5
        },
        {
            label: "drift direction",
            prop: "driftAngle",
            group: "Drift",
            tip: "The direction of the drift, radians.",
            val: 0.35,
            from: -3.14,
            to: 3.14,
            step: 0.05
        },
        {
            label: "sway",
            prop: "swayReach",
            group: "Drift",
            tip: "How far a sheet sways against the one beneath it, px at 1620 high. Held under the budget whatever is asked: the gap between two levels of the field (level step x pattern scale over the field's steepest slope, 43.6 px at the defaults) less the margin, two swell caps and the sheet rattle. 14 is under it at the defaults (15.4).",
            val: 14,
            from: 0,
            to: 40,
            step: 0.5
        },
        {
            label: "sway seconds",
            prop: "swayPeriod",
            group: "Drift",
            tip: "Seconds of one sway out and back (each sheet a little faster or slower than this, its axis slowly turning).",
            val: 70,
            from: 10,
            to: 300,
            step: 5
        },
        {
            label: "margin",
            prop: "sheetMargin",
            group: "Drift",
            tip: "The least distance between a sheet's edge and the edge of the one beneath it, px at 1620 high: two edges never touch. A larger margin leaves less sway.",
            val: 12,
            from: 0,
            to: 30,
            step: 1
        },
        {
            label: "peel stagger",
            prop: "peelStagger",
            group: "Entrance",
            blurb: "The entrance is the ok peel played backwards: the bed is laid by a front, then each sheet grows in from the lowest to the top.",
            tip: "How much of the peel each sheet is offset by from the one above it (in the peel's own time, 0 to 1). The accepted password peels the top sheet first; the entrance plays the same peel backwards, so the lowest sheet comes first and the top one last.",
            val: 0.14,
            from: 0,
            to: 0.3,
            step: 0.01
        },
        {
            label: "peel span",
            prop: "peelSpan",
            group: "Entrance",
            tip: "How much of the peel one sheet's own motion takes. 0.5 lets two or three sheets move at once.",
            val: 0.5,
            from: 0.1,
            to: 0.9,
            step: 0.02
        }
    ]

    readonly property var paperLightParams: [
        {
            label: "shadow spread",
            prop: "shadowSpread",
            group: "Shadow",
            blurb: "Raised material: a shadow outside, a bevel inside, the light above and to the left as everywhere in the shell.",
            tip: "How far a sheet's drop shadow reaches over the one below, px at 1620 high.",
            val: 38,
            from: 6,
            to: 100,
            step: 1
        },
        {
            label: "shadow strength",
            prop: "shadowStrength",
            group: "Shadow",
            tip: "Opacity of the shadow at the sheet's edge.",
            val: 0.5,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "shadow drop",
            prop: "shadowDrop",
            group: "Shadow",
            tip: "How far the shadow is thrown down and to the right, px: the light is above.",
            val: 14,
            from: 0,
            to: 50,
            step: 1
        },
        {
            label: "popup shadow",
            prop: "stoneShadow",
            group: "Shadow",
            tip: "The shadow the popup and its bar cast on the top sheet, as a share of a sheet's.",
            val: 0.7,
            from: 0,
            to: 1.5,
            step: 0.05
        },
        {
            label: "shell's shadow in",
            prop: "attachSeconds",
            group: "Shadow",
            tip: "When the shell arrives over the veil (at boot the veil is up seconds before the shell) the shadow its bar and popup cast on the top sheet comes in over this many seconds of veil time, OutCubic, instead of popping in in one frame; a shell there from the veil's first 0.3 s casts it at once. 0.6 s: done before the popup has finished opening.",
            val: 0.6,
            from: 0.1,
            to: 3,
            step: 0.1
        },
        {
            label: "lift gain",
            prop: "liftGain",
            group: "Shadow",
            tip: "How much more a sheet's shadow spreads and drops where a ripple (or a wake) lifts it.",
            val: 1.3,
            from: 0,
            to: 4,
            step: 0.05
        },
        {
            label: "bevel width",
            prop: "bevelWidth",
            group: "Bevel",
            blurb: "The lit edges of the sheets, and the shading a ripple puts on their faces.",
            tip: "Width of the highlight along a sheet's edges that face the light, px.",
            val: 3,
            from: 1,
            to: 12,
            step: 0.5
        },
        {
            label: "bevel strength",
            prop: "bevelStrength",
            group: "Bevel",
            tip: "How much of the bevel token the lit edge takes.",
            val: 0.9,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "bevel (dark)",
            prop: "darkBevel",
            group: "Bevel",
            tip: "Extra gain of the bevel in dark mode, where the bevel token is only a few levels above the surface.",
            val: 2.2,
            from: 1,
            to: 4,
            step: 0.05
        },
        {
            label: "face shading",
            prop: "faceGain",
            group: "Bevel",
            tip: "Gain of the shading a ripple puts on a sheet's face (highlight toward the light, shade away), light mode.",
            val: 2.4,
            from: 0,
            to: 8,
            step: 0.1
        },
        {
            label: "face shading (dark)",
            prop: "darkFaceGain",
            group: "Bevel",
            tip: "The same in dark mode.",
            val: 2.4,
            from: 0,
            to: 8,
            step: 0.1
        }
    ]

    readonly property var paperPulsesParams: [
        {
            label: "ripple height",
            prop: "keyHeight",
            group: "Keys",
            blurb: "A key: a ripple travels out of the password field through the stack, the top sheet first and each lower one a moment later.",
            tip: "How high a key's swell is, px: 8 is a ripple; about twice that reads as too intense. It shades the sheet faces (slope along the light) and swells the edges. Past the popup's edge it has to show.",
            val: 8,
            from: 2,
            to: 50,
            step: 1
        },
        {
            label: "ripple speed",
            prop: "keySpeed",
            group: "Keys",
            tip: "How fast the ripple travels outward, px per second at 1620 high.",
            val: 520,
            from: 100,
            to: 1200,
            step: 10
        },
        {
            label: "ripple width",
            prop: "keyWidth",
            group: "Keys",
            tip: "Width of the ripple's packet, px at 1620 high.",
            val: 70,
            from: 20,
            to: 200,
            step: 2
        },
        {
            label: "ripple cycles",
            prop: "keyCycles",
            group: "Keys",
            tip: "The phase advance across the packet's width: low is one swell, high a rippling.",
            val: 1.9,
            from: 0.5,
            to: 5,
            step: 0.1
        },
        {
            label: "ripple life",
            prop: "keyLife",
            group: "Keys",
            tip: "Seconds a ripple takes to fade out. Sixteen run at once; past twelve the oldest fades over the crowd fade instead of being cut.",
            val: 3.4,
            from: 1,
            to: 8,
            step: 0.1
        },
        {
            label: "layer delay",
            prop: "layerDelay",
            group: "Keys",
            tip: "Seconds between one sheet's swell and the next lower one's.",
            val: 0.16,
            from: 0,
            to: 0.6,
            step: 0.01
        },
        {
            label: "edge swell",
            prop: "edgeSwell",
            group: "Keys",
            tip: "How far the ripple pushes a sheet's edge out, as a multiple of its height.",
            val: 1.3,
            from: 0,
            to: 4,
            step: 0.05
        },
        {
            label: "swell cap",
            prop: "swellCap",
            group: "Keys",
            tip: "The most a ripple moves a sheet's edge, out or in, px at 1620 high: a soft clamp, so two neighbouring sheets never swell into each other's margin. Each px of cap is two px less sway.",
            val: 6,
            from: 1,
            to: 15,
            step: 0.5
        },
        {
            label: "crowd fade",
            prop: "crowdFade",
            group: "Keys",
            tip: "Seconds an older ripple takes to fade once newer ones have crowded it out of the twelve drawn whole.",
            val: 0.3,
            from: 0.1,
            to: 1.5,
            step: 0.05
        },
        {
            label: "rattle",
            prop: "rattle",
            group: "Fail",
            blurb: "A wrong password: the sheets rattle and take the error tint.",
            tip: "How far the whole stack rattles against the bed on a failed attempt, px at 1620 high.",
            val: 14,
            from: 0,
            to: 60,
            step: 1
        },
        {
            label: "sheet rattle",
            prop: "rattleLayer",
            group: "Fail",
            tip: "How far each sheet rattles against the one beneath it on top of that, px at 1620 high, alternating by sheet: the top sheet shakes most. Part of the cascade's budget.",
            val: 4,
            from: 0,
            to: 10,
            step: 0.5
        },
        {
            label: "fail seconds",
            prop: "failLife",
            group: "Fail",
            tip: "The cut-off for following a failed attempt.",
            val: 1.8,
            from: 0.8,
            to: 5,
            step: 0.1
        },
        {
            label: "fail tint",
            prop: "failTint",
            group: "Fail",
            tip: "How much of the error tint the plateaus and the shadows take.",
            val: 1,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "peel seconds",
            prop: "okSeconds",
            group: "Ok",
            blurb: "Accepted: the layers peel away.",
            tip: "Seconds the whole peel takes: the top sheet first, the lowest last, when the password is accepted. The lock holds the veil about 600 ms and then fades it over about 400, so 1.2 s reads in the hold and the lowest sheets still move through the fade.",
            val: 1.2,
            from: 0.4,
            to: 8,
            step: 0.05
        },
        {
            label: "wake seconds",
            prop: "wakeSeconds",
            group: "Wake",
            blurb: "Input after rest: the stack lifts and the edges swell once.",
            tip: "How long the stack's one slow lift lasts after rest.",
            val: 3.5,
            from: 1,
            to: 8,
            step: 0.1
        },
        {
            label: "wake lift",
            prop: "wakeLift",
            group: "Wake",
            tip: "How far the shadows spread at the top of the lift.",
            val: 0.8,
            from: 0,
            to: 3,
            step: 0.05
        },
        {
            label: "wake swell",
            prop: "wakeSwell",
            group: "Wake",
            tip: "How far the sheets' edges swell outward.",
            val: 0.22,
            from: 0,
            to: 0.6,
            step: 0.01
        }
    ]

    readonly property var paperColoursParams: [
        {
            label: "surface",
            prop: "surfaceColor",
            group: "Material",
            blurb: "The shell's own tokens; the veil holds no literals.",
            tip: "The sheets' plateau: Theme.surface, the popup's own.",
            val: "@surface"
        },
        {
            label: "deep tone",
            prop: "deepColor",
            group: "Material",
            tip: "What the lower sheets and the bed are tinted toward: the border token.",
            val: "@border"
        },
        {
            label: "highlight",
            prop: "highlightColor",
            group: "Material",
            tip: "The bevel and the lit face: the raised buttons' bevel token.",
            val: "@buttonBevel"
        },
        {
            label: "shadow",
            prop: "shadowColor",
            group: "Material",
            tip: "Every drop shadow and the shaded face: the deep shadow token.",
            val: "@shadowDeep"
        },
        {
            label: "error tint",
            prop: "errorColor",
            group: "Fail",
            blurb: "What a failed attempt tints.",
            tip: "The tint of a failed attempt.",
            val: "@errorTint"
        }
    ]

    readonly property var louvresGeomParams: [
        {
            label: "pitch",
            prop: "pitch",
            group: "Slats",
            blurb: "The slats themselves: rows of the material turned about their long axis.",
            tip: "Height of one row of slats (a slat and its gap), item px. 40 reads as a facade at the lock's size; below ~24 the slats become hairlines, above 70 they are planks.",
            val: 40,
            from: 20,
            to: 90,
            step: 2
        },
        {
            label: "slat fill",
            prop: "slatFill",
            group: "Slats",
            tip: "How much of a row a face-on slat covers; the rest is the carved gap. Turned away a slat shows only cos(angle) of it, so the gap opens as the wave turns it.",
            val: 0.9,
            from: 0.5,
            to: 1,
            step: 0.01
        },
        {
            label: "convexity",
            prop: "curve",
            group: "Slats",
            tip: "How much a slat's normal changes across its height, degrees: the slat is a little convex, so its upper part catches more light than its lower. 0 is a flat plate.",
            val: 20,
            from: 0,
            to: 60,
            step: 1
        },
        {
            label: "stagger",
            prop: "stagger",
            group: "Slats",
            tip: "Each slat's own small turn, degrees, a slow ripple from row to row on top of the wave: what makes it a kinetic facade rather than one sheet bending. 0 is perfectly in step.",
            val: 5,
            from: 0,
            to: 20,
            step: 0.5
        }
    ]

    readonly property var louvresWaveParams: [
        {
            label: "wavelength",
            prop: "wavelength",
            group: "Wave",
            blurb: "The wave that turns the slats: one plane wave (its direction slowly turning) and one radial wave from a drifting source.",
            tip: "Distance between two crests of the slow wave that turns the slats, item px. The light rolls across the screen in bands this far apart.",
            val: 900,
            from: 300,
            to: 2400,
            step: 20
        },
        {
            label: "speed",
            prop: "waveSpeed",
            group: "Wave",
            tip: "How fast the crests travel, item px per second. 40 is a band every 22 seconds: slow enough to feel rather than watch.",
            val: 40,
            from: 0,
            to: 200,
            step: 2
        },
        {
            label: "tilt",
            prop: "tilt",
            group: "Wave",
            tip: "How far the wave turns a slat at its crest, degrees from face-on. 55 opens the gap to 43 percent of a row; beyond 70 the slats nearly vanish edge-on.",
            val: 55,
            from: 0,
            to: 80,
            step: 1
        },
        {
            label: "wave angle",
            prop: "waveAngle",
            group: "Wave",
            tip: "Direction of the plane wave, degrees from the horizontal. The bands are perpendicular to it; it also drifts a few degrees back and forth over a minute.",
            val: 28,
            from: -90,
            to: 90,
            step: 1
        }
    ]

    readonly property var louvresLightParams: [
        {
            label: "light direction",
            prop: "lightAngle",
            group: "Light",
            blurb: "The shell's one light; the shadows fall away from it.",
            tip: "Direction TOWARD the light on the screen, radians (y down). -2.111 is the shell's: from above and a little to the left.",
            val: -2.111,
            from: -3.1416,
            to: 3.1416,
            step: 0.001
        },
        {
            label: "elevation",
            prop: "elevation",
            group: "Light",
            tip: "How far the light stands from the screen's normal, degrees. Small is head-on (every face-on slat the same), large is raking (the wave's turning shows as strong light and dark).",
            val: 40,
            from: 5,
            to: 75,
            step: 1
        },
        {
            label: "shadow width",
            prop: "shadowWidth",
            group: "Light",
            tip: "How far a slat's drop shadow reaches down into the gap beneath it, item px. It shrinks as the slat turns edge-on.",
            val: 11,
            from: 2,
            to: 30,
            step: 0.5
        },
        {
            label: "shadow strength",
            prop: "shadowGain",
            group: "Light",
            tip: "Opacity of that shadow at the slat's edge (the deep shadow token).",
            val: 1.0,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "bevel width",
            prop: "bevelWidth",
            group: "Light",
            tip: "Width of the raised material's inner highlight along a slat's top edge, item px.",
            val: 1.6,
            from: 0.5,
            to: 6,
            step: 0.1
        },
        {
            label: "highlight",
            prop: "bevelGain",
            group: "Light",
            tip: "Strength of the highlights: the top-edge bevel and the lit slats' brightening.",
            val: 1.0,
            from: 0,
            to: 2.5,
            step: 0.05
        },
        {
            label: "slat opacity",
            prop: "overTint",
            group: "Grade",
            blurb: "How the slats and their gaps lie over the held desktop.",
            tip: "Opacity of the slats over the held desktop; the desktop's colours breathe through the rest. Boot ignores it (opaque there).",
            val: 0.86,
            from: 0.3,
            to: 1,
            step: 0.01
        },
        {
            label: "gap opacity",
            prop: "gapTint",
            group: "Grade",
            tip: "Opacity of the carved gaps (the floor token) over the desktop. Boot ignores it.",
            val: 0.55,
            from: 0,
            to: 1,
            step: 0.01
        }
    ]

    readonly property var louvresRiseParams: [
        {
            label: "front spread",
            prop: "riseSpread",
            group: "Front",
            blurb: "The entrance: a front out of the field; slats it has not reached lie edge-on and invisible.",
            tip: "How wide the entrance's front is, in entrances: a slat goes from edge-on to turned in 1 / (1 + spread) of the entrance. 4.5 is a front crossing the screen over most of 0.8 s with each slat turning in ~150 ms; lower is a sweep, higher a slow bloom with no visible front.",
            val: 4.5,
            from: 0.5,
            to: 12,
            step: 0.1
        },
        {
            label: "overshoot",
            prop: "overshoot",
            group: "Front",
            tip: "How far a slat swings past its angle as it settles (an ease-out-back; 1.7 is 10 percent). 0 turns it dead into place.",
            val: 1.7,
            from: 0,
            to: 4,
            step: 0.05
        },
        {
            label: "origin x",
            prop: "originX",
            group: "Front",
            tip: "Where the front starts, as a share of the width, when the host does not know the popup (the lock does: it leaves the popup's outline, visible from the first frame).",
            val: 0.5,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "origin y",
            prop: "originY",
            group: "Front",
            tip: "The same, as a share of the height.",
            val: 0.5,
            from: 0,
            to: 1,
            step: 0.01
        }
    ]

    readonly property var louvresDetailParams: [
        {
            label: "edge glint",
            prop: "edgeGlint",
            group: "Edge glint",
            blurb: "A bright lip along each slat's top edge, behind its own switch.",
            tip: "A thin bright lip along each slat's top edge that catches the light as the slat tips toward it, so the turning slats flash in bands across the wave. Off leaves the edges plain.",
            val: true
        },
        {
            label: "glint gain",
            prop: "glintGain",
            group: "Edge glint",
            tip: "Opacity of the lip at its brightest (the bevel token).",
            val: 1,
            from: 0,
            to: 1,
            step: 0.02
        },
        {
            label: "gloss",
            prop: "gloss",
            group: "Gloss",
            blurb: "A glazed streak across each slat, behind its own switch.",
            tip: "A soft streak of the light's mirror image across each convex slat; as the slat turns it slides from one edge to the other, so the surface looks glazed. Off leaves the slats matte.",
            val: true
        },
        {
            label: "gloss gain",
            prop: "glossGain",
            group: "Gloss",
            tip: "Opacity of the streak at its brightest (the bevel token).",
            val: 1,
            from: 0,
            to: 1,
            step: 0.02
        }
    ]

    readonly property var louvresPulseParams: [
        {
            label: "key turn",
            prop: "keyAmp",
            group: "Keys",
            blurb: "A key: a turning wave out of the field.",
            tip: "How far a key's wave turns the slats at its crest, degrees: an S-shaped ring leaves the password field, slats tipping one way as it arrives and the other as it passes.",
            val: 60,
            from: 0,
            to: 90,
            step: 1
        },
        {
            label: "key speed",
            prop: "keySpeed",
            group: "Keys",
            tip: "How fast the ring travels, item px per second.",
            val: 520,
            from: 100,
            to: 1400,
            step: 10
        },
        {
            label: "key width",
            prop: "keySigma",
            group: "Keys",
            tip: "Width of the ring's packet, item px.",
            val: 100,
            from: 20,
            to: 300,
            step: 2
        },
        {
            label: "key decay",
            prop: "keyLife",
            group: "Keys",
            tip: "Decay time of a ring's strength, seconds; a ring is dropped when it is down to about 4 percent. Sixteen and more run at once; past 28 the oldest fades out over a quarter second instead of being cut.",
            val: 3.0,
            from: 0.5,
            to: 8,
            step: 0.1
        },
        {
            label: "flutter",
            prop: "failFlutter",
            group: "Fail",
            blurb: "A wrong password: two brisk fronts, slats fluttering and tinted with the error colour behind them.",
            tip: "Amplitude of the flutter behind a wrong password's fronts, degrees; each slat flutters on its own phase.",
            val: 30,
            from: 0,
            to: 60,
            step: 1
        },
        {
            label: "fail speed",
            prop: "failSpeed",
            group: "Fail",
            tip: "Speed of the fronts, item px per second.",
            val: 1000,
            from: 200,
            to: 2400,
            step: 20
        },
        {
            label: "fail width",
            prop: "failSigma",
            group: "Fail",
            tip: "How far ahead of the front the flutter begins, item px; behind it it fades over two and a half times this.",
            val: 130,
            from: 30,
            to: 400,
            step: 5
        },
        {
            label: "fail decay",
            prop: "failLife",
            group: "Fail",
            tip: "Decay time of the flutter, seconds.",
            val: 1.5,
            from: 0.3,
            to: 4,
            step: 0.1
        },
        {
            label: "flutter rate",
            prop: "flutterHz",
            group: "Fail",
            tip: "How fast a slat flutters, Hz.",
            val: 7,
            from: 1,
            to: 16,
            step: 0.5
        },
        {
            label: "flutter lag",
            prop: "flutterLag",
            group: "Fail",
            tip: "Phase shift per item px along a slat: the flutter runs along it like a ripple. 0 flutters a whole slat at once.",
            val: 0.02,
            from: 0,
            to: 0.08,
            step: 0.002
        },
        {
            label: "ok angle",
            prop: "okAngle",
            group: "Ok",
            blurb: "Accepted: every slat lines up.",
            tip: "The one angle every slat takes behind the accepted password's front, degrees (positive tips them toward the light).",
            val: 38,
            from: -60,
            to: 60,
            step: 1
        },
        {
            label: "ok speed",
            prop: "okSpeed",
            group: "Ok",
            tip: "Speed of that front, item px per second. 2400 crosses the screen inside the lock's 600 ms unlock hold.",
            val: 2400,
            from: 300,
            to: 3000,
            step: 20
        },
        {
            label: "wake turn",
            prop: "wakeAmp",
            group: "Wake",
            blurb: "Input after rest: one broad gentle ring.",
            tip: "How far input after rest turns the slats at the crest of its ring, degrees.",
            val: 18,
            from: 0,
            to: 60,
            step: 1
        },
        {
            label: "wake speed",
            prop: "wakeSpeed",
            group: "Wake",
            tip: "Speed of the ring, item px per second.",
            val: 400,
            from: 100,
            to: 1000,
            step: 10
        },
        {
            label: "wake width",
            prop: "wakeSigma",
            group: "Wake",
            tip: "Width of the ring, item px.",
            val: 230,
            from: 60,
            to: 600,
            step: 10
        },
        {
            label: "wake decay",
            prop: "wakeLife",
            group: "Wake",
            tip: "Decay time, seconds.",
            val: 2.4,
            from: 0.5,
            to: 6,
            step: 0.1
        }
    ]

    readonly property var louvresColourParams: [
        {
            label: "slat",
            prop: "slatColor",
            group: "Slats",
            blurb: "The shell's own tokens; the veil holds no literals.",
            tip: "The slats' face-on colour: Theme.surface, the popup's own.",
            val: "@surface"
        },
        {
            label: "mid shade",
            prop: "midColor",
            group: "Slats",
            tip: "The colour a slat sinks toward as it turns away from the light, and the gap's mid tone: the border token.",
            val: "@border"
        },
        {
            label: "highlight",
            prop: "bevelColor",
            group: "Slats",
            tip: "The lit edge and the lit slats: the raised buttons' bevel token (lifted a little in dark mode).",
            val: "@buttonBevel"
        },
        {
            label: "gap floor",
            prop: "floorColor",
            group: "Gaps",
            blurb: "The carved gaps between the slats.",
            tip: "The carved gap's fill: the sunk panel token.",
            val: "@panelSunk"
        },
        {
            label: "shadow",
            prop: "shadowColor",
            group: "Gaps",
            tip: "Cast shadows and the deepest shade: the deep shadow token.",
            val: "@shadowDeep"
        },
        {
            label: "error tint",
            prop: "errorColor",
            group: "Fail",
            blurb: "What a failed attempt tints.",
            tip: "The tint the slats take while a failed attempt flutters them.",
            val: "@errorStrong"
        }
    ]

    readonly property var keycapsGeomParams: [
        {
            label: "pitch",
            prop: "pitch",
            group: "Caps",
            blurb: "The caps: a grid of raised rounded squares with gaps.",
            tip: "Distance from one cap's centre to the next, item px. 44 is a keyboard's scale at the lock's size; smaller reads as a pin-screen (the dimples' territory), larger as tiles.",
            val: 80,
            from: 24,
            to: 90,
            step: 2
        },
        {
            label: "cap fill",
            prop: "capFill",
            group: "Caps",
            tip: "The cap's share of its cell; the rest is the carved gap its shadow falls into.",
            val: 0.84,
            from: 0.5,
            to: 0.96,
            step: 0.01
        },
        {
            label: "corner",
            prop: "corner",
            group: "Caps",
            tip: "The cap's corner radius as a share of its half size. 0 is square, 1 a disc.",
            val: 0.3,
            from: 0,
            to: 1,
            step: 0.02
        },
        {
            label: "press shrink",
            prop: "pressShrink",
            group: "Caps",
            tip: "How much smaller a fully pressed cap is: it sinks away from you.",
            val: 0.2,
            from: 0,
            to: 0.25,
            step: 0.01
        }
    ]

    readonly property var keycapsWaveParams: [
        {
            label: "wavelength",
            prop: "wavelength",
            group: "Wave",
            blurb: "Slow waves press rows of caps down and let them spring back (with a little overshoot behind the press).",
            tip: "Distance between two presses of the slow bands, item px.",
            val: 900,
            from: 200,
            to: 2000,
            step: 20
        },
        {
            label: "speed",
            prop: "waveSpeed",
            group: "Wave",
            tip: "How fast the bands travel, item px per second.",
            val: 34,
            from: 0,
            to: 200,
            step: 2
        },
        {
            label: "press depth",
            prop: "waveAmp",
            group: "Wave",
            tip: "How far the bands press a cap, 0 (not at all) to 1 (fully down). Sprung caps stand a little higher than rest.",
            val: 0.9,
            from: 0,
            to: 1,
            step: 0.02
        },
        {
            label: "wave angle",
            prop: "waveAngle",
            group: "Wave",
            tip: "Direction of the plane wave, degrees from the horizontal: near 90 it presses whole ROWS in turn (the brief), 0 presses columns.",
            val: 78,
            from: -90,
            to: 90,
            step: 1
        }
    ]

    readonly property var keycapsLightParams: [
        {
            label: "light direction",
            prop: "lightAngle",
            group: "Light",
            blurb: "The shell's one light: a raised cap has a drop shadow outside and a highlight inside its lit edges.",
            tip: "Direction TOWARD the light on the screen, radians (y down). -2.111 is the shell's: above and a little left; shadows fall the other way.",
            val: -2.111,
            from: -3.1416,
            to: 3.1416,
            step: 0.001
        },
        {
            label: "shadow drop",
            prop: "shadowDrop",
            group: "Light",
            tip: "How far a standing cap throws its shadow, item px; it shortens as the cap is pressed.",
            val: 14,
            from: 0,
            to: 24,
            step: 0.5
        },
        {
            label: "shadow width",
            prop: "shadowWidth",
            group: "Light",
            tip: "The shadow's softness, item px.",
            val: 14,
            from: 2,
            to: 24,
            step: 0.5
        },
        {
            label: "shadow strength",
            prop: "shadowGain",
            group: "Light",
            tip: "Opacity of the shadow at the cap's edge (the deep shadow token).",
            val: 0.9,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "bevel width",
            prop: "bevelWidth",
            group: "Light",
            tip: "Width of the inner highlight along a cap's lit edges, item px.",
            val: 2.4,
            from: 0.5,
            to: 6,
            step: 0.1
        },
        {
            label: "highlight",
            prop: "bevelGain",
            group: "Light",
            tip: "Strength of the highlights: the bevel and the top-left brightening.",
            val: 1.0,
            from: 0,
            to: 2.5,
            step: 0.05
        },
        {
            label: "cap opacity",
            prop: "overTint",
            group: "Grade",
            blurb: "How the caps and their gaps lie over the held desktop.",
            tip: "Opacity of the caps over the held desktop. Boot ignores it (opaque there).",
            val: 0.88,
            from: 0.3,
            to: 1,
            step: 0.01
        },
        {
            label: "gap opacity",
            prop: "gapTint",
            group: "Grade",
            tip: "Opacity of the carved gaps (the floor token) over the desktop. Boot ignores it.",
            val: 0.6,
            from: 0,
            to: 1,
            step: 0.01
        }
    ]

    readonly property var keycapsRiseParams: [
        {
            label: "front spread",
            prop: "riseSpread",
            group: "Front",
            blurb: "The entrance: a front out of the field; caps rise out of the surface behind it.",
            tip: "How wide the entrance's front is, in entrances: a cap goes from nothing to risen in 1 / (1 + spread) of the entrance. 4.5 is a front crossing the screen over most of 0.8 s, each cap rising in ~150 ms. The front is squarish, like a keyboard's rectangle of presses.",
            val: 4.5,
            from: 0.5,
            to: 12,
            step: 0.1
        },
        {
            label: "overshoot",
            prop: "overshoot",
            group: "Front",
            tip: "How far a cap springs past its size as it settles (an ease-out-back; 1.9 is 12 percent). 0 is dead into place.",
            val: 1.9,
            from: 0,
            to: 4,
            step: 0.05
        },
        {
            label: "origin x",
            prop: "originX",
            group: "Front",
            tip: "Where the front starts, as a share of the width, when the host does not know the popup (the lock does: it leaves the popup's outline, visible from the first frame).",
            val: 0.5,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "origin y",
            prop: "originY",
            group: "Front",
            tip: "The same, as a share of the height.",
            val: 0.5,
            from: 0,
            to: 1,
            step: 0.01
        }
    ]

    readonly property var keycapsDetailParams: [
        {
            label: "dish",
            prop: "dish",
            group: "Dish",
            blurb: "The cap tops, concave like a real keycap's, behind their own switch.",
            tip: "Each cap top is slightly concave like a real keycap: its inner edge on the light's side lies in shadow, the far side catches the light. Off leaves the tops flat.",
            val: true
        },
        {
            label: "dish depth",
            prop: "dishDepth",
            group: "Dish",
            tip: "How strong the concavity reads (1 = default).",
            val: 1.0,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "legends",
            prop: "legends",
            group: "Legends",
            blurb: "Small marks engraved on one cap in five, behind their own switch.",
            tip: "One cap in five carries a small engraved mark (a dot, a dash, a plus or a ring): shaded on the light's side, a lit lip on the other. Off leaves every cap blank.",
            val: true
        },
        {
            label: "legend gain",
            prop: "legendGain",
            group: "Legends",
            tip: "How strongly the marks are engraved.",
            val: 1.0,
            from: 0,
            to: 2,
            step: 0.05
        }
    ]

    readonly property var keycapsPulseParams: [
        {
            label: "key press",
            prop: "keyAmp",
            group: "Keys",
            blurb: "A key: a ring of presses out of the password field, like a ripple on a keyboard.",
            tip: "How far a key's ring presses a cap at its crest (0 to 1; more than 1 holds it down longer). A softer ring springs the caps behind it back up past rest.",
            val: 1.6,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "key speed",
            prop: "keySpeed",
            group: "Keys",
            tip: "How fast the ring travels, item px per second.",
            val: 520,
            from: 100,
            to: 1400,
            step: 10
        },
        {
            label: "key width",
            prop: "keySigma",
            group: "Keys",
            tip: "Width of the ring, item px.",
            val: 120,
            from: 20,
            to: 250,
            step: 2
        },
        {
            label: "key decay",
            prop: "keyLife",
            group: "Keys",
            tip: "Decay time of a ring's strength, seconds; a ring is dropped at about 4 percent. Sixteen and more run at once; past 28 the oldest fades out over a quarter second instead of being cut.",
            val: 3.0,
            from: 0.5,
            to: 8,
            step: 0.1
        },
        {
            label: "fail press",
            prop: "failAmp",
            group: "Fail",
            blurb: "A wrong password: two brisk rings, the caps tinted with the error colour.",
            tip: "How hard a wrong password's two brisk rings press the caps; they take the error colour.",
            val: 1.1,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "fail speed",
            prop: "failSpeed",
            group: "Fail",
            tip: "Speed of the rings, item px per second.",
            val: 1000,
            from: 200,
            to: 2400,
            step: 20
        },
        {
            label: "fail width",
            prop: "failSigma",
            group: "Fail",
            tip: "Width of the rings, item px.",
            val: 80,
            from: 20,
            to: 250,
            step: 2
        },
        {
            label: "fail decay",
            prop: "failLife",
            group: "Fail",
            tip: "Decay time, seconds.",
            val: 1.2,
            from: 0.3,
            to: 4,
            step: 0.1
        },
        {
            label: "ok press",
            prop: "okAmp",
            group: "Ok",
            blurb: "Accepted: one wide ring presses the caps in turn, the caps behind it tinted with ok.",
            tip: "How hard the accepted password's wide ring presses the caps in turn.",
            val: 0.9,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "ok speed",
            prop: "okSpeed",
            group: "Ok",
            tip: "Speed of that ring, item px per second.",
            val: 2400,
            from: 300,
            to: 3000,
            step: 20
        },
        {
            label: "ok tint",
            prop: "okTintStrength",
            group: "Ok",
            tip: "How much of the ok colour the caps take behind the ring.",
            val: 0.8,
            from: 0,
            to: 1,
            step: 0.02
        },
        {
            label: "wake press",
            prop: "wakeAmp",
            group: "Wake",
            blurb: "Input after rest: one broad gentle ring and a sheen of light.",
            tip: "How far input after rest presses the caps at its ring's crest (half this; the ring also brightens them).",
            val: 0.6,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "wake speed",
            prop: "wakeSpeed",
            group: "Wake",
            tip: "Speed of the ring, item px per second.",
            val: 400,
            from: 100,
            to: 1000,
            step: 10
        },
        {
            label: "wake width",
            prop: "wakeSigma",
            group: "Wake",
            tip: "Width of the ring, item px.",
            val: 220,
            from: 60,
            to: 600,
            step: 10
        },
        {
            label: "wake decay",
            prop: "wakeLife",
            group: "Wake",
            tip: "Decay time, seconds.",
            val: 2.4,
            from: 0.5,
            to: 6,
            step: 0.1
        }
    ]

    readonly property var keycapsColourParams: [
        {
            label: "cap",
            prop: "capColor",
            group: "Caps",
            blurb: "The shell's own tokens; the veil holds no literals.",
            tip: "The caps' colour: Theme.surface, the popup's own.",
            val: "@surface"
        },
        {
            label: "mid shade",
            prop: "midColor",
            group: "Caps",
            tip: "The colour a cap's far edge and a pressed cap sink toward, and the gap's mid tone: the border token.",
            val: "@border"
        },
        {
            label: "highlight",
            prop: "bevelColor",
            group: "Caps",
            tip: "The lit edge and the top-left brightening: the raised buttons' bevel token (lifted a little in dark mode).",
            val: "@buttonBevel"
        },
        {
            label: "gap floor",
            prop: "floorColor",
            group: "Gaps",
            blurb: "The carved gaps between the caps.",
            tip: "The carved gap's fill: the sunk panel token.",
            val: "@panelSunk"
        },
        {
            label: "shadow",
            prop: "shadowColor",
            group: "Gaps",
            tip: "Drop shadows: the deep shadow token.",
            val: "@shadowDeep"
        },
        {
            label: "error tint",
            prop: "errorColor",
            group: "Fail",
            blurb: "What a failed attempt tints.",
            tip: "The tint the caps take under a failed attempt's rings.",
            val: "@errorStrong"
        },
        {
            label: "ok tint",
            prop: "okColor",
            group: "Ok",
            blurb: "What the accepted password tints.",
            tip: "The tint behind the accepted password's ring.",
            val: "@ok"
        }
    ]

    readonly property var dialsRingParams: [
        {
            label: "ring pitch",
            prop: "ringPitch",
            group: "Rings",
            blurb: "Concentric rings round the popup, each a plateau of the surface between carved grooves.",
            tip: "Radial width of one ring including its groove, px at 1620 high. About ten rings fill the screen at 92.",
            val: 92,
            from: 40,
            to: 200,
            step: 1
        },
        {
            label: "groove width",
            prop: "grooveWidth",
            group: "Rings",
            tip: "Width of the carved groove between two rings, px.",
            val: 14,
            from: 4,
            to: 40,
            step: 1
        },
        {
            label: "groove depth",
            prop: "grooveDepth",
            group: "Rings",
            tip: "Height of the relief: how steeply the groove's flanks take the light and the shadow.",
            val: 4.5,
            from: 1,
            to: 10,
            step: 0.1
        },
        {
            label: "hub margin",
            prop: "hubMargin",
            group: "Rings",
            tip: "Clear space between the popup's corners and the innermost ring, px.",
            val: 36,
            from: 0,
            to: 200,
            step: 1
        },
        {
            label: "ring tint",
            prop: "ringTone",
            group: "Rings",
            tip: "How much every other ring is tinted toward the sunk tone, so neighbours read apart.",
            val: 0.07,
            from: 0,
            to: 0.3,
            step: 0.01
        },
        {
            label: "spin rate",
            prop: "spinRate",
            group: "Motion",
            blurb: "Every ring turns at its own slow rate and its own way (alternate rings go opposite ways).",
            tip: "Base rate the rings turn, radians per second. 0.011 is one turn in about ten minutes; at the outer rings that is a drift of 10 px a second.",
            val: 0.011,
            from: 0,
            to: 0.06,
            step: 0.001
        },
        {
            label: "rate spread",
            prop: "spinSpread",
            group: "Motion",
            tip: "How much the rates differ from ring to ring: 0 turns them all alike.",
            val: 0.8,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "alignment angle",
            prop: "alignAngle",
            group: "Motion",
            tip: "Where the rings' zero marks line up when the password is accepted, degrees (y down: 90 is straight down, 0 is to the right).",
            val: 90,
            from: -180,
            to: 180,
            step: 1
        }
    ]

    readonly property var dialsTickParams: [
        {
            label: "tick spacing",
            prop: "tickPitch",
            group: "Ticks",
            blurb: "Fine ticks engraved in every ring: each a small carved groove lit by its own slope, so the left and right of a ring catch the light differently.",
            tip: "Target spacing of a ring's ticks along the ring, px at 1620 high. Each ring takes a whole multiple of twelve ticks nearest to this, so the pitch varies a little with the ring's size.",
            val: 17,
            from: 6,
            to: 40,
            step: 1
        },
        {
            label: "tick width",
            prop: "tickWidth",
            group: "Ticks",
            tip: "Half width of a tick's groove, px at 1620 high.",
            val: 1.25,
            from: 0.5,
            to: 3,
            step: 0.05
        },
        {
            label: "tick depth",
            prop: "tickDepth",
            group: "Ticks",
            tip: "Relief of the engraving: how strongly a tick takes the light.",
            val: 3,
            from: 0.5,
            to: 6,
            step: 0.1
        },
        {
            label: "minor length",
            prop: "minorLength",
            group: "Ticks",
            tip: "Length of an ordinary tick as a share of the ring's band.",
            val: 0.22,
            from: 0.05,
            to: 0.9,
            step: 0.01
        },
        {
            label: "major length",
            prop: "majorLength",
            group: "Ticks",
            tip: "Length of a major tick.",
            val: 0.42,
            from: 0.1,
            to: 1,
            step: 0.01
        },
        {
            label: "major every",
            prop: "majorEvery",
            group: "Ticks",
            tip: "Every how many ticks a major one stands.",
            val: 5,
            from: 2,
            to: 12,
            step: 1
        },
        {
            label: "mark length",
            prop: "markLength",
            group: "Ticks",
            tip: "Length of the long mark at each ring's zero, as a share of the band. The marks are what line up when the password is accepted.",
            val: 0.9,
            from: 0.2,
            to: 1,
            step: 0.01
        },
        {
            label: "highlight",
            prop: "grooveHi",
            group: "Light",
            blurb: "How the grooves take the light, and how the rings lie over the held desktop.",
            tip: "Gain of the highlight on the flank that faces the light (upper left).",
            val: 1.4,
            from: 0,
            to: 4,
            step: 0.05
        },
        {
            label: "highlight (dark)",
            prop: "darkHighlight",
            group: "Light",
            tip: "Extra gain of the highlight in dark mode, where the bevel token is close to the surface.",
            val: 1.8,
            from: 1,
            to: 4,
            step: 0.05
        },
        {
            label: "shadow",
            prop: "grooveLo",
            group: "Light",
            tip: "Gain of the shadow on the flank that faces away.",
            val: 1.8,
            from: 0,
            to: 4,
            step: 0.05
        },
        {
            label: "floor tint",
            prop: "cavity",
            group: "Light",
            tip: "How far a groove's bottom is tinted toward the sunk tone.",
            val: 0.55,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "sand (light)",
            prop: "sandAlpha",
            group: "Light",
            tip: "Opacity of the rings' ground over the held desktop in light mode. Boot is opaque.",
            val: 0.72,
            from: 0.2,
            to: 1,
            step: 0.01
        },
        {
            label: "sand (dark)",
            prop: "sandAlphaDark",
            group: "Light",
            tip: "The same in dark mode.",
            val: 0.7,
            from: 0.2,
            to: 1,
            step: 0.01
        },
        {
            label: "brushed metal",
            prop: "brushed",
            group: "Details",
            blurb: "Small extras, each a switch; its default is what ships.",
            tip: "Brushed-metal ring faces: fine lines running round the dial and the anisotropic sheen of such a finish, two soft lobes along the light's axis and none across it. 0 is the plain surface; 1 is the finish. It stays inside the shell's material: the lines are a few percent of a level, the sheen is the bevel token.",
            val: 1,
            from: 0,
            to: 1.5,
            step: 0.05
        },
        {
            label: "numerals",
            prop: "numerals",
            group: "Details",
            tip: "Engraved numerals under the major ticks of every third ring (the rings whose ticks hang from the outer edge): seven-segment digits, carved like the ticks and upright with the ring, turning with it. Off leaves the ticks plain.",
            val: true
        }
    ]

    readonly property var dialsPulseParams: [
        {
            label: "edge feather",
            prop: "groundFeather",
            group: "Entrance",
            blurb: "A cutter groove travels out from the popup; each ring is cut in behind it and turns into place.",
            tip: "Width of the cutter's edge where the ground goes from nothing to whole: kept narrow so no point shows the veil faintly.",
            val: 24,
            from: 2,
            to: 100,
            step: 1
        },
        {
            label: "cut-in",
            prop: "cutIn",
            group: "Entrance",
            tip: "Distance behind the cutter over which a ring's ticks engrave and the ring turns into place, px.",
            val: 130,
            from: 20,
            to: 400,
            step: 5
        },
        {
            label: "entrance spin",
            prop: "entranceSpin",
            group: "Entrance",
            tip: "How far from its place a ring starts, radians; it turns in over the cut-in.",
            val: 1.1,
            from: 0,
            to: 3.14,
            step: 0.05
        },
        {
            label: "arrival",
            prop: "arriveSeconds",
            group: "Shell arrives",
            blurb: "Before the shell has said where it is (a boot, or a lock before its popup opens) the rings centre on the top centre, or on the bar's foot once the bar is there, round a hub of the hub margin alone; when the popup comes they open out round it. Try it with the Run tab's 'shell arrives'.",
            tip: "Seconds the rings take, OutCubic, to ease from where they are drawn to the shell's place when what they centre on changes (nothing, the bar, the popup): the popup opens in 0.4 s and the rings follow it out of the bar rather than jump to it. 1.2 s: the same span as the unlock's zoom, which is this motion played backwards.",
            val: 1.2,
            from: 0.2,
            to: 4,
            step: 0.1
        },
        {
            label: "re-cut speed",
            prop: "recutSpeed",
            group: "Shell arrives",
            tip: "Once the hub holds still a re-cut front leaves it at this speed, px per second at 1620 high: a ring keeps its tick count while the hub moves and takes the count of its new size as the front passes it, its ticks smoothed away and engraved again over the cut-in either side, so no ring re-ticks in view. 1400: about the entrance's own pace.",
            val: 1400,
            from: 200,
            to: 5000,
            step: 50
        },
        {
            label: "notch",
            prop: "notch",
            group: "Keys",
            blurb: "A key clicks every ring one notch round, each a moment after the one inside it.",
            tip: "Ticks a key turns each ring.",
            val: 1,
            from: 1,
            to: 6,
            step: 1
        },
        {
            label: "click delay",
            prop: "clickDelay",
            group: "Keys",
            tip: "Seconds between one ring's click and the next ring out: the wave of clicks.",
            val: 0.035,
            from: 0,
            to: 0.15,
            step: 0.005
        },
        {
            label: "click seconds",
            prop: "clickSeconds",
            group: "Keys",
            tip: "Seconds a ring takes to turn its notch: an ease with a little overshoot, like a detent.",
            val: 0.22,
            from: 0.05,
            to: 1,
            step: 0.01
        },
        {
            label: "shudder",
            prop: "shudder",
            group: "Fail",
            blurb: "A wrong password: the rings shudder out of step with each other, tinted by the error token.",
            tip: "Amplitude of the shudder a failed attempt gives the rings, radians.",
            val: 0.05,
            from: 0,
            to: 0.3,
            step: 0.005
        },
        {
            label: "shudder Hz",
            prop: "shudderHz",
            group: "Fail",
            tip: "Frequency of the shudder.",
            val: 7,
            from: 1,
            to: 20,
            step: 0.5
        },
        {
            label: "shudder decay",
            prop: "shudderSeconds",
            group: "Fail",
            tip: "Seconds for the shudder to fall to a third.",
            val: 0.45,
            from: 0.1,
            to: 2,
            step: 0.05
        },
        {
            label: "fail seconds",
            prop: "failSeconds",
            group: "Fail",
            tip: "The cut-off for following a failed attempt.",
            val: 1.8,
            from: 0.5,
            to: 5,
            step: 0.1
        },
        {
            label: "ok seconds",
            prop: "okSeconds",
            group: "Ok",
            blurb: "Accepted: every ring turns, by the shortest way, until the marks line up.",
            tip: "Seconds every ring takes to turn to the alignment angle when the password is accepted.",
            val: 1.1,
            from: 0.3,
            to: 6,
            step: 0.1
        },
        {
            label: "unlock zoom seconds",
            prop: "zoomSeconds",
            group: "Ok",
            blurb: "The popup retracts into the bar on an unlock and the rings are sized from it; they pull in on this clock instead of with it.",
            tip: "Seconds the rings take, from the ok, to ease from the size they had when the password was accepted to the size the shell's popup says now (a retracted popup is a hub of a few px). The lock holds the veil 0.6 s and fades it over 0.4 s, so 1.2 s zooms visibly through the fade; shorter is a quick zoom-out that is over before the fade shows it.",
            val: 1.2,
            from: 0.2,
            to: 4,
            step: 0.1
        }
    ]

    readonly property var dialsColourParams: [
        {
            label: "surface",
            prop: "sandColor",
            group: "Material",
            blurb: "The shell's own tokens; the veil holds no literals.",
            tip: "The rings' ground: Theme.surface, the popup's own.",
            val: "@surface"
        },
        {
            label: "highlight",
            prop: "highlightColor",
            group: "Material",
            tip: "The lit flank: the raised buttons' bevel token.",
            val: "@buttonBevel"
        },
        {
            label: "shadow",
            prop: "shadowColor",
            group: "Material",
            tip: "The dark flank: the deep shadow token.",
            val: "@shadowDeep"
        },
        {
            label: "groove floor",
            prop: "floorColor",
            group: "Material",
            tip: "The bottom of a groove: the border token.",
            val: "@border"
        },
        {
            label: "error tint",
            prop: "errorColor",
            group: "Fail",
            blurb: "What a failed attempt tints.",
            tip: "The tint the rings take in a failed attempt.",
            val: "@errorTint"
        }
    ]
}
