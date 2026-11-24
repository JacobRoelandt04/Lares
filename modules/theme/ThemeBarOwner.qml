pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// ThemeBarOwner.qml -- the theme popup's bar-side object. The theme button's left click opens it; its right click is ThemeControl's light <-> dark, no popup involved.
//
//   control     ThemeControl: the one switch, and its `pairs`. Injected: none means the feature is absent (CONTRACT section 4).
//   anchorItem  what the popup hangs from (the button).
//   toggle() / open() / close()
//
// THE PICK DOES NOT CLOSE IT: the switch runs under the open popup. A close there would leave the wipe's still with nothing where the popup stood (CLAUDE.md, A HOLE IN A
// COMPOSED STILL). And an open reads the pairs again: a theme added while the shell runs is a card the next time it is looked at.
// =============================================================================
Item {
    id: owner

    property var engine: null                 // GooeyEngine
    property var bar: null                    // GooeyBar
    property string barId: ""
    property string ownerId: "theme"
    property Item anchorItem: null
    property bool shellHosted: true

    property var control: null
    property string fontFamily: "Audiowide"
    property real renderScale: owner.engine ? owner.engine.renderScale : 1
    property bool shown: true

    readonly property bool popupMine: !!owner.engine && owner.engine.popupOpen && owner.engine.popupOwnerId === owner.ownerId
    // The content lives until the close ends, and it is on screen all that time.
    readonly property bool popupPresent: !!owner.engine && owner.engine.thePopup.ownerId === owner.ownerId && owner.engine.thePopup.phase !== "closed"
    readonly property bool _windowShown: owner.Window.window ? owner.Window.window.visible : true

    readonly property Component popupComponent: Component {
        ThemePopup {
            control: owner.control
            fontFamily: owner.fontFamily
            renderScale: owner.renderScale
            motionRunning: owner.popupPresent && owner.shown && owner._windowShown
            outlineRadius: owner.engine ? owner.engine.popupRadius : 20
        }
    }

    function toggle(): void {
        if (owner.popupMine)
            owner.close();
        else
            owner.open();
    }
    function open(): void {
        if (!owner.engine || !owner.bar || !owner.anchorItem || !owner.control || owner.popupMine)
            return;
        owner.control.pairs.rescan();
        const centre = owner.anchorItem.mapToItem(owner.bar, owner.anchorItem.width / 2, owner.anchorItem.height / 2).x;
        owner.engine.open(owner.ownerId, owner.barId, centre, null, null, false, owner.popupComponent, 1);
    }
    function close(): void {
        if (owner.popupMine)
            owner.engine.close();
    }
}
