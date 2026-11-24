pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// GooeyBar.qml -- one bar of the gooey engine.
//
// A bar is a strip along one screen edge: its place on the engine's perimeter
// track (`edge`, `rawPos`, `rawLen`) and a frame its modules live in. The frame
// is ROTATED with the edge, so inside a bar x always runs along the bar and y
// inward from the screen edge, whatever edge it is on.
//
// It draws nothing. The engine's field draws every bar and every popup as one
// surface, so there is no seam between a bar and what hangs out of it, and the
// bar's modules are drawn above that surface and above the popups' content.
//
// Its own numbers, each defaulting to the engine's:
//   thickness  how far it reaches in from the screen edge. Everything placed
//              against the bar uses it: its popups' face, how far a popup on a
//              perpendicular edge keeps off it, the wall a migration rides past
//              it. A 6 px bar under a 40 px one is just this property.
//   radius     its free corners (the field clamps a corner to half the bar's
//              thickness and half its length, per axis); the engine's maxR x its bar ratio.
//   reserve    what it takes from the compositor's work area on its edge
//              (engine.edgeReserve): its thickness, or 0 for a bar that sits
//              inside the compositor's gap and lets windows keep their place. The
//              shell's reserve (HyprReserve) takes the engine's number plus
//              the border ring the bars grow outward by, and give the outlets their
//              own room (ShellLayout.windowReserve: the engine's 0 is not theirs).
//   inputMask  whether its rect is part of the engine's input region
//              (GooeyMask). False keeps it out, so the screen's edge under a
//              slim bar passes the pointer on to what is beneath it. Only the
//              bar's own rect: the popups' rects are the engine's as ever.
//   maskBox    {x0, y0, x1, y1} or null: the rect this bar puts in the input region INSTEAD of its own, for as long as it
//              is set. A host that moves the bar's rect on every frame (the islands' lengths easing) holds the union
//              of where the bar will have stood here, so the compositor is told twice per move and not every frame.
//   sky        the bar meets the screen's edge as if it hung from one gigantic body just beyond it (THE SKY,
//              GooeyGeometry.js): concave fillets where its ends meet the edge's line, on every frame of its
//              thickness. Off: its ends are square on the edge.
// =============================================================================
Item {
    id: root

    property var engine
    property string barId
    property string edge
    property real rawPos
    property real rawLen
    property real thickness: root.engine ? root.engine.thickness : 40
    property real radius: root.engine ? root.engine.barRadius : 0
    property real reserve: root.thickness
    property bool inputMask: true
    property var maskBox: null
    property bool sky: false
    // The engine lays out again when it changes while running (a bar hidden or shown): the
    // input region follows on the same frame. Not while the bar is still being built.
    property bool _built: false
    Component.onCompleted: root._built = true
    onInputMaskChanged: if (root._built && root.engine) root.engine.layout()
    onSkyChanged: if (root._built && root.engine) root.engine.layout()
    onMaskBoxChanged: if (root._built && root.engine) root.engine.layout()

    default property alias content: container.data

    readonly property real trackPos: {
        const p = root.engine ? root.engine.track.getBarInfoById(root.barId) : null;
        return p ? p.start : 0;
    }
    readonly property var metrics: root.engine ? root.engine.track.getMetrics(root.trackPos)
                                               : ({ edge: "top", x: 0, y: 0, rot: 0 })

    x: root.metrics.x
    y: root.metrics.y
    rotation: root.metrics.rot
    transformOrigin: Item.TopLeft

    width: root.rawLen
    height: root.thickness

    // The bar's box on screen, unrotated.
    readonly property bool _horizontal: root.metrics.edge === "top" || root.metrics.edge === "bottom"
    readonly property real absW: root._horizontal ? root.width : root.height
    readonly property real absH: root._horizontal ? root.height : root.width
    readonly property real absX: root.metrics.edge === "top" ? root.x
                               : root.metrics.edge === "right" ? root.x - root.height
                               : root.metrics.edge === "bottom" ? root.x - root.width : root.x
    readonly property real absY: root.metrics.edge === "top" ? root.y
                               : root.metrics.edge === "right" ? root.y
                               : root.metrics.edge === "bottom" ? root.y - root.height : root.y - root.width

    Item {
        id: container
        anchors.fill: parent
    }
}
