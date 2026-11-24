pragma Singleton

import QtQuick
import Quickshell

// =============================================================================
// InkWhole.qml -- "something draws outside the engine's ink now": the ONE registry the visible region reads (shell.jsonc
// `workarounds.visibleInk`, GooeyInk, ShellScreen). The bar window's visible region holds the engine's bands, slots and tiles; a
// part that can draw elsewhere (a glyph's flourish throwing a wave past its bar) holds this while it does, and every window keeps
// its whole surface visible until the last hold lets go. A hold is cheap, so a part that cannot tell holds it for its whole run.
//
//   InkWhole.hold(true) ... InkWhole.hold(false)     (always in pairs)
// =============================================================================
Singleton {
    id: root

    // how many parts draw outside the engine now
    property int holds: 0
    readonly property bool whole: root.holds > 0

    function hold(on: bool): void {
        root.holds = Math.max(0, root.holds + (on ? 1 : -1));
    }
}
