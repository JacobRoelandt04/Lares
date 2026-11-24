pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../system"

// =============================================================================
// MockupStore -- the file side of a mockup's control panel.
//
// "Save" does two things with the modified values, in one process
// (tools/dev/mockup_promote.py save):
//   - it writes the MODULE: for each row it finds where the module ships that
//     default and writes it there (the module's own declaration, or -- for a
//     component other modules share -- the module's own use of it), refusing
//     what would break (a binding default, a sentinel, a colour literal over a
//     theme token, a protected module). The files it wrote are committed, and
//     the running shell follows, through tools/shell/lares apply --commit.
//     The user's idea (PLAN.md answer 21): the mockups retire as the settings
//     panels of their modules; tweak with live feedback, press Save, done.
//   - it hands the same values to tools/dev/mockup_save_defaults.py, which rewrites
//     the matching `val:` literals in the mockup file and reports each one; what
//     it reports as written becomes the in-memory default too, so the * marks
//     clear without a restart. This half has always been Save to mockup.
// Nothing writes the module from a COPY of the config (tools/dev/sandbox.sh): its
// files are the repo's, so `moduleBlock` says why and only the mockup's val: is
// written (it lands in the repo through MOCKUP_REPO, as before).
//
// A value goes into both in the form its entry holds it: a number as a
// number, a colour as "#RRGGBB", a bool as `val: true` / JSON `true`.
//
// Profiles are one JSON file each under `profileDir`, in the same
// {listId: {prop: value}} shape the save script takes
// (tools/dev/mockup_profiles.py). Its `list` brings every profile's values along,
// so Load is a pure in-memory apply and switching between two sets is
// instant.
//
// One profile is reserved: `default.json` is every registered entry at its
// `val:`, rewritten from the QML at every launch. The `val:` entries are the
// source of truth while designing, but a module deployed into the bar reads
// values from JSON, not from QML -- this is that file. Because it is derived,
// saving over it or deleting it is refused on both sides.
// =============================================================================
Scope {
    id: store

    property MockupRegistry registry: null
    // Absolute path of the file whose `val:` entries a save rewrites.
    property string mockupFile: ""
    // Directory the profile JSON files live in.
    property string profileDir: ""
    readonly property string scriptsDir: RepoRoot.dir + "/tools/dev"

    // ---- Save ---------------------------------------------------------------
    property string saveStatus: ""
    // One line for the strip: what the last Save did to the module (files, commit, refusals)
    property string saveSummary: ""
    property bool saveSummaryBad: false
    // WHERE A SAVE WOULD GO, PROVEN BEFORE THE BUTTON IS DRAWN. `mockupFile`
    // is derived from `moduleId` unless the mockup says otherwise, so a file
    // whose name is not mockups/<moduleId>.qml wrote its defaults into a path
    // that does not exist -- silently, because the failure surfaced only in
    // `saveStatus`, which is rendered on the Profiles tab and not beside the
    // button (round 16: three of the framework's own mockups were doing it,
    // this module's among them). `blockLoading` because the answer is wanted
    // in the same frame as the button.
    readonly property bool mockupFileFound: store._probeText.length > 0
    property string _probeText: ""
    function _probe() {
        let t = "";
        try { t = _mockupProbe.text(); } catch (e) { t = ""; }
        store._probeText = t;
    }
    FileView {
        id: _mockupProbe
        path: store.mockupFile
        blockLoading: true
        printErrors: false
        // A FileView does NOT load again when its path is repointed, and this
        // one is pointed once the window has resolved PANEL_MOCKUP_PATH.
        onPathChanged: { reload(); store._probe(); }
        onLoaded: store._probe()
        onTextChanged: store._probe()
    }
    Component.onCompleted: store._probe()
    readonly property bool saving: saveProc.running

    // ---- the module side of Save ----------------------------------------------
    // The tree whose module files Save writes (MockupWindow.repoDir), the mockup's path in it, the module's
    // name (what the commit is titled with), and why the module is NOT written from here ("" = it is).
    property string repoDir: ""
    property string mockupRel: ""
    property string moduleId: ""
    property string moduleBlock: ""
    // The panel's self-test: the module is planned and reported, nothing of it written.
    property bool moduleDry: false
    // tools/shell/lares; "" = <repoDir>/tools/shell/lares. A probe names its stub.
    property string lares: ""
    property var _pendingSave: ({})

    Process {
        id: saveProc
        stdout: StdioCollector {
            id: saveOut
        }
        stderr: StdioCollector {
            id: saveErr
        }
    }
    // A Connections handler rather than onExited on the Process: qmllint
    // cannot see QProcess::ExitStatus and warns on every inline onExited.
    Connections {
        target: saveProc
        function onExited() {
            store._saveDone();
        }
    }
    function saveToMockup() {
        if (saveProc.running || !store.registry)
            return;
        // Not the themed lists (the theme's) nor the file-backed ones (their
        // own file keeps them; a val: saved for them would lie at the next
        // launch): registry.savedIds().
        const changes = store.registry.collect(store.registry.savedIds(), true);
        if (Object.keys(changes).length === 0) {
            store.saveStatus = "nothing to save: no value of the mockup's own differs from its val:";
            store.saveSummary = "";
            return;
        }
        store._pendingSave = changes;
        const args = ["python3", store.scriptsDir + "/mockup_promote.py", "save", store.mockupRel !== "" ? store.mockupRel : store.mockupFile,
                      JSON.stringify(changes), "--root", store.repoDir !== "" ? store.repoDir : RepoRoot.dir, "--mockup-file", store.mockupFile];
        if (store.moduleBlock !== "")
            args.push("--no-module", store.moduleBlock);
        else if (store.moduleDry)
            args.push("--module-dry");
        const picks = store.registry.sharedKeys(changes);
        if (picks.length > 0)
            args.push("--shared", picks.join(","));
        if (store.lares !== "")
            args.push("--lares", store.lares);
        saveProc.command = args;
        store.saveSummary = "saving…";
        store.saveSummaryBad = false;
        saveProc.running = true;
    }
    function _saveDone() {
        const out = saveOut.text.trim();
        const err = saveErr.text.trim();
        // Adopt exactly what the script wrote (or found already there), so a
        // prop it skipped keeps its * and its old default.
        const adopted = {};
        const lines = out.split("\n");
        for (const line of lines) {
            const m = /^(set|same)\s+(\w+)\.(\w+):/.exec(line);
            if (!m || !store._pendingSave[m[2]])
                continue;
            if (!adopted[m[2]])
                adopted[m[2]] = {};
            adopted[m[2]][m[3]] = store._pendingSave[m[2]][m[3]];
        }
        store.registry.adoptDefaults(adopted);
        store.saveStatus = out + (err.length > 0 ? "\nsave failed:\n" + err : "");
        store.saveSummary = store._summary(lines, err);
        store.saveSummaryBad = err.length > 0 || /FAILED|commit failed/.test(out);
    }
    // The line under the strip: what happened, the most important first, short enough to read in the panel's
    // width (the whole report is on hover and on the Profiles tab).
    function _summary(lines, err) {
        const files = lines.filter(l => l.indexOf("FILE ") === 0).length;
        const dry = lines.some(l => /\(dry run\)/.test(l));
        const blocked = lines.find(l => l.indexOf("module not written: ") === 0);
        const failed = lines.some(l => /^module: FAILED/.test(l));
        const refused = lines.filter(l => l.indexOf("REFUSE") === 0).length;
        const exit = lines.find(l => /^commit: lares apply exited \d+/.test(l)) || "";
        const code = exit === "" ? -1 : Number(/exited (\d+)/.exec(exit)[1]);
        const committed = lines.find(l => /^commit: apply: committed /.test(l)) || "";
        const none = lines.find(l => l.indexOf("commit: ") === 0 && l.indexOf("nothing is committed") > 0);
        const parts = [];
        if (blocked) {
            const why = blocked.substring("module not written: ".length);
            parts.push("module not written: " + (/copy of the config/.test(why) ? "runs from a copy of the config"
                : /redirected/.test(why) ? "a redirected save (a test)" : /not inside/.test(why) ? "the mockup is outside the config tree"
                : /git work tree/.test(why) ? "the tree is not a git work tree" : why.substring(0, 50)));
        } else if (failed) {
            parts.push("module FAILED before writing anything");
        } else if (files > 0) {
            parts.push((dry ? "would write " : "wrote ") + files + " module file" + (files === 1 ? "" : "s"));
        } else {
            parts.push("no module file changed");
        }
        if (refused > 0)
            parts.push(refused + " kept in the mockup only");
        if (code === 0)
            parts.push(committed !== "" ? "committed " + (/committed (\w+)/.exec(committed) || ["", ""])[1] : "nothing to commit");
        else if (code === 4)
            parts.push("committed, shell NOT restarted (a package update runs)");
        else if (code === 1 || code === 2)
            parts.push("COMMIT FAILED");
        else if (none)
            parts.push("not committed (no lares)");
        if (err.length > 0)
            parts.push("FAILED: " + err.split("\n").pop());
        return parts.join("; ");
    }

    // ---- what Save would do with each row (tools/dev/mockup_promote.py plan) -----------------
    // Read once, a moment after load and only for an interactive session: a scripted mode (a grab, a
    // render, a probe) never asks, so its panel is byte for byte what it was.
    property string planError: ""
    Process {
        id: planProc
        stdout: StdioCollector {
            id: planOut
        }
        stderr: StdioCollector {
            id: planErr
        }
    }
    Connections {
        target: planProc
        function onExited() {
            store._planDone();
        }
    }
    function loadPlan() {
        // Where the module is not written (a copy of the config, a redirected save) its rows' tips and
        // switches would promise what Save will not do: the plan is not asked for.
        if (planProc.running || !store.registry || store.mockupRel === "" || store.moduleBlock !== "")
            return;
        planProc.command = ["python3", store.scriptsDir + "/mockup_promote.py", "plan", store.mockupRel, "--root", store.repoDir];
        planProc.running = true;
    }
    function _planDone() {
        try {
            const o = JSON.parse(planOut.text);
            store.registry.plan = o.rows || {};
            store.planError = "";
        } catch (e) {
            store.planError = planErr.text.trim().split("\n").pop() || String(e);
        }
    }

    // ---- Profiles ---------------------------------------------------------
    property var profiles: ({})
    property var profileNames: []
    property string currentProfile: ""
    property string profileStatus: ""
    readonly property bool profileBusy: profileProc.running

    // The derived profile: every entry's `val:`, rewritten at every launch.
    readonly property string defaultProfileName: "default"
    // The profiles a user made, which is what the Profiles tab lists; the
    // derived one gets a row of its own because its buttons differ.
    readonly property var savedProfileNames: store.profileNames.filter(n => !store.isDefaultProfile(n))
    // Matched the way tools/dev/mockup_profiles.py matches it, so the GUI and a
    // hand-run command refuse the same names.
    function isDefaultProfile(name) {
        return String(name).trim().toLowerCase() === store.defaultProfileName;
    }
    // Every entry's `val:` in the profile shape, normalised through the
    // registry's own helpers so a default value and a saved one are written
    // identically (0.30000000000000004 -> 0.3, colours upper case, a bool
    // left the bool it is -- rounding one through a Number would write the
    // derived default of a switch as 1 and read back as a number for ever --
    // a text as its text, a colour that follows a token as "@<token>").
    function defaultValues() {
        const out = {};
        if (!store.registry)
            return out;
        for (const id of store.registry.listIds) {
            const es = store.registry.entries(id);
            if (es.length === 0)
                continue;
            out[id] = {};
            for (const e of es)
                if (e.val !== undefined)
                    out[id][e.prop] = store.registry.defaultForm(id, e);
        }
        return out;
    }

    Process {
        id: profileProc
        property string mode: ""
        stdout: StdioCollector {
            id: profileOut
        }
        stderr: StdioCollector {
            id: profileErr
        }
    }
    Connections {
        target: profileProc
        function onExited() {
            store._profileDone();
        }
    }
    function _profileRun(mode, args) {
        if (profileProc.running)
            return false;
        profileProc.mode = mode;
        profileProc.command = ["python3", store.scriptsDir + "/mockup_profiles.py"].concat(args);
        profileProc.running = true;
        return true;
    }
    // Latched, not a one-shot at startup: the derived default must be written
    // before anything lists the directory, and there is one process for both,
    // so the write is folded into the first listing and the list follows it
    // from _profileDone. Starting it from Component.onCompleted instead would
    // leave the process busy when MockupWindow calls refreshProfiles(), and
    // that first listing would simply be dropped.
    property bool defaultWritten: false
    // Whether this launch may write the derived default at all. The window
    // decides (MockupWindow._mayWriteDefault): a copy whose mockup file is not
    // the repo's may not write the repo's.
    property bool writeDefault: true

    function refreshProfiles() {
        if (!store.defaultWritten && store.writeDefault && store.registry
                && store._profileRun("default", ["default", store.profileDir, JSON.stringify(store.defaultValues())])) {
            store.defaultWritten = true;
            return;
        }
        store._profileRun("list", ["list", store.profileDir]);
    }
    function saveProfile(name) {
        if (!store.registry)
            return;
        if (store.isDefaultProfile(name)) {
            store.profileStatus = store.defaultProfileName + " is rewritten from the mockup's val: entries at every launch — save under another name";
            return;
        }
        if (store._profileRun("save", ["save", store.profileDir, name, JSON.stringify(store.registry.collect(store.registry.listIds, false))]))
            store.currentProfile = name;
    }
    function deleteProfile(name) {
        if (store.isDefaultProfile(name)) {
            store.profileStatus = store.defaultProfileName + " is rewritten from the mockup's val: entries at every launch — it cannot be deleted";
            return;
        }
        if (store._profileRun("delete", ["delete", store.profileDir, name]) && store.currentProfile === name)
            store.currentProfile = "";
    }
    function loadProfile(name) {
        const p = store.profiles[name];
        if (!p || !store.registry) {
            store.profileStatus = "no profile " + name;
            return;
        }
        store.registry.applyValues(p);
        store.currentProfile = name;
        store.profileStatus = "loaded " + name;
    }
    function validProfileName(s) {
        return /^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$/.test(s.trim());
    }
    function _profileDone() {
        const out = profileOut.text.trim();
        const err = profileErr.text.trim();
        if (profileProc.mode === "list") {
            try {
                const o = JSON.parse(out);
                store.profiles = o.profiles || {};
                store.profileNames = o.names || [];
            } catch (e) {
                store.profileStatus = err.length > 0 ? err : "profile list: " + e;
            }
            return;
        }
        // Writing the derived default is routine and happens once per launch,
        // so only its failure is worth a word on the panel; the listing it
        // deferred follows here like any other operation's.
        if (err.length > 0)
            store.profileStatus = err;
        else if (profileProc.mode !== "default")
            store.profileStatus = out;
        Qt.callLater(store.refreshProfiles);
    }
}
