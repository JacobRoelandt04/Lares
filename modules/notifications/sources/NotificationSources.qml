pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "../../common/components"
import "SourceSettings.js" as Settings

// =============================================================================
// NotificationSources.qml -- the shell's own notification sources, ONE host.
//
// Every module that has something to say to the user -- the system update, the
// battery, the stocks, a screenshot, a USB drive, the calendar, the disk, a failed
// service, the CPU's heat -- says it through a SOURCE in this directory: an Item
// that listens to that module's service and posts through the notification service
// (SOURCES.md; CONTRACT.md section D). The shell builds this host once, beside the
// NotificationService, and hands it what each source needs; a service that is null
// switches its source off, never a source that builds one of its own (CONTRACT section
// 4). The modules know nothing of it: a hook line where one had nothing to hook.
//
//   live         the shell is live (the desktop's, not a mock or a mockup). NOTHING here
//                runs while it is false -- no source is active, no process is started,
//                no post is made. The default is false: a host that forgets cannot reach
//                the machine (CONTRACT section 4).
//   service      the NotificationService: where the settings come from (its `config.sources`,
//                notifications.jsonc hot) and, through NotificationBus, where every post goes
//   updates, battery, stocks, calendar, osd
//                the services (SystemUpdateService, SiliconBatteryAdapter, StocksService,
//                CalendarService, OsdService); null = that source is off
//   ownerOf      function (ownerKey) -> the focused screen's owner of that key, or null: how a
//                card's "Open" reaches a popup ("update", "silicon", "stocks")
//   runner       the shell's CommandRunner (live runs it, a mock only records): the commands a
//                CLICK asks for. null = a process of the host's own
//
// A source is `active` when the host is live, `sources.<id>.enabled` is not false, its service
// is there, and `only` (empty in the shell) lets it run. Its settings are SourceSettings' (the defaults of the table, notifications.jsonc over
// them, a bad value named in the log and left at the default). The shared pieces: `clock` (one
// BoundaryClock, so every wall-time deadline of every source follows a suspend), `state` (what the
// sources remember between runs, sources.json), `exec` (a program that must be heard back from),
// `open(key)`, `run(argv)`.
// =============================================================================
Item {
    id: hub
    visible: false

    // ---- what the shell hands in --------------------------------------------------
    property bool live: false
    property var service: null
    property var updates: null
    property var battery: null
    property var stocks: null
    property var calendar: null
    property var osd: null
    property var ownerOf: null
    property var runner: null
    // When the list is not empty ONLY these sources may run (a probe or a mockup of one source). The shell leaves it empty.
    property var only: []
    function allows(id) {
        return hub.only.length === 0 || hub.only.indexOf(id) >= 0;
    }
    // sources.json lives here; false keeps it in memory (a probe's clean start).
    property bool persist: true
    property string stateDir:
        (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/lares/notifications"
    // Read-only facts of the machine, overridable for a probe.
    property string uptimePath: "/proc/uptime"
    property string bootIdPath: "/proc/sys/kernel/random/boot_id"

    // ---- settings -------------------------------------------------------------------
    readonly property var _resolved: Settings.resolve(hub.service && hub.service.config ? hub.service.config.sources : null)
    readonly property var settings: hub._resolved.settings
    readonly property var problems: hub._resolved.problems
    function settingsOf(id) {
        return Settings.settingsOf(hub.settings, id);
    }
    // One warning per distinct set of problems, never per reload of the same file.
    property string _warned: ""
    on_ResolvedChanged: {
        const key = hub._resolved.problems.join("\n");
        if (key === hub._warned)
            return;
        hub._warned = key;
        for (let i = 0; i < hub._resolved.problems.length; i++)
            console.warn("notifications.jsonc: " + hub._resolved.problems[i]);
    }

    // ---- the sources ----------------------------------------------------------------
    // Registered by SourceBase as each is built.
    property var sources: []
    function register(src) {
        if (hub.sources.indexOf(src) < 0)
            hub.sources = hub.sources.concat([src]);
    }
    function unregister(src) {
        hub.sources = hub.sources.filter(s => s !== src);
    }
    function sourceOf(id) {
        for (let i = 0; i < hub.sources.length; i++)
            if (hub.sources[i].sourceId === id)
                return hub.sources[i];
        return null;
    }

    // ---- the sources, one per module that has something to say --------------------------
    UpdateNotifier {
        host: hub
        updates: hub.updates
    }
    BatteryNotifier {
        host: hub
        battery: hub.battery
    }
    StocksNotifier {
        host: hub
        stocks: hub.stocks
    }
    ScreenshotNotifier {
        host: hub
        osd: hub.osd
    }
    UsbNotifier {
        host: hub
    }
    CalendarNotifier {
        host: hub
        calendar: hub.calendar
    }
    DiskNotifier {
        host: hub
    }
    UnitsNotifier {
        host: hub
    }
    ThermalNotifier {
        host: hub
    }

    // ---- the shared pieces ------------------------------------------------------------
    readonly property alias clock: clockItem
    readonly property alias state: stateItem
    readonly property alias exec: execItem
    BoundaryClock {
        id: clockItem
        active: hub.live
    }
    SourcesState {
        id: stateItem
        persist: hub.persist
        statePath: hub.stateDir + "/sources.json"
    }
    SourceExec {
        id: execItem
    }

    // The popup of an owner on the focused screen (a card's "Open"). False: nobody to open it.
    function open(key) {
        const o = hub.ownerOf ? hub.ownerOf(key) : null;
        if (!o || typeof o.open !== "function")
            return false;
        o.open();
        return true;
    }

    // A program a click asked for, fire and forget: the shell's runner (which a mock only records),
    // else a process of the host's own.
    // `{ detached: true }` starts it in a session of its own, outliving a click's card and the shell (a file manager).
    function run(argv, opts) {
        if (!Array.isArray(argv) || argv.length === 0)
            return;
        const o = opts || {};
        if (hub.runner)
            hub.runner.run(argv, o);
        else if (o.detached === true)
            execItem.run(["setsid", "-f", "sh", "-c", "exec \"$@\" </dev/null >/dev/null 2>&1", "sh"].concat(argv), null, 60000);
        else
            execItem.run(argv, null, 60000);
    }

    // ---- the machine's facts -----------------------------------------------------------
    // The boot this shell runs in (a uuid; "" when unreadable) and how long the machine has been up.
    readonly property string bootId: hub._bootId
    property string _bootId: ""
    function uptimeMs() {
        uptimeFile.reload();
        const t = String(uptimeFile.text() || "").trim().split(/\s+/)[0];
        const s = parseFloat(t);
        return isFinite(s) && s >= 0 ? s * 1000 : -1;
    }
    FileView {
        id: bootIdFile
        path: hub.bootIdPath
        blockLoading: true
        printErrors: false
    }
    FileView {
        id: uptimeFile
        path: hub.uptimePath
        blockLoading: true
        blockAllReads: true
        printErrors: false
    }
    Component.onCompleted: hub._bootId = String(bootIdFile.text() || "").trim()
}
