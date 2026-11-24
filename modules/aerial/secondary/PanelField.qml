pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"

// =============================================================================
// PanelField.qml -- a one-line text field carved into its ground (a ShadowBox sunk 3 px, the shell's field look). `secret` shows dots
// (`revealed` shows the text), Enter asks `accepted()`, Escape gives up (`escaped()`, accepted: the host decides what giving up is),
// and `shake()` is the refusal: the field slides side to side and keeps its text, selected, ready for another try.
// The text lives in the field only: a secret is never copied into a property of ours (`text` reads the edit's own).
// `placeholder` is the one hint, in the faint ink. Focus is asked by the HOST (`forceFocus()`): a field that grabbed it by itself
// would take the keys from the app being typed in.
// =============================================================================
Item {
    id: field

    property PanelStyle look: null
    property alias text: edit.text
    property string placeholder: ""
    property bool secret: false
    property bool revealed: false
    property color ground: Theme.listBox
    property alias validator: edit.validator
    property alias inputMethodHints: edit.inputMethodHints
    readonly property bool hasFocus: edit.activeFocus

    signal accepted()
    signal escaped()
    signal edited(string text)

    function forceFocus(): void {
        edit.forceActiveFocus();
    }
    function clear(): void {
        edit.clear();
    }
    function selectAll(): void {
        edit.selectAll();
    }
    function shake(): void {
        shaker.restart();
        edit.forceActiveFocus();
        edit.selectAll();
    }

    property real _shift: 0
    SequentialAnimation {
        id: shaker
        NumberAnimation { target: field; property: "_shift"; to: -7; duration: 45 }
        NumberAnimation { target: field; property: "_shift"; to: 7; duration: 70 }
        NumberAnimation { target: field; property: "_shift"; to: -5; duration: 60 }
        NumberAnimation { target: field; property: "_shift"; to: 3; duration: 50 }
        NumberAnimation { target: field; property: "_shift"; to: 0; duration: 40 }
    }

    width: parent ? parent.width : 0
    implicitHeight: field.look ? field.look.fieldHeight : 30

    Item {
        id: body
        x: field._shift
        width: field.width
        height: field.height

        ShadowBox {
            anchors.fill: parent
            baseRadius: 8
            surfaceColor: field.ground
            backgroundColor: Theme.panelSunk
            bevelColor: Theme.bevel
            shadowColor: Theme.border
            bevelWidth: 1
            shadowWidth: 3
            shadowFalloff: 1
        }
        TextInput {
            id: edit
            objectName: "fieldInput"
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            clip: true
            color: Theme.textPrimary
            selectionColor: Theme.accent
            selectedTextColor: Theme.textOnAccent
            selectByMouse: true
            echoMode: field.secret && !field.revealed ? TextInput.Password : TextInput.Normal
            font.family: field.look ? field.look.fontFamily : "Inter"
            font.pixelSize: field.look ? field.look.bodySize : 12
            onTextEdited: field.edited(edit.text)
            onAccepted: field.accepted()
            Keys.onEscapePressed: event => {
                field.escaped();
                event.accepted = true;
            }
            // a caret that is not drawn while the field has no keys
            cursorDelegate: Rectangle {
                width: 1
                color: Theme.textPrimary
                visible: edit.activeFocus
            }
        }
        PText {
            look: field.look
            tone: 2
            x: edit.x
            anchors.verticalCenter: parent.verticalCenter
            width: edit.width
            elide: Text.ElideRight
            visible: edit.text.length === 0 && edit.preeditText.length === 0
            text: field.placeholder
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.IBeamCursor
            acceptedButtons: Qt.LeftButton
            onPressed: mouse => {
                edit.forceActiveFocus();
                mouse.accepted = false;
            }
        }
    }
}
