pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../../common/power"
import "FanGuardMath.js" as Fgm

// =============================================================================
// FanGuard.qml -- is the CPU hot because it is working, or because the fans are not turning?
//
// WHY. 2026-11-13: after a 4.9 h s2idle the laptop ran at Quiet, the fans never spun and the CPU reached 92 degrees at a light load; a
// hot reboot spun them at once (the firmware's own fan logic had been left in a state a profile write re-programs). Nothing in the
// machine reads a fan speed (hwmon `asus` has no fan input; the ACPI "Fan" cooling devices read 0 whatever the fan does), so the one
// thing that can be seen is the temperature -- and a temperature alone is no verdict: 90 degrees under a build is normal, 90 at a light
// load is not. So the guard compares the temperature with what THIS machine, in THIS profile, normally reads at the load it has
// now, from a baseline it learns (FanGuardMath.js; `thermal-baseline.json` beside state.json).
//
// WHAT IT SEES. Every `sample()` (the service's beat, ~5 s) reads the package temperature and the LOAD INDEX (SysfsPoller.guardSample: the
// cores' busy share times their clocks, as a share of full speed -- no package power: RAPL's energy_uj is root only and no helper op
// delivers it). It judges against the load of the last minute's PEAK, not the instant: a build that just ended leaves the package hot
// while the fans spin down, and that is "working". It cannot see a fan: a stuck fan under a load heavy enough that the package reaches
// its limit at working fans too (index above what it has learned) looks the same as work.
//
// THE LADDER (every time is a property; the probe shortens them):
//   idle      learning: a sample taken while the load has stood in one bucket (+-1) for `learnStableMs`, outside a grace, below suspicion
//             (a suspect sample never enters the baseline, or a dying fan would teach the guard that hot is normal) goes into the baseline
//   suspect   T >= hotC and T >= expected + marginC (no baseline for this load yet: only T >= extremeC at a load index of at most
//             extremeLoadMax) for `confirmMs` without a break
//   kicked    STAGE 1, silent: `kickRequested` -- the host writes the platform profile again (another one, then this one back), which
//             re-programs the firmware's fan logic. After `recheckMs` it is judged: a sample below the line meanwhile, or a package that is
//             falling (fallC below where it stood), means it worked, and nothing is said; else
//   held      STAGE 2: `alarm` (a critical notice: the fans look stuck, with the temperature, the load and what this load normally reads) and a
//             Performance hold on PowerBus (the firmware's strongest fan curve) until the package is under releaseC twice in a row, then the hold
//             is released and the user's profile comes back through HoldFollower. A manual profile change drops the hold (PowerBus.dropped);
//             the guard then keeps quiet for `dropCooldownMs`.
//   NEVER fires inside `graceMs` of a re-kick (a resume's, the guard's own, the end of a hold) -- the package is still settling -- nor from one
//   spike (confirmMs), nor from a sample whose load figure spans a gap longer than `maxGapMs` (a suspend: the busy share is an average over
//   the sleep).
//
// RESUME. `resumed()` (the service's Sleep hook): re-kick once after `resumeKickMs` (the first status and the firmware's own re-adds have landed, and the
// reapply of what the firmware reset has run, so the kick never races a restore) and hold the guard's suspicion off for `graceMs` after it.
// =============================================================================
Item {
    id: root

    property var reader: null                  // SysfsPoller: guardSample(), acpiFans()
    property string profile: ""                // the platform profile the machine is in ("quiet" | "balanced" | "performance")
    property bool ready: false                 // the host can sample and kick (the helper answered)
    property bool persist: true
    property string statePath: ""              // thermal-baseline.json ("" = in memory only)
    property string holdSource: "fan-guard"

    // ---- the numbers (see the header) ---------------------------------------------------------------------------------
    property real hotC: 85
    property real marginC: 15
    property real extremeC: 95
    property real extremeLoadMax: 30           // load index (percent of full speed) a light load is, for the no-baseline case
    property real releaseC: 75
    property real fallC: 4
    property int bucketWidth: 5
    property int minSamples: 60                // steady samples a bucket needs before it is believed (~5 minutes at one every 5 s)
    property int confirmMs: 20000
    property int recheckMs: 60000
    property int graceMs: 180000
    property int resumeKickMs: 8000
    property int learnStableMs: 45000
    property int peakMs: 60000                 // the window whose load peak the temperature is judged against
    property int maxGapMs: 20000               // longer between two samples: a sleep or a stall, the load figure is not trusted
    property int dropCooldownMs: 900000
    property int saveMs: 600000

    // what the host does
    signal kickRequested(string why)           // write the platform profile again (host: SiliconService._kickProfile)
    signal alarm(var info)                     // post the notice: { tempC, loadPct, expectedC, hasBaseline, profile, releaseC }

    readonly property string stage: root._state          // "idle" | "suspect" | "kicked" | "held" (Item.state is final: `stage`)
    readonly property real tempC: root._tempC
    readonly property var thermalBase: root._base     // (not `baseline`: that is Item's own, final)
    readonly property int kicks: root._kicks
    readonly property int alarms: root._alarms
    readonly property int learned: root._learned
    // the last verdict's figures, for the probe and a log line
    readonly property var last: root._lastJudge

    function sample() {
        if (!root.ready || root.reader === null || root.profile === "")
            return;
        const s = root.reader.guardSample();
        if (s === null)
            return;
        const t = Date.now();
        const gap = root._lastAt === 0 ? 0 : t - root._lastAt;
        root._lastAt = t;
        root._tempC = s.tempC;
        if (s.index === null || gap > root.maxGapMs) {
            // the first sample, or one over a sleep or a stall: the busy share is an average over the gap, no load to judge by
            root._ring = [];
            root._suspectSince = 0;
            if (root._state === "suspect")
                root._state = "idle";
            if (root._state === "held")
                root._watchRelease(s.tempC);
            return;
        }
        if (root._state === "held") {
            root._watchRelease(s.tempC);
            return;
        }
        root._ring.push({ t: t, idx: s.index });
        while (root._ring.length > 0 && t - root._ring[0].t > root.peakMs)
            root._ring.shift();
        let peak = 0;
        for (let i = 0; i < root._ring.length; i++)
            peak = Math.max(peak, root._ring[i].idx);
        const ex = Fgm.expected(root._base, root.profile, Fgm.bucketOf(peak, root.bucketWidth), root.minSamples);
        const exC = ex === null ? null : ex.tempC;
        const hot = s.tempC >= root.hotC;
        const suspicious = hot && (exC === null ? (s.tempC >= root.extremeC && peak <= root.extremeLoadMax) : s.tempC >= exC + root.marginC);
        root._lastJudge = { tempC: s.tempC, index: s.index, peak: peak, expectedC: exC, suspicious: suspicious, state: root._state };

        if (root._state === "kicked") {
            if (!suspicious)
                root._curedSeen = true;
            if (t - root._kickedAt >= root.recheckMs)
                root._recheck(t, s.tempC, suspicious, s.index, exC);
            return;
        }
        if (t < root._graceUntil) {
            root._suspectSince = 0;
            root._state = "idle";
            return;
        }
        if (suspicious) {
            if (root._suspectSince === 0) {
                root._suspectSince = t;
                root._state = "suspect";
            } else if (t - root._suspectSince >= root.confirmMs) {
                root._kick(t, s.tempC, "the CPU is at " + s.tempC + " degrees at load index " + s.index + " (peak " + peak + "), this profile's usual for that is " + (exC === null ? "unknown" : exC));
            }
            return;
        }
        root._suspectSince = 0;
        root._state = "idle";
        // a hot sample with nothing to compare against, at a load too light to explain the heat, is never taught (a guard that met its
        // first fault before it had a baseline would learn the fault)
        if (!(hot && exC === null && peak <= root.extremeLoadMax))
            root._learnFrom(t, s.index, s.tempC);
    }

    // The machine came back from a sleep: stay quiet for a while, and (`kick`) re-kick once, soon.
    function resumed(kick) {
        root._lastAt = 0;
        root._ring = [];
        root._suspectSince = 0;
        if (root._state === "suspect")
            root._state = "idle";
        root._graceUntil = Date.now() + root.resumeKickMs + root.graceMs;
        if (kick)
            resumeKick.restart();
    }

    // ---- Private ------------------------------------------------------------------------------------------------------------
    property string _state: "idle"
    property real _tempC: 0
    property var _base: ({})
    property var _ring: []
    property double _lastAt: 0
    property double _suspectSince: 0
    property double _graceUntil: 0
    property double _kickedAt: 0
    property real _kickTemp: 0
    property bool _curedSeen: false
    property int _belowCount: 0
    property int _kicks: 0
    property int _alarms: 0
    property int _learned: 0
    property bool _dirty: false
    property var _lastJudge: null

    function _learnFrom(t, idx, tempC) {
        // only a steady load teaches: the whole ring (>= learnStableMs of it) stood within one bucket of this one
        if (root._ring.length < 2 || t - root._ring[0].t < root.learnStableMs || tempC >= 105)
            return;
        const b = Fgm.bucketOf(idx, root.bucketWidth);
        for (let i = 0; i < root._ring.length; i++) {
            if (Math.abs(Fgm.bucketOf(root._ring[i].idx, root.bucketWidth) - b) > 1)
                return;
        }
        root._base = Fgm.learn(root._base, root.profile, b, tempC);
        root._learned++;
        root._dirty = true;
        if (!saveTimer.running)
            saveTimer.restart();
    }

    function _kick(t, tempC, why) {
        root._state = "kicked";
        root._kickedAt = t;
        root._kickTemp = tempC;
        root._curedSeen = false;
        root._suspectSince = 0;
        root._kicks++;
        console.info("FanGuard: " + why + "; re-kicking the platform profile (ACPI fans: " + (root.reader ? root.reader.acpiFans() : "") + ")");
        root.kickRequested("fan-guard");
    }

    function _recheck(t, tempC, suspicious, idx, exC) {
        root._graceUntil = t + root.graceMs;
        if (root._curedSeen || !suspicious || tempC <= root._kickTemp - root.fallC) {
            console.info("FanGuard: the re-kick worked (" + tempC + " degrees now, " + root._kickTemp + " when it was asked)");
            root._state = "idle";
            return;
        }
        root._state = "held";
        root._belowCount = 0;
        root._alarms++;
        console.info("FanGuard: still " + tempC + " degrees a minute after the re-kick: the fans look stuck; holding Performance (ACPI fans: " + (root.reader ? root.reader.acpiFans() : "") + ")");
        PowerBus.hold(root.holdSource, "performance", "The fans look stuck: the CPU is hot at a load that does not explain it", "hold");
        root.alarm({ tempC: tempC, loadPct: idx, expectedC: exC, hasBaseline: exC !== null, profile: root.profile, releaseC: root.releaseC });
    }

    function _watchRelease(tempC) {
        if (tempC < root.releaseC)
            root._belowCount++;
        else
            root._belowCount = 0;
        if (root._belowCount >= 2) {
            console.info("FanGuard: the CPU is at " + tempC + " degrees: Performance released");
            PowerBus.release(root.holdSource);
            root._endHold(Date.now() + root.graceMs);
        }
    }

    function _endHold(graceUntil) {
        root._state = "idle";
        root._graceUntil = Math.max(root._graceUntil, graceUntil);
        root._suspectSince = 0;
        root._ring = [];
    }

    Connections {
        target: PowerBus
        function onDropped(sources) {
            // a manual profile change took the hold away: the user's hand wins, and the guard keeps quiet for a long while
            if (root._state === "held" && sources.indexOf(root.holdSource) >= 0) {
                console.info("FanGuard: the hold was dropped by a manual change; quiet for " + Math.round(root.dropCooldownMs / 60000) + " min");
                root._endHold(Date.now() + root.dropCooldownMs);
            }
        }
    }

    Timer {
        id: resumeKick
        interval: root.resumeKickMs
        onTriggered: {
            root._kicks++;
            root.kickRequested("resume");
        }
    }

    // ---- the baseline on disk -------------------------------------------------------------------------------------------------
    function _load() {
        if (root.statePath === "" || !root.persist)
            return;
        store.reload();
        root._base = Fgm.parse(store.text());
        mkdir.running = true;
    }
    function flush() {
        if (root.statePath === "" || !root.persist || !root._dirty)
            return;
        root._dirty = false;
        store.setText(Fgm.serialize(root._base));
    }
    Timer { id: saveTimer; interval: root.saveMs; onTriggered: root.flush() }
    FileView {
        id: store
        path: root.persist ? root.statePath : ""
        blockLoading: true
        blockAllReads: true
        atomicWrites: true
        printErrors: false
        watchChanges: false
    }
    Process {
        id: mkdir
        command: ["mkdir", "-p", root.statePath.substring(0, root.statePath.lastIndexOf("/"))]
        running: false
    }
    Component.onCompleted: root._load()
    Component.onDestruction: root.flush()
}
