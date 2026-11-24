import QtQuick

import "../common/theme"

// =============================================================================
// AudioStyle.qml -- the audio popup's numbers and colours in one object, so one panel row moves every row at once. The popup holds one and hands it
// down; a host may hand its own. Colours are tokens: nothing here is a literal.
// =============================================================================
QtObject {
    // ---- the popup -------------------------------------------------------------------------------------------------------------------
    property real popupWidth: 720
    property real listHeight: 430
    property real padding: 12                    // the shell's one number
    property real tabsHeight: 32
    property real footHeight: 28
    property real listRadius: 14
    property int fadeMs: 160
    property int resizeMs: 260
    property int enterStaggerMs: 55              // a tab's rows, one after the other: the network popup's

    // ---- a row -----------------------------------------------------------------------------------------------------------------------
    property real rowPadding: 8
    property real rowGap: 6                      // between two rows, and from the box's edge to the first
    property real rowRadius: 10
    property real titleSize: 12
    property real subtitleSize: 11
    property real figureSize: 11
    property real noteSize: 11
    property real glyphSize: 15
    property real sliderScale: 0.72
    property real sliderBall: 12
    property real sliderEdge: 6
    property real figureWidth: 104               // the "100 %  -60.0 dB" slot: figures never jitter
    property real channelLabelWidth: 74
    property real offsetStepMs: 10               // pavucontrol's spin step
    property int sliderRestMs: 450               // how long the pointer rests on a slider before the wheel is the slider's, where the list can scroll

    // ---- the level glow --------------------------------------------------------------------------------------------------------------
    property bool glowEnabled: true
    property int levelBeatMs: 33                 // one beat for every meter and line of the popup, a whole-window frame each; none at all in silence
    property real levelFloor: 0.02               // a peak under this is silence: no frame for a noise floor
    property real levelSteps: 12                 // the glow moves in whole steps, so a level that barely moves draws nothing
    property real levelDecay: 0.85               // per beat, the fall after a peak
    property real glowCurve: 0.55                // the peak's exponent: <1 lifts a quiet signal into view
    property real glowMax: 0.9                   // the strongest the row's inset takes the accent
    property color glowColor: Theme.accent

    // ---- the patch bay ---------------------------------------------------------------------------------------------------------------
    property bool linesEnabled: true
    property real socketColumn: 210              // the devices' box beside the list: room for a device's name, always
    property real socketPitch: 78                // from one socket to the next, as the rows: the two columns share a rhythm while the sockets fit
    property real gapNone: 12                    // between the two boxes with no stream at all: the shell's padding
    property real gapIdle: 34                    // ... with lines lying calm
    property real gapSounding: 104               // ... while a stream sounds: the room the waves live in
    property int gapHoldMs: 1400                 // how long the room stays after the last of the sound has run down the line
    property real lineStep: 4                    // px between two points of a line
    property real lineWavelength: 46             // px, the broad layer's; the others are shorter on the same speed
    property real lineSpeed: 70                  // px/s: how fast the sound runs down the line. Sets the waves' flow AND how long a stop takes to arrive
    property real lineAmp: 9                     // the deepest sine, px, at full level
    property real lineColorGain: 3               // how fast a quiet sound takes the line's colour
    property real lineRise: 0.3                  // per beat, how far the line's level goes towards a louder sound
    property real lineDecay: 0.92                // per beat, what is left of it after a quieter one: how softly a stop tapers along the line
    property real lineThickA: 6
    property real lineThickB: 3.2
    property real lineThickC: 1.5
    property real lineAlphaA: 0.16
    property real lineAlphaB: 0.34
    property real lineAlphaC: 0.95
    property real lineCalmAlpha: 0.8             // the thin layer's alpha on a silent line
    property real lineDim: 0.3                   // the lines the pointer is not on, while it is on one
    property color lineColor: Theme.accent
    property color lineIdleColor: Theme.textFaint
    property real ballSize: 10
    property real portSize: 7
    property int travelMs: 420                   // the marker's one clock

    // ---- the default's rail ----------------------------------------------------------------------------------------------------------
    property real railWidth: 16                  // the column it stands in
    property real railLine: 4
    property real railDot: 12                    // a slot, at each place the ball can rest
    property real railBall: 8
    property real railSettle: 0.05               // how far the ball runs past its slot, as a share of its way (at most 2.5 px)

    // ---- what a row says -------------------------------------------------------------------------------------------------------------
    property color noteColor: Theme.errorStrong
}
