pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls

import "../theme"

// =============================================================================
// CarvedSearchField.qml -- a one-line search box carved into its ground.
//
//   CarvedSearchField {
//       placeholder: "Search stocks"
//       surfaceColor: Theme.surface          // the ground it is carved INTO
//       text: service.searchQuery            // optional: a host may drive it
//       onEdited: t => service.setSearchQuery(t)
//       onEscaped: ...
//   }
//
// One component for the LLM sidebar's "Search chats" box (LlmSidebar.qml, the
// Search block) and the network PSK field (PskField.qml): a carved
// ShadowBox (radius 8, bevel 1, shadow 3), the magnifier in the faint colour at
// the left, the edit after it, the hint in the placeholder once.
//
// `text` IS THE EDIT'S OWN TEXT (an alias), so a host may bind it and the
// binding survives typing: every keystroke emits `edited(text)`, the host
// writes its model, and the binding hands the same string back, which the
// edit ignores. Esc with something typed clears it through the edit's own
// `clear()` -- never an assignment, which would cut a host's binding for
// good (CLAUDE.md) -- emits `edited("")` and `escaped()`, and is accepted.
// Esc on an EMPTY field emits `escaped()` and is NOT accepted, so it reaches
// whatever closes the popup. `escapeClears: false` leaves the text alone and
// only signals.
//
// `padding: 0` ON A CONTROLS FIELD DOES NOT ZERO ITS LEFT PADDING (Basic and
// Fusion bind `leftPadding: padding + 4` on their own), so every side is set
// explicitly and the caret starts exactly where the placeholder does.
//
// A ShadowBox draws its bevel OUTSIDE its rect: a host that clips close to
// this item must leave it the bevel's slack (2 px) or the bevel is sheared.
// =============================================================================
Item {
    id: root

    // ---- Contract --------------------------------------------------------
    property alias text: edit.text
    property string placeholder: ""
    property string fontFamily: "Inter"
    property int pixelSize: 12
    property color surfaceColor: Theme.surface
    property bool escapeClears: true

    signal edited(string text)
    signal escaped()

    function forceFocus() {
        edit.forceActiveFocus();
    }
    readonly property bool hasFocus: edit.activeFocus

    // ---- Look (Theme defaults; a host overrides only what differs) ---------
    property color fillColor: Theme.panelSunk
    property color bevelColor: Theme.bevel
    property color shadowColor: Theme.border
    property color textColor: Theme.textPrimary
    property color placeholderColor: Theme.textFaint
    property color glyphColor: Theme.textFaint
    property color selectionColor: Theme.accent
    property color selectedTextColor: Theme.textOnAccent
    property real radius: 8
    property string glyph: "\uf002"
    property string glyphFamily: "Symbols Nerd Font"
    property int glyphSize: 10
    // The glyph's left inset, and the gap from the glyph to the text.
    property real glyphInset: 9
    property real glyphGap: 7
    property real rightInset: 8

    implicitWidth: 160
    implicitHeight: 28

    ShadowBox {
        anchors.fill: parent
        baseRadius: root.radius
        surfaceColor: root.surfaceColor
        backgroundColor: root.fillColor
        bevelColor: root.bevelColor
        shadowColor: root.shadowColor
        bevelWidth: 1
        shadowWidth: 3
    }

    Text {
        id: glyphText
        x: root.glyphInset
        y: Math.round((root.height - glyphText.implicitHeight) / 2)
        text: root.glyph
        font.family: root.glyphFamily
        font.pixelSize: root.glyphSize
        color: root.glyphColor
    }

    TextField {
        id: edit
        Keys.forwardTo: [editKeys]
        EditKeys {
            id: editKeys
            target: edit
        }
        anchors.fill: parent
        // Every side, and not `padding`: see the header.
        leftPadding: Math.round(root.glyphInset + glyphText.implicitWidth + root.glyphGap)
        rightPadding: root.rightInset
        topPadding: 0
        bottomPadding: 0
        verticalAlignment: TextInput.AlignVCenter
        background: null                 // the ShadowBox is the chrome
        selectByMouse: true
        placeholderText: root.placeholder
        placeholderTextColor: root.placeholderColor
        color: root.textColor
        selectionColor: root.selectionColor
        selectedTextColor: root.selectedTextColor
        font.family: root.fontFamily
        font.pixelSize: root.pixelSize
        onTextEdited: root.edited(edit.text)
        Keys.onEscapePressed: function (e) {
            if (root.escapeClears && edit.text.length > 0) {
                edit.clear();
                root.edited("");
                e.accepted = true;
            } else {
                e.accepted = false;
            }
            root.escaped();
        }
    }
}
