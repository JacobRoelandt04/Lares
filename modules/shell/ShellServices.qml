// qmllint disable unused-imports
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "../common/components"
import "../common/glyphs"
import "../common/system"
import "../common/scroll"
import "../common/icons"
import "../common/config"
import "../common/flourish"
import "../common/config/ConfigSpecs.js" as Specs
import "ShellLayout.js" as Layout
import "../auth/data"
import "../auth"
import "../osd"
import "../osd/data"
import "../notifications/data"
import "../notifications/sources"
import "../aerial/data"
import "../silicon"
import "../silicon/data"
import "../clock/data"
import "../wiki"
import "../wiki/data"
import "../screentime"
import "../screentime/data"
import "../weather/data"
import "../stocks/data"
import "../launcher/data"
import "../clipboard/data"
import "../picker/data"
import "../bridge/data"
import "../notes"
import "../windowtray/data"
import "../bar/audio/data"
import "../audio/data"
import "../audio/airplay"
import "../bar/llm"
import "../bar/system_update"
import "../bar/system_update/snapshots"
import "../common/locale"
import "../idle"
import "../lockscreen"
import "../dictation"
import "../session"
import "../presets/data"
import "../panorama/data"
import "../bar/workspaces"
import "scale"
import "cursor"

// =============================================================================
// ShellServices.qml -- everything the shell has ONE of (CONTRACT section 3).
//
// A Scope, not an Item: the contract's id for the focused-screen source is `focus`, which an Item
// cannot be given as a property (Item.focus is final).
//
// The notification server, the polkit agent, the player, the battery reader,
// the weather, the stocks, the OSD's brain: each exists once however many screens
// there are, and each screen's owners are handed it. `mode` picks what they are:
//
//   live   the real service of every module (the desktop's)
//   mock   each module's own mock twin, every path under `mockHome`, every command
//          RECORDED (CommandRunner) and none run, no D-Bus name taken, no polkit
//          agent, no tray host, no sound, no notify-send -- what the probes, the
//          renders and mockups/shell.qml run on. Set by `SHELL_SERVICES=mock`.
//
// The ids are the contract's: notifications, notifyClock, auth, howdy, polkit, osd,
// osdStyle, pipewire, audio, airplay, mpd, aerial, silicon, siliconBattery, calendar,
// timers, wiki, screentime, weather, stocks, launcher, appLookup,
// clipboard, notes, llm, updates, tray, windowtrayConfig, focus, idle, dictation, bridge, panorama, drm, boost (null unless on) -- plus
// `commands` (the CommandRunner) and `power` (the reel's table, below).
//
// CROSS-SCREEN GLUE. Each screen's frame registers itself (`registerScreen`) with its
// owners by key. A service property the OWNERS would each write otherwise (`popupOpen`,
// `managerOpen`, `hostOpen`, `attended` ...) is written HERE, once, as the OR of every
// screen's owner `sharedFlags` -- two screens each writing it would be the last writer
// winning, a flag that flaps -- and a request that was unaddressed (the wiki's
// openRequested, a stock alert's click) goes to the FOCUSED screen's owner. Owner
// destruction recomputes both. The tables are `flagRows` and the Connections below.
//
// THE LOCK. ONE LockOwner (`lock`): the server end of the lock process's socket, and the popup it hangs from the clock's island on
// every screen while the session is locked. What `lock.locked` does to the rest of the shell: the notifications' `holds.locked` is
// written here (a toast is held, and the clipboard drops its sealed copies -- it follows the same holds), the frames bring their bars up
// whatever Super+F2 asked (`barsUp`), and every bar window takes no keyboard and no input (ShellScreen). `SHELL_LOCK=live|mock` picks
// the lock's socket: `live` is the real one (<runtime>/lares-lock/<display>.sock, the lock process's), `mock` a private one in the
// runtime dir, which no lock process knows -- a windowed mock shell on the desktop must never take over a real lock's socket. The
// default follows the services' mode; SHELL_LOCK=live with MOCK services is the real path in a nested compositor of its own (a test of
// the whole lock chain).
//
// WHAT IS NEVER HERE: a BatteryData. Its 1 Hz uevent read is an ACPI call into the
// embedded controller (CLAUDE.md, the EC law); the shell has ONE battery reader, silicon's,
// and what would read a BatteryData's members (the OSD's battery card, the lock) reads the adapter.
// `census` is for the probes: the type of every service this built.
//
// THE MODULES (shell.jsonc `modules`, ShellLayout.MODULES). A module that is switched off has no service: its Loader makes nothing (null, which every
// reader takes as "the feature is absent", CONTRACT section 4), and one that is no Loader's is not live. `moduleOn(id)` is the one question,
// answered from what the file said as the shell started (ShellConfig.modulesOff), so it never changes under a running shell.
// =============================================================================
Scope {
    id: services

    // ---- the mode ---------------------------------------------------------------------------------
    property string mode: Quickshell.env("SHELL_SERVICES") === "mock" ? "mock" : "live"
    readonly property bool mock: services.mode === "mock"
    readonly property bool live: !services.mock
    // No layer-shell window exists (mockups/shell.qml in a plain window, the in-process probes): the
    // pill windows, the global shortcuts and the other things that need a compositor stay off.
    property bool windowless: false
    // The shortcut layer (ShortcutRouter, OsdShortcuts) registers with the compositor.
    property bool shortcutsEnabled: !services.windowless

    // ---- the paths --------------------------------------------------------------------------------
    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (services.home + "/.local/state")
    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (services.home + "/.config")
    readonly property string cacheHome: Quickshell.env("XDG_CACHE_HOME") || (services.home + "/.cache")
    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
    // Where a mock keeps everything it would write.
    property string mockHome: services.stateHome + "/lares-shell-mock"
    // The config directory of the modules' json files: the desktop's, or the mock's.
    readonly property string configDir: services.mock ? services.mockHome + "/config" : services.configHome + "/quickshell"
    // Where the hand-edited <name>.jsonc files live (2026-11-12: config/ under the config dir; ConfigFile still reads one not moved
    // yet one level up). State the shell writes (favourites included) is under stateDir, never here. The mock's files are where they were.
    readonly property string configFilesDir: services.mock ? services.mockHome + "/config" : services.configDir + "/config"
    readonly property string stateDir: services.mock ? services.mockHome + "/state" : services.stateHome + "/lares"
    readonly property string cacheDir: services.mock ? services.mockHome + "/cache" : services.cacheHome + "/lares"
    readonly property string notesRoot: services.mock ? services.mockHome + "/notes" : atStart.notesRoot

    // A path of a hand-edited file: `~` is the home, a trailing slash is none.
    function homePath(p: string): string {
        const full = p === "~" || p.indexOf("~/") === 0 ? services.home + p.substring(1) : p;
        return full.length > 1 && full.endsWith("/") ? full.substring(0, full.length - 1) : full;
    }

    // What a file said AS THE SHELL STARTED, for the keys a running shell does not follow (their examples say so): a binding until the shell is
    // built, held from then on.
    QtObject {
        id: atStart
        property string notesRoot: services.homePath(notesConfigItem.settings.root)
        property string llmStore: llmConfigItem.settings.store
        property string llmUrl: llmConfigItem.settings.server.url
        property string llmProtocol: llmConfigItem.settings.server.protocol
        property int llmMax: llmConfigItem.settings.maxConversations
        Component.onCompleted: {
            for (const k of ["notesRoot", "llmStore", "llmUrl", "llmProtocol", "llmMax"])
                atStart[k] = atStart[k];
        }
    }

    // ---- the modules (THE MODULES, above) --------------------------------------------------------------
    function moduleOn(id: string): bool {
        return shellConfigItem.modulesOff[id] !== true;
    }

    // ---- ready ----------------------------------------------------------------------------------------
    // `servicesUp`: every service an owner is handed exists (each Loader has loaded its twin). `ready` is what THE FRAMES WAIT
    // FOR. A frame made before the Loaders have loaded hands every owner a null service, and a hosted owner (`shellHosted`)
    // builds none of its own (a mock run would start a real SiliconService, which calls pkexec): the feature is absent until the service
    // appears, popups that open nothing for a moment. A window should come up whole. The shell's windows and test_shell's frame are created from `ready`; registerScreen notes
    // whether the services were up at that moment (the probes read it: `registeredUp`).
    readonly property bool servicesUp: !!services.notifications && !!services.pipewire && services._up("player", services.mpd)
        && services._up("aerial", services.aerial) && services._up("silicon", services.silicon) && !!services.calendar
        && services._up("wiki", services.wiki) && services._up("screentime", services.screentime)
        && services._up("weather", services.weather) && services._up("stocks", services.stocks)
        && services._up("clipboard", services.clipboard) && !!services.tray
    // A module's service is there, or the module is switched off and none will come.
    function _up(id: string, item: var): bool {
        return !!item || !services.moduleOn(id);
    }
    readonly property bool ready: services.servicesUp
    property var registeredUp: ({})

    // ---- settled ----------------------------------------------------------------------------------------
    // The start has tails: every frame's warm-up (ShellFrame.prewarmDone), the launcher's catalogue, and the bake of its icons (a
    // child process; when it ends the atlas pages are read and decoded on the main thread, ~1 s of it). A gate that measures the
    // shell AT REST starts its window when this has said so -- ONE console line, `LARES settled
    // screens=<n>`, so an offscreen stage and the nested shell are read alike -- instead of after a number of seconds that is the
    // start's length on one machine and a cold shader cache and not on another: a window that lands inside these tails (or the silicon
    // mock's scripted wake) reads the idle frames and CPU as intermittent on the same code.
    property bool settled: false
    function _settleCheck(): bool {
        const names = Object.keys(services.frames);
        if (names.length === 0)
            return false;
        for (const n of names) {
            const f = services.frames[n];
            if (!f || typeof f.prewarmDone !== "function" || !f.prewarmDone())
                return false;
        }
        if (services.launcher && services.launcher.ready !== true)
            return false;
        return true;
    }
    // Five minutes of polling at most: a shell whose launcher never reports ready (no applications) stops
    // asking rather than wake twice a second for ever.
    property int _settlePolls: 0
    Timer {
        interval: 500
        repeat: true
        running: services.ready && !services.settled && services._settlePolls < 600
        onTriggered: {
            services._settlePolls++;
            if (!services._settleCheck())
                return;
            services.settled = true;
            console.log("LARES settled screens=" + Object.keys(services.frames).length);
        }
    }

    // ---- the screens ------------------------------------------------------------------------------
    // name -> frame. A frame has `owners`, a map owner key -> owner (CONTRACT section 2).
    property var frames: ({})
    property int serial: 0
    readonly property var screenNames: { void services.serial; return Object.keys(services.frames); }

    function registerScreen(name: string, frame: var): void {
        services.registeredUp[name] = services.servicesUp;
        const f = Object.assign({}, services.frames);
        f[name] = frame;
        services.frames = f;
        services.serial++;
        // A fake focus that has none yet takes the first screen (a mockup, an in-process probe: no compositor to ask).
        if (!focusItem.live && focusItem.name === "")
            focusItem.setFocused(name);
    }
    function unregisterScreen(name: string): void {
        if (services.frames[name] === undefined)
            return;
        const f = Object.assign({}, services.frames);
        delete f[name];
        services.frames = f;
        services.serial++;
    }
    function ownerOn(name: string, key: string): var {
        void services.serial;
        const fr = services.frames[name];
        return fr && fr.owners ? (fr.owners[key] ?? null) : null;
    }
    // The owner on the focused screen, else on the first live one.
    function focusedOwner(key: string): var {
        void services.serial;
        const fname = focusItem.name;
        const on = fname !== "" ? services.ownerOn(fname, key) : null;
        if (on)
            return on;
        const names = Object.keys(services.frames);
        for (let i = 0; i < names.length; i++) {
            const o = services.ownerOn(names[i], key);
            if (o)
                return o;
        }
        return null;
    }
    // The focused screen's frame has been presented (ShellScreen: on the glass, in one frame); false with no screen yet.
    readonly property bool focusedPresented: {
        void services.serial;
        const f = services.frames[services.focusedScreen];
        return !!f && f.presented === true;
    }
    // The screen the focused owner belongs to ("" none).
    readonly property string focusedScreen: {
        void services.serial;
        const fname = focusItem.name;
        if (fname !== "" && services.frames[fname] !== undefined)
            return fname;
        const names = Object.keys(services.frames);
        return names.length > 0 ? names[0] : "";
    }

    // ---- the aggregation (CONTRACT section 3) -----------------------------------------------------
    // service property <- OR of owner key . sharedFlags flag over every screen.
    readonly property var flagRows: [
        { id: "wikiPopupOpen", owner: "clock", flag: "wikiPopupOpen" },
        { id: "timersAttended", owner: "clock", flag: "timersAttended" },
        { id: "stocksPopupOpen", owner: "stocks", flag: "popupOpen" },
        { id: "siliconPopupOpen", owner: "silicon", flag: "popupOpen" },
        { id: "managerOpen", owner: "notifications", flag: "managerOpen" },
        { id: "aerialPopupOpen", owner: "aerial", flag: "aerialPopupOpen" },
        { id: "aerialRatesWatch", owner: "aerial", flag: "aerialRatesWatch" },
        { id: "clipboardHostOpen", owner: "clipboard", flag: "hostOpen" },
        { id: "pickerHostOpen", owner: "picker", flag: "hostOpen" },
        { id: "bridgePopupOpen", owner: "bridge", flag: "popupOpen" },
        { id: "panoramaPopupOpen", owner: "panorama", flag: "popupOpen" },
        { id: "weatherPopupOpen", owner: "weather", flag: "popupOpen" },
        { id: "playerPopupOpen", owner: "player", flag: "popupOpen" },
        { id: "audioPopupOpen", owner: "audio", flag: "popupOpen" },
        { id: "updatesPopupOpen", owner: "update", flag: "popupOpen" },
        { id: "llmAttended", owner: "llm", flag: "attended" }
    ]
    // { id: bool }: recomputed when a screen comes or goes and when any owner's sharedFlags changes
    // (each owner's `sharedFlags` is a binding that makes a new object, which this binding reads).
    readonly property var flags: {
        void services.serial;
        const out = {};
        for (const row of services.flagRows) {
            let v = false;
            for (const name in services.frames) {
                const o = services.frames[name] && services.frames[name].owners ? services.frames[name].owners[row.owner] : null;
                const sf = o ? o.sharedFlags : null;
                if (sf && sf[row.flag] === true)
                    v = true;
            }
            out[row.id] = v;
        }
        return out;
    }

    // ---- the services -----------------------------------------------------------------------------
    // Every one is a plain `readonly property var` so that a mock and a live twin answer to one name.

    // The recorder of everything the shell would run.
    readonly property alias commands: cmdRunner
    CommandRunner {
        id: cmdRunner
        live: services.live
    }

    // -- notifications (the name org.freedesktop.Notifications; in a mock, in-process only) --
    readonly property var notifications: notificationsLoader.item
    // The server holds the name (live), or there is none to hold (a mock): what the ready line waits for.
    readonly property bool notificationsUp: services.mock ? !!services.notifications : (!!services.notifications && services.notifications.serverRunning === true)
    Loader {
        id: notificationsLoader
        sourceComponent: services.mock ? notificationsMock : notificationsLive
    }
    Component {
        id: notificationsLive
        NotificationService {
            focusSource: focusItem
        }
    }
    Component {
        id: notificationsMock
        NotificationService {
            // No D-Bus name, no compositor signals, no files of the desktop's; the bus is in process,
            // so every DesktopNotifier posts here and none reaches notify-send.
            serverEnabled: false
            liveSignals: false
            persist: false
            ipcEnabled: false
            focusSource: focusItem
            configPath: services.configFilesDir + "/notifications.jsonc"
            statePath: services.stateDir + "/notifications/state.json"
            historyPath: services.stateDir + "/notifications/history.json"
        }
    }
    // -- the screen share: ONE watcher (a portal cast session or a recorder's process), read by the toasts' holds and the idle auto layer --
    readonly property alias shareWatch: shareWatchItem
    ScreenShareWatch {
        id: shareWatchItem
        liveSignals: services.live
        livePipewire: services.live
        recorders: shellConfigItem.recordersText.split(" ").filter(n => n !== "")
    }
    Binding {
        target: services.notifications ? services.notifications.holds : null
        property: "share"
        value: shareWatchItem
    }
    // -- the download folder: ONE inotify watcher (DownloadWatch), read by the idle auto layer --
    readonly property alias downloadWatch: downloadWatchItem
    DownloadWatch {
        id: downloadWatchItem
        watch: services.live && services.moduleOn("idle")
        // idle.jsonc `download`: how long a download grows before it counts, and the folder ("" = xdg-user-dir DOWNLOAD)
        minAgeMs: Math.round(idleService.checked.download.minMinutes * 60000)
        dir: idleService.checked.download.folder.replace(/^~(?=\/|$)/, Quickshell.env("HOME") || "~")
    }
    // -- package jobs: ONE scanner (PackageJobWatch), read by the idle auto layer. The shell's own update is told by its supervisor's pid --
    readonly property alias packageJobs: packageJobWatch
    PackageJobWatch {
        id: packageJobWatch
        watch: services.live && services.moduleOn("idle")
        ownRun: updatesService.runActive
        minAgeMs: Math.round(idleService.checked.packages.minMinutes * 60000)
        ownPid: Number((updatesService.backend && updatesService.backend.attachPid) || 0)
    }
    // No sound in a mock.
    Binding {
        target: services.mock && services.notifications ? services.notifications.sound : null
        property: "pwPlay"
        value: "true"
    }
    // The shell's own notification sources (system update, battery, stocks sudden moves, screenshot, USB, calendar,
    // disk, failed units, thermal): ONE host on the service above, each source switched on by notifications.jsonc and by
    // the service it listens to being here (a null one is that source off). Inert unless the shell is live.
    NotificationSources {
        id: notificationSources
        live: services.live
        persist: services.live
        service: services.notifications
        updates: services.moduleOn("update") ? updatesService : null
        battery: batteryAdapter
        stocks: services.stocks
        calendar: services.calendar
        osd: osdService
        runner: services.commands
        ownerOf: key => services.focusedOwner(key)
        stateDir: services.stateDir + "/notifications"
    }
    // ONE clock for every relative time the notification surfaces show; it runs while one is on screen.
    readonly property alias notifyClock: notifyClockItem
    BoundaryClock {
        id: notifyClockItem
        active: services._notificationsVisible
    }
    readonly property bool _notificationsVisible: {
        void services.serial;
        for (const name in services.frames) {
            const o = services.ownerOn(name, "notifications");
            if (o && (o.popupMine === true || o.laneMine === true))
                return true;
        }
        return false;
    }

    // -- auth: the broker, howdy's config, the polkit agent, the one owner --
    readonly property alias auth: authBroker
    AuthBroker {
        id: authBroker
        registerOnBus: true
    }
    readonly property alias howdy: howdyConfig
    HowdyConfig {
        id: howdyConfig
        path: services.mock ? services.mockHome + "/howdy.ini" : "/etc/howdy/config.ini"
    }
    QtObject {
        id: fakePolkitAgent
        property var flow: null
    }
    readonly property alias polkit: polkitSource
    PolkitSource {
        id: polkitSource
        broker: authBroker
        enabled: services.live
        fakeAgent: services.mock ? fakePolkitAgent : null
        howdyMode: howdyConfig.mode
        faceTimeoutMs: howdyConfig.timeoutMs
    }
    readonly property alias authOwner: authOwnerItem
    AuthOwner {
        id: authOwnerItem
        broker: authBroker
        service: services.notifications
        // `fullscreen` and the pill's screen are read from the shell's ONE FocusedScreen
        focusSource: focusItem
        sharing: !!services.notifications && services.notifications.holdReason === "screencast"
        // A host with no layer-shell window shows the pill nowhere.
        pillSource: services.windowless ? "" : Qt.resolvedUrl("../auth/AuthPillWindow.qml")
    }
    // polkitd allows ONE agent per session; if ours is not registered 5 s after the start (polkit-gnome
    // still holds it, or the bus refused), the desktop would have NO agent: start polkit-gnome as
    // Hyprland's child, as the autostart did. Live only; a mock records the call and runs nothing.
    // `LARES polkit registered=<bool>` is said ONCE, when it settles: at the registration, or after the
    // fallback's wait when there never was one (nothing outside the shell can see the agent).
    readonly property string polkitFallbackPath: "/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1"
    property bool polkitFallbackStarted: false
    property bool polkitSettled: false
    property int polkitFallbackMs: 5000
    // A probe turns this on to see the fallback decide in a mock (the call is recorded, never run).
    property bool polkitFallbackProbe: false
    function _polkitSettle(registered: bool): void {
        if (services.polkitSettled)
            return;
        services.polkitSettled = true;
        console.log("LARES polkit registered=" + registered);
    }
    Connections {
        target: polkitSource
        function onRegisteredChanged() {
            if (polkitSource.registered)
                services._polkitSettle(true);
        }
    }
    Timer {
        id: polkitWatch
        interval: services.polkitFallbackMs
        running: true
        onTriggered: {
            if (polkitSource.registered) {
                services._polkitSettle(true);
                return;
            }
            if ((services.live || services.polkitFallbackProbe) && !services.polkitFallbackStarted) {
                services.polkitFallbackStarted = true;
                cmdRunner.run(["hyprctl", "dispatch", "hl.dsp.exec_cmd(\"" + services.polkitFallbackPath + "\")"]);
            }
            services._polkitSettle(false);
        }
    }
    // A probe turns the fake agent off and asks the watch to look again.
    function rearmPolkitWatch(): void {
        services.polkitSettled = false;
        polkitWatch.restart();
    }
    // The OSD's sources have nothing to read in a mock (their `live` is false: no Pipewire, no sysfs): give them the
    // machine mockups/osd.qml gives them, so the volume halves and the keys have a value to change and a card to show.
    function _seedMock(): void {
        const src = osdService.sources;
        src.audio.simulateReady(0.42, false, "Speakers", "speaker", 0.8, false);
        src.backlight.simulateSet(220, 400);
        src.kbd.simulateSet(1, 3);
        src.lockKeys.simulateKeys(false, false);
    }
    Component.onCompleted: {
        if (polkitSource.registered)
            services._polkitSettle(true);
        if (services.mock)
            services._seedMock();
    }

    // -- the OSD --
    readonly property alias osdStyle: osdStyleItem
    OsdStyle {
        id: osdStyleItem
        // osd.jsonc lockkeys.keys: the keys the lock keys card draws (and is sized by)
        lockKeys: osdService._c.lockkeys.keys
    }
    readonly property alias osd: osdService
    // ONE, hosted: the five sources read the shell's own services (never an `ownBackend`: a second Pipewire / mpd / aerial /
    // battery reader per source); the battery is the SiliconBatteryAdapter, never a BatteryData.
    OsdService {
        id: osdService
        live: services.live
        shellHosted: true
        audioBackend: services.pipewire
        mpdBackend: services.mpd
        aerialBackend: services.aerial
        batteryBackend: batteryAdapter
        absent: (services.moduleOn("player") ? [] : ["mpd"]).concat(services.moduleOn("aerial") ? [] : ["aerial"])
        // the brightness keys act on the display under the pointer (hyprctl cursorpos over these rects, the focused screen when it does not
        // answer): an external display's own brightness over DDC, the laptop's backlight for the panel (Panorama)
        displayBackend: services.panorama
        focusedScreen: focusItem.name
        monitorRects: focusItem.outputs
    }
    // The last mute the OSD announced per kind (the probe reads it: a mock shell's OSD source is not live, so a mute made through it never reaches the mock
    // Pipewire, and the pill's click -- which mutes through the OSD -- is seen here).
    property var osdMutes: ({})
    Connections {
        target: osdService
        function onRequest(req) {
            if ((req.kind === "volume" || req.kind === "mic") && req.muteFlip === true) {
                const m = Object.assign({}, services.osdMutes);
                m[req.kind] = { muted: req.muted === true, n: (m[req.kind] ? m[req.kind].n : 0) + 1 };
                services.osdMutes = m;
            }
        }
    }
    OsdShortcuts {
        service: osdService
        enabled: services.shortcutsEnabled
    }
    OsdIpc {
        service: osdService
    }

    // -- audio, player --
    // The audio popup's one service: `pactl` behind deadlines, the read-back. At rest it runs nothing (AudioService).
    readonly property var audio: audioLoader.item
    Loader {
        id: audioLoader
        sourceComponent: !services.moduleOn("volume") ? null : services.mock ? audioMock : audioLive
    }
    Component {
        id: audioLive
        AudioService {
            live: true
            pipewire: services.pipewire
            hide: audioConfigItem.settings.hide
        }
    }
    Component {
        id: audioMock
        AudioMock {
            hide: audioConfigItem.settings.hide
        }
    }
    readonly property var pipewire: pipewireLoader.item
    Loader {
        id: pipewireLoader
        sourceComponent: services.mock ? pipewireMock : pipewireLive
    }
    Component {
        id: pipewireLive
        PipewireService {}
    }
    Component {
        id: pipewireMock
        PipewireMock {}
    }
    // -- AirPlay: ONE watcher (AirplayWatch): sound flowing into a RAOP sink, its latency, the Wi-Fi power save while it does.
    // Its `delayMs` is the shell's one AirplayDelay (what the OSD's track card, the bar glyph's flourish and the lyrics wait for). A mock
    // has the twin (no radio, no helper, nothing run).
    readonly property var airplay: airplayLoader.item
    Loader {
        id: airplayLoader
        sourceComponent: services.mock ? airplayMock : airplayLive
    }
    Component {
        id: airplayLive
        AirplayWatch {
            live: services.live
            configPath: services.configFilesDir + "/airplay.jsonc"
            stateFile: services.runtimeDir + "/lares/airplay-powersave.json"
        }
    }
    Component {
        id: airplayMock
        AirplayWatchMock {}
    }
    Binding {
        target: AirplayDelay
        property: "delayMs"
        value: services.airplay ? services.airplay.delayMs : 0
    }
    readonly property var mpd: mpdLoader.item
    Loader {
        id: mpdLoader
        sourceComponent: !services.moduleOn("player") ? null : services.mock ? mpdMock : mpdLive
    }
    // player.jsonc (the paths are read as the shell starts: JsonConfig keeps them) and shell.jsonc workarounds.mpdResumeSeek
    Component {
        id: mpdLive
        MpdService {
            musicDir: services.homePath(playerConfigItem.settings.paths.music)
            albumsSubdir: playerConfigItem.settings.paths.albums
            tracksSubdir: playerConfigItem.settings.paths.tracks
            playlistsSubdir: playerConfigItem.settings.paths.playlists
            favoritesName: playerConfigItem.settings.paths.favorites
            coverNames: playerConfigItem.settings.paths.covers
            socketPath: services.homePath(playerConfigItem.settings.paths.socket)
            prevRestartSec: playerConfigItem.settings.prevRestartSec
            shuffleArtistGap: playerConfigItem.settings.shuffle.artistGap
            shuffleAlbumGap: playerConfigItem.settings.shuffle.albumGap
            losslessResume: shellConfigItem.checked.workarounds.mpdResumeSeek
        }
    }
    Component {
        id: mpdMock
        PlayerMockRun {
            musicDir: services.homePath(playerConfigItem.settings.paths.music)
            albumsSubdir: playerConfigItem.settings.paths.albums
            tracksSubdir: playerConfigItem.settings.paths.tracks
            playlistsSubdir: playerConfigItem.settings.paths.playlists
            favoritesName: playerConfigItem.settings.paths.favorites
            prevRestartSec: playerConfigItem.settings.prevRestartSec
            shuffleArtistGap: playerConfigItem.settings.shuffle.artistGap
            shuffleAlbumGap: playerConfigItem.settings.shuffle.albumGap
        }
    }
    // SHELL_PLAYER=play (a mock only): the mock player starts PLAYING once its queue is filled -- the state of a
    // shell at rest with music (a playing player with no popup open must not wake a window; PlayerTickHold). Nothing else reads it.
    property bool _playerStarted: false
    Connections {
        target: services.mock ? services.mpd : null
        enabled: (Quickshell.env("SHELL_PLAYER") || "") === "play"
        function onQueueLengthChanged(): void {
            if (services.mpd.queueLength > 0 && !services.mpd.playing && !services._playerStarted) {
                services._playerStarted = true;
                services.mpd.play();
            }
        }
    }

    // -- aerial: the network (Wi-Fi, cable, hotspot, Bluetooth, the tunnel, the tests). ONE service: the helper, the machine's reads and the
    //    intents; a mock shell builds the mock twin (the same members), which touches nothing. --
    // Every failure is ONE toast through the shell's own notification service (never in the popup): the service holds the notifier, a repeat
    // replaces its toast by key, a cleared cause withdraws it. Null notifier = no toasts (mockups).
    DesktopNotifier {
        id: aerialNotifier
        appName: "Aerial"
        sourceId: "aerial"
        keys: ["spare"]
    }
    readonly property var aerial: aerialLoader.item
    Loader {
        id: aerialLoader
        sourceComponent: !services.moduleOn("aerial") ? null : services.mock ? aerialMock : aerialLive
    }
    Component {
        id: aerialLive
        AerialService {
            live: true
            notifier: aerialNotifier
        }
    }
    Component {
        id: aerialMock
        AerialMock {
            notifier: aerialNotifier
        }
    }

    // -- silicon: the machine (NEVER the real service outside a live shell: it calls pkexec) --
    readonly property var silicon: siliconLoader.item
    Loader {
        id: siliconLoader
        sourceComponent: !services.moduleOn("silicon") ? null : services.mock ? siliconMock : siliconLive
    }
    Component {
        id: siliconLive
        // the MUX restart is the reel's reboot: the session is saved first, so session restore reads a reboot, not a crash
        // the display connectors are the shell's ONE DrmWatch (Panorama reads them too): silicon builds none of its own
        SiliconService {
            rebootArgv: reelActionsItem.ownCommandOf("reboot")
            drm: drmWatch
        }
    }
    Component {
        id: siliconMock
        SiliconMock {}
    }

    // -- the interaction boost: ONE client of lares-boost.service (a root service, `lares setup` R6) that holds the Intel GPU's
    //    and the CPU's frequency floor up while a shell motion runs. `services.boost` is the client while silicon.jsonc
    //    "interactionBoost" is true and the shell is live, else null: a caller kicks it at a motion's start,
    //    `if (services.boost) services.boost.kick(ms)`. Off, the client holds no connection (the service puts the floors back
    //    when it closes). It is never the machine's in a mock shell. --
    readonly property var boost: boostClient.wanted ? boostClient : null
    BoostClient {
        id: boostClient
        wanted: services.live && !!services.silicon && !!services.silicon.config && services.silicon.config.interactionBoost === true
    }

    // -- the display connectors: ONE DrmWatch (modules/common/system/DrmWatch.qml) -- the kernel's connectors, a DisplayLink dock's
    //    traces, when each became connected. Silicon reads its NVIDIA HDMI fact, Panorama all of it. A mock shell reads nothing. --
    readonly property alias drm: drmWatch
    DrmWatch {
        id: drmWatch
        enabled: services.live
    }

    // -- the displays (Panorama): ONE service. Hyprland applies the setups itself (tools/panorama/engine.lua inside the generated
    //    ~/.config/hypr/config/panorama.lua); the service is the popup's and the glyph's view of it, the store, the trial and its keep
    //    toast. Until the user's one-time `lares panorama-import` the engine is missing and the popup is read-only. A mock shell runs
    //    PanoramaMock on SHELL_PANORAMA's scenario (PanoramaScenarios.js; "desk" when unset). --
    DesktopNotifier {
        id: panoramaNotifier
        appName: "Displays"
        sourceId: "panorama"
    }
    readonly property var panorama: panoramaLoader.item
    Loader {
        id: panoramaLoader
        // SHELL_PANORAMA=live in a mock shell: the live service on the compositor's outputs -- only inside tools/dev/lock_env.sh, where the
        // compositor, the XDG homes and the runtime dir are the env's own (the platform probe); refused anywhere else
        sourceComponent: !services.moduleOn("panorama") ? null : services.mock && !services._panoramaLiveInEnv ? panoramaMock : panoramaLive
    }
    readonly property bool _panoramaLiveInEnv: Quickshell.env("SHELL_PANORAMA") === "live" && String(Quickshell.env("LOCK_ENV_DIR") || "") !== ""
    Component {
        id: panoramaLive
        PanoramaService {
            live: true
            focusSource: focusItem
            drm: drmWatch
            silicon: services.silicon
            notifier: panoramaNotifier
            configPath: services.configFilesDir + "/panorama.jsonc"
            engineSource: RepoRoot.dir + "/tools/panorama/engine.lua"
            // the keep toast waits for the user to see it: not under the lock, not before the focused screen's frame is on the glass
            ready: !lockOwner.locked && services.focusedPresented
        }
    }
    Component {
        id: panoramaMock
        PanoramaMock {
            scenario: Quickshell.env("SHELL_PANORAMA") && Quickshell.env("SHELL_PANORAMA") !== "live" ? Quickshell.env("SHELL_PANORAMA") : "desk"
        }
    }
    // The never-seen toast's "Arrange…": the popup opens on the focused screen with that display's tile selected.
    // the popup's slider for the laptop panel goes through the OSD service (it owns the backlight: PanelBacklight's rule, never 0)
    Binding {
        target: services.panorama
        property: "panel"
        value: osdService
        when: services.panorama !== null
    }
    // -- casting (Miracast through fluxcast): ONE cast service, handed to the displays service, which uses it only when panorama.jsonc
    //    says "cast": true (off by default). The mock twin under SHELL_SERVICES=mock: nothing reaches the machine --
    readonly property var cast: castLoader.item
    Loader {
        id: castLoader
        sourceComponent: !services.moduleOn("panorama") ? null : services.mock ? castMockC : castLiveC
    }
    Component {
        id: castLiveC
        CastService {
            live: true
        }
    }
    Component {
        id: castMockC
        CastMock {}
    }
    Binding {
        target: services.panorama
        property: "cast"
        value: services.cast
        when: services.panorama !== null && services.cast !== null
    }
    Connections {
        target: services.panorama
        function onOpenRequested(name: string) {
            const o = services.focusedOwner("panorama");
            if (o)
                o.openWith(name);
        }
    }

    // -- the local-model GPU: ONE helper, held by the wiki's batches and the LLM chat (modules/common/system/OllamaGpu). It asks
    //    silicon for Hybrid and puts the mode back when the last holder lets go; `live` runs its commands (nvidia-smi, journalctl,
    //    systemctl restart ollama, /api/ps), a mock shell only simulates the waits. --
    readonly property alias ollamaGpu: ollamaGpuItem
    OllamaGpu {
        id: ollamaGpuItem
        silicon: services.silicon
        live: services.live
        // THE SHELL'S ONE OLLAMA ADDRESS (the card, and the service to restart, are this machine's): the chat's server while the chat
        // runs here, else the wiki's (wiki.jsonc ollamaUrl), the other one who asks for the card; the chat's own server stays its own
        ollamaUrl: services.moduleOn("llm") && !llmBundle.remote ? llmBundle.serverUrl
            : services.wiki && services.wiki.config ? services.wiki.config.ollamaUrl : "http://localhost:11434"
    }
    // The shell's one battery reader is silicon's. What reads a BatteryData's members (the OSD's battery card, the lock's
    // info band) is handed this instead: no sysfs read of its own.
    readonly property alias siliconBattery: batteryAdapter
    SiliconBatteryAdapter {
        id: batteryAdapter
        silicon: services.silicon
    }
    // The MUX's moments that come without the popup (the keep prompt at login is one toast); Smart's blocked apps are
    // told once.
    SiliconMuxWatcher {
        id: muxWatcher
        vm: services.silicon
        // the keep prompt waits for the user to see it: not under the boot lock, not before the focused screen's frame is on the glass
        locked: lockOwner.locked
        shown: services.focusedPresented
    }
    BlockedAppNotifier {
        vm: services.silicon
    }

    // -- the clock's: calendar, timers, wiki, screentime --
    CalendarConfig {
        id: calendarConfig
    }
    readonly property var calendar: calendarLoader.item
    Loader {
        id: calendarLoader
        sourceComponent: services.mock ? calendarMock : calendarLive
    }
    Component {
        id: calendarLive
        CalendarService {
            config: calendarConfig
        }
    }
    Component {
        id: calendarMock
        MockCalendarData {}
    }
    DesktopNotifier {
        id: timersNotifier
        // appName "Clock" and its four keys are the notifier's defaults: the timers' own.
    }
    SoundPlayer {
        id: timersSound
        pwPlay: services.mock ? "true" : "pw-play"
    }
    readonly property alias timers: timersService
    TimerService {
        id: timersService
        persist: services.live
        stateDir: services.mock ? services.mockHome + "/state" : services.stateHome
        notifier: timersNotifier
        sound: timersSound
        // clock.jsonc timers (the lengths are read as the shell starts: JsonConfig keeps them)
        snoozeMs: Math.round(clockConfigItem.settings.timers.snoozeMin * 60000)
        sounds: clockConfigItem.settings.timers.sounds
        volume: clockConfigItem.settings.timers.volume
        ringMaxMs: clockConfigItem.settings.timers.ringSec * 1000
        soundUnderDnd: clockConfigItem.settings.timers.soundUnderDnd
        dnd: !!services.notifications && services.notifications.dnd === true
        missedWindowMs: Math.round(clockConfigItem.settings.timers.missedHours * 3600000)
        defaultCountdownMs: Math.round(clockConfigItem.settings.timers.countdownMin * 60000)
        defaultFocusMs: Math.round(clockConfigItem.settings.timers.focusMin * 60000)
        defaultShortMs: Math.round(clockConfigItem.settings.timers.shortMin * 60000)
        defaultLongMs: Math.round(clockConfigItem.settings.timers.longMin * 60000)
    }
    DesktopNotifier {
        id: wikiNotifier
        appName: "Wiki"
        keys: services.wiki && services.wiki.notifyKeys ? services.wiki.notifyKeys : []
    }
    readonly property var wiki: wikiLoader.item
    Loader {
        id: wikiLoader
        sourceComponent: !services.moduleOn("wiki") ? null : services.mock ? wikiMock : wikiLive
    }
    Component {
        id: wikiLive
        WikiService {
            notifier: wikiNotifier
            // The GPU for a batch is silicon's to give (Hybrid and back): through the shell's one OllamaGpu.
            sharedGpu: services.ollamaGpu
        }
    }
    Component {
        id: wikiMock
        WikiMock {
            scenario: "normal"
            dryRun: true
        }
    }
    readonly property var screentime: screentimeLoader.item
    Loader {
        id: screentimeLoader
        sourceComponent: !services.moduleOn("screentime") ? null : services.mock ? screentimeMock : screentimeLive
    }
    Component {
        id: screentimeLive
        ScreentimeService {}
    }
    Component {
        id: screentimeMock
        ScreentimeMock {}
    }

    // -- weather, stocks --
    readonly property var weather: weatherLoader.item
    Loader {
        id: weatherLoader
        sourceComponent: !services.moduleOn("weather") ? null : services.mock ? weatherMock : weatherLive
    }
    // The once-per-session notice of the live location ("weather-location"): the service tells it through this notifier (a mock has none).
    DesktopNotifier {
        id: weatherNotifier
        appName: "Weather"
        keys: ["weather-location"]
    }
    Component {
        id: weatherLive
        WeatherService {
            notifier: weatherNotifier
        }
    }
    Component {
        id: weatherMock
        WeatherMock {}
    }
    // TEMPORARY: the weather icon set on trial (weather.jsonc `glyphSet`), written here and nowhere else in the shell.
    Binding {
        target: WeatherGlyphSet
        property: "set"
        value: services.weather && services.weather.config && services.weather.config.glyphSet === "carved" ? "carved" : "ink"
    }
    DesktopNotifier {
        id: stocksNotifier
        appName: "Stocks"
        keys: services.stocks && services.stocks.alertKeys ? services.stocks.alertKeys : []
    }
    // The day-on-a-chart body of a stocks alert card (the notifier carries it to the shell's service).
    Component {
        id: stockMoveBody
        StockMoveBody {}
    }
    readonly property var stocks: stocksLoader.item
    Loader {
        id: stocksLoader
        sourceComponent: !services.moduleOn("stocks") ? null : services.mock ? stocksMock : stocksLive
    }
    Component {
        id: stocksLive
        StocksService {
            notifier: stocksNotifier
            alertBody: stockMoveBody
        }
    }
    Component {
        id: stocksMock
        StocksMock {
            notifier: stocksNotifier
            alertBody: stockMoveBody
            // SHELL_STOCKS=market-closed: the weekend face of the bar button (renders and probes; the mock's own scenarios)
            scenario: Quickshell.env("SHELL_STOCKS") || "market-open"
        }
    }

    // -- the launcher's service and the icons the bar shares --
    DesktopNotifier {
        id: launcherNotifier
        appName: "Launcher"
        keys: launcherService.notifyKeys
    }
    readonly property alias launcher: launcherService
    LauncherService {
        id: launcherService
        notifier: launcherNotifier
        configPath: services.configFilesDir + "/launcher.jsonc"
        favoritesPath: services.stateDir + "/launcher/favorites.json"
        favoritesLegacyPath: services.mock ? "" : services.configDir + "/launcher_favorites.json"
        statePath: services.stateDir + "/launcher/state.json"
        terminalCommand: shellConfigItem.terminal
        dryRun: services.mock
    }
    readonly property alias appLookup: appLookupItem
    AppLookup {
        id: appLookupItem
    }

    // -- the clipboard --
    readonly property var clipboard: clipboardLoader.item
    Loader {
        id: clipboardLoader
        sourceComponent: !services.moduleOn("clipboard") ? null : services.mock ? clipboardMock : clipboardLive
    }
    Component {
        id: clipboardLive
        ClipboardService {}
    }
    Component {
        id: clipboardMock
        ClipboardMock {}
    }

    // -- the emoji / symbol picker: its data, its memory, and the paste through the clipboard service above --
    // `forwardHostOpen: false`: the picker's popup being open is part of the OR the clipboard service is written ONCE with (below).
    // Not live (the mock shell): nothing is pasted and the memory stays in RAM.
    readonly property var picker: pickerLoader.item
    Loader {
        id: pickerLoader
        sourceComponent: services.moduleOn("picker") ? pickerService : null
    }
    Component {
        id: pickerService
        PickerService {
            live: services.live
            clipboard: services.clipboard
            forwardHostOpen: false
            copyOnly: pickerConfigItem.settings.pick === "copy"
        }
    }

    // -- the bridge to a phone (KDE Connect, adb, scrcpy, MTP): ONE service -- its tool's watcher, its one-shots, its toasts --
    // Not live (the mock shell) no process exists at all: SHELL_BRIDGE picks the mock's state (BridgeScenarios.js: none, pairing,
    // asleep, wifi, wired, mirroring, mounted, transfer, error; "wired" when unset).
    DesktopNotifier {
        id: bridgeNotifier
        appName: "Bridge"
        sourceId: "bridge"
    }
    readonly property var bridge: bridgeLoader.item
    Loader {
        id: bridgeLoader
        sourceComponent: services.moduleOn("bridge") ? bridgeService : null
    }
    Component {
        id: bridgeService
        BridgeService {
            live: services.live
            scenario: services.live ? "" : (Quickshell.env("SHELL_BRIDGE") || "wired")
            configPath: services.configFilesDir + "/bridge.jsonc"
            notifier: bridgeNotifier
            runner: cmdRunner
            clipboard: services.clipboard
        }
    }

    // -- notes: the store once (its root, its session) --
    readonly property alias notes: notesStore
    NotesStore {
        id: notesStore
        root: services.notesRoot
        newName: notesConfigItem.settings.newName
        statePath: services.stateDir + "/notes/session.json"
        defaultBrowseSize: ({ w: 560, h: 440, shift: 0 })
        defaultNoteSize: ({ w: 420, h: 480, shift: 0 })
    }

    // -- the LLM's bundle (backend, store, tools, attention, service) --
    // ONE for the shell: every screen's LlmBarOwner shares it. Live, the store is llm.jsonc's `store` (default conversations.json in
    // <state>/llm/; the mockup keeps its own, mockup_conversations.json); a mock keeps a private one. `attended` is the OR over the screens of the owners'
    // sharedFlags: a chat nobody can see is not attended (the attention's "come back").
    readonly property alias llm: llmBundle
    LlmServices {
        id: llmBundle
        live: services.live && services.moduleOn("llm")
        storePath: services.mock ? services.mockHome + "/llm/conversations.json" : services.stateDir + "/llm/" + atStart.llmStore
        settings: llmConfigItem.settings
        baseUrl: atStart.llmUrl
        protocol: atStart.llmProtocol
        maxConversations: atStart.llmMax
        howdyMode: howdyConfig.mode
        howdyTimeoutMs: howdyConfig.timeoutMs
        attended: services.flags.llmAttended
        gpu: services.ollamaGpu
    }

    // -- the system update --
    readonly property alias updates: updatesService
    SystemUpdateService {
        id: updatesService
        live: services.live && services.moduleOn("update")
        autoStart: services.moduleOn("update")
        // A mock keeps every path it reads once at creation under its own home, and never serves the
        // desktop's askpass socket.
        stateDir: services.mock ? services.mockHome + "/state/system-update" : services.stateHome + "/lares/system-update"
        askpassPath: services.runtimeDir + "/lares-askpass-update" + (services.mock ? "-mock" : "") + ".sock"
        logDir: services.mock ? services.mockHome + "/state/system-update-logs" : ""
        askpassRequireSudoParent: true
        mockSpec: ({ core: 9, extra: 180, multilib: 14, aur: 6, flatpak: 5 })
        snapshots: snapshotsItem
        configPath: services.configFilesDir + "/system_update.jsonc"
        favoritesLegacyPath: services.mock ? "" : services.configDir + "/system_update_favorites.json"
    }
    // -- the system snapshots (modules/bar/system_update/snapshots, docs/snapshots.md): the page beside the update popup, the Snapshot notch's rule, the
    //    copy off site. A mock (`live: false`) starts no process and serves fixtures. It follows the update run: no snapshot of ours and no copy while one is on.
    readonly property alias snapshots: snapshotsItem
    SnapshotService {
        id: snapshotsItem
        live: services.live && services.moduleOn("update")
        runActive: updatesService.running
        onBattery: batteryAdapter.isDischarging === true
        offsitePath: services.stateHome + "/lares/snapshots/offsite.json"
        configPath: services.configFilesDir + "/snapshots.jsonc"
    }

    // -- the window title's data: the tray, its config, the icons --
    readonly property alias windowtrayConfig: windowtrayConfigItem
    WindowTrayConfig {
        id: windowtrayConfigItem
        live: services.live
        configPath: services.configFilesDir + "/windowtray.jsonc"
    }
    readonly property var tray: trayLoader.item
    Loader {
        id: trayLoader
        sourceComponent: services.mock ? trayMock : trayLive
    }
    Component {
        id: trayLive
        TrayService {
            live: true
            config: windowtrayConfigItem.config
            appLookup: appLookupItem
        }
    }
    Component {
        id: trayMock
        TrayMock {
            config: windowtrayConfigItem.config
            appLookup: appLookupItem
        }
    }

    // -- which screen has the focus: FocusedScreen, ONE (CONTRACT section 6) --
    // Live it reads the compositor; a mock is its FAKE, which the shell feeds from the screens Quickshell has. SHELL_FOCUS=live
    // makes a mock's focus the compositor's too: the platform probe, in its own nested Hyprland, needs the focus to follow the
    // pointer between outputs (read-only: hyprctl -j and the event line).
    readonly property alias focus: focusItem
    FocusedScreen {
        id: focusItem
        live: services.live || Quickshell.env("SHELL_FOCUS") === "live"
        // shell.jsonc bars.outputs leaves a display out: the lane and the OSD go to one that has a window ([]: every display has one)
        shellScreens: JSON.parse(shellConfigItem.barsOutputsText) === "all" ? [] : services.barScreens.map(s => s.name)
    }
    // -- the keyboard of the open popups --
    // ESCAPE: while some screen has a popup open (`ShellFrame.escapeWanted`: ANY open popup, keyless ones and ones whose keys were let go
    // to a window too) the shell holds a runtime Hyprland bind on a bare Escape (EscapeBind)
    // that closes it; ShortcutRouter's "popup-escape" answers it with `escapePressed()`, which goes to the focused screen's popup first,
    // then to any other open one. A mock shell records the bind's Lua and runs nothing (SHELL_ESC=live runs it:
    // the nested-compositor probe). Not while the session is locked: the lock's popup is the lock's.
    readonly property bool escapeWanted: {
        void services.serial;
        if (lockOwner.locked)
            return false;
        for (const name in services.frames) {
            const f = services.frames[name];
            if (f && f.escapeWanted === true)
                return true;
        }
        return services.panoramaKeepWaiting;
    }
    // Panorama's keep toast is asking (Keep / Revert after an Apply): Escape reverts, once no popup took it (decision 7).
    readonly property bool panoramaKeepWaiting: !!services.panorama && !!services.panorama.keepPrompt && services.panorama.keepPrompt.waiting === true
    EscapeBind {
        id: escapeBindItem
        live: services.live || Quickshell.env("SHELL_ESC") === "live"
        wanted: services.escapeWanted
    }
    // Escape was pressed: true when a popup answered.
    property int escapePresses: 0
    function escapePressed(): bool {
        void services.serial;
        services.escapePresses += 1;
        const names = Object.keys(services.frames);
        const first = services.focusedScreen;
        if (first !== "" && names.indexOf(first) >= 0)
            names.splice(names.indexOf(first), 1);
        const order = first !== "" ? [first].concat(names) : names;
        for (const name of order) {
            const f = services.frames[name];
            if (f && f.escapeWanted === true && f.pressEscape())
                return true;
        }
        if (services.panoramaKeepWaiting) {
            services.panorama.keepPrompt.revert();
            return true;
        }
        return false;
    }
    // A window opened or took the focus on `screenName`: the popup there lets go of the keyboard (it stays open).
    // The window that opened gets the keys (KeyRelease: a release alone leaves the focus with the last window, or none).
    function releaseKeysOn(screenName: string, address: string, byFocus: bool): void {
        const f = services.frames[screenName];
        if (f && f.releaseKeys(byFocus) && address !== "")
            keyReleaseItem.focusWindow(address);
    }
    readonly property alias keyRelease: keyReleaseItem
    KeyRelease {
        id: keyReleaseItem
        live: focusItem.live
        focusSource: focusItem
        onReleased: (name, address, byFocus) => services.releaseKeysOn(name, address, byFocus)
    }
    // The pixel ratio of the shell's window on `sc` -- the PanelWindow's, which carries the real fractional one -- else the screen's,
    // which at a fractional Hyprland scale (1.25, 1.5) is the INTEGER wl_output scale.
    function _ratioOf(sc: var): real {
        const fr = services.frames[sc.name];
        const w = fr ? fr.window : null;
        return w && w.devicePixelRatio > 0 ? w.devicePixelRatio : sc.devicePixelRatio;
    }
    function _feedFocus(): void {
        if (focusItem.live)
            return;
        const list = [];
        for (const sc of Quickshell.screens)
            list.push({ name: sc.name, x: sc.x, y: sc.y, width: sc.width, height: sc.height, scale: services._ratioOf(sc) });
        if (list.length > 0)
            focusItem.setMonitors(list);
    }
    Connections {
        target: Quickshell
        function onScreensChanged() {
            services._feedFocus();
        }
    }

    // -- idle --
    readonly property alias idle: idleService
    IdleService {
        id: idleService
        live: services.live && services.moduleOn("idle")
        present: services.moduleOn("idle")
        // soft's laptop-panel rule follows the shell's one focus source; its timings are idle.jsonc's (IdleConfig.js)
        focusSource: focusItem
        config: idleConfigItem.raw
        configReady: idleConfigItem.applied
        // soft's steps are measured on the brightness keys' own curve (osd.jsonc's `brightness`: gamma, step, floorRaw)
        ladder: osdService.config && osdService.config.config ? osdService.config.config.brightness : undefined
        // the sleep fade waits for the lock's veil, and the lock going away skips its climb (modules/idle/sleep, docs/idle.md)
        lock: lockOwner
        // the external displays' own brightness (DDC), dimmed where there is no laptop panel
        displays: services.panorama
        stateDir: services.stateDir
    }
    // THE AUTO LAYER'S FACTS (IdleAuto; content is the service's own): work the user waits on asks for soft -- the LLM answering, a
    // timer counting (a countdown, a pomodoro phase, a stopwatch: paused ones ask nothing), a system update run, the player playing.
    Binding {
        target: idleService.auto
        property: "llm"
        value: !!services.llm && !!services.llm.service && services.llm.service.generating === true
    }
    readonly property string _timerRunning: {
        const t = timersService;
        return t.pomodoro && t.pomodoro.state === "running" ? "pomodoro" : t.countdown && t.countdown.state === "running" ? "timer"
            : t.stopwatch && t.stopwatch.state === "running" ? "stopwatch" : "";
    }
    Binding {
        target: idleService.auto
        property: "timer"
        value: services._timerRunning !== ""
    }
    Binding {
        target: idleService.auto
        property: "timerWhat"
        value: services._timerRunning
        when: services._timerRunning !== ""
        restoreMode: Binding.RestoreNone
    }
    Binding {
        target: idleService.auto
        property: "update"
        value: updatesService.runActive
    }
    Binding {
        target: idleService.auto
        property: "music"
        value: !!services.mpd && services.mpd.playing === true
    }
    // the screen is shared or recorded: others see it, so no dimming (normal); a wiki batch runs (also the GPU-automatic ones, and the wait for
    // the GPU before one); a file is being downloaded into the download folder (soft)
    Binding {
        target: idleService.auto
        property: "share"
        // a running cast is the screen being shared too (from the click to its end)
        value: shareWatchItem.active || (!!services.panorama && services.panorama.castActive === true)
    }
    Binding {
        target: idleService.auto
        property: "wiki"
        value: !!services.wiki && ((!!services.wiki.batch && services.wiki.batch.running === true) || services.wiki.batchPending === true)
    }
    Binding {
        target: idleService.auto
        property: "download"
        value: downloadWatchItem.active
    }
    Binding {
        target: idleService.auto
        property: "downloadWhat"
        value: downloadWatchItem.firstName
        when: downloadWatchItem.firstName !== ""
        restoreMode: Binding.RestoreNone
    }
    // a package job that is not the shell's own update (yay / pacman / an AUR build in a terminal), after it has run 2 minutes (soft)
    Binding {
        target: idleService.auto
        property: "pkg"
        value: packageJobWatch.active
    }
    Binding {
        target: idleService.auto
        property: "pkgWhat"
        value: packageJobWatch.what
        when: packageJobWatch.what !== ""
        restoreMode: Binding.RestoreNone
    }
    // files are being sent to a phone (the bridge's send job, over the cable): a suspend would cut the transfer (soft)
    Binding {
        target: idleService.auto
        property: "bridge"
        value: !!services.bridge && services.bridge.busy === true
    }
    Binding {
        target: idleService.auto
        property: "bridgeWhat"
        value: services.bridge && services.bridge.current ? services.bridge.current.name : ""
        when: !!services.bridge && services.bridge.busy === true && !!services.bridge.current
        restoreMode: Binding.RestoreNone
    }

    // -- the lock --
    readonly property string lockMode: {
        const e = Quickshell.env("SHELL_LOCK");
        return e === "live" || e === "mock" ? e : services.mode;
    }
    readonly property alias locale: localeConfig
    LocaleConfig {
        id: localeConfig
    }
    readonly property alias lock: lockOwner
    // A probe's stand-in for the session being locked, for the frames that follow it alone (the eye over the workspaces' clock): the shell.qml hook
    // `eye 1|0` sets it, in a MOCK shell only. Nothing real reads it but ShellFrame.eyeT.
    property bool eyeForce: false
    // ... and the eye's clock itself, held by hand (a film steps it a few hundredths at a time: -1, the default, is the animated one)
    property real eyeSet: -1
    LockOwner {
        id: lockOwner
        // the popup's inputs: the shell's own services (the battery is silicon's adapter, never a BatteryData); each may be null
        battery: batteryAdapter
        weather: services.weather
        updates: services.moduleOn("update") ? updatesService.avail : null
        screentime: services.screentime
        mpd: services.mpd
        // wiki.jsonc show.lock
        wikiService: services.wiki && (!services.wiki.config || services.wiki.config.show.lock) ? services.wiki : null
        locale: localeConfig
        // a mock names nobody (no `getent` for the account's name)
        greetingName: services.mock ? "Mock" : lockscreenConfigItem.settings.greetingName
        bandOrder: lockscreenConfigItem.settings.popupBand
        footOrder: lockscreenConfigItem.settings.popupFoot
        greets: lockscreenConfigItem.settings.greeting
        lockedControls: lockscreenConfigItem.settings.lockedControls
        // a MOCK shell listens nowhere (SHELL_LOCK=live: a mock shell on the real path, in a private nested env)
        listen: services.lockMode === "live"
    }

    // -- the shell's own: its settings, the bars toggle, and what the left island's small modules do --
    readonly property alias shellConfig: shellConfigItem
    ShellConfig {
        id: shellConfigItem
        live: true
        configPath: services.configFilesDir + "/shell.jsonc"
    }
    // idle.jsonc (soft idle, the lid, the sleep fade: IdleService) and llm.jsonc (LlmConfig), read hot like shell.jsonc.
    readonly property alias idleConfig: idleConfigItem
    IdleConfig {
        id: idleConfigItem
        live: true
        configPath: services.configFilesDir + "/idle.jsonc"
    }
    readonly property alias llmConfig: llmConfigItem
    LlmConfig {
        id: llmConfigItem
        live: true
        configPath: services.configFilesDir + "/llm.jsonc"
    }
    // The modules' own files, read through their specs (modules/common/config/JsonConfig: `settings` has every key, right from the first turn).
    readonly property alias powerConfig: powerConfigItem
    JsonConfig { id: powerConfigItem; name: "power"; spec: Specs.specOf("power"); configPath: services.configFilesDir + "/power.jsonc" }
    readonly property alias workspacesConfig: workspacesConfigItem
    JsonConfig { id: workspacesConfigItem; name: "workspaces"; spec: Specs.specOf("workspaces"); configPath: services.configFilesDir + "/workspaces.jsonc" }
    readonly property alias clockConfig: clockConfigItem
    JsonConfig { id: clockConfigItem; name: "clock"; spec: Specs.specOf("clock"); configPath: services.configFilesDir + "/clock.jsonc" }
    readonly property alias playerConfig: playerConfigItem
    JsonConfig { id: playerConfigItem; name: "player"; spec: Specs.specOf("player"); configPath: services.configFilesDir + "/player.jsonc" }
    readonly property alias audioConfig: audioConfigItem
    JsonConfig { id: audioConfigItem; name: "audio"; spec: Specs.specOf("audio"); configPath: services.configFilesDir + "/audio.jsonc" }
    readonly property alias notesConfig: notesConfigItem
    JsonConfig { id: notesConfigItem; name: "notes"; spec: Specs.specOf("notes"); configPath: services.configFilesDir + "/notes.jsonc" }
    // (the lock process reads lockscreen.jsonc by itself, LockConfig: what is the shell's popup's in it is read here)
    readonly property alias lockscreenConfig: lockscreenConfigItem
    JsonConfig { id: lockscreenConfigItem; name: "lockscreen"; spec: Specs.specOf("lockscreen"); configPath: services.configFilesDir + "/lockscreen.jsonc" }
    readonly property alias pickerConfig: pickerConfigItem
    JsonConfig { id: pickerConfigItem; name: "picker"; spec: Specs.specOf("picker"); configPath: services.configFilesDir + "/picker.jsonc" }
    // A MISTAKE IN ANY OF THE HAND-EDITED FILES IS SAID: one toast per file, with the line, the key and why, gone when the file is right
    // (modules/common/config; `lares config` checks them all). Aerial and the locale read through the snapshot's link to config/, so that path
    // counts too; screentime.jsonc (the daemon's) has no loader in the shell.
    readonly property alias configWatch: configWatchItem
    DesktopNotifier {
        id: configNotifier
        appName: "Config"
        keys: ["spare"]
    }
    ConfigWatch {
        id: configWatchItem
        live: services.live
        dirs: [services.configFilesDir + "/", RepoRoot.dir + "/config/"]
        notifier: configNotifier
        extra: ["screentime"]
    }
    // The file's `icons` block (overrides, fallback), to the shell's one AppIcons.
    Binding {
        target: AppIcons
        property: "config"
        value: shellConfigItem.raw
    }
    // The file's `scale` block, to the shell's one ShellScale (hot, like the rest of the file: see ScaleConfig.js).
    Binding {
        target: ShellScale
        property: "source"
        value: shellConfigItem.raw
    }
    // The file's `flourishes` (played by a hover, by a key), to the shell's one FlourishRegistry.
    Binding {
        target: FlourishRegistry
        property: "hoverPlays"
        value: shellConfigItem.flourishHover
    }
    Binding {
        target: FlourishRegistry
        property: "keyPlays"
        value: shellConfigItem.flourishKey
    }
    // The file's `hoverCursor`, to the shell's one ShellCursor (every window's CursorCover reads it).
    Binding {
        target: ShellCursor
        property: "hover"
        value: shellConfigItem.hoverCursor
    }
    // THE DISPLAYS THAT GET THE BARS (shell.jsonc bars.outputs): the screens shell.qml makes a window for.
    readonly property var barScreens: {
        const all = Quickshell.screens.filter(s => s.name !== "LARESLOCK-HOP");     // the lock's own few-hundred-ms headless output
        const names = Layout.barOutputs(all.map(s => s.name), JSON.parse(shellConfigItem.barsOutputsText));
        return all.filter(s => names.indexOf(s.name) >= 0);
    }
    // The file's `input` (the mouse's side buttons and its notch), to the shell's one WheelHub and ScrollFeel.
    readonly property var _input: shellConfigItem.input
    Binding { target: WheelHub; property: "sideButtons"; value: services._input.sideButtons }
    Binding { target: WheelHub; property: "sideClick"; value: services._input.sideClick }
    Binding { target: WheelHub; property: "sideGain"; value: services._input.sideGain }
    Binding { target: WheelHub; property: "sideHold"; value: services._input.sidePointer === "hold" }
    Binding { target: ScrollFeel; property: "notchPx"; value: services._input.notchPx }
    Binding { target: ScrollFeel; property: "notchMs"; value: services._input.notchMs }
    // Super+F2: every screen's bars hide and show together (each frame eases its own). `barsShown` is what was ASKED; `barsUp` is
    // what the frames do: while the session is locked the lock's popup hangs from the bars, so they are up whatever was asked, and
    // the asked state is back when the lock lets go (a toggle made in between is kept, and does nothing visible until then).
    property bool barsShown: true
    readonly property bool barsUp: services.barsShown || lockOwner.locked
    // THE AURA (GooeyEngine.playAura; shell.jsonc `"shadow": { "aura": true }`, off unless it says so): the shadow's halo lit with hues
    // flowing round the outline, on every screen. Called by IPC (`shell aura <palette> <group>`) and by the events of
    // AuraEvents (below). Answers one line: what plays, or why not.
    function playAura(palette: string, group: string, lifeMs: int): string {
        if (!shellConfigItem.auraEnabled)
            return "aura is off";
        if (!services.barsUp)
            return "the bars are hidden";
        let n = 0, words = [];
        for (const name in services.frames) {
            const e = services.frames[name] ? services.frames[name].engine : null;
            if (!e)
                continue;
            words = e.auraPalettes;
            if (e.playAura(palette, group, lifeMs))
                n++;
        }
        return n > 0 ? "playing on " + n + " screen(s)" : "no such palette or group (palettes: " + words.join(" ") + "; groups: all island side)";
    }
    // WHICH events play it (AuraEvents has the table): an LLM answer after a minute, a system update that ends with its
    // popup shut, a timer or alarm, the screen being shared or recorded. DND silences them; the switch above silences all.
    AuraEvents {
        id: auraEventsItem
        armed: shellConfigItem.auraEnabled
        events: shellConfigItem.auraEvents
        // a dictation take's aura is the user's own act and runs for the take: an event never plays over it (its 2 s life would
        // end the take's aura under the user's words)
        play: (palette, group) => dictationItem.holdsAura ? "the dictation take holds the aura" : services.playAura(palette, group, 0)
        llm: services.moduleOn("llm") ? llmBundle.service : null
        updates: updatesService
        timers: timersService
        notifications: services.notifications
    }
    function stopAura(): void {
        for (const name in services.frames)
            if (services.frames[name] && services.frames[name].engine)
                services.frames[name].engine.stopAura();
    }
    // The way out from the level each screen's aura is at (GooeyEngine.releaseAura): the end of a take.
    function releaseAura(): void {
        for (const name in services.frames)
            if (services.frames[name] && services.frames[name].engine)
                services.frames[name].engine.releaseAura();
    }
    // -- dictation: a PROTOTYPE behind shell.jsonc `"dictation": { "enabled": true }` (modules/dictation, docs/dictation.md) --
    // ONE take at a time for the whole shell, the keys registered once. Its aura is the user's own act: the hook above, not AuraEvents.
    readonly property alias dictation: dictationItem
    // THE SHELL'S OWN FIELDS (DictationService, THE SHELL ROUTE): the popup content whose field has the caret -- the focused screen's
    // open popup's content (the primary, then its secondary), then any other screen's -- or null. A content takes dictation by
    // declaring `dictationActive` (true while its field has the caret, which falls with the window's keyboard) and
    // `dictationPreedit(text)` / `dictationCommit(text)`; nothing else is asked of it.
    readonly property var dictationTarget: {
        void services.serial;
        const names = Object.keys(services.frames);
        const fname = services.focusedScreen;
        const order = fname !== "" ? [fname].concat(names.filter(n => n !== fname)) : names;
        for (const name of order) {
            const e = services.frames[name] ? services.frames[name].engine : null;
            if (!e)
                continue;
            const cands = [e.popupOpen ? e.thePopup.contentItem : null, e.childOpen ? e.childPopup.contentItem : null];
            for (const c of cands)
                if (c && c.dictationActive === true && typeof c.dictationPreedit === "function" && typeof c.dictationCommit === "function")
                    return c;
        }
        return null;
    }
    DictationService {
        id: dictationItem
        live: services.live
        rawConfig: shellConfigItem.dictation
        shellTarget: services.dictationTarget
        pipewire: services.pipewire
        playAura: (palette, group, lifeMs) => services.playAura(palette, group, lifeMs)
        releaseAura: () => services.releaseAura()
        onBattery: batteryAdapter.isDischarging === true
        stateDir: services.stateDir
        // round 5's two takes: the caption card's host (the OSD's kind "caption") and where a voice ask goes
        osd: services.osd
        llm: services.moduleOn("llm") ? llmBundle.service : null
        onToast: (title, body) => dictationNotifier.notify("dictation", { title: title, body: body, urgency: "low" })
    }
    DesktopNotifier {
        id: dictationNotifier
        appName: "Dictation"
        keys: ["dictation", "spare"]
    }
    DictationShortcuts {
        service: dictationItem
        enabled: services.shortcutsEnabled
    }
    DesktopNotifier {
        id: reelNotifier
        appName: "Shell"
        keys: ["hibernate", "idle", "spare"]
    }
    // The one command a mock shell runs for real: the reel's Lock, and only when the lock is LIVE (SHELL_LOCK=live) inside a nested test
    // compositor (tools/dev/lock_env.sh marks every process of its own with LOCK_ENV_DIR). The mock's runner records and runs nothing, and
    // that is right for every other item; with SHELL_LOCK=live the whole chain runs, from a real right click to the lock's supervisor.
    CommandRunner {
        id: lockCmdRunner
        live: true
    }
    readonly property alias reelActions: reelActionsItem
    ReelActions {
        id: reelActionsItem
        runner: cmdRunner
        lockRunner: services.mock && services.lockMode === "live" && (Quickshell.env("LOCK_ENV_DIR") || "") !== "" ? lockCmdRunner : null
        idle: idleService
        notifier: reelNotifier
        commands: powerConfigItem.settings.commands
        waitForFlourish: powerConfigItem.settings.waitForFlourish
        sessionTool: sessionItem.live ? sessionItem.endTool : ""
        sessionPython: sessionItem.endPython
    }
    // -- session restore: the save before the session ends (the reel above), the decision at its start, the asks (docs/session.md).
    //    Off as shipped (config/session.jsonc "enabled"); a mock starts nothing and records what it would.
    readonly property alias session: sessionItem
    DesktopNotifier {
        id: sessionNotifier
        appName: "Session"
        keys: ["restore", "progress", "result", "spare"]
    }
    SessionService {
        id: sessionItem
        live: services.live
        configPath: services.configFilesDir + "/session.jsonc"
        notifier: sessionNotifier
        // an ask waits for the user to see it: not under the boot lock, not before the focused screen's frame is on the glass
        locked: lockOwner.locked
        shown: services.focusedPresented
    }
    // -- desktop presets (modules/presets, docs/presets.md): the saved desktops the Presets tab of the panorama popup shows (handed to the panorama owner); a load runs through the session
    //    service above (its progress and result toasts). A mock serves fixtures and runs nothing.
    readonly property alias presets: presetsItem
    PresetsService {
        id: presetsItem
        live: services.live && services.moduleOn("panorama")
        session: sessionItem
    }
    readonly property alias oled: oledItem
    // The OLED care: the bars' content steps a device pixel every 240 s (ShellFrame's zone rows read it); the place is kept across restarts.
    // Its switches are shell.jsonc's `oled.enabled` and `oled.shift` (read hot).
    OledShift {
        id: oledItem
        on: shellConfigItem.oledShift
        intervalMs: shellConfigItem.oledShiftMs
        statePath: services.stateDir + "/oled-shift.json"
    }
    readonly property alias themeControl: themeControlItem
    ThemeControl {
        id: themeControlItem
        config: shellConfigItem
        live: services.live
        commands: cmdRunner
        // the curtain is never used while the session is locked (the lock owns the screen)
        locked: lockOwner.locked
    }
    Binding { target: services.notifications; property: "curtainHold"; value: themeControlItem.wipeRun; when: !!services.notifications }
    // while the curtain shows the hidden workspaces by turns, the focus the bars read holds still
    Binding { target: focusItem; property: "held"; value: themeControlItem.repaintHeld }

    // ---- the routing (CONTRACT section 3): an unaddressed request goes to the focused screen's owner ----
    Connections {
        target: services.wiki
        ignoreUnknownSignals: true
        function onOpenRequested(tab: string) {
            const o = services.focusedOwner("clock");
            if (o && o.openWiki)
                o.openWiki(tab);
        }
    }
    Connections {
        target: services.stocks
        ignoreUnknownSignals: true
        function onAlertOpenRequested(symbol: string) {
            const o = services.focusedOwner("stocks");
            if (o && o.openSymbol)
                o.openSymbol(symbol);
        }
    }
    // a click on one of the network's toasts: the aerial popup on the focused screen
    Connections {
        target: services.aerial
        ignoreUnknownSignals: true
        function onOpenRequested() {
            const o = services.focusedOwner("aerial");
            if (o && o.open)
                o.open();
        }
    }
    // a click on a ring's toast (a timer, an alarm, a pomodoro): the clock popup on its Timers tab, on the view that rang
    Connections {
        target: timersService
        ignoreUnknownSignals: true
        function onOpenRequested(kind: string) {
            const o = services.focusedOwner("clock");
            if (o && o.openTimers)
                o.openTimers(kind);
        }
    }
    Connections {
        target: services.llm.attention
        function onShowRequested() {
            const o = services.focusedOwner("llm");
            if (o && o.open)
                o.open();
        }
        function onOpenConversation(id: var) {
            const o = services.focusedOwner("llm");
            if (o && o.openConversation)
                o.openConversation(id);
        }
    }

    // ---- the aggregation's writes ----------------------------------------------------------------------
    Binding { target: services.wiki; property: "popupOpen"; value: services.flags.wikiPopupOpen; when: !!services.wiki }
    Binding { target: timersService; property: "attended"; value: services.flags.timersAttended }
    Binding { target: services.stocks; property: "popupOpen"; value: services.flags.stocksPopupOpen; when: !!services.stocks }
    Binding { target: services.bridge; property: "popupOpen"; value: services.flags.bridgePopupOpen; when: !!services.bridge }
    Binding { target: services.panorama; property: "popupOpen"; value: services.flags.panoramaPopupOpen; when: !!services.panorama }
    Binding { target: services.silicon; property: "popupOpen"; value: services.flags.siliconPopupOpen; when: !!services.silicon }
    Binding { target: services.notifications; property: "managerOpen"; value: services.flags.managerOpen; when: !!services.notifications }
    Binding { target: services.aerial; property: "popupOpen"; value: services.flags.aerialPopupOpen; when: !!services.aerial }
    // The bar's pill shows the traffic figures on any screen: the service reads /proc/net/dev on a 1 s beat while one does (the mock has no beat to ask).
    Binding { target: services.aerial && "ratesWatched" in services.aerial ? services.aerial : null; property: "ratesWatched"; value: services.flags.aerialRatesWatch }
    // The picker pastes through the clipboard service, which sends the paste key only after the keyboard is let go: its hostOpen is the OR of the
    // clipboard shelf's and the picker's popups.
    Binding { target: services.clipboard; property: "hostOpen"; value: services.flags.clipboardHostOpen || services.flags.pickerHostOpen; when: !!services.clipboard }
    Binding { target: services.weather; property: "popupOpen"; value: services.flags.weatherPopupOpen; when: !!services.weather }
    Binding { target: services.osd; property: "playerOpen"; value: services.flags.playerPopupOpen; when: !!services.osd }
    Binding { target: services.audio; property: "popupOpen"; value: services.flags.audioPopupOpen; when: !!services.audio }
    // While the session is locked the lock shows what plays: the OSD holds its now-playing card back (OsdKinds.suppressedBy)
    Binding { target: services.osd; property: "locked"; value: services.lock.locked; when: !!services.osd }
    Binding { target: updatesService; property: "popupOpen"; value: services.flags.updatesPopupOpen }
    // A locked session holds the toasts (and the clipboard drops its sealed copies: it follows the same holds). The hypridle hook's IPC
    // (`notifications hold locked <bool>`) may still write the property; this one owns it from the lock's own word.
    Binding { target: services.notifications ? services.notifications.holds : null; property: "locked"; value: lockOwner.locked; when: !!services.notifications }
    // the break nudge (BreakClock, one per shell): a lock is a break at once, not after the idle pause
    Binding { target: BreakClock; property: "locked"; value: lockOwner.locked }

    // ---- what a probe reads --------------------------------------------------------------------------------
    // The observable state of the whole shell as one plain object (the platform probe asks for it over IPC,
    // `quickshell ipc call shell probe`, and the in-process probes read it directly): per screen the engine's
    // bodies, the bars as the engine has them, the keyboard request, and the services' recorded calls.
    // Panorama's popup tiles in the frame's px ([x, y, w, h] by display name), for a probe that has to aim at one (null when it is not open)
    function _probeObject(item: var, objectName: string): var {
        if (!item)
            return null;
        if (item.objectName === objectName)
            return item;
        for (const c of item.children) {
            const r = services._probeObject(c, objectName);
            if (r)
                return r;
        }
        return null;
    }
    function _probeTiles(frame: var, content: var): var {
        const canvas = services._probeObject(content, "canvas");
        if (!canvas || typeof canvas.tileItem !== "function" || !services.panorama)
            return null;
        const out = {};
        for (const d of services.panorama.displays || []) {
            const it = canvas.tileItem(d.name);
            if (it) {
                const a = it.mapToItem(frame, 0, 0);
                out[d.name] = [Math.round(a.x), Math.round(a.y), Math.round(it.width), Math.round(it.height)];
            }
        }
        return out;
    }
    function probeState(): var {
        const screens = {};
        for (const name in services.frames) {
            const f = services.frames[name];
            const e = f.engine;
            const bars = [];
            for (const b of e.barsList)
                if (b)
                    bars.push({ id: b.barId, edge: b.edge, rawPos: b.rawPos, rawLen: b.rawLen, thickness: Math.round(b.thickness * 100) / 100,
                                reserve: b.reserve, inputMask: b.inputMask });
            const tp = e.thePopup;
            const masks = [];
            for (const m of e.maskItems)
                if (m && m.width > 0 && m.height > 0)
                    masks.push([Math.round(m.x), Math.round(m.y), Math.round(m.width), Math.round(m.height)]);
            screens[name] = {
                width: f.width, height: f.height, mode: f.cfg.topMode,
                // the frame's Item scale and the device px per design px (ShellScale): the probes' K
                // (and the bar's / the popups' ratios on it: shell.jsonc `scale.bar` / `scale.popup`)
                scale: { frame: f.frameScale, render: f.renderScale, bar: f.barRatio, popup: f.popupRatio },
                // the window is on the Overlay layer for a popup that floats over a fullscreen window (ShellScreen.overlayWanted)
                overlay: !!f.window && f.window.overlayWanted === true,
                frozen: !!f.window && f.window._frozen === true,
                // `ratio`: the body's frame px per content px; `content`: the content's own implicit size (its units)
                popup: { open: e.popupOpen, owner: e.popupOwnerId, phase: tp.phase, keyboard: e.popupKeyboard, ratio: tp.ratio,
                         content: tp.contentItem ? [tp.contentItem.implicitWidth, tp.contentItem.implicitHeight] : null,
                         box: e.popupOpen ? [Math.round(tp.popX), Math.round(tp.popY), Math.round(tp.popW), Math.round(tp.popH)] : null,
                         bar: tp.barId, floating: tp.floating, floatF: tp.floatF,
                         panoTiles: e.popupOpen && e.popupOwnerId === "panorama" ? services._probeTiles(f, tp.contentItem) : null },
                // the child levels not closed (a secondary: its owner id "<owner>/secondary"), their boxes in the frame's px
                children: e.childPopups.filter(c => c && c.phase !== "closed").map(c => ({ owner: c.ownerId, phase: c.phase,
                    box: [Math.round(c.popX), Math.round(c.popY), Math.round(c.popW), Math.round(c.popH)] })),
                lane: { open: e.laneOpen, owner: e.laneOwnerId, blocked: e.laneBlockedReason },
                osd: { open: e.osdOpen, owner: e.osdOwnerId, phase: e.osdPhase, blocked: e.osdBlockedReason },
                // the reel slot (power / idle): the strip beside thePopup
                reel: { open: e.reelOpen, owner: e.reelOwnerId, phase: e.reelPhase, blocked: e.reelBlocked, ratio: e.theReel.ratio,
                        box: e.reelOpen ? [Math.round(e.theReel.popX), Math.round(e.theReel.popY), Math.round(e.theReel.popW), Math.round(e.theReel.popH)] : null },
                keyboardFocus: e.keyboardFocus,
                // the popup's keys let go by a window event, whether Escape is wanted here, the popup a joiner covers,
                // and how many windows the owners' focus grabs get
                keys: { released: e.keysReleased, escapeWanted: f.escapeWanted, stacked: e.stackedOwnerId, grabWindows: f.keyGrabWindows.length },
                // what each reel has selected (the power reel rests on Lock when the shell starts)
                reels: { power: f.buttons.power.reel.selectedItem ? f.buttons.power.reel.selectedItem.id : "", idle: f.buttons.idle.reel.selectedItem ? f.buttons.idle.reel.selectedItem.id : "",
                         // the padlock's flourish (playing kind, shut) and the idle reel held by the auto layer
                         lock: f.buttons.power.flourishes ? { kind: f.buttons.power.flourishes.lock.kind, shut: f.buttons.power.flourishes.shut } : null,
                         idleHeld: f.buttons.idle.autoHeld === true,
                         // the two reels' cells in the frame's design px (a film crops them)
                         cells: [f.buttons.power, f.buttons.idle].map(m => { const a = m.mapToItem(f, 0, 0); return [Math.round(a.x), Math.round(a.y), Math.round(m.width), Math.round(m.height)]; }) },
                reserve: e.edgeReserve,
                hideT: Math.round(f.hideT * 1000) / 1000,
                bars: bars,
                mask: masks,
                lengths: f.lengths,
                placed: f.placed
            };
        }
        const firstFrame = Object.keys(services.frames).length > 0 ? services.frames[Object.keys(services.frames)[0]] : null;
        // which owners RUN hosted (`shellHosted` is true; an owner that has the member but not the value would build its own
        // service and register its own shortcut)
        const hosted = {};
        if (firstFrame)
            for (const k in firstFrame.owners) {
                const o = firstFrame.owners[k];
                hosted[k] = !!o && o.shellHosted === true;
            }
        return {
            // the Escape bind: wanted by some popup, in force, how often Hyprland was told, and the Lua of the last time
            escape: { wanted: services.escapeWanted, presses: services.escapePresses, applied: escapeBindItem.applied, sent: escapeBindItem.sent, lua: escapeBindItem.lastLua, reply: escapeBindItem.lastReply },
            keyRelease: { events: keyReleaseItem.seen, focused: keyReleaseItem.focused, lua: keyReleaseItem.lastLua },
            mode: services.mode,
            settled: services.settled,
            focused: services.focusedScreen,
            // the theme curtain's run and its repaint of the hidden windows; how often the focus facts were published
            curtain: { phase: themeControlItem.curtainPhase, runs: themeControlItem.curtainRuns, drops: themeControlItem.curtainDrops,
                       fastForwards: themeControlItem.curtainFastForwards, lastMs: themeControlItem.curtainLastMs,
                       repaintRuns: themeControlItem.repaintRuns, repaintLast: themeControlItem.repaintLast, repaintHeld: themeControlItem.repaintHeld },
            focusPublished: focusItem.stats.published,
            themeMode: themeControlItem.modeNow,
            // the focused screen's focused window is fullscreen (FocusedScreen: what the overlay switch reads)
            fullscreen: focusItem.fullscreen,
            barsShown: services.barsShown,
            // the bars the frames show: the asked state, or up for the lock
            barsUp: services.barsUp,
            // the lock: the shell's whole view of it (LockOwner), the state it mirrors, and what it did to the holds
            lock: {
                mode: services.lockMode, locked: lockOwner.locked, connected: lockOwner.connected, wantPopup: lockOwner.wantPopup,
                phase: lockOwner.lockState.phase, auth: lockOwner.lockState.auth, shown: lockOwner.shownScreens,
                retractedSent: lockOwner.retractedSent, ignoredLines: lockOwner.ignoredLines, socket: lockOwner.socketPath,
                dots: lockOwner.lockState.dots, orphanHold: lockOwner._orphanHold,
                // the last `hints` / `targets` line sent per screen (what the lock was told, as the wire carried it)
                sentHints: lockOwner._sentHints, sentTargets: lockOwner._sentTargets
            },
            // what a locked session did to the toasts, and to the clipboard's sealed copies
            notifications: services.notifications ? {
                reason: services.notifications.holdReason, shown: services.notifications.toasts.shown.length,
                held: services.notifications.toasts.held.length,
                titles: services.notifications.store.all().map(r => String(r.summary))
            } : null,
            clipboard: services.clipboard ? { secrets: services.clipboard.secrets.length } : null,
            // the displays as Panorama sees them (the glyph's count, the identify, the engine, the trial)
            panorama: services.panorama ? {
                live: services.panorama.live === true, panes: services.panorama.panes, mirroring: services.panorama.mirroring === true,
                identify: services.panorama.identify, engine: services.panorama.engineState, phase: services.panorama.phase,
                setKey: services.panorama.setKey, displays: (services.panorama.displays || []).map(d => d.name),
                keepWaiting: services.panoramaKeepWaiting
            } : null,
            // the default speaker and microphone, as the volume pill's wheel moves them
            audio: services.pipewire && services.pipewire.defaultSink && services.pipewire.defaultSource ? {
                sink: services.pipewire.defaultSink.audio.volume, source: services.pipewire.defaultSource.audio.volume,
                sinkMuted: services.pipewire.defaultSink.audio.muted === true, sourceMuted: services.pipewire.defaultSource.audio.muted === true,
                osdMutes: services.osdMutes
            } : null,
            flags: services.flags,
            // what the aggregation WROTE: the services' own properties
            written: {
                wikiPopupOpen: services.wiki ? services.wiki.popupOpen === true : false, timersAttended: timersService.attended === true,
                bridgePopupOpen: services.bridge ? services.bridge.popupOpen === true : false,
                panoramaPopupOpen: services.panorama ? services.panorama.popupOpen === true : false,
                stocksPopupOpen: services.stocks ? services.stocks.popupOpen === true : false, siliconPopupOpen: services.silicon ? services.silicon.popupOpen === true : false,
                managerOpen: services.notifications ? services.notifications.managerOpen === true : false,
                aerialPopupOpen: services.aerial ? services.aerial.popupOpen === true : false,
                aerialRatesWatch: services.aerial && "ratesWatched" in services.aerial ? services.aerial.ratesWatched === true : false,
                clipboardHostOpen: services.clipboard ? services.clipboard.hostOpen === true : false,
                weatherPopupOpen: services.weather ? services.weather.popupOpen === true : false, updatesPopupOpen: updatesService.popupOpen === true,
                holdsLocked: services.notifications ? services.notifications.holds.locked === true : false
            },
            // the OSD owner is told which screen presents (CONTRACT section 4: `active`)
            osdActive: !!firstFrame && "active" in firstFrame.owners.osd,
            hosted: hosted,
            idle: { mode: idleService.mode, selected: idleService.selectedMode, auto: idleService.autoActive, reason: idleService.autoReason, held: idleService.held, log: idleService.log },
            // the player's frame clock: playing with nobody holding it must not tick (PlayerTickHold)
            player: services.mpd ? { playing: services.mpd.playing === true, ticking: services.mpd.ticking === true, tickHolds: services.mpd.tickHolds || 0 } : null,
            calls: cmdRunner.calls,
            screens: screens
        };
    }

    // ---- the census ---------------------------------------------------------------------------------------
    // The QML type of everything above (the name before the "(" of its string form, without the
    // generated suffix), for the probes: exactly one of each, and never a BatteryData.
    readonly property var census: {
        const objs = {
            notifications: services.notifications, notifyClock: notifyClockItem, auth: authBroker, howdy: howdyConfig,
            polkit: polkitSource, authOwner: authOwnerItem, osd: osdService, osdStyle: osdStyleItem,
            pipewire: services.pipewire, audio: services.audio, mpd: services.mpd, aerial: services.aerial,
            silicon: services.silicon, siliconBattery: batteryAdapter, calendar: services.calendar,
            timers: timersService, wiki: services.wiki, screentime: services.screentime, weather: services.weather,
            stocks: services.stocks, launcher: launcherService, appLookup: appLookupItem,
            clipboard: services.clipboard, picker: services.picker, bridge: services.bridge, panorama: services.panorama, drm: drmWatch, notes: notesStore, llm: services.llm, updates: updatesService,
            tray: services.tray, windowtrayConfig: windowtrayConfigItem, focus: focusItem, idle: idleService,
            commands: cmdRunner, shellConfig: shellConfigItem, reelActions: reelActionsItem, oled: oledItem,
            lock: lockOwner, locale: localeConfig, dictation: dictationItem, session: sessionItem
        };
        const byId = {}, counts = {};
        for (const k in objs) {
            const o = objs[k];
            const t = o ? String(o).replace(/\(0x.*$/, "").replace(/_QMLTYPE_\d+$/, "").replace(/_QML_\d+$/, "") : "";
            byId[k] = t;
            if (t !== "")
                counts[t] = (counts[t] ?? 0) + 1;
        }
        return { byId: byId, counts: counts };
    }
}
