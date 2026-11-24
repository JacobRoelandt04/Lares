import QtQuick
import Quickshell
import Quickshell.Io
import "modules/common/system"

// tools/dev/qml/panorama_common_drm.qml -- DrmWatch on a FAKE /sys (PCOM_W/drm, built by the runner) and a udevadm stand-in whose
// events the probe appends to a feed file. Prints "PCD ok|FAIL <name>" lines and "PCD RESULT PASS|FAIL".
Scope {
    id: root
    property string dir: Quickshell.env("PCOM_W")
    // smoked bare (no runner, no fake sysfs): build nothing that reaches out, quit at once
    readonly property bool bare: !root.dir
    property string sys: root.dir + "/sys"
    property int fails: 0
    property int checks: 0
    function check(name: string, ok: bool, detail: string): void {
        root.checks++;
        if (!ok)
            root.fails++;
        console.log("PCD " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }
    function j(v: var): string {
        return JSON.stringify(v);
    }

    DrmWatch {
        id: dw
        drmRoot: root.sys + "/class/drm"
        usbRoot: root.sys + "/bus/usb/devices"
        evdiModule: root.sys + "/module/evdi"
        udevadm: root.dir + "/bin/udevadm"
        systemctl: root.dir + "/bin/systemctl"
        debounceMs: 150
        enabled: !root.bare
        onChanged: root.changes++
    }
    property int changes: 0

    // ---- the stand-ins' logs, the feed ----
    property string calls: ""
    property string sysctl: ""
    Process {
        id: sh
        stdout: StdioCollector { id: shOut }
    }
    property var cont: null
    function run(cmd: string, then: var): void {
        root.cont = then;
        sh.command = ["sh", "-c", cmd];
        sh.running = true;
    }
    Connections {
        target: sh
        function onExited() {
            const f = root.cont;
            root.cont = null;
            if (f)
                f(shOut.text);
        }
    }
    function udev(sub: string, kind: string, n: int): string {
        let c = "for i in $(seq 1 " + n + "); do printf 'UDEV  [%s.123456] " + kind + "   /devices/pci0000:00/x/" + sub + "/y (" + sub + ")\\n' \"$i\" >> '" + root.dir + "/feed'; sleep 0.1; done";
        return c;
    }
    function logs(then: var): void {
        root.run("echo \"$(grep -c . '" + root.dir + "/udevadm.log' 2>/dev/null || echo 0)|$(grep -c . '" + root.dir + "/systemctl.log' 2>/dev/null || echo 0)|$(cat '" + root.dir + "/udevadm.log' 2>/dev/null | head -3 | tr '\\n' ';')|$(cat '" + root.dir + "/systemctl.log' 2>/dev/null | head -3 | tr '\\n' ';')\"", then);
    }

    // ---- the steps ----
    property var scansAt: ({})
    property int stepIx: 0
    property real t0: Date.now()
    property real mark: 0
    property var steps: []
    function until(cond: var, ms: int, name: string): void {
        // checked on the ticker
        root._cond = cond; root._deadline = Date.now() + ms; root._condName = name;
    }
    property var _cond: null
    property real _deadline: 0
    property string _condName: ""
    function by(name: string): var {
        return dw.connectors.filter(c => c.dir === name)[0];
    }

    function s1() {
        root.until(() => dw.scans >= 1 && dw.watching && dw.connectors.length > 0, 8000, "start");
        root._then = function () {
            root.logs(function (t) {
                const f = t.trim().split("|");
                root.check("ONE monitor, both subsystems", f[0] === "1" && f[2].indexOf("monitor --udev --subsystem-match=drm --subsystem-match=usb") >= 0, t);
                root.check("systemctl only with a dock (not asked at start)", f[1] === "0", t);
                const names = dw.connectors.map(c => c.dir).sort().join(",");
                root.check("connectors by directory and by name", names === "card0-HDMI-A-1,card0-eDP-2,card1-HDMI-A-2,card1-eDP-1" && dw.connectors.map(c => c.name).sort().join(",") === "HDMI-A-1,HDMI-A-2,eDP-1,eDP-2", names);
                const hd = root.by("card0-HDMI-A-1"), ig = root.by("card1-eDP-1");
                root.check("driver, vendor, status, enabled", hd.driver === "nvidia" && hd.vendor === "0x10de" && hd.status === "disconnected" && ig.driver === "i915" && ig.vendor === "0x8086" && ig.status === "connected" && ig.enabled === "enabled", root.j([hd, ig]));
                root.check("evdi and the iGPU never count (an iGPU HDMI-A reads connected)", dw.nvidiaHdmi === false && root.by("card1-HDMI-A-2").status === "connected", String(dw.nvidiaHdmi));
                root.check("no dock: usb, since, evdi, service", dw.displayLinkUsb === false && dw.displayLinkSince === 0 && dw.evdiLoaded === false && dw.displayLinkActive === false, "");
                root.check("connected since: the two connected, the others not", Object.keys(dw.connectedSince).sort().join(",") === "HDMI-A-2,eDP-1", root.j(dw.connectedSince));
                root.next();
            });
        };
    }
    function s2() {
        root.mark = dw.scans;
        root.run("printf 'connected\\n' > '" + root.sys + "/class/drm/card0-HDMI-A-1/status'; " + root.udev("drm", "change", 1), function () {});
        root.until(() => dw.nvidiaHdmi === true, 8000, "hdmi up");
        root._then = function () {
            root.check("an NVIDIA HDMI-A reading connected is the fact, in ONE scan", dw.scans === root.mark + 1, dw.scans + "/" + root.mark);
            root.check("its connected-since is set", dw.connectedSince["HDMI-A-1"] > 0, root.j(dw.connectedSince));
            root.next();
        };
    }
    function s3() {
        root.mark = dw.scans;
        root.run(root.udev("drm", "change", 5), function () {});
        root.wait(1200, function () {
            root.check("a burst of five events is one scan", dw.scans === root.mark + 1, dw.scans + "/" + root.mark);
            root.next();
        });
    }
    function s4() {
        root.mark = dw.scans;
        root.run(root.udev("usb", "change", 2) + "; " + root.udev("usb", "bind", 1), function () {});
        root.wait(1000, function () {
            root.check("usb change / bind is no scan", dw.scans === root.mark, dw.scans + "/" + root.mark);
            root.next();
        });
    }
    function s5() {
        root.mark = dw.scans;
        root.run("mkdir -p '" + root.sys + "/class/drm/card2/device' '" + root.sys + "/class/drm/card2-DVI-I-1' '" + root.sys + "/bus/usb/devices/1-3' '" + root.sys + "/module/evdi'; "
                 + "ln -sfn /sys/bus/platform/drivers/evdi '" + root.sys + "/class/drm/card2/device/driver'; printf 'connected\\n' > '" + root.sys + "/class/drm/card2-DVI-I-1/status'; printf 'disabled\\n' > '" + root.sys + "/class/drm/card2-DVI-I-1/enabled'; "
                 + "printf '17e9\\n' > '" + root.sys + "/bus/usb/devices/1-3/idVendor'; " + root.udev("usb", "add", 1), function () {});
        root.until(() => dw.displayLinkUsb === true && dw.displayLinkActive === true, 8000, "dock");
        root._then = function () {
            root.check("a usb add is a scan", dw.scans === root.mark + 1, dw.scans + "/" + root.mark);
            root.check("DisplayLink: usb 17e9 seen, evdi loaded, service active, first-seen time kept", dw.displayLinkSince > 0 && dw.evdiLoaded === true && dw.displayLinkActive === true, root.j([dw.displayLinkSince, dw.evdiLoaded]));
            const e = root.by("card2-DVI-I-1");
            root.check("the evdi connector: no PCI vendor, driver evdi, never the NVIDIA fact", e && e.driver === "evdi" && e.vendor === "" && e.nvidia === false && e.enabled === "disabled" && e.status === "connected" && dw.nvidiaHdmi === true, root.j(e));
            root._since = dw.displayLinkSince;
            root.logs(function (t) {
                root.check("systemctl only with a dock: one is-active call, for the unit", t.trim().split("|")[1] === "1" && t.indexOf("is-active displaylink.service") >= 0, t);
                root.next();
            });
        };
    }
    property real _since: 0
    function s6() {
        root.mark = dw.scans;
        root.run("printf 'x\\n' > /dev/null; rm -rf '" + root.sys + "/class/drm/card2-DVI-I-1' ; printf 'connected\\n' > '" + root.sys + "/class/drm/card0-HDMI-A-1/status'; " + root.udev("drm", "add", 1), function () {});
        root.until(() => dw.scans > root.mark && dw.connectors.length === 4, 8000, "dock connector gone");
        root._then = function () {
            root.check("the first-seen time of the dock does not move on another scan", dw.displayLinkSince === root._since, dw.displayLinkSince + "/" + root._since);
            root.next();
        };
    }
    function s7() {
        root.logs(function (t) {
            root._askedBefore = t.trim().split("|")[1];
            root.s7b();
        });
    }
    property string _askedBefore: ""
    function s7b() {
        root.run("rm -rf '" + root.sys + "/bus/usb/devices/1-3' '" + root.sys + "/module/evdi'; " + root.udev("usb", "remove", 1), function () {});
        root.until(() => dw.displayLinkUsb === false, 8000, "dock gone");
        root._then = function () {
            root.check("the dock leaves: since 0, evdi, service off", dw.displayLinkSince === 0 && dw.evdiLoaded === false && dw.displayLinkActive === false, "");
            root.logs(function (t) {
                root.check("systemctl not asked again", t.trim().split("|")[1] === root._askedBefore, t);
                root.next();
            });
        };
    }
    function s8() {
        const hd = dw.connectedSince["HDMI-A-1"];
        root.mark = dw.scans;
        root.run("printf 'disconnected\\n' > '" + root.sys + "/class/drm/card0-HDMI-A-1/status'", function () { dw.rescan(); });
        root.until(() => dw.nvidiaHdmi === false, 8000, "hdmi down");
        root._then = function () {
            root.check("rescan(): a connector that disconnects leaves the since map", dw.connectedSince["HDMI-A-1"] === undefined && dw.connectedSince["eDP-1"] > 0, root.j(dw.connectedSince));
            root.wait(100, function () {
                root.run("printf 'connected\\n' > '" + root.sys + "/class/drm/card0-HDMI-A-1/status'", function () { dw.rescan(); });
                root.until(() => dw.nvidiaHdmi === true, 8000, "hdmi back");
                root._then = function () {
                    root.check("... and when it connects again the time is new", dw.connectedSince["HDMI-A-1"] > hd, dw.connectedSince["HDMI-A-1"] + "/" + hd);
                    root.next();
                };
            });
        };
    }
    function s9() {
        root.mark = dw.scans;
        root.wait(2000, function () {
            root.check("never a poll: two quiet seconds read nothing", dw.scans === root.mark, dw.scans + "/" + root.mark);
            root.finish();
        });
    }

    function wait(ms: int, f: var): void {
        root._waitUntil = Date.now() + ms;
        root._waitFn = f;
    }
    property real _waitUntil: 0
    property var _waitFn: null
    property var _then: null
    function next() {
        root.stepIx++;
        root._cond = null;
        root._then = null;
        const f = [null, root.s1, root.s2, root.s3, root.s4, root.s5, root.s6, root.s7, root.s8, root.s9][root.stepIx];
        if (f)
            f();
    }
    function finish(): void {
        console.log("PCD RESULT " + (root.fails === 0 ? "PASS" : "FAIL") + " (" + (root.checks - root.fails) + "/" + root.checks + ")");
        quitTimer.start();
    }
    Timer {
        interval: 40
        running: !root.bare
        repeat: true
        onTriggered: {
            if (root._waitFn && Date.now() >= root._waitUntil) {
                const f = root._waitFn;
                root._waitFn = null;
                f();
                return;
            }
            if (root._cond) {
                if (root._cond()) {
                    root._cond = null;
                    if (root._then) {
                        const t = root._then;
                        root._then = null;
                        t();
                    }
                } else if (Date.now() > root._deadline) {
                    root.check("step: " + root._condName, false, "timed out");
                    root._cond = null;
                    root.finish();
                }
            }
        }
    }
    Component.onCompleted: root.bare ? quitTimer.start() : root.next()
    Timer { id: quitTimer; interval: 0; onTriggered: Qt.quit() }
}
