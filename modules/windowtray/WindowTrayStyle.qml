pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// WindowTrayStyle.qml -- every number the window title and the tray strip are
// drawn and timed by, in one object: the bar carries one title per bar and
// they are one material, so one style moves them all (and it is what the
// mockup's control panel writes to).
//
// The STRIP's own geometry -- its thickness, the pitch between icons, the
// open/close timings, the width it slides out at -- is NOT here: it is the
// power reel's, read from the IconReelStyle the owner is handed, so the tray
// and the power/idle-inhibit reels stay one material (plan, design 11).
// =============================================================================
QtObject {
    id: style

    // ---- The title -------------------------------------------------------
    property string titleFamily: "Inter"
    property int titlePixelSize: 13
    property bool titleBold: true
    // The title's room in the bar, in px (the brief leaves the number to the
    // deployment: a long title fades out at this width).
    property real maxTitleWidth: 360
    // Over how many px the cut end of a long title fades into the bar.
    // 0: an ellipsis instead (then a title that does not fit swaps at once).
    property real endFade: 24
    // Space between the title's end and the module's end.
    property real titleEndPad: 10
    // How much narrower than what the bar's island was sized for a title must get before the island shrinks (it grows at once, a
    // title that does not fit is cut): a terminal's spinner cycles glyphs a few px apart, and an island that breathed with them would
    // be a figure that jitters.
    property real islandDeadBand: 6
    // "drift" (the changed letters lift out and settle in), "wipe" (a soft
    // front across them) or "swap" (no motion).
    property int morphMode: 0
    readonly property string morphModeName: ["drift", "wipe", "swap"][Math.max(0, Math.min(2, style.morphMode))]
    property int morphMs: 220
    property real driftPx: 3
    // How much of the clock the leaving and the arriving letters share (drift).
    // 0: the old letters are gone before the new ones come.
    property real morphOverlap: 0.2
    // What an empty workspace shows (windowtray.jsonc).
    property string desktopText: "Desktop"
    // What the title says while the session has been locked since it began (the boot lock: no window has been seen yet, so there
    // is nobody to call away and no desktop to name). A later, ordinary lock says "<name> is away".
    property string bootText: "New session"

    // ---- The window's mark ------------------------------------------------
    property int markSize: 20

    // ---- Hover ------------------------------------------------------------
    property int hoverMs: 120
    // How far the title's ink goes towards the accent under the pointer.
    property real hoverTint: 0.55

    // ---- Attention: icons that peek into the bar ---------------------------
    property int peekSize: 16
    property real peekGap: 6
    property int peekMs: 260
    property int peekMax: 3
    // Whether they peek at all (windowtray.jsonc `attention`).
    property bool peeks: true

    // ---- The tray strip ---------------------------------------------------
    property int trayIconSize: 18
    // "ink" (the icon's shape in the shell's glyph ink) | "colour" (as it is) (windowtray.jsonc).
    property string trayIconMode: "ink"
    // HOW IT OPENS AND CLOSES (windowtray.jsonc `openOn`, `closeOnLeave`, `closeOnActivate`). The strip opens when the pointer RESTS on the title's cell, as a reel does (it is the reels' kind of popup: it comes out over
    // whatever popup is open and leaves it be -- GooeyEngine THE REEL SLOT): after the reels' openDelayMs, and it closes by the same
    // leave rule below. A click on the open strip then does nothing (the leave closes it); with the hover off, or the leave rule off, a
    // click closes it.
    property bool openOnHover: true
    // Leaving the cell, the strip and its secondary (a label, a menu and its submenus) closes the strip, after the reel's closeGraceMs. It
    // is the ONLY thing that closes a strip by the pointer: a click elsewhere does nothing to it (no click-anywhere-
    // to-close). Off: a pick, Escape or a click on the title closes it, nothing else.
    property bool closeOnLeave: true
    // A left click that activates an item (raises its window) closes the strip.
    property bool closeOnActivate: true

    // ---- The label beside a hovered icon ----------------------------------
    // How long the pointer rests on an icon before its name comes out. Moving
    // to the next icon while it is out slides it there at once.
    property int labelDelayMs: 220
    // How long the label stays after the pointer left every icon.
    property int labelGraceMs: 180
    // 0 beside the strip (the engine's secondary), 1 in the bar (the title
    // morphs into the hovered item's name).
    property int labelPlace: 0
    property real labelPadX: 12
    property real labelPadY: 7
    property int labelNameSize: 12
    property int labelStatusSize: 11
    // A label (or menu) that would come within this many px of the bar face
    // is laid against the face instead: a few px of wallpaper between them
    // read as a sliver.
    property real flushGap: 12

    // ---- The menu (the same secondary, grown) -----------------------------
    property real menuWidth: 240
    property real menuPad: 6
    property int menuRowHeight: 26
    // 11, not the 12 of the shell's other menus: the tray's apps write long rows
    // ("Connect to Hidden Wi-Fi Network...").
    property int menuFontSize: 11
    property real menuHeadHeight: 32
    // The room a menu needs beside the strip; with less towards the bar's
    // end the secondary opens on the other side.
    property real sideRoom: 280
    // The tallest a menu gets; past it its rows scroll.
    property real menuMaxHeight: 460
    // A menu whose items have not arrived opens anyway after this, empty.
    property int menuLoadTimeoutMs: 600
}
