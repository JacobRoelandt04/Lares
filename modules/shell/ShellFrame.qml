pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland

import "../common/theme"
import "../common/components"
import "../common/flourish"
import "../common/glyphs"
import "../bar/gooey"
import "../bar/reel"
import "../bar/workspaces"
import "../bar/llm"
import "../bar/system_update"
import "../bar/player"
import "../weather"
import "../clock"
import "../stocks"
import "../silicon"
import "../notes"
import "../notifications"
import "../launcher"
import "../clipboard"
import "../picker"
import "../bridge"
import "../panorama"
import "../panorama/bar"
import "../osd"
import "../aerial"
import "../audio"
import "../theme"
import "../windowtray"
import "../windowtray/data"
import "scale"
import "ShellLayout.js" as Layout
import "HyprJoint.js" as Joint
import "ReelItems.js" as ReelItems

// =============================================================================
// ShellFrame.qml -- ONE screen of the shell, window-less (PLAN.md "Architecture").
//
// An Item: the engine, the bars the layout gives (three 40 px islands or one continuous bar on the top
// edge, three 6 px outlets right / bottom / left), every module standing in the island its zone puts it in,
// every per-screen owner with the shell's services injected. It owns no window, so it is hosted by
// ShellScreen (a layer-shell PanelWindow) in the shell and by mockups/shell.qml (a MockupWindow at a real
// output size) in the mockup -- the same tree, which is the point.
//
//   services     ShellServices (required): the once-per-shell services and the glue
//   screenName   the output's connector name ("eDP-1"): the key of its island lengths, of its focus,
//                of its registration with the services
//   window       the layer-shell window that hosts it (null in a mockup): the focus grabs of the owners
//                that open by a KEY are on it
//   osdPill      the OsdPill that shows the OSD over a fullscreen window (the host's window has it)
//   renderScale  DEVICE px per design px: what a texture, a decode or a canvas is multiplied by to be sharp (the shell's
//                configured scale; a mockup's zoom)
//   frameScale   the Item scale the host draws this frame at (ShellScreen's ScaleRoot): everything in here is laid out in
//                DESIGN px; Hyprland's gaps_out is 6 COMPOSITOR px, so the outlet bars are `slim` = 6 / frameScale design px
//   barRatio, popupRatio   the bar's and the popups' scale on the frame (ShellScale.ratio; shell.jsonc `scale.bar` / `scale.popup`, 1 by
//                default). THE BAR is laid out in BAR UNITS -- the design px ShellLayout.js is written in: `barWidth` (the frame's width /
//                barRatio) of room, island lengths and module widths in them -- and drawn `barRatio` times larger: every ZoneRow is a
//                ScaleRoot of it, and Layout.bars converts the bars' own records (thickness 40 x ratio, the reserve the same, the islands'
//                rects) to the frame's px. THE POPUPS' content is laid out in the engine's units (GooeyEngine: THE RATIOS); the engine is
//                handed both. The outlets are the compositor's gap and follow neither. Ratio 1 is the frame unscaled.
//
// THE MODULES stand where ShellLayout.js puts them: `rowFor(id)` / `xOf(id)` / `wOf(id)` are the parent,
// x and width of each, from the config's zones and the island lengths. Switching islands <-> continuous or
// moving a module to another zone changes those three; nothing is rebuilt.
//
// THE OUTLETS. Notes and the LLM are opened by buttons in the top bar and come out of the LEFT bar, near its
// top (an OutletAnchor each); the launcher and the clipboard come out of the BOTTOM bar's middle (keys only);
// the OSD out of the RIGHT bar's middle; the toasts hang from the top bar's right end.
//
// THE FIRST FRAME (ShellScreen, which holds the window's content out of sight until it may be shown): `presented` is the host's word that
// this frame is on screen -- a frame showing it has been swapped (a mockup's frame is from the start). Until then nothing here MOVES: the island lengths snap, the eye snaps, the
// title swaps, the lock's popup is not asked for -- so the first frame anyone sees is the bar at rest, not the middle of its arrival.
// `whole` is what the frame waits for of its own: its size, the window title's first read, Hyprland's joint, and the padlock's engage
// played out (a lock heard at the start shuts it on its own clock); the host adds the lock's first word and a few frames.
//
// THE BARS TOGGLE (Super+F2, services.barsShown): every bar eases to NOTHING (a bar with no area is no body of
// the engine's), the side bars' span following the top and bottom bars' current thickness so they stay joined
// to both all the way (ShellLayout.bars), with the main bar's reserve released at the start (the windows take
// the room back) and restored when a show has finished; the modules fade out first. One clock (`hideT`).
// =============================================================================
Item {
    id: frame

    required property var services
    property string screenName: ""
    property var window: null
    property var osdPill: null
    // the pill that shows the toast stack while the bars are hidden (the host's window has it)
    property var toastPill: null
    // What takes input while the session is locked (ShellScreen): the idle reel's cell, and the reel slot's strip (the idle reel's: the power reel is blocked)
    readonly property Item idleCellItem: idleReel.cellItem
    readonly property Item reelMaskItem: gooeyEngine.reelMaskItem
    // ... and the volume / microphone pill, for its WHEEL alone (VolumeParity.locked drops its clicks)
    readonly property Item volumeItem: volumeParity
    property real renderScale: 1
    property real frameScale: 1
    property real barRatio: 1
    property real popupRatio: 1
    readonly property real slim: 6 / Math.max(0.01, frame.frameScale)
    // The screen's width in BAR units: the room the islands' lengths and the voids are made of.
    readonly property real barWidth: frame.width / Math.max(0.01, frame.barRatio)

    readonly property alias engine: gooeyEngine
    readonly property alias workspaces: workspacesModule
    // The owners by key (CONTRACT section 2): what the services' glue reads.
    readonly property var owners: ({
            clock: clockOwner, stocks: stocksOwner, silicon: siliconOwner, bridge: bridgeOwner, panorama: panoramaOwner, notes: notesOwner,
            launcher: launcherOwner, clipboard: clipboardOwner, picker: pickerOwner, osd: osdOwner, notifications: notificationsOwner,
            aerial: aerialOwner, windowtray: windowtrayOwner,
            weather: weatherOwner, player: playerOwner, llm: llmOwner, audio: audioOwner, theme: themeOwner,
            update: updateOwner, power: powerReel, idle: idleReel
        })
    // What a right or middle click on a button does when shell.jsonc says so (ModuleSlot's catcher).
    readonly property alias barClicks: barClicksItem
    // the idle reel's follower (idle.jsonc autoTell: the probes read `cinematic`)
    readonly property alias idleFollow: idleFollow
    BarClicks {
        id: barClicksItem
        frame: frame
        volume: volumeParity
    }
    // Every button's item by module id (a probe clicks them).
    readonly property var buttons: ({
            power: powerReel, idle: idleReel, theme: themeButton, notes: notesButton, llm: llmButton,
            windowtray: titleButton, weather: weatherButton, clock: clockButton, stocks: stocksButton,
            player: playerButton, volume: volumeParity, aerial: aerialOwner, bridge: bridgeButton, panorama: panoramaButton, silicon: siliconButton,
            update: updateOwner, notifications: bell
        })
    readonly property bool ready: frame.width > 0 && frame.height > 0
    // THE FIRST FRAME (header): on screen (the host's word), and what this frame waits for before it may be.
    property bool presented: true
    readonly property bool whole: frame.ready && titleButton.ready && (!joint.live || joint.read)
        && !(powerReel.flourishes && powerReel.flourishes.lock.playing)
    readonly property var cfg: frame.services.shellConfig.config
    readonly property bool continuous: frame.cfg.topMode === "continuous"
    readonly property real topThickness: Layout.TOP
    readonly property string fontFamily: frame.cfg.font
    // THE JOINT (HyprJoint): the bars' concave joints are drawn to nest a tiled window's corner, whose outline is a
    // circle of Hyprland's rounding + border_size in COMPOSITOR px (the windows do not grow with the scale): HyprJoint asks Hyprland, and
    // Joint.blendFor says the blendRadius, in this frame's px, whose joint nests that circle behind the shell's own border ring (shell.jsonc `border`,
    // drawn outside the surface: the window's side of the ring is the joint less its width) at this frame's scale. The joint is the window's outline
    // plus THE OVERLAP (HyprJoint.js: 0.34 x sqrt(outline), never over half Hyprland's border) plus the ring, and the ring is snapped to whole
    // compositor px (HyprJoint.ringWidth: 3 x 1.25 = 3.75 -> 4) so the reserve ends where the ring does: at a frame of 1, Hyprland's 14 + 3 and a 3 px
    // ring is 21.4.
    readonly property real jointRadius: Joint.blendFor(joint.outer, frame.frameScale, frame.cfg.border.width, joint.border)
    // Hyprland's border_size as HyprJoint read it (compositor px): where a window's border starts under Hyprland's own scale (ShellScreen's edgeFix)
    readonly property real hyprBorder: joint.border
    HyprJoint {
        id: joint
        // a compositor to ask: this frame has a window of its own in it (a mockup's does not, and neither does a mock run in an offscreen sandbox)
        live: !!frame.window
        roundingOver: frame.cfg.joint.rounding
        borderOver: frame.cfg.joint.border
    }

    // ---- the layout -----------------------------------------------------------------------------
    // The modules' own widths (the groove, the clock's flex, is the config's number). The title's slot is what the title button
    // WILL ask for (`wantedWidth`: the title as it is heading for the bar, capped by titleSlot in the layout): the left island follows
    // the title, on the one clock below.
    readonly property var widths: ({
            power: powerReel.width, idle: idleReel.width, theme: themeButton.implicitWidth,
            notes: notesButton.implicitWidth, llm: llmButton.implicitWidth, windowtray: titleButton.wantedWidth,
            weather: weatherButton.implicitWidth, stocks: stocksButton.implicitWidth,
            player: playerButton.implicitWidth, volume: volumeParity.implicitWidth, aerial: aerialOwner.implicitWidth,
            bridge: bridgeButton.implicitWidth, panorama: panoramaButton.implicitWidth, silicon: siliconButton.implicitWidth, update: updateOwner.implicitWidth, notifications: bell.implicitWidth
        })
    // THE ISLAND LENGTHS, ON ONE CLOCK: the island follows the title's length with a simple ease that stays snappy.
    // `lengthsTarget` is what the layout says the
    // lengths are NOW; `lengths` is where they are: a fraction (`lenT`, 0 -> 1 on a 180 ms OutCubic, retargeting from where it
    // stands) between the lengths a move started from and the target, in whole pixels on every frame. Everything that stands on an
    // island reads `lengths` (the bars' rects, the centre island's place, every module's x and width), so the whole row moves on
    // the one clock; a popup hanging from a moving island follows it (the engine places it again on the frame the bar moved), and
    // the islands' input rects are held at the union of where they will have stood (`maskHold`) until the move ends. A new
    // screen size, another screen, the continuous bar and the first second after the screen came up (fonts settling the
    // modules' widths) are not moves: they snap.
    // (In BAR units, like the module widths they are made of: `lengths` is what the zone rows are wide, in their own units.)
    readonly property var lengthsTarget: frame.ready ? Layout.lengthsFor(frame.cfg, frame.screenName, frame.barWidth, frame.widths) : ({ left: 0, centre: 0, right: 0 })
    // (Their first values are the target's -- a frame born with its size has no change of the target to start from; the first
    // assignment in _aimLengths ends those bindings, and it is the only thing that writes them from then on.)
    property var lengths: frame.lengthsTarget
    property var maskHold: null
    property real lenT: 1
    property var _lenFrom: frame.lengthsTarget
    property var _lenTo: frame.lengthsTarget
    property real _lenWidth: 0
    property string _lenScreen: ""
    property bool lenArmed: false
    // How long a move of the lengths takes (ms): snappy by default; the film runs it slowed, and a settings tab may tune it.
    property int lengthsMs: 180
    Timer {
        interval: 1500
        running: frame.ready && frame.presented && !frame.lenArmed
        onTriggered: frame.lenArmed = true
    }
    NumberAnimation {
        id: lenAnim
        target: frame
        property: "lenT"
        from: 0
        to: 1
        duration: frame.lengthsMs
        easing.type: Easing.OutCubic
    }
    onLenTChanged: {
        frame.lengths = Layout.lengthsAt(frame._lenFrom, frame._lenTo, frame.lenT);
        if (frame.lenT >= 1)
            frame.maskHold = null;
    }
    onLengthsTargetChanged: frame._aimLengths()
    function _aimLengths(): void {
        const to = frame.lengthsTarget;
        const snap = !frame.lenArmed || !frame.ready || frame.continuous || frame.barWidth !== frame._lenWidth || frame.screenName !== frame._lenScreen;
        frame._lenWidth = frame.barWidth;
        frame._lenScreen = frame.screenName;
        if (snap) {
            lenAnim.stop();
            frame._lenFrom = to;
            frame._lenTo = to;
            frame.maskHold = null;
            frame.lengths = to;
            frame.lenT = 1;
            return;
        }
        if (Layout.sameLengths(to, frame._lenTo))
            return;
        // Hold what is held before anything is written (the hand-over of a retarget): where the clock stands now becomes the
        // start, so the first frame of the new trip is the last of the old one.
        const cur = frame.lengths;
        frame.maskHold = Layout.maskUnion(frame.lenT < 1 ? frame.maskHold : null, frame.cfg, frame.width, frame.height, [cur, to], frame.barRatio, frame.oledX);
        frame._lenFrom = cur;
        frame._lenTo = to;
        lenAnim.stop();
        frame.lenT = 0;
        lenAnim.start();
        gooeyEngine.kickBoost(frame.lengthsMs);
    }
    readonly property var centre: Layout.centreAt(frame.cfg, frame.barWidth, frame.lengths)
    // The bars as they stand NOW: the toggle's clock (`hideT`) eases every thickness and moves the side bars' ends with them.
    // `slim` (6 / frameScale) is the outlet bars' shown thickness in this frame's px. The islands' free ends stand at the OLED shift's x
    // (`oledX`, THE OLED CARE below: ShellLayout's THE OLED SHIFT).
    readonly property var barSpecs: frame.ready ? Layout.bars(frame.cfg, frame.width, frame.height, frame.lengths, frame.hideT, frame.slim, frame.barRatio, frame.oledX) : []
    // id -> { x, width } over the three zones.
    readonly property var placed: {
        const out = {};
        for (const z of Layout.ZONES) {
            const list = Layout.place(frame.cfg.zones[z], frame.widths, frame.lengths[z],
                                      { cfg: frame.cfg, flex: Layout.FLEX[z] });
            for (const p of list)
                out[p.id] = p;
        }
        return out;
    }
    // A colour of the shell's edge as shell.jsonc says it (ShellLayout.colourOf): null is `fallback` (the theme's), "#..." itself,
    // a Theme token's name that token -- read here, so the binding follows a theme switch. A name that is no colour is `fallback`.
    function edgeColour(spec: var, fallback: color): color {
        if (spec === null || spec === undefined)
            return fallback;
        if (String(spec).charAt(0) === "#")
            return spec;
        const v = Theme[spec]; // qmllint disable missing-property
        return v !== undefined && String(v).charAt(0) === "#" ? v : fallback;
    }

    function spec(barId: string): var {
        for (const b of frame.barSpecs)
            if (b.barId === barId)
                return b;
        return null;
    }
    // A module that is switched off (shell.jsonc `modules`) is in no zone: its slot is not shown, its owner has no service and opens nothing.
    function moduleOn(id: string): bool {
        return frame.services.moduleOn(id);
    }
    function zoneOf(id: string): string {
        return Layout.zoneOf(frame.cfg, id) || "left";
    }
    function barOf(id: string): var {
        if (frame.continuous)
            return topBar;
        const z = frame.zoneOf(id);
        return z === "left" ? topL : z === "centre" ? topC : topR;
    }
    function barIdOf(id: string): string {
        return frame.barOf(id).barId;
    }
    function rowFor(id: string): var {
        const z = frame.zoneOf(id);
        return z === "left" ? rowLeft : z === "centre" ? rowCentre : rowRight;
    }
    function xOf(id: string): real {
        const p = frame.placed[id];
        return p ? p.x : 0;
    }
    function wOf(id: string): real {
        const p = frame.placed[id];
        return p ? p.width : 0;
    }

    // ---- the bars toggle --------------------------------------------------------------------------
    // The bars that are UP: the asked state, or up for the lock (ShellServices.barsUp).
    readonly property bool barsShown: frame.services.barsUp
    // This screen's focused window is fullscreen (the shell's one FocusedScreen): what makes a popup float and a toast a pill.
    readonly property bool fullscreenHere: frame.services.focus.name === frame.screenName && frame.services.focus.fullscreen
    // The bars are away for TWO reasons, on two clocks that meet in `hideT`:
    //  - the toggle (`toggleT`): eased out and in over 260 ms, what Super+F2 does;
    //  - a popup that FLOATS over a fullscreen window (`floatT`, GooeyEngine: THE FLOATING POPUP): ShellScreen raises its window to the Overlay
    //    layer in the event that opens it, and a window on Overlay shows whatever it draws OVER the video. The bars must therefore be GONE in
    //    the very frame the window rises -- an ease there is the whole shell flashing and shrinking over the film
    //    -- so `floatT` is written to 1 at once, and it eases back only when the window has been LOWERED: that is when the window
    //    has left fullscreen (`floatRaised`, below), the compositor holds the new level 8-18 ms after the assignment, so the bars wait
    //    `floatLowerMs` more before they start to come back.
    readonly property bool toggleGone: !frame.barsShown
    property real toggleT: frame.toggleGone ? 1 : 0
    Behavior on toggleT {
        NumberAnimation {
            duration: 260
            easing.type: Easing.OutCubic
        }
    }
    property int floatLowerMs: 80
    property bool _lowering: false
    // THE WINDOW STAYS UP UNTIL THE FULLSCREEN ENDS (a remap would delay the popup between keypress and appearance).
    // Going back to Top commits a frame whose callback Hyprland never answers (a Top surface under a fullscreen window gets none), so Qt
    // calls the window unexposed and the NEXT open would have to remap it (ShellScreen, OVER A FULLSCREEN WINDOW). So once a popup has floated
    // the window stays on Overlay, empty and frozen, for the rest of this fullscreen, and opens again at the speed of a normal open.
    property bool _floatedHere: false
    readonly property bool floatParked: frame._floatedHere && frame.fullscreenHere && !frame.services.lock.locked
    readonly property bool floatRaised: gooeyEngine.floatOverlay || frame.floatParked
    readonly property bool floatHold: frame.floatRaised || frame._lowering
    property real floatT: 0
    onFullscreenHereChanged: {
        if (!frame.fullscreenHere)
            frame._floatedHere = false;
    }
    // The window asks to be up before anything has floated (ShellScreen: a frame in the air as the cover came), and takes that back.
    function parkFloat(on) {
        if (!gooeyEngine.floatOverlay)
            frame._floatedHere = on;
    }
    onFloatHoldChanged: {
        if (frame.floatHold) {
            floatReturn.stop();
            frame.floatT = 1;
        } else {
            floatReturn.restart();
        }
    }
    onFloatRaisedChanged: {
        if (frame.floatRaised) {
            lowerTimer.stop();
            frame._lowering = false;
        } else if (frame.floatT > 0) {
            frame._lowering = true;
            lowerTimer.restart();
        }
    }
    Connections {
        target: gooeyEngine
        function onFloatOverlayChanged() {
            // (only a fullscreen keeps the window up after the popup: with the bars hidden over ordinary windows it goes down again)
            frame._floatedHere = gooeyEngine.floatOverlay || (frame._floatedHere && frame.fullscreenHere);
        }
    }
    Connections {
        target: frame.services.lock
        function onLockedChanged() {
            frame._floatedHere = false;
        }
    }
    Timer {
        id: lowerTimer
        interval: frame.floatLowerMs
        onTriggered: frame._lowering = false
    }
    NumberAnimation {
        id: floatReturn
        target: frame
        property: "floatT"
        to: 0
        duration: 260
        easing.type: Easing.OutCubic
    }
    readonly property real hideT: Math.max(frame.toggleT, frame.floatT)

    // THE EYE: ONE clock for the lock's closing of the clock's split: `eyeT`, 0 open, 1 closed, linear, following the session's lock (`services.lock.locked`;
    // a mock shell's `eyeForce` hook stands in for it in a probe). Two motions are read from it, one after the other: the lids (`eyeF`, Workspaces.lockMerge:
    // the two rails become one over the clock, `eyeMs`) and then the slots (`eyeSlotsF`, Workspaces.lockSpread: all but the two outer ones go to their even
    // places on the one rail, `eyeSlotsMs`, leaving when the lids are at 97 %, so the two read as one gesture with no stop in it). Each is InOutCubic on its own
    // stretch, which is its own mirror, so an unlock is the same clock run back and plays the whole sequence in reverse: slots home, then the lids part.
    // Nothing else is animated for it: the rails, the fills, the dots and the ball are all read from these two.
    property int eyeMs: Number(Quickshell.env("EYE_MS") || 420)
    property int eyeSlotsMs: Number(Quickshell.env("EYE_SLOTS_MS") || 320)
    readonly property real eyeSlotsAtMs: frame.eyeMs * 0.8
    readonly property real eyeTotalMs: frame.eyeSlotsAtMs + frame.eyeSlotsMs
    property real eyeT: frame.services.eyeSet >= 0 ? frame.services.eyeSet : (frame.services.lock.locked || frame.services.eyeForce) ? 1 : 0
    Behavior on eyeT {
        enabled: frame.services.eyeSet < 0 && frame.presented
        NumberAnimation {
            duration: frame.eyeTotalMs
            easing.type: Easing.Linear
        }
    }
    function _eyeEase(x: real): real {
        const t = Math.max(0, Math.min(1, x));
        return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(2 - 2 * t, 3) / 2;
    }
    readonly property real eyeF: frame._eyeEase(frame.eyeT * frame.eyeTotalMs / frame.eyeMs)
    readonly property real eyeSlotsF: frame._eyeEase((frame.eyeT * frame.eyeTotalMs - frame.eyeSlotsAtMs) / frame.eyeSlotsMs)
    // The main bar's reserve: released at the start of a hide, back when a show has finished. The hide of the TOGGLE: a float draws the bars away over a fullscreen window, which
    // has no use for the room, and its way back would give the reserve up for half a second after the fullscreen ended (the windows laid out twice, HyprReserve's rule twice).
    readonly property bool reserveOn: frame.barsShown && frame.toggleT < 0.001

    // THE WORKSPACES THE INDICATOR LISTS: Hyprland's, as plain ids -- and the ids as they stood while the theme curtain shows the
    // hidden workspaces by turns (ThemeControl, "THE HIDDEN WINDOWS"): an EMPTY workspace on show is destroyed when it is left and
    // made again on the way back, and its slot would go and come under a bar that is on show.
    property var _workspaceHeld: null
    readonly property var _workspaceList: {
        if (frame._workspaceHeld !== null)
            return frame._workspaceHeld;
        const out = [];
        const v = Hyprland.workspaces ? Hyprland.workspaces.values : [];
        for (let i = 0; i < v.length; i++)
            if (v[i])
                out.push(frame._workspacesOwn ? { id: v[i].id, screen: v[i].monitor ? v[i].monitor.name : "" } : { id: v[i].id });
        return out;
    }
    // workspaces.jsonc: the dots that are always there (`shown`), and whether this bar shows its own display's workspaces alone (`scope`).
    readonly property bool _workspacesOwn: frame.services.workspacesConfig.settings.scope === "screen"
    readonly property var _workspacesHere: frame._workspacesOwn ? Layout.workspacesOn(frame._workspaceList, frame.screenName) : frame._workspaceList
    readonly property var _workspacesShown: {
        const shown = frame.services.workspacesConfig.settings.shown;
        return frame._workspacesOwn ? Layout.workspacesKept(shown, frame._workspaceList, frame.screenName) : shown;
    }
    Connections {
        target: frame.services.themeControl
        function onRepaintHeldChanged() {
            frame._workspaceHeld = frame.services.themeControl.repaintHeld ? frame._workspaceList : null;
        }
    }
    function closeAll(): void {
        // Not while the session is locked: the one popup up is the lock's, and it goes with the retract (a toggle of the bars made
        // meanwhile does nothing visible until the unlock).
        if (frame.services.lock.locked)
            return;
        // everything goes, the popup a joiner covered included
        gooeyEngine.dropStack();
        gooeyEngine.close();
        gooeyEngine.closeReel();
        gooeyEngine.closeOsd();
    }
    Connections {
        target: frame.services
        function onBarsShownChanged() {
            if (!frame.services.barsShown)
                frame.closeAll();
        }
    }
    // The lock lets go with the bars hidden by the toggle: they go down again, and what is open goes with them (what a hide does).
    Connections {
        target: frame.services.lock
        function onLockedChanged() {
            if (!frame.services.lock.locked && !frame.services.barsShown)
                frame.closeAll();
        }
    }

    // ---- the keys of the open popup -------------------------------------------------------------
    // THE STACK: the owners that say `joinsPopupStack` (the clipboard, the launcher) open over another popup without closing it for good; the engine gives the place back when they close.
    readonly property var stackJoinerIds: {
        const out = [];
        for (const k in frame.owners) {
            const o = frame.owners[k];
            if (o && o.joinsPopupStack === true && o.ownerId)
                out.push(o.ownerId);
        }
        return out;
    }
    // THE GRAB: what the owners hand their HyprlandFocusGrab. A popup whose keys were let go (a window opened) has none, and the grab
    // drops with the list. So does a window being remapped (ShellScreen.remapping): a grab holds a SURFACE, and it is taken again on the new one.
    readonly property var keyGrabWindows: frame.window && !gooeyEngine.keysReleased && !frame.window.remapping ? [frame.window] : []
    // ESCAPE is wanted while a popup is open on this screen -- ANY popup, however its keys stand. A bind dropped once the popup
    // let go of its keys (`keysReleased`: a window opened or took the focus, or the popup was restored from under a joiner) would leave
    // Escape with the window -- and a popup that is still on screen but cannot be closed by the key the user reaches for. The first Escape
    // with a popup open is the popup's, even when the user is typing in a window; only the lock (its own process reads its keys) is not.
    readonly property bool escapeWanted: gooeyEngine.popupOpen && !frame.services.lock.locked
    function pressEscape(): bool {
        return gooeyEngine.pressEscape();
    }
    function releaseKeys(byFocus: bool): bool {
        return gooeyEngine.releaseKeys(byFocus);
    }
    // THE POPUP A JOINER GIVES BACK COMES WITHOUT THE KEYS. The clipboard / launcher pastes into the window that had the keyboard
    // before Alt+V, and Wayland offers the clipboard only to the FOCUSED client. The shelf's close restores the popup it covered
    // (GooeyEngine "THE POPUP STACK"), and a restored popup is opened like any: the system update asks the layer for an exclusive
    // keyboard on open, so the keyboard goes to IT and the app never gets it back. A popup that comes back from under a joiner is not the
    // user's new destination, it is the old state returning: it is let go of its keys at once (the engine's `_restoring` is the one
    // open in which that happens; this handler runs inside that open, after the engine set the keys back and before the content is
    // swapped in, so the layer never asks for a keyboard; `keysReleased` is written, not `releaseKeys()`, which wants a live popup). The pointer moving into it takes the keys, as after any release.
    Connections {
        target: gooeyEngine
        function onPopupOwnerIdChanged() {
            if (gooeyEngine._restoring && gooeyEngine.popupOwnerId !== "")
                gooeyEngine.keysReleased = true;
        }
    }

    // The pointer MOVES inside a popup (or its live child) whose keys were let go: they are its again (the on-demand rule: pointer motion into the layer gives
    // the keys). A resting pointer is re-delivered every frame (Qt 6.11), so only a move of a pixel or more counts; the first point after
    // the release is the pointer where it rests.
    HoverHandler {
        id: keyReclaim
        enabled: gooeyEngine.keysReleased
        property real lx: 0
        property real ly: 0
        property bool seen: false
        onEnabledChanged: keyReclaim.seen = false
        onPointChanged: {
            const p = keyReclaim.point.position;
            if (!keyReclaim.seen) {
                keyReclaim.seen = true;
                keyReclaim.lx = p.x;
                keyReclaim.ly = p.y;
                return;
            }
            if (Math.abs(p.x - keyReclaim.lx) + Math.abs(p.y - keyReclaim.ly) < 1)
                return;
            keyReclaim.lx = p.x;
            keyReclaim.ly = p.y;
            // thePopup's body or a LIVE CHILD's (a secondary is a body of its own: the aerial panel's search field is typed into from there)
            for (const b of [gooeyEngine.thePopup].concat(gooeyEngine.childPopups)) {
                if (b && (b === gooeyEngine.thePopup || b.live) && p.x >= b.popX && p.x < b.popX + b.popW && p.y >= b.popY && p.y < b.popY + b.popH) {
                    gooeyEngine.reclaimKeys();
                    return;
                }
            }
        }
    }

    // ---- the engine and its bars --------------------------------------------------------------------
    GooeyEngine {
        id: gooeyEngine
        anchors.fill: parent
        stackJoiners: frame.stackJoinerIds
        // the interaction boost (a service another module owns; absent = null): every motion asks it for a raised floor
        boost: frame.services.boost ?? null
        // device px per popup CONTENT px (the engine's frame is `renderScale` per px; the content is drawn `popupRatio` times larger)
        renderScale: frame.renderScale * frame.popupRatio * gooeyEngine.primaryScale
        hostRenderScale: frame.renderScale
        barRatio: frame.barRatio
        popupRatio: frame.popupRatio
        // Escape with a detail open: the detail first, or the popup and its detail at once (shell.jsonc `escape`)
        escapeDetailFirst: frame.services.shellConfig.escapeDetailFirst
        clickAwayIds: frame.services.shellConfig.clickAwayText === "" ? [] : frame.services.shellConfig.clickAwayText.split(" ")
        // THE FLOATING POPUP's rule: this screen's focused window is fullscreen, or the bars are hidden (read when a popup opens)
        fullscreenHere: frame.fullscreenHere
        barsHidden: !frame.barsShown
        floatHomeWaitMs: frame.floatLowerMs
        floatGap: 12 * ShellScale.pillRatio(frame.screenName, "toast")
        // a popup's own ratio (shell.jsonc `scale.popups`): the map for this output, hot with the file
        popupScales: ShellScale.popupMap(frame.screenName)
        // the joints' radius (above), in this frame's px: the circle on the glass is Hyprland's, whatever the scale and the ratios
        blendRadius: frame.jointRadius
        surfaceColor: Theme.surface
        // THE SHELL'S EDGE: shell.jsonc's `shadow` and `border` (ShellLayout.js), read hot with the rest. Both ease out with the bars
        // toggle's own clock (hideT): bars hidden to a few px must not cast a band of shadow along the screen's edges.
        shadowReach: frame.cfg.shadow.reach
        shadowStrength: frame.cfg.shadow.strength * (1 - frame.hideT)
        shadowSpread: frame.cfg.shadow.spread
        shadowSoftness: frame.cfg.shadow.softness
        shadowColor: frame.edgeColour(frame.cfg.shadow.color, Theme.shellShadow)
        shadowBlend: frame.cfg.shadow.blend !== null ? frame.cfg.shadow.blend : 20
        borderWidth: frame.cfg.border.width * (1 - frame.hideT)
        borderColor: frame.edgeColour(frame.cfg.border.color, Theme.shellBorder)
        barsList: frame.continuous ? [topBar, rightBar, bottomBar, leftBar] : [topL, topC, topR, rightBar, bottomBar, leftBar]

        // the main bar: three islands, or one bar across (each present only in its mode)
        GooeyBar {
            id: topL
            readonly property var s: frame.spec("topL")
            engine: gooeyEngine
            barId: "topL"
            edge: "top"
            visible: !!s
            rawPos: s ? s.rawPos : 0
            rawLen: s ? s.rawLen : 0
            thickness: s ? s.thickness : 0
            reserve: s && frame.reserveOn ? s.reserve : 0
            inputMask: !!s && s.inputMask && frame.hideT < 0.5
            sky: true   // the island meets the screen's edge as if it hung from one gigantic popup above it (THE SKY)
            maskBox: frame.maskHold ? (frame.maskHold.topL || null) : null
        }
        GooeyBar {
            id: topC
            readonly property var s: frame.spec("topC")
            engine: gooeyEngine
            barId: "topC"
            edge: "top"
            visible: !!s
            rawPos: s ? s.rawPos : 0
            rawLen: s ? s.rawLen : 0
            thickness: s ? s.thickness : 0
            reserve: s && frame.reserveOn ? s.reserve : 0
            inputMask: !!s && s.inputMask && frame.hideT < 0.5
            sky: true   // the island meets the screen's edge as if it hung from one gigantic popup above it (THE SKY)
            maskBox: frame.maskHold ? (frame.maskHold.topC || null) : null
        }
        GooeyBar {
            id: topR
            readonly property var s: frame.spec("topR")
            engine: gooeyEngine
            barId: "topR"
            edge: "top"
            visible: !!s
            rawPos: s ? s.rawPos : 0
            rawLen: s ? s.rawLen : 0
            thickness: s ? s.thickness : 0
            reserve: s && frame.reserveOn ? s.reserve : 0
            inputMask: !!s && s.inputMask && frame.hideT < 0.5
            sky: true   // the island meets the screen's edge as if it hung from one gigantic popup above it (THE SKY)
            maskBox: frame.maskHold ? (frame.maskHold.topR || null) : null
        }
        GooeyBar {
            id: topBar
            readonly property var s: frame.spec("top")
            engine: gooeyEngine
            barId: "top"
            edge: "top"
            visible: !!s
            rawPos: s ? s.rawPos : 0
            rawLen: s ? s.rawLen : 0
            thickness: s ? s.thickness : 0
            reserve: s && frame.reserveOn ? s.reserve : 0
            inputMask: !!s && s.inputMask && frame.hideT < 0.5
        }

        // the outlets: 6 px, inside Hyprland's gap, taking nothing from the compositor and no input
        GooeyBar {
            id: rightBar
            readonly property var s: frame.spec("right")
            engine: gooeyEngine
            barId: "right"
            edge: "right"
            visible: !!s
            rawPos: s ? s.rawPos : 0
            rawLen: s ? s.rawLen : 0
            thickness: s ? s.thickness : 0
            reserve: 0
            inputMask: !!s && s.inputMask && frame.hideT < 0.5
        }
        GooeyBar {
            id: bottomBar
            readonly property var s: frame.spec("bottom")
            engine: gooeyEngine
            barId: "bottom"
            edge: "bottom"
            visible: !!s
            rawPos: s ? s.rawPos : 0
            rawLen: s ? s.rawLen : 0
            thickness: s ? s.thickness : 0
            reserve: 0
            inputMask: !!s && s.inputMask && frame.hideT < 0.5
        }
        GooeyBar {
            id: leftBar
            readonly property var s: frame.spec("left")
            engine: gooeyEngine
            barId: "left"
            edge: "left"
            visible: !!s
            rawPos: s ? s.rawPos : 0
            rawLen: s ? s.rawLen : 0
            thickness: s ? s.thickness : 0
            reserve: 0
            inputMask: !!s && s.inputMask && frame.hideT < 0.5
        }
        // Where notes and the LLM open (shell.jsonc `outlets`): a point of the bar each names.
        OutletAnchor {
            id: notesAnchor
            bar: frame.outletItem("notes")
            parent: notesAnchor.bar
            along: frame.outletAlong("notes")
        }
        OutletAnchor {
            id: llmAnchor
            bar: frame.outletItem("llm")
            parent: llmAnchor.bar
            along: frame.outletAlong("llm")
        }
    }

    function outletAlong(key: string): real {
        const o = frame.cfg.outlets[key];
        return o ? o.along : 0;
    }
    // The slim bar it names, or null for "top": the popup then hangs from the module's own button.
    function outletItem(key: string): var {
        const o = frame.cfg.outlets[key];
        const b = o ? o.bar : "left";
        return b === "top" ? null : b === "right" ? rightBar : b === "bottom" ? bottomBar : leftBar;
    }

    // ---- the rows the modules stand in ---------------------------------------------------------------
    // One row per zone, a child of its island (islands mode) or of the one top bar (continuous). They fade
    // with the bars toggle before the bars shrink. A row is in BAR units (THE RATIOS, above): a ScaleRoot of the bar's ratio, `lengths` wide
    // and 40 tall in its own units, its host `ratio` times that -- so every module in it, and every DeviceScale under it, find the scale.
    component ZoneRow: ScaleRoot {
        id: row
        required property string zone
        readonly property real fade: Math.max(0, 1 - frame.hideT * 3)
        parent: frame.continuous ? topBar : (row.zone === "left" ? topL : row.zone === "centre" ? topC : topR)
        factor: frame.barRatio
        hostWidth: frame.lengths[row.zone] * frame.barRatio
        hostHeight: Layout.TOP * frame.barRatio
        // THE OLED SHIFT (OledShift): the content stands whole device pixels off its place. An island's free ends step with it (ShellLayout.bars):
        // the centre and right islands move their start, so their rows ride on them; the left island starts on the screen's corner, so its row
        // takes the step inside it; the continuous bar has no free end, so every row takes it.
        x: frame.continuous ? (row.zone === "left" ? 0 : row.zone === "centre" ? frame.centre.x * frame.barRatio : frame.width - frame.lengths.right * frame.barRatio) + frame.oledX
                            : (row.zone === "left" ? frame.oledX : 0)
        y: frame.oledY
        opacity: row.fade
        visible: row.fade > 0.002
    }
    // ---- the OLED care: the rows stand a whole number of DEVICE px off their place ---------------------------------------------------
    // OledShift's dx / dy are device px; a frame px is `renderScale` of them (the configured scale at any Hyprland scale), so a step is a
    // whole device pixel at 1 and at 1.25. The islands' FREE ends (not on a screen corner) follow the x (`barSpecs`), so the room between an end
    // and its module is the same at every place, and an island's input rect with it (the engine's mask is the bar's rect). The island's
    // bottom edge, the ends on the corners, the slim bars, the continuous bar and the reserve (so the windows' gaps) never move.
    readonly property real oledX: frame.services.oled.dx / Math.max(0.01, frame.renderScale)
    readonly property real oledY: frame.services.oled.dy / Math.max(0.01, frame.renderScale)
    // A step taken while the island lengths move: the input rect held for the move (`maskHold`) takes the ends' new place as well.
    onOledXChanged: {
        if (frame.lenT < 1 && frame.maskHold)
            frame.maskHold = Layout.maskUnion(frame.maskHold, frame.cfg, frame.width, frame.height, [frame.lengths, frame._lenTo], frame.barRatio, frame.oledX);
    }
    // Anything placed from a module's position when it came out, or moving in the bar: a step waits for it (OledShift: the holders).
    // A popup in any phase but closed (the slots of the engine; the reel slot's strip -- a reel's or the tray's -- and its chain are slots too), a flourish
    // that plays (ANY glyph flourish on this screen: they register themselves, FlourishRegistry), the theme's crossfade (its picture
    // is of the rows where they stood).
    readonly property bool slotsOut: {
        const e = gooeyEngine;
        const slots = [e.thePopup, e.childPopups[0], e.childPopups[1], e.childPopups[2], e.theReel].concat(e.reelChildPopups);
        for (const b of slots)
            if (b && b.phase !== "closed")
                return true;
        return false;
    }
    readonly property bool oledHeld: frame.slotsOut || Theme.crossfading || FlourishRegistry.playingUnder(frame)

    // ---- the OLED care's random flourishes (FlourishScheduler): now and then one of this screen's glyphs plays by itself --------------
    // shell.jsonc `oled.flourishes` (ShellConfig.oledFlourishes), on while the OLED care is (the bar button). A turn is skipped, never
    // put off, while there is a reason here not to move anything (`flourishBlock`).
    readonly property string flourishBlock: {
        if (frame.services.lock.locked)
            return "locked";
        if (!frame.ready || !frame.presented)
            return "starting";
        if (!frame.services.barsUp || frame.hideT > 0)
            return "bars away";
        if (frame.fullscreenHere)
            return "fullscreen";
        if (Theme.crossfading)
            return "theme fade";
        if (frame.slotsOut)
            return "popup";
        return "";
    }
    readonly property alias flourishScheduler: flourishSched
    FlourishScheduler {
        id: flourishSched
        scope: frame
        live: frame.services.live
        settings: frame.services.shellConfig.oledFlourishes
        on: frame.services.shellConfig.oledEnabled
        blocked: frame.flourishBlock
    }
    // A turn now (the IPC's `oledFlourish`): what played, or why nothing did.
    function flourishNow(): string {
        const k = flourishSched.turn();
        return k !== "" ? "played " + k : flourishSched.lastTurn;
    }
    // (a key of its own: a frame replaced in one update of the screens completes before the old one is destroyed, and the old one's release
    // must not take the live one's hold)
    property string _oledKey: ""
    onOledHeldChanged: {
        if (frame._oledKey !== "")
            frame.services.oled.setHeld(frame._oledKey, frame.oledHeld);
    }

    ZoneRow { id: rowLeft; zone: "left" }
    ZoneRow { id: rowCentre; zone: "centre" }
    ZoneRow { id: rowRight; zone: "right" }

    // =================================================================================================
    //  THE MODULES (PLAN.md's layout table). Each: a slot in its zone's row, its button, its owner.
    // =================================================================================================

    // ---- the reels' shared look ---------------------------------------------------------------------
    IconReelStyle {
        id: sharedReelStyle
    }

    // ---- power -------------------------------------------------------------------------------------------
    ModuleSlot {
        host: frame
        moduleId: "power"
        ReelBarModule {
            id: powerReel
            engine: gooeyEngine
            bar: frame.barOf("power")
            barId: frame.barIdOf("power")
            ownerId: "power"
            style: sharedReelStyle
            // power.jsonc "items" and "rest", as they were when the shell started
            readonly property var ids: frame.services.powerConfig.settings.items
            items: ReelItems.powerItems(powerReel.ids)
            leftClickActivates: frame.services.powerConfig.settings.leftClickFires
            // The lock's popup is the one thing up while the session is locked: the power reel closes when it comes and
            // opens no more. The idle reel below stays.
            blocked: frame.services.lock.locked
            // snapTo turns nothing and fires nothing
            Component.onCompleted: {
                const at = ReelItems.indexOf(powerReel.items, frame.services.powerConfig.settings.rest);
                powerReel.reel.snapTo(at >= 0 ? at : ReelItems.indexOf(powerReel.items, ReelItems.POWER_REST));
            }
            onActivated: (index, item) => frame.services.reelActions.firePower(item.id)
            // Every item's flourish (ReelFlourish.js): on a fire from any screen's reel or the lock key (ReelActions.flourished), on
            // the pointer's arrival, and the padlock's on a lock that came by itself (hypridle before a suspend): it shuts while the
            // session is locked and springs open when it lets go.
            flourishes: ReelFlourishes {
                locked: frame.services.lock.locked
                // the action that waits for its flourish runs when one has played (ReelActions)
                onPlayed: id => frame.services.reelActions.flourishPlayed(id)
            }
            Connections {
                target: frame.services.reelActions
                function onFlourished(id: string): void {
                    powerReel.flourishes.play(id);
                }
            }
        }
    }
    // ---- idle ---------------------------------------------------------------------------------------------
    ModuleSlot {
        host: frame
        moduleId: "idle"
        ReelBarModule {
            id: idleReel
            engine: gooeyEngine
            bar: frame.barOf("idle")
            barId: frame.barIdOf("idle")
            ownerId: "idle"
            style: sharedReelStyle
            // idle.jsonc "items": the modes on offer, as the service took them when the config landed
            items: ReelItems.idleItems(frame.services.idle.offered)
            leftClickActivates: true
            // the selected icon IS the mode in force: a click on it fires nothing new to celebrate (the sparks a turn throws stay)
            burstOnActivate: false
            // the auto layer holds the mode: the icon keeps its colour; what a cause asks for is a FLOOR -- a plain pick at or above it is
            // the user's mode, one under it is refused (the icon shakes, the cause is told), and Ctrl+click / Ctrl+scroll still goes below
            autoHeld: frame.services.idle.autoActive
            floorId: frame.services.idle.floorMode
            onActivated: (index, item) => frame.services.reelActions.fireIdle(item.id, idleReel.reel.lastInputOverride)
            onSelectionChanged: (index, item) => frame.services.reelActions.idleSelected(item.id, idleReel.reel.lastInputOverride)
            // Every item's flourish (IdleFlourish.js): on the pointer's arrival and as the user turns it into the cell, as the power
            // reel's; nothing here runs anything (the mode is ReelActions').
            flourishes: IdleFlourishes {}
        }
        // While the auto layer holds the reel, a pointer that moved onto it takes the keyboard for this window, so a Ctrl held over it
        // is seen (Wayland sends modifiers to the keyboard's surface only): the user's way past an automatic mode. Not while a popup
        // is open (its own keys stand; a second grab would clear its owner's).
        HyprlandFocusGrab {
            active: idleReel.wantsKeys && frame.keyGrabWindows.length > 0 && !gooeyEngine.popupOpen
            windows: frame.keyGrabWindows
        }
        // The reel stands on the mode IN FORCE: a refused mode turns it back; the auto layer taking the mode, changing its cause or
        // letting go plays the cinematic (the strip out, the long way round, the strip in).
        ReelFollow {
            id: idleFollow
            module: idleReel
            target: frame.services.idle.mode
            automatic: frame.services.idle.autoActive
            // why, told beside the strip (ReelReason, the strip's side popup)
            reason: frame.services.idle.autoReason
            // why a plain pick under the floor was refused, told beside the strip as the reason is
            floorReason: frame.services.idle.floorReason
            hold: frame.services.reelActions.idleWaiting
            cinematic: frame.services.idle.checked.autoTell === "cinematic"
        }
    }
    // ---- theme: a glyph button (the swatch book). The theme's left click opens its popup, the right one is light <-> dark ---------------------
    ModuleSlot {
        host: frame
        moduleId: "theme"
        ThemeBarButton {
            id: themeButton
            control: frame.services.themeControl
            anchors.verticalCenter: parent.verticalCenter
            onClicked: button => {
                if (button === Qt.RightButton)
                    frame.services.themeControl.click();
                else if (button === Qt.LeftButton)
                    themeOwner.toggle();
            }
        }
    }
    ThemeBarOwner {
        id: themeOwner
        engine: gooeyEngine
        bar: frame.barOf("theme")
        barId: frame.barIdOf("theme")
        anchorItem: themeButton
        control: frame.services.themeControl
        fontFamily: frame.fontFamily
        renderScale: frame.renderScale * frame.popupRatio
    }

    // ---- notes: the button in the left island, the popup out of the left bar ----------------------------------
    ModuleSlot {
        host: frame
        moduleId: "notes"
        NotesBarButton {
            id: notesButton
            owner: notesOwner
            anchors.verticalCenter: parent.verticalCenter
        }
    }
    NotesBarOwner {
        id: notesOwner
        engine: gooeyEngine
        bar: notesAnchor.bar ?? frame.barOf("notes")
        barId: notesAnchor.bar ? notesAnchor.bar.barId : frame.barIdOf("notes")
        anchorItem: notesAnchor.bar ? notesAnchor : notesButton
        notesRoot: frame.services.notesRoot
        openAt: frame.services.notesConfig.settings.openAt
        escapeBack: frame.services.notesConfig.settings.escape === "back"
        confirmDelete: frame.services.notesConfig.settings.confirmDelete
        linkClick: frame.services.notesConfig.settings.linkClick
        statePath: frame.services.stateDir + "/notes/session.json"
        fontFamily: frame.fontFamily
        // the shell's ONE NotesStore, and the keys of a key-opened popup (the router's Alt+N calls
        // shortcutPressed()) held by a grab over THIS screen's bar window
        shellHosted: true
        store: frame.services.notes
        grabWindows: frame.keyGrabWindows
        // "Send to LLM" in a note's menu: offered when this screen has the chat, answered by this screen's chat owner (the two
        // owners of one frame; the notes owner builds nothing of the chat, it only asks).
        llmEnabled: !!frame.services.llm && !!frame.services.llm.service
        onSendToLlm: path => llmOwner.sendFile(path)
    }

    // ---- the LLM: the star button, the chat out of the left bar, flush under the island -----
    ModuleSlot {
        host: frame
        moduleId: "llm"
        LlmBarButton {
            id: llmButton
            llm: frame.services.llm
            anchors.verticalCenter: parent.verticalCenter
            onClicked: button => {
                if (button === Qt.LeftButton)
                    llmOwner.toggle();
            }
        }
    }
    LlmBarOwner {
        id: llmOwner
        engine: gooeyEngine
        bar: llmAnchor.bar ?? frame.barOf("llm")
        barId: llmAnchor.bar ? llmAnchor.bar.barId : frame.barIdOf("llm")
        ownerId: "llm"
        anchorItem: llmAnchor.bar ? llmAnchor : llmButton
        hoverTarget: llmButton
        llm: frame.services.llm
        fontFamily: frame.fontFamily
        // The prompt a note sent to the chat arrives with, selected (llm.jsonc `notePrompt`; empty = none).
        noteTemplate: frame.services.llmConfig.settings.notePrompt
        history: frame.services.llmConfig.settings.history
        attachDir: frame.services.homePath(frame.services.llmConfig.settings.attachFrom)
    }

    // ---- the window title and the tray ------------------------------------------------------------------------------
    WindowTrayStyle {
        id: trayStyle
        readonly property var config: frame.services.windowtrayConfig.config
        titleFamily: frame.fontFamily
        desktopText: trayStyle.config.desktopText
        trayIconMode: trayStyle.config.trayIconMode
        peeks: trayStyle.config.attention !== "off"
        openOnHover: trayStyle.config.openOn !== "click"
        closeOnLeave: trayStyle.config.closeOnLeave
        closeOnActivate: trayStyle.config.closeOnActivate
        // (the slot is shared with the peeking icons: where the title is CUT -- the island at its cap -- it leaves room for them; where it is not,
        // the slot already holds title and peeks and the two clocks (the island's 180 ms, the peek's 260) must not clip a title that fits)
        maxTitleWidth: Math.max(60, frame.wOf("windowtray") - sharedReelStyle.thickness
            - (titleButton.wantedWidth > frame.cfg.titleSlot ? titleButton.peekWidth : 0) - trayStyle.titleEndPad)
    }
    Loader {
        id: windowLoader
        sourceComponent: frame.services.mock ? windowMock : windowLive
    }
    Component {
        id: windowLive
        ActiveWindowService {
            live: true
            held: frame.services.themeControl.repaintHeld
            follow: frame.services.windowtrayConfig.config.follow
            screenName: frame.screenName
            focusSource: frame.services.focus
            config: frame.services.windowtrayConfig.config
            appLookup: frame.services.appLookup
        }
    }
    Component {
        id: windowMock
        ActiveWindowMock {
            config: frame.services.windowtrayConfig.config
            appLookup: frame.services.appLookup
        }
    }
    ModuleSlot {
        host: frame
        moduleId: "windowtray"
        WindowTitleButton {
            id: titleButton
            owner: windowtrayOwner
            window: windowLoader.item
            tray: frame.services.tray
            appLookup: frame.services.appLookup
            style: trayStyle
            thickness: Layout.TOP
            barRotation: 0
            renderScale: frame.renderScale * frame.barRatio
            ground: gooeyEngine.surfaceColor
            width: Math.min(titleButton.implicitWidth, parent.width)
            // while the session is locked: "<first name> is away" with the Arch mark (the lock's greeting name)
            locked: frame.services.lock.locked
            lockedName: frame.services.lock.effectiveName
            // ... and since the session began: "New session" (the boot lock; the lock's own fact, which lands before `locked`)
            bootLock: frame.services.lock.lockState.boot
            // not on screen yet: the title swaps (THE FIRST FRAME)
            snap: !frame.presented
        }
    }
    WindowTrayOwner {
        id: windowtrayOwner
        engine: gooeyEngine
        bar: frame.barOf("windowtray")
        barId: frame.barIdOf("windowtray")
        ownerId: "windowtray"
        window: windowLoader.item
        tray: frame.services.tray
        appLookup: frame.services.appLookup
        config: frame.services.windowtrayConfig.config
        style: trayStyle
        reelStyle: sharedReelStyle
        // the strip shares the reel slot: it waits while the idle reel's automatic cinematic plays (never interrupting it)
        reelBusy: idleReel.autoOpen
        shellHosted: true
    }

    // ---- weather: the popup's drawn glyph and the temperature ---------------------------------------------------------------------------------
    ModuleSlot {
        host: frame
        moduleId: "weather"
        WeatherBarButton {
            id: weatherButton
            service: frame.services.weather
            fontFamily: frame.fontFamily
            anchors.verticalCenter: parent.verticalCenter
            onClicked: button => {
                if (button === Qt.LeftButton)
                    weatherOwner.toggle();
            }
        }
    }
    WeatherBarOwner {
        id: weatherOwner
        engine: gooeyEngine
        bar: frame.barOf("weather")
        barId: frame.barIdOf("weather")
        anchorItem: weatherButton
        service: frame.services.weather
        shown: frame.barsShown
        fontFamily: frame.fontFamily
        // weather.jsonc view, look
        viewStart: frame.services.weather ? frame.services.weather.config.view.start : "mini"
        viewRemember: !frame.services.weather || frame.services.weather.config.view.remember !== "never"
        detailSide: frame.services.weather ? frame.services.weather.config.look.secondarySide : "end"
    }

    // ---- the workspaces and the clock ----------------------------------------------------------------------------------------------
    // The FITTED groove: the side tracks pushed out so the gap between them is 20 px at every scale, the groove
    // 2 * pitch + 64 + 100 * scale wide -- the scale and the pitch are shell.jsonc's. THE CLOCK HAS NO CONTAINER (DeploymentNotes.md
    // 126): its figures stand straight on the surface in the hole the groove leaves, Audiowide like every other text of the bar,
    // 20 px. The slot is 80 x 18 px with a 16 px gap to the last dot either side -- slot + 2 gaps
    // is 112 px (64 + 2 x 24), so the dots and ShellLayout's lengths do not move -- and the groove's corners start AT
    // the last dot (splitOffset 0, not 10 px past it): that is the width the figures need.
    ModuleSlot {
        host: frame
        moduleId: "clock"
        clickBox: clockEye
        Workspaces {
            id: workspacesModule
            readonly property real k: frame.cfg.workspacesScale
            anchors.fill: parent
            sizeScale: workspacesModule.k
            trackSeparation: (10 + 5 * workspacesModule.k) / workspacesModule.k
            clockSize: 80 / workspacesModule.k
            // THE SECONDS' ROOM: hovering the clock brings its seconds in and the slot widens by what
            // they take, the dots on either side moving out -- the module's own length (ShellLayout) stays, the groove gives and takes.
            clockExtra: clockButton.extraWidth / workspacesModule.k
            clockCross: 18 / workspacesModule.k
            clockGap: 16 / workspacesModule.k
            splitOffset: 0
            edgePadding: 10
            // THE SPARKS' ROOM: a jump from one end to the other would send them over
            // the module's edge. The canvas is the whole centre island, to the SAME reach either side of the groove (a canvas it is
            // not the middle of would give the room unequally), and 56 px below the bar over whatever is under it; they fade out over
            // the last 24 px of it. No frame at rest; while sparks live the extra CPU is inside the machine's noise (-18 % to +35 % over four runs).
            particleReachX: Math.max(0, frame.xOf("clock"), frame.lengths.centre - frame.xOf("clock") - frame.wOf("clock"))
            particleReachDown: 56
            showClock: true
            focusSource: frame.services.focus
            screenName: frame.screenName
            workspaceIds: frame._workspacesShown
            allWorkspaces: frame.services.mock ? [] : frame._workspacesHere
            // THE EYE: locked, the two rails converge into one over the clock. The groove draws
            // above the clock while they do (z), so a clock cut at the rails' CENTRE lines is cut under their bodies: no seam, no second layer.
            lockMerge: frame.eyeF
            lockSpread: frame.eyeSlotsF
            z: frame.eyeF > 0 ? 2 : 0
        }
        // The clock's box: the Workspaces' clock slot, cut to the band between the rails' centre lines once they have come in far enough to touch the
        // figures (`clockBandHalf` under the slot's half height: before that it is the slot itself and nothing is cut), whole pixels. The button keeps its
        // own place in the slot: only the window onto it narrows, so the popup that hangs from it and its hover are where they were.
        Item {
            id: clockEye
            readonly property real eyeHalf: Math.min(workspacesModule.clockSlot.height / 2, workspacesModule.clockBandHalf)
            readonly property real eyeTop: Math.round(workspacesModule.lineCenter - clockEye.eyeHalf)
            readonly property real eyeBottom: Math.round(workspacesModule.lineCenter + clockEye.eyeHalf)
            x: workspacesModule.clockSlot.x
            y: clockEye.eyeTop
            width: workspacesModule.clockSlot.width
            height: Math.max(0, clockEye.eyeBottom - clockEye.eyeTop)
            clip: frame.eyeF > 0
            visible: clockEye.height > 0
            z: 1
            ClockBarButton {
                id: clockButton
                x: 0
                y: workspacesModule.clockSlot.y - clockEye.y
                width: workspacesModule.clockSlot.width
                height: workspacesModule.clockSlot.height
                fontFamily: frame.fontFamily
                horizontalPixelSize: 13
                // clock.jsonc `seconds`: "always" holds them out (their room taken for good, so the groove never moves) and ticks them
                // only while this screen's bar is on show
                secondsEnabled: frame.services.clockConfig.settings.seconds !== "never"
                forceSeconds: frame.services.clockConfig.settings.seconds === "always"
                secondsTick: frame.barsShown && (!frame.fullscreenHere || frame.services.lock.locked)
                onClicked: clockOwner.toggle()
            }
        }
    }
    // ---- the prewarm (GooeyEngine.prewarm) ---------------------------------------------------------------------------------------
    // Once the shell has settled, every popup that can be built parked is built once, drawn through the engine's own two paths (plain,
    // then the clip layer) at 2 % scale and opacity in this window's corner, and destroyed -- one at a time, when nothing moves -- so
    // that its first real open draws with its pipelines linked (otherwise +45..77 ms and a 91 ms first-draw gap on a cold open).
    // The screens take turns, in the order they registered, so that two windows do not build their popups in one beat. The module
    // streams add their owners' lines to `prewarmEntries`; an entry's `initial` is what its owner builds the content with.
    // Counted from the first frame SHOWN (THE FIRST FRAME): a draw under the held content's opacity 0 is no draw, and links nothing.
    // THE GATE: it starts once this frame is shown and quiet -- the launcher's catalogue and icon bake done (their decode is ~1 s of
    // this thread), the engine at rest with nothing the next click may take, and no pointer motion over the bars for `prewarmQuietMs`
    // -- or, whatever of that still stands, `prewarmCapMs` after the frame was shown (the engine still builds each entry only at rest).
    // A popup asked for meanwhile takes the warm-up's place at once (GooeyEngine._pwFrame).
    property bool prewarm: true
    property int prewarmQuietMs: 1500
    property int prewarmCapMs: 20000
    // THE ORDER: what a click most likely wants first and what is cheap, then the costly ones; weather (its every card built) and the
    // LLM last. Measured nested (build / the largest GUI block, ms): clock 205 / 205, notifications 33, panorama 15, theme 66, aerial
    // 74 / 150, silicon 71 / 740 (its board's first draw), bridge 130 / 140, weather 200 / 200, llm 56. Every entry but the clock is
    // INCUBATED (GooeyEngine.prewarm); the clock's content is kept after its warm-up (parkPinned) and is built as it always was (`sync`).
    function prewarmEntries() {
        const entries = [];
        entries.push({ ownerId: clockOwner.ownerId, component: clockOwner.popupComponent, initial: { parked: true }, sync: true });
        entries.push({ ownerId: notificationsOwner.ownerId, component: notificationsOwner.managerComponent, initial: { parked: true } });
        if (panoramaOwner.svc)
            // both tabs: the presets' cards and the displays' canvas link their pipelines here, not in the turn a tab is first shown
            entries.push({ ownerId: panoramaOwner.ownerId, component: panoramaOwner.popupComponent, initial: { parked: true, eager: true } });
        if (frame.moduleOn("theme"))
            entries.push({ ownerId: themeOwner.ownerId, component: themeOwner.popupComponent, initial: { parked: true } });
        // aerial: the board's popup, built parked with `prewarm` (the board on, the power-on snapped, every layer drawn once: the board,
        // glow, globe and tunnel pipelines link here, never in the turn the popup opens with; the entrance is the popup's own)
        if (aerialOwner.svc)
            entries.push({ ownerId: aerialOwner.ownerId, component: aerialOwner.popupComponent, initial: { parked: true, prewarm: true } });
        // prewarm: the board ON (no entrance: a dark board draws no hologram or spark) and the card's patch shown, drawn through the engine's plain path and its clip layer too, where the open's
        // power-on draws them
        if (siliconOwner.svc)
            entries.push({ ownerId: siliconOwner.ownerId, component: siliconOwner.popupComponent, initial: { parked: true, prewarm: true } });
        // the bridge: the phone's body is one traced picture; prewarm draws it live and as its cached layer, so both pipelines link here
        // and not in the turn the popup opens with
        if (bridgeOwner.svc)
            entries.push({ ownerId: bridgeOwner.ownerId, component: bridgeOwner.popupComponent, initial: { parked: true, prewarm: true } });
        if (weatherOwner.service)
            // eagerCards: the strip, list and tiles are built too, so their shaders link here and not at the first switch to
            // normal / detailed (mini alone builds 99 of the popup's 3582 items)
            entries.push({ ownerId: weatherOwner.ownerId, component: weatherOwner.popupComponent, initial: { parked: true, eagerCards: true } });
        // the LLM: the history panel and the transcript are most of ~3 600 items; built parked, it takes nothing of the service
        if (frame.moduleOn("llm") && llmOwner.llm && llmOwner.llm.service)
            entries.push({ ownerId: llmOwner.ownerId, component: llmOwner.popupComponent, initial: { parked: true } });
        return entries;
    }
    function _prewarmWaitReason(): string {
        const l = frame.services.launcher;
        if (l && l.ready !== true)
            return "launcher";
        if (Date.now() - prewarmPointer.movedAt < frame.prewarmQuietMs)
            return "pointer";
        return gooeyEngine._pwWaitReason();
    }
    property string _prewarmGateWhy: "-"
    Timer {
        id: prewarmGate
        interval: 250
        repeat: true
        running: frame.ready && frame.presented && frame.prewarm && !frame._prewarmGateOpen
        onTriggered: {
            const capped = frame._shownAt > 0 && Date.now() - frame._shownAt >= frame.prewarmCapMs;
            const why = frame._prewarmWaitReason();
            if (why !== "" && !capped) {
                if (why !== frame._prewarmGateWhy)
                    console.log("LARES prewarm wait " + why);
                frame._prewarmGateWhy = why;
                return;
            }
            frame._prewarmGateOpen = true;
            frame._prewarmGate = why === "" ? "idle" : "cap";
            prewarmTurn.restart();
        }
    }
    property bool _prewarmGateOpen: false
    property string _prewarmGate: ""
    // The pointer's last MOTION over this window (a resting pointer's hover point is re-delivered every frame: only a move counts).
    HoverHandler {
        id: prewarmPointer
        enabled: !frame._prewarmGateOpen
        property real movedAt: 0
        property point last: Qt.point(-1, -1)
        onHoveredChanged: prewarmPointer.movedAt = Date.now()
        onPointChanged: {
            const p = prewarmPointer.point.position;
            if (Math.abs(p.x - prewarmPointer.last.x) + Math.abs(p.y - prewarmPointer.last.y) < 1)
                return;
            prewarmPointer.last = p;
            prewarmPointer.movedAt = Date.now();
        }
    }
    Timer {
        id: prewarmTurn
        interval: 2500 * Math.max(0, frame.services.screenNames.indexOf(frame.screenName))
        onTriggered: {
            frame._prewarmAsked = true;
            gooeyEngine.prewarm(frame.prewarmEntries(), { afterReadyMs: frame._shownAt > 0 ? Date.now() - frame._shownAt : -1, gate: frame._prewarmGate });
        }
    }
    // Has this frame's warm-up been asked for and run out (or is it off)? A function, not a binding: the engine's queue is an array
    // changed in place and says nothing when it empties. ShellServices' settle check reads it (`LARES settled`): a gate that
    // measures the shell AT REST starts its window after it, never inside the warm-up's CPU and frames.
    property bool _prewarmAsked: false
    function prewarmDone(): bool {
        return !frame.prewarm || (frame._prewarmAsked && !gooeyEngine.prewarming && gooeyEngine._pwQueue.length === 0);
    }

    ClockBarOwner {
        id: clockOwner
        engine: gooeyEngine
        bar: frame.barOf("clock")
        barId: frame.barIdOf("clock")
        anchorItem: clockButton
        shellHosted: true
        timerService: frame.services.timers
        calendarService: frame.services.calendar
        wikiService: frame.services.wiki
        screentimeService: frame.services.screentime
        workspaces: workspacesModule
        wikiFontFamily: frame.fontFamily
        openMode: frame.services.clockConfig.settings.open
        wikiSide: frame.services.clockConfig.settings.look.secondarySide
        wikiTearoff: frame._wikiShow.calendar
    }
    // wiki.jsonc show: where the wiki's card is (a service with no config, the mock's, shows it everywhere)
    readonly property var _wikiShow: frame.services.wiki && frame.services.wiki.config ? frame.services.wiki.config.show
        : ({ calendar: true, notifications: true, lock: true, launcher: true })

    // ---- stocks ---------------------------------------------------------------------------------------------------------------------
    ModuleSlot {
        host: frame
        moduleId: "stocks"
        StocksBarButton {
            id: stocksButton
            owner: stocksOwner
            anchors.verticalCenter: parent.verticalCenter
            fontFamily: frame.fontFamily
        }
    }
    StocksBarOwner {
        id: stocksOwner
        engine: gooeyEngine
        bar: frame.barOf("stocks")
        barId: frame.barIdOf("stocks")
        anchorItem: stocksButton
        shellHosted: true
        service: frame.services.stocks
        fontFamily: frame.fontFamily
        // stocks.jsonc detailMemoryMin, look.secondarySide
        detailMemoryMin: frame.services.stocks ? frame.services.stocks.config.detailMemoryMin : 10
        detailSide: frame.services.stocks ? frame.services.stocks.config.look.secondarySide : "end"
    }

    // ---- player: the album disc (a flourish on a new track), N3's owner ----------------------------------------------------------------------------------------
    ModuleSlot {
        host: frame
        moduleId: "player"
        PlayerBarButton {
            id: playerButton
            player: frame.services.mpd
            anchors.verticalCenter: parent.verticalCenter
            // A right click is the module's one quick action, as on its siblings (the theme's mode, the bell's do not disturb,
            // the volume's mute): play / pause, with no popup. It was taken and dropped.
            onClicked: button => {
                if (button === Qt.LeftButton)
                    playerOwner.toggle();
                else if (button === Qt.RightButton && frame.services.mpd)
                    frame.services.mpd.toggle();
            }
        }
    }
    PlayerBarOwner {
        id: playerOwner
        engine: gooeyEngine
        bar: frame.barOf("player")
        barId: frame.barIdOf("player")
        anchorItem: playerButton
        player: frame.services.mpd
        fontFamily: frame.fontFamily
        // player.jsonc
        openView: frame.services.playerConfig.settings.open.view
        openSidebar: frame.services.playerConfig.settings.open.sidebar
        openPanel: frame.services.playerConfig.settings.open.panel
        openRemember: frame.services.playerConfig.settings.open.remember
        levelTapEnabled: frame.services.playerConfig.settings.musicSparks
        autoplay: frame.services.playerConfig.settings.autoplay
        holdForRecord: frame.services.playerConfig.settings.holdForRecord
        libraryGrouping: frame.services.playerConfig.settings.library.grouping
        librarySort: frame.services.playerConfig.settings.library.sort
        libraryAscending: frame.services.playerConfig.settings.library.ascending
        libraryLooseArtists: frame.services.playerConfig.settings.library.looseArtists
    }

    // ---- volume: the two-half pill (AudioBarButton, wired by VolumeParity) ---------------------------------------------------------------------------------------------------
    ModuleSlot {
        host: frame
        moduleId: "volume"
        VolumeParity {
            id: volumeParity
            pipewire: frame.services.pipewire
            osd: frame.services.osd
            onMixerRequested: half => audioOwner.showHalf(half)
            // the natural-scroll reader (NaturalScroll) lives behind `live`: a frame with a window has the compositor to ask
            live: !!frame.window
            locked: frame.services.lock.locked
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    // The audio popup, hanging from the pill (a left click opens it; a right click mutes).
    AudioBarOwner {
        id: audioOwner
        engine: gooeyEngine
        bar: frame.barOf("volume")
        barId: frame.barIdOf("volume")
        anchorItem: volumeParity
        service: frame.services.audio
        parity: volumeParity
        fontFamily: frame.fontFamily
        renderScale: frame.renderScale * frame.popupRatio
        halfOpens: [frame.services.audioConfig.settings.pill.speakerOpens, frame.services.audioConfig.settings.pill.micOpens]
    }

    // ---- aerial: the network (Wi-Fi, cable, hotspot, Bluetooth, the tunnel) -------------------------------------------------------------------------
    ModuleSlot {
        host: frame
        moduleId: "aerial"
        AerialBarOwner {
            id: aerialOwner
            engine: gooeyEngine
            bar: frame.barOf("aerial")
            barId: frame.barIdOf("aerial")
            shellHosted: true
            service: frame.services.aerial
            // aerial.jsonc bar: the figures at all, and from how many Mbps (they stay down to half of it)
            trafficEnabled: !frame.services.aerial || !frame.services.aerial.config || frame.services.aerial.config.bar.traffic
            trafficConfig: frame.services.aerial && frame.services.aerial.config
                ? { enterMbps: frame.services.aerial.config.bar.trafficFromMbps, stayMbps: frame.services.aerial.config.bar.trafficFromMbps / 2 } : ({})
            // the board's family is silicon's one setting for both boards
            family: siliconOwner.family
            // the traffic figures are drawn in the shell's face like the clock's and the stocks' figures (the owner's own default is Inter)
            fontFamily: frame.fontFamily
            anchors.verticalCenter: parent.verticalCenter
            width: aerialOwner.implicitWidth
            height: aerialOwner.implicitHeight
        }
    }

    // ---- the bridge (a phone) ----------------------------------------------------------------------------------------------------------------------------
    ModuleSlot {
        host: frame
        moduleId: "bridge"
        BridgeBarButton {
            id: bridgeButton
            objectName: "bridgeBarButton"
            anchors.verticalCenter: parent.verticalCenter
            service: frame.services.bridge
            owner: bridgeOwner
            // files dropped on the glyph: sent to the current phone, and the popup opens so the send is seen
            onFilesDropped: paths => bridgeOwner.sendFiles(paths)
        }
    }
    BridgeBarOwner {
        id: bridgeOwner
        engine: gooeyEngine
        bar: frame.barOf("bridge")
        barId: frame.barIdOf("bridge")
        anchorItem: bridgeButton
        shellHosted: true
        service: frame.services.bridge
        fontFamily: frame.fontFamily
    }

    // ---- panorama (the displays AND the presets: one popup, two tabs): the pane count, always on show; a click toggles the popup (no key, no right click: decision 9) ----------
    ModuleSlot {
        host: frame
        moduleId: "panorama"
        PanoramaBarButton {
            id: panoramaButton
            objectName: "panoramaBarButton"
            anchors.verticalCenter: parent.verticalCenter
            panes: frame.services.panorama ? frame.services.panorama.panes : 1
            mirroring: !!frame.services.panorama && frame.services.panorama.mirroring === true
            hueOn: BarHues.panoramaOn
            hueHover: BarHues.panoramaHover
            onClicked: button => {
                if (button === Qt.LeftButton)
                    panoramaOwner.toggle();
            }
        }
    }
    PanoramaBarOwner {
        id: panoramaOwner
        engine: gooeyEngine
        bar: frame.barOf("panorama")
        barId: frame.barIdOf("panorama")
        anchorItem: panoramaButton
        shellHosted: true
        service: frame.services.panorama
        presets: frame.services.presets
        appLookup: frame.services.appLookup
        fontFamily: frame.fontFamily
        renderScale: frame.renderScale * frame.popupRatio
    }

    // ---- silicon -------------------------------------------------------------------------------------------------------------------------------------
    ModuleSlot {
        host: frame
        moduleId: "silicon"
        SiliconBarButton {
            id: siliconButton
            objectName: "siliconBarButton"
            anchors.verticalCenter: parent.verticalCenter
            fontFamily: frame.fontFamily
        }
    }
    SiliconBarOwner {
        id: siliconOwner
        engine: gooeyEngine
        bar: frame.barOf("silicon")
        barId: frame.barIdOf("silicon")
        anchorItem: siliconButton
        shellHosted: true
        // no `prewarmArmed`: silicon's own whole-popup draw (SiliconPrewarm, 6 s after start) would draw what the engine's prewarm entry below draws, through the clip
        // layer too, and leaves the first cold open and the first close at 108 / 193 ms gaps; the engine's alone is 25 / 16
        service: frame.services.silicon
        fontFamily: frame.fontFamily
    }

    // ---- the system update ------------------------------------------------------------------------------------------------------------------------------
    ModuleSlot {
        host: frame
        moduleId: "update"
        SystemUpdateBarOwner {
            id: updateOwner
            engine: gooeyEngine
            bar: frame.barOf("update")
            barId: frame.barIdOf("update")
            updates: frame.services.updates
            fontFamily: frame.fontFamily
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    // ---- notifications: the bell, the manager under it, the toast lane at the top bar's right end ----------------------------------------------------------------------
    ModuleSlot {
        host: frame
        moduleId: "notifications"
        NotificationsBarButton {
            id: bell
            owner: notificationsOwner
            anchors.verticalCenter: parent.verticalCenter
        }
    }
    NotificationsBarOwner {
        id: notificationsOwner
        engine: gooeyEngine
        bar: frame.barOf("notifications")
        barId: frame.barIdOf("notifications")
        anchorItem: bell
        screenName: frame.screenName
        service: frame.services.notifications
        clock: frame.services.notifyClock
        wiki: frame._wikiShow.notifications ? frame.services.wiki : null
        shellHosted: true
        pill: frame.toastPill
        // The stack is the PILL while the bars are hidden AND while this screen's focused window is fullscreen: the lane hangs from the
        // bars, which are on the Top layer under the video, so a critical toast (the one thing the fullscreen hold lets through) would be
        // shown to nobody.
        barsHidden: !frame.barsShown || frame.fullscreenHere
    }

    // ---- the launcher and the clipboard: keys only, out of the bottom bar's middle -------------------------------------------------------------------------------------------------------
    // The shell's ONE LauncherService is handed in (a hosted owner builds none); the keys it
    // opens with (the router's Alt+Space calls shortcutPressed()) are held by a grab over THIS screen's bar window -- with a
    // grab the owner asks the layer for NO keyboard (an Exclusive request clears a HyprlandFocusGrab at once).
    LauncherBarOwner {
        id: launcherOwner
        engine: gooeyEngine
        bar: bottomBar
        barId: "bottom"
        wiki: frame.services.wiki
        tune.wikiTeaser: frame._wikiShow.launcher
        dryRun: frame.services.mock
        shellHosted: true
        service: frame.services.launcher
        shortcutEnabled: false
        grabWindows: frame.keyGrabWindows
    }
    ClipStyle {
        id: clipStyle
    }
    ClipboardBarOwner {
        id: clipboardOwner
        engine: gooeyEngine
        bar: bottomBar
        barId: "bottom"
        service: frame.services.clipboard
        style: clipStyle
        fontFamily: frame.fontFamily
        shellHosted: true
        shortcutEnabled: false
        liveWindow: frame.services.live
        grabWindows: frame.keyGrabWindows
    }
    // The emoji / symbol picker (Alt+Period): the clipboard's bottom-bar, key-only way, on the shell's one PickerService.
    PickerStyle {
        id: pickerStyle
    }
    PickerBarOwner {
        id: pickerOwner
        engine: gooeyEngine
        bar: bottomBar
        barId: "bottom"
        service: frame.services.picker
        style: pickerStyle
        fontFamily: frame.fontFamily
        tabList: frame.services.pickerConfig.settings.tabs
        openTab: frame.services.pickerConfig.settings.openTab
        nerdPick: frame.services.pickerConfig.settings.nerdPick
        recents: frame.services.pickerConfig.settings.recents
        shellHosted: true
        shortcutEnabled: false
        liveWindow: frame.services.live
        grabWindows: frame.keyGrabWindows
    }

    // ---- the OSD: out of the right bar's middle; only one screen presents it (the focused one, or osd.jsonc's `screen`) --------------------------------------------------------------------------------------------------------------
    OsdOwner {
        id: osdOwner
        engine: gooeyEngine
        service: frame.services.osd
        style: frame.services.osdStyle
        pill: frame.osdPill
        barsHidden: !frame.barsShown
        held: !!frame.services.themeControl && frame.services.themeControl.wipeClaimed(frame.screenName)
        // the OSD wheel reads the same natural-scroll setting as the bar's volume pair (VolumeParity's one NaturalScroll)
        naturalScroll: volumeParity.naturalScroll
        screenName: frame.screenName
        // `active` (this screen is the one it comes on) and `fullscreen` are read from the shell's ONE FocusedScreen
        focusSource: frame.services.focus
        readonly property var config: frame.services.osd.config.config
        screen: osdOwner.config.screen
        fullscreenMode: osdOwner.config.fullscreen
        spot: osdOwner.config.spot
        dismissMs: osdOwner.config.dismissMs
        resumeMinMs: osdOwner.config.resumeMinMs
        queueCap: osdOwner.config.queueCap
        captureClick: osdOwner.config.capture.click
        // a click on the now-playing card opens the player's popup, on the screen that showed it
        onPlayerRequested: playerOwner.open()
    }

    // ---- the lock ---------------------------------------------------------------------------------------------------------------------------------------------------------------------
    // The lock's popup hangs from the clock's island on every screen (ShellServices.lock: one LockOwner, a registration per screen).
    // The island changes with the layout (islands <-> continuous, the clock moved to another zone): the registration follows it. It is
    // made once the frame has a size (a popup asked for before the engine has a bar to hang from opens nothing) and is on screen (THE FIRST
    // FRAME: the popup comes out of a bar that is there, instead of having opened out of sight).
    readonly property var _lockBar: frame.barOf("clock")
    property var _lockedBar: null
    function _lockRegister(): void {
        if (!frame.ready || !frame.presented || frame._lockedBar === frame._lockBar)
            return;
        frame._lockedBar = frame._lockBar;
        frame.services.lock.register(frame.screenName, gooeyEngine, frame._lockBar, frame.barIdOf("clock"), clockButton);
    }
    on_LockBarChanged: frame._lockRegister()
    onReadyChanged: frame._lockRegister()
    onPresentedChanged: {
        if (frame.presented && frame._shownAt === 0)
            frame._shownAt = Date.now();
        frame._lockRegister();
    }
    // when this frame was first shown (the prewarm's log counts from it)
    property real _shownAt: 0

    // ---- registration with the services ------------------------------------------------------------------------------------------------------------------------------------------------
    signal completed()
    Component.onCompleted: {
        frame._oledKey = frame.services.oled.holderKey(frame.screenName);
        frame.services.oled.setHeld(frame._oledKey, frame.oledHeld);
        frame.services.registerScreen(frame.screenName, frame);
        frame._lockRegister();
        frame.completed();
    }
    Component.onDestruction: {
        frame.services.oled.setHeld(frame._oledKey, false);
        // A REPLACED FRAME UNREGISTERS NOTHING. An output that goes and comes back in one update of `Quickshell.screens` (a GPU switch, a re-plug) gets its new
        // frame before the old one is destroyed: the old one's name is the new one's, and taking the name out would drop the live frame from the
        // registry. Its owners' sharedFlags would then reach nothing: a popup open on that screen would tell no service so (silicon's ladder would sit at halt for good).
        if (frame.services.frames[frame.screenName] !== frame)
            return;
        frame.services.lock.unregister(frame.screenName);
        frame.services.unregisterScreen(frame.screenName);
    }
}
