pragma ComponentBehavior: Bound

import QtQuick
import QtTest
import Quickshell

import "modules/common/theme"
import "modules/common/components"
import "modules/bar/gooey"
import "modules/bar/reel"
import "modules/idle"
import "modules/windowtray"
import "modules/windowtray/data"
import "modules/launcher/data"
import "modules/shell/ReelItems.js" as ReelItems

// =============================================================================
// tray_reel_probe.qml -- the tray's strip in the engine's REEL SLOT (feedback window+tray "Tray should be reel like popup type";
// tools/dev/tray_reel_probe.sh runs it in a sandbox copy, offscreen): a real GooeyEngine with one top bar, the idle ReelBarModule
// with its ReelFollow over a MOCK IdleService (live: false), the window title + tray (WindowTitleButton, WindowTrayOwner, the mock
// tray with an item whose menu nests three deep), and a regular popup (a red ground, a field, a secondary of its own).
//
//   T1  the popup out, the pointer on the title: the strip opens in the reel slot and the popup stays (owner and phase, every tick)
//   T2  the strip's ground over the popup (THE REEL PASS's fill): the pass draws on the one popup under the strip, and a point of the
//       strip over the popup's red is the surface (the runner reads the grab)
//   T3  the label, the menu, the submenu and its submenu are the reel slot's chain (levels 1..3, each the child of the one before),
//       the popup and ITS secondary untouched; the keys are the menu's (keyboardFocus), Escape through the engine closes the
//       deepest level each time and then the strip, never the popup; the popup's field has its focus back
//   T4  the idle strip out, the pointer to the title quickly: ONE travel (the slot never closed), the strip the tray's; and the pass's
//       ink for the strip stays whole through it (the content is swapped under a body that stands: the ring must not blink)
//   T5  slowly (the idle strip gone first): a fresh open
//   T6  an automatic switch while the strip is out: the cinematic waits (no turn, not even in the cell), the strip stays; the
//       pointer leaves, the strip closes, and only then the cinematic plays (the idle strip out, the turn)
//   T7  the pointer on the title while the cinematic plays: the strip does not open until it has ended, then it does
//   T8  the session locks with the strip out: it goes, and none opens while locked
//   T9  THE REEL PASS: the strip over the popup has its ring (a pixel 2 px off its side, below the joint with the bar, is the border
//       colour) and its halo (the popup's red is darker 5 px off it than far away); the pass has the strip, its bar and the popup, and the
//       strip's two fillets with the bar (the runner reads the pixels)
//   T12 windowtray.jsonc trayPassive "hide": a passive item is no row until it is active again
//   T11 the engine's prewarm warms the pass: its effect is drawn for a few frames with no tile (the pipeline is built then, not in the
//       middle of a strip's first opening over a popup), and drawing nothing it is on no popup
//   T10 ... and the ring goes with the merge: closing, the pass's ink for the strip falls monotonically from 1 to 0 over a real span of
//       frames (no pop), and a frame held at half the fade shows the ring at about half (the runner reads the pixel)
//
// Prints `TRAYREEL ok|FAIL <check>`, `TRAYREEL ground <x> <y> <png>` (the runner's pixel) and `TRAYREEL RESULT PASS|FAIL (<n>/<n>)`.
// =============================================================================
ShellRoot {
    FloatingWindow {
        id: win
        implicitWidth: 960
        implicitHeight: 620
        visible: true
        color: Theme.surface

        TestCase {
            id: tc
            when: false
        }

        IconReelStyle {
            id: sharedStyle
        }
        WindowTrayStyle {
            id: trayStyle
        }
        AppLookup {
            id: lookup
        }
        property var trayConfig: ({ follow: "focus", stripSuffix: true, rewrites: [], trayOrder: [], trayHide: [], trayRename: {},
                                    terminalClasses: ["kitty"], terminalTitleMs: 0 })
        ActiveWindowMock {
            id: mockWindow
            config: win.trayConfig
            appLookup: lookup
        }
        TrayMock {
            id: mockTray
            config: win.trayConfig
            appLookup: lookup
        }

        GooeyEngine {
            id: engine
            anchors.fill: parent
            surfaceColor: Theme.surface
            // the shell's edge as shell.jsonc's halo + border have it (T9, T10)
            shadowReach: 28
            shadowStrength: 0.3
            shadowSpread: -20
            shadowSoftness: 0.6
            shadowBlend: 12
            borderWidth: 3
            barsList: [topBar]

            GooeyBar {
                id: topBar
                engine: engine
                barId: "topBar"
                edge: "top"
                rawPos: 0
                rawLen: engine.w

                ReelBarModule {
                    id: idleMod
                    x: 60
                    engine: engine
                    bar: topBar
                    barId: "topBar"
                    ownerId: "idle"
                    style: sharedStyle
                    items: ReelItems.IDLE
                    leftClickActivates: true
                    burstOnActivate: false
                    autoHeld: svc.autoActive
                }
                WindowTitleButton {
                    id: titleButton
                    x: 300
                    owner: trayOwner
                    window: mockWindow
                    tray: mockTray
                    appLookup: lookup
                    style: trayStyle
                    thickness: topBar.height
                    barRotation: topBar.rotation
                    ground: engine.surfaceColor
                }
            }
        }

        WindowTrayOwner {
            id: trayOwner
            engine: engine
            bar: topBar
            barId: "topBar"
            ownerId: "windowtray"
            window: mockWindow
            tray: mockTray
            appLookup: lookup
            config: win.trayConfig
            style: trayStyle
            reelStyle: sharedStyle
            reelBusy: idleMod.autoOpen
        }

        ReelFollow {
            id: follow
            module: idleMod
            target: svc.mode
            automatic: svc.autoActive
            reason: svc.autoReason
            readMs: 900
            readAfterMs: 300
            travelMs: 700
        }
        IdleService {
            id: svc
            live: false
            auto.onMs: 250
            auto.offMs: 600
        }

        // ---- the regular popup: a red ground (what must not show through the strip), a field, a secondary of its own ----------
        property Item popupField: null
        Component {
            id: popupComp
            Item {
                id: pop
                implicitWidth: 380
                implicitHeight: 300
                property Component secondaryComponent: Component {
                    Rectangle {
                        implicitWidth: 160
                        implicitHeight: 120
                        color: "#2040C0"
                    }
                }
                property bool secondaryOpen: true
                property point secondaryAnchor: Qt.point(pop.width, 80)
                property string secondarySide: "end"
                Rectangle {
                    anchors.fill: parent
                    color: "#FF0000"
                }
                TextInput {
                    id: field
                    x: 220
                    y: 260
                    width: 120
                    text: "typing"
                    Component.onCompleted: win.popupField = field
                }
            }
        }

        // A tray item whose menu nests three deep (nm-applet's, with a level below "Network 3": the overshoot harness's).
        readonly property var deepSpec: ({
            id: "probe-deep", title: "Deep menus", icon: "", status: "Active", category: "ApplicationStatus",
            menu: [{ text: "Header", enabled: false }, { isSeparator: true },
                   { text: "_Available networks", children: [{ text: "Network 2" },
                       { text: "Network 3", children: [{ text: "Connect" }, { text: "Forget" }] },
                       { text: "Network 4" }] },
                   { text: "Edit Connections…" }]
        })
        property string deepKey: ""

        // ---- helpers --------------------------------------------------------------------------------------------------------
        readonly property string grabDir: Quickshell.env("GRAB_DIR") || ""
        property int checks: 0
        property int fails: 0
        function check(name: string, ok: bool, detail: var): void {
            win.checks++;
            if (!ok)
                win.fails++;
            console.log("TRAYREEL " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  (" + detail + ")"));
        }
        function centreOf(it: Item): point {
            return it.mapToItem(win.contentItem, it.width / 2, it.height / 2);
        }
        // onto an item as a hand comes: an entry, then a motion
        function hoverOn(it: Item): void {
            const p = win.centreOf(it);
            tc.mouseMove(win.contentItem, p.x - 3, p.y);
            tc.mouseMove(win.contentItem, p.x, p.y);
        }
        function away(): void {
            tc.mouseMove(win.contentItem, 900, 600);
        }
        function openPopup(): void {
            engine.open("probe", "topBar", 400, null, null, false, popupComp, 0.5);
        }
        // Open the owner's level L (0: the item's menu; L: the first submenu row of level L - 1).
        function trayLevel(L: int): void {
            if (L === 0) {
                trayOwner.openMenu(win.deepKey);
                return;
            }
            const P = L - 1, slot = trayOwner.levelSlot[P];
            const m = trayOwner.menuModelOf(P, slot);
            for (let i = 0; i < m.rows.count; i++) {
                const d = trayOwner._rowAt(P, i);
                if (d && d.submenu && !d.disabled) {
                    trayOwner.menuPick(P, slot, i, d, trayOwner._keyRowY(P, i));
                    return;
                }
            }
        }
        function chainState(): string {
            return engine.reelChildPopups.map(C => C.phase + (C.parentSlot ? "<" + engine._bodyIdOf(C.parentSlot) : "")).join(" ");
        }

        // the per-tick record of the step in progress (a var mutated in place: nothing binds to it)
        property var rec: ({})
        // T11: the pass's warm-up, as it starts
        property var warm: null
        Connections {
            target: engine.reelCast
            function onWarmingChanged() {
                if (win.warm && engine.reelCast.warming) {
                    win.warm.seen = true;
                    win.warm.count = engine.reelCast.count;
                }
            }
        }
        // T4: the strip's content fade and the pass's ink for it, at every step of the fade (never sampled: a tick can miss a 160 ms fade)
        Connections {
            target: engine.theReel
            function onContentOpacityChanged() {
                const sw = win.rec ? win.rec.swap : null;
                if (!sw)
                    return;
                sw.minOp = Math.min(sw.minOp, engine.theReel.contentOpacity);
                sw.minInk = Math.min(sw.minInk, engine.reelCast.ink.x);
            }
        }
        function watch(): void {
            const r = win.rec;
            if (r.popup !== undefined && (!engine.popupOpen || engine.popupOwnerId !== "probe" || engine.thePopup.phase !== "open"))
                r.popupLeft = (r.popupLeft || 0) + 1;
            const ph = engine.reelPhase + ":" + engine.reelOwnerId;
            if (r.phases && r.phases[r.phases.length - 1] !== ph)
                r.phases.push(ph);
            if (r.trayDuringCine !== undefined && idleMod.autoOpen && engine.reelOwnerId === "windowtray" && engine.reelPhase !== "closed")
                r.trayDuringCine++;
        }

        // ---- the sequence -------------------------------------------------------------------------------------------------
        property int at: -1
        property int ticks: 0
        property bool acted: false
        property var mark: ({})
        readonly property var seq: [
            { act: () => {
                  mockWindow.setWindow({ cls: "kitty", title: "~/.config/quickshell", initialTitle: "kitty" });
                  win.deepKey = mockTray.add(win.deepSpec);
              }, cond: () => engine.w > 0 && topBar.thickness > 0 && !mockTray.empty, wait: 10 },
            // ---- T1: a popup out, the pointer on the title
            { act: () => win.openPopup(), cond: () => engine.popupOpen && engine.thePopup.phase === "open" && engine.childPopups[0].phase === "open" },
            { act: () => { win.popupField.forceActiveFocus(); win.rec = { popup: true }; win.hoverOn(titleButton.iconCell); },
              cond: () => { win.watch(); return engine.reelOpen && engine.reelOwnerId === "windowtray" && engine.reelPhase === "open" && !!trayOwner.strip; },
              then: () => {
                  win.check("T1 the strip opened in the reel slot (the tray's owner, open)", engine.reelOwnerId === "windowtray" && trayOwner.popupMine, engine.reelOwnerId);
                  win.check("T1 the popup under it stayed out on every tick (owner, phase), its secondary too",
                            !win.rec.popupLeft && engine.popupOwnerId === "probe" && engine.childPopups[0].phase === "open",
                            "left " + win.rec.popupLeft + " owner " + engine.popupOwnerId + " child " + engine.childPopups[0].phase);
              } },
            // ---- T2: the strip's ground over the popup (the runner reads the pixel)
            { act: () => {}, wait: 5,
              then: () => {
                  const s = engine.theReel.box, p = engine.thePopup.box;
                  const x0 = Math.max(s.x0, p.x0), x1 = Math.min(s.x1, p.x1), y0 = Math.max(s.y0, p.y0), y1 = Math.min(s.y1, p.y1);
                  const over = x1 - x0 > 8 && y1 - y0 > 8;
                  win.check("T2 the strip lies over the popup (the scene the ground is for)", over, JSON.stringify({ s: s, p: p }));
                  win.check("T2 the reel pass draws its fill on the one popup under the strip", engine.reelCast.count === 1 && engine.reelCast.drawn.shape > 0,
                            JSON.stringify(engine.reelCast.drawn));
                  if (over && win.grabDir !== "") {
                      // between two icons, 4 px in from the strip's side: surface, never the popup's red
                      const gx = Math.round(x0 + 4), gy = Math.round((y0 + y1) / 2);
                      engine.grabToImage(r => {
                          const f = win.grabDir + "/ground.png";
                          console.log("TRAYREEL ground " + gx + " " + gy + " " + (r.saveToFile(f) ? f : "FAILED"));
                      });
                  }
              } },
            // ---- T9: the strip's ring and halo over the popup (the runner reads the pixels)
            { act: () => {}, cond: () => engine.theReel.contentOpacity >= 0.999 && engine.theReel.phase === "open", wait: 10,
              then: () => {
                  const s = engine.theReel.box, p = engine.thePopup.box;
                  const dr = engine.reelCast.drawn;
                  win.check("T9 the reel pass has the strip, its bar, the popup and the strip's two fillets with the bar",
                            engine.reelCast.count === 1 && dr.group === 1 && dr.bars >= 1 && dr.pops >= 1 && dr.fillets >= 2 && dr.halo > 0, JSON.stringify(dr));
                  if (win.grabDir !== "") {
                      const x = Math.round(s.x0), y = Math.round(s.y0 + 40);
                      engine.grabToImage(r => {
                          const f = win.grabDir + "/ring.png";
                          console.log("TRAYREEL shot ring " + (r.saveToFile(f) ? f : "FAILED") + " " + (x - 2) + " " + y + " " + (x - 5) + " " + y
                                      + " " + Math.round(Math.max(p.x0 + 2, x - 80)) + " " + y + " " + Theme.shellBorder);
                      });
                  }
              } },
            // ---- T3: the three levels in the slot, the keys, Escape
            { act: () => win.trayLevel(0), cond: () => trayOwner.menuOpen && engine.reelChildPopups[0].phase === "open" },
            { act: () => win.trayLevel(1), cond: () => trayOwner.levelOpen[1] && engine.reelChildPopups[1].phase === "open" },
            { act: () => win.trayLevel(2), cond: () => trayOwner.levelOpen[2] && engine.reelChildPopups[2].phase === "open",
              then: () => {
                  const L = engine.reelChildPopups;
                  win.check("T3 the menu, the submenu and its submenu are the reel slot's chain, each the child of the one before",
                            L[0].parentSlot === engine.theReel && L[1].parentSlot === L[0] && L[2].parentSlot === L[1], win.chainState());
                  win.check("T3 the popup and its secondary untouched, the popup's chain holds no tray level",
                            engine.popupOwnerId === "probe" && engine.thePopup.phase === "open" && engine.childPopups[0].phase === "open"
                            && engine.childPopups[1].phase === "closed", engine.popupOwnerId + " " + engine.childPopups.map(C => C.phase).join(","));
                  win.check("T3 the keys are the menu's (the layer asks onDemand, the strip has the focus)",
                            engine.keyboardFocus === "onDemand" && !!trayOwner.strip && trayOwner.strip.activeFocus,
                            engine.keyboardFocus + " strip focus " + (trayOwner.strip ? trayOwner.strip.activeFocus : "-"));
              } },
            { act: () => { win.mark = { r: engine.pressEscape() }; }, cond: () => engine.reelChildPopups[2].phase === "closed",
              then: () => win.check("T3 Escape (the engine's, a popup under the strip) closes the deepest level, not the popup",
                                    win.mark.r && engine.reelChildPopups[1].phase === "open" && engine.popupOwnerId === "probe" && engine.thePopup.phase === "open",
                                    win.chainState() + " popup " + engine.popupOwnerId + "/" + engine.thePopup.phase) },
            { act: () => engine.pressEscape(), cond: () => engine.reelChildPopups[1].phase === "closed" },
            { act: () => engine.pressEscape(), cond: () => !trayOwner.menuOpen && !trayOwner.sideOpen,
              then: () => win.check("T3 the menus closed, the popup's field has the focus back", !!win.popupField && win.popupField.activeFocus,
                                    win.popupField ? win.popupField.activeFocus : "no field") },
            { act: () => { win.mark = { r: engine.pressEscape() }; }, wait: 15,
              then: () => win.check("T3 with no menu the strip asks for no keys: Escape is the popup's (it closes)", !engine.popupOpen || engine.thePopup.phase === "closing",
                                    engine.popupOwnerId + "/" + engine.thePopup.phase) },
            { act: () => win.away(), cond: () => engine.reelPhase === "closed" && !engine.popupOpen && engine.thePopup.phase === "closed" },
            // ---- T4: from the idle reel's strip to the title, quickly: one travel
            { act: () => win.hoverOn(idleMod), cond: () => engine.reelOpen && engine.reelOwnerId === "idle" && engine.reelPhase === "open" },
            { act: () => { win.rec = { phases: [], swap: { minOp: 1, minInk: 1 } }; win.hoverOn(titleButton.iconCell); },
              cond: () => { win.watch(); return engine.reelOwnerId === "windowtray" && engine.reelPhase === "open"; },
              then: () => {
                  const ps = win.rec.phases, sw = win.rec.swap;
                  win.check("T4 quick: the strip travelled from the reel to the tray (moving, never closed on the way)",
                            ps.indexOf("moving:windowtray") >= 0 && !ps.some(p => p.indexOf("closed") === 0), ps.join(" > "));
                  win.check("T4 the ring stays through the travel: the content faded out and in, the pass's ink stayed whole",
                            sw.minOp < 0.5 && sw.minInk > 0.999, "content's lowest " + sw.minOp.toFixed(3) + ", ink's lowest " + sw.minInk.toFixed(3));
                  win.rec.swap = null;
              } },
            // ---- T5: slowly -- the strip gone first, then a fresh one
            { act: () => win.away(), cond: () => engine.reelPhase === "closed" },
            { act: () => win.hoverOn(idleMod), cond: () => engine.reelOwnerId === "idle" && engine.reelPhase === "open" },
            { act: () => win.away(), cond: () => engine.reelPhase === "closed" },
            { act: () => { win.rec = { phases: [] }; win.hoverOn(titleButton.iconCell); },
              cond: () => { win.watch(); return engine.reelOwnerId === "windowtray" && engine.reelPhase === "open"; },
              then: () => win.check("T5 slow: a fresh strip (opening from closed, no travel)",
                                    win.rec.phases.indexOf("opening:windowtray") >= 0 && win.rec.phases.indexOf("moving:windowtray") < 0, win.rec.phases.join(" > ")) },
            // ---- T6: an automatic switch while the strip is out waits for it
            { act: () => { win.mark = { travels: follow.travels, sel: idleMod.reel.selectedItem.id }; svc.auto.llm = true; },
              cond: () => svc.mode === "soft" && svc.autoActive && follow.phase === "wait", wait: 0,
              then: () => win.check("T6 the auto switch waits while the strip is out: no turn, not even in the cell; the strip stays",
                                    follow.phase === "wait" && idleMod.reel.selectedItem.id === win.mark.sel && follow.travels === win.mark.travels
                                    && engine.reelOwnerId === "windowtray" && engine.reelOpen,
                                    follow.phase + " sel " + idleMod.reel.selectedItem.id + " travels " + follow.travels + " reel " + engine.reelOwnerId) },
            { act: () => {}, wait: 40,
              then: () => win.check("T6 ... and goes on waiting while the pointer keeps the strip", follow.phase === "wait" && engine.reelOwnerId === "windowtray" && engine.reelOpen,
                                    follow.phase + " " + engine.reelOwnerId) },
            { act: () => { win.rec = { phases: [] }; win.away(); },
              cond: () => { win.watch(); return follow.travels === win.mark.travels + 1 && idleMod.reel.selectedItem.id === "soft" && follow.phase !== "wait"; },
              then: () => {
                  const ps = win.rec.phases;
                  const closedAt = ps.indexOf("closed:windowtray"), idleAt = ps.findIndex(p => p.split(":")[1] === "idle");
                  win.check("T6 the strip closed, and only then the cinematic: the idle strip out, the turn to soft",
                            closedAt >= 0 && idleAt > closedAt && idleMod.reel.selectedItem.id === "soft", ps.join(" > "));
              } },
            { act: () => {}, cond: () => follow.phase === "" && engine.reelPhase === "closed" },
            // ---- T7: the pointer on the title while the cinematic plays: the strip waits for it
            { act: () => { svc.auto.llm = false; }, cond: () => follow.phase === "opening" || follow.phase === "travel" },
            { act: () => { win.rec = { trayDuringCine: 0, phases: [] }; win.hoverOn(titleButton.iconCell); },
              cond: () => { win.watch(); return follow.phase === "" && engine.reelOwnerId === "windowtray" && engine.reelPhase === "open"; },
              then: () => {
                  win.check("T7 the strip did not open while the cinematic played", win.rec.trayDuringCine === 0, win.rec.trayDuringCine + " ticks");
                  win.check("T7 ... and opened when it had ended, the pointer still on the title", engine.reelOwnerId === "windowtray" && idleMod.reel.selectedItem.id === "off",
                            win.rec.phases.join(" > ") + " sel " + idleMod.reel.selectedItem.id);
              } },
            { act: () => win.away(), cond: () => engine.reelPhase === "closed" },
            // ---- T8: the session locks with the strip out: it goes, and none opens while locked (the lock's popup is the one thing up)
            { act: () => win.hoverOn(titleButton.iconCell), cond: () => engine.reelOwnerId === "windowtray" && engine.reelPhase === "open" },
            { act: () => { titleButton.locked = true; }, cond: () => engine.reelPhase === "closed",
              then: () => { trayOwner.open(); win.check("T8 a lock takes the strip away, and it opens no more while locked", engine.reelPhase === "closed", engine.reelPhase); } },
            { act: () => { titleButton.locked = false; win.away(); }, wait: 5 },
            // ---- T10: the ring goes with the merge. The popup out again, the strip over it, then the pointer away.
            { act: () => win.openPopup(), cond: () => engine.popupOpen && engine.thePopup.phase === "open" },
            { act: () => win.hoverOn(titleButton.iconCell), cond: () => engine.reelOwnerId === "windowtray" && engine.reelPhase === "open" && engine.theReel.contentOpacity >= 0.999 },
            { act: () => { win.rec = { ink: [engine.reelCast.ink.x], at: engine.theReel.box.x0 }; win.away(); },
              cond: () => {
                  const k = engine.reelCast.ink.x;
                  if (engine.reelPhase === "closing" || engine.reelPhase === "closed")
                      win.rec.ink.push(engine.reelCast.count > 0 ? k : 0);
                  return engine.reelPhase === "closed";
              },
              then: () => {
                  const k = win.rec.ink;
                  let mono = true, mid = 0;
                  for (let i = 1; i < k.length; i++)
                      if (k[i] > k[i - 1] + 1e-6)
                          mono = false;
                  for (const v of k)
                      if (v > 0.05 && v < 0.95)
                          mid++;
                  win.check("T10 the ring fades with the merge: the ink falls monotonically from 1 to 0 over several frames (no pop)",
                            k.length > 4 && k[0] > 0.95 && k[k.length - 1] < 0.001 && mono && mid >= 3,
                            "n " + k.length + " first " + k[0] + " last " + k[k.length - 1] + " mono " + mono + " mid " + mid);
              } },
            // a frame held half way through the fade (the strip closing again, its clock and fade stopped at 0.5)
            { act: () => win.away(), cond: () => engine.reelPhase === "closed" && engine.thePopup.phase === "open" },
            { act: () => win.hoverOn(titleButton.iconCell), cond: () => engine.reelOwnerId === "windowtray" && engine.reelPhase === "open" && engine.theReel.contentOpacity >= 0.999 },
            { act: () => win.away(), cond: () => engine.reelPhase === "closing" && engine.theReel.t >= 0.08,
              then: () => {
                  const R = engine.theReel;
                  R.stop();
                  R.t = 0.08;
                  R.contentOpacity = 0.5;
                  // (below the joint with the bar: along the fillet the ring leaves the side and fades, by design)
                  win.mark = { R: R, x: Math.round(R.box.x0), y: Math.round(R.box.y0 + Math.min(40, 0.6 * (R.box.y1 - R.box.y0))) };
                  engine.layout();
              } },
            { act: () => {}, wait: 6,
              then: () => {
                  const m = win.mark;
                  if (win.grabDir !== "")
                      engine.grabToImage(r => {
                          const f = win.grabDir + "/merge.png";
                          console.log("TRAYREEL shot merge " + (r.saveToFile(f) ? f : "FAILED") + " " + (m.x - 2) + " " + m.y + " " + Theme.shellBorder);
                      });
              } },
            { act: () => {}, wait: 12,
              then: () => {
                  const R = win.mark.R;
                  R.fadeTo(0, 1);
                  R.runTo(1, 20);
              } },
            { act: () => {}, cond: () => engine.reelPhase === "closed", then: () => engine.close() },
            // ---- T11: the engine's prewarm warms the pass (read by signal: three frames pass between two ticks)
            { act: () => {}, cond: () => engine.reelPhase === "closed" && !engine.popupOpen && engine.thePopup.phase === "closed" },
            { act: () => { win.warm = { seen: false, count: -1 }; engine.prewarm([]); }, cond: () => win.warm.seen && !engine.reelCast.warming,
              then: () => win.check("T11 the engine's prewarm draws the reel pass's effect for a few frames, with no tile",
                                    win.warm.seen && win.warm.count === 0 && !engine.reelCast.warming, JSON.stringify(win.warm)) },
            // ---- T12: a passive item is no row while trayPassive is "hide", and a row again when it is active
            { act: () => {
                  win.rec = { rows: mockTray.count, shown: [] };
                  mockTray.setStatus("chat", "Passive");
                  win.rec.shown.push(mockTray.count);
                  win.trayConfig = Object.assign({}, win.trayConfig, { trayPassive: "hide" });
                  win.rec.shown.push(mockTray.count);
                  mockTray.setStatus("chat", "Active");
                  win.rec.shown.push(mockTray.count);
                  mockTray.setStatus("chat", "Passive");
                  win.rec.shown.push(mockTray.count);
                  win.trayConfig = Object.assign({}, win.trayConfig, { trayPassive: "faint" });
                  win.rec.shown.push(mockTray.count);
              }, cond: () => true,
              then: () => win.check("T12 a passive item is hidden while trayPassive says so, and only then",
                                    JSON.stringify(win.rec.shown.map(n => n - win.rec.rows)) === "[0,-1,0,-1,0]", JSON.stringify(win.rec)) }
        ]

        function finish(): void {
            console.log("TRAYREEL RESULT " + (win.fails === 0 ? "PASS" : "FAIL") + " (" + (win.checks - win.fails) + "/" + win.checks + " checks)");
            quitT.start();
        }
        Timer {
            id: quitT
            interval: 200
            onTriggered: Qt.quit()
        }
        Timer {
            interval: 20
            repeat: true
            running: true
            onTriggered: {
                if (win.at >= win.seq.length)
                    return;
                if (win.at < 0) {
                    win.at = 0;
                    win.acted = false;
                }
                const s = win.seq[win.at];
                // A fault an ARM puts in may make a step throw: a failed check, and the run goes on to its RESULT.
                const guarded = (what, f) => {
                    try {
                        return f();
                    } catch (e) {
                        win.check("step " + win.at + " " + what + " ran without an error", false, String(e));
                        return true;
                    }
                };
                if (!win.acted) {
                    win.acted = true;
                    win.ticks = 0;
                    guarded("act", s.act);
                    return;
                }
                win.ticks++;
                const ready = s.cond ? guarded("cond", s.cond) : win.ticks >= (s.wait || 1);
                if (!ready && win.ticks < 400)
                    return;
                if (!ready)
                    win.check("step " + win.at + " reached its condition", false, "timed out: reel " + engine.reelPhase + ":" + engine.reelOwnerId
                              + " follow " + follow.phase + " chain " + win.chainState() + " popup " + engine.popupOwnerId + "/" + engine.thePopup.phase);
                if (s.then)
                    guarded("then", s.then);
                win.at++;
                win.acted = false;
                if (win.at >= win.seq.length)
                    win.finish();
            }
        }
    }
}
