pragma ComponentBehavior: Bound

import QtQuick

import "../theme"
import "Mix.js" as Mix

// =============================================================================
// TileButton.qml -- a raised square tile with a glyph on it and its label under it: the phone's home-screen icon, in the
// shell's material. A control panel of actions (the bridge's Mirror / Files / Send ...) is a grid of these.
//
//   glyph        the mark, a code point of `glyphFamily` (a Nerd Font by default)
//   label        the word under the tile (11 px, body ink)
//   tileSize     the tile's side, 68
//   radius       the tile's corner, 14 (the shell's container radius: it meets a container's corner on the same curve)
//   surfaceColor the GROUND the tile stands on: its drop shadow fades into it, so a tile on a card takes the card's fill
//   enabledLook  false = the tile cannot act now: a faint glyph and label and no raised colour, but it stays hoverable
//                so its tip can say why
//   clickable    the pointer is a hand and a click is meant. Follows `enabledLook`; a host whose tile still does
//                something while it looks unavailable (it opens a page that explains) says true
//   active       a thing that is ON: the accent plateau and the text-on-accent glyph
//   actState     "idle" | "busy" | "done" | "failed" -- how the last call of this tile went. (Not `state`: an Item's own
//                `state` is FINAL.) Each look is an eased FRACTION mixed with Mix.js, never a colour animation, so a theme
//                switch is not chased by a clock of its own:
//                  busy    the glyph breathes (its presence rises and falls); the one clock behind it runs only while busy
//                  done    a short accent flash that decays by itself (only for a change into `done`, never at the build)
//                  failed  the error colour on glyph and plateau, kept until the state leaves
//   tip          what the tile says on hover, in `overlayItem` (HoverTip): the reason when it cannot act, the failure
//                after a failed call
//   clicked()    a click, whatever the look: the host decides what it does
//
// PRESSING sinks the tile: the raised shadow and highlight ease away while a carved copy of the same box fades in over it,
// so a plateau goes down into the surface and comes back up. HOVER is a short fade and the hand cursor, nothing else.
//
// Nothing here holds a `layer` and nothing animates a colour, so a tile can live on a face that is turned under a
// projection (the bridge's screen) and across a theme crossfade.
// =============================================================================
Item {
    id: tile

    property string glyph: ""
    property string label: ""
    property string glyphFamily: "Symbols Nerd Font"
    property string fontFamily: "Inter"
    property real tileSize: 68
    property real radius: 14
    property real glyphSize: 28
    property real labelSize: 11
    property real labelGap: 6
    property color surfaceColor: Theme.listBox
    property bool enabledLook: true
    property bool clickable: tile.enabledLook
    property bool active: false
    property string actState: "idle"
    property string tip: ""
    property Item overlayItem: null

    // The timings of its looks.
    property int pressMs: 90
    property int hoverMs: 120
    property int stateMs: 160
    property int breatheMs: 900
    property int flashMs: 700
    // How far the glyph's presence falls at the bottom of a breath.
    property real breatheDepth: 0.55

    signal clicked
    // the pointer is down on the tile (a host that wants a press-and-hold reads it)
    readonly property bool pressed: area.pressed

    implicitWidth: tile.tileSize
    implicitHeight: tile.tileSize + tile.labelGap + labelText.implicitHeight

    // ---- the fractions -------------------------------------------------------------------------------------------
    readonly property bool _hovered: area.containsMouse
    property real _press: area.pressed ? 1 : 0
    Behavior on _press {
        NumberAnimation {
            duration: tile.pressMs
            easing.type: Easing.OutCubic
        }
    }
    property real _hoverF: tile._hovered && tile.clickable ? 1 : 0
    Behavior on _hoverF {
        NumberAnimation {
            duration: tile.hoverMs
            easing.type: Easing.OutCubic
        }
    }
    property real _onF: tile.active ? 1 : 0
    Behavior on _onF {
        NumberAnimation {
            duration: tile.stateMs
            easing.type: Easing.OutCubic
        }
    }
    property real _enabledF: tile.enabledLook ? 1 : 0
    Behavior on _enabledF {
        NumberAnimation {
            duration: tile.stateMs
            easing.type: Easing.OutCubic
        }
    }
    property real _busyF: tile.actState === "busy" ? 1 : 0
    Behavior on _busyF {
        NumberAnimation {
            duration: tile.stateMs
            easing.type: Easing.OutCubic
        }
    }
    property real _failF: tile.actState === "failed" ? 1 : 0
    Behavior on _failF {
        NumberAnimation {
            duration: tile.stateMs
            easing.type: Easing.OutCubic
        }
    }
    // The flash: raised to 1 by a change into `done`, and let down by its own clock.
    property real _doneF: 0
    NumberAnimation {
        id: flash
        target: tile
        property: "_doneF"
        from: 1
        to: 0
        duration: tile.flashMs
        easing.type: Easing.OutCubic
    }
    onActStateChanged: {
        if (tile.actState === "done")
            flash.restart();
        else
            flash.stop();
        if (tile.actState !== "done")
            tile._doneF = 0;
    }
    // The breath: one clock, running only while the tile is busy; at rest nothing here ticks.
    property real _breath: 0
    SequentialAnimation {
        id: breathe
        running: tile.actState === "busy"
        loops: Animation.Infinite
        NumberAnimation {
            target: tile
            property: "_breath"
            from: 0
            to: 1
            duration: tile.breatheMs
            easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: tile
            property: "_breath"
            from: 1
            to: 0
            duration: tile.breatheMs
            easing.type: Easing.InOutSine
        }
        onRunningChanged: if (!breathe.running)
            tile._breath = 0
    }

    // ---- the colours (every one a mix of themed ends) ---------------------------------------------------------
    readonly property color _plateau: {
        const rest = Mix.c(Theme.buttonPlateau, Theme.buttonPlateauHover, tile._hoverF);
        const on = Mix.c(Theme.accent, Theme.accentHover, tile._hoverF);
        const lit = Mix.c(rest, on, tile._onF);
        const flashed = Mix.c(lit, Theme.accent, tile._doneF * 0.22);
        return Mix.c(flashed, Theme.errorTint, tile._failF);
    }
    readonly property color _ink: {
        const off = Theme.textFaint;
        const rest = Mix.c(off, Theme.textPrimary, tile._enabledF);
        const lit = Mix.c(rest, Theme.textOnAccent, tile._onF);
        const flashed = Mix.c(lit, Theme.accent, tile._doneF);
        return Mix.c(flashed, Theme.error, tile._failF);
    }
    readonly property color _labelInk: Mix.c(Theme.textFaint, Theme.textPrimary, tile._enabledF)

    // ---- the tile ---------------------------------------------------------------------------------------------------
    Item {
        id: plate
        width: tile.tileSize
        height: tile.tileSize

        ShadowBox {
            anchors.fill: parent
            baseWidth: plate.width
            baseHeight: plate.height
            baseRadius: tile.radius
            raised: true
            shadowToAlpha: true
            surfaceColor: tile.surfaceColor
            backgroundColor: tile._plateau
            bevelColor: Mix.c(Theme.buttonBevel, Theme.accentBevel, tile._onF)
            shadowColor: Theme.buttonShadow
            bevelWidth: Math.max(0.5, 1.5 * (1 - tile._press * 0.8))
            shadowWidth: Math.max(0.5, 5 * (1 - tile._press * 0.85))
            shadowEdgeAlpha: 0.9 * (1 - tile._press * 0.6)
        }
        // The same plateau carved: what the raised box becomes under a finger. It only fades in, over the raised box's
        // own fill, so nothing but the relief changes sides.
        ShadowBox {
            anchors.fill: parent
            baseWidth: plate.width
            baseHeight: plate.height
            baseRadius: tile.radius
            opacity: tile._press
            visible: tile._press > 0.01
            surfaceColor: "transparent"
            backgroundColor: tile._plateau
            bevelColor: Theme.bevel
            shadowColor: Theme.border
            bevelWidth: 1
            shadowWidth: 3
        }
        Text {
            id: mark
            anchors.centerIn: parent
            anchors.verticalCenterOffset: tile._press
            text: tile.glyph
            color: tile._ink
            opacity: 1 - tile.breatheDepth * tile._breath * tile._busyF
            font.family: tile.glyphFamily
            font.pixelSize: tile.glyphSize
        }
    }

    Text {
        id: labelText
        y: tile.tileSize + tile.labelGap
        width: tile.tileSize
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        text: tile.label
        color: tile._labelInk
        font.family: tile.fontFamily
        font.pixelSize: tile.labelSize
    }

    MouseArea {
        id: area
        width: tile.tileSize
        height: tile.tileSize
        hoverEnabled: true
        cursorShape: tile.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: tile.clicked()
    }

    HoverTip {
        anchorItem: plate
        overlayItem: tile.overlayItem
        text: tile.tip
        show: area.containsMouse && tile.tip !== ""
    }
}
