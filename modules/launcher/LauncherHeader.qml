pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/components/Mix.js" as Mix

// =============================================================================
// LauncherHeader.qml -- the row above the launcher's list.
//
//   back chevron   top-left while a folder is open; its presence is `backF`,
//                  the one fraction the title slides on (notes' header)
//   title          "Applications" at the root; the folder's name inside one
//                  (click it to rename the folder, or the folder menu's
//                  Rename puts the caret there); while a query is typed,
//                  the query itself after a search glyph -- there is no
//                  search field, so this is where typing shows.
//                  The swap is instant: text swaps, presence fades.
//   sort           right: SortControl, notes' sort label and menu, which also
//                  carries the layout toggle and the hidden apps
// =============================================================================
Item {
    id: header

    property var service: null
    property Item overlayItem: null
    property string fontFamily: "Inter"
    // The folder this row names -- during a morph the one being arrived at.
    property string folderKey: header.service ? header.service.folder : ""
    property real backF: 0
    readonly property bool searching: !!header.service && header.service.query !== ""
    readonly property var folderEntry: header.service && header.service.serial >= 0 && header.folderKey !== "" ? header.service.entry(header.folderKey) : null
    // The folder's name is shown BOUND to its entry only while nobody is
    // editing it: the entry is re-read on every service.serial, so a live
    // `text:` binding would put the old name back over what is being typed the
    // moment anything else rebuilds the list (a favourite toggled elsewhere).
    // A typed name that was committed is held until the rename has answered
    // (`renameAnswered`): bound again at once it would read the old name for the
    // length of the move, then the new one.
    property bool _editing: false
    property bool _renaming: false
    readonly property alias sortControl: sort

    signal backClicked
    signal renameFolder(string text)
    // The folder's name gave the keyboard up (Return, Escape, a click
    // elsewhere): the host hands it back to the list.
    signal editEnded
    signal hiddenViewToggled

    // The host's tune.headerHeight sets it; 32 is that default.
    implicitHeight: 32

    // The host's rename has finished, done or refused: the name follows the
    // folder's entry again.
    function renameAnswered() {
        header._renaming = false;
    }

    // The caret in the folder's name, all of it selected backwards (its start
    // in view, as the row rename selects).
    function focusFolderName() {
        if (!folderName.visible)
            return;
        folderName.forceActiveFocus();
        folderName.select(folderName.text.length, 0);
    }

    Item {
        id: backBtn
        objectName: "headerBack"
        property real hf: backArea.containsMouse ? 1 : 0
        Behavior on hf {
            NumberAnimation {
                duration: 120
                easing.type: Easing.OutCubic
            }
        }
        visible: header.backF > 0.01
        opacity: header.backF
        // Slides in with the title, 8 px ahead of it (notes' header).
        x: Math.round(24 * header.backF) - 12
        width: 16
        height: parent.height
        Chevron {
            x: Math.round((parent.width - width) / 2)
            y: Math.round((parent.height - height) / 2)
            size: 12
            thickness: 2
            rotation: 90
            color: Mix.c(Theme.textMuted, Theme.accent, backBtn.hf)
        }
        MouseArea {
            id: backArea
            anchors.fill: parent
            anchors.margins: -4
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: header.backClicked()
        }
    }

    Item {
        id: titleSlot
        x: 12 + Math.round(24 * header.backF)
        width: Math.max(0, sort.x - x - 12)
        height: parent.height

        Text {
            id: plainTitle
            objectName: "headerTitle"
            visible: !folderName.visible && !header.searching
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            elide: Text.ElideRight
            text: header.service && header.service.hiddenView ? "Hidden apps" : "Applications"
            font.family: header.fontFamily
            font.pixelSize: 16
            font.bold: true
            color: Theme.textPrimary
        }
        Row {
            objectName: "headerQuery"
            visible: header.searching
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "\uF002"
                font.family: "Symbols Nerd Font"
                font.pixelSize: 12
                color: Theme.textFaint
            }
            Text {
                id: queryText
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, titleSlot.width - 18)
                elide: Text.ElideLeft
                text: header.service ? header.service.query : ""
                font.family: header.fontFamily
                font.pixelSize: 16
                font.bold: true
                color: Theme.textPrimary
            }
        }
        TextInput {
            id: folderName
            Keys.forwardTo: [folderNameKeys]
            EditKeys {
                id: folderNameKeys
                target: folderName
                selectAll: true
            }
            objectName: "headerFolderName"
            visible: header.folderEntry !== null && !header.searching
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            font.family: header.fontFamily
            font.pixelSize: 16
            font.bold: true
            color: Theme.textPrimary
            selectionColor: Mix.c(Theme.surface, Theme.accent, 0.3)
            selectedTextColor: Theme.textPrimary
            selectByMouse: true
            clip: true
            // One commit: when the name loses the keyboard, however it does
            // (Return drops it here; Escape puts the name back first).
            onAccepted: folderName.focus = false
            onActiveFocusChanged: {
                if (activeFocus) {
                    header._editing = true;
                    return;
                }
                if (header._editing && header.folderEntry && folderName.text !== header.folderEntry.name) {
                    header._renaming = true;
                    header.renameFolder(folderName.text);
                }
                header._editing = false;
                header.editEnded();
            }
            Keys.onEscapePressed: {
                // The edit ends first, so the folder's own name is back (the
                // Binding) before the focus goes and nothing is committed.
                header._editing = false;
                folderName.focus = false;
            }
            HoverHandler {
                cursorShape: Qt.IBeamCursor
            }
        }
        // A Binding, not a `text:` binding, so it can be let go while the name
        // is edited: a `text:` binding stays live under the typing and
        // re-evaluates over it. RestoreNone: let go, it leaves the name where
        // it is (Qt 6's default restores the value from before the Binding --
        // an empty or a stale name -- and the caret landed in that).
        Binding {
            target: folderName
            property: "text"
            value: header.folderEntry ? header.folderEntry.name : ""
            when: !header._editing && !header._renaming
            restoreMode: Binding.RestoreNone
        }
    }

    SortControl {
        id: sort
        objectName: "sortControl"
        visible: !header.searching
        x: header.width - 12 - width
        anchors.verticalCenter: parent.verticalCenter
        overlayItem: header.overlayItem
        fontFamily: header.fontFamily
        modes: [
            {
                id: "default",
                label: "Default",
                directional: false
            },
            {
                id: "name",
                label: "Name",
                directional: true
            },
            {
                id: "recent",
                label: "Recent",
                directional: false
            }
        ]
        mode: header.service ? header.service.sortMode : "default"
        ascending: header.service ? header.service.sortAscending : true
        extraRows: [
            {
                id: "columns",
                label: "Columns",
                checked: !!header.service && header.service.layout === "columns"
            },
            {
                id: "hidden",
                label: "Hidden apps",
                checked: !!header.service && header.service.hiddenView
            }
        ]
        onSortRequested: (mode, asc) => header.service.setSort(mode, asc)
        onExtraTriggered: id => {
            if (id === "columns")
                header.service.setLayout(header.service.layout === "columns" ? "list" : "columns");
            else if (id === "hidden")
                header.hiddenViewToggled();
        }
    }
}
