pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import Quickshell.Io

import "modules/common/theme"
import "modules/notes"

// =============================================================================
// dictation_probe_notes.qml -- the notes editor's side of a dictation take (round 8: "while I was speaking there was more text than
// there should have been"), on the real store + popup + editor over a fixture notes root. Run by tools/dev/dictation_probe_notes.sh.
//
// The service hands a shell field `shellPrefix + the live words` -- a piece after a word starts with a SPACE -- once per partial, then the
// sentence's final through `dictationCommit`. Each partial is sampled in the line's TextEdit (what the user SEES):
//   P1  every partial shows its words exactly once, at the caret, whatever the one before it was (a rich-text insert may drop the leading
//       space, so the clear of the old preedit found other text and the old one stayed: words twice)
//   P2  the characters of speech that rich text reads as markup (&, <, >) stand as typed and the next partial still replaces them
//   P3  a commit lands in the document at the caret, the preedit gone, and the contract answers true; a commit with nothing to take it
//       (the editor lost the caret) answers false -- the service then falls back to the clipboard
//   P4  the title edit: a preedit in it is never committed as a title by a focus change (titleCommitted), a commit lands
//   P5  no `QTextCursor::setPosition ... out of range` warning in the whole run (the log is read by the runner)
// Each check prints `DNP ok|FAIL <what>`; the last line is `DNP RESULT PASS|FAIL (<n>/<n> checks)`.
// =============================================================================
ShellRoot {
    id: probe
    settings.watchFiles: false

    readonly property string notesDir: Quickshell.env("DNP_NOTES") || ""
    readonly property string stateDir: Quickshell.env("XDG_STATE_HOME") || "/tmp"

    property int checks: 0
    property int fails: 0
    function check(ok: bool, what: string): void {
        probe.checks++;
        if (!ok)
            probe.fails++;
        console.log("DNP " + (ok ? "ok " : "FAIL ") + what);
    }

    Window {
        id: win
        visible: probe.notesDir !== ""
        width: 460
        height: 560
        color: Theme.surface
        Loader {
            id: host
            active: probe.notesDir !== ""
            sourceComponent: Component {
                Item {
                    readonly property alias store: st
                    readonly property alias popup: pop
                    NotesStore {
                        id: st
                        root: probe.notesDir
                        statePath: probe.stateDir + "/dnp-notes.json"
                        defaultBrowseSize: ({ w: 440, h: 540, shift: 0 })
                    }
                    NotesPopup {
                        id: pop
                        store: st
                        fontFamily: "Inter"
                        motionRunning: false
                        width: 440
                        height: 540
                    }
                }
            }
        }
    }

    readonly property var np: host.item ? host.item.popup : null
    readonly property var ns: host.item ? host.item.store : null
    // qmllint disable missing-property
    function editorOf(it: Item): var {
        if (!it)
            return null;
        if (it.viewport !== undefined && it.insertImageLine !== undefined)
            return it;
        for (let i = 0; i < it.children.length; i++) {
            const r = probe.editorOf(it.children[i]);
            if (r)
                return r;
        }
        return null;
    }
    // qmllint enable missing-property
    // found once the note is open (the editor is built with its view; a binding on `np` would keep its first, null, answer)
    property var ed: null
    function rowText(l: int): string {
        const row = probe.ed.viewport.delegateFor(l);
        return row ? row.edit.getText(0, row.edit.length).replace(/\u00a0/g, " ") : "<no row>";    // what the user sees: a no-break space is a space
    }
    function lines(): string {
        return JSON.stringify(probe.ed.doc.lines);
    }
    function count(hay: string, needle: string): int {
        return hay.split(needle).length - 1;
    }

    property var m: ({})
    property var steps: []
    property int stepAt: 0
    property real stepStarted: 0
    Timer {
        id: driver
        interval: 20
        repeat: true
        onTriggered: {
            if (probe.stepAt >= probe.steps.length) {
                driver.stop();
                console.log("DNP RESULT " + (probe.fails === 0 && probe.checks > 0 ? "PASS" : "FAIL") + " (" + (probe.checks - probe.fails) + "/" + probe.checks + " checks)");
                Qt.quit();
                return;
            }
            driver.stop();
            const waited = Date.now() - probe.stepStarted;
            let r = false;
            try {
                r = probe.steps[probe.stepAt](waited);
            } catch (e) {
                probe.check(false, "step " + probe.stepAt + " threw: " + e);
                r = true;
            }
            if (r === "wait" && waited < 15000) {
                driver.start();
                return;
            }
            if (r === "wait")
                probe.check(false, "step " + probe.stepAt + " timed out");
            probe.stepAt++;
            probe.stepStarted = Date.now();
            driver.start();
        }
    }
    Component.onCompleted: Qt.callLater(() => {
        if (probe.notesDir === "") {
            Qt.quit();
            return;
        }
        probe.steps = [
            () => probe.np && probe.ns && probe.ns.service.ready ? true : "wait",
            w => {
                if (w === 0 || !probe.ed)
                    probe.ns.openNote("Probe.md");
                probe.ed = probe.editorOf(probe.np);
                if (!probe.ed || !probe.ed.doc)
                    return "wait";
                probe.ed.doc.load("alpha beta\nsecond\n");
                probe.ed.focusBodyAt({ line: 0, col: 5 });
                return probe.np.dictationActive ? true : "wait";
            },
            // the opening restores the note's remembered caret a turn later: let it, then place ours
            w => {
                if (w < 300)
                    return "wait";
                probe.ed.setCaret({ line: 0, col: 5 }, { line: 0, col: 5 }, false);
                return true;
            },
            // ---- P1: the partials of a take, each as the service sends it (a space first: a piece after a word) ----
            () => {
                const parts = [" w0", " w0 w1", " w0 w1 w2", " w0 w1 w2 w3", " w0 w1 w2 w3 w4.", " w0 w1 w2 w3 w4. w5"];
                let bad = "";
                for (const t of parts) {
                    probe.np.dictationPreedit(t);
                    const got = probe.rowText(0);
                    if (got !== "alpha" + t + " beta")
                        bad += (bad ? " | " : "") + JSON.stringify(t) + " -> " + JSON.stringify(got);
                }
                probe.check(bad === "", "P1 each partial shows its words once at the caret" + (bad ? ": " + bad : ""));
                probe.np.dictationPreedit("");
                probe.check(probe.rowText(0) === "alpha beta" && probe.ed._pre === null, "P1 an empty preedit takes the last one away: " + JSON.stringify(probe.rowText(0)));
                probe.check(probe.lines() === '["alpha beta","second",""]', "P1 the document never held a preedit: " + probe.lines());
                return true;
            },
            // ---- P1b: the caret at the END of a long line (the user's notes: paragraphs of 500+ characters) ----
            () => {
                let long = "";
                for (let i = 0; i < 90; i++)
                    long += "word" + i % 10 + " ";
                probe.m.long = long.trim();
                probe.ed.doc.load(probe.m.long + "\nsecond\n");
                probe.ed.setCaret({ line: 0, col: probe.m.long.length }, { line: 0, col: probe.m.long.length }, false);
                return true;
            },
            () => {
                const parts = [" q0", " q0 q1", " q0 q1 q2 q3.", " q0 q1 q2 q3. q4"];
                let bad = "";
                for (const t of parts) {
                    probe.np.dictationPreedit(t);
                    const got = probe.rowText(0);
                    if (got !== probe.m.long + t)
                        bad += (bad ? " | " : "") + JSON.stringify(t) + " -> ..." + JSON.stringify(got.slice(-40));
                }
                probe.check(bad === "", "P1 at the end of a 500-character line each partial shows its words once" + (bad ? ": " + bad : ""));
                probe.check(probe.np.dictationCommit(" Q0 q1.") === true && probe.rowText(0) === probe.m.long + " Q0 q1.", "P1 and its commit leaves the line whole: ..." + JSON.stringify(probe.rowText(0).slice(-30)));
                probe.np.dictationPreedit(" q2");
                probe.np.dictationPreedit("");
                probe.check(probe.rowText(0) === probe.m.long + " Q0 q1.", "P1 a preedit cleared after a commit takes nothing of the line: ..." + JSON.stringify(probe.rowText(0).slice(-30)));
                probe.ed.doc.load("alpha beta\nsecond\n");
                probe.ed.setCaret({ line: 0, col: 5 }, { line: 0, col: 5 }, false);
                return true;
            },
            // ---- P2: markup characters ----
            () => {
                const parts = [" a < b", " a < b & c >", " <b>bold</b> &amp; more"];
                let bad = "";
                for (const t of parts) {
                    probe.np.dictationPreedit(t);
                    const got = probe.rowText(0);
                    if (got !== "alpha" + t + " beta")
                        bad += (bad ? " | " : "") + JSON.stringify(t) + " -> " + JSON.stringify(got);
                }
                probe.check(bad === "", "P2 &, < and > stand as spoken" + (bad ? ": " + bad : ""));
                probe.np.dictationPreedit("");
                probe.check(probe.rowText(0) === "alpha beta", "P2 and the preedit still clears: " + JSON.stringify(probe.rowText(0)));
                return true;
            },
            // ---- P3: a commit ----
            () => {
                probe.np.dictationPreedit(" w0 w1");
                const ok = probe.np.dictationCommit(" W0 w1.");
                probe.check(ok === true, "P3 a commit the editor took answers true: " + ok);
                probe.check(probe.lines() === '["alpha W0 w1. beta","second",""]' && probe.rowText(0) === "alpha W0 w1. beta", "P3 it is in the document, the preedit gone: " + probe.lines() + " / " + JSON.stringify(probe.rowText(0)));
                // ... and the next take's partials go in after it
                probe.np.dictationPreedit(" w2");
                probe.np.dictationPreedit(" w2 w3");
                probe.check(probe.rowText(0) === "alpha W0 w1. w2 w3 beta", "P3 the next partials follow the commit: " + JSON.stringify(probe.rowText(0)));
                probe.np.dictationPreedit("");
                return true;
            },
            () => {
                // no caret in the editor (the popup lost the keyboard): the contract says so, the service falls back
                probe.ed.focusTitle(true);
                probe.ed.doc.readOnly = true;
                const dropped = probe.np.dictationCommit("lost words");
                probe.ed.doc.readOnly = false;
                probe.check(dropped === false, "P3 a commit nothing can take answers false: " + dropped);
                probe.check(probe.lines() === '["alpha W0 w1. beta","second",""]', "P3 and the document is as it was: " + probe.lines());
                return true;
            },
            // ---- P4: the title ----
            () => {
                probe.ed.focusTitle(true);
                return probe.np.dictationActive ? true : "wait";
            },
            () => {
                probe.m.titleBefore = probe.ed.titleText !== undefined ? probe.ed.titleText : "";
                probe.m.committed = [];
                return true;
            },
            () => {
                probe.np.dictationPreedit(" spoken title");
                // the focus leaves the title with a preedit standing in it: what the title commits is its text WITHOUT the preedit
                probe.ed.focusBodyAt({ line: 0, col: 0 });
                return true;
            },
            w => {
                if (w < 200)
                    return "wait";
                const key = probe.ns.noteKey || "";
                probe.check(String(key).indexOf("spoken title") < 0, "P4 a preedit in the title is never committed as the title: the note is " + JSON.stringify(key));
                return true;
            }
        ];
        probe.stepStarted = Date.now();
        driver.start();
    })
}
