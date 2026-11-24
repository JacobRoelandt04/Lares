pragma Singleton

import QtQuick
import Quickshell

// =============================================================================
// ScrollFeel -- the shell's ONE scroll feel. Every scroller reads it through a
// KineticScroll (directly, or through ScrollDressing), so "how far does a notch
// go, how fast do the cards move under two fingers, how long does a fling
// coast" has one answer, tuned once (the clipboard mockup's Scrolling tab) and
// not eyeballed per module.
//
// The model is the browser's: a mouse notch GLIDES over notchMs (notches add
// up, none is swallowed); a touchpad follows the fingers and, when they lift
// while moving, COASTS with its velocity decaying as exp(-t / momentumTau) --
// the distance it travels is v0 x momentumTau; fingers put back catch it.
// =============================================================================
Singleton {
    property real speed: 1.0
    property real hSpeed: 1.6
    property real notchPx: 120
    property int notchMs: 140
    property real momentumTau: 380
    property real flingMin: 0.3
    property real velocityWindowMs: 90
    property real maxFling: 8
}
