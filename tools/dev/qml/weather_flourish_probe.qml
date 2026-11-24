pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import QtTest
import Quickshell

import "modules/common/theme"
import "modules/common/glyphs"
import "modules/common/flourish"
import "modules/common/components"
import "modules/weather"
import "modules/weather/data"

// =============================================================================
// weather_flourish_probe.qml -- the weather popup's glyphs flourish when their item is picked (feedback/weather.md): the real
// WeatherPopup on WeatherMock, its detail built from the popup's own secondaryComponent, a QtTest pointer on the WINDOW, live
// clocks. Runner: tools/dev/weather_ink_probe.sh (its popup pass).
//
//   rest      nothing plays and no flourish clock runs before anything is touched
//   hero      the glyph under the pointer plays (an entry, then a motion) and ends at rest
//   hourly    a clicked column plays ITS glyph and still opens the detail; a second column picked mid-play plays TOO and the
//             first runs on to its end (the user: a sweep must not cut the last one short); the pointer coming onto a third
//             column and moving plays it with no click, and resting there plays nothing more
//   daily     a row plays its glyphs under the pointer
//   tile      the moon tile plays the moon under the pointer
//   detail    a day selected plays its chip's glyph, and a chip under the pointer plays; a scrub ALONG the conditions strip
//             plays every slot it lands on, the earlier ones running on; the sun-and-moon card's moon plays under the pointer
//   carved    with the carved set chosen a click plays nothing
//
// PROBE=1 runs it (a bare smoke only loads). Prints `WXFL <check> ok|FAIL ...` and `WXFL RESULT PASS|FAIL`.
// =============================================================================
ShellRoot {
    id: probe

    readonly property bool live: Quickshell.env("PROBE") === "1"
    property int fails: 0
    property int checks: 0
    function check(name: string, ok: bool, detail: string): void {
        probe.checks++;
        if (!ok)
            probe.fails++;
        console.log("WXFL " + name + " " + (ok ? "ok" : "FAIL") + " " + (detail || ""));
    }

    Window {
        id: win
        visible: true
        width: 1700
        height: 800
        color: Theme.surface

        WeatherMock {
            id: mock
        }
        WeatherPopup {
            id: popup
            x: 20
            y: 20
            service: mock
            viewMode: "detailed"
            eagerCards: true
            fontFamily: "Inter"
            backdropRunning: false
            cardFloat: false
            width: implicitWidth
            height: implicitHeight
        }
        Loader {
            id: detailLoader
            x: 1230
            y: 20
            width: 440
            height: 560
            sourceComponent: popup.secondaryComponent
        }
        Binding {
            target: detailLoader.item
            property: "secondaryKey"
            value: popup.secondaryKey
            when: !!detailLoader.item && popup.secondaryKey !== null
        }

        TestCase {
            id: tc
            name: "wxflourish"
            when: false
        }
    }

    readonly property Item detail: detailLoader.item as Item
    function centre(item: Item): point {
        const p = item.mapToItem(win.contentItem, item.width / 2, item.height / 2);
        return Qt.point(Math.round(p.x), Math.round(p.y));
    }
    function park(): void {
        tc.mouseMove(win.contentItem, win.width - 3, win.height - 3);
    }
    // onto an item as a person arrives: an entry, then a motion
    function hover(item: Item): void {
        const p = probe.centre(item);
        tc.mouseMove(win.contentItem, p.x - 3, p.y);
        tc.mouseMove(win.contentItem, p.x, p.y);
        tc.mouseMove(win.contentItem, p.x + 2, p.y);
    }
    function click(item: Item): void {
        const p = probe.centre(item);
        tc.mouseMove(win.contentItem, p.x - 2, p.y);
        tc.mouseClick(win.contentItem, p.x, p.y);
    }
    // the flourishes of the popup and its detail that play now (every one registers itself)
    function playing(): var {
        return FlourishRegistry.entries.filter(e => e.playing && e.group === "");
    }
    function column(i: int): Item {
        const c = popup.hourlyStrip._cols[i];
        return popup.hourlyStrip.columnItem(c.dayIndex, c.hour);
    }
    function tile(title: string): Item {
        const kids = popup.tileGrid.children;
        for (let i = 0; i < kids.length; ++i) {
            if (kids[i].title === title) // qmllint disable missing-property
                return kids[i];
        }
        return null;
    }
    // the conditions strip's flourish (the detail's "glyphs" item)
    function slotFlourish(): var {
        const find = it => {
            if (it.objectName === "glyphs")
                return it;
            for (let i = 0; i < it.children.length; ++i) {
                const f = find(it.children[i]);
                if (f)
                    return f;
            }
            return null;
        };
        const strip = find(probe.detail);
        return strip ? strip.slotFlourish : null; // qmllint disable missing-property
    }
    function slotRuns(): var {
        const fl = probe.slotFlourish();
        return fl ? fl.runs : ({});
    }
    function slotOn(k): bool {
        const fl = probe.slotFlourish();
        return !!fl && fl.on(k);
    }
    function moonArea(): Item {
        const e = FlourishRegistry.entries.find(f => f.hoverArea && f.hoverArea.parent && f.hoverArea.parent.kind === "moon"); // qmllint disable missing-property
        return e ? e.hoverArea : null;
    }

    // ---- the script: steps, each returning how long to wait before the next ----
    property int _i: -1
    function next(): void {
        probe._i++;
        if (probe._i >= probe.script.length) {
            console.log("WXFL RESULT " + (probe.fails === 0 && probe.checks > 0 ? "PASS" : "FAIL") + " (" + (probe.checks - probe.fails) + "/" + probe.checks + " checks)");
            Qt.quit();
            return;
        }
        let wait = 0;
        try {
            wait = probe.script[probe._i]() || 0;
        } catch (err) {
            probe.check("step " + probe._i + " ran", false, String(err));
        }
        stepTimer.interval = Math.max(1, wait);
        stepTimer.restart();
    }
    Timer {
        id: stepTimer
        onTriggered: probe.next()
    }
    readonly property int quiet: 2600        // longer than any flourish (fog: two beats)

    readonly property var script: [
        () => {
            probe.park();
            return 1500;
        },
        () => {
            const fls = FlourishRegistry.entries.filter(e => e.group === "");
            probe.check("rest", fls.length >= 5 && probe.playing().length === 0 && fls.filter(e => e._run.running).length === 0,
                        "flourishes " + fls.length + " playing " + probe.playing().length);
            probe.hover(popup.hero.glyphFlourish.hoverArea);
            return 150;
        },
        () => {
            const fl = popup.hero.glyphFlourish;
            probe.check("hero", fl.playing && fl.t > 0 && fl.why === "hover", "playing=" + fl.playing + " t " + Math.round(fl.t) + " ms " + fl.ms);
            probe.park();
            return probe.quiet;
        },
        () => {
            probe.check("hero_ends", probe.playing().length === 0, "playing " + probe.playing().length);
            probe.click(probe.column(3));
            return 150;
        },
        () => {
            const fl = popup.hourlyStrip.glyphFlourish;
            probe.check("hourly", fl.on(3) && fl.beatOf(3) > 0 && !fl.on(4) && popup.secondaryOpen && popup.secondaryKey.from === "hourly",
                        "on(3)=" + fl.on(3) + " beat " + fl.beatOf(3).toFixed(2) + " open=" + popup.secondaryOpen);
            probe.click(probe.column(5));
            return 100;
        },
        () => {
            const fl = popup.hourlyStrip.glyphFlourish;
            // the first runs on beside the second, further along (the detail follows a pick with its own: that hour's slot, a new day's chip)
            probe.check("hourly_both", fl.on(3) && fl.on(5) && fl.beatOf(3) > fl.beatOf(5) && fl.beatOf(5) > 0,
                        "on(3)=" + fl.on(3) + " " + fl.beatOf(3).toFixed(2) + " on(5)=" + fl.on(5) + " " + fl.beatOf(5).toFixed(2));
            return probe.quiet;
        },
        () => {
            probe.check("hourly_ends", probe.playing().length === 0, "playing " + probe.playing().length);
            // no click: the pointer comes onto a column and moves
            probe.park();
            probe.hover(probe.column(7));
            return 150;
        },
        () => {
            const fl = popup.hourlyStrip.glyphFlourish;
            probe.check("hourly_hover", fl.on(7) && fl.beatOf(7) > 0, "on(7)=" + fl.on(7));
            return probe.quiet;
        },
        () => {
            // resting on it, then moving inside it: the entry is spent
            const p = probe.centre(probe.column(7));
            tc.mouseMove(win.contentItem, p.x + 4, p.y + 3);
            return 150;
        },
        () => {
            probe.check("hourly_once", probe.playing().length === 0, "playing " + probe.playing().length);
            probe.park();
            probe.hover(popup.dailyList.rowItem(2));
            return 150;
        },
        () => {
            const fl = popup.dailyList.glyphFlourish;
            probe.check("daily", fl.on(2) && fl.beatOf(2) > 0, "on(2)=" + fl.on(2));
            probe.park();
            return probe.quiet;
        },
        () => {
            probe.hover(probe.tile("Moon"));
            return 150;
        },
        () => {
            const fl = popup.tileGrid.glyphFlourish;
            probe.check("tile", fl.on("moon") && popup.secondaryKey.from !== "tile", "on(moon)=" + fl.on("moon"));
            probe.click(probe.tile("Moon"));
            return probe.quiet;
        },
        () => {
            // the detail shows the sun and the moon now (the tile's key): its moon under the pointer
            const a = probe.moonArea();
            probe.check("detail_moon_there", !!a && a.visible, "key " + JSON.stringify(popup.secondaryKey));
            if (a)
                probe.hover(a);
            return 150;
        },
        () => {
            const p = probe.playing();
            probe.check("detail_moon", p.length === 1 && p[0].why === "hover" && !!p[0].hoverArea, "playing " + p.length);
            probe.park();
            return probe.quiet;
        },
        () => {
            // the conditions (the hero's glyph is their link): a day picked, then a slot scrubbed
            probe.click(popup.hero.glyphFlourish.hoverArea);
            return probe.quiet;
        },
        () => {
            probe.check("detail_conditions", popup.secondaryOpen && popup.secondaryKey.metric === "conditions" && probe.playing().length === 0,
                        "key " + JSON.stringify(popup.secondaryKey) + " playing " + probe.playing().length);
            probe.detail.selectDay(2); // qmllint disable missing-property
            return 150;
        },
        () => {
            const fl = probe.detail.chipFlourish; // qmllint disable missing-property
            probe.check("detail_day", fl.on(2) && !fl.on(1), "on(2)=" + fl.on(2));
            return probe.quiet;
        },
        () => {
            // a scrub along the strip: three slots one after the other (two hours a slot), then off it
            probe.detail._hover = 8; // qmllint disable missing-property
            return 120;
        },
        () => {
            probe.detail._hover = 10; // qmllint disable missing-property
            return 120;
        },
        () => {
            probe.detail._hover = 12; // qmllint disable missing-property
            return 120;
        },
        () => {
            probe.detail._hover = -1; // qmllint disable missing-property
            return 100;
        },
        () => {
            const p = probe.playing();
            const fl = p.length === 1 ? p[0] : null;
            const runs = fl ? Object.keys(FlourishRegistry.entries.length ? probe.slotRuns() : {}) : [];
            probe.check("detail_sweep", p.length === 1 && runs.length === 3 && runs.every(k => probe.slotOn(k)),
                        "playing " + p.length + " runs " + runs.join(",") + " on " + runs.map(k => probe.slotOn(k)).join(","));
            return probe.quiet;
        },
        () => {
            WeatherGlyphSet.set = "carved";
            return 300;
        },
        () => {
            probe.click(probe.column(4));
            return 150;
        },
        () => {
            probe.check("carved", probe.playing().length === 0 && popup.secondaryOpen, "playing " + probe.playing().length);
            WeatherGlyphSet.set = "ink";
            return 100;
        }
    ]

    Timer {
        interval: 1200
        running: true
        onTriggered: {
            if (!probe.live) {
                Qt.quit();
                return;
            }
            WeatherGlyphSet.set = "ink";
            probe.next();
        }
    }
}
