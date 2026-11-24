pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import "modules/common/theme"
import "modules/common/mockup"
import "modules/shell"
import "modules/theme"

// =============================================================================
// mockups/theme.qml -- the theme popup's mockup (modules/theme): linked pairs of mini desktops. Cards, strands and the float on the stage; every number on the panel.
//
//   quickshell -p mockups/theme.qml
//
// The control is a real ThemeControl in "shell" apply mode with no curtain: a click on a card switches THIS mockup's theme, and the crossfade it runs is the host's, so the
// popup can be watched going through one as a theme island.
// =============================================================================
MockupWindow {
    id: win

    moduleId: "theme"
    title: "Theme mockup"
    content: popup
    target: popup.style

    lists: ({
            layoutParams: win.layoutParams,
            floatParams: win.floatParams,
            tiltParams: win.tiltParams,
            dealParams: win.dealParams,
            strandParams: win.strandParams
        })
    tabDefs: [
        { name: "Run", page: runPage },
        { name: "Layout", lists: ["layoutParams"] },
        { name: "Float", lists: ["floatParams"] },
        { name: "Tilt", lists: ["tiltParams"] },
        { name: "Deal", lists: ["dealParams"] },
        { name: "Strands", lists: ["strandParams"] }
    ]

    // What ThemeControl reads of a ShellConfig, and never the real file's `apply` or curtain.
    QtObject {
        id: mockCfg
        readonly property bool curtain: false
        readonly property bool curtainLive: false
        readonly property string curtainStyle: "radial"
        readonly property string curtainProblem: ""
    }
    ThemeControl {
        id: themeCtl
        config: mockCfg
    }

    ThemePopup {
        id: popup
        control: themeCtl
        fontFamily: "Audiowide"
        motionRunning: win.motionOn
    }
    // SHEET_GRAB (the cleanup check's picture): the cards' float has a frame clock of its own, so it does not start
    property bool motionOn: win.sheetGrabPath === ""

    pages: [
        MockupPage {
            id: runPage

            TipRow {
                tip: "The button's right click: light <-> dark of the pair in force, through ThemeControl, the same call the shell makes."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: "Right click"
                    onClicked: themeCtl.click()
                }
                Button {
                    text: "Read the pairs again"
                    onClicked: themeCtl.pairs.rescan()
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "The owner's word that the popup is on screen. Off, the one clock stops: every card holds where it is. In the shell this falls when the popup is parked or its window is hidden."
                Layout.fillWidth: true
                spacing: 8
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
                blurb: "What the popup reads."
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: "in force: " + Theme.themeName + " " + Theme.mode + "\npairs: " + popup.names.join(", ") + "\nclock: " + (popup.clockOn ? "running" : "held")
                      + "\nhand: " + (popup.currentKey || "none") + "\nkeys armed: " + popup.keysArmed
                color: Theme.textFaint
                font.family: "Audiowide"
                font.pixelSize: 14
            }
        }
    ]

    readonly property var layoutParams: [
        {
            label: "card width",
            prop: "cardWidth",
            group: "Cards",
            blurb: "What a card is: a mini desktop, in the mode's palette on the mode's own gradient ground.",
            tip: "236 px is 16:9 at the height below: the desktop it stands for. Two cards and the gap make the popup's width.",
            val: 236,
            from: 160,
            to: 320,
            step: 1
        },
        {
            label: "card height",
            prop: "cardHeight",
            group: "Cards",
            tip: "133 px keeps 16:9. The islands, windows and lines inside are shares of this, so the mock scales with it.",
            val: 133,
            from: 90,
            to: 180,
            step: 1
        },
        {
            label: "corner radius",
            prop: "cardRadius",
            group: "Cards",
            tip: "14 is the shell's container radius, so a card has the curve of everything around it.",
            val: 14,
            from: 4,
            to: 24,
            step: 1
        },
        {
            label: "shadow reach",
            prop: "shadowWidth",
            group: "Cards",
            tip: "How far the drop shadow reaches. Cards stand proud of the surface; 6 is wider than a button's 5 because they float over it.",
            val: 6,
            from: 0,
            to: 14,
            step: 0.5
        },
        {
            label: "texture scale",
            prop: "faceScale",
            group: "Cards",
            tip: "The face is one held texture at this many times the glass: the tilt and the sway resample it, and 2 keeps 2 px lines clean through a rotation. 1 is softer, 3 costs memory.",
            val: 2,
            from: 1,
            to: 4,
            step: 0.5
        },
        {
            label: "padding",
            prop: "padding",
            group: "Layout",
            blurb: "The popup around the cards.",
            tip: "12 on every side, the shell's padding, so the space above equals the space below.",
            val: 12,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "strand gap",
            prop: "strandGap",
            group: "Layout",
            tip: "The room between a pair's two cards, which the strands and the name stand in. 96 keeps the longest name as shown (tokyo night, 79 px in Audiowide; a name's dashes show as spaces) inside it at 12 px.",
            val: 96,
            from: 50,
            to: 180,
            step: 1
        },
        {
            label: "row gap",
            prop: "rowGap",
            group: "Layout",
            tip: "Between two pairs: the padding, as everywhere.",
            val: 12,
            from: 4,
            to: 32,
            step: 1
        },
        {
            label: "rows before it scrolls",
            prop: "maxRows",
            group: "Layout",
            tip: "How many pairs show at once. Four rows at 133 is a popup of 586 px; more pairs scroll inside it.",
            val: 4,
            from: 1,
            to: 8,
            step: 1
        },
        {
            label: "name size",
            prop: "labelSize",
            group: "Layout",
            tip: "The pair's name, body text.",
            val: 12,
            from: 9,
            to: 16,
            step: 1
        },
        {
            label: "name rise",
            prop: "labelRise",
            group: "Layout",
            tip: "How far above the strands' axis the name stands: clear of the widest wave (12) and of the thickest strand.",
            val: 34,
            from: 10,
            to: 60,
            step: 1
        }
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

    readonly property var strandParams: [
        {
            label: "amplitude 1",
            prop: "strand1Amp",
            group: "Thick strand",
            blurb: "The widest, slowest strand. Three strands per pair, the old picker's numbers: y = sin(x f - t flow) a sin(pi u), so each pinches to nothing at both cards.",
            tip: "Px at the middle.",
            val: 12,
            from: 0,
            to: 24,
            step: 0.5
        },
        {
            label: "wave 1",
            prop: "strand1Wave",
            group: "Thick strand",
            tip: "Rad/px: 0.08 is one wave in 78 px, about one across the gap.",
            val: 0.08,
            from: 0.01,
            to: 0.4,
            step: 0.01
        },
        {
            label: "flow 1",
            prop: "strand1Flow",
            group: "Thick strand",
            tip: "Rad/s the wave travels.",
            val: 0.8,
            from: 0,
            to: 5,
            step: 0.1
        },
        {
            label: "width 1",
            prop: "strand1Width",
            group: "Thick strand",
            tip: "Px at the middle.",
            val: 8,
            from: 0.5,
            to: 16,
            step: 0.5
        },
        {
            label: "alpha 1",
            prop: "strand1Alpha",
            group: "Thick strand",
            tip: "The thick strand is the haze the two others run over.",
            val: 0.45,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "amplitude 2",
            prop: "strand2Amp",
            group: "Middle strand",
            blurb: "The second strand.",
            tip: "Px at the middle.",
            val: 8,
            from: 0,
            to: 24,
            step: 0.5
        },
        {
            label: "wave 2",
            prop: "strand2Wave",
            group: "Middle strand",
            tip: "Rad/px.",
            val: 0.12,
            from: 0.01,
            to: 0.4,
            step: 0.01
        },
        {
            label: "flow 2",
            prop: "strand2Flow",
            group: "Middle strand",
            tip: "Rad/s.",
            val: 1.2,
            from: 0,
            to: 5,
            step: 0.1
        },
        {
            label: "width 2",
            prop: "strand2Width",
            group: "Middle strand",
            tip: "Px at the middle.",
            val: 5,
            from: 0.5,
            to: 16,
            step: 0.5
        },
        {
            label: "alpha 2",
            prop: "strand2Alpha",
            group: "Middle strand",
            tip: "Alpha.",
            val: 0.7,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "amplitude 3",
            prop: "strand3Amp",
            group: "Fine strand",
            blurb: "The thinnest, fastest strand, on top.",
            tip: "Px at the middle.",
            val: 4,
            from: 0,
            to: 24,
            step: 0.5
        },
        {
            label: "wave 3",
            prop: "strand3Wave",
            group: "Fine strand",
            tip: "Rad/px.",
            val: 0.15,
            from: 0.01,
            to: 0.4,
            step: 0.01
        },
        {
            label: "flow 3",
            prop: "strand3Flow",
            group: "Fine strand",
            tip: "Rad/s.",
            val: 1.5,
            from: 0,
            to: 5,
            step: 0.1
        },
        {
            label: "width 3",
            prop: "strand3Width",
            group: "Fine strand",
            tip: "Px at the middle.",
            val: 3,
            from: 0.5,
            to: 16,
            step: 0.5
        },
        {
            label: "alpha 3",
            prop: "strand3Alpha",
            group: "Fine strand",
            tip: "Alpha.",
            val: 0.95,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "end width",
            prop: "strandEndWidth",
            group: "Ends",
            blurb: "Where a strand meets a card.",
            tip: "A strand's width at the card, as a share of its middle: 0 comes to a point, 1 stays full.",
            val: 0.2,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "tuck",
            prop: "strandTuck",
            group: "Ends",
            tip: "How far under the card a strand starts, px: a card that sways never shows the end.",
            val: 8,
            from: 0,
            to: 24,
            step: 1
        }
    ]
}
