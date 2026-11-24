.pragma library

// What every HyprSettings of one lock must agree on, because the settings they
// flip are the compositor's -- global -- and there may be more than one
// instance (the lock's own, plus one a DesktopLayer makes when its host did not
// hand it the lock's): which screens have settled (xray may go off only when all
// have), whether it did, and whether the unlock's settings were already sent.
// A .pragma library is shared by every importer in the engine.
//
// Everything is a FUNCTION: QML cannot assign a library's variables from
// outside (`Reg.frozen = true` is silently dropped -- measured: xray never went
// off), only the library can.
var screens = {};
var frozen = false;
var unlockSent = false;

function reset() {
    screens = {};
    frozen = false;
    unlockSent = false;
}

function register(name) {
    screens[name] = false;
}

// One screen holds its final still. True exactly once: when it was the last.
function settle(name) {
    screens[name] = true;
    for (var k in screens)
        if (!screens[k])
            return false;
    if (frozen)
        return false;
    frozen = true;
    return true;
}

function isFrozen() {
    return frozen;
}

// True the first time only (every instance and screen asks).
function beginUnlock() {
    if (unlockSent)
        return false;
    unlockSent = true;
    frozen = false;
    return true;
}

function isUnlocking() {
    return unlockSent;
}

function thaw() {
    frozen = false;
}
