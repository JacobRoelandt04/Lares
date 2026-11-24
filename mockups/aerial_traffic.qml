pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

import "modules/aerial/bar"
import "modules/aerial/data"
import "modules/common/components"
import "modules/common/mockup"
import "modules/common/theme"

// =============================================================================
// mockups/aerial_traffic.qml -- aerial's bar PILL on its strip (modules/aerial/bar/AerialBarButton.qml): the Wi-Fi / wire / plane glyph and the
// Bluetooth rune in one pill, the battery stripe between them, the traffic figures that widen it, and the four states the module added
// (a tunnel up: a padlock on the glyph; the hotspot on: the broadcasting glyph; a Public network without a tunnel: an open padlock in the
// warn colour; a failed pad: the glyph in the warn / error colour). Driven by AerialMock (the contract's members); the pill reads the
// service and nothing else. Its settings panel: the figures' margin and thresholds (the Button tab) and the mock's own knobs (Run).
//
// Run it: quickshell -p mockups/aerial_traffic.qml        Env: SCENARIO=<home|crowd|airplane|hotspot|vpn|portal|pairing|earbuds|nowifi|errors>
// =============================================================================
MockupWindow {
    id: win

    moduleId: "aerial_traffic"
    title: "Aerial pill mockup"
    stageLabel: "The bar pill on its strip -- mock data"
    content: strip
    target: strip
    targets: ({
            figureParams: strip,
            machineParams: mock
        })
    lists: ({
            figureParams: win.figureParams,
            machineParams: win.machineParams
        })
    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        {
            name: "Button",
            lists: ["figureParams"]
        },
        {
            name: "Machine",
            lists: ["machineParams"]
        }
    ]

    AerialMock {
        id: mock
        live: true
        scenario: Quickshell.env("SCENARIO") || "home"
        trafficMbps: 0
    }

    // ---- the pill on its strip -----------------------------------------------------------------------------------
    Item {
        id: strip
        objectName: "strip"

        // What the panel writes.
        property real gap: 22
        property real reach: 14
        property int holdReadings: 4

        readonly property real pad: 12
        readonly property real volW: 52
        readonly property real netW: 52
        readonly property real siW: 100
        implicitWidth: strip.pad * 2 + strip.volW + strip.netW + strip.siW + 2 * strip.gap
        implicitHeight: 40

        component Neighbour: ShadowBox {
            required property real slotW
            width: slotW
            height: 26
            y: 7
            baseRadius: 13
            surfaceColor: Theme.surface
            backgroundColor: Theme.panelSunk
            bevelColor: Theme.bevel
            shadowColor: Theme.border
            bevelWidth: 1
            shadowWidth: 3
        }
        Neighbour {
            slotW: strip.volW
            x: strip.pad
        }
        AerialBarButton {
            id: button
            objectName: "button"
            x: strip.pad + strip.volW + strip.gap
            y: 7
            service: mock
            fontFamily: "Audiowide"
            reach: strip.reach
            // when the figures come is aerial.jsonc's (bar.trafficFromMbps; they stay down to half of it)
            trafficConfig: ({ holdReadings: strip.holdReadings })
            halfLength: 26
            thickness: 26
            width: implicitWidth
            height: implicitHeight
        }
        Neighbour {
            slotW: strip.siW
            x: strip.pad + strip.volW + strip.gap + strip.netW + strip.gap
        }
    }

    pages: [
        MockupPage {
            id: runPage

            TipGroup {
                title: "Scenarios"
                blurb: "The mock machine's states (AerialMockData.js): the pill reads the facts the popup reads."
            }
            TipRow {
                tip: "The mock's scenario. home: a Wi-Fi network joined; vpn: the tunnel up (a padlock on the glyph); hotspot: the broadcasting glyph; portal: the NET pad warns (the alert fan); airplane: the plane; earbuds: a device with a battery (the stripe); nowifi: no radio; errors: a failed pad."
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
            TipRow {
                tip: "Light or dark: the pill's inks are the shell's hues (BarHues) and the warn / error tokens."
                Layout.fillWidth: true
                spacing: 8
                Button { text: "Light"; onClicked: Theme.setMode("light") }
                Button { text: "Dark"; onClicked: Theme.setMode("dark") }
                Item { Layout.fillWidth: true }
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: "scenario " + mock.scenario + "   net glyph U+" + (button.netGlyph.codePointAt(0) || 0).toString(16) + "   badge " + (button.netBadge === "" ? "-" : "U+" + button.netBadge.codePointAt(0).toString(16))
                    + "   fault " + (button.pill.fault || "-") + "   figures " + (button.trafficShown ? "up" : "off")
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
            }
        }
    ]

    readonly property var figureParams: [
        {
            label: "gap",
            prop: "gap",
            group: "Margin",
            blurb: "The room the pill grows into. The shell's one spacing rule: ink to ink (shell.jsonc `inkGap`; a pill's ink is its box).",
            tip: "Space between the ink of two modules of the island. The pill grows by `reach` into it on each side while it shows traffic, so the clear margin left is gap - reach: 22 leaves 8.",
            val: 22,
            from: 4,
            to: 32,
            step: 1
        },
        {
            label: "reach",
            prop: "reach",
            group: "Margin",
            tip: "How far the pill grows past each end of its slot while it shows THREE-digit figures, in the shell's face (Audiowide; ShellLayout.TRAFFIC_REACH says the same 14): at 8 the \"1\" stands on the wifi glyph. A figure with fewer digits grows the pill half a digit's width less per side for each, so a single digit does not carry the room of two more.",
            val: 14,
            from: 0,
            to: 20,
            step: 1
        },
        {
            label: "hold (readings)",
            prop: "holdReadings",
            group: "Threshold",
            tip: "How many readings in a row below `stays at` before the figures leave. The reading is one second, so 4 is four seconds: a burst that dips and returns never makes them flap, and they leave on a reading rather than on a clock of their own.",
            val: 4,
            from: 1,
            to: 10,
            step: 1
        }
    ]

    readonly property var machineParams: [
        {
            label: "traffic Mbit/s",
            prop: "trafficMbps",
            group: "Machine",
            blurb: "What the mock link carries: the pill's figures follow it.",
            tip: "The carrying link's rate (AerialMock). The figures appear at `appears at` and the battery stripe yields its place to them; 0 is an idle link.",
            val: 0,
            from: 0,
            to: 900,
            step: 1
        }
    ]
}
