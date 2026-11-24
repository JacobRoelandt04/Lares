pragma ComponentBehavior: Bound

import QtQuick
import "../../../common/components/Bytes.js" as Bytes
import "UpdateGroups.js" as Groups
import "../../../common/components"

// =============================================================================
// UpdateCategorySection.qml
//
// One collapsible category of available updates (Core / Extra / Multilib /
// AUR / …): a header plus a body of UpdatePackageRows that slide in from the
// left when it opens and out to the right when it closes, staggered top-down.
//
// TIMING MODEL
// ------------
// Two invariants, in priority order:
//
//   1. The speed a row travels at is ALWAYS the same. Per-row duration and
//      the gap between rows are fixed constants, never scaled by how many
//      rows there are.
//   2. Total time is bounded, because only rows that are actually ON SCREEN
//      are animated. Everything else is retired instantly.
//
// Invariant 1 is what makes the motion feel like one consistent mechanism;
// invariant 2 is what stops a 182-row category taking seven seconds to open.
// Compressing the stagger for long lists would satisfy
// (2) by breaking (1): long categories would snap and short ones amble. Worse,
// compression applied only on expand would fire all 182 rows of a collapsing Extra
// at a ~6 ms gap, and the whole list would vanish in one frame.
//
// Rows outside the viewport use the "collapsed" state: zero height, no
// animation. On collapse this is what makes the content BELOW the category
// behave. The 170 off-screen rows of Extra give up their ~6000 px instantly —
// invisible, since it all happens off-screen — which leaves the content below
// sitting just past the bottom edge, so it then slides gently into place along
// with the dozen visible rows instead of rocketing up from six screens away.
// Opening runs the same idea in reverse: off-screen rows stay flat until the
// visible wave has finished, by which point the content below has already been
// pushed past the bottom edge and cannot be seen taking up its final offset.
//
// Row height is animated by AnimatedListRow on the same clock as the slide, so
// content below tracks each arriving row rather than being displaced up front.
//
// GROUPS
// ------
// Packages that share a prefix (`python-*`, `haskell-*`, `lib32-*`) fold into ONE row
// of the list's own style -- the prefix, "+N more" under it, a chevron --, the packages
// one level in under it when it is open. UpdateGroups.js has the rule and the order. The
// group is just more rows of the same flat model, each carrying its `kind` and `depth`
// (the way the player's library nests an album under a genre), so the sync, the
// favourites at the head and the flights all go on working on one list. A group opens
// and closes with the section's own law (only what is on screen animates, the rest is
// placed): `_openGroup` / `_closeGroup`. Idle list only: a run lists what the
// transaction does, package by package, and that is a flat list.
//
// PERFORMANCE
// -----------
// Each section keeps a private model of only its own rows. Binding every
// section to the full update list and hiding foreign rows would
// instantiate ~800 items for ~200 updates, nearly all invisible.
// =============================================================================
Item {
    id: section

    // ---- Data ----
    objectName: "updateCategorySection"
    // How many rows the model currently holds, for the state recorder.
    readonly property int rowModelRefCount: rowModel.count

    property var service: null

    // ---- Run mode ----
    //
    // Idle, the rows come from the available-updates service. During a run the
    // authoritative set is the parser's package list instead: it includes the
    // dependencies that were pulled in, which the available list never knew
    // about, and it is the only thing that carries live state.
    //
    // Live state is delivered by `runSource.packageProgress(name, state, pct)`
    // and written straight into the one row it names. Re-diffing the whole
    // category on the model's dataChanged would rebuild 212 rows on every
    // percent tick of every concurrent download.
    property bool runMode: false
    // Pre-download: run rows still carry the favourite flag from the idle
    // service, so a starred package stays starred (and visible in a
    // collapsed category) until the transaction actually touches it.
    // Whether the rows are still the idle list's favourites. True until the
    // run touches a package (sync, resolve, the prompts); from the first
    // working step on a favourite is an ORDINARY row, retired when it is
    // through and gone when its header shuts. Pinning them past that point would
    // leave rows in the list that nothing could take out.
    property bool keepFavorites: false
    // "done / total" only once the step is one where a package can be done.
    property bool showStepCounts: true
    property var runModel: null      // parser.packages
    property var runSource: null     // the parser itself, for packageProgress

    // ---- Groups ----
    property bool groupsEnabled: true
    // The fewest packages of one prefix that make a group.
    property int groupMin: 3
    // { prefix: true } for the groups the user has open in THIS category. Lives on the host,
    // so it survives a rebuild of the sections.
    property var expandedGroups: ({})
    // How far a group's packages step in (pre-scale px).
    property real groupIndent: 14
    // The group row asks to open / shut (the host keeps the state).
    signal groupToggleRequested(string groupKey, bool open)
    // A right click on a header: these packages become (or stop being) favourites.
    signal groupFavoriteRequested(string groupKey, var names, bool favorite)
    readonly property bool _grouping: section.groupsEnabled && !section.runMode

    property string categoryKey: ""
    property string label: ""
    property int count: 0
    property color accentColor: "#4480F4"

    // ---- Styling passthrough ----
    property color textColor:  "#5D5D5F"
    property color mutedColor: "#8A8A8C"
    property color faintColor: "#B8BBC2"
    property string fontFamily: "Inter"
    property var iconResolver: null
    // The step-status resolver, passed straight to the rows so
    // the vocabulary lives in exactly one place.
    // ---- Section flight ----
    // The header is what flies when a category changes its place in the list,
    // so the host needs to reach it; the section's top-left IS the header's
    // top-left, which is why no half-gap correction is needed at either end.
    readonly property alias headerItem: header
    // Hidden, not removed: it is still the destination the ghost lands on, and
    // its properties are what the ghost is drawn from.
    property bool headerSuppressed: false
    // Set while the section's Layout cell is being shrunk under it -- a cell
    // smaller than its children does not clip them on its own.
    property bool flightClip: false
    // Rows on screen for this category right now, favourites included.
    readonly property int rowCount: rowModel.count
    // The section is giving up EVERY row -- favourites too -- because a
    // flight is about to carry its header somewhere else. A favourite left
    // behind is the one row that still teleports, and it is also what makes
    // the space a flight has to reserve a row taller than the header that
    // lands in it. Cleared by refillAfterFlight().
    property bool flightEmptying: false
    // Give up every row, on the list's own leave wave, and report
    // `transitionFinished` when the last one has gone -- exactly as a collapse
    // does, because it IS one.
    function emptyForFlight() {
        if (section.flightEmptying) return;
        section.flightEmptying = true;
        section._close();
    }
    // And bring them back where the section has landed. `_open()` is right for
    // a shut category too: it fills from `_targetRows`, which gives a shut one
    // its favourites and nothing else.
    function refillAfterFlight() {
        if (!section.flightEmptying) return;
        section.flightEmptying = false;
        section._open();
    }

    // Which run step the marks and the header count describe.
    property string runStepKey: ""
    // Bumped by the host when the SAME step starts over on the same rows --
    // the AUR half, whose built packages become pending again the moment
    // pacman is told to install them. A step key change already does this;
    // this is the same reset without a new key, because the rail must not
    // step backwards for it.
    property int stepPass: 0
    // The single package being worked on right now, and what it is doing.
    // Used for the steps that HAVE a single focus — install, and AUR build —
    // where the detail is a global rather than a per-package field.
    property string activePackage: ""
    property string activeDetail: ""
    // Show yay's menu numbers on the rows (only meaningful at its numbered
    // prompts).
    property bool showNumbers: false
    // Point at this category: it is one of the ones a pending question covers.
    property bool highlighted: false
    // The topmost section shares the list container's corner, so its box can
    // nest into that curve instead of sitting squarely inside it.
    property bool firstInList: false
    property real containerRadius: 10
    // Rows are inset from the container's edges; headers are not. Passing the
    // inset down here rather than applying it to the scrolling viewport is
    // what lets a header's box meet those edges.
    property real rowInset: 0

    // ---- Header inset styling, passed straight through -------------------
    // Defaults = SystemUpdatePopup's (the tuned values), for a host that sets none.
    property real headerBoxPadding: 11
    property real headerBoxPaddingV: 8
    property real headerIdleWidthPx: 12
    property real headerIdleFeatherPx: 12
    property real headerActiveFeatherPx: 12
    property real headerIdleWidth: 7.5
    property real headerActiveWidth: 7
    property real headerIdleEdgeAlpha: 0.55
    property real headerActiveEdgeAlpha: 1.0
    property real headerIdleFalloff: 0.9
    property real headerActiveFalloff: 1.0
    property real headerProgressBlendEnd: 0.32
    // function(rawState) -> "pending" | "active" | "done" | "failed"
    property var stepStatusFor: null

    // This category's standing in the CURRENT step.
    //
    // Counted from the SOURCE model, not from `rowModel`. A collapsed category
    // holds only its favourites in the row model — none, during a run — so
    // counting there would report a total of 0 the moment you collapse it.
    property int stepDone: 0
    // The step has touched a package of this category (one is active, done
    // or failed); before that the header shows plain totals.
    property bool stepStarted: false
    property int stepTotal: 0
    // Bytes, for the download step: how much of this category has come
    // down, how much there is, the summed rate of its active transfers and
    // the time that implies. The parser only knows the run's totals; the
    // category's are summed here from its own rows.
    property real stepBytesDone: 0
    property real stepBytesTotal: 0
    property real stepRateBps: 0
    property int  stepEtaSec: -1
    // Slice of the bar held back until the LAST package is through. Bytes
    // shape the bar, but bytes cannot show a 40 KiB straggler behind 700 MiB:
    // extra would sit at "148 / 149" with a full bar for 18 seconds. The held
    // slice fills with that last package's own progress, so its finish is
    // a visible step rather than nothing.
    property real tailHold: 0.08
    property int stepFailed: 0

    // Fraction of this category's WORK complete, weighted by download size
    // rather than by package count.
    //
    // Counting packages puts the bar at 99% while a single 8 GiB package is
    // still coming down, which is the opposite of what a progress bar is for.
    // Weighting by bytes means the bar tracks the data actually moved. Where
    // no size is known — the mock, or a run whose table was never parsed —
    // every package weighs 1 and it degrades to the package count.
    property real stepFraction: 0

    function _recountStep() {
        if (!section.runMode || !section.stepStatusFor || !section.runModel) {
            section.stepDone = 0; section.stepTotal = 0;
            section.stepFailed = 0; section.stepFraction = 0;
            section.stepBytesDone = 0; section.stepBytesTotal = 0;
            section.stepRateBps = 0; section.stepEtaSec = -1;
            return;
        }
        const m = section.runModel;
        let d = 0, f = 0, n = 0, wSum = 0, wDone = 0, active = 0;
        let bytesDone = 0, bytesTotal = 0, rate = 0, lastPct = 0;
        // Two steps carry bytes: pacman's download (official rows) and the
        // AUR source fetch (AUR rows, curl's figures). Each counts only the
        // rows it moves; counting the others would show a category as done --
        // or as pending -- for a step it takes no part in.
        const dl = section.runStepKey === "download" || section.runStepKey === "sources";
        const sources = section.runStepKey === "sources";
        // ALL BY BYTES OR ALL BY COUNT, never a mix. A row's size is not
        // known until something has told us -- pacman's table for the
        // download step, curl's first meter row for the AUR sources -- and a
        // row with no size weighs 1 byte. During the source fetch that means
        // the DENOMINATOR grows as each package starts: with docker-desktop's
        // 661.6 MiB source entering a sum of eight one-byte weights, the bar
        // would fall from 23% to 0.9% in one tick. If any row in this step is still
        // unmeasured, every row weighs 1 and the bar is the package count --
        // which is exactly what it degrades to anyway.
        let allSized = true;
        for (let i = 0; i < m.count; i++) {
            const r = m.get(i);
            if (section._runCategory(r) !== section.categoryKey) continue;
            if (section.runStepKey === "download" && r.isAur) continue;
            if (sources && !r.isAur) continue;
            if (!(r.dlBytes > 0)) { allSized = false; break; }
        }
        for (let i = 0; i < m.count; i++) {
            const r = m.get(i);
            if (section._runCategory(r) !== section.categoryKey) continue;
            if (section.runStepKey === "download" && r.isAur) continue;
            if (sources && !r.isAur) continue;
            n++;
            const st = section.stepStatusFor(r.state || "", !!r.isAur);
            if (st === "done") d++;
            else if (st === "failed") f++;
            else if (st === "active") active++;

            const w = allSized ? r.dlBytes : 1;
            const pct = Math.max(0, Math.min(1, (r.dlPct || 0) / 100));
            wSum += w;
            // Only the download step reports sub-package progress; install and
            // build are all-or-nothing per package because that is all pacman
            // and makepkg tell us.
            if (st === "done") wDone += w;
            else if (dl && st === "active") { wDone += w * pct; lastPct = pct; }

            if (dl) {
                const total = r.dlBytes > 0 ? r.dlBytes : 0;
                bytesTotal += total;
                if (st === "done") bytesDone += total;
                else if (st === "active") {
                    bytesDone += r.dlSoFarBytes > 0 ? Math.min(r.dlSoFarBytes, total) : total * pct;
                    rate += Bytes.parseRate(r.dlRate || "");
                }
            }
        }
        section.stepDone = d;
        section.stepTotal = n;
        section.stepFailed = f;
        section.stepStarted = d + f + active > 0;
        // The bar: bytes, less the held slice, which only the last package
        // can fill -- with its own progress while it is the one downloading.
        const byteFrac = wSum > 0 ? wDone / wSum : 0;
        const remaining = n - d - f;
        let frac;
        if (n === 0) frac = 0;
        else if (remaining <= 0) frac = 1;
        else if (remaining === 1) frac = byteFrac * (1 - section.tailHold) + section.tailHold * lastPct;
        else frac = byteFrac * (1 - section.tailHold);
        section.stepFraction = Math.max(0, Math.min(1, frac));
        section.stepBytesDone = bytesDone;
        section.stepBytesTotal = bytesTotal;
        section.stepRateBps = rate;
        section.stepEtaSec = (dl && rate > 0 && bytesTotal > bytesDone)
            ? Math.ceil((bytesTotal - bytesDone) / rate) : -1;
    }

    // THROTTLED, not debounced.
    //
    // A live download fires a progress event per package per percent, and each
    // recount is a pass over the whole transaction — so it must not run per
    // event. But restarting on every event would starve it completely: the stream
    // never pauses long enough for it to fire, so the header would sit at 0 for the
    // whole phase and snap to 1 when the phase ended. Starting it only when
    // it is not already running gives a recount every interval while events
    // flow, which is what a progress bar needs.
    Timer {
        id: stepCountTimer
        interval: 120
        repeat: false
        onTriggered: section._recountStep()
    }
    function _scheduleStepCount() {
        if (!stepCountTimer.running) stepCountTimer.start();
    }
    // A new step brings every package back: it is pending again for whatever
    // the step is, so the list refills and reopens.
    //
    // `_doneAt` and `_refilled` are the two latches that keep a drained row
    // OUT of the list for good, so a reset that does not clear both leaves
    // the section empty however the package states are rewritten.
    function _beginStepPass() {
        section._doneAt = ({});
        section._refilled = false;
        section._recountStep();
        section._scheduleSync();
        if (section._retiringStep) doneExitTimer.start();
    }
    onRunStepKeyChanged: section._beginStepPass()
    onStepPassChanged: section._beginStepPass()
    // Uniform density control for the whole list. Row heights are MEASURED
    // rather than assumed, so the viewport range and stagger maths follow the
    // scale automatically; only the pre-measurement fallback needs scaling.
    property real listScale: 1.0
    // For a narrow list (the verbose view's side panel): the header puts its
    // count beside the title and gives the download figures a line of their
    // own, and the rows shrink their figures -- see ListSectionHeader and
    // UpdatePackageRow.
    property bool compactLayout: false
    // The header box's corner radius (pre-scale); the host hands over the
    // list container's so the two curves coincide at the top.
    property real headerBoxRadius: 10
    // The header box's colours: fill, what it stands on, highlight, inset
    // shadow. Handed through from the host's palette.
    property color headerBoxColor:        "#DCDFE6"
    property color headerBoxSurfaceColor: "#EAEDF5"
    property color headerBoxBevelColor:   "#EEF0F7"
    property color headerBoxShadowColor:  "#AAADB4"

    // The header's download figures, for this category alone. Only the
    // download step has any; everything else leaves them empty.
    readonly property bool _showDlDetail:
        section.runMode && section.showStepCounts
        && (section.runStepKey === "download" || section.runStepKey === "sources")
        && section.stepBytesTotal > 0

    // ---- Behaviour ----
    property bool expanded: false
    property int  animDuration: 240
    property int  staggerMs: 34

    // The Flickable this section lives in. Used to work out which rows are on
    // screen; without it the section falls back to `fallbackWaveRows`.
    property Item viewport: null
    property int  fallbackWaveRows: 12
    // Starting estimate of a collapsed row's height; replaced by a real
    // measurement as soon as one row exists.
    property real rowHeightHint: 42
    readonly property real _scaledHint: rowHeightHint * Math.max(0.2, listScale)
    property real _measuredRowH: 0
    readonly property real _rowH: _measuredRowH > 8 ? _measuredRowH : _scaledHint

    property string suppressedRow: ""
    // How far open the suppressed row's space is, 0..1.
    property real suppressedReveal: 1

    // ---- Flight gap -------------------------------------------------------
    //
    // A favourited row moves in the model the instant the toggle lands, so the
    // slot it came from closes immediately while the slot it is going to opens
    // immediately — two jumps, and the clone flies between two things that
    // have already finished moving.
    //
    // A phantom is left behind at the old index instead. It carries exactly
    // the height the destination has not yet taken, so `phantom + destination`
    // is constant: the gap does not close until the new one opens, and the
    // list shifts by the difference rather than twice.
    property int _phantomIndex: -1
    readonly property real _phantomReveal: 1 - section.suppressedReveal

    // True while a clone is in flight over this section.
    property bool flightPending: false

    function beginFlightGap(name) {
        section.flightPending = true;
        // Captured BEFORE the model moves, which is the only moment the old
        // index still exists.
        section._phantomIndex = section._indexOfRow(name, 0);
        if (section._phantomIndex >= 0)
            rowModel.insert(section._phantomIndex,
                            {name: "", oldVer: "", newVer: "", isFavorite: false,
                             rowState: "rest", staggerIdx: 0, runState: "",
                             dlPct: 0, dlRate: "", dlEta: "", isPhantom: true,
                             kind: "pkg", groupKey: "", depth: 0, groupCount: 0,
                             groupFav: false, groupOpen: false, dropping: false});
    }
    // Where a row will COME TO REST, computed from the model rather than
    // measured off the item.
    //
    // Measuring is unusable here: the destination row's own position animates
    // toward its new slot at exactly the moment the flight needs to know where
    // it is going, so a sample at any delay reads a moving target. Measured
    // 32ms after the reconcile, the destination sits 3px from the source when
    // the true distance is two rows — under flightMinTravel, so the flight
    // would be cancelled and the row simply appear at the top, a teleport with no ghost.
    //
    // Summing full row heights above it is exact and immune to timing. The
    // phantom is skipped because it is about to give up all its height.
    //
    // Assumes uniform row height, as the wave maths already does; an expanded
    // row above the destination would shift this by its extra height.
    function flightDestTopIn(item, name) {
        const di = section._indexOfRow(name, 0);
        if (di < 0) return NaN;
        let y = 0;
        for (let i = 0; i < di; i++) {
            const above = rowModel.get(i);
            if (above.isPhantom) continue;
            y += section._rowH;   // a group is a row of the same pitch
        }
        // The wrapper offsets its content by half the virtual spacing, and the
        // clone is aligned to the CONTENT (that is what `_flightY` samples at
        // launch). Summing wrapper heights alone would therefore aim the clone a
        // few pixels high, which would show as a snap at the end of every landing.
        // Expressed in listScale so it holds at any density; the demo zoom is
        // a render transform and scales with everything else.
        return bodyClip.mapToItem(item, 0, 0).y + y
             + 3 * Math.max(0.2, section.listScale);
    }

    function endFlightGap() {
        section.flightPending = false;
        for (let i = rowModel.count - 1; i >= 0; i--)
            if (rowModel.get(i).isPhantom) rowModel.remove(i);
        section._phantomIndex = -1;
    }

    signal favoriteToggleRequested(string name, var rowItem)
    // A row's link glyph was clicked: the host resolves and opens the
    // package's upstream URL (see PackageUrlOpener). `isAur` picks the
    // lookup tool; it is true for anything in the AUR category even when the
    // idle row model has not carried the flag over.
    signal openUrlRequested(string name, bool isAur)
    // The package whose URL is being resolved right now ("" when none), as
    // reported by the host's PackageUrlOpener.busyName. That one row shows
    // its glyph in the busy tone.
    property string busyLink: ""
    signal toggleRequested()
    signal transitionFinished()

    readonly property bool animating: cleanupTimer.running || settleTimer.running
                                   || removeTimer.running || groupCloseTimer.running

    implicitHeight: header.implicitHeight + bodyClip.height

    ListSectionHeader {
        id: header
        width: section.width
        opacity: section.headerSuppressed ? 0 : 1
        title: section.label
        // Running, the subtitle answers "how far through THIS step is this
        // category" rather than restating a count the title already implies.
        subtitle: {
            if (section.runMode && section.showStepCounts) {
                // Everything in this category is through: say so, rather
                // than "9 / 9" -- and after the run, that is the overview.
                if (section.stepTotal > 0 && section.stepDone === section.stepTotal
                        && section.runStepKey !== "download")
                    return section.stepTotal + (section.stepTotal === 1 ? " package updated" : " packages updated")
                         + (section.stepFailed > 0 ? "  ·  " + section.stepFailed + " failed" : "");
                // Plain total until the step has touched a package here.
                if (section.runStepKey.length > 0 && section.stepTotal > 0 && section.stepStarted)
                    return section.stepDone + " / " + section.stepTotal
                         + (section.stepTotal === 1 ? " package" : " packages")
                         + (section.stepFailed > 0 ? "  ·  " + section.stepFailed + " failed" : "");
            }
            return section.count + (section.count === 1 ? " package" : " packages");
        }
        accentColor: section.accentColor
        expanded: section.expanded
        textColor: section.textColor
        mutedColor: section.mutedColor
        faintColor: section.faintColor
        fontFamily: section.fontFamily
        listScale: section.listScale
        // Byte-weighted, so a category is not reported nearly finished while
        // its single largest package is still downloading.
        progress: section.runMode && section.showStepCounts && section.runStepKey.length > 0
                  ? section.stepFraction : -1
        // Red when the step has FINISHED with a failure in it -- not from the
        // moment one happens. A category still working reads its sweep as
        // progress, and painting that red while the packages after the failed
        // one are being installed says the step failed when it is going fine.
        // The failed ROW keeps its own red mark throughout; this is the
        // category's verdict, and a verdict waits for the end.
        progressFailed: section.stepFailed > 0
                        && section.stepDone + section.stepFailed >= section.stepTotal
        // Bytes, rate and time for this category alone, during the download.
        // Before the first byte moves -- waiting at "Proceed?" -- only the
        // total: "0.0 / 11.5 MiB" says nothing "11.5 MiB" does not.
        detailBytesDone:  section._showDlDetail ? (section.stepStarted ? section.stepBytesDone : -1) : 0
        detailBytesTotal: section._showDlDetail ? section.stepBytesTotal : 0
        detailRateText:   section._showDlDetail && section.stepRateBps > 0
                          ? Bytes.formatBytes(section.stepRateBps) + "/s" : ""
        detailEtaText:    section._showDlDetail && section.stepEtaSec >= 0
                          ? Bytes.formatEta(section.stepEtaSec) : ""
        compactLayout: section.compactLayout
        boxRadius: section.headerBoxRadius
        boxColor: section.headerBoxColor
        boxSurfaceColor: section.headerBoxSurfaceColor
        boxBevelColor: section.headerBoxBevelColor
        boxShadowColor: section.headerBoxShadowColor
        firstInList: section.firstInList
        containerRadius: section.containerRadius

        boxPadding: section.headerBoxPadding
        boxPaddingV: section.headerBoxPaddingV
        idleWidthPx: section.headerIdleWidthPx
        boxIdleFeatherPx: section.headerIdleFeatherPx
        boxActiveFeatherPx: section.headerActiveFeatherPx
        boxShadowWidth: section.headerIdleWidth
        boxProgressShadowWidth: section.headerActiveWidth
        boxIdleEdgeAlpha: section.headerIdleEdgeAlpha
        boxActiveEdgeAlpha: section.headerActiveEdgeAlpha
        boxIdleFalloff: section.headerIdleFalloff
        boxActiveFalloff: section.headerActiveFalloff
        progressBlendEnd: section.headerProgressBlendEnd

        onToggled: section.toggleRequested()
    }

    Item {
        id: bodyClip
        anchors.top: header.bottom
        width: section.width
        clip: true
        height: bodyCol.implicitHeight

        Column {
            id: bodyCol
            // Inset from the container's edges. The header above is not --
            // its box is meant to touch them.
            x: section.rowInset
            width: parent.width - section.rowInset * 2
            spacing: 0     // AnimatedListRow reserves its own virtual spacing

            Repeater {
                id: rowRepeater
                model: rowModel

                delegate: AnimatedListRow {
                    id: wrap
                    required property int index
                    required property var model

                    width: bodyCol.width
                    rowState: model.rowState
                    staggerIdx: model.staggerIdx
                    animDuration: section.animDuration
                    staggerMs: section.staggerMs
                    // Scaled by the row's own reveal.
                    //
                    // The wrapper adds this on top of the row's height, so a
                    // row revealed to 0 would still occupy its spacing — about a
                    // fifth of a row, appearing and vanishing instantly at
                    // each end of a flight. Space has to close completely or
                    // not at all.
                    virtualSpacing: 6 * Math.max(0.2, section.listScale)
                                  * (wrap.model.isPhantom
                                     ? section._phantomReveal
                                     : (section.suppressedRow === wrap.model.name
                                        ? section.suppressedReveal : 1))

                    // Feed the real height back so the viewport maths uses a
                    // measurement instead of the estimate (a group row is
                    // a package row's pitch).
                    contentHeight: rowLoader.item ? rowLoader.item.implicitHeight : 0
                    onHeightChanged: section._measure(wrap, rowLoader.item)

                    // A group is a package row in the list's own style (UpdatePackageRow `isGroup`): the
                    // prefix for a name, "+N more" where the version stands, a chevron. Its stripe is the
                    // favourite mark in full when every package of the group is a favourite, drained
                    // otherwise, as a package's.
                    Component {
                        id: groupRowComponent
                        UpdatePackageRow {
                            id: groupRow
                            isGroup: true
                            entry: ({ name: wrap.model.groupKey, isFavorite: wrap.model.groupFav })
                            groupOpen: !!wrap.model.groupOpen
                            groupLine: wrap.model.groupOpen
                                       ? wrap.model.groupCount + (wrap.model.groupCount === 1 ? " package" : " packages")
                                       : "+" + wrap.model.groupCount + " more"
                            categoryColor: section.accentColor
                            textColor: section.textColor
                            mutedColor: section.mutedColor
                            faintColor: section.faintColor
                            mutedGroundColor: section.headerBoxSurfaceColor
                            fontFamily: section.fontFamily
                            listScale: section.listScale
                            iconGlyph: section.iconResolver
                                ? section.iconResolver(wrap.model.groupKey, section.categoryKey)
                                : ""
                            animDuration: section.animDuration
                            onActivated: section.groupToggleRequested(wrap.model.groupKey,
                                                                      !wrap.model.groupOpen)
                            onToggleFavoriteRequested: section._groupFavorite(wrap.model.groupKey)
                        }
                    }

                    Component {
                        id: packageRowComponent
                    UpdatePackageRow {
                        id: pkgRow
                        // A phantom is pure space: no content, and it gives up
                        // exactly what the destination row is taking.
                        visible: !wrap.model.isPhantom
                        revealFraction: wrap.model.isPhantom
                            ? section._phantomReveal
                            : (section.suppressedRow === wrap.model.name
                               ? section.suppressedReveal : 1)
                        // A package inside a group steps in by the group's indent.
                        anchors.leftMargin: wrap.model.depth * section.groupIndent
                                            * Math.max(0.2, section.listScale)
                        anchors.left: parent.left
                        anchors.right: parent.right
                        entry: wrap.model
                        categoryColor: section.accentColor
                        textColor: section.textColor
                        mutedColor: section.mutedColor
                        faintColor: section.faintColor
                        // A muted stripe is drained relative to the ground it
                        // lies on, and that ground is the list container the
                        // header boxes also stand on.
                        mutedGroundColor: section.headerBoxSurfaceColor
                        fontFamily: section.fontFamily
                        listScale: section.listScale
                        compactStats: section.compactLayout
                        sizeWhenPending: section.runStepKey === "download" || section.runStepKey === "sources"
                        iconGlyph: section.iconResolver
                            ? section.iconResolver(wrap.model.name, section.categoryKey)
                            : ""
                        stepStatusFor: section.stepStatusFor
                        showDoneLabel: section._retiringStep
                        showNumber: section.showNumbers
                        packageNumber: wrap.model.number || 0
                        activeDetail: section.activePackage === wrap.model.name
                                      ? section.activeDetail : ""
                        contentVisible: section.suppressedRow !== wrap.model.name
                        linkBusy: section.busyLink.length > 0
                                  && section.busyLink === wrap.model.name
                        onToggleFavoriteRequested:
                            section.favoriteToggleRequested(wrap.model.name, pkgRow)
                        onOpenUrlRequested:
                            section.openUrlRequested(wrap.model.name,
                                !!wrap.model.isAur || section.categoryKey === "aur")
                    }
                    }

                    Loader {
                        id: rowLoader
                        anchors.left: parent.left
                        anchors.right: parent.right
                        sourceComponent: wrap.model.kind === "group" ? groupRowComponent
                                                                     : packageRowComponent
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // Row model + choreography
    //
    // FAVOURITES ARE ALWAYS PRESENT. A collapsed category still lists its
    // favourites — that is the entire point of starring something: it stays in
    // view when the rest of the category is folded away. So the model holds
    // the favourites at all times, and expanding/collapsing only ever adds or
    // removes the NON-favourites underneath them.
    //
    // Everything that animates therefore works on the non-favourite block:
    // stagger indices are relative to it, and the on-screen range is measured
    // from where that block starts (i.e. below whatever favourites are already
    // occupying space), not from the top of the body.
    // ------------------------------------------------------------------
    ListModel { id: rowModel }


    onExpandedChanged: expanded ? _open() : _close()
    Component.onCompleted: {
        section._seenGroups = Object.assign({}, section.expandedGroups || ({}));
        section._ready = true;
        section._syncSilent();
    }

    Connections {
        target: section.runMode
            ? section.runModel
            : (section.service ? section.service.updates : null)
        ignoreUnknownSignals: true
        // Membership only. State arrives through packageProgress below, so a
        // percent tick never triggers a re-diff.
        function onCountChanged() {
            section._scheduleSync();
            if (section.runMode) section._scheduleStepCount();
        }
        function onDataChanged()  { if (!section.runMode) section._scheduleSync() }
    }

    Connections {
        target: section.runMode ? section.runSource : null
        ignoreUnknownSignals: true
        function onPackageProgress(name, state, pct, rate, eta) {
            section._applyProgress(name, state, pct, rate, eta);
        }
    }

    onRunModeChanged: { section._scheduleSync(); section._recountStep(); }

    property bool _syncQueued: false
    function _scheduleSync() {
        if (_syncQueued) return;
        _syncQueued = true;
        Qt.callLater(() => {
            section._syncQueued = false;
            // Never reshuffle mid-flight: the running wave owns the model
            // until it settles, or rows get their state rewritten mid-slide.
            //
            // A flight is the exception, and must be, because this deferral is
            // unbounded: it re-queues for as long as `animating` holds, and a
            // flight started while an expand wave is still running would therefore
            // wait for a sync that has not happened when it measures. The
            // flying row is suppressed and belongs to no wave, so reconciling
            // now cannot disturb one.
            if (section.animating && !section.flightPending) {
                section._scheduleSync();
                return;
            }
            section._syncSilent();
        });
    }

    // Which category a parser package belongs to, using the same keys the
    // service uses so both sources land in the same sections.
    function _runCategory(p) {
        if (p.isAur) return "aur";
        return p.repo && p.repo.length > 0 ? p.repo : "extra";
    }

    // All rows of this category, source order (favourites already first).
    function _sourceRows() {
        const out = [];
        if (section.runMode) {
            const m = section.runModel;
            if (!m) return out;
            const favs = {};
            if (section.keepFavorites && service && service.updates) {
                const u = service.updates;
                for (let i = 0; i < u.count; i++) {
                    const f = u.get(i);
                    if (f.isFavorite) favs[f.name] = true;
                }
            }
            for (let i = 0; i < m.count; i++) {
                const r = m.get(i);
                if (section._runCategory(r) !== section.categoryKey) continue;
                out.push({
                    name: r.name,
                    oldVer: r.oldVer || "",
                    newVer: r.newVer || "",
                    // A favourite only while the list is still the idle one
                    // (`keepFavorites`). Favourites answer "what important
                    // thing is waiting for me" when the popup opens; once the
                    // update is working the answer is "all of it", and a row
                    // pinned into a shut category is a row nothing can take
                    // out.
                    isFavorite: !!favs[r.name],
                    number: r.number || 0,
                    isAur: !!r.isAur,
                    dlBytes: r.dlBytes || 0,
                    runState: r.state || "queued",
                    dlPct: r.dlPct || 0,
                    dlRate: r.dlRate || "",
                    dlEta: r.dlEta || ""
                });
            }
            // Transaction order is dependency order, which is meaningless to
            // read. With favourites out of the picture there is nothing left
            // to rank by, so sort by name.
            out.sort((a, b) => a.name.localeCompare(b.name));
            return out;
        }
        if (!service || !service.updates) return out;
        const m = service.updates;
        for (let i = 0; i < m.count; i++) {
            const r = m.get(i);
            if ((r.category || r.source) === section.categoryKey) {
                out.push({
                    name: r.name,
                    oldVer: r.oldVer || "",
                    newVer: r.newVer || "",
                    isFavorite: !!r.isFavorite,
                    number: 0,
                    isAur: false,
                    dlBytes: 0,
                    runState: "",
                    dlPct: 0,
                    dlRate: "",
                    dlEta: ""
                });
            }
        }
        return out;
    }

    function _rowEntry(r, state, stagger) {
        return {
            name: r.name, oldVer: r.oldVer, newVer: r.newVer,
            isFavorite: r.isFavorite, rowState: state, staggerIdx: stagger,
            runState: r.runState || "", dlPct: r.dlPct || 0,
            dlRate: r.dlRate || "", dlEta: r.dlEta || "", isPhantom: false,
            number: r.number || 0, isAur: !!r.isAur, dlBytes: r.dlBytes || 0,
            kind: r.kind || "pkg", groupKey: r.groupKey || "", depth: r.depth || 0,
            groupCount: r.groupCount || 0, groupFav: !!r.groupFav, groupOpen: !!r.groupOpen,
            dropping: false
        };
    }

    // Write one package's live state into its row, if this category holds it.
    function _applyProgress(name, state, pct, rate, eta) {
        // The count is over the SOURCE model, so it moves whether or not the
        // row is on screen. Scheduled only after finding the row below, it would never
        // run for a collapsed category (no rows), whose header would sit at 0/total until it was opened.
        section._scheduleStepCount();
        for (let i = 0; i < rowModel.count; i++) {
            // ONE get() per row. `ListModel.get()` materialises a fresh JS
            // wrapper for the row every call, and the matching row would be fetched
            // five times: once to compare the name and once per field. During
            // a download this runs for every section on every progress event,
            // several times a second for the whole phase.
            //
            // Safe to hold across the writes: no comparison below depends on a
            // field set above it, so each sees exactly the value a re-fetch would.
            const r = rowModel.get(i);
            if (r.name !== name) continue;
            if (r.runState !== state)
                rowModel.setProperty(i, "runState", state);
            if (r.dlPct !== pct)
                rowModel.setProperty(i, "dlPct", pct);
            if (rate !== undefined && r.dlRate !== rate)
                rowModel.setProperty(i, "dlRate", rate);
            if (eta !== undefined && r.dlEta !== eta)
                rowModel.setProperty(i, "dlEta", eta);
            // `isAur` is not optional. pacman downloads nothing for an AUR
            // package, so the resolver reads it as pending for the download
            // step -- but only when it is TOLD the row is an AUR one. Dropped
            // here, an AUR row sitting at `sources-ready` would read as DONE for the
            // download step, be retired, and take the whole category with it:
            // the AUR list would drain and shut itself the moment pacman started
            // downloading something else.
            if (section._retiringStep && section.stepStatusFor
                && section.stepStatusFor(state, !!r.isAur) === "done"
                && section._doneAt[name] === undefined) {
                section._doneAt[name] = Date.now();
                doneExitTimer.start();
            }
            return;
        }
    }

    // The category's packages as the list shows them: groups folded under their headers
    // (UpdateGroups.js). A run's list is flat.
    function _grouped(rows) {
        if (!section._grouping)
            return rows;
        return Groups.plan(rows, { min: section.groupMin, open: section.expandedGroups || ({}) });
    }

    // Rows that should be on screen right now: collapsed → favourites only,
    // expanded → everything.
    // Rows a completed package retires after, so the list empties itself as
    // the step works through it.
    property int doneExitDelayMs: 900
    // name -> ms at which it finished the current step.
    property var _doneAt: ({})
    // Set while the list has been refilled after emptying, so it is not
    // immediately drained again by the same completions.
    property bool _refilled: false

    signal autoCollapseRequested()
    // Emitted once the row model matches its source again. A host that needs
    // to MEASURE a row's new position has to wait for this: the sync is
    // deferred through Qt.callLater and re-deferred entirely while a wave is
    // running, so no fixed delay can be relied on to have caught it.
    signal rowsReconciled()

    // Steps where a finished package has nothing left to say and can leave.
    readonly property bool _retiringStep:
        section.runMode
        && (section.runStepKey === "download" || section.runStepKey === "sources"
            || section.runStepKey === "install" || section.runStepKey === "aur")

    // `opening`: called from _open(). A category whose rows have ALL left
    // is then shown in full (it has finished; there is nothing to drain)
    // instead of being handed an empty list and shut again by the
    // auto-collapse that an empty drain normally requests.
    function _targetRows(opening) {
        // Airborne: the section holds nothing, so a sync cannot put the
        // favourites back under a header that is not there.
        if (section.flightEmptying) return [];
        const rows = section._grouped(_sourceRows());
        if (!section.expanded) return rows.filter(r => r.isFavorite);
        if (!section._retiringStep || section._refilled) return rows;

        // Retire completed rows once their delay has elapsed. The delay is
        // what makes the list drain steadily instead of packages vanishing the
        // instant their bar fills.
        const now = Date.now();

        // Adopt anything that finished while this section did not exist.
        //
        // `_doneAt` is written by the live progress signal, so a section built
        // AFTER a package completed never learns about it — and both summary
        // panels are rebuilt on a view switch. Switching normal <-> verbose
        // mid-phase would therefore produce a section whose `_doneAt` is empty,
        // which drains nothing and stays open for the rest of the phase no
        // matter how much had finished.
        //
        // Backdated past the delay so these retire at once rather than
        // replaying a drain the user already watched in the other view.
        for (let i = 0; i < rows.length; i++) {
            const r = rows[i];
            if (section._doneAt[r.name] !== undefined) continue;
            // Same as above: without `isAur` this would backdate every AUR row
            // as already finished for a step it takes no part in.
            if (section.stepStatusFor(r.runState || "", !!r.isAur) === "done")
                section._doneAt[r.name] = now - section.doneExitDelayMs - 1;
        }
        const live = rows.filter(r => {
            const at = section._doneAt[r.name];
            return at === undefined || (now - at) < section.doneExitDelayMs;
        });

        // Everything has gone. Refill with the whole category and ask the host
        // to collapse it: the step is finished here, but the packages must
        // stay reachable so a later phase can still be inspected.
        if (live.length === 0 && rows.length > 0) {
            // Stay empty and ask to be shut. Refilling here would put every row back
            // on screen and then stagger them all out again as the collapse
            // arrives — a second drain to sit through. The full
            // set comes back the next time the category is expanded, which the
            // `_refilled` branch above handles.
            section._refilled = true;
            if (opening) return rows;
            Qt.callLater(section.autoCollapseRequested);
            return live;
        }
        return live;
    }

    // A finished row waits out its delay, then the next sync drops it.
    Timer {
        id: doneExitTimer
        interval: 220
        repeat: true
        running: false
        onTriggered: {
            if (!section._retiringStep || section._refilled) { running = false; return; }
            let pending = false;
            const now = Date.now();
            for (const k in section._doneAt)
                if ((now - section._doneAt[k]) < section.doneExitDelayMs) { pending = true; break; }
            section._scheduleSync();
            if (!pending) running = false;
        }
    }

    function _indexOfRow(name, from) {
        for (let i = from; i < rowModel.count; i++) {
            const r = rowModel.get(i);
            if (r.isPhantom) continue;
            if (r.name === name && r.rowState !== "leaving") return i;
        }
        return -1;
    }

    // Incremental reconciliation against the service, rather than clear() plus
    // rebuild.
    //
    // Rebuilding would destroy and recreate every delegate on any change, which
    // (a) throws away rowState, so a sync landing just after a collapse wipes
    // the "leaving" flags and the list vanishes in one frame instead of
    // staggering out, and (b) means a row leaving the set — un-favouriting
    // something while the category is collapsed — simply blinks out of
    // existence with the content below snapping up.
    //
    // Diffing keeps identity, so a departing row can slide out to the right on
    // the same choreography a collapsing list uses, and an unrelated sync
    // cannot disturb an animation already in progress.
    function _syncSilent() {
        // Never mutate under a running wave; retry once it has settled.
        if (cleanupTimer.running || settleTimer.running || groupCloseTimer.running) { _scheduleSync(); return; }

        const target = _targetRows();

        // 1. Rows that are gone: animate them out, then drop them.
        const wanted = new Set(target.map(t => t.name));
        let departing = 0;
        for (let i = 0; i < rowModel.count; i++) {
            const r = rowModel.get(i);
            if (r.rowState === "leaving" || r.isPhantom) continue;
            if (!wanted.has(r.name)) {
                // Index first — see the note in _close().
                rowModel.setProperty(i, "staggerIdx", departing);
                rowModel.setProperty(i, "rowState", "leaving");
                departing += 1;
            }
        }
        if (departing > 0) {
            removeTimer.interval = _waveMs(departing) + 30;
            removeTimer.restart();
        }

        // 2. Bring surviving rows into target order, inserting what is new.
        //    Departing rows are skipped by _indexOfRow, so they keep their
        //    place visually while they slide away.
        // A row arriving in a list that is already showing slides in the way
        // an expanding category's rows do -- one row, one animation -- rather
        // than popping into place. The initial fill and a collapsed category
        // still place rows silently.
        const animateNew = rowModel.count > 0 && section.expanded;
        let added = 0;
        let cursor = 0;
        for (let t = 0; t < target.length; t++) {
            const want = target[t];
            // Skip over rows that are on their way out.
            while (cursor < rowModel.count
                   && (rowModel.get(cursor).rowState === "leaving"
                       || rowModel.get(cursor).isPhantom))
                cursor += 1;

            const at = _indexOfRow(want.name, cursor);
            if (at < 0) {
                rowModel.insert(cursor, _rowEntry(want, animateNew ? "entering" : "rest",
                                                  animateNew ? added : 0));
                added += 1;
            } else {
                if (at !== cursor) rowModel.move(at, cursor, 1);
                // Refresh mutable fields in place so the delegate is reused.
                const cur = rowModel.get(cursor);
                if (cur.isFavorite !== want.isFavorite)
                    rowModel.setProperty(cursor, "isFavorite", want.isFavorite);
                if (cur.newVer !== want.newVer)
                    rowModel.setProperty(cursor, "newVer", want.newVer);
                if (cur.oldVer !== want.oldVer)
                    rowModel.setProperty(cursor, "oldVer", want.oldVer);
                // The run's own fields too: when the source flips from the
                // cached idle rows to the parser's, the numbers a prompt
                // refers to have to reach rows that already exist.
                if (cur.number !== (want.number || 0))
                    rowModel.setProperty(cursor, "number", want.number || 0);
                if ((cur.dlBytes || 0) !== (want.dlBytes || 0))
                    rowModel.setProperty(cursor, "dlBytes", want.dlBytes || 0);
                if (!!cur.isAur !== !!want.isAur)
                    rowModel.setProperty(cursor, "isAur", !!want.isAur);
                if ((cur.runState || "") !== (want.runState || ""))
                    rowModel.setProperty(cursor, "runState", want.runState || "");
                // Where it stands in a group: a favourite pulled out, a group's count, its state.
                if ((cur.depth || 0) !== (want.depth || 0))
                    rowModel.setProperty(cursor, "depth", want.depth || 0);
                if ((cur.groupKey || "") !== (want.groupKey || ""))
                    rowModel.setProperty(cursor, "groupKey", want.groupKey || "");
                if ((cur.groupCount || 0) !== (want.groupCount || 0))
                    rowModel.setProperty(cursor, "groupCount", want.groupCount || 0);
                if (!!cur.groupFav !== !!want.groupFav)
                    rowModel.setProperty(cursor, "groupFav", !!want.groupFav);
                if (!!cur.groupOpen !== !!want.groupOpen)
                    rowModel.setProperty(cursor, "groupOpen", !!want.groupOpen);
            }
            cursor += 1;
        }
        if (added > 0 && animateNew) {
            settleTimer.interval = _waveMs(added) + 30;
            settleTimer.restart();
        }
        section.rowsReconciled();
    }

    Timer {
        id: removeTimer
        repeat: false
        onTriggered: {
            for (let i = rowModel.count - 1; i >= 0; i--) {
                if (rowModel.get(i).rowState === "leaving") rowModel.remove(i);
            }
                section.transitionFinished();
        }
    }

    // Which of the animatable rows are worth animating: those inside the
    // viewport plus a row of overscan. `offsetPx` is the space already taken
    // by the favourites sitting above them.
    //
    // Everything outside the range is retired instantly. That is what keeps a
    // 182-row category honest at both ends: on collapse the off-screen rows
    // give up their height in one invisible step, leaving the content below
    // just past the bottom edge so it slides gently in rather than arriving
    // from six screens away.
    function _animRange(n, offsetPx) {
        const last = Math.max(0, n - 1);
        if (n <= 0) return {first: 0, last: -1};
        if (!section.viewport || section.viewport.height <= 0)
            return {first: 0, last: Math.min(last, section.fallbackWaveRows - 1)};

        const p = bodyClip.mapToItem(section.viewport, 0, 0);
        const top = p.y + (offsetPx || 0);
        const rowH = Math.max(8, section._rowH);
        const first = Math.min(last, Math.max(0, Math.floor(Math.max(0, -top) / rowH)));
        const avail = section.viewport.height - Math.max(0, top);
        const fit = Math.max(1, Math.ceil(avail / rowH) + 1);
        return {first: first, last: Math.min(last, first + fit - 1)};
    }

    function _waveMs(n) {
        return Math.max(0, n - 1) * section.staggerMs + section.animDuration;
    }

    function _open() {
        cleanupTimer.stop();
        groupCloseTimer.stop();
        // Through the same filter a sync uses, so a category reopened
        // mid-drain comes back WITHOUT the rows that have already left.
        // Building from the raw source would bring every finished row back,
        // and they would all walk out again at the next progress tick.
        const rows = _targetRows(true);
        const favsAll = rows.filter(r => r.isFavorite);
        const restAll = rows.filter(r => !r.isFavorite);
        // Favourites are already on screen and must not move or re-animate;
        // the wave is measured from directly beneath them. UNLESS nothing is
        // on screen at all -- a section that has just been emptied for a
        // flight, or drained to nothing -- in which case they are arriving
        // like everything else and belong in the wave, at the head of it.
        const arriving = rowModel.count === 0;
        const favs = arriving ? [] : favsAll;
        const rest = arriving ? favsAll.concat(restAll) : restAll;
        const r = _animRange(rest.length, favs.length * section._rowH);

        rowModel.clear();
        for (const f of favs) rowModel.append(_rowEntry(f, "rest", 0));
        for (let i = 0; i < rest.length; i++) {
            const inWave = i >= r.first && i <= r.last;
            rowModel.append(_rowEntry(rest[i],
                                      inWave ? "entering" : "collapsed",
                                      inWave ? i - r.first : 0));
        }
        settleTimer.interval = _waveMs(Math.max(1, r.last - r.first + 1)) + 30;
        settleTimer.restart();
    }

    function _close() {
        settleTimer.stop();
        // Count the favourites at the head of the model — they stay. Except
        // when the section is emptying for a flight, where nothing stays.
        let favCount = 0;
        if (!section.flightEmptying)
            while (favCount < rowModel.count && rowModel.get(favCount).isFavorite) favCount++;
        const animatable = rowModel.count - favCount;
        if (animatable <= 0) { section.transitionFinished(); return; }

        const r = _animRange(animatable, favCount * section._rowH);

        {
            for (let i = favCount; i < rowModel.count; i++) {
                const k = i - favCount;
                // staggerIdx BEFORE rowState, always.
                //
                // Writing rowState fires AnimatedListRow.onRowStateChanged
                // synchronously, and that schedules the kick from whatever
                // staggerIdx currently holds. Setting the index afterwards is
                // too late — the row has already been scheduled with the value
                // left over from the previous transition. A category expanded
                // while mostly off screen gives its unseen rows staggerIdx 0,
                // so collapsing it later would fire all of those at once no matter
                // how correct the newly computed wave was.
                if (k >= r.first && k <= r.last) {
                    rowModel.setProperty(i, "staggerIdx", k - r.first);
                    rowModel.setProperty(i, "rowState", "leaving");
                } else if (k < r.first) {
                    // ABOVE the viewport: hold full height until cleanup.
                    //
                    // Zeroing these immediately would make a collapse from
                    // deep inside a long list look instant. Their combined
                    // height sits above the visible area, so removing it
                    // shrinks the content under a contentY that is already at
                    // (or near) its maximum — the Flickable clamps, and the
                    // rows that were mid-animation are yanked out of view. On
                    // the 180-row category scrolled to its middle that is a
                    // 2911 px jump in one frame.
                    rowModel.setProperty(i, "staggerIdx", 0);
                    rowModel.setProperty(i, "rowState", "rest");
                } else {
                    // BELOW the viewport. Retiring these instantly is what
                    // lets whatever follows the category slide up gently
                    // instead of arriving from several screens away — but only
                    // when the viewport can afford to lose that height.
                    //
                    // Safe to retire instantly: they are off screen, and the
                    // rows ABOVE keeping their height means the content only
                    // shrinks below the viewport, so the scroll position is
                    // never clamped out from under the wave.
                    rowModel.setProperty(i, "staggerIdx", 0);
                    rowModel.setProperty(i, "rowState", "collapsed");
                }
            }
        }
        cleanupTimer.interval = _waveMs(Math.max(1, r.last - r.first + 1)) + 30;
        cleanupTimer.restart();
    }

    // ---- Groups: opening, closing, the favourite on a header --------------------------------
    //
    // The host keeps which groups are open (`expandedGroups`); this section animates the change.
    // A group is a slice of the flat model, opened and shut by the same law as the category:
    // the packages whose slots land on screen fly in (out) on the stagger, the rest are placed
    // when the head has landed (retired at once below the fold, held above it).
    property var _seenGroups: ({})
    property bool _ready: false
    onExpandedGroupsChanged: {
        const now = section.expandedGroups || ({});
        const before = section._seenGroups;
        section._seenGroups = Object.assign({}, now);
        if (!section._ready || !section._grouping) return;
        for (const k in now)
            if (now[k] === true && before[k] !== true) section._openGroup(k);
        for (const k in before)
            if (before[k] === true && now[k] !== true) section._closeGroup(k);
    }

    // A row at rest and whole tells the pitch of its kind. Only such a row: a phantom, the row a
    // flight has suppressed (its space is opening), one mid-wave or one the user has expanded
    // is not the pitch of a row.
    function _measure(wrap, item) {
        const m = wrap.model;
        if (!item || m.isPhantom || wrap.rowState !== "rest" || wrap._fullHeight <= 8) return;
        if (section.suppressedRow === m.name && section.suppressedReveal < 1) return;
        if (!item.expanded) section._measuredRowH = wrap._fullHeight;
    }

    // The row model as plain text, one "name|kind|depth|state" per row (a probe's picture of it).
    function modelDump() {
        const out = [];
        for (let i = 0; i < rowModel.count; i++) {
            const r = rowModel.get(i);
            out.push((r.isPhantom ? "(phantom)" : r.name) + "|" + r.kind + "|" + r.depth + "|" + r.rowState
                     + (r.dropping ? "|dropping" : ""));
        }
        return out;
    }

    function _groupHeadIndex(key) {
        for (let i = 0; i < rowModel.count; i++) {
            const r = rowModel.get(i);
            if (r.kind === "group" && r.groupKey === key && r.rowState !== "leaving") return i;
        }
        return -1;
    }
    // Something else is moving the model: the diff places the group instead (animated, on its
    // own law for rows that arrive).
    function _busyForGroup() {
        return cleanupTimer.running || settleTimer.running || removeTimer.running
            || groupCloseTimer.running || section.flightEmptying;
    }

    function _openGroup(key) {
        const hi = section._groupHeadIndex(key);
        if (hi < 0 || section._busyForGroup()) { section._scheduleSync(); return; }
        // The sync may have put them there already.
        if (hi + 1 < rowModel.count && rowModel.get(hi + 1).kind === "pkg"
            && rowModel.get(hi + 1).groupKey === key && rowModel.get(hi + 1).depth > 0) return;
        const members = section._targetRows().filter(t => t.kind === "pkg" && t.groupKey === key);
        rowModel.setProperty(hi, "groupOpen", true);
        if (members.length === 0) return;
        const r = section._animRange(members.length, (hi + 1) * section._rowH);
        for (let i = 0; i < members.length; i++) {
            const inWave = i >= r.first && i <= r.last;
            rowModel.insert(hi + 1 + i, section._rowEntry(members[i],
                            inWave ? "entering" : "collapsed", inWave ? i - r.first : 0));
        }
        settleTimer.interval = section._waveMs(Math.max(1, r.last - r.first + 1)) + 30;
        settleTimer.restart();
    }

    function _closeGroup(key) {
        const hi = section._groupHeadIndex(key);
        if (hi < 0 || section._busyForGroup()) { section._scheduleSync(); return; }
        rowModel.setProperty(hi, "groupOpen", false);
        let end = hi + 1;
        while (end < rowModel.count) {
            const m = rowModel.get(end);
            if (m.kind !== "pkg" || m.groupKey !== key || m.depth <= 0) break;
            end++;
        }
        const n = end - hi - 1;
        if (n <= 0) return;
        const r = section._animRange(n, (hi + 1) * section._rowH);
        for (let k = 0; k < n; k++) {
            const i = hi + 1 + k;
            rowModel.setProperty(i, "dropping", true);
            // staggerIdx BEFORE rowState, as in _close().
            if (k >= r.first && k <= r.last) {
                rowModel.setProperty(i, "staggerIdx", k - r.first);
                rowModel.setProperty(i, "rowState", "leaving");
            } else if (k < r.first) {
                rowModel.setProperty(i, "staggerIdx", 0);
                rowModel.setProperty(i, "rowState", "rest");
            } else {
                rowModel.setProperty(i, "staggerIdx", 0);
                rowModel.setProperty(i, "rowState", "collapsed");
            }
        }
        groupCloseTimer.interval = section._waveMs(Math.max(1, r.last - r.first + 1)) + 30;
        groupCloseTimer.restart();
    }
    Timer {
        id: groupCloseTimer
        repeat: false
        onTriggered: {
            for (let i = rowModel.count - 1; i >= 0; i--)
                if (rowModel.get(i).dropping) rowModel.remove(i);
                section.transitionFinished();
        }
    }

    // A right click on a group's header: every package of it becomes a favourite, or, when
    // they all are already, none does.
    function _groupFavorite(key) {
        const ch = Groups.favoriteChange(section._sourceRows(), key, section.groupMin);
        if (ch.names.length > 0)
            section.groupFavoriteRequested(key, ch.names, ch.favorite);
    }

    Timer {
        id: cleanupTimer
        repeat: false
        onTriggered: {
            // Drop only the non-favourites; the starred rows stay on screen --
            // unless the section is emptying for a flight, when they go too.
            for (let i = rowModel.count - 1; i >= 0; i--) {
                if (section.flightEmptying || !rowModel.get(i).isFavorite) rowModel.remove(i);
            }
                section.transitionFinished();
        }
    }
    Timer {
        id: settleTimer
        repeat: false
        onTriggered: {
            // Rows that were not part of the visible wave take their real
            // height now. Anchored for the same reason as the collapse: any of
            // them sitting above the viewport would otherwise shove the
            // visible content down as they claim their space.
            for (let i = 0; i < rowModel.count; i++) {
                if (rowModel.get(i).rowState !== "rest")
                    rowModel.setProperty(i, "rowState", "rest");
            }
            section.transitionFinished();
        }
    }

}
