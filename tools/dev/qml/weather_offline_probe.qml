pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import Quickshell

import "modules/common/theme"
import "modules/weather"
import "modules/weather/data"

// =============================================================================
// tools/dev/qml/weather_offline_probe.qml -- the weather popup's header note says 'offline, retrying' in the warn colour when
// there is no cache and the first fetch failed (76e257e3). The real WeatherPopup on WeatherMock, its facts written by hand.
// Runner: tools/dev/weather_offline_probe.sh. Prints WO lines and "WO RESULT PASS|FAIL". A bare smoke (no PROBE=1) quits.
//
//   healthy   a model, online: "updated <time>" in the faint ink, nothing offline shown
//   cached    offline with a model: "offline, from <time>" in warn
//   nocache   offline with no model, not loading: "offline, retrying" in warn
//   quiet     no model, not offline, not loading: no note at all
//   loading   no model, loading, offline: no note (the skeleton stands in)
// =============================================================================
Scope {
    id: root
    readonly property bool live: Quickshell.env("PROBE") === "1"
    property int fails: 0
    property int checks: 0
    function check(name: string, ok: bool, detail: string): void {
        root.checks++;
        if (!ok)
            root.fails++;
        console.log("WO " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }

    Window {
        id: win
        visible: root.live
        width: 900
        height: 800
        color: Theme.surface
        WeatherMock {
            id: mock
        }
        WeatherPopup {
            id: popup
            x: 10
            y: 10
            service: mock
            viewMode: "detailed"
            fontFamily: "Inter"
            backdropRunning: false
            cardFloat: false
            width: implicitWidth
            height: implicitHeight
        }
    }

    // the header note on show: a visible Text that starts "updated" or "offline"
    function note(): var {
        let found = null;
        const walk = it => {
            if (!found && it.text !== undefined && /^(updated|offline)/.test(String(it.text)) && it.visible)
                found = it;
            for (let i = 0; i < it.children.length; i++)
                walk(it.children[i]);
        };
        walk(popup);
        return found;
    }

    property var _model: null
    property int _i: -1
    readonly property var steps: [
        () => {
            root._model = mock.model;
            return () => {
                const n = root.note();
                root.check("healthy: a model exists", !!root._model, "");
                root.check("healthy: 'updated <time>' in the faint ink", !!n && /^updated /.test(n.text) && Qt.colorEqual(n.color, Theme.textFaint), n ? n.text + " " + n.color : "no note");
            };
        },
        () => {
            mock.offline = true;
            return () => {
                const n = root.note();
                root.check("cached: 'offline, from <time>' in warn", !!n && /^offline, from /.test(n.text) && Qt.colorEqual(n.color, Theme.warn), n ? n.text + " " + n.color : "no note");
            };
        },
        () => {
            mock.model = null;
            return () => {
                const n = root.note();
                root.check("nocache: 'offline, retrying' in warn", !!n && n.text === "offline, retrying" && Qt.colorEqual(n.color, Theme.warn), n ? n.text + " " + n.color : "no note");
            };
        },
        () => {
            mock.offline = false;
            return () => {
                const n = root.note();
                root.check("quiet: no note when nothing failed and nothing is cached", n === null, n ? n.text : "");
            };
        },
        () => {
            mock.offline = true;
            mock.loading = true;
            return () => {
                const n = root.note();
                root.check("loading: no note while the first fetch is out", n === null, n ? n.text : "");
            };
        }
    ]
    property var _judge: null
    function next(): void {
        if (root._judge) {
            root._judge();
            root._judge = null;
        }
        root._i++;
        if (root._i >= root.steps.length) {
            console.log("WO RESULT " + (root.fails === 0 && root.checks > 0 ? "PASS" : "FAIL") + " (" + (root.checks - root.fails) + "/" + root.checks + " checks)");
            Qt.quit();
            return;
        }
        root._judge = root.steps[root._i]();
        stepTimer.restart();
    }
    Timer {
        id: stepTimer
        interval: 300
        onTriggered: root.next()
    }
    Timer {
        interval: 1500
        running: true
        onTriggered: {
            if (!root.live) {
                Qt.quit();
                return;
            }
            root.next();
        }
    }
}
