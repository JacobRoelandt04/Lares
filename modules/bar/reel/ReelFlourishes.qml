import QtQuick

import "../../common/flourish"
import "ReelFlourish.js" as F

// =============================================================================
// ReelFlourishes.qml -- the power reel's flourishes: one clock per item, and the padlock's state (ReelFlourish.js has the curves).
//
//   play(id)    the item fired: its flourish plays, and `played(id)` says when it has ended: the action that waits runs then
//               (ReelActions)
//   hover(id)   the pointer arrived on the bar's cell (an entry and a motion: IconReelView.pointerArrived), or moved onto another icon
//               of the open strip (IconReelView.pointerOnIcon): the same flourish, as a demo (the padlock shuts and opens again)
//   arrive(id)  the user turned the ring and this item came into the bar's cell (a scroll, a swipe, a click on the strip): the same
//               demo. A scroll only PLAYS: nothing here runs an action, and `played` of a demo finds no action waiting
//   demo(id)    the OLED care's random flourish (FlourishScheduler, through the item's FlourishClock in the registry): the same demo, and
//               ONLY the demo -- never `play`, the fire, which is the path an action waits on. Says whether it started
//   poseOf(id, px, base, reach)   what the reel draws for the item now (ReelFlourish.js `pose`): the Text's turn, scale and shade, and
//               the vector layers drawn instead of it or over it (ReelGlyphArt). The idle reel's set (IdleFlourishes) answers the same
//   locked      the session is locked: the padlock stays shut. Its rising edge plays the engage by itself (a lock nobody clicked
//               for: hypridle's before suspend, a key) unless one is already shutting it; its falling edge springs it open. An
//               engage the lock never follows (a lock that did not start) opens again after `lockGraceMs`.
//
// THE OVERLAPS, case by case. One clock per item (six in all), each ending at its own length: however fast the ring is turned,
// nothing piles up, and at rest nothing runs.
//   a hover or an arrival while the item plays   nothing: it goes on. A fresh hover, or the icon scrolled back into the cell
//                                                mid-flourish, never jumps it back to its start (a restart is a visible jump)
//   a fire while a demo plays                    the demo goes on and is the fire's: the action waits for its end (`played`);
//                                                the padlock's engage takes over from where the shackle stands (it must end shut)
//   the icon turned out of the cell mid-play     nothing: it plays out where the ring took it (the strip, or under the bar's
//                                                outer fog), its clock ends at its length, and it is at rest when it comes
//                                                back. Stopping it there would be a jump in the strip, where it is still seen
//   the padlock shut (locked, or the grace)      a demo plays nothing
//
// One per power reel (ShellFrame); every screen's reel hears the same fire (ReelActions.flourished), so they play together. A demo
// is the reel's own: the screen whose reel was hovered or turned.
// =============================================================================
QtObject {
    id: set

    property bool locked: false
    property int lockGraceMs: 3000
    // The registry's names (FlourishClock): the group the items are known by in the config ("power.sleep"), the item the reel is turned to
    // (only that one is on show), the module they live under (which screen). ReelBarModule hands the last two.
    property string group: "power"
    property string selectedId: ""
    property Item host: null

    // An item's flourish has played to its end (fired or hovered): the action that waits for it may run (ReelActions.flourishPlayed).
    signal played(string id)

    readonly property FlourishClock sleep: FlourishClock {
        itemId: "sleep"
        owner: set
        group: set.group
        host: set.host
        shown: set.selectedId === "sleep"
        onFinished: set.played("sleep")
    }
    readonly property FlourishClock poweroff: FlourishClock {
        itemId: "poweroff"
        owner: set
        group: set.group
        host: set.host
        shown: set.selectedId === "poweroff"
        onFinished: set.played("poweroff")
    }
    readonly property FlourishClock reboot: FlourishClock {
        itemId: "reboot"
        owner: set
        group: set.group
        host: set.host
        shown: set.selectedId === "reboot"
        onFinished: set.played("reboot")
    }
    readonly property FlourishClock hibernate: FlourishClock {
        itemId: "hibernate"
        owner: set
        group: set.group
        host: set.host
        shown: set.selectedId === "hibernate"
        onFinished: set.played("hibernate")
    }
    readonly property FlourishClock logout: FlourishClock {
        itemId: "logout"
        owner: set
        group: set.group
        host: set.host
        shown: set.selectedId === "logout"
        onFinished: set.played("logout")
    }
    readonly property FlourishClock lock: FlourishClock {
        itemId: "lock"
        owner: set
        group: set.group
        host: set.host
        shown: set.selectedId === "lock"
        onFinished: kind => set._lockEnded(kind)
    }

    // The clock of an item, or null (an item with no flourish).
    function clockOf(id: string): var {
        switch (id) {
        case "sleep": return set.sleep;
        case "poweroff": return set.poweroff;
        case "reboot": return set.reboot;
        case "hibernate": return set.hibernate;
        case "logout": return set.logout;
        case "lock": return set.lock;
        }
        return null;
    }

    // ---- the padlock's pose, for the art: the shackle (1 open .. 0 shut) and the knock (px down) --------------------------------
    // The shackle is shut at rest after an engage (while locked, or within the grace).
    property bool shut: false
    readonly property var lockPose: set.lock.playing ? F.lockPose(set.lock.kind, set.lock.t, set.lock.from)
        : ({ open: set.shut ? 0 : 1, knock: 0 })

    function play(id: string): void {
        if (id === "lock") {
            set._engage();
            return;
        }
        const c = set.clockOf(id);
        if (c && !c.playing)
            c.play("fire", F.durationOf(id), 1);
    }

    function hover(id: string): void {
        if (FlourishRegistry.hoverPlays)
            set._demo(id, "hover");
    }

    function arrive(id: string): void {
        set._demo(id, "arrive");
    }

    // The OLED care's random flourish: a demo, never the fire. True when one started.
    function demo(id: string): bool {
        const c = set.clockOf(id);
        if (!c || c.playing)
            return false;
        set._demo(id, "random");
        return c.playing;
    }

    // What the reel draws for `id` now: ReelFlourish.js `pose` (the padlock's from its own state, at rest too).
    function poseOf(id: string, px: real, base: real, reach: real): var {
        const c = set.clockOf(id);
        if (id === "lock")
            return F.pose(id, c.playing, c.t, set.lockPose, px, base, reach);
        if (!c || !c.playing)
            return F.REST;
        return F.pose(id, true, c.t, null, px, base, reach);
    }

    // A demo: the flourish with nothing behind it. `why` names it on the clock ("hover" / "arrive" / "random"; the padlock's is its "cycle").
    function _demo(id: string, why: string): void {
        const c = set.clockOf(id);
        // a play in progress goes on (THE OVERLAPS)
        if (!c || c.playing)
            return;
        if (id === "lock") {
            if (set.shut || set.locked)
                return;
            c.play("cycle", F.lockMs("cycle"), 1);
            return;
        }
        c.play(why, F.durationOf(id), 1);
    }

    function _engage(): void {
        if (set.lock.playing && set.lock.kind === "engage")
            return;
        if (set.shut && !set.lock.playing)
            return;
        const from = set.lockPose.open;
        set.lock.play("engage", F.lockMs("engage"), from);
    }

    function _release(): void {
        const from = set.lockPose.open;
        set.shut = false;
        set.lock.play("release", F.lockMs("release"), from);
    }

    function _lockEnded(kind: string): void {
        if (kind === "engage") {
            set.shut = true;
            if (!set.locked)
                set._grace.restart();
        }
    }

    onLockedChanged: {
        if (set.locked) {
            set._grace.stop();
            set._engage();
        } else if (set.shut || (set.lock.playing && set.lock.kind === "engage")) {
            set._release();
        }
    }

    property Timer _grace: Timer {
        interval: set.lockGraceMs
        onTriggered: {
            if (!set.locked && set.shut)
                set._release();
        }
    }
}
