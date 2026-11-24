pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/scroll"
import ".."

// =============================================================================
// ClipShelf.qml -- the clipboard's strip of typed cards (STAGE3.md has the API).
//
// WHAT IT OWNS. The horizontal Flickable and its ScrollDressing, the pool of
// cards, one BoundaryClock for every card's relative time, one AppLookup for
// every card's source, the focus mark, and the arrival motion.
//
// PAINT OUTSIDE THE RECT. A card's shadow, a lifted card's rise and the well
// around the focused one reach past the card, so the Flickable is the shelf's
// rect grown by `slack` on every side and cards sit `slack` in. The shelf's own
// rect is exactly the cards: at the head the first card's left edge is x = 0.
// The host keeps `slack` (12, the popup's padding) free around it. Only
// shadow and fade paint out there, so nothing is lost to input.
//
// THE POOL. Cards exist only for the window of indices near the view; a card
// leaving the window is released to its kind's pool and the one entering takes
// it, snapped (LauncherGrid's _takeFace/_releaseFace). A list of 1000 entries
// costs a dozen cards.
//
// MOTION (list_animation.md). Only what is on screen animates.
//   * A new copy while `open` arrives as ONE new key in the list: the cards at
//     and after it slide one slot on a single fraction (`slideT`, insertMs),
//     those on screen only -- the rest are placed. A copy that lands wholly
//     BEFORE a scrolled view holds the view where it is instead (contentX +=
//     one stride), so nothing on screen moves.
//   * Any other change of the list (search, filter, pin) places the cards at
//     once; a card that was not in the window before fades in (presenceMs).
//   * Focus: "lift" is each card's own fraction; "well" is one carved well that
//     glides on `wellT`.
//   * The keyboard's reveal glides the view (focusMs).
//
// INPUT. The wheel is read here, once: a MouseArea (never a WheelHandler), a
// vertical notch scrolls sideways, a touchpad motion keeps the axis it began
// on until the fingers lift (gestures.md). The Flickable is not interactive,
// so it has no second reader. What the reader decides -- which axis -- it hands
// to the shell's one scroll engine (KineticScroll, the feel of ScrollFeel): a
// notch glides, fingers are followed, and a lift while they were moving COASTS
// and eases out. Pointer input is arithmetic on the same geometry that places
// the cards: one MouseArea under the cards.
// =============================================================================
Item {
    id: root

    // ---- in ------------------------------------------------------------------
    property ClipStyle style: null
    property var items: []
    property string stateDir: ""
    property int currentIndex: 0
    property var marks: []
    property bool showDigits: false
    property string peekKey: ""
    property string peekText: ""
    property bool open: true
    // What the fades run into: the surface the shelf sits on.
    property color ground: Theme.surface

    // ---- out -----------------------------------------------------------------
    readonly property int firstVisibleIndex: root._firstVisible

    signal clicked(int index)
    signal activated(int index)
    signal contextRequested(int index, real sceneX, real sceneY)
    signal pinClicked(string key)
    signal keepClicked(string key)

    function ensureVisible(index: int): void {
        if (index < 0 || index >= root.items.length)
            return;
        const m = 24;
        const left = index * root._stride;
        const right = left + root.st.cardWidth;
        const w = root.width;
        let c = shelfFlick.contentX;
        if (left < c + m)
            c = left - m;
        else if (right > c + w - m)
            c = right - w + m;
        c = Math.max(0, Math.min(root._maxX(), c));
        if (Math.abs(c - shelfFlick.contentX) < 0.5)
            return;
        kinetic.stop();
        reveal.stop();
        reveal.to = c;
        reveal.start();
    }

    function cardRect(index: int): var {
        return {
            x: index * root._stride - shelfFlick.contentX,
            y: 0,
            width: root.st.cardWidth,
            height: root.st.cardHeight
        };
    }

    // ---- derived ---------------------------------------------------------------
    property ClipStyle _fallback: ClipStyle {}
    readonly property ClipStyle st: root.style ? root.style : root._fallback
    readonly property int _stride: root.st.cardWidth + root.st.cardGap
    readonly property int slack: 12
    // The furthest the view can scroll. A FUNCTION of the list, not of
    // shelfFlick.contentWidth: the change handlers that call it run before that
    // binding has followed the list (CLAUDE.md, one cascade two generations).
    function _maxX(): real {
        return Math.max(0, 2 * root.slack + Math.max(0, root.items.length * root._stride - root.st.cardGap) - shelfFlick.width);
    }
    readonly property string focusKey: root.currentIndex >= 0 && root.currentIndex < root.items.length ? root.items[root.currentIndex].key : ""
    // Hovered card (key), by the pointer.
    property string hoverKey: ""
    // The clock every sealed card's ring reads (stepped once a second, only
    // while a sealed card is on screen).
    property double secretNow: Date.now()
    readonly property alias clock: clock
    readonly property alias apps: apps

    implicitWidth: Math.min(root.st.shelfCards * root._stride - root.st.cardGap, Math.max(root.st.cardWidth, root.items.length * root._stride - root.st.cardGap))
    implicitHeight: root.st.cardHeight

    BoundaryClock {
        id: clock
    }
    AppLookup {
        id: apps
    }

    // Digit n belongs to the n-th card that is at least half in view.
    readonly property int _firstVisible: {
        const c = shelfFlick.contentX;
        const i = Math.floor((c - root.st.cardWidth / 2) / root._stride) + 1;
        return Math.max(0, Math.min(root.items.length - 1, i));
    }
    function digitFor(index: int): int {
        if (!root.showDigits || index < 0)
            return 0;
        const n = index - root._firstVisible + 1;
        if (n < 1 || n > 9)
            return 0;
        const midX = index * root._stride + root.st.cardWidth / 2 - shelfFlick.contentX;
        return midX < root.width ? n : 0;
    }

    // ---- the view --------------------------------------------------------------------
    Flickable {
        id: shelfFlick
        x: -root.slack
        y: -root.slack
        width: root.width + 2 * root.slack
        height: root.height + 2 * root.slack
        interactive: false
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        contentWidth: 2 * root.slack + Math.max(0, root.items.length * root._stride - root.st.cardGap)
        contentHeight: height

        onContentXChanged: root._onScrolled()
        onWidthChanged: root._onScrolled()

        Item {
            id: layer
            width: shelfFlick.contentWidth
            height: shelfFlick.height

            // Under the cards: the pointer, by arithmetic.
            MouseArea {
                id: pointer
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                hoverEnabled: true
                cursorShape: root.hoverKey !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
                function indexAt(x: real, y: real): int {
                    const rel = x - root.slack;
                    if (rel < 0)
                        return -1;
                    const i = Math.floor(rel / root._stride);
                    if (i < 0 || i >= root.items.length || rel - i * root._stride >= root.st.cardWidth)
                        return -1;
                    const ry = y - root.slack;
                    return ry >= -root.st.liftPx && ry < root.st.cardHeight ? i : -1;
                }
                function track(x: real, y: real): void {
                    const i = pointer.indexAt(x, y);
                    root.hoverKey = i >= 0 ? root.items[i].key : "";
                }
                onPositionChanged: mouse => pointer.track(mouse.x, mouse.y)
                onExited: root.hoverKey = ""
                onClicked: mouse => {
                    const i = pointer.indexAt(mouse.x, mouse.y);
                    if (i < 0)
                        return;
                    root.clicked(i);
                    if (mouse.button === Qt.RightButton) {
                        const p = pointer.mapToItem(null, mouse.x, mouse.y);
                        root.contextRequested(i, p.x, p.y);
                    }
                }
                onDoubleClicked: mouse => {
                    const i = pointer.indexAt(mouse.x, mouse.y);
                    if (i >= 0 && mouse.button === Qt.LeftButton)
                        root.activated(i);
                }
                Connections {
                    target: shelfFlick
                    function onContentXChanged() {
                        if (pointer.containsMouse)
                            pointer.track(pointer.mouseX, pointer.mouseY);
                    }
                }
            }

            // The "well" focus: a carved socket that glides under the focused
            // card. Its rect is the card's, grown by `wellPad`.
            ShadowBox {
                id: well
                readonly property int pad: 5
                visible: root.st.focusStyle === "well" && root.focusKey !== "" && root._wellReady
                x: Math.round(root._wellRect.x) - well.pad
                y: Math.round(root._wellRect.y) - well.pad
                width: root.st.cardWidth + 2 * well.pad
                height: root.st.cardHeight + 2 * well.pad
                baseWidth: width
                baseHeight: height
                baseRadius: root.st.cardRadius + well.pad
                surfaceColor: root.ground
                bevelColor: Theme.bevel
                shadowColor: Theme.border
                backgroundColor: Theme.panelSunk
                bevelWidth: 1
                shadowWidth: 3
            }
            // The cards are created into this layer, above the well.
        }
    }

    ScrollDressing {
        id: dressing
        anchors.fill: shelfFlick
        flick: shelfFlick
        orientation: Qt.Horizontal
        wheelEnabled: false
        ground: root.ground
        fadeHeight: 28 + root.slack
        rampLength: 28
    }

    // ---- the wheel ---------------------------------------------------------------------------
    // One reader. Mouse: a notch is a notch, vertical or sideways alike. Touchpad: the motion keeps
    // the axis that was clearly ahead when it began until the fingers lift (a zero-delta event; the
    // timer is for devices that never send one), and only that axis' deltas reach the engine.
    KineticScroll {
        id: kinetic
        flick: shelfFlick
        axis: Qt.Horizontal
        maxPos: root._maxX()
    }
    property string _axis: ""
    property real _accX: 0
    property real _accY: 0
    function _endMotion(): void {
        root._axis = "";
        root._accX = 0;
        root._accY = 0;
        axisIdle.stop();
    }
    Timer {
        id: axisIdle
        interval: 220
        onTriggered: {
            kinetic.release();
            root._endMotion();
        }
    }
    // `ev` is a WheelEvent (or what a probe builds with the same fields).
    function _read(ev: var): void {
        const ax = ev.angleDelta.x, ay = ev.angleDelta.y;
        const px = ev.pixelDelta.x, py = ev.pixelDelta.y;
        const touch = px !== 0 || py !== 0;
        ev.accepted = true;
        if (ax === 0 && ay === 0 && !touch) {
            // The lift (or the fingers put back): the engine coasts or catches.
            kinetic.feed(0, 0, ev.phase);
            root._endMotion();
            return;
        }
        if (!touch) {
            kinetic.feed(0, ay !== 0 ? ay : ax, ev.phase);
            return;
        }
        let d = 0;
        if (root._axis === "") {
            root._accX += Math.abs(px);
            root._accY += Math.abs(py);
            if (Math.max(root._accX, root._accY) >= 4) {
                if (root._accX >= 1.5 * root._accY)
                    root._axis = "x";
                else if (root._accY >= 1.5 * root._accX)
                    root._axis = "y";
            }
            // Undecided fingers still move the strip along the larger axis.
            d = root._axis === "x" || (root._axis === "" && root._accX >= root._accY) ? px : py;
        } else {
            d = root._axis === "x" ? px : py;
        }
        // A zero here is the other axis' event, not a lift: only a real delta reaches the engine.
        if (d !== 0)
            kinetic.feed(d, 0, ev.phase);
        axisIdle.restart();
    }
    WheelArea {
        anchors.fill: shelfFlick
        turned: wheel => root._read(wheel)
    }

    NumberAnimation {
        id: reveal
        target: shelfFlick
        property: "contentX"
        duration: root.st.focusMs
        easing.type: Easing.OutCubic
    }

    // ---- the pool ----------------------------------------------------------------------------
    Item {
        id: park
        visible: false
    }
    Component {
        id: cardC
        ClipCard {}
    }
    property var _free: ({})
    property var _live: ({})
    // Cards ever built (a probe's count: a scroll builds for the screen only).
    property int cardsBuilt: 0

    function _kindOf(item: var): string {
        if (item.type === "secret")
            return "sealed";
        const k = item.d ? item.d.kind : "text";
        return k === "code" || k === "link" || k === "colour" || k === "image" || k === "files" ? k : "text";
    }
    function _take(kind: string): var {
        const pool = root._free[kind];
        const c = pool ? pool.pop() : undefined;
        if (!c) {
            root.cardsBuilt++;
            const nc = cardC.createObject(park, { shelf: root, faceKind: kind });
            nc.parent = layer;
            return nc;
        }
        c.parent = layer;
        return c;
    }
    function _release(c: var): void {
        c.assign(-1, null, false);
        c.parent = park;
        (root._free[c.faceKind] = root._free[c.faceKind] || []).push(c);
    }

    // ---- window + sync ------------------------------------------------------------------------
    property int _lo: 0
    property int _hi: 0
    property bool _populated: false
    property bool _sealedShown: false

    function slotX(index: int): real {
        return root.slack + index * root._stride;
    }
    // The y a card rests at, and the one the lift reaches.
    function slotY(): real {
        return root.slack;
    }

    function _syncCards(fadeNew: bool): void {
        const n = root.items.length;
        const margin = 2;
        const first = Math.max(0, Math.floor((shelfFlick.contentX - root.slack) / root._stride) - margin);
        const last = Math.min(n, Math.ceil((shelfFlick.contentX + shelfFlick.width - root.slack) / root._stride) + margin);
        root._lo = first;
        root._hi = last;
        const want = {};
        for (let i = first; i < last; i++)
            want[root.items[i].key] = i;
        const live = root._live;
        for (const k in live) {
            const c = live[k];
            if (want[k] === undefined || c.faceKind !== root._kindOf(root.items[want[k]])) {
                root._release(c);
                delete live[k];
            }
        }
        let sealed = false;
        for (let i = first; i < last; i++) {
            const it = root.items[i];
            let c = live[it.key];
            const fresh = !c;
            if (fresh) {
                c = root._take(root._kindOf(it));
                live[it.key] = c;
            }
            c.assign(i, it, fresh && fadeNew && root.open);
            if (it.type === "secret")
                sealed = true;
        }
        root._sealedShown = sealed;
    }

    function _onScrolled(): void {
        if (root._populated)
            root._syncCards(false);
    }

    // ---- a new copy slides in ---------------------------------------------------------------------
    property var _keys: []
    property int slideP: -1
    property real slideT: 1
    NumberAnimation {
        id: slideAnim
        target: root
        property: "slideT"
        from: 0
        to: 1
        duration: root.st.insertMs
        easing.type: Easing.OutCubic
        onFinished: root.slideP = -1
    }
    // How far card `index` sits from its place right now: a card at or after
    // the new one came from the slot before, if it is on screen.
    function slideOffset(index: int): real {
        if (root.slideP < 0 || index < root.slideP || root.slideT >= 1)
            return 0;
        const x = root.slotX(index) - shelfFlick.contentX;
        const w = root.st.cardWidth;
        const vw = shelfFlick.width;
        const was = x - root._stride;
        const onNow = x + w > 0 && x < vw;
        const onWas = was + w > 0 && was < vw;
        return onNow || onWas ? -(1 - root.slideT) * root._stride : 0;
    }
    // The new card itself fades in on the same clock.
    function arriveFactor(index: int): real {
        return root.slideP >= 0 && index === root.slideP && root.slideT < 1 ? root.slideT : 1;
    }

    function _insertPoint(nk: var): int {
        const ok = root._keys;
        if (nk.length !== ok.length + 1)
            return -1;
        let i = 0;
        while (i < ok.length && nk[i] === ok[i])
            i++;
        for (let j = i; j < ok.length; j++)
            if (nk[j + 1] !== ok[j])
                return -1;
        return i;
    }

    onItemsChanged: {
        const nk = [];
        for (let i = 0; i < root.items.length; i++)
            nk.push(root.items[i].key);
        const p = root._populated && root.open ? root._insertPoint(nk) : -1;
        slideAnim.stop();
        root.slideP = -1;
        root.slideT = 1;
        root._keys = nk;
        // A copy wholly before the scrolled view: hold the view, move nothing.
        const hold = p >= 0 && root.slotX(p) + root.st.cardWidth <= shelfFlick.contentX + root.slack - root.st.cardGap && shelfFlick.contentX > 0;
        if (hold)
            shelfFlick.contentX += root._stride;
        // The strip may have got shorter than where the view stands.
        if (shelfFlick.contentX > root._maxX())
            shelfFlick.contentX = root._maxX();
        const was = root._populated;
        root._populated = true;
        root._syncCards(was && p < 0);
        if (p >= 0 && !hold) {
            root.slideP = p;
            root.slideT = 0;
            slideAnim.restart();
        }
        root._retargetWell(false);
    }

    // ---- the well ------------------------------------------------------------------------------------
    property real wellT: 1
    property var _wellFrom: ({ x: 0, y: 0 })
    property var _wellTo: ({ x: 0, y: 0 })
    property bool _wellReady: false
    readonly property var _wellRect: {
        const k = root.slideP >= 0 ? root.slideT : 1;
        k;
        const t = root.wellT;
        const off = root.slideOffset(root.currentIndex);
        return {
            x: root._wellFrom.x + (root._wellTo.x - root._wellFrom.x) * t + off,
            y: root.slotY()
        };
    }
    NumberAnimation {
        id: glide
        target: root
        property: "wellT"
        from: 0
        to: 1
        duration: root.st.focusMs
        easing.type: Easing.OutCubic
    }
    // Aim the well at the current card; `animate` glides it from where it is
    // drawn, else it is placed.
    function _retargetWell(animate: bool): void {
        if (root.currentIndex < 0 || root.currentIndex >= root.items.length)
            return;
        const to = root.slotX(root.currentIndex);
        const drawn = root._wellFrom.x + (root._wellTo.x - root._wellFrom.x) * root.wellT;
        glide.stop();
        const first = !root._wellReady;
        root._wellReady = true;
        if (!animate || first || Math.abs(to - drawn) < 0.5) {
            root._wellFrom = { x: to, y: 0 };
            root._wellTo = { x: to, y: 0 };
            root.wellT = 1;
            return;
        }
        root._wellFrom = { x: drawn, y: 0 };
        root._wellTo = { x: to, y: 0 };
        root.wellT = 0;
        glide.restart();
    }
    onCurrentIndexChanged: {
        root._retargetWell(true);
        root.ensureVisible(root.currentIndex);
    }

    // ---- sealed rings tick, only while shown -----------------------------------------------------
    Timer {
        interval: 1000
        repeat: true
        running: root.open && root.visible && root._sealedShown
        onRunningChanged: if (running) root.secretNow = Date.now()
        onTriggered: root.secretNow = Date.now()
    }

    Component.onCompleted: {
        if (root.items.length > 0 && !root._populated)
            root.itemsChanged();
    }
}
