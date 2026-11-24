pragma ComponentBehavior: Bound

import QtQuick

import "../common/components"

// =============================================================================
// StocksBarOwner.qml -- the stocks popup's bar-side owner.
//
// The engine builds a popup's content on open and destroys it on close, so
// what must outlive the popup lives here: the StocksService (the quotes, the
// portfolio, the watchlist, the caches and the market-aware cadence), the
// alerts' notifier and the tunables the popup is built with. The
// ClockBarOwner / NotesBarOwner pattern.
//
//   toggle() / open() / close()   from the bar button
//   openSymbol(sym)               open the popup with that stock's detail out
//                                 (an alert notification's "Open" action)
//
// A mockup or a probe hands its own `service` (a StocksMock) in; the bar
// leaves it null and the owner runs a real StocksService of its own.
//
// SHELL-HOSTED (`shellHosted`, docs/contracts/shell.md section 4). The shell mounts one
// owner per screen over ONE service: nothing is built here (the service, and the notifier
// that posts its alerts, belong to the host), the owner writes no property of the service
// (`sharedFlags.popupOpen` is what it would have written: the host ORs the screens') and
// connects to no request (the host routes `alertOpenRequested` to the focused screen's
// `openSymbol()`). Each screen's owner remembers its own detail (SecondaryMemory, for the
// session). Off, this file is what it always was.
// =============================================================================
Item {
    id: owner

    property var engine: null                 // GooeyEngine
    property var bar: null                    // GooeyBar
    property string barId: ""
    property string ownerId: "stocks"
    property Item anchorItem: null            // the bar button the popup hangs from

    // ---- the shell (CONTRACT section 4) --------------------------------------
    property bool shellHosted: false
    readonly property var sharedFlags: ({
            popupOpen: owner.popupMine
        })

    // ---- the service: injected, else our own --------------------------------
    property var service: null
    readonly property var svc: owner.service ?? ownService.item

    readonly property bool popupMine: !!owner.engine && owner.engine.popupOpen
                                      && owner.engine.popupOwnerId === owner.ownerId

    // ---- What the popup is built with (the mockup's panel writes these) --------
    property string fontFamily: "Inter"
    property real popupWidth: 504
    property int listRows: 6
    property real rowHeight: 44
    property real logoSize: 30
    property real summaryChartHeight: 96
    // Where the detail opens (StocksPopup's header): side "far" | "start" |
    // "end", anchor "row" | "start" | "centre" | "end", width in popup widths.
    property string detailSide: "end"
    property string detailAnchor: "row"
    property real detailWidthScale: 1
    property bool detailOverhang: false
    property real detailInset: 0
    // The detail comes back with the popup, for the shell's session and while it
    // was on screen less than `detailMemoryMin` minutes ago (stocks.jsonc; the
    // user: 10): the engine's persistent secondary, remembered here because the
    // popup is rebuilt on every open (SecondaryMemory). 0: it never comes back
    // (SecondaryMemory's own 0 is "for ever", so 0 here is no persistence).
    property real detailMemoryMin: 10
    readonly property bool detailPersistent: owner.detailMemoryMin > 0
    readonly property real detailDecayMs: owner.detailMemoryMin * 60000
    readonly property var detailMemory: memory
    property real detailMaxHeight: 960
    property real detailChartHeight: 180
    property real detailLogoSize: 56
    property int stripCycleMs: 4000
    property int stripRollMs: 420
    property int stripStaggerMs: 90
    property int stripHoverDwellMs: 400
    property int stripReleaseGraceMs: 250
    property real flashPeak: 0.22
    property real flashPad: 3
    property real cardBevelWidth: 1
    property real cardShadowWidth: 3
    property real cardShadowFalloff: 1

    // The detail the next popup opens with (a notification's Open, a probe),
    // taken once by the content that is built.
    property var pendingDetail: null

    SecondaryMemory {
        id: memory
        decayMs: owner.detailDecayMs
    }

    // The service rotates its alerts over its own keys (one slot each). Only a service this owner
    // runs needs one: an injected service has its notifier from whoever built it.
    Loader {
        id: ownNotifier
        active: owner.service === null && !owner.shellHosted
        sourceComponent: Component {
            DesktopNotifier {
                appName: "Stocks"
                keys: owner.svc && owner.svc.alertKeys ? owner.svc.alertKeys : []
            }
        }
    }
    // By URL: the owner (and the bar) still load when the service cannot.
    Loader {
        id: ownService
        active: owner.service === null && !owner.shellHosted
        source: owner.service === null && !owner.shellHosted ? Qt.resolvedUrl("data/StocksService.qml") : ""
    }
    // A Binding, not the service's `onLoaded`: two Loaders of one item do not complete in the order
    // they are declared, and the notifier's may not be there yet.
    Binding {
        target: ownService.item
        property: "notifier"
        value: ownNotifier.item
        when: !!ownService.item && !!ownNotifier.item
    }

    Binding {
        target: owner.svc
        property: "popupOpen"
        value: owner.popupMine
        when: !owner.shellHosted && !!owner.svc
    }

    Connections {
        target: owner.svc
        enabled: !owner.shellHosted
        ignoreUnknownSignals: true
        function onAlertOpenRequested(symbol: string) {
            owner.openSymbol(symbol);
        }
    }

    readonly property Component popupComponent: Component {
        StocksPopup {
            id: pop
            service: owner.svc
            fontFamily: owner.fontFamily
            popupWidth: owner.popupWidth
            listRows: owner.listRows
            rowHeight: owner.rowHeight
            logoSize: owner.logoSize
            summaryChartHeight: owner.summaryChartHeight
            detailSide: owner.detailSide
            detailAnchor: owner.detailAnchor
            detailWidthScale: owner.detailWidthScale
            detailOverhang: owner.detailOverhang
            detailInset: owner.detailInset
            detailPersistent: owner.detailPersistent
            detailMemory: owner.detailMemory
            detailMaxHeight: owner.detailMaxHeight
            detailChartHeight: owner.detailChartHeight
            detailLogoSize: owner.detailLogoSize
            stripCycleMs: owner.stripCycleMs
            stripRollMs: owner.stripRollMs
            stripStaggerMs: owner.stripStaggerMs
            stripHoverDwellMs: owner.stripHoverDwellMs
            stripReleaseGraceMs: owner.stripReleaseGraceMs
            flashPeak: owner.flashPeak
            flashPad: owner.flashPad
            cardBevelWidth: owner.cardBevelWidth
            cardShadowWidth: owner.cardShadowWidth
            cardShadowFalloff: owner.cardShadowFalloff
            // A detail asked for (a notification's Open) wins over the one
            // remembered; either is set once the rows are placed, and the
            // engine opens a persistent one when the popup is nearly out.
            Component.onCompleted: {
                if (owner.pendingDetail) {
                    const k = owner.pendingDetail;
                    owner.pendingDetail = null;
                    Qt.callLater(() => pop.openDetail(k, pop.anchorFor(k)));
                } else if (owner.detailPersistent && memory.restorable()) {
                    const k = memory.key;
                    Qt.callLater(() => pop.restoreDetail(k));
                }
            }
        }
    }

    function toggle() {
        if (owner.popupMine)
            owner.close();
        else
            owner.open();
    }

    function open() {
        // Hosted with no service, the feature is absent: there is nothing to build a popup from.
        if (!owner.engine || !owner.bar || !owner.anchorItem || owner.popupMine || (owner.shellHosted && !owner.svc))
            return;
        const centre = owner.anchorItem.mapToItem(owner.bar, owner.anchorItem.width / 2, owner.anchorItem.height / 2).x;
        owner.engine.open(owner.ownerId, owner.barId, centre, null, null, false, owner.popupComponent, 1);
    }

    function close() {
        if (owner.popupMine)
            owner.engine.close();
    }

    function openSymbol(sym) {
        if (!sym)
            return;
        const key = {
            symbol: sym,
            from: owner.svc && owner.svc.position && owner.svc.position(sym) ? "holding" : "watch"
        };
        const content = owner.popupMine && owner.engine.thePopup ? owner.engine.thePopup.contentItem : null;
        if (content && content.openDetail) {
            content.openDetail(key, content.anchorFor(key));
            return;
        }
        owner.pendingDetail = key;
        owner.open();
    }
}
