pragma ComponentBehavior: Bound

import QtQuick

import "data"
import "../common/theme"
import "../common/components"
import "../common/icons"
import "../common/components/Mix.js" as Mix
import "../common/components/AppHue.js" as AppHue
import "../launcher/browse/CategoryHue.js" as CH
import "data/ScreentimeModel.js" as Model

// =============================================================================
// ScreentimeCard.qml -- the screentime tab: what the machine's time went to,
// by week, by day, by app (the clock popup's third tab; CONTRACT.md §10).
//
// Top to bottom, padding 12: a header (TODAY and SESSION live, the week's label
// with its chevrons, its total and daily average), the faces card (Days /
// Hours / Span on a CardViewCycler), the stats strip, the ribbon of a selected
// day (one fraction; the list hangs from its foot), the app list.
//
// DATA. `service` is a ScreentimeService or a ScreentimeMock (CONTRACT §9) and
// the card only reads it (the host sets `service.live`, and a service takes ONE
// snapshot a session: nothing on the card changes while it is shown). The
// shown week's today has the open interval merged in
// (Model.liveSum) and the header's figures are Model.liveFigures, both at
// `serviceNow`: the snapshot's own instant (`state.now`), so the figures are
// the snapshot's too and no clock ticks while the card is on screen.
//
// ONE CLOCK PER MOTION. A week step and an app focus are both
// `chart.morph(...)`: the heat grid and the span bars hold what they DRAW and
// move to the new picture on the chart's own progress, so the three faces
// share one e at every frame, and a step that interrupts a step continues from
// what is on screen. A week that is not loaded yet is asked for and the step
// lands on arrival. Never into the future.
//
// GESTURES. The card reads no wheel: the host's one reader asks `ownerAt()`
// where a gesture began ("week": the faces card; "list": a list that scrolls;
// "": anywhere else, the tabs') and hands `stepWeekBy` (sideways) or
// `cycleFacesBy` (vertical) its units, then `endGesture()`.
// =============================================================================
Item {
    id: card

    // ---- Contract (CONTRACT §10) ------------------------------------------
    property var service: null
    // 0 days | 1 hours | 2 span (the owner remembers it)
    property int face: 0
    property bool listWheelEnabled: true

    // ---- Layout -------------------------------------------------------------
    property real cardWidth: 420
    property real hostHeight: 454
    implicitWidth: card.cardWidth
    implicitHeight: card.hostHeight
    property string fontFamily: "Inter"
    property real padding: 12
    property real radius: 14
    property real gap: 8
    property real facesHeight: 170
    property int ribbonMs: 260
    // The day's histogram: its narrowest column (px) and how many apps keep a
    // colour of their own (the rest share a faint one).
    property real minColumnPx: 5
    property int dayLayers: 5

    // ---- State ---------------------------------------------------------------
    property string weekKey: ""
    property int selectedDay: -1
    property string focused: ""
    property string _pendingWeek: ""

    readonly property var st: card.service ? card.service.state : null
    readonly property string today: card.st ? card.st.day : ""
    readonly property string curWeek: card.today !== "" && card.service ? card.service.weekStartOf(card.today) : ""
    readonly property bool absent: card.service !== null && card.service.status === "absent"
    readonly property double serviceNow: card.st && card.st.now ? card.st.now : 0
    readonly property var figures: Model.liveFigures(card.st, card.serviceNow)
    readonly property real morphProgress: bars.chart.morphProgress
    readonly property alias barsFace: bars
    readonly property alias heatFace: heat
    readonly property alias spanFace: span
    readonly property alias appList: list
    readonly property alias statsStrip: stats
    readonly property alias ribbonStrip: ribbon

    // The shown week with today's day live-merged; null until it has landed.
    readonly property var _week: {
        const w = card.service && card.weekKey !== "" && !card.absent ? card.service.week(card.weekKey) : null;
        if (!w || !card.st)
            return w;
        const now = card.serviceNow;
        let touched = false;
        const days = w.days.map(d => {
            if (d.date !== card.st.day || !d.sum)
                return d;
            touched = true;
            return { date: d.date, status: d.status, start: d.start, end: d.end, sum: Model.liveSum(d.sum, card.st, now) };
        });
        return touched ? { from: w.from, days: days } : w;
    }
    readonly property var _dates: card.weekKey !== "" ? Model.weekDates(card.weekKey) : []
    readonly property var _daySum: card.selectedDay >= 0 && card._week && card.selectedDay < card._week.days.length
        ? card._week.days[card.selectedDay].sum : null
    readonly property var _scope: card.selectedDay >= 0 ? card._daySum : card._week
    readonly property var _stats: card._week ? Model.stats(card._scope) : null
    readonly property var _rows: card._week ? Model.rows(card._scope) : []
    readonly property var _totals: {
        let total = 0, n = 0;
        const days = card._week ? card._week.days : [];
        for (let i = 0; i < days.length; i++)
            if (days[i].sum && days[i].sum.total > 0) {
                total += days[i].sum.total;
                n++;
            }
        return { total: total, avg: n > 0 ? total / n : 0, n: n };
    }
    readonly property string _message: card.absent ? "Screentime is not running"
        : (card._week && card._totals.n === 0 ? "No activity this week" : "")
    property string _messageShown: ""
    on_MessageChanged: if (card._message !== "")
        card._messageShown = card._message

    readonly property int startHour: card.st && card.st.config ? card.st.config.dayStartHour : 4
    readonly property color focusHue: card.focused !== "" ? card.hueOf(card.focused) : Theme.accent

    readonly property var _monthNames: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    function _dm(date) {
        return Number(date.substring(8, 10)) + " " + card._monthNames[Number(date.substring(5, 7)) - 1];
    }
    readonly property string weekLabel: card._dates.length === 7 ? card._dm(card._dates[0]) + " – " + card._dm(card._dates[6]) : ""
    readonly property string summaryText: {
        if (card.absent || !card._week)
            return "";
        if (card.selectedDay >= 0)
            return Model.dayLabel(card._dates[card.selectedDay]) + " · " + Model.fmt(card._daySum ? card._daySum.total : 0);
        return card._totals.n > 0 ? Model.fmt(card._totals.total) + " · avg " + Model.fmt(card._totals.avg) : "No data";
    }
    readonly property bool canGoNext: card.weekKey !== "" && card.curWeek !== "" && card.weekKey < card.curWeek

    // ---- An app's hue, resolved where it is drawn --------------------------------
    readonly property var _palette: ["mdBlue", "mdOrange", "mdGreen", "mdPurple", "mdTeal", "mdPink", "mdYellow", "mdRed"]
    // The icon's own strongest colour, SAMPLED from the icon the theme gives the app (IconColours: once per icon, a 16 x 16 read-back,
    // the answer a turn later through `colours.serial`), else the category's hue, else a fixed palette hue by hash of the class.
    // want() only queues, so a binding may call it.
    IconColours {
        id: colours
    }
    function hueOf(cls) {
        card.apps.serial;
        colours.serial;
        if (cls === "~desktop")
            return Theme.mdGray;
        const info = card.apps.app(cls);
        const tok = CH.tokenFor(info.categories);
        const fb = tok !== "accent" ? Theme[tok] : Theme[card._palette[AppHue.hashIndex(cls, card._palette.length)]];
        const src = AppIcons.source({ cls: cls, appId: info.desktopId, icon: info.icon, kind: "app" });
        colours.want(src);
        return AppHue.appColour(colours.colourOf(src), fb);
    }

    ScreentimeApps {
        id: apps
    }
    readonly property alias apps: apps

    // ---- Weeks ---------------------------------------------------------------------
    function _init() {
        // The service's own state, not `card.st`: a host that hands the service
        // in AFTER creation (the clock's Binding) runs onServiceChanged before
        // the `st` binding has followed it (CLAUDE.md, two generations), and
        // the first week would then never be taken.
        const st = card.service ? card.service.state : null;
        if (card.weekKey !== "" || !st)
            return;
        const k = card.service.weekStartOf(st.day);
        bars.chart.jump(() => {
            card.weekKey = k;
        });
        card.service.loadWeek(k);
    }
    // What changed in the service: take the first picture, answer a step that
    // was waiting for its week, ask again for a week the cache dropped.
    function _landed() {
        card._init();
        if (card.weekKey === "" || !card.service)
            return;
        if (card._pendingWeek !== "") {
            if (card.service.week(card._pendingWeek) !== null)
                card._commit(card._pendingWeek);
        }
        if (card.service.week(card.weekKey) === null)
            card.service.loadWeek(card.weekKey);
    }
    Connections {
        target: card.service
        function onSerialChanged() {
            card._landed();
        }
        function onStateChanged() {
            card._landed();
        }
    }
    // Another service is another record: the week, the day and the focus of the
    // old one mean nothing in it, so the card starts again from the new one's
    // current week (a mockup switching between the mock and the real daemon).
    onServiceChanged: {
        card.selectedDay = -1;
        card.focused = "";
        card._pendingWeek = "";
        card._ribbon = null;
        card.weekKey = "";
        card._landed();
    }
    Component.onCompleted: card._landed()

    // A change of the picture, as one motion: the heat grid and the span take
    // what they draw, then the chart morphs while `fn` moves the inputs.
    function _morphTo(fn) {
        if (card.weekKey === "") {
            fn();
            return;
        }
        heat.hold();
        span.hold();
        bars.chart.morph(fn);
    }
    function _commit(k) {
        card._pendingWeek = "";
        card._morphTo(() => {
            card.weekKey = k;
            card.selectedDay = -1;
        });
    }

    // +1 = the next week. Never past the current one; a week not loaded yet is
    // asked for and shown on arrival.
    function stepWeek(n) {
        if (!card.service || card.weekKey === "" || n === 0)
            return false;
        const base = card._pendingWeek !== "" ? card._pendingWeek : card.weekKey;
        const k = Model.addDays(base, 7 * n);
        if (card.curWeek === "" || k > card.curWeek)
            return false;
        if (card.service.week(k) !== null) {
            card._commit(k);
        } else {
            card._pendingWeek = k;
            card.service.loadWeek(k);
        }
        return true;
    }

    function selectDay(i) {
        if (!card.service || card.weekKey === "" || i < 0 || i > 6)
            return;
        if (i === card.selectedDay) {
            card.selectedDay = -1;
            return;
        }
        const d = card._week ? card._week.days[i] : null;
        if (!d || d.status !== "ok")
            return;
        card.selectedDay = i;
        card.service.loadDay(d.date);
    }

    function focusApp(cls) {
        const next = card.focused === cls ? "" : cls;
        card._morphTo(() => {
            card.focused = next;
        });
    }

    function pinMorph(t) {
        bars.chart.pinMorph(t);
    }

    // ---- Gestures (the host's reader calls these) --------------------------------------
    function ownerAt(x, y) {
        if (x >= facesBox.x && x < facesBox.x + facesBox.width && y >= facesBox.y && y < facesBox.y + facesBox.height)
            return "week";
        if (list.canScroll && x >= list.x && x < list.x + list.width && y >= list.y && y < list.y + list.height)
            return "list";
        return "";
    }
    // Positive units (towards the right chevron) = the next week. The calendar's months go
    // the other way, because there the page slides with the fingers; a week step here is a
    // morph that nothing slides along, so the swipe follows the chevrons.
    function stepWeekBy(units, fromPixels) {
        const n = stepper.feed(units, fromPixels);
        if (n !== 0)
            card.stepWeek(n > 0 ? 1 : -1);
    }
    function cycleFacesBy(units, fromPixels) {
        cycler.feed(units, fromPixels);
    }
    function endGesture() {
        stepper.end();
        cycler.end();
    }
    function handleKey(e) {
        switch (e.key) {
        case Qt.Key_Left:
            card.stepWeek(-1);
            break;
        case Qt.Key_Right:
            card.stepWeek(1);
            break;
        case Qt.Key_Up:
            cycler.select(card.face - 1);
            break;
        case Qt.Key_Down:
            cycler.select(card.face + 1);
            break;
        case Qt.Key_Escape:
            if (card.selectedDay >= 0)
                card.selectedDay = -1;
            else if (card.focused !== "")
                card.focusApp(card.focused);
            else
                return false;
            break;
        default:
            return false;
        }
        e.accepted = true;
        return true;
    }
    WheelStepper {
        id: stepper
    }

    // ---- Header --------------------------------------------------------------------
    readonly property real _innerW: card.width - 2 * card.padding
    Item {
        id: header
        x: card.padding
        y: card.padding
        width: card._innerW
        height: Math.ceil(today.y + today.height)

        // Two rows on two baselines: the captions with the week's label, the
        // figures with the week's summary.
        component Cap: Text {
            y: 0
            color: Theme.textFaint
            font.family: card.fontFamily
            font.pixelSize: 10
        }
        component Fig: Text {
            y: 14
            color: Theme.textPrimary
            font.family: card.fontFamily
            font.pixelSize: 16
            font.bold: true
        }
        Cap {
            id: capToday
            x: 0
            text: "Today"
        }
        Fig {
            id: today
            x: 0
            text: card.st ? Model.fmt(card.figures.today) : "–"
        }
        Cap {
            id: capSession
            x: 100
            text: "Session"
        }
        Fig {
            id: sessionFig
            x: 100
            text: card.st && card.st.session ? Model.fmt(card.figures.session) : "–"
        }
        MouseArea {
            id: todayArea
            x: 0
            width: Math.ceil(Math.max(capToday.width, today.width))
            height: today.y + today.height
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            cursorShape: undefined   // a hover area for the tip: the cursor is what lies under it (a MouseArea owns an Arrow)
        }
        HoverTip {
            anchorItem: todayArea
            overlayItem: card
            side: "below"
            fontFamily: card.fontFamily
            fontPixelSize: 11
            show: todayArea.containsMouse
            text: "Active time today, counted from " + card.startHour + ":00"
        }
        MouseArea {
            id: sessionArea
            x: 100
            width: Math.ceil(Math.max(capSession.width, sessionFig.width))
            height: sessionFig.y + sessionFig.height
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            cursorShape: undefined   // a hover area for the tip: the cursor is what lies under it (a MouseArea owns an Arrow)
        }
        HoverTip {
            anchorItem: sessionArea
            overlayItem: card
            side: "below"
            fontFamily: card.fontFamily
            fontPixelSize: 11
            show: sessionArea.containsMouse
            text: "Active time since your last break"
        }

        component Step: Item {
            id: step
            property int dir: 1
            property bool active: true
            width: 22
            height: 22
            property real hoverF: stepArea.containsMouse && step.active ? 1 : 0
            Behavior on hoverF {
                NumberAnimation {
                    duration: 160
                    easing.type: Easing.OutCubic
                }
            }
            Chevron {
                x: Math.round((step.width - width) / 2)
                y: Math.round((step.height - height) / 2)
                size: 13
                rotation: step.dir > 0 ? -90 : 90
                color: Mix.c(step.active ? Theme.textMuted : Theme.textFaint, Theme.textPrimary, step.hoverF)
                opacity: step.active ? 1 : 0.45
            }
            MouseArea {
                id: stepArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: step.active ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: if (step.active)
                    card.stepWeek(step.dir)
            }
        }
        // The week's column, flush with the right edge: its label between the
        // chevrons and its summary under it, on one centre line. Its width is
        // the widest either can be, so neither moves the other.
        FontMetrics {
            id: weekFm
            font.family: card.fontFamily
            font.pixelSize: 12
            font.bold: true
        }
        FontMetrics {
            id: sumFm
            font.family: card.fontFamily
            font.pixelSize: 11
        }
        function _labelW() {
            weekFm.font;
            return Math.ceil(weekFm.advanceWidth("28 Sep – 30 Sep"));
        }
        function _sumW() {
            sumFm.font;
            return Math.ceil(sumFm.advanceWidth("188h 88m · avg 28h 88m"));
        }
        readonly property real _labelSlot: header._labelW()
        readonly property real _colW: Math.max(header._labelSlot + 2 * 22, header._sumW())
        readonly property real _colX: header.width - header._colW
        readonly property real _mid: header._colX + header._colW / 2
        Text {
            id: weekLabel
            x: Math.round(header._mid - width / 2)
            y: Math.round(capToday.baselineOffset - weekLabel.baselineOffset)
            text: card.weekLabel
            color: Theme.textPrimary
            font.family: card.fontFamily
            font.pixelSize: 12
            font.bold: true
        }
        Step {
            x: Math.round(header._mid - header._labelSlot / 2) - 22
            y: Math.round(weekLabel.y + weekLabel.height / 2 - 11)
            dir: -1
            active: card.weekKey !== ""
        }
        Step {
            x: Math.round(header._mid + header._labelSlot / 2)
            y: Math.round(weekLabel.y + weekLabel.height / 2 - 11)
            dir: 1
            active: card.canGoNext
        }
        Text {
            id: summary
            x: Math.round(header._mid - width / 2)
            y: Math.round(today.y + today.baselineOffset - summary.baselineOffset)
            text: card.summaryText
            color: Theme.textMuted
            font.family: card.fontFamily
            font.pixelSize: 11
        }
    }

    // ---- The faces -------------------------------------------------------------------
    Item {
        id: facesBox
        x: card.padding
        y: header.y + header.height + card.gap
        width: card._innerW
        height: card.facesHeight

        ShadowBox {
            anchors.fill: parent
            baseRadius: card.radius
            surfaceColor: Theme.surface
            bevelColor: Theme.bevel
            shadowColor: Theme.border
            backgroundColor: Theme.listBox
            bevelWidth: 1
            shadowWidth: 3
        }
        ViewBlend {
            id: faceBlend
            count: 3
            target: card.face
            durationMs: 200
        }
        readonly property real _w0: faceBlend.weights.length > 0 ? faceBlend.weights[0] : 1
        readonly property real _w1: faceBlend.weights.length > 1 ? faceBlend.weights[1] : 0
        readonly property real _w2: faceBlend.weights.length > 2 ? faceBlend.weights[2] : 0
        readonly property real _pad: card.padding

        ScreentimeBars {
            id: bars
            x: facesBox._pad - chartPadding
            y: facesBox._pad - chartPadding
            width: facesBox.width - 2 * facesBox._pad + 2 * chartPadding
            height: facesBox.height - 2 * facesBox._pad + 2 * chartPadding
            opacity: facesBox._w0 * (1 - facesBox._msgF)
            visible: opacity > 0.001
            week: card._week
            weekKey: card.weekKey
            today: card.today
            focusCls: card.focused
            focusHue: card.focusHue
            selectedDay: card.selectedDay
            fontFamily: card.fontFamily
        }
        ScreentimeHeatmap {
            id: heat
            x: facesBox._pad
            y: facesBox._pad
            width: facesBox.width - 2 * facesBox._pad
            height: facesBox.height - 2 * facesBox._pad
            opacity: facesBox._w1 * (1 - facesBox._msgF)
            visible: opacity > 0.001
            target: Model.heat(card._week, card.focused !== "" ? card.focused : null)
            progress: card.morphProgress
            hue: card.focusHue
            dayLabels: card._dates.map(d => Model.dayLabel(d))
            startHour: card.startHour
            selectedDay: card.selectedDay
            fontFamily: card.fontFamily
        }
        ScreentimeSpan {
            id: span
            x: facesBox._pad
            y: facesBox._pad
            width: facesBox.width - 2 * facesBox._pad
            height: facesBox.height - 2 * facesBox._pad
            opacity: facesBox._w2 * (1 - facesBox._msgF)
            visible: opacity > 0.001
            target: Model.span(card._week)
            progress: card.morphProgress
            hue: card.focusHue
            dayLabels: card._dates.map(d => Model.dayLabel(d))
            startHour: card.startHour
            selectedDay: card.selectedDay
            fontFamily: card.fontFamily
        }

        property real _msgF: card._message !== "" ? 1 : 0
        Behavior on _msgF {
            NumberAnimation {
                duration: 160
                easing.type: Easing.OutCubic
            }
        }
        Text {
            x: Math.round((parent.width - width) / 2)
            y: Math.round((parent.height - height) / 2)
            text: card._messageShown
            opacity: facesBox._msgF
            visible: opacity > 0.001
            color: Theme.textMuted
            font.family: card.fontFamily
            font.pixelSize: 12
        }

        // A day is picked on the face's own picture.
        function _tap(x, y) {
            let i = -1;
            if (card.face === 0) {
                const c = bars.chart, cx = x - bars.x;
                if (c.slotW > 0 && cx >= c.px0 && cx < c.px1)
                    i = Math.floor((cx - c.px0) / c.slotW);
            } else if (card.face === 1) {
                if (x >= heat.x + heat.gridX)
                    i = heat.rowAt(y - heat.y);
            } else {
                i = span.dayAt(x - span.x);
            }
            if (i >= 0 && i < 7)
                card.selectDay(i);
        }
        TapHandler {
            onTapped: eventPoint => facesBox._tap(eventPoint.position.x, eventPoint.position.y)
        }

        CardViewCycler {
            id: cycler
            anchors.fill: parent
            views: [{ id: "days", label: "Days" }, { id: "hours", label: "Hours" }, { id: "span", label: "Span" }]
            orientation: "vertical"
            padding: card.padding
            radius: card.radius
            fontFamily: card.fontFamily
        }
        Binding {
            target: cycler
            property: "currentIndex"
            value: card.face
        }
        Connections {
            target: cycler
            function onCurrentIndexChanged() {
                card.face = cycler.currentIndex;
            }
        }
    }

    // ---- Stats ---------------------------------------------------------------------------
    ScreentimeStats {
        id: stats
        x: card.padding
        y: facesBox.y + facesBox.height + card.gap
        width: card._innerW
        height: implicitHeight
        stats: card._stats
        overlayItem: card
        breakMin: card.st && card.st.config && card.st.config.sessionBreakMin > 0 ? card.st.config.sessionBreakMin : 5
        longestName: card._stats && card._stats.longest.app ? card.apps.app(card._stats.longest.app).name : ""
        fontFamily: card.fontFamily
    }

    // ---- The ribbon of a selected day --------------------------------------------------
    property var _ribbon: null
    function _syncRibbon() {
        if (card.selectedDay < 0 || !card._week || !card.service)
            return;
        const day = card.service.day(card._week.days[card.selectedDay].date);
        if (day)
            card._ribbon = Model.dayColumns(day, Math.floor(card._innerW / card.minColumnPx), card.dayLayers);
    }
    onSelectedDayChanged: card._syncRibbon()
    Connections {
        target: card.service
        function onSerialChanged() {
            card._syncRibbon();
        }
    }
    property real _ribbonF: card.selectedDay >= 0 ? 1 : 0
    Behavior on _ribbonF {
        NumberAnimation {
            duration: card.ribbonMs
            easing.type: Easing.OutCubic
        }
    }
    Item {
        id: ribbonSlot
        x: card.padding
        y: stats.y + stats.height + card.gap
        width: card._innerW
        height: Math.round(card._ribbonF * (ribbon.implicitHeight + card.gap)) - (card._ribbonF > 0 ? card.gap : 0)
        clip: true
        visible: card._ribbonF > 0.001
        ScreentimeRibbon {
            id: ribbon
            width: parent.width
            height: implicitHeight
            opacity: card._ribbonF
            columns: card._ribbon
            hueOf: card.hueOf
            fontFamily: card.fontFamily
        }
    }

    // ---- The list -----------------------------------------------------------------------
    ScreentimeAppList {
        id: list
        x: card.padding
        y: ribbonSlot.visible ? ribbonSlot.y + ribbonSlot.height + card.gap : stats.y + stats.height + card.gap
        width: card._innerW
        height: Math.max(0, card.height - card.padding - y)
        radius: card.radius
        rows: card._rows
        scopeKey: card.weekKey + ":" + card.selectedDay
        apps: card.apps
        hueOf: card.hueOf
        focused: card.focused
        fontFamily: card.fontFamily
        listWheelEnabled: card.listWheelEnabled
        emptyText: card._week && card._rows.length === 0 ? "Nothing here" : ""
        onRowClicked: cls => card.focusApp(cls)
    }
}
