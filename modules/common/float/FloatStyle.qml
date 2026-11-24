import QtQuick

// =============================================================================
// FloatStyle.qml -- the numbers of a card float (FloatMotion.js reads them, FloatCard and FloatClock too): the sway, the pointer's tilt and lift, the deal
// that brings the cards in. The defaults are the theme popup's, where the float was tuned first; a module that floats takes its own instance with its
// own lines (ThemeStyle is one, NotesFloatStyle another, the weather popup's `floatStyle` a third), so a mockup's Save writes that module and nobody else.
// =============================================================================
QtObject {
    // The sway: three oscillators per card (x, y, rotation), each rolling a new size and speed every `retarget` seconds
    property real moveAmpMin: 1.2
    property real moveAmpMax: 3.0
    property real moveFreqMin: 0.5
    property real moveFreqMax: 0.9
    property real rotAmpMin: 0.35
    property real rotAmpMax: 0.8
    property real rotFreqMin: 0.4
    property real rotFreqMax: 1.0
    property real retargetMin: 6
    property real retargetMax: 7

    // The pointer's tilt and the hand's lift
    property real tiltMax: 9
    property real tiltStiffness: 140
    property real tiltDamping: 15
    property real liftScale: 1.045
    property real planeDistance: 700
    property real clickKick: -6

    // The deal: every card OutBack from `dealRise` px below and `dealTurn` degrees turned, `dealStaggerMs` after the one before it
    property int dealMs: 440
    property int dealStaggerMs: 45
    property real dealRise: 16
    property real dealTurn: 3.5

    // The calm (FloatClock.calm): how fast the sway eases out when a drag or a scroll begins, and back in when it ends
    property int calmMs: 200
    property int resumeMs: 600
}
