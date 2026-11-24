pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import QtTest

import "modules/shell"

// =============================================================================
// tools/dev/qml/bar_clicks_probe.qml -- shell.jsonc `clicks`: the real ModuleSlot and BarClicks over a stand-in frame and services, clicked for real
// (QtTest). tools/dev/bar_clicks_probe.sh runs it. Prints `BARCLICK ok|FAIL <check>` and `BARCLICK RESULT PASS|FAIL (<n>/<n> checks)`.
// =============================================================================
Window {
    id: win
    visible: true
    width: 400
    height: 60

    property int fails: 0
    property int checks: 0
    function check(name: string, ok: bool, detail: string): void {
        win.checks++;
        if (!ok)
            win.fails++;
        console.log("BARCLICK " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }
    function same(name: string, got: var, want: var): void {
        win.check(name, JSON.stringify(got) === JSON.stringify(want), JSON.stringify(got) + " want " + JSON.stringify(want));
    }

    // what was asked, oldest first
    property var asked: []
    function ask(what: string): void { win.asked = win.asked.concat([what]); }
    function taken(): var { const a = win.asked; win.asked = []; return a; }

    QtObject {
        id: fakeServices
        property var lock: QtObject { property bool locked: false }
        property var shellConfig: QtObject { property var clicks: ({}) }
        property var commands: QtObject { function run(argv: var, o: var): void { win.ask("run " + argv.join(" ") + (o.detached ? " detached" : "")); } }
        property var mpd: QtObject { function toggle(): void { win.ask("toggle"); } function next(): void { win.ask("next"); } }
        property var notifications: QtObject { property bool dnd: false }
        property var weather: QtObject {
            property var locations: ["a", "b", "c"]
            property int locationIndex: 2
            function selectLocation(i: int): void { win.ask("place " + i); }
        }
        property var timers: QtObject {
            property var countdown: ({ state: "idle" })
            property var pomodoro: ({ state: "idle" })
            property var stopwatch: ({ state: "idle" })
            property var touched: ({ countdown: 0, pomodoro: 0, stopwatch: 0 })
            function pause(): void { win.ask("pause"); }
            function resume(): void { win.ask("resume"); }
            function pomoPause(): void { win.ask("pomoPause"); }
            function pomoResume(): void { win.ask("pomoResume"); }
            function pomoStart(): void { win.ask("pomoStart"); }
            function swPause(): void { win.ask("swPause"); }
            function swStart(): void { win.ask("swStart"); }
        }
    }
    Item {
        id: fakeFrame
        anchors.fill: parent
        property var services: fakeServices
        property var owners: ({
                clock: { openTimers: k => win.ask("openTimers"), toggle: () => win.ask("clock popup") },
                audio: { toggle: () => win.ask("audio popup") }
            })
        readonly property alias barClicks: clicks
        function rowFor(id: string): Item { return fakeFrame; }
        function xOf(id: string): real { return ({ theme: 0, clock: 50, player: 150, volume: 250 })[id]; }
        function wOf(id: string): real { return id === "clock" || id === "volume" ? 100 : 40; }
        readonly property real topThickness: 40
        function moduleOn(id: string): bool { return true; }
        BarClicks {
            id: clicks
            frame: fakeFrame
            volume: pill
        }
        component Button: MouseArea {
            property string name: ""
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: mouse => win.ask(name + (mouse.button === Qt.RightButton ? " right" : " left"))
            onWheel: wheel => win.ask(name + " wheel")
        }
        ModuleSlot { host: fakeFrame; moduleId: "theme"; Button { id: themeB; name: "theme" } }
        ModuleSlot {
            host: fakeFrame
            moduleId: "clock"
            clickBox: box
            Button { name: "groove" }
            Item { id: box; x: 30; width: 40; height: 40; Button { name: "clock" } }
        }
        ModuleSlot { host: fakeFrame; moduleId: "player"; Button { name: "player" } }
        ModuleSlot {
            host: fakeFrame
            moduleId: "volume"
            Item {
                id: pill
                x: 10
                width: 80
                height: 40
                function halfAt(x: real, y: real): int { return x < 40 ? 0 : 1; }
                function click(half: int, button: int): void { win.ask("mute " + half); }
                Button { name: "volume" }
            }
        }
    }

    TestCase {
        id: tc
        when: false
        name: "clicks"
    }
    function click(x: real, button: int): var {
        tc.mouseMove(win.contentItem, x - 1, 20);
        tc.mouseMove(win.contentItem, x, 20);
        tc.mouseClick(win.contentItem, x, 20, button);
        return win.taken();
    }

    Timer {
        interval: 300
        running: true
        onTriggered: {
            const L = Qt.LeftButton, R = Qt.RightButton, M = Qt.MiddleButton;
            win.same("nothing written: the button has its own right click", win.click(20, R), ["theme right"]);
            fakeServices.shellConfig.clicks = { theme: { right: "none" }, player: { middle: "next", right: "toggle" },
                clock: { right: ["xdg-open", "https://calendar.proton.me"], middle: "timer" }, volume: { right: "mute", middle: ["pavucontrol"] } };
            win.same("\"none\": a right click does nothing", win.click(20, R), []);
            win.same("... and the left click is the button's", win.click(20, L), ["theme left"]);
            win.check("... and the hover", themeB.containsMouse, "no hover");
            tc.mouseWheel(win.contentItem, 20, 20, 0, 120);
            win.same("... and the wheel", win.taken(), ["theme wheel"]);
            win.same("a word of the button", win.click(170, M), ["next"]);
            win.same("another", win.click(170, R), ["toggle"]);
            win.same("a command, by itself", win.click(100, R), ["run xdg-open https://calendar.proton.me detached"]);
            win.same("only the button's own box: the rest of the slot is what it was", win.click(58, R), ["groove right"]);
            win.same("the volume's mute is the half under the pointer (left)", win.click(275, R), ["mute 0"]);
            win.same("... (right)", win.click(325, R), ["mute 1"]);
            win.same("a middle click where the button takes none", win.click(300, M), ["run pavucontrol detached"]);
            // the timer
            const t = fakeServices.timers;
            win.same("timer: none in progress opens the timers", win.click(100, M), ["openTimers"]);
            t.countdown = { state: "running" };
            t.touched = { countdown: 5, pomodoro: 0, stopwatch: 0 };
            win.same("timer: the running one is paused", win.click(100, M), ["pause"]);
            t.countdown = { state: "paused" };
            t.pomodoro = { state: "waiting" };
            t.touched = { countdown: 5, pomodoro: 9, stopwatch: 0 };
            win.same("timer: the one started last (a pomodoro that waits starts)", win.click(100, M), ["pomoStart"]);
            t.touched = { countdown: 10, pomodoro: 9, stopwatch: 0 };
            win.same("timer: a paused one goes on", win.click(100, M), ["resume"]);
            fakeServices.shellConfig.clicks = { theme: { middle: "popup" }, clock: { right: "popup" }, weather: { right: "nextPlace" } };
            win.same("popup: the button's own", win.click(100, R), ["clock popup"]);
            clicks.click("weather", R, themeB, 0, 0);
            win.same("weather: the next place, round again", win.taken(), ["place 0"]);
            clicks.click("notifications", R, themeB, 0, 0);
            win.check("a button the file does not name does nothing here", !fakeServices.notifications.dnd, "");
            fakeServices.lock.locked = true;
            win.same("locked: the button's own clicks, none of the file's", win.click(100, R), ["clock right"]);
            clicks.click("clock", R, themeB, 0, 0);
            win.same("locked: nothing runs whoever asks", win.taken(), []);
            console.log("BARCLICK RESULT " + (win.fails === 0 ? "PASS" : "FAIL") + " (" + (win.checks - win.fails) + "/" + win.checks + " checks)");
            Qt.quit();
        }
    }
}
