pragma Singleton

import QtQuick

// =============================================================================
// ShellCursor -- whether the pointer changes over what it can act on: ONE answer for every window of the shell (CursorCover reads it).
//
//   hover   shell.jsonc `"hoverCursor"` (ShellConfig.hoverCursor; ShellServices writes it, hot). false, the default: the pointer is the
//           plain arrow everywhere. true: a hand over what can be clicked, the beam over text, the resize arrows on a grip.
// =============================================================================
QtObject {
    property bool hover: false
}
