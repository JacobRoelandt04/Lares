import QtQuick

// =============================================================================
// LauncherBarHover.qml -- the slim bottom bar's one input: the pointer on it.
//
// The bar carries no icon (it is the iconless slim bar the launcher grows
// from), so the whole bar is the hover target; the screen's edge makes a
// 6 px strip easy to hit. Placed as a child of the GooeyBar, filling it; it
// tells the owner, which opens after `tune.hoverOpenMs` at rest.
// =============================================================================
Item {
    id: hover

    property var owner: null

    anchors.fill: parent

    HoverHandler {
        onHoveredChanged: {
            if (hover.owner)
                hover.owner.barHovered = hovered;
        }
    }
}
