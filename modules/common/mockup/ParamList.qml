pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// =============================================================================
// ParamList -- one labelled control per entry of a value list: a slider for
// a number, a switch for a bool, a drop-down for a choice (`choices`: the
// value is the index), a line of text for `kind: "text"`, and a JSON box for
// `kind: "json"` (applied only while it parses and has its `shape`; the text
// turns red and says why otherwise).
//
// `listId` names a list in the registry ({label, prop, group, tip, val,
// from, to, step} entries, `from`/`to`/`step` only where there is a range);
// each control reads the LIVE value off the list's target and writes it back
// when moved, so the readout is always what the component actually holds and
// follows a reset or a profile load without being told. `groups`, when set,
// shows only the entries of those groups so a long list can be split over
// sub-tabs without being split in the data. The group heading is emitted by
// the first row of each group rather than by a separate structure, so a list
// stays flat and easy to reorder.
//
// The KIND of a row is the entry's own `val`, so a bool needs no new field:
// `val: true` is a switch, a number is a slider. Both live in the same list,
// because the panel is split by component and a component's switch belongs
// beside its numbers. The two controls share the row: same label column,
// same value column on the right, one of them hidden -- and a layout skips
// an invisible child, so the visible one gets the whole middle column.
//
// A Repeater: place it inside a ColumnLayout and the rows land there.
// =============================================================================
Repeater {
    id: plist

    property MockupRegistry registry: null
    property string listId: ""
    property var groups: null
    // THE VALUE SLOT: the width the slider and switch rows read their value
    // in, right-aligned, so their controls end on one line. The host measures
    // it over everything it shows at once (MockupTabPage: the widest figure
    // of the section, never under the framework's 56 px).
    required property real slotWidth
    readonly property var target: plist.registry ? plist.registry.targetOf(plist.listId) : null
    readonly property var params: {
        const all = plist.registry ? plist.registry.entries(plist.listId) : [];
        return plist.groups ? all.filter(e => plist.groups.indexOf(e.group) >= 0) : all;
    }
    model: plist.params

    delegate: ColumnLayout {
        id: paramRow
        required property var modelData
        required property int index
        // One answer to "is this value modified", used by the * mark, the
        // reset line in the tip and the right-click, so the three cannot
        // disagree. defaultsRev is passed so it re-evaluates after a save
        // has rewritten the defaults.
        readonly property bool modified: plist.registry ? plist.registry.valueModified(plist.registry.defaultsRev, plist.target, plist.listId, paramRow.modelData) : false
        readonly property bool isBool: plist.registry ? plist.registry.isBoolEntry(paramRow.modelData) : false
        readonly property bool isChoice: plist.registry ? plist.registry.isChoiceEntry(paramRow.modelData) : false
        readonly property bool isJson: plist.registry ? plist.registry.isJsonEntry(paramRow.modelData) : false
        readonly property bool isText: plist.registry ? plist.registry.isTextEntry(paramRow.modelData) && !paramRow.isJson : false
        // A slider unless it is one of the others.
        readonly property bool isSlider: plist.registry ? plist.registry.isSliderEntry(paramRow.modelData) : false
        // The live bool, read the way the slider reads its number: off the
        // target, so the switch follows a reset, a profile load or whatever
        // else in the mockup writes the same property.
        readonly property bool live: paramRow.isBool && plist.target ? !!plist.target[paramRow.modelData.prop] : false
        // The live text of a text or JSON row, the same way.
        readonly property string liveText: (paramRow.isText || paramRow.isJson) && plist.target
            ? String(plist.target[paramRow.modelData.prop]) : ""
        // Why the JSON box's text is not applied ("" = it is).
        readonly property string jsonProblem: paramRow.isJson && plist.registry
            ? plist.registry.jsonProblem(paramRow.modelData, jsonBox.text) : ""
        Layout.fillWidth: true
        spacing: 0

        // The live text into a field -- unless the user is typing and what
        // they typed already IS the live value (the case right after their own
        // edit applied), or JSON that means the same thing.
        function syncText() {
            if (paramRow.isText && !(textField.activeFocus && textField.text === paramRow.liveText))
                textField.text = paramRow.liveText;
            if (paramRow.isJson && !(jsonBox.activeFocus && plist.registry
                    && plist.registry.canonicalJson(jsonBox.text) === plist.registry.canonicalJson(paramRow.liveText))) {
                paramRow._syncing = true;
                jsonBox.text = paramRow.liveText;
                paramRow._syncing = false;
            }
        }
        property bool _syncing: false
        onLiveTextChanged: paramRow.syncText()
        Component.onCompleted: paramRow.syncText()

        TipGroup {
            visible: paramRow.index === 0 || plist.params[paramRow.index - 1].group !== paramRow.modelData.group
            title: paramRow.modelData.group || ""
            blurb: paramRow.modelData.blurb || ""
        }

        TipRow {
            // The reset line is appended, never substituted: the entry's own
            // explanation is the reason the row is readable at all.
            tip: (paramRow.modelData.tip || "")
                 + (plist.registry ? plist.registry.fileNote(plist.listId) : "")
                 + (paramRow.modified && plist.registry ? plist.registry.resetHint(plist.listId, paramRow.modelData) : "")
                 + (plist.registry ? plist.registry.planNote(plist.listId, paramRow.modelData) + plist.registry.sharedNote(plist.listId, paramRow.modelData) : "")
            Label {
                // The * marks a value that differs from the entry's `val:`
                // default.
                text: paramRow.modelData.label + (paramRow.modified ? " *" : "")
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 14
                elide: Text.ElideRight
                Layout.preferredWidth: 160

                // Right button only, so the label never takes the press that
                // starts a slider drag. Both handlers are off while the value
                // sits at its default: there is then nothing to put back, and
                // per the design language nothing but the pointer may promise
                // an affordance.
                TapHandler {
                    enabled: paramRow.modified
                    acceptedButtons: Qt.RightButton
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: if (plist.registry)
                        plist.registry.resetEntry(plist.listId, paramRow.modelData)
                }
                HoverHandler {
                    enabled: paramRow.modified
                    cursorShape: Qt.PointingHandCursor
                }
            }
            Slider {
                id: sl
                visible: paramRow.isSlider
                Layout.fillWidth: true
                // Only a slider row carries a range and a numeric value, so
                // the hidden slider of any other row must be kept from reading
                // either: assigning `undefined` to from/to/stepSize, or a bool
                // or a string to value, is warnings per row at every load.
                from: paramRow.isSlider ? paramRow.modelData.from : 0
                to: paramRow.isSlider ? paramRow.modelData.to : 1
                stepSize: paramRow.isSlider ? paramRow.modelData.step : 0
                value: !paramRow.isSlider || !plist.target ? 0 : plist.target[paramRow.modelData.prop]
                onMoved: if (plist.target)
                    plist.target[paramRow.modelData.prop] = value
            }
            // A choice names its value: the index is what is stored, saved and
            // compared, the name is what is shown. `activated` rather than a
            // currentIndex handler, so writing the target is the user's doing
            // and the binding to the live index survives.
            ComboBox {
                id: choice
                objectName: "paramChoice"
                visible: paramRow.isChoice
                Layout.fillWidth: true
                model: paramRow.isChoice ? paramRow.modelData.choices : []
                currentIndex: paramRow.isChoice && plist.target ? Number(plist.target[paramRow.modelData.prop]) : -1
                font.family: "Audiowide"
                font.pixelSize: 13
                onActivated: index => {
                    if (plist.registry)
                        plist.registry.setValue(plist.listId, paramRow.modelData, index);
                }
            }
            TextField {
                id: textField
                objectName: "paramText"
                visible: paramRow.isText
                Layout.fillWidth: true
                font.family: "Audiowide"
                font.pixelSize: 13
                color: "#5D5D5F"
                selectByMouse: true
                onTextEdited: if (plist.registry)
                    plist.registry.setValue(plist.listId, paramRow.modelData, textField.text)
            }
            // Fills the same column the slider does, so the whole width of
            // the control column is the target -- the switch's own indicator
            // sits where a slider at its minimum has its handle. `checked` is
            // a binding and stays one: a click sets it from C++, which leaves
            // the binding in place, so `live` still moves the switch when the
            // value is put back. onToggled, not onCheckedChanged, so writing
            // the target is the user's doing and never the binding's.
            Switch {
                id: sw
                visible: paramRow.isBool
                Layout.fillWidth: true
                checked: paramRow.live
                onToggled: if (plist.target)
                    plist.target[paramRow.modelData.prop] = sw.checked
            }
            Label {
                // The same slot the numbers are read in, in the switch's own
                // words: a slider's or a switch's value is always in this
                // column. A choice, a text and a JSON box show their value in
                // the control itself, which takes the column's room instead.
                visible: paramRow.isSlider || paramRow.isBool
                text: paramRow.isBool ? (paramRow.live ? "on" : "off")
                    : paramRow.isSlider && plist.registry ? plist.registry.figureText(paramRow.modelData, sl.value) : ""
                color: "#5D5D5F"
                font.family: "Audiowide"
                font.pixelSize: 14
                Layout.preferredWidth: plist.slotWidth
                horizontalAlignment: Text.AlignRight
            }
        }
        // THE SHARED DEFAULT, on a line of its own under the row so every value keeps its column. A component
        // other modules use too: Save writes this row at THIS module's use of it unless this is on, when it
        // writes the component's own default (the row's tip says where). Only a modified row of such a
        // component carries it -- nothing else announces it.
        TipRow {
            visible: paramRow.modified && !!plist.registry && plist.registry.hasSharedChoice(plist.listId, paramRow.modelData)
            tip: plist.registry ? plist.registry.sharedNote(plist.listId, paramRow.modelData).trim() : ""
            Item {
                Layout.preferredWidth: 160
            }
            Switch {
                id: sharedSw
                objectName: "paramShared"
                checked: !!plist.registry && plist.registry.sharedOn(plist.listId, paramRow.modelData)
                text: "shared default"
                font.family: "Audiowide"
                font.pixelSize: 12
                onToggled: if (plist.registry)
                    plist.registry.setShared(plist.listId, paramRow.modelData, sharedSw.checked)
            }
            Item {
                Layout.fillWidth: true
            }
        }
        // A JSON box under its label, the panel's whole width: a rule object
        // does not fit beside a 160 px label. Its own TipRow, so hovering the
        // box explains it as the label does.
        TipRow {
            visible: paramRow.isJson
            tip: (paramRow.modelData.tip || "") + (plist.registry ? plist.registry.fileNote(plist.listId) : "")
            TextArea {
                id: jsonBox
                objectName: "paramJson"
                Layout.fillWidth: true
                font.family: "Consolas"
                font.pixelSize: 12
                wrapMode: TextEdit.Wrap
                selectByMouse: true
                color: paramRow.jsonProblem === "" ? "#5D5D5F" : "#D20F39"
                background: Rectangle {
                    color: "#F4F5F9"
                    radius: 6
                    border.width: 1
                    border.color: jsonBox.activeFocus ? "#4480F4" : "#CED1D7"
                }
                // Applied as soon as what it holds parses and has its shape,
                // like a hex field; an edit that does not stays red here and
                // reaches nothing.
                // (The problem is asked afresh here: the `jsonProblem` binding
                // and this handler hear the same change in an order nobody sets.)
                onTextChanged: if (paramRow.isJson && !paramRow._syncing && plist.registry
                        && plist.registry.canonicalJson(jsonBox.text) !== plist.registry.canonicalJson(paramRow.liveText))
                    plist.registry.setValue(plist.listId, paramRow.modelData, jsonBox.text)
            }
        }
        Label {
            visible: paramRow.isJson && paramRow.jsonProblem !== ""
            Layout.fillWidth: true
            text: "not applied: " + paramRow.jsonProblem
            color: "#D20F39"
            font.family: "Audiowide"
            font.pixelSize: 12
            wrapMode: Text.Wrap
        }
    }
}
