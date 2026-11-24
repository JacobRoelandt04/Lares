import QtQuick

// =============================================================================
// HoverIntent.qml -- "the pointer has come to rest on this item": the moment an owner builds its popup's content ahead of the click
// (GooeyEngine.prebuild).
//
//     HoverIntent {
//         target: owner.anchorItem
//         armed: !owner.popupMine
//         onIntent: owner.engine.prebuild(owner.ownerId, owner.popupComponent)
//     }
//
// `intent()` fires once `restMs` after the pointer came onto `target` (80 ms by default: a pointer passing over a button on its way
// elsewhere does not build anything, one resting on it does -- and the click that follows is ~100-500 ms later). It is a passive
// HoverHandler placed ON the target, which hears hover without taking it from the target's own MouseArea or cursor.
//
// `armed` is the owner's "a content is wanted": false while its popup is open (nothing to build), true again when it closes -- and
// a pointer that never left the button (the click that closed the popup) rests on it again, so the content for the NEXT open is
// built while the popup closes (the engine waits for it to finish). One intent per arming. A key-opened owner has no pointer: it
// never calls this. `enabled: false` (the item's own: the host's bars hidden, a screen off) stops it.
// =============================================================================
Item {
    id: root

    property Item target: null
    property int restMs: 80
    property bool armed: true
    signal intent

    HoverHandler {
        id: handler
        parent: root.target
        enabled: root.enabled && !!root.target
        onHoveredChanged: root._arm()
    }
    onArmedChanged: root._arm()

    // Rest, then fire: restarted whenever the pointer comes or goes (the handler is disabled with the item, and hears the pointer that
    // rests on its target when it is enabled again) or the arming changes.
    function _arm() {
        if (handler.hovered && root.armed && root.enabled)
            rest.restart();
        else
            rest.stop();
    }
    Timer {
        id: rest
        interval: Math.max(1, root.restMs)
        onTriggered: {
            if (handler.hovered && root.armed && root.enabled)
                root.intent();
        }
    }
}
