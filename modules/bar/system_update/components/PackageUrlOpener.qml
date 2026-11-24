pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// =============================================================================
// PackageUrlOpener.qml
//
// Resolves a package's upstream URL and opens it in the browser, so the
// changelog for the version you are about to get is one click away.
//
// LAZY by design. Nothing is looked up until `open()` is called for one
// package, because the list can hold three hundred rows and the user will
// click the link on two of them. Resolving every row up front would be three
// hundred processes -- and, for the AUR, three hundred RPC calls -- for
// nothing.
//
//   official   LC_ALL=C pacman -Si <name>    reads the sync DB, instant
//   AUR        LC_ALL=C yay -Si <name>       asks the AUR RPC, takes a moment
//
// Both print a `URL : ...` field. LC_ALL=C pins the label to English, so a
// localised pacman cannot hide it; the match is anchored at the line start so
// yay's `AUR URL` line is never mistaken for it. When no usable URL comes back
// (unknown package, "None", the lookup timed out, yay missing...) the
// package's own web page is opened instead, which always exists:
//
//   official   https://archlinux.org/packages/?q=<name>   (search: needs no repo/arch)
//   AUR        https://aur.archlinux.org/packages/<name>
//
// So `resolved` fires for the fallback too, with the fallback URL. `failed`
// fires only when NOTHING could be opened: an empty name, or a desktop with
// no handler for https URLs.
//
// One resolve at a time. A click while `busyName` is set is IGNORED, not
// queued: the row being resolved shows a busy glyph, and a queued request
// would open a second tab seconds after a click the user has moved on from.
//
// Only http(s) URLs are ever handed to the browser, whatever the field says.
//
// Usage:
//   PackageUrlOpener { id: urlOpener }
//   UpdateCategorySection {
//       onOpenUrlRequested: (name, isAur) => urlOpener.open(name, isAur)
//       busyLink: urlOpener.busyName
//   }
// =============================================================================
Item {
    id: opener

    // The package whose URL is being resolved right now; "" when idle.
    readonly property string busyName: opener._busy
    // Seconds the lookup may take before it is abandoned and the web page is
    // opened instead. The AUR RPC is normally well under a second; this only
    // matters when the network is down or silently blackholed.
    property int timeoutSec: 8
    // Emit `resolved` with the URL instead of handing it to the browser.
    // For probes, so a test never opens a tab.
    property bool dryRun: false

    // The URL that was opened: the upstream one, or the fallback web page.
    signal resolved(string name, string url)
    // Nothing could be opened for this package.
    signal failed(string name, string reason)

    property string _busy: ""
    property bool _busyIsAur: false

    function open(name, isAur) {
        const n = (name || "").trim();
        if (n.length === 0) { opener.failed(n, "empty package name"); return; }
        if (opener._busy.length > 0) return;
        opener._busy = n;
        opener._busyIsAur = !!isAur;
        // The name travels as `$1`, never interpolated into the script, so a
        // package name cannot become shell. `exec` makes `timeout` the
        // process itself, so stopping the Process stops the lookup too.
        const tool = opener._busyIsAur ? "yay" : "pacman";
        proc.command = ["sh", "-c",
            "exec timeout " + opener.timeoutSec + " env LC_ALL=C " + tool + " -Si \"$1\"",
            "sh", n];
        watchdog.restart();
        proc.running = true;
    }

    function _webPage(name, isAur) {
        const q = encodeURIComponent(name);
        return isAur ? "https://aur.archlinux.org/packages/" + q
                     : "https://archlinux.org/packages/?q=" + q;
    }

    function _isHttp(url) {
        return /^https?:\/\/\S+$/i.test(url || "");
    }

    // One exit, whichever way the lookup ended. The guard makes the watchdog
    // and the process's own exit safe to both call it.
    function _finish(stdoutText, stderrText) {
        if (opener._busy.length === 0) return;
        const name = opener._busy;
        const isAur = opener._busyIsAur;
        watchdog.stop();
        opener._busy = "";

        let url = "";
        const m = (stdoutText || "").match(/^URL\s*:\s*(\S+)\s*$/m);
        if (m && opener._isHttp(m[1])) url = m[1];
        if (url.length === 0) {
            url = opener._webPage(name, isAur);
            const why = ((stderrText || "").trim().split("\n")[0]
                         || (stdoutText || "").trim().split("\n")[0]
                         || "no URL field").trim();
            console.log("PackageUrlOpener: no upstream URL for " + name
                        + " (" + why + "); opening " + url);
        }
        opener._deliver(name, url);
    }

    function _deliver(name, url) {
        if (!opener._isHttp(url)) {
            opener.failed(name, "not an http(s) URL: " + url);
            return;
        }
        if (opener.dryRun || Qt.openUrlExternally(url)) opener.resolved(name, url);
        else opener.failed(name, "no handler could open " + url);
    }

    Process {
        id: proc
        running: false
        stdout: StdioCollector { id: out }
        stderr: StdioCollector { id: err }
        onExited: opener._finish(out.text, err.text)
    }

    // Belt and braces over `timeout`: should the process never report back
    // at all (failed to spawn, say), the row must not stay busy forever.
    Timer {
        id: watchdog
        interval: (opener.timeoutSec + 3) * 1000
        repeat: false
        onTriggered: {
            proc.running = false;
            opener._finish("", "lookup did not return in time");
        }
    }
}
