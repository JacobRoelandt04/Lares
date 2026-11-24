pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"

// =============================================================================
// OsdPill.qml -- the OSD while a window is fullscreen (CONTRACT §7): a capsule
// at the top centre of the screen, click-through, that is BORN as a dot, grows
// DOWN into a vertical capsule, then WIDENS to its full width; the reverse on
// the way out.
//
//   pillT   the shape's clock, 0..2 (= _g + _w):  0 a dot,  1 a vertical capsule,  2 full width
//             height = lerp(dotD, H, _g)      _g, 0..1: the growth down
//             width  = lerp(dotD, W, _w)      _w, 0..1: the widening
//           OPENING is one motion: _g and _w run on the same parallel animation, the widening
//           starting `pillOpenLeadMs` into the growth (while the capsule is still arriving at its
//           height, so there is no standstill between the two). Closing runs them one after the
//           other (narrow, then shrink), as before.
//   content (OsdContent, orientation "pill", not interactive) fades in (`pillFadeInMs`) as soon
//           as the widening has carried the capsule's ends past the content's ink
//           (`pillFadeAt`, the share of the widening: the largest any kind's ink needs, measured
//           by tools/dev/osd_pill_open_probe.sh), and out BEFORE the reverse starts. Nothing is
//           ever cut by the capsule.
//
//   present(req)  first: spawn. Same kind and key: the content updates in
//                 place. Another kind (or key): a CURTAIN -- the content fades
//                 out, W and H ease to the new kind's extent (260 ms OutCubic),
//                 the new content fades in.
//   dismiss()     fade out, narrow, shrink, `closed()`.
//   present(req, true) / a present of the shown key with `hidden` changed: THE BALL. The
//                 content fades, the capsule narrows and shrinks to the dot -- which stays
//                 at full presence -- rises until `pillBallShow` of it is below the screen's
//                 top edge (`offsetY`, which the host adds to its place: the window's top IS
//                 the screen's, so the rest is cut there) and fades over `pillBallFadeMs` to
//                 `pillBallFaint`. The content keeps its payload (renewals land in place,
//                 unseen). Shown again (hidden false): the ball comes back to full presence and
//                 down to its place, then grows and widens as at birth. A dismiss of the ball
//                 fades it out where it is.
//                 `ballRect` (this item's px, empty unless the ball is parked) is where the
//                 host hears the pointer for `revealRequested()`; `hideRect` the content's hide
//                 button while the content is out (`hideRequested()` from it).
//
// A raised ShadowBox (a drop shadow outside, a highlight inside) with
// `shadowToAlpha`: it floats over arbitrary content, so the shadow blends to
// transparent, not to a surface colour. `implicitWidth/Height` are the CURRENT
// box; the host (OsdPillWindow) centres it at the top.
//
// Test hooks: `holdAt(t, req, contentOpacity)` pins a pose (the sheets and the
// filmstrip use it), `contentOpacity` is read by the probe.
// =============================================================================
Item {
    id: root

    property var style: null
    property real renderScale: 1

    readonly property real pillT: root._t
    readonly property bool showing: root._showing
    readonly property real contentOpacity: root._contentF
    signal closed()
    // A clock of it runs (the ball parked and faded is at rest: its window's ink stands still).
    readonly property bool moving: openAnim.running || grow.running || widen.running || narrow.running || shrink.running || fadeIn.running
        || fadeOut.running || resize.running || lift.running || lower.running || dim.running || brighten.running || ballOut.running
    // The content's hide button was clicked; the host's pointer reached the parked ball (`reveal()`).
    signal hideRequested()
    signal revealRequested()

    // THE BALL (the header).
    readonly property bool hidden: root._hidden
    // Parked: risen and still hidden -- where the pointer brings it back.
    readonly property bool ballParked: root._hidden && root._lift >= 1
    // How far up the host draws the pill (<= 0, design px): the ball's rise.
    readonly property real offsetY: root._lift * root._liftTo
    readonly property real _liftTo: -(root._style.pillTop + (1 - root._style.pillBallShow) * root._style.pillDotD)
    // The parked ball's hover area in this item's px (above it the screen ends: the host clips at its window's top).
    readonly property rect ballRect: root.ballParked
        ? Qt.rect(-root._style.pillBallHoverPad, 0, root.width + 2 * root._style.pillBallHoverPad, root.height + root._style.pillBallHoverPad)
        : Qt.rect(0, 0, 0, 0)
    // The content's hide button, while the content is out and not on its way to the ball.
    readonly property rect hideRect: !root._hidden && root._t >= 2 && root._contentF > 0.5 && content.hideRect.width > 0
        ? Qt.rect(content.x + content.hideRect.x, content.y + content.hideRect.y, content.hideRect.width, content.hideRect.height)
        : Qt.rect(0, 0, 0, 0)
    function reveal() {
        if (root.ballParked)
            root.revealRequested();
    }

    OsdStyle {
        id: ownStyle
    }
    readonly property var _style: root.style ? root.style : ownStyle

    // ---- state ---------------------------------------------------------------
    property real _g: 0
    property real _w: 0
    readonly property real _t: root._g + root._w
    property bool _showing: false
    property real _contentF: 0
    property string _kind: ""
    property string _key: ""
    property var _payload: ({})
    property real _W: 0
    property real _H: 0
    property var _pending: null
    // +1 coming out, -1 going away.
    property int _dir: 1
    property string _after: "narrow"
    // The ball: the target is the ball (`_hidden`); the box is drawn as one (`_ball`: its presence is `_ballOpacity`, not the
    // clock's); how far it has risen (0..1).
    property bool _hidden: false
    property bool _ball: false
    property real _ballOpacity: 1
    property real _lift: 0
    property bool _pendingHidden: false

    function _extent(kind) {
        return root._style.extentOf(kind, "pill");
    }
    function _keyOf(req) {
        return req.kind + ":" + (req.key !== undefined ? req.key : "");
    }

    // ---- the box ----------------------------------------------------------------
    readonly property real boxH: root._lerp(root._style.pillDotD, root._H, root._g)
    readonly property real boxW: root._lerp(root._style.pillDotD, root._W, root._w)
    function _lerp(a, b, f) {
        return a + (b - a) * f;
    }

    // Whole pixels: the capsule's edges stay on the grid as it grows.
    implicitWidth: Math.round(root.boxW)
    implicitHeight: Math.round(root.boxH)
    visible: root._showing

    ShadowBox {
        id: box
        anchors.fill: parent
        // The dot is born by fading in over the first fifth of the first phase; the ball has its own presence.
        opacity: root._ball ? root._ballOpacity : Math.min(1, root._g / 0.2)
        raised: true
        shadowToAlpha: true
        baseRadius: Math.min(width, height) / 2
        surfaceColor: Theme.surface
        bevelColor: Theme.bevel
        shadowColor: Theme.shadowDeep
        backgroundColor: Theme.surface
        bevelWidth: root._style.pillBevel
        shadowWidth: root._style.pillShadow
        shadowEdgeAlpha: root._style.pillShadowAlpha
    }

    OsdContent {
        id: content
        kind: root._kind
        orientation: "pill"
        interactive: false
        payload: root._payload
        style: root._style
        renderScale: root.renderScale
        width: root._W
        height: root._H
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        // (a ball fading out takes a content still fading with it)
        opacity: root._contentF * (root._ball ? root._ballOpacity : 1)
        visible: root._contentF > 0
        onHideRequested: root.hideRequested()
    }

    // ---- the clock ----------------------------------------------------------------
    // THE OPEN: growth and widening on one parallel animation, the widening `_lead` ms behind (0 when the capsule already has
    // its height). Both OutCubic: the widening begins at its fastest while the growth is still easing in, so the speed
    // never drops to nothing between them. The content's fade is started from `_w` (`onWChanged`) while this still runs.
    property int _lead: 0
    ParallelAnimation {
        id: openAnim
        NumberAnimation {
            id: grow
            target: root
            property: "_g"
            to: 1
            duration: root._style.pillOpenGrowMs
            easing.type: Easing.OutCubic
        }
        SequentialAnimation {
            PauseAnimation {
                duration: root._lead
            }
            NumberAnimation {
                id: widen
                target: root
                property: "_w"
                to: 1
                duration: root._style.pillOpenWidenMs
                easing.type: Easing.OutCubic
            }
        }
        onFinished: {
            // a ball grown back into the capsule: the clock's presence (1 from here) takes over
            root._ball = false;
            if (root._dir > 0)
                root._forward();
        }
    }
    on_WChanged: {
        if (root._dir > 0 && openAnim.running && !root._hidden && root._contentF < 1 && !fadeIn.running
                && root._w >= root._style.pillFadeAt)
            fadeIn.restart();
    }
    NumberAnimation {
        id: narrow
        target: root
        property: "_w"
        to: 0
        duration: root._style.pillWidenMs
        easing.type: Easing.InCubic
        onFinished: if (root._dir < 0) root._backward()
    }
    NumberAnimation {
        id: shrink
        target: root
        property: "_g"
        to: 0
        duration: root._style.pillGrowMs
        easing.type: Easing.InCubic
        onFinished: {
            if (root._dir >= 0)
                return;
            if (root._hidden) {
                // the dot now: the card it will grow back into is the one it holds (a swap taken unseen kept the old size till here)
                const e = root._extent(root._kind);
                root._W = e.w;
                root._H = e.h;
                lift.restart();
            } else {
                root._finishClose();
            }
        }
    }
    // THE BALL's clocks: the rise (and the way back down), its fade to faint, its fade back to full or out.
    NumberAnimation {
        id: lift
        target: root
        property: "_lift"
        to: 1
        duration: root._style.pillBallLiftMs
        easing.type: Easing.OutCubic
        onFinished: dim.restart()
    }
    NumberAnimation {
        id: lower
        target: root
        property: "_lift"
        to: 0
        duration: root._style.pillBallLiftMs
        easing.type: Easing.OutCubic
        onFinished: root._forward()
    }
    NumberAnimation {
        id: dim
        target: root
        property: "_ballOpacity"
        to: root._style.pillBallFaint
        duration: root._style.pillBallFadeMs
        easing.type: Easing.InOutSine
    }
    NumberAnimation {
        id: brighten
        target: root
        property: "_ballOpacity"
        to: 1
        duration: root._style.pillFadeMs
        easing.type: Easing.OutCubic
    }
    NumberAnimation {
        id: ballOut
        target: root
        property: "_ballOpacity"
        to: 0
        duration: root._style.pillFadeMs
        easing.type: Easing.OutCubic
        onFinished: root._finishClose()
    }
    NumberAnimation {
        id: fadeIn
        target: root
        property: "_contentF"
        to: 1
        duration: root._style.pillFadeInMs
        easing.type: Easing.OutCubic
    }
    NumberAnimation {
        id: fadeOut
        target: root
        property: "_contentF"
        to: 0
        duration: root._style.pillFadeMs
        easing.type: Easing.OutCubic
        onFinished: {
            if (root._after === "swap")
                root._applyPending();
            else
                root._backward();
        }
    }
    // A different kind's size: W and H ease together, then the content returns.
    ParallelAnimation {
        id: resize
        NumberAnimation {
            target: root
            property: "_W"
            to: root._wTo
            duration: root._style.pillSwapMs
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: root
            property: "_H"
            to: root._hTo
            duration: root._style.pillSwapMs
            easing.type: Easing.OutCubic
        }
        onFinished: root._forward()
    }
    property real _wTo: 0
    property real _hTo: 0

    function _stopAll() {
        openAnim.stop();
        narrow.stop();
        shrink.stop();
        fadeIn.stop();
        fadeOut.stop();
        resize.stop();
        lift.stop();
        lower.stop();
        dim.stop();
        brighten.stop();
        ballOut.stop();
    }

    // Come out from wherever the clock is: grow, widen, then the content.
    function _forward() {
        root._dir = 1;
        // out of the ball past the dot's birth fade: the clock's presence is the ball's (1) from here
        if (!root._hidden && root._lift <= 0 && root._g >= 0.2)
            root._ball = false;
        if (root._lift > 0) {
            // a ball comes down first, at full presence
            brighten.restart();
            lower.restart();
        } else if (root._g < 1 || root._w < 1) {
            // (the widening waits for the growth only when there is growth to wait for)
            root._lead = root._g < 1 ? root._style.pillOpenLeadMs : 0;
            openAnim.restart();
        } else if (root._contentF < 1 && !fadeIn.running)
            fadeIn.restart();
    }
    // Go away from wherever the clock is: the content first, then narrow, shrink.
    function _backward() {
        root._dir = -1;
        if (root._w > 0)
            narrow.restart();
        else if (root._g > 0)
            shrink.restart();
        else
            root._finishClose();
    }
    function _finishClose() {
        root._showing = false;
        root._g = 0;
        root._w = 0;
        root._contentF = 0;
        root._kind = "";
        root._key = "";
        root._hidden = false;
        root._ball = false;
        root._ballOpacity = 1;
        root._lift = 0;
        root.closed();
    }

    // Into the ball from wherever the clock is (the content first, then narrow, shrink, rise, fade), or back out of it.
    function _setHidden(on) {
        if (on === root._hidden)
            return;
        root._stopAll();
        root._hidden = on;
        if (on) {
            root._ball = true;
            root._ballOpacity = 1;
            root._dir = -1;
            root._after = "narrow";
            if (root._contentF > 0)
                fadeOut.restart();
            else
                root._backward();
        } else {
            root._forward();
        }
    }

    // ---- the API ------------------------------------------------------------------
    function present(req, hidden) {
        const hide = hidden === true;
        const k = root._keyOf(req);
        // (a close in progress: going away and not to the ball)
        const fresh = !root._showing || (root._dir < 0 && !root._hidden);
        if (fresh) {
            // Spawn (or come back from a close that has not finished).
            root._stopAll();
            root._pending = null;
            // the payload BEFORE the kind: the content is made when its kind is set (OsdContent.bornKind)
            root._payload = req;
            root._kind = req.kind;
            root._key = k;
            const e = root._extent(req.kind);
            root._W = e.w;
            root._H = e.h;
            root._after = "narrow";
            if (hide && !root._showing) {
                // born hidden (a hidden card back after another): the dot, already risen, fading in to faint
                root._showing = true;
                root._hidden = true;
                root._ball = true;
                root._g = 0;
                root._w = 0;
                root._contentF = 0;
                root._lift = 1;
                root._ballOpacity = 0;
                root._dir = -1;
                dim.restart();
                return;
            }
            root._showing = true;
            if (hide) {
                root._hidden = false;
                root._setHidden(true);
            } else {
                root._hidden = false;
                root._forward();
            }
        } else if (k === root._key) {
            // The same thing again: the content updates in place (also unseen, in the ball).
            root._payload = req;
            root._setHidden(hide);
        } else {
            root._pendingHidden = hide;
            root._beginSwap(req);
        }
    }

    function dismiss() {
        if (!root._showing || ballOut.running || (root._dir < 0 && !root._hidden && (narrow.running || shrink.running || fadeOut.running)))
            return;
        if (root._hidden || root._lift > 0) {
            // the ball (or on its way there, or back): it fades out where it is
            root._stopAll();
            root._hidden = true;
            root._ball = true;
            root._dir = -1;
            ballOut.restart();
            return;
        }
        root._stopAll();
        root._pending = null;
        root._dir = -1;
        root._after = "narrow";
        if (root._contentF > 0)
            fadeOut.restart();
        else
            root._backward();
    }

    function _beginSwap(req) {
        root._pending = req;
        // Still coming out (the content is not there yet), or in the ball: just take the new one.
        if ((root._t < 2 && root._contentF <= 0 && !fadeIn.running) || root._hidden || root._lift > 0) {
            root._applyPending();
            return;
        }
        root._stopAll();
        root._dir = 1;
        root._after = "swap";
        fadeOut.restart();
    }

    function _applyPending() {
        const req = root._pending;
        root._pending = null;
        if (!req)
            return;
        root._payload = req;
        root._kind = req.kind;
        root._key = root._keyOf(req);
        const e = root._extent(req.kind);
        root._wTo = e.w;
        root._hTo = e.h;
        if (root._pendingHidden || root._hidden) {
            // into (or staying in) the ball: nothing of the new card is seen. Its size is taken now where the box is the dot or
            // comes out of the ball as the new card (a capsule on its way to the ball keeps the size it has; the dot takes the
            // card's when it lands)
            const hide = root._pendingHidden;
            root._pendingHidden = false;
            if (root._t <= 0 || !hide) {
                root._W = e.w;
                root._H = e.h;
            }
            if (hide && root._hidden)
                return;
            root._stopAll();
            if (hide) {
                root._hidden = false;
                root._setHidden(true);
            } else {
                root._hidden = false;
                root._forward();
            }
            return;
        }
        root._dir = 1;
        if (root._t < 2) {
            // Not out yet: nothing is showing, so no curtain.
            root._W = e.w;
            root._H = e.h;
            root._forward();
        } else if (Math.abs(e.w - root._W) < 0.5 && Math.abs(e.h - root._H) < 0.5) {
            root._forward();
        } else {
            resize.restart();
        }
    }

    // Pin a pose: the sheets and the filmstrip draw these.
    function holdAt(t, req, contentOpacity) {
        root._stopAll();
        root._pending = null;
        root._payload = req;
        root._kind = req.kind;
        root._key = root._keyOf(req);
        const e = root._extent(req.kind);
        root._W = e.w;
        root._H = e.h;
        root._showing = true;
        root._g = Math.min(1, t);
        root._w = Math.max(0, t - 1);
        root._contentF = contentOpacity !== undefined ? contentOpacity : (t >= 2 ? 1 : 0);
        root._hidden = false;
        root._ball = false;
        root._lift = 0;
        root._ballOpacity = 1;
    }
    // Pin the ball: risen `lift` (0..1) at presence `opacity` (the sheets and the films).
    function holdBall(req, lift, opacity) {
        root.holdAt(0, req, 0);
        root._hidden = true;
        root._ball = true;
        root._lift = lift;
        root._ballOpacity = opacity;
    }
}
