pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

// =============================================================================
// PowerBus.qml -- where modules ask for a CPU power profile to be HELD, and where silicon (the
// one that owns the profile) hears about it. A module that must not run slow while it works --
// the system update -- looks here; it never writes a profile itself and never reads silicon.
//
//   hold(source, profile, reason, kind)   `source` asks for `profile` ("quiet" | "balanced" |
//                                   "performance") for as long as it holds; one hold per source,
//                                   asking again replaces it. `kind` is "hold" (the default: the
//                                   machine IS at that profile while it holds) or "floor" (the
//                                   machine is at least as keen as that profile: a source that
//                                   only needs the CPU not to sleep -- a loaded language model --
//                                   raises a lower profile and leaves a higher one alone; it
//                                   never takes the machine DOWN)
//   release(source)                 the source is done; silicon puts back what it held
//   dropAll(why)                    a MANUAL change: every hold is dropped at once, nothing is
//                                   restored (the user's hand wins over a module's request)
//
//   holds         { source: { profile, reason, kind } }
//   heldProfile   the profile the holds ask for ("" = none); with several holds the most
//                 performant wins, a hold that arrived earlier on a tie
//   heldBy        the source whose hold wins
//   heldIsFloor   the winning hold is a floor: a "hold" always outranks a floor, whatever the
//                 profiles (a system update's Performance over a model's Balanced, and the
//                 floor takes over again when the update ends)
//   changed()     any of the above changed
//   dropped(sources)   a dropAll emitted this just before changed(): `sources` is who lost their
//                 hold, so a module that holds for as long as something runs can tell "I am
//                 done" from "the user took the profile back" and does not hold again
//
// SILICON is the consumer (modules/silicon/data/SiliconService.qml): it switches to the held
// profile when a hold arrives, shows who holds it, and on a plain release switches back to the
// profile it left. Without silicon nothing listens and a hold is a note nobody reads.
// =============================================================================
Singleton {
    id: root

    readonly property var holds: root._holds
    readonly property string heldProfile: root._winner.profile
    readonly property string heldBy: root._winner.source
    readonly property bool heldIsFloor: root._winner.floor === true

    signal changed
    signal dropped(var sources)

    property var _holds: ({})
    readonly property var _rank: ({ quiet: 0, balanced: 1, performance: 2 })
    readonly property var _winner: {
        let best = { source: "", profile: "", floor: false };
        const keys = Object.keys(root._holds);
        for (let i = 0; i < keys.length; i++) {
            const h = root._holds[keys[i]];
            const floor = h.kind === "floor";
            // a hold beats a floor; within a kind the more performant wins, the earlier on a tie
            const better = best.profile === "" || (best.floor && !floor)
                || (best.floor === floor && root._rank[h.profile] > root._rank[best.profile]);
            if (better)
                best = { source: keys[i], profile: h.profile, floor: floor };
        }
        return best;
    }

    function hold(source, profile, reason, kind) {
        if (typeof source !== "string" || source === "" || root._rank[profile] === undefined)
            return false;
        const k = kind === "floor" ? "floor" : "hold";
        const now = root._holds[source];
        const why = reason === undefined || reason === null ? "" : String(reason);
        if (now && now.profile === profile && now.reason === why && now.kind === k)
            return true;
        const next = Object.assign({}, root._holds);
        next[source] = { profile: profile, reason: why, kind: k };
        root._holds = next;
        root.changed();
        return true;
    }

    function release(source) {
        if (!root._holds[source])
            return false;
        const next = Object.assign({}, root._holds);
        delete next[source];
        root._holds = next;
        root.changed();
        return true;
    }

    // A manual change. Returns who lost their hold.
    function dropAll(why) {
        const sources = Object.keys(root._holds);
        if (sources.length === 0)
            return sources;
        root._holds = ({});
        root.dropped(sources);
        root.changed();
        return sources;
    }
}
