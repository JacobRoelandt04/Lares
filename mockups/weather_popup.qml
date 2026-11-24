pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtTest
import Quickshell

import "modules/common/components"
import "modules/common/glyphs"
import "modules/bar/gooey/GooeyGeometry.js" as Geo
import "modules/common/mockup"
import "modules/common/scroll"
import "modules/common/theme"
import "modules/weather"
import "modules/weather/data"
import "modules/bar/gooey"

// =============================================================================
// mockups/weather_popup.qml -- the weather popup and its detail, on the gooey
// surface, over the wallpaper.
//
// The content on the stage is a HARNESS, not the popup alone: WeatherPopup is
// a drop-in for thePopup and its detail is a drop-in for the engine's
// secondary, so what has to be seen is the two of them as ONE surface. The
// harness emulates the bar's engine the way the user allowed ("cheat"):
//
//   - the real wallpaper (mockups/bar.qml's block, following the theme pair and
//     mode) as the ground;
//   - a standalone GooeyField drawing the popup's box and, while the detail is
//     out, the child's box as one antialiased shape (GooeyGeometry's fillets);
//   - WeatherPopup on the main box, which follows the popup's implicit size
//     with the host's easing (260 ms OutCubic, as thePopup);
//   - the detail, created from the popup's own `secondaryComponent` and
//     placed on the child box, which grows out of the popup's `detailSide`
//     centred on `secondaryAnchor` projected onto that side and clamped to the
//     popup's extent -- OutBack 1.2 over 320 ms; a key change while it is out
//     slides the box (OutQuint 260 ms) and swaps the content while hidden:
//     fade out 160 ms, assign `secondaryKey`, fade in 160 ms -- exactly the
//     engine's contract (GooeyEngine.qml's header).
//
// THE STAGE IS ONE SIZE. The user: "Make the emulated desktop background a
// fixed size that can house all shapes. It switching is just too jarring." The
// harness reserves room for every shape the two can take -- the popup in each
// of its three views, the detail of any metric grown out of `detailSide` and
// carried past its full size by the open's overshoot -- so a view switch, an
// open, a close, a slide or a metric never resizes the emulated desktop and
// never moves the popup on it. Only a different `detailSide` asks for another
// reserve. The reserve starts from measured extremes (PROBE=measure) and only
// grows, so a panel knob that makes something bigger grows the stage once.
//
// Env (this file's own; the framework's GRAB / PANEL_* still apply):
//   SCENARIO=<WeatherMock scenario>   VIEW=mini|normal|detailed
//   HOURLYVIEW=<id|index>   DAILYVIEW=<id|index>   the cards' views at load
//   DETAIL=<metric>[,dayIndex[,hourIndex]]   opens the detail at load, from
//                  the link a click on that metric would use (keyFor)
//   DETAILSIDE=far|end|start|bottom|right|left|top   the popup's detailSide
//   BACKDROP=0     the backdrop off        TIMEOFDAY=<h>   the mock's hour
//   RUNNING=0      the backdrop still      STATICLAYERS=0  no static layers
//   PULSE=0        skeletons still (a render)
//   STAGE_GRAB=<png> [GRAB_MS]   grab the HARNESS alone (1:1) and quit
//   PROBE=1        the click probe:  WEATHER CLICK RESULT PASS|FAIL
//   PROBE=swipe    the wheel probe:  WEATHER SWIPE RESULT PASS|FAIL
//   PROBE=trace    the detail clock: WEATHER TRACE RESULT PASS|FAIL
//   PROBE=stage    the stage's size: WEATHER STAGE RESULT PASS|FAIL
//   PROBE=measure  prints the extremes the stage reserve starts from
//   ARM=1          with a PROBE: the fault that probe exists to catch
//   ARM=leak       with PROBE=swipe: the stage's wheel catchers off, so a
//                  wheel the popup handled scrolls the stage too -- must FAIL
//
//   quickshell -p mockups/weather_popup.qml
// =============================================================================
MockupWindow {
    id: win

    moduleId: "weather_popup"
    title: "Weather popup"
    stageLabel: "WeatherPopup + WeatherDetail on one gooey surface (drop-ins for thePopup and its secondary)"
    content: harness
    target: popup
    targets: ({
            glyphSetParams: setKnob,
            flourishParams: flourishKnob,
            heroParams: popup.hero,
            hourlyParams: popup.hourlyStrip,
            hourlyCyclerParams: win.hourlyCycler,
            dailyParams: popup.dailyList,
            dailyCyclerParams: win.dailyCycler,
            tilesParams: popup.tileGrid,
            floatSwayParams: popup.floatStyle,
            floatLeanParams: popup.floatStyle,
            floatDealParams: popup.floatStyle
        })
    zoom: 1.0
    panelWidth: 470

    lists: ({
            layoutParams: win.layoutParams,
            swipeParams: win.swipeParams,
            heroParams: win.heroParams,
            hourlyParams: win.hourlyParams,
            hourlyCyclerParams: win.hourlyCyclerParams,
            dailyParams: win.dailyParams,
            dailyCyclerParams: win.dailyCyclerParams,
            tilesParams: win.tilesParams,
            detailParams: win.detailParams,
            glyphSetParams: win.glyphSetParams,
            flourishParams: win.flourishParams,
            flourishPopupParams: win.flourishPopupParams,
            glyphParams: win.glyphParams,
            backdropParams: win.backdropParams,
            floatSwayParams: win.floatSwayParams,
            floatLeanParams: win.floatLeanParams,
            floatDealParams: win.floatDealParams,
            floatWideParams: win.floatWideParams,
            weatherColors: win.weatherColors
        })
    themedLists: ["weatherColors"]

    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        {
            name: "Layout",
            subs: [
                {
                    name: "Layout",
                    lists: ["layoutParams"],
                    groups: ["Padding", "Radii", "Widths", "Header", "Figures", "Motion"]
                },
                {
                    name: "Carve",
                    lists: ["layoutParams"],
                    groups: ["Carve"]
                },
                {
                    name: "Swipe",
                    lists: ["swipeParams"]
                }
            ]
        },
        {
            name: "Hero",
            lists: ["heroParams"]
        },
        {
            name: "Hourly",
            subs: [
                {
                    name: "Strip",
                    lists: ["hourlyParams"],
                    groups: ["Columns", "Type", "Band", "Link", "Scroll", "Skeleton"]
                },
                {
                    name: "Lines",
                    lists: ["hourlyParams"],
                    groups: ["Lines", "Track", "Bars"]
                },
                {
                    name: "Scales",
                    lists: ["hourlyParams"],
                    groups: ["Scales", "Motion"]
                },
                {
                    name: "Views",
                    lists: ["hourlyCyclerParams"]
                }
            ]
        },
        {
            name: "Daily",
            subs: [
                {
                    name: "List",
                    lists: ["dailyParams"],
                    groups: ["Rows", "Glyphs", "Type", "Groove", "Link", "Scroll", "Skeleton"]
                },
                {
                    name: "Bars",
                    lists: ["dailyParams"],
                    groups: ["Pair", "Air quality", "Scales", "Motion"]
                },
                {
                    name: "Views",
                    lists: ["dailyCyclerParams"]
                }
            ]
        },
        {
            name: "Tiles",
            lists: ["tilesParams"]
        },
        {
            name: "Float",
            subs: [
                {
                    name: "Sway",
                    lists: ["floatSwayParams"]
                },
                {
                    name: "Lean",
                    lists: ["floatLeanParams"]
                },
                {
                    name: "Deal",
                    lists: ["floatDealParams", "floatWideParams"]
                }
            ]
        },
        {
            name: "Detail",
            subs: [
                {
                    name: "Chart",
                    lists: ["detailParams"],
                    groups: ["Chart", "Axis"]
                },
                {
                    name: "Scale",
                    lists: ["detailParams"],
                    groups: ["Scale"]
                },
                {
                    name: "Days",
                    lists: ["detailParams"],
                    groups: ["Day change", "Swipe"]
                }
            ]
        },
        {
            name: "Glyphs",
            lists: ["glyphSetParams", "flourishParams", "flourishPopupParams", "glyphParams"],
            page: glyphPage
        },
        {
            name: "Backdrop",
            lists: ["backdropParams"],
            page: backdropPage
        },
        {
            name: "Colours",
            subs: [
                {
                    name: "Glyphs",
                    lists: ["weatherColors"],
                    groups: ["Glyph colours"]
                },
                {
                    name: "Conditions",
                    lists: ["weatherColors"],
                    groups: ["Condition hues"]
                },
                {
                    name: "Scales",
                    lists: ["weatherColors"],
                    groups: ["Scale bands"]
                }
            ]
        }
    ]

    // =====================================================================
    //  ENVIRONMENT
    // =====================================================================
    readonly property string envScenario: Quickshell.env("SCENARIO") || "live-fixture"
    readonly property string envView: Quickshell.env("VIEW") || "normal"
    readonly property string envDetail: Quickshell.env("DETAIL") || ""
    readonly property bool envBackdrop: (Quickshell.env("BACKDROP") || "1") !== "0"
    // RUNNING=0: the backdrop present but not ticking (the host's hook, the
    // perf script's `rest` arm); STATICLAYERS=0: the strip, list and tiles
    // drawn live under the ticking backdrop instead of held as textures.
    readonly property bool envRunning: (Quickshell.env("RUNNING") || "1") !== "0"
    // The tiles' float (WeatherPopup.cardFloat): SHEET_GRAB (the cleanup check's picture) holds it off, its clock being its own; the Run tab's switch too.
    property bool floatOn: win.sheetGrabPath === ""
    readonly property bool envStaticLayers: (Quickshell.env("STATICLAYERS") || "1") !== "0"
    readonly property real envTimeOfDay: Number(Quickshell.env("TIMEOFDAY") || "-1")
    readonly property bool envPulse: (Quickshell.env("PULSE") || "1") !== "0"
    readonly property string stageGrab: Quickshell.env("STAGE_GRAB") || ""
    readonly property string probeKind: Quickshell.env("PROBE") || ""
    readonly property bool armed: (Quickshell.env("ARM") || "") === "1"
    // The two faults a probe can arm inside the harness itself.
    readonly property bool traceArmed: win.armed && win.probeKind === "trace"
    readonly property bool stageArmed: win.armed && win.probeKind === "stage"
    // ARM=nocoast (PROBE=swipe): the lift never starts a fling (ScrollFeel.flingMin out of reach),
    // so the "a fast stream coasts after the lift" step must FAIL.
    // The cards' cyclers, once the popup has built the cards (null before: a card is a loader's, registered as it is built).
    // Properties of the window so the Save planner can follow them (tools/dev/mockup_promote.py unguards `cond ? win.x.y : null`).
    readonly property var hourlyCycler: popup.hourlyStrip ? popup.hourlyStrip.cycler : null
    readonly property var dailyCycler: popup.dailyList ? popup.dailyList.cycler : null
    // ARM=stripsign (PROBE=swipe): the hourly strip's sideways sense turned around (dx > 0 = later hours, not the content
    // following the fingers) and its view cycle reading a touchpad's fingers the wrong way up -- the strip's checks must FAIL.
    readonly property bool stripsignArmed: (Quickshell.env("ARM") || "") === "stripsign" && win.probeKind === "swipe"
    readonly property bool nocoastArmed: (Quickshell.env("ARM") || "") === "nocoast" && win.probeKind === "swipe"
    readonly property bool leakArmed: (Quickshell.env("ARM") || "") === "leak" && win.probeKind === "swipe"
    // ARM=sticky (with PROBE=swipe): the harness no longer hands a live
    // gesture's wheels from outside the popup's body to popup.gestureWheel --
    // round 3's broken sticky gesture, which the probe must catch.
    readonly property bool stickyArmed: (Quickshell.env("ARM") || "") === "sticky" && win.probeKind === "swipe"
    // WHERE THE DETAIL OPENS is weather.jsonc's `look.secondarySide` (no panel row: one value, one home). The stage takes the shell's
    // default, "end" (with no bar here `far` is the bottom, `end` the right and `start` the left, as on a top bar); DETAILSIDE= names
    // another, the engine's absolute words included (a harness's DETAILSIDE=top).
    // The icon set on trial (WeatherGlyphSet; in the shell it is weather.jsonc's temporary `glyphSet`): this window's own.
    readonly property var setNames: ["ink", "carved"]
    QtObject {
        id: setKnob
        property int glyphSet: 0
        onGlyphSetChanged: WeatherGlyphSet.set = win.setNames[Math.max(0, Math.min(win.setNames.length - 1, setKnob.glyphSet))]
    }
    readonly property var glyphSetParams: [
        {
            label: "icon set",
            prop: "glyphSet",
            group: "Set",
            blurb: "Which weather icon set every glyph draws, here and in the gallery. Temporary: the carved set stays only until the ink set is approved.",
            tip: "ink: the drawn set, solid icons at the weight of the bar's other glyphs, in the muted ink with one coloured part (the sun, the drops, the bolt). carved: the legacy full-colour carved glyphs, which the Carve knobs below shape (they do nothing to the ink set). On the desktop the choice is weather.jsonc's \"glyphSet\", read live; this row only switches this window, so Save does not write it.",
            val: 0,
            choices: ["ink", "carved"],
            promote: { skip: "the shell's set is weather.jsonc's glyphSet (a config key), not a default in a file" }
        }
    ]
    // The bar icon's flourish (WeatherBarButton.flourishMs): the strip of real bar buttons on the Glyphs page reads this.
    QtObject {
        id: flourishKnob
        property int flourishMs: 900
    }
    readonly property var flourishParams: [
        {
            label: "beat (bar)",
            prop: "flourishMs",
            group: "Flourish",
            blurb: "The icons' flourish (ink set): each icon moves as what it shows. In the bar it plays under the pointer (the \"In the bar\" strip below); in the popup when the pointer comes onto its item or picks it -- the hero's glyph, an hour, a day, the wind / pressure / moon tile, a day chip of the detail, its conditions strip under the scrub. Each plays to its end: sweep along the hours and they follow one another.",
            tip: "One beat of the flourish, ms. Every icon's motion is written in beats and runs its own length: rain about 0.9, the sun and the bolt 1, the moon 1.5, clouds 1.8, fog 2. 900 is the bar's usual flourish (the bell, the archive box), so what strikes and falls is as quick as those, and what drifts runs longer on the same curves. Save writes WeatherBarButton's default.",
            val: 900,
            from: 400,
            to: 2000,
            step: 20,
            promote: { to: "WeatherBarButton.flourishMs" }
        }
    ]
    readonly property var flourishPopupParams: [
        {
            label: "beat (popup)",
            prop: "glyphFlourishMs",
            group: "Flourish",
            tip: "One beat of a glyph's flourish inside the popup and its detail, ms (WeatherPopup.glyphFlourishMs): every glyph there, under the pointer or picked. 900, the bar's beat, so an icon moves the same wherever it is.",
            val: 900,
            from: 400,
            to: 2000,
            step: 20
        }
    ]
    // [kind, intensity, night, shower]: one bar button each on the Glyphs page
    readonly property var barConditions: [
        ["clear", 1, false, false], ["clear", 1, true, false], ["partly", 1, false, false], ["partly", 1, true, false],
        ["cloudy", 1, false, false], ["fog", 1, false, false], ["wind", 1, false, false],
        ["rain", 0, false, false], ["rain", 1, false, false], ["rain", 2, false, false], ["rain", 1, false, true], ["rain", 1, true, true],
        ["sleet", 1, false, false], ["snow", 1, false, false], ["snow", 2, false, false], ["hail", 1, false, false], ["hail", 2, false, false],
        ["thunder", 0, false, false], ["thunder", 1, false, false], ["thunder", 2, false, false]
    ]

    readonly property var metrics: ["temperature", "feelsLike", "precipitation", "wind", "airQuality", "pollen",
                                    "humidity", "uv", "visibility", "pressure", "cloudCover", "sunMoon", "conditions"]

    function parseDetail(s) {
        const parts = s.split(",");
        const metric = parts[0].trim();
        if (metric.length === 0)
            return null;
        const day = parts.length > 1 && parts[1].trim() !== "" ? Number(parts[1]) : 0;
        const hour = parts.length > 2 && parts[2].trim() !== "" ? Number(parts[2]) : null;
        return { metric: metric, dayIndex: isFinite(day) ? day : 0, hourIndex: hour !== null && isFinite(hour) ? hour : null };
    }

    Component.onCompleted: {
        const m = Quickshell.env("MODE");
        if (m === "light" || m === "dark")
            Theme.setMode(m);
        popup.viewMode = win.envView;
        popup.detailSide = Quickshell.env("DETAILSIDE") || "end";
        popup.backdropEnabled = win.envBackdrop;
        popup.backdropRunning = win.envRunning;
        popup.staticLayers = win.envStaticLayers;
        popup.skeletonPulse = win.envPulse;
        win.setCardView(popup.hourlyStrip, Quickshell.env("HOURLYVIEW") || "");
        win.setCardView(popup.dailyList, Quickshell.env("DAILYVIEW") || "");
        if (win.envDetail.length > 0) {
            const key = win.parseDetail(win.envDetail);
            if (key)
                Qt.callLater(function () { win.openFor(key.metric, key.dayIndex, key.hourIndex, false); });
        }
    }

    // A card's view (the strip's or the list's) by id or index, set the way a
    // host restores state: the cycler's index written directly, so no title
    // box shows. `viewIndex` itself is the cycler's, bound, never written.
    function setCardView(card, s) {
        if (s === "")
            return;
        const n = Number(s);
        const i = isFinite(n) ? Math.floor(n) : card.views.findIndex(v => v.id === s);
        if (i >= 0 && i < card.views.length)
            card.cycler.currentIndex = i;
        else
            console.warn("weather mockup: no view '" + s + "' (" + card.views.map(v => v.id).join(", ") + ")");
    }

    // THE KEY A CLICK WOULD MAKE for a metric on a day (and an hour), so the
    // detail anchors on the link a user would have clicked and that link
    // highlights: an hour names a strip column, in the strip's view of that
    // metric when it has one (keyAt builds it); today's metric with a tile
    // names the tile in the detailed view; today's conditions the hero's
    // glyph; anything else a row of the daily list, in the list's view of that
    // metric when it has one. `announce` changes a card's view the way a dot
    // click does (its title box shows); without it the view is set silently,
    // as at load.
    function keyFor(metric, day, hour, announce) {
        function viewTo(card) {
            const i = card.views.findIndex(v => v.metric === metric);
            if (i < 0 || i === card.viewIndex)
                return;
            if (announce)
                card.cycler.select(i);
            else
                card.cycler.currentIndex = i;
        }
        if (hour !== null) {
            const s = popup.hourlyStrip;
            viewTo(s);
            for (let i = 0; ; i++) {
                const k = s.keyAt(i);
                if (!k)
                    break;
                if (k.dayIndex === day && k.hourIndex === hour)
                    return { metric: metric, dayIndex: k.dayIndex, hourIndex: k.hourIndex, from: k.from };
            }
            return { metric: metric, dayIndex: day, hourIndex: hour, from: "hourly" };
        }
        if (day === 0 && popup.detailed && popup.tileGrid.tileItem(metric))
            return { metric: metric, dayIndex: 0, hourIndex: null, from: "tile" };
        if (day === 0 && metric === "conditions")
            return popup.hero.glyphItem.key;
        viewTo(popup.dailyList);
        return { metric: metric, dayIndex: day, hourIndex: null, from: "daily" };
    }
    function openFor(metric, day, hour, announce) {
        const key = win.keyFor(metric, day, hour, announce);
        popup.openDetail(key, popup.anchorFor(key));
    }

    // =====================================================================
    //  THE SERVICE (the mock: the fixture, edited per scenario)
    // =====================================================================
    WeatherMock {
        id: mock
        scenario: win.envScenario
        timeOfDay: win.envTimeOfDay
    }

    // LIVE DATA (LIVE=1, or the Run tab's "live" switch): the real
    // WeatherService -- weather.jsonc, geoclue, Open-Meteo, KMI, the caches --
    // in place of the mock, created only while it is on so no probe or render
    // ever fetches. What it serves (place, source, fetch time, the exact
    // Open-Meteo request) is on the Run tab, to compare against open-meteo.com.
    property bool liveData: (Quickshell.env("LIVE") || "") === "1"
    Loader {
        id: liveLoader
        active: win.liveData
        sourceComponent: Component {
            WeatherService {
                popupOpen: true
            }
        }
    }
    readonly property var svc: win.liveData && liveLoader.item ? liveLoader.item : mock

    // =====================================================================
    //  THE WALLPAPER (as mockups/bar.qml: the real one, following the theme)
    // =====================================================================
    MockupWallpaper {
        id: stageWall
    }
    readonly property string wallpaper: stageWall.source

    // =====================================================================
    //  THE HARNESS
    // =====================================================================
    Item {
        id: harness

        readonly property real margin: 24
        readonly property real maxR: 20
        readonly property int openMs: 320
        readonly property real openOvershoot: 1.2
        readonly property int slideMs: 260
        readonly property int fadeMs: 160
        readonly property int hostResizeMs: 260

        // ---- The popup's box: the host's easing ------------------------------
        property real popW: popup.implicitWidth
        property real popH: popup.implicitHeight
        Behavior on popW {
            NumberAnimation { duration: harness.hostResizeMs; easing.type: Easing.OutCubic }
        }
        Behavior on popH {
            NumberAnimation { duration: harness.hostResizeMs; easing.type: Easing.OutCubic }
        }

        // ---- The child ---------------------------------------------------------
        // Which side of the popup it grows from. There is no bar here, so
        // "far" is the bottom; "start"/"end" the left/right, as on a top bar.
        readonly property string childEdge: {
            const s = popup.secondarySide;
            if (s === "top" || s === "left" || s === "right" || s === "bottom")
                return s;
            if (s === "end")
                return "right";
            if (s === "start")
                return "left";
            return "bottom";
        }
        readonly property bool sideways: harness.childEdge === "left" || harness.childEdge === "right"
        readonly property Item detail: detailLoader.item as Item
        readonly property real childFullW: harness.detail ? harness.detail.implicitWidth : 0
        readonly property real childFullH: harness.detail ? harness.detail.implicitHeight : 0
        readonly property real popAlong: harness.sideways ? harness.popH : harness.popW

        // TWO CLOCKS, ONE PER DIRECTION, and the extent read off whichever is
        // current. Round 1 had one clock `t` and a direction flag, and its
        // close wrote the flag and then reset `t`: between the two statements
        // the extent read the finished open clock through the close's curve,
        // 0, so the child was ABSENT for one synchronous cascade and present
        // again at the next write -- and `bodies`, re-evaluated before
        // `childFull` had come back, read that stale null (the user's
        // "TypeError: Value is null", after every close). Here a switch resets
        // the clock it is about to read while the other one is still the one
        // read, and flips `closing` LAST, so the extent it lands on is the one
        // it left: no write in between passes through a false zero.
        property real openT: 0
        property real closeT: 1
        property bool closing: true
        property real closeFrom: 0
        readonly property real e: harness.closing
            ? harness.closeFrom * (1 - Geo.ease(1, harness.closeT, 0))
            : Geo.ease(3, harness.openT, harness.openOvershoot)
        readonly property bool moving: harness.closing ? harness.closeT < 1 : harness.openT < 1
        readonly property bool childPresent: popup.secondaryOpen || harness.e > 0.001
        // The invariant PROBE=trace counts: the child can only APPEAR by
        // opening. Present again while closed means an extent went through 0.
        onChildPresentChanged: {
            if (harness.childPresent && !popup.secondaryOpen)
                win.traceStats.rises++;
        }
        NumberAnimation {
            id: openAnim
            target: harness
            property: "openT"
            from: 0
            to: 1
            duration: harness.openMs
        }
        NumberAnimation {
            id: closeAnim
            target: harness
            property: "closeT"
            from: 0
            to: 1
        }
        // THE CHILD'S SPAN on its side, kept as the engine keeps it: where its
        // near end sits from the popup's own start (`rel`), how long it is
        // along the side, how far it reaches out. `wanted` is the target and
        // it is LIVE (GooeyEngine._childTarget): the anchor the child was
        // opened or slid to, the content's size now, the popup's extent now.
        // What is drawn eases toward it on ONE slide clock (OutQuint 260 ms)
        // from where it was drawn: a new key slides it, and so does the
        // content taking its new size once the key lands -- round 1 kept the
        // place it had worked out for the OLD content, so a tall detail (the
        // wind's Beaufort table, 1051 px) hung past the popup's end and out of
        // any fixed stage. The popup moving under it is followed at once, as
        // the engine follows its parent's box. `slide` holds both ends in ONE
        // object, so a retarget is one write and the drawn span is never, not
        // even for a cascade, somewhere it was not.
        property point anchorUsed: Qt.point(0, 0)
        readonly property var wanted: {
            const sw = harness.sideways;
            const along = sw ? harness.childFullH : harness.childFullW;
            const out = sw ? harness.childFullW : harness.childFullH;
            const c = sw ? harness.anchorUsed.y : harness.anchorUsed.x;
            const pa = harness.popAlong;
            let rel = (pa - along) / 2;
            if (pa > along) {
                rel = Math.max(0, Math.min(pa - along, c - along / 2));
                if (Math.abs(rel) < 3)
                    rel = 0;
                if (Math.abs(rel + along - pa) < 3)
                    rel = pa - along;
            }
            return { edge: harness.childEdge, rel: rel, along: along, out: out };
        }
        property var slide: ({ from: null, to: null })
        property real slideT: 1
        // The span drawn now. A function of plain properties, so a caller
        // never reads another binding's stale copy of it.
        function spanNow() {
            const s = harness.slide;
            if (!s.to)
                return null;
            const k = Geo.ease(2, harness.slideT, 0);
            const mix = (a, b) => a + (b - a) * k;
            return { edge: s.to.edge, rel: mix(s.from.rel, s.to.rel), along: mix(s.from.along, s.to.along),
                     out: mix(s.from.out, s.to.out) };
        }
        onWantedChanged: harness.retarget()
        Component.onCompleted: harness.retarget()
        function retarget() {
            const w = harness.wanted, s = harness.slide, now = harness.spanNow();
            if (!now || w.edge !== s.to.edge || !harness.childPresent) {
                // Nothing drawn, or another side: the target itself.
                harness.slide = { from: w, to: w };
                return;
            }
            if (w.rel === s.to.rel && w.along === s.to.along && w.out === s.to.out)
                return;
            const k = Geo.ease(2, harness.slideT, 0);
            if (harness.slideT < 1 && k < 1 - 1e-6) {
                // A slide is running: keep its clock, solve where it must have
                // come from (the engine's _childResized).
                const back = (n, t) => (n - k * t) / (1 - k);
                harness.slide = { from: { edge: w.edge, rel: back(now.rel, w.rel), along: back(now.along, w.along),
                                          out: back(now.out, w.out) }, to: w };
            } else if (w.along !== s.to.along || w.out !== s.to.out) {
                // The content took a new size: slide there from where it is drawn.
                harness.slide = { from: now, to: now };
                harness.slideT = 0;
                harness.slide = { from: now, to: w };
                slideAnim.restart();
            } else {
                // The popup moved under it: follow.
                harness.slide = { from: w, to: w };
            }
        }
        NumberAnimation {
            id: slideAnim
            target: harness
            property: "slideT"
            from: 0
            to: 1
            duration: harness.slideMs
        }
        // The content's presence, and the swap that assigns the key while it
        // is hidden.
        property real contentF: 0
        NumberAnimation {
            id: contentFade
            target: harness
            property: "contentF"
            duration: harness.fadeMs
            easing.type: Easing.OutCubic
        }
        SequentialAnimation {
            id: swap
            NumberAnimation { target: harness; property: "contentF"; to: 0; duration: harness.fadeMs; easing.type: Easing.OutCubic }
            ScriptAction { script: harness.assignKey() }
            NumberAnimation { target: harness; property: "contentF"; to: 1; duration: harness.fadeMs; easing.type: Easing.OutCubic }
        }
        function assignKey() {
            if (harness.detail && ("secondaryKey" in harness.detail))
                harness.detail.secondaryKey = popup.secondaryKey;
        }
        function fadeContent(to) {
            swap.stop();
            contentFade.stop();
            contentFade.to = to;
            contentFade.restart();
        }

        Connections {
            target: popup
            function onSecondaryOpenChanged() {
                if (popup.secondaryOpen) {
                    // Assigned while hidden, then the box grows and the content fades in.
                    harness.assignKey();
                    slideAnim.stop();
                    harness.slideT = 1;
                    harness.anchorUsed = popup.secondaryAnchor;
                    harness.retarget();
                    closeAnim.stop();
                    harness.openT = 0;
                    harness.closing = false;
                    openAnim.restart();
                    harness.fadeContent(1);
                } else {
                    openAnim.stop();
                    harness.closeFrom = harness.e;
                    if (win.traceArmed) {
                        // ARM: round 1's order -- the flag first, then the clock.
                        harness.closing = true;
                        harness.closeT = 0;
                    } else {
                        harness.closeT = 0;
                        harness.closing = true;
                    }
                    closeAnim.duration = Math.max(1, Math.round(harness.openMs * harness.closeFrom));
                    closeAnim.restart();
                    harness.fadeContent(0);
                    win.traceStats.closes++;
                }
            }
            function onSecondaryKeyChanged() {
                if (!popup.secondaryOpen)
                    return;
                // Slide from where it is drawn now: frozen there on a clock at
                // 0, the new anchor's target is solved from here (retarget runs
                // on the anchor's change, and again in case the anchor was the
                // same and only an unfinished slide's target is left); swap the
                // content while hidden.
                const now = harness.spanNow();
                slideAnim.stop();
                if (now)
                    harness.slide = { from: now, to: now };
                harness.slideT = 0;
                harness.anchorUsed = popup.secondaryAnchor;
                harness.retarget();
                slideAnim.restart();
                contentFade.stop();
                swap.restart();
            }
        }

        // ---- The stage: one size for every shape --------------------------------
        // Where the extremes start, measured by PROBE=measure (8597 states: all
        // 28 mock scenarios in every view; the detail at every metric x
        // scenario x day 0..15 x pollutant tab; retaken whenever a card's height
        // changes, last 2026-09-23 after round 5's one hero for every view):
        // every view is now one height whatever the scenario -- mini 184,
        // normal 737, detailed 689 (the warning chip that made thunder taller
        // is gone); the detail is 420 wide and 1051 tall at most (wind, whose
        // Beaufort table is the longest). The widths are the popup's own knobs.
        // These are MARKS: the popup's extents only widen them (the shortest
        // height only lowers), so a shape the measurement did not cover -- a
        // taller chart from the panel -- grows the stage once instead of being
        // cut off, and nothing ever shrinks it back.
        property real popWMin: 504
        property real popWMax: 1180
        property real popHMin: 184
        property real popHMax: 737
        property real childWMax: 420
        property real childHMax: 1051
        // What the marks follow: every view's width, the popup's height now and
        // the two tall views' heights, the detail's size now.
        readonly property var seen: [popup.miniWidth, popup.normalWidth, popup.detailedWidth, popup.implicitWidth,
                                     popup.implicitHeight, popup._heightNormal, popup._heightDetailed,
                                     harness.childFullW, harness.childFullH]
        // Taken AFTER the change's cascade settles, not inside it: a view
        // switch moves a card's height through intermediate values within one
        // cascade (the hero's `compact` lands before its fonts and its KMI row
        // follow: 829 on the way into normal, 199/183/180 into mini, measured
        // 2026-09-22), which no frame ever shows -- a high-water mark read in
        // the cascade kept them, and the stage grew for a shape that never
        // existed. Round 2's 180 minimum was one of these.
        onSeenChanged: Qt.callLater(harness.takeMarks)
        function takeMarks() {
            const s = harness.seen;
            harness.popWMin = Math.min(harness.popWMin, s[0], s[1], s[2]);
            harness.popWMax = Math.max(harness.popWMax, s[0], s[1], s[2], s[3]);
            if (popup.mini)
                harness.popHMin = Math.min(harness.popHMin, s[4]);
            harness.popHMax = Math.max(harness.popHMax, s[4], s[5], s[6]);
            harness.childWMax = Math.max(harness.childWMax, s[7]);
            harness.childHMax = Math.max(harness.childHMax, s[8]);
        }
        // The open's overshoot carries the child past its full size: the peak
        // of OutBack(s) is at u = -2s / 3(s + 1).
        readonly property real eMax: {
            const s = harness.openOvershoot, u = -2 * s / (3 * (s + 1));
            return u * u * ((s + 1) * u + s) + 1;
        }
        // Along a side: the child is centred on a popup shorter than it, else
        // kept inside the popup's span, and the overshoot carries each end out
        // by (e - 1) of up to half the span (childBox's a0 = o0 + (s0 - o0) e).
        function spanOf(pMin, pMax, len) {
            const k = (harness.eMax - 1) * len / 2;
            return [Math.min(0, (pMin - len) / 2) - k, Math.max(pMax, (Math.min(pMax, len) + len) / 2) + k];
        }
        // The reserve in the popup's coordinates: every popup box and every
        // child box the marks allow on this side.
        readonly property var reserve: {
            const cw = harness.childWMax * harness.eMax, ch = harness.childHMax * harness.eMax;
            const across = harness.spanOf(harness.popWMin, harness.popWMax, harness.childWMax);
            const down = harness.spanOf(harness.popHMin, harness.popHMax, harness.childHMax);
            switch (harness.childEdge) {
            case "top": return { x0: across[0], y0: -ch, x1: across[1], y1: harness.popHMax };
            case "left": return { x0: -cw, y0: down[0], x1: harness.popWMax, y1: down[1] };
            case "right": return { x0: 0, y0: down[0], x1: harness.popWMax + cw, y1: down[1] };
            default: return { x0: across[0], y0: 0, x1: across[1], y1: harness.popHMax + ch };
            }
        }
        readonly property real originX: Math.ceil(harness.margin - harness.reserve.x0)
        readonly property real originY: Math.ceil(harness.margin - harness.reserve.y0)
        implicitWidth: win.stageArmed
            ? harness.originX + Math.max(harness.popW, harness.childBox ? harness.childBox.x1 - harness.originX : 0) + harness.margin
            : Math.ceil(harness.originX + harness.reserve.x1 + harness.margin)
        implicitHeight: win.stageArmed
            ? harness.originY + Math.max(harness.popH, harness.childBox ? harness.childBox.y1 - harness.originY : 0) + harness.margin
            : Math.ceil(harness.originY + harness.reserve.y1 + harness.margin)

        // ---- Geometry -----------------------------------------------------------
        // The child while it is present: its FULL box relative to the popup's
        // top-left at its target place, and the span drawn now -- one object,
        // so the two are always one generation.
        readonly property var childFull: {
            const t = harness.slide.to;
            if (!harness.childPresent || !t || t.along <= 0)
                return null;
            let box;
            switch (t.edge) {
            case "top": box = { x0: t.rel, y0: -t.out, x1: t.rel + t.along, y1: 0 }; break;
            case "left": box = { x0: -t.out, y0: t.rel, x1: 0, y1: t.rel + t.along }; break;
            case "right": box = { x0: harness.popW, y0: t.rel, x1: harness.popW + t.out, y1: t.rel + t.along }; break;
            default: box = { x0: t.rel, y0: harness.popH, x1: t.rel + t.along, y1: harness.popH + t.out };
            }
            return { box: box, span: harness.spanNow() };
        }

        // The child's box THIS FRAME, in harness coordinates (the engine's
        // _childBox: it opens out of the parent from widthFrom 0.5 of its
        // span about its final centre, clamped to the parent's side), with
        // the extent it was built at and, while the clock runs, the full box
        // it is heading for (the field's `stick`). Built from ONE read of
        // `childFull`, so whether there is a box and where its stick goes are
        // always one generation. (ARM: round 1 took the box's presence from
        // `childPresent` and read `childFull` separately in `bodies` -- two
        // re-evaluation generations, which is what the stale null came from.)
        readonly property var childBox: {
            const cf = win.traceArmed ? null : harness.childFull;
            const sp = win.traceArmed ? harness.spanNow() : (cf ? cf.span : null);
            if (win.traceArmed ? !harness.childPresent || !sp || sp.along <= 0 : !cf)
                return null;
            const ox = harness.originX, oy = harness.originY;
            const pb = { x0: ox, y0: oy, x1: ox + harness.popW, y1: oy + harness.popH };
            const sw = sp.edge === "left" || sp.edge === "right";
            const p0 = sw ? pb.y0 : pb.x0, p1 = sw ? pb.y1 : pb.x1;
            const along = sp.along, out = sp.out, e = harness.e;
            const outNow = Math.max(0, out * e);
            const s0 = p0 + sp.rel;
            const c = s0 + along / 2;
            let o0 = Math.max(c - along * 0.25, p0), o1 = Math.min(c + along * 0.25, p1);
            if (o1 < o0) {
                const m = Math.min(Math.max(c, p0), p1);
                o0 = m;
                o1 = m;
            }
            const a0 = o0 + (s0 - o0) * e, a1 = o1 + (s0 + along - o1) * e;
            const fb = cf ? cf.box : null;
            const stick = harness.moving && fb ? { x0: ox + fb.x0, y0: oy + fb.y0, x1: ox + fb.x1, y1: oy + fb.y1 } : null;
            const fullW = sw ? out : along, fullH = sw ? along : out;
            switch (sp.edge) {
            case "top": return { x0: a0, y0: pb.y0 - outNow, x1: a1, y1: pb.y0, e: e, fullW: fullW, fullH: fullH, stick: stick };
            case "left": return { x0: pb.x0 - outNow, y0: a0, x1: pb.x0, y1: a1, e: e, fullW: fullW, fullH: fullH, stick: stick };
            case "right": return { x0: pb.x1, y0: a0, x1: pb.x1 + outNow, y1: a1, e: e, fullW: fullW, fullH: fullH, stick: stick };
            default: return { x0: a0, y0: pb.y1, x1: a1, y1: pb.y1 + outNow, e: e, fullW: fullW, fullH: fullH, stick: stick };
            }
        }
        // ARM (PROBE=trace ARM=1): round 1's SECOND read of childFull beside
        // the box, gated on the clock itself as round 1 read `t < 1`, which
        // meets the stale null the old write order leaves.
        function armedStick() {
            if (!(harness.closing ? harness.closeT < 1 : harness.openT < 1))
                return null;
            const cf = harness.childFull;
            if (!cf)
                win.traceStats.nullReads++;
            return { x0: harness.originX + cf.box.x0, y0: harness.originY + cf.box.y0,
                     x1: harness.originX + cf.box.x1, y1: harness.originY + cf.box.y1 };
        }
        readonly property var bodies: {
            const list = [{
                id: "pop", x0: harness.originX, y0: harness.originY,
                x1: harness.originX + harness.popW, y1: harness.originY + harness.popH,
                r: harness.maxR, mobile: true, stick: null
            }];
            const cb = harness.childBox;
            if (cb && cb.e > 0.001) {
                const tr = Geo.tensionRadii(cb.x1 - cb.x0, cb.y1 - cb.y0, cb.fullW, cb.fullH, harness.maxR);
                list.push({ id: "child", x0: cb.x0, y0: cb.y0, x1: cb.x1, y1: cb.y1,
                            rx: tr.rx, ry: tr.ry, mobile: true, stick: win.traceArmed ? harness.armedStick() : cb.stick,
                            parent: "pop" });
            }
            return list;
        }

        // ---- The scene ------------------------------------------------------------
        Image {
            anchors.fill: parent
            source: win.wallpaper
            asynchronous: true
            cache: true
            fillMode: Image.PreserveAspectCrop
        }

        GooeyField {
            id: field
            anchors.fill: parent
            color: Theme.surface
            bodies: harness.bodies
        }

        // THE STAGE HEARS NO WHEEL THE POPUP HEARD. The popup's one wheel
        // reader never accepts an event, and the stage is a plain interactive
        // Flickable, so without these every notch that cycled the strip,
        // cycled the list or switched the view ALSO scrolled the emulated
        // desktop 72 px, and the next notch landed on another card -- two
        // readers of one wheel (CLAUDE.md). They lie UNDER the popup and the
        // detail, so every reader inside those hears the event first; what
        // they leave ends here. While a gesture is live the router above
        // everything (gestureRouter, below) takes every wheel instead. The
        // wallpaper around the shapes and the stage's scroll bars still pan
        // it. ARM=leak (PROBE=swipe) turns both off.
        WheelArea {
            id: popupWheelCatch
            x: popupBody.x
            y: popupBody.y
            width: popupBody.width
            height: popupBody.height
            enabled: !win.leakArmed
            turned: wheel => {
                wheel.accepted = true;
            }
        }
        WheelArea {
            x: childHost.x
            y: childHost.y
            width: childHost.width
            height: childHost.height
            visible: childHost.visible
            enabled: !win.leakArmed
            turned: wheel => {
                wheel.accepted = true;
            }
        }

        // The popup's body, as GooeyBody hosts it: the content sized to the
        // box the host is easing and CLIPPED to it (GooeyBody is `clip: true`
        // at popW x popH, plus its rounded cut while the outline moves). A
        // view switch moves the cards at once while the box eases, so without
        // the clip the cards of the taller view hung out of the popup for the
        // 260 ms of the resize (the user, round 3, detailed -> normal); the
        // real engine cuts them at the moving edge, and now so does this.
        Item {
            id: popupBody
            x: harness.originX
            y: harness.originY
            width: harness.popW
            height: harness.popH
            clip: true

            WeatherPopup {
                id: popup
                eagerCards: true
                cardFloat: win.floatOn
                service: win.svc
                fontFamily: "Audiowide"
                // The stage's live zoom: the static layers allocate their
                // textures at it, so a magnified stage does not show them soft.
                renderScale: win.stage ? win.stage.zoom : 1
                x: 0
                y: 0
                width: popupBody.width
                height: popupBody.height
            }
        }

        // The child's host: the box, clipped, with the detail laid at its full
        // size against the attach face so it unrolls out of the popup.
        Item {
            id: childHost
            readonly property var b: harness.childBox
            visible: childHost.b !== null
            x: childHost.b ? childHost.b.x0 : 0
            y: childHost.b ? childHost.b.y0 : 0
            width: childHost.b ? childHost.b.x1 - childHost.b.x0 : 0
            height: childHost.b ? childHost.b.y1 - childHost.b.y0 : 0
            clip: true

            Loader {
                id: detailLoader
                sourceComponent: popup.secondaryComponent
                width: harness.childFullW
                height: harness.childFullH
                x: harness.childEdge === "left" ? childHost.width - width
                 : harness.childEdge === "right" ? 0 : (childHost.width - width) / 2
                y: harness.childEdge === "top" ? childHost.height - height
                 : harness.childEdge === "bottom" ? 0 : (childHost.height - height) / 2
                opacity: harness.contentF
                visible: opacity > 0
            }
        }

        // THE STICKY GESTURE, as GooeyEngine's gestureLayer does it: while
        // the popup's or the detail's gesture is live, a wheel that lands
        // OUTSIDE its owner's clipped body goes to the owner's gestureWheel()
        // -- the view shrank under the fingers and nothing there would hear
        // it, or it landed on the OTHER body, whose reader would start a
        // gesture of its own and take the event (a view swipe drifting onto
        // the closing detail stepped its day). Inside the owner's body it is
        // let through to the content's own readers: the popup reads the
        // daily list's scroll through the list's own ScrollDressing, not
        // through gestureWheel(), and a router that took those too scrolled
        // the list one notch per motion (the user, round 5). Above
        // everything, and enabled only while a gesture lives. ARM=sticky
        // (PROBE=swipe) turns it off.
        WheelArea {
            id: gestureRouter
            readonly property var owner: popup.swipeGestureActive ? popup
                : harness.detail && harness.detail.swipeGestureActive === true ? harness.detail : null
            readonly property Item ownerBody: gestureRouter.owner === popup ? popupBody : childHost
            anchors.fill: parent
            enabled: !!gestureRouter.owner && !win.stickyArmed
            turned: wheel => {
                const b = gestureRouter.mapToItem(gestureRouter.ownerBody, wheel.x, wheel.y);
                if (b.x >= 0 && b.y >= 0 && b.x < gestureRouter.ownerBody.width && b.y < gestureRouter.ownerBody.height) {
                    wheel.accepted = false;
                    return;
                }
                const p = gestureRouter.mapToItem(gestureRouter.owner, wheel.x, wheel.y);
                gestureRouter.owner.gestureWheel(Object.assign({}, wheel, { x: p.x, y: p.y }));
                wheel.accepted = true;
            }
        }

        // STAGE_GRAB: the harness alone, at 1:1, then quit.
        Timer {
            running: win.stageGrab !== ""
            interval: win.grabMs
            onTriggered: harness.grabToImage(function (r) {
                r.saveToFile(win.stageGrab);
                console.log("STAGE_GRAB saved " + win.stageGrab);
                Qt.quit();
            })
        }
    }

    // =====================================================================
    //  THE PROBES
    //
    // Each is a list of steps [delay ms, name, function] on one clock, so a
    // step can wait for an open, a slide or the host's resize to finish, and
    // each prints one RESULT line and quits. Clicks and wheels are real
    // synthetic events through the WINDOW (QtTest), so everything that could
    // steal them is in the chain.
    // =====================================================================
    TestCase {
        id: tc
        name: "weather_probe"
        when: false
    }
    Timer {
        running: win.probeKind !== ""
        interval: 1800
        onTriggered: {
            switch (win.probeKind) {
            case "1": win.runSteps(win.clickSteps()); break;
            case "swipe": win.runSteps(win.swipeSteps()); break;
            case "trace": win.runSteps(win.traceSteps()); break;
            case "stage": win.runSteps(win.stageSteps()); break;
            case "tip": win.runSteps(win.tipSteps()); break;
            case "measure": win.startMeasure(); break;
            default: console.log("weather mockup: no probe '" + win.probeKind + "'");
            }
        }
    }
    property var probeSteps: []
    property int probeStep: 0
    property string probeStepName: ""
    property var probeFails: []
    property int settleTries: 0
    function motionIdle() {
        const d = harness.detail;
        return !popup.hourlyStrip.scrolling && !popup.dailyList.scrolling && !(d && d.scrolling === true);
    }
    function runSteps(steps) {
        win.probeSteps = steps;
        win.probeStep = 0;
        probeTimer.interval = steps[0][0];
        probeTimer.restart();
    }
    function fail(msg) {
        win.probeFails.push(win.probeStepName + ": " + msg);
    }
    function report(name) {
        const f = win.probeFails;
        console.log("WEATHER " + name + " RESULT " + (f.length === 0 ? "PASS" : "FAIL: " + f.join("; ")));
        Qt.quit();
    }
    Timer {
        id: probeTimer
        onTriggered: {
            // A notch GLIDES and a lift COASTS (modules/common/scroll): a step starts
            // once every scroller has landed, or what it reads is the motion's middle.
            // Offscreen a Timer's interval is not wall time and the engine moves by wall
            // time, so wait on the motion itself, never on an interval.
            if (!win.motionIdle() && win.settleTries++ < 600) {
                probeTimer.interval = 20;
                probeTimer.restart();
                return;
            }
            win.settleTries = 0;
            const s = win.probeSteps[win.probeStep];
            win.probeStepName = s[1];
            console.log("WEATHER STEP " + win.probeStep + " " + s[1]);
            s[2]();
            win.probeStep++;
            if (win.probeStep < win.probeSteps.length) {
                probeTimer.interval = win.probeSteps[win.probeStep][0];
                probeTimer.restart();
            }
        }
    }
    // The stage scrolls: an item below the window's foot has to be brought
    // into view, or the event lands outside the window.
    function scrollStageTo(it) {
        const st = win.stage;
        const p = it.mapToItem(st.contentItem, it.width / 2, it.height / 2);
        st.contentX = Math.max(0, Math.min(st.contentWidth - st.width, p.x - st.width / 2));
        st.contentY = Math.max(0, Math.min(st.contentHeight - st.height, p.y - st.height / 2));
    }
    function centreOf(it) {
        win.scrollStageTo(it);
        return it.mapToItem(null, it.width / 2, it.height / 2);
    }

    // ---- PROBE=1: the clicks ------------------------------------------------
    // A strip column in the wind view opens wind at that hour (from the
    // strip), a daily row in the precipitation view opens precipitation for
    // that day (from the list) and slides the open detail there, a tile in the
    // detailed view opens its metric (from the tile), the hero's glyph opens
    // the conditions; each must carry its key WITH `from` and an anchor within
    // a pixel of the item's centre in the popup's coordinates, and the same
    // click again closes it. ARM=1 expects the anchor 10 px off, which must
    // FAIL: a check that cannot fail proves nothing.
    function clickAt(key, open) {
        const it = popup.linkItem(key);
        if (!it) {
            win.fail("no link item for " + JSON.stringify(key));
            return;
        }
        const wc = win.centreOf(it);
        tc.mouseClick(win.contentItem, wc.x, wc.y);
        if (popup.secondaryOpen !== open) {
            win.fail("secondaryOpen " + popup.secondaryOpen + ", expected " + open);
            return;
        }
        if (!open)
            return;
        const k = popup.secondaryKey;
        if (!popup.sameKey(k, key) || k.from !== key.from)
            win.fail("key " + JSON.stringify(k) + ", expected " + JSON.stringify(key));
        const exp = it.mapToItem(popup, it.width / 2, it.height / 2);
        if (win.armed)
            exp.x += 10;
        const d = Math.hypot(popup.secondaryAnchor.x - exp.x, popup.secondaryAnchor.y - exp.y);
        if (!(d <= 1))
            win.fail("anchor " + popup.secondaryAnchor.x.toFixed(1) + "," + popup.secondaryAnchor.y.toFixed(1)
                     + " is " + d.toFixed(2) + " px from the centre " + exp.x.toFixed(1) + "," + exp.y.toFixed(1));
        console.log("WEATHER CLICK " + win.probeStepName + ": key=" + JSON.stringify(k)
                    + " anchor=" + popup.secondaryAnchor.x.toFixed(1) + "," + popup.secondaryAnchor.y.toFixed(1));
    }
    function clickSteps() {
        const S = popup.hourlyStrip, L = popup.dailyList;
        const col = 3, row = 2;
        let colKey = null;
        const rowKey = { metric: "precipitation", dayIndex: row, hourIndex: null, from: "daily" };
        const tileKey = { metric: "wind", dayIndex: 0, hourIndex: null, from: "tile" };
        return [
            [0, "views: strip wind, list precipitation", function () {
                win.setCardView(S, "wind");
                win.setCardView(L, "precipitation");
                colKey = S.keyAt(col);
                if (!colKey || colKey.metric !== "wind" || colKey.from !== "hourly")
                    win.fail("keyAt(" + col + ") in the wind view is " + JSON.stringify(colKey));
            }],
            [400, "strip column " + col + " (wind)", function () { win.clickAt(colKey, true); }],
            [450, "daily row " + row + " (precipitation, slides)", function () { win.clickAt(rowKey, true); }],
            [450, "daily row " + row + " again", function () { win.clickAt(rowKey, false); }],
            [450, "strip column " + col + " again opens", function () { win.clickAt(colKey, true); }],
            [450, "strip column " + col + " again closes", function () { win.clickAt(colKey, false); }],
            [450, "hero glyph", function () { win.clickAt(popup.hero.glyphItem.key, true); }],
            [450, "view detailed (closes the detail)", function () {
                popup.viewMode = "detailed";
                if (popup.secondaryOpen)
                    win.fail("the view switch left the detail open");
            }],
            [700, "tile wind", function () { win.clickAt(tileKey, true); }],
            [450, "tile wind again", function () { win.clickAt(tileKey, false); }],
            [450, "done", function () { win.report("CLICK"); }]
        ];
    }

    // ---- PROBE=tip: the location's tooltip stands under the location -------------
    // The pointer goes over the location link in each view (mini, normal, detailed), the tip's delay passes, and the bubble (the popup's
    // child at z 1000, the one HoverTip reparents into the overlay) must be BELOW the link, close to it, and its span must hold the link's
    // middle: in the detailed view the tip used to be centred on the whole slot the header leaves for the text, half a popup wide, and
    // stood far right of the name (feedback/weather.md "Tooltip positioning issue in detailed"). Also the link's own extent: the pointer in the
    // empty header, past the link, opens no tip. ARM=1 expects the bubble's middle 40 px off, which must FAIL.
    function tipBubble() {
        for (let i = 0; i < popup.children.length; i++) {
            const c = popup.children[i];
            if (c.z === 1000 && c.visible && c.opacity > 0.9)
                return c;
        }
        return null;
    }
    function tipStepsFor(view) {
        return [
            [600, "view " + view + ", the pointer away", function () {
                popup.viewMode = view;
                tc.mouseMove(win.contentItem, 3, 3);
            }],
            [500, "hover the location in " + view, function () {
                const c = win.centreOf(popup.locationHit);
                tc.mouseMove(win.contentItem, c.x - 1, c.y);
                tc.mouseMove(win.contentItem, c.x, c.y);
            }],
            [1100, "the tip of " + view + " stands under the location", function () {
                const b = win.tipBubble();
                if (!b) {
                    win.fail(view + ": no tip bubble opened over the location");
                    return;
                }
                const loc = popup.locationHit;
                const box = loc.mapToItem(popup, 0, 0);
                const mid = box.x + loc.width / 2;
                const bMid = b.x + b.width / 2 + (win.armed ? 40 : 0);
                const gap = b.y - (box.y + loc.height);
                // the bubble holds the link's middle and, centred on it, is within 2 px of it unless the popup's own edge clamped it
                const centred = Math.abs(bMid - mid) <= 2 || b.x <= 2.5 || b.x + b.width >= popup.width - 2.5;
                console.log("WEATHER TIP " + view + ": link x " + box.x.toFixed(1) + " w " + loc.width + " mid " + mid.toFixed(1)
                            + ", bubble x " + b.x + " w " + b.width + " y " + b.y + " (gap " + gap.toFixed(1) + ")");
                if (!(b.x <= mid && mid <= b.x + b.width))
                    win.fail(view + ": the bubble (" + b.x + ".." + (b.x + b.width) + ") does not hold the link's middle " + mid.toFixed(1));
                if (!centred)
                    win.fail(view + ": the bubble's middle " + bMid.toFixed(1) + " is " + Math.abs(bMid - mid).toFixed(1) + " px from the link's " + mid.toFixed(1));
                if (gap < -1 || gap > 14)
                    win.fail(view + ": the bubble's top is " + gap.toFixed(1) + " px under the link, not just below it");
            }]
        ];
    }
    function tipSteps() {
        const out = [];
        for (const v of ["mini", "normal", "detailed"])
            for (const st of win.tipStepsFor(v))
                out.push(st);
        out.push([300, "past the link, in the empty header (detailed)", function () {
            popup.viewMode = "detailed";
            tc.mouseMove(win.contentItem, 3, 3);
        }]);
        out.push([500, "pointer in the header past the link", function () {
            const loc = popup.locationHit;
            const p = loc.mapToItem(null, loc.width + 40, loc.height / 2);
            tc.mouseMove(win.contentItem, p.x - 1, p.y);
            tc.mouseMove(win.contentItem, p.x, p.y);
        }]);
        out.push([1100, "no tip, no hand, over the empty header", function () {
            if (win.tipBubble())
                win.fail("a tip opened over the empty header, 40 px past the link");
        }]);
        out.push([200, "done", function () { win.report("TIP"); }]);
        return out;
    }

    // ---- PROBE=swipe: the one wheel reader's routes -------------------------
    // Synthetic wheels through the window, each gesture ended by the
    // zero-delta event: sideways ones are fingers (angle and pixels), upright
    // ones a mouse's notches. DIAGONAL deltas wherever the route depends on
    // the axis (docs/contracts/gestures.md: a straight one passes with the axis
    // wrong). Normal view, live fixture, unless a step says otherwise:
    //
    //   over the list, ten (-120, 40)      the LIST's view ten steps back; the
    //                                      list unscrolled, the popup's view kept
    //   over the strip, ten (-120, 40)     the strip scrolls; every view kept
    //   over the strip, one (0, -120)      the STRIP's view one step on, unscrolled
    //   over the list, three (20, -120)    the list scrolls (its own reader),
    //                                      its view kept
    //   over the hero, three (0, -120)     nothing changes
    //   30 px into the strip's left, one (0, -120)   the strip's view steps and
    //   30 px into the list's left, ten (-120, 40)   the list's view cycles, the
    //                                      popup's view kept: the owner is picked
    //                                      where the pointer IS, not inside the
    //                                      hold rect the gesture grows into
    //   over the list, (-60, 60) then ten (-120, 0)  an undecided first event:
    //                                      the list cycles and never scrolls
    //   over the strip (0, 120), then over the list (0, 120), one gesture:
    //                                      the strip's view two steps back; the
    //                                      list the gesture drifted onto does
    //                                      not scroll
    //   swipeToSwitchView off: three (-120, 0) over the strip still scroll it,
    //                                      one (0, -120) still cycles it, three
    //                                      (-120, 0) over the list still cycle
    //                                      it, ten (-120, 40) over the hero
    //                                      change nothing
    //   detailed: a notch 10 px into the strip's top cycles the strip; one 10
    //                                      px into the tiles' top changes nothing
    //   normal, detail open: ten (-120, 40) over the hero switch the popup's
    //                                      view and close the detail
    //
    // Every step checks EVERYTHING a gesture could move (both cards' views and
    // scrolls, the popup's view), not only what it expects to move. And after
    // every gesture the STAGE must not have moved: the popup's wheels are the
    // popup's, and a stage that scrolled under one slid the whole emulated
    // desktop and put the next notch on another card. Read at the next step,
    // past the stage Flickable's glide.
    // ARM=1 aims every gesture at the wrong card: every routing check FAILS.
    // ARM=leak turns the harness's wheel catchers off: the stage checks FAIL.
    property var swipeStage: null
    property var pendingCheck: null
    function flushCheck() {
        const c = win.pendingCheck;
        win.pendingCheck = null;
        if (!c)
            return;
        const was = win.probeStepName;
        win.probeStepName = c.name;
        c.run(c.view);
        win.probeStepName = was;
    }
    // The sticky case's pointer, held across its steps.
    property point stickyPoint: Qt.point(0, 0)
    // n steps 100 ms apart, each a small sideways wheel at the sticky point:
    // the fingers still moving between two strokes.
    function stickyKeepAlive(n) {
        const out = [];
        for (let i = 0; i < n; i++)
            out.push([100, "sticky: fingers still moving", function () {
                win.touch(win.stickyPoint, -1, 0, Qt.ScrollUpdate);
                win.noteStage();
            }]);
        return out;
    }
    function noteStage() {
        win.swipeStage = { x: win.stage.contentX, y: win.stage.contentY, step: win.probeStepName };
    }
    function stageStill() {
        const s = win.swipeStage, st = win.stage;
        if (s && (st.contentX !== s.x || st.contentY !== s.y))
            win.fail("the stage moved " + s.x.toFixed(0) + "," + s.y.toFixed(0) + " -> " + st.contentX.toFixed(0) + ","
                     + st.contentY.toFixed(0) + " under the gesture of '" + s.step + "'");
        win.swipeStage = null;
    }
    // A point of an item in window coordinates, the stage brought to the item.
    function aimAt(it, lx, ly) {
        win.scrollStageTo(it);
        const p = it.mapToItem(null, lx, ly);
        const v = win.stage.mapToItem(null, 0, 0);
        if (p.x < v.x || p.y < v.y || p.x > v.x + win.stage.width || p.y > v.y + win.stage.height)
            win.fail("aim " + p.x.toFixed(0) + "," + p.y.toFixed(0) + " is outside the stage's view");
        return p;
    }
    // One gesture: [point, dx, dy] events (angle units), then the zero-delta end at the last point. A motion that goes sideways is FINGERS
    // (QtTest has no pixels: they go along the readers under the point, as Qt would offer them); an upright one is a mouse's notches.
    function wheels(events) {
        win.noteStage();
        const fingers = events.some(ev => Math.abs(ev[1]) >= Math.abs(ev[2]));
        for (const ev of events) {
            if (fingers)
                win.touch(ev[0], ev[1] / 12, ev[2] / 12, Qt.ScrollUpdate);
            else
                tc.mouseWheel(win.contentItem, ev[0].x, ev[0].y, ev[1], ev[2]);
        }
        const last = events[events.length - 1][0];
        if (fingers)
            win.touch(last, 0, 0, Qt.ScrollEnd);
        else
            tc.mouseWheel(win.contentItem, last.x, last.y, 0, 0);
    }
    function touch(p, px, py, phase) {
        WheelHub.deliver(WheelHub.chainAt(win.contentItem, p.x, p.y), win.contentItem, p.x, p.y, WheelHub.fingers(px, py, phase));
    }
    function gestureAt(it, lx, ly, dx, dy, n) {
        const p = win.aimAt(it, lx, ly);
        const events = [];
        for (let i = 0; i < n; i++)
            events.push([p, dx, dy]);
        win.wheels(events);
    }
    function gesture(it, dx, dy, n) {
        win.gestureAt(it, it.width / 2, it.height / 2, dx, dy, n);
    }
    // A GESTURE OF FINGERS IS ONE STEP: its events arrive in one burst, inside
    // the cards' step cooldown (CardViewCycler.stepCooldownMs, 200), so its
    // card moves ONE view. A mouse's notch is one view each. Which card moved,
    // and that nothing else did, is the routing check.
    function swipeSteps() {
        const S = popup.hourlyStrip, L = popup.dailyList, H = popup.hero, T = popup.tileGrid;
        const aim = function (right, wrong) { return win.armed ? wrong : right; };
        const wrap = (i, n) => ((i % n) + n) % n;
        const nS = S.views.length, nL = L.views.length;
        // Notches of 120 that carry one view step of the popup's selector, with a
        // little over (the swipe threshold is the selector's, not a number of
        // this probe), and the count that reverses a stroke that left a
        // remainder behind it.
        const nv = Math.ceil(popup.swipeThreshold / 120) + 1;
        const nBack = Math.ceil(popup.swipeThreshold / 120) + 4;
        const names = { sv: "the strip's view", ss: "the strip's scroll", lv: "the list's view", ls: "the list's scroll",
                        view: "the popup's view" };
        const state = () => ({ sv: S.viewIndex, ss: S.scrollPos, lv: L.viewIndex, ls: L.scrollPos, view: popup.viewMode });
        const said = s => "strip " + s.sv + "/" + Math.round(s.ss) + " list " + s.lv + "/" + Math.round(s.ls) + " popup " + s.view;
        // Every field `want` does not name must be unchanged; a named one must pass its test.
        // A check is READ AT THE NEXT STEP, once the glides have landed (a notch glides now);
        // the popup's view is read at once, because the step goes on to put it back.
        const check = function (a, want) {
            win.pendingCheck = { name: win.probeStepName, view: popup.viewMode, run: function (viewNow) {
                const b = state();
                b.view = viewNow;
                console.log("WEATHER SWIPE " + win.probeStepName + ": " + said(a) + " -> " + said(b));
                for (const k in names) {
                    if (k in want) {
                        if (!want[k].ok(a[k], b[k]))
                            win.fail(names[k] + " " + a[k] + " -> " + b[k] + ", expected " + want[k].what);
                    } else if (a[k] !== b[k]) {
                        win.fail(names[k] + " " + a[k] + " -> " + b[k] + ", expected it unchanged");
                    }
                }
            } };
        };
        const to = v => ({ ok: (x, y) => y === v, what: String(v) });
        const grew = { ok: (x, y) => y > x, what: "more" };
        const moved = { ok: (x, y) => y !== x, what: "another" };
        const steps = [
            [0, "diagonal over the list", function () {
                win.setCardView(L, "0");
                const a = state();
                win.gesture(aim(L, H), -120, 40, 10);
                check(a, { lv: to(wrap(a.lv - 1, nL)) });
                popup.viewMode = "normal";
            }],
            [700, "diagonal over the strip", function () {
                // The content follows the fingers (the shell's one scroll feel): fingers to the left take the strip to
                // later hours.
                if (win.stripsignArmed)
                    popup.stripScrollReversed = true;
                const a = state();
                win.gesture(aim(S, L), -120, 40, 10);
                check(a, { ss: grew });
                popup.viewMode = "normal";
            }],
            [700, "vertical notch over the strip", function () {
                const a = state();
                win.gesture(aim(S, L), 0, -120, 1);
                check(a, { sv: to(wrap(a.sv + 1, nS)) });
                popup.viewMode = "normal";
            }],
            [700, "touchpad fingers DOWN over the strip: the next view (the dot follows the hand)", function () {
                // QtTest sends angles only, so a touchpad's stroke (pixels AND angles, y > 0 for fingers down here) goes
                // through the popup's own reader, the way its MouseArea hands it on.
                const a = state();
                const t = win.armed ? L : S;
                const q = t.mapToItem(popup, t.width / 2, t.height / 2);
                win.scrollStageTo(t);
                const sg = win.stripsignArmed ? -1 : 1;
                // 10 x 120 angle units: past the cycler's touchpad detent (pixelThreshold 1000) once.
                for (let i = 0; i < 10; i++)
                    popup._wheel(q.x, q.y, WheelHub.fingers(0, sg * 10, Qt.ScrollUpdate));
                popup._wheel(q.x, q.y, WheelHub.fingers(0, 0, Qt.ScrollEnd));
                check(a, { sv: to(wrap(a.sv + 1, nS)) });
                popup.viewMode = "normal";
            }],
            [700, "vertical over the list", function () {
                // Three notches in ONE motion travel three notches: the
                // round-4 router took every wheel after the first away from
                // the list's own reader, and the list moved one notch per
                // motion (the user, round 5).
                const a = state();
                const notch = 120 * popup.scrollSpeed;
                win.gesture(aim(L, S), 20, -120, 3);
                check(a, { ls: { ok: (x, y) => y - x > 1.5 * notch, what: "more than 1.5 notches (" + 1.5 * notch + " px) further" } });
                popup.viewMode = "normal";
            }],
            [700, "vertical over the hero", function () {
                const a = state();
                win.gesture(aim(H, S), 0, -120, 3);
                check(a, {});
                popup.viewMode = "normal";
            }],
            [700, "notch 30 px into the strip's left", function () {
                const a = state();
                const it = aim(S, H);
                win.gestureAt(it, 30, it.height / 2, 0, -120, 1);
                check(a, { sv: to(wrap(a.sv + 1, nS)) });
                popup.viewMode = "normal";
            }],
            [700, "sideways 30 px into the list's left", function () {
                const a = state();
                const it = aim(L, H);
                win.gestureAt(it, 30, 60, -120, 40, 10);
                check(a, { lv: to(wrap(a.lv - 1, nL)) });
                popup.viewMode = "normal";
            }],
            [700, "undecided first event over the list", function () {
                const a = state();
                if (!(a.ls > 0))
                    win.fail("the list is at its top, where a stray upward scroll cannot show");
                const it = aim(L, H);
                const p = win.aimAt(it, it.width / 2, it.height / 2);
                const ev = [[p, -60, 60]];
                for (let i = 0; i < 10; i++)
                    ev.push([p, -120, 0]);
                win.wheels(ev);
                check(a, { lv: to(wrap(a.lv - 1, nL)) });
                popup.viewMode = "normal";
            }],
            [700, "a strip gesture drifting onto the list", function () {
                const a = state();
                if (!(a.ls > 0))
                    win.fail("the list is at its top, where a stray upward scroll cannot show");
                const from = aim(S, L), onto = aim(L, S);
                const p = win.aimAt(from, from.width / 2, from.height / 2);
                const q = onto.mapToItem(null, onto.width - 88, 60);
                win.wheels([[p, 0, 120], [q, 0, 120]]);
                check(a, { sv: to(wrap(a.sv - 2, nS)) });
                popup.viewMode = "normal";
            }],
            [700, "switch off: sideways over the strip", function () {
                popup.swipeToSwitchView = false;
                // From the start: the earlier steps' notches (x ScrollFeel.hSpeed) left it at the end.
                S.scrollBy(-1e9);
                const a = state();
                win.gesture(aim(S, L), -120, 0, 3);
                check(a, { ss: grew });
            }],
            [700, "switch off: vertical notch over the strip", function () {
                const a = state();
                win.gesture(aim(S, L), 0, -120, 1);
                check(a, { sv: to(wrap(a.sv + 1, nS)) });
            }],
            [700, "switch off: sideways over the list", function () {
                const a = state();
                win.gesture(aim(L, S), -120, 0, 10);
                check(a, { lv: to(wrap(a.lv - 1, nL)) });
            }],
            [700, "switch off: diagonal over the hero", function () {
                const a = state();
                win.gesture(aim(H, S), -120, 40, nv);
                check(a, {});
                popup.swipeToSwitchView = true;
                popup.viewMode = "normal";
            }],
            [700, "view detailed", function () {
                popup.viewMode = "detailed";
            }],
            [700, "detailed: notch 10 px into the strip's top", function () {
                const a = state();
                const it = aim(S, T);
                win.gestureAt(it, it.width / 2, 10, 0, -120, 1);
                check(a, { sv: to(wrap(a.sv + 1, nS)) });
                popup.viewMode = "detailed";
            }],
            [700, "detailed: notch 10 px into the tiles' top", function () {
                const a = state();
                const it = aim(T, S);
                win.gestureAt(it, it.width / 2, 10, 0, -120, 1);
                check(a, {});
                popup.viewMode = "detailed";
            }],
            [700, "normal, open the detail", function () {
                popup.viewMode = "normal";
                win.openFor("conditions", 0, null, false);
                if (!popup.secondaryOpen)
                    win.fail("the detail did not open");
            }],
            [700, "diagonal over the hero", function () {
                const a = state();
                win.gesture(aim(H, S), -120, 40, nv);
                check(a, { view: moved });
                if (popup.secondaryOpen)
                    win.fail("the detail is still open");
            }],
            // ONE GESTURE, ONE OWNER (round 4): a view stroke that starts on the
            // hero and runs on over the open detail is the popup's to the end --
            // the detail's own reader must not start a day swipe of its own and
            // take the events (with ARM=sticky it does: the day steps and the
            // view never switches).
            [700, "cross: normal, the detail open on day 2", function () {
                popup.viewMode = "normal";
                win.openFor("conditions", 2, null, false);
            }],
            [900, "cross: a view stroke from the hero onto the detail", function () {
                const d = harness.detail;
                if (!popup.secondaryOpen || !d) {
                    win.fail("cross: the detail did not open");
                    return;
                }
                // The hero in view first, then the middle of whatever part of
                // the detail is in view with it.
                const hp = win.aimAt(H, H.width / 2, H.height / 2);
                const v = win.stage.mapToItem(null, 0, 0);
                const c0 = childHost.mapToItem(null, 0, 0);
                const x0 = Math.max(c0.x, v.x) + 10, x1 = Math.min(c0.x + childHost.width, v.x + win.stage.width) - 10;
                const y0 = Math.max(c0.y, v.y) + 10, y1 = Math.min(c0.y + childHost.height, v.y + win.stage.height) - 10;
                if (x1 <= x0 || y1 <= y0) {
                    win.fail("cross: no part of the detail is in the stage's view with the hero, so this proves nothing");
                    return;
                }
                const dp = Qt.point((x0 + x1) / 2, (y0 + y1) / 2);
                const a = state(), day0 = d._day;
                win.touch(hp, -10, 0, Qt.ScrollUpdate);
                for (let i = 0; i < nv - 1; i++)
                    win.touch(dp, -10, 0, Qt.ScrollUpdate);
                const day1 = d._day;
                win.touch(dp, 0, 0, Qt.ScrollEnd);
                if (day1 !== day0)
                    win.fail("cross: the detail stepped its day " + day0 + " -> " + day1 + " inside the popup's gesture");
                check(a, { view: to("mini") });
                win.noteStage();
            }],
            // THE STICKY GESTURE (round 4): one motion from detailed to mini and
            // back, the pointer left where the tiles were -- outside the body
            // once the view has shrunk. The fingers keep moving between the
            // strokes (small sideways wheels every 100 ms) as they do on a
            // touchpad, so the gesture is never idle-ended; the zero-delta end
            // comes only after the last stroke.
            [700, "sticky: detailed", function () {
                popup.viewMode = "detailed";
            }],
            [700, "sticky: a stroke to normal, over the tiles' right edge", function () {
                const T = aim(popup.tileGrid, popup.hero);
                win.stickyPoint = win.aimAt(T, T.width - 20, T.height / 2);
                for (let i = 0; i < nv; i++)
                    win.touch(win.stickyPoint, -10, 0, Qt.ScrollUpdate);
                if (popup.viewMode !== "normal")
                    win.fail("sticky: the first stroke left the view " + popup.viewMode + ", expected normal");
                win.noteStage();
            }]
        ].concat(win.stickyKeepAlive(6)).concat([
            [100, "sticky: on to mini, from outside the body", function () {
                const b = popupBody.mapFromItem(null, win.stickyPoint.x, win.stickyPoint.y);
                if (b.x < popupBody.width && b.y < popupBody.height)
                    win.fail("sticky: the pointer is inside the body (" + b.x.toFixed(0) + "," + b.y.toFixed(0)
                             + "), so this proves nothing");
                for (let i = 0; i < nv; i++)
                    win.touch(win.stickyPoint, -10, 0, Qt.ScrollUpdate);
                if (popup.viewMode !== "mini")
                    win.fail("sticky: a stroke from outside the shrunk popup left the view " + popup.viewMode + ", expected mini");
                win.noteStage();
            }]
        ]).concat(win.stickyKeepAlive(6)).concat([
            [100, "sticky: back to normal in the same motion", function () {
                // More than the way out: TabSelector carries a stroke's remainder
                // into a reversal, so the same count back falls short of a step.
                for (let i = 0; i < nBack; i++)
                    win.touch(win.stickyPoint, 10, 0, Qt.ScrollUpdate);
                win.touch(win.stickyPoint, 0, 0, Qt.ScrollEnd);
                if (popup.viewMode !== "normal")
                    win.fail("sticky: the stroke back left the view " + popup.viewMode + ", expected normal");
                win.noteStage();
            }],
        ]).concat(win.coastSteps()).concat([
            [700, "done", function () {
                if (popup.swipeGestureActive)
                    win.fail("the gesture is still latched after the zero-delta event");
                win.report("SWIPE");
            }]
        ]);
        return steps.map(s => [s[0], s[1], function () {
            win.flushCheck();
            win.stageStill();
            s[2]();
        }]);
    }

    // ---- PROBE=swipe, the strip's coast (modules/common/scroll) -----------------
    // The popup's wheel reader hands the hourly strip's x to the strip's engine, so the
    // feel is the shell's: a FAST touchpad stream coasts after the lift (the zero-delta
    // event), a SLOW one does not, and fingers put back (a zero-delta ScrollBegin) catch
    // the coast. QtTest sends angle deltas only, so these call the reader with pixel deltas
    // as a touchpad does. Streams are spaced far enough apart (8 / 80 ms of a Timer) that
    // the velocity is well either side of ScrollFeel.flingMin on the wall clock too (offscreen
    // a Timer runs ~3x fast). ARM=nocoast (PROBE=swipe) puts flingMin out of reach.
    property real coastPark: 0
    property real flingWas: 0.3
    function coastSteps() {
        const S = popup.hourlyStrip;
        const feed = function (px, phase) {
            const p = win.aimAt(S, S.width / 2, S.height / 2);
            const q = popup.mapFromItem(null, p.x, p.y);
            popup._wheel(q.x, q.y, WheelHub.fingers(px, 0, phase));
        };
        const out = [];
        out.push([300, "coast: park the strip at its start", function () {
            S.scrollBy(1e9);
            const max = S.scrollPos;
            S.scrollBy(-1e9);
            if (!(max > 700))
                win.fail("the strip scrolls only " + max + " px, too short to show a coast");
            win.flingWas = ScrollFeel.flingMin;
            if (win.nocoastArmed)
                ScrollFeel.flingMin = 1000;
        }]);
        const stream = function (n, px, every, tag) {
            for (let i = 0; i < n; i++)
                out.push([every, "coast: " + tag + " fingers", function () { feed(px, Qt.ScrollUpdate); }]);
        };
        stream(12, -24, 8, "fast");
        out.push([8, "coast: fast lift", function () {
            win.coastPark = S.scrollPos;
            feed(0, Qt.ScrollEnd);
            if (!S.scrolling)
                win.fail("the lift after a fast stream started no motion");
        }]);
        out.push([50, "coast: fast stream coasted", function () {
            const far = S.scrollPos - win.coastPark;
            console.log("WEATHER SWIPE coast: fast stream, lift at " + win.coastPark.toFixed(0) + ", coasted " + far.toFixed(0) + " px");
            if (!(far > 150))
                win.fail("a fast stream coasted " + far.toFixed(1) + " px after the lift, expected more than 150");
            S.scrollBy(-1e9);
        }]);
        stream(8, -1, 80, "slow");
        out.push([80, "coast: slow lift", function () {
            win.coastPark = S.scrollPos;
            feed(0, Qt.ScrollEnd);
        }]);
        out.push([60, "coast: slow stream did not", function () {
            const far = S.scrollPos - win.coastPark;
            console.log("WEATHER SWIPE coast: slow stream, lift at " + win.coastPark.toFixed(1) + ", moved " + far.toFixed(2) + " px after");
            if (!(Math.abs(far) < 0.5) || S.scrolling)
                win.fail("a slow stream moved " + far.toFixed(2) + " px after the lift (moving " + S.scrolling + "), expected none");
            S.scrollBy(-1e9);
        }]);
        stream(12, -24, 8, "fast again");
        out.push([8, "coast: lift, then fingers back", function () {
            feed(0, Qt.ScrollEnd);
        }]);
        out.push([60, "coast: catch", function () {
            win.coastPark = S.scrollPos;
            feed(0, Qt.ScrollBegin);
            if (S.scrolling)
                win.fail("fingers put back left the coast running");
        }]);
        out.push([200, "coast: caught where it was", function () {
            const far = S.scrollPos - win.coastPark;
            if (!(Math.abs(far) < 0.5))
                win.fail("the coast went on " + far.toFixed(1) + " px after the fingers came back");
            ScrollFeel.flingMin = win.flingWas;
            S.scrollBy(-1e9);
        }]);
        return out;
    }

    // ---- PROBE=trace: the detail's clock --------------------------------------
    // The sequence that produced the user's TypeError (every close of an open
    // detail: by the same key, by secondaryOpen, by a view switch, mid-open,
    // mid-slide), with slides, side changes and scenario changes between.
    // In-file it counts the two things the fault is made of: the child
    // APPEARING while closed (an extent through a false zero) and a null read
    // of childFull while the box exists. The log must also hold no TypeError
    // and no warning; the runner greps it. ARM=1 restores round 1's write
    // order and its second read, and must FAIL both ways.
    property var traceStats: ({ rises: 0, nullReads: 0, closes: 0 })
    function traceSteps() {
        const tk = function (m, d, h, from) { return { metric: m, dayIndex: d, hourIndex: h, from: from }; };
        const open = function (k) { popup.openDetail(k, popup.anchorFor(k)); };
        return [
            [0, "open conditions from the hero", function () { open(popup.hero.glyphItem.key); }],
            [500, "slide to hourly column 3", function () { open(popup.hourlyStrip.keyAt(3)); }],
            [60, "slide mid-slide to daily row 2", function () { open(tk("temperature", 2, null, "daily")); }],
            [500, "close by the same key", function () { open(tk("temperature", 2, null, "daily")); }],
            [90, "reopen mid-close", function () { open(tk("pressure", 1, null, "daily")); }],
            [600, "view detailed while open", function () { popup.viewMode = "detailed"; }],
            [500, "open the wind tile", function () { open(tk("wind", 0, null, "tile")); }],
            [500, "view mini while open", function () { popup.viewMode = "mini"; }],
            [500, "view normal", function () { popup.viewMode = "normal"; }],
            [500, "open airQuality", function () { win.openFor("airQuality", 1, null, false); }],
            [500, "side right", function () { popup.detailSide = "right"; }],
            [500, "side left", function () { popup.detailSide = "left"; }],
            [500, "side top", function () { popup.detailSide = "top"; }],
            [500, "side far", function () { popup.detailSide = "far"; }],
            [500, "open sunMoon", function () { win.openFor("sunMoon", 0, null, false); }],
            [40, "open pollen fast", function () { win.openFor("pollen", 1, null, false); }],
            [40, "open humidity fast", function () { win.openFor("humidity", 0, 22, false); }],
            [500, "scenario loading", function () { mock.scenario = "loading"; }],
            [500, "scenario rain", function () { mock.scenario = "rain"; }],
            [500, "close", function () { popup.secondaryOpen = false; }],
            [30, "open during the close", function () { win.openFor("uv", 1, null, false); }],
            [30, "close again", function () { popup.secondaryOpen = false; }],
            [30, "open again", function () { win.openFor("visibility", 0, 23, false); }],
            [700, "detailed, then close", function () { popup.viewMode = "detailed"; popup.secondaryOpen = false; }],
            [100, "mini mid-close", function () { popup.viewMode = "mini"; }],
            [600, "normal and open", function () { popup.viewMode = "normal"; win.openFor("wind", 0, null, false); }],
            [40, "mini at once", function () { popup.viewMode = "mini"; }],
            [800, "done", function () {
                const st = win.traceStats;
                console.log("WEATHER TRACE closes=" + st.closes + " rises=" + st.rises + " nullReads=" + st.nullReads);
                if (st.closes < 7)
                    win.fail("only " + st.closes + " closes ran");
                if (st.rises > 0)
                    win.fail("the child appeared " + st.rises + " time(s) while closed (an extent through a false zero)");
                if (st.nullReads > 0)
                    win.fail(st.nullReads + " null read(s) of childFull beside a live box");
                win.report("TRACE");
            }]
        ];
    }

    // ---- PROBE=stage: one size ----------------------------------------------------
    // After the first settle, the harness's implicit size and the popup's
    // origin are sampled on EVERY frame (and on every change, between frames)
    // through every view, the detail of every metric opened, slid between and
    // closed in each, a view switch with the detail open, and the scenarios
    // whose popups are the shortest and the tallest. Nothing may move, and on
    // every frame the popup's box and the child's (overshoot included) must
    // lie inside the stage: a fixed size that clips a shape is no answer. The
    // side comes from DETAILSIDE (the one setting that may change the size).
    // ARM=1 restores round 1's sizing (the live popup plus the live child),
    // which must FAIL.
    property var stageBase: null
    property int stageFrames: 0
    property real stageDeepest: 0
    function stageHouses() {
        const W = harness.implicitWidth, H = harness.implicitHeight;
        const boxes = [{ id: "popup", x0: harness.originX, y0: harness.originY,
                         x1: harness.originX + harness.popW, y1: harness.originY + harness.popH }];
        if (harness.childBox)
            boxes.push({ id: "detail", x0: harness.childBox.x0, y0: harness.childBox.y0,
                         x1: harness.childBox.x1, y1: harness.childBox.y1 });
        for (const b of boxes) {
            win.stageDeepest = Math.max(win.stageDeepest, b.x1 - W + harness.margin, b.y1 - H + harness.margin,
                                        harness.margin - b.x0, harness.margin - b.y0);
            if ((b.x0 < 0 || b.y0 < 0 || b.x1 > W || b.y1 > H) && win.probeFails.length < 3)
                win.fail("the " + b.id + " box " + [b.x0, b.y0, b.x1, b.y1].map(v => v.toFixed(1)).join(",")
                         + " leaves the " + W + " x " + H + " stage");
        }
    }
    function stageSample(where) {
        const b = win.stageBase;
        if (!b)
            return;
        const now = [harness.implicitWidth, harness.implicitHeight, harness.originX, harness.originY];
        if (now[0] !== b[0] || now[1] !== b[1] || now[2] !== b[2] || now[3] !== b[3]) {
            const msg = "stage " + now.join(",") + " (was " + b.join(",") + ") " + where;
            if (win.probeFails.length < 3)
                win.fail(msg);
            win.stageBase = now;
        }
    }
    FrameAnimation {
        running: win.probeKind === "stage" && win.stageBase !== null
        onTriggered: {
            win.stageFrames++;
            win.stageSample("at a frame");
            win.stageHouses();
        }
    }
    Connections {
        target: harness
        enabled: win.probeKind === "stage"
        function onImplicitWidthChanged() { win.stageSample("between frames"); }
        function onImplicitHeightChanged() { win.stageSample("between frames"); }
        function onOriginXChanged() { win.stageSample("between frames"); }
        function onOriginYChanged() { win.stageSample("between frames"); }
    }
    function stageSteps() {
        const steps = [[0, "baseline", function () {
            win.stageBase = [harness.implicitWidth, harness.implicitHeight, harness.originX, harness.originY];
            console.log("WEATHER STAGE side=" + harness.childEdge + " size=" + win.stageBase.join(","));
        }]];
        const views = ["normal", "detailed", "mini"];
        for (const v of views) {
            steps.push([450, "view " + v, function () { popup.viewMode = v; }]);
            for (const m of win.metrics) {
                steps.push([450, v + ": open " + m, function () {
                    win.openFor(m, m === "conditions" ? 0 : 1, m === "humidity" || m === "wind" ? 14 : null, false);
                }]);
            }
            steps.push([450, v + ": close", function () { popup.secondaryOpen = false; }]);
            steps.push([450, v + ": reopen pollen", function () { win.openFor("pollen", 0, null, false); }]);
        }
        steps.push([450, "switch with the detail open", function () { popup.viewMode = "detailed"; }]);
        // thunder is the tallest popup measured (normal, its warning chip),
        // live-fixture the shortest (mini).
        for (const sc of ["thunder", "warning", "loading", "offline", "live-fixture"]) {
            for (const v of views) {
                steps.push([350, sc + " " + v, function () {
                    mock.scenario = sc;
                    popup.viewMode = v;
                    win.openFor("airQuality", 0, null, false);
                }]);
            }
        }
        steps.push([500, "done", function () {
            console.log("WEATHER STAGE frames=" + win.stageFrames + " deepest reach into the margin " + win.stageDeepest.toFixed(1)
                        + " px, marks popW " + harness.popWMin + ".." + harness.popWMax
                        + " popH " + harness.popHMin + ".." + harness.popHMax + " child " + harness.childWMax + "x" + harness.childHMax);
            if (win.stageFrames < 60)
                win.fail("only " + win.stageFrames + " frames sampled");
            win.report("STAGE");
        }]);
        return steps;
    }

    // ---- PROBE=measure: the extremes the stage reserve starts from ------------
    // The popup's height in every scenario and view, and the detail's size in
    // every scenario at every metric, day 0..15 and pollutant tab, set straight
    // on the open detail (the engine assigns a key while the content is
    // hidden; nothing here waits for a swap). One state per two frames: a
    // column's implicit height is settled by the polish of the frame after.
    property var measureStates: []
    property int measureIndex: 0
    property int measureWait: 0
    property var measureMax: ({})
    function startMeasure() {
        const st = [];
        for (const sc of mock.scenarios)
            for (const v of ["mini", "normal", "detailed"])
                st.push({ scenario: sc, view: v });
        st.push({ openDetail: true });
        const tabs = ["index", "pm25", "pm10", "o3", "no2", "so2", "co"];
        for (const sc of mock.scenarios)
            for (const m of win.metrics)
                for (let d = 0; d < 16; d++)
                    for (const p of (m === "airQuality" ? tabs : ["index"]))
                        st.push({ scenario: sc, metric: m, day: d, pollutant: p });
        win.measureStates = st;
        win.measureIndex = 0;
        win.measureWait = 0;
        measureClock.running = true;
    }
    function measureNote(name, v, what) {
        const mm = win.measureMax;
        if (!(name in mm) || (name.endsWith("Min") ? v < mm[name].v : v > mm[name].v))
            mm[name] = { v: v, what: what };
    }
    FrameAnimation {
        id: measureClock
        onTriggered: {
            const st = win.measureStates;
            if (win.measureWait > 0) {
                win.measureWait--;
                return;
            }
            // Read the state set two frames ago, then set the next.
            const i = win.measureIndex;
            if (i > 0) {
                const s = st[i - 1];
                const what = JSON.stringify(s);
                if (s.view) {
                    win.measureNote("popH_" + s.view + "_Min", popup.implicitHeight, what);
                    win.measureNote("popH_" + s.view + "_Max", popup.implicitHeight, what);
                    win.measureNote("popW_" + s.view + "_Max", popup.implicitWidth, what);
                } else if (s.metric) {
                    win.measureNote("childW_Max", harness.childFullW, what);
                    win.measureNote("childH_Max", harness.childFullH, what);
                }
            }
            if (i >= st.length) {
                measureClock.running = false;
                const mm = win.measureMax;
                for (const k of Object.keys(mm).sort())
                    console.log("WEATHER MEASURE " + k + " = " + mm[k].v + "   at " + mm[k].what);
                console.log("WEATHER MEASURE DONE states=" + st.length);
                Qt.quit();
                return;
            }
            const s = st[i];
            if (s.view) {
                mock.scenario = s.scenario;
                popup.viewMode = s.view;
            } else if (s.openDetail) {
                mock.scenario = "live-fixture";
                popup.viewMode = "normal";
                win.openFor("temperature", 0, null, false);
                win.measureWait = 30;
            } else {
                if (mock.scenario !== s.scenario)
                    mock.scenario = s.scenario;
                const d = harness.detail;
                if (d && ("secondaryKey" in d)) {
                    d.secondaryKey = { metric: s.metric, dayIndex: s.day, hourIndex: null };
                    if ("_pollutant" in d)
                        d._pollutant = s.pollutant;
                }
            }
            win.measureIndex = i + 1;
            win.measureWait = Math.max(win.measureWait, 1);
        }
    }

    // =====================================================================
    //  PAGES
    // =====================================================================
    pages: [
        MockupPage {
            id: runPage

            TipRow {
                tip: "The ten tiles' float (WeatherPopup.cardFloat): off, the tiles stand still, the wide cards are not dealt and the popup is drawn as it was before the float. Opening is the deal: a fresh deal on 'Deal again'."
                Layout.fillWidth: true
                spacing: 8
                CheckBox {
                    text: "Float"
                    checked: win.floatOn
                    onToggled: win.floatOn = checked
                }
                Button {
                    text: "Deal again"
                    onClicked: popup.floatClock.restartDeal()
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipGroup {
                title: "Scenario"
                blurb: "The captured day (Antwerp, 2026-09-16 19:02) normalised as the real service does it, then edited per scenario so every figure stays plausible."
            }
            TipRow {
                tip: "Which WeatherMock scenario the popup shows. 'loading' has no model (the skeletons); 'offline' shows the capture with the header's offline note; the rest paint a condition over the captured day, and the seven from 'rain-soon' to 'settled-evening' each put the hero's context line on one of its rules."
                Label {
                    text: "scenario"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                }
                ComboBox {
                    Layout.fillWidth: true
                    model: mock.scenarios
                    currentIndex: Math.max(0, mock.scenarios.indexOf(mock.scenario))
                    onActivated: mock.scenario = currentText
                }
                Button {
                    text: "Refresh"
                    onClicked: mock.refresh()
                }
            }
            TipRow {
                tip: "LIVE: the real WeatherService in place of the mock -- ~/.config/quickshell/config/weather.jsonc (without one: Brussels), geoclue when an agent runs, Open-Meteo and the KMI app, the caches under ~/.cache/lares/weather. Everything else on this tab (scenario, time of day) drives the mock only. The readout below says where the data came from and gives the exact Open-Meteo request to open in a browser. Env: LIVE=1."
                Label {
                    text: "data"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                }
                CheckBox {
                    text: "live"
                    checked: win.liveData
                    onToggled: win.liveData = checked
                }
                Button {
                    text: "Fetch now"
                    enabled: win.liveData && !!liveLoader.item
                    onClicked: liveLoader.item.refresh()
                }
            }
            TextEdit {
                // Selectable, so the request can be copied into a browser.
                Layout.fillWidth: true
                visible: win.liveData
                readOnly: true
                selectByMouse: true
                wrapMode: TextEdit.WrapAnywhere
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
                text: {
                    const sv = liveLoader.item;
                    if (!sv)
                        return "live: starting";
                    const m = sv.model;
                    const L = m ? m.location : null;
                    return "live: " + (sv.loading ? "fetching" : sv.offline ? "OFFLINE (showing the cache)" : sv.stale ? "stale cache" : "fresh")
                        + (m ? "   fetched " + popup.fmt.time(m.fetchedAtMs) + " " + popup.fmt.date(m.fetchedAtMs) : "   no model yet")
                        + "\nplace: " + (L ? L.name + "  " + L.lat + ", " + L.lon + (L.elevation !== null ? "  " + L.elevation + " m" : "")
                                          + "  (" + L.source + (L.reason ? ": " + L.reason : "") + ")" : "–")
                        + "\nmodel: Open-Meteo " + sv.modelName + " + CAMS air quality; KMI app for the observation, warnings, radar"
                        + "\nconfig: " + sv.configPath + (sv.configError ? "  -- " + sv.configError : "")
                        + (sv.lastError ? "\nlast error: " + sv.lastError : "")
                        + "\nrequest: " + sv.forecastUrl;
                }
            }
            TipRow {
                tip: "The service's location list; the header's name is the link that cycles it. With the mock both entries are the same fixture; with live data they are weather.jsonc's (the current location first when enabled)."
                Label {
                    text: "location"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                }
                ComboBox {
                    Layout.fillWidth: true
                    model: (win.svc.locations || []).map(l => l.name)
                    currentIndex: win.svc.locationIndex
                    onActivated: win.svc.selectLocation(currentIndex)
                }
            }
            TipRow {
                tip: "Which hour of the fixture's day is 'now' (0..24); -1 is the capture's own 19:00. Moves the strip's first column, the hero's figures, the context line and the sun's place on its arc."
                Label {
                    text: "time of day"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                }
                Slider {
                    Layout.fillWidth: true
                    from: -1
                    to: 24
                    stepSize: 0.5
                    value: mock.timeOfDay
                    onMoved: mock.timeOfDay = value
                }
                Label {
                    text: mock.timeOfDay < 0 ? "capture" : mock.timeOfDay.toFixed(1) + " h"
                    color: "#5D5D5F"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    Layout.preferredWidth: 64
                }
            }

            TipGroup {
                title: "View"
                blurb: "The three layouts, and the views of the two cards that have several. The TabSelector or a two-finger horizontal swipe across the popup switches the layout; a vertical wheel over the strip or a horizontal one over the list cycles that card's view."
            }
            TipRow {
                tip: "mini: the header (icons in the selector) and the compact hero, 360 wide. normal: the hero, the hourly strip and the daily list in one column, 720. detailed: the hero and the list on the left (480), the strip and three columns of tiles on the right, 1180. A switch closes an open detail."
                Button {
                    text: "mini"
                    onClicked: popup.viewMode = "mini"
                }
                Button {
                    text: "normal"
                    onClicked: popup.viewMode = "normal"
                }
                Button {
                    text: "detailed"
                    onClicked: popup.viewMode = "detailed"
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "The hourly strip's view, picked the way a click on one of its dots does: the view's title shows over the card and the dots fade in. HOURLYVIEW=<id|index> sets it silently at load."
                Label {
                    text: "hourly"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    Layout.preferredWidth: 64
                }
                ComboBox {
                    Layout.fillWidth: true
                    model: popup.hourlyStrip ? popup.hourlyStrip.views.map(v => v.label) : []
                    currentIndex: popup.hourlyStrip ? popup.hourlyStrip.viewIndex : 0
                    onActivated: index => popup.hourlyStrip.cycler.select(index)
                }
            }
            TipRow {
                tip: "The daily list's view, picked the way a click on one of its dots does. DAILYVIEW=<id|index> sets it silently at load."
                Label {
                    text: "daily"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    Layout.preferredWidth: 64
                }
                ComboBox {
                    Layout.fillWidth: true
                    model: popup.dailyList ? popup.dailyList.views.map(v => v.label) : []
                    currentIndex: popup.dailyList ? popup.dailyList.viewIndex : 0
                    onActivated: index => popup.dailyList.cycler.select(index)
                }
            }

            TipGroup {
                title: "Detail"
                blurb: "The secondary popup, opened through the popup's own openDetail() exactly as a click does, from the link that click would be on: the same key closes it, another slides it."
            }
            TipRow {
                tip: "The metric the detail shows, the day (0 = today) and the hour on that day (-1 = none, the day's figures). Open picks the link a click would use: an hour is a strip column (the strip turns to that metric's view when it has one), today's metric a tile in the detailed view, today's conditions the hero's glyph, anything else a row of the daily list (turned to that metric's view when it has one)."
                ComboBox {
                    id: detailMetric
                    Layout.fillWidth: true
                    model: win.metrics
                    currentIndex: 3
                }
                Label {
                    text: "day"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                }
                SpinBox {
                    id: detailDay
                    Layout.preferredWidth: 84
                    from: 0
                    to: 15
                    value: 0
                }
                Label {
                    text: "hour"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                }
                SpinBox {
                    id: detailHour
                    Layout.preferredWidth: 84
                    from: -1
                    to: 23
                    value: -1
                }
            }
            TipRow {
                tip: "Opens the detail of the metric, day and hour above, from the side chosen on the Layout tab (Detail group). Close closes it."
                Button {
                    text: "Open"
                    onClicked: win.openFor(detailMetric.currentText, detailDay.value, detailHour.value < 0 ? null : detailHour.value, true)
                }
                Button {
                    text: "Close"
                    onClicked: popup.secondaryOpen = false
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "Backdrop"
                blurb: "The hero card's moving background. Off is the honest comparison for cost: at rest with it off the popup must present no frame."
            }
            TipRow {
                tip: "Runs the backdrop under the hero (the Backdrop tab's switch, here for convenience), and which of its two precipitation renderers draws: the stateless shader (default) or the shell's CPU particle system (the measured fallback)."
                CheckBox {
                    text: "backdrop"
                    checked: popup.backdropEnabled
                    onToggled: popup.backdropEnabled = checked
                }
                ComboBox {
                    model: ["shader", "canvas"]
                    currentIndex: Math.max(0, model.indexOf(popup.backdropRenderer))
                    onActivated: popup.backdropRenderer = currentText
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "State"
                blurb: "What the model, the service and the popup say right now."
            }
            Label {
                Layout.fillWidth: true
                readonly property var m: mock.model
                readonly property var c: m && m.current ? m.current : null
                readonly property var d: m && m.daily && m.daily.length > 0 ? m.daily[0] : null
                text: !m ? "model: none" + (mock.loading ? " (loading)" : "")
                    : (m.location.name + "   " + popup.fmt.temp(c ? c.temp : null) + "  "
                       + (c ? c.kind + "/" + c.intensity + (c.night ? " night" : "") : "–")
                       + "   H " + popup.fmt.temp(d ? d.temp.max : null) + "  L " + popup.fmt.temp(d ? d.temp.min : null)
                       + "\nfeels " + popup.fmt.temp(c ? c.feelsLike : null)
                       + "   wind " + popup.fmt.wind(c ? c.wind : null) + (c && c.wind.dirText ? " " + c.wind.dirText : "")
                       + "   aq " + (c && c.aq ? c.aq.index : "–")
                       + "   uv " + (c && c.uv !== null ? c.uv : "–")
                       + "   hours " + m.hourly.length + "  days " + m.daily.length
                       + "   warnings " + m.warnings.length + "  nowcast " + m.nowcast.length
                       + "\ncontext " + popup.hero.contextLine.id + ": " + popup.hero.contextLine.text
                       + "\nfetched " + popup.fmt.time(m.fetchedAtMs) + "  stale " + m.stale)
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 13
                wrapMode: Text.Wrap
            }
            Label {
                Layout.fillWidth: true
                text: "service: " + (mock.loading ? "loading" : mock.offline ? "offline" : "ready")
                    + (mock.lastError ? " (" + mock.lastError + ")" : "")
                    + "   scenario " + mock.scenario
                    + "   now " + popup.fmt.time(mock.nowMs)
                    + "\npopup: " + popup.viewMode + "  " + popup.implicitWidth.toFixed(0) + " x " + popup.implicitHeight.toFixed(0)
                    + "   strip " + (popup.hourlyStrip ? popup.hourlyStrip.viewId : "-") + "  list " + (popup.dailyList ? popup.dailyList.viewId : "-")
                    + "   gesture " + (popup.swipeGestureActive ? "active" : "idle")
                    + "\ndetail: " + (popup.secondaryOpen ? "open" : "closed")
                    + "  key " + JSON.stringify(popup.secondaryKey)
                    + "  anchor " + popup.secondaryAnchor.x.toFixed(0) + "," + popup.secondaryAnchor.y.toFixed(0)
                    + "  edge " + harness.childEdge + "  e " + harness.e.toFixed(2)
                    + "  child " + harness.childFullW.toFixed(0) + " x " + harness.childFullH.toFixed(0)
                    + "\nstage: " + harness.implicitWidth.toFixed(0) + " x " + harness.implicitHeight.toFixed(0)
                    + "  popup at " + harness.originX + "," + harness.originY
                    + "  reserve popup " + harness.popWMin + ".." + harness.popWMax + " x " + harness.popHMin + ".." + harness.popHMax
                    + ", child " + harness.childWMax + " x " + harness.childHMax
                    + "\nfield bodies " + field.bodyCount + "  fillets " + field.filletCount
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 13
                wrapMode: Text.Wrap
            }
        },

        MockupPage {
            id: glyphPage

            TipGroup {
                title: "In the bar"
                blurb: "The real bar button for each condition, at twice its size (ink set). Hover one to play its flourish, as on the bar: once per pointer entry, once the pointer moves."
            }
            TipRow {
                tip: "WeatherBarButton with a stand-in service per condition: the icon at the bar's 18 px (drawn 2x here), the hover hue on the icon and the figure, and the flourish on hover (WeatherInkPose.js; the Flourish group's beat sets its pace). With the carved set chosen the buttons draw the legacy glyph, which has no flourish."
                Flow {
                    Layout.fillWidth: true
                    spacing: 8
                    Repeater {
                        id: barCells
                        model: win.barConditions
                        Rectangle {
                            id: barCell
                            required property var modelData
                            readonly property alias button: barButton
                            width: 2 * barButton.implicitWidth + 12
                            height: 2 * barButton.implicitHeight + 8
                            radius: 10
                            color: Theme.surface
                            border.width: 1
                            border.color: Theme.border
                            QtObject {
                                id: barSvc
                                property var model: ({
                                        current: { kind: barCell.modelData[0], intensity: barCell.modelData[1], night: barCell.modelData[2], shower: barCell.modelData[3], temp: 12 },
                                        warnings: []
                                    })
                                property var config: ({ units: ({}) })
                            }
                            WeatherBarButton {
                                id: barButton
                                x: 6
                                y: 4
                                scale: 2
                                transformOrigin: Item.TopLeft
                                service: barSvc
                                flourishMs: flourishKnob.flourishMs
                            }
                        }
                    }
                }
            }
            TipRow {
                tip: "Plays every button's flourish at once (what a hover plays on one), to compare their lengths and curves."
                Button {
                    text: "Play all"
                    onClicked: {
                        for (let i = 0; i < barCells.count; ++i)
                            barCells.itemAt(i).button.flourish.play("mockup");
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "Gallery"
                blurb: "Every kind, day and night, at the three sizes the popup draws (24 in the strip and the list, 48, 88 in the hero), and the wind-direction arrow. The carve knobs above apply to all of them and to every glyph on the stage."
            }
            Repeater {
                model: ["clear", "partly", "cloudy", "fog", "rain", "sleet", "snow", "hail", "thunder", "wind"]
                TipRow {
                    id: galleryRow
                    required property string modelData
                    required property int index
                    tip: "The '" + galleryRow.modelData + "' composition: day then night at 24, 48 and 88 px. Intensity 1; showers off."
                    Label {
                        text: galleryRow.modelData
                        color: "#5D5D5F"
                        font.family: "Audiowide"
                        font.pixelSize: 13
                        Layout.preferredWidth: 60
                    }
                    Repeater {
                        model: [24, 24, 48, 48, 88, 88]
                        Item {
                            id: galleryCell
                            required property int modelData
                            required property int index
                            Layout.preferredWidth: galleryCell.modelData
                            Layout.preferredHeight: 88
                            WeatherGlyph {
                                anchors.centerIn: parent
                                size: galleryCell.modelData
                                kind: galleryRow.modelData
                                night: galleryCell.index % 2 === 1
                                intensity: 1
                                moonPhase: 0.35
                                renderScale: 1
                                style: popup.glyphStyle
                            }
                        }
                    }
                    Item {
                        Layout.fillWidth: true
                    }
                }
            }
            TipRow {
                tip: "The 'arrow' part, the carved dart of the strip's and the list's wind views, the wind tile's rose and the pressure tile's trend. `direction` is the meteorological FROM bearing and the dart points where the air goes: from the north (0), the east (90), the south-west (225) and the west-north-west (290) at 24, 48 and 88 px, then no direction (null), which draws a small carved dot."
                Label {
                    text: "arrow"
                    color: "#5D5D5F"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                    Layout.preferredWidth: 60
                }
                Repeater {
                    // [size, from-bearing]; -1 is no direction.
                    model: [[24, 0], [24, 90], [48, 225], [48, -1], [88, 290], [88, -1]]
                    Item {
                        id: arrowCell
                        required property var modelData
                        Layout.preferredWidth: arrowCell.modelData[0]
                        Layout.preferredHeight: 88
                        WeatherGlyph {
                            anchors.centerIn: parent
                            size: arrowCell.modelData[0]
                            kind: "arrow"
                            direction: arrowCell.modelData[1] < 0 ? null : arrowCell.modelData[1]
                            renderScale: 1
                            style: popup.glyphStyle
                        }
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }
        },

        MockupPage {
            id: backdropPage

            TipGroup {
                title: "Style"
                blurb: "Round 4 redid every scene (v2). Round 1's scenes (v1) stay selectable for comparison until the bar is deployed; then v1 and its shader are deleted."
            }
            TipRow {
                tip: "Which generation of scenes the backdrop draws: v2 (round 4, the default) or v1 (round 1, kept only to compare against)."
                Label {
                    text: "style"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                }
                ComboBox {
                    model: ["v2", "v1"]
                    currentIndex: Math.max(0, model.indexOf(popup.backdropStyle))
                    onActivated: popup.backdropStyle = currentText
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "Renderer"
                blurb: "The precipitation's two arms: the stateless shader (default) and the shell's CPU particle system, kept as the measured fallback for a machine without a usable GPU."
            }
            TipRow {
                tip: "Which arm draws the streaks and flakes. Everything else in the backdrop (sky, cloud, fog, the storm's flash) is the shader either way."
                Label {
                    text: "renderer"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                }
                ComboBox {
                    model: ["shader", "canvas"]
                    currentIndex: Math.max(0, model.indexOf(popup.backdropRenderer))
                    onActivated: popup.backdropRenderer = currentText
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipGroup {
                title: "State"
            }
            Label {
                Layout.fillWidth: true
                readonly property var bd: popup.hero.backdrop
                text: "kind " + bd.kind + "/" + bd.intensity + (bd.night ? " night" : "")
                    + "   wind " + bd.windKmh.toFixed(0) + " km/h from " + bd.windDir.toFixed(0) + "°"
                    + "\nrunning " + bd.running + "   ticking " + bd.ticking + "   ticks " + bd.tickCount
                    + "   time " + bd.time.toFixed(1) + " s   flash " + bd.flash.toFixed(2)
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 13
                wrapMode: Text.Wrap
            }
        }
    ]

    // =====================================================================
    //  VALUES
    // =====================================================================
    readonly property var layoutParams: [
        {
            label: "padding",
            prop: "padding",
            group: "Padding",
            blurb: "The popup's own spacing: 12 on every side and between cards, as everywhere in the shell.",
            tip: "Space between the popup's edge and the cards, and between the cards. 12 is the shell's number; space above equals space below.",
            val: 12,
            from: 0,
            to: 32,
            step: 1
        },
        {
            label: "card padding",
            prop: "cardPadding",
            group: "Padding",
            tip: "Space inside every carved card between its edge and its content. 12, the shell's card padding.",
            val: 12,
            from: 0,
            to: 32,
            step: 1
        },
        {
            label: "radius",
            prop: "radius",
            group: "Radii",
            blurb: "The container radius rule: 14 normal, 10 compact.",
            tip: "Corner radius of every card in the normal and detailed views. 14 is the shell's container radius.",
            val: 14,
            from: 4,
            to: 24,
            step: 1
        },
        {
            label: "mini width",
            prop: "miniWidth",
            group: "Widths",
            blurb: "What each view asks its host for. Heights follow the cards.",
            tip: "Mini view width: the header and the hero. The hero is one card in every view (round 5), so mini is the detailed view's left column and its padding, 480 + 2 x 12, and the card is exactly the detailed one. Round 3: 360, round 4: 440 (a mini-only layout).",
            val: 504,
            from: 300,
            to: 720,
            step: 1
        },
        {
            label: "normal width",
            prop: "normalWidth",
            group: "Widths",
            tip: "Normal view width: the header, the hero, the strip and the list in one column, no tiles. 720 gives the strip 15 columns before it scrolls.",
            val: 720,
            from: 560,
            to: 900,
            step: 1
        },
        {
            label: "detailed width",
            prop: "detailedWidth",
            group: "Widths",
            tip: "Detailed view width: the hero and the list on the left, the strip and three columns of tiles on the right. 1180.",
            val: 1180,
            from: 1000,
            to: 1400,
            step: 1
        },
        {
            label: "detailed left width",
            prop: "detailedLeftWidth",
            group: "Widths",
            tip: "Width the hero and the daily list share in the detailed view, so their right edges line up; the strip and the tiles take the rest of the row. 480 keeps the list's range groove readable beside its figures.",
            val: 480,
            from: 400,
            to: 600,
            step: 1
        },
        {
            label: "header height",
            prop: "headerHeight",
            group: "Header",
            blurb: "The header row: the location name (the link that cycles the locations) beside the view selector.",
            tip: "The header row's height: the location name beside the view selector. 32 is the selector's own height.",
            val: 32,
            from: 24,
            to: 48,
            step: 1
        },
        {
            label: "selector width",
            prop: "tabWidth",
            group: "Header",
            tip: "Width of the icon-only view selector, in every view (its tips carry the names). Its natural width is 126 (a 14 px icon advance plus 14 px either side, times three); 132 gives each pill 38 px.",
            val: 132,
            from: 96,
            to: 220,
            step: 1
        },
        {
            label: "icon size",
            prop: "tabIconSize",
            group: "Header",
            tip: "Pixel size of the Nerd Font view icons in the selector. At 16 the three icons read at a glance and stay centred in the 32 px track.",
            val: 16,
            from: 10,
            to: 24,
            step: 1
        },
        {
            label: "probability min %",
            prop: "probLabelMin",
            group: "Figures",
            blurb: "When a value is worth a figure at all: one threshold for every card that draws the same fact.",
            tip: "Precipitation probability below which neither card shows it: the hourly strip draws no faint bar and no % figure in that column, the daily list no faint fill on the range groove and no % figure on that row. Under 10 % the strip made a row of dots and the list a lone bead at the groove's end. 10.",
            val: 10,
            from: 0,
            to: 50,
            step: 5
        },
        {
            label: "fade ms",
            prop: "fadeMs",
            group: "Motion",
            blurb: "Presence fades; text swaps instantly; the host eases the size.",
            tip: "How long presence takes to fade: a card leaving a view, a skeleton resolving into the real card, the open detail's content. 160, the shell's presence fade.",
            val: 160,
            from: 0,
            to: 600,
            step: 10
        },
        {
            label: "skeleton pulse",
            prop: "skeletonPulse",
            group: "Motion",
            tip: "Whether the skeletons breathe while the model is awaited. On in life; a render turns it off so two grabs of the same state are the same picture (PULSE=0).",
            val: true
        },
        {
            label: "view morph ms",
            prop: "viewMorphMs",
            group: "Motion",
            tip: "THE VIEW MORPH between normal and detailed: the whole move, every card's ease scaled with it. 210: at most 30 % of the box bare at 40 ms and 4 % by 160 going to detailed (round 5's two phases over 400 ms left 55 % bare at 160 and 21 % at 400); the cards meet only stacked, hero over strip over list, and only in the first 120 ms.",
            val: 210,
            from: 60,
            to: 800,
            step: 10
        },
        {
            label: "card bevel",
            prop: "cardBevelWidth",
            group: "Carve",
            blurb: "Three depths of carve for every carved box of the popup and its detail: the cards, the boxes inside a card, the thin grooves. Round 1's depths: round 2 deepened them while normal view was the whole module stacked, and the user asked for these back once normal became the status card, the hours and the days.",
            tip: "Width of the light bevel outside every card's edge (hero, strip, list, tiles, the detail's cards and chart). Width alone adds little, because Theme.bevel is 3 levels off the surface; card bevel lift is what makes a rim visible. 1, round 1's. Layer slack must stay at least ceil(this) + 2.",
            val: 1,
            from: 0,
            to: 4,
            step: 0.5
        },
        {
            label: "card bevel lift",
            prop: "cardBevelLift",
            group: "Carve",
            tip: "How far the cards' bevel rim lifts from the theme's bevel toward the buttons' highlight (Theme.bevel to Theme.buttonBevel, mixed, so it follows the theme). At 0 the rim is Theme.bevel; round 2 tried 0.5 (a visible lip) with a 2 px bevel; at 1 it is a white line in light mode and a grey outline in dark. 0, round 1's.",
            val: 0,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "card shadow",
            prop: "cardShadowWidth",
            group: "Carve",
            tip: "Inset shadow inside every card's edge (hero, strip, list, tiles, the detail's cards and chart). 3, round 1's. Round 2 tried 9 with falloff 0.5: widths alone barely deepen it, since the inset is capped at Theme.border and ShadowBox's ease-out keeps its depth in the first 2 px.",
            val: 3,
            from: 2,
            to: 12,
            step: 0.5
        },
        {
            label: "card shadow falloff",
            prop: "cardShadowFalloff",
            group: "Carve",
            tip: "How the cards' inset shadow decays inward (ShadowBox's falloff, an exponent on the remaining strength). At 1, ShadowBox's own curve, the ramp stays in the first pixels; below 1 it lingers and reads as a deeper cut (round 2's 0.5); above 1 it hugs the edge. 1, round 1's.",
            val: 1,
            from: 0.25,
            to: 3,
            step: 0.05
        },
        {
            label: "inset bevel",
            prop: "insetBevelWidth",
            group: "Carve",
            tip: "Bevel of the boxes carved inside a card: the warning chip, the view-title box over the strip and the list, the open row, column and hero glyph (the selection sinks), the detail's selected day chip and pollutant selector. Its colour is the cards' (card bevel lift). 1, round 1's.",
            val: 1,
            from: 0,
            to: 3,
            step: 0.5
        },
        {
            label: "inset shadow",
            prop: "insetShadowWidth",
            group: "Carve",
            tip: "Inset shadow of the boxes carved inside a card, the open row / column / glyph included. 3, round 1's.",
            val: 3,
            from: 1,
            to: 8,
            step: 0.5
        },
        {
            label: "inset shadow falloff",
            prop: "insetShadowFalloff",
            group: "Carve",
            tip: "How the inset shadow of the boxes carved inside a card decays inward, as card shadow falloff does for the cards. Read by the hero's warning chip and open glyph, the open hourly column and daily row, the view-title boxes, and the detail's selected day chip and pollutant track. Below 1 the ramp lingers and a box reads as cut rather than outlined (round 2 used 0.6). 1, round 1's.",
            val: 1,
            from: 0.25,
            to: 3,
            step: 0.05
        },
        {
            label: "groove bevel",
            prop: "grooveBevelWidth",
            group: "Carve",
            tip: "Bevel of the thin tracks and grooves 10 px tall or less: the daily list's range hull, the UV tile's track.",
            val: 1,
            from: 0,
            to: 2,
            step: 0.5
        },
        {
            label: "groove shadow",
            prop: "grooveShadowWidth",
            group: "Carve",
            tip: "Inset shadow of the thin tracks and grooves (the daily list's range hull, the UV tile's track). A 6 px groove has room for only about 2 px of ramp before its floor. 1.5, round 1's.",
            val: 1.5,
            from: 0.5,
            to: 4,
            step: 0.5
        },
        {
            label: "layer slack",
            prop: "layerSlack",
            group: "Carve",
            tip: "Whole pixels a static layer keeps around its card for the bevel a carved box draws outside its own rect. Must be at least ceil(card bevel) + 2; at 0 the rims shear (1688 px differ from the live scene in normal, 5013 in detailed). 4.",
            val: 4,
            from: 0,
            to: 8,
            step: 1
        }
    ]

    readonly property var swipeParams: [
        {
            label: "swipe to switch",
            prop: "swipeToSwitchView",
            group: "Swipe",
            blurb: "The popup's one wheel reader. Over the hourly strip a sideways swipe scrolls the hours and a vertical one cycles the strip's view; over the daily list a sideways swipe cycles the list's view; anywhere else a sideways swipe switches the popup's view.",
            tip: "Whether a horizontal two-finger swipe across the popup switches the view. Off, only the selector's pills do.",
            val: true
        },
        {
            label: "strip scroll reversed",
            prop: "stripScrollReversed",
            group: "Swipe",
            tip: "Which way a sideways swipe takes the hourly strip. Off (the shell's one scroll feel): the content follows the fingers. On: dx > 0 goes to later hours. Off is the scroll feel of every other list in the shell (ScrollFeel). On turns the strip's sideways sense around; the user's \"inverted\" note was about the vertical view swipe, which now follows the hand.",
            val: false
        },
        {
            label: "threshold",
            prop: "swipeThreshold",
            group: "Swipe",
            tip: "Accumulated wheel units to commit one view step. 1500 is the shell's tab selector standard (the system update's tuned value): a flick of a few millimetres must not skip two views.",
            val: 1500,
            from: 200,
            to: 3000,
            step: 50
        },
        {
            label: "pull taper",
            prop: "swipePullTaper",
            group: "Swipe",
            tip: "How sharply the pill's pull tapers: above 1 front-loads the travel so what is left of the gesture reads as effort. 2.5, the shell's tab selector standard (the system update's).",
            val: 2.5,
            from: 1,
            to: 6,
            step: 0.1
        },
        {
            label: "max pull",
            prop: "swipeMaxPull",
            group: "Swipe",
            tip: "How far the pill may be dragged out of its slot while the gesture is under way, as a fraction of a slot. 0.42 stays under half, so the pull never completes a step by itself.",
            val: 0.42,
            from: 0.1,
            to: 0.5,
            step: 0.01
        },
        {
            label: "momentum rate",
            prop: "swipeMomentumRate",
            group: "Swipe",
            tip: "Units per second above which a swipe keeps its remainder and skips the cooldown, so a flick carries through the middle view. 2400, the tab selector standard.",
            val: 2400,
            from: 800,
            to: 6000,
            step: 100
        },
        {
            label: "cooldown ms",
            prop: "swipeCooldownMs",
            group: "Swipe",
            tip: "Gap between committed steps of a slow swipe, so one long swipe steps one view at a time. 320.",
            val: 320,
            from: 0,
            to: 1000,
            step: 10
        },
        {
            label: "gesture idle end ms",
            prop: "gestureIdleEndMs",
            group: "Swipe",
            tip: "Fallback end of a gesture for devices that never send the zero-delta scroll-end: this much silence releases the pill and the card that owned the gesture. 260.",
            val: 260,
            from: 100,
            to: 2000,
            step: 10
        },
        {
            label: "pixel to angle",
            prop: "swipePixelToAngle",
            group: "Swipe",
            tip: "A touchpad that sends only pixel deltas is scaled by this into wheel-angle units before any threshold, and the cards' view cycles then count those units against their own pixel threshold. 2.5 makes a finger's travel weigh like a notch's.",
            val: 2.5,
            from: 0.5,
            to: 6,
            step: 0.1
        },
        {
            label: "scroll speed",
            prop: "scrollSpeed",
            group: "Wheel",
            blurb: "How far a notch goes in the scrolling boxes.",
            tip: "Multiplier on the wheel's angle for the daily list and the hourly strip: 1.0 is one notch = 120 px, the shell's one speed.",
            val: 1,
            from: 0.25,
            to: 3,
            step: 0.05
        }
    ]

    readonly property var heroParams: [
        {
            label: "temperature size",
            prop: "tempSize",
            group: "Type",
            blurb: "The figure, the condition, the observation. One layout in every view: the card's height is the fonts', so mini, normal and detailed show the same card at different widths.",
            tip: "The temperature figure's pixel size. 44: the one figure that must read from across the room.",
            val: 44,
            from: 24,
            to: 64,
            step: 1
        },
        {
            label: "condition size",
            prop: "conditionSize",
            group: "Type",
            tip: "The condition text's size. 16 bold, the shell's title size.",
            val: 16,
            from: 10,
            to: 24,
            step: 1
        },
        {
            label: "body size",
            prop: "bodySize",
            group: "Type",
            tip: "The observation line, the context line, and the labels of the high / low / feels-like block. 12, the shell's body size.",
            val: 12,
            from: 9,
            to: 16,
            step: 1
        },
        {
            label: "stat figure size",
            prop: "statFigureSize",
            group: "Type",
            tip: "The high, low and feels-like figures, three baselines spread over the card's whole content height (the first figure's top level with the temperature's, the last on the context line's baseline). Bold. 16, the condition's size.",
            val: 16,
            from: 11,
            to: 24,
            step: 1
        },
        {
            label: "line gap",
            prop: "lineGap",
            group: "Layout",
            blurb: "Spacing inside the card. The four lines left of the stats sit on a baseline grid, so their gaps read even whatever their sizes.",
            tip: "From each line's baseline to the next line's capitals (temperature, condition, observation, context line). Sets the card's height, and so the glyph's size. 9.",
            val: 9,
            from: 2,
            to: 20,
            step: 1
        },
        {
            label: "text gap",
            prop: "textGap",
            group: "Layout",
            tip: "Gap between the glyph and the text column. 12, the card padding.",
            val: 12,
            from: 0,
            to: 32,
            step: 1
        },
        {
            label: "stats gap",
            prop: "statsGap",
            group: "Layout",
            tip: "Least gap between the text column and the high / low / feels-like block; the text column takes whatever the card leaves between them. 14.",
            val: 14,
            from: 0,
            to: 40,
            step: 1
        },
        {
            label: "stat label gap",
            prop: "statLabelGap",
            group: "Layout",
            tip: "Space between the labels (High / Low / Feels like) and the figures' slot. 14.",
            val: 14,
            from: 4,
            to: 40,
            step: 1
        },
        {
            label: "context gap",
            prop: "contextGap",
            group: "Context line",
            blurb: "The last line of the text column always says something the card does not already show: WeatherContext.js takes the first rule that holds (rain now or soon, rain later today, gusts, frost or heat, fog clearing, UV still ahead, tomorrow's change, a dry spell, the sunset).",
            tip: "Minimum space between the context text and the radar bars when both show. The text elides before it runs into the bars. 10.",
            val: 10,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "nowcast bar width",
            prop: "nowcastBarWidth",
            group: "Nowcast",
            blurb: "KMI's radar sequence, up to twelve 10-minute bars standing on the context line's baseline at the text column's end, shown only when its rule is about rain now or within two hours. Their height is the gap under the observation line's descenders, so they never touch it.",
            tip: "Each 10-minute bar's width. 5: twelve bars and their gaps take 82 px, which leaves the context text room in the 218 px column of mini and detailed.",
            val: 5,
            from: 2,
            to: 16,
            step: 1
        },
        {
            label: "nowcast bar gap",
            prop: "nowcastBarGap",
            group: "Nowcast",
            tip: "Gap between the bars. 2 keeps twelve steps readable as separate bars.",
            val: 2,
            from: 0,
            to: 8,
            step: 1
        },
        {
            label: "nowcast full mm",
            prop: "nowcastMaxMm",
            group: "Nowcast",
            tip: "Millimetres per 10 minutes at which a bar is full height. Bars follow the SQUARE ROOT of the amount, so 0.1 mm fills a fifth, 0.5 mm half and 2 mm all; on a linear scale 0.1-0.7 mm drew as 1-6 px dashes that looked like the dry steps.",
            val: 2,
            from: 0.5,
            to: 5,
            step: 0.1
        }
    ]

    readonly property var hourlyParams: [
        {
            label: "column width",
            prop: "columnWidth",
            group: "Columns",
            blurb: "One column per hour, 48 of them, on a horizontal wheel -- nine views of the same columns, cycled by a vertical wheel over the card (the Views tab).",
            tip: "Each hour's column width. 44 holds a 24 px glyph, a '-10°' figure and a three-digit percentage with air on both sides.",
            val: 44,
            from: 32,
            to: 64,
            step: 1
        },
        {
            label: "hours",
            prop: "hours",
            group: "Columns",
            tip: "How many hours the strip shows. 48: today and tomorrow; the model keeps up to 16 days of hours.",
            val: 48,
            from: 12,
            to: 96,
            step: 1
        },
        {
            label: "glyph size",
            prop: "glyphSize",
            group: "Columns",
            tip: "The hour's condition glyph, or the wind view's carved arrow. 24, the same as the daily list's.",
            val: 24,
            from: 16,
            to: 40,
            step: 1
        },
        {
            label: "row gap",
            prop: "rowGap",
            group: "Columns",
            tip: "Gap between the column's rows: the hour label, the glyph, the chart band, the value under it. 4.",
            val: 4,
            from: 0,
            to: 12,
            step: 1
        },
        {
            label: "label size",
            prop: "labelSize",
            group: "Type",
            blurb: "Three sizes: the hour label, the temperature figure, the small figures.",
            tip: "The hour label ('19', or the weekday at midnight). 11.",
            val: 11,
            from: 8,
            to: 14,
            step: 1
        },
        {
            label: "figure size",
            prop: "figureSize",
            group: "Type",
            tip: "The figure over a line view's point: the temperature, the dew point, the pressure, the visibility. 12.",
            val: 12,
            from: 9,
            to: 16,
            step: 1
        },
        {
            label: "small size",
            prop: "smallSize",
            group: "Type",
            tip: "The value under the band (probability, Beaufort, millimetres, UV, percentages, AQI) and the faint feels-like figures. 10, the compact figure size.",
            val: 10,
            from: 8,
            to: 14,
            step: 1
        },
        {
            label: "line height",
            prop: "curveHeight",
            group: "Band",
            blurb: "The chart band every view draws in: a figure over the highest point, the line's range over `line height`, a faint figure under the lowest. The same height in every view.",
            tip: "The vertical span every line's own range is drawn over. The band adds a figure above and a faint figure below, so the card is 125 + this tall in Audiowide (173 at 48, round 1's card was 208).",
            val: 48,
            from: 24,
            to: 96,
            step: 1
        },
        {
            label: "figure gap",
            prop: "figureGap",
            group: "Band",
            tip: "Gap between a point and its figure. The figure above sits this far over the higher of the column's two points, the one below this far under the lower, so the two can never collide. The temperature takes the top and the feels-like figure the bottom, except in a column where feels-like is above the temperature: there they swap, so each figure stays next to its own line. 3.",
            val: 3,
            from: 0,
            to: 10,
            step: 0.5
        },
        {
            label: "line width",
            prop: "lineWidth",
            group: "Lines",
            blurb: "The line views' ribbon: thicker in the middle of the viewport, narrowing over the last hours before an edge that has more hours beyond it. The edge fade is unchanged.",
            tip: "The line's width in the middle of the viewport. Round 1 drew 2; the user asked for a bit thicker. 3.",
            val: 3,
            from: 1,
            to: 6,
            step: 0.25
        },
        {
            label: "line min width",
            prop: "lineMinWidth",
            group: "Lines",
            tip: "The width the line narrows to at a viewport edge with content beyond it. Never 0: the user asked for a narrower line, not a vanishing one. 1.5.",
            val: 1.5,
            from: 0.5,
            to: 6,
            step: 0.25
        },
        {
            label: "taper hours",
            prop: "taperHours",
            group: "Lines",
            tip: "How many columns from each edge the taper spans (smoothstep), weighted by the edge fade's own weight, so at the very start nothing tapers on the left. 3, the user's number.",
            val: 3,
            from: 0,
            to: 6,
            step: 0.5
        },
        {
            label: "curve steps",
            prop: "curveSteps",
            group: "Lines",
            tip: "Dense points per column on the line's centreline, cached per model; a scroll only recomputes the widths. 6 makes the cubic read smooth at 44 px columns; more costs more per scroll.",
            val: 6,
            from: 2,
            to: 12,
            step: 1
        },
        {
            label: "feels-like width",
            prop: "feelsLineWidth",
            group: "Lines",
            tip: "Width of the faint feels-like line in the conditions view. It tapers in proportion to the main line. 1.5.",
            val: 1.5,
            from: 0.5,
            to: 4,
            step: 0.25
        },
        {
            label: "feels-like alpha",
            prop: "feelsAlpha",
            group: "Lines",
            tip: "Opacity of the feels-like line. At 0.55 it reads as secondary next to the temperature line and stays visible on both themes.",
            val: 0.55,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "line shadow alpha",
            prop: "shadowAlpha",
            group: "Lines",
            tip: "Starting alpha of the long gradient shadow under the temperature line (Theme.shadowDeep), fading to 0 at the track's foot. Kept subtle, as asked. 0.14.",
            val: 0.14,
            from: 0,
            to: 0.5,
            step: 0.01
        },
        {
            label: "track width",
            prop: "trackWidth",
            group: "Track",
            blurb: "Each hour's faint vertical track -- what makes the columns read as one seamless strip -- and the bars that grow over it.",
            tip: "Width of each hour's faint vertical track. Bars grow over it from its foot. 2.",
            val: 2,
            from: 1,
            to: 6,
            step: 0.5
        },
        {
            label: "track strength",
            prop: "trackStrength",
            group: "Track",
            tip: "How far the track's colour leans from the card fill toward Theme.border. At 1 it is heavy on the dark theme; at 0.5 it almost disappears on light. 0.7, from a render of 0.5 / 0.7 / 1.0.",
            val: 0.7,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "track pad",
            prop: "trackPad",
            group: "Track",
            tip: "Space between the band's edges and the track's ends. With the row gap that leaves 10 px clear of the glyph and the value (the user's 'generous padding'); a bar's full scale is the track's length (71 px). 6.",
            val: 6,
            from: 0,
            to: 20,
            step: 1
        },
        {
            label: "track gap",
            prop: "trackGap",
            group: "Track",
            tip: "The track and its bar break around a figure's ink by this much above and below, so no line crosses a number. A cut closes in the first half of its figure's fade. 2.",
            val: 2,
            from: 0,
            to: 6,
            step: 0.5
        },
        {
            label: "segment min px",
            prop: "segmentMinPx",
            group: "Track",
            tip: "A piece of track or bar shorter than this, left between two breaks, is dropped, so no dots float between two figures. 3.",
            val: 3,
            from: 0,
            to: 10,
            step: 0.5
        },
        {
            label: "bar width",
            prop: "barWidth",
            group: "Bars",
            blurb: "Opaque bars carry a view's value, faint ones a percentage beside a line.",
            tip: "Width of the opaque bars (wind, precipitation, UV, cloud cover, air quality), rounded only at their true ends. 8.",
            val: 8,
            from: 2,
            to: 16,
            step: 0.5
        },
        {
            label: "faint bar width",
            prop: "faintBarWidth",
            group: "Bars",
            tip: "Width of the faint bars (precipitation probability, humidity): thicker than the track, as asked, thinner than an opaque bar. 5.",
            val: 5,
            from: 2,
            to: 12,
            step: 0.5
        },
        {
            label: "faint bar alpha",
            prop: "faintBarAlpha",
            group: "Bars",
            tip: "Opacity of the faint bars. At 0.35 a 90 % bar reads without competing with the line and its figures.",
            val: 0.35,
            from: 0.05,
            to: 1,
            step: 0.05
        },
        {
            label: "bar min px",
            prop: "barMinPx",
            group: "Bars",
            tip: "Smallest drawn height of a bar whose value is drawn at all: a 0.1 mm hour is a couple of pixels, never nothing. A bar is drawn only where its figure is: a UV index that rounds to 0 and a probability under probability min % draw no bar. 2.",
            val: 2,
            from: 0,
            to: 6,
            step: 0.5
        },
        {
            label: "wind max Bft",
            prop: "windMaxBft",
            group: "Scales",
            blurb: "What fills a track. A column above a maximum grows the scale while it is on screen, eased over `max ms`.",
            tip: "Beaufort that fills the track (the user's number). While a visible column exceeds it the scale grows to that column and eases back afterwards. 10.",
            val: 10,
            from: 4,
            to: 12,
            step: 1
        },
        {
            label: "precip full mm",
            prop: "precipMaxMm",
            group: "Scales",
            tip: "Millimetres per hour that fill the track. WMO intensity classes: light < 2.5, moderate 2.5-10, heavy > 10 mm/h. At 5, 0.5 mm is 7 px, 1 mm is 14 px and the light/moderate boundary sits at half height; heavier hours grow the scale while visible.",
            val: 5,
            from: 1,
            to: 20,
            step: 0.5
        },
        {
            label: "UV max",
            prop: "uvMax",
            group: "Scales",
            tip: "UV index that fills the track. 8 is where WHO's 'very high' starts and roughly where a Belgian summer midday peaks; 9+ grows the scale while visible.",
            val: 8,
            from: 3,
            to: 12,
            step: 1
        },
        {
            label: "EAQI max",
            prop: "aqMaxEaqi",
            group: "Scales",
            tip: "EAQI value that fills the track: 100, the top of 'very poor'. Grows while a visible column exceeds it.",
            val: 100,
            from: 20,
            to: 150,
            step: 5
        },
        {
            label: "BelAQI max",
            prop: "aqMaxBelaqi",
            group: "Scales",
            tip: "BelAQI value that fills the track: 10, the index's top. Used when the model's index is BelAQI.",
            val: 10,
            from: 5,
            to: 10,
            step: 1
        },
        {
            label: "temperature min span",
            prop: "tempMinSpan",
            group: "Scales",
            tip: "Smallest range (°C) the temperature and dew-point lines are drawn over, centred on the data, so a 1° day stays flat instead of filling the band. 4.",
            val: 4,
            from: 0,
            to: 15,
            step: 0.5
        },
        {
            label: "pressure min span",
            prop: "pressureMinSpan",
            group: "Scales",
            tip: "Smallest range (hPa) the pressure line is drawn over, so a 2 hPa drift does not look like a storm. 8.",
            val: 8,
            from: 0,
            to: 40,
            step: 1
        },
        {
            label: "visibility min top",
            prop: "visibilityMinSpanKm",
            group: "Scales",
            tip: "Top of the visibility axis (km) while every visible value is lower. The axis always starts at 0, so fog sits at the foot and 15 against 50 km -- both clear air -- is no dramatic swing. 10.",
            val: 10,
            from: 1,
            to: 50,
            step: 1
        },
        {
            label: "view ms",
            prop: "viewMs",
            group: "Motion",
            blurb: "One clock per view switch, one per growing maximum.",
            tip: "Length of the one clock behind a view switch (OutCubic): bars grow between values, a line morphs or fades, the glyph and the arrow swap in their slot; a retarget starts from what is drawn. 260, the shell's motion duration.",
            val: 260,
            from: 0,
            to: 1000,
            step: 10
        },
        {
            label: "max ms",
            prop: "maxMs",
            group: "Motion",
            tip: "Ease time of a bar maximum when the visible columns' maximum changes (scrolling a stormy hour in or out). 260.",
            val: 260,
            from: 0,
            to: 1000,
            step: 10
        },
        {
            label: "hover ground alpha",
            prop: "hoverGroundAlpha",
            group: "Link",
            blurb: "Every column is the link to the detail of its hour, in the metric of the view the strip shows.",
            tip: "How strong the ground under a hovered column is. 0.6, a wash.",
            val: 0.6,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "ground inset",
            prop: "groundInset",
            group: "Link",
            tip: "How far a column's ground (the hover wash, the open column's carve) sits inside its 44 px slot on every side, so the first column's ground is as far from the card's padding at top and bottom as at the side. 2.",
            val: 2,
            from: 0,
            to: 6,
            step: 1
        },
        {
            label: "hover ms",
            prop: "hoverMs",
            group: "Link",
            tip: "How long the hover wash takes. 120.",
            val: 120,
            from: 0,
            to: 400,
            step: 10
        },
        {
            label: "fade height",
            prop: "fadeHeight",
            group: "Scroll",
            blurb: "The edge fades of the scrolling strip.",
            tip: "How wide the fade into the card's fill is at either end. 34, the shell's fade.",
            val: 34,
            from: 0,
            to: 80,
            step: 1
        },
        {
            label: "skeleton columns",
            prop: "skeletonColumns",
            group: "Skeleton",
            blurb: "The silhouette shown until the first model.",
            tip: "How many silhouette columns stand in before the first model. 12.",
            val: 12,
            from: 4,
            to: 24,
            step: 1
        }
    ]

    readonly property var hourlyCyclerParams: [
        {
            label: "title size",
            prop: "titleSize",
            group: "Title box",
            blurb: "The view's name, front and centre in a translucent carved box over the card, with a blurred shadow cast onto the content -- the LLM module's drop overlay. In on the first step of a wheel burst, held while steps come (the text swaps instantly), out after the burst.",
            tip: "Pixel size of the view's name in the centre of the card. 20: 16 got lost in the content and 24 looked heavy on a narrow card (a candidates sheet).",
            val: 20,
            from: 12,
            to: 32,
            step: 1
        },
        {
            label: "box inset",
            prop: "overlayInset",
            group: "Title box",
            tip: "How far the box's edge sits inside the card's rim. At 0 it lands on the rim, the way the LLM drop box lands on its container; at 6 it reads as a second frame; at 12 the corner goes square.",
            val: 0,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "veil alpha",
            prop: "veilAlpha",
            group: "Title box",
            tip: "How opaque the card-ground fill over the content is while a view's title shows. The user, round 3: more transparent. 0.45 keeps the card's content readable through it; the title stays legible by its shadow. Round 2: 0.7.",
            val: 0.45,
            from: 0.3,
            to: 1,
            step: 0.05
        },
        {
            label: "title opacity",
            prop: "titleOpacity",
            group: "Title box",
            tip: "Opacity of the view's name and its shadow, on top of the box's own fade. Below 1 the name reads as printed on the veil rather than laid over the card. 1.",
            val: 1,
            from: 0.2,
            to: 1,
            step: 0.05
        },
        {
            label: "scale from",
            prop: "overlayScaleFrom",
            group: "Title box",
            tip: "The scale the box grows from, on the same clock as its fade. 0.86 is the LLM drop box's number: it reads as growing out of the centre without the edge travelling far.",
            val: 0.86,
            from: 0.5,
            to: 1,
            step: 0.01
        },
        {
            label: "fade ms",
            prop: "overlayFadeMs",
            group: "Title box",
            tip: "How long the box takes to come in and go out (OutCubic). 140, as the LLM drop box the user named.",
            val: 140,
            from: 60,
            to: 400,
            step: 10
        },
        {
            label: "linger ms",
            prop: "overlayLingerMs",
            group: "Title box",
            tip: "How long the box stays after the gesture ends, or after the last wheel event when no end arrives. Any wheel movement inside this window holds the box (a slow drag included); steps only swap its text. 650.",
            val: 650,
            from: 100,
            to: 3000,
            step: 50
        },
        {
            label: "title on dot click",
            prop: "overlayOnClick",
            group: "Title box",
            tip: "Clicking a dot also shows the title box. The label beside the dot already names the view; the box confirms the change the same way the wheel does.",
            val: true
        },
        {
            label: "shadow offset",
            prop: "shadowOffset",
            group: "Title box",
            tip: "How far below the title its blurred shadow sits. 4 at size 20 looks lifted without detaching (the LLM uses 7 under a 46 px glyph).",
            val: 4,
            from: 0,
            to: 12,
            step: 1
        },
        {
            label: "shadow opacity",
            prop: "shadowOpacity",
            group: "Title box",
            tip: "Opacity of the title's and the hover label's shadow. 0.4, as in the LLM.",
            val: 0.4,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "shadow blur",
            prop: "shadowBlur",
            group: "Title box",
            tip: "Blur amount of the shadow copies. 0.7, as in the LLM.",
            val: 0.7,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "shadow blur max",
            prop: "shadowBlurMax",
            group: "Title box",
            tip: "Blur radius of the shadow copies at blur 1. 16, as in the LLM.",
            val: 16,
            from: 2,
            to: 64,
            step: 1
        },
        {
            label: "dot size",
            prop: "dotSize",
            group: "Dots",
            blurb: "A faint array of dots down the card's right padding band, one per view, the current one an accent bead. Shown while the wheel cycles and while the pointer is over the band; hovering a dot fades in its view's name to the left of the dots, right-aligned, clicking it picks that view.",
            tip: "Diameter of each faint dot. 6 fits the 12 px padding band with 3 px either side.",
            val: 6,
            from: 2,
            to: 10,
            step: 1
        },
        {
            label: "active dot size",
            prop: "activeDotSize",
            group: "Dots",
            tip: "Diameter of the accent bead on the current view. The same as the dots: colour alone reads clearly at 1:1. 6.",
            val: 6,
            from: 2,
            to: 12,
            step: 1
        },
        {
            label: "dot pitch",
            prop: "dotPitch",
            group: "Dots",
            tip: "Centre-to-centre spacing of the dots, which is also each dot's click and hover cell along the band. 12 matches the padding and makes square cells.",
            val: 12,
            from: 6,
            to: 24,
            step: 1
        },
        {
            label: "dot opacity",
            prop: "dotOpacity",
            group: "Dots",
            tip: "Opacity of the dots that are not the current view. The user asked for a faint array; 0.55 still shows in dark mode.",
            val: 0.55,
            from: 0.1,
            to: 1,
            step: 0.05
        },
        {
            label: "dots fade ms",
            prop: "dotsFadeMs",
            group: "Dots",
            tip: "Presence fade of the dot array: the shell's 160 ms presence rule.",
            val: 160,
            from: 60,
            to: 400,
            step: 10
        },
        {
            label: "dots linger ms",
            prop: "dotsLingerMs",
            group: "Dots",
            tip: "How long the dots stay after the last wheel step, pick or gesture end. Longer than the title's linger, so how many views there are is still readable after the title leaves. 1200.",
            val: 1200,
            from: 200,
            to: 4000,
            step: 50
        },
        {
            label: "hover linger ms",
            prop: "dotsHoverLingerMs",
            group: "Dots",
            tip: "How long the dots stay after the pointer leaves the band. Short, but it absorbs a brief slip off a 12 px band. 300.",
            val: 300,
            from: 0,
            to: 2000,
            step: 50
        },
        {
            label: "bead move ms",
            prop: "dotMoveMs",
            group: "Dots",
            tip: "How long the accent bead takes to slide to the new dot (one eased position, OutCubic, the motion rule's 260). Placed without sliding while the dots are hidden.",
            val: 260,
            from: 0,
            to: 600,
            step: 10
        },
        {
            label: "hover slack",
            prop: "hoverSlack",
            group: "Dots",
            tip: "How far the band's hover reaches past the padding into the strip's content and past the first and last dot. The links under it keep their hover and clicks (a HoverHandler on the card, not an item over it). 6.",
            val: 6,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "label size",
            prop: "labelSize",
            group: "Dots",
            tip: "Pixel size of a hovered dot's name. 11.",
            val: 11,
            from: 8,
            to: 16,
            step: 1
        },
        {
            label: "label gap",
            prop: "labelGap",
            group: "Dots",
            tip: "Space between a hovered dot's name and the dots, to the left of the dots, right-aligned. 6.",
            val: 6,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "label fade ms",
            prop: "labelFadeMs",
            group: "Dots",
            tip: "Presence fade of the hovered dot's name. Moving from dot to dot swaps its text and place instantly. 160.",
            val: 160,
            from: 60,
            to: 400,
            step: 10
        },
        {
            label: "label shadow offset",
            prop: "labelShadowOffset",
            group: "Dots",
            tip: "How far below the hovered dot's name its blurred shadow sits. Half the title's, for the smaller type. 2.",
            val: 2,
            from: 0,
            to: 8,
            step: 1
        },
        {
            label: "label knock pad",
            prop: "labelKnockPad",
            group: "Dots",
            tip: "How far the blurred patch of card ground behind a hovered dot's name reaches past the words (half as far vertically). At 8 the neighbouring figure ran into the name; at 12 it fades out.",
            val: 12,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "label knock alpha",
            prop: "labelKnockAlpha",
            group: "Dots",
            tip: "Opacity of that patch. At 0.9 the figures under the name ghosted through; at 1 its core is clean and the blurred edge still lets the content show at the rim.",
            val: 1,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "label knock blur",
            prop: "labelKnockBlur",
            group: "Dots",
            tip: "Edge softness of that patch. At 12 its core thinned below opaque; at 8 the core stays solid and the edge soft.",
            val: 8,
            from: 2,
            to: 32,
            step: 1
        },
        {
            label: "notch threshold",
            prop: "notchThreshold",
            group: "Wheel",
            blurb: "How much wheel makes one view step, and what happens past the last view.",
            tip: "Units per view step from a mouse wheel (angle deltas and no pixel deltas; one notch is 120): one notch, one view. A high-resolution wheel's smaller deltas add up to the same notch. 120.",
            val: 120,
            from: 40,
            to: 480,
            step: 10
        },
        {
            label: "step cooldown ms",
            prop: "stepCooldownMs",
            group: "Wheel",
            tip: "After a view step the wheel is not read for this long, and what the event still carried is dropped: a fast flick moves one view per cooldown instead of racing round the ring. 0 turns it off (every threshold's worth steps). 200.",
            val: 200,
            from: 0,
            to: 800,
            step: 10
        },
        {
            label: "pixel threshold",
            prop: "pixelThreshold",
            group: "Wheel",
            tip: "Units per view step from a touchpad (any wheel event that carries pixel deltas; on Wayland it carries angle deltas too, and round 2 counted those against the 120-unit notch, so a few millimetres of finger drift stepped a view -- the overshoot the user reported). 1000, the view switcher's own detent (TabSelector's swipe threshold).",
            val: 1000,
            from: 120,
            to: 2000,
            step: 20
        },
        {
            label: "wrap",
            prop: "wrap",
            group: "Wheel",
            tip: "Past the last view the wheel comes back to the first: the views are a ring, and the dots show where on it the card is.",
            val: true
        }
    ]

    readonly property var dailyParams: [
        {
            label: "row height",
            prop: "rowHeight",
            group: "Rows",
            blurb: "One row per day, sixteen of them, seven visible -- seven views of the same rows, cycled by a horizontal wheel over the card (the Views tab).",
            tip: "Each day's row height. 48 holds two lines of text and a 24 px glyph pair.",
            val: 48,
            from: 32,
            to: 72,
            step: 1
        },
        {
            label: "visible rows",
            prop: "visibleRows",
            group: "Rows",
            tip: "How many rows the card asks for; the rest are on the wheel. 7: a week.",
            val: 7,
            from: 3,
            to: 16,
            step: 1
        },
        {
            label: "row inset",
            prop: "rowInset",
            group: "Rows",
            tip: "How far a row's ground (today's shade, the hover wash, the open row) sits in from the card's padding line, at the sides, the top and the foot. 0: today's row starts on the padding line, 12 px from the card's edge on every side, where every card's first ink starts. Round 3: 6.",
            val: 0,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "row radius",
            prop: "rowRadius",
            group: "Rows",
            tip: "The radius of a row's ground (today's, the hover wash, the open row's). 8.",
            val: 8,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "row padding",
            prop: "rowPadH",
            group: "Rows",
            tip: "Space between a row's ground edge and its first and last column. 8.",
            val: 8,
            from: 0,
            to: 20,
            step: 1
        },
        {
            label: "column gap",
            prop: "colGap",
            group: "Rows",
            tip: "Gap between the row's columns. 10.",
            val: 10,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "glyph size",
            prop: "glyphSize",
            group: "Glyphs",
            blurb: "The day's and the night's condition glyphs flank the temperatures and their range; the wind view's arrows flank its pair.",
            tip: "Each condition glyph's size. 24, the same as the strip's.",
            val: 24,
            from: 16,
            to: 40,
            step: 1
        },
        {
            label: "glyph gap",
            prop: "glyphGap",
            group: "Glyphs",
            tip: "Gap between a flanking condition glyph and the temperature figure beside it. 4.",
            val: 4,
            from: 0,
            to: 12,
            step: 1
        },
        {
            label: "arrow size",
            prop: "arrowSize",
            group: "Glyphs",
            tip: "Size of the carved wind-direction arrows flanking the wind view's pair. 22 sits just under the 24 px condition glyphs, so arrows and glyphs read as one family.",
            val: 22,
            from: 14,
            to: 32,
            step: 1
        },
        {
            label: "flank gap",
            prop: "flankGap",
            group: "Glyphs",
            tip: "Gap between a flanking glyph or arrow and the pair it frames (the wind and precipitation views). 6, the figure gap: the flank sits as close as a figure sits to its groove.",
            val: 6,
            from: 2,
            to: 16,
            step: 1
        },
        {
            label: "weekday size",
            prop: "weekdaySize",
            group: "Type",
            blurb: "Five sizes: the weekday, the date, the figures, the small figures, the air-quality labels.",
            tip: "The weekday, bold. 12.",
            val: 12,
            from: 9,
            to: 16,
            step: 1
        },
        {
            label: "date size",
            prop: "dateSize",
            group: "Type",
            tip: "The date under the weekday, faint. 11.",
            val: 11,
            from: 8,
            to: 14,
            step: 1
        },
        {
            label: "figure size",
            prop: "figureSize",
            group: "Type",
            tip: "The min and max temperatures and the bar views' figures (probability, hours of sunshine, UV). 12.",
            val: 12,
            from: 9,
            to: 16,
            step: 1
        },
        {
            label: "small size",
            prop: "smallSize",
            group: "Type",
            tip: "The pair's figures (millimetres, wind speeds) and the air-quality values. 11.",
            val: 11,
            from: 8,
            to: 14,
            step: 1
        },
        {
            label: "label size",
            prop: "labelSize",
            group: "Type",
            tip: "Pixel size of the air-quality labels (AQI, PM2.5, ...) over their bars. 10: faint, one step under the 11 px figures, and on the weekday line so the bars line up with the date line.",
            val: 10,
            from: 8,
            to: 12,
            step: 1
        },
        {
            label: "groove height",
            prop: "grooveHeight",
            group: "Groove",
            blurb: "The range groove: a carved track over the days' range, the day's span a raised segment on it coloured by temperature, the probability a faint fill from its right end. The sunshine, UV and air-quality views reuse it as their bars.",
            tip: "The carved track's height. 6.",
            val: 6,
            from: 2,
            to: 12,
            step: 1
        },
        {
            label: "segment height",
            prop: "segmentHeight",
            group: "Groove",
            tip: "The raised segment's height; a little more than the track so it stands proud of it. 8.",
            val: 8,
            from: 4,
            to: 16,
            step: 1
        },
        {
            label: "segment min width",
            prop: "segmentMinWidth",
            group: "Groove",
            tip: "The narrowest a raised segment or fill gets: a day with no temperature range, or a small sunshine / UV / air-quality value. 12, 1.5 x the 8 px segment's height (the pair's ratio): a horizontal pill, never a dot or an upright tick (round 2 drew PM10 as a 2x8 tick).",
            val: 12,
            from: 2,
            to: 20,
            step: 1
        },
        {
            label: "figure gap",
            prop: "figureGap",
            group: "Groove",
            tip: "Gap between the min figure and the track, and the track and the max figure. 6, the text-to-rail gap.",
            val: 6,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "probability alpha",
            prop: "popAlpha",
            group: "Groove",
            tip: "Opacity of the faint precipitation-probability fill inside the groove, from its right end, under the temperature segment. 0.16: tinted, not a second bar (0.3 read as one in both themes).",
            val: 0.16,
            from: 0,
            to: 0.6,
            step: 0.02
        },
        {
            label: "pair bar length",
            prop: "pairBarLength",
            group: "Pair",
            blurb: "The day's bar (left) and the night's (right, fainter) back to back, growing out from the centre, their figures riding on the bar ends: precipitation in the conditions views, and the whole row in the wind and precipitation views.",
            tip: "Longest each precipitation bar gets in the conditions and feels-like views, either side of the centre. 18 keeps the pair to about 100 px so the groove keeps its room on the 480 card; in the wind and precipitation views the pair grows to fill the row.",
            val: 18,
            from: 8,
            to: 40,
            step: 1
        },
        {
            label: "pair bar height",
            prop: "pairBarHeight",
            group: "Pair",
            tip: "Thickness of the day and night bars. 4: tiny bars, clearly thinner than the 6 px groove, so they never read as a second range bar.",
            val: 4,
            from: 2,
            to: 8,
            step: 0.5
        },
        {
            label: "pair centre gap",
            prop: "pairCenterGap",
            group: "Pair",
            tip: "Gap between the day bar's and the night bar's zero ends. 2: back to back, the two halves still visibly separate.",
            val: 2,
            from: 0,
            to: 8,
            step: 1
        },
        {
            label: "value gap",
            prop: "valueGap",
            group: "Pair",
            tip: "Gap between a figure and the bar end it rides on (the pair's values, the air-quality values). 3: attached, not touching.",
            val: 3,
            from: 0,
            to: 8,
            step: 1
        },
        {
            label: "bar min px",
            prop: "barMinPx",
            group: "Pair",
            tip: "Shortest bar a non-zero value gets in the pair. 6, 1.5 x the 4 px bar's height: a 0.1 mm trace is a horizontal pill growing out of the centre, never a 2x4 tick or a 4x4 dot (round 2's 2 px floor made a 0.4 / 0.4 mm day read as a pause sign).",
            val: 6,
            from: 0,
            to: 12,
            step: 0.5
        },
        {
            label: "night bar alpha",
            prop: "nightBarAlpha",
            group: "Pair",
            tip: "Opacity of the night (right) bar against the day bar's colour. 0.45: the same hue, clearly fainter, as asked.",
            val: 0.45,
            from: 0.1,
            to: 1,
            step: 0.05
        },
        {
            label: "segment gap",
            prop: "aqSegmentGap",
            group: "Air quality",
            blurb: "The air-quality view splits the groove into one bar per value.",
            tip: "Gap between one air-quality value's figure and the next value's bar. 10, the column gap.",
            val: 10,
            from: 4,
            to: 20,
            step: 1
        },
        {
            label: "values shown",
            prop: "aqCount",
            group: "Air quality",
            tip: "How many air-quality values a row shows, in order: index, PM2.5, PM10, O3, NO2, SO2, CO. 5 at both card widths: 7 leaves 11 px bars on the 480 card, and SO2 and CO sit in their lowest band all year in Belgium (CO is not in the EAQI), so their bars would always be empty.",
            val: 5,
            from: 1,
            to: 7,
            step: 1
        },
        {
            label: "precip half max",
            prop: "precipHalfMax",
            group: "Scales",
            blurb: "What fills a bar, computed over the rows in the viewport: a visible row above a maximum stretches the scale, eased over `max ease ms`.",
            tip: "Millimetres per half-day (sunrise to sunset, sunset to sunrise) that fill a precipitation bar. 5: 3.6 px per mm on the 18 px conditions pair (2.3 mm draws 8 px, 3.8 mm 14), so a common wet Belgian half-day (1-5 mm) reads as a length; under 1.7 mm is the bar min px floor; a visible row above 5 stretches the scale.",
            val: 5,
            from: 1,
            to: 50,
            step: 0.5
        },
        {
            label: "wind max Bft",
            prop: "windMaxBft",
            group: "Scales",
            tip: "Beaufort that fills a wind bar (continuous Beaufort from the half-day's mean speed). 10, the strip's number, so the two cards read wind on one scale.",
            val: 10,
            from: 4,
            to: 12,
            step: 1
        },
        {
            label: "sunshine max h",
            prop: "sunshineMaxHours",
            group: "Scales",
            tip: "Hours of sunshine that fill the sunshine bar. 13, the user's natural peak.",
            val: 13,
            from: 8,
            to: 16,
            step: 0.5
        },
        {
            label: "UV max",
            prop: "uvMax",
            group: "Scales",
            tip: "UV index that fills the UV bar. 8, WHO's 'very high' threshold: a Belgian summer peak (7-8) nearly fills it, a winter 1 is an eighth; the band colour carries the severity.",
            val: 8,
            from: 3,
            to: 11,
            step: 0.5
        },
        {
            label: "transition ms",
            prop: "transitionMs",
            group: "Motion",
            blurb: "One clock per view switch, one per stretching maximum.",
            tip: "Length of the one clock a view switch runs on: every element's place, width, presence, bar length and colour; elements shared by both views move, the rest shrink away or grow in. 260 OutCubic; a retarget starts from what is drawn.",
            val: 260,
            from: 0,
            to: 1000,
            step: 10
        },
        {
            label: "cross dip",
            prop: "crossDip",
            group: "Motion",
            tip: "How far the day glyph shrinks halfway through changing sides of the pair (conditions <-> precipitation). 0.6: at the crossing it is 40 % of its size, so it hops over the figures instead of sliding across them.",
            val: 0.6,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "max ease ms",
            prop: "maxEaseMs",
            group: "Motion",
            tip: "How long a scale's maximum eases when the rows in the viewport change it (scrolling a wet day in or out). 260.",
            val: 260,
            from: 0,
            to: 1000,
            step: 10
        },
        {
            label: "row ground gap",
            prop: "rowGroundGap",
            group: "Link",
            blurb: "Every row is the link to its day's detail, in the metric of the view the list shows; the open row sinks: today's shade carved in with the popup's inset knobs.",
            tip: "How far a row's ground (today's shade, the hover wash, the open row's carve) sits inside its slot at top and bottom; the list starts and ends row inset minus this, so the first ground is as far from the card's padding at the top as at the sides. 2.",
            val: 2,
            from: 0,
            to: 6,
            step: 1
        },
        {
            label: "hover ground alpha",
            prop: "hoverGroundAlpha",
            group: "Link",
            tip: "How strong the ground under a hovered row is. 0.6, a wash.",
            val: 0.6,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "hover ms",
            prop: "hoverMs",
            group: "Link",
            tip: "How long the hover wash takes. 120.",
            val: 120,
            from: 0,
            to: 400,
            step: 10
        },
        {
            label: "fade height",
            prop: "fadeHeight",
            group: "Scroll",
            blurb: "The edge fades of the scrolling list.",
            tip: "How tall the fade into the card's fill is at the top and the foot. 34.",
            val: 34,
            from: 0,
            to: 80,
            step: 1
        },
        {
            label: "skeleton rows",
            prop: "skeletonRows",
            group: "Skeleton",
            blurb: "The silhouette shown until the first model.",
            tip: "How many silhouette rows stand in before the first model. 7, the visible count.",
            val: 7,
            from: 1,
            to: 16,
            step: 1
        }
    ]

    readonly property var dailyCyclerParams: [
        {
            label: "title size",
            prop: "titleSize",
            group: "Title box",
            blurb: "The view's name, front and centre in a translucent carved box over the card, with a blurred shadow cast onto the content -- the LLM module's drop overlay. In on the first step of a wheel burst, held while steps come (the text swaps instantly), out after the burst.",
            tip: "Pixel size of the view's name in the centre of the card. 20: 16 got lost in the content and 24 looked heavy on a narrow card (a candidates sheet).",
            val: 20,
            from: 12,
            to: 32,
            step: 1
        },
        {
            label: "box inset",
            prop: "overlayInset",
            group: "Title box",
            tip: "How far the box's edge sits inside the card's rim. At 0 it lands on the rim, the way the LLM drop box lands on its container; at 6 it reads as a second frame; at 12 the corner goes square.",
            val: 0,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "veil alpha",
            prop: "veilAlpha",
            group: "Title box",
            tip: "How opaque the card-ground fill over the content is while a view's title shows. The user, round 3: more transparent. 0.45 keeps the card's content readable through it; the title stays legible by its shadow. Round 2: 0.7.",
            val: 0.45,
            from: 0.3,
            to: 1,
            step: 0.05
        },
        {
            label: "title opacity",
            prop: "titleOpacity",
            group: "Title box",
            tip: "Opacity of the view's name and its shadow, on top of the box's own fade. Below 1 the name reads as printed on the veil rather than laid over the card. 1.",
            val: 1,
            from: 0.2,
            to: 1,
            step: 0.05
        },
        {
            label: "scale from",
            prop: "overlayScaleFrom",
            group: "Title box",
            tip: "The scale the box grows from, on the same clock as its fade. 0.86 is the LLM drop box's number: it reads as growing out of the centre without the edge travelling far.",
            val: 0.86,
            from: 0.5,
            to: 1,
            step: 0.01
        },
        {
            label: "fade ms",
            prop: "overlayFadeMs",
            group: "Title box",
            tip: "How long the box takes to come in and go out (OutCubic). 140, as the LLM drop box the user named.",
            val: 140,
            from: 60,
            to: 400,
            step: 10
        },
        {
            label: "linger ms",
            prop: "overlayLingerMs",
            group: "Title box",
            tip: "How long the box stays after the gesture ends, or after the last wheel event when no end arrives. Any wheel movement inside this window holds the box (a slow drag included); steps only swap its text. 650.",
            val: 650,
            from: 100,
            to: 3000,
            step: 50
        },
        {
            label: "title on dot click",
            prop: "overlayOnClick",
            group: "Title box",
            tip: "Clicking a dot also shows the title box. The label beside the dot already names the view; the box confirms the change the same way the wheel does.",
            val: true
        },
        {
            label: "shadow offset",
            prop: "shadowOffset",
            group: "Title box",
            tip: "How far below the title its blurred shadow sits. 4 at size 20 looks lifted without detaching (the LLM uses 7 under a 46 px glyph).",
            val: 4,
            from: 0,
            to: 12,
            step: 1
        },
        {
            label: "shadow opacity",
            prop: "shadowOpacity",
            group: "Title box",
            tip: "Opacity of the title's and the hover label's shadow. 0.4, as in the LLM.",
            val: 0.4,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "shadow blur",
            prop: "shadowBlur",
            group: "Title box",
            tip: "Blur amount of the shadow copies. 0.7, as in the LLM.",
            val: 0.7,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "shadow blur max",
            prop: "shadowBlurMax",
            group: "Title box",
            tip: "Blur radius of the shadow copies at blur 1. 16, as in the LLM.",
            val: 16,
            from: 2,
            to: 64,
            step: 1
        },
        {
            label: "dot size",
            prop: "dotSize",
            group: "Dots",
            blurb: "A faint array of dots along the card's bottom padding band, one per view, the current one an accent bead. Shown while the wheel cycles and while the pointer is over the band; hovering a dot fades in its view's name above the row of dots, clicking it picks that view.",
            tip: "Diameter of each faint dot. 6 fits the 12 px padding band with 3 px either side.",
            val: 6,
            from: 2,
            to: 10,
            step: 1
        },
        {
            label: "active dot size",
            prop: "activeDotSize",
            group: "Dots",
            tip: "Diameter of the accent bead on the current view. The same as the dots: colour alone reads clearly at 1:1. 6.",
            val: 6,
            from: 2,
            to: 12,
            step: 1
        },
        {
            label: "dot pitch",
            prop: "dotPitch",
            group: "Dots",
            tip: "Centre-to-centre spacing of the dots, which is also each dot's click and hover cell along the band. 12 matches the padding and makes square cells.",
            val: 12,
            from: 6,
            to: 24,
            step: 1
        },
        {
            label: "dot opacity",
            prop: "dotOpacity",
            group: "Dots",
            tip: "Opacity of the dots that are not the current view. The user asked for a faint array; 0.55 still shows in dark mode.",
            val: 0.55,
            from: 0.1,
            to: 1,
            step: 0.05
        },
        {
            label: "dots fade ms",
            prop: "dotsFadeMs",
            group: "Dots",
            tip: "Presence fade of the dot array: the shell's 160 ms presence rule.",
            val: 160,
            from: 60,
            to: 400,
            step: 10
        },
        {
            label: "dots linger ms",
            prop: "dotsLingerMs",
            group: "Dots",
            tip: "How long the dots stay after the last wheel step, pick or gesture end. Longer than the title's linger, so how many views there are is still readable after the title leaves. 1200.",
            val: 1200,
            from: 200,
            to: 4000,
            step: 50
        },
        {
            label: "hover linger ms",
            prop: "dotsHoverLingerMs",
            group: "Dots",
            tip: "How long the dots stay after the pointer leaves the band. Short, but it absorbs a brief slip off a 12 px band. 300.",
            val: 300,
            from: 0,
            to: 2000,
            step: 50
        },
        {
            label: "bead move ms",
            prop: "dotMoveMs",
            group: "Dots",
            tip: "How long the accent bead takes to slide to the new dot (one eased position, OutCubic, the motion rule's 260). Placed without sliding while the dots are hidden.",
            val: 260,
            from: 0,
            to: 600,
            step: 10
        },
        {
            label: "hover slack",
            prop: "hoverSlack",
            group: "Dots",
            tip: "How far the band's hover reaches past the padding into the list's content and past the first and last dot. The links under it keep their hover and clicks (a HoverHandler on the card, not an item over it). 6.",
            val: 6,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "label size",
            prop: "labelSize",
            group: "Dots",
            tip: "Pixel size of a hovered dot's name. 11.",
            val: 11,
            from: 8,
            to: 16,
            step: 1
        },
        {
            label: "label gap",
            prop: "labelGap",
            group: "Dots",
            tip: "Space between a hovered dot's name and the dots, above the row of dots. 6.",
            val: 6,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "label fade ms",
            prop: "labelFadeMs",
            group: "Dots",
            tip: "Presence fade of the hovered dot's name. Moving from dot to dot swaps its text and place instantly. 160.",
            val: 160,
            from: 60,
            to: 400,
            step: 10
        },
        {
            label: "label shadow offset",
            prop: "labelShadowOffset",
            group: "Dots",
            tip: "How far below the hovered dot's name its blurred shadow sits. Half the title's, for the smaller type. 2.",
            val: 2,
            from: 0,
            to: 8,
            step: 1
        },
        {
            label: "label knock pad",
            prop: "labelKnockPad",
            group: "Dots",
            tip: "How far the blurred patch of card ground behind a hovered dot's name reaches past the words (half as far vertically). At 8 the neighbouring figure ran into the name; at 12 it fades out.",
            val: 12,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "label knock alpha",
            prop: "labelKnockAlpha",
            group: "Dots",
            tip: "Opacity of that patch. At 0.9 the figures under the name ghosted through; at 1 its core is clean and the blurred edge still lets the content show at the rim.",
            val: 1,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "label knock blur",
            prop: "labelKnockBlur",
            group: "Dots",
            tip: "Edge softness of that patch. At 12 its core thinned below opaque; at 8 the core stays solid and the edge soft.",
            val: 8,
            from: 2,
            to: 32,
            step: 1
        },
        {
            label: "notch threshold",
            prop: "notchThreshold",
            group: "Wheel",
            blurb: "How much wheel makes one view step, and what happens past the last view.",
            tip: "Units per view step from a mouse wheel (angle deltas and no pixel deltas; one notch is 120): one notch, one view. A high-resolution wheel's smaller deltas add up to the same notch. 120.",
            val: 120,
            from: 40,
            to: 480,
            step: 10
        },
        {
            label: "step cooldown ms",
            prop: "stepCooldownMs",
            group: "Wheel",
            tip: "After a view step the wheel is not read for this long, and what the event still carried is dropped: a fast flick moves one view per cooldown instead of racing round the ring. 0 turns it off (every threshold's worth steps). 200.",
            val: 200,
            from: 0,
            to: 800,
            step: 10
        },
        {
            label: "pixel threshold",
            prop: "pixelThreshold",
            group: "Wheel",
            tip: "Units per view step from a touchpad (any wheel event that carries pixel deltas; on Wayland it carries angle deltas too, and round 2 counted those against the 120-unit notch, so a few millimetres of finger drift stepped a view -- the overshoot the user reported). 1000, the view switcher's own detent (TabSelector's swipe threshold).",
            val: 1000,
            from: 120,
            to: 2000,
            step: 20
        },
        {
            label: "wrap",
            prop: "wrap",
            group: "Wheel",
            tip: "Past the last view the wheel comes back to the first: the views are a ring, and the dots show where on it the card is.",
            val: true
        }
    ]

    readonly property var tilesParams: [
        {
            label: "gap",
            prop: "gap",
            group: "Grid",
            blurb: "Ten tiles in three columns, shown in the detailed view only.",
            tip: "Gap between tiles, both ways. 12, the shell's spacing.",
            val: 12,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "tile height",
            prop: "tileHeight",
            group: "Grid",
            tip: "Each tile's natural height; a row stretches to the column's remainder in the detailed view. 100 holds a title, a figure, a line and a mark.",
            val: 100,
            from: 72,
            to: 160,
            step: 1
        },
        {
            label: "tile radius",
            prop: "tileRadius",
            group: "Grid",
            tip: "Each tile's corner radius. 10, the compact container radius.",
            val: 10,
            from: 4,
            to: 20,
            step: 1
        },
        {
            label: "tile padding",
            prop: "tilePadding",
            group: "Grid",
            tip: "Space inside a tile. 12.",
            val: 12,
            from: 4,
            to: 24,
            step: 1
        },
        {
            label: "title size",
            prop: "titleSize",
            group: "Type",
            blurb: "The title, the figure, the line under it.",
            tip: "The tile's title, muted. 11.",
            val: 11,
            from: 8,
            to: 14,
            step: 1
        },
        {
            label: "figure size",
            prop: "figureSize",
            group: "Type",
            tip: "The tile's one figure, bold. 16, the title size of the shell.",
            val: 16,
            from: 11,
            to: 24,
            step: 1
        },
        {
            label: "body size",
            prop: "bodySize",
            group: "Type",
            tip: "The line under the figure: a band name, the next wet hour, the gusts. 11.",
            val: 11,
            from: 8,
            to: 14,
            step: 1
        },
        {
            label: "mark height",
            prop: "markHeight",
            group: "Marks",
            blurb: "The one mark a tile carries: bars, a band row, a groove, a rose, an arc, the moon.",
            tip: "The height of the marks laid along a tile's foot: the precipitation bars, the band dots, the UV groove. 14.",
            val: 14,
            from: 8,
            to: 28,
            step: 1
        },
        {
            label: "bar width",
            prop: "barWidth",
            group: "Marks",
            tip: "The precipitation tile's twelve hourly bars: each one's width. 4.",
            val: 4,
            from: 2,
            to: 10,
            step: 1
        },
        {
            label: "bar gap",
            prop: "barGap",
            group: "Marks",
            tip: "Gap between the precipitation bars. 2.",
            val: 2,
            from: 0,
            to: 6,
            step: 1
        },
        {
            label: "dot size",
            prop: "dotSize",
            group: "Marks",
            tip: "The band dots of the air-quality row and the pollen mark. 8; the current band is drawn raised and 2 px larger.",
            val: 8,
            from: 4,
            to: 14,
            step: 1
        },
        {
            label: "dot gap",
            prop: "dotGap",
            group: "Marks",
            tip: "Gap between the band dots. 4.",
            val: 4,
            from: 0,
            to: 10,
            step: 1
        },
        {
            label: "rose size",
            prop: "roseSize",
            group: "Marks",
            tip: "The wind tile's compass rose diameter; the carved arrow inside it is 0.55 of this (14 px at 26), the same dart as the strip's and the list's wind views. 26.",
            val: 26,
            from: 16,
            to: 40,
            step: 1
        },
        {
            label: "arc width",
            prop: "arcWidth",
            group: "Marks",
            tip: "The sun tile's day arc, sunrise at its left foot and sunset at its right. 44 wide.",
            val: 44,
            from: 24,
            to: 64,
            step: 1
        },
        {
            label: "moon size",
            prop: "moonSize",
            group: "Marks",
            tip: "The moon tile's glyph. 32.",
            val: 32,
            from: 20,
            to: 48,
            step: 1
        },
        {
            label: "hover ground alpha",
            prop: "hoverGroundAlpha",
            group: "Link",
            blurb: "Every tile is the link to its metric's detail for today.",
            tip: "How strong the ground of a hovered tile is. 0.6, a wash.",
            val: 0.6,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "hover ms",
            prop: "hoverMs",
            group: "Link",
            tip: "How long the hover wash takes. 120.",
            val: 120,
            from: 0,
            to: 400,
            step: 10
        }
    ]

    readonly property var detailParams: [
        {
            label: "compact",
            prop: "detailCompact",
            group: "Chart",
            blurb: "The detail's chart card: WeatherDetail's own knobs, bound through the popup's secondaryComponent.",
            tip: "The detail's compact layout: 360 wide, radius 10, a lower chart, narrower day chips. Off, the 420 px layout.",
            val: false
        },
        {
            label: "chart height",
            prop: "detailChartHeight",
            group: "Chart",
            tip: "The TimelineChart's height inside its card. 176 in the normal layout.",
            val: 176,
            from: 100,
            to: 300,
            step: 1
        },
        {
            label: "chip width",
            prop: "detailChipWidth",
            group: "Chart",
            tip: "Each day chip's width in the detail's day strip. 50 holds a weekday, a 24 px glyph and two figures.",
            val: 50,
            from: 36,
            to: 80,
            step: 1
        },
        {
            label: "chip gap",
            prop: "detailChipGap",
            group: "Chart",
            tip: "Gap between the day chips. 4.",
            val: 4,
            from: 0,
            to: 12,
            step: 1
        },
        {
            label: "card radius",
            prop: "detailCardRadius",
            group: "Chart",
            tip: "The detail's cards' corner radius. 14, the container radius.",
            val: 14,
            from: 4,
            to: 24,
            step: 1
        },
        {
            label: "temperature min span",
            prop: "detailTemperatureMinSpan",
            group: "Axis",
            blurb: "The chart axes' floors and spans (WeatherSeries.js has the table per metric): a flat day is drawn flat, and a value only reaches the top when it matters.",
            tip: "Smallest y range, in °C, of the temperature and feels-like charts. A narrower day is drawn against this range, centred on its middle, so a 4° evening does not look like a heatwave swing. 10 is a typical Belgian summer day's swing (KMI Uccle, July: max about 23, min about 13).",
            val: 10,
            from: 2,
            to: 30,
            step: 1
        },
        {
            label: "pressure min span",
            prop: "detailPressureMinSpan",
            group: "Axis",
            tip: "Smallest y range, in hPa, of the pressure chart. A front moves pressure about 10 hPa in a day; without this a 0.6 hPa evening filled the whole chart. 20: a front's change fills half of it.",
            val: 20,
            from: 5,
            to: 60,
            step: 1
        },
        {
            label: "title size",
            prop: "detailTitleSize",
            group: "Scale",
            blurb: "The detail's type, and the scale table's.",
            tip: "The metric's title in the detail's header. 16.",
            val: 16,
            from: 11,
            to: 24,
            step: 1
        },
        {
            label: "body size",
            prop: "detailBodySize",
            group: "Scale",
            tip: "The detail's body text: the about text, the band advice. 12.",
            val: 12,
            from: 9,
            to: 16,
            step: 1
        },
        {
            label: "figure size",
            prop: "detailFigureSize",
            group: "Scale",
            tip: "The detail's figures: the chart's axis labels, the chips' figures, the scale table. 11.",
            val: 11,
            from: 8,
            to: 14,
            step: 1
        },
        {
            label: "morph ms",
            prop: "detailMorphMs",
            group: "Day change",
            blurb: "The morph to another day.",
            tip: "How long a day change takes: every chart moves from the day on screen to the new one on one clock, and the day strip slides to the chip. 260, the cards' view morph and the resize.",
            val: 260,
            from: 0,
            to: 1000,
            step: 10
        },
        {
            label: "swipe days",
            prop: "detailSwipeToSwitchDay",
            group: "Swipe",
            blurb: "Stepping the day with a sideways swipe or a wheel.",
            tip: "Whether a sideways two-finger swipe anywhere over the detail steps the day (clamped at both ends, no wrap). The device scaling, the gesture's silent end and the strip's wheel speed are the popup's own (Layout tab).",
            val: true
        },
        {
            label: "notch threshold",
            prop: "detailSwipeNotchThreshold",
            group: "Swipe",
            tip: "Wheel units per day from a mouse notch (angle 120, no pixel delta): one notch, one day. 120, the cards' cyclers.",
            val: 120,
            from: 30,
            to: 480,
            step: 10
        },
        {
            label: "pixel threshold",
            prop: "detailSwipePixelThreshold",
            group: "Swipe",
            tip: "Units per day from a touchpad (any event with a pixel delta; Wayland sends angle deltas too). 1000, the view switcher's detent: less and a few millimetres of drift step a day.",
            val: 1000,
            from: 200,
            to: 3000,
            step: 50
        },
        {
            label: "step cooldown",
            prop: "detailSwipeStepCooldownMs",
            group: "Swipe",
            tip: "After a step the wheel is ignored this long, so a flick moves one day per cooldown instead of racing to the end. 200, the cards' cyclers.",
            val: 200,
            from: 0,
            to: 800,
            step: 10
        }
    ]

    readonly property var glyphParams: [
        {
            label: "bevel width",
            prop: "glyphBevelWidth",
            group: "Carve",
            blurb: "WeatherGlyph's carve, applied to every glyph on the stage and in the gallery: the light rim outside each part's edge, the inset inside it, the flat body in the part's own colour (the Colours tab's glyph tokens).",
            tip: "The light rim outside each part's edge, in device px. 1.25: this rim is the gap that separates a cloud from the sun or grey cloud behind it at 24 px, and on the card it is ShadowBox's bevel.",
            val: 1.25,
            from: 0,
            to: 3,
            step: 0.25
        },
        {
            label: "shadow width",
            prop: "glyphShadowWidth",
            group: "Carve",
            tip: "How deep the inset shadow reaches, as a share of the glyph size, clamped to 1.5..7 device px. 0.1 gives 2.4 px at 24 and 7 px at 88: the glyph reads as carved without a white cloud turning grey.",
            val: 0.1,
            from: 0.02,
            to: 0.3,
            step: 0.01
        },
        {
            label: "part shadow share",
            prop: "glyphPartShadowShare",
            group: "Carve",
            tip: "Caps the inset at this share of a part's own inscribed half-width (a drop's round end, a flake arm, a bolt stroke). Without it a 2 px flake arm is all shadow and loses its colour. 0.9.",
            val: 0.9,
            from: 0.2,
            to: 1.5,
            step: 0.05
        },
        {
            label: "shadow tint",
            prop: "glyphShadowTint",
            group: "Carve",
            tip: "Where the inset's edge colour starts: 0 is the part's colour multiplied by the theme's glyph shade (the full carve), 1 is the colour itself (no inset). 0, because the shade token is tuned per theme.",
            val: 0,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "body tint",
            prop: "glyphBodyTint",
            group: "Carve",
            tip: "How far a part's flat body moves from the sunk panel colour (0) to its own colour (1). 1 gives the references' white cloud and yellow sun; lower brings back round 1's pale look.",
            val: 1,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "bevel alpha",
            prop: "glyphBevelAlpha",
            group: "Carve",
            tip: "Opacity of the rim outside each part. 1: it is the separating gap between overlapping parts, and it fades out over its own width anyway.",
            val: 1,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "shadow edge alpha",
            prop: "glyphShadowEdgeAlpha",
            group: "Carve",
            tip: "Strength of the inset at the very edge (ShadowBox's edge alpha). 1.",
            val: 1,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "shadow falloff",
            prop: "glyphShadowFalloff",
            group: "Carve",
            tip: "Exponent on the inset's fade: above 1 it hugs the edge, below 1 it spreads inward. 1, ShadowBox's curve.",
            val: 1,
            from: 0.25,
            to: 4,
            step: 0.05
        }
    ]

    readonly property var backdropParams: [
        {
            label: "enabled",
            prop: "backdropEnabled",
            group: "Backdrop",
            blurb: "The hero card's always-moving background, under its content, reaching the card's true edge under its carve.",
            tip: "Runs the backdrop. Off, the card is the plain carved fill and the popup presents no frame at rest (BACKDROP=0 for the idle measurement).",
            val: true
        },
        {
            label: "running",
            prop: "backdropRunning",
            group: "Backdrop",
            tip: "The host's hand on the backdrop's clock: thePopup sets it false while the popup is closed or hidden, so a hero nobody sees asks for no frame. Off here, the backdrop stands still on its last frame (RUNNING=0 for the perf script's rest arm).",
            val: true
        },
        {
            label: "static layers",
            prop: "staticLayers",
            group: "Backdrop",
            tip: "While the backdrop or the tiles' float ticks, the hourly strip, the daily list and (with the float off) the tile grid are held as textures (rendered once, re-rendered only when their own content changes) so each tick redraws the hero and the moving tiles instead of the whole popup. Dropped at rest. Measured: 3.8 % of a thread and 21 GPU ms/s with everything redrawn per tick at 30 Hz; STATICLAYERS=0 is the A/B.",
            val: true
        },
        {
            label: "strength",
            prop: "backdropStrength",
            group: "Backdrop",
            tip: "Scales every alpha of the effect. 1 is the tuned subtlety (under 12 % luminance change against the card over any 5 px patch, 25 % at a point); the render gate fails above it.",
            val: 1,
            from: 0,
            to: 4,
            step: 0.05
        },
        {
            label: "ambient hz",
            prop: "ambientHz",
            group: "Backdrop",
            tip: "The backdrop's clock: how many frames a second it asks for while running. 30 reads as motion at a cost of half a display's rate; nothing else here animates continuously.",
            val: 30,
            from: 5,
            to: 60,
            step: 1
        },
        {
            label: "tone knee",
            prop: "backdropToneKnee",
            group: "v2 contrast",
            blurb: "The v2 scene's ceilings, so the figures over it keep their contrast.",
            tip: "v2 only. The luminance change against the card that passes unchanged; above it the scene is eased toward the tone cap. 0.07.",
            val: 0.07,
            from: 0,
            to: 0.12,
            step: 0.005
        },
        {
            label: "tone cap",
            prop: "backdropToneCap",
            group: "v2 contrast",
            tip: "v2 only. The ceiling of the scene's luminance change, so the figures over it keep their contrast. 0.11: just under the render gate's 0.12 area bound.",
            val: 0.11,
            from: 0.02,
            to: 0.2,
            step: 0.005
        },
        {
            label: "spark cap",
            prop: "backdropSparkCap",
            group: "v2 contrast",
            tip: "v2 only. The ceiling for point lights (star cores, glints, a flake's bright centre): higher than the tone cap because a point is not read against, and held to the area cap a star is a grey dot. 0.24: under the gate's 0.25 point bound.",
            val: 0.24,
            from: 0.05,
            to: 0.4,
            step: 0.01
        }
    ]

    // ---- The float (modules/common/float): the weather' FloatStyle ---------------------------------------
    readonly property var floatSwayParams: [
        {
            label: "drift min",
            prop: "moveAmpMin",
            group: "Drift",
            blurb: "Every detail tile sways on three oscillators of its own (x, y, rotation), each rolling a new size and speed now and then. The phases are INTEGRATED: speed is speed at any age.",
            tip: "Least swing in px. The theme popup's tuned value; a card must stay well inside its 12 px of gap.",
            val: 1.2,
            from: 0,
            to: 6,
            step: 0.1
        },
        {
            label: "drift max",
            prop: "moveAmpMax",
            group: "Drift",
            tip: "Most swing in px. 3 leaves 9 px of the 12 px gap, and the lift still fits.",
            val: 3,
            from: 0,
            to: 10,
            step: 0.1
        },
        {
            label: "drift speed min",
            prop: "moveFreqMin",
            group: "Drift",
            tip: "Slowest swing, rad/s: 0.5 is one sway in 12.5 s.",
            val: 0.5,
            from: 0.05,
            to: 3,
            step: 0.05
        },
        {
            label: "drift speed max",
            prop: "moveFreqMax",
            group: "Drift",
            tip: "Fastest swing, rad/s: 0.9 is one sway in 7 s, 2.7 px/s at the most: the 20 Hz rest beat moves a card 0.14 px a tick.",
            val: 0.9,
            from: 0.05,
            to: 3,
            step: 0.05
        },
        {
            label: "turn min",
            prop: "rotAmpMin",
            group: "Turn",
            blurb: "The sway's rotation, in the card's own plane.",
            tip: "Least turn in degrees.",
            val: 0.35,
            from: 0,
            to: 3,
            step: 0.05
        },
        {
            label: "turn max",
            prop: "rotAmpMax",
            group: "Turn",
            tip: "Most turn in degrees: 0.8 moves the corners of a 200 px card by 1.4 px.",
            val: 0.8,
            from: 0,
            to: 3,
            step: 0.05
        },
        {
            label: "turn speed min",
            prop: "rotFreqMin",
            group: "Turn",
            tip: "Slowest turn, rad/s.",
            val: 0.4,
            from: 0.05,
            to: 3,
            step: 0.05
        },
        {
            label: "turn speed max",
            prop: "rotFreqMax",
            group: "Turn",
            tip: "Fastest turn, rad/s.",
            val: 1,
            from: 0.05,
            to: 3,
            step: 0.05
        },
        {
            label: "new targets after, min",
            prop: "retargetMin",
            group: "Rolls",
            blurb: "How often an oscillator picks a new size and speed.",
            tip: "Seconds: often enough that the sway never reads as a loop.",
            val: 6,
            from: 1,
            to: 20,
            step: 0.5
        },
        {
            label: "new targets after, max",
            prop: "retargetMax",
            group: "Rolls",
            tip: "Seconds.",
            val: 7,
            from: 1,
            to: 20,
            step: 0.5
        },
        {
            label: "calm",
            prop: "calmMs",
            group: "Calm",
            blurb: "Under a theme switch the tiles stand still (they do not ease: the crossfade is a still picture).",
            tip: "How fast the sway eases to rest when it must hold still, ms. 200 is gone before a dragged card has left its place.",
            val: 200,
            from: 0,
            to: 1000,
            step: 10
        },
        {
            label: "resume",
            prop: "resumeMs",
            group: "Calm",
            tip: "How slowly the sway comes back after it, ms: slower than it went, so the cards wake rather than jump.",
            val: 600,
            from: 0,
            to: 2000,
            step: 10
        }
    ]
    readonly property var floatLeanParams: [
        {
            label: "tilt",
            prop: "tiltMax",
            group: "Tilt",
            blurb: "The detail tile under the pointer leans towards it, on a spring.",
            tip: "Degrees at the card's edge. 9 reads as a card in the hand; text on it stays readable well past that.",
            val: 9,
            from: 0,
            to: 20,
            step: 0.5
        },
        {
            label: "spring",
            prop: "tiltStiffness",
            group: "Tilt",
            tip: "How hard the spring pulls: 140 reaches the pointer in about 200 ms.",
            val: 140,
            from: 20,
            to: 400,
            step: 5
        },
        {
            label: "damping",
            prop: "tiltDamping",
            group: "Tilt",
            tip: "15 at this stiffness is a little under critical: one small overshoot, then still.",
            val: 15,
            from: 4,
            to: 40,
            step: 0.5
        },
        {
            label: "perspective",
            prop: "planeDistance",
            group: "Tilt",
            tip: "The eye's distance in px: smaller is a stronger perspective. 700 is a card held at reading distance.",
            val: 700,
            from: 200,
            to: 2000,
            step: 10
        },
        {
            label: "lift",
            prop: "liftScale",
            group: "Lift",
            blurb: "The pointer on a card: it rises to meet it.",
            tip: "Scale of the card the pointer is on. It must grow past the sway, or the pointer slips off a card's edge: 1.045 is 3-5 px each way.",
            val: 1.045,
            from: 1,
            to: 1.12,
            step: 0.005
        }
    ]
    readonly property var floatDealParams: [
        {
            label: "deal time",
            prop: "dealMs",
            group: "Deal",
            blurb: "As the popup opens, the hero, the strip and the list land first (presence only: they never sway), then the ten tiles.",
            tip: "How long one card takes, OutBack. 440 is about the popup's own opening; 0 turns the deal off.",
            val: 440,
            from: 0,
            to: 1000,
            step: 10
        },
        {
            label: "stagger",
            prop: "dealStaggerMs",
            group: "Deal",
            tip: "Between two cards, in reading order: 35, a little closer than the theme's 45, because thirteen places are dealt here (the three wide cards, then the ten tiles), and the last lands 860 ms after the open.",
            val: 35,
            from: 0,
            to: 150,
            step: 5
        },
        {
            label: "rise",
            prop: "dealRise",
            group: "Deal",
            tip: "How far below its place a card starts, px.",
            val: 16,
            from: 0,
            to: 40,
            step: 1
        },
        {
            label: "turn",
            prop: "dealTurn",
            group: "Deal",
            tip: "How far turned a card starts, degrees, every other one the other way.",
            val: 3.5,
            from: 0,
            to: 12,
            step: 0.5
        }
    ]
    // The wide cards' turn is the popup's own number (the default target), not the FloatStyle's.
    readonly property var floatWideParams: [
        {
            label: "wide turn",
            prop: "wideDealTurn",
            group: "Deal",
            tip: "How far the hero, the strip and the list start turned, degrees. A turn moves a card's corners by half its width times the angle: 0.8 on a 700 px card is about the 3.5 of a tile.",
            val: 0.8,
            from: 0,
            to: 4,
            step: 0.1
        }
    ]

    readonly property var weatherColors: [
        {
            label: "sun disc",
            prop: "weatherSunDisc",
            group: "Glyph colours",
            blurb: "What each carved glyph part is made of, from the user's reference sets: its flat body and, darkened by the glyph shade, its inset. Theme tokens; edits write the theme file.",
            tip: "The sun's disc: a saturated yellow on the orange crown (the references' set 2 and 3). Theme token; edits write the theme file.",
            val: "#FFC634"
        },
        {
            label: "sun crown",
            prop: "weatherSunCrown",
            group: "Glyph colours",
            tip: "The sun's serrated crown: the orange second tone. Theme token.",
            val: "#F7931E"
        },
        {
            label: "moon",
            prop: "weatherMoon",
            group: "Glyph colours",
            tip: "The crescent and the moon-phase disc: a warm gold. At 24 px day and night are told apart by shape; a blue moon would collide with the rain drops. Theme token.",
            val: "#F5AE3A"
        },
        {
            label: "star",
            prop: "weatherStar",
            group: "Glyph colours",
            tip: "The five-pointed stars beside the crescent. Theme token.",
            val: "#FFC634"
        },
        {
            label: "cloud front",
            prop: "weatherCloudFront",
            group: "Glyph colours",
            tip: "The front cloud: near-white, as in every reference (a touch below white in dark mode, so it does not glare next to the text). Theme token.",
            val: "#FCFDFF"
        },
        {
            label: "cloud back",
            prop: "weatherCloudBack",
            group: "Glyph colours",
            tip: "The grey cloud behind the white one (cloudy and heavy skies). Theme token.",
            val: "#B7BDC9"
        },
        {
            label: "drop",
            prop: "weatherDrop",
            group: "Glyph colours",
            tip: "Rain drops and streaks. Theme token.",
            val: "#3D8FF2"
        },
        {
            label: "flake",
            prop: "weatherFlake",
            group: "Glyph colours",
            tip: "Snowflakes: an icy cyan, so a flake beside a drop in sleet reads as a different thing. Theme token.",
            val: "#36BCE6"
        },
        {
            label: "hail",
            prop: "weatherHail",
            group: "Glyph colours",
            tip: "Hail pellets: paler ice than the flakes. Theme token.",
            val: "#86CFEA"
        },
        {
            label: "bolt",
            prop: "weatherBolt",
            group: "Glyph colours",
            tip: "The lightning bolt: an amber, more orange than the sun's disc. Theme token.",
            val: "#FFAA1F"
        },
        {
            label: "fog bar",
            prop: "weatherFogBar",
            group: "Glyph colours",
            tip: "The staggered fog bars. Theme token.",
            val: "#A5ADBC"
        },
        {
            label: "wind line",
            prop: "weatherWindLine",
            group: "Glyph colours",
            tip: "The wind curls, and the carved arrow of the strip's and the list's wind views (and its no-direction dot), the wind tile's rose and the pressure tile's trend. Theme token.",
            val: "#8D9BB0"
        },
        {
            label: "glyph shade",
            prop: "weatherGlyphShade",
            group: "Glyph colours",
            tip: "What a part's colour is MULTIPLIED by at the edge of its inset, one value per mode, tuned so the carve looks equally deep on the light and the dark card (Theme.shadowDeep is near-black in dark mode, and a cloud carved toward it read as a blur). The light value is also what outlines a white cloud against the light card at 24 px: #8A8F99, where round 2's #B2B6BF left a 1 px ring at 1.2:1. Theme token.",
            val: "#8A8F99"
        },
        {
            label: "sun",
            prop: "weatherSun",
            group: "Condition hues",
            blurb: "The weather hues everything but the glyphs reads: the strip's and the list's bars, the detail's charts, the tiles and the backdrop.",
            tip: "The sun's hue: the UV and sunshine bars, the sun and moon detail, the warm end of the temperature gradients, the backdrop's sun. Theme token; edits write the theme file.",
            val: "#DF8E1D"
        },
        {
            label: "cloud",
            prop: "weatherCloud",
            group: "Condition hues",
            tip: "The cloud's hue: the strip's cloud-cover bars, the detail's cloud chart, the backdrop's cloud. Theme token.",
            val: "#7C8AA6"
        },
        {
            label: "rain",
            prop: "weatherRain",
            group: "Condition hues",
            tip: "The rain's hue: precipitation bars in the strip, the list and the tiles, the detail's rain, the cold end of the temperature gradients. Theme token.",
            val: "#1E66F5"
        },
        {
            label: "snow",
            prop: "weatherSnow",
            group: "Condition hues",
            tip: "The snow's hue: snow bars in the strip, the detail's snow, the backdrop's flakes. Theme token.",
            val: "#04A5E5"
        },
        {
            label: "storm",
            prop: "weatherStorm",
            group: "Condition hues",
            tip: "The storm's hue: the detail's thunder, the backdrop's flash. Theme token.",
            val: "#8839EF"
        },
        {
            label: "fog",
            prop: "weatherFog",
            group: "Condition hues",
            tip: "The fog's hue: the detail's fog, the backdrop's fog. Theme token.",
            val: "#9CA0B0"
        },
        {
            label: "night",
            prop: "weatherNight",
            group: "Condition hues",
            tip: "The night's hue: the detail's moon, the backdrop's night sky. Theme token.",
            val: "#7287FD"
        },
        {
            label: "band good",
            prop: "bandGood",
            group: "Scale bands",
            blurb: "The six generic bands every scale is read on (UV, air quality, pollen, wind, the warning chip): a row carries the band index, the delegate resolves the colour.",
            tip: "Band 0, good. Theme token (an alias of the multilib category colour).",
            val: "#00BEC4"
        },
        {
            label: "band fair",
            prop: "bandFair",
            group: "Scale bands",
            tip: "Band 1, fair. Theme token (an alias of ok).",
            val: "#44C145"
        },
        {
            label: "band moderate",
            prop: "bandModerate",
            group: "Scale bands",
            tip: "Band 2, moderate. Theme token (an alias of spill).",
            val: "#D69A00"
        },
        {
            label: "band poor",
            prop: "bandPoor",
            group: "Scale bands",
            tip: "Band 3, poor; also a level-1 KMI warning's chip. Theme token (an alias of warn).",
            val: "#FF6D12"
        },
        {
            label: "band very poor",
            prop: "bandVeryPoor",
            group: "Scale bands",
            tip: "Band 4, very poor; a level-2 warning's chip. Theme token (an alias of error).",
            val: "#EC0000"
        },
        {
            label: "band extreme",
            prop: "bandExtreme",
            group: "Scale bands",
            tip: "Band 5, extreme; a level-3 warning's chip. Theme token (an alias of the flatpak category colour).",
            val: "#C838C6"
        }
    ]
}
