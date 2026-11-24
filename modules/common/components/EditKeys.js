.pragma library

// =============================================================================
// EditKeys.js -- the terminal's line-editing keys as pure functions on a string.
//
//   actionOf(key, modifiers, selectAll)  -> null | action name
//   plan(action, text, pos, selStart, selEnd) -> { from, to, caret }
//        from < to : delete text[from, to) and put the caret at `caret`
//        from == to: only move the caret to `caret`
//   queryActionOf(key, modifiers) -> the actions a caret-less field (a type-ahead query) takes: the three backward kills
//   queryAfter(action, text) -> the string after such a kill
//        (type-ahead queries: the launcher's, the notes', the clipboard's search, which only grow at their end)
//
// THE SET (readline's emacs mode, what bash does in the user's terminal):
//   Ctrl+Backspace, Alt+Backspace   killWordBack     the word before the caret      (word = letters and digits)
//   Ctrl+W                          killBigWordBack  back to the last blank          (unix-word-rubout)
//   Ctrl+Delete, Alt+D              killWordForward  the word after the caret       (kill-word)
//   Ctrl+U                          killToStart      to the start of the LINE        (unix-line-discard)
//   Ctrl+K                          killToEnd        to the end of the LINE          (kill-line)
//   Ctrl+A / Ctrl+E                 lineStart / lineEnd                              (select-all keeps Ctrl+A: see actionOf)
//   Alt+B / Alt+F                   wordBack / wordForward
// The two word rules differ the way readline's do: "foo bar.baz" + Ctrl+W leaves "foo " (whitespace is the
// boundary), + Ctrl+Backspace leaves "foo bar." (punctuation is a boundary). Both are the answers of a REAL bash
// readline over a matrix of texts and caret positions.
//
// A LINE is what lies between newlines: in a multi-line field Ctrl+U, Ctrl+K, Ctrl+A and Ctrl+E act on the
// caret's own line, and a word kill may cross a newline (a newline is a blank, as in readline).
// WITH A SELECTION a kill deletes the selection (a text field's habit, readline has none) and a move starts
// from the caret.
//
// WORD CHARACTERS. Qt's JS engine has no \p{L}: letters and digits are ASCII alphanumerics, Latin-1 and
// everything from U+0100 up except the punctuation, symbol, emoji and private-use (icon font) blocks.
// Underscore is NOT a word character (readline's isn't).
//
// Pure, no Qt: table-tested under node.
// =============================================================================

// Qt.Key_* and Qt.*Modifier values (a pragma-library file cannot see the Qt object).
var KEY_BACKSPACE = 0x01000003;
var KEY_DELETE = 0x01000007;
var KEY_A = 0x41, KEY_B = 0x42, KEY_D = 0x44, KEY_E = 0x45, KEY_F = 0x46, KEY_K = 0x4b, KEY_U = 0x55, KEY_W = 0x57;
var MOD_SHIFT = 0x02000000, MOD_CTRL = 0x04000000, MOD_ALT = 0x08000000, MOD_META = 0x10000000;

function actionOf(key, modifiers, selectAll) {
    // Exactly Ctrl, or exactly Alt: Shift+Ctrl is the field's own selection step, Ctrl+Alt is AltGr on many
    // layouts, Meta is the compositor's. The keypad bit is ignored.
    const m = modifiers & (MOD_SHIFT | MOD_CTRL | MOD_ALT | MOD_META);
    if (m === MOD_CTRL) {
        switch (key) {
        case KEY_BACKSPACE: return "killWordBack";
        case KEY_W: return "killBigWordBack";
        case KEY_DELETE: return "killWordForward";
        case KEY_U: return "killToStart";
        case KEY_K: return "killToEnd";
        case KEY_A: return selectAll ? null : "lineStart";
        case KEY_E: return "lineEnd";
        }
    } else if (m === MOD_ALT) {
        switch (key) {
        case KEY_BACKSPACE: return "killWordBack";
        case KEY_D: return "killWordForward";
        case KEY_B: return "wordBack";
        case KEY_F: return "wordForward";
        }
    }
    return null;
}

function isKill(action) {
    return action === "killWordBack" || action === "killBigWordBack" || action === "killWordForward"
        || action === "killToStart" || action === "killToEnd";
}

