pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "../../../common/system"

// =============================================================================
// LockKeysSource.qml -- Caps Lock and Num Lock, shown the moment the lock has CHANGED.
//
//   press() / release()        the lock-key shortcut went down / came up (the key itself still goes to the application)
//   signal request(var req)    one partial CONTRACT section 1 request
//
// Qt cannot say whether a lock is on; Hyprland can (`hyprctl -j devices`, about 5 ms, per keyboard), and LockKeys (common/system) reads it.
//
// THE CARD SHOWS THE KEY'S REAL STATE, NEVER A GUESS, AND SHOWS IT AT ONCE. A lock key turns the lock ON at its press and OFF at its RELEASE
// (xkb: a press of a lock that is already on only unlocks it when the key comes up), and the compositor's report can trail either by a few
// milliseconds. So both ends of the key start a BURST of reads (`asksMs`), and the first answer in which a keyboard's lock differs from
// what is known is the card -- tens of milliseconds after the change itself, not a settle time after the key (it waited 450 ms after the
// last press, every time). What a later answer of the burst changes is said too, so whatever was read early is put right on the same card.
// The FIRST reading is not the press's own when it equals what is known (the report still trails): nothing is announced from it, the next
// read is.
//
// THE LAST WORD. When the burst is over the state in hand is shown if nothing was (a toggle that cancelled itself, a key the compositor
// ate): whatever the key did, a press is answered. A reading outside a burst (the poll healing a stale value, a read at start-up) only moves
// what is known -- and a lock changed unseen in between (Shift+Caps, which the compositor's bind does not see) is put right by the next
// burst's own reads, on its one card.
//
// PER KEYBOARD: a board whose lock has stood on since it was last used (a receiver, a second keyboard) must not hold the answer of the one
// being typed on. The board that FLIPPED is the one the card tells of; the lock that did not flip is "on when any keyboard has it on".
//
// WHAT THE CARD SHOWS (`shown`, osd.jsonc lockkeys.keys): a lock that is not on the card changes nothing on screen -- a burst whose only flip
// is such a lock is answered by nothing, not by the last word (a keyboard with no number pad: a Num Lock press elsewhere shows no card).
//
// `live: false` runs no hyprctl: simulateKeys(caps, num) is the reading.
// =============================================================================
Item {
    id: root

    property bool live: true
    // When a key event asks for a reading, after it; and how long after the last one the burst's last word falls.
    property var asksMs: root.live ? [0, 25, 60, 110, 180, 300] : []
    property int lastWordMs: root.live ? 380 : 40

    signal request(var req)

    // The locks the card shows, in order: "caps", "num" (osd.jsonc lockkeys.keys)
    property var shown: ["caps", "num"]

    readonly property bool caps: root._caps
    readonly property bool num: root._num

    property bool _caps: false
    property bool _num: false
    property var _boards: ({})
    // A burst is under way; a card of it is out; the next ask.
    property bool _burst: false
    property bool _said: false
    property int _ask: 0
    property double _at: 0

    function press() {
        root._event();
    }
    function release() {
        root._event();
    }

    function _event() {
        if (!root._burst) {
            root._burst = true;
            root._said = false;
        }
        root._at = Date.now();
        root._ask = 0;
        lastWord.interval = root.lastWordMs;
        lastWord.restart();
        root._next();
    }
    // Ask for every reading that is due, and wait for the next one.
    function _next() {
        const lk = root._lk;
        const since = Date.now() - root._at;
        let due = false;
        while (root._ask < root.asksMs.length && root.asksMs[root._ask] <= since + 1) {
            due = true;
            root._ask++;
        }
        if (due && root.live && lk)
            lk.refresh();
        if (root._ask < root.asksMs.length) {
            ask.interval = Math.max(1, Math.round(root.asksMs[root._ask] - since));
            ask.restart();
        }
    }
    Timer {
        id: ask
        onTriggered: root._next()
    }
    Timer {
        id: lastWord
        onTriggered: {
            ask.stop();
            root._burst = false;
            if (!root._said)
                root._announce(root._caps, root._num, "");
        }
    }

    // One reading: the boards as they are now.
    function _observe(boards) {
        const was = root._boards;
        let caps = false, num = false, flippedCaps = null, flippedNum = null;
        for (const n in boards) {
            const b = boards[n];
            caps = caps || b.caps;
            num = num || b.num;
            // a board seen for the first time (plugged in since the last reading) came with caps off; num may come on (numlock_by_default)
            const o = was[n] !== undefined ? was[n] : { caps: false, num: b.num };
            if (o.caps !== b.caps)
                flippedCaps = b.caps;
            if (o.num !== b.num)
                flippedNum = b.num;
        }
        root._boards = boards;
        if (flippedCaps !== null)
            caps = flippedCaps;
        if (flippedNum !== null)
            num = flippedNum;
        root._caps = caps;
        root._num = num;
        const showsCaps = root.shown.indexOf("caps") >= 0, showsNum = root.shown.indexOf("num") >= 0;
        if (root._burst && ((flippedCaps !== null && showsCaps) || (flippedNum !== null && showsNum)))
            root._announce(caps, num, flippedCaps !== null && showsCaps ? "caps" : "num");
        else if (root._burst && (flippedCaps !== null || flippedNum !== null))
            // a lock the card does not show flipped: the press is answered, by nothing
            root._said = true;
    }

    function simulateKeys(caps, num) {
        if (root._boards.sim === undefined)
            root._boards = { sim: { caps: false, num: false } };
        root._observe({ sim: { caps: caps, num: num } });
    }

    function _announce(caps, num, changed) {
        root._said = true;
        root.request({
            kind: "lockkeys",
            key: "lockkeys",
            source: "key",
            keys: { caps: caps, num: num },
            changed: changed
        });
    }

    LazyLoader {
        id: loader
        active: root.live
        component: LockKeys {
            id: lk
            onAnswered: root._observe(lk.boards)
        }
    }
    readonly property var _lk: loader.item
}
