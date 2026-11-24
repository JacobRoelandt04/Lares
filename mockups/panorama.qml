pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

import "modules/common/theme"
import "modules/common/components"
import "modules/common/glyphs"
import "modules/common/mockup"
import "modules/panorama/bar"
import "modules/panorama/data"
import "modules/presets/data"
import "modules/panorama/popup"
import "modules/panorama/secondary"
import "modules/panorama/screen"

// =============================================================================
// mockups/panorama.qml -- the displays' popup (modules/panorama): the canvas, the hints, the apply bar, the side popup of one
// display, the toasts the mock posted, the identify card over a thumbnail of each fake screen, and the bar's glyph (a cast being made plays on it).
// Every number on the panel.
//
//   quickshell -p mockups/panorama.qml        SCENE=<id> picks a scenario, SELECT=<output> a tile, STAGE=move|mode stages an edit (for a grab),
//                                             TAB=displays|presets the tab on show (the popup is PanoramaTabs: both tabs, as the shell mounts them)
//                                             CASTFIG='{"fps":30,...}' pins the stream's figures for a grab (CastMock.pinned; a key left out has no source)
//                                             CAST=chips|confirm|connecting|tile|detail|failed turns casting ON (panorama.jsonc "cast": true) and plays the
//                                             state (the scene is the laptop): the cast service is a CastMock, the engine the mock's
//
// The service is the MOCK (PanoramaMock): the rules of PanoramaModel on a fake Hyprland, nothing reaches the machine. The toasts are a CLOSE
// STAND-IN (the notification module's card needs its service and scheduler: this draws the same words, buttons and drain), the side popup
// is drawn on a surface of its own where the engine would draw it as a second body.
// =============================================================================
MockupWindow {
    id: win

    moduleId: "panorama"
    title: "Panorama mockup"
    content: demo
    target: popup.style
    stageLabel: "Popup content, its side popup, the toasts and the identify card"

    lists: ({
            canvasParams: win.canvasParams,
            tileParams: win.tileParams,
            floatParams: win.floatParams,
            sideParams: win.sideParams,
            castParams: win.castParams,
            glyphParams: win.glyphParams
        })
    targets: ({
            canvasParams: popup.style,
            tileParams: popup.style,
            floatParams: popup.style,
            sideParams: popup.style,
            castParams: popup.style,
            glyphParams: glyph
        })
    tabDefs: [
        { name: "Run", page: runPage },
        { name: "Canvas", lists: ["canvasParams"] },
        { name: "Tile", lists: ["tileParams"] },
        { name: "Float", lists: ["floatParams"] },
        { name: "Side", lists: ["sideParams"] },
        { name: "Cast", lists: ["castParams", "glyphParams"] }
    ]

    property string scene: Quickshell.env("SCENE") || "desk"
    property string pick: Quickshell.env("SELECT") || ""
    property string stageDemo: Quickshell.env("STAGE") || ""
    property string castDemo: Quickshell.env("CAST") || ""
    // for a grab: RESMENU=1 opens the side popup's resolution menu, STAGE=drag holds a tile mid-drag (the laptop's left third under the pointer)
    property bool resMenu: !!Quickshell.env("RESMENU")
    property string lastClose: ""

    // The toast cards on the stage are a STAND-IN (the shell's notification module draws the real ones): their sizes are fixed here,
    // not panel rows -- a row would tune nothing any module ships, and Save could write it nowhere.
    QtObject {
        id: toastLook
        readonly property real cardWidth: 340
        readonly property real cardRadius: 14
        readonly property real drainWidth: 7
    }

    // casting: a CastMock for the cast service (its script and speed are the Run page's), the config's switch "cast": true
    CastMock {
        id: castMock
        stepMs: win.castDemo === "connecting" ? 60000 : (win.castDemo !== "" ? 150 : 500)
        scanMs: win.castDemo !== "" ? 100 : 1500
        beatMs: win.castDemo !== "" ? 200 : 1000
        pinned: Quickshell.env("CASTFIG") ? JSON.parse(Quickshell.env("CASTFIG")) : null
    }
    PanoramaMock {
        id: svc
        scenario: win.scene
        castConfig: win.castDemo !== ""
        cast: castMock
        popupOpen: win.castDemo !== ""
        onOpenRequested: name => {
            popup.currentTab = "displays";
            popup.selected = name;
        }
    }
    // the Presets tab: the shell's one PresetsService, here its mock (fixtures, nothing reaches the machine)
    AppLookup {
        id: lookup
    }
    PresetsService {
        id: presetsSvc
        live: false
        Component.onCompleted: {
            presetsSvc.refresh();
            presetsSvc.refreshCurrent();
        }
    }

    property real _now: Date.now()
    Timer {
        interval: 100
        repeat: true
        running: svc.postedToasts.length > 0
        onTriggered: win._now = Date.now()
    }

    Component.onCompleted: {
        popup.currentTab = Quickshell.env("TAB") === "presets" ? "presets" : "displays";
        if (win.pick !== "")
            popup.selected = win.pick;
        if (win.stageDemo === "move") {
            const o = svc.displays.find(d => !d.internal);
            if (o) svc.stageMove(o.name, svc.plan.specs[o.name].position[0] + 300, svc.plan.specs[o.name].position[1]);
        } else if (win.stageDemo === "mode") {
            const o = svc.displays.find(d => !d.internal);
            if (o) svc.stageSpec(o.name, { transform: 1 });
        } else if (win.stageDemo === "drag" || win.resMenu) {
            demoTimer.start();
        }
        if (win.castDemo !== "") {
            castMock.script(win.castDemo === "failed" ? "cancelled" : "ok");
            castTimer.start();
        }
    }
    function _find(o: var, name: string): var {
        if (o.objectName === name)
            return o;
        for (const c of o.children) {
            const r = win._find(c, name);
            if (r)
                return r;
        }
        return null;
    }
    // the cast states for a grab: the chip, its confirm step, a connecting cast, the TV as a tile, its detail, a failure
    readonly property string castTv: "wfd:02:AE:00:00:0A:01"
    Timer {
        id: castTimer
        interval: 700
        onTriggered: {
            const chip = win._find(popup, "castChip");
            if (win.castDemo === "confirm" && chip)
                chip.confirming = true;
            else if (["connecting", "tile", "detail", "failed"].indexOf(win.castDemo) >= 0)
                svc.castStart(win.castTv);
            if (win.castDemo === "detail")
                detailTimer.start();
        }
    }
    Timer {
        id: detailTimer
        interval: 1500
        onTriggered: {
            popup.selected = "LARES-CAST-1";
            const sd = win._find(side, "castLine");
            if (sd)
                side.setQ("res", "1280x720");
        }
    }
    Timer {
        id: demoTimer
        interval: 700
        onTriggered: {
            if (win.stageDemo === "drag") {
                const canvas = win._find(popup, "canvas");
                const ext = svc.displays.find(d => !d.internal), lap = svc.displays.find(d => d.internal);
                if (canvas && ext && lap) {
                    const a = canvas.restRect(ext.name), b = canvas.restRect(lap.name);
                    canvas._pressed(ext.name, a.x + a.width / 2, a.y + a.height / 2);
                    canvas._moved(ext.name, a.x + a.width / 2 + 12, a.y + a.height / 2);
                    canvas._moved(ext.name, b.x + b.width * 0.12, b.y + b.height * 0.5);
                }
            }
            if (win.resMenu) {
                const dd = win._find(side, "resolutionDropdown");
                if (dd)
                    dd.openMenu();
            }
        }
    }

    // =====================================================================
    //  THE STAGE: the popup, its side popup, the toasts, the thumbnails
    // =====================================================================
    Item {
        id: demo
        implicitWidth: popup.implicitWidth + 12 + (sideBox.shown ? side.implicitWidth + 24 : 0) + 24
        implicitHeight: Math.max(popup.implicitHeight, sideBox.shown ? side.implicitHeight + 24 : 0) + 12 + below.height + 24

        PanoramaTabs {
            id: popup
            x: 12
            y: 12
            width: implicitWidth
            height: implicitHeight
            service: svc
            presets: presetsSvc
            appLookup: lookup
            eager: true
            motionRunning: win.sheetGrabPath === ""
            fontFamily: "Audiowide"
            onCloseRequested: win.lastClose = "the owner would close the popup now"
        }

        Rectangle {
            id: sideBox
            readonly property bool shown: popup.secondaryOpen
            x: popup.x + popup.width + 12
            y: popup.y
            width: side.implicitWidth
            height: side.implicitHeight
            radius: 14
            color: Theme.surface
            border.width: 1
            border.color: Theme.border
            visible: sideBox.shown
            DisplaySettings {
                id: side
                width: parent.width
                service: svc
                fontFamily: "Audiowide"
                style: popup.style
                targetName: popup.selected
                onDismissed: popup.selected = ""
            }
        }

        Row {
            id: below
            x: 12
            y: Math.max(popup.y + popup.height, sideBox.shown ? sideBox.y + sideBox.height : 0) + 12
            spacing: 12
            height: Math.max(toastCol.height, thumbs.height)

            Column {
                id: toastCol
                spacing: 8
                width: toastLook.cardWidth
                Repeater {
                    model: svc.postedToasts
                    delegate: ShadowBox {
                        id: card
                        required property var modelData
                        width: toastCol.width
                        height: 30 + (modelData.body !== "" ? 18 : 0) + 38
                        raised: true
                        baseRadius: toastLook.cardRadius
                        bevelWidth: 1.5
                        shadowWidth: 5
                        surfaceColor: Theme.surface
                        backgroundColor: Theme.buttonPlateau
                        bevelColor: Theme.buttonBevel
                        shadowColor: Theme.buttonShadow
                        Text {
                            x: 12
                            y: 10
                            text: card.modelData.title
                            color: Theme.textPrimary
                            font.family: "Audiowide"
                            font.pixelSize: 13
                            font.bold: true
                        }
                        Text {
                            x: 12
                            y: 30
                            visible: card.modelData.body !== ""
                            text: card.modelData.body
                            color: Theme.textMuted
                            font.family: "Audiowide"
                            font.pixelSize: 11
                        }
                        Row {
                            anchors.right: parent.right
                            anchors.rightMargin: 12
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: 10
                            spacing: 6
                            Repeater {
                                model: card.modelData.actions
                                delegate: PanoButton {
                                    required property var modelData
                                    text: modelData.label
                                    height: 24
                                    fontPixelSize: 11
                                    ground: Theme.buttonPlateau
                                    accent: modelData.id === "keep"
                                    fontFamily: "Audiowide"
                                    onClicked: svc.toastAction(card.modelData.key, modelData.id)
                                }
                            }
                        }
                        // the keep toast's drain: the shell's own sweep in the card's inset
                        ShadowBox {
                            anchors.fill: parent
                            visible: card.modelData.totalMs > 0
                            baseRadius: toastLook.cardRadius
                            bevelWidth: 0
                            shadowWidth: toastLook.drainWidth
                            surfaceColor: "transparent"
                            backgroundColor: "transparent"
                            bevelColor: "transparent"
                            shadowColor: "transparent"
                            shadowProgress: card.modelData.totalMs > 0 ? Math.max(0, Math.min(1, (card.modelData.deadlineMs - win._now) / card.modelData.totalMs)) : -1
                            shadowProgressColor: Theme.accent
                        }
                    }
                }
            }

            Column {
                id: thumbs
                visible: !Quickshell.env("NOTHUMBS")
                spacing: 8
                Repeater {
                    model: svc.displays.length
                    delegate: Item {
                        id: th
                        required property int index
                        readonly property var d: svc.displays[th.index]
                        width: 240
                        height: 135
                        clip: true
                        Rectangle {
                            anchors.fill: parent
                            radius: 6
                            gradient: Gradient {
                                GradientStop { position: 0; color: "#7A8FB8" }
                                GradientStop { position: 1; color: "#B88F7A" }
                            }
                        }
                        Item {
                            width: 480
                            height: 270
                            scale: 0.5
                            transformOrigin: Item.TopLeft
                            IdentifyCard {
                                anchors.fill: parent
                                service: svc
                                screenName: th.d ? th.d.name : ""
                                style: popup.style
                                fontFamily: "Audiowide"
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            onContainsMouseChanged: svc.setIdentify(containsMouse && th.d ? th.d.name : "")
                        }
                    }
                }
            }

            // the bar's glyph, as the shell mounts it (the owner writes `working`)
            PanoramaBarButton {
                id: glyph
                panes: svc.panes
                mirroring: svc.mirroring
                working: svc.castWorking
                casting: svc.castActive
                hueOn: BarHues.panoramaOn
                hueHover: BarHues.panoramaHover
            }
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
                blurb: "One click puts the fake Hyprland in a state: the displays, the saved setups, the dock's service."
            }
            TipRow {
                tip: "laptop: the panel alone. desk: the laptop with the ACME ultrawide above (a saved setup). projector: a display never seen (the 'connected' toast). three: laptop, ultrawide, TV. onlyExternal: the laptop is off. mirror: the TV mirrors the laptop. integrated: the HDMI note. dlNoService: a DisplayLink dock with no service. modeFails: the next apply does not take. connectedOff: a display is plugged in but off. notImported: Panorama is read only."
                Layout.fillWidth: true
                spacing: 6
                Flow {
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: svc.scenarios
                        delegate: Button {
                            required property var modelData
                            text: modelData.id
                            highlighted: svc.scenario === modelData.id
                            onClicked: {
                                popup.selected = "";
                                svc.scenario = modelData.id;
                                svc.load(modelData.id);
                            }
                        }
                    }
                }
            }
            TipGroup {
                title: "Hotplug"
                blurb: "A plug runs the engine's added handler: the never-seen toast, the saved setup, the placement."
            }
            TipRow {
                tip: "plug: lg (DisplayLink ultrawide, DVI-I-1), tv (HDMI-A-1), proj (a projector with no EDID size, HDMI-A-1), port4k (a 4K portable, DP-1). unplug takes each connected external out: the safety rule switches the laptop panel back on when nothing is left."
                Layout.fillWidth: true
                spacing: 6
                Flow {
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: ["lg", "tv", "proj", "port4k"]
                        delegate: Button {
                            required property string modelData
                            text: "plug " + modelData
                            onClicked: svc.plug(modelData)
                        }
                    }
                    Repeater {
                        model: svc.displays.filter(d => !d.internal)
                        delegate: Button {
                            required property var modelData
                            text: "unplug " + modelData.name
                            onClicked: svc.unplug(modelData.name)
                        }
                    }
                }
            }
            TipGroup {
                title: "The trial"
                blurb: "Apply sends the edit to the fake engine; 1.5 s later it reads the outputs back; the keep toast waits 15 s."
            }
            TipRow {
                tip: "failNextTrial: the fake hardware refuses the next mode, so the verify fails and the old settings come back at once (the popup's note, the red hint). timeScale: the trial's clocks run that many times faster, for a quick look."
                Layout.fillWidth: true
                spacing: 8
                CheckBox {
                    text: "failNextTrial"
                    checked: svc.failNextTrial
                    onToggled: svc.failNextTrial = checked
                }
                Label {
                    text: "timeScale"
                    color: Theme.textMuted
                }
                Slider {
                    from: 1
                    to: 10
                    stepSize: 1
                    value: svc.timeScale
                    Layout.preferredWidth: 140
                    onMoved: svc.timeScale = value
                }
                Label {
                    text: svc.timeScale + "x"
                    color: Theme.textMuted
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipGroup {
                title: "Cast"
                blurb: "A TV found by the scan waits as a chip; a click starts the cast and the TV becomes a display."
            }
            TipRow {
                tip: "panorama.jsonc \"cast\": true. Off (the default) there is no chip, no scan and no engine call. The cast service here is a CastMock: the tool's own events, scripted."
                Layout.fillWidth: true
                spacing: 8
                CheckBox {
                    text: "cast: true"
                    checked: svc.castConfig
                    onToggled: {
                        svc.castConfig = checked;
                        svc.popupOpen = checked;
                    }
                }
                Label {
                    text: "script"
                    color: Theme.textMuted
                }
                Repeater {
                    model: ["ok", "activation-then-ok", "activation-twice", "cancelled", "peer-gone-midstream", "link-then-ok"]
                    delegate: Button {
                        required property string modelData
                        text: modelData
                        highlighted: castMock.scriptName === modelData
                        onClicked: castMock.script(modelData)
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: "cast: " + svc.castPhase + " / " + svc.castState + "   output: " + svc.castOutput + "   devices: " + svc.castDevices.length
                      + "\n" + svc.castLog.slice(-4).join("\n")
                color: Theme.textFaint
                font.family: "Audiowide"
                font.pixelSize: 12
            }
            TipGroup {
                title: "State"
                blurb: "What the popup reads, and what the mock engine did."
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: "setup: " + svc.setupName + " (" + (svc.setupSaved ? "saved" : "not saved") + ")   phase: " + svc.phase + "   dirty: " + svc.dirty
                      + "\nselected: " + popup.selected + "   engine: " + svc.engineState + "   identify: " + svc.identify
                      + "\nsize: " + popup.implicitWidth + " x " + popup.implicitHeight + "   panes: " + svc.panes + "   mirroring: " + svc.mirroring
                      + (win.lastClose !== "" ? "\n" + win.lastClose : "")
                      + "\n" + svc.log.slice(-8).join("\n")
                color: Theme.textFaint
                font.family: "Audiowide"
                font.pixelSize: 12
            }
        }
    ]

    // =====================================================================
    //  VALUES
    // =====================================================================
    readonly property var canvasParams: [
        { label: "popup width", prop: "popupWidth", group: "Popup", blurb: "The popup's frame.",
          tip: "Popup width, px. 460 holds the canvas card at a size where a 3440 x 1440 ultrawide above a laptop still reads as two tiles with their figures.", val: 460, from: 360, to: 640, step: 1 },
        { label: "padding", prop: "padding", group: "Popup",
          tip: "Popup padding, px, on every side. 12 is the shell's one padding.", val: 12, from: 0, to: 32, step: 1 },
        { label: "gap", prop: "gap", group: "Popup",
          tip: "Space between the title, the canvas, the hints and the apply bar, px. Equal to the padding so the rhythm is one number.", val: 12, from: 0, to: 32, step: 1 },
        { label: "canvas height", prop: "canvasHeight", group: "Canvas", blurb: "The carved card the displays stand on, drawn to scale.",
          tip: "The arrangement area's LOWEST height, px: a wide arrangement keeps it. 250 shows a laptop with an ultrawide above it at a readable scale.", val: 250, from: 140, to: 400, step: 1 },
        { label: "canvas max height", prop: "canvasMaxHeight", group: "Canvas",
          tip: "The arrangement area's HIGHEST height, px: the card grows with a tall live arrangement (a stack of three) so its tiles keep their figures; staged drags never resize it. 420 holds three stacked displays.", val: 420, from: 200, to: 600, step: 1 },
        { label: "canvas inset", prop: "canvasPad", group: "Canvas",
          tip: "Space between the card's edge and the layout's bounding box, px.", val: 14, from: 0, to: 40, step: 1 },
        { label: "room round", prop: "slackFrac", group: "Canvas",
          tip: "Free room kept round the layout, as a share of its larger side, so a tile can be carried past the layout's edge. The fit is held while a tile is carried.", val: 0.08, from: 0, to: 0.6, step: 0.01 },
        { label: "largest scale", prop: "maxScale", group: "Canvas",
          tip: "Canvas px per logical px at most: a laptop alone is not blown up to fill the card. 0.16 draws a 2304 px panel 369 px wide.", val: 0.16, from: 0.05, to: 0.5, step: 0.01 },
        { label: "tile gap", prop: "tileGap", group: "Canvas",
          tip: "The visible gap between two tiles, canvas px. Drawn only: the logical edges still touch (Hyprland has no gap), and every tile is inset by half of it on every side, so the picture stays centred. 8 keeps two cards from sitting in each other.", val: 8, from: 0, to: 16, step: 1 },
        { label: "carried opacity", prop: "dragOpacity", group: "Drag", blurb: "A carried tile follows the hand; an outline above every tile shows where it will land.",
          tip: "How solid the carried card is while it follows the hand. 0.6 lets the outline of the place it will take show through.", val: 0.6, from: 0.2, to: 1, step: 0.05 },
        { label: "outline width", prop: "outlineWidth", group: "Drag",
          tip: "The destination outline's line, px.", val: 2, from: 1, to: 5, step: 0.5 },
        { label: "outline opacity", prop: "outlineOpacity", group: "Drag",
          tip: "How solid the destination outline is.", val: 0.9, from: 0.2, to: 1, step: 0.05 },
        { label: "drop ease", prop: "dropEaseMs", group: "Drag",
          tip: "Time a tile takes to settle after the drop and after any resize, ms. 260 is the shell's resize clock.", val: 260, from: 0, to: 600, step: 10 },
        { label: "lift", prop: "liftMs", group: "Drag",
          tip: "Time the carved tile takes to stand proud when picked up, ms.", val: 140, from: 0, to: 400, step: 10 },
        { label: "drag slop", prop: "dragSlop", group: "Drag",
          tip: "Travel before a press is a drag and not a click, px.", val: 5, from: 0, to: 20, step: 1 },
        { label: "parked row", prop: "parkedHeight", group: "Parked", blurb: "A display that is off waits under the canvas.",
          tip: "Height of the parked row, px.", val: 40, from: 28, to: 80, step: 1 },
        { label: "chip width", prop: "chipWidth", group: "Parked", tip: "A parked display's chip, px.", val: 132, from: 80, to: 220, step: 1 },
        { label: "button height", prop: "buttonHeight", group: "Apply", blurb: "Glued to the box's foot while an edit is staged.",
          tip: "Discard and Apply, px. The bar is as tall as its buttons: the popup's padding is the space above and below.", val: 28, from: 22, to: 40, step: 1 },
        { label: "fade", prop: "fadeMs", group: "Apply",
          tip: "Presence fade of the apply bar, the identify card and a selected tile, ms. 160 is the shell's.", val: 160, from: 0, to: 600, step: 10 }
    ]
    readonly property var tileParams: [
        { label: "radius", prop: "tileRadius", group: "Tile", blurb: "One display, to scale.",
          tip: "A tile's corner, px. 10 is the shell's compact radius: a box inside a 14 container.", val: 10, from: 2, to: 20, step: 1 },
        { label: "padding", prop: "tilePadding", group: "Tile", tip: "Space between a tile's edge and its words, px.", val: 8, from: 2, to: 16, step: 1 },
        { label: "shadow", prop: "tileShadow", group: "Tile", tip: "The carve's inset shadow, px (3 on containers).", val: 3, from: 0, to: 8, step: 0.5 },
        { label: "lift shadow", prop: "tileLiftShadow", group: "Tile", tip: "The raised look of a carried tile, px (5 on buttons).", val: 5, from: 0, to: 12, step: 0.5 },
        { label: "label size", prop: "tileLabelSize", group: "Tile", tip: "The label (port + model), px.", val: 12, from: 9, to: 16, step: 1 },
        { label: "figure size", prop: "figureSize", group: "Tile", tip: "The figures, px (11; 10 in compact views).", val: 11, from: 8, to: 14, step: 1 },
        { label: "details from", prop: "tileDetailMinH", group: "Tile",
          tip: "A tile shorter than this shows only its label; the figures fade in over the next 14 px.", val: 62, from: 20, to: 90, step: 1 },
        { label: "ghost opacity", prop: "ghostOpacity", group: "Mirror", blurb: "A display that mirrors the laptop is a ghost behind its tile.",
          tip: "How solid the mirror's ghost tile is.", val: 0.55, from: 0.1, to: 1, step: 0.05 },
        { label: "ghost offset", prop: "ghostOffset", group: "Mirror", tip: "The mirror's card stepped out behind the laptop's tile, px: far enough to read as a second display you can click.", val: 12, from: 0, to: 20, step: 1 }
    ]
    readonly property var floatParams: [
        { label: "rest rate", prop: "floatRestHz", group: "Clock", blurb: "The tiles float on ONE clock for the popup, calm while a tile is carried.",
          tip: "Ticks a second while only the slow sway moves. Every tick is a frame of the whole window, so this is the cost: 20 is the notes' and presets' rate.", val: 20, from: 5, to: 60, step: 1 },
        { label: "sway", prop: "floatSway", group: "Sway", blurb: "Gentler than the theme popup's.",
          tip: "The largest sway of a tile, px (the smallest is a third of it).", val: 1.4, from: 0, to: 4, step: 0.1 },
        { label: "turn", prop: "floatRot", group: "Sway", tip: "The largest turn of a tile, degrees.", val: 0.45, from: 0, to: 2, step: 0.05 },
        { label: "lean", prop: "floatTilt", group: "Pointer", blurb: "What a tile does under the pointer.",
          tip: "How far a tile leans towards the pointer, degrees.", val: 6, from: 0, to: 14, step: 0.5 },
        { label: "lift", prop: "floatLift", group: "Pointer", tip: "The scale a lifted tile grows to.", val: 1.03, from: 1, to: 1.12, step: 0.005 },
        { label: "deal", prop: "floatDealMs", group: "Deal", blurb: "The tiles are dealt in when the popup opens.",
          tip: "The time one tile takes to arrive, ms.", val: 420, from: 0, to: 1000, step: 10 },
        { label: "deal stagger", prop: "floatDealStaggerMs", group: "Deal", tip: "Time between one tile's arrival and the next's, ms.", val: 50, from: 0, to: 200, step: 5 },
        { label: "deal rise", prop: "floatDealRise", group: "Deal", tip: "How far below its place a tile starts, px.", val: 12, from: 0, to: 40, step: 1 },
        { label: "face texture", prop: "faceScale", group: "Clock",
          tip: "While the clock runs a tile's face is one held texture this many times the glass: the sway then moves a quad, not the boxes and text. 2 keeps the figures sharp under a small turn.", val: 2, from: 1, to: 3, step: 0.5 }
    ]
    readonly property var castParams: [
        { label: "row height", prop: "castRowHeight", group: "Chip", blurb: "A TV the scan found waits in the parked row.",
          tip: "The parked row's height while a TV is listed, px: room for the chip's confirm step, so clicking it moves nothing under it.", val: 80, from: 56, to: 120, step: 1 },
        { label: "chip width", prop: "castChipWidth", group: "Chip", tip: "A cast chip at rest, px (the name is elided to it).", val: 176, from: 100, to: 260, step: 1 },
        { label: "chip padding", prop: "castChipPad", group: "Chip", tip: "Space inside a chip round its glyph and words, px.", val: 10, from: 4, to: 20, step: 1 },
        { label: "confirm gap", prop: "castConfirmGap", group: "Chip", tip: "Between the confirm step's words and its Cast button, and between the cast line and Stop casting, px.", val: 8, from: 4, to: 20, step: 1 },
        { label: "figure row", prop: "castFigureRow", group: "Figures", blurb: "The stream's figures in a cast display's detail.",
          tip: "One row of the figures (frames sent, dropped, the round trip ...), px. The words are the figure size (11).", val: 18, from: 14, to: 26, step: 1 },
        { label: "mark size", prop: "castMarkSize", group: "Mark", blurb: "The cast glyph (md-cast).",
          tip: "The cast glyph in a chip and in a casting tile's corner, px.", val: 14, from: 10, to: 22, step: 1 }
    ]
    readonly property var glyphParams: [
        { label: "rest between turns", prop: "breathMs", group: "Glyph", blurb: "The bar's glyph while a cast is being made: its hover hue, its flourish turn after turn.",
          tip: "The glyph stands still this long between two turns, ms. A turn is 1000 ms; with no rest it never stands and reads as nervous.", val: 320, from: 0, to: 1200, step: 10 }
    ]
    readonly property var sideParams: [
        { label: "width", prop: "sideWidth", group: "Side popup", blurb: "One display's settings, in a second body.",
          tip: "Width of the side popup, px. 360 is the aerial panels' width.", val: 360, from: 280, to: 520, step: 1 },
        { label: "block gap", prop: "sideGroupGap", group: "Side popup", tip: "Space between two blocks of settings, px.", val: 12, from: 4, to: 24, step: 1 },
        { label: "caption gap", prop: "captionGap", group: "Side popup", tip: "Space between a caption and its control, px.", val: 6, from: 2, to: 12, step: 1 },
        { label: "toggle row", prop: "sideRow", group: "Side popup", tip: "A toggle's row, px.", val: 24, from: 20, to: 36, step: 1 },
        { label: "segment height", prop: "segHeight", group: "Choices", blurb: "Few options: a segmented row. Many: a dropdown.",
          tip: "A segmented choice and a dropdown's button, px.", val: 28, from: 24, to: 40, step: 1 },
        { label: "tabs at most", prop: "segMaxTabs", group: "Choices", tip: "More options than this and a choice (the scale) is a dropdown.", val: 5, from: 2, to: 8, step: 1 },
        { label: "menu row", prop: "menuRow", group: "Choices", tip: "A dropdown menu's row, px.", val: 26, from: 22, to: 36, step: 1 },
        { label: "menu rows", prop: "menuMaxRows", group: "Choices", tip: "How many options a dropdown shows, the largest first (the menu has no scroll).", val: 10, from: 4, to: 20, step: 1 },
        { label: "workspace gap", prop: "chipGapSide", group: "Choices", tip: "Space between the four workspace toggles, px.", val: 8, from: 2, to: 16, step: 1 },
        { label: "hint padding", prop: "hintPad", group: "Hints", blurb: "What the popup tells: a stripe, a title, a body, a command.",
          tip: "Space inside a hint row, px. 12 is the shell's card padding.", val: 12, from: 4, to: 20, step: 1 },
        { label: "hint gap", prop: "hintGap", group: "Hints", tip: "Space between hint rows, px.", val: 8, from: 0, to: 20, step: 1 },
        { label: "stripe", prop: "hintStripe", group: "Hints", tip: "Width of the severity stripe, px.", val: 4, from: 2, to: 8, step: 1 },
        { label: "command height", prop: "commandHeight", group: "Hints", tip: "The command box, px.", val: 26, from: 20, to: 40, step: 1 },
        { label: "ring", prop: "identifyRing", group: "Identify", blurb: "What a screen shows while its tile is rested on.",
          tip: "The accent ring at the screen's edge, px.", val: 5, from: 1, to: 16, step: 1 },
        { label: "card width", prop: "identifyCardW", group: "Identify", tip: "The name card, px.", val: 260, from: 160, to: 420, step: 1 },
        { label: "card height", prop: "identifyCardH", group: "Identify", tip: "The name card, px.", val: 92, from: 60, to: 160, step: 1 }
    ]
}
