pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes

import "../common/theme"
import "../common/components"
import "../common/components/Mix.js" as Mix
import "data/WeatherModel.js" as WM
import "data/PlaceBlend.js" as PB
import "data/WeatherScales.js" as Scales

// =============================================================================
// WeatherTiles.qml -- the ten niche metrics, as a grid of carved tiles.
//
// Hosted by WeatherPopup, which hands it `popup` (the model, the formatter,
// the face, the glyph carve, the skeleton pulse, the fade) and `columns`.
//
//   precipitation   today's total, the next wet hour, 12 bars of the next 12 h
//   wind            Beaufort + arrow, the gusts, a compass rose with the
//                   direction the wind comes from
//   air quality     the index, its band name, a six-dot band row with the
//                   current band raised
//   pollen          the primary species and its level with a band dot; "none"
//                   with nothing active, "no data" with no air-quality data
//   humidity        the percentage, the dew point, the comfort band
//   uv              the index, its band, a groove 0..11 with a mark
//   visibility      the distance and its band
//   pressure        the value, a trend arrow, its band
//   sun             rise -> set, the day's length, a day arc with the sun on it
//   moon            the moon glyph at its phase, the phase name, illumination
//
// Every tile is the link to its metric's detail for today (sun and moon to
// "sunMoon"). The facts are one object built per model -- strings, numbers
// and band INDICES, never colours; a tile resolves `Theme.bands[i]` itself.
// `columns` is the host's (3: only the detailed view shows the grid);
// `heightFor()` answers the grid's height for any column count, so the popup
// can size a view it is not showing. Given more height than it asks for, the
// rows stretch to fill it. Every tile edge lands on a whole pixel and every
// gap is exactly `gap`: the share of a width that does not divide evenly goes
// to the tiles a pixel at a time, never to a fractional x.
// =============================================================================
Item {
    id: tiles

    property var popup: null
    property int columns: 3

    // ---- Knobs ---------------------------------------------------------------
    property real gap: 12
    property real tileHeight: 100
    property real tileRadius: 10
    property real tilePadding: 12
    property int titleSize: 11
    property int figureSize: 16
    property int bodySize: 11
    property real markHeight: 14
    property real barWidth: 4
    property real barGap: 2
    property real dotSize: 8
    property real dotGap: 4
    property real roseSize: 26
    property real arcWidth: 44
    property real moonSize: 32
    property real hoverGroundAlpha: 0.6
    property int hoverMs: 120

    readonly property int count: 10
    function heightFor(cols) {
        const rows = Math.ceil(tiles.count / Math.max(1, cols));
        return rows * tiles.tileHeight + (rows - 1) * tiles.gap;
    }
    implicitWidth: 480
    implicitHeight: tiles.heightFor(tiles.columns)

    readonly property int _rows: Math.ceil(tiles.count / Math.max(1, tiles.columns))
    readonly property real _gridH: Math.max(tiles.height, tiles.heightFor(tiles.columns))
    // A row that the count does not fill (the moon alone in a fourth row of
    // three) is shared by the tiles in it, so the grid ends flush instead of
    // with holes; every other row is `columns` wide.
    function _colsIn(i) {
        const rest = tiles.count % Math.max(1, tiles.columns);
        return (rest > 0 && Math.floor(i / tiles.columns) === tiles._rows - 1) ? rest : tiles.columns;
    }
    // The k-th of n cells along `total` px, `gap` apart: its whole-pixel start
    // and end. Edges are rounded, not sizes, so the last cell ends on `total`.
    function _cellStart(k, n, total) {
        return Math.round(k * (total + tiles.gap) / n);
    }
    function _cellEnd(k, n, total) {
        return Math.round((k + 1) * (total + tiles.gap) / n) - tiles.gap;
    }
    function _x(i) {
        return tiles._cellStart(i % tiles.columns, tiles._colsIn(i), Math.round(tiles.width));
    }
    function _w(i) {
        const k = i % tiles.columns, n = tiles._colsIn(i), W = Math.round(tiles.width);
        return tiles._cellEnd(k, n, W) - tiles._cellStart(k, n, W);
    }
    function _y(i) {
        return tiles._cellStart(Math.floor(i / tiles.columns), tiles._rows, Math.round(tiles._gridH));
    }
    function _h(i) {
        const r = Math.floor(i / tiles.columns), H = Math.round(tiles._gridH);
        return tiles._cellEnd(r, tiles._rows, H) - tiles._cellStart(r, tiles._rows, H);
    }

    // ---- What it reads ---------------------------------------------------------
    readonly property var _model: tiles.popup ? tiles.popup.model : null
    readonly property var _F: tiles.popup ? tiles.popup.fmt : WM.format({})
    readonly property string _font: tiles.popup ? tiles.popup.fontFamily : "Inter"
    readonly property var _gs: tiles.popup ? tiles.popup.glyphStyle : ({})
    // A tile's glyph flourishes when the pointer comes onto the tile or clicks it (the wind's arrow, the pressure's trend, the
    // moon), each to its end: one clock for the grid, a run per tile.
    readonly property WeatherGlyphFlourish glyphFlourish: WeatherGlyphFlourish {
        host: tiles
        beatMs: tiles.popup ? tiles.popup.glyphFlourishMs : 900
    }
    readonly property bool _skeleton: !tiles._model
    readonly property bool _pulse: tiles.popup ? tiles.popup.skeletonPulse : true
    readonly property int _fadeMs: tiles.popup ? tiles.popup.fadeMs : 160

    FontMetrics {
        id: fmFig
        font.family: tiles._font
        font.pixelSize: tiles.figureSize
        font.bold: true
    }
    FontMetrics {
        id: fmBody
        font.family: tiles._font
        font.pixelSize: tiles.bodySize
    }
    readonly property real _lineFig: Math.ceil(fmFig.height)
    readonly property real _lineBody: Math.ceil(fmBody.height)

    // ---- The facts ---------------------------------------------------------------
    readonly property var _factsBuilt: {
        // The formatter is read BEFORE the model, and that order is load-bearing:
        // the service's `config` is an object literal Qt finalizes lazily, so the
        // first binding to read it fires the service's onConfigChanged -> rebuild
        // -> model assignment; a builder that had already captured the model would
        // be re-entered mid-evaluation (a binding loop, measured on the tiles).
        const F = tiles._F;
        const m = tiles._model;
        const empty = {
            precip: { total: "–", next: "", bars: [] },
            wind: { fig: "–", dir: null, gust: "", hasDir: false },
            aq: { fig: "–", band: -1, name: "", has: false },
            pollen: { fig: "–", sub: "", band: -1, has: false },
            humidity: { fig: "–", sub: "", band: "" },
            uv: { fig: "–", name: "", f: -1 },
            visibility: { fig: "–", name: "" },
            pressure: { fig: "–", trend: 0, name: "" },
            sun: { fig: "–", sub: "", f: -1 },
            moon: { name: "–", sub: "", phase: 0.5 }
        };
        if (!m || !m.current)
            return empty;
        const c = m.current;
        const d = m.daily && m.daily.length > 0 ? m.daily[0] : null;
        const out = {};

        // precipitation
        let next = "";
        const bars = [];
        for (let i = 0; i < m.hourly.length; i++) {
            const h = m.hourly[i];
            const mm = h.precip && h.precip.mm !== null ? h.precip.mm : 0;
            if (i < 12)
                bars.push(mm);
            if (next === "" && mm >= 0.1)
                next = "next: " + F.time(h.timeMs);
        }
        if (next === "")
            next = "none in " + m.hourly.length + " h";
        out.precip = {
            total: F.precip(d && d.precip ? d.precip.total : null) + " " + F.precipUnit() + " today",
            next: next, bars: bars
        };

        // wind
        const w = c.wind || null;
        out.wind = {
            fig: F.wind(w),
            dir: w ? w.dir : null,
            hasDir: !!(w && w.dir !== null),
            gust: w && (w.gustBft !== null || w.gust !== null) ? "gusts " + F.wind({ bft: w.gustBft, speed: w.gust }) : "",
            dirText: w && w.dirText ? w.dirText : ""
        };

        // air quality
        if (c.aq && c.aq.index !== null) {
            const b = Scales.bandOf(m.aqIndex, c.aq.index);
            out.aq = { fig: String(Math.round(c.aq.index)), band: b ? b.band : -1, name: b ? b.name : "", has: true };
        } else {
            out.aq = { fig: "–", band: -1, name: "no data", has: false };
        }

        // pollen
        if (!c.aq) {
            out.pollen = { fig: "–", sub: "no data", band: -1, has: false };
        } else if (c.pollen && c.pollen.primary) {
            const p = c.pollen.primary;
            const lv = Scales.pollenLevel(p.species, p.conc);
            out.pollen = { fig: p.name, sub: (lv ? lv.name : "") + (m.pollenNote ? " · KMI: " + m.pollenNote : ""), band: p.band, has: true };
        } else {
            out.pollen = { fig: "none", sub: m.pollenNote ? "KMI: " + m.pollenNote : "no active species", band: 0, has: true };
        }

        // humidity
        const dp = Scales.bandOf("dewPoint", c.dewPoint);
        out.humidity = {
            fig: F.percent(c.humidity) + " %",
            sub: "dew point " + F.temp(c.dewPoint),
            band: dp ? dp.name : ""
        };

        // uv
        const ub = Scales.bandOf("uv", c.uv);
        out.uv = {
            fig: c.uv === null ? "–" : String(Math.round(c.uv * 10) / 10),
            name: ub ? ub.name : "",
            f: c.uv === null ? -1 : Math.max(0, Math.min(1, c.uv / 11))
        };

        // visibility
        const vb = Scales.bandOf("visibility", c.visibility);
        out.visibility = { fig: F.distance(c.visibility) + " " + F.distanceUnit(), name: vb ? vb.name : "" };

        // pressure
        const pb = Scales.bandOf("pressure", c.pressure);
        out.pressure = {
            fig: F.pressure(c.pressure) + " " + F.pressureUnit(),
            trend: c.pressureTrend || 0,
            name: (pb ? pb.name : "") + (c.pressureTrend > 0 ? ", rising" : c.pressureTrend < 0 ? ", falling" : ", steady")
        };

        // sun
        let sf = -1;
        if (d && d.sunriseMs !== null && d.sunsetMs !== null && d.sunsetMs > d.sunriseMs) {
            const now = c.timeMs !== null ? c.timeMs : d.sunriseMs;
            sf = (now - d.sunriseMs) / (d.sunsetMs - d.sunriseMs);
        }
        out.sun = {
            fig: F.time(d ? d.sunriseMs : null) + " → " + F.time(d ? d.sunsetMs : null),
            sub: F.duration(d ? d.daylightS : null) + " of daylight",
            f: sf
        };

        // moon
        out.moon = {
            name: d && d.moonName ? d.moonName : "–",
            sub: d && d.moonIllumination !== null ? Math.round(d.moonIllumination * 100) + " % lit" : "",
            phase: d && d.moonPhase !== null ? d.moonPhase : 0.5
        };
        return out;
    }

    // ---- THE PLACE MORPH (WeatherPopup) ------------------------------------------------------------------
    // `_facts` is what the tiles DRAW: on a change of place the numbers (the twelve bars, the wind's needle, the UV and sun
    // marks, the moon's phase) go from the old place's to the new one's on the popup's clock, and every word swaps at once.
    // The popup calls `placeBegin()` BEFORE it writes the model and restarts the clock at zero, so the picture on screen is the
    // snapshot at every step of the change. A band or a trend is a category: the new place's, at once.
    property var _placeFrom: null
    readonly property var _placeRules: ({
        cyclic: { dir: 360, phase: 1 },
        discrete: { band: true, trend: true }
    })
    readonly property var _facts: tiles.popup && tiles.popup.placeMorphing && tiles._placeFrom
        ? PB.facts(tiles._placeFrom, tiles._factsBuilt, tiles.popup.placeE, tiles._placeRules) : tiles._factsBuilt
    function placeBegin() {
        tiles._placeFrom = tiles._facts;
    }

    function tileItem(metric) {
        switch (metric) {
        case "precipitation": return tPrecip;
        case "wind": return tWind;
        case "airQuality": return tAq;
        case "pollen": return tPollen;
        case "humidity": return tHumidity;
        case "uv": return tUv;
        case "visibility": return tVis;
        case "pressure": return tPressure;
        case "sunMoon": return tSun;
        default: return null;
        }
    }

    // A figure line and a sub line, the shape every tile's text takes.
    component TileText: Item {
        id: tt
        property string figure: ""
        property string sub: ""
        property real rightRoom: 0
        width: parent ? parent.width - tt.rightRoom : 0
        height: tiles._lineFig + tiles._lineBody
        Text {
            x: 0
            y: 0
            width: parent.width
            height: tiles._lineFig
            text: tt.figure
            elide: Text.ElideRight
            color: Theme.textPrimary
            font.family: tiles._font
            font.pixelSize: tiles.figureSize
            font.bold: true
            verticalAlignment: Text.AlignVCenter
        }
        Text {
            x: 0
            y: tiles._lineFig
            width: parent.width
            height: tiles._lineBody
            text: tt.sub
            elide: Text.ElideRight
            color: Theme.textMuted
            font.family: tiles._font
            font.pixelSize: tiles.bodySize
            verticalAlignment: Text.AlignVCenter
        }
    }

    // ---- precipitation ----------------------------------------------------------
    WeatherTile {
        id: tPrecip
        popup: tiles.popup
        metric: "precipitation"
        title: "Precipitation"
        cell: 0
        x: tiles._x(0)
        y: tiles._y(0)
        width: tiles._w(0)
        height: tiles._h(0)
        radius: tiles.tileRadius
        padding: tiles.tilePadding
        titleSize: tiles.titleSize
        fontFamily: tiles._font
        hoverGroundAlpha: tiles.hoverGroundAlpha
        hoverMs: tiles.hoverMs
        skeleton: tiles._skeleton
        skeletonPulse: tiles._pulse
        fadeMs: tiles._fadeMs
        TileText {
            figure: tiles._facts.precip.total
            sub: tiles._facts.precip.next
        }
        Row {
            x: 0
            y: tPrecip.bodyHeight - tiles.markHeight
            height: tiles.markHeight
            spacing: tiles.barGap
            Repeater {
                model: tiles._facts.precip.bars.length
                Item {
                    id: pBar
                    required property int index
                    readonly property real mm: tiles._facts.precip.bars[pBar.index] || 0
                    width: tiles.barWidth
                    height: tiles.markHeight
                    Rectangle {
                        x: 0
                        width: parent.width
                        height: Math.max(pBar.mm > 0 ? 2 : 1, Math.min(1, pBar.mm / 4) * tiles.markHeight)
                        y: parent.height - height
                        radius: 1
                        color: pBar.mm > 0 ? Theme.weatherRain : Theme.border
                    }
                }
            }
        }
    }

    // ---- wind ----------------------------------------------------------------------
    WeatherTile {
        id: tWind
        onPicked: tiles.glyphFlourish.play("wind", roseArrow.flourishBeats)
        popup: tiles.popup
        metric: "wind"
        title: "Wind"
        cell: 1
        x: tiles._x(1)
        y: tiles._y(1)
        width: tiles._w(1)
        height: tiles._h(1)
        radius: tiles.tileRadius
        padding: tiles.tilePadding
        titleSize: tiles.titleSize
        fontFamily: tiles._font
        hoverGroundAlpha: tiles.hoverGroundAlpha
        hoverMs: tiles.hoverMs
        skeleton: tiles._skeleton
        skeletonPulse: tiles._pulse
        fadeMs: tiles._fadeMs
        TileText {
            figure: tiles._facts.wind.fig + (tiles._facts.wind.dirText ? "  " + tiles._facts.wind.dirText : "")
            sub: tiles._facts.wind.gust
            rightRoom: tiles.roseSize + 8
        }
        // The compass rose: a ring with the direction the wind comes FROM.
        Item {
            id: rose
            x: tWind.bodyWidth - width
            y: Math.round((tWind.bodyHeight - height) / 2)
            width: tiles.roseSize
            height: tiles.roseSize
            Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: "transparent"
                border.width: 1
                border.color: Theme.border
            }
            Rectangle {
                x: (parent.width - width) / 2
                y: 0
                width: 1
                height: 3
                color: Theme.textFaint
            }
            // The strip's and the list's carved dart; no direction is its dot.
            // Centred by hand: anchors.centerIn rounds the offset.
            WeatherGlyph {
                id: roseArrow
                posing: tiles.glyphFlourish.on("wind")
                poseBeat: tiles.glyphFlourish.beatOf("wind")
                kind: "arrow"
                direction: tiles._facts.wind.hasDir ? tiles._facts.wind.dir : null
                size: Math.round(tiles.roseSize * 0.55)
                x: (rose.width - width) / 2
                y: (rose.height - height) / 2
                style: tiles._gs
            }
            Rectangle {
                readonly property real a: (tiles._facts.wind.hasDir ? tiles._facts.wind.dir : 0) * Math.PI / 180
                readonly property real r: (tiles.roseSize - width) / 2
                width: 5
                height: 5
                radius: 2.5
                visible: tiles._facts.wind.hasDir
                x: (rose.width - width) / 2 + r * Math.sin(a)
                y: (rose.height - height) / 2 - r * Math.cos(a)
                color: Theme.accent
            }
        }
    }

    // ---- air quality -----------------------------------------------------------------
    WeatherTile {
        id: tAq
        popup: tiles.popup
        metric: "airQuality"
        title: "Air quality"
        cell: 2
        x: tiles._x(2)
        y: tiles._y(2)
        width: tiles._w(2)
        height: tiles._h(2)
        radius: tiles.tileRadius
        padding: tiles.tilePadding
        titleSize: tiles.titleSize
        fontFamily: tiles._font
        hoverGroundAlpha: tiles.hoverGroundAlpha
        hoverMs: tiles.hoverMs
        skeleton: tiles._skeleton
        skeletonPulse: tiles._pulse
        fadeMs: tiles._fadeMs
        TileText {
            figure: tiles._facts.aq.fig
            sub: tiles._facts.aq.name
        }
        Row {
            x: 0
            y: tAq.bodyHeight - tiles.markHeight
            height: tiles.markHeight
            spacing: tiles.dotGap
            visible: tiles._facts.aq.has
            Repeater {
                model: 6
                Item {
                    id: bandCell
                    required property int index
                    readonly property bool current: tiles._facts.aq.band === bandCell.index
                    width: tiles.dotSize + 2
                    height: tiles.markHeight
                    Rectangle {
                        anchors.centerIn: parent
                        width: tiles.dotSize
                        height: tiles.dotSize
                        radius: width / 2
                        color: Theme.bands[bandCell.index]
                        opacity: bandCell.current ? 0 : 0.45
                    }
                    ShadowBox {
                        anchors.centerIn: parent
                        width: tiles.dotSize + 2
                        height: tiles.dotSize + 2
                        visible: bandCell.current
                        raised: true
                        shadowToAlpha: true
                        baseRadius: width / 2
                        surfaceColor: Theme.listBox
                        bevelColor: Theme.buttonBevel
                        shadowColor: Theme.buttonShadow
                        backgroundColor: Theme.bands[bandCell.index]
                        bevelWidth: 1
                        shadowWidth: 2
                        shadowEdgeAlpha: 0.7
                    }
                }
            }
        }
    }

    // ---- pollen ------------------------------------------------------------------------
    WeatherTile {
        id: tPollen
        popup: tiles.popup
        metric: "pollen"
        title: "Pollen"
        cell: 3
        x: tiles._x(3)
        y: tiles._y(3)
        width: tiles._w(3)
        height: tiles._h(3)
        radius: tiles.tileRadius
        padding: tiles.tilePadding
        titleSize: tiles.titleSize
        fontFamily: tiles._font
        hoverGroundAlpha: tiles.hoverGroundAlpha
        hoverMs: tiles.hoverMs
        skeleton: tiles._skeleton
        skeletonPulse: tiles._pulse
        fadeMs: tiles._fadeMs
        TileText {
            figure: tiles._facts.pollen.fig
            sub: tiles._facts.pollen.sub
            rightRoom: tiles.dotSize + 8
        }
        Rectangle {
            x: tPollen.bodyWidth - width
            y: (tiles._lineFig - height) / 2
            width: tiles.dotSize + 2
            height: tiles.dotSize + 2
            radius: width / 2
            visible: tiles._facts.pollen.has && tiles._facts.pollen.band >= 0
            color: Theme.bands[Math.max(0, Math.min(5, tiles._facts.pollen.band))]
        }
    }

    // ---- humidity ----------------------------------------------------------------------
    WeatherTile {
        id: tHumidity
        popup: tiles.popup
        metric: "humidity"
        title: "Humidity"
        cell: 4
        x: tiles._x(4)
        y: tiles._y(4)
        width: tiles._w(4)
        height: tiles._h(4)
        radius: tiles.tileRadius
        padding: tiles.tilePadding
        titleSize: tiles.titleSize
        fontFamily: tiles._font
        hoverGroundAlpha: tiles.hoverGroundAlpha
        hoverMs: tiles.hoverMs
        skeleton: tiles._skeleton
        skeletonPulse: tiles._pulse
        fadeMs: tiles._fadeMs
        TileText {
            figure: tiles._facts.humidity.fig
            sub: tiles._facts.humidity.sub
        }
        Text {
            x: 0
            y: tHumidity.bodyHeight - height
            text: tiles._facts.humidity.band
            color: Theme.textFaint
            font.family: tiles._font
            font.pixelSize: tiles.bodySize
        }
    }

    // ---- uv -------------------------------------------------------------------------------
    WeatherTile {
        id: tUv
        popup: tiles.popup
        metric: "uv"
        title: "UV index"
        cell: 5
        x: tiles._x(5)
        y: tiles._y(5)
        width: tiles._w(5)
        height: tiles._h(5)
        radius: tiles.tileRadius
        padding: tiles.tilePadding
        titleSize: tiles.titleSize
        fontFamily: tiles._font
        hoverGroundAlpha: tiles.hoverGroundAlpha
        hoverMs: tiles.hoverMs
        skeleton: tiles._skeleton
        skeletonPulse: tiles._pulse
        fadeMs: tiles._fadeMs
        TileText {
            figure: tiles._facts.uv.fig
            sub: tiles._facts.uv.name
        }
        Item {
            x: 0
            y: tUv.bodyHeight - tiles.markHeight
            width: tUv.bodyWidth
            height: tiles.markHeight
            // The groove sits on a ground that changes (the hover wash, the
            // open tile's headerBox), so its carve is the translucent one:
            // over listBox exactly the opaque colours, over a darker ground
            // still darker than it instead of a light pill.
            ShadowBox {
                x: 0
                y: (parent.height - height) / 2
                width: parent.width
                height: 6
                baseRadius: 3
                surfaceColor: "transparent"
                bevelColor: Mix.carve(Theme.listBox, Theme.bevel, Theme.buttonBevel)
                shadowColor: Mix.carve(Theme.listBox, Theme.border, Theme.shadowDeep)
                backgroundColor: Mix.carve(Theme.listBox, Theme.panelSunk, Theme.shadowDeep)
                bevelWidth: tiles.popup ? tiles.popup.grooveBevelWidth : 1
                shadowWidth: tiles.popup ? tiles.popup.grooveShadowWidth : 1.5
            }
            ShadowBox {
                visible: tiles._facts.uv.f >= 0
                x: Math.max(0, Math.min(parent.width - width, tiles._facts.uv.f * parent.width - width / 2))
                y: (parent.height - height) / 2
                width: 10
                height: 10
                raised: true
                shadowToAlpha: true
                baseRadius: 5
                surfaceColor: Theme.panelSunk
                bevelColor: Theme.buttonBevel
                shadowColor: Theme.buttonShadow
                backgroundColor: Theme.weatherSun
                bevelWidth: 1
                shadowWidth: 2
                shadowEdgeAlpha: 0.7
            }
        }
    }

    // ---- visibility -------------------------------------------------------------------------
    WeatherTile {
        id: tVis
        popup: tiles.popup
        metric: "visibility"
        title: "Visibility"
        cell: 6
        x: tiles._x(6)
        y: tiles._y(6)
        width: tiles._w(6)
        height: tiles._h(6)
        radius: tiles.tileRadius
        padding: tiles.tilePadding
        titleSize: tiles.titleSize
        fontFamily: tiles._font
        hoverGroundAlpha: tiles.hoverGroundAlpha
        hoverMs: tiles.hoverMs
        skeleton: tiles._skeleton
        skeletonPulse: tiles._pulse
        fadeMs: tiles._fadeMs
        TileText {
            figure: tiles._facts.visibility.fig
            sub: tiles._facts.visibility.name
        }
    }

    // ---- pressure -----------------------------------------------------------------------------
    WeatherTile {
        id: tPressure
        onPicked: tiles.glyphFlourish.play("pressure", trendArrow.flourishBeats)
        popup: tiles.popup
        metric: "pressure"
        title: "Pressure"
        cell: 7
        x: tiles._x(7)
        y: tiles._y(7)
        width: tiles._w(7)
        height: tiles._h(7)
        radius: tiles.tileRadius
        padding: tiles.tilePadding
        titleSize: tiles.titleSize
        fontFamily: tiles._font
        hoverGroundAlpha: tiles.hoverGroundAlpha
        hoverMs: tiles.hoverMs
        skeleton: tiles._skeleton
        skeletonPulse: tiles._pulse
        fadeMs: tiles._fadeMs
        TileText {
            figure: tiles._facts.pressure.fig
            sub: tiles._facts.pressure.name
            rightRoom: 20
        }
        // The trend: the carved dart up, level (right), or down. The glyph
        // points direction + 180, as for the wind.
        WeatherGlyph {
            id: trendArrow
            posing: tiles.glyphFlourish.on("pressure")
            poseBeat: tiles.glyphFlourish.beatOf("pressure")
            kind: "arrow"
            x: tPressure.bodyWidth - width
            y: (tiles._lineFig - height) / 2
            size: 14
            direction: tiles._facts.pressure.trend > 0 ? 180 : (tiles._facts.pressure.trend < 0 ? 0 : 270)
            style: tiles._gs
        }
    }

    // ---- sun ----------------------------------------------------------------------------------
    WeatherTile {
        id: tSun
        popup: tiles.popup
        metric: "sunMoon"
        title: "Sun"
        cell: 8
        x: tiles._x(8)
        y: tiles._y(8)
        width: tiles._w(8)
        height: tiles._h(8)
        radius: tiles.tileRadius
        padding: tiles.tilePadding
        titleSize: tiles.titleSize
        fontFamily: tiles._font
        hoverGroundAlpha: tiles.hoverGroundAlpha
        hoverMs: tiles.hoverMs
        skeleton: tiles._skeleton
        skeletonPulse: tiles._pulse
        fadeMs: tiles._fadeMs
        TileText {
            figure: tiles._facts.sun.fig
            sub: tiles._facts.sun.sub
            rightRoom: tiles.arcWidth + 8
        }
        // The day arc: sunrise at its left foot, sunset at its right, the sun
        // at the fraction of daylight that has passed.
        Item {
            id: arc
            x: tSun.bodyWidth - width
            y: Math.round((tSun.bodyHeight - height) / 2)
            width: tiles.arcWidth
            height: tiles.arcWidth / 2 + 6
            readonly property real r: tiles.arcWidth / 2 - 4
            readonly property real cx: tiles.arcWidth / 2
            readonly property real cy: tiles.arcWidth / 2
            Shape {
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    strokeColor: Theme.border
                    strokeWidth: 1.5
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    startX: arc.cx - arc.r
                    startY: arc.cy
                    PathArc {
                        x: arc.cx + arc.r
                        y: arc.cy
                        radiusX: arc.r
                        radiusY: arc.r
                        useLargeArc: false
                        direction: PathArc.Clockwise
                    }
                }
            }
            Rectangle {
                x: 0
                y: arc.cy
                width: parent.width
                height: 1
                color: Theme.border
                opacity: 0.6
            }
            ShadowBox {
                readonly property real f: tiles._facts.sun.f
                readonly property real a: Math.PI * (1 - Math.max(0, Math.min(1, f)))
                visible: f >= 0 && f <= 1
                width: 9
                height: 9
                x: arc.cx + arc.r * Math.cos(a) - width / 2
                y: arc.cy - arc.r * Math.sin(a) - height / 2
                raised: true
                shadowToAlpha: true
                baseRadius: 4.5
                surfaceColor: Theme.listBox
                bevelColor: Theme.buttonBevel
                shadowColor: Theme.buttonShadow
                backgroundColor: Theme.weatherSun
                bevelWidth: 1
                shadowWidth: 2
                shadowEdgeAlpha: 0.7
            }
        }
    }

    // ---- moon ----------------------------------------------------------------------------------
    WeatherTile {
        id: tMoon
        onPicked: tiles.glyphFlourish.play("moon", moonGlyph.flourishBeats)
        popup: tiles.popup
        metric: "sunMoon"
        title: "Moon"
        cell: 9
        x: tiles._x(9)
        y: tiles._y(9)
        width: tiles._w(9)
        height: tiles._h(9)
        radius: tiles.tileRadius
        padding: tiles.tilePadding
        titleSize: tiles.titleSize
        fontFamily: tiles._font
        hoverGroundAlpha: tiles.hoverGroundAlpha
        hoverMs: tiles.hoverMs
        skeleton: tiles._skeleton
        skeletonPulse: tiles._pulse
        fadeMs: tiles._fadeMs
        WeatherGlyph {
            id: moonGlyph
            posing: tiles.glyphFlourish.on("moon")
            poseBeat: tiles.glyphFlourish.beatOf("moon")
            x: 0
            y: Math.round((tMoon.bodyHeight - height) / 2)
            size: tiles.moonSize
            kind: "moon"
            night: true
            moonPhase: tiles._facts.moon.phase
            style: tiles._gs
        }
        Item {
            x: tiles.moonSize + 10
            y: Math.round((tMoon.bodyHeight - height) / 2)
            width: tMoon.bodyWidth - x
            height: tiles._lineFig + tiles._lineBody
            Text {
                x: 0
                y: 0
                width: parent.width
                height: tiles._lineFig
                text: tiles._facts.moon.name
                elide: Text.ElideRight
                color: Theme.textPrimary
                font.family: tiles._font
                font.pixelSize: tiles.figureSize
                font.bold: true
                verticalAlignment: Text.AlignVCenter
            }
            Text {
                x: 0
                y: tiles._lineFig
                width: parent.width
                height: tiles._lineBody
                text: tiles._facts.moon.sub
                elide: Text.ElideRight
                color: Theme.textMuted
                font.family: tiles._font
                font.pixelSize: tiles.bodySize
                verticalAlignment: Text.AlignVCenter
            }
        }
    }
}
