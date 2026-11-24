pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/components/Mix.js" as Mix
import "data/WeatherModel.js" as WM
import "data/PlaceBlend.js" as PB
import "data/WeatherScales.js" as Scales

// =============================================================================
// WeatherDailyList.qml -- sixteen days, seven visible, the rest on the wheel;
// seven views of them, cycled sideways.
//
// Hosted by WeatherPopup, which hands it `popup` (the model, the formatter,
// the face, the padding, the radius, the glyph carve, the card and groove
// carve, the fade, the wheel gate) and routes the sideways wheel here
// (`cycleBy` / `endCycle`). A carved card with a vertical Flickable (not
// interactive; ScrollDressing is its one wheel reader) and a CardViewCycler
// over it (dots along the bottom padding). One 48 px row per day.
//
// ---- THE VIEWS ----------------------------------------------------------------
//
//   i  id             overlay label   detail metric   what a row shows
//   0  conditions     Conditions      temperature     day glyph, min, range, max, night glyph; precip pair; PoP
//   1  feelsLike      Feels like      feelsLike       the same, the range and figures the feels-like ones
//   2  wind           Wind            wind            day arrow, speed pair (day left, night right), night arrow
//   3  precipitation  Precipitation   precipitation   day glyph, mm pair, night glyph
//   4  sunshine       Sunshine        sunMoon         day glyph, hours bar (13 h natural peak), hours
//   5  uv             UV index        uv              UV bar (8 natural peak, WHO band colour), index
//   6  airQuality     Air quality     airQuality      one bar per value: index, PM2.5, PM10, O3, NO2
//                                                     (`aqCount` of index, PM2.5, PM10, O3, NO2, SO2, CO)
//
// ---- THE LAYOUT (row coordinates; cx0 = after the weekday column, cx1 = row end) --
//
// Every element sits in ONE left-to-right order, the same for every view:
//
//   aDay  gDay(L)  pair  gDay(R)  min  hull  aq1..aq6  max  gNight  tail  aNight
//
// A view names the elements it shows, each with a width (or GROW, the one that
// takes what is left) and the gap in front of it; an element it does not show
// has width 0 AT THE POINT WHERE IT WOULD BE in that order. So between any two
// views an element either MOVES (present in both), or SHRINKS INTO / GROWS OUT
// OF the place its neighbours leave for it -- which is the push and pull.
//
//   element  conditions, feelsLike   wind            precipitation    sunshine       uv            airQuality
//   aDay     0 @cx0                  arrow @cx0      0                0              0             0
//   gDay     glyph, right of pair    0               glyph @cx0 (L)   glyph @cx0     0             0
//   pair     2(val+3+18)+2 @cx0      GROW, gap 6     GROW, gap 6      0              0             0
//   min      temp slot, gap 4        0               0                0              0             0
//   hull     GROW, gap 6             0               0                GROW, gap 10   GROW @cx0     segment 0 (index)
//   aq1..6   0 past the hull         0               0                0 past hull    0 past hull   segments, gap 10
//   max      temp slot, gap 6        0               0                0              0             0
//   gNight   glyph, gap 4            0               glyph, gap 6     0              0             0
//   tail     PoP %, gap 10           0               0                hours, gap 6   index, gap 6  0
//   aNight   0 @cx1                  arrow, gap 6    0                0              0             0
//
// "0 past the hull": segment 0 of the air-quality view IS the hull (its figure
// rides the hull's end in every view), and the others start as points past the
// hull's end, one figure slot apart, so a switch to that view breaks the bar
// into pieces that come out of its end in order without crossing a figure.
// The day glyph is the one element that changes side of the pair (right of
// it in conditions, left of it in precipitation); it dips in scale while it
// crosses (`crossDip`), so it hops over the pair rather than sliding through
// its figures.
//
// Inside the elements, per row: the pair's two bars grow out of its centre
// (day left, night right, night fainter) and its figures are ATTACHED to the
// bars' outer ends; the flank glyphs and arrows are not (they sit at the
// pair's ends whatever the bars do). The hull is a carved groove; in the
// temperature views its raised segment spans min..max on the scale of all
// sixteen days' temperatures AND feels-likes (so the feels-like view is the
// same segment sliding), with the PoP as a faint fill anchored at the hull's
// right end under it -- neither fill nor figure under the popup's
// `probLabelMin`, the strip's rule. In sunshine / UV / air quality the same
// segment is the fill, anchored at the right end, recoloured.
//
// ---- MOTION -------------------------------------------------------------------
//
// ONE clock (`blend`, a ViewBlend over `transitionMs`, OutCubic) blends a
// weight per view. Every x / width / presence / bar length / colour in every
// row is the weighted sum of that quantity in each view (`blend.mix`,
// `blend.mixColor`), so a retarget mid-flight snapshots the drawn state and
// nothing jumps. Texts swap instantly to the target's (an element absent from
// the target keeps the text of the view that weighed most when the switch
// began, `blend.textView`), and a figure's opacity is its presence SQUARED -- on the same
// clock, figures leave before and arrive after the shapes around them, so a
// switch never shows two sets of figures through each other. The maxima
// (precipitation halves, wind, sunshine, UV, air quality)
// are taken over the rows in the viewport and eased 260 ms.
//
// Rows are facts built once per model, for every view at once (no colours);
// the Repeater takes the count. Nothing is created, destroyed or layered on a
// view change. Seven silhouette rows stand in until the first model.
//
// Today's row and the open row stand on Theme.headerBox, a hovered row on a
// wash of panelSunk. Everything carved INSIDE a row is ground-independent:
// the grooves' fill, inset and bevel are Mix.carve's translucent shades
// (`_carveFill`, `_carveShadow`, `_carveBevel`), equal to the opaque colours
// over listBox and the same relative depth over any other ground. A row is
// the link to its day's detail in the current view's metric
// ({ metric, dayIndex, hourIndex: null, from: "daily" }).
// =============================================================================
Item {
    id: list

    property var popup: null

    // ---- Knobs ---------------------------------------------------------------
    property real rowHeight: 48
    property int visibleRows: 7
    // How far a row's ground sits in from the card's padding at the sides (and,
    // through _rowTop, at the top and the foot). 0: today's shaded row starts
    // on the padding line, 12 px from the card's edge on every side, where the
    // hourly strip's first ink and the tiles' text start too -- one perceived
    // margin, one number at the sides, the top and the foot.
    property real rowInset: 0
    // How far a row's ground (today's shade, the hover wash, the open row)
    // sits inside the row's own slot at the top and at the bottom: two rows
    // then keep 2 * rowGroundGap between their grounds.
    property real rowGroundGap: 2
    property real rowRadius: 8
    property real rowPadH: 8
    property real glyphSize: 24
    property real arrowSize: 22
    property real glyphGap: 4
    property real flankGap: 6
    property int weekdaySize: 12
    property int dateSize: 11
    property int figureSize: 12
    property int smallSize: 11
    property int labelSize: 10
    property real colGap: 10
    property real figureGap: 6
    property real grooveHeight: 6
    property real segmentHeight: 8
    // The narrowest a raised segment or fill gets: 12, 1.5 x the 8 px
    // segment's height (the pair's ratio) -- a day with no range, or a small
    // sunshine / UV / air-quality value, is a horizontal pill, never a dot or
    // an upright tick.
    property real segmentMinWidth: 12
    property real pairBarLength: 18
    property real pairBarHeight: 4
    property real pairCenterGap: 2
    property real valueGap: 3
    // The shortest bar a non-zero value gets: 6, 1.5 x the 4 px bar's height,
    // so a trace is a horizontal pill growing out of the centre, never a tick
    // or a dot.
    property real barMinPx: 6
    property real nightBarAlpha: 0.45
    property real popAlpha: 0.16
    property real crossDip: 0.6
    property real aqSegmentGap: 10
    property int aqCount: 5
    // Natural maxima; a visible row above one stretches its scale.
    // precipHalfMax: 5 mm fills a half-day's bar. On the 18 px pair that is
    // 3.6 px per mm -- 2.3 mm draws 8 px, 3.8 mm 14 -- so the common wet
    // Belgian half-day (1-5 mm) reads as length, and a wetter one stretches.
    property real precipHalfMax: 5
    property real windMaxBft: 10
    property real sunshineMaxHours: 13
    property real uvMax: 8
    property int transitionMs: 260
    property int maxEaseMs: 260
    property real hoverGroundAlpha: 0.6
    property int hoverMs: 120
    property real fadeHeight: 34
    property int skeletonRows: 7

    // ---- The views (§1.6) ----------------------------------------------------
    readonly property var views: [
        { id: "conditions", label: "Conditions", metric: "temperature" },
        { id: "feelsLike", label: "Feels like", metric: "feelsLike" },
        { id: "wind", label: "Wind", metric: "wind" },
        { id: "precipitation", label: "Precipitation", metric: "precipitation" },
        { id: "sunshine", label: "Sunshine", metric: "sunMoon" },
        { id: "uv", label: "UV index", metric: "uv" },
        { id: "airQuality", label: "Air quality", metric: "airQuality" }
    ]
    // What each view puts in the pair, the hull's fill and the tail.
    readonly property var _kinds: [
        { pair: "precip", fill: "temp", tail: "pop" },
        { pair: "precip", fill: "feels", tail: "pop" },
        { pair: "wind", fill: "", tail: "" },
        { pair: "precip", fill: "", tail: "" },
        { pair: "", fill: "sun", tail: "sun" },
        { pair: "", fill: "uv", tail: "uv" },
        { pair: "", fill: "aq", tail: "" }
    ]
    // The view the card OPENS on, for a host that remembers it across the popup's life (the
    // engine destroys the content on close). A binding on the cycler's index until the first
    // jump, so the card is built on it at rest -- no transition from view 0.
    property int startView: 0
    // The cycler writes the index (wheel, dot); set a view with cycler.select(i).
    readonly property int viewIndex: cycler.currentIndex
    readonly property string viewId: list.views[list.viewIndex] ? list.views[list.viewIndex].id : ""
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
    readonly property var _model: list.popup ? list.popup.model : null
    readonly property var _F: list.popup ? list.popup.fmt : WM.format({})
    readonly property string _font: list.popup ? list.popup.fontFamily : "Inter"
    readonly property var _gs: list.popup ? list.popup.glyphStyle : ({})
    // A row's glyphs flourish when the pointer comes onto the row or clicks it (day and night, or the two wind arrows where those
    // are on show), each to its end: one clock for the list, a run per row.
    readonly property WeatherGlyphFlourish glyphFlourish: WeatherGlyphFlourish {
        host: list
        beatMs: list.popup ? list.popup.glyphFlourishMs : 900
    }
    readonly property real _pad: list.popup ? list.popup.cardPadding : 12
    readonly property real _radius: list.popup ? list.popup.radius : 14
    readonly property int _fadeMs: list.popup ? list.popup.fadeMs : 160
    readonly property var _activeKey: list.popup ? list.popup.activeKey : null
    readonly property real _probMin: list.popup ? list.popup.probLabelMin : 10
    // The carve: the popup's knobs, with its defaults when there is no popup.
    readonly property real _cardBevel: list.popup ? list.popup.cardBevelWidth : 1
    readonly property real _cardShadow: list.popup ? list.popup.cardShadowWidth : 3
    readonly property real _cardFalloff: list.popup ? list.popup.cardShadowFalloff : 1
    readonly property color _cardBevelColor: list.popup ? list.popup.cardBevelColor : Theme.bevel
    readonly property real _grooveBevel: list.popup ? list.popup.grooveBevelWidth : 1
    readonly property real _grooveShadow: list.popup ? list.popup.grooveShadowWidth : 1.5
    readonly property real _insetBevel: list.popup ? list.popup.insetBevelWidth : 1
    readonly property real _insetShadow: list.popup ? list.popup.insetShadowWidth : 3
    readonly property real _insetFalloff: list.popup ? list.popup.insetShadowFalloff : 1
    readonly property bool _hasModel: list._rows.length > 0
    readonly property real _innerW: list.width - 2 * list._pad
    readonly property real _innerH: list.height - 2 * list._pad
    readonly property real _rowW: list._innerW - 2 * list.rowInset
    // A carved ground's bevel lies OUTSIDE its rect, so a viewport clipped on the
    // padding line would shear the open row's bevel there. The viewport reaches
    // this far into the padding on every side instead; the scroll fades' opaque
    // lead covers it, so a scrolled row still fades out on the padding line.
    readonly property real _slack: 2
    readonly property real _rowX: list._slack + list.rowInset
    property int _hoverIndex: -1

    implicitWidth: 480
    // THE ROWS' OWN PADDING. A row's ground sits `rowInset` in from the card's
    // padding line at its sides; the list starts and ends `_rowTop` into the
    // viewport (which begins `_slack` outside that line), so the first and last
    // grounds sit exactly `rowInset` from the padding line too (not 2 px down
    // against 6 px in at the sides).
    readonly property real _rowTop: Math.max(0, list._slack + list.rowInset - list.rowGroundGap)
    implicitHeight: 2 * (list._pad - list._slack) + 2 * list._rowTop + list.visibleRows * list.rowHeight

    // ---- Ground-independent carve ------------------------------------------------
    // The grooves inside a row take Mix.carve's translucent shades: over listBox
    // (the card) they ARE panelSunk / border / bevel, and over headerBox or a
    // hover wash they keep the same relative depth instead of turning into a
    // light pill on a darker row.
    readonly property color _carveFill: Mix.carve(Theme.listBox, Theme.panelSunk, Theme.shadowDeep)
    readonly property color _carveShadow: Mix.carve(Theme.listBox, Theme.border, Theme.shadowDeep)
    readonly property color _carveBevel: Mix.carve(Theme.listBox, Theme.bevel, Theme.buttonBevel)

    // ---- Metrics ----------------------------------------------------------------
    FontMetrics {
        id: fmWeek
        font.family: list._font
        font.pixelSize: list.weekdaySize
        font.bold: true
    }
    FontMetrics {
        id: fmDate
        font.family: list._font
        font.pixelSize: list.dateSize
    }
    FontMetrics {
        id: fmFig
        font.family: list._font
        font.pixelSize: list.figureSize
    }
    FontMetrics {
        id: fmSmall
        font.family: list._font
        font.pixelSize: list.smallSize
    }
    FontMetrics {
        id: fmLabel
        font.family: list._font
        font.pixelSize: list.labelSize
    }
    function _w(fm, t) {
        const f = fm.font;
        return t.length > 0 ? Math.ceil(fm.advanceWidth(t)) : 0;
    }
    readonly property string _wide: {
        const f = fmFig.font;
        let best = "0", bw = 0;
        for (const d of "0123456789") {
            const w = fmFig.advanceWidth(d);
            if (w > bw) { bw = w; best = d; }
        }
        return best;
    }
    readonly property real _lineWeek: Math.ceil(fmWeek.height)
    readonly property real _lineDate: Math.ceil(fmDate.height)
    readonly property real _lineFig: Math.ceil(fmFig.height)
    readonly property real _lineSmall: Math.ceil(fmSmall.height)
    readonly property real _lineLabel: Math.ceil(fmLabel.height)
    // The slots.
    readonly property real _dayColW: {
        let w = list._w(fmDate, list._wide + list._wide + "/" + list._wide + list._wide);
        for (const d of ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
            w = Math.max(w, list._w(fmWeek, d));
        return w;
    }
    readonly property real _tempSlot: list._w(fmFig, "-" + list._wide + list._wide + "°")
    readonly property real _mmSlot: list._w(fmSmall, list._wide + list._wide + "." + list._wide)
    readonly property real _windSlot: {
        const W = list._wide;
        if (list._F.units.wind === "speed")
            return Math.max(list._w(fmSmall, W + W + W + " " + list._F.speedUnit()),
                            list._w(fmSmall, W + W + "." + W + " " + list._F.speedUnit()));
        return list._w(fmSmall, W + W + " Bft");
    }
    readonly property real _popSlot: list._w(fmFig, list._wide + list._wide + list._wide + " %")
    readonly property real _hrSlot: list._w(fmFig, list._wide + list._wide + "h" + list._wide + list._wide)
    readonly property real _uvSlot: list._w(fmFig, list._wide + list._wide)
    readonly property real _aqValSlot: Math.max(list._w(fmSmall, list._wide + list._wide + list._wide),
                                                list._w(fmSmall, list._wide + "." + list._wide + list._wide))
    // Vertical: the weekday line and the date line of the day column; the
    // air-quality labels sit on the first and their bars on the second.
    readonly property real _textY: Math.round((list.rowHeight - (list._lineWeek + list._lineDate)) / 2)
    readonly property real _labelCy: list._textY + list._lineWeek / 2
    readonly property real _barCy: list._textY + list._lineWeek + list._lineDate / 2
    readonly property real _cx0: list.rowPadH + list._dayColW + list.colGap

    // ---- The facts ---------------------------------------------------------------
    readonly property var _aqIds: ["index", "pm25", "pm10", "o3", "no2", "so2", "co"]
    readonly property var _aqLabels: ["AQI", "PM2.5", "PM10", "O3", "NO2", "SO2", "CO"]
    // Where a value sits on its scale's bands, 0 at the bottom of the first,
    // 1 at the bottom of the last ("extremely poor" / "horrible"); linear
    // inside each band, and past 1 in the last at the previous band's width.
    // Every pollutant and both indices share this axis, so equal bar lengths
    // mean equal bands and the colour and the length never disagree.
    function _bandPos(id, v) {
        if (typeof v !== "number" || !isFinite(v))
            return null;
        const bands = Scales.bands(id);
        const n = bands.length;
        if (n < 2)
            return null;
        let lo = id === "belaqi" ? 1 : 0;
        let prevW = 1;
        for (let i = 0; i < n; i++) {
            const hi = bands[i].hi;
            if (hi === Infinity)
                return (i + Math.max(0, v - lo) / prevW) / (n - 1);
            if (v < hi)
                return (i + Math.max(0, v - lo) / (hi - lo)) / (n - 1);
            prevW = hi - lo;
            lo = hi;
        }
        return 1;
    }
    function _num(v) {
        return typeof v === "number" && isFinite(v) ? v : null;
    }
    // Continuous Beaufort from km/h (v = 3.01 B^1.5), so a bar does not step.
    function _bftOf(kmh) {
        return kmh === null ? null : Math.pow(Math.max(0, kmh) / 3.0096, 2 / 3);
    }
    // The last day, cut short by the model's horizon, is not a row (model.dailyShown). A host that wants every day says false.
    property bool cullIncomplete: true
    readonly property var _rowsBuilt: {
        // The formatter is read BEFORE the model, and that order is load-bearing:
        // the service's `config` is an object literal Qt finalizes lazily, so the
        // first binding to read it fires the service's onConfigChanged -> rebuild
        // -> model assignment; a builder that had already captured the model would
        // be re-entered mid-evaluation (a binding loop; WeatherTiles has the measurement).
        const F = list._F;
        const m = list._model;
        if (!m || !m.daily || m.daily.length === 0)
            return [];
        const aqScale = m.aqIndex === "belaqi" ? "belaqi" : "eaqi";
        const out = [];
        // THE LAST DAY IS LEFT OUT while the model's horizon cuts it short (feedback/weather.md "No displaying
        // incomplete days": a row at the foot whose detail shows "a handful of hours"). Trailing days only, so a row's
        // index stays its day's index; the detail's own day chips still show it (a secondary may show a partial day).
        const n = list.cullIncomplete && typeof m.dailyShown === "number" ? Math.min(m.daily.length, m.dailyShown) : m.daily.length;
        for (let i = 0; i < n; i++) {
            const d = m.daily[i];
            const wd = d.wind && d.wind.day ? d.wind.day : null;
            const wn = d.wind && d.wind.night ? d.wind.night : null;
            const mmD = list._num(d.precip ? d.precip.day : null);
            const mmN = list._num(d.precip ? d.precip.night : null);
            const pop = list._num(d.precip ? d.precip.prob : null);
            const sunS = list._num(d.sunshineS);
            const uv = list._num(d.uvMax);
            const uvb = Scales.bandOf("uv", uv);
            const bD = Scales.beaufort(wd ? wd.speed : null);
            const bN = Scales.beaufort(wn ? wn.speed : null);
            const aq = [];
            for (let k = 0; k < list._aqIds.length; k++) {
                const id = list._aqIds[k];
                const scale = k === 0 ? aqScale : id;
                const v = d.aq ? list._num(d.aq[id]) : null;
                const b = Scales.bandOf(scale, v);
                aq.push({
                    text: v === null ? "–" : (k === 0 ? String(Math.round(v)) : F.conc(v, id)),
                    f: list._bandPos(scale, v), band: b ? b.band : -1
                });
            }
            out.push({
                weekday: d.weekday, date: d.dateLabel, isToday: !!d.isToday,
                dayKind: d.day ? d.day.kind : null, dayIntensity: d.day && d.day.intensity !== null ? d.day.intensity : 1,
                dayShower: d.day ? !!d.day.shower : false,
                nightKind: d.night ? d.night.kind : null, nightIntensity: d.night && d.night.intensity !== null ? d.night.intensity : 1,
                nightShower: d.night ? !!d.night.shower : false,
                moonPhase: d.moonPhase !== null ? d.moonPhase : 0.5,
                mmDay: mmD, mmNight: mmN, mmDayText: F.precip(mmD), mmNightText: F.precip(mmN),
                pop: pop, popText: pop === null ? "–" : F.percent(pop) + " %",
                tmin: d.temp ? list._num(d.temp.min) : null, tmax: d.temp ? list._num(d.temp.max) : null,
                tminText: F.temp(d.temp ? d.temp.min : null), tmaxText: F.temp(d.temp ? d.temp.max : null),
                fmin: d.feelsLike ? list._num(d.feelsLike.min) : null, fmax: d.feelsLike ? list._num(d.feelsLike.max) : null,
                fminText: F.temp(d.feelsLike ? d.feelsLike.min : null), fmaxText: F.temp(d.feelsLike ? d.feelsLike.max : null),
                bftDay: list._bftOf(wd ? list._num(wd.speed) : null), bftNight: list._bftOf(wn ? list._num(wn.speed) : null),
                windDayBand: bD ? bD.band : -1, windNightBand: bN ? bN.band : -1,
                windDayText: F.wind(wd), windNightText: F.wind(wn),
                windDayDir: wd ? list._num(wd.dir) : null, windNightDir: wn ? list._num(wn.dir) : null,
                sunH: sunS === null ? null : sunS / 3600, sunText: F.duration(sunS),
                uv: uv, uvText: uv === null ? "–" : String(Math.round(uv)), uvBand: uvb ? uvb.band : -1,
                aq: aq
            });
        }
        return out;
    }
    // ---- THE PLACE MORPH (WeatherPopup) ------------------------------------------------------------------
    // `_rows` is what the card DRAWS: the rows of the place before and the target (`_rowsBuilt`, from the model) on the popup's
    // clock while it morphs, the target itself the rest of the time. Every length, range and colour reads it: a number moves,
    // a word swaps at once (PlaceBlend.js). The popup calls `placeBegin()` BEFORE it writes the model, and restarts the clock at
    // zero, so the picture on screen is the snapshot at every step of the change and a switch in the middle of a morph starts
    // from what is drawn.
    property var _placeFrom: null
    // Which numbers are not plain lengths: a bar with no value is none long, an angle or a phase turns the short way, a band
    // index is a colour ON the scale (half way between two bands is the colour between them, and "none" is not a band).
    readonly property var _placeRules: ({
        zero: { mmDay: true, mmNight: true, pop: true, sunH: true, uv: true, bftDay: true, bftNight: true, f: true },
        cyclic: { moonPhase: 1, windDayDir: 360, windNightDir: 360 },
        sentinel: { windDayBand: true, windNightBand: true, uvBand: true, band: true }
    })
    readonly property var _rows: list.popup && list.popup.placeMorphing && list._placeFrom
        ? PB.facts(list._placeFrom, list._rowsBuilt, list.popup.placeE, list._placeRules) : list._rowsBuilt
    function placeBegin() {
        list._placeFrom = list._rows;
    }
    // The temperature scale: every day's temperatures and feels-likes, so the
    // feels-like view moves the same segment along the same axis.
    readonly property var _range: {
        let lo = Infinity, hi = -Infinity;
        for (let i = 0; i < list._rows.length; i++) {
            const r = list._rows[i];
            for (const t of [r.tmin, r.tmax, r.fmin, r.fmax]) {
                if (t === null)
                    continue;
                if (t < lo) lo = t;
                if (t > hi) hi = t;
            }
        }
        if (!(lo <= hi))
            return { lo: 0, hi: 1 };
        if (hi - lo < 1)
            return { lo: lo - 0.5, hi: hi + 0.5 };
        return { lo: lo, hi: hi };
    }
    function fracOf(t) {
        const r = list._range;
        return Math.max(0, Math.min(1, (t - r.lo) / (r.hi - r.lo)));
    }
    function tempColor(t) {
        return Mix.c(Theme.weatherRain, Theme.weatherSun, list.fracOf(t));
    }
    // A band index is whole at rest; mid-morph it is the point between two bands (PlaceBlend `sentinel`), and its colour the mix.
    function _band(i) {
        if (!(i >= 0 && i <= Theme.bands.length - 1))
            return Theme.textFaint;
        const lo = Math.floor(i);
        return i === lo ? Theme.bands[lo] : Mix.c(Theme.bands[lo], Theme.bands[lo + 1], i - lo);
    }
    function rowItem(dayIndex) {
        return rowRep.itemAt(dayIndex);
    }
    // Back to the first row (a content being recycled for the next open): a glide or a coast stops, the position is the top's.
    function resetScroll() {
        dressing.stopMotion();
        dressing.scrollBy(-1e9);
    }
    // Where the list is scrolled to, for a probe.
    readonly property real scrollPos: listFlick.contentY
    // A glide or a coast is under way (a probe waits for it to end).
    readonly property bool scrolling: dressing.moving

    // ---- The maxima, over the rows in the viewport ----------------------------------
    readonly property int _firstVisible: Math.max(0, Math.floor((listFlick.contentY - list._rowTop) / list.rowHeight))
    readonly property int _lastVisible: Math.min(list._rows.length - 1,
                                                 Math.ceil((listFlick.contentY + listFlick.height - list._rowTop) / list.rowHeight) - 1)
    readonly property var _maxTarget: {
        let p = list.precipHalfMax, w = list.windMaxBft, s = list.sunshineMaxHours, u = list.uvMax, a = 1;
        const shown = list._aqShown();
        // The TARGET's rows: the maxima ease on their own (Behavior), and one that followed the morphing rows would restart its
        // animation on every tick and never move.
        for (let i = list._firstVisible; i <= list._lastVisible; i++) {
            const r = list._rowsBuilt[i];
            if (!r)
                continue;
            if (r.mmDay !== null) p = Math.max(p, r.mmDay);
            if (r.mmNight !== null) p = Math.max(p, r.mmNight);
            if (r.bftDay !== null) w = Math.max(w, r.bftDay);
            if (r.bftNight !== null) w = Math.max(w, r.bftNight);
            if (r.sunH !== null) s = Math.max(s, r.sunH);
            if (r.uv !== null) u = Math.max(u, r.uv);
            for (let k = 0; k < shown.length; k++) {
                const f = r.aq[shown[k]].f;
                if (f !== null) a = Math.max(a, f);
            }
        }
        return { precip: p, wind: w, sun: s, uv: u, aq: a };
    }
    property real _precipMax: list._maxTarget.precip
    property real _windMax: list._maxTarget.wind
    property real _sunMax: list._maxTarget.sun
    property real _uvMaxNow: list._maxTarget.uv
    property real _aqMax: list._maxTarget.aq
    Behavior on _precipMax { NumberAnimation { duration: list.maxEaseMs; easing.type: Easing.OutCubic } }
    Behavior on _windMax { NumberAnimation { duration: list.maxEaseMs; easing.type: Easing.OutCubic } }
    Behavior on _sunMax { NumberAnimation { duration: list.maxEaseMs; easing.type: Easing.OutCubic } }
    Behavior on _uvMaxNow { NumberAnimation { duration: list.maxEaseMs; easing.type: Easing.OutCubic } }
    Behavior on _aqMax { NumberAnimation { duration: list.maxEaseMs; easing.type: Easing.OutCubic } }

    // ---- The layout: one function per view ---------------------------------------
    readonly property var _order: ["aDay", "gDayL", "pair", "gDayR", "min", "hull",
                                   "aq1", "aq2", "aq3", "aq4", "aq5", "aq6", "max", "gNight", "tail", "aNight"]
    // Which air-quality values a row shows, by index into _aqIds: the first
    // `aqCount` of index, PM2.5, PM10, O3, NO2, SO2, CO. Five at both card
    // widths: seven leave an 11 px bar on the 480 card, and SO2 and CO sit in
    // their lowest band all year in Belgium (CO is not even in the EAQI), so
    // their bars would be empty on every row.
    function _aqShown() {
        const n = Math.max(1, Math.min(7, list.aqCount));
        const out = [];
        for (let k = 0; k < n; k++)
            out.push(k);
        return out;
    }
    // spec: { name: { w (px, or -1 = GROW), gap } } for the elements shown.
    // Unshown elements get width 0 at the running position, so the order holds.
    function _walk(W, spec) {
        const cx0 = list._cx0, cx1 = W - list.rowPadH;
        let fixed = 0, any = false;
        for (const n of list._order) {
            const s = spec[n];
            if (!s)
                continue;
            if (any)
                fixed += s.gap;
            any = true;
            if (s.w >= 0)
                fixed += s.w;
        }
        const out = {};
        let x = cx0;
        any = false;
        for (const n of list._order) {
            const s = spec[n];
            if (!s) {
                out[n] = { x: x, w: 0, p: 0 };
                continue;
            }
            if (any)
                x += s.gap;
            any = true;
            const w = s.w >= 0 ? s.w : Math.max(0, Math.floor(cx1 - cx0 - fixed));
            out[n] = { x: x, w: w, p: 1 };
            x += w;
        }
        return out;
    }
    function _layoutOf(v, W) {
        const id = list.views[v].id;
        const g = list.glyphSize, a = list.arrowSize;
        const A = W - list.rowPadH - list._cx0;
        const shown = list._aqShown();
        const N = shown.length;
        let spec, segW = [];
        if (id === "conditions" || id === "feelsLike") {
            spec = {
                pair: { w: 2 * (list._mmSlot + list.valueGap + list.pairBarLength) + list.pairCenterGap, gap: 0 },
                gDayR: { w: g, gap: list.colGap },
                min: { w: list._tempSlot, gap: list.glyphGap },
                hull: { w: -1, gap: list.figureGap },
                max: { w: list._tempSlot, gap: list.figureGap },
                gNight: { w: g, gap: list.glyphGap },
                tail: { w: list._popSlot, gap: list.colGap }
            };
        } else if (id === "wind") {
            spec = { aDay: { w: a, gap: 0 }, pair: { w: -1, gap: list.flankGap }, aNight: { w: a, gap: list.flankGap } };
        } else if (id === "precipitation") {
            spec = { gDayL: { w: g, gap: 0 }, pair: { w: -1, gap: list.flankGap }, gNight: { w: g, gap: list.flankGap } };
        } else if (id === "sunshine") {
            spec = { gDayR: { w: g, gap: 0 }, hull: { w: -1, gap: list.colGap }, tail: { w: list._hrSlot, gap: list.figureGap } };
        } else if (id === "uv") {
            spec = { hull: { w: -1, gap: 0 }, tail: { w: list._uvSlot, gap: list.figureGap } };
        } else {
            // N equal segments; the last takes the remainder so the row ends flush.
            const each = Math.floor((A - (N - 1) * list.aqSegmentGap) / N);
            spec = {};
            for (let j = 0; j < N; j++) {
                const w = j === N - 1 ? A - (N - 1) * (each + list.aqSegmentGap) : each;
                segW.push(w);
                spec[j === 0 ? "hull" : "aq" + j] = { w: w, gap: j === 0 ? 0 : list.aqSegmentGap };
            }
        }
        const o = list._walk(W, spec);
        const L = {};
        for (const n of ["aDay", "pair", "min", "max", "gNight", "tail", "aNight"])
            L[n] = o[n];
        L.gDay = o.gDayL.p > 0 ? o.gDayL : o.gDayR;
        L.gDaySide = o.gDayL.p > 0 ? -1 : 1;
        const pv = id === "wind" ? list._windSlot : list._mmSlot;
        L.pair = {
            x: o.pair.x, w: o.pair.w, p: o.pair.p, val: pv,
            bar: o.pair.p === 0 ? 0 : (id === "conditions" || id === "feelsLike" ? list.pairBarLength
                 : Math.max(0, Math.floor((o.pair.w - 2 * (pv + list.valueGap) - list.pairCenterGap) / 2)))
        };
        const aqView = id === "airQuality";
        const valW = list._aqValSlot;
        L.hull = { x: o.hull.x, w: aqView ? Math.max(0, segW[0] - list.valueGap - valW) : o.hull.w, p: o.hull.p };
        L.hullCy = aqView ? list._barCy : list.rowHeight / 2;
        L.aq = [];
        for (let k = 0; k < 7; k++) {
            const j = shown.indexOf(k);
            if (aqView && j >= 0) {
                const e = j === 0 ? o.hull : o["aq" + j];
                L.aq.push({ x: e.x, w: e.w, barW: Math.max(0, e.w - list.valueGap - valW), p: 1 });
            } else if (k === 0) {
                // Segment 0's bar IS the hull, in every view: its figure rides the hull's end.
                L.aq.push({ x: o.hull.x, w: o.hull.w, barW: o.hull.w, p: 0 });
            } else if (o.hull.p > 0 && j >= 0) {
                // Past the end of the hull, one figure slot apart: segment j's
                // figure rides its bar's end, so each collapsed segment keeps
                // the room of the figure in front of it and the pieces come
                // out of the bar's end in order without crossing a figure.
                L.aq.push({ x: o.hull.x + o.hull.w + j * (list.valueGap + valW), w: 0, barW: 0, p: 0 });
            } else {
                const e = j > 0 ? o["aq" + j] : (j === 0 ? o.hull : o.max);
                L.aq.push({ x: e.x, w: 0, barW: 0, p: 0 });
            }
        }
        return L;
    }
    // Only the views in play are laid out (and the first, which the skeleton reads): a card that follows a resizing popup
    // re-walks its row at every width, and at rest ONE view weighs anything. Every reader asks for a view that weighs.
    readonly property var _layouts: {
        const W = list._rowW;
        const w = blend.weights;
        const out = [];
        for (let v = 0; v < list.views.length; v++)
            out.push(v === 0 || w[v] > 0 ? list._layoutOf(v, W) : null);
        return out;
    }

    // ---- The clock ----------------------------------------------------------------
    ViewBlend {
        id: blend
        count: list.views.length
        target: list.viewIndex
        durationMs: list.transitionMs
    }
    // Whether any view in play shows the air-quality segments, and what a segment is while none does.
    readonly property bool _aqLive: blend.mix(v => list.views[v].id === "airQuality" ? 1 : 0) > 0
    readonly property var _aqAbsent: ({ x: 0, w: 0, barW: 0, p: 0 })
    // What an element of kind `key` ("pair", "fill", "tail") shows, by the view
    // whose text it keeps (blend.textView); "" when no view in play has it.
    function _kindOf(key, has) {
        const v = blend.textView(has);
        return v >= 0 ? list._kinds[v][key] : "";
    }
    // The blended slots, shared by every row.
    // The blended slots ONE NUMBER EACH: a row binding re-runs only when the slot it reads moved (a card that follows a resizing
    // popup changes the hull's width and what stands after it, not the whole row), where a read of `_lay` re-runs for any of them.
    readonly property real _lay_aDay_p: list._lay.aDay.p
    readonly property real _lay_aDay_w: list._lay.aDay.w
    readonly property real _lay_aDay_x: list._lay.aDay.x
    readonly property real _lay_aNight_p: list._lay.aNight.p
    readonly property real _lay_aNight_w: list._lay.aNight.w
    readonly property real _lay_aNight_x: list._lay.aNight.x
    readonly property real _lay_gDaySide: list._lay.gDaySide
    readonly property real _lay_gDay_p: list._lay.gDay.p
    readonly property real _lay_gDay_w: list._lay.gDay.w
    readonly property real _lay_gDay_x: list._lay.gDay.x
    readonly property real _lay_gNight_p: list._lay.gNight.p
    readonly property real _lay_gNight_w: list._lay.gNight.w
    readonly property real _lay_gNight_x: list._lay.gNight.x
    readonly property real _lay_hullCy: list._lay.hullCy
    readonly property real _lay_hull_w: list._lay.hull.w
    readonly property real _lay_hull_x: list._lay.hull.x
    readonly property real _lay_max_p: list._lay.max.p
    readonly property real _lay_max_w: list._lay.max.w
    readonly property real _lay_max_x: list._lay.max.x
    readonly property real _lay_min_p: list._lay.min.p
    readonly property real _lay_min_w: list._lay.min.w
    readonly property real _lay_min_x: list._lay.min.x
    readonly property real _lay_pair_p: list._lay.pair.p
    readonly property real _lay_pair_val: list._lay.pair.val
    readonly property real _lay_pair_w: list._lay.pair.w
    readonly property real _lay_pair_x: list._lay.pair.x
    readonly property real _lay_tail_p: list._lay.tail.p
    readonly property real _lay_tail_w: list._lay.tail.w
    readonly property real _lay_tail_x: list._lay.tail.x
    readonly property var _lay: {
        const Ls = list._layouts;
        // At rest one view weighs 1 and the blend of its slots is that view's own layout (1 * x): no mix, no new object per slot.
        const one = blend.weights.indexOf(1);
        if (one >= 0 && Ls[one])
            return Ls[one];
        const acc = get => blend.mix(v => get(Ls[v]));
        const box = function (n) {
            return { x: acc(l => l[n].x), w: acc(l => l[n].w), p: acc(l => l[n].p) };
        };
        const out = {
            aDay: box("aDay"), gDay: box("gDay"), min: box("min"), hull: box("hull"), max: box("max"),
            gNight: box("gNight"), tail: box("tail"), aNight: box("aNight"),
            pair: { x: acc(l => l.pair.x), w: acc(l => l.pair.w), p: acc(l => l.pair.p),
                    val: acc(l => l.pair.val), bar: acc(l => l.pair.bar) },
            hullCy: acc(l => l.hullCy),
            gDaySide: acc(l => l.gDaySide),
            aq: []
        };
        for (let k = 0; k < 7; k++)
            out.aq.push({ x: acc(l => l.aq[k].x), w: acc(l => l.aq[k].w), barW: acc(l => l.aq[k].barW), p: acc(l => l.aq[k].p) });
        return out;
    }

    // ---- Per row, per view ---------------------------------------------------------
    function _pairLen(v, r, day) {
        const lay = list._layouts[v];
        const kind = list._kinds[v].pair;
        if (!r || lay.pair.p === 0 || kind === "")
            return 0;
        let f;
        if (kind === "precip") {
            const mm = day ? r.mmDay : r.mmNight;
            if (mm === null || !(mm > 0))
                return 0;
            f = mm / Math.max(0.001, list._precipMax);
        } else {
            const b = day ? r.bftDay : r.bftNight;
            if (b === null || !(b > 0))
                return 0;
            f = b / Math.max(0.001, list._windMax);
        }
        return Math.max(list.barMinPx, lay.pair.bar * Math.min(1, f));
    }
    function _pairColor(v, r, day) {
        const kind = list._kinds[v].pair;
        if (!r || kind === "")
            return null;
        const c = kind === "precip" ? Theme.weatherRain : list._band(day ? r.windDayBand : r.windNightBand);
        return day ? c : Qt.rgba(c.r, c.g, c.b, c.a * list.nightBarAlpha);
    }
    // The raised segment's ends, in row coordinates.
    function _segEnd(v, r, which) {
        const lay = list._layouts[v];
        const hx = lay.hull.x, hw = lay.hull.w;
        const kind = list._kinds[v].fill;
        if (!r || kind === "" || lay.hull.p === 0)
            return hx + hw / 2;
        if (kind === "temp" || kind === "feels") {
            const lo = kind === "temp" ? r.tmin : r.fmin;
            const hi = kind === "temp" ? r.tmax : r.fmax;
            if (lo === null || hi === null)
                return hx + hw / 2;
            const f0 = list.fracOf(lo) * hw, f1 = list.fracOf(hi) * hw;
            const sw = Math.min(hw, Math.max(list.segmentMinWidth, f1 - f0));
            const x0 = hx + Math.max(0, Math.min(hw - sw, (f0 + f1) / 2 - sw / 2));
            return which === 0 ? x0 : x0 + sw;
        }
        let f = 0;
        if (kind === "sun")
            f = r.sunH === null ? 0 : r.sunH / Math.max(0.001, list._sunMax);
        else if (kind === "uv")
            f = r.uv === null ? 0 : r.uv / Math.max(0.001, list._uvMaxNow);
        else
            f = r.aq[0].f === null ? 0 : r.aq[0].f / Math.max(0.001, list._aqMax);
        const len = f > 0 ? Math.min(hw, Math.max(list.segmentMinWidth, hw * f)) : 0;
        return which === 0 ? hx + hw - len : hx + hw;
    }
    function _segColor(v, r, which) {
        const kind = list._kinds[v].fill;
        if (!r || kind === "")
            return null;
        if (kind === "temp" || kind === "feels") {
            const t = kind === "temp" ? (which === 0 ? r.tmin : r.tmax) : (which === 0 ? r.fmin : r.fmax);
            return t === null ? null : list.tempColor(t);
        }
        if (kind === "sun")
            return Theme.weatherSun;
        if (kind === "uv")
            return list._band(r.uvBand);
        return list._band(r.aq[0].band);
    }
    function _popLen(v, r) {
        const lay = list._layouts[v];
        if (!r || list._kinds[v].tail !== "pop" || r.pop === null || r.pop < list._probMin)
            return 0;
        return lay.hull.w * Math.max(0, Math.min(1, r.pop / 100));
    }
    function _aqLen(v, r, k) {
        const lay = list._layouts[v];
        if (!r || list._kinds[v].fill !== "aq" || lay.aq[k].p === 0 || r.aq[k].f === null)
            return 0;
        const f = r.aq[k].f / Math.max(0.001, list._aqMax);
        return f > 0 ? Math.min(lay.aq[k].barW, Math.max(list.segmentMinWidth, lay.aq[k].barW * f)) : 0;
    }

    ShadowBox {
        id: card
        anchors.fill: parent
        baseRadius: list._radius
        surfaceColor: Theme.surface
        bevelColor: list._cardBevelColor
        shadowColor: Theme.border
        backgroundColor: Theme.listBox
        bevelWidth: list._cardBevel
        shadowWidth: list._cardShadow
        shadowFalloff: list._cardFalloff

        Item {
            id: box
            x: list._pad - list._slack
            y: list._pad - list._slack
            width: list._innerW + 2 * list._slack
            height: list._innerH + 2 * list._slack

            Flickable {
                id: listFlick
                anchors.fill: parent
                interactive: false
                clip: true
                contentWidth: width
                contentHeight: Math.max(height, list._rows.length * list.rowHeight + 2 * list._rowTop)
                onHeightChanged: contentY = Math.max(0, Math.min(contentY, contentHeight - height))
                onContentHeightChanged: contentY = Math.max(0, Math.min(contentY, contentHeight - height))
                opacity: list._hasModel ? 1 : 0
                visible: opacity > 0
                Behavior on opacity {
                    NumberAnimation { duration: list._fadeMs; easing.type: Easing.OutCubic }
                }

                // THE OPEN ROW SINKS. Its ground is today's shade carved in
                // with the popup's inset knobs -- one mark for "this row's
                // detail is open", and the same mark on today's already
                // shaded row, which a flat shade could not show. One box for
                // the list, placed on the open row.
                ShadowBox {
                    id: selectionGround
                    readonly property int dayIndex: {
                        const k = list._activeKey;
                        return !!k && k.from === "daily" && k.dayIndex >= 0 && k.dayIndex < list._rows.length ? k.dayIndex : -1;
                    }
                    visible: selectionGround.dayIndex >= 0
                    x: list._rowX
                    y: list._rowTop + Math.max(0, selectionGround.dayIndex) * list.rowHeight + list.rowGroundGap
                    width: list._rowW
                    height: list.rowHeight - 2 * list.rowGroundGap
                    baseRadius: list.rowRadius
                    surfaceColor: "transparent"
                    bevelColor: list._cardBevelColor
                    shadowColor: Theme.border
                    backgroundColor: Theme.headerBox
                    bevelWidth: list._insetBevel
                    shadowWidth: list._insetShadow
                    shadowFalloff: list._insetFalloff
                }

                Repeater {
                    id: rowRep
                    model: list._rows.length
                    Item {
                        id: row
                        required property int index
                        x: list._rowX
                        y: list._rowTop + row.index * list.rowHeight
                        width: list._rowW
                        height: list.rowHeight
                        readonly property var r: list._rows[row.index]
                        readonly property var key: ({ metric: list.views[list.viewIndex].metric, dayIndex: row.index,
                                                       hourIndex: null, from: "daily" })
                        readonly property bool active: {
                            const k = list._activeKey;
                            return !!k && k.from === "daily" && k.dayIndex === row.index;
                        }
                        readonly property bool today: row.r ? row.r.isToday : false
                        readonly property real cy: list.rowHeight / 2
                        property real hoverF: list._hoverIndex === row.index ? 1 : 0
                        Behavior on hoverF {
                            NumberAnimation { duration: list.hoverMs; easing.type: Easing.OutCubic }
                        }

                        // The ground: today's shade, the hover wash. The open
                        // row's ground is the carved one under the Repeater
                        // (selectionGround), so this one stands aside for it.
                        Rectangle {
                            x: 0
                            y: list.rowGroundGap
                            width: parent.width
                            height: parent.height - 2 * list.rowGroundGap
                            radius: list.rowRadius
                            color: row.today ? Theme.headerBox : Theme.panelSunk
                            opacity: row.active ? 0 : (row.today ? 1 : row.hoverF * list.hoverGroundAlpha)
                            visible: opacity > 0.001
                        }

                        // Weekday over date.
                        Item {
                            objectName: "dayCol"
                            x: list.rowPadH
                            y: list._textY
                            width: list._dayColW
                            height: list._lineWeek + list._lineDate
                            Text {
                                x: 0
                                y: 0
                                height: list._lineWeek
                                text: row.r ? row.r.weekday : ""
                                color: Theme.textPrimary
                                font.family: list._font
                                font.pixelSize: list.weekdaySize
                                font.bold: true
                                verticalAlignment: Text.AlignVCenter
                            }
                            Text {
                                x: 0
                                y: list._lineWeek
                                height: list._lineDate
                                text: row.r ? row.r.date : ""
                                color: Theme.textFaint
                                font.family: list._font
                                font.pixelSize: list.dateSize
                                verticalAlignment: Text.AlignVCenter
                            }
                        }

                        // ---- The pair: two bars out of one centre, figures on their ends.
                        readonly property real pairCx: Math.round(list._lay_pair_x + list._lay_pair_w / 2)
                        readonly property real dayLen: Math.round(blend.mix(v => list._pairLen(v, row.r, true)))
                        readonly property real nightLen: Math.round(blend.mix(v => list._pairLen(v, row.r, false)))
                        readonly property bool pairWind: list._kindOf("pair", v => list._kinds[v].pair !== "") === "wind"
                        readonly property real pairValW: Math.round(list._lay_pair_val)
                        Rectangle {
                            objectName: "dayBar"
                            x: row.pairCx - list.pairCenterGap / 2 - width
                            y: Math.round(row.cy - height / 2)
                            width: row.dayLen
                            height: list.pairBarHeight
                            radius: height / 2
                            color: blend.mixColor(v => list._pairColor(v, row.r, true))
                            visible: width > 0.5 && list._lay_pair_p > 0.01
                        }
                        Rectangle {
                            objectName: "nightBar"
                            x: row.pairCx + list.pairCenterGap / 2
                            y: Math.round(row.cy - height / 2)
                            width: row.nightLen
                            height: list.pairBarHeight
                            radius: height / 2
                            color: blend.mixColor(v => list._pairColor(v, row.r, false))
                            visible: width > 0.5 && list._lay_pair_p > 0.01
                        }
                        Text {
                            objectName: "dayVal"
                            readonly property bool zero: row.r ? (row.pairWind ? !(row.r.bftDay > 0) : !(row.r.mmDay > 0)) : true
                            x: row.pairCx - list.pairCenterGap / 2 - row.dayLen - list.valueGap - width
                            y: Math.round(row.cy - height / 2)
                            width: row.pairValW
                            height: list._lineSmall
                            text: !row.r ? "" : (row.pairWind ? row.r.windDayText : row.r.mmDayText)
                            color: zero ? Theme.textFaint : Theme.textPrimary
                            font.family: list._font
                            font.pixelSize: list.smallSize
                            horizontalAlignment: Text.AlignRight
                            verticalAlignment: Text.AlignVCenter
                            transformOrigin: Item.Right
                            scale: list._lay_pair_p
                            opacity: list._lay_pair_p * list._lay_pair_p
                            visible: opacity > 0.01
                        }
                        Text {
                            objectName: "nightVal"
                            readonly property bool zero: row.r ? (row.pairWind ? !(row.r.bftNight > 0) : !(row.r.mmNight > 0)) : true
                            x: row.pairCx + list.pairCenterGap / 2 + row.nightLen + list.valueGap
                            y: Math.round(row.cy - height / 2)
                            width: row.pairValW
                            height: list._lineSmall
                            text: !row.r ? "" : (row.pairWind ? row.r.windNightText : row.r.mmNightText)
                            color: zero ? Theme.textFaint : Theme.textMuted
                            font.family: list._font
                            font.pixelSize: list.smallSize
                            horizontalAlignment: Text.AlignLeft
                            verticalAlignment: Text.AlignVCenter
                            transformOrigin: Item.Left
                            scale: list._lay_pair_p
                            opacity: list._lay_pair_p * list._lay_pair_p
                            visible: opacity > 0.01
                        }

                        // ---- The flank glyphs: condition glyphs and wind arrows.
                        // Placed from the slots alone -- never from a bar.
                        WeatherGlyph {
                            id: gDay
                            objectName: "gDay"
                            posing: list.glyphFlourish.on(row.index)
                            poseBeat: list.glyphFlourish.beatOf(row.index)
                            // How far through a change of side the glyph is: 1 at
                            // rest on either side, 0 halfway across the pair.
                            readonly property real settled: Math.abs(list._lay_gDaySide)
                            x: Math.round(list._lay_gDay_x + list._lay_gDay_w / 2 - list.glyphSize / 2)
                            y: Math.round(row.cy - height / 2)
                            size: list.glyphSize
                            scale: list._lay_gDay_p * (1 - list.crossDip * (1 - settled))
                            opacity: list._lay_gDay_p
                            visible: opacity > 0.01 && (row.r ? row.r.dayKind !== null : false)
                            kind: row.r && row.r.dayKind ? row.r.dayKind : "clear"
                            intensity: row.r ? row.r.dayIntensity : 1
                            night: false
                            shower: row.r ? row.r.dayShower : false
                            style: list._gs
                        }
                        WeatherGlyph {
                            id: gNight
                            objectName: "gNight"
                            posing: list.glyphFlourish.on(row.index)
                            poseBeat: list.glyphFlourish.beatOf(row.index)
                            x: Math.round(list._lay_gNight_x + list._lay_gNight_w / 2 - list.glyphSize / 2)
                            y: Math.round(row.cy - height / 2)
                            size: list.glyphSize
                            scale: list._lay_gNight_p
                            opacity: list._lay_gNight_p
                            visible: opacity > 0.01 && (row.r ? row.r.nightKind !== null : false)
                            kind: row.r && row.r.nightKind ? row.r.nightKind : "clear"
                            intensity: row.r ? row.r.nightIntensity : 1
                            night: true
                            shower: row.r ? row.r.nightShower : false
                            moonPhase: row.r ? row.r.moonPhase : 0.5
                            style: list._gs
                        }
                        WeatherGlyph {
                            id: aDay
                            objectName: "aDay"
                            posing: list.glyphFlourish.on(row.index)
                            poseBeat: list.glyphFlourish.beatOf(row.index)
                            x: Math.round(list._lay_aDay_x + list._lay_aDay_w / 2 - list.arrowSize / 2)
                            y: Math.round(row.cy - height / 2)
                            size: list.arrowSize
                            scale: list._lay_aDay_p
                            opacity: list._lay_aDay_p
                            visible: opacity > 0.01
                            kind: "arrow"
                            direction: row.r ? row.r.windDayDir : null
                            style: list._gs
                        }
                        WeatherGlyph {
                            id: aNight
                            objectName: "aNight"
                            posing: list.glyphFlourish.on(row.index)
                            poseBeat: list.glyphFlourish.beatOf(row.index)
                            x: Math.round(list._lay_aNight_x + list._lay_aNight_w / 2 - list.arrowSize / 2)
                            y: Math.round(row.cy - height / 2)
                            size: list.arrowSize
                            scale: list._lay_aNight_p
                            opacity: list._lay_aNight_p
                            visible: opacity > 0.01
                            kind: "arrow"
                            direction: row.r ? row.r.windNightDir : null
                            style: list._gs
                        }

                        // ---- min, the hull with its segment, max, the tail.
                        readonly property bool feels: list._kindOf("fill", v => list._kinds[v].fill === "temp" || list._kinds[v].fill === "feels") === "feels"
                        Text {
                            objectName: "min"
                            x: Math.round(list._lay_min_x + list._lay_min_w / 2 - width / 2)
                            y: Math.round(row.cy - height / 2)
                            width: list._tempSlot
                            height: list._lineFig
                            text: !row.r ? "" : (row.feels ? row.r.fminText : row.r.tminText)
                            color: Theme.textPrimary
                            font.family: list._font
                            font.pixelSize: list.figureSize
                            horizontalAlignment: Text.AlignRight
                            verticalAlignment: Text.AlignVCenter
                            scale: list._lay_min_p
                            opacity: list._lay_min_p * list._lay_min_p
                            visible: opacity > 0.01
                        }
                        ShadowBox {
                            id: hull
                            objectName: "hull"
                            x: list._lay_hull_x
                            y: Math.round(list._lay_hullCy - height / 2)
                            width: list._lay_hull_w
                            height: list.grooveHeight
                            visible: width > 0.5
                            baseRadius: list.grooveHeight / 2
                            surfaceColor: "transparent"
                            bevelColor: list._carveBevel
                            shadowColor: list._carveShadow
                            backgroundColor: list._carveFill
                            bevelWidth: list._grooveBevel
                            shadowWidth: list._grooveShadow

                            // The PoP, faint, from the right end.
                            Rectangle {
                                objectName: "pop"
                                readonly property real len: blend.mix(v => list._popLen(v, row.r))
                                x: hull.width - width
                                y: 0
                                width: Math.min(hull.width, len)
                                height: hull.height
                                radius: height / 2
                                color: Qt.rgba(Theme.weatherRain.r, Theme.weatherRain.g, Theme.weatherRain.b, list.popAlpha)
                                visible: width > 0.5
                            }
                        }
                        ShadowBox {
                            id: segment
                            objectName: "seg"
                            readonly property real x0: blend.mix(v => list._segEnd(v, row.r, 0))
                            readonly property real x1: blend.mix(v => list._segEnd(v, row.r, 1))
                            readonly property color c0: blend.mixColor(v => list._segColor(v, row.r, 0))
                            readonly property color c1: blend.mixColor(v => list._segColor(v, row.r, 1))
                            x: segment.x0
                            y: Math.round(list._lay_hullCy - height / 2)
                            width: Math.max(0, segment.x1 - segment.x0)
                            height: list.segmentHeight
                            visible: width > 0.5
                            raised: true
                            shadowToAlpha: true
                            baseRadius: list.segmentHeight / 2
                            surfaceColor: Theme.panelSunk
                            bevelColor: Theme.buttonBevel
                            shadowColor: Theme.buttonShadow
                            backgroundColor: Mix.c(segment.c0, segment.c1, 0.5)
                            bevelWidth: 1
                            shadowWidth: 2
                            shadowEdgeAlpha: 0.7
                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: 1.5
                                radius: height / 2
                                gradient: Gradient {
                                    orientation: Gradient.Horizontal
                                    GradientStop { position: 0; color: segment.c0 }
                                    GradientStop { position: 1; color: segment.c1 }
                                }
                            }
                        }
                        Text {
                            objectName: "max"
                            x: Math.round(list._lay_max_x + list._lay_max_w / 2 - width / 2)
                            y: Math.round(row.cy - height / 2)
                            width: list._tempSlot
                            height: list._lineFig
                            text: !row.r ? "" : (row.feels ? row.r.fmaxText : row.r.tmaxText)
                            color: Theme.textPrimary
                            font.family: list._font
                            font.pixelSize: list.figureSize
                            horizontalAlignment: Text.AlignLeft
                            verticalAlignment: Text.AlignVCenter
                            scale: list._lay_max_p
                            opacity: list._lay_max_p * list._lay_max_p
                            visible: opacity > 0.01
                        }
                        Text {
                            objectName: "tail"
                            readonly property string kind: list._kindOf("tail", v => list._kinds[v].tail !== "")
                            x: Math.round(list._lay_tail_x + list._lay_tail_w - width)
                            y: Math.round(row.cy - height / 2)
                            width: Math.round(list._lay_tail_w)
                            height: list._lineFig
                            text: !row.r ? "" : (kind === "sun" ? row.r.sunText : (kind === "uv" ? row.r.uvText
                                  : (row.r.pop !== null && row.r.pop < list._probMin ? "" : row.r.popText)))
                            color: kind === "pop" ? Theme.textMuted : Theme.textPrimary
                            font.family: list._font
                            font.pixelSize: list.figureSize
                            horizontalAlignment: Text.AlignRight
                            verticalAlignment: Text.AlignVCenter
                            transformOrigin: Item.Right
                            scale: list._lay_tail_p
                            opacity: list._lay_tail_p * list._lay_tail_p
                            visible: opacity > 0.01
                        }

                        // ---- Air quality: one bar per value (segment 0's bar is the hull).
                        Repeater {
                            model: 7
                            Item {
                                id: aqSeg
                                required property int index
                                objectName: "aq" + aqSeg.index
                                // Out of the air-quality view (no view in play shows these) a segment has presence 0 and length 0:
                                // it reads neither the layout nor the blend, so a resize of the card does not run 7 x rows of them.
                                readonly property var s: list._aqLive ? list._lay.aq[aqSeg.index] : list._aqAbsent
                                readonly property real len: list._aqLive ? blend.mix(v => list._aqLen(v, row.r, aqSeg.index)) : 0
                                x: 0
                                y: 0
                                width: 0
                                height: 0
                                visible: aqSeg.s.p > 0.01
                                Text {
                                    objectName: "aqLabel"
                                    x: Math.round(aqSeg.s.x)
                                    y: Math.round(list._labelCy - height / 2)
                                    height: list._lineLabel
                                    text: aqSeg.index === 0 && list._model && list._model.aqIndex === "belaqi" ? "BelAQI" : list._aqLabels[aqSeg.index]
                                    color: Theme.textFaint
                                    font.family: list._font
                                    font.pixelSize: list.labelSize
                                    verticalAlignment: Text.AlignVCenter
                                    transformOrigin: Item.Left
                                    scale: aqSeg.s.p
                                    opacity: aqSeg.s.p * aqSeg.s.p
                                }
                                ShadowBox {
                                    id: aqHull
                                    objectName: "aqHull"
                                    x: aqSeg.s.x
                                    y: Math.round(list._lay_hullCy - height / 2)
                                    width: aqSeg.s.barW
                                    height: list.grooveHeight
                                    visible: aqSeg.index > 0 && width > 0.5
                                    baseRadius: list.grooveHeight / 2
                                    surfaceColor: "transparent"
                                    bevelColor: list._carveBevel
                                    shadowColor: list._carveShadow
                                    backgroundColor: list._carveFill
                                    bevelWidth: list._grooveBevel
                                    shadowWidth: list._grooveShadow
                                }
                                ShadowBox {
                                    objectName: "aqFill"
                                    readonly property color c: row.r ? list._band(row.r.aq[aqSeg.index].band) : Theme.textFaint
                                    x: aqSeg.s.x + aqSeg.s.barW - width
                                    y: Math.round(list._lay_hullCy - height / 2)
                                    width: Math.min(aqSeg.s.barW, aqSeg.len)
                                    height: list.segmentHeight
                                    visible: aqSeg.index > 0 && width > 0.5
                                    raised: true
                                    shadowToAlpha: true
                                    baseRadius: list.segmentHeight / 2
                                    surfaceColor: Theme.panelSunk
                                    bevelColor: Theme.buttonBevel
                                    shadowColor: Theme.buttonShadow
                                    backgroundColor: c
                                    bevelWidth: 1
                                    shadowWidth: 2
                                    shadowEdgeAlpha: 0.7
                                }
                                Text {
                                    objectName: "aqValue"
                                    x: Math.round(aqSeg.s.x + aqSeg.s.barW + list.valueGap)
                                    y: Math.round(list._lay_hullCy - height / 2)
                                    width: list._aqValSlot
                                    height: list._lineSmall
                                    text: row.r ? row.r.aq[aqSeg.index].text : ""
                                    color: Theme.textPrimary
                                    font.family: list._font
                                    font.pixelSize: list.smallSize
                                    horizontalAlignment: Text.AlignRight
                                    verticalAlignment: Text.AlignVCenter
                                    transformOrigin: Item.Right
                                    scale: aqSeg.s.p
                                    opacity: aqSeg.s.p * aqSeg.s.p
                                }
                            }
                        }

                        MouseArea {
                            id: rowArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            function flourish(): void {
                                let beats = 0;
                                for (const g of [gDay, gNight, aDay, aNight])
                                    beats = Math.max(beats, g.visible ? g.flourishBeats : 0);
                                list.glyphFlourish.play(row.index, beats);
                            }
                            onContainsMouseChanged: {
                                list.glyphFlourish.entered(rowArea);
                                if (rowArea.containsMouse)
                                    list._hoverIndex = row.index;
                                else if (list._hoverIndex === row.index)
                                    list._hoverIndex = -1;
                            }
                            onPositionChanged: if (list.glyphFlourish.hovered(rowArea)) rowArea.flourish()
                            onClicked: {
                                rowArea.flourish();
                                if (list.popup)
                                    list.popup.openDetail(row.key, row.mapToItem(list.popup, row.width / 2, row.height / 2));
                            }
                        }
                    }
                }
            }

            ScrollDressing {
                id: dressing
                anchors.fill: parent
                flick: listFlick
                orientation: Qt.Vertical
                wheelEnabled: list._hasModel && (list.popup ? list.popup.listWheelEnabled : true)
                scrollSpeed: list.popup ? list.popup.scrollSpeed : 1
                ground: Theme.listBox
                fadeHeight: list.fadeHeight
                fadeLead: list._slack
                visible: list._hasModel
            }

            // ---- The silhouette (the conditions view's slots) -----------------------
            Item {
                id: skeleton
                anchors.fill: parent
                opacity: list._hasModel ? 0 : 1
                visible: opacity > 0
                Behavior on opacity {
                    NumberAnimation { duration: list._fadeMs; easing.type: Easing.OutCubic }
                }
                readonly property bool pulse: list.popup ? list.popup.skeletonPulse : true
                readonly property var lay: list._layouts[0]
                Repeater {
                    model: list.skeletonRows
                    Item {
                        id: skRow
                        required property int index
                        x: list._rowX
                        y: list._rowTop + skRow.index * list.rowHeight
                        width: list._rowW
                        height: list.rowHeight
                        readonly property int phase: skRow.index * 90
                        SkeletonBar {
                            x: list.rowPadH
                            y: list._textY + (list._lineWeek - height) / 2
                            width: 28
                            height: 8
                            pulse: skeleton.pulse
                            pulseTravel: 2
                            pulsePhaseMs: skRow.phase
                            barColor: Theme.headerBox
                            groundColor: Theme.listBox
                        }
                        SkeletonBar {
                            x: list.rowPadH
                            y: list._textY + list._lineWeek + (list._lineDate - height) / 2
                            width: 24
                            height: 6
                            pulse: skeleton.pulse
                            pulseTravel: 2
                            pulsePhaseMs: skRow.phase
                            barColor: Theme.headerBox
                            groundColor: Theme.listBox
                        }
                        SkeletonBar {
                            x: skeleton.lay.pair.x
                            y: (parent.height - height) / 2
                            width: skeleton.lay.pair.w
                            height: 6
                            pulse: skeleton.pulse
                            pulseTravel: 2
                            pulsePhaseMs: skRow.phase
                            barColor: Theme.headerBox
                            groundColor: Theme.listBox
                        }
                        SkeletonBar {
                            x: skeleton.lay.gDay.x
                            y: (parent.height - height) / 2
                            width: list.glyphSize
                            height: list.glyphSize
                            radius: list.glyphSize / 2
                            pulse: skeleton.pulse
                            pulseTravel: 2
                            pulsePhaseMs: skRow.phase
                            barColor: Theme.headerBox
                            groundColor: Theme.listBox
                        }
                        SkeletonBar {
                            x: skeleton.lay.hull.x
                            y: (parent.height - height) / 2
                            width: skeleton.lay.hull.w
                            height: list.grooveHeight
                            pulse: skeleton.pulse
                            pulseTravel: 2
                            pulsePhaseMs: skRow.phase
                            barColor: Theme.headerBox
                            groundColor: Theme.listBox
                        }
                        SkeletonBar {
                            x: skeleton.lay.gNight.x
                            y: (parent.height - height) / 2
                            width: list.glyphSize
                            height: list.glyphSize
                            radius: list.glyphSize / 2
                            pulse: skeleton.pulse
                            pulseTravel: 2
                            pulsePhaseMs: skRow.phase
                            barColor: Theme.headerBox
                            groundColor: Theme.listBox
                        }
                        SkeletonBar {
                            x: skeleton.lay.tail.x + skeleton.lay.tail.w - width
                            y: (parent.height - height) / 2
                            width: skeleton.lay.tail.w * 0.7
                            height: 8
                            pulse: skeleton.pulse
                            pulseTravel: 2
                            pulsePhaseMs: skRow.phase
                            barColor: Theme.headerBox
                            groundColor: Theme.listBox
                        }
                    }
                }
            }
        }

        // The view cycler: overlay title, dots along the bottom padding.
        CardViewCycler {
            id: cycler
            anchors.fill: parent
            currentIndex: list.startView
            views: list.views
            orientation: "horizontal"
            padding: list._pad
            radius: list._radius
            fontFamily: list._font
            bevelWidth: list._insetBevel
            shadowWidth: list._insetShadow
            shadowFalloff: list._insetFalloff
            bevelColor: list._cardBevelColor
        }
    }
}
