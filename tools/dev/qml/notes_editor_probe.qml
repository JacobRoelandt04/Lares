pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import Quickshell.Io

import "modules/common/theme"
import "modules/common/components/LiveMarkdown.js" as LM
import "modules/common/components/Markdown.js" as Md
import "modules/notes"

// =============================================================================
// notes_editor_probe.qml -- the notes popup's round-6 behaviour, on the real store + popup + editor over a fixture notes root.
// Run by tools/dev/notes_editor_probe.sh (a private config / state, the fixture built there).
//
//   NEP_NOTES=<dir>    the notes root (a copy, with Probe.md, a symlinked Linked.md and .attachments/Pasted image ....png)
//   NEP_GRAB=<dir>     also write the editor's picture after each image check (<dir>/<name>.png)
//
//   escape     the popup's handleEscape() answers false (the engine closes) and goes back nowhere: view, note and folder stay
//   shift      Shift+Enter opens an empty line below the caret's line, the tail stays; Enter still splits / continues a list
//   image      a pasted image link (<..> destination, spaces) is put on a line of its own and RENDERS (plain note, symlinked note);
//              the LLM's markdown reads the same destination
//   dictation  dictationActive / dictationPreedit / dictationCommit: the preedit is underlined in the line and not in the document,
//              a commit lands in the document and on disk, a title takes it, the grid is not active
//   config     notes.jsonc: Escape that goes back, what the popup opens on, the name of a note that has none, the delete's question, a link's click
// Each check prints `NEP ok|FAIL <what>`; the last line is `NEP RESULT PASS|FAIL (<n>/<n> checks)`.
// =============================================================================
ShellRoot {
    id: probe
    settings.watchFiles: false

    readonly property string notesDir: Quickshell.env("NEP_NOTES") || ""
    readonly property string grabDir: Quickshell.env("NEP_GRAB") || ""
    readonly property string stateDir: Quickshell.env("XDG_STATE_HOME") || "/tmp"

    property int checks: 0
    property int fails: 0
    function check(ok: bool, what: string): void {
        probe.checks++;
        if (!ok)
            probe.fails++;
        console.log("NEP " + (ok ? "ok " : "FAIL ") + what);
    }

    TestCase {
        id: tc
        name: "nep"
        when: false
    }
    FileView {
        id: reader
        blockLoading: true
        printErrors: false
    }
    function disk(path: string): string {
        reader.path = "";
        reader.path = path;
        reader.reload();
        return reader.text() || "";
    }

    Window {
        id: win
        visible: probe.notesDir !== ""
        width: 460
        height: 560
        color: Theme.surface
        Rectangle {
            anchors.fill: parent
            color: Theme.surface
        }
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
                        statePath: probe.stateDir + "/nep-notes.json"
                        defaultBrowseSize: ({
                                w: 440,
                                h: 540,
                                shift: 0
                            })
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
    // The first item in the tree that has property `name` and is visible.
    function findProp(item: Item, name: string, vis: bool): var {
        if (!item)
            return null;
        if (name in item && (!vis || item.visible) && item.order !== undefined)
            return item;
        for (let i = 0; i < item.children.length; i++) {
            const r = probe.findProp(item.children[i], name, vis);
            if (r)
                return r;
        }
        return null;
    }
    function find(item: Item, name: string): var {
        if (!item)
            return null;
        if (item.objectName === name)
            return item;
        for (let i = 0; i < item.children.length; i++) {
            const r = probe.find(item.children[i], name);
            if (r)
                return r;
        }
        return null;
    }
    readonly property var ed: probe.editorOf(probe.np)
    // The note pane (the item that has `problem` and `banded`), and a visible Text under it that starts with `head`.
    function pane(): var {
        return probe.findOf(probe.np, it => it.banded !== undefined && it.problem !== undefined);
    }
    function findOf(item: Item, pred: var): var {
        if (!item)
            return null;
        if (pred(item))
            return item;
        for (let i = 0; i < item.children.length; i++) {
            const r = probe.findOf(item.children[i], pred);
            if (r)
                return r;
        }
        return null;
    }
    function textShown(root: Item, head: string): var {
        return probe.findOf(root, it => it.visible && typeof it.text === "string" && it.elide !== undefined && it.text.indexOf(head) === 0);
    }
    readonly property string attach: probe.notesDir + "/.attachments/Pasted image 20261109-111327.png"

    function grab(name: string, then: var): void {
        if (probe.grabDir === "") {
            then();
            return;
        }
        win.contentItem.grabToImage(r => {
            r.saveToFile(probe.grabDir + "/" + name + ".png");
            then();
        });
    }
    function pos(l: int, c: int): var {
        return { line: l, col: c };
    }
    function lines(): string {
        return JSON.stringify(probe.ed.doc.lines);
    }
    function caretOk(l: int, c: int): bool {
        const k = probe.ed.doc.caret;
        return k.line === l && k.col === c;
    }
    // Open a note and put the caret in its body.
    function openAt(key: string, l: int, c: int): bool {
        probe.ns.openNote(key);
        if (!probe.ed || !probe.ed.doc)
            return false;
        probe.ed.focusBodyAt(probe.pos(l, c));
        return probe.np.dictationActive;
    }

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
                console.log("NEP RESULT " + (probe.fails === 0 && probe.checks > 0 ? "PASS" : "FAIL") + " (" + (probe.checks - probe.fails) + "/" + probe.checks + " checks)");
                Qt.quit();
                return;
            }
            // keyClick runs the event loop: the timer must not run a step inside a step.
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

    property var mem: ({})
    Component.onCompleted: Qt.callLater(() => {
        if (probe.notesDir === "") {
            Qt.quit();
            return;
        }
        probe.steps = probe.makeSteps();
        probe.stepStarted = Date.now();
        driver.start();
    })

    function makeSteps(): var {
        const m = probe.mem;
        return [
            () => probe.np && probe.ns && probe.ns.service.ready ? true : "wait",
            // ---- escape ----
            () => {
                probe.ns.openNote("Probe.md");
                probe.ns.setQuery("zz");
                const r = probe.np.handleEscape();
                probe.check(r === false, "escape: handleEscape answers false, so the engine closes the popup (" + r + ")");
                probe.check(probe.ns.query === "", "escape: the typed search goes");
                probe.check(probe.ns.view === "editor" && probe.ns.noteKey === "Probe.md" && !probe.np.morphing, "escape: the open note stays open (" + probe.ns.view + " " + probe.ns.noteKey + ")");
                probe.ns.view = "browse";
                probe.ns.folder = "Projects";
                probe.np.handleEscape();
                probe.check(probe.ns.folder === "Projects" && probe.ns.view === "browse", "escape: the folder stays (" + probe.ns.folder + ")");
                probe.ns.folder = "";
                return true;
            },
            // ---- Shift+Enter ----
            () => probe.openAt("Probe.md", 0, 5) ? true : "wait",
            () => {
                tc.keyClick(Qt.Key_Return, Qt.ShiftModifier);
                probe.check(probe.lines() === '["alpha beta","","- item one","tail",""]' && probe.caretOk(1, 0), "shift+enter: a new empty line below, the tail ' beta' stays where it was: " + probe.lines() + " caret " + JSON.stringify(probe.ed.doc.caret));
                probe.ed.setCaret(probe.pos(2, 6), probe.pos(2, 6), false);
                tc.keyClick(Qt.Key_Return, Qt.ShiftModifier);
                probe.check(probe.lines() === '["alpha beta","","- item one","","tail",""]' && probe.caretOk(3, 0), "shift+enter in a list item: an empty line, no marker, the item's tail stays: " + probe.lines());
                return true;
            },
            // plain Enter, from a clean document
            () => {
                probe.ed.doc.load("alpha beta\n- item one\ntail\n");
                probe.ed.setCaret(probe.pos(0, 5), probe.pos(0, 5), false);
                tc.keyClick(Qt.Key_Return);
                probe.check(probe.lines() === '["alpha"," beta","- item one","tail",""]' && probe.caretOk(1, 0), "enter: still splits at the caret: " + probe.lines());
                probe.ed.setCaret(probe.pos(2, 10), probe.pos(2, 10), false);
                tc.keyClick(Qt.Key_Return);
                probe.check(probe.lines() === '["alpha"," beta","- item one","- ","tail",""]' && probe.caretOk(3, 2), "enter: still continues a list: " + probe.lines());
                return true;
            },
            // ---- the image ----
            () => {
                m.rel = LM.relativePath(probe.ns.realDirOf("Probe.md"), probe.attach);
                m.md = LM.imageMarkdown(m.rel, "");
                probe.check(m.md.indexOf("<") >= 0, "image: the link of a name with spaces is written <like this>: " + m.md);
                probe.ed.doc.load("# Plain\ntext here\n");
                probe.ed.setCaret(probe.pos(1, 4), probe.pos(1, 4), false);
                probe.ed.insertImageLine(m.md);
                probe.check(probe.ed.doc.lines[1] === "text here" && probe.ed.doc.lines[2] === m.md, "image: the link is on a line of its own, the text before it untouched: " + probe.lines());
                return true;
            },
            w => {
                const row = probe.ed.viewport.delegateFor(2);
                const box = row ? probe.find(row, "imageBox") : null;
                if ((!box || !box.ready) && w < 4000)
                    return "wait";
                probe.check(!!box && box.ready && row.t === "image" && box.visible, "image: the pasted link renders as an image in a plain note (" + box.width + " x " + box.height + ")");
                probe.grab("image_plain", () => {});
                return true;
            },
            () => {
                probe.ns.openNote("Linked.md");
                if (!probe.ed || probe.ns.noteKey !== "Linked.md")
                    return "wait";
                probe.ed.doc.load("# Linked\nabove\n");
                probe.ed.focusBodyAt(probe.pos(1, 0));
                m.relL = LM.relativePath(probe.ns.realDirOf("Linked.md"), probe.attach);
                probe.check(m.relL.indexOf("..") === 0, "image: a symlinked note's link is relative from its real folder: " + m.relL);
                probe.ed.insertImageLine(LM.imageMarkdown(m.relL, ""));
                return true;
            },
            w => {
                const row = probe.ed.viewport.delegateFor(2);
                const box = row ? probe.find(row, "imageBox") : null;
                if ((!box || !box.ready) && w < 4000)
                    return "wait";
                probe.check(!!box && box.ready && row.t === "image" && box.visible, "image: the pasted link renders in a symlinked note (" + box.width + " x " + box.height + ")");
                probe.grab("image_linked", () => {});
                return true;
            },
            () => {
                const o = Md.imageOf("![shot](<../.attachments/Pasted image 1.png>)");
                probe.check(o !== null && o.src === "../.attachments/Pasted image 1.png" && o.alt === "shot", "image: the LLM's markdown reads the <..> destination: " + JSON.stringify(o));
                const p = Md.imageOf("![a](plain.png \"t\")");
                probe.check(p !== null && p.src === "plain.png", "image: a plain destination reads as before");
                probe.check(Md.imageOf("![a](two words.png)") === null, "image: an unbracketed destination with a space is still no image");
                const h = Md.blockHtml(Md.parseBlocks("a ![s](<x y.png>) b")[0], {});
                probe.check(String(h).indexOf('src="x y.png"') >= 0, "image: inline, the destination loses its brackets");
                return true;
            },
            // ---- dictation ----
            () => {
                probe.ns.openNote("Probe.md");
                probe.ed.doc.load("alpha beta\nsecond\n");
                probe.ed.focusBodyAt(probe.pos(0, 5));
                return probe.np.dictationActive ? true : "wait";
            },
            // the opening restores the note's remembered caret a turn later: let it, then place ours
            w => {
                if (w < 300)
                    return "wait";
                probe.ed.setCaret(probe.pos(0, 5), probe.pos(0, 5), false);
                return true;
            },
            () => {
                probe.check(probe.np.dictationActive, "dictation: active with the caret in a line of an open note");
                const row = probe.ed.viewport.delegateFor(0);
                probe.np.dictationPreedit("XYZ");
                probe.check(row.edit.getText(0, row.edit.length) === "alphaXYZ beta", "dictation: the preedit is shown at the caret: " + row.edit.getText(0, row.edit.length));
                probe.check(probe.ed._pre && probe.ed._pre.bars.length === 1 && probe.ed._pre.bars[0].width > 4, "dictation: and underlined");
                probe.check(probe.lines() === '["alpha beta","second",""]', "dictation: the document does not hold it: " + probe.lines());
                probe.np.dictationPreedit("XYZW");
                probe.check(row.edit.getText(0, row.edit.length) === "alphaXYZW beta", "dictation: the next preedit replaces the last");
                m.preGrab = false;
                probe.grab("dictation_preedit", () => m.preGrab = true);
                return true;
            },
            // the picture of the standing preedit lands a frame or two after the ask
            () => {
                if (!m.preGrab)
                    return "wait";
                const row = probe.ed.viewport.delegateFor(0);
                probe.np.dictationPreedit("");
                probe.check(row.edit.getText(0, row.edit.length) === "alpha beta" && probe.ed._pre === null, "dictation: an empty preedit takes it away");
                probe.np.dictationPreedit("again");
                probe.np.dictationCommit("hello ");
                probe.check(probe.lines() === '["alphahello  beta","second",""]' || probe.lines() === '["alphahello  beta","second",""]', "dictation: a commit lands in the document at the caret, the preedit gone: " + probe.lines());
                probe.check(probe.caretOk(0, 11) && row.edit.getText(0, row.edit.length) === "alphahello  beta", "dictation: the caret follows the text (" + JSON.stringify(probe.ed.doc.caret) + ")");
                probe.ns.saveAll();
                return true;
            },
            w => probe.disk(probe.notesDir + "/Probe.md").indexOf("alphahello  beta") === 0 ? true : "wait",
            () => {
                probe.check(true, "dictation: the commit is on disk");
                probe.np.dictationPreedit("typed over");
                tc.keyClick(Qt.Key_Z);
                probe.check(probe.ed._pre === null && probe.ed.viewport.delegateFor(0).edit.getText(0, 99).indexOf("typed over") < 0, "dictation: a key takes a standing preedit out first");
                probe.ed.focusTitle(true);
                probe.check(probe.np.dictationActive, "dictation: active in the title");
                const before = probe.ed.titleItem.text;
                probe.np.dictationCommit(" Zed/x");
                probe.check(probe.ed.titleItem.text === before + " Zed x", "dictation: the title takes it, without a slash: " + probe.ed.titleItem.text);
                probe.ns.view = "browse";
                probe.check(!probe.np.dictationActive, "dictation: not active on the grid");
                return true;
            },
            // ---- the grid's keyboard highlight ----
            () => {
                probe.ns.view = "browse";
                probe.ns.setQuery("");
                return probe.np.morphing ? "wait" : true;
            },
            () => {
                const g = probe.findProp(probe.np, "kbKey", true);
                probe.check(!!g, "keys: the browse grid is found");
                if (!g)
                    return true;
                m.g = g;
                g.forceActiveFocus();
                probe.check(!g.kbShown, "keys: no highlight before a key");
                tc.keyClick(Qt.Key_Right);
                probe.check(g.kbShown && g.kbKey === g.order[0], "keys: the first arrow shows the highlight on the first tile: " + g.kbKey);
                tc.keyClick(Qt.Key_Down);
                probe.grab("keys-highlight", () => {});
                tc.keyClick(Qt.Key_End);
                probe.check(g.kbKey === g.order[g.order.length - 1], "keys: End goes to the last tile");
                tc.keyClick(Qt.Key_Home);
                probe.check(g.kbKey === g.order[0], "keys: Home goes to the first tile");
                tc.keyClick(Qt.Key_Down);
                probe.check(g.order.length <= g.geo.cols || g.kbKey === g.order[Math.min(g.order.length - 1, g.geo.cols)], "keys: Down moves a row");
                tc.keyClick(Qt.Key_Z);
                probe.check(!g.kbShown, "keys: typing hides the highlight");
                return true;
            },
            // arrows move by one tile / one row of the grid's own columns; Enter opens exactly the highlighted note
            () => {
                probe.ns.setQuery("");
                const g = m.g;
                return g.order.length > 2 && !g.searching && !probe.np.morphing ? true : "wait";
            },
            () => {
                const g = m.g;
                const n = g.order.length, cols = g.geo.cols;
                g.forceActiveFocus();
                probe.check(n > cols + 1, "keys: the fixture has more than one row (" + n + " tiles, " + cols + " columns)");
                tc.keyClick(Qt.Key_Home);
                probe.check(g.kbShown && g.kbKey === g.order[0], "keys: Home shows the highlight on the first tile");
                tc.keyClick(Qt.Key_Right);
                probe.check(g.kbKey === g.order[1], "keys: Right moves one tile: " + g.order.indexOf(g.kbKey));
                tc.keyClick(Qt.Key_Left);
                probe.check(g.kbKey === g.order[0], "keys: Left moves back one tile: " + g.order.indexOf(g.kbKey));
                tc.keyClick(Qt.Key_Down);
                probe.check(g.order.indexOf(g.kbKey) === cols, "keys: Down moves one row (" + g.order.indexOf(g.kbKey) + " of " + cols + " columns)");
                tc.keyClick(Qt.Key_Up);
                probe.check(g.kbKey === g.order[0], "keys: Up moves back one row: " + g.order.indexOf(g.kbKey));
                tc.keyClick(Qt.Key_End);
                probe.check(g.kbKey === g.order[n - 1], "keys: End reaches the last tile");
                // a note (not a folder) two tiles in
                let j = -1;
                for (let i = 1; i < n; i++) {
                    const e = probe.ns.service.entry(g.order[i]);
                    if (e && !e.isGroup) {
                        j = i;
                        break;
                    }
                }
                probe.check(j > 0, "keys: the fixture has a note tile to open (index " + j + ")");
                if (j < 0)
                    return true;
                tc.keyClick(Qt.Key_Home);
                for (let i = 0; i < j; i++)
                    tc.keyClick(Qt.Key_Right);
                m.want = g.order[j];
                probe.check(g.kbKey === m.want, "keys: the highlight stands on the note " + m.want);
                tc.keyClick(Qt.Key_Return);
                return true;
            },
            w => {
                if (probe.ns.view !== "editor") {
                    if (w < 4000)
                        return "wait";
                    probe.check(false, "keys: Enter opens exactly the highlighted note (the view stayed " + probe.ns.view + ")");
                    return true;
                }
                probe.check(probe.ns.noteKey === m.want, "keys: Enter opens exactly the highlighted note (" + probe.ns.noteKey + ", wanted " + m.want + ")");
                probe.ns.view = "browse";
                return true;
            },
            () => probe.np.morphing || probe.ns.view !== "browse" ? "wait" : true,
            () => {
                // One result of a search: Enter opens it with no highlight shown.
                probe.ns.setQuery("");
                return true;
            },
            () => {
                // The service's search is not running in this probe: hand the store the one-hit list a search would.
                probe.ns.query = "Ideas";
                probe.ns.searchKeys = ["Ideas.md"];
                return probe.mem.g.order.length === 1 && probe.mem.g.searching ? true : "wait";
            },
            () => {
                const g = probe.mem.g;
                g.forceActiveFocus();
                probe.check(!g.kbShown, "keys: no highlight shown for the one-hit Enter");
                tc.keyClick(Qt.Key_Return);
                return true;
            },
            w => {
                if (probe.ns.view !== "editor")
                    return "wait";
                probe.check(true, "keys: Enter opens the only search hit in the editor");
                return true;
            },
            // ---- the words for a note that is not saved, a read-only note, a search nothing matches ----
            () => {
                probe.ns.view = "browse";
                probe.ns.query = "";
                probe.ns.searchKeys = null;
                return true;
            },
            () => probe.np.morphing || probe.ns.view !== "browse" ? "wait" : true,
            () => {
                probe.check(probe.ns.openNote("Welcome.md"), "words: a healthy note opens");
                return true;
            },
            () => probe.ns.view === "editor" && !probe.np.morphing && probe.pane() ? true : "wait",
            w => {
                if (w < 300)
                    return "wait";
                const p = probe.pane();
                probe.check(!!p && p.problem === "" && !p.banded && probe.textShown(p, "Not saved") === null && probe.textShown(p, "Read-only") === null, "words: a healthy note says no problem (" + (p ? JSON.stringify(p.problem) : "no pane") + ")");
                return true;
            },
            () => probe.np.morphing ? "wait" : true,
            () => {
                probe.ns.openNote("Locked/Held.md");
                return true;
            },
            () => probe.ns.noteKey === "Locked/Held.md" && probe.ed && probe.ed.doc && !probe.np.morphing ? true : "wait",
            () => {
                probe.ed.focusBodyAt(probe.pos(0, 0));
                tc.keyClick(Qt.Key_X);
                probe.ns.saveAll();
                return true;
            },
            w => {
                const p = probe.pane();
                const t = p ? probe.textShown(p, "Not saved: ") : null;
                if (!t && w < 6000)
                    return "wait";
                probe.check(!!p && p.problem.indexOf("Not saved: ") === 0 && p.banded, "words: a note whose folder refuses the write says 'Not saved: <reason>' (" + (p ? JSON.stringify(p.problem) : "no pane") + ")");
                probe.check(!!t, "words: and the band shows those words in the popup");
                probe.grab("words_notsaved", () => {});
                return true;
            },
            () => probe.np.morphing ? "wait" : true,
            () => {
                probe.ns.openNote("Zbin.md");
                return true;
            },
            () => probe.ns.noteKey === "Zbin.md" && !probe.np.morphing && probe.pane() ? true : "wait",
            w => {
                if (w < 300)
                    return "wait";
                const p = probe.pane();
                probe.check(!!p && p.problem === "Read-only: not valid UTF-8 text" && !!probe.textShown(p, "Read-only: not valid UTF-8 text"), "words: a note that is not UTF-8 says 'Read-only: not valid UTF-8 text' (" + (p ? JSON.stringify(p.problem) : "no pane") + ")");
                return true;
            },
            () => {
                probe.ns.view = "browse";
                probe.ns.query = "nomatchxyz";
                probe.ns.searchKeys = [];
                return true;
            },
            () => probe.np.morphing ? "wait" : true,
            w => {
                // The popup holds more than one grid (the group card's): the one that shows the words is the one a search reaches.
                const t = probe.findOf(probe.np, it => it.objectName === "notesNoMatch" && it.f > 0);
                if ((!t || t.f < 1) && w < 4000)
                    return "wait";
                probe.check(!!t && t.f === 1 && t.visible && t.text === "No match" && probe.ns.searchKeys.length === 0, "words: a search with no hit says 'No match' (" + (t ? t.f : "no item") + ")");
                probe.grab("words_nomatch", () => {});
                probe.ns.searchKeys = ["Ideas.md"];
                return true;
            },
            w => {
                const t = probe.findOf(probe.np, it => it.objectName === "notesNoMatch" && it.visible);
                if (t && w < 4000)
                    return "wait";
                probe.check(!t, "words: a search with a hit does not say it");
                probe.ns.query = "";
                probe.ns.searchKeys = null;
                return true;
            },
            // ---- notes.jsonc ----
            () => {
                probe.np.escapeBack = true;
                probe.ns.openNote("Welcome.md");
                const r = probe.np.handleEscape();
                probe.check(r === true, "config: escape 'back': the open note takes the key (" + r + ")");
                return true;
            },
            () => probe.np.morphing ? "wait" : true,
            () => {
                probe.check(probe.ns.view === "browse", "config: escape 'back': and the popup is on the tiles (" + probe.ns.view + ")");
                probe.check(probe.np.handleEscape() === false, "config: escape 'back': Escape on the tiles closes");
                probe.np.escapeBack = false;
                probe.ns.openNote("Welcome.md");
                probe.ns.folder = "Projects";
                probe.ns.arriveAt("root");
                probe.check(probe.ns.view === "editor" && probe.ns.folder === "Projects", "config: openAt changes nothing under a popup that is out (" + probe.ns.view + ")");
                probe.ns.release();
                probe.ns.arriveAt("last");
                probe.check(probe.ns.view === "editor" && probe.ns.noteKey === "Welcome.md", "config: openAt 'last' is where it was left");
                probe.ns.arriveAt("root");
                probe.check(probe.ns.view === "browse" && probe.ns.folder === "", "config: openAt 'root' is the tiles of the root (" + probe.ns.view + ", '" + probe.ns.folder + "')");
                probe.ns.arriveAt("new");
                probe.check(probe.ns.view === "editor" && probe.ns.newNote && probe.ns.newNoteFolder === "", "config: openAt 'new' is a new note");
                probe.ns.newName = "..";
                probe.check(probe.ns.service.untitled === "Untitled", "config: a newName no file can have is 'Untitled'");
                probe.ns.newName = "Idea";
                probe.ns.current.doc.replace(0, 0, 0, 0, "words");
                const doc = probe.ns.current.doc;
                probe.ns.arriveAt("new");
                probe.check(probe.ns.newNote && probe.ns.current.doc === doc, "config: openAt 'new' keeps a new note that holds text");
                probe.ns.hold();
                probe.ns.saveAll();
                return true;
            },
            w => {
                if (probe.ns.newNote && w < 4000)
                    return "wait";
                probe.check(probe.ns.noteKey === "Idea.md", "config: a note with no name is 'newName' (" + probe.ns.noteKey + ")");
                probe.np.openTileMenu("Welcome.md", 20, 20);
                const menu = probe.findOf(probe.np, it => it.currentSwatch !== undefined && it.rows && it.rows.length > 0 && it.rows[it.rows.length - 1].id === "delete");
                const asks = () => menu.rows[menu.rows.length - 1].confirm;
                probe.check(!!menu && asks() === "Delete?", "config: a delete asks (" + (menu ? asks() : "no menu") + ")");
                probe.np.confirmDelete = false;
                probe.np.openTileMenu("Welcome.md", 20, 20);
                probe.check(!!menu && asks() === "", "config: confirmDelete false: it does not");
                const link = { href: "https://lares", row: { raw: false } };
                probe.check(!probe.ed._opensLink(link, false, false) && probe.ed._opensLink(link, true, false), "config: linkClick 'ctrl': Ctrl+click opens, a click does not");
                probe.np.linkClick = "click";
                probe.check(probe.ed._opensLink(link, false, false) && !probe.ed._opensLink(link, false, true)
                            && !probe.ed._opensLink({ href: "https://lares", row: { raw: true } }, false, false)
                            && !probe.ed._opensLink({ row: { raw: false } }, false, false),
                            "config: linkClick 'click': a click opens, not with Shift, not in the line being edited");
                return true;
            }
        ];
    }
}
