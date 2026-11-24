pragma ComponentBehavior: Bound

import QtQuick
import QtTest
import Quickshell

// Quickshell registers the types reachable from the ROOT file's imports.
// qmllint disable unused-imports
import "modules/common/theme"
import "modules/common/components"
import "modules/bar/gooey"
import "modules/launcher"
import "modules/launcher/data"
import "modules/clipboard"
import "modules/clipboard/data"
import "modules/notifications"
import "modules/notifications/parts"
import "modules/notifications/data"
import "modules/osd"
import "modules/osd/data"
import "modules/osd/data/sources"
import "modules/wiki"
import "modules/wiki/data"
import "modules/auth"
import "modules/auth/data"
import "modules/common/system"
// qmllint enable unused-imports

// =============================================================================
// tools/dev/qml/shell_hosted_m2_probe.qml -- stream M2 of the shell assembly: the launcher,
// clipboard, notifications and OSD owners in SHELL-HOSTED mode (CONTRACT section 4):
// TWO screens (two windows, two engines) on ONE set of services, as the shell
// runs them. Driven by tools/dev/shell_hosted_m2_probe.sh (private XDG homes, fixture
// apps; the runner owns the ARMs). Every check prints
// `M2 PASS|FAIL <name>  (<detail>)`; the last line is `M2 DONE checks=N fails=F`.
//
//   H1  ONE LauncherService in the whole object tree, whatever the number of screens; a hosted
//       owner builds no failure notifier and registers no GlobalShortcut (shortcutEnabled left true
//       on purpose); the owners hold the injected service and write nothing on it
//   H2  a launcher opened on a screen reads the shared service and draws its icons with AppIcon
//       (a plain Image of the icon theme's file, in THAT window; nothing is shared or baked)
//   H3  the clipboard and the manager flags: a hosted owner writes no service property
//       (`sharedFlags` says what it would have written, the host ORs them); the control,
//       the same owner not hosted, does write
//   H4  an unaddressed openManagerRequested opens the manager on the lane's screen only
//   H5  the manager opened by key / IPC (exclusive) asks for the whole track and closes on
//       a press in the void; opened by the bell (on demand) it asks for neither
//   H6  _alongOf on a RIGHT and a LEFT bar: the bell's manager opens under the bell
//   H7  the OSD presents only on the owner that is `active`, queues nothing elsewhere, and a
//       focus move takes it from one screen to the other
//   H8  the lane's "wanted and not out" is a REPORT per screen (the scheduler's clocks
//       block while any screen says yes)
//   H9  the OSD service hands the shell's backends down; a hosted source with no backend
//       builds nothing and says so (once); a source whose backend is injected builds
//       nothing, not even for an instant (BatterySource, stage N3)
//   H10 the shell's ONE focus tracker (E2's FocusedScreen, handed in as `focusSource`): the
//       service hands it to its holds (the lane's screen and the fullscreen hold read its answer),
//       an OsdOwner reads `active` and `fullscreen` from it unless the host assigns them, the
//       AuthOwner reads `screenName` and `fullscreen` (the pill or the toast)
// This probe needs the tree with E2 merged (FocusedScreen, FullscreenWatch.focusSource).
// =============================================================================
ShellRoot {
    id: root
    settings.watchFiles: false

    readonly property string dir: Quickshell.env("PROBE_DIR") || ""
    readonly property bool armed: root.dir !== ""
    // The static scan of the runner: the five sources' Loaders carry the hosted guard. The
    // dynamic source checks instantiate sources whose guard, if missing, would build a REAL
    // service (Pipewire, MPD, NetworkManager, BlueZ, the EC reader): never without it.
    readonly property bool sourcesGuarded: Quickshell.env("M2_SOURCES_GUARDED") === "1"

    property int checks: 0
    property int fails: 0
    function check(name, ok, detail) {
        root.checks++;
        if (!ok)
            root.fails++;
        console.log("M2 " + (ok ? "PASS " : "FAIL ") + name + (detail !== undefined && detail !== "" ? "  (" + detail + ")" : ""));
    }

    // ---- the shell's services, once (what ShellServices builds) -----------------------------
    LauncherService {
        id: sharedLauncher
        dryRun: true
        configPath: root.armed ? root.dir + "/cfg/launcher.json" : "/nonexistent-m2/launcher.json"
        favoritesPath: root.armed ? root.dir + "/cfg/launcher_favorites.json" : "/nonexistent-m2/launcher_favorites.json"
        favoritesLegacyPath: ""
        statePath: root.armed ? root.dir + "/state/launcher/state.json" : "/nonexistent-m2/state.json"
        scriptsRootOverride: root.armed ? root.dir + "/scripts" : "/nonexistent-m2/scripts"
    }
    ClipboardMock {
        id: sharedClip
    }
    // The shell's one focus tracker, a fake the probe drives (E2's FocusedScreen).
    FocusedScreen {
        id: focusSrc
        live: false
    }
    NotificationService {
        id: sharedNotif
        serverEnabled: false
        registerOnBus: false
        persist: false
        liveSignals: false
        ipcEnabled: false
        configPath: ""
        focusSource: focusSrc
    }
    AuthBroker {
        id: authBroker
        registerOnBus: false
    }
    AuthOwner {
        id: authOwner
        broker: authBroker
        service: sharedNotif
        focusSource: focusSrc
        // No layer-shell window offscreen: the owner decides where the request goes, `where` says it.
        pillSource: ""
    }
    BoundaryClock {
        id: sharedNotifClock
    }
    QtObject { id: fakeAudio }
    QtObject {
        id: fakePill
        property var log: []
        property bool showing: true
        function present(req: var, hidden: var): void { fakePill.log.push(req.kind); }
        function dismiss(): void {}
    }
    QtObject { id: fakeMpd }
    QtObject { id: fakeAerial }
    QtObject { id: fakeBattery }
    OsdService {
        id: sharedOsd
        live: false
        registerOnBus: false
        shellHosted: true
        audioBackend: fakeAudio
        mpdBackend: fakeMpd
        aerialBackend: fakeAerial
        batteryBackend: fakeBattery
    }
    OsdStyle {
        id: sharedOsdStyle
    }

    // The host's aggregation (ShellServices): the service flag is the OR of the screens' flags.
    // Off while a check wants to see what an OWNER wrote by itself.
    property bool aggregate: true
    Binding {
        target: sharedClip
        property: "hostOpen"
        value: screenA.clip.sharedFlags.hostOpen || screenB.clip.sharedFlags.hostOpen
        when: root.aggregate
    }
    Binding {
        target: sharedNotif
        property: "managerOpen"
        value: screenA.notif.sharedFlags.managerOpen || screenB.notif.sharedFlags.managerOpen
        when: root.aggregate
    }

    // ---- a screen: a window, an engine, the owners as the shell mounts them ---------------------
    component Screen: Window {
        id: sc

        required property string tag
        // The side bar the bell and the OSD stand on ("right" | "left").
        required property string side
        // The shell's services (what ShellServices hands every screen).
        required property var launcherSvc
        required property var clipSvc
        required property var notifSvc
        required property var notifClock
        required property var osdSvc
        required property var osdStyle
        property bool osdActive: false
        // false: `active` is the host's explicit switch (a Binding below); true: the owner reads it
        // from its focusSource, the Binding gives way and the owner's own default comes back.
        property bool osdFromSource: false
        property bool clipHosted: true
        property bool clipShortcut: true
        property bool notifHosted: true

        readonly property alias eng: gooeyEngine
        readonly property alias launcher: launcherOwner
        readonly property alias clip: clipOwner
        readonly property alias notif: notifOwner
        readonly property alias osd: osdOwner
        readonly property alias bell: bellItem
        readonly property alias test: tc

        width: 1000
        height: 900
        visible: true
        color: Theme.surface

        GooeyEngine {
            id: gooeyEngine
            anchors.fill: parent
            surfaceColor: Theme.surface
            barsList: [topBar, bottomBar, sideBar]

            GooeyBar {
                id: topBar
                engine: gooeyEngine
                barId: "topR"
                edge: "top"
                rawPos: 0
                rawLen: gooeyEngine.w
            }
            GooeyBar {
                id: bottomBar
                engine: gooeyEngine
                barId: "bottom"
                edge: "bottom"
                rawPos: 0
                rawLen: gooeyEngine.w
                thickness: 6
                reserve: 0
                inputMask: false
            }
            GooeyBar {
                id: sideBar
                engine: gooeyEngine
                barId: sc.side
                edge: sc.side
                rawPos: topBar.thickness
                rawLen: gooeyEngine.h - topBar.thickness - bottomBar.thickness
                thickness: 6
                reserve: 0
                inputMask: false
                // The bell's stand-in, 60 % of the way along the bar (bar-local x runs along it).
                Item {
                    id: bellItem
                    x: Math.round(sideBar.width * 0.6)
                    y: 0
                    width: 24
                    height: 24
                }
            }
        }

        LauncherBarOwner {
            id: launcherOwner
            shellHosted: true
            service: sc.launcherSvc
            engine: gooeyEngine
            bar: bottomBar
            barId: "bottom"
            dryRun: true
            // Left on: a hosted owner must not register it (the host's router does).
            shortcutEnabled: true
        }
        ClipboardBarOwner {
            id: clipOwner
            shellHosted: sc.clipHosted
            service: sc.clipSvc
            engine: gooeyEngine
            bar: bottomBar
            barId: "bottom"
            liveWindow: false
            // On while hosted (it must register nothing); the NOT hosted control turns it off FIRST, as a
            // mockup does: a real GlobalShortcut here would take Alt+V from whatever shell is on the compositor.
            shortcutEnabled: sc.clipShortcut
        }
        NotificationsBarOwner {
            id: notifOwner
            shellHosted: sc.notifHosted
            screenName: sc.tag
            service: sc.notifSvc
            clock: sc.notifClock
            engine: gooeyEngine
            bar: sideBar
            barId: sc.side
            anchorItem: bellItem
        }
        OsdOwner {
            id: osdOwner
            engine: gooeyEngine
            service: sc.osdSvc
            style: sc.osdStyle
            screenName: sc.tag
            spot: ({ bar: sc.side, along: 0.5 })
            // Longer than any wait below: only the owner's `active` can take an OSD away in time.
            dismissMs: 6000
        }
        Binding {
            target: osdOwner
            property: "active"
            value: sc.osdActive
            when: !sc.osdFromSource
        }
        TestCase {
            id: tc
            name: "screen" + sc.tag
            when: false
        }
    }

    Screen {
        id: screenA
        tag: "A"
        side: "right"
        launcherSvc: sharedLauncher
        clipSvc: sharedClip
        notifSvc: sharedNotif
        notifClock: sharedNotifClock
        osdSvc: sharedOsd
        osdStyle: sharedOsdStyle
        osdActive: true
        x: 0
        y: 0
    }
    Screen {
        id: screenB
        tag: "B"
        side: "left"
        launcherSvc: sharedLauncher
        clipSvc: sharedClip
        notifSvc: sharedNotif
        notifClock: sharedNotifClock
        osdSvc: sharedOsd
        osdStyle: sharedOsdStyle
        x: 1020
        y: 0
    }

    // Sources declared at load, as a host declares them. The first has its backend passed at
    // DECLARATION (a binding to an object); it must never build a reader of its own, not even
    // for the instant before that binding has been evaluated (stage N3's finding).
    BatterySource {
        id: injectedBattery
        live: true
        backend: fakeBattery
    }
    // The adapter of a shell that makes its services in Loaders: the object does not exist when the
    // source is created, and arrives a moment after (the instant stage N3 found a BatteryData built in).
    Loader {
        id: lateAdapter
        sourceComponent: Component {
            QtObject {
                property int percent: 50
                signal eventLowCharge
                signal eventFullyCharged
            }
        }
    }
    BatterySource {
        id: lateBattery
        live: true
        backend: lateAdapter.item
    }
    BatterySource {
        id: noOptInBattery
        live: true
    }
    readonly property var hostedItem: hostedSources.item
    Loader {
        id: hostedSources
        active: root.sourcesGuarded
        sourceComponent: Item {
            property alias audio: hostedAudio
            property alias mpd: hostedMpd
            property alias net: hostedNet
            property alias bt: hostedBt
            property alias battery: hostedBattery
            AudioSource { id: hostedAudio; live: true; shellHosted: true }
            MpdSource { id: hostedMpd; live: true; shellHosted: true }
            NetSource { id: hostedNet; live: true; shellHosted: true }
            BtSource { id: hostedBt; live: true; shellHosted: true }
            BatterySource { id: hostedBattery; live: true; shellHosted: true }
        }
    }

    // ---- helpers ----------------------------------------------------------------------------
    function waitUntil(cond, ms) {
        const t0 = Date.now();
        while (!cond() && Date.now() - t0 < ms)
            screenA.test.wait(20);
        return !!cond();
    }
    function settle(ms) {
        screenA.test.wait(ms);
    }
    function has(o, k) {
        return o !== null && typeof o === "object" && (k in o);
    }
    // A list property as an array ([] when the object has none, or its list cannot be counted:
    // some Quickshell lists define no Count function and throw).
    function listOf(o, k) {
        const out = [];
        try {
            const l = o[k];
            if (l && typeof l.length === "number")
                for (let i = 0; i < l.length; i++)
                    out.push(l[i]);
        } catch (e) {
            return out;
        }
        return out;
    }
    // Every object reachable from `roots`, tallied by the members that identify its type.
    function census(roots) {
        const c = { launcherSvc: 0, flourish: 0, launcherNotifier: 0, shortcut: 0,
                    lazy: 0, lazyActive: 0, objects: 0 };
        const seen = new Set();
        const stack = roots.slice();
        while (stack.length) {
            const o = stack.pop();
            if (o === null || o === undefined || typeof o !== "object" || seen.has(o))
                continue;
            seen.add(o);
            c.objects++;
            if (root.has(o, "notifyKeys") && root.has(o, "endSession"))
                c.launcherSvc++;
            if (root.has(o, "holdReopen"))
                c.flourish++;
            if (root.has(o, "notifySend") && o.appName === "Launcher")
                c.launcherNotifier++;
            if (root.has(o, "appid") && root.has(o, "pressed"))
                c.shortcut++;
            if (root.has(o, "activeAsync")) {
                c.lazy++;
                if (o.active)
                    c.lazyActive++;
            }
            for (const k of ["data", "children", "resources"])
                for (const e of root.listOf(o, k))
                    stack.push(e);
            for (const k of ["item", "contentItem"]) {
                let v = null;
                try {
                    v = o[k];
                } catch (e) {
                    v = null;
                }
                if (v)
                    stack.push(v);
            }
        }
        return c;
    }
    // The first object under `top` that satisfies `pred`.
    function find(top, pred) {
        const seen = new Set();
        const stack = [top];
        while (stack.length) {
            const o = stack.pop();
            if (o === null || o === undefined || typeof o !== "object" || seen.has(o))
                continue;
            seen.add(o);
            if (pred(o))
                return o;
            for (const e of root.listOf(o, "children"))
                stack.push(e);
            let it = null;
            try {
                it = o.item;
            } catch (e) {
                it = null;
            }
            if (it)
                stack.push(it);
        }
        return null;
    }
    function catchAllRect(scr) {
        const e = scr.eng;
        return e.maskItems.some(m => !!m && m.width >= e.w - 0.5 && m.height >= e.h - 0.5);
    }
    function closeAll(scr) {
        scr.launcher.close();
        scr.clip.close();
        scr.notif.close();
        root.waitUntil(() => !scr.eng.popupOpen, 3000);
    }

    // ---- the run ----------------------------------------------------------------------------
    function run() {
        const A = screenA, B = screenB;

        // H1 -- one service, one store, nothing built or registered by a hosted owner -------------------
        root.waitUntil(() => A.eng.w > 0 && B.eng.w > 0, 3000);
        root.settle(300);
        // The shell's objects under ShellRoot cannot be listed (a Scope's list has no Count): the shared
        // ones are roots of their own, the screens are walked through their items and loaders.
        const c = root.census([sharedLauncher, sharedClip, sharedNotif, sharedOsd, A, B]);
        root.check("H1 one LauncherService in the whole shell (two screens)", c.launcherSvc === 1, JSON.stringify(c));
        root.check("H1 one ConfirmFlourish per screen, no failure notifier of the owners'",
                   c.flourish === 2 && c.launcherNotifier === 0, JSON.stringify(c));
        root.check("H1 a hosted owner registers no GlobalShortcut though shortcutEnabled is on (no loader active, none built)",
                   c.shortcut === 0, "shortcuts " + c.shortcut + ", lazy loaders " + c.lazy + " (" + c.lazyActive + " active)");
        root.check("H1 both owners hold the injected service, and wrote nothing on it",
                   A.launcher.service === sharedLauncher && B.launcher.service === sharedLauncher
                   && sharedLauncher.notifier === null && sharedLauncher.rowsOverride === -1
                   && sharedLauncher.columnsOverride === -1,
                   "notifier " + sharedLauncher.notifier
                   + ", rows/cols override " + sharedLauncher.rowsOverride + "/" + sharedLauncher.columnsOverride);

        // H2 -- the launcher on each screen draws the icon theme's icons ---------------------------------
        // The launcher on each screen: the shared service, this window's icons.
        root.waitUntil(() => sharedLauncher.ready, 10000);
        for (const S of [A, B]) {
            S.launcher.open("shortcut");
            const opened = root.waitUntil(() => S.launcher.popupMine && !!S.eng.thePopup.contentItem, 4000);
            const popup = opened ? S.eng.thePopup.contentItem : null;
            const icon = popup ? (root.waitUntil(() => !!root.find(popup, o => root.has(o, "archFallback") && o.ready), 4000)
                                  ? root.find(popup, o => root.has(o, "archFallback") && o.ready) : null) : null;
            root.check("H2 the launcher opened on " + S.tag + " reads the shared service and shows a theme icon in THIS window",
                       !!popup && popup.service === sharedLauncher && !!icon && icon.Window.window === S,
                       "popup " + (!!popup) + ", icon " + (!!icon) + (icon ? ", its source " + icon.source + " in "
                       + (icon.Window.window === A ? "A" : icon.Window.window === B ? "B" : "?") : ""));
            S.launcher.close();
            root.waitUntil(() => !S.launcher.popupMine && S.eng.thePopup.phase === "closed", 4000);
        }

        // H3 -- the flags: the hosted owner writes nothing, the host ORs --------------------------------------
        root.aggregate = false;
        A.clip.toggle();
        root.waitUntil(() => A.clip.popupMine, 3000);
        root.settle(100);
        root.check("H3 clipboard: open on a screen, the hosted owner says hostOpen in sharedFlags and writes NOTHING on the service",
                   A.clip.popupMine && A.clip.sharedFlags.hostOpen === true && B.clip.sharedFlags.hostOpen === false
                   && sharedClip.hostOpen === false, "popupMine " + A.clip.popupMine + ", flag " + A.clip.sharedFlags.hostOpen
                   + ", service.hostOpen " + sharedClip.hostOpen);
        root.aggregate = true;
        root.settle(50);
        root.check("H3 clipboard: the host's OR sets the service flag, and clears it on close",
                   sharedClip.hostOpen === true, "service.hostOpen " + sharedClip.hostOpen);
        A.clip.close();
        root.waitUntil(() => !A.clip.popupMine, 3000);
        root.settle(50);
        root.check("H3 clipboard: ... closed again", sharedClip.hostOpen === false, "service.hostOpen " + sharedClip.hostOpen);
        root.waitUntil(() => A.eng.thePopup.phase === "closed", 3000);
        // the control: the same owner NOT hosted writes the flag itself
        root.aggregate = false;
        B.clipShortcut = false;
        B.clipHosted = false;
        B.clip.toggle();
        root.waitUntil(() => B.clip.popupMine, 3000);
        root.settle(100);
        root.check("H3 clipboard control: not hosted, the owner's own Binding writes service.hostOpen",
                   B.clip.popupMine && sharedClip.hostOpen === true, "service.hostOpen " + sharedClip.hostOpen);
        B.clip.close();
        root.waitUntil(() => !B.clip.popupMine, 3000);
        B.clipHosted = true;
        B.clipShortcut = true;
        root.aggregate = true;
        root.waitUntil(() => B.eng.thePopup.phase === "closed", 3000);

        root.aggregate = false;
        A.notif.toggle();
        root.waitUntil(() => A.notif.popupMine, 3000);
        root.settle(100);
        root.check("H3 manager: open on a screen, the hosted owner says managerOpen in sharedFlags and writes NOTHING on the service",
                   A.notif.popupMine && A.notif.sharedFlags.managerOpen === true && B.notif.sharedFlags.managerOpen === false
                   && sharedNotif.managerOpen === false, "popupMine " + A.notif.popupMine + ", flag " + A.notif.sharedFlags.managerOpen
                   + ", service.managerOpen " + sharedNotif.managerOpen);
        root.aggregate = true;
        root.settle(50);
        root.check("H3 manager: the host's OR sets the service flag", sharedNotif.managerOpen === true, "service.managerOpen " + sharedNotif.managerOpen);
        A.notif.close();
        root.waitUntil(() => !A.notif.popupMine && A.eng.thePopup.phase === "closed", 3000);
        root.settle(50);
        root.check("H3 manager: ... and clears it on close", sharedNotif.managerOpen === false, "service.managerOpen " + sharedNotif.managerOpen);
        root.aggregate = false;
        B.notifHosted = false;
        B.notif.toggle();
        root.waitUntil(() => B.notif.popupMine, 3000);
        root.settle(100);
        root.check("H3 manager control: not hosted, the owner's own Binding writes service.managerOpen",
                   B.notif.popupMine && sharedNotif.managerOpen === true, "service.managerOpen " + sharedNotif.managerOpen);
        B.notif.close();
        root.waitUntil(() => !B.notif.popupMine && B.eng.thePopup.phase === "closed", 3000);
        B.notifHosted = true;
        root.aggregate = true;
        root.settle(50);

        // H4 -- an unaddressed request opens the manager on the lane's screen only ---------------------------
        sharedNotif._laneScreen = "B";
        sharedNotif.openManagerRequested("");
        root.waitUntil(() => B.notif.popupMine, 3000);
        root.settle(300);
        root.check("H4 openManagerRequested(\"\"): the manager opens on the lane's screen (B) and nowhere else",
                   B.notif.popupMine && !A.notif.popupMine, "A " + A.notif.popupMine + ", B " + B.notif.popupMine);
        sharedNotif.closeManagerRequested();
        root.waitUntil(() => !B.notif.popupMine && B.eng.thePopup.phase === "closed", 3000);
        sharedNotif._laneScreen = "";
        sharedNotif.openManagerRequested("A");
        root.waitUntil(() => A.notif.popupMine, 3000);
        root.settle(300);
        root.check("H4 openManagerRequested(\"A\"): addressed, it opens on A and not on B",
                   A.notif.popupMine && !B.notif.popupMine, "A " + A.notif.popupMine + ", B " + B.notif.popupMine);

        // H5 -- the exclusive manager releases on a press in the void -----------------------------------------
        const mgr = A.eng.thePopup.contentItem;
        root.check("H5 opened by a request (a key, IPC): exclusive, and it asks for the whole track as input",
                   !!mgr && mgr.keyboardFocusRequest === "exclusive" && mgr.maskCatchAll === true && root.catchAllRect(A),
                   "keyboard " + (mgr ? mgr.keyboardFocusRequest : "-") + ", maskCatchAll " + (mgr ? mgr.maskCatchAll : "-")
                   + ", catch-all rect " + root.catchAllRect(A));
        A.test.mouseClick(A.contentItem, 300, 600);
        const released = root.waitUntil(() => !A.notif.popupMine, 3000);
        root.check("H5 a press in the void closes it (the keyboard is released)", released, "popupMine " + A.notif.popupMine);
        root.waitUntil(() => A.eng.thePopup.phase === "closed", 3000);
        A.notif.toggle();
        root.waitUntil(() => A.notif.popupMine && !!A.eng.thePopup.contentItem, 3000);
        root.settle(300);
        const mgr2 = A.eng.thePopup.contentItem;
        const catchOn = root.catchAllRect(A);
        A.test.mouseClick(A.contentItem, 300, 600);
        root.settle(700);
        root.check("H5 control: opened by the bell it is on demand, asks for no catch-all, and a click elsewhere is not its business",
                   !!mgr2 && mgr2.keyboardFocusRequest === "onDemand" && mgr2.maskCatchAll === false && !catchOn && A.notif.popupMine,
                   "keyboard " + (mgr2 ? mgr2.keyboardFocusRequest : "-") + ", catch-all rect " + catchOn + ", still open " + A.notif.popupMine);
        A.notif.close();
        root.waitUntil(() => !A.notif.popupMine && A.eng.thePopup.phase === "closed", 3000);

        // H6 -- _alongOf on a right and a left bar --------------------------------------------------------------
        for (const S of [A, B]) {
            const expect = S.bell.x + S.bell.width / 2;
            const got = S.notif._alongOf(S.bell);
            S.notif.toggle();
            root.waitUntil(() => S.notif.popupMine && S.eng.thePopup.t >= 1, 4000);
            root.settle(200);
            const pop = S.eng.thePopup;
            const bc = S.bell.mapToItem(S.contentItem, S.bell.width / 2, S.bell.height / 2);
            const popC = pop.popY + pop.popH / 2;
            root.check("H6 " + S.side + " bar: _alongOf is the bell's place ALONG the bar (bar-local x), and the manager opens under the bell",
                       Math.abs(got - expect) < 0.5 && Math.abs(popC - bc.y) < 4 && pop.popH > 20,
                       "alongOf " + Number(got).toFixed(1) + " (want " + Number(expect).toFixed(1) + "), popup centre y " + Number(popC).toFixed(1)
                       + " vs bell y " + Number(bc.y).toFixed(1) + ", popup " + Math.round(pop.popH) + " long");
            S.notif.close();
            root.waitUntil(() => !S.notif.popupMine && S.eng.thePopup.phase === "closed", 3000);
        }

        // H7 -- the OSD presents only where it is active ---------------------------------------------------------
        sharedOsd.test("volume");
        root.waitUntil(() => A.eng.osdOpen, 3000);
        root.settle(300);
        root.check("H7 the active screen presents the OSD; the inactive one asks the engine for nothing, shows nothing, queues nothing",
                   A.eng.osdOpen && A.osd.shown !== null && !B.eng.osdOpen && B.osd.shown === null && B.osd._queue.length === 0
                   && B.eng.osdRequestOwner === "" && B.eng.osdPhase === "closed",
                   "A open " + A.eng.osdOpen + " shown " + (A.osd.shown ? A.osd.shown.kind : "-") + "; B open " + B.eng.osdOpen
                   + " phase " + B.eng.osdPhase + " request '" + B.eng.osdRequestOwner + "' queue " + B.osd._queue.length);
        // the focus moves: A goes inactive (what it had out folds), B active, no backlog for B
        A.osdActive = false;
        B.osdActive = true;
        const folded = root.waitUntil(() => !A.eng.osdOpen && A.osd.shown === null, 1500);
        root.check("H7 a screen that goes inactive takes its OSD away, and the one that becomes active starts from nothing",
                   folded && B.osd.shown === null && B.osd._queue.length === 0 && !B.eng.osdOpen,
                   "A open " + A.eng.osdOpen + " shown " + (A.osd.shown ? A.osd.shown.kind : "-") + "; B shown " + (B.osd.shown ? B.osd.shown.kind : "-")
                   + " queue " + B.osd._queue.length);
        sharedOsd.test("brightness");
        root.waitUntil(() => B.eng.osdOpen, 3000);
        root.settle(300);
        root.check("H7 after the move the request is presented on B alone",
                   B.eng.osdOpen && B.osd.shown !== null && !A.eng.osdOpen && A.osd.shown === null && A.eng.osdRequestOwner === "",
                   "B open " + B.eng.osdOpen + "; A open " + A.eng.osdOpen + " request '" + A.eng.osdRequestOwner + "'");
        sharedOsd.dismiss();
        root.waitUntil(() => !B.eng.osdOpen, 4000);

        // H8 -- the lane's unseen state is a report per screen ------------------------------------------------------
        const sched = sharedNotif.toasts;
        sharedNotif.reportLaneUnseen("A", true);
        const t1 = sched.blocked;
        sharedNotif.reportLaneUnseen("B", true);
        sharedNotif.reportLaneUnseen("A", false);
        const t2 = sched.blocked;
        sharedNotif.reportLaneUnseen("B", false);
        const t3 = sched.blocked;
        root.check("H8 the scheduler blocks while ANY screen reports its lane wanted and not out",
                   t1 === true && t2 === true && t3 === false, "A:" + t1 + ", then B alone:" + t2 + ", then none:" + t3);
        A.notif.laneUnseen = true;
        root.settle(50);
        const t4 = sched.blocked;
        A.notif.laneUnseen = false;
        root.settle(50);
        root.check("H8 a hosted owner reports it itself (and writes no Binding onto the scheduler)",
                   t4 === true && sched.blocked === false, "while A is unseen:" + t4 + ", after:" + sched.blocked);

        // H9 -- the OSD service's backends and the sources' fallback -------------------------------------------------
        const src = sharedOsd.sources;
        root.check("H9 OsdService hands the shell's backends to its sources",
                   src.audio.backend === fakeAudio && src.mpd.backend === fakeMpd && src.net.backend === fakeAerial
                   && src.bt.backend === fakeAerial && src.battery.backend === fakeBattery && src.battery.shellHosted === true
                   && src.audio.shellHosted === true, "audio " + (src.audio.backend === fakeAudio) + ", mpd " + (src.mpd.backend === fakeMpd)
                   + ", net " + (src.net.backend === fakeAerial) + ", bt " + (src.bt.backend === fakeAerial) + ", battery " + (src.battery.backend === fakeBattery));
        root.check("H9 BatterySource with the adapter passed at declaration built NOTHING, not even for an instant (stage N3)",
                   injectedBattery.builds === 0 && injectedBattery.backend === fakeBattery, "builds " + injectedBattery.builds);
        root.check("H9 BatterySource whose adapter arrives from a Loader after it was created built NOTHING for the instant before (stage N3)",
                   lateBattery.builds === 0 && lateBattery.backend === lateAdapter.item && lateAdapter.item !== null,
                   "builds " + lateBattery.builds + ", adapter arrived " + (lateAdapter.item !== null));
        root.check("H9 BatterySource with no backend and no request builds nothing either (the EC reader is opt-in)",
                   noOptInBattery.builds === 0, "builds " + noOptInBattery.builds);
        if (root.sourcesGuarded) {
            const hs = root.hostedItem;
            root.settle(300);
            const built = hs.audio.builds + hs.mpd.builds + hs.net.builds + hs.bt.builds + hs.battery.builds;
            root.check("H9 five hosted sources with NO backend build nothing (each says so once in the log)", built === 0,
                       "builds audio " + hs.audio.builds + " mpd " + hs.mpd.builds + " net " + hs.net.builds + " bt " + hs.bt.builds + " battery " + hs.battery.builds);
        } else {
            root.check("H9 five hosted sources with NO backend build nothing (skipped: the sources' hosted guard is not in place)", false,
                       "M2_SOURCES_GUARDED is not 1");
        }

        // H10 -- the shell's one focus tracker ----------------------------------------------------------------------------
        focusSrc.setFocused("A");
        root.settle(120);
        const lane1 = sharedNotif.holds.focusedScreen;
        focusSrc.setFocused("B");
        root.settle(120);
        root.check("H10 the service hands focusSource to its holds: the lane's screen is the tracker's focused screen",
                   lane1 === "A" && sharedNotif.holds.focusedScreen === "B", "A:" + lane1 + " B:" + sharedNotif.holds.focusedScreen);
        focusSrc.setFullscreen(true);
        root.settle(120);
        const hold1 = sharedNotif.holds.fullscreen && sharedNotif.holdReason === "fullscreen";
        focusSrc.setFullscreen(false);
        root.settle(120);
        root.check("H10 ... and the fullscreen hold reads its answer, with the service not live",
                   hold1 && !sharedNotif.holds.fullscreen && sharedNotif.holdReason === "",
                   "on:" + hold1 + " off:" + sharedNotif.holds.fullscreen + "/'" + sharedNotif.holdReason + "'");

        for (const S of [A, B]) {
            S.osdFromSource = true;
            S.osd.focusSource = focusSrc;
        }
        focusSrc.setFocused("A");
        root.settle(120);
        const act1 = A.osd.active && !B.osd.active;
        focusSrc.setFocused("B");
        root.settle(120);
        const act2 = !A.osd.active && B.osd.active;
        focusSrc.setFullscreen(true);
        root.settle(120);
        const fs1 = !A.osd.fullscreen && B.osd.fullscreen;
        // ... on a display osd.jsonc names (`screen`): there whatever has the focus, with ITS fullscreen; one that is not there: the focused one
        for (const S of [A, B])
            S.osd.screen = "A";
        root.settle(120);
        const named = A.osd.active && !B.osd.active && !A.osd.fullscreen;
        focusSrc.removeMonitor("A");
        root.settle(120);
        const gone = !A.osd.active && B.osd.active;
        focusSrc.addMonitor({ name: "A" });
        root.settle(120);
        const back = A.osd.active && !B.osd.active;
        for (const S of [A, B])
            S.osd.screen = "focused";
        focusSrc.setFullscreen(false);
        root.settle(120);
        root.check("H10 an OsdOwner given the tracker is active on the focused screen alone, and its fullscreen is its own screen's (no `active` or `fullscreen` assigned)",
                   act1 && act2 && fs1 && !A.osd.fullscreen && !B.osd.fullscreen,
                   "focus A: A/B active " + act1 + ", focus B: " + act2 + ", fullscreen B alone " + fs1);
        root.check("H10 ... a named display has it whatever the focus; unplugged, the focused one; plugged again, it is back", named && gone && back,
                   "named " + named + ", gone " + gone + ", back " + back);
        // fullscreen "keys": the pill for what the user did, nothing for news
        B.osd.pill = fakePill;
        B.osd.fullscreenMode = "keys";
        focusSrc.setFullscreen(true);
        root.settle(120);
        B.osd.present({ kind: "network", key: "network", ms: 60000, net: { ssid: "H", signal: 1, state: "lost" } });
        const news = fakePill.log.slice();
        B.osd.present({ kind: "theme", key: "theme", ms: 60000, theme: { name: "eva", mode: "dark" } });
        const key = fakePill.log.slice();
        B.osd.dismiss();
        focusSrc.setFullscreen(false);
        B.osd.pill = null;
        B.osd.fullscreenMode = "pill";
        root.settle(300);
        root.check("H10 ... fullscreen \"keys\": news is dropped, a key's card is on the pill", news.length === 0 && JSON.stringify(key) === '["theme"]',
                   JSON.stringify([news, key]));
        // an explicit `active` still wins (the mockup's way): the Binding is back
        for (const S of [A, B]) {
            S.osdFromSource = false;
            S.osdActive = false;
        }
        root.settle(120);
        root.check("H10 ... and the host's explicit switch overrides the default (the owner's own binding comes back when it lets go)",
                   !A.osd.active && !B.osd.active, "A " + A.osd.active + ", B " + B.osd.active);

        focusSrc.setFocused("A");
        root.settle(120);
        const scr1 = authOwner.screenName;
        focusSrc.setFocused("B");
        root.settle(120);
        const scr2 = authOwner.screenName;
        focusSrc.setFullscreen(true);
        root.settle(120);
        const reqPill = authBroker.open({ source: "polkit", title: "T", body: "b", user: "u", prompt: "Password: " }, { respond: () => {}, cancel: () => {} });
        root.settle(300);
        const wherePill = authOwner.where, pillId = authOwner.pillId;
        authBroker.finish(reqPill, "cancelled");
        root.settle(300);
        focusSrc.setFullscreen(false);
        root.settle(120);
        const reqToast = authBroker.open({ source: "polkit", title: "T", body: "b", user: "u", prompt: "Password: " }, { respond: () => {}, cancel: () => {} });
        root.settle(400);
        const whereToast = authOwner.where;
        authBroker.finish(reqToast, "cancelled");
        root.settle(300);
        root.check("H10 the one AuthOwner reads the tracker: its screen follows the focus, a request over a fullscreen window is the pill, otherwise the toast",
                   scr1 === "A" && scr2 === "B" && wherePill === "pill" && pillId === reqPill && whereToast === "toast",
                   "screen A:" + scr1 + " B:" + scr2 + ", fullscreen -> " + wherePill + ", else -> " + whereToast);

        console.log("M2 DONE checks=" + root.checks + " fails=" + root.fails);
        Qt.quit();
    }

    Timer {
        id: starter
        interval: 200
        running: root.armed
        onTriggered: root.run()
    }
    Component.onCompleted: {
        if (!root.armed) {
            console.log("M2 (not armed: run tools/dev/shell_hosted_m2_probe.sh)");
            quitter.start();
        }
    }
    Timer {
        id: quitter
        interval: 3000
        onTriggered: Qt.quit()
    }
}
