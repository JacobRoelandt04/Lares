pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Quickshell registers the types reachable from the ROOT file's imports.
// qmllint disable unused-imports
import "modules/common/theme"
import "modules/common/system"
import "modules/common/components"
import "modules/notifications/data"
import "modules/notifications/parts"
import "modules/notifications/toast"
import "modules/notifications/manager"
import "modules/notifications/sources"
// qmllint enable unused-imports

// =============================================================================
// usb_notifier_probe.qml -- the drive card, on the real parts: the REAL UsbNotifier behind the real NotificationSources host and the
// real NotificationService on a private bus, and the real NotificationRow / ToastEntry for what a swipe says. UDisks is a stub pair on
// PATH (tools/dev/usb_notifier_probe.sh): `udisksctl monitor` tails fx/monitor.log, `lsblk` prints the world the stubs keep in
// fx/world.json (an SD card mmcblk0 + mmcblk0p1, USB sticks sdb / sdc with two filesystems, a whole-disk filesystem sdd, the internal
// NVMe), and mount / unmount / power-off change that world the way udisks does and write the monitor line it writes.
// Run by tools/dev/usb_notifier_probe.sh. One line per check: `USBN PASS|FAIL <id> <name>`, then `USBN RESULT PASS|FAIL`.
//
//   U1 the shell starts with a drive mounted: its mounted card (kept, not persisted, Open + Unmount); a drive nothing mounted gets none
//   U2 a mount change made ELSEWHERE moves the card: unmounted -> "can be removed" (no actions, not kept, goes after safeSec), mounted again,
//      pulled while mounted -> the warning (a plain card: deletable)
//   U3 plugged -> "connected" (Mount + Eject, body click = Mount): every filesystem mounted, Open = yazi in kitty (exact argv, detached),
//      never xdg-open; the card becomes "mounted"
//   U4 a kept card: remove / clear all / clear group / retention leave it; its row and its toast say no with the shake (nothing committed);
//      a plain card is still deleted by the same verbs
//   U5 Open from the card (through the host's runner, and the host's own detached start)
//   U6 Unmount: a refusal is said on the kept card; then every filesystem unmounted; remounted and unmounted elsewhere; pulled: the card goes at once
//   U7 a whole-disk filesystem mounts; Eject on a connected drive: unmount, power off, "can be removed" outlives the drive by safeSec
// =============================================================================
Window {
    id: w
    width: 900
    height: 700
    visible: true
    color: Theme.surface

    readonly property string cfg: Quickshell.env("CFG") || ""
    readonly property string fx: w.cfg + "/fx"
    readonly property string media: w.cfg + "/media"
    readonly property bool underRunner: w.cfg !== "" && (Quickshell.env("PATH") || "").indexOf(w.cfg + "/stubs:") === 0 && (Quickshell.env("STUB_LOG") || "") !== ""
    readonly property string stubLog: Quickshell.env("STUB_LOG") || ""

    property int fails: 0
    property int checks: 0
    function check(id, name, ok, detail) {
        w.checks++;
        if (!ok)
            w.fails++;
        console.log("USBN " + (ok ? "PASS " : "FAIL ") + id + " " + name + (ok ? "" : "  -- " + detail));
    }

    // ---- timing and processes ---------------------------------------------------------------
    Component {
        id: laterComp
        Timer {
            property var fn
            running: true
            onTriggered: {
                const f = fn;
                destroy();
                f();
            }
        }
    }
    function later(ms, fn) {
        laterComp.createObject(w, { interval: ms, fn: fn });
    }
    function until(pred, ms, cb) {
        const t0 = Date.now();
        const tick = () => {
            const v = pred();
            if (v || Date.now() - t0 > ms)
                cb(v);
            else
                w.later(20, tick);
        };
        tick();
    }
    Component {
        id: shComp
        Item {
            id: job
            property var cb
            property var command: []
            Process {
                id: p
                command: job.command
                running: true
                stdout: StdioCollector {
                    id: so
                }
                onExited: {
                    const f = job.cb;
                    const t = so.text;
                    job.destroy();
                    if (f)
                        f(t);
                }
            }
        }
    }
    function sh(argv, cb) {
        shComp.createObject(w, { command: argv, cb: cb });
    }
    function put(path, text, cb) {
        w.sh(["bash", "-c", "printf %s \"$1\" > \"$2\"", "bash", text, path], () => cb && cb());
    }
    // fxctl <verb> ...: the world's own doings (plug, pull, extmount, extunmount): what another program or the user's hand does
    function fxctl(args, cb) {
        w.sh([w.cfg + "/stubs/fxctl"].concat(args), () => cb && cb());
    }
    function log(cb) {
        w.sh(["cat", w.stubLog], t => cb(t));
    }
    function count(text, needle) {
        return text.split("\n").filter(l => l.indexOf(needle) >= 0).length;
    }

    // ---- the parts -----------------------------------------------------------------------------
    FocusedScreen {
        id: focusSrc
        live: false
    }
    NotificationService {
        id: svc
        serverEnabled: false
        registerOnBus: true
        persist: false
        liveSignals: false
        ipcEnabled: false
        focusSource: focusSrc
        statePath: w.cfg + "/state/lares/notifications/state.json"
        historyPath: w.cfg + "/state/lares/notifications/history.json"
    }
    // the shell's CommandRunner, as far as the source sees it: it records what it is asked to run
    QtObject {
        id: recRunner
        property var calls: []
        function run(argv, opts) {
            recRunner.calls = recRunner.calls.concat([{ argv: argv.slice(), detached: !!opts && opts.detached === true }]);
        }
    }
    property bool hostLive: false
    NotificationSources {
        id: hub
        live: w.hostLive
        only: ["usb"]
        service: svc
        persist: false
        runner: w.useRunner ? recRunner : null
        stateDir: w.cfg + "/state/lares/notifications"
    }
    property bool useRunner: true
    function usb() {
        return hub.sourceOf("usb");
    }

    NotificationStyle {
        id: lookStyle
    }
    GroupPalette {
        id: lookGroups
    }
    BoundaryClock {
        id: lookClock
    }
    Item {
        id: stage
        anchors.fill: parent
    }
    Component {
        id: rowComp
        NotificationRow {
            width: 396
            service: svc
            clock: lookClock
            overlayItem: stage
            groups: lookGroups
            style: lookStyle
            cardWidth: 396
        }
    }
    Component {
        id: toastComp
        ToastEntry {
            width: 396
            service: svc
            clock: lookClock
            overlayItem: stage
            groups: lookGroups
            style: lookStyle
            cardWidth: 396
            property int commits: 0
            onCommitted: commits++
        }
    }

    // ---- reading the store ----------------------------------------------------------------------
    function recs() {
        return svc.store.all().filter(r => r.origin === "shell" && r.sourceId === "usb");
    }
    function card(dev) {
        const l = w.recs().filter(r => r.key === "usb:_dev_" + dev);
        return l.length > 0 ? l[0] : null;
    }
    function has(dev, summaryPart) {
        const r = w.card(dev);
        return !!r && r.summary.indexOf(summaryPart) >= 0;
    }
    function actionIds(r) {
        return r ? r.actions.map(a => a.id + ":" + a.label).join(",") : "";
    }
    function plain(key) {
        return svc.post({ source: "probe", key: key, title: "Plain " + key, body: "an ordinary card", timeoutMs: 8000 });
    }
    function stubCount(needle, cb) {
        w.log(t => cb(w.count(t, needle), t));
    }
    function lastWord(t, n) {
        return t.trim().split("\n").slice(-n).join(" ; ");
    }

    property var steps: []
    property int at: 0
    function step() {
        if (w.at >= w.steps.length) {
            w.finish();
            return;
        }
        const f = w.steps[w.at++];
        f(() => w.later(1, w.step));
    }
    property bool _done: false
    function finish(note) {
        if (w._done)
            return;
        w._done = true;
        console.log("USBN RESULT " + (w.fails === 0 ? "PASS" : "FAIL") + " (" + (w.checks - w.fails) + "/" + w.checks + " checks" + (note ? "; " + note : "") + ")");
        quitTimer.start();
    }
    Timer {
        id: quitTimer
        interval: 0
        onTriggered: Qt.quit()
    }
    Timer {
        interval: 200000
        running: true
        onTriggered: {
            w.fails++;
            console.log("USBN FAIL deadline  -- the probe did not finish, at step " + w.at);
            w.finish("deadline");
        }
    }

    Component.onCompleted: {
        if (!w.underRunner) {
            console.log("USBN not run: a bare run has none of the runner's stubs (udisksctl, lsblk, kitty, xdg-open are the machine's own)");
            w.later(1, () => w.finish("not run, bare"));
            return;
        }
        const mp = d => w.media + "/" + d;
        w.steps = [
            // ---- U1: the shell starts with the SD card mounted (and a stick nothing mounted) -----------------------------------------------
            next => {
                w.later(150, () => {
                    w.hostLive = true;
                    w.until(() => !!w.usb() && w.usb()._known !== null && !!w.card("mmcblk0"), 8000, () => next());
                });
            },
            next => {
                const r = w.card("mmcblk0");
                w.check("U1", "a drive already mounted when the shell starts gets its mounted card", !!r && r.summary === "SDCARD mounted" && r.bodyText === "at " + mp("SDCARD"), r ? r.summary + " | " + r.bodyText : "no card");
                w.check("U1", "the mounted card has Open and Unmount, is quiet and resident", !!r && w.actionIds(r) === "open:Open,unmount:Unmount" && r.urgency === "low" && r.resident === true, w.actionIds(r));
                w.check("U1", "the mounted card is kept, and not persisted (the start posts it again)", !!r && r.kept === true && r.transient === true, r ? "kept " + r.kept + " transient " + r.transient : "");
                w.check("U1", "a drive nothing has mounted (the baseline) gets no card, and no plain 'connected' is announced", w.card("sdb") === null && w.recs().length === 1, JSON.stringify(w.recs().map(x => x.key)));
                next();
            },
            // ---- U2: a mount change made elsewhere moves the card ------------------------------------------------------------------------------
            next => {
                w.fxctl(["extunmount", "/dev/mmcblk0p1"], () => w.until(() => w.has("mmcblk0", "can be removed"), 4000, () => next()));
            },
            next => {
                const r = w.card("mmcblk0");
                w.check("U2", "an unmount made elsewhere (yazi's plugin) moves the card to 'can be removed'", !!r && r.summary === "SDCARD can be removed" && r.bodyText === "Every filesystem on it is unmounted", r ? r.summary + " | " + r.bodyText : "no card");
                w.check("U2", "... with no actions, quiet, and no longer kept", !!r && r.actions.length === 0 && r.kept !== true && r.urgency === "low", r ? w.actionIds(r) + " kept " + r.kept : "");
                w.later(1000, () => {
                    w.check("U2", "... it is still there a second on (safeSec is 2)", w.card("mmcblk0") !== null);
                    w.until(() => w.card("mmcblk0") === null, 4000, ok => {
                        w.check("U2", "... and goes after safeSec, the drive still present", ok === true && !!w.usb()._known["/dev/mmcblk0"], "");
                        next();
                    });
                });
            },
            next => {
                w.fxctl(["extmount", "/dev/mmcblk0p1"], () => w.until(() => w.has("mmcblk0", "mounted"), 4000, () => next()));
            },
            next => {
                const r = w.card("mmcblk0");
                w.check("U2", "a mount made elsewhere brings the mounted card back (kept again)", !!r && r.summary === "SDCARD mounted" && r.kept === true, r ? r.summary + " kept " + r.kept : "no card");
                w.fxctl(["pull", "mmcblk0"], () => w.until(() => w.has("mmcblk0", "was removed"), 4000, () => next()));
            },
            next => {
                const r = w.card("mmcblk0");
                w.check("U2", "pulled while mounted: the warning (files may be damaged), a plain card", !!r && r.summary === "SDCARD was removed" && /damaged/.test(r.bodyText) && r.kept !== true, r ? r.summary + " kept " + r.kept : "no card");
                const uid = r ? r.uid : "";
                w.check("U4", "a plain card is still removed by remove()", !!uid && svc.remove(uid) === true && w.card("mmcblk0") === null, "");
                next();
            },
            // ---- U3: plugged, Mount, Open -----------------------------------------------------------------------------------------------------
            next => {
                w.fxctl(["plug", "sdc"], () => w.until(() => w.has("sdc", "connected"), 4000, () => next()));
            },
            next => {
                const r = w.card("sdc");
                w.check("U3", "plugged: 'connected', the label, size and filesystems", !!r && r.summary === "SanDisk Ultra connected" && r.bodyText === "TESTDRIVE · SPARE · 32 GB · exfat, ntfs", r ? r.summary + " | " + r.bodyText : "no card");
                w.check("U3", "... Mount and Eject, a quiet resident card that is not kept", !!r && w.actionIds(r) === "mount:Mount,eject:Eject" && r.urgency === "low" && r.resident === true && r.kept !== true, r ? w.actionIds(r) : "");
                svc.activate(r.uid);                            // the body click
                w.until(() => w.has("sdc", "mounted") && recRunner.calls.length > 0, 6000, () => next());
            },
            next => {
                w.log(t => {
                    const a = t.indexOf("UDISKS mount -b /dev/sdc1"), b = t.indexOf("UDISKS mount -b /dev/sdc2");
                    w.check("U3", "the body click mounts EVERY filesystem of the drive, in order (udisksctl mount -b)", a >= 0 && b > a, w.lastWord(t, 4));
                    const c = recRunner.calls[recRunner.calls.length - 1];
                    const want = ["kitty", "-o", "background_opacity=0.75", "--title", "yazi", "yazi", mp("TESTDRIVE")];
                    w.check("U3", "Open is yazi in the user's kitty window at the first mount point (exact argv), started detached through the host", !!c && JSON.stringify(c.argv) === JSON.stringify(want) && c.detached === true, c ? JSON.stringify(c) : "no call");
                    w.check("U3", "xdg-open is never called", t.indexOf("OPEN ") < 0, w.lastWord(t, 3));
                    const r = w.card("sdc");
                    w.check("U3", "the card moved to 'mounted', both mount points, kept", !!r && r.summary === "SanDisk Ultra mounted" && r.bodyText === "at " + mp("TESTDRIVE") + ", " + mp("SPARE") && r.kept === true, r ? r.summary + " | " + r.bodyText + " kept " + r.kept : "");
                    next();
                });
            },
            // ---- U4: a kept card refuses -----------------------------------------------------------------------------------------------------------
            next => {
                const r = w.card("sdc");
                const uid = r.uid;
                w.check("U4", "remove() of a kept card is refused and does nothing", svc.remove(uid) === false && w.card("sdc") !== null, "");
                w.plain("a");
                svc.clearAll();
                w.check("U4", "clear all takes the plain cards and leaves the kept one", w.card("sdc") !== null && svc.store.all().filter(x => x.sourceId === "probe").length === 0, JSON.stringify(svc.store.all().map(x => x.key)));
                w.plain("b");
                svc.clearGroup(r.group);
                w.check("U4", "clear group likewise", w.card("sdc") !== null && svc.store.all().filter(x => x.sourceId === "probe").length === 0, "");
                w.put(w.cfg + "/xdg/quickshell/config/notifications.jsonc", '{ "retention": { "count": 1, "days": 7 }, "sources": { "usb": { "debounceMs": 150, "safeSec": 2 } } }\n', () => {
                    w.until(() => svc.config.retention && svc.config.retention.count === 1, 4000, ok => {
                        w.plain("c"); w.plain("d"); w.plain("e");
                        // a toast still on the lane is protected whatever its kind: take every one off it first, so the kept card is a real candidate
                        for (let i = 0; i < 12 && svc.toasts.shown.concat(svc.toasts.held).length > 0; i++)
                            for (const u of svc.toasts.shown.concat(svc.toasts.held))
                                svc.toasts.unshow(u);
                        const onLane = svc.toasts.shown.length + svc.toasts.held.length;
                        svc._retain();
                        const left = svc.store.all().filter(x => x.sourceId === "probe").length;
                        w.check("U4", "the retention pass keeps a kept card whatever the count (the plain ones are cut to it)", ok === true && onLane === 0 && w.card("sdc") !== null && left === 1, "count 1 in force " + ok + ", plain left " + left + ", still on the lane " + onLane + " " + JSON.stringify(svc.toasts.shown.concat(svc.toasts.held).map(u => svc.store.get(u) ? svc.store.get(u).key : u)));
                        svc.clearAll();
                        w.put(w.cfg + "/xdg/quickshell/config/notifications.jsonc", '{ "toasts": { "floodCount": 1000 }, "sources": { "usb": { "debounceMs": 150, "safeSec": 2 } } }\n', () => next());
                    });
                });
            },
            next => {
                const r = w.card("sdc");
                const row = rowComp.createObject(stage, { uid: r.uid });
                row.deleteAction();
                w.check("U4", "the delete says no with the shake (manager row: Delete key / verb), and the card stays", row.refusing === true && w.card("sdc") !== null, "refusing " + row.refusing);
                w.until(() => !row.refusing, 3000, () => {
                    row.scrub(-300);
                    row.release(0);
                    w.check("U4", "a delete swipe on the kept row springs back with the shake, committing nothing", row.refusing === true && w.card("sdc") !== null && row.swiping, "refusing " + row.refusing);
                    w.until(() => !row.refusing && !row.swiping, 3000, ok => {
                        w.check("U4", "... and ends at rest", ok === true && row.offset === 0, "offset " + row.offset);
                        const pu = w.plain("p");
                        const prow = rowComp.createObject(stage, { uid: pu });
                        prow.scrub(-300);
                        prow.release(0);
                        w.until(() => w.recs().length >= 0 && svc.store.get(pu) === null, 3000, gone => {
                            w.check("U4", "the same swipe on a plain card deletes it (no shake)", gone === true && prow.refusing === false, "gone " + gone);
                            const te = toastComp.createObject(stage, { uid: r.uid });
                            te.scrub(-300);
                            te.release(0);
                            w.check("U4", "a delete swipe on the kept TOAST shakes and commits nothing", te.refusing === true && te.commits === 0 && w.card("sdc") !== null, "refusing " + te.refusing + " commits " + te.commits);
                            w.until(() => !te.refusing && !te.swiping, 3000, () => {
                                te.scrub(300);
                                te.release(0);
                                w.check("U4", "the toast's other swipe (file) still works on a kept card", te.commits === 1 && !te.refusing, "commits " + te.commits);
                                row.destroy(); prow.destroy(); te.destroy();
                                next();
                            });
                        });
                    });
                });
            },
            // ---- U4: the verbs of the sides are the user's (toasts.swipe, manager.swipe), the rules follow the verb ------------------------------
            next => {
                const conf = extra => '{ "toasts": { "floodCount": 1000' + extra + ' }, "manager": { "swipe": { "right": "delete", "left": "pin" } }, "sources": { "usb": { "debounceMs": 150, "safeSec": 2 } } }\n';
                const path = w.cfg + "/xdg/quickshell/config/notifications.jsonc";
                w.put(path, conf(', "swipe": { "right": "delete", "left": "file" }'), () => w.until(() => svc.config.manager.swipe.left === "pin", 4000, () => {
                    const r = w.card("sdc");
                    const kept = rowComp.createObject(stage, { uid: r.uid }), kt = toastComp.createObject(stage, { uid: r.uid });
                    const pu = w.plain("q"), qu = w.plain("r");
                    const prow = rowComp.createObject(stage, { uid: pu }), qrow = rowComp.createObject(stage, { uid: qu });
                    for (const c of [kept, kt, prow]) {
                        c.scrub(300);
                        c.release(0);
                    }
                    w.check("U4", "swapped: the delete to the right, a kept row and a kept toast say no", kept.refusing && kt.refusing && kt.commits === 0 && w.card("sdc") !== null, kept.refusing + " " + kt.refusing);
                    w.check("U4", "swapped: a toast that files by itself goes left", kt.fileDir === -1, kt.fileDir);
                    qrow.scrub(-300);
                    qrow.release(0);
                    w.until(() => svc.store.get(pu) === null && svc.store.get(qu) !== null && svc.store.get(qu).pinned === true && !qrow.swiping, 3000, ok => {
                        w.check("U4", "swapped: right deletes a plain row, left pins one (and it springs back)", ok === true && qrow.offset === 0, JSON.stringify(svc.store.get(qu)));
                        for (const c of [kept, kt, prow, qrow])
                            c.destroy();
                        svc.remove(qu);
                        w.put(path, conf("").replace(/"manager": \{[^}]*\} \}, /, ""), () => w.until(() => svc.config.manager.swipe.left === "delete", 4000, () => next()));
                    });
                }));
            },
            // ---- U5: Open from the card; the host's own detached start --------------------------------------------------------------
            next => {
                const n0 = recRunner.calls.length;
                svc.invoke(w.card("sdc").uid, "open");
                w.check("U5", "Open on the mounted card runs the opener again, at the first mount point", recRunner.calls.length === n0 + 1 && recRunner.calls[n0].argv[recRunner.calls[n0].argv.length - 1] === mp("TESTDRIVE") && recRunner.calls[n0].detached === true && w.card("sdc") !== null, "calls " + (recRunner.calls.length - n0));
                w.useRunner = false;                            // no shell runner: the host starts it itself, detached
                svc.invoke(w.card("sdc").uid, "open");
                w.until(() => hub.exec.calls.length > 0 && hub.exec.calls[hub.exec.calls.length - 1].indexOf("setsid") === 0, 3000, () => {
                    const c = hub.exec.calls[hub.exec.calls.length - 1];
                    w.check("U5", "the host's own start is detached (setsid -f) and runs kitty with the same argv", !!c && c[0] === "setsid" && c.slice(-7).join(" ") === ["kitty", "-o", "background_opacity=0.75", "--title", "yazi", "yazi", mp("TESTDRIVE")].join(" "), c ? c.join(" ") : "");
                    w.later(500, () => w.log(t => {
                        w.check("U5", "... and the stub kitty heard it", t.indexOf("KITTY -o background_opacity=0.75 --title yazi yazi " + mp("TESTDRIVE")) >= 0, w.lastWord(t, 2));
                        w.useRunner = true;
                        next();
                    }));
                });
            },
            // ---- U6: Unmount --------------------------------------------------------------------------------------------------------------------------------
            next => {
                w.put(w.fx + "/fail_unmount", "Error unmounting /dev/sdc1: GDBus.Error:org.freedesktop.UDisks2.Error.DeviceBusy: target is busy\n", () => {
                    svc.invoke(w.card("sdc").uid, "unmount");
                    w.until(() => w.has("sdc", "Could not"), 5000, () => next());
                });
            },
            next => {
                const r = w.card("sdc");
                w.check("U6", "a refused unmount is said on the card, with the reason a person reads", !!r && r.summary === "Could not unmount SanDisk Ultra" && r.bodyText === "target is busy", r ? r.summary + " | " + r.bodyText : "");
                w.check("U6", "... and the card stays kept with Open and Unmount for another try", !!r && r.kept === true && w.actionIds(r) === "open:Open,unmount:Unmount", r ? "kept " + r.kept + " " + w.actionIds(r) : "");
                w.sh(["rm", "-f", w.fx + "/fail_unmount"], () => {
                    svc.invoke(w.card("sdc").uid, "unmount");
                    w.until(() => w.has("sdc", "can be removed"), 6000, () => next());
                });
            },
            next => {
                const r = w.card("sdc");
                w.check("U6", "Unmount unmounts every filesystem (udisksctl unmount -b), and the card moves to 'can be removed'", !!r && r.summary === "SanDisk Ultra can be removed" && r.kept !== true && r.actions.length === 0, r ? r.summary : "no card");
                w.log(t => {
                    w.check("U6", "... both partitions were unmounted", t.indexOf("UDISKS unmount -b /dev/sdc1") >= 0 && t.indexOf("UDISKS unmount -b /dev/sdc2") >= 0, w.lastWord(t, 3));
                    w.fxctl(["extmount", "/dev/sdc2"], () => w.until(() => w.has("sdc", "mounted") && !w.has("sdc", "can be removed"), 4000, ok => {
                        const q = w.card("sdc");
                        w.check("U6", "any one filesystem mounted by anything moves it to 'mounted' again", ok === true && !!q && q.kept === true && q.bodyText === "at " + mp("SPARE"), q ? q.summary + " | " + q.bodyText : "no card");
                        w.fxctl(["extunmount", "/dev/sdc2"], () => w.until(() => w.has("sdc", "can be removed"), 4000, () => {
                            w.fxctl(["pull", "sdc"], () => w.until(() => w.card("sdc") === null, 1500, gone => {
                                w.check("U6", "pulled while 'can be removed': the card goes with the drive at once (not after safeSec)", gone === true, "");
                                next();
                            }));
                        }));
                    }));
                });
            },
            // ---- U7: whole-disk filesystem; Eject ---------------------------------------------------------------------------------------------
            next => {
                w.fxctl(["plug", "sdd"], () => w.until(() => w.has("sdd", "connected"), 4000, () => {
                    svc.activate(w.card("sdd").uid);
                    w.until(() => w.has("sdd", "mounted"), 5000, () => next());
                }));
            },
            next => {
                w.log(t => {
                    w.check("U7", "a whole-disk filesystem (no partition) mounts by the disk's own path", t.indexOf("UDISKS mount -b /dev/sdd\n") >= 0, w.lastWord(t, 3));
                    w.check("U7", "... and its card is the kept mounted card", !!w.card("sdd") && w.card("sdd").kept === true && w.card("sdd").bodyText === "at " + mp("WHOLE"), w.card("sdd") ? w.card("sdd").bodyText : "");
                    w.fxctl(["pull", "sdd"], () => w.until(() => w.has("sdd", "was removed"), 4000, () => {
                        svc.remove(w.card("sdd").uid);
                        w.fxctl(["pull", "sdb"], () => w.until(() => !w.usb()._known["/dev/sdb"], 4000, () => w.fxctl(["plug", "sdb"], () => w.until(() => w.has("sdb", "connected"), 4000, () => next()))));
                    }));
                });
            },
            next => {
                const r = w.card("sdb");
                w.check("U7", "plugged again: the first-time drive gets its connected card", !!r && r.summary === "Kingston DataTraveler 3.0 connected", r ? r.summary : "no card");
                svc.invoke(r.uid, "eject");
                w.until(() => w.has("sdb", "can be removed"), 6000, () => next());
            },
            next => {
                w.log(t => {
                    const iu = t.indexOf("UDISKS power-off -b /dev/sdb");
                    w.check("U7", "Eject powers the drive off, and the same card says it can be removed", iu >= 0 && w.card("sdb").bodyText === "Every filesystem on it is unmounted", w.lastWord(t, 2));
                    w.until(() => !w.usb()._known["/dev/sdb"], 4000, () => {
                        w.later(800, () => {
                            w.check("U7", "... the card outlives the vanished drive (it is still there to be read)", w.card("sdb") !== null, "");
                            w.until(() => w.card("sdb") === null, 5000, ok => {
                                w.check("U7", "... and goes safeSec after it", ok === true, "");
                                next();
                            });
                        });
                    });
                });
            },
            next => {
                w.log(t => {
                    w.check("U8", "through the whole run xdg-open was never called", t.indexOf("OPEN ") < 0, w.lastWord(t, 2));
                    next();
                });
            }
        ];
        w.later(1, w.step);
    }
}
