pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import "modules/osd"
import "modules/osd/kinds"
import "modules/osd/data/sources"
import "modules/osd/data/OsdKinds.js" as Kinds

// tools/dev/qml/osd_lockkeys_card_probe.qml -- osd.jsonc lockkeys.keys: the lock keys card draws only the keys it names, in that order,
// and is sized by them; the source announces nothing for a lock the card does not show; the config keeps "caps" / "num" once each.
// tools/dev/osd_lockkeys_card_probe.sh runs it offscreen ("OLKC" lines, "OLKC RESULT PASS|FAIL").
Window {
    id: win
    visible: true
    width: 420
    height: 260

    property int fails: 0
    property int checks: 0
    function check(name: string, ok: bool, detail: string): void {
        win.checks++;
        if (!ok)
            win.fails++;
        console.log("OLKC " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }

    OsdStyle {
        id: st
    }
    OsdLockKeys {
        id: card
        style: st
        orientation: "h"
        payload: ({ keys: { caps: true, num: false } })
        width: st.lockExtent(card.orientation).w
        height: st.lockExtent(card.orientation).h
    }
    function keyOf(name: string): var {
        for (let i = 0; i < card.children.length; i++)
            if (card.children[i].objectName === "key-" + name)
                return card.children[i];
        return null;
    }

    property var cards: []
    LockKeysSource {
        id: src
        live: false
        onRequest: req => win.cards = win.cards.concat([req.changed])
    }

    property int at: 0
    readonly property var seq: [
        () => {
            const caps = win.keyOf("caps"), num = win.keyOf("num");
            const capsW = st.keyWidth(st.keyCapsU, st.keyU), numW = st.keyWidth(st.keyNumU, st.keyU);
            win.check("both keys by default: the card is both keys wide, Num beside Caps",
                      st.lockExtent("h").w === 2 * st.pad + capsW + st.keyGap + numW && caps.visible && num.visible && num.x === caps.x + capsW + st.keyGap,
                      st.lockExtent("h").w + " caps " + caps.x + " num " + num.x);
            st.lockKeys = ["caps"];
        },
        () => {
            const caps = win.keyOf("caps"), num = win.keyOf("num");
            const capsW = st.keyWidth(st.keyCapsU, st.keyU);
            win.check("lockkeys.keys [\"caps\"]: no Num key, and the card is Caps wide", !num.visible && caps.visible && st.lockExtent("h").w === 2 * st.pad + capsW
                      && card.width === 2 * st.pad + capsW && caps.x === st.pad, "num " + num.visible + " w " + card.width + " caps x " + caps.x);
            win.check("... stacked, one key tall", st.lockExtent("v").h === 2 * st.pad + st.keyU, String(st.lockExtent("v").h));
            st.lockKeys = ["num", "caps"];
        },
        () => {
            const caps = win.keyOf("caps"), num = win.keyOf("num");
            win.check("lockkeys.keys [\"num\", \"caps\"]: in that order", caps.visible && num.visible && num.x < caps.x, "num " + num.x + " caps " + caps.x);
            st.lockKeys = ["caps", "num"];
            // the source: both shown, a Num flip is a card
            win.cards = [];
            src.press();
            src.simulateKeys(false, true);
        },
        () => {
            win.check("both shown: a Num Lock change is a card", win.cards.length === 1 && win.cards[0] === "num", JSON.stringify(win.cards));
            src.shown = ["caps"];
            win.cards = [];
            src.press();
            src.simulateKeys(false, false);
        },
        () => {
            win.check("lockkeys.keys [\"caps\"]: a Num Lock change shows no card, not even the press's last word", win.cards.length === 0, JSON.stringify(win.cards));
            src.press();
            src.simulateKeys(true, false);
        },
        () => {
            win.check("... and a Caps Lock change still is one", win.cards.length === 1 && win.cards[0] === "caps", JSON.stringify(win.cards));
            const k = o => JSON.stringify(Kinds.mergeConfig(o).lockkeys.keys);
            win.check("the config: caps / num once each, in order; nothing usable is the pair",
                      k({}) === '["caps","num"]' && k({ lockkeys: { keys: ["num", "num", "scroll"] } }) === '["num"]'
                      && k({ lockkeys: { keys: [] } }) === '["caps","num"]' && k({ lockkeys: { keys: "caps" } }) === '["caps","num"]',
                      k({ lockkeys: { keys: ["num", "num", "scroll"] } }));
        }
    ]
    // each step a frame apart, and after the source's last word (40 ms when not live)
    Timer {
        interval: 120
        repeat: true
        running: true
        onTriggered: {
            if (win.at < win.seq.length) {
                win.seq[win.at]();
                win.at++;
                return;
            }
            stop();
            console.log("OLKC RESULT " + (win.fails === 0 && win.checks > 0 ? "PASS" : "FAIL") + " (" + (win.checks - win.fails) + "/" + win.checks + " checks)");
            Qt.quit();
        }
    }
}