// ---- characters --------------------------------------------------------------------------------------------------------------
function _isWordCp(cp) {
    if (cp < 0x80)
        return (cp >= 0x30 && cp <= 0x39) || (cp >= 0x41 && cp <= 0x5a) || (cp >= 0x61 && cp <= 0x7a);
    if (cp < 0x100)
        return cp === 0xaa || cp === 0xb5 || cp === 0xba || (cp >= 0xc0 && cp !== 0xd7 && cp !== 0xf7);
    if (cp >= 0x2000 && cp <= 0x2bff) return false;   // punctuation, symbols, arrows, maths, dingbats
    if (cp >= 0x3000 && cp <= 0x303f) return false;   // CJK punctuation
    if (cp >= 0xe000 && cp <= 0xf8ff) return false;   // private use: the icon fonts
    if (cp >= 0xfe00 && cp <= 0xfe0f) return false;   // variation selectors
    if (cp >= 0x1f000 && cp <= 0x1faff) return false; // emoji and pictographs
    return true;
}
function _isBlankCp(cp) {
    return cp === 0x20 || (cp >= 0x09 && cp <= 0x0d) || cp === 0xa0 || cp === 0x2029 || cp === 0x2028
        || (cp >= 0x2000 && cp <= 0x200a) || cp === 0x3000;
}
// The code point that ENDS at index i (i > 0), and the index it starts at.
function _cpBefore(text, i) {
    const lo = text.charCodeAt(i - 1);
    if (lo >= 0xdc00 && lo <= 0xdfff && i >= 2) {
        const hi = text.charCodeAt(i - 2);
        if (hi >= 0xd800 && hi <= 0xdbff)
            return { cp: ((hi - 0xd800) << 10) + (lo - 0xdc00) + 0x10000, at: i - 2 };
    }
    return { cp: lo, at: i - 1 };
}
// The code point that STARTS at index i (i < length), and the index after it.
function _cpAt(text, i) {
    const hi = text.charCodeAt(i);
    if (hi >= 0xd800 && hi <= 0xdbff && i + 1 < text.length) {
        const lo = text.charCodeAt(i + 1);
        if (lo >= 0xdc00 && lo <= 0xdfff)
            return { cp: ((hi - 0xd800) << 10) + (lo - 0xdc00) + 0x10000, end: i + 2 };
    }
    return { cp: hi, end: i + 1 };
}

// ---- boundaries --------------------------------------------------------------------------------------------------------------
function _wordBack(text, pos) {
    let i = pos, c;
    while (i > 0 && !_isWordCp((c = _cpBefore(text, i)).cp))
        i = c.at;
    while (i > 0 && _isWordCp((c = _cpBefore(text, i)).cp))
        i = c.at;
    return i;
}
function _bigWordBack(text, pos) {
    let i = pos, c;
    while (i > 0 && _isBlankCp((c = _cpBefore(text, i)).cp))
        i = c.at;
    while (i > 0 && !_isBlankCp((c = _cpBefore(text, i)).cp))
        i = c.at;
    return i;
}
function _wordForward(text, pos) {
    let i = pos, c;
    while (i < text.length && !_isWordCp((c = _cpAt(text, i)).cp))
        i = c.end;
    while (i < text.length && _isWordCp((c = _cpAt(text, i)).cp))
        i = c.end;
    return i;
}
function lineStart(text, pos) {
    return text.lastIndexOf("\n", pos - 1) + 1;
}
function lineEnd(text, pos) {
    const e = text.indexOf("\n", pos);
    return e < 0 ? text.length : e;
}

// ---- the plan ----------------------------------------------------------------------------------------------------------------
function plan(action, text, pos, selStart, selEnd) {
    const a = Math.min(selStart, selEnd), b = Math.max(selStart, selEnd);
    if (isKill(action) && b > a)
        return { from: a, to: b, caret: a };
    let from = pos, to = pos, caret = pos;
    switch (action) {
    case "killWordBack": from = _wordBack(text, pos); caret = from; break;
    case "killBigWordBack": from = _bigWordBack(text, pos); caret = from; break;
    case "killWordForward": to = _wordForward(text, pos); break;
    case "killToStart": from = lineStart(text, pos); caret = from; break;
    case "killToEnd": to = lineEnd(text, pos); break;
    case "lineStart": caret = lineStart(text, pos); break;
    case "lineEnd": caret = lineEnd(text, pos); break;
    case "wordBack": caret = _wordBack(text, pos); break;
    case "wordForward": caret = _wordForward(text, pos); break;
    }
    return { from: from, to: to, caret: caret };
}

// The actions that mean something to a field with no caret (a type-ahead query that only grows at its end): the three kills
// that look backwards. A host's key sink asks this first and, when it answers, writes queryAfter() into its query.
function queryActionOf(key, modifiers) {
    const a = actionOf(key, modifiers, false);
    return a === "killWordBack" || a === "killBigWordBack" || a === "killToStart" ? a : null;
}

// A field whose caret is always at its end (a type-ahead query): what a kill leaves of `text`.
function queryAfter(action, text) {
    if (!isKill(action) || action === "killWordForward" || action === "killToEnd")
        return text;
    const p = plan(action, text, text.length, text.length, text.length);
    return text.slice(0, p.from);
}
