pragma ComponentBehavior: Bound

import QtQuick

import "components"

// =============================================================================
// PlayerBarOwner.qml -- the audio player's bar-side object.
//
// The engine builds a popup's content on open and DESTROYS it on close, so what must
// outlive the popup is not here but in the player (MpdService, or PlayerMockRun: once per
// shell, also read by the OSD's track card and the lock). This owner holds only what the
// bar needs of it: the way the popup is opened and handed the player, and the three things
// a popup forgets on its own -- the view the user last chose, whether the sidebar was out,
// and which panel it showed.
//
//   player          MpdService | PlayerMockRun. Injected: none means the feature is
//                   absent (a click opens nothing), never a service of its own making.
//   anchorItem      what the popup hangs from (the host's button: PlayerBarButton).
//   viewMode        "mini" | "player"        the popup writes its own on a switch; this
//   browseOpen      the sidebar is out       owner takes it back (the content is gone
//   browsePanel     "queue" | "library" | "data"   after a close), and the next open
//                   starts where the last one ended.
//   levelTapEnabled the viewfinder's music-following sparks (a PipeWire recorder while open
//                   and playing); the popup's default, on.
//   sharedFlags     { popupOpen }: the player's popup is open here (mini, normal, with its side panel). The player
//                   writes nothing onto a service; the shell ORs it over the screens and tells the OSD's service,
//                   which holds the now-playing card back while it is up (OsdService.playerOpen).
//   toggle() / open() / close()
//
// THE CLOCK. The popup holds the player's elapsed clock while it exists (PlayerTickHold),
// so with the popup shut a playing player runs no FrameAnimation and wakes no window. This
// owner does nothing for that, on purpose: the hold lives exactly as long as the content.
//
// THE KEYBOARD. The popup declares `keyboardFocusRequest` ("exclusive" while the pointer,
// having MOVED onto it, is over it; "none" otherwise) for Space and the library's search; the host maps
// the engine's `keyboardFocus` onto the layer surface.
// =============================================================================
Item {
    id: owner

    // ---- the bar ------------------------------------------------------------
    property var engine: null                 // GooeyEngine
    property var bar: null                    // GooeyBar
    property string barId: ""
    property string ownerId: "player"
    property Item anchorItem: null

    // ---- what it holds ----------------------------------------------------------
    property var player: null
    // HOW IT OPENS (player.jsonc open): the first open is these three; after it the popup comes back as it was left, unless
    // `openRemember` is false, when every open is these three again.
    property string openView: "player"
    property bool openSidebar: false
    property string openPanel: "queue"
    property bool openRemember: true
    property string viewMode: owner.openView
    property bool browseOpen: owner.openSidebar
    property string browsePanel: owner.openPanel
    property string fontFamily: "Audiowide"
    // The viewfinder's sparks follow the MUSIC, which costs a recorder on the daemon's own
    // PipeWire stream while the popup is open and the song plays (about a process and 25 MB):
    // the module that opens the popup decides whether that is worth it (the popup's own words).
    property bool levelTapEnabled: true
    // What the popup does by itself and how its library opens (player.jsonc autoplay, holdForRecord, library): handed on.
    property bool autoplay: true
    property bool holdForRecord: true
    property string libraryGrouping: "albums"
    property var librarySort: ({ albums: "artist", artists: "name", genres: "name", playlists: "order" })
    property bool libraryAscending: true
    property bool libraryLooseArtists: false

    readonly property bool popupMine: !!owner.engine && owner.engine.popupOpen
                                      && owner.engine.popupOwnerId === owner.ownerId
    readonly property var sharedFlags: ({ popupOpen: owner.popupMine })

    // What thePopup loads: the drop-in, handed the player. Its three states are written
    // back on every change, so the next open starts where this one ended.
    readonly property Component popupComponent: Component {
        AudioPlayerPopup {
            id: content
            player: owner.player
            fontFamily: owner.fontFamily
            levelTapEnabled: owner.levelTapEnabled
            autoplayOnQueue: owner.autoplay
            holdPlaybackUntilDown: owner.holdForRecord
            libraryGrouping: owner.libraryGrouping
            librarySort: owner.librarySort
            libraryAscending: owner.libraryAscending
            libraryLooseArtists: owner.libraryLooseArtists
            viewMode: owner.viewMode
            browseOpen: owner.browseOpen
            browsePanel: owner.browsePanel
            onViewModeChanged: owner.viewMode = content.viewMode
            onBrowseOpenChanged: owner.browseOpen = content.browseOpen
            onBrowsePanelChanged: owner.browsePanel = content.browsePanel
        }
    }

    function toggle() {
        if (owner.popupMine)
            owner.close();
        else
            owner.open();
    }

    function open() {
        if (!owner.engine || !owner.bar || !owner.anchorItem || !owner.player || owner.popupMine)
            return;
        // Read at the moment of opening, not bound: a mapToItem in a binding does not
        // track the layout that moved it.
        const centre = owner.anchorItem.mapToItem(owner.bar, owner.anchorItem.width / 2, owner.anchorItem.height / 2).x;
        if (!owner.openRemember) {
            owner.viewMode = owner.openView;
            owner.browseOpen = owner.openSidebar;
            owner.browsePanel = owner.openPanel;
        }
        owner.engine.open(owner.ownerId, owner.barId, centre, null, null, false, owner.popupComponent, 1);
    }

    function close() {
        if (owner.popupMine)
            owner.engine.close();
    }
}
