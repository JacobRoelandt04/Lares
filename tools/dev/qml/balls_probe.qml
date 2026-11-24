pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "modules/common/components"
import "modules/common/theme"
import "modules/audio"
import "modules/audio/data"
import "modules/shell"

// tools/dev/qml/balls_probe.qml -- the squishy ball of GrooveSlider / SlotRail, frame by frame (tools/dev/balls_probe.sh runs it and
// tools/dev/balls_judge.py reads what it writes). It grabs the stage on every frame into BALLS_OUT/f<n>.png and prints one
// "BALLS F <n> <json>" line per grab request: the rects of the things being judged (mapped to the stage), AS THEY STOOD when the grab was
// asked, with their effective opacity. A grab lands a frame after its request, so the judge reads the PICTURE of a frame (its own ink),
// with a margin round each rect, never the counter beside it.
//
//   BALLS_MODE=slider  a GrooveSlider is made fresh (a Loader switched on), ball away from its start
//   BALLS_MODE=popup   the real AudioPopup on AudioMock made fresh; then the tab switched (the rows animate out and in)
//   BALLS_MODE=rail    a SlotRail picks another stop (a squish on the way; round at rest)
//   BALLS_MODE=menu    MenuRows with a run of radio rows, made fresh (the ball is seated, round, in the first frame that has the rows), then another row picked
Window {
    id: win
    width: 560
    height: 560
    visible: true
    color: "#EAEDF5"

    readonly property string mode: Quickshell.env("BALLS_MODE") || "slider"
    readonly property string outDir: Quickshell.env("BALLS_OUT") || "/tmp/balls"
    property int frame: 0
    property bool done: false
    property int pending: 0

    function effOpacity(it: Item): real {
        let o = 1;
        for (let p = it; p; p = p.parent) {
            if (!p.visible)
                return 0;
            o *= p.opacity;
        }
        return o;
    }
    function rectOf(it: Item): var {
        if (!it)
            return null;
        const p = it.mapToItem(stage, 0, 0);
        return { x: p.x, y: p.y, w: it.width, h: it.height, o: win.effOpacity(it) };
    }
    // every Item below `root` with an objectName
    function find(root: Item, name: string, out: var): void {
        for (const c of root.children) {
            if (c.objectName === name)
                out.push(c);
            win.find(c, name, out);
        }
    }

    // what the judge reads: named rects, per request
    property var watch: () => ({})
    function snap(tag: string): void {
        const n = win.frame;
        const info = win.watch();
        info.accent = String(Theme.accent);
        info.groove = String(Theme.headerBox);
        const file = win.outDir + "/f" + String(n).padStart(4, "0") + ".png";
        win.pending++;
        stage.grabToImage(r => {
            r.saveToFile(file);
            win.pending--;
        });
        console.log("BALLS F " + n + " " + tag + " " + JSON.stringify(info));
    }
    function finish(): void {
        if (win.done)
            return;
        win.done = true;
        quitTimer.start();
    }
    Timer {
        id: quitTimer
        interval: 100
        repeat: true
        running: false
        onTriggered: {
            if (win.pending === 0)
                Qt.quit();
        }
    }
    Timer {
        interval: 90000
        running: true
        onTriggered: {
            console.log("BALLS DEADLINE");
            Qt.quit();
        }
    }
    FrameAnimation {
        id: clock
        running: !win.done
        onTriggered: {
            win.frame++;
            win.step(win.frame);
        }
    }

    Item {
        id: stage
        width: win.width
        height: win.height

        // ------------------------------------------------------------------------------------------- slider
        Loader {
            id: sliderLoader
            active: false
            x: 40
            y: 40
            sourceComponent: GrooveSlider {
                objectName: "slider"
                width: 300
                height: Math.round(neededCross)
                orientation: "horizontal"
                value: 0.7
                sparksEnabled: false
                muteEnabled: false
                surfaceColor: "#EAEDF5"
                grooveColor: Theme.headerBox
            }
        }

        // ------------------------------------------------------------------------------------------- popup
        AudioMock {
            id: mock
            popupOpen: true
            settings: ({ meters: false })
        }
        VolumeParity {
            id: pill
            visible: false
            pipewire: mock.world
        }
        Loader {
            id: popupLoader
            active: false
            x: 10
            y: 10
            sourceComponent: AudioPopup {
                service: mock
                parity: pill
                fontFamily: "Inter"
                section: Quickshell.env("BALLS_SECTION") || "playback"
            }
        }

        // ------------------------------------------------------------------------------------------- menu
        Loader {
            id: menuLoader
            active: false
            x: 40
            y: 40
            sourceComponent: MenuRows {
                id: mr
                objectName: "menu"
                width: 220
                ground: Theme.listBox
                pickedId: win.picked
                rows: [
                    { id: "a", label: "Name", check: "radio", checked: true },
                    { id: "b", label: "Date added", check: "radio", checked: false },
                    { id: "c", label: "Size", check: "radio", checked: false },
                    { separator: true },
                    { id: "dir", label: "Ascending" }
                ]
            }
        }

        // ------------------------------------------------------------------------------------------- rail
        SlotRail {
            id: rail
            visible: win.mode === "rail"
            objectName: "rail"
            x: 100
            y: 40
            width: 24
            height: 400
            slotSize: 12
            ballSize: 8
            travelMs: 420
            ground: "#EAEDF5"
            stops: [10, 70, 130, 190, 250].map((y, i) => ({ key: "k" + i, y: y + 20, top: y, height: 40 }))
            currentKey: "k0"
        }
    }

    // the SquishItems below an item (duck-typed: GrooveSlider's ball has no name)
    function balls(root: Item, out: var): void {
        for (const c of root.children) {
            if ("_physicsAwake" in c)
                out.push(c);
            win.balls(c, out);
        }
    }
    property string picked: ""
    // the menu's rail: the SlotRail the MenuRows made
    function menuRail(): var {
        const out = [];
        win.find(stage, "menuRail", out);
        return out.length ? out[0] : null;
    }
    // the audio popup's SlotRails (the device default's)
    function rails(): var {
        const out = [];
        win.find(stage, "defaultRail", out);
        win.find(stage, "socketRail", out);
        // a SlotRail has no height of its own: its groove (a child) is the place
        return out.map(r => {
            const g = [];
            win.find(r, "groove", g);
            return win.rectOf(g.length ? g[0] : r);
        });
    }
    function sliders(): var {
        const out = [];
        win.find(stage, "slider", out);
        return out.map(s => {
            const r = win.rectOf(s);
            const b = [];
            win.balls(s, b);
            r.ball = b.length ? win.rectOf(b[0]) : null;
            return r;
        });
    }

    property int startAt: 8
    function step(n: int): void {
        if (win.mode === "slider") {
            if (n === win.startAt)
                sliderLoader.active = true;
            if (n >= win.startAt - 2 && n < win.startAt + 40)
                win.snap("s");
            if (n === win.startAt + 60)
                win.finish();
            win.watch = () => ({ sliders: win.sliders(), loaded: !!sliderLoader.item });
        } else if (win.mode === "popup") {
            if (n === win.startAt)
                popupLoader.active = true;
            if (n >= win.startAt - 2 && n < win.startAt + 50)
                win.snap("open");
            if (n === win.startAt + 150)
                popupLoader.item.section = Quickshell.env("BALLS_SECTION") ? "playback" : "recording";
            if (n >= win.startAt + 148 && n < win.startAt + 148 + 70)
                win.snap("tab");
            if (n === win.startAt + 300)
                win.finish();
            win.watch = () => ({ sliders: win.sliders(), rails: win.rails(), loaded: !!popupLoader.item });
        } else if (win.mode === "menu") {
            if (n === win.startAt)
                menuLoader.active = true;
            if (n === win.startAt + 60)
                win.picked = "c";
            if ((n >= win.startAt - 2 && n < win.startAt + 30) || (n >= win.startAt + 58 && n < win.startAt + 110))
                win.snap(n < win.startAt + 58 ? "open" : "pick");
            if (n === win.startAt + 140)
                win.finish();
            win.watch = () => {
                const r = win.menuRail();
                return { rail: r ? win.rectOf(r) : null, moving: r ? r.moving : false, seated: r ? r.seated : false, rows: menuLoader.item ? win.rectOf(menuLoader.item) : null };
            };
        } else if (win.mode === "rail") {
            if (n === win.startAt)
                rail.currentKey = "k3";
            if (n >= win.startAt - 2 && n < win.startAt + 40)
                win.snap("r");
            if (n === win.startAt + 90)
                win.finish();
            win.watch = () => ({ rail: win.rectOf(rail), ballY: rail.ballY, moving: rail.moving });
        }
    }
}
