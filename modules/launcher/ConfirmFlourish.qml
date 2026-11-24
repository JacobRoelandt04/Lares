pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland

import "../common/theme"
import "FlourishPose.js" as Pose
import "FlourishFrame.js" as FF

// =============================================================================
// ConfirmFlourish.qml -- the launcher's confirm flourish, a THROW:
// the launched row detaches from the closing launcher and is THROWN: it flies up, reaches its apex with
// no speed at all, falls back (closing into a ball on the way) and splashes into its bar. One parabola,
// ONE gravity (confirmGravity: every length of the throw follows from it and the geometry, FlourishPose.throwOf), no pause at the
// top and no waiting for the launched window (the flourish does not wait on the application to start), like
// throwing a ball upwards. Nothing of the throw reads the launcher's close.
//
// Held by LauncherBarOwner: it outlives the popup's content, which the engine
// destroys when the launcher's close ends. It drives the engine's FLOURISH
// slot (GooeyEngine: openFlourish / setFlourish / setFlourishNeck /
// setFlourishGroup / setFlourishCut / rippleBar / spawnDroplets / closeFlourish) box by box from
// FlourishPose.js, and the slot's content is FlourishFace, which draws the
// row -- its icon, its title -- at the pose.
//
// THE TIMELINE (every number a LauncherTune `confirm*` value; ONE clock, the
// phase time `pt`, a FrameAnimation that runs only while a phase is timed and
// holds still while Theme.crossfading):
//   0 capture  LauncherPopup.launch: the row's facts and rect, the icon, the
//              well -- before anything resets (the owner's session reset waits
//              for the content's end)
//   1 lift     the row leaves its cell (the grid keeps the gap, frozen) and
//              compacts into the card through the launcher, whose close is
//              HELD (close({ hold })) and whose content fades
//   2 rise     the way up (FlourishPose.riseE): the card is pulled out at a growing pace, the
//              NECK between the card and the launcher (the engine's setFlourishNeck: two capsules and
//              the card's and the launcher's own fillets onto them, never
//              the two blended) thinning until the card has travelled detachFrac of
//              its way; there the strand snaps -- the launcher's close is let go and each half
//              retracts into its body over neckRetractMs -- and the freed card flies on, slowed at
//              a constant rate to no speed at all at the apex (the icon growing all the way)
//   3 fall     the way down, from the apex at the same gravity (FlourishPose.throwOf: sqrt(2 D / g), nobody's
//              tune): down on a quadratic, across the bar at the pace it has had since the launch, the card
//              hanging whole through the apex's slow part and then closing round the icon into a ball on
//              the way (confirmBallStart, confirmBallMs); the content is cut at the bar's face from its
//              first frame, and the ball's foot meets the face at its end
//   4 sink     the contact: the group {bar, flourish, droplets} (eased in by
//              the engine from k 0), rippleBar -- refused on a held bar, and
//              then no droplets either -- and the droplets a moment later; the
//              flourish closes once it is a merge radius deep
//   5 settle   the droplets land (each a ripple source); the group is cleared
//              when the last has gone; the engine's own clock ends the ripple.
//              Nothing of this runs any more.
// The launcher's close must be over by the contact (the ball falls where its body was, and a ripple is refused under a popup):
// on every preset it is, by a wide margin; a tune that breaks that gets the close cut short,
// never the throw changed.
//
// SKIP AHEAD: a popup opening while it plays makes it the ball where it is and
// drops it at once; a REOPEN of the launcher itself is held until
// the ball has merged (holdReopen: bounded), so the ball never falls through
// the growing launcher.
//
// POSED (the renders): `posed` stops the clock and the timers; poseAt(ms)
// places everything at nominal time ms, the
// launcher's held close and the engine's effects clock posed with it.
//
// THE TRANSPORT (the audio player's methodology -- PoseRecorder,
// Motion tab -- adapted: part of the picture is the engine's). Two halves:
//
//   live    `paused` and `timeScale` (0.25x..4x) apply to EVERYTHING the
//           flourish shows, not to its own clock alone. While either is off its
//           rest, the flourish TAKES the engine's clocks over (_takeEngine):
//           the launcher's held close and its content's fade (GooeyBody's own
//           NumberAnimations: stopped, and stepped here by the same dt) and the
//           effects clock (the ripple, the droplets, the group's ease:
//           effectsPosed, effectTime stepped here). So slow motion is the
//           real animation slowed, a pause holds every value to the digit, and
//           no clock runs while it holds. Back at 1x unpaused the engine takes
//           them back (_returnEngine) from where they stand, no jump. A run
//           reads its tune values ONCE, at its start (_tn): a panel slider
//           moved mid-run (a pause, a tweak, a resume) cannot re-time a phase
//           under the card.
//   record  `record` publishes every frame's RESULT as numbers (`frame`,
//           FlourishFrame.js) for a PoseRecorder in the host; playing it back
//           (enterReplay / handBack, applyFrame by the frame's `serial`) writes
//           those frames into the engine -- the body, the neck, the launcher's
//           held close, the cut, the group, the ripple and the droplets -- with
//           the live flourish frozen (posed) meanwhile. The engine's effects
//           only run forward, so a frame's effects are REBUILT: the contact
//           again (group, ripple), the droplets thrown at their recorded time,
//           the clock jumped to the frame's. The launcher's held close needs
//           the launcher: when a frame wants it and it has closed, the host is
//           asked (`openLauncherRequested`) to open it and the close is held
//           again (_restoreHost).
//   replay  replay() runs the last row again from its start.
// =============================================================================
Item {
    id: fl

    property var engine: null
    property var tune: null
    property string ownerId: "launcher"
    property string barId: ""
    property bool posed: false
    // THE TRANSPORT (header). `timeScale` multiplies every duration of the run;
    // `paused` holds it. Either, set before a flourish starts, applies from its
    // first frame.
    property real timeScale: 1
    property bool paused: false
    // Publish every frame's result in `frame` (a mockup's PoseRecorder target).
    property bool record: false
    // Asks the host to open the launcher (a replay and a scrub back into the
    // launcher's held close need it); the host connects it to its owner's open.
    // Nobody answering is a timeout, reported in `replayNote`.
    signal openLauncherRequested
    readonly property alias frame: frameState
    readonly property var frameKeys: FF.KEYS
    FlourishFrame {
        id: frameState
    }

    // "idle" | "lift" | "rise" | "fall" | "sink" | "settle"
    property string phase: "idle"
    readonly property bool playing: fl.phase !== "idle"
    // The capture's facts and the fixed geometry (FlourishPose ctx), the pose
    // on this frame, and what the face shows besides it.
    property var ctx: null
    property var pose: null
    property var face: null
    // Probes and the mockup read these.
    property real pt: 0
    property real elapsed: 0
    property bool released: false
    property real releasedAt: -1
    // The launcher's close is let go on its own moment: the end of the strand's recoil (the pinch, with confirmHostAfterRecoil off), or
    // `confirmHostCloseDelayMs` after the confirm when that is later -- on the run's clock (`_clock()`), -1 until the neck
    // is released. Skip-ahead and a reopen let it go at once.
    property real hostReleasedAt: -1
    // The launcher's free face where the strand parted (v; NaN before): the card's half of the neck is measured against it from then on,
    // so nothing the closing launcher does reaches the freed card (FlourishPose.neck).
    property real heldFaceV: NaN
    property bool rippleRefused: false
    property int dropletsThrown: 0
    property string skipReason: ""
    readonly property bool clockRunning: clock.running

    signal finished

    property var _from: null
    property var _host: null
    property bool _fast: false
    property bool _dropsDone: false
    property var _pendingOpen: null
    property real _sinkMs: 220
    property real _effectMs: 0
    // The neck: "off" until the rise, "on" while it is drawn, "gone" after its
    // retraction (or a skip): it never comes back in a run.
    property string _neck: "off"
    property real _retractMs: 160
    readonly property bool _timed: ["lift", "rise", "fall", "sink"].indexOf(fl.phase) >= 0

    // ---- A run's own copy of the tune ------------------------------------------------------------------
    // Taken when it starts (start()), dropped when it ends: while it runs every
    // value is the one it started with. `_t(name, fallback)` is the one reader.
    property var _tn: null
    readonly property var _tuned: [
        "bevelPx",
        "confirmBallEasing",
        "confirmBallMarginPx",
        "confirmBallMs",
        "confirmBallStart",
        "confirmCullFeatherPx",
        "confirmDetachFrac",
        "confirmDropletDelayMs",
        "confirmDropletPx",
        "confirmDropletVx",
        "confirmDropletVy",
        "confirmDroplets",
        "confirmGravity",
        "confirmGrowIcon",
        "confirmHostAfterRecoil",
        "confirmHostCloseDelayMs",
        "confirmHostCloseEasing",
        "confirmHostCloseMs",
        "confirmHostOvershoot",
        "confirmIconPx",
        "confirmLiftEasing",
        "confirmLiftMs",
        "confirmMergeK",
        "confirmNeckBulbPx",
        "confirmNeckEmergeFadePx",
        "confirmNeckEmergeGrowPx",
        "confirmNeckEmergeK",
        "confirmNeckInsetPx",
        "confirmNeckKA",
        "confirmNeckKB",
        "confirmNeckKJoin",
        "confirmNeckKMid",
        "confirmNeckMidFrac",
        "confirmNeckQPinchPx",
        "confirmNeckQStartPx",
        "confirmNeckRLFrac",
        "confirmNeckRUFrac",
        "confirmNeckRetractEasing",
        "confirmNeckRetractMs",
        "confirmPadPx",
        "confirmRadiusPx",
        "confirmReopenHoldMaxMs",
        "confirmRestClearPx",
        "confirmRestOffsetPx",
        "confirmRippleA",
        "confirmRippleB",
        "confirmRippleBulgeW",
        "confirmRippleDamping",
        "confirmRippleOnset",
        "confirmRippleSpeed",
        "confirmRippleTend",
        "confirmRippleWavelength",
        "confirmSinkEasing",
        "confirmSinkMs",
        "confirmSinkShrink",
        "confirmSkipBallMs",
        "confirmSkipFallMs",
        "confirmSkipSinkMs",
        "confirmTitleGapPx",
        "iconSize",
        "wellRadius"
    ]
    // The values outside the flourish that move the card: the launcher's own geometry
    // (the row, its icon, its name, the popup) -- a change re-captures the row (Re-pose, below).
    readonly property var _layoutTuned: [
        "columnGap",
        "columnWidth",
        "columns",
        "fontFamily",
        "headerHeight",
        "iconGap",
        "listWidth",
        "nameSize",
        "padding",
        "rowInset",
        "rows",
        "teaserHeight",
        "wikiTeaser"
    ]
    // Every one of them as it is now: ONE binding that reads them all, so it re-evaluates when
    // any of them moves and nothing else does (the idle cost of watching them is nil).
    readonly property var _tuneNow: {
        const o = {};
        const t = fl.tune;
        if (t) {
            for (const n of fl._tuned)
                o[n] = t[n];
            for (const n of fl._layoutTuned)
                o[n] = t[n];
        }
        return o;
    }
    function _t(name, d) {
        const t = fl._tn;
        if (t !== null && t[name] !== undefined)
            return t[name];
        return fl.tune ? fl.tune[name] : d;
    }
    function _snapTune() {
        const o = {};
        if (fl.tune)
            for (const n of fl._tuned)
                o[n] = fl.tune[n];
        fl._tn = o;
    }

    // ---- The phases' clocks ----------------------------------------------------------------------------
    function _msOf(ph) {
        switch (ph) {
        case "lift":
            return fl._t("confirmLiftMs", 280);
        case "rise":
            return fl.ctx ? fl.ctx.flight.riseMs : 0;
        case "fall":
            return fl._fallMs;
        case "sink":
            return fl._sinkMs;
        }
        return 0;
    }
    function _next(ph) {
        switch (ph) {
        case "lift":
            return "rise";
        case "rise":
            return "fall";
        case "fall":
            return "sink";
        case "sink":
            return "settle";
        }
        return "idle";
    }
    // The fall's length: the throw's (ctx.flight, FlourishPose.throwOf), fixed when the fall begins; a skipped run's is the short fixed one.
    property real _fallMs: 350
    function _fallMsOf(from) {
        if (fl._fast)
            return Math.min(200, fl._t("confirmSkipFallMs", 180));
        return fl.ctx.flight.downMs;
    }
    // The nominal timeline's length to the flourish's close: the mockup's LAUNCHER_PIN poses it over this.
    readonly property real nominalMs: fl._contactAt() + fl._t("confirmSinkMs", 110)
    // The moment of the contact on a run's clock: the lift, the throw's rise and fall.
    function _contactAt() {
        return fl._t("confirmLiftMs", 280) + (fl.ctx ? fl.ctx.flight.riseMs + fl.ctx.flight.downMs : 0);
    }

    // ---- Start ----------------------------------------------------------------------------------------
    // cap (LauncherGrid.flourishCapture): { key, item (the grid), rect (in
    // the grid), view (the list's viewport, in the grid), fade {head, foot,
    // h} (its edge fades), facts, room (the popup's hostRoom), well, star,
    // link, matchIndices, showFolder, name {x, y, w, h, natural}, icon {x, y} }.
    // False (nothing done) when the flourish cannot play here.
    function start(cap) {
        const E = fl.engine;
        if (!E || !cap || !cap.item || !cap.rect || !cap.room || fl.playing || fl._replaying)
            return false;
        const P = E.thePopup;
        if (!P || !P.live || P.ownerId !== fl.ownerId || !P.box)
            return false;
        // The run's own copy of the tune, from here to its end.
        fl._snapTune();
        fl._tail = false;
        fl._geom = fl._capGeom(cap, P);
        fl.ctx = fl._mkCtx();
        fl._geomLayout = fl._layoutOf(fl._tuneNow);
        fl.face = {
            facts: cap.facts,
            matchIndices: cap.matchIndices || [],
            showFolder: !!cap.showFolder,
            well: !!cap.well,
            star: cap.star,
            link: !!cap.link,
            linkHovered: !!cap.linkHovered,
            nameW: fl._geom.nameW,
            fade: fl._fadeOf(cap)
        };
        fl._host = P;
        fl._fast = false;
        fl._dropsDone = false;
        fl.released = false;
        fl.releasedAt = -1;
        fl.hostReleasedAt = -1;
        fl.heldFaceV = NaN;
        fl._hostGone = false;
        fl.rippleRefused = false;
        fl.dropletsThrown = 0;
        fl.skipReason = "";
        fl.elapsed = 0;
        fl._effectMs = 0;
        fl._neck = "off";
        fl._neckObj = null;
        fl._cutOn = false;
        fl._groupOn = false;
        fl._tape = null;
        fl._fxEpoch = 0;
        fl._lastKey = cap.key;
        fl._lastPack = null;
        fl._takeBase = fl._tuneNow;
        fl._takeSkipped = false;
        const p0 = Pose.rowPose(fl.ctx);
        fl.pose = fl._dressed(p0);
        if (fl.posed)
            E.effectsPosed = true;
        if (!E.openFlourish(fl.ownerId, faceComp, p0.box, {
                radii: p0.radii,
                clipFeather: 0,
                host: fl.ownerId,
                smoothK: 0
            })) {
            fl.ctx = null;
            fl.pose = null;
            fl._tn = null;
            return false;
        }
        // The launcher's close, held while the row lifts out of it; its content
        // fades now (the row is the flourish's, hidden in the grid).
        E.close({
            hold: true,
            ms: fl._t("confirmHostCloseMs", 400),
            easingIndex: fl._t("confirmHostCloseEasing", 3),
            overshoot: fl._t("confirmHostOvershoot", 1.2)
        });
        // Paused or slowed from the first frame: the engine's clocks are ours.
        if (fl._isDriven() && !fl.posed)
            fl._takeEngine();
        fl._enter("lift");
        fl._apply();
        return true;
    }

    // ---- The capture, and the fixed geometry built from it --------------------------------------------
    // What the capture says in the engine's own coordinates (nothing here reads the tune):
    // the row's rect, the list's viewport, the launcher's face and width, where the icon and the
    // name sit in the row. A re-pose rebuilds the ctx from it with the tune as it is NOW.
    property var _geom: null
    function _capGeom(cap, P) {
        const E = fl.engine;
        const r = E.mapFromItem(cap.item, cap.rect.x, cap.rect.y, cap.rect.w, cap.rect.h);
        const axis = {
            edge: cap.room.edge,
            face: cap.room.face
        };
        const vert = axis.edge === "top" || axis.edge === "bottom";
        const vw = cap.view ? E.mapFromItem(cap.item, cap.view.x, cap.view.y, cap.view.w, cap.view.h) : null;
        const centre = vert ? E.h / 2 : E.w / 2;
        return {
            key: cap.key,
            axis: axis,
            farV: Pose.toUV(axis, ...fl._farFace(axis.edge)).v,
            row: {
                x0: r.x,
                y0: r.y,
                x1: r.x + r.width,
                y1: r.y + r.height
            },
            view: vw ? {
                x0: vw.x,
                y0: vw.y,
                x1: vw.x + vw.width,
                y1: vw.y + vw.height
            } : null,
            hostV: Pose.footOf(axis, P.box) + Pose.outExtent(axis, P.box),
            hostW: Pose.alongExtent(axis, P.box),
            screenCentreV: Pose.toUV(axis, vert ? 0 : centre, vert ? centre : 0).v,
            anchorU: cap.room.center,
            nameW: Math.max(1, Math.ceil(cap.name.w)),
            nameNatural: Math.ceil(cap.name.natural),
            nameH: Math.ceil(cap.name.h),
            rowIcon: {
                x: cap.icon.x,
                y: cap.icon.y
            },
            rowTitle: {
                x: cap.name.x,
                y: cap.name.y
            }
        };
    }
    // A point on what stands across from the bar: the free face of the thickest bar on the far edge (the shell's top bar over a bottom
    // bar: the card's apex stays under it), or the far edge. In engine px, [x, y].
    function _farFace(edge) {
        const E = fl.engine;
        const far = edge === "bottom" ? "top" : edge === "top" ? "bottom" : edge === "left" ? "right" : "left";
        let t = 0;
        for (const b of E.barsList)
            if (b && b.edge === far)
                t = Math.max(t, Number(b.thickness) || 0);
        return far === "top" ? [0, t] : far === "bottom" ? [0, E.h - t] : far === "left" ? [t, 0] : [E.w - t, 0];
    }
    // The list's edge fades where the row was (a row at the foot of a list with more below it
    // lies under the foot's band): the face draws the same bands over itself, released with the well.
    function _fadeOf(cap) {
        const view = fl._geom.view;
        return view && cap.fade && (cap.fade.head > 0.001 || cap.fade.foot > 0.001) ? {
            x0: view.x0,
            y0: view.y0,
            x1: view.x1,
            y1: view.y1,
            head: cap.fade.head,
            foot: cap.fade.foot,
            h: cap.fade.h
        } : null;
    }
    // The layout values the capture was made with: a change of one of them needs the launcher
    // laid out again, so the row is captured again (_restoreHost).
    property var _geomLayout: null
    function _layoutOf(t) {
        const o = {};
        for (const n of fl._layoutKeys)
            o[n] = t[n];
        return o;
    }
    readonly property var _layoutKeys: ["iconSize"].concat(fl._layoutTuned)
    function _layoutStale() {
        return fl._geomLayout !== null && fl._differs(fl._layoutOf(fl._tuneNow), fl._geomLayout);
    }
    // The FlourishPose ctx: the capture's geometry and the tune's dimensions (_t).
    function _mkCtx() {
        const E = fl.engine, g = fl._geom;
        const ip0 = fl._t("iconSize", 40);
        const d = {
            ip0: ip0,
            ip1: fl._t("confirmGrowIcon", true) ? Math.round(fl._t("confirmIconPx", 56)) : ip0,
            pad: fl._t("confirmPadPx", 12),
            titleGap: fl._t("confirmTitleGapPx", 8),
            titleW: Math.min(g.nameW, g.nameNatural),
            titleH: g.nameH,
            radius: fl._t("confirmRadiusPx", 20),
            slack: 3,
            wellRadius: fl._t("wellRadius", 10),
            rowIcon: g.rowIcon,
            rowTitle: g.rowTitle,
            neckInset: fl._t("confirmNeckInsetPx", 6),
            midFrac: fl._t("confirmNeckMidFrac", 0.5),
            detachFrac: fl._t("confirmDetachFrac", 0.35),
            qStart: fl._t("confirmNeckQStartPx", 26),
            qPinch: fl._t("confirmNeckQPinchPx", 4),
            rUFrac: fl._t("confirmNeckRUFrac", 0.4),
            rLFrac: fl._t("confirmNeckRLFrac", 0.15),
            kA: fl._t("confirmNeckKA", 24),
            kB: fl._t("confirmNeckKB", 80),
            kMid: fl._t("confirmNeckKMid", 16),
            kJoin: fl._t("confirmNeckKJoin", 6),
            bulb: fl._t("confirmNeckBulbPx", 12),
            retractMs: fl._t("confirmNeckRetractMs", 160),
            retractEase: fl._t("confirmNeckRetractEasing", 0),
            emergeK: fl._t("confirmNeckEmergeK", 45),
            emergeGrowPx: fl._t("confirmNeckEmergeGrowPx", 2.3),
            emergeFadePx: fl._t("confirmNeckEmergeFadePx", 12),
            gravity: fl._t("confirmGravity", 3200),
            restClear: fl._t("confirmRestClearPx", 500),
            restOffset: fl._t("confirmRestOffsetPx", 0),
            ballMargin: fl._t("confirmBallMarginPx", 3),
            bevelPx: fl._t("bevelPx", 3),
            sinkShrink: fl._t("confirmSinkShrink", 0.6),
            mergeK: fl._t("confirmMergeK", 24),
            cullFeather: fl._t("confirmCullFeatherPx", 6),
            // One device pixel (FlourishPose.rowBox: a side cut to the viewport).
            px: 1 / Math.max(0.25, E.renderScale || 1)
        };
        const c = {
            key: g.key,
            axis: g.axis,
            row: g.row,
            view: g.view,
            hostV: g.hostV,
            hostW: g.hostW,
            screenCentreV: g.screenCentreV,
            farV: g.farV,
            anchorU: g.anchorU,
            dims: d
        };
        c.restGap = Pose.restGapOf(c);
        c.flight = Pose.throwOf(c);
        return c;
    }
    // The tune the take (the run's recording) was made with (`_tuneNow` as the run started).
    property var _takeBase: null

    Component {
        id: faceComp
        FlourishFace {
            flourish: fl
            tune: fl.tune
        }
    }

    // The pose plus what the face fades by time: the highlight well, the
    // row's marks and the list's edge fades over it go in 160 ms (a presence
    // fade), from the first frame.
    function _dressed(p) {
        const a = 1 - Pose.ease(1, fl.elapsed / 160);
        p.wellA = a;
        p.marksA = a;
        p.bandA = a;
        return p;
    }

    // ---- The clock -------------------------------------------------------------------------------------
    FrameAnimation {
        id: clock
        running: fl._timed && !fl.posed && !fl.paused && !Theme.crossfading
        onTriggered: fl._frame(clock.frameTime * 1000)
    }
    // The frames outside the timed phases that still move something: the
    // launcher's held close running out, the ripple and the droplets -- stepped
    // here while the engine's clocks are ours (the transport), published here
    // for the recorder. Not running at rest, and never when neither is asked.
    readonly property bool _hostAlive: !!fl._host && fl._host.phase === "closing" && fl._host.ownerId === fl.ownerId
    readonly property bool _fxLive: !!fl.engine && fl.engine.effectsLive
    FrameAnimation {
        id: observer
        running: (fl.playing || fl._tail) && !fl._timed && (fl._engineTaken || fl.record) && (fl._hostAlive || fl._fxLive) && !fl.posed && !fl.paused && !Theme.crossfading
        onTriggered: fl._frame(observer.frameTime * 1000)
    }
    // One frame of a run: the engine's clocks first when they are ours (the
    // launcher's box is where the neck reads it), then the phase, then the
    // effects -- all by the same scaled dt -- and the result published.
    function _frame(dt) {
        const d = fl._engineTaken ? dt * Math.max(0, fl.timeScale) : dt;
        if (fl._engineTaken)
            fl._stepHost(d);
        if (fl._timed)
            fl._advance(d);
        fl._hostTick();
        if (fl._engineTaken)
            fl._stepFx(d);
        fl._publish();
        if (fl._tail && !fl.engine.effectsLive) {
            fl._tail = false;
            fl._publish();
            fl._releaseTaken();
        }
    }
    // The ripple's tail after the run's end is still being stepped / recorded.
    property bool _tail: false
    // The engine ends the effects and the launcher's close on its own clocks at
    // 1x: nobody calls _frame at that moment, so the frame that shows it is
    // published here.
    Connections {
        target: fl._tail ? fl.engine : null
        function onEffectsLiveChanged() {
            if (!fl.engine.effectsLive) {
                fl._tail = false;
                fl._publish();
                fl._releaseTaken();
            }
        }
    }
    Connections {
        target: fl.record ? fl._host : null
        function onPhaseChanged() {
            fl._publish();
        }
    }

    function _enter(ph) {
        fl.phase = ph;
        fl.pt = 0;
        fl._from = fl.pose;
        const E = fl.engine;
        if (ph === "fall") {
            // The neck ends with the rise (a detach of 1 would leave it half retracted); an unfinished retraction
            // runs on into the fall (_poseNeck drops it when it is out).
            if (!fl.released)
                fl._release();
            // The fall's own length: the throw's gravity, or the short fixed one of a skipped run.
            fl._fallMs = fl._fallMsOf(fl._from);
            // From here the content is cut where it enters the bar's face.
            fl._setCut(true);
        } else if (ph === "sink") {
            // Its length is fixed as it begins: a reopen asked mid-sink must
            // not move its fraction (a jump of the ball).
            fl._sinkMs = fl.skipReason === "reopen" ? fl._t("confirmSkipSinkMs", 140) : fl._t("confirmSinkMs", 110);
            fl._dropNeck();
            fl._contact();
        } else if (ph === "settle") {
            fl._closeBody();
        }
    }

    function _advance(dt) {
        if (!fl._timed)
            return;
        fl.pt += dt;
        fl.elapsed += dt;
        let guard = 0;
        while (fl._timed && fl.pt >= fl._msOf(fl.phase) && guard++ < 16) {
            const over = fl.pt - fl._msOf(fl.phase);
            // The phase's last pose, then the next phase from it.
            fl.pt = fl._msOf(fl.phase);
            fl._apply();
            fl._enter(fl._next(fl.phase));
            if (fl._timed)
                fl.pt = over;
        }
        if (fl._timed)
            fl._apply();
    }

    function _apply() {
        const c = fl.ctx, E = fl.engine;
        if (!c || !E)
            return;
        const ms = fl._msOf(fl.phase);
        const f = ms > 0 ? Pose.clamp01(fl.pt / ms) : 1;
        let p = null;
        switch (fl.phase) {
        case "lift":
            p = Pose.lift(c, Pose.ease(fl._t("confirmLiftEasing", 4), f));
            break;
        case "rise":
            p = Pose.rise(c, Pose.riseE(c, f), fl._uShare(f * ms));
            break;
        case "fall":
            // Down on gravity's quadratic, across at the pace the throw has had since the launch, the card
            // closing round the icon on its way (_ballF).
            p = Pose.fall(c, fl._from, f * f, f, Pose.ease(fl._t("confirmBallEasing", 4), fl._ballF(f)));
            break;
        case "sink":
            p = Pose.sink(c, fl._from, Pose.ease(fl._t("confirmSinkEasing", 1), f));
            // No splash when a reopen waits for the merge: the launcher grows
            // out of the bar right there.
            if (!fl._dropsDone && fl.skipReason !== "reopen" && fl.pt >= fl._t("confirmDropletDelayMs", 30))
                fl._throwDroplets(p);
            break;
        default:
            return;
        }
        // The pinch: the launcher's close runs and the neck snaps.
        if (!fl.released && fl.phase === "rise" && Pose.travel(c, p) >= c.dims.detachFrac - 1e-6)
            fl._release();
        fl.pose = fl._dressed(p);
        if (fl.phase === "lift" || fl.phase === "rise" || fl.phase === "fall")
            fl._poseNeck(p);
        E.setFlourish(p.box, p.radii, {
            clipFeather: p.feather
        });
        if (fl.posed)
            fl._poseHost();
        else
            fl._publish();
    }

    // The throw's share of the way across the bar at `ms` into the rise (one constant pace from the row's centre to the
    // anchor, over the rise and the fall together).
    function _uShare(ms) {
        return ms / (fl.ctx.flight.riseMs + fl.ctx.flight.downMs);
    }
    // The ball's fraction at the fall's fraction f. The card stays whole through the first confirmBallStart of the fall -- it hangs
    // at the apex there, which is when it is read -- then closes over confirmBallMs (less when the fall is shorter), so it is a
    // ball a moment before the contact. A skipped run has no apex to read: its ball starts at once.
    function _ballF(f) {
        const ms = fl._msOf("fall");
        const at = fl._fast ? 0 : fl._t("confirmBallStart", 0.3) * ms;
        const b = Math.max(1, Math.min(fl._fast ? fl._t("confirmSkipBallMs", 100) : fl._t("confirmBallMs", 260), ms * 0.9 - at));
        return Pose.clamp01((f * ms - at) / b);
    }

    function _release() {
        fl.heldFaceV = fl._hostNow().faceV;
        fl.released = true;
        fl.releasedAt = fl.elapsed;
        // The launcher's close waits for the strand's recoil (confirmHostAfterRecoil): its body is what the card's stub is drawn against.
        const recoilEnd = fl._t("confirmHostAfterRecoil", true) ? fl._clock() + Math.max(1, fl.ctx.dims.retractMs) : 0;
        const contactAt = fl._fast || !fl.ctx ? Infinity : fl._contactAt();
        fl.hostReleasedAt = Math.max(fl._clock(), Math.min(Math.max(fl._t("confirmHostCloseDelayMs", 0), recoilEnd), contactAt - fl._hostLastMs));
        // The retraction takes the whole of confirmNeckRetractMs on the run's clock: it carries on into the
        // fall if the glide is shorter (a retracted neck is exactly the plain card and launcher).
        fl._retractMs = Math.max(1, fl.ctx.dims.retractMs);
        // The close's own length (cut short for the ball's landing) is the host's from now on, whoever steps it.
        const H = fl._hostOf();
        if (H)
            H.closeMs = fl._hostCloseMs();
        fl._hostTick();
    }

    // The run's clock in nominal ms.
    function _clock() {
        return fl.elapsed;
    }
    // How long the launcher's close takes: confirmHostCloseMs at most, and cut short so that it is OVER a moment (60 ms)
    // before the ball lands -- the ball falls where the launcher's body was, and a throw cannot wait for it. The contact is
    // the run's own fixed moment (lift + rise + the throw's fall); the close starts when the strand's recoil is over.
    function _hostCloseMs() {
        const tuned = Math.max(1, Math.round(fl._t("confirmHostCloseMs", 400)));
        if (!fl.ctx)
            return tuned;
        const lift = fl._t("confirmLiftMs", 280), T = fl.ctx.flight.riseMs;
        const a = Math.max(0.05, Math.min(0.95, fl._t("confirmDetachFrac", 0.35)));
        const contact = fl._contactAt();
        const recoil = fl._t("confirmHostAfterRecoil", true) ? Math.max(1, fl._t("confirmNeckRetractMs", 160)) : 0;
        const freeAt = Math.min(Math.max(lift + a * T + recoil, fl._t("confirmHostCloseDelayMs", 0)), contact - fl._hostLastMs);
        return Math.max(120, Math.min(tuned, Math.round(contact - freeAt - 60)));
    }
    // The launcher's close is let go at the latest this long (nominal ms) before the ball lands, whatever the recoil and the delay say: a
    // recoil longer than the throw has left would hold the close past the contact, and the ball would fall into an open launcher.
    readonly property real _hostLastMs: 180
    // The launcher's close is let go (the neck's release is the pinch; this is the later of it and the delay).
    function _hostFree() {
        return fl.released && fl.hostReleasedAt >= 0 && fl._clock() + 1e-6 >= fl.hostReleasedAt;
    }
    function _hostEnd() {
        return fl.hostReleasedAt + fl._hostCloseMs();
    }
    property bool _hostGone: false
    // Its close runs on the engine's clock -- or on ours while the transport has them.
    function _hostTick() {
        if (fl.posed || fl._engineTaken || fl._hostGone || !fl._hostFree() || !fl.engine)
            return;
        fl._hostGone = true;
        const P = fl._hostOf();
        if (P)
            P.closeMs = fl._hostCloseMs();
        fl.engine.releaseClose();
    }
    // ---- The neck ------------------------------------------------------------------------------------
    // The launcher's free face as it is now (it moves once its close is let
    // go), and its width along the bar.
    function _hostNow() {
        const P = fl._host, c = fl.ctx;
        if (P && P.box && P.phase === "closing" && P.ownerId === fl.ownerId)
            return {
                faceV: Pose.footOf(c.axis, P.box) + Pose.outExtent(c.axis, P.box),
                w: Pose.alongExtent(c.axis, P.box)
            };
        return {
            faceV: c.hostV,
            w: c.hostW
        };
    }
    function _poseNeck(p) {
        if (fl._neck === "gone")
            return;
        const c = fl.ctx, d = c.dims, h = fl._hostNow();
        // Not before the card stands out of the launcher: until then it is
        // inside the launcher's own picture (and a neck on changes how the
        // engine draws the launcher's text, which the detach must not).
        if (fl._neck === "off" && Pose.protrusion(c, p, h.faceV) <= 0)
            return;
        const r = fl.released ? Pose.clamp01((fl._clock() - fl.releasedAt) / fl._retractMs) : 0;
        if (r >= 1) {
            fl._dropNeck();
            return;
        }
        fl._neck = "on";
        fl._setNeck(Pose.neck(c, p, {
            faceV: h.faceV,
            heldFaceV: fl.released ? fl.heldFaceV : undefined,
            hostW: h.w,
            r: r
        }));
    }
    function _dropNeck() {
        if (fl._neck === "on" && fl.engine)
            fl._setNeck(null);
        fl._neck = "gone";
    }
    // What the engine was last handed for the neck and the cut (the recorder reads them).
    function _setNeck(n) {
        fl._neckObj = n;
        fl.engine.setFlourishNeck(n);
    }
    function _setCut(on) {
        fl._cutOn = on;
        fl.engine.setFlourishCut(on ? fl.barId : "");
    }

    // ---- The impact ----------------------------------------------------------------------------------
    function _contact() {
        const E = fl.engine, c = fl.ctx;
        // The contact as it was made, for a replay to make again (header).
        fl._fxEpoch = E.effectTime;
        const ids = ["bar:" + fl.barId, "flourish", "droplets"];
        E.setFlourishGroup(ids, c.dims.mergeK);
        fl._groupOn = true;
        const rp = {
            s: c.anchorU,
            sb: c.anchorU,
            A: fl._t("confirmRippleA", 5),
            B: fl._t("confirmRippleB", 10),
            w: fl._t("confirmRippleBulgeW", 32),
            onset: fl._t("confirmRippleOnset", 0.02),
            c: fl._t("confirmRippleSpeed", 560),
            gamma: fl._t("confirmRippleDamping", 2.5),
            wavelength: fl._t("confirmRippleWavelength", 30),
            Tend: fl._t("confirmRippleTend", 1.2)
        };
        const ok = E.rippleBar(fl.barId, rp);
        fl._tape = {
            ids: ids,
            k: c.dims.mergeK,
            ripple: ok ? rp : null,
            dropT: -1,
            drops: null
        };
        // Refused (a popup hangs from the bar, or another ripple runs): no
        // splash either -- its beads would land on a face that cannot move.
        fl.rippleRefused = !ok;
        if (!ok || fl.skipReason === "reopen")
            fl._dropsDone = true;
    }
    function _throwDroplets(p) {
        fl._dropsDone = true;
        const c = fl.ctx, E = fl.engine;
        const n = Math.max(0, Math.min(3, Math.round(fl._t("confirmDroplets", 2))));
        if (n === 0)
            return;
        const r = fl._t("confirmDropletPx", 6.5);
        const vx = fl._t("confirmDropletVx", 150), vy = fl._t("confirmDropletVy", 760);
        const R = Pose.outExtent(c.axis, p.box) / 2;
        const cu = Pose.centreUV(c, p).u;
        // Either side of the ball, at the face; a third straight up behind it.
        const sides = n === 1 ? [0] : n === 2 ? [-1, 1] : [-1, 1, 0];
        const list = [];
        for (const s of sides) {
            const u = cu + s * (R + r);
            const at = Pose.toXY(c.axis, u, r * 0.5);
            const up = Pose.toXY(c.axis, 0, 1), base = Pose.toXY(c.axis, 0, 0);
            const nx = up.x - base.x, ny = up.y - base.y;
            const tx = Math.abs(ny), ty = Math.abs(nx);
            const lift = s === 0 ? vy * 1.15 : vy;
            // (on the throw's own gravity: one world)
            list.push({
                x: at.x,
                y: at.y,
                vx: nx * lift + tx * s * vx,
                vy: ny * lift + ty * s * vx,
                r: s === 0 ? r * 0.75 : r,
                g: c.dims.gravity
            });
        }
        if (fl._tape) {
            fl._tape.dropT = E.effectTime - fl._fxEpoch;
            fl._tape.drops = list;
        }
        fl.dropletsThrown = E.spawnDroplets(fl.barId, list);
    }

    // ---- The end --------------------------------------------------------------------------------------
    function _closeBody() {
        const E = fl.engine;
        fl._setCut(false);
        E.closeFlourish();
        // A reopen held for the merge opens now.
        fl._runPendingOpen();
        if (!fl._reposing && (!E.droplets || E.droplets.length === 0))
            fl._finish();
    }
    Connections {
        target: fl.phase === "settle" ? fl.engine : null
        function onDropletsChanged() {
            // A take played back moves the droplets by itself: not the run's end.
            if (!fl._replaying && !fl._reposing && (!fl.engine.droplets || fl.engine.droplets.length === 0))
                fl._finish();
        }
    }
    function _finish() {
        if (fl.phase === "idle")
            return;
        const E = fl.engine;
        // The droplets merged: the group is the bar's alone, which is none.
        E.setFlourishGroup([], 0);
        fl._groupOn = false;
        fl.phase = "idle";
        // The take goes on until the ripple's tail is out (the observer), its
        // last frame has nothing of the flourish in the engine any more.
        fl._tail = !fl.posed && (fl._engineTaken || fl.record) && E.effectsLive;
        fl._publish();
        fl.ctx = null;
        fl._from = null;
        fl._host = null;
        fl._tn = null;
        if (!fl._tail)
            fl._releaseTaken();
        fl.finished();
    }

    // ---- Skip ahead, and the reopen ------------------------------------------------------------------
    // "popup": another popup opened -- it opens at once, the ball ignores it;
    // "reopen": the launcher itself -- it waits for the merge (holdReopen).
    function skipAhead(reason) {
        if (!fl.playing || fl.posed || fl._restoring)
            return;
        fl.skipReason = reason || "popup";
        fl._takeSkipped = true;
        if (fl.phase === "fall" || fl.phase === "sink" || fl.phase === "settle")
            return;
        if (!fl.released)
            fl._release();
        // The launcher's close, delayed or not, is let go now.
        fl.hostReleasedAt = Math.min(fl.hostReleasedAt, fl._clock());
        fl._hostTick();
        fl._dropNeck();
        fl._fast = true;
        fl._enter("fall");
        fl._apply();
    }
    // A reopen while it plays: held until the ball has merged (the flourish
    // closed), at most confirmReopenHoldMaxMs; true when held (`open` runs
    // later), false when nothing plays (open now).
    function holdReopen(open) {
        // (The launcher opening for a re-pose is the transport's, not a reopen to hold.)
        if (!fl.playing || fl.posed || fl._restoring || fl.phase === "settle")
            return false;
        fl._pendingOpen = open;
        reopenCap.interval = fl._t("confirmReopenHoldMaxMs", 700);
        reopenCap.restart();
        fl.skipAhead("reopen");
        return true;
    }
    // The held reopen taken back (the shortcut pressed again while it
    // waits): the ball goes on falling, nothing opens after it.
    function cancelReopen() {
        reopenCap.stop();
        fl._pendingOpen = null;
    }
    Timer {
        id: reopenCap
        onTriggered: fl._runPendingOpen()
    }
    function _runPendingOpen() {
        reopenCap.stop();
        const f = fl._pendingOpen;
        fl._pendingOpen = null;
        if (f)
            f();
    }

    // Another module's popup opening while it plays.
    Connections {
        target: fl.playing ? fl.engine : null
        function onPopupOpenChanged() {
            const E = fl.engine;
            if (E.popupOpen && E.popupOwnerId !== fl.ownerId)
                fl.skipAhead("popup");
        }
    }

    // ---- Posed -------------------------------------------------------------------------------------------
    // Everything at nominal time `ms` from the start (forward only: the
    // engine's group ease and effects are posed on relative steps of its
    // effects clock).
    function poseAt(ms) {
        if (!fl.posed)
            return;
        const dt = ms - fl.elapsed;
        if (dt <= 0)
            return;
        let left = dt;
        let guard = 0;
        while (left > 1e-6 && fl.phase !== "idle" && fl.phase !== "settle" && guard++ < 64) {
            const room = fl._msOf(fl.phase) - fl.pt;
            const step = Math.min(left, room);
            // Steps of a frame at most, so the engine's eases see the ramp.
            const n = Math.max(1, Math.ceil(step / 8));
            for (let i = 0; i < n; i++) {
                fl._poseEffectsBy(step / n);
                fl._advance(step / n);
            }
            left -= step;
        }
        // Closed (or done): the splash and the ripple on the effects clock.
        if (left > 1e-6) {
            fl._poseEffectsBy(left);
            fl.elapsed += left;
        }
        fl._apply();
    }
    function _poseEffectsBy(ms) {
        const E = fl.engine;
        if (!E || !fl.posed || ms <= 0)
            return;
        fl._effectMs += ms;
        E.effectTime = E.effectTime + ms / 1000;
    }
    // The launcher's held close, posed: held until the release, then on its
    // own curve; its content faded as the engine fades it.
    function _poseHost() {
        const P = fl._host, E = fl.engine;
        if (!P || P.phase !== "closing" || P.ownerId !== fl.ownerId)
            return;
        P.stop();
        // The close as the tune has it now (a re-pose changes them under a held close).
        const ms = fl._hostCloseMs();
        const ei = Math.round(fl._t("confirmHostCloseEasing", 3)), ov = fl._t("confirmHostOvershoot", 1.2);
        const curve = P.closeMs !== ms || P.easingIndex !== ei || P.overshoot !== ov;
        if (curve) {
            P.closeMs = ms;
            P.easingIndex = ei;
            P.overshoot = ov;
        }
        P.contentOpacity = Math.max(0, 1 - fl.elapsed / Math.max(1, E.contentFadeMs));
        const t = fl.released ? Pose.clamp01((fl.elapsed - fl.hostReleasedAt) / Math.max(1, P.closeMs)) : 0;
        if (P.t !== t)
            P.t = t;
        else if (curve)
            E.layout();
        // Its close over: finished as its own clock would finish it (the
        // content goes, the bar is free for the ripple).
        if (t >= 1)
            P.finished();
    }
    // Ends it where it is (a replay's start, a take's hand-back): the body
    // closed, the group, the cut and the neck cleared, a posed or held host's
    // close finished, the effects run out on a posed clock, idle -- and every
    // transport and replay flag down, so nothing of it is left in the engine.
    function abort() {
        const E = fl.engine;
        if (!E)
            return;
        fl._restoreStop();
        fl._relaunchStop();
        const P = fl._hostOf();
        if (P) {
            P.stop();
            P.t = 1;
            P.finished();
        }
        if (E.flourishOpen && E.flourishOwnerId === fl.ownerId) {
            fl._setCut(false);
            E.closeFlourish();
        }
        fl._setNeck(null);
        fl._neck = "gone";
        fl._setCut(false);
        E.setFlourishGroup([], 0);
        fl._groupOn = false;
        // A posed effects clock moved past every end: the ripple and the
        // droplets are over, and the engine goes idle on its own.
        if (E.effectsLive) {
            E.effectsPosed = true;
            E.effectTime = E.effectTime + 10;
        }
        E.effectsPosed = false;
        fl._pendingOpen = null;
        reopenCap.stop();
        fl.posed = false;
        fl.phase = "idle";
        fl.ctx = null;
        fl.pose = null;
        fl._from = null;
        fl._host = null;
        fl._tn = null;
        fl._tail = false;
        fl._engineTaken = false;
        fl._replaying = false;
        fl._liveFrozen = false;
        fl._handing = false;
        fl._fxAt = -2;
        fl._reposeWait = false;
        fl._reposing = false;
    }

    // Posed no more: the engine's clocks take it on from where it stands (the
    // transport's, when it is paused or slowed) -- the launcher's held close
    // and its fade continue from their values, never jump.
    function unpose() {
        if (!fl.posed)
            return;
        fl.posed = false;
        fl._goLive();
    }
    function _goLive() {
        if (fl._isDriven())
            fl._takeEngine();
        else
            fl._returnEngine();
    }

    // ---- The live transport ----------------------------------------------------------------------------
    // A function, not a binding: the change handlers below run before a binding
    // on the property that changed has been re-evaluated (CLAUDE.md, two
    // generations of one fact).
    function _isDriven() {
        return fl.paused || fl.timeScale !== 1;
    }
    property bool _engineTaken: false
    onPausedChanged: fl._syncTransport()
    onTimeScaleChanged: fl._syncTransport()
    function _syncTransport() {
        if (fl.posed || (!fl.playing && !fl._tail))
            return;
        if (fl._isDriven()) {
            fl._takeEngine();
            // The frame the engine's clocks stopped at: the engine ticked after
            // the last published one.
            fl._publish();
        } else {
            fl._returnEngine();
        }
    }
    // The launcher's held close, while it is closing and ours.
    function _hostOf() {
        const E = fl.engine;
        if (!E)
            return null;
        const a = fl._host, b = E.thePopup;
        if (a && a.phase === "closing" && a.ownerId === fl.ownerId)
            return a;
        if (b && b.phase === "closing" && b.ownerId === fl.ownerId)
            return b;
        return null;
    }
    // The engine's clocks, ours: the launcher's close and its content's fade
    // stop where they are, the effects' clock is posed.
    function _takeEngine() {
        const E = fl.engine;
        if (!E)
            return;
        fl._engineTaken = true;
        E.effectsPosed = true;
        const P = fl._hostOf();
        if (P)
            P.stop();
    }
    // ... and theirs again, from where they stand: a close not yet let go is
    // held again, one let go runs on, the fade continues at its own rate.
    function _returnEngine() {
        const E = fl.engine;
        if (!E)
            return;
        fl._engineTaken = false;
        if (!fl.posed)
            E.effectsPosed = false;
        const P = fl._hostOf();
        if (!P)
            return;
        if (!fl._hostFree()) {
            P.hold();
            P.flourishHold = true;
            P.holdFaded = true;
            fl._hostGone = false;
        } else if (P.t < 1) {
            fl._hostGone = true;
            P.runTo(1, P.closeMs);
        }
        if (P.contentOpacity > 0)
            P.fadeTo(0, E.contentFadeMs * P.contentOpacity);
    }
    // Where the transport ends: the engine is left as it was.
    function _releaseTaken() {
        if (!fl._engineTaken)
            return;
        fl._engineTaken = false;
        if (!fl.posed)
            fl.engine.effectsPosed = false;
    }
    // The launcher's close and fade on our clock: the same rates the engine's
    // own NumberAnimations run at (a linear t over closeMs, a linear fade over
    // contentFadeMs), by the scaled dt.
    function _stepHost(d) {
        const P = fl._host, E = fl.engine;
        if (!fl._hostAlive)
            return;
        if (P.contentOpacity > 0)
            P.contentOpacity = Math.max(0, P.contentOpacity - d / Math.max(1, E.contentFadeMs));
        if (fl._hostFree()) {
            const t = Math.min(1, P.t + d / Math.max(1, P.closeMs));
            if (t !== P.t)
                P.t = t;
            if (t >= 1)
                P.finished();
        }
    }
    function _stepFx(d) {
        const E = fl.engine;
        if (E.effectsLive)
            E.effectTime = E.effectTime + d / 1000;
    }

    // ---- The recorder's side ----------------------------------------------------------------------------
    property int _pubN: 0
    property var _lastPack: null
    property var _neckObj: null
    property bool _cutOn: false
    property bool _groupOn: false
    property var _tape: null
    property real _fxEpoch: 0
    property string _lastKey: ""
    // The row of the last run (what Replay launches).
    readonly property string lastKey: fl._lastKey
    // The frame's numbers (FlourishFrame.js): everything handed to the engine
    // and the engine clocks the picture depends on. Nothing when not recording
    // or posed (a take played back writes `frame` itself).
    function _publish() {
        if (!fl.record || fl.posed || !fl.engine || !fl.pose)
            return;
        const E = fl.engine, p = fl.pose, c = fl.ctx, P = fl._hostAlive ? fl._host : null;
        const o = FF.pack({
            el: fl.elapsed,
            pt: fl.pt,
            ph: FF.PHASES.indexOf(fl.phase),
            rel: fl.released,
            hrel: fl._hostFree(),
            gap: c ? Pose.gapOf(c, p) : undefined,
            trv: c ? Pose.travel(c, p) : undefined,
            pose: p,
            bodyOn: E.flourishOpen,
            neck: fl._neckObj,
            host: P ? {
                t: P.t,
                c: P.contentOpacity
            } : null,
            cut: fl._cutOn,
            groupOn: fl._groupOn,
            groupK: E.flourishGroupK,
            fxOn: !!fl._tape && E.effectsLive,
            fxT: E.effectTime - fl._fxEpoch,
            pg: fl._pgNow(),
            serial: ++fl._pubN
        }, fl._lastPack);
        fl._lastPack = o;
        const f = frameState;
        for (const k of FF.KEYS)
            if (f[k] !== o[k])
                f[k] = o[k];
    }

    // Where the run is, as one number no tune value can move: the phase's index plus the share of
    // it gone (the settle: 0 -- its clock is `fxT`).
    function _pgNow() {
        const k = FF.PHASES.indexOf(fl.phase);
        if (k <= 0)
            return 0;
        if (fl.phase === "settle")
            return k;
        const m = fl._msOf(fl.phase);
        return k + (m > 0 ? Pose.clamp01(fl.pt / m) : 1);
    }

    // ---- Re-pose: a value moved while the picture is held ------------------------------------
    // Two held pictures follow the panel: (a) a live run held by the transport's pause, and (b) a
    // recorded moment shown by the walk-through. Both are one operation. WHERE the run is -- a phase
    // and the fraction of it gone, never a time -- is read, the run's capture is kept (the row, its
    // rect, the icon: _geom), and the run is posed there again with the values as they are now:
    // the run's own state is reset to its start and poseAt() -- the posed path the renders use --
    // walks the new timeline to that moment, writing the body, the neck, the launcher's held close,
    // the cut, the group, the ripple and the droplets as it goes. A re-posed picture is therefore
    // what a fresh run posed at that phase and fraction shows, parameter by parameter.
    //
    //   timed phases   the same fraction of the phase (a duration moves the picture's time, not
    //                  its place; an easing shows its new curve at that fraction)
    //   the settle     the effects' clock (seconds since the contact) as it was: the ripple and
    //                  the droplets are rebuilt at that effect time with the new values
    //   a skipped run  stays as it was (its timeline is not a phase and a fraction any more)
    //
    // (a) rebuilds the live run in place, so resuming goes on from the held phase and fraction
    // with the new values. (b) shows the recorded frame's moment (FlourishFrame `pg`, `rn`,
    // `fxT`) and puts the live run's own fields back after it.
    property bool _reposing: false
    // How many pictures have been re-posed (a probe waits on it), and whether one is waiting for its frame.
    property int reposes: 0
    property bool _reposeWait: false
    property var _reposeW: null
    property bool _takeSkipped: false
    readonly property bool takeReposed: fl._takeBase !== null && !fl._takeSkipped && fl._differs(fl._tuneNow, fl._takeBase)
    function _differs(a, b) {
        if (!a || !b)
            return false;
        for (const k in a)
            if (a[k] !== b[k])
                return true;
        return false;
    }
    on_TuneNowChanged: {
        if (fl._reposing)
            return;
        if (fl._replaying || (fl.playing && fl.paused && !fl.posed && fl.skipReason === ""))
            repose.restart();
    }
    // One re-pose per frame however many values moved (a slider drag).
    Timer {
        id: repose
        interval: 0
        onTriggered: {
            if (fl._replaying)
                fl._applyFrame();
            else if (fl.playing && fl.paused && !fl.posed)
                fl._reposeLive();
        }
    }
    function _where() {
        const ph = fl.phase, E = fl.engine;
        const w = {
            phase: ph,
            f: 0,
            fx: 0
        };
        if (ph === "settle") {
            w.fx = Math.max(0, E.effectTime - fl._fxEpoch);
        } else {
            const m = fl._msOf(ph);
            w.f = m > 0 ? Pose.clamp01(fl.pt / m) : 1;
        }
        return w;
    }
    // The moment a recorded frame stands for (FlourishFrame.js: pg, rn, fxT).
    function _whereOfFrame(fr) {
        const k = Math.max(1, Math.min(FF.PHASES.length - 1, Math.floor(fr.pg + 1e-9)));
        const ph = FF.PHASES[k];
        return {
            phase: ph,
            f: ph === "settle" ? 0 : Pose.clamp01(fr.pg - k),
            fx: fr.fxT
        };
    }
    function _reposeLive() {
        const E = fl.engine;
        if (!E || !fl.ctx || !fl.playing || fl._reposing || fl.skipReason !== "" || fl.posed)
            return;
        const w = fl._reposeW || fl._where();
        fl._reposeW = null;
        fl._snapTune();
        if (fl._layoutStale()) {
            // The launcher laid out with the new values: its held close goes, the launcher is
            // opened afresh, the row captured in it, and the re-pose runs from there.
            fl._dropHost();
            fl._reposeW = w;
            fl._reposeWait = true;
            fl._restoreHost();
            return;
        }
        if (!fl._rebuild(w)) {
            // The launcher is brought back first; the re-pose runs when it is there, from the
            // same moment.
            fl._reposeW = w;
            fl._reposeWait = true;
            fl._restoreHost();
            return;
        }
        fl._afterRebuild();
        fl.reposes++;
        fl._publish();
        if (fl.phase === "settle" && (!E.droplets || E.droplets.length === 0) && !E.effectsLive)
            fl._finish();
    }
    function _dropHost() {
        const P = fl._hostOf();
        if (!P)
            return;
        P.stop();
        P.t = 1;
        P.finished();
        fl._host = null;
    }
    // The engine's clocks are the transport's again, as they were before the re-pose.
    function _afterRebuild() {
        if (fl._isDriven())
            fl._takeEngine();
        else
            fl._returnEngine();
    }
    // The run from its start to `w`, with the values of `_t()` as they are now. False when the
    // picture needs the launcher's held close and the launcher is not there.
    function _rebuild(w) {
        const E = fl.engine, was = fl.posed;
        fl._reposing = true;
        fl.posed = true;
        fl.ctx = fl._mkCtx();
        // The run as it is at its start: nothing of the effects, the neck, the cut or the group
        // in the engine, the card on its row.
        fl._fxIdle();
        fl._tape = null;
        fl._fxEpoch = 0;
        fl._dropsDone = false;
        fl._fast = false;
        fl._setNeck(null);
        fl._neck = "off";
        fl._setCut(false);
        fl.phase = "lift";
        fl.pt = 0;
        fl.elapsed = 0;
        fl._effectMs = 0;
        fl.released = false;
        fl.releasedAt = -1;
        fl.hostReleasedAt = -1;
        fl.heldFaceV = NaN;
        fl._hostGone = false;
        fl.rippleRefused = false;
        fl.dropletsThrown = 0;
        fl._host = fl._hostOf();
        const p0 = Pose.rowPose(fl.ctx);
        fl.pose = fl._dressed(p0);
        fl._from = fl.pose;
        if (E.flourishOpen && E.flourishOwnerId === fl.ownerId)
            E.setFlourish(p0.box, p0.radii, {
                clipFeather: 0
            });
        else if (!E.openFlourish(fl.ownerId, faceComp, p0.box, {
                radii: p0.radii,
                clipFeather: 0,
                host: fl.ownerId,
                smoothK: 0
            })) {
            fl.posed = was;
            fl._reposing = false;
            return true;
        }
        // The timeline's length to the moment.
        let T = 0;
        const order = ["lift", "rise", "fall", "sink"];
        // The fall's length is the throw's (fixed as the fall begins, so it is read for the timeline from the ctx just made).
        const ms = q => q === "sink" ? fl._t("confirmSinkMs", 110) : q === "fall" ? fl.ctx.flight.downMs : fl._msOf(q);
        let gone = 0;
        for (const q of order) {
            if (q === w.phase)
                break;
            gone += ms(q);
        }
        if (w.phase === "settle")
            T = gone - ms("sink") + w.fx * 1000;   // the effect clock counts from the contact, the sink's start
        else
            T = gone + w.f * ms(w.phase);
        if (T > 1e-6)
            fl.poseAt(T);
        else
            fl._apply();
        // The picture needs the launcher's close where the timeline says it still runs.
        const need = !fl.released || fl.elapsed < fl._hostEnd();
        fl.posed = was;
        fl._reposing = false;
        if (need && !fl._hostOf())
            return false;
        return true;
    }

    // (b) A recorded frame, its moment re-posed with the values now. The live run's own fields
    // (a take played over a held run) go back after it: the walk-through never changes the run.
    readonly property var _runFields: ["phase", "pt", "elapsed", "released", "releasedAt", "hostReleasedAt", "heldFaceV", "_hostGone", "_from", "ctx", "_tn", "_neck", "_tape", "_fxEpoch", "_dropsDone", "_sinkMs", "dropletsThrown", "rippleRefused", "_fast", "_fallMs", "_host", "_effectMs"]
    function _applyReposed(fr) {
        if (fl._layoutStale()) {
            fl._dropHost();
            fl._restoreHost();
            return;
        }
        const stash = {};
        for (const k of fl._runFields)
            stash[k] = fl[k];
        fl._snapTune();
        const ok = fl._rebuildFrame(fl._whereOfFrame(fr));
        // What the engine holds is the re-posed picture's (the pose, the neck, the cut, the group
        // stay as written); the plain path rebuilds its effects from the take's own tape.
        const pose = fl.pose;
        for (const k of fl._runFields)
            fl[k] = stash[k];
        fl.pose = pose;
        fl._fxAt = -2;
        fl._dropped = false;
        fl.reposes++;
        if (!ok)
            fl._restoreHost();
    }
    function _rebuildFrame(w) {
        return fl._rebuild(w);
    }

    // ---- A take played back ----------------------------------------------------------------------------
    // PoseRecorder's `beforeScrub` calls enterReplay(); every write of a frame
    // ends on `serial`, which applies it; handBack() is the way out.
    property bool _replaying: false
    readonly property bool replaying: fl._replaying
    property bool _liveFrozen: false
    property bool _handing: false
    property bool _restoring: false
    property int _recapAt: -1
    property bool _relaunching: false
    // True while the launcher is being brought back for a frame (or the row's
    // replay is waiting for it): the frame written last lands when it is there.
    readonly property bool replayBusy: fl._restoring || fl._relaunching
    property string replayNote: ""
    property real _fxAt: -2
    property bool _dropped: false

    function enterReplay() {
        if (fl._replaying)
            return;
        fl._replaying = true;
        fl._liveFrozen = fl.playing;
        fl._relaunchStop();
        fl._tail = false;
        // Posed: the clock, the timers and the pose's writers stand down.
        fl.posed = true;
        fl._takeEngine();
        fl._fxAt = -2;
    }
    Connections {
        target: frameState
        function onSerialChanged() {
            if (fl._replaying)
                fl._applyFrame();
        }
    }
    // The engine as the frame written into `frame` says.
    function _applyFrame() {
        const E = fl.engine;
        if (!E || !fl._replaying || !fl.face || fl._restoring)
            return;
        const fr = FF.unpack(frameState);
        // A parameter differs from the take's: its moment (phase, fraction), not its numbers.
        if (!fl._handing && fl.takeReposed && fl._geom && fr.ph > 0) {
            fl._applyReposed(fr);
            return;
        }
        // 1 the launcher's held close
        const P = fl._hostOf();
        if (fr.hostOn) {
            if (!P) {
                fl._restoreHost();
                return;
            }
            P.stop();
            // The close's curve as the take was made with (a re-posed frame may have changed it).
            const B = fl._takeBase;
            if (B) {
                const ms = Math.max(1, Math.round(B.confirmHostCloseMs)), ei = Math.round(B.confirmHostCloseEasing);
                if (P.closeMs !== ms || P.easingIndex !== ei || P.overshoot !== B.confirmHostOvershoot) {
                    P.closeMs = ms;
                    P.easingIndex = ei;
                    P.overshoot = B.confirmHostOvershoot;
                    E.layout();
                }
            }
            if (P.contentOpacity !== fr.hostC)
                P.contentOpacity = fr.hostC;
            if (P.t !== fr.hostT)
                P.t = fr.hostT;
            fl._host = P;
        } else if (P) {
            P.stop();
            P.t = 1;
            P.finished();
        }
        // 2 the body and the face's pose
        const mine = E.flourishOpen && E.flourishOwnerId === fl.ownerId;
        if (fr.bodyOn) {
            if (!mine && !E.openFlourish(fl.ownerId, faceComp, fr.pose.box, {
                    radii: fr.pose.radii,
                    clipFeather: 0,
                    host: fl.ownerId,
                    smoothK: 0
                }))
                return;
            fl.pose = fr.pose;
            E.setFlourish(fr.pose.box, fr.pose.radii, {
                clipFeather: fr.pose.feather
            });
        } else {
            if (mine) {
                fl._setCut(false);
                E.closeFlourish();
            }
            fl.pose = fr.pose;
        }
        // 3 the neck and the cut
        fl._setNeck(fr.neck);
        fl._setCut(fr.cutOn);
        // 4 the ripple and the droplets
        fl._applyFx(fr);
        if (fl._handing)
            fl._finishHandBack();
    }
    // The effects only run forward: a frame at or after the one shown moves the
    // clock; any other rebuilds the contact (group, ripple), throws the droplets
    // at their recorded time and jumps the clock.
    function _applyFx(fr) {
        const E = fl.engine, T = fl._tape;
        const want = fr.fxOn && T ? fr.fxT : -1;
        if (want < 0) {
            if (fl._fxAt !== -1) {
                fl._fxIdle();
                fl._fxAt = -1;
            }
            return;
        }
        if (fl._fxAt < 0 || want < fl._fxAt - 1e-9) {
            fl._fxIdle();
            E.effectsPosed = true;
            // The take's times are relative to the contact: the clock starts at 0 again, so the
            // ripple's epoch (the clock when it starts) is 0 as the take's `fxT` assumes.
            if (!E.effectsLive && E.effectTime !== 0)
                E.effectTime = 0;
            E.setFlourishGroup(T.ids, T.k);
            fl._groupOn = true;
            // The effects' clock starts at 0 again: the take's times are relative to the contact.
            fl._fxEpoch = 0;
            if (T.ripple)
                E.rippleBar(fl.barId, T.ripple);
            E.layout();
            fl._fxAt = 0;
            fl._dropped = false;
        }
        if (!fl._dropped && T.drops && T.dropT >= 0 && want >= T.dropT) {
            E.effectTime = T.dropT;
            E.spawnDroplets(fl.barId, T.drops);
            fl._dropped = true;
        }
        if (E.effectTime !== want)
            E.effectTime = want;
        fl._fxAt = E.effectsLive ? want : -1;
        // The droplets merged: the group is the bar's alone, which is none.
        if (!fr.groupOn) {
            E.setFlourishGroup([], 0);
            fl._groupOn = false;
        }
    }
    function _fxIdle() {
        const E = fl.engine;
        E.effectsPosed = true;
        E.setFlourishGroup([], 0);
        fl._groupOn = false;
        E.layout();
        // The clock past every end: the ripple and the droplets are over. (A ripple that is still
        // there refuses the next contact, so the clock is taken on until it has gone.)
        // (past the ripple's own epoch too: a clock posed back leaves it ahead of the clock)
        for (let i = 0; i < 4 && (E.effectsLive || E._rippleBarId !== ""); i++)
            E.effectTime = Math.max(E.effectTime, E._rippleEpoch) + 10;
    }

    // The launcher's held close again, for a frame that has it after it closed:
    // the host opens the launcher (`openLauncher`), the close is held and
    // frozen, the row hidden in the list as the launch had it.
    function _restoreHost() {
        if (fl._restoring)
            return;
        fl._restoring = true;
        fl.replayNote = "bringing the launcher back";
        restorePoll.n = 0;
        restorePoll.start();
    }
    function _restoreStop() {
        restorePoll.stop();
        fl._recapAt = -1;
        fl._restoring = false;
        if (!fl._relaunching)
            fl.replayNote = "";
    }
    Timer {
        id: restorePoll
        interval: 30
        repeat: true
        property int n: 0
        onTriggered: {
            const E = fl.engine;
            restorePoll.n++;
            if (!E || restorePoll.n > 300) {
                fl._restoreStop();
                fl.replayNote = "the launcher did not come back";
                return;
            }
            const P = fl._launcherReady(restorePoll.n);
            if (!P)
                return;
            const g = fl._find(P.contentItem, "launcherGrid");
            // Laid out with other values than the capture's: the row is captured again, where
            // it comes to rest in this launcher (as a launch would, FlourishCapture).
            if (fl._layoutStale()) {
                const i = g.order.indexOf(fl._lastKey);
                if (i < 0) {
                    fl._restoreStop();
                    fl._reposeWait = false;
                    fl.replayNote = "the row is not in the list now";
                    return;
                }
                if (fl._recapAt < 0) {
                    g.reveal(fl._lastKey);
                    g.current = i;
                    fl._recapAt = restorePoll.n;
                    return;
                }
                if (restorePoll.n - fl._recapAt < 9)
                    return;
                const cap = g.flourishCapture(fl._lastKey);
                fl._recapAt = -1;
                if (!cap) {
                    fl._restoreStop();
                    fl._reposeWait = false;
                    fl.replayNote = "the row could not be captured again";
                    return;
                }
                cap.room = P.contentItem.hostRoom;
                fl._geom = fl._capGeom(cap, P);
                fl._geomLayout = fl._layoutOf(fl._tuneNow);
                fl.face = Object.assign({}, fl.face, {
                    nameW: fl._geom.nameW,
                    fade: fl._fadeOf(cap)
                });
            }
            if (fl._lastKey !== "")
                g.hiddenKey = fl._lastKey;
            g.frozen = true;
            P.contentItem.confirmed = true;
            fl._host = P;
            E.close({
                hold: true,
                ms: fl._t("confirmHostCloseMs", 400),
                easingIndex: fl._t("confirmHostCloseEasing", 3),
                overshoot: fl._t("confirmHostOvershoot", 1.2)
            });
            P.stop();
            fl._restoreStop();
            if (fl._reposeWait) {
                fl._reposeWait = false;
                fl._reposeLive();
            } else {
                fl._applyFrame();
            }
        }
    }
    // The launcher, open and loaded -- asking for it (again every 600 ms) until it is.
    function _launcherReady(n) {
        const E = fl.engine, P = E.thePopup;
        if (!(E.popupOpen && E.popupOwnerId === fl.ownerId)) {
            if (n % 20 === 1)
                fl.openLauncherRequested();
            return null;
        }
        if (P.phase !== "open" || P.t < 1 || !P.contentItem || !fl._find(P.contentItem, "launcherGrid"))
            return null;
        return P;
    }
    function _find(item, name) {
        if (!item)
            return null;
        for (let i = 0; i < item.children.length; i++) {
            const c = item.children[i];
            if (c.objectName === name)
                return c;
            const f = fl._find(c, name);
            if (f)
                return f;
        }
        return null;
    }

    // The way out of a take. A live run that was held under it goes on from its
    // last frame (written back first); a finished take leaves the engine idle.
    function handBack() {
        if (!fl._replaying)
            return;
        fl._restoreStop();
        if (!fl._liveFrozen || !fl._lastPack) {
            fl.abort();
            return;
        }
        fl._handing = true;
        const o = fl._lastPack;
        for (const k of FF.KEYS)
            if (frameState[k] !== o[k])
                frameState[k] = o[k];
        fl._applyFrame();
    }
    function _finishHandBack() {
        fl._handing = false;
        fl._replaying = false;
        fl._liveFrozen = false;
        fl.posed = false;
        fl._goLive();
        // The walk-through showed the values as they are now: the run goes on with them.
        let moved = false;
        if (fl._tn)
            for (const k of fl._tuned)
                if (fl._tn[k] !== fl._tuneNow[k])
                    moved = true;
        if (fl.playing && fl.skipReason === "" && (moved || fl._layoutStale()))
            fl._reposeLive();
    }

    // ---- Replay: the last row again, from its start ----------------------------------------------------
    // Whatever is on (a live run, a take being played) is taken down to idle,
    // the launcher is opened if it is closed, the row captured last is
    // revealed in it and launched -- with the transport as it is set.
    property real _relaunchRevealed: -1
    function replay() {
        if (fl._lastKey === "")
            return false;
        fl.abort();
        fl._relaunching = true;
        fl._relaunchRevealed = -1;
        fl.replayNote = "opening the launcher";
        relaunchPoll.n = 0;
        relaunchPoll.start();
        return true;
    }
    function _relaunchStop() {
        relaunchPoll.stop();
        fl._relaunching = false;
        if (!fl._restoring)
            fl.replayNote = "";
    }
    Timer {
        id: relaunchPoll
        interval: 30
        repeat: true
        property int n: 0
        onTriggered: {
            relaunchPoll.n++;
            if (relaunchPoll.n > 300) {
                fl._relaunchStop();
                fl.replayNote = "the launcher did not open";
                return;
            }
            const P = fl._launcherReady(relaunchPoll.n);
            if (!P)
                return;
            const g = fl._find(P.contentItem, "launcherGrid");
            const i = g.order.indexOf(fl._lastKey);
            if (i < 0) {
                fl._relaunchStop();
                fl.replayNote = "the row is not in the list now";
                return;
            }
            // The list scrolls to it; the capture is of where it comes to rest.
            if (fl._relaunchRevealed < 0) {
                g.reveal(fl._lastKey);
                g.current = i;
                fl._relaunchRevealed = relaunchPoll.n;
                return;
            }
            if (relaunchPoll.n - fl._relaunchRevealed < 9)
                return;
            const key = fl._lastKey;
            fl._relaunchStop();
            P.contentItem.launch(key, false);
        }
    }
}
