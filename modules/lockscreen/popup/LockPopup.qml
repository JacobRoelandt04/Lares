pragma ComponentBehavior: Bound

import QtQuick

import ".."

// =============================================================================
// LockPopup.qml -- what the user sees while the session is locked: the clock,
// the password field, the machine's state at a glance, one slot of something
// to look at. Drop-in content for thePopup (contract section 4), and the lock
// process's own fallback card.
//
//   1  LockClockBlock   the time (Audiowide, DigitCells), a greeting on the
//                       session's first unlock or the date otherwise, and how
//                       long ago it was locked
//   2  LockField        the carved password field: dots, the face glyph, the
//                       checking band, the failed flush
//      LockStatusRow    the words under it (Wrong password, Face not
//                       recognised ...)
//   3  LockInfoBand     battery, weather, updates, screen time -- each cell only if its
//                       source was handed in
//   4  LockMediaSlot    the mini vinyl while mpd plays, else the wiki card; or
//                       nothing, and the popup closes over it
//
// FACTS IN, NOTHING OUT. `lockState` (LockState) is the whole conversation
// with the lock; the rest are the shell's services, handed in as properties.
// The popup never starts a Process, never opens a URL, never reads a singleton
// service, and has pointer input in ONE place: the player's buttons (LockMediaSlot;
// the shell's locked input region is the idle reel, the volume pill and that strip,
// ShellScreen) -- the keyboard belongs to the lock process.
// `fallback` is the lock's own hosting of it (no services, no shell): it drops
// every service but the battery and the locale.
//
// SIZED BY IMPLICIT SIZE. The width is fixed (`contentWidth` + padding on both
// sides) and the content is centred on it by hand, so the layout does not move
// while the engine grows the box on open; the height is the sum of what is
// there. A section that has nothing to show has NO height and no gap. The
// engine eases the box (260 ms OutCubic); nothing here animates its own
// height, so there is one clock for a resize.
//
// AT REST (`active` false, the lock has been idle) nothing ticks: the field's
// bands, the face's sweep, the record and the wiki card stop. The one thing
// that runs is the clock's minute boundary.
//
// Numbers: popup padding 12, section gap 12 (the shell's), carved boxes
// radius 14, the field a pill.
// =============================================================================
Item {
    id: root

    // ---- the contract (section 4) ----------------------------------------------
    property LockState lockState: null
    property var battery: null
    property var weather: null
    property var updates: null
    property var screentime: null
    property var mpd: null
    property var wikiService: null
    property var locale: null
    property string greetingName: ""
    // lockscreen.jsonc: the band's cells in their order, what stands at the foot in order of preference, when the greeting is said
    // ("boot" | "always" | "never").
    property var bandOrder: ["battery", "weather", "updates", "screen"]
    property var footOrder: ["music", "wiki"]
    property string greets: "boot"
    property bool fallback: false
    property bool active: true
    property real renderScale: 1
    property string fontFamily: "Audiowide"

    // ---- layout -------------------------------------------------------------------
    property real padding: 12
    property real gap: 12
    // The status row sits closer to the field it speaks about.
    property real statusGap: 8
    // 560: the band's four cells side by side at
    // their widest texts need ~550; every section lays out from this width.
    property real contentWidth: 560

    implicitWidth: root.contentWidth + 2 * root.padding
    implicitHeight: root._bottom

    // The parts, for a mockup's panel to tune (each is the component's own
    // properties; nothing here reads them back).
    readonly property alias clockBlock: clockItem
    readonly property alias field: fieldItem
    readonly property alias statusRow: status
    readonly property alias infoBand: band
    readonly property alias mediaSlot: media
    // The player's three buttons (null-safe for a host that has no player): the one strip of the popup that takes the pointer.
    readonly property Item mediaControls: media.controlsItem

    // Where key pulses start (LockOwner sends it as `targets`): the password
    // field's rect in THIS item's coordinates ([x, y, w, h]).
    readonly property var fieldRect: [fieldItem.x, fieldItem.y, fieldItem.width, fieldItem.height]

    // Fallback: only the battery and the locale survive.
    readonly property var _weather: root.fallback ? null : root.weather
    readonly property var _updates: root.fallback ? null : root.updates
    readonly property var _screentime: root.fallback ? null : root.screentime
    readonly property var _mpd: root.fallback ? null : root.mpd
    readonly property var _wiki: root.fallback ? null : root.wikiService

    readonly property real _x: Math.round((root.width - root.contentWidth) / 2)
    readonly property real _yField: root.padding + clockItem.implicitHeight + root.gap
    readonly property real _yStatus: root._yField + fieldItem.implicitHeight + root.statusGap
    readonly property real _yFoot: root._yStatus + status.implicitHeight
    readonly property real _bandH: band.implicitHeight
    readonly property real _mediaH: media.implicitHeight
    readonly property real _yBand: root._yFoot + root.gap
    readonly property real _yMedia: root._yFoot + (root._bandH > 0 ? root.gap + root._bandH : 0) + root.gap
    readonly property real _bottom: root._yFoot + (root._bandH > 0 ? root.gap + root._bandH : 0)
        + (root._mediaH > 0 ? root.gap + root._mediaH : 0) + root.padding

    LockClockBlock {
        id: clockItem
        x: root._x
        y: root.padding
        width: root.contentWidth
        height: implicitHeight
        timeFormat: root.locale ? root.locale.timeFormat : "HH:mm"
        dateFormat: root.locale ? root.locale.dateFormat : "dddd d MMMM"
        boot: root.lockState ? root.lockState.boot : false
        lockedAt: root.lockState ? root.lockState.lockedAt : 0
        greetingName: root.greetingName
        greets: root.greets
        fontFamily: root.fontFamily
        renderScale: root.renderScale
    }

    LockField {
        id: fieldItem
        x: root._x
        y: root._yField
        width: root.contentWidth
        height: implicitHeight
        lockState: root.lockState
        active: root.active
    }

    LockStatusRow {
        id: status
        x: root._x
        y: root._yStatus
        width: root.contentWidth
        height: implicitHeight
        lockState: root.lockState
        fontFamily: root.fontFamily
    }

    LockInfoBand {
        id: band
        x: root._x
        y: root._yBand
        width: root.contentWidth
        height: implicitHeight
        battery: root.battery
        weather: root._weather
        updates: root._updates
        screentime: root._screentime
        order: root.bandOrder
        fontFamily: root.fontFamily
        renderScale: root.renderScale
    }

    LockMediaSlot {
        id: media
        x: root._x
        y: root._yMedia
        width: root.contentWidth
        height: implicitHeight
        mpd: root._mpd
        wikiService: root._wiki
        order: root.footOrder
        active: root.active
        renderScale: root.renderScale
        fontFamily: root.fontFamily
    }
}
