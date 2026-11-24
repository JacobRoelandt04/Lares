pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "../../../common/system"
import "../../../common/components/Bytes.js" as Bytes
import "../../../common/scroll"
import "../../../common/components/Mix.js" as Mix
import "../../../common/components/RelTime.js" as RelTime
import "SystemUpdateWork.js" as Work
import "SystemUpdateProgress.js" as Progress
import "../../../common/theme"
import "../../../common/auth"
import "../../../auth/data"
import "../../../common/components"
import "../snapshots"
import QtQuick.Controls
import QtQuick.Layouts

// =============================================================================
// SystemUpdatePopup.qml
//
// Drop-in popup content for the system-update module. Renders the state of a
// `yay -Syu` run — driven by an externally-provided TerminalBackend and the
// PackageUpdateParser that sits on top of it. No data ownership: the enclosing
// module creates + holds both, so the update can keep running while the popup
// is closed.
//
// Three verbosity modes per docs/contracts/system_update_phases.md §7:
//   - quiet   : only the header card. Body is hidden so the host container
//               can collapse to the header's natural height.
//   - normal  : header + summary panel (category sections, errors).
//   - verbose : header + split view: TerminalView (70%) + same summary
//               panel (30%) on the right.
//
// Palette is eva-light (CLAUDE.md table + ~/.config/kitty/themes/evalight.conf)
// so terminal ANSI colours and popup UI read as one design.
//
// Drop-in contract:
//   - `anchors.fill: parent` in a parent of any size ≥ ~380×120 renders.
//   - The popup advertises `implicitHeight` / `implicitWidth` per mode so a
//     host that follows the implicit size (thePopup, mockup stage) shrinks
//     for quiet and expands for verbose automatically.
// =============================================================================
Item {
    id: root

    // ---- Required inputs ----
    property var backend: null                      // TerminalBackend
    property var parser: null                       // PackageUpdateParser

    // ---- Optional: AvailableUpdatesService for the idle state. When null,
    // the idle panel just shows "No update running" + an unconditional Run
    // button (which is wired to startUpdateRequested anyway).
    property var availableUpdates: null

    // ---- Optional: the SnapshotService (docs/contracts/snapshots.md). Null = no snapshots in this shell: no
    // Snapshot notch, no companion line, no page, and the popup is what it was without them.
    property var snapshots: null
    readonly property bool _snapReady: !!root.snapshots && root.snapshots.ready === true

    // ---- Options ----
    // Typeface for the whole popup. Defaults to the module's own choice so a
    // bare drop-in looks right; hosts (the mockup, the bar popup) override it
    // to match the rest of their surface without the module's default moving.
    property string fontFamily: "Audiowide"
    // The quiet view's content width: the card and the prompt's field are laid out in it, and the popup
    // is this plus its padding wide in quiet.
    property int tabSelectorWidth: 400
    // The view selector's own width. It shows icons, so it is as wide as three icons need --
    // 132 gives each pill 38 px -- and rests against the popup's right edge.
    property int modeTabsWidth: 132
    property real modeTabsIconSize: 16
    // Wheel step multiplier for the summary lists, applied to the raw angle
    // delta.
    property real scrollSpeed: 1.0
    // Shared by the list rows and the favourite clone, so a row leaving a
    // collapsing list and a clone leaving the screen travel at the same speed.
    property int rowAnimDuration: 240
    // Two-finger horizontal swipe anywhere in the popup switches view.
    property bool swipeToSwitchMode: true
    // THE TAB ROW COMES AND GOES WITH THE POINTER: the quiet view keeps its small size once the
    // shell is scaled up, so the row that picks the view is freed while the pointer is away.
    // It is asked for from the popup's TOP BAND and by a two-finger gesture
    // anywhere, and held for `tabsHoldMs` after a view switch and after the fingers of a gesture
    // lift: the switch itself can carry the pointer out of the popup (verbose -> quiet shrinks the
    // box from under it), and a row that vanished mid-gesture would take the gesture with it.
    //
    // THE BAND, NOT THE WHOLE POPUP. The row pushes the
    // content down by its own height, so a row that appears wherever the pointer happens to be makes
    // every button run away from the hand that is going for it. Three rules keep it from doing that:
    //   - only the strip along the popup's top edge (`tabsBandHeight`) asks for it, and only after the
    //     pointer has RESTED there for `tabsDwellMs`: the popup hangs from the bar, so a pointer on its
    //     way to a button crosses that strip every time, and a row that answered the crossing would
    //     nudge the very button being aimed at;
    //   - once shown it stays while the pointer is anywhere in the popup, and goes when the pointer
    //     leaves it: a row that left the moment the pointer dropped out of the band would slide the
    //     content back up under the hand that followed it down;
    //   - a swipe shows it wherever it begins (`_gestureActive`): the gesture is the other way in.
    // The content refits into the freed room, easing on the card's own 260 ms. `tabsAutoHide: false`
    // keeps the row always (a mockup stage that has to be tuned from a panel beside it).
    property bool tabsAutoHide: true
    property int tabsHoldMs: 1100
    // The band, from the popup's top edge: the padding and a little of what lies under it. Narrower than
    // the row's own extent on purpose: in the quiet view the card's glyph and buttons start under it.
    property real tabsBandHeight: root.padding * 2
    property int tabsDwellMs: 150
    // The pointer is over the popup (a probe reads it), and whether it is in the top band.
    readonly property bool tabsPointerOver: popupHover.hovered
    readonly property bool tabsPointerInBand: popupHover.hovered
        && popupHover.point.position.y < root.tabsBandHeight
    // The pointer has rested in the band and has not left the popup since: the row is asked for.
    property bool _bandArmed: false
    // Touchpads that report high-resolution scrolling can deliver a wheel
    // event with pixelDelta set and angleDelta at (or near) zero. Keying only
    // off angleDelta silently ignores those devices entirely, so pixelDelta is
    // accepted as a fallback and scaled into the same units — one notch is
    // 120 angle units, which is roughly 48 px of travel.
    property real swipePixelToAngle: 2.5

    // ---- Swipe / pill tuning ------------------------------------------------
    // Passed straight through to the mode selector so the mockup's panel can
    // tune the feel on the popup. The numbers are TabSelector's own defaults;
    // keep the two in step.
    property real swipeThreshold: 1500      // accumulated units to commit a step
    property real swipePullTaper: 2.5       // >1 front-loads the pill's travel
    property real swipeMaxPull: 0.42        // peak lean, as a fraction of a slot
    property real swipeMomentumRate: 2400   // units/s that counts as a flick
    property int  swipeCooldownMs: 320      // gap between slow-swipe commits
    property real squishMax: 0.18           // peak stretch, as a fraction
    property real squishVelocityRef: 850    // px/s at which peak stretch is hit

    // ---- Wheel diagnostics -------------------------------------------------
    // Read-only mirror of the last wheel event this popup saw. Exposed because
    // whether a given touchpad produces horizontal deltas at all, and in which
    // field, is not something that can be reasoned about from here — it has to
    // be observed on the machine.
    // Wheel diagnostics for a hosting mockup; the writes below are skipped
    // unless a host turns this on, so a production popup does no per-event
    // bookkeeping.
    property bool diagnostics: false
    readonly property alias lastWheelAngleX: _wheelDiag.angleX
    readonly property alias lastWheelAngleY: _wheelDiag.angleY
    readonly property alias lastWheelPixelX: _wheelDiag.pixelX
    readonly property alias lastWheelPixelY: _wheelDiag.pixelY
    readonly property alias wheelEventCount: _wheelDiag.count
    readonly property alias lastSwipeAccum:  _wheelDiag.accum
    // Live gesture-latch state, for the mockup readout.
    readonly property bool  gestureOwnedByTerminal: root._gestureOwnedByTerminal
    QtObject {
        id: _wheelDiag
        property real angleX: 0
        property real angleY: 0
        property real pixelX: 0
        property real pixelY: 0
        property int  count: 0
        property real accum: 0
    }
    // Wrap long terminal lines (verbose view). Off = horizontal scrolling.
    property bool terminalWrapLines: false
    // Per-view density for the package lists. Quiet has no list, so it has no
    // knob. Tune these to taste; every size and the animation maths follow.
    property real normalListScale: 1.2
    property real verboseListScale: 1.1
    property string verbosityMode: "normal"         // "quiet" | "normal" | "verbose"
    // Lets a perf harness isolate the rail's cost from the list's.
    property bool railEnabled: true
    property bool railParticles: true
    // The rail itself, so a host can tune its particle behaviour without
    // twenty pass-through properties in between. Read-only handle; set the
    // rail's own properties through it.
    readonly property alias rail: phaseRail
    property bool allowModeSwitch: true
    property bool allowPromptReply: true

    // ---- sudo's password is asked through the authentication toast ---------
    //
    // The run's sudo (yay --sudo helpers/sudo-askpass, which adds -A to every
    // call, --sudoloop's `sudo -v` included; helpers/update-run.sh) asks its
    // SUDO_ASKPASS helper, which connects to `askpassPath`; an AskpassServer
    // serves that socket while its backend is attached to a live run (the run
    // outlives any one shell and the helper retries until the next one serves
    // the same path) and an AskpassSource hands each request to the shell's
    // AuthBroker, where the toast takes the face, the password or the cancel.
    // The card only says that it is waiting. No secret passes through this
    // popup, the backend or the run's stdin.fifo.
    //
    // WHO SERVES IT. In the bar the engine DESTROYS this content when the popup
    // closes, and the run goes on with the popup shut: a sudo asking then would
    // find nobody on the socket. So the update's SERVICE
    // (modules/bar/system_update/SystemUpdateService.qml) holds the pair for as
    // long as the shell lives and hands the server here as `askpassServer`; the
    // card reads its standing request and builds nothing. With none handed in
    // (a mockup, or a probe that builds a popup and a backend of its own) this popup
    // serves its own.
    property var askpassServer: null
    // The own pair's inputs (unused when a server is handed in).
    property var askpassBroker: AuthBus.broker
    property string askpassPath: Quickshell.env("XDG_RUNTIME_DIR")
        ? Quickshell.env("XDG_RUNTIME_DIR") + "/lares-askpass-update.sock" : ""
    // null | the standing request ({ id, pid, prompt, ... }), for hosts and probes.
    // False only in a probe: no process of a test is root, so none can be the
    // setuid sudo the server insists on for the requester's parent.
    property bool askpassRequireSudoParent: true
    // The server this card reads: the one handed in, else the own pair's (which
    // registers itself here when it is built).
    property var _ownServer: null
    readonly property var _askpassSrv: root.askpassServer ? root.askpassServer : root._ownServer
    readonly property var askpassRequest: root._askpassSrv ? root._askpassSrv.request : null
    readonly property bool _askpassWaiting: !!root.askpassRequest
    Loader {
        id: _ownAskpass
        active: !root.askpassServer
        sourceComponent: Component {
            Item {
                Component.onCompleted: root._ownServer = _server
                AskpassServer {
                    id: _server
                    path: root.askpassPath
                    active: root.askpassPath.length > 0 && !!root.backend
                        && root.backend.attached === true && root.backend.running === true
                    rootPid: Number((root.backend && root.backend.attachPid) || 0)
                    requireSudoParent: root.askpassRequireSudoParent
                    // update-run.sh's LARES_ASKPASS_TIMEOUT: sudo's own passwd_timeout.
                    answerWindowMs: 300000
                }
                HowdyConfig { id: _howdy }
                AskpassSource {
                    broker: root.askpassBroker
                    server: _server
                    title: "System update"
                    howdyMode: _howdy.mode
                    faceTimeoutMs: _howdy.timeoutMs
                    describe: function (request) { return root._askpassDescribe(request); }
                    // With no broker there is nobody to ask: the source answers sudo "" at
                    // once (it says so, and yay stops) rather than leave it waiting on a
                    // toast that cannot come.
                    onDeclined: (request, reason) => console.warn("update: sudo was refused a password prompt: " + reason)
                }
            }
        }
    }
    // What the toast says: the run, and what yay is doing when sudo asks.
    function _askpassDescribe(request) {
        return Work.askpassDescription(root._phase, root.parser ? root.parser.subPhase : "", root._rawPhaseLabel, root._runKind, root._snapState);
    }
    // How long the status card takes to settle when its content changes size.
    property int containerResizeMs: 260

    // ---- Carved list surfaces --------------------------------------------
    // Each category header becomes its own ShadowBox, with its step progress
    // carried by the colour of that box's inset shadow; and the scrollable
    // list sits in one box of its own, its lower rows dissolving into the
    // bottom edge rather than being cut off by it.
    property bool boxedList: true
    property color listBoxColor: Theme.listBox
    property real listBoxRadius: 14
    // Verbose's compact headers are a third shorter, so the container's corner they share
    // takes this smaller radius in verbose (the normal one reads over-round on them: top
    // corners rounder than the bottom ones, the inset shadow's bend not matching).
    // Every header takes the box's radius in both views, so the corners are one curve.
    property real listBoxRadiusCompact: 10
    readonly property real _listRadius: root._listInVerbose ? root.listBoxRadiusCompact : root.listBoxRadius

    // ---- The Arch mark ---------------------------------------------------
    //
    // Carved into whatever ground it sits on -- the same relief the LLM popup
    // gives a model's logo (LogoRelief, over the field baked into
    // assets/logos by tools/bake_logo_relief.py). Two places, two jobs: the
    // list container's EMPTY STATE in normal view, and a GROUND for the
    // terminal in verbose, which stays where it is as output fills the buffer
    // because it is a ground and not a placeholder. Verbose's list panel gets
    // none: at three tenths of the width there is no room for a mark that
    // reads.
    property url archLogoSource: "file://" + RepoRoot.dir + "/assets/logos/archlinux.png"
    property int archLogoSize: 150
    property int terminalLogoSize: 260
    // How far the terminal's own ground is pushed toward the theme's rim and
    // shadow to carve into it. The terminal is a darker shade than the list
    // box, so it cannot borrow the list's bevel and border outright.
    property real terminalLogoContrast: 1.0

    // Nothing is drawn in the list container: no categories, no skeleton, and
    // neither of the two blocks under them.
    // Written so a parser that does not carry a count at all (the mock, a
    // host's own stub) reads as "none", not as "unknown": `x === 0` is false
    // for undefined, so the mark would never appear on a list that is
    // demonstrably empty.
    readonly property bool _listEmpty: categoryModel.count === 0
        && !root._showSkeleton
        && !(root.parser && root.parser.errorCount > 0)
        && !(root.parser && root.parser.noticeCount > 0)
    property real listFadeHeight: 34
    // Breathing room between the box's carved edge and the rows inside it.
    //
    // Applied to the ROWS, not to the scrolling viewport. The viewport fills
    // the box exactly so a header's own box can sit flush against the
    // container's edges and share its corner; insetting the viewport would
    // hold every header away from those edges.
    property real listInset: 6

    // ---- List silhouette while the update check runs ----------------------
    //
    // Instead of a line of text above an empty box, the box holds a
    // silhouette of the list it is about to show (ListSkeleton). When the
    // check completes the silhouette resolves against the real category
    // count: slots with a real header fade into it in place, extra ones
    // collapse, and the real sections fade in underneath.
    readonly property bool _showSkeleton: root._idle && !root._runHeld && root._scanning
    property bool _skeletonAlive: false
    on_ShowSkeletonChanged: {
        if (root._showSkeleton) {
            skeletonSettle.stop();
            skeletonResolve.stop();
            listSkeleton.reset();
            root._skeletonAlive = true;
        } else {
            // A beat for the category model to reconcile with the service's
            // fresh list before the silhouette is told how many are real.
            skeletonResolve.restart();
        }
    }
    Timer {
        id: skeletonResolve
        interval: 80
        onTriggered: {
            listSkeleton.resolve(categoryModel.count);
            skeletonSettle.restart();
        }
    }
    Timer {
        id: skeletonSettle
        interval: listSkeleton.fadeMs + listSkeleton.collapseMs + 40
        onTriggered: root._skeletonAlive = false
    }
    // Line heights of the list's own texts at the list's own scale, for the
    // silhouette. Text items rather than FontMetrics: a Text's line can
    // differ from the metric's height by a pixel, and the silhouette has to match
    // the real rows to the pixel.
    Item {
        visible: false
        readonly property real _s: Math.max(0.2, root._listInVerbose ? root.verboseListScale : root.normalListScale)
        Text { id: skelTitleProbe;   text: "Ag"; font.family: root.fontFamily; font.pixelSize: 15 * parent._s; font.bold: true }
        Text { id: skelSubProbe;     text: "Ag"; font.family: root.fontFamily; font.pixelSize: 11 * parent._s }
        Text { id: skelNameProbe;    text: "Ag"; font.family: root.fontFamily; font.pixelSize: 13 * parent._s; font.bold: true }
        Text { id: skelVersionProbe; text: "Ag"; font.family: root.fontFamily; font.pixelSize: 11 * parent._s }
    }

    // ---- Terminal (verbose view) ------------------------------------------
    property int  terminalFontSize: 12
    // How far ahead one axis of a two-finger motion has to be before the
    // terminal commits to it. Forwarded to TerminalView, where the reasoning
    // for the lock lives.
    property real terminalAxisLockRatio: 1.4
    property bool terminalFontBold: true

    // Verbose lays the terminal beside the list and compacts the list; see
    // the body for why there is one list box rather than one per view.
    readonly property bool _listInVerbose: verbosityMode === "verbose"

    // ---- Category header inset, idle and under way ------------------------
    // Plumbed through to ListSectionHeader -> ShadowBox. See ShadowBox for
    // what width, edge alpha and falloff each mean; the pair is blended on
    // progress, never on a clock.
    // The defaults are the tuned values (mockups/system_update.qml's
    // `val:` entries, which are also ListSectionHeader's and ShadowBox's own
    // defaults), so the popup looks the same mounted anywhere, not only in
    // the mockup that pushes them.
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
    // Exposed so a harness can watch the card settle.
    readonly property real headerHeight: headerCard.height

    // Emitted when the user clicks the primary "Run yay -Syu" / "Run update"
    // button. The host wires this to `backend.command = ...; backend.start()`
    // because the popup itself doesn't know which command to run (sudo-vs-not,
    // pkexec wrapping, replay-mode override, etc.).
    signal startUpdateRequested()
    // "Update without it": the run stopped because no snapshot could be taken, and the user says go on anyway.
    // The host starts the run with the skip token (SystemUpdateService.startUpdate(true)).
    signal startWithoutSnapshotRequested()
    // The snapshots page asks to undo an update (short id); the host starts the undo run, the page closes.
    signal undoRequested(string short)
    signal refreshRequested()
    // The check glyph of a finished run was clicked: the popup has nothing more to say
    // and asks its host to close it. The host obeys (the bar's owner closes the popup);
    // a mockup that cannot close anything ignores it. It never starts a run: the check
    // of a finished update must not re-run it.
    signal closeRequested()

    // ---- Keys on a layer surface -----------------------------------------------
    //
    // The prompt's number-list field (yay's "Packages to exclude") and the
    // terminal's selection copy need the keyboard, and a layer surface has it
    // only when its window asks. The request is "onDemand" -- a click inside
    // gives the keys, a click elsewhere takes them away -- and EXCLUSIVE for a
    // moment when the field appears, so a question that arrives mid-run can be
    // answered by typing (the notes popup's idiom, NotesPopup.qml). The host
    // binds its window's keyboard focus to this (the engine: `popupKeyboard`).
    // UNVERIFIED on a real layer surface: the desktop checklist. `grabKeyboard:
    // false` turns the pulse off.
    property bool grabKeyboard: true
    property bool _focusPulse: false
    readonly property string keyboardFocusRequest: root._focusPulse ? "exclusive" : "onDemand"
    function pulseKeyboard() {
        if (!root.grabKeyboard)
            return;
        root._focusPulse = true;
        focusPulse.restart();
    }
    Timer {
        id: focusPulse
        interval: 120
        onTriggered: root._focusPulse = false
    }

    // ---- The snapshots page: this popup's secondary (the engine's content contract, as StocksPopup) -----------
    // The page hangs beside the popup (start: toward the bar's start, away from the right segment the quiet
    // view rests against), its top level with the popup's. It is built on open and DESTROYED on close, so
    // nothing it needs to outlive lives in it: the undo run is the SERVICE's (`undoRequested` -> startUndo),
    // the rows and the busy state are the SnapshotService's.
    property real _pageW: 360
    property real _pageH: 300
    property Component secondaryComponent: Component {
        SnapshotsPage {
            service: root.snapshots
            fontFamily: root.fontFamily
            runActive: !root._idle
            // Placed by its NATURAL size, which the engine cannot move (the live one includes the cutout).
            onNaturalHeightChanged: root._pageH = naturalHeight
            onImplicitWidthChanged: root._pageW = implicitWidth
            Component.onCompleted: { root._pageH = naturalHeight; root._pageW = implicitWidth; }
            // The run belongs to the service; the page closes with the ask.
            onUndoRequested: short => {
                root.secondaryOpen = false;
                root.undoRequested(short);
            }
        }
    }
    property bool secondaryOpen: false
    readonly property string secondarySide: "start"
    readonly property point secondaryAnchor: Qt.point(root._pageW / 2, root._pageH / 2)
    readonly property bool secondaryOverhang: root._pageH > root.implicitHeight + 0.5
    readonly property real secondaryInset: 0
    property var secondaryKey: null
    function toggleSnapshots() {
        if (root._snapReady)
            root.secondaryOpen = !root.secondaryOpen;
    }
    // Escape's step back (GooeyEngine.stepBack): the page goes; true when one was open.
    function stepBack(): bool {
        const was = root.secondaryOpen;
        root.secondaryOpen = false;
        return was;
    }
    // No page without a service that can fill it.
    // (and a service that becomes ready mid-run is asked the rule at once)
    on_SnapReadyChanged: {
        if (!root._snapReady) root.secondaryOpen = false;
        pkgSummaryTimer.restart();
    }

    // Central icon registry. Exposed so a host can extend or swap it without
    // touching the popup.
    property var packageIcons: _defaultPackageIcons

    // Opens a package's upstream URL on request from a row's link -- resolved
    // lazily, one package at a time, only when clicked. A click opens the URL AND closes the
    // popup, whatever the lookup does (the wiki's redirect does the same). The content is gone
    // on close, so a host hands over an opener that outlives it (the service's: a repo package
    // resolves from the sync DB in a blink, an AUR one asks yay and may take seconds, and
    // either still opens its page after the popup has gone). With none (a mockup, a probe)
    // the popup uses its own, which dies with it.
    property var urlOpener: null
    readonly property var _opener: root.urlOpener || localUrlOpener
    PackageUrlOpener { id: localUrlOpener }
    PackageIcons { id: _defaultPackageIcons }

    // ---- Palette ----
    // Every colour defaults to a Theme token, so a theme or mode switch
    // crossfades the whole popup on Theme's single clock. They stay plain
    // (not readonly) defaults: a host that assigns one still wins, and the
    // mockup panel edits the theme itself rather than these properties --
    // assigning one from JS would destroy its binding for good.
    property color surfaceColor:   Theme.surface
    property color panelColor:     Theme.panelSunk
    property color bevelColor:     Theme.bevel
    property color borderColor:    Theme.border
    property color primaryText:    Theme.textPrimary
    property color mutedText:      Theme.textMuted
    property color faintText:      Theme.textFaint
    property color accent:         Theme.accent
    property color accentHover:    Theme.accentHover
    property color textOnAccent:   Theme.textOnAccent
    property color warnStrongColor: Theme.warn
    property color okColor:        Theme.ok
    property color errColor:       Theme.error

    // ---- Category colours -------------------------------------------------
    // Matched to how yay syntax-highlights each repo in the terminal, so the
    // popup and the scrollback read as the same information. The theme's cat*
    // tokens carry them, and the same theme dresses the terminal, so the two
    // cannot drift apart.
    //   core     amber-orange
    //   extra    green
    //   multilib cyan
    //   aur      blue
    property color repoCoreColor:     Theme.catCore
    property color repoExtraColor:    Theme.catExtra
    property color repoMultilibColor: Theme.catMultilib
    property color aurCategoryColor:  Theme.catAur
    property color flatpakColor:      Theme.catFlatpak

    // Soft tint helpers for error / success backgrounds on white.
    property color errTint:   Theme.errorTint

    // ---- Rail ---------------------------------------------------------------
    // The ball's contact shadow. Neutral dark rather than a tint of the run
    // tone, so the ball reads as sitting IN the channel.
    property color ballShadowColor: Theme.ballShadow

    // ---- Terminal -----------------------------------------------------------
    // The verbose view's scrollback. `terminalBg` is its own token rather
    // than the popup's sunk panel because a terminal is a window onto another
    // program, and the theme may want to give it its own ground; the ANSI
    // palette the text is coloured with lives in TerminalBackend, which reads
    // the same theme.
    property color terminalBgColor:            Theme.terminalBg
    property color terminalSelectionColor:     Theme.terminalSelection
    property color terminalSelectionTextColor: Theme.terminalSelectionText

    // ---- Derived state ----
    readonly property bool _idle: !root.backend || !root.backend.running
    // The parser has produced the transaction's package list (after
    // resolve). Before that, the list on screen is the cached idle one.
    // The finished run stays on screen as an overview -- every package it
    // touched, "N packages updated" -- until the popup is hidden or the next
    // run starts. Without this the list would snap back to the cached idle rows
    // the moment the backend exits, and a refresh would then replace even those.
    property bool _runHeld: false
    readonly property bool _showingRun: !root._idle || root._runHeld
    on_IdleChanged: {
        if (!root._idle) {
            runListSettleTimer.stop();
            root._runListSettled = false;
            root._runHeld = false; root._hasAurWork = false; root._hasSnapshotWork = false;
            root._clearRunOverlay();
        }
        else if (root._parserHasPackages) { root._runHeld = true; root._runEndedAtMs = Date.now(); }
        root._updateStep();
        root._recomputePackageSummary();
    }
    // Shown while idle: ask the host for a fresh check, so the popup opens
    // on current numbers.
    onVisibleChanged: {
        if (!root.visible) root.dismissRunOverview();
        else if (root._idle) root.refreshRequested();
    }
    function dismissRunOverview() {
        if (!root._runHeld) return;
        // A category flight (the run's lead category handing over to the service's), airborne or still
        // waiting for its section to empty, carries the overview's list and applies it where it lands:
        // it would bring back the run's categories the dismissal is about to take out. End it first, so
        // its list goes in before the real one.
        sectionFlight.cancel();
        root._cancelSectionFlight();
        root._runHeld = false;
        root._maxStepKey = "";
        root._currentStep = "";
        root._recomputePackageSummary();
    }
    readonly property bool _parserHasPackages: !!root.parser && !!root.parser.packages
                                               && root.parser.packages.count > 0
    // Sync, resolve, the prompts: nothing has been done to any package yet,
    // so the list keeps its idle dress -- favourites, "N packages", the
    // user's own expanded state -- rather than pretending to be a run.
    readonly property bool _preDownload: !root._idle
        && root._indexOfStep(root._currentStep) < root._indexOfStep(root._firstWorkStep)
    // The first notch that works on packages (what "before the download" is measured against): an undo
    // has no download, its work starts at the snapshot or the install.
    readonly property string _firstWorkStep: root._runKind === "undo"
        ? (root._hasSnapshotWork ? "snapshot" : "install")
        : (root._hasAurWork ? "sources" : "download")
    readonly property bool _active: !root._idle
    readonly property bool _awaiting: (!!root.parser && root.parser.awaitingUserInput)
                                   || (!!root.backend && root.backend.awaitingInput)
    readonly property bool _completed: root._idle && root.parser && root.parser.phase !== "INITIAL"

    // Has a run happened during this popup's lifetime?
    //
    // The rail hides before the first run and stays up afterwards, so a
    // finished run's green (or red) settle is actually visible. It resets
    // only when the popup is rebuilt, which in the real shell is exactly
    // closing and reopening it.
    property bool _hasRun: false
    on_ActiveChanged: if (root._active) root._hasRun = true;
    readonly property bool _showRail: root.railEnabled && (!root._idle || root._hasRun)

    // ---- Prompt classification. parser.currentPromptKind is a plain string
    // so QML binding tracks changes reliably (var-property nested-field
    // access is flaky). A sudo password is NOT a prompt kind: it is asked
    // through the authentication toast (see _passwordNeeded), never typed here.
    // Map a PROMPT_* phase back to its prompt kind. Used as a backstop below.
    readonly property var _phasePromptKinds: ({
        PROMPT_EXCLUDE:        "yay_exclude",
        PROMPT_CLEANBUILD:     "yay_cleanbuild",
        PROMPT_DIFFS:          "yay_diffs",
        PROMPT_EDIT_PKGBUILD:  "yay_edit_pkgbuild"
    })

    readonly property string _promptKind: {
        if (root.parser && root.parser.currentPromptKind.length > 0)
            return root.parser.currentPromptKind;

        // Backstop: the parser closes a prompt as soon as any line that does
        // not look like a prompt arrives. On a real yay run extra output can
        // land between the question and the user answering it, which clears
        // `currentPromptKind` while the PHASE still says we are sitting at that
        // question — the popup would show the phase ("Exclude packages?") with
        // no way to answer it, a dead end. If the
        // phase says we are at a prompt and the process is still running, keep
        // offering the matching input.
        if (root._active && root.parser
            && root.parser.phase !== root._answeredPhase) {
            const byPhase = root._phasePromptKinds[root.parser.phase];
            if (byPhase) return byPhase;
        }

        // Last resort: the backend's own heuristic, read from the UNCOMMITTED
        // tail.
        //
        // A prompt that waits for input is, by definition, a line with no
        // newline yet — pacman writes ":: Proceed with installation? [Y/n] "
        // and blocks. The parser only ever sees committed lines, so it never
        // learns about that prompt at all, and the run dead-ends with the
        // question visible in the terminal and nothing to answer it with.
        // TerminalBackend does inspect the tail (that is how the sudo prompt
        // is caught), so trust it for yes/no too.
        if (root.backend && root.backend.awaitingInput) {
            const lp = root.backend.lastPrompt || "";
            if (/\[[yY]\/[nN]\]/.test(lp)) {
                if (/Proceed with install/i.test(lp)) return "pacman_proceed";
                if (/skip the above package/i.test(lp)) return "yay_skip_dep";
                return "yay_yesno";
            }
        }
        return "";
    }
    readonly property bool _promptVisible: root._promptDisplayKind.length > 0 && root.allowPromptReply
    // The words are yay's and pacman's own, so what the card asks is what
    // the terminal is asking. The hint goes in the field's placeholder, once;
    // a subtitle repeating it would say everything twice.
    readonly property string _promptTitle: {
        switch (root._promptDisplayKind) {
            case "pacman_proceed":     return "Proceed with installation?";
            case "yay_exclude":        return "Packages to exclude";
            case "yay_cleanbuild":     return "Packages to cleanBuild?";
            case "yay_diffs":          return "Diffs to show?";
            case "yay_edit_pkgbuild":  return "PKGBUILDs to edit?";
            case "yay_skip_dep":       return "Do you want to skip the above package for this upgrade?";
            case "yay_yesno":          return root._yesNoQuestion.length > 0
                                            ? root._yesNoQuestion + "?"
                                            : "";
            default: return "";
        }
    }
    // The question itself, in the tool's own words.
    //
    // The parser is asked first, and answers whenever it recognised the
    // question on a committed line. When it did not -- the banner can also be
    // opened straight off the terminal's uncommitted tail, which is the only
    // place a question lives until it is answered -- the tail IS the words,
    // so read them from there rather than a placeholder word ("Question").
    readonly property string _yesNoTail: {
        if (!root.backend || !root.backend.lastPrompt) return "";
        return String(root.backend.lastPrompt)
            .replace(/\s+$/, "")
            // The echoed answer, when the line has already committed.
            .replace(/\s*[yYnN]$/, "")
            .replace(/\s*\[[yY]\/[nN]\]\s*$/, "")
            // yay's ":: ", makepkg's "==> ".
            .replace(/^\s*(?:::|==>|->)\s*/, "")
            .replace(/\?\s*$/, "")
            .trim();
    }
    readonly property string _yesNoQuestion:
        (root.parser && root.parser.currentPromptText.length > 0)
            ? root.parser.currentPromptText : root._yesNoTail
    // Which button is the tool's own default, as "Y", "N" or "" when unknown.
    // The parser knows once it has matched the question; before that the
    // bracket in the tail says it, and marking neither button would leave the user
    // guessing which answer is the safe one.
    readonly property string _yesNoDefault: {
        if (root.parser && root.parser.currentPromptDefault.length > 0)
            return root.parser.currentPromptDefault;
        const lp = (root.backend && root.backend.lastPrompt) ? String(root.backend.lastPrompt) : "";
        const m = lp.match(/\[([yY])\/([nN])\]/);
        if (!m) return "";
        return m[1] === "Y" ? "Y" : (m[2] === "N" ? "N" : "");
    }

    // The lines yay printed just before a yes/no question: for the
    // skip-a-dependency prompt that is the warning naming the package, which
    // is the whole context the question needs.
    readonly property string _promptContext: {
        if (!root.parser || !root.parser.currentPromptContext) return "";
        if (root._promptDisplayKind !== "yay_skip_dep") return "";
        return root.parser.currentPromptContext.join("\n");
    }
    readonly property string _promptDetail: {
        switch (root._promptDisplayKind) {
            // ONLY the skip-a-dependency question. Its context IS pacman's
            // list of what cannot be upgraded -- the question is meaningless
            // without it. A plain yes/no ("Remove make dependencies after
            // install?") is self-contained, and the lines that happened to
            // come before it are whatever the build was printing at the time:
            // a checksum result, a curl meter. That is tty noise under a
            // question it has nothing to do with.
            case "yay_skip_dep":       return root._promptContext;
            default: return "";
        }
    }
    readonly property string _promptPlaceholder: {
        switch (root._promptDisplayKind) {
            case "yay_exclude":        return "eg: \"1 2 3\", \"1-3\", \"^4\" or repo name";
            case "yay_cleanbuild":
            case "yay_diffs":
            case "yay_edit_pkgbuild":  return "[N]one [A]ll [Ab]ort [I]nstalled [No]tInstalled or (1 2 3, 1-3, ^4)";
            default: return "";
        }
    }
    readonly property string _promptDefaultLabel: {
        switch (root._promptDisplayKind) {
            case "yay_exclude":        return "Exclude none";
            default:                   return "None";
        }
    }
    readonly property bool _promptIsList: root._promptDisplayKind === "yay_exclude"
        || root._promptDisplayKind === "yay_cleanbuild" || root._promptDisplayKind === "yay_diffs"
        || root._promptDisplayKind === "yay_edit_pkgbuild"
                                       || root._promptKind === "yay_cleanbuild"
                                       || root._promptKind === "yay_diffs"
                                       || root._promptKind === "yay_edit_pkgbuild"
    readonly property bool _promptIsYesNo: root._promptDisplayKind === "pacman_proceed"
        || root._promptDisplayKind === "yay_yesno" || root._promptDisplayKind === "yay_skip_dep"
                                        || root._promptKind === "yay_yesno"
    readonly property string _phase: root.parser ? root.parser.phase : "INITIAL"
    readonly property string _rawPhaseLabel: root.parser ? root.parser.phaseLabel : "Idle"

    // ---- The card's texts ---------------------------------------------------
    readonly property string _cardTitle: root._idle ? root._idleHeadline : root._phaseLabel
    readonly property string _cardSubA: root._idle ? root._idleSubtextShown : root._subLabel
    // Slot A exists in idle only (one subtitle line, blank when there is
    // nothing to say). During a run the title carries pacman's sub-phase, so a run
    // is always title plus the operation line, and the card's height never changes mid-run.
    readonly property bool _cardSubASlot: root._idle

    // ---- Animated ellipsis ---------------------------------------------------
    //
    // A trailing "…" in any card text is drawn as a cycling ". .. ..." instead
    // of three static dots. `_live(t)` swaps the suffix; the clock only runs
    // while some shown text actually ends in an ellipsis.
    property string _dots: "."
    readonly property bool _dotsNeeded: /(\.{3}|…)$/.test(root._cardTitle)
        || /(\.{3}|…)$/.test(root._cardSubA) || /(\.{3}|…)$/.test(root._currentOperation)
    function _live(t) {
        const m = String(t || "").match(/^(.*?)(\.{3}|…)$/);
        return m ? m[1] + root._dots : String(t || "");
    }
    Timer {
        interval: 420; repeat: true; running: root._dotsNeeded && root.visible
        onTriggered: root._dots = root._dots.length >= 3 ? "." : root._dots + "."
        onRunningChanged: if (!running) root._dots = "."
    }

    // ---- Idle subtitle, a beat late ----------------------------------------
    //
    // The "N official · M non-official" line appears 1.2s after the check
    // completes, not with it. The reader takes the headline in first, and
    // the list's silhouette gets to finish becoming the list before the
    // card above it grows a line and shifts everything.
    property string _idleSubtextShown: ""
    property int idleSubtextDelayMs: 1200
    on_ScanningChanged: {
        if (root._scanning) { idleSubtextTimer.stop(); root._idleSubtextShown = ""; }
        else idleSubtextTimer.restart();
    }
    on_IdleSubtextChanged: if (!root._scanning && !idleSubtextTimer.running) root._idleSubtextShown = root._idleSubtext
    Timer {
        id: idleSubtextTimer
        interval: root.idleSubtextDelayMs
        onTriggered: root._idleSubtextShown = root._idleSubtext
    }

    // ---- One prompt at a time, with a breath between ------------------------
    //
    // The banner shows `_promptDisplayKind`, which follows the real prompt
    // kind through a gate: a new question never replaces a shown one in
    // place, and never opens while the card is still shrinking from the
    // last one. yay's cleanBuild and diffs questions arrive back to back,
    // and swapping the text in place would leave the reader wondering whether
    // anything had changed. The gap is the card's own resize time.
    property string _promptDisplayKind: ""
    property real _promptClosedAtMs: 0
    // The handler waits for the content to be complete. Built while a question
    // stands (the bar builds this content on every open, mid-run), `_promptKind`
    // takes its first value INSIDE the first evaluation of `_promptIsList`, which
    // reads it beside `_promptDisplayKind`; a handler that wrote `_promptDisplayKind`
    // there and then would raise "Binding loop detected for property _promptIsList",
    // and the binding would stay false: the banner would open on the question with no
    // field and no buttons to answer it. Completion syncs once, outside any evaluation.
    property bool _promptReady: false
    on_PromptKindChanged: if (root._promptReady) root._syncPromptDisplay()
    function _syncPromptDisplay() {
        const want = root._promptKind;
        if (want === root._promptDisplayKind) { promptGapTimer.stop(); return; }
        if (want.length === 0) {
            // Closing: immediate.
            promptGapTimer.stop();
            root._promptDisplayKind = "";
            root._promptClosedAtMs = Date.now();
            return;
        }
        if (root._promptDisplayKind.length > 0) {
            // A different question while one is shown: close first, then open
            // after the shrink.
            root._promptDisplayKind = "";
            root._promptClosedAtMs = Date.now();
        }
        const since = Date.now() - root._promptClosedAtMs;
        const gap = root.containerResizeMs + 80;
        if (since >= gap) { root._promptDisplayKind = want; return; }
        promptGapTimer.interval = Math.max(1, gap - since);
        promptGapTimer.restart();
    }
    Timer {
        id: promptGapTimer
        onTriggered: root._promptDisplayKind = root._promptKind
    }
    readonly property string _rawSubLabel: root.parser ? root.parser.subPhaseLabel : ""

    // True when the backend is running but auth-time is still in progress:
    // no terminal output has arrived yet AND no password prompt has fired.
    // Covers Howdy face-scan (PAM auth via libcamera, no terminal text)
    // and the brief gap between sudo invocation and its prompt. As soon
    // as ANY line lands, parser advances past INITIAL — or the password
    // prompt fires — and this flips false; the existing phase / prompt
    // UI takes over.
    readonly property bool _authenticating: !!root.backend
        && root.backend.running
        && !root._passwordNeeded
        && root._phase === "INITIAL"
        && (!root.backend.linesModel || root.backend.linesModel.count === 0)
    // sudo is asking for the password -- the face unlock failed or is not set
    // up, or the ticket ran out mid-run. The run cannot go on without the
    // reader, and the parser's placeholder would read "Waiting…" over an empty
    // subtitle (after Howdy's "Failure, timeout reached"). It is asked through the authentication
    // toast (an askpass request stands), at any phase; a prompt on the
    // terminal itself means something bypassed askpass.
    readonly property bool _passwordNeeded: !!root.backend
        && root.backend.running
        && (root._askpassWaiting || root.backend.passwordPrompt === true)
    // Howdy says why it gave up on its own line, before sudo's prompt. Only
    // read while the password is being asked for, when the terminal holds a
    // handful of lines at most.
    readonly property bool _howdyTimedOut: {
        if (!root._passwordNeeded || !root.backend.linesModel) return false;
        const lm = root.backend.linesModel;
        for (let i = 0; i < Math.min(lm.count, 6); i++)
            if (/^Failure, timeout reached/.test(lm.get(i).raw)) return true;
        return false;
    }

    // The run's kind ("update" | "undo"); a parser that does not carry one (a mock, a probe's stub) is an update.
    readonly property string _runKind: (root.parser && root.parser.runKind) ? root.parser.runKind : "update"
    readonly property string _snapState: (root.parser && root.parser.snapshotState) ? root.parser.snapshotState : ""
    // The run ended BECAUSE no snapshot could be taken: pacman stopped before it changed anything.
    readonly property bool _snapFailed: root._completed && root._snapState === "failed"
    readonly property string _phaseLabel: {
        if (root._idle && root._phase === "INITIAL") return "No update running";
        if (root._authenticating) return "Authenticating…";
        if (root._passwordNeeded) return "Password required";
        if (root._snapFailed) return "No snapshot, so nothing was installed";
        if (root._completed && root.parser && root.parser.errorCount > 0)
            return "Finished with " + root.parser.errorCount + " error"
                + (root.parser.errorCount === 1 ? "" : "s");
        if (root._completed) return Work.endLabel(root._runKind, true);
        return root._workLabel;
    }
    // What the run is doing, whatever it is waiting for: the title of the
    // authentication toast says it too.
    // The words are SystemUpdateWork.js's: the service names the same work in
    // the authentication toast with this popup closed.
    readonly property string _workLabel:
        Work.workLabel(root._phase, root.parser ? root.parser.subPhase : "", root._rawPhaseLabel, root._runKind, root._snapState)
    // Never the title again: the parser's sub-phase label and the popup's
    // title can land on the same words ("Running post-install hooks" over
    // "Running post-install hooks"), and a subtitle that repeats the title
    // says nothing.
    readonly property string _subLabel: root._idle || root._rawSubLabel === root._phaseLabel
        ? "" : root._rawSubLabel
    // Slot B's figures: a count and, during the download, the bytes, the
    // rate and the time. Structured rather than one string, because each
    // figure sits in its own anchored slot on the card (DownloadStats) and
    // a digit gained on the right must not shove the ones on its left.
    function _progressInfo() {
        const none = {done: -1, total: -1, unit: "", bytesDone: 0, bytesTotal: 0, rate: "", eta: ""};
        if (!root.parser || root._idle) return none;
        const p = root.parser;
        // The AUR source fetch: curl's figures for the file on the wire.
        if (p.phase === "AUR_SRC_FETCH" && p.aurBuildsTotal > 0)
            return {done: p.aurSourcesDone, total: p.aurBuildsTotal, unit: "packages",
                    bytesDone: p.sourceFetchPct >= 0 ? p.sourceFetchBytesDone : 0,
                    bytesTotal: p.sourceFetchPct >= 0 ? p.sourceFetchBytesTotal : 0,
                    rate: p.sourceFetchRate, eta: p.sourceFetchEta};
        // pacman's question, and what saying yes commits to: the transaction's
        // package count and its Total Download Size, as plain totals (nothing
        // has moved yet, so no "0 / 43"). Only for the OFFICIAL transaction:
        // the AUR install's table has no download column, and the figure the
        // parser still holds then is the official one.
        if (root._promptKind === "pacman_proceed" && p.phase !== "AUR_INSTALL"
                && p.totalDownloadBytes > 0)
            return {done: -1, total: root._officialRunCount, unit: "packages",
                    bytesDone: -1, bytesTotal: p.totalDownloadBytes, rate: "", eta: ""};
        if (p.subPhase === "L2_DOWNLOAD" && p.downloadsTotal > 0) {
            let bd = 0, bt = 0;
            if (p.totalDownloadBytes !== undefined && p.totalDownloadBytes > 0) {
                // pacman's exact "so far" figure from the Total row when the
                // parser holds one; the integer-percent estimate only before
                // the first row and at the pinned 100% end state.
                bt = p.totalDownloadBytes;
                const exact = p.downloadPct < 100 && p.downloadSoFar !== undefined
                    ? Bytes.parseSize(p.downloadSoFar) : 0;
                bd = exact > 0 ? Math.min(exact, bt) : bt * Math.max(0, p.downloadPct) / 100;
            }
            return {done: p.downloadsDone, total: p.downloadsTotal, unit: "packages",
                    bytesDone: bd, bytesTotal: bt, rate: p.downloadRate || "", eta: p.downloadEta || ""};
        }
        const count = (d, t, u) => Object.assign({}, none, {done: d, total: t, unit: u});
        // the hook's percent has a slot of its own (snapPct): no hook counter beside it
        if (root._snapPercent >= 0) return none;
        if ((p.subPhase === "L5_CHANGES" || p.subPhase === "N5_CHANGES") && p.installsTotal > 0)
            return count(p.installsDone, p.installsTotal, "packages");
        if (p.subPhase === "L4_PREHOOKS" && p.hooksTotal > 0)
            return count(p.hooksDone, p.hooksTotal, "pre-transaction hooks");
        // AUR work outranks a leftover hook sub-phase.
        if ((p.phase === "AUR_SRC_FETCH" || p.phase === "AUR_BUILD_LOOP") && p.aurBuildsTotal > 0)
            return count(p.aurBuildsDone, p.aurBuildsTotal, "AUR built");
        if ((p.subPhase === "L6_POSTHOOKS" || p.subPhase === "N6_POSTHOOKS") && p.hooksTotal > 0)
            return count(p.hooksDone, p.hooksTotal, "hooks");
        return none;
    }
    // ONE call, seven readers. Each reader invoking `_progressInfo()` itself would
    // capture the same dozen parser properties, so any one of them changing would
    // re-run all seven -- seven object literals and, in the download branch, seven
    // `Bytes.parseSize` regexes to produce one set of figures. A real capture drives
    // ~3,800 parser notifies through a download: ~26,000 calls where 3,800 do.
    //
    // The seven stay TYPED properties on purpose: QML suppresses a same-value
    // write per property, so a re-evaluation that yields an unchanged rate still
    // emits no change to DownloadStats. And the var below activates its dependents
    // inside the same change propagation, so the figures land on the same frame --
    // deferring them through Qt.callLater would change what is drawn.
    readonly property var    _progress:           root._progressInfo()
    readonly property int    _progressDone:       root._progress.done
    readonly property int    _progressTotal:      root._progress.total
    readonly property string _progressUnit:       root._progress.unit
    readonly property real   _progressBytesDone:  root._progress.bytesDone
    readonly property real   _progressBytesTotal: root._progress.bytesTotal
    readonly property string _progressRate:       root._progress.rate
    readonly property string _progressEta:        root._progress.eta
    // Slot B has something to show: an operation (not in quiet, which
    // never names one) or a figure.
    // ---- Concurrent downloads -------------------------------------------
    readonly property var _dlNames: (root.parser && root.parser.downloadingNames)
        ? root.parser.downloadingNames : []
    readonly property bool _inDownloadOp: !!root.parser
        && root.parser.subPhase === "L2_DOWNLOAD" && root._dlNames.length > 0
    // How long each window of names is held before the next one is shown,
    // when there are more in flight than the line can hold.
    property int downloadNameCycleMs: 2000
    property int _dlCycle: 0
    Timer {
        // Only when there is something the line cannot show: with everything
        // visible, rotating the order would be movement for its own sake.
        running: root._inDownloadOp
                 && slotB._opFitted.shown < root._dlNames.length
        interval: root.downloadNameCycleMs
        repeat: true
        onTriggered: root._dlCycle = root._dlCycle + 1
    }
    // The property is `_dlNames`, so its signal is `_dlNamesChanged`.
    on_DlNamesChanged: if (root._dlNames.length === 0) root._dlCycle = 0

    // The snapshot's percent, from the hook's progress lines (-1: none to show). Drawn in its own slot of the card.
    readonly property int _snapPercent: (root.parser && !root._idle && root.parser.subPhase === "L4_PREHOOKS"
                                         && root._snapState === "running" && root.parser.snapshotProgress >= 0)
        ? Math.round(root.parser.snapshotProgress * 100) : -1
    readonly property bool _slotBHasContent: root._progressTotal > 0
        || root._currentOperation.length > 0

    // What's happening right NOW. Empty string when idle / completed — we
    // don't want "mkinitcpio linux []" sticking around after the run finishes.
    readonly property string _currentOperation: {
        if (!root.parser || root._idle) return "";
        // Howdy / PAM auth window before sudo prints anything. Tells the
        // user the camera is in use; if it fails the password prompt
        // fires and the regular awaiting-input path takes over.
        if (root._authenticating) return "verifying with Howdy or sudo";
        if (root._passwordNeeded) {
            if (!root._askpassWaiting) return "sudo is asking on the terminal";
            return root._howdyTimedOut ? "Howdy timed out, answer in the toast" : "answer in the toast";
        }
        const p = root.parser;
        if (p.awaitingUserInput) return "waiting for your input";
        if (p.phase === "DB_SYNC_1" || p.phase === "DB_SYNC_2") return "syncing package databases";
        if (p.phase === "AUR_SEARCH") return "querying AUR";
        if (p.phase === "UPGRADE_LIST") return "gathering upgrade list";
        if (p.phase === "GROUPED_SUMMARY") return "building dependency graph";
        if (p.phase === "PKGBUILD_CACHE") return "checking PKGBUILD cache";
        if (p.phase === "SRCINFO_PARSE") return "parsing SRCINFO files";
        // EVERY package in flight, not the last row printed. pacman runs 20
        // downloads at once and prints a row per file several times a second,
        // so `currentDownloading` flips through the whole set and the line would
        // flicker between twenty names. What is shown on the card is this
        // list trimmed to the room and cycled (see `_opFitted` in slot B);
        // this is the full truth, which is also what the run recorder logs.
        if (root._inDownloadOp)
            return "downloading " + root._dlNames.join(", ");
        if (p.subPhase === "L2_DOWNLOAD" && p.currentDownloading) return "downloading " + p.currentDownloading;
        if (p.subPhase === "L3_INTEGRITY" || p.subPhase === "N3_INTEGRITY") return "integrity — " + p.integrityStep;
        if ((p.phase === "AUR_SRC_FETCH" || p.phase === "AUR_BUILD_LOOP") && p.currentAurBuild)
            return p.currentAurBuild + " — " + p.currentAurBuildStep;
        // The snapshot hook: the title says it is being taken, the line says what it is for.
        if (p.subPhase === "L4_PREHOOKS" && root._snapState === "running") {
            const names = Work.snapshotNames(p.snapshotText);
            return names.length > 0 ? "before " + (root._runKind === "undo" ? "downgrading " : "updating ") + names
                                    : (root._runKind === "undo" ? "before the downgrade" : "before the update");
        }
        if ((p.subPhase === "L4_PREHOOKS" || p.subPhase === "L6_POSTHOOKS" || p.subPhase === "N6_POSTHOOKS") && p.currentHook) {
            if (p.currentInitramfsKernel && p.currentInitramfsHook)
                return "mkinitcpio " + p.currentInitramfsKernel + " [" + p.currentInitramfsHook + "]";
            if (p.currentDkmsOp) return "DKMS " + p.currentDkmsOp;
            return "hook: " + p.currentHook;
        }
        if ((p.subPhase === "L5_CHANGES" || p.subPhase === "N5_CHANGES") && p.currentInstalling)
            return (root._runKind === "undo" ? "downgrading " : "installing ") + p.currentInstalling;
        if (p.phase === "FINAL_ERRORS") return "collecting failure report";
        return "";
    }

    // =================================================================
    //  PHASE STEPPER
    //
    // The run's journey, as distinct from the header's "what is happening
    // now". Steps are built per run so a transaction with no AUR packages
    // never shows an AUR node that cannot light up.
    // =================================================================
    // Per-package summaries, recomputed on a short debounce rather than as
    // bindings on the model's count.
    //
    // As bindings these would re-run on EVERY append. A transaction arrives one
    // package at a time, so a 69-package resolve re-walks the list 69 times
    // over — and worse, `_runCategories` would hand the Repeater a brand-new array
    // each time, tearing down and rebuilding every category section with all
    // its row delegates (measured: 1783 ms of blocked UI thread for 69
    // packages, and a real run carries 218). Coalescing the burst makes it one
    // rebuild instead of N.
    property bool _hasAurWork: false
    // The run has a Snapshot notch: the service is ready and its rule wants one for this run's packages, or the hook
    // has spoken. Latched like the AUR one, written ONLY from _recomputePackageSummary (a handler, never a
    // binding or the notch list's own change handler), and settled long before the notch is reached: the list
    // of packages is read at resolve, the snapshot comes after the download.
    property bool _hasSnapshotWork: false
    property var  _runCategories: []
    // Packages in the official transaction -- everything the run's categories
    // count that is not AUR. Read off the summary the sections are built from,
    // so it costs nothing extra.
    readonly property int _officialRunCount: {
        let n = 0;
        for (let i = 0; i < root._runCategories.length; i++)
            if (root._runCategories[i].key !== "aur") n += root._runCategories[i].count;
        return n;
    }

    // The category list the sections are built from, as a ListModel rather
    // than a fresh array per change. A Repeater over an array rebuilds
    // every delegate when the array is reassigned; over a ListModel it
    // creates and removes only the rows that actually changed. That is what
    // lets the idle list simply STAY when an update starts: the run's
    // categories are the cached ones plus whatever the parser adds later,
    // reconciled in place, so a package that appeared between the last
    // check and the sync is one inserted row, not a redrawn list.
    ListModel { id: categoryModel }

    // Which category leads the list. AUR leads during its own step: it is the
    // only one doing anything and the others are shut, so leaving it under
    // three closed headers buries the one list that is moving.
    //
    // The rule lives HERE, on the merged list, rather than where the run's own
    // categories are built -- there it would be discarded for any category
    // the idle scan had already reported, because `_desiredCategories` takes
    // POSITION from the service and only the count from the run.
    //
    // "" is the run's own decision; the mockup's debug tool forces either.
    property string categoryOrderOverride: ""
    function _categoryLead() {
        if (root.categoryOrderOverride === "aur-first") return "aur";
        if (root.categoryOrderOverride === "aur-last")  return "";
        // `_currentStep` HOLDS once the process exits (see _updateStep), so a
        // finished run keeps the order it ended on. Re-sorting the list the
        // instant the process dies would be a change with no event behind it, and
        // without even the flight -- the list would simply snap back.
        return root._currentStep === "aur" ? "aur" : "";
    }
    function _applyCategoryOrder(list) {
        const lead = root._categoryLead();
        if (lead.length === 0) return list;
        for (let i = 1; i < list.length; i++)
            if (list[i].catKey === lead) {
                const out = list.slice();
                out.unshift(out.splice(i, 1)[0]);
                return out;
            }
        return list;
    }
    onCategoryOrderOverrideChanged: root._reconcileCategories()

    function _desiredCategories() {
        const out = [], seen = {};
        if (root._hasService) {
            const cs = root.availableUpdates.categories || [];
            for (let i = 0; i < cs.length; i++) {
                seen[cs[i].key] = out.length;
                out.push({catKey: cs[i].key, catLabel: cs[i].label, catCount: cs[i].count});
            }
        }
        if (root._showingRun) {
            for (let i = 0; i < root._runCategories.length; i++) {
                const c = root._runCategories[i];
                if (seen[c.key] !== undefined) out[seen[c.key]].catCount = c.count;
                else { seen[c.key] = out.length; out.push({catKey: c.key, catLabel: c.label, catCount: c.count}); }
            }
        }
        return root._applyCategoryOrder(out);
    }
    // The reorder is intercepted HERE, the one place the model's order can
    // change, so every caller is covered by one hook. A flight is warranted
    // only when exactly one key relocated and the SET is otherwise identical:
    // an insert or a removal in the same call goes instantly, because the
    // flight's destination is summed from a list it assumes already exists.
    //
    // NO FLIGHT WHERE THERE IS NO LIST. The flight's ghost is drawn in an overlay over the
    // whole popup, and in quiet the list it was lifted from is hidden: the AUR step
    // (the category taking the lead) would show a header flying across the status card.
    // Where the list body is not shown the order is simply applied -- nothing is on screen
    // to teleport -- and the list is in its new order when the view next shows it.
    readonly property bool _listShown: root.verbosityMode !== "quiet"
    function _reconcileCategories() {
        const want = root._desiredCategories();
        const k = root._soleRelocation(want);
        if (k.length > 0 && root.sectionFlightEnabled && root.visible && root._listShown
                && !sectionFlight.active && root._beginSectionFlight(k, want))
            return;
        root._applyCategories(want);
    }
    // "" unless exactly one key changed place and nothing came or went.
    function _soleRelocation(want) {
        if (want.length !== categoryModel.count) return "";
        const cur = [];
        for (let i = 0; i < categoryModel.count; i++) cur.push(categoryModel.get(i).catKey);
        const nxt = want.map(x => x.catKey);
        for (const key of nxt) if (cur.indexOf(key) < 0) return "";
        if (cur.join() === nxt.join()) return "";
        // Every key that explains the whole change on its own. With TWO
        // categories a swap has two such keys -- take either one out and the
        // other is where it was -- so requiring exactly one would make the
        // commonest real list (extra + aur) teleport every time.
        const candidates = [];
        for (const key of nxt) {
            const a = cur.filter(x => x !== key), b = nxt.filter(x => x !== key);
            if (a.every((v, i) => v === b[i])) candidates.push(key);
        }
        if (candidates.length === 0) return "";
        if (candidates.length === 1) return candidates[0];
        // Ambiguous: fly the one that is being PROMOTED. It is the one the
        // reorder is about -- AUR taking the lead because it is the category
        // that is working -- and the others reading as making room for it is
        // the story the motion is telling.
        let best = candidates[0], bestMove = -1;
        for (const key of candidates) {
            const move = cur.indexOf(key) - nxt.indexOf(key);   // > 0 = moved up
            if (move > bestMove) { bestMove = move; best = key; }
        }
        return best;
    }
    function _applyCategories(want) {
        for (let i = categoryModel.count - 1; i >= 0; i--)
            if (!want.some(w => w.catKey === categoryModel.get(i).catKey)) categoryModel.remove(i);
        for (let i = 0; i < want.length; i++) {
            let at = -1;
            for (let j = i; j < categoryModel.count; j++)
                if (categoryModel.get(j).catKey === want[i].catKey) { at = j; break; }
            if (at < 0) { categoryModel.insert(i, want[i]); continue; }
            if (at !== i) categoryModel.move(at, i, 1);
            if (categoryModel.get(i).catCount !== want[i].catCount)
                categoryModel.setProperty(i, "catCount", want[i].catCount);
            if (categoryModel.get(i).catLabel !== want[i].catLabel)
                categoryModel.setProperty(i, "catLabel", want[i].catLabel);
        }
        root._categoryOrderSerial = root._categoryOrderSerial + 1;
    }
    // Bumped whenever the model's ORDER changes. A binding that walks
    // categoryModel does not re-evaluate on `move` -- ListModel emits no
    // change a binding can see for a reorder, and `count` has not moved -- so
    // the section margins would keep a stale answer and the first section would carry a
    // gap it should not have. Every binding below reads this first.
    property int _categoryOrderSerial: 0
    function _categoryKeys() {
        const out = [];
        for (let i = 0; i < categoryModel.count; i++) out.push(categoryModel.get(i).catKey);
        return out;
    }
    Connections {
        target: root.availableUpdates
        ignoreUnknownSignals: true
        function onCategoriesChanged() { root._reconcileCategories() }
        // A check that lands after the run ended and finds updates ends the overview: the
        // finished run stays on screen until the popup is hidden or the next run starts, and
        // a popup left open meanwhile would keep listing what was updated over the one new package
        // the check had just found. Only an idle popup, only a check
        // that began after the run ended, never one that found nothing ("Update complete" holds).
        function onRefreshFinished(count) {
            if (count > 0 && root._idle && root._refreshedSinceRun)
                root.dismissRunOverview();
        }
    }
    onAvailableUpdatesChanged: root._reconcileCategories()

    function _recomputePackageSummary() {
        if (!root.parser) {
            root._hasAurWork = false;
            root._hasSnapshotWork = false;
            if (root._runCategories.length > 0) root._runCategories = [];
            root._reconcileCategories();
            return;
        }
        const m = root.parser.packages;
        // THE PARSER STILL HOLDS THE RUN THAT ENDED for the beat between a new run's `running`
        // and its started() (see _updateStep): its AUR rows are not this run's. Counted, they
        // would set the latch below to true again straight after on_IdleChanged had cleared it for
        // the new run -- one of the two writes that would make the notch list's binding loop.
        const staleRun = !root._idle && root.parser.exitCode >= 0;
        let aur = false;
        const counts = ({});
        const officialNames = [];
        for (let i = 0; i < m.count; i++) {
            const p = m.get(i);
            if (p.isAur) aur = true;
            else officialNames.push(p.name);
            const n = p.name;
            const k = p.isAur ? "aur" : (p.repo && p.repo.length > 0 ? p.repo : "extra");
            counts[k] = (counts[k] || 0) + 1;
        }
        // Latched for the run. yay's skip-a-dependency answer, an exclusion,
        // a re-added row: the AUR package can leave the model and come back,
        // and the notch list must not follow it out and in.
        root._hasAurWork = (aur && !staleRun) || (!root._idle && root._hasAurWork);
        // The hook is in the official transaction, so the rule asks about its packages -- as soon as the list has
        // rows (a rule that says yes on part of the list says yes on all of it, and the settle timer asks once more
        // before the ball leaves Sync), and for good once the hook speaks.
        const listRead = root._runKind === "undo" || (!!root.parser && root.parser.phase !== "INITIAL"
            && root.parser.phase !== "DB_SYNC_1" && root.parser.phase !== "AUR_SEARCH");
        // A hook that is WORKING (running, done) makes the notch whatever the rule said; one that skips
        // never adds it (the rule was right), and with no service in the shell there is no notch at all.
        const hookWorks = !!root.snapshots && (root._snapState === "running" || root._snapState === "done");
        const wants = !staleRun && (hookWorks || (root._snapReady && listRead
            && officialNames.length > 0 && Work.wantsYes(root.snapshots.wantsFor(officialNames))));
        root._hasSnapshotWork = wants || (!root._idle && root._hasSnapshotWork);

        // Plain rank order. Which category LEADS is decided once, on the
        // merged list, in _applyCategoryOrder -- deciding it here would reach the
        // model only for a category the service has never reported.
        const order = ["core", "extra", "multilib", "aur"];
        const out = [];
        if (root._showingRun) {
            for (const k of order)
                if (counts[k]) out.push({key: k, label: root.categoryLabel(k), count: counts[k]});
            for (const k in counts)
                if (order.indexOf(k) < 0)
                    out.push({key: k, label: root.categoryLabel(k), count: counts[k]});
        }
        // Only hand the Repeater a new array when the categories actually
        // changed. Assigning an equal-but-distinct array still rebuilds every
        // delegate, which is most of what made this expensive.
        const cur = root._runCategories;
        let same = cur.length === out.length;
        if (same) {
            for (let i = 0; i < out.length; i++) {
                if (cur[i].key !== out[i].key || cur[i].count !== out[i].count) {
                    same = false;
                    break;
                }
            }
        }
        if (!same) root._runCategories = out;
        root._reconcileCategories();
    }

    Timer {
        id: pkgSummaryTimer
        interval: 50
        repeat: false
        onTriggered: root._recomputePackageSummary()
    }

    Connections {
        target: root.parser ? root.parser.packages : null
        ignoreUnknownSignals: true
        function onCountChanged() { pkgSummaryTimer.restart() }
    }
    // The latch is re-read when the run reaches the point the rule can be asked (the phase moves past the list)
    // and when the hook speaks.
    Connections {
        target: root.parser
        ignoreUnknownSignals: true
        function onSnapshotStateChanged() { pkgSummaryTimer.restart() }
        function onPhaseChanged() { if (root._snapReady) pkgSummaryTimer.restart() }
    }
    onParserChanged: root._recomputePackageSummary()
    Component.onCompleted: {
        root._recomputePackageSummary();
        // A host that builds this content on open, mid-run, hands over a
        // parser whose list is already full: no count change will ever come
        // to settle `_runListSettled`, and the run's list would never be shown.
        if (root._parserHasPackages) runListSettleTimer.restart();
        // visibleChanged never fires for an item created already visible (a
        // host that builds the content on open), so ask here as well.
        if (root.visible && root._idle) root.refreshRequested();
        root._askClock();
        root._askSnapClock();
        root._promptReady = true;
        root._tabsReady = true;
        root._syncPromptDisplay();
        // A CONTENT BORN MID-RUN SEATS ITS BALL where the run stands. The step and its
        // progress are written a turn later by their own handlers (the progress through
        // Qt.callLater), so the facts are settled here by hand, the notch list first
        // (_recomputePackageSummary above), and only then is the ball put on its target:
        // no flight from notch 0, no sparks, nothing that reads as a rebuild. Live
        // progress from here on moves the ball as it always did.
        root._updateStep();
        root._updateStepProgress();
        phaseRail.seat();
    }

    // The rail's notches for THIS run. A transaction with no AUR packages
    // never shows an AUR notch that cannot light up, and the same for kernel
    // work — both flags settle at resolve time so the notch count holds for
    // the rest of the run rather than re-spacing mid-flight.
    readonly property var _phaseSteps: {
        // An undo is pacman -U of old packages: nothing to sync, nothing to download.
        const undo = root._runKind === "undo";
        const out = undo ? [{key: "resolve", label: "Resolve"}] : [
            {key: "sync",     label: "Sync"},
            {key: "resolve",  label: "Resolve"}
        ];
        // yay fetches and validates AUR sources BEFORE the official
        // transaction, then builds and installs them after it. Without a notch
        // for that first half the ball would shoot to AUR and straight back, because
        // the only place the phase could map to is the last step.
        if (root._hasAurWork) out.push({key: "sources", label: "Sources"});
        if (!undo) out.push({key: "download", label: "Download"});
        // The snapshot the pre-transaction hook takes: its own notch only in a run that has one.
        if (root._hasSnapshotWork) out.push({key: "snapshot", label: "Snapshot"});
        out.push({key: "install",  label: "Install"});
        out.push({key: "hooks",    label: "Hooks"});
        // No "Kernel" notch. Kernel work is not a phase of its own: DKMS
        // removal is a pre-transaction hook, DKMS builds and mkinitcpio are
        // post-transaction hooks 9 and 10 of 11 on this machine, with a bus
        // reload after them. A notch for it after Hooks would be reached -- and then
        // held, because the ball never goes backwards -- the moment the first DKMS line
        // appeared during the PRE-hooks, which would make the install and the hooks look
        // skipped. It is shown as the operation text inside Install and Hooks.
        if (root._hasAurWork)    out.push({key: "aur",    label: "AUR"});
        return out;
    }

    // The single package a step is focused on, where a step has one.
    //
    // Download has twenty concurrent transfers and no single focus, so it is
    // deliberately excluded — those rows carry their own rate and ETA instead.
    readonly property string _activePackage: {
        if (!root.parser || root._idle) return "";
        const p = root.parser;
        if (root._currentStep === "aur") return p.currentAurBuild || "";
        if (root._currentStep === "install") return p.currentInstalling || "";
        return "";
    }
    readonly property string _activeDetail: {
        if (!root.parser || root._idle) return "";
        const p = root.parser;
        if (root._currentStep === "aur") return p.currentAurBuildStep || "";
        if (root._currentStep === "install") return root._runKind === "undo" ? "downgrading" : "installing";
        return "";
    }

    // Categories reopen only for a step that will work through them.
    //
    // Download and install put every package back in play, so the list should
    // be open and full for the new step to drain. Hooks, kernel work and the
    // rest do not touch the package list at all — reopening for those would
    // undo the draining that just finished and leave a full list sitting there
    // with nothing happening to it.
    on_CurrentStepChanged: {
        if (root._idle) return;
        // The category ORDER depends on the step (AUR leads during its own),
        // and the summary is otherwise only recomputed when the model changes.
        // This is what can start a header flight, so it goes first.
        //
        // The ORDER only: `_recomputePackageSummary` also WRITES `_hasAurWork`, which the
        // notch list (`_phaseSteps`) is a binding on, and this handler runs inside the
        // notch list's own change handler (`on_PhaseStepsChanged` -> `_updateStep` ->
        // here). A change handler of a binding that writes what the binding reads is a
        // binding loop -- and the loop does not only warn, it leaves the binding holding
        // the OLD notches. The step changes nothing the summary is made of.
        root._reconcileCategories();
        // Read from _currentStep directly: a derived binding is not guaranteed
        // to have re-evaluated when this handler runs.
        const step = root._currentStep;
        // TWO FACTS, IN SEQUENCE. The reorder is one thing; opening the
        // category that is about to work and shutting the rest is another.
        // Run together they are two clocks: every section's height is
        // animating while the flight measures where it is going and how big
        // the space it needs is, and neither number holds. Held back, it reads
        // as a story -- the header arrives, and then its list opens under it.
        if (sectionFlight.active) { root._pendingStepExpansion = step; return; }
        root._applyStepExpansion(step);
    }
    property string _pendingStepExpansion: ""
    // A STEP DOES NOT REARRANGE THE LIST: setting every category's expanded
    // state explicitly at every step change would shut a category the user had
    // opened during the source fetch for the download, open it again for the
    // install and shut it again for the hooks -- the list rearranging itself four
    // times under someone who has already said how they want it.
    //
    // The only step that imposes anything is AUR, and it earns it: it is the
    // one step where a single category does all the work and the others have
    // nothing to show, so burying the one that is moving under three shut
    // headers is worse than moving them out of the way. Every other step drops
    // the run's overlay, which puts each category back to the user's own
    // state -- including one that drained itself and asked to be shut, because
    // the new step has work for those rows again.
    function _applyStepExpansion(step) {
        if (step !== "aur") { root._clearRunOverlay(); return; }
        const next = ({});
        for (const k in root._sectionExpanded)
            if (k.indexOf("run:") !== 0) next[k] = root._sectionExpanded[k];
        for (let i = 0; i < root._runCategories.length; i++)
            next["run:" + root._runCategories[i].key] =
                (root._runCategories[i].key === "aur");
        root._sectionExpanded = next;
    }

    // Which categories a pending "proceed?" actually covers.
    //
    // yay asks twice — once for the official transaction and again for the AUR
    // one — and the question does not say which. With every category collapsed
    // by then, lighting the relevant headers' stripes is enough to answer it,
    // and it reuses the stripe the progress indicator already drives.
    readonly property var _promptCategories: {
        if (!root.parser || root._idle) return [];
        if (root._promptKind !== "pacman_proceed") return [];
        const aurPhase = root.parser.phase === "AUR_INSTALL";
        const out = [];
        for (let i = 0; i < root._runCategories.length; i++) {
            const k = root._runCategories[i].key;
            if ((k === "aur") === aurPhase) out.push(k);
        }
        return out;
    }

    // yay's menu numbers belong on the rows only while it is parked at one of
    // its numbered prompts — excluding packages, choosing diffs, choosing
    // clean builds. Those are the moments the number is the thing you type.
    // Everywhere else it is a column of noise, so it takes no space.
    readonly property bool _showPackageNumbers: {
        if (!root.parser || root._idle) return false;
        // The real kinds are prefixed by the tool that asked — matching the
        // unprefixed names would never fire in a real run.
        const k = root._promptKind;
        return k === "yay_exclude" || k === "yay_diffs"
            || k === "yay_cleanbuild" || k === "yay_edit_pkgbuild";
    }

    // How far through the CURRENT step, or -1 when the step has nothing
    // countable to report.
    //
    // Only whole steps move the ball along the rail, so this is progress
    // WITHIN one step and never leaks across a notch. Sync finishing its
    // database list does not creep toward Resolve: the ball's position claims
    // how much of the run is done, and a groove filled past a step that has
    // not started would be claiming work that has not happened.
    // Progress within the step never walks backwards, the same policy the
    // step itself follows. Sampled at the end of the event rather than on
    // each change: the parser switches sub-phase BEFORE it resets the
    // counters for it, and a mark raised from that half-updated state
    // (hooks 1/1 from the pre-hooks read as the post-hooks' 100%) could
    // never be lowered again.
    property real _stepProgress: -1
    property string _stepProgressStep: ""
    on_RawStepProgressChanged: Qt.callLater(root._updateStepProgress)
    function _updateStepProgress() {
        const raw = root._rawStepProgress;
        if (root._currentStep !== root._stepProgressStep) {
            root._stepProgressStep = root._currentStep;
            root._stepProgress = raw;
        } else if (raw > root._stepProgress || raw < 0) {
            root._stepProgress = raw;
        }
    }
    readonly property real _rawStepProgress: {
        if (!root.parser || root._idle) return -1;
        const p = root.parser;
        switch (root._currentStep) {
            // Packages whose sources are in, plus curl's share of the one
            // being fetched.
            case "sources":
                if (p.aurBuildsTotal <= 0) return -1;
                return Math.min(1, (p.aurSourcesDone
                    + (p.sourceFetchPct >= 0 ? p.sourceFetchPct / 100 : 0)) / p.aurBuildsTotal);
            case "download":
                if (p.downloadPct >= 0) return p.downloadPct / 100;
                if (p.downloadsTotal > 0) return p.downloadsDone / p.downloadsTotal;
                return -1;
            case "install": {
                // Pre-transaction hooks take the first tenth of the step,
                // the package changes the rest, so the groove never runs
                // backwards when the hooks hand over to the changes.
                const PRE = 0.1;
                if (p.subPhase === "L4_PREHOOKS")
                    return p.hooksTotal > 0 ? PRE * (p.hooksDone / p.hooksTotal) : 0;
                if (p.subPhase === "L5_CHANGES" || p.subPhase === "N5_CHANGES")
                    return p.installsTotal > 0 ? PRE + (1 - PRE) * (p.installsDone / p.installsTotal) : PRE;
                return 0;
            }
            // The hook's own percent (-1 until it has said it started: the ball rests).
            case "snapshot":
                return p.snapshotState === "done" ? 1 : p.snapshotProgress;
            case "hooks":
                return p.hooksTotal > 0 ? p.hooksDone / p.hooksTotal : -1;
            case "aur":
                return p.aurBuildsTotal > 0 ? p.aurBuildsDone / p.aurBuildsTotal : -1;
        }
        return -1;
    }

    // Which step the parser's phase/subPhase belongs to.
    // The furthest step reached this run. The ball never walks backwards.
    //
    // yay revisits earlier-looking phases mid-run — it syncs the databases a
    // second time before the official transaction, and parses SRCINFO after
    // fetching sources — and mapping those to their literal step would send the ball
    // back to Sync and Resolve after it has already moved on. A rail that goes
    // backwards is worse than one that is briefly imprecise: it says work was
    // undone, which never happens.
    // `_currentStep` is written by ONE function, from the raw step and the
    // high-water mark, rather than bound to both. As a binding it would depend
    // on the high-water mark, which the raw step's change handler writes while the
    // binding is being re-evaluated for that same change -- QML would report it
    // as a binding loop on every step, and re-run the whole dependent chain.
    // The furthest notch reached, by KEY. As an index it would be re-read
    // against a notch list that has just lost (or regained) its Sources and
    // AUR notches, and index 3 of the shorter list is Install: the ball would
    // "shoot to install" during the download, then back.
    property string _maxStepKey: ""
    property string _currentStep: ""
    on_RawStepChanged: {
        // The header line that moves the phase to UPGRADE_LIST arrives BEFORE
        // any row, so a hold keyed off the row count alone would never engage.
        // Arm it the moment the raw step first leaves Sync; the row appends
        // then keep it armed until the list is quiet.
        if (root._currentStep === "sync" && root._rawStep !== "sync" && root._rawStep !== "") {
            root._stepsSettled = false;
            stepsSettleTimer.restart();
        }
        root._updateStep();
    }
    on_PhaseStepsChanged: root._updateStep()
    // The notch list is not final until yay's upgrade list has been read in
    // full: an AUR row anywhere in it inserts two notches, and re-spacing
    // the rail while the ball is already travelling to Resolve would send it
    // backwards. Leaving Sync therefore waits until the package model has
    // been quiet for `stepsSettleMs` -- comfortably longer than the 50ms
    // summary debounce, so `_phaseSteps` is final by then. Everything that
    // keys off `_currentStep` (category order, drains, the rail) waits with
    // it, as one.
    property int stepsSettleMs: 400
    property bool _stepsSettled: true
    Timer {
        id: stepsSettleTimer
        interval: root.stepsSettleMs
        // The notch list is read one last time BEFORE the ball may leave Sync (a Snapshot notch decided after
        // would re-space the rail under a ball already travelling).
        onTriggered: { root._recomputePackageSummary(); root._stepsSettled = true; root._updateStep(); }
    }
    Connections {
        target: root.parser ? root.parser.packages : null
        ignoreUnknownSignals: true
        function onCountChanged() {
            if (root._currentStep === "sync" || root._currentStep === "") {
                root._stepsSettled = false;
                stepsSettleTimer.restart();
            }
            if (!root._runListSettled) runListSettleTimer.restart();
        }
    }
    // THE RUN'S LIST IS READ BEFORE IT IS SHOWN. Taking the parser's list the
    // moment it holds ONE package would show it as yay prints its upgrade list, a
    // line at a time: a shut category's favourites would drop to none (the run's
    // list has no AUR row yet) and come back one by one as their lines arrive --
    // 2, 0, 1, 2 inside the upgrade list. The
    // idle list stays until the parser's list has been quiet for as long as
    // the rail waits for it, and then the switch happens once.
    //
    // A latch of its own rather than `_stepsSettled`: that one is re-armed by
    // the same count change that makes `_parserHasPackages` true, so a binding
    // reading both could see them from two generations and flip for one
    // evaluation. This one is already false when the first package lands.
    property bool _runListSettled: false
    Timer {
        id: runListSettleTimer
        interval: root.stepsSettleMs
        onTriggered: root._runListSettled = true
    }
    function _updateStep() {
        if (root._idle) {
            // A HELD OVERVIEW KEEPS ITS BALL. Clearing the step the moment the
            // process exits would send the ball back to the first notch -- and on a
            // run that ended in an ERROR that would read as "it failed at the very
            // beginning", the opposite of what happened. The overview
            // is dismissed (or a new run starts) before this resets.
            if (root._runHeld || root._parserHasPackages) return;
            root._maxStepKey = ""; root._currentStep = ""; return;
        }
        if (!root._stepsSettled && root._currentStep === "sync") return;
        // The backend flips `running` BEFORE it emits started(), and the
        // parser only reset()s on started(), so the first call for a new run
        // still sees the previous run's final phase. Drop the high-water mark
        // when the parser is back at INITIAL rather than only on the idle edge.
        if (root.parser && root.parser.phase === "INITIAL") root._maxStepKey = "";
        const raw = root._rawStep;
        const i = root._indexOfStep(raw);
        let maxI = root._indexOfStep(root._maxStepKey);
        if (i > maxI) { maxI = i; root._maxStepKey = raw; }
        // A raw key with no notch ("aur" before the AUR notch exists) keeps
        // the furthest notch reached rather than handing the rail a key it
        // cannot place.
        root._currentStep = (maxI >= 0 && (i < 0 || maxI > i))
            ? root._phaseSteps[maxI].key : raw;
        Qt.callLater(root._updateStepProgress);
    }
    function _indexOfStep(key) {
        for (let i = 0; i < root._phaseSteps.length; i++)
            if (root._phaseSteps[i].key === key) return i;
        return -1;
    }


    readonly property string _rawStep: {
        if (!root.parser || root._idle) return "";
        const p = root.parser;
        switch (p.phase) {
            // Authentication happens before any output arrives. It belongs to
            // the first notch rather than falling through to the default,
            // which would put the ball two steps ahead of the run before it starts.
            case "INITIAL":
                return root._runKind === "undo" ? "resolve" : "sync";
            case "COMPLETE": case "DONE":
                return root._phaseSteps.length > 0
                    ? root._phaseSteps[root._phaseSteps.length - 1].key : "";
            case "DB_SYNC_1": case "DB_SYNC_2": case "AUR_SEARCH":
                return "sync";
            case "UPGRADE_LIST": case "GROUPED_SUMMARY":
            case "PKGBUILD_CACHE": case "SRCINFO_PARSE":
            case "PROMPT_EXCLUDE": case "PROMPT_CLEANBUILD":
            case "PROMPT_DIFFS":   case "PROMPT_EDIT_PKGBUILD":
                return "resolve";
            // Source retrieval and SRCINFO parsing are the FIRST half of the
            // AUR work and happen before the official transaction; building
            // and installing are the second half and happen after it.
            case "AUR_SRC_FETCH":
                return root._hasAurWork ? "sources" : "resolve";
            case "AUR_BUILD_LOOP": case "AUR_INSTALL":
                return "aur";
        }
        // pacman's own resolve and table, and its "Proceed with installation?",
        // come AFTER the AUR source fetch on a mixed run. They are what the
        // download is being approved for, so with the sources notch behind
        // us the ball waits at Download (progress 0) beside the highlighted
        // categories rather than parking on Sources for the whole prompt.
        if (root._promptKind === "pacman_proceed") return root._runKind === "undo" ? "resolve" : "download";
        // WHERE THE SNAPSHOT IS: pacman verifies, then runs the pre-transaction hooks and the snapshot hook is
        // the first of them, so from the verification until the hook has said it is through (done or skipped) the
        // run is at the Snapshot notch -- the notch holds the ball for the integrity checks too, or the ball would
        // pass it at "verifying" and the hook would run behind it. A failed hook leaves the ball where it failed.
        if (root._hasSnapshotWork && (root._snapState === "" || root._snapState === "running" || root._snapState === "failed")
                && (p.subPhase === "L3_INTEGRITY" || p.subPhase === "L4_PREHOOKS"))
            return "snapshot";
        switch (p.subPhase) {
            // pacman's own resolve and table. On a mixed run they come
            // after the source fetch, and the high-water mark keeps the ball
            // at Sources for them; mapping them to Download would put the ball on
            // a notch nothing has been downloaded for, through yay's
            // skip-a-dependency question.
            case "L0_RESOLVE": case "L1_TABLE":
                return "resolve";
            case "L2_DOWNLOAD":  return "download";
            // The transaction: integrity, the pre-transaction hooks (DKMS
            // removal among them) and the package changes are one step.
            case "L3_INTEGRITY": case "N3_INTEGRITY":
            case "L4_PREHOOKS":
            case "L5_CHANGES":   case "N5_CHANGES":
                return "install";
            case "L6_POSTHOOKS": case "N6_POSTHOOKS":
                return "hooks";
        }
        return "resolve";
    }

    // ---- Idle headline (shown in header card when not actively updating) ----
    readonly property bool _hasService: !!root.availableUpdates
    readonly property bool _scanning: root._hasService && root.availableUpdates.refreshing
    readonly property int  _availableTotal: root._hasService ? root.availableUpdates.totalCount : 0
    // The last check for updates FAILED and found nothing: no network, a
    // mirror down, yay unable to reach the AUR. "System up to date" over
    // "aur: -> 1 error occurred:" would say the opposite of what has just happened.
    readonly property bool _checkFailed: root._hasService && !root._scanning
        && !!root.availableUpdates.lastError && root.availableUpdates.lastError.length > 0
        && root._availableTotal === 0
    readonly property string _idleHeadline: {
        if (root._snapFailed) return "No snapshot, so nothing was installed";
        if (root._completed && root.parser && root.parser.errorCount > 0)
            return "Finished with " + root.parser.errorCount + " error"
                + (root.parser.errorCount === 1 ? "" : "s");
        // Fresh-after-refresh updates win over "Update complete" so the
        // headline reflects the system's current state (kernel may have
        // just shipped, etc.) rather than a stale post-run banner.
        // A count the service found BEFORE the run is stale the moment the
        // run ends; "Update complete" holds until the service has checked
        // again since. Otherwise the card would say "157 updates available" for
        // the second the refresh takes to come back with zero.
        if (root._completed && !root._refreshedSinceRun) return Work.endLabel(root._runKind, true);
        if (root._availableTotal > 0)
            return root._availableTotal + " update" + (root._availableTotal === 1 ? "" : "s")
                + " available";
        if (root._completed) return Work.endLabel(root._runKind, true);
        if (root._scanning) return "Checking for updates…";
        if (root._checkFailed) return "Could not check for updates";
        if (root._hasService)
            return root.availableUpdates.lastRefreshAtMs > 0 ? "System up to date"
                                                              : "No updates checked yet";
        return "No update running";
    }
    // When the last run ended, so a refresh can be told apart from the
    // count the service held before it.
    property real _runEndedAtMs: 0
    readonly property bool _refreshedSinceRun: root._hasService
        && root.availableUpdates.lastRefreshAtMs > root._runEndedAtMs
    // Which line is under the idle headline: "", "error", "partial", "split", "checked".
    readonly property string _idleSubtextKind: {
        // The reason the snapshot stopped the run, whatever the update check says.
        if (root._snapFailed) return "snapshot";
        if (!root._hasService) return "";
        // Nothing under "Update complete", before or after the re-check:
        // "checked just now" is not a fact anyone acts on right after
        // updating.
        if (root._completed && (!root._refreshedSinceRun || root._availableTotal === 0)) return "";
        const a = root.availableUpdates;
        // Under "Could not check for updates": the reason, in words (the tool's own text is in the log).
        if (root._checkFailed) return "error";
        // Some updates were found but a source did not answer: the list is partial.
        if (a.totalCount > 0 && a.failedSourceList.length > 0) return "partial";
        // Official vs non-official only. The per-repo split is the list itself;
        // repeating it here as a second breakdown would be redundant.
        // Only when there is something to split: "32 official · 0 non-official"
        // repeats the headline, and the list below already says which.
        if (a.totalCount > 0)
            return (a.officialCount > 0 && a.nonOfficialCount > 0) ? "split" : "";
        if (a.lastRefreshAtMs > 0) return "checked";
        return "";
    }
    function _sourceNames(list) {
        const names = { official: "Official repos", aur: "AUR", flatpak: "Flatpak" };
        return list.map(k => names[k] || k).join(" and ");
    }
    // The check's raw failure line ("aur: error: failed retrieving file ...") in a sentence.
    function _failWords(raw, failed) {
        const t = String(raw || "").toLowerCase();
        if (/could not resolve|resolve host|name or service|network is unreachable|temporary failure|no route|offline|connection refused|timed out|timeout/.test(t))
            return "No connection to the network";
        if (failed.length === 1 && failed[0] === "aur") return "The AUR did not answer";
        if (failed.length === 1 && failed[0] === "official") return "A mirror failed to answer";
        if (failed.length === 1) return root._sourceNames(failed) + " did not answer";
        return "Some sources did not answer";
    }
    readonly property string _idleSubtext: {
        const a = root.availableUpdates;   // null for "snapshot": the case below does not read it
        switch (root._idleSubtextKind) {
        case "snapshot": return Work.snapshotFailure(root.parser.snapshotCode, root.parser.snapshotText);
        case "error":   return root._failWords(a.lastError, a.failedSourceList);
        case "partial": return root._sourceNames(a.failedSourceList) + " not checked";
        case "split":   return a.officialCount + " official  ·  " + a.nonOfficialCount + " non-official";
        case "checked": return root._checkedRel ? "checked " + root._checkedRel.text : "";
        }
        return "";
    }

    // "checked 4 min ago" (RelTime with the card's words; past a day the
    // hours count on, "checked 49 h ago"), read against the popup's own
    // BoundaryClock. The clock is asked for the instant the words change,
    // and only while they are on the card: a closed popup, a run, or a line
    // that says something else asks for nothing, so nothing ticks for it.
    BoundaryClock {
        id: relClock
    }
    readonly property bool _checkedAsking: root.visible && root._idle && root._idleSubtextKind === "checked"
    // The later of the clock's `now` and the wall, whether the line is on the
    // card riding in the reading, and a handler that only asks -- LlmTurn,
    // "When it was asked", says why each of the three.
    readonly property var _checkedRel: {
        if (!root._hasService || !(root.availableUpdates.lastRefreshAtMs > 0))
            return null;
        const r = RelTime.format(root.availableUpdates.lastRefreshAtMs, Math.max(relClock.now, Date.now()),
                                 { justNow: "just now", suffix: " ago", dates: false });
        r.asking = root._checkedAsking;
        return r;
    }
    on_CheckedRelChanged: root._askClock()
    // A boundary that passed while the line was being read wakes the clock
    // at once instead of never.
    function _askClock() {
        const r = root._checkedRel;
        if (r && r.asking && r.nextMs > 0)
            relClock.request(Math.max(r.nextMs, Date.now() + 1));
    }
    // ---- The snapshot line ("Snapshot 3 h ago"), under the idle card's other line ----------------------------
    // From the newest row of the service, in the same words as "checked 4 min ago" (RelTime), against a
    // BoundaryClock of its own that is asked only while the line is on the card. Nothing without a ready
    // service; "No snapshot yet" when it is ready and has none. A click opens and closes the snapshots page.
    BoundaryClock {
        id: snapClock
    }
    readonly property var _snapRow: {
        if (!root._snapReady) return null;
        const r = root.snapshots.rows;
        return (r && r.length > 0) ? r[0] : null;
    }
    readonly property bool _snapLineOn: root._idle && root._snapReady && !root._snapFailed
    readonly property var _snapRel: {
        const row = root._snapRow;
        if (!row || !(row.timeMs > 0)) return null;
        const r = RelTime.format(row.timeMs, Math.max(snapClock.now, Date.now()),
                                 { justNow: "just now", suffix: " ago", dates: false });
        r.asking = root.visible && root._snapLineOn;
        return r;
    }
    readonly property string _snapLine: {
        if (!root._snapReady) return "";
        return root._snapRel ? "Snapshot " + root._snapRel.text : "No snapshot yet";
    }
    on_SnapRelChanged: root._askSnapClock()
    function _askSnapClock() {
        const r = root._snapRel;
        if (r && r.asking && r.nextMs > 0)
            snapClock.request(Math.max(r.nextMs, Date.now() + 1));
    }
    readonly property color _idleHeadlineColor: {
        if (root._completed && root.parser && root.parser.errorCount > 0) return root.errColor;
        // "Update complete" is the headline until a check made AFTER the run says otherwise (above),
        // so it takes the ok colour even while the count held from before the run is above zero.
        if (root._completed && !root._refreshedSinceRun) return root.okColor;
        if (root._availableTotal > 0) return root.accent;
        if (root._completed) return root.okColor;
        if (root._checkFailed) return root.warnStrongColor;
        if (root._hasService && root.availableUpdates.lastRefreshAtMs > 0) return root.okColor;
        return root.primaryText;
    }

    // ---- Action / status glyph ------------------------------------------
    // Nerd Font (Font Awesome range) codepoints, written as \u escapes rather
    // than pasted private-use characters so the source stays readable and
    // greppable. The icon reflects what the run is doing right now:
    //   download  waiting to start, or fetching packages
    //   hdd       writing packages to disk
    //   cog       compiling (AUR build, kernel/DKMS work)
    //   check     finished cleanly
    //   warning   finished with errors
    readonly property string glyphDownload: "\uf019"
    readonly property string glyphDisk:     "\uf0a0"
    readonly property string glyphCog:      "\uf013"
    readonly property string glyphCheck:    "\uf00c"
    readonly property string glyphWarn:     "\uf071"

    // WHAT THE LAST RUN LEFT ON THE CARD, when the card still speaks of it: "" (nothing: idle,
    // or a fresh check has found updates again), "ok" (a run that ended clean: "Update
    // complete"), "failed" ("Finished with N errors"). The glyph and what a click on it does
    // follow this -- it is the headline's own condition, so the glyph never says "done" over
    // "5 updates available" (the parser keeps COMPLETE until the next run starts, long after
    // new updates have been found).
    readonly property string _outcome: {
        if (!root._completed || !root.parser) return "";
        if (root.parser.errorCount > 0) return "failed";
        if (root._refreshedSinceRun && root._availableTotal > 0) return "";
        return "ok";
    }
    readonly property string _actionGlyph: {
        if (!root.parser || root._idle) {
            if (root._outcome === "failed") return root.glyphWarn;
            if (root._outcome === "ok") return root.glyphCheck;
            return root.glyphDownload;
        }
        // The rule is the bar button's too (a run's phase mark): one copy, SystemUpdateProgress.js's
        // markKind.
        const kind = Progress.markKind({ phase: root.parser.phase, subPhase: root.parser.subPhase });
        return kind === "cog" ? root.glyphCog : kind === "disk" ? root.glyphDisk : root.glyphDownload;
    }

    // ---- Implicit sizing so hosts can animate between modes ----
    property int normalMinHeight: 560
    property int verboseMinHeight: 760
    property int normalMinWidth:  700
    property int verboseMinWidth: 1080

    // The popup's inner padding, on every side, and the gap between the
    // tab row and the card. One number, so the space above the tabs is the
    // space below them, and the same as the space at the foot.
    property real padding: 12
    // Clearance between the status card's edge and its texts, rail and
    // prompt. The card's clip sits on its edge (particles), so this is what
    // keeps the content off it.
    property real cardPadding: 12
    // Gap between the text block and the rail, and above an open prompt.
    property real railGap: 8

    // ---- Prompt inputs -----------------------------------------------------
    // The field is carved into the card, the buttons stand proud of it, and
    // the two sit level at the same height: one surface with a groove and
    // a plateau, the button's drop shadow carrying the ramp between them.
    // A yes/no question has no groove; its raised pair stands alone on the
    // question's row, the default answer in the accent.
    property real promptInputHeight: 30
    property real promptButtonShadowWidth: 5
    property real promptButtonBevelWidth: 1.5
    property real promptButtonRadius: 8
    // The raised buttons' colours: the plateau at rest and under the
    // pointer, the highlight inside the edge, the drop shadow, and the
    // highlight of an accent (default-answer) button; the accent plateau
    // itself is the popup's accent.
    property color promptButtonColor:       Theme.buttonPlateau
    property color promptButtonHoverColor:  Theme.buttonPlateauHover
    property color promptButtonBevelColor:  Theme.buttonBevel
    property color promptButtonShadowColor: Theme.buttonShadow
    property color promptAccentBevelColor:  Theme.accentBevel
    // The carved field the buttons stand beside, in the card's own palette: ShadowBox's
    // eva-light defaults would leave the one place the user types a light box on a
    // dark card.
    property color promptFieldColor:       Theme.panelSunk
    property color promptFieldBevelColor:  Theme.bevel
    property color promptFieldShadowColor: Theme.border

    // ---- Category header boxes ---------------------------------------------
    // Fill, highlight and inset shadow of each header's carved box; the box
    // stands on the list container's fill.
    property color headerBoxColor:       Theme.headerBox
    property color headerBoxBevelColor:  Theme.headerBoxBevel
    property color headerBoxShadowColor: Theme.headerBoxShadow

    readonly property bool _railShown: root._showRail && root._phaseSteps.length > 0

    // Quiet is exactly as wide as the tab selector plus the popup's padding:
    // the selector is the widest thing quiet shows, so anything more is a
    // margin with nothing in it.
    readonly property real _quietWidth: root.tabSelectorWidth + root.padding * 2
    implicitWidth: verbosityMode === "quiet"   ? root._quietWidth
                 : verbosityMode === "verbose" ? verboseMinWidth
                                               : normalMinWidth
    // Quiet asks for exactly what it shows: the tabs and the card's own
    // destination height. A fixed minimum would leave the card poking out of the
    // popup the moment a rail or a second subtitle line arrives, and a
    // prompt-only boost would catch only one of the three things that grow it.
    implicitHeight: verbosityMode === "quiet"
        ? root.padding * 2 + (root._tabsWanted ? 32 + root.padding : 0) + headerCard.targetHeight
        : (verbosityMode === "verbose" ? verboseMinHeight : normalMinHeight)

    // THE SIZE THE NEXT OPEN ASKS FOR (the engine's owner size memory reads these when a content has them: GooeyEngine `_rememberSize`).
    // The view RESETS on a reopen -- the owner opens in quiet unless a run goes (SystemUpdateBarOwner.open) -- so what the popup was
    // when it closed (verbose, 1080 x 760) is not what the trip back to it should aim at: the box would fly for the first part of the trip
    // at the old view's size and then turn round for quiet's. Quiet's own size, with the tabs as a fresh popup has them (hidden while they auto-hide).
    // (The view a reopen comes back in is the owner's: `restView`, system_update.jsonc `view` -- quiet unless the file names another.)
    property string restView: "quiet"
    readonly property real restImplicitWidth: root.restView === "verbose" ? root.verboseMinWidth : root.restView === "normal" ? root.normalMinWidth : root._quietWidth
    readonly property real restImplicitHeight: root.restView === "verbose" ? root.verboseMinHeight : root.restView === "normal" ? root.normalMinHeight
        : root.padding * 2 + (root.allowModeSwitch && !root.tabsAutoHide ? 32 + root.padding : 0) + headerCard.targetHeight

    // =================================================================
    //  CONTENT
    // =================================================================
    // ----- Mode selector + status dot -----
    // The selector is centred on the popup's full width rather than laid
    // out in a row with the status readout, so it stays optically centred
    // no matter how wide the status text gets. The status sits on top of
    // the same band, pinned right.
    //
    // The row is ANCHORED TO THE POPUP'S RIGHT EDGE, not centred. The quiet view rests against the
    // right segment of the bar and the wider views grow leftwards from it, so a row centred on
    // the popup would walk left with every view; on the right edge it stays where it is on the
    // screen, as in the quiet view, which is anchored to the right. Quiet is exactly as wide as the selector: nothing changes there.
    //
    // Its height eases on the presence fraction, with the content's offset under it (the layout below
    // starts 44 f from the top: see there), and it is clipped only while it is moving: at rest a clip
    // on the selector's edge would shear its carved bevel.
    Item {
        id: tabRow
        x: root.padding
        y: root.padding
        width: root.width - root.padding * 2
        height: 32 * root._tabsF
        visible: root.allowModeSwitch && root._tabsF > 0.001
        clip: root._tabsF < 0.999
        opacity: Math.min(1, root._tabsF * 1.6)

        TabSelector {
            id: modeTabs
            objectName: "modeTabs"
            // The selector's own defaults are eva-light literals, so on a dark theme it would
            // be a light pill on a dark card. Its palette is the popup's.
            trackSurfaceColor: root.surfaceColor
            trackBevelColor: root.borderColor
            trackShadowColor: root.headerBoxShadowColor
            trackBackgroundColor: root.panelColor
            // The pill is a raised box: the surface is the TRACK it
            // stands on, the bevel a highlight inside its edge, the
            // shadow the one it drops onto the track.
            pillSurfaceColor: root.panelColor
            pillBevelColor: root.promptAccentBevelColor
            pillShadowColor: root.promptButtonShadowColor
            pillBackgroundColor: root.accent
            textColor: root.primaryText
            activeTextColor: root.textOnAccent
            // Driven by the popup-wide handler below.
            swipeSelfHandled: false
            swipeThreshold: root.swipeThreshold
            swipePullTaper: root.swipePullTaper
            swipeMaxPull: root.swipeMaxPull
            swipeMomentumRate: root.swipeMomentumRate
            swipeCooldownMs: root.swipeCooldownMs
            squishMax: root.squishMax
            squishVelocityRef: root.squishVelocityRef
            anchors.right: parent.right
            anchors.top: parent.top
            width: root.modeTabsWidth
            height: 32
            // The weather popup's icons: one card for the quiet view, a column of cards for the normal one,
            // and the console for the verbose one (its content is the terminal). The words are the tips.
            tabs: [
                {id: "quiet",   label: "quiet",   icon: "\u{F0B6F}", tip: "quiet"},     // md-card
                {id: "normal",  label: "normal",  icon: "\u{F056A}", tip: "normal"},    // md-view_agenda
                {id: "verbose", label: "verbose", icon: "\u{F018D}", tip: "verbose"}   // md-console
            ]
            currentTab: root.verbosityMode
            onTabChanged: (id) => root.verbosityMode = id
            fontFamily: root.fontFamily
            fontPixelSize: 12
            iconFontFamily: "Symbols Nerd Font"
            iconSize: root.modeTabsIconSize
            labelsVisible: false
            iconsVisible: true
            overlayItem: root
        }

    }

    // THE ROW AND THE CONTENT UNDER IT ARE ONE MOTION, ON ONE CLOCK (`_tabsF`). The row stands
    // outside the layout, and the layout starts `padding + 44 f` below the top: the row (32) and
    // the gap (12) it asks for, as a fraction, with nothing in between to clamp or to drop. As the
    // layout's first cell (its height 32 * fraction and a negative bottom margin taking the layout's
    // spacing with it) the row would fail: a layout cell cannot be negative, so below a fraction of
    // 0.27 the cell (32 f + 12 (f - 1)) is clamped at 0 while the spacing stays, and the content
    // would stand still 12 px under the top for the last third of the hide and then jump those 12
    // when the row goes invisible and takes its spacing with it.
    ColumnLayout {
        id: contentLayout
        anchors.fill: parent
        anchors.margins: root.padding
        anchors.topMargin: root.padding + (root.allowModeSwitch ? (32 + root.padding) * root._tabsF : 0)
        spacing: root.padding

        // ----- Prompt banner (all modes) -----
        // Quiet alert: thin left accent strip + small uppercase kind label,
        // no circular badge. Coexists with future notification system.
        
        // ----- Header card: phase + progress + currentOp -----
        ShadowBox {
            id: headerCard
            objectName: "headerCard"
            Layout.fillWidth: true

            // Two eased heights, summed.
            //
            // The body -- the texts and the rail -- eases here. The prompt
            // banner eases its own height (it grows out of the card's foot),
            // and the card adds that height as it is, frame for frame. One
            // easing over the sum would stall the card behind the banner and leave
            // the clip cutting the banner's foot; switching the card's easing
            // off while the banner runs would make every OTHER change
            // during a banner animation jump instead -- a subtitle slot
            // opening right after a question was answered would snap the rail
            // into the card's bottom edge. Two easings that add have neither
            // problem: each change moves on its own clock.
            readonly property real _bodyTarget: textBlock.implicitHeight
                + (root._railShown ? root.railGap + phaseRail.implicitHeight : 0)
                + root.cardPadding * 2
            property real _bodyHeight: _bodyTarget
            Behavior on _bodyHeight {
                NumberAnimation { duration: root.containerResizeMs; easing.type: Easing.OutCubic }
            }
            // Where the card is heading, unanimated. The quiet-mode popup
            // sizes itself from this so the host's own resize carries it.
            readonly property real targetHeight: _bodyTarget + promptBanner.targetHeight
            Layout.preferredHeight: _bodyHeight + promptBanner.height

            baseRadius: root.listBoxRadius
            surfaceColor: root.surfaceColor
            bevelColor: root.bevelColor
            shadowColor: root.borderColor
            // Same carved surface as the list below it, so the two read as one
            // material rather than as a panel sitting on the background.
            backgroundColor: root.boxedList ? root.listBoxColor : root.surfaceColor
            bevelWidth: 1
            shadowWidth: 3

            // Clips at the card's own edges, not inset from them. The rail's
            // particles may run right up to the edge -- they fade out there
            // (PhaseRail.particleEdge*) -- so the clip has to sit exactly on
            // it, or the fade ends in a hard cut a handful of pixels inside.
            // The content keeps its own padding instead.
            Item {
                id: headerClip
                anchors.fill: parent
                clip: true

                // ---- Text block ---------------------------------------------
                //
                // ONE set of texts for both modes, whose content swaps the
                // moment the state changes. An idle block and a run block
                // cross-fading in the same column would both be in the layout for the
                // fade: the card would grow to their combined height and shrink again --
                // a visible spasm on every switch, with the old text still fading out under
                // the new. Text changes are instant.
                //
                // Each slot holds its line height whether or not it has text,
                // so the rail below never moves while a status comes and goes.
                // Slot A (the sub-phase) is present in the phases that have
                // sub-phases and absent in the ones that never do; slot B (the
                // operation, with the figures at the right) is present for the
                // whole run. That is one height change at the start of the
                // transaction and one at its end, and none in between.
                //
                // A slot that is reserved but blank -- "Checking for updates"
                // with nothing to say under it, "Update complete", a sync with
                // no figure yet -- would leave the title sitting high over a
                // band of nothing. The title takes the middle of the block
                // then, and slides back up when the line fills; the block's
                // height never changes for it, so nothing below moves.
                //
                // Quiet keeps the title and the figures only. What exact thing
                // is being handled is the other views' business; quiet is for
                // seeing progress being made.
                Item {
                    id: textBlock
                    objectName: "textBlock"
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.topMargin: root.cardPadding
                    anchors.leftMargin: root.cardPadding
                    anchors.rightMargin: root.cardPadding
                    height: implicitHeight

                    FontMetrics { id: titleMetrics; font.family: root.fontFamily; font.pixelSize: 16; font.bold: true }
                    FontMetrics { id: subMetrics;   font.family: root.fontFamily; font.pixelSize: 12 }

                    readonly property real _titleH: titleMetrics.height
                    readonly property real _subH: subMetrics.height
                    readonly property real _gap: 2
                    readonly property bool _slotA: root._cardSubASlot
                    readonly property bool _slotB: !root._idle
                    // The snapshot line: it takes slot A's row while A has no words, and has a row of its own
                    // only when A has some (that height change rides the card's own 260 ms clock). The words of
                    // the line change and its height does not.
                    readonly property bool _slotC: root._snapLineOn
                    readonly property bool _cOwnRow: _slotC && root._cardSubA.length > 0
                    // A failed snapshot's two buttons stand on a row under the texts: the card is narrow in quiet,
                    // and beside the title they would leave it a few characters.
                    readonly property bool _snapFailed: root._snapFailed && root._idle
                    readonly property int  _lines: (_slotA ? 1 : 0) + (_slotB ? 1 : 0) + (_cOwnRow ? 1 : 0)
                    // The one companion line is reserved and blank.
                    readonly property bool _companionBlank: _lines === 1
                        && (_slotA ? (root._cardSubA.length === 0 && !_slotC) : !root._slotBHasContent)
                    implicitHeight: _titleH + _lines * (_gap + _subH)
                        + (_snapFailed ? 8 + root.promptInputHeight : 0)
                    function snapW(t) {
                        const f = subMetrics.font;
                        return Math.ceil(subMetrics.advanceWidth(t));
                    }

                    Item {
                        id: textArea
                        anchors.left: parent.left
                        anchors.top: parent.top
                        width: parent.width - (runGlyph.visible ? runGlyph.width + 10 : 0)
                               - (retryButton.visible && !textBlock._snapFailed ? retryButton.width + 10 : 0)
                        height: parent.height

                        Text {
                            id: titleText
                            width: parent.width
                            height: textBlock._titleH
                            y: textBlock._companionBlank
                               ? (textBlock.implicitHeight - textBlock._titleH) / 2 : 0
                            Behavior on y {
                                NumberAnimation { duration: root.containerResizeMs; easing.type: Easing.OutCubic }
                            }
                            verticalAlignment: Text.AlignVCenter
                            text: root._live(root._cardTitle)
                            color: root._idle ? root._idleHeadlineColor : root.primaryText
                            font.family: root.fontFamily
                            font.pixelSize: 16
                            font.bold: true
                            elide: Text.ElideRight
                        }
                        // Slot A.
                        Text {
                            id: subAText
                            visible: textBlock._slotA
                            y: textBlock._titleH + textBlock._gap
                            width: parent.width
                            height: textBlock._subH
                            verticalAlignment: Text.AlignVCenter
                            opacity: root._cardSubA.length > 0 ? 1 : 0
                            Behavior on opacity { NumberAnimation { duration: 160 } }
                            text: root._live(root._cardSubA)
                            color: root.mutedText
                            font.family: root.fontFamily
                            font.pixelSize: 12
                            elide: Text.ElideRight
                        }
                        // Slot C: the newest snapshot, clickable (the page): the words, then the shell's Chevron
                        // (down at rest, up while the page is open), one hit area for the whole. Hover is a short
                        // colour fade of one fraction; an open page holds the accent.
                        Item {
                            id: snapRow
                            visible: textBlock._slotC
                            y: textBlock._titleH + textBlock._gap
                               + (textBlock._slotA && root._cardSubA.length > 0 ? textBlock._subH + textBlock._gap : 0)
                            readonly property real _chevW: snapChevron.implicitWidth + 6
                            readonly property real _textW: Math.min(parent.width - snapRow._chevW, textBlock.snapW(root._snapLine))
                            width: snapRow._textW + snapRow._chevW
                            height: textBlock._subH
                            property real hoverF: (snapArea.containsMouse || root.secondaryOpen) ? 1 : 0
                            Behavior on hoverF {
                                NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                            }
                            property real openF: root.secondaryOpen ? 1 : 0
                            Behavior on openF {
                                NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
                            }
                            readonly property color ink: Mix.c(root.mutedText, root.accent, snapRow.hoverF)
                            Text {
                                id: snapText
                                objectName: "snapLine"
                                width: snapRow._textW
                                height: parent.height
                                verticalAlignment: Text.AlignVCenter
                                text: root._snapLine
                                color: snapRow.ink
                                font.family: root.fontFamily
                                font.pixelSize: 12
                                elide: Text.ElideRight
                            }
                            Chevron {
                                id: snapChevron
                                size: 9
                                thickness: 1.6
                                color: snapRow.ink
                                rotation: snapRow.openF * 180
                                x: Math.round(snapRow._textW + 6)
                                y: Math.round((parent.height - height) / 2)
                            }
                            MouseArea {
                                id: snapArea
                                objectName: "snapLineArea"
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.toggleSnapshots()
                            }
                        }
                        // Slot B: what is happening, and how far along.
                        Item {
                            id: slotB
                            // The names, trimmed to what the line can hold and
                            // wound on by `_dlCycle`. One binding returning
                            // both the text and how many it managed, so the
                            // cycle timer can ask whether anything is hidden
                            // without the fitting being done twice -- and so
                            // nothing has to be written from inside a binding.
                            //
                            // Measured with FontMetrics, never by reading a
                            // Text's width: that is what the Text is sized
                            // from. The room is what the figures leave, which
                            // is the same rule the whole line follows.
                            readonly property real _opRoom:
                                Math.max(0, width - (cardStats.hasContent ? cardStats.width + 8 : 0))
                            readonly property var _opFitted: {
                                const n = root._dlNames;
                                if (!root._inDownloadOp || n.length === 0)
                                    return ({ text: root._currentOperation, shown: 0 });
                                const room = slotB._opRoom;
                                let out = "";
                                let shown = 0;
                                for (let k = 0; k < n.length; k++) {
                                    const cand = out.length === 0
                                        ? "downloading " + n[(root._dlCycle + k) % n.length]
                                        : out + ", " + n[(root._dlCycle + k) % n.length];
                                    if (room > 0 && opFm.advanceWidth(cand) > room) break;
                                    out = cand;
                                    shown++;
                                }
                                // Never nothing: one name elided beats a blank
                                // line while twenty files are moving.
                                if (shown === 0)
                                    return ({ text: "downloading " + n[root._dlCycle % n.length],
                                              shown: 1 });
                                return ({ text: out, shown: shown });
                            }
                            FontMetrics {
                                id: opFm
                                font.family: root.fontFamily
                                font.pixelSize: 12
                            }
                            visible: textBlock._slotB
                            y: textBlock._titleH + textBlock._gap
                               + (textBlock._slotA ? textBlock._subH + textBlock._gap : 0)
                            width: parent.width
                            height: textBlock._subH
                            opacity: root._slotBHasContent ? 1 : 0
                            Behavior on opacity { NumberAnimation { duration: 160 } }

                            Text {
                                id: opText
                                objectName: "opText"
                                anchors.left: parent.left
                                // Whatever the figures leave, by arithmetic
                                // rather than by anchoring to a sibling that
                                // moves: `cardStats.x` is derived from its own
                                // implicit width and never from this text, so
                                // there is nothing here to close a loop with.
                                width: Math.max(0, (snapPct.visible ? snapPct.x : cardStats.x) - 8)
                                height: parent.height
                                verticalAlignment: Text.AlignVCenter
                                text: root._live(slotB._opFitted.text)
                                color: root.primaryText
                                font.family: root.fontFamily
                                font.pixelSize: 12
                                elide: Text.ElideRight
                            }
                            // The snapshot's percent: right-aligned in a slot the width of "100 %", so it never jitters.
                            Text {
                                id: snapPct
                                objectName: "snapPercent"
                                visible: root._snapPercent >= 0
                                width: Math.ceil(opFm.advanceWidth("100 %")) + 1
                                x: parent.width - width
                                height: parent.height
                                horizontalAlignment: Text.AlignRight
                                verticalAlignment: Text.AlignVCenter
                                text: root._snapPercent + " %"
                                color: root.mutedText
                                font.family: root.fontFamily
                                font.pixelSize: 11
                            }
                            // Each figure in its own anchored slot, so a digit
                            // gained on the right never shoves the text on its
                            // left. Quiet keeps only the PROGRESS -- the count
                            // and the time; the bytes and the rate are the other
                            // views' business. At quiet's 376 px all four figures
                            // would take the whole line and leave the operation text
                            // ("downloading ...") a few pixels. A step that has no package count (a
                            // sync, a lone download) keeps its bytes: they are
                            // its progress.
                            DownloadStats {
                                id: cardStats
                                objectName: "cardStats"
                                anchors.verticalCenter: parent.verticalCenter
                                // PLACED BY x, never by a pair of horizontal
                                // anchors that swap with the view mode.
                                //
                                // `anchors.right: quiet ? undefined : parent.right`
                                // beside `anchors.left: quiet ? parent.left : undefined`
                                // does not switch atomically: leaving quiet,
                                // the `right` binding lands while `left` is
                                // still set, and for that instant the item is
                                // anchored on BOTH sides. Qt answers a
                                // two-sided anchor by CALLING setWidth(),
                                // which destroys `width: implicitWidth` for
                                // good -- so the block would stay 512 px wide
                                // (quiet's slot) with 75 px of figures in it
                                // for the rest of the session, and the
                                // operation text would be cut to 132 px with the
                                // figures' ink 437 px away: truncated with plenty of space left.
                                x: Math.max(0, parent.width - width)
                                done: root._progressDone
                                total: root._progressTotal
                                unit: root._progressUnit
                                bytesDone: root._progressBytesDone
                                bytesTotal: root._progressBytesTotal
                                rateText: root._progressRate
                                etaText: root._progressEta
                                showBytes: root.verbosityMode !== "quiet" || root._progressTotal <= 0
                                showRate: root.verbosityMode !== "quiet"
                                // The figures are the priority and take the
                                // line; the operation text takes what they
                                // leave. This only drops the rate when the
                                // FIGURES alone would not fit, which is the
                                // overflow guard a narrow card needs.
                                availableWidth: slotB.width
                                alignment: Qt.AlignRight
                                fontFamily: root.fontFamily
                                pixelSize: 11
                                color: root.mutedText
                            }
                        }
                    }

                    Text {
                        id: runGlyph
                        objectName: "runGlyph"
                        // The failed snapshot's card has its buttons instead (its warning is the title's colour).
                        visible: root._idle && !textBlock._snapFailed
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 32
                        text: root._actionGlyph
                        font.family: "Symbols Nerd Font"
                        font.pixelSize: 20
                        // Two eased fractions rather than `Behavior on
                        // color`: all three colours are themed, and a
                        // Behavior would chase a light/dark switch 120ms behind
                        // the card.
                        property real availF: root._availableTotal > 0 ? 1 : 0
                        property real hoverF: runArea.containsMouse ? 1 : 0
                        Behavior on availF {
                            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                        }
                        Behavior on hoverF {
                            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                        }
                        color: Mix.c3(root.primaryText, root.accent, availF,
                                      root.accentHover, hoverF)
                        horizontalAlignment: Text.AlignHCenter
                        // WHAT A CLICK ON IT DOES FOLLOWS WHAT IT SAYS. The download glyph
                        // starts the update; the check of a run that ended clean closes the
                        // popup (nothing is left to do here);
                        // the warning of a failed run is a mark, not a button -- the Retry
                        // beside it is the way back. No pointer, no hover, no click on a mark.
                        MouseArea {
                            id: runArea
                            objectName: "runGlyphArea"
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            enabled: root._idle && root._outcome !== "failed"
                            onClicked: {
                                if (root._outcome === "ok")
                                    root.closeRequested();
                                else
                                    root.startUpdateRequested();
                            }
                        }
                    }

                    // A run that FAILED offers the way back: the same update again. pacman keeps
                    // what it already downloaded (its cache), so a retry after a lost mirror
                    // starts with the packages that did arrive. A labelled button, not another
                    // glyph, so a failed run is not left sitting on its warning with no way back.
                    RaisedButton {
                        id: retryButton
                        objectName: "retryButton"
                        visible: root._idle && root._outcome === "failed"
                        // Beside the glyph, or -- when the snapshot stopped the run -- at the foot of the texts.
                        anchors.right: textBlock._snapFailed ? parent.right : runGlyph.left
                        anchors.rightMargin: textBlock._snapFailed ? 0 : 10
                        anchors.verticalCenter: textBlock._snapFailed ? undefined : parent.verticalCenter
                        anchors.bottom: textBlock._snapFailed ? parent.bottom : undefined
                        height: root.promptInputHeight
                        text: "Retry"
                        accent: true
                        surfaceColor: headerCard.backgroundColor
                        fontFamily: root.fontFamily
                        shadowWidth: root.promptButtonShadowWidth
                        bevelWidth: root.promptButtonBevelWidth
                        radius: root.promptButtonRadius
                        plateauColor: root.promptButtonColor
                        plateauHoverColor: root.promptButtonHoverColor
                        bevelColor: root.promptButtonBevelColor
                        shadowColor: root.promptButtonShadowColor
                        accentColor: root.accent
                        accentHoverColor: root.accentHover
                        accentBevelColor: root.promptAccentBevelColor
                        textColor: root.primaryText
                        faintTextColor: root.faintText
                        accentTextColor: root.textOnAccent
                        onClicked: root.startUpdateRequested()
                    }
                    // The snapshot could not be taken and pacman stopped before it changed anything: go on without one.
                    RaisedButton {
                        id: noSnapshotButton
                        objectName: "noSnapshotButton"
                        visible: textBlock._snapFailed
                        anchors.right: retryButton.left
                        anchors.rightMargin: 10
                        anchors.bottom: parent.bottom
                        height: root.promptInputHeight
                        text: "Update without it"
                        surfaceColor: headerCard.backgroundColor
                        fontFamily: root.fontFamily
                        shadowWidth: root.promptButtonShadowWidth
                        bevelWidth: root.promptButtonBevelWidth
                        radius: root.promptButtonRadius
                        plateauColor: root.promptButtonColor
                        plateauHoverColor: root.promptButtonHoverColor
                        bevelColor: root.promptButtonBevelColor
                        shadowColor: root.promptButtonShadowColor
                        accentColor: root.accent
                        accentHoverColor: root.accentHover
                        accentBevelColor: root.promptAccentBevelColor
                        textColor: root.primaryText
                        faintTextColor: root.faintText
                        accentTextColor: root.textOnAccent
                        onClicked: root.startWithoutSnapshotRequested()
                    }
                    HoverTip {
                        objectName: "retryTip"
                        show: retryButton.visible && retryButton._hovered
                        anchorItem: retryButton
                        overlayItem: root
                        text: "Run the update again. Downloads already finished are kept."
                        fontFamily: root.fontFamily
                    }
                }

                // ---- Rail ---------------------------------------------------
                //
                // Glued to the card's bottom edge, not laid out under the
                // texts. Laid out, it would snap to its new place the instant a
                // subtitle slot opened while the card is still easing toward
                // that height, and clip into the bottom edge on the way.
                // Anchored to the foot it moves exactly as the edge moves --
                // the edge appears to drag it. The prompt banner opens between
                // the two; its height is part of the card's, so the rail holds
                // still while a question comes and goes.
                //
                // It first appears from under the texts as the card grows
                // for it, and fades in over that growth.
                PhaseRail {
                    id: phaseRail
                    objectName: "phaseRail"
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: root.cardPadding
                    anchors.rightMargin: root.cardPadding
                    anchors.bottom: promptBanner.top
                    height: implicitHeight
                    visible: opacity > 0
                    opacity: root._railShown ? 1 : 0
                    Behavior on opacity {
                        NumberAnimation { duration: root.containerResizeMs; easing.type: Easing.OutCubic }
                    }

                    particlesEnabled: root.railParticles
                    // The particles fade to nothing at the card's edges: the
                    // clip is flush with them left and right, and the foot
                    // is the card's own (or the banner's top).
                    particleEdgeLeft: root.cardPadding
                    particleEdgeRight: root.cardPadding
                    particleEdgeTop: phaseRail.y
                    particleEdgeBottom: headerClip.height - phaseRail.y - phaseRail.height
                    steps: root._phaseSteps
                    currentKey: root._currentStep
                    stepProgress: root._stepProgress
                    failed: !!root.parser && root.parser.errorCount > 0
                    allDone: root._completed
                             && (!root.parser || root.parser.errorCount === 0)
                    active: root._active

                    textColor: root.primaryText
                    mutedColor: root.mutedText
                    faintColor: root.faintText
                    accentColor: root.accent
                    doneColor: root.okColor
                    errorColor: root.errColor
                    surfaceColor: root.surfaceColor
                    grooveColor: root.panelColor
                    grooveBevelColor: root.bevelColor
                    grooveShadowColor: root.borderColor
                    ballShadowColor: root.ballShadowColor
                    fontFamily: root.fontFamily
                }

                // ---- Prompt banner ------------------------------------------
                //
                // Below the rail, not above it. Layout-wise the question
                // belongs with the status text, but a banner opening above
                // the rail would shove the rail down every time -- and the rail is
                // the one thing on the card that should hold still.
                Item {
                    id: promptBanner
                    objectName: "promptBanner"
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.leftMargin: root.cardPadding
                    anchors.rightMargin: root.cardPadding
                    anchors.bottomMargin: root.cardPadding
                    // The gap above the banner is part of its own height, so
                    // the gap grows with it instead of popping in. +18 =
                    // promptCol's own 9+9 margins, so the box matches its
                    // content; at +10 the column would overflow by 8px and the
                    // stripe end above the field.
                    readonly property real targetHeight:
                        root._promptVisible ? promptCol.implicitHeight + 18 + root.railGap : 0
                    // Height animates rather than the item appearing, so the
                    // card grows downwards into the prompt instead of jumping.
                    // Stays in until the close animation has actually reached 0.
                    height: targetHeight
                    Behavior on height {
                        NumberAnimation { duration: root.containerResizeMs; easing.type: Easing.OutCubic }
                    }
                    visible: root._promptVisible || height > 0
                    clip: true

                    // Everything in the banner fades as ONE: the stripe, the
                    // question, the field, the buttons. Parts that each arrive their
                    // own way (stripe growing, buttons on frame one, title reflowing as
                    // space frees) would read as broken; the card's own resize already covers half
                    // of the entrance, so a plain fade is all that is needed.
                    Item {
                        id: promptContent
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.topMargin: root.railGap
                        height: promptCol.implicitHeight + 18
                        opacity: root._promptVisible ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 160 } }
                    }
                    Rectangle {
                        parent: promptContent
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: 5
                        // The same margins the column keeps, so the stripe
                        // spans exactly the rows it marks.
                        anchors.topMargin: 9
                        anchors.bottomMargin: 9
                        width: 3
                        radius: 1.5
                        color: root.warnStrongColor
                    }

                    ColumnLayout {
                        id: promptCol
                        parent: promptContent
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.leftMargin: 16
                        anchors.rightMargin: 11
                        anchors.topMargin: 9
                        height: implicitHeight
                        spacing: 6

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10

                            Text {
                                text: "INPUT"
                                color: root.warnStrongColor
                                font.family: root.fontFamily
                                font.pixelSize: 9
                                font.bold: true
                                font.letterSpacing: 1.2
                                Layout.alignment: Qt.AlignVCenter
                            }
                            Text {
                                Layout.fillWidth: true
                                text: root._promptTitle
                                color: root.primaryText
                                font.family: root.fontFamily
                                font.pixelSize: 12
                                font.bold: true
                                elide: Text.ElideRight
                            }
                            // Yes/no answers live on the question's own row. A row of their
                            // own under the title would leave a band of empty space where a text
                            // field goes for other prompts.
                            RaisedButton {
                                visible: root._promptIsYesNo
                                Layout.preferredHeight: root.promptInputHeight
                                text: "Yes"
                                accent: root._yesNoDefault === "Y"
                                surfaceColor: headerCard.backgroundColor
                                fontFamily: root.fontFamily
                                shadowWidth: root.promptButtonShadowWidth
                                bevelWidth: root.promptButtonBevelWidth
                                radius: root.promptButtonRadius
                                plateauColor: root.promptButtonColor
                                plateauHoverColor: root.promptButtonHoverColor
                                bevelColor: root.promptButtonBevelColor
                                shadowColor: root.promptButtonShadowColor
                                accentColor: root.accent
                                accentHoverColor: root.accentHover
                                accentBevelColor: root.promptAccentBevelColor
                                textColor: root.primaryText
                                faintTextColor: root.faintText
                                accentTextColor: root.textOnAccent
                                onClicked: root._sendPromptReply("y")
                            }
                            RaisedButton {
                                visible: root._promptIsYesNo
                                Layout.preferredHeight: root.promptInputHeight
                                text: "No"
                                accent: root._yesNoDefault === "N"
                                surfaceColor: headerCard.backgroundColor
                                fontFamily: root.fontFamily
                                shadowWidth: root.promptButtonShadowWidth
                                bevelWidth: root.promptButtonBevelWidth
                                radius: root.promptButtonRadius
                                plateauColor: root.promptButtonColor
                                plateauHoverColor: root.promptButtonHoverColor
                                bevelColor: root.promptButtonBevelColor
                                shadowColor: root.promptButtonShadowColor
                                accentColor: root.accent
                                accentHoverColor: root.accentHover
                                accentBevelColor: root.promptAccentBevelColor
                                textColor: root.primaryText
                                faintTextColor: root.faintText
                                accentTextColor: root.textOnAccent
                                onClicked: root._sendPromptReply("n")
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            text: root._promptDetail
                            color: root.mutedText
                            font.family: root.fontFamily
                            font.pixelSize: 11
                            wrapMode: Text.WordWrap
                            visible: text.length > 0
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            // Wide enough for the button's drop shadow to fall
                            // into, so the groove's rim and the plateau's
                            // shadow meet in the gap rather than on each other.
                            spacing: 10
                            visible: root._promptIsList

                            // -- number-list prompts (exclude / cleanBuild / diffs / edit) --
                            // Same wrapper treatment as the password input. Send
                            // button is dropped (Enter submits); only the
                            // "default" button remains because empty-string
                            // submit is a meaningful alternative the user might
                            // miss otherwise.
                            ShadowBox {
                                visible: root._promptIsList
                                Layout.fillWidth: true
                                Layout.preferredHeight: root.promptInputHeight
                                baseRadius: root.promptButtonRadius
                                // Carved INTO the card: the ground outside
                                // its edge is the card's own fill.
                                surfaceColor: headerCard.backgroundColor
                                backgroundColor: root.promptFieldColor
                                bevelColor: root.promptFieldBevelColor
                                shadowColor: root.promptFieldShadowColor

                                TextField {
                                    id: listField
                                    Keys.forwardTo: [listKeys]
                                    EditKeys {
                                        id: listKeys
                                        target: listField
                                    }
                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 8
                                    placeholderText: root._promptPlaceholder
                                    font.family: root.fontFamily
                                    font.pixelSize: 12
                                    color: root.primaryText
                                    placeholderTextColor: root.faintText
                                    verticalAlignment: TextInput.AlignVCenter
                                    background: null
                                    onAccepted: { root._sendPromptReply(text); text = "" }
                                }
                            }
                            // Two buttons, and the highlighted one sends what was typed. With
                            // only the default beside the field, the natural move -- type, then
                            // click the one button -- would send a blank and exclude nothing.
                            RaisedButton {
                                visible: root._promptIsList
                                Layout.preferredHeight: root.promptInputHeight
                                text: root._promptDisplayKind === "yay_exclude" ? "Exclude" : "Apply"
                                accent: true
                                enabled: listField.text.trim().length > 0
                                surfaceColor: headerCard.backgroundColor
                                fontFamily: root.fontFamily
                                shadowWidth: root.promptButtonShadowWidth
                                bevelWidth: root.promptButtonBevelWidth
                                radius: root.promptButtonRadius
                                plateauColor: root.promptButtonColor
                                plateauHoverColor: root.promptButtonHoverColor
                                bevelColor: root.promptButtonBevelColor
                                shadowColor: root.promptButtonShadowColor
                                accentColor: root.accent
                                accentHoverColor: root.accentHover
                                accentBevelColor: root.promptAccentBevelColor
                                textColor: root.primaryText
                                faintTextColor: root.faintText
                                accentTextColor: root.textOnAccent
                                onClicked: { root._sendPromptReply(listField.text); listField.text = "" }
                            }
                            RaisedButton {
                                visible: root._promptIsList
                                Layout.preferredHeight: root.promptInputHeight
                                text: root._promptDefaultLabel
                                surfaceColor: headerCard.backgroundColor
                                fontFamily: root.fontFamily
                                shadowWidth: root.promptButtonShadowWidth
                                bevelWidth: root.promptButtonBevelWidth
                                radius: root.promptButtonRadius
                                plateauColor: root.promptButtonColor
                                plateauHoverColor: root.promptButtonHoverColor
                                bevelColor: root.promptButtonBevelColor
                                shadowColor: root.promptButtonShadowColor
                                accentColor: root.accent
                                accentHoverColor: root.accentHover
                                accentBevelColor: root.promptAccentBevelColor
                                textColor: root.primaryText
                                faintTextColor: root.faintText
                                accentTextColor: root.textOnAccent
                                onClicked: root._sendPromptReply("")
                            }

                            // -- y/n prompts (pacman proceed + generic yay yes/no) --
                        }
                    }

                    // Auto-focus the active text input as soon as the prompt
                    // banner becomes visible AND whenever the kind transitions
                    // while the banner stays up (e.g. yay_exclude → yay_cleanbuild
                    // back-to-back). Without auto-focus the user would have to click
                    // the field before typing — for yay_exclude this would
                    // read as a soft-lock because no other UI gives any cue that
                    // input is needed.
                    function _focusActive() {
                        if (!visible) return;
                        if (root._promptIsList) {
                            listField.forceActiveFocus();
                            // The field is up: on a layer surface the keys come
                            // only when the window asks for them.
                            root.pulseKeyboard();
                        }
                    }
                    onVisibleChanged: Qt.callLater(_focusActive)

                    Connections {
                        target: root.parser
                        ignoreUnknownSignals: true
                        function onCurrentPromptKindChanged() { Qt.callLater(promptBanner._focusActive) }
                    }
                }
            }
        }

        // In quiet mode the body is hidden, so no child claims the leftover
        // vertical space and the layout spreads it around the header card —
        // which would show quiet a larger gap under the tab row than
        // the other modes. This spacer gives the slack somewhere to go, so the
        // card sits at the same offset in every mode.
        Item {
            Layout.fillHeight: true
            Layout.fillWidth: true
            visible: root.verbosityMode === "quiet"
        }

        // ----- Body: hidden in quiet, list in normal, terminal + list in verbose -----
        //
        // ONE list box, always. Verbose puts the terminal beside it and the
        // box takes 30%; normal hides the terminal and the box takes it all.
        //
        // A separate box, viewport and list panel per view (a StackLayout) would destroy one panel and
        // build the other on every switch -- every category section and every row,
        // synchronously, inside the property change: 64-100ms of blocked
        // frames for 69 packages and three times that for a real run -- and
        // the fresh sections would then have to reconstruct mid-phase state they had
        // never seen. With one box the switch is a relayout (the worst frame
        // gap is 35-41ms), and the drain, the favourites,
        // the step counts and the scroll position simply carry on. What
        // remains is the relayout itself -- the two views use different
        // list scales, so every row re-shapes its text on the switch.
        // Binding both scales to one value halves that again; it is a
        // density choice, so it is left to the host.
        RowLayout {
            id: body
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.verbosityMode !== "quiet"
            spacing: 10

            TerminalView {
                id: termView
                visible: root._listInVerbose
                Layout.fillWidth: true
                Layout.fillHeight: true
                // stretchFactor only distributes extra space — with two
                // panes that have non-trivial implicits the ratio collapses
                // toward 50/50. Force preferredWidth=0 so all width is
                // "extra" and stretchFactor (7:3) is authoritative.
                Layout.preferredWidth: 0
                Layout.minimumWidth: 200
                Layout.horizontalStretchFactor: 7
                backend: root.backend
                showInputRow: false
                showPromptBanner: false
                showYesNoShortcuts: false
                showCopyAllButton: false
                wrapLines: root.terminalWrapLines
                color: root.terminalBgColor
                radius: 10
                border.color: root.borderColor
                selectionColor: root.terminalSelectionColor
                selectedTextColor: root.terminalSelectionTextColor
                border.width: 1
                fontPixelSize: root.terminalFontSize
                wheelAxisRatio: root.terminalAxisLockRatio
                // This gesture is the view switch's, not the terminal's --
                // including the part of it that arrives after the switch has
                // put the terminal under the pointer.
                externalGesture: root._gestureActive && !root._gestureOwnedByTerminal
                fontBold: root.terminalFontBold

                // A GROUND, NOT AN EMPTY STATE: the output renders over it and
                // it stays. Carved into the terminal's own shade, which is
                // darker than the list box, so its rim and floor are that
                // shade pushed toward the theme's own rim and shadow rather
                // than the list's tokens outright.
                LogoRelief {
                    anchors.centerIn: parent
                    source: root.archLogoSource
                    logoSize: root.terminalLogoSize
                    surfaceColor: root.terminalBgColor
                    bevelColor: Mix.c(root.terminalBgColor, root.bevelColor,
                                      root.terminalLogoContrast)
                    shadowColor: Mix.c(root.terminalBgColor, root.borderColor,
                                       root.terminalLogoContrast)
                    bodyColor: Mix.c(root.terminalBgColor, root.headerBoxColor,
                                     root.terminalLogoContrast * 0.5)
                }
            }

            // One carved box around the whole scrollable list.
            //
            // Inside a box the rows belong to a surface, and the fade at
            // its foot lets the lower rows dissolve into that surface instead
            // of being cut in half by it — which also says "there is more
            // below" without a scrollbar.
            ShadowBox {
                id: listBox
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 0
                Layout.minimumWidth: 200
                Layout.horizontalStretchFactor: 3
                baseRadius: root._listRadius
                surfaceColor: root.surfaceColor
                bevelColor: root.bevelColor
                shadowColor: root.borderColor
                backgroundColor: root.boxedList ? root.listBoxColor : root.surfaceColor
                bevelWidth: root.boxedList ? 1 : 0
                shadowWidth: root.boxedList ? 3 : 0

                // The mark, when there is nothing to list. Outside the
                // Flickable on purpose: it is the container's own empty
                // state, not a row, so it does not scroll and takes no part
                // in the list's height. Never in verbose, whose list panel is
                // too narrow for it.
                LogoRelief {
                    anchors.centerIn: parent
                    visible: root._listEmpty && !root._listInVerbose
                    source: root.archLogoSource
                    logoSize: root.archLogoSize
                    // Carved into the container's own fill, which is the
                    // ground this box actually is.
                    surfaceColor: root.boxedList ? root.listBoxColor : root.surfaceColor
                    bevelColor: root.bevelColor
                    shadowColor: root.borderColor
                    bodyColor: root.headerBoxColor
                }

                // The viewport fills the box exactly, so a header's own box
                // can sit flush against the container's edges and share its
                // corner. The rows are what is inset, not the viewport.
                Flickable {
                    id: listFlick
                    anchors.fill: parent
                    contentWidth: listPanel.width
                    contentHeight: listPanel.height
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    // Held still while a favourite flight is airborne — otherwise
                    // the landing slot could scroll away mid-flight and the clone
                    // would visibly miss it.
                    interactive: !root.scrollLocked

                    // No scrollbar: the list is short enough to be obviously
                    // scrollable and the bar was the only hard edge in the panel.

                    SummaryPanel {
                        id: listPanel
                        opacity: root._showSkeleton ? 0 : 1
                        Behavior on opacity {
                            NumberAnimation { duration: listSkeleton.fadeMs; easing.type: Easing.OutCubic }
                        }
                        width: listFlick.width
                        compact: root._listInVerbose
                        viewport: listFlick
                        listScale: root._listInVerbose ? root.verboseListScale
                                                       : root.normalListScale
                        rowInset: root.listInset
                        containerRadius: root._listRadius
                    }

                    // Smears the list vertically while it scrolls under a flying
                    // favourite. Idle at all other times — MotionBlur bypasses its
                    // own capture below `threshold`, so there is no standing cost.
                    MotionBlur {
                        source: listPanel
                        amount: Math.max(flightOverlay.blur, sectionFlight.blur)
                        threshold: 0.02
                        direction: Qt.vector2d(0, 1)
                    }
                }

                // THE WHEEL. The shell's scroll feel (modules/common/scroll): a notch
                // glides, a touchpad follows the fingers and coasts after their lift.
                // A MouseArea laid OVER the viewport (taking no button and no hover),
                // not a handler inside the Flickable and not a child of its content:
                // a WheelHandler never hears a purely sideways event or the lift
                // (CLAUDE.md), and a content child would have to win delivery against every
                // row and header MouseArea above it. Laid over the box nothing grows
                // over it. `scrollSpeed` multiplies the feel's own speed.
                KineticScroll {
                    id: listScroll
                    flick: listFlick
                    speed: root.scrollSpeed * ScrollFeel.speed
                }
                WheelArea {
                    anchors.fill: listFlick
                    turned: wheel => {
                        if (!root.scrollLocked)
                            listScroll.feed(wheel.pixelDelta.y, wheel.angleDelta.y, wheel.phase);
                        wheel.accepted = true;
                    }
                }
                Connections {
                    target: root
                    // A favourite's flight owns the position while it lasts.
                    function onScrollLockedChanged() {
                        if (root.scrollLocked)
                            listScroll.stop();
                    }
                }

                // The shared dressing: the fade at each end, keyed on where
                // the list is scrolled to rather than on how tall it is, and
                // the corner re-cut over the scrolling rows (see CarvedListDressing.qml).
                CarvedListDressing {
                    flick: listFlick
                    boxed: root.boxedList
                    boxColor: root.listBoxColor
                    surfaceColor: root.surfaceColor
                    bevelColor: root.bevelColor
                    radius: root._listRadius
                    fadeHeight: root.listFadeHeight
                }

                // The list's silhouette while the update check runs; see
                // ListSkeleton for the transition it performs when the
                // real categories arrive.
                ListSkeleton {
                    id: listSkeleton
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    visible: root._skeletonAlive
                    listScale: root._listInVerbose ? root.verboseListScale : root.normalListScale
                    // The real header's and row's geometry, from the same
                    // fonts at the same scale. A rounded guess would put the
                    // silhouettes a few pixels short of the rows they stand
                    // for, and the two lists would not line up as one
                    // becomes the other.
                    headerPadV: root.headerBoxPaddingV * listScale
                    titleLineH: skelTitleProbe.implicitHeight
                    subLineH: skelSubProbe.implicitHeight
                    // Verbose's compact header keeps its count on the
                    // title line, so its box is one line shorter.
                    compact: root._listInVerbose
                    headerHeight: headerPadV * 2 + titleLineH + (compact ? 0 : subLineH - 1)
                    headerGap: 6 * listScale
                    sectionGap: 6
                    rowInnerTop: 3 * listScale
                    rowVPad: 4 * listScale
                    nameLineH: skelNameProbe.implicitHeight
                    versionLineH: skelVersionProbe.implicitHeight
                    rowHeight: nameLineH + 1 + versionLineH + rowVPad * 2 + 6 * listScale
                    rowInset: root.listInset
                    containerRadius: root._listRadius
                    headerRadius: root._listRadius
                    boxColor: root.headerBoxColor
                    // The silhouette is drawn in exactly two tones and a bar
                    // is always the OTHER one: bars inside a header box take
                    // the list's tone, bars lying on the list take the box's.
                    // Passing only the first would leave the rows' stripe, icon
                    // and text bars on the light default while the
                    // header boxes go dark.
                    barColor: root.listBoxColor
                    rowBarColor: root.headerBoxColor
                }
            }
        }
    }

    // Mode swiping, captured across the WHOLE popup.
    //
    // A MouseArea on top, NOT a WheelHandler: a WheelHandler here never hears the
    // swipe.
    //
    // The lists and the terminal each own a WheelHandler for scrolling. Those
    // sit deeper in the scene than a popup-level handler, so they receive every
    // wheel event first and accept it — horizontal ones included, even though
    // they only read the vertical component. A handler higher up therefore
    // never sees the swipe at all, no matter how far the gesture goes.
    //
    // Overlaying a MouseArea puts this FIRST in delivery instead of last. It
    // takes no buttons, so clicks and hover pass straight through, and it
    // always leaves `wheel.accepted = false` so vertical scrolling continues
    // down to whatever is underneath. Same shape as the month-swipe in the
    // clock popup, which is the implementation known to work on this hardware.
    // A gesture that has begun keeps running until the fingers lift, even if
    // the popup resizes out from under the cursor.
    //
    // Switching to a smaller view shrinks this item, and the moment the cursor
    // falls outside it the wheel events stop arriving and the gesture dies
    // halfway. While a gesture is live the capture area is therefore held at
    // the largest size any view uses, so verbose -> quiet -> verbose is one
    // continuous gesture no matter where the pointer happens to sit. It shrinks
    // back as soon as the fingers lift, so it never listens outside the popup
    // at rest.
    property bool _gestureActive: false

    // ---- the tab row's presence -------------------------------------------------------------------
    //
    // The pointer is read by a HoverHandler on the popup's root: a handler on an ANCESTOR of the
    // popup's links and buttons leaves their hover alone (a hover-only item stacked over them
    // takes it: measured). `hovered` is true while the pointer is within the root's bounds; the
    // band is read from the handler's own point (the root's coordinates), not from a second
    // item laid over the top of the popup, which would take the hover of whatever is under it.
    HoverHandler {
        id: popupHover
    }
    Timer {
        id: bandDwell
        interval: root.tabsDwellMs
        onTriggered: root._bandArmed = true
    }
    onTabsPointerInBandChanged: {
        if (root.tabsPointerInBand && root.tabsAutoHide && !root._bandArmed)
            bandDwell.restart();
        else if (!root.tabsPointerInBand)
            bandDwell.stop();
    }
    onTabsPointerOverChanged: {
        if (!root.tabsPointerOver) {
            bandDwell.stop();
            root._bandArmed = false;
        }
    }
    property bool _tabsReady: false
    property bool _tabsHold: false
    function _holdTabs() {
        // Not at creation: the first assignment of the view is the host's, and a popup that
        // opens under a pointer that is elsewhere opens without the row.
        if (!root._tabsReady || !root.tabsAutoHide)
            return;
        root._tabsHold = true;
        tabsHoldTimer.restart();
    }
    Timer {
        id: tabsHoldTimer
        interval: root.tabsHoldMs
        onTriggered: root._tabsHold = false
    }
    on_GestureActiveChanged: if (!root._gestureActive) root._holdTabs()
    readonly property bool _tabsWanted: root.allowModeSwitch
        && (!root.tabsAutoHide || root._bandArmed || root._tabsHold || root._gestureActive)
    property real _tabsF: root._tabsWanted ? 1 : 0
    Behavior on _tabsF {
        NumberAnimation { duration: root.containerResizeMs; easing.type: Easing.OutCubic }
    }

    // Public: a horizontal gesture is in flight and must not be interrupted.
    //
    // Growing the capture area above is enough while the pointer stays inside
    // the host's input region. thePopup shrinks its actual SURFACE on a view
    // change, and once the cursor is off the surface the compositor routes the
    // scroll elsewhere — no item-level trick can get it back. So the host
    // should hold its input region / mask at the outgoing (larger) size while
    // this is true, and let it shrink when it clears. It is a mask-size hint
    // only: this overlay takes no buttons and consumes no event, so click
    // regions are unaffected.
    readonly property bool swipeGestureActive: root._gestureActive
    // The size the host should keep its surface at, centred on the popup,
    // while `swipeGestureActive` holds: the largest any view uses.
    readonly property real gestureHoldWidth:  Math.max(root.width,  root.verboseMinWidth)
    readonly property real gestureHoldHeight: Math.max(root.height, root.verboseMinHeight)

    // Latched at the START of a gesture: does this one belong to the terminal?
    property bool _gestureOwnedByTerminal: false

    // THE AXIS OF A MOTION: merely scrolling through the list of packages must not make
    // the tab selector appear. A two-finger scroll is never one axis, so a motion's first wheels only
    // COLLECT: once `swipeAxisLockUnits` have arrived on either axis the one that is clearly ahead
    // (`swipeAxisRatio`) owns the motion until the fingers lift, and only a horizontal one is the view
    // switcher's gesture -- it alone raises `_gestureActive` (the tab row, the hold rect, the host's
    // hand-over). A vertical one is the list's and never touches the popup's chrome. 0 undecided, 1
    // horizontal, 2 vertical.
    property real swipeAxisLockUnits: 30
    property real swipeAxisRatio: 1.5
    property int _axis: 0
    property real _axisX: 0           // |units| collected while undecided
    property real _axisY: 0
    property real _axisSumX: 0        // signed, handed to the switcher at the lock
    property real _beginX: 0          // where the motion began (swipe area's frame)
    property real _beginY: 0
    function _endMotion() {
        gestureIdleTimer.stop();
        modeTabs.applySwipe(0);
        root._gestureActive = false;
        root._gestureOwnedByTerminal = false;
        root._axis = 0;
        root._axisX = 0;
        root._axisY = 0;
        root._axisSumX = 0;
    }

    // Fallback end-of-gesture for input devices that never report one.
    //
    // A touchpad ends a scroll with a zero-delta event, which is the real
    // signal. A mouse wheel does not — it just stops sending — so without this
    // the gesture would stay latched forever and the capture area would sit at
    // verbose size listening outside the popup. Long enough not to cut a slow
    // touchpad drag short; the zero-delta path is what normally fires.
    property int gestureIdleEndMs: 260
    Timer {
        id: gestureIdleTimer
        interval: root.gestureIdleEndMs
        onTriggered: root._endMotion()
    }

    WheelArea {
        id: swipeArea
        // Grown about the popup's CENTRE while a gesture is live, not from
        // its top-left corner. A host that keeps the popup centred (the
        // mockup's stage; thePopup on a bottom bar) shrinks it away from the
        // pointer in every direction, and a capture area hanging off the top
        // edge only covered the pointer when it ended up below.
        //
        // This only helps while the pointer stays on the host's surface. A
        // thePopup window that shrinks its surface with the view drops the
        // wheel stream the moment the pointer is off it -- no item can get
        // that back -- so the host must hold its surface and input region
        // at the outgoing size while `swipeGestureActive` is true (see
        // `gestureHoldWidth` / `gestureHoldHeight`).
        x: (root.width - width) / 2
        y: (root.height - height) / 2
        width:  root._gestureActive ? Math.max(root.width,  root.verboseMinWidth)  : root.width
        height: root._gestureActive ? Math.max(root.height, root.verboseMinHeight) : root.height
        z: 200
        enabled: root.allowModeSwitch && root.swipeToSwitchMode

        // Is the pointer over a terminal that actually has content cut off?
        function _overScrollableTerminal(wx, wy) {
            if (root.verbosityMode !== "verbose") return false;
            if (!termView || !termView.visible) return false;
            if (!termView.horizontallyScrollable) return false;
            const p = swipeArea.mapToItem(termView, wx, wy);
            return p.x >= 0 && p.y >= 0 && p.x <= termView.width && p.y <= termView.height;
        }

        turned: wheel => {
            root._swipeWheel(wheel, wheel.x, wheel.y);
            // Never consume it: the lists still need the vertical component.
            wheel.accepted = false;
        }
    }

    // THE SWIPE READER: one function for the two ways a wheel of the gesture arrives -- the area above
    // (this popup's own body) and the host's hand-over (`gestureWheel`, below). `x`, `y` are in the swipe
    // area's frame, and only mean anything for the event that BEGINS a gesture.
    function _swipeWheel(ev, x, y) {
        const angleDelta = ev.angleDelta, pixelDelta = ev.pixelDelta;
        // Record first, vertical included, so the diagnostic readout
        // reflects everything that arrives rather than only what is used.
        if (root.diagnostics) {
            _wheelDiag.angleX = angleDelta.x;
            _wheelDiag.angleY = angleDelta.y;
            _wheelDiag.pixelX = pixelDelta.x;
            _wheelDiag.pixelY = pixelDelta.y;
            _wheelDiag.count += 1;
        }

        // A MOUSE: a sideways notch is a view (unless it is over cut-off terminal text, whose sideways it is); an upright one is the list's,
        // or the mode row's own.
        if (ev.device === "wheel") {
            if (angleDelta.x !== 0 && !swipeArea._overScrollableTerminal(x, y))
                modeTabs.applySteps(ev.steps);
            return;
        }

        let dx = angleDelta.x;
        if (dx === 0 && pixelDelta.x !== 0)
            dx = pixelDelta.x * root.swipePixelToAngle;
        let dy = angleDelta.y;
        if (dy === 0 && pixelDelta.y !== 0)
            dy = pixelDelta.y * root.swipePixelToAngle;

        // Zero on BOTH axes means the touchpad reported scroll-end, i.e.
        // the fingers left the surface.
        const ended = dx === 0 && dy === 0;

        if (ended) {
            root._endMotion();
            if (root.diagnostics) _wheelDiag.accum = modeTabs._swipeAccum;
            return;
        }

        gestureIdleTimer.restart();

        // The axis first (see `_axis`): a vertical motion is the list's, and ends here for the popup.
        if (root._axis === 2)
            return;
        if (root._axis === 0) {
            if (root._axisX === 0 && root._axisY === 0) {
                root._beginX = x;
                root._beginY = y;
            }
            root._axisX += Math.abs(dx);
            root._axisY += Math.abs(dy);
            root._axisSumX += dx;
            if (Math.max(root._axisX, root._axisY) < root.swipeAxisLockUnits)
                return;
            if (root._axisX >= root._axisY * root.swipeAxisRatio)
                root._axis = 1;
            else if (root._axisY >= root._axisX * root.swipeAxisRatio)
                root._axis = 2;
            else
                return;
            if (root._axis === 2)
                return;
            dx = root._axisSumX;     // what arrived while undecided belongs to the swipe
        }

        // Ownership is decided ONCE, when a gesture begins, and holds for
        // its whole life.
        //
        // Deciding per event would mean a swipe that started on the list
        // and dragged the view into verbose suddenly stopped switching the
        // moment the terminal slid under the pointer — so peeking at
        // verbose and carrying on to another view in one motion would be
        // impossible. Latching at the start also gives the natural rule for
        // the terminal itself: begin a gesture over cut-off text and it is
        // the terminal's, all of it.
        if (!root._gestureActive) {
            // Owner FIRST, then the flag. Raising `_gestureActive` grows
            // the area to the hold rect, and `x/y` are in the frame
            // the area had when the event arrived -- mapped through the
            // grown one they miss the terminal (CLAUDE.md).
            root._gestureOwnedByTerminal = swipeArea._overScrollableTerminal(root._beginX, root._beginY);
            root._gestureActive = true;
        }

        // Either way the event is passed through untouched, so the
        // terminal still scrolls horizontally; only the tab change is
        // withheld.
        if (dx !== 0 && !root._gestureOwnedByTerminal) {
            modeTabs.applySwipe(dx);
        }
        if (root.diagnostics) _wheelDiag.accum = modeTabs._swipeAccum;
    }

    // THE HOST'S HAND-OVER (GooeyEngine.gestureLayer; docs/contracts/gestures.md section 4). Once the view
    // has switched the box is smaller than the fingers' reach -- verbose to quiet takes the popup from 1080
    // px to 424 -- and a body clips its content, so a wheel that lands outside the new box reaches nothing
    // in it and the swipe would die after its first step. While
    // `swipeGestureActive` the engine hands every such wheel here; one that lands inside the box goes
    // through to the area above as always. False when no gesture is held.
    function gestureWheel(ev) {
        if (!root._gestureActive)
            return false;
        root._swipeWheel(ev, ev.x, ev.y);
        return true;
    }

    // =================================================================
    //  FAVOURITE FLIGHT
    //
    // The motion lives in RowFlight, shared with anything else that moves a
    // row between slots. What the popup supplies is the ghost's appearance
    // and the answers to the questions RowFlight asks about ITS model: where
    // the row is going, how to hold the slot it vacates open and let it go
    // again, how to commit the toggle, and where the row sits in the list.
    //
    // At the popup's root so no Flickable or category clip region can cut the
    // clone off mid-flight. The real row hides itself while its name matches
    // `flightOverlay.key`, so exactly one copy is ever on screen.
    // =================================================================
    RowFlight {
        id: flightOverlay
        anchors.fill: parent

        liftMs: root.flightLiftMs
        travelMs: root.flightTravelMs
        landMs: root.flightLandMs
        // A clone with nowhere to land leaves the way a row leaves a
        // collapsing list, so the two travel at the same speed.
        exitMs: root.rowAnimDuration
        liftScale: root.flightLiftScale
        shortDistance: root.flightShortDistance
        minTravelMs: root.flightMinTravelMs
        visibleInset: root.flightVisibleInset
        blurRefDistance: root.flightBlurRefDistance
        blurMax: root.flightBlurMax
        settleMs: root.flightSettleMs
        preMoveDelayMs: root.flightPreMoveDelayMs
        preDropDelayMs: root.flightPreDropDelayMs
        minTravel: root.flightMinTravel
        backingColor: root.surfaceColor

        // ---- What the popup answers -------------------------------------
        findDest: (name) => root._findPackageRow(name)
        // Where the row will COME TO REST, asked of the sections rather than
        // measured off the row, because the row is moving. Both summary
        // panels exist at once, so whichever one holds the row answers and
        // the other returns NaN.
        destTopIn: (item, name) => {
            let v = NaN;
            root._forEachSection(sec => {
                const x = sec.flightDestTopIn(item, name);
                if (!isNaN(x)) v = x;
            });
            return v;
        }
        beginGap: (name) => root._forEachSection(sec => sec.beginFlightGap(name))
        endGap: () => root._forEachSection(sec => sec.endFlightGap())
        indexOf: (name) => root._rowIndexOf(name)
        commit: (name) => {
            // Flip the clone's own copy so its stripe colour animates while
            // it is airborne and has settled by the time it lands. In the
            // same call as the model change, so no frame is drawn between
            // the two.
            const g = flightOverlay.cloneItem;
            const fd = g ? g.flightData : null;
            if (fd && fd.entry) g.flightData = {
                entry: { name: fd.entry.name, oldVer: fd.entry.oldVer,
                         newVer: fd.entry.newVer, isFavorite: !fd.entry.isFavorite },
                categoryColor: fd.categoryColor, iconGlyph: fd.iconGlyph
            };
            root.availableUpdates.toggleFavorite(name);
        }

        cloneComponent: Component {
            UpdatePackageRow {
                id: flightGhost
                // Distinct from the "updatePackageRow" tag the real rows
                // carry, so the destination search can never match the clone
                // itself.
                objectName: "updatePackageRowGhost"
                property var flightData: null
                entry: flightGhost.flightData ? flightGhost.flightData.entry : null
                categoryColor: flightGhost.flightData
                    ? flightGhost.flightData.categoryColor : root.accent
                // Without this the clone would render iconless and the package
                // would appear to regain its icon on landing.
                iconGlyph: flightGhost.flightData
                    ? flightGhost.flightData.iconGlyph : ""
                listScale: flightOverlay.cloneScaleFactor
                textColor: root.primaryText
                mutedColor: root.mutedText
                faintColor: root.faintText
                mutedGroundColor: root.listBoxColor
                fontFamily: root.fontFamily
            }
        }
    }




    // The category header's own flight. Everything host-specific about it is
    // in the SECTION FLIGHT block above; this is the motion and the ghost.
    RowFlight {
        id: sectionFlight
        anchors.fill: parent
        flick: listFlick

        liftMs: root.sectionFlightLiftMs
        travelMs: root.sectionFlightTravelMs
        landMs: root.sectionFlightLandMs
        exitMs: root.rowAnimDuration
        liftScale: root.sectionFlightLiftScale
        shortDistance: root.sectionFlightShortDistance
        minTravelMs: root.flightMinTravelMs
        visibleInset: root.flightVisibleInset
        blurRefDistance: root.flightBlurRefDistance
        blurMax: root.flightBlurMax
        settleMs: root.flightSettleMs
        preMoveDelayMs: root.sectionFlightPreMoveDelayMs
        preDropDelayMs: root.sectionFlightPreDropDelayMs
        // A lead change is a fact about the MODEL. The pixel backstop must not
        // veto it: the flyer's own hole is still open when the distance is
        // first measured, so a one-slot swap can read as no move at all.
        minTravel: 0
        // The header paints its own opaque box, and RowFlight's backing is
        // 2 px proud on each side -- it would only ever peek past the box's
        // corners.
        backingColor: "transparent"
        // Headers span the full list width (only ROWS are inset), and the
        // contact shadow's hard rect is 10 px proud on each side. Pulled back
        // to the clone's own width so it does not spill over the list box's
        // bevel, and in verbose over the terminal.
        contentInsetLeft: 10
        contentInsetRight: 10

        findDest: (key) => {
            const sec = root._sectionForKey(key);
            return sec ? sec.headerItem : null;
        }
        destTopIn: (item, key) => root._sectionDestTopIn(item, key)
        sourceTopIn: (item, key) => root._sectionSourceTopIn(item, key)
        beginGap: (key) => {
            root._secFlightKey = key;
            const sec = root._sectionForKey(key);
            if (sec) { sec.headerSuppressed = true; sec.flightClip = true; }
        }
        // Nothing moves here: the wanted order is published so `indexOf` can
        // answer from it, and the model itself is left alone until the ghost
        // has landed and the layout has already made the swap free.
        commit: (key) => {
            root._secFlightWant = root._secPendingWant;
            Qt.callLater(() => sectionFlight.reconciled());
        }
        indexOf: (key) => root._sectionWantIndexOf(key)
        endGap: () => {
            const sec = root._sectionForKey(root._secFlightKey);
            const want = root._secFlightWant;
            root._secRefillKey = root._secFlightKey;
            root._secFlightKey = "";
            root._secFlightWant = null;
            root._secPendingWant = null;
            if (sec) { sec.headerSuppressed = false; sec.flightClip = false; }
            // RowFlight sets `reveal` to 1 immediately before calling this, so
            // the destination is at full height and the flyer at none: the
            // move is geometrically a no-op at exactly this instant.
            if (want) root._applyCategories(want);
        }

        onEnded: {
            // Beat 3: the section is where it belongs, so let its rows come
            // back under it, staggered, on the list's own clock. One turn
            // later, because the column has not laid out the new order yet and
            // the entering wave is measured against where the rows will be.
            const refill = root._secRefillKey;
            Qt.callLater(() => root._refillSection(refill));
            if (root._pendingStepExpansion.length === 0) return;
            const step = root._pendingStepExpansion;
            root._pendingStepExpansion = "";
            root._applyStepExpansion(step);
        }

        cloneComponent: Component {
            ListSectionHeader {
                id: sectionGhost
                objectName: "updateCategoryHeaderGhost"
                property var flightData: null
                // Read off the header it was lifted from -- which is alive,
                // only hidden -- rather than a copy of two dozen properties
                // that would quietly drift from it.
                readonly property var _src: sectionGhost.flightData
                    ? sectionGhost.flightData.section.headerItem : null

                // The box IS the ghost: no trailing gap under it, so the
                // contact shadow hugs what is painted.
                bottomGap: 0

                title:            sectionGhost._src ? sectionGhost._src.title : ""
                subtitle:         sectionGhost._src ? sectionGhost._src.subtitle : ""
                accentColor:      sectionGhost._src ? sectionGhost._src.accentColor : root.accent
                progress:         sectionGhost._src ? sectionGhost._src.progress : -1
                progressFailed:   sectionGhost._src ? sectionGhost._src.progressFailed : false
                detailBytesDone:  sectionGhost._src ? sectionGhost._src.detailBytesDone : 0
                detailBytesTotal: sectionGhost._src ? sectionGhost._src.detailBytesTotal : 0
                detailRateText:   sectionGhost._src ? sectionGhost._src.detailRateText : ""
                detailEtaText:    sectionGhost._src ? sectionGhost._src.detailEtaText : ""
                iconGlyph:        sectionGhost._src ? sectionGhost._src.iconGlyph : ""
                expanded:         sectionGhost._src ? sectionGhost._src.expanded : false
                expandable:       sectionGhost._src ? sectionGhost._src.expandable : true
                compactLayout:    sectionGhost._src ? sectionGhost._src.compactLayout : false
                listScale:        sectionFlight.cloneScaleFactor
                boxRadius:        sectionGhost._src ? sectionGhost._src.boxRadius : 10
                containerRadius:  sectionGhost._src ? sectionGhost._src.containerRadius : 10
                // The corner it will wear when it lands, so it does not gain
                // or lose the container's radius on touchdown.
                firstInList: !!sectionGhost.flightData
                    && root._sectionLeadKey === sectionGhost.flightData.key

                textColor:  root.primaryText
                mutedColor: root.mutedText
                faintColor: root.faintText
                fontFamily: root.fontFamily
                boxColor: root.headerBoxColor
                boxSurfaceColor: root.listBoxColor
                boxBevelColor: root.headerBoxBevelColor
                boxShadowColor: root.headerBoxShadowColor
                boxPadding: root.headerBoxPadding
                boxPaddingV: root.headerBoxPaddingV
                idleWidthPx: root.headerIdleWidthPx
                boxIdleFeatherPx: root.headerIdleFeatherPx
                boxActiveFeatherPx: root.headerActiveFeatherPx
                boxShadowWidth: root.headerIdleWidth
                boxProgressShadowWidth: root.headerActiveWidth
                boxIdleEdgeAlpha: root.headerIdleEdgeAlpha
                boxActiveEdgeAlpha: root.headerActiveEdgeAlpha
                boxIdleFalloff: root.headerIdleFalloff
                boxActiveFalloff: root.headerActiveFalloff
                progressBlendEnd: root.headerProgressBlendEnd
            }
        }
    }

    // ---- Per-mode collapse persistence ----
    // Kept on the popup rather than on the sections: sections are rebuilt when the
    // category list changes (idle <-> run, a new source appearing), and without shared
    // state each rebuild would reset every category to `startExpanded:false`,
    // losing the user's expanded view.
    // This dict is keyed by section title and holds the user-toggled
    // expanded state. CategorySection mirrors its `_expanded` to/from
    // here on user toggle. Initialised lazily from `startExpanded`
    // when a section first reads from the dict (key absent = use
    // default).
    property var _sectionExpanded: ({})
    function _readSectionExpanded(key, fallback) {
        const v = root._sectionExpanded[key];
        return v === undefined ? fallback : !!v;
    }
    // A run keeps the user's own expanded state, so the list is exactly as
    // it was the moment the update started. The one thing a run adds is a
    // category shutting itself after it has drained, and that is an OVERLAY
    // -- "run:" keys -- cleared at the next run's start rather than written
    // into the preference.
    function _clearRunOverlay() {
        const next = {};
        for (const k in root._sectionExpanded)
            if (k.indexOf("run:") !== 0) next[k] = root._sectionExpanded[k];
        root._sectionExpanded = next;
    }
    // ---- Package groups --------------------------------------------------
    // Packages of one category that share a prefix (python-*, haskell-*, lib32-*) fold into one
    // row of the list's style (UpdateCategorySection); whether a group is open is kept with the categories' state, under a key of
    // its own ("grp:<category>:<prefix>"), so it survives a rebuild of the sections too.
    // Off, the list is flat.
    property bool groupPackages: root.groupMin > 0
    property int groupMin: 3
    // The categories whose lists are open as the popup opens (system_update.jsonc list.open: keys, or "all").
    property var openCategories: []
    function _openAtStart(cat) {
        return root.openCategories.indexOf("all") >= 0 || root.openCategories.indexOf(cat) >= 0;
    }
    property real groupIndent: 14
    function _groupStateKey(cat, prefix) { return "grp:" + cat + ":" + prefix; }
    // {prefix: true} for the open groups of one category. `dict` is the state it reads, passed
    // in so a binding on this call follows it.
    function _openGroupsFor(cat, dict) {
        const out = {}, head = "grp:" + cat + ":";
        for (const k in dict)
            if (dict[k] === true && k.indexOf(head) === 0) out[k.substring(head.length)] = true;
        return out;
    }
    // A header's right click: these packages become favourites, or stop being.
    function _setFavorites(names, favorite) {
        if (!root.availableUpdates) return;
        flightOverlay.cancel();
        for (const n of names) {
            if (favorite) root.availableUpdates.addFavorite(n);
            else root.availableUpdates.removeFavorite(n);
        }
    }
    function _writeSectionExpanded(key, value) {
        // Reassign the whole object so QML binding system sees a
        // change (Qt's `var` properties don't watch deep mutations).
        const next = Object.assign({}, root._sectionExpanded);
        next[key] = !!value;
        root._sectionExpanded = next;
    }

    // ---- Favourite flight -------------------------------------------------
    //
    // Right-clicking a row toggles its favourite state. Favourites sort to the
    // top of their own category, so the row physically moves; the flight is a
    // clone of it travelling from where it was to where it ends up, so the
    // move reads as one object rather than a disappearance and a reappearance.
    //
    // The motion -- lift, camera follow, blur, landing -- is RowFlight's. What is left here is
    // the decision of whether a flight is worth making at all, which is about
    // packages and categories rather than about motion.

    // Held still while a favourite flight is airborne -- otherwise the landing
    // slot could scroll away mid-flight and the clone would visibly miss it.
    readonly property bool scrollLocked: flightOverlay.scrollLocked || sectionFlight.scrollLocked

    // =================================================================
    //  SECTION FLIGHT -- a category header changing its place in the list
    //
    // AUR takes the lead while it builds and gives it back when it is done,
    // which is two reorders per update, and a bare ListModel.move would make both a teleport: it
    // keeps the Repeater's delegates and the ColumnLayout
    // re-places them in the same frame, so the state is right and nothing
    // interpolates. The header travels instead, on the same machinery a
    // favourited package row uses.
    //
    // The HEADER flies, not the section. When AUR leads it is also the section
    // that OPENS, so its body is arbitrarily tall and already animating; a
    // clone of that would be larger than the popup and would carry a live copy
    // of the row model with it. What migrates is the section's SPACE, and that
    // is done in the layout: the flyer's cell shrinks to nothing while the
    // space at its destination opens, both on the flight's own `reveal`.
    //
    // A SECOND RowFlight, not the favourite one. `flightOverlay.key` is bound
    // into every section as `suppressedRow` and compared against package
    // NAMES; a section flight setting key = "aur" there would hide any package
    // called aur/core/extra/multilib in every category at once. The two share
    // the scroll lock and the motion blur, and cancel each other.
    // =================================================================
    property bool sectionFlightEnabled: true
    // Space between category sections. A per-section MARGIN rather than the
    // layout's own spacing, so a section giving up its slot gives up its gap
    // with it -- with the layout's spacing the gap lands on the other side of
    // the moved section and the swap ends on a 6 px step.
    property real sectionGap: 6

    // The section is shut for the length of the flight. A category whose rows
    // are ON SCREEN cannot have them carried by the header's ghost -- the
    // ghost is the header alone -- so the rows LEAVE at the old place and
    // COME BACK at the new one, which is what docs/contracts/list_animation.md
    // calls a swap: a collapse followed by an expand. Three beats, each with
    // ONE clock:
    //
    //   1 the rows exit, staggered, under their own header  (the list's clock)
    //   2 the header flies to its new slot                  (the flight's)
    //   3 the rows enter, staggered, under it again         (the list's)
    //
    // Sequential on purpose. Run together, the flight measures a destination
    // and a slot height that are both still animating, which is the two-clock
    // fault RowFlight's own header is written about.
    //
    // The section empties ITSELF (`emptyForFlight`), rather than the popup
    // overriding its `expanded` binding: the user's preference is not what is
    // changing, and a favourite row is kept by a collapse but must NOT be kept
    // by this -- a favourite left behind is the one row that would still
    // teleport, and it is what makes the reserved space a row taller than the
    // header landing in it.
    property string _secFlightKey: ""
    // The wanted order is held back until `commit`. RowFlight asks `indexOf`
    // once before it and once after, and ends the flight when the two agree --
    // publishing the want any earlier makes both answers the destination and
    // every flight ends before it starts.
    property var    _secPendingWant: null
    property var    _secFlightWant: null
    property real   _secFlightH: 0

    // Diagnostics for the mockup's Run page.
    readonly property string categoryOrderText: root._categoryKeys().join(" · ")
    readonly property bool   sectionFlightActive: sectionFlight.active
    readonly property string sectionFlightKey: root._secFlightKey

    readonly property Item _sectionsColumn: listPanel.sectionsColumn
    function _sectionForKey(key) {
        let out = null;
        root._forEachSection(sec => { if (sec.categoryKey === key) out = sec; });
        return out;
    }
    function _wantKeys() {
        return root._secFlightWant ? root._secFlightWant.map(x => x.catKey) : root._categoryKeys();
    }
    // The index the model WILL have. RowFlight compares before and after to
    // decide whether anything is moving, and the model has not moved yet.
    function _sectionWantIndexOf(key) { return root._wantKeys().indexOf(key); }

    // ---- The layout's share of the flight ---------------------------------
    //
    // Every figure below is a factor, so the sum of the cells is the same on
    // both sides of the swap and no section steps at the handover. Worked
    // through in both directions (AUR to the front, AUR back to the end):
    //
    //   height   flyer only, 1 -> 0
    //   top gap  flyer:  its own gap, 1 -> 0
    //            others: the gap its MODEL index implies -> the one its WANTED
    //                    index implies, so the section that becomes first
    //                    loses its gap exactly as the flyer's slot closes
    //   pad      the flyer's whole cell (height + the gap its wanted index
    //            implies), opening where it will land: above the section that
    //            follows it, or below the one that precedes it when it lands
    //            last
    readonly property real _secReveal: sectionFlight.active ? sectionFlight.reveal : 1
    // Gap the key's MODEL index implies, and the one its WANTED index implies.
    function _secGapAt(key)   { return root._categoryKeys().indexOf(key) === 0 ? 0 : 1; }
    function _secGapWant(key) { return root._wantKeys().indexOf(key) === 0 ? 0 : 1; }
    // The one section that is not flying but whose gap still changes: the one
    // that becomes, or stops being, the first in the list.
    readonly property string _secDeltaKey: {
        const serial = root._categoryOrderSerial;   // the dependency, see above
        if (!sectionFlight.active) return "";
        const keys = root._categoryKeys();
        for (const k of keys) {
            if (k === root._secFlightKey) continue;
            if (root._secGapAt(k) !== root._secGapWant(k)) return k;
        }
        return "";
    }
    // EVERY figure below is a WHOLE number, and the pad is the remainder
    // rather than a formula of its own. The arithmetic is exactly constant in
    // reals, but a ColumnLayout rounds each cell it is given, and three
    // independently rounded cells do not add up to a rounded constant -- the
    // column would breathe a pixel for the length of every flight. Taking the pad
    // as "what is left of the constant" makes the integer sum exact.
    readonly property real _secConst: sectionFlight.active
        ? Math.round(root._secFlightH) + root.sectionGap * root._secGapAt(root._secFlightKey) : 0
    readonly property real _secFlyerTop: sectionFlight.active
        ? Math.round(root.sectionGap * root._secGapAt(root._secFlightKey) * (1 - root._secReveal)) : 0
    readonly property real _secFlyerH: sectionFlight.active
        ? Math.round(root._secFlightH * (1 - root._secReveal)) : 0
    readonly property real _secOtherGap: {
        if (!sectionFlight.active || root._secDeltaKey.length === 0) return 0;
        const k = root._secDeltaKey;
        return Math.round(root.sectionGap
            * (root._secGapWant(k) - root._secGapAt(k)) * root._secReveal);
    }
    readonly property real _secPad: sectionFlight.active
        ? root._secConst - root._secFlyerTop - root._secFlyerH - root._secOtherGap : 0

    // The section the space opens ABOVE (the flyer's follower in the wanted
    // order), and the one it opens BELOW when the flyer lands last.
    readonly property string _secPadAbove: {
        if (!sectionFlight.active) return "";
        const w = root._wantKeys();
        const i = w.indexOf(root._secFlightKey);
        return (i >= 0 && i + 1 < w.length) ? w[i + 1] : "";
    }
    readonly property string _secPadBelow: {
        if (!sectionFlight.active) return "";
        const w = root._wantKeys();
        const i = w.indexOf(root._secFlightKey);
        return (i > 0 && i === w.length - 1) ? w[i - 1] : "";
    }
    // ---- What the delegate asks for --------------------------------------
    // WHOLE PIXELS, in a flight and out of one. A ColumnLayout works in
    // integers, so summing fractional cells and rounding the total is not the
    // same number as rounding each cell -- and the flight's own figures have
    // to be integers for the pad to absorb the rounding. Rounding here as well
    // means the resting column and the flying one are the same height, which
    // is the difference between a flight that is exact and one that steps a
    // pixel the moment it starts. Sections sit on whole pixels either way,
    // which a carved edge wants anyway.
    function _sectionHeightFor(key, implicitH) {
        return (sectionFlight.active && key === root._secFlightKey)
            ? root._secFlyerH : Math.round(implicitH);
    }
    function _sectionTopMarginFor(key) {
        const serial = root._categoryOrderSerial;   // the dependency, see above
        if (!sectionFlight.active) return root.sectionGap * root._secGapAt(key);
        if (key === root._secFlightKey) return root._secFlyerTop;
        let m = root.sectionGap * root._secGapAt(key);
        if (key === root._secDeltaKey) m += root._secOtherGap;
        if (key === root._secPadAbove) m += root._secPad;
        return m;
    }
    function _sectionBottomMarginFor(key) {
        return (sectionFlight.active && key === root._secPadBelow) ? root._secPad : 0;
    }
    // Which header wears the container's corner. It changes hands halfway
    // through the travel, by which time the space has opened and the section
    // that was at the top is no longer there.
    readonly property string _sectionLeadKey: {
        const serial = root._categoryOrderSerial;   // the dependency, see above
        const cur = root._categoryKeys();
        const curLead = cur.length > 0 ? cur[0] : "";
        if (!sectionFlight.active) return curLead;
        const w = root._wantKeys();
        const wantLead = w.length > 0 ? w[0] : "";
        return root._secReveal >= 0.5 ? wantLead : curLead;
    }

    // ---- Where it is going, summed from the WANTED order ------------------
    //
    // Analytic, never measured off a delegate: the destination is moving at
    // exactly the moment the flight asks (UpdateCategorySection has the
    // row version of this), and the flyer's own hole moves too, which is
    // what sourceTopIn is for.
    function _sectionDestTopIn(item, key) {
        const col = root._sectionsColumn;
        if (!col || !root._secFlightWant) return NaN;
        const w = root._wantKeys();
        let y = 0;
        for (let i = 0; i < w.length; i++) {
            if (w[i] === key) break;
            const sec = root._sectionForKey(w[i]);
            // Rounded, because that is what the layout will give them.
            y += (i === 0 ? 0 : root.sectionGap)
               + (sec ? Math.round(sec.implicitHeight) : 0);
        }
        if (w.indexOf(key) > 0) y += root.sectionGap;
        return col.mapToItem(item, 0, y).y;
    }
    function _sectionSourceTopIn(item, key) {
        const sec = root._sectionForKey(key);
        return sec ? sec.mapToItem(item, 0, 0).y : NaN;
    }

    function _beginSectionFlight(key, want) {
        const sec = root._sectionForKey(key);
        if (!sec || !sec.headerItem) return false;
        // One clone in the air at a time. A favourite in flight has measured
        // every number against a list whose sections are about to move.
        flightOverlay.cancel();
        root._secPendingWant = want;
        // Beat 1, when there is anything to see leave. A category with no
        // rows on screen at all flies at once.
        if (sec.rowCount > 0) {
            root._secAwaitCollapse = key;
            sec.emptyForFlight();
            return true;
        }
        return root._flySection(key);
    }
    // Beat 2. Measured HERE, not when the reorder was decided: after a
    // collapse the section is a different height, and the space that migrates
    // is the one it has NOW.
    function _flySection(key) {
        const sec = root._sectionForKey(key);
        if (!sec || !sec.headerItem || !root._secPendingWant) {
            root._cancelSectionFlight();
            return false;
        }
        root._secFlightH = sec.implicitHeight;
        if (sectionFlight.begin(key, sec.headerItem, { section: sec, key: key }))
            return true;
        root._cancelSectionFlight();
        return false;
    }
    // Whatever we were part-way through, put the list back the way it was and
    // apply the order outright. A section left collapsed by a flight that
    // never started would stay collapsed with no way back.
    function _cancelSectionFlight() {
        const want = root._secPendingWant;
        const key = root._secAwaitCollapse.length > 0 ? root._secAwaitCollapse : root._secRefillKey;
        root._secAwaitCollapse = "";
        root._secPendingWant = null;
        if (want) root._applyCategories(want);
        root._refillSection(key);
    }
    // The section waiting to be filled again once its header has landed.
    property string _secRefillKey: ""
    function _refillSection(key) {
        root._secRefillKey = "";
        if (key.length === 0) return;
        const sec = root._sectionForKey(key);
        if (sec) sec.refillAfterFlight();
    }
    // The section whose collapse the flight is waiting on.
    property string _secAwaitCollapse: ""
    // Backstop. Every path out of `_close()` reports, but a section torn down
    // mid-collapse reports nothing, and a category left shut by a flight that
    // never happened has no way back.
    Timer {
        id: secCollapseWatchdog
        running: root._secAwaitCollapse.length > 0
        interval: root.rowAnimDuration + root.flightSettleMs + 900
        repeat: false
        onTriggered: {
            const key = root._secAwaitCollapse;
            root._secAwaitCollapse = "";
            if (key.length > 0) root._flySection(key);
        }
    }
    function _sectionTransitionFinished(key) {
        root._releaseScrollLock();
        if (key !== root._secAwaitCollapse) return;
        root._secAwaitCollapse = "";
        // One turn later: `transitionFinished` can arrive from inside the
        // `expanded` change itself (a section with nothing to animate reports
        // at once), and the flight must not begin inside the binding that
        // caused it.
        Qt.callLater(() => root._flySection(key));
    }

    // ---- Flight tuning (nothing derived from panel size) ----
    property int  flightLiftMs: 160
    property int  flightTravelMs: 340
    property int  flightLandMs: 160
    property real flightLiftScale: 1.055
    // Travel time is constant, except for genuinely short hops: below this
    // distance it scales down so a two-row move is not padded out to the full
    // duration.
    property real flightShortDistance: 220
    property int  flightMinTravelMs: 130
    // Blur peaks when the list travels this far; further than that and it is
    // already saturated.
    // The list is only scrolled when the destination would otherwise be off
    // screen. Inset from the viewport edges (as a fraction of its height)
    // before a destination counts as "comfortably visible", so a row does not
    // land flush against an edge.
    property real flightVisibleInset: 0.08
    property real flightBlurRefDistance: 700
    property real flightBlurMax: 0.55
    // Long enough for the sections' queued re-sync AND the resulting Column
    // relayout to land, since no lift runs first to cover it.
    property int  flightSettleMs: 90
    // Beat before the clone starts travelling, and again before it drops into
    // place. Gives the eye a moment to register the lift as a distinct step
    // rather than one continuous slide.
    property int  flightPreMoveDelayMs: 100
    property int  flightPreDropDelayMs: 100
    // Below this the row is not really moving, so there is nothing for a
    // flight to convey.
    property real flightMinTravel: 4

    // ---- Header flight tuning ----
    // A whole section is a heavier object than a row, so it travels a little
    // more deliberately; everything else is the row flight's numbers.
    property int  sectionFlightLiftMs: 160
    property int  sectionFlightTravelMs: 420
    property int  sectionFlightLandMs: 180
    property real sectionFlightLiftScale: 1.03
    property real sectionFlightShortDistance: 220
    property int  sectionFlightPreMoveDelayMs: 100
    property int  sectionFlightPreDropDelayMs: 100

    function _releaseScrollLock() {
        flightOverlay.releaseScrollLock();
        sectionFlight.releaseScrollLock();
    }

    // Walk up to the category section a row belongs to.
    function _sectionFor(item) {
        let cur = item ? item.parent : null;
        while (cur) {
            if (cur.categoryKey !== undefined && cur.expanded !== undefined) return cur;
            cur = cur.parent;
        }
        return null;
    }

    function _beginFavoriteFlight(name, rowItem) {
        if (!root.availableUpdates) return;
        if (!rowItem || flightOverlay.active || sectionFlight.active) {
            root.availableUpdates.toggleFavorite(name);
            return;
        }

        // Un-favouriting inside a COLLAPSED category: the row is leaving the
        // visible list entirely and belongs back among the hidden rows. There
        // is no destination to fly to and nothing to convey by lifting it, so
        // no clone is made at all -- the incremental sync marks the row
        // "leaving" and it slides out to the right exactly like a row does
        // when its list collapses, then reappears in place next time the
        // category is opened.
        const sec = root._sectionFor(rowItem);
        const isFav = !!(rowItem.entry && rowItem.entry.isFavorite);
        if (isFav && sec && !sec.expanded) {
            root.availableUpdates.toggleFavorite(name);
            return;
        }
        // An expanded row would otherwise snap shut the instant it is hidden
        // for the flight. Collapse it first, in view, then fly the collapsed
        // form -- the shape that is about to land is the shape that leaves.
        if (rowItem.expanded) {
            rowItem.expanded = false;
            _collapseThenFly.rowItem = rowItem;
            _collapseThenFly.pkgName = name;
            _collapseThenFly.restart();
            return;
        }
        _launchFlight(name, rowItem);
    }

    Timer {
        id: _collapseThenFly
        property var rowItem: null
        property string pkgName: ""
        // Matches UpdatePackageRow's own expand animation, so the flight picks
        // up exactly as the row finishes folding.
        interval: 240
        repeat: false
        onTriggered: root._launchFlight(pkgName, rowItem)
    }

    function _launchFlight(name, rowItem) {
        const e = rowItem ? rowItem.entry : null;
        if (!e) { root.availableUpdates.toggleFavorite(name); return; }
        // Only what the ghost draws itself from. The row's own listScale is
        // read by RowFlight, so the clone matches the density it left.
        flightOverlay.begin(name, rowItem, {
            entry: { name: e.name, oldVer: e.oldVer, newVer: e.newVer,
                     isFavorite: !!e.isFavorite },
            categoryColor: rowItem.categoryColor,
            iconGlyph: rowItem.iconGlyph
        });
    }

    // Position of a package in the service model. Used to decide whether a
    // toggle actually moves the row, which is a question about the MODEL and
    // must not be answered by measuring pixels: the sections re-sync on a
    // callLater and re-lay out after that, so immediately post-toggle the row
    // is still sitting at its old coordinates and every move looks like a
    // no-move.
    function _rowIndexOf(name) {
        if (!root.availableUpdates) return -1;
        const m = root.availableUpdates.updates;
        for (let i = 0; i < m.count; i++)
            if (m.get(i).name === name) return i;
        return -1;
    }

    // A view switch mid-flight ends the flight. Every number the flight
    // runs on -- scroll from/to, travel target, the clone's scale -- was
    // measured against the list as it was, and the switch changes the list
    // scale and the box width under it. The toggle itself was committed at
    // launch, so ending early just lets the row appear in its new slot.
    onVerbosityModeChanged: { flightOverlay.cancel(); sectionFlight.cancel(); root._holdTabs(); }

    // Depth-first search for the live row of `name`. Rows tag themselves with
    // objectName so the walk cannot pick up an arbitrary Item.
    function _findPackageRow(name) { return root._findRowRec(root, name); }

    // Walk every category section, wherever it is in the tree. Both summary
    // panels exist at once (normal and verbose), so a flight has to reach the
    // sections in whichever one is showing.
    function _forEachSection(fn) { root._sectionRec(root, fn); }
    function _sectionRec(item, fn) {
        if (!item) return;
        if (item.objectName === "updateCategorySection") fn(item);
        const cs = item.children;
        if (cs) for (let i = 0; i < cs.length; i++) root._sectionRec(cs[i], fn);
    }
    function _findRowRec(item, name) {
        if (!item) return null;
        // The real row is deliberately hidden (contentVisible false) while
        // its clone is in flight — it is still the destination, so hidden-ness
        // must NOT disqualify it. The clone is excluded by objectName instead.
        if (item.objectName === "updatePackageRow"
            && item.entry && item.entry.name === name) {
            return item;
        }
        const cs = item.children;
        if (cs) {
            for (let i = 0; i < cs.length; i++) {
                const r = root._findRowRec(cs[i], name);
                if (r) return r;
            }
        }
        return null;
    }

    // Colour per category, matching yay's own syntax highlighting so the
    // popup and the terminal agree: core amber-orange, extra green,
    // multilib cyan, AUR blue. Unknown sources fall back to the accent.
    function categoryColor(key) {
        switch (key) {
            case "core":     return root.repoCoreColor;
            case "extra":    return root.repoExtraColor;
            case "multilib": return root.repoMultilibColor;
            case "aur":      return root.aurCategoryColor;
            case "flatpak":  return root.flatpakColor;
            default:         return root.accent;
        }
    }

    // Display name per category. Prefers whatever the service publishes so
    // idle and running lists never disagree on a label, and falls back to a
    // capitalised key for a category only the transaction knows about.
    function categoryLabel(key) {
        const svc = root.availableUpdates;
        if (svc && svc.categoryMeta && svc.categoryMeta[key]
            && svc.categoryMeta[key].label)
            return svc.categoryMeta[key].label;
        if (!key || key.length === 0) return "";
        return key.charAt(0).toUpperCase() + key.slice(1);
    }

    // =================================================================
    //  STEP-RELATIVE STATUS
    //
    // A package's standing relative to the CURRENT step, not its raw state.
    //
    // The raw state is the wrong thing to put on a row: during the download
    // step a package that has finished downloading is done, and marking it
    // with a download arrow says the opposite. During install that same
    // package is pending again. Resolving the mark per step is what makes a
    // row read as "done with what is happening now", which is also what the
    // category header counts.
    // =================================================================
    // A package's standing in a step, from the ORDER of its states rather
    // than a per-step table: each step has the states it is busy with and
    // the state that means it is through. Post-install steps (hooks, and the
    // overview after the run) have nothing to be busy with -- an installed
    // package is done, anything else is still to come.
    readonly property var _stateRank: ({
        "queued": 0, "downloading": 1, "downloaded": 2, "fetching": 2,
        // Built, handed to pacman, not yet written. Below "built" on purpose:
        // the AUR step reads anything from 5 up as finished, and the whole
        // point of the state is that these rows are NOT finished any more.
        "sources-ready": 3, "staged": 3, "building": 4, "built": 5, "installing": 6,
        "installed": 7, "removed": 7
    })
    function _stepStatus(st, step, isAur) {
        if (!st || st.length === 0) return "";
        if (st === "failed") return "failed";
        // pacman downloads nothing for an AUR package; in the download step
        // it is neither pending nor done, and reading its 'fetching' state
        // as past 'downloaded' would call the AUR category finished before a
        // single byte has moved.
        if (isAur && step === "download") return "pending";
        const rank = root._stateRank[st] !== undefined ? root._stateRank[st] : 0;
        switch (step) {
            case "download":
                if (st === "downloading") return "active";
                return rank >= 2 ? "done" : "pending";
            case "sources":
                if (st === "fetching") return "active";
                return rank >= 3 ? "done" : "pending";
            case "install":
                if (st === "installing") return "active";
                return rank >= 7 ? "done" : "pending";
            case "aur":
                // Only a package being worked on is active. One that has its
                // sources and waits for its turn at the build is PENDING:
                // counted active it would draw the figures its source download
                // ended on ("44.3 / 57.5 MiB . 11.0 MiB/s . 00:01") under
                // every waiting package for the whole build of the others.
                if (st === "fetching" || st === "building") return "active";
                return rank >= 5 ? "done" : "pending";
            default:
                // hooks, and the held overview: nothing is worked on per
                // package.
                return rank >= 7 ? "done" : "pending";
        }
    }

    // =================================================================
    //  PROMPT REPLY
    // =================================================================
    // Phase whose prompt the user has already answered. The phase label lags
    // the answer (it only moves on when the next phase marker arrives), so
    // without this the backstop above would keep the input on screen after it
    // had been submitted.
    property string _answeredPhase: ""

    // Bumped every time the AUR rows are put back to "not installed yet", so
    // the sections can start their drain over without the step key -- and the
    // rail -- moving backwards.
    property int _aurResetSerial: 0
    Connections {
        target: root.parser
        ignoreUnknownSignals: true
        function onAurInstallReset() {
            root._aurResetSerial = root._aurResetSerial + 1;
            // The AUR category drained and shut itself when the last build
            // finished. Its packages are about to do something visible again,
            // so the run's own overlay key reopens it -- never the base key,
            // which is the user's idle preference.
            root._writeSectionExpanded("run:aur", true);
        }
    }

    function _sendPromptReply(text) {
        if (!root.backend || !root._promptVisible) return;
        if (root.parser) root._answeredPhase = root.parser.phase;
        // "Proceed?" for the AUR transaction. The parser reaches the same
        // latched call when pacman's integrity pass starts, but that is a
        // second or two later; doing it on the click is what makes the answer
        // feel like it did something.
        if (root.parser && root._promptKind === "pacman_proceed"
                && root.parser.phase === "AUR_INSTALL"
                && !/^n/i.test(text) && root.parser.resetAurForInstall)
            root.parser.resetAurForInstall();
        // Skipped packages leave the list: the parser drops them and every
        // row still showing takes its exit. yay itself only ever shows the
        // remaining set from here on, so the list would be wrong otherwise.
        if (root.parser && root._promptKind === "yay_exclude" && root.parser.excludeSelection)
            root.parser.excludeSelection(text);
        // "Yes, skip the above package": the package named in the warning
        // leaves the list too, or it sits there queued for the whole run.
        if (root.parser && root._promptKind === "yay_skip_dep" && /^y/i.test(text)
            && root.parser.skipContextPackages)
            root.parser.skipContextPackages();
        root.backend.submit(text);
    }

    // =================================================================
    //  INLINE COMPONENTS
    // =================================================================

    // A "section block": optional title with a line divider, then stacked
    // content. Inner slot is a ColumnLayout so Layout.fillWidth children
    // size correctly. Empty title → header row collapses entirely.
    component SectionBlock: ColumnLayout {
        id: blockRoot
        property string title: ""
        property color titleColor: root.mutedText
        // Inset from the container's edge, the same as a list row. The title
        // and the rule beside it are CONTENT, and content does not run into
        // the carved box's own edge -- only a category header does, and only
        // because its box is meant to meet the container's corner.
        property real inset: root.listInset
        default property alias blockContent: _slot.data
        spacing: 6

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: blockRoot.inset
            Layout.rightMargin: blockRoot.inset
            spacing: 6
            visible: blockRoot.title.length > 0
            Text {
                text: blockRoot.title
                color: blockRoot.titleColor
                font.family: root.fontFamily
                font.pixelSize: 11
                font.bold: true
            }
            Rectangle {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                implicitHeight: 1
                color: root.borderColor
            }
        }

        ColumnLayout {
            id: _slot
            Layout.fillWidth: true
            Layout.leftMargin: blockRoot.inset
            Layout.rightMargin: blockRoot.inset
            spacing: 6
        }
    }

    // One error row.
    // Carved, like every other container in the shell, rather than a fill
    // with a hairline around it. Same colours: the error red is the deepest
    // part of the inset shadow instead of a hard 1 px edge, so the box reads
    // as sunk into the list rather than drawn on top of it.
    component ErrorRow: ShadowBox {
        property var err: null
        Layout.fillWidth: true
        implicitHeight: errRowCol.implicitHeight + 12
        baseRadius: 8
        backgroundColor: root.errTint
        shadowColor: root.errColor
        bevelColor: root.bevelColor
        surfaceColor: root.listBoxColor
        shadowWidth: 3
        bevelWidth: 1

        ColumnLayout {
            id: errRowCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: 6
            spacing: 2

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Text {
                    text: "✗"
                    color: root.errColor
                    font.family: root.fontFamily
                    font.pixelSize: 13
                    font.bold: true
                    Layout.preferredWidth: 14
                    horizontalAlignment: Text.AlignHCenter
                }
                Text {
                    text: err ? err.pkg : ""
                    // THEMED. Eva-light literals here (a very dark red on a pale pink tint)
                    // would leave the package name all but invisible on the dark theme, where the
                    // tint is a dark maroon (#53363B). The mark beside it already says
                    // "error" in the theme's own red; the name says it in the
                    // same red, and the reason under it is ordinary muted ink.
                    color: root.errColor
                    font.family: root.fontFamily
                    font.pixelSize: 12
                    font.bold: true
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }
            }
            Text {
                Layout.fillWidth: true
                text: err ? err.reason : ""
                color: root.mutedText
                font.family: root.fontFamily
                font.pixelSize: 10
                wrapMode: Text.WordWrap
            }
        }
    }

    // The list itself: the category sections in order, with the rows a
    // section holds and the space between them. The panel is one component so
    // the normal and the verbose lists cannot drift apart.
    component SummaryPanel: ColumnLayout {
        id: panel
        property bool compact: false
        property real listScale: 1.0
        // Horizontal inset applied to ROWS only. Headers span the full width
        // so their boxes can meet the container's edges.
        property real rowInset: 0
        // Radius the topmost header's box takes, to share the container's
        // corner. 0 leaves it square.
        property real containerRadius: 0
        // The Flickable this panel scrolls in, so its sections can work out
        // which rows are on screen.
        property Item viewport: null
        // The column the category sections live in, so the section flight can
        // measure a destination in its coordinates.
        readonly property alias sectionsColumn: sectionsCol
        spacing: compact ? 8 : 12

        // --- IDLE-MODE: categorized available updates -------------------
        // Sections are generated from the service's live `categories` list
        // (core / extra / multilib / aur / flatpak / any future source)
        // rather than a hardcoded Official / AUR / Flatpak trio, so a new
        // source appears here the moment the service can report it.
        ColumnLayout {
            id: sectionsCol
            Layout.fillWidth: true
            // The gap between sections is a per-section MARGIN, not the
            // layout's spacing: a section giving up its slot to a flight has
            // to give up its gap with it, and the layout's own spacing lands
            // on the other side of a moved item -- a 6 px step on the last
            // frame of every reorder, invisible in code.
            spacing: 0
            // Visible during a run as well as idle. This is the per-package
            // half of the display: idle it lists what is available, running it
            // lists what the transaction is actually doing, package by package.
            visible: (root._idle && root._hasService) || !root._idle


            Repeater {
                // Running, the categories come from what the transaction
                // actually contains — which includes pulled-in dependencies
                // the available-updates scan never saw.
                model: categoryModel

                delegate: UpdateCategorySection {
                    id: catSection
                    required property string catKey
                    required property string catLabel
                    required property int catCount
                    required property int index

                    Layout.fillWidth: true
                    // Height and gap are both factors of the section flight, so
                    // the column's total is identical on both sides of a swap
                    // and nothing steps at the handover.
                    Layout.preferredHeight:
                        root._sectionHeightFor(catSection.catKey, catSection.implicitHeight)
                    Layout.topMargin: root._sectionTopMarginFor(catSection.catKey)
                    Layout.bottomMargin: root._sectionBottomMarginFor(catSection.catKey)
                    // A shrunk Layout cell does not clip children placed by
                    // anchors, so the section says when to.
                    clip: catSection.flightClip

                    service: root.availableUpdates
                    // Run dress only once the parser knows the transaction;
                    // until then the cached idle rows stay on screen.
                    runMode: root._showingRun && root._parserHasPackages && root._runListSettled
                    keepFavorites: root._preDownload
                    showStepCounts: !root._preDownload
                    // Verbose's narrow list: count on the title line, the
                    // figures on their own line, smaller.
                    compactLayout: panel.compact
                    busyLink: root._opener.busyName
                    onOpenUrlRequested: (name, isAur) => {
                        root._opener.open(name, isAur);
                        root.closeRequested();
                    }
                    // Every header's box shares the container's corner
                    // radius (handed over pre-divided by the list scale).
                    headerBoxRadius: panel.containerRadius / Math.max(0.2, panel.listScale)
                    runModel: root.parser ? root.parser.packages : null
                    runSource: root.parser
                    firstInList: catSection.catKey === root._sectionLeadKey
                    // The header box sits ON the container's bounds, so it takes the
                    // container's own radius.
                    containerRadius: panel.containerRadius
                    rowInset: panel.rowInset

                    headerBoxPadding: root.headerBoxPadding
                    headerBoxColor: root.headerBoxColor
                    headerBoxSurfaceColor: root.listBoxColor
                    headerBoxBevelColor: root.headerBoxBevelColor
                    headerBoxShadowColor: root.headerBoxShadowColor
                    headerBoxPaddingV: root.headerBoxPaddingV
                    headerIdleWidthPx: root.headerIdleWidthPx
                    headerIdleFeatherPx: root.headerIdleFeatherPx
                    headerActiveFeatherPx: root.headerActiveFeatherPx
                    headerIdleWidth: root.headerIdleWidth
                    headerActiveWidth: root.headerActiveWidth
                    headerIdleEdgeAlpha: root.headerIdleEdgeAlpha
                    headerActiveEdgeAlpha: root.headerActiveEdgeAlpha
                    headerIdleFalloff: root.headerIdleFalloff
                    headerActiveFalloff: root.headerActiveFalloff
                    headerProgressBlendEnd: root.headerProgressBlendEnd
                    // The held overview keeps a step key, so the headers stay
                    // lit and counted as finished instead of dropping to the
                    // idle mark the moment the process exits.
                    // A held run reads as "done" only when it IS: a run that
                    // died in its download keeps the step it died in, so the
                    // overview says how far it got (core 2/5, its sweep where
                    // it stopped) instead of re-reading every row against
                    // "installed" and showing 0/5 under a red headline.
                    runStepKey: root._runHeld && (!root.parser || root.parser.errorCount === 0)
                                ? "done" : root._currentStep
                    // Only the AUR category starts its step over.
                    stepPass: catSection.catKey === "aur" ? root._aurResetSerial : 0
                    showNumbers: root._showPackageNumbers
                    activePackage: root._activePackage
                    activeDetail: root._activeDetail
                    stepStatusFor: (st, isAur) => root._stepStatus(st, root._currentStep, isAur)
                    categoryKey: catSection.catKey
                    label: catSection.catLabel
                    count: catSection.catCount
                    accentColor: root.categoryColor(catSection.catKey)

                    textColor: root.primaryText
                    mutedColor: root.mutedText
                    faintColor: root.faintText
                    fontFamily: root.fontFamily

                    // Expansion state lives on the popup so it survives a
                    // rebuild of the sections.
                    // A run keeps the idle preference: the list stays exactly
                    // as it was when the update started.
                    expanded: root._readSectionExpanded(catSection.catKey, root._openAtStart(catSection.catKey))
                        && (!root._showingRun || root._readSectionExpanded("run:" + catSection.catKey, true))
                    // `next` is taken ONCE. The first write re-evaluates the
                    // `expanded` binding, so a second `!expanded` after it
                    // would already be the opposite answer -- opening the
                    // category and shutting it again in the same click.
                    onToggleRequested: {
                        const next = !expanded;
                        root._writeSectionExpanded(catSection.catKey, next);
                        if (root._showingRun) root._writeSectionExpanded("run:" + catSection.catKey, next);
                    }
                    // Packages that share a prefix fold under a header of their own; which of
                    // those are open lives here too, beside the categories'.
                    groupsEnabled: root.groupPackages
                    groupMin: root.groupMin
                    groupIndent: root.groupIndent
                    expandedGroups: root._openGroupsFor(catSection.catKey, root._sectionExpanded)
                    onGroupToggleRequested: (groupKey, open) =>
                        root._writeSectionExpanded(root._groupStateKey(catSection.catKey, groupKey), open)
                    onGroupFavoriteRequested: (groupKey, names, favorite) =>
                        root._setFavorites(names, favorite)
                    // The category drained itself: it has refilled with every
                    // package so a later phase can still be inspected, and now
                    // wants to be shut.
                    onAutoCollapseRequested:
                        root._writeSectionExpanded("run:" + catSection.catKey, false)
                    onRowsReconciled: flightOverlay.reconciled()

                    // Hide the real row while its clone is in flight.
                    suppressedRow: flightOverlay.key
                    suppressedReveal: flightOverlay.reveal
                    // Lets the section work out which of its rows are actually
                    // on screen, so only those are animated.
                    viewport: panel.viewport
                    iconResolver: (n, c) => root.packageIcons.glyphFor(n, c)
                    listScale: panel.listScale
                    animDuration: root.rowAnimDuration

                    onFavoriteToggleRequested: (name, rowItem) =>
                        root._beginFavoriteFlight(name, rowItem)
                    onTransitionFinished: root._sectionTransitionFinished(catSection.catKey)
                }
            }
        }

        // --- Notices ---
        // Not errors: things the run said in passing that the user would
        // otherwise only see by watching the terminal at the right second.
        // One example is "Run 'systemctl --user daemon-reload'", a real
        // chore nobody would otherwise be told about.
        SectionBlock {
            Layout.fillWidth: true
            title: "Notices (" + (root.parser ? root.parser.noticeCount : 0) + ")"
            titleColor: root.warnStrongColor
            visible: root.parser && root.parser.noticeCount > 0

            Repeater {
                model: root.parser ? root.parser.notices : null
                delegate: RowLayout {
                    id: noticeRow
                    required property var model
                    Layout.fillWidth: true
                    spacing: 8
                    // No card and no tint. A notice is not an error, and a
                    // second boxed thing under the list would read as one.
                    Text {
                        text: "!"
                        color: root.warnStrongColor
                        font.family: root.fontFamily
                        font.pixelSize: 12
                        // NOT bold. At this size a bold exclamation mark is a
                        // stem two pixels wide with a dot under it and no
                        // shape left to read.
                        Layout.preferredWidth: 10
                        Layout.alignment: Qt.AlignTop
                        horizontalAlignment: Text.AlignHCenter
                    }
                    Text {
                        Layout.fillWidth: true
                        text: noticeRow.model.text
                        color: root.mutedText
                        font.family: root.fontFamily
                        font.pixelSize: 11
                        wrapMode: Text.WordWrap
                    }
                }
            }
        }

        // --- Errors ---
        SectionBlock {
            Layout.fillWidth: true
            title: "Errors (" + (root.parser ? root.parser.errorCount : 0) + ")"
            titleColor: root.errColor
            visible: root.parser && root.parser.errorCount > 0

            Repeater {
                model: root.parser ? root.parser.errors : null
                delegate: ErrorRow {
                    required property var model
                    Layout.fillWidth: true
                    err: model
                }
            }
        }

        Item { Layout.preferredHeight: 4 }
    }
}
