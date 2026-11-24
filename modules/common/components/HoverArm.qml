import QtQuick

// =============================================================================
// HoverArm.qml -- "the keyboard is yours once the pointer has MOVED onto you".
//
// For anything that may take the keyboard from the window the user is typing
// in (the auth toast): it must never do so because it APPEARED under a resting
// pointer, only because the pointer was moved onto it. Measured on Hyprland
// 0.56 (measured):
//   - a surface that maps under a resting pointer gets no event at all; the
//     enter arrives WITH the first motion, at the moved point;
//   - inside a surface the pointer is already in, Qt RE-DELIVERS hover at the
//     last point when an item appears under it (and again around key events).
// So "hovered" proves nothing. What does is a motion the WINDOW saw: a pointer
// event whose scene point differs from the last one the window saw. The arm
// counts those on the window's content item and is `armed` while the target
// is hovered and the count has grown since the arm became `active`. The FIRST
// point after that is only where the pointer stands, never a motion: Hyprland
// 0.57 gives a surface that maps under a resting pointer its enter at once.
//
//   HoverArm { id: arm; target: card; active: card.visible }
//   keyboardFocusRequest: arm.armed ? "exclusive" : "none"
//
// `sticky` (latch()) keeps it armed with the pointer gone: after the first
// key, the keys stay until Enter / Escape / a click elsewhere.
// The host reports Enter and Escape with release(); release(true) also asks
// for a NEW motion before it arms again (Escape: let go even under the
// pointer). A click elsewhere it sees itself: under an Exclusive keyboard a
// click on another window reaches NOBODY, so the host grows its input mask
// over the whole output while `sticky && !hovered` (the catch) and the press
// lands on its own window, where a passive handler on the content item hears
// it outside the target -> outsidePressed(), and released when
// `releaseOnOutsidePress`.
// =============================================================================
QtObject {
    id: root

    property Item target: null
    // Arming is considered only while true; the motion baseline is taken
    // when it turns true.
    property bool active: true
    // false = armed on hover alone (a probe's ARM).
    property bool requireMotion: true
    property bool releaseOnOutsidePress: true
    // A press in the target's window outside the target (the catch's click).
    signal outsidePressed()

    readonly property bool hovered: root._hover ? root._hover.hovered : false
    readonly property bool armed: root.active && root.target !== null
        && (root.sticky || (root.hovered && (!root.requireMotion || root._motions > root._baseline)))
    readonly property bool sticky: root._sticky

    function latch() {
        if (root.armed)
            root._sticky = true;
    }
    function release(needMotion) {
        root._sticky = false;
        if (needMotion)
            root._baseline = root._motions;
    }

    property bool _sticky: false
    property int _motions: 0
    property int _baseline: 0
    property real _lastX: -1
    property real _lastY: -1
    property HoverHandler _hover: null
    property HoverHandler _window: null
    property PointHandler _press: null

    onActiveChanged: {
        root._baseline = root._motions;
        root._lastX = -1;
        root._lastY = -1;
        if (!root.active)
            root._sticky = false;
    }
    onTargetChanged: root._attach()
    Component.onCompleted: root._attach()
    Component.onDestruction: root._detach()

    property Component _handlerComp: Component {
        HoverHandler {}
    }
    property Component _pressComp: Component {
        // passive: every item under the press still gets it
        PointHandler {
            acceptedButtons: Qt.AllButtons
        }
    }

    function _detach() {
        if (root._hover) {
            root._hover.destroy();
            root._hover = null;
        }
        if (root._window) {
            root._window.pointChanged.disconnect(root._onWindowPoint);
            root._window.destroy();
            root._window = null;
        }
        if (root._press) {
            root._press.activeChanged.disconnect(root._onPress);
            root._press.destroy();
            root._press = null;
        }
    }

    function _attach() {
        root._detach();
        const t = root.target;
        if (!t)
            return;
        root._hover = root._handlerComp.createObject(t);
        const content = t.Window.contentItem;
        if (content) {
            root._window = root._handlerComp.createObject(content);
            root._window.pointChanged.connect(root._onWindowPoint);
            root._press = root._pressComp.createObject(content);
            root._press.activeChanged.connect(root._onPress);
        } else {
            // not in a window yet: try again when it is
            t.Window.contentItemChanged.connect(root._attach);
        }
    }

    function _onPress() {
        const h = root._press;
        const t = root.target;
        if (!h || !h.active || !t || !root.active)
            return;
        const p = t.mapFromItem(null, h.point.scenePosition.x, h.point.scenePosition.y);
        if (p.x >= 0 && p.y >= 0 && p.x < t.width && p.y < t.height)
            return;
        root.outsidePressed();
        if (root.releaseOnOutsidePress)
            root.release(false);
    }

    function _onWindowPoint() {
        const h = root._window;
        if (!h || !h.hovered)
            return;
        const p = h.point.scenePosition;
        if (p.x === root._lastX && p.y === root._lastY)
            return;
        const first = root._lastX < 0;
        root._lastX = p.x;
        root._lastY = p.y;
        if (!first)
            root._motions++;
    }
}
