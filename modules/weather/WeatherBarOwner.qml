pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window

import "../common/components"

// =============================================================================
// WeatherBarOwner.qml -- the weather popup's bar-side object.
//
// The engine builds a popup's content on open and DESTROYS it on close, so what must
// outlive the popup is not here but in the WeatherService (once per shell: the place,
// the forecast, the caches, the geoclue fix). This owner holds only what the bar needs
// of it: how the popup is opened and handed the service, the things a popup forgets on
// its own -- the view the user last chose and the views of the hourly strip and of the
// daily list -- and the one hand the host has on the popup's clock.
//
//   service         WeatherService | WeatherMock. Injected: none means the feature is
//                   absent (a click opens nothing), never a service of its own making.
//   anchorItem      what the popup hangs from (the host's button: WeatherBarButton).
//   viewMode        "mini" | "normal" | "detailed"      the popup writes its own on a
//   stripView       0..8   the hourly strip's views     switch or a cycle; this owner
//   listView        0..6   the daily list's views       takes it back, and the next open
//                                                       starts where the last one ended --
//                                                       WITHIN ONE SESSION: a new session
//                                                       (the shell started again) opens
//                                                       "mini" (feedback/weather.md
//                                                       "Nuance to last remembered view
//                                                       mode"). Nothing is written to disk.
//   detailSide      where the detail grows from ("far": away from the bar).
//   renderScale     the engine's (the popup's static layers allocate their textures at it).
//   fontFamily      Audiowide.
//   shown           the host's hand: false while the bars are hidden (Super+F2) or the
//                   screen is off; default true.
//   backdropRunning the popup's 30 Hz backdrop clock: on only while the popup is on screen
//                   (open, or closing: the close still draws it) AND shown. The content is
//                   destroyed when the close ends, so "closed" costs nothing by itself; this
//                   is for the popup that is alive and not seen.
//   sharedFlags     { popupOpen }: what the host ORs over its screens' owners and writes to
//                   `service.popupOpen` (it turns the KMI nowcast poll on). This owner
//                   writes no property of the service (CONTRACT section 4).
//   toggle() / open() / close()
//
// The detail (the engine's secondary), the view swipe and its sticky hold are the popup's
// own contract with the engine; nothing is forwarded here.
// =============================================================================
Item {
    id: owner

    // ---- the bar ------------------------------------------------------------
    property var engine: null                 // GooeyEngine
    property var bar: null                    // GooeyBar
    property string barId: ""
    property string ownerId: "weather"
    property Item anchorItem: null

    // ---- what it holds ----------------------------------------------------------
    property var service: null
    // The view a session's first open is on, and whether the popup comes back as it was left (weather.jsonc view): with
    // `viewRemember` false the content goes back to `viewStart` when it is parked after a close, and every open is on it.
    property string viewStart: "mini"
    property bool viewRemember: true
    property string viewMode: owner.viewStart
    property int stripView: 0
    property int listView: 0
    property string detailSide: "end"
    property string fontFamily: "Audiowide"
    property real renderScale: owner.engine ? owner.engine.renderScale : 1
    property bool shown: true

    readonly property bool popupMine: !!owner.engine && owner.engine.popupOpen
                                      && owner.engine.popupOwnerId === owner.ownerId
    // This owner's popup is on screen: opening, open, moving or closing (the content lives until
    // the close ends).
    readonly property bool popupPresent: !!owner.engine && owner.engine.thePopup.ownerId === owner.ownerId
                                         && owner.engine.thePopup.phase !== "closed"
    readonly property bool _windowShown: owner.Window.window ? owner.Window.window.visible : true
    readonly property bool backdropRunning: owner.popupPresent && owner.shown && owner._windowShown
    readonly property var sharedFlags: ({
            popupOpen: owner.popupMine
        })

    // What thePopup loads: the drop-in, handed the service. Its view and its cards' views are
    // written back on every change, so the next open starts where this one ended.
    readonly property Component popupComponent: Component {
        WeatherPopup {
            id: content
            service: owner.service
            fontFamily: owner.fontFamily
            detailSide: owner.detailSide
            renderScale: owner.renderScale
            backdropRunning: owner.backdropRunning
            viewMode: owner.viewMode
            resetView: owner.viewRemember ? "" : owner.viewStart
            stripViewStart: owner.stripView
            listViewStart: owner.listView
            onViewModeChanged: owner.viewMode = content.viewMode
            onStripViewIndexChanged: owner.stripView = content.stripViewIndex
            onListViewIndexChanged: owner.listView = content.listViewIndex
        }
    }

    // Hover intent: the pointer has rested on the button, so the content is built now, parked, for the click that follows
    // (GooeyEngine.prebuild: the click then adopts it and builds nothing).
    HoverIntent {
        target: owner.anchorItem
        enabled: owner.shown && !!owner.service
        armed: !!owner.engine && !owner.popupMine
        onIntent: owner.engine.prebuild(owner.ownerId, owner.popupComponent, { parked: true })
    }

    function toggle() {
        if (owner.popupMine)
            owner.close();
        else
            owner.open();
    }

    function open() {
        if (!owner.engine || !owner.bar || !owner.anchorItem || !owner.service || owner.popupMine)
            return;
        // Read at the moment of opening, not bound: a mapToItem in a binding does not
        // track the layout that moved it.
        const centre = owner.anchorItem.mapToItem(owner.bar, owner.anchorItem.width / 2, owner.anchorItem.height / 2).x;
        if (!owner.viewRemember)
            owner.viewMode = owner.viewStart;
        owner.engine.open(owner.ownerId, owner.barId, centre, null, null, false, owner.popupComponent, 1);
    }

    function close() {
        if (owner.popupMine)
            owner.engine.close();
    }
}
