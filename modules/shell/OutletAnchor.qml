import QtQuick

// =============================================================================
// OutletAnchor.qml -- an invisible point on a bar that a popup is anchored to.
//
// Notes and the LLM open out of the LEFT slim bar, near its top, though their buttons are in the
// top bar: their owners hang the popup from `anchorItem` (mapToItem(bar, w/2, h/2) gives the
// centre along the bar, in the bar's own frame), and this is the item they are handed. It sits in
// the outlet bar and takes no input and draws nothing.
//
// `along` is BarSpot's rule (modules/common/components/BarSpot.js): the fraction of the bar's
// length from its START ON THE SCREEN -- the left or top end. A bar's own x runs against the
// screen on the bottom and left edges (a left bar's local x runs bottom-to-top), so the
// fraction is turned round there. At 0 on the left bar the anchor is at the top end, under the
// main bar's left island; the popup's box (clamped to the bar, and THE WALL pulls it flush) rests
// against the island. `bar` is the GooeyBar it stands in.
//
// A WHOLE-PIXEL MIDDLE: width 0 and a rounded x. The engine rests a popup's box about the point
// its owner passes (anchorItem.mapToItem(bar, w / 2, h / 2).x); a 1 px outlet has its middle on
// x.5, and whenever the content's own shift is followed exactly (a morph, a live resize) the box
// lands on a half pixel and every Text in it rasters 0.5 px off (the notes box, for one,
// lands on y = 40.5).
// =============================================================================
Item {
    id: root

    property var bar: null
    property real along: 0

    width: 0
    height: 0
    visible: false
    readonly property real _g: root.bar && (root.bar.edge === "bottom" || root.bar.edge === "left") ? 1 - root.along : root.along
    x: Math.round(root._g * (root.bar ? root.bar.width : 0))
    y: root.bar ? Math.round(root.bar.height / 2) : 0
}
