pragma ComponentBehavior: Bound

import QtQuick

import "../../common/components"
import "../../common/theme"

// =============================================================================
// LockMediaSlot.qml -- the one reclaimable 92 px slot at the foot of the popup.
//
//   mpd has a track  a mini vinyl and the track: title, artist (the album is the third, faint
//   (playing or      line, when there is one), and three buttons -- previous, play / pause,
//   paused)          next -- on the shell's raised material, for a machine whose function keys
//                    have no media marks. The record spins only while
//                    it plays AND `active` -- a lock at rest holds it still, which is what
//                    lets the lock stop drawing; the TEXT and the cover follow the track
//                    whatever `active` says (a title is a binding, not an animation). A
//                    pause keeps the card: the way back to play is a button on it.
//   otherwise        the wiki's compact card, variant "lock" (the row 440 x 92
//                    it was built to: not interactive, discover only), loaded
//                    by URL so a change to the wiki module can never stop the
//                    lock from coming up -- a card that fails to load, or has
//                    nothing to show (`collapseWhenEmpty`), leaves the slot at
//                    height 0
//   neither          the slot has no height and the popup closes over it
//
// The slot's `implicitHeight` is the fact the popup sizes from: 92 for the
// record, the card's own for the card, 0 for nothing. It never animates itself
// -- the engine eases the popup's box (260 ms OutCubic) -- and what fades is
// only the newcomer: on a mode change the old view is gone at once and the new
// one fades in (160 ms), never two layouts through each other.
//
// `mpd` is anything with `playing`, `current` ({ title, artist, album, file })
// and, optionally, `playState` ("play" | "pause" | "stop"), `coverUrlFor(file)`
// and the player's verbs `prev()`, `toggle()`, `next()` (a button of a verb the
// service lacks does nothing). Nothing here starts a process, opens a URL or
// reads a singleton. THE BUTTONS ARE THE ONE PLACE THE POPUP TAKES THE POINTER:
// `controlsItem` is their strip, which the shell adds to its locked input
// region (ShellScreen; the rest of the window leaves the pointer to the lock).
// =============================================================================
Item {
    id: root

    property var mpd: null
    property var wikiService: null
    property bool active: true
    property real renderScale: 1
    property string fontFamily: "Audiowide"

    property real slotHeight: 92
    property real radius: 14
    property real padding: 12
    property real discItem: 96
    property real spinMs: 1800
    property real titleSize: 14
    property real artistSize: 12
    property real albumSize: 10
    property real lineGap: 4
    property int fadeMs: 160
    property real buttonSize: 48
    property real buttonGap: 10
    property string glyphFont: "Symbols Nerd Font"

    implicitWidth: 560
    implicitHeight: root._mode === "vinyl" ? root.slotHeight
        : (root._mode === "wiki" && wikiLoader.item ? Math.round((wikiLoader.item as Item).implicitHeight) : 0)

    // THE PLAYER'S STATE IS READ ONCE. `playing` and `playState` of the real service are two properties of one value, and a binding that reads
    // both sees them from different generations: on a pause `playing` goes false while `playState` still says "play", so for one turn
    // the card would have no track, its mode would be "none", and the newcomer's fade (below) would play the whole card in again -- a flash
    // on every pause and never on a resume. A stub with no `playState` gives `playing`.
    readonly property string _state: !root.mpd ? "stop"
        : (typeof root.mpd.playState === "string" ? root.mpd.playState : (root.mpd.playing ? "play" : "stop"))
    readonly property bool playing: root._state === "play"
    readonly property var track: root.mpd && root.mpd.current ? root.mpd.current : null
    // a track under the needle, playing or paused (a stopped player has none to show)
    readonly property bool _hasTrack: !!root.track && (root._state === "play" || root._state === "pause")
    // What may stand here, in order of preference: the first that has something to show.
    property var order: ["music", "wiki"]
    readonly property string _mode: {
        for (let i = 0; i < root.order.length; i++) {
            if (root.order[i] === "music" && root._hasTrack)
                return "vinyl";
            if (root.order[i] === "wiki" && root.wikiService)
                return "wiki";
        }
        return "none";
    }
    // what a test reads: the words and the cover the slot shows
    readonly property alias titleText: titleLine.text
    readonly property alias artistText: artistLine.text
    readonly property alias albumText: albumLine.text
    // the three buttons' strip (the shell's locked input region)
    readonly property alias controlsItem: controls
    readonly property real controlsWidth: 3 * root.buttonSize + 2 * root.buttonGap

    // The newcomer's fade: 0 -> 1 when the mode changes.
    property real _in: 1
    NumberAnimation {
        id: inAnim
        target: root
        property: "_in"
        from: 0
        to: 1
        duration: root.fadeMs
        easing.type: Easing.OutCubic
    }
    on_ModeChanged: {
        if (root.active)
            inAnim.restart();
        else
            root._in = 1;
    }

    // ---- the record -----------------------------------------------------------
    Item {
        id: vinylView
        anchors.fill: parent
        visible: root._mode === "vinyl"
        opacity: root._in

        ShadowBox {
            anchors.fill: parent
            baseRadius: root.radius
            surfaceColor: Theme.surface
            backgroundColor: Theme.listBox
            bevelColor: Theme.bevel
            shadowColor: Theme.border
            bevelWidth: 1
            shadowWidth: 3
        }
        VinylDisc {
            id: disc
            width: root.discItem
            height: root.discItem
            // The record's own 92 px slot: its centre one padding-less inset
            // from the left, whole pixels.
            x: Math.round(root.slotHeight / 2 - root.discItem / 2)
            y: Math.round(root.slotHeight / 2 - root.discItem / 2)
            albumArt: root.mpd && root.track && typeof root.mpd.coverUrlFor === "function" ? root.mpd.coverUrlFor(root.track.file) : ""
            NumberAnimation on spinDeg {
                from: 0
                to: 360
                duration: root.spinMs
                loops: Animation.Infinite
                running: root.playing && root.active && vinylView.visible && !Theme.crossfading
            }
        }
        Column {
            x: root.slotHeight
            y: Math.round((root.slotHeight - height) / 2)
            width: root.width - root.slotHeight - root.controlsWidth - 2 * root.padding
            spacing: root.lineGap
            Text {
                id: titleLine
                width: parent.width
                elide: Text.ElideRight
                text: root.track ? String(root.track.title || "") : ""
                color: Theme.textPrimary
                font.family: root.fontFamily
                font.pixelSize: root.titleSize
                font.bold: true
            }
            Text {
                id: artistLine
                width: parent.width
                elide: Text.ElideRight
                text: root.track ? String(root.track.artist || "") : ""
                color: Theme.textMuted
                font.family: root.fontFamily
                font.pixelSize: root.artistSize
            }
            Text {
                id: albumLine
                width: parent.width
                elide: Text.ElideRight
                text: root.track ? String(root.track.album || "") : ""
                color: Theme.textFaint
                font.family: root.fontFamily
                font.pixelSize: root.albumSize
            }
        }

        // ---- previous / play-pause / next -----------------------------------------
        Row {
            id: controls
            x: root.width - root.padding - root.controlsWidth
            y: Math.round((root.slotHeight - root.buttonSize) / 2)
            spacing: root.buttonGap
            // the strip answers a pointer only while the card is there
            enabled: vinylView.visible
            Repeater {
                model: ["prev", "toggle", "next"]
                RaisedButton {
                    id: tb
                    required property string modelData
                    width: root.buttonSize
                    height: root.buttonSize
                    minWidth: 0
                    horizontalPadding: 0
                    radius: root.buttonSize / 2
                    bold: false
                    fontFamily: root.glyphFont
                    fontPixelSize: Math.round(root.buttonSize * 0.5)
                    text: tb.modelData === "prev" ? "\u{F04AE}"
                        : tb.modelData === "next" ? "\u{F04AD}"
                        : (root.playing ? "\u{F03E4}" : "\u{F040A}")
                    accent: tb.modelData === "toggle"
                    surfaceColor: Theme.listBox
                    plateauColor: Theme.buttonPlateau
                    plateauHoverColor: Theme.buttonPlateauHover
                    bevelColor: Theme.buttonBevel
                    shadowColor: Theme.buttonShadow
                    accentColor: Theme.accent
                    accentHoverColor: Theme.accentHover
                    accentBevelColor: Theme.accentBevel
                    accentTextColor: Theme.textOnAccent
                    textColor: Theme.textMuted
                    bevelWidth: 1
                    shadowWidth: 3
                    onClicked: root.verb(tb.modelData)
                }
            }
        }
    }

    // A button's verb, asked of the player (a missing one does nothing).
    signal verbAsked(string verb)
    function verb(name: string): void {
        root.verbAsked(name);
        if (root.mpd && typeof root.mpd[name] === "function")
            root.mpd[name]();
    }

    // ---- the wiki card ----------------------------------------------------------
    Loader {
        id: wikiLoader
        anchors.left: parent.left
        anchors.top: parent.top
        width: root.width
        active: root._mode === "wiki"
        source: "../../wiki/WikiCompactCard.qml"
        opacity: root._in
    }
    Binding {
        target: wikiLoader.item
        when: wikiLoader.item !== null
        property: "service"
        value: root.wikiService
    }
    Binding {
        target: wikiLoader.item
        when: wikiLoader.item !== null
        property: "variant"
        value: "lock"
    }
    Binding {
        target: wikiLoader.item
        when: wikiLoader.item !== null
        property: "collapseWhenEmpty"
        value: true
    }
    Binding {
        target: wikiLoader.item
        when: wikiLoader.item !== null
        property: "active"
        value: root.active
    }
    Binding {
        target: wikiLoader.item
        when: wikiLoader.item !== null
        property: "attended"
        value: root.active
    }
    Binding {
        target: wikiLoader.item
        when: wikiLoader.item !== null
        property: "groundColor"
        value: Theme.surface
    }
    Binding {
        target: wikiLoader.item
        when: wikiLoader.item !== null
        property: "fontFamily"
        value: root.fontFamily
    }
    Binding {
        target: wikiLoader.item
        when: wikiLoader.item !== null
        property: "renderScale"
        value: root.renderScale
    }
    Binding {
        target: wikiLoader.item
        when: wikiLoader.item !== null
        property: "width"
        value: root.width
    }
}
