pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects

import "../theme"
import "../scroll"

// =============================================================================
// CardViewCycler.qml -- several views of one card, cycled by a wheel.
//
// A card with several views of the same data lays this over itself
// (anchors.fill: the card, declared LAST so it draws on top) and feeds it the
// wheel on the axis that cycles:
//
//     CardViewCycler {
//         id: cycler
//         anchors.fill: parent            // the CARD's rect
//         views: strip.views              // [{ id, label }]
//         orientation: "vertical"         // dots down the right padding
//         padding: 12; radius: 14
//         fontFamily: "Audiowide"
//         bevelWidth: popup.insetBevelWidth; shadowWidth: popup.insetShadowWidth
//         shadowFalloff: popup.insetShadowFalloff; bevelColor: popup.cardBevelColor
//     }
//     strip.viewIndex: cycler.currentIndex
//
//     // the host's one wheel reader, per event on the cycling axis:
//     cycler.feed(units, fromPixels)     // units > 0 = next view
//     cycler.end()                       // fingers lifted / idle
//
// WHAT IT DRAWS: the title of the view appears at the centre of the card in
// the same fashion as LlmPopup's drop overlay (a file hovered over the
// conversation): ONE eased presence fraction drives both the scale (overlayScaleFrom -> 1,
// out of the centre) and the opacity of a carved box with a translucent
// ground fill (the bevel fades to transparent, so the box is an EDGE drawn
// onto the card rather than a card over it), with the label front and centre
// casting a blurred shadow down through the box onto the content.
//
//   * The box is in on the FIRST step of a gesture and held while the wheel
//     keeps feeding -- any feed, not only a step, so a slow drag whose steps
//     are further apart than the linger keeps it; the text swaps instantly
//     under it. It leaves `overlayLingerMs` after end() -- or after the last
//     feed, when no end arrives. Only the start and the stop of a gesture
//     animate.
//   * The dots (a faint array, the current view highlighted) live in the
//     card's padding band: down the RIGHT band for
//     "vertical", along the BOTTOM band for "horizontal". Shown on any feed
//     (a sub-threshold drift included: the scroll has started) and
//     while the pointer is over the band; out `dotsLingerMs` after the last
//     activity, `dotsHoverLingerMs` after the pointer leaves. The current view
//     is an accent bead sliding along the row on one eased position.
//   * Hovering a dot fades in its label beside the column (left of it,
//     right-aligned) or above the row. ONE label, latched to the last hovered
//     dot: moving along the dots swaps its text and place instantly, only its
//     presence fades -- two labels never crossfade through each other.
//   * A dot is clicked by its own small MouseArea, sized to the band across
//     and to the pitch along, so it never reaches over the card's content.
//     The band's hover is a HoverHandler on the CARD (see Input): it takes no
//     buttons and blocks no hover, so a link whose area runs under the band's
//     slack keeps its clicks, its hover ground and its hand cursor.
//
// THE WHEEL TRAP. feed() runs inside a wheel delivery, and a layer flipped or
// an item created there crashes the delivery agent. Nothing here is created
// per view (the dot Repeaters take the view COUNT), and the title shadow's
// blur layer is enabled PERMANENTLY on an item hidden by `visible` while the
// box is absent: a hidden layer renders nothing and costs no frame, and there
// is no enable to defer. The same holds for the label's.
//
// AT REST nothing ticks: the three timers are single-shot and stop, every
// fraction sits at 0 or 1, and the box and the dots are `visible: false`,
// so a settled card asks for no frames.
// =============================================================================
Item {
    id: root

    // Device px per design px here (the nearest ScaleRoot's, else the window's): the layers below are made at the glass's resolution.
    DeviceScale {
        id: dev
    }

    // ---- Contract -----------------------------------------------------------
    property var views: []
    property int currentIndex: 0
    property string orientation: "vertical"   // "vertical" | "horizontal"
    property real padding: 12
    property real radius: 14
    property string fontFamily: "Inter"
    property int titleSize: 20
    // Wheel units per step. A NOTCH is a mouse wheel's (angleDelta 120, no
    // pixelDelta): one notch, one view. A device that reports pixels -- a
    // touchpad -- sends a stream of small angle deltas, and 120 of them is a
    // finger drift of a few millimetres, which would overshoot: 1000
    // is the view switcher's own detent (TabSelector.swipeThreshold).
    property real notchThreshold: 120
    property real pixelThreshold: 1000
    // After a step, the wheel is not read for this long: a fast flick moves
    // one view per cooldown instead of racing through the ring.
    property int stepCooldownMs: 200
    property bool wrap: true

    signal selected(int index)

    // ---- The title box ---------------------------------------------------------
    // Distance of the box from the card's rim. 0 lays the box's edge on the
    // card's own: the carve deepens and the veil covers the content to the rim.
    property real overlayInset: 0
    // The title box's corner radius. By default the card's own, shrunk by the
    // inset (concentric); a host whose overlay lies over a box of its own (the
    // wiki's hero well) passes that box's radius so the two curves coincide.
    property real overlayRadius: Math.max(0, root.radius - root.overlayInset)
    // The box's carve; hosts bind the popup's inset knobs. The defaults are
    // ShadowBox's own curve and the theme's bevel.
    property real bevelWidth: 1.5
    property real shadowWidth: 4
    property real shadowFalloff: 1
    property color bevelColor: Theme.bevel
    // The veil: the card's ground at this alpha over the content.
    property color groundColor: Theme.listBox
    property real veilAlpha: 0.45
    // The title and its shadow together: below 1 the view's name reads as
    // printed on the veil rather than laid over it.
    property real titleOpacity: 1
    property real overlayScaleFrom: 0.86
    // The title box held up by the host for as long as it says (the bridge's cast while its stream reloads), the same box a
    // step brings; one view's cycler is then only that box (no dots, no input).
    property bool held: false
    property int overlayFadeMs: 140
    property int overlayLingerMs: 650
    // Also show the title when a DOT is clicked (the label beside the dot
    // already names the view; the box confirms the change).
    property bool overlayOnClick: true
    // The title's shadow: a blurred copy sunk below it (the hover label's
    // takes the same opacity and blur at its own offset).
    property real shadowOffset: 4
    property real shadowOpacity: 0.4
    property real shadowBlur: 0.7
    property int shadowBlurMax: 16

    // ---- The dots ------------------------------------------------------------------
    property real dotSize: 6
    property real activeDotSize: 6
    property real dotPitch: 12
    property real dotOpacity: 0.55
    property int dotsFadeMs: 160
    property int dotsLingerMs: 1200
    property int dotsHoverLingerMs: 300
    property int dotMoveMs: 260
    // How far the band's hover reaches past the padding into the content, and
    // past the first and last dot along the band.
    property real hoverSlack: 6
    property int labelSize: 11
    property real labelGap: 6
    property int labelFadeMs: 160
    property real labelShadowOffset: 2
    // The patch of ground behind a hovered label: how far it reaches past the
    // words, how opaque it is and how soft its edge.
    property real labelKnockPad: 12
    property real labelKnockAlpha: 1
    property int labelKnockBlur: 8

    // ---- State -----------------------------------------------------------------------
    readonly property int _n: root.views ? root.views.length : 0
    readonly property bool _vertical: root.orientation !== "horizontal"
    // The detent: notch / touchpad thresholds and the step cooldown
    // (WheelStepper, shared with the weather detail's day swipe).
    WheelStepper {
        id: stepper
        notchThreshold: root.notchThreshold
        pixelThreshold: root.pixelThreshold
        stepCooldownMs: root.stepCooldownMs
    }
    property bool _overlayOn: false
    property bool _dotsActive: false
    property bool _hoverHeld: false
    property int _hoverDot: -1
    property int _labelIndex: 0
    readonly property bool _hovering: root._bandHovered || root._hoverDot >= 0

    property real _overlayF: root._overlayOn || root.held ? 1 : 0
    Behavior on _overlayF {
        NumberAnimation {
            duration: root.overlayFadeMs
            easing.type: Easing.OutCubic
        }
    }
    property real _dotsF: root._n > 1 && (root._dotsActive || root._hoverHeld) ? 1 : 0
    Behavior on _dotsF {
        NumberAnimation {
            duration: root.dotsFadeMs
            easing.type: Easing.OutCubic
        }
    }
    property real _labelF: root._hoverDot >= 0 ? 1 : 0
    Behavior on _labelF {
        NumberAnimation {
            duration: root.labelFadeMs
            easing.type: Easing.OutCubic
        }
    }
    // The bead's place along the row, in dot slots. Placed, not slid, while
    // the dots are away: they come back with the bead already home.
    property real _bead: root.currentIndex
    Behavior on _bead {
        enabled: root._dotsF > 0
        NumberAnimation {
            duration: root.dotMoveMs
            easing.type: Easing.OutCubic
        }
    }

    // For the probe: every timer stopped and every fraction at its target.
    readonly property bool _idle: !overlayTimer.running && !dotsTimer.running && !hoverTimer.running
        && root._overlayF === (root._overlayOn || root.held ? 1 : 0)
        && root._dotsF === (root._n > 1 && (root._dotsActive || root._hoverHeld) ? 1 : 0)
        && root._labelF === (root._hoverDot >= 0 ? 1 : 0)
        && root._bead === root.currentIndex
    readonly property string _shownTitle: title.text

    function _labelOf(i) {
        const v = i >= 0 && i < root._n ? root.views[i] : null;
        return v && v.label !== undefined ? String(v.label) : "";
    }

    // ---- API -------------------------------------------------------------------------
    // A jump that counts as the user's (a dot click, the mockup's view picker):
    // it shows the dots and -- with overlayOnClick -- the title, and emits
    // selected(). A host restoring state writes currentIndex instead.
    function select(index) {
        root._jump(index, true);
    }
    function feed(units, fromPixels) {
        if (!(units !== 0) || root._n < 2)
            return;
        // Any feed holds a box that is up, not only a step: in a slow drag
        // one step takes longer than the linger while the fingers never
        // stopped. Only a step brings the box up.
        if (root._overlayOn)
            overlayTimer.restart();
        root._touchDots();
        // A step against a clamped end (wrap off) still shows the title: the
        // box says where the wheel stopped. With a cooldown a feed takes at
        // most ONE step and drops the rest of what it carried.
        const steps = stepper.feed(units, fromPixels);
        const dir = steps > 0 ? 1 : -1;
        for (let i = 0; i < Math.abs(steps); i++) {
            root._showOverlay();
            root._jump(root.currentIndex + dir, false);
        }
    }
    function end() {
        stepper.end();
        if (root._overlayOn)
            overlayTimer.restart();
        if (root._dotsActive)
            dotsTimer.restart();
    }

    // ---- Internals ---------------------------------------------------------------------
    function _jump(index, fromCall) {
        const n = root._n;
        if (n === 0)
            return;
        const i = root.wrap ? ((index % n) + n) % n : Math.max(0, Math.min(n - 1, index));
        if (i === root.currentIndex)
            return;
        if (fromCall) {
            root._touchDots();
            if (root.overlayOnClick)
                root._showOverlay();
        }
        root.currentIndex = i;
        root.selected(i);
    }
    function _showOverlay() {
        root._overlayOn = true;
        overlayTimer.restart();
    }
    function _touchDots() {
        root._dotsActive = true;
        dotsTimer.restart();
    }

    Timer {
        id: overlayTimer
        interval: root.overlayLingerMs
        onTriggered: root._overlayOn = false
    }
    Timer {
        id: dotsTimer
        interval: root.dotsLingerMs
        onTriggered: root._dotsActive = false
    }
    Timer {
        id: hoverTimer
        interval: root.dotsHoverLingerMs
        onTriggered: root._hoverHeld = false
    }
    on_HoveringChanged: {
        if (root._hovering) {
            hoverTimer.stop();
            root._hoverHeld = true;
        } else if (root._hoverHeld) {
            hoverTimer.restart();
        }
    }
    on_HoverDotChanged: {
        if (root._hoverDot >= 0)
            root._labelIndex = root._hoverDot;
    }
    onViewsChanged: {
        if (root.currentIndex >= root._n && root._n > 0)
            root.currentIndex = root._n - 1;
    }

    // ---- Geometry (the cycler's own coordinates) -----------------------------------------
    readonly property real _span: root._n > 0 ? (root._n - 1) * root.dotPitch + root.dotSize : 0
    // Along the band: where the first dot's box begins.
    readonly property real _start: Math.round(((root._vertical ? root.height : root.width) - root._span) / 2)
    // Across the band: the dots' centre line, the middle of the padding.
    readonly property real _across: root._vertical ? root.width - root.padding / 2 : root.height - root.padding / 2
    function _alongOf(i) {
        return root._start + root.dotSize / 2 + i * root.dotPitch;
    }
    // A dot's centre, for hosts and probes.
    function _dotCentre(i) {
        const a = root._alongOf(i);
        return root._vertical ? Qt.point(root._across, a) : Qt.point(a, root._across);
    }

    FontMetrics {
        id: fmLabel
        font.family: root.fontFamily
        font.pixelSize: root.labelSize
    }
    TextMetrics {
        id: tmTitle
        font: title.font
        text: title.text
    }
    TextMetrics {
        id: tmLabel
        font: label.font
        text: label.text
    }

    // ---- The title box -----------------------------------------------------------------
    Item {
        id: overlay
        x: root.overlayInset
        y: root.overlayInset
        width: Math.max(0, root.width - 2 * root.overlayInset)
        height: Math.max(0, root.height - 2 * root.overlayInset)
        visible: root._overlayF > 0
        opacity: root._overlayF
        scale: root.overlayScaleFrom + (1 - root.overlayScaleFrom) * root._overlayF
        transformOrigin: Item.Center

        ShadowBox {
            anchors.fill: parent
            baseRadius: root.overlayRadius
            surfaceColor: "transparent"
            bevelColor: root.bevelColor
            shadowColor: Theme.border
            backgroundColor: Qt.rgba(root.groundColor.r, root.groundColor.g, root.groundColor.b, root.veilAlpha)
            bevelWidth: root.bevelWidth
            shadowWidth: root.shadowWidth
            shadowFalloff: root.shadowFalloff
        }

        readonly property real _titleW: Math.min(Math.ceil(tmTitle.advanceWidth), Math.max(0, overlay.width - 2 * root.padding))
        readonly property real _titleH: Math.ceil(title.implicitHeight)
        readonly property real _titleX: Math.round((overlay.width - overlay._titleW) / 2)
        readonly property real _titleY: Math.round((overlay.height - overlay._titleH) / 2)

        Text {
            id: titleShadow
            x: overlay._titleX
            y: overlay._titleY + root.shadowOffset
            width: overlay._titleW
            text: title.text
            font: title.font
            elide: Text.ElideRight
            color: Theme.shadowDeep
            opacity: root.shadowOpacity * root.titleOpacity
            layer.enabled: true
            layer.textureSize: dev.texSize(titleShadow.width, titleShadow.height)
            layer.effect: MultiEffect {
                blurEnabled: true
                blur: root.shadowBlur
                blurMax: root.shadowBlurMax
            }
        }
        Text {
            id: title
            x: overlay._titleX
            y: overlay._titleY
            width: overlay._titleW
            text: root._labelOf(root.currentIndex)
            font.family: root.fontFamily
            font.pixelSize: root.titleSize
            font.bold: true
            elide: Text.ElideRight
            color: Theme.textPrimary
            opacity: root.titleOpacity
        }
    }

    // ---- The dots ------------------------------------------------------------------------
    // Paint: hidden outright while absent, so a resting card has none of it.
    Item {
        id: dotsPaint
        anchors.fill: parent
        visible: root._dotsF > 0
        opacity: root._dotsF

        // The hovered dot's name, beside the column or above the row. Under
        // the dots, so its knock-back never dims them.
        Item {
            id: labelBox
            readonly property real _w: Math.ceil(tmLabel.advanceWidth)
            readonly property real _h: Math.ceil(fmLabel.height)
            readonly property real _a: root._alongOf(root._labelIndex)
            readonly property real _dotHalf: Math.max(root.dotSize, root.activeDotSize) / 2
            x: root._vertical
                ? Math.round(root._across - labelBox._dotHalf - root.labelGap - labelBox._w)
                : Math.round(Math.max(root.padding, Math.min(root.width - root.padding - labelBox._w, labelBox._a - labelBox._w / 2)))
            y: root._vertical
                ? Math.round(labelBox._a - labelBox._h / 2)
                : Math.round(root._across - labelBox._dotHalf - root.labelGap - labelBox._h)
            width: labelBox._w
            height: labelBox._h
            visible: root._labelF > 0
            opacity: root._labelF

            // The knock-back: a blurred patch of the card's ground behind the
            // words, so they read over the content without a box around them
            // (a local veil, the title box's own device; not a tooltip).
            Rectangle {
                x: -root.labelKnockPad
                y: -Math.round(root.labelKnockPad / 2)
                width: labelBox.width + 2 * root.labelKnockPad
                height: labelBox.height + 2 * Math.round(root.labelKnockPad / 2)
                radius: height / 2
                color: root.groundColor
                opacity: root.labelKnockAlpha
                layer.enabled: true
                layer.textureSize: dev.texSize(width, height)
                layer.effect: MultiEffect {
                    blurEnabled: true
                    blur: 1
                    blurMax: root.labelKnockBlur
                }
            }
            Text {
                id: labelShadow
                x: 0
                y: root.labelShadowOffset
                text: label.text
                font: label.font
                color: Theme.shadowDeep
                opacity: root.shadowOpacity
                layer.enabled: true
                layer.textureSize: dev.texSize(labelShadow.width, labelShadow.height)
                layer.effect: MultiEffect {
                    blurEnabled: true
                    blur: root.shadowBlur
                    blurMax: root.shadowBlurMax
                }
            }
            Text {
                id: label
                x: 0
                y: 0
                text: root._labelOf(root._labelIndex)
                font.family: root.fontFamily
                font.pixelSize: root.labelSize
                color: Theme.textPrimary
            }
        }

        Repeater {
            model: root._n
            Rectangle {
                id: dot
                required property int index
                readonly property real _a: root._alongOf(dot.index)
                x: root._vertical ? root._across - root.dotSize / 2 : dot._a - root.dotSize / 2
                y: root._vertical ? dot._a - root.dotSize / 2 : root._across - root.dotSize / 2
                width: root.dotSize
                height: root.dotSize
                radius: root.dotSize / 2
                color: Theme.textFaint
                opacity: root.dotOpacity
            }
        }
        Rectangle {
            id: bead
            readonly property real _a: root._alongOf(root._bead)
            x: root._vertical ? root._across - root.activeDotSize / 2 : bead._a - root.activeDotSize / 2
            y: root._vertical ? bead._a - root.activeDotSize / 2 : root._across - root.activeDotSize / 2
            width: root.activeDotSize
            height: root.activeDotSize
            radius: root.activeDotSize / 2
            color: Theme.accent
        }
    }

    // ---- Input -----------------------------------------------------------------------------
    // The band's hover. NOT a hover item over the band: in Qt 6.11 a
    // HoverHandler (even `blocking: false`) or a hover MouseArea on an item
    // stacked over a link takes the link's hover away -- its ground and its
    // hand cursor go dark wherever the band reaches into the content. A
    // handler on an ANCESTOR is hovered alongside whatever its children
    // accept, so the handler sits on the card (this item's parent) and the
    // band is arithmetic on its point. Measured both ways.
    HoverHandler {
        id: cardHover
        parent: root.parent
    }
    // Always present (an absent dot still has to be found by the pointer),
    // the padding band plus `hoverSlack` into the content and past the ends.
    Item {
        id: band
        readonly property real _lead: Math.max(0, root._start - root.hoverSlack)
        readonly property real _len: root._n > 1 ? root._span + 2 * root.hoverSlack : 0
        readonly property real _deep: root.padding + root.hoverSlack
        x: root._vertical ? root.width - band._deep : band._lead
        y: root._vertical ? band._lead : root.height - band._deep
        width: root._vertical ? band._deep : band._len
        height: root._vertical ? band._len : band._deep
    }
    readonly property bool _bandHovered: {
        if (!cardHover.hovered || root._n < 2)
            return false;
        const p = cardHover.point.position;
        const x = p.x - root.x;
        const y = p.y - root.y;
        return x >= band.x && x < band.x + band.width && y >= band.y && y < band.y + band.height;
    }
    // A MOUSE OVER THE DOTS of a row that is swiped sideways: one notch is one view (an upright ring is the host's whole card's).
    WheelArea {
        x: band.x
        y: band.y
        width: band.width
        height: band.height
        enabled: root._n > 1 && !root._vertical
        turned: ev => {
            ev.accepted = ev.device === "wheel" && ev.angleDelta.y !== 0;
            if (ev.accepted)
                root.feed(120 * ev.steps, false);
        }
    }
    Repeater {
        model: root._n > 1 ? root._n : 0
        MouseArea {
            id: hit
            required property int index
            readonly property real _a: root._alongOf(hit.index)
            x: root._vertical ? root.width - root.padding : Math.round(hit._a - root.dotPitch / 2)
            y: root._vertical ? Math.round(hit._a - root.dotPitch / 2) : root.height - root.padding
            width: root._vertical ? root.padding : root.dotPitch
            height: root._vertical ? root.dotPitch : root.padding
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onContainsMouseChanged: {
                if (hit.containsMouse)
                    root._hoverDot = hit.index;
                else if (root._hoverDot === hit.index)
                    root._hoverDot = -1;
            }
            onClicked: root.select(hit.index)
        }
    }
}
