pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../../common/system"
import "../../clipboard/data/ClipboardModel.js" as ClipModel
import "../../launcher/data/Frecency.js" as F
import "PickerModel.js" as Model

// =============================================================================
// PickerService.qml -- the emoji / symbol picker's data, memory and paste. ONE per shell.
//
// THE DATA is modules/picker/data/picker_data.json (tools/picker/build_data.py: rofimoji's emoji, kaomoji and symbol files plus
// Python's cp437 / cp1252 tables), committed, so the shell never needs rofimoji. It is read and indexed on the first
// `ensureLoaded()` (the popup calls it; a shell that never opens the picker pays nothing): `index` is PickerModel.index().
//
// THE MEMORY is $XDG_STATE_HOME/lares/picker/state.json (`stateOverride` names another folder):
//     { "version": 1, "tone": 0..5, "tab": "", "frecency": { "<char>": { "count": n, "recent": [ms, ...] } } }
// (`tab`: the last tab, kept only where picker.jsonc opens on it) the same frecency as the launcher (Frecency.js: how often AND how lately), keyed by the character the data holds (never
// the toned text, so a changed tone re-dresses the recents). `tone` is the ONE global skin tone: every emoji that takes a tone
// is shown, and pasted, in it. Writes are debounced and atomic.
//
// THE PASTE is the clipboard module's own path, not a second one: `pick(text, bases)` hands the text to the injected
// ClipboardService (`clipboard`), which wl-copies it, waits for this popup to let go of the keyboard (`hostOpen`), checks the
// window the popup was opened over (`origin`) is still the active one, and sends that window class's paste key
// (docs/clipboard.md, "Pasting"). With no `clipboard` (a mockup) nothing is sent: `lastPick` records what would have been.
// The echo of the copy lands in the clipboard history as a card, as any copy does.
//
// THE NERD FONTS TAB's data is NOT in that asset: the icon list changes with every Nerd Fonts release, so it is fetched for the version of
// the INSTALLED font (tools/picker/nerd_fetch.py: the version from the font's name table, curl, a timeout, the code points the font draws
// kept, cached in $XDG_CACHE_HOME/lares/picker). `ensureNerd()` (the popup calls it when the Nerd tab is first shown, never at start or
// at every open) runs the tool ONCE per shell -- a cache that is current answers in ~0.2 s with no network, a changed font fetches --
// and reads the asset it wrote into `nerdIndex`. `nerdState` is idle | loading | ready | error; on error `nerdError` is the tool's own
// reason (offline, no list for that version, no Nerd Font installed ...) and the next visit to the tab tries again. Nothing else changes.
//
// `live` defaults FALSE (CLAUDE.md, the shell-hosted contract): not live, the memory is in RAM only and nothing is pasted.
//
// WHO WRITES WHAT: the owner writes `origin` (the window the key was pressed over) and `hostOpen` (true while the popup is the
// engine's). `hostOpen` is forwarded to the clipboard service unless `forwardHostOpen` is false (the shell host ORs the
// clipboard's and the picker's flags itself and writes the clipboard service once).
// =============================================================================
QtObject {
    id: root

    property bool live: false
    property var clipboard: null
    // A state folder other than the default (a probe's).
    property string stateOverride: ""
    property int writeDelayMs: 300
    property var origin: null
    property bool hostOpen: false
    // The clipboard's openOverFullscreen (the owner reads it; with no clipboard module, its default).
    readonly property bool openOverFullscreen: !root.clipboard || root.clipboard.openOverFullscreen === true
    property bool forwardHostOpen: true
    // A pick is only copied (picker.jsonc "pick").
    property bool copyOnly: false

    // ---- the surface the popup reads -------------------------------------------------
    // The indexed data (PickerModel.index), null until ensureLoaded() has read it.
    property var index: null
    readonly property bool ready: root.index !== null
    property string error: ""
    // Bumped by every change of the memory (a pick, the tone): a binding that reads recents or the tone reads this first.
    property int serial: 0
    property int tone: 0
    // The tab the popup was last on ("" = none remembered): `rememberTab`.
    property string lastTab: ""
    readonly property var tones: root.index ? root.index.tones : []
    property var _data: null
    // The code pages the alt codes were built from ("CP437", "CP1252"), for the caption.
    readonly property string oemName: root._data && root._data.source ? String(root._data.source.oem).toUpperCase() : "CP437"
    readonly property string ansiName: root._data && root._data.source ? String(root._data.source.ansi).toUpperCase() : "CP1252"

    // ---- the Nerd Fonts tab ------------------------------------------------------------
    // idle (never asked) | loading (the tool runs) | ready (`nerdIndex` is built) | error (`nerdError` says why).
    property string nerdState: "idle"
    property string nerdError: ""
    // PickerModel.indexNerd(): { family, version, sets, items }, null until ready.
    property var nerdIndex: null
    readonly property string nerdFamily: root.nerdIndex ? root.nerdIndex.family : "Symbols Nerd Font"
    // What the tool last said (the parsed JSON line): a probe and the mockup read it. `nerdRuns` counts the tool's starts.
    property var nerdResult: null
    property int nerdRuns: 0
    // A cache folder / font file / list URL other than the machine's (a probe's, a mockup's).
    property string nerdCacheOverride: ""
    property string nerdFontOverride: ""
    property string nerdUrlBase: ""
    property string nerdToolPath: RepoRoot.dir + "/tools/picker/nerd_fetch.py"

    // What the last pick sent (a mockup / a probe reads it): { text, bases, origin, pasteKey ("" when nothing is sent), at }.
    property var lastPick: null
    property int picks: 0

    function ensureLoaded() {
        if (root.index !== null)
            return;
        const text = dataFile.text();
        const d = Model.parse(text);
        if (d === null) {
            root.error = "The emoji and symbol data is missing or out of date: tools/picker/build_data.py makes it";
            return;
        }
        root._data = d;
        root.index = Model.index(d);
        root.error = "";
        root._loadState();
    }

    // The Nerd Fonts list, for the installed font: asked once per shell (a failure may be asked again by the next visit to the tab).
    function ensureNerd() {
        if (root.nerdState === "loading" || root.nerdState === "ready")
            return;
        root.nerdState = "loading";
        root.nerdError = "";
        const cmd = ["setpriv", "--pdeathsig", "TERM", "--", "python3", root.nerdToolPath, "ensure", "--cache-dir", root._nerdDir];
        if (root.nerdFontOverride !== "")
            cmd.push("--font", root.nerdFontOverride);
        if (root.nerdUrlBase !== "")
            cmd.push("--url-base", root.nerdUrlBase);
        nerdProc.command = cmd;
        root.nerdRuns++;
        nerdProc.running = true;
        nerdWatch.restart();
    }

    function _nerdFinished(code, out) {
        nerdWatch.stop();
        if (root.nerdState !== "loading")
            return;
        let r = null;
        try {
            r = JSON.parse(out.trim().split("\n").pop());
        } catch (e) {
            r = null;
        }
        root.nerdResult = r;
        if (r === null || r.status === "error") {
            root._nerdFail(r ? String(r.reason) : "the Nerd Fonts tool did not answer (exit " + code + ")");
            return;
        }
        nerdAsset.path = String(r.asset);
        nerdAsset.reload();
        const asset = Model.parseNerd(nerdAsset.text());
        if (asset === null) {
            root._nerdFail("the Nerd Fonts list on disk is not readable (" + r.asset + ")");
            return;
        }
        root.nerdIndex = Model.indexNerd(asset);
        root.nerdState = "ready";
    }
    function _nerdFail(reason) {
        root.nerdError = reason;
        root.nerdState = "error";
    }

    // The text a pick puts on the clipboard for an item: its character with the global tone where it takes one, or -- an item picked as its
    // name (Ctrl+Enter on the Nerd tab) -- its name.
    function textOf(it) {
        if (it.asName === true)
            return it.name;
        return it.tonable ? Model.toned(it.ch, root.tone, root.tones) : it.ch;
    }

    function setTone(t) {
        const v = Math.max(0, Math.min(5, Math.floor(Number(t))));
        if (v === root.tone)
            return;
        root.tone = v;
        root._touch();
    }

    function rememberTab(tab) {
        if (tab === root.lastTab)
            return;
        root.lastTab = tab;
        root._dirty = true;
        if (root.live)
            writeTimer.restart();
    }

    // The items of `tab` the user pasted most (frecency), best first, at most `max`.
    function recentsOf(tab, max) {
        root.serial;
        if (!root.index || max <= 0)
            return [];
        const now = Date.now();
        const scored = [];
        // A Nerd glyph is no key of `byChar` (10 600 keys are 700 ms to build): the few that were pasted are found in one pass.
        const nerd = tab === "nerd" && root.nerdIndex !== null ? Model.nerdFind(root.nerdIndex, root._privateKeys()) : {};
        for (const ch in root._frecency) {
            const it = tab === "nerd" ? nerd[ch] : root.index.byChar[ch];
            if (!it || it.tab !== tab)
                continue;
            scored.push({ it: it, s: F.score(root._frecency[ch], now), last: root._frecency[ch].recent.slice(-1)[0] || 0 });
        }
        scored.sort((a, b) => b.s - a.s || b.last - a.last);
        return scored.slice(0, max).map(x => x.it);
    }

    function _privateKeys() {
        const want = {};
        for (const ch in root._frecency)
            if (Model.isPrivateUse(ch))
                want[ch] = true;
        return want;
    }

    // The tab a remembered character belongs to ("emoji" | "symbols" | "nerd"; "" when the asset no longer holds it). A Nerd glyph is no key of
    // `byChar`, but only the Nerd list has private-use characters.
    function _tabOfKey(ch) {
        if (Model.isPrivateUse(ch))
            return "nerd";
        const it = root.index ? root.index.byChar[ch] : undefined;
        return it ? it.tab : "";
    }

    // Take ONE character out of the recents (its frecency record). True when there was one.
    function forget(ch) {
        if (root._frecency[ch] === undefined)
            return false;
        delete root._frecency[ch];
        root._touch();
        return true;
    }

    // Take every record of `tab` out of the memory, the ones the Recent section shows and the ones it has no room for. Returns what it
    // removed ({ "<char>": record }), which `restoreRecents` puts back; empty when the tab had none (and nothing is written then).
    function clearRecents(tab) {
        const saved = {};
        let n = 0;
        for (const ch in root._frecency) {
            if (root._tabOfKey(ch) !== tab)
                continue;
            saved[ch] = root._frecency[ch];
            delete root._frecency[ch];
            n++;
        }
        if (n > 0)
            root._touch();
        return saved;
    }

    // Put back what `clearRecents` returned, exactly (counts and times).
    function restoreRecents(saved) {
        let n = 0;
        for (const ch in saved) {
            root._frecency[ch] = saved[ch];
            n++;
        }
        if (n > 0)
            root._touch();
    }

    // Forget everything: the recents and the tone (a mockup's button; the state file follows).
    function clearMemory() {
        root._frecency = {};
        root.tone = 0;
        root._touch();
    }

    // A pick, or several joined: `text` is what goes on the clipboard, `bases` the data characters it was made of.
    function pick(text, bases) {
        const o = root.origin ? { address: String(root.origin.address || ""), cls: String(root.origin.cls || "") } : null;
        root.lastPick = {
            text: String(text),
            bases: bases.slice(),
            origin: o,
            pasteKey: root.clipboard && !root.copyOnly ? ClipModel.pasteKeyFor(o ? o.cls : "", root.clipboard.pasteKeys) : "",
            at: Date.now()
        };
        root.picks++;
        const now = Date.now();
        for (let i = 0; i < bases.length; i++)
            root._frecency[bases[i]] = F.record(root._frecency[bases[i]], now);
        root._touch();
        if (root.live && root.clipboard) {
            root.clipboard.origin = root.origin;
            root.clipboard.paste([], { mode: root.copyOnly ? "copy" : "paste", text: String(text), via: "picker" });
        }
    }

    // ---- the memory -------------------------------------------------------------------
    property var _frecency: ({})
    property bool _dirty: false
    property bool _dirReady: false
    readonly property string _dir: root.stateOverride !== "" ? root.stateOverride
        : (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/lares/picker"
    readonly property string _path: root._dir + "/state.json"

    function _loadState() {
        if (!root.live)
            return;
        const txt = stateFile.text();
        if (!txt || txt.length === 0)
            return;
        let d = null;
        try {
            d = JSON.parse(txt);
        } catch (e) {
            d = null;
        }
        if (!d || d.version !== 1) {
            console.log("PickerService: " + root._path + " is not a version-1 state; the first change replaces it");
            return;
        }
        const f = {};
        const src = d.frecency && typeof d.frecency === "object" && !Array.isArray(d.frecency) ? d.frecency : {};
        for (const k in src) {
            const r = F.normalise(src[k]);
            // a Nerd glyph is kept whether or not the list is loaded yet (it is indexed on the first visit to the tab)
            if (r !== null && (root.index.byChar[k] !== undefined || Model.isPrivateUse(k)))
                f[k] = r;
        }
        root._frecency = f;
        root.tone = Math.max(0, Math.min(5, Math.floor(Number(d.tone) || 0)));
        root.lastTab = typeof d.tab === "string" ? d.tab : "";
        root.serial++;
    }

    function _touch() {
        root._dirty = true;
        root.serial++;
        if (root.live)
            writeTimer.restart();
    }

    function flush() {
        writeTimer.stop();
        if (!root._dirty || !root.live)
            return;
        if (!root._dirReady) {
            mkdir.running = true;
            return;
        }
        root._dirty = false;
        stateFile.setText(JSON.stringify({ version: 1, tone: root.tone, tab: root.lastTab, frecency: root._frecency }, null, 1) + "\n");
    }

    property Timer _writeTimer: Timer {
        id: writeTimer
        interval: root.writeDelayMs
        onTriggered: root.flush()
    }
    property Process _mkdir: Process {
        id: mkdir
        command: ["mkdir", "-p", "--", root._dir]
        onExited: code => {
            root._dirReady = code === 0;
            if (root._dirReady)
                root.flush();
            else
                console.log("PickerService: could not create " + root._dir + "; the memory is not written");
        }
    }

    // The tool's cache: $XDG_CACHE_HOME/lares/picker (the list as fetched, and the asset the shell reads).
    readonly property string _nerdDir: root.nerdCacheOverride !== "" ? root.nerdCacheOverride
        : (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/lares/picker"
    property Process _nerdProc: Process {
        id: nerdProc
        stdout: StdioCollector {
            id: nerdOut
        }
        onExited: code => root._nerdFinished(code, nerdOut.text)
    }
    // A Process whose program is missing says nothing at all (neither started nor exited): the tool's own curl timeout is 30 s.
    property Timer _nerdWatch: Timer {
        id: nerdWatch
        interval: 45000
        onTriggered: {
            if (root.nerdState === "loading") {
                nerdProc.running = false;
                root._nerdFail("the Nerd Fonts tool did not answer in 45 s (python3 or setpriv missing?)");
            }
        }
    }
    // One view, repointed only before its first read (CLAUDE.md: a FileView loads synchronously on its first path assignment).
    property FileView _nerdAsset: FileView {
        id: nerdAsset
        blockLoading: true
        blockAllReads: true
        printErrors: false
    }
    property FileView _dataFile: FileView {
        id: dataFile
        path: RepoRoot.dir + "/modules/picker/data/picker_data.json"
        blockLoading: true
        printErrors: false
    }
    // One FileView on a static path (a view is never repointed); not live: no path, nothing read or written.
    property FileView _stateFile: FileView {
        id: stateFile
        path: root.live ? root._path : ""
        blockLoading: true
        atomicWrites: true
        printErrors: false
    }

    // The paste waits for the popup to let go of the keyboard: the clipboard service's `hostOpen` is ours.
    property Binding _hostOpen: Binding {
        target: root.clipboard
        property: "hostOpen"
        value: root.hostOpen
        when: root.forwardHostOpen && !!root.clipboard
    }

    Component.onDestruction: {
        if (root._dirty && root.live)
            root.flush();
        stateFile.waitForJob();
    }
}
