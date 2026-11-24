pragma ComponentBehavior: Bound

import QtQuick

import "../common/components"

// =============================================================================
// SiliconBarOwner.qml -- silicon's bar-side owner (CONTRACT.md section 9; StocksBarOwner is the model).
//
// The engine builds a popup's content when it opens and tears it down when it closes, so what must
// outlive the popup lives here: the service (the facts, the targets, the intents -- SiliconService
// on the real machine, a SiliconMock in a mockup or a probe) and the wiring between it, the bar's
// button and thePopup. This item has no visual of its own.
//
//   THE HOST (the bar's assembly, or a mockup) places a SiliconBarButton in its bar, sets the two
//   facts only the bar knows (`vertical`, `barRotation`), and hands the button here as `anchorItem`.
//   It does NOT wire the button further: this owner binds every fact the button draws, its `active`
//   flag (a fact it keeps and draws nothing for), its `clicked` and its event pulse, so a host that also wired `onClicked` would toggle the
//   popup twice.
//
//   toggle() / open() / close()   from the button's click (wired here), a shortcut or a probe
//
// WHAT IT WIRES
//   the button's facts   percent, charging, plugged, limitOn, limitPercent, profile, tweaked,
//                        gpuMode, gpuInUse, muxPending, gpuKnown: the machine as it IS (the service's facts,
//                        never its targets). A write that is refused animates the popup's scene
//                        back and the bar never changed, so the bar cannot show a state the
//                        machine was not in. `gpuMode` is the scene's STEP order (0 Integrated,
//                        1 Smart, 2 Hybrid, 3 dGPU-only), which the service already maps from
//                        cardwire's own numbers and the MUX wiring. `gpuKnown` is false until cardwire and
//                        the helper have both answered (the step is only a fallback then): the GPU's glyph is not
//                        drawn and does not move until it is true, and the first mode snaps in.
//   `active`             the popup is open and ours (the button keeps the fact and wears no plate for it)
//   `vm.popupOpen`       the same fact for the service: its pollers' cadence follows the popup
//   the event pulse      the service's `batteryEvent(kind)` -> `button.pulse(kind)`
//   the popup            engine.open(...) with a component of SiliconPopup (vm, family, secondarySide,
//                        renderScale, shown, and the `fontFamily` a mockup dresses it in); the engine's
//                        secondary contract is the popup's own
//
// THE SERVICE. A mockup or a probe hands its own in (`service`: a SiliconMock). The bar leaves it null
// and the owner runs a SiliconService of its own, loaded BY URL so the owner and the bar still load
// when the data layer cannot -- which is also why the host's root file has to import
// modules/silicon/data (Quickshell registers a directory's types only when something imports it).
// THE REAL SERVICE CALLS pkexec AND THE REAL HELPER: no test, render or mockup may leave `service` null.
//
// SHELL-HOSTED (`shellHosted`, docs/contracts/shell.md section 4). The shell mounts one owner per screen over
// ONE service, so the owner builds none (a hosted owner NEVER starts a SiliconService, whatever `service` is: it
// calls pkexec and the real helper), writes no property of it (`sharedFlags.popupOpen` is what it would have
// written: the host ORs the screens' and writes the service) and holds neither once-per-shell watcher -- the
// SiliconMuxWatcher (it puts up the keep prompt toast due at login) and the BlockedAppNotifier
// belong to the host, which makes one of each. `prewarmArmed` is the one thing every window needs of its own: pipelines
// link per window, at their first draw, so the host arms the prewarm on every screen's window (default: only an
// owner that runs the real service). Not hosted, the owner builds its own service as above.
//
// THE LOOK. `family` is the config's `look.family` ("material" 0, "blueprint" 1; the old spelling "eva" still reads as material) unless the host hands a
// `familyOverride` (0 / 1; the mockup's panel does), which wins. It is read live: a config edit or a
// panel switch reaches an open popup.
//
// WHERE THE SECONDARY OPENS (it depends heavily on the composition of the final shell assembly).
// ONE setting for every secondary the popup opens -- the CPU tuning and GPU
// panels, the restart card and the busy-dGPU question: `secondarySide`, the engine's side for a
// child, "far" (away from the bar) | "start" | "end" (along it). It is the config's `look.secondarySide` (default
// "far") unless the host hands a `secondarySideOverride` (the mockup's panel does), which wins; read live like the
// family.
//
// HOW LARGE (DeploymentNotes.md 136: "the silicon popup can be made bigger ... let it scale freely"). The user's size is shell.jsonc's
// `scale.popups.silicon` (1.35 by default), the engine's ratio for this popup; `sizeScale` (0.5 .. 2, default 1) is the module's own
// constant ON TOP of it, tuned in the silicon mockup: the popup draws itself that much larger or smaller (PopupStage), asks the engine for that much more room, and makes its layers at the
// scale it is drawn at. At 1 the popup is drawn at that ratio alone, to the pixel. Read live.
// =============================================================================
Item {
    id: barOwner

    property var engine: null                 // GooeyEngine
    property var bar: null                    // GooeyBar
    property string barId: ""
    property string ownerId: "silicon"
    property Item anchorItem: null            // the SiliconBarButton the popup hangs from

    // ---- the shell (CONTRACT section 4) --------------------------------------
    property bool shellHosted: false
    readonly property var sharedFlags: ({
            popupOpen: barOwner.popupMine
        })
    // Draw the popup once at idle in this window (SiliconPrewarm). Default: only the owner of the real service
    // (a mockup or a probe must not pay or hide that compile in a gate). The shell does not set it: the engine's prewarm
    // (ShellFrame.prewarmEntries) draws silicon's popup in every window, through the clip layer too, and a second prewarm would buy nothing.
    property bool prewarmArmed: barOwner.ownsService

    // ---- the service: injected, else our own --------------------------------
    property var service: null
    readonly property var svc: barOwner.service ?? ownService.item
    // True when this owner runs the real service (nothing was injected, and the shell did not host it).
    readonly property bool ownsService: barOwner.service === null && !barOwner.shellHosted

    // By URL: the owner (and the bar) still load when the service cannot.
    Loader {
        id: ownService
        active: barOwner.service === null && !barOwner.shellHosted
        source: barOwner.service === null && !barOwner.shellHosted ? Qt.resolvedUrl("data/SiliconService.qml") : ""
    }

    // ---- the popup ----------------------------------------------------------
    readonly property bool popupMine: !!barOwner.engine && barOwner.engine.popupOpen
                                      && barOwner.engine.popupOwnerId === barOwner.ownerId
    // The popup's clock runs only while this holds: ours, on its way in or out and showing.
    readonly property bool popupShown: barOwner.popupMine && !!barOwner.engine.thePopup
                                       && barOwner.engine.thePopup.contentOpacity > 0

    // How far the popup has come out, 0..1, for the entrance: its body's clock while it opens,
    // then its content's presence while it is open or moving.
    readonly property real openProgress: {
        const b = barOwner.popupMine ? barOwner.engine.thePopup : null;
        if (!b)
            return 0;
        if (b.phase === "opening")
            return Math.max(0, Math.min(1, b.t));
        return b.phase === "open" || b.phase === "moving" ? Math.max(0, Math.min(1, b.contentOpacity)) : 0;
    }

    // Which ends of the popup (where it will REST: its target box) lie against a perpendicular bar's face -- { start, end }, the left and
    // right ends of a popup hanging from a top or bottom bar. The dialogs use it to open out of that corner (SiliconPopup.flushEnds).
    readonly property var popupFlushEnds: {
        const r = { start: false, end: false };
        const eng = barOwner.engine;
        const P = barOwner.popupMine && eng ? eng.thePopup : null;
        const tb = P ? P.toBox : null;
        if (!tb || (P.edge !== "top" && P.edge !== "bottom"))
            return r;
        const tol = 1.5;
        // the bar must stand beside the popup's FOOT, where the dialog opens (the edge away from its own bar)
        const footY = P.edge === "top" ? tb.y1 : tb.y0;
        for (const b of eng.barsList) {
            if (!b || footY < b.absY || footY > b.absY + b.absH)
                continue;
            if (b.edge === "right" && Math.abs(tb.x1 - b.absX) <= tol)
                r.end = true;
            else if (b.edge === "left" && Math.abs(tb.x0 - (b.absX + b.absW)) <= tol)
                r.start = true;
        }
        return r;
    }

    // The face the popup's text is set in: Inter, the module default (a mockup dresses it in Audiowide).
    property string fontFamily: "Inter"

    // Where the popup's secondaries open: "" follows silicon.jsonc's look.secondarySide, "far" | "start" | "end" wins over it.
    property string secondarySideOverride: ""
    readonly property string _configSide: {
        const c = barOwner.svc ? barOwner.svc.config : null;
        const v = c && c.look ? c.look.secondarySide : "";
        return v === "start" || v === "end" ? v : "far";
    }
    readonly property string secondarySide: barOwner.secondarySideOverride === "far" || barOwner.secondarySideOverride === "start" || barOwner.secondarySideOverride === "end"
        ? barOwner.secondarySideOverride : barOwner._configSide

    // How large the popup is drawn on top of its popup ratio (shell.jsonc `scale.popups.silicon`, the size the user picks): a constant of
    // the module, 0.5 .. 2, tuned in the silicon mockup; 1 draws it at that ratio.
    property real sizeScale: 1

    // The board's family: -1 follows silicon.jsonc, 0 / 1 (Material, Blueprint) wins over it.
    property int familyOverride: -1
    readonly property int _configFamily: {
        const c = barOwner.svc ? barOwner.svc.config : null;
        return c && c.look && c.look.family === "blueprint" ? 1 : 0;
    }
    readonly property int family: barOwner.familyOverride >= 0 ? Math.min(1, barOwner.familyOverride) : barOwner._configFamily

    // A device pixel of the popup's layers: the engine's renderScale, DEVICE px per design px (the shell's configured scale; a mockup's
    // stage zoom). Not times the attached Screen's ratio: the shell's frame already absorbs the window's.
    readonly property real renderScale: barOwner.engine && barOwner.engine.renderScale > 0 ? barOwner.engine.renderScale : 1

    readonly property Component popupComponent: Component {
        SiliconPopup {
            vm: barOwner.svc
            family: barOwner.family
            secondarySide: barOwner.secondarySide
            sizeScale: barOwner.sizeScale
            renderScale: barOwner.renderScale
            flushEnds: barOwner.popupFlushEnds
            defaultWidthFrom: barOwner.engine ? barOwner.engine.childWidthFrom : 0.5
            shown: barOwner.popupShown
            fontFamily: barOwner.fontFamily
            openProgress: barOwner.openProgress
            entranceEnabled: true
        }
    }

    // ---- the button's facts ---------------------------------------------------
    // One record, built from the service's facts; each Binding below reads one field of it.
    readonly property var button: barOwner.anchorItem
    readonly property var _facts: {
        const s = barOwner.svc;
        const b = s ? s.battery : null;
        const g = s ? s.gpu : null;
        const c = s ? s.cpu : null;
        return {
            percent: b ? b.pct : 0,
            charging: !!b && b.status === "Charging",
            plugged: !!b && b.ac === true,
            limitOn: !!b && b.limitOn === true,
            // the track is scaled to this while the limit is on (and to 100 with it off)
            limitPercent: b && b.limitOn === true ? b.limitPct : 80,
            profile: s ? s.profileIndex : 1,
            tweaked: !!c && c.tweaked === true,
            cpuLoad: c && typeof c.loadPct === "number" ? Math.max(0, Math.min(1, c.loadPct / 100)) : 0,
            gpuMode: s ? s.gpuMode : 2,
            gpuInUse: !!g && g.inUse === true,
            // the mode is a fact once cardwire and the helper have answered (Model: gpu.known); a service that says nothing is known
            gpuKnown: !g || g.known !== false,
            muxPending: !!g && !!g.mux && g.mux.pending === true
        };
    }
    readonly property bool _wired: !!barOwner.button && !!barOwner.svc

    Binding {
        target: barOwner.button
        property: "percent"
        value: barOwner._facts.percent
        when: barOwner._wired
    }
    Binding {
        target: barOwner.button
        property: "charging"
        value: barOwner._facts.charging
        when: barOwner._wired
    }
    Binding {
        target: barOwner.button
        property: "plugged"
        value: barOwner._facts.plugged
        when: barOwner._wired
    }
    Binding {
        target: barOwner.button
        property: "limitOn"
        value: barOwner._facts.limitOn
        when: barOwner._wired
    }
    Binding {
        target: barOwner.button
        property: "limitPercent"
        value: barOwner._facts.limitPercent
        when: barOwner._wired
    }
    Binding {
        target: barOwner.button
        property: "lowAt"
        value: barOwner.svc && barOwner.svc.config ? barOwner.svc.config.battery.lowAt : 15
        when: barOwner._wired
    }
    Binding {
        target: barOwner.button
        property: "profile"
        value: barOwner._facts.profile
        when: barOwner._wired
    }
    Binding {
        target: barOwner.button
        property: "cpuLoad"
        value: barOwner._facts.cpuLoad
        when: barOwner._wired
    }
    Binding {
        target: barOwner.button
        property: "tweaked"
        value: barOwner._facts.tweaked
        when: barOwner._wired
    }
    Binding {
        target: barOwner.button
        property: "gpuMode"
        value: barOwner._facts.gpuMode
        when: barOwner._wired
    }
    Binding {
        target: barOwner.button
        property: "gpuInUse"
        value: barOwner._facts.gpuInUse
        when: barOwner._wired
    }
    Binding {
        target: barOwner.button
        property: "muxPending"
        value: barOwner._facts.muxPending
        when: barOwner._wired
    }
    // AFTER gpuMode / gpuInUse / muxPending (declaration order): the GPU's glyph is told the mode is known only once it holds it
    Binding {
        target: barOwner.button
        property: "gpuKnown"
        value: barOwner._facts.gpuKnown
        when: barOwner._wired
    }
    Binding {
        target: barOwner.button
        property: "active"
        value: barOwner.popupMine
        when: !!barOwner.button
    }

    // Hover intent: the pointer has rested on the button, so the content is built now, parked, for the click that follows (GooeyEngine.prebuild: the click
    // then adopts it and builds nothing).
    HoverIntent {
        target: barOwner.anchorItem
        enabled: barOwner._wired
        armed: !!barOwner.engine && !barOwner.popupMine
        onIntent: barOwner.engine.prebuild(barOwner.ownerId, barOwner.popupComponent, { parked: true })
    }

    // The service's cadence follows the popup: open polls the stats, closed halts them.
    Binding {
        target: barOwner.svc
        property: "popupOpen"
        value: barOwner.popupMine
        when: !barOwner.shellHosted && !!barOwner.svc
    }

    Connections {
        target: barOwner.button
        ignoreUnknownSignals: true
        function onClicked() {
            barOwner.toggle();
        }
    }

    // A battery event plays one simple coloured pulse on the button.
    Connections {
        target: barOwner.svc
        ignoreUnknownSignals: true
        function onBatteryEvent(kind: string) {
            if (barOwner.button)
                barOwner.button.pulse(kind);
        }
    }

    // The popup's types and shaders, built and drawn once at idle (SiliconPrewarm: the first open's
    // first frame takes 13-35 ms instead of 115-640 ms, for a one-time ~0.5 s freeze of the bar's own frames 6 s after start). For an owner of
    // the real service outside the shell (the Live mockup): a mockup or a probe hands in its own service and must not pay or hide
    // that compile in a gate, and the shell's windows are warmed by the engine instead (see prewarmArmed).
    SiliconPrewarm {
        parent: barOwner.anchorItem
        armed: barOwner._wired && barOwner.prewarmArmed
        sizeScale: barOwner.sizeScale
    }

    // The MUX's moments that come without the popup, and Smart's blocked apps. Once per SHELL,
    // not per screen: hosted, the host makes one of each, so a second screen would show the keep prompt and the notice twice.
    Loader {
        id: muxWatcherLoader
        active: !barOwner.shellHosted
        sourceComponent: Component {
            SiliconMuxWatcher {
                vm: barOwner.svc
            }
        }
    }
    // The mock never reboots: the mockup's "restart the shell" re-runs the watcher's startup look.
    readonly property var muxWatcher: muxWatcherLoader.item
    Loader {
        id: blockedNotifierLoader
        active: !barOwner.shellHosted
        sourceComponent: Component {
            BlockedAppNotifier {
                vm: barOwner.svc
            }
        }
    }

    function toggle() {
        if (barOwner.popupMine)
            barOwner.close();
        else
            barOwner.open();
    }

    // Nothing opens without a service: the popup is built from it, and a data layer that did not
    // load leaves the bar button as it is (the default facts) rather than a popup with no vm.
    function open() {
        if (!barOwner.engine || !barOwner.bar || !barOwner.anchorItem || !barOwner.svc || barOwner.popupMine)
            return;
        // Read at the moment of opening, not bound: a mapToItem in a binding does not track the
        // layout that moved it.
        const centre = barOwner.anchorItem.mapToItem(barOwner.bar, barOwner.anchorItem.width / 2, barOwner.anchorItem.height / 2).x;
        barOwner.engine.open(barOwner.ownerId, barOwner.barId, centre, null, null, false, barOwner.popupComponent, 1);
    }

    function close() {
        if (barOwner.popupMine)
            barOwner.engine.close();
    }
}
