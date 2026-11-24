pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes

import "../common/theme"
import "../common/glyphs"
import "../common/components"
import "../common/components/Mix.js" as Mix
import "data/StocksFormat.js" as F
import "parts/StocksPose.js" as P

// =============================================================================
// StocksBarButton.qml -- the stocks module in the bar.
//
// While any held market is open: a 22 x 12 sparkline of today's portfolio
// value and the day's change in percent, both in the gain or loss colour. No
// money on the bar. When every held market is closed there
// is nothing moving to show, and the button wears the SKELETON of the live
// face -- the same line and the same percentage slot as quiet placeholders --
// in the closed colour (blue, the accent: not green, not red, nothing is
// going up or down). A chart glyph would be too different from the dynamic weekday icons;
// the skeleton placeholder still depicts what the weekday icons look like.
//
// THE WIDTH FOLLOWS THE FACE, NOT THE FIGURE. The live percentage sits in a slot as wide as the widest figure StocksFormat can write
// (its template, measured as the cells the figure is drawn in), right-aligned, so a digit ticking over moves nothing; a figure that
// changes ROLLS, as the clock's do (DigitCells, each figure in its own exact advance: it sets as the plain Text did). The closed face is the line and the dots AS ONE UNIT, the dots a `gap` from
// the line's end (dots right-aligned in that slot would read as two separate buttons and elongate the right side of the middle
// island, breaking its symmetry), so the
// button is as wide as the face it wears: a market opening or closing widens or narrows the island once, on the layout's own 180 ms
// clock (ShellFrame.lengths), and a digit ticking never does. The width follows the face's STATE (`live`), not its fade (`liveF`): a
// width that followed the fade would retarget the island's clock every frame.
//
// THE FLOURISH (the bar glyphs' one contract, GlyphFlourish; StocksPose.js has the motion): hovering plays a RIPPLE along the line (a
// lump up on a gain, down on a loss) and an ARROW thrown off the line's tip as the ripple reaches it; a closed face gets a neutral S that
// carries on through the three dots, each hopping as it passes. It is decorative (the OLED care plays it at random, group "stocks").
// NOTHING OF THE FACE'S SIZE MOVES: the ripple is the line's points displaced in pixels (Sparkline `warp`, bound only while it plays,
// so at rest the path is the plain one), the dots hop by a transform and the arrow is a Shape of its own in the gap beside the tip.
// The face's state (gain, loss, closed) is read when the play starts and held for it: a fetch that flips the sign mid-play does not
// flip the lump.
//
// A click toggles the popup. THE INK IS A GLYPH BUTTON'S (one style for every bar button, so no sunk square comes up behind the
// face on hover): no ground, ever. The pointer, and the popup being ours,
// take the ink to the stocks' hover hue (BarHues `stocksHover`: gold, which is neither the gain, the loss nor the closed blue)
// as ONE eased fraction on the bar's one hover clock, mixed into the themed colours (Mix.js; nothing animates a colour) --
// from the sign's green or red on the live face, from the closed blue on the closed one. Nothing is faint.
//
// ON A SIDE BAR the line and the figure run ALONG the bar, turned with it: a
// percentage is wider than a 40 px bar is thick, and stacked upright it would
// have to shrink to 7 px to fit. The skeleton is the same two pieces and turns
// with them. The bar's frame is already rotated, so the face is laid out the
// same way on every edge: x along the bar (the host needs to tell the button
// nothing about the edge).
// =============================================================================
Item {
    id: btn

    property var owner: null
    readonly property var service: btn.owner ? btn.owner.svc : null
    readonly property bool active: btn.owner ? btn.owner.popupMine : false

    property string fontFamily: "Inter"
    property int pixelSize: 11
    property real sparkWidth: 22
    property real sparkHeight: 12
    property real gap: 5
    // The closed face's percentage placeholder:
    //   "text"  an em dash in the live figure's own type, right-aligned in its slot: the figure the closed market has none of
    //   "thin"  a hairline bar (3 px) where the text would stand
    //   "bar"   the thick bar (6 px thick, 60 % of the slot)
    //   "dots"  three dots, an ellipsis
    //   "none"  nothing: the line alone, the slot kept empty so the width never changes
    //   "flat"  "text", over a FLAT line instead of the wave: nothing is moving either
    // LIVE: "dots" (judged best: it keeps the figure's mass without a block, reads as "no figure yet", and is full ink like the
    // line). One word to change.
    property string closedStyle: "dots"
    property real padAlong: 6
    property real padAcross: 4

    // ---- the facts ---------------------------------------------------------------
    readonly property var _p: btn.service ? btn.service.portfolio : null
    readonly property bool live: !!btn._p && !!btn._p.anyHeldOpen
    readonly property var _spark: btn.service ? btn.service.daySpark : null
    readonly property real dayPct: btn._p && isFinite(btn._p.dayPct) ? btn._p.dayPct : 0
    readonly property bool _loss: btn.dayPct < 0
    // The sign's colour is ONE eased fraction mixed between the two themed colours (Mix.js), never a colour animation: a fetch
    // that turns the day from a gain into a loss (or back) fades instead of snapping, and at rest the value IS a Theme token,
    // so a light/dark switch reaches it with no
    // clock of its own in between.
    property int signFadeMs: 500
    property real lossF: btn._loss ? 1 : 0
    Behavior on lossF {
        NumberAnimation {
            duration: btn.signFadeMs
            easing.type: Easing.InOutQuad
        }
    }
    readonly property color signColour: Mix.c(Theme.stockGain, Theme.stockLoss, btn.lossF)
    // The closed face's colour: the accent, a blue no gain or loss wears. A Theme token, so a light/dark
    // switch reaches it with no clock of its own.
    readonly property color closedColour: Theme.accent
    // The placeholder line: the chart skeleton's own wave (StockSeries.skeletonSpec's shape, 24 points).
    readonly property var _skeleton: {
        const out = [];
        for (let i = 0; i < 24; i++) {
            const u = i / 23;
            out.push(0.42 + 0.09 * Math.sin(u * 2 * Math.PI * 1.15 + 0.5) + 0.04 * Math.sin(u * 2 * Math.PI * 3.3) + 0.08 * u);
        }
        return out;
    }

    // The figure's roll: the clock's (ClockBarButton rollMs / rollStaggerMs).
    property int rollMs: 320
    property int rollStaggerMs: 50

    // ---- the flourish (every number is a tunable of the mockup's Flourish group) ---------------------------------------
    property bool flourishEnabled: true
    // "both" (the ripple and the arrow) | "ripple" | "arrow"
    property string flourishStyle: "both"
    // the life's scale: 900 is the bar's usual beat and the pose's own numbers
    property int flourishMs: 900
    property real flourishAmp: 2
    property real flourishHalf: 5
    property real flourishHop: 2
    property real arrowTravel: 5
    property real arrowSize: 4
    property real arrowAlpha: 0.6
    readonly property alias flourish: stkFlourish
    // the face the play began on, held for it
    property string _mode: "gain"
    property string _style: "both"
    readonly property var _look: {
        const sc = btn.flourishMs / 900;
        let dots = null;
        if (btn.closedStyle === "dots") {
            dots = [];
            for (let i = 0; i < 3; i++)
                dots.push(btn.sparkWidth + btn.gap + btn.dotSize / 2 + i * (btn.dotSize + btn.dotGap));
        }
        return {
            w: btn.sparkWidth,
            dotX: dots,
            travelMs: 560 * sc,
            arrowMs: 320 * sc,
            amp: btn.flourishAmp,
            half: btn.flourishHalf,
            hop: btn.flourishHop,
            arrowTravel: btn.arrowTravel,
            arrowSize: btn.arrowSize,
            arrowAlpha: btn.arrowAlpha
        };
    }
    function _warp(x, w, t) {
        return P.dy(x, w, t, btn._mode, btn._style, btn._look);
    }
    readonly property var _arrow: stkFlourish.playing ? P.arrow(stkFlourish.t, btn._mode, btn._style, btn._look) : null

    GlyphFlourish {
        id: stkFlourish
        group: "stocks"
        decorative: true
        overlap: "ignore"
        hoverArea: area
        armed: btn.flourishEnabled
        ms: Math.max(1, Math.round(P.life(btn._mode, btn._style, btn._look)))
        onPlayed: {
            btn._mode = btn.live ? (btn._loss ? "loss" : "gain") : "closed";
            btn._style = btn.flourishStyle;
        }
    }

    // ---- the face's size (screen frame) ------------------------------------------
    TextMetrics {
        id: slotMetrics
        font.family: btn.fontFamily
        font.pixelSize: btn.pixelSize
        font.bold: true
        text: F.pctTemplate(88.88)
    }
    // The widest figure as the cells it is drawn in (DigitCells' own measure: `cellWidth` reads its metrics' font inside).
    readonly property real slotW: {
        const t = slotMetrics.text;
        let w = 0;
        for (let i = 0; i < t.length; i++)
            w += pctText.cellWidth(t.charAt(i));
        return Math.ceil(w);
    }
    readonly property real slotH: Math.ceil(slotMetrics.height)

    // The closed face's figure: the dots' own width (3 dots, 3 gaps), the whole slot for a style that draws a figure's worth, none for "none".
    readonly property real dotSize: 3
    readonly property real dotGap: 3
    readonly property real dotsW: 3 * btn.dotSize + 2 * btn.dotGap
    readonly property real closedFigW: btn.closedStyle === "none" ? 0 : btn.closedStyle === "dots" ? btn.dotsW : btn.slotW
    readonly property real figW: btn.live ? btn.slotW : btn.closedFigW
    readonly property real faceW: btn.sparkWidth + (btn.figW > 0 ? btn.gap + btn.figW : 0) + 2 * btn.padAlong
    readonly property real faceH: Math.max(btn.sparkHeight, btn.slotH) + 2 * btn.padAcross

    // In the bar's frame x runs along the bar.
    implicitWidth: btn.faceW
    implicitHeight: btn.faceH

    property real hoverF: area.containsMouse ? 1 : 0
    Behavior on hoverF {
        GlyphHoverEase {}
    }
    // The popup is ours: the same ink as the pointer's, as its own eased fraction on the same clock.
    property real activeF: btn.active ? 1 : 0
    Behavior on activeF {
        GlyphHoverEase {}
    }
    readonly property real inkF: Math.max(btn.hoverF, btn.activeF)
    // Presence of the live face against the closed skeleton (160 ms, the shell's fade).
    property real liveF: btn.live ? 1 : 0
    Behavior on liveF {
        NumberAnimation {
            duration: 160
            easing.type: Easing.OutCubic
        }
    }

    Item {
        id: face
        width: btn.faceW
        height: btn.faceH
        x: (btn.width - width) / 2
        y: (btn.height - height) / 2

        Item {
            id: liveFace
            anchors.fill: parent
            opacity: btn.liveF
            visible: opacity > 0

            Sparkline {
                id: spark
                objectName: "stocksSpark"
                x: btn.padAlong
                y: Math.round((face.height - height) / 2)
                width: btn.sparkWidth
                height: btn.sparkHeight
                values: btn._spark && btn._spark.v ? btn._spark.v : []
                baselineValue: btn._spark && isFinite(btn._spark.base) ? btn._spark.base : NaN
                color: Mix.c(btn.signColour, BarHues.stocksHover, btn.inkF)
                baselineColor: Theme.textFaint
                warp: stkFlourish.playing && btn._mode !== "closed" ? btn._warp : null
                warpT: stkFlourish.t
            }
            // The figure, right-aligned in its slot, a cell per character (the clock's roll); its width glides with a roll, and
            // the right edge stays where it is.
            DigitCells {
                id: pctText
                objectName: "stocksPct"
                x: Math.round(spark.x + spark.width + btn.gap + btn.slotW - pctText.implicitWidth)
                y: Math.round((face.height - btn.slotH) / 2)
                text: F.pct(btn.dayPct)
                fontFamily: btn.fontFamily
                pixelSize: btn.pixelSize
                bold: true
                proportional: true
                exactAdvances: true
                glide: true
                rolling: true
                rollMs: btn.rollMs
                staggerMs: btn.rollStaggerMs
                color: Mix.c(btn.signColour, BarHues.stocksHover, btn.inkF)
            }
        }

        // The closed face: the live face's pieces as placeholders, in the closed colour (full ink: nothing here is faint). The
        // pointer and the popup being ours take it to the stocks' hover hue, the same fraction as the live face's.
        Item {
            id: closedFace
            objectName: "stocksClosedFace"
            anchors.fill: parent
            opacity: 1 - btn.liveF
            visible: opacity > 0
            readonly property color ink: Mix.c(btn.closedColour, BarHues.stocksHover, btn.inkF)
            readonly property bool flat: btn.closedStyle === "flat"
            readonly property bool hasFigure: btn.closedStyle !== "none"

            Sparkline {
                id: skelSpark
                objectName: "stocksSkelSpark"
                x: btn.padAlong
                y: Math.round((face.height - height) / 2)
                width: btn.sparkWidth
                height: btn.sparkHeight
                values: closedFace.flat ? [1, 1, 1] : btn._skeleton
                color: closedFace.ink
                warp: stkFlourish.playing && btn._mode === "closed" ? btn._warp : null
                warpT: stkFlourish.t
            }
            // The percentage's place, right-aligned in the slot the figure would have: ONE of the parts, by `closedStyle`.
            Item {
                id: skelPct
                objectName: "stocksSkelPct"
                visible: closedFace.hasFigure
                x: spark.x + spark.width + btn.gap
                y: Math.round((face.height - btn.slotH) / 2)
                width: btn.closedFigW
                height: btn.slotH

                Rectangle {
                    readonly property real thick: btn.closedStyle === "thin" ? 3 : Math.round(btn.pixelSize * 0.55)
                    visible: btn.closedStyle === "bar" || btn.closedStyle === "thin"
                    width: Math.round(btn.slotW * 0.6)
                    height: thick
                    radius: height / 2
                    x: skelPct.width - width
                    y: Math.round((skelPct.height - height) / 2)
                    color: Qt.alpha(closedFace.ink, 0.5)
                }
                Row {
                    visible: btn.closedStyle === "dots"
                    spacing: btn.dotGap
                    x: skelPct.width - width
                    y: Math.round((skelPct.height - height) / 2)
                    Repeater {
                        model: 3
                        Rectangle {
                            id: dot
                            required property int index
                            objectName: "stocksDot" + dot.index
                            // hops as the ripple passes it (a transform: the Row's layout never hears it)
                            readonly property real hop: stkFlourish.playing && btn._mode === "closed" && btn._look.dotX ? P.dotHop(btn._look.dotX[dot.index], btn.sparkWidth, stkFlourish.t, btn._mode, btn._style, btn._look) : 0
                            transform: Translate {
                                y: dot.hop
                            }
                            width: btn.dotSize
                            height: btn.dotSize
                            radius: btn.dotSize / 2
                            color: closedFace.ink
                        }
                    }
                }
                Text {
                    visible: btn.closedStyle === "text" || btn.closedStyle === "flat"
                    anchors.fill: parent
                    horizontalAlignment: Text.AlignRight
                    verticalAlignment: Text.AlignVCenter
                    text: F.pct(NaN)
                    color: closedFace.ink
                    font.family: btn.fontFamily
                    font.pixelSize: btn.pixelSize
                    font.bold: true
                }
            }
        }
    }

    // The arrow thrown off the tip: a small triangle in the line's colour at reduced alpha, in the gap beside the tip.
    Shape {
        id: arrowShape
        objectName: "stocksArrow"
        readonly property var a: btn._arrow
        readonly property real sz: btn.arrowSize
        readonly property real h: Math.round(arrowShape.sz * 0.9 * 10) / 10
        readonly property var tip: spark._last
        visible: arrowShape.a !== null && arrowShape.a.alpha > 0.002 && arrowShape.tip !== null
        width: arrowShape.sz
        height: arrowShape.h
        x: face.x + spark.x + (arrowShape.tip ? arrowShape.tip.x : 0) - arrowShape.sz / 2
        y: Math.max(0, Math.min(btn.height - arrowShape.h, face.y + spark.y + (arrowShape.tip ? arrowShape.tip.y : 0) + (arrowShape.a ? arrowShape.a.dy : 0) - arrowShape.h / 2))
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeColor: "transparent"
            fillColor: Qt.alpha(spark.color, arrowShape.a ? arrowShape.a.alpha : 0)
            startX: 0
            startY: arrowShape.a && !arrowShape.a.up ? 0 : arrowShape.h
            PathLine {
                x: arrowShape.sz
                y: arrowShape.a && !arrowShape.a.up ? 0 : arrowShape.h
            }
            PathLine {
                x: arrowShape.sz / 2
                y: arrowShape.a && !arrowShape.a.up ? arrowShape.h : 0
            }
        }
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            if (btn.owner)
                btn.owner.toggle();
        }
    }
}
