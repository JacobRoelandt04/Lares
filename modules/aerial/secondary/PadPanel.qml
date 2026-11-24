pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/components/RelTime.js" as Rel
import "PanelWords.js" as Words

// =============================================================================
// PadPanel.qml -- one test pad (LINK, ADDR, GATEWAY, DNS, NET): what the stage means in plain words, its result and detail, Re-test,
// and the fix. A login page in the way (`health.portal.present`) is the one fix with a button: "Open the login page" -> `openPortal()`.
//
//   vm         an AerialService or an AerialMock
//   targetKey  the pad's id ("link" | "addr" | "gateway" | "dns" | "net")
// =============================================================================
PanelFrame {
    id: panel

    property var vm: null
    property string targetKey: "net"

    signal dismissed()

    readonly property var pad: {
        const l = panel.vm ? panel.vm.health.pads : [];
        for (let i = 0; i < l.length; i++)
            if (l[i].id === panel.targetKey)
                return l[i];
        return null;
    }
    readonly property string state: panel.pad ? panel.pad.state : "unknown"
    readonly property var words: Words.pad(panel.targetKey)
    readonly property bool portal: !!panel.vm && panel.vm.health.portal.present === true
    readonly property bool wantsKeys: false

    title: panel.words.title
    subtitle: panel.state === "ok" ? "Working" : panel.state === "warn" ? "Needs attention" : panel.state === "fail" ? "Not working"
        : panel.state === "testing" ? "Testing" : "Not looked at yet"
    subtitleTone: panel.state === "ok" ? 5 : panel.state === "warn" ? 3 : panel.state === "fail" ? 4 : 1


    BoundaryClock { id: clock }
    readonly property var rel: panel.pad && panel.pad.atMs > 0 ? Rel.format(panel.pad.atMs, clock.now, { justNow: "just now", suffix: " ago" }) : null
    onRelChanged: if (panel.rel) clock.request(panel.rel.nextMs)

    PanelPage {
        look: panel.look
        pageId: "pad"
        shown: true

        PanelCard {
            look: panel.look
            PText {
                look: panel.look
                tone: 1
                width: parent.width
                wrapMode: Text.WordWrap
                text: panel.words.means
            }
            PText {
                look: panel.look
                tone: panel.state === "ok" ? 5 : panel.state === "warn" ? 3 : panel.state === "fail" ? 4 : 0
                width: parent.width
                wrapMode: Text.WordWrap
                text: panel.state === "testing" ? "Testing now." : Words.padState(panel.targetKey, panel.state)
            }
            FactRow { look: panel.look; label: "Detail"; value: panel.pad ? panel.pad.detail : "" }
            FactRow { look: panel.look; label: "Took"; value: panel.pad && panel.pad.ms > 0 ? panel.pad.ms + " ms" : "" }
            FactRow { look: panel.look; label: "Tested"; value: panel.rel ? panel.rel.text : "" }
            ButtonRow {
                PanelButton {
                    objectName: "padRetest"
                    look: panel.look
                    text: "Test again"
                    enabled: panel.state !== "testing"
                    visible: panel.targetKey !== "link" && panel.targetKey !== "addr"
                    onClicked: if (panel.vm) panel.vm.testPad(panel.targetKey)
                }
                PanelButton {
                    objectName: "padPortal"
                    look: panel.look
                    accent: true
                    text: "Open the login page"
                    visible: panel.targetKey === "net" && panel.portal
                    onClicked: if (panel.vm) panel.vm.openPortal()
                }
            }
        }
        PanelCard {
            look: panel.look
            visible: panel.targetKey === "net" && panel.portal
            PText {
                look: panel.look
                tone: 3
                width: parent.width
                wrapMode: Text.WordWrap
                text: "This network asks you to log in before the internet works. Open the login page, finish it, and the test passes by itself."
            }
        }
    }
}
