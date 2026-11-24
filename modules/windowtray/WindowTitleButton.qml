pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "../common/theme"
import "../common/glyphs"
import "../common/components"
import "../common/icons"
import "../common/components/Mix.js" as Mix

// =============================================================================
// WindowTitleButton.qml -- the focused window in the bar: its app's mark in a
// cell as wide as the reel strip (the strip hangs from THIS cell), the tray
// items that ask for attention peeking in beside it, and the title.
//
// THE TITLE says only what the icon does not (the service strips the app's
// name off its end) and MORPHS on a change -- only the letters that changed
// move (TextMorph: drift by default), and a morph always plays out (a
// change that arrives mid-morph waits for it). When the APP changes
// the whole title is replaced and the mark drifts on the same clock (outF / inF).
// A long title is cut at `maxTitleWidth` and fades into the bar.
//
// THE ISLAND FOLLOWS THE TITLE (a simple ease, still snappy). `wantedWidth` is what this button
// WILL ask for once everything under it has settled -- the mark's cell, the peeking icons
// where they are heading, the title that is heading for the bar, its end -- uncapped and in
// whole pixels. The shell's layout takes it (capped by shell.jsonc's titleSlot) for the left
// island's length and eases the island on its ONE clock; `implicitWidth` is the same sum on
// the title's own morph clock, which the slot (the eased island) clips. Nothing here depends
// on the slot, which is what keeps the two from chasing each other. While the strip is open
// the title's cell is held, and so is this (frozen where it was, and caught up when the strip
// closes -- it does not read the held cell, which is the slot's own child).
// A DEAD BAND ON THE WAY DOWN (`style.islandDeadBand`, 6 px). The want grows at once -- a title
// that does not fit is cut -- but shrinks only when the title is that much narrower than what was
// asked for: a spinner in a terminal's title cycles glyphs that differ by a few px (measured in
// Audiowide: the star set of Claude Code's spinner spans 4), and an island that breathed with them
// would be a figure that jitters. The glyph set in use (the four half circles) is one width.
//
// IT IS A BUTTON ONLY WHILE THE TRAY HAS ITEMS (with an empty tray
// the title is inert -- no hand cursor, a click does nothing). The pointer is
// the only announcement: a short fade of the title's ink towards the accent.
// While the strip is open the cell's width is held, so the strip's anchor
// stays where it hangs from; the title still changes inside it.
//
// WHILE THE SESSION IS LOCKED the title would still display the last window that was active. The focused
// window is nobody's business behind a lock, so the face says who is away instead: `lockedName` is
// the lock's own greeting name (first word of the account's name, shell.jsonc / lockscreen.jsonc), the title reads
// "<name> is away" ("Away" with no name) and the mark is the Arch Linux logo -- not a lock, the power reel already has
// one. It rides the ordinary class machinery: the class is `~locked`, so the app change drifts the mark and the title
// swaps by the same morph as any other, and when the lock lets go the focused window's own facts are all still there.
// The tray is not reachable while locked (the bars take no input), so the button is inert as well.
// THE BOOT LOCK is the one lock nobody walked away from: the session has been locked since it began (`bootLock`: the lock in force
// was started by Hyprland's --locked-cmd, so no unlock has happened yet), so the title reads `style.bootText` ("New session") instead,
// with the same mark. `bootLock` is the lock's own fact and only read while `locked`: the lock says it BEFORE it says it is locked
// (LockOwner applies a state before `locked` follows), so the title goes straight to its words; a `locked && boot` handed in would be
// one step behind `locked` and say "Away" for a turn. The shell shows its bar only once it knows (ShellScreen: THE FIRST FRAME), so the title is born with it and the
// island at its length; the first unlock hands over to the window's own title by the usual morph.
// `snap` (the host's: its window is not shown yet) swaps the title instead of morphing it, so what the first frame shows is the text
// at rest, not a morph that started out of sight.
//
// THE SAME LOGO IS THE FALLBACK: some windows provide no icon (the steam update window), and wear the same logo as
// when locked. A class that no icon resolves for -- no override of the user's (shell.jsonc
// icons.overrides), and no desktop entry whose Icon the theme has -- wears the Arch logo (AppIcon.archFallback). No guessing: the
// answer is only given once the desktop entries have been scanned (before that every class is unresolved). `~desktop` -- no window --
// is the Arch logo too (wherever "desktop" is named).
// THE MARK is the icon the active icon theme gives the app (AppIcon), drawn as it is; nothing is baked.
//
// ORIENTATION. The bar's frame is rotated with its edge, so the face is laid
// out along x on every edge. On a side bar the title runs along the bar and
// the marks stand upright (they counter-rotate). On a BOTTOM bar (180 deg) the
// whole face turns half round, which reads the right way up AND puts the mark
// on the screen's left, before the title.
// =============================================================================
Item {
    id: btn

    property var owner: null
    // The session is locked (LockOwner.locked) and whom the lock calls it (LockOwner.effectiveName); see the header.
    property bool locked: false
    property string lockedName: ""
    // ... and the lock in force is the boot lock (see the header; read only while `locked`)
    property bool bootLock: false
    // The host's window is not shown yet: a title change swaps (see the header).
    property bool snap: false
    property var window: null                 // ActiveWindowService / Mock
    property var tray: null                   // TrayService / Mock
    property var appLookup: null
    property var style: owner ? owner.style : null
    property real cellWidth: owner ? owner.reelStyle.thickness : 40
    property real thickness: 40               // the bar's
    property real barRotation: 0
    property real renderScale: 1
    // What the bar is made of: the end fade fades into it, the mark is cut into it.
    property color ground: Theme.surface

    readonly property int _rot: Math.round(((btn.barRotation % 360) + 360) % 360)
    readonly property bool flip: btn._rot === 180
    readonly property bool sideBar: btn._rot === 90 || btn._rot === 270
    readonly property bool inert: btn.locked || !btn.tray || btn.tray.empty
    readonly property bool hovered: area.containsMouse || peekHover.hovered
    readonly property Item iconCell: cell
    // The mark being shown (probes read its `how` / `source`).
    readonly property AppIcon markItem: markNow
    // The title's morph, for probes and films (TextMorph.debugSeek holds its clock).
    readonly property bool active: !!btn.owner && btn.owner.popupMine

    // ---- the facts -----------------------------------------------------------------
    // A live source says nothing until its first read lands (`ready`): the
    // bar shows no title rather than a "Desktop" that was never true.
    readonly property bool ready: !!btn.window && btn.window.ready !== false
    readonly property bool empty: !btn.window || btn.window.empty
    readonly property string cls: btn.locked ? "~locked" : !btn.ready ? "" : btn.empty ? "~desktop" : btn.window.cls
    readonly property var info: btn.appLookup && !btn.locked ? (btn.appLookup.serial >= 0 ? btn.appLookup.app(btn.cls) : null) : null
    readonly property string titleText: btn.locked ? (btn.bootLock ? (btn.style ? btn.style.bootText : "New session")
            : btn.lockedName !== "" ? btn.lockedName + " is away" : "Away")
        : btn.owner && btn.owner.hoverName !== "" ? btn.owner.hoverName
        : !btn.ready ? "" : btn.empty ? (btn.style ? btn.style.desktopText : "Desktop") : btn.window.shownTitle
    readonly property string titleKey: btn.locked ? btn.cls : btn.owner && btn.owner.hoverName !== "" ? "tray:" + btn.owner.hoverName : btn.cls
    // Whether a class that nothing resolves for may wear the Arch logo: only once the desktop entries have been scanned (before
    // that every class is unresolved). `~desktop` and `~locked` are the logo outright (IconResolve).
    readonly property bool archFallback: !!btn.appLookup && btn.appLookup.scanned && !btn.locked

    // The mark drifts with exactly the morph that replaced the title because the
    // APP changed (the morph's key is the class; a tray name in the bar is not).
    readonly property string _prevCls: title.replacing && typeof title.keyFrom === "string"
        && title.keyFrom.indexOf("tray:") !== 0 && btn.titleKey.indexOf("tray:") !== 0 ? title.keyFrom : ""
    readonly property bool _driftMark: btn._prevCls !== "" && btn._prevCls !== btn.cls

    property real hoverF: (area.containsMouse && !btn.inert) || btn.active ? 1 : 0
    Behavior on hoverF {
        GlyphHoverEase {}
    }

    implicitWidth: Math.ceil(btn.cellWidth + peekRow.width + title.implicitWidth + (btn.style ? btn.style.titleEndPad : 10))
    implicitHeight: btn.thickness

    // What the button will ask for when everything has settled (see the header): the peeks at their targets, the title's cell at
    // the width of the title that is heading for the bar (held while the strip is open).
    readonly property real wantedWidth: btn._want
    readonly property real _freeWanted: Math.ceil(btn.cellWidth + btn._peekCount * (btn.style ? btn.style.peekSize + btn.style.peekGap : 22)
        + Math.ceil(targetSize.implicitWidth) + (btn.style ? btn.style.titleEndPad : 10))
    property real _want: 0
    on_FreeWantedChanged: btn._follow()
    onActiveChanged: {
        if (!btn.active)
            btn._follow();
    }
    function _follow(): void {
        // the strip is open: the title's cell is held (TextMorph.holdWidth), and so is what is asked for
        if (btn.active && btn._want > 0)
            return;
        const w = btn._freeWanted;
        if (btn._want <= 0 || w > btn._want || btn._want - w > (btn.style ? btn.style.islandDeadBand : 0))
            btn._want = w;
    }
    // The room the peeking icons take now (animated): the shell cuts the title short of it (the slot is shared).
    readonly property real peekWidth: peekRow.width
    // The peeking icons that are staying (a leaving one is on its way out: its width is not asked for any more).
    property int _peekCount: 0
    // The title that is heading for the bar, measured as TextMorph measures its own (a hidden Text of the very same face: a
    // synthesized bold is laid out wider than FontMetrics says).
    Text {
        id: targetSize
        visible: false
        textFormat: Text.PlainText
        text: btn.titleText
        font.family: btn.style ? btn.style.titleFamily : "Inter"
        font.pixelSize: btn.style ? btn.style.titlePixelSize : 13
        font.bold: btn.style ? btn.style.titleBold : true
    }

    Item {
        id: face
        width: btn.width
        height: btn.height
        rotation: btn.flip ? 180 : 0

        // ---- the mark, in the cell the strip hangs from --------------------------------
        Item {
            id: cell
            width: btn.cellWidth
            height: btn.height
            readonly property real drift: btn.style ? btn.style.driftPx : 3
            AppIcon {
                id: markNow
                visible: btn.cls !== ""
                size: btn.style ? btn.style.markSize : 20
                renderScale: btn.renderScale
                cls: btn.cls
                appId: btn.info ? btn.info.desktopId : ""
                icon: btn.info ? btn.info.icon : ""
                kind: "app"
                archFallback: btn.archFallback
                x: Math.round((cell.width - width) / 2)
                y: Math.round((cell.height - height) / 2 + (btn._driftMark ? cell.drift * (1 - title.inF) : 0))
                width: size
                height: size
                rotation: btn.sideBar ? -btn.barRotation : 0
                opacity: btn._driftMark ? title.inF : 1
            }
            AppIcon {
                id: markOld
                readonly property var prevInfo: btn.appLookup && btn._prevCls !== "" ? (btn.appLookup.serial >= 0 ? btn.appLookup.app(btn._prevCls) : null) : null
                visible: btn._driftMark
                size: btn.style ? btn.style.markSize : 20
                renderScale: btn.renderScale
                cls: btn._prevCls
                appId: markOld.prevInfo ? markOld.prevInfo.desktopId : ""
                icon: markOld.prevInfo ? markOld.prevInfo.icon : ""
                kind: "app"
                archFallback: btn.archFallback
                x: Math.round((cell.width - width) / 2)
                y: Math.round((cell.height - height) / 2 - cell.drift * title.outF)
                width: size
                height: size
                rotation: btn.sideBar ? -btn.barRotation : 0
                opacity: 1 - title.outF
            }
        }

        // ---- the items that ask for attention ------------------------------------------
        Row {
            id: peekRow
            x: cell.width
            height: btn.height
            Repeater {
                model: peeks
                delegate: Item {
                    id: peek
                    required property string key
                    required property bool leaving
                    required property int index
                    readonly property var rec: btn.tray ? (btn.tray.serial >= 0 ? btn.tray.record(peek.key) : null) : null
                    readonly property real full: (btn.style ? btn.style.peekSize + btn.style.peekGap : 22)
                    property real f: 0
                    Behavior on f {
                        NumberAnimation {
                            duration: btn.style ? btn.style.peekMs : 260
                            easing.type: Easing.OutCubic
                        }
                    }
                    Component.onCompleted: peek.f = Qt.binding(() => peek.leaving ? 0 : 1)
                    onFChanged: {
                        if (peek.leaving && peek.f === 0)
                            Qt.callLater(() => btn._dropPeek(peek.key));
                    }
                    width: Math.round(peek.full * peek.f)
                    height: btn.height
                    clip: true
                    property real hoverF: peekArea.containsMouse ? 1 : 0
                    Behavior on hoverF {
                        GlyphHoverEase {}
                    }
                    TrayInk {
                        readonly property real s: btn.style ? btn.style.peekSize : 16
                        x: Math.round((peek.full - (btn.style ? btn.style.peekGap : 6) - s) / 2)
                        y: Math.round((btn.height - s) / 2)
                        width: s
                        height: s
                        size: s
                        opacity: peek.f
                        rotation: btn.sideBar ? -btn.barRotation : 0
                        source: peek.rec ? peek.rec.iconSource : ""
                        mode: "ink"
                        ink: Mix.c(Theme.warn, Theme.accent, peek.hoverF)
                        renderScale: btn.renderScale
                    }
                    MouseArea {
                        id: peekArea
                        anchors.fill: parent
                        enabled: !peek.leaving
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        cursorShape: Qt.PointingHandCursor
                        onClicked: mouse => {
                            if (btn.owner)
                                btn.owner.peekClicked(peek.key, mouse.button);
                        }
                    }
                }
            }
            HoverHandler {
                id: peekHover
            }
        }

        // ---- the title -------------------------------------------------------------------
        TextMorph {
            id: title
            x: cell.width + peekRow.width
            anchors.verticalCenter: parent.verticalCenter
            text: btn.titleText
            key: btn.titleKey
            fontFamily: btn.style ? btn.style.titleFamily : "Inter"
            pixelSize: btn.style ? btn.style.titlePixelSize : 13
            bold: btn.style ? btn.style.titleBold : true
            color: Mix.c(btn.window && !btn.window.focused ? Theme.textMuted : BarText.ink, Theme.accent,
                (btn.style ? btn.style.hoverTint : 0.55) * btn.hoverF)
            maxWidth: btn.style ? btn.style.maxTitleWidth : 360
            endFade: btn.style ? btn.style.endFade : 24
            ground: btn.ground
            mode: btn.snap ? "swap" : btn.style ? btn.style.morphModeName : "drift"
            durationMs: btn.style ? btn.style.morphMs : 220
            driftPx: btn.style ? btn.style.driftPx : 3
            overlap: btn.style ? btn.style.morphOverlap : 0.2
            holdWidth: btn.active
        }
    }

    // The whole cell is the button -- when there is a tray to open.
    MouseArea {
        id: area
        anchors.fill: parent
        z: -1
        hoverEnabled: true
        cursorShape: btn.inert ? Qt.ArrowCursor : Qt.PointingHandCursor
        onClicked: {
            if (!btn.inert && btn.owner)
                btn.owner.toggle();
        }
    }

    // ---- the peeks: a mirror of the tray's attention list, so one that clears
    // can leave (its width and ink fading) instead of vanishing.
    ListModel {
        id: peeks
    }
    readonly property bool _peeksOn: !btn.style || btn.style.peeks
    on_PeeksOnChanged: btn._syncPeeks()
    function _syncPeeks() {
        const want = btn._peeksOn ? (btn.tray ? btn.tray.attention : []).slice(0, btn.style ? btn.style.peekMax : 3) : [];
        for (let i = 0; i < peeks.count; i++) {
            const k = peeks.get(i).key;
            const gone = want.indexOf(k) < 0;
            if (gone !== peeks.get(i).leaving)
                peeks.setProperty(i, "leaving", gone);
        }
        for (const k of want) {
            let found = false;
            for (let i = 0; i < peeks.count; i++)
                if (peeks.get(i).key === k)
                    found = true;
            if (!found)
                peeks.append({ key: k, leaving: false });
        }
        btn._peekCount = want.length;
    }
    function _dropPeek(key) {
        for (let i = 0; i < peeks.count; i++)
            if (peeks.get(i).key === key && peeks.get(i).leaving) {
                peeks.remove(i);
                return;
            }
    }
    Connections {
        target: btn.tray
        ignoreUnknownSignals: true
        function onAttentionChanged() {
            btn._syncPeeks();
        }
    }

    Component.onCompleted: {
        btn._follow();
        btn._syncPeeks();
        if (btn.owner)
            btn.owner.button = btn;
    }
    Component.onDestruction: {
        if (btn.owner && btn.owner.button === btn)
            btn.owner.button = null;
    }
}
