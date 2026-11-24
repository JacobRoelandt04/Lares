pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Quickshell registers the types reachable from the ROOT file's imports.
// qmllint disable unused-imports
import "modules/common/theme"
import "modules/common/components"
import "modules/common/system"
import "modules/notifications/data"
import "modules/notifications/parts"
import "modules/notifications/sources"
import "modules/notifications/sources/SuddenMove.js" as Sudden
import "modules/notifications/sources/SourceGlyphs.js" as G
import "modules/stocks/data/StocksFormat.js" as Fmt
import "tools/dev/fixtures/stock_notif/cases.js" as Cases
// qmllint enable unused-imports

// =============================================================================
// stock_notif_sheet.qml -- the stocks cards as the user sees them: the REAL NotificationCard (a toast's 360 px) on the real
// NotificationService, one PNG per cell, the new body (StockMoveBody) for the four sudden-move cases and the three alert kinds, and
// the OLD body (SuddenMoveBody of 80434cc4, fed the window values it was) for the four sudden cases. tools/dev/stock_notif_sheet.sh
// composes the cells into the labelled sheet. It runs from the config's ROOT (the runner copies it there in its sandbox copy): the
// relative imports of the scripts are the root's.
//   OUT_DIR   where the cells go (<name>.png) -- required       CASE_DIR   the fixtures       OLD_BODY   the old body's file ("" none)
// Prints `STOCK_NOTIF_SHEET cell <name>` per grab and `STOCK_NOTIF_SHEET RESULT PASS|FAIL`.
// =============================================================================
ShellRoot {
    id: root

    readonly property string outDir: Quickshell.env("OUT_DIR") || ""
    readonly property string caseDir: Quickshell.env("CASE_DIR") || ""
    readonly property string oldBody: Quickshell.env("OLD_BODY") || ""
    // 09:30 on a Wednesday, local: the labels read like a real day
    readonly property real baseMs: new Date(2026, 10, 18, 9, 30).getTime()
    readonly property var names: ["a_drop_late", "b_jump_morning", "c_jump_after_open", "d_thin_gaps", "e_above", "f_below", "g_daymove"]
    property var cells: []
    property int fails: 0

    FocusedScreen {
        id: focusSrc
        live: false
    }
    NotificationService {
        id: svc
        serverEnabled: false
        registerOnBus: false
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
        id: newBody
        StockMoveBody {}
    }
    property var oldComp: null

    function load(name) {
        const fv = fileView.createObject(root, { path: root.caseDir + "/" + name + ".json" });
        const t = fv.text();
        fv.destroy();
        return JSON.parse(t);
    }

    function post(tag, c, q, comp, props, title, body, up) {
        const uid = svc.post({ source: "sheet", key: tag, appName: "Stocks", icon: up ? G.stocksUp : G.stocksDown, title: title, body: body,
                               urgency: "normal", timeoutMs: -1, bodyComponent: comp, bodyProps: props });
        return { name: tag, uid: uid };
    }

    function build() {
        if (root.oldBody !== "")
            root.oldComp = Qt.createComponent(root.oldBody);
        const params = { pct: 3, minutes: 30 };
        const out = [];
        for (const n of root.names) {
            const c = root.load(n);
            const q = Cases.quoteOf(c, root.baseMs); // qmllint disable unqualified
            const now = q.timeMs;
            const price = v => Fmt.price(v, q.currency, q.priceHint);
            if (c.kind === "sudden") {
                const mv = Sudden.evaluate(q, params, now);
                const m = mv.up || mv.down;
                const t = Sudden.text(c.label, m, q);
                const day = Sudden.facts(q, m, params, now);
                out.push(root.post("new_" + n, c, q, newBody, { facts: day }, t.title, t.body, m.dir === "up"));
                if (root.oldComp) {
                    const w = Sudden.windowOf(q, now, params.minutes);
                    out.push(root.post("old_" + n, c, q, root.oldComp, { values: w.c, baselineValue: m.from, up: m.dir === "up" }, t.title, t.body, m.dir === "up"));
                }
            } else {
                const what = c.kind === "above" ? "rose above " + price(c.level) : c.kind === "below" ? "fell below " + price(c.level)
                           : "moved " + Fmt.pct(q.changePct) + " today";
                const f = Sudden.facts(q, null, null, now, { kind: c.kind, level: c.kind === "dayMove" ? null : c.level });
                out.push(root.post("new_" + n, c, q, newBody, { facts: f }, c.label + " " + what,
                                   "Now " + price(q.price) + ", " + Fmt.pct(q.changePct) + " today", c.kind === "above" || (c.kind === "dayMove" && q.changePct >= 0)));
            }
        }
        root.cells = out;
    }

    FloatingWindow {
        id: win
        implicitWidth: 400
        implicitHeight: 1700
        visible: true
        color: Theme.surface

        Column {
            id: col
            x: 0
            y: 0
            spacing: 0
            Repeater {
                id: rep
                model: root.cells
                delegate: Item {
                    id: cell
                    required property var modelData
                    objectName: "cell_" + cell.modelData.name
                    width: 400
                    height: card.implicitHeight + 24
                    Rectangle {
                        anchors.fill: parent
                        color: Theme.surface
                    }
                    NotificationCard {
                        id: card
                        x: 20
                        y: 12
                        width: 360
                        d: svc.store.get(cell.modelData.uid)
                        service: svc
                        style: nstyle
                        cardWidth: 360
                    }
                }
            }
        }

        Timer {
            id: go
            interval: 700
            running: false
            onTriggered: win.next()
        }
        property int _i: 0
        function next() {
            if (win._i >= rep.count) {
                console.log("STOCK_NOTIF_SHEET RESULT " + (root.fails === 0 ? "PASS" : "FAIL"));
                Qt.quit();
                return;
            }
            const it = rep.itemAt(win._i++);
            it.grabToImage(r => {
                const p = root.outDir + "/" + it.modelData.name + ".png";
                if (!r.saveToFile(p))
                    root.fails++;
                console.log("STOCK_NOTIF_SHEET cell " + it.modelData.name + " " + it.width + "x" + it.height);
                Qt.callLater(win.next);
            });
        }
    }

    Component.onCompleted: {
        root.build();
        go.start();
    }
}
