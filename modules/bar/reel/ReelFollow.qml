pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// ReelFollow.qml -- keeps a reel on the item a service has IN FORCE (the idle reel on IdleService.mode), and says WHY when it was
// not the user who put it there.
//
//   target      the id in force
//   automatic   something other than the user put it there (IdleService.autoActive)
//   reason      why, in words (IdleService.autoReason: "Firefox is playing video"); "" for none
//   hold        the user's own turn is waiting to apply (ReelActions.idleWaiting): the reel is theirs until it has
//   floorReason the words of the cause that sets the FLOOR (IdleService.floorReason), also while it raised nothing (the user's mode is
//               above it). The reel REFUSES a plain turn under the floor (IconReel.refuse: the shake), and this tells why: the
//               module's `refusedStep` brings the reason out beside the open strip for `readMs` (the strip is under the pointer that
//               turned it), and it goes with the strip.
//
// A change the user made is already where the reel is: nothing happens. One that is not theirs turns the reel, and how depends on
// what made it:
//   AUTOMATIC (the auto layer took the mode, changed its cause, or let go of it): THE CINEMATIC -- the strip comes out by itself
//               (`openLeadMs` for it to grow), the ring travels the LONG way round to the item as one eased motion (`travelMs`), and
//               then, when the auto layer holds the mode and says why, THE REASON pops out beside the strip and holds a READING PAUSE
//               (`readMs`; it holds on while the pointer is on the words, and `readAfterMs` at least once the pointer has left them)
//               before the two fold back; with no reason to tell (the way back to the user's mode) the ring rests (`restMs`) and the
//               strip goes back in. The ring takes no input meanwhile (IconReel.traveling). A new cause at the same mode (another
//               holder took over) is told the same way, with no turn.
//   otherwise   (a mode refused, a hard lock that ended, an IPC hook) the short way, at the step's pace, the strip left alone.
//
// THE CINEMATIC NEVER INTERRUPTS (feedback window+tray "Tray should be reel like popup type": "I want one to never interupt the
// other"). The strip it brings out is the engine's REEL SLOT, which the other reel and the tray use too. While that slot is someone
// else's (`module.slotTaken()`: out, or on its way in) an automatic change WAITS (`phase` "wait"): the reel is not turned, not even
// in its cell, and the moment the slot is free -- or the pointer brings this reel's own strip out -- the cinematic plays, so the
// change is shown when the other one has finished (the tray closed: "the reel will open and display it changed"). The other way
// round the tray waits for the cinematic (WindowTrayOwner.reelBusy, this module's `autoOpen`).
//
// THE REASON (ReelReason, the engine's REEL CHILD: GooeyEngine.openChild on the strip): out beside the strip whenever the strip is
// out and the auto layer holds the mode -- after a cinematic's turn, and whenever the pointer brings the strip out -- level with the
// strip's last-but-one icon (the user: "on the level of the 3rd icon in the reel, so one above the last"), on the strip's end face
// (to the right of a strip hanging from a top bar). It goes with the strip (the engine folds it first, then the strip). While the
// ring turns it is not out: it comes when the turn has landed, so the cause and the mode it brought are read together.
//
// THE DECISION IS TAKEN A TURN LATER: the mode in force and the flag that says it is automatic are two bindings of one change, and
// a handler of either sees the other a generation behind (CLAUDE.md "ONE BINDING THAT READS TWO OTHERS"). `_lastAuto` remembers
// whether the reel stood on an automatic mode, so the way back is cinematic too.
// =============================================================================
QtObject {
    id: follow

    property var module: null
    property string target: ""
    property bool automatic: false
    property string reason: ""
    property bool hold: false
    property string floorReason: ""
    // idle.jsonc `autoTell`: false ("quiet") turns the cell by itself with no cinematic; the reason is told when the pointer brings the strip out
    property bool cinematic: true

    property int openLeadMs: 280
    property int travelMs: 1100
    property int restMs: 500
    property int readMs: 4000
    property int readAfterMs: 1500

    // "" at rest; "opening" / "travel" / "rest" / "read" while the cinematic plays; "wait" while it waits for the slot (the probes read it)
    readonly property string phase: follow._phase
    // How many cells the last turn took, signed (the probes read the long way from it), how many cinematics have played, and how
    // many times a cinematic told a cause.
    readonly property int lastSteps: follow._lastSteps
    readonly property int travels: follow._travels
    readonly property int tells: follow._tells

    // What the reason shows (the cause, the content's key), "" while there is nothing to tell.
    readonly property string reasonKey: follow.automatic && follow.reason !== "" ? follow.reason : ""
    // The reason's owner id in the engine, and whether it is out now (the engine's fact, not a flag of ours).
    readonly property string reasonId: follow.module ? follow.module.ownerId + "/reason" : ""
    readonly property var _engine: follow.module ? follow.module.engine : null
    readonly property bool reasonOut: !!follow._engine && !!follow._engine.theReelChild && follow._engine.theReelChild.live
        && follow._engine.theReelChild.ownerId === follow.reasonId

    property string _phase: ""
    property int _lastSteps: 0
    property int _travels: 0
    property int _tells: 0
    property bool _lastAuto: false
    // an automatic change is waiting for the reel slot (THE CINEMATIC NEVER INTERRUPTS): when it is decided again, it is still one
    property bool _waited: false
    property int _pendingIndex: -1
    // the cause a cinematic told last ("" once the auto layer lets go): a new one at the same mode is told again
    property string _toldKey: ""
    property bool _reasonHover: false
    // a refusal is being told (see floorReason): the reason out beside the strip though the auto layer raised nothing
    property bool _refusalOn: false
    property real _readEndsAt: 0

    onTargetChanged: Qt.callLater(follow._decide)
    onAutomaticChanged: Qt.callLater(follow._decide)
    onReasonChanged: Qt.callLater(follow._decide)
    onHoldChanged: Qt.callLater(follow._decide)
    onModuleChanged: Qt.callLater(follow._decide)
    onReasonKeyChanged: Qt.callLater(follow._syncReason)
    onFloorReasonChanged: Qt.callLater(follow._syncReason)
    on_RefusalOnChanged: Qt.callLater(follow._syncReason)

    function _indexOf(id: string): int {
        const it = follow.module && follow.module.reel ? follow.module.reel.items : null;
        if (!it)
            return -1;
        for (let i = 0; i < it.length; i++)
            if (it[i].id === id)
                return i;
        return -1;
    }

    function _decide(): void {
        if (!follow.module || follow.hold)
            return;
        const reel = follow.module.reel;
        const auto = follow.cinematic && (follow.automatic || follow._lastAuto || follow._waited);
        follow._lastAuto = follow.automatic;
        if (follow.reasonKey === "")
            follow._toldKey = "";
        const idx = follow._indexOf(follow.target);
        if (idx < 0 || idx === reel.selectedIndex) {
            // the same item, a cause not told yet (another holder took over at the same mode): told, with no turn -- once the slot is free
            if (follow.cinematic && follow.reasonKey !== "" && follow.reasonKey !== follow._toldKey && follow._phase !== "travel") {
                if (follow._waitForSlot())
                    return;
                follow._play(-1);
                return;
            }
            // nothing left to show: a wait for the slot is over, a cinematic that had not begun to turn stops
            follow._endWait();
            if (follow._phase === "opening" && follow._pendingIndex >= 0) {
                follow._openT.stop();
                follow._phase = "";
                follow.module.autoOpen = false;
            }
            return;
        }
        if (!auto) {
            follow._endWait();
            follow._lastSteps = reel.turnTo(idx, false, 0);
            return;
        }
        if (follow._waitForSlot())
            return;
        follow._travels += 1;
        follow._play(idx);
    }

    // THE CINEMATIC NEVER INTERRUPTS (header): the reel slot is someone else's, so the change waits (true). The slot's own changes
    // decide again (_engineWatch).
    function _waitForSlot(): bool {
        if (!follow.module.slotTaken()) {
            follow._endWait();
            return false;
        }
        // a cinematic still playing (the pointer took its strip to another reel) ends here: what it was showing is overtaken
        follow._openT.stop();
        follow._travelT.stop();
        follow._readT.stop();
        follow._restT.stop();
        follow.module.autoOpen = false;
        follow._waited = true;
        follow._phase = "wait";
        return true;
    }
    function _endWait(): void {
        follow._waited = false;
        if (follow._phase === "wait")
            follow._phase = "";
    }

    // THE CINEMATIC: the strip out by itself, the ring the long way to `idx` (-1: no turn, a cause alone), then the reason or the rest.
    function _play(idx: int): void {
        follow._waited = false;
        follow._pendingIndex = idx;
        const open = follow.module.canAutoOpen();
        follow.module.autoOpen = open;
        follow._restT.stop();
        follow._travelT.stop();
        follow._readT.stop();
        if (idx < 0 && !open) {
            // nowhere to show a cause now (another reel's strip is under the pointer): the strip that comes out next tells it
            follow._phase = "";
            follow._syncLater();
            return;
        }
        // a strip already out (the pointer on it, or the last cinematic still resting) needs no time to grow
        if (open && !follow.module.reelOpen) {
            follow._phase = "opening";
            follow._openT.restart();
        } else {
            follow._openT.stop();
            follow._next();
        }
        follow._syncLater();
    }

    function _next(): void {
        if (follow._pendingIndex >= 0)
            follow._travel();
        else
            follow._read();
    }

    function _travel(): void {
        follow._phase = "travel";
        follow._lastSteps = follow.module.reel.turnTo(follow._pendingIndex, true, follow.travelMs);
        follow._travelT.restart();
        follow._syncLater();
    }

    // The turn has landed: the reason out beside the strip for the reading pause -- when there is one to tell and a strip to tell
    // it beside (none came out by itself: the travel was in the bar's cell, and the next strip out tells it).
    function _read(): void {
        if (follow.reasonKey === "" || !follow.module.autoOpen) {
            follow._phase = "rest";
            follow._restT.restart();
            follow._syncLater();
            return;
        }
        follow._phase = "read";
        follow._toldKey = follow.reasonKey;
        follow._tells += 1;
        follow._readEndsAt = Date.now() + follow.readMs;
        follow._readT.interval = follow.readMs;
        if (follow._reasonHover)
            follow._readT.stop();
        else
            follow._readT.restart();
        follow._syncLater();
    }

    // The end of the cinematic: the strip goes back in unless something else holds it (the pointer), the reason with it.
    function _end(): void {
        follow._phase = "";
        if (follow.module)
            follow.module.autoOpen = false;
        follow._syncLater();
    }

    // The pointer is on the reason's words (ReelReason): the reading pause holds; when it leaves, what was left of the pause, and at
    // least `readAfterMs`. The strip stays under it as under a pointer on the strip (ReelBarModule.sideHovered).
    function reasonHovered(on: bool): void {
        follow._reasonHover = on;
        if (follow.module)
            follow.module.sideHovered = on;
        if (follow._phase !== "read")
            return;
        if (on) {
            follow._readT.stop();       // the pause holds under the pointer
        } else {
            follow._readT.interval = Math.max(follow.readAfterMs, Math.round(follow._readEndsAt - Date.now()));
            follow._readT.restart();
        }
    }

    // ---- the reason in the engine: out while the strip is out and the auto layer holds the mode (not while the ring turns) ----------
    function _syncLater(): void {
        Qt.callLater(follow._syncReason);
    }
    function _syncReason(): void {
        const m = follow.module;
        const e = follow._engine;
        if (!m || !e || !e.theReelChild)
            return;
        const C = e.theReelChild;
        const mine = C.live && C.ownerId === follow.reasonId;
        const key = follow.reasonKey !== "" ? follow.reasonKey : (follow._refusalOn ? follow.floorReason : "");
        const want = key !== "" && m.reelOpen && (follow._phase === "read" || follow._phase === "");
        if (!want) {
            if (mine)
                e.closeChild(follow.reasonId);
            return;
        }
        // out of a strip the pointer brought out once that strip stands (one growth after the other); at once in the cinematic's read
        if (!mine && follow._phase !== "read" && e.reelPhase !== "open")
            return;
        if (mine && C.key === key)
            return;
        e.openChild(m.ownerId, follow.reasonId, "end", m.sideAnchor(m.reel.count - 2), null, null, follow._reasonComp, { key: key });
    }
    property Connections _moduleWatch: Connections {
        target: follow.module
        function onReelOpenChanged(): void {
            if (follow.module && !follow.module.reelOpen)
                follow._refusalOn = false;
            follow._syncLater();
        }
        function onRefusedStep(): void {
            if (follow.floorReason === "")
                return;
            follow._refusalOn = true;
            follow._refusalT.interval = follow.readMs;
            follow._refusalT.restart();
        }
    }
    property Connections _engineWatch: Connections {
        target: follow._engine
        function onReelPhaseChanged(): void {
            follow._syncLater();
            follow._slotMoved();
        }
        function onReelOwnerIdChanged(): void {
            follow._slotMoved();
        }
    }
    // The reel slot changed hands or phase: a change waiting for it decides again (a turn later: the phase and the owner are two
    // properties of one change).
    function _slotMoved(): void {
        if (follow._phase === "wait")
            Qt.callLater(follow._decide);
    }

    property Component _reasonComp: Component {
        ReelReason {
            owner: follow
            style: follow.module ? follow.module.style : null
        }
    }

    property Timer _openT: Timer {
        interval: follow.openLeadMs
        onTriggered: follow._next()
    }
    property Timer _travelT: Timer {
        interval: follow.travelMs
        onTriggered: follow._read()
    }
    property Timer _refusalT: Timer {
        onTriggered: follow._refusalOn = false
    }
    property Timer _restT: Timer {
        interval: follow.restMs
        onTriggered: follow._end()
    }
    // (stopped while the pointer is on the words: reasonHovered; its leave restarts it)
    property Timer _readT: Timer {
        onTriggered: follow._end()
    }
}
