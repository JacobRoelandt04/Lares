import QtQuick
import QtTest
import Quickshell

import "modules/common/scroll"
import "modules/common/components"
import "modules/common/theme"

// tools/dev/qml/side_swipe_probe.qml -- the shell's one wheel reader (WheelHub.read, WheelArea) and a mouse's side buttons as a two-finger swipe
// (SideSwipe), on real presses, motions and wheels through the window, with the shared readers under them: a tab selector, a back scrub over a list
// that scrolls, a view cycler, a stepper. The events a mouse and a touchpad send Qt 6.12 are the RECORDED ones (a Razer Viper V3 Pro on the desktop;
// a finger axis through a nested Hyprland, 2026-11-22), handed to WheelHub.read as QtTest cannot make a pixel delta. tools/dev/side_swipe_probe.sh.
// Prints "SSP ok|FAIL <name>" and "SSP RESULT PASS|FAIL (<n>/<n>)".
Window {
    id: win
    visible: true
    width: 600
    height: 500
    color: "#EAEDF5"

    property int fails: 0
    property int checks: 0
    function check(name: string, ok: bool, detail: var): void {
        win.checks++;
        if (!ok)
            win.fails++;
        console.log("SSP " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + JSON.stringify(detail) + "]"));
    }
    TestCase {
        id: tc
        name: "ssp"
        when: false
    }

    Item {
        id: body
        anchors.fill: parent

        // ---- a popup: a reader over all of it that takes sideways motions and passes the rest on
        Item {
            id: popup
            x: 100
            y: 60
            width: 400
            height: 300

            TabSelector {
                id: tabs
                width: 400
                height: 36
                tabs: [{ id: "a", label: "One" }, { id: "b", label: "Two" }, { id: "c", label: "Three" }, { id: "d", label: "Four" }]
                currentTab: "a"
                swipeSelfHandled: false
            }
            Item {
                id: page
                y: 40
                width: 400
                height: 260
                clip: true
                Flickable {
                    id: flick
                    anchors.fill: parent
                    contentHeight: 3000
                    interactive: false
                    Rectangle {
                        width: 400
                        height: 3000
                        color: "#E1E4EB"
                    }
                }
                ScrollDressing {
                    id: dress
                    flick: flick
                    ground: "#E1E4EB"
                }
                SwipeScrub {
                    id: scrub
                    anchors.fill: parent
                    z: 10
                    property var got: []
                    onScrub: p => scrub.got.push("scrub")
                    onCommit: scrub.got.push("commit")
                    onCancel: scrub.got.push("cancel")
                }
                // a reader that is cut off by the page's clip: nothing may reach it from below the page
                WheelArea {
                    id: cut
                    y: 250
                    width: 400
                    height: 200
                    z: 20
                    property int heard: 0
                    turned: ev => {
                        cut.heard++;
                        ev.accepted = false;
                    }
                }
            }
        }
        // ---- beside it: an observer under, a keeper over
        Item {
            id: pair
            x: 20
            y: 380
            width: 200
            height: 100
            WheelArea {
                id: under
                anchors.fill: parent
                property var got: []
                turned: ev => under.got.push(ev)
            }
            WheelArea {
                id: over
                anchors.fill: parent
                property var got: []
                property bool keep: false
                turned: ev => {
                    over.got.push(ev);
                    ev.accepted = over.keep;
                }
            }
        }
        // ---- a card of views with its dots
        Item {
            id: card
            x: 260
            y: 380
            width: 200
            height: 100
            CardViewCycler {
                id: cycler
                anchors.fill: parent
                orientation: "horizontal"
                views: [{ label: "A" }, { label: "B" }, { label: "C" }]
            }
        }
        WheelStepper {
            id: stepper
            notchThreshold: 120
            pixelThreshold: 1000
            stepCooldownMs: 200
        }
        SideSwipe {
            id: side
            property var asks: []
            onPointer: (what, dx, dy) => side.asks.push(what === "anchor" ? what + " " + dx + " " + dy : what)
        }
    }

    function raw(ax: real, ay: real, px: real, py: real, phase: int, buttons: int): var {
        return { x: 5, y: 5, angleDelta: Qt.point(ax, ay), pixelDelta: Qt.point(px, py), phase: phase, buttons: buttons, modifiers: 0, inverted: false };
    }
    function at(it: Item, x: real, y: real): point {
        return it.mapToItem(body, x, y);
    }
    // press, move in steps, (not) release
    function drag(p: point, dx: real, dy: real, button: int, keep: bool): void {
        tc.mousePress(win.contentItem, p.x, p.y, button);
        const n = Math.max(1, Math.round(Math.hypot(dx, dy) / 10));
        for (let i = 1; i <= n; i++)
            tc.mouseMove(win.contentItem, p.x + dx * i / n, p.y + dy * i / n, 0, button);
        if (!keep)
            tc.mouseRelease(win.contentItem, p.x + dx, p.y + dy, button);
    }
    function clear(): void {
        under.got = [];
        over.got = [];
        scrub.got = [];
        side.asks = [];
        cut.heard = 0;
    }

    // ---- the steps: { act, until?, then } -- a step that throws is a failed check
    property var seq: []
    property int idx: -1
    property double since: 0
    property bool busy: false
    function build(): var {
        const s = [];
        // ---- WHICH DEVICE
        s.push({ act: () => {
            const n = WheelHub.read(win.raw(0, -120, 0, -15, 0, 0), over);
            win.check("a mouse's notch (angle 120, 15 px, no phase) is a wheel, its pixels nothing", n.device === "wheel" && n.pixelDelta.y === 0 && n.angleDelta.y === -120 && n.steps === 1, n);
            const u = WheelHub.read(win.raw(0, 120, 0, 15, 0, 0), over);
            win.check("rolled up it is a step back", u.steps === -1 && u.notches.y === 1, u);
            const f = WheelHub.read(win.raw(-36, 240, -3, 20, 2, 0), over);
            win.check("fingers (phase update, angle 12 x the pixels) are fingers", f.device === "touch" && f.pixelDelta.y === 20 && f.steps === 0, f);
            const c = WheelHub.read(win.raw(0, 24, 0, 2, 0, 0), over);
            win.check("a continuous axis with no phase is fingers with no lift", c.device === "touch" && c.pixelDelta.y === 2, c);
            const a = WheelHub.read(win.raw(0, 120, 0, 10, 0, 0), over);
            win.check("ten px of it (angle 120) too", a.device === "touch" && a.pixelDelta.y === 10, a);
            const o = WheelHub.read(win.raw(0, -120, 0, 0, 0, 0), over);
            win.check("a notch with no pixels at all (an older Qt) is a wheel", o.device === "wheel" && o.steps === 1, o);
            const q = WheelHub.read(win.raw(0, -40, 0, 0, 0, 0), over);
            win.check("a probe's angle in pieces stays fingers", q.device === "touch", q);
        } });
        s.push({ act: () => {
            let total = 0;
            for (let i = 0; i < 7; i++)
                total += WheelHub.read(win.raw(0, -40, 0, -5, 0, 0), under).steps;
            win.check("a high-resolution wheel's pieces add up to whole notches (7 x 40: two)", total === 2, total);
            const back = WheelHub.read(win.raw(0, 40, 0, 5, 0, 0), under);
            win.check("and a reversal starts afresh", back.steps === 0, back);
            const t = WheelHub.read(win.raw(0, -120, 0, -15, 0, Qt.BackButton), over);
            win.check("a notch with a side button down is sideways, down = the next", t.angleDelta.x === -120 && t.angleDelta.y === 0 && t.steps === 1 && WheelHub.sideTurned, t);
            WheelHub.sideTurned = false;
            WheelHub.sideButtons = "forward";
            const r = WheelHub.read(win.raw(0, -120, 0, -15, 0, Qt.BackButton), over);
            win.check("a button that is not a swipe's turns nothing", r.angleDelta.y === -120, r);
            WheelHub.sideButtons = "both";
        } });
        // ---- THE CHAIN
        s.push({ act: () => {
            const p = win.at(pair, 50, 50);
            const c = WheelHub.chainAt(body, p.x, p.y);
            win.check("the chain under a point is topmost first", c.length === 2 && c[0] === over && c[1] === under, c.length);
            const q = win.at(page, 100, 100);
            const d = WheelHub.chainAt(body, q.x, q.y);
            win.check("a z is above a later sibling (the scrub over the dressing)", d.length === 2 && d[0] === scrub, d.length);
            const r = win.at(page, 100, 270);
            win.check("a clip cuts its readers off", WheelHub.chainAt(body, r.x, r.y).indexOf(cut) < 0, 0);
            const e = win.at(page, 100, 255);
            win.check("inside the clip it is there", WheelHub.chainAt(body, e.x, e.y)[0] === cut, 0);
        } });
        // ---- A DRAG
        s.push({ act: () => {
            win.clear();
            over.keep = false;
            win.drag(win.at(pair, 100, 50), -60, 4, Qt.BackButton, true);
            const g = under.got;
            win.check("a drag begins like fingers: a zero begin, then pixels with 12 x the angle", g.length >= 3 && g[0].phase === Qt.ScrollBegin && g[0].pixelDelta.x === 0
                && g[1].phase === Qt.ScrollUpdate && g[1].device === "swipe" && g[1].angleDelta.x === 12 * g[1].pixelDelta.x, g.length ? [g[0].phase, g[1]] : 0);
            win.check("the whole way is there, nothing of the slop lost", Math.abs(g.reduce((s, e) => s + e.pixelDelta.x, 0) + 60) <= 1, g.reduce((s, e) => s + e.pixelDelta.x, 0));
            win.check("every event stands where the press was", g.every(e => Math.abs(e.x - 100) < 1 && Math.abs(e.y - 50) < 1), g.map(e => e.x));
            win.check("the pointer is hidden only where a host holds it", !side.hiding && side.asks.length === 0 && WheelHub.swiping, side.asks);
            tc.mouseRelease(win.contentItem, 10, 10, Qt.BackButton);
            const l = under.got[under.got.length - 1];
            win.check("the release is the lift: a zero end", l.phase === Qt.ScrollEnd && l.pixelDelta.x === 0 && !WheelHub.swiping, l);
        } });
        s.push({ act: () => {
            win.clear();
            over.keep = true;
            win.drag(win.at(pair, 100, 50), 0, -40, Qt.ForwardButton, false);
            win.check("a reader that keeps an event keeps it from the one below", over.got.length > 3 && under.got.length === 0, [over.got.length, under.got.length]);
            win.check("an upward drag moves the content up (as natural scrolling)", over.got.reduce((s, e) => s + e.pixelDelta.y, 0) === -40, 0);
            over.keep = false;
        } });
        // ---- THE POINTER HELD
        s.push({ act: () => {
            win.clear();
            side.holds = true;
            pair.x = 200;
            pair.y = 200;
            const p = win.at(pair, 100, 50);
            win.drag(p, 150, 0, Qt.BackButton, true);
            win.check("held: asked to hold at the press, put back to it once it strayed", side.hiding && side.grabbing && side.asks[0] === "hold" && side.asks[1] === "anchor 0 0" && side.asks.length === 2, side.asks);
            const before = under.got.reduce((s, e) => s + e.pixelDelta.x, 0);
            // the jump home, seen 6 px past the start (the hand moved on meanwhile): those 6 px are the hand's
            tc.mouseMove(win.contentItem, p.x + 6, p.y, 0, Qt.BackButton);
            const after = under.got.reduce((s, e) => s + e.pixelDelta.x, 0);
            win.check("the jump home is no motion, what it is off its start is", after - before === 6, [before, after]);
            tc.mouseMove(win.contentItem, p.x + 26, p.y, 0, Qt.BackButton);
            win.check("and the hand goes on from there", under.got.reduce((s, e) => s + e.pixelDelta.x, 0) - after === 20, 0);
            side.asks = [];
            tc.mouseRelease(win.contentItem, p.x + 26, p.y, Qt.BackButton);
            win.check("let go, it is put back and shown", side.asks.length === 1 && side.asks[0] === "home" && !side.hiding, side.asks);
            win.check("the window keeps the input a moment longer", side.grabbing, side.grabbing);
            // a press near an edge: the hidden pointer is taken to the middle of the window, and that jump is no motion either
            pair.x = 20;
            pair.y = 380;
            win.clear();
            const q = win.at(pair, 100, 50);
            win.drag(q, 0, -10, Qt.BackButton, true);
            win.check("near an edge its anchor is the window's middle", side.asks.length === 2 && side.asks[1] === "anchor " + (300 - q.x) + " " + (250 - q.y), side.asks);
            const was = under.got.reduce((s, e) => s + e.pixelDelta.y, 0);
            tc.mouseMove(win.contentItem, 300, 250 - 8, 0, Qt.BackButton);
            win.check("the jump there counts what the hand did meanwhile (8 px up)", under.got.reduce((s, e) => s + e.pixelDelta.y, 0) - was === -8, 0);
            tc.mouseRelease(win.contentItem, 300, 242, Qt.BackButton);
            side.holds = false;
        } });
        // ---- A CLICK, A NOTCH
        s.push({ act: () => {
            win.clear();
            const p = win.at(pair, 100, 50);
            tc.mouseClick(win.contentItem, p.x, p.y, Qt.BackButton);
            win.check("a click of Back is one step back, marked a click", under.got.length === 1 && under.got[0].steps === -1 && under.got[0].click && under.got[0].device === "wheel", under.got);
            tc.mouseClick(win.contentItem, p.x, p.y, Qt.ForwardButton);
            win.check("a click of Forward one step on", under.got.length === 2 && under.got[1].steps === 1, under.got.length);
            WheelHub.sideClick = false;
            tc.mouseClick(win.contentItem, p.x, p.y, Qt.BackButton);
            win.check("sideClick off: nothing", under.got.length === 2, under.got.length);
            WheelHub.sideClick = true;
            win.clear();
            tc.mousePress(win.contentItem, p.x, p.y, Qt.BackButton);
            tc.mouseWheel(win.contentItem, p.x, p.y, 0, -120, Qt.BackButton);
            const heard = under.got.length;
            tc.mouseMove(win.contentItem, p.x + 40, p.y, 0, Qt.BackButton);
            tc.mouseRelease(win.contentItem, p.x + 40, p.y, Qt.BackButton);
            win.check("held + a notch: one step sideways, and the press is neither a click nor a drag", heard === 1 && under.got.length === 1 && under.got[0].steps === 1 && under.got[0].angleDelta.x === -120, under.got.map(e => [e.steps, e.device]));
            WheelHub.sideButtons = "off";
            win.clear();
            win.drag(p, -60, 0, Qt.BackButton, false);
            win.check("sideButtons off: the buttons are nobody's", under.got.length === 0, under.got.length);
            WheelHub.sideButtons = "both";
        } });
        // ---- THE SHARED READERS: the list
        s.push({ act: () => {
            win.clear();
            win.drag(win.at(page, 200, 200), 2, -90, Qt.BackButton, true);
            win.check("a drag up over a list moves it with the hand, 1:1", Math.abs(flick.contentY - 90) <= 2, flick.contentY);
            win.check("and scrubs nothing", scrub.got.length === 0, scrub.got);
            tc.mouseRelease(win.contentItem, 10, 10, Qt.BackButton);
        }, until: () => !dress.moving, then: () => { flick.contentY = 0; } });
        s.push({ act: () => {
            win.clear();
            dress.wheel(WheelHub.read(win.raw(0, -120, 0, -15, 0, 0), over));
            win.check("a mouse's notch GLIDES (it did not jump 15 px)", flick.contentY < 60, flick.contentY);
        }, until: () => !dress.moving, then: () => win.check("to a whole notch (120 px)", Math.abs(flick.contentY - 120) < 1, flick.contentY) });
        s.push({ act: () => {
            flick.contentY = 0;
            win.clear();
            const p = win.at(page, 200, 100);
            tc.mouseWheel(win.contentItem, p.x, p.y, 0, -120);
        }, until: () => !dress.moving && flick.contentY > 0, then: () => win.check("through the window too", Math.abs(flick.contentY - 120) < 1, flick.contentY) });
        // ---- the back scrub
        s.push({ act: () => {
            win.clear();
            const p = win.at(page, 200, 100);
            win.drag(p, 160, 2, Qt.BackButton, false);
            win.check("a drag to the right scrubs back and commits at the release", scrub.got[0] === "scrub" && scrub.got[scrub.got.length - 1] === "commit", scrub.got);
            win.clear();
            tc.mousePress(win.contentItem, p.x, p.y, Qt.BackButton);
            for (let i = 1; i <= 4; i++) {
                tc.mouseMove(win.contentItem, p.x + 5 * i, p.y, 0, Qt.BackButton);
                tc.wait(60);
            }
            tc.mouseRelease(win.contentItem, p.x + 20, p.y, Qt.BackButton);
            win.check("a short one springs back", scrub.got[scrub.got.length - 1] === "cancel", scrub.got);
            win.clear();
            tc.mouseClick(win.contentItem, p.x, p.y, Qt.BackButton);
            win.check("a click of Back commits it whole", scrub.got.length === 1 && scrub.got[0] === "commit", scrub.got);
            win.clear();
            tc.mouseClick(win.contentItem, p.x, p.y, Qt.ForwardButton);
            win.check("a click of Forward does not", scrub.got.length === 0, scrub.got);
        } });
        // ---- the tabs
        s.push({ act: () => {
            tabs.currentTab = "a";
            const p = win.at(tabs, 60, 18);
            tc.mouseWheel(win.contentItem, p.x, p.y, 0, -120);
            win.check("a notch over the tab row is one tab, at once", tabs.currentTab === "b", tabs.currentTab);
            tc.mouseWheel(win.contentItem, p.x, p.y, 0, -120);
            tc.mouseWheel(win.contentItem, p.x, p.y, 0, -120);
            win.check("three quick notches are three tabs (no cooldown, no threshold)", tabs.currentTab === "d", tabs.currentTab);
            tc.mouseWheel(win.contentItem, p.x, p.y, 0, -120);
            win.check("past the end it stays", tabs.currentTab === "d", tabs.currentTab);
            tc.mouseWheel(win.contentItem, p.x, p.y, 0, 120);
            win.check("rolled up: the previous", tabs.currentTab === "c", tabs.currentTab);
            tabs.applySteps(-2);
            win.check("a host's sideways notches: two back", tabs.currentTab === "a", tabs.currentTab);
        } });
        // ---- the dots, the stepper
        s.push({ act: () => {
            const p = win.at(card, 100, 95);
            tc.mouseWheel(win.contentItem, p.x, p.y, 0, -120);
            tc.mouseWheel(win.contentItem, p.x, p.y, 0, -120);
            win.check("a notch over the dots is one view, two are two", cycler.currentIndex === 2, cycler.currentIndex);
            const q = win.at(card, 100, 30);
            tc.mouseWheel(win.contentItem, q.x, q.y, 0, 120);
            win.check("elsewhere on the card it is nobody's", cycler.currentIndex === 2, cycler.currentIndex);
            let n = 0;
            for (let i = 0; i < 4; i++)
                n += stepper.feed(120, false);
            win.check("four quick notches are four steps", n === 4, n);
            n = 0;
            for (let i = 0; i < 4; i++)
                n += stepper.feed(1000, true);
            win.check("fingers still rest between steps", n === 1, n);
        } });
        return s;
    }

    function run(f: var, name: string): void {
        try {
            f();
        } catch (e) {
            win.check(name + " threw", false, String(e) + " " + e.stack);
        }
    }
    Timer {
        id: driver
        interval: 20
        repeat: true
        onTriggered: {
            if (win.busy)
                return;
            win.busy = true;
            if (win.idx < 0 || win.state === "next") {
                win.idx++;
                if (win.idx >= win.seq.length) {
                    driver.stop();
                    console.log("SSP RESULT " + (win.fails === 0 ? "PASS" : "FAIL") + " (" + (win.checks - win.fails) + "/" + win.checks + " checks)");
                    Qt.quit();
                    return;
                }
                win.state = "wait";
                win.since = Date.now();
                win.run(win.seq[win.idx].act, "step " + win.idx);
            } else {
                const s = win.seq[win.idx];
                const done = s.until ? s.until() : true;
                if (done || Date.now() - win.since > 4000) {
                    if (!done)
                        win.check("step " + win.idx + " settled", false, 0);
                    if (s.then)
                        win.run(s.then, "step " + win.idx + " then");
                    win.state = "next";
                }
            }
            win.busy = false;
        }
    }
    property string state: ""
    Timer {
        interval: 300
        running: true
        onTriggered: {
            win.seq = win.build();
            driver.start();
        }
    }
}
