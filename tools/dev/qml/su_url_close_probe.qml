pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "modules/bar/system_update/components"

// su_url_close_probe -- the expanded package's icon opens its upstream URL AND closes the popup, unconditionally.
//
// The real popup on a mock list, with an opener handed in from OUTSIDE the content (as the service hands its own): the section's
// openUrlRequested is fired (what a click on a row's icon emits), then the content is destroyed the way a close destroys it.
//   1. closeRequested fired once, at the click, before the lookup answered (close does not wait for the URL)
//   2. the opener, which outlives the content, still resolves and "opens" the URL (dryRun) AFTER the content is gone
//   3. a package that cannot be resolved (unknown to pacman) still closes, and opens the fallback web page
Window {
    id: win; width: 700; height: 760; visible: true; color: "#EAEDF5"

    PackageUrlOpener { id: opener; dryRun: true }
    AvailableUpdatesService {
        id: avail
        mockMode: true; cacheEnabled: false
        mockSpec: ({ core: 4, extra: 6, multilib: 2, aur: 0, flatpak: 0 })
        favoritesPath: Quickshell.env("SU_TMP") + "/fav.json"
        favoritesLegacyPath: ""
        cachePath: Quickshell.env("SU_TMP") + "/cache.json"
    }
    property bool shown: true
    Loader {
        id: host
        anchors.fill: parent
        active: win.shown
        sourceComponent: SystemUpdatePopup {
            availableUpdates: avail
            urlOpener: opener
            railParticles: false
            onCloseRequested: win.closes++
        }
    }

    property int closes: 0
    property var opened: []
    property var checks: []
    property bool contentGone: false
    function check(name, ok, why) { win.checks.push({ name: name, ok: ok, why: why || "" }); }
    Connections {
        target: opener
        function onResolved(name, url) { win.opened.push({ name: name, url: url, contentGone: win.contentGone }); }
    }

    function findSection(it) {
        if (!it) return null;
        if (it.busyLink !== undefined && it.openUrlRequested) return it;
        const kids = it.children;
        for (let i = 0; i < kids.length; i++) {
            const r = win.findSection(kids[i]);
            if (r) return r;
        }
        return null;
    }

    property int step: 0
    property var sec: null
    Timer {
        interval: 100; repeat: true; running: true
        property int tries: 0
        onTriggered: {
            if (win.step === 0) {
                win.sec = win.findSection(host.item);
                if (!win.sec && ++tries < 60) return;
                win.check("a category section exists", !!win.sec, "none after 6 s");
                if (!win.sec) return win.finish();
                win.step = 1;
                // the click on the icon of a package the machine does not know: the lookup fails, the web page is the answer
                win.sec.openUrlRequested("lares-probe-no-such-package", false);
                win.check("closeRequested fired at the click, before the lookup answered", win.closes === 1 && win.opened.length === 0,
                          "closes=" + win.closes + " opened=" + win.opened.length);
                win.contentGone = true;
                win.shown = false;                 // the close: the content goes
            } else if (win.step === 1 && win.opened.length > 0) {
                win.check("the opener outlived the content and opened a page", win.opened[0].contentGone === true && /^https:\/\/archlinux\.org\/packages\/\?q=lares-probe-no-such-package$/.test(win.opened[0].url),
                          JSON.stringify(win.opened));
                win.check("closed exactly once", win.closes === 1, "closes=" + win.closes);
                win.finish();
            } else if (win.step === 1 && ++tries > 150) {
                win.check("the opener answered", false, "no resolved after the content went");
                win.finish();
            }
        }
    }
    property bool finished: false
    function finish() {
        if (win.finished) return;
        win.finished = true;
        let bad = [];
        for (const c of win.checks) {
            console.log("SUCL " + (c.ok ? "ok  " : "FAIL") + " " + c.name + (c.ok ? "" : "  <" + c.why + ">"));
            if (!c.ok) bad.push(c.name);
        }
        console.log("SUCL RESULT " + (bad.length ? "FAIL (" + bad.join("; ") + ")" : "PASS (" + win.checks.length + " checks)"));
        Qt.quit();
    }
}
