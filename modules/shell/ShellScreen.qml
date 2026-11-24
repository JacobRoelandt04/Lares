pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Io

import "../bar/gooey"
import "../common/components"
import "../common/scroll"
import "../common/scroll/HeldPointer.js" as Held
import "../common/system"
import "../common/theme"
import "../osd"
import "../notifications/toast"
import "../panorama/screen"
import "scale"
import "cursor"
import "perf"
import "ShellLayout.js" as Layout
import "HyprJoint.js" as Joint
import "RemapRule.js" as RemapRule

// =============================================================================
// ShellScreen.qml -- one screen's layer-shell window: the bar window.
//
// A PanelWindow over the whole output on the TOP layer (the OVERLAY layer while a key-opened popup is up over a
// fullscreen window: below), namespace `lares-bar` (the compositor's rules name it: above_lock, no_anim), taking no room
// (`exclusionMode: Ignore`; the main bar's room is HyprReserve's), transparent, its input region the engine's
// (GooeyMask: the islands, the open popups and nothing else -- the slim bars are out of it, so the screen's edges pass
// the pointer to the windows). It hosts a ShellFrame (everything visible) and the per-window objects that need a window:
//
//   ThemeCrossfade        this window's own host of a light / dark switch
//   HyprReserve           what the bars take from the compositor's work area, ON THIS OUTPUT (in COMPOSITOR px, whole: the main bar's
//                         reserve and the outlets' thickness, each + the border ring: ShellLayout.windowReserve), set on the output: no window
//   OsdPillWindow         the OSD's capsule over a fullscreen window, ON THIS SCREEN: mapped while it shows, and while this window is covered (below)
//   THE IDLE HOLD         the idle reel's "normal" (and "soft"): an idle inhibitor on this window, and on the OSD pill's while this one is
//                         covered, each made afresh for every surface its window gets and asserted again where Hyprland's count goes stale
//                         (below); held through the lock (the user's decision of 2026-10-30)
//
// WHILE THE SESSION IS LOCKED (`services.lock.locked`, LockOwner) this window is the lock's popup and the bars it hangs from, over
// the lock surface (Hyprland's `above_lock` rule for `lares-bar`): it takes NO keyboard (the lock process owns the keys) and an input region
// that is the IDLE REEL's cell and strip and the VOLUME / MICROPHONE pill (its wheel and both buttons: VolumeParity.locked turns the left click into a mute) -- the pointer is the lock's
// everywhere else -- whatever the engine asks for or the mask holds.
// Both come back when the lock lets go.
//
// KEYBOARD. `engine.keyboardFocus` (none / onDemand / exclusive) is mapped onto the layer's keyboard mode. A
// popup opened by a click uses the pulse or OnDemand (the pointer rests on this layer: the whole bar window is
// one surface); one opened by a key takes a HyprlandFocusGrab on THIS window (`screenFrame.window`) or holds Exclusive
// with its own outside-click dismissal (CONTRACT section 10).
//
// THE SCALE (ShellScale). The window stays output-sized and transparent. Inside `body` the whole
// ShellFrame sits in a ScaleRoot: laid out in DESIGN px (the window's size / k), drawn k times larger, where
// k = the configured scale / THIS window's pixel ratio -- so a design px is `configured` device px whatever Hyprland's
// own scale is. The theme crossfade, a sibling of the root, captures the window unscaled. What the compositor is told is
// told in COMPOSITOR px: the reserve (the engine's x k, whole) and the input region (which maps through the transform).
// The outlet bars are the compositor's 6 px gap: 6 / k design px (ShellFrame.slim). The bar's and the popups' RATIOS (`scale.bar`,
// `scale.popup`) are the frame's own business: it lays the bar out in its own units and hands the engine both (ShellFrame).
//
// ONE EXPOSED WINDOW. Qt runs a process's animations from vsync only while exactly one window is exposed, so at rest this is the only window
// the shell has mapped: the reserve is the output's (HyprReserve), the pills map while they show. And it must not be the only one while it is FROZEN (below): a frozen
// window is still exposed and draws no frame, so with no other window every animation in the process, and with one running every QML Timer, would stand still. The OSD
// pill's window is that other window: `keepMapped` holds it for as long as this one is covered, which also keeps it ready for the OSD over a fullscreen window.
//
// THE FIRST FRAME. The window maps when it is made and Qt shows whatever its first frames hold; at a boot that was a bar half there for
// ~100 ms (below), so the content is held out of sight until the bar is whole and then shown in ONE frame.
//
// OVER A FULLSCREEN WINDOW. Top is drawn UNDER a fullscreen window, so a popup opened by a KEY -- the clipboard,
// the launcher, any popup a key opens tomorrow -- over one would take the keyboard blind. EVERY popup opened while this screen's focused
// window is fullscreen FLOATS (GooeyEngine: THE FLOATING POPUP: a free pill off its face, the bars drawn away) and this window goes to the
// Overlay layer in the frame that shows the popup's start: no second surface and no step, see "over a fullscreen window" below. The rule
// keys on the fullscreen window at the moment of opening, not on a module.
// =============================================================================
PanelWindow {
    id: win

    required property var services
    readonly property alias frame: screenFrame

    // Said once, at the first frame swapped ON SCREEN (THE FIRST FRAME): the scene has drawn and the window has its input region.
    signal drawn(string name)
    property bool _drawn: false

    // ---- THE FIRST FRAME ----------------------------------------------------------------------------------------------------------
    // What a boot showed for ~100 ms before this (a phone film at 60 fps, every boot; reproduced in tools/dev/bar_boot_film.sh): the power
    // and idle reel cells and the middle island were holes or smears -- a Cooperative canvas (every ParticleSystem's) draws an uninitialised
    // texture, opaque, until its first paint lands -- the left island stood at the length of a title not read yet with "Desktop" over its
    // end, and the title morphed to the lock's words once the lock was heard. So the frame's content is held OUT OF SIGHT (`scaled` at
    // opacity 0: still built, laid out, synchronised and painted, only not drawn) and nothing in it moves (ShellFrame.presented: lengths,
    // eye and title snap, the lock's popup is not asked for) until
    //   - the frame has its own facts (ShellFrame.whole: its size, the window title's first read, Hyprland's joint, the padlock at rest);
    //   - THE LOCK has spoken, when a lock supervisor held the session as this window was made (tools/lockscreen/lares-lock-held, asked once:
    //     the kernel's table of locks, which takes nothing), so a shell born under the boot lock is born locked -- "New session", the eye
    //     shut, the padlock shut -- or `lockWaitMs` have passed without a word (a lock that cannot reach the socket, hyprlock's fallback);
    //   - and `settleFrames` frames have been swapped with all of that in place (what the last turn changed -- the engine's bars in the
    //     next polish, a canvas's first paint in the next sync -- has landed in them).
    // Then `presented` and ONE frame shows the bar at rest; the frame is told (ShellFrame.presented) once that frame has been SWAPPED
    // (`_drawn`), so what waits for the bar to be seen -- the lock's popup and its hints (the lock hides its own card when the shell names
    // its bar), the prewarm -- waits for a frame on the glass, not for one still compiling. `presentCapMs` after the window's first frame
    // it is shown whatever is missing: a bar late is better than none. While held, the window takes no input. Its console line:
    // LARES shown <output> <ms> (<why>).
    property bool presented: false
    property int lockWaitMs: 5000
    // while it waits for a lock's word, the shell asks the kernel's table again this often: a lock that already ended goes in one ask
    property int lockRecheckMs: 250
    property int settleFrames: 2
    property int presentCapMs: 8000
    // the supervisor's flock as the window was made: -1 not answered yet, 1 held, 0 free
    property int _lockHeld: win.services.lock.listen ? -1 : 0
    property bool _lockWaited: false
    readonly property bool _lockKnown: win._lockHeld === 0 || win.services.lock.locked || win._lockWaited
    readonly property bool _whole: screenFrame.whole && win._lockKnown
    property int _settled: 0
    property real _firstSwapMs: 0
    on_WholeChanged: {
        win._settled = 0;
        if (win._whole)
            win._askFrame();
    }
    Process {
        id: heldAtStart
        running: win.services.lock.listen
        command: [RepoRoot.dir + "/tools/lockscreen/lares-lock-held", win.services.lock.lockFile]
        onExited: code => {
            win._lockHeld = code === 0 ? 1 : 0;
            if (win._lockHeld !== 1 || win.presented || win._lockKnown)
                return;
            if (!lockWait.running && !win._lockWaited)
                lockWait.start();
            lockRecheck.start();
        }
    }
    // A LOCK THAT ENDS BEFORE IT EVER SPOKE leaves its supervisor's flock held for an instant after its unlock: asked once, the shell
    // then held its bar out of sight for the whole `lockWaitMs` waiting for a word that could not come any more (the user's relogs in
    // dGPU-only, 2026-11-15: the face unlocked the lock 6 s into the shell's QML load, before the shell's socket existed, and the bar
    // showed 5003 ms after its first frame, "the lock never spoke"). While it waits it asks again; a flock let go is a lock gone.
    Timer {
        id: lockRecheck
        interval: win.lockRecheckMs
        onTriggered: {
            if (!win.presented && !win._lockKnown)
                heldAtStart.running = true;
        }
    }
    Timer {
        id: lockWait
        interval: win.lockWaitMs
        onTriggered: win._lockWaited = true
    }
    Timer {
        id: presentCap
        interval: win.presentCapMs
        onTriggered: win._present("cap: " + (!screenFrame.whole ? "the frame is not whole" : "the lock"))
    }
    function _askFrame(): void {
        const w = body.Window.window;
        if (w)
            w.update();
    }
    function _present(why: string): void {
        if (win.presented)
            return;
        presentCap.stop();
        lockWait.stop();
        lockRecheck.stop();
        win.presented = true;
        console.log("LARES shown " + win.outputName + " " + Math.round(Date.now() - win._firstSwapMs) + " ms after its first frame (" + why + ")");
        win._askFrame();
    }
    // A frame swapped while held: the first starts the cap; with the bar whole, the `settleFrames`-th shows it.
    function _heldSwap(): void {
        if (win._firstSwapMs === 0) {
            win._firstSwapMs = Date.now();
            presentCap.start();
        }
        if (!win._whole)
            return;
        win._settled++;
        if (win._settled >= win.settleFrames)
            win._present(win.services.lock.locked ? "whole, locked" + (win.services.lock.lockState.boot ? " since boot" : "")
                         : win._lockWaited ? "whole, the lock never spoke" : "whole");
        else
            win._askFrame();
    }

    WlrLayershell.layer: win.overlayWanted ? WlrLayer.Overlay : WlrLayer.Top
    WlrLayershell.namespace: "lares-bar"
    WlrLayershell.keyboardFocus: win.locked ? WlrKeyboardFocus.None
        : screenFrame.engine.keyboardFocus === "exclusive" ? WlrKeyboardFocus.Exclusive
        : screenFrame.engine.keyboardFocus === "onDemand" ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    anchors {
        left: true
        right: true
        top: true
        bottom: true
    }
    color: "transparent"
    surfaceFormat.opaque: false
    mask: !win.presented ? heldMask : win.locked ? lockedMask : sideSwipe.grabbing ? wholeMask : gooeyMask
    // A side-button swipe's hidden pointer may be anywhere in the window: the button comes up over THIS surface (the compositor gives the
    // focus to what is under it), so the whole of it takes input until the pointer is back.
    Region {
        id: wholeMask
        item: body
    }
    // THE FIRST FRAME: nothing takes input before it is shown
    Region {
        id: heldMask
    }
    GooeyMask {
        id: gooeyMask
        engine: screenFrame.engine
    }
    // THE IDLE REEL AND THE VOLUME OVER THE LOCK: the idle mode can still be changed while locked -- the idle cell in
    // the bar and the strip it opens -- and so can the audio, by the wheel and a click over the volume / microphone pill (the audio is controlled with
    // keybinds anyway, so scrolling the bar icons is allowed too, mic and audio; both its buttons mute over the lock, VolumeParity.locked; no mixer
    // opens there). Those are the only shell input then; every other module, popup and bar is out of the region (the
    // pointer is the lock's there), and the keyboard stays the lock's (none, above). The power reel is blocked while locked, so the strip is the idle's.
    Region {
        id: lockedMask
        Region { item: win._lockTakes("idle") ? screenFrame.idleCellItem : null }
        Region { item: win._lockTakes("idle") ? screenFrame.reelMaskItem : null }
        Region { item: win._lockTakes("volume") ? screenFrame.volumeItem : null }
        Region { item: win._lockTakes("player") ? win.services.lock.controlsFor(win.outputName) : null }
        Region { id: lockedMaskFollow }
    }
    // Whether that control takes the pointer now (lockscreen.jsonc lockedControls).
    function _lockTakes(what: string): bool {
        return win.locked && win.services.lock.lockedControls.indexOf(what) >= 0;
    }
    // A Region FOLLOWS ITS ITEM'S OWN x / y / size AND NO ANCESTOR'S (Quickshell 0.3.2, core/region.cpp): a strip measured while the lock's
    // popup is still landing keeps its region 16 px left of the buttons for the whole lock -- nothing else moves it.
    // While locked the items' places in the window are compared and any change re-applies the region; `x` of a region with no size draws nothing.
    property string _lockedPlaces: ""
    function _place(i: Item): string {
        if (!i)
            return "none";
        const a = i.mapToItem(null, 0, 0);
        return Math.round(a.x) + "," + Math.round(a.y) + " " + Math.round(i.width) + "x" + Math.round(i.height);
    }
    Timer {
        interval: 250
        repeat: true
        running: win.locked
        triggeredOnStart: true
        onTriggered: {
            const p = "idle " + win._place(screenFrame.idleCellItem) + ", reel " + win._place(screenFrame.reelMaskItem) + ", volume " + win._place(screenFrame.volumeItem)
                + ", player " + win._place(win.services.lock.controlsFor(win.outputName));
            if (p === win._lockedPlaces)
                return;
            win._lockedPlaces = p;
            lockedMaskFollow.x = lockedMaskFollow.x + 1;
            console.log("LARES lock input " + win.outputName + ": " + p);     // what the pointer can reach; with the line below, what a real lock did
        }
    }
    // The pointer arrived on this window while the session is locked: the compositor gave it to the shell (rule 2 + the region above).
    HoverHandler {
        parent: body
        enabled: win.locked
        onHoveredChanged: console.log("LARES lock pointer " + win.outputName + (hovered ? " on " : " off ") + Math.round(point.position.x) + "," + Math.round(point.position.y))
    }
    // The session is locked (LockOwner): the lock process owns the keyboard and the pointer.
    readonly property bool locked: win.services.lock.locked

    // ---- the scale ------------------------------------------------------------------------------------
    // qmllint disable missing-property
    // (ShellScreen.name is Quickshell's, absent from the linter's type description of QuickshellScreenInfo)
    readonly property string outputName: win.screen ? win.screen.name : ""
    // qmllint enable missing-property
    // The Item scale of the frame: the configured number over this WINDOW's pixel ratio (never the screen's: at a fractional
    // Hyprland scale the attached Screen answers the integer one).
    readonly property real frameScale: ShellScale.frameScale(body, win.outputName)

    // ---- over a fullscreen window ---------------------------------------------------------------------
    // Top is drawn UNDER a fullscreen window, so a popup that floats over one (GooeyEngine: THE FLOATING POPUP -- every popup opened while
    // this screen's focused window is fullscreen) needs this window on the Overlay layer, and the bars are drawn away for it, so it is the
    // popup alone that is over the video, not the whole shell. On Hyprland 0.57 a Top surface under a fullscreen window has alpha 0 and gets NO
    // frame callbacks, and one Qt frame swapped there is never answered: 100 ms later Qt calls the window unexposed and runs no polish and no
    // frame again, and `set_layer` goes out in a polish and only takes effect on a commit, which is a swap. So the window must not
    // draw while it is covered: FROZEN (`updatesEnabled`), it has no frame waiting for an answer and stays exposed, and the rise is an ordinary
    // frame: thaw, polish (`set_layer`), the popup's first frame, one commit, on the next vsync of a normal open. (A remap of the
    // window would cost 200-300 ms behind every key: on a layer surface Quickshell DELETES the QQuickWindow, and a new context, scene graph and
    // first frame follow.) After the popup's close the window stays up (ShellFrame.floatParked), since going down is a frame nobody answers.
    readonly property bool overlayWanted: screenFrame.floatRaised
    // Frames keep coming for `floatSettleMs` after a close, for its last frame and the input region that follows it: both are only sent in a frame.
    property int floatSettleMs: 120
    property bool _floatSettling: false
    readonly property bool _frozen: win._covered && !win.locked && win._drawn && !screenFrame.engine.floatOverlay && !win._floatSettling
    updatesEnabled: !win._frozen
    // COVERED IS FROZEN IN THE TURN IT IS HEARD, AND THEN ASKED: the shell's own reaction to the fullscreen is a frame in the air, so the freeze cannot wait for an answer. But
    // `fullscreenHere` is "the workspace has a fullscreen window", which a MAXIMIZED window is too, and over that the bars stay on screen: frozen, they would stand
    // still. So one read: anything but a real fullscreen thaws again. (A stale window only costs the remap below.)
    property bool _covered: false
    readonly property bool _fullscreenHere: screenFrame.fullscreenHere
    on_FullscreenHereChanged: {
        win._covered = win._fullscreenHere;
        if (win._fullscreenHere) {
            win._parkIfInTheAir();
            coverRead.running = true;
        }
    }
    function _notCovered() {
        win._covered = false;
        screenFrame.parkFloat(false);
    }
    Process {
        id: coverRead
        command: ["hyprctl", "-j", "activewindow"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    if (JSON.parse(text).fullscreen !== 2)
                        win._notCovered();
                } catch (e) {
                    win._notCovered();
                }
            }
        }
    }
    // A FRAME IN THE AIR AS THE COVER CAME (a workspace switch's own animation, a title's) is never answered, and 100 ms later the window is stale. It still has
    // those 100 ms: it goes up now, parked and empty, where frames are answered, instead of freezing under the film and paying the remap at the first key.
    property int staleSwapMs: 36
    property real _lastSwap: 0
    Connections {
        target: body.Window.window
        function onFrameSwapped() {
            win._lastSwap = Date.now();
        }
    }
    function _parkIfInTheAir() {
        // (not with a docked popup out: it stays where it is, under the window, and must not take clicks over the film)
        if (Date.now() - win._lastSwap < win.staleSwapMs && !win.locked && !screenFrame.engine.popupOpen) {
            win._floatSettling = true;
            floatSettle.restart();
            screenFrame.parkFloat(true);
        }
    }
    // Parked it shows nothing, and the compositor is told so: a surface on Overlay is otherwise blended over every frame of the film.
    Region {
        id: nothingVisible
    }
    HyprlandWindow.visibleMask: screenFrame.floatParked && !screenFrame.engine.floatOverlay ? nothingVisible
        : inkRegion.ready && !win._inkWhole ? inkRegion : null
    // THE INK (shell.jsonc `workarounds.visibleInk`, off by default; GooeyInk): Hyprland blends this surface under every frame of
    // the shell, all of the output; told where the ink can be -- the bands of the edges with bars, the popups, toasts and OSD that are
    // out, and any field tile outside those -- it blends only that. Ink outside the region would be CUT, so the whole window is
    // visible again (null: as without the switch) whenever anything draws outside the engine: the first frame not shown yet, the
    // lock, a popup floating over a fullscreen window (the bars drawn away), the theme's crossfade and curtain, Panorama's identify
    // card, and any part that says so through InkWhole (a glyph's flourish). tools/dev/visible_ink_probe.sh holds it to the pixels.
    GooeyInk {
        id: inkRegion
        engine: screenFrame.engine
        on: win.services.shellConfig.visibleInk
    }
    readonly property string _inkMode: screenFrame.floatParked && !screenFrame.engine.floatOverlay ? "empty"
        : inkRegion.ready && !win._inkWhole ? "rects" : "whole"
    readonly property bool _inkWhole: !win.presented || win.locked || screenFrame.engine.floatOverlay || Theme.crossfading
        || Theme.fadeProgress > 0 || wipeLoader.item !== null || identifyHost.visible || InkWhole.whole
    Timer {
        id: floatSettle
        interval: win.floatSettleMs
        onTriggered: win._floatSettling = false
    }
    // A FROZEN WINDOW CAN STILL BE STALE: a frame swapped between the cover and the shell hearing of it (or a screen that was covered while
    // another had the focus, or a start under a fullscreen window) leaves it unexposed. Then no frame starts, and only a new surface will do.
    // `riseStallMs` from the rise with no frame begun: remap. All this window shows is under the film at that moment, so it costs only the time.
    // A MISSING `afterAnimating` ALONE NEVER REMAPS (the 2026-11-17 freeze: six remaps in a row right after a resume, then a shell whose GUI thread
    // never came back). An idle shell can rise without producing a frame ("an update() of an item with no contents schedules no frame"), so the
    // first expiry only ASKS for one (`window.update()`) and waits another period; the remap needs that second silence too, and happens at
    // most once per `remapCooldownMs` per window -- a skipped one is logged once, and the window stays as it is (a stale window costs a
    // slow open; a remap storm costs the render thread). The rule: RemapRule.js (tools/dev/shell_remap_cases.js).
    property int riseStallMs: 64
    property int remapCooldownMs: 10000
    property bool remapping: false
    property bool _frameAsked: false
    property bool _skipLogged: false
    property real _lastRemapMs: -1e12
    visible: !win.remapping
    Timer {
        id: riseWatch
        interval: win.riseStallMs
        onTriggered: {
            const what = RemapRule.decide(win._frameAsked, Date.now() - win._lastRemapMs, win.remapCooldownMs);
            if (what === "ask") {
                win._frameAsked = true;
                const w = body.Window.window;
                if (w)
                    w.update();
                riseWatch.restart();
            } else if (what === "skip") {
                if (!win._skipLogged)
                    console.log("LARES remap " + win.outputName + " skipped (no frame, but one remap already in the last " + win.remapCooldownMs + " ms)");
                win._skipLogged = true;
            } else {
                console.log("LARES remap " + win.outputName + " (no frame " + win.riseStallMs + " ms after the rise, none " + win.riseStallMs + " ms after asking)");
                win._lastRemapMs = Date.now();
                win._frameAsked = false;
                win.remapping = true;
                Qt.callLater(() => {
                    win.remapping = false;
                });
            }
        }
    }
    onOverlayWantedChanged: {
        if (win.overlayWanted) {
            win._frameAsked = false;
            riseWatch.restart();
        }
    }
    Connections {
        target: screenFrame.engine
        function onFloatOverlayChanged() {
            if (screenFrame.engine.floatOverlay) {
                floatSettle.stop();
                win._floatSettling = false;
            } else if (screenFrame.fullscreenHere) {
                win._floatSettling = true;
                floatSettle.restart();
            }
        }
    }
    Connections {
        target: body.Window.window
        enabled: riseWatch.running
        function onAfterAnimating() {
            riseWatch.stop();
            win._frameAsked = false;
            win._skipLogged = false;
        }
    }

    // THE LIVE CURTAIN (ThemeWipe.qml; shell.jsonc `theme.curtainLive`): the still under the shell and the old shell over it, for the length of a run. Nothing of it
    // exists at rest. `wipeCan`: the shell is on view here (a window under a fullscreen one keeps the stand-alone curtain, on Overlay).
    readonly property bool wipeCan: !win._covered && !win.locked && win._drawn
    readonly property var wipeItem: wipeLoader.item
    // Ink of the shell on its way somewhere: the capture and the commit's picture are of a shell at rest. (Read only while a run has a wipe here.)
    readonly property bool _inkMoving: {
        if (!wipeLoader.item)
            return false;
        const e = screenFrame.engine;
        const slots = [e.thePopup.phase, e.childPopup.phase, e.theLane.phase, e.osdPhase];
        const q = pillWindow.pill;
        return slots.some(s => s !== "closed" && s !== "open") || (q.showing && q.moving);
    }
    // THE COLLECTOR'S CYCLE IN FLIGHT ENDS HERE, WHILE THIS WINDOW HAS NO PARENT YET. Qt 6.12's incremental collector loses live objects
    // when one of its cycles STARTS inside a component's build and the new root gets its parent before the cycle resumes (CLAUDE.md "A GC
    // CYCLE THAT STARTS INSIDE A COMPONENT'S BUILD"; tools/dev/qt_gc_attach_probe.sh). Variants builds this window in one synchronous call
    // and parents it right after; on 2026-11-14 a cycle began in that build twice in a row, and every non-visual helper of the bar that no
    // JS value held (171: Connections, Timers, PosedGlyph's paths, the reels' HoverArm and styles) lived on with its storage collected --
    // the idle reel stuck open, flourishes blank. gc() here finishes a cycle in flight (or runs one) inside that call: this window is
    // still the top of its tree, so its wrapper's rescue walk marks everything below it. One collection per screen, before its first frame.
    // THE SWITCH: shell.jsonc `"workarounds": { "gcAtScreenBuild": false }` (ShellConfig.gcAtScreenBuild(), read from the file: the
    // config's first load lands after this window is built; on unless exactly false), for
    // the day Qt has lost the fault (tools/dev/qt_gc_attach_probe.sh says so). The log says which way each screen was built.
    Component.onCompleted: {
        const collect = win.services.shellConfig.gcAtScreenBuild();
        if (collect)
            gc();
        console.log("LARES gc at build " + win.outputName + ": " + (collect ? "on" : "off"));
        win.services.themeControl.registerWipeScreen(win);
    }
    Component.onDestruction: win.services.themeControl.unregisterWipeScreen(win)
    Item {
        id: wipeUnder
        anchors.fill: parent
    }

    // The window's content, which this window's theme host captures: a SIBLING of the host (a child would be in its own picture).
    Item {
        id: body
        anchors.fill: parent

        // Everything the shell draws, in design px, magnified by the frame scale.
        ScaleRoot {
            id: scaled
            // THE FIRST FRAME: out of sight until the bar is whole (above)
            opacity: win.presented ? 1 : 0
            factor: win.frameScale
            hostWidth: body.width
            hostHeight: body.height

            ShellFrame {
                id: screenFrame
                anchors.fill: parent
                services: win.services
                screenName: win.outputName
                window: win
                osdPill: pillWindow.pill
                toastPill: toastPillWindow.pill
                renderScale: ShellScale.renderScale(win.outputName, "frame")
                frameScale: win.frameScale
                // the bar's and the popups' ratios on the frame (shell.jsonc `scale.bar` / `scale.popup`): the frame lays the bar out under
                // the first and hands the engine both (ShellFrame, GooeyEngine: THE RATIOS)
                barRatio: ShellScale.ratio(win.outputName, "bar")
                popupRatio: ShellScale.ratio(win.outputName, "popup")
                // on screen: the first frame that shows it has been swapped (THE FIRST FRAME)
                presented: win._drawn
            }
            // Panorama's identify (a tile hovered in its popup): an accent ring at this screen's edge and the display's name card, drawn
            // in this window -- no window of its own, no remap, no input (it is in no mask). Not while the window is frozen under a
            // fullscreen window (it would draw nothing, and a thaw for it would be a frame nobody asked for).
            Item {
                anchors.fill: parent
                z: 1000
                visible: !win._frozen
                IdentifyCard {
                    id: identifyHost
                    anchors.fill: parent
                    service: win.services.panorama
                    screenName: win.outputName
                    fontFamily: screenFrame.fontFamily
                }
            }
        }
        // THE GATE'S EYE (tools/dev/visible_ink_probe.sh; the ink's region, below): only with LARES_INK_PROBE=<dir>. In `body`, above
        // everything: it grabs `body` (all the shell draws but the crossfade's picture, which has the whole window) with its own cells in it.
        Loader {
            active: String(Quickshell.env("LARES_INK_PROBE") || "") !== ""
            x: body.width - 48
            y: body.height - 3
            z: 1e6
            sourceComponent: Component {
                InkProbe {
                    grabItem: body
                    frame: screenFrame
                    ink: inkRegion
                    mode: win._inkMode
                    dir: String(Quickshell.env("LARES_INK_PROBE"))
                }
            }
        }
    }
    // One host per window with themed content: Theme waits for every one and commits once.
    ThemeCrossfade {
        id: themeHost
        target: body
        anchors.fill: body
        wipe: wipeLoader.item
    }
    Item {
        id: wipeOver
        anchors.fill: parent
        z: 100001
    }
    Loader {
        id: wipeLoader
        anchors.fill: parent
        active: win.services.themeControl.wipeClaimed(win.outputName)
        sourceComponent: Component {
            ThemeWipe {
                control: win.services.themeControl
                shell: body
                under: wipeUnder
                over: wipeOver
                host: themeHost
                screen: win.screen
                outputName: win.outputName
                locked: win.locked
                shellMoving: win._inkMoving
                onReadyChanged: win.services.themeControl.curtainsChanged()
                onFailedChanged: win.services.themeControl.curtainsChanged()
            }
        }
    }
    // The mouse's side buttons as a two-finger swipe over everything in the window; the hidden pointer is kept in place by the compositor.
    SideSwipe {
        id: sideSwipe
        // (over the lock the pointer is the lock's: it goes with the hand)
        holds: win.services.live === true && !win.locked
        onPointer: (what, dx, dy) => Hyprland.dispatch(Held.expr(what, dx, dy))
    }
    // The pointer's shape over the whole window (shell.jsonc `hoverCursor`), and what hides it (the bridge's free look, a side-button swipe).
    CursorCover {
        anchors.fill: parent
        hidden: screenFrame.engine.pointerHidden || sideSwipe.hiding
    }
    // The reserve is in COMPOSITOR px, whole: the room the shell's drawn edge needs -- the main bar's reserve and
    // the outlets' thickness, each + the border ring that grows outward from them (Layout.windowReserve) -- so Hyprland's
    // `gaps_out` can be 0 on every side and the windows sit snug against the ring.
    QtObject {
        id: reserveSrc
        readonly property real ring: Joint.ringWidth(screenFrame.cfg.border.width, win.frameScale)
        readonly property var edgeReserve: Layout.windowReserve(screenFrame.engine.edgeReserve, screenFrame.slim, reserveSrc.ring, win.frameScale, screenFrame.reserveOn)
    }
    // The ring is drawn on WHOLE compositor px (HyprJoint.ringWidth) and the reserve above is exactly where it ends: the engine draws the
    // configured width times this (1 when there is no ring). A Binding on a property of its own, so ShellFrame's `borderWidth` stays as it is.
    Binding {
        target: screenFrame.engine
        property: "borderFix"
        value: screenFrame.cfg.border.width > 0 ? reserveSrc.ring / screenFrame.cfg.border.width : 1
    }
    // THE DEVICE EDGE (HyprJoint.edgeFix): under Hyprland's own scale a reserve is not a whole device px (43 x 1.25 = 53.75), and Hyprland
    // draws the window's border from its rounded surface less its rounded thickness (54); the engine draws each edge's bars' face there, so
    // the ring meets the border with nothing between them. All 0 at Hyprland's scale 1.
    Binding {
        target: screenFrame.engine
        property: "edgeFix"
        value: Joint.edgeFix(reserveSrc.edgeReserve,
                             { top: screenFrame.engine.edgeReserve.top, right: screenFrame.slim, bottom: screenFrame.slim, left: screenFrame.slim },
                             reserveSrc.ring, win.frameScale, ShellScale.dpr(body), body.width, body.height, screenFrame.hyprBorder)
    }
    HyprReserve {
        // (offscreen there is no compositor: a sandbox's offscreen run has the user's socket linked in, and must not tell it anything)
        live: Quickshell.env("QT_QPA_PLATFORM") !== "offscreen" && String(Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "") !== ""
        output: win.outputName
        reserve: reserveSrc.edgeReserve
        // (not before the frame is whole: until then the reserve is a frame's that knows neither its bars nor its scale, and every rule
        // stops the compositor for half a second -- HyprReserve's header)
        hold: win._covered || !win._reserveArmed
        cacheFile: win.services.stateDir + "/reserve/" + win.outputName + ".lua"
    }
    // The reserve is final once the frame is whole (or shown anyway, at the first frame's cap): latched, it never holds a later change.
    property bool _reserveArmed: false
    readonly property bool _reserveFinal: screenFrame.whole || win._drawn
    on_ReserveFinalChanged: {
        if (win._reserveFinal)
            win._reserveArmed = true;
    }
    OsdPillWindow {
        id: pillWindow
        screen: win.screen
        keepMapped: win._covered
        style: win.services.osdStyle
        lineWipe: wipeLoader.item
    }
    // The toast stack's pill, while the bars are hidden
    ToastPillWindow {
        id: toastPillWindow
        screen: win.screen
        pillStyle: win.services.osdStyle
        lineWipe: wipeLoader.item
        live: win.services.live === true
    }
    // The frame journal: every frame this window misses while something moves, with what was moving (shell_progress perf_pass/JOURNAL.md)
    FrameJournalHook { windowName: "bar"; screenName: win.outputName; engine: screenFrame.engine; frame: screenFrame }

    // >>> IDLE HOLD
    // ---- THE IDLE HOLD ------------------------------------------------------------------------------------------------------------
    // While the idle reel stands on "normal" (or "soft", which never lets hypridle blank or suspend), locked or not -- coffee holds fully,
    // the lock included (the user's decision of 2026-10-30; Hyprland counts an inhibitor on a layer over the lock) -- this window holds a
    // Wayland idle inhibitor, so hypridle's plain listeners, the 240 s suspend among them, stay quiet. The lid is hard mode's.
    // What made the machine suspend under "normal" on 2026-11-10, and what each part below is for (tools/dev/idle_hold_env_probe.sh):
    //   - QUICKSHELL'S IdleInhibitor IS LOST AT A REMAP (0.3.2). A layer window shown again is a NEW QQuickWindow (the old one goes by
    //     deleteLater), and the inhibitor follows the new one without letting go of the old: the old window's destruction, a turn later,
    //     deletes the inhibitor just made for the new surface, and nothing makes another. So the inhibitor is NOT one object for the
    //     window's life: a fresh IdleInhibitor is made for every surface the window shows (`HeldInhibitor`: its model is empty while the
    //     window is hidden), and one never outlives the surface it was made for.
    //   - HYPRLAND COUNTS AN INHIBITOR ONLY AT A RECHECK (0.57.2: a window mapped or focused, a fullscreen change, an inhibitor made or
    //     destroyed), and only if its surface is then mapped, takes input and has a non-zero alpha. Two of those facts change with no
    //     recheck after them: a layer's MAP and the fade-in that follows it (an inhibitor made for a surface still without its first
    //     buffer, or one asked for in the instant the map is announced, before the layer's alpha has left 0, is not counted), and the
    //     alpha a TOP layer gets back when a fullscreen window over it goes (the fullscreen's recheck reads the alpha before it moves:
    //     the bar stays uncounted until something else rechecks -- the user, idle with the focus on kitty, never did). So the hold is
    //     ASSERTED AGAIN -- a fresh inhibitor, whose creation is a recheck -- `holdAssertMs` after Hyprland says a shell surface has
    //     mapped (socket2 `openlayer` of `lares-bar` / `osd-pill`). Hyprland tells no client when a fade has begun, and nothing hurries:
    //     a verdict that is wrong for a second only restarts hypridle's count, whose shortest listener that respects inhibitors waits
    //     120 s. One second is many frames of any fade, even in the nested test compositor's ~13 fps.
    //   - UNDER A FULLSCREEN WINDOW A TOP LAYER HAS ALPHA 0 and counts for nothing at any recheck (any window mapped or focused anywhere
    //     drops the hold), so while this window is covered the OSD pill's window -- mapped then anyway (`keepMapped`), on the Overlay
    //     layer, which a fullscreen window does not hide -- holds one too. Its letting go when the cover ends is the recheck that counts
    //     this window again, by then uncovered.
    readonly property bool _holdWanted: win.services.idle.normalHold
    // bumped `holdAssertMs` after Hyprland says a bar window / an OSD pill window has mapped (any screen's: a fresh inhibitor costs nothing)
    property int holdAssertMs: 1000
    property int _barSerial: 0
    property int _pillSerial: 0
    Timer {
        id: barAssert
        interval: win.holdAssertMs
        onTriggered: win._barSerial++
    }
    Timer {
        id: pillAssert
        interval: win.holdAssertMs
        onTriggered: win._pillSerial++
    }
    // A fresh inhibitor for every surface `target` shows, and again at every `serial`: never one object for the window's life.
    component HeldInhibitor: Instantiator {
        id: held
        required property var target
        property bool want: false
        property int serial: 0
        model: held.want && held.target.backingWindowVisible ? [held.serial] : []
        delegate: IdleInhibitor {
            window: held.target
            enabled: true
        }
    }
    HeldInhibitor {
        target: win
        want: win._holdWanted
        serial: win._barSerial
    }
    HeldInhibitor {
        target: pillWindow
        want: win._holdWanted && win._covered
        serial: win._pillSerial
    }
    LazyLoader {
        // (offscreen, or a sandbox's run with the user's socket linked in, there is no compositor of ours to listen to)
        active: Quickshell.env("QT_QPA_PLATFORM") !== "offscreen" && String(Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "") !== ""
        component: Scope {
            Connections {
                target: Hyprland
                function onRawEvent(ev) {
                    if (ev.name !== "openlayer")
                        return;
                    if (ev.data === "lares-bar")
                        barAssert.restart();
                    else if (ev.data === "osd-pill")
                        pillAssert.restart();
                }
            }
        }
    }
    // <<< IDLE HOLD

    Connections {
        target: screenFrame.Window.window
        function onFrameSwapped() {
            if (!win.presented) {
                win._heldSwap();
                return;
            }
            if (!win._drawn) {
                win._drawn = true;
                win.drawn(screenFrame.screenName);
            }
        }
    }
}
