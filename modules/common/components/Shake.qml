import QtQuick

// =============================================================================
// Shake.qml -- the shell's ONE refusal: "no" said by a short side-to-side wiggle (the idle reel's refused step, a name
// field that will not take its text, a card the manager will not delete).
//
// One animated property, `offset` (px across the thing refused), OutCubic out and back with a small OutBack settle --
// the IconReel refuse motion. The host applies it where it draws:
//
//     Shake { id: shake }
//     transform: Translate { x: shake.offset }
//     ...  shake.play()
//
// An Item, not a QtObject: a non-visual helper built inside a component can lose its storage to Qt 6.12's collector
// (CLAUDE.md, "A GC CYCLE THAT STARTS INSIDE A COMPONENT'S BUILD"); an Item's wrapper is marked by its parent's.
// =============================================================================
Item {
    id: root

    width: 0
    height: 0
    visible: false

    // How far the first swing goes, in px. 3 reads as a refusal on an icon; a wide card or a field takes more.
    property real amplitude: 3
    // The offset to draw by. 0 at rest.
    property real offset: 0
    readonly property bool running: anim.running

    signal finished

    function play(): void {
        anim.restart();
    }

    SequentialAnimation {
        id: anim
        NumberAnimation { target: root; property: "offset"; to: root.amplitude; duration: 55; easing.type: Easing.OutCubic }
        NumberAnimation { target: root; property: "offset"; to: -root.amplitude; duration: 90; easing.type: Easing.OutCubic }
        NumberAnimation { target: root; property: "offset"; to: root.amplitude * 0.5; duration: 80; easing.type: Easing.OutCubic }
        NumberAnimation { target: root; property: "offset"; to: 0; duration: 140; easing.type: Easing.OutBack; easing.overshoot: 1.6 }
        onFinished: root.finished()
    }
}
