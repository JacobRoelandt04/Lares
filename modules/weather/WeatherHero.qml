pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/components/Mix.js" as Mix
import "data/WeatherModel.js" as WM
import "data/PlaceBlend.js" as PB
import "data/WeatherContext.js" as Ctx

// =============================================================================
// WeatherHero.qml -- the prevalent card: what the weather is NOW, and the one
// thing worth knowing next.
//
// Hosted by WeatherPopup, which hands it `popup` (the model, the formatter,
// the face, the padding, the radius, the carve, the glyph carve, the fade).
//
// THE CARD IS THREE LAYERS, so the backdrop reaches the card's true edge and
// the carve still draws over it:
//
//   ground    ShadowBox with no inset shadow: the bevel rim outside the edge
//             and the flat listBox fill inside
//   backdrop  WeatherBackdrop, grown `_bleed` px past the card's edge under
//             the bevel rim (which is opaque there), its corners rounded at
//             radius + bleed with an inward one-pixel feather -- so its ink is
//             full at the edge itself, not a few pixels short of it
//   card      the same ShadowBox again with a TRANSPARENT fill: bevel rim and
//             inset shadow only, painted over the backdrop; the content
//             lives inside it
//
// With the backdrop off the three composite to the plain carved box: the
// ground's rim is covered by the card's own, opaque, identical one, and inside
// the card's shadow over the ground's fill IS a carved box's arithmetic --
// mix(fill, shadow, s). Measured within 1 level of a plain ShadowBox (the
// 8-bit rounding of blending twice) over the card's edge band, at 1x and 4x
// in both themes; the card's rim MUST stay opaque, since a transparent one
// leaves the ground's rim showing through the corners' antialiased seam, 2-3
// levels dark. The carve's
// knobs are the popup's (cardBevelWidth, cardShadowWidth, cardShadowFalloff,
// cardBevelColor), read by the ground and the carve alike.
//
// ONE LAYOUT IN EVERY VIEW (the mini mode is the same height as the others, so
// that when transitioning the shader card is visually unchanged apart from
// the length). Three columns inside the padding:
//
//   [       ]  44 px temperature                        High         20°
//   [ glyph ]  16 bold condition
//   [       ]  12 faint KMI observation                 Low          16°
//   [       ]  12 context line: "Drizzle tomorrow…"  ▂▄▆  Feels like  17°
//
// The four lines on the left sit on a BASELINE GRID: every line's capitals
// start `lineGap` under the baseline above, so the gaps read even whatever the
// sizes (placed by its row's foot the context line would float 28 px under
// the observation against 18 between the others). The content runs
// from the temperature's digit tops, on the top padding line, to the context
// line's baseline, on the bottom one (descenders hang into the padding, as a
// line of text standing on a rule does). The glyph is square and exactly that
// tall. The three stats spread over the SAME height -- the first figure's top
// level with the temperature's, the last baseline on the context line's -- so
// the right column has no dead space under "Feels like".
// The nowcast bars stand on the context baseline at the text column's right
// end, no taller than the gap under the observation's descenders. Nothing
// depends on the view: the card's height is the fonts', and its width the
// popup's (mini's popup is the detailed view's left column plus its padding,
// so the hero is the same card in both).
//
// THE GROUND CAN BE THE BACKDROP'S. In light mode the backdrop may paint a
// ground of its own (light mode's sky tint);
// when it says the ground is dark (`darkGround`) every text, the glyph and the
// carve's inset take the OTHER half of the theme, and on a mid sky tint the
// inset is a fixed share of black, so the carve reads the same on any ground.
//
// Every card height follows from the fonts, never from the weather: a glyph's
// own margin differs by kind (0 px for a shower's sun, 13 for a cloudy night)
// and a card whose height moved with the condition would resize the popup when
// the hour turned; the observation line is reserved whether or not KMI has
// answered. The glyph is the link to the conditions detail for today at the
// current hour (`from: "hero"`). Figures sit in slots measured off the widest
// digit; the stats' figures are right-aligned in theirs so the labels never
// move when a figure gains a digit or a sign.
//
// With no model yet the same geometry is drawn as silhouettes (a disc where the
// glyph will be, bars where the figures will), so the real card resolves in
// place. Presence fades over `popup.fadeMs`; text swaps instantly.
// =============================================================================
Item {
    id: hero

    property var popup: null

    // ---- Knobs ---------------------------------------------------------------
    property int tempSize: 44
    property int conditionSize: 16
    property int bodySize: 12
    // High / low / feels-like: the figures' size and the gap between the
    // label column and the figures.
    property int statFigureSize: 16
    property real statLabelGap: 14
    // The baseline grid: from one line's baseline to the next line's
    // capitals.
    property real lineGap: 9
    property real textGap: 12
    property real statsGap: 14
    property real nowcastBarWidth: 5
    property real nowcastBarGap: 2
    // mm per 10 minutes at which a nowcast bar reaches its full height. The
    // bars follow the SQUARE ROOT of the amount: a linear bar draws the common
    // 0.1-0.7 mm as 1-6 px dashes, the same row as a dry step; on the root
    // 0.1 mm is a fifth of the bar, 0.5 mm half, 2 mm all of it.
    property real nowcastMaxMm: 2
    property real contextGap: 10
    // THE GLYPH UNDER THE POINTER FLOURISHES (the bar glyphs' rule, GlyphFlourish: once per entry, once the pointer moves); the
    // hand cursor and that motion are all that announce the link.

    readonly property alias glyphFlourish: heroFlourish

    // ---- What the popup hands in -----------------------------------------------
    readonly property var _model: hero.popup ? hero.popup.model : null
    readonly property bool _layered: hero.popup ? !!hero.popup._layered : false
    readonly property real _renderScale: hero.popup ? hero.popup.renderScale : 1
    readonly property var _F: hero.popup ? hero.popup.fmt : WM.format({})
    readonly property var _cur: hero._model && hero._model.current ? hero._model.current : null
    readonly property var _today: hero._model && hero._model.daily && hero._model.daily.length > 0 ? hero._model.daily[0] : null
    // The nowcast bars are the one figure of the hero that has a bar: on a change of place (WeatherPopup, THE PLACE MORPH) they
    // grow or shrink from the old place's amounts to the new one's on the popup's clock; the words around them swap at once.
    readonly property var _nowcastTo: hero._model && hero._model.nowcast ? hero._model.nowcast : []
    property var _nowcastFrom: null
    readonly property var _nowcast: hero.popup && hero.popup.placeMorphing && hero._nowcastFrom
        ? PB.facts(hero._nowcastFrom, hero._nowcastTo, hero.popup.placeE, { zero: { mm: true } }) : hero._nowcastTo
    // What the popup calls before it changes the model: the bars as they are drawn now.
    function placeBegin() {
        hero._nowcastFrom = hero._nowcast;
    }
    readonly property string _font: hero.popup ? hero.popup.fontFamily : "Inter"
    readonly property var _gs: hero.popup ? hero.popup.glyphStyle : ({})
    readonly property real _pad: hero.popup ? hero.popup.cardPadding : 12
    readonly property real _radius: hero.popup ? hero.popup.radius : 14
    readonly property real _cardBevel: hero.popup ? hero.popup.cardBevelWidth : 1
    readonly property real _cardShadow: hero.popup ? hero.popup.cardShadowWidth : 3
    readonly property real _cardFalloff: hero.popup ? hero.popup.cardShadowFalloff : 1
    readonly property color _cardBevelColor: hero.popup ? hero.popup.cardBevelColor : Theme.bevel
    // How far the backdrop reaches past the card's edge, under its bevel rim:
    // the rim is opaque from half a pixel inside its outer edge, so the
    // backdrop's own outer edge (and nothing past it) stays covered.
    readonly property real _bleed: Math.max(0, hero._cardBevel - 0.5)
    readonly property int _fadeMs: hero.popup ? hero.popup.fadeMs : 160
    readonly property bool _hasModel: hero._cur !== null
    readonly property real _innerW: hero.width - 2 * hero._pad

    // ---- The ground under the content ------------------------------------------
    // The backdrop's own ground when it paints one (light mode's sky / window
    // treatments); `_dark` puts every text, the glyph and the inset on the
    // other half of the theme.
    readonly property bool _ownGround: backdrop.visible && !Qt.colorEqual(backdrop.groundColor, Theme.listBox)
    readonly property bool _dark: backdrop.visible && backdrop.darkGround
    function _tone(c, token) {
        return hero._dark ? (hero._alt[token] || c) : c;
    }
    // THE OTHER HALF OF THE THEME, held (WeatherBackdrop._dark says why):
    // Theme.counterpart answers for the NEW mode between a switch's ask and
    // its commit while the tokens still hold the old, and that is the frame
    // the crossfade captures -- a bound counterpart would put the wrong text
    // on a dark window in it. Read at creation and on every `settled`.
    property var _alt: ({})
    function _altNow() {
        const out = {};
        for (const k of ["textPrimary", "textMuted", "textFaint", "border", "bevel", "headerBox", "panelSunk", "weatherRain"])
            out[k] = Qt.color(Theme.counterpart(Theme[k].toString(), k));
        return out;
    }
    Connections {
        target: Theme
        function onSettled() {
            hero._alt = hero._altNow();
        }
    }
    Component.onCompleted: hero._alt = hero._altNow()
    // The inset: the theme's border on its own ground; the dark half's on a
    // dark one; on a mid sky tint the share of black that takes listBox to
    // border, so the carve's depth reads the same on any ground.
    readonly property color _insetColor: {
        const b = Theme.border;
        if (!hero._ownGround)
            return b;
        if (hero._dark)
            return hero._alt.border || b;
        const k = 1 - Mix.lum(b) / Math.max(0.01, Mix.lum(Theme.listBox));
        return Qt.rgba(0, 0, 0, Math.max(0, Math.min(1, k)));
    }

    // The instant the model speaks for: the service's clock when it has one
    // (WeatherMock's scrubbed `nowMs`), else the moment the model was rebuilt
    // (WeatherService rebuilds every minute). Reading the model first makes
    // every rebuild re-evaluate this.
    readonly property real _nowMs: {
        const m = hero._model;
        const s = hero.popup ? hero.popup.service : null;
        if (s && typeof s.nowMs === "number" && s.nowMs > 0)
            return s.nowMs;
        return m ? Date.now() : 0;
    }

    // ---- The context line ----------------------------------------------------------
    // { id, text, bars }: WeatherContext.js has the rules and their order.
    readonly property var contextLine: Ctx.line(hero._model, hero._F, hero._nowMs)
    readonly property bool _bars: hero.contextLine.bars && hero._nowcast.length > 0

    // ---- Metrics ----------------------------------------------------------------
    FontMetrics {
        id: fmTemp
        font.family: hero._font
        font.pixelSize: hero.tempSize
        font.bold: true
    }
    FontMetrics {
        id: fmCond
        font.family: hero._font
        font.pixelSize: hero.conditionSize
        font.bold: true
    }
    FontMetrics {
        id: fmBody
        font.family: hero._font
        font.pixelSize: hero.bodySize
    }
    FontMetrics {
        id: fmStat
        font.family: hero._font
        font.pixelSize: hero.statFigureSize
        font.bold: true
    }
    function _w(fm, t) {
        const f = fm.font;
        return t.length > 0 ? Math.ceil(fm.advanceWidth(t)) : 0;
    }
    // The height of a font's digits (or capitals) above its baseline. A method
    // call captures nothing, so the font is read first: that read is the
    // dependency.
    function _ink(fm, specimen) {
        const f = fm.font;
        return -fm.tightBoundingRect(specimen).y;
    }
    readonly property string _wide: {
        const f = fmStat.font;
        let best = "0", bw = 0;
        for (const d of "0123456789") {
            const w = fmStat.advanceWidth(d);
            if (w > bw) { bw = w; best = d; }
        }
        return best;
    }
    // "-00°": a figure with a sign and two digits.
    readonly property real _statSlot: hero._w(fmStat, "-" + hero._wide + hero._wide + "°")
    readonly property real _capTemp: hero._ink(fmTemp, "0123456789")
    readonly property real _capCond: hero._ink(fmCond, "HAMERT")
    readonly property real _capBody: hero._ink(fmBody, "HAMERT")
    readonly property real _capStat: hero._ink(fmStat, "0123456789")

    // THE BASELINE GRID, in the content's frame: 0 is the temperature's digit
    // top (on the top padding line), `_mainH` the context line's baseline (on
    // the bottom one).
    readonly property real _bTemp: Math.round(hero._capTemp)
    readonly property real _bCond: hero._bTemp + Math.round(hero.lineGap + hero._capCond)
    readonly property real _bObs: hero._bCond + Math.round(hero.lineGap + hero._capBody)
    readonly property real _bCtx: hero._bObs + Math.round(hero.lineGap + hero._capBody)
    readonly property real _mainH: hero._bCtx
    // The glyph: square, the content's height.
    readonly property real _g: hero._mainH
    readonly property real _textX: hero._g + hero.textGap
    // The stats: three baselines spread over the same height, the first
    // figure's top at 0, the last on the context baseline.
    readonly property real _statTop: Math.round(hero._capStat)
    readonly property var _statBase: [hero._statTop, Math.round((hero._statTop + hero._mainH) / 2), hero._mainH]
    readonly property real _labelW: Math.max(hero._w(fmBody, "High"), hero._w(fmBody, "Low"), hero._w(fmBody, "Feels like"))
    readonly property real _statsW: hero._labelW + hero.statLabelGap + hero._statSlot
    readonly property real _textW: Math.max(0, hero._innerW - hero._textX - hero.statsGap - hero._statsW)
    // The nowcast bars stand on the context baseline and stop short of the
    // observation line's descenders.
    readonly property real _barsH: Math.max(4, Math.floor(hero.lineGap + hero._capBody - fmBody.descent))
    readonly property real _barsW: hero._nowcast.length > 0
        ? hero._nowcast.length * (hero.nowcastBarWidth + hero.nowcastBarGap) - hero.nowcastBarGap : 0
    // Room around the content's rect for what draws past it -- the glyph's
    // rim, a hail pellet's foot, the context line's descenders: the content is a layer while the
    // backdrop ticks, and a layer is cut on its item's rect (a layered "Dry
    // until Monday" would read "Dru until Mondau" without it).
    readonly property real _layerSlack: 6

    implicitWidth: 480
    implicitHeight: hero._pad + hero._mainH + hero._pad

    // ---- Texts -------------------------------------------------------------------
    readonly property string _tempText: hero._F.temp(hero._cur ? hero._cur.temp : null)
    readonly property string _condText: hero._cur
        ? WM.conditionText(hero._cur.kind, hero._cur.intensity, hero._cur.night, hero._cur.shower, hero._cur.code) : "–"
    readonly property string _obsText: {
        // The formatter first, then the model (WeatherTiles says why).
        const F = hero._F;
        const o = hero._cur ? hero._cur.obs : null;
        if (!o)
            return "";
        const c = WM.conditionText(o.kind, o.intensity, o.night);
        return "KMI: " + F.temp(o.temp) + " " + (c === "–" ? "" : c.toLowerCase() + " ") + "at " + F.time(o.timeMs);
    }
    readonly property string _hiText: hero._F.temp(hero._today ? hero._today.temp.max : null)
    readonly property string _loText: hero._F.temp(hero._today ? hero._today.temp.min : null)
    readonly property string _feelsText: hero._F.temp(hero._cur ? hero._cur.feelsLike : null)

    readonly property alias glyphItem: glyph
    // The backdrop, for a harness's readout (ticking, tickCount).
    readonly property alias backdrop: backdrop

    // ---- 1. The ground: rim and fill, no inset shadow ------------------------------
    ShadowBox {
        id: ground
        anchors.fill: parent
        baseRadius: hero._radius
        surfaceColor: Theme.surface
        bevelColor: hero._cardBevelColor
        shadowColor: Theme.listBox
        backgroundColor: Theme.listBox
        bevelWidth: hero._cardBevel
        shadowWidth: 0
    }

    // ---- 2. The backdrop, to the card's true edge -----------------------------------
    WeatherBackdrop {
        id: backdrop
        x: -hero._bleed
        y: -hero._bleed
        width: hero.width + 2 * hero._bleed
        height: hero.height + 2 * hero._bleed
        cornerRadius: hero._radius + hero._bleed
        visible: hero._hasModel && hero.popup && hero.popup.backdropEnabled
        kind: hero._cur && hero._cur.kind ? hero._cur.kind : "clear"
        intensity: hero._cur && hero._cur.intensity !== null ? hero._cur.intensity : 1
        night: hero._cur ? !!hero._cur.night : false
        windKmh: hero._cur && hero._cur.wind && hero._cur.wind.speed !== null ? hero._cur.wind.speed : 0
        windDir: hero._cur && hero._cur.wind && hero._cur.wind.dir !== null ? hero._cur.wind.dir : 0
        running: backdrop.visible && hero.visible && (!hero.popup || hero.popup.backdropRunning)
        ambientHz: hero.popup ? hero.popup.ambientHz : 30
        strength: hero.popup ? hero.popup.backdropStrength : 1
        precipRenderer: hero.popup ? hero.popup.backdropRenderer : "shader"
        style: hero.popup ? hero.popup.backdropStyle : "v2"
        toneKnee: hero.popup ? hero.popup.backdropToneKnee : 0.07
        toneCap: hero.popup ? hero.popup.backdropToneCap : 0.11
        sparkCap: hero.popup ? hero.popup.backdropSparkCap : 0.24
    }

    // ---- 3. The carve over it, and the content ---------------------------------------
    ShadowBox {
        id: card
        anchors.fill: parent
        baseRadius: hero._radius
        surfaceColor: Theme.surface
        bevelColor: hero._cardBevelColor
        shadowColor: hero._insetColor
        backgroundColor: "transparent"
        bevelWidth: hero._cardBevel
        shadowWidth: hero._cardShadow
        shadowFalloff: hero._cardFalloff

        Item {
            id: content
            x: hero._pad - hero._layerSlack
            y: hero._pad - hero._layerSlack
            width: hero._innerW + 2 * hero._layerSlack
            height: hero._mainH + 2 * hero._layerSlack
            opacity: hero._hasModel ? 1 : 0
            visible: opacity > 0
            // Held as a texture while the backdrop ticks (WeatherPopup's
            // static layers): the glyph shader and the figures are redrawn
            // only when they change, not thirty times a second.
            layer.enabled: hero._layered
            layer.textureSize: Qt.size(Math.round(width * hero._renderScale), Math.round(height * hero._renderScale))
            layer.smooth: true
            Behavior on opacity {
                NumberAnimation { duration: hero._fadeMs; easing.type: Easing.OutCubic }
            }

            // ---- The glyph: the link ---------------------------------------------
            // The pointer becomes a hand and the glyph flourishes; nothing else announces it.
            Item {
                id: glyph
                x: hero._layerSlack
                y: hero._layerSlack
                width: hero._g
                height: hero._g
                readonly property var key: ({
                    metric: "conditions", dayIndex: 0,
                    hourIndex: hero._cur && hero._cur.timeMs !== null ? WM.localParts(hero._cur.timeMs).hour : 0,
                    from: "hero"
                })
                GlyphFlourish {
                    id: heroFlourish
                    armed: heroGlyph.flourishBeats > 0
                    ms: Math.max(1, Math.round((hero.popup ? hero.popup.glyphFlourishMs : 900) * heroGlyph.flourishBeats))
                    overlap: "ignore"
                    hoverArea: glyphArea
                }
                WeatherGlyph {
                    id: heroGlyph
                    posing: heroFlourish.playing
                    poseBeat: heroFlourish.t / Math.max(1, hero.popup ? hero.popup.glyphFlourishMs : 900)
                    anchors.fill: parent
                    size: hero._g
                    kind: hero._cur && hero._cur.kind ? hero._cur.kind : "clear"
                    intensity: hero._cur && hero._cur.intensity !== null ? hero._cur.intensity : 1
                    night: hero._cur ? !!hero._cur.night : false
                    shower: hero._cur ? !!hero._cur.shower : false
                    moonPhase: hero._today && hero._today.moonPhase !== null ? hero._today.moonPhase : 0.5
                    style: hero._gs
                    otherMode: hero._dark
                }
                MouseArea {
                    id: glyphArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (hero.popup) hero.popup.openDetail(glyph.key, glyph.mapToItem(hero.popup, glyph.width / 2, glyph.height / 2))
                }
            }

            // ---- The four lines, on the baseline grid ----------------------------
            Item {
                id: textCol
                x: hero._layerSlack + hero._textX
                y: hero._layerSlack
                width: hero._textW
                height: hero._mainH
                Text {
                    id: tempText
                    y: Math.round(hero._bTemp - fmTemp.ascent)
                    text: hero._tempText
                    color: hero._tone(Theme.textPrimary, "textPrimary")
                    font.family: hero._font
                    font.pixelSize: hero.tempSize
                    font.bold: true
                }
                Text {
                    y: Math.round(hero._bCond - fmCond.ascent)
                    width: textCol.width
                    text: hero._condText
                    elide: Text.ElideRight
                    color: hero._tone(Theme.textPrimary, "textPrimary")
                    font.family: hero._font
                    font.pixelSize: hero.conditionSize
                    font.bold: true
                }
                // Reserved whether or not KMI has answered: the card never
                // resizes on data.
                Text {
                    y: Math.round(hero._bObs - fmBody.ascent)
                    width: textCol.width
                    visible: text.length > 0
                    text: hero._obsText
                    elide: Text.ElideRight
                    color: hero._tone(Theme.textFaint, "textFaint")
                    font.family: hero._font
                    font.pixelSize: hero.bodySize
                }
                // The context line takes the column, less the bars' slot while
                // they show; the bars stand on its baseline at the column's end
                // and fade in and out as the rule's `bars` says.
                Text {
                    id: contextText
                    y: Math.round(hero._bCtx - fmBody.ascent)
                    width: Math.max(0, textCol.width - (hero._bars ? hero._barsW + hero.contextGap : 0))
                    text: hero.contextLine.text
                    elide: Text.ElideRight
                    color: hero._tone(Theme.textMuted, "textMuted")
                    font.family: hero._font
                    font.pixelSize: hero.bodySize
                }
                Item {
                    id: bars
                    x: textCol.width - width
                    y: hero._bCtx - height
                    width: hero._barsW
                    height: hero._barsH
                    opacity: hero._bars ? 1 : 0
                    visible: opacity > 0
                    Behavior on opacity {
                        NumberAnimation { duration: hero._fadeMs; easing.type: Easing.OutCubic }
                    }
                    Repeater {
                        model: hero._nowcast.length
                        Item {
                            id: barSlot
                            required property int index
                            readonly property real mm: hero._nowcast[barSlot.index] ? hero._nowcast[barSlot.index].mm : 0
                            x: barSlot.index * (hero.nowcastBarWidth + hero.nowcastBarGap)
                            width: hero.nowcastBarWidth
                            height: bars.height
                            Rectangle {
                                x: 0
                                width: parent.width
                                height: Math.max(1.5, Math.sqrt(Math.min(1, Math.max(0, barSlot.mm) / hero.nowcastMaxMm)) * parent.height)
                                y: parent.height - height
                                radius: Math.min(1.5, parent.width / 2)
                                color: barSlot.mm > 0 ? hero._tone(Theme.weatherRain, "weatherRain") : hero._tone(Theme.border, "border")
                                opacity: barSlot.mm > 0 ? 1 : 0.6
                            }
                        }
                    }
                }
            }

            // ---- High / low / feels-like ------------------------------------------
            // Labels left in one column, figures right-aligned in one slot
            // each, the block pinned to the card's right edge -- a wider face
            // moves the whole block, never a figure against its label. The
            // three baselines spread over the content's height (`_statBase`).
            Item {
                id: rightCol
                readonly property var labels: ["High", "Low", "Feels like"]
                readonly property var figures: [hero._hiText, hero._loText, hero._feelsText]
                x: content.width - hero._layerSlack - width
                y: hero._layerSlack
                width: hero._statsW
                height: hero._mainH
                Repeater {
                    model: 3
                    Item {
                        id: statRow
                        required property int index
                        readonly property real base: hero._statBase[statRow.index]
                        width: rightCol.width
                        Text {
                            y: Math.round(statRow.base - fmBody.ascent)
                            text: rightCol.labels[statRow.index]
                            color: hero._tone(Theme.textMuted, "textMuted")
                            font.family: hero._font
                            font.pixelSize: hero.bodySize
                        }
                        Text {
                            x: rightCol.width - hero._statSlot
                            y: Math.round(statRow.base - fmStat.ascent)
                            width: hero._statSlot
                            text: rightCol.figures[statRow.index]
                            color: hero._tone(Theme.textPrimary, "textPrimary")
                            font.family: hero._font
                            font.pixelSize: hero.statFigureSize
                            font.bold: true
                            horizontalAlignment: Text.AlignRight
                        }
                    }
                }
            }
        }

        // ---- The silhouette -----------------------------------------------------
        // The same grid: a disc for the glyph, a bar per line where its ink
        // will be, a bar per stat on its baseline.
        Item {
            id: skeleton
            x: hero._pad
            y: hero._pad
            width: hero._innerW
            height: hero._mainH
            opacity: hero._hasModel ? 0 : 1
            visible: opacity > 0
            Behavior on opacity {
                NumberAnimation { duration: hero._fadeMs; easing.type: Easing.OutCubic }
            }
            readonly property bool pulse: hero.popup ? hero.popup.skeletonPulse : true
            SkeletonBar {
                x: 0
                y: 0
                width: hero._g
                height: hero._g
                radius: hero._g / 2
                pulse: skeleton.pulse
                pulseTravel: 3
                barColor: Theme.headerBox
                groundColor: Theme.listBox
            }
            Repeater {
                // [baseline, ink height, width, phase]
                model: [[hero._bTemp, Math.round(hero._capTemp), Math.round(hero._capTemp * 2.2), 120],
                        [hero._bCond, Math.round(hero._capCond), 110, 240],
                        [hero._bObs, Math.round(hero._capBody), 150, 360],
                        [hero._bCtx, Math.round(hero._capBody), 170, 480]]
                SkeletonBar {
                    required property var modelData
                    x: hero._textX
                    y: modelData[0] - modelData[1]
                    width: Math.min(modelData[2], hero._textW)
                    height: modelData[1]
                    pulse: skeleton.pulse
                    pulseTravel: 3
                    pulsePhaseMs: modelData[3]
                    barColor: Theme.headerBox
                    groundColor: Theme.listBox
                }
            }
            Repeater {
                model: 3
                SkeletonBar {
                    required property int index
                    x: skeleton.width - width
                    y: hero._statBase[index] - height
                    width: hero._statsW
                    height: Math.round(hero._capStat)
                    pulse: skeleton.pulse
                    pulseTravel: 3
                    pulsePhaseMs: 360 + 120 * index
                    barColor: Theme.headerBox
                    groundColor: Theme.listBox
                }
            }
        }
    }
}
