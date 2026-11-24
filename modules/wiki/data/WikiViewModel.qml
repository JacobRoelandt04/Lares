pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../../common/system"
import "WikiCardModel.js" as Card
import "WikiPool.js" as Pool

// =============================================================================
// WikiViewModel.qml -- what the wiki popup READS, whatever fed it. WikiService
// and WikiMock each hold one and expose its getters as their own, so the card
// assembly, the trail and the counts are one implementation (the StocksService /
// StocksMock / StocksViewModel pattern). Contract: docs/contracts/wiki.md
// ("QML surfaces").
//
// FEEDING IT (asks, from handlers -- never from a binding)
//   ingestIndex(text)         index.json as it is on disk
//   ingestDaily(text|object)  daily/<day>.json
//   setSeen(map)              { id: ms } -- the service's own map, by reference
//   showSlot(tab, id, why)    read the entry off disk, build its card; false when
//                             the file cannot be read (the tab shows nothing)
//   showSlotEntry(tab, entry, why)   the same from an entry in hand
//   clearSlot(tab)
//   showFollowed(tab, entry, parentTitle)   the rabbit hole: the card on show is
//                             pushed onto the trail, the entry is shown (followed)
//   upgradeIntro(id, intro)   the tool's `upgrade`: a written intro swapped in
//   back(tab) / closeCard()   walk the trail / clear every trail
//   setLoading(tab, on)
//
// READING IT (getters: read only, they never ask -- a getter called from a
// binding must not touch the disk or start anything, CLAUDE.md)
//   card(tab)  trail(tab)  canBack(tab)  unseen(tab)  loading(tab)  whyText(card)
//   cardFor(tab, id)  rows(tab)  rowOf(tab, id)  entryOf(id)
//
// EVERY GETTER READS `serial` FIRST: it is the one notification (a `var` that
// is mutated in place tells a binding nothing) and it is bumped where the data
// is written. The cards are built when their inputs change and KEPT BY
// IDENTITY, and `trail(tab)` is the same array until it really changes, so a
// binding that re-reads after an unrelated bump gets the very object it had and
// a Repeater over it (or over `card.introLinks`) regenerates nothing. Cards
// hold FACTS only -- never a colour (a Repeater model may not hold a themed
// colour); the delegate resolves `hueToken`.
//
// HOW AN ENTRY IS READ (the FileView laws, CLAUDE.md). A FileView loads
// synchronously on its FIRST path assignment and hands back the PREVIOUS file's
// bytes on any later one, so one is never repointed. An entry file is immutable
// once the tool has written it (atomic replace), so it is read ONCE: a FileView
// created with the path as an initial property (blockLoading: text() answers at
// once), parsed, and destroyed. No view outlives its read, none can be repointed,
// and nothing polls. The parsed entries are kept in a small LRU (`entryCap`) so
// a card that comes back (a trail step, a rebuild) costs no read.
// =============================================================================
Item {
    id: root

    // The directory that holds index.json, entries/<tab>/, img/ (and, for the
    // mock, live/): $XDG_STATE_HOME/lares/wiki for the service.
    property string stateDir: ""
    readonly property string stateUrl: root.stateDir ? "file://" + encodeURI(root.stateDir) : ""
    property string familiesPath: RepoRoot.dir + "/modules/wiki/data/families.json"
    readonly property var families: root._families
    property int entryCap: 40
    property int trailCap: 20
    // The mock's pretend pool: added to `unseen(tab)` so "24 left" can be
    // shown from eight hand-made rows. The service leaves it at 0.
    property var unseenPad: ({ discover: 0, deepen: 0 })

    readonly property int serial: root._serial
    readonly property var daily: root._daily

    // ---- feeding ---------------------------------------------------------------------
    function ingestIndex(text) {
        let o = null;
        try { o = JSON.parse(text || "null"); } catch (e) { o = null; }
        const tabs = o && typeof o === "object" && o.tabs && typeof o.tabs === "object" ? o.tabs : null;
        if (!tabs) return false;
        const next = { discover: [], deepen: [] };
        for (const tab in next) {
            const list = Array.isArray(tabs[tab]) ? tabs[tab] : [];
            for (let i = 0; i < list.length; i++) {
                const r = list[i];
                if (r && typeof r.id === "string" && r.id.length > 0)
                    next[tab].push(r);
            }
        }
        root._rows = next;
        root._bump();
        return true;
    }

    function ingestDaily(v) {
        let o = v;
        if (typeof v === "string") {
            try { o = JSON.parse(v || "null"); } catch (e) { o = null; }
        }
        root._daily = o && typeof o === "object" ? o : null;
        // The Discover card carries today's On-this-day line: rebuild it.
        root._rebuild("discover");
        root._bump();
    }

    function setSeen(map) {
        root._seen = map || {};
        root._bump();
    }

    function setLoading(tab, on) {
        const t = root._rec(tab);
        if (!t || t.loading === !!on) return;
        t.loading = !!on;
        root._bump();
    }

    function showSlot(tab, id, why) {
        return root.showSlotEntry(tab, id ? root.loadEntry(tab, id) : null, why);
    }

    // The same from an entry already in hand (the mock's doctored copy).
    function showSlotEntry(tab, entry, why) {
        const t = root._rec(tab);
        if (!t) return false;
        t.slot = entry ? { id: entry.id, why: why || null, entry: entry } : null;
        t.follow = null;
        t.trail = [];
        root._rebuild(tab);
        root._bump();
        return !!entry;
    }

    function clearSlot(tab) {
        const t = root._rec(tab);
        if (!t) return;
        t.slot = null;
        t.follow = null;
        t.trail = [];
        root._rebuild(tab);
        root._bump();
    }

    function showFollowed(tab, entry, parentTitle) {
        const t = root._rec(tab);
        if (!t || !entry || !entry.id) return;
        if (t.cur) {
            const tr = t.trail.concat([t.cur]);
            t.trail = tr.length > root.trailCap ? tr.slice(tr.length - root.trailCap) : tr;
        }
        root._remember(root._live, root._liveOrder, entry.id, entry);
        t.follow = { entry: entry, parentTitle: parentTitle || "" };
        root._rebuild(tab);
        root._bump();
    }

    function upgradeIntro(id, intro) {
        const e = root._live[id];
        if (!e || !intro) return;
        const up = Object.assign({}, e, { intro: intro });
        root._live[id] = up;
        root.ensureFamilies();
        for (const tab in root._tabs) {
            const t = root._tabs[tab];
            if (t.follow && t.follow.entry.id === id)
                t.follow = { entry: up, parentTitle: t.follow.parentTitle };
            if (t.cur && t.cur.id === id)
                root._rebuild(tab);
            for (let i = 0; i < t.trail.length; i++) {
                if (t.trail[i].id !== id) continue;
                const tr = t.trail.slice();
                tr[i] = Card.cardOf(up, root._families, root.stateUrl,
                                    { followed: true, parentTitle: t.trail[i].followedFrom });
                t.trail = tr;
            }
        }
        root._bump();
    }

    // -> true when a step was taken
    function back(tab) {
        const t = root._rec(tab);
        if (!t || t.trail.length === 0) return false;
        const c = t.trail[t.trail.length - 1];
        t.trail = t.trail.slice(0, t.trail.length - 1);
        t.follow = c.followed && root._live[c.id]
            ? { entry: root._live[c.id], parentTitle: c.followedFrom } : null;
        t.cur = c;
        root._bump();
        return true;
    }

    // Back to what each tab had before the first step: the bottom of the trail IS
    // that card, so the very object comes back (nothing that reads it re-evaluates).
    function closeCard() {
        for (const tab in root._tabs) {
            const t = root._tabs[tab];
            if (t.trail.length === 0 && !t.follow) continue;
            const base = t.trail.length > 0 ? t.trail[0] : null;
            t.trail = [];
            t.follow = null;
            if (base) t.cur = base;
            else root._rebuild(tab);
        }
        root._bump();
    }

    // The entry as it is on disk (asks; cached). `tab` names the directory.
    function loadEntry(tab, id) {
        const hit = root._entries[id];
        if (hit) return hit;
        const row = root.rowOf(tab, id);
        const slug = row && row.slug ? row.slug : root.slugOf(id);
        const e = root.readJson(root.stateDir + "/entries/" + tab + "/" + slug + ".json");
        if (!e || e.id !== id) return null;
        root._remember(root._entries, root._entryOrder, id, e);
        return e;
    }

    // One read of one file: a FileView made with its path, read, destroyed.
    function readJson(path) {
        const v = viewComp.createObject(root, { path: path }) as FileView;
        if (!v) return null;
        let o = null;
        try { o = JSON.parse(v.text() || "null"); } catch (e) { o = null; }
        v.destroy();
        return o && typeof o === "object" ? o : null;
    }

    // host + "__" + the rest, "#" as "--" (CONTRACT.md "Paths"): the file of an
    // id the index does not list.
    function slugOf(id) {
        const i = String(id).indexOf("/");
        if (i < 0) return String(id);
        return id.substring(0, i) + "__" + id.substring(i + 1).replace(/#/g, "--");
    }

    // ---- reading ---------------------------------------------------------------------
    function card(tab) {
        void root._serial;
        const t = root._tabs[tab];
        return t ? t.cur : null;
    }
    function trail(tab) {
        void root._serial;
        const t = root._tabs[tab];
        return t ? t.trail : root._none;
    }
    function canBack(tab) {
        void root._serial;
        const t = root._tabs[tab];
        return !!t && t.trail.length > 0;
    }
    function loading(tab) {
        void root._serial;
        const t = root._tabs[tab];
        return !!t && t.loading;
    }
    // The unseen count: the rows nobody has seen, plus the mock's pad.
    function unseen(tab) {
        void root._serial;
        return Pool.unseen(root._rows[tab], root._seen).length + (root.unseenPad[tab] || 0);
    }
    function whyText(card) {
        return card ? card.whyText : "";
    }
    // The card of `id` on `tab`: the one on show or one on the trail.
    function cardFor(tab, id) {
        void root._serial;
        const t = root._tabs[tab];
        if (!t) return null;
        if (t.cur && t.cur.id === id) return t.cur;
        for (let i = t.trail.length - 1; i >= 0; i--)
            if (t.trail[i].id === id) return t.trail[i];
        return null;
    }
    function rows(tab) {
        void root._serial;
        return root._rows[tab] || root._none;
    }
    function rowOf(tab, id) {
        const list = root._rows[tab] || root._none;
        for (let i = 0; i < list.length; i++)
            if (list[i].id === id) return list[i];
        return null;
    }
    // The parsed entry when it has been read (a getter: never reads).
    function entryOf(id) {
        return root._entries[id] || root._live[id] || null;
    }
    // The slot's entry of a tab, or null.
    function slotOf(tab) {
        const t = root._tabs[tab];
        return t && t.slot ? t.slot : null;
    }

    // ---- private -----------------------------------------------------------------------
    property var _families: ({})
    property var _rows: ({ discover: [], deepen: [] })
    property var _seen: ({})
    property var _daily: null
    property int _serial: 0
    property var _entries: ({})
    property var _entryOrder: []
    property var _live: ({})
    property var _liveOrder: []
    readonly property var _none: []
    // tab -> { slot: {id, why, entry}|null, follow: {entry, parentTitle}|null,
    //          cur: card|null, trail: [card], loading }
    property var _tabs: ({
        discover: { slot: null, follow: null, cur: null, trail: [], loading: false },
        deepen: { slot: null, follow: null, cur: null, trail: [], loading: false }
    })

    function _bump() { root._serial++; }
    function _rec(tab) { return root._tabs[tab] || null; }

    // A small insertion-ordered LRU: the oldest entry goes when `entryCap` is passed.
    function _remember(map, order, id, value) {
        if (map[id] === undefined) order.push(id);
        map[id] = value;
        while (order.length > root.entryCap) {
            const old = order.shift();
            delete map[old];
        }
    }

    function _rebuild(tab) {
        root.ensureFamilies();
        const t = root._tabs[tab];
        if (t.follow) {
            t.cur = Card.cardOf(t.follow.entry, root._families, root.stateUrl,
                                { followed: true, parentTitle: t.follow.parentTitle });
        } else if (t.slot) {
            const otd = tab === "discover" && root._daily && root._daily.otd ? root._daily.otd : null;
            t.cur = Card.cardOf(t.slot.entry, root._families, root.stateUrl, { why: t.slot.why, otd: otd });
        } else {
            t.cur = null;
        }
    }

    Component {
        id: viewComp
        FileView {
            blockLoading: true
            printErrors: false
            watchChanges: false
        }
    }

    FileView {
        id: famView
        path: root.familiesPath
        blockLoading: true
        printErrors: false
        watchChanges: false
    }

    // families.json is read once, by whichever comes first: the completion or the
    // first caller that needs it (a parent's onCompleted runs BEFORE its child's,
    // so a service that plans at its own completion must ask for it here).
    property bool _famRead: false
    function ensureFamilies() {
        if (root._famRead) return;
        root._famRead = true;
        try { root._families = JSON.parse(famView.text() || "{}"); } catch (e) { root._families = ({}); }
    }
    Component.onCompleted: root.ensureFamilies()
}
