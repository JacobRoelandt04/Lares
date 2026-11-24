pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/scroll"

// =============================================================================
// WikiPopup.qml -- the full card: today's article on one of two tabs.
//
//   [ hero well: the entry's pictures or its veil, a band of buttons on hover ]
//   Title (2 lines)                            [family] [package] [source logo]
//   One paragraph, links inside it, a mark at its foot (sparkle / pencil)
//                                                          . .   (the tab dots)
//
// It is the clock popup's SECONDARY (the engine's content contract: `secondaryKey`,
// `secondaryCutout`, `secondaryMoving`, `naturalHeight`) and the mockup's drop-in
// for thePopup: sized through `implicitWidth` / `implicitHeight` only, with no
// assumption about its host beyond what it exposes below.
//
// THE SERVICE is one object (WikiService, or WikiMock -- the same members,
// docs/contracts/wiki.md); the card is `service.card(tab)`, a
// bag of FACTS (never a colour: each part resolves the hue token itself). Every
// getter is read after `service.serial`; every ask is made from a handler.
//
// TABS. Discover and Deepen are two views of the same card, cycled by a
// CardViewCycler declared LAST over everything (its dots live in the bottom
// padding band). This popup owns the ONE wheel reader: a MouseArea (a WheelHandler
// never hears a sideways swipe) that latches the gesture's axis at its first
// clear lead, feeds the cycler on x, ends on the zero-delta lift (or after
// `gestureIdleEndMs` of silence), and leaves everything else to whoever is
// under it. The height must not move under the fingers (a secondary cannot hold
// a gesture rect), so `naturalHeight` is the MAX over both tabs' current entries:
// each tab has its own title row and intro, both laid out at the same width
// (only the current tab's is shown), and the slots take the taller of the two.
// It changes only when an entry does (next, follow, back), and the engine eases
// it. The wheel a swipe leaves behind is `gestureWheel(ev)`'s, for the events
// that land outside the body while a gesture is live.
//
// THE CUTOUT. An inset secondary lies under its primary along the face it hangs
// from; the part the primary covers arrives as `secondaryCutout` and is ADDED to
// the implicit size, the card starting one padding past it (StockDetail's rule,
// on any side). `naturalHeight` is the content only, without the band, so the
// host can decide overhangs from what the engine cannot move.
//
// WHAT IS REPORTED. While the card is on screen (visible, not moving, `windowActive`,
// not loading) `service.read(tab, id, cumulativeMs)` is called about once a
// second per entry -- this popup is the one place an article is READ, and the
// only one that makes it seen (WikiService "SEEN") -- and a pointer resting on the card for `dwellMs` says
// `service.hoverDwell(tab, id, ms)` once. Both are timers that run only then:
// hidden, the card ticks nothing.
//
// LINKS. A plain click on a link in the paragraph opens it in the browser through
// `service.openLink` (http(s) only; the service records the interest and a probe
// silences it with the service's own `dryRun`); a
// Ctrl+click follows it into the rabbit hole (`service.follow`). `service.closeCard()`
// runs when the card is destroyed: a trail never outlives its popup.
// =============================================================================
Item {
    id: root

    // ---- Contract ------------------------------------------------------------------
    property var service: null
    property string fontFamily: "Inter"
    property real cardWidth: 448
    property real padding: 12
    property real radius: 14
    property WikiStyle style: WikiStyle {}
    property int autoAdvanceMs: 7000
    property int slideMs: 260
    // wiki.jsonc dwellMs (the service's own test is against the same number)
    readonly property int dwellMs: root.service && root.service.config ? root.service.config.dwellMs : 15000
    // The tab it opens on; `showTab(id)` changes it later.
    property string startTab: "discover"
    // A host that knows the shell is idle or locked says so here.
    property bool windowActive: true
    // How often the on-screen time is reported.
    property int reportMs: 1000
    property int gestureIdleEndMs: 260
    property real swipePixelToAngle: 2.5
    property real axisLead: 1.2
    // The tab switcher's detent, handed to the CardViewCycler (whose WheelStepper reads
    // them; its own defaults are these numbers). Wheel units per step for a mouse notch
    // (angleDelta 120, no pixel delta):
    property real notchThreshold: 120
    // ... for a touchpad, any event that carries a pixel delta:
    property real pixelThreshold: 1000
    // ... and the pause after a step, in which the wheel is not read (a flick moves one tab per pause).
    property int stepCooldownMs: 200

    // The engine's secondary contract.
    property var secondaryKey: null
    property rect secondaryCutout: Qt.rect(0, 0, 0, 0)
    property bool secondaryMoving: false
    readonly property real naturalHeight: Math.round(root._introY + root._introH + root.padding)

    readonly property var views: [{ id: "discover", label: "Discover" }, { id: "deepen", label: "Deepen" }]
    readonly property int tabIndex: cycler.currentIndex
    readonly property string tab: root.views[cycler.currentIndex].id

    // The swipe contract.
    readonly property bool swipeGestureActive: root._gestureActive
    readonly property real gestureHoldWidth: root.implicitWidth
    readonly property real gestureHoldHeight: root.implicitHeight

    signal closeRequested
    // An article was opened in the browser (the source logo, or a link in the text): the reader has left for it, so the
    // HOST closes the card and the popup it hangs from (the clock: ClockPopupContent). Emitted after the service call.
    signal articleOpened

    function showTab(id) {
        for (let i = 0; i < root.views.length; i++)
            if (root.views[i].id === id && i !== cycler.currentIndex)
                cycler.currentIndex = i;
    }

    // A new entry starts its own count.
    onCardIdChanged: {
        if (shownTimer.running)
            shownTimer.restart();
        if (dwellTimer.running)
            dwellTimer.restart();
    }
    onSecondaryKeyChanged: {
        if (root.secondaryKey && root.secondaryKey.tab)
            root.showTab(root.secondaryKey.tab);
    }

    // ---- the facts (serial first: a new arrival re-reads) --------------------------------------
    readonly property var cardDiscover: {
        const s = root.service;
        if (!s)
            return null;
        void s.serial;
        return s.card("discover");
    }
    readonly property var cardDeepen: {
        const s = root.service;
        if (!s)
            return null;
        void s.serial;
        return s.card("deepen");
    }
    readonly property var card: root.tab === "discover" ? root.cardDiscover : root.cardDeepen
    readonly property bool loading: {
        const s = root.service;
        if (!s)
            return false;
        void s.serial;
        return s.loading(root.tab);
    }
    readonly property bool canBack: {
        const s = root.service;
        if (!s)
            return false;
        void s.serial;
        return s.canBack(root.tab);
    }
    readonly property string parentTitle: {
        const s = root.service;
        if (!s)
            return "";
        void s.serial;
        const t = s.trail(root.tab);
        return t && t.length > 0 ? (t[t.length - 1].title || "") : "";
    }
    readonly property string cardId: root.card ? root.card.id : ""
    // An entry is on show: not being fetched, and there is one.
    readonly property bool shows: root.card !== null && !root.loading
    // What an empty pool is waiting for, from what the service knows: only a batch that runs fills it.
    readonly property string _emptyWords: {
        const s = root.service;
        if (!s) return "No articles yet";
        const b = s.batch;
        if (b && b.running) return "No articles yet — the pool is being filled";
        if (s.batchPending) return "No articles yet — waiting for the GPU";
        if (s.offline) return "No articles yet — the network is down";
        if (b && b.blocked) return "No articles yet — the GPU is busy";
        return "No articles yet";
    }
    // The empty pool offers a batch when one could start now: nothing runs or waits for the GPU, the network is up. A GPU that was busy
    // (`blocked`) is a retry. The click is the refill notification's "Process N now" (WikiService.startBatch: its plan, its GPU hand-over).
    readonly property bool _offerProcess: {
        const s = root.service;
        if (!s || root.loading || typeof s.startBatch !== "function")
            return false;
        const b = s.batch;
        return !(b && b.running) && !s.batchPending && !s.offline;
    }

    // ---- the cutout band (StockDetail's rule, on any side) --------------------------------------
    readonly property var _band: {
        const r = root.secondaryCutout;
        const b = { top: 0, bottom: 0, left: 0, right: 0 };
        if (!(r.width > 0) || !(r.height > 0))
            return b;
        // A band that does not start at an edge ends at the opposite one. Not
        // measured against this item's own size: that size is made of the band.
        const across = r.width >= r.height;
        if (across && r.y <= 0.5)
            b.top = r.y + r.height;
        else if (across)
            b.bottom = r.height;
        else if (r.x <= 0.5)
            b.left = r.x + r.width;
        else
            b.right = r.width;
        return b;
    }
    readonly property real _top: Math.ceil(root._band.top)
    readonly property real _bottom: Math.ceil(root._band.bottom)
    readonly property real _left: Math.ceil(root._band.left)
    readonly property real _right: Math.ceil(root._band.right)

    // ---- the column, in whole pixels ----------------------------------------------------------------
    readonly property real _innerW: root.cardWidth - 2 * root.padding
    readonly property real _heroH: Math.floor(root._innerW * root.style.heroRatioH / root.style.heroRatioW)
    readonly property real _titleY: root.padding + root._heroH + root.style.heroGap
    readonly property real _titleH: Math.max(titleDiscover.naturalHeight, titleDeepen.naturalHeight)
    readonly property real _introY: root._titleY + root._titleH + root.style.titleGap
    readonly property real _introH: Math.max(introDiscover.implicitHeight, introDeepen.implicitHeight)

    implicitWidth: root._left + root.cardWidth + root._right
    implicitHeight: root._top + root._bottom + root.naturalHeight

    focus: true
    Keys.onEscapePressed: root.closeRequested()

    Component.onCompleted: {
        root.showTab(root.startTab);
        if (root.service)
            root.service.ensureSlots();
    }
    onServiceChanged: {
        if (root.service)
            root.service.ensureSlots();
    }
    Component.onDestruction: {
        if (root.service)
            root.service.closeCard();
    }

    // ---- the card ---------------------------------------------------------------------------------------
    Item {
        id: content
        x: root._left
        y: root._top
        width: root.cardWidth
        height: Math.max(0, root.height - root._top - root._bottom)

        // The entry's presence: it fades out while one is fetched, in when it lands.
        property real shownF: root.shows ? 1 : 0
        Behavior on shownF {
            NumberAnimation {
                duration: root.style.presenceMs
                easing.type: Easing.OutCubic
            }
        }

        WikiHero {
            id: hero
            x: root.padding
            y: root.padding
            width: root._innerW
            height: root._heroH
            service: root.service
            tab: root.tab
            card: root.card
            style: root.style
            overlayItem: overlay
            radius: root.radius
            fontFamily: root.fontFamily
            autoAdvanceMs: root.autoAdvanceMs
            slideMs: root.slideMs
            holdCarousel: root.secondaryMoving || root.loading || Theme.crossfading
            live: root.shows
            veilRunning: root.windowActive
            shownF: content.shownF
            canBack: root.canBack
            parentTitle: root.parentTitle
        }

        WikiTitleRow {
            id: titleDiscover
            objectName: "wikiTitleDiscover"
            x: root.padding
            y: root._titleY
            width: root._innerW
            height: root._titleH
            visible: root.tab === "discover"
            opacity: content.shownF
            card: root.cardDiscover
            service: root.service
            tab: "discover"
            style: root.style
            fontFamily: root.fontFamily
            overlayItem: overlay
            interactive: root.shows
            onSourceOpened: root.articleOpened()
        }
        WikiTitleRow {
            id: titleDeepen
            objectName: "wikiTitleDeepen"
            x: root.padding
            y: root._titleY
            width: root._innerW
            height: root._titleH
            visible: root.tab === "deepen"
            opacity: content.shownF
            card: root.cardDeepen
            service: root.service
            tab: "deepen"
            style: root.style
            fontFamily: root.fontFamily
            overlayItem: overlay
            interactive: root.shows
            onSourceOpened: root.articleOpened()
        }

        WikiIntro {
            id: introDiscover
            objectName: "wikiIntroDiscover"
            x: root.padding
            y: root._introY
            width: root._innerW
            height: root._introH
            visible: root.tab === "discover"
            opacity: root.cardDiscover !== null ? content.shownF : 1
            card: root.cardDiscover
            tab: "discover"
            style: root.style
            fontFamily: root.fontFamily
            overlayItem: overlay
            interactive: root.shows
            emptyText: root.loading ? "" : root._emptyWords
            offerProcess: root._offerProcess
            onProcessRequested: {
                if (root.service)
                    root.service.startBatch("discover");
            }
            onLinkOpened: link => {
                if (root.service && root.cardDiscover) {
                    root.service.openLink("discover", root.cardDiscover.id, link.url);
                    root.articleOpened();
                }
            }
            onLinkFollowed: link => {
                if (root.service)
                    root.service.follow("discover", link);
            }
        }
        WikiIntro {
            id: introDeepen
            objectName: "wikiIntroDeepen"
            x: root.padding
            y: root._introY
            width: root._innerW
            height: root._introH
            visible: root.tab === "deepen"
            opacity: root.cardDeepen !== null ? content.shownF : 1
            card: root.cardDeepen
            tab: "deepen"
            style: root.style
            fontFamily: root.fontFamily
            overlayItem: overlay
            interactive: root.shows
            emptyText: root.loading ? "" : root._emptyWords
            offerProcess: root._offerProcess
            onProcessRequested: {
                if (root.service)
                    root.service.startBatch("deepen");
            }
            onLinkOpened: link => {
                if (root.service && root.cardDeepen) {
                    root.service.openLink("deepen", root.cardDeepen.id, link.url);
                    root.articleOpened();
                }
            }
            onLinkFollowed: link => {
                if (root.service)
                    root.service.follow("deepen", link);
            }
        }

        WikiSkeleton {
            id: skeleton
            anchors.fill: parent
            style: root.style
            showing: root.loading
            heroRect: Qt.rect(root.padding, root.padding, root._innerW, root._heroH)
            titleRect: Qt.rect(root.padding, root._titleY, root._innerW, root._titleH)
            introRect: Qt.rect(root.padding, root._introY, root._innerW, root._introH)
        }

        // ---- what is reported ---------------------------------------------------------------------
        readonly property bool reporting: root.visible && root.windowActive && !root.secondaryMoving
            && root.shows && root.service !== null && root.Window.window !== null && root.Window.window.visible
        property var _shownMs: ({})
        property var _dwellDone: ({})
        Timer {
            id: shownTimer
            interval: root.reportMs
            repeat: true
            running: content.reporting
            onTriggered: {
                const id = root.cardId;
                const total = (content._shownMs[id] || 0) + shownTimer.interval;
                content._shownMs[id] = total;
                root.service.read(root.tab, id, total);
            }
        }
        Timer {
            id: dwellTimer
            interval: root.dwellMs
            running: content.reporting && cardHover.hovered && content._dwellDone[root.cardId] !== true
            onTriggered: {
                content._dwellDone[root.cardId] = true;
                root.service.hoverDwell(root.tab, root.cardId, root.dwellMs);
            }
        }
        HoverHandler {
            id: cardHover
        }

        // ---- the one wheel reader ------------------------------------------------------------------
        WheelArea {
            id: wheelReader
            anchors.fill: parent
            turned: wheel => {
                wheel.accepted = root._wheel(wheel);
            }
        }

        // The tab dots and the title box, over everything.
        CardViewCycler {
            id: cycler
            anchors.fill: parent
            views: root.views
            orientation: "horizontal"
            notchThreshold: root.notchThreshold
            pixelThreshold: root.pixelThreshold
            stepCooldownMs: root.stepCooldownMs
            padding: root.padding
            radius: root.radius
            fontFamily: root.fontFamily
            overlayInset: root.padding
            overlayRadius: hero.radius     // the hero well's own, so the title box's corners are the image's
            groundColor: Theme.surface
            bevelColor: Theme.bevel
            bevelWidth: root.style.wellBevel
            shadowWidth: root.style.wellShadow
            shadowFalloff: root.style.wellFalloff
        }
    }

    // Tips and anything else that floats live here, above the card.
    Item {
        id: overlay
        objectName: "wikiOverlay"
        anchors.fill: parent
        z: 10
    }

    // ---- the wheel ----------------------------------------------------------------------------------------
    property bool _gestureActive: false
    property string _gestureAxis: ""
    Timer {
        id: gestureIdle
        interval: root.gestureIdleEndMs
        onTriggered: root._endGesture()
    }
    function _endGesture() {
        gestureIdle.stop();
        cycler.end();
        root._gestureActive = false;
        root._gestureAxis = "";
    }
    // One wheel event (WheelHub's). Returns whether it was used (a sideways
    // gesture is this card's; the rest is not).
    function _wheel(ev) {
        const ad = ev.angleDelta, pd = ev.pixelDelta;
        // a mouse: a sideways notch is a view (the upright one is the dots', under the pointer)
        if (ev.device === "wheel") {
            if (ad.x === 0)
                return false;
            cycler.feed(120 * ev.steps, false);
            return true;
        }
        const xPixels = pd.x !== 0;
        const dx = ad.x !== 0 ? ad.x : pd.x * root.swipePixelToAngle;
        const dy = ad.y !== 0 ? ad.y : pd.y * root.swipePixelToAngle;
        // Zero on both axes is the touchpad's scroll-end: the fingers lifted.
        if (dx === 0 && dy === 0) {
            const mine = root._gestureAxis === "x";
            root._endGesture();
            return mine;
        }
        gestureIdle.restart();
        root._gestureActive = true;
        // A two-finger read is never one axis: the one clearly ahead is taken
        // and kept until the fingers lift.
        if (root._gestureAxis === "") {
            if (Math.abs(dx) > Math.abs(dy) * root.axisLead)
                root._gestureAxis = "x";
            else if (Math.abs(dy) > Math.abs(dx) * root.axisLead)
                root._gestureAxis = "y";
        }
        if (root._gestureAxis !== "x" || dx === 0)
            return false;
        cycler.feed(dx, xPixels);
        return true;
    }
    // A wheel that lands OUTSIDE the body while a gesture is live (the engine
    // clips a body): in this item's coordinates, like the event.
    function gestureWheel(ev) {
        if (!root._gestureActive || !ev)
            return false;
        root._wheel(ev);
        return true;
    }
}
