pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// TimerView.qml -- what every view of the timers card is: an overlay the size
// of the card, placing its controls round the dial the card draws.
//
// The card is square and the dial is centred in it; a view uses the space the
// circle leaves: a control top-right beside the title, the bottom corners, or
// the band under the ring for a list. The main action inside the ring and the
// icon row under it are the card's own (shared by the views, so a switch
// moves them instead of swapping them) and sit at this geometry's `innerY` /
// `iconY`. The geometry comes from the card, so every view agrees on where
// the ring is.
//
// `presence` is this view's own half of a switch (0 while another view is
// shown, 1 when it is): the leaving view is gone by the switch's midpoint and
// the arriving one comes in over the second half, so two sets of controls are
// never seen through each other. Input goes only to the view the card is on.
// =============================================================================
Item {
    id: view

    property var timers: null
    property string fontFamily: "Audiowide"
    property real presence: 1
    property bool current: false
    property bool listWheelEnabled: true

    // ---- The card's geometry ----------------------------------------------
    property real side: 454
    property real padding: 12
    property real cx: side / 2
    property real cy: side / 2
    property real ringOuter: 137           // the carve's outer edge from the centre
    property real innerRadius: 110         // the room inside the ring's ticks

    // Where the main action sits: the lower half of the ring's inside, and
    // the row of icon actions under it.
    readonly property real innerY: Math.round(view.cy + 14)
    readonly property real iconY: Math.round(view.innerY + 38)
    // The band under the ring, for a list.
    readonly property real bandTop: Math.round(view.cy + view.ringOuter + 10)
    readonly property real bandBottom: Math.round(view.side - view.padding)

    // A scrolling list in this view, for the popup's wheel owners (null: none).
    property Item listViewport: null
    // A duration field under (px, py), in this item's coordinates (null: none).
    function fieldAt(px, py) {
        return null;
    }

    width: view.side
    height: view.side
    opacity: view.presence * view.presence
    visible: view.presence > 0.001
    enabled: view.current
}
