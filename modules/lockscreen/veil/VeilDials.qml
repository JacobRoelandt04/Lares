pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"

// =============================================================================
// VeilDials.qml -- DIAL RINGS, a lock veil.
//
// Concentric rings of the shell's material round the popup, like a vault dial or a watch's
// chapter rings: carved grooves between them, fine ticks engraved in each (a major tick every
// fifth, one longer mark at the ring's zero), every ring turning at its own slow rate and its own
// way.
//
//   keys    every ring clicks one tick round, the outer rings a moment after the inner: a wave of
//           clicks, each a little detent (an ease with overshoot); sixteen at once
//   fail    the rings shudder out of step with one another, tinted by the error token
//   ok      every ring turns, by the shortest way, to the alignment angle and the marks line up; then the cutter
//           comes back: the dial is un-cut from the outermost ring in, each ring turning away a quarter turn as the
//           desktop comes back behind it, while the whole dial is pulled into the popup's place (the entrance run backwards)
//   wake    one soft click, as a key
//   presence  a cutter groove travels out from the popup; behind it each ring is cut in -- its ticks
//           engrave over the next ring's width and it turns from a quarter turn away into place;
//           the desktop is untouched ahead of it (the same over the bare ground at boot)
//   the shell  only where the lock says it is: the rings centre on the popup's rect, `hubMargin` clear of its
//           corners. Before the shell has said where it is (a boot lock before the shell has started, a regular lock
//           before its popup opens) no popup is guessed: the rings centre on the point the popup will come out of --
//           the foot of the bar once the shell names its bar, else the top centre of the screen (the lock popup hangs
//           from the top bar's middle) -- round a hub of `hubMargin` alone: the dial as an unlock leaves it, the popup
//           retracted into its bar. THE ARRIVAL: when what the dial centres on changes (nothing, the bar, the popup;
//           either way), centre and hub ease from what is drawn to the shell's live place over `arriveSeconds`
//           (OutCubic), following the popup as it opens: the rings open out round it. THE RE-CUT then gives each ring
//           the tick count of its new size (below).
//
// A pure function of `host` except for one thing it remembers: how many clicks the rings have
// taken (a ring's angle is the sum of every key since the lock). The host keeps 32 pulses, so the
// count is kept here from the pulses it has seen (`_log`); a clear of the host's pulses clears it.
// The shader (shaders/veil_dials.frag) is one pass: no loop over rings, no texture, no per-tick
// re-grab; a resting host renders nothing.
// =============================================================================
Item {
    id: root

    // `var`, not LockVeil: the lock loads a veil by URL (see VeilDimples).
    property var host: null

    // ---- where the shell is: the lock's rects, and only those (see "the shell" above) ----
    property real hubMargin: 36
    // The dial's place from the shell's rects: what it centres on (2 the popup, 1 the bar's foot, 0 the top centre), its
    // centre, its hub, and where the entrance's cutter starts (inside the popup's outline). One function for the drawing
    // and for the handler that records a change, so the two work out the same numbers. (A popup rect of no height is
    // still the popup: the unlock's retract ends in one, LockSurface `_goneRect`.)
    function _placeOf(pr, br, w, h) {
        let s, kind;
        if (pr.width > 0) {
            s = pr;
            kind = 2;
        } else if (br.width > 0 && br.height > 0) {
            s = Qt.rect(br.x + br.width / 2, br.y + br.height, 0, 0);
            kind = 1;
        } else {
            s = Qt.rect(w / 2, 0, 0, 0);
            kind = 0;
        }
        return {
            kind: kind,
            cx: s.x + s.width / 2,
            cy: s.y + s.height / 2,
            hub: Math.hypot(s.width / 2, s.height / 2) + root.hubMargin * (h / 1620),
            fs: Math.min(s.width, s.height) / 2 * 1.0
        };
    }
    readonly property rect _noRect: Qt.rect(0, 0, 0, 0)
    // the place the rects say now
    readonly property var _live: root._placeOf(root.host ? root.host.popupRect : root._noRect, root.host ? root.host.barRect : root._noRect, root.width, root.height)

    // ---- THE ARRIVAL (see "the shell" above) ----
    // Veil seconds the dial takes to ease to its new place when the shell's rects change what it centres on.
    property real arriveSeconds: 1.2
    // { at, cx, cy, hub, fs }: the dial as it was drawn when what it centres on last changed (the ease starts there);
    // null while that never happened, and a shell there from the veil's first moments is followed as it is.
    property var _arr: null
    // the place drawn at veil time t while the rects say `live`
    function _drawnAt(t, live) {
        const a = root._arr;
        if (!a || t < a.at)
            return live;
        const x = Math.max(0, Math.min(1, (t - a.at) / Math.max(0.05, root.arriveSeconds)));
        if (x >= 1)
            return live;
        const e = 1 - Math.pow(1 - x, 3);
        return {
            kind: live.kind,
            cx: a.cx + (live.cx - a.cx) * e,
            cy: a.cy + (live.cy - a.cy) * e,
            hub: a.hub + (live.hub - a.hub) * e,
            fs: a.fs + (live.fs - a.fs) * e
        };
    }

    // ---- THE RE-CUT ----
    // A ring's tick count is worked out from its size (veil_dials.frag, THE TICK COUNT); a count that changed in place
    // would re-tick the whole ring in one frame (every ring, many times over, while the hub grows round an opening popup).
    // So a ring keeps its count while the hub moves and takes the count of its new size only when a re-cut passes it: a
    // front that leaves the hub once the hub has held still for `_settle` and travels out at `recutSpeed`. A ring whose
    // count changes has its ticks smoothed away as the front comes and engraved again as it goes on (over `cutIn` either
    // side): the count changes while the ring shows none. Two re-cuts can be out at once (the newest behind the one
    // before); a third change while both are out gives the rings the older one has not reached its count at once.
    //   { h0, h1, f1at, f2at }: rings neither re-cut has reached are counted from hub h0, those only the earlier one has
    //   passed from h1, those the newest has passed from the live hub (the ok's once the password is accepted); f1at and
    //   f2at are the veil times the two left (-1e9: long ago, every ring passed).
    property real recutSpeed: 1400       // px per veil second at 1620 high
    readonly property real _settle: 0.25
    readonly property var _cutRest: ({ h0: 0, h1: 0, f1at: -1e9, f2at: -1e9 })
    property var _cut: root._cutRest
    // how far a re-cut that left at `at` has come by t, px from the hub: -1e6 not left yet, 1e6 every ring passed (it
    // starts a fade's width inside the hub, so the innermost ring's engraving is whole when it leaves)
    function _travel(at, t, end) {
        if (t < at)
            return -1e6;
        const s = root.recutSpeed * root._unit * (t - at) - root.cutIn * root._unit;
        return s >= end ? 1e6 : s;
    }
    // what a change of the live hub (from `wasHub`) at t does to the re-cuts
    function _recutOn(t, wasHub) {
        const c = root._cut;
        // the newest has not left yet: it waits for the hub to hold still again
        if (t < c.f2at)
            return { h0: c.h0, h1: c.h1, f1at: c.f1at, f2at: t + root._settle };
        // it has passed every ring: they all have the hub it cut them to
        if (root._travel(c.f2at, t, root._recutEnd) >= 1e6)
            return { h0: wasHub, h1: wasHub, f1at: -1e9, f2at: t + root._settle };
        // it is out: it carries on with the hub it had, and a new one follows once the hub holds still
        return { h0: c.h1, h1: wasHub, f1at: c.f2at, f2at: t + root._settle };
    }

    // ---- the record of the shell's place (the handler: it reads the facts themselves, never a binding on them) ----
    property var _seen: null
    property real _lastT: 0
    function _onPlace() {
        if (!root.host)
            return;
        const t = root.host.time;
        const now = root._placeOf(root.host.popupRect, root.host.barRect, root.width, root.height);
        const was = root._seen;
        root._seen = now;
        // The lock hands the rects over a turn after the veil is built: a shell there in the first moments, before any
        // change, was there from the start.
        if (!was || (root._arr === null && t < 0.3))
            return;
        if (now.kind !== was.kind) {
            const d = root._drawnAt(t, was);
            root._arr = { at: t, cx: d.cx, cy: d.cy, hub: d.hub, fs: d.fs };
        }
        // (while an unlock pulls the dial in, every ring keeps its count: the ok's)
        if (now.hub !== was.hub && !root._latch)
            root._cut = root._recutOn(t, was.hub);
    }
    onWidthChanged: root._onPlace()
    onHeightChanged: root._onPlace()
    onHubMarginChanged: root._onPlace()

    // ---- the rings ----
    property real ringPitch: 92
    property real grooveWidth: 14
    property real grooveDepth: 4.5
    property real ringTone: 0.07
    property real spinRate: 0.011
    property real spinSpread: 0.8
    property real alignAngle: 90         // degrees, y down: 90 is straight down

    // ---- the ticks ----
    property real tickPitch: 17
    property real tickWidth: 1.25
    property real tickDepth: 3
    property real minorLength: 0.22
    property real majorLength: 0.42
    property int majorEvery: 5
    property real markLength: 0.9

    // ---- details (each can be switched off) ----
    property real brushed: 1             // brushed-metal ring faces: fine lines round the dial and an anisotropic sheen; 0 = off
    property bool numerals: true         // engraved numerals under the major ticks of every third ring

    // ---- lighting ----
    property real grooveHi: 1.4
    property real darkHighlight: 1.8
    property real grooveLo: 1.8
    property real cavity: 0.55
    property real sandAlpha: 0.72
    property real sandAlphaDark: 0.7

    // ---- the entrance ----
    property real groundFeather: 24
    property real cutIn: 130
    property real entranceSpin: 1.1

    // ---- pulses ----
    property real notch: 1               // ticks a click turns a ring
    property real clickDelay: 0.035      // seconds between one ring's click and the next one out
    property real clickSeconds: 0.22
    property real shudder: 0.05          // rad
    property real shudderHz: 7
    property real shudderSeconds: 0.45
    property real failSeconds: 1.8
    property real okSeconds: 1.1
    // The unlock's zoom: the popup retracts into the bar in ~0.2 s and then is a rect of no height,
    // and the rings are sized and centred from it. From the ok, centre and hub ease from what they
    // were AT the ok to what the popup says now, over this long on a smooth in-out, so the dial
    // visibly pulls in through the lock's 0.6 s hold and 0.4 s fade (an instant follow reads as
    // the dial zooming out quickly).
    property real zoomSeconds: 1.2

    // ---- colours (the shell's tokens) ----
    property color sandColor: Theme.surface
    property color highlightColor: Theme.buttonBevel
    property color shadowColor: Theme.shadowDeep
    property color floorColor: Theme.border
    property color errorColor: Theme.errorTint

    // ---- what the host says ----
    readonly property real _t: root.host ? root.host.time : 0
    readonly property real _presence: root.host ? root.host.presence : 1
    // the entrance's front moves at constant speed: the host's riseClock is linear in real time (presence is eased)
    readonly property real _rise: root.host && root.host.riseClock !== undefined ? root.host.riseClock : root._presence
    readonly property bool _opaque: root.host ? root.host.opaque : false
    readonly property bool _dark: root.host ? root.host.dark : false
    readonly property real _unit: root.height / 1620
    readonly property int _slots: 16
    readonly property real _rad: Math.PI / 180
    // where the rings are centred and how big the hub is: the shell's place (THE ARRIVAL), eased from the ok's
    readonly property var _placed: root._drawnAt(root._t, root._live)
    readonly property vector2d _placeCentre: Qt.vector2d(root._placed.cx, root._placed.cy)
    readonly property real _placeHub: root._placed.hub
    // 1 = follow the popup, 0 = still where the ok found it
    readonly property real _follow: {
        const l = root._latch;
        if (!l)
            return 1;
        const x = Math.max(0, Math.min(1, (root._t - l.t) / Math.max(0.05, root.zoomSeconds)));
        return x * x * (3 - 2 * x);
    }
    readonly property vector2d _centre: root._latch ? Qt.vector2d(root._latch.cx + (root._placeCentre.x - root._latch.cx) * root._follow,
                                                                  root._latch.cy + (root._placeCentre.y - root._latch.cy) * root._follow)
                                                    : root._placeCentre
    readonly property real _hub: root._latch ? root._latch.hub + (root._placeHub - root._latch.hub) * root._follow : root._placeHub
    // the hub the tick counts of the rings the newest re-cut has passed come from (all of them at rest): the popup's own,
    // the ok's once the password is accepted, so the zoom of an unlock never re-ticks a ring (veil_dials.frag, THE TICK
    // COUNT)
    readonly property real _tickHub: root._latch ? root._latch.tick : root._live.hub
    // px from the hub past which no ring is on screen, and a re-cut's fade beyond; the re-cuts for the shader
    readonly property real _recutEnd: root._frontMax - root._hub + (root.ringPitch + root.cutIn) * root._unit
    readonly property vector4d _recut: Qt.vector4d(root._cut.h0, root._cut.h1, root._travel(root._cut.f1at, root._t, root._recutEnd),
                                                   root._travel(root._cut.f2at, root._t, root._recutEnd))
    readonly property real _frontMax: Math.hypot(Math.max(root._centre.x, root.width - root._centre.x), Math.max(root._centre.y, root.height - root._centre.y))
                                      + (root.groundFeather + root.cutIn * 1.7 + 40) * root._unit
    // THE CLEAR: the cutter that cut the rings in comes back along the same road, from beyond the farthest ring to
    // the popup: a ring is un-cut (its ticks leave the next ring's width, it turns a quarter turn away) as the
    // cutter passes it, outermost first, the desktop untouched beyond. It waits `clearDelay` of the clear for the rings
    // to line up (the ok) and is done at 0.95 of it.
    property real clearDelay: 0.2
    readonly property real _clearBack: { const c = root.host ? root.host.clear : 0; return Math.max(0, Math.min(1, (c - root.clearDelay) / (0.95 - root.clearDelay))); }
    function _smooth(a, b, x) {
        const t = Math.max(0, Math.min(1, (x - a) / (b - a)));
        return t * t * (3 - 2 * t);
    }
    // the shader tells "the cutter is in the way" from `presence` < 1
    readonly property real _shaderPresence: root._clearBack > 0 ? Math.min(root._presence, 0.9) : root._presence
    // the cutter starts just inside the popup's own outline (hidden behind it) so it is on screen and moving from the rise's first frame
    readonly property real _frontStart: root._placed.fs

    // ---- the geometry at the ok ----
    // { t, cx, cy, hub, tick } of the newest ok the host holds, taken when it ARRIVED: the popup is still
    // at rest then (the lock's hints follow the retract a moment later), and a veil that follows the
    // popup would otherwise follow it all the way in. Null with no ok.
    property var _latch: null
    function _latchOk() {
        const ps = root.host ? root.host.pulses : [];
        let okT = -1;
        for (const p of ps)
            if (p.kind === "ok" && p.t > okT)
                okT = p.t;
        if (okT < 0) {
            if (root._latch)
                root._latch = null;
            return;
        }
        if (root._latch && root._latch.t === okT)
            return;
        root._latch = { t: okT, cx: root._placeCentre.x, cy: root._placeCentre.y, hub: root._placeHub, tick: root._live.hub };
    }

    // ---- the clicks the rings have taken ----
    // Times of every key and wake the host has sent since its pulses were last empty.
    property var _log: []
    function _sync() {
        const ps = root.host ? root.host.pulses : [];
        if (ps.length === 0) {
            if (root._log.length > 0)
                root._log = [];
            return;
        }
        const have = {};
        for (const l of root._log)
            have[l] = true;
        const add = [];
        for (const p of ps)
            if ((p.kind === "key" || p.kind === "wake") && !have[p.t])
                add.push(p.t);
        if (add.length === 0)
            return;
        root._log = root._log.concat(add).sort((a, b) => a - b).slice(-600);
    }
    Connections {
        target: root.host
        function onPulsesChanged() { root._sync(); root._latchOk(); }
        function onPopupRectChanged() { root._onPlace(); }
        function onBarRectChanged() { root._onPlace(); }
        // a seek backwards (renders and probes; the lock's clock only runs forward): what the dial remembers lies ahead
        // of the clock, so it starts over with the shell where it is now
        function onTimeChanged() {
            const t = root.host.time;
            if (t < root._lastT - 1e-9) {
                root._arr = null;
                root._cut = root._cutRest;
                root._seen = root._placeOf(root.host.popupRect, root.host.barRect, root.width, root.height);
            }
            root._lastT = t;
        }
    }
    // a host is a lock: the dial starts with the shell where that one says it is
    function _restart() {
        root._arr = null;
        root._cut = root._cutRest;
        root._seen = null;
        root._onPlace();
        root._lastT = root.host ? root.host.time : 0;
    }
    onHostChanged: root._restart()
    Component.onCompleted: {
        root._sync();
        root._latchOk();
        root._restart();
    }

    // what the pulses ask of the rings now: how many clicks are done, which are still turning, the
    // fail's age, the ok's progress and time
    readonly property var _fx: root._compute(root._t, root.host ? root.host.pulses : [], root._log)
    function _compute(t, pulses, log) {
        const live = root.clickDelay * 40 + root.clickSeconds;
        let total = 0;
        const recent = [];
        for (let i = log.length - 1; i >= 0; i--) {
            const age = t - log[i];
            if (age < 0)
                continue;
            total++;
            if (age < live && recent.length < root._slots)
                recent.push(Qt.vector4d(age, 1, 0, 0));
        }
        let failAge = -1, okE = 0, okT = 0;
        let seenFail = false, seenOk = false;
        for (let i = (pulses ? pulses.length : 0) - 1; i >= 0; i--) {
            const p = pulses[i];
            const age = t - p.t;
            if (age < 0)
                continue;
            if (p.kind === "fail" && !seenFail && age < root.failSeconds) {
                seenFail = true;
                failAge = age;
            } else if (p.kind === "ok" && !seenOk) {
                seenOk = true;
                const x = Math.min(1, age / Math.max(0.1, root.okSeconds));
                okE = 1 - (1 - x) * (1 - x);          // fast out of the gate (it reads inside the unlock's hold), still moving through the fade
                okT = p.t;
            }
        }
        return { total: total, settled: total - recent.length, recent: recent, failAge: failAge, okE: okE, okT: okT };
    }
    // The clicks the slots read: a fresh array every tick while one turns; none, the same empty one, so the sixteen slots'
    // bindings do not run again (a fresh object runs them all).
    readonly property var _recent: root._fx.recent.length > 0 ? root._fx.recent : root._noRecent
    readonly property var _noRecent: []
    function _c(i) {
        const r = root._recent;
        return i < r.length ? r[i] : Qt.vector4d(0, 0, 0, 0);
    }

    ShaderEffect {
        id: fx
        anchors.fill: parent
        visible: root._opaque || root._presence > 0.001
        blending: true
        fragmentShader: "../shaders/veil_dials.frag.qsb"

        property vector2d size: Qt.vector2d(root.width, root.height)
        property vector4d geom: Qt.vector4d(root._centre.x, root._centre.y, root._unit, root._hub)
        property vector4d ringG: Qt.vector4d(root.ringPitch, root.grooveWidth, root.grooveDepth, root.tickPitch)
        property vector4d tickG: Qt.vector4d(root.tickWidth, root.tickDepth, root.minorLength, root.majorLength)
        property vector4d spin: Qt.vector4d(root.spinRate, root.spinSpread, root.majorEvery, root.markLength)
        property vector4d click: Qt.vector4d(root.notch, root.clickDelay, root.clickSeconds, root._fx.settled)
        property vector4d align: Qt.vector4d(root.alignAngle * root._rad, root._fx.okE, root._fx.okT, root._fx.total)
        property vector4d shake: Qt.vector4d(root._fx.failAge, root.shudder, root.shudderSeconds, root.shudderHz)
        property vector4d front: Qt.vector4d(root._frontStart + Math.min(root._rise, 1 - root._clearBack) * (root._frontMax - root._frontStart), root.groundFeather, root.cutIn, root.entranceSpin)
        property vector4d lightK: Qt.vector4d(root.grooveHi, root.grooveLo, root.cavity, root._dark ? root.darkHighlight : 1)
        property vector4d tone: Qt.vector4d(root.ringTone, root._tickHub, 1 - root._smooth(0.7, 1, root._clearBack), 0)
        property vector4d detail: Qt.vector4d(root.brushed, root.numerals ? 1 : 0, 0, 0)
        property vector4d recut: root._recut
        property real presence: root._shaderPresence
        property real opaqueMode: root._opaque ? 1 : 0
        property real tm: root._t
        property real sandAlpha: root._dark ? root.sandAlphaDark : root.sandAlpha
        property real clickCount: root._recent.length
        property color cSand: root.sandColor
        property color cHi: root.highlightColor
        property color cLo: root.shadowColor
        property color cFloor: root.floorColor
        property color cErr: root.errorColor
        property vector4d clk0: root._c(0)
        property vector4d clk1: root._c(1)
        property vector4d clk2: root._c(2)
        property vector4d clk3: root._c(3)
        property vector4d clk4: root._c(4)
        property vector4d clk5: root._c(5)
        property vector4d clk6: root._c(6)
        property vector4d clk7: root._c(7)
        property vector4d clk8: root._c(8)
        property vector4d clk9: root._c(9)
        property vector4d clk10: root._c(10)
        property vector4d clk11: root._c(11)
        property vector4d clk12: root._c(12)
        property vector4d clk13: root._c(13)
        property vector4d clk14: root._c(14)
        property vector4d clk15: root._c(15)
    }
}
