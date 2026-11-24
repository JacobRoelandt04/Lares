pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "UpdateGroups.js" as Groups
import "../../../common/components"

// Favorites JSON shape ($XDG_STATE_HOME/lares/system-update/favorites.json: shell state, never the repo; it was
// $XDG_CONFIG_HOME/quickshell/system_update_favorites.json until 2026-11-23, moved from there once -- favoritesLegacyPath):
//   { "favorites": ["hyprland-git", "linux-zen", "firefox", ...] }
// Names match exactly. The file, its watcher and its writes are
// FavoritesStore's (the launcher keeps its own file through the same one).

// =============================================================================
// AvailableUpdatesService.qml
//
// Headless poller for outstanding system updates. Wraps three commands:
//   - `checkupdates`              → official-repo updates (pacman-contrib)
//   - `yay -Qua --aur`            → AUR updates
//   - `flatpak remote-ls --updates --columns=application,branch`
//                                 → flatpak updates (skipped if not installed)
//
// All three run in parallel on `refresh()`. Output is normalised into a single
// ListModel of `{name, oldVer, newVer, source, isAur, isFlatpak}`
// rows so a popup can render them grouped or filtered.
//
// Non-visual by design. Drop into any scene, call `refresh()`, bind `updates`
// / `totalCount` / `refreshing` / `lastRefreshAtMs`. Host modules drive the cadence:
// `pollIntervalMs` > 0 polls one interval after each check ENDS (whoever started it), and a
// check already out is joined by refresh(), never doubled.
//
// "Interesting" tagging is a hardcoded patternlist (kernels, Hyprland stack,
// graphics, Qt/KDE, browsers, system core). It's a hint for the UI to surface
// noteworthy upgrades, not a security classification — adjust freely.
// =============================================================================
Item {
    id: root

    // ---- Public state ----
    ListModel { id: _updates }
    property alias updates: _updates

    property int officialCount: 0
    property int nonOfficialCount: 0
    property int totalCount: 0
    // What the bar glyph's STATUS counts: every package group (the popup's own, UpdateGroups.js)
    // once, every other package once. `totalCount` stays the real number of packages -- the
    // popup, the lockscreen and the nudge say that one (one qemu update
    // is a hundred packages and no reason for level 2).
    property int statusCount: 0

    // ---- Category registry -------------------------------------------------
    // A "category" is the finest-grained bucket the UI groups by. Official
    // repos are split apart (core / extra / multilib) rather than lumped into
    // one "Official" list, because that is how pacman and yay present them and
    // it is the distinction the user actually reasons about.
    //
    // `official` drives the official vs non-official headline breakdown, so
    // adding a future source (snap, pip, cargo, …) is a one-line change here
    // plus a colour in the UI — no other logic needs to know about it.
    //
    // Repos not listed here (a user's custom repo, testing, a kde-unstable
    // pin, …) are still handled: they get a category of their own, keyed by
    // the repo name, ranked after the known official repos, and counted as
    // official.
    readonly property var categoryOrder: ["core", "extra", "multilib", "aur", "flatpak"]
    readonly property var categoryMeta: ({
        core:     {label: "Core",     official: true},
        extra:    {label: "Extra",    official: true},
        multilib: {label: "Multilib", official: true},
        aur:      {label: "AUR",      official: false},
        flatpak:  {label: "Flatpak",  official: false}
    })

    // Live, ordered category list for the UI to bind to. Each entry is
    // `{key, label, official, count}`. Recomputed whenever the model
    // or the favourites set changes, so a view can bind straight to it without
    // walking `updates` itself.
    property var categories: []

    function _sameCategoryList(a, b) {
        if (!a || !b || a.length !== b.length) return false;
        for (let i = 0; i < a.length; i++) {
            if (a[i].key !== b[i].key) return false;
            if (a[i].count !== b[i].count) return false;
            if (a[i].label !== b[i].label) return false;
            if (a[i].official !== b[i].official) return false;
        }
        return true;
    }

    function categoryIsOfficial(key) {
        const m = root.categoryMeta[key];
        return m ? m.official : true;      // unknown repo => official
    }
    function categoryLabel(key) {
        const m = root.categoryMeta[key];
        if (m) return m.label;
        return key.charAt(0).toUpperCase() + key.slice(1);
    }
    // Sort rank: known categories in registry order, unknown official repos
    // slotted just after the known official ones, ahead of AUR/flatpak.
    function categoryRank(key) {
        const i = root.categoryOrder.indexOf(key);
        if (i >= 0) return i;
        return root.categoryOrder.indexOf("aur") - 0.5;   // unknown repo
    }
    property bool refreshing: false
    property string lastError: ""
    // The sources ("official", "aur", "flatpak") whose probe failed in the last check, in the order
    // they reported. A fresh array each time (a plain `_failedSources` object notifies nobody).
    property var failedSourceList: []
    property double lastRefreshAtMs: 0

    // A check began (never for one that joined a check already out)
    signal refreshStarted()
    signal refreshFinished(int count)
    signal refreshFailed(string source, string err)

    // ---- Result cache -----------------------------------------------------
    // The last successful result is persisted and reloaded at startup, so a
    // host can show the previous list the instant it opens instead of an empty
    // "Checking for updates…" panel. A user opens the popup BECAUSE the bar
    // already told them updates exist; making them wait for a fresh check to
    // see anything defeats the purpose. The refresh then runs in the
    // background and swaps the list when it lands.
    //
    // `lastRefreshAtMs` is restored with it, so the UI can honestly say how
    // old the displayed data is.
    property bool cacheEnabled: true
    property string cachePath:
        (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache"))
        + "/lares/available_updates.json"

    // ---- Mock mode ---------------------------------------------------------
    // Generates a synthetic update set instead of shelling out. Deliberately
    // fed through the SAME _appendRow / _commitStaged / _recomputeCategories
    // path the real probes use, so categorisation, ordering, favourites and
    // counts behave identically — a separate mock implementation would be free
    // to drift from the real one, which is the whole failure mode this is
    // meant to avoid.
    //
    // Sizes are chosen to exercise the list machinery: one category far larger
    // than any viewport (stagger capping, collapse-from-off-screen), a couple
    // of mid-size ones, and small ones that fit entirely on screen.
    property bool mockMode: false
    property var mockSpec: ({ core: 9, extra: 180, multilib: 14, aur: 6, flatpak: 5 })

    readonly property var _mockNames: ({
        core: ["linux", "linux-headers", "linux-lts", "systemd", "glibc", "pacman",
               "openssl", "coreutils", "iproute2", "e2fsprogs", "shadow", "tar"],
        extra: ["qt6-base", "qt6-declarative", "kf6-kio", "plasma-desktop", "mesa",
                "vulkan-icd-loader", "ffmpeg", "gstreamer", "python", "python-requests",
                "nodejs", "npm", "rust", "gcc", "llvm", "clang", "firefox", "chromium",
                "thunderbird", "libreoffice-fresh", "gimp", "inkscape", "blender",
                "krita", "vlc", "mpv", "obs-studio", "audacity", "pipewire",
                "wireplumber", "hyprland", "waybar", "kitty", "alacritty", "neovim",
                "git", "docker", "podman", "kubectl", "helm", "terraform", "ansible",
                "postgresql", "mariadb", "redis", "nginx", "sqlite", "curl", "wget",
                "openssh", "gnupg", "imagemagick", "ghostscript", "poppler", "cairo",
                "pango", "harfbuzz", "freetype2", "fontconfig", "noto-fonts"],
        multilib: ["lib32-mesa", "lib32-vulkan-intel", "lib32-glibc", "lib32-gcc-libs",
                   "lib32-alsa-lib", "lib32-libpulse", "lib32-openssl", "lib32-curl",
                   "lib32-fontconfig", "lib32-freetype2", "lib32-libx11", "lib32-zlib"],
        aur: ["visual-studio-code-bin", "zen-browser-bin", "docker-desktop",
              "postman-bin", "vesktop-bin", "antigravity-cli", "spotify",
              "google-chrome", "slack-desktop", "zoom"],
        flatpak: ["org.signal.Signal", "com.discordapp.Discord", "org.gimp.GIMP",
                  "md.obsidian.Obsidian", "com.spotify.Client", "org.blender.Blender"]
    })

    // Deterministic pseudo-version so a package looks the same across reloads.
    function _mockVersion(seed, bump) {
        const a = 1 + (seed * 7) % 9;
        const b = (seed * 13) % 20;
        const c = 1 + (seed * 3) % 5;
        return a + "." + (b + (bump ? 1 : 0)) + "." + c + "-" + (1 + seed % 3);
    }

    function _runMock() {
        root._pendingSources += 1;
        const spec = root.mockSpec;
        for (const key in spec) {
            const want = spec[key];
            const pool = root._mockNames[key] || [];
            for (let i = 0; i < want; i++) {
                // Reuse the pool cyclically, suffixing repeats so names stay
                // unique and sort sensibly.
                const base = pool.length > 0 ? pool[i % pool.length] : (key + "-pkg");
                const name = i < pool.length ? base : base + "-" + Math.floor(i / pool.length);
                _appendRow(name, root._mockVersion(i + key.length, false),
                           root._mockVersion(i + key.length, true), key);
            }
        }
        // Land asynchronously like a real probe, so the UI exercises its
        // "checking" state rather than being handed everything synchronously.
        _mockTimer.restart();
    }
    Timer {
        id: _mockTimer
        interval: 180
        repeat: false
        onTriggered: root._finishSource("mock", 0, "")
    }

    // ---- Optional polling -------------------------------------------------
    // Off by default: the popup mockup drives refresh() itself. The bar module
    // sets this (≈15 min) and additionally calls refresh() when the popup
    // opens. Kept here rather than in the host so every consumer gets the same
    // cadence semantics for free.
    //
    // THE NEXT POLL IS ONE INTERVAL AFTER THE LAST CHECK ENDED, WHOEVER STARTED IT.
    // A timer running free has its own phase: a popup that opened a check at minute 14 would see
    // the poll's own check a minute later, and the skeleton twice. So every check that ends -- the
    // poll's, a popup's, a run's, the notifier's -- re-arms the one single-shot, and none runs
    // while a check is out (refresh() joins one in flight).
    property int pollIntervalMs: 0
    // system_update.jsonc check.official / aur / flatpak: a source that is off is never asked and lists nothing.
    property bool officialEnabled: true
    property bool aurEnabled: true
    property bool flatpakEnabled: true
    // list.groupMin: this many packages of one category with a common prefix are one group (the icon's count counts it once); 0 = none.
    property int groupMin: 3
    // The shortest poll. A probe lowers it; a host never needs to.
    property int pollFloorMs: 60000
    function _armPoll() {
        if (root.pollIntervalMs > 0 && !root.refreshing)
            _pollTimer.restart();
        else
            _pollTimer.stop();
    }
    onRefreshingChanged: root._armPoll()
    onPollIntervalMsChanged: root._armPoll()
    Component.onCompleted: root._armPoll()
    Timer {
        id: _pollTimer
        interval: Math.max(root.pollFloorMs, root.pollIntervalMs)
        repeat: false
        onTriggered: root.refresh()
    }

    FileView {
        id: _cacheFile
        path: root.cachePath
        preload: true
        printErrors: false
        onLoaded: root._loadCache(text())
    }

    function _loadCache(txt) {
        if (!root.cacheEnabled || root.mockMode) return;
        // Never let a restore clobber live data.
        if (root.refreshing || _updates.count > 0) return;
        if (!txt || txt.length === 0) return;
        try {
            const obj = JSON.parse(txt);
            if (!Array.isArray(obj.rows)) return;
            for (const r of obj.rows) {
                if (!r || !r.name) continue;
                _appendRow(r.name, r.oldVer || "", r.newVer || "",
                           r.category || "unknown");
            }
            root.lastRefreshAtMs = obj.savedAtMs || 0;
            // The cache stores the order that was correct WHEN IT WAS SAVED.
            // Favourites can have changed since (they live in their own file,
            // and the two FileViews load in an unspecified order), so re-sort
            // against the favourites currently in effect. The favourites
            // loading later is the opposite order: the store's favoriteChanged
            // fires for every key it brings, and each one is placed.
            root._reorder();
            root._recomputeCategories();
        } catch (e) {
            // Corrupt cache is not worth surfacing — the refresh will replace
            // it either way.
        }
    }

    function _writeCache() {
        // Mock data must never reach the cache: it would be restored on the
        // next real start and look like genuine pending updates.
        if (root.mockMode) return;
        if (!root.cacheEnabled || _cacheProc.running) return;
        const rows = [];
        for (let i = 0; i < _updates.count; i++) {
            const r = _updates.get(i);
            rows.push({name: r.name, oldVer: r.oldVer, newVer: r.newVer,
                       category: r.category || r.source});
        }
        const json = JSON.stringify({savedAtMs: Date.now(), rows: rows}) + "\n";
        _cacheProc.stdinEnabled = true;
        _cacheProc.command = ["sh", "-c",
            "mkdir -p \"$(dirname \"$1\")\" && cat > \"$1.tmp\" && mv -f \"$1.tmp\" \"$1\"",
            "sh", root.cachePath];
        _cacheProc.running = true;
        _cacheProc.write(json);
        _cacheProc.stdinEnabled = false;
    }
    Process { id: _cacheProc; running: false; stdinEnabled: true }

    // ---- Favorites ----
    property string favoritesPath: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
        + "/lares/system-update/favorites.json"
    property string favoritesLegacyPath: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config"))
        + "/quickshell/system_update_favorites.json"
    readonly property alias favorites: _fav.favorites   // string list of package names

    // Every change of a key -- a toggle here, or the file loaded or edited
    // elsewhere -- places that one row. A load that lands after the rows
    // (the two files load in an unspecified order) is a change of every key
    // it brings, so the rows built before it are marked and moved too.
    FavoritesStore {
        id: _fav
        path: root.favoritesPath
        legacyPath: root.favoritesLegacyPath
        onFavoriteChanged: (key, favorite) => root._markAndReposition(key, favorite)
    }

    function isFavorite(name) { return _fav.isFavorite(name); }
    function addFavorite(name) { _fav.add(name); }
    function removeFavorite(name) { _fav.remove(name); }
    function toggleFavorite(name) { _fav.toggle(name); }

    // Incremental update: flip isFavorite on the row, recompute its sorted
    // position, and move() the row there. Avoids the clear+append churn of
    // full _reorder so toggle is instant even with 200+ packages on screen.
    function _markAndReposition(name, isFav) {
        let srcIdx = -1;
        for (let i = 0; i < _updates.count; i++) {
            if (_updates.get(i).name === name) { srcIdx = i; break; }
        }
        if (srcIdx < 0) return;
        _updates.setProperty(srcIdx, "isFavorite", isFav);
        const dest = _sortedDestFor(srcIdx);
        if (dest !== srcIdx) _updates.move(srcIdx, dest, 1);
        root._recomputeCategories();
    }

    // Compute where `_updates.get(srcIdx)` should sit under the
    // source → favorite → alphabetical order, ignoring its current slot.
    function _sortedDestFor(srcIdx) {
        const target = _updates.get(srcIdx);
        const tRank = root.categoryRank(target.category || target.source);
        // Walk the others in their current order and count how many would
        // sort before `target`. That count IS the destination index.
        let dest = 0;
        for (let i = 0; i < _updates.count; i++) {
            if (i === srcIdx) continue;
            const o = _updates.get(i);
            const oRank = root.categoryRank(o.category || o.source);
            if (oRank < tRank) { dest += 1; continue; }
            if (oRank > tRank) break;
            // Same source: favorites first, then alphabetical
            if (o.isFavorite && !target.isFavorite) { dest += 1; continue; }
            if (!o.isFavorite && target.isFavorite) break;
            if (o.name.localeCompare(target.name) < 0) { dest += 1; continue; }
            break;
        }
        return dest;
    }

    onMockModeChanged: {
        // Swap the dataset immediately so the toggle feels instant.
        _updates.clear();
        root.refresh();
    }


    // ---- Public API ----
    function refresh() {
        if (root.refreshing) return;
        root.refreshing = true;
        root.refreshStarted();
        root.lastError = "";
        // NOTE: the model is deliberately NOT cleared here. Whatever is on
        // screen (cached or from the previous check) stays until the new
        // results are ready, so opening the popup never shows an empty list
        // while a check runs. _ingestDone swaps the contents atomically.
        root._pendingRows = [];
        root._staging = true;
        root._pendingSources = 0;
        root._failedSources = ({});
        root.failedSourceList = [];
        if (root.mockMode) {
            root._runMock();
            return;
        }
        if (root.officialEnabled)
            root._runOfficial();
        if (root.aurEnabled)
            root._runAur();
        if (root.flatpakEnabled)
            root._runFlatpak();
        // every source switched off (system_update.jsonc check): a check that finds nothing, at once
        if (root._pendingSources === 0) {
            root._pendingSources = 1;
            Qt.callLater(() => root._finishSource("", 0, ""));
        }
    }

    // ---- Internals ----
    property int _pendingSources: 0

    // Sources whose probe FAILED, as opposed to reporting nothing to update.
    //
    // Telling those two apart is the whole point. A failed probe produces the
    // same empty stdout as a clean "no updates", and treating it as the latter
    // would silently drop the AUR category — then write that empty result
    // to the cache, so it would stay missing until a later refresh happened to
    // succeed.
    property var _failedSources: ({})

    // Empty output ALONE is not failure: it is the correct answer when there
    // is nothing to update. Both checkupdates and yay exit non-zero in that
    // case too, so an exit code alone is not enough either. Failure is the
    // combination — nothing on stdout, a non-zero exit, AND something on
    // stderr to say why.
    function _probeFailed(stdoutText, stderrText, code) {
        if ((stdoutText || "").trim().length > 0) return false;
        if (code === 0) return false;
        return (stderrText || "").trim().length > 0;
    }

    function _runOfficial() {
        root._pendingSources += 1;
        // `checkupdates` reports "name old -> new" with no repo, but the UI
        // groups by repo. Join it against `pacman -Sl` (repo name version)
        // in one awk pass so we still spend exactly one process on this and
        // emit "repo name old new" directly. Packages whose repo cannot be
        // resolved (dropped from the repos since the last sync) fall back to
        // the "extra" bucket's neighbour: an explicit "unknown" category, so
        // they stay visible instead of silently vanishing.
        _officialProc.command = ["bash", "-lc",
            "set -o pipefail; checkupdates | awk 'NR==FNR{repo[$2]=$1; next}"
            + " {print (($1 in repo)?repo[$1]:\"unknown\"), $1, $2, $4}'"
            + " <(pacman -Sl 2>/dev/null) -"];
        _officialProc.running = true;
    }
    function _runAur() {
        root._pendingSources += 1;
        // stderr is NOT discarded: it is the only thing that distinguishes a
        // failed probe from a clean "nothing to update".
        _aurProc.command = ["bash", "-lc", "yay -Qua --aur"];
        _aurProc.running = true;
    }
    function _runFlatpak() {
        root._pendingSources += 1;
        _flatpakProc.command = ["bash", "-lc",
            "command -v flatpak >/dev/null && "
            + "flatpak remote-ls --updates --columns=application,branch 2>/dev/null"];
        _flatpakProc.running = true;
    }

    function _ingest(text, source) {
        const lines = (text || "").split("\n");
        let n = 0;
        for (const ln of lines) {
            const t = ln.trim();
            if (t.length === 0) continue;

            // Official form (produced by the awk join in _runOfficial):
            //   "repo name oldver newver"
            if (source === "official") {
                const om = t.match(/^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)$/);
                if (om) {
                    _appendRow(om[2], om[3], om[4], om[1]);
                    n += 1;
                }
                continue;
            }

            // yay form: "name oldver -> newver [3d12h]"
            //
            // The trailing bracketed "out of date since" age is OPTIONAL: a
            // pattern anchored with `$` immediately after the new version would
            // make yay 13's age suffix fail every line, and the whole
            // AUR category would silently disappear from the UI. Anything after
            // the new version is tolerated and ignored.
            const m = t.match(/^(\S+)\s+(\S+)\s+->\s+(\S+)(?:\s+.*)?$/);
            if (m) {
                _appendRow(m[1], m[2], m[3], source);
                n += 1;
                continue;
            }
            // flatpak form: "<app-id>\t<branch>"
            if (source === "flatpak") {
                const fm = t.match(/^(\S+)\s+(\S+)$/);
                if (fm) {
                    _appendRow(fm[1], "", fm[2], "flatpak");
                    n += 1;
                }
            }
        }
        return n;
    }

    // Single construction point for a model row, so every ingest path agrees
    // on the schema. `category` is the fine-grained bucket key (core / extra /
    // multilib / aur / flatpak / <custom repo>); `source` is a coarse alias for existing bindings.
    // During a refresh rows are STAGED rather than appended, so the list on
    // screen keeps showing the previous (or cached) results until the whole
    // check has finished. Sources land at different times; appending live
    // would show a partial list that grows in visible jumps.
    property var _pendingRows: []
    property bool _staging: false

    function _appendRow(name, oldVer, newVer, category) {
        const row = {
            name: name, oldVer: oldVer, newVer: newVer,
            category: category,
            source: category,
            official: root.categoryIsOfficial(category),
            isAur: category === "aur",
            isFlatpak: category === "flatpak",
            isFavorite: root.isFavorite(name)
        };
        if (root._staging) root._pendingRows.push(row);
        else               _updates.append(row);
    }

    // Category first (registry order), then favourites to the top of their own
    // group, then alphabetical. Favourites are pinned WITHIN their category
    // rather than hoisted into a global favourites block, so a package never
    // leaves its colour group when it is starred.
    function _rowLess(a, b) {
        const ca = root.categoryRank(a.category), cb = root.categoryRank(b.category);
        if (ca !== cb) return ca - cb;
        if (a.isFavorite !== b.isFavorite) return a.isFavorite ? -1 : 1;
        return a.name.localeCompare(b.name);
    }

    // Swap staged results in as one atomic replacement.
    function _commitStaged() {
        const all = root._pendingRows.slice();

        // A source that FAILED contributes nothing to the staged rows, and
        // swapping that in would delete everything it had reported last time.
        // Its previous rows are carried over instead, so a broken probe leaves
        // the list as it was rather than quietly emptying a whole category.
        let carried = 0;
        for (let i = 0; i < _updates.count; i++) {
            const r = _updates.get(i);
            if (!root._failedSources[r.source]) continue;
            all.push({
                name: r.name, oldVer: r.oldVer, newVer: r.newVer,
                category: r.category || r.source, source: r.source,
                official: r.official, isAur: r.isAur, isFlatpak: r.isFlatpak,
                isFavorite: root.isFavorite(r.name)
            });
            carried += 1;
        }
        if (carried > 0)
            console.warn("AvailableUpdatesService: carried " + carried
                + " row(s) from failed source(s); list left as it was");

        all.sort(root._rowLess);
        _updates.clear();
        for (const r of all) _updates.append(r);
        root._pendingRows = [];
        root._staging = false;
    }

    // Rebuild `categories` (and the headline counters) from the model.
    // Called after every refresh and after any favourite toggle.
    function _recomputeCategories() {
        const seen = {};
        const names = {};
        for (let i = 0; i < _updates.count; i++) {
            const r = _updates.get(i);
            const k = r.category || r.source || "unknown";
            if (!seen[k]) seen[k] = {key: k, count: 0};
            seen[k].count += 1;
            if (!names[k]) names[k] = [];
            names[k].push({ name: r.name });
        }
        const list = [];
        for (const k in seen) {
            list.push({
                key: k,
                label: root.categoryLabel(k),
                official: root.categoryIsOfficial(k),
                count: seen[k].count
            });
        }
        list.sort((a, b) => {
            const ra = root.categoryRank(a.key), rb = root.categoryRank(b.key);
            if (ra !== rb) return ra - rb;
            return a.key.localeCompare(b.key);
        });

        // Only publish when the STRUCTURE actually changed.
        //
        // `categories` is a plain array, so any reassignment makes the Repeater
        // bound to it tear down and rebuild every category delegate. Favourite
        // toggles do not change which categories exist or how many packages
        // they hold — only which rows are starred. Reassigning anyway would make every
        // star press destroy and recreate all the sections, wiping their row models
        // mid-animation: collapsing a list straight after favouriting something would
        // snap instantly, and the flight's destination row could vanish from
        // under it. Comparing first makes a favourite toggle a no-op here.
        if (!root._sameCategoryList(root.categories, list))
            root.categories = list;

        let off = 0, nonOff = 0;
        for (const c of list) {
            if (c.official) off += c.count; else nonOff += c.count;
        }
        root.officialCount    = off;
        root.nonOfficialCount = nonOff;
        root.totalCount       = off + nonOff;
        // A group never spans two categories in the popup, so the status is the sum of each one's.
        let status = 0;
        for (const k in names)
            status += Groups.statusCount(names[k], root.groupMin > 0 ? root.groupMin : Infinity);
        root.statusCount = status;
    }

    // Reorder _updates: favorites first (alphabetical), then non-favorites
    // grouped by source (official → aur → flatpak), each group alphabetical.
    function _reorder() {
        if (_updates.count === 0) return;
        const all = [];
        for (let i = 0; i < _updates.count; i++) {
            const r = _updates.get(i);
            all.push({
                name: r.name, oldVer: r.oldVer, newVer: r.newVer,
                category: r.category || r.source, source: r.source,
                official: r.official, isAur: r.isAur, isFlatpak: r.isFlatpak,
                isFavorite: root.isFavorite(r.name)
            });
        }
        all.sort(root._rowLess);
        _updates.clear();
        for (const r of all) _updates.append(r);
    }

    function _finishSource(source, count, errText) {
        // Per-source counts are not authoritative — one source
        // ("official") fans out into several categories — so the
        // headline numbers are recomputed from the model once every source
        // has reported in.
        if (errText && errText.length > 0) {
            root._failedSources[source] = true;
            // The first line that SAYS something. yay's stderr opens with
            // " -> 1 error occurred:" and puts the reason on the line after,
            // so taking line one would give the card a counter with no error on it.
            const lines = errText.split("\n").map(l => l.trim()).filter(l => l.length > 0);
            const said = lines.filter(l => !/^->\s*\d+\s+errors?\s+occur+ed:?$/i.test(l));
            root.lastError = source + ": " + ((said.length > 0 ? said : lines)[0] || "failed");
            root.failedSourceList = root.failedSourceList.concat([source]);
            console.warn("AvailableUpdates: " + source + " check failed: " + lines.slice(0, 4).join(" | "));
            root.refreshFailed(source, errText);
        }
        root._pendingSources -= 1;
        if (root._pendingSources <= 0) {
            root._commitStaged();
            // Re-apply favourites to the rows that just landed.
            //
            // The favourites file loads asynchronously, and `_reorder` no-ops
            // on an empty model — so whichever of the two arrives first, the
            // other misses it. Rows built before the file loaded would keep
            // isFavorite false while `isFavorite()` reports true, and the two
            // disagreeing breaks every toggle: `removeFavorite` finds
            // nothing to remove and returns without touching the model, so
            // the first click on a persisted favourite does nothing at all and
            // the flight measures a row that has not moved.
            root._reorder();
            root._recomputeCategories();
            root.refreshing = false;
            root.lastRefreshAtMs = Date.now();
            // Never cache a run in which any probe failed: the cache is what
            // the next launch trusts, and persisting a hole in it would make
            // a transient yay failure look permanent.
            let anyFailed = false;
            for (const k in root._failedSources) { anyFailed = true; break; }
            if (!anyFailed) root._writeCache();
            root.refreshFinished(root.totalCount);
        }
    }

    // checkupdates exits non-zero (2) when there are zero updates. yay too.
    // Treat any exit code as success — content is determined by stdout.
    Process {
        id: _officialProc
        running: false
        stdout: StdioCollector { id: _officialOut }
        stderr: StdioCollector { id: _officialErr }
        onExited: (code) => {
            const c = root._ingest(_officialOut.text, "official");
            // The failure text goes on only when `_probeFailed` says the probe failed: a failed
            // `checkupdates` must not look like an empty official list. checkupdates
            // exits 2 with nothing on stderr when there is nothing to do; that
            // is not a failure.
            root._finishSource("official", c,
                root._probeFailed(_officialOut.text, _officialErr.text, code) ? _officialErr.text : "");
        }
    }
    Process {
        id: _aurProc
        running: false
        stdout: StdioCollector { id: _aurOut }
        stderr: StdioCollector { id: _aurErr }
        onExited: (code) => {
            const c = root._ingest(_aurOut.text, "aur");
            root._finishSource("aur", c,
                root._probeFailed(_aurOut.text, _aurErr.text, code) ? _aurErr.text : "");
        }
    }
    Process {
        id: _flatpakProc
        running: false
        stdout: StdioCollector { id: _flatpakOut }
        stderr: StdioCollector { id: _flatpakErr }
        onExited: (code) => {
            const c = root._ingest(_flatpakOut.text, "flatpak");
            root._finishSource("flatpak", c,
                root._probeFailed(_flatpakOut.text, _flatpakErr.text, code)
                    ? _flatpakErr.text : "");
        }
    }
}
