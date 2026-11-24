pragma ComponentBehavior: Bound

import QtQuick

import "PanelWords.js" as Words

// =============================================================================
// UsagePanel.qml -- the usage display's panel: how much data went through each network today and this month (the shell's own
// counter: nothing was counted before the shell ran), and the last 30 days as a chart drawn to scale.
//
//   vm   an AerialService or an AerialMock (fact `usage`)
// =============================================================================
PanelFrame {
    id: panel

    property var vm: null

    signal dismissed()

    readonly property var usage: panel.vm ? panel.vm.usage : null
    readonly property bool wantsKeys: false
    readonly property var nets: {
        const l = panel.usage ? panel.usage.byNetwork.slice() : [];
        l.sort((a, b) => (b.month + b.today) - (a.month + a.today));
        return l.filter(n => n.today > 0 || n.month > 0);
    }

    title: "Data used"
    subtitle: panel.usage ? Words.bytes(panel.usage.todayBytes) + " today · " + Words.bytes(panel.usage.monthBytes) + " this month" : "Nothing counted yet"


    PanelPage {
        look: panel.look
        pageId: "usage"
        shown: true

        PanelCard {
            look: panel.look
            PText { look: panel.look; text: "Last 30 days" }
            BarChart {
                objectName: "usageChart"
                look: panel.look
                width: parent.width
                days: panel.usage ? panel.usage.days : []
            }
        }
        PanelCard {
            look: panel.look
            PText {
                look: panel.look
                tone: 1
                width: parent.width
                wrapMode: Text.WordWrap
                shown: panel.nets.length === 0
                text: "No network has carried data since the shell began counting"
            }
            Item {
                width: parent.width
                height: panel.nets.length > 0 ? 16 : 0
                visible: panel.nets.length > 0
                PText { look: panel.look; tone: 1; small: true; text: "Network" }
                PText { look: panel.look; tone: 1; small: true; x: parent.width - 150; width: 70; horizontalAlignment: Text.AlignRight; text: "Today" }
                PText { look: panel.look; tone: 1; small: true; x: parent.width - 70; width: 70; horizontalAlignment: Text.AlignRight; text: "This month" }
            }
            Repeater {
                model: panel.nets.length
                delegate: Item {
                    id: nrow
                    required property int index
                    readonly property var n: panel.nets[nrow.index] || ({ label: "", today: 0, month: 0 })
                    width: parent.width
                    height: 20
                    PText { look: panel.look; width: parent.width - 160; elide: Text.ElideRight; text: nrow.n.label }
                    PText { look: panel.look; x: parent.width - 150; width: 70; horizontalAlignment: Text.AlignRight; text: Words.bytes(nrow.n.today) }
                    PText { look: panel.look; x: parent.width - 70; width: 70; horizontalAlignment: Text.AlignRight; text: Words.bytes(nrow.n.month) }
                }
            }
        }
    }
}
