pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

import "modules/common/theme"
import "modules/common/components"
import "modules/common/mockup"
import "modules/presets"
import "modules/presets/data"
import "modules/presets/data/PresetFixtures.js" as Fixtures

// =============================================================================
// mockups/presets.qml -- the desktop presets' popup (modules/presets): a card per saved desktop, its workspaces drawn as tiled mini screens,
// Load (replace, confirmed) and Add, the right-click menu, and the card that saves the desktop now. Every number on the panel.
//
//   quickshell -p mockups/presets.qml
//
// The service is the MOCK (PresetsService `live: false`): fixtures shaped like the user's desktop (PresetFixtures.js), the verbs answered in
// memory, every call in the Run tab's log. Nothing here reaches the tool or a window.
// =============================================================================
MockupWindow {
    id: win

    moduleId: "presets"
    title: "Presets mockup"
    content: popup
    target: popup.style

    lists: ({
            layoutParams: win.layoutParams,
            behaviourParams: win.behaviourParams,
            faceParams: win.faceParams,
            floatParams: win.floatParams,
            tiltParams: win.tiltParams,
            dealParams: win.dealParams
        })
    tabDefs: [
        { name: "Run", page: runPage },
        { name: "Layout", lists: ["layoutParams", "behaviourParams"] },
        { name: "Face", lists: ["faceParams"] },
        { name: "Float", lists: ["floatParams"] },
        { name: "Tilt", lists: ["tiltParams"] },
        { name: "Deal", lists: ["dealParams"] }
    ]

    AppLookup {
        id: lookup
    }
    PresetsService {
        id: svc
        live: false
        Component.onCompleted: {
            svc.refresh();
            svc.refreshCurrent();
        }
    }

    PresetsPopup {
        id: popup
        service: svc
        appLookup: lookup
        fontFamily: "Audiowide"
        motionRunning: win.motionOn
        onCloseRequested: win.lastClose = "the owner would close the popup now"
    }
    // SHEET_GRAB (a still picture): the cards' float has a frame clock of its own, so it does not start
    property bool motionOn: win.sheetGrabPath === ""
    property string lastClose: ""

    function _many(): void {
        const base = Fixtures.presets();
        const out = [];
        for (let i = 0; i < 9; i++) {
            const p = JSON.parse(JSON.stringify(base[i % base.length]));
            p.name = p.name + (i >= base.length ? " " + (i + 1) : "");
            p.slug = svc.slugOf(p.name);
            out.push(p);
        }
        svc.mockPresets = out;
        svc.refresh();
    }
    // SCENE=<name> picks a scenario at start (a grab of each)
    Component.onCompleted: {
        if (win.scene === "one") {
            svc.mockPresets = Fixtures.presets().slice(0, 1);
            svc.refresh();
        } else if (win.scene === "none") {
            svc.mockPresets = [];
            svc.refresh();
        } else if (win.scene === "many") {
            win._many();
        }
    }
    property string scene: Quickshell.env("SCENE") || ""

    pages: [
        MockupPage {
            id: runPage

            TipGroup {
                title: "Scenarios"
                blurb: "One click puts the mock's presets in a state."
            }
            TipRow {
                tip: "The fixtures: dev (a six-tab group with VS Code, zen, two tiles, a special kitty), Writing (three tiles and a floating window), Media (a fullscreen mpv), Everything (seven workspaces: the strip ends in +N). One / None / Many: the grid with one card, the save card alone, nine cards (it scrolls)."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: "Fixtures"
                    onClicked: {
                        svc.mockPresets = Fixtures.presets();
                        svc.refresh();
                    }
                }
                Button {
                    text: "One"
                    onClicked: {
                        svc.mockPresets = Fixtures.presets().slice(0, 1);
                        svc.refresh();
                    }
                }
                Button {
                    text: "None"
                    onClicked: {
                        svc.mockPresets = [];
                        svc.refresh();
                    }
                }
                Button {
                    text: "Many"
                    onClicked: win._many()
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "What the mock's plan answers for Load. With windows to close, the first click turns Load into 'Close N windows?' and a second click loads; with none it loads at once. Motion off: the one clock stops and every card holds."
                Layout.fillWidth: true
                spacing: 8
                CheckBox {
                    text: "Load closes nothing"
                    onToggled: {
                        const m = {};
                        if (checked)
                            for (let i = 0; i < svc.presets.length; i++)
                                m[svc.presets[i].name] = 0;
                        svc.mockClose = m;
                    }
                }
                CheckBox {
                    text: "Motion"
                    checked: win.motionOn
                    onToggled: win.motionOn = checked
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipGroup {
                title: "State"
                blurb: "What the popup reads, and the calls the live service would make."
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: "presets: " + svc.presets.map(p => p.name + (p.deleted ? " (deleted)" : "")).join(", ")
                      + "\nhand: " + popup.hand + "   keys armed: " + popup.keysArmed + "   clock: " + (popup.clockOn ? "running" : "held")
                      + "\nsize: " + popup.implicitWidth + " x " + popup.implicitHeight
                      + (win.lastClose !== "" ? "\n" + win.lastClose : "")
                      + "\ncalls: " + svc.calls.slice(-8).join(" | ")
                color: Theme.textFaint
                font.family: "Audiowide"
                font.pixelSize: 13
            }
        }
    ]

    readonly property var layoutParams: [
        { label: "padding", prop: "padding", group: "Popup", blurb: "The grid: cards in columns, the last card the one that saves the desktop now.",
          tip: "Popup padding, px, on every side and between the cards' rows. 12 is the shell's one padding.", val: 12, from: 0, to: 32, step: 1 },
        { label: "columns", prop: "columns", group: "Popup",
          tip: "Cards across at most. Two keep the popup near the theme popup's width with a face wide enough for four mini screens. With fewer cards than columns the popup is as wide as its cards: the save card alone is one column.", val: 2, from: 1, to: 4, step: 1 },
        { label: "max rows", prop: "maxRows", group: "Popup",
          tip: "Rows shown before the grid scrolls. Three rows of two are five presets and the save card.", val: 3, from: 1, to: 6, step: 1 },
        { label: "card width", prop: "cardWidth", group: "Cards", blurb: "One saved desktop: its name and window count, its face, Load and Add.",
          tip: "A card's width, px. 280 leaves the face 256 px: four mini screens of 59 px, or three of 81.", val: 280, from: 200, to: 400, step: 1 },
        { label: "card gap", prop: "cardGap", group: "Cards",
          tip: "Space between two cards, px: the shell's padding, so the gaps match the edges.", val: 12, from: 0, to: 32, step: 1 },
        { label: "corner radius", prop: "cardRadius", group: "Cards",
          tip: "The cards' corner, px. 14 is the shell's container radius.", val: 14, from: 0, to: 24, step: 1 },
        { label: "card padding", prop: "cardPadding", group: "Cards",
          tip: "Space inside a card, px, on every side. 12 is the shell's card padding.", val: 12, from: 4, to: 24, step: 1 },
        { label: "shadow", prop: "shadowWidth", group: "Cards",
          tip: "The card's drop shadow, px: it stands proud like a button (5).", val: 5, from: 0, to: 12, step: 0.5 },
        { label: "face scale", prop: "faceScale", group: "Cards",
          tip: "The held texture of the name and the face, in device px per px. 2 keeps the small tiles crisp under the sway's turn (the theme card's number).", val: 2, from: 1, to: 4, step: 0.5 },
        { label: "title size", prop: "titleSize", group: "Cards",
          tip: "The preset's name, px, bold.", val: 13, from: 9, to: 20, step: 1 },
        { label: "meta size", prop: "metaSize", group: "Cards",
          tip: "The window count beside the name, px: the shell's figure size.", val: 11, from: 8, to: 16, step: 1 },
        { label: "title gap", prop: "titleGap", group: "Cards",
          tip: "Space between the name and the face, px.", val: 8, from: 0, to: 20, step: 1 },
        { label: "foot gap", prop: "footGap", group: "Cards",
          tip: "Space between the face and the buttons, px.", val: 10, from: 0, to: 24, step: 1 },
        { label: "button height", prop: "buttonHeight", group: "Cards",
          tip: "Load / Add / Save, px.", val: 26, from: 18, to: 40, step: 1 },
        { label: "button gap", prop: "buttonGap", group: "Cards",
          tip: "Space between Load and Add, px.", val: 8, from: 0, to: 20, step: 1 }
    ]

    readonly property var behaviourParams: [
        { label: "confirm ms", prop: "confirmMs", group: "Behaviour", blurb: "What the cards do.",
          tip: "How long Load's 'Close N windows?' waits for the second click before it goes back to Load. 4 s: long enough to read the count, short enough that a forgotten confirm is not armed when the pointer comes back.", val: 4000, from: 1000, to: 10000, step: 100 },
        { label: "shake px", prop: "shakePx", group: "Behaviour",
          tip: "The refusal's first swing, px (a taken name, a bad rename): the shell's Shake.", val: 4, from: 1, to: 10, step: 0.5 }
    ]

    readonly property var faceParams: [
        { label: "face height", prop: "faceHeight", group: "Strip", blurb: "One mini screen per workspace that has windows, all at one scale, each its monitor's aspect.",
          tip: "The face's height, px, the workspace names under the screens included.", val: 72, from: 40, to: 120, step: 1 },
        { label: "screen gap", prop: "screenGap", group: "Strip",
          tip: "Space between two mini screens, px.", val: 6, from: 0, to: 16, step: 1 },
        { label: "least width", prop: "screenMinWidth", group: "Strip",
          tip: "The least a mini screen is drawn at, px; below it the strip keeps what fits and ends in +N.", val: 46, from: 24, to: 100, step: 1 },
        { label: "most width", prop: "screenMaxWidth", group: "Strip",
          tip: "The widest a mini screen is drawn, px (one or two workspaces would otherwise fill the card).", val: 128, from: 60, to: 256, step: 1 },
        { label: "screen radius", prop: "screenRadius", group: "Strip",
          tip: "A mini screen's corner, px.", val: 4, from: 0, to: 10, step: 0.5 },
        { label: "label size", prop: "labelSize", group: "Strip",
          tip: "The workspace's name under its screen, px.", val: 9, from: 7, to: 14, step: 1 },
        { label: "label gap", prop: "labelGap", group: "Strip",
          tip: "Space between a screen and its name, px.", val: 2, from: 0, to: 8, step: 1 },
        { label: "badge width", prop: "badgeWidth", group: "Strip",
          tip: "The special workspace's badge, px wide: its windows' icons stacked, the four-pointed star under it.", val: 26, from: 16, to: 48, step: 1 },
        { label: "tile radius", prop: "tileRadius", group: "Tiles", blurb: "A window as Hyprland tiled it: its saved place and size, scaled, every edge on a whole pixel.",
          tip: "A window tile's corner, px.", val: 2.5, from: 0, to: 6, step: 0.5 },
        { label: "tile gap", prop: "tileGap", group: "Tiles",
          tip: "Taken off a tile's right and bottom edges, px, so two tiles that meet show their seam.", val: 1, from: 0, to: 3, step: 1 },
        { label: "icon max", prop: "iconMax", group: "Tiles",
          tip: "The largest app icon in a tile, px.", val: 18, from: 8, to: 32, step: 1 },
        { label: "icon min", prop: "iconMin", group: "Tiles",
          tip: "Below this a tile shows no icon (a sliver of a window), px.", val: 8, from: 4, to: 16, step: 1 },
        { label: "tab strip", prop: "tabStrip", group: "Tiles",
          tip: "A group's tab strip, px tall: a segment per tab, the shown one in the accent.", val: 3, from: 1, to: 6, step: 1 }
    ]

    readonly property var floatParams: [
        {
            label: "drift min",
            prop: "moveAmpMin",
            group: "Drift",
            blurb: "Every card sways on three oscillators of its own (x, y, rotation), each rolling a new size and speed now and then. The phases are INTEGRATED: speed is speed at any age.",
            tip: "Least swing in px. The old picker's cards went 2.6 to 20 px in a full-screen widget; in a popup a card must stay well inside its 12 px of padding.",
            val: 1.2,
            from: 0,
            to: 6,
            step: 0.1
        },
        {
            label: "drift max",
            prop: "moveAmpMax",
            group: "Drift",
            tip: "Most swing in px. 3 leaves 9 px of the padding, and the lift's 5 px still fit.",
            val: 3,
            from: 0,
            to: 10,
            step: 0.1
        },
        {
            label: "drift speed min",
            prop: "moveFreqMin",
            group: "Drift",
            tip: "Slowest swing, rad/s: 0.5 is one sway in 12.5 s.",
            val: 0.5,
            from: 0.05,
            to: 3,
            step: 0.05
        },
        {
            label: "drift speed max",
            prop: "moveFreqMax",
            group: "Drift",
            tip: "Fastest swing, rad/s: 0.9 is one sway in 7 s. Balatro's cards idle about here: alive, never busy.",
            val: 0.9,
            from: 0.05,
            to: 3,
            step: 0.05
        },
        {
            label: "turn min",
            prop: "rotAmpMin",
            group: "Turn",
            blurb: "The sway's rotation, in the card's own plane.",
            tip: "Least turn in degrees, the old picker's 0.4.",
            val: 0.35,
            from: 0,
            to: 3,
            step: 0.05
        },
        {
            label: "turn max",
            prop: "rotAmpMax",
            group: "Turn",
            tip: "Most turn in degrees, the old picker's 0.9.",
            val: 0.8,
            from: 0,
            to: 3,
            step: 0.05
        },
        {
            label: "turn speed min",
            prop: "rotFreqMin",
            group: "Turn",
            tip: "Slowest turn, rad/s.",
            val: 0.4,
            from: 0.05,
            to: 3,
            step: 0.05
        },
        {
            label: "turn speed max",
            prop: "rotFreqMax",
            group: "Turn",
            tip: "Fastest turn, rad/s.",
            val: 1,
            from: 0.05,
            to: 3,
            step: 0.05
        },
        {
            label: "new targets after, min",
            prop: "retargetMin",
            group: "Rolls",
            blurb: "How often an oscillator picks a new size and speed.",
            tip: "Seconds, the old picker's 6: often enough that the sway never reads as a loop.",
            val: 6,
            from: 1,
            to: 20,
            step: 0.5
        },
        {
            label: "new targets after, max",
            prop: "retargetMax",
            group: "Rolls",
            tip: "Seconds, the old picker's 7.",
            val: 7,
            from: 1,
            to: 20,
            step: 0.5
        }
    ]

    readonly property var tiltParams: [
        {
            label: "tilt",
            prop: "tiltMax",
            group: "Tilt",
            blurb: "The card under the pointer leans towards it, on a spring. Balatro's, which the old picker never had.",
            tip: "Degrees at the card's edge. 9 reads as a card in the hand; past 15 the mock's lines start to swim.",
            val: 9,
            from: 0,
            to: 20,
            step: 0.5
        },
        {
            label: "spring",
            prop: "tiltStiffness",
            group: "Tilt",
            tip: "How hard the spring pulls: 140 reaches the pointer in about 200 ms.",
            val: 140,
            from: 20,
            to: 400,
            step: 5
        },
        {
            label: "damping",
            prop: "tiltDamping",
            group: "Tilt",
            tip: "15 at this stiffness is a little under critical: one small overshoot, then still.",
            val: 15,
            from: 4,
            to: 40,
            step: 0.5
        },
        {
            label: "perspective",
            prop: "planeDistance",
            group: "Tilt",
            tip: "The eye's distance in px: smaller is a stronger perspective. 700 on a card of 236 is a card held at reading distance.",
            val: 700,
            from: 200,
            to: 2000,
            step: 10
        },
        {
            label: "lift",
            prop: "liftScale",
            group: "Lift",
            blurb: "The hand on a card: the pointer's, or the keys'.",
            tip: "Scale of the card the hand is on: 1.045 is 5 px each way, inside the padding.",
            val: 1.045,
            from: 1,
            to: 1.12,
            step: 0.005
        },
        {
            label: "click dip",
            prop: "clickKick",
            group: "Lift",
            tip: "A push on the lift's spring when a card is clicked: negative dips it, the answer a card gives before the switch starts.",
            val: -6,
            from: -20,
            to: 20,
            step: 0.5
        }
    ]

    readonly property var dealParams: [
        {
            label: "deal time",
            prop: "dealMs",
            group: "Deal",
            blurb: "The cards land one after the other as the popup opens, like a hand being dealt.",
            tip: "How long one card takes, OutBack. 440 is about the popup's own opening; 0 turns the deal off.",
            val: 440,
            from: 0,
            to: 1000,
            step: 10
        },
        {
            label: "stagger",
            prop: "dealStaggerMs",
            group: "Deal",
            tip: "Between two cards, in reading order.",
            val: 45,
            from: 0,
            to: 150,
            step: 5
        },
        {
            label: "rise",
            prop: "dealRise",
            group: "Deal",
            tip: "How far below its place a card starts, px.",
            val: 16,
            from: 0,
            to: 40,
            step: 1
        },
        {
            label: "turn",
            prop: "dealTurn",
            group: "Deal",
            tip: "How far turned a card starts, degrees, every other one the other way.",
            val: 3.5,
            from: 0,
            to: 12,
            step: 0.5
        }
    ]
}
