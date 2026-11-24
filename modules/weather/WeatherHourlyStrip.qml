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
// WeatherHourlyStrip.qml -- 48 hours, one 44 px column each, in nine views.
//
// A carved card holding a horizontal Flickable that is NOT interactive: the
// popup's one wheel reader scrolls it through `scrollBy()` (x) and cycles its
// view through `cycleBy()` / `endCycle()` (y), which feed the CardViewCycler
// laid over the card. ScrollDressing draws only the edge fades.
//
// ---- THE VIEWS (index order is the contract) -------------------------------------
//
//   i  id             glyph slot   bar over the track           line (labels)       value slot
//   0  conditions     condition    PoP %, faint, max 100        temperature + faint PoP %
//                                                               feels-like, shadow
//   1  wind           ARROW        Beaufort, band colour, 10+   --                  Bft
//   2  precipitation  condition    mm, rain/snow hue, 5+        --                  mm
//   3  uv             --           UV, WHO band colour, 8+      --                  UV
//   4  humidity       condition    humidity %, faint, max 100   dew point           humidity %
//   5  pressure       condition    --                           pressure            --
//   6  cloudCover     condition    cloud %, cloud hue, max 100  --                  %
//   7  visibility     condition    --                           visibility          Fog / Mist
//   8  airQuality     --           index, band colour, 100/10+  --                  index
//
// "N+" is a maximum that GROWS while a column whose centre is inside the
// viewport exceeds it, eased `maxMs`. Units live in the view's label ("Wind
// (Bft)", "Pressure (hPa)") so every figure fits its column bare. Pressure's
// value slot is blank: the labels carry the value and the line's slope is the
// trend, so a third figure per column would only repeat them. Visibility's
// names the WMO band only when it matters (under 5 km).
//
// ---- THE GEOMETRY, per column, top to bottom (content y) ----------------------
//
//   0            hour label       _lineLabel (11 px face); midnight shows the
//                                 weekday in textPrimary with a divider left
//   + rowGap
//   _glyphY      glyph slot       glyphSize; condition glyph and arrow share
//                                 it, each scaled by its views' weight
//   + rowGap
//   _bandTop     CHART BAND ----------------------------------------------------
//                  room for a figure above the highest point: _labelRoom + figureGap
//   _pointTop      highest point of any line
//                  curveHeight   (every line's own range maps onto this span)
//   _pointBottom   lowest point of any line
//                  the same room below it: figureGap + _labelRoom
//   _bandBottom  ---------------------------------------------------------------
//                the TRACK: trackWidth wide, centred, from _bandTop + trackPad
//                to _bandBottom - trackPad; a bar grows up from its foot, so a
//                bar's full scale is the track's length (_trackLen). A view with
//                no glyph (UV, air quality) has nothing in the glyph slot, so
//                its track rises into the slot (_slotLift) and its bars take
//                the longer scale; the rise is weighted like everything else
//   + rowGap
//   _valueY      value slot       _lineSmall (10 px face)
//
//   _labelRoom is the taller of the two figure faces on BOTH sides of the
//   curve, because either figure can sit on either side (LABEL RULES).
//   card height = 2 * padding + _valueY + _lineSmall: with the defaults 173 px
//   in Audiowide (171 in Inter).
//
// ---- LABEL RULES --------------------------------------------------------------
//
//   Figures sit centred in their column, every one's ink inside it. On a line view the primary figure's BOTTOM is figureGap above
//   the HIGHER of the column's two points (the line's and, in conditions, the
//   feels-like line's); the feels-like figure's TOP is figureGap below the
//   LOWER of the two. So the two figures are separated by at least the two
//   points' distance plus two gaps, neither sits on either point, and both
//   stay inside the band by construction (the points are inside
//   [_pointTop, _pointBottom] and the band reserves the room on both sides).
//   WHERE FEELS-LIKE IS ABOVE THE TEMPERATURE (a humid summer hour) the two
//   sides swap for that column -- the temperature figure below the LOWER point,
//   the feels-like figure above the HIGHER -- so each figure stays next to its
//   own line with the same separation. The side is a fact of the column's data
//   (`flip`) and applies only while the primary figure is the temperature, so
//   it changes with the figure's text, at the retarget, and never slides.
//
// ---- THE TAPER (the line narrows toward off-screen territory) -----------------
//
//   The line is a filled ribbon of `lineWidth` around a dense centreline (a
//   clamped cubic through the column centres, `curveSteps` per column). Near
//   a viewport edge its width is
//
//       w(s) = lineWidth - (lineWidth - lineMinWidth) * max(kL, kR)
//       kL   = 1 - smoothstep(0, taperHours * columnWidth, s)
//       kR   = 1 - smoothstep(0, taperHours * columnWidth, W - s)
//
//   with s the point's distance from the viewport's left edge and W the
//   viewport. Both ends, always: weighting each side by the dressing's
//   fade (a side tapering only while content lies beyond it) would draw the
//   first hour at rest and the last hour at the end at full width, and the
//   taper belongs there too.
//   COST: the dense centreline, its normals and a pool of Qt.point objects are
//   built once per model (and per tick of a view morph); a scroll recomputes
//   only the offsets of the dense points inside the viewport (plus one column
//   each side) into the pooled points and hands PathMultiline slices of the
//   pool -- no point objects are allocated per scroll. Measured in JS:
//   ~0.36 ms per scroll for both ribbons, ~2 ms per morph
//   tick including every delegate binding the tick notifies.
//   The rebuild runs INSIDE the viewport's change (`_viewport`), not deferred:
//   a `Qt.callLater` could land after a frame already queued and draw the line
//   a frame behind its columns. It creates and destroys nothing, so it is safe
//   inside a wheel's delivery. The two ribbon Shapes are then synced on the
//   spot (`ensurePolished`): a Shape synced by the render loop's polish pass
//   calls update() from inside that pass, and the basic loop answers that with
//   a second, identical frame (QQuickShapePrivate::sync; measured: 12
//   frames for 6 steps, 6 with the sync here, 6 with no rebuild). A scroll step
//   presents one frame.
//   A KNOWN LIMIT: the curve renderer's antialiasing of a FILLED
//   3 px ribbon wanders by ~0.35 px along its length (a stroke of the same
//   centreline is smooth to 0.02), but a stroke can carry neither the
//   gradient nor a varying width.
//
// ---- MOTION -------------------------------------------------------------------
//
//   ONE CLOCK: `blend` (ViewBlend, viewMs OutCubic). The drawn state is a
//   weight per view (ViewBlend's `weights`: the weights drawn when the view last
//   changed move toward a one-hot of the target by the eased fraction e); a
//   retarget snapshots the drawn weights as the new start, so rapid
//   cycling continues from what is on screen. Each tick publishes ONE object, `_frame`
//   (the weights, their sums per trait, the lines' column-centre y), so a
//   delegate that reads several of them re-evaluates once per tick. Every
//   drawn quantity is a weighted sum:
//   bar height (a view without a bar contributes 0, so the bar shrinks away),
//   bar width/colour/alpha (normalised over the views that have a bar), line
//   points (normalised over the views that have a line, so a line fades in
//   place rather than sinking), line alpha, and the glyph slot: each glyph's
//   scale is 2 * weight - 1, so the leaving glyph shrinks away in the first
//   half and the arriving one grows in the second. Text swaps instantly to
//   the arriving view's; a figure's presence is the weight of the views that
//   have one.
//
// ---- THE PLACE MORPH (WeatherPopup) --------------------------------------------------------------------
//
//   A change of place MOVES the picture instead of swapping it, on the popup's clock (`popup.placeE`, OutCubic over
//   `placeMs`): every line's centreline goes from the old place's y to the new one's (the figures ride the lines, the
//   shadow and the taper follow), every bar from the old place's length to the new one's (a column with no value is a bar
//   none long, so one grows from nothing and one shrinks to it), a bar's colour between the two hues. Words and glyphs swap
//   at once (the text rule), as do the hour labels, the midnight dividers and the figures' sides. The popup calls
//   `placeBegin()` before the model changes: the strip keeps what it DRAWS (`_shownDense`, the bars it would draw), so a
//   second switch in the middle of a morph starts from what is on screen. The view blend and this one are independent
//   clocks that multiply: the weights pick WHICH series is drawn, the place clock moves each series' numbers.
//
// Every column is a link: the ground fades in under the pointer, the hand
// says so, a click opens the current view's detail for that hour
// ({ metric, dayIndex, hourIndex, from: "hourly" }); the open column carries
// the headerBox ground. The facts of every column, for EVERY view, are built
// once per model into `_cols` -- plain numbers and strings, no colours -- and
// the Repeaters take the count, so neither a theme switch nor a view switch
// (a wheel event) creates or destroys anything. Twelve silhouette columns
// stand in until the first model.
// =============================================================================
Item {
    id: strip

    property var popup: null

    // ---- Knobs ---------------------------------------------------------------
    property real columnWidth: 44
    property int hours: 48
    property real glyphSize: 24
    property int labelSize: 11
    property int figureSize: 12
    property int smallSize: 10
    property real rowGap: 4
    // The span every line's range is drawn over, and the gap between a point
    // and its figure.
    property real curveHeight: 48
    property real figureGap: 3
    property int curveSteps: 6
    // The track, the bars on it.
    property real trackWidth: 2
    // How far the track leans from the card's fill toward Theme.border.
    property real trackStrength: 0.7
    property real trackPad: 6
    // The track breaks around a figure's ink by this much above and below;
    // a piece shorter than segmentMinPx left between two breaks is dropped.
    property real trackGap: 2
    property real segmentMinPx: 3
    property real barWidth: 8
    property real faintBarWidth: 5
    property real faintBarAlpha: 0.35
    property real barMinPx: 2
    // The lines.
    property real lineWidth: 3
    property real lineMinWidth: 1.5
    property real taperHours: 3
    property real feelsLineWidth: 1.5
    property real feelsAlpha: 0.55
    property real shadowAlpha: 0.14
    // The default maxima; each grows while a visible column exceeds it.
    //   wind 10 Bft     a gale (8-9) is most of the track
    //   precip 5 mm     WMO rain intensity (CIMO Guide, WMO-No. 8): light is
    //                   under 2.5 mm/h, moderate 2.5-10, heavy over 10. Most
    //                   wet hours in Belgium are light, so light rain has to
    //                   read: on the 71 px track 0.5 mm is 7 px and 1 mm 14,
    //                   the light/moderate boundary sits at half height, a
    //                   0.1 mm drizzle hour keeps the barMinPx floor, and a
    //                   heavy downpour grows the scale while it is on screen
    //   uv 8            WHO: 8 opens "very high"; a Belgian summer midday
    //                   peaks around 7-8, so it fills the track, a winter 1-2
    //                   stays low, and a rare 9+ grows the scale
    //   aq 100 / 10     the top of the EAQI's "very poor" band / BelAQI's 10
    property real windMaxBft: 10
    property real precipMaxMm: 5
    property real uvMax: 8
    property real aqMaxEaqi: 100
    property real aqMaxBelaqi: 10
    // The smallest ranges a line is drawn over, so a flat day stays flat.
    property real tempMinSpan: 4
    property real pressureMinSpan: 8
    property real visibilityMinSpanKm: 10
    property int viewMs: 260
    property int maxMs: 260
    property real hoverGroundAlpha: 0.6
    // How far a column's ground (the hover wash, the open column) sits inside
    // its slot on EVERY side, the first and last column's too: one width for
    // every column, whatever lies beside it.
    property real groundInset: 2
    // How far the scroll viewport reaches INTO the card's padding at each
    // horizontal end: exactly the glyph's inset in its column, so at rest the
    // first hour's glyph -- the column's widest ink -- starts on the padding
    // line, as the hour labels do at the top. With the viewport on the padding
    // line a 44 px column puts its 24 px glyph 10 px further in: the first
    // hour's ink sits 22 px from the card's edge against 12 at the top
    // (measured). Once content
    // lies beyond an end, the fade's opaque lead (ScrollDressing.fadeLead)
    // covers the reach, so the fading line stays on the padding line. A
    // column's ground (the hover wash, the open column) is NOT held to the
    // padding line: the first and last columns' grounds are the width of
    // every other (`groundInset` in on both sides) and lie in the reach.
    readonly property real edgeReach: Math.max(0, (strip.columnWidth - strip.glyphSize) / 2)
    property int hoverMs: 120
    property int skeletonColumns: 12
    property real fadeHeight: 34
    // How far the scroll clip stands inside the fade's outer edge, px: the cut is under the fade's opaque lead at any scale.
    property real clipInset: 1

    // ---- The views ----------------------------------------------------------------
    // Static per index: glyph 0 none / 1 condition / 2 arrow; bar 0 none /
    // 1 faint / 2 opaque; line "" or the series key; feels (conditions only).
    readonly property var _viewSpec: [
        { glyph: 1, bar: 1, line: "temp", feels: true },
        { glyph: 2, bar: 2, line: "", feels: false },
        { glyph: 1, bar: 2, line: "", feels: false },
        { glyph: 0, bar: 2, line: "", feels: false },
        { glyph: 1, bar: 1, line: "dew", feels: false },
        { glyph: 1, bar: 0, line: "pressure", feels: false },
        { glyph: 1, bar: 2, line: "", feels: false },
        { glyph: 1, bar: 0, line: "vis", feels: false },
        { glyph: 0, bar: 2, line: "", feels: false }
    ]
    readonly property var views: {
        const F = strip._F;
        return [
            { id: "conditions", label: "Conditions", metric: "conditions" },
            { id: "wind", label: "Wind (Bft)", metric: "wind" },
            { id: "precipitation", label: "Precipitation (" + F.precipUnit() + ")", metric: "precipitation" },
            { id: "uv", label: "UV index", metric: "uv" },
            { id: "humidity", label: "Humidity & dew point", metric: "humidity" },
            { id: "pressure", label: "Pressure (" + F.pressureUnit() + ")", metric: "pressure" },
            { id: "cloudCover", label: "Cloud cover", metric: "cloudCover" },
            { id: "visibility", label: "Visibility (" + F.distanceUnit() + ")", metric: "visibility" },
            { id: "airQuality", label: "Air quality", metric: "airQuality" }
        ];
    }
    // The view the card OPENS on, for a host that remembers it across the popup's life (the
    // engine destroys the content on close). A binding on the cycler's index until the first
    // jump, so the card is built on it at rest -- no transition from view 0.
    property int startView: 0
    // The cycler writes the index (wheel, dot); set a view with cycler.select(i).
    readonly property int viewIndex: cycler.currentIndex
    readonly property string viewId: strip.views[Math.max(0, Math.min(strip.views.length - 1, strip.viewIndex))].id
    readonly property alias cycler: cycler
    // The view clock (harness stills: blend.pin(t)).
    readonly property alias blend: blend

    function cycleBy(units, fromPixels) {
        cycler.feed(units, fromPixels);
    }
    function endCycle() {
        cycler.end();
    }

    // ---- What it reads ---------------------------------------------------------
    readonly property var _model: strip.popup ? strip.popup.model : null
    readonly property var _F: strip.popup ? strip.popup.fmt : WM.format({})
    readonly property string _font: strip.popup ? strip.popup.fontFamily : "Inter"
    readonly property var _gs: strip.popup ? strip.popup.glyphStyle : ({})
    // A column's glyph flourishes when the pointer comes onto the column or clicks it (the condition, or the wind's arrow where
    // that is on show), each to its end: one clock for the strip, a run per column.
    readonly property WeatherGlyphFlourish glyphFlourish: WeatherGlyphFlourish {
        host: strip
        beatMs: strip.popup ? strip.popup.glyphFlourishMs : 900
    }
    readonly property real _pad: strip.popup ? strip.popup.cardPadding : 12
    readonly property real _radius: strip.popup ? strip.popup.radius : 14
    readonly property int _fadeMs: strip.popup ? strip.popup.fadeMs : 160
    readonly property var _activeKey: strip.popup ? strip.popup.activeKey : null
    // The carve: the popup's knobs, with its defaults when there is no popup.
    readonly property real _cardBevel: strip.popup ? strip.popup.cardBevelWidth : 1
    readonly property real _cardShadow: strip.popup ? strip.popup.cardShadowWidth : 3
    readonly property real _cardFalloff: strip.popup ? strip.popup.cardShadowFalloff : 1
    readonly property color _cardBevelColor: strip.popup ? strip.popup.cardBevelColor : Theme.bevel
    readonly property real _insetBevel: strip.popup ? strip.popup.insetBevelWidth : 1
    readonly property real _insetShadow: strip.popup ? strip.popup.insetShadowWidth : 3
    readonly property real _insetFalloff: strip.popup ? strip.popup.insetShadowFalloff : 1
    // A chance of precipitation under this shows neither its bar nor its figure.
    readonly property real _probMin: strip.popup ? strip.popup.probLabelMin : 10
    readonly property bool _hasModel: strip._cols.length > 0
    // The track is a translucent shade, solved to the card's own colour over the
    // card's fill, so it keeps its depth over the open column's darker ground.
    readonly property color _trackColor: Mix.carve(Theme.listBox, Mix.c(Theme.listBox, Theme.border, strip.trackStrength), Theme.shadowDeep)
    // The column under the pointer, -1 for none.
    property int _hoverIndex: -1

    // ---- Metrics ----------------------------------------------------------------
    FontMetrics {
        id: fmLabel
        font.family: strip._font
        font.pixelSize: strip.labelSize
    }
    FontMetrics {
        id: fmFig
        font.family: strip._font
        font.pixelSize: strip.figureSize
    }
    FontMetrics {
        id: fmSmall
        font.family: strip._font
        font.pixelSize: strip.smallSize
    }
    readonly property real _lineLabel: Math.ceil(fmLabel.height)
    readonly property real _lineFig: Math.ceil(fmFig.height)
    readonly property real _lineSmall: Math.ceil(fmSmall.height)

    // ---- The rows, top to bottom (content coordinates; the header has the plan) --
    readonly property real _labelY: 0
    readonly property real _glyphY: strip._lineLabel + strip.rowGap
    readonly property real _bandTop: strip._glyphY + strip.glyphSize + strip.rowGap
    readonly property real _labelRoom: Math.max(strip._lineFig, strip._lineSmall)
    readonly property real _pointTop: strip._bandTop + strip._labelRoom + strip.figureGap
    readonly property real _pointBottom: strip._pointTop + strip.curveHeight
    readonly property real _bandBottom: strip._pointBottom + strip.figureGap + strip._labelRoom
    readonly property real _trackTop: strip._bandTop + strip.trackPad
    // How far a glyph-less view's track rises into the empty glyph slot, and
    // the drawn top under the weights.
    readonly property real _slotLift: strip.glyphSize + strip.rowGap
    readonly property real _trackTopNow: strip._trackTop - (1 - strip._frame.g) * strip._slotLift
    readonly property real _trackBottom: strip._bandBottom - strip.trackPad
    readonly property real _trackLen: Math.max(0, strip._trackBottom - strip._trackTop)
    readonly property real _valueY: strip._bandBottom + strip.rowGap
    readonly property real _contentH: strip._valueY + strip._lineSmall
    readonly property real _innerW: strip.width - 2 * strip._pad
    readonly property real _innerH: strip.height - 2 * strip._pad

    implicitWidth: 480
    implicitHeight: strip._pad * 2 + strip._contentH

    // ---- The facts ---------------------------------------------------------------
    // Hue codes a delegate resolves: 0 rain, 1 snow, 2 cloud, 10 + n band n.
    readonly property var _cols: {
        // The formatter is read BEFORE the model, and that order is load-bearing:
        // the service's `config` is an object literal Qt finalizes lazily, so the
        // first binding to read it fires the service's onConfigChanged -> rebuild
        // -> model assignment; a builder that had already captured the model would
        // be re-entered mid-evaluation (a binding loop; WeatherTiles has the measurement).
        const F = strip._F;
        const m = strip._model;
        const probMin = strip._probMin;
        if (!m || !m.hourly || m.hourly.length === 0)
            return [];
        const n = Math.min(strip.hours, m.hourly.length);
        const has = function (v) { return typeof v === "number" && isFinite(v); };
        const out = [];
        let day = 0;
        for (let i = 0; i < n; i++) {
            const h = m.hourly[i];
            const lp = h.timeMs !== null ? WM.localParts(h.timeMs) : null;
            const midnight = i > 0 && lp !== null && lp.hour === 0;
            if (midnight)
                day++;
            const d = m.daily && day < m.daily.length ? m.daily[day] : null;
            const snow = (h.precip.snowCm !== null && h.precip.snowCm > 0) && (h.kind === "snow" || h.kind === "sleet");
            const wind = h.wind || null;
            const bft = wind && has(wind.bft) ? wind.bft : null;
            const bftBand = wind && has(wind.speed) ? Scales.beaufort(wind.speed).band : 0;
            const prob = has(h.precip.prob) ? h.precip.prob : null;
            const mm = has(h.precip.mm) ? h.precip.mm : null;
            const uv = has(h.uv) ? h.uv : null;
            const uvBand = uv !== null ? Scales.bandOf("uv", uv).band : 0;
            const hum = has(h.humidity) ? h.humidity : null;
            const cloud = has(h.cloudCover) ? h.cloudCover : null;
            const vis = has(h.visibility) ? h.visibility : null;
            const visBand = vis !== null ? Scales.bandOf("visibility", vis) : null;
            const aq = h.aq && has(h.aq.index) ? h.aq.index : null;
            const aqBand = h.aq && has(h.aq.band) ? h.aq.band : 0;
            out.push({
                label: lp === null ? "–" : (midnight ? F.weekday(h.timeMs) : F.hour(h.timeMs)),
                midnight: midnight,
                dayIndex: day,
                hour: lp === null ? 0 : lp.hour,
                kind: h.kind,
                intensity: h.intensity === null ? 1 : h.intensity,
                night: !!h.night,
                shower: !!h.shower,
                moonPhase: d && d.moonPhase !== null ? d.moonPhase : 0.5,
                windDir: wind && has(wind.dir) ? wind.dir : null,
                // Per view, by index.
                // UV's bar shares its figure's threshold: a UV under 0.5 has
                // no figure, so it has no bar either (not a dash under nothing).
                bar: [prob !== null && prob >= probMin ? prob : null, bft, mm,
                      uv !== null && Math.round(uv) >= 1 ? uv : null, hum, null, cloud, null, aq],
                hue: [0, 10 + bftBand, snow ? 1 : 0, 10 + uvBand, 0, 0, 2, 0, 10 + aqBand],
                value: [
                    prob !== null && prob >= probMin ? F.percent(prob) + " %" : "",
                    bft !== null ? String(bft) : "",
                    mm !== null && mm > 0 ? F.precip(mm) : "",
                    uv !== null && Math.round(uv) >= 1 ? String(Math.round(uv)) : "",
                    hum !== null ? F.percent(hum) + " %" : "",
                    "",
                    cloud !== null ? F.percent(cloud) + " %" : "",
                    visBand !== null && visBand.band >= 3 ? visBand.name : "",
                    aq !== null ? String(Math.round(aq)) : ""
                ],
                line: [
                    has(h.temp) ? F.temp(h.temp) : "", "", "", "",
                    has(h.dewPoint) ? F.temp(h.dewPoint) : "",
                    has(h.pressure) ? F.pressure(h.pressure) : "",
                    "",
                    vis !== null ? F.distance(vis) : "",
                    ""
                ],
                feelsText: has(h.feelsLike) ? F.temp(h.feelsLike) : "",
                // Feels-like runs above the temperature here: the figures swap sides.
                flip: has(h.feelsLike) && has(h.temp) && h.feelsLike > h.temp,
                temp: has(h.temp) ? h.temp : null,
                feels: has(h.feelsLike) ? h.feelsLike : null,
                dew: has(h.dewPoint) ? h.dewPoint : null,
                pressure: has(h.pressure) ? h.pressure : null,
                vis: vis
            });
        }
        return out;
    }
    readonly property bool _belaqi: !!strip._model && strip._model.aqIndex === "belaqi"

    // ---- The lines: ranges, then the dense centrelines, once per model -----------
    function _rangeOf(keys, minSpan, fromZero) {
        let lo = Infinity, hi = -Infinity;
        const cols = strip._cols;
        for (let i = 0; i < cols.length; i++) {
            for (let k = 0; k < keys.length; k++) {
                const v = cols[i][keys[k]];
                if (v === null)
                    continue;
                if (v < lo) lo = v;
                if (v > hi) hi = v;
            }
        }
        if (!(lo <= hi))
            return { lo: 0, hi: 1 };
        if (fromZero)
            return { lo: 0, hi: Math.max(hi, minSpan) };
        if (hi - lo < minSpan) {
            const mid = (lo + hi) / 2;
            return { lo: mid - minSpan / 2, hi: mid + minSpan / 2 };
        }
        return { lo: lo, hi: hi };
    }
    readonly property var _ranges: {
        const t = strip._rangeOf(["temp", "feels"], strip.tempMinSpan);
        return {
            temp: t,
            feels: t,
            dew: strip._rangeOf(["dew"], strip.tempMinSpan),
            pressure: strip._rangeOf(["pressure"], strip.pressureMinSpan),
            // A distance is read from zero: 15 and 50 km are both clear air,
            // and fog belongs at the foot.
            vis: strip._rangeOf(["vis"], strip.visibilityMinSpanKm * 1000, true)
        };
    }
    readonly property int _denseCount: strip._cols.length > 0 ? (strip._cols.length - 1) * strip.curveSteps + 1 : 0
    function _denseX(k) {
        return strip.columnWidth / 2 + k * strip.columnWidth / strip.curveSteps;
    }
    // Content-y per dense index for one series, NaN where a column has no
    // value. A clamped cubic (no overshoot between two points) with reflected
    // ends, so x is uniform in the parameter and every series shares one grid.
    function _denseOf(key) {
        const cols = strip._cols;
        const n = cols.length;
        const S = strip.curveSteps;
        const r = strip._ranges[key];
        const top = strip._pointTop, span = strip.curveHeight;
        const out = new Array(strip._denseCount).fill(NaN);
        const yv = function (i) {
            const v = i >= 0 && i < n ? cols[i][key] : null;
            return v === null ? NaN : top + (r.hi - v) / (r.hi - r.lo) * span;
        };
        for (let i = 0; i < n; i++) {
            const y1 = yv(i);
            if (isNaN(y1))
                continue;
            out[i * S] = y1;
            const y2 = yv(i + 1);
            if (i + 1 >= n || isNaN(y2))
                continue;
            let y0 = yv(i - 1), y3 = yv(i + 2);
            if (isNaN(y0)) y0 = 2 * y1 - y2;
            if (isNaN(y3)) y3 = 2 * y2 - y1;
            const lo = Math.min(y1, y2), hi = Math.max(y1, y2);
            const c1 = Math.max(lo, Math.min(hi, y1 + (y2 - y0) / 6));
            const c2 = Math.max(lo, Math.min(hi, y2 - (y3 - y1) / 6));
            for (let t = 1; t < S; t++) {
                const u = t / S, mu = 1 - u;
                out[i * S + t] = mu * mu * mu * y1 + 3 * mu * mu * u * c1 + 3 * mu * u * u * c2 + u * u * u * y2;
            }
        }
        return out;
    }
    readonly property var _dense: {
        if (strip._denseCount === 0)
            return null;
        return {
            temp: strip._denseOf("temp"),
            feels: strip._denseOf("feels"),
            dew: strip._denseOf("dew"),
            pressure: strip._denseOf("pressure"),
            vis: strip._denseOf("vis")
        };
    }

    // ---- THE PLACE MORPH -----------------------------------------------------------
    // The picture the morph moves FROM (null at rest): `dense` the centrelines last drawn, `bar` and `hue` per column the
    // bar values and hue codes last drawn per view. `_placeNow` is what the drawing reads each tick: the snapshot and the
    // popup's eased fraction, null when nothing is moving.
    property var _placeFrom: null
    property var _shownDense: null
    // A FUNCTION, not a binding: `_updateW` runs from the clock's own change, and a binding on the clock's fraction may not have
    // been re-evaluated yet (bindings follow in notification order), so it would draw the fraction of the tick before.
    function _placeNow() {
        return strip.popup && strip.popup.placeMorphing && strip._placeFrom ? { from: strip._placeFrom, e: strip.popup.placeE } : null;
    }
    function placeBegin() {
        const cols = strip._cols;
        const bar = new Array(cols.length), hue = new Array(cols.length), dir = new Array(cols.length);
        for (let i = 0; i < cols.length; i++) {
            const pb = strip._placeBars(i, null);
            bar[i] = pb.bar;
            hue[i] = pb.hueFrom && pb.e < 0.5 ? pb.hueFrom : pb.hue;
            dir[i] = strip._windDirOf(i);
        }
        strip._placeFrom = { dense: strip._shownDense, bar: bar, hue: hue, dir: dir };
    }
    // One column's bars as they are drawn now, for every view: `bar` the lengths' values (null, no bar, is none long and a
    // value moves to it), `floor` how much of the bar's minimum height is owed (1 where either picture has a bar, easing as
    // one goes -- a bar shrinking to nothing does not stop at the floor and pop out), `hue` the hue codes of the target and
    // `hueFrom` the old place's, mixed where the bar is drawn. At rest it is the column's own facts.
    function _placeBars(i, w) {
        const c = strip._cols[i];
        const pn = strip._placeNow();
        if (!pn)
            return { bar: c.bar, floor: null, hue: c.hue, hueFrom: null, e: 1 };
        const f = i < pn.from.bar.length ? pn.from : null;
        const n = strip._viewSpec.length;
        const bar = new Array(n), floor = new Array(n);
        for (let v = 0; v < n; v++) {
            const b = c.bar[v];
            const has = b !== null && b > 0 ? 1 : 0;
            if (w && !(w[v] > 0)) {          // a view that weighs nothing draws nothing
                bar[v] = b;
                floor[v] = has;
            } else if (f) {
                const a = f.bar[i][v];
                bar[v] = PB.bar(a, b, pn.e);
                floor[v] = (a !== null && a > 0 ? 1 : 0) * (1 - pn.e) + has * pn.e;
            } else {
                bar[v] = b;
                floor[v] = has;      // a column the old place lacked: it grows from nothing like a new bar
            }
        }
        return { bar: bar, floor: floor, hue: c.hue, hueFrom: f ? f.hue[i] : null, e: pn.e };
    }
    // The wind arrow's direction in column i as it is drawn: it turns the short way from the old place's to the new one's.
    function _windDirOf(i) {
        const c = strip._cols[i];
        const pn = strip._placeNow();
        return pn && i < pn.from.dir.length ? PB.angle(pn.from.dir[i], c.windDir, pn.e) : c.windDir;
    }
    // The centrelines at this tick: the target's, or between the last drawn and the target's. Where one side has no value
    // (a column the data lacks) the line takes the other's at once.
    function _denseDrawn(w) {
        const to = strip._dense;
        const pn = strip._placeNow();
        if (!to || !pn || !pn.from.dense)
            return to;
        const e = pn.e, from = pn.from.dense;
        // Only the series some weighted view draws move (and the feels-like line, every view's); the others are not on screen, so
        // their last drawn state is the target's -- which is also what a later retarget snapshots, and what a view switched to
        // mid-morph moves from.
        const live = { feels: true };
        for (let v = 0; v < w.length; v++) {
            if (w[v] > 0 && strip._viewSpec[v].line !== "")
                live[strip._viewSpec[v].line] = true;
        }
        const out = {};
        for (const key of ["temp", "feels", "dew", "pressure", "vis"]) {
            const a = from[key], b = to[key];
            if (!live[key]) {
                out[key] = b;
                continue;
            }
            const y = new Array(b.length);
            for (let k = 0; k < b.length; k++) {
                const ak = a && k < a.length ? a[k] : NaN;
                y[k] = isNaN(ak) || isNaN(b[k]) ? b[k] : ak * (1 - e) + b[k] * e;
            }
            out[key] = y;
        }
        return out;
    }
    Connections {
        target: strip.popup
        function onPlaceEChanged() {
            if (strip.popup.placeMorphing && strip._placeFrom)
                strip._updateW();
        }
        function onPlaceMorphingChanged() {
            if (strip._placeFrom)
                strip._updateW();
        }
    }

    // ---- The clock ---------------------------------------------------------------
    ViewBlend {
        id: blend
        count: strip._viewSpec.length
        target: strip.viewIndex
        durationMs: strip.viewMs
        onTicked: strip._updateW()
    }
    // ONE FRAME of the drawn state, assigned once per tick so that a delegate
    // reading several of its parts re-evaluates once, not once per part: the
    // weights, the summed weight of each trait (line, feels-like, condition
    // glyph, arrow, any glyph), and the column-centre y of the drawn lines (p, s).
    property var _frame: ({ w: [1, 0, 0, 0, 0, 0, 0, 0, 0], line: 1, feels: 1, cond: 1, arrow: 0, g: 1, p: [], s: [] })
    readonly property var _w: strip._frame.w
    readonly property real _lineAlpha: strip._frame.line
    // The wind arrow shows (its scale is above 0 from half weight): only then does its direction follow the place morph.
    readonly property bool _arrowOn: strip._frame.arrow > 0.5
    readonly property real _feelsW: strip._frame.feels

    // One tick of the blend (or a new model): the weights' sums per trait, the
    // mixed lines, then the frame, then the shapes (which read the frame's sums).
    function _updateW() {
        const n = strip._viewSpec.length;
        const w = blend.weights;
        // A model that lands before the blend's first publish: it ticks then.
        if (w.length !== n)
            return;
        let line = 0, feels = 0, cond = 0, arrow = 0;
        for (let v = 0; v < n; v++) {
            const spec = strip._viewSpec[v];
            if (spec.line !== "")
                line += w[v];
            if (spec.feels)
                feels += w[v];
            if (spec.glyph === 1)
                cond += w[v];
            else if (spec.glyph === 2)
                arrow += w[v];
        }
        const dense = strip._denseDrawn(w);
        strip._shownDense = dense;
        const ys = strip._mixLines(w, line, dense);
        strip._frame = {
            w: w, line: Math.min(1, line), feels: Math.min(1, feels), cond: Math.min(1, cond), arrow: Math.min(1, arrow),
            g: Math.min(1, cond + arrow), p: ys.p, s: ys.s
        };
        strip._updateShadow();
        strip._updatePolys();
    }
    function _at(list, i) {
        return i < list.length ? list[i] : NaN;
    }

    // ---- The maxima of the growing bars, over the VISIBLE columns ------------------
    readonly property var _visMax: {
        const cols = strip._cols;
        const out = { wind: 0, precip: 0, uv: 0, aq: 0 };
        if (cols.length === 0)
            return out;
        const cw = strip.columnWidth;
        const a = Math.max(0, Math.ceil((flick.contentX) / cw - 0.5));
        const b = Math.min(cols.length - 1, Math.floor((flick.contentX + flick.width) / cw - 0.5));
        for (let i = a; i <= b; i++) {
            const bar = cols[i].bar;
            if (bar[1] !== null && bar[1] > out.wind) out.wind = bar[1];
            if (bar[2] !== null && bar[2] > out.precip) out.precip = bar[2];
            if (bar[3] !== null && bar[3] > out.uv) out.uv = bar[3];
            if (bar[8] !== null && bar[8] > out.aq) out.aq = bar[8];
        }
        return out;
    }
    property real _maxWind: Math.max(strip.windMaxBft, strip._visMax.wind)
    property real _maxPrecip: Math.max(strip.precipMaxMm, strip._visMax.precip)
    property real _maxUv: Math.max(strip.uvMax, strip._visMax.uv)
    property real _maxAq: Math.max(strip._belaqi ? strip.aqMaxBelaqi : strip.aqMaxEaqi, strip._visMax.aq)
    Behavior on _maxWind {
        NumberAnimation { duration: strip.maxMs; easing.type: Easing.OutCubic }
    }
    Behavior on _maxPrecip {
        NumberAnimation { duration: strip.maxMs; easing.type: Easing.OutCubic }
    }
    Behavior on _maxUv {
        NumberAnimation { duration: strip.maxMs; easing.type: Easing.OutCubic }
    }
    Behavior on _maxAq {
        NumberAnimation { duration: strip.maxMs; easing.type: Easing.OutCubic }
    }

    function _hue(code) {
        if (code >= 10)
            return Theme.bands[Math.max(0, Math.min(5, code - 10))];
        return code === 1 ? Theme.weatherSnow : (code === 2 ? Theme.weatherCloud : Theme.weatherRain);
    }
    // One column's drawn bar under the weights: { h, width, color }.
    function _barOf(c, i, w, maxWind, maxPrecip, maxUv, maxAq) {
        let h = 0, ws = 0, bw = 0, r = 0, g = 0, b = 0, a = 0;
        const len = strip._trackLen;
        const pb = strip._placeBars(i, w);
        for (let v = 0; v < w.length; v++) {
            const wv = w[v];
            const kind = strip._viewSpec[v].bar;
            if (wv <= 0 || kind === 0)
                continue;
            const val = pb.bar[v];
            const mx = v === 1 ? maxWind : v === 2 ? maxPrecip : v === 3 ? maxUv : v === 8 ? maxAq : 100;
            // A glyph-less view's track is longer by the slot it rose into.
            const full = len + (strip._viewSpec[v].glyph === 0 ? strip._slotLift : 0);
            if (val !== null && val > 0)
                h += wv * Math.max(pb.floor ? strip.barMinPx * pb.floor[v] : strip.barMinPx, Math.min(1, val / mx) * full);
            let col = strip._hue(pb.hue[v]);
            if (pb.hueFrom && pb.hueFrom[v] !== pb.hue[v])
                col = Mix.c(strip._hue(pb.hueFrom[v]), col, pb.e);
            const alpha = kind === 1 ? strip.faintBarAlpha : 1;
            ws += wv;
            bw += wv * (kind === 1 ? strip.faintBarWidth : strip.barWidth);
            r += wv * col.r;
            g += wv * col.g;
            b += wv * col.b;
            a += wv * alpha;
        }
        if (ws <= 0)
            return { h: 0, width: strip.barWidth, color: Qt.rgba(0, 0, 0, 0) };
        return { h: h, width: bw / ws, color: Qt.rgba(r / ws, g / ws, b / ws, a / ws) };
    }
    // A column's texts per view go through blend.textOf (the arriving view's,
    // else the one that weighed most when the switch began: once per switch).
    function _anyView(v) {
        return true;
    }
    function _isLineView(v) {
        return strip._viewSpec[v].line !== "";
    }
    // The figures' boxes (content y of the Text's top), shared by the Texts and
    // by the track that breaks around them. The feels-like point counts for the
    // primary figure by its line's presence. `flip` (LABEL RULES) puts the
    // primary figure below the lower point and the feels-like one above the
    // higher; it holds only while the primary figure is the temperature.
    function _flipOf(c) {
        return c.flip && blend.textView(strip._isLineView, c.line) === 0;
    }
    function _primaryBoxY(yP, yS, feelsW, flip) {
        const a = isNaN(yS) ? yP : yP + feelsW * ((flip ? Math.max(yP, yS) : Math.min(yP, yS)) - yP);
        if (flip)
            return Math.round(isNaN(a) ? strip._pointBottom : a) + strip.figureGap;
        return Math.round(isNaN(a) ? strip._pointTop : a) - strip.figureGap - strip._lineFig;
    }
    function _secondaryBoxY(yP, yS, flip) {
        if (isNaN(yS))
            return 0;
        if (flip)
            return Math.round(isNaN(yP) ? yS : Math.min(yP, yS)) - strip.figureGap - strip._lineSmall;
        return Math.round(isNaN(yP) ? yS : Math.max(yP, yS)) + strip.figureGap;
    }
    // Where a figure's ink sits inside its box: the tight bounds of the digits
    // under a vertically centred single line. The metrics' font is read here,
    // so the binding re-measures when the face changes.
    function _inkOf(fm, boxH) {
        const f = fm.font;
        const r = fm.tightBoundingRect("0123456789°");
        const base = (boxH - fm.height) / 2 + fm.ascent;
        return { top: base + r.y, bottom: base + r.y + r.height };
    }
    readonly property var _figInk: strip._inkOf(fmFig, strip._lineFig)
    readonly property var _smallInk: strip._inkOf(fmSmall, strip._lineSmall)
    // The spans [y0, y1] of one column's figures' ink, grown by trackGap. A
    // span closes about its middle in the first half of its figure's fade (the
    // glyph slot's rule), so a bar under a figure that is leaving is whole
    // again before the figure is half gone rather than dotted all the way out.
    function _inkCuts(c, i, frame) {
        const cuts = [];
        const g = strip.trackGap;
        const yP = strip._at(frame.p, i), yS = strip._at(frame.s, i);
        const lineAlpha = frame.line, feelsW = frame.feels;
        const flip = strip._flipOf(c);
        const add = function (top, bottom, presence) {
            const mid = (top + bottom) / 2, half = (bottom - top) / 2 * Math.max(0, Math.min(1, 2 * presence - 1));
            cuts.push([mid - half, mid + half]);
        };
        if (lineAlpha > 0.01 && !isNaN(yP) && blend.textOf(c.line, strip._isLineView) !== "") {
            const b = strip._primaryBoxY(yP, yS, feelsW, flip);
            add(b + strip._figInk.top - g, b + strip._figInk.bottom + g, lineAlpha);
        }
        if (feelsW > 0.01 && !isNaN(yS) && c.feelsText !== "") {
            const b = strip._secondaryBoxY(yP, yS, flip);
            add(b + strip._smallInk.top - g, b + strip._smallInk.bottom + g, feelsW);
        }
        return cuts;
    }
    // [y0, y1] less the cuts, as exactly three segments ([0, 0] when unused):
    // the track and the bar on it both break around the figures drawn over
    // them. A cut edge is square and only the true ends are round, so a bar
    // reads as one bar passing behind a figure rather than as separate pills;
    // a sliver left between a cut and anything is dropped.
    function _minus(y0, y1, cuts) {
        let segs = y1 > y0 ? [[y0, y1]] : [];
        for (let k = 0; k < cuts.length; k++) {
            const a = cuts[k][0], b = cuts[k][1];
            const next = [];
            for (let j = 0; j < segs.length; j++) {
                const sg = segs[j];
                if (b <= sg[0] || a >= sg[1]) {
                    next.push(sg);
                    continue;
                }
                if (a > sg[0])
                    next.push([sg[0], a]);
                if (b < sg[1])
                    next.push([b, sg[1]]);
            }
            segs = next;
        }
        segs = segs.filter(sg => sg[1] - sg[0] >= strip.segmentMinPx || (sg[0] === y0 && sg[1] === y1));
        while (segs.length < 3)
            segs.push([0, 0]);
        return segs;
    }
    function _presenceOf(list, w) {
        let s = 0;
        for (let v = 0; v < w.length; v++)
            if (list[v] !== "")
                s += w[v];
        return Math.min(1, s);
    }

    // ---- The drawn lines --------------------------------------------------------
    property var _drawnP: null
    property var _drawnS: null
    property var _poolP: []
    property var _poolS: []
    property var _poolShadow: []

    on_DenseChanged: {
        const D = strip._denseCount;
        const mk = function (n) {
            const out = new Array(n);
            for (let i = 0; i < n; i++)
                out[i] = Qt.point(0, 0);
            return out;
        };
        strip._poolP = mk(2 * D);
        strip._poolS = mk(2 * D);
        strip._poolShadow = mk(D + 2 * Math.max(1, D));
        strip._drawnP = null;
        strip._drawnS = null;
        strip._updateW();
    }

    // Mixes the views' centrelines under the weights (normalised over the views
    // that have a line; kept as they were while none weighs anything) and
    // caches the normals. Returns the column-centre y of both lines.
    function _mixLines(w, lw, dense) {
        if (!dense) {
            strip._drawnP = null;
            strip._drawnS = null;
            return { p: [], s: [] };
        }
        const D = strip._denseCount;
        if (lw > 0) {
            const y = new Array(D);
            for (let k = 0; k < D; k++) {
                let s = 0, ws = 0;
                for (let v = 0; v < w.length; v++) {
                    const key = strip._viewSpec[v].line;
                    if (w[v] <= 0 || key === "")
                        continue;
                    const dv = dense[key][k];
                    if (isNaN(dv))
                        continue;
                    s += w[v] * dv;
                    ws += w[v];
                }
                y[k] = ws > 0 ? s / ws : NaN;
            }
            strip._drawnP = strip._withNormals(y);
        }
        // The feels-like line is the same in every view, so it is rebuilt per model, and per tick of a place morph.
        if (!strip._drawnS || strip._placeNow())
            strip._drawnS = strip._withNormals(dense.feels);
        const S = strip.curveSteps, n = strip._cols.length;
        const p = new Array(n), s = new Array(n);
        for (let i = 0; i < n; i++) {
            p[i] = strip._drawnP ? strip._drawnP.y[i * S] : NaN;
            s[i] = strip._drawnS.y[i * S];
        }
        return { p: p, s: s };
    }
    function _withNormals(y) {
        const D = y.length;
        const dx = strip.columnWidth / strip.curveSteps;
        const nx = new Array(D), ny = new Array(D);
        for (let k = 0; k < D; k++) {
            if (isNaN(y[k])) {
                nx[k] = 0;
                ny[k] = 1;
                continue;
            }
            const a = k > 0 && !isNaN(y[k - 1]) ? k - 1 : k;
            const b = k + 1 < D && !isNaN(y[k + 1]) ? k + 1 : k;
            const tx = (b - a) * dx, ty = y[b] - y[a];
            const len = Math.hypot(tx, ty) || 1;
            nx[k] = -ty / len;
            ny[k] = tx / len;
        }
        return { y: y, nx: nx, ny: ny };
    }
    function _updateShadow() {
        const d = strip._drawnP;
        const pool = strip._poolShadow;
        if (!d || pool.length === 0) {
            shadowMulti.paths = [];
            return;
        }
        const D = d.y.length;
        const foot = strip._trackBottom;
        const paths = [];
        let used = 0;
        let k = 0;
        while (k < D) {
            while (k < D && isNaN(d.y[k]))
                k++;
            const a = k;
            while (k < D && !isNaN(d.y[k]))
                k++;
            const b = k - 1;
            if (b <= a)
                continue;
            const start = used;
            for (let j = a; j <= b; j++) {
                pool[used].x = strip._denseX(j);
                pool[used].y = d.y[j];
                used++;
            }
            pool[used].x = strip._denseX(b);
            pool[used].y = foot;
            used++;
            pool[used].x = strip._denseX(a);
            pool[used].y = foot;
            used++;
            paths.push(pool.slice(start, used));
        }
        shadowMulti.paths = paths;
    }
    // Half the line's width at content x, under the taper law in the header.
    function _halfWidthAt(x, full, least) {
        const W = flick.width;
        const Z = Math.max(1, strip.taperHours * strip.columnWidth);
        const s = x - flick.contentX;
        const sm = function (e) {
            const t = Math.max(0, Math.min(1, e / Z));
            return t * t * (3 - 2 * t);
        };
        const k = Math.max(1 - sm(s), 1 - sm(W - s));
        return (full - (full - least) * k) / 2;
    }
    function _ribbon(d, pool, full, least, multi) {
        if (!d || pool.length === 0) {
            multi.paths = [];
            return;
        }
        const D = d.y.length;
        const dx = strip.columnWidth / strip.curveSteps;
        const k0 = Math.max(0, Math.floor((flick.contentX - strip.columnWidth * 1.5) / dx));
        const k1 = Math.min(D - 1, Math.ceil((flick.contentX + flick.width + strip.columnWidth * 0.5) / dx));
        const paths = [];
        let used = 0;
        let k = k0;
        const W = flick.width, cx = flick.contentX, denseX = strip._denseX;
        const Z = Math.max(1, strip.taperHours * strip.columnWidth);
        while (k <= k1) {
            while (k <= k1 && isNaN(d.y[k]))
                k++;
            const a = k;
            while (k <= k1 && !isNaN(d.y[k]))
                k++;
            const b = k - 1;
            if (b <= a)
                continue;
            const start = used;
            const len = b - a + 1;
            for (let j = a; j <= b; j++) {
                const x = denseX(j);
                // _halfWidthAt(x, full, least), in line: this loop runs for every point at every width of a resizing card
                const s = x - cx;
                let t = s / Z;
                t = t > 0 ? (t < 1 ? t : 1) : 0;
                const ka = 1 - t * t * (3 - 2 * t);
                t = (W - s) / Z;
                t = t > 0 ? (t < 1 ? t : 1) : 0;
                const kb = 1 - t * t * (3 - 2 * t);
                const hw = (full - (full - least) * (ka > kb ? ka : kb)) / 2;
                const L = pool[start + (j - a)], R = pool[start + 2 * len - 1 - (j - a)];
                L.x = x + d.nx[j] * hw;
                L.y = d.y[j] + d.ny[j] * hw;
                R.x = x - d.nx[j] * hw;
                R.y = d.y[j] - d.ny[j] * hw;
            }
            used += 2 * len;
            paths.push(pool.slice(start, used));
        }
        multi.paths = paths;
    }
    // Everything a ribbon rebuild reads of the viewport, as ONE binding: a change
    // of either rebuilds in the same change, so the scroll's own frame carries
    // the new ribbons.
    readonly property var _viewport: ({ x: flick.contentX, w: flick.width })
    on_ViewportChanged: strip._updatePolys()
    function _updatePolys() {
        strip._ribbon(strip._lineAlpha > 0 ? strip._drawnP : null, strip._poolP,
                      strip.lineWidth, strip.lineMinWidth, lineMulti);
        strip._ribbon(strip._feelsW > 0 ? strip._drawnS : null, strip._poolS,
                      strip.feelsLineWidth, strip.feelsLineWidth * strip.lineMinWidth / Math.max(0.01, strip.lineWidth), feelsMulti);
        // Synced now rather than in the render loop's polish (the header's TAPER).
        feelsShape.ensurePolished();
        lineShape.ensurePolished();
    }
    // What the Shapes were handed, for a probe: { line, feels } each a list of
    // closed ribbons (left edge forward, right edge back).
    function lineGeometry() {
        return { line: lineMulti.paths, feels: feelsMulti.paths };
    }

    // ---- Keys ---------------------------------------------------------------------
    function keyAt(i) {
        const c = strip._cols[i];
        return c ? { metric: strip.views[strip.viewIndex].metric, dayIndex: c.dayIndex, hourIndex: c.hour, from: "hourly" } : null;
    }
    // The height of column i's bar as it is drawn this frame (a probe's; 0 for none).
    function columnBar(i) {
        const g = groundRep.itemAt(i);
        return g && g.bar ? g.bar.h : 0;
    }
    function columnItem(dayIndex, hourIndex) {
        for (let i = 0; i < strip._cols.length; i++) {
            const c = strip._cols[i];
            if (c.dayIndex === dayIndex && c.hour === hourIndex)
                return colRep.itemAt(i);
        }
        return null;
    }
    // Immediate (a probe, a programmatic move): any glide or coast is dropped.
    function scrollBy(d) {
        dressing.scrollBy(d);
        strip._noteWanted();
    }
    // One axis of the popup's wheel reader (the gesture it latched is this
    // strip's, on x): handed to the dressing's engine, so a notch glides, the
    // fingers follow, and their lift (zero deltas) coasts. The popup's own
    // scrollSpeed is the dressing's.
    function feedWheel(px, ad, phase) {
        dressing.wheel({ pixelDelta: Qt.point(px, 0), angleDelta: Qt.point(ad, 0), phase: phase });
        strip._noteWanted();
    }
    // Back to the first column (a content being recycled for the next open): a glide or a coast stops, the position is the start's.
    function resetScroll() {
        dressing.stopMotion();
        dressing.scrollBy(-1e9);
        strip._noteWanted();
    }
    // Fingers put back, or a host about to move the strip itself.
    function stopMotion() {
        dressing.stopMotion();
    }
    property real scrollSpeed: strip.popup ? strip.popup.scrollSpeed : 1
    // Whether the strip is being moved by its engine, for a probe.
    readonly property bool scrolling: dressing.moving
    function _noteWanted() {
        strip._wantX = flick.contentX;
        strip._wantEnd = flick.contentX >= dressing._max - 0.5;
    }
    // A glide or a coast moves the content on its own clock: the wanted
    // position follows it (a resize's clamp in _placeWanted is not the user).
    Connections {
        target: flick
        function onContentXChanged() {
            if (dressing.moving && !strip._placing)
                strip._noteWanted();
        }
    }
    property bool _placing: false
    // Where the user scrolled to, which a resize never writes: the popup's width
    // eases, so leaving the detailed view hands the strip a width that is too
    // WIDE for its first frames, and clamping the live position there would throw
    // most of it away. A strip scrolled to its end stays at its end.
    property real _wantX: 0
    property bool _wantEnd: false
    function _placeWanted() {
        const max = Math.max(0, flick.contentWidth - flick.width);
        strip._placing = true;
        flick.contentX = strip._wantEnd ? max : Math.max(0, Math.min(strip._wantX, max));
        strip._placing = false;
    }
    // Where the strip is scrolled to, for a probe.
    readonly property real scrollPos: flick.contentX

    ShadowBox {
        id: card
        anchors.fill: parent
        baseRadius: strip._radius
        surfaceColor: Theme.surface
        bevelColor: strip._cardBevelColor
        shadowColor: Theme.border
        backgroundColor: Theme.listBox
        bevelWidth: strip._cardBevel
        shadowWidth: strip._cardShadow
        shadowFalloff: strip._cardFalloff

        Item {
            id: box
            x: strip._pad - strip.edgeReach
            y: strip._pad
            width: strip._innerW + 2 * strip.edgeReach
            height: strip._innerH

            // THE CLIP IS INSET `clipInset` FROM THE FADE'S OUTER EDGE: a
            // Flickable's clip is a scissor rectangle the renderer rounds on the CPU, the dressing's opaque lead a quad the GPU rasterises by
            // pixel centres, and where an edge passes exactly through a row of pixel centres the two can round opposite ways (a 1 px column at
            // scale 1.25, at 1 with the box on x.5). The dressing now seals every band's edge for that (ScrollDressing, THE BAND COVERS WHAT
            // THE CLIP LETS THROUGH); this strip also cuts `clipInset` inside the lead's outer edge, in the room its viewport reaches into the
            // card's padding, so the cut lies under the lead whatever happens at the edge. The Flickable keeps the box's whole
            // size, so its contentX, its width and everything laid out in it are unchanged; only what is SEEN stops a pixel short, in the room
            // the viewport reaches into the card's padding (`edgeReach`), where there is no ink. (`parent: clipHost` below.)
            Item {
                id: clipHost
                x: strip.clipInset
                width: parent.width - 2 * strip.clipInset
                height: parent.height
                clip: true
            }

            Flickable {
                id: flick
                parent: clipHost
                x: -clipHost.x
                width: box.width
                height: box.height
                interactive: false
                contentWidth: Math.max(width, strip._cols.length * strip.columnWidth)
                contentHeight: height
                // Not interactive, so nothing else puts the content back in
                // range when the card resizes: the wanted position, clamped.
                onWidthChanged: strip._placeWanted()
                onContentWidthChanged: strip._placeWanted()
                opacity: strip._hasModel ? 1 : 0
                visible: opacity > 0
                Behavior on opacity {
                    NumberAnimation { duration: strip._fadeMs; easing.type: Easing.OutCubic }
                }

                // THE OPEN COLUMN SINKS: the hover shade carved in with the
                // popup's inset knobs (the daily list's open row does the
                // same). One box for the strip, placed on the open column,
                // under the tracks and the lines.
                ShadowBox {
                    id: selectionGround
                    readonly property int colIndex: {
                        const k = strip._activeKey;
                        if (!k || k.from !== "hourly" || typeof k.hourIndex !== "number")
                            return -1;
                        for (let i = 0; i < strip._cols.length; i++) {
                            const c = strip._cols[i];
                            if (c.dayIndex === k.dayIndex && c.hour === k.hourIndex)
                                return i;
                        }
                        return -1;
                    }
                    visible: selectionGround.colIndex >= 0
                    readonly property real slotX: Math.max(0, selectionGround.colIndex) * strip.columnWidth
                    x: selectionGround.slotX + strip.groundInset
                    y: strip.groundInset
                    width: strip.columnWidth - 2 * strip.groundInset
                    height: strip._contentH - 2 * strip.groundInset
                    baseRadius: 6
                    surfaceColor: "transparent"
                    bevelColor: strip._cardBevelColor
                    shadowColor: Theme.border
                    backgroundColor: Theme.headerBox
                    bevelWidth: strip._insetBevel
                    shadowWidth: strip._insetShadow
                    shadowFalloff: strip._insetFalloff
                }

                // The grounds, tracks and bars first, under the lines.
                Repeater {
                    id: groundRep
                    model: strip._cols.length
                    Item {
                        id: groundCell
                        required property int index
                        x: groundCell.index * strip.columnWidth
                        y: 0
                        width: strip.columnWidth
                        height: strip._contentH
                        readonly property var col: strip._cols[groundCell.index]
                        readonly property bool active: {
                            const k = strip._activeKey;
                            return !!k && k.from === "hourly" && typeof k.hourIndex === "number"
                                && !!groundCell.col && k.dayIndex === groundCell.col.dayIndex && k.hourIndex === groundCell.col.hour;
                        }
                        // One hovered column, held on the strip: `itemAt()` in
                        // a binding would capture nothing and keep its first answer.
                        property real hoverF: strip._hoverIndex === groundCell.index ? 1 : 0
                        Behavior on hoverF {
                            NumberAnimation { duration: strip.hoverMs; easing.type: Easing.OutCubic }
                        }
                        readonly property var bar: groundCell.col
                            ? strip._barOf(groundCell.col, groundCell.index, strip._frame.w, strip._maxWind, strip._maxPrecip, strip._maxUv, strip._maxAq)
                            : null
                        Rectangle {
                            x: strip.groundInset
                            y: strip.groundInset
                            width: parent.width - 2 * strip.groundInset
                            height: parent.height - 2 * strip.groundInset
                            radius: 6
                            color: Theme.panelSunk
                            opacity: groundCell.active ? 0 : groundCell.hoverF * strip.hoverGroundAlpha
                            visible: opacity > 0.001
                        }
                        Rectangle {
                            visible: groundCell.col ? groundCell.col.midnight : false
                            x: 0
                            y: 0
                            width: 1
                            height: parent.height
                            color: Theme.border
                        }
                        // The hour's track and the bar on it, both broken
                        // around the figures drawn over them.
                        readonly property var cuts: groundCell.col
                            ? strip._inkCuts(groundCell.col, groundCell.index, strip._frame)
                            : []
                        readonly property var trackSegs: strip._minus(strip._trackTopNow, strip._trackBottom, groundCell.cuts)
                        readonly property var barSegs: groundCell.bar && groundCell.bar.h > 0.25
                            ? strip._minus(strip._trackBottom - groundCell.bar.h, strip._trackBottom, groundCell.cuts)
                            : [[0, 0], [0, 0], [0, 0]]
                        Repeater {
                            model: 3
                            Rectangle {
                                id: seg
                                required property int index
                                readonly property var span: groundCell.trackSegs[seg.index]
                                objectName: "track"
                                x: (groundCell.width - width) / 2
                                y: seg.span[0]
                                width: strip.trackWidth
                                height: Math.max(0, seg.span[1] - seg.span[0])
                                radius: Math.min(width, height) / 2
                                topLeftRadius: seg.span[0] <= strip._trackTopNow ? seg.radius : 0
                                topRightRadius: seg.span[0] <= strip._trackTopNow ? seg.radius : 0
                                bottomLeftRadius: seg.span[1] >= strip._trackBottom ? seg.radius : 0
                                bottomRightRadius: seg.span[1] >= strip._trackBottom ? seg.radius : 0
                                visible: height > 0.5
                                color: strip._trackColor
                            }
                        }
                        Repeater {
                            model: 3
                            Rectangle {
                                id: barSeg
                                required property int index
                                readonly property var span: groundCell.barSegs[barSeg.index]
                                objectName: "bar"
                                width: groundCell.bar ? groundCell.bar.width : strip.barWidth
                                x: (groundCell.width - width) / 2
                                y: barSeg.span[0]
                                height: Math.max(0, barSeg.span[1] - barSeg.span[0])
                                radius: Math.min(width, height) / 2
                                topLeftRadius: groundCell.bar && barSeg.span[0] <= strip._trackBottom - groundCell.bar.h ? barSeg.radius : 0
                                topRightRadius: groundCell.bar && barSeg.span[0] <= strip._trackBottom - groundCell.bar.h ? barSeg.radius : 0
                                bottomLeftRadius: barSeg.span[1] >= strip._trackBottom ? barSeg.radius : 0
                                bottomRightRadius: barSeg.span[1] >= strip._trackBottom ? barSeg.radius : 0
                                visible: height > 0.25
                                color: groundCell.bar ? groundCell.bar.color : "transparent"
                            }
                        }
                    }
                }

                // The shadow under the primary line, then the feels-like line,
                // then the primary line itself.
                Shape {
                    x: 0
                    y: 0
                    width: flick.contentWidth
                    height: strip._contentH
                    preferredRendererType: Shape.CurveRenderer
                    opacity: strip._lineAlpha
                    visible: opacity > 0.001 && strip.shadowAlpha > 0
                    ShapePath {
                        strokeColor: "transparent"
                        strokeWidth: 0
                        fillGradient: LinearGradient {
                            x1: 0
                            y1: strip._pointTop
                            x2: 0
                            y2: strip._trackBottom
                            GradientStop { position: 0; color: Qt.rgba(Theme.shadowDeep.r, Theme.shadowDeep.g, Theme.shadowDeep.b, strip.shadowAlpha) }
                            GradientStop { position: 1; color: Qt.rgba(Theme.shadowDeep.r, Theme.shadowDeep.g, Theme.shadowDeep.b, 0) }
                        }
                        PathMultiline {
                            id: shadowMulti
                        }
                    }
                }
                Shape {
                    id: feelsShape
                    x: 0
                    y: 0
                    width: flick.contentWidth
                    height: strip._contentH
                    preferredRendererType: Shape.CurveRenderer
                    opacity: strip._feelsW * strip.feelsAlpha
                    visible: opacity > 0.001
                    ShapePath {
                        strokeColor: "transparent"
                        strokeWidth: 0
                        fillRule: ShapePath.WindingFill
                        fillGradient: LinearGradient {
                            x1: 0
                            y1: strip._pointTop
                            x2: 0
                            y2: strip._pointBottom
                            GradientStop { position: 0; color: Theme.weatherSun }
                            GradientStop { position: 1; color: Theme.weatherRain }
                        }
                        PathMultiline {
                            id: feelsMulti
                        }
                    }
                }
                Shape {
                    id: lineShape
                    x: 0
                    y: 0
                    width: flick.contentWidth
                    height: strip._contentH
                    preferredRendererType: Shape.CurveRenderer
                    opacity: strip._lineAlpha
                    visible: opacity > 0.001
                    ShapePath {
                        strokeColor: "transparent"
                        strokeWidth: 0
                        fillRule: ShapePath.WindingFill
                        fillGradient: LinearGradient {
                            x1: 0
                            y1: strip._pointTop
                            x2: 0
                            y2: strip._pointBottom
                            GradientStop { position: 0; color: Theme.weatherSun }
                            GradientStop { position: 1; color: Theme.weatherRain }
                        }
                        PathMultiline {
                            id: lineMulti
                        }
                    }
                }

                // The columns.
                Repeater {
                    id: colRep
                    model: strip._cols.length
                    Item {
                        id: cell
                        required property int index
                        x: cell.index * strip.columnWidth
                        y: 0
                        width: strip.columnWidth
                        height: strip._contentH
                        readonly property var col: strip._cols[cell.index]
                        readonly property var key: ({
                            metric: strip.views[strip.viewIndex].metric,
                            dayIndex: cell.col ? cell.col.dayIndex : 0,
                            hourIndex: cell.col ? cell.col.hour : 0,
                            from: "hourly"
                        })

                        Text {
                            x: 0
                            y: strip._labelY
                            width: parent.width
                            height: strip._lineLabel
                            text: cell.col ? cell.col.label : ""
                            color: cell.col && cell.col.midnight ? Theme.textPrimary : Theme.textMuted
                            font.family: strip._font
                            font.pixelSize: strip.labelSize
                            font.bold: cell.col ? cell.col.midnight : false
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        // The glyph slot: the condition, or the wind's arrow;
                        // the leaving one shrinks away before the arriving one grows.
                        WeatherGlyph {
                            id: condGlyph
                            posing: strip.glyphFlourish.on(cell.index)
                            poseBeat: strip.glyphFlourish.beatOf(cell.index)
                            x: (parent.width - width) / 2
                            y: strip._glyphY
                            size: strip.glyphSize
                            scale: Math.max(0, 2 * strip._frame.cond - 1)
                            visible: scale > 0.01 && (cell.col ? cell.col.kind !== null : false)
                            kind: cell.col && cell.col.kind ? cell.col.kind : "clear"
                            intensity: cell.col ? cell.col.intensity : 1
                            night: cell.col ? cell.col.night : false
                            shower: cell.col ? cell.col.shower : false
                            moonPhase: cell.col ? cell.col.moonPhase : 0.5
                            style: strip._gs
                        }
                        WeatherGlyph {
                            id: arrowGlyph
                            posing: strip.glyphFlourish.on(cell.index)
                            poseBeat: strip.glyphFlourish.beatOf(cell.index)
                            x: (parent.width - width) / 2
                            y: strip._glyphY
                            size: strip.glyphSize
                            scale: Math.max(0, 2 * strip._frame.arrow - 1)
                            visible: scale > 0.01
                            kind: "arrow"
                            direction: cell.col ? (strip._arrowOn ? strip._windDirOf(cell.index) : cell.col.windDir) : null
                            style: strip._gs
                        }
                        // Whether this column's figures take the swapped sides.
                        readonly property bool flip: cell.col ? strip._flipOf(cell.col) : false
                        // The line's figure: its bottom figureGap above the
                        // higher of the column's two points (the feels-like
                        // point counts by its line's presence); flipped, its
                        // top figureGap below the lower.
                        Text {
                            objectName: "colText:primary:" + cell.index
                            x: 0
                            width: parent.width
                            height: strip._lineFig
                            y: strip._primaryBoxY(strip._at(strip._frame.p, cell.index), strip._at(strip._frame.s, cell.index), strip._frame.feels, cell.flip)
                            text: cell.col ? blend.textOf(cell.col.line, strip._isLineView) : ""
                            opacity: strip._frame.line
                            visible: opacity > 0.01 && !isNaN(strip._at(strip._frame.p, cell.index)) && text !== ""
                            color: Theme.textPrimary
                            font.family: strip._font
                            font.pixelSize: strip.figureSize
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        // The feels-like figure: its top figureGap below the
                        // lower of the two points; flipped, its bottom
                        // figureGap above the higher.
                        Text {
                            objectName: "colText:secondary:" + cell.index
                            x: 0
                            width: parent.width
                            height: strip._lineSmall
                            y: strip._secondaryBoxY(strip._at(strip._frame.p, cell.index), strip._at(strip._frame.s, cell.index), cell.flip)
                            text: cell.col ? cell.col.feelsText : ""
                            opacity: strip._frame.feels
                            visible: opacity > 0.01 && !isNaN(strip._at(strip._frame.s, cell.index)) && text !== ""
                            color: Theme.textFaint
                            font.family: strip._font
                            font.pixelSize: strip.smallSize
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        Text {
                            objectName: "colText:value:" + cell.index
                            x: 0
                            y: strip._valueY
                            width: parent.width
                            height: strip._lineSmall
                            text: cell.col ? blend.textOf(cell.col.value, strip._anyView) : ""
                            opacity: cell.col ? strip._presenceOf(cell.col.value, strip._frame.w) : 0
                            visible: opacity > 0.01 && text !== ""
                            color: Theme.textMuted
                            font.family: strip._font
                            font.pixelSize: strip.smallSize
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        MouseArea {
                            id: cellArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            function flourish(): void {
                                strip.glyphFlourish.play(cell.index, Math.max(condGlyph.visible ? condGlyph.flourishBeats : 0,
                                                                              arrowGlyph.visible ? arrowGlyph.flourishBeats : 0));
                            }
                            onContainsMouseChanged: {
                                strip.glyphFlourish.entered(cellArea);
                                if (cellArea.containsMouse)
                                    strip._hoverIndex = cell.index;
                                else if (strip._hoverIndex === cell.index)
                                    strip._hoverIndex = -1;
                            }
                            onPositionChanged: if (strip.glyphFlourish.hovered(cellArea)) cellArea.flourish()
                            onClicked: {
                                cellArea.flourish();
                                if (strip.popup)
                                    strip.popup.openDetail(cell.key, cell.mapToItem(strip.popup, cell.width / 2, cell.height / 2));
                            }
                        }
                    }
                }
            }

            ScrollDressing {
                id: dressing
                anchors.fill: parent
                flick: flick
                orientation: Qt.Horizontal
                wheelEnabled: false
                scrollSpeed: strip.scrollSpeed
                ground: Theme.listBox
                fadeHeight: strip.fadeHeight
                fadeLead: strip.edgeReach
                visible: strip._hasModel
            }

            // ---- The silhouette ---------------------------------------------------
            Item {
                id: skeleton
                anchors.fill: parent
                opacity: strip._hasModel ? 0 : 1
                visible: opacity > 0
                Behavior on opacity {
                    NumberAnimation { duration: strip._fadeMs; easing.type: Easing.OutCubic }
                }
                readonly property bool pulse: strip.popup ? strip.popup.skeletonPulse : true
                Repeater {
                    model: strip.skeletonColumns
                    Item {
                        id: skCell
                        required property int index
                        x: skCell.index * strip.columnWidth
                        y: 0
                        width: strip.columnWidth
                        height: strip._contentH
                        readonly property int phase: skCell.index * 70
                        SkeletonBar {
                            x: (parent.width - width) / 2
                            y: strip._labelY + (strip._lineLabel - height) / 2
                            width: 16
                            height: 7
                            pulse: skeleton.pulse
                            pulseTravel: 2
                            pulsePhaseMs: skCell.phase
                            barColor: Theme.headerBox
                            groundColor: Theme.listBox
                        }
                        SkeletonBar {
                            x: (parent.width - width) / 2
                            y: strip._glyphY
                            width: strip.glyphSize
                            height: strip.glyphSize
                            radius: strip.glyphSize / 2
                            pulse: skeleton.pulse
                            pulseTravel: 2
                            pulsePhaseMs: skCell.phase
                            barColor: Theme.headerBox
                            groundColor: Theme.listBox
                        }
                        SkeletonBar {
                            x: (parent.width - width) / 2
                            y: strip._trackTop
                            width: strip.trackWidth
                            height: strip._trackLen
                            radius: strip.trackWidth / 2
                            pulse: false
                            barColor: Theme.headerBox
                            groundColor: Theme.listBox
                        }
                        SkeletonBar {
                            x: (parent.width - width) / 2
                            y: strip._pointTop + strip.curveHeight * (0.5 + 0.3 * Math.sin(skCell.index * 1.1)) - strip.figureGap - strip._lineFig + (strip._lineFig - height) / 2
                            width: 20
                            height: 7
                            pulse: skeleton.pulse
                            pulseTravel: 2
                            pulsePhaseMs: skCell.phase
                            barColor: Theme.headerBox
                            groundColor: Theme.listBox
                        }
                        SkeletonBar {
                            x: (parent.width - width) / 2
                            y: strip._valueY + (strip._lineSmall - height) / 2
                            width: 18
                            height: 6
                            pulse: skeleton.pulse
                            pulseTravel: 2
                            pulsePhaseMs: skCell.phase
                            barColor: Theme.headerBox
                            groundColor: Theme.listBox
                        }
                    }
                }
            }
        }

        CardViewCycler {
            id: cycler
            anchors.fill: parent
            currentIndex: strip.startView
            views: strip.views
            orientation: "vertical"
            padding: strip._pad
            radius: strip._radius
            fontFamily: strip._font
            bevelWidth: strip._insetBevel
            shadowWidth: strip._insetShadow
            shadowFalloff: strip._insetFalloff
            bevelColor: strip._cardBevelColor
        }
    }
}
