pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// =============================================================================
// ColorList -- one swatch and hex field per colour entry of a list.
//
// Same shape as ParamList: `listId` names a list of {label, prop, group,
// tip, val} in the registry, where `val` is a hex string -- or "@<token>", a
// colour that follows that Theme token (the component's own binding). The
// field accepts #RRGGBB, #AARRGGBB or "@<token>" and applies as soon as what
// it holds is one; anything else turns the text red and applies nothing. It
// shows "@<token>" while the row follows one, the hex once it is overridden.
//
// Where the colour is read from and written to is the registry's business,
// not this file's: an ordinary row is the target's `property color`, a row of
// a `themedLists` list is a theme token, and a themed list may have no target
// at all.
//
// A Repeater: place it inside a ColumnLayout and the rows land there.
// =============================================================================
Repeater {
    id: clist

    property MockupRegistry registry: null
    property string listId: ""
    property var groups: null
    readonly property var target: clist.registry ? clist.registry.targetOf(clist.listId) : null
    readonly property var colors: {
        const all = clist.registry ? clist.registry.entries(clist.listId) : [];
        return clist.groups ? all.filter(e => clist.groups.indexOf(e.group) >= 0) : all;
    }
    model: clist.colors

    delegate: ColumnLayout {
        id: colorRow
        required property var modelData
        required property int index
        // One answer to "is this value modified", used by the * mark, the
        // reset line in the tip and the right-click, so the three cannot
        // disagree. defaultsRev is passed so it re-evaluates after a save
        // has rewritten the defaults.
        readonly property bool modified: clist.registry ? clist.registry.colorModified(clist.registry.defaultsRev, clist.target, clist.listId, colorRow.modelData) : false
        Layout.fillWidth: true
        spacing: 0

        // The live colour, so the swatch and the field follow a reset, a
        // profile load or a theme switch. Through the registry, which knows
        // whether this row is the module's property or a theme token --
        // reading the target regardless assigned `undefined` to a QColor for
        // every row of a themed list with no such property on its target.
        readonly property color live: clist.registry
            ? clist.registry.colorOf(clist.listId, colorRow.modelData) : "transparent"
        onLiveChanged: colorRow.sync()
        // The token the row follows: a switch to a token that shows the same
        // colour in this mode moves no `live`, and the field must still say it.
        readonly property string follows: clist.registry ? clist.registry.followsToken(clist.listId, colorRow.modelData) : ""
        onFollowsChanged: colorRow.sync()
        Component.onCompleted: colorRow.sync()

        // Writes the live colour into the field -- unless the user is
        // typing and what they have typed already IS the live colour,
        // which is the case right after their own edit applied.
        function sync() {
            if (!clist.registry)
                return;
            if (hexField.activeFocus && clist.registry.isColorText(hexField.text)
                    && Qt.colorEqual(clist.registry.tokenDefault(hexField.text) !== ""
                                     ? clist.registry.tokenColorFor(colorRow.modelData, clist.registry.tokenDefault(hexField.text)) : hexField.text, colorRow.live))
                return;
            hexField.text = clist.registry.colorTextOf(clist.listId, colorRow.modelData);
        }
        // A themed row under a copy of the config (tools/dev/sandbox.sh): the
        // theme file it would write is the copy's, and the next sync puts it
        // back -- so the field is read-only and the tip says why.
        readonly property bool frozen: !!clist.registry && !clist.registry.themeWritable
            && clist.registry.themeKeyOf(clist.listId, colorRow.modelData) !== ""
        // Through the registry for the same reason, and one more: a themed
        // row must be written with setToken. Assigning the target's property
        // would destroy its `Theme.<token>` binding for good, so the module
        // would keep the typed colour and then ignore every later switch.
        // The `!clist.target` guard went with it: a themed list needs none.
        function apply() {
            if (!clist.registry || colorRow.frozen || !clist.registry.isColorText(hexField.text))
                return;
            // "@<token>" always goes through (it restores a binding, whatever
            // colour the row shows); a hex only when it is a change.
            if (clist.registry.tokenDefault(hexField.text) !== "" || !Qt.colorEqual(hexField.text, colorRow.live))
                clist.registry.setColor(clist.listId, colorRow.modelData, hexField.text);
        }

        TipGroup {
            visible: colorRow.index === 0 || clist.colors[colorRow.index - 1].group !== colorRow.modelData.group
            title: colorRow.modelData.group || ""
            blurb: colorRow.modelData.blurb || ""
        }

        TipRow {
            // The reset line is appended, never substituted: the entry's own
            // explanation is the reason the row is readable at all.
            tip: (colorRow.modelData.tip || "")
     + (clist.registry ? (clist.registry.themeKeyOf(clist.listId, colorRow.modelData) !== ""
                          ? clist.registry.themeNote(clist.listId, colorRow.modelData)
                            + (colorRow.frozen ? "\nRead-only here: this mockup runs from a copy of the config (tools/dev/sandbox.sh), so the theme file it would write is the copy's -- the next sync puts it back. Run the mockup from the config itself to edit the theme." : "")
                          : (colorRow.modified ? clist.registry.resetHint(clist.listId, colorRow.modelData) : "")
                            + clist.registry.planNote(clist.listId, colorRow.modelData) + clist.registry.sharedNote(clist.listId, colorRow.modelData)) : "")
            Label {
                text: colorRow.modelData.label + (colorRow.modified ? " *" : "")
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 14
                elide: Text.ElideRight
                Layout.preferredWidth: 160

                // Right button only, so the label never takes the press that
                // selects text in the hex field. Both handlers are off while
                // the value sits at its default: there is then nothing to put
                // back, and per the design language nothing but the pointer
                // may promise an affordance. The field follows the reset
                // through `live` -> sync(), the same path a profile load uses.
                TapHandler {
                    enabled: colorRow.modified
                    acceptedButtons: Qt.RightButton
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: if (clist.registry)
                        clist.registry.resetEntry(clist.listId, colorRow.modelData)
                }
                HoverHandler {
                    enabled: colorRow.modified
                    cursorShape: Qt.PointingHandCursor
                }
            }
            Rectangle {
                implicitWidth: 30
                implicitHeight: 20
                radius: 5
                color: colorRow.live
                border.color: "#CED1D7"
                border.width: 1
            }
            TextField {
                id: hexField
                Layout.fillWidth: true
                placeholderText: "#RRGGBB or @token"
                font.family: "Audiowide"
                font.pixelSize: 14
                readOnly: colorRow.frozen
                color: colorRow.frozen ? "#8A8A8C" : clist.registry && clist.registry.isColorText(text) ? "#5D5D5F" : "#D20F39"
                selectByMouse: true
                onTextEdited: colorRow.apply()
                onAccepted: {
                    colorRow.apply();
                    if (clist.registry)
                        text = clist.registry.colorTextOf(clist.listId, colorRow.modelData);
                }
            }
        }
        // THE SHARED DEFAULT: see ParamList. A modified colour of a component other modules use too.
        TipRow {
            visible: colorRow.modified && !!clist.registry && clist.registry.hasSharedChoice(clist.listId, colorRow.modelData)
            tip: clist.registry ? clist.registry.sharedNote(clist.listId, colorRow.modelData).trim() : ""
            Item {
                Layout.preferredWidth: 160
            }
            Switch {
                id: sharedSw
                objectName: "paramShared"
                checked: !!clist.registry && clist.registry.sharedOn(clist.listId, colorRow.modelData)
                text: "shared default"
                font.family: "Audiowide"
                font.pixelSize: 12
                onToggled: if (clist.registry)
                    clist.registry.setShared(clist.listId, colorRow.modelData, sharedSw.checked)
            }
            Item {
                Layout.fillWidth: true
            }
        }
    }
}
