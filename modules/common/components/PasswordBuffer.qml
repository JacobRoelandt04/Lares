import QtQuick

import "EditKeys.js" as EK

// =============================================================================
// PasswordBuffer.qml -- a secret typed key by key, with no text field.
//
// The lockscreen and the auth toast both take a password as raw key events
// (the lock has no field at all; the toast draws dots), and both answer a
// PAM prompt that may not have arrived yet. This is the one copy of the key
// handling they share:
//
//   Return / Enter            enterPressed(empty)
//   Backspace                 one character off
//   Escape, Ctrl+U,           clear() -- and escapePressed() for Escape, so a
//   Ctrl+Backspace            host can also let go of the keyboard on it
//   Ctrl+W                    the last blank-delimited word off, as a terminal's
//                             (EditKeys.js; a secret without blanks goes whole)
//   a printable character     appended (at most maxLength); firstCharacter()
//                             when it went into an empty buffer
//
// handleKey(event) answers whether it used the key. The secret leaves only
// through take(), which also empties the buffer; `length` is all a host
// needs to draw. Nothing here logs, stores or binds the text.
// =============================================================================
QtObject {
    id: root

    property int maxLength: 512
    readonly property int length: root._buf.length
    property string _buf: ""

    // Any change of `length` by a key, take() or clear().
    signal edited()
    // A printable character went into an EMPTY buffer (the lock starts a face
    // scan on it).
    signal firstCharacter()
    // Return / Enter; `empty` when there was nothing to submit.
    signal enterPressed(bool empty)
    signal escapePressed()

    function printable(text) {
        if (text === undefined || text === null || text.length === 0)
            return false;
        for (let i = 0; i < text.length; i++) {
            const c = text.charCodeAt(i);
            if (c < 32 || c === 127)
                return false;
        }
        return true;
    }

    function handleKey(event) {
        const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
        const alt = (event.modifiers & (Qt.AltModifier | Qt.MetaModifier)) !== 0;
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.enterPressed(root._buf.length === 0);
            return true;
        }
        if (event.key === Qt.Key_Backspace && !ctrl) {
            if (root._buf.length > 0) {
                root._buf = root._buf.slice(0, -1);
                root.edited();
            }
            return true;
        }
        if (event.key === Qt.Key_Escape) {
            root.clear();
            root.escapePressed();
            return true;
        }
        if (ctrl && (event.key === Qt.Key_U || event.key === Qt.Key_Backspace)) {
            root.clear();
            return true;
        }
        if (ctrl && !alt && event.key === Qt.Key_W) {
            const rest = EK.queryAfter("killBigWordBack", root._buf);
            if (rest !== root._buf) {
                root._buf = rest;
                root.edited();
            }
            return true;
        }
        if (!ctrl && !alt && root.printable(event.text)) {
            const wasEmpty = root._buf.length === 0;
            root._buf = (root._buf + event.text).slice(0, root.maxLength);
            root.edited();
            if (wasEmpty)
                root.firstCharacter();
            return true;
        }
        return false;
    }

    // The secret, once: the buffer is empty afterwards.
    function take() {
        const s = root._buf;
        root.clear();
        return s;
    }

    function clear() {
        if (root._buf.length === 0)
            return;
        root._buf = "";
        root.edited();
    }
}
