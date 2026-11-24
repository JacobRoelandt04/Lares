pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Quickshell registers the types reachable from the ROOT file's imports.
// qmllint disable unused-imports
import "modules/common/theme"
import "modules/common/components"
import "modules/common/system"
import "modules/common/notify"
import "modules/notifications/data"
import "modules/notifications/parts"
import "modules/notifications/sources"
import "modules/notifications/sources/SuddenMove.js" as Sudden
import "modules/notifications/sources/SourceGlyphs.js" as G
import "modules/notifications/sources/SourceSettings.js" as Settings
import "modules/stocks/data"
import "tools/dev/fixtures/stock_notif/cases.js" as Cases
// qmllint enable unused-imports

// =============================================================================
// stock_notif_probe.qml -- the stocks cards' graph, on the real parts: the REAL StocksNotifier (a stub host, a fake `stocks` whose
// quotes are the fixtures' days and whose fineSpark waits for the probe), the REAL NotificationService and NotificationCard (a
// card's `d` follows the store as ToastEntry does), the real StocksViewModel.notifyAlerts through a DesktopNotifier on the bus.
// Run by tools/dev/stock_notif_probe.sh. One line per check: `STOCKN PASS|FAIL <id> <name>`, then `STOCKN RESULT PASS|FAIL`.
//
//   S1 the card carries the WHOLE day (every bar and the live price), not the window       S2 x follows TIME (unequal gaps, unequal x gaps)
//   S3 the previous close stands inside the box where the day moved away from it           S4 a 3 % and a 12 % move differ in drawn height
//   S5 a card 9 minutes after the open ends well left of the right edge (1 h axis)         S6 the labels never overlap nor leave the box
//   S7 the fine answer re-feeds the LOADED body (same item, more points in the span)       S8 a failed / empty fetch leaves the card as born
//   S9 each alert kind posts the body with its level and glyph                              S10 other rich bodies get their props once; an identical re-feed writes nothing
// =============================================================================
ShellRoot {
    id: root

    readonly property string caseDir: Quickshell.env("CASE_DIR") || ""
    readonly property real baseMs: new Date(2026, 10, 18, 9, 30).getTime()
    property real nowMs: 0
    property int fails: 0
    property int checks: 0
    function check(id, name, ok, detail) {
        root.checks++;
        if (!ok)
            root.fails++;
        console.log("STOCKN " + (ok ? "PASS " : "FAIL ") + id + " " + name + (ok ? "" : "  -- " + detail));
    }

    FocusedScreen {
        id: focusSrc
        live: false
    }
    NotificationService {
        id: svc
        serverEnabled: false
        registerOnBus: true
        persist: false
        liveSignals: false
        ipcEnabled: false
        configPath: ""
        focusSource: focusSrc
    }
    NotificationStyle {
        id: nstyle
    }
    Component {
        id: fileView
        FileView {
            blockLoading: true
            printErrors: false
        }
    }
    Component {
        id: bodyComp
        StockMoveBody {}
    }

    // ---- the fake stocks service ----------------------------------------------------------------
    QtObject {
        id: fake
        property var quotes: ({})
        property var config: ({ holdings: [], sudden: { pct: 3, minutes: 30 } })
        property var portfolio: null
        property var watchlist: []
        property bool popupOpen: false
        property var asks: []
        signal updated
        signal alertOpenRequested(string symbol)
        function fineSpark(sym, cb) {
            fake.asks.push({ sym: sym, cb: cb });
        }
    }
    QtObject {
        id: stubHost
        property bool live: true
        function allows(id) { return true; }
        function settingsOf(id) { return Settings.defaults()[id]; }
        function register(s) {}
        function unregister(s) {}
        function open(what) {}
        function run(argv) {}
        property var state: ({ get: k => ({ latches: {} }), put: (k, v) => {} })
    }
    StocksNotifier {
        id: notifier
        host: stubHost
        stocks: fake
        nowFn: function () { return root.nowMs; }
    }
    DesktopNotifier {
        id: alertNotifier
        appName: "Stocks"
        keys: ["stocks-alert-0", "stocks-alert-1", "stocks-alert-2", "stocks-alert-3"]
    }
    StocksViewModel {
        id: vm
    }

    // ---- helpers ------------------------------------------------------------------------------------
    function load(name) {
        const fv = fileView.createObject(root, { path: root.caseDir + "/" + name + ".json" });
        const t = fv.text();
        fv.destroy();
        return JSON.parse(t);
    }
    function recOf(prefix) {
        const all = svc.store.all();
        for (let i = all.length - 1; i >= 0; i--)
            if (String(all[i].summary).indexOf(prefix) === 0)
                return all[i];
        return null;
    }
    function walk(it, pred, out) {
        if (pred(it))
            out.push(it);
        for (let i = 0; i < it.children.length; i++)
            root.walk(it.children[i], pred, out);
        return out;
    }
    function bodyOf(wrapper) {
        const r = root.walk(wrapper, it => "facts" in it && "labelSize" in it, []);
        return r.length ? r[0] : null;
    }
    function sparkOf(body) {
        const r = root.walk(body, it => "_placed" in it && "rangeMinSpan" in it, []);
        return r.length ? r[0] : null;
    }
    function textsOf(body) {
        return body.children.filter(it => "elide" in it && typeof it.text === "string");
    }

    property var wrappers: []
    Component {
        id: cardComp
        Item {
            id: w
            property string uid: ""
            property alias card: c
            width: 400
            height: c.implicitHeight
            NotificationCard {
                id: c
                x: 20
                width: 360
                d: svc.store.get(w.uid)
                service: svc
                style: nstyle // qmllint disable incompatible-type
                cardWidth: 360
            }
            Connections {
                target: svc
                function onSerialChanged() { c.d = svc.store.get(w.uid); }
            }
        }
    }
    function cardFor(rec) {
        const w = cardComp.createObject(host, { uid: rec.uid });
        root.wrappers.push(w);
        return w;
    }

    FloatingWindow {
        id: win
        implicitWidth: 420
        implicitHeight: 900
        visible: true
        color: Theme.surface
        Column {
            id: host
        }
    }

    // ---- the run -------------------------------------------------------------------------------------
    property var cases: ({})
    property var quotes: ({})
    property var recs: ({})
    property var bodies: ({})
    property var born: ({})

    function say(name, c) {
        const q = Cases.quoteOf(c, root.baseMs);
        root.quotes[name] = q;
        root.cases[name] = c;
        root.nowMs = q.timeMs;
        fake.config = { holdings: [{ symbol: c.symbol, label: c.label }], sudden: { pct: c.pct || 3, minutes: c.minutes || 30 } };
        const m = {};
        m[c.symbol] = q;
        fake.quotes = m;
        fake.updated();
    }

    property var steps: []
    property int stepAt: 0
    function step() {
        if (root.stepAt >= root.steps.length) {
            console.log("STOCKN RESULT " + (root.fails === 0 ? "PASS" : "FAIL") + " (" + (root.checks - root.fails) + "/" + root.checks + " checks)");
            Qt.quit();
            return;
        }
        const f = root.steps[root.stepAt++];
        try {
            f();
        } catch (e) {
            root.check("X", "a step threw", false, e + " at step " + (root.stepAt - 1));
        }
        tick.restart();
    }

    readonly property var suddenNames: ["a_drop_late", "b_jump_morning", "c_jump_after_open", "d_thin_gaps"]
    readonly property var alertNames: ["e_above", "f_below", "g_daymove"]

    Component.onCompleted: {
        root.steps = [
            // 1: every sudden case says it, then its card
            () => {
                for (const n of root.suddenNames)
                    root.say(n, root.load(n));
            },
            () => {
                for (const n of root.suddenNames) {
                    const c = root.cases[n];
                    const rec = root.recOf(c.label + " ");
                    root.recs[n] = rec;
                    if (rec)
                        root.bodies[n] = root.cardFor(rec);
                }
            },
            () => {
                for (const n of root.suddenNames) {
                    root.bodies[n] = root.bodyOf(root.bodies[n]);
                    root.born[n] = root.bodies[n] ? root.bodies[n].facts : null;
                }
            },
            root.checkWholeDay,
            root.checkTime,
            root.checkBox,
            root.checkSpan,
            root.checkLabels,
            root.checkRefeed,
            root.checkFailed,
            root.checkAlerts,
            root.checkOthers,
            root.finish,
            root.finish2,
            root.finish3
        ];
        tick.start();
    }
    Timer {
        id: tick
        interval: 150
        onTriggered: root.step()
    }
    Timer {
        interval: 90000
        running: true
        onTriggered: {
            console.log("STOCKN RESULT FAIL (timeout)");
            Qt.quit();
        }
    }

    // S1
    function checkWholeDay() {
        let ok = true, why = "";
        for (const n of root.suddenNames) {
            const q = root.quotes[n], rec = root.recs[n];
            const props = rec ? svc.richBodyOf(rec.uid) : null;
            const f = props && props.props ? props.props.facts : null;
            const want = q.spark.t.length + 1;
            const b = root.bodies[n];
            if (!f || f.t.length !== want || f.t[0] !== q.spark.t[0] || f.c[f.c.length - 1] !== q.price || !b || !b.facts || b.facts.t.length !== want) {
                ok = false;
                why += n + ": posted " + (f ? f.t.length : "none") + " points, drawn " + (b && b.facts ? b.facts.t.length : "none") + ", day " + want + "; ";
            }
        }
        root.check("S1", "the card carries the whole day, not the window", ok, why);
    }
    // S2: x follows time
    function checkTime() {
        const b = root.bodies["d_thin_gaps"], sp = b ? root.sparkOf(b) : null;
        const run = sp && sp._placed.length ? sp._placed[0] : [];
        let rates = [], minDt = Infinity, maxDt = 0, dxAtMin = 0, dxAtMax = 0;
        for (let i = 1; i < run.length; i++) {
            const dt = run[i].k - run[i - 1].k, dx = run[i].x - run[i - 1].x;
            rates.push(dx / dt);
            if (dt < minDt) { minDt = dt; dxAtMin = dx; }
            if (dt > maxDt) { maxDt = dt; dxAtMax = dx; }
        }
        const r0 = rates.length ? rates[0] : 1;
        const constant = rates.length > 3 && rates.every(r => Math.abs(r - r0) <= Math.abs(r0) * 1e-6);
        const unequal = maxDt >= 3 * minDt && dxAtMax >= 2.5 * dxAtMin;
        root.check("S2", "drawn x follows time: unequal time gaps give unequal x gaps", constant && unequal,
                   run.length + " points, rates equal " + constant + ", dt " + minDt + ".." + maxDt + " dx " + dxAtMin + ".." + dxAtMax);
    }
    // S3: the previous close inside the box where the day moved away from it (the cards of the fixtures, and a day that jumped 12 %,
    // past the least span, where the baseline is the range's own extreme)
    function checkBox() {
        let ok = true, why = "";
        const bodies = [["b_jump_morning", root.bodies["b_jump_morning"]], ["c_jump_after_open", root.bodies["c_jump_after_open"]]];
        const c = root.flatDay(112), q = Cases.quoteOf(c, root.baseMs);
        const big = bodyComp.createObject(host, { width: 284, facts: Sudden.facts(q, Sudden.evaluate(q, { pct: 3, minutes: 30 }, q.timeMs).up, { pct: 3, minutes: 30 }, q.timeMs) });
        bodies.push(["jump12", big]);
        for (const [n, b] of bodies) {
            const sp = b ? root.sparkOf(b) : null;
            if (!sp) { ok = false; why += n + ": no chart; "; continue; }
            const y = sp._baseY;
            if (!(y > 3 && y < sp.height - 3)) { ok = false; why += n + ": baseline at " + y + " of " + sp.height + "; "; }
        }
        big.destroy();
        root.check("S3", "the previous-close line stands inside the box where the day moved away from it", ok, why);
    }
    // S4 + S5
    function flatDay(jumpTo) {
        const c = { symbol: "FLAT", label: "FLAT", currency: "USD", priceHint: 2, prevClose: 100, nowMin: 120, live: jumpTo, kind: "sudden",
                    bars: [] };
        for (let m = 0; m <= 110; m += 5)
            c.bars.push([m, 100 + 0.05 * Math.sin(m)]);
        return c;
    }
    function spanHeight(jumpTo) {
        const c = root.flatDay(jumpTo), q = Cases.quoteOf(c, root.baseMs), now = q.timeMs;
        const mv = Sudden.evaluate(q, { pct: 3, minutes: 30 }, now);
        const m = mv.up;
        if (!m)
            return -1;
        const f = Sudden.facts(q, m, { pct: 3, minutes: 30 }, now);
        const b = bodyComp.createObject(host, { width: 284, facts: f });
        const sp = root.sparkOf(b);
        let lo = Infinity, hi = -Infinity;
        for (const run of sp._emphRuns)
            for (const p of run) { lo = Math.min(lo, p.y); hi = Math.max(hi, p.y); }
        b.destroy();
        return hi - lo;
    }
    function checkSpan() {
        const h3 = root.spanHeight(103.2), h12 = root.spanHeight(112);
        root.check("S4", "a 3 % and a 12 % move differ in drawn height (a small move looks small)", h3 > 0 && h12 > 0 && h12 / h3 >= 1.6,
                   "3 %: " + h3 + " px, 12 %: " + h12 + " px");
        const b = root.bodies["c_jump_after_open"], sp = b ? root.sparkOf(b) : null;
        root.check("S5", "9 minutes after the open the line ends well left of the right edge (1 h axis)", !!sp && !!sp._last && sp._last.x < 0.3 * sp.width,
                   sp && sp._last ? "last x " + sp._last.x + " of " + sp.width : "no line");
    }
    // S6
    function labelProblems(b, tag) {
        const t = root.textsOf(b);
        if (t.length !== 2)
            return tag + ": " + t.length + " labels; ";
        const l = t[0], r = t[1];
        let why = "";
        if (l.x < 0 || r.x + r.width > b.width + 0.001 || l.x + l.width > b.width + 0.001) why += tag + ": leaves the box (" + l.x + "+" + l.width + ", " + r.x + "+" + r.width + " of " + b.width + "); ";
        if (l.x + l.width + 4 > r.x) why += tag + ": overlap (" + (l.x + l.width) + " vs " + r.x + "); ";
        if (l.x !== Math.round(l.x) || r.x !== Math.round(r.x) || l.y !== Math.round(l.y)) why += tag + ": off the pixel grid; ";
        return why;
    }
    function checkLabels() {
        let why = "";
        for (const n of root.suddenNames)
            if (root.bodies[n])
                why += root.labelProblems(root.bodies[n], n);
        // every case's facts at several widths, standalone
        const all = [];
        for (const n of root.suddenNames) {
            const c = root.cases[n], q = root.quotes[n];
            const mv = Sudden.evaluate(q, { pct: 3, minutes: 30 }, q.timeMs);
            all.push([n, Sudden.facts(q, mv.up || mv.down, { pct: 3, minutes: 30 }, q.timeMs)]);
        }
        for (const n of root.alertNames) {
            const c = root.load(n), q = Cases.quoteOf(c, root.baseMs);
            all.push([n, Sudden.facts(q, null, null, q.timeMs, { kind: c.kind, level: c.level })]);
        }
        for (const [n, f] of all)
            for (const w of [284, 220, 160, 110]) {
                const b = bodyComp.createObject(host, { width: w, facts: f });
                why += root.labelProblems(b, n + "@" + w);
                b.destroy();
            }
        root.check("S6", "the time labels never overlap and never leave the box (4 cases and 3 alerts, 4 widths)", why === "", why);
    }
    // S7
    function checkRefeed() {
        const n = "a_drop_late", b = root.bodies[n], rec = root.recs[n];
        const ask = fake.asks.filter(a => a.sym === root.cases[n].symbol)[0];
        if (!b || !ask) {
            root.check("S7", "the fine answer re-feeds the loaded body", false, "no body or no fineSpark ask (asks " + fake.asks.length + ")");
            return;
        }
        b.objectName = "marker";
        const before = b.facts, sp = root.sparkOf(b);
        const inSpan = () => root.sparkOf(b)._placed.reduce((s, run) => s + run.filter(p => p.k >= before.fromMs && p.k <= before.toMs).length, 0);
        const nBefore = inSpan();
        const q = root.quotes[n];
        ask.cb(Cases.fineOf(q, before.fromMs, before.toMs));
        root.refeed = { n: n, b: b, before: before, nBefore: nBefore, rec: rec };
        // the check lands one step later: the card pulls the new record on the service's serial
    }
    property var refeed: null
    function checkRefeed2() {
        const r = root.refeed;
        const w = root.wrappers[root.suddenNames.indexOf(r.n)];
        const now = root.bodyOf(w);
        const nAfter = root.sparkOf(r.b)._placed.reduce((s, run) => s + run.filter(p => p.k >= r.before.fromMs && p.k <= r.before.toMs).length, 0);
        root.check("S7", "the fine answer re-feeds the LOADED body (the same item, more points inside the span)",
                   now === r.b && r.b.objectName === "marker" && r.b.facts !== r.before && nAfter > r.nBefore + 10 && r.b.facts.fromMs === r.before.fromMs,
                   "same item " + (now === r.b) + ", facts replaced " + (r.b.facts !== r.before) + ", points in span " + r.nBefore + " -> " + nAfter);
    }
    // S8
    function checkFailed() {
        root.checkRefeed2();
        const n = "b_jump_morning", b = root.bodies[n], rec = root.recs[n];
        const ask = fake.asks.filter(a => a.sym === root.cases[n].symbol)[0];
        const before = b.facts, props = svc.richBodyOf(rec.uid).props.facts;
        ask.cb(null);
        const n2 = "d_thin_gaps";
        const ask2 = fake.asks.filter(a => a.sym === root.cases[n2].symbol)[0];
        const before2 = root.bodies[n2].facts;
        ask2.cb({ t: [], c: [] });
        root.failed = { b: b, before: before, props: props, rec: rec, b2: root.bodies[n2], before2: before2 };
    }
    property var failed: null
    function checkAlerts() {
        const f = root.failed;
        root.check("S8", "a failed or empty fine fetch leaves the card as it was born", f.b.facts === f.before && svc.richBodyOf(f.rec.uid).props.facts === f.props
                   && f.b2.facts === f.before2, "facts replaced");
        // the alerts, through the real notifyAlerts and a DesktopNotifier on the bus
        let why = "";
        const out = [];
        for (const n of root.alertNames) {
            const c = root.load(n), q = Cases.quoteOf(c, root.baseMs);
            root.nowMs = q.timeMs;
            const fire = [{ index: 0, symbol: c.symbol, kind: c.kind, level: c.level, price: c.live, changePct: q.changePct }];
            const qs = {};
            qs[c.symbol] = q;
            vm.notifyAlerts(fire, qs, alertNotifier, { body: bodyComp, nowMs: q.timeMs, label: s => c.label });
            out.push({ n: n, c: c, q: q });
        }
        root.alertCases = out;
    }
    property var alertCases: []
    function checkAlerts2() {
        let why = "";
        for (const a of root.alertCases) {
            const rec = root.recOf(a.c.label + " ");
            const rich = rec ? svc.richBodyOf(rec.uid) : null;
            const f = rich && rich.props ? rich.props.facts : null;
            const up = a.c.kind === "above" || (a.c.kind === "dayMove" && a.q.changePct >= 0);
            if (!f || f.kind !== a.c.kind || f.t.length !== a.c.bars.length + 1
                || (a.c.kind === "dayMove" ? f.level !== null : f.level !== a.c.level)
                || rec.appIcon !== (up ? G.stocksUp : G.stocksDown))
                why += a.n + ": " + (f ? "kind " + f.kind + " level " + f.level + " points " + f.t.length + " icon " + (rec ? rec.appIcon.length : "") : "no rich body") + "; ";
            else
                root.alertCards.push({ n: a.n, w: root.cardFor(rec) });
        }
        root.alertWhy = why;
    }
    property var alertCards: []
    property string alertWhy: ""
    function checkAlerts3() {
        let why = root.alertWhy;
        for (const c of root.alertCards)
            if (!root.bodyOf(c.w))
                why += c.n + ": the card draws no body; ";
        root.check("S9", "each alert kind (above, below, dayMove) posts the body with its level, the whole day and its glyph", why === "" && root.alertCards.length === 3, why);
    }
    // S10
    Component {
        id: countComp
        Item {
            property var chips: []
            property int writes: 0
            onChipsChanged: writes++
            implicitHeight: 10
        }
    }
    property var counted: null
    function checkOthers() {
        root.checkAlerts2();
        const lines = ["one", "two", "three"];
        const chips = [{ key: "core", label: "core", count: 2 }];
        const logUid = svc.post({ source: "units", key: "log", title: "A unit failed", body: "x", bodyComponent: logComp, bodyProps: { lines: lines } });
        const cUid = svc.post({ source: "units", key: "count", title: "Counted", body: "x", bodyComponent: countComp, bodyProps: { chips: chips } });
        root.counted = { log: root.cardFor(svc.store.get(logUid)), cnt: root.cardFor(svc.store.get(cUid)), logUid: logUid, cUid: cUid, chips: chips };
    }
    Component {
        id: logComp
        LogTailBody {}
    }
    function finish() {
        const o = root.counted;
        const log = root.walk(o.log, it => "lines" in it && "_boxH" in it, [])[0];
        const cnt = root.walk(o.cnt, it => "writes" in it, [])[0];
        const w1 = cnt ? cnt.writes : -1;
        svc.update(o.cUid, { body: "y" });                              // a change of the record, no new props
        svc.update(o.cUid, { title: "Counted again" });
        root.after = { log: log, cnt: cnt, w1: w1 };
    }
    property var after: null
    function finish2() {
        const a = root.after, o = root.counted;
        const w2 = a.cnt ? a.cnt.writes : -1;
        const next = [{ key: "aur", label: "aur", count: 5 }];
        svc.update(o.cUid, { bodyProps: { chips: next } });
        root.after.w2 = w2;
        root.after.next = next;
    }
    function finish3() {
        root.checkAlerts3();
        const a = root.after;
        root.check("S10", "other rich bodies: props applied at load (once per change signal of the item), a change of another field writes nothing, new props are written",
                   !!a.log && a.log.lines.length === 3 && a.w1 >= 1 && a.w2 === a.w1 && a.cnt.writes > a.w2 && a.cnt.chips === a.next,
                   "log lines " + (a.log ? a.log.lines.length : "none") + ", writes at load " + a.w1 + ", after other changes " + a.w2 + ", after a new one " + (a.cnt ? a.cnt.writes : -1));
    }
    Component.onDestruction: {}
}
