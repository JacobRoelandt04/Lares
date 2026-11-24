pragma ComponentBehavior: Bound

import QtQuick

import "EditKeys.js" as EK

// =============================================================================
// EditKeys.qml -- the terminal's editing keys for a text field (the shell's ONE implementation).
//
//   TextField {
//       id: edit
//       Keys.forwardTo: [editKeys]
//       EditKeys { id: editKeys; target: edit }
//   }
//
// Ctrl+Backspace / Alt+Backspace delete the word before the caret, Ctrl+W the run back to the last blank, Ctrl+Delete /
// Alt+D the word after it, Ctrl+U everything back to the start of the line, Ctrl+K everything on to its end, Ctrl+A / Ctrl+E
// move to the line's start / end and Alt+B / Alt+F by a word -- readline's, measured against bash (EditKeys.js has the
// rules). Qt alone does Ctrl+Backspace / Ctrl+Delete (stopping at
// punctuation, differently per platform theme), selects all on Ctrl+A, ignores Ctrl+W/U/K/E, and TYPES the letter of
// Alt+B / Alt+F / Alt+D into the field.
//
// `target` is a TextInput / TextEdit or a Controls TextField / TextArea. Keys.forwardTo runs this before the field's own
// handling (and after its own Keys.onPressed), so a key it takes never reaches the field; every other key passes untouched,
// Ctrl+C / V / X / Z / Shift-selections among them. A deletion is ONE remove() on the field, which is one step of its undo
// stack. A field being composed into by an input method (preedit) is left alone, and a read-only one only moves (a kill is swallowed).
//
// `selectAll: true` leaves Ctrl+A as "select all" (the notes editor and the LLM composer: a document is not a command line).
// `active: false` switches the whole set off. A kill goes through the field's remove(), which a TextInput / TextField reports on
// its own textEdited() (measured; a host that listens for the user's edits hears it once, a TextEdit has textChanged only);
// `acted(action)` says which key it was.
//
// A host with its own Keys.onPressed that must see the key first just lists this in forwardTo; a host with no field to
// forward from (a window-level key sink) calls handle(event) itself.
// =============================================================================
Item {
    id: root

    property var target: null
    property bool selectAll: false
    property bool active: true

    signal acted(string action)

    // The event is accepted and true is returned when this took it.
    function handle(event): bool {
        const f = root.target;
        if (!root.active || !f || event.accepted)
            return false;
        const action = EK.actionOf(event.key, event.modifiers, root.selectAll);
        if (action === null)
            return false;
        if (f.inputMethodComposing)
            return false;
        // The field's own text: getText covers a TextEdit's rich content as plain text, positions as the field counts them.
        const text = f.getText(0, f.length);
        const p = EK.plan(action, text, f.cursorPosition, f.selectionStart, f.selectionEnd);
        const kill = EK.isKill(action);
        if (kill && f.readOnly) {
            event.accepted = true;
            return true;
        }
        if (kill && p.to > p.from) {
            f.remove(p.from, p.to);
            f.cursorPosition = p.caret;
        } else if (!kill) {
            f.cursorPosition = p.caret;
        }
        root.acted(action);
        event.accepted = true;
        return true;
    }

    Keys.onPressed: event => root.handle(event)
}
