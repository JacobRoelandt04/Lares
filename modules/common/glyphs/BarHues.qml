pragma Singleton

import QtQuick

import "../theme"
import "BarHues.js" as Hues

// =============================================================================
// BarHues.qml -- the bar's glyph colours, ONE table for every module (feedback "Bar glyphs overhaul and unification").
//
// Every glyph in the bar has a HOVER hue: the colour the pointer takes it to (and, for a button whose popup is up, the colour
// it wears while the popup is ours). A glyph that has an on/off state also has an ON hue, which it wears while the thing is on
// (Wi-Fi and Bluetooth, the speaker and the microphone, a loaded model, the player playing): off is the
// muted ink, in the SAME glyph shape. The hues are the theme's terminal colours, by meaning; pairs that belong together (the
// network pair, the audio pair) are neighbours on the hue circle. STATUS colours -- the update's levels, the bell's unread
// colours, warn and error -- are their own group and no hover lands on them; BarHues.js has the table and the rule that keeps
// a role off what it must be told from, which is also what finds a clash in a theme that duplicates a value.
//
//   onHues / hovers     readonly colours, one per role (`speakerOn`, `netHover`, ...)
//   tint(key)           a reel option's colour by its role ("power.sleep"), or a Theme token by its old reel name
//   choice              role -> the Theme token it landed on (a probe and the hue sheet read it)
//   hoverMs, hoverEasing  THE ONE HOVER CLOCK (GlyphHoverEase): every bar glyph's hover fade
//
// WHICH SLOT A ROLE TAKES IS DECIDED WHEN THE PALETTE IS SETTLED, not on every frame of a fade: the choice is held (read at
// creation and on `Theme.settled`, the GroupPalette rule) and the COLOUR of the chosen token follows the theme live. A switch
// through a crossfade host writes the tokens once behind the old picture and settles in the same turn, so a role that moves to
// another slot moves behind the picture; a switch with no host glides the chosen slots and re-decides when the glide lands.
// =============================================================================
QtObject {
    id: root

    // ---- the one hover clock -------------------------------------------------------------------------------------------------
    // 120 ms OutCubic read as instant: an OutCubic covers half its way in a fifth of its time. A sine in and out over 180 ms is a
    // short fade the eye sees, with no jump at either end.
    property int hoverMs: 180
    property int hoverEasing: Easing.InOutSine

    // ---- the held choice -----------------------------------------------------------------------------------------------------
    property var choice: ({})
    function resolve(): void {
        const names = Hues.tokens();
        const pal = {};
        for (let i = 0; i < names.length; i++) {
            const c = Theme[names[i]];
            if (c !== undefined)
                pal[names[i]] = [c.r, c.g, c.b];
        }
        root.choice = Hues.resolve(pal);
    }
    readonly property Connections _settled: Connections {
        target: Theme
        function onSettled() {
            root.resolve();
        }
    }
    Component.onCompleted: root.resolve()

    // A role's colour: its token, live. The token name is read first, so the binding follows the choice and the token both.
    function _c(role: string): color {
        const tok = root.choice[role];
        return tok ? Theme[tok] : Theme.accent;
    }

    // ---- the roles -----------------------------------------------------------------------------------------------------------
    readonly property color themeHover: root._c("theme.hover")
    readonly property color notesHover: root._c("notes.hover")
    readonly property color llmOn: root._c("llm.on")
    readonly property color llmHover: root._c("llm.hover")
    readonly property color weatherHover: root._c("weather.hover")
    readonly property color stocksHover: root._c("stocks.hover")
    readonly property color playerOn: root._c("player.on")
    readonly property color playerHover: root._c("player.hover")
    readonly property color speakerOn: root._c("speaker.on")
    readonly property color micOn: root._c("mic.on")
    readonly property color audioHover: root._c("audio.hover")
    readonly property color wifiOn: root._c("wifi.on")
    readonly property color btOn: root._c("bt.on")
    readonly property color netHover: root._c("net.hover")
    readonly property color bridgeHover: root._c("bridge.hover")
    readonly property color panoramaOn: root._c("panorama.on")
    readonly property color panoramaHover: root._c("panorama.hover")
    readonly property color updateHover: root._c("update.hover")
    readonly property color bellHover: root._c("bell.hover")
    // aerial's dome: one hue per Wi-Fi band (the dome's holograms and tags read these through the theme's own terminal colours)
    readonly property color aerialBand24: root._c("aerial.band24")
    readonly property color aerialBand5: root._c("aerial.band5")
    readonly property color aerialBand6: root._c("aerial.band6")

    // A reel option's colour. `key` is the role ReelItems.js names ("power.sleep"); a reel built before the table named Theme
    // tokens ("accent", "error", "warn", "ok", "cyan", "violet"), and those still answer as they did.
    function tint(key: string): color {
        if (root.choice[key])
            return Theme[root.choice[key]];
        switch (key) {
        case "error":
            return Theme.error;
        case "warn":
            return Theme.warn;
        case "ok":
            return Theme.ok;
        case "cyan":
            return Theme.catMultilib;
        case "violet":
            return Theme.catFlatpak;
        default:
            return Theme.accent;
        }
    }
}
