pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "FlourishConfig.js" as Cfg

// =============================================================================
// FlourishRegistry.qml -- every glyph flourish of the shell that lives now, in one list: what the OLED care asks of them.
//
// A flourish REGISTERS ITSELF when it is made and goes when it is destroyed: GlyphFlourish (every bar glyph's clock: the bell, the
// archive, the disc, silicon's glyph) and FlourishClock (each reel item's clock) do it in their own Component.onCompleted /
// onDestruction, so a new one is in the list without anyone listing it. What an entry offers (both types have it):
//
//   group, glyph   its name: the module ("power", "idleReel", "update", "bell", "player", "silicon") and, in a reel, the item
//                  ("power.sleep", "idleReel.mug"); "" for a flourish that names no group (a harness's, a mockup's)
//   decorative     its motion means nothing (the reels, the archive): it is in the random pool unless the config says otherwise.
//                  One that MEANS something (the bell's new notification) is false and plays at random only when switched on
//   host           an Item it lives under (its button, its reel module): which screen it is on (`under`)
//   shown          it is on show now: a reel's item is in the bar's cell only while the reel is turned to it
//   playing        a play is in progress
//   demo()         plays it as a DEMO -- the motion with nothing behind it, as a hover would -- and says whether it started. NEVER a
//                  reel's fire: a power reel's fire is the path that powers the machine off (ReelFlourishes.demo)
//
// AN ENTRY IS REMOVED BY WHO IT IS, NEVER BY ITS NAME: every screen has a bell named "bell", and a delegate replaced in one update
// (a screen's frame rebuilt for a GPU switch or a re-plug) completes BEFORE the old one is destroyed -- a removal by name would drop the
// live entry (CLAUDE.md: AN OBJECT REGISTERED BY A NAME MUST NOT UNREGISTER THE NAME WHEN IT DIES).
//
// THE SHUFFLE BAG (`draw`) is the shell's one: every screen's scheduler draws from it, so the glyphs take turns across screens too.
// =============================================================================
Singleton {
    id: reg

    // shell.jsonc `flourishes`: whether a hover plays them, and whether the key that opens a module's popup does (a demo of the OLED care's
    // is neither).
    property bool hoverPlays: true
    property bool keyPlays: true

    // every live entry, in the order they came
    property var entries: []
    readonly property int count: reg.entries.length

    function add(e: var): void {
        if (!e || reg.entries.indexOf(e) >= 0)
            return;
        reg.entries = reg.entries.concat([e]);
    }
    function remove(e: var): void {
        const i = reg.entries.indexOf(e);
        if (i < 0)
            return;
        const a = reg.entries.slice();
        a.splice(i, 1);
        reg.entries = a;
    }

    function keyOf(e: var): string {
        return e ? Cfg.keyOf(e.group, e.glyph) : "";
    }

    // Does `e` live under `scope` (an Item: a screen's frame): its host, or an ancestor of it, is the scope.
    function under(e: var, scope: Item): bool {
        if (!e || !scope)
            return false;
        let it = e.host;
        for (let n = 0; it && n < 200; n++) {
            if (it === scope)
                return true;
            it = it.parent;
        }
        return false;
    }

    function entriesUnder(scope: Item): var {
        return reg.entries.filter(e => reg.under(e, scope));
    }

    // Is any flourish under `scope` playing (a binding may read it: it reads the list and every entry's `playing`).
    function playingUnder(scope: Item): bool {
        const list = reg.entries;
        let any = false;
        for (let i = 0; i < list.length; i++)
            if (list[i].playing && reg.under(list[i], scope))
                any = true;
        return any;
    }

    // ---- the shuffle bag ----------------------------------------------------------------------------------------------------
    // `pool`: the keys that may play on the drawer's screen (enabled and on show); `playable`: those that can play this instant.
    // Returns the key to play, "" for none. The bag holds a shuffled round of the pool; a key leaves it when it is drawn, the bag is
    // refilled when it is empty, when the pool is another set, or when nothing left in it can play here; a new round never starts
    // with the key drawn last.
    property var bag: []
    property string last: ""
    property string _sig: ""
    function draw(pool: var, playable: var): string {
        const sig = Cfg.signature(pool);
        if (sig !== reg._sig || reg.bag.length === 0)
            reg._refill(pool, sig);
        let i = reg.bag.findIndex(k => playable.indexOf(k) >= 0);
        if (i < 0) {
            reg._refill(pool, sig);
            i = reg.bag.findIndex(k => playable.indexOf(k) >= 0);
        }
        if (i < 0)
            return "";
        const k = reg.bag[i];
        const b = reg.bag.slice();
        b.splice(i, 1);
        reg.bag = b;
        reg.last = k;
        return k;
    }
    function _refill(pool: var, sig: string): void {
        reg.bag = Cfg.shuffle(pool, reg.last, Math.random);
        reg._sig = sig;
    }
}
