pragma ComponentBehavior: Bound

import QtQuick

import "../../../common/theme"
import "../../../common/components"
import "../../../common/components/Mix.js" as Mix

// =============================================================================
// PlayerTransport.qml
//
// The classic transport row: shuffle · prev · play/pause · next · repeat, with
// a burger on the right that asks for the queue and a view toggle on the left
// that mirrors it. Nothing here knows what MPD is; it shows five booleans and
// emits seven signals, and the service decides what "repeat one" means (it is
// MPD's `single` + `repeat`, which is the service's business, not a button's).
//
// WHY RaisedButton. A carved glyph is an engraved mark, the language of a
// container, and the shell's rule is that buttons stand PROUD. A colour
// `Behavior` on a button's fill, shadow or bevel would be a second clock
// downstream of the theme, so six of them would lag every light/dark switch.
// RaisedButton is the plateau, eases its hover as a FRACTION through Mix.js, and
// takes any font -- so a Nerd Font glyph is just its label, exactly as CodeBlock's
// copy button does it.
//
// WHAT SITS IN THE SLOT ON THE LEFT. The five transport buttons are centred
// and the burger is pinned right, so the implicit width reserves the same slot
// on both sides -- the five sit dead centre at every width the host can give,
// including the smallest, and the row is symmetric: space left equals space
// right, the way space above equals space below. The left slot holds the view
// toggle, so the row is symmetric in its CONTENT as well as in its spacing.
// `showViewToggle: false` empties the slot and the five stay exactly where they
// are.
//
// ONE MARK PER FACT. The play button is the accent one because it is the
// primary action, the way a prompt's default answer is. The two toggles and
// the burger say on/off with the INK of their glyph and nothing else -- no
// crossed-out shuffle next to a dimmed one, no second plateau colour. The
// repeat glyph swaps to the "repeat once" mark for `repeatMode: "one"`,
// because all-versus-one is a fact a colour cannot carry.
//
// The view toggle carries its fact in the GLYPH alone -- arrows out of the
// box in the small view, arrows into it in the large one -- and its ink never
// lights. `miniView` is not an on/off state the way `browseOpen` is: it is
// which of two views is showing, and the glyph that says which way the button
// goes has already said it. Accent ink would be a second mark for the one
// fact, which is the thing this shell does not do.
//
// The ink swap eases as a 0..1 fraction mixed with Mix.c, never as a
// `Behavior on color`: the theme is already one clock and a second one below
// it can only lag (tools/dev/theme_sync_probe.sh fails on any).
//
// Hover tips name the controls. A glyph is a mark that cannot be read, and
// HoverTip is this shell's answer to that; the repeat button in particular
// has three states and one shape. They need `overlayItem` -- the popup's
// overlay layer -- or they are clipped by the card they sit in. Their hover
// state is read off RaisedButton's `_hovered` (it publishes no public
// `hovered`), because a second hover MouseArea over the button would only
// steal the hover from the button's own wash.
//
// Sized through implicitWidth/implicitHeight only, paints no background: the
// host paints the surface. The drop shadows paint ~shadowWidth OUTSIDE the
// item, as every raised ShadowBox in the shell does.
// =============================================================================
Item {
    id: root

    // ---- What it shows ----
    property bool playing: false
    property string repeatMode: "off"       // "off" | "all" | "one"
    property bool shuffleOn: false
    property bool browseOpen: false         // the burger's state
    // Which view the host is in, so the toggle can say which way it goes.
    property bool miniView: false
    property bool showViewToggle: true

    // ---- What the host must perform ----
    signal playPauseRequested()
    signal nextRequested()
    signal prevRequested()
    signal shuffleToggled()
    signal repeatCycled()                   // off -> all -> one -> off
    signal browseToggled()
    signal viewToggleRequested()            // mini <-> player

    // ---- Geometry ----
    property real buttonSize: 38
    property real spacing: 10
    // A transport button is a disc: the shape every player has used for
    // decades, and to ShadowBox it is only a radius, so the bevel and the
    // drop shadow follow the contour unchanged.
    property real buttonRadius: root.buttonSize / 2
    property real glyphSize: Math.round(root.buttonSize * 0.5)

    // ---- Type ----
    // `fontFamily` is the module's text font; it dresses the hover tips.
    // The glyphs come from their own family, so a host restyling the shell's
    // words does not silently blank the marks.
    property string fontFamily: "Inter"
    property string glyphFontFamily: "Symbols Nerd Font"

    // ---- Glyph slots (Material Design Nerd Font, 4-byte codepoints written
    // as \u{XXXXX} so the source survives any 3-byte PUA mangling) ----
    property string glyphShuffle:   "\u{F049D}"   // 󰒝 md-shuffle
    property string glyphPrev:      "\u{F04AE}"   // 󰒮 md-skip_previous
    property string glyphPlay:      "\u{F040A}"   // 󰐊 md-play
    property string glyphPause:     "\u{F03E4}"   // 󰏤 md-pause
    property string glyphNext:      "\u{F04AD}"   // 󰒭 md-skip_next
    property string glyphRepeat:    "\u{F0456}"   // 󰑖 md-repeat
    property string glyphRepeatOne: "\u{F0458}"   // 󰑘 md-repeat_once
    property string glyphBurger:    "\u{F035C}"   // 󰍜 md-menu
    // The view toggle's two states: arrows out of the box (this view is the
    // small one, pressing opens it out) and arrows into it (this is the large
    // one, pressing folds it down). Both verified present in
    // SymbolsNerdFont-Regular.ttf; a missing glyph draws a blank button.
    // md-fullscreen / md-fullscreen_exit do not read as one mark in two states:
    // at 19 px the exit one is a cluster of four short ticks, where two mirrored
    // arrows do.
    property string glyphViewExpand:   "\u{F0616}"   // 󰘖 md-arrow_expand
    property string glyphViewCollapse: "\u{F0615}"   // 󰘕 md-arrow_collapse

    // ---- Palette (Theme defaults; a host may override every one) ----
    property color surfaceColor: Theme.surface          // the fill it stands on
    property color plateauColor: Theme.buttonPlateau
    property color plateauHoverColor: Theme.buttonPlateauHover
    property color bevelColor: Theme.buttonBevel
    property color shadowColor: Theme.buttonShadow
    property color accentColor: Theme.accent
    property color accentHoverColor: Theme.accentHover
    property color accentBevelColor: Theme.accentBevel
    property color textOnAccentColor: Theme.textOnAccent
    property color textColor: Theme.textPrimary
    property color mutedColor: Theme.textMuted
    property color tipSurfaceColor: Theme.surface
    property color tipBevelColor: Theme.bevel
    property color tipShadowColor: Theme.border
    property color tipTextColor: Theme.textPrimary

    // ---- Relief (button tuning: shadow 5, highlight 1.5) ----
    property real bevelWidth: 1.5
    property real shadowWidth: 5
    property real shadowEdgeAlpha: 0.55
    property int toggleMs: 140

    // ---- Tips ----
    property bool tipsEnabled: true
    property Item overlayItem: null         // the popup root; null = own parent
    property int tipDelayMs: 450
    property int tipFadeMs: 160

    // ---- Size ----
    // Five buttons, four gaps, and a burger slot reserved at each end.
    readonly property int _mainCount: 5
    readonly property real _mainWidth:
        root._mainCount * root.buttonSize + (root._mainCount - 1) * root.spacing
    implicitWidth: root._mainWidth + 2 * (root.spacing + root.buttonSize)
    implicitHeight: root.buttonSize

    // ---- Per-key state -------------------------------------------------------
    readonly property var _mainKeys: ["shuffle", "prev", "play", "next", "repeat"]

    function _glyphFor(key) {
        if (key === "shuffle") return root.glyphShuffle;
        if (key === "prev")    return root.glyphPrev;
        if (key === "play")    return root.playing ? root.glyphPause : root.glyphPlay;
        if (key === "next")    return root.glyphNext;
        if (key === "repeat")  return root.repeatMode === "one" ? root.glyphRepeatOne : root.glyphRepeat;
        if (key === "view")    return root.miniView ? root.glyphViewExpand : root.glyphViewCollapse;
        return root.glyphBurger;
    }
    // A toggle rests in muted ink and lights to the accent; an action rests in
    // primary ink, so the things that DO something read stronger than the
    // things that only modify how.
    function _isToggle(key) { return key === "shuffle" || key === "repeat"; }
    function _onFor(key) {
        if (key === "shuffle") return root.shuffleOn;
        if (key === "repeat")  return root.repeatMode !== "off";
        if (key === "burger")  return root.browseOpen;
        return false;
    }
    function _tipFor(key) {
        if (key === "shuffle") return "Shuffle";
        if (key === "prev")    return "Previous";
        if (key === "play")    return root.playing ? "Pause" : "Play";
        if (key === "next")    return "Next";
        if (key === "repeat")  return root.repeatMode === "one" ? "Repeat one"
                                    : root.repeatMode === "all" ? "Repeat all" : "Repeat off";
        // The tip names the action, not the view it would land in -- which is
        // the one thing the glyph cannot say on its own.
        if (key === "view")    return "toggle view";
        return "Queue";
    }
    function _activate(key) {
        if (key === "shuffle")      root.shuffleToggled();
        else if (key === "prev")    root.prevRequested();
        else if (key === "play")    root.playPauseRequested();
        else if (key === "next")    root.nextRequested();
        else if (key === "repeat")  root.repeatCycled();
        else if (key === "view")     root.viewToggleRequested();
        else                        root.browseToggled();
    }

    // ---- The five, centred --------------------------------------------------
    Row {
        id: mainRow
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        spacing: root.spacing

        Repeater {
            // A CONSTANT model: the keys never change, so no state change ever
            // destroys and rebuilds a button. Everything variable is a binding
            // inside the delegate.
            model: root._mainKeys

            RaisedButton {
                id: mainBtn
                required property string modelData

                width: root.buttonSize
                height: root.buttonSize
                minWidth: 0
                horizontalPadding: 0
                radius: root.buttonRadius

                text: root._glyphFor(mainBtn.modelData)
                fontFamily: root.glyphFontFamily
                fontPixelSize: root.glyphSize
                bold: false                 // the symbol font has no bold face

                accent: mainBtn.modelData === "play"

                property real onF: root._onFor(mainBtn.modelData) ? 1 : 0
                Behavior on onF { NumberAnimation { duration: root.toggleMs; easing.type: Easing.OutCubic } }

                surfaceColor: root.surfaceColor
                plateauColor: root.plateauColor
                plateauHoverColor: root.plateauHoverColor
                bevelColor: root.bevelColor
                shadowColor: root.shadowColor
                accentColor: root.accentColor
                accentHoverColor: root.accentHoverColor
                accentBevelColor: root.accentBevelColor
                accentTextColor: root.textOnAccentColor
                textColor: Mix.c(root._isToggle(mainBtn.modelData) ? root.mutedColor : root.textColor,
                                 root.accentColor, mainBtn.onF)

                bevelWidth: root.bevelWidth
                shadowWidth: root.shadowWidth
                shadowEdgeAlpha: root.shadowEdgeAlpha

                onClicked: root._activate(mainBtn.modelData)

                HoverTip {
                    anchorItem: mainBtn
                    overlayItem: root.overlayItem
                    // Declared ABOVE `show` on purpose: both re-evaluate when
                    // `tipsEnabled` flips, in this order, so the fade is already
                    // zero when the bubble is told to go. A tip dismissed by a
                    // view switch must vanish on that frame, not fade over the
                    // next ten of a layout that is moving under it.
                    fadeMs: root.tipsEnabled ? root.tipFadeMs : 0
                    show: root.tipsEnabled && mainBtn._hovered
                    text: root._tipFor(mainBtn.modelData)
                    delayMs: root.tipDelayMs
                    fontFamily: root.fontFamily
                    surfaceColor: root.tipSurfaceColor
                    bevelColor: root.tipBevelColor
                    shadowColor: root.tipShadowColor
                    textColor: root.tipTextColor
                }
            }
        }
    }

    // ---- The view toggle, pinned left ---------------------------------------
    // The burger's mirror image, to the pixel: same size, same radius, same
    // relief, the same distance from its own end of the row.
    RaisedButton {
        id: viewBtn
        visible: root.showViewToggle

        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: root.buttonSize
        height: root.buttonSize
        minWidth: 0
        horizontalPadding: 0
        radius: root.buttonRadius

        text: root._glyphFor("view")
        fontFamily: root.glyphFontFamily
        fontPixelSize: root.glyphSize
        bold: false

        surfaceColor: root.surfaceColor
        plateauColor: root.plateauColor
        plateauHoverColor: root.plateauHoverColor
        bevelColor: root.bevelColor
        shadowColor: root.shadowColor
        // No on-state: the glyph is the whole mark (see the header).
        textColor: root.mutedColor

        bevelWidth: root.bevelWidth
        shadowWidth: root.shadowWidth
        shadowEdgeAlpha: root.shadowEdgeAlpha

        onClicked: root._activate("view")

        HoverTip {
            anchorItem: viewBtn
            overlayItem: root.overlayItem
            // Declared ABOVE `show` on purpose: both re-evaluate when
            // `tipsEnabled` flips, in this order, so the fade is already
            // zero when the bubble is told to go. A tip dismissed by a
            // view switch must vanish on that frame, not fade over the
            // next ten of a layout that is moving under it.
            fadeMs: root.tipsEnabled ? root.tipFadeMs : 0
            show: root.tipsEnabled && viewBtn._hovered
            text: root._tipFor("view")
            delayMs: root.tipDelayMs
            fontFamily: root.fontFamily
            surfaceColor: root.tipSurfaceColor
            bevelColor: root.tipBevelColor
            shadowColor: root.tipShadowColor
            textColor: root.tipTextColor
        }
    }

    // ---- The burger, pinned right -------------------------------------------
    RaisedButton {
        id: burgerBtn

        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: root.buttonSize
        height: root.buttonSize
        minWidth: 0
        horizontalPadding: 0
        radius: root.buttonRadius

        text: root._glyphFor("burger")
        fontFamily: root.glyphFontFamily
        fontPixelSize: root.glyphSize
        bold: false

        property real onF: root._onFor("burger") ? 1 : 0
        Behavior on onF { NumberAnimation { duration: root.toggleMs; easing.type: Easing.OutCubic } }

        surfaceColor: root.surfaceColor
        plateauColor: root.plateauColor
        plateauHoverColor: root.plateauHoverColor
        bevelColor: root.bevelColor
        shadowColor: root.shadowColor
        textColor: Mix.c(root.mutedColor, root.accentColor, burgerBtn.onF)

        bevelWidth: root.bevelWidth
        shadowWidth: root.shadowWidth
        shadowEdgeAlpha: root.shadowEdgeAlpha

        onClicked: root._activate("burger")

        HoverTip {
            anchorItem: burgerBtn
            overlayItem: root.overlayItem
            // Declared ABOVE `show` on purpose: both re-evaluate when
            // `tipsEnabled` flips, in this order, so the fade is already
            // zero when the bubble is told to go. A tip dismissed by a
            // view switch must vanish on that frame, not fade over the
            // next ten of a layout that is moving under it.
            fadeMs: root.tipsEnabled ? root.tipFadeMs : 0
            show: root.tipsEnabled && burgerBtn._hovered
            text: root._tipFor("burger")
            delayMs: root.tipDelayMs
            fontFamily: root.fontFamily
            surfaceColor: root.tipSurfaceColor
            bevelColor: root.tipBevelColor
            shadowColor: root.tipShadowColor
            textColor: root.tipTextColor
        }
    }
}
