pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import "modules/common/mockup"
import "modules/aerial/data"
import "modules/aerial/secondary"

// =============================================================================
// mockups/aerial_panels.qml -- the aerial module's DETAIL PANELS (the popup's secondary), every kind on the AerialMock: network (a Wi-Fi
// network and its pages), saved (the memory chip), wired, hotspot, vpn, bt (a device and its pairing prompt), pad, usage.
//
// The content is the real AerialSecondary (the drop-in the popup mounts), sized by its own implicit size. The Run page picks the kind, the
// target and the mock's scenario; with `live` on the mock answers intents like a machine would (a password refused, a tunnel raised) after
// `settleMs`. The panel's numbers (width, tallest height, gaps) are on the Panel tab; they live in PanelStyle.
// =============================================================================
MockupWindow {
    id: win

    moduleId: "aerial_panels"
    title: "Aerial detail panels"
    content: demo
    target: demo

    lists: ({ panelParams: win.panelParams, mockParams: win.mockParams })

    tabDefs: [
        { name: "Run", page: runPage },
        { name: "Panel", lists: ["panelParams"] },
        { name: "Mock", lists: ["mockParams"] }
    ]

    Item {
        id: demo

        implicitWidth: panelHost.implicitWidth
        implicitHeight: panelHost.implicitHeight

        // what the Panel tab writes (PanelStyle's numbers)
        property real panelWidth: 360
        property real maxHeight: 560
        property real padding: 12
        property real gap: 12
        property real rowGap: 8
        // what the Mock tab writes
        property real settleMs: 700
        property real trafficMbps: 25
        property bool live: true
        property string scenario: "home"

        readonly property alias mock: mock
        readonly property alias sec: panelHost

        AerialMock {
            id: mock
            live: demo.live
            scenario: demo.scenario
            settleMs: demo.settleMs
            trafficMbps: demo.trafficMbps
        }
        AerialSecondary {
            id: panelHost
            vm: mock
            kind: "network"
            targetKey: "Home-5G"
            fontFamily: "Audiowide"
            Binding { target: panelHost.look; property: "panelWidth"; value: demo.panelWidth }
            Binding { target: panelHost.look; property: "maxHeight"; value: demo.maxHeight }
            Binding { target: panelHost.look; property: "padding"; value: demo.padding }
            Binding { target: panelHost.look; property: "gap"; value: demo.gap }
            Binding { target: panelHost.look; property: "rowGap"; value: demo.rowGap }
        }
        Behavior on implicitHeight {
            NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
        }
    }

    readonly property var kindRows: [
        { k: "network", t: "Home-5G", label: "Network: connected" },
        { k: "network", t: "FRITZ!Box 7590", label: "Network: needs a password" },
        { k: "network", t: "eduroam", label: "Network: enterprise" },
        { k: "saved", t: "", label: "Saved networks" },
        { k: "wired", t: "enp46s0", label: "Cable" },
        { k: "hotspot", t: "", label: "Hotspot" },
        { k: "vpn", t: "", label: "VPN" },
        { k: "bt", t: "AA:BB:CC:00:00:01", label: "Bluetooth device" },
        { k: "bt", t: "AA:BB:CC:00:00:10", label: "Bluetooth pairing" },
        { k: "pad", t: "net", label: "Test pad: internet" },
        { k: "pad", t: "dns", label: "Test pad: DNS" },
        { k: "usage", t: "", label: "Usage" }
    ]
    readonly property var scenarioFor: ({ "Bluetooth device": "earbuds", "Bluetooth pairing": "pairing", "Hotspot": "hotspot", "Cable": "hotspot", "VPN": "vpn", "Test pad: internet": "portal", "Test pad: DNS": "errors" })

    pages: [
        MockupPage {
            id: runPage

            TipGroup {
                title: "Panel"
                blurb: "Which detail panel the stage shows. Each is the drop-in the popup mounts as its secondary."
            }
            TipRow {
                tip: "One click puts the stage on that panel and the mock on the scenario that has something to show for it (a pairing prompt, a hotspot with clients, a portal)."
                Layout.fillWidth: true
                Flow {
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: win.kindRows
                        delegate: Button {
                            required property var modelData
                            text: modelData.label
                            onClicked: {
                                demo.scenario = win.scenarioFor[modelData.label] || "home";
                                demo.sec.kind = modelData.k;
                                demo.sec.targetKey = modelData.t;
                            }
                        }
                    }
                }
            }
            TipGroup {
                title: "Scenario"
                blurb: "What the mock believes: the same raw states the data layer folds."
            }
            TipRow {
                tip: "The mock's scenario. Changing it rebuilds the state; a panel that shows a fact the scenario lacks says so plainly."
                Layout.fillWidth: true
                Flow {
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: ["home", "crowd", "airplane", "hotspot", "vpn", "portal", "pairing", "earbuds", "nowifi", "errors"]
                        delegate: Button {
                            required property string modelData
                            text: modelData
                            onClicked: demo.scenario = modelData
                        }
                    }
                }
            }
            TipGroup {
                title: "State"
                blurb: "What the stage shows now."
            }
            Label {
                Layout.fillWidth: true
                text: "kind: " + demo.sec.shownKind + "  target: " + demo.sec.shownTarget + "\nscenario: " + demo.scenario + "   size: " + demo.implicitWidth.toFixed(0) + " x " + demo.implicitHeight.toFixed(0)
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
                wrapMode: Text.WordWrap
            }
        }
    ]

    readonly property var panelParams: [
        { label: "width", prop: "panelWidth", group: "Size", blurb: "The panel's box.", tip: "Width of every aerial panel. 360 carries the facts table of a network (a name column and a value column) without wrapping; silicon's dialogs are 300 because they hold a sentence.", val: 360, from: 280, to: 520, step: 4 },
        { label: "tallest", prop: "maxHeight", group: "Size", tip: "The tallest a panel grows before its page scrolls (with the shell's fades). The popup's own room is the real limit; 560 leaves the Wi-Fi pages whole on a 1080p screen.", val: 560, from: 300, to: 1000, step: 10 },
        { label: "padding", prop: "padding", group: "Spacing", blurb: "CLAUDE.md layout numbers: 12 on every side.", tip: "Space between the panel's edge and its head, tabs and cards, and between the tab row and the first card. 12 is the shell's popup padding; the space above equals the space below.", val: 12, from: 6, to: 24, step: 1 },
        { label: "card gap", prop: "gap", group: "Spacing", tip: "Space between cards of a page. 12, the one gap of the shell.", val: 12, from: 6, to: 24, step: 1 },
        { label: "row gap", prop: "rowGap", group: "Spacing", tip: "Space between blocks inside a card (a fact, a field, a button row). 8 keeps a card of eleven facts under a screen's height.", val: 8, from: 2, to: 16, step: 1 }
    ]

    readonly property var mockParams: [
        { label: "live", prop: "live", group: "Mock", blurb: "The simulated machine.", tip: "On: the mock answers intents after `settleMs` (a connect settles, a refused password is refused). Off: the facts stand still and a click changes nothing. On by default so the panels can be worked.", val: true },
        { label: "settle ms", prop: "settleMs", group: "Mock", tip: "How long a simulated intent takes before its result lands. 700 ms shows the in-between state (Connecting) long enough to read.", val: 700, from: 0, to: 3000, step: 50 },
        { label: "traffic Mbit/s", prop: "trafficMbps", group: "Mock", tip: "The rate the carrying link shows; it feeds the usage counter, so the Usage panel's today figure grows with it.", val: 25, from: 0, to: 500, step: 5 }
    ]
}
