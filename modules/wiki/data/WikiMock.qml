pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../../common/system"
import "WikiPool.js" as Pool

// =============================================================================
// WikiMock.qml -- the wiki service without a shell around it.
//
// The SAME members as WikiService (docs/contracts/wiki.md, "QML
// surfaces"): the popup, the compact cards and the teaser take ONE `service`
// and nothing above it changes when the mock is swapped for the real one. The
// getters are WikiViewModel's, the cards are assembled by the same
// WikiCardModel.js, from eight hand-made entries under
// modules/wiki/data/fixtures/:
//
//   discover  E1 Messier 87              photo, landscape, cleaned (parentheticals)
//             E2 Marie Curie             portrait (focusY 0.33), cleaned (dates)
//             E3 Battle of Hastings      wide image (2.76), GENERATED (sparkle)
//             E4 Anekantavada            no image: its veil, cleaned
//             E5 Formation and evolution of the Solar System
//                                        long title, two images (a carousel), original
//   deepen    E6 Systemd                 a logo relief on its veil's plate, installed, cleaned (hatnote)
//             E7 Zsh: keep the terminal usable   tips, no image, installed
//             E8 Debian                  Wikipedia computing, no image
//   daily     On this day (1791, The Magic Flute) + a Picture of the day that
//             relates to E5, so E5's first image is the potd
//   live/     the rabbit-hole page follow() answers (Globular cluster, cleaned,
//             then the generated intro); any other link answers a canned page
//
// `nowMs` is PINNED (2026-09-30 10:00 local), so the day, the On-this-day line
// and every relative time are the same in every run.
//
// `scenario` puts both tabs in a named state (assigning it applies it):
//   normal     discover E1, deepen E6, a pool of 25 / 14
//   portrait   discover E2
//   cleaned    discover E1 with a long list of removed things (the ✎ tip)
//   generated  discover E3 (the ✦ mark, its tip, the wide image)
//   noImage    discover E4, deepen E7 (both on their veil)
//   empty      nothing to show, nothing unseen, no batch running
//   loading    nothing to show yet, both tabs loading
//   follow     discover E1, then a follow of its "globular clusters" link
//   pool5      as normal with exactly 5 unseen per tab; refillAsked fires
//   offline    as normal, `offline` true and a lastError
// and `show(tab, id)` puts any of the eight on a tab. Timing knobs: followDelayMs
// (the page arrives), upgradeDelayMs (then the written intro replaces it),
// followHold (the page never arrives: the loading state to look at), answerMs
// (save-to-note), batchStepMs (one item of a simulated batch).
//
// Every ask is recorded in `calls` ([{ fn, tab, id }], the last 60), so a
// harness can prove that a button reaches the service without a real one.
// Nothing here reads the network or the user's state.
// =============================================================================
Item {
    id: root

    // ---- status -----------------------------------------------------------------------
    property bool popupOpen: false
    property real nowMs: new Date(2026, 8, 30, 10, 0, 0).getTime()
    readonly property bool ready: root._ready
    readonly property bool offline: root.scenario === "offline"
    readonly property bool busy: root._batch.running || vm.loading("discover") || vm.loading("deepen")
    readonly property string lastError: root.scenario === "offline" ? "Can't reach the network" : ""
    readonly property string day: Pool.dayKey(root.nowMs, 4)
    readonly property int serial: vm.serial
    readonly property var daily: vm.daily
    readonly property var batch: root._batch
    readonly property bool batchPending: false        // the real service's wait for the dGPU (never in the mock)
    property bool dryRun: false
    property int seenMs: 5000
    property int followDelayMs: 700
    property int upgradeDelayMs: 1400
    property bool followHold: false
    property int answerMs: 300
    property int batchStepMs: 350
    readonly property var calls: root._calls

    property string scenario: "normal"
    readonly property var scenarios: ["normal", "portrait", "cleaned", "generated", "noImage", "empty",
                                      "loading", "follow", "pool5", "offline", "noIntro"]
    readonly property string stateDir: RepoRoot.dir + "/modules/wiki/data/fixtures"
    readonly property var entryIds: ({
        discover: ["en.wikipedia.org/Messier_87", "en.wikipedia.org/Marie_Curie",
                   "en.wikipedia.org/Battle_of_Hastings", "en.wikipedia.org/Anekantavada",
                   "en.wikipedia.org/Formation_and_evolution_of_the_Solar_System"],
        deepen: ["wiki.archlinux.org/Systemd", "wiki.archlinux.org/Zsh#Tips_and_tricks",
                 "en.wikipedia.org/Debian"]
    })

    signal updated()
    signal openRequested(string tab)
    signal noteSaved(string tab, string id, bool ok, string keyOrError)
    signal refillAsked(string tab, int left)
    signal batchFinished(string tab, int ok, int failed)
    signal urlOpened(string url)

    // ---- getters (read only) -------------------------------------------------------------
    function card(tab) { return vm.card(tab); }
    function trail(tab) { return vm.trail(tab); }
    function canBack(tab) { return vm.canBack(tab); }
    function unseen(tab) { return vm.unseen(tab); }
    function loading(tab) { return vm.loading(tab); }
    function whyText(card) { return vm.whyText(card); }

    // ---- asks ---------------------------------------------------------------------------------
    function ensureSlots() {
        if (!vm.card("discover") && !vm.card("deepen") && root.scenario !== "empty" && root.scenario !== "loading")
            root._apply(root.scenario);
    }
    function shown(tab, id, visibleMs) {
        root._log("shown", tab, id);
    }
    function read(tab, id, readMs) {
        root._log("read", tab, id);
        if (readMs >= root.seenMs) root._markSeen(id);
    }
    function hoverDwell(tab, id, ms) { root._log("hoverDwell", tab, id); }
    // The buttons' choice, as WikiService keeps it (more / less one choice, the same again undoes it, knew a switch of its own).
    // The mock never rolls a day over: `commitChoices()` stands for the turnover, for a probe.
    property int choiceSerial: 0
    property var _choices: ({})
    function choiceOf(tab, id) {
        void root.choiceSerial;
        const c = root._choices[tab + "|" + id];
        return { more: !!c && c.taste === "more", less: !!c && c.taste === "less", knew: !!c && c.knew === true };
    }
    function commitChoices() { root._choices = ({}); root.choiceSerial++; }
    function _press(tab, id, kind) {
        root._log(kind, tab, id);
        const key = tab + "|" + id;
        const c = Object.assign({ taste: "", knew: false }, root._choices[key] || {});
        if (kind === "knew") c.knew = !c.knew;
        else c.taste = c.taste === kind ? "" : kind;
        const m = Object.assign({}, root._choices);
        if (c.taste === "" && !c.knew) delete m[key]; else m[key] = c;
        root._choices = m;
        root.choiceSerial++;
    }
    function more(tab, id) { root._press(tab, id, "more"); }
    function less(tab, id) { root._press(tab, id, "less"); }
    function knew(tab, id) { root._press(tab, id, "knew"); }
    function next(tab) {
        const cur = vm.card(tab);
        root._log("next", tab, cur ? cur.id : "");
        const ids = root.entryIds[tab] || [];
        if (ids.length === 0) return;
        const at = cur ? ids.indexOf(cur.id) : -1;
        if (cur) root._markSeen(cur.id);
        root.show(tab, ids[(at + 1) % ids.length]);
    }
    function openSource(tab, id) {
        root._log("openSource", tab, id);
        const c = vm.cardFor(tab, id);
        const url = c ? c.source.url : "";
        if (!/^https?:\/\//.test(url)) return;
        if (!root.dryRun) Qt.openUrlExternally(url);
        root.urlOpened(url);
    }
    function openLink(tab, id, url) {
        root._log("openLink", tab, id, url);
        if (!/^https?:\/\//.test(String(url))) return;
        if (!root.dryRun) Qt.openUrlExternally(url);
        root.urlOpened(String(url));
    }
    function follow(tab, link) {
        root._log("follow", tab, link ? link.url : "");
        const url = link && typeof link.url === "string" ? link.url : "";
        if (!/^https?:\/\//.test(url) || !vm.card(tab)) return;
        const from = vm.card(tab);
        root._follow = { tab: tab, url: url, target: link.target || "", parentTitle: from.title,
                         family: from.family, topic: from.topic };
        vm.setLoading(tab, true);
        if (root.followHold) return;
        followTimer.interval = Math.max(0, root.followDelayMs);
        followTimer.restart();
    }
    function followOnThisDay() {
        root._log("followOnThisDay", "discover", "");
        const o = vm.daily ? vm.daily.otd : null;
        if (o && o.url) root.follow("discover", { url: o.url, target: o.title || "" });
    }
    function back(tab) {
        root._log("back", tab, "");
        vm.back(tab);
    }
    function closeCard() {
        root._log("closeCard", "", "");
        followTimer.stop();
        upgradeTimer.stop();
        root._follow = null;
        vm.setLoading("discover", false);
        vm.setLoading("deepen", false);
        vm.closeCard();
    }
    function saveToNote(tab, id) {
        root._log("saveToNote", tab, id);
        const c = vm.cardFor(tab, id);
        root._save = { tab: tab, id: id, key: "Wiki/" + (c ? c.title : id) + ".md" };
        saveTimer.interval = Math.max(0, root.answerMs);
        saveTimer.restart();
    }
    function startBatch(tab) {
        root._log("startBatch", tab, "");
        if (root._batch.running) return;
        root._batch = { running: true, tab: tab, done: 0, total: 30, blocked: false, lastError: "" };
        batchTimer.interval = Math.max(1, root.batchStepMs);
        batchTimer.restart();
    }
    function refresh() { root._log("refresh", "", ""); root.updated(); }
    function requestOpen(tab) { root._log("requestOpen", tab, ""); root.openRequested(tab); }

    // The mock's own: put any of the eight on a tab (a fresh slot, like next()).
    function show(tab, id) {
        followTimer.stop();
        upgradeTimer.stop();
        root._follow = null;
        vm.setLoading(tab, false);
        vm.showSlot(tab, id, root._whyOf(tab, id));
        root.updated();
    }

    // ---- scenarios --------------------------------------------------------------------------------
    onScenarioChanged: if (root._ready) root._apply(root.scenario)

    function _apply(sc) {
        followTimer.stop();
        upgradeTimer.stop();
        batchTimer.stop();
        root._follow = null;
        root._batch = { running: false, tab: null, done: 0, total: 0, blocked: false, lastError: "" };
        vm.unseenPad = { discover: 20, deepen: 11 };
        vm.setSeen({});
        const ids = root.entryIds;
        let d = ids.discover[0], e = ids.deepen[0];
        if (sc === "portrait") d = ids.discover[1];
        else if (sc === "generated") d = ids.discover[2];
        else if (sc === "noImage") { d = ids.discover[3]; e = ids.deepen[1]; }
        else if (sc === "pool5") vm.unseenPad = { discover: 0, deepen: 2 };
        vm.setLoading("discover", sc === "loading");
        vm.setLoading("deepen", sc === "loading");
        if (sc === "empty" || sc === "loading") {
            vm.clearSlot("discover");
            vm.clearSlot("deepen");
            if (sc === "empty") {
                vm.unseenPad = { discover: 0, deepen: 0 };
                const all = {};
                const both = ids.discover.concat(ids.deepen);
                for (let i = 0; i < both.length; i++) all[both[i]] = root.nowMs;
                vm.setSeen(all);
            }
        } else {
            vm.showSlot("discover", d, root._whyOf("discover", d));
            vm.showSlot("deepen", e, root._whyOf("deepen", e));
            if (sc === "cleaned") root._forceCleaned();
        }
        if (sc === "noIntro") {
            // E1 with no intro text: a compact card then shows its On-this-day line as the body.
            const e0 = vm.entryOf(d);
            vm.showSlotEntry("discover", Object.assign({}, e0, { intro: Object.assign({}, e0.intro, { text: "", words: 0, links: [] }) }), root._whyOf("discover", d));
        }
        if (sc === "follow") {
            const c = vm.card("discover");
            const l = c ? c.introLinks[2] : null;      // "globular clusters"
            if (l) root.follow("discover", l);
        }
        if (sc === "pool5") {
            root.refillAsked("discover", 5);
            root.refillAsked("deepen", 5);
        }
        root.updated();
    }

    // The ✎ tip's longest form: E1's card with every kind of removal named.
    function _forceCleaned() {
        const e = vm.entryOf(root.entryIds.discover[0]);
        if (!e) return;
        const intro = Object.assign({}, e.intro, { provenance: "cleaned",
            stripped: ["pronunciation", "ipa", "native_names", "dates", "coordinates", "citations", "parentheticals"] });
        vm.showSlotEntry("discover", Object.assign({}, e, { intro: intro }), root._whyOf("discover", e.id));
    }

    function _whyOf(tab, id) {
        const r = vm.rowOf(tab, id);
        if (!r) return null;
        const p = tab === "deepen" ? 0.3 : 0.11;
        return { p: p, oneIn: Math.round(1 / p), openRate: tab === "discover" && id.indexOf("Curie") < 0 ? 0.4 : null };
    }

    function _markSeen(id) {
        if (!id) return;
        const s = Object.assign({}, root._seenMap);
        if (s[id]) return;
        s[id] = root.nowMs;
        root._seenMap = s;
        vm.setSeen(s);
    }
    function _log(fn, tab, id) {
        const c = root._calls.concat([{ fn: fn, tab: tab, id: id }]);
        root._calls = c.length > 60 ? c.slice(c.length - 60) : c;
    }

    // ---- state ---------------------------------------------------------------------------------------
    property bool _ready: false
    property var _seenMap: ({})
    property var _calls: []
    property var _follow: null
    property var _save: null
    property var _batch: ({ running: false, tab: null, done: 0, total: 0, blocked: false, lastError: "" })

    WikiViewModel { id: vm; stateDir: root.stateDir }

    FileView {
        id: indexFile
        path: root.stateDir + "/index.json"
        blockLoading: true
        printErrors: false
        watchChanges: false
    }
    FileView {
        id: dailyFile
        path: root.stateDir + "/daily.json"
        blockLoading: true
        printErrors: false
        watchChanges: false
    }

    Timer {
        id: followTimer
        onTriggered: {
            const f = root._follow;
            if (!f) return;
            const slug = vm.slugOf(f.url.replace(/^https?:\/\//, "").replace("/wiki/", "/"));
            let entry = vm.readJson(root.stateDir + "/live/" + slug + ".json");
            if (!entry) entry = root._canned(f);
            vm.showFollowed(f.tab, entry, f.parentTitle);
            vm.setLoading(f.tab, false);
            root.updated();
            const up = vm.readJson(root.stateDir + "/live/" + slug + ".upgrade.json");
            if (up && up.intro && up.id === entry.id) {
                root._pendingUpgrade = up;
                upgradeTimer.interval = Math.max(0, root.upgradeDelayMs);
                upgradeTimer.restart();
            }
        }
    }
    property var _pendingUpgrade: null
    Timer {
        id: upgradeTimer
        onTriggered: {
            const up = root._pendingUpgrade;
            root._pendingUpgrade = null;
            if (!up) return;
            vm.upgradeIntro(up.id, up.intro);
            root.updated();
        }
    }
    Timer {
        id: saveTimer
        onTriggered: {
            const s = root._save;
            root._save = null;
            if (s) root.noteSaved(s.tab, s.id, true, s.key);
        }
    }
    Timer {
        id: batchTimer
        repeat: true
        onTriggered: {
            const b = root._batch;
            const done = b.done + 1;
            root._batch = { running: done < b.total, tab: b.tab, done: done, total: b.total, blocked: false, lastError: "" };
            if (done >= b.total) {
                batchTimer.stop();
                const pad = Object.assign({}, vm.unseenPad);
                pad[b.tab] = (pad[b.tab] || 0) + 28;
                vm.unseenPad = pad;
                root.batchFinished(b.tab, 28, 2);
                root.updated();
            }
        }
    }

    // A link that has no page of its own in live/: the one canned answer.
    function _canned(f) {
        const title = f.target || "Linked article";
        const text = title + " is the subject of the page behind the link you followed, shown here as the "
            + "mock's canned answer: the first paragraph of the article, cleaned of pronunciations, "
            + "citations and parenthetical asides, and about a hundred words long so that the card has the "
            + "height a real one has. A real page would begin by saying what its subject is, then give "
            + "the one detail that makes it worth reading, and end at the end of the paragraph. This "
            + "sentence pads it to the length of a real lead. It has no images of its own, so the card "
            + "shows its veil.";
        return {
            v: 1, id: "en.wikipedia.org/" + title.replace(/ /g, "_"), tab: f.tab, kind: "article",
            source: { wiki: "wikipedia", host: "en.wikipedia.org", title: title, url: f.url, revid: 1,
                      license: "CC BY-SA 4.0", quality: null },
            title: title,
            category: { family: f.family, topic: f.topic, via: "follow", why: null },
            intro: { text: text, words: text.split(/\s+/).length, provenance: "cleaned",
                     stripped: ["pronunciation", "citations"], model: null, grounded: null, locator: null, links: [] },
            images: [], installed: null, popularity: null, judge: null, batch: "", fetchedAt: root.nowMs
        };
    }

    Component.onCompleted: {
        vm.ingestIndex(indexFile.text());
        vm.ingestDaily(dailyFile.text());
        root._ready = true;
        root._apply(root.scenario);
    }
}
