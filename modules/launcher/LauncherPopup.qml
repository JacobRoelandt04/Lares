pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window

import "../common/theme"
import "../common/components"
import "../common/components/LevelMorph.js" as LM
import "../common/components/EditKeys.js" as EK
import "../wiki"
import "browse"

// =============================================================================
// LauncherPopup.qml -- the application launcher, a drop-in for thePopup.
//
// Holds nothing that must outlive it: the service (the apps, the query, the
// sort and layout, the folder being viewed, favourites and frecency) lives
// bar-side (LauncherBarOwner); this is built on every open.
//
// HOST CONTRACT (GooeyEngine; docs/contracts/gooey_engine.md):
//   implicitWidth/Height   the layout's size: one list, or N columns, always
//                          `rows` rows tall -- the popup never resizes while
//                          you type (fixed rows, the list scrolls)
//   keyboardFocusRequest   "exclusive" when the shortcut opened it (typing
//                          goes here at once); a hover-opened one takes the
//                          keyboard in a pulse, as notes does, then asks for
//                          "onDemand" so a click elsewhere takes it away. Opened
//                          over the user's file browser (`keysFree`, set by the
//                          owner) it asks for "onDemand" from the start and never
//                          pulses: its keys stay with the browser until the
//                          launcher is clicked
//   swipeGestureActive / gestureHoldWidth / gestureHoldHeight / gestureWheel
//                          the folder's two-finger back (SwipeScrub)
//   hostRoom, cornerRadii  assigned by the host: the fades are cut to the
//                          popup's real corners
//   closeRequested()       Escape at the root with no query, or a launch
//                          with the confirm flourish off
//   engaged()              the user typed, moved the highlight or dragged:
//                          a hover-opened launcher stays open after this
//
// THE WIKI TEASER (docs/wiki.md): with a
// wiki service injected (`wiki`, by LauncherBarOwner) and `tune.wikiTeaser`,
// the foot carries one line, today's Discover article; a click closes the
// launcher and asks the service to open the clock popup's wiki card
// (`wiki.requestOpen("discover")`). Its slot is STATIC -- a padding and
// `tune.teaserHeight`, decided by those two alone, never by an article
// arriving or by what is typed -- so the popup does not resize through it.
// No service (null): nothing is built and every size is the launcher's own.
//
// OWNER CONTRACT (LauncherBarOwner): `flourish` (its ConfirmFlourish: a
// launch hands it the row, and it closes the launcher itself), contentGone()
// (this content's end: the owner's session reset waits for it, not for the
// close's start) and freshen() (a reopen that finds this content
// still closing: the engine reopens the same one).
//
// Content paints no background; the host's surface is the ground.
// =============================================================================
Item {
    id: popup

    property var service: null
    // The wiki service (WikiService / WikiMock), injected by the owner; null:
    // no teaser at all.
    property var wiki: null
    property LauncherTune tune: null
    // Opened by the shortcut (not by hovering the bar): the keyboard is ours.
    property bool keyboardOwned: false
    // Opened over the user's file browser: the launcher takes no keys of its own accord -- no
    // hover pulse -- and a click on it (on-demand) is what gives it the keyboard (LauncherBarOwner).
    property bool keysFree: false
    // The owner's confirm flourish (ConfirmFlourish), or null: a launch then
    // closes the popup plainly.
    property var flourish: null
    // launcher.jsonc `flourish` "off": no launch plays it.
    property bool flourishOff: false
    // launcher.jsonc `answers.takesEnter`: an answer takes the highlight, so Enter copies it.
    property bool answerTakesEnter: true
    // A launch's row has gone to the flourish, or the wiki teaser has sent
    // the launcher away: the popup is closing, and takes no more input.
    property bool confirmed: false
    enabled: !popup.confirmed

    readonly property real pad: popup.tune ? popup.tune.padding : 12
    readonly property real rowH: popup.tune ? popup.tune.iconSize + 2 * popup.tune.rowInset : 52
    // launcher.jsonc's numbers, through the service's null-safe mirrors.
    readonly property int rows: popup.service ? Math.max(1, popup.service.gridRows) : 9
    readonly property int columns: popup.service && popup.service.layout === "columns" ? Math.max(1, popup.service.gridColumns) : 1
    // The teaser's slot: one more padding and the line, under the rows (so the
    // padding above the header, between the parts and below the foot stays
    // one number). Decided by the service being there and the tune's switch
    // ONLY -- never by the article, the list or the query.
    readonly property bool _teaserOn: !!popup.wiki && (popup.tune ? popup.tune.wikiTeaser : true)
    readonly property real _teaserH: Math.round(popup.tune ? popup.tune.teaserHeight : 18)
    readonly property real _footExtra: popup._teaserOn ? Math.round(popup.pad) + popup._teaserH : 0
    readonly property real _listWidth: popup.columns === 1 ? (popup.tune ? popup.tune.listWidth : 420) : popup.columns * (popup.tune ? popup.tune.columnWidth : 300) + (popup.columns - 1) * (popup.tune ? popup.tune.columnGap : 12) + 2 * popup.pad

    // ---- Host contract ---------------------------------------------------------------------------------
    implicitWidth: Math.round(popup._listWidth)
    // The padding, the header, the padding, the rows, the padding: as much
    // room above the header as below the last row (the house rule; four
    // paddings would leave 21 px under the rows where 12 are due). With the
    // wiki teaser: one more padding and the line, then the same last padding.
    implicitHeight: Math.round(3 * popup.pad + header.implicitHeight + popup.rows * popup.rowH) + popup._footExtra
    property var hostRoom: null
    property var cornerRadii: [0, 0, 0, 0]
    readonly property string _edge: popup.hostRoom && popup.hostRoom.edge ? popup.hostRoom.edge : "bottom"
    // The popup's outline in `item`'s coordinates, for the fades: the
    // corners that hang from the bar are not free (0).
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

    property bool _focusPulse: false
    // A focus grab holds the keyboard (the shell: the owner's HyprlandFocusGrab on the bar window, active
    // while a shortcut-opened launcher is up). The grab IS the keyboard and the dismissal in one -- the
    // keys go to the window whatever its mode, a click anywhere else clears the grab, closes the launcher
    // and is not delivered -- so the layer asks for NO keyboard of its own: Exclusive on top would take
    // every pointer from every window and the grab would never clear, leaving a
    // launcher no click can close.
    property bool grabbed: false
    readonly property string keyboardFocusRequest: popup.grabbed ? "none"
        : popup.keyboardOwned || popup._focusPulse ? "exclusive" : "onDemand"
    function pulseKeyboard() {
        if (popup.keyboardOwned || popup.keysFree || popup.Window.active)
            return;
        popup._focusPulse = true;
        focusPulse.restart();
    }
    Timer {
        id: focusPulse
        interval: 120
        onTriggered: popup._focusPulse = false
    }
    readonly property alias hovered: hover.hovered
    HoverHandler {
        id: hover
        onHoveredChanged: {
            if (hovered)
                popup.pulseKeyboard();
        }
    }

    signal closeRequested
    signal engaged
    signal contentGone

    Component.onCompleted: {
        popup.pulseKeyboard();
        grid.forceActiveFocus();
    }
    Component.onDestruction: {
        if (popup._m)
            popup._finishNow();
        popup.contentGone();
    }

    // ---- Keys and pointer, from the grid -------------------------------------------------------------
    // The whole Escape chain as one call that says it handled the key (true), so a host that hears
    // Escape itself -- the shell's Escape bind -- can offer it here before closing anything; the grid's
    // own key goes through the same function.
    function handleEscape() {
        if (popup._m) {
            popup.goBack();
            return true;
        }
        if (popup.service.query !== "")
            popup.service.setQuery("");
        else if (popup.service.hiddenView)
            popup.service.setHiddenView(false);
        else if (popup.service.folder !== "")
            popup.goBack();
        else
            popup.closeRequested();
        return true;
    }
    readonly property var _sortCycle: ["default", "name", "recent"]
    function cycleSort(dir) {
        const s = popup.service;
        const i = popup._sortCycle.indexOf(s.sortMode);
        const n = popup._sortCycle.length;
        s.setSort(popup._sortCycle[((i < 0 ? 0 : i) + dir + n) % n], s.sortAscending);
    }
    // Enter or a click: the launch, and the confirm flourish carries the row
    // off (it closes the popup, holding the close while the row lifts out).
    // Shift+Enter (or a shift-click): the launch, a pulse of the row, and the
    // launcher stays. The row is captured BEFORE the launch: its frecency
    // re-sorts the list a moment later, and the grid is frozen before that
    // lands. A motion in the way does not cost the flourish: a
    // folder's morph is finished first and a landing clone put down (as a
    // cut does), and the row is taken where it then stands; only a favourite
    // still in the air or a row being dragged closes the popup plainly.
    // A row's click and Enter. In the hidden view that takes the hidden tag off (the row leaves the list and the launcher stays):
    // Shift keeps meaning "open and stay", and the right click opens it as usual (openHiddenRow).
    function activate(key, keepOpen) {
        const s = popup.service;
        if (s.hiddenView && !keepOpen) {
            const e = s.entry(key);
            if (e)
                s.unhide(e.desktopId);
            popup.engaged();
            return;
        }
        popup.launch(key, keepOpen);
    }
    function launch(key, keepOpen) {
        if (keepOpen) {
            if (popup.service.launch(key, true))
                grid.pulse(key);
            return;
        }
        const fl = popup.flourish;
        const flourishing = !!fl && !!popup.tune && !popup.flourishOff;
        if (flourishing) {
            if (popup._m)
                popup._finishNow();
            grid.settleForLaunch();
        }
        const cap = flourishing ? grid.flourishCapture(key) : null;
        if (cap) {
            cap.room = popup.hostRoom;
            grid.frozen = true;
        }
        const ok = popup.service.launch(key, false);
        if (cap && ok && fl.start(cap)) {
            // The same frame as the flourish's first: the row is the flourish's.
            grid.hiddenKey = key;
            popup.confirmed = true;
            return;
        }
        grid.frozen = false;
        popup.closeRequested();
    }
    // A reopen while this content is still closing: the engine takes it back
    // as it is, so what a launch left (the frozen list, the row's gap, the
    // input off) goes first; the owner has reset the session.
    // ---- The quick answer (AnswerRow) --------------------------------------------------------------------
    // The first slot of the list while an answer exists: the list below it is one row shorter, the popup is not. Only at rest
    // (never under a folder's morph) and never in the hidden-apps view. Enter copies the main form and closes the launcher,
    // Shift+Enter copies and stays ("Copied" in the expr slot for answerCopiedMs); a click does the same, an alt's click copies the alt.
    readonly property var answer: popup.service && popup.service.answerSerial >= 0 && popup.service.answers.length > 0 ? popup.service.answers[0] : null
    readonly property real _answerRoom: !!popup.answer && !popup._m && !popup.service.hiddenView ? popup.rowH : 0
    property bool _copiedFlash: false
    property string _selQuery: ""
    Connections {
        target: popup.service
        // The first answer of a query takes the highlight, unless launcher.jsonc says it does not (a pending one replaced by its landed one does not take it again).
        function onAnswerSerialChanged() {
            if (popup.answer && popup.service.query !== popup._selQuery) {
                popup._selQuery = popup.service.query;
                grid.answerSelRaw = popup.answerTakesEnter;
            }
        }
        function onQueryChanged() {
            if (popup.service.query === "")
                popup._selQuery = "";
        }
    }
    Timer {
        id: copiedTimer
        interval: popup.tune ? popup.tune.answerCopiedMs : 1200
        onTriggered: popup._copiedFlash = false
    }
    function copyAnswerText(text, keepOpen) {
        // A click on the row while it fades out has nothing to copy.
        if (!popup.answer)
            return;
        popup.service.copyAnswer(text);
        if (keepOpen) {
            popup._copiedFlash = true;
            copiedTimer.restart();
        } else {
            popup.closeRequested();
        }
    }
    function freshen() {
        if (popup._m)
            popup._finishNow();
        rowMenu.open = false;
        popup.confirmed = false;
        grid.frozen = false;
        grid.hiddenKey = "";
        grid.refreshOrder();
        // An open starts at the top, the highlight on the first row.
        grid.stopScroll();
        grid.flick.contentY = 0;
        grid.current = 0;
        grid._userMoved = false;
        // The first pointer event after it is Qt's hover, as on a fresh open.
        grid._pointerScene = {
            x: -1e6,
            y: -1e6
        };
    }

    // ---- The folder morph: notes' group morph ---------------------------------------------------------
    // A folder row grows into the popup and its items arrive inside it; back
    // shrinks it into its row again, and a two-finger swipe scrubs back. ONE
    // clock (MorphClock) drives the card, the parent level receding (fading,
    // zooming 6 % towards the row), the folder's rows arriving (scaled with
    // the card, never cut mid-word), the chevron and the title's room for
    // it. An open changes the service at its start (the level arrived at is
    // laid out from it); a back changes it at its END, so a swipe that is let
    // go changes nothing. One object per morph (`_m`), read alone: a flag and
    // the object read side by side can come from two generations (CLAUDE.md).
    //
    //   _m = { dir: "open" | "back", key, facts, minis, fromRect, focus,
    //          parent, fromBack, toBack, cancelled }
    property var _m: null
    readonly property bool morphing: popup._m !== null
    MorphClock {
        id: clock
        morphMs: popup.tune ? popup.tune.morphMs : 320
        onLanded: popup._morphLanded()
    }
    readonly property real me: clock.me
    readonly property var _fr: popup._m ? LM.fractions(popup._m.dir, popup.me) : ({
            recede: 1,
            zoom: 1,
            arrive: 1,
            faceF: 0
        })

    // The folder row on this frame, in the body's coordinates: the captured
    // rect for an open, the parent level's live row for a back, through the
    // zoom of the level it sits in.
    function _tileRect() {
        const m = popup._m;
        let r = m.dir === "open" ? m.fromRect : grid2.rectOf(m.key);
        if (!r)
            r = {
                x: body.width / 2,
                y: body.height / 2,
                w: 0,
                h: 0
            };
        return LM.zoomRect(r, m.focus, popup._fr.zoom);
    }
    readonly property var cardRect: popup._m ? LM.cardRect(popup._tileRect(), {
            x: 0,
            y: 0,
            w: body.width,
            h: body.height
        }, popup._m.dir, popup.me) : null

    // `rename`: the folder menu's Rename -- once the folder is open, the
    // caret goes to its name in the header.
    function openFolder(key, rename) {
        if (popup._m)
            popup._finishNow();
        popup._renameOnOpen = rename === true ? key : "";
        const s = popup.service;
        const e = s.entry(key);
        if (!e || e.kind !== "folder")
            return;
        // Out of a search (a pinned folder heads every query's hits): the
        // query goes and the folder is a page of its own, placed -- the
        // level it would recede into is not the page on screen.
        if (s.query !== "") {
            s.setQuery("");
            s.openFolder(key);
            // The list first: the folder menu's Rename then takes the
            // keyboard from it (the other way round the list would take it back).
            grid.forceActiveFocus();
            popup._folderOpened();
            popup.engaged();
            return;
        }
        // The card grows out of the row, so the row is on screen first (a
        // click can only land on a shown row; anything else opening a
        // folder would grow the card from off the list).
        grid.reveal(key);
        const r = grid.rectOf(key);
        grid2.folder = s.folder;
        grid.stopScroll();
        grid2.stopScroll();
        grid2.flick.contentY = grid.flick.contentY;
        grid2.hiddenKey = key;
        popup._m = {
            dir: "open",
            key: key,
            facts: e,
            minis: grid.minisOf(key),
            fromRect: r,
            focus: r ? {
                x: r.x + r.w / 2,
                y: r.y + r.h / 2
            } : {
                x: body.width / 2,
                y: body.height / 2
            },
            parent: s.folder,
            fromBack: popup.backF,
            toBack: 1
        };
        clock.stop();
        clock.mt = 0;
        s.openFolder(key);
        clock.runTo(1);
        grid.forceActiveFocus();
        popup.engaged();
    }

    function goBack() {
        if (popup._m) {
            if (popup._m.dir === "open") {
                popup._reverse();
                return;
            }
            popup._finishNow();
        }
        if (popup.service.folder !== "")
            popup._startBack(false);
    }
    function _startBack(scrub) {
        const s = popup.service;
        const key = s.folder;
        grid2.folder = "";
        grid2.stopScroll();
        grid2.flick.contentY = 0;
        // The folder just left stands in the MIDDLE of the list (clamped at its ends), not at the foot.
        grid2.centreRow(key);
        grid2.hiddenKey = key;
        const r = grid2.rectOf(key);
        popup._m = {
            dir: "back",
            key: key,
            facts: s.entry(key),
            minis: grid2.minisOf(key),
            fromRect: r,
            focus: r ? {
                x: r.x + r.w / 2,
                y: r.y + r.h / 2
            } : {
                x: body.width / 2,
                y: body.height / 2
            },
            parent: "",
            fromBack: popup.backF,
            toBack: 0,
            cancelled: false
        };
        clock.stop();
        clock.mt = 0;
        if (!scrub)
            clock.runTo(1);
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
        if (clock.mt >= 1 && m.dir === "back" && !m.cancelled)
            popup._applyBack(m);
        else if (clock.mt <= 0 && m.dir === "open" && m.reversed)
            popup.service.closeFolder();
        if (clock.mt >= 1 || clock.mt <= 0)
            popup._clearMorph();
    }
    function _finishNow() {
        const m = popup._m;
        if (!m)
            return;
        clock.stop();
        if (m.dir === "back" && !m.cancelled)
            popup._applyBack(m);
        else if (m.dir === "open" && m.reversed)
            popup.service.closeFolder();
        popup._clearMorph();
    }
    function _applyBack(m) {
        grid2.stopScroll();
        const y = grid2.flick.contentY;
        popup.service.closeFolder();
        grid.stopScroll();
        grid.flick.contentY = y;
    }
    function _clearMorph() {
        clock.stop();
        grid.hiddenKey = "";
        grid2.hiddenKey = "";
        popup._m = null;
        clock.mt = 0;
        grid2.folder = "\u0000";
        if (popup._renameOnOpen === "" && !grid.activeFocus)
            grid.forceActiveFocus();
        popup._folderOpened();
    }
    // The folder menu's Rename: the folder is opened, and once it has
    // landed the caret is in its name in the header (the on-disk rename,
    // notes' group rename).
    property string _renameOnOpen: ""
    function _folderOpened() {
        const k = popup._renameOnOpen;
        popup._renameOnOpen = "";
        if (k !== "" && popup.service.folder === k)
            header.focusFolderName();
    }
    // Harnesses: hold the morph at clock `t`, and let it go on.
    function pinMorph(t) {
        clock.stop();
        clock.mt = t;
    }
    function releaseMorph() {
        if (popup._m)
            clock.runTo(popup._m.reversed || popup._m.cancelled ? 0 : 1);
    }

    // The chevron and the title's room for it: one fraction, carried by the
    // morph's clock while a folder opens or closes, eased alone otherwise.
    readonly property bool canBack: !!popup.service && popup.service.folder !== ""
    property real _backRest: popup.canBack ? 1 : 0
    onCanBackChanged: {
        backAnim.stop();
        if (popup._m)
            popup._backRest = popup.canBack ? 1 : 0;
        else {
            backAnim.to = popup.canBack ? 1 : 0;
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
    readonly property real backF: popup._m ? LM.lerp(popup._m.fromBack, popup._m.toBack, popup.me) : popup._backRest

    // ---- Two fingers to the right: back out of a folder ------------------------------------------------
    SwipeScrub {
        id: swipe
        anchors.fill: parent
        z: 800
        enabled: popup.canBack || (popup._m !== null && popup._m.dir === "back")
        units: popup.tune ? popup.tune.swipeBackUnits : 900
        sign: popup.tune ? popup.tune.swipeBackSign : 1
        // A back that was COMMITTED (lifted past the third, a tilt notch, Escape) is still playing out on its own clock: the fingers
        // that carry on, or the next stray wheel, must not start a second one over it (a double exit animation:
        // SwipeScrub would begin anew during a committed morph). Not blocked: a scrub under the fingers
        // (`swipe.active`), a spring-back (`cancelled`) and an open, which a swipe takes over.
        blocked: !!popup._m && popup._m.dir === "back" && !swipe.active && !popup._m.cancelled
        onScrub: p => {
            if (!popup._m && popup.service.folder !== "")
                popup._startBack(true);
            if (popup._m && popup._m.dir === "back")
                clock.scrubTo(p);
        }
        // A commit with no scrub before it is a mouse's tilt notch: one
        // whole back.
        onCommit: {
            if (popup._m && popup._m.dir === "back")
                clock.runTo(1);
            else
                popup.goBack();
        }
        onCancel: {
            if (popup._m && popup._m.dir === "back") {
                const n = Object.assign({}, popup._m);
                n.cancelled = true;
                popup._m = n;
                clock.runTo(0);
            }
        }
    }
    readonly property bool swipeGestureActive: swipe.active
    readonly property real gestureHoldWidth: popup.width
    readonly property real gestureHoldHeight: popup.height
    function gestureWheel(ev) {
        return swipe.gestureWheel(ev);
    }

    // ---- Layout -----------------------------------------------------------------------------------------
    // Everything is laid out at the size the popup ASKED for, never at the
    // host's easing box: the box grows from the bar as the popup opens, and a
    // page that followed it would re-lay itself out on the way (CLAUDE.md) --
    // every name would be elided at the first frame's width and stay empty.
    // The growing box reveals the finished page.
    readonly property real layoutWidth: popup.implicitWidth
    LauncherHeader {
        id: header
        objectName: "launcherHeader"
        x: 0
        y: popup.pad
        width: popup.layoutWidth
        implicitHeight: popup.tune ? popup.tune.headerHeight : 32
        height: implicitHeight
        service: popup.service
        overlayItem: overlay
        fontFamily: popup.tune ? popup.tune.fontFamily : "Inter"
        folderKey: popup._m && popup._m.dir === "back" ? popup._m.parent : (popup.service ? popup.service.folder : "")
        backF: popup.backF
        onBackClicked: popup.goBack()
        // The header holds the typed name until the rename answers (done or
        // refused); the answer may come after this popup is gone, so the
        // header is held by reference and asked only if it still stands.
        onRenameFolder: text => {
            const h = header;
            if (popup.service.folder === "") {
                h.renameAnswered();
                return;
            }
            popup.service.renameFolder(popup.service.folder, text, () => {
                if (h && typeof h.renameAnswered === "function")
                    h.renameAnswered();
            });
        }
        onEditEnded: grid.forceActiveFocus()
        onHiddenViewToggled: {
            if (popup._m)
                popup._finishNow();
            popup.service.setHiddenView(!popup.service.hiddenView);
            grid.forceActiveFocus();
        }
    }

    Item {
        id: body
        // The rows start one padding under the header; the grid keeps a
        // bevel's slack above and below them inside its own clip.
        readonly property real slack: 3
        x: 0
        y: header.y + header.height + popup.pad - body.slack
        width: popup.layoutWidth
        height: popup.rows * popup.rowH + 2 * body.slack
        clip: popup._m !== null

        // The parent level while a folder opens (receding) or closes (the
        // level arrived at). Idle it shows a level that cannot exist.
        LauncherGrid {
            id: grid2
            objectName: "parentGrid"
            x: 0
            y: 0
            width: body.width
            height: body.height
            visible: popup._m !== null
            enabled: false
            primary: false
            folder: "\u0000"
            columns: popup.columns
            opacity: popup._fr.recede
            transform: Scale {
                origin.x: popup._m ? popup._m.focus.x : 0
                origin.y: popup._m ? popup._m.focus.y : 0
                xScale: popup._fr.zoom
                yScale: popup._fr.zoom
            }
            service: popup.service
            tune: popup.tune
            overlayItem: overlay
            ground: Theme.surface
            outline: popup._m ? popup.outlineIn(body) : null
        }

        MorphCard {
            id: card
            readonly property var cr: popup.cardRect
            visible: card.cr !== null
            x: card.cr ? card.cr.x : 0
            y: card.cr ? card.cr.y : 0
            width: card.cr ? card.cr.w : 0
            height: card.cr ? card.cr.h : 0
            readonly property var m: popup._m
            facts: card.m ? card.m.facts : null
            grow: card.m ? (card.m.dir === "open" ? popup.me : 1 - popup.me) : 0
            faceF: popup._fr.faceF
            tileW: card.m && card.m.fromRect ? card.m.fromRect.w : body.width
            tileH: popup.rowH
            tileRadius: popup.tune ? popup.tune.wellRadius : 10
            tileColor: Theme.panelSunk
            groundColor: Theme.surface
            radii: [0, 0, 0, 0]
            // A folder is a carved well, not a raised tile.
            raised: false
            face: Component {
                FolderRow {
                    facts: card.m ? card.m.facts : null
                    minis: card.m ? card.m.minis : []
                    tune: popup.tune
                }
            }
        }

        AnswerRow {
            id: answerRow
            objectName: "answerRow"
            x: popup.pad
            y: body.slack
            width: body.width - 2 * popup.pad
            height: popup.rowH
            tune: popup.tune
            answer: popup._answerRoom > 0 ? popup.answer : null
            selected: grid.answerSel
            copied: popup._copiedFlash
            onCopyMain: keepOpen => popup.copyAnswerText(popup.answer ? popup.answer.copy : "", keepOpen)
            onCopyAlt: (text, keepOpen) => popup.copyAnswerText(text, keepOpen)
            onPointerMoved: {
                grid.answerSelRaw = true;
                popup.engaged();
            }
        }

        // The level being viewed, cut to the card while a folder opens or
        // closes, and scaled with it as a phone scales an app's window.
        Item {
            id: gridClip
            readonly property var r: popup.cardRect || ({
                    x: 0,
                    y: 0,
                    w: body.width,
                    h: body.height
                })
            x: gridClip.r.x
            y: gridClip.r.y + popup._answerRoom
            width: gridClip.r.w
            height: gridClip.r.h - popup._answerRoom
            clip: popup.cardRect !== null
            opacity: popup.cardRect !== null ? popup._fr.arrive : 1

            LauncherGrid {
                id: grid
                objectName: "launcherGrid"
                readonly property real s: popup.cardRect ? popup.cardRect.s : 1
                x: 0
                y: 0
                width: body.width
                height: body.height - popup._answerRoom
                answerOn: !!popup.answer && !popup.service.hiddenView
                onAnswerActivated: keepOpen => popup.copyAnswerText(popup.answer ? popup.answer.copy : "", keepOpen)
                transform: Scale {
                    xScale: grid.s
                    yScale: grid.s
                }
                primary: true
                columns: popup.columns
                service: popup.service
                tune: popup.tune
                overlayItem: overlay
                flightLayer: flightLayer
                ground: Theme.surface
                outline: popup.outlineIn(body)
                // Inside a folder, the header band is the drag's way out.
                exitRect: popup.service && popup.service.folder !== "" ? ({
                        x: 0,
                        y: -(header.height + popup.pad),
                        w: grid.width,
                        h: header.height
                    }) : null
                onActivated: (key, keepOpen) => popup.activate(key, keepOpen)
                onOpenFolder: key => popup.openFolder(key)
                // The hidden view has no context menu: a right click opens the app (the left one unhides it).
                onMenuRequested: (key, x, y) => popup.service.hiddenView ? popup.launch(key, false) : popup.openRowMenu(key, x, y)
                onExitRequested: {
                    // Back at the root the list is not at its top: the folder
                    // the item came out of is centred in the view, highlighted,
                    // in the frame the level returns.
                    const left = popup.service.folder;
                    popup.service.closeFolder();
                    grid.continueDrag();
                    grid.centreOn(left);
                }
                onTyped: text => {
                    // A leading space types nothing (as in the clipboard and the picker).
                    if (!(text === " " && popup.service.query === ""))
                        popup.service.setQuery(popup.service.query + text);
                }
                onQueryKilled: action => popup.service.setQuery(EK.queryAfter(action, popup.service.query))
                onBackspaced: {
                    if (popup.service.query !== "")
                        popup.service.setQuery(popup.service.query.slice(0, -1));
                    else if (popup.service.folder !== "")
                        popup.goBack();
                }
                onEscaped: popup.handleEscape()
                onSortStep: dir => popup.cycleSort(dir)
                onEngaged: popup.engaged()
            }
        }
    }

    // A query nothing matches (and no quick answer is, or is still coming): the sibling popups' empty words.
    Text {
        objectName: "launcherNoMatch"
        x: 0
        y: body.y + popup._answerRoom
        width: popup.layoutWidth
        height: body.height - popup._answerRoom
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: "No match"
        font.family: popup.tune ? popup.tune.fontFamily : "Inter"
        font.pixelSize: 14
        color: Theme.textFaint
        opacity: popup.service && popup.service.query.trim() !== "" && grid.order.length === 0 && !popup.answer && !popup.service.answersWaiting && !popup._m ? 1 : 0
        visible: opacity > 0
        Behavior on opacity {
            NumberAnimation {
                duration: 160
            }
        }
    }

    // The hidden view with nothing in it (the last row unhidden, or none hidden yet).
    Text {
        objectName: "noHiddenApps"
        x: 0
        y: body.y
        width: popup.layoutWidth
        height: body.height
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: "No hidden apps"
        font.family: popup.tune ? popup.tune.fontFamily : "Inter"
        font.pixelSize: 14
        color: Theme.textFaint   // as its sibling "No match" and the clipboard's and picker's empty words
        opacity: grid.hiddenView && popup.service.query === "" && grid.order.length === 0 ? 1 : 0
        visible: opacity > 0
        Behavior on opacity {
            NumberAnimation {
                duration: 160
            }
        }
    }

    // ---- The wiki teaser ---------------------------------------------------------------------------------
    // The foot's one line, on the rows' plates: its hover wash is the width of
    // a row's, and its glyph stands on the icons' left edge (the row inset).
    // Pinned to the size the popup ASKED for, one padding above the foot.
    Loader {
        id: teaserSlot
        objectName: "wikiTeaserSlot"
        active: popup._teaserOn
        x: Math.round(popup.pad)
        y: popup.implicitHeight - Math.round(popup.pad) - popup._teaserH
        width: popup.layoutWidth - 2 * Math.round(popup.pad)
        height: popup._teaserH
        sourceComponent: Component {
            WikiTeaser {
                anchors.fill: parent
                service: popup.wiki
                groundColor: Theme.surface
                fontFamily: popup.tune ? popup.tune.fontFamily : "Inter"
                // One of the rows: the glyph centred in the icon column, the words
                // on the names' edge, the rows' radius.
                glyphX: popup.tune ? popup.tune.rowInset + Math.round((popup.tune.iconSize - 14) / 2) : 19
                textX: popup.tune ? popup.tune.rowInset + popup.tune.iconSize + popup.tune.iconGap : 56
                washRadius: 10
                // The launcher goes first (the clock's popup then opens in the
                // other slot, as after any hover-out); nothing more is heard
                // from a popup that is closing.
                onActivated: {
                    const w = popup.wiki;
                    popup.confirmed = true;
                    popup.closeRequested();
                    if (w)
                        w.requestOpen("discover");
                }
            }
        }
    }

    // ---- Menus ------------------------------------------------------------------------------------------
    // A row's context menu (right-click). Rows are facts, never colours.
    //   an app or script   Favourite, Rename (a display title), Remove from
    //                      folder / Hide, Show in file manager (notes' entry:
    //                      the file chooser at the folder the row's own file
    //                      is in -- a link's, not its target's; the scripts
    //                      root for an app of the main list -- and what is
    //                      picked there is linked in, as a drop is), and on a
    //                      linked script or .desktop Remove from list (the
    //                      symlink only, never its target; asks first)
    //   a folder           Pin for this session (it heads every search's
    //                      hits until the launcher closes), Rename (the
    //                      folder itself, in the header), Show in file
    //                      manager, Remove folder (its items back to the top
    //                      level; nothing is deleted)
    property string _menuKey: ""
    FloatingMenu {
        id: rowMenu
        objectName: "rowMenu"
        overlayItem: overlay
        fontFamily: popup.tune ? popup.tune.fontFamily : "Inter"
        menuWidth: 190
        rows: {
            const e = popup._menuKey !== "" && popup.service && popup.service.serial >= 0 ? popup.service.entry(popup._menuKey) : null;
            if (!e)
                return [];
            if (e.kind === "folder")
                return [
                    {
                        id: "pin",
                        label: e.pinned ? "Unpin" : "Pin for this session"
                    },
                    {
                        id: "rename",
                        label: "Rename"
                    },
                    {
                        id: "reveal",
                        label: "Show in file manager"
                    },
                    {
                        separator: true
                    },
                    {
                        id: "rmfolder",
                        label: "Remove folder",
                        danger: true,
                        confirm: "Remove?"
                    }
                ];
            const out = [
                {
                    id: "fav",
                    label: e.favorite ? "Unfavourite" : "Favourite"
                },
                {
                    id: "rename",
                    label: "Rename"
                }
            ];
            if (e.folderKey)
                out.push({
                    id: "unlink",
                    label: "Remove from folder"
                });
            if (e.kind === "app" && !e.folderKey)
                out.push({
                    id: "hide",
                    label: "Hide"
                });
            if (e.isLink && e.kind !== "app")
                out.push({
                    id: "rmlink",
                    label: "Remove from list",
                    danger: true,
                    confirm: "Remove?"
                });
            out.push({
                separator: true
            }, {
                id: "reveal",
                label: "Show in file manager"
            });
            return out;
        }
        onTriggered: id => {
            const k = popup._menuKey;
            const s = popup.service;
            const e = s.entry(k);
            if (!e)
                return;
            if (id === "fav")
                grid.toggleFavourite(k, false);
            else if (id === "rename" && e.kind === "folder")
                popup.openFolder(k, true);
            else if (id === "rename")
                grid.beginRename(k);
            else if (id === "unlink")
                s.moveOut(k, null);
            else if (id === "hide")
                s.hide(k);
            else if (id === "rmlink")
                s.removeLink(k, null);
            else if (id === "reveal")
                s.showInFileManager(k, false);
            else if (id === "pin")
                s.pinFolder(k, !e.pinned);
            else if (id === "rmfolder")
                s.removeFolder(k, null);
        }
    }
    function openRowMenu(key, x, y) {
        popup._menuKey = key;
        popup._menuScroll = 0;
        popup._menuLastY = grid.flick.contentY;
        rowMenu.openAt(x, y);
        popup.engaged();
    }
    // Scrolling the list under an open row menu closes it once the list has
    // moved `menuScrollClosePx`: the menu belongs to a row that is
    // leaving; a nudge of the fingers does not throw it away.
    property real _menuScroll: 0
    property real _menuLastY: 0
    Connections {
        target: grid.flick
        enabled: rowMenu.open
        function onContentYChanged() {
            const y = grid.flick.contentY;
            popup._menuScroll += Math.abs(y - popup._menuLastY);
            popup._menuLastY = y;
            if (popup._menuScroll > (popup.tune ? popup.tune.menuScrollClosePx : 40))
                rowMenu.open = false;
        }
    }

    // The favourites file is written once the flight has landed (a write
    // mid-flight is a missed frame of it: the LLM sidebar's measured reason).
    Binding {
        target: popup.service
        property: "favWriteHold"
        value: grid.flying
    }

    // ---- Files dropped from a file manager ------------------------------------------------------------
    // The paths go to the service in ONE call (addDropped): a single file is linked into the level on screen;
    // two or more loose files on the main list become a new group, and a directory a group of its launchable
    // files (a folder open on screen takes the files as they are). The first row that lands is the
    // confirmation: scrolled to, centred in the view and highlighted at once (no glide).
    // A refused drop shakes the drop overlay's box and says why, in the service's words, in a note that fades.
    function linkPaths(paths) {
        if (popup._m)
            popup._finishNow();
        popup.service.setHiddenView(false);
        popup.service.addDropped(paths, popup.service.folder, (ok, res, err) => {
            const refused = res && res.refused ? res.refused : (ok ? [] : [{
                        path: paths.length > 0 ? paths[0] : "",
                        error: err
                    }]);
            if (refused.length > 0) {
                dropOverlay.refuse();
                popup.showDropNote(popup.service.dropRefusal(refused[0]) + (refused.length > 1 ? " (and " + (refused.length - 1) + " more)" : ""));
            }
            if (ok && res && res.key)
                grid.centreOn(res.key);
        });
        popup.engaged();
    }
    // The note keeps its words while it fades out; `dropNoteOn` is what shows it.
    property string dropNoteText: ""
    property bool dropNoteOn: false
    function showDropNote(text) {
        popup.dropNoteText = text;
        popup.dropNoteOn = true;
        dropNoteTimer.restart();
    }
    Timer {
        id: dropNoteTimer
        interval: 4500
        onTriggered: popup.dropNoteOn = false
    }
    TextMetrics {
        id: dropNoteMetrics
        font.family: popup.tune ? popup.tune.fontFamily : "Inter"
        font.pixelSize: 12
        text: popup.dropNoteText
    }
    Item {
        id: dropNote
        objectName: "dropNote"
        readonly property real maxW: popup.implicitWidth - 2 * popup.pad
        width: Math.ceil(Math.min(dropNote.maxW, dropNoteMetrics.advanceWidth + 28))
        height: 34
        x: Math.round((popup.width - dropNote.width) / 2)
        y: Math.round(popup.height * 0.5 - dropNote.height / 2)
        z: 960
        opacity: popup.dropNoteOn ? 1 : 0
        visible: dropNote.opacity > 0.01
        Behavior on opacity {
            NumberAnimation {
                duration: 160
                easing.type: Easing.OutCubic
            }
        }
        ShadowBox {
            anchors.fill: parent
            baseWidth: dropNote.width
            baseHeight: dropNote.height
            baseRadius: 10
            surfaceColor: Theme.surface
            bevelColor: Theme.bevel
            shadowColor: Theme.border
            backgroundColor: Theme.listBox
            bevelWidth: 1.5
            shadowWidth: 5
        }
        Text {
            anchors.fill: parent
            anchors.leftMargin: 14
            anchors.rightMargin: 14
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: popup.dropNoteText
            font: dropNoteMetrics.font
            color: Theme.textPrimary
        }
    }
    // Linked into the level being viewed (notes' drop): a script, a
    // .desktop file, anything executable.
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
            popup.linkPaths(paths);
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
            surfaceColor: Theme.surface
        }
    }

    // The favourite flight's clone, above the rows and below every menu,
    // cut to the popup: lifted at 1.055 a row reaches past its cell into the
    // padding, and at rest the engine clips nothing, so its plate's shadow
    // would land outside the popup (the rows' ends meet only the popup's
    // straight sides and its square foot on the bar, so the rectangle is the
    // outline there).
    Item {
        id: flightLayer
        objectName: "flightLayer"
        anchors.fill: parent
        z: 900
        clip: true
    }

    // The layer everything floating lives in (menus, tips, the drag ghost).
    Item {
        id: overlay
        objectName: "launcherOverlay"
        anchors.fill: parent
        z: 1000
    }
}
