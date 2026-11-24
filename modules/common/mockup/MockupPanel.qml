pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// =============================================================================
// MockupPanel -- the control panel: tab strip, status line, one page per tab.
//
// The strip shows a * on any tab holding a value that differs from the
// file defaults; the status line counts them and carries "Save to mockup".
// Pills rather than a TabBar: nine tabs do not fit 440px, and a Flow wraps
// onto a second row instead of squeezing or scrolling.
// =============================================================================
ColumnLayout {
    id: panel

    property MockupRegistry registry: null
    property MockupStore store: null
    // [{name, lists, subs, page}] -- MockupWindow.allTabs.
    property var tabs: []
    property int tabIndex: 0
    // The tab whose sub-tab PANEL_SUBTAB selects.
    property int initialTab: 0
    property int initialSub: 0
    // A strip drawn under the tab pages on EVERY tab (the mockup's `footer`):
    // the pages scroll in the space above it. Null (the default) adds nothing
    // -- no item, no gap -- so a panel without one is what it always was.
    property Component footer: null

    readonly property int modifiedTotal: panel.registry ? panel.registry.modifiedCount(panel.registry.defaultsRev, panel.registry.listIds, null) : 0
    // What Save to mockup would write: the modified values of the lists that
    // are the mockup's own (not a themed list, not a file-backed one).
    readonly property int saveableTotal: panel.registry ? panel.registry.modifiedCount(panel.registry.defaultsRev, panel.registry.savedIds(), null) : 0

    spacing: 8

    Flow {
        Layout.fillWidth: true
        spacing: 6
        Repeater {
            model: panel.tabs
            delegate: MockupTabPill {
                required property var modelData
                required property int index
                text: modelData.name || ""
                current: panel.tabIndex === index
                marked: panel.registry ? panel.registry.modifiedCount(panel.registry.defaultsRev, panel.registry.tabLists(modelData), null) > 0 : false
                onClicked: panel.tabIndex = index
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        Label {
            text: panel.modifiedTotal === 0 ? "every value is at its file default"
                : panel.modifiedTotal + " value" + (panel.modifiedTotal === 1 ? "" : "s") + " differ from the file defaults (*)"
                  + (panel.saveableTotal < panel.modifiedTotal ? ", " + (panel.modifiedTotal - panel.saveableTotal) + " kept in the module's own file" : "")
            color: panel.modifiedTotal === 0 ? "#8A8A8C" : "#4480F4"
            font.family: "Audiowide"
            font.pixelSize: 13
            elide: Text.ElideRight
            Layout.fillWidth: true
        }
        TipRow {
            tip: panel.store && !panel.store.mockupFileFound
                 ? "There is no file at " + panel.store.mockupFile + ", so there is nothing to save into. A mockup whose file is not mockups/<moduleId>.qml has to say where it lives: `mockupFile: RepoRoot.dir + \"/mockups/<name>.qml\"` beside its moduleId."
                 : "Writes every * value into the REAL implementation and into the mockup. The module: for each row the place the module ships that default (its own declaration, or -- for a component other modules share -- this module's use of it; a row's tip says where), refusing what would break (a binding default, a sentinel, a colour literal over a theme token); the files written are committed (tools/shell/lares apply --commit) and a running shell restarts on them. The mockup: the val: entries of " + (panel.store ? panel.store.mockupFile : "") + ", so the marks clear and the tweak is the default the next time it opens (tools/dev/mockup_save_defaults.py). Not here: a themed list (it writes themes/<name>.json itself and never counts as modified) and a file-backed list (its own file keeps it)." + (panel.store && panel.store.moduleBlock !== "" ? " The module is NOT written from here: " + panel.store.moduleBlock + "." : "")
            Layout.fillWidth: false
            Button {
                text: panel.store && panel.store.saving ? "Saving…" : "Save to mockup"
                // A save with no file to write is refused rather than
                // attempted: it used to fail into a status line on another
                // tab, which reads as the button doing nothing.
                enabled: panel.store && !panel.store.saving && panel.saveableTotal > 0 && panel.store.mockupFileFound
                font.pixelSize: 13
                padding: 5
                onClicked: panel.store.saveToMockup()
            }
        }
        Label {
            // The one place a save's own words are visible next to the thing
            // that made them. Silent while it says nothing interesting.
            visible: panel.store && (!panel.store.mockupFileFound || panel.store.saveStatus.indexOf("failed") >= 0)
            text: panel.store && !panel.store.mockupFileFound ? "no file at " + panel.store.mockupFile : "save failed -- see the Profiles tab"
            color: "#EC0000"
            font.family: "Audiowide"
            font.pixelSize: 12
            elide: Text.ElideRight
            Layout.maximumWidth: 320
        }
    }

    // What the last Save did to the module, in a line (the whole report is on hover and on the Profiles tab).
    TipRow {
        visible: !!panel.store && panel.store.saveSummary.length > 0
        tipMaxWidth: 520
        tip: panel.store ? panel.store.saveStatus : ""
        Label {
            Layout.fillWidth: true
            text: panel.store ? panel.store.saveSummary : ""
            color: panel.store && panel.store.saveSummaryBad ? "#EC0000" : "#5D5D5F"
            font.family: "Audiowide"
            font.pixelSize: 12
            elide: Text.ElideRight
        }
    }

    Item {
        Layout.fillWidth: true
        Layout.fillHeight: true
        Repeater {
            model: panel.tabs
            delegate: MockupTabPage {
                required property var modelData
                required property int index
                anchors.fill: parent
                visible: index === panel.tabIndex
                def: modelData
                registry: panel.registry
                sub: index === panel.initialTab ? panel.initialSub : 0
            }
        }
    }

    Loader {
        id: footerSlot
        Layout.fillWidth: true
        active: panel.footer !== null
        visible: panel.footer !== null
        sourceComponent: panel.footer
    }
}
