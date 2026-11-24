pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/components/Mix.js" as Mix

// =============================================================================
// OsdLockKeys.qml -- Caps Lock and Num Lock, drawn as the two KEYS they are
// (the actual keyboard key dimensions and general shape, shaded, not an on / off reading alone).
//
//   h     the two keys side by side        v   stacked, centred on the card's axis
//   pill  the same as h, on the capsule's own key size (`keyUPill`)
//
// THE KEYS. Caps Lock is 1.75 units wide and Num Lock 1, both one unit tall (a unit is
// `style.keyU`, 32 on the pill), with a chiclet's corner. A key stands proud of the card as
// every button of the shell does (ShadowBox raised: a drop shadow outside, a highlight inside)
// and its legend is the key's own word.
//
// WHICH KEYS: the style's `lockKeys` (osd.jsonc lockkeys.keys), in that order; a key not in it is not drawn and takes no room.
//
// THE STATE IS ON OR OFF, NOTHING ELSE. A key that is ON is lit and held down: its plate is the
// accent (RaisedButton's accent plateau, the accent's own highlight), its legend the on-accent
// colour, and it is PRESSED as RaisedButton's pressed is -- the relief sinks (`keyPress` of the
// way) and the legend drops a pixel. Which key the user just pressed is not in the picture: the
// card is the same for "caps went on while num was on" and "num came on while caps was on" (dimming
// the key that had not changed would make an ON key that had not changed read as OFF).
//
// The light is ONE fraction per key (0..1, `valueEaseMs`) mixed from Theme colours with Mix.js:
// no Behavior on a colour, so a theme switch cannot lag it. The sizes are the style's
// (`extentOf` computes this card's from the same numbers): nothing here is a second copy of them.
// =============================================================================
Item {
    id: root

    property string kind: "lockkeys"
    property string orientation: "h"
    property var payload: ({})
    property bool interactive: true
    property var style: null
    property real renderScale: 1

    signal userValue(real v)
    signal userToggleMute()
    signal userToggleBoost()
    signal touched()

    readonly property var p: root.payload ? root.payload : ({})
    readonly property bool vert: root.orientation === "v"
    readonly property bool isPill: root.orientation === "pill"
    readonly property var keys: root.p.keys ? root.p.keys : ({})

    readonly property real u: root.isPill ? root.style.keyUPill : root.style.keyU
    readonly property var shown: root.style.lockKeys && root.style.lockKeys.length > 0 ? root.style.lockKeys : ["caps", "num"]
    readonly property var widths: root.style.lockKeyWidths(root.u)
    readonly property real totalW: root.vert ? Math.max.apply(null, root.widths) : root.widths.reduce((a, b) => a + b, 0) + (root.widths.length - 1) * root.style.keyGap
    readonly property real totalH: root.vert ? root.widths.length * root.u + (root.widths.length - 1) * root.style.keyGap : root.u
    // A key's place in the row (or the stack), from the keys before it.
    function keyX(i: int): real {
        if (root.vert)
            return root.pairX + Math.round((root.totalW - root.widths[i]) / 2);
        let x = root.pairX;
        for (let j = 0; j < i; j++)
            x += root.widths[j] + root.style.keyGap;
        return x;
    }
    function keyY(i: int): real {
        return root.vert ? root.pairY + i * (root.u + root.style.keyGap) : root.pairY;
    }
    // The pair's corner, centred by hand (anchors.centerIn would round the offset).
    readonly property real pairX: Math.round((root.width - root.totalW) / 2)
    readonly property real pairY: Math.round((root.height - root.totalH) / 2)

    component Key: Item {
        id: key
        required property string legend
        required property bool on

        height: root.u

        // ON, eased: one fraction drives the plate, the highlight, the legend, the sink.
        property real lit: key.on ? 1 : 0
        Behavior on lit {
            NumberAnimation {
                duration: root.style.valueEaseMs
                easing.type: Easing.OutCubic
            }
        }
        // RaisedButton's pressed, as far as the style says.
        readonly property real press: key.lit * root.style.keyPress

        ShadowBox {
            anchors.fill: parent
            raised: true
            baseRadius: root.style.keyRadius
            surfaceColor: Theme.surface
            bevelColor: Mix.c(Theme.bevel, Theme.accentBevel, key.lit)
            shadowColor: Theme.shadowDeep
            backgroundColor: Mix.c(Theme.surface, Theme.accent, key.lit)
            bevelWidth: Math.max(0.5, 1.5 * (1 - key.press * 0.8))
            shadowWidth: Math.max(0.5, 5 * (1 - key.press * 0.85))
            shadowEdgeAlpha: 0.9 * (1 - key.press * 0.6)
        }
        Text {
            x: Math.round((key.width - width) / 2)
            y: Math.round((key.height - height) / 2) + Math.round(key.lit)
            text: key.legend
            color: Mix.c(Theme.textMuted, Theme.textOnAccent, key.lit)
            font.family: root.style.textFont
            // the legend scales with the key (the capsule's smaller keys print a smaller word)
            font.pixelSize: Math.round(root.style.keyPx * root.u / root.style.keyU)
            font.bold: true
        }
    }

    Key {
        id: caps
        readonly property int at: root.shown.indexOf("caps")
        objectName: "key-caps"
        legend: "Caps"
        on: root.keys.caps === true
        visible: caps.at >= 0
        width: caps.at >= 0 ? root.widths[caps.at] : 0
        x: caps.at >= 0 ? root.keyX(caps.at) : 0
        y: caps.at >= 0 ? root.keyY(caps.at) : 0
    }
    Key {
        id: num
        readonly property int at: root.shown.indexOf("num")
        objectName: "key-num"
        legend: "Num"
        on: root.keys.num === true
        visible: num.at >= 0
        width: num.at >= 0 ? root.widths[num.at] : 0
        x: num.at >= 0 ? root.keyX(num.at) : 0
        y: num.at >= 0 ? root.keyY(num.at) : 0
    }
}
