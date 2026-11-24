pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../system"
import "ThemeResolve.js" as Resolve

// =============================================================================
// Theme.qml — the shell's palette, as data.
//
// Three layers, in the order they win:
//   L0  the code defaults below. They ARE the eva-light values the components
//       were built with (SystemUpdatePopup / PhaseRail / TerminalView), so a
//       machine with no theme file on disk renders the plain eva-light shell.
//       Nothing here is ever written to a file.
//   L1  <name>.json — a light/dark pair. ONE file, read by the shell, the lock,
//       the mockups and themectl: ~/.config/theme/themes/<name>.json, and until
//       `themectl install` has put the repo's themes there, the repo's own
//       themes/<name>.json. Every key is optional and falls through to L0; a
//       half-written dark block renders as shipped values, never as magenta.
//   L2  ~/.config/theme/state.json — which pair and which mode are active.
//       This is user state, not shell code, so it lives outside the repo.
//
// Writing JSON never reloads the Quickshell config (editing a .qml always
// does, and that resets the session), which is the whole reason a theme is
// data rather than QML literals: a switch re-evaluates bindings in ~1ms and
// nothing on screen resets.
//
// THE CROSSFADE IS ONE CLOCK. A switch snapshots the colours currently on
// screen as `_fromC`, resolves the new theme+mode into `_toC`, and runs a
// single NumberAnimation on `_mix`. Every token property is a lerp of those
// two, so every colour moves on one animation. A `Behavior on color` per token
// would be one clock per token *and* would animate a live hex edit from the panel,
// which must land instantly.
// =============================================================================
Singleton {
    id: root

    // ---- Where things live -------------------------------------------------
    // THE THEMES' HOME (theme.md L1): themectl, the shell, the lock and the mockups read ONE file per theme, so an edit made in a
    // mockup's Theme tab reaches the deployed shell and the desktop's other programs. It is ~/.config/theme/themes/<name>.json;
    // until `themectl install` has put the repo's themes there, the repo's own themes/<name>.json answers (every test runs with a
    // private XDG_CONFIG_HOME). Which pair and which mode are active is not a theme: it
    // is ~/.config/theme/state.json, beside them.
    readonly property string stateDir: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/theme"
    readonly property string statePath: root.stateDir + "/state.json"
    readonly property string homeThemesDir: root.stateDir + "/themes"
    readonly property string repoThemesDir: RepoRoot.dir + "/themes"
    // The file the active theme was read from (a live edit is written back there) and its directory; the home directory while
    // nothing is loaded.
    readonly property string themePath: root._themePath
    readonly property string themesDir: root._themePath !== "" ? root._themePath.substring(0, root._themePath.lastIndexOf("/")) : root.homeThemesDir

    // ---- Public API --------------------------------------------------------
    readonly property var pairs: root._pairs                 // theme names on disk, sorted
    readonly property string themeName: root._themeName      // the active pair
    readonly property string mode: root._mode                // "light" | "dark"
    readonly property bool ready: root._ready                // a theme file is loaded
    readonly property string lastError: root._lastError      // "" when fine

    property int fadeMs: 420
    property int fadeEasing: Easing.InOutQuad
    readonly property real fadeProgress: !root._switching ? 0 : (root._hosted ? root._snapMix : root._mix)

    // ---- The snapshot crossfade ---------------------------------------------
    //
    // WHY. A lerp on every token is ONE clock, but it is one clock read by
    // every binding on every token in the scene, ~25 times over the fade. On a
    // popup of five thousand items that cascade costs 33-88 ms a frame
    // (measured): seven frames of stepping where the system update, a
    // tenth the size, runs at 120. The cost is proportional to the scene.
    //
    // RAM FOR CPU. A host that can hold a picture of itself registers here.
    // While one is registered a switch does not lerp at all: the host is told
    // to capture the frame as it is (`aboutToSwitch`), the tokens are written
    // ONCE when it says it has (`commitSwitch`), and the host fades its
    // picture out over `fadeMs` on the one clock below. One texture the size
    // of the window buys back the whole cascade; the per-frame cost is a
    // single textured quad. Every consumer sees the same thing it always saw
    // -- a crossfade from the old palette to the new -- and `fadeProgress`
    // keeps its meaning. What changes for a consumer that BAKES a colour into
    // something (a rich-text document) is that the tokens are final at once,
    // so it bakes on `settled`, which both paths emit when the palette is
    // where it will stay.
    //
    // ONE HOST PER WINDOW. The shell has a window per screen, each with its own
    // ThemeCrossfade, and the windows are on outputs with frame clocks of their
    // own. A host's picture must be the OLD palette, so it has to be taken
    // before the tokens are written -- by EVERY host, or the one whose frame
    // comes late captures the new palette and cuts (measured offscreen: t 1.00
    // against 0.53 for its neighbour). So a switch asks every
    // registered host, waits until each has said that its picture is taken --
    // or that it cannot take one (no size, window not shown) -- and commits
    // ONCE: `registerHost` / `unregisterHost` / `hostReady`, with the 120 ms
    // fallback for a host that never answers. A host that goes away mid-switch
    // stops being waited for. With ONE host every step happens in that host's
    // own frame.
    property var _hosts: []
    property var _awaitList: []
    // Every registered host, read-only: a ThemeIsland finds the host of its own window here.
    readonly property var crossfadeHosts: root._hosts
    function registerHost(host) {
        if (root._hosts.indexOf(host) < 0)
            root._hosts = root._hosts.concat([host]);
    }
    function unregisterHost(host) {
        root._hosts = root._hosts.filter(x => x !== host);
        if (root._awaitList.indexOf(host) >= 0)
            root.hostReady(host);
    }
    // The host's picture is taken (or it cannot take one): the last answer commits.
    function hostReady(host) {
        if (!root._hosted || !root._pendingC || root._awaitList.indexOf(host) < 0)
            return;
        root._awaitList = root._awaitList.filter(x => x !== host);
        if (root._awaitList.length === 0)
            root.commitSwitch();
    }
    // True from the ask until the picture has faded: the host shows its
    // picture while this holds and it has one.
    readonly property bool crossfading: root._switching && root._hosted
    // The palette is about to change; a host captures the frame NOW and calls
    // commitSwitch() once it has.
    signal aboutToSwitch()
    // The palette is final and will not move again: bake into documents now.
    // The lerp path emits it when its fade lands; the hosted path emits it the
    // moment the tokens are written, BEFORE the picture starts to fade, so the
    // one heavy frame is hidden behind the picture.
    signal settled()
    property bool _hosted: false
    property real _snapMix: 1
    property var  _pendingC: null

    function commitSwitch() {
        if (!root._hosted || !root._pendingC)
            return;
        _hostFallback.stop();
        root._awaitList = [];
        fadeAnim.stop();
        const next = root._pendingC;
        root._pendingC = null;
        root._fromC = next;
        root._toC = next;
        root._mix = 1;                    // every token, written once
        root.settled();                   // the bakers rebuild in this frame
        root._snapMix = 0;
        if (!root.fadeExternal)
            snapAnim.restart();           // then the picture fades on one clock
    }
    NumberAnimation {
        id: snapAnim
        target: root
        property: "_snapMix"
        from: 0
        to: 1
        duration: root.fadeMs
        easing.type: root.fadeEasing
        onFinished: {
            root._switching = false;
            root._hosted = false;
        }
    }
    // ---- A switch held back, a fade on somebody else's clock (the live curtain, modules/shell/ThemeWipe.qml) ---
    //
    // The curtain's wipe wants the shell to stay LIVE, in the OLD palette, while the apps repaint behind the still, and the shell's
    // palette to change in the frame the reveal starts. So:
    //   deferSwitches   true: a switch that arrives (ours or the state file's) changes nothing of the shell: `mode`, `themeName` and
    //                   the tokens stay, and it is KEPT (the last one wins). Our own is still written to the state file at once:
    //                   that file is what the apps follow.
    //   applyDeferred() runs the kept switch through the ordinary hosted path, true if there was one.
    //   fadeExternal    true: the commit starts no clock of its own, `fadeProgress` is what driveFade() writes, endExternalFade()
    //                   ends the fade. A wipe's line and every FadeColor read one clock, the wipe's.
    // All three off (always, without the wipe) change nothing on any path.
    property bool deferSwitches: false
    property bool fadeExternal: false
    property var _deferred: null
    readonly property bool switchDeferred: root._deferred !== null
    // What the shell is about to be, which is what the theme OSD says: the kept switch from the moment it arrives, `themeName` / `mode` otherwise. The card opens in the
    // OLD palette, while the shell is still old, so it is in the old shell's picture and the line goes over it like over everything else.
    readonly property string announcedName: root._deferred ? root._deferred.theme : root._themeName
    readonly property string announcedMode: root._deferred ? root._deferred.mode : root._mode
    function applyDeferred() {
        const d = root._deferred;
        if (!d)
            return false;
        root._deferred = null;
        root._mode = d.mode;
        if (d.theme !== root._themeName) {
            root._themeName = d.theme;
            root._readThemeFile();
        }
        root._apply(true);
        return true;
    }
    // The running wipe of the window `item` is in, null when there is none.
    function wipeFor(item) {
        const win = item ? item.Window.window : null;
        for (let i = 0; win && i < root._hosts.length; i++)
            if (root._hosts[i].hostWindow === win)
                return root._hosts[i].wiping ? root._hosts[i].wipe : null;
        return null;
    }
    function driveFade(p) {
        if (root.fadeExternal && root._switching && root._hosted)
            root._snapMix = p;
    }
    function endExternalFade() {
        if (!root.fadeExternal)
            return;
        root.fadeExternal = false;
        if (root._switching && root._hosted && !root._pendingC) {
            root._snapMix = 1;
            root._switching = false;
            root._hosted = false;
        }
    }

    // A host that never answers (hidden, or gone between the ask and the
    // capture) must not leave the palette half-switched.
    Timer {
        id: _hostFallback
        interval: 120
        onTriggered: root.commitSwitch()
    }

    // ---- The tokens --------------------------------------------------------
    // Declared properties, not a string lookup, so `Theme.surfce` is a lint
    // error instead of a silently unthemeable value.
    readonly property color surface: root._c("surface")
    readonly property color panelSunk: root._c("panelSunk")
    readonly property color bevel: root._c("bevel")
    readonly property color border: root._c("border")
    readonly property color shadowDeep: root._c("shadowDeep")
    readonly property color listBox: root._c("listBox")
    readonly property color headerBox: root._c("headerBox")
    readonly property color headerBoxBevel: root._c("headerBoxBevel")
    readonly property color headerBoxShadow: root._c("headerBoxShadow")
    readonly property color textPrimary: root._c("textPrimary")
    readonly property color textMuted: root._c("textMuted")
    readonly property color textFaint: root._c("textFaint")
    readonly property color accent: root._c("accent")
    readonly property color accentHover: root._c("accentHover")
    readonly property color accentBevel: root._c("accentBevel")
    readonly property color textOnAccent: root._c("textOnAccent")
    readonly property color ok: root._c("ok")
    readonly property color warn: root._c("warn")
    // Deep yellow: a fact that is degrading but not failing -- today, a model
    // spilling out of VRAM into system RAM. Distinct from `warn`, which in
    // this shell is pacman core's orange and already names a category.
    readonly property color spill: root._c("spill")
    readonly property color error: root._c("error")
    readonly property color errorStrong: root._c("errorStrong")
    readonly property color errorTint: root._c("errorTint")
    readonly property color catCore: root._c("catCore")
    readonly property color catExtra: root._c("catExtra")
    readonly property color catMultilib: root._c("catMultilib")
    readonly property color catAur: root._c("catAur")
    readonly property color catFlatpak: root._c("catFlatpak")
    // Hyprland's locked group tab (themes' `hyprBorderLocked`, which themectl writes into Hyprland's groupbar): a drawing of a locked
    // group (the presets' face) takes the colour the desktop shows it in.
    readonly property color hyprBorderLocked: root._c("hyprBorderLocked")
    // The LLM module's conversation categories: six hues of its own, none of
    // them the accent (which is the "no category" fallback) or the faint ink.
    readonly property color llmCode: root._c("llmCode")
    readonly property color llmSystem: root._c("llmSystem")
    readonly property color llmExplain: root._c("llmExplain")
    readonly property color llmWrite: root._c("llmWrite")
    readonly property color llmData: root._c("llmData")
    readonly property color llmOther: root._c("llmOther")
    // The weather module's hues: one per condition (sun, cloud, rain, snow,
    // storm, fog, night) -- what bars, charts and the backdrop are coloured
    // with; the carved glyphs have their own below -- and six generic scale bands
    // (good .. extreme) every index in it is read on: UV, air quality, pollen,
    // wind. A row carries the band INDEX; the delegate resolves the colour.
    readonly property color weatherSun: root._c("weatherSun")
    readonly property color weatherCloud: root._c("weatherCloud")
    readonly property color weatherRain: root._c("weatherRain")
    readonly property color weatherSnow: root._c("weatherSnow")
    readonly property color weatherStorm: root._c("weatherStorm")
    readonly property color weatherFog: root._c("weatherFog")
    readonly property color weatherNight: root._c("weatherNight")
    // The carved condition glyphs' own colours, one per PART (WeatherGlyph):
    // the references' saturated bodies -- a white cloud with a grey one behind
    // it, a yellow disc on an orange crown, a gold crescent and its stars, blue
    // drops, icy flakes and hail, an amber bolt, grey fog bars and wind lines.
    // Separate from the hues above, which bars, charts and the backdrop read.
    readonly property color weatherSunDisc: root._c("weatherSunDisc")
    readonly property color weatherSunCrown: root._c("weatherSunCrown")
    readonly property color weatherMoon: root._c("weatherMoon")
    readonly property color weatherStar: root._c("weatherStar")
    readonly property color weatherCloudFront: root._c("weatherCloudFront")
    readonly property color weatherCloudBack: root._c("weatherCloudBack")
    readonly property color weatherDrop: root._c("weatherDrop")
    readonly property color weatherFlake: root._c("weatherFlake")
    readonly property color weatherHail: root._c("weatherHail")
    readonly property color weatherBolt: root._c("weatherBolt")
    readonly property color weatherFogBar: root._c("weatherFogBar")
    readonly property color weatherWindLine: root._c("weatherWindLine")
    // What a glyph part's colour is MULTIPLIED by at the edge of its inset:
    // one per mode so the carve reads equally deep on both cards. The light
    // value is what gives a WHITE cloud an outline on the light card at 24 px
    // (#B2B6BF would leave it a 1 px ring at 1.2:1 against the card).
    readonly property color weatherGlyphShade: root._c("weatherGlyphShade")

    // ---- the networking plate's metal -------------------------------------
    // A socket is hardware set into the plate, so its parts are MATERIALS
    // rather than palette roles: a metal face, a deeper cavity, gold contacts,
    // a dead lens and the three lamps that light it. The lamps alias the
    // status colours the rest of the shell already uses, so a lit link lamp is
    // the same green as an OK anywhere else.
    // a socket's metal face, set into the plate
    readonly property color netShell: root._c("netShell")
    // the cavity behind the face: the deepest metal
    readonly property color netShellDark: root._c("netShellDark")
    // gold contacts, a jack's comb
    readonly property color netContact: root._c("netContact")
    // a lamp's dead lens
    readonly property color netLampOff: root._c("netLampOff")
    // a link lamp, lit
    readonly property color netLampLink: root._c("netLampLink")
    // an activity lamp, lit
    readonly property color netLampAct: root._c("netLampAct")
    // a lamp reporting limited or portal
    readonly property color netLampWarn: root._c("netLampWarn")
    // the bluetooth module's board
    readonly property color netPcb: root._c("netPcb")
    // a printed trace: the meander antenna
    readonly property color netTrace: root._c("netTrace")
    // the VPN key
    readonly property color netBrass: root._c("netBrass")
    // a bezel ring around a lamp or a keyway
    readonly property color netBezel: root._c("netBezel")
    // silk-screen marks on the plate
    readonly property color netLegend: root._c("netLegend")
    // what a socket part's colour is multiplied by at its inset's edge
    readonly property color netGlyphShade: root._c("netGlyphShade")
    // the specular edge a lifted part takes where it faces the light
    readonly property color netRim: root._c("netRim")
    // the edge a lifted part takes where it faces away
    readonly property color netShade: root._c("netShade")
    // ---- the battery's charge ------------------------------------------
    // What the fill, the nub, the particles and the event flashes say about
    // the flow of energy. Aliases of the status colours, so a charging battery
    // is the same green as an OK anywhere else, and each can part from its
    // status colour without touching it.
    // energy going in: charging, full, the charge particles and flash
    readonly property color batteryCharge: root._c("batteryCharge")
    // the fill while running on battery above the low mark
    readonly property color batteryDrain: root._c("batteryDrain")
    // low charge, and energy going out: the nub and particles while
    // discharging, the abort and low-charge flash
    readonly property color batteryLow: root._c("batteryLow")
    // plugged in with nothing flowing either way
    readonly property color batteryIdle: root._c("batteryIdle")
    // ---- the stocks module ---------------------------------------------
    // A price or a gain going up / down, and a trade marker on a chart: a buy
    // and a sell. Aliases of the status colours; the markers are NOT green and
    // red, because green and red already mean gain and loss.
    readonly property color stockGain: root._c("stockGain")
    readonly property color stockLoss: root._c("stockLoss")
    readonly property color stockBuy: root._c("stockBuy")
    readonly property color stockSell: root._c("stockSell")
    // ---- the silicon module (battery + CPU profile + GPU mode) ---------
    // A CPU profile and a GPU mode as colours: the hologram, its rim, the
    // trace light, the bar's glyph and dGPU mark. Aliases of the status
    // colours where they mean the same (Quiet and Integrated are the OK
    // green, Balanced and Hybrid the accent, Performance and dGPU-only the
    // strong warn); Smart has its own cyan. A tweaked profile (settings held
    // away from the profile's own) rims its hologram in profileTweak.
    readonly property color profileQuiet: root._c("profileQuiet")
    readonly property color profileBalanced: root._c("profileBalanced")
    readonly property color profilePerformance: root._c("profilePerformance")
    readonly property color profileTweak: root._c("profileTweak")
    readonly property color gpuIntegrated: root._c("gpuIntegrated")
    readonly property color gpuSmart: root._c("gpuSmart")
    readonly property color gpuHybrid: root._c("gpuHybrid")
    readonly property color gpuDgpu: root._c("gpuDgpu")
    // The board's two families, one slot per
    // material (board_materials.glsl names them). Carved Eva is the shell's
    // own material carved into a plateau of the popup's surface; Blueprint a
    // drafting sheet, white paper and blue ink by day, a cyanotype at night.
    readonly property color siliconEvaSurface: root._c("siliconEvaSurface")
    readonly property color siliconEvaBevel: root._c("siliconEvaBevel")
    readonly property color siliconEvaShadow: root._c("siliconEvaShadow")
    readonly property color siliconEvaGroove: root._c("siliconEvaGroove")
    readonly property color siliconEvaInk: root._c("siliconEvaInk")
    readonly property color siliconEvaSunk: root._c("siliconEvaSunk")
    readonly property color siliconEvaWell: root._c("siliconEvaWell")
    readonly property color siliconEvaMetal: root._c("siliconEvaMetal")
    readonly property color siliconBlueprintPaper: root._c("siliconBlueprintPaper")
    readonly property color siliconBlueprintInk: root._c("siliconBlueprintInk")
    readonly property color siliconBlueprintFaint: root._c("siliconBlueprintFaint")
    readonly property color siliconBlueprintGrid: root._c("siliconBlueprintGrid")
    readonly property color siliconBlueprintWash: root._c("siliconBlueprintWash")
    // The second palette: the 7-segment displays' window, unlit segments and bezel (one set per family), the
    // lock bar's amber (the theme's warn), gold (the card's fingers, the HDMI contacts), the memory hue (Catppuccin pink), the
    // display ribbon's film and its conductors. board_materials.glsl names the slots they fill.
    readonly property color siliconEvaWindow: root._c("siliconEvaWindow")
    readonly property color siliconEvaGhost: root._c("siliconEvaGhost")
    readonly property color siliconEvaBezel: root._c("siliconEvaBezel")
    readonly property color siliconBlueprintWindow: root._c("siliconBlueprintWindow")
    readonly property color siliconBlueprintGhost: root._c("siliconBlueprintGhost")
    readonly property color siliconBlueprintBezel: root._c("siliconBlueprintBezel")
    // The smoked glass over each display's window, one tint per family: what it lets through, multiplied into the lit segments
    // (a darker, slightly more saturated light) and into the window and the unlit segments seen through it.
    readonly property color siliconEvaGlass: root._c("siliconEvaGlass")
    readonly property color siliconBlueprintGlass: root._c("siliconBlueprintGlass")
    readonly property color siliconLock: root._c("siliconLock")
    readonly property color siliconGold: root._c("siliconGold")
    readonly property color siliconMemory: root._c("siliconMemory")
    readonly property color siliconRibbonFilm: root._c("siliconRibbonFilm")
    readonly property color siliconRibbonCopper: root._c("siliconRibbonCopper")
    // The display connector's flip-lock bar -- dark plastic in Carved Eva, deep ink in Blueprint (an alias of each family's own display window)
    readonly property color siliconEvaLatch: root._c("siliconEvaLatch")
    readonly property color siliconBlueprintLatch: root._c("siliconBlueprintLatch")
    // aerial's card (the Intel AX210 on its board): the materials silicon's board has not got -- the solder mask, the RF shield's tin and its solder rim, the label's paper, gold, the two coax jackets.
    // The same in every theme file (a PCB is green in every theme); the family palettes are silicon's own tokens.
    readonly property color aerialPcb: root._c("aerialPcb")
    readonly property color aerialShield: root._c("aerialShield")
    readonly property color aerialSolder: root._c("aerialSolder")
    readonly property color aerialPaper: root._c("aerialPaper")
    readonly property color aerialGold: root._c("aerialGold")
    readonly property color aerialCoaxMain: root._c("aerialCoaxMain")
    readonly property color aerialCoaxAux: root._c("aerialCoaxAux")
    // the label as the tunnel's shield (the VPN is up: the sticker turns to brushed chrome): the room's lights, the plate's own tone, its darks, and the
    // matte tone of the print roughened into it. Materials too: the same in every theme file.
    readonly property color aerialChromeSky: root._c("aerialChromeSky")
    readonly property color aerialChromeBase: root._c("aerialChromeBase")
    readonly property color aerialChromeDeep: root._c("aerialChromeDeep")
    readonly property color aerialChromeEtch: root._c("aerialChromeEtch")
    // the label's print (dark on the pale sticker of light mode, white on the dark sticker of dark mode) and the lip of a letter roughened into the chrome
    readonly property color aerialLabelInk: root._c("aerialLabelInk")
    readonly property color aerialLabelLip: root._c("aerialLabelLip")
    readonly property color bandGood: root._c("bandGood")
    readonly property color bandFair: root._c("bandFair")
    readonly property color bandModerate: root._c("bandModerate")
    readonly property color bandPoor: root._c("bandPoor")
    readonly property color bandVeryPoor: root._c("bandVeryPoor")
    readonly property color bandExtreme: root._c("bandExtreme")
    // The six bands as one array, indexed by a scale's band index.
    readonly property var bands: [root.bandGood, root.bandFair, root.bandModerate,
                                  root.bandPoor, root.bandVeryPoor, root.bandExtreme]
    // The clock's timers, and the fill they put in the Workspaces groove: a
    // countdown, a pomodoro focus session (tomato) and its break (a softer
    // tomato, toward the groove). None of them the accent: the workspace ball
    // is the accent, and it rolls over the fill.
    readonly property color timerRun: root._c("timerRun")
    readonly property color timerFocus: root._c("timerFocus")
    readonly property color timerBreak: root._c("timerBreak")
    // The colours a fill cycles through, one per revolution (a timer wound
    // past an hour, a stopwatch's minutes): each new turn is drawn over the
    // full ring of the last, so a completed turn never resets to empty.
    readonly property color timerCycle2: root._c("timerCycle2")
    readonly property color timerCycle3: root._c("timerCycle3")
    readonly property color timerCycle4: root._c("timerCycle4")
    readonly property var timerCycle: [root.timerRun, root.timerCycle2, root.timerCycle3, root.timerCycle4]
    // The notes module. A note's named text colours -- `<span style="color:
    // red">` is drawn in THIS red, Catppuccin Latte in light and Mocha in
    // dark, so a coloured word never glares after a theme switch --, the
    // ==highlighter==, inline code, and the eight note tints: a note's colour
    // fills its tile and, while it is open, the whole popup surface.
    readonly property color mdRed: root._c("mdRed")
    readonly property color mdOrange: root._c("mdOrange")
    readonly property color mdYellow: root._c("mdYellow")
    readonly property color mdGreen: root._c("mdGreen")
    readonly property color mdTeal: root._c("mdTeal")
    readonly property color mdBlue: root._c("mdBlue")
    readonly property color mdPurple: root._c("mdPurple")
    readonly property color mdPink: root._c("mdPink")
    readonly property color mdGray: root._c("mdGray")
    readonly property color mdMark: root._c("mdMark")
    readonly property color mdCode: root._c("mdCode")
    readonly property color noteRed: root._c("noteRed")
    readonly property color noteOrange: root._c("noteOrange")
    readonly property color noteYellow: root._c("noteYellow")
    readonly property color noteGreen: root._c("noteGreen")
    readonly property color noteTeal: root._c("noteTeal")
    readonly property color noteBlue: root._c("noteBlue")
    readonly property color notePurple: root._c("notePurple")
    readonly property color notePink: root._c("notePink")
    readonly property color buttonPlateau: root._c("buttonPlateau")
    readonly property color buttonPlateauHover: root._c("buttonPlateauHover")
    readonly property color buttonBevel: root._c("buttonBevel")
    readonly property color buttonShadow: root._c("buttonShadow")
    readonly property color ballShadow: root._c("ballShadow")
    // THE SHELL'S EDGE (GooeyField; shell.jsonc "shadow" / "border"). The ring just outside the surface is the waybar's: a line DARKER
    // than the surface in the light theme (border) and LIGHTER in the dark one (buttonBevel -- `border` is the dark theme's carved-inset
    // edge, darker than the surface, the wrong way round for a rim that has to stand out from a dark window). The shadow falls in the
    // ball's colour. Both are aliases and can part from them: a theme that wants waybar's own #454963 says it here.
    readonly property color shellBorder: root._c("shellBorder")
    readonly property color shellShadow: root._c("shellShadow")
    readonly property color terminalBg: root._c("terminalBg")
    readonly property color terminalFg: root._c("terminalFg")
    readonly property color terminalSelection: root._c("terminalSelection")
    readonly property color terminalSelectionText: root._c("terminalSelectionText")

    // The terminal's 16-colour ANSI palette, one token each. It is the palette
    // kept for kitty (~/.config/kitty/themes/eva*.conf) and yay colours most
    // of its output with it, so a themed shell that left it behind would show
    // a dark terminal writing in light-theme ink.
    readonly property color ansiBlack: root._c("ansiBlack")
    readonly property color ansiRed: root._c("ansiRed")
    readonly property color ansiGreen: root._c("ansiGreen")
    readonly property color ansiYellow: root._c("ansiYellow")
    readonly property color ansiBlue: root._c("ansiBlue")
    readonly property color ansiMagenta: root._c("ansiMagenta")
    readonly property color ansiCyan: root._c("ansiCyan")
    readonly property color ansiWhite: root._c("ansiWhite")
    readonly property color ansiBrightBlack: root._c("ansiBrightBlack")
    readonly property color ansiBrightRed: root._c("ansiBrightRed")
    readonly property color ansiBrightGreen: root._c("ansiBrightGreen")
    readonly property color ansiBrightYellow: root._c("ansiBrightYellow")
    readonly property color ansiBrightBlue: root._c("ansiBrightBlue")
    readonly property color ansiBrightMagenta: root._c("ansiBrightMagenta")
    readonly property color ansiBrightCyan: root._c("ansiBrightCyan")
    readonly property color ansiBrightWhite: root._c("ansiBrightWhite")

    // The two arrays TerminalBackend indexes with an SGR code. Built from the
    // tokens above, so they crossfade with everything else.
    readonly property var ansi: [root.ansiBlack, root.ansiRed, root.ansiGreen, root.ansiYellow,
                                 root.ansiBlue, root.ansiMagenta, root.ansiCyan, root.ansiWhite]
    readonly property var ansiBright: [root.ansiBrightBlack, root.ansiBrightRed, root.ansiBrightGreen,
                                       root.ansiBrightYellow, root.ansiBrightBlue, root.ansiBrightMagenta,
                                       root.ansiBrightCyan, root.ansiBrightWhite]

    // The theme file's `common` block (non-colour values shared by both modes),
    // exposed raw. Nothing consumes it yet, but dropping it silently would make
    // a hand-written theme lie about what it sets.
    readonly property var common: root._common

    // ---- L0: the shipped defaults -----------------------------------------
    // eva-light, exactly as the components declare them:
    //   surface..errorTint, cat*, button*, accentBevel, headerBox*
    //     -> SystemUpdatePopup.qml
    //   ballShadow            -> PhaseRail.qml ballShadowColor
    //   terminalBg/terminalFg -> TerminalView.qml root colour / defaultFg
    //   terminalSelection*    -> TerminalView.qml selection colours
    //   ansi*                 -> TerminalBackend.qml ansi / ansiBright, which
    //     are the evalight kitty palette verbatim (color0..color15)
    //   shadowDeep/textOnAccent have no single declaration; they are the values
    //     the popup repeats inline (#AAADB4 as the deepest inset, #EAEDF5 as
    //     the text laid on the accent).
    readonly property var defaults: ({
        "surface": "#EAEDF5",
        "panelSunk": "#E1E4EB",
        "bevel": "#EEF0F7",
        "border": "#CED1D7",
        "shadowDeep": "#AAADB4",
        "listBox": "#E6E9F0",
        "headerBox": "#DCDFE6",
        "headerBoxBevel": "#EEF0F7",
        "headerBoxShadow": "#AAADB4",
        "textPrimary": "#5D5D5F",
        "textMuted": "#6F6F72",
        "textFaint": "#8A8A8C",
        "accent": "#4480F4",
        "accentHover": "#4D91F8",
        "accentBevel": "#8DB3F8",
        "textOnAccent": "#EAEDF5",
        "ok": "#44C145",
        "warn": "#FF6D12",
        "spill": "#D69A00",
        "error": "#EC0000",
        "errorStrong": "#F14C4C",
        "errorTint": "#FDE4E7",
        "catCore": "#FF6D12",
        "catExtra": "#44C145",
        "catMultilib": "#00BEC4",
        "catAur": "#4480F4",
        "catFlatpak": "#C838C6",
        "hyprBorderLocked": "@catFlatpak",
        "llmCode": "#8839EF",
        "llmSystem": "#FE640B",
        "llmExplain": "#40A02B",
        "llmWrite": "#EA76CB",
        "llmData": "#04A5E5",
        "llmOther": "#DD7878",
        "weatherSun": "#DF8E1D",
        "weatherCloud": "#7C8AA6",
        "weatherRain": "#1E66F5",
        "weatherSnow": "#04A5E5",
        "weatherStorm": "#8839EF",
        "weatherFog": "#9CA0B0",
        "weatherNight": "#7287FD",
        "weatherSunDisc": "#FFC634",
        "weatherSunCrown": "#F7931E",
        "weatherMoon": "#F5AE3A",
        "weatherStar": "#FFC634",
        "weatherCloudFront": "#FCFDFF",
        "weatherCloudBack": "#B7BDC9",
        "weatherDrop": "#3D8FF2",
        "weatherFlake": "#36BCE6",
        "weatherHail": "#86CFEA",
        "weatherBolt": "#FFAA1F",
        "weatherFogBar": "#A5ADBC",
        "weatherWindLine": "#8D9BB0",
        "weatherGlyphShade": "#8A8F99",
        "netShell": "#C6CAD3",
        "netShellDark": "#9EA3AD",
        "netContact": "#D6A93C",
        "netLampOff": "#B9BDC6",
        "netLampLink": "@ok",
        "netLampAct": "@accent",
        "netLampWarn": "@warn",
        "netPcb": "#2E6B4F",
        "netTrace": "#C9A227",
        "netBrass": "#C8A04A",
        "netBezel": "#B4B9C2",
        "netLegend": "@textFaint",
        "netGlyphShade": "#8A8F99",
        "netRim": "#FFFFFF",
        "netShade": "#7E838D",
        "batteryCharge": "@ok",
        "batteryDrain": "@spill",
        "batteryLow": "@error",
        "batteryIdle": "@accent",
        "stockGain": "@ok",
        "stockLoss": "@error",
        "stockBuy": "@accent",
        "stockSell": "@warn",
        "profileQuiet": "@ok",
        "profileBalanced": "@accent",
        "profilePerformance": "@warn",
        "profileTweak": "#C838C6",
        "gpuIntegrated": "@ok",
        "gpuSmart": "#00BEC4",
        "gpuHybrid": "@accent",
        "gpuDgpu": "@warn",
        "siliconEvaSurface": "@surface",
        "siliconEvaBevel": "#FFFFFF",
        "siliconEvaShadow": "#A0A6B4",
        "siliconEvaGroove": "#D0D4E0",
        "siliconEvaInk": "#6F7587",
        "siliconEvaSunk": "#D6DAE5",
        "siliconEvaWell": "#D0D4E0",
        "siliconEvaMetal": "#C4C9D6",
        "siliconBlueprintPaper": "#F5F8FD",
        "siliconBlueprintInk": "#1F4FA6",
        "siliconBlueprintFaint": "#9EB5DE",
        "siliconBlueprintGrid": "#DAE4F4",
        "siliconBlueprintWash": "#E6EDF8",
        "siliconEvaWindow": "#262A35",
        "siliconEvaGhost": "#3B4150",
        "siliconEvaBezel": "#9CA3B5",
        "siliconBlueprintWindow": "#13224A",
        "siliconBlueprintGhost": "#2E4880",
        "siliconBlueprintBezel": "#E6EDF8",
        "siliconEvaGlass": "#C2C9D6",
        "siliconBlueprintGlass": "#BEC8DA",
        "siliconLock": "@warn",
        "siliconGold": "#D6A93C",
        "siliconMemory": "#EA76CB",
        "siliconRibbonFilm": "#DBC9A0",
        "siliconRibbonCopper": "#B58F6A",
        "siliconEvaLatch": "@siliconEvaWindow",
        "siliconBlueprintLatch": "@siliconBlueprintWindow",
        "aerialPcb": "#3F6E4A",
        "aerialShield": "#C9CED6",
        "aerialSolder": "#B58F6A",
        "aerialPaper": "#F4F5F7",
        "aerialGold": "#D6A93C",
        "aerialCoaxMain": "#2B2D33",
        "aerialCoaxAux": "#8A8F99",
        "aerialChromeSky": "#F3F6FB",
        "aerialChromeBase": "#D0D6E0",
        "aerialChromeDeep": "#A9B1BE",
        "aerialChromeEtch": "#3A3E47",
        "aerialLabelInk": "#2B2D33",
        "aerialLabelLip": "#FFFFFF",
        "bandGood": "#00BEC4",
        "bandFair": "#44C145",
        "bandModerate": "#D69A00",
        "bandPoor": "#FF6D12",
        "bandVeryPoor": "#EC0000",
        "bandExtreme": "#C838C6",
        "timerRun": "#00BEC4",
        "timerFocus": "#FF6D12",
        "timerBreak": "#F2A374",
        "timerCycle2": "#C838C6",
        "timerCycle3": "#D69A00",
        "timerCycle4": "#44C145",
        "mdRed": "#D20F39",
        "mdOrange": "#FE640B",
        "mdYellow": "#DF8E1D",
        "mdGreen": "#40A02B",
        "mdTeal": "#179299",
        "mdBlue": "#1E66F5",
        "mdPurple": "#8839EF",
        "mdPink": "#EA76CB",
        "mdGray": "#7C7F93",
        "mdMark": "#F2E2A6",
        "mdCode": "#DCDFE6",
        "noteRed": "#E6C9D7",
        "noteOrange": "#EDD7D0",
        "noteYellow": "#E8DED2",
        "noteGreen": "#CFE1D5",
        "noteTeal": "#C8DEE6",
        "noteBlue": "#C9D7F5",
        "notePurple": "#DAD0F4",
        "notePink": "#EADAEE",
        "buttonPlateau": "#EAEDF5",
        "buttonPlateauHover": "#F2F4F9",
        "buttonBevel": "#FFFFFF",
        "buttonShadow": "#AAADB4",
        "ballShadow": "#2A2C31",
        "shellBorder": "@border",
        "shellShadow": "@ballShadow",
        "terminalBg": "#E1E4EB",
        "terminalFg": "#5D5D5F",
        "terminalSelection": "#A4BEE6",
        "terminalSelectionText": "#5D5D5F",
        "ansiBlack": "#5D5D5F",
        "ansiRed": "#F14C4C",
        "ansiGreen": "#48D148",
        "ansiYellow": "#FF6D12",
        "ansiBlue": "#4D91F8",
        "ansiMagenta": "#EF8ED8",
        "ansiCyan": "#00D6DE",
        "ansiWhite": "#5D5D5F",
        "ansiBrightBlack": "#424242",
        "ansiBrightRed": "#EC0000",
        "ansiBrightGreen": "#44C145",
        "ansiBrightYellow": "#F0AA0B",
        "ansiBrightBlue": "#4480F4",
        "ansiBrightMagenta": "#C838C6",
        "ansiBrightCyan": "#00BEC4",
        "ansiBrightWhite": "#888888"
    })

    readonly property var tokenNames: Object.keys(root.defaults)

    // Panel property names -> token names. The popup's existing property names
    // are the vocabulary the control panel already speaks; mapping them here
    // means the panel never has to know a token was renamed.
    readonly property var aliases: ({
        "surfaceColor": "surface",
        "panelColor": "panelSunk",
        "bevelColor": "bevel",
        "borderColor": "border",
        "listBoxColor": "listBox",
        "headerBoxColor": "headerBox",
        "headerBoxBevelColor": "headerBoxBevel",
        "headerBoxShadowColor": "headerBoxShadow",
        "primaryText": "textPrimary",
        "mutedText": "textMuted",
        "faintText": "textFaint",
        "warnStrongColor": "warn",
        "okColor": "ok",
        "errColor": "error",
        "errStrongColor": "errorStrong",
        "errTint": "errorTint",
        "repoCoreColor": "catCore",
        "repoExtraColor": "catExtra",
        "repoMultilibColor": "catMultilib",
        "aurCategoryColor": "catAur",
        "flatpakColor": "catFlatpak",
        "catCodeColor": "llmCode",
        "catSystemColor": "llmSystem",
        "catExplainColor": "llmExplain",
        "catWriteColor": "llmWrite",
        "catDataColor": "llmData",
        "catOtherColor": "llmOther",
        "promptButtonColor": "buttonPlateau",
        "promptButtonHoverColor": "buttonPlateauHover",
        "promptButtonBevelColor": "buttonBevel",
        "promptButtonShadowColor": "buttonShadow",
        "promptAccentBevelColor": "accentBevel",
        "ballShadowColor": "ballShadow"
    })

    // ---- Internal state ----------------------------------------------------
    property var _pairs: []
    property string _themeName: ""
    property string _mode: "light"
    property bool _ready: false
    property string _lastError: ""
    property bool _switching: false

    // The crossfade's single clock, and its two endpoints. Both hold
    // token -> [r,g,b,a] in 0..1 floats: pre-split so a frame costs one array
    // read per token rather than a colour parse per token.
    property real _mix: 1
    property var _fromC: root._parseAll(root.defaults)
    property var _toC: root._parseAll(root.defaults)

    // The theme file exactly as parsed, so a write preserves keys we do not
    // know about (assets, ansi, a future mode) instead of rewriting the file
    // down to the tokens this build happens to declare.
    property var _themeDoc: null
    property var _common: ({})
    // The file the theme above was read from, and the view that read it (see _viewFor).
    property string _themePath: ""
    property var _themeView: null

    // Set true once the state file has told us what to load, so a late theme
    // discovery does not overwrite an explicit choice with pairs[0].
    property bool _stateLoaded: false
    property bool _stateDirReady: false
    // The exact text we last handed to the theme FileView. The watcher fires on
    // our own write; without this the echo would re-parse (harmless) and, worse,
    // a slow echo arriving mid-drag would clobber what the user is typing.
    property string _selfWriteText: ""
    property bool _loadingTheme: false
    property bool _started: false

    // ---- Public functions --------------------------------------------------

    function toggleMode() {
        root.setMode(root._mode === "dark" ? "light" : "dark");
    }

    function setMode(m) {
        root.setPair(root.announcedName, m);
    }

    function setTheme(name) {
        if (name)
            root.setPair(name, root.announcedMode);
    }

    // A pair and a mode as ONE switch: the theme popup's card, and what setMode and setTheme are. Two calls in a row would be two crossfades, and under
    // `deferSwitches` each kept the half it did not name from the shell as it stands, so the second lost the first's. The half a call does not name is what the
    // shell is ABOUT to be (`announcedName` / `announcedMode`).
    function setPair(name, m) {
        if (m !== "light" && m !== "dark") {
            root._lastError = "Unknown mode \"" + m + "\"; expected \"light\" or \"dark\".";
            return;
        }
        if (name && root._pairs.length > 0 && root._pairs.indexOf(name) < 0) {
            root._lastError = "No theme named \"" + name + "\" in " + root.homeThemesDir + " or " + root.repoThemesDir + ".";
            return;
        }
        if (root.deferSwitches) {
            if (name === root.announcedName && m === root.announcedMode)
                return;
            root._deferred = name === root._themeName && m === root._mode ? null : { mode: m, theme: name };
            root._scheduleStateWrite();
            return;
        }
        if (name === root._themeName && m === root._mode)
            return;
        root._mode = m;
        if (name !== root._themeName) {
            root._themeName = name;
            root._readThemeFile();
        }
        root._apply(true);
        root._scheduleStateWrite();
    }

    // A pair's file as text, whichever pair is in force (the user's copy first, as _readThemeFile), "" when there is none. Its views stay and watch their files, so a
    // later call hands back what the disk holds. Never from a binding: the first call for a path makes a view.
    function pairText(name) {
        const dirs = [root.homeThemesDir, root.repoThemesDir];
        for (let i = 0; i < dirs.length; i++) {
            const txt = root._viewFor(dirs[i] + "/" + name + ".json").text();
            if (txt && txt.length > 0)
                return txt;
        }
        return "";
    }
    // One mode of such a document as resolved colours: token -> "#AARRGGBB" for `keys`; null when the document has no such block. Data, not tokens: nothing here
    // follows the theme, which is what lets a card show a pair that is not in force.
    function resolvedColors(doc, mode, keys) {
        const block = doc && doc[mode] && typeof doc[mode] === "object" ? doc[mode] : null;
        if (!block)
            return null;
        const common = doc.common && typeof doc.common === "object" ? doc.common : ({});
        const r = Resolve.resolveAll(root.defaults, common, block, root.tokenKey);
        const hex = v => (v < 16 ? "0" : "") + v.toString(16);
        const out = {};
        for (let i = 0; i < keys.length; i++) {
            const c = r.values[keys[i]];
            out[keys[i]] = c ? "#" + hex(c[3]) + hex(c[0]) + hex(c[1]) + hex(c[2]) : "#ff000000";
        }
        return out;
    }

    // The pairs on disk again: a theme added while the shell runs (`ls` only ran at the start, nothing watches the directories).
    function rescanPairs() {
        if (lsHomeProc.running || lsRepoProc.running)
            return;
        root._ls = ({});
        lsHomeProc.running = true;
        lsRepoProc.running = true;
    }

    // Aliases resolve too, so the panel can ask with the popup's own property
    // name and never has to carry the mapping table itself.
    function tokenKey(alias) {
        if (root.defaults.hasOwnProperty(alias))
            return alias;
        if (root.aliases.hasOwnProperty(alias))
            return root.aliases[alias];
        return alias;
    }

    function hasToken(key) {
        return root.defaults.hasOwnProperty(root.tokenKey(key));
    }

    // The colour on screen right now — mid-fade it is the interpolated value.
    function tokenOf(key) {
        const k = root.tokenKey(key);
        if (!root.defaults.hasOwnProperty(k)) {
            console.warn("[Theme] tokenOf: unknown token", key);
            return root._c("textPrimary");
        }
        return root._c(k);
    }

    // The colour as the active theme+mode has it written down (or the code
    // default where the file is silent). Never animated: this is what the
    // panel's hex field shows and compares a `*` mark against.
    function baseOf(key) {
        const k = root.tokenKey(key);
        if (!root.defaults.hasOwnProperty(k)) {
            console.warn("[Theme] baseOf: unknown token", key);
            return root._c("textPrimary");
        }
        const c = Resolve.resolveOne(k, root.defaults, root._common, root._block(root._mode), root.tokenKey, null);
        return c ? Qt.rgba(c[0] / 255, c[1] / 255, c[2] / 255, c[3] / 255) : Qt.rgba(0, 0, 0, 1);
    }

    // A live edit of the active theme+mode: in memory now, on disk in ~200ms.
    // It writes the theme file's value for THIS mode, so it survives the next
    // mode switch instead of being a session-only tweak.
    function setToken(key, hex) {
        const k = root.tokenKey(key);
        if (!root.defaults.hasOwnProperty(k)) {
            root._lastError = "Cannot set unknown token \"" + key + "\".";
            return false;
        }
        if (!root._parseHex(hex)) {
            root._lastError = "\"" + hex + "\" is not a #RRGGBB colour.";
            return false;
        }

        // A `property var` mutated in place notifies nothing: rebuild and
        // reassign, every level.
        const doc = root._themeDoc ? JSON.parse(JSON.stringify(root._themeDoc)) : {
            "name": root._themeName
        };
        const block = Object.assign({}, doc[root._mode] || {});
        block[k] = String(hex);
        doc[root._mode] = block;
        root._themeDoc = doc;

        // Instant, even mid-fade: a colour you are dragging must not lag the
        // pointer by 420ms.
        root._apply(false);
        root._scheduleThemeWrite();
        return true;
    }

    // ---- The other mode's colours ------------------------------------------
    // "What does this colour become when the mode flips?" Asked by a surface
    // that bakes colours INTO a document (CodeBlock) so it can bake the other
    // mode's copy at rest and swap it in when the switch comes, instead of
    // paying the bake inside the switch. `token` is the one the asker's
    // colour defaults to: if the colour is still that token's, the answer is
    // that token's other value. Otherwise the colour is looked up by value,
    // so an override that is some other token still maps and a literal maps
    // to itself. The hint matters because values COLLIDE: in eva's light
    // mode ansiBrightMagenta is also catFlatpak, ansiBlue is accent and
    // ansiBrightCyan is catMultilib (measured), and each pair
    // parts in the dark. The by-value fallback takes the first token with
    // that value; the asker checks its guess by key at the switch and bakes
    // if it was wrong, so a collision costs time, never correctness.
    property var _altC: ({})
    property var _altMap: ({})
    function counterpart(hex, token) {
        if (token !== undefined) {
            const c = root._toC[token];
            const a = root._altC[token];
            if (c && a && Qt.rgba(c[0], c[1], c[2], c[3]).toString() === hex)
                return Qt.rgba(a[0], a[1], a[2], a[3]).toString();
        }
        const v = root._altMap[hex];
        return v === undefined ? hex : v;
    }
    function _counterparts(cur, alt) {
        const m = {};
        const names = root.tokenNames;
        for (let i = 0; i < names.length; i++) {
            const c = cur[names[i]];
            const a = alt[names[i]];
            if (!c || !a)
                continue;
            const h = Qt.rgba(c[0], c[1], c[2], c[3]).toString();
            if (m[h] === undefined)
                m[h] = Qt.rgba(a[0], a[1], a[2], a[3]).toString();
        }
        return m;
    }

    // ONE IDLE BAKE PER FRAME, across every surface of every window. Work
    // done "at rest" -- a document baked ahead for the other mode -- is only
    // free if it is alone in its frame: the history's blocks all come to rest
    // at the same moment, and nine bakes in one pass would be the freeze the
    // rest was meant to avoid. A surface claims the frame before it bakes and
    // tries again a frame later if someone else has it.
    property real _idleSlotAt: 0
    function claimIdleSlot() {
        const now = Date.now();
        if (now - root._idleSlotAt < 16)
            return false;
        root._idleSlotAt = now;
        return true;
    }

    // ---- Colour maths ------------------------------------------------------

    function _c(k) {
        const f = root._fromC[k];
        const t = root._toC[k];
        if (!f || !t)
            return Qt.rgba(0, 0, 0, 1);
        const m = root._mix;
        if (m >= 1)
            return Qt.rgba(t[0], t[1], t[2], t[3]);
        if (m <= 0)
            return Qt.rgba(f[0], f[1], f[2], f[3]);
        return Qt.rgba(f[0] + (t[0] - f[0]) * m, f[1] + (t[1] - f[1]) * m, f[2] + (t[2] - f[2]) * m, f[3] + (t[3] - f[3]) * m);
    }

    // Hand-parsed rather than handed to Qt: an unparseable string assigned to a
    // color property is how a shell ends up magenta, and here a bad value must
    // fall through to the code default instead. The parsing is ThemeResolve.js's
    // (one reader of a theme's colours); this only turns 0..255 into 0..1. It
    // accepts a plain string or a QML color (which stringifies to #rrggbb), so the
    // panel may hand back whatever its hex field produced.
    function _parseHex(s) {
        const c = Resolve.parseColor(typeof s === "string" ? s : String(s));
        return c ? [c[0] / 255, c[1] / 255, c[2] / 255, c[3] / 255] : null;
    }

    function _parseAll(map) {
        const out = {};
        const names = Object.keys(root.defaults);
        for (let i = 0; i < names.length; i++) {
            const k = names[i];
            out[k] = root._parseHex(map[k]) || [0, 0, 0, 1];
        }
        return out;
    }

    // ---- Resolving a theme -------------------------------------------------

    // The resolver is ThemeResolve.js -- the other copy of tools/theme/themectl's, held to the same answers token by token by
    // tools/dev/themectl_resolver_parity.sh. L0 (`defaults` above) < the theme's `common` < the mode's block; "@name" is an alias,
    // "@name lighten|darken|alpha n" a recipe, a cycle or a bad value an error that falls back to L0.
    function _block(mode) {
        const doc = root._themeDoc;
        return doc && typeof doc === "object" && doc[mode] && typeof doc[mode] === "object" ? doc[mode] : null;
    }

    // The declared tokens of one mode as token -> [r,g,b,a] in 0..1 floats, and the sentences for whatever failed.
    function _resolveMode(mode) {
        const r = Resolve.resolveAll(root.defaults, root._common, root._block(mode), root.tokenKey);
        const out = {};
        const names = root.tokenNames;
        for (let i = 0; i < names.length; i++) {
            const c = r.values[names[i]];
            out[names[i]] = c ? [c[0] / 255, c[1] / 255, c[2] / 255, c[3] / 255] : [0, 0, 0, 1];
        }
        return { colors: out, errors: Object.keys(r.errors).map(k => r.errors[k]) };
    }

    // Rebuild both endpoints from the current theme+mode.
    // `animate` false is the initial load, an external file edit and every
    // setToken: the shell opens already in its theme, so only an explicit
    // toggleMode/setMode/setTheme is allowed to cross-fade.
    function _apply(animate) {
        const res = root._resolveMode(root._mode);
        const errs = res.errors;
        const next = res.colors;
        root._altC = root._resolveMode(root._mode === "dark" ? "light" : "dark").colors;
        root._altMap = root._counterparts(next, root._altC);

        if (animate && root.fadeMs > 0 && root._hosts.length > 0) {
            // The hosted path: nothing moves until EVERY host has its picture.
            // A switch that lands mid-crossfade replaces the pending palette;
            // the picture on screen is still the truth of what was shown.
            root._pendingC = next;
            root._hosted = true;
            root._snapMix = 0;                // the picture is opaque until committed
            root._switching = true;
            root._awaitList = root._hosts.slice();
            _hostFallback.restart();          // armed before the ask: a host that answers at once commits inside it
            root.aboutToSwitch();
        } else if (animate && root.fadeMs > 0) {
            root._hosted = false;
            snapAnim.stop();
            root._fromC = root._snapshot();   // continue from what is on screen
            root._toC = next;
            root._mix = 0;
            root._switching = true;
            fadeAnim.restart();
        } else {
            fadeAnim.stop();
            snapAnim.stop();
            root._hosted = false;
            root._pendingC = null;
            root._fromC = next;
            root._toC = next;
            root._mix = 1;
            root._switching = false;
            root.settled();
        }

        // The missing-mode-block complaint belongs here, not in the parse: it is
        // a fact about theme+MODE, so it must be re-decided on every switch.
        if (root._themeDoc && !root._themeDoc[root._mode])
            errs.push("Theme \"" + root._themeName + "\" has no \"" + root._mode + "\" block; using the shipped defaults for it.");

        if (errs.length > 0)
            root._lastError = errs.join(" ");
        else if (root._themeDoc)
            root._lastError = "";
    }

    // The colours actually on screen, so interrupting a fade does not snap.
    function _snapshot() {
        const out = {};
        const names = root.tokenNames;
        const m = root._mix;
        for (let i = 0; i < names.length; i++) {
            const k = names[i];
            const f = root._fromC[k];
            const t = root._toC[k];
            if (!f || !t) {
                out[k] = t || f || [0, 0, 0, 1];
                continue;
            }
            out[k] = [f[0] + (t[0] - f[0]) * m, f[1] + (t[1] - f[1]) * m, f[2] + (t[2] - f[2]) * m, f[3] + (t[3] - f[3]) * m];
        }
        return out;
    }

    NumberAnimation {
        id: fadeAnim
        target: root
        property: "_mix"
        from: 0
        to: 1
        duration: root.fadeMs
        easing.type: root.fadeEasing
        onFinished: {
            root._switching = false;
            root.settled();
        }
    }

    // ---- Files -------------------------------------------------------------

    // blockLoading makes text() a synchronous read, which is the only way to
    // have the right colours in the FIRST painted frame: a singleton is
    // constructed BY the first binding that reads it, so FileView.onLoaded is
    // always one frame too late.
    // One FileView per theme FILE, with a path that is set once and never changed: a FileView loads synchronously on its first
    // path and NOT on later ones (assign a second path and text() hands back the previous file's bytes -- CLAUDE.md), so a switch
    // of pair, or a second place to look in, is another view and never a repointed one. The registry is an object mutated in
    // place on purpose: nothing binds to it.
    property var _views: ({})
    Component {
        id: themeViewComp
        FileView {
            id: view
            blockLoading: true
            atomicWrites: true
            printErrors: false
            watchChanges: true
            onFileChanged: view.reload()
            onTextChanged: root._onThemeViewText(view)
        }
    }
    function _viewFor(path) {
        let v = root._views[path];
        if (!v) {
            v = themeViewComp.createObject(root, { "path": path });
            root._views[path] = v;
        }
        return v;
    }
    function _onThemeViewText(view) {
        if (view === root._themeView) {
            root._onThemeText(view.text());
            return;
        }
        // Not the file in use. One case matters: the user's copy appears while the repo's is in use (`themectl install` with the
        // shell running): from then on it is the file, so a Save lands where themectl and the lock read.
        if (root._loadingTheme || !root._themeName || !root._themeView || root._themePath === view.path)
            return;
        const t = view.text();
        if (t && t.length > 0 && view.path === root.homeThemesDir + "/" + root._themeName + ".json") {
            root._readThemeFile();
            root._apply(false);
        }
    }

    FileView {
        id: stateFile
        blockLoading: true
        atomicWrites: true
        printErrors: false
        watchChanges: true
        onFileChanged: stateFile.reload()
        onTextChanged: root._onStateText(stateFile.text())
    }

    function _readThemeFile() {
        if (!root._themeName) {
            root._themeDoc = null;
            root._common = ({});
            root._themeView = null;
            root._themePath = "";
            root._ready = false;
            return;
        }
        // A new view fires its text signal synchronously, as it is made; without
        // this flag that would apply the new theme instantly and the animated
        // _apply() the caller is about to run would then fade from the new
        // colours to themselves — a switch with no visible crossfade.
        root._loadingTheme = true;
        const file = root._themeName + ".json";
        let view = root._viewFor(root.homeThemesDir + "/" + file);
        let txt = view.text();
        if (!txt || txt.length === 0) {
            view = root._viewFor(root.repoThemesDir + "/" + file);
            txt = view.text();
        }
        root._themeView = view;
        root._themePath = view.path;
        root._ingestTheme(txt, false);
        root._loadingTheme = false;
    }

    function _onThemeText(txt) {
        if (root._loadingTheme)
            return;
        // FileView reads are not atomic: an editor mid-save shows up as an empty
        // or truncated read. Never clobber a loaded theme with nothing.
        if (!txt || txt.length === 0)
            return;
        // Our own write coming back through the watcher, or a stale echo landing
        // while the user is still dragging: either way, ignore it.
        if (txt === root._selfWriteText)
            return;
        if (themeWriteTimer.running)
            return;
        root._ingestTheme(txt, true);
    }

    // `reapply` is false during the synchronous startup read, where _apply()
    // runs once afterwards; true for a live file edit, which must land now.
    function _ingestTheme(txt, reapply) {
        if (!txt || txt.length === 0) {
            root._themeDoc = null;
            root._common = ({});
            root._ready = false;
            root._lastError = "Theme file " + root._themePath + " is missing or empty; using the shipped defaults.";
            if (reapply)
                root._apply(false);
            return;
        }
        let doc = null;
        try {
            doc = JSON.parse(txt);
        } catch (e) {
            // Never clobber a good theme with a broken one: a half-written file
            // is a normal thing to see from an editor mid-save.
            root._lastError = "Theme file " + root._themePath + " is not valid JSON (" + e + "); keeping the colours already loaded.";
            return;
        }
        if (!doc || typeof doc !== "object") {
            root._lastError = "Theme file " + root._themePath + " is not a JSON object; keeping the colours already loaded.";
            return;
        }
        root._themeDoc = doc;
        root._common = (doc.common && typeof doc.common === "object") ? doc.common : ({});
        root._ready = true;
        root._lastError = "";
        if (reapply)
            root._apply(false);
    }

    function _onStateText(txt) {
        if (!txt || txt.length === 0)
            return;
        // Our own write coming back. The watcher hands it over a moment after the write, and by then the
        // mode may have moved on (a double click on the theme button): that is not somebody else's switch.
        if (root._selfStateTexts.indexOf(txt) >= 0)
            return;
        let obj = null;
        try {
            obj = JSON.parse(txt);
        } catch (e) {
            root._lastError = "State file " + root.statePath + " is not valid JSON (" + e + ").";
            return;
        }
        if (!obj || typeof obj !== "object")
            return;

        root._stateLoaded = true;
        root._stateDirReady = true;      // the file exists, so the directory does

        const m = (obj.mode === "dark" || obj.mode === "light") ? obj.mode : root._mode;
        const n = (typeof obj.theme === "string" && obj.theme.length > 0) ? obj.theme : root._themeName;
        if (root.deferSwitches) {
            root._deferred = m === root._mode && n === root._themeName ? null : { mode: m, theme: n };
            return;
        }
        if (m === root._mode && n === root._themeName)
            return;

        root._mode = m;
        if (n !== root._themeName) {
            root._themeName = n;
            root._readThemeFile();
        }
        // An external state change is somebody else's switch (themectl, another
        // app). Animate it like our own, so the desktop moves together.
        root._apply(root._started);
    }

    // ---- Writes ------------------------------------------------------------
    // Debounced so dragging a colour is one write, and atomic (FileView's
    // temp-then-rename) so no reader ever sees a truncated file.

    Timer {
        id: themeWriteTimer
        interval: 200
        onTriggered: root._flushThemeWrite()
    }

    function _scheduleThemeWrite() {
        themeWriteTimer.restart();
    }

    // A live edit is written to the file the theme was READ from: the user's copy once there is one, the repo's until then. With
    // no file at all (a theme made by its first edit) it is created in the user's directory.
    function _flushThemeWrite() {
        if (!root._themeName || !root._themeDoc) {
            root._lastError = "No theme file to write to: create " + root.homeThemesDir + "/<name>.json first.";
            return;
        }
        const txt = JSON.stringify(root._themeDoc, null, 2) + "\n";
        root._selfWriteText = txt;
        const view = root._themeView ? root._themeView : root._viewFor(root.homeThemesDir + "/" + root._themeName + ".json");
        if (!root._themeView) {
            root._themeView = view;
            root._themePath = view.path;
        }
        view.setText(txt);
    }

    Timer {
        id: stateWriteTimer
        interval: 150
        onTriggered: root._flushStateWrite()
    }

    function _scheduleStateWrite() {
        stateWriteTimer.restart();
    }

    function _flushStateWrite() {
        if (!root._stateDirReady) {
            // mkdir is still in flight; come back rather than writing into a
            // directory that does not exist yet.
            stateWriteTimer.restart();
            return;
        }
        stateFile.path = root.statePath;
        const txt = JSON.stringify({
            "theme": root._deferred ? root._deferred.theme : root._themeName,
            "mode": root._deferred ? root._deferred.mode : root._mode
        }, null, 2) + "\n";
        root._selfStateTexts = root._selfStateTexts.concat([txt]);
        selfStateExpiry.restart();
        stateFile.setText(txt);
    }

    // The state texts this shell wrote lately (see _onStateText); forgotten after the echoes are long past.
    property var _selfStateTexts: []
    Timer {
        id: selfStateExpiry
        interval: 3000
        onTriggered: root._selfStateTexts = []
    }

    // ---- Discovery ---------------------------------------------------------

    Process {
        id: mkdirProc
        command: ["mkdir", "-p", root.stateDir]
        stdout: StdioCollector {}
        stderr: StdioCollector {}
    }
    Connections {
        target: mkdirProc
        // A Connections handler rather than an inline onExited: qmllint cannot
        // see QProcess::ExitStatus and warns on every inline one.
        function onExited() {
            root._stateDirReady = true;
        }
    }

    // The pairs are the names in the user's directory and in the repo's, once each. (A directory that does not exist lists nothing.)
    Process {
        id: lsHomeProc
        command: ["ls", "-1", root.homeThemesDir]
        stdout: StdioCollector {
            id: lsHomeOut
        }
        stderr: StdioCollector {}
    }
    Process {
        id: lsRepoProc
        command: ["ls", "-1", root.repoThemesDir]
        stdout: StdioCollector {
            id: lsRepoOut
        }
        stderr: StdioCollector {}
    }
    Connections {
        target: lsHomeProc
        function onExited() {
            root._lsDone("home", lsHomeOut.text);
        }
    }
    Connections {
        target: lsRepoProc
        function onExited() {
            root._lsDone("repo", lsRepoOut.text);
        }
    }
    property var _ls: ({})
    function _lsDone(which, text) {
        const m = Object.assign({}, root._ls);
        m[which] = text || "";
        root._ls = m;
        if (m.home !== undefined && m.repo !== undefined)
            root._onPairs(m.home + "\n" + m.repo);
    }

    function _onPairs(txt) {
        const found = [];
        const lines = (txt || "").split("\n");
        for (let i = 0; i < lines.length; i++) {
            const l = lines[i].trim();
            if (l.length > 5 && l.substring(l.length - 5) === ".json" && found.indexOf(l.substring(0, l.length - 5)) < 0)
                found.push(l.substring(0, l.length - 5));
        }
        found.sort();
        if (found.join("\n") !== root._pairs.join("\n"))
            root._pairs = found;

        if (found.length === 0) {
            root._lastError = "No themes in " + root.homeThemesDir + " or " + root.repoThemesDir + "; using the shipped defaults.";
            return;
        }
        // Adopt the first pair when the state file does not name a theme that
        // actually exists. Testing `!_stateLoaded` alone is not enough: the
        // state file is written before any theme exists (it records the mode
        // from the very first launch), so it comes back naming "" -- an
        // explicit choice by that test, and the shell would then sit on the
        // shipped defaults with a theme on disk it never loaded. The same branch
        // recovers a state file naming a theme that has since been renamed.
        if (!root._themeName || found.indexOf(root._themeName) < 0) {
            if (root._themeName)
                root._lastError = "No theme named \"" + root._themeName + "\" in "
                    + root.homeThemesDir + " or " + root.repoThemesDir + "; using " + found[0] + ".";
            root._themeName = found[0];
            root._readThemeFile();
            root._apply(false);
            root._scheduleStateWrite();
        }
    }

    // ---- Startup -----------------------------------------------------------
    // Everything that decides the first painted frame happens here, not in a
    // FileView handler.
    Component.onCompleted: {
        stateFile.path = root.statePath;
        root._onStateText(stateFile.text());
        if (root._themeName)
            root._readThemeFile();
        root._apply(false);
        root._started = true;

        mkdirProc.running = true;
        lsHomeProc.running = true;
        lsRepoProc.running = true;
    }
}
