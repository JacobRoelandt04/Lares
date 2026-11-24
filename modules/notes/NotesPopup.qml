pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window

import "../common/theme"
import "../common/components"
import "../common/components/Mix.js" as Mix
import "../common/components/LevelMorph.js" as LM
import "../common/components/EditKeys.js" as EK
import "../common/float"
import "browse"
import "editor"

// =============================================================================
// NotesPopup.qml -- the notes popup's content, a drop-in for thePopup.
//
// Holds nothing that must outlive it: the store (NotesStore, owned bar-side
// or by the mockup) has the view, the folder, the open documents and the
// sizes; this is built on every open and destroyed on close.
//
// HOST CONTRACT (GooeyEngine; all optional members, docs/notes.md):
//   implicitWidth/Height   the current view's size: the browse size, or the
//                          open note's own (per-note sizes)
//   alongShift             how far the popup sits off its icon along the bar
//                          (an edge drag keeps the opposite edge fixed)
//   liveResizeActive       an edge drag is live: follow the size exactly
//   hostRoom               assigned by the host: where the popup may go
//   surfaceTint            the open note's colour over the whole surface,
//                          eased in on one 260 ms fraction; transparent at rest
//   keyboardFocusRequest   "onDemand": the popup takes typing
//   cornerRadii            assigned by the owner: the popup's corners as the
//                          engine draws them on this frame ([tl, tr, br, bl],
//                          GooeyEngine.popupCornerRadii); the grid's fades are
//                          cut to them
//   dictationActive        an editable line of an open note has the caret (the editor view)
//   dictationPreedit(t)    t underlined at the caret, replacing the previous one; "" clears; false: no place to show it
//   dictationCommit(t)     t inserted at the caret for good; false: nothing took it
//   dictationBefore()      the text before the caret on its line (the spacing)
//   closeRequested()       Escape pressed in the popup's own keys (the shell's bind goes through handleEscape())
//   motionRunning          the owner's word that the popup is on screen: the
//                          tiles' float runs only then, and only while the
//                          grid shows (THE FLOAT, NotesGrid)
//   floatStyle             the float's numbers (NotesFloatStyle)
//
// Content paints no background; the host's surface is the ground.
// =============================================================================
Item {
    id: popup

    property var store: null
    property string fontFamily: "Inter"
    // The writing face, separate from the chrome's: a mockup dressed in
    // Audiowide still writes in Inter.
    property string editorFontFamily: "Inter"
    property real editorBodySize: 12
    property real editorTitleSize: 22
    property var gridOptions: ({
            pad: 12,
            gap: 12,
            minTile: 150,
            maxTile: 210,
            aspect: 0.7,
            hysteresis: 6
        })
    property real minWidth: 300
    property real minHeight: 280
    // Escape in an open note goes back to the tiles (handleEscape).
    property bool escapeBack: false
    property bool confirmDelete: true
    property string linkClick: "ctrl"
    property bool motionRunning: true
    property FloatStyle floatStyle: NotesFloatStyle {}

    // ---- The float: ONE clock for every tile of both grids ---------------------------------
    // Every frame while a deal, a lean or the calm moves; 20 a second for the
    // sway alone (2.7 px/s at most: 0.14 px a tick, and every tick is a frame
    // of the whole window: measured offscreen, 5.5 % of a core at 30 Hz, 3 % at
    // 20). It stops while the editor covers the grid, and it stands still
    // under a theme crossfade.
    readonly property alias floatClock: cardClock
    FloatClock {
        id: cardClock
        running: popup.motionRunning && browseLayer.visible
        restHz: 20
        calm: grid.floatCalm
        style: popup.floatStyle
    }
    // Where the tile a morph leaves (or lands on) is drawn: the card carries
    // that pose and lets go of it as it grows (1 - grow), so it leaves from
    // the tile the user clicked -- lifted, leaning, swayed -- and not from its
    // cell. Live: a back lands on the pose the tile has then.
    readonly property var _morphPose: {
        const m = popup._m;
        return m ? (m.layer === "group" ? grid2 : grid).poseOf(m.key) : null;
    }

    // ---- Host contract -----------------------------------------------------------------------
    readonly property string sizeKey: popup.store ? popup.store.sizeKeyFor(popup.store.view) : ""
    readonly property var restSize: popup.store && popup.store.service.serial >= 0 && popup.store.docSerial >= 0 ? popup.store.sizeFor(popup.sizeKey) : ({
            w: 560,
            h: 440,
            shift: 0
        })
    property var liveSize: null
    // During a morph the popup drives its own size, on the morph's clock,
    // lerped by its EDGES and rounded (LevelMorph.lerpSize): a box on half
    // pixels makes everything in it shimmer.
    readonly property var size: popup._m ? LM.lerpSize(popup._m.fromSize, popup._m.toSize, popup.me, popup._edge === "left" || popup._edge === "right") : (popup.liveSize || popup._restNow)
    // A morph runs between boxes as the host RESTS them (_boxNow, _restOf):
    // it may land on a shift the host's wall put in, not the one asked for.
    // Handing the asked shift over when it lands would make the host place
    // the box again -- where it already is, or, caught in the wrong order
    // against the live flag dropping, a jump there and an ease back. So the
    // landed size stays the popup's size for as long as it stands for this
    // view's asked size in this room.
    property var _landed: null
    readonly property var _restNow: {
        const l = popup._landed, s = popup.restSize;
        if (l && popup._roomKey === l.room && l.asked.w === s.w && l.asked.h === s.h && (l.asked.shift || 0) === (s.shift || 0))
            return l.size;
        return s;
    }
    readonly property string _roomKey: {
        const r = popup.hostRoom;
        return r ? [r.edge, r.center, r.lo, r.hi, r.wallLo, r.wallHi, r.snap].join(" ") : "";
    }
    implicitWidth: popup.size.w
    implicitHeight: popup.size.h
    property real alongShift: popup.size.shift || 0
    readonly property bool liveResizeActive: resizer.active || popup.morphing
    property var hostRoom: null
    property var cornerRadii: [0, 0, 0, 0]
    // How far above the popup's foot the grid's page stops: a raised tile's
    // shadow reach, so a row scrolled past the foot never shadows the corners.
    readonly property real _footGap: 6
    readonly property string _edge: popup.hostRoom && popup.hostRoom.edge ? popup.hostRoom.edge : "top"
    // The popup's outline in `item`'s coordinates, for the fades. The corners
    // that hang from the bar are not free (the engine's list carries the
    // fillet there, and the bar continues past them): 0.
    function outlineIn(item) {
        const r = popup.cornerRadii || [0, 0, 0, 0];
        const e = popup._edge;
        const p = item ? item.mapToItem(popup, 0, 0) : Qt.point(0, 0);
        return {
            x: -p.x,
            y: -p.y,
            w: popup.width,
            h: popup.height,
            radii: [e === "top" || e === "left" ? 0 : r[0], e === "top" || e === "right" ? 0 : r[1], e === "bottom" || e === "right" ? 0 : r[2], e === "bottom" || e === "left" ? 0 : r[3]]
        };
    }
    // How much of a note's card is left at `grow`: all of it until 60 %, none at 1 (a smoothstep), so the card hands the page over
    // to the surface the field draws (see noteCard).
    function cardKeep(grow) {
        const t = LM.clamp01((grow - 0.6) / 0.4);
        return 1 - t * t * (3 - 2 * t);
    }
    // How far the engine pours the note's colour across the popup's join with the bar, in this popup's units (GooeyEngine.tintBlend:
    // the ramp is this deep on each side of the join). The editor's fades must fade into the surface AS THE FIELD DRAWS IT there.
    property real tintReach: 20
    // The fades' ground near the join: the untinted surface mixed into the tint over `tintReach`, on the sides that hang from a
    // bar (a square corner pair, as outlineIn gives them). null while the note has no colour: the ground is then one colour.
    function surfaceRampIn(item) {
        if (popup.tintF <= 0.001)
            return null;
        const r = popup.outlineIn(item).radii;
        return {
            base: Theme.surface,
            reach: popup.tintReach,
            sides: [r[0] === 0 && r[3] === 0 ? 1 : 0, r[0] === 0 && r[1] === 0 ? 1 : 0, r[1] === 0 && r[2] === 0 ? 1 : 0, r[2] === 0 && r[3] === 0 ? 1 : 0]
        };
    }
    // Typing needs the layer surface to have the keyboard. OnDemand gives it on
    // a click; to type straight after opening (a search, the open note) and
    // when the pointer comes back to the popup -- as windows behave under
    // Hyprland's follow_mouse -- the request is Exclusive for a moment, then
    // OnDemand again, so a click elsewhere still takes the keyboard away.
    // UNVERIFIED on the layer surface (the mockup is a toplevel window).
    // `grabKeyboard: false` turns
    // it off.
    property bool grabKeyboard: true
    property bool _focusPulse: false
    readonly property string keyboardFocusRequest: popup._focusPulse ? "exclusive" : "onDemand"
    function pulseKeyboard() {
        if (!popup.grabKeyboard || popup.Window.active)
            return;
        popup._focusPulse = true;
        focusPulse.restart();
    }
    Timer {
        id: focusPulse
        interval: 120
        onTriggered: popup._focusPulse = false
    }
    HoverHandler {
        onHoveredChanged: {
            if (hovered)
                popup.pulseKeyboard();
        }
    }
    property color surfaceTint: popup.tintF > 0.001 ? Mix.c(Theme.surface, popup._tintColor, popup.tintF) : "transparent"
    signal closeRequested
    // "Send to LLM" (the right-click menu of a note): the file's real path, for the host to hand to the chat.
    // The row is offered only where the host can (`llmEnabled`).
    signal sendToLlm(string path)
    property bool llmEnabled: false

    // ---- The note's colour over the surface ------------------------------------------------
    readonly property string tintKey: {
        if (!popup.store || popup.store.view !== "editor" || popup.store.newNote)
            return "";
        const e = popup.store.service.serial >= 0 ? popup.store.entryOf(popup.store.noteKey) : null;
        return e ? (e.colorKey || "") : "";
    }
    property string _lastTint: ""
    readonly property color _tintColor: popup.tintOf(popup._lastTint)
    // At rest the tint eases on its own (a colour picked while editing);
    // while a note opens or closes it is a fraction of the morph clock.
    property real _tintRest: popup.tintKey ? 1 : 0
    onTintKeyChanged: {
        if (popup.tintKey)
            popup._lastTint = popup.tintKey;
        tintAnim.stop();
        if (popup._m)
            popup._tintRest = popup.tintKey ? 1 : 0;
        else {
            tintAnim.to = popup.tintKey ? 1 : 0;
            tintAnim.restart();
        }
    }
    NumberAnimation {
        id: tintAnim
        target: popup
        property: "_tintRest"
        duration: 260
        easing.type: Easing.OutCubic
    }
    readonly property real tintF: popup._m && popup._m.layer === "note" ? LM.lerp(popup._m.fromTint, popup._m.toTint, popup.me) : popup._tintRest
    readonly property color ground: popup.tintF > 0.001 ? Mix.c(Theme.surface, popup._tintColor, popup.tintF) : Theme.surface

    function tintOf(key) {
        if (!key)
            return Theme.surface;
        const k = "note" + key.charAt(0).toUpperCase() + key.substring(1);
        return Theme[k] !== undefined ? Theme[k] : Theme.surface;
    }

    // ---- The morph: opening a tile, and going back ---------------------------------------------
    // A phone opens an app by growing its icon into the screen; notes and
    // groups open the same way, and back undoes it.
    // ONE clock (MorphClock: `mt` linear, `me` its OutCubic) drives everything a
    // transition moves: the popup's own size (the content drives it -- the
    // engine follows exactly, liveResizeActive), the card growing from the
    // tile to the popup (MorphCard), the page left behind receding (fading,
    // zooming 6 % towards the tile), the page arrived at fading in inside the
    // card, the tint, the chevron and the title's room for it. Going back is
    // the same clock the other way round, landing on the tile's LIVE rect, and
    // a two-finger swipe scrubs it. Every layer is laid out once at its own
    // resting size and held still on the screen while the popup's edges move
    // over it (`_layerAt`), so nothing reflows and nothing slides.
    //
    //   _m = { dir: "open" | "back", layer: "note" | "group", face: "note" |
    //          "group" | "new", key, facts, minis, fromRect, focus, fromSize,
    //          toSize, browseSize, editorSize, parentFolder, fromTint, toTint,
    //          fromBack, toBack, scrub, reversed, cancelled }
    //
    // An open changes the store at its start (the page arrived at needs it);
    // a back changes it at its END, so a swipe that is let go can undo it.
    property int morphMs: 320
    property var _m: null
    readonly property bool morphing: popup._m !== null
    readonly property real me: clock.me
    // The running morph, one object per kind (null otherwise). A binding
    // reads ONE of these and nothing else about the morph: a flag and `_m`
    // read side by side can come from two generations -- `_noteMorph` still
    // true while `_m` is already null -- and throw as a morph clears (the
    // user saw "Value is null" on the note card's tileW).
    readonly property var _nm: popup._m && popup._m.layer === "note" ? popup._m : null
    readonly property var _gm: popup._m && popup._m.layer === "group" ? popup._m : null
    readonly property bool _noteMorph: popup._nm !== null
    readonly property bool _groupMorph: popup._gm !== null
    MorphClock {
        id: clock
        morphMs: popup.morphMs
        onLanded: popup._morphLanded()
    }
    // Where a layer laid out at size `s` sits in the popup on this frame so
    // that it stays still on the screen: the popup grows about its icon
    // (plus its shift) along the bar and away from the bar's face.
    function _layerAt(s, shown) {
        if (!popup._m || !s) {
            // At rest the page on show takes the popup's OWN size -- what it
            // asked the host for, not the box the host is easing towards it:
            // opening, the box grows from the bar and a page that followed it
            // re-laid itself out on the way (the grid went from two columns
            // to three and its third card flew up a row). In a live drag the
            // two are the same. The hidden page keeps its own resting size, so
            // it does not re-lay itself out at the other page's (the grid came
            // back from a note scrolled, in the note's two columns).
            if (shown || !s)
                return {
                    x: 0,
                    y: 0,
                    w: popup.size.w,
                    h: popup.size.h
                };
            return {
                x: 0,
                y: 0,
                w: s.w,
                h: s.h
            };
        }
        const c = popup.size;
        const e = popup._edge;
        if (e === "top" || e === "bottom")
            return {
                x: ((s.shift || 0) - s.w / 2) - ((c.shift || 0) - c.w / 2),
                y: e === "bottom" ? c.h - s.h : 0,
                w: s.w,
                h: s.h
            };
        return {
            x: e === "right" ? c.w - s.w : 0,
            y: ((s.shift || 0) - s.h / 2) - ((c.shift || 0) - c.h / 2),
            w: s.w,
            h: s.h
        };
    }
    // The size as the host has the box NOW. The host may rest a box off the
    // shift it was asked for -- GooeyEngine's WALL moves a box that would
    // stop just short of a side bar flush against it -- and a morph lerped
    // from the ASKED shift would drop that move on its first frame: the box
    // would jump by it. So a morph runs from the box as it
    // is (hostRoom's a0/a1, where a drag starts from too) to where the host
    // will rest the target (_restOf). Both need a room that says where the
    // host rests a box (_rests); in any other the morph runs between the
    // asked sizes, and the host keeps its own placement. The room
    // says where THIS size sits only when its span is this size's; otherwise
    // (the host easing, a drag under way) the size is the truth.
    function _boxNow() {
        const s = popup.size;
        const r = popup.hostRoom;
        if (!popup._rests(r) || !isFinite(r.a0) || !isFinite(r.a1))
            return s;
        const along = popup._edge === "left" || popup._edge === "right" ? s.h : s.w;
        const shift = (r.a0 + r.a1) / 2 - r.center;
        if (Math.abs((r.a1 - r.a0) - along) > 0.5 || Math.abs(shift - (s.shift || 0)) < 1e-6)
            return s;
        return {
            w: s.w,
            h: s.h,
            shift: shift
        };
    }
    // Where the host will REST a size, as the size whose shift puts the box
    // there: the host's own answer (hostRoom.restAt -- its clamp, its wall,
    // its bar's end; GooeyEngine places every box by the same function, so
    // nothing here mirrors its rules). A morph lands on it, so the host has
    // nothing left to move when the morph ends.
    function _restOf(s) {
        const r = popup.hostRoom;
        if (!s || !popup._rests(r))
            return s;
        const p = r.restAt(popup._edge === "left" || popup._edge === "right" ? s.h : s.w, s.shift || 0);
        const shift = p ? (p.a0 + p.a1) / 2 - r.center : NaN;
        if (!isFinite(shift) || Math.abs(shift - (s.shift || 0)) < 1e-6)
            return s;
        return {
            w: s.w,
            h: s.h,
            shift: shift
        };
    }
    // A room that says where the host rests a box: GooeyEngine's hostRoom
    // (`restAt`, a function; `center`, what a shift is counted from).
    function _rests(r) {
        return !!r && typeof r.restAt === "function" && isFinite(r.center);
    }
    readonly property var browseAt: popup._layerAt(popup._m ? popup._m.browseSize : (popup.store ? popup.store.sizeFor("") : null), !popup.store || popup.store.view === "browse")
    readonly property var editorAt: popup._layerAt(popup._m ? popup._m.editorSize : null, true)

    // The page left behind (receding, zooming towards the tile) and the page
    // arrived at; the tile's face out, then the page in (never both at
    // once), the page scaled with the card so it is whole from its first
    // frame. One read of the clock for all four (LevelMorph.fractions).
    readonly property var _fr: LM.fractions(popup._m ? popup._m.dir : "", popup.me)
    readonly property real _recede: popup._fr.recede
    readonly property real _zoom: popup._fr.zoom
    readonly property real _arrive: popup._fr.arrive
    readonly property real _faceF: popup._fr.faceF
    // Without a morph (a restore, a drop, a wikilink) the view that arrives
    // fades in; nothing else moves.
    property real arriveF: 1
    NumberAnimation {
        id: arrive
        target: popup
        property: "arriveF"
        from: 0
        to: 1
        duration: 160
        easing.type: Easing.OutCubic
    }

    // The tile's rect on this frame, in `space`'s coordinates: the captured
    // one for an open, the grid's live cell for a back (through the zoom of
    // the page it sits in). No tile: the card shrinks to the page's centre.
    function _tileRect() {
        const m = popup._m;
        const g = m.layer === "group" ? grid2 : grid;
        let r = m.dir === "open" ? m.fromRect : g.rectOf(m.key);
        if (!r)
            r = {
                x: body.width / 2,
                y: body.height / 2,
                w: 0,
                h: 0
            };
        r = LM.zoomRect(r, m.focus, popup._zoom);
        if (m.layer === "group")
            return r;
        return {
            x: r.x + popup.browseAt.x,
            y: r.y + popup.browseAt.y + body.y,
            w: r.w,
            h: r.h
        };
    }
    // The card: popup coordinates for a note, the body's for a group.
    readonly property var cardRect: {
        if (!popup._m)
            return null;
        const full = popup._m.layer === "group" ? {
            x: 0,
            y: 0,
            w: body.width,
            h: body.height
        } : {
            x: 0,
            y: 0,
            w: popup.size.w,
            h: popup.size.h
        };
        const r = LM.cardRect(popup._tileRect(), full, popup._m.dir, popup.me);
        // Everything a reader needs, in the one object: the page's scale in
        // the card (`s`), the zoom of the page behind and its origin.
        r.layer = popup._m.layer;
        r.zoom = popup._zoom;
        r.focus = popup._m.focus;
        return r;
    }
    // Each card reads the rect alone (one read, one generation), null when
    // the morph is not its own.
    readonly property var _groupCardRect: popup.cardRect && popup.cardRect.layer === "group" ? popup.cardRect : null
    readonly property var _noteCardRect: popup.cardRect && popup.cardRect.layer === "note" ? popup.cardRect : null

    function _tileColor(e, key) {
        if (key === "+" || !e)
            return Theme.listBox;
        if (e.isGroup)
            return e.colorKey ? popup.tintOf(e.colorKey) : Theme.listBox;
        return e.colorKey ? popup.tintOf(e.colorKey) : Theme.buttonPlateau;
    }

    // A tile was clicked: grow it into the popup.
    function openItem(key) {
        if (popup._m)
            popup._finishNow();
        const st = popup.store;
        const e = key === "+" ? null : st.entryOf(key);
        if (key !== "+" && (!e || e.broken))
            return;
        const group = e !== null && e.isGroup;
        const r = grid.rectOf(key);
        const from = popup._boxNow();
        const m = {
            dir: "open",
            layer: group ? "group" : "note",
            face: key === "+" ? "new" : (group ? "group" : "note"),
            key: key,
            facts: e,
            minis: group ? grid.minisOf(key) : [],
            fromRect: r,
            focus: r ? {
                x: r.x + r.w / 2,
                y: r.y + r.h / 2
            } : {
                x: body.width / 2,
                y: body.height / 2
            },
            fromSize: from,
            toSize: from,
            parentFolder: st.folder,
            fromTint: popup.tintF,
            toTint: popup.tintF,
            fromBack: popup.backF,
            toBack: popup.backF,
            tileColor: popup._tileColor(e, key)
        };
        if (group) {
            grid2.searchKeys = st.searchKeys;
            grid2.folder = st.folder;
            grid2.flick.contentY = grid.flick.contentY;
            grid2.hiddenKey = key;
        } else {
            grid.hiddenKey = key;
        }
        m.browseSize = m.fromSize;
        m.editorSize = m.fromSize;
        popup._m = m;
        // The store changes now: the page arrived at is laid out from it.
        let ok = true;
        if (group)
            st.folder = key;
        else if (key === "+")
            st.startNewNote(st.folder);
        else
            ok = st.openNote(key);
        if (!ok) {
            grid.hiddenKey = "";
            popup._land(from);
            return;
        }
        const n = Object.assign({}, m);
        n.toSize = popup._restOf(popup.restSize);
        n.browseSize = group ? n.toSize : n.fromSize;
        n.editorSize = group ? null : n.toSize;
        n.toTint = popup._tintRest;
        n.toBack = group ? 1 : n.fromBack;
        clock.mt = 0;
        popup._m = n;
        clock.runTo(1);
        if (group)
            grid.forceActiveFocus();
        else
            pane.focusEditor();
    }

    // Back, as the user sees it: the editor to its grid, a group to its
    // parent (both shrink into their tile), a search cleared.
    function goBack() {
        if (popup._m) {
            if (popup._m.dir === "open" && !popup._m.reversed) {
                popup._reverse();
                return;
            }
            popup._finishNow();
        }
        const st = popup.store;
        if (st.view === "editor")
            popup._startBack("note", false);
        else if (st.query !== "")
            st.setQuery("");
        else if (st.folder !== "")
            popup._startBack("group", false);
    }
    readonly property bool canGoBack: !!popup.store && (popup.store.view === "editor" || popup.store.query !== "" || popup.store.folder !== "")

    function _startBack(layer, scrub) {
        const st = popup.store;
        const m = {
            dir: "back",
            layer: layer,
            fromSize: popup._boxNow(),
            toSize: popup._restOf(st.sizeFor("")),
            fromTint: popup.tintF,
            toTint: 0,
            fromBack: popup.backF,
            toBack: popup.backF,
            scrub: scrub
        };
        let e = null;
        if (layer === "note") {
            pane.remember();
            m.key = st.newNote ? "+" : st.noteKey;
            e = st.newNote ? null : st.entryOf(m.key);
            // The grid back() will show.
            if (e && st.query === "" && st.folder !== e.parentKey)
                st.folder = e.parentKey;
            grid.reveal(m.key);
            grid.hiddenKey = m.key;
            m.face = st.newNote ? "new" : "note";
            m.minis = [];
            m.browseSize = m.toSize;
            m.editorSize = m.fromSize;
        } else {
            m.key = st.folder;
            e = st.entryOf(m.key);
            m.parentFolder = e ? e.parentKey : "";
            grid2.searchKeys = null;
            grid2.folder = m.parentFolder;
            grid2.flick.contentY = 0;
            grid2.reveal(m.key);
            grid2.hiddenKey = m.key;
            m.face = "group";
            m.minis = grid2.minisOf(m.key);
            m.browseSize = m.toSize;
            m.editorSize = null;
            m.toBack = m.parentFolder !== "" || st.query !== "" ? 1 : 0;
        }
        m.facts = e;
        m.tileColor = popup._tileColor(e, m.key);
        const r = (layer === "note" ? grid : grid2).rectOf(m.key);
        m.focus = r ? {
            x: r.x + r.w / 2,
            y: r.y + r.h / 2
        } : {
            x: body.width / 2,
            y: body.height / 2
        };
        clock.mt = 0;
        popup._m = m;
        if (!scrub)
            clock.runTo(1);
    }

    // Harnesses: hold a running morph at clock `t` (a filmstrip, a probe),
    // and let it go on.
    function pinMorph(t) {
        clock.stop();
        clock.mt = t;
    }
    function releaseMorph() {
        if (popup._m)
            clock.runTo(popup._m.reversed || popup._m.cancelled ? 0 : 1);
    }

    // An open taken back half way: the same clock, run home.
    function _reverse() {
        const n = Object.assign({}, popup._m);
        n.reversed = true;
        popup._m = n;
        clock.runTo(0);
    }
    function _morphLanded() {
        const m = popup._m;
        if (!m)
            return;
        if (clock.mt >= 1 && m.dir === "back")
            popup._applyBack(m);
        else if (clock.mt <= 0 && m.dir === "open" && m.reversed)
            popup._undoOpen(m);
        if (clock.mt >= 1 || clock.mt <= 0)
            popup._clearMorph(clock.mt >= 1 ? m.toSize : m.fromSize);
    }
    // Jump a running morph to where it is going.
    function _finishNow() {
        const m = popup._m;
        if (!m)
            return;
        clock.stop();
        if (m.dir === "back" && !m.cancelled)
            popup._applyBack(m);
        else if (m.dir === "open" && m.reversed)
            popup._undoOpen(m);
        popup._clearMorph(m.reversed || m.cancelled ? m.fromSize : m.toSize);
    }
    function _applyBack(m) {
        if (m.cancelled)
            return;
        if (m.layer === "note") {
            popup.store.back();
        } else {
            const y = grid2.flick.contentY;
            popup.store.folder = m.parentFolder;
            grid.flick.contentY = y;
        }
    }
    function _undoOpen(m) {
        if (m.layer === "note")
            popup.store.back();
        else
            popup.store.folder = m.parentFolder;
    }
    // `end`: the size the morph ended on (the store already changed).
    function _clearMorph(end) {
        clock.stop();
        grid.hiddenKey = "";
        grid2.hiddenKey = "";
        popup._land(end);
        clock.mt = 0;
        grid2.folder = "\u0000";
        // The keyboard stays where it is: the caret was placed when the note
        // opened, and the user may have typed since.
        if (popup.store.view === "editor")
            pane.keepFocus();
        else if (!grid.activeFocus)
            grid.forceActiveFocus();
    }

    // The morph is over at `end`: that is the size now (_restNow), then no
    // morph.
    function _land(end) {
        popup._landed = end ? {
            asked: popup.restSize,
            size: end,
            room: popup._roomKey
        } : null;
        popup._m = null;
    }

    // ---- The title's room for the chevron ------------------------------------------------------
    // One fraction: the chevron's presence in the grid and the title's slide.
    // A group's morph carries it on its clock; anything else (a search begun
    // or cleared) eases it alone.
    readonly property bool browseCanBack: !!popup.store && (popup.store.folder !== "" || popup.store.query !== "")
    property real _backRest: popup.browseCanBack ? 1 : 0
    onBrowseCanBackChanged: {
        backAnim.stop();
        if (popup._m)
            popup._backRest = popup.browseCanBack ? 1 : 0;
        else {
            backAnim.to = popup.browseCanBack ? 1 : 0;
            backAnim.restart();
        }
    }
    NumberAnimation {
        id: backAnim
        target: popup
        property: "_backRest"
        duration: 260
        easing.type: Easing.OutCubic
    }
    readonly property real backF: popup._gm ? LM.lerp(popup._gm.fromBack, popup._gm.toBack, popup.me) : popup._backRest

    // ---- Views ---------------------------------------------------------------------------------------
    Connections {
        target: popup.store
        function onViewChanged() {
            if (!popup._m)
                arrive.restart();
        }
        function onNoteOpened(key) {
            if (popup.store.view === "editor" && !popup._m)
                Qt.callLater(() => pane.focusEditor());
        }
    }

    Component.onCompleted: {
        popup.pulseKeyboard();
        if (popup.store) {
            popup.store.hold();
            if (popup.store.service.ready)
                popup.store.restore();
        }
        if (popup.store && popup.store.view === "editor") {
            // Opened on a note: the grid is not dealt when it shows later (a back is a morph of its own).
            cardClock.skipDeal();
            Qt.callLater(() => pane.focusEditor());
        } else {
            grid.forceActiveFocus();
        }
    }
    Component.onDestruction: {
        if (popup.store) {
            if (popup._m)
                popup._finishNow();
            if (popup.store.view === "editor")
                pane.remember();
            popup.store.saveAll();
            popup.store.saveSession();
            popup.store.release();
        }
    }

    // ---- Layout --------------------------------------------------------------------------------------
    // The grid page: the header and the grid (and, while a group opens or
    // closes, its parent's grid under it).
    Item {
        id: browseLayer
        x: popup.browseAt.x
        y: popup.browseAt.y
        width: popup.browseAt.w
        height: popup.browseAt.h
        visible: (popup.store && popup.store.view === "browse") || popup._noteMorph
        opacity: popup._noteMorph ? popup._recede : popup.arriveF
        transform: Scale {
            origin.x: popup._nm ? popup._nm.focus.x : 0
            origin.y: popup._nm ? popup._nm.focus.y + body.y : 0
            xScale: popup._noteMorph ? popup._zoom : 1
            yScale: popup._noteMorph ? popup._zoom : 1
        }

        NotesHeader {
            id: header
            x: 0
            y: 12
            width: browseLayer.width
            height: implicitHeight
            store: popup.store
            fontFamily: popup.fontFamily
            overlayItem: overlay
            folderKey: popup._gm && popup._gm.dir === "back" ? popup._gm.parentFolder : (popup.store ? popup.store.folder : "")
            backF: popup.backF
            onBackClicked: popup.goBack()
            onRenameGroup: text => {
                if (popup.store.folder)
                    popup.store.service.renameEntry(popup.store.folder, text);
            }
        }

        Item {
            id: body
            x: 0
            y: header.y + header.height + 4
            width: browseLayer.width
            // The page stops a tile shadow's reach (6) above the popup's foot
            // and the grid pads its last row by the other 6, so at the end of
            // a scroll the last row sits 12 from the bottom edge, as the tiles
            // do from the sides (12 + 12 would be a couple of pixels too
            // deep). Not to the foot itself: a row scrolled over the corners
            // would lay its drop shadow outside the popup's curve there.
            height: Math.max(0, browseLayer.height - y - popup._footGap)
            // The parent grid zooms towards the well while a group opens;
            // kept to its own page, it does not slide up over the header.
            clip: popup._groupMorph

            // The parent level while a group opens (receding) or closes (the
            // page arrived at). Idle it lists a folder that cannot exist, so
            // it holds no tiles.
            NotesGrid {
                id: grid2
                objectName: "parentGrid"
                x: 0
                y: 0
                width: body.width
                height: body.height
                visible: popup._groupMorph
                enabled: false
                opacity: popup._recede
                transform: Scale {
                    origin.x: popup._gm ? popup._gm.focus.x : 0
                    origin.y: popup._gm ? popup._gm.focus.y : 0
                    xScale: popup._zoom
                    yScale: popup._zoom
                }
                service: popup.store ? popup.store.service : null
                folder: "\u0000"
                searchKeys: null
                overlayItem: overlay
                fontFamily: popup.fontFamily
                opt: popup.gridOptions
                footPad: 12 - popup._footGap
                ground: popup.ground
                outline: popup._m ? popup.outlineIn(body) : null
                floatClock: cardClock
                floatStyle: popup.floatStyle
            }

            FloatCard {
                id: groupCardPose
                readonly property var cr: popup._groupCardRect
                readonly property var p: popup._morphPose
                readonly property real hold: 1 - groupCard.grow
                visible: groupCardPose.cr !== null
                x: groupCardPose.cr ? groupCardPose.cr.x : 0
                y: groupCardPose.cr ? groupCardPose.cr.y : 0
                width: groupCardPose.cr ? groupCardPose.cr.w : 0
                height: groupCardPose.cr ? groupCardPose.cr.h : 0
                style: popup.floatStyle
                poseX: groupCardPose.p ? groupCardPose.p.x * groupCardPose.hold : 0
                poseY: groupCardPose.p ? groupCardPose.p.y * groupCardPose.hold : 0
                poseRot: groupCardPose.p ? groupCardPose.p.rot * groupCardPose.hold : 0
                poseTiltX: groupCardPose.p ? groupCardPose.p.tiltX * groupCardPose.hold : 0
                poseTiltY: groupCardPose.p ? groupCardPose.p.tiltY * groupCardPose.hold : 0
                poseLift: groupCardPose.p ? groupCardPose.p.lift * groupCardPose.hold : 0

                MorphCard {
                    id: groupCard
                    anchors.fill: parent
                    readonly property var m: popup._gm
                    raised: false
                    face: groupFace
                    facts: groupCard.m ? groupCard.m.facts : null
                    grow: groupCard.m ? (groupCard.m.dir === "open" ? popup.me : 1 - popup.me) : 0
                    faceF: popup._faceF
                    tileW: groupCard.m && groupCard.m.fromRect ? groupCard.m.fromRect.w : grid.geo.tileW
                    tileH: grid.geo.tileH
                    tileColor: groupCard.m ? groupCard.m.tileColor : Theme.listBox
                    groundColor: popup.ground
                    radii: [0, 0, 0, 0]
                }
            }

            // The current level, cut to the card while a group opens or
            // closes: the grid stays where it is laid out, the window over
            // it moves.
            Item {
                id: gridClip
                readonly property var r: popup._groupCardRect || ({
                        x: 0,
                        y: 0,
                        w: body.width,
                        h: body.height
                    })
                x: gridClip.r.x
                y: gridClip.r.y
                width: gridClip.r.w
                height: gridClip.r.h
                clip: popup._groupCardRect !== null
                opacity: popup._groupCardRect !== null ? popup._arrive : 1

                // Scaled with the card, as a phone scales an app's window:
                // the page is always whole inside it, never cut mid-word.
                NotesGrid {
                    id: grid
                    objectName: "notesGrid"
                    readonly property real s: popup._groupCardRect ? popup._groupCardRect.s : 1
                    x: 0
                    y: 0
                    width: body.width
                    height: body.height
                    transform: Scale {
                        xScale: grid.s
                        yScale: grid.s
                    }
                    service: popup.store ? popup.store.service : null
                    folder: popup.store ? popup.store.folder : ""
                    searchKeys: popup.store ? popup.store.searchKeys : null
                    overlayItem: overlay
                    fontFamily: popup.fontFamily
                    opt: popup.gridOptions
                    footPad: 12 - popup._footGap
                    ground: popup.ground
                    outline: popup.outlineIn(body)
                    floatClock: cardClock
                    floatStyle: popup.floatStyle
                    exitRect: popup.store && popup.store.folder !== "" ? ({
                            x: 0,
                            y: -(header.height + 4),
                            w: grid.width,
                            h: header.height
                        }) : null
                    onOpenNote: key => popup.openItem(key)
                    onOpenGroup: key => popup.openItem(key)
                    onCreateNote: popup.openItem("+")
                    onMenuRequested: (key, x, y) => popup.openTileMenu(key, x, y)
                    onRevealReal: key => popup.store.service.showInFileManager(key, true)
                    onExitRequested: {
                        const e = popup.store.entryOf(popup.store.folder);
                        popup.store.folder = e ? e.parentKey : "";
                        grid.continueDragInFolder();
                    }
                    // A leading space types nothing (the clipboard's and the picker's rule).
                    onTyped: text => {
                        if (!(text === " " && popup.store.query === ""))
                            popup.store.setQuery(popup.store.query + text);
                    }
                    onQueryKilled: action => popup.store.setQuery(EK.queryAfter(action, popup.store.query))
                    onBackspaced: popup.store.setQuery(popup.store.query.slice(0, -1))
                    onEscaped: popup._escaped()
                }
            }
        }
    }

    // A note's card, between the grid page and the editor.
    FloatCard {
        id: noteCardPose
        readonly property var cr: popup._noteCardRect
        readonly property var p: popup._morphPose
        readonly property real hold: 1 - noteCard.grow
        visible: noteCardPose.cr !== null
        x: noteCardPose.cr ? noteCardPose.cr.x : 0
        y: noteCardPose.cr ? noteCardPose.cr.y : 0
        width: noteCardPose.cr ? noteCardPose.cr.w : 0
        height: noteCardPose.cr ? noteCardPose.cr.h : 0
        style: popup.floatStyle
        poseX: noteCardPose.p ? noteCardPose.p.x * noteCardPose.hold : 0
        poseY: noteCardPose.p ? noteCardPose.p.y * noteCardPose.hold : 0
        poseRot: noteCardPose.p ? noteCardPose.p.rot * noteCardPose.hold : 0
        poseTiltX: noteCardPose.p ? noteCardPose.p.tiltX * noteCardPose.hold : 0
        poseTiltY: noteCardPose.p ? noteCardPose.p.tiltY * noteCardPose.hold : 0
        poseLift: noteCardPose.p ? noteCardPose.p.lift * noteCardPose.hold : 0

        MorphCard {
            id: noteCard
            anchors.fill: parent
            readonly property var m: popup._nm
            raised: !noteCard.m || noteCard.m.face === "note"
            face: noteCard.m && noteCard.m.face === "new" ? newFace : noteFace
            facts: noteCard.m ? noteCard.m.facts : null
            grow: noteCard.m ? (noteCard.m.dir === "open" ? popup.me : 1 - popup.me) : 0
            faceF: popup._faceF
            tileW: noteCard.m && noteCard.m.fromRect ? noteCard.m.fromRect.w : grid.geo.tileW
            tileH: grid.geo.tileH
            tileColor: noteCard.m ? noteCard.m.tileColor : Theme.buttonPlateau
            groundColor: popup.ground
            radii: popup.outlineIn(popup).radii
            // THE CARD LANDS AS THE SURFACE AS THE FIELD DRAWS IT. At grow 1 the card is "the page's own surface" -- one flat ground colour --
            // but over a coloured note the engine's surface is not flat near the join: it pours the tint across the bar's join (a ramp
            // `tintReach` deep, half tint at the face). The opaque card hid that ramp for the whole open and the last frame dropped it:
            // the harsh edge of colour that snapped into the fade when the animation completed. By the time
            // the old page is gone (60 % of the open) the card fades out over the surface instead, so the ramp is there as it lands.
            opacity: popup.cardKeep(noteCard.grow)
        }
    }

    // The tiles' faces on the cards: the real tiles, drawn bare.
    Component {
        id: noteFace
        NoteTile {
            bare: true
            bareGround: noteCard.fill
            entry: noteCard.facts
            now: grid.now
            fontFamily: popup.fontFamily
            hoverEnabled: false
        }
    }
    Component {
        id: newFace
        NewNoteTile {
            bare: true
        }
    }
    Component {
        id: groupFace
        GroupTile {
            bare: true
            entry: groupCard.facts
            minis: groupCard.m ? groupCard.m.minis : []
            fontFamily: popup.fontFamily
            hoverEnabled: false
        }
    }

    // The editor page, cut to the card while a note opens or closes.
    Item {
        id: editorClip
        readonly property var r: popup._noteCardRect || ({
                x: 0,
                y: 0,
                w: popup.width,
                h: popup.height
            })
        x: editorClip.r.x
        y: editorClip.r.y
        width: editorClip.r.w
        height: editorClip.r.h
        clip: popup._noteCardRect !== null
        visible: (popup.store && popup.store.view === "editor") || popup._noteMorph
        opacity: popup._noteMorph ? popup._arrive : popup.arriveF

        // Scaled with the card, like the grid of a group.
        Item {
            id: editorLayer
            readonly property real s: popup._noteCardRect ? popup._noteCardRect.s : 1
            x: popup.editorAt.x * editorLayer.s
            y: popup.editorAt.y * editorLayer.s
            width: popup.editorAt.w
            height: popup.editorAt.h
            transform: Scale {
                xScale: editorLayer.s
                yScale: editorLayer.s
            }

            NoteEditorPane {
                id: pane
                x: 0
                y: 12
                width: editorLayer.width
                height: Math.max(0, editorLayer.height - 24)
                store: popup.store
                overlayItem: overlay
                fontFamily: popup.editorFontFamily
                bodySize: popup.editorBodySize
                titleSize: popup.editorTitleSize
                ground: popup.ground
                outline: popup.outlineIn(pane)
                surfaceRamp: popup.surfaceRampIn(pane)
                titleLeftInset: 24
                titleRightInset: Math.round(28 * editorReset.presence)
                linkClick: popup.linkClick
                onEscapePressed: popup._escaped()
            }
            ChromeButton {
                id: editorBack
                x: 12
                y: 12 + pane.titleCentreY - 16
                onClicked: popup.goBack()
            }
            ChromeButton {
                id: editorReset
                chevron: false
                property real presence: popup.store && popup.store.view === "editor" && popup._resetWanted && !popup.morphing ? 1 : 0
                Behavior on presence {
                    NumberAnimation {
                        duration: 160
                        easing.type: Easing.OutCubic
                    }
                }
                visible: presence > 0.01
                opacity: presence
                x: editorLayer.width - 12 - width
                y: 12 + pane.titleCentreY - 16
                onClicked: popup.store.setSize(popup.sizeKey, null)
            }
        }
    }

    // ---- The chevron and the reset button ------------------------------------------------------------
    // Each page has its own: in the grid on the header row, in the editor on
    // the title's first line (no row of its own). They belong to
    // their page, so a morph zooms, scales and fades them with it.
    component ChromeButton: Item {
        id: cb
        property real hf: cbArea.containsMouse ? 1 : 0
        Behavior on hf {
            NumberAnimation {
                duration: 120
                easing.type: Easing.OutCubic
            }
        }
        property bool chevron: true
        signal clicked
        width: 16
        height: 32
        Chevron {
            visible: cb.chevron
            x: Math.round((parent.width - width) / 2)
            y: Math.round((parent.height - height) / 2)
            size: 12
            thickness: 2
            rotation: 90
            color: Mix.c(Theme.textMuted, Theme.accent, cb.hf)
        }
        Text {
            visible: !cb.chevron
            anchors.centerIn: parent
            text: "\uF066"
            font.family: "Symbols Nerd Font"
            font.pixelSize: 12
            color: Mix.c(Theme.textFaint, Theme.accent, cb.hf)
        }
        MouseArea {
            id: cbArea
            anchors.fill: parent
            anchors.margins: -4
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: cb.clicked()
        }
    }
    readonly property bool _resetWanted: popup.store ? !popup.store.isDefaultSize(popup.sizeKey, popup.restSize) : false

    // ---- Two fingers to the right: back ---------------------------------------------------------------
    // A browser's back gesture, read by SwipeScrub: a horizontal
    // motion scrubs the back morph -- the page slides home under the fingers,
    // never faster than the morph runs by itself -- and on the lift it
    // completes past a third, or on a fling, and springs back otherwise. A
    // mouse's tilt notch is one whole back; a search is cleared, not morphed.
    // Vertical motions are let through to the scrolling below.
    property real swipeBackUnits: 900
    property real swipeBackSign: 1
    readonly property bool swipeGestureActive: swipe.active
    readonly property real gestureHoldWidth: popup._m ? Math.max(popup._m.fromSize.w, popup._m.toSize.w) : popup.width
    readonly property real gestureHoldHeight: popup._m ? Math.max(popup._m.fromSize.h, popup._m.toSize.h) : popup.height
    function gestureWheel(ev) {
        return swipe.gestureWheel(ev);
    }
    // The fingers lifted from a scrub (commit or spring back); with no scrub
    // under them it was a notch: one whole back.
    function _swipeLifted(commit) {
        if (!swipe.active) {
            popup.goBack();
            return;
        }
        if (popup._m && popup._m.scrub) {
            const n = Object.assign({}, popup._m);
            n.scrub = false;
            if (!commit)
                n.cancelled = true;
            popup._m = n;
            clock.runTo(commit ? 1 : 0);
        } else if (!popup._m) {
            // The morph was finished under the fingers (an Escape): the chase stops.
            clock.stop();
        }
    }
    SwipeScrub {
        id: swipe
        anchors.fill: parent
        z: 880
        units: popup.swipeBackUnits
        sign: popup.swipeBackSign
        canBegin: popup.canGoBack
        // A back that was committed (lifted past the third, or a notch) is still playing out: the fingers that carry on, or the next
        // stray wheel, must not start a second one over it (`_finishNow` then `_startBack` would run twice, overlapping). A spring-back
        // (`cancelled`), a scrub under the fingers and an open are not blocked: those a swipe takes over.
        blocked: !!popup._m && popup._m.dir === "back" && !popup._m.scrub && !popup._m.cancelled
        stepOnly: !!popup.store && popup.store.view !== "editor" && popup.store.query !== ""
        onScrub: p => {
            if (!swipe.active) {
                if (popup._m)
                    popup._finishNow();
                popup._startBack(popup.store.view === "editor" ? "note" : "group", true);
            }
            clock.scrubTo(p);
        }
        onCommit: popup._swipeLifted(true)
        onCancel: popup._swipeLifted(false)
        onStep: popup.store.setQuery("")
    }

    // Escape only closes (the engine closes the popup unless this returns true): it goes back nowhere, so
    // the popup reopens on the note or folder it was left on. A typed search is the one thing it takes
    // with it: a filter nobody sees on reopening would read as missing notes. With `escapeBack` an open note goes back to
    // its grid, search and all, and Escape there closes; a note already on its way back closes too.
    function handleEscape() {
        if (popup.escapeBack && popup.store.view === "editor" && !(popup._m && popup._m.dir === "back")) {
            popup.goBack();
            return true;
        }
        if (popup.store.query !== "")
            popup.store.setQuery("");
        return false;
    }
    // Escape pressed in the popup's own keys.
    function _escaped() {
        if (!popup.handleEscape())
            popup.closeRequested();
    }

    // ---- Dictation -----------------------------------------------------------------------------------
    // An editable line of an open note has the caret (the editor view, never the grid, never mid-morph).
    readonly property bool dictationActive: !!popup.store && popup.store.view === "editor" && !popup.morphing && pane.editor.dictationActive
    // `text` underlined at the caret, replacing the previous preedit; "" takes it away.
    function dictationPreedit(text: string): bool {
        return pane.editor.dictationPreedit(text);
    }
    // `text` in at the caret for good (the preedit goes); false: nothing took it.
    function dictationCommit(text: string): bool {
        return pane.editor.dictationCommit(text);
    }
    // The text before the caret on its line (the spacing of the next piece).
    function dictationBefore(): string {
        return pane.editor.dictationBefore();
    }

    // ---- Menus -----------------------------------------------------------------------------------------------
    property string _menuKey: ""
    function openTileMenu(key, x, y) {
        const e = popup.store.entryOf(key);
        if (!e)
            return;
        popup._menuKey = key;
        const rows = [];
        rows.push({
            id: "rename",
            label: "Rename"
        });
        rows.push({
            id: "swatches"
        });
        rows.push({
            id: "reveal",
            label: "Show in file manager"
        });
        if (popup.llmEnabled && !e.isGroup && popup.store.service.filePathOf(key) !== "")
            rows.push({
                id: "sendllm",
                label: "Send to LLM"
            });
        rows.push({
            separator: true
        });
        if (e.isLink)
            rows.push({
                id: "unlink",
                label: "Remove from list",
                danger: true,
                confirm: "Remove?"
            });
        else
            rows.push({
                id: "delete",
                label: e.isGroup ? "Delete group" : "Delete",
                danger: true,
                confirm: !popup.confirmDelete ? "" : e.isGroup ? "Delete group?" : "Delete?"
            });
        tileMenu.rows = rows;
        tileMenu.currentSwatch = e.colorKey || "";
        tileMenu.openAt(x, y);
    }

    FloatingMenu {
        id: tileMenu
        overlayItem: overlay
        fontFamily: popup.fontFamily
        swatches: ["", "red", "orange", "yellow", "green", "teal", "blue", "purple", "pink"]
        swatchColor: key => popup.tintOf(key)
        onSwatchPicked: key => popup.store.service.setColor(popup._menuKey, key)
        onTriggered: id => {
            const key = popup._menuKey;
            const e = popup.store.entryOf(key);
            if (!e)
                return;
            switch (id) {
            case "rename":
                popup.openItem(key);
                if (!e.isGroup)
                    Qt.callLater(() => pane.editor.focusTitle(true));
                break;
            case "reveal":
                popup.store.service.showInFileManager(key);
                break;
            case "sendllm":
                {
                    // What is on screen reaches the disk first: the chat reads the file, not the editor.
                    popup.store.saveAll();
                    const path = popup.store.service.filePathOf(key);
                    if (path !== "")
                        popup.sendToLlm(path);
                }
                break;
            case "unlink":
                popup.store.service.unlinkEntry(key);
                break;
            case "delete":
                popup.store.service.trashEntry(key);
                break;
            }
        }
    }

    // ---- Resizing by the edges -------------------------------------------------------------------------------
    // Only a note is resized; the grid page has one size.
    PopupEdgeResize {
        id: resizer
        anchors.fill: parent
        z: 900
        enabled: !!popup.store && popup.store.view === "editor" && !popup.morphing
        hostRoom: popup.hostRoom
        curW: popup.width
        curH: popup.height
        curShift: popup.alongShift
        minW: popup.minWidth
        minH: popup.minHeight
        onResized: (w, h, shift) => popup.liveSize = {
                w: w,
                h: h,
                shift: shift
            }
        // Persisted on the release; the live size stays until the resizer is
        // done -- a snap onto a wall eases on after the release (it commits
        // the size it ends on first), and the rest size is that size then.
        onCommitted: (w, h, shift) => popup.store.setSize(popup.sizeKey, {
                w: w,
                h: h,
                shift: shift
            })
        onActiveChanged: {
            if (!resizer.active)
                popup.liveSize = null;
        }
    }

    // ---- Files dropped from anywhere ---------------------------------------------------------------------------
    DropArea {
        id: drop
        anchors.fill: parent
        z: 950
        keys: []
        onEntered: drag => {
            drag.accepted = drag.hasUrls;
        }
        onDropped: d => {
            if (!d.hasUrls)
                return;
            const paths = [];
            for (let i = 0; i < d.urls.length; i++) {
                const u = d.urls[i].toString();
                if (u.indexOf("file://") === 0)
                    paths.push(decodeURIComponent(u.substring(7)));
            }
            if (paths.length === 0) {
                dropOverlay.refuse();
                return;
            }
            d.accept();
            const images = paths.filter(p => /\.(png|jpe?g|gif|webp|bmp|svg)$/i.test(p));
            if (popup.store.view === "editor" && images.length === paths.length) {
                for (const p of images)
                    pane.insertImage(p);
                return;
            }
            if (popup._m)
                popup._finishNow();
            if (popup.store.view === "editor")
                pane.remember();
            popup.store.dropFiles(paths.filter(p => images.indexOf(p) < 0), () => dropOverlay.refuse());
        }
        property real f: drop.containsDrag ? 1 : 0
        Behavior on f {
            NumberAnimation {
                duration: 140
                easing.type: Easing.OutCubic
            }
        }
        FileDropOverlay {
            id: dropOverlay
            anchors.fill: parent
            anchors.margins: 12
            presence: drop.f
            surfaceColor: popup.ground
        }
    }

    // The layer everything floating lives in (menus, tips, the drag ghost).
    Item {
        id: overlay
        anchors.fill: parent
        z: 1000
    }
}
