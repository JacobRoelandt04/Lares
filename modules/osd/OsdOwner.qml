pragma ComponentBehavior: Bound

import QtQuick
import QtQml.Models

import "../common/components"
import "../common/components/BarSpot.js" as BarSpot
import "data/OsdKinds.js" as Kinds

// =============================================================================
// OsdOwner.qml -- the OSD on ONE screen: what is asked, what is shown, when it goes.
//
// The service (one per shell) says `request(req)` for everything that is worth
// showing; this owner turns that into the engine's OSD slot (theOsd) -- or, in
// fullscreen, into the top-centre pill -- and keeps the clock of what it showed.
// CONTRACT.md section 6 is the surface; the rules, in the order a request meets them:
//
//   WHERE.  A fullscreen window with mode "pill" hands the request to the pill
//           (`pill.present`), with mode "suppress" drops it, with mode "keys" drops
//           what the user did not do (OsdKinds.byUser). Otherwise the spot
//           (BarSpot.placeOf: a bar and where along it, or a corner = along 0/1
//           of the bar on that edge) names the bar; the bar's edge is the
//           orientation (a left/right bar -> "v", else "h").
//   DIP OR IN PLACE.  The engine decides by component + key (key = kind:key,
//           one Component per kind). The owner mirrors it into two payloads:
//           `shown` is what is on screen; `pending` waits for the bottom of a
//           dip (`engine.osdSwap`) and becomes `shown` exactly there, so the
//           content never shows the new payload before the swap. A request for
//           the same kind + key updates `shown` in place (or `pending`, when it
//           is the one waiting; or cancels the swap, when it is `shown`'s again).
//   WHEN IT GOES.  One single-shot timer for the latest request: `req.ms`, else
//           dismissMs. Hover freezes it; on leave the rest is
//           max(rest, resumeMinMs). Any touch of the content (`touched()`) and
//           any request merged in place re-arms it in full (frozen while hovered).
//           A bar that is `osdBlocked` changes nothing here: the timer runs, the
//           request just expires.
//   WHAT WAITS.  User kinds (a key, an action) pre-empt at once: they are shown
//           now, whatever is out. Event kinds (the system) that find something
//           shown wait in a FIFO deduped by kind + key (a repeat updates the
//           waiting one), capped at queueCap (the OLDEST is dropped: a stale
//           event is the one nobody needs). The head takes over when the shown
//           one expires, or -- when the shown one is itself an event -- once it
//           has been out minShowMs; never while the pointer holds it, and never
//           from under a user kind.
//   WHAT IS HELD BACK.  The player's own open popup says what the now-playing card would, so
//           with `service.playerOpen` (the player module is open on any screen: mini, normal, with
//           its side panel) a `track` request is dropped on arrival -- not queued -- and the ones
//           already waiting go the moment it opens (OsdKinds.suppressedBy). What is on screen
//           runs out; a kind routed to a desktop notification never gets here. A LOCKED session
//           (`service.locked`) holds the same card back: the lock screen already shows what plays.
//   FULLSCREEN FLIPS while something is shown: it moves to the other surface
//           (close one, present on the other) and keeps its remaining time.
//   HIDDEN.  A card can be hidden by the user (the caption's hide button, `hideRequested`): on a bar it TUCKS into its
//           bar until a sliver stands out (the engine's `tucked`), in the pill it collapses to a ball that rises half off the
//           screen's top and fades to a faint presence. The card keeps running underneath -- its renewals land in place, its
//           clock is the same -- and comes back out when the pointer MOVES onto the sliver (the engine's `osdTuckZone`, a
//           HoverArm) or the ball. Hidden is the card's KEY's: another card in between comes out as ever, and the hidden one
//           returns hidden; it is forgotten when the card is withdrawn or the OSD is dismissed (the take ended).
//
// The contents are made by the engine from one Component per kind; each is
// bound to this owner (`shown`, style, orientation, scale) and reports back
// through the service (userValue / userToggleMute / userToggleBoost), through
// `touched` (re-arm) and through `hovered` (hold). The hover is a COUNT over the
// live contents, so a content destroyed under the pointer lets go.
//
// SEVERAL SCREENS (shell-hosted). The service is one per shell and every screen has an
// owner on it, so every request would be presented on every screen. `active` is the host's
// switch (CONTRACT section 4): it is true on the owner of ONE screen -- the focused one, or the display osd.jsonc names (`screen`).
// An inactive owner presents nothing and QUEUES nothing (a request is dropped on arrival,
// so the owner that becomes active starts from an empty queue and shows what happens next,
// never a backlog of events nobody saw), and whatever it had out is taken away the moment
// it goes inactive (the focus moved: the pill or the slot folds on the screen it left).
// The rest of what osd.jsonc says -- `spot`, `screen`, `fullscreenMode`, `dismissMs`, `resumeMinMs`, `queueCap`,
// `captureClick` -- are plain properties the host binds from `service.config.config` (spot, screen, fullscreen,
// dismissMs, resumeMinMs, queueCap, capture.click), and `fullscreen` is the host's per screen (the workspace
// THAT screen shows has a fullscreen window). `minShowMs` is the module's own constant (the
// OSD mockup's Timing rows tune it).
// =============================================================================
Item {
    id: owner

    required property var engine
    property var service: null
    property var style: null
    property string ownerId: "osd"
    property string screenName: ""
    // The shell's one focus tracker (a FocusedScreen, modules/common/system). With it `active` and
    // `fullscreen` are DEFAULTS read from it -- this owner's screen is the one the OSD comes on; the
    // workspace this screen shows has a fullscreen window -- and a host that assigns either itself (a
    // mockup) overrides them. An unknown focus ("") leaves every owner active rather than none.
    // null = today's behaviour.
    property var focusSource: null
    // Which display it comes on: "focused", or a connector's name (the focused one while that one is not there).
    property string screen: "focused"
    readonly property string _display: owner.focusSource ? owner.focusSource.displayFor(owner.screen) : ""
    // The host's switch for several screens (see above): false = present nothing, queue
    // nothing, and take away what is out. Default true: a single-screen host (the mockup,
    // today's probes) is unchanged.
    property bool active: owner._display === "" || owner._display === owner.screenName
    property var spot: ({ bar: "right", along: 0.5 })
    property bool fullscreen: owner.focusSource ? owner.focusSource.fullscreenOn(owner.screenName) : false
    // "pill" | "keys" (the pill for what the user did alone) | "suppress"
    property string fullscreenMode: "pill"
    // The bars are hidden (the shell's toggle, Super+F2): the OSD has no bar to come out of and melt into, so it is the pill, as it is over a
    // fullscreen window (it would otherwise shrink into a bar that visually does not exist). false with no host.
    property bool barsHidden: false
    property var pill: null
    // THE LIVE CURTAIN (ThemeWipe) runs on this screen. A run's still holds nothing of what the shell covered, so where a card leaves, what shows until the line comes is a soft
    // fill: a blurred card (a ghost OSD with image compression artifacts). While this is true what is out stays out: its clock may end and a request of another
    // key waits; both happen when the line has passed. The same key updates in place, and an OSD with nothing out opens as ever: it stands over the still.
    property bool held: false
    // The shell's natural-scroll reader (modules/shell/NaturalScroll.qml: `touchpad` / `mouse` flags; null = nobody flips): the
    // host hands in the ONE it already has (VolumeParity's), so the OSD starts no hyprctl of its own. The wheel over a level
    // follows it, as the volume pill's does.
    property var naturalScroll: null
    // How long a card stays when its request names no time.
    property int dismissMs: 2000
    property int resumeMinMs: 800
    // A click on a screenshot's card: "edit" | "open" | "none".
    property string captureClick: "edit"
    // An event kind is shown at least this long before the next waiting one takes over (a constant: 600, time to read a glyph and a word).
    property int minShowMs: 600
    property int queueCap: 3

    // Payload on screen, payload waiting for the swap, the hold.
    property var _shown: null
    property var _pending: null
    readonly property var shown: owner._shown
    readonly property var pending: owner._pending
    readonly property bool hovered: owner._hoverCount > 0
    property int _hoverCount: 0

    // Where the spot stands now: { barId, local, alongAt, ... } or null (no bar for it).
    readonly property var place: BarSpot.placeOf(owner.spot, owner.engine ? owner.engine.barsList : null)
    readonly property string orientation: {
        const bars = owner.engine ? owner.engine.barsList : null;
        const b = owner.place && bars ? bars.find(x => !!x && x.barId === owner.place.barId) : null;
        return b && (b.edge === "left" || b.edge === "right") ? "v" : "h";
    }
    // True while the shown payload is on the pill (a fullscreen window is up).
    readonly property bool inPill: owner._where === "pill"
    // Device px per design px for the OSD's pictures (the capture tile's decode): the ENGINE's, which is the shell's configured scale
    // (times the popup ratio) -- already device px per design px, so NOT times the screen's own ratio again (at
    // Hyprland 1.5 the attached Screen answers the integer 2: a decode a third too big).
    readonly property real renderScale: owner.engine && owner.engine.renderScale > 0 ? owner.engine.renderScale : 1

    property string _where: ""            // "" nothing | "bar" | "pill"
    property var _queue: []               // event requests waiting (FIFO)
    property string _hiddenKey: ""        // the card (kind:key) the user hid ("" none)
    // The shown card is hidden.
    readonly property bool hidden: owner._hiddenKey !== "" && owner.keyOf(owner._shown) === owner._hiddenKey
    property double _shownAt: 0           // when the shown payload first came out (min show)
    // The dismiss clock.
    property double _armedAt: 0
    property int _armedMs: 0
    property double _rest: 0              // what was left when the hover froze it
    property bool _closeAsked: false      // closeOsd() was called and the engine has not said closed yet
    property int swapFallbacks: 0         // promotions made by the key safety net instead of osdSwap (a probe reads it)

    readonly property var _noPayload: ({})
    property var _comps: ({})

    // The wall, in ms. A host that runs on another clock than the wall (a probe offscreen,
    // where timers follow the render loop) hands the one its Timers run on.
    property var clockMs: null
    function _now() {
        return owner.clockMs ? owner.clockMs() : Date.now();
    }
    // kind:key, the identity the engine tells "the same" by (OsdKinds.coalesceKey).
    function keyOf(req) {
        return req ? Kinds.coalesceKey(req) : "";
    }
    function componentFor(kind) {
        return owner._comps[String(kind)] || owner._comps["generic"] || null;
    }
    // A function, not a binding: the flip handlers run in the cascade of the very change that
    // makes it true, and a binding may not have caught up with it yet.
    function _pillWanted() {
        return ((owner.fullscreen && owner.fullscreenMode !== "suppress") || owner.barsHidden) && !!owner.pill;
    }
    // The fullscreen window under it holds this request back.
    function _suppressed(req) {
        return owner.fullscreen && (owner.fullscreenMode === "suppress" || (owner.fullscreenMode === "keys" && !Kinds.byUser(req)));
    }
    function _msOf(req) {
        return req && Number(req.ms) > 0 ? Number(req.ms) : owner.dismissMs;
    }

    // One Component per kind: the engine tells "another kind" from "the same" by identity.
    Instantiator {
        model: Kinds.kindIds()
        delegate: QtObject {
            id: holder
            required property string modelData
            Component.onCompleted: owner._comps[holder.modelData] = holder.comp
            readonly property Component comp: Component {
                OsdContent {
                    id: face
                    // A held hover is the owner's count; a content that is destroyed lets go of it.
                    property bool _holding: false
                    kind: holder.modelData
                    orientation: owner.orientation
                    payload: owner._shown && owner._shown.kind === holder.modelData ? owner._shown : owner._noPayload
                    style: owner.style
                    renderScale: owner.renderScale
                    touchpadNatural: !!owner.naturalScroll && owner.naturalScroll.touchpad === true
                    mouseNatural: !!owner.naturalScroll && owner.naturalScroll.mouse === true
                    interactive: true
                    onHoveredChanged: {
                        if (face.hovered === face._holding)
                            return;
                        face._holding = face.hovered;
                        owner._hoverMoved(face.hovered ? 1 : -1);
                    }
                    onTouched: owner._touched()
                    onHideRequested: owner.hideShown()
                    onActivated: owner._activated(holder.modelData)
                    onTrashRequested: owner._trashShot(holder.modelData)
                    onUserValue: v => {
                        if (owner.service)
                            owner.service.userValue(holder.modelData, v);
                    }
                    onUserToggleMute: {
                        if (owner.service)
                            owner.service.userToggleMute(holder.modelData);
                    }
                    onUserToggleBoost: {
                        if (owner.service)
                            owner.service.userToggleBoost(holder.modelData);
                    }
                    Component.onDestruction: {
                        if (face._holding)
                            owner._hoverMoved(-1);
                    }
                }
            }
        }
    }

    // ---- the service ----------------------------------------------------------------------
    Connections {
        target: owner.service
        ignoreUnknownSignals: true
        function onRequest(req) {
            owner.present(req);
        }
        function onDismissRequested() {
            owner.dismiss();
        }
        function onShotDeleted(path) {
            owner._shotGone(path);
        }
        function onWithdrawRequested(kind, key) {
            owner.withdraw(kind + ":" + key);
        }
    }
    Connections {
        target: owner.engine
        ignoreUnknownSignals: true
        function onOsdSwap(ownerId, key) {
            if (ownerId === owner.ownerId)
                owner._promote(false);
        }
        function onOsdPhaseChanged() {
            owner._engineSettled();
        }
        function onOsdKeyChanged() {
            // The engine switched to the pending request's key without a swap (it
            // opened fresh while closing): the pending one is what is out now.
            if (owner._pending && owner.engine.osdOwnerId === owner.ownerId
                    && owner.engine.osdKey === owner.keyOf(owner._pending)
                    && (owner.engine.osdPhase === "opening" || owner.engine.osdPhase === "open"))
                owner._promote(true);
        }
    }
    Connections {
        target: owner.pill
        ignoreUnknownSignals: true
        function onClosed() {
            if (owner._where === "pill" && !(owner.pill && owner.pill.showing))
                owner._leave();
        }
        function onHideRequested() {
            owner.hideShown();
        }
        function onRevealRequested() {
            owner.unhide();
        }
    }
    // The player opened: whatever the queue holds for it is dropped (it must not come out behind it).
    Connections {
        target: owner.service
        ignoreUnknownSignals: true
        function onPlayerOpenChanged() {
            owner._queue = owner._queue.filter(r => owner._allowed(r));
        }
        // the session locked: what waits for a now-playing card goes too (the lock shows what plays)
        function onLockedChanged() {
            owner._queue = owner._queue.filter(r => owner._allowed(r));
        }
    }
    onFullscreenChanged: owner._surfaceFlip()
    onFullscreenModeChanged: owner._surfaceFlip()
    onBarsHiddenChanged: owner._surfaceFlip()
    // The focus moved to another screen: whatever this one had out goes, and its queue with it.
    onActiveChanged: {
        if (!owner.active)
            owner.dismiss();
    }
    onPlaceChanged: {
        // The spot moved (config, a bar came or went) while something is out on a bar: ask the
        // engine again -- along the bar it glides, to another bar it hops.
        if (owner._where === "bar" && owner.place && owner._shown && !owner._pending)
            owner._askEngine(owner._shown);
    }

    // ---- requests -------------------------------------------------------------------------
    // One request, from the service (or a host that drives the owner by hand).
    // False for a request an open module holds back (OsdKinds.suppressedBy).
    function _allowed(req) {
        const s = owner.service;
        return !Kinds.suppressedBy(req, { playerOpen: !!s && s.playerOpen === true, locked: !!s && s.locked === true });
    }
    function present(req) {
        if (!owner.active || !req || req.kind === undefined)
            return;
        if (!owner._allowed(req))
            return;                                  // the player is open / the session is locked: dropped, not queued
        if (owner._suppressed(req))
            return;                                  // dropped, not queued
        const idle = !owner._shown && !owner._pending;
        if (idle) {
            owner._deliver(req);
            return;
        }
        const key = owner.keyOf(req);
        // The same thing again updates it where it is: the shown one (also while another waits for
        // the swap -- that cancels the swap) or the one waiting for it.
        if (key === owner.keyOf(owner._shown) || key === owner.keyOf(owner._pending)) {
            owner._deliver(req);
            return;
        }
        if (!owner.held && (Kinds.isUserKind(req.kind) || req.user === true)) {
            owner._deliver(req);
            return;
        }
        owner._enqueue(req);
        owner._pump();
    }
    function _enqueue(req) {
        owner._queue = Kinds.queuePush(owner._queue, req, owner.queueCap);
    }
    function _dequeue() {
        const r = Kinds.queueShift(owner._queue);
        owner._queue = r.rest;
        return r.head;
    }
    // Put `req` out now: fresh, in place, or as the dip's pending payload.
    function _deliver(req) {
        // A request that is not for the queue's head anymore must not come back later.
        const key = owner.keyOf(req);
        if (owner._queue.some(r => owner.keyOf(r) === key))
            owner._queue = owner._queue.filter(r => owner.keyOf(r) !== key);
        if (owner._pillWanted()) {
            owner._deliverPill(req);
            return;
        }
        if (!owner.place || owner.fullscreen)
            return;                                  // no bar for the spot: nothing to show it on
        const wasOut = owner._where === "bar" && !!owner._shown && owner.engine.osdPhase !== "closed";
        const inPlace = wasOut && owner.keyOf(owner._shown) === key;
        if (owner._where === "pill")
            owner._pillGone();
        owner._closeAsked = false;
        // THE PAYLOAD GOES OUT BEFORE THE ENGINE IS ASKED. The engine makes the content inside openOsd(), so a payload
        // handed over after the call finds the content already born -- empty, and sized by an empty
        // card -- and every kind's start-up runs from nothing: a level's ball glides in from 0 over 120 ms, a rail's
        // ball is sent to its stop, a content-fit card (the layout name, a screenshot) asks the engine for the
        // size of an empty one first. Set first, the content is made with what it shows -- and a dip's `pending` is
        // already there if the engine answers with an osdSwap inside the call.
        if (!wasOut || inPlace) {
            owner._setShown(req, !wasOut);
            owner._pending = null;
        } else {
            owner._pending = req;
        }
        owner._askEngine(req);
        owner._where = "bar";
        owner._arm(owner._msOf(req));
    }
    function _deliverPill(req) {
        if (owner._where === "bar")
            owner._closeBar();
        owner._pending = null;
        owner._closeAsked = false;
        owner.pill.present(req, owner._isHidden(req));
        owner._setShown(req, false);
        owner._where = "pill";
        owner._arm(owner._msOf(req));
    }
    function _askEngine(req) {
        const p = owner.place;
        owner.engine.openOsd(owner.ownerId, p.barId, p.local, null, null, owner.componentFor(req.kind),
                             { alongAt: p.alongAt, key: owner.keyOf(req), tucked: owner._isHidden(req) });
    }

    // ---- hidden (the header) ------------------------------------------------------------------
    function _isHidden(req) {
        return owner._hiddenKey !== "" && owner.keyOf(req) === owner._hiddenKey;
    }
    // The card on show goes out of the way and keeps running.
    function hideShown() {
        if (!owner._shown || owner._pending || owner._isHidden(owner._shown))
            return;
        owner._hiddenKey = owner.keyOf(owner._shown);
        owner._resurface();
    }
    // It comes back out (the pointer moved onto the sliver or the ball).
    function unhide() {
        if (owner._hiddenKey === "")
            return;
        owner._hiddenKey = "";
        owner._resurface();
    }
    // The surface the shown card is on hears the change: the engine is asked again (in place: a tuck), the pill told.
    function _resurface() {
        if (owner._where === "bar" && owner.place && owner._shown)
            owner._askEngine(owner._shown);
        else if (owner._where === "pill" && owner.pill && owner._shown)
            owner.pill.present(owner._shown, owner._isHidden(owner._shown));
    }
    // The pointer moved onto the tucked sliver (or the bar beside it): out again.
    HoverArm {
        id: tuckArm
        target: owner.engine && owner.engine.osdTuckZone ? owner.engine.osdTuckZone : null
        active: owner._where === "bar" && owner.hidden && !!owner.engine && owner.engine.osdTuckedRest === true
        // (a turn later: the reveal ends `active`, which `armed` reads -- written from its own change handler it is a binding loop)
        onArmedChanged: {
            if (tuckArm.armed)
                Qt.callLater(owner.unhide);
        }
    }
    // `shown` is req. The minimum show counts from a new appearance: fresh, or another key
    // than the one that was out; an in-place update does not restart it.
    function _setShown(req, fresh) {
        const was = owner._shown;
        owner._shown = req;
        if (fresh || !was || owner.keyOf(was) !== owner.keyOf(req))
            owner._shownAt = owner._now();
    }
    // The bottom of a dip: the waiting payload is what is shown now.
    function _promote(viaNet) {
        if (!owner._pending)
            return;
        const p = owner._pending;
        owner._pending = null;
        if (viaNet)
            owner.swapFallbacks++;
        owner._setShown(p, true);
        // The new content gets the whole of its time from here.
        owner._arm(owner._msOf(p));
        owner._pump();
    }
    // What the engine reports once it is closed again.
    function _engineSettled() {
        if (owner.engine.osdPhase === "closed" && owner._where === "bar" && owner._closeAsked) {
            owner._shown = null;
            owner._pending = null;
            owner._where = "";
            owner._closeAsked = false;
            owner._pump();
        }
    }

    // ---- the clock ------------------------------------------------------------------------
    function _arm(ms) {
        owner._expireHeld = false;
        owner._armedMs = ms;
        owner._armedAt = owner._now();
        owner._rest = ms;
        if (owner.hovered) {
            dismissTimer.stop();              // held: the full time is what is left when the pointer goes
            return;
        }
        dismissTimer.interval = Math.max(1, ms);
        dismissTimer.restart();
    }
    // The now-playing card was clicked: the host opens the player's popup (on this screen's bar).
    signal playerRequested()

    // A click on a card as a whole. A screenshot's edits or opens that shot (`captureClick`; the capture source's `edit` and `open`, what
    // the manager's buttons run too); a track's asks the host for the player (`playerRequested`). The OSD goes either way -- what was
    // opened is the next thing the user looks at.
    function _activated(kind) {
        if (kind === "track") {
            owner.dismiss();
            owner.playerRequested();
            return;
        }
        const cap = owner._shown && owner._shown.kind === kind && owner._shown.capture ? owner._shown.capture : null;
        const src = owner.service && owner.service.sources ? owner.service.sources.capture : null;
        if (kind !== "capture" || !cap || cap.what !== "shot" || !cap.path || !src || owner.captureClick === "none")
            return;
        if (owner.captureClick === "open")
            src.open(cap.path);
        else
            src.edit(cap.path);
        owner.dismiss();
    }
    // The trash icon on a screenshot's card: the capture source moves the shot to the Trash and the OSD goes at once -- the click is the confirmation,
    // as a click on the card as a whole closes it. The helper then tells the shell the shot is gone
    // (`deleted`, which is no card of its own). The editor is not opened.
    function _trashShot(kind) {
        const cap = owner._shown && owner._shown.kind === kind && owner._shown.capture ? owner._shown.capture : null;
        const src = owner.service && owner.service.sources ? owner.service.sources.capture : null;
        if (kind !== "capture" || !cap || cap.what !== "shot" || !cap.path || !src || typeof src.trash !== "function")
            return;
        src.trash(cap.path);
        owner.dismiss();
    }
    // A shot was deleted from somewhere else (its notification's trash button, swappy's): its card is not to stay up over a file
    // that is gone -- whether it is the one on show, the one waiting for the swap or one in the queue. Only ITS card goes: what
    // else waits in the queue comes out as it does when a card's time is up.
    function _shotGone(path) {
        const is = r => !!r && r.kind === "capture" && !!r.capture && r.capture.what === "shot" && r.capture.path === path;
        owner._queue = owner._queue.filter(r => !is(r));
        if (is(owner._shown) || is(owner._pending))
            owner._expire();
    }
    // A card that is over before its time (OsdService.withdraw: the dictation's caption at the end of its take), by kind:key. Out of
    // the queue; on show it expires (what waits comes out, else the OSD goes); waiting for the swap, the swap is cancelled and what
    // is on show rises again (the engine's undip); on show while ANOTHER waits for the swap, nothing: it is already on its way out.
    function withdraw(key) {
        owner._queue = owner._queue.filter(r => owner.keyOf(r) !== key);
        if (key === owner._hiddenKey)
            owner._hiddenKey = "";
        if (owner._pending && owner.keyOf(owner._pending) === key) {
            owner._pending = null;
            if (owner._shown && owner._where === "bar")
                owner._askEngine(owner._shown);
            else
                owner._expire();
        } else if (!owner._pending && owner._shown && owner.keyOf(owner._shown) === key) {
            owner._expire();
        }
    }
    function _touched() {
        if (owner._shown || owner._pending)
            owner._arm(owner._msOf(owner._pending || owner._shown));
    }
    function _hoverMoved(d) {
        const was = owner.hovered;
        owner._hoverCount = Math.max(0, owner._hoverCount + d);
        if (owner.hovered === was)
            return;
        if (owner.hovered) {
            if (dismissTimer.running) {
                owner._rest = Math.max(0, owner._armedMs - (owner._now() - owner._armedAt));
                dismissTimer.stop();
            }
        } else if (owner._shown || owner._pending) {
            // Left: what was left, but never less than a moment to reach for the control again.
            const ms = Math.max(owner._rest, owner.resumeMinMs);
            owner._armedMs = ms;
            owner._armedAt = owner._now();
            dismissTimer.interval = Math.max(1, ms);
            dismissTimer.restart();
            owner._pump();
        }
    }
    Timer {
        id: dismissTimer
        repeat: false
        onTriggered: owner._expire()
    }
    // Time left on the clock (ms), whether it runs or is held.
    function remainingMs() {
        if (dismissTimer.running)
            return Math.max(0, owner._armedMs - (owner._now() - owner._armedAt));
        return owner._shown || owner._pending ? owner._rest : 0;
    }

    property bool _expireHeld: false
    onHeldChanged: {
        if (owner.held)
            return;
        if (owner._expireHeld) {
            // its time ran out behind the line: what waits comes now, and a card with nothing after it is seen in the new palette for a moment, as after a pointer on it
            owner._expireHeld = false;
            if (owner._queue.length > 0)
                owner._expire();
            else
                owner._arm(owner.resumeMinMs);
        } else {
            owner._pump();
        }
    }
    function _expire() {
        if (owner.held) {
            owner._expireHeld = true;
            return;
        }
        if (owner._queue.length > 0) {
            owner._deliver(owner._dequeue());
            return;
        }
        owner.dismiss();
    }
    // Take what is out away (IPC dismiss, the end of the clock).
    function dismiss() {
        dismissTimer.stop();
        owner._queue = [];
        owner._hiddenKey = "";
        if (owner._where === "pill") {
            if (owner.pill)
                owner.pill.dismiss();
            owner._pillGone();
        } else if (owner._where === "bar") {
            owner._closeBar();
        }
    }
    // `shown` stays until the engine says closed: the content fades out showing what it showed.
    function _closeBar() {
        owner._closeAsked = true;
        owner._pending = null;
        owner.engine.closeOsd();
        if (owner.engine.osdPhase === "closed")
            owner._engineSettled();
    }
    function _leave() {
        owner._pillGone();
        owner._pump();
    }
    function _pillGone() {
        owner._shown = null;
        owner._pending = null;
        owner._where = "";
        dismissTimer.stop();
    }

    // ---- the queue -------------------------------------------------------------------------
    // The head of the queue goes out when the shown one is an event that has had its minimum, or
    // when nothing is out. Never from under a user kind or a held pointer.
    function _pump() {
        queueTimer.stop();
        if (owner._queue.length === 0)
            return;
        if (!owner._shown && !owner._pending) {
            owner._deliver(owner._dequeue());
            return;
        }
        if (owner._pending || owner.hovered || owner.held || Kinds.isUserKind(owner._shown.kind) || owner._shown.user === true)
            return;
        const left = owner.minShowMs - (owner._now() - owner._shownAt);
        if (left <= 0) {
            owner._deliver(owner._dequeue());
        } else {
            queueTimer.interval = Math.max(1, left);
            queueTimer.start();
        }
    }
    Timer {
        id: queueTimer
        repeat: false
        onTriggered: owner._pump()
    }

    // ---- fullscreen -------------------------------------------------------------------------
    // The window state changed under something that is out: it moves to the other surface and
    // keeps what was left of its time.
    function _surfaceFlip() {
        owner._queue = owner._queue.filter(r => !owner._suppressed(r));
        if (!owner._shown)
            return;
        const rest = owner.remainingMs();
        const req = owner._pending || owner._shown;
        const suppress = owner._suppressed(req);
        if (owner._where === "pill" && owner._pillWanted() && suppress) {
            owner.dismiss();
            return;
        }
        if (owner._where === "pill" && !owner._pillWanted()) {
            if (owner.pill)
                owner.pill.dismiss();
            owner._pillGone();
            if (!suppress)
                owner._deliverAfterFlip(req, rest);
        } else if (owner._where === "bar" && (owner._pillWanted() || suppress)) {
            owner._closeBar();
            if (!suppress) {
                owner._where = "";
                owner._deliverAfterFlip(req, rest);
            } else {
                dismissTimer.stop();
            }
        }
    }
    function _deliverAfterFlip(req, rest) {
        owner._deliver(req);
        if (rest > 0 && !owner.hovered)
            owner._arm(rest);
        else
            owner._rest = Math.max(0, rest);
    }
}
