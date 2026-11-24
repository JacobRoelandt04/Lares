pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

import "modules/common/theme"
import "modules/common/components"
import "modules/common/mockup"
import "modules/bar/system_update/snapshots"
import "modules/bar/system_update/snapshots/SnapshotFixtures.js" as Fixtures

// =============================================================================
// mockups/snapshots.qml -- the snapshots page of the system update popup (modules/bar/system_update/snapshots): the head (title, "6
// snapshots, 18 GB", Snapshot now, the off-site line) and a carved card per snapshot, the newest open; Undo / Keep / Delete on the open one.
//
//   quickshell -p mockups/snapshots.qml          (SNAP_SCENE=<name>, SNAP_MODE=light|dark pick a state at the start: a grab's way)
//
// The service is the MOCK (SnapshotService `live: false`): realistic records (real package names; the first snapshot 12 GB, the rest 0.6 to
// 4 GB), every verb answered in memory, every call in the Run tab's log. Nothing here reaches restic, pkexec or the machine.
// =============================================================================
MockupWindow {
    id: win

    moduleId: "snapshots"
    title: "Snapshots mockup"
    content: page
    target: page

    lists: ({
            pageParams: win.pageParams
        })
    tabDefs: [
        { name: "Run", page: runPage },
        { name: "Page", lists: ["pageParams"] }
    ]

    SnapshotService {
        id: svc
        live: false
        runActive: false
        // a mock create lasts long enough to be looked at
        mockCreateMs: 6000
        onBattery: Quickshell.env("SNAP_AC") !== "1"
    }

    SnapshotsPage {
        id: page
        service: svc
        fontFamily: Quickshell.env("SNAP_FONT") || "Audiowide"
        runActive: win.running
        onUndoRequested: short => win.undone = short
    }

    property bool running: false
    property string undone: ""
    property string scene: "many"

    function _clone(n) {
        const base = Fixtures.records(Date.now());
        const out = base.slice();
        for (let i = 0; out.length < n; i++) {
            const src = base[(i % (base.length - 1)) + 1];
            const c = Object.assign({}, src);
            c.short = ("0123456789abcdef" + (i * 7919 + 4099).toString(16) + "ab").slice(-8);
            c.time = src.time - (i + 1) * 5 * 86400;
            c.keep = false;
            out.push(c);
        }
        return out;
    }
    function setScene(name) {
        win.scene = name;
        svc.mockState = "ready";
        svc.mockOffsiteEnabled = true;
        const now = Date.now();
        const full = Fixtures.records(now);
        if (name === "empty") svc.mockRecords = [];
        else if (name === "one") svc.mockRecords = full.slice(0, 1);
        // a machine's first evening: one snapshot taken by hand, nothing installed since
        else if (name === "first") svc.mockRecords = [Object.assign({}, full[2], { time: Math.floor(now / 1000) - 4 * 3600, changed: null, added: 12.7e9 })];
        else if (name === "few") svc.mockRecords = full;
        else if (name === "many") svc.mockRecords = win._clone(11);
        else if (name === "missing") svc.mockState = "missing";
        else if (name === "long") {
            const r = full.slice(0, 3).map(x => Object.assign({}, x));
            r[0].title = "";
            r[0].critical = ["linux-firmware-nvidia-extremely-long-package-name", "quickshell-git-with-a-name-that-goes-on", "nvidia-open-dkms", "mesa"];
            r[0].changed = [
                { name: "linux-firmware-nvidia-extremely-long-package-name", from: "20261001.abcdef1-1", to: "20261112.f00dcafe-1" },
                { name: "quickshell-git-with-a-name-that-goes-on", from: "0.3.1.r12.g1234567-1", to: "0.3.2.r4.gabcdef0-1" },
                { name: "nvidia-open-dkms", from: "615.35.01-1", to: "615.40.02-1" },
                { name: "mesa", from: "1:26.2.1-1", to: "1:26.2.2-1" }].concat(r[0].changed.slice(4));
            svc.mockRecords = r;
        } else if (name === "unfinished") {
            const r = full.slice(0, 3).map(x => Object.assign({}, x));
            r[0].state = "open";
            r[0].changed = null;
            r[0].time = Math.floor(now / 1000) - 3 * 3600;
            svc.mockRecords = r;
        } else svc.mockRecords = full;
        if (name === "busy") {
            svc.mockRecords = full;
            Qt.callLater(() => svc.create());
        }
        svc._mockRead();
    }
    function setOffsite(kind) {
        const now = Math.floor(Date.now() / 1000);
        svc.mockOffsiteEnabled = kind !== "disabled";
        if (kind === "idle") svc.mockOffsite = { state: "idle", reason: "", lastOk: now - 86400 - 3600, pending: { files: 0, bytes: 0 }, done: { files: 0, bytes: 0 }, snapshots: ["6a493314", "b01c7e22"], pid: 0 };
        else if (kind === "running") svc.mockOffsite = { state: "running", reason: "", lastOk: now - 86400, pending: { files: 800, bytes: 2.2e9 }, done: { files: 1200, bytes: 1.2e9 }, snapshots: ["b01c7e22"], pid: 4242 };
        else if (kind === "signin") svc.mockOffsite = { state: "error", cause: "signin", reason: "Proton Drive is signed out.", lastOk: 0, pending: { files: 0, bytes: 0 }, done: { files: 0, bytes: 0 }, snapshots: [], pid: 0 };
        else if (kind === "waiting") svc.mockOffsite = { state: "waiting", reason: "The machine is on battery; the copy waits for the charger.", cause: "battery", lastOk: now - 5 * 86400, pending: { files: 10, bytes: 1e8 }, done: { files: 0, bytes: 0 }, snapshots: ["b01c7e22"], pid: 0 };
        else svc.mockOffsite = { state: "off" };
    }

    Component.onCompleted: {
        const mode = Quickshell.env("SNAP_MODE");
        if (mode === "dark" || mode === "light") Theme.setMode(mode);
        win.setScene(Quickshell.env("SNAP_SCENE") || "many");
        const off = Quickshell.env("SNAP_OFFSITE");
        if (off) win.setOffsite(off);
        const open = Quickshell.env("SNAP_OPEN");
        if (open) page.pick = open;
        if (Quickshell.env("SNAP_RUN") === "1") win.running = true;
        if (Quickshell.env("SNAP_UNFOLD") === "1") Qt.callLater(() => { const c = page.cards.itemAt(0); if (c) c.listOpen = true; });
    }

    pages: [
        MockupPage {
            id: runPage

            TipGroup {
                title: "Scenarios"
                blurb: "One click puts the mock service in a state."
            }
            TipRow {
                tip: "The records the mock serves. Empty: nothing taken yet. One / Few / Many: 1, 8 and 11 snapshots (the list scrolls). Long names: package names that must elide. Unfinished: the newest record is still open with no update running."
                Layout.fillWidth: true
                spacing: 8
                Repeater {
                    model: ["empty", "first", "one", "few", "many", "long", "unfinished"]
                    delegate: Button {
                        required property string modelData
                        text: modelData
                        onClicked: win.setScene(modelData)
                    }
                }
                Item { Layout.fillWidth: true }
            }
            TipRow {
                tip: "Not installed: the root tool is missing (the page says how to set it up). Busy: a manual snapshot is being taken (the head shows its progress, the buttons rest)."
                Layout.fillWidth: true
                spacing: 8
                Button { text: "not installed"; onClicked: win.setScene("missing") }
                Button { text: "taking one"; onClicked: win.setScene("busy") }
                CheckBox {
                    text: "update running"
                    checked: win.running
                    onToggled: win.running = checked
                }
                Item { Layout.fillWidth: true }
            }
            TipGroup {
                title: "Off site"
                blurb: "The line under the summary, from offsite.json."
            }
            TipRow {
                tip: "Proton Drive's state: up to date (with when), copying (done of total), needing a sign-in, waiting for a condition, or off (no line)."
                Layout.fillWidth: true
                spacing: 8
                Repeater {
                    model: ["idle", "running", "signin", "waiting", "disabled"]
                    delegate: Button {
                        required property string modelData
                        text: modelData
                        onClicked: win.setOffsite(modelData)
                    }
                }
                Item { Layout.fillWidth: true }
            }
            TipGroup {
                title: "State"
                blurb: "What the page believes, and the calls the live service would make."
            }
            Label {
                Layout.fillWidth: true
                text: "scene: " + win.scene + "   rows: " + svc.rows.length + "   open: " + page.openShort + "   busy: " + svc.busyKind
                    + "\nlast undo asked: " + (win.undone || "-") + "   page: " + page.implicitWidth + " x " + page.naturalHeight
                    + "\ncalls: " + svc.calls.slice(-6).join(" | ")
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 11
                wrapMode: Text.Wrap
            }
        }
    ]

    readonly property var pageParams: [
        {
            label: "width", prop: "pageWidth", group: "Page",
            blurb: "The page beside the update popup.",
            tip: "Width of the page. 380 holds 'Before 112 packages' and a version pair on one line each; the update popup beside it is about as wide.",
            val: 380, from: 300, to: 520, step: 2
        },
        {
            label: "max height", prop: "maxHeight", group: "Page",
            tip: "The tallest the page asks for; past it the cards scroll under a fade. 560 keeps it inside a 1080 px screen under the bar with the popup beside it.",
            val: 560, from: 260, to: 900, step: 10
        },
        {
            label: "padding", prop: "padding", group: "Page",
            tip: "Space round the page, px. 12 is the popup's padding, the same on every side.",
            val: 12, from: 6, to: 24, step: 1
        },
        {
            label: "card gap", prop: "cardGap", group: "Cards",
            tip: "Space between two cards, px.",
            val: 8, from: 2, to: 20, step: 1
        },
        {
            label: "card radius", prop: "cardRadius", group: "Cards",
            tip: "Corner radius of a card. 10 is the compact radius: a card in a list is smaller than the popup (14).",
            val: 10, from: 4, to: 20, step: 1
        },
        {
            label: "open / unfold ms", prop: "openMs", group: "Cards",
            tip: "How long a card takes to open and its package list to unfold. 260 is the shell's resize time.",
            val: 260, from: 0, to: 600, step: 10
        },
        {
            label: "scroll fade", prop: "fadeHeight", group: "Cards",
            tip: "Height of the fade where the list runs under the page's top and foot, px.",
            val: 16, from: 0, to: 40, step: 1
        }
    ]
}
