pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/components/Mix.js" as Mix

// =============================================================================
// NotesHeader.qml -- the row above the grid.
//
//   back chevron   top-left, whenever there is somewhere to go back to (a
//                  group, a search); its presence is `backF`, one fraction the
//                  title slides on, so it moves rather than jumps
//   title          "Notes" at the root; a group's name (click it to rename --
//                  the folder is renamed); the search as it is typed
//   sort           right: the mode, a click opens the menu (SortControl)
//
// The editor has its own chevron beside the note's title (NotesPopup).
//
// Nothing here is a button until the pointer says so: a short fade to the
// accent and the hand cursor.
// =============================================================================
Item {
    id: header

    property var store: null
    property string fontFamily: "Inter"
    // The popup's overlay: the sort menu floats in it.
    property Item overlayItem: null
    // The folder this row names -- the popup's, which during a transition is
    // the one being arrived at, not yet the store's.
    property string folderKey: header.store ? header.store.folder : ""
    // 0..1: how much of the chevron's room the title leaves free.
    property real backF: 0
    readonly property bool searching: header.store ? header.store.query !== "" : false
    readonly property var groupEntry: header.store && header.store.service.serial >= 0 && header.folderKey !== "" ? header.store.entryOf(header.folderKey) : null

    signal backClicked
    signal renameGroup(string text)

    implicitHeight: 32

    component Hoverable: Item {
        id: h
        property real hf: ha.containsMouse ? 1 : 0
        Behavior on hf {
            NumberAnimation {
                duration: 120
                easing.type: Easing.OutCubic
            }
        }
        signal clicked(real x, real y)
        MouseArea {
            id: ha
            anchors.fill: parent
            anchors.margins: -4
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: m => h.clicked(m.x, m.y)
        }
    }

    Hoverable {
        id: backBtn
        objectName: "headerBack"
        visible: header.backF > 0.01
        opacity: header.backF
        // Slides in WITH the title, 8 px ahead of it, rather than fading in
        // where the title still is: -12 at rest, 12 when fully there.
        x: Math.round(24 * header.backF) - 12
        width: 16
        height: parent.height
        onClicked: header.backClicked()
        Chevron {
            x: Math.round((parent.width - width) / 2)
            y: Math.round((parent.height - height) / 2)
            size: 12
            thickness: 2
            rotation: 90
            color: Mix.c(Theme.textMuted, Theme.accent, backBtn.hf)
        }
    }

    // The title slot.
    Item {
        id: titleSlot
        // 12, or 36 with the chevron (12 + its 16 + a gap of 8): whole pixels.
        x: 12 + Math.round(24 * header.backF)
        width: sortBtn.x - x - 12
        height: parent.height

        Text {
            id: plainTitle
            visible: !groupName.visible && !header.searching
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            elide: Text.ElideRight
            text: "Notes"
            font.family: header.fontFamily
            font.pixelSize: 16
            font.bold: true
            color: Theme.textPrimary
        }
        Row {
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
                anchors.verticalCenter: parent.verticalCenter
                text: header.store ? header.store.query : ""
                font.family: header.fontFamily
                font.pixelSize: 16
                font.bold: true
                color: Theme.textPrimary
            }
        }
        TextInput {
            id: groupName
            Keys.forwardTo: [groupNameKeys]
            EditKeys {
                id: groupNameKeys
                target: groupName
                selectAll: true
            }
            visible: header.groupEntry !== null && !header.searching
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            text: header.groupEntry ? header.groupEntry.title : ""
            font.family: header.fontFamily
            font.pixelSize: 16
            font.bold: true
            color: Theme.textPrimary
            selectionColor: Mix.c(Theme.surface, Theme.accent, 0.3)
            selectedTextColor: Theme.textPrimary
            selectByMouse: true
            clip: true
            onAccepted: {
                header.renameGroup(groupName.text);
                groupName.focus = false;
            }
            onActiveFocusChanged: {
                if (!activeFocus && header.groupEntry && groupName.text !== header.groupEntry.title)
                    header.renameGroup(groupName.text);
            }
            Keys.onEscapePressed: {
                groupName.text = header.groupEntry ? header.groupEntry.title : "";
                groupName.focus = false;
            }
            HoverHandler {
                cursorShape: Qt.IBeamCursor
            }
        }
    }

    SortControl {
        id: sortBtn
        visible: !header.searching
        x: header.width - 12 - width
        width: implicitWidth
        height: parent.height
        overlayItem: header.overlayItem
        fontFamily: header.fontFamily
        // A custom order has no direction.
        modes: [
            {
                id: "name",
                label: "Name",
                directional: true
            },
            {
                id: "modified",
                label: "Modified",
                directional: true
            },
            {
                id: "created",
                label: "Created",
                directional: true
            },
            {
                id: "size",
                label: "Size",
                directional: true
            },
            {
                id: "custom",
                label: "Custom",
                caption: "Custom order",
                directional: false
            }
        ]
        mode: header.store ? header.store.service.sortMode : ""
        ascending: header.store ? header.store.service.sortAscending : true
        onSortRequested: (mode, ascending) => header.store.service.setSort(mode, ascending)
    }
}
