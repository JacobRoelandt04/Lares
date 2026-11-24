pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"

// =============================================================================
// UpdateNudgeBody.qml -- the facts of the post-boot nudge, as the card's rich body.
//
//   chips        [{ key, label, count }]   the updates per category, in the list's order
//   highlights   [{ name, oldVer, newVer }] the packages the user FAVOURITED, with the move they make
//   hostCard     handed in by the card (its font)
//
// Each category is a dot in yay's own colour for its repo (core orange, extra green, multilib cyan, aur
// blue, flatpak magenta -- Theme.cat*, the same marks the update popup's headers carry) and its count; the
// highlights are the names, bold, with "old -> new" beside them in the muted colour. Drop-in rules: sized
// by its own implicitHeight, a width it is given (the card's text column), no assumption about the host
// beyond `hostCard`'s optional font; nothing animates. The highlights are StyledText with the two theme
// colours resolved HERE (a repeater's model carries facts, never a colour): a theme switch re-colours the
// text, and the model is not touched.
// =============================================================================
Item {
    id: root

    property var chips: []
    property var highlights: []
    property var hostCard: null

    readonly property string fontFamily: root.hostCard && root.hostCard.fontFamily ? root.hostCard.fontFamily : "Inter"
    readonly property int textSize: root.hostCard && root.hostCard._bodySize ? root.hostCard._bodySize : 12
    readonly property int metaSize: root.hostCard && root.hostCard._metaSize ? root.hostCard._metaSize : 11

    implicitHeight: Math.ceil(col.implicitHeight)

    function esc(t) {
        return String(t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }
    function colorOf(key) {
        switch (key) {
        case "core": return Theme.catCore;
        case "extra": return Theme.catExtra;
        case "multilib": return Theme.catMultilib;
        case "aur": return Theme.catAur;
        case "flatpak": return Theme.catFlatpak;
        }
        return Theme.textFaint;
    }

    Column {
        id: col
        width: root.width
        spacing: 4

        Flow {
            width: col.width
            spacing: 10
            visible: root.chips.length > 0

            Repeater {
                model: root.chips
                delegate: Row {
                    id: chip
                    required property var modelData
                    spacing: 4
                    Rectangle {
                        width: 8
                        height: 8
                        radius: 4
                        anchors.verticalCenter: parent.verticalCenter
                        color: root.colorOf(chip.modelData.key)
                    }
                    Text {
                        text: chip.modelData.count + " " + chip.modelData.label
                        textFormat: Text.PlainText
                        color: Theme.textMuted
                        font.family: root.fontFamily
                        font.pixelSize: root.metaSize
                    }
                }
            }
        }

        Repeater {
            model: root.highlights
            delegate: Text {
                id: hl
                required property var modelData
                width: col.width
                textFormat: Text.StyledText
                elide: Text.ElideRight
                maximumLineCount: 1
                color: Theme.textMuted
                font.family: root.fontFamily
                font.pixelSize: root.textSize
                text: "<font color=\"" + Theme.textPrimary + "\">" + root.esc(hl.modelData.name) + "</font>"
                      + (hl.modelData.newVer !== "" ? "   " + root.esc(hl.modelData.oldVer) + " → " + root.esc(hl.modelData.newVer) : "")
            }
        }
    }
}
