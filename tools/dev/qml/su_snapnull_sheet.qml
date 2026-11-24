pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import Quickshell

import "modules/common/theme"
import "modules/bar/system_update/components"

// su_snapnull_sheet.qml -- the update popup WITHOUT snapshots, at a handful of states, saved as PNGs: the same file runs on the tree before the
// snapshots work and on the tree after it, and the two sheets must not differ by one pixel (tools/dev/su_snapnull_sheet.sh). Uses nothing the
// snapshots work added: a stand-in backend, the real parser and popup, a transcript with no hook line.
ShellRoot {
    id: probe
    settings.watchFiles: false
    readonly property string outDir: Quickshell.env("SNS_OUT") || ""
    Timer { interval: 0; running: probe.outDir === ""; onTriggered: Qt.quit() }
    Item {
        id: be
        property bool running: false
        property bool awaitingInput: false
        property bool passwordPrompt: false
        property string lastPrompt: ""
        property bool attached: false
        property int attachPid: 0
        property var linesModel: ListModel {}
        property color defaultFg: "#5D5D5F"
        property string fontFamily: "Consolas"
        property int trimmedLines: 0
        function submit(text: string): void {}
        signal lineAppended(string raw)
        signal progressPreview(string text)
        signal previewUpdated(string text)
        signal screenRows(var rows)
        signal started()
        signal exited(int code, int status)
    }
    PackageUpdateParser { id: pp; backend: be }
    Window {
        id: win
        visible: probe.outDir !== ""
        width: 760
        height: 700
        color: Theme.surface
        SystemUpdatePopup {
            id: popup
            anchors.fill: parent
            backend: be
            parser: pp
            railParticles: false
            stepsSettleMs: 40
            idleSubtextDelayMs: 40
            verbosityMode: "normal"
        }
    }
    function feed(lines: var): void { for (const l of lines) be.lineAppended(l); }
    property var steps: []
    property int at: 0
    property real since: 0
    property bool busy: false
    Timer {
        interval: 30
        repeat: true
        running: probe.outDir !== ""
        onTriggered: {
            if (probe.busy) return;
            if (probe.at >= probe.steps.length) { console.log("SNS DONE"); Qt.quit(); return; }
            if (Date.now() - probe.since < probe.steps[probe.at].wait) return;
            const st = probe.steps[probe.at];
            probe.at++;
            probe.since = Date.now();
            if (st.act) st.act();
            if (st.shot) {
                probe.busy = true;
                win.contentItem.grabToImage(r => { r.saveToFile(probe.outDir + "/" + st.shot + ".png"); probe.busy = false; });
            }
        }
    }
    Component.onCompleted: {
        const rows = [":: 45 packages to upgrade/install."];
        for (let i = 1; i <= 45; i++) rows.push("  " + i + " extra/pkg" + i + " 1.0-1 -> 1.1-1");
        rows.push("  46 aur/aurpkg 1.0-1 -> 1.1-1");
        const table = ["Package (45)  Old Version  New Version  Net Change  Download Size"];
        for (let i = 1; i <= 45; i++) table.push("extra/pkg" + i + "  1.0-1  1.1-1  0.10 MiB  1.00 MiB");
        table.push("Total Download Size:  45.00 MiB");
        const pre = [":: Synchronizing package databases...", ":: Searching AUR for updates..."].concat(rows)
            .concat([":: Starting full system upgrade...", "resolving dependencies...", "looking for conflicting packages..."]).concat(table);
        const install = [":: Retrieving packages...", "(1/5) checking keys in keyring                       [######] 100%",
                         ":: Running pre-transaction hooks...", "(1/2) Hook one...", "(2/2) Hook two...",
                         ":: Processing package changes..."];
        for (let i = 1; i <= 20; i++) install.push("(" + i + "/45) upgrading pkg" + i + "          [######] 100%");
        const hooks = [":: Running post-transaction hooks...", "(1/2) Arming ConditionNeedsUpdate...", "(2/2) Updating the desktop file MIME type cache..."];
        const S = [];
        const mode = m => ({ wait: 600, act: () => { popup.verbosityMode = m; }, shot: "" });
        S.push({ wait: 700, shot: "idle_normal" });
        S.push({ wait: 100, act: () => { popup.verbosityMode = "quiet"; }, shot: "" });
        S.push({ wait: 700, shot: "idle_quiet" });
        S.push({ wait: 100, act: () => { popup.verbosityMode = "normal"; be.running = true; be.started(); probe.feed(pre); }, shot: "" });
        S.push({ wait: 900, shot: "resolve_normal" });
        S.push({ wait: 100, act: () => { probe.feed(install); }, shot: "" });
        S.push({ wait: 3000, shot: "install_normal" });     // the ball's shadow is still easing at 900 ms (1 or 2 levels, 31 px)
        S.push({ wait: 100, act: () => { popup.verbosityMode = "quiet"; }, shot: "" });
        S.push({ wait: 700, shot: "install_quiet" });
        S.push({ wait: 100, act: () => { probe.feed(hooks); }, shot: "" });
        S.push({ wait: 700, shot: "hooks_quiet" });
        S.push({ wait: 100, act: () => { be.running = false; be.exited(0, 0); }, shot: "" });
        S.push({ wait: 900, shot: "complete_quiet" });
        S.push({ wait: 100, act: () => { popup.verbosityMode = "normal"; }, shot: "" });
        S.push({ wait: 800, shot: "complete_normal" });
        S.push({ wait: 100, act: () => { be.running = true; be.started(); probe.feed(pre); probe.feed(install.slice(0, 5)); probe.feed(["error: failed to commit transaction (conflicting files)"]); be.running = false; be.exited(1, 0); }, shot: "" });
        S.push({ wait: 2500, shot: "failed_normal" });
        S.push({ wait: 100, act: () => { popup.verbosityMode = "quiet"; }, shot: "" });
        S.push({ wait: 2500, shot: "failed_quiet" });
        probe.steps = S;
        probe.since = Date.now();
    }
}
