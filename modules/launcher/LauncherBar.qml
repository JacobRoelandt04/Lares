import QtQuick

import "../bar/gooey"

// =============================================================================
// LauncherBar.qml -- the slim, iconless bottom bar the launcher grows from.
//
// A GooeyBar with the launcher's numbers: on the bottom edge, 6 px thick --
// the width of Hyprland's outer gap (gaps_out = 6), and it sits INSIDE that
// gap (`reserve: 0`), so tiled windows do not move. The engine places a
// popup against each bar's own thickness, so any other value works by
// setting it: one property tweaked, everything reacts
// correctly. The host gives it its span (`rawPos`, `rawLen`: the whole
// edge) and the owner; hovering it opens the launcher.
// =============================================================================
GooeyBar {
    id: bar

    property var owner: null

    edge: "bottom"
    thickness: 6
    reserve: 0

    LauncherBarHover {
        owner: bar.owner
    }
}
