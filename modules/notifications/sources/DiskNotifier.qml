pragma ComponentBehavior: Bound

import QtQuick

import "SourceGlyphs.js" as G
import "DiskSpace.js" as Disk

// =============================================================================
// DiskNotifier.qml -- the disk is running out of room (source "disk"; SOURCES.md, "Later sources").
//
// Every `pollMin` minutes `df -P -B1 -- <path>` for each path asked for (`mounts`: / and /home) is read. Paths on ONE
// filesystem are one fact (this machine's /home is a directory of /: one card that says "/ and /home"). Free
// space under `minFreeGB` (a mount of its own in `perMount`) is a Normal card, "Low disk space"; under `criticalGB` the
// card becomes Critical, "Disk almost full" -- the one thing here that cannot wait, because a full disk stops the system
// writing. ONE key per filesystem: the level changes the card in place, its rail is the used share and follows the disk
// silently (an update of the record: a card the user took away stays away until the next level); it goes when the free space is `recover` over the line it crossed (a disk hovering at the threshold does
// not post and withdraw). The first poll is at once, so a shell started on a nearly full disk says so.
// =============================================================================
SourceBase {
    id: src

    sourceId: "disk"
    appName: "Disk"
    glyph: G.disk
    keys: ["disk"]

    property int pollMs: Math.round(src.settings.pollMin * 60000)
    // device -> "low" | "critical"; device -> the card out for it ({ uid, pct: the rail's })
    property var _levels: ({})
    property var _cards: ({})

    Timer {
        interval: Math.max(50, src.pollMs)
        running: src.active
        repeat: true
        triggeredOnStart: true
        onTriggered: src._poll()
    }

    function _poll() {
        if (!src.active)
            return;
        // One df PER PATH, after `--` (a config value is never an option of df): df answers with the row of the mount a path
        // is ON, so `/home` that is no mount of its own comes back as `/`'s row (this machine's), and the row is the path's.
        // Only absolute paths.
        const paths = src.settings.mounts.filter(m => typeof m === "string" && m.charAt(0) === "/");
        if (paths.length === 0)
            return;
        const entries = [];
        let pending = paths.length;
        for (const path of paths) {
            src.host.exec.run(["df", "-P", "-B1", "--", path], (code, out) => {
                const rows = Disk.parseDf(out);
                if (rows.length > 0)
                    entries.push(Object.assign({}, rows[0], { target: path }));
                if (--pending === 0 && src.active)
                    src._apply(entries);
            });
        }
    }

    function _apply(entries) {
        // A reading with no row at all is a df that could not answer (no card is taken back for it)
        if (entries.length === 0)
            return;
        const cfg = src.settings;
        const seen = {};
        for (const g of Disk.groups(entries, cfg.mounts)) {
            seen[g.device] = true;
            const was = src._levels[g.device] || "ok";
            const now = Disk.judge(g, was, cfg);
            const key = Disk.key(g);
            if (now === "ok") {
                if (was !== "ok") {
                    delete src._levels[g.device];
                    delete src._cards[g.device];
                    src.withdraw(key);
                }
                continue;
            }
            const t = Disk.text(g, now);
            if (now !== was) {
                src._levels[g.device] = now;
                const uid = src.post(key, { title: t.title, body: t.body, urgency: now === "critical" ? "critical" : "normal", progress: t.usedPct });
                src._cards[g.device] = { uid: uid, pct: t.usedPct };
            } else if (src._cards[g.device] && src._cards[g.device].pct !== t.usedPct) {
                // the rail moves, in place (its words are those of the moment the level was reached -- a new number in them would be
                // a new toast); a card the user has taken away is not made again for it
                if (src.update(src._cards[g.device].uid, { progress: t.usedPct }))
                    src._cards[g.device].pct = t.usedPct;
                else
                    delete src._cards[g.device];
            }
        }
        // a filesystem that is not mounted any more has nothing to be low about
        for (const device in src._levels)
            if (!seen[device]) {
                delete src._levels[device];
                delete src._cards[device];
                src.withdraw(Disk.key({ device: device }));
            }
    }

    onActivated: {
        src._levels = ({});
        src._cards = ({});
    }
}
