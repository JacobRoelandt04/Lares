pragma ComponentBehavior: Bound

import QtQuick

import "kinds"
import "../common/scroll"

// =============================================================================
// OsdContent.qml -- what the OSD shows for ONE kind, as a drop-in (CONTRACT §4).
//
// A dispatcher: `kind` picks the layout (kinds/), `orientation` ("h" | "v" |
// "pill") picks how it stands, `payload` is the request object. The content
// has no ground of its own -- the engine's popup (or the pill) is the surface
// -- and no assumption about its host beyond its implicit size, which is
// OsdStyle's number for kind x orientation (a vertical card may ask for more
// width, up to the style's cardMaxW, to keep its longest word whole). The card
// is LAID OUT AT THAT SIZE and centred by hand in whatever box it is handed (the
// engine's box is animated: nothing at birth, then growing), and its host hands
// the payload over BEFORE the content is made, so a card is born with what it
// shows and at its own size (`bornKind`, `bornSize`).
//
// INPUT lives here, once, above whatever the kind draws:
//   hover     a HoverHandler (`hovered`); the owner freezes its timer on it
//   wheel     a MouseArea (never a WheelHandler, gestures.md) over a level:
//             a notch is `style.wheelStep` of the range, handed to the kind
//   middle    toggles mute (volume and mic)
//   touched() any of those, or the slider's own drag / mute / boost
//   hideRequested()  a card's own hide button (the caption's): the owner tucks it away
// `interactive: false` (the pill) means no hover, no wheel: the one control the pill
// takes is a hide button, whose rect (`hideRect`, in this item's px; empty when the
// card has none) its window lets through.
// =============================================================================
Item {
    id: root

    property string kind: ""
    property string orientation: "h"          // "h" | "v" | "pill"
    property var payload: ({})
    property bool interactive: true
    property var style: null                  // OsdStyle; null = the built-in numbers
    property real renderScale: 1
    // The compositor flips the wheel's deltas for this kind of device (Hyprland's natural_scroll) and never says so: Qt's
    // `inverted` stays false there (modules/shell/NaturalScroll.qml, which reads the setting once for the shell). The
    // owner hands the two flags in; a delta is un-flipped HERE, once, so that fingers moving up always raise the level.
    property bool touchpadNatural: false
    property bool mouseNatural: false

    readonly property bool hovered: hover.hovered

    // One wheel event's vertical delta as the hand meant it (angle units: a notch is 120). A touchpad is the event that
    // carries a pixel delta; a mouse notch carries none. Flipped when Qt says so OR the device's kind is natural -- one flip.
    function wheelUnits(angleY: real, pixelY: real, inverted: bool): real {
        const flipped = inverted || (pixelY !== 0 ? root.touchpadNatural : root.mouseNatural);
        return angleY * (flipped ? -1 : 1);
    }

    // What this content was when its KIND's card was MADE: the kind of payload it held ("" = the card was born empty)
    // and the size it asked for (`bornSize`, {w, h}). A card made before its payload is handed to it starts every
    // animation from nothing (a level's ball glides in from 0, a rail's ball is sent to its stop) and asks the engine
    // for the size of an empty one (a layout name with no words, a screenshot with no picture); the owner therefore
    // hands the payload over BEFORE it asks the engine to make the content, and the pill sets its payload before its
    // kind.
    property string bornKind: ""
    property var bornSize: ({ w: 0, h: 0 })

    signal userValue(real v)
    signal userToggleMute()
    signal userToggleBoost()
    signal touched()
    // The card was clicked as a whole (a screenshot's: the owner opens it for editing).
    signal activated()
    // The trash icon of a screenshot's card.
    signal trashRequested()
    // The card's hide button (the caption's).
    signal hideRequested()

    // Where the card's hide button is, in this item's px (the card is centred in it); an empty rect when it has none.
    readonly property rect hideRect: {
        const it = body.item;
        // Only the caption declares one.
        // qmllint disable missing-property
        const r = it ? it.hideRect : undefined;
        // qmllint enable missing-property
        return r !== undefined && r.width > 0 ? Qt.rect(body.x + r.x, body.y + r.y, r.width, r.height) : Qt.rect(0, 0, 0, 0);
    }

    OsdStyle {
        id: ownStyle
    }
    readonly property var _style: root.style ? root.style : ownStyle
    readonly property var _extent: root._style.extentOf(root.kind, root.orientation)

    // A vertical card never breaks a word: it grows past the style's width to
    // fit its longest word, up to `cardMaxW` (the kinds say it as `wantW`).
    readonly property real _wantW: {
        const it = body.item;
        // Only the cards that stand vertically declare `wantW`; the others have none.
        // qmllint disable missing-property
        const w = root.orientation === "v" && it ? it.wantW : undefined;
        // qmllint enable missing-property
        return w !== undefined ? Number(w) : 0;
    }

    implicitWidth: root._fitW > 0 ? root._fitW : Math.max(root._extent.w, Math.min(root._style.cardMaxW, root._wantW))
    implicitHeight: root._fitH > 0 ? root._fitH : root._extent.h

    // A card that KNOWS its size from what it says -- a name's wrapped lines, a name's length -- declares it
    // (`fitW` / `fitH`; 0 = no opinion) and the style's extent is not asked: an extent is for the kinds whose size
    // is a decision, not a consequence. A fixed number there would leave the layout card with an empty band at its foot.
    readonly property real _fitW: {
        const it = body.item;
        // qmllint disable missing-property
        const v = it ? it.fitW : undefined;
        // qmllint enable missing-property
        return v !== undefined ? Number(v) : 0;
    }
    readonly property real _fitH: {
        const it = body.item;
        // qmllint disable missing-property
        const v = it ? it.fitH : undefined;
        // qmllint enable missing-property
        return v !== undefined ? Number(v) : 0;
    }

    readonly property bool _isLevel: root.kind === "volume" || root.kind === "mic" || root.kind === "brightness"

    Component {
        id: levelC
        OsdLevel {
            kind: root.kind
            orientation: root.orientation
            payload: root.payload
            interactive: root.interactive
            style: root._style
            renderScale: root.renderScale
        }
    }
    Component {
        id: stopsC
        OsdStops {
            kind: root.kind
            orientation: root.orientation
            payload: root.payload
            interactive: root.interactive
            style: root._style
            renderScale: root.renderScale
        }
    }
    Component {
        id: lockC
        OsdLockKeys {
            kind: root.kind
            orientation: root.orientation
            payload: root.payload
            interactive: root.interactive
            style: root._style
            renderScale: root.renderScale
        }
    }
    Component {
        id: layoutC
        OsdLayoutCode {
            kind: root.kind
            orientation: root.orientation
            payload: root.payload
            interactive: root.interactive
            style: root._style
            renderScale: root.renderScale
        }
    }
    Component {
        id: cardC
        OsdCard {
            kind: root.kind
            orientation: root.orientation
            payload: root.payload
            interactive: root.interactive
            style: root._style
            renderScale: root.renderScale
        }
    }
    Component {
        id: trackC
        OsdTrack {
            kind: root.kind
            orientation: root.orientation
            payload: root.payload
            interactive: root.interactive
            style: root._style
            renderScale: root.renderScale
        }
    }
    Component {
        id: captionC
        OsdCaption {
            kind: root.kind
            orientation: root.orientation
            payload: root.payload
            interactive: root.interactive
            style: root._style
            renderScale: root.renderScale
        }
    }
    Component {
        id: captureC
        OsdCapture {
            kind: root.kind
            orientation: root.orientation
            payload: root.payload
            interactive: root.interactive
            style: root._style
            renderScale: root.renderScale
        }
    }

    function _componentFor(kind) {
        switch (root._style.familyOf(kind)) {
        case "level":
            return levelC;
        case "stops":
            return stopsC;
        case "lock":
            return lockC;
        case "layout":
            return layoutC;
        case "track":
            return trackC;
        case "capture":
            return captureC;
        case "caption":
            return captionC;
        default:
            return cardC;
        }
    }

    // THE CARD IS LAID OUT AT THE SIZE IT ASKED FOR, centred in whatever box it is handed (CLAUDE.md: a page laid out at
    // the host's easing box re-lays out while the host opens). The engine hands a content the animated box -- tiny at
    // birth, then growing, overshooting, folding for a dip -- and a card that filled it would be squeezed into every one of
    // those sizes: a layout name elided from 'B...' to 'Belgian', a screenshot's title on two lines and then one, a
    // slider whose groove is a few pixels long when a second mute key arrives. The card has its own size from
    // its first frame and the growing box reveals it (at rest the two agree, to the pixel). Centred BY HAND, not
    // rounded: the box's centre holds still while it grows, so the card's place is exactly where it will rest -- a
    // rounded offset of a box that grows in fractions flips by a pixel and the whole card shimmers.
    Loader {
        id: body
        width: root.implicitWidth
        height: root.implicitHeight
        x: (root.width - width) / 2
        y: (root.height - height) / 2
        sourceComponent: root.kind.length > 0 ? root._componentFor(root.kind) : null
        onLoaded: {
            root.bornKind = root.payload && root.payload.kind !== undefined ? String(root.payload.kind) : "";
            root.bornSize = { w: root.implicitWidth, h: root.implicitHeight };
        }
    }

    Connections {
        target: body.item
        ignoreUnknownSignals: true
        function onUserValue(v) {
            root.userValue(v);
        }
        function onUserToggleMute() {
            root.userToggleMute();
        }
        function onUserToggleBoost() {
            root.userToggleBoost();
        }
        function onTouched() {
            root.touched();
        }
        function onActivated() {
            root.activated();
        }
        function onTrashRequested() {
            root.trashRequested();
        }
        function onHideRequested() {
            root.hideRequested();
        }
    }

    HoverHandler {
        id: hover
        enabled: root.interactive
    }

    // One reader of the wheel and of the middle button, ABOVE the slider (whose
    // own MouseArea would otherwise take both). No other button reaches it, so
    // the ball's drag and its right-click boost stay the slider's.
    WheelArea {
        anchors.fill: parent
        z: 5
        enabled: root.interactive && root._isLevel
        acceptedButtons: Qt.MiddleButton
        onClicked: {
            if (root.kind !== "brightness") {
                root.userToggleMute();
                root.touched();
            }
        }
        turned: wheel => {
            const it = body.item as OsdLevel;
            const dy = root.wheelUnits(wheel.angleDelta.y, wheel.pixelDelta.y, wheel.inverted);
            if (dy !== 0 && it)
                it.wheelStep(dy / 120);
            if (dy !== 0)
                root.touched();
            // Always taken: the slider's own wheel would read a sideways one
            // as a notch DOWN.
            wheel.accepted = true;
        }
    }
}
