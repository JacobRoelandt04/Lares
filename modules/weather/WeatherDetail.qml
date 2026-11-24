pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/components/Mix.js" as Mix
import "data/WeatherModel.js" as WM
import "data/WeatherSeries.js" as WS
import "data/PlaceBlend.js" as PB
import "../common/scroll"

// =============================================================================
// WeatherDetail.qml -- the secondary popup's content: one metric on a timeline.
//
// The engine hands this `secondaryKey` = { metric, dayIndex,
// hourIndex } while the content is hidden (on load and between the fade out
// and the fade in of a swap), so a key change rebuilds everything INSTANTLY
// (`jump`). THE EXCEPTION: a key whose chart MORPHS from the one shown (`secondarySwapsInPlace`:
// WS.morphsInto, only when the two would morph into each other; on stocks and here) is
// swapped in place: the engine leaves this content in view, `curtain` takes the sections out and back, and the
// chart and the day strip stay and move. `secondaryCutout` is the part of this item the primary covers
// when the secondary is inset; the content lays out below it, as
// mockups/bar.qml's compDetail does.
//
// A DAY CHANGE MORPHS. A chip, a sideways swipe anywhere over the detail
// (THE SWIPE below) or the pollutant tabs change what the chart plots while
// it is shown, and the chart moves from the picture on screen to the new one
// on its own clock (TimelineChart's THE MORPH has the rule per kind); the
// conditions' glyph strip swaps each glyph that changes by halves (the old
// one shrinks away, the new one grows) and keeps the ones both days share.
// Texts -- the header, the chips' figures, the blocks below -- swap at once.
// Nothing is created or destroyed by a day change: the chart's parts, the
// strip's glyphs, the species rows and the scale table are pools.
//
// THE SWIPE. One MouseArea over the whole detail reads every wheel event,
// the popup's rule (WeatherPopup's THE SWIPE RULE, docs/contracts/gestures.md):
// the gesture's owner is latched from what is under the pointer when it
// begins, its axis from the first events that clearly lead (x1.2), both held
// until the fingers lift (the zero-delta event) or `gestureIdleEndMs` of
// silence.
//
//   owner      axis x                       axis y
//   day strip  steps the selected day       scrolls the strip
//   detail     steps the selected day       nothing (the host's)
//
// A step is counted by WheelStepper against a mouse notch
// (`swipeNotchThreshold`) or, for a touchpad (a pixel delta on that axis;
// Wayland sends angle deltas too), against `swipePixelThreshold`, with
// `swipeStepCooldownMs` between steps; the day clamps at the first and last
// (no wrap) and the strip brings the new chip into view. An event this used
// is accepted, anything else passes on. The strip's ScrollDressing reads no
// wheel of its own: with two readers of one event a sideways swipe's
// drifting y would scroll the strip under it.
//
// THE STICKY GESTURE (as WeatherPopup): a day with fewer blocks (no KMI text,
// no pollen) is shorter, and a host that clips this content stops delivering
// to a pointer the shrink left outside. `swipeGestureActive` and
// `gestureHoldWidth/Height` say how far the reader reaches while a gesture
// lives; a host puts a catcher under the body and hands `gestureWheel(ev)`
// every wheel outside it, in this item's coordinates.
//
// Sections, one carved card each, 12 px apart and 12 px from the edge:
//
//   header    the metric's title and unit, the figure at the scrubbed hour
//             (a fixed slot, so the title never moves), and the hour's band
//             name with its dot when the metric has bands;
//   days      sixteen chips (weekday, a 24 px glyph, the day's figures) in a
//             strip that scrolls on the vertical wheel (THE SWIPE's reader;
//             the Flickable is not interactive and its ScrollDressing only
//             paints the fades); the selected chip is carved a shade darker
//             and stands on the padding line, and it slides into view with
//             the day's morph;
//   chart     the TimelineChart of the day (WeatherSeries.js builds the
//             spec; hover drives the header), or the glyph strip for
//             conditions;
//   block     what only this metric has: the pollutant selector, the pollen
//             species, the sun and moon figures, KMI's text for the day;
//   about     the scale's own description and source, and its table.
//
// The spec is pure data with colour ROLES; `_col` resolves them to Theme
// tokens when the spec is handed to the chart, which is the one place the
// theme enters. Figures sit in FontMetrics-measured slots and swap instantly;
// only presence fades (the band, a chip's carve, a chip's hover wash).
// `morphMs` is the day change's clock; the swipe's knobs are below it.
// =============================================================================
Item {
    id: root

    // ---- Contract (§5) -------------------------------------------------------
    property var service: null
    property var secondaryKey: null
    property rect secondaryCutout: Qt.rect(0, 0, 0, 0)
    property string fontFamily: "Inter"
    property bool compact: false

    // ---- Layout knobs ---------------------------------------------------------
    property real padding: 12
    property real cardPadding: 12
    property real cardRadius: root.compact ? 10 : 14
    property real chipRadius: root.compact ? 8 : 10
    property real chipWidth: root.compact ? 44 : 50
    property real chipGap: 4
    property real chartHeight: root.compact ? 150 : 176
    property int titleSize: 16
    property int bodySize: 12
    property int figureSize: root.compact ? 10 : 11
    property int fadeMs: 160
    // The day change: every chart's morph, and the strip's slide to the chip.
    property int morphMs: 260
    // THE SWIPE's knobs (see the header). The notch and touchpad detents and
    // the cooldown are CardViewCycler's, so a day steps like a card's view.
    property bool swipeToSwitchDay: true
    property real swipeNotchThreshold: 120
    property real swipePixelThreshold: 1000
    property int swipeStepCooldownMs: 200
    // A device that sends only pixels is scaled into angle units by this.
    property real swipePixelToAngle: 2.5
    property int gestureIdleEndMs: 260
    // The day strip's vertical wheel, per notch of 120 (ScrollDressing's unit).
    property real scrollSpeed: 1.0
    // The minimum y extent of the two range charts (WeatherSeries.js AXIS
    // POLICY): a day narrower than this is drawn against it, about its middle.
    property real temperatureMinSpan: 10
    property real pressureMinSpan: 20

    // ---- The carve --------------------------------------------------------------
    // Bound from WeatherPopup's knobs, so the detail is carved like the popup it
    // grows out of. CARD (widths, falloff, bevel colour): the header, the day
    // strip, the chart, the glyph strip and the blocks. INSET (widths, falloff;
    // the rim takes cardBevelColor): boxes inside a card (the selected day chip)
    // and the pollutant selector's track. The defaults are WeatherPopup's, for
    // a host that binds none of them.
    property real cardBevelWidth: 1
    property real cardShadowWidth: 3
    property real cardShadowFalloff: 1
    property color cardBevelColor: Theme.bevel
    property real insetBevelWidth: 1
    property real insetShadowWidth: 3
    property real insetShadowFalloff: 1
    // The popup's glyph carve as one object (WeatherGlyph.style): keys it
    // lacks keep WeatherGlyph's own defaults.
    property var glyphStyle: ({})
    // One beat of a glyph's flourish, ms (WeatherPopup.glyphFlourishMs). Here a glyph flourishes when the pointer comes onto its
    // day chip or the day is selected, when the scrub lands on its slot of the conditions strip, and the moon under the pointer;
    // each plays to its end whatever the pointer does next.
    property int glyphFlourishMs: 900
    readonly property WeatherGlyphFlourish chipFlourish: WeatherGlyphFlourish {
        host: root
        beatMs: root.glyphFlourishMs
    }

    implicitWidth: root.compact ? 360 : 420
    implicitHeight: root._top + root.padding + column.implicitHeight + root.padding

    readonly property real _top: root.secondaryCutout.height > 0
        ? root.secondaryCutout.y + root.secondaryCutout.height : 0
    // LAID OUT AT THE WIDTH THE DETAIL ASKED FOR, not at the host's easing box. The engine
    // eases the box with an overshoot and hands the content that box as its `width`; text laid out at it re-wraps while the
    // box is a few pixels too wide (the description block would lose a line for a moment and regain it). The launcher,
    // stocks, clipboard and notes lay out at their implicit size; so does this, and the growing box reveals it.
    readonly property real _innerW: root.implicitWidth - 2 * root.padding
    readonly property real _cardInnerW: root._innerW - 2 * root.cardPadding
    // The day strip's room around its chips: a selected chip's bevel is drawn
    // OUTSIDE its rect, so the clip keeps at least that much slack.
    readonly property int _chipSlack: Math.max(2, Math.ceil(root.insetBevelWidth))
    // How far the day strip's viewport reaches into the card's padding at its
    // ends: scrolled chips pass under the padding band (the scroll fade's
    // opaque lead covers it, so they fade out ON the padding line) while a
    // chip at rest stands on it. It stops short of the card's inset shadow:
    // the lead would paint over it (the hourly strip's edgeReach, 8).
    readonly property real _stripReach: Math.max(0, root.cardPadding - root.cardShadowWidth - 1)

    // ---- THE MARGIN IS MEASURED TO INK ------------------------------------------
    // The popup's rule: every card's first
    // ink sits `cardPadding` from its edge, on every side. A text line's box
    // carries the face's ascent above its capitals and its descent under the
    // baseline, so a card of text raises its column by the first line's
    // `top` and ends `foot` under its last baseline -- the capitals start on
    // the padding line and the baseline stands on it (a descender hangs
    // into the padding, as it does in the hero). Whole pixels. The top is
    // WeatherTile's `_titleInkTop` measure for a line that starts at its
    // box's top, on its sample of capitals and ascenders -- except the 16 px
    // title line, measured on CAPITALS AND FIGURES: there Audiowide's
    // ascenders stand 2 px over its capitals, and on the ascender sample a
    // title without one ("Temperature") would sit 14 px down (measured, both
    // faces). The font is read first: tightBoundingRect is a call and
    // captures nothing.
    function _inkOf(fm, sample) {
        const f = fm.font;
        return {
            top: Math.max(0, Math.round(fm.ascent + fm.tightBoundingRect(sample).y)),
            foot: Math.max(0, Math.ceil(fm.height) - Math.round(fm.ascent))
        };
    }
    readonly property var _titleInk: root._inkOf(valueFm, "HT0123456789")
    readonly property var _bodyInk: root._inkOf(bodyFm, "HAbdfhklt")
    readonly property var _figInk: root._inkOf(figureFm, "HAbdfhklt")

    // ---- State from the key ---------------------------------------------------
    property string _metric: "temperature"
    property int _day: 0
    // The key's hour on the key's day; -1 when the key named no hour.
    property int _keyHour: -1
    property int _keyDay: 0
    property string _pollutant: "index"

    // A key lands while the content is hidden: everything at once, any day
    // morph still moving stops where the new key puts it.
    function _applyKey() {
        root._endGesture();
        curtain.stop();
        chart.jump(() => glyphStrip.jump(root._takeKey));
        Qt.callLater(root._ensureChipVisible, false);
    }
    function secondarySwapsInPlace(key) {
        return root._keyShown && !!key && WS.morphsInto(root._metric, key.metric);
    }
    // The first key is applied by Component.onCompleted (the engine's assignment may come before it).
    property bool _keyShown: false
    function _keyChanged() {
        if (root.secondarySwapsInPlace(root.secondaryKey))
            curtain.swap(() => {
                root._endGesture();
                root._change(root._takeKey);
                root._ensureChipVisible(true);
            });
        else
            root._applyKey();
    }
    SwapCurtain {
        id: curtain
    }
    function _takeKey() {
        const k = root.secondaryKey;
        if (!k || typeof k !== "object") {
            root._metric = "temperature";
            root._day = 0;
            root._keyDay = 0;
            root._keyHour = -1;
            return;
        }
        root._metric = typeof k.metric === "string" && k.metric.length > 0 ? k.metric : "temperature";
        const d = typeof k.dayIndex === "number" && isFinite(k.dayIndex) ? Math.max(0, Math.floor(k.dayIndex)) : 0;
        root._day = d;
        root._keyDay = d;
        root._keyHour = typeof k.hourIndex === "number" && isFinite(k.hourIndex) ? Math.floor(k.hourIndex) : -1;
    }

    // ---- The day change ----------------------------------------------------------
    // What the shown chart plots changes inside `fn`: that chart morphs from
    // what it draws, the hidden one simply takes the change.
    function _change(fn) {
        if (root._metric === "conditions")
            chart.jump(() => glyphStrip.morph(fn));
        else
            glyphStrip.jump(() => chart.morph(fn));
    }
    // Select day `d` (clamped: no wrap). Returns whether the day changed.
    function selectDay(d) {
        const n = root._dayCount;
        if (n <= 0 || !isFinite(d))
            return false;
        const c = Math.max(0, Math.min(n - 1, Math.round(d)));
        if (c === root._day)
            return false;
        root._change(() => root._day = c);
        root._ensureChipVisible(true);
        return true;
    }
    // Harness stills: the day morph at linear time t (select, then pin).
    function pinDayMorph(t) {
        chart.pinMorph(t);
        glyphStrip.pinMorph(t);
    }

    // ---- THE SWIPE (see the header) ----------------------------------------------
    readonly property bool swipeGestureActive: root._gestureActive
    readonly property real gestureHoldWidth: root.width
    readonly property real gestureHoldHeight: Math.max(root.height, root._gestureStartH)
    property bool _gestureActive: false
    property string _gestureOwner: ""          // "strip" | "detail"
    property string _gestureAxis: ""           // "" until one axis leads, then "x" | "y"
    property real _gestureStartH: 0
    WheelStepper {
        id: dayStepper
        notchThreshold: root.swipeNotchThreshold
        pixelThreshold: root.swipePixelThreshold
        stepCooldownMs: root.swipeStepCooldownMs
    }
    Timer {
        id: gestureIdleTimer
        interval: root.gestureIdleEndMs
        onTriggered: root._endGesture()
    }
    function _endGesture() {
        gestureIdleTimer.stop();
        dayStepper.end();
        root._gestureActive = false;
        root._gestureOwner = "";
        root._gestureAxis = "";
    }
    // One wheel event (WheelHub's) at (wx, wy) in swipeArea's coordinates.
    // Returns whether it was used.
    function _wheel(wx, wy, ev) {
        const ad = ev.angleDelta, pd = ev.pixelDelta, phase = ev.phase;
        // A mouse: a sideways notch is a day, and so is an upright one over the strip of days.
        if (ev.device === "wheel") {
            if (ad.x === 0 && !swipeArea._over(dayClip, wx, wy))
                return false;
            if (root.swipeToSwitchDay && ev.steps !== 0)
                root.selectDay(root._day + ev.steps);
            return true;
        }
        // Each axis in angle units; `xPixels` says the DEVICE reports pixels
        // (a touchpad), whose steps count against the touchpad detent.
        const xPixels = pd.x !== 0;
        const dx = ad.x !== 0 ? ad.x : pd.x * root.swipePixelToAngle;
        const dy = ad.y !== 0 ? ad.y : pd.y * root.swipePixelToAngle;
        // Zero on both axes is the touchpad's scroll-end: the fingers lifted.
        if (dx === 0 && dy === 0) {
            // The day strip's engine hears the lift (a coast) or the fingers put back (a catch).
            if (phase === Qt.ScrollBegin
                    || (root._gestureOwner === "strip" && root._gestureAxis === "y"))
                root._feedStrip(0, 0, phase);
            root._endGesture();
            return false;
        }
        gestureIdleTimer.restart();
        if (!root._gestureActive) {
            // The owner FIRST: the next lines grow this area, and (wx, wy)
            // are in its geometry from before that.
            root._gestureOwner = swipeArea._over(dayClip, wx, wy) ? "strip" : "detail";
            root._gestureStartH = root.height;
            root._gestureActive = true;
            root._gestureAxis = "";
        }
        if (root._gestureAxis === "") {
            if (Math.abs(dx) > Math.abs(dy) * 1.2)
                root._gestureAxis = "x";
            else if (Math.abs(dy) > Math.abs(dx) * 1.2)
                root._gestureAxis = "y";
        }
        if (root._gestureAxis === "x" && dx !== 0 && root.swipeToSwitchDay) {
            const steps = dayStepper.feed(dx, xPixels);
            if (steps !== 0)
                root.selectDay(root._day + steps);
            return true;
        }
        if (root._gestureAxis === "y" && dy !== 0 && root._gestureOwner === "strip") {
            root._feedStrip(pd.y, ad.y, phase);
            return true;
        }
        return false;
    }
    // For a host that clips this content: a wheel outside it while a
    // gesture lives, in THIS item's coordinates. A forwarded wheel never
    // starts one. Returns whether it was taken.
    function gestureWheel(ev) {
        if (!root._gestureActive || !ev)
            return false;
        root._wheel(ev.x - swipeArea.x, ev.y - swipeArea.y, ev);
        return true;
    }
    onSecondaryKeyChanged: root._keyChanged()
    Component.onCompleted: {
        root._refreshF();
        root._applyKey();
        root._keyShown = true;
        root._model = root._model;      // the creation-time binding ends here (same value): `_takeModel` moves it from now on
    }

    // ---- The data ---------------------------------------------------------------
    // THE MODEL THE DETAIL SHOWS follows the service's, through `_takeModel`: a change of PLACE is a morph of whatever the shown
    // chart plots (the same `_change` the day uses -- the chart snapshots what it draws, holds the target while its inputs move
    // and eases one clock), so switching the location with a detail open moves the chart from the old place's curve to the new
    // one's instead of swapping it. The same place with DATA that just arrived (a fetch landing: PB.morphs) moves the same way; the clock's rebuilds of
    // it, or a model from nothing, are taken at once.
    // Bound for the creation only (the detail is born on the service's model) and assigned from then on.
    property var _model: root.service ? root.service.model : null
    function _takeModel(m) {
        const old = root._model;
        if (old === m)
            return;
        if (old && m && PB.morphs(old, m) && root.morphMs > 0)
            root._change(() => root._model = m);
        else
            root._model = m;
    }
    Connections {
        target: root.service
        function onModelChanged() {
            root._takeModel(root.service.model);
        }
    }
    // The formatter is REFRESHED, not bound. Reading `service.config` is what
    // initialises a host's lazily-bound config object, and a host may rebuild
    // its model in that object's change handler (the mock does): read inside
    // `_spec`'s own evaluation that changed `_model` under it -- a binding
    // loop. Read here instead, on completion and on the config's own signal.
    property var _F: null
    function _refreshF() {
        const cfg = root.service ? root.service.config : null;
        root._F = WM.format(cfg && cfg.units ? cfg.units : ({}));
    }
    onServiceChanged: {
        root._refreshF();
        root._takeModel(root.service ? root.service.model : null);
    }
    Connections {
        target: root.service
        function onConfigChanged() { root._refreshF(); }
    }
    readonly property var _spec: root._F
        ? WS.forDay(root._model, root._metric, root._day, root._F, {
            pollutant: root._pollutant,
            temperatureMinSpan: root.temperatureMinSpan,
            pressureMinSpan: root.pressureMinSpan
        })
        : WS.emptySpec(root._metric, "")
    readonly property int _dayCount: root._model && root._model.daily ? root._model.daily.length : 0
    readonly property bool _twelveHour: !!(root._F && root._F.units && root._F.units.clock === "12h")

    // The hour whose figure the header shows: the pointer's, else the key's
    // hour on the key's day, else none (the day's figures).
    property int _hover: -1
    readonly property int _scrub: root._spec.empty ? -1 : (root._hover >= 0 ? root._hover
        : (root._keyHour >= 0 && root._day === root._keyDay ? root._keyHour : -1))
    readonly property string _value: root._scrub >= 0 ? root._spec.summary.valueAt(root._scrub) : root._spec.summary.dayValue
    readonly property string _line2: {
        if (root._scrub < 0)
            return root._spec.summary.dayLine;
        const label = root._spec.xLabels[root._scrub] !== undefined ? root._spec.xLabels[root._scrub] : "";
        const hourText = root._twelveHour ? label : label + ":00";
        const detail = root._spec.summary.detailAt(root._scrub);
        return hourText + (detail ? " · " + detail : "");
    }
    readonly property var _band: root._scrub >= 0 ? root._spec.summary.bandAt(root._scrub) : root._spec.summary.dayBand
    // The band's name is latched so its presence can fade out still reading.
    property string _bandShown: ""
    property int _bandIndex: 0
    on_BandChanged: {
        if (root._band) {
            root._bandShown = root._band.name;
            root._bandIndex = root._band.band;
        }
    }
    property real _bandF: root._band ? 1 : 0
    Behavior on _bandF {
        NumberAnimation { duration: root.fadeMs; easing.type: Easing.OutCubic }
    }

    // ---- Colour roles -> Theme tokens ------------------------------------------
    function _col(role) {
        if (typeof role !== "string")
            return Theme.textPrimary;
        if (role.indexOf("band:") === 0) {
            const i = parseInt(role.substring(5));
            return Theme.bands[Math.max(0, Math.min(5, isFinite(i) ? i : 0))];
        }
        switch (role) {
        case "accent": return Theme.accent;
        case "textPrimary": return Theme.textPrimary;
        case "textMuted": return Theme.textMuted;
        case "textFaint": return Theme.textFaint;
        case "sun": return Theme.weatherSun;
        case "cloud": return Theme.weatherCloud;
        case "rain": return Theme.weatherRain;
        case "snow": return Theme.weatherSnow;
        case "storm": return Theme.weatherStorm;
        case "fog": return Theme.weatherFog;
        case "night": return Theme.weatherNight;
        default: return Theme.textPrimary;
        }
    }
    readonly property var _chartSeries: root._spec.series.map(s => ({
        id: s.id, kind: s.kind, values: s.values, bandLow: s.bandLow, width: s.width, dotted: s.dotted,
        gradient: s.gradient, range: s.range, color: root._col(s.color)
    }))
    readonly property var _chartThresholds: root._spec.thresholds.map(t => ({ value: t.value, label: t.label, color: root._col(t.color) }))
    readonly property var _chartStops: root._spec.gradientStops.map(g => ({ value: g.value, color: root._col(g.color) }))

    // ---- Slots ------------------------------------------------------------------
    FontMetrics {
        id: valueFm
        font.family: root.fontFamily
        font.pixelSize: root.titleSize
        font.bold: true
    }
    function _widestDigit(fm) {
        let wide = "0", bw = 0;
        for (const d of "0123456789") {
            const w = fm.advanceWidth(d);
            if (w > bw) { bw = w; wide = d; }
        }
        return wide;
    }
    // Reads the metrics' font first (the call alone captures nothing). The
    // slot is the template's width (digits re-measured with the widest; a
    // LIST of templates takes its widest member, measured here in the value's
    // own face: the conditions pass every label WM.conditionText can print),
    // or the value's own when that is wider -- CAPPED so the TITLE keeps its
    // whole width: the title has priority on the line, the value takes the
    // remainder and elides if it must (the conditions' longest label on the
    // 360 px layout).
    readonly property real _valueW: {
        const f = valueFm.font;
        const fb = bodyFm.font;
        const wide = root._widestDigit(valueFm);
        const t = root._spec.summary.valueTemplate;
        const tpls = Array.isArray(t) ? t : [t || "88"];
        let want = valueFm.advanceWidth(root._value);
        for (const one of tpls)
            want = Math.max(want, valueFm.advanceWidth(String(one).replace(/[0-9]/g, wide)));
        const titleW = valueFm.advanceWidth(root._spec.title)
                     + (root._spec.unit.length > 0 ? bodyFm.advanceWidth(root._spec.unit) + 6 : 0);
        const cap = root._cardInnerW - Math.ceil(titleW) - 12;
        return Math.max(24, Math.ceil(Math.min(want, cap)));
    }
    FontMetrics {
        id: bodyFm
        font.family: root.fontFamily
        font.pixelSize: root.bodySize
    }
    FontMetrics {
        id: figureFm
        font.family: root.fontFamily
        font.pixelSize: root.figureSize
    }
    // The scale table's two measured columns.
    readonly property real _scaleNameW: {
        const f = bodyFm.font;
        let w = 0;
        for (const r of root._spec.scale)
            w = Math.max(w, bodyFm.advanceWidth(r.name));
        return Math.ceil(w);
    }
    readonly property real _scaleRangeW: {
        const f = figureFm.font;
        let w = 0;
        for (const r of root._spec.scale)
            w = Math.max(w, figureFm.advanceWidth(r.range));
        return Math.ceil(w);
    }

    // ---- The day strip's scroll ---------------------------------------------------
    // The selected chip into view, sliding with the day's morph when
    // `animated` (it is where the strip is GOING that counts: a second step
    // during the slide measures from the first one's end).
    function _ensureChipVisible(animated) {
        const pitch = root.chipWidth + root.chipGap;
        // The chip between the padding lines and clear of the scroll fades
        // (at either end of the strip the fade there is off anyway).
        const edge = root._stripReach + dayDressing.fadeHeight;
        const x = root._stripReach + root._day * pitch;
        const maxX = Math.max(0, dayFlick.contentWidth - dayFlick.width);
        const from = chipFollow.running ? chipFollow.to : dayFlick.contentX;
        let cx = from;
        if (x - edge < cx)
            cx = x - edge;
        else if (x + root.chipWidth + edge > cx + dayFlick.width)
            cx = x + root.chipWidth + edge - dayFlick.width;
        cx = Math.max(0, Math.min(maxX, cx));
        chipFollow.stop();
        dayDressing.stopMotion();
        if (animated === true && root.morphMs > 0 && Math.abs(cx - dayFlick.contentX) > 0.5) {
            chipFollow.from = dayFlick.contentX;
            chipFollow.to = cx;
            chipFollow.start();
        } else {
            dayFlick.contentX = cx;
        }
    }
    // The wheel's y on the strip (a mouse has no x wheel): the dressing's
    // engine glides a notch, follows the fingers and coasts after their lift.
    // A glide or a coast of the day strip is under way (a probe waits for it).
    readonly property bool scrolling: dayDressing.moving
    function _feedStrip(px, ad, phase) {
        chipFollow.stop();
        dayDressing.wheel({ pixelDelta: Qt.point(0, px), angleDelta: Qt.point(0, ad), phase: phase });
    }
    NumberAnimation {
        id: chipFollow
        target: dayFlick
        property: "contentX"
        duration: root.morphMs
        easing.type: Easing.OutCubic
    }

    // =========================================================================
    // Components
    // =========================================================================
    component Card: ShadowBox {
        baseRadius: root.cardRadius
        surfaceColor: Theme.surface
        backgroundColor: Theme.listBox
        bevelColor: root.cardBevelColor
        shadowColor: Theme.border
        bevelWidth: root.cardBevelWidth
        shadowWidth: root.cardShadowWidth
        shadowFalloff: root.cardShadowFalloff
    }

    component BandDot: Rectangle {
        property int band: 0
        width: 8
        height: 8
        radius: 4
        color: Theme.bands[Math.max(0, Math.min(5, band))]
    }

    // One day of the strip.
    component DayChip: Item {
        id: chip
        required property int index
        readonly property var day: root._model && root._model.daily ? root._model.daily[chip.index] : null
        readonly property bool selected: chip.index === root._day
        // a day picked (a click, a swipe to it) flourishes its glyph; the chip that is selected as the detail is built does not
        property bool _built: false
        Component.onCompleted: chip._built = true
        onSelectedChanged: if (chip.selected && chip._built) root.chipFlourish.play(chip.index, chipGlyph.flourishBeats)
        readonly property var figures: WS.chipText(root._model, root._metric, chip.index, root._F)
        width: root.chipWidth
        height: chipCol.implicitHeight + 12

        property real hoverF: chipArea.containsMouse ? 1 : 0
        Behavior on hoverF {
            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
        }
        property real selectedF: chip.selected ? 1 : 0
        Behavior on selectedF {
            NumberAnimation { duration: root.fadeMs; easing.type: Easing.OutCubic }
        }

        // The hover wash: the sunk panel colour lifted in by the fraction.
        Rectangle {
            anchors.fill: parent
            radius: root.chipRadius
            color: Mix.c(Qt.rgba(Theme.panelSunk.r, Theme.panelSunk.g, Theme.panelSunk.b, 0), Theme.panelSunk, chip.hoverF * (1 - chip.selectedF))
        }
        // The carve, present while selected.
        ShadowBox {
            anchors.fill: parent
            opacity: chip.selectedF
            visible: opacity > 0.001
            baseRadius: root.chipRadius
            surfaceColor: Theme.listBox
            backgroundColor: Theme.headerBox
            bevelColor: root.cardBevelColor
            shadowColor: Theme.headerBoxShadow
            bevelWidth: root.insetBevelWidth
            shadowWidth: root.insetShadowWidth
            shadowFalloff: root.insetShadowFalloff
        }
        Column {
            id: chipCol
            anchors.centerIn: parent
            spacing: 2
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: chip.day ? (chip.day.isToday ? "Today" : chip.day.weekday) : ""
                color: chip.selected ? Theme.textPrimary : Theme.textMuted
                font.family: root.fontFamily
                font.pixelSize: root.figureSize
            }
            WeatherGlyph {
                id: chipGlyph
                posing: root.chipFlourish.on(chip.index)
                poseBeat: root.chipFlourish.beatOf(chip.index)
                anchors.horizontalCenter: parent.horizontalCenter
                style: root.glyphStyle
                size: 24
                kind: chip.day && chip.day.day && chip.day.day.kind ? chip.day.day.kind : "clear"
                intensity: chip.day && chip.day.day && typeof chip.day.day.intensity === "number" ? chip.day.day.intensity : 1
                night: false
                shower: !!(chip.day && chip.day.day && chip.day.day.shower)
                moonPhase: chip.day && typeof chip.day.moonPhase === "number" ? chip.day.moonPhase : 0.5
            }
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 3
                Text {
                    text: chip.figures.a
                    color: Theme.textPrimary
                    font.family: root.fontFamily
                    font.pixelSize: root.figureSize - 1
                }
                Text {
                    visible: chip.figures.b.length > 0
                    text: chip.figures.b
                    color: Theme.textFaint
                    font.family: root.fontFamily
                    font.pixelSize: root.figureSize - 1
                }
            }
        }
        MouseArea {
            id: chipArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onContainsMouseChanged: root.chipFlourish.entered(chipArea)
            onPositionChanged: if (root.chipFlourish.hovered(chipArea)) root.chipFlourish.play(chip.index, chipGlyph.flourishBeats)
            onClicked: root.selectDay(chip.index)
        }
    }

    // The conditions metric's timeline: a glyph every two hours in a carved
    // box, the scrubbed slot marked, hover reporting the hour.
    //
    // ITS MORPH (a day change): per cell up to two glyphs, each with a weight
    // on the strip's own clock; a glyph's scale is 2w - 1, so the leaving one
    // is gone in the first half and the arriving one grows in the second --
    // the hourly strip's glyph-slot rule -- and a glyph both days share (same
    // kind, intensity, night, shower, phase) stays as it is. At most one glyph
    // of a cell is ever visible, so a morph that lands during another keeps
    // the visible one and the target: two items per cell always suffice.
    component GlyphStrip: Item {
        id: strip
        property var row: []
        property var labels: []
        property int markerIndex: -1
        readonly property int slots: 12
        readonly property real pad: root.cardPadding
        readonly property real slotW: (strip.width - 2 * strip.pad) / strip.slots
        readonly property real glyphSize: Math.min(26, Math.floor(strip.slotW - 4))
        // the slot the scrub lands on flourishes its glyph, to its end: a sweep along the strip leaves a wake of them
        readonly property WeatherGlyphFlourish slotFlourish: WeatherGlyphFlourish {
            host: strip
            beatMs: root.glyphFlourishMs
        }
        onMarkerIndexChanged: {
            const slot = strip.markerIndex >= 0 ? Math.floor(strip.markerIndex / 2) : -1;
            const cell = slot >= 0 ? slotRep.itemAt(slot) : null;
            if (cell && strip.visible)
                strip.slotFlourish.play(slot, cell.beats); // qmllint disable missing-property
        }
        // The scrubbed slot's ground (2 px around the glyph) stands on the
        // padding line; the hour labels' baseline on the foot's.
        readonly property real naturalHeight: strip.pad * 2 + strip.glyphSize + 4 + Math.ceil(figureFm.height) - root._figInk.foot
        height: strip.naturalHeight

        function hourOf(slot) {
            const a = slot * 2, b = slot * 2 + 1;
            if (strip.row[a]) return a;
            if (strip.row[b]) return b;
            return a;
        }

        function _keyOf(g) {
            return g.kind + "|" + g.intensity + "|" + (g.night ? 1 : 0) + "|" + (g.shower ? 1 : 0) + "|" + Math.round(g.moonPhase * 100);
        }
        function _build() {
            const cells = [];
            for (let c = 0; c < strip.slots; c++) {
                const g = strip.row[strip.hourOf(c)] || null;
                cells.push(g ? [{ g: g, k: strip._keyOf(g), w: 1 }] : []);
            }
            return cells;
        }
        function _lerp(A, B, e) {
            if (!A || e >= 1)
                return B;
            if (e <= 0)
                return A;
            const out = [];
            for (let c = 0; c < strip.slots; c++) {
                const a = A[c] || [], b = B[c] || [];
                const bk = b.length ? b[0].k : null;
                const cell = [];
                for (const x of a) {
                    const kept = x.k === bk;
                    // A leaving glyph already at or under half is invisible
                    // for the rest of the clock: it is dropped.
                    if (kept || x.w > 0.5)
                        cell.push({ g: x.g, k: x.k, w: x.w + ((kept ? 1 : 0) - x.w) * e });
                }
                if (bk !== null && !a.some(x => x.k === bk))
                    cell.push({ g: b[0].g, k: bk, w: e });
                out.push(cell);
            }
            return out;
        }
        property bool _batching: false
        property var _held: null
        property var _from: null
        property bool _morphing: false
        property int _morphSerial: 0
        readonly property var _target: strip._batching && strip._held ? strip._held : strip._build()
        readonly property var _frame: strip._morphing && strip._from ? strip._lerp(strip._from, strip._target, stripClock.progress) : strip._target
        ViewBlend {
            id: stripClock
            count: 2
            target: strip._morphSerial % 2
            durationMs: root.morphMs
            onTicked: {
                if (strip._morphing && stripClock.progress >= 1)
                    strip._morphing = false;
            }
        }
        function morph(fn) {
            const from = strip._frame;
            strip._held = strip._target;
            strip._batching = true;
            try {
                if (fn)
                    fn();
            } finally {
                strip._from = from;
                strip._morphSerial++;
                strip._morphing = true;
                strip._batching = false;
            }
        }
        function jump(fn) {
            stripClock.pin(1);
            strip._morphing = false;
            strip._held = strip._target;
            strip._batching = true;
            try {
                if (fn)
                    fn();
            } finally {
                strip._batching = false;
            }
        }
        function pinMorph(t) {
            stripClock.pin(t);
        }

        Card { anchors.fill: parent }
        Rectangle {
            visible: strip.markerIndex >= 0
            x: Math.round(strip.pad + Math.floor(strip.markerIndex / 2) * strip.slotW)
            y: strip.pad
            width: Math.round(strip.slotW)
            height: strip.glyphSize + 4
            radius: 6
            color: Theme.headerBox
        }
        Repeater {
            id: slotRep
            model: strip.slots
            delegate: Item {
                id: cell
                required property int index
                readonly property var entries: strip._frame[cell.index] || []
                readonly property real beats: Math.max(glyphA.visible ? glyphA.flourishBeats : 0, glyphB.visible ? glyphB.flourishBeats : 0)
                x: strip.pad + cell.index * strip.slotW
                y: strip.pad + 2
                width: strip.slotW
                height: strip.glyphSize
                WeatherGlyph {
                    id: glyphA
                    posing: strip.slotFlourish.on(cell.index)
                    poseBeat: strip.slotFlourish.beatOf(cell.index)
                    readonly property var en: cell.entries.length > 0 ? cell.entries[0] : null
                    scale: glyphA.en ? Math.max(0, Math.min(1, 2 * glyphA.en.w - 1)) : 0
                    visible: glyphA.scale > 0.001
                    anchors.centerIn: parent
                    style: root.glyphStyle
                    size: strip.glyphSize
                    kind: glyphA.en ? glyphA.en.g.kind : "clear"
                    intensity: glyphA.en ? glyphA.en.g.intensity : 1
                    night: glyphA.en ? glyphA.en.g.night : false
                    shower: glyphA.en ? glyphA.en.g.shower : false
                    moonPhase: glyphA.en ? glyphA.en.g.moonPhase : 0.5
                }
                WeatherGlyph {
                    id: glyphB
                    posing: strip.slotFlourish.on(cell.index)
                    poseBeat: strip.slotFlourish.beatOf(cell.index)
                    readonly property var en: cell.entries.length > 1 ? cell.entries[1] : null
                    scale: glyphB.en ? Math.max(0, Math.min(1, 2 * glyphB.en.w - 1)) : 0
                    visible: glyphB.scale > 0.001
                    anchors.centerIn: parent
                    style: root.glyphStyle
                    size: strip.glyphSize
                    kind: glyphB.en ? glyphB.en.g.kind : "clear"
                    intensity: glyphB.en ? glyphB.en.g.intensity : 1
                    night: glyphB.en ? glyphB.en.g.night : false
                    shower: glyphB.en ? glyphB.en.g.shower : false
                    moonPhase: glyphB.en ? glyphB.en.g.moonPhase : 0.5
                }
                Text {
                    x: Math.round((parent.width - width) / 2)
                    y: strip.glyphSize + 2
                    text: strip.labels[cell.index * 2] !== undefined ? strip.labels[cell.index * 2] : ""
                    color: Theme.textFaint
                    font.family: root.fontFamily
                    font.pixelSize: root.figureSize
                }
            }
        }
        MouseArea {
            x: strip.pad
            y: strip.pad
            width: Math.max(0, strip.width - 2 * strip.pad)
            height: strip.glyphSize + 4
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            cursorShape: undefined   // clicks pass through: the cursor is what lies under it (a MouseArea owns an Arrow)
            onPositionChanged: mouse => {
                const s = Math.max(0, Math.min(strip.slots - 1, Math.floor(mouse.x / strip.slotW)));
                root._hover = strip.hourOf(s);
            }
            onExited: root._hover = -1
        }
    }

    // A label over a figure, for the sun/moon block.
    component Figure: Column {
        property string label: ""
        property string value: ""
        spacing: 1
        Text {
            text: parent.label
            color: Theme.textFaint
            font.family: root.fontFamily
            font.pixelSize: root.figureSize
        }
        Text {
            text: parent.value
            color: Theme.textPrimary
            font.family: root.fontFamily
            font.pixelSize: root.bodySize
        }
    }

    // =========================================================================
    // The content
    // =========================================================================
    // A POSITIONER HEARS NOTHING FROM A CHILD WHOSE `visible` FLIPS WHILE AN
    // ANCESTOR IS HIDDEN: the child's effective visibility did not change, so
    // no signal fires and the Column keeps its old layout (measured: a pool's
    // rows made visible under a hidden host left the Column at 0 px, and
    // forceLayout() does not help). A host swaps this content's key while it
    // is hidden and sizes its box from the height it reads then, so every
    // conditional child of a positioner here ALSO collapses by geometry
    // (height or width 0 when absent): a size change is a signal the
    // positioner hears, hidden or not.
    Column {
        id: column
        x: root.padding
        y: root._top + root.padding
        width: root._innerW
        spacing: root.padding

        // ---- (a) header --------------------------------------------------------
        Card {
            id: headerCard
            opacity: curtain.shown
            objectName: "header"
            width: parent.width
            height: headerCol.implicitHeight - root._titleInk.top - root._bodyInk.foot + 2 * root.cardPadding
            Column {
                id: headerCol
                x: root.cardPadding
                y: root.cardPadding - root._titleInk.top
                width: root._cardInnerW
                spacing: 2
                Item {
                    width: parent.width
                    height: Math.max(titleRow.implicitHeight, valueText.implicitHeight)
                    Row {
                        id: titleRow
                        spacing: 6
                        width: parent.width - root._valueW - 12
                        Text {
                            id: titleText
                            text: root._spec.title
                            color: Theme.textPrimary
                            font.family: root.fontFamily
                            font.pixelSize: root.titleSize
                            font.bold: true
                            elide: Text.ElideRight
                            width: Math.min(implicitWidth, parent.width - (root._spec.unit.length > 0 ? unitText.implicitWidth + 6 : 0))
                        }
                        Text {
                            id: unitText
                            visible: root._spec.unit.length > 0
                            text: root._spec.unit
                            color: Theme.textMuted
                            font.family: root.fontFamily
                            font.pixelSize: root.bodySize
                            anchors.baseline: titleText.baseline
                        }
                    }
                    Text {
                        id: valueText
                        x: parent.width - width
                        width: root._valueW
                        horizontalAlignment: Text.AlignRight
                        text: root._value
                        elide: Text.ElideRight
                        color: Theme.textPrimary
                        font.family: root.fontFamily
                        font.pixelSize: root.titleSize
                        font.bold: true
                        // Same face and size as the title, whose Row sits at
                        // y 0: the baselines coincide without an anchor
                        // (the title is not a sibling, it is in the Row).
                        y: 0
                    }
                }
                Item {
                    width: parent.width
                    height: Math.max(line2.implicitHeight, bandRow.implicitHeight)
                    Text {
                        id: line2
                        width: parent.width - (root._bandF > 0.001 ? bandRow.width + 12 : 0)
                        text: root._line2
                        color: Theme.textMuted
                        font.family: root.fontFamily
                        font.pixelSize: root.bodySize
                        elide: Text.ElideRight
                    }
                    Row {
                        id: bandRow
                        x: parent.width - width
                        spacing: 6
                        opacity: root._bandF
                        visible: opacity > 0.001
                        anchors.verticalCenter: line2.verticalCenter
                        Text {
                            text: root._bandShown
                            color: Theme.textMuted
                            font.family: root.fontFamily
                            font.pixelSize: root.bodySize
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        BandDot {
                            band: root._bandIndex
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }
            }
        }

        // ---- (b) the day strip -------------------------------------------------
        Card {
            id: dayCard
            objectName: "days"
            width: parent.width
            // The chips' rects stand on the padding line (a selected chip's
            // carve is the strip's first ink, as a list row's ground is);
            // the viewport keeps the chips' bevel slack above and below.
            visible: root._dayCount > 0
            height: root._dayCount > 0 ? dayRow.height + 2 * root.cardPadding : 0
            Item {
                id: dayClip
                // `_stripReach` into the padding at the ends and the bevel's
                // slack above and below: the clip's edge is never a chip's
                // carved edge (the bevel band lives outside a box).
                x: root.cardPadding - root._stripReach
                y: root.cardPadding - root._chipSlack
                width: parent.width - 2 * dayClip.x
                height: dayRow.height + 2 * root._chipSlack
                clip: true
                Flickable {
                    id: dayFlick
                    anchors.fill: parent
                    contentWidth: dayRow.width + 2 * root._stripReach
                    contentHeight: height
                    interactive: false
                    boundsBehavior: Flickable.StopAtBounds
                    Row {
                        id: dayRow
                        x: root._stripReach
                        y: root._chipSlack
                        spacing: root.chipGap
                        Repeater {
                            model: root._dayCount
                            delegate: DayChip {}
                        }
                    }
                }
                // Paint only: the detail's one wheel reader scrolls the strip.
                ScrollDressing {
                    id: dayDressing
                    flick: dayFlick
                    orientation: Qt.Horizontal
                    fadeHeight: 24
                    fadeLead: root._stripReach
                    ground: Theme.listBox
                    wheelEnabled: false
                    scrollSpeed: root.scrollSpeed
                }
            }
        }

        // ---- (c) the chart -------------------------------------------------------
        TimelineChart {
            id: chart
            objectName: "chart"
            morphMs: root.morphMs
            visible: root._metric !== "conditions"
            width: parent.width
            height: root._metric !== "conditions" ? root.chartHeight : 0
            fontFamily: root.fontFamily
            compact: root.compact
            radius: root.cardRadius
            padding: root.cardPadding
            bevelWidth: root.cardBevelWidth
            shadowWidth: root.cardShadowWidth
            shadowFalloff: root.cardShadowFalloff
            bevelColor: root.cardBevelColor
            series: root._chartSeries
            xLabels: root._spec.xLabels
            xLabelEvery: 3
            thresholds: root._chartThresholds
            gradientStops: root._chartStops
            yMin: root._spec.yMin
            yMax: root._spec.yMax
            yMaxFloor: root._spec.yMaxFloor
            yMinSpan: root._spec.yMinSpan
            yTicks: root._spec.yTicks
            yNiceSteps: root._spec.yNiceSteps
            yFormat: root._spec.yFormat
            markerIndex: root._scrub
            nowIndex: root._spec.nowIndex
            emptyText: root._spec.empty ? root._spec.emptyText : ""
            onHovered: index => root._hover = index
        }
        GlyphStrip {
            id: glyphStrip
            objectName: "glyphs"
            visible: root._metric === "conditions"
            width: parent.width
            height: root._metric === "conditions" ? glyphStrip.naturalHeight : 0
            row: root._spec.glyphRow
            labels: root._spec.xLabels
            markerIndex: root._scrub
        }

        // ---- (d) the metric's own block ----------------------------------------------
        TabSelector {
            objectName: "pollutants"
            opacity: curtain.shown
            visible: root._metric === "airQuality" && root._spec.pollutants.length > 0
            width: parent.width
            height: root._metric === "airQuality" && root._spec.pollutants.length > 0 ? 30 : 0
            tabs: root._spec.pollutants
            currentTab: root._pollutant
            onTabChanged: id => root._change(() => root._pollutant = id)
            fontFamily: root.fontFamily
            fontPixelSize: root.figureSize
            swipeSelfHandled: false
            trackRadiusOverride: root.cardRadius
            trackBevelWidth: root.insetBevelWidth
            trackShadowWidth: root.insetShadowWidth
            trackShadowFalloff: root.insetShadowFalloff
            trackSurfaceColor: Theme.surface
            trackBevelColor: root.cardBevelColor
            trackShadowColor: Theme.border
            trackBackgroundColor: Theme.listBox
            pillSurfaceColor: Theme.listBox
            pillBevelColor: Theme.accentBevel
            pillShadowColor: Theme.shadowDeep
            pillBackgroundColor: Theme.accent
            textColor: Theme.textPrimary
            activeTextColor: Theme.textOnAccent
        }

        Card {
            objectName: "species"
            opacity: curtain.shown
            visible: root._metric === "pollen" && root._spec.speciesRows.length > 0
            width: parent.width
            // A row is its text's line and 2 px above and below.
            height: root._metric === "pollen" && root._spec.speciesRows.length > 0
                ? speciesCol.implicitHeight - (2 + root._bodyInk.top) - (2 + root._bodyInk.foot) + 2 * root.cardPadding : 0
            Column {
                id: speciesCol
                x: root.cardPadding
                y: root.cardPadding - 2 - root._bodyInk.top
                width: root._cardInnerW
                spacing: 4
                // A pool (a day change creates nothing); the rows past the
                // day's list are hidden, and a Column skips them.
                Repeater {
                    model: Math.max(8, root._spec.speciesRows.length)
                    delegate: Item {
                        id: sp
                        required property int index
                        readonly property var r: root._spec.speciesRows[sp.index] || ({ name: "", levelName: "", band: -1, conc: "" })
                        visible: sp.index < root._spec.speciesRows.length
                        width: parent.width
                        height: sp.index < root._spec.speciesRows.length ? Math.ceil(bodyFm.height) + 4 : 0
                        Text {
                            x: 0
                            anchors.verticalCenter: parent.verticalCenter
                            text: sp.r.name
                            color: Theme.textPrimary
                            font.family: root.fontFamily
                            font.pixelSize: root.bodySize
                        }
                        Row {
                            x: parent.width - width
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 8
                            Text {
                                text: sp.r.levelName
                                color: Theme.textMuted
                                font.family: root.fontFamily
                                font.pixelSize: root.figureSize
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            BandDot {
                                visible: sp.r.band >= 0
                                width: sp.r.band >= 0 ? 8 : 0
                                band: sp.r.band
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                width: 40
                                horizontalAlignment: Text.AlignRight
                                text: sp.r.conc
                                color: Theme.textPrimary
                                font.family: root.fontFamily
                                font.pixelSize: root.figureSize
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                    }
                }
            }
        }

        Card {
            visible: root._metric === "sunMoon" && root._spec.sunMoon !== null
            width: parent.width
            height: root._metric === "sunMoon" && root._spec.sunMoon !== null
                ? sunMoonRow.implicitHeight - root._figInk.top - root._bodyInk.foot + 2 * root.cardPadding : 0
            readonly property var sm: root._spec.sunMoon || ({
                sunrise: "", sunset: "", daylight: "", sunshine: "", moonrise: "", moonset: "",
                moonPhase: 0.5, moonName: "", illumination: ""
            })
            id: sunMoonCard
            opacity: curtain.shown
            objectName: "sunMoon"
            Row {
                id: sunMoonRow
                x: root.cardPadding
                y: root.cardPadding - root._figInk.top
                width: root._cardInnerW
                spacing: 12
                Grid {
                    columns: 2
                    columnSpacing: 16
                    rowSpacing: 6
                    width: parent.width - moonCol.width - 12
                    Figure { label: "Sunrise"; value: sunMoonCard.sm.sunrise }
                    Figure { label: "Sunset"; value: sunMoonCard.sm.sunset }
                    Figure { label: "Daylight"; value: sunMoonCard.sm.daylight }
                    Figure { label: "Sunshine"; value: sunMoonCard.sm.sunshine }
                    Figure { label: "Moonrise"; value: sunMoonCard.sm.moonrise }
                    Figure { label: "Moonset"; value: sunMoonCard.sm.moonset }
                }
                Column {
                    id: moonCol
                    spacing: 4
                    width: 96
                    WeatherGlyph {
                        id: cardMoon
                        posing: moonFlourish.playing
                        poseBeat: moonFlourish.t / Math.max(1, root.glyphFlourishMs)
                        anchors.horizontalCenter: parent.horizontalCenter
                        style: root.glyphStyle
                        size: 40
                        kind: "moon"
                        night: true
                        moonPhase: sunMoonCard.sm.moonPhase
                        // under the pointer it rocks (the bar glyphs' hover rule: once per entry, once the pointer moves)
                        GlyphFlourish {
                            id: moonFlourish
                            host: cardMoon
                            armed: cardMoon.flourishBeats > 0
                            ms: Math.max(1, Math.round(root.glyphFlourishMs * cardMoon.flourishBeats))
                            overlap: "ignore"
                            hoverArea: moonHover
                        }
                        MouseArea {
                            id: moonHover
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.NoButton
                            cursorShape: undefined   // clicks pass through: the cursor is what lies under it (a MouseArea owns an Arrow)
                        }
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: sunMoonCard.sm.moonName
                        color: Theme.textPrimary
                        font.family: root.fontFamily
                        font.pixelSize: root.figureSize
                        horizontalAlignment: Text.AlignHCenter
                        width: parent.width
                        wrapMode: Text.Wrap
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: sunMoonCard.sm.illumination + " lit"
                        color: Theme.textMuted
                        font.family: root.fontFamily
                        font.pixelSize: root.figureSize
                    }
                }
            }
        }

        Card {
            objectName: "kmi"
            visible: root._metric === "conditions" && !!root._spec.kmiText
            opacity: curtain.shown
            width: parent.width
            height: root._metric === "conditions" && !!root._spec.kmiText
                ? kmiCol.implicitHeight - root._figInk.top - root._bodyInk.foot + 2 * root.cardPadding : 0
            Column {
                id: kmiCol
                x: root.cardPadding
                y: root.cardPadding - root._figInk.top
                width: root._cardInnerW
                spacing: 2
                Text {
                    text: "KMI forecast"
                    color: Theme.textFaint
                    font.family: root.fontFamily
                    font.pixelSize: root.figureSize
                }
                Text {
                    width: parent.width
                    text: root._spec.kmiText || ""
                    color: Theme.textPrimary
                    font.family: root.fontFamily
                    font.pixelSize: root.bodySize
                    wrapMode: Text.Wrap
                }
            }
        }

        // ---- (e) about and the scale ---------------------------------------------
        Card {
            objectName: "about"
            visible: root._spec.about !== null
            opacity: curtain.shown
            width: parent.width
            height: root._spec.about !== null
                ? aboutCol.implicitHeight - root._bodyInk.top - root._figInk.foot + 2 * root.cardPadding : 0
            Column {
                id: aboutCol
                x: root.cardPadding
                y: root.cardPadding - root._bodyInk.top
                width: root._cardInnerW
                spacing: 6
                Text {
                    width: parent.width
                    text: root._spec.about ? root._spec.about.text : ""
                    color: Theme.textPrimary
                    font.family: root.fontFamily
                    font.pixelSize: root.bodySize
                    wrapMode: Text.Wrap
                }
                Text {
                    width: parent.width
                    text: root._spec.about && root._spec.about.source ? "Source: " + root._spec.about.source : ""
                    visible: text.length > 0
                    height: text.length > 0 ? implicitHeight : 0
                    color: Theme.textFaint
                    font.family: root.fontFamily
                    font.pixelSize: root.figureSize
                    wrapMode: Text.Wrap
                }
                Item {
                    width: parent.width
                    height: root._spec.scale.length > 0 ? 4 : 0
                    visible: root._spec.scale.length > 0
                }
                // A pool, as the species rows.
                Repeater {
                    model: Math.max(16, root._spec.scale.length)
                    delegate: Item {
                        id: sr
                        required property int index
                        readonly property var r: root._spec.scale[sr.index] || ({ band: 0, name: "", range: "", advice: "" })
                        visible: sr.index < root._spec.scale.length
                        readonly property real adviceX: 8 + 8 + root._scaleNameW + 10 + root._scaleRangeW + 10
                        width: parent.width
                        // The advice's own condition, not `adviceText.visible`: that
                        // is EFFECTIVE visibility, false whenever an ancestor is
                        // hidden, so a detail measured while its host hid it
                        // would collapse every row to one line (657 px for 806).
                        height: sr.index < root._spec.scale.length
                            ? Math.max(Math.ceil(bodyFm.height), sr.r.advice.length > 0 ? adviceText.implicitHeight : 0) : 0
                        BandDot {
                            x: 0
                            y: Math.round((Math.ceil(bodyFm.height) - height) / 2)
                            band: sr.r.band
                        }
                        Text {
                            x: 16
                            width: root._scaleNameW
                            text: sr.r.name
                            color: Theme.textPrimary
                            font.family: root.fontFamily
                            font.pixelSize: root.bodySize
                        }
                        Text {
                            id: rangeText
                            x: 16 + root._scaleNameW + 10
                            width: root._scaleRangeW
                            text: sr.r.range
                            color: Theme.textMuted
                            font.family: root.fontFamily
                            font.pixelSize: root.figureSize
                            anchors.baseline: adviceText.baseline
                        }
                        Text {
                            id: adviceText
                            x: sr.adviceX
                            width: Math.max(0, parent.width - sr.adviceX)
                            visible: sr.r.advice.length > 0
                            text: sr.r.advice
                            color: Theme.textMuted
                            font.family: root.fontFamily
                            font.pixelSize: root.figureSize
                            wrapMode: Text.Wrap
                            y: Math.round((Math.ceil(bodyFm.height) - Math.ceil(figureFm.height)) / 2)
                        }
                    }
                }
            }
        }
    }

    // THE SWIPE's one reader (see the header), over the whole detail and
    // grown to the hold rect while a gesture lives. It takes no buttons and
    // no hover, so the chips, the chart's hover and the tabs keep theirs.
    WheelArea {
        id: swipeArea
        x: 0
        y: 0
        width: root._gestureActive ? root.gestureHoldWidth : root.width
        height: root._gestureActive ? root.gestureHoldHeight : root.height
        z: 200

        // Whether a point of this area is over `item`.
        function _over(item, wx, wy) {
            if (!item || !item.visible)
                return false;
            const p = swipeArea.mapToItem(item, wx, wy);
            return p.x >= 0 && p.y >= 0 && p.x <= item.width && p.y <= item.height;
        }

        turned: wheel => {
            wheel.accepted = root._wheel(wheel.x, wheel.y, wheel);
        }
    }
}
