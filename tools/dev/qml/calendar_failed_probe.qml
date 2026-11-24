pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io

import "modules/common/theme"
import "modules/clock/calendar"
import "modules/clock/data"

// =============================================================================
// tools/dev/qml/calendar_failed_probe.qml -- a calendar feed that fails says so in the appointment list (83c0a376).
// The REAL CalendarService (two CalendarFeeds, curl on file:// feeds in a private cache) under the real AppointmentList.
// Runner: tools/dev/calendar_failed_probe.sh (it writes today's two .ics files into $CAL_FEEDS). Prints CF lines and
// "CF RESULT PASS|FAIL". A bare smoke (no CAL_FEEDS) quits at once.
//
//   healthy   both feeds good: no "Could not load" shown, failedFeeds empty, both calendars' rows on show
//   gone      Work's feed vanishes (curl exit 37): "Could not load Work (no connection)" in Theme.warn; Home's row stays
//   unread    Work's feed is empty: "Could not load Work (the feed could not be read)"
//   recovered Work's feed good again: the words go and failedFeeds clears
// =============================================================================
Scope {
    id: root
    readonly property string feeds: Quickshell.env("CAL_FEEDS") ?? ""
    property int fails: 0
    property int checks: 0
    function check(name: string, ok: bool, detail: string): void {
        root.checks++;
        if (!ok)
            root.fails++;
        console.log("CF " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }

    QtObject {
        id: cfg
        readonly property var entries: [
            { id: "home", name: "Home", color: "#40A02B", url: "file://" + root.feeds + "/home.ics", pollIntervalMs: 500 },
            { id: "work", name: "Work", color: "#1E66F5", url: "file://" + root.feeds + "/work.ics", pollIntervalMs: 500 }
        ]
    }

    Window {
        id: win
        visible: root.feeds !== ""
        width: 360
        height: 400
        color: Theme.surface
        CalendarService {
            id: svc
            config: cfg
        }
        AppointmentList {
            id: list
            anchors.fill: parent
            calendarData: svc
            fontFamily: "Inter"
        }
    }

    function find(item: Item, pred: var): var {
        if (pred(item))
            return item;
        for (let i = 0; i < item.children.length; i++) {
            const f = root.find(item.children[i], pred);
            if (f)
                return f;
        }
        return null;
    }
    function failedText(): var {
        return root.find(list, it => it.text !== undefined && String(it.text).indexOf("Could not load") === 0 && it.visible);
    }
    function shown(tag: string): bool {
        return !!root.find(list, it => it.text !== undefined && String(it.text) === tag && it.visible);
    }

    Process {
        id: sh
        property var done: null
        onExited: if (sh.done) sh.done()
    }
    function shell(cmd: string, then: var): void {
        sh.done = then;
        sh.command = ["sh", "-c", cmd];
        sh.running = true;
    }

    // wait for cond() on a live tick count (a Timer is ~3x the wall offscreen), a named failure when it never holds
    property var _cond: null
    property string _what: ""
    property int _ticks: 0
    property var _then: null
    function until(what: string, cond: var, then: var): void {
        root._what = what;
        root._cond = cond;
        root._then = then;
        root._ticks = 0;
        waiter.start();
    }
    Timer {
        id: waiter
        interval: 100
        repeat: true
        onTriggered: {
            root._ticks++;
            let ok = false;
            try {
                ok = root._cond();
            } catch (e) {
                ok = false;
            }
            if (ok) {
                waiter.stop();
                root._then(true);
            } else if (root._ticks > 150) {
                waiter.stop();
                root.check(root._what, false, "never arrived");
                root._then(false);
            }
        }
    }

    function finish(): void {
        console.log("CF RESULT " + (root.fails === 0 && root.checks > 0 ? "PASS" : "FAIL") + " (" + (root.checks - root.fails) + "/" + root.checks + " checks)");
        Qt.quit();
    }

    Timer {
        interval: 100
        running: true
        onTriggered: {
            if (root.feeds === "") {
                Qt.quit();
                return;
            }
            root.healthy();
        }
    }

    function healthy(): void {
        root.until("healthy: both calendars' rows are on show", () => root.shown("Home dentist") && root.shown("Work standup") && svc.events.length >= 2, ok => {
            if (!ok)
                return root.finish();
            root.check("healthy: no failed feed published", svc.failedFeeds.length === 0, JSON.stringify(svc.failedFeeds));
            root.check("healthy: no 'Could not load' words on show", root.failedText() === null, root.failedText() ? root.failedText().text : "");
            root.shell("rm -f '" + root.feeds + "/work.ics'", () => root.gone());
        });
    }
    function gone(): void {
        root.until("gone: the words appear", () => !!root.failedText(), ok => {
            const t = root.failedText();
            root.check("gone: 'Could not load Work (no connection)'", !!t && t.text === "Could not load Work (no connection)", t ? t.text : "none");
            root.check("gone: the words are the theme's warn colour", !!t && Qt.colorEqual(t.color, Theme.warn), t ? String(t.color) : "none");
            root.check("gone: failedFeeds names Work only", svc.failedFeeds.length === 1 && svc.failedFeeds[0].name === "Work", JSON.stringify(svc.failedFeeds));
            root.check("gone: Home's row stays on show", root.shown("Home dentist"), "");
            root.shell(": > '" + root.feeds + "/work.ics'", () => root.unread());
        });
    }
    function unread(): void {
        root.until("unread: the words change to the unreadable form", () => !!root.failedText() && root.failedText().text.indexOf("could not be read") > 0, ok => {
            const t = root.failedText();
            root.check("unread: 'Could not load Work (the feed could not be read)' in warn",
                       !!t && t.text === "Could not load Work (the feed could not be read)" && Qt.colorEqual(t.color, Theme.warn), t ? t.text : "none");
            root.shell("cp '" + root.feeds + "/work.good' '" + root.feeds + "/work.ics'", () => root.recovered());
        });
    }
    function recovered(): void {
        root.until("recovered: the words go", () => root.failedText() === null && svc.failedFeeds.length === 0, ok => {
            root.check("recovered: failedFeeds is empty again", svc.failedFeeds.length === 0, JSON.stringify(svc.failedFeeds));
            root.check("recovered: no words on show", root.failedText() === null, "");
            root.finish();
        });
    }
}
