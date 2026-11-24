pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import "modules/common/components"
import "modules/common/mockup"
import "modules/common/theme"

// =============================================================================
// mockups/shadowbox.qml -- the shell's one material, as a gallery of the shared components that carry it.
//
// Everything sits on one surface: containers, fields and grooves are CARVED (an inset shadow inside the edge, a light
// bevel outside), buttons STAND PROUD (a drop shadow outside, a highlight inside). The stage shows each shared piece
// once, dressed in the theme's tokens as its hosts dress it: ShadowBox carved and raised, RaisedButton plain and
// accent, GrooveToggle off and on, CarvedRing with a fill, SlotRail with its ball in a slot. The groove slider has its
// own mockup (groove_slider.qml).
//
// One tab per component. A row is the component's OWN default, which every host that leaves the value unset follows;
// most hosts set their sizes (the containers' 3 / 1 carve, the buttons' 5 / 1.5), so Save here changes what a host
// gets only where it says nothing. The Run tab clicks through the states a host would set.
//
//   quickshell -p mockups/shadowbox.qml
// =============================================================================
MockupWindow {
    id: win

    moduleId: "shadowbox"
    title: "Carved and raised components"
    stageLabel: "ShadowBox, RaisedButton, GrooveToggle, CarvedRing, SlotRail"
    content: gallery
    target: carved
    targets: ({
            buttonParams: button,
            toggleParams: toggle,
            ringParams: ring,
            railParams: rail
        })
    zoom: 1.5

    lists: ({
            boxParams: win.boxParams,
            buttonParams: win.buttonParams,
            toggleParams: win.toggleParams,
            ringParams: win.ringParams,
            railParams: win.railParams
        })

    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        {
            name: "ShadowBox",
            lists: ["boxParams"]
        },
        {
            name: "Button",
            lists: ["buttonParams"]
        },
        {
            name: "Toggle",
            lists: ["toggleParams"]
        },
        {
            name: "Ring",
            lists: ["ringParams"]
        },
        {
            name: "Rail",
            lists: ["railParams"]
        }
    ]

    // ---- the states a host sets -------------------------------------------------
    QtObject {
        id: host
        property bool on: true
        property real fill: 220
        property string railKey: "b"
        property string lastClick: "(none)"
    }

    component Caption: Text {
        color: Theme.textFaint
        font.family: "Inter"
        font.pixelSize: 11
    }

    // ---- the drop-in content: the gallery ---------------------------------------
    Item {
        id: gallery

        readonly property real pad: 24
        implicitWidth: 560
        implicitHeight: 316

        // ---- ShadowBox: carved (the panel's) and raised (it follows the carved one's shape) ----
        ShadowBox {
            id: carved
            x: gallery.pad
            y: gallery.pad
            width: 150
            height: 90
            baseRadius: 14
            surfaceColor: Theme.surface
            backgroundColor: Theme.panelSunk
            bevelColor: Theme.bevel
            shadowColor: Theme.border
        }
        Caption {
            x: carved.x
            y: carved.y + carved.height + 6
            text: "carved"
        }
        ShadowBox {
            id: raisedBox
            x: carved.x + carved.width + gallery.pad
            y: gallery.pad
            width: 150
            height: 90
            baseRadius: 14
            raised: true
            bevelWidth: 1.5
            shadowWidth: 5
            curveProfile: carved.curveProfile
            shadowEdgeAlpha: carved.shadowEdgeAlpha
            shadowFalloff: carved.shadowFalloff
            surfaceColor: Theme.surface
            backgroundColor: Theme.buttonPlateau
            bevelColor: Theme.buttonBevel
            shadowColor: Theme.buttonShadow
        }
        Caption {
            x: raisedBox.x
            y: raisedBox.y + raisedBox.height + 6
            text: "raised"
        }

        // ---- RaisedButton: plain (the panel's) and accent (it follows) ----
        RaisedButton {
            id: button
            x: raisedBox.x + raisedBox.width + gallery.pad
            y: gallery.pad + 6
            text: "Plain"
            surfaceColor: Theme.surface
            plateauColor: Theme.buttonPlateau
            plateauHoverColor: Theme.buttonPlateauHover
            bevelColor: Theme.buttonBevel
            shadowColor: Theme.buttonShadow
            accentColor: Theme.accent
            accentHoverColor: Theme.accentHover
            accentBevelColor: Theme.accentBevel
            onClicked: host.lastClick = "Plain"
        }
        RaisedButton {
            id: accentButton
            x: button.x
            y: button.y + button.height + 18
            text: "Accent"
            accent: true
            fontPixelSize: button.fontPixelSize
            bold: button.bold
            horizontalPadding: button.horizontalPadding
            minWidth: button.minWidth
            bevelWidth: button.bevelWidth
            shadowWidth: button.shadowWidth
            radius: button.radius
            shadowEdgeAlpha: button.shadowEdgeAlpha
            pressMs: button.pressMs
            hoverMs: button.hoverMs
            surfaceColor: Theme.surface
            plateauColor: Theme.buttonPlateau
            plateauHoverColor: Theme.buttonPlateauHover
            bevelColor: Theme.buttonBevel
            shadowColor: Theme.buttonShadow
            accentColor: Theme.accent
            accentHoverColor: Theme.accentHover
            accentBevelColor: Theme.accentBevel
            onClicked: host.lastClick = "Accent"
        }

        // ---- GrooveToggle: the panel's, and one that follows it in the other state ----
        GrooveToggle {
            id: toggle
            x: gallery.pad
            y: 166
            surfaceColor: Theme.surface
            checked: host.on
            onToggled: c => host.on = c
        }
        GrooveToggle {
            x: toggle.x + toggle.width + 18
            y: toggle.y
            trackWidth: toggle.trackWidth
            grooveThickness: toggle.grooveThickness
            ballSize: toggle.ballSize
            moveMs: toggle.moveMs
            fillShadowDarken: toggle.fillShadowDarken
            surfaceColor: Theme.surface
            checked: !host.on
            onToggled: c => host.on = !c
        }
        Caption {
            x: toggle.x
            y: toggle.y + toggle.height + 6
            text: "toggle"
        }

        // ---- CarvedRing with one fill ----
        CarvedRing {
            id: ring
            x: raisedBox.x + Math.round((raisedBox.width - width) / 2)
            y: 140
            width: implicitWidth
            height: implicitHeight
            radius: 52
            surfaceColor: Theme.surface
            aStarts: [0, 0, 0, 0]
            aEnds: [host.fill, 0, 0, 0]
        }

        // ---- SlotRail: three slots, the ball in one ----
        SlotRail {
            id: rail
            x: button.x + 12
            y: 166
            height: 72
            ground: Theme.surface
            stops: [
                {
                    key: "a",
                    y: 12,
                    top: 0,
                    height: 24
                },
                {
                    key: "b",
                    y: 36,
                    top: 24,
                    height: 24
                },
                {
                    key: "c",
                    y: 60,
                    top: 48,
                    height: 24
                }
            ]
            currentKey: host.railKey
        }
        Caption {
            x: rail.x + rail.width + 10
            y: rail.y + 30
            text: "rail"
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
                blurb: "The states a host puts the pieces in. On the stage itself the buttons press, the toggles switch and the boxes are what they are."
            }
            TipRow {
                tip: "The toggles' state: the first follows it, the second shows the other one."
                Layout.fillWidth: true
                CheckBox {
                    text: "first toggle on"
                    checked: host.on
                    onToggled: host.on = checked
                }
            }
            TipRow {
                tip: "How far round the ring's fill comes, degrees from the top, clockwise: a timer's share of its dial."
                Layout.fillWidth: true
                Label {
                    text: "ring fill"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Slider {
                    Layout.fillWidth: true
                    from: 0
                    to: 360
                    stepSize: 1
                    value: host.fill
                    onMoved: host.fill = value
                }
                Label {
                    text: Math.round(host.fill) + " deg"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
            }
            TipRow {
                tip: "The slot the rail's ball rests in: it rolls there on the rail's clock, a little past and back."
                Layout.fillWidth: true
                spacing: 6
                Label {
                    text: "rail slot"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Repeater {
                    model: ["a", "b", "c"]
                    delegate: Button {
                        required property string modelData
                        text: modelData
                        checkable: true
                        checked: host.railKey === modelData
                        onClicked: host.railKey = modelData
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "State"
                blurb: "What the pieces report."
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: "last button: " + host.lastClick + "   toggle " + (toggle.checked ? "on" : "off") + "   rail " + (rail.moving ? "rolling" : "seated")
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
            }
        }
    ]

    readonly property var boxParams: [
        {
            label: "bevel px",
            prop: "bevelWidth",
            group: "Depth",
            blurb: "How deep the box is carved (or how high it stands). The raised box on the stage keeps its own 5 / 1.5.",
            tip: "Carved: the light bevel outside the edge; raised: the highlight inside it, px. Hosts set their own (1 on containers, 1.5 on buttons); 2 is for a box that says nothing.",
            val: 2,
            from: 0,
            to: 6,
            step: 0.25
        },
        {
            label: "shadow px",
            prop: "shadowWidth",
            group: "Depth",
            tip: "Carved: how far the inset shadow reaches inward; raised: the drop shadow outside, px. Hosts set their own (3 on containers, 5 on buttons).",
            val: 3,
            from: 0,
            to: 12,
            step: 0.25
        },
        {
            label: "edge strength",
            prop: "shadowEdgeAlpha",
            group: "Shadow shape",
            blurb: "The shadow as three numbers: how far it reaches (above), how strong it is at the edge, how it decays inward.",
            tip: "How strong the shadow is at the very edge, 0 to 1: the depth.",
            val: 1,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "falloff",
            prop: "shadowFalloff",
            group: "Shadow shape",
            tip: "How the strength decays inward: 1 leaves the easing curve alone, above 1 pulls the shadow tight against the edge, below 1 spreads it and lets it linger.",
            val: 1,
            from: 0.2,
            to: 4,
            step: 0.05
        },
        {
            label: "corner profile",
            prop: "curveProfile",
            group: "Corners",
            blurb: "The shape of the rounded corners.",
            tip: "The corners' curve: 1 is a circular arc, above 1 approaches a squircle.",
            val: 1,
            from: 0.5,
            to: 3,
            step: 0.05
        }
    ]

    readonly property var buttonParams: [
        {
            label: "font px",
            prop: "fontPixelSize",
            group: "Label",
            blurb: "The word on the button.",
            tip: "The label's pixel size: 12 is the shell's body text.",
            val: 12,
            from: 8,
            to: 20,
            step: 1
        },
        {
            label: "bold",
            prop: "bold",
            group: "Label",
            tip: "On: the label in bold.",
            val: true
        },
        {
            label: "side padding px",
            prop: "horizontalPadding",
            group: "Label",
            tip: "Space either side of the label, px; the button is the label plus this twice, never under the minimum width.",
            val: 14,
            from: 4,
            to: 32,
            step: 1
        },
        {
            label: "min width px",
            prop: "minWidth",
            group: "Label",
            tip: "The narrowest the button gets, px, so a short word still makes a button.",
            val: 64,
            from: 24,
            to: 160,
            step: 1
        },
        {
            label: "radius px",
            prop: "radius",
            group: "Relief",
            blurb: "The button stands proud: a drop shadow outside, a highlight inside, tuned apart (a highlight is a thin line, a shadow spreads).",
            tip: "The plateau's corner radius, px.",
            val: 8,
            from: 0,
            to: 20,
            step: 0.5
        },
        {
            label: "highlight px",
            prop: "bevelWidth",
            group: "Relief",
            tip: "Width of the highlight inside the edge, px: 1.5 is the shell's buttons'.",
            val: 1.5,
            from: 0,
            to: 4,
            step: 0.25
        },
        {
            label: "shadow px",
            prop: "shadowWidth",
            group: "Relief",
            tip: "Width of the drop shadow outside the edge, px: 5 is the shell's buttons'.",
            val: 5,
            from: 0,
            to: 12,
            step: 0.5
        },
        {
            label: "shadow edge",
            prop: "shadowEdgeAlpha",
            group: "Relief",
            tip: "Strength of the drop shadow at the edge, 0 to 1.",
            val: 0.9,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "press ms",
            prop: "pressMs",
            group: "Motion",
            blurb: "How the button answers the pointer.",
            tip: "How long the press takes to sink the button and to let it up, ms.",
            val: 90,
            from: 0,
            to: 400,
            step: 10
        },
        {
            label: "hover ms",
            prop: "hoverMs",
            group: "Motion",
            tip: "How long the plateau takes to reach its hover tone and back, ms: 120 is the shell's hover fade.",
            val: 120,
            from: 0,
            to: 400,
            step: 10
        }
    ]

    readonly property var toggleParams: [
        {
            label: "track px",
            prop: "trackWidth",
            group: "Shape",
            blurb: "A carved groove with a raised ball that rolls from off to on; the groove fills with the accent behind it.",
            tip: "The toggle's length, px: the ball travels it end to end.",
            val: 34,
            from: 16,
            to: 80,
            step: 1
        },
        {
            label: "groove px",
            prop: "grooveThickness",
            group: "Shape",
            tip: "The groove's thickness, px.",
            val: 8,
            from: 2,
            to: 20,
            step: 0.5
        },
        {
            label: "ball px",
            prop: "ballSize",
            group: "Shape",
            tip: "The ball's diameter, px: 14 is the shell's ball.",
            val: 14,
            from: 6,
            to: 30,
            step: 0.5
        },
        {
            label: "fill shade",
            prop: "fillShadowDarken",
            group: "Shape",
            tip: "How much darker the accent fill's inset shadow is than the fill: 1.35 is the Workspaces fills'.",
            val: 1.35,
            from: 1,
            to: 3,
            step: 0.05
        },
        {
            label: "move ms",
            prop: "moveMs",
            group: "Motion",
            blurb: "The ball's roll.",
            tip: "How long the ball takes to roll across, ms.",
            val: 180,
            from: 40,
            to: 600,
            step: 10
        }
    ]

    readonly property var ringParams: [
        {
            label: "line px",
            prop: "lineThickness",
            group: "Groove",
            blurb: "A circular groove carved into the surface, a timer's dial. Sizes are px before the size scale; the radius is the host's.",
            tip: "The ring's groove width before the size scale, px: 6 is the Workspaces groove's.",
            val: 6,
            from: 2,
            to: 16,
            step: 0.5
        },
        {
            label: "size scale",
            prop: "sizeScale",
            group: "Groove",
            tip: "Multiplies the groove's sizes: 1.5 matches the Workspaces groove at its own default scale.",
            val: 1.5,
            from: 0.5,
            to: 3,
            step: 0.05
        },
        {
            label: "shadow px",
            prop: "grooveShadowWidth",
            group: "Groove",
            tip: "Width of the inset shadow inside the groove, px before the scale.",
            val: 3,
            from: 0,
            to: 8,
            step: 0.5
        },
        {
            label: "bevel px",
            prop: "grooveBevelWidth",
            group: "Groove",
            tip: "Width of the light bevel outside it, px before the scale.",
            val: 2,
            from: 0,
            to: 6,
            step: 0.5
        },
        {
            label: "bevel strength",
            prop: "grooveBevelStrength",
            group: "Groove",
            tip: "How far the rim outside the carve reaches from the ground toward the bevel colour: 1 is the Workspaces groove's; less is a subtler rim.",
            val: 1,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "fill shade",
            prop: "fillShadowDarken",
            group: "Fills",
            blurb: "What fills the groove: a timer's share, each tone up to four arcs.",
            tip: "How much darker a fill's inset shadow is than the fill.",
            val: 1.35,
            from: 1,
            to: 3,
            step: 0.05
        },
        {
            label: "head bulge",
            prop: "fillHeadBulge",
            group: "Fills",
            tip: "Depth of a fill's convex head, as a share of the half groove: 1 is a semicircle, a capsule's end; 0 a straight cut.",
            val: 1,
            from: 0,
            to: 2,
            step: 0.05
        }
    ]

    readonly property var railParams: [
        {
            label: "line px",
            prop: "lineThickness",
            group: "Groove",
            blurb: "A carved groove with a slot at every place the ball can rest: a one-of-many choice (the audio popup's default device, a menu's radio group).",
            tip: "The rail's groove width, px.",
            val: 4,
            from: 1,
            to: 10,
            step: 0.5
        },
        {
            label: "slot px",
            prop: "slotSize",
            group: "Groove",
            tip: "A slot's diameter, px.",
            val: 12,
            from: 4,
            to: 24,
            step: 0.5
        },
        {
            label: "ball px",
            prop: "ballSize",
            group: "Groove",
            tip: "The ball's diameter, px.",
            val: 8,
            from: 4,
            to: 20,
            step: 0.5
        },
        {
            label: "travel ms",
            prop: "travelMs",
            group: "Motion",
            blurb: "The ball's roll: it passes its slot a little and settles back into it.",
            tip: "How long the ball takes from one slot to the next, ms (OutBack).",
            val: 420,
            from: 100,
            to: 1200,
            step: 10
        },
        {
            label: "settle",
            prop: "settle",
            group: "Motion",
            tip: "How far past its slot the ball rolls before it settles, as a share of the way.",
            val: 0.05,
            from: 0,
            to: 0.3,
            step: 0.01
        },
        {
            label: "settle cap px",
            prop: "settleMaxPx",
            group: "Motion",
            tip: "The most it rolls past, px, so a long way does not leave the slot.",
            val: 2.5,
            from: 0,
            to: 10,
            step: 0.5
        }
    ]
}
