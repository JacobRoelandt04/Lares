pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/theme"
import "modules/stocks"
import "modules/stocks/data"

// =============================================================================
// tools/dev/qml/stocks_note_probe.qml -- the summary card's note says when the figures on show were fetched, and changes
// WITH them (tools/dev/stocks_note_probe.sh runs it). Prints SN lines and "SN RESULT PASS|FAIL".
//
// feedback/stocks.md "Last fetch time": a faint subtitle like the weather's. The note is taken when the service PUBLISHES
// figures (`updated`), so a fetch that has landed but not been computed yet (a 0 ms timer in the real service) does not
// change it a turn early; a failure (offline, rate limited) publishes nothing and is taken the turn after it is written.
// The mock (StocksMock) is the service; its fields are written by hand in the order the real service writes them.
// =============================================================================
Scope {
    id: root
    property int fails: 0
    property int checks: 0
    function check(name: string, ok: bool, detail: string): void {
        root.checks++;
        if (!ok)
            root.fails++;
        console.log("SN " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }
    function hm(ms: real): string {
        return Qt.formatDateTime(new Date(ms), "HH:mm");
    }

    FloatingWindow {
        id: win
        visible: true
        implicitWidth: 520
        implicitHeight: 700
        color: Theme.surface
        StocksMock {
            id: mock
            dryRun: true
            scenario: "market-open"
        }
        StocksMock {
            id: mock2
            dryRun: true
            scenario: "empty"
        }
        StocksList {
            id: list
            x: 12
            y: 300
            width: 480
            height: implicitHeight
            service: mock2
            rows: 6
        }
        StocksSummaryCard {
            id: card
            x: 12
            y: 12
            width: 480
            height: implicitHeight
            service: mock
        }
    }
    function note(): var {
        for (let i = 0; i < card.children.length; i++)
            if (card.children[i].objectName === "stocksStatus")
                return card.children[i];
        return null;
    }

    Timer {
        interval: 800
        running: true
        onTriggered: root.run()
    }
    property var _late: null
    function run() {
        const n = root.note();
        root.check("the note exists", !!n, "");
        if (!n) {
            console.log("SN RESULT FAIL (no note)");
            Qt.quit();
            return;
        }
        const t0 = mock.fetchedAtMs;
        // 1. fresh: "updated HH:MM", faint
        root.check("fresh reads 'updated <time>'", n.text === "updated " + root.hm(t0), n.text);
        root.check("fresh is faint", Qt.colorEqual(n.color, Theme.textFaint), String(n.color));
        // 2. a fetch lands (the real service's order: offline off, the time, stale off), the figures not yet published
        const t1 = t0 + 7 * 60000;
        mock.offline = false;
        mock.fetchedAtMs = t1;
        mock.stale = false;
        root.check("a landed fetch changes nothing before the figures", n.text === "updated " + root.hm(t0), n.text);
        mock.updated();
        root.check("the figures' publication brings the new time", n.text === "updated " + root.hm(t1), n.text);
        // 3. a cached start: stale, then a live fetch -- the stale word never pairs with the new time, nor fresh with the old
        mock.stale = true;
        mock.fetchedAtMs = t1 - 3600000;
        mock.updated();
        root.check("stale reads 'stale, from <time>' in warn", n.text === "stale, from " + root.hm(t1 - 3600000) && Qt.colorEqual(n.color, Theme.warn), n.text);
        mock.fetchedAtMs = t1;
        mock.stale = false;
        root.check("no 'updated <cached time>' between the fetch and its figures", n.text === "stale, from " + root.hm(t1 - 3600000), n.text);
        mock.updated();
        root.check("then fresh", n.text === "updated " + root.hm(t1), n.text);
        // 4. a failure publishes nothing: offline is told on the next turn, with the time the figures are from
        mock.offline = true;
        mock.stale = true;
        root._late = () => {
            root.check("offline reads 'offline, from <time>' in warn", n.text === "offline, from " + root.hm(t1) && Qt.colorEqual(n.color, Theme.warn), n.text);
            // 5. rate limited: the flag first, the retry after (the real service's order): the note has both
            mock.offline = false;
            mock.rateLimited = true;
            mock.retryAtMs = t1 + 4 * 60000;
            root._late = () => {
                root.check("rate limited reads the retry time", n.text === "rate limited, retry " + root.hm(t1 + 4 * 60000), n.text);
                root.configChecks(n, t1);
            };
            lateTimer.start();
        };
        lateTimer.start();
    }
    // A broken stocks.jsonc says so (2abdc4c1): the summary card's note while a last good portfolio is on show, and the empty list's
    // words in the warn colour; the healthy case shows neither (so a component that always shows them fails).
    function textOf(item: Item, tag: string): var {
        const found = [];
        const walk = it => {
            if (it.text !== undefined && String(it.text).indexOf(tag) === 0)
                found.push(it);
            for (let i = 0; i < it.children.length; i++)
                walk(it.children[i]);
        };
        walk(item);
        return found;
    }
    function configChecks(n, t1): void {
        mock.rateLimited = false;
        mock.retryAtMs = 0;
        mock.offline = false;
        mock.stale = false;
        mock.updated();
        root.check("cfg: healthy note has no config error", n.text === "updated " + root.hm(t1) && n.text.indexOf("stocks.jsonc") < 0, n.text);
        root.check("cfg: healthy empty list has no config error", root.textOf(list, "stocks.jsonc has an error").length === 0, "");
        const hint = root.textOf(list, "No holdings");
        root.check("cfg: healthy empty list says 'No holdings' in faint", hint.length === 1 && Qt.colorEqual(hint[0].color, Theme.textFaint), hint.length ? String(hint[0].color) : "no text");
        mock.configError = "stocks.jsonc line 3, column 9: unexpected token";
        mock2.configError = "stocks.jsonc line 3, column 9: unexpected token";
        root._late = () => {
            root.check("cfg: the card's note says 'stocks.jsonc has an error' in warn", n.text === "stocks.jsonc has an error" && Qt.colorEqual(n.color, Theme.warn), n.text + " " + n.color);
            const e = root.textOf(list, "stocks.jsonc has an error: ");
            root.check("cfg: the empty list says the line, column and reason in warn",
                       e.length === 1 && e[0].text === "stocks.jsonc has an error: line 3, column 9: unexpected token" && Qt.colorEqual(e[0].color, Theme.warn),
                       e.length ? e[0].text + " " + e[0].color : "no text");
            mock.configError = "";
            mock2.configError = "";
            root._late = () => {
                root.check("cfg: fixed file clears the card's note", n.text.indexOf("stocks.jsonc") < 0, n.text);
                root.check("cfg: fixed file clears the list's words", root.textOf(list, "stocks.jsonc has an error").length === 0, "");
                console.log("SN RESULT " + (root.fails === 0 ? "PASS" : "FAIL") + " (" + (root.checks - root.fails) + "/" + root.checks + " checks)");
                Qt.quit();
            };
            lateTimer.start();
        };
        lateTimer.start();
    }
    Timer {
        id: lateTimer
        interval: 50
        onTriggered: root._late()
    }
}
