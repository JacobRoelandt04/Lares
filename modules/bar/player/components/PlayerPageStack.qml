pragma ComponentBehavior: Bound

import QtQuick

import "../../../common/theme"
import "../../../common/components"
import "../../../common/components/LevelMorph.js" as LM
import "../../../common/scroll"

// =============================================================================
// PlayerPageStack.qml -- what opens inside a panel's carved box: an album's page, an artist's, a song's details. The library has one over its list and the queue one over
// its own: a tab keeps its own way back, as a phone's tabs do. It fills the box and lies on it.
//
// The stack is what back walks: [{ id, kind: "album"|"artist"|"song", a, b, info, loading, y, backLabel, tile, ret }], the bottom page first.
//
// A PAGE OPENS THE WAY A NOTE DOES (NotesPopup, LevelMorph.js, MorphCard). The row that was opened grows into the box on
// ONE clock (MorphClock), what it was opened from recedes (fading, zooming 6 % towards the row), the page fades in inside the card, scaled with it so it is whole from its
// first frame, and back is the same picture the other way, landing on the row's LIVE rect. A page opened from a page does the same over that page, so there are two page
// slots (only neighbours in the stack are ever on screen together), and a page keeps its scroll while it waits under another. A tile that is not on screen is the box's
// centre. Two fingers sideways scrub the back (SwipeScrub).
//
// THE PAGE IS FLUSH BECAUSE NOTHING IS BEHIND IT. The box's inset shadow is drawn under its children, so an opaque ground over the whole box flattens the carve, and a ground
// stood inside it would leave the list showing round the page. So there is no ground: the host's list is at opacity 0 (`listF`) for as long as a page is up and the page lies on the
// box itself. While the card moves it IS the ground, standing `_inset` inside the edge at the inner radius; by the time it gets there the list has receded.
//
// A PAGE OPENED FROM ANOTHER PANEL says so in `ret` (the queue's Show album, the player card's links, anything that jumps): { panel, tab, browseOpen, viewMode, label } is where
// it came from, and back goes there, which is not this stack's business: `returnTaken(ret)` asks the host to put it back. With a `panel` the morph crosses: the tile is
// that panel's row (a tile spec with a `get()`), that panel recedes instead of this one's list (`crossing`, `crossRecede`), and the chrome of the panel this stack is in
// comes in with the page (`crossArrive`). With none (the sidebar was shut) the sidebar's own close is the motion, and the host calls `dropTop()` when it has gone.
//
//   listTile(spec)   the host's: the tile of a row of its own list ({ where: "list", ... }): { item, w, h, color, radius, facts } or null
//   listLabel        what back says when it lands on the host's list
//   rowFace          a row's face on the card, for a tile with `facts` (`cardFacts` is what it reads); without facts the tile is taken as it stands
// =============================================================================
Item {
    id: stack

    objectName: "playerPageStack"

    property var player: null
    property var albums: []
    property var artists: []
    property string currentFile: ""
    property bool playing: false
    property var listTile: null
    property string listLabel: ""
    property Component rowFace: null
    property string fontFamily: "Inter"
    property real containerRadius: 14
    property real inset: 3
    property real scrollSpeed: 1.0
    property int morphMs: 320
    property real swipeBackUnits: 900
    property real swipeBackSign: 1

    property color listBoxColor: Theme.listBox
    property color headerBoxColor: Theme.headerBox
    property color surfaceColor: Theme.surface
    property color bevelColor: Theme.bevel
    property color borderColor: Theme.border
    property color textColor: Theme.textPrimary
    property color mutedColor: Theme.textMuted
    property color faintColor: Theme.textFaint
    property color accentColor: Theme.accent
    property color accentHoverColor: Theme.accentHover
    property color accentBevelColor: Theme.accentBevel
    property color textOnAccentColor: Theme.textOnAccent
    property color buttonPlateauColor: Theme.buttonPlateau
    property color buttonPlateauHoverColor: Theme.buttonPlateauHover
    property color buttonBevelColor: Theme.buttonBevel
    property color buttonShadowColor: Theme.buttonShadow

    signal albumAsked(string albumArtist, string album)
    signal songClicked(string uri)
    signal songMenuRequested(string uri, real sceneX, real sceneY)
    signal albumMenuRequested(string albumArtist, string album, real sceneX, real sceneY)
    // Play / Play next / Add to queue for the whole page.
    signal wholeRequested(string what, var entry, real sceneX, real sceneY)
    // A song page's own buttons: "next", "queue", "album", "artist".
    signal songAction(string action, var song)
    // Back is leaving this panel: put back what `ret` says.
    signal returnTaken(var ret)

    visible: stack.pageOpen

    property var _pageStack: []
    property int _pageSerial: 0
    readonly property bool pageOpen: stack._pageStack.length > 0
    // The page on show (its `info` and `loading` are written in place when the host answers).
    readonly property var pageEntry: stack.pageOpen ? stack._pageStack[stack._pageStack.length - 1] : null
    // The running morph: { dir: "open"|"back", under: entry|null (null: the list), tileItem, tileW, tileH, tileColor, tileRadius, focus, all, scrub, reversed, cancelled,
    // foreign, panel }. A binding reads this one object.
    property var _m: null
    readonly property var morph: stack._m
    // [slot 0's entry, slot 1's]; `_topSlot` holds the page on show.
    property var _slots: [null, null]
    property int _topSlot: 0
    MorphClock {
        id: pageClock
        morphMs: stack.morphMs
        onLanded: stack._pageLanded()
    }
    readonly property var _fr: LM.fractions(stack._m ? stack._m.dir : "", pageClock.me)
    readonly property real arrive: stack._fr.arrive

    // The host's list: receding under an open, returning under a back, away under a page at rest.
    readonly property bool listInMorph: stack._m !== null && stack._m.under === null && !stack._m.foreign
    readonly property real listF: stack.listInMorph ? stack._fr.recede : (stack.pageOpen ? 0 : 1)
    readonly property real listZoom: stack.listInMorph ? stack._fr.zoom : 1
    readonly property var focusPoint: stack._m ? stack._m.focus : ({ x: 0, y: 0 })

    // A morph that crosses to or from another panel: which one, how much of it is left, how much of this panel's chrome has come.
    readonly property string crossing: stack._m !== null && stack._m.foreign ? stack._m.panel : ""
    readonly property real crossRecede: stack._fr.recede
    readonly property real crossArrive: stack._fr.arrive
    readonly property real crossZoom: stack._fr.zoom
    function focusIn(item: Item): point {
        const f = stack.focusPoint;
        return stack.mapToItem(item, f.x, f.y);
    }

    function _setSlot(i, e) {
        const n = stack._slots.slice();
        n[i] = e;
        stack._slots = n;
    }
    function _pageIn(i) {
        const it = pageSlots.itemAt(i);
        return it ? it.page : null;
    }
    readonly property var shownPage: {
        void stack._slots;
        return stack._pageIn(stack._topSlot);
    }
    function _labelUnder(st) {
        const n = st.length;
        if (n > 0) {
            const e = st[n - 1];
            return e.kind === "artist" ? e.a : e.kind === "song" ? "Song details" : e.b;
        }
        return stack.listLabel;
    }
    function _shelfAlbum(aa, al) {
        const all = stack.albums || [];
        for (let i = 0; i < all.length; i++)
            if (all[i].album === al && (all[i].albumArtist === aa || (all[i].albumArtists || []).indexOf(aa) >= 0)) return all[i];
        return null;
    }
    function _artistInfo(name) {
        const albums = [];
        const all = stack.albums || [];
        for (let i = 0; i < all.length; i++)
            if ((all[i].albumArtists || [all[i].albumArtist]).indexOf(name) >= 0) albums.push(all[i]);
        let rec = null;
        const arts = stack.artists || [];
        for (let k = 0; k < arts.length; k++) if (arts[k].name === name) rec = arts[k];
        let dur = 0;
        let songs = 0;
        for (let j = 0; j < albums.length; j++) { dur += Number(albums[j].duration) || 0; songs += Number(albums[j].songCount) || 0; }
        return { name: name, albums: albums, songCount: rec ? (Number(rec.songCount) || songs) : songs,
                 duration: rec && rec.duration > 0 ? rec.duration : dur, genre: rec ? (rec.genre || "") : "" };
    }
    // The header shows at once, from the shelf; an album's songs follow when the host answers.
    function _firstInfo(kind, a, b) {
        if (kind === "artist")
            return stack._artistInfo(a);
        const rec = stack._shelfAlbum(a, b);
        return rec ? { albumArtist: rec.albumArtist, albumArtists: rec.albumArtists || [rec.albumArtist], album: rec.album,
                       coverUrl: rec.coverUrl, year: rec.year || 0, date: rec.date || "", genre: rec.genre || "",
                       duration: rec.duration || 0, songs: [], discs: 1, formats: [], mixed: false, label: "" }
                   : { albumArtist: a, albumArtists: [a], album: b, coverUrl: "", year: 0, genre: "", duration: 0, songs: [],
                       discs: 1, formats: [], mixed: false, label: "" };
    }

    // ---- the tile: what a page grows out of and lands back on -----------------------------------------
    // `t`: { where: "list", ... } a row of the host's list | { where: "page", kind, a, b } a row or a link of the page under | { get() } a row of another panel | null.
    function _tileOf(t, under) {
        if (!t)
            return null;
        if (t.get)
            return t.get();
        if (t.where === "list")
            return under === null && stack.listTile ? stack.listTile(t) : null;
        const pg = under !== null ? stack._pageIn(1 - stack._topSlot) : null;
        const it = pg ? pg.tileOf(t.kind, t.a, t.b) : null;
        return it ? { item: it, w: it.width, h: it.height, color: stack.listBoxColor, radius: 6, facts: null } : null;
    }
    // Where the tile is drawn on this frame. A zoomed row runs past the box's sides, where the list's clip cuts it: the card stops there too.
    // A row that went under the morph (a filter landed) is where it was last seen.
    function _tileRect(m) {
        const it = m.tileItem;
        if (it) {
            const p = it.mapToItem(pageHost, 0, 0);
            const q = it.mapToItem(pageHost, m.tileW, m.tileH);
            const x0 = Math.max(0, p.x);
            const x1 = Math.min(pageHost.width, q.x);
            m.last = { x: x0, y: p.y, w: x1 - x0, h: q.y - p.y };
        }
        return m.last || { x: pageHost.width / 2, y: pageHost.height / 2, w: 0, h: 0 };
    }
    function _focusOf(tile) {
        if (tile) {
            const p = tile.item.mapToItem(pageHost, tile.w / 2, tile.h / 2);
            return { x: p.x, y: p.y };
        }
        return { x: pageHost.width / 2, y: pageHost.height / 2 };
    }
    // The card on this frame, and the page's scale inside it. The clock is read first: it is what re-reads the tile's live rect.
    readonly property var cardRect: {
        const me = pageClock.me;
        const m = stack._m;
        if (!m)
            return null;
        const i = stack.inset;
        const full = { x: i, y: i, w: pageHost.width - 2 * i, h: pageHost.height - 2 * i };
        const r = LM.cardRect(stack._tileRect(m), full, m.dir, me);
        r.s = Math.min(1, Math.min(r.w / Math.max(1, full.w), r.h / Math.max(1, full.h)));
        return r;
    }

    // ---- open and back ----------------------------------------------------------------------------------
    function _morphOf(dir, under, t, all, scrub, ret) {
        return { dir: dir, under: under, tileItem: t ? t.item : null, tileFacts: t ? t.facts : null, tileW: t ? t.w : 0, tileH: t ? t.h : 0,
                 tileColor: t ? t.color : stack.listBoxColor, tileRadius: t ? t.radius : stack.containerRadius, focus: stack._focusOf(t), all: all, scrub: scrub,
                 foreign: !!ret && ret.panel !== "", panel: ret ? ret.panel : "" };
    }
    // `first`: what a song's page shows until the daemon has answered ({ title, artist, album }).
    function openPage(kind, a, b, tileFact, ret, first) {
        if (stack._m)
            stack._finishPageNow();
        const st = stack._pageStack.slice();
        const top = st.length > 0 ? st[st.length - 1] : null;
        if (top && top.kind === kind && top.a === a && top.b === b) {
            if (ret)
                stack._setReturn(top, ret);
            return;
        }
        const under = top;
        if (under) {
            const shown = stack._pageIn(stack._topSlot);
            under.y = shown ? shown.scrollY : 0;
        }
        const e = { id: ++stack._pageSerial, kind: kind, a: a, b: b, info: kind === "song" ? (first || null) : stack._firstInfo(kind, a, b), loading: kind === "album", y: 0,
                    backLabel: ret ? ret.label : stack._labelUnder(st), tile: tileFact || null, ret: ret || null };
        // Read before the slots move: `_tileOf` asks the page that is on show now.
        const free = under ? 1 - stack._topSlot : stack._topSlot;
        stack._topSlot = free;
        const t = stack._tileOf(e.tile, under);
        const m = stack._morphOf("open", under, t, false, false, e.ret);
        stack._setSlot(free, e);
        // A slot used before keeps its page: the new one starts at its head.
        const pg = stack._pageIn(free);
        if (pg)
            pg.scrollY = 0;
        st.push(e);
        stack._pageStack = st;
        pageClock.mt = 0;
        stack._m = m;
        pageClock.runTo(1);
        if (kind === "album")
            stack.albumAsked(a, b);
    }
    // The page right under the one on show is this one.
    function underIs(kind, a, b) {
        const st = stack._pageStack;
        const e = st.length > 1 ? st[st.length - 2] : null;
        if (!e || e.kind !== kind)
            return false;
        return kind === "artist" ? e.a === a : e.b === b && (e.a === a || (e.info.albumArtists || []).indexOf(a) >= 0);
    }
    function _setReturn(e, ret) {
        e.ret = ret;
        e.backLabel = ret.label;
        stack._refreshSlots(e);
    }
    function _refreshSlots(e) {
        for (let n = 0; n < 2; n++)
            if (stack._slots[n] && stack._slots[n].id === e.id)
                stack._setSlot(n, Object.assign({}, e));
    }
    // The hand took over (a tab, the burger): nothing leads back across a panel.
    function forgetReturns() {
        const st = stack._pageStack;
        for (let i = 0; i < st.length; i++) {
            if (!st[i].ret)
                continue;
            st[i].ret = null;
            st[i].backLabel = stack._labelUnder(st.slice(0, i));
            stack._refreshSlots(st[i]);
        }
    }
    // A page opened before the shelf was read (a jump into a library nobody has looked at yet) has only names: the shelf fills in what the header takes from it.
    onAlbumsChanged: {
        const st = stack._pageStack;
        for (let i = 0; i < st.length; i++) {
            const e = st[i];
            if (e.kind === "artist") {
                e.info = stack._artistInfo(e.a);
            } else if (e.kind === "album") {
                const rec = stack._shelfAlbum(e.a, e.b);
                if (!rec || e.info.coverUrl)
                    continue;
                e.info = Object.assign({}, e.info, { coverUrl: rec.coverUrl, date: e.info.date || rec.date || "", albumArtists: rec.albumArtists || e.info.albumArtists });
            } else {
                continue;
            }
            stack._refreshSlots(e);
        }
    }
    // The host's answer: albumInfo(), keyed by the album it was asked about. It can land under a deeper page: it goes to its own entry.
    function showAlbumPage(albumArtist, album, info) {
        const st = stack._pageStack;
        for (let i = st.length - 1; i >= 0; i--) {
            const e = st[i];
            if (e.kind !== "album" || e.b !== album || (e.a !== albumArtist && e.info.albumArtists.indexOf(e.a) < 0))
                continue;
            const m = {};
            for (const k in e.info) m[k] = e.info[k];
            for (const k2 in info) m[k2] = info[k2];
            e.info = m;
            e.loading = false;
            stack._refreshSlots(e);
            return;
        }
    }
    function closePage(all) {
        if (stack._m) {
            if (stack._m.dir === "open" && !stack._m.reversed && all !== true) {
                if (stack.pageEntry.ret)
                    stack.returnTaken(stack.pageEntry.ret);
                stack._reversePage();
                return;
            }
            stack._finishPageNow();
        }
        if (stack._pageStack.length === 0)
            return;
        const ret = all !== true ? stack.pageEntry.ret : null;
        if (ret) {
            stack.returnTaken(ret);
            if (ret.panel === "")
                return;        // the sidebar's own close carries it: `dropTop()`
        }
        stack._startBack(all === true, false);
    }
    // The page on show goes with no motion of its own (the sidebar it stood in has shut).
    function dropTop() {
        const n = stack._pageStack.length;
        if (stack._m)
            stack._finishPageNow();
        if (n > 0 && stack._pageStack.length === n)
            stack._applyBack({ all: false });
    }
    function _startBack(all, scrub) {
        const st = stack._pageStack;
        const n = st.length;
        const top = st[n - 1];
        const ret = !all && top.ret && top.ret.panel !== "" ? top.ret : null;
        const next = !all && n > 1 ? st[n - 2] : null;
        const under = ret ? null : next;
        const free = 1 - stack._topSlot;
        if (next) {
            const held = stack._slots[free];
            if (!held || held.id !== next.id)
                stack._setSlot(free, next);
            const pg = stack._pageIn(free);
            if (pg)
                pg.scrollY = next.y;
        } else {
            stack._setSlot(free, null);
        }
        // A page goes back to what it was opened from; all the way down, to what the bottom page was opened from.
        const t = stack._tileOf((all ? st[0] : top).tile, under);
        pageClock.mt = 0;
        stack._m = stack._morphOf("back", under, t, all, scrub, ret);
        if (!scrub)
            pageClock.runTo(1);
    }
    // Harnesses: hold a running morph at clock `t` (a filmstrip), and let it go on.
    function pinPageMorph(t) {
        pageClock.stop();
        pageClock.mt = t;
    }
    function releasePageMorph() {
        if (stack._m)
            pageClock.runTo(stack._m.reversed || stack._m.cancelled ? 0 : 1);
    }
    // An open taken back half way: the same clock, run home.
    function _reversePage() {
        const n = Object.assign({}, stack._m);
        n.reversed = true;
        stack._m = n;
        pageClock.runTo(0);
    }
    // The stack as a finished back leaves it.
    function _applyBack(m) {
        const st = stack._pageStack.slice();
        const old = stack._topSlot;
        if (m.all || st.length < 2) {
            st.length = 0;
            stack._slots = [null, null];
            stack._topSlot = 0;
        } else {
            st.pop();
            stack._topSlot = 1 - old;
            stack._setSlot(old, null);
        }
        stack._pageStack = st;
    }
    function _undoOpen() {
        const st = stack._pageStack.slice();
        const old = stack._topSlot;
        st.pop();
        if (st.length > 0)
            stack._topSlot = 1 - old;
        stack._setSlot(old, null);
        stack._pageStack = st;
    }
    function _pageLanded() {
        const m = stack._m;
        if (!m)
            return;
        if (pageClock.mt >= 1 && m.dir === "back")
            stack._applyBack(m);
        else if (pageClock.mt <= 0 && m.dir === "open" && m.reversed)
            stack._undoOpen();
        if (pageClock.mt >= 1 || pageClock.mt <= 0) {
            stack._m = null;
            pageClock.mt = 0;
        }
    }
    // Jump a running morph to where it is going.
    function _finishPageNow() {
        const m = stack._m;
        if (!m)
            return;
        pageClock.stop();
        if (m.dir === "back" && !m.cancelled)
            stack._applyBack(m);
        else if (m.dir === "open" && m.reversed)
            stack._undoOpen();
        stack._m = null;
        pageClock.mt = 0;
    }
    // The fingers lifted from a scrub (commit or spring back); with no scrub under them it was a notch: one whole back.
    function _swipeLifted(commit) {
        if (!pageSwipe.active) {
            stack.closePage();
            return;
        }
        if (stack._m && stack._m.scrub) {
            const n = Object.assign({}, stack._m);
            n.scrub = false;
            if (!commit)
                n.cancelled = true;
            stack._m = n;
            const top = stack.pageEntry;
            if (commit && top && top.ret)
                stack.returnTaken(top.ret);
            pageClock.runTo(commit ? 1 : 0);
        } else if (!stack._m) {
            pageClock.stop();
        }
    }

    // ---- what it draws ------------------------------------------------------------------------------------
    DeviceScale {
        id: dev
    }
    Item {
        id: pageHost
        objectName: "playerPageHost"
        anchors.fill: parent

        Repeater {
            id: pageSlots
            model: 2
            delegate: Item {
                id: slot
                required property int index
                readonly property var entry: stack._slots[slot.index]
                readonly property bool onTop: stack._topSlot === slot.index
                readonly property var cr: slot.onTop ? stack.cardRect : null
                readonly property var page: pageLoader.item
                z: slot.onTop ? 2 : 0
                visible: slot.entry !== null && (slot.onTop || stack._m !== null)
                // On show: the box. In a morph the page on top is cut to the card and fades in it; the one under recedes, unless the morph is crossing panels.
                x: slot.cr ? slot.cr.x : 0
                y: slot.cr ? slot.cr.y : 0
                width: slot.cr ? slot.cr.w : pageHost.width
                height: slot.cr ? slot.cr.h : pageHost.height
                clip: slot.cr !== null
                opacity: slot.cr ? stack._fr.arrive : (slot.onTop ? 1 : (stack._m && stack._m.foreign ? 0 : stack._fr.recede))

                Item {
                    id: pageHold
                    readonly property real s: slot.cr ? slot.cr.s : 1
                    // Laid out once, at the box's size, and scaled: whole from its first frame, centred on the card, pinned to its head.
                    x: slot.cr ? (slot.cr.w - pageHold.s * pageHost.width) / 2 : 0
                    y: slot.cr ? -stack.inset * pageHold.s : 0
                    width: pageHost.width
                    height: pageHost.height
                    transform: Scale {
                        origin.x: !slot.onTop && stack._m ? stack._m.focus.x : 0
                        origin.y: !slot.onTop && stack._m ? stack._m.focus.y : 0
                        xScale: slot.onTop ? pageHold.s : stack._fr.zoom
                        yScale: slot.onTop ? pageHold.s : stack._fr.zoom
                    }
                    Loader {
                        id: pageLoader
                        anchors.fill: parent
                        active: slot.entry !== null
                        sourceComponent: slot.entry && slot.entry.kind === "song" ? songPage : albumPage
                    }
                    Component {
                        id: albumPage
                        PlayerLibraryPage {
                            kind: slot.entry ? slot.entry.kind : "album"
                            info: slot.entry ? slot.entry.info : null
                            loading: slot.entry ? slot.entry.loading : false
                            backLabel: slot.entry ? slot.entry.backLabel : ""
                            currentFile: stack.currentFile
                            playing: stack.playing
                            fontFamily: stack.fontFamily
                            containerRadius: stack.containerRadius
                            insetFoot: stack.inset
                            listBoxColor: stack.listBoxColor
                            headerBoxColor: stack.headerBoxColor
                            surfaceColor: stack.surfaceColor
                            bevelColor: stack.bevelColor
                            borderColor: stack.borderColor
                            textColor: stack.textColor
                            mutedColor: stack.mutedColor
                            faintColor: stack.faintColor
                            accentColor: stack.accentColor
                            accentHoverColor: stack.accentHoverColor
                            accentBevelColor: stack.accentBevelColor
                            textOnAccentColor: stack.textOnAccentColor
                            buttonPlateauColor: stack.buttonPlateauColor
                            buttonPlateauHoverColor: stack.buttonPlateauHoverColor
                            buttonBevelColor: stack.buttonBevelColor
                            buttonShadowColor: stack.buttonShadowColor
                            scrollSpeed: stack.scrollSpeed
                            onBackRequested: stack.closePage()
                            onWholeRequested: what => {
                                const c = pageHost.mapToItem(null, pageHost.width / 2, pageHost.height / 2);
                                stack.wholeRequested(what, stack.pageEntry, c.x, c.y);
                            }
                            onSongClicked: uri => stack.songClicked(uri)
                            onSongMenuRequested: (uri, sx, sy) => stack.songMenuRequested(uri, sx, sy)
                            onAlbumClicked: (aa, al) => stack.openPage("album", aa, al, { where: "page", kind: "album", a: aa, b: al })
                            onAlbumMenuRequested: (aa, al, sx, sy) => stack.albumMenuRequested(aa, al, sx, sy)
                            onArtistClicked: name => stack.openPage("artist", name, "", { where: "page", kind: "artist", a: name, b: "" })
                        }
                    }
                    Component {
                        id: songPage
                        PlayerSongSheet {
                            player: stack.player
                            uri: slot.entry ? slot.entry.a : ""
                            first: slot.entry ? slot.entry.info : null
                            backLabel: slot.entry ? slot.entry.backLabel : ""
                            fontFamily: stack.fontFamily
                            insetFoot: stack.inset
                            listBoxColor: stack.listBoxColor
                            textColor: stack.textColor
                            mutedColor: stack.mutedColor
                            faintColor: stack.faintColor
                            accentColor: stack.accentColor
                            buttonPlateauColor: stack.buttonPlateauColor
                            buttonPlateauHoverColor: stack.buttonPlateauHoverColor
                            buttonBevelColor: stack.buttonBevelColor
                            buttonShadowColor: stack.buttonShadowColor
                            scrollSpeed: stack.scrollSpeed
                            onBackRequested: stack.closePage()
                            onActionRequested: (action, song) => stack.songAction(action, song)
                        }
                    }
                }
            }
        }

        // DEAF WHILE IT MOVES, AND NOT DISABLED. `enabled` is inherited: a slot switched off for the morph would switch off the page's Play with it, and a disabled default answer
        // drops its accent (RaisedButton), so the button would light up only when the card had landed. This cover takes the pointer instead.
        WheelArea {
            anchors.fill: parent
            z: 5
            visible: stack._m !== null
            acceptedButtons: Qt.AllButtons
            hoverEnabled: true
            turned: wheel => wheel.accepted = true
        }

        // The tile on its way to becoming the page, or back (LevelMorph.js has the arithmetic).
        MorphCard {
            id: pageCard
            readonly property var cr: stack.cardRect
            z: 1
            visible: pageCard.cr !== null
            x: pageCard.cr ? pageCard.cr.x : 0
            y: pageCard.cr ? pageCard.cr.y : 0
            width: pageCard.cr ? pageCard.cr.w : 0
            height: pageCard.cr ? pageCard.cr.h : 0
            raised: false
            face: !stack._m ? null : stack._m.tileFacts ? stack.rowFace : stack._m.tileItem ? tileFace : null
            facts: stack._m ? stack._m.tileFacts : null
            grow: stack._m ? (stack._m.dir === "open" ? pageClock.me : 1 - pageClock.me) : 0
            faceF: stack._fr.faceF
            tileW: stack._m ? stack._m.tileW : 0
            tileH: stack._m ? stack._m.tileH : 0
            tileRadius: stack._m ? stack._m.tileRadius : stack.containerRadius
            tileColor: stack._m ? stack._m.tileColor : stack.listBoxColor
            groundColor: stack.listBoxColor
            readonly property real innerRadius: Math.max(0, stack.containerRadius - stack.inset)
            radii: [pageCard.innerRadius, pageCard.innerRadius, pageCard.innerRadius, pageCard.innerRadius]
        }
        // A page's row or link, a row of the queue: flat ink on the ground, taken as it stands.
        Component {
            id: tileFace
            ShaderEffectSource {
                sourceItem: stack._m ? stack._m.tileItem : null
                sourceRect: Qt.rect(0, 0, width, height)
                textureSize: dev.texSize(width, height)
                live: true
            }
        }
    }
    readonly property var cardFacts: stack._m ? stack._m.tileFacts : null

    // Two fingers sideways: back, under the fingers (NotesPopup, the same reader). Only over a page; a vertical motion goes on to the scroll. A back that is the sidebar's own
    // close cannot be scrubbed: it is one step.
    SwipeScrub {
        id: pageSwipe
        anchors.fill: parent
        enabled: stack.pageOpen
        z: 10
        units: stack.swipeBackUnits
        sign: stack.swipeBackSign
        canBegin: stack.pageOpen
        stepOnly: !!stack.pageEntry && !!stack.pageEntry.ret && stack.pageEntry.ret.panel === ""
        blocked: !!stack._m && stack._m.dir === "back" && !stack._m.scrub && !stack._m.cancelled
        onScrub: p => {
            if (!pageSwipe.active) {
                if (stack._m)
                    stack._finishPageNow();
                if (stack._pageStack.length > 0)
                    stack._startBack(false, true);
            }
            pageClock.scrubTo(p);
        }
        onCommit: stack._swipeLifted(true)
        onCancel: stack._swipeLifted(false)
        onStep: stack.closePage()
    }
}
