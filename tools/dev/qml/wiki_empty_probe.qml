pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import QtTest
import Quickshell

import "modules/common/theme"
import "modules/wiki"

// =============================================================================
// tools/dev/qml/wiki_empty_probe.qml -- an empty wiki pool says what it waits for (6858abb6): the real WikiPopup on a stub
// service with no card, its facts written by hand. Runner: tools/dev/wiki_empty_probe.sh. Prints WE lines and
// "WE RESULT PASS|FAIL". A bare smoke (no PROBE=1) quits at once.
//
//   idle      nothing runs, nothing waits: just "No articles yet" (never "being filled")
//   running   a running batch: "... the pool is being filled"
//   pending   a batch waiting for the dGPU: "... waiting for the GPU"
//   offline   the network is down: "... the network is down"
//   blocked   the batch is blocked: "... the GPU is busy"
//   priority  a running batch outranks offline and blocked
//   loading   while the tab loads no empty words are shown
//   button    "Process articles" under the words when a batch could start now (idle; blocked is a retry), none while one runs, waits
//             for the GPU or the network is down, none while loading; centred with the words as one block; a real click starts a
//             batch of the tab on show
// WE_GRAB=<png>: the idle empty popup is also saved there (a look, not a check).
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
        console.log("WE " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }

    QtObject {
        id: svc
        property int serial: 0
        property bool offline: false
        property bool batchPending: false
        property bool isLoading: false
        property var batch: ({ running: false, blocked: false })
        property var started: []
        function startBatch(tab: string): void { svc.started = svc.started.concat([tab]); }
        function card(tab: string): var { return null; }
        function loading(tab: string): bool { return svc.isLoading; }
        function canBack(tab: string): bool { return false; }
        function trail(tab: string): var { return []; }
        function ensureSlots(): void {}
        function closeCard(tab: string): void {}
        function follow(tab: string, link: var): void {}
        function hoverDwell(tab: string, id: string, ms: real): void {}
        function openLink(tab: string, id: string, url: string): void {}
        function read(tab: string, id: string, ms: real): void {}
    }

    Window {
        id: win
        visible: root.live
        width: 520
        height: 520
        color: Theme.surface
        WikiPopup {
            id: popup
            x: 10
            y: 10
            service: svc
            width: implicitWidth
            height: implicitHeight
        }
        TestCase {
            id: tc
            when: false
        }
    }
    // the process button on show now, or null
    function button(): var {
        let hit = null;
        const walk = it => {
            if (hit)
                return;
            if (it.objectName === "wikiProcessButton" && it.visible) {
                hit = it;
                return;
            }
            for (let i = 0; i < it.children.length; i++)
                walk(it.children[i]);
        };
        walk(popup);
        return hit;
    }
    function shown(): bool {
        return root.button() !== null;
    }

    // the empty words on show now (a Text whose text starts "No articles yet", visible)
    function words(): string {
        const found = [];
        const walk = it => {
            if (it.text !== undefined && String(it.text).indexOf("No articles yet") === 0 && it.visible)
                found.push(String(it.text));
            for (let i = 0; i < it.children.length; i++)
                walk(it.children[i]);
        };
        walk(popup);
        const uniq = found.filter((w, i) => found.indexOf(w) === i);
        return uniq.length === 0 ? "" : uniq.join(" | ");
    }
    function set(running: bool, pending: bool, offline: bool, blocked: bool): void {
        svc.batch = { running: running, blocked: blocked };
        svc.batchPending = pending;
        svc.offline = offline;
        svc.serial++;
    }

    property int _i: -1
    readonly property var steps: [
        () => {
            root.set(false, false, false, false);
            return () => {
                const w = root.words();
                root.check("idle: just 'No articles yet'", w === "No articles yet", w);
                root.check("idle: never claims the pool is being filled", w.indexOf("filled") < 0, w);
                const b = root.button();
                root.check("button: idle, 'Process articles' is offered", !!b && b.text === "Process articles", b ? b.text : "none");
                if (b) {
                    // the words and the button are ONE block, centred in the intro's slot
                    let words = null;
                    const walk = it => {
                        if (!words && it.text !== undefined && String(it.text).indexOf("No articles yet") === 0 && it.visible)
                            words = it;
                        for (let i = 0; i < it.children.length && !words; i++)
                            walk(it.children[i]);
                    };
                    walk(popup);
                    const slot = b.parent, top = words.y, bottom = slot.height - (b.y + b.height);
                    root.check("button: under the words, the block centred (" + top + " above, " + bottom + " below)", b.y > words.y + words.height && Math.abs(top - bottom) <= 1, top + " / " + bottom);
                }
            };
        },
        () => {
            root.set(true, false, false, false);
            return () => {
                const w = root.words();
                root.check("running: 'the pool is being filled'", w === "No articles yet — the pool is being filled", w);
                root.check("button: running, none", !root.shown(), "shown");
            };
        },
        () => {
            root.set(false, true, false, false);
            return () => {
                const w = root.words();
                root.check("pending: 'waiting for the GPU'", w === "No articles yet — waiting for the GPU", w);
                root.check("button: waiting for the GPU, none", !root.shown(), "shown");
            };
        },
        () => {
            root.set(false, false, true, false);
            return () => {
                const w = root.words();
                root.check("offline: 'the network is down'", w === "No articles yet — the network is down", w);
                root.check("button: offline, none", !root.shown(), "shown");
            };
        },
        () => {
            root.set(false, false, false, true);
            return () => {
                const w = root.words();
                root.check("blocked: 'the GPU is busy'", w === "No articles yet — the GPU is busy", w);
                root.check("button: blocked, offered again (a retry)", root.shown(), "none");
            };
        },
        () => {
            root.set(true, false, true, true);
            return () => {
                const w = root.words();
                root.check("priority: a running batch outranks offline and blocked", w === "No articles yet — the pool is being filled", w);
            };
        },
        () => {
            root.set(false, false, false, false);
            svc.isLoading = true;
            svc.serial++;
            return () => {
                const w = root.words();
                root.check("loading: no empty words while the tab loads", w === "", w);
                root.check("button: loading, none", !root.shown(), "shown");
            };
        },
        () => {
            root.set(false, false, false, false);
            svc.isLoading = false;
            svc.serial++;
            return () => {
                const b = root.button();
                if (!b) {
                    root.check("button: a real click starts a batch of the tab on show", false, "no button");
                    return;
                }
                const p = b.mapToItem(win.contentItem, b.width / 2, b.height / 2);
                tc.mouseClick(win.contentItem, p.x, p.y);
                root.check("button: a real click starts a batch of the tab on show", svc.started.length === 1 && svc.started[0] === popup.tab, JSON.stringify(svc.started) + " tab " + popup.tab);
                if (Quickshell.env("WE_GRAB"))          // a picture of the idle empty popup on its ground, to look at (not judged)
                    win.contentItem.grabToImage(r => r.saveToFile(Quickshell.env("WE_GRAB")));
            };
        },
        () => () => {}                                   // the grab's frame lands before the quit
    ]
    property var _judge: null
    function next(): void {
        if (root._judge) {
            root._judge();
            root._judge = null;
        }
        root._i++;
        if (root._i >= root.steps.length) {
            console.log("WE RESULT " + (root.fails === 0 && root.checks > 0 ? "PASS" : "FAIL") + " (" + (root.checks - root.fails) + "/" + root.checks + " checks)");
            Qt.quit();
            return;
        }
        root._judge = root.steps[root._i]();
        stepTimer.restart();
    }
    Timer {
        id: stepTimer
        interval: 250
        onTriggered: root.next()
    }
    Timer {
        interval: 600
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
