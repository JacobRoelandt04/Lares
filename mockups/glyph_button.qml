pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import "modules/bar/llm"
import "modules/bar/player"
import "modules/bar/system_update/components"
import "modules/common/components"
import "modules/common/glyphs"
import "modules/common/mockup"
import "modules/shell"

// =============================================================================
// mockups/glyph_button.qml -- BarGlyphButton, the bar's plain icon button, and the three bar buttons built on it.
//
// The stage is a strip of the bar: a plain BarGlyphButton (the one the panel tunes) and the shell's own users of it,
// each as the bar mounts it -- the theme button, the LLM star, the player -- at the shell's gap. The
// users take the plain button's size, pad, font and cursor, so a change shows on all four; their ink and their hover hue
// are their own (what the module says now, and the bar's hue table, BarHues), which the Run tab drives through stand-ins:
// the theme run busy or failed, the LLM loaded, generating or waiting for you, the player playing
// or on a new song (the turn and the motion lines).
//
// Save writes BarGlyphButton's own defaults: no bar button sets its size or pad, so every one follows them. The Hover tab
// is the bar's ONE hover clock (BarHues.hoverMs): every glyph of the bar fades on it. The Flourish tab is the player's spin and
// the system update's box (the archive glyph stands at the strip's end for it): hovering a glyph plays its flourish, once per
// entry (GlyphFlourish), the rule for every bar glyph's flourish.
//
//   quickshell -p mockups/glyph_button.qml
// =============================================================================
MockupWindow {
    id: win

    moduleId: "glyph_button"
    title: "Bar glyph button mockup"
    stageLabel: "BarGlyphButton, then the bar's own: theme, LLM, player -- and the system update's box (its flourish)"
    content: strip
    target: plain
    zoom: 3

    lists: ({
            glyphParams: win.glyphParams,
            glyphColors: win.glyphColors,
            hoverParams: win.hoverParams,
            flourishPlayer: win.flourishPlayer,
            flourishUpdate: win.flourishUpdate
        })
    targets: ({
            hoverParams: BarHues,
            flourishPlayer: playerBtn,
            flourishUpdate: updateIcon
        })

    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        {
            name: "Button",
            lists: ["glyphParams", "glyphColors"]
        },
        {
            name: "Hover",
            lists: ["hoverParams"]
        },
        {
            name: "Flourish",
            lists: ["flourishPlayer", "flourishUpdate"]
        }
    ]

    // ---- the stand-ins the users read -------------------------------------
    // ThemeControl: `active` > 0 while a run is out, `fails` counts failed runs.
    QtObject {
        id: themeStandIn
        property int active: 0
        property int fails: 0
    }
    // The LLM's services: the star reads a model loaded in the backend, a generation, a pending confirmation.
    component LlmServiceStandIn: QtObject {
        readonly property string model: "stand-in"
        property var backend: ({
                loaded: {}
            })
        property bool generating: false
        property var pendingConfirm: null
    }
    QtObject {
        id: llmStandIn
        property bool attended: false
        readonly property LlmServiceStandIn service: LlmServiceStandIn {}
    }
    // MpdService: connected, the play state, the song id (a new id turns the glyph).
    QtObject {
        id: playerStandIn
        property bool connected: true
        property string playState: "stop"
        property int songId: 1
    }
    property string lastClick: "(none)"

    // ---- the drop-in content: a strip of the bar ---------------------------
    Item {
        id: strip

        // The shell's spacing between two modules' ink (shell.jsonc inkGap), and the island's own inset.
        readonly property real gap: 22
        readonly property real pad: 12
        implicitWidth: Math.ceil(row.implicitWidth) + 2 * strip.pad
        implicitHeight: 40

        Row {
            id: row
            x: strip.pad
            y: Math.round((strip.height - height) / 2)
            spacing: strip.gap

            BarGlyphButton {
                id: plain
                glyph: String.fromCodePoint(0xF0493)
                onClicked: button => win.lastClick = "plain, " + (button === Qt.RightButton ? "right" : "left")
            }
            ThemeBarButton {
                control: themeStandIn
                family: plain.family
                glyphSize: plain.glyphSize
                pad: plain.pad
                pointerCursor: plain.pointerCursor
                onClicked: button => win.lastClick = "theme, " + (button === Qt.RightButton ? "right" : "left")
            }
            LlmBarButton {
                id: llmBtn
                llm: llmStandIn
                family: plain.family
                glyphSize: plain.glyphSize
                pad: plain.pad
                pointerCursor: plain.pointerCursor
                onClicked: button => win.lastClick = "LLM, " + (button === Qt.RightButton ? "right" : "left")
            }
            PlayerBarButton {
                id: playerBtn
                player: playerStandIn
                family: plain.family
                glyphSize: plain.glyphSize
                pad: plain.pad
                pointerCursor: plain.pointerCursor
                onClicked: button => win.lastClick = "player, " + (button === Qt.RightButton ? "right" : "left")
            }
            SystemUpdateIcon {
                id: updateIcon
                updatesAvailable: 12
                fontFamily: "Audiowide"
                onClicked: win.lastClick = "update"
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
                blurb: "What the modules behind the three bar buttons are saying. Each button mixes its own ink from it."
            }
            TipRow {
                tip: "The theme button: a theme run out (busy: the ink takes busyShare of the accent) and a failed run (the warn tint for six seconds, then it lets go)."
                Layout.fillWidth: true
                spacing: 6
                Label {
                    text: "theme"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                CheckBox {
                    text: "busy"
                    checked: themeStandIn.active > 0
                    onToggled: themeStandIn.active = checked ? 1 : 0
                }
                Button {
                    text: "fail"
                    onClicked: themeStandIn.fails++
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "The LLM star: a model loaded (the star's own hue; one shape, the colour carries it), a generation running (the accent) and a question waiting for you (the warn tint, which wins over the accent)."
                Layout.fillWidth: true
                spacing: 6
                Label {
                    text: "LLM"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                CheckBox {
                    text: "loaded"
                    checked: llmBtn.loaded
                    onToggled: llmStandIn.service.backend = checked ? {
                        loaded: {
                            "stand-in": {
                                size: 1
                            }
                        }
                    } : {
                        loaded: {}
                    }
                }
                CheckBox {
                    text: "generating"
                    checked: llmStandIn.service.generating
                    onToggled: llmStandIn.service.generating = checked
                }
                CheckBox {
                    text: "needs you"
                    checked: llmStandIn.service.pendingConfirm !== null
                    onToggled: llmStandIn.service.pendingConfirm = checked ? {
                        tool: "stand-in"
                    } : null
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "The player: playing takes the ink to the player's own hue; a new song turns the glyph and draws its motion lines, as a song change in mpd does."
                Layout.fillWidth: true
                spacing: 6
                Label {
                    text: "player"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                CheckBox {
                    text: "playing"
                    checked: playerStandIn.playState === "play"
                    onToggled: playerStandIn.playState = checked ? "play" : "stop"
                }
                Button {
                    text: "next song"
                    onClicked: playerStandIn.songId++
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "State"
                blurb: "What the buttons hold now."
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: "plain " + plain.width.toFixed(0) + " x " + plain.height.toFixed(0) + " px   hovered " + plain.hovered
                      + "\nlast click: " + win.lastClick + "   player turning " + playerBtn.flourishing
                      + "   box " + (updateIcon.flourish.playing ? "open" : "shut")
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
            }
        }
    ]

    readonly property var glyphParams: [
        {
            label: "glyph px",
            prop: "glyphSize",
            group: "Glyph",
            blurb: "The one glyph of the button and the square round it.",
            tip: "The glyph's pixel size in its font. 18 is the notes button's glyph; no bar button sets its own, so all of them follow this.",
            val: 18,
            from: 10,
            to: 32,
            step: 1
        },
        {
            label: "pad px",
            prop: "pad",
            group: "Glyph",
            tip: "Space round the glyph on every side, px: the button is a square of glyph + 2 x pad, which is what the pointer can hit. 5 makes the 28 px square the notes button is at 18.",
            val: 5,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "font",
            prop: "family",
            group: "Glyph",
            tip: "The font the glyph is drawn in. Symbols Nerd Font holds every glyph the bar's buttons use; a glyph is never drawn bold, the synthetic weight deforms it.",
            val: "Symbols Nerd Font",
            kind: "text"
        },
        {
            label: "hand cursor",
            prop: "pointerCursor",
            group: "Pointer",
            blurb: "How the button answers the pointer: a short colour fade (the Hover tab) and the hand cursor, nothing else.",
            tip: "On: the pointer becomes the hand over the button, the shell's one sign that something can be clicked.",
            val: true
        }
    ]

    // THE BAR'S ONE HOVER CLOCK (BarHues): every bar glyph's hover fades on it, these four and every other module's.
    readonly property var hoverParams: [
        {
            label: "hover ms",
            prop: "hoverMs",
            group: "Hover",
            blurb: "The bar's one hover fade: every glyph of the bar (these four, the bell, the pairs, the reels' neighbours) eases its hover on it.",
            tip: "How long a glyph takes to reach its hover hue and back, ms, sine in and out. 180: the old 120 ms OutCubic covered half its way in a fifth of its time and read as instant; this is a short fade the eye sees.",
            val: 180,
            from: 0,
            to: 400,
            step: 10
        }
    ]

    // THE FLOURISHES: the player's spin (a new song, or the pointer coming onto the disc) and the system update's box (the pointer).
    readonly property var flourishPlayer: [
        {
            label: "windup deg",
            prop: "windupDeg",
            group: "Player spin",
            blurb: "The disc's flourish: a short windup one way, then a coasting spin the other that eases out upright, with faint motion lines. It plays on a new song while playing and when the pointer comes onto the disc (once per entry).",
            tip: "How far the disc turns back before the spin, degrees. 28: enough to read as a windup, not a wobble.",
            val: 28,
            from: 0,
            to: 90,
            step: 1
        },
        {
            label: "windup ms",
            prop: "windupMs",
            group: "Player spin",
            tip: "How long the windup takes, ms (InOutQuad). 150: a flick.",
            val: 150,
            from: 0,
            to: 600,
            step: 10
        },
        {
            label: "coast ms",
            prop: "coastMs",
            group: "Player spin",
            tip: "How long the spin coasts to rest, ms (OutCubic: fast at first, then easing out). 900.",
            val: 900,
            from: 200,
            to: 3000,
            step: 10
        },
        {
            label: "turns",
            prop: "turns",
            group: "Player spin",
            tip: "Whole turns the disc makes, so it comes to rest upright. 2.",
            val: 2,
            from: 1,
            to: 6,
            step: 1
        }
    ]
    readonly property var flourishUpdate: [
        {
            label: "box flourish",
            prop: "flourishEnabled",
            group: "Update box",
            blurb: "The system update's flourish: the pointer coming onto the idle archive glyph tosses its lid off while two papers rise out of the box, staggered, drop back in, and the lid falls back on with a bounce. Hover the box on the stage to play it (once per entry); not during a run.",
            tip: "Off: the box never moves; the hover is its colour alone.",
            val: true
        },
        {
            label: "box ms",
            prop: "flourishMs",
            group: "Update box",
            tip: "How long the whole flourish takes, ms: the lid's toss, the papers up and down, the lid's fall and its two bounces are shares of it (ArchivePose.js). 880: snappy; longer reads floaty.",
            val: 880,
            from: 400,
            to: 2000,
            step: 10
        }
    ]

    readonly property var glyphColors: [
        {
            label: "ink",
            prop: "ink",
            group: "Ink",
            blurb: "The colours the glyph is drawn in.",
            tip: "The ink at rest: the muted text colour. A bar button replaces it with what its module says (the theme run's tints, the LLM's generating, the player's playing).",
            val: "@textMuted"
        },
        {
            label: "hover ink",
            prop: "hoverInk",
            group: "Ink",
            tip: "The plain button's ink under the pointer, mixed in by the hover fade: the accent. Every bar button sets its own from the bar's hue table (BarHues), so this reaches the plain button only.",
            val: "@accent"
        }
    ]
}
