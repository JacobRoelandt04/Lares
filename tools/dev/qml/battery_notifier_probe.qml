import QtQuick
import "modules/common/notify"
import "modules/notifications/sources"
import "modules/notifications/sources/SourceSettings.js" as Settings

// BatteryNotifier on a stub host and a fake battery: the low-charge levels run while the pack is Discharging OR its charge
// is STALLED (silicon's chargeStalled: the kernel says Charging, nothing reaches the pack -- 2026-11-04). Prints BATNOTE lines
// and one `BATNOTE RESULT PASS|FAIL`. Runner: tools/dev/battery_notifier_probe.sh.
Item {
    id: root
    width: 10
    height: 10

    property var posts: []
    property var withdrawn: []
    property var fails: []
    property int checks: 0

    function check(id, ok, detail) {
        root.checks++;
        console.log("BATNOTE " + id + ": " + (ok ? "ok" : "FAIL") + (detail ? "  " + detail : ""));
        if (!ok)
            root.fails.push(id);
    }

    // the service as the sources see it: a record per key, gone when withdrawn or when the USER takes it away (root.discard)
    property var recs: ({})
    property var updates: []
    Component.onCompleted: NotificationBus.service = ({
        post: spec => { root.posts.push(spec); const u = spec.source + "/" + spec.key; root.recs[u] = spec.progress; return u; },
        update: (uid, patch) => {
            if (root.recs[uid] === undefined)
                return false;
            root.recs[uid] = patch.progress;
            root.updates.push({ uid: uid, progress: patch.progress });
            return true;
        },
        withdraw: (source, key) => { delete root.recs[source + "/" + key]; root.withdrawn.push(source + "/" + key); },
        attend: () => {}
    })
    function discard(uid) { delete root.recs[uid]; }

    // the fake battery: the members BatteryNotifier reads, and its `reading` signal
    Item {
        id: bat
        property int percent: 50
        property string status: "Discharging"
        property bool chargeStalled: false
        property real estimatedTimeSec: -1
        property real powerNowW: 10
        property bool isDischarging: bat.status === "Discharging"
        property int targetPercent: 100
        property var silicon: null
        signal reading
        signal eventFullyCharged
        function set(pct, status, stalled) {
            bat.percent = pct;
            bat.status = status;
            bat.chargeStalled = stalled;
            bat.reading();
        }
    }

    QtObject {
        id: stubHost
        property bool live: true
        function allows(id) { return true; }
        function settingsOf(id) { return Settings.defaults()[id]; }
        function register(s) {}
        function unregister(s) {}
        function open(what) {}
        function run(argv) {}
        property var exec: ({ run: (argv, then) => {} })
        property var state: ({ get: k => ({}), put: (k, v) => {} })
    }

    BatteryNotifier {
        id: notifier
        host: stubHost
        battery: bat
    }
    DiskNotifier {
        id: disk
        host: stubHost
        pollMs: 3600000
    }
    // one filesystem with that many GB free of 100
    function df(freeGB) {
        const g = 1024 * 1024 * 1024;
        return [{ device: "/dev/x", target: "/", sizeBytes: 100 * g, size: 100 * g, total: 100 * g, usedBytes: (100 - freeGB) * g, used: (100 - freeGB) * g, availBytes: freeGB * g, avail: freeGB * g, free: freeGB * g }];
    }
    function diskPosts() { return root.posts.filter(p => p.source === "disk"); }

    function levelPosts() { return root.posts.filter(p => p.key === "level"); }

    property int stepAt: 0
    Timer {
        id: go
        interval: 300
        running: true
        onTriggered: root.run()
    }

    function run() {
        root.check("armed", notifier.active, "the notifier is active on the stub host");
        // control: Discharging at 2 % posts the critical card
        bat.set(20, "Discharging", false);
        root.check("quiet-above", levelPosts().length === 0, "20 % posts nothing");
        bat.set(2, "Discharging", false);
        root.check("discharging-posts", levelPosts().length === 1 && /critical/i.test(levelPosts()[0].title), JSON.stringify(levelPosts().map(p => p.title)));
        bat.set(50, "Charging", false);
        root.check("charging-withdraws", root.withdrawn.indexOf("battery/level") >= 0, JSON.stringify(root.withdrawn));
        // the fact: Charging, stalled, 2 % -> the same card
        root.posts = [];
        root.withdrawn = [];
        bat.set(2, "Charging", false);
        root.check("charging-2pct-says-nothing", levelPosts().length === 0, "a healthy charge at 2 % is no warning");
        bat.set(2, "Charging", true);
        root.check("stalled-posts", levelPosts().length === 1 && /critical/i.test(levelPosts()[0].title) && levelPosts()[0].urgency === "critical",
                   JSON.stringify(levelPosts().map(p => [p.title, p.urgency])));
        // the rail follows the percentage silently (an update of the same record)
        root.updates = [];
        bat.set(1, "Charging", true);
        root.check("stalled-follows", levelPosts().length === 1 && root.updates.length === 1 && root.updates[0].progress !== levelPosts()[0].progress, JSON.stringify(root.updates));
        // the flow returns: the card goes
        bat.set(1, "Charging", false);
        root.check("stall-ends-withdraws", root.withdrawn.indexOf("battery/level") >= 0, JSON.stringify(root.withdrawn));
        // A DISCARDED WARNING STAYS AWAY until the next level: one post at 8, one at 3, whatever the user does with each
        bat.set(40, "Charging", false);
        root.posts = [];
        root.updates = [];
        for (let p = 20; p >= 1; p--) {
            bat.set(p, "Discharging", false);
            root.discard("battery/level");
        }
        root.check("discarded-stays-away", levelPosts().length === 2, JSON.stringify(levelPosts().map(p => p.body)));
        // kept on screen, the rail follows every percent and nothing is posted between the levels
        bat.set(40, "Charging", false);
        root.posts = [];
        root.updates = [];
        for (let p = 20; p >= 1; p--)
            bat.set(p, "Discharging", false);
        root.check("kept-follows", levelPosts().length === 2 && root.updates.length === 6 && root.updates[5].progress === 1, levelPosts().length + " " + root.updates.length + " " + JSON.stringify(root.updates[root.updates.length - 1]));
        // the disk's card: the same rule
        root.posts = [];
        root.updates = [];
        disk._apply(root.df(4));
        const first = diskPosts().length;
        disk._apply(root.df(3));
        root.check("disk-follows", first === 1 && diskPosts().length === 1 && root.updates.length === 1, first + " " + diskPosts().length + " " + root.updates.length);
        root.discard(Object.keys(root.recs).filter(k => k.indexOf("disk/") === 0)[0] || "");
        disk._apply(root.df(2));
        disk._apply(root.df(1.5));
        root.check("disk-discarded-stays-away", diskPosts().length === 1, JSON.stringify(diskPosts().map(p => p.body)));
        console.log("BATNOTE RESULT " + (root.fails.length === 0 && root.checks > 0 ? "PASS" : "FAIL") + " (" + root.checks + " checks" + (root.fails.length ? "; failed: " + root.fails.join(", ") : "") + ")");
        quit.start();
    }
    Timer { id: quit; interval: 50; onTriggered: Qt.quit() }
}
