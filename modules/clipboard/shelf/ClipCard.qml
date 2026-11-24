pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/icons"
import "../../common/components/Mix.js" as Mix
import "../../common/components/RelTime.js" as RelTime
import "faces"
import ".."

// =============================================================================
// ClipCard.qml -- one card of the shelf: the box, a face by kind, a footer.
//
// A card is POOLED. The shelf builds one per kind it shows, hands it its
// record with assign(), and takes it back with release(): a card is not built
// and torn down per row crossing the view's edge (LauncherGrid's lesson, and
// CLAUDE.md's "a Loader that hands its item its data runs every binding
// twice" -- the kind is an initial property, the Loader's component is
// chosen once, and the face's bindings read the card they are in).
//
// MATERIAL. A card is something you pick, so it is the tile of the notes grid:
//   "lift"  at rest carved into the surface (a container with its content);
//           the focused card stands proud -- the raised box fades in over the
//           carved one and the whole card rises `liftPx`. ONE fraction
//           (`focusF`) drives box, rise and the star.
//   "well"  at rest a raised tile; the shelf's carved well glides under the
//           focused one. The card itself does not change.
// Colours are mixed from a FRACTION (Mix.js), never a Behavior on a colour.
//
// FOOTER. Source app icon (full colour), the relative time, and on the right
// the one slot of the card that changes with the keyboard: the digit while Alt
// is held, else the pin star (an entry's; a secret has none). A pick-order
// badge sits left of it. A pinned entry with a title shows the title as the
// first line.
// =============================================================================
Item {
    id: card

    // Device px per design px here (the nearest ScaleRoot's, else the window's).
    DeviceScale {
        id: dev
    }

    // The shelf this card serves (its style, clock, lookups) and the kind of
    // face it carries, both fixed at creation.
    required property var shelf
    required property string faceKind

    // What the shelf hands it on every assign().
    property int index: -1
    property var item: null                    // { key, type, d }

    readonly property ClipStyle st: card.shelf.st
    readonly property var d: card.item ? card.item.d : null
    readonly property string key: card.item ? card.item.key : ""
    readonly property bool isSecret: !!card.item && card.item.type === "secret"
    readonly property bool lift: card.st.focusStyle !== "well"

    // ---- the fractions (each one clock) -------------------------------------
    property bool _snap: false
    readonly property bool focused: card.key !== "" && card.shelf.focusKey === card.key
    property real focusF: card.focused ? 1 : 0
    Behavior on focusF {
        enabled: !card._snap
        NumberAnimation {
            duration: card.st.focusMs
            easing.type: Easing.OutCubic
        }
    }
    readonly property bool hovered: card.key !== "" && card.shelf.hoverKey === card.key
    property real hoverF: card.hovered ? 1 : 0
    Behavior on hoverF {
        enabled: !card._snap
        NumberAnimation {
            duration: 120
            easing.type: Easing.OutCubic
        }
    }
    // A card the shelf shows because the list was re-cut fades in.
    property real presence: 1
    NumberAnimation {
        id: fadeIn
        target: card
        property: "presence"
        from: 0
        to: 1
        duration: card.st.presenceMs
        easing.type: Easing.OutCubic
    }
    function appear(): void {
        card.presence = 0;
        fadeIn.restart();
    }

    // Take a record. Snapped: nothing eases out of the last row's state.
    function assign(index: int, item: var, fade: bool): void {
        card._snap = true;
        fadeIn.stop();
        card.presence = 1;
        card.index = index;
        card.item = item;       // focusF / hoverF follow at once: their Behaviors are off while _snap
        card._snap = false;
        if (fade)
            card.appear();
    }

    // ---- geometry -------------------------------------------------------------
    readonly property int pad: card.st.cardPadding
    readonly property int footH: 18
    readonly property bool titled: !!card.d && !card.isSecret && card.d.pinned === true && !!card.d.title
    readonly property int titleH: card.titled ? 18 : 0
    readonly property int faceW: Math.max(0, card.width - 2 * card.pad)
    readonly property int faceY: card.pad + card.titleH
    readonly property int faceH: Math.max(0, card.height - card.pad - card.footH - 6 - card.faceY)
    readonly property int lineSpare: card.titled ? 1 : 0

    // What the card sits on, for the faces' own carved things.
    readonly property color fill: card.lift ? Mix.c(Theme.listBox, Theme.buttonPlateau, card.focusF) : Theme.buttonPlateau

    width: card.st.cardWidth
    height: card.st.cardHeight
    // Placed by index: the slot, the slide of a new copy, and the lift.
    x: card.index >= 0 ? card.shelf.slotX(card.index) + card.shelf.slideOffset(card.index) : 0
    y: card.shelf.slotY() - (card.lift ? card.st.liftPx * card.focusF : 0)
    visible: card.item !== null
    opacity: card.presence * card.shelf.arriveFactor(card.index)
    z: card.focusF > 0.01 ? 1 : 0

    // ---- the box ------------------------------------------------------------------
    ShadowBox {
        id: carved
        anchors.fill: parent
        visible: card.lift && card.focusF < 0.999
        opacity: 1 - card.focusF
        baseWidth: card.width
        baseHeight: card.height
        baseRadius: card.st.cardRadius
        surfaceColor: card.shelf.ground
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        backgroundColor: Mix.c(Theme.listBox, Theme.panelSunk, 0.5 * card.hoverF)
        bevelWidth: 1
        shadowWidth: 3
    }
    ShadowBox {
        id: raised
        anchors.fill: parent
        visible: !card.lift || card.focusF > 0.001
        opacity: card.lift ? card.focusF : 1
        baseWidth: card.width
        baseHeight: card.height
        baseRadius: card.st.cardRadius
        raised: true
        shadowToAlpha: true
        surfaceColor: card.shelf.ground
        bevelColor: Theme.buttonBevel
        shadowColor: Theme.buttonShadow
        backgroundColor: Mix.c(Theme.buttonPlateau, Theme.buttonPlateauHover, card.hoverF)
        bevelWidth: 1.5
        shadowWidth: 5
        shadowEdgeAlpha: 0.9
    }

    // ---- title (a pinned entry that has one) ----------------------------------------
    Text {
        visible: card.titled
        x: card.pad
        y: card.pad
        width: card.faceW
        text: card.titled ? String(card.d.title) : ""
        textFormat: Text.PlainText
        elide: Text.ElideRight
        maximumLineCount: 1
        color: Theme.textPrimary
        font.family: "Inter"
        font.pixelSize: 12
        font.bold: true
        lineHeight: 16
        lineHeightMode: Text.FixedHeight
    }

    // ---- the face -----------------------------------------------------------------------
    Loader {
        id: faceLoader
        objectName: "clipFace"
        x: card.pad
        y: card.faceY
        width: card.faceW
        height: card.faceH
        sourceComponent: {
            switch (card.faceKind) {
            case "code":
                return codeC;
            case "link":
                return linkC;
            case "colour":
                return colourC;
            case "image":
                return imageC;
            case "files":
                return filesC;
            case "sealed":
                return sealedC;
            default:
                return textC;
            }
        }
    }
    Component {
        id: textC
        TextFace {
            rec: card.d
            fw: card.faceW
            fh: card.faceH
            lines: card.st.textLines - card.lineSpare
        }
    }
    Component {
        id: codeC
        CodeFace {
            rec: card.d
            fw: card.faceW
            fh: card.faceH
            lines: card.st.codeLines - card.lineSpare
        }
    }
    Component {
        id: linkC
        LinkFace {
            rec: card.d
            fw: card.faceW
            fh: card.faceH
            lines: card.st.textLines - card.lineSpare
        }
    }
    Component {
        id: colourC
        ColourFace {
            rec: card.d
            fw: card.faceW
            fh: card.faceH
            ground: card.fill
            radius: Math.max(4, card.st.cardRadius - 2)
        }
    }
    Component {
        id: imageC
        ImageFace {
            rec: card.d
            fw: card.faceW
            fh: card.faceH
            stateDir: card.shelf.stateDir
            fit: card.st.thumbFit
            radius: Math.max(4, card.st.cardRadius - 2)
            fadeMs: card.st.presenceMs
        }
    }
    Component {
        id: filesC
        FilesFace {
            rec: card.d
            fw: card.faceW
            fh: card.faceH
            lines: card.st.textLines - card.lineSpare
        }
    }
    Component {
        id: sealedC
        SealedFace {
            rec: card.d
            fw: card.faceW
            fh: card.faceH
            apps: card.shelf.apps
            now: card.shelf.secretNow
            ringSize: card.st.ringSize
            ground: card.fill
            peekText: card.shelf.peekKey !== "" && card.shelf.peekKey === card.key ? card.shelf.peekText : ""
            onKeepClicked: card.shelf.keepClicked(card.key)
        }
    }

    // ---- footer -----------------------------------------------------------------------------
    readonly property var appInfo: {
        const cls = card.d && card.d.source ? card.d.source.cls : "";
        return card.shelf.apps && cls ? (card.shelf.apps.serial >= 0 ? card.shelf.apps.app(cls) : null) : null;
    }
    readonly property string iconSource: {
        const n = card.appInfo ? card.appInfo.icon : "";
        return n ? AppIcons.checkedPath(n) : "";
    }
    // When the card's thing happened: an entry's last copy, a secret's seal.
    readonly property double stamp: !card.d ? 0 : (card.isSecret ? (card.d.t || 0) : (card.d.last || card.d.first || 0))
    readonly property bool imported: !!card.d && !card.isSecret && card.d.via === "import" && !(card.d.last > 0)
    // A card never reads a clock older than the wall (NoteTile's rule): `now`
    // moves on a boundary somebody asked for, and a card built after the last
    // one would otherwise read a stale instant.
    readonly property var rel: card.stamp > 0 ? RelTime.format(card.stamp, Math.max(card.shelf.clock.now, Date.now())) : null
    onRelChanged: card._ask()
    onItemChanged: card._ask()
    function _ask(): void {
        if (card.rel && card.rel.nextMs > 0 && card.visible)
            card.shelf.clock.request(Math.max(card.rel.nextMs, Date.now() + 1));
    }

    readonly property int footY: card.height - card.pad - card.footH

    Item {
        id: icon
        x: card.pad
        y: card.footY + 1
        width: 16
        height: 16
        Image {
            id: iconImg
            anchors.fill: parent
            visible: status === Image.Ready
            source: card.iconSource
            // twice the 16 px slot, and more when the glass shows it larger (a cap, constant under layout: never re-decoded by a resize)
            sourceSize.width: Math.round(32 * Math.max(1, dev.value))
            sourceSize.height: Math.round(32 * Math.max(1, dev.value))
            asynchronous: true
            cache: true
            smooth: true
            mipmap: true
        }
        Rectangle {
            anchors.fill: parent
            visible: !iconImg.visible && card.appInfo !== null
            radius: 4
            color: Theme.panelSunk
            Text {
                anchors.centerIn: parent
                text: card.appInfo && card.appInfo.name ? card.appInfo.name.charAt(0).toUpperCase() : ""
                color: Theme.textMuted
                font.family: "Inter"
                font.pixelSize: 10
                font.bold: true
            }
        }
    }
    Text {
        x: card.pad + 16 + 6
        y: card.footY
        height: card.footH
        width: Math.max(0, pickSlot.x - x - 4)
        verticalAlignment: Text.AlignVCenter
        text: card.imported ? "imported" : (card.rel ? card.rel.text : "")
        elide: Text.ElideRight
        color: Theme.textFaint
        font.family: "Inter"
        font.pixelSize: 11
    }

    // The right-hand slots, from the edge in: [digit | star] then [pick badge].
    readonly property int slotSize: card.st.badgeSize
    readonly property int markOrder: card.item ? card.shelf.marks.indexOf(card.key) + 1 : 0
    readonly property int digit: card.item ? card.shelf.digitFor(card.index) : 0

    Item {
        id: pickSlot
        x: card.width - card.pad - card.slotSize - 6 - card.slotSize
        y: card.footY + Math.floor((card.footH - card.slotSize) / 2)
        width: card.slotSize
        height: card.slotSize
        visible: card.markOrder > 0
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: Theme.accent
            Text {
                anchors.centerIn: parent
                text: card.markOrder > 0 ? card.markOrder : ""
                color: Theme.textOnAccent
                font.family: "Inter"
                font.pixelSize: 11
                font.bold: true
            }
        }
    }

    Item {
        id: lastSlot
        x: card.width - card.pad - card.slotSize
        y: card.footY + Math.floor((card.footH - card.slotSize) / 2)
        width: card.slotSize
        height: card.slotSize

        // The digit, while Alt is held: the card's Alt+n paste, named.
        Rectangle {
            anchors.fill: parent
            visible: card.digit > 0
            radius: width / 2
            color: Theme.surface
            border.width: 1
            border.color: Theme.border
            Text {
                anchors.centerIn: parent
                text: card.digit > 0 ? card.digit : ""
                color: Theme.textPrimary
                font.family: "Inter"
                font.pixelSize: 11
                font.bold: true
            }
        }

        // The pin star: an entry's. Pinned is always there; an unpinned one is
        // only there for the pointer and the keyboard focus -- the icon is the
        // control, nothing announces it.
        Text {
            id: star
            readonly property bool pinned: !!card.d && !card.isSecret && card.d.pinned === true
            readonly property real starHover: starArea.containsMouse ? 1 : 0
            visible: card.digit === 0 && !card.isSecret && (star.pinned || star.shown > 0.01)
            readonly property real shown: Math.max(card.hoverF, card.focusF)
            opacity: star.pinned ? 1 : star.shown
            anchors.centerIn: parent
            text: ""
            font.family: "Symbols Nerd Font"
            font.pixelSize: 13
            color: star.pinned ? Mix.c(Theme.accent, Theme.accentHover, star.starHover) : Mix.c(Theme.textFaint, Theme.accent, star.starHover)
        }
        MouseArea {
            id: starArea
            anchors.fill: parent
            anchors.margins: -3
            visible: card.digit === 0 && !card.isSecret
            enabled: visible
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: card.shelf.pinClicked(card.key)
        }
    }
}
