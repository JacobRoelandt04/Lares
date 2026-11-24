pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/system"
import "modules/notifications/data"
import "modules/notifications/data/NotifyPolicy.js" as Policy

// =============================================================================
// notif_live_probe.qml -- a LIVE post (NotificationService, "A LIVE POST"; the wiki's batch progress): a toast the user can hide
// into the manager and bring back, which its own updates never re-toast while hidden. Run by tools/dev/notif_live_probe.sh (the
// real service, a private bus, private XDG dirs). One line per check: `LIVE PASS|FAIL <name>`, then `LIVE RESULT PASS|FAIL`.
//
//   L1 a live post is a toast, in the group "live" (none of the manager's: neither listed nor counted)
//   L2 the manager opening leaves it on the lane (an ordinary toast posted beside it is filed)
//   L3 hide: off the lane, into the manager in its own group, seen
//   L4 updates of a hidden one change it in the manager and never toast it (three new texts)
//   L5 the user's other verbs cannot end it: remove and the clears leave it, file hides it
//   L6 unhide: out of the manager (group "live"), a toast again
//   L7 a timeout or a full stack that takes it off the lane hides it (never in neither place)
//   L9 THE SHELL'S QUESTION (fixed + breakDnd: "Keep these display settings?") is shown under DND, a share and fullscreen, waits for a lock,
//      and comes out when the lock becomes a share; a fixed record without breakDnd and an ordinary one are held as ever
// and the keys of notifications.jsonc that decide where, when and how a toast comes:
//   L10 a rule's breakDnd passes DND and no hold     L11 a rule's sound is heard over a post that asks for none, and nothing else is
//   L12 dnd.holdApps holds, dnd.summary              L13 screen: the named display, its fullscreen, the focused one while it is gone
//   L14 dnd.hours: the clock switches, a hand stands until the next start or end     L15 a word that is none is the default
//   L8 its source's last word without `live` (the batch's result) is an ordinary toast again, in the manager's group
// =============================================================================
ShellRoot {
    id: root

    property int fails: 0
    property int checks: 0
    function check(name, ok, detail) {
        root.checks++;
        if (!ok)
            root.fails++;
        console.log("LIVE " + (ok ? "PASS " : "FAIL ") + name + (ok ? "" : "  -- " + detail));
    }

    FocusedScreen {
        id: focusSrc
        live: false
    }
    NotificationService {
        id: svc
        serverEnabled: false
        registerOnBus: false
        persist: false
        liveSignals: false
        ipcEnabled: false
        configPath: ""
        focusSource: focusSrc
    }

    function rec(uid) { return svc.store.get(uid); }
    function onLane(uid) { return svc.toasts.shown.indexOf(uid) >= 0 || svc.toasts.held.indexOf(uid) >= 0; }
    function listed(uid) { const r = root.rec(uid); return !!r && ["critical", "system", "normal", "low"].indexOf(r.group) >= 0; }
    function post(body, extra) {
        return svc.post(Object.assign({ source: "wiki", key: "progress", title: "Wiki · Discover", body: body, urgency: "low",
                                        timeoutMs: -1, live: true, actions: [{ id: "default", label: "Open" }] }, extra || {}));
    }

    function run() {
        const u = root.post("1 / 30 — reading Alpha");
        root.check("L1 a live post is a toast in the group live, not listed", root.onLane(u) && root.rec(u).group === "live" && !root.listed(u)
                   && root.rec(u).live === true && root.rec(u).hidden === false, JSON.stringify(root.rec(u)));

        svc.managerOpen = true;
        const other = svc.post({ source: "probe", key: "other", title: "Other", body: "an ordinary one", timeoutMs: 8000 });
        const keptLive = root.onLane(u), otherFiled = !root.onLane(other) && root.listed(other);
        root.post("1 / 30 — judging Alpha");                 // its text changes while the manager is open: still a toast beside it
        const keptUpdated = root.onLane(u) && root.rec(u).hidden === false;
        svc.managerOpen = false;
        root.check("L2 the manager opening leaves the live toast on the lane, through an update (an ordinary one is filed)",
                   keptLive && keptUpdated && otherFiled, "live on lane " + keptLive + ", after an update " + keptUpdated + ", other filed " + otherFiled);

        const hid = svc.hide(u);
        root.check("L3 hide: off the lane, into the manager in its own group, seen", hid && !root.onLane(u) && root.listed(u)
                   && root.rec(u).hidden === true && root.rec(u).seen === true, JSON.stringify(root.rec(u)));

        root.post("2 / 30 — reading Beta");
        root.post("3 / 30 — writing intros Gamma");
        root.post("4 / 30 — judging Delta");
        root.check("L4 updates of a hidden one change it in the manager and never toast it", !root.onLane(u) && root.listed(u)
                   && root.rec(u).hidden === true && root.rec(u).bodyText.indexOf("Delta") >= 0, JSON.stringify(root.rec(u)));

        const removed = svc.remove(u);
        svc.clearAll();
        const stillThere = !!root.rec(u) && root.rec(u).hidden === true;
        root.check("L5 remove and the clears leave it (the user cannot end it)", !removed && stillThere, "removed " + removed + " there " + stillThere);

        const back = svc.unhide(u);
        root.check("L6 unhide: out of the manager (group live), a toast again", back && root.onLane(u) && root.rec(u).group === "live"
                   && root.rec(u).hidden === false && !root.listed(u), JSON.stringify(root.rec(u)));

        svc.file(u);
        const filedHides = !root.onLane(u) && root.rec(u).hidden === true && root.listed(u);
        const back7 = svc.unhide(u) && root.onLane(u);
        svc.toasts.expired(u);                   // what a timeout or a full stack says: the service's own handler takes it
        root.check("L7 file hides it, and a toast that ends by itself is hidden, never in neither place", filedHides && back7 && !root.onLane(u)
                   && root.rec(u).hidden === true && root.listed(u), "file hid " + filedHides + ", back " + back7 + "; " + JSON.stringify(root.rec(u)));

        svc.unhide(u);
        svc.hide(u);
        root.post("Added 30 (12 written ✦)", { live: false, timeoutMs: 10000 });
        root.check("L8 the last word without live is an ordinary toast, in the manager's group", root.onLane(u) && root.rec(u).live === false
                   && root.rec(u).hidden === false && root.listed(u), JSON.stringify(root.rec(u)));

        const ask = key => svc.post({ source: "probe", key: key, title: "Keep these display settings?", urgency: "normal", timeoutMs: -1, fixed: true,
                                      breakDnd: true, sound: "none", actions: [{ id: "keep", label: "Keep" }] });
        const shown = uid => svc.toasts.shown.indexOf(uid) >= 0;
        svc.dnd = true;
        svc.holds.screencast = true;
        const q1 = ask("q1");
        const plain = svc.post({ source: "probe", key: "p1", title: "Plain", timeoutMs: 8000, fixed: true });
        root.check("L9 a question is shown under DND and a screen share", shown(q1), JSON.stringify([svc.toasts.shown, svc.toasts.held, svc.holds.reason]));
        svc.dnd = false;
        const plain2 = svc.post({ source: "probe", key: "p2", title: "Plain 2", timeoutMs: 8000, fixed: true });
        const plain3 = svc.post({ source: "probe", key: "p3", title: "Plain 3", timeoutMs: 8000 });
        root.check("L9 a fixed record without breakDnd and an ordinary one stay held by the share", !shown(plain2) && !shown(plain3), JSON.stringify(svc.toasts.shown));
        svc.withdraw("probe", "q1");
        svc.holds.screencast = false;
        svc.holds.fullscreen = true;
        const q2 = ask("q2");
        root.check("L9 a question is shown over a fullscreen window", shown(q2), svc.holds.reason);
        svc.withdraw("probe", "q2");
        svc.holds.fullscreen = false;
        svc.holds.locked = true;
        const q3 = ask("q3");
        const waits = !shown(q3);
        svc.holds.screencast = true;
        svc.holds.locked = false;
        root.check("L9 a question waits for a lock, and comes out when the lock becomes a share", waits && shown(q3), JSON.stringify([waits, svc.toasts.shown, svc.toasts.held]));
        svc.holds.screencast = false;

        // ---- the config's keys
        const cfg = Array.from(svc.children).find(c => typeof c.parseText === "function");
        const conf = o => { cfg._config = Policy.merge(o); cfg._serial++; };
        const plainPost = key => svc.post({ source: "probe", key: key, title: key, timeoutMs: 8000 });
        conf({ sources: { probe: { breakDnd: true } }, toasts: { floodCount: 0 } });
        svc.dnd = true;
        const b1 = shown(plainPost("b1"));
        svc.dnd = false;
        svc.holds.screencast = true;
        const b2 = shown(plainPost("b2"));
        svc.holds.screencast = false;
        conf({ toasts: { floodCount: 0 } });
        svc.dnd = true;
        const b3 = shown(plainPost("b3"));
        svc.dnd = false;
        root.check("L10 a rule's breakDnd toasts under DND, and passes no share", b1 && !b2 && !b3, JSON.stringify([b1, b2, b3]));

        const cand = w => JSON.stringify(svc.sound.candidates({ urgency: "normal" }, w));
        const heard = rule => svc._decide({ uid: "x", origin: "shell", sourceId: "zz", urgency: "normal" }, rule, { sound: { spec: "none" } }, false).sound;
        root.check("L11 a rule's path is heard over a post that asks for none, alone; with no rule it stays silent, \"none\" silences",
                   cand({ spec: "none", rule: "/r.oga" }) === '["/r.oga"]' && cand({ spec: "none" }) === "[]" && cand({ rule: "none" }) === "[]"
                   && heard({ sound: "/r.oga" }) && !heard({}) && !heard({ sound: "none" }), cand({ spec: "none", rule: "/r.oga" }));

        conf({ toasts: { floodCount: 0 }, dnd: { holdApps: ["Game.Exe"] } });
        svc.holds.fakeActiveWindow = { cls: "game.exe", initialClass: "", title: "", pid: 1 };
        const g1 = !shown(plainPost("g1")) && svc.holdReason === "app";
        svc.holds.fakeActiveWindow = { cls: "kitty", initialClass: "", title: "", pid: 1 };
        const told = svc.toasts.shown.some(u => root.rec(u) && root.rec(u).sourceId === "notifications");
        svc.withdraw("notifications", "held");
        conf({ toasts: { floodCount: 0 }, dnd: { holdApps: ["game.exe"], summary: false } });
        svc.holds.fakeActiveWindow = { cls: "game.exe", initialClass: "", title: "", pid: 1 };
        plainPost("g2");
        svc.holds.fakeActiveWindow = null;
        const quiet = !svc.toasts.shown.some(u => root.rec(u) && root.rec(u).sourceId === "notifications");
        root.check("L12 a window of holdApps holds toasts, its end tells, summary off does not", g1 && told && quiet, JSON.stringify([g1, told, quiet]));

        conf({ toasts: { floodCount: 0 }, screen: "B" });
        focusSrc.setMonitors([{ name: "A" }, { name: "B" }]);
        focusSrc.setFocused("A");
        plainPost("s1");
        const s1 = svc.laneScreen === "B" && svc.managerScreen === "A";
        focusSrc.setFullscreen(true);
        const overA = svc.holdReason;
        focusSrc.setFocused("B");
        focusSrc.setFullscreen(true);
        const overB = svc.holdReason;
        focusSrc.setFullscreen(false);
        focusSrc.setFocused("A");
        focusSrc.setFullscreen(false);
        focusSrc.removeMonitor("B");
        const s2 = svc.laneScreen;
        focusSrc.addMonitor({ name: "B" });
        const s3 = svc.laneScreen;
        conf({ toasts: { floodCount: 0 } });
        focusSrc.setFocused("A");
        plainPost("s2");
        focusSrc.setFocused("B");
        root.check("L13 the toasts come on the named display, go to the focused one with it gone and come back; its fullscreen is the one that holds",
                   s1 && overA === "" && overB === "fullscreen" && s2 === "A" && s3 === "B" && svc.laneScreen === "A",
                   JSON.stringify([s1, overA, overB, s2, s3, svc.laneScreen]));

        const hm = ms => Qt.formatTime(new Date(ms), "HH:mm");
        const now = Date.now();
        const span = [hm(now - 3600000) + "-" + hm(now + 3600000)];
        conf({ dnd: { hours: span } });
        const h1 = svc.dnd;
        svc.dnd = false;
        svc._followHours();                      // the timer, a resume
        const h2 = svc.dnd;
        conf({ dnd: { hours: span, summary: false } });
        const h3 = svc.dnd;
        conf({});
        conf({ dnd: { hours: span } });
        const h4 = svc.dnd;
        conf({});
        root.check("L14 quiet hours switch DND on and off, a switch by hand stands until the next start or end", h1 && !h2 && !h3 && h4 && !svc.dnd,
                   JSON.stringify([h1, h2, h3, h4, svc.dnd]));

        const m = Policy.merge({ toasts: { swipe: { right: "x", left: "file" } }, manager: { openGroup: "x", swipe: { left: 3 } }, bell: { ring: "no" } });
        root.check("L15 a word that is none is the default", m.toasts.swipe.right === "file" && m.toasts.swipe.left === "file" && m.manager.openGroup === "latest"
                   && m.manager.swipe.left === "delete" && m.bell.ring === "always", JSON.stringify(m.manager));

        console.log("LIVE RESULT " + (root.fails === 0 ? "PASS" : "FAIL") + " (" + (root.checks - root.fails) + "/" + root.checks + " checks)");
        Qt.quit();
    }

    Timer {
        interval: 0
        running: true
        onTriggered: root.run()
    }
    Timer {
        interval: 60000
        running: true
        onTriggered: {
            console.log("LIVE RESULT FAIL (timeout)");
            Qt.quit();
        }
    }
}
