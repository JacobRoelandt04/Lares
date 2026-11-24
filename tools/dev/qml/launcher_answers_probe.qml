pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import Quickshell.Io
import "modules/launcher"
import "modules/launcher/data"

// tools/dev/qml/launcher_answers_probe.qml -- the launcher's quick answers through the REAL service and popup, with the stand-in child
// (tools/dev/fixtures/launcher_answers_stub.py) and a copy command that appends to a file. Run by tools/dev/launcher_answers_ui_probe.sh,
// which sets LAN_DIR (the work dir), LAN_STUB and the private homes. Typing is done with real key events into the popup's grid.
// Prints `LAN ok|FAIL <check>` and `LAN RESULT PASS|FAIL (<n>/<n> checks)`.
Window {
    id: win
    visible: true
    width: 700
    height: 600

    readonly property string dir: Quickshell.env("LAN_DIR") || "/tmp/lan"
    readonly property string stub: Quickshell.env("LAN_STUB") || ""

    property int fails: 0
    property int checks: 0
    function check(name: string, ok: bool, detail: string): void {
        win.checks++;
        if (!ok)
            win.fails++;
        console.log("LAN " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }

    FileView {
        id: copyLog
        path: win.dir + "/copies.log"
        blockAllReads: true
        printErrors: false
    }
    FileView {
        id: askLog
        path: win.dir + "/asks.log"
        blockAllReads: true
        printErrors: false
    }
    function lines(fv): var {
        fv.reload();
        let t = "";
        try {
            t = String(fv.text());
        } catch (e) {
            t = "";
        }
        return t.split("\n").filter(l => l.length > 0);
    }
    function copies(): var {
        return win.lines(copyLog);
    }
    function asks(): var {
        return win.lines(askLog);
    }

    // Smoked bare (no runner: no stub, no work dir) it drives nothing.
    Timer {
        interval: 0
        running: win.stub === ""
        onTriggered: Qt.quit()
    }
    property int closes: 0
    property bool stageOn: true
    Loader {
        id: stage
        anchors.fill: parent
        active: win.stageOn && win.stub !== ""
        sourceComponent: Item {
            id: st
            readonly property alias service: svc
            readonly property alias popup: popup
            LauncherService {
                id: svc
                configPath: win.dir + "/launcher.jsonc"
                favoritesPath: win.dir + "/favs.json"
                favoritesLegacyPath: ""
                statePath: win.dir + "/state/state.json"
                scriptsRootOverride: win.dir + "/scripts"
                dryRun: true
                answerCommand: ["python3", win.stub]
                copyCommand: ["sh", "-c", 'printf "%s\\n" "$2" >> "$1"', "sh", win.dir + "/copies.log"]
                rowsOverride: 6
                columnsOverride: 1
            }
            LauncherPopup {
                id: popup
                service: svc
                tune: LauncherTune {
                    answerCopiedMs: 300
                }
                width: popup.implicitWidth
                height: popup.implicitHeight
                onCloseRequested: win.closes++
            }
        }
    }
    readonly property var svc: stage.item ? stage.item.service : null
    readonly property var popup: stage.item ? stage.item.popup : null

    // A second service whose child's script is missing (nothing is typed into a popup there).
    readonly property alias missingSvc: missingSvc
    LauncherService {
        id: missingSvc
        configPath: win.dir + "/m/launcher.jsonc"
        favoritesPath: win.dir + "/m/favs.json"
        favoritesLegacyPath: ""
        statePath: win.dir + "/m/state.json"
        scriptsRootOverride: win.dir + "/scripts"
        dryRun: true
        answerScript: win.dir + "/no-such-answers.py"
    }

    TestCase {
        id: tc
        name: "lan"
        when: false
    }

    function find(item, name): var {
        if (!item)
            return null;
        if (item.objectName === name)
            return item;
        const ch = item.children;
        for (let i = 0; i < ch.length; i++) {
            const f = win.find(ch[i], name);
            if (f)
                return f;
        }
        return null;
    }
    function row(): var {
        return win.find(win.popup, "answerRow");
    }
    function nomatch(): var {
        return win.find(win.popup, "launcherNoMatch");
    }
    // What the runner's notifier is told, and a finished script's stand-in.
    QtObject {
        id: noteStub
        property var sent: []
        function notify(key: string, spec: var): void {
            sent.push({ key: key, title: spec.title, body: spec.body });
        }
    }
    property alias noteStub: noteStub
    QtObject {
        id: finishedStub
        property string key: "ok"
    }
    property alias finishedStub: finishedStub
    function grid(): var {
        return win.find(win.popup, "launcherGrid");
    }
    function textOf(name): string {
        const t = win.find(win.row(), name);
        return t ? String(t.text) : "<none>";
    }
    function type(text: string): void {
        win.requestActivate();
        for (let i = 0; i < text.length; i++)
            tc.keyClick(text.charAt(i));
    }
    function key(k, mods): void {
        tc.keyClick(k, mods === undefined ? Qt.NoModifier : mods);
    }
    function ans(): string {
        return win.svc && win.svc.answers.length > 0 ? win.svc.answers[0].value : "";
    }

    // ---- the script ---------------------------------------------------------------------------------------------
    property int step: -1
    property double stepAt: 0
    property bool started: false
    property var memo: ({})
    property var steps: []

    function addPause(ms) {
        win.steps.push({
            name: "pause",
            doit: () => { },
            until: () => false,
            ms: ms,
            pause: true
        });
    }
    function addStep(name, doit, until, ms) {
        win.steps.push({
            name: name,
            doit: doit,
            until: until || (() => true),
            ms: ms || 3000
        });
    }

    Component.onCompleted: {
        // -- nothing asked, nothing started -------------------------------------------------------------------------
        win.addStep("lazy: no child before the first non-empty query", () => {
            win.check("lazy: no child before the first non-empty query", win.svc && !win.svc.answersRunning && win.asks().length === 0, "running=" + (win.svc && win.svc.answersRunning));
            win.memo.h0 = win.popup.implicitHeight;
            win.memo.gridY = win.grid().parent.y;
        });
        win.addStep("", () => {
            win.popup.forceActiveFocus();
            win.grid().forceActiveFocus();
            // Up on an empty query with nothing remembered: nothing happens
            win.key(Qt.Key_Up);
        });
        win.addStep("", () => {
            win.check("recall: Up with no history leaves the query alone", win.svc.query === "" && !win.svc.answerRecalling, "query=" + win.svc.query);
            win.type("2+2");
        }, () => win.ans() === "4");
        win.addStep("", () => {
            win.check("answers: a typed query lands as the first answer", win.ans() === "4" && win.svc.answersRunning, "answer=" + win.ans());
            win.check("row: the answer row shows it", win.row() && win.row().visible && win.textOf("answerValue") === "4", "value=" + win.textOf("answerValue"));
            win.check("row: the popup did not resize, the list moved down one row", win.popup.implicitHeight === win.memo.h0 && win.grid().parent.y === win.memo.gridY + win.popup.rowH, "h=" + win.popup.implicitHeight + " vs " + win.memo.h0 + " gridY=" + win.grid().parent.y);
            win.check("row: highlighted by default", win.grid().answerSel === true, "sel=" + win.grid().answerSel);
        });
        // -- stale replies ------------------------------------------------------------------------------------------
        win.addStep("", () => {
            win.svc.setQuery("");
            win.svc.setQuery("slow");
            win.svc.setQuery("0xff");
        }, () => win.ans() === "255");
        win.addPause(900);
        win.addStep("", () => {
            win.check("stale: a reply for an earlier query is dropped", win.ans() === "255" && win.asks().some(l => l.indexOf(" slow") > 0), "answer=" + win.ans() + " asks=" + win.asks().length);
        });
        win.addStep("", () => {
            win.memo.n = win.asks().length;
            win.svc.setQuery("slow");
            win.svc.setQuery("");
        }, () => win.svc.answers.length === 0);
        win.addPause(900);
        win.addStep("", () => {
            win.check("empty: an empty query clears the answers and a late reply lands on nothing", win.svc.answers.length === 0 && win.row().presence < 0.01, "answers=" + win.svc.answers.length);
            win.check("empty: the empty query asked nothing", win.asks().length === win.memo.n + 1, "asks " + win.memo.n + " -> " + win.asks().length);
        });
        // -- pending ------------------------------------------------------------------------------------------------
        win.addStep("", () => {
            win.memo.n = win.asks().length;
            win.svc.setQuery("100 usd in eur");
        }, () => win.svc.answers.length > 0 && win.svc.answers[0].pending === true);
        win.addStep("", () => {
            win.memo.serial = win.svc.answerSerial;
            win.check("pending: the pending answer shows its fetching line", win.textOf("answerSub").indexOf("fetching") >= 0, win.textOf("answerSub"));
        }, () => win.svc.answers.length > 0 && win.svc.answers[0].pending === false);
        win.addStep("", () => {
            win.check("pending: its landed reply replaced it in place (one ask, same row, new text)", win.asks().length === win.memo.n + 1 && win.svc.answerSerial === win.memo.serial + 1 && win.textOf("answerSub").indexOf("ECB") >= 0 && win.textOf("answerValue") === "92.31 EUR", "asks=" + (win.asks().length - win.memo.n) + " serial " + win.memo.serial + " -> " + win.svc.answerSerial + " sub=" + win.textOf("answerSub"));
        });
        // -- Enter copies and closes --------------------------------------------------------------------------------
        win.addStep("", () => {
            win.svc.setQuery("2+2");
        }, () => win.ans() === "4" && win.grid().answerSel);
        win.addStep("", () => {
            win.memo.closes = win.closes;
            win.key(Qt.Key_Return);
        }, () => win.copies().length >= 1);
        win.addStep("", () => {
            win.check("enter: copies the main form", win.copies()[win.copies().length - 1] === "4", JSON.stringify(win.copies()));
            win.check("enter: closes the launcher", win.closes === win.memo.closes + 1, "closes " + win.memo.closes + " -> " + win.closes);
        });
        // -- Shift+Enter copies and stays ---------------------------------------------------------------------------
        win.addStep("", () => {
            win.svc.setQuery("0xff");
        }, () => win.ans() === "255" && win.grid().answerSel);
        win.addStep("", () => {
            win.memo.closes = win.closes;
            win.key(Qt.Key_Return, Qt.ShiftModifier);
        }, () => win.copies().length >= 2);
        win.addStep("", () => {
            win.check("shift+enter: copies", win.copies()[win.copies().length - 1] === "255", JSON.stringify(win.copies()));
            win.check("shift+enter: the launcher stays", win.closes === win.memo.closes, "closes " + win.memo.closes + " -> " + win.closes);
            win.check("shift+enter: the expr slot says Copied", win.textOf("answerSub").indexOf("Copied") >= 0, win.textOf("answerSub"));
        });
        win.addStep("", () => { }, () => win.textOf("answerSub").indexOf("Copied") < 0, 1500);
        win.addStep("", () => {
            win.check("shift+enter: Copied goes after answerCopiedMs", win.textOf("answerSub").indexOf("Copied") < 0, win.textOf("answerSub"));
        });
        // -- an alt's click copies the alt --------------------------------------------------------------------------
        win.addStep("", () => {
            win.svc.setQuery("4k");
        }, () => win.ans() === "3840 × 2160" && win.find(win.row(), "answerAltArea") !== null);
        win.addStep("", () => {
            win.memo.closes = win.closes;
            const a = win.find(win.row(), "answerAltArea");
            const p = a.mapToItem(null, a.width / 2, a.height / 2);
            tc.mouseMove(win.contentItem, p.x, p.y);
            tc.mouseClick(win.contentItem, p.x, p.y);
        }, () => win.copies().length >= 3);
        win.addStep("", () => {
            win.check("alt: a click on an alt copies that alt", win.copies()[win.copies().length - 1] === "3840 x 2160", JSON.stringify(win.copies()));
            win.check("alt: and closes the launcher", win.closes === win.memo.closes + 1, "closes " + win.memo.closes + " -> " + win.closes);
        });
        // -- no answer: behaviour unchanged ---------------------------------------------------------------------------
        win.addStep("", () => {
            win.svc.setQuery("zzprobe");
        }, () => win.grid().order.length > 0 && win.svc.answers.length === 0);
        win.addPause(400);
        win.addStep("", () => {
            win.check("none: no answer, no row, the list is whole again", win.svc.answers.length === 0 && win.grid().parent.y === win.memo.gridY && !win.grid().answerSel, "gridY=" + win.grid().parent.y);
            win.key(Qt.Key_Up);
        });
        win.addStep("", () => {
            win.check("none: Up on a non-empty query is not a recall", win.svc.query === "zzprobe" && !win.svc.answerRecalling, "query=" + win.svc.query);
            win.memo.closes = win.closes;
            win.memo.copies = win.copies().length;
            win.key(Qt.Key_Return);
        }, () => win.svc.lastCommand !== "");
        win.addStep("", () => {
            win.check("none: Enter launches the app as before", win.svc.lastCommand.indexOf("zzprobe") >= 0 && win.closes === win.memo.closes + 1 && win.copies().length === win.memo.copies, "last=" + win.svc.lastCommand + " closes " + win.memo.closes + " -> " + win.closes);
        });
        // -- the child dies and comes back --------------------------------------------------------------------------
        win.addStep("", () => {
            win.svc.setQuery("boom");
        }, () => !win.svc.answersRunning, 2500);
        win.addStep("", () => {
            win.svc.setQuery("2+2");
        }, () => win.ans() === "4", 6000);
        win.addStep("", () => {
            win.check("restart: a child that died is started again and answers the query asked meanwhile", win.ans() === "4" && win.svc.answersRunning, "answer=" + win.ans() + " running=" + win.svc.answersRunning);
        });
        // -- the history survives a restart of the service ----------------------------------------------------------
        win.addStep("", () => {
            win.svc.setQuery("");
            win.stageOn = false;
        }, () => win.svc === null);
        win.addPause(500);
        win.addStep("", () => {
            win.stageOn = true;
        }, () => win.svc !== null && win.popup !== null && win.svc.ready !== undefined);
        win.addPause(400);
        win.addStep("", () => {
            win.grid().forceActiveFocus();
            win.requestActivate();
            win.key(Qt.Key_Up);
        }, () => win.svc.query !== "");
        win.addStep("", () => {
            win.check("recall: Up on an empty query brings back the newest answered query (kept in the state file)", win.svc.query === "4k" && win.svc.answerRecalling, "query=" + win.svc.query);
            win.key(Qt.Key_Up);
        });
        win.addStep("", () => {
            win.check("recall: Up again goes one further back", win.svc.query === "0xff", "query=" + win.svc.query);
            win.key(Qt.Key_Down);
        });
        win.addStep("", () => {
            win.check("recall: Down walks back", win.svc.query === "4k", "query=" + win.svc.query);
            win.key(Qt.Key_Down);
        });
        win.addStep("", () => {
            win.check("recall: Down past the newest leaves it with an empty query", win.svc.query === "" && !win.svc.answerRecalling, "query=" + win.svc.query);
            win.key(Qt.Key_Up);
            win.type("x");
        });
        win.addStep("", () => {
            win.check("recall: typing leaves the recall", !win.svc.answerRecalling && win.svc.query === "4kx", "query=" + win.svc.query + " rec=" + win.svc.answerRecalling);
        });
        // -- a child that cannot start ------------------------------------------------------------------------------
        win.addStep("", () => {
            missingSvc.setQuery("2+2");
        }, () => missingSvc.answersMissing, 4000);
        win.addStep("", () => {
            win.check("missing: no python or script, no answers and no child", missingSvc.answersMissing && missingSvc.answers.length === 0 && !missingSvc.answersRunning, "missing=" + missingSvc.answersMissing);
        });
        // -- the words of an empty list: "No match" ----------------------------------------------------------------------
        win.addStep("", () => {
            win.svc.setQuery("");
        }, () => win.svc.answers.length === 0 && win.nomatch() !== null && win.nomatch().opacity < 0.01, 3000);
        win.addStep("", () => {
            win.check("nomatch: an empty query says nothing", !!win.nomatch() && win.nomatch().opacity < 0.01 && !win.nomatch().visible, "opacity=" + (win.nomatch() ? win.nomatch().opacity : "no item"));
            win.svc.setQuery("zzprobe");
        }, () => win.grid().order.length > 0);
        win.addPause(500);
        win.addStep("", () => {
            win.check("nomatch: a query with a match says nothing", win.grid().order.length > 0 && win.nomatch().opacity < 0.01, "opacity=" + win.nomatch().opacity + " tiles=" + win.grid().order.length);
            win.svc.setQuery("qzxslow");
        });
        win.addPause(400);
        win.addStep("", () => {
            win.check("nomatch: no words while the quick answer's reply is still out (no flash)", win.svc.answersWaiting && win.grid().order.length === 0 && win.nomatch().opacity < 0.01, "waiting=" + win.svc.answersWaiting + " tiles=" + win.grid().order.length + " opacity=" + win.nomatch().opacity);
        });
        win.addStep("", () => {
        }, () => !win.svc.answersWaiting && win.nomatch().opacity > 0.99, 4000);
        win.addStep("", () => {
            win.check("nomatch: a query nothing matches says 'No match' once the reply came empty", win.nomatch().text === "No match" && win.nomatch().visible && win.nomatch().opacity > 0.99 && win.grid().order.length === 0 && win.svc.answers.length === 0, "text=" + win.nomatch().text + " opacity=" + win.nomatch().opacity + " tiles=" + win.grid().order.length);
            win.svc.setQuery("2+2");
        }, () => true);
        win.addStep("", () => {
        }, () => win.ans() === "4", 3000);
        win.addPause(500);
        win.addStep("", () => {
            win.check("nomatch: a quick answer stands in for the words", win.ans() === "4" && win.nomatch().opacity < 0.01, "opacity=" + win.nomatch().opacity);
        });
        // -- a script that failed says what happened in words (LaunchRunner) ------------------------------------------------
        win.addStep("", () => {
            win.svc.notifier = win.noteStub;
            win.noteStub.sent = [];
            win.svc._runner._report("k", "Backup", 3, "");
            win.svc._runner._report("k2", "Sync", 1, "disk full");
            win.svc._runner._finished(win.finishedStub, 0, "");
        });
        win.addStep("", () => {
            const n = win.noteStub.sent;
            win.check("script: a failure with no output of its own says 'It stopped with exit code N'", n.length >= 1 && n[0].title === "Backup failed" && n[0].body === "It stopped with exit code 3", JSON.stringify(n));
            win.check("script: its own last line still wins", n.length >= 2 && n[1].title === "Sync failed" && n[1].body === "disk full", JSON.stringify(n));
            win.check("script: a clean exit says nothing", n.length === 2, JSON.stringify(n));
        });
        // -- launcher.jsonc -----------------------------------------------------------------------------------------
        win.addStep("", () => {
            const free = (c, t) => barOwner._freeKeysFor({ "class": c, title: t });
            win.check("file: keysFree's default is kitty with yazi in its title", free("Kitty", "Yazi: ~/x") && !free("kitty", "bash") && !free("foot", "yazi"), "");
            win.check("file: a click outside keeps the launcher by default", (barOwner._grabCleared(), fakeEngine.closes === 0), "closes=" + fakeEngine.closes);
            win.svc.config._ingest('{ "keysFree": [{ "class": "foot" }, {}, { "title": "pick a file" }], "clickOutsideCloses": true, "keepQuerySec": 60, '
                + '"answers": { "takesEnter": false, "history": 1, "homeCurrency": "USD", "currencies": ["JPY", "GBP"], "kinds": ["math", "unit"] } }');
            win.check("file: keysFree is a list of classes and titles, an empty one matches nothing", free("foot", "x") && free("x", "Pick a file") && !free("kitty", "yazi"), "");
            win.popup.answerTakesEnter = win.svc.config.answers.takesEnter;
            win.svc.setQuery("");
            win.svc._state.pushAnswerHistory("1+1");
            win.svc._state.pushAnswerHistory("1+2");
            win.check("file: answers.history is how many are remembered", JSON.stringify(win.svc._state.answerHistory()) === '["1+2"]', JSON.stringify(win.svc._state.answerHistory()));
            const argv = win.missingSvc._answerBox;
            win.missingSvc._config._ingest('{ "answers": { "homeCurrency": "USD", "currencies": ["JPY", "GBP"], "kinds": ["math", "unit"] } }');
            win.check("file: the child is told what answers says", argv._argv().slice(-6).join(" ") === "--home-currency USD --currencies JPY,GBP --kinds math,unit", argv._argv().join(" "));
        });
        win.addStep("", () => {
            // the pointer the steps above left on the answer row goes: hovering the row highlights it
            tc.mouseMove(win.contentItem, 3, win.height - 3);
            win.svc.setQuery("2+2");
        }, () => win.ans() === "4");
        win.addStep("", () => {
            win.check("file: takesEnter false: the answer is shown and not highlighted", win.row() && win.row().visible && !win.grid().answerSel, "sel=" + win.grid().answerSel);
            // the owner's session over the same service
            barOwner.open("shortcut");
            win.svc.setQuery("7*6");
            barOwner.close();
            barOwner._endSession();
            win.check("file: a closed launcher has no query", win.svc.query === "", win.svc.query);
            barOwner.open("shortcut");
            win.check("file: keepQuerySec: opened again it has the query it was left with", win.svc.query === "7*6", win.svc.query);
            win.svc.launched("x", false);
            barOwner.close();
            barOwner._endSession();
            barOwner.open("shortcut");
            win.check("file: keepQuerySec: a launch leaves none", win.svc.query === "", win.svc.query);
            win.svc.setQuery("7*7");
            win.svc.config._ingest("{}");
            barOwner.close();
            barOwner._endSession();
            barOwner.open("shortcut");
            win.check("file: keepQuerySec 0: it opens empty", win.svc.query === "", win.svc.query);
            win.svc.config._ingest('{ "clickOutsideCloses": true }');
            barOwner._grabCleared();
            win.check("file: clickOutsideCloses closes it", !fakeEngine.popupOpen, "");
        });
    }

    Timer {
        interval: 40
        repeat: true
        running: true
        onTriggered: {
            if (!win.started) {
                if (!win.svc || !win.popup || !win.grid() || win.svc.ready !== true)
                    return;
                win.started = true;
                win.step = 0;
                win.stepAt = Date.now();
                win.steps[0].begun = false;
            }
            if (win.step >= win.steps.length) {
                if (win.step === win.steps.length) {
                    win.step++;
                    console.log("LAN RESULT " + (win.fails === 0 ? "PASS" : "FAIL") + " (" + (win.checks - win.fails) + "/" + win.checks + " checks)");
                    Qt.quit();
                }
                return;
            }
            const s = win.steps[win.step];
            const now = Date.now();
            if (!s.begun) {
                s.begun = true;
                s.at = now;
                try {
                    s.doit();
                } catch (e) {
                    win.check("step " + win.step + " " + s.name, false, "threw: " + e);
                }
            }
            let done = false;
            try {
                done = s.until();
            } catch (e) {
                done = false;
            }
            if (done || now - s.at > s.ms) {
                if (!done && !s.pause)
                    win.check("wait before step " + (win.step + 1), false, "timed out after " + s.ms + " ms");
                win.step++;
                if (win.step < win.steps.length)
                    win.steps[win.step].begun = false;
            }
        }
    }
    // The bar-side owner over a stand-in engine (its windows, its kept query).
    QtObject {
        id: fakeEngine
        property bool popupOpen: false
        property string popupOwnerId: ""
        property var popupCornerRadii: [0, 0, 0, 0]
        property bool effectsLive: false
        property int closes: 0
        function open(id) {
            fakeEngine.popupOwnerId = id;
            fakeEngine.popupOpen = true;
        }
        function close() {
            fakeEngine.popupOpen = false;
            fakeEngine.popupOwnerId = "";
            fakeEngine.closes++;
        }
    }
    Item {
        id: fakeBar
        width: 100
    }
    LauncherBarOwner {
        id: barOwner
        engine: fakeEngine
        bar: fakeBar
        shellHosted: true
        shortcutEnabled: false
        liveWindow: false
        service: win.svc
    }
    // A harness that never starts (the service never ready) is a failed run, not a silent one.
    Timer {
        interval: 60000
        running: true
        onTriggered: {
            console.log("LAN FAIL step " + win.step + " never finished");
            console.log("LAN RESULT FAIL (" + (win.checks - win.fails) + "/" + win.checks + " checks, stuck at step " + win.step + ")");
            Qt.quit();
        }
    }
}
