pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import "../../../common/components"
import "../../../audio/airplay"

// =============================================================================
// MpdSource.qml -- the track card: the media keys, and MPD's own track changes.
//
//   media(verb)                "next" | "prev" | "toggle" | "stop": does it on
//                              MPD and asks for a track card
//   others                     the keys are another player's while MPD has no song in play (osd.jsonc media.keys "auto"; below)
//   signal request(var req)    one partial CONTRACT section 1 request
//
// WHAT SHOWS. The song changing while MPD plays (a key, the queue running on,
// another client) -- not the first song the service reports after it connects
// (the baseline), not a song nobody hears. A media key shows the card whatever
// came of it: `next` / `prev` show the new song when it arrives, and when
// nothing arrives (`prev` after three seconds of a song only restarts it, `next`
// on the last song of a non-repeating queue stops) the card is shown anyway
// after `fallbackMs`, with the action on it; `toggle` and `stop` show the card
// with the state they reached.
//
// AIRPLAY. While mpd plays into an AirPlay speaker the sound lags mpd's own facts by the sink's buffer (AirplayDelay.delayMs, 0
// otherwise): a song change that came by itself shows its card that much later, so it arrives with the music. A media key's card
// is the key's own feedback and shows at once. A newer change during the wait replaces the pending card, a stop, a disconnect or a
// key's own card drops it.
//
// ANOTHER PLAYER (`others`). MPD plays or is paused with a song: the keys are its, as ever. Else `playerctl` (MPRIS: a browser, a video) is
// asked which player plays -- the one that plays, else one that is paused --, the verb goes to that one, and the card says what it has
// (its cover only from a file: no picture is fetched from the net). No player at all: the key is MPD's again. Without playerctl that is
// said once in the log and the keys are MPD's. One press at a time; a press during another's answer waits for it.
//
// The card's `art` is the song's cover URL. A cover that was not on disk yet
// lands a moment later (`coverArtResolved`): the same request goes out again,
// in place, with the picture in it.
//
// `live: false` has no MPD: simulateReady(state, songId) is the baseline,
// simulateSong(song, state) the service saying a different song is current,
// simulateState(state) the play state moving. `backend` hands in the shell's
// own MpdService.
// =============================================================================
Item {
    id: root

    property bool live: true
    property var backend: null
    property int fallbackMs: 450

    signal request(var req)

    // The facts, as the service reads them (simulated or live).
    property var _song: null           // { id, title, artist, album, file, coverUrl }
    property string _state: "stop"
    property int _lastId: -2           // -2 = nothing read yet
    property string _action: ""        // the verb a key is waiting on
    property bool _answered: false
    property string _shownFile: ""
    property string _shownArt: "x"
    property bool _shownByKey: false

    // ---- observers --------------------------------------------------------------
    function _observeSong(song, state) {
        root._song = song;
        root._state = state;
        const id = song ? song.id : -1;
        const first = root._lastId === -2;
        const changed = id !== root._lastId;
        root._lastId = id;
        if (first || !changed || !song)
            return;
        // A song that comes up while stopped or paused is not a track change
        // anybody hears -- unless a key asked for it.
        if (state !== "play" && root._action === "")
            return;
        if (root._action === "" && AirplayDelay.delayMs > 0) {
            root._pendingId = id;
            lag.interval = AirplayDelay.delayMs;
            lag.restart();
            return;
        }
        root._dropPending();
        root._emit(root._action, root._action !== "");
    }

    // A card waiting for the sound (AirPlay): the song it is for, so the answer is dropped if that is no longer the song.
    property int _pendingId: -1
    function _dropPending() {
        lag.stop();
        root._pendingId = -1;
    }
    Timer {
        id: lag
        onTriggered: {
            const id = root._pendingId;
            root._pendingId = -1;
            if (id >= 0 && root._song && root._song.id === id && root._state === "play")
                root._emit("", false);
        }
    }

    function _observeState(state) {
        root._state = state;
        if (state === "stop")
            root._dropPending();
        if (root._action === "toggle" || root._action === "stop")
            root._emit(root._action, true);
    }

    // `byKey`: the card is a media key's, or updates one that is.
    function _emit(action, byKey) {
        const s = root._song;
        if (!s)
            return;
        if (action !== "")
            root._answered = true;
        root._shownFile = s.file || "";
        root._shownArt = s.coverUrl || "";
        root._shownByKey = byKey;
        root.request({
            kind: "track",
            key: "track",
            source: action !== "" ? "key" : "external",
            event: byKey ? "key" : "change",
            track: {
                title: s.title || "",
                artist: s.artist || "",
                album: s.album || "",
                art: s.coverUrl || "",
                state: root._state,
                action: action
            }
        });
    }

    // A cover that arrived after the card went out.
    function _artLanded(file) {
        const s = root._song;
        if (!s || s.file !== file || root._shownFile !== file)
            return;
        if ((s.coverUrl || "") === root._shownArt || !s.coverUrl)
            return;
        root._emit("", root._shownByKey);
    }

    // ---- the media keys -----------------------------------------------------------
    function media(verb) {
        if (["next", "prev", "toggle", "stop"].indexOf(verb) < 0)
            return false;
        if (root.others && !root._inPlay()) {
            root._askOthers(verb);
            return true;
        }
        return root._mpdKey(verb);
    }

    function _mpdKey(verb) {
        if (root.live) {
            const m = root._svc;
            if (!m || !m.connected)
                return false;
            root._act(m, verb);
        }
        root._dropPending();
        root._action = verb;
        root._answered = false;
        settle.restart();
        return true;
    }

    function _act(m, verb) {
        if (verb === "next") m.next();
        else if (verb === "prev") m.prev();
        else if (verb === "toggle") m.toggle();
        else m.stop();
    }

    // ---- another player (the header) ------------------------------------------------
    property bool others: false
    // The program (a probe's seam), and whether it was found missing.
    property string playerctl: "playerctl"
    property bool _noPlayerctl: false
    property var _waiting: []           // verbs pressed while another's answer is out

    // MPD has a song in play: it plays, or is paused in one.
    function _inPlay() {
        const m = root.live ? root._svc : null;
        return !!m && m.connected && m.playState !== "stop" && !!m.current;
    }
    function _askOthers(verb) {
        if (root._noPlayerctl) {
            root._mpdKey(verb);
            return;
        }
        if (otherProc.running) {
            root._waiting = root._waiting.concat([verb]);
            return;
        }
        otherProc.verb = verb;
        otherProc.command = ["timeout", "-k", "1", "4", "sh", "-c", otherProc.script, "sh", root.playerctl, ({ next: "next", prev: "previous", toggle: "play-pause", stop: "stop" })[verb]];
        otherProc.running = true;
    }
    function _otherDone(code, text) {
        const verb = otherProc.verb;
        if (code === 127) {
            root._noPlayerctl = true;
            console.warn("OsdService: media.keys is \"auto\" and playerctl is not installed; the media keys are mpd's alone");
        }
        const f = code === 0 ? text.replace(/\n$/, "").split("\x1f") : [];
        if (code === 3 || code === 127)
            root._mpdKey(verb);
        else if (f.length >= 5)
            root.request({
                kind: "track", key: "track", source: "key", event: "key",
                track: {
                    title: f[1], artist: f[2], album: f[3], art: f[4].indexOf("file://") === 0 ? f[4] : "",
                    state: f[0] === "Playing" ? "play" : f[0] === "Paused" ? "pause" : "stop", action: verb
                }
            });
        if (root._waiting.length > 0) {
            const next = root._waiting[0];
            root._waiting = root._waiting.slice(1);
            Qt.callLater(root.media, next);
        }
    }
    Process {
        id: otherProc
        property string verb: ""
        // The player that plays, else one that is paused (3: none); the verb (4: it would not), a moment for it to answer, what it says now.
        readonly property string script: 'command -v "$1" > /dev/null 2>&1 || exit 127\n'
            + 'p=$("$1" -a --format "{{status}} {{playerInstance}}" status 2> /dev/null | awk \'$1 == "Playing" { print $2; f = 1; exit } $1 == "Paused" && !q { q = $2 } END { if (!f && q) print q }\')\n'
            + '[ -n "$p" ] || exit 3\n'
            + '"$1" -p "$p" "$2" 2> /dev/null || exit 4\n'
            + 'sleep 0.25\n'
            + 's=$(printf "\\037")\n'
            + '"$1" -p "$p" --format "{{status}}${s}{{title}}${s}{{artist}}${s}{{album}}${s}{{mpris:artUrl}}" metadata 2> /dev/null || exit 4'
        stdout: StdioCollector {
            id: otherOut
        }
        onExited: code => root._otherDone(code, otherOut.text)
    }

    // A key's answer window: `next` / `prev` are answered by the song change,
    // `toggle` / `stop` by the state change; if neither came, the card is shown
    // with what is there. Then the key's claim on the next change ends.
    Timer {
        id: settle
        interval: root.fallbackMs
        onTriggered: {
            if (!root._answered && root._song)
                root._emit(root._action, true);
            root._action = "";
        }
    }

    // ---- the live half --------------------------------------------------------------
    // THE FALLBACK. A source with no backend can build a service of its own (an MpdService). SHELL-HOSTED
    // (CONTRACT section 4): the backend is the shell's one MpdService, injected, and a null one means the
    // feature is ABSENT -- a hosted source never builds a service of its own -- said once in the log,
    // because it is a wiring fault, not a state.
    property bool shellHosted: false
    // How many services this source has built for itself (a probe reads it; nothing binds to it).
    property int builds: 0
    Component.onCompleted: {
        if (root.shellHosted && root.live && root.backend === null)
            console.warn("OsdService: shell-hosted but the mpd source got no backend; it stays absent (it does not build its own MpdService)");
    }

    Loader {
        id: loader
        active: root.live && root.backend === null && !root.shellHosted
        sourceComponent: MpdService {}
        onLoaded: root.builds++
    }
    readonly property var _svc: root.backend !== null ? root.backend : loader.item

    Connections {
        target: root.live ? root._svc : null
        ignoreUnknownSignals: true
        function onSongChanged() {
            root._observeSong(root._svc.current, root._svc.playState);
        }
        function onPlayStateChanged() {
            root._observeState(root._svc.playState);
        }
        function onCoverArtResolved(file) {
            root._song = root._svc.current;
            root._artLanded(file);
        }
        function onConnectedChanged() {
            // A (re)connection re-reads the song: that is a baseline, not a track change.
            if (!root._svc.connected) {
                root._lastId = -2;
                root._dropPending();
            }
        }
    }

    // ---- simulation (live: false) ------------------------------------------------------
    function simulateReady(state, songId) {
        root._observeSong({ id: songId, title: "", artist: "", album: "", file: "", coverUrl: "" }, state);
    }
    function simulateSong(song, state) {
        root._observeSong(song, state);
    }
    function simulateState(state) {
        root._observeState(state);
    }
    function simulateArt(file, url) {
        const s = root._song;
        if (s && s.file === file)
            root._song = Object.assign({}, s, { coverUrl: url });
        root._artLanded(file);
    }
}
