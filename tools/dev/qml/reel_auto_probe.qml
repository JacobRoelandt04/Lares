pragma ComponentBehavior: Bound

import QtQuick
import QtTest
import Quickshell

import "modules/common/theme"
import "modules/common/components"
import "modules/bar/gooey"
import "modules/bar/reel"
import "modules/idle"
import "modules/shell"
import "modules/shell/ReelItems.js" as ReelItems

// =============================================================================
// reel_auto_probe.qml -- the two reels' new behaviour on MOCKS (tools/dev/reel_auto_probe.sh runs it in a sandbox copy):
//
//   the idle auto layer   a real GooeyEngine with a bar, the idle ReelBarModule and its ReelFollow, a MOCK IdleService (live: false:
//                         nothing is held, no program runs) whose holders the probe flips, ReelActions over a recording
//                         CommandRunner. Debounce shortened (on 250 ms, off 900 ms). THE REASON: the strip's side popup (ReelReason, the
//                         engine's reel child: the cause alone, one line, its edges on whole pixels) -- out beside the strip level
//                         with its 3rd icon after a cinematic's turn, the reading pause
//                         (shortened to 1.5 s; held while the pointer is on the words), folded before the strip; out again under a hover
//                         while the auto layer holds; never for a mode the user picked. Each tick records it (`watchReason`).
//   the power flourishes  the power ReelBarModule with its ReelFlourishes, the same ReelActions (what it runs is recorded with the
//                         time), the lock key through ShortcutRouter (its GlobalShortcuts off).
//   the scroll            the power reel turned by the wheel and by a flick: each icon plays as it arrives, nothing fires, a flourish in
//                         progress is never restarted (a second arrival, a fresh hover), a flick plays only the icon it lands on, and
//                         every clock has stopped by itself afterwards with every icon at rest. THE FRAME RECORD: every write of every
//                         item's clock is followed (tChanged / kindChanged), and each play is printed as a `REELAUTO play` line.
//
// Pointer and wheel go through QtTest on the WINDOW (the cell's own MouseAreas answer). Prints `REELAUTO ok|FAIL <check>` and
// `REELAUTO RESULT PASS|FAIL (<n>/<n> checks)`.
// =============================================================================
ShellRoot {
    FloatingWindow {
        id: win
        implicitWidth: 800
        implicitHeight: 500
        visible: true
        color: Theme.surface

        TestCase {
            id: tc
            when: false
        }

        IconReelStyle {
            id: sharedStyle
        }
        // the reason's line, to judge its height by (one line and its padding)
        FontMetrics {
            id: reasonLine
            font.family: sharedStyle.reasonFamily
            font.pixelSize: sharedStyle.reasonTitleSize
            font.bold: true
        }

        GooeyEngine {
            id: engine
            anchors.fill: parent
            surfaceColor: Theme.surface
            barsList: [topBar]

            GooeyBar {
                id: topBar
                engine: engine
                barId: "topBar"
                edge: "top"
                rawPos: 0
                rawLen: engine.w

                ReelBarModule {
                    id: powerMod
                    x: 160
                    engine: engine
                    bar: topBar
                    barId: "topBar"
                    ownerId: "power"
                    style: sharedStyle
                    items: ReelItems.POWER
                    flourishes: ReelFlourishes {
                        onPlayed: id => {
                            win.playedAt[id] = Date.now();
                            actions.flourishPlayed(id);
                        }
                    }
                    Component.onCompleted: powerMod.reel.snapTo(ReelItems.indexOf(ReelItems.POWER, "lock"))
                    onActivated: (index, item) => actions.firePower(item.id)
                }
                ReelBarModule {
                    id: idleMod
                    x: 100
                    engine: engine
                    bar: topBar
                    barId: "topBar"
                    ownerId: "idle"
                    style: sharedStyle
                    items: ReelItems.IDLE
                    leftClickActivates: true
                    burstOnActivate: false
                    autoHeld: svc.autoActive
                    floorId: svc.floorMode
                    onActivated: (index, item) => actions.fireIdle(item.id, idleMod.reel.lastInputOverride)
                    onSelectionChanged: (index, item) => actions.idleSelected(item.id, idleMod.reel.lastInputOverride)
                }
            }
        }

        ReelFollow {
            id: follow
            module: idleMod
            target: svc.mode
            automatic: svc.autoActive
            reason: svc.autoReason
            hold: actions.idleWaiting
            floorReason: svc.floorReason
            readMs: 1500
            readAfterMs: 600
        }

        IdleService {
            id: svc
            live: false
            auto.onMs: 250
            auto.offMs: 900
        }
        CommandRunner {
            id: runner
            live: false
        }
        ReelActions {
            id: actions
            runner: runner
            idle: svc
        }
        Connections {
            target: actions
            function onFlourished(id: string): void {
                powerMod.flourishes.play(id);
            }
        }
        ShortcutRouter {
            id: router
            enabled: false
            services: QtObject {
                property var reelActions: actions
                property var lock: QtObject {
                    property bool locked: false
                }
            }
        }

        // ---- helpers --------------------------------------------------------------------------------------------------------
        readonly property string grabDir: Quickshell.env("GRAB_DIR") || ""
        property int checks: 0
        property int fails: 0
        function check(name: string, ok: bool, detail: var): void {
            win.checks++;
            if (!ok)
                win.fails++;
            console.log("REELAUTO " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  (" + detail + ")"));
        }
        function cellCentre(mod: Item): point {
            return mod.mapToItem(win.contentItem, mod.width / 2, mod.height / 2);
        }
        function wheelOn(mod: Item, notches: int, ctrl: bool): void {
            const p = win.cellCentre(mod);
            tc.mouseMove(win.contentItem, p.x, p.y);
            tc.mouseWheel(win.contentItem, p.x, p.y, 0, -120 * notches, Qt.NoButton, ctrl ? Qt.ControlModifier : Qt.NoModifier);
        }
        function away(): void {
            tc.mouseMove(win.contentItem, 600, 400);
        }
        // onto a module's cell as a hand comes: an entry, then a motion (an entry alone is no hover: IconReelView.pointerArrived)
        function hoverOn(mod: Item): void {
            const p = win.cellCentre(mod);
            tc.mouseMove(win.contentItem, p.x - 3, p.y);
            tc.mouseMove(win.contentItem, p.x, p.y);
        }
        function clockOf(id: string): var {
            return powerMod.flourishes.clockOf(id);
        }
        // the item `slot` cells from the bar's cell (1: the strip's first icon), and the middle of its icon in the open strip
        function stripIndex(mod: Item, slot: int): int {
            for (let i = 0; i < mod.reel.count; i++)
                if (Math.round(mod.reel.slotOf(i)) === slot)
                    return i;
            return -1;
        }
        function stripPoint(mod: Item, slot: int): point {
            const pv = mod.popupView;
            const a = mod.reel.aOf(win.stripIndex(mod, slot));
            const along = pv.fromStart ? a - pv.aFrom : pv.viewLen - (a - pv.aFrom);
            const q = pv.vertical ? pv.mapToItem(win.contentItem, pv.width / 2, along) : pv.mapToItem(win.contentItem, along, pv.height / 2);
            return Qt.point(Math.round(q.x), Math.round(q.y));
        }
        function anyPlaying(): bool {
            return ReelItems.POWER.some(it => win.clockOf(it.id).playing);
        }
        function playing(): var {
            return ReelItems.POWER.filter(it => win.clockOf(it.id).playing).map(it => it.id);
        }

        // ---- the frame record: every write of every power item's clock, while `on` (a var mutated in place: nothing binds to it) ----
        //   plays     [{ id, kind, start, end, frames, lastT }] in ms after `t0`; `open` the plays in progress by id
        //   restarts  a clock written back while it played (t fell, or the kind changed under it: a play started over another)
        //   cuts      a play that ended before its clock reached its end (stopped, or stopped and started again)
        property var rec: ({ on: false })
        function recStart(): void {
            if (!win.rec.wired) {
                for (const it of ReelItems.POWER) {
                    const id = it.id;
                    const c = win.clockOf(id);
                    c.kindChanged.connect(() => win._recKind(id, c));
                    c.tChanged.connect(() => win._recT(id, c));
                }
            }
            win.rec = { wired: true, on: true, t0: Date.now(), plays: [], open: {}, restarts: {}, cuts: {}, pending: false };
        }
        function _recKind(id: string, c: var): void {
            const r = win.rec;
            if (!r.on)
                return;
            const now = Date.now() - r.t0;
            const o = r.open[id];
            if (o) {
                if (o.lastT < 0.98)
                    r.cuts[id] = (r.cuts[id] || 0) + 1;
                o.end = now;
                delete r.open[id];
                if (c.kind !== "")
                    r.restarts[id] = (r.restarts[id] || 0) + 1;
            }
            if (c.kind !== "") {
                const n = { id: id, kind: c.kind, start: now, end: -1, frames: 0, lastT: 0 };
                r.plays.push(n);
                r.open[id] = n;
            }
        }
        function _recT(id: string, c: var): void {
            const r = win.rec;
            const o = r.on ? r.open[id] : null;
            if (!o || !c.playing)
                return;
            if (c.t < o.lastT - 1e-9)
                r.restarts[id] = (r.restarts[id] || 0) + 1;
            o.lastT = c.t;
            o.frames++;
        }
        // when the current play of an item started (-1: none)
        function playStart(id: string): real {
            const o = win.rec.open ? win.rec.open[id] : null;
            return o ? o.start : -1;
        }
        function sum(m: var): int {
            let n = 0;
            for (const k in m)
                n += m[k];
            return n;
        }
        // the selected delegate of a module's bar cell (its hover fraction is the colour's clock)
        function selectedCell(mod: Item): var {
            const walk = it => {
                if (it && it.isSelected === true && it.hoverF !== undefined)
                    return it;
                const kids = it ? it.children : [];
                for (let i = 0; i < kids.length; i++) {
                    const r = walk(kids[i]);
                    if (r)
                        return r;
                }
                return null;
            };
            for (const c of mod.children)
                if (c.objectName === "reelBarCell")
                    return walk(c);
            return null;
        }
        function callsOf(word: string): var {
            return runner.calls.filter(c => c.argv.join(" ").indexOf(word) >= 0);
        }
        // ---- the reason, recorded on every tick of a step that watches it (a var mutated in place: nothing binds to it) ----------
        //   firstPhase  the cinematic's phase when it was first seen out ("read": after the turn landed)
        //   ticks       how many of the probe's ticks it was out (the probe's ticks and ReelFollow's timers run on one clock)
        //   geo         its place once open: dx its near face from the strip's far side, dy its middle from the 3rd icon's middle, its
        //               top and bottom edges (y0, y1) and size
        //   lines       the words it shows: every visible Text of the content with words, { text, top, bottom } (top: the line box's
        //               distance from the content's top; bottom: from its foot)
        //   childFirst  it began to fold before the strip did, and the strip HELD for it (the engine: a parent waits for its child)
        property var rs: ({})
        function rsReset(): void {
            win.rs = { firstPhase: "", ticks: 0, geo: null, cause: "", lines: null, childClosing: false, reelHeld: false, reelFirst: false };
        }
        function watchReason(): void {
            const r = win.rs;
            const C = engine.theReelChild, R = engine.theReel;
            if (follow.reasonOut) {
                if (r.firstPhase === "")
                    r.firstPhase = follow.phase;
                r.ticks++;
                if (!r.geo && C.phase === "open" && C.box && R.box && idleMod.popupView) {
                    const pv = idleMod.popupView;
                    const third = pv.mapToItem(win.contentItem, 0, pv.coordFor(sharedStyle.barCell / 2 + (idleMod.reel.count - 2) * sharedStyle.cellPitch, 0));
                    r.geo = { dx: C.box.x0 - R.box.x1, dy: (C.box.y0 + C.box.y1) / 2 - third.y, w: C.box.x1 - C.box.x0, h: C.box.y1 - C.box.y0,
                              y0: C.box.y0, y1: C.box.y1 };
                    const it = C.contentItem;
                    r.cause = it ? it.cause : "";
                    r.lines = it ? win.linesOf(it) : null;
                    console.log("REELAUTO reason '" + r.cause + "' " + JSON.stringify({ geo: r.geo, lines: r.lines, lineH: reasonLine.height }));
                }
            }
            if (C.phase === "closing" && C.ownerId === follow.reasonId)
                r.childClosing = true;
            if (R.phase === "closing" && R.closeHeld && r.childClosing)
                r.reelHeld = true;
            if (R.phase === "closing" && !R.closeHeld && !r.childClosing && r.ticks > 0)
                r.reelFirst = true;
        }
        // Every visible Text with words in a content, in the content's frame (a var: read once, when the reason is first open).
        function linesOf(item: Item): var {
            const out = [];
            const walk = (n) => {
                for (const c of n.children) {
                    if (!c.visible)
                        continue;
                    if (typeof c.text === "string" && c.font !== undefined && c.text !== "") {
                        const p = c.mapToItem(item, 0, 0);
                        out.push({ text: c.text, top: p.y, bottom: item.height - p.y - c.height });
                    }
                    walk(c);
                }
            };
            walk(item);
            return out;
        }
        // The user's words: "only the reason why it was engaged" -- the cause, ONE bold line, the padding the same above and below (to
        // the line box's own fraction), so the popup is one line and its padding tall.
        function oneLine(cause: string): bool {
            const r = win.rs, g = r.geo, L = r.lines;
            return !!g && !!L && L.length === 1 && L[0].text === cause && Math.abs(L[0].top - L[0].bottom) <= 1
                && Math.abs(g.h - (2 * sharedStyle.reasonPadY + reasonLine.height)) <= 1;
        }
        function reasonChecks(cause: string): void {
            const r = win.rs;
            const g = r.geo;
            win.check("the reason popped out beside the strip, naming the cause (" + cause + ")",
                      r.ticks > 0 && r.cause === cause, r.ticks + " ticks, '" + r.cause + "'");
            win.check("the reason is the cause alone, one line, as much padding above as below (no mode under it)", win.oneLine(cause),
                      JSON.stringify({ lines: r.lines, h: g ? g.h : -1, lineH: reasonLine.height }));
            win.check("at the level of its 3rd icon, flush against the strip's right side, its edges on whole pixels",
                      !!g && Math.abs(g.dx) < 1.5 && Math.abs(g.dy) < 1.5 && g.w > 40 && g.h > 20
                      && Math.abs(g.y0 - Math.round(g.y0)) < 1e-3 && Math.abs(g.y1 - Math.round(g.y1)) < 1e-3, JSON.stringify(g));
            win.check("it came after the turn landed (the cause read with the mode it brought)", r.firstPhase === "read", "first seen in phase '" + r.firstPhase + "'");
            win.check("it held the reading pause", r.ticks * 20 >= follow.readMs * 0.9, (r.ticks * 20) + " ms of " + follow.readMs);
            win.check("it folded first, the strip holding for it, then the strip", r.childClosing && r.reelHeld && !r.reelFirst,
                      "child closing " + r.childClosing + " strip held " + r.reelHeld + " strip first " + r.reelFirst);
        }

        // ---- the sequence: each step acts, waits for its condition (or `wait` ticks), then judges ----------------------------
        property int at: -1
        property int ticks: 0
        property bool acted: false
        property var mark: ({})
        // when each flourish said it had played (a var, mutated in place: nothing binds to it)
        property var playedAt: ({})
        property bool sawOpen: false
        property real shakeSeen: 0
        property int refusedSteps: 0
        Connections {
            target: idleMod
            function onRefusedStep(): void { win.refusedSteps++; }
        }
        readonly property var seq: [
            { act: () => {}, cond: () => engine.w > 0 && topBar.thickness > 0, wait: 10,
              then: () => win.check("rest: the user's mode (off) is in force, the auto layer asks nothing", svc.mode === "off" && !svc.autoActive && idleMod.reel.selectedItem.id === "off",
                                    svc.mode + " " + svc.autoActive) },
            // ---- the debounce
            { act: () => { svc.auto.llm = true; }, wait: 5 },
            { act: () => { svc.auto.llm = false; }, wait: 30,
              then: () => win.check("a holder that flaps for 100 ms asks nothing (the debounce)", svc.mode === "off" && follow.travels === 0, svc.mode + " travels " + follow.travels) },
            // ---- the LLM answering: soft, the long way, the strip out and back in, the reason beside it
            { act: () => { win.sawOpen = false; win.rsReset(); svc.auto.llm = true; },
              cond: () => {
                  win.watchReason();
                  if (follow.phase === "travel" && engine.reelOpen && engine.reelOwnerId === "idle")
                      win.sawOpen = true;
                  return svc.mode === "soft" && follow.travels === 1 && follow.phase === "" && !engine.reelOpen && !follow.reasonOut;
              },
              then: () => {
                  win.check("the LLM answering puts soft in force by itself", svc.mode === "soft" && svc.autoActive && svc.selectedMode === "off", svc.mode + " " + svc.autoActive);
                  win.check("the reel travelled to soft the LONG way (3 cells back, not 1 on)", follow.lastSteps === -3 && idleMod.reel.selectedItem.id === "soft", "steps " + follow.lastSteps + " at " + idleMod.reel.selectedItem.id);
                  win.check("the strip came out by itself for the travel and went back in", win.sawOpen && !engine.reelOpen, "saw " + win.sawOpen + " open " + engine.reelOpen);
                  win.reasonChecks("The LLM is answering");
              } },
            { act: () => {}, wait: 15,
              then: () => {
                  const c = win.selectedCell(idleMod);
                  win.check("the selected icon keeps its colour with the pointer away (the automatic mark)", !!c && c.hoverF > 0.99 && idleMod.reel.autoHeld, c ? c.hoverF : "no cell");
              } },
            // ---- input is dead without Ctrl, hover still opens -- and the reason comes out with it
            // THE FLOOR: soft is asked for, so a plain turn UNDER it (to off) is refused -- the ring stays, the icon shakes, nothing applies
            { act: () => { win.mark = { calls: runner.calls.length, refused: 0, shakeMax: 0 }; win.wheelOn(idleMod, -1, false); }, wait: 30,
              then: () => win.check("a plain scroll UNDER the floor (soft -> off) is refused: the ring stays on soft, nothing applies", idleMod.reel.selectedItem.id === "soft" && !actions.idleWaiting && svc.selectedMode === "off" && svc.mode === "soft",
                                    idleMod.reel.selectedItem.id + " waiting " + actions.idleWaiting + " user " + svc.selectedMode) },
            { act: () => { win.shakeSeen = 0; win.wheelOn(idleMod, -1, false); }, cond: () => { win.shakeSeen = Math.max(win.shakeSeen, Math.abs(idleMod.reel.shakeX)); return win.shakeSeen > 1 && idleMod.reel.shakeX === 0 && win.refusedSteps >= 2; },
              then: () => win.check("... the refusal shakes the icon (across the strip, back to 0 at the end) and says refusedStep", win.shakeSeen > 1 && idleMod.reel.shakeX === 0 && win.refusedSteps >= 2, win.shakeSeen + " steps " + win.refusedSteps) },
            { act: () => win.rsReset(), cond: () => { win.watchReason(); return engine.reelOpen && engine.reelOwnerId === "idle" && engine.theReelChild.phase === "open"; },
              then: () => {
                  win.check("hover still opens the held reel", engine.reelOpen, engine.reelOwnerId);
                  win.check("a hover with auto active shows the reason again, beside the open strip", follow.reasonOut && win.rs.cause === "The LLM is answering",
                            follow.reasonOut + " '" + win.rs.cause + "'");
              } },
            { act: () => win.away(), cond: () => { win.watchReason(); return !engine.reelOpen && !follow.reasonOut; },
              then: () => win.check("the hovered reason goes with the strip (first, the strip holding for it)", win.rs.childClosing && win.rs.reelHeld && !win.rs.reelFirst,
                                    JSON.stringify(win.rs)) },
            // ---- a short flap keeps the hold (a video paused for a look away)
            { act: () => { win.mark = { travels: follow.travels }; svc.auto.llm = false; }, wait: 8 },
            { act: () => { svc.auto.llm = true; }, wait: 60,
              then: () => win.check("a holder that lets go for 160 ms keeps the hold: no dance", svc.mode === "soft" && follow.travels === win.mark.travels, svc.mode + " travels " + follow.travels) },
            // ---- a video: normal, the cause changes; the pointer on the words holds the reading pause
            { act: () => { win.rsReset(); svc.soft.content.simulate(true, "firefox"); },
              cond: () => { win.watchReason(); return svc.mode === "normal" && follow.phase === "read" && engine.theReelChild.phase === "open" && !!win.rs.geo; },
              then: () => {
                  win.check("content being watched raises it to normal, the long way (3 cells back)", follow.lastSteps === -3 && idleMod.reel.selectedItem.id === "normal", "steps " + follow.lastSteps);
                  win.check("the reason names the new cause, alone on its line", win.rs.cause === "Firefox is playing video" && win.oneLine("Firefox is playing video"),
                            win.rs.cause + " " + JSON.stringify(win.rs.lines));
                  // GRAB_DIR (the runner's sheet): the reason out beside the strip, at rest
                  if (win.grabDir !== "" && !engine.grabToImage(r => console.log("REELAUTO grab " + (r.saveToFile(win.grabDir + "/reason.png") ? "saved" : "FAILED"))))
                      console.log("REELAUTO grab REFUSED");
                  const b = engine.theReelChild.box;
                  if (b) {
                      tc.mouseMove(win.contentItem, Math.round((b.x0 + b.x1) / 2) - 3, Math.round((b.y0 + b.y1) / 2));
                      tc.mouseMove(win.contentItem, Math.round((b.x0 + b.x1) / 2), Math.round((b.y0 + b.y1) / 2));
                  }
              } },
            { act: () => {}, wait: Math.ceil(1500 / 20) + 30,
              then: () => win.check("the reading pause holds while the pointer is on the words (past its length)", follow.reasonOut && follow.phase === "read" && engine.reelOpen,
                                    follow.reasonOut + " " + follow.phase) },
            { act: () => { win.mark.leaveTicks = 0; win.away(); },
              cond: () => { win.mark.leaveTicks++; win.watchReason(); return !follow.reasonOut && !engine.reelOpen && follow.phase === ""; },
              then: () => win.check("once the pointer leaves, the rest of the pause (at least readAfterMs), then both fold",
                                    win.mark.leaveTicks * 20 >= follow.readAfterMs * 0.9 && win.rs.childClosing && win.rs.reelHeld,
                                    (win.mark.leaveTicks * 20) + " ms after the leave, " + JSON.stringify(win.rs)) },
            // ---- Ctrl+scroll: the user's pick wins, the holders of the moment set aside -- and no reason for it
            { act: () => { win.mark = { travels: follow.travels, tells: follow.tells }; win.wheelOn(idleMod, -1, true); },
              cond: () => !actions.idleWaiting && svc.selectedMode === "soft" && engine.reelOpen,
              then: () => {
                  win.check("Ctrl+scroll picks a mode on the held reel: soft is the user's and in force, the auto layer set aside",
                            svc.mode === "soft" && !svc.autoActive && svc.auto.overridden && idleMod.reel.selectedItem.id === "soft", svc.mode + " auto " + svc.autoActive + " overridden " + svc.auto.overridden);
                  win.check("a mode the user picked shows no reason (the strip is out under the pointer, the words are not)", !follow.reasonOut && engine.reelOpen,
                            "reason " + follow.reasonOut + " strip " + engine.reelOpen);
              } },
            { act: () => win.away(), wait: 60,
              then: () => win.check("the override stands while the same holders hold (no travel back)", svc.mode === "soft" && follow.travels === win.mark.travels, svc.mode + " travels " + follow.travels) },
            { act: () => { svc.auto.timer = true; svc.auto.timerWhat = "pomodoro"; }, cond: () => svc.autoActive && follow.phase === "" && follow.travels === win.mark.travels + 1 && !engine.reelOpen,
              then: () => win.check("a holder the override did not set aside ends it: normal again, by the long way", svc.mode === "normal" && follow.lastSteps === -3, svc.mode + " steps " + follow.lastSteps) },
            // ---- the hold ends: back to the user's mode, the long way, no reason
            { act: () => { win.mark = { travels: follow.travels, tells: follow.tells }; win.rsReset(); svc.soft.content.simulate(false); svc.auto.llm = false; svc.auto.timer = false; },
              cond: () => { win.watchReason(); return !svc.autoActive && follow.phase === "" && follow.travels === win.mark.travels + 1 && !engine.reelOpen; },
              then: () => {
                  win.check("when the hold ends the reel travels back to the user's soft, the long way (3 cells on)", svc.mode === "soft" && follow.lastSteps === 3 && idleMod.reel.selectedItem.id === "soft", svc.mode + " steps " + follow.lastSteps);
                  win.check("the way back tells no reason", win.rs.ticks === 0 && follow.tells === win.mark.tells, win.rs.ticks + " ticks, tells " + follow.tells + " vs " + win.mark.tells);
                  win.check("the colour goes with the hold", !idleMod.reel.autoHeld, idleMod.reel.autoHeld);
              } },
            // ---- the floor, taken: a share (normal) over the user's soft; plain turns UNDER it are refused, ABOVE it taken, and the cause ending keeps the user's pick
            { act: () => { win.mark = { travels: follow.travels }; win.rsReset(); svc.auto.share = true; },
              cond: () => svc.mode === "normal" && follow.phase === "" && follow.travels === win.mark.travels + 1 && !engine.reelOpen && !follow.reasonOut,
              then: () => win.check("a share raises soft to normal; the floor is normal", idleMod.reel.selectedItem.id === "normal" && svc.floorMode === "normal" && svc.selectedMode === "soft", svc.mode + " floor " + svc.floorMode) },
            { act: () => { win.refusedSteps = 0; win.rsReset(); win.wheelOn(idleMod, -1, false); }, cond: () => { win.watchReason(); return win.refusedSteps >= 1 && follow.reasonOut && win.rs.cause !== ""; },
              then: () => {
                  win.check("a plain scroll to soft (under the floor, which is the user's own soft) is refused", idleMod.reel.selectedItem.id === "normal" && svc.selectedMode === "soft" && !actions.idleWaiting, idleMod.reel.selectedItem.id);
                  win.check("... and the cause is told beside the open strip", follow.reasonOut && win.rs.cause === "Screen is being shared", follow.reasonOut + " '" + win.rs.cause + "'");
              } },
            { act: () => { win.wheelOn(idleMod, 1, false); }, cond: () => !actions.idleWaiting && svc.selectedMode === "hard",
              then: () => win.check("a plain scroll to hard (above the floor) is taken: the user's mode, in force", svc.selectedMode === "hard" && svc.mode === "hard" && idleMod.reel.selectedItem.id === "hard", svc.selectedMode + " " + svc.mode) },
            { act: () => { win.refusedSteps = 0; win.rsReset(); win.wheelOn(idleMod, 1, false); }, cond: () => { win.watchReason(); return win.refusedSteps >= 1 && follow.reasonOut && win.rs.cause !== ""; },
              then: () => win.check("above the floor the cause raised nothing, and a refusal (hard -> off round the ring) still tells it beside the strip", !svc.autoActive && idleMod.reel.selectedItem.id === "hard" && follow.reasonOut && win.rs.cause === "Screen is being shared",
                                    svc.autoActive + " " + idleMod.reel.selectedItem.id + " '" + win.rs.cause + "'") },
            { act: () => { win.away(); svc.auto.share = false; }, wait: 80,
              then: () => win.check("the cause ends: the user's hard is still in force and the reel stays on it", svc.mode === "hard" && svc.selectedMode === "hard" && idleMod.reel.selectedItem.id === "hard", svc.mode) },
            // ---- idle.jsonc autoTell "quiet": a cause turns the cell by itself, no strip, no cinematic, no reason told
            { act: () => { svc.setMode("off"); }, cond: () => svc.mode === "off" && idleMod.reel.selectedItem.id === "off" && follow.phase === "" && !engine.reelOpen },
            { act: () => { follow.cinematic = false; win.mark = { travels: follow.travels, tells: follow.tells, opened: false }; svc.auto.music = true; },
              cond: () => { if (engine.reelOpen) win.mark.opened = true; return svc.mode === "soft" && idleMod.reel.selectedItem.id === "soft"; },
              then: () => win.check("autoTell quiet: the cell turns to soft with no strip and no cinematic", follow.travels === win.mark.travels && !win.mark.opened && follow.tells === win.mark.tells,
                                    "travels " + follow.travels + " vs " + win.mark.travels + ", opened " + win.mark.opened) },
            { act: () => { svc.auto.music = false; }, cond: () => { if (engine.reelOpen) win.mark.opened = true; return svc.mode === "off" && idleMod.reel.selectedItem.id === "off"; },
              then: () => { win.check("... and back to off the same way", follow.travels === win.mark.travels && !win.mark.opened, "travels " + follow.travels); follow.cinematic = true; svc.setMode("hard"); } },
            { act: () => {}, cond: () => svc.mode === "hard" && idleMod.reel.selectedItem.id === "hard" && follow.phase === "" },
            // ---- the power reel: a fire waits for its flourish
            { act: () => { win.mark = { t0: Date.now(), n: win.callsOf("poweroff").length }; actions.firePower("poweroff");
                           win.check("poweroff's flourish plays at the click", powerMod.flourishes.poweroff.playing, powerMod.flourishes.poweroff.kind); },
              cond: () => win.callsOf("poweroff").length > win.mark.n,
              then: () => {
                  const c = win.callsOf("poweroff");
                  const ran = c[c.length - 1].ms;
                  const played = win.playedAt.poweroff || 0;
                  win.check("poweroff runs when its flourish has played (and not before)", played >= win.mark.t0 && ran >= played && !powerMod.flourishes.poweroff.playing,
                            "played " + (played - win.mark.t0) + " ms, ran " + (ran - win.mark.t0) + " ms after the click");
              } },
            { act: () => { win.mark = { t0: Date.now(), n: win.callsOf("lares-lock-session").length }; actions.firePower("lock"); },
              cond: () => win.callsOf("lares-lock-session").length > win.mark.n,
              then: () => {
                  const c = win.callsOf("lares-lock-session");
                  const dt = c[c.length - 1].ms - win.mark.t0;
                  win.check("lock runs at once (no wait) while its flourish plays", dt < 100 && powerMod.flourishes.lock.kind === "engage", dt + " ms, " + powerMod.flourishes.lock.kind);
              } },
            { act: () => { powerMod.flourishes.locked = true; }, cond: () => !powerMod.flourishes.lock.playing,
              then: () => win.check("the padlock stays shut while the session is locked", powerMod.flourishes.lockPose.open === 0 && powerMod.flourishes.shut, JSON.stringify(powerMod.flourishes.lockPose)) },
            { act: () => { powerMod.flourishes.locked = false; },
              then: () => win.check("the lock letting go springs it open", powerMod.flourishes.lock.kind === "release", powerMod.flourishes.lock.kind) },
            { act: () => {}, cond: () => !powerMod.flourishes.lock.playing },
            { act: () => { powerMod.flourishes.locked = true; },
              then: () => win.check("a lock nobody clicked for (hypridle's, before a suspend) plays the engage", powerMod.flourishes.lock.kind === "engage", powerMod.flourishes.lock.kind) },
            { act: () => {}, cond: () => !powerMod.flourishes.lock.playing },
            { act: () => { powerMod.flourishes.locked = false; }, cond: () => !powerMod.flourishes.lock.playing && !powerMod.flourishes.shut },
            // ---- hover plays it, fires nothing; an entry alone (a pointer the cell came up under) is no hover
            { act: () => { win.mark = { n: runner.calls.length }; const p = win.cellCentre(powerMod); tc.mouseMove(win.contentItem, p.x - 3, p.y); }, wait: 12,
              then: () => win.check("a pointer that comes onto the cell without moving on it plays nothing (an entry is not a hover)", !win.anyPlaying(), win.playing().join(",")) },
            { act: () => { const p = win.cellCentre(powerMod); tc.mouseMove(win.contentItem, p.x, p.y); }, wait: 3,
              then: () => win.check("hover plays the selected item's flourish (the padlock shuts and opens) and fires nothing",
                                    powerMod.flourishes.lock.kind === "cycle" && runner.calls.length === win.mark.n, powerMod.flourishes.lock.kind + " calls " + runner.calls.length) },
            { act: () => win.away(), cond: () => !powerMod.flourishes.lock.playing && !engine.reelOpen },
            // ---- the open strip (feedback/reel.md "Flourish on hover"): the pointer moving onto an icon there plays THAT icon's flourish (a demo:
            // it says the icon can be clicked) and fires nothing; the pointer coming in without a motion plays nothing; the selected icon is the cell's
            { act: () => win.hoverOn(powerMod), cond: () => !win.anyPlaying() && engine.reelOpen && engine.reelOwnerId === "power" && !!powerMod.popupView
                                                             && engine.reelPhase === "open" },
            { act: () => { win.mark = { n: runner.calls.length, sel: powerMod.reel.selectedItem.id, id: powerMod.reel.items[win.stripIndex(powerMod, 2)].id };
                           const p = win.stripPoint(powerMod, 2); tc.mouseMove(win.contentItem, p.x, p.y - 3); }, wait: 3,
              then: () => win.check("the pointer coming into the strip onto an icon plays nothing before it moves there", !win.clockOf(win.mark.id).playing, win.playing().join(",")) },
            { act: () => { const p = win.stripPoint(powerMod, 2); tc.mouseMove(win.contentItem, p.x, p.y); }, wait: 3,
              then: () => win.check("a motion onto an icon of the open strip plays THAT icon's flourish (a hover), fires nothing, and the selected icon plays nothing",
                                    win.clockOf(win.mark.id).kind === "hover" && !win.clockOf(win.mark.sel).playing && runner.calls.length === win.mark.n && actions.powerPending === "",
                                    win.mark.id + " " + win.clockOf(win.mark.id).kind + ", selected " + win.mark.sel + " " + win.clockOf(win.mark.sel).kind + ", calls " + runner.calls.length) },
            { act: () => win.away(), cond: () => !win.anyPlaying() && !engine.reelOpen },
            // ---- scrolling through the power reel: each icon plays as it ARRIVES in the cell; nothing fires; nothing restarts
            { act: () => win.hoverOn(powerMod), cond: () => !win.anyPlaying() && engine.reelOpen && engine.reelOwnerId === "power" && !powerMod.reel._swipeCooling },
            { act: () => { win.recStart(); win.mark = { n: runner.calls.length }; win.wheelOn(powerMod, 1, false); }, wait: 2,
              then: () => win.check("a scroll plays the flourish of the icon it brings into the cell (sleep) and fires nothing",
                                    powerMod.reel.selectedItem.id === "sleep" && win.clockOf("sleep").kind === "arrive" && runner.calls.length === win.mark.n && actions.powerPending === "",
                                    powerMod.reel.selectedItem.id + " " + win.clockOf("sleep").kind + " calls " + runner.calls.length + " pending '" + actions.powerPending + "'") },
            { act: () => {}, cond: () => win.clockOf("sleep").t > 0.2 && !powerMod.reel._swipeCooling },
            { act: () => win.wheelOn(powerMod, 1, false), wait: 2,
              then: () => win.check("the next notch plays the next icon (poweroff) while sleep, turned out of the cell, plays on",
                                    powerMod.reel.selectedItem.id === "poweroff" && win.clockOf("poweroff").kind === "arrive" && win.clockOf("sleep").playing,
                                    powerMod.reel.selectedItem.id + " poweroff " + win.clockOf("poweroff").kind + " sleep " + win.clockOf("sleep").kind) },
            { act: () => {}, cond: () => win.clockOf("poweroff").t > 0.1 && !powerMod.reel._swipeCooling },
            { act: () => { win.mark.sleepStart = win.playStart("sleep"); win.wheelOn(powerMod, -1, false); }, wait: 2,
              then: () => win.check("turned back into the cell mid-flourish, sleep goes on: a second arrival does not restart it",
                                    powerMod.reel.selectedItem.id === "sleep" && win.clockOf("sleep").playing && win.playStart("sleep") === win.mark.sleepStart
                                    && !win.rec.restarts.sleep && !win.rec.cuts.sleep,
                                    powerMod.reel.selectedItem.id + " playing " + win.clockOf("sleep").playing + " start " + win.playStart("sleep") + " vs " + win.mark.sleepStart
                                    + " restarts " + (win.rec.restarts.sleep || 0) + " cuts " + (win.rec.cuts.sleep || 0)) },
            // off the cell into the strip, and back on with a motion: a fresh hover, while sleep still plays
            { act: () => { const p = win.cellCentre(powerMod); tc.mouseMove(win.contentItem, p.x, p.y + 44); }, wait: 2 },
            { act: () => win.hoverOn(powerMod), wait: 3,
              then: () => win.check("a fresh hover during a flourish does not restart it (sleep plays on from where it was)",
                                    win.clockOf("sleep").playing && win.playStart("sleep") === win.mark.sleepStart && !win.rec.restarts.sleep && !win.rec.cuts.sleep,
                                    "playing " + win.clockOf("sleep").playing + " start " + win.playStart("sleep") + " vs " + win.mark.sleepStart
                                    + " restarts " + (win.rec.restarts.sleep || 0) + " cuts " + (win.rec.cuts.sleep || 0)) },
            // a fast flick, as the view hands a touchpad's wheel to the ring: one push big enough to commit three steps in ONE turn
            { act: () => { win.mark.from = powerMod.reel.reelTarget; win.mark.poweroffStart = win.playStart("poweroff");
                           powerMod.reel.applySwipe(1); powerMod.reel.applySwipe(2100); powerMod.reel.applySwipe(0); }, wait: 3,
              then: () => win.check("a turn that commits several steps (a fast flick) plays only the icon it lands on (hibernate; reboot passed in the blur plays nothing)",
                                    powerMod.reel.reelTarget - win.mark.from === 3 && powerMod.reel.selectedItem.id === "hibernate" && win.clockOf("hibernate").kind === "arrive"
                                    && !win.clockOf("reboot").playing && win.playStart("poweroff") === win.mark.poweroffStart,
                                    "steps " + (powerMod.reel.reelTarget - win.mark.from) + " at " + powerMod.reel.selectedItem.id + " playing " + win.playing().join(",")) },
            // on across the rest of the ring, a notch at a time: log out, the padlock (it shuts and opens), sleep (the padlock turned out mid-play)
            { act: () => {}, cond: () => !powerMod.reel._swipeCooling },
            { act: () => win.wheelOn(powerMod, 1, false), cond: () => !powerMod.reel._swipeCooling },
            { act: () => win.wheelOn(powerMod, 1, false), wait: 2,
              then: () => win.check("the padlock arriving plays its close-and-open (cycle)", powerMod.reel.selectedItem.id === "lock" && win.clockOf("lock").kind === "cycle",
                                    powerMod.reel.selectedItem.id + " " + win.clockOf("lock").kind) },
            { act: () => {}, cond: () => win.clockOf("lock").t > 0.1 && !powerMod.reel._swipeCooling },
            { act: () => win.wheelOn(powerMod, 1, false), wait: 2,
              then: () => win.check("the padlock turned out of the cell mid-play plays on", powerMod.reel.selectedItem.id === "sleep" && win.clockOf("lock").kind === "cycle",
                                    powerMod.reel.selectedItem.id + " lock " + win.clockOf("lock").kind) },
            { act: () => win.away(), cond: () => !win.anyPlaying() && powerMod.reel.motion === 0 && !engine.reelOpen,
              then: () => {
                  win.rec.on = false;
                  for (const pl of win.rec.plays)
                      console.log("REELAUTO play " + pl.id + " " + pl.kind + " +" + pl.start + " ms .. " + (pl.end < 0 ? "never ended" : "+" + pl.end + " ms") + ", " + pl.frames + " frames, t to " + pl.lastT.toFixed(3));
                  const left = ReelItems.POWER.filter(it => { const c = win.clockOf(it.id); return c.playing || c._anim.running || c.t !== 0; }).map(it => it.id);
                  const pose = powerMod.flourishes.lockPose;
                  win.check("after the scroll every flourish has ended by itself: no clock left running, every icon at its rest pose",
                            left.length === 0 && pose.open === 1 && pose.knock === 0 && !powerMod.flourishes.shut && Object.keys(win.rec.open).length === 0,
                            "still running " + left.join(",") + " pose " + JSON.stringify(pose) + " open plays " + Object.keys(win.rec.open).join(","));
                  win.check("nothing was cut short or started over while the ring turned (each play ran its clock to the end)",
                            win.sum(win.rec.restarts) === 0 && win.sum(win.rec.cuts) === 0 && win.rec.plays.length >= 5,
                            "restarts " + JSON.stringify(win.rec.restarts) + " cuts " + JSON.stringify(win.rec.cuts) + " plays " + win.rec.plays.length);
                  win.check("the scroll fired nothing: no command ran and no action waited", runner.calls.length === win.mark.n && !win.rec.pending,
                            "calls " + runner.calls.length + " vs " + win.mark.n + " pending seen " + win.rec.pending);
                  win.check("the reel's own clocks are at rest (the turn, the pull, the flash)",
                            powerMod.reel.motion === 0 && powerMod.reel.swipePull === 0 && powerMod.reel.flash === 0 && !powerMod.reel.gestureLive,
                            "motion " + powerMod.reel.motion + " pull " + powerMod.reel.swipePull + " flash " + powerMod.reel.flash);
              } },
            // ---- the lock key goes the reel's way
            { act: () => { win.mark = { n: win.callsOf("lares-lock-session").length }; router.press("lock"); },
              then: () => win.check("the lares:lock key starts the lock through the reel's path, with the flourish",
                                    win.callsOf("lares-lock-session").length === win.mark.n + 1 && powerMod.flourishes.lock.kind === "engage", win.callsOf("lares-lock-session").length) }
        ]

        function finish(): void {
            console.log("REELAUTO RESULT " + (win.fails === 0 ? "PASS" : "FAIL") + " (" + (win.checks - win.fails) + "/" + win.checks + " checks)");
            quitT.start();
        }
        Timer {
            id: quitT
            interval: 0
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
                // A fault an ARM puts in may make a step throw: that is a failed check and the run goes on to its RESULT, never a hang.
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
                if (win.rec.on && actions.powerPending !== "")
                    win.rec.pending = true;
                const ready = s.cond ? guarded("cond", s.cond) : win.ticks >= (s.wait || 1);
                if (!ready && win.ticks < 400)
                    return;
                if (!ready)
                    win.check("step " + win.at + " reached its condition", false, "timed out");
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
