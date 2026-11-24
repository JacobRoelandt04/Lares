pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// AudioBarOwner.qml -- the audio popup's bar-side object. A left click on the volume pill opens it on that half's tab (VolumeParity's `mixerRequested`), as the network pair
// does: by default the speaker is Outputs, the microphone is Inputs (`halfOpens`, audio.jsonc pill). A click on the half whose tab is showing closes it, on the other
// it switches the tab.
//
//   service     AudioService | AudioMock. Injected: none means the feature is absent, never a service of its own making (CONTRACT section 4).
//   parity      VolumeParity: the shell's one volume step.
//   anchorItem  what the popup hangs from (the pill).
//   section     the tab; the content is destroyed on close, the next open starts where this one ended.
//   sharedFlags { popupOpen }: the host ORs it over the screens and writes `service.popupOpen`, the one thing that makes the service read anything.
//   halfOpens   [the speaker's tab, the microphone's tab]
//   showHalf(i)   the two halves' only entry point; toggle() / open() / close() the owner contract's, on the tab it last showed
// =============================================================================
Item {
    id: owner

    property var engine: null                 // GooeyEngine
    property var bar: null                    // GooeyBar
    property string barId: ""
    property string ownerId: "audio"
    property Item anchorItem: null
    property bool shellHosted: true

    property var service: null
    property var parity: null
    property string section: "playback"
    property var halfOpens: ["sinks", "sources"]
    // The half last clicked: when both halves open one tab, the one that opened it is the one showing.
    property int _half: 0
    readonly property int activeHalf: !owner.popupMine ? -1
        : owner.section === owner.halfOpens[owner._half] ? owner._half
        : owner.section === owner.halfOpens[1 - owner._half] ? 1 - owner._half : -1
    property string fontFamily: "Audiowide"
    property real renderScale: 1

    readonly property bool popupMine: !!owner.engine && owner.engine.popupOpen && owner.engine.popupOwnerId === owner.ownerId
    readonly property var sharedFlags: ({ popupOpen: owner.popupMine })

    readonly property Component popupComponent: Component {
        AudioPopup {
            id: content
            service: owner.service
            parity: owner.parity
            fontFamily: owner.fontFamily
            renderScale: owner.renderScale
            section: owner.section
            onSectionChanged: owner.section = content.section
            // By hand after that: the popup writes its own `section` from a tab click, which ends a plain binding for good (CLAUDE.md).
            Connections {
                target: owner
                function onSectionChanged() {
                    content.section = owner.section;
                }
            }
        }
    }

    // The half whose tab is showing (-1 while shut): a click on it closes, on the other switches the tab. The pill draws none of it: only
    // the pointer is announced on a bar pill (AudioBarButton, aerial's rule).
    function showHalf(half: int): void {
        if (owner.popupMine && owner.activeHalf === half) {
            owner.close();
            return;
        }
        owner._half = half;
        // The section first: a popup about to open loads on the right tab.
        owner.section = String(owner.halfOpens[half]);
        owner.open();
    }


    function toggle(): void {
        if (owner.popupMine)
            owner.close();
        else
            owner.open();
    }
    function open(): void {
        if (!owner.engine || !owner.bar || !owner.anchorItem || !owner.service || owner.popupMine)
            return;
        const centre = owner.anchorItem.mapToItem(owner.bar, owner.anchorItem.width / 2, owner.anchorItem.height / 2).x;
        owner.engine.open(owner.ownerId, owner.barId, centre, null, null, false, owner.popupComponent, 1);
    }
    function close(): void {
        if (owner.popupMine)
            owner.engine.close();
    }
}
