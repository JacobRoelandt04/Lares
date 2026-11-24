pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/glyphs"
import "../common/components"
import "../common/components/Mix.js" as Mix
import "data/WeatherModel.js" as WM

// =============================================================================
// WeatherBarButton.qml -- the weather in the bar: the popup's OWN drawn glyph, live, and the
// temperature beside it ("12°").
//
//   [ glyph ]  12°
//
// The glyph is WeatherGlyph with the service's `model.current` (kind, intensity, night, shower): the same carved picture the
// popup's hero draws, at the bar's icon size. The temperature is the popup's own formatter (`WM.format(units).temp`: the
// units are the config's, "12°" in Celsius, "54°" in Fahrenheit), in the bar's font and its weight (bold, as the clock's
// figures and the stocks' and the battery's), and it ROLLS when it changes, as the clock's figures do (DigitCells, each figure
// in its own exact advance -- `proportional`, `exactAdvances` -- so it sets as a plain Text of the same string would). A change
// of length ("9°" -> "10°") swaps at once (DigitCells' rule).
//
// THE WIDTH NEVER MOVES. Audiowide has no tabular figures, so the figure stands in a slot measured for the widest it can
// be -- a sign, two of the widest digits and the degree sign ("-00°"), measured as the cells the figure is drawn in -- and is
// left-aligned against the glyph; a temperature
// that changes, or crosses zero, changes no pixel of the layout (CLAUDE.md, Figures never jitter). The figure's digits are
// centred on the glyph by their INK (a Text's line box is not its ink), rounded once.
//
// STATES. Loading, offline with nothing cached, or no `current`: the glyph (a plain cloud) and "--°" at 45 % -- the fraction
// is eased, never a colour animated. A KMI warning (`model.warnings`) tints the temperature: the warn colour, the error
// colour from level 3. One mark for one fact: nothing else changes. The pointer takes the figure to the weather's hover hue
// (BarHues `weatherHover`), on the bar's one hover clock.
//
// THE TWO SETS (WeatherGlyphSet, temporary). The ink set is a bar glyph like its neighbours: 18 px (`inkGlyphSize`, the bar's
// glyph size), resting in the bar's ink and going to the weather's hover hue WITH the figure, its one accent part keeping
// its colour. The carved set keeps its 20 px and its own colours and does not answer the pointer.
//
// THE FLOURISH (the ink set's; feedback/weather.md "Flourish"): the icon moves as what it shows -- the sun turns, drops let
// go, the bolt strikes, fog slides (WeatherInkPose.js) -- on the bar glyphs' one contract (GlyphFlourish): once per pointer
// entry, never restarted mid-play, nothing running at rest. It means nothing, so the OLED care's random flourishes play it
// (group "weather"). Each icon runs its own length, `flourishMs` times the icon's beats.
//
// Click and the popup are the host's (WeatherBarOwner); `clicked(button)` is all this says. `service` is WeatherService |
// WeatherMock (null = a faint "--°").
// =============================================================================
Item {
    id: btn

    property var service: null
    property string fontFamily: "Audiowide"
    property real glyphSize: WeatherGlyphSet.carved ? 20 : btn.inkGlyphSize
    property real inkGlyphSize: 18
    property int tempPixelSize: 13
    property real padX: 6
    property real padY: 5
    property real gap: 4
    // The figure's roll: the clock's (ClockBarButton rollMs / rollStaggerMs).
    property int rollMs: 320
    property int rollStaggerMs: 50

    property bool flourishEnabled: true
    // one BEAT of the flourish: the bar's usual 900 ms. An icon runs 0.9 (rain) to 2 beats (fog).
    property int flourishMs: 900
    readonly property alias flourish: wxFlourish

    signal clicked(int button)

    // ---- what the service says ---------------------------------------------------------------------------------
    readonly property var _model: btn.service ? btn.service.model : null
    readonly property var _cur: btn._model && btn._model.current ? btn._model.current : null
    readonly property bool hasData: btn._cur !== null
    readonly property var _fmt: WM.format(btn.service && btn.service.config ? btn.service.config.units : ({}))
    readonly property bool _hasTemp: btn._cur !== null && typeof btn._cur.temp === "number" && isFinite(btn._cur.temp)
    readonly property string tempText: btn._hasTemp ? btn._fmt.temp(btn._cur.temp) : "--°"
    readonly property int warnLevel: {
        const ws = btn._model && btn._model.warnings ? btn._model.warnings : [];
        let lvl = 0;
        for (let i = 0; i < ws.length; i++)
            lvl = Math.max(lvl, ws[i].level || 1);
        return lvl;
    }

    // ---- geometry (whole pixels) ----------------------------------------------------------------------------------
    FontMetrics {
        id: fm
        font.family: btn.fontFamily
        font.pixelSize: btn.tempPixelSize
        font.bold: true
    }
    readonly property string _wide: {
        const f = fm.font;
        let best = "0", bw = 0;
        for (const d of "0123456789") {
            const w = fm.advanceWidth(d);
            if (w > bw) {
                bw = w;
                best = d;
            }
        }
        return best;
    }
    // The widest figure as the cells it is drawn in (DigitCells' own measure: `cellWidth` reads its metrics' font inside).
    readonly property real slotWidth: temp.cellWidth("-") + 2 * temp.cellWidth(btn._wide) + temp.cellWidth("°")
    // The height of the digits above their baseline.
    readonly property real _digitInk: {
        const f = fm.font;
        return -fm.tightBoundingRect("0123456789").y;
    }

    implicitWidth: Math.ceil(btn.padX + btn.glyphSize + btn.gap + btn.slotWidth + btn.padX)
    implicitHeight: Math.ceil(btn.glyphSize + 2 * btn.padY)

    // ---- the eased fractions -------------------------------------------------------------------------------------
    property real _warnF: btn.warnLevel > 0 && btn.hasData ? 1 : 0
    Behavior on _warnF {
        NumberAnimation {
            duration: 160
            easing.type: Easing.OutCubic
        }
    }
    property real _hoverF: hit.containsMouse ? 1 : 0
    Behavior on _hoverF {
        GlyphHoverEase {}
    }

    DeviceScale {
        id: dev
    }

    GlyphFlourish {
        id: wxFlourish
        group: "weather"
        decorative: true
        shown: wxGlyph.flourishBeats > 0
        armed: btn.flourishEnabled && wxGlyph.flourishBeats > 0
        ms: Math.max(1, Math.round(btn.flourishMs * wxGlyph.flourishBeats))
        overlap: "ignore"
        hoverArea: hit
    }

    WeatherGlyph {
        id: wxGlyph
        x: btn.padX
        y: Math.round((btn.height - btn.glyphSize) / 2)
        size: btn.glyphSize
        renderScale: dev.value
        ink: Mix.c(BarText.ink, BarHues.weatherHover, btn._hoverF)
        posing: wxFlourish.playing
        poseBeat: wxFlourish.t / Math.max(1, btn.flourishMs)
        kind: btn.hasData && btn._cur.kind ? btn._cur.kind : "cloudy"
        intensity: btn.hasData && btn._cur.intensity !== null && btn._cur.intensity !== undefined ? btn._cur.intensity : 1
        night: btn.hasData ? !!btn._cur.night : false
        shower: btn.hasData ? !!btn._cur.shower : false
    }

    // The figure, a cell per character (the clock's roll). Its cells' baseline is the font's ascent below the item's top.
    DigitCells {
        id: temp
        objectName: "weatherTemp"
        x: btn.padX + btn.glyphSize + btn.gap
        // the digits' ink centred on the glyph's centre: the baseline, rounded once
        y: Math.round(btn.height / 2 + btn._digitInk / 2) - Math.round(fm.ascent)
        text: btn.tempText
        fontFamily: btn.fontFamily
        pixelSize: btn.tempPixelSize
        bold: true
        proportional: true
        exactAdvances: true
        glide: true
        rolling: true
        rollMs: btn.rollMs
        staggerMs: btn.rollStaggerMs
        color: Mix.c(Mix.c(BarText.ink, btn.warnLevel >= 3 ? Theme.error : Theme.warn, btn._warnF), BarHues.weatherHover, btn._hoverF)
    }

    MouseArea {
        id: hit
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: mouse => btn.clicked(mouse.button)
    }
}
