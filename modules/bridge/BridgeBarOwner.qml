pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Hyprland

import "../common/components"
import "../common/scroll/HeldPointer.js" as Look

// =============================================================================
// BridgeBarOwner.qml -- the bridge popup's bar-side owner (the StocksBarOwner pattern).
//
// The engine builds a popup's content on open and destroys it on close, so what must outlive the popup lives in the
// service (the devices, the jobs, the page on show); this owner only opens and closes, and hands the content its
// service.
//
//   toggle() / open() / close()   from the bar button
//   sendFiles(paths)              files dropped on the bar's glyph: sent to the current phone, and the popup opens so the
//                                 send is seen (the service says what happened either way: its toast)
//
// SHELL-HOSTED (`shellHosted`, docs/contracts/shell.md section 4). The shell mounts one owner per screen over ONE
// BridgeService: nothing is built here, the owner writes no property of the service (`sharedFlags.popupOpen` is what
// it would have written: the host ORs the screens') and registers no shortcut. Not hosted and with no service handed
// in (a mockup, a bare bar), it runs a BridgeService of its own that is NOT live: the mock's "wired" phone, no process.
// =============================================================================
Item {
    id: owner

    property var engine: null                 // GooeyEngine
    property var bar: null                    // GooeyBar
    property string barId: ""
    property string ownerId: "bridge"
    property Item anchorItem: null            // the bar button the popup hangs from

    // ---- the shell (CONTRACT section 4) --------------------------------------
    property bool shellHosted: false
    readonly property var sharedFlags: ({
            popupOpen: owner.popupMine
        })

    // ---- the service: injected, else our own (never live) --------------------
    property var service: null
    readonly property var svc: owner.service ?? ownService.item

    readonly property bool popupMine: !!owner.engine && owner.engine.popupOpen
                                      && owner.engine.popupOwnerId === owner.ownerId

    property string fontFamily: "Inter"

    // By URL: the owner (and the bar) still load when the service cannot.
    Loader {
        id: ownService
        active: owner.service === null && !owner.shellHosted
        source: owner.service === null && !owner.shellHosted ? Qt.resolvedUrl("data/BridgeService.qml") : ""
    }
    // The mock's phone on the cable (the service is never live here).
    Binding {
        target: ownService.item
        property: "scenario"
        value: "wired"
        when: !!ownService.item
    }
    Binding {
        target: owner.svc
        property: "popupOpen"
        value: owner.popupMine
        when: !owner.shellHosted && !!owner.svc
    }

    readonly property Component popupComponent: Component {
        BridgePopup {
            service: owner.svc
            fontFamily: owner.fontFamily
            onLookPointer: what => owner._lookPointer(what)
        }
    }

    // The pointer resting on the glyph: the content is built ahead of the click (parked), as silicon's is.
    HoverIntent {
        target: owner.anchorItem
        onIntent: {
            if (owner.engine && owner.svc && !owner.popupMine)
                owner.engine.prebuild(owner.ownerId, owner.popupComponent, { parked: true });
        }
    }

    // The popup's free look keeps the hidden pointer where the look began: Hyprland moves it (HeldPointer.js). Only for a
    // LIVE service: a mock shell, a mockup or a probe never moves anybody's pointer.
    function _lookPointer(what: string) {
        if (owner.svc && owner.svc.live === true)
            Hyprland.dispatch(Look.expr(what));
    }

    function toggle() {
        if (owner.popupMine)
            owner.close();
        else
            owner.open();
    }

    function open() {
        // Hosted with no service, the feature is absent: there is nothing to build a popup from.
        if (!owner.engine || !owner.bar || !owner.anchorItem || owner.popupMine || !owner.svc)
            return;
        // A whole middle: the popup rests about it, and the phone in it is laid out on whole pixels from its corner.
        const centre = Math.round(owner.anchorItem.mapToItem(owner.bar, owner.anchorItem.width / 2, owner.anchorItem.height / 2).x);
        owner.engine.open(owner.ownerId, owner.barId, centre, null, null, false, owner.popupComponent, 1);
    }

    function close() {
        if (owner.popupMine)
            owner.engine.close();
    }

    function sendFiles(paths: var) {
        if (!owner.svc || !paths || paths.length === 0)
            return;
        const key = owner.svc.currentKey;
        if (key === "")
            return;
        owner.svc.send(key, paths);
        owner.open();
    }
}
