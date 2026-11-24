pragma Singleton

import QtQuick
import Quickshell

// =============================================================================
// WheelHub -- the shell's ONE reading of a wheel event, and the mouse's side buttons as a two-finger swipe.
//
// WHICH DEVICE (docs/contracts/gestures.md). On Qt 6.12 a mouse's notch carries a pixel delta as well as its angle (120 and 15, scroll phase
// 0: measured on a Razer Viper V3 Pro, 2026-11-22; Qt calls every wheel device "touchpad"), so "it has pixels" no longer says touchpad:
// every notch was read as 15 px of fingers -- a list crept without a glide, a reel took twelve notches, the globe stood between its two
// tilts, the volume ran backwards. What tells them apart is the SCROLL PHASE: libinput's fingers begin, update and end (phases 1, 2, 3), a
// wheel has none. (With no phase, an angle of exactly 12 x the pixels is Qt's own making of a continuous axis -- a trackpoint, a button-scroll
// device -- and that is fingers with no lift.)
//
//   read(w, area)   -> one event, normalised: { x, y, angleDelta, pixelDelta, phase, modifiers, buttons, inverted, device, notches, steps, click,
//                      accepted }
//        device     "wheel" (a mouse), "touch" (fingers), "swipe" (a side-button drag: fingers, made here)
//        pixelDelta (0, 0) for a mouse, whatever Qt said: every reader's "pixels = fingers" is true again
//        notches    the whole notches this event completed on each axis, signed as the angle (a high-resolution wheel adds its pieces up);
//                   0 for fingers. ONE NOTCH IS ONE STEP, whatever a swipe's threshold is
//        steps      the same as steps to the NEXT one (+: rolled down, tilted right, a side button's notch down; -: the previous), what a
//                   stepper takes whatever way its own swipe counts (a tab's pill follows the fingers, a page moves against them)
//        click      made by a click of a side button (a reader whose step destroys something leaves those alone)
//        accepted   what the reader writes: false passes the event on (Qt's own rule)
//
// THE SIDE BUTTONS (shell.jsonc "input"; a mouse has no second axis and no lift). SideSwipe, one per window, hears them:
//   held + moved       a two-finger swipe under the pointer's place: the same events fingers make (begin, updates, end), so every reader in
//                      the shell follows it, coasts out of it and springs back from it; the pointer is hidden and stays where it was
//   held + the wheel   one step SIDEWAYS per notch (down = the next): read() turns the axis
//   clicked            one step back (the Back button) or on (Forward): one sideways notch
//
// `sideButtons`, `sideClick`, `sideGain`, `sideHold` are written by ShellServices from shell.jsonc; a mockup and a probe have the defaults.
// =============================================================================
Singleton {
    id: hub

    // "both" | "back" | "forward" | "off"
    property string sideButtons: "both"
    property bool sideClick: true
    // How far a swipe goes per px of the hand (1: fingers on a touchpad).
    property real sideGain: 1
    // The pointer is hidden during a swipe and put back where it was (a live shell; SideSwipe's host moves the real one).
    property bool sideHold: true

    readonly property int sideMask: hub.sideButtons === "both" ? (Qt.BackButton | Qt.ForwardButton)
        : hub.sideButtons === "back" ? Qt.BackButton : hub.sideButtons === "forward" ? Qt.ForwardButton : Qt.NoButton
    // A side-button swipe is under way in some window.
    readonly property bool swiping: hub._swiping
    property bool _swiping: false
    // A notch was turned while a side button is down: that press is no click and no drag (SideSwipe reads and clears it).
    property bool sideTurned: false

    // ---- one event ----
    // `area`: the WheelArea that heard it (its accumulators of a high-resolution wheel's pieces).
    function read(w: var, area: var): var {
        let ad = Qt.point(w.angleDelta.x, w.angleDelta.y), pd = Qt.point(w.pixelDelta.x, w.pixelDelta.y);
        const phase = w.phase === undefined ? Qt.NoScrollPhase : w.phase;
        let device = "touch";
        // (Angle alone in pieces of a notch is no device Wayland has: a probe's fingers.)
        const wheel = phase !== Qt.NoScrollPhase ? false
            : pd.x !== 0 || pd.y !== 0 ? !hub._continuous(ad.x, pd.x) && !hub._continuous(ad.y, pd.y) && (ad.x !== 0 || ad.y !== 0)
            : (ad.x !== 0 && ad.x % 120 === 0) || (ad.y !== 0 && ad.y % 120 === 0);
        if (wheel) {
            device = "wheel";
            pd = Qt.point(0, 0);
            if ((w.buttons & hub.sideMask) !== 0) {
                // a side button is down: the notch is sideways (down = the next one, as a swipe to the left is)
                ad = Qt.point(ad.y !== 0 ? ad.y : ad.x, 0);
                hub.sideTurned = true;
            }
        }
        const n = device === "wheel" ? hub._notches(ad, area) : Qt.point(0, 0);
        return {
            x: w.x, y: w.y, angleDelta: ad, pixelDelta: pd, phase: phase, modifiers: w.modifiers, buttons: w.buttons, inverted: w.inverted === true,
            device: device, notches: n, steps: -(Math.abs(n.x) > Math.abs(n.y) ? n.x : n.y), click: false, accepted: true
        };
    }
    // Qt makes an angle out of a continuous axis: 12 x its value, both rounded.
    function _continuous(a: real, p: real): bool {
        return p !== 0 && Math.abs(a - 12 * p) <= 6;
    }
    function _notches(ad: point, area: var): point {
        const now = Date.now();
        const s = area._pieces;
        if (now - s.at > 400 || (ad.x !== 0 && s.x * ad.x < 0))
            s.x = 0;
        if (now - s.at > 400 || (ad.y !== 0 && s.y * ad.y < 0))
            s.y = 0;
        s.at = now;
        s.x += ad.x;
        s.y += ad.y;
        const nx = Math.trunc(s.x / 120), ny = Math.trunc(s.y / 120);
        s.x -= nx * 120;
        s.y -= ny * 120;
        return Qt.point(nx, ny);
    }

    // ---- the readers, for the swipe ----
    readonly property var _areas: []
    function join(area: Item): void {
        hub._areas.push(area);
    }
    // by identity: a replacement is made before the one it replaces goes
    function leave(area: Item): void {
        const i = hub._areas.indexOf(area);
        if (i >= 0)
            hub._areas.splice(i, 1);
    }
    function alive(area: var): bool {
        return hub._areas.indexOf(area) >= 0;
    }
    // The readers under a point of `root` (a window's content item, or a stage), the topmost first: the order Qt delivers a wheel in.
    function chainAt(root: Item, x: real, y: real): var {
        const out = [];
        for (let i = 0; i < hub._areas.length; i++) {
            const a = hub._areas[i];
            if (!a || !a.visible || !a.enabled || !a.contains(a.mapFromItem(root, x, y)))
                continue;
            const path = hub._path(a, root, x, y);
            if (path !== null)
                out.push({ area: a, path: path });
        }
        out.sort((m, n) => hub._above(m.path, n.path) ? -1 : 1);
        return out.map(o => o.area);
    }
    // One event, offered along a chain until a reader keeps it: each in its own coordinates of the place (x, y of `root`). Whether one did.
    function deliver(chain: var, root: Item, x: real, y: real, ev: var): bool {
        for (let i = 0; i < chain.length; i++) {
            const a = chain[i];
            if (!hub.alive(a) || !a.enabled)
                continue;
            const p = a.mapFromItem(root, x, y);
            if (a.feed(Object.assign({}, ev, { x: p.x, y: p.y })))
                return true;
        }
        return false;
    }
    // Fingers' event: `px`, `py` the way (px), its angle 12 x as Qt makes it.
    function fingers(px: real, py: real, phase: int): var {
        return { x: 0, y: 0, angleDelta: Qt.point(12 * px, 12 * py), pixelDelta: Qt.point(px, py), phase: phase, modifiers: Qt.NoModifier,
                 buttons: Qt.NoButton, inverted: false, device: "touch", notches: Qt.point(0, 0), steps: 0, click: false, accepted: true };
    }
    // [{ z, i }] from `root` down to the item, null when it is not under `root` or an ancestor's clip cuts it off there.
    function _path(item: Item, root: Item, x: real, y: real): var {
        const out = [];
        let it = item;
        while (it && it !== root) {
            const p = it.parent;
            if (!p)
                return null;
            let i = 0;
            while (i < p.children.length && p.children[i] !== it)
                i++;
            out.unshift({ z: it.z, i: i });
            if (p !== root && p.clip && !p.contains(p.mapFromItem(root, x, y)))
                return null;
            it = p;
        }
        return it === root ? out : null;
    }
    function _above(a: var, b: var): bool {
        for (let i = 0; i < Math.min(a.length, b.length); i++) {
            if (a[i].z !== b[i].z)
                return a[i].z > b[i].z;
            if (a[i].i !== b[i].i)
                return a[i].i > b[i].i;
        }
        // one holds the other: the child is above, unless it is drawn behind it
        return a.length > b.length ? a[b.length].z >= 0 : b[a.length].z < 0;
    }
}
