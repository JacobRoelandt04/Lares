pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import QtTest
import Quickshell

import "modules/bar/gooey"
import "modules/common/theme"
import "modules/clock"
import "modules/clock/data"
import "modules/stocks"
import "modules/stocks/data"
import "modules/silicon"
import "modules/silicon/data"
import "modules/notes"
import "modules/wiki"
import "modules/wiki/data"
import "modules/screentime/data"

// =============================================================================
// tools/dev/qml/shell_hosted_m1_probe.qml -- the clock, stocks, silicon and notes owners in SHELL-HOSTED
// mode (docs/contracts/shell.md section 4), on TWO screens over ONE set of services.
// Run by tools/dev/shell_hosted_m1_probe.sh, which stubs the four services that would touch the
// machine or the network (SiliconService, StocksService, WikiService, ScreentimeService:
// each is a few lines that carry the flags and nothing else) in a snapshot of the tree, so a
// hosted owner that wrongly BUILDS one of them is counted, and never reaches pkexec or a URL.
//
//   screen A, screen B   shellHosted, the same injected services (the shell's ShellServices)
//   screen D             shellHosted, NOTHING injected (a feature that is absent)
//   screen E             shellHosted false, its own injected mocks (a mockup's wiring)
//   bare owners          shellHosted false, NOTHING injected (the bar's own owners), made
//                        for a moment and counted
//
//   H1  hosted owners that were handed their services build none (a census of each owner's
//       subtree: TimerService, CalendarService, CalendarConfig, WikiService, ScreentimeService,
//       StocksService, SiliconService, NotesStore, DesktopNotifier, SoundPlayer, the silicon
//       watcher and notifier)
//   H2  ...and write no property of a service: a flag the host holds is still the host's after
//       every owner opened and closed its popup (true and false, on both screens)
//   H3  sharedFlags say what the owner would have written, in every state
//   H4  popupMine is per screen, though both screens' owners share an owner id
//   H5  a host that ORs the screens' flags keeps the service right while one screen closes
//       under another's open popup (the case the last writer loses)
//   H6  a service's unaddressed request reaches no hosted owner; the host's routed call does
//   H7  a hosted owner given NOTHING builds nothing, opens nothing without its service
//   H8  an owner that is not hosted does what it always did: builds its own, binds the
//       service's flags, answers the request
//   H9  notes: the injected store, a key-opened popup (grab wanted, pulse off), cleared closes
//   H10 stocks: the remembered detail is each screen's, for the session only, and decays after 10 minutes
//   H11 silicon: the per-window prewarm follows prewarmArmed, whose default is today's
//   H12 notes: one store under the popups of two screens stays awake until the last closes
// Prints `SHM PASS|FAIL <name>` per check and `SHELL_HOSTED_M1 RESULT PASS|FAIL`.
// =============================================================================
ShellRoot {
    id: root

    readonly property string notesRoot: Quickshell.env("NOTES_ROOT") || "/nonexistent"
    readonly property string stateDir: Quickshell.env("PROBE_STATE") || "/tmp"
    property int checks: 0
    property int fails: 0

    function check(name, ok, detail) {
        root.checks++;
        if (!ok)
            root.fails++;
        console.log("SHM " + (ok ? "PASS " : "FAIL ") + name + (detail !== undefined && detail !== "" ? "   " + detail : ""));
    }

    // ---- what is counted -----------------------------------------------------------------------
    readonly property var watched: ["TimerService", "CalendarService", "CalendarConfig", "WikiService", "ScreentimeService", "StocksService", "SiliconService", "NotesStore", "DesktopNotifier", "SoundPlayer", "SiliconMuxWatcher", "BlockedAppNotifier"]
    function typeOf(o) {
        return String(o).replace(/\(0x[0-9a-f]+\).*$/, "").replace(/_QMLTYPE.*$/, "").replace(/_QML_.*$/, "");
    }
    // Every watched object in `item`'s subtree: its children and resources, and what its Loaders hold.
    function census(item, out, seen) {
        out = out || ({});
        seen = seen || [];
        // A Loader's item is also one of its visual children: once.
        if (!item || seen.indexOf(item) >= 0)
            return out;
        seen.push(item);
        const t = root.typeOf(item);
        if (root.watched.indexOf(t) >= 0)
            out[t] = (out[t] || 0) + 1;
        const d = item.data;
        if (d)
            for (let i = 0; i < d.length; i++)
                root.census(d[i], out, seen);
        if (t === "QQuickLoader" && item.item)
            root.census(item.item, out, seen);
        return out;
    }
    function censusOf(owners) {
        const out = {};
        for (const o of owners) {
            const c = root.census(o);
            for (const k in c)
                out[k] = (out[k] || 0) + c[k];
        }
        return out;
    }
    function show(c) {
        const k = Object.keys(c).sort();
        return k.length ? k.map(n => n + " " + c[n]).join(", ") : "nothing";
    }
    // The first descendant of a type (the silicon prewarm).
    function find(item, type) {
        if (!item)
            return null;
        if (root.typeOf(item) === type)
            return item;
        const d = item.data;
        if (d)
            for (let i = 0; i < d.length; i++) {
                const f = root.find(d[i], type);
                if (f)
                    return f;
            }
        if (root.typeOf(item) === "QQuickLoader" && item.item)
            return root.find(item.item, type);
        return null;
    }

    // ---- one set of services: the shell's, or a mockup's ------------------------------------------
    component Services: Item {
        id: set
        required property string label
        required property string notesDir
        required property string stateDir
        readonly property alias calendar: cal
        readonly property alias timers: tm
        readonly property alias wiki: wk
        readonly property alias screentime: sc
        readonly property alias stocks: st
        readonly property alias silicon: si
        readonly property alias notes: nt
        MockCalendarData {
            id: cal
        }
        TimerService {
            id: tm
            persist: false
        }
        WikiMock {
            id: wk
        }
        ScreentimeMock {
            id: sc
        }
        StocksMock {
            id: st
        }
        SiliconMock {
            id: si
        }
        NotesStore {
            id: nt
            root: set.notesDir
            statePath: set.stateDir + "/session-" + set.label + ".json"
        }
    }

    // ---- one screen: an engine, a bar, the four buttons and the four owners ------------------------
    component Scene: Window {
        id: scene
        required property string label
        required property bool hosted
        required property var svcs
        required property string notesRoot
        required property string stateDir
        width: 900
        height: 640
        visible: true
        color: "#1F2229"

        readonly property alias engine: eng
        readonly property alias clockOwner: clockO
        readonly property alias stocksOwner: stocksO
        readonly property alias siliconOwner: silO
        readonly property alias notesOwner: notesO

        GooeyEngine {
            id: eng
            anchors.fill: parent
            surfaceColor: Theme.surface
            barsList: [bar]
            GooeyBar {
                id: bar
                engine: eng
                barId: "bar"
                edge: "top"
                rawPos: 0
                rawLen: eng.w
                ClockBarButton {
                    id: clockBtn
                    x: 100
                    y: (bar.height - height) / 2
                    fontFamily: "Audiowide"
                    horizontalPixelSize: 13
                }
                StocksBarButton {
                    id: stocksBtn
                    x: 280
                    y: (bar.height - height) / 2
                    owner: stocksO
                }
                SiliconBarButton {
                    id: silBtn
                    x: 460
                    y: (bar.height - height) / 2
                }
                NotesBarButton {
                    id: notesBtn
                    x: 640
                    y: (bar.height - height) / 2
                    owner: notesO
                }
            }
        }
        ClockBarOwner {
            id: clockO
            engine: eng
            bar: bar
            barId: "bar"
            anchorItem: clockBtn
            shellHosted: scene.hosted
            calendarService: scene.svcs ? scene.svcs.calendar : null
            timerService: scene.svcs ? scene.svcs.timers : null
            wikiService: scene.svcs ? scene.svcs.wiki : null
            screentimeService: scene.svcs ? scene.svcs.screentime : null
            // Asked for in every screen: nothing may build what it asks for when hosted or injected.
            wikiEnabled: true
            screentimeEnabled: true
        }
        StocksBarOwner {
            id: stocksO
            engine: eng
            bar: bar
            barId: "bar"
            anchorItem: stocksBtn
            shellHosted: scene.hosted
            service: scene.svcs ? scene.svcs.stocks : null
        }
        SiliconBarOwner {
            id: silO
            engine: eng
            bar: bar
            barId: "bar"
            anchorItem: silBtn
            shellHosted: scene.hosted
            service: scene.svcs ? scene.svcs.silicon : null
        }
        NotesBarOwner {
            id: notesO
            engine: eng
            bar: bar
            barId: "bar"
            anchorItem: notesBtn
            shellHosted: scene.hosted
            store: scene.svcs ? scene.svcs.notes : null
            notesRoot: scene.notesRoot
            statePath: scene.stateDir + "/session-own-" + scene.label + ".json"
        }
    }

    // ---- the bare, not-hosted owners (the bar's own): made for a moment and counted ---------------
    property bool bareOn: false
    Window {
        id: bareWin
        width: 100
        height: 100
        visible: true
        Loader {
            id: bareClock
            active: root.bareOn
            sourceComponent: Component {
                ClockBarOwner {
                    wikiEnabled: true
                    screentimeEnabled: true
                }
            }
        }
        Loader {
            id: bareStocks
            active: root.bareOn
            sourceComponent: Component {
                StocksBarOwner {}
            }
        }
        Loader {
            id: bareSilicon
            active: root.bareOn
            sourceComponent: Component {
                SiliconBarOwner {}
            }
        }
        Loader {
            id: bareNotes
            active: root.bareOn
            sourceComponent: Component {
                NotesBarOwner {
                    notesRoot: root.notesRoot
                    statePath: root.stateDir + "/session-bare.json"
                }
            }
        }
        // The services are items: they live in a window (a visual tree with none crashes Quickshell 0.3.1).
        Services {
            id: shared
            label: "shared"
            notesDir: root.notesRoot
            stateDir: root.stateDir
        }
        Services {
            id: own
            label: "own"
            notesDir: root.notesRoot
            stateDir: root.stateDir
        }
        TestCase {
            id: tc
            name: "hostedm1"
            when: false
        }
    }

    Scene {
        id: scA
        label: "SCR-A"
        hosted: true
        svcs: shared
        notesRoot: root.notesRoot
        stateDir: root.stateDir
    }
    Scene {
        id: scB
        label: "SCR-B"
        hosted: true
        svcs: shared
        notesRoot: root.notesRoot
        stateDir: root.stateDir
    }
    Scene {
        id: scD
        label: "SCR-D"
        hosted: true
        svcs: null
        notesRoot: root.notesRoot
        stateDir: root.stateDir
    }
    Scene {
        id: scE
        label: "SCR-E"
        hosted: false
        svcs: own
        notesRoot: root.notesRoot
        stateDir: root.stateDir
    }

    // The shell's aggregation (ShellServices): a service flag is the OR of every screen's sharedFlags.
    property bool aggregate: false
    Binding {
        target: shared.wiki
        property: "popupOpen"
        value: scA.clockOwner.sharedFlags.wikiPopupOpen || scB.clockOwner.sharedFlags.wikiPopupOpen
        when: root.aggregate
    }
    Binding {
        target: shared.timers
        property: "attended"
        value: scA.clockOwner.sharedFlags.timersAttended || scB.clockOwner.sharedFlags.timersAttended
        when: root.aggregate
    }
    Binding {
        target: shared.stocks
        property: "popupOpen"
        value: scA.stocksOwner.sharedFlags.popupOpen || scB.stocksOwner.sharedFlags.popupOpen
        when: root.aggregate
    }
    Binding {
        target: shared.silicon
        property: "popupOpen"
        value: scA.siliconOwner.sharedFlags.popupOpen || scB.siliconOwner.sharedFlags.popupOpen
        when: root.aggregate
    }

    // ---- helpers ---------------------------------------------------------------------------------
    function settle(pred, ms) {
        const end = Date.now() + (ms || 3000);
        while (Date.now() < end) {
            if (pred())
                return true;
            tc.wait(30);
        }
        return pred();
    }
    function closeAll() {
        for (const s of [scA, scB, scD, scE])
            if (s.engine.popupOpen)
                s.engine.close();
        root.settle(() => !scA.engine.popupOpen && !scB.engine.popupOpen && !scD.engine.popupOpen && !scE.engine.popupOpen, 4000);
    }
    // Open an owner on a screen and wait for the engine to take it.
    function openOwner(o) {
        o.open();
        root.settle(() => o.popupMine, 1500);
        tc.wait(150);
    }
    function closeOwner(s) {
        if (s.engine.popupOpen)
            s.engine.close();
        root.settle(() => !s.engine.popupOpen, 3000);
        tc.wait(100);
    }
    function ownersOf(s) {
        return [s.clockOwner, s.stocksOwner, s.siliconOwner, s.notesOwner];
    }

    // ---- the script ------------------------------------------------------------------------------
    function run() {
        tc.wait(600);

        // ===== H1  hosted, handed their services: they build none
        let c = root.censusOf(root.ownersOf(scA).concat(root.ownersOf(scB)));
        root.check("H1 hosted owners handed their services build none of them", Object.keys(c).length === 0, root.show(c));
        root.check("H1b ...and use the services they were handed",
                   scA.clockOwner.timers === shared.timers && scB.clockOwner.calendarData === shared.calendar
                   && scA.clockOwner.wiki === shared.wiki && scB.clockOwner.screentime === shared.screentime
                   && scA.stocksOwner.svc === shared.stocks && scB.siliconOwner.svc === shared.silicon
                   && scA.notesOwner.activeStore === shared.notes && scB.notesOwner.activeStore === shared.notes, "");

        // ===== H2  ...and write no property of a service
        let bad = [];
        const sentinel = v => {
            shared.wiki.popupOpen = v;
            shared.timers.attended = v;
            shared.stocks.popupOpen = v;
            shared.silicon.popupOpen = v;
        };
        const flagsAre = v => {
            const w = [];
            if (shared.wiki.popupOpen !== v) w.push("wiki.popupOpen");
            if (shared.timers.attended !== v) w.push("timers.attended");
            if (shared.stocks.popupOpen !== v) w.push("stocks.popupOpen");
            if (shared.silicon.popupOpen !== v) w.push("silicon.popupOpen");
            return w;
        };
        for (const v of [true, false]) {
            for (const s of [scA, scB]) {
                sentinel(v);
                s.clockOwner.currentTab = "timers";
                for (const o of [s.clockOwner, s.stocksOwner, s.siliconOwner]) {
                    root.openOwner(o);
                    // open: what an unhosted owner would have written is on the service now
                    const open = flagsAre(v);
                    root.closeOwner(s);
                    const closed = flagsAre(v);
                    for (const n of open.concat(closed))
                        if (bad.indexOf(s.label + " " + n) < 0)
                            bad.push(s.label + " " + n);
                }
                s.clockOwner.currentTab = "calendar";
            }
        }
        sentinel(false);
        root.check("H2 hosted owners write no property of a service (held true and false, opened and closed on both screens)", bad.length === 0, bad.join(", "));

        // ===== H3 / H4  sharedFlags, and popupMine per screen
        const all = s => ({
                clock: s.clockOwner.sharedFlags,
                stocks: s.stocksOwner.sharedFlags,
                silicon: s.siliconOwner.sharedFlags,
                notes: s.notesOwner.sharedFlags
            });
        let a = all(scA), b = all(scB);
        root.check("H3a closed: every flag false, notes' flags empty",
                   a.clock.wikiPopupOpen === false && a.clock.timersAttended === false && a.stocks.popupOpen === false && a.silicon.popupOpen === false
                   && Object.keys(a.notes).length === 0 && b.stocks.popupOpen === false, JSON.stringify([a.clock, a.stocks, a.silicon, a.notes]));
        root.openOwner(scA.clockOwner);
        a = all(scA); b = all(scB);
        root.check("H3b clock open on the calendar tab: wikiPopupOpen true, timersAttended false", a.clock.wikiPopupOpen === true && a.clock.timersAttended === false, JSON.stringify(a.clock));
        root.check("H4 popupMine is this screen's: A is the clock's, B is not (one owner id on two engines)",
                   scA.clockOwner.popupMine === true && scB.clockOwner.popupMine === false && b.clock.wikiPopupOpen === false, "");
        scA.clockOwner.currentTab = "timers";
        a = all(scA);
        root.check("H3c ...on the Timers tab: timersAttended true", a.clock.timersAttended === true && a.clock.wikiPopupOpen === true, JSON.stringify(a.clock));
        root.openOwner(scB.clockOwner);
        a = all(scA); b = all(scB);
        root.check("H3d both screens open: A on timers, B on the calendar",
                   a.clock.timersAttended === true && b.clock.wikiPopupOpen === true && b.clock.timersAttended === false, JSON.stringify([a.clock, b.clock]));
        root.closeOwner(scA);
        root.closeOwner(scB);
        scA.clockOwner.currentTab = "calendar";
        root.openOwner(scB.stocksOwner);
        root.check("H3e stocks open on B only: B's flag true, A's false", all(scB).stocks.popupOpen === true && all(scA).stocks.popupOpen === false && scB.stocksOwner.popupMine && !scA.stocksOwner.popupMine, "");
        root.closeOwner(scB);
        root.openOwner(scA.siliconOwner);
        root.check("H3f silicon open on A only: A's flag true, B's false", all(scA).silicon.popupOpen === true && all(scB).silicon.popupOpen === false && scA.siliconOwner.popupMine && !scB.siliconOwner.popupMine, "");
        root.closeOwner(scA);
        root.check("H3g closed again: every flag false", all(scA).silicon.popupOpen === false && all(scA).stocks.popupOpen === false && all(scA).clock.wikiPopupOpen === false, "");

        // ===== H5  the host ORs the screens' flags
        root.aggregate = true;
        tc.wait(100);
        const svcFlags = () => [shared.stocks.popupOpen, shared.silicon.popupOpen, shared.wiki.popupOpen, shared.timers.attended].join(",");
        root.check("H5a nothing open: the services' flags are false", svcFlags() === "false,false,false,false", svcFlags());
        scA.clockOwner.currentTab = "timers";
        root.openOwner(scA.stocksOwner);
        root.openOwner(scB.stocksOwner);
        root.check("H5b stocks open on both screens: the service's flag is true", shared.stocks.popupOpen === true, svcFlags());
        root.closeOwner(scA);
        root.check("H5c A closes under B's open popup: the service stays true (a last writer would have said false)", shared.stocks.popupOpen === true, svcFlags());
        root.closeOwner(scB);
        root.check("H5d both closed: false", shared.stocks.popupOpen === false, svcFlags());
        root.openOwner(scA.clockOwner);
        root.openOwner(scB.clockOwner);
        root.check("H5e clock on A (timers tab) and B (calendar): wiki.popupOpen and timers.attended true", shared.wiki.popupOpen === true && shared.timers.attended === true, svcFlags());
        scA.clockOwner.currentTab = "calendar";
        root.check("H5f A leaves the timers tab, B never was on it: attended false, the wiki still open", shared.timers.attended === false && shared.wiki.popupOpen === true, svcFlags());
        root.closeOwner(scA);
        root.check("H5g A closes under B: wiki.popupOpen stays true", shared.wiki.popupOpen === true, svcFlags());
        root.closeOwner(scB);
        root.openOwner(scA.siliconOwner);
        root.openOwner(scB.siliconOwner);
        root.closeOwner(scA);
        root.check("H5h silicon: A closes under B, the flag stays true", shared.silicon.popupOpen === true, svcFlags());
        root.closeOwner(scB);
        root.check("H5i silicon: both closed, false", shared.silicon.popupOpen === false, svcFlags());
        root.aggregate = false;
        tc.wait(50);

        // ===== H6  a request reaches no hosted owner; the host's routed call does
        root.closeAll();
        shared.wiki.openRequested("deepen");
        shared.stocks.alertOpenRequested("AAPL");
        tc.wait(500);
        root.check("H6a wiki.openRequested and stocks.alertOpenRequested open nothing on a hosted screen",
                   !scA.clockOwner.popupMine && !scB.clockOwner.popupMine && !scA.stocksOwner.popupMine && !scB.stocksOwner.popupMine
                   && !scA.engine.popupOpen && !scB.engine.popupOpen, "");
        scB.clockOwner.openWiki("deepen");
        root.settle(() => scB.clockOwner.popupMine, 1500);
        root.check("H6b the host's routed call (openWiki on the focused screen's owner) opens it there only", scB.clockOwner.popupMine && !scA.clockOwner.popupMine, "");
        root.closeOwner(scB);
        scA.stocksOwner.openSymbol("AAPL");
        root.settle(() => scA.stocksOwner.popupMine, 1500);
        root.check("H6c ...and openSymbol for the stocks alert", scA.stocksOwner.popupMine && !scB.stocksOwner.popupMine, "");
        root.closeOwner(scA);

        // ===== H7  hosted with NOTHING injected: nothing is built, nothing opens
        const d = root.ownersOf(scD);
        c = root.censusOf(d);
        root.check("H7a hosted owners handed nothing build nothing (the wiki and the screentime asked for, too)", Object.keys(c).length === 0, root.show(c));
        root.check("H7b ...a null service is an absent feature: no timers, calendar, wiki, screentime, stocks, silicon, store",
                   scD.clockOwner.timers === null && scD.clockOwner.calendarData === null && scD.clockOwner.wiki === null && scD.clockOwner.screentime === null
                   && scD.stocksOwner.svc === null && scD.siliconOwner.svc === null && scD.siliconOwner.ownsService === false && scD.notesOwner.activeStore === null, "");
        scD.clockOwner.open();
        root.settle(() => scD.clockOwner.popupMine, 1500);
        tc.wait(300);
        root.closeOwner(scD);
        scD.stocksOwner.open();
        scD.siliconOwner.open();
        scD.notesOwner.open();
        scD.notesOwner.shortcutPressed();
        tc.wait(300);
        root.check("H7c ...and without its service a hosted owner opens no popup (stocks, silicon, notes, the notes key)",
                   !scD.stocksOwner.popupMine && !scD.siliconOwner.popupMine && !scD.notesOwner.popupMine && !scD.notesOwner.keyOpened, "");
        root.closeAll();

        // ===== H8  not hosted: what it always did
        c = root.censusOf(root.ownersOf(scE));
        root.check("H8a an owner handed its services builds none of them, and keeps its watchers (silicon: the mux watcher and the blocked-app notifier, each with its DesktopNotifier) and its config reader (clock)",
                   root.show(c) === "BlockedAppNotifier 1, CalendarConfig 1, DesktopNotifier 2, SiliconMuxWatcher 1", root.show(c));
        root.bareOn = true;
        tc.wait(500);
        const bareC = root.census(bareClock.item), bareS = root.census(bareStocks.item), bareL = root.census(bareSilicon.item), bareN = root.census(bareNotes.item);
        root.check("H8b the bar's own clock, given nothing, builds its timers (with their notifier and sound), calendar, config, wiki (and its notifier) and screentime",
                   root.show(bareC) === "CalendarConfig 1, CalendarService 1, DesktopNotifier 2, ScreentimeService 1, SoundPlayer 1, TimerService 1, WikiService 1", root.show(bareC));
        root.check("H8c ...stocks its service and its alert notifier", root.show(bareS) === "DesktopNotifier 1, StocksService 1", root.show(bareS));
        root.check("H8d ...silicon its service, the watcher and the blocked-app notifier (the service is the stub here: the real one calls pkexec)",
                   root.show(bareL) === "BlockedAppNotifier 1, DesktopNotifier 2, SiliconMuxWatcher 1, SiliconService 1", root.show(bareL));
        root.check("H8e ...notes its store", root.show(bareN) === "NotesStore 1", root.show(bareN));
        root.check("H8f ...and notes' store is the owner's own, reached as activeStore", bareNotes.item.activeStore !== null && bareNotes.item.store === null, "");
        // the silicon prewarm default: an owner that runs the real service arms it
        root.check("H11a prewarmArmed defaults to ownsService: an owner that runs the service itself arms the prewarm (wired once its button is)",
                   bareSilicon.item.ownsService === true && bareSilicon.item.prewarmArmed === true, "");
        root.bareOn = false;
        tc.wait(200);

        // old behaviour: the flags follow popupMine, the request opens the popup
        shared.wiki.popupOpen = false;
        own.wiki.popupOpen = false;
        own.timers.attended = false;
        root.openOwner(scE.stocksOwner);
        root.check("H8g unhosted stocks writes the service's popupOpen", own.stocks.popupOpen === true && scE.stocksOwner.sharedFlags.popupOpen === true, "");
        root.closeOwner(scE);
        root.check("H8h ...and takes it back on close", own.stocks.popupOpen === false, "");
        scE.clockOwner.currentTab = "timers";
        root.openOwner(scE.clockOwner);
        root.check("H8i unhosted clock writes wiki.popupOpen and timers.attended (and says the same in sharedFlags)",
                   own.wiki.popupOpen === true && own.timers.attended === true && scE.clockOwner.sharedFlags.wikiPopupOpen && scE.clockOwner.sharedFlags.timersAttended, "");
        root.closeOwner(scE);
        scE.clockOwner.currentTab = "calendar";
        root.openOwner(scE.siliconOwner);
        root.check("H8j unhosted silicon writes the service's popupOpen", own.silicon.popupOpen === true, "");
        root.closeOwner(scE);
        own.wiki.openRequested("discover");
        root.settle(() => scE.clockOwner.popupMine, 1500);
        root.check("H8k unhosted clock opens on wiki.openRequested (the owner's own Connections)", scE.clockOwner.popupMine, "");
        root.closeOwner(scE);
        own.stocks.alertOpenRequested("AAPL");
        root.settle(() => scE.stocksOwner.popupMine, 1500);
        root.check("H8l unhosted stocks opens on alertOpenRequested", scE.stocksOwner.popupMine, "");
        root.closeOwner(scE);

        // ===== H9  notes: the injected store and the key-opened popup
        root.check("H9a hosted notes uses the one injected store on both screens", scA.notesOwner.activeStore === shared.notes && scB.notesOwner.activeStore === shared.notes && scA.notesOwner.store === shared.notes, "");
        scA.notesOwner.shortcutPressed();
        root.settle(() => scA.notesOwner.popupMine, 1500);
        tc.wait(300);
        let pop = scA.engine.thePopup ? scA.engine.thePopup.contentItem : null;
        root.check("H9b the shortcut opens a KEY-opened popup (keyOpened) on A only", scA.notesOwner.popupMine && scA.notesOwner.keyOpened && !scB.notesOwner.popupMine && !scB.notesOwner.keyOpened, "");
        root.check("H9c ...whose pulse is off (the grab holds the keyboard: a pulse would hand it to the window under the pointer)", !!pop && pop.grabKeyboard === false, pop ? String(pop.grabKeyboard) : "no popup");
        scA.notesOwner.keyGrab.cleared();
        root.settle(() => !scA.notesOwner.popupMine, 3000);
        root.check("H9d a cleared grab (a click outside) closes it, and it is no longer key-opened", !scA.notesOwner.popupMine && !scA.notesOwner.keyOpened, "");
        scB.notesOwner.shortcutPressed();
        root.settle(() => scB.notesOwner.popupMine, 1500);
        scB.notesOwner.shortcutPressed();
        root.settle(() => !scB.notesOwner.popupMine, 3000);
        root.check("H9e the shortcut pressed again closes it", !scB.notesOwner.popupMine && !scB.notesOwner.keyOpened, "");
        scA.notesOwner.toggle();
        root.settle(() => scA.notesOwner.popupMine, 1500);
        tc.wait(300);
        pop = scA.engine.thePopup ? scA.engine.thePopup.contentItem : null;
        root.check("H9f the click path (toggle) is not key-opened and keeps the pulse", scA.notesOwner.popupMine && !scA.notesOwner.keyOpened && !!pop && pop.grabKeyboard === true, pop ? String(pop.grabKeyboard) : "no popup");
        scA.notesOwner.shortcutPressed();
        root.settle(() => !scA.notesOwner.popupMine, 3000);
        root.check("H9g the shortcut on a popup the click opened closes it", !scA.notesOwner.popupMine, "");
        root.closeAll();

        // ===== H10  stocks: the remembered detail is each screen's, in memory for the session, and decays (the user, 2026-11-12)
        const memA = scA.stocksOwner.detailMemory, memB = scB.stocksOwner.detailMemory;
        memA.remember(true, { symbol: "AAPL", from: "holdings" });
        const fresh10 = memA.restorable() && !memB.restorable();
        memA._seenMs = Date.now() - 11 * 60000;                   // last on screen 11 minutes ago
        const stale10 = memA.restorable();
        memA.seen();                                              // the popup goes with it out: shown until now
        const reseen10 = memA.restorable();
        memA.forget();
        root.check("H10 each screen remembers its own detail, in memory only (no file); one last shown 11 minutes ago does not come back, seen() restarts the 10 minutes",
                   fresh10 && !stale10 && reseen10 && !("statePath" in memA) && scA.stocksOwner.detailDecayMs === 600000,
                   "fresh " + fresh10 + " stale " + stale10 + " reseen " + reseen10 + " decay " + scA.stocksOwner.detailDecayMs);

        // ===== H11  silicon: the prewarm is armed per window by the host
        // SiliconPrewarm is re-parented onto the owner's anchor item (pipelines link per window): look there.
        const warmB = root.find(scB.siliconOwner.anchorItem, "SiliconPrewarm");
        const warmA = root.find(scA.siliconOwner.anchorItem, "SiliconPrewarm");
        root.check("H11b a hosted owner does not arm the prewarm by itself (ownsService is false)", !!warmA && !!warmB && warmA.armed === false && warmB.armed === false && scB.siliconOwner.prewarmArmed === false, "");
        scB.siliconOwner.prewarmArmed = true;
        tc.wait(50);
        const armedB = warmB.armed;
        scB.siliconOwner.prewarmArmed = false;
        tc.wait(50);
        root.check("H11c ...the host arms it on a window by setting prewarmArmed (disarmed again here: the warm-up draws a whole popup after 6 s)", armedB === true && warmB.armed === false, "armed " + armedB);

        // ===== H12  one store under two popups: the first to close must not stop the watching under the other
        root.closeAll();
        scA.notesOwner.toggle();
        scB.notesOwner.toggle();
        root.settle(() => scA.notesOwner.popupMine && scB.notesOwner.popupMine, 2000);
        root.settle(() => shared.notes.holders === 2, 2000);
        const both = shared.notes.active && shared.notes.holders === 2;
        root.closeOwner(scA);
        // a popup's content goes when its close animation ends, a little after the engine says it is closed
        root.settle(() => shared.notes.holders === 1, 3000);
        const stillB = shared.notes.active && shared.notes.holders === 1 && scB.notesOwner.popupMine;
        root.closeOwner(scB);
        root.settle(() => shared.notes.holders === 0, 3000);
        root.check("H12 one store under two screens' popups: awake while either is open, asleep when the last has closed",
                   both && stillB && !shared.notes.active && shared.notes.holders === 0, "both " + both + ", B alone " + stillB + ", after " + shared.notes.active + " / " + shared.notes.holders);

        console.log("SHELL_HOSTED_M1 RESULT " + (root.fails === 0 ? "PASS" : "FAIL") + "  " + (root.checks - root.fails) + "/" + root.checks + " checks");
        quitTimer.start();
    }

    Timer {
        interval: 1500
        running: true
        onTriggered: {
            scA.requestActivate();
            try {
                root.run();
            } catch (e) {
                root.check("EXCEPTION", false, String(e) + " " + e.stack);
                console.log("SHELL_HOSTED_M1 RESULT FAIL");
                quitTimer.start();
            }
        }
    }
    Timer {
        id: quitTimer
        interval: 0
        onTriggered: Qt.quit()
    }
}
