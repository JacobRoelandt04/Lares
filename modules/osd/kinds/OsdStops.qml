pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/components/Mix.js" as Mix

// =============================================================================
// OsdStops.qml -- the keyboard light: four stops engraved on the shell's rail,
// a ball resting in the current one, a keyboard glyph and the stop's word ("Off",
// "1".."3"). Shown, not interactive: a stop is a key's answer, not a slider.
//
//   h     glyph | rail | word       v   glyph / rail (the ball climbs) / word
//   pill  the same as h, compact
//
// THE RAIL IS PhaseRail, the workspaces switcher's own mechanism: a groove with a notch per stop, the ball rests in one and travels to
// the next when the key says so, throwing sparks as it goes, and the swirl orbits it
// while it rests. One component for every rail of the shell; nothing here is a copy.
//
//   - Labels are off (a stop's word stands beside the rail, big): `minLabelWidth` is out of reach.
//   - The step is immediate (`minDwellMs: 0`): the rail holds a seated ball for a second so a
//     step that finishes in a blink is still seen, which is the opposite of a key's answer.
//   - A card that comes out already on a stop has its ball THERE (born seated); only a stop
//     that changes while the card is out is a trip. The rail starts every ball at the first
//     notch and its particles read a ball that jumps as a very fast one (sparks, and the swirl
//     yanked after it): the ball is put on its stop BEFORE the particles are let in. And a card
//     can be built before its payload has landed or its box has a width, so "born" is when the card
//     has its facts and its room (`ready`), whichever comes first.
//   - OFF is the muted ball's grey (Theme.shadowDeep, as a muted volume's), the stops lit are
//     the accent: one fraction, eased, mixed from Theme colours -- no Behavior on a colour.
//   - The particles fade to nothing at the card's own edges (the engine clips the content to
//     the card's outline, and a spark cut in half is the first thing a clip shows).
//   - A vertical card turns the whole rail a quarter back (PhaseRail has one orientation): the
//     first stop is at the foot and the ball climbs, as a level reads.
// =============================================================================
Item {
    id: root

    property string kind: "kbd"
    property string orientation: "h"
    property var payload: ({})
    property bool interactive: true
    property var style: null
    property real renderScale: 1

    signal userValue(real v)
    signal userToggleMute()
    signal userToggleBoost()
    signal touched()

    readonly property var p: root.payload ? root.payload : ({})
    readonly property bool vert: root.orientation === "v"
    readonly property bool isPill: root.orientation === "pill"
    readonly property int stopCount: Math.max(2, Number(root.p.stops) || 4)
    readonly property int stop: Math.max(0, Math.min(root.stopCount - 1, Math.round(Number(root.p.stop) || 0)))
    // One step per stop; only the key matters (no labels).
    readonly property var steps: {
        const out = [];
        for (let i = 0; i < root.stopCount; i++)
            out.push({ key: String(i), label: "" });
        return out;
    }

    // The light: 0 at OFF, 1 on any stop. One eased fraction, so the grey and the accent trade places
    // on the same clock as the ball's trip.
    property real _lit: root.stop > 0 ? 1 : 0
    Behavior on _lit {
        NumberAnimation {
            duration: root.style.valueEaseMs
            easing.type: Easing.OutCubic
        }
    }

    readonly property real padX: root.isPill ? root.style.pillPad : root.style.pad
    // The card has its facts (a stop) and its room (a size): only now has the ball a place to be born in.
    readonly property bool ready: root.width > 0 && root.p.stop !== undefined
    property bool _seated: false
    // The rail's particles are let in one turn after the ball is seated (see the header).
    property bool _go: false
    Timer {
        id: goTimer
        interval: 0
        onTriggered: root._go = true
    }
    function _seat() {
        if (root._seated || !root.ready)
            return;
        // The key follows the stop from here (and sets the rail off toward it); the ball is put there at once.
        root._seated = true;
        rail.ballPos = rail._targetPos;
        rail._moveToTarget();
        goTimer.start();
    }
    onReadyChanged: root._seat()
    Component.onCompleted: root._seat()

    OsdGlyph {
        id: glyphItem
        osd: root.style
        glyph: "\u{F030C}"
        size: root.isPill ? root.style.pillGlyphPx : root.style.glyphPx
        slot: root.isPill ? root.style.pillGlyphPx : root.style.glyphSlot
        color: root.stop === 0 ? Theme.textFaint : Theme.textPrimary
        x: root.vert ? Math.round((root.width - width) / 2) : Math.round(root.padX)
        y: root.vert ? Math.round(root.style.pad) : Math.round((root.height - height) / 2)
    }

    // "Off" is the widest word; the slot is sized for it.
    OsdFigure {
        id: word
        text: root.stop === 0 ? "Off" : String(root.stop)
        ruler: "Off"
        percent: false
        px: root.isPill ? root.style.pillFigurePx : root.vert ? root.style.figurePxV : root.style.figurePx
        family: root.style.figureFont
        color: root.stop === 0 ? Theme.textFaint : Theme.textPrimary
        x: root.vert ? Math.round((root.width - width) / 2) : Math.round(root.width - root.padX - width)
        y: root.vert ? Math.round(root.height - root.style.pad - height) : Math.round((root.height - height) / 2)
    }

    // The room the rail has along the card: from just past the glyph to just before the word (its own
    // edge padding is the ball's, so the first and last notch stand a ball's radius inside).
    readonly property real startAt: root.vert ? glyphItem.y + glyphItem.height + root.style.gap - 3
                                              : glyphItem.x + glyphItem.width + root.style.gap - 3
    readonly property real endAt: root.vert ? word.y - root.style.gap + 3
                                            : word.x - root.style.gap + 3
    // The rail's rectangle AS IT STANDS (after the turn), on whole pixels: `along` long, as thick as the
    // rail is across. A turn of exactly a quarter keeps every pixel of the rail on the pixel grid when the
    // turned rectangle's corner is on it, so it is the CORNER that is rounded, not the rail's own box.
    readonly property real along: Math.round(root.endAt - root.startAt)
    readonly property real across: rail.implicitHeight
    readonly property real visX: root.vert ? Math.round((root.width - root.across) / 2) : Math.round(root.startAt)
    readonly property real visY: root.vert ? Math.round(root.startAt) : Math.round((root.height - root.across) / 2)
    readonly property real visW: root.vert ? root.across : root.along
    readonly property real visH: root.vert ? root.along : root.across

    PhaseRail {
        id: rail
        // THE RAIL'S OWN FRAME: `width` runs along the stops, `height` across. A vertical card stands it
        // up by turning it about its centre, so the box is placed by where that centre must be.
        width: root.along
        height: implicitHeight
        transformOrigin: Item.Center
        rotation: root.vert ? -90 : 0
        x: root.visX + (root.visW - width) / 2
        y: root.visY + (root.visH - height) / 2

        steps: root.steps
        // Held on the first stop until the ball is seated: a stop that arrives before the card has its room (the
        // owner hands the facts and the size one after the other) must not start a trip the seat then cuts short.
        currentKey: root._seated ? String(root.stop) : "0"
        stepProgress: -1
        // `active` follows `particlesEnabled` (the rail samples and seeds when `active` turns on, and only
        // if particles are enabled by then: two bindings on one flag may update in either order).
        particlesEnabled: root._go
        active: root._go && rail.particlesEnabled

        lineThickness: root.style.stopsLine
        dotSize: root.style.stopsDot
        ballSize: root.style.stopsBall
        edgePadding: Math.max(root.style.stopsDot, root.style.stopsBall) / 2 + 3
        minLabelWidth: 1e6
        minDwellMs: 0
        stepMoveMs: root.style.stopsMoveMs
        // NO ORBIT HERE: the swirl round the resting ball is the system update rail's and does not belong in the OSD. PhaseRail
        // has no switch for it, so its seed, its batch and its timer are put out of work; the grind sparks of a ball in
        // travel stay.
        orbitSeedCount: 0
        orbitBatch: 0
        orbitSpawnMs: 3600000

        // Where the particles must be gone: the card's own edges. In this rail's frame: left and right
        // along it, top and bottom across it; a vertical card's left end is its foot and its top side
        // is the card's left.
        particleEdgeLeft: root.vert ? root.height - (root.visY + root.visH) : root.visX
        particleEdgeRight: root.vert ? root.visY : root.width - (root.visX + root.visW)
        particleEdgeTop: root.vert ? root.visX : root.visY
        particleEdgeBottom: root.vert ? root.width - (root.visX + root.visW) : root.height - (root.visY + root.visH)

        // OFF is quiet, not dead: the swirl keeps going round the grey ball, as fine dust. (The bloom
        // brightens what it blurs, so a grey swirl would otherwise come out as a white smudge.)
        particleSizeScale: 0.35 + 0.65 * root._lit
        bloomBrightness: 0.5 * root._lit
        accentColor: Mix.c(Theme.shadowDeep, Theme.accent, root._lit)
        surfaceColor: Theme.surface
        grooveColor: Theme.panelSunk
        grooveBevelColor: Theme.bevel
        grooveShadowColor: Theme.border
        ballShadowColor: Theme.ballShadow

    }
}
