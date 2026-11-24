pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// =============================================================================
// MockupTabPage -- one tab of the control panel.
//
// A card that scrolls on its own, headed by the tab's name, how many of its
// values differ from the file defaults, and a Reset that puts every one of
// them back. Under the header, in this order:
//   - the sub-tab strip, when the tabDef has `subs`;
//   - a ParamList or ColorList for every list of the tab (or of the
//     current sub-tab -- every sub-tab is kept alive and shown by turns);
//   - the tabDef's `page`, a MockupPage the mockup declared itself.
//
// tabDef: { name, lists: [listId], subs: [{name, lists, groups}], page }
// =============================================================================
Item {
    id: page

    property var def: ({})
    property MockupRegistry registry: null
    // Current sub-tab; the initial value comes from PANEL_SUBTAB.
    property int sub: 0

    readonly property string name: (page.def && page.def.name) ? page.def.name : ""
    readonly property var subs: (page.def && page.def.subs) ? page.def.subs : []
    // What the list area shows: one section per sub-tab, or the tab's own
    // lists as a single section.
    readonly property var sections: page.subs.length > 0 ? page.subs : [{ lists: (page.def && page.def.lists) ? page.def.lists : [], groups: null }]
    readonly property int subIndex: Math.max(0, Math.min(page.sections.length - 1, page.sub))
    readonly property var lists: page.registry ? page.registry.tabLists(page.def) : []
    readonly property int modified: page.registry ? page.registry.modifiedCount(page.registry.defaultsRev, page.lists, null) : 0

    Layout.fillWidth: true
    Layout.fillHeight: true

    // ---- THE VALUE SLOT ----------------------------------------------------
    // One width per section (what is shown at once), so every slider in it
    // ends on one line: the widest figure its slider rows can show, and never
    // under 56 px -- the framework's slot, four digits, which is what every
    // panel with no longer figures keeps. A fixed slot for six digits took
    // ~30 px from every slider of all fourteen mockups to fit one Config tab
    // (R2E refix). A figure is its row's text of `from` and `to` with every
    // digit the font's widest: Audiowide has no tabular figures, so 288000
    // can be wider than 300000.
    readonly property real minSlot: 56
    FontMetrics {
        id: slotFont
        font.family: "Audiowide"
        font.pixelSize: 14
    }
    function slotFor(sec) {
        // The read of the family is the dependency a FontMetrics method call
        // lacks: without it the slot keeps its first measure, taken before the
        // family applied.
        if (!page.registry || !sec || slotFont.font.family === "")
            return page.minSlot;
        let wide = "0";
        for (let d = 1; d <= 9; d++)
            if (slotFont.advanceWidth(String(d)) > slotFont.advanceWidth(wide))
                wide = String(d);
        let w = page.minSlot;
        for (const id of (sec.lists || [])) {
            if (page.registry.isColorList(id))
                continue;
            for (const e of page.registry.entries(id)) {
                if ((sec.groups && sec.groups.indexOf(e.group) < 0) || !page.registry.isSliderEntry(e))
                    continue;
                for (const v of [e.from, e.to])
                    w = Math.max(w, Math.ceil(slotFont.advanceWidth(page.registry.figureText(e, v).replace(/[0-9]/g, wide))));
            }
        }
        return w;
    }

    // The mockup's own page is declared without a visual parent (in
    // MockupWindow.pages); it is parented under the header here, after the
    // lists, because the Repeater's rows are inserted at the Repeater's
    // own position and this appends.
    function attachPage() {
        const p = page.def ? page.def.page : null;
        if (p)
            p.parent = pageCol;
    }
    Component.onCompleted: page.attachPage()
    onDefChanged: page.attachPage()

    Flickable {
        id: pageFlick
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: pageBox.height
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar {
            policy: ScrollBar.AsNeeded
        }

        Rectangle {
            id: pageBox
            width: pageFlick.width
            height: pageCol.implicitHeight + 24
            color: "#EAEDF5"
            radius: 16
            border.color: "#CED1D7"
            border.width: 1

            ColumnLayout {
                id: pageCol
                anchors.fill: parent
                anchors.margins: 12
                spacing: 10

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Label {
                        text: page.name
                        color: "#5D5D5F"
                        font.family: "Audiowide"
                        font.pixelSize: 17
                        font.bold: true
                    }
                    Label {
                        text: page.modified > 0 ? page.modified + " modified" : ""
                        color: "#4480F4"
                        font.family: "Audiowide"
                        font.pixelSize: 13
                    }
                    Item {
                        Layout.fillWidth: true
                    }
                    Button {
                        text: "Reset tab"
                        visible: page.lists.length > 0
                        enabled: page.modified > 0
                        font.pixelSize: 13
                        padding: 5
                        onClicked: if (page.registry)
                            page.registry.applyDefaults(page.lists)
                    }
                }

                // Sub-tab strip. A sub-tab is marked when any of its lists,
                // narrowed to its groups, holds a modified value.
                Flow {
                    Layout.fillWidth: true
                    visible: page.subs.length > 0
                    spacing: 6
                    Repeater {
                        model: page.subs
                        delegate: MockupTabPill {
                            required property var modelData
                            required property int index
                            small: true
                            text: modelData.name || ""
                            current: page.subIndex === index
                            marked: page.registry ? page.registry.modifiedCount(page.registry.defaultsRev, modelData.lists || [], modelData.groups || null) > 0 : false
                            onClicked: page.sub = index
                        }
                    }
                }

                Repeater {
                    model: page.sections
                    delegate: ColumnLayout {
                        id: section
                        required property var modelData
                        required property int index
                        objectName: "paramSection"
                        readonly property real slotWidth: page.slotFor(section.modelData)
                        visible: index === page.subIndex
                        Layout.fillWidth: true
                        spacing: 8

                        Repeater {
                            model: section.modelData.lists || []
                            delegate: ColumnLayout {
                                id: listCol
                                required property string modelData
                                readonly property bool isColor: page.registry ? page.registry.isColorList(listCol.modelData) : false
                                Layout.fillWidth: true
                                spacing: 8

                                // One of the two gets the list; the other an
                                // empty id and so no rows.
                                ParamList {
                                    registry: page.registry
                                    listId: listCol.isColor ? "" : listCol.modelData
                                    groups: section.modelData.groups || null
                                    slotWidth: section.slotWidth
                                }
                                ColorList {
                                    registry: page.registry
                                    listId: listCol.isColor ? listCol.modelData : ""
                                    groups: section.modelData.groups || null
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
