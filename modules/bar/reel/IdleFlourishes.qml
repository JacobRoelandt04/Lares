import QtQuick

import "../../common/flourish"
import "IdleFlourish.js" as F

// =============================================================================
// IdleFlourishes.qml -- the idle reel's flourishes: one clock per item (IdleFlourish.js has the curves). The power reel's set
// (ReelFlourishes) answers the same calls, so the reel and its views treat the two alike.
//
//   hover(id)   the pointer arrived on the bar's cell (an entry and a motion: IconReelView.pointerArrived), or moved onto another icon
//               of the open strip (IconReelView.pointerOnIcon): the item plays
//   arrive(id)  the user turned the ring and this item came into the bar's cell (a scroll, a swipe, a click on the strip): it plays
//               as it arrives. Nothing here runs anything: the mode is ReelActions' (fireIdle / idleSelected), the motion is only a show
//   demo(id)    the OLED care's random flourish (FlourishScheduler, through the item's FlourishClock): the same play. True when it started
//   poseOf(id, px, base, reach)   what the reel draws for the item now (IdleFlourish.js `pose`)
//
// THE OVERLAPS, as the power reel's: one clock per item, each ending at its own length; a hover, an arrival or a demo while the item
// plays does nothing (a restart is a visible jump); an item turned out of the cell mid-play plays out where the ring took it.
//
// The registry names its clocks "idleReel.<glyph>" (F.GLYPH: zzz, sunset, mug, infinity -- what the glyph IS, not the mode it picks).
// =============================================================================
QtObject {
    id: set

    // The registry's names (FlourishClock): ReelBarModule hands the item the reel is turned to and the module the clocks live under.
    property string group: "idleReel"
    property string selectedId: ""
    property Item host: null

    readonly property FlourishClock off: FlourishClock {
        itemId: "off"
        owner: set
        group: set.group
        glyph: F.GLYPH.off
        host: set.host
        shown: set.selectedId === "off"
    }
    readonly property FlourishClock soft: FlourishClock {
        itemId: "soft"
        owner: set
        group: set.group
        glyph: F.GLYPH.soft
        host: set.host
        shown: set.selectedId === "soft"
    }
    readonly property FlourishClock normal: FlourishClock {
        itemId: "normal"
        owner: set
        group: set.group
        glyph: F.GLYPH.normal
        host: set.host
        shown: set.selectedId === "normal"
    }
    readonly property FlourishClock hard: FlourishClock {
        itemId: "hard"
        owner: set
        group: set.group
        glyph: F.GLYPH.hard
        host: set.host
        shown: set.selectedId === "hard"
    }

    // The clock of an item, or null (an item with no flourish).
    function clockOf(id: string): var {
        switch (id) {
        case "off": return set.off;
        case "soft": return set.soft;
        case "normal": return set.normal;
        case "hard": return set.hard;
        }
        return null;
    }

    function hover(id: string): void {
        if (FlourishRegistry.hoverPlays)
            set._play(id, "hover");
    }
    function arrive(id: string): void {
        set._play(id, "arrive");
    }
    function demo(id: string): bool {
        return set._play(id, "random");
    }

    function _play(id: string, why: string): bool {
        const c = set.clockOf(id);
        // a play in progress goes on (THE OVERLAPS)
        if (!c || c.playing)
            return false;
        c.play(why, F.durationOf(id), 1);
        return true;
    }

    function poseOf(id: string, px: real, base: real, reach: real): var {
        const c = set.clockOf(id);
        if (!c || !c.playing)
            return F.rest(id, px, base);
        return F.pose(id, true, c.t, px, base);
    }
}
