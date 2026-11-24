import QtQuick

// =============================================================================
// PlayerTickHold.qml -- "this draws the player's elapsed time".
//
// MpdService (and PlayerMockRun) interpolate `elapsed` with a FrameAnimation, and a
// running FrameAnimation makes EVERY window of the process render at vsync. In the shell
// the service is one for all screens, so the clock runs only while something on screen
// shows the position. That something declares it with one of these:
//
//     PlayerTickHold { player: root.player; active: root.visible }
//
// The clock runs while this object lives, `active` is true and the player is playing; it is
// let go the moment `active` goes false, the player changes, or this object is destroyed
// (the engine builds a popup's content on open and destroys it when the close ends, so the
// hold lives exactly as long as the popup does). A player without the API (a stub) is simply
// not held: the position then stays whatever the stub makes it.
//
// Holder: the player popup (AudioPlayerPopup). Anything else that shows the position declares
// it the same way.
// =============================================================================
QtObject {
    id: root

    property var player: null
    property bool active: true

    // Whether the clock is held by this object right now.
    readonly property bool held: root._heldBy !== null

    property var _heldBy: null

    // A function, never a binding: a change handler runs before the bindings on the
    // same property have followed it.
    function _sync() {
        const p = root.player;
        const want = root.active && !!p && typeof p.holdTick === "function" ? p : null;
        if (want === root._heldBy)
            return;
        if (root._heldBy)
            root._heldBy.releaseTick(root);
        root._heldBy = want;
        if (want)
            want.holdTick(root);
    }

    onPlayerChanged: root._sync()
    onActiveChanged: root._sync()
    Component.onCompleted: root._sync()
    Component.onDestruction: {
        if (root._heldBy)
            root._heldBy.releaseTick(root);
        root._heldBy = null;
    }
}
