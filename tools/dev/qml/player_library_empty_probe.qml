pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import Quickshell

import "modules/common/theme"
import "modules/common/components/MpdHealth.js" as Health
import "modules/bar/player/components"

// =============================================================================
// player_library_empty_probe.qml -- the player's empty library names the dead daemon (PlayerLibrary, commit 7bf8040a). The REAL PlayerLibrary over a
// plain mock player (no mpd, no PipeWire, no process) whose `health` is built by the real MpdHealth.diagnose, the library empty:
//   healthy            "Nothing here" (grouping albums), "No playlists" (grouping playlists)
//   mpd-down           the health title, "mpd is not running"   (and mpd-unreachable / mpd-stuck: their own titles)
//   a sound fault      (device stall, kind not mpd-*) the library still says "Nothing here"
//   health not shown   even an mpd-* diagnosis says "Nothing here" (the banner is not up)
// Read from the emptyLabel Text's `text`, once it is drawn (opacity 1). Run by tools/dev/player_library_empty_probe.sh; bare it quits at once
// (no PLE_RUN). One `PLE ok|FAIL <id>: what` line per check, then `PLE DONE PASS|FAIL`.
// =============================================================================
ShellRoot {
    id: probe
    settings.watchFiles: false
    readonly property bool run: Quickshell.env("PLE_RUN") === "1"
    property int checks: 0
    property int fails: 0
    function check(id: string, ok: bool, what: string): void {
        probe.checks++;
        if (!ok)
            probe.fails++;
        console.log("PLE " + (ok ? "ok  " : "FAIL ") + id + ": " + what);
    }
    Timer { interval: 0; running: !probe.run; onTriggered: Qt.quit() }

    function diag(f: var, shown: bool): var {
        const dac = { id: 1, name: "alsa_output.usb-X", desc: "A DAC", state: "running", error: "", default: true };
        const probeFacts = (o) => Object.assign({ pw: "ok", sinks: [dac], procs: { mpd: ["S"], wireplumber: ["S"], pipewire: ["S"] }, wchan: {} }, o || {});
        const base = { down: false, stuck: false, error: false, stalled: false, errorText: "" };
        const d = Health.diagnose(Object.assign(base, f, { probe: probeFacts(f.procs !== undefined ? { procs: f.procs } : {}) }));
        return Object.assign({}, d, { busy: false, busyWords: "", outcome: "", outcomeWords: "", shown: shown });
    }

    QtObject {
        id: mock
        property var health: ({ kind: "ok", severity: "", title: "", words: "", hint: "", action: null, device: "", shown: false })
        property var albums: []
        property var artists: []
        property var genres: []
        property var recent: []
        property var playlists: []
        property bool libraryLoading: false
        property bool artistsIncludeLoose: false
    }

    Window {
        id: win
        visible: probe.run
        width: 420
        height: 560
        color: Theme.surface
        PlayerLibrary {
            id: lib
            anchors.fill: parent
            player: mock
            albums: mock.albums
            artists: mock.artists
            genres: mock.genres
            recent: mock.recent
            playlists: mock.playlists
            loading: false
        }
    }

    // the empty line: the Text that is drawn (opacity 1) among the library's children, found as the visible one that shows an empty-list word or an mpd health title
    readonly property var emptyWords: ["Nothing here", "No playlists", "No match", "No matches", "mpd is not running", "mpd is not answering", "mpd is stuck", "mpd stopped answering"]
    function findEmpty(item: Item): var {
        if (!item)
            return null;
        if (typeof item.text === "string" && probe.emptyWords.indexOf(item.text) >= 0 && item.visible && item.opacity > 0.99)   // qmllint disable missing-property
            return item;
        for (let i = 0; i < item.children.length; i++) {
            const r = probe.findEmpty(item.children[i]);
            if (r)
                return r;
        }
        return null;
    }
    function said(): string {
        const t = probe.findEmpty(lib);
        return t ? String(t.text) : "";   // qmllint disable missing-property
    }

    // wait until the line reads `want`, naming what was read when the time box runs out
    function expect(id: string, want: string, what: string): var {
        return w => {
            if (probe.said() === want) {
                probe.check(id, true, what + " ('" + want + "')");
                return true;
            }
            if (w < 4000)
                return "wait";
            probe.check(id, false, what + ": wanted '" + want + "', read '" + probe.said() + "'");
            return true;
        };
    }

    property var steps: []
    property int stepAt: 0
    property real stepStarted: 0
    Timer {
        id: driver
        interval: 40
        repeat: true
        onTriggered: {
            if (probe.stepAt >= probe.steps.length) {
                driver.stop();
                console.log("PLE DONE " + (probe.fails === 0 && probe.checks > 0 ? "PASS" : "FAIL") + " (" + (probe.checks - probe.fails) + "/" + probe.checks + ")");
                Qt.quit();
                return;
            }
            const waited = Date.now() - probe.stepStarted;
            let r = true;
            try {
                r = probe.steps[probe.stepAt](waited);
            } catch (e) {
                probe.check("step" + probe.stepAt, false, "threw: " + e);
            }
            if (r === "wait")
                return;
            probe.stepAt++;
            probe.stepStarted = Date.now();
        }
    }
    Component.onCompleted: Qt.callLater(() => {
        if (!probe.run) {
            Qt.quit();
            return;
        }
        probe.steps = [
            probe.expect("healthy", "Nothing here", "a healthy player with an empty library says"),
            () => { mock.health = probe.diag({ down: true, procs: {} }, true); },
            probe.expect("mpd-down", "mpd is not running", "mpd down: the empty library names the daemon"),
            () => { mock.health = probe.diag({ down: true, procs: { mpd: ["S"] } }, true); },
            probe.expect("mpd-unreachable", "mpd is not answering", "mpd up but refusing: the empty library says"),
            () => { mock.health = probe.diag({ down: true, procs: { mpd: ["D"] } }, true); },
            probe.expect("mpd-stuck", "mpd is stuck", "mpd in D state: the empty library says"),
            () => { mock.health = probe.diag({ stalled: true }, true); },
            probe.expect("sound-fault", "Nothing here", "a sound fault that is not mpd-* leaves the empty library's own word"),
            () => { mock.health = probe.diag({ down: true, procs: {} }, false); },
            probe.expect("hidden-banner", "Nothing here", "an mpd-* diagnosis whose banner is not shown leaves the empty library's own word"),
            () => { mock.health = probe.diag({ down: true, procs: {} }, true); lib.grouping = "playlists"; },
            probe.expect("playlists-down", "mpd is not running", "the dead daemon outranks 'No playlists' too"),
            () => { mock.health = probe.diag({}, false); },
            probe.expect("playlists-healthy", "No playlists", "healthy again, playlists says")
        ];
        probe.stepStarted = Date.now();
        driver.start();
    })
}
