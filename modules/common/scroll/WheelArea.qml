import QtQuick

// =============================================================================
// WheelArea -- the shell's wheel reader: a MouseArea whose wheel events come NORMALISED (WheelHub.read), and which a side-button swipe can
// drive as well (SideSwipe feeds it the same events). Every reader in the shell is one; a bare `onWheel` reads a mouse as fingers on Qt 6.12.
//
//     WheelArea {
//         anchors.fill: parent
//         turned: ev => { ...; ev.accepted = false; }     // false passes it on, as Qt's wheel does; true (the default) keeps it
//     }
//
// `turned` is a FUNCTION, not a signal: an object handed through a signal is a copy, and what a handler writes on it (`accepted`) is lost.
//
// It takes no button, no hover and decides no cursor (docs/contracts/gestures.md section 2: a MouseArea, never a WheelHandler). A host that
// also wants clicks sets `acceptedButtons`.
// =============================================================================
MouseArea {
    id: wa

    // One event: { x, y, angleDelta, pixelDelta, phase, modifiers, buttons, inverted, device, notches, steps, click, accepted } (WheelHub.read).
    property var turned: null

    acceptedButtons: Qt.NoButton
    cursorShape: undefined   // clicks pass through: the cursor is what lies under it (a MouseArea owns an Arrow)
    onWheel: wheel => {
        const ev = WheelHub.read(wheel, wa);
        wa._offer(ev);
        wheel.accepted = ev.accepted;
    }

    // An event made elsewhere (SideSwipe; a probe's fingers), in this item's coordinates. Returns whether it was kept.
    function feed(ev: var): bool {
        ev.accepted = true;
        wa._offer(ev);
        return ev.accepted;
    }
    function _offer(ev: var): void {
        if (typeof wa.turned === "function")
            wa.turned(ev);
    }

    // a high-resolution wheel's pieces of a notch (WheelHub._notches)
    readonly property var _pieces: ({ x: 0, y: 0, at: 0 })
    Component.onCompleted: WheelHub.join(wa)
    Component.onDestruction: WheelHub.leave(wa)
}
