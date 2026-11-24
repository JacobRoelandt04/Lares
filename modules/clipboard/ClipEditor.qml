pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls

import "../common/theme"
import "../common/components"

// =============================================================================
// ClipEditor.qml -- the text of one entry, edited before it is pasted.
//
// A carved text area in the shelf's rectangle (the popup lays it over the
// shelf and gives it the shelf's height: a reserved slot keeps its height).
// Ctrl+Enter hands the edited text to the host to paste (`pasteRequested`),
// Escape hands it over to be KEPT without pasting (`saved`), Ctrl+Escape throws
// the edit away (`cancelled`); nothing else leaves
// the editor. The service stores what was pasted or saved as a new entry
// (`via: "edit"`), the original stays as it was.
//
//   saveNow()   what Escape does, for a host that hears the key elsewhere (the shell's
//               Escape bind): `saved(text)` with the text as it stands
//
//   begin(text, code)   fill it and take the keyboard; `code` picks the face
//                       (Consolas Bold for code, the module's font otherwise)
//   active              presence: fades in/out (160 ms), takes no input and
//                       draws nothing while false
//
// `padding` on a Controls TextArea does NOT zero its left padding (Basic and
// Fusion bind `leftPadding: padding + 4`), so every side is set explicitly and
// the caret starts exactly one padding in.
// =============================================================================
Item {
    id: root

    property bool active: false
    property string fontFamily: "Inter"
    property bool code: false
    property color surfaceColor: Theme.surface
    property real radius: 14
    property real padding: 12
    property int fadeMs: 160
    readonly property alias area: editArea

    signal pasteRequested(string text)
    signal saved(string text)
    signal cancelled

    opacity: root.active ? 1 : 0
    visible: opacity > 0
    enabled: root.active
    Behavior on opacity {
        NumberAnimation {
            duration: root.fadeMs
            easing.type: Easing.OutCubic
        }
    }

    function saveNow() {
        root.saved(editArea.text);
    }

    function begin(text, isCode) {
        root.code = isCode === true;
        editArea.text = text;
        editArea.cursorPosition = editArea.length;
        editArea.forceActiveFocus();
    }

    ShadowBox {
        anchors.fill: parent
        baseRadius: root.radius
        surfaceColor: root.surfaceColor
        backgroundColor: Theme.panelSunk
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        bevelWidth: 1
        shadowWidth: 3
    }

    // The foot line: the two keys, in the faint colour, once.
    Text {
        id: hint
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: root.padding
        anchors.bottomMargin: 8
        text: "Ctrl+Enter pastes   Esc saves   Ctrl+Esc cancels"
        font.family: root.fontFamily
        font.pixelSize: 11
        color: Theme.textFaint
    }

    Flickable {
        id: editFlick
        x: root.padding
        y: root.padding
        width: root.width - 2 * root.padding
        height: root.height - 2 * root.padding - hint.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        contentWidth: width
        contentHeight: editArea.implicitHeight

        TextArea.flickable: TextArea {
            id: editArea
            Keys.forwardTo: [editAreaKeys]
            EditKeys {
                id: editAreaKeys
                target: editArea
                selectAll: true
            }
            objectName: "clipEditorArea"
            leftPadding: 0
            rightPadding: 0
            topPadding: 0
            bottomPadding: 0
            background: null
            wrapMode: TextEdit.Wrap
            selectByMouse: true
            color: Theme.textPrimary
            selectionColor: Theme.accent
            selectedTextColor: Theme.textOnAccent
            font.family: root.code ? "Consolas" : root.fontFamily
            font.bold: root.code
            font.pixelSize: 12
            // Ctrl+Enter pastes, Escape saves and Ctrl+Escape cancels, before the area
            // sees them (a plain Enter is a new line; Escape is ignored by a TextArea).
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: event => {
                if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
                    event.accepted = true;
                    root.pasteRequested(editArea.text);
                } else if (event.key === Qt.Key_Escape) {
                    event.accepted = true;
                    if (event.modifiers & Qt.ControlModifier)
                        root.cancelled();
                    else
                        root.saveNow();
                }
            }
        }
    }

    // The shell's one scroll feel and its edge fades (a long entry scrolls in here): without it the box scrolled on Qt's own
    // 72 px style-hint step, swallowed notches while it glided and was cut hard at both edges. A sibling, told which rectangle
    // it dresses (the LLM composer's field is the same); the band is held to a quarter of the viewport, so a short editor is
    // not all fade.
    ScrollDressing {
        objectName: "clipEditorDressing"
        anchors.fill: editFlick
        flick: editFlick
        fadeHeight: Math.min(34, editFlick.height / 4)
        ground: Theme.panelSunk
    }
}
