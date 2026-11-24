pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "../../common/components"
import "../../common/system"
import "AudioModel.js" as Model

// =============================================================================
// AudioService.qml -- the audio popup's ONE service (once per shell, like every service: the popup is built on open and destroyed on close).
//
// WHAT TALKS TO WHAT. Quickshell's Pipewire binding (`pipewire`: PipewireService) is the live half: nodes, volumes per channel, mute, the
// default, the link graph. It has no cards, ports, profiles, formats, offsets or stream moves, so those are `pactl`, behind AudioCalls (one child per
// slot, every one with a deadline); `pw-dump Node` says what no other source says (a node's `error` state); `pw-metadata` the configured default
// and System Sounds; `pw-cli destroy` is the only Terminate there is (pactl has no such verb, and it wants the node ID where every pactl verb wants
// the index, which is the serial).
//
// AT REST IT DOES NOTHING. `popupOpen` is host-written (the OR of the screens' owners). Closed: no child, no subscription, no timer, no merge.
// Open: one `pactl subscribe` says when to read, and a heartbeat reads anyway, because a hung server sends no events and silence is how a
// hang looks.
//
// EVERY CHANGE IS READ BACK. A verb makes an INTENT: what was asked, by when it must show. The intents are judged whenever the facts move and at
// their deadlines; one that does not show becomes the row's NOTE ("Did not move to Headphones: still on Speaker"), and it stays until the fact
// agrees or the user asks again. A refused or hung write says so at once. A row that vanishes under an intent, or under a held gesture, is
// a NOTICE at the popup's foot, since there is no row left to say it in.
//
// HEALTH. `health` is "idle" (closed, never read), "reading", "ok", "hung", "dead", "missing" or "error" (pactl failed in a way it has no word for), `healthReason` the sentence, `healthDiag` what the hang
// is made of (tools/audio/lares-audio-diag: WirePlumber in D on a USB call is the user's locked DAC). While not ok, verbs that need pactl are not
// sent: they fail at once, in the row, with the reason. Rows stay on screen with what was last known.
//
// `live` defaults to FALSE (a host that forgets cannot reach the machine): with no `machine` either, nothing is ever run.
// =============================================================================
Item {
    id: root

    property bool live: false
    property var pipewire: null
    property var machine: null
    // Host-written: some screen's audio popup is open (CONTRACT section 4).
    property bool popupOpen: false

    // ---- the numbers ---------------------------------------------------------------------------------------------------------
    property int callDeadlineMs: 3000
    property int heartbeatMs: 5000
    property int debounceMs: 90
    // How long each change may take to show before the row says it did not take.
    property int volumeMs: 1500
    property int defaultMs: 1800
    // How long a ball stays on a device that cannot take the default (`setDefault`), and how long the row then says why.
    property int refusedMs: 470
    property int refusedNoteMs: 5000
    property int moveMs: 2500
    property int portMs: 3000
    property int profileMs: 4000
    property int toneMs: 1200
    // What a device's hardware steps may round a level by, before it counts as "did not take".
    property real volumeTolerance: 0.025
    // How the tone is played (a probe's stub). `node.dont-fallback`: a tone for a device that is gone FAILS, it never plays on another.
    property string playBin: "pw-play"
    property string toneFile: "/usr/share/sounds/freedesktop/stereo/audio-test-signal.oga"
    property string tickFile: "/usr/share/sounds/freedesktop/stereo/audio-volume-change.oga"
    property real toneVolume: 0.25
    property int toneDeadlineMs: 6000
    readonly property string diagPath: RepoRoot.dir + "/tools/audio/lares-audio-diag"
    property string diagBin: root.diagPath
    readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/lares/audio"

    // ---- the state ---------------------------------------------------------------------------------------------------------------
    property string health: "idle"
    property string healthReason: ""
    property string healthDiag: ""
    readonly property bool canCall: root.health === "ok" || root.health === "reading" || root.health === "error"
    // The binding is the shell's own connection, and Quickshell 0.3.2 NEVER makes it again after the daemon restarts (13 s after a restart on the
    // same sockets `ready` is still false, with no nodes). Gone: every row here falls back to pactl, the meters stop, and the bar's pill is dead until the shell restarts. The popup says so.
    readonly property bool bindingUp: !!root.pipewire && root.pipewire.ready === true

    property var rows: ({ sinks: [], sources: [], playback: [], recording: [], cards: [] })
    property var roleRow: null
    property int rowsSerial: 0
    property var _byKey: ({})
    // The default in force: the binding's; with the binding gone, what the metadata said last.
    readonly property string defaultSinkName: root.pipewire && root.pipewire.defaultSink ? root.pipewire.defaultSink.name : root._metaSink
    readonly property string defaultSourceName: root.pipewire && root.pipewire.defaultSource ? root.pipewire.defaultSource.name : root._metaSource
    property string _metaSink: ""
    property string _metaSource: ""
    // WHAT THE HAND ASKED FOR, until the graph has answered: the rail reads this first, so its ball rolls to a slot the moment the slot is clicked, and the fact decides where
    // it comes to rest. Not the default: everything that says what plays where goes on reading the two above.
    property string askedSink: ""
    property string askedSource: ""
    readonly property string railSink: root.askedSink !== "" ? root.askedSink : root.defaultSinkName
    readonly property string railSource: root.askedSource !== "" ? root.askedSource : root.defaultSourceName
    function _ask(dir: string, name: string): void {
        if (dir === "sink")
            root.askedSink = name;
        else
            root.askedSource = name;
    }
    // What the user configured, when it is not what is in force (a device that is not plugged in).
    property string configuredSink: ""
    property string configuredSource: ""

    property var notes: ({})
    property int notesSerial: 0
    property var notice: null               // { text, action?: "moveAll", ids } or null
    property string toneKey: ""             // the output whose tone is sounding
    property string heldKey: ""             // a row the hand is holding (a drag)

    // ---- the rows ----------------------------------------------------------------------------------------------------------------
    function rowOf(key: string): var {
        return root._byKey[key] || null;
    }
    function noteOf(key: string): var {
        return root.notes[key] || null;
    }
    // Live values where a node carries them, the last reading where none does.
    function volumesOf(row: var): var {
        if (!row)
            return [];
        return row.node && row.node.audio ? row.node.audio.volumes : row.volumes;
    }
    function mutedOf(row: var): bool {
        if (!row)
            return false;
        return row.node && row.node.audio ? row.node.audio.muted === true : row.muted === true;
    }

    function dropNote(key: string): void {
        root._lateChecks = root._lateChecks.filter(i => i.key !== key);
        if (root.notes[key])
            root._setNote(key, null);
    }

    // ---- reading -----------------------------------------------------------------------------------------------------------------
    AudioCalls {
        id: calls
        machine: root.machine
        deadlineMs: root.callDeadlineMs
    }
    readonly property alias calls: calls
    readonly property bool _canRun: root.live || !!root.machine

    property var _snap: null
    property var _dump: ({})
    property var _codecs: ({})
    // What pavucontrol keeps in its .ini, and the names: { meters, hideUnavailable, feedback, filters: { section: index }, labels: { "<kind>:<node>": name } }.
    property var settings: ({})
    // Device names the lists leave out (audio.jsonc hide, `*` any text): never the default, never one a stream is on.
    property var hide: []
    onHideChanged: root._remerge()
    readonly property var _labels: root.settings.labels || ({})
    property bool _readAgain: false
    property int _heartbeats: 0

    function _pactlList(): var {
        return ["pactl", "-f", "json", "list"];
    }

    // One round of reading. Each slot is its own: a pactl that hangs does not stop pw-dump from saying what the node's state is.
    function refresh(): void {
        if (!root._canRun)
            return;
        if (root.health === "idle")
            root.health = "reading";
        const started = calls.read("pactl", root._pactlList(), (c, o, e) => root._onList(c, o, e), root.callDeadlineMs);
        if (!started)
            root._readAgain = true;
        calls.read("pw", ["pw-dump", "Node"], (c, o, e) => root._onDump(c, o, e), root.callDeadlineMs);
        if (root._heartbeats % 3 === 0 || !root.bindingUp)
            calls.read("meta", ["sh", "-c", "pw-metadata -n default; pw-metadata -n route-settings"], (c, o, e) => root._onMeta(c, o, e), root.callDeadlineMs);
    }

    function _onList(code: int, out: string, err: string): void {
        if (root._readAgain) {
            root._readAgain = false;
            Qt.callLater(root.refresh);
        }
        if (code === -3)
            return;
        const v = root._verdictOf(code, err);
        if (!v.ok) {
            root._setHealth(v.health || "dead", v.reason);
            root._remerge();                // no snapshot yet: the binding's nodes still make rows
            return;
        }
        let snap = null;
        try {
            snap = JSON.parse(out);
        } catch (e) {
            root._setHealth("dead", "pactl answered something that is not JSON.");
            return;
        }
        root._snap = snap;
        root._setHealth("ok", "");
        root._remerge();
        root._readCodecs();
    }

    function _verdictOf(code: int, err: string): var {
        if (code === -1)
            return { ok: false, health: "hung", reason: "No answer in time: the sound server took the call and went silent." };
        return Model.verdict(code, err);
    }

    function _onDump(code: int, out: string, err: string): void {
        if (code !== 0)
            return;                         // pactl alone decides the health: this is the node states' extra word
        root._dump = Model.parseDump(out);
        root._remerge();
    }

    function _onMeta(code: int, out: string, err: string): void {
        if (code !== 0)
            return;
        const sink = out.match(/default\.configured\.audio\.sink' value:'\{"name":"([^"]*)"/);
        const src = out.match(/default\.configured\.audio\.source' value:'\{"name":"([^"]*)"/);
        root.configuredSink = sink ? sink[1] : "";
        root.configuredSource = src ? src[1] : "";
        const inForce = out.match(/default\.audio\.sink' value:'\{"name":"([^"]*)"/);
        const inForceSrc = out.match(/default\.audio\.source' value:'\{"name":"([^"]*)"/);
        root._metaSink = inForce ? inForce[1] : "";
        root._metaSource = inForceSrc ? inForceSrc[1] : "";
        const was = root.roleRow;
        const r = Model.parseRole(out);
        if (JSON.stringify(was) !== JSON.stringify(r)) {
            root.roleRow = r;
            root._index();
        }
    }

    // Bluetooth cards' codecs are messages to the card (pipewire-pulse's message-handler.c): one card at a time, in the codec slot.
    function _readCodecs(): void {
        const cards = root.rows.cards.filter(c => c.isBluez);
        if (cards.length === 0 || calls.busy("codec"))
            return;
        const c = cards[0];
        calls.read("codec", ["sh", "-c", 'pactl send-message "$1" list-codecs; echo; pactl send-message "$1" get-codec', "sh", "/card/" + c.name + "/bluez"], (code, out, err) => {
            if (code !== 0)
                return;
            const lines = out.split("\n").filter(l => l.trim() !== "");
            try {
                const list = JSON.parse(lines[0]).map(x => ({ name: String(x.name), description: x.description || String(x.name) }));
                const active = lines.length > 1 ? JSON.parse(lines[1]) : "";
                const next = Object.assign({}, root._codecs);
                next[c.name] = { list: list, active: active === null ? "" : String(active) };
                if (JSON.stringify(root._codecs) !== JSON.stringify(next)) {
                    root._codecs = next;
                    root._remerge();
                }
            } catch (e) {
                // an answer that does not parse: the card simply shows no codec box
            }
        }, root.callDeadlineMs);
    }

    function _setHealth(h: string, reason: string): void {
        const was = root.health;
        root.health = h;
        root.healthReason = reason;
        if (h === "ok")
            root.healthDiag = "";
        if (h === "hung" && was !== "hung")
            calls.read("diag", [root.diagBin], (code, out, err) => {
                if (code === 0)
                    root.healthDiag = Model.diagnose(out);
            }, 2000);
        if (h !== "ok" && h !== "reading")
            root._failCallIntents();
    }

    // ---- the merge: the last snapshot + what the binding says now ------------------------------------------------------------------------
    property bool _mergeArmed: false
    function _remerge(): void {
        if (!root.popupOpen && root.rowsSerial > 0)
            return;
        if (root._mergeArmed)
            return;
        root._mergeArmed = true;
        Qt.callLater(root._mergeNow);
    }
    function _mergeNow(): void {
        root._mergeArmed = false;
        const pw = root.pipewire;
        const before = root._byKey;
        const r = Model.merge(root._snap, pw ? pw.trackedAudioNodes || [] : [], pw ? pw.linkPairs || [] : [], {
            defaultSink: root.defaultSinkName, defaultSource: root.defaultSourceName,
            dump: root._dump, labels: root._labels, codecs: root._codecs, hide: root.hide
        });
        root.rows = r;
        root._index();
        root._vanished(before);
        root._judge();
    }
    function _index(): void {
        const m = {};
        const r = root.rows;
        for (const sec of [r.sinks, r.sources, r.playback, r.recording, r.cards])
            for (let i = 0; i < sec.length; i++)
                m[sec[i].key] = sec[i];
        if (root.roleRow)
            m[root.roleRow.key] = root.roleRow;
        root._byKey = m;
        root.rowsSerial++;
    }
    // Something was in the hand or on its way when its row went away.
    function _vanished(before: var): void {
        if (root.heldKey !== "" && !root._byKey[root.heldKey] && before[root.heldKey]) {
            const b = before[root.heldKey];
            root.notice = { text: (b.shortName || b.app) + " went away while you held it. Nothing was changed on it." };
            root.heldKey = "";
        }
        const list = root._intents.slice();
        let changed = false;
        for (let i = list.length - 1; i >= 0; i--) {
            const it = list[i];
            if (root._byKey[it.key] || it.kind === "default")
                continue;
            const b = before[it.key];
            if (b && it.kind !== "profile" && it.kind !== "tone") {
                root.notice = { text: (b.shortName || b.app) + " went away before the change showed." };
                list.splice(i, 1);
                changed = true;
            }
        }
        if (changed)
            root._intents = list;
    }

    onDefaultSinkNameChanged: root._remerge()
    onDefaultSourceNameChanged: root._remerge()
    Connections {
        target: root.popupOpen ? root.pipewire : null
        ignoreUnknownSignals: true
        function onTrackedAudioNodesChanged() {
            root._remerge();
        }
        function onLinkPairsChanged() {
            root._remerge();
        }
    }
    Binding {
        target: root.pipewire
        when: !!root.pipewire
        property: "linksWanted"
        value: root.popupOpen
    }

    // ---- open and closed ---------------------------------------------------------------------------------------------------------------
    function _opened(): void {
        root._heartbeats = 0;
        root.health = "reading";            // what it was at the last close says nothing about now
        root._loadState();
        root._remerge();
        root.refresh();
    }
    // A host that says "open" from the start (a mockup) gets no change signal; one turn later, because a child's Connections complete after this.
    Component.onCompleted: {
        if (root.popupOpen)
            Qt.callLater(root._opened);
    }
    onPopupOpenChanged: {
        if (root.popupOpen) {
            root._opened();
        } else {
            root.notice = null;
            root.heldKey = "";
            root._intents = [];
            root._toneStopped = true;
            calls.stopTone();
        }
    }
    Timer {
        id: heartbeat
        interval: root.heartbeatMs
        repeat: true
        running: root.popupOpen && root._canRun
        onTriggered: {
            root._heartbeats++;
            root.refresh();
        }
    }
    Timer {
        id: debounce
        interval: root.debounceMs
        onTriggered: root.refresh()
    }
    // The events: a line means "read again", nothing more. In a mock (`machine`) the world calls `poke()`.
    SupervisedStream {
        id: events
        enabled: root.popupOpen && root.live
        what: "AudioService: pactl subscribe"
        command: ["setpriv", "--pdeathsig", "TERM", "--", "pactl", "subscribe"]
        onLine: text => {
            if (text.indexOf("client") < 0 && text.indexOf("module") < 0)
                debounce.restart();
        }
    }
    function poke(): void {
        if (root.popupOpen)
            debounce.restart();
    }

    // ---- intents: what was asked, and whether it has shown --------------------------------------------------------------------------------
    property var _intents: []
    Timer {
        id: judgeTimer
        interval: 120
        repeat: true
        running: root._intents.length > 0
        onTriggered: root._judge()
    }

    function _setNote(key: string, note: var): void {
        const n = Object.assign({}, root.notes);
        if (note)
            n[key] = note;
        else
            delete n[key];
        root.notes = n;
        root.notesSerial++;
    }
    function _intend(i: var, ms: int): void {
        i.deadline = Date.now() + ms;
        i.t0 = Date.now();
        // one intent per kind per row: a new ask replaces the old one, and its note
        root._intents = root._intents.filter(x => !(x.key === i.key && x.kind === i.kind && x.dir === i.dir)).concat([i]);
        if (root.notes[i.key])
            root._setNote(i.key, null);
    }
    // What the facts say now, for one intent.
    function _have(i: var): var {
        const r = root.rowOf(i.key);
        switch (i.kind) {
        case "default":
            return i.dir === "sink" ? root.defaultSinkName : root.defaultSourceName;
        case "volume":
            return r ? (i.roleKey ? root.roleRow.volumes : root.volumesOf(r)) : null;
        case "mute":
            return r ? (i.roleKey ? root.roleRow.muted : root.mutedOf(r)) : null;
        case "move":
            return r ? r.device : null;
        case "port":
            return r ? r.activePort : null;
        case "profile":
            return r ? r.activeProfile : null;
        case "offset":
            return r ? r.activeOffsetMs : null;
        case "formats":
            return r ? r.formats : null;
        case "codec":
            return r ? r.activeCodec : null;
        }
        return null;
    }
    function _haveText(i: var, h: var): string {
        switch (i.kind) {
        case "volume":
            return h ? Model.percentText(Model.average(h)) : "nothing";
        case "default": {
            const d = root.rowOf("d:" + i.dir + ":" + h);
            return d ? d.shortName : String(h);
        }
        case "move": {
            const r = root.rowOf(i.key);
            return r && r.deviceDescription !== "" ? r.deviceDescription : "nothing";
        }
        case "port": {
            const r = root.rowOf(i.key);
            const p = r ? r.ports.filter(x => x.name === h)[0] : null;
            return p ? p.description : String(h);
        }
        case "profile": {
            const r = root.rowOf(i.key);
            const p = r ? r.profiles.filter(x => x.name === h)[0] : null;
            return p ? p.description : String(h);
        }
        }
        return String(h);
    }
    function _judge(): void {
        const now = Date.now();
        const keep = [];
        const answered = i => {
            if (i.kind === "default" && (i.dir === "sink" ? root.askedSink : root.askedSource) === i.want)
                root._ask(i.dir, "");
        };
        for (const i of root._intents) {
            const h = root._have(i);
            if (Model.compare(i.kind, i.want, h, root.volumeTolerance)) {
                answered(i);
                if (root.notes[i.key])
                    root._setNote(i.key, null);
                if (i.then)
                    i.then();
                continue;
            }
            if (now >= i.deadline) {
                answered(i);
                if (root.rowOf(i.key) || i.kind === "default") {
                    root._setNote(i.key, { state: "failed", text: Model.failText(i, root._haveText(i, h)) });
                    root._lateChecks = root._lateChecks.filter(x => x.key !== i.key || x.kind !== i.kind).concat([i]);
                }
                continue;
            }
            keep.push(i);
        }
        if (keep.length !== root._intents.length)
            root._intents = keep;
        root._rejudgeNotes();
    }
    // A note stays until the fact agrees: a change that shows late clears it.
    function _rejudgeNotes(): void {
        const open = root._lateChecks;
        if (open.length === 0)
            return;
        const keep = open.filter(i => {
            if (!Model.compare(i.kind, i.want, root._have(i), root.volumeTolerance))
                return !!root.notes[i.key];
            if (root.notes[i.key])
                root._setNote(i.key, null);
            return false;
        });
        if (keep.length !== open.length)
            root._lateChecks = keep;
    }
    property var _lateChecks: []

    function _failCallIntents(): void {
        const needsCall = ["move", "port", "profile", "offset", "formats", "codec"];
        const list = root._intents.filter(i => {
            if (needsCall.indexOf(i.kind) < 0)
                return true;
            root._setNote(i.key, { state: "failed", text: root._notSent() });
            return false;
        });
        if (list.length !== root._intents.length)
            root._intents = list;
    }
    function _notSent(): string {
        return root.health === "hung" ? "Not sent: the sound server is not answering."
            : root.health === "dead" ? "Not sent: the sound server is not running."
            : root.health === "missing" ? "Not sent: pactl is not installed."
            : "Not sent.";
    }

    // A pactl write with its intent. `key` is the row, `verb` keeps two different writes to one row apart in the queue.
    function _call(verb: string, key: string, argv: var, intent: var, ms: int): void {
        if (!root._canRun) {
            root._setNote(key, { state: "failed", text: "Not sent: no sound server here." });
            return;
        }
        if (!root.canCall) {
            root._setNote(key, { state: "failed", text: root._notSent() });
            return;
        }
        if (intent)
            root._intend(intent, ms);
        calls.write(verb + ":" + key, argv, (code, out, err) => {
            if (code === -3)
                return;                     // a newer ask for the same thing took its place
            if (code === -4) {
                root._dropIntent(intent);
                root._setNote(key, { state: "failed", text: "Not sent: too many changes waiting." });
                return;
            }
            const v = root._verdictOf(code, err);
            if (v.ok) {
                debounce.restart();
                return;
            }
            root._dropIntent(intent);
            root._setNote(key, { state: "failed", text: (v.health === "hung" ? "No answer: " : "Refused: ") + (v.health === "hung" ? "the sound server took this and went silent." : v.reason) });
            // A refusal is about this ask, not about the server.
            if (v.health && v.health !== "error")
                root._setHealth(v.health, v.reason);
        }, root.callDeadlineMs);
    }
    function _dropIntent(intent: var): void {
        if (intent)
            root._intents = root._intents.filter(i => i !== intent);
    }

    // ---- the verbs ---------------------------------------------------------------------------------------------------------------------
    function _pactlDev(row: var): string {
        return row.kind === "sink" ? "sink" : "source";
    }
    function _pactlStream(row: var): string {
        return row.kind === "playback" ? "sink-input" : "source-output";
    }

    function setVolumes(row: var, volumes: var): void {
        if (!row)
            return;
        const v = [];
        for (let i = 0; i < volumes.length; i++)
            v.push(Math.round(Math.max(0, volumes[i]) * 1000) / 1000);
        const wantText = Model.percentText(Model.average(v));
        if (row.kind === "role") {
            root._writeRole(v, root.roleRow.muted, "volume", wantText);
            return;
        }
        if (row.node && row.node.audio && root.bindingUp) {
            root._intend({ kind: "volume", key: row.key, want: v, wantText: wantText }, root.volumeMs);
            root.pipewire.setVolumes(row.node, v);
            return;
        }
        const pct = v.map(x => Math.round(x * 100) + "%");
        if (row.kind === "sink" || row.kind === "source")
            root._call("volume", row.key, ["pactl", "set-" + root._pactlDev(row) + "-volume", row.name].concat(pct), { kind: "volume", key: row.key, want: v, wantText: wantText }, root.volumeMs);
        else
            root._call("volume", row.key, ["pactl", "set-" + root._pactlStream(row) + "-volume", String(row.serial)].concat(pct), { kind: "volume", key: row.key, want: v, wantText: wantText }, root.volumeMs);
    }

    // A step taken through VolumeParity (the wheel): the write is its, the read-back is here.
    function expectVolume(row: var, v: real): void {
        if (!row || v < 0)
            return;
        const n = Math.max(1, root.volumesOf(row).length);
        const want = [];
        for (let i = 0; i < n; i++)
            want.push(v);
        root._intend({ kind: "volume", key: row.key, want: want, wantText: Model.percentText(v) }, root.volumeMs);
    }

    function setMuted(row: var, muted: bool): void {
        if (!row)
            return;
        if (row.kind === "role") {
            root._writeRole(root.roleRow.volumes, muted, "mute", "");
            return;
        }
        if (row.node && row.node.audio && root.bindingUp) {
            root._intend({ kind: "mute", key: row.key, want: muted }, root.volumeMs);
            root.pipewire.setMuted(row.node, muted);
            return;
        }
        const noun = row.kind === "sink" || row.kind === "source" ? root._pactlDev(row) : root._pactlStream(row);
        const target = row.kind === "sink" || row.kind === "source" ? row.name : String(row.serial);
        root._call("mute", row.key, ["pactl", "set-" + noun + "-mute", target, muted ? "1" : "0"], { kind: "mute", key: row.key, want: muted }, root.volumeMs);
    }

    // WirePlumber takes no device all of whose ports say nothing is plugged in (`lutils.haveAvailableRoutes`, default-nodes/rescan.lua): an HDMI output with no screen on it
    // cannot be the default, however it is asked. pactl's `availability` is that same route state.
    function unplugged(row: var): bool {
        return !!row && !!row.ports && row.ports.length > 0 && row.ports.every(p => p.available === false);
    }
    // The default. Quickshell writes the configured default; `default.audio.sink` is what the session manager makes of it, and that is what is read back.
    //
    // A DEVICE WITH NOTHING PLUGGED IN IS NOT ASKED AT ALL. On this laptop that is every HDMI output and the second microphone: a click on one would do
    // nothing, the write lands in `default.configured.*`, WirePlumber keeps the default where it was, the ball (which follows the default in force) never leaves its slot, and
    // the wish stays behind ("Your chosen device ... is not here") with no way to take it back. So the ball goes there and comes back, and the row says why.
    function setDefault(row: var): void {
        if (!row || !root.pipewire)
            return;
        const dir = row.kind;
        const before = dir === "sink" ? root.defaultSinkName : root.defaultSourceName;
        if (before === row.name)
            return;
        root._ask(dir, row.name);
        if (root.unplugged(row)) {
            refused.dir = dir;
            refused.key = row.key;
            refused.restart();
            return;
        }
        root._intend({ kind: "default", dir: dir, key: row.key, want: row.name, then: () => root._afterDefault(dir, row.name) }, root.defaultMs);
        if (root.bindingUp && row.node) {
            if (dir === "sink")
                root.pipewire.setDefaultSink(row.node);
            else
                root.pipewire.setDefaultSource(row.node);
        } else {
            root._call("default", row.key, ["pactl", "set-default-" + dir, row.name], null, 0);
        }
        debounce.restart();
    }

    Timer {
        id: refused
        property string dir: ""
        property string key: ""
        interval: root.refusedMs
        onTriggered: {
            root._ask(refused.dir, "");
            const have = refused.dir === "sink" ? root.defaultSinkName : root.defaultSourceName;
            const d = root.rowOf("d:" + refused.dir + ":" + have);
            root._setNote(refused.key, { state: "failed", text: Model.refusedText(d ? d.shortName : have) });
            refusedNote.key = refused.key;
            refusedNote.restart();
        }
    }
    Timer {
        id: refusedNote
        property string key: ""
        interval: root.refusedNoteMs
        onTriggered: root._setNote(refusedNote.key, null)
    }

    // The failure to prevent: "I select an output ... and it plays through my laptop speakers". The default moved; say which streams did not
    // follow it (a stream pinned by hand stays), and offer to bring them.
    function _afterDefault(dir: string, name: string): void {
        afterDefault.dir = dir;
        afterDefault.name = name;
        afterDefault.restart();
    }
    Timer {
        id: afterDefault
        property string dir: ""
        property string name: ""
        interval: 700
        onTriggered: {
            const list = afterDefault.dir === "sink" ? root.rows.playback : root.rows.recording;
            const left = list.filter(r => r.device !== "" && r.device !== afterDefault.name);
            if (left.length === 0)
                return;
            const dev = root.rowOf("d:" + afterDefault.dir + ":" + afterDefault.name);
            root.notice = {
                text: left.map(r => r.app).join(", ") + (left.length === 1 ? " stays" : " stay") + " on " + left[0].deviceDescription + ".",
                action: "moveAll", label: "Move to " + (dev ? dev.shortName : afterDefault.name), keys: left.map(r => r.key), target: afterDefault.name
            };
        }
    }
    function runNoticeAction(): void {
        const n = root.notice;
        if (!n || n.action !== "moveAll")
            return;
        root.notice = null;
        for (let i = 0; i < n.keys.length; i++)
            root.moveStream(root.rowOf(n.keys[i]), n.target);
    }
    function dismissNotice(): void {
        root.notice = null;
    }

    function moveStream(row: var, deviceName: string): void {
        if (!row || row.device === deviceName)
            return;
        const dev = root.rowOf("d:" + (row.kind === "playback" ? "sink" : "source") + ":" + deviceName);
        if (!dev) {
            root._setNote(row.key, { state: "failed", text: "Not moved: that device is gone." });
            return;
        }
        root._call("move", row.key, ["pactl", "move-" + root._pactlStream(row), String(row.serial), deviceName],
            { kind: "move", key: row.key, want: deviceName, wantText: dev.shortName }, root.moveMs);
    }

    function setPort(row: var, portName: string): void {
        if (!row || row.activePort === portName)
            return;
        root._call("port", row.key, ["pactl", "set-" + root._pactlDev(row) + "-port", row.name, portName], { kind: "port", key: row.key, want: portName }, root.portMs);
    }

    function setProfile(card: var, profileName: string): void {
        if (!card || card.activeProfile === profileName)
            return;
        root._call("profile", card.key, ["pactl", "set-card-profile", card.name, profileName], { kind: "profile", key: card.key, want: profileName }, root.profileMs);
    }

    function setCodec(card: var, codec: string): void {
        if (!card || card.activeCodec === codec)
            return;
        root._call("codec", card.key, ["pactl", "send-message", "/card/" + card.name + "/bluez", "switch-codec", JSON.stringify(codec)], { kind: "codec", key: card.key, want: codec }, root.profileMs);
    }

    function setOffset(row: var, ms: real): void {
        if (!row || row.cardName === "" || row.activePort === "")
            return;
        root._call("offset", row.key, ["pactl", "set-port-latency-offset", row.cardName, row.activePort, String(Math.round(ms * 1000))], { kind: "offset", key: row.key, want: ms }, root.portMs);
    }

    function setFormats(row: var, formats: var): void {
        if (!row)
            return;
        root._call("formats", row.key, ["pactl", "set-sink-formats", String(row.serial), formats.join(";")], { kind: "formats", key: row.key, want: formats }, root.portMs);
    }

    // pavucontrol's "Terminate Playback" / "Terminate Recording". pactl has no such verb; a node's destruction is what pipewire-pulse does for it.
    function terminate(row: var): void {
        if (!row)
            return;
        if (row.id < 0) {
            root._setNote(row.key, { state: "failed", text: "Not ended: the stream has no node." });
            return;
        }
        root._call("kill", row.key, ["pw-cli", "destroy", String(row.id)], null, 0);
    }

    function _writeRole(volumes: var, muted: bool, kind: string, wantText: string): void {
        const row = root.roleRow;
        if (!row)
            return;
        root.roleRow = Object.assign({}, row, { volumes: volumes, muted: muted });
        root._index();
        calls.write("role", ["pw-metadata", "-n", "route-settings", "0", Model.EVENT_ROLE_KEY, Model.roleValue(volumes, row.channels, muted), "Spa:String:JSON"], (code, out, err) => {
            if (code === -3)
                return;
            const v = root._verdictOf(code, err);
            if (!v.ok) {
                root.roleRow = row;
                root._index();
                root._setNote(row.key, { state: "failed", text: "Refused: " + v.reason });
            }
        }, root.callDeadlineMs);
    }

    // ---- the test tone ---------------------------------------------------------------------------------------------------------------
    // Into THAT output or nowhere: `node.dont-fallback` makes a tone whose target is gone fail, and the link it makes is read back, so "it played" is a fact.
    function toneProps(): string {
        return "{ node.dont-fallback = true node.dont-reconnect = true media.name = lares-audio-test-tone }";
    }
    function playTone(row: var): void {
        if (!row || row.kind !== "sink")
            return;
        if (root.toneKey === row.key) {
            root._toneStopped = true;
            calls.stopTone();
            return;
        }
        if (calls.busy("tone")) {
            root._toneStopped = true;
            calls.stopTone();
            root._queuedTone = row.key;
            return;
        }
        root._startSound(row, root.toneFile, true);
    }
    property string _queuedTone: ""
    property bool _toneStopped: false
    function _startSound(row: var, file: string, tone: bool): void {
        if (!root._canRun)
            return;
        if (tone) {
            root.toneKey = row.key;
            root._toneSeen = false;
            root._toneFor = row.name;
            toneWatch.restart();
        }
        calls.read("tone", [root.playBin, "--target=" + row.name, "--volume=" + root.toneVolume, "-P", root.toneProps(), file], (code, out, err) => {
            const key = row.key;
            const stopped = root._toneStopped;
            root._toneStopped = false;
            if (tone) {
                root.toneKey = "";
                toneWatch.stop();
                // Stopped by the hand is the end it was asked for; any other end that is not clean is the row's.
                if (code !== 0 && !stopped) {
                    const v = root._verdictOf(code, err);
                    root._setNote(key, { state: "failed", text: "No tone: " + (v.reason || "the player failed.") });
                }
            }
            if (root._queuedTone !== "") {
                const q = root.rowOf(root._queuedTone);
                root._queuedTone = "";
                if (q)
                    root._startSound(q, root.toneFile, true);
            }
        }, root.toneDeadlineMs);
    }
    property bool _toneSeen: false
    property string _toneFor: ""
    Timer {
        id: toneWatch
        interval: root.toneMs
        onTriggered: root._checkTone()
    }
    function _checkTone(): void {
        if (root.toneKey === "" || !root.pipewire)
            return;
        const dest = root.pipewire.linkTargetOf ? root.pipewire.linkTargetOf("lares-audio-test-tone") : "";
        if (dest === root._toneFor)
            return;
        const d = root.rowOf("d:sink:" + dest);
        root._setNote(root.toneKey, { state: "failed", text: Model.failText({ kind: "tone", wantText: (root.rowOf(root.toneKey) || {}).shortName || root._toneFor }, d ? d.shortName : dest) });
    }
    // pavucontrol's feedback sound, at the end of a gesture on a sink.
    function tick(row: var): void {
        if (root.settings.feedback === true && row && row.kind === "sink" && !calls.busy("tone"))
            root._startSound(row, root.tickFile, false);
    }

    // ---- what is kept, and renames ----------------------------------------------------------------------------------------------------
    // pavucontrol's Rename Device needs module-device-manager's protocol, which pipewire-pulse loads but does not implement (its module registers no
    // extension). A name is the shell's own here: kept with the settings, shown in this popup.
    FileView {
        id: stateFile
        path: root.live ? root.stateDir + "/popup.json" : ""
        printErrors: false
        blockAllReads: true
    }
    property bool _stateRead: false
    function _loadState(): void {
        if (root._stateRead || !root.live)
            return;
        root._stateRead = true;
        try {
            const t = stateFile.text();
            root.settings = t && t !== "" ? JSON.parse(t) : {};
        } catch (e) {
            root.settings = {};
        }
    }
    function _saveState(): void {
        if (!root.live)
            return;
        Quickshell.execDetached(["mkdir", "-p", root.stateDir]);
        stateFile.setText(JSON.stringify(root.settings, null, 2) + "\n");
    }
    function setSetting(key: string, value: var): void {
        const n = Object.assign({}, root.settings);
        n[key] = value;
        root.settings = n;
        root._saveState();
    }
    function setFilter(section: string, index: int): void {
        const f = Object.assign({}, root.settings.filters || {});
        f[section] = index;
        root.setSetting("filters", f);
    }
    function setLabel(row: var, text: string): void {
        if (!row)
            return;
        const next = Object.assign({}, root._labels);
        const t = text.trim();
        if (t === "" || t === row.originalDescription)
            delete next[row.kind + ":" + row.name];
        else
            next[row.kind + ":" + row.name] = t;
        root.setSetting("labels", next);
        root._remerge();
    }
}
