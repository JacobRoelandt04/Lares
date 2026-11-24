import QtQuick
import QtQuick.Window
import Quickshell
import "modules/common/components"
import "modules/common/locale"
import "modules/shell"
import "modules/osd/data"
import "modules/notifications/data"
import "modules/windowtray/data"
import "modules/stocks/data"
import "modules/wiki/data"
import "modules/silicon/data"
import "modules/clock/data"
import "modules/weather/data"
import "modules/launcher/data"
import "modules/idle"
import "modules/bar/llm"

// tools/dev/qml/config_loaders_probe.qml -- every QML config loader reads `<name>.jsonc` first and `<name>.json` after it, comments allowed.
// tools/dev/config_loaders_probe.sh makes four directories (CL_ROOT/A..D) holding each loader's file in the shape of the scenario:
//   A  .jsonc valid with comments + .json GARBAGE   -> the loader read the .jsonc          (ok)
//   B  .jsonc GARBAGE + .json valid                 -> the .jsonc is the one in force, so  (not ok)
//   C  .json only, valid with comments              -> the older name still works          (ok)
//   D  neither                                      -> the defaults                        (none)
// The loaders build on their own paths (no XDG, no desktop); a loader's verdict is "ok" / "bad" / "none".
// Prints CL lines and "CL RESULT PASS|FAIL".
Scope {
    id: root
    property string base: Quickshell.env("CL_ROOT")
    property int fails: 0
    property int checks: 0

    function check(name: string, ok: bool, detail: string): void {
        root.checks++;
        if (!ok) root.fails++;
        console.log("CL " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }

    // one bundle of loaders over a scenario's directory
    Component {
        id: bundle
        Item {
            id: b
            property string dir
            OsdConfig { id: osd; configPath: b.dir + "/osd.json" }
            ShellConfig { id: shell; configPath: b.dir + "/shell.json" }
            NotificationConfig { id: notif; configPath: b.dir + "/notifications.json" }
            WindowTrayConfig { id: wtray; configPath: b.dir + "/windowtray.json" }
            StocksConfig { id: stocks; configPath: b.dir + "/stocks.json" }
            WikiConfig { id: wiki; configPath: b.dir + "/wiki.json" }
            SiliconConfig { id: silicon; configPath: b.dir + "/silicon.json" }
            CalendarConfig { id: calendars; configPath: b.dir + "/calendars.json" }
            WeatherConfig { id: weather; configPath: b.dir + "/weather.json" }
            LauncherConfig { id: launcher; path: b.dir + "/launcher.json" }
            LocaleConfig { id: locale; path: b.dir + "/locale.json"; examplePath: b.dir + "/none.example.json" }
            IdleConfig { id: idle; configPath: b.dir + "/idle.json" }
            LlmConfig { id: llm; configPath: b.dir + "/llm.json" }

            function ofPresent(c): string {
                if (c.lastError !== "") return "bad";
                return c.present ? "ok" : "none";
            }
            function states(): var {
                return {
                    osd: b.ofPresent(osd), shell: b.ofPresent(shell), notifications: b.ofPresent(notif),
                    windowtray: b.ofPresent(wtray), stocks: b.ofPresent(stocks), wiki: b.ofPresent(wiki),
                    silicon: b.ofPresent(silicon),
                    calendars: calendars.available ? "ok" : (calendars.lastError !== "" ? "bad" : "none"),
                    weather: weather.lastError === "" ? "ok" : (weather.lastError.indexOf("not found") >= 0 ? "none" : "bad"),
                    launcher: launcher.error !== "" ? "bad" : (launcher.exists ? "ok" : "none"),
                    locale: locale.source === "user" ? "ok" : "none",
                    idle: b.ofPresent(idle), llm: b.ofPresent(llm)
                };
            }
        }
    }

    // the loaders are Items: a hidden window gives them a scene (an Item tree made with no window is a crash, CLAUDE.md)
    Window { id: stage; visible: false; width: 1; height: 1 }
    property var _bundles: ({})
    Timer {
        interval: 0
        running: true
        onTriggered: {
            for (const s of ["A", "B", "C", "D"])
                root._bundles[s] = bundle.createObject(stage.contentItem, { dir: root.base + "/" + s });
            settle.start();
        }
    }
    // The loaders read at creation (blockLoading); the weather's lookup and the launcher's first read need a turn.
    Timer {
        id: settle
        interval: 600
        onTriggered: {
            const names = ["osd", "shell", "notifications", "windowtray", "stocks", "wiki", "silicon", "calendars", "weather",
                           "launcher", "locale", "idle", "llm"];
            const st = {};
            for (const s of ["A", "B", "C", "D"]) st[s] = root._bundles[s].states();
            for (const n of names) {
                root.check(n + ": A, a .jsonc with comments beside a garbage .json, is read", st.A[n] === "ok", st.A[n]);
                root.check(n + ": B, a garbage .jsonc beside a good .json, is the one in force", st.B[n] !== "ok", st.B[n]);
                root.check(n + ": C, only a .json with comments, still works", st.C[n] === "ok", st.C[n]);
                root.check(n + ": D, neither file, is the defaults", st.D[n] === "none", st.D[n]);
            }
            console.log("CL RESULT " + (root.fails === 0 ? "PASS" : "FAIL") + " (" + (root.checks - root.fails) + "/" + root.checks + ")");
            quitTimer.start();
        }
    }
    Timer { id: quitTimer; interval: 0; onTriggered: Qt.quit() }
}
