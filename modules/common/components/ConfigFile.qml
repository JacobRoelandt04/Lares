pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import "JsonComments.js" as JsonComments
import "ConfigTell.js" as ConfigTell

// =============================================================================
// ConfigFile.qml -- a hand-edited config: `config/<name>.jsonc` first, the `.json` beside it, then the same names one
// level up (where every config lived before 2026-11-12).
//
// A drop-in for a FileView: name the file where it lives (`path: ".../quickshell/config/osd.jsonc"`). This reads that file
// when it exists, else the `.json` beside it, else -- only for a file in a folder named `config` -- `.../quickshell/osd.jsonc`,
// else `.../quickshell/osd.json` (JsonComments.configPaths / pickFile). The first that exists wins and any other that exists is
// ignored; the log says so once. (VS Code takes comments in a `.jsonc` without a word, and flags every one in a `.json`.)
//
// ONE VIEW PER FILE, EACH ON A STATIC PATH (CLAUDE.md: a FileView is never repointed -- the second path's `text()` is the
// first file's bytes): every candidate has its own, and the active one is chosen by which exists, so a file created, moved
// or removed later is followed in place.
//
//   text()          the bytes of the file in force ("" when none exists)
//   exists          one of them does
//   activePath      the file in force; the first candidate (`config/<name>.jsonc`) when none exists (where a first write goes)
//   reload()        every view re-reads (done by itself, `settleMs` after any of the files changed on disk: a write is seen
//                   whole, and a file that appears or goes is followed)
//   setText(t)      writes the file in force; with none, a new first candidate (its folder made first)
//   waitForJob()    blocks until a write in flight is done (a host's onDestruction)
//   loaded()        the file in force has (new) text -- also when it just became the one in force, and once after creation
//                   (a host's handlers are not there yet when the first read happens)
//   loadFailed()    no candidate could be read (also once after creation, when none exists)
//
// Every text it reads is told to ConfigTell.js, so a mistake in it can be said (modules/common/config/ConfigWatch).
//
// A path that is not named *.json / *.jsonc (a probe's fixture) is one file with no sibling.
// =============================================================================
Item {
    id: root

    property string path: ""
    property bool watchChanges: true
    property bool atomicWrites: false
    property bool blockWrites: true
    property int settleMs: 120

    readonly property string jsoncPath: root._pair.jsonc
    readonly property string jsonPath: root._pair.json
    readonly property string oldJsoncPath: root._pair.oldJsonc
    readonly property string oldJsonPath: root._pair.oldJson
    // Bindings on the views themselves (`loaded` flips when a view has read its file; `_prime()` makes that happen before any
    // answer is given): a host's Component.onCompleted runs BEFORE its child's (CLAUDE.md), and its first `text()` must already
    // know which file is in force.
    readonly property bool jsoncExists: jsoncView.loaded
    readonly property bool jsonExists: root.jsonPath.length > 0 && jsonView.loaded
    readonly property bool oldJsoncExists: root.oldJsoncPath.length > 0 && oldJsoncView.loaded
    readonly property bool oldJsonExists: root.oldJsonPath.length > 0 && oldJsonView.loaded
    readonly property bool exists: root.jsoncExists || root.jsonExists || root.oldJsoncExists || root.oldJsonExists
    readonly property string active: JsonComments.pickFile(root.jsoncExists, root.jsonExists, root.oldJsoncExists, root.oldJsonExists)
    readonly property string activePath: root._pathOf(root.active === "" ? "jsonc" : root.active)

    signal loaded()
    signal loadFailed()

    function text(): string {
        root._prime();
        const v = root._viewOf(root.active);
        return v ? v.text() : "";
    }

    // The text of the file in force RIGHT NOW, for a caller that must decide before the first `loaded` arrives (a screen's window is
    // built before it): `active` follows the views' `loaded`, which is still false right after a blocking read (CLAUDE.md "Right after
    // a blocking read `loaded` is false"), so text() says "" then. The candidates in their order, the first with text.
    function textNow(): string {
        root._prime();
        for (const v of root._views()) {
            const t = v.text();
            if (t.length > 0)
                return t;
        }
        return "";
    }
    function reload(): void {
        root._prime();
        for (const v of root._views())
            v.reload();
    }

    function waitForJob(): void {
        for (const v of [jsoncView, jsonView, oldJsoncView, oldJsonView])
            v.waitForJob();
    }

    function setText(t: string): void {
        root._prime();
        const v = root._viewOf(root.active);
        if (v) {
            v.setText(t);
            return;
        }
        // None exists: a new first candidate, in a folder that may not exist yet. A FileView makes no folder, and one made on a
        // path whose folder was missing does not write there once it appears (measured): the folder and the file are made by one
        // child, and the view then reads what it wrote.
        const slash = root.jsoncPath.lastIndexOf("/");
        if (slash <= 0) {
            jsoncView.setText(t);
            return;
        }
        firstWrite.command = ["sh", "-c", 'mkdir -p -- "$1" && printf "%s" "$2" > "$3"', "sh", root.jsoncPath.substring(0, slash), t, root.jsoncPath];
        firstWrite.running = true;
    }

    function _pathOf(which: string): string {
        return which === "json" ? root.jsonPath : (which === "oldJsonc" ? root.oldJsoncPath : (which === "oldJson" ? root.oldJsonPath : root.jsoncPath));
    }
    function _viewOf(which: string): var {
        return which === "jsonc" ? jsoncView : (which === "json" ? jsonView : (which === "oldJsonc" ? oldJsoncView : (which === "oldJson" ? oldJsonView : null)));
    }
    // The views on a path (a candidate a name does not have is no view).
    function _views(): var {
        const out = [jsoncView];
        if (root.jsonPath.length > 0)
            out.push(jsonView);
        if (root.oldJsoncPath.length > 0)
            out.push(oldJsoncView, oldJsonView);
        return out;
    }
    // Every candidate that exists beside the one in force: said once (the ones that are not read).
    function _tellShadowed(): void {
        if (root._told)
            return;
        const there = [["jsonc", root.jsoncExists], ["json", root.jsonExists], ["oldJsonc", root.oldJsoncExists], ["oldJson", root.oldJsonExists]]
            .filter(e => e[1] && e[0] !== root.active).map(e => root._pathOf(e[0]));
        if (root.active === "" || there.length === 0)
            return;
        root._told = true;
        console.warn("ConfigFile: " + root.activePath + " is read; " + there.join(", ") + (there.length === 1 ? " is" : " are") + " ignored");
    }

    readonly property var _pair: JsonComments.configPaths(root.path)
    property bool _told: false
    property string _was: ""
    property bool _primed: false
    property bool _quiet: false

    // A FileView has not read its file until something asks (text() blocks and reads): ask both once, quietly (the answer is the
    // caller's, the events of this first read are not news), so `loaded` -- and with it `active` -- is true before it is used.
    function _prime(): void {
        if (root._primed)
            return;
        root._primed = true;
        root._quiet = true;
        for (const v of root._views())
            v.text();
        root._quiet = false;
        root._was = root.active;
    }

    // What a view reports, and the one thing the host hears: the file in force and its text. An event of a file that is
    // NOT in force (the .json loading again beside a .jsonc, the old place beside config/) changes nothing the host reads, so it
    // is not passed on.
    function _settle(which: string): void {
        if (!root._primed || root._quiet)
            return;
        const now = root.active;
        const before = root._was;
        root._was = now;
        root._tellShadowed();
        if (now !== "" && now === before && which !== now)
            return;
        if (now === "" && before === "" && which !== "jsonc")
            return;
        root._tell();
        if (root.exists)
            root.loaded();
        else
            root.loadFailed();
    }

    function _tell(): void {
        if (root.jsonPath.length > 0)
            ConfigTell.saw(root.jsoncPath, root.text());
    }

    FileView {
        id: jsoncView
        path: root.jsoncPath
        watchChanges: root.watchChanges
        atomicWrites: root.atomicWrites
        blockWrites: root.blockWrites
        blockLoading: true
        printErrors: false
        onFileChanged: if (root.watchChanges) settle.restart()
        onLoaded: root._settle("jsonc")
        onLoadFailed: root._settle("jsonc")
    }

    FileView {
        id: jsonView
        path: root.jsonPath
        watchChanges: root.watchChanges && root.jsonPath.length > 0
        atomicWrites: root.atomicWrites
        blockWrites: root.blockWrites
        blockLoading: true
        printErrors: false
        onFileChanged: if (root.watchChanges) settle.restart()
        onLoaded: root._settle("json")
        onLoadFailed: root._settle("json")
    }

    // Where every config lived before config/ (only for a file in a folder named `config`).
    FileView {
        id: oldJsoncView
        path: root.oldJsoncPath
        watchChanges: root.watchChanges && root.oldJsoncPath.length > 0
        atomicWrites: root.atomicWrites
        blockWrites: root.blockWrites
        blockLoading: true
        printErrors: false
        onFileChanged: if (root.watchChanges) settle.restart()
        onLoaded: root._settle("oldJsonc")
        onLoadFailed: root._settle("oldJsonc")
    }

    FileView {
        id: oldJsonView
        path: root.oldJsonPath
        watchChanges: root.watchChanges && root.oldJsonPath.length > 0
        atomicWrites: root.atomicWrites
        blockWrites: root.blockWrites
        blockLoading: true
        printErrors: false
        onFileChanged: if (root.watchChanges) settle.restart()
        onLoaded: root._settle("oldJson")
        onLoadFailed: root._settle("oldJson")
    }

    // A first write: its folder (config/) and the file, then the view reads it.
    Process {
        id: firstWrite
        running: false
        onExited: jsoncView.reload()
    }

    Timer {
        id: settle
        interval: root.settleMs
        onTriggered: root.reload()
    }

    // The first read happened before any handler existed: say what it found once everything has completed, as a FileView's own
    // first announcement would (a host that reports "no such file" waits for exactly this).
    Timer {
        id: first
        interval: 0
        onTriggered: {
            root._tell();
            if (root.exists)
                root.loaded();
            else
                root.loadFailed();
        }
    }

    Component.onCompleted: {
        root._prime();
        first.start();
        root._tellShadowed();
    }
}
