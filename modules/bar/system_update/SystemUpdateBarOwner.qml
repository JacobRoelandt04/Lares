pragma ComponentBehavior: Bound

import QtQuick
import "components"


// =============================================================================
// SystemUpdateBarOwner.qml -- the system update's bar-side object, and its button.
//
// The engine builds a popup's content on open and DESTROYS it on close, so what
// must outlive the popup is not here but in the SystemUpdateService (once per
// shell: the run, the parser, the available updates, the askpass pair). This
// owner holds only what the bar needs of it: the icon, the way the popup is
// opened and handed the service's objects, and the one thing a popup would
// forget on its own -- the view the user last chose.
//
//   button            the SystemUpdateIcon (fits the 40 px bar): the archive glyph coloured
//                     by the updates waiting, and while a run goes silicon's assembly -- glyph,
//                     the whole run's percentage, the phase's mark, a bar. It sits
//                     in this item, which is as big as it is, so the host places
//                     THIS item in the island; `anchorItem` is the icon unless
//                     the host hands another (an OutletAnchor).
//   updates           the SystemUpdateService. Injected: none means the feature
//                     is absent (an icon with nothing to show, a click that opens
//                     nothing), never a service of its own making.
//   verbosityMode     "quiet" | "normal" | "verbose": the view the popup is built in.
//                     open() sets it from the SERVICE's memory (quiet when nothing runs,
//                     the run's own view while one does, restarts included), and the popup's
//                     own changes come back here and go on to the service: one memory for
//                     the shell, not one per screen (SystemUpdateService, "viewMemory").
//   sharedFlags       { popupOpen }: what the host ORs over its screens' owners and
//                     writes to `updates.popupOpen`. This owner writes no property
//                     of the service.
//   toggle() / open() / close()
//
// The popup's two requests go to the service: "Run update" starts the run
// (`startUpdate`: the real one only when the service is live), and a popup shown
// idle asks for a fresh check (`refreshIfStale`: the service decides whether the
// numbers it has are old enough).
// =============================================================================
Item {
    id: owner

    // ---- the bar ------------------------------------------------------------
    property var engine: null                 // GooeyEngine
    property var bar: null                    // GooeyBar
    property string barId: ""
    property string ownerId: "update"
    property Item anchorItem: icon            // what the popup hangs from

    // ---- what it holds --------------------------------------------------------
    property var updates: null                // SystemUpdateService
    property string verbosityMode: "quiet"
    property string fontFamily: "Audiowide"
    property string orientation: "horizontal"

    readonly property alias button: icon
    readonly property bool popupMine: !!owner.engine && owner.engine.popupOpen
                                      && owner.engine.popupOwnerId === owner.ownerId
    readonly property var sharedFlags: ({
            popupOpen: owner.popupMine
        })

    implicitWidth: icon.implicitWidth
    implicitHeight: icon.implicitHeight

    // ---- the button -----------------------------------------------------------
    SystemUpdateIcon {
        id: icon
        anchors.fill: parent
        // The archive glyph, coloured by what waits, while idle; while a run goes the assembly of silicon's bar style with
        // the WHOLE RUN's percentage, which the service keeps (the popup may be shut).
        updatesAvailable: owner.updates ? owner.updates.avail.statusCount : 0
        accentAt: owner.updates ? owner.updates.iconAccentAt : 1
        warnAt: owner.updates ? owner.updates.iconWarnAt : 30
        errorAt: owner.updates ? owner.updates.iconErrorAt : 150
        running: owner.updates ? owner.updates.running : false
        percent: owner.updates ? owner.updates.progress.percent : 0
        mark: owner.updates ? owner.updates.progress.mark : "download"
        outcome: owner.updates ? owner.updates.progress.outcome : ""
        active: owner.popupMine
        orientation: owner.orientation
        fontFamily: owner.fontFamily
        onClicked: owner.toggle()
    }

    // ---- the popup --------------------------------------------------------------
    // What thePopup loads: the drop-in, handed the service's objects. Its view is
    // written back on every change, so the next open starts where this one ended.
    readonly property Component popupComponent: Component {
        SystemUpdatePopup {
            id: content
            backend: owner.updates ? owner.updates.backend : null
            parser: owner.updates ? owner.updates.parser : null
            availableUpdates: owner.updates ? owner.updates.avail : null
            // The snapshots (notch, line, page): the service's, null while the shell has none.
            snapshots: owner.updates ? owner.updates.snapshots : null
            // The service serves the askpass socket; the popup only reads its request.
            askpassServer: owner.updates ? owner.updates.askpassServer : null
            // Outlives this content: the link closes the popup, the lookup goes on.
            urlOpener: owner.updates ? owner.updates.urlOpener : null
            fontFamily: owner.fontFamily
            verbosityMode: owner.verbosityMode
            restView: owner.updates ? owner.updates.idleView() : "quiet"
            groupMin: owner.updates ? owner.updates.settings.list.groupMin : 3
            openCategories: owner.updates ? owner.updates.settings.list.open : []
            onVerbosityModeChanged: {
                owner.verbosityMode = content.verbosityMode;
                if (owner.updates)
                    owner.updates.noteView(content.verbosityMode);
            }
            onStartUpdateRequested: {
                if (owner.updates)
                    owner.updates.startUpdate();
            }
            // The run stopped because no snapshot could be taken: the user goes on without one.
            onStartWithoutSnapshotRequested: {
                if (owner.updates)
                    owner.updates.startUpdate(true);
            }
            // The run is the service's (this content is destroyed when the popup closes).
            onUndoRequested: short => {
                if (owner.updates)
                    owner.updates.startUndo(short);
            }
            // The check of a finished run: nothing more to do in here.
            onCloseRequested: owner.close()
            onRefreshRequested: {
                if (owner.updates)
                    owner.updates.refreshIfStale();
            }
            // The recorder reads what this popup believes, for as long as it lives.
            Component.onCompleted: {
                if (owner.updates)
                    owner.updates.registerPopup(content);
            }
            Component.onDestruction: {
                if (owner.updates && owner.updates.unregisterPopup)
                    owner.updates.unregisterPopup(content);
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
        if (!owner.engine || !owner.bar || !owner.anchorItem || !owner.updates || owner.popupMine)
            return;
        // Read at the moment of opening, not bound: a mapToItem in a binding
        // does not track the layout that moved it.
        const centre = owner.anchorItem.mapToItem(owner.bar, owner.anchorItem.width / 2, owner.anchorItem.height / 2).x;
        // The file's view unless an update is in progress (quiet as shipped), then the view that update was last shown in.
        owner.verbosityMode = owner.updates.openView();
        owner.updates.noteView(owner.verbosityMode);
        // the snapshots the page lists are read again at each open (the service coalesces; null = no snapshots in this shell)
        if (owner.updates.snapshots)
            owner.updates.snapshots.refresh();
        owner.engine.open(owner.ownerId, owner.barId, centre, null, null, false, owner.popupComponent, 1);
    }

    function close() {
        if (owner.popupMine)
            owner.engine.close();
    }
}
