pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "../../common/components"
import "../../common/system"
import "LauncherModel.js" as M
import "ScriptHeader.js" as H
import "DesktopFile.js" as DF
import "../../notes/data/NotesScan.js" as S

// =============================================================================
// LauncherService.qml -- the launcher's data layer: what can be launched, in
// what order, the folders of the scripts root, and launching it. No visual
// items; it lives bar-side (LauncherBarOwner) and survives the popup.
//
// WHAT IS LISTED.
//   - Every app DesktopEntries lists (it already drops NoDisplay, Hidden and
//     Type=Link, and honours XDG_DATA_HOME over XDG_DATA_DIRS by id) that passes OnlyShowIn / NotShowIn for XDG_CURRENT_DESKTOP
//     (DesktopEntries does NOT: this service reads those two keys from the
//     files itself, appsScanScript), minus launcher.jsonc's `hidden` ids.
//   - The scripts root (launcher.jsonc `scriptsRoot`, default
//     $XDG_CONFIG_HOME/quickshell/launcher/), ONE level of folders deep:
//     executable files (a script: ScriptHeader's `# name:` `# icon:`
//     `# terminal: yes` `# description:`), .desktop files, and links to
//     either. A link to an app's .desktop IS that app ("linked"): it moves
//     the app out of the main list into its folder. Hidden names, nested
//     folders, broken links and anything else are not listed. Everything
//     in the scripts root is shown whatever its NoDisplay / OnlyShowIn say:
//     the user put it there.
//
// KEYS. "app:<desktopId>" for an app in the main list; "f:<path under the
// scripts root>" for everything in the scripts root ("f:Dev" a folder,
// "f:Dev/build.sh" an item in it, "f:Dev/code.desktop" a linked app). An
// IDENTITY names what favourites, frecency and titles are kept under: an
// app's desktop id (so an app keeps them in and out of folders), else
// "scripts:<path>" (carried along when a move renames it).
//
// ROWS. `rows` is the current view -- the query's hits across every level
// (search FLATTENS folders; folders themselves are not hits, pinned ones
// aside), else the open folder's items, else the root -- as a ListModel with
// roles `key` and `rec`, `rec` a QtObject { property var d } kept by pointer
// and mirrored BY KEY: a row that stays is moved (never removed and
// re-added), only `d` is re-assigned, and only when it changed. `serial`
// bumps on every write (a move emits nothing a binding can watch). d is
// FACTS, never a colour:
//   { key, kind: "app"|"script"|"desktop"|"folder", desktopId, name,
//     realName, renamed, genericName, keywords, categories (the .desktop
//     Categories list; the row resolves a colourless icon's fallback hue
//     from it), icon, description, folderKey, folderName, isLink, realPath,
//     linkPath, favorite, pinned, frecency, terminal, matchIndices, minis,
//     count }
// `name` is what the row SHOWS: the user's title when the item was renamed
// (`renamed`), else `realName`, its own. `realPath` is where a link points,
// `linkPath` the link's own absolute path ("" for anything not a link).
// `matchIndices` are positions in `name` (the accent letters; [] outside a
// query or when only another field matched); `minis` are a folder's first
// four item keys in its own order (entry() resolves them); `count` a
// folder's item count; `pinned` a folder pinned for this session.
//
// ORDER. A query ranks by FuzzyMatch score over name / real name (a renamed
// item's own, just below its title) / generic name / keywords (weights
// `searchWeights`), ties by favourite, frecency, name -- whatever the sort;
// the PINNED folders come first, in pin order, whatever the query. Otherwise
// `sortMode`: "default" (favourites, then launched by frecency, then
// never-launched A-Z), "name" (A-Z by the shown name, `sortAscending` flips
// it), "recent" (frecency). A folder sorts as one row, its frecency the
// highest of its items'. Sort, layout, frecency and titles persist in
// state.json (LauncherState, Frecency.js).
//
// THE HIDDEN VIEW (setHiddenView, the sort menu's "Hidden apps"): the list is replaced by launcher.jsonc's
// hidden apps, as ordinary rows, with the sort and the search of any list. A folder on screen is left for it. Their records exist only
// while the view is on, and never in what a normal search reads. It is part of the session: endSession() ends it.
//
// THE SESSION (one opening of the popup; the host calls endSession() when it
// closes). A folder made by a drop HOLDS the cell of the row it was made on:
// sorting would move it to its rank, away from where the user just put it,
// so it keeps that display index for the session, through every rebuild
// (the watch's too), a rename and further drops; a row that LEAVES the
// level before it, whichever way (a drop, a hide, a folder removed, a file
// deleted outside), closes its gap as the grid does and the folder moves up
// with the rows around it. A folder renamed before it has not left: the
// held folder stays where it is. A sort chosen in the menu and
// endSession() let the level sort again. Pins (pinFolder) last as long.
//
// OPS (notes' mechanics, on NotesFileOps' own implementation --
// LauncherFileOps). Each takes a callback cb(ok, result, error), called when
// the op is finished AND the model shows it:
//   makeFolder(target, dragged)  both at the root, neither a folder: a new
//                                "Folder" (+ " N") holding both; result: its key
//   moveInto(key, folderKey)     result: the item's new key
//   moveOut(key)                 back to the root; result: its new key
//   renameFolder(key, name)      result: the folder's new key
//   addForeign(path, folderKey)  a file dropped from a file manager;
//                                result: { key, existed }
//   addDropped(paths, folderKey) what a drop from a file manager is: files and/or directories. One file
//                                is linked as addForeign does. Two or more loose files on the main list become a new GROUP (a folder)
//                                named after their common directory; a dropped DIRECTORY is a group of its
//                                launchable files (executable or .desktop, one level, hidden names left);
//                                inside a folder the files are simply linked there (a group never holds a
//                                group). A system folder, $HOME, a directory with more than `dropGroupMax`
//                                launchable files or none are refused with a reason (dropRefusal(r) is the
//                                launcher's own words for it). result: { key (the first row to show),
//                                keys, groups: [key], existed: [key], refused: [{ path, error }] }; ok
//                                when anything landed or was already listed
//   removeLink(key)              a linked row's symlink removed (never its target)
//   removeFolder(key)            every entry back to the root, then the
//                                folder's directory removed; all or nothing,
//                                and NOTHING is deleted: a script or file
//                                moves (a link stays a link), an app's link
//                                is unlinked (the app is back in the main
//                                list); result: { moved: { key: newKey } };
//                                a folder holding a name the scan does not
//                                list (a hidden one) is left as it is, error
//                                "changed", and one holding a directory that
//                                cannot be listed or entered (chmod 000)
//                                too, error "unreadable"; a link into the
//                                folder (relative or absolute) still
//                                resolves after it
//   showInFileManager(key, real) the file chooser (notes' portal helper) at
//                                the row's folder -- the folder itself, the
//                                folder its file is in (the scripts root for
//                                an app of the main list), or with `real` a
//                                link's TARGET's folder; what is picked there
//                                is linked into the row's level as a drop is;
//                                result: { picked, results }; a cancel is
//                                error "cancel"
// An APP (a DesktopEntry) is only ever LINKED into a folder (`ln -s`, no
// clobber, absolute) and out of one only UNLINKED: its .desktop is never
// moved, renamed or touched. A file of the scripts root is MOVED (mvu:
// verified, noclobber, suffix on a clash). A dropped file is LINKED where
// it is being viewed (absolute link to its real path, the target never
// touched); the same real file already listed is that row ({ existed:
// true }); only a .desktop or an executable is taken (error "type"). A
// folder an op empties is removed. One level only: a folder is never put in
// a folder (error "nesting"). There is no reordering.
//
// RENAME. renameItem(key, title) gives an item a DISPLAY title: shown,
// sorted and searched by, kept in state.json under its identity (so it
// follows a moved script, and an app is renamed in and out of folders),
// while the .desktop file or script behind it is never touched and its own
// name stays searchable. An empty title, or the real name, removes it. A
// folder has no title apart from its directory's name: renameItem renames
// it on disk (renameFolder).
//
// LAUNCH. launch(key, keepOpen) -> LaunchRunner (a scope + setsid for apps,
// a transient service for scripts, see there), records frecency, emits
// launched(key, keepOpen). `dryRun` starts nothing and sets `lastCommand`.
//
// Paths (configPath, favoritesPath, favoritesLegacyPath, statePath, scriptsRootOverride) are set
// at CREATION; the stores are made then (a FileView is never repointed) and
// a later change is ignored with a log line.
// =============================================================================
Scope {
    id: svc

    // ---- wiring (at creation) -------------------------------------------------
    property var notifier: null
    readonly property string _configHome: Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")
    readonly property string _stateHome: Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")
    property string configPath: svc._configHome + "/quickshell/config/launcher.jsonc"
    property string favoritesPath: svc._stateHome + "/lares/launcher/favorites.json"
    // where they lived before (the config dir, i.e. the repo): moved once (FavoritesStore.legacyPath); "" = none
    property string favoritesLegacyPath: svc._configHome + "/quickshell/launcher_favorites.json"
    property string statePath: svc._stateHome + "/lares/launcher/state.json"
    // "" = launcher.jsonc's scriptsRoot (itself "" = the default); a path
    // here wins over the file.
    property string scriptsRootOverride: ""
    property bool dryRun: false
    // A dry launch still records itself (frecency moves) unless this is off: a
    // mockup that replays one row to compare parameters keeps the list's order
    // and the row's place as they were. A real launch always records.
    property bool dryRecords: true
    // The applications dirs, highest precedence first (XDG_DATA_HOME, then
    // XDG_DATA_DIRS), and XDG_CURRENT_DESKTOP's list.
    property var applicationDirs: svc._defaultAppDirs()
    property var currentDesktops: String(Quickshell.env("XDG_CURRENT_DESKTOP") || "").split(":").filter(s => s.length > 0)
    property var searchWeights: ({
            name: 1,
            realName: 0.9,
            genericName: 0.8,
            keywords: 0.6
        })
    property var terminalCommand: ["kitty", "-e"]
    property int watchDelayMs: 150
    // The grid's size from the host (the panel's tune), over launcher.jsonc's
    // rows / columns while >= 1 (clamped as the file's own values are).
    property int rowsOverride: -1
    property int columnsOverride: -1
    // While true a favourite toggle changes the records at once and the
    // favourites FILE later: the host holds it for a flight, because the
    // store's save lands mid-air otherwise (the LLM sidebar's deferred pin).
    // The newest state of every toggled item is written when it drops.
    property bool favWriteHold: false
    // The file chooser helper (notes' own; argv: FOLDER; picked paths on
    // stdout, NUL-terminated; exit 1 = cancelled). A probe points it at a
    // stub: the real one opens a dialog on the desktop.
    // A dropped directory (addDropped) with more launchable files than this is refused: a group is a list
    // the user reads, and a folder of a thousand executables (/usr/bin) is never what was meant.
    property int dropGroupMax: 40
    property string pickerCommand: RepoRoot.dir + "/tools/notes/portal_pick.py"
    // The quick answers (LauncherAnswers): the child's argv ([] = python3 on tools/launcher/answers.py; a probe points it at a
    // stub), the copy command (the text is appended), and a switch.
    property var answerCommand: []
    property var copyCommand: ["wl-copy", "--"]
    property bool answersEnabled: !svc._config || svc._config.answers.enabled
    property string answerScript: RepoRoot.dir + "/tools/launcher/answers.py"

    // ---- state -------------------------------------------------------------------
    // The three stores exist from the service's own Component.onCompleted on
    // (they are made there, with the paths final); a binding over them before
    // that reads null -- bind the settings through the mirrors below instead.
    readonly property var config: svc._config
    readonly property var state: svc._state
    readonly property var favorites: svc._favs
    readonly property int gridColumns: svc.columnsOverride >= 1 ? Math.min(8, svc.columnsOverride) : (svc._config ? svc._config.columns : 2)
    readonly property int gridRows: svc.rowsOverride >= 1 ? Math.min(40, svc.rowsOverride) : (svc._config ? svc._config.rows : 9)
    readonly property bool ready: svc._appsLoaded && svc._appsScanned && svc._fsScanned
    readonly property string scriptsRoot: svc._rootOf(svc.scriptsRootOverride, svc._config ? svc._config.scriptsRoot : "")
    property string query: ""
    property string sortMode: "default"
    property bool sortAscending: true
    property string layout: "list"
    property string folder: ""
    // The list shows the hidden apps (THE HIDDEN VIEW, above). Set through setHiddenView().
    property bool hiddenView: false
    readonly property int serial: svc._serial
    // The pinned folders' keys, in pin order (this session only).
    readonly property var pins: svc._pins
    readonly property ListModel rows: ListModel {
        id: rowsModel
    }
    readonly property int appCount: svc._appCount
    readonly property string lastCommand: runner.lastCommand
    readonly property var notifyKeys: [runner.notifyKey]
    readonly property bool busy: ops.busy

    // The answers of the query (see LauncherAnswers): [] when it is not one. `answerSerial` bumps with every change of them.
    readonly property var answers: svc._answerBox.items
    readonly property int answerSerial: svc._answerBox.serial
    readonly property bool answerRecalling: svc._recallIdx >= 0
    // The child is up / was found missing (python3 or its script): the probes and the log read these.
    readonly property bool answersRunning: svc._answerBox.running
    readonly property bool answersMissing: svc._answerBox.missing
    readonly property bool answersWaiting: svc._answerBox.waiting
    signal launched(string key, bool keepOpen)
    // An answer's text went to the clipboard.
    signal answerCopied(string text)
    signal failed(string key, string message)

    // =========================================================================
    //  Reading
    // =========================================================================

    // The record of any level (root, folder, item in a folder) without the
    // query's matchIndices; a copy, or null.
    function entry(key) {
        const r = svc._base[key];
        return r ? Object.assign({}, r) : null;
    }
    // One level's keys ("" = the root) in the current sort, no query.
    function levelKeys(folderKey) {
        const l = svc._levels[folderKey || ""];
        return l ? l.slice() : [];
    }
    // [{ desktopId, name, icon }] of launcher.jsonc's hidden ids, by name (an
    // id no app has any more is listed by itself).
    function hiddenApps() {
        const ids = svc._config ? svc._config.hidden : [];
        const out = [];
        for (let i = 0; i < ids.length; i++) {
            const e = DesktopEntries.byId(ids[i]);
            const t = svc._state ? svc._state.nameOf(ids[i]) : "";
            out.push({
                desktopId: ids[i],
                name: t.length > 0 ? t : e ? (e.name || ids[i]) : ids[i],
                icon: e ? (e.icon || "") : ""
            });
        }
        out.sort((a, b) => M.natCompare(a.name, b.name));
        return out;
    }
    function identityOf(key) {
        const r = svc._base[key];
        return r ? svc._identity(r) : "";
    }

    // =========================================================================
    //  View
    // =========================================================================

    function setQuery(q) {
        svc.query = String(q === undefined || q === null ? "" : q);
    }
    // Copies an answer's text and remembers the query it answered (Up on an empty query brings it back).
    function copyAnswer(text) {
        svc._answerBox.copy(text);
        if (svc._state)
            svc._state.pushAnswerHistory(svc.query);
    }
    // Up (dir 1: older) / Down (dir -1: newer) through the remembered queries, newest first; the query becomes the one
    // recalled and the answer is asked for again. Down past the newest leaves the recall with an empty query. True when
    // the key was taken. Typing (any other change of the query) leaves the recall.
    function recallStep(dir) {
        const h = svc._state ? svc._state.answerHistory() : [];
        if (svc._recallIdx < 0 && (dir < 0 || h.length === 0 || svc.query !== ""))
            return false;
        const i = Math.min(h.length - 1, svc._recallIdx + dir);
        svc._recalling = true;
        svc._recallIdx = i;
        svc.setQuery(i < 0 ? "" : h[i]);
        svc._recalling = false;
        if (i < 0)
            svc._recallIdx = -1;
        return true;
    }
    // A sort chosen in the menu re-sorts every level: the folders that held
    // their place for the session sort with the rest from here on.
    function setSort(mode, ascending) {
        svc._viewGuard = true;
        svc.sortMode = mode;
        svc.sortAscending = !!ascending;
        svc._viewGuard = false;
        svc._clearHolds();
        svc._persistView();
        svc._refreshView();
    }
    function setLayout(l) {
        if (l === "list" || l === "columns")
            svc.layout = l;
    }
    function openFolder(key) {
        const r = svc._base[key];
        if (!r || r.kind !== "folder")
            return false;
        svc.folder = key;
        return true;
    }
    function closeFolder() {
        svc.folder = "";
    }
    function setHiddenView(on) {
        const want = !!on;
        if (want === svc.hiddenView)
            return;
        svc.hiddenView = want;
        if (want && svc.folder !== "")
            svc.closeFolder();
        svc._rebuild();
    }
    // Re-read the scripts root and the applications dirs (the host calls it
    // on open; the watch covers most changes anyway).
    function refresh() {
        svc._queueFsScan();
        svc._queueAppsScan();
    }
    // The popup closed: the session's pins and held places end with it (a
    // reopen shows every level in its sort), and so does a favourites write
    // hold -- a popup destroyed mid-flight leaves its Binding's `true`
    // behind (a destroyed Binding does not restore its target),
    // and the toggles it held would never be written.
    function endSession() {
        svc.favWriteHold = false;
        if (svc._state && svc.answers.length > 0)
            svc._state.pushAnswerHistory(svc.query);
        svc._recallIdx = -1;
        const wasHidden = svc.hiddenView;
        svc.hiddenView = false;
        if (!wasHidden && svc._pins.length === 0 && Object.keys(svc._holds).length === 0)
            return;
        svc._pins = [];
        svc._clearHolds();
        svc._rebuild();
    }
    // A folder first in every search, whatever the query (always
    // the first result while searching), after the ones pinned before it.
    // False for anything but a folder.
    function pinFolder(key, on) {
        const r = svc._base[key];
        if (!r || r.kind !== "folder")
            return false;
        const want = !!on;
        if ((svc._pins.indexOf(key) >= 0) === want)
            return true;
        svc._pins = want ? svc._pins.concat([key]) : svc._pins.filter(k => k !== key);
        svc._base[key] = Object.assign({}, r, {
            pinned: want
        });
        svc._refreshView();
        return true;
    }

    onQueryChanged: {
        if (!svc._recalling)
            svc._recallIdx = -1;
        svc._answerBox.ask(svc.query);
        svc._refreshView();
    }
    onFolderChanged: svc._refreshView()
    onSortModeChanged: {
        if (svc._viewGuard)
            return;
        svc._persistView();
        svc._refreshView();
    }
    onSortAscendingChanged: {
        if (svc._viewGuard)
            return;
        svc._persistView();
        svc._refreshView();
    }
    onLayoutChanged: {
        if (!svc._viewGuard)
            svc._persistView();
    }

    // =========================================================================
    //  Marks
    // =========================================================================

    // The new favourite state (false for a folder: it has none). The records,
    // the levels and the rows show it when this returns -- a flight asks the
    // model where the row went straight after the toggle (RowFlight's
    // commit); the file follows now, or when favWriteHold drops.
    function toggleFavorite(key) {
        const id = svc.identityOf(key);
        if (id.length === 0 || !svc._favs)
            return false;
        const on = !svc._isFav(id);
        svc._setFav(id, on);
        svc._rebuild();
        return on;
    }
    // A display title; see the header (RENAME). A folder's title is its
    // directory's name: it is renamed on disk (renameFolder, cb as there).
    // An item's cb(ok, key, error) is called once the rows show the title.
    function renameItem(key, title, cb) {
        const r = svc._base[key];
        if (r && r.kind === "folder") {
            svc.renameFolder(key, title, cb);
            return true;
        }
        const id = r ? svc._identity(r) : "";
        if (id.length === 0 || !svc._state) {
            svc.failed(key, "no such item");
            svc._answer(cb, false, null, "missing");
            return false;
        }
        // One line of text; the real name itself (or nothing) is no title.
        let t = String(title === undefined || title === null ? "" : title).replace(/[\u0000-\u001f\u007f]+/g, " ").trim();
        if (t === r.realName)
            t = "";
        if (svc._state.setName(id, t))
            svc._rebuild();
        svc._answer(cb, true, key, "");
        return true;
    }
    // Apps only (a script is deleted, not hidden); hidden everywhere, its
    // folder included. False (and failed()) when launcher.jsonc cannot be
    // written -- see LauncherConfig: a file with an error is never replaced.
    function hide(key) {
        const r = svc._base[key];
        if (!r || r.kind !== "app") {
            svc.failed(key, "only an app can be hidden");
            return false;
        }
        return svc._setHidden(key, r.desktopId, true);
    }
    function unhide(desktopId) {
        return svc._setHidden("app:" + desktopId, String(desktopId || ""), false);
    }
    function _setHidden(key, id, on) {
        if (!svc._config)
            return false;
        const err = svc._config.setHidden(id, on);
        if (err.length > 0) {
            svc.failed(key, err);
            return false;
        }
        return true;
    }

    // =========================================================================
    //  Launch
    // =========================================================================

    function launch(key, keepOpen) {
        const r = svc._base[key];
        const how = svc._how[key];
        if (!r || !how || r.kind === "folder") {
            svc.failed(key, r ? "a folder is opened, not launched" : "no such item");
            return false;
        }
        if (how.script) {
            // A failure is announced under the name the row shows.
            runner.launchScript(Object.assign({}, how.script, {
                name: r.name
            }));
        } else {
            if (!how.app.command || how.app.command.length === 0) {
                svc.failed(key, r.name + " has no command");
                return false;
            }
            runner.launchApp(how.app);
        }
        if (svc._state && (!svc.dryRun || svc.dryRecords))
            svc._state.recordLaunch(svc._identity(r), Date.now());
        svc.launched(key, !!keepOpen);
        return true;
    }

    // =========================================================================
    //  Folder ops -- cb(ok, result, error) once the model shows the result
    // =========================================================================

    function makeFolder(targetKey, draggedKey, cb) {
        svc._op(cb, targetKey, () => {
            const t = svc._base[targetKey], d = svc._base[draggedKey];
            if (!t || !d)
                return svc._fail("missing");
            if (targetKey === draggedKey)
                return svc._fail("same");
            if (t.kind === "folder" || d.kind === "folder" || t.folderKey !== "" || d.folderKey !== "")
                return svc._fail("nesting");
            const a = svc._putSpec(t), b = svc._putSpec(d);
            if (!a || !b)
                return svc._fail("path");
            return {
                step: {
                    script: ops.folderScript,
                    args: [svc.scriptsRoot, a.mode, a.src, a.base, a.ext, b.mode, b.src, b.base, b.ext]
                },
                done: res => {
                    const g = svc._tags(res);
                    if (!g.G)
                        return svc._fail(g.E || "mkdir");
                    const carry = [];
                    if (g.T && a.mode === "move")
                        carry.push([svc._identity(t), "scripts:" + g.G + "/" + g.T]);
                    if (g.D && b.mode === "move")
                        carry.push([svc._identity(d), "scripts:" + g.G + "/" + g.D]);
                    if (!g.T || !g.D)
                        return svc._fail(g.E || "move", carry);
                    const nk = "f:" + g.G;
                    // The folder takes the target's cell as the grid shows
                    // it during the drag (the dragged row's gap closed):
                    // the level without the dragged row, the target
                    // replaced by the folder. The rebuild alone would read
                    // the target as a row that LEFT and close its cell.
                    return svc._ok(nk, carry, [], null, () => svc._hold("", nk, svc.levelKeys("").filter(k => k !== draggedKey).map(k => k === targetKey ? nk : k)));
                }
            };
        });
    }

    function moveInto(key, folderKey, cb) {
        svc._op(cb, key, () => {
            const r = svc._base[key], f = svc._base[folderKey];
            if (!r || !f)
                return svc._fail("missing");
            if (f.kind !== "folder" || r.kind === "folder")
                return svc._fail("nesting");
            if (r.folderKey === folderKey)
                return svc._ok(key, []);
            const dest = svc._abs(folderKey);
            if (r.kind === "app" && !r.isLink) {
                const a = svc._putSpec(r);
                if (!a)
                    return svc._fail("path");
                return {
                    step: {
                        script: ops.foreignLinkScript,
                        args: [svc.scriptsRoot, a.src, dest, a.base, a.ext]
                    },
                    done: res => {
                        const t = svc._tags(res);
                        return t.N ? svc._ok(svc._child(folderKey, t.N), []) : svc._fail(t.E || "link");
                    }
                };
            }
            const nm = svc._split(svc._baseName(key));
            const srcDir = r.folderKey === "" ? svc.scriptsRoot : svc._abs(r.folderKey);
            return {
                step: {
                    script: ops.moveScript,
                    args: [svc.scriptsRoot, svc._abs(key), dest, nm.base, nm.ext, srcDir]
                },
                done: res => {
                    const t = svc._tags(res);
                    if (!t.N)
                        return svc._fail(svc._mvError(t.E));
                    const nk = svc._child(folderKey, t.N);
                    const carry = r.kind === "app" ? [] : [[svc._identity(r), "scripts:" + nk.substring(2)]];
                    return svc._ok(nk, carry, t.R);
                }
            };
        });
    }

    function moveOut(key, cb) {
        svc._op(cb, key, () => {
            const r = svc._base[key];
            if (!r)
                return svc._fail("missing");
            if (r.folderKey === "")
                return svc._fail("root");
            const dir = svc._abs(r.folderKey);
            if (r.kind === "app") {
                return {
                    step: {
                        script: ops.unlinkScript,
                        args: [svc.scriptsRoot, svc._abs(key), dir]
                    },
                    done: res => {
                        const t = svc._tags(res);
                        if (t.E !== undefined)
                            return svc._fail(t.E);
                        return svc._ok("app:" + r.desktopId, [], t.R);
                    }
                };
            }
            const nm = svc._split(svc._baseName(key));
            return {
                step: {
                    script: ops.moveScript,
                    args: [svc.scriptsRoot, svc._abs(key), svc.scriptsRoot, nm.base, nm.ext, dir]
                },
                done: res => {
                    const t = svc._tags(res);
                    if (!t.N)
                        return svc._fail(svc._mvError(t.E));
                    return svc._ok("f:" + t.N, [[svc._identity(r), "scripts:" + t.N]], t.R);
                }
            };
        });
    }

    // "Remove from list": a LINKED row's symlink goes (a script or a .desktop
    // linked into the scripts root or a folder; a linked app has Remove from
    // folder). Only the link is removed, never what it points to: the script
    // is notes' unlinkScript, which tests `-L` (lstat) at the moment it runs
    // and refuses anything else ("notlink"), and `rm` of a link never
    // follows it. What the launcher keeps by the item's id (star, launches,
    // title) is forgotten with it; a folder it empties goes, as with moveOut.
    // A broken link is never listed (scan), but one the scan saw is removed
    // by its key all the same.
    function removeLink(key, cb) {
        svc._op(cb, key, () => {
            const r = svc._base[key];
            const e = svc._fs.entries[key.substring(2)];
            if (key.indexOf("f:") !== 0 || (r ? (!r.isLink || r.kind === "folder" || r.kind === "app") : (!e || e.y !== "l")))
                return svc._fail("notlink");
            const sl = key.lastIndexOf("/");
            const dir = sl < 0 ? svc.scriptsRoot : svc._abs(key.substring(0, sl));
            return {
                step: {
                    script: ops.unlinkScript,
                    args: [svc.scriptsRoot, svc._abs(key), dir]
                },
                done: res => {
                    const t = svc._tags(res);
                    if (t.E !== undefined)
                        return svc._fail(t.E);
                    if (r)
                        svc._forget(svc._identity(r));
                    return svc._ok(key, [], t.R);
                }
            };
        });
    }
    // Everything kept by an id: its star, its launches, its title.
    function _forget(id) {
        if (id.length === 0)
            return;
        if (svc._isFav(id))
            svc._setFav(id, false);
        if (svc._state)
            svc._state.forgetId(id);
    }

    function renameFolder(key, name, cb) {
        svc._op(cb, key, () => {
            const r = svc._base[key];
            if (!r || r.kind !== "folder")
                return svc._fail("missing");
            const base = svc._sanitize(name);
            if (base.length === 0)
                return svc._fail("name");
            if (base === r.name)
                return svc._ok(key, []);
            const items = svc._members[key] || [];
            return {
                step: {
                    script: ops.renameScript,
                    args: [svc.scriptsRoot, svc._abs(key), svc.scriptsRoot, base, ""]
                },
                done: res => {
                    const t = svc._tags(res);
                    if (!t.N)
                        return svc._fail(svc._mvError(t.E));
                    const carry = [];
                    for (let i = 0; i < items.length; i++) {
                        const it = svc._base[items[i]];
                        if (it && it.kind !== "app")
                            carry.push([svc._identity(it), "scripts:" + t.N + "/" + svc._baseName(items[i])]);
                    }
                    return svc._ok("f:" + t.N, carry, [], {
                        from: key,
                        to: "f:" + t.N
                    });
                }
            };
        });
    }

    // Every entry the scan saw in the folder goes (listed or not: nothing is
    // left behind to keep the directory); a name the scan does not see (a
    // hidden one) makes the script refuse before anything moves.
    function removeFolder(key, cb) {
        svc._op(cb, key, () => {
            const f = svc._base[key];
            if (!f || f.kind !== "folder")
                return svc._fail("missing");
            const rel = key.substring(2);
            const E = svc._fs.entries;
            const names = Object.keys(E).filter(n => n.indexOf(rel + "/") === 0).map(n => n.substring(rel.length + 1)).sort();
            const args = [svc.scriptsRoot, svc._abs(key)];
            for (let i = 0; i < names.length; i++) {
                const nm = svc._split(names[i]);
                args.push(svc._isAppLink(E[rel + "/" + names[i]], names[i]) ? "unlink" : "move", names[i], nm.base, nm.ext);
            }
            return {
                step: {
                    script: ops.removeFolderScript,
                    args: args
                },
                done: res => {
                    const recs = String(res.text || "").split("\u0000");
                    const moved = {}, carry = [];
                    let removed = "", error = "";
                    for (let i = 0; i < recs.length; i++) {
                        const tag = recs[i].charAt(0), v = recs[i].substring(1);
                        if (tag === "M" && i + 1 < recs.length) {
                            const to = recs[++i];
                            moved["f:" + rel + "/" + v] = "f:" + to;
                            carry.push(["scripts:" + rel + "/" + v, "scripts:" + to]);
                        } else if (tag === "U") {
                            const id = svc._linkedIdOf(E[rel + "/" + v]);
                            moved["f:" + rel + "/" + v] = "app:" + id;
                        } else if (tag === "R") {
                            removed = v;
                        } else if (tag === "E" && error === "") {
                            error = v;
                        }
                    }
                    if (removed !== rel)
                        return svc._fail(error || "remove");
                    return svc._ok({
                        moved: moved
                    }, carry, [rel]);
                }
            };
        });
    }

    // The file chooser at the row's folder; what is picked there is linked
    // into the row's level (addForeign, one by one). One at a time: a second
    // call while it is open answers "busy".
    function showInFileManager(key, real, cb) {
        const r = svc._base[key];
        if (!r || portal.running) {
            if (!r)
                svc.failed(key, "no such item");
            svc._answer(cb, false, null, r ? "busy" : "missing");
            return false;
        }
        const dir = p => p.substring(0, p.lastIndexOf("/")) || "/";
        let folder;
        if (r.kind === "folder")
            folder = svc._abs(key);
        else if (real && r.isLink)
            folder = dir(r.realPath);
        else
            folder = key.indexOf("f:") === 0 ? dir(svc._abs(key)) : svc.scriptsRoot;
        svc._portalJob = {
            key: key,
            level: r.kind === "folder" ? key : r.folderKey,
            cb: cb
        };
        portal.command = ["setpriv", "--pdeathsig", "TERM", "--", svc.pickerCommand, folder];
        portal.running = true;
        return true;
    }

    function addForeign(path, folderKey, cb) {
        const src = String(path || "");
        const fk = folderKey || "";
        svc._op(cb, fk, () => {
            if (src.charAt(0) !== "/")
                return svc._fail("path");
            if (fk !== "" && (!svc._base[fk] || svc._base[fk].kind !== "folder"))
                return svc._fail("missing");
            return {
                step: {
                    script: ops.foreignProbeScript,
                    args: [src]
                },
                done: res => {
                    const c = svc._tags(res);
                    if (c.P === undefined)
                        return svc._fail(c.E || "missing");
                    if (c.F === undefined)
                        return svc._fail("type");
                    const plan = svc._foreignPlan(src, c.P, c.X !== undefined, fk !== "");
                    if (plan.error)
                        return svc._fail(plan.error);
                    if (plan.existed)
                        return svc._ok({ key: plan.existed, existed: true }, []);
                    return {
                        step: {
                            script: ops.foreignLinkScript,
                            args: [svc.scriptsRoot, plan.target, fk === "" ? svc.scriptsRoot : svc._abs(fk), plan.base, plan.ext]
                        },
                        done: res2 => {
                            const t = svc._tags(res2);
                            if (!t.N)
                                return svc._fail(t.E || "link");
                            return svc._ok({ key: svc._child(fk, t.N), existed: false }, []);
                        }
                    };
                }
            };
        });
    }

    // What a dropped file (its path as dropped, its real path, whether it is executable) is to the list:
    // { error } | { existed: the key it already has } | { target (what the link points at), base, ext }.
    // `inFolder`: it will be linked into a folder (an app already listed on the main list is then moved
    // there by its link; on the main list it is already what the user sees).
    function _foreignPlan(src, real, executable, inFolder) {
        const canon = svc._fs.canon;
        // A file of the scripts root itself is its own row.
        if (canon.length > 0 && real.indexOf(canon + "/") === 0) {
            const k = svc._keyOfReal(real, false);
            return k ? { existed: k } : { error: "type" };
        }
        const isDesktop = /\.desktop$/i.test(real) || /\.desktop$/i.test(src);
        let target = real;
        if (isDesktop) {
            const id = svc._appIdOfPath(src) || svc._appIdOfPath(real) || svc._appByReal[real] || "";
            if (id.length > 0 && svc._appInfo[id]) {
                const shown = svc._linkedApp[id] || ("app:" + id);
                if (!inFolder || svc._linkedApp[id])
                    return { existed: shown };
                target = svc._appFiles[id].path;
            }
        } else if (!executable) {
            return { error: "type" };
        }
        const known = svc._keyOfReal(real, true);
        if (known)
            return { existed: known };
        const nm = svc._split(svc._sanitize(src.substring(src.lastIndexOf("/") + 1)) || "item");
        return { target: target, base: nm.base, ext: nm.ext };
    }

    // ---- several files, or a directory, dropped at once ----------------------------------------------------

    // System folders a drop never makes a group of (a top-level directory of / is one too, and so is the
    // home).
    readonly property var _systemFolders: ["/usr/bin", "/usr/sbin", "/usr/lib", "/usr/lib64", "/usr/local", "/usr/local/bin", "/usr/share", "/var/lib", "/var/log"]
    function _isSystemFolder(real) {
        const home = String(Quickshell.env("HOME") || "");
        if (real === "/" || real === home || real.indexOf("/", 1) < 0)
            return true;
        return svc._systemFolders.indexOf(real) >= 0;
    }
    // The launcher's own words for a refusal { path, error }.
    function dropRefusal(r) {
        const path = String(r.path || "");
        const name = path.substring(path.lastIndexOf("/") + 1) || path;
        switch (r.error) {
        case "system":
            return name + " is a system folder, not a group of your own";
        case "home":
            return "Your home folder is too much to make a group of";
        case "toomany":
            return name + " has over " + svc.dropGroupMax + " programs. Drop the ones you want";
        case "empty":
            return "Nothing in " + name + " can be launched";
        case "nesting":
            return "No group inside a group. Drop " + name + " on the main list";
        case "inlist":
            return name + " is already in the list";
        case "type":
            return name + " is not a program or a .desktop file";
        case "missing":
            return name + " is not there any more";
        default:
            return name + " could not be added";
        }
    }
    // The name a group of loose files takes: the directory they share (the first one's, when they come from
    // several).
    function _groupNameOf(reals) {
        const dirs = reals.map(p => p.substring(0, p.lastIndexOf("/")));
        const base = dirs[0].substring(dirs[0].lastIndexOf("/") + 1);
        return svc._sanitize(base) || "Dropped";
    }
    // The probe's records into [{ path, real, dir, error, files: [{ src, real, f, x, error }] }].
    function _parseDrop(text, paths) {
        const out = [];
        let a = null, c = null;
        const recs = String(text || "").split("\u0000");
        for (let i = 0; i < recs.length; i++) {
            const s = recs[i];
            if (s.length === 0)
                continue;
            const tag = s.charAt(0), v = s.substring(1);
            if (tag === "A") {
                a = { path: paths[out.length], real: "", dir: false, error: "", files: [] };
                c = null;
                out.push(a);
            } else if (!a) {
                continue;
            } else if (tag === "/") {
                c = null;
            } else if (tag === "C") {
                c = { src: "", real: "", f: false, x: false, error: "" };
                a.files.push(c);
            } else {
                const o = c || a;
                if (tag === "P")
                    o.real = v;
                else if (tag === "S")
                    o.src = v;
                else if (tag === "F")
                    o.f = true;
                else if (tag === "X")
                    o.x = true;
                else if (tag === "D")
                    a.dir = true;
                else if (tag === "E")
                    o.error = v;
            }
        }
        return out;
    }

    function addDropped(paths, folderKey, cb) {
        const list = (paths || []).map(p => String(p || ""));
        const fk = folderKey || "";
        svc._op(cb, fk, () => {
            if (list.length === 0)
                return svc._fail("path");
            for (const p of list) {
                if (p.charAt(0) !== "/")
                    return svc._fail("path");
            }
            if (fk !== "" && (!svc._base[fk] || svc._base[fk].kind !== "folder"))
                return svc._fail("missing");
            return {
                step: {
                    script: ops.dropProbeScript,
                    args: [String(svc.dropGroupMax)].concat(list)
                },
                done: res => svc._dropPlan(svc._parseDrop(res.text, list), fk)
            };
        });
    }

    // The probe's answer into the jobs to run (a group per directory, one for the loose files) and what is
    // refused or already listed, then the jobs one after the other.
    function _dropPlan(args, fk) {
        const jobs = [], refused = [], existed = [], loose = [], seen = {};
        const home = String(Quickshell.env("HOME") || "");
        const canon = svc._fs.canon;
        // A member of a directory's group: nothing is said about one that is no launchable file (the probe
        // listed only those), one already listed is `existed`.
        const members = (files) => {
            const out = [];
            for (const f of files) {
                if (f.error || !f.f || seen[f.real])
                    continue;
                seen[f.real] = true;
                const m = svc._foreignPlan(f.src, f.real, f.x, true);
                if (m.existed)
                    existed.push(m.existed);
                else if (!m.error)
                    out.push(m);
            }
            return out;
        };
        for (const a of args) {
            if (a.error) {
                refused.push({ path: a.path, error: a.error });
            } else if (a.dir) {
                const why = fk !== "" ? "nesting" : a.real === home ? "home" : svc._isSystemFolder(a.real) ? "system"
                    : (canon.length > 0 && (a.real === canon || a.real.indexOf(canon + "/") === 0)) ? "inlist"
                    : a.files.length > svc.dropGroupMax ? "toomany" : a.files.length === 0 ? "empty" : "";
                if (why !== "") {
                    refused.push({ path: a.real, error: why });
                    continue;
                }
                const ms = members(a.files);
                if (ms.length > 0)
                    jobs.push({ name: svc._sanitize(a.real.substring(a.real.lastIndexOf("/") + 1)) || "Dropped", members: ms });
            } else if (!a.f) {
                refused.push({ path: a.path, error: "type" });
            } else if (!seen[a.real]) {
                seen[a.real] = true;
                loose.push({ src: a.path, real: a.real, x: a.x });
            }
        }
        // Loose files: two or more on the main list make a group, one is linked as a single drop is, and in
        // a folder they are all linked there.
        const plan = (l, into) => svc._foreignPlan(l.src, l.real, l.x, into);
        const asGroup = fk === "" && loose.length >= 2;
        const planned = [];
        for (const l of loose) {
            const m = plan(l, fk !== "" || asGroup);
            if (m.existed)
                existed.push(m.existed);
            else if (m.error)
                refused.push({ path: l.src, error: m.error });
            else
                planned.push({ l: l, m: m });
        }
        if (fk === "" && planned.length >= 2) {
            jobs.push({ name: svc._groupNameOf(planned.map(x => x.l.real)), members: planned.map(x => x.m) });
        } else {
            for (const x of planned) {
                const m = asGroup ? plan(x.l, false) : x.m;
                if (m.existed)
                    existed.push(m.existed);
                else
                    jobs.push({ single: m });
            }
        }
        const out = { key: "", keys: [], groups: [], existed: existed, refused: refused };
        const finish = () => {
            if (out.key === "" && existed.length > 0)
                out.key = existed[0];
            if (out.keys.length === 0 && existed.length === 0)
                return Object.assign(svc._fail(refused.length > 0 ? refused[0].error : "type"), { result: out });
            return svc._ok(out, []);
        };
        const run = i => {
            if (i >= jobs.length)
                return finish();
            const j = jobs[i];
            const land = key => {
                out.keys.push(key);
                if (out.key === "")
                    out.key = key;
            };
            if (j.single) {
                return {
                    step: {
                        script: ops.foreignLinkScript,
                        args: [svc.scriptsRoot, j.single.target, fk === "" ? svc.scriptsRoot : svc._abs(fk), j.single.base, j.single.ext]
                    },
                    done: res => {
                        const t = svc._tags(res);
                        if (!t.N)
                            return svc._fail(t.E || "link");
                        land(svc._child(fk, t.N));
                        return run(i + 1);
                    }
                };
            }
            const args = [svc.scriptsRoot, j.name];
            for (const m of j.members)
                args.push(m.target, m.base, m.ext);
            return {
                step: {
                    script: ops.dropGroupScript,
                    args: args
                },
                done: res => {
                    const g = svc._tags(res);
                    if (!g.G)
                        return svc._fail(g.E || "mkdir");
                    out.groups.push("f:" + g.G);
                    land("f:" + g.G);
                    return run(i + 1);
                }
            };
        };
        return run(0);
    }

    // =========================================================================
    //  Internals
    // =========================================================================

    property int _recallIdx: -1
    property bool _recalling: false
    readonly property LauncherAnswers _answerBox: LauncherAnswers {
        enabled: svc.answersEnabled
        command: svc.answerCommand
        script: svc.answerScript
        kinds: svc._config ? svc._config.answers.kinds : []
        homeCurrency: svc._config ? svc._config.answers.homeCurrency : "EUR"
        currencies: svc._config ? svc._config.answers.currencies : []
        copyCommand: svc.copyCommand
        onCopied: text => svc.answerCopied(text)
    }

    property var _config: null
    property var _state: null
    property var _favs: null
    property bool _fixed: false
    property bool _viewGuard: false
    property string _followFolder: ""
    property bool _appsLoaded: false
    property bool _appsScanned: false
    property bool _appsScannedOnce: false
    property bool _fsScanned: false
    property int _serial: 0
    property int _appCount: 0

    // What the scans found.
    property var _appFiles: ({})       // id -> { path, real, only: [], not: [] }
    property var _appByReal: ({})      // realpath -> id
    property var _appDirList: []       // the dirs the last apps scan read
    property var _fs: ({
            exists: false,
            canon: "",
            entries: {}
        })

    // What the last build made of them.
    property var _base: ({})           // key -> record (a fresh object per version)
    property var _how: ({})            // key -> { app: spec } | { script: spec }
    property var _appInfo: ({})        // id -> the DesktopEntry's facts (listed apps)
    property var _linkedApp: ({})      // id -> the key of its link in a folder
    property var _members: ({})        // level key -> [keys], unsorted
    property var _levels: ({})         // level key -> [keys], sorted
    // What _levels was sorted for (mutated in place: read inside the view's
    // refresh, never bound).
    readonly property var _levelsFor: ({
            members: null,
            mode: "",
            asc: true
        })
    property var _searchable: []       // every record, folders too (a folder's name is a hit like an app's), no hidden row
    property var _hiddenRows: []       // the hidden view's keys
    property var _rowKeys: []          // rowsModel's keys, in row order
    property var _rowFp: ({})          // key -> JSON of the d the row holds
    property var _rowD: ({})           // key -> the record object it was made from

    function _defaultAppDirs() {
        const home = Quickshell.env("HOME");
        const dh = Quickshell.env("XDG_DATA_HOME") || (home + "/.local/share");
        const dd = String(Quickshell.env("XDG_DATA_DIRS") || "/usr/local/share:/usr/share").split(":").filter(s => s.length > 0);
        return [dh].concat(dd).map(d => svc._trim(d) + "/applications");
    }
    function _trim(p) {
        let s = String(p || "");
        while (s.length > 1 && s.charAt(s.length - 1) === "/")
            s = s.substring(0, s.length - 1);
        return s;
    }
    function _rootOf(override, fromConfig) {
        const v = String(override || fromConfig || "");
        if (v.length === 0)
            return svc._trim(svc._configHome + "/quickshell/launcher");
        if (v === "~" || v.indexOf("~/") === 0)
            return svc._trim(Quickshell.env("HOME") + v.substring(1));
        if (v.charAt(0) === "/")
            return svc._trim(v);
        return svc._trim(svc._configHome + "/quickshell/" + v);
    }
    function _abs(key) {
        return svc.scriptsRoot + "/" + key.substring(2);
    }
    function _child(folderKey, name) {
        return folderKey === "" ? "f:" + name : folderKey + "/" + name;
    }
    function _baseName(key) {
        const rel = key.substring(2);
        return rel.substring(rel.lastIndexOf("/") + 1);
    }
    function _split(name) {
        const dot = name.lastIndexOf(".");
        return dot > 0 ? {
            base: name.substring(0, dot),
            ext: name.substring(dot)
        } : {
            base: name,
            ext: ""
        };
    }
    // A user-typed name made safe for a file name (NotesScan.sanitize's
    // rule): control characters become spaces, "/" becomes "-", leading dots
    // and surrounding space go.
    function _sanitize(s) {
        let t = String(s === undefined || s === null ? "" : s);
        t = t.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\//g, "-");
        return t.trim().replace(/^\.+/, "").trim();
    }
    function _identity(r) {
        if (r.kind === "app")
            return r.desktopId;
        if (r.kind === "folder")
            return "";
        return "scripts:" + r.key.substring(2);
    }
    function _idOf(dir, path) {
        let rel = path.substring(dir.length + 1);
        if (/\.desktop$/.test(rel))
            rel = rel.substring(0, rel.length - 8);
        return rel.split("/").join("-");
    }
    function _appIdOfPath(p) {
        const s = String(p || "");
        if (!/\.desktop$/.test(s))
            return "";
        for (let i = 0; i < svc._appDirList.length; i++) {
            const d = svc._appDirList[i];
            if (s.indexOf(d + "/") === 0) {
                const id = svc._idOf(d, s);
                return svc._appFiles[id] && svc._appFiles[id].path === s ? id : "";
            }
        }
        return "";
    }
    // The app a link in the scripts root stands for (its target is one of
    // the applications dirs' .desktop files), or "".
    function _linkedIdOf(e) {
        if (!e || e.y !== "l")
            return "";
        return svc._appIdOfPath(e.link.charAt(0) === "/" ? e.link : "") || svc._appByReal[e.real] || "";
    }
    // A link that IS an app's row (listed, or hidden): taking it out of a
    // folder unlinks it, as moveOut does.
    function _isAppLink(e, name) {
        if (!/\.desktop$/i.test(name))
            return false;
        const id = svc._linkedIdOf(e);
        return id.length > 0 && (!!svc._appInfo[id] || (!!svc._config && svc._config.isHidden(id)));
    }
    // The key of the listed row whose real file is `real` (links only when
    // `linksOnly`), or "".
    function _keyOfReal(real, linksOnly) {
        for (const k in svc._base) {
            const r = svc._base[k];
            if (r.kind === "folder" || k.indexOf("f:") !== 0)
                continue;
            if (linksOnly && !r.isLink)
                continue;
            if (r.realPath === real)
                return k;
        }
        return "";
    }
    // How a root record goes into a new folder: an app is linked (its
    // .desktop where the applications dir has it), a file of the scripts
    // root is moved.
    function _putSpec(r) {
        if (r.kind === "app" && !r.isLink) {
            const f = svc._appFiles[r.desktopId];
            if (!f)
                return null;
            const nm = svc._split(f.path.substring(f.path.lastIndexOf("/") + 1));
            return {
                mode: "link",
                src: f.path,
                base: nm.base,
                ext: nm.ext
            };
        }
        const nm = svc._split(svc._baseName(r.key));
        return {
            mode: "move",
            src: svc._abs(r.key),
            base: nm.base,
            ext: nm.ext
        };
    }

    // ---- ops plumbing -----------------------------------------------------------

    // `place`: the op's part in the session's held places, run inside the
    // rebuild that shows the op, after it re-read the holds for the rows that
    // left (the levels are still the ones the user saw when it ran): an op
    // that put something in a leaving row's cell says so there, and its
    // order wins.
    function _ok(result, carry, removed, rename, place) {
        return {
            ok: true,
            result: result,
            error: "",
            carry: carry || [],
            removed: removed || [],
            rename: rename || null,
            place: place || null
        };
    }
    function _fail(error, carry) {
        return {
            ok: false,
            result: null,
            error: error,
            carry: carry || [],
            removed: [],
            rename: null,
            place: null
        };
    }
    function _answer(cb, ok, result, error) {
        if (typeof cb !== "function")
            return;
        try {
            cb(ok, result, error);
        } catch (e) {
            console.log("LauncherService: an op callback threw: " + e);
        }
    }
    function _mvError(code) {
        return code === "2" ? "missing" : code === "3" ? "full" : code === "4" ? "move" : (code || "move");
    }
    // An op's NUL records by tag: { N, G, T, D, P, F, X, E: first value,
    // R: [removed folder rels] }.
    function _tags(res) {
        const out = {
            R: []
        };
        const recs = String(res.text || "").split("\u0000");
        for (let i = 0; i < recs.length; i++) {
            const s = recs[i];
            if (s.length === 0)
                continue;
            const tag = s.charAt(0), v = s.substring(1);
            if (tag === "R")
                out.R.push(v);
            else if (out[tag] === undefined)
                out[tag] = v;
        }
        return out;
    }

    // A job on the queue: start() -> outcome | { step, done }; done(res)
    // likewise; the scripts root is rescanned on the same job, then the
    // outcome is applied and cb called.
    function _op(cb, key, start) {
        const job = {
            h: null,
            out: null,
            scanning: false
        };
        const settle = o => {
            if (o.step) {
                job.h = o.done;
                return o.step;
            }
            job.out = o;
            job.scanning = true;
            return svc._fsStep();
        };
        job.next = res => {
            if (res === null)
                return settle(svc.scriptsRoot.length > 0 ? start() : svc._fail("root"));
            if (job.scanning) {
                svc._applyFs(res);
                svc._finishOp(job.out, key, cb);
                svc._fsScanned = true;
                return null;
            }
            return settle(job.h(res));
        };
        ops.enqueue(job, false);
    }
    function _finishOp(o, key, cb) {
        for (let i = 0; i < o.carry.length; i++)
            svc._carry(o.carry[i][0], o.carry[i][1]);
        // The open folder follows its rename, and so do its pin and its held
        // place; one an op removed closes (_refreshView).
        svc._followFolder = o.rename && svc.folder === o.rename.from ? o.rename.to : "";
        if (o.rename)
            svc._renameSession(o.rename.from, o.rename.to);
        svc._rebuild(o.place);
        svc._followFolder = "";
        if (!o.ok)
            svc.failed(key, o.error);
        svc._answer(cb, o.ok, o.result, o.error);
    }
    // Favourite, frecency and title follow a script that moved.
    function _carry(oldId, newId) {
        if (oldId === newId || oldId.length === 0)
            return;
        if (svc._isFav(oldId)) {
            svc._setFav(oldId, false);
            svc._setFav(newId, true);
        }
        if (svc._state)
            svc._state.renameId(oldId, newId);
    }

    // ---- favourites under the write hold ------------------------------------------

    // id -> the state a toggle gave it while favWriteHold was up; it wins
    // over the store until the hold drops and it is written.
    property var _favPending: ({})
    function _isFav(id) {
        if (id.length === 0)
            return false;
        if (Object.prototype.hasOwnProperty.call(svc._favPending, id))
            return svc._favPending[id];
        return !!svc._favs && svc._favs.isFavorite(id);
    }
    function _setFav(id, on) {
        if (svc.favWriteHold) {
            svc._favPending[id] = on;
            return;
        }
        if (!svc._favs)
            return;
        if (on)
            svc._favs.add(id);
        else
            svc._favs.remove(id);
    }
    // add / remove are no-ops for a state the store already holds, so an
    // item toggled back and forth under the hold writes nothing.
    onFavWriteHoldChanged: {
        if (svc.favWriteHold)
            return;
        const p = svc._favPending;
        svc._favPending = {};
        for (const id in p)
            svc._setFav(id, p[id]);
    }

    // ---- the session: held places and pins -------------------------------------------

    // level key -> { key: the display index it holds }.
    property var _holds: ({})
    property var _pins: []

    // `key` holds its index in `order` (the level as the user sees it after
    // the op), and every other hold of the level is re-read from it too.
    function _hold(lk, key, order) {
        if (!svc._holds[lk])
            svc._holds[lk] = {};
        svc._holds[lk][key] = order.indexOf(key);
        svc._rebaseHolds(lk, order);
    }
    // Every hold of the level re-read from `order`, the level as the user
    // sees it (a held key not in it keeps what it holds).
    function _rebaseHolds(lk, order) {
        const h = svc._holds[lk];
        if (!h)
            return;
        for (const k in h) {
            const i = order.indexOf(k);
            if (i >= 0)
                h[k] = i;
        }
        svc._levelsFor.members = null;
    }
    function _clearHolds() {
        svc._holds = {};
        svc._levelsFor.members = null;
    }
    function _renameSession(from, to) {
        for (const lk in svc._holds) {
            const h = svc._holds[lk];
            if (h[from] !== undefined) {
                h[to] = h[from];
                delete h[from];
            }
        }
        if (svc._holds[from]) {
            svc._holds[to] = svc._holds[from];
            delete svc._holds[from];
        }
        if (svc._pins.indexOf(from) >= 0)
            svc._pins = svc._pins.map(k => k === from ? to : k);
        // A rename is the same row STAYING, held or not, so in the levels the
        // user saw it goes by its new key: read as its old key leaving, it
        // would slide every hold after it a cell toward the front, and its
        // new key's arrival pushes none of them back (an arrival sorts in
        // around the held cells). A held folder keeps its cell; one that is
        // not held goes to its new rank, and the held cells stay put.
        const lv = svc._levels;
        for (const lk in lv)
            if (lv[lk].indexOf(from) >= 0)
                lv[lk] = lv[lk].map(k => k === from ? to : k);
        svc._levelsFor.members = null;
    }
    // A sorted level with its held keys put back at their indices (in index
    // order, so each lands where it was held).
    function _applyHolds(lk, keys) {
        const h = svc._holds[lk];
        if (!h)
            return keys;
        const held = keys.filter(k => h[k] !== undefined).sort((a, b) => h[a] - h[b]);
        if (held.length === 0)
            return keys;
        const out = keys.filter(k => h[k] === undefined);
        for (let i = 0; i < held.length; i++)
            out.splice(Math.min(h[held[i]], out.length), 0, held[i]);
        return out;
    }

    // ---- scans --------------------------------------------------------------------

    function _fsStep() {
        return {
            script: ops.rootScanScript,
            args: [svc.scriptsRoot]
        };
    }
    function _queueFsScan() {
        if (svc._fsQueued)
            return;
        svc._fsQueued = true;
        ops.enqueue({
            next: res => {
                if (res === null) {
                    svc._fsQueued = false;
                    return svc._fsStep();
                }
                svc._applyFs(res);
                svc._rebuild();
                svc._fsScanned = true;
                return null;
            }
        }, false);
    }
    property bool _fsQueued: false

    // The flags that make `ready` come up are set AFTER the rebuild that
    // uses what they announce: a binding on `ready` reads the rows at once.
    function _applyFs(res) {
        svc._fs = svc._parseFs(String(res.text || ""));
        svc._ensureWatch();
    }

    // rootScanScript's records, positionally (see LauncherFileOps).
    function _parseFs(text) {
        const recs = text.split("\u0000");
        const out = {
            exists: false,
            canon: "",
            entries: {}
        };
        let i = 0;
        if (recs.length === 0 || recs[0].charAt(0) !== "R")
            return out;
        out.exists = true;
        out.canon = recs[i++].substring(1);
        const E = out.entries;
        while (i + 1 < recs.length && recs[i] !== "/x") {
            const e = recs[i], link = recs[i + 1];
            i += 2;
            if (e.charAt(0) !== "E")
                break;
            const t1 = e.indexOf("\t"), t2 = e.indexOf("\t", t1 + 1);
            if (t1 < 0 || t2 < 0)
                continue;
            const rel = e.substring(t2 + 1);
            E[rel] = {
                y: e.substring(1, t1),
                Y: e.substring(t1 + 1, t2),
                link: link,
                exec: false,
                real: out.canon + "/" + rel,
                head: ""
            };
        }
        i++;
        while (i < recs.length && recs[i] !== "/p") {
            if (E[recs[i]])
                E[recs[i]].exec = true;
            i++;
        }
        i++;
        while (i < recs.length && recs[i] !== "/h") {
            const names = [];
            while (i < recs.length && recs[i] !== "")
                names.push(recs[i++]);
            i++;
            for (let k = 0; k < names.length && i < recs.length; k++) {
                const rp = recs[i++];
                if (E[names[k]])
                    E[names[k]].real = rp;
            }
        }
        i++;
        while (i + 1 < recs.length && recs[i] !== "/z") {
            if (E[recs[i]])
                E[recs[i]].head = recs[i + 1];
            i += 2;
        }
        return out;
    }

    function _queueAppsScan() {
        if (svc._appsQueued)
            return;
        svc._appsQueued = true;
        const dirs = svc.applicationDirs.slice();
        ops.enqueue({
            next: res => {
                if (res === null) {
                    svc._appsQueued = false;
                    return {
                        script: ops.appsScanScript,
                        args: dirs
                    };
                }
                svc._applyApps(dirs, String(res.text || ""));
                svc._appsScannedOnce = true;
                svc._rebuild();
                svc._appsScanned = true;
                return null;
            }
        }, false);
    }
    property bool _appsQueued: false

    // appsScanScript's records: per dir "#<dir>", then batches of paths, "",
    // realpaths, "<path>\t<only>\t<not>" records, "". The first dir to have
    // an id wins it (XDG precedence, as DesktopEntries resolves it).
    function _applyApps(dirs, text) {
        const recs = text.split("\u0000");
        const files = {}, byReal = {};
        const list = v => String(v || "").split(";").map(s => s.trim()).filter(s => s.length > 0);
        let dir = "";
        let i = 0;
        while (i < recs.length) {
            const r = recs[i];
            if (r.length === 0) {
                i++;
                continue;
            }
            if (r.charAt(0) === "#") {
                dir = r.substring(1);
                i++;
                continue;
            }
            const names = [];
            while (i < recs.length && recs[i] !== "")
                names.push(recs[i++]);
            i++;
            const reals = [];
            for (let k = 0; k < names.length; k++)
                reals.push(i < recs.length ? recs[i++] : "");
            const show = {};
            while (i < recs.length && recs[i] !== "") {
                const a = recs[i++];
                const t2 = a.lastIndexOf("\t"), t1 = t2 > 0 ? a.lastIndexOf("\t", t2 - 1) : -1;
                if (t1 >= 0)
                    show[a.substring(0, t1)] = {
                        only: list(a.substring(t1 + 1, t2)),
                        not: list(a.substring(t2 + 1))
                    };
            }
            i++;
            for (let k = 0; k < names.length; k++) {
                const id = svc._idOf(dir, names[k]);
                if (files[id] === undefined) {
                    const s = show[names[k]];
                    files[id] = {
                        path: names[k],
                        real: reals[k],
                        only: s ? s.only : [],
                        not: s ? s.not : []
                    };
                }
                if (reals[k].length > 0 && byReal[reals[k]] === undefined)
                    byReal[reals[k]] = svc._idOf(dir, names[k]);
            }
        }
        svc._appDirList = dirs;
        svc._appFiles = files;
        svc._appByReal = byReal;
    }

    // ---- the build ----------------------------------------------------------------

    function _list(v) {
        const out = [];
        if (!v)
            return out;
        for (let i = 0; i < v.length; i++)
            out.push(String(v[i]));
        return out;
    }

    // `place`: an op's own part in the held places (_ok).
    function _rebuild(place) {
        if (!svc._fixed)
            return;
        const now = Date.now();
        const st = svc._state, cfg = svc._config;
        const frec = id => id.length > 0 && st ? st.scoreOf(id, now) : 0;
        const hidden = id => !!cfg && cfg.isHidden(id);

        // The listed apps -- none before the applications dirs were read: an
        // app is never listed unfiltered, not even for one frame.
        const info = {};
        const vals = svc._appsScannedOnce ? DesktopEntries.applications.values : [];
        for (let i = 0; i < vals.length; i++) {
            const e = vals[i];
            const id = String(e.id);
            const f = svc._appFiles[id];
            if (f && !DF.showIn(f.only, f.not, svc.currentDesktops))
                continue;
            info[id] = {
                id: id,
                name: String(e.name || id),
                genericName: String(e.genericName || ""),
                keywords: svc._list(e.keywords),
                categories: svc._list(e.categories),
                icon: String(e.icon || ""),
                comment: String(e.comment || ""),
                command: svc._list(e.command),
                workingDirectory: String(e.workingDirectory || ""),
                terminal: !!e.runInTerminal,
                path: f ? f.path : "",
                real: f ? f.real : ""
            };
        }

        const base = {}, how = {}, members = {
            "": []
        }, linked = {};
        const folderName = fk => fk === "" ? "" : fk.substring(2);
        const appRec = (a, key, fk, isLink, real) => ({
                    key: key,
                    kind: "app",
                    desktopId: a.id,
                    name: a.name,
                    genericName: a.genericName,
                    keywords: a.keywords,
                    categories: a.categories,
                    icon: a.icon,
                    description: a.comment,
                    folderKey: fk,
                    folderName: folderName(fk),
                    isLink: isLink,
                    realPath: real,
                    favorite: svc._isFav(a.id),
                    frecency: frec(a.id),
                    terminal: a.terminal,
                    matchIndices: [],
                    minis: [],
                    count: 0
                });
        const appHow = (a, key) => ({
                    app: {
                        key: key,
                        slug: a.id,
                        command: a.command,
                        terminal: a.terminal,
                        workingDirectory: a.workingDirectory
                    }
                });

        // The scripts root: folders first, so their items find them.
        const E = svc._fs.entries;
        const rels = Object.keys(E).sort();
        for (let i = 0; i < rels.length; i++) {
            const rel = rels[i], e = E[rel];
            if (rel.indexOf("/") < 0 && e.y === "d") {
                const k = "f:" + rel;
                members[k] = [];
                base[k] = {
                    key: k,
                    kind: "folder",
                    desktopId: "",
                    name: rel,
                    genericName: "",
                    keywords: [],
                    categories: [],
                    icon: "",
                    description: "",
                    folderKey: "",
                    folderName: "",
                    isLink: false,
                    realPath: e.real,
                    favorite: false,
                    frecency: 0,
                    terminal: false,
                    matchIndices: [],
                    minis: [],
                    count: 0
                };
                members[""].push(k);
            }
        }
        for (let i = 0; i < rels.length; i++) {
            const rel = rels[i], e = E[rel];
            const slash = rel.indexOf("/");
            if (e.Y !== "f")
                continue;               // folders (done), broken links, links to folders, others
            const fk = slash < 0 ? "" : "f:" + rel.substring(0, slash);
            if (fk !== "" && !members[fk])
                continue;
            const key = "f:" + rel;
            const name = rel.substring(slash + 1);
            const isLink = e.y === "l";
            if (/\.desktop$/i.test(name)) {
                const id = svc._linkedIdOf(e);
                if (id.length > 0 && hidden(id))
                    continue;
                if (id.length > 0 && info[id]) {
                    // A linked app: in a folder it moves there; a link at the
                    // root is the app's own row already.
                    if (fk === "")
                        continue;
                    base[key] = appRec(info[id], key, fk, true, e.real);
                    how[key] = appHow(info[id], key);
                    linked[id] = key;
                    members[fk].push(key);
                    continue;
                }
                const p = DF.parse(e.head);
                if (p.type.length > 0 && p.type !== "Application")
                    continue;
                const stem = H.fallbackName(name);
                base[key] = {
                    key: key,
                    kind: "desktop",
                    desktopId: "",
                    name: p.name || stem,
                    genericName: p.genericName,
                    keywords: p.keywords,
                    categories: p.categories,
                    icon: p.icon,
                    description: p.comment,
                    folderKey: fk,
                    folderName: folderName(fk),
                    isLink: isLink,
                    realPath: e.real,
                    favorite: false,
                    frecency: 0,
                    terminal: p.terminal,
                    matchIndices: [],
                    minis: [],
                    count: 0
                };
                how[key] = {
                    app: {
                        key: key,
                        slug: stem,
                        command: DF.execArgv(p.exec),
                        terminal: p.terminal,
                        workingDirectory: p.path
                    }
                };
                members[fk].push(key);
                continue;
            }
            if (!e.exec)
                continue;
            const h = H.parse(e.head, name);
            base[key] = {
                key: key,
                kind: "script",
                desktopId: "",
                name: h.name,
                genericName: "",
                keywords: [],
                categories: [],
                icon: h.icon,
                description: h.description,
                folderKey: fk,
                folderName: folderName(fk),
                isLink: isLink,
                realPath: e.real,
                favorite: false,
                frecency: 0,
                terminal: h.terminal,
                matchIndices: [],
                minis: [],
                count: 0
            };
            how[key] = {
                script: {
                    key: key,
                    slug: H.fallbackName(name),
                    path: svc.scriptsRoot + "/" + rel,
                    name: h.name,
                    terminal: h.terminal
                }
            };
            members[fk].push(key);
        }
        // The favourite and frecency of what the scripts root holds.
        for (const k in base) {
            const r = base[k];
            if (r.kind === "script" || r.kind === "desktop") {
                const id = svc._identity(r);
                r.favorite = svc._isFav(id);
                r.frecency = frec(id);
            }
        }
        // The main list: every listed app not hidden and not linked away.
        let appCount = 0;
        for (const id in info) {
            if (hidden(id) || linked[id])
                continue;
            const key = "app:" + id;
            base[key] = appRec(info[id], key, "", false, info[id].real || info[id].path);
            how[key] = appHow(info[id], key);
            members[""].push(key);
            appCount++;
        }
        // The hidden view's rows: every hidden id as the app it is (an id no app has any more is a row of its own name, to unhide).
        const hiddenRows = [];
        if (svc.hiddenView)
            for (const h of svc.hiddenApps()) {
                const a = info[h.desktopId] || {
                    id: h.desktopId,
                    name: h.name,
                    genericName: "",
                    keywords: [],
                    categories: [],
                    icon: h.icon,
                    comment: "",
                    terminal: false,
                    command: [],
                    workingDirectory: ""
                };
                const key = "app:" + a.id;
                base[key] = appRec(a, key, "", false, a.real || a.path);
                how[key] = appHow(a, key);
                hiddenRows.push(key);
            }
        // Folders: a count, and the frecency of their busiest item.
        for (const fk in members) {
            if (fk === "")
                continue;
            const f = base[fk];
            f.count = members[fk].length;
            let best = 0;
            for (let i = 0; i < members[fk].length; i++)
                best = Math.max(best, base[members[fk][i]].frecency);
            f.frecency = best;
        }
        // Titles (the user's Rename: the row shows, sorts and is searched by
        // it, its real name kept beside it), each link's own path, this
        // session's pins -- and pins and holds of folders that are gone.
        const pins = svc._pins.filter(k => base[k] && base[k].kind === "folder");
        if (pins.length !== svc._pins.length)
            svc._pins = pins;
        // A row that LEFT a level -- dropped away, hidden, a folder removed,
        // a file deleted or an app uninstalled behind the launcher's back --
        // closes its gap there, as the grid closes it for a drag, so what a
        // held folder keeps is the cell it is shown in once the gap has
        // closed: re-read the level's holds from the order the user saw
        // minus the rows that left. Otherwise each row gone from before it
        // slides it a cell on. (A row that ARRIVES sorts in around it: the
        // cell is what is held.)
        for (const lk in svc._holds) {
            if (lk !== "" && !base[lk]) {
                delete svc._holds[lk];
                continue;
            }
            const stays = {};
            for (let i = 0; i < members[lk].length; i++)
                stays[members[lk][i]] = true;
            const shown = svc._levels[lk] || [];
            const kept = shown.filter(k => stays[k] === true);
            if (kept.length < shown.length)
                svc._rebaseHolds(lk, kept);
            for (const k in svc._holds[lk])
                if (!base[k])
                    delete svc._holds[lk][k];
        }
        if (place)
            place();
        for (const k in base) {
            const r = base[k];
            r.realName = r.name;
            r.renamed = false;
            r.linkPath = r.isLink ? svc._abs(k) : "";
            r.pinned = r.kind === "folder" && pins.indexOf(k) >= 0;
            const t = r.kind === "folder" || !st ? "" : st.nameOf(svc._identity(r));
            if (t.length > 0 && t !== r.name) {
                r.name = t;
                r.renamed = true;
            }
        }

        svc._appInfo = info;
        svc._linkedApp = linked;
        svc._base = base;
        svc._how = how;
        svc._members = members;
        svc._hiddenRows = hiddenRows;
        svc._searchable = Object.keys(base).filter(k => hiddenRows.indexOf(k) < 0).map(k => base[k]);
        svc._appCount = appCount;
        svc._refreshView();
    }

    // Sort every level (only when the records or the sort changed: a
    // keystroke does not move a level), give folders their minis, and mirror
    // the view.
    function _refreshView() {
        if (!svc._fixed)
            return;
        const base = svc._base;
        const lf = svc._levelsFor;
        if (lf.members !== svc._members || lf.mode !== svc.sortMode || lf.asc !== svc.sortAscending) {
            const lv = {};
            for (const lk in svc._members)
                lv[lk] = svc._applyHolds(lk, M.sortKeys(svc._members[lk].map(k => base[k]), svc.sortMode, svc.sortAscending));
            for (const lk in lv) {
                if (lk === "")
                    continue;
                const minis = lv[lk].slice(0, 4);
                if (JSON.stringify(minis) !== JSON.stringify(base[lk].minis))
                    base[lk] = Object.assign({}, base[lk], {
                        minis: minis
                    });
            }
            svc._levels = lv;
            lf.members = svc._members;
            lf.mode = svc.sortMode;
            lf.asc = svc.sortAscending;
        }
        const levels = svc._levels;
        if (svc.folder !== "" && !levels[svc.folder]) {
            // re-enters through onFolderChanged
            svc.folder = svc._followFolder !== "" && levels[svc._followFolder] ? svc._followFolder : "";
            return;
        }
        const q = svc.query.trim();
        let keys;
        const marks = {};
        if (q.length > 0) {
            const hits = M.rank(q, svc.hiddenView ? svc._hiddenRows.map(k => base[k]) : svc._searchable, svc.searchWeights);
            // The pinned folders first, matched or not (no letters marked);
            // every other hit -- a folder whose name matches is one, like an
            // app -- follows by score.
            keys = svc.hiddenView ? [] : svc._pins.filter(k => base[k] && base[k].kind === "folder");
            const pinned = {};
            for (let i = 0; i < keys.length; i++)
                pinned[keys[i]] = true;
            for (let i = 0; i < hits.length; i++) {
                if (pinned[hits[i].key] === true)
                    continue;
                keys.push(hits[i].key);
                marks[hits[i].key] = hits[i].nameIndices;
            }
        } else if (svc.hiddenView) {
            keys = M.sortKeys(svc._hiddenRows.map(k => base[k]), svc.sortMode, svc.sortAscending);
        } else {
            keys = levels[svc.folder] || [];
        }
        svc._syncRows(keys, k => marks[k] && marks[k].length > 0 ? Object.assign({}, base[k], {
                matchIndices: marks[k]
            }) : base[k]);
        svc._serial += 1;
    }

    // The ListModel follows `keys` BY KEY: gone rows removed, staying rows
    // MOVED into place, new rows inserted; a row's `d` re-assigned only when
    // its facts changed.
    function _syncRows(keys, dOf) {
        const order = svc._rowKeys;
        const want = {};
        for (let i = 0; i < keys.length; i++)
            want[keys[i]] = true;
        for (let i = order.length - 1; i >= 0; i--) {
            if (want[order[i]] === true)
                continue;
            const rec = rowsModel.get(i).rec;
            rowsModel.remove(i, 1);
            delete svc._rowFp[order[i]];
            delete svc._rowD[order[i]];
            order.splice(i, 1);
            if (rec)
                rec.destroy();
        }
        for (let i = 0; i < keys.length; i++) {
            const k = keys[i];
            const d = dOf(k);
            // The same record object is the same facts (records are never
            // mutated after a build); only a new one is compared.
            const same = svc._rowD[k] === d;
            const fp = same ? svc._rowFp[k] : JSON.stringify(d);
            svc._rowD[k] = d;
            if (order[i] !== k) {
                const j = order.indexOf(k, i + 1);
                if (j >= 0) {
                    rowsModel.move(j, i, 1);
                    order.splice(j, 1);
                    order.splice(i, 0, k);
                } else {
                    rowsModel.insert(i, {
                        key: k,
                        rec: recComp.createObject(svc, {
                            d: d
                        })
                    });
                    order.splice(i, 0, k);
                    svc._rowFp[k] = fp;
                    continue;
                }
            }
            if (svc._rowFp[k] !== fp) {
                rowsModel.get(i).rec.d = d;
                svc._rowFp[k] = fp;
            }
        }
    }
    readonly property Component _recComp: Component {
        id: recComp
        QtObject {
            property var d: ({})
        }
    }

    // ---- sort and layout in state.json ------------------------------------------------

    function _persistView() {
        if (!svc._state)
            return;
        svc._state.setSort(svc.sortMode, svc.sortAscending);
        svc._state.setLayout(svc.layout);
    }
    function _ingestView() {
        if (!svc._state)
            return;
        svc._viewGuard = true;
        svc.sortMode = svc._state.sortMode();
        svc.sortAscending = svc._state.sortAscending();
        svc.layout = svc._state.layout();
        svc._viewGuard = false;
    }

    // ---- the watch ---------------------------------------------------------------------

    function _ensureWatch() {
        if (!svc._fs.exists) {
            if (watch.running)
                watch.running = false;
            return;
        }
        if (watch.running && svc._watchedRoot === svc.scriptsRoot)
            return;
        if (watch.running) {
            svc._watchRestart = true;
            watch.running = false;
            return;
        }
        svc._watchedRoot = svc.scriptsRoot;
        watch.command = ["setpriv", "--pdeathsig", "TERM", "--", "inotifywait", "-m", "-r", "-q", "--no-newline",
            "--format", "%e %w%f%0", "--exclude", "^" + svc._ere(svc.scriptsRoot) + "/(.*/)?\\.",
            "-e", "create,close_write,moved_from,moved_to,delete,delete_self,move_self,attrib", "--", svc.scriptsRoot];
        watch.running = true;
    }
    // Hidden names UNDER the root are not watched; the root's own path may
    // hold a dot-folder (~/.config), so the pattern is anchored at it.
    function _ere(s) {
        return s.replace(/[.[\]()*+?{}|^$\\]/g, "\\$&");
    }
    property string _watchedRoot: ""
    property bool _watchRestart: false
    readonly property Process _watch: Process {
        id: watch
        running: false
        stdout: SplitParser {
            splitMarker: "\u0000"
            onRead: data => watchTimer.restart()
        }
    }
    readonly property Connections _watchExit: Connections {
        target: watch
        function onExited() {
            if (svc._watchRestart) {
                svc._watchRestart = false;
                Qt.callLater(svc._ensureWatch);
            }
        }
    }
    readonly property Timer _watchTimer: Timer {
        id: watchTimer
        interval: svc.watchDelayMs
        onTriggered: svc._queueFsScan()
    }
    onScriptsRootChanged: {
        if (svc._fixed)
            svc._queueFsScan();
    }

    // ---- the file chooser ----------------------------------------------------------------

    property var _portalJob: null      // { key, level, cb } while the chooser is open
    readonly property Process _portal: Process {
        id: portal
        running: false
        stdout: StdioCollector {
            id: portalOut
        }
    }
    readonly property Connections _portalExit: Connections {
        target: portal
        function onExited(exitCode) {
            const job = svc._portalJob;
            svc._portalJob = null;
            if (!job)
                return;
            if (exitCode !== 0) {
                if (exitCode !== 1)
                    svc.failed(job.key, "the file chooser could not be opened");
                svc._answer(job.cb, false, null, exitCode === 1 ? "cancel" : "portal");
                return;
            }
            const paths = S.splitZ(S.bytesOf(portalOut.data), portalOut.text).filter(p => p !== null && p.length > 0);
            const results = [];
            let left = paths.length;
            if (left === 0)
                svc._answer(job.cb, true, {
                    picked: [],
                    results: []
                }, "");
            for (let i = 0; i < paths.length; i++) {
                const at = i;
                svc.addForeign(paths[i], job.level, (ok, res, err) => {
                    results[at] = {
                        path: paths[at],
                        ok: ok,
                        result: res,
                        error: err
                    };
                    if (--left === 0)
                        svc._answer(job.cb, results.every(x => x.ok), {
                            picked: paths,
                            results: results
                        }, "");
                });
            }
        }
    }

    // ---- parts ---------------------------------------------------------------------------

    readonly property LauncherFileOps _ops: LauncherFileOps {
        id: ops
    }
    readonly property LaunchRunner _runner: LaunchRunner {
        id: runner
        dryRun: svc.dryRun
        notifier: svc.notifier
        terminalCommand: svc.terminalCommand
    }
    readonly property Connections _runnerEvents: Connections {
        target: runner
        function onScriptExited(key: string, code: int, message: string) {
            if (code !== 0)
                svc.failed(key, message);
        }
    }
    readonly property Component _configComp: Component {
        id: configComp
        LauncherConfig {}
    }
    readonly property Component _stateComp: Component {
        id: stateComp
        LauncherState {
            historyMax: svc._config ? svc._config.answers.history : 20
        }
    }
    readonly property Component _favComp: Component {
        id: favComp
        FavoritesStore {}
    }

    readonly property Connections _appsEvents: Connections {
        target: DesktopEntries
        function onApplicationsChanged() {
            svc._rebuild();
            svc._appsLoaded = true;
            appsTimer.restart();
        }
    }
    // DesktopEntries scans on first use and says so once it has; an empty
    // system never says anything, so the flag also comes up on its own.
    readonly property Timer _appsTimer: Timer {
        id: appsTimer
        interval: 100
        onTriggered: svc._queueAppsScan()
    }
    readonly property Timer _appsFallback: Timer {
        interval: 3000
        running: !svc._appsLoaded
        onTriggered: {
            svc._rebuild();
            svc._appsLoaded = true;
        }
    }
    readonly property Connections _configEvents: Connections {
        target: svc._config
        function onChanged() {
            svc._rebuild();
        }
    }
    readonly property Connections _stateEvents: Connections {
        target: svc._state
        function onSerialChanged() {
            Qt.callLater(svc._rebuild);
        }
        function onIngested() {
            svc._ingestView();
            svc._refreshView();
        }
    }
    readonly property Connections _favEvents: Connections {
        target: svc._favs
        function onSerialChanged() {
            Qt.callLater(svc._rebuild);
        }
    }

    onConfigPathChanged: svc._fixedWarn("configPath")
    onFavoritesPathChanged: svc._fixedWarn("favoritesPath")
    onFavoritesLegacyPathChanged: svc._fixedWarn("favoritesLegacyPath")
    onStatePathChanged: svc._fixedWarn("statePath")
    function _fixedWarn(what) {
        if (svc._fixed)
            console.log("LauncherService: " + what + " is fixed at creation; the change is ignored");
    }

    Component.onCompleted: {
        svc._config = configComp.createObject(svc, {
            path: svc.configPath
        });
        svc._state = stateComp.createObject(svc, {
            path: svc.statePath
        });
        svc._favs = favComp.createObject(svc, {
            path: svc.favoritesPath,
            legacyPath: svc.favoritesLegacyPath
        });
        svc._ingestView();
        svc._fixed = true;
        if (DesktopEntries.applications.values.length > 0)
            svc._appsLoaded = true;
        svc._queueAppsScan();
        svc._queueFsScan();
    }
}
