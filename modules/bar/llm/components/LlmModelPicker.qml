pragma ComponentBehavior: Bound

import QtQuick
import "../../../common/theme"
import "../../../common/components"
import "../../../common/components/Mix.js" as Mix
import "../../../common/scroll"

// =============================================================================
// LlmModelPicker.qml
//
// Which model is answering, and the list to change it.
//
// The closed state is a pill because that is all the fact deserves: a name and
// what the thing can do. THE CAPABILITY MARKS ARE DOTS, NOT GLYPHS, AND EVERY
// DOT HAS A NAME: three fixed slots (vision, tools, thinking, in that order), a
// filled dot in the capability's own colour when the model has it, an empty
// ring when it does not -- an absent capability is a visible absence, not a
// shorter row -- and every slot carries a HoverTip that says its word. The
// colours are catExtra / catAur / catFlatpak, each a property the host can
// override.
//
// THE BAR UNDER THE DOTS IS A VRAM BAR, and it answers the one question an
// 8 GB card makes urgent: how much of the CARD is this model sitting on right
// now. Not how much of the model is resident: that would draw a bar for every
// model /api/ps has ever mentioned, including ones holding no VRAM at all.
//
// THE SELECTED MODEL ALWAYS HAS ONE, loaded or not. "Will this fit on the
// card?" is a question asked BEFORE the model is loaded, and a bar gated on the
// footprint alone answers it by drawing nothing -- pick a cold model and the
// row goes blank, which reads as a broken row, not as an answer. So the
// selected row keeps an EMPTY bar (the track, no fill) with a tip that says it
// is not loaded, and it fills in under the pointer as the model loads
// (`service.vramLive`, below). Every other row has a bar only while it holds
// VRAM or is resident (see "WHO GETS A BAR" below).
//
// AND THE CHANGE IS A GESTURE, NOT A FRAME. The bar grows from the left when
// it appears and retreats to the left when it goes, and when the selection
// moves from one model to another the old bar's exit and the new bar's
// entrance are SEQUENTIAL halves of ONE easing curve -- see `_swapU`. The
// dots above the bar ride the same clock, sliding to the position the bar
// leaves them rather than jumping 5 px.
//
// SPILL IS A COLOUR. `/api/ps` gives the model's total footprint and the part
// of it on the GPU; the difference is running in system RAM, which is the "too
// big for 8 GB, so it crawls" case. When the service reports it, the whole bar
// turns deep yellow (`Theme.spill`) and the tip gains the RAM row. It is the
// same bar saying a different thing, not a second mark.
//
// LIVE WHILE OPEN. Opening the list sets `service.vramLive`, which drops the
// service's /api/ps + nvidia-smi throttle to about a second, and a timer here
// re-asks `vramInfo` on `liveRefreshMs`; closing it clears the flag. A closed
// pill costs the service nothing.
//
// TWO FILLS IN ONE BAR. The model's `size_vram` is not the card's usage: the
// compute graph, the display server and whatever else is running sit on the
// card too, and btop shows that figure while a model-only bar would not. Both
// are true, so the bar carries two fills from the left: the CARD's used share
// as the longer, lighter one, and the MODEL's share as the shorter, full-accent
// one drawn on top of it. Every end is a capsule -- rounded within the bar's
// own height, never a ball wider than the line. The model's fill is never
// longer than the card's (the model is part of the card's use), and when the
// two would end within `minStepPx` of each other the CARD's fill is extended
// so the step stays a step; the model's fill is never shortened below its
// truth. See `vramSlot.cardW` for the number.
//
// IT IS NOT A RESIDENCY MARK. `loaded` means "in /api/ps right now", and that
// is TRUE for a model running entirely on the CPU: a real load then reports
// `size_vram` 0 while nvidia-smi is perfectly healthy. A fill gated on
// `loaded` would draw a bar for a model occupying nothing of the card, and
// because the fill has a floor (a dot as tall as the bar) it would be a
// VISIBLE one, captioned "0.0/8.0 GiB · 0%". So the gate on the FILLS is the
// FOOTPRINT: `vramBytes > 0` with a known card total. Nothing on the card, no
// fill on the row -- and the zero is excluded before the floor can round it up
// into a mark. Whether the ROW carries a bar at all is the selection's and the
// residency's business (a resident model keeps its bar with no fill in it, see
// "WHO GETS A BAR" below, so the unload gesture is never out of reach), and
// whether that bar has anything IN it is the footprint's.
//
// It is fed by the service's `vramInfo(model)` (loaded / vramBytes /
// totalBytes / fraction, usedBytes / usedFraction for the card, ramBytes /
// ramFraction / spilling) and re-asked on `vramInfoChanged`, on a new /api/ps
// map, every time the list opens, and on `liveRefreshMs` while it is open. No
// service, or no GPU total, means the share of the card is unknowable, and an
// unknowable ratio is not drawn.
//
// WHY THE DROP-DOWN LIVES IN THE HOST'S OVERLAY. Qt Quick prunes POINTER
// DELIVERY at ancestor bounds: the list paints above the transcript, but a
// click on a row is delivered to the transcript under it -- painting outside
// bounds works, input outside bounds does not. So while `overlayItem` is set,
// the drop-down and its dismiss layer are reparented into that layer -- an
// Item filling the popup's root, above everything, inside nothing -- and
// positioned by mapping the pill's origin into it when the list opens. The
// pill cannot move while the list is open (the composer's foot is anchored to
// the popup's), so mapping once is enough. With `overlayItem: null` (a bare
// harness) everything stays parented here, which reproduces the pruned shape
// -- fine for a pill-sized world, wrong inside a popup.
//
// The list opens UPWARD and right-aligned (`y` up, `x` left from the pill's
// right edge): the pill sits at the bottom-right of the popup, so the list
// grows away from both edges it is near. The pill's implicitWidth/Height are
// what the composer's control row lays out; the drop-down never touches them.
//
// PICKING A MODEL DOES NOT DISMISS IT. The list is where models are compared,
// so it stays up until the user is done with it, and it is dismissed the four
// ways a menu is: a click outside (the full-bleed MouseArea one z below it),
// the pill again (that same area covers the pill), Escape (a window-context
// Shortcut, live only while the list is open), and going back to typing in the
// prompt (the composer writes `open = false` on the first keystroke, without
// swallowing it). It carries no wheel handler of its own, so the transcript's
// scrolling is never stolen -- only the list takes the wheel, and only over
// itself. The list scrolls with NO scroll bar -- the rows take the full width
// -- and the wheel and the edges are the shell's ONE answer, ScrollDressing,
// a SIBLING of the Flickable (a child would be reparented into `contentItem`
// and scroll away with the rows): 120 px a notch, and a fade at whichever end
// still has content past it. The dressing takes no input, so a row is still
// clicked and hovered THROUGH it, and it sits below the swipe capture in z --
// which is what keeps the MouseArea first in delivery: the horizontal gesture
// is read before the vertical scroll ever sees the event.
//
// BRAND TABS. Twelve models in one column is a list to scroll, not a list to
// read, so a pill selector ABOVE the list -- the Manual|Auto toggle's sibling,
// one tab per BRAND -- filters it. A brand is the leading word of the model's
// name (`brandOf`: "gemma4:12b" and "gemma5:2b" are both gemma,
// "ornith-1.5:35b" is ornith, "muse-glimmer:30b" is muse), the tabs are
// alphabetical, and the tab shown when the list opens is the CURRENT model's
// brand. One brand is not a choice, so with fewer than two the band is not
// there and the list is the whole list. The rule under the tabs is the SAME
// rule that sits above the Manual|Auto row -- one component, `Divider`, one
// gap of `_gap` above and below it -- and the drop-down grows to fit its tabs
// if a machine has more brands than the list is wide.
//
// THE TABS SWIPE, THE UPDATE POPUP'S WAY. A two-finger horizontal swipe
// anywhere on the drop-down steps the brand, through SystemUpdatePopup's
// mechanism: a MouseArea over everything, first in delivery, taking no
// buttons and accepting nothing, that feeds the horizontal delta into the
// selector's `applySwipe` and treats a zero-delta wheel (libinput's scroll-
// end) as the fingers lifting, with an idle timer for the mice that never
// send one. And its HOLD CONTRACT: switching to a brand with fewer models
// shrinks the drop-down, which grows UPWARD from the pill, so the capture
// area's top edge would move down out from under the pointer and the
// gesture would die halfway. While a gesture is live the area is therefore
// held at the height of the TALLEST brand's list (`gestureHoldHeight`),
// anchored to the drop-down's foot -- the edge that does not move -- and it
// shrinks back when the fingers lift. The update's gesture is inline in its
// popup, entangled with its terminal ownership and diagnostics, so this is
// the same shape written a second time rather than an extraction.
//
// WHAT EACH MODEL IS FOR. Hovering a row opens the model's NOTES from
// LlmModelNotes to the LEFT of the drop-down, never over the list: the
// strengths as short lines, the caveats fainter, and the compare sentence
// last, at a fixed width so twelve tips are one shape. A model the registry
// has nothing on gets no tip.
//
// THE TOOLS DOT IS A CLAIM OR A MEASUREMENT. The server's `tools` capability
// is derived from the chat template -- a claim, not a test -- and the service
// PROBES it once per model (one tiny calculator call after the model's first
// finished answer, cached by digest). So the tools slot has four states: no
// claim = the empty ring; declared but unproven = a hollow RING in the
// capability's own colour; proven = the filled dot; failed the probe = the
// ring in `spill`, the colour this list already uses for "it runs, but not the
// way you hoped". The verdicts arrive as `toolProof` (model → { state, ms,
// why }), and the tip says the word and the figure: `tool calling  proven ·
// 0.9 s`.
//
// THE BOX CHANGES SIZE ON A CLOCK. Choosing a brand with a different number of
// models changes the drop-down's height over the composer's ease -- 260 ms
// OutCubic, `resizeMs` -- and it is ONE value: the LIST's height
// (`_animListH`), which the box's height is a sum of. Never a `Behavior on
// height` on the box itself: the list is anchored to the box's TOP, which is
// the edge that MOVES (`y` is derived from `height`, so the FOOT stays pinned
// to the pill), so a box easing while the list jumped would paint up to 152 px
// of rows and the ctx rule BELOW its own foot, with the ctx row 196 px adrift
// from the rule that names it -- and this box cannot clip its way out, because
// a ShadowBox deliberately paints outside its rect and a clip would eat the
// bevel and the drop shadow. With one clock every consumer follows for free:
// the tabs ride the moving top edge, so the content shifts with it; the ctx
// rule and row stay glued to the list's foot and the box's.
//
// TWO THINGS DELIBERATELY DO NOT FOLLOW IT. `_holdH` keeps its own un-eased
// formula -- it is the swipe's hold contract, and a capture area that eased
// would shrink out from under a live gesture, which is the whole reason it
// exists. And a HoverTip maps its anchor ONCE, when it opens (HoverTip.qml),
// while the rows travel with the top edge. A BRAND switch rebuilds every row
// and takes its tips down with it, but a resize that KEEPS the rows -- the
// host's `maxListHeight` changing under an open list -- leaves a tip hanging
// where its row was (for one frame, and only because the hover then breaks by
// itself). So every tip anchored in a ROW -- the notes, the capability dots,
// the VRAM bar -- is shut while the box is moving and comes back on its own
// delay once it has settled. The ctx row's tips are NOT gated: that row is
// pinned to the foot, which does not move.
//
// A REPEATER'S MODEL MAY NEVER CONTAIN A THEMED COLOUR. The capability dots'
// `model:` is an array compared BY VALUE, so a Theme token in it would make
// every frame of the theme's 420 ms crossfade a real model change, and
// `QQuickRepeater::setModel` REGENERATES EVERY DELEGATE. Measured over one
// switch with the colours in the rows: `_capSlots` ran 462 times and the two
// live CapDots sites (the pill and every row) emitted 342 model changes --
// about a thousand Item + Rectangle + HoverHandler + HoverTip trees destroyed
// and rebuilt inside the fade, which ran at 24 fps; with them out, the popup's
// fade stall falls from 249 ms to 93 ms. So `_capSlots` returns FACTS -- kind,
// has, filled, state, tip -- and the DELEGATE resolves them into colours
// (`_capFill`, `_capRing`), which is a colour write like every other themed
// Rectangle in the shell. On five rows and the pill, one light->dark switch
// costs 330 evaluations and 330 model changes with one colour in the model,
// ZERO of either with none.
//
// AND A SLOT IS MEASURED IN THE FACE IT IS DRAWN IN. `advanceWidth()` is a
// METHOD: a binding that only calls it captures no dependency and keeps its
// first answer for ever -- see `_advance`, which every measured width in this
// file goes through.
//
// THE DEFAULT MODEL IS THE SAME MARK, DRAINED. Right-clicking a row tags it as
// the module's default (`service.setDefaultModel`, toggled off by
// right-clicking it again); the service decides what to do with it -- this
// file only says which row it is. The mark is the SELECTION's stripe, in two
// dimensions of one object: `_markF` is its presence (default OR selected)
// and `_selF` its colour (drained -> full accent). The drained colour is the
// SYSTEM UPDATE's own recipe, not a lookalike -- UpdatePackageRow's
// `mutedSaturation` / `mutedLightnessMix`: the accent's hue,
// `stripeMutedSaturation` of its saturation, and a lightness a fixed fraction
// (`stripeMutedLightnessMix`) of the way from THE GROUND IT LIES ON toward
// mid-grey, so it drains in both themes instead of glowing on the dark one.
// The recipe is a copy of UpdatePackageRow's rather than a shared helper: if
// one of the two numbers is tuned, extract it.
// A row that is both the default and the selection shows the ACCENT stripe
// and nothing else: two coloured marks for one row is what the design
// language forbids, so when the default IS the selection the mark says only
// "selected".
//
// MoE OR DENSE, BETWEEN THE CONTEXT AND THE QUANTISATION. Why a 35 B answers
// at 40 tok/s and a 31 B at 3 is whether it is a mixture of experts, and that
// is a fact the SERVER reports (`<arch>.expert_count` in /api/show), not a
// guess from the name -- gemma4:26b is a mixture and gemma4:31b is not. The
// service owns it (`moeOf(model)`); this file asks for it per model, in its
// own fixed slot, and leaves the slot EMPTY until the answer arrives, so
// nothing after it ever moves. There is no signal for that arrival in the
// service's API, so it is re-asked exactly where the card is: when `models`
// changes (the same /api/show reply updates the entry), when the list opens,
// and on the list's own live tick while it is open -- and the map is only
// replaced when the answer actually changed.
//
// RIGHT-CLICK THE VRAM BAR TO UNLOAD. The bar is where residency is read, so
// it is where residency is given back, and it asks for THAT ROW's model
// (`unloadNow(id)`) -- the bar is about that model. The gesture is silent: no
// tip, no glyph, no flash -- the answer is the fills disappearing within one
// `liveRefreshMs` tick and, on a row that then keeps no bar, the whole bar
// retreating to the left through `_swapU`. Both gates are the service's: it
// refuses while anything is generating, being titled, probed or tuned, and it
// refuses for a model that is not resident, so the selected-but-cold row's
// empty bar is a no-op rather than an eviction of something else. Asking the
// same question here again would be a second answer to it.
//
// Every colour is a property with a `Theme.<token>` default. Nothing here
// animates a colour: hover eases a 0..1 fraction and `Mix.js` blends, because
// the theme is already one clock.
// =============================================================================
Item {
    id: root

    // ======================================================================
    // PUBLIC API
    // ======================================================================

    // LlmBackend.models:
    //   [{ id, family, sizeBytes, quant, paramSize, ctx,
    //      caps: { vision, tools, thinking, audio }, loaded, sizeVram }]
    property var    models: []
    property string current: ""
    // LlmBackend.loaded (/api/ps): { name: { sizeVram, size, ctx, expiresAt } }.
    // The VRAM bar does not READ this -- the service owns that answer --
    // but this map changing IS the moment residency changed, and it usually
    // lands before the service has re-polled, so it is what tells the picker
    // to ask again.
    property var    loaded: ({})
    // The LlmService, for the ctx row pinned under the list: the picker calls
    // `ctxInfo(model)` / `setCtxMode` / `setCtxValue` and listens for
    // `ctxInfoChanged`. The composer forwards it; the POPUP must wire `service` on the composer for the row
    // to appear. Null (or a service without the API): the row simply is not
    // there, which is also what keeps bare harnesses green.
    property var    service: null
    property bool   open: false
    property bool   busy: false
    // The backend knows Ollama does not answer: an empty list then says so
    // rather than "no models". True only for a backend that said offline.
    property bool   offline: false
    property string fontFamily: "Inter"
    property real   maxListHeight: 280
    // The host's floating layer (LlmPopup.overlayItem). REQUIRED in a real
    // host -- see the header. Null falls back to local parenting.
    property Item   overlayItem: null
    // The model notes: anything with the
    //   notesFor(modelId) -> { strengths: [], caveats: [], compare, source } | null
    // shape. LlmModelNotes by default; a host or a probe may hand in its own.
    property var    notes: LlmModelNotes { }
    // The probe verdicts by model id: { state: "none" | "declared"
    // | "proven" | "failed", ms, why }, or just the state word. The composer
    // rebuilds it from `service.toolProbeInfo` on every `toolProbeChanged`.
    // A model missing from the map is unproven.
    property var    toolProof: ({})
    // What the tool definitions cost on the wire (the service's
    // `toolDefinitionTokens`, ~173 tokens each measured) and whether the
    // wrench is on: the context tip names the price when the window is small
    // enough for it to matter.
    property int    toolDefinitionTokens: 0
    property bool   toolsOn: false
    // WHICH MODEL A FRESH MODULE STARTS ON. The service owns the
    // preference (`defaultModel` / `setDefaultModel`, persisted); the picker
    // marks the row and toggles it on a right-click. Bound to the service by
    // default so nothing between here and the popup has to forward it, and
    // still settable by a host or a probe that has no service.
    property string defaultModel: (root.service && root.service.defaultModel !== undefined)
                                  ? String(root.service.defaultModel) : ""
    // ---- The brand swipe (the update popup's numbers) ----
    // Two-finger horizontal swipe anywhere on the drop-down steps the brand.
    property bool swipeToSwitchBrand: true
    // A high-resolution touchpad reports pixelDelta with angleDelta at zero;
    // one notch is 120 angle units, about 48 px of travel.
    property real swipePixelToAngle: 2.5
    // Fallback end-of-gesture for a mouse wheel, which never reports one.
    property int  gestureIdleEndMs: 260
    // Public: a swipe is in flight, and the capture area is held at
    // `gestureHoldHeight` -- the drop-down at its tallest brand -- until it
    // ends. See the header.
    readonly property bool swipeGestureActive: root._gestureActive
    readonly property real gestureHoldHeight: dropdown._holdH

    // ---- Palette ----
    property color surfaceColor: Theme.surface          // ground the pill stands on
    property color fieldColor: Theme.panelSunk          // the drop-down's fill
    property color listBoxColor: Theme.listBox          // what the drop-down lies OVER
    property color headerBoxColor: Theme.headerBox
    property color bevelColor: Theme.bevel
    property color shadowColor: Theme.border
    property color primaryText: Theme.textPrimary
    property color mutedText: Theme.textMuted
    property color faintText: Theme.textFaint
    property color accent: Theme.accent
    property color accentHover: Theme.accentHover
    property color accentBevel: Theme.accentBevel
    property color textOnAccent: Theme.textOnAccent
    property color buttonPlateau: Theme.buttonPlateau
    property color buttonPlateauHover: Theme.buttonPlateauHover
    property color buttonBevel: Theme.buttonBevel
    property color buttonShadow: Theme.buttonShadow
    property color errColor: Theme.error
    // SPILL: the bar's colour when part of the model is running in system RAM
    // instead of on the card. A deep yellow of its own token rather than
    // `warn`, which in this shell is the pacman-core orange and already means
    // "a package category"; two different facts in one hue would read as one.
    property color spillColor: Theme.spill
    // The three capability dots: green sees, blue acts, magenta thinks. Overridable so a themed host stays one material.
    property color capVisionColor: Theme.catExtra
    property color capToolsColor: Theme.catAur
    property color capThinkColor: Theme.catFlatpak
    // The ctx toggle's deep inset -- the same token the update popup's mode
    // selector uses for its track. Theme-defaulted like the chip's code
    // colours; hosts need not forward it.
    property color deepShadowColor: Theme.headerBoxShadow
    // The pill's own height, so a host row can
    // line it up with its buttons without this file inventing a number the
    // host cannot see.
    property real pillHeight: 28
    // How wide the drop-down opens. The pill is short; the list is not.
    property real listWidth: 268
    // ---- Tunables ----
    property real capDotSize: 5          // the dot's ink
    property real capSlotWidth: 12       // its hover slot (the pitch)
    property real capSlotHeight: 20
    property real vramBarHeight: 4
    // THE MINIMUM VISIBLE STEP between the bar's two fills -- see vramSlot.
    property real vramMinStepPx: 6
    property real vramTrackOpacity: 0.22
    property real vramCardOpacity: 0.45
    // How often the bar re-asks the service while the list is open. The
    // service's own fast throttle is ~1 s under `vramLive`, so asking much
    // faster only repeats an answer.
    property int  liveRefreshMs: 1000
    property real rowHeight: 42
    // How long the drop-down takes to change size when a brand with a
    // different number of models is chosen: the shell's resize easing, the
    // composer's own number (LlmComposer.resizeMs). One clock -- see the
    // header.
    property int  resizeMs: 260
    // ---- The default model's mark ----
    // The drain applied to the stripe of a row that is the DEFAULT but not
    // the selection: the system update's own two numbers (UpdatePackageRow's
    // `mutedSaturation` / `mutedLightnessMix`), so the two marks are one mark.
    // The lightness is RELATIVE to the ground the stripe lies on -- one
    // absolute reads drained on a light list and bright on a dark one.
    property real stripeMutedSaturation: 0.22
    property real stripeMutedLightnessMix: 0.4732
    // The presence of the mark (the shell's 160 ms presence fade: on a row
    // that is not selected it is the gesture's only feedback) and its colour
    // travel from drained to full accent (the row's own hover number).
    property int  defaultStripeFadeMs: 160
    property int  stripeSelectFadeMs: 120
    // ---- The spec columns ----
    property int  specFontSize: 10
    property real specColumnGap: 6
    // The MoE / Dense cell between the context and the quantisation. Off
    // compares the row without it.
    property bool showMoeColumn: true
    // ---- The notes tip ----
    // Its content width: fixed, so every model's tip is one shape and the
    // lines wrap at one place. 200 holds a short line whole at 10 px.
    property real notesTipWidth: 200
    // The tip's clearance from the drop-down's edge: the shell's tip gap.
    property real notesTipGap: 6

    signal picked(string modelId)

    // THE DEFAULT ROW'S STRIPE, drained the system update's way:
    // the accent's hue kept, its saturation cut to `stripeMutedSaturation`,
    // and its lightness moved `stripeMutedLightnessMix` of the way from the
    // GROUND (the row's resting fill, which is the drop-down's own) toward
    // mid-grey. Derived, never animated: the theme is one clock, and every
    // term here is a themed colour that crossfades with it.
    readonly property color _faintStripeColor: Qt.hsla(
        root.accent.hslHue, root.stripeMutedSaturation,
        root.fieldColor.hslLightness
            + (0.5 - root.fieldColor.hslLightness) * root.stripeMutedLightnessMix, 1.0)

    // ======================================================================
    // DERIVATIONS
    // ======================================================================
    function _shortName(id) {
        if (!id || id.length === 0)
            return "no model";
        const i = id.lastIndexOf(":");
        return i >= 0 && i < id.length - 1 ? id.substring(i + 1) : id;
    }
    function _entryFor(id) {
        const ms = root.models || [];
        for (let i = 0; i < ms.length; ++i)
            if (ms[i] && ms[i].id === id)
                return ms[i];
        return null;
    }
    function _capsOf(m) { return (m && m.caps) ? m.caps : ({}); }
    // "25.8B" -> 2.58e10, "800M" -> 8e8. The SORT KEY for the list, biggest
    // first: PARAMETERS beat GIGABYTES because quantisation makes disk size
    // lie about capability -- a q4 12B is smaller on disk than a q8 4B and
    // far more capable, so bytes would order the list by compression, not by
    // model. `sizeBytes` is only the fallback for an entry Ollama gave no
    // parameter_size for (mixed-unit, but it still lands big things high).
    // The parse is byte-for-byte LlmBackend.paramCountOf's; it is repeated
    // here because this file receives the `models` ARRAY, never the backend
    // object -- if the plumbing ever carries the backend's function down,
    // defer to it and delete this copy.
    function paramCountOf(m) {
        const s = (typeof m === "string") ? m
                : ((m && m.paramSize) ? m.paramSize : "");
        const r = /^\s*(\d+(?:\.\d+)?)\s*([KMBT])\s*$/i.exec(s);
        if (!r) return (m && Number(m.sizeBytes)) || 0;
        const mul = ({ K: 1e3, M: 1e6, B: 1e9, T: 1e12 });
        return parseFloat(r[1]) * mul[r[2].toUpperCase()];
    }
    readonly property var _sortedModels: {
        const ms = (root.models || []).slice();
        ms.sort((a, b) => root.paramCountOf(b) - root.paramCountOf(a));
        return ms;
    }
    // ---- The brands --------------------------------------------------------
    // A model's BRAND is the leading word of its name: the letters before the
    // first digit, dash or dot of the base name, namespace and tag stripped.
    // "gemma4:12b" and "gemma5:2b" are gemma; "qwen3.8:27b" is qwen;
    // "ornith-1.5:35b" is ornith; "muse-glimmer:30b" is muse. A name that
    // starts with no letter at all is its own brand.
    function brandOf(id) {
        let s = String(id || "").toLowerCase().trim();
        const slash = s.lastIndexOf("/");
        if (slash >= 0) s = s.substring(slash + 1);
        const colon = s.indexOf(":");
        if (colon >= 0) s = s.substring(0, colon);
        const m = /^[a-z]+/.exec(s);
        return m ? m[0] : s;
    }
    // One pass over the sorted list: the brands, alphabetical, and how many
    // models the biggest of them has (what the swipe area is held at).
    readonly property var _brandTable: {
        const ms = root._sortedModels;
        const counts = {};
        for (let i = 0; i < ms.length; ++i) {
            const b = root.brandOf(ms[i] ? ms[i].id : "");
            counts[b] = (counts[b] || 0) + 1;
        }
        const brands = Object.keys(counts).sort();
        let max = 0;
        for (let i = 0; i < brands.length; ++i)
            max = Math.max(max, counts[brands[i]]);
        return { brands: brands, maxCount: max };
    }
    readonly property var  _brands: root._brandTable.brands
    readonly property int  _maxBrandCount: root._brandTable.maxCount
    // One brand is not a choice: the band exists from two.
    readonly property bool _tabsVisible: root._brands.length >= 2
    readonly property var  _brandTabs: root._brands.map(b => ({ id: b, label: b }))
    // The tab the user is on. Set to the CURRENT model's brand every time
    // the list opens, moved by a click or a swipe while it is open, and
    // validated against the brands that exist right now -- a brand that has
    // gone (its last model pulled) falls back to the first.
    property string _brand: ""
    readonly property string _brandShown: root._brands.indexOf(root._brand) >= 0
                                          ? root._brand
                                          : (root._brands.length > 0 ? root._brands[0] : "")
    readonly property var _visibleModels: root._tabsVisible
        ? root._sortedModels.filter(m => root.brandOf(m ? m.id : "") === root._brandShown)
        : root._sortedModels
    // The widest brand label, in the tabs' face: what sizes the drop-down
    // when the tabs need more room than the list. Each slot is that label
    // plus `_tabAir`: the pill's 3 px inset and 5 px of pill either side of
    // the word. MEASURED: at Inter 10 the five installed brands (gemma,
    // granite, muse, ornith, qwen -- "gemma" widest at 36) need 280, at
    // Audiowide 10 ("granite", 41) they need 305, so the box widens past
    // the 268 list to seat them; fewer brands, and the list's own width
    // stands.
    readonly property int  _tabFontSize: 10
    readonly property real _tabAir: 16
    FontMetrics {
        id: tabMetrics
        font.family: root.fontFamily
        font.pixelSize: root._tabFontSize
    }
    // Through `_advance` for the reason the spec slots are: a bare
    // advanceWidth() call in a binding never re-measures after a face change.
    readonly property real _widestBrandW: {
        let m = 0;
        for (let i = 0; i < root._brands.length; ++i)
            m = Math.max(m, root._advance(tabMetrics, root._brands[i]));
        return m;
    }
    // A live swipe (see the header): latched by the first wheel event of a
    // gesture, cleared by the scroll-end event or the idle timer.
    property bool _gestureActive: false

    // 131072 -> "128K". Contexts are always powers of two here, so the round
    // number is the honest one and it fits the 10px slot.
    function _ctxLabel(n) {
        const v = Number(n) || 0;
        if (v <= 0) return "";
        return v >= 1024 ? Math.round(v / 1024) + "K" : String(v);
    }
    // ---- The spec columns' fixed slots -------------------------------------
    // A row's specs are a TABLE: parameters, context, quantisation, each in a
    // slot of its own so the second row's quantisation starts on the same
    // column as the first's, and the FIRST slot starts where the model's name
    // starts. A joined string would put every row's figures somewhere else, and
    // a model with no quantisation would slide the rest left.
    //
    // THE SLOTS ARE MEASURED, NOT COUNTED, and measured from the WIDEST VALUE
    // the column can hold rather than from any row's actual text -- reading a
    // Text's width back into what sizes it is the binding loop this repo has
    // hit before. Referencing `font` is what makes the widths follow a font
    // change.
    //   params  "000.0B"  -- 4 digits and a unit covers 1.5B .. 685.0B
    //   ctx     "0000K"   -- 32K and 128K both START on the column
    //   quant   "Q0_K_M"  -- Ollama's longest common tag
    // A missing value leaves its slot EMPTY; nothing after it moves.
    //
    // EVERY CELL READS FROM THE LEFT of its slot: right-aligned figures would
    // put the first value's left edge somewhere different on every row and hang
    // the group away from the model's name above it.
    //
    // THE CONTEXT COMES BEFORE THE QUANTISATION, and it is the figure alone --
    // "128K" beside a parameter count is a context to anyone reading a model
    // list, and a "ctx" label would repeat on every row. The two capacities
    // (how big, how much it can read) sit together, and the encoding comes
    // after them.
    FontMetrics {
        id: specMetrics
        font.family: root.fontFamily
        font.pixelSize: root.specFontSize
    }
    //
    // AND THE MEASUREMENT FOLLOWS THE FACE. `advanceWidth()` is a
    // METHOD, so a binding that only CALLS it captures no dependency on the
    // metrics' font and keeps its first answer for ever. MEASURED under
    // quickshell: a slot bound at Inter still read 40 px after the face was
    // changed to Audiowide, where a fresh call on the same object answered
    // 50 -- so a host dressed in the display face would lay its figures out
    // in the BODY face's slots and the columns would collide. Every slot therefore takes the metrics' own `font` as an
    // argument: that read is both the dependency and the guarantee that the
    // re-measure happens AFTER the font object itself has changed (a binding
    // on `root.fontFamily` would race the FontMetrics' own). Reading it INSIDE
    // the helper is enough -- a property read during a binding's evaluation is
    // captured wherever it happens -- so every measured slot in this file goes
    // through `_advance` and there is no second way to measure one.
    function _advance(fm, s) {
        void fm.font;                      // THE DEPENDENCY -- see above
        return Math.ceil(fm.advanceWidth(s));
    }
    readonly property real _specParamsW: root._advance(specMetrics, "000.0B")
    readonly property real _specCtxNumW: root._advance(specMetrics, "0000K")
    readonly property real _specQuantW: root._advance(specMetrics, "Q0_K_M")
    //   moe     the wider of its own two words -- it is one or the other
    readonly property real _specMoeW: Math.max(root._advance(specMetrics, "MoE"),
                                               root._advance(specMetrics, "Dense"))
    function _paramsOf(m) { return (m && m.paramSize) ? String(m.paramSize) : ""; }
    function _quantOf(m) { return (m && m.quant) ? String(m.quant) : ""; }
    // The whole table's width, which is what the drop-down has to seat: four
    // slots and the gaps between them (three, or two with the MoE cell off --
    // a Row skips an invisible child's gap as well as its width).
    readonly property real _specTableW: root._specParamsW + root._specCtxNumW + root._specQuantW
        + (root.showMoeColumn ? root._specMoeW + root.specColumnGap : 0)
        + root.specColumnGap * 2

    // ---- MoE or dense ------------------------------------------------------
    // The one fact that explains why a 35 B answers thirteen times faster than
    // a 31 B, and the SERVER's fact rather than a guess from the name: the
    // service reads `<arch>.expert_count` out of the /api/show reply it is
    // already fetching for every model and publishes `moeOf(model)` ->
    // { moe, used, total }, or {} while it does not know yet. Only the WORD is
    // kept here: the spec cells carry no tips to put the expert counts in.
    //
    // WHEN IT IS ASKED. There is no signal for "the show reply landed" in the
    // service's API, so this rides the two cues the picker already has: `models`
    // changing (the same reply that carries the fact rewrites the entry) and
    // the list's own live tick while it is open -- the mechanism for exactly
    // this, a fact that ARRIVES while a human is looking at the list.
    // The map is only replaced when the answer changed, so a tick that learns
    // nothing rebuilds no cell.
    property var _moeMap: ({})
    function _refreshMoe() {
        const svc = root.service;
        const out = ({});
        if (svc && typeof svc.moeOf === "function") {
            const ms = root.models || [];
            for (let i = 0; i < ms.length; ++i) {
                const id = (ms[i] && ms[i].id) ? String(ms[i].id) : "";
                if (id.length === 0) continue;
                const r = svc.moeOf(id);
                if (r && r.moe !== undefined)
                    out[id] = !!r.moe;
            }
        }
        if (JSON.stringify(out) !== JSON.stringify(root._moeMap))
            root._moeMap = out;
    }
    // "" until the service can answer: an empty slot, and nothing after it
    // moves when the word arrives.
    function _moeLabelOf(id) {
        const v = root._moeMap[id];
        return v === undefined ? "" : (v ? "MoE" : "Dense");
    }

    // ---- Giving the card back ----------------------------------------------
    // A right-click on a row's VRAM bar asks the service to unload THAT ROW's
    // model -- the bar is about that model, so the gesture has to be too.
    // Silent: the answer is the fills going out on the next live
    // tick and, on a row that then keeps no bar, the bar retreating to the
    // left through `_swapU`; a refusal says nothing at all.
    //
    // BOTH GATES ARE THE SERVICE'S, and asked exactly once, there: it refuses
    // while anything is generating, being titled, probed or tuned, and it
    // refuses for a model that is not resident anyway -- so a right-click on
    // the selected-but-cold row's EMPTY bar is a no-op rather than an eviction
    // of whatever else is loaded. A picker-side residency test would be a
    // second answer to the same question, and the honest one is /api/ps, which
    // is what the service reads.
    function _requestUnload(id) {
        const svc = root.service;
        if (svc && typeof svc.unloadNow === "function")
            svc.unloadNow(id);
    }

    // ---- The default model -------------------------------------------------
    // Right-click tags the row; right-clicking the row that already is the
    // default clears it, which is the only way to undo one (the system
    // update's favourite gesture, exactly). THE TOGGLE IS THE SERVICE'S OWN
    // RULE -- `setDefaultModel` clears when handed the id that is already the
    // default -- so this hands it the row and nothing else. Two places
    // deciding what a second right-click means is two places to change it.
    function _toggleDefault(id) {
        if (!id || id.length === 0) return;
        const svc = root.service;
        if (!svc || typeof svc.setDefaultModel !== "function") return;
        svc.setDefaultModel(id);
    }
    // ---- The VRAM bar's data -----------------------------------------------
    // One snapshot per model of the frozen service answer, taken together so
    // the whole list is one consistent reading of the card. Rebuilt wholesale
    // rather than per model because residency here is EXCLUSIVE -- one model
    // loads and another is evicted in the same instant -- so a single
    // `vramInfoChanged` is news about every row, not just its own.
    //
    // WHO GETS A BAR. The SELECTED model always does, loaded or not: the
    // question "will this thing fit?" is asked before it is loaded, not after,
    // and a footprint gate alone would answer it with nothing at all -- pick a
    // cold model and the row would go blank. An unloaded selection gets an
    // EMPTY bar (the track, no fill) and a tip that says so. Every OTHER row
    // has one while it holds VRAM -- and while it is merely RESIDENT: `loaded`
    // is true for a model running entirely in RAM (the dGPU did not come up),
    // and that is the model whose bar is needed, because it is where a
    // right-click unloads it so it can be loaded again once the card is fixed.
    // Such a bar draws no fill (it holds nothing of the card),
    // its track is the spill yellow (all of it is in RAM) and its tip says so.
    //
    // The map holds the service's answer for every model it can answer for;
    // `_hasBar` decides who draws one. `vramInfo` is only asked while the
    // list is open (see `_refreshVram`), and it is asked again on a timer
    // while it is open -- with `service.vramLive` set, so the
    // service polls fast enough for a bar to follow a model loading in.
    property var _vramMap: ({})
    function _refreshVram() {
        // ONLY THE ROWS CARRY A BAR, and rows exist only while the list is
        // open -- so a residency cue arriving while it is shut costs nothing
        // and every open re-asks. The map is not cleared on close (the
        // drop-down fades, and bars popping out from under it would be a
        // frame of nonsense); it is simply not refreshed.
        if (!root.open) return;
        const svc = root.service;
        if (!svc || typeof svc.vramInfo !== "function") {
            if (Object.keys(root._vramMap).length > 0)
                root._vramMap = ({});
            root._resyncBars();
            return;
        }
        const out = ({});
        const ms = root.models || [];
        for (let i = 0; i < ms.length; ++i) {
            const id = (ms[i] && ms[i].id) ? String(ms[i].id) : "";
            if (id.length === 0) continue;
            const v = svc.vramInfo(id);
            // A RESIDENT model is in the map whatever the card says: it has to carry a bar to be unloaded from, and a model running
            // in RAM (the dGPU did not come up) or a card that did not answer must not take that away.
            if (v && (Number(v.totalBytes) > 0 || v.loaded))
                out[id] = v;
        }
        root._vramMap = out;
        root._resyncBars();
    }
    function _vramOf(id) {
        const v = root._vramMap[id];
        return v ? v : null;
    }
    // Does this row draw a bar at all? See the note above.
    function _hasBar(id) {
        if (!id || id.length === 0) return false;
        const v = root._vramOf(id);
        if (!v) return false;
        // The selection, anything on the card, and anything RESIDENT -- a model that loaded into RAM holds no VRAM and is the one the user
        // most needs to unload (a dGPU that failed to come up means reloading it once the card is fixed). Its track is yellow: all of
        // it is "in RAM".
        return id === root.current || Number(v.vramBytes) > 0 || !!v.loaded;
    }
    // 0..1, clamped: what the MODEL's fill measures. -1 = no fill.
    function _vramFractionOf(id) {
        const v = root._vramOf(id);
        if (!v || Number(v.vramBytes) <= 0 || Number(v.totalBytes) <= 0) return -1;
        const f = Number(v.fraction);
        if (isNaN(f)) return -1;
        return Math.max(0, Math.min(1, f));
    }
    // 0..1, clamped: what the CARD's fill measures (usedFraction), never less
    // than the model's own share -- the model is part of the card's use, so a
    // card figure under it is a stale read, not a fact. -1 when the service
    // does not know the card's usage, and -1 for an EMPTY bar: an unloaded
    // selection draws no fill at all, so the growth the user watches when it
    // loads starts from nothing.
    function _vramCardFractionOf(id) {
        const v = root._vramOf(id);
        if (!v || Number(v.vramBytes) <= 0 || Number(v.totalBytes) <= 0) return -1;
        const used = Number(v.usedBytes);
        if (isNaN(used) || used <= 0) return -1;
        const f = Number(v.usedFraction);
        if (isNaN(f)) return -1;
        return Math.max(root._vramFractionOf(id), Math.min(1, f));
    }
    // Is this model paying the 8 GB tax -- part of it running in system RAM
    // because it did not fit (`size - size_vram`)? That is the
    // "it crawls" case, and it is a COLOUR: the bar turns deep yellow.
    function _vramSpillingOf(id) {
        const v = root._vramOf(id);
        return !!v && !!v.spilling && Number(v.ramBytes) > 0;
    }

    // ---- THE BAR'S APPEARANCE, AS ONE GESTURE ------------------------------
    // A bar that appeared and vanished between two frames would make the dots
    // above it jump 5 px as the row's right column changed height, so the whole
    // change -- the old row's bar retreating to the left, the new row's bar
    // growing from the left, and the dots of both rows sliding to where the
    // bar leaves them -- is ONE eased parameter.
    //
    // `_swapU` runs LINEARLY in time across the gesture; `_swapE` is the one
    // easing curve evaluated on it. The two halves of that curve are the two
    // halves of the gesture:
    //
    //     exit  = clamp(1 - 2*E)    1 -> 0 while E is 0 .. 0.5
    //     enter = clamp(2*E - 1)    0 -> 1 while E is 0.5 .. 1
    //
    // so the old bar is completely gone before the new one starts (SEQUENTIAL,
    // never both moving), and both are shaped by one curve rather than by two
    // independent eases -- the motion is fastest either side of the handover,
    // which is where the curve is steep. A gesture with nothing to remove
    // starts at u = 0.5 and a gesture with nothing to add stops there, so a
    // lone appearance is the second half of the same curve at half the
    // duration, not a different animation.
    property int  vramSwapMs: 420
    property real _swapU: 1
    property real _swapTo: 1
    function _easeInOutCubic(u) {
        const x = Math.max(0, Math.min(1, u));
        return x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2;
    }
    readonly property real _swapE: root._easeInOutCubic(root._swapU)
    readonly property real _exitExtent: Math.max(0, Math.min(1, 1 - 2 * root._swapE))
    readonly property real _enterExtent: Math.max(0, Math.min(1, 2 * root._swapE - 1))

    // Who has a bar now, who is losing one, who is gaining one.
    property var _barSet: ({})
    property var _barLeaving: ({})
    property var _barEntering: ({})
    NumberAnimation {
        id: swapAnim
        target: root
        property: "_swapU"
        // LINEAR: the curve is applied to the parameter (`_swapE`), once, for
        // both halves. Easing the animation as well would ease it twice.
        easing.type: Easing.Linear
    }
    function _resyncBars() {
        const want = ({});
        const ms = root.models || [];
        for (let i = 0; i < ms.length; ++i) {
            const id = (ms[i] && ms[i].id) ? String(ms[i].id) : "";
            if (id.length > 0 && root._hasBar(id))
                want[id] = true;
        }
        const had = root._barSet;
        const leaving = ({});
        const entering = ({});
        let changed = false;
        for (const k in had)
            if (!want[k]) { leaving[k] = true; changed = true; }
        for (const k in want)
            if (!had[k]) { entering[k] = true; changed = true; }
        if (!changed)
            return;
        root._barSet = want;
        root._barLeaving = leaving;
        root._barEntering = entering;
        const hasOut = Object.keys(leaving).length > 0;
        const hasIn = Object.keys(entering).length > 0;
        const from = hasOut ? 0 : 0.5;
        const to = hasIn ? 1 : 0.5;
        swapAnim.stop();
        root._swapU = from;
        swapAnim.from = from;
        swapAnim.to = to;
        swapAnim.duration = Math.max(1, Math.round(root.vramSwapMs * (to - from)));
        swapAnim.start();
    }
    // 0..1: how much of this row's bar is drawn. 1 = it was there before this
    // gesture and still is; the two animated cases are the gesture's halves.
    function _barExtentOf(id) {
        if (root._barEntering[id]) return root._enterExtent;
        if (root._barLeaving[id]) return root._exitExtent;
        return root._barSet[id] ? 1 : 0;
    }

    // ---- THE TIP'S TABLE ---------------------------------------------------
    // The same discipline as the spec columns: CELLS in fixed slots, each
    // left-aligned on its column's start. A figure that is centred moves both
    // ways at once.
    //
    // Four columns: what the row is about, how much, of how much, and the
    // share as a percent. Every slot is measured from the widest string the
    // column can hold, so a model loading under the pointer changes digits
    // and nothing else.
    //
    //   \uF1B2   3.0    / 8.0 GiB    38%     of the card
    //   U+F08AE  5.2    / 8.0 GiB    65%     of the card
    //   \uEFC5   1.4    / 8.6 GiB    16%     of the MODEL -- the spill
    //
    // THE TABLE'S THREE RULES. (1) The first column is one Nerd Font glyph, not
    // a word -- a cube for the model, the CARD for the card (a microchip is
    // what a CPU looks like, and the row is about the GPU), a memory stick for
    // the spill -- which is 9 px of label where the words "model" / "card" /
    // "in RAM" take 25, and reads at a glance.
    // (2) Each slot is measured from the widest string THIS tip can hold, the
    // numerator from the shape of its own total: a numerator slot measured from
    // "000.0" -- four digits of a figure that can never exceed the total beside
    // it -- would carry two digits of air in every row of an 8 GiB card.
    // (3) The share is right-aligned in its slot, which is what "grows to the
    // left" means for a figure that can reach three digits; left-aligned in a
    // "000%" slot, "38%" would leave a hole to its right at the tip's edge.
    //
    // The RAM row appears only when the model is spilling, and its
    // total is the model's own footprint, because what it measures is how
    // much of the MODEL is not on the card.
    // The tip's own type size (HoverTip's default), declared here because the
    // slots below are measured in it.
    property int tipFontSize: 10
    FontMetrics {
        id: tipMetrics
        font.family: root.fontFamily
        font.pixelSize: root.tipFontSize
    }
    // The three marks, as codepoints so an editor cannot lose them: fa-cube
    // (the model), md-expansion_card (the card -- a graphics card, which is
    // what this row measures), fa-memory (what spilled into system RAM).
    //
    // THE CARD'S MARK IS ABOVE THE BMP. U+F08AE cannot be written
    // as a `\uXXXX` escape -- that syntax reaches U+FFFF and no further -- so
    // it is built from its codepoint. Not pasted: this project has lost
    // pasted private-use glyphs to an editor before, and a codepoint in the
    // source is the one form that survives every tool that touches the file.
    // It is measured with `markMetrics.advanceWidth`, which takes the whole
    // surrogate pair as the one character it is.
    readonly property string markModel: "\uF1B2"
    readonly property string markCard: String.fromCodePoint(0xF08AE)
    readonly property string markRam: "\uEFC5"
    FontMetrics {
        id: markMetrics
        font.family: "Symbols Nerd Font"
        font.pixelSize: root.tipFontSize
    }
    function _gib(bytes) { return (Math.max(0, Number(bytes) || 0) / 1073741824).toFixed(1); }
    function _pct(f) { return String(Math.round(Math.max(0, Number(f) || 0) * 100)) + "%"; }
    // [{ mark, label, used, totalNum, total, pct }, ...]. `label` is the word
    // the mark stands for: what the tip says as TEXT (a probe, a log) says it
    // in words, because a glyph is not a reading.
    function _vramTipRows(id) {
        const v = root._vramOf(id);
        if (!v) return [];
        const total = root._gib(v.totalBytes);
        const rows = [];
        const modelF = root._vramFractionOf(id);
        if (modelF >= 0)
            rows.push({ mark: root.markModel, label: "model", used: root._gib(v.vramBytes),
                        totalNum: total, total: "/ " + total + " GiB", pct: root._pct(modelF) });
        const cardF = root._vramCardFractionOf(id);
        if (cardF >= 0)
            rows.push({ mark: root.markCard, label: "card", used: root._gib(v.usedBytes),
                        totalNum: total, total: "/ " + total + " GiB", pct: root._pct(cardF) });
        if (root._vramSpillingOf(id)) {
            const ram = Number(v.ramBytes) || 0;
            const size = root._gib(ram + (Number(v.vramBytes) || 0));
            rows.push({ mark: root.markRam, label: "in RAM", used: root._gib(ram),
                        totalNum: size, total: "/ " + size + " GiB",
                        pct: root._pct(v.ramFraction) });
        }
        return rows;
    }
    // The four slot widths of THIS tip, each the widest string its column can
    // hold here -- not the widest any tip could ever hold. The numerator is
    // measured from its own total with every digit turned into a 0: a share
    // of a card cannot have more digits than the card, and both are fixed
    // while the model under the pointer loads, which is when the digits move.
    // The share is the one column that is right-aligned, so 100% grows into
    // the space 38% leaves rather than past the tip's edge.
    readonly property string _pctSlot: "100%"
    function _vramTipSlots(id) {
        const rows = root._vramTipRows(id);
        let mark = 0, used = 0, total = 0;
        for (let i = 0; i < rows.length; ++i) {
            mark = Math.max(mark, root._advance(markMetrics, rows[i].mark));
            used = Math.max(used, root._advance(tipMetrics,
                                                rows[i].totalNum.replace(/[0-9]/g, "0")));
            total = Math.max(total, root._advance(tipMetrics, rows[i].total));
        }
        return [mark, used, total, root._advance(tipMetrics, root._pctSlot)];
    }
    // The one line of prose under the table, or "". An empty bar has to say
    // why it is empty; that is not a figure. A SPILLING bar says nothing
    // more: the yellow and the RAM row already say it, and a sentence there
    // would break the table's shape -- a line of prose wider than every
    // column under three rows of figures.
    function _vramTipNote(id) {
        const v = root._vramOf(id);
        if (!v) return "";
        if (!v.loaded)
            return "not loaded — nothing of the card is this model's yet";
        // Resident, and the bar has nothing to measure against: say which (the yellow track of a model in RAM says the rest).
        if (Number(v.totalBytes) <= 0)
            return "the card did not answer — its size is unknown";
        if (Number(v.vramBytes) <= 0 && Number(v.ramBytes) <= 0)
            return "loaded — nothing of the card is this model's";
        return "";
    }
    // The same, as words: the table joined into lines, then the note. What
    // anything that reads the tip as text gets.
    function _vramTip(id) {
        const rows = root._vramTipRows(id);
        const lines = [];
        for (let i = 0; i < rows.length; ++i)
            lines.push([rows[i].label, rows[i].used, rows[i].total, rows[i].pct].join("  "));
        const note = root._vramTipNote(id);
        if (note.length > 0)
            lines.push(note);
        return lines.join("\n");
    }

    // The three fixed slots, in reading order. `has` decides dot vs ring; the
    // tip says which word, honestly ("no vision" on a ring, never a bare word
    // over an absence). Audio is deliberately not marked -- every model on
    // this machine that has audio also has vision, so a fourth slot would add
    // width and no information.
    //
    // Each slot says whether its dot is FILLED, what colour its ring is when
    // it is not, and the tip's words. Vision and thinking are claims and stay
    // filled-or-empty; the tools slot carries the probe's verdict.
    function _proofOf(m) {
        const id = m && m.id ? String(m.id) : "";
        const p = root.toolProof ? root.toolProof[id] : undefined;
        if (p === undefined || p === null)
            return { state: "none", ms: 0, why: "" };
        if (typeof p === "string")
            return { state: p, ms: 0, why: "" };
        return { state: String(p.state || "none"), ms: Number(p.ms) || 0, why: String(p.why || "") };
    }
    //
    // FACTS ONLY -- NO COLOUR MAY ENTER THIS ARRAY. It is a
    // Repeater's `model`, an array compared by value, so a Theme token in it
    // makes every frame of the 420 ms crossfade a real model change and
    // `setModel` regenerates every delegate: 462 evaluations and 342 model
    // changes in ONE switch, about a thousand delegate trees built and torn
    // down, the fade at 24 fps. The delegate resolves the colours instead
    // (`_capFill` / `_capRing`), which is a colour write like any other.
    function _capSlots(m) {
        const c = root._capsOf(m);
        const proof = root._proofOf(m);
        const toolsFilled = !!c.tools && proof.state === "proven";
        const toolsTip = !c.tools ? "no tool calling"
                       : proof.state === "proven" ? "tool calling  proven · " + (proof.ms / 1000).toFixed(1) + " s"
                       : proof.state === "failed" ? "tool calling  declared, failed the probe"
                                                    + (proof.why.length > 0 ? " (" + proof.why + ")" : "")
                       : "tool calling  declared";
        return [
            { label: "vision",       kind: "vision", has: !!c.vision,   state: "",
              filled: !!c.vision, tip: (c.vision ? "" : "no ") + "vision" },
            { label: "tool calling", kind: "tools",  has: !!c.tools,    state: proof.state,
              filled: toolsFilled, tip: toolsTip },
            { label: "thinking",     kind: "think",  has: !!c.thinking, state: "",
              filled: !!c.thinking, tip: (c.thinking ? "" : "no ") + "thinking" }
        ];
    }
    // The two resolvers the delegate binds. Vision and thinking are claims,
    // so their ring is the shell's border; the tools slot carries the probe's
    // verdict -- no claim is the same empty ring, a failed probe is the ring
    // in `spill` (this list's "it runs, but not the way you hoped"), and a
    // claim not yet proven is a ring in the capability's own colour.
    function _capFill(d) {
        return d.kind === "vision" ? root.capVisionColor
             : d.kind === "tools"  ? root.capToolsColor
                                   : root.capThinkColor;
    }
    function _capRing(d) {
        if (d.kind !== "tools" || !d.has) return root.shadowColor;
        return d.state === "failed" ? root.spillColor : root.capToolsColor;
    }

    readonly property var _currentEntry: root._entryFor(root.current)

    // ---- The ctx row's state -----------------------------------------------
    // One snapshot of the frozen service API's answer for the CURRENT model,
    // re-read whenever anything that could change it moves: the model, the
    // service, the list opening, and every ctxInfoChanged for this model. A
    // snapshot rather than live bindings because ctxInfo() is a function --
    // the signal is the service's way of saying "ask again".
    property var _ctx: null
    readonly property bool _ctxRowVisible: root._ctx !== null
    readonly property bool _ctxManual: !!root._ctx && String(root._ctx.mode) === "manual"
    readonly property bool _ctxAutoSupported: !!root._ctx && !!root._ctx.autoSupported

    function _refreshCtx() {
        root._ctx = (root.service && root.current.length > 0
                     && typeof root.service.ctxInfo === "function")
            ? root.service.ctxInfo(root.current) : null;
    }
    onServiceChanged: {
        root._setVramLive(root.open);
        root._refreshCtx();
        root._refreshVram();
        root._refreshMoe();
    }
    // The selection decides who carries a bar, so it is news for the gesture
    // as well as for the ctx row.
    onCurrentChanged: { root._refreshCtx(); root._resyncBars(); }
    onModelsChanged: { root._refreshVram(); root._refreshMoe(); }
    // Not read by the bar, but its arrival IS the residency news -- see the
    // property's note.
    onLoadedChanged: root._refreshVram()
    Component.onCompleted: { root._refreshCtx(); root._refreshVram(); root._refreshMoe(); }
    Connections {
        target: root.service
        // The service may lack the ctx or vram API (an old mock): the row and
        // the bar are absent then, and this must not warn about either signal.
        ignoreUnknownSignals: true
        function onCtxInfoChanged(model) {
            if (model === root.current)
                root._refreshCtx();
        }
        // Deliberately not filtered by model: one model becoming resident is
        // another being evicted, and both rows have to stop lying at once.
        function onVramInfoChanged() { root._refreshVram(); }
    }
    // AUTO'S TIP. The first clause is all the tip says; a tail that named VRAM
    // would be wrong as often as right -- e2b tuned to 32768 is the QUALITY
    // cap, not the card. So the tip names the one fact the tuner knows and the
    // user cannot see: WHICH limit stopped it (`ctxInfo.autoBoundBy`). No
    // bound published, no second line.
    readonly property string _ctxBoundClause: {
        const b = root._ctx ? String(root._ctx.autoBoundBy || "") : "";
        if (b === "quality") return "capped for quality, not by VRAM";
        if (b === "vram") return "as much as fits on the card";
        if (b === "trained") return "the model's own maximum";
        return "";
    }
    readonly property string _ctxAutoTip: (root._ctxBoundClause.length > 0
        ? "auto-tuned context length\n" + root._ctxBoundClause
        : "auto-tuned context length") + root._toolCostClause
    readonly property string _ctxManualTip: "context length in tokens" + root._toolCostClause
    // Only when it matters: tools on, definitions priced, and a window under
    // 8192 -- a quarter of which the definitions would take.
    readonly property string _toolCostClause: {
        if (!root.toolsOn || root.toolDefinitionTokens <= 0) return "";
        const v = Number(root._ctxDisplayValue());
        if (!(v > 0) || v >= 8192) return "";
        return "\ntool definitions cost ~" + root.toolDefinitionTokens + " tokens of this context";
    }

    // What the field SHOWS. Manual: the user's value (the service seeds it
    // with the default). Auto: the tuned value once there is one, an ellipsis
    // while the tuner runs or before it has answered.
    function _ctxDisplayValue() {
        const c = root._ctx;
        if (!c) return "";
        if (String(c.mode) === "auto")
            return (c.probing || !(Number(c.autoValue) > 0)) ? "…" : String(c.autoValue);
        const v = Number(c.manualValue) > 0 ? c.manualValue : c.defaultValue;
        return String(Number(v) > 0 ? v : "");
    }

    // ---- The drop-down's rule, one component -------------------------------
    // The line under the brand tabs and the line above the Manual|Auto row
    // are the same line: inset by the box's padding, one pixel, the border
    // tone. Declared once so they cannot drift apart.
    component Divider: Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: dropdown._pad
        anchors.rightMargin: dropdown._pad
        height: 1
        color: root.shadowColor
    }

    // ---- The two pill selectors, one dressing ------------------------------
    // The brand tabs above the list and the Manual|Auto toggle under it are
    // the update popup's mode selector in the picker's palette, and they are
    // one material: this is that dressing, declared once. The INACTIVE tint
    // is the primary text; the ctx toggle dims it when auto is refused.
    component PickerTabs: TabSelector {
        height: dropdown._ctrlH
        // Neither selector listens for the wheel itself: the ctx toggle
        // answers clicks only, and the brand tabs are driven by the
        // drop-down's own capture area (see the header).
        swipeSelfHandled: false
        fontFamily: root.fontFamily
        fontPixelSize: root._tabFontSize
        trackSurfaceColor: root.fieldColor
        trackBevelColor: root.shadowColor
        trackShadowColor: root.deepShadowColor
        trackBackgroundColor: root.headerBoxColor
        trackBevelWidth: 1
        pillSurfaceColor: root.headerBoxColor
        pillBevelColor: root.accentBevel
        pillShadowColor: root.buttonShadow
        pillBackgroundColor: root.accent
        // THE PILL SITS IN THE GROOVE. A raised ShadowBox paints its drop
        // shadow OUTSIDE its edge, and with `shadowToAlpha` off -- which is
        // what TabSelector uses -- that band is OPAQUE: `pillSurfaceColor`
        // shaded down to the shadow, laid over whatever is under it. At the
        // default 3 it is exactly as wide as `pillInset`, so it reaches the
        // track's own edge and repaints the track's inset shadow out of
        // existence. Measured in light mode, reading inward from the track's
        // edge: the free half of the track (no pill over it) goes 195, 214,
        // 220 -- dark at the edge, easing into the header-box fill -- and
        // beside a pill with the default shadow it goes 219, 215, 198, the
        // same ramp upside down, because that is the PILL's shadow and the
        // groove is gone. Pill and track then read as one flat step. At 1.5
        // the apron stops halfway across the inset: the same three pixels
        // read 195, 217, 209 -- the track's own edge back to the value it has
        // where nothing covers it. The invariant is apron < inset: what
        // stands proud may not paint over the channel it stands in.
        pillShadowWidth: 1.5
        textColor: root.primaryText
        activeTextColor: root.textOnAccent
    }

    // ---- One line of the notes tip -----------------------------------------
    // A mark in a slot of its own, then the words, wrapping under
    // themselves rather than under the mark -- a list, not a paragraph.
    readonly property real _noteMarkW: Math.max(root._advance(tipMetrics, "+ "),
                                                root._advance(tipMetrics, "− "))
    component NoteLine: Item {
        id: noteLine
        property string mark: ""
        property string body: ""
        property color tint: root.primaryText
        width: parent ? parent.width : 0
        implicitHeight: noteBody.implicitHeight
        height: implicitHeight
        Text {
            x: 0
            width: root._noteMarkW
            text: noteLine.mark
            color: noteLine.tint
            font.family: root.fontFamily
            font.pixelSize: root.tipFontSize
        }
        Text {
            id: noteBody
            x: root._noteMarkW
            width: Math.max(0, noteLine.width - root._noteMarkW)
            wrapMode: Text.WordWrap
            text: noteLine.body
            color: noteLine.tint
            font.family: root.fontFamily
            font.pixelSize: root.tipFontSize
        }
    }
    // What the row's model may be handed to read: "reads files up to 78 KB",
    // with the way to more when its context is held below its trained window.
    // "" when the service cannot say. The cap is the service's (`textCapInfo`).
    function _capTextOf(id) {
        const s = root.service;
        if (!s || typeof s.textCapInfo !== "function")
            return "";
        const c = s.textCapInfo(id);
        if (!c || c.bytes <= 0)
            return "";
        const kb = c.bytes >= 1048576 ? (c.bytes / 1048576).toFixed(1) + " MiB" : Math.round(c.bytes / 1024) + " KiB";
        let t = "reads text files up to " + kb;
        if (c.bound === "ceiling")
            t += " (the most the module hands over)";
        else if (c.trained > c.ctx * 1.5)
            t += " at its " + c.ctx + "-token context -- a larger context reads more";
        return t;
    }
    // The row's tip is its notes, then what it reads: it opens for either.
    function _tipOf(id) {
        return root._notesOf(id) !== null || root._capTextOf(id).length > 0;
    }
    // The notes for a row, or null when the registry has nothing worth a tip.
    function _notesOf(id) {
        const n = root.notes;
        if (!n || typeof n.notesFor !== "function")
            return null;
        const r = n.notesFor(id);
        if (!r) return null;
        const hasLines = (r.strengths && r.strengths.length > 0)
                      || (r.caveats && r.caveats.length > 0);
        return (hasLines || (r.compare && String(r.compare).length > 0)) ? r : null;
    }

    // ---- The capability dots, one component for the pill and the rows ------
    // A 5px dot (filled = has it, ring = does not) inside a MUCH larger hover
    // slot, 12x20 (the dot stays 5px, centred; pitch is kept by the spacing):
    // a human cannot park a cursor on a 5px mark and hold it, so a slot the
    // size of the ink would never show its tip. The delay is 250ms: the mark
    // is small, the answer should not also be slow.
    component CapDots: Row {
        id: dots
        property var entry: null
        // A TIP MAPS ITS ANCHOR ONCE, at open (HoverTip.qml), so a copy of
        // these dots that travels -- the one in a list row, while the box
        // eases to another brand's height -- must not open one mid-flight.
        // The pill's copy never moves and leaves this false.
        property bool tipsHeld: false
        spacing: 0
        // THE INK'S FOOTPRINT: from the first dot's left edge to
        // the last dot's right edge -- the dots plus the gaps between them,
        // without the hover slack either side. This is what the VRAM bar
        // under the dots is as wide as. The dot is placed EXPLICITLY, floored
        // to a whole pixel (measured: `anchors.centerIn` put a 5 px dot at
        // x = 3 in a 12 px slot, not 4), so the inset the bar is offset by
        // and the pixel the dot sits on are the same number by construction.
        readonly property real inkLeftInset: Math.floor((root.capSlotWidth - root.capDotSize) / 2)
        readonly property real inkRightInset: root.capSlotWidth - root.capDotSize - dots.inkLeftInset
        readonly property real inkWidth: dots.width - dots.inkLeftInset - dots.inkRightInset
        Repeater {
            model: root._capSlots(dots.entry)
            Item {
                id: slot
                required property var modelData
                width: root.capSlotWidth; height: root.capSlotHeight
                Rectangle {
                    x: dots.inkLeftInset
                    y: Math.floor((slot.height - height) / 2)
                    width: root.capDotSize; height: root.capDotSize; radius: root.capDotSize / 2
                    color: slot.modelData.filled ? root._capFill(slot.modelData) : "transparent"
                    border.width: slot.modelData.filled ? 0 : 1
                    border.color: root._capRing(slot.modelData)
                }
                // HoverHandler, not a MouseArea: it neither eats the row's
                // click nor steals the row's own containsMouse.
                HoverHandler { id: slotHover }
                HoverTip {
                    show: slotHover.hovered && !dots.tipsHeld
                    delayMs: 250
                    anchorItem: slot
                    overlayItem: root.overlayItem
                    text: slot.modelData.tip
                    fontFamily: root.fontFamily
                    surfaceColor: root.surfaceColor
                    bevelColor: root.bevelColor
                    shadowColor: root.shadowColor
                    textColor: root.primaryText
                }
            }
        }
    }

    // WHOLE PIXELS. The row's implicit width is a sum of glyph advances, so
    // left fractional the pill would be 112.70 wide and, right-anchored in the
    // composer, START at x = 709.30: every glyph in it would sit at a
    // fractional position. MEASURED: text at a fractional x does not always
    // raster the same way twice -- after other text had been drawn (a
    // confirmation's card) the name's glyphs came back with 3-11 pixels one
    // level off. Integer widths here and on the two texts put every glyph on
    // the pixel grid, where the raster is the same whatever was drawn before
    // it.
    implicitWidth: pillRow.implicitWidth + 20
    implicitHeight: root.pillHeight

    // ======================================================================
    // THE PILL
    // ======================================================================
    property real _pillHoverF: pillArea.containsMouse ? 1 : 0
    Behavior on _pillHoverF { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
    property real _pillPress: pillArea.pressed ? 1 : 0
    Behavior on _pillPress { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }

    ShadowBox {
        id: pill
        anchors.fill: parent
        raised: true
        baseRadius: 8
        surfaceColor: root.surfaceColor
        backgroundColor: Mix.c(root.buttonPlateau, root.buttonPlateauHover, root._pillHoverF)
        bevelColor: root.buttonBevel
        shadowColor: root.buttonShadow
        // Same relief maths as RaisedButton, so pill and buttons in the same
        // band read as one plateau height.
        bevelWidth: Math.max(0.5, 1.5 * (1 - root._pillPress * 0.8))
        shadowWidth: Math.max(0.5, 5 * (1 - root._pillPress * 0.85))
        shadowEdgeAlpha: 0.9 * (1 - root._pillPress * 0.6)
    }

    Row {
        id: pillRow
        anchors.centerIn: parent
        anchors.verticalCenterOffset: root._pillPress * 1
        // Above pillArea: a MouseArea that accepts hover blocks the dots'
        // HoverHandlers underneath it (measured -- the tips never opened).
        // Nothing in this row takes buttons, so clicks still fall through.
        z: 1
        spacing: 6

        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: Math.ceil(implicitWidth)
            text: "\uF085"
            font.family: "Symbols Nerd Font"
            font.pixelSize: 12
            color: root.mutedText
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: Math.ceil(implicitWidth)
            text: root._shortName(root.current)
            font.family: root.fontFamily
            font.pixelSize: 12
            font.bold: true
            color: root.current.length > 0 ? root.primaryText : root.faintText
        }

        CapDots {
            anchors.verticalCenter: parent.verticalCenter
            entry: root._currentEntry
        }
    }

    MouseArea {
        id: pillArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.open = !root.open
    }

    // ======================================================================
    // THE FLOATING PAIR -- dismiss layer and drop-down
    //
    // Both live in the host's overlay while one exists (see the header): the
    // pill's origin is mapped into the overlay each time the list opens, and
    // the drop-down hangs off that stored point, so it keeps growing upward
    // from the pill even as its own height resolves. With no overlay both
    // stay children of root.
    // ======================================================================
    readonly property Item _floatHost: root.overlayItem ? root.overlayItem : root
    property point _origin: Qt.point(0, 0)
    onOpenChanged: {
        if (root.open && root.overlayItem)
            root._origin = root.mapToItem(root.overlayItem, 0, 0);
        // Values may have moved while the list was shut (a tuner finishing,
        // an ask reloading the model): every open shows the current truth.
        if (root.open) {
            root._refreshCtx();
            root._refreshVram();
            root._refreshMoe();
            // The tab the list opens on is the CURRENT model's brand.
            root._brand = root.brandOf(root.current);
        } else {
            // A list shut mid-swipe: the gesture is over, the pill goes home.
            gestureIdle.stop();
            brandTabs.applySwipe(0);
            root._gestureActive = false;
        }
        // LIVE ONLY WHILE A HUMAN IS LOOKING: the
        // flag drops the service's /api/ps + nvidia-smi throttle to about a
        // second, which is what lets a bar follow a model loading in; a
        // closed pill must not pay for that, so it is cleared on close.
        root._setVramLive(root.open);
    }
    // Set on the service object itself -- `vramLive` is a plain property on
    // it, and a service without the field is simply left alone.
    function _setVramLive(on) {
        const svc = root.service;
        if (svc && svc.vramLive !== undefined)
            svc.vramLive = on;
    }
    // The re-ask. The service is what actually re-reads the card; this only
    // asks it again for its current answer, so the interval is the refresh
    // rate of the BAR, not of nvidia-smi.
    Timer {
        running: root.open
        interval: Math.max(100, root.liveRefreshMs)
        repeat: true
        onTriggered: { root._refreshVram(); root._refreshMoe(); }
    }
    // A popup destroyed with the list open would leave the service polling
    // fast forever.
    Component.onDestruction: root._setVramLive(false)

    // Dismiss layer: full-bleed over the overlay (or, parentless fallback, a
    // deliberately huge sheet -- nothing in the popup clips this band). It does
    // not take the click (LlmDismissLayer): the click that closes the list also
    // reaches what it was aimed at, so the tools button under the pointer is
    // pressed by the same click. The pill is the exception, left to its own
    // toggle -- a click there reaching both would close the list twice over and
    // the pill's toggle would open it again.
    LlmDismissLayer {
        parent: root._floatHost
        open: root.open
        x: root.overlayItem ? 0 : -3000
        y: root.overlayItem ? 0 : -3000
        width: root.overlayItem ? root._floatHost.width : 6000
        height: root.overlayItem ? root._floatHost.height : 6000
        onDismissed: pt => {
            const p = root.mapFromItem(null, pt.x, pt.y);
            if (p.x >= 0 && p.y >= 0 && p.x < root.width && p.y < root.height)
                return;
            root.open = false;
        }
    }

    // Escape, wherever the keyboard focus happens to be. A window-context
    // Shortcut rather than a Keys handler because the list must NOT take
    // focus: the prompt field keeps it the whole time the list is open (that
    // is what lets typing dismiss it), and an unfocused item receives no keys.
    // MEASURED under quickshell (offscreen, synthetic keyClick): while the
    // shortcut is enabled it consumes Escape and the focused TextArea never
    // sees it; disabled, the TextArea gets it -- so the composer's own Escape
    // (drop focus out of the prompt) is untouched the moment the list is
    // shut.
    Shortcut {
        sequence: "Escape"
        enabled: root.open
        onActivated: root.open = false
    }

    Item {
        id: dropdown
        parent: root._floatHost
        z: 300
        // Right-aligned and above the pill: it sits at the bottom-right of
        // the popup, so the list grows away from both edges it is near.
        x: root.overlayItem ? Math.max(2, root._origin.x + root.width - width)
                            : root.width - width
        y: root.overlayItem ? root._origin.y - height - 6
                            : -(height + 6)
        // As wide as the pill's row, the list, or the tabs -- whichever
        // asks for most.
        width: Math.max(root.listWidth, root.width, dropdown._tabsMinW, dropdown._specMinW)
        height: dropdown._pad * 2 + dropdown._tabsH + dropdown._listH + dropdown._ctxH

        // The box's own numbers: its padding, the gap either side of a rule,
        // and the height of a control row (the tabs, the ctx row).
        readonly property real _pad: 10
        readonly property real _gap: 8
        readonly property real _ctrlH: 26
        // THE ONE CLOCK. `_listTarget` is where the list is
        // going -- the rows this brand has, capped by the host's maximum --
        // and `_animListH` is where it is now. Everything else in this box is
        // a sum of `_listH` or an anchor off something that is, so the whole
        // drop-down moves on this single eased value; see the header for why
        // the Behavior may not sit on the box's own height.
        readonly property real _listTarget: Math.min(root.maxListHeight, Math.max(28, listColumn.implicitHeight))
        property real _animListH: dropdown._listTarget
        Behavior on _animListH {
            NumberAnimation { id: listResize; duration: root.resizeMs; easing.type: Easing.OutCubic }
        }
        // Is the box in motion? What cannot follow a moving anchor is shut
        // while it is: every tip anchored in a row (see the header).
        readonly property bool _resizing: listResize.running
        // ROUNDED ONCE, HERE (the composer's law): the easing keeps its
        // smooth real, and every edge derived from it lands on whole pixels,
        // so nothing in the box breathes a pixel for the whole 260 ms.
        readonly property real _listH: Math.round(dropdown._animListH)
        // The brand band above the list: tabs, gap, rule, gap -- present
        // only with two or more brands to choose between.
        readonly property real _tabsH: root._tabsVisible
            ? dropdown._ctrlH + dropdown._gap + 1 + dropdown._gap : 0
        // The ctx band under the list: gap, rule, gap, row -- present only
        // while a service answers ctxInfo for the current model.
        readonly property real _ctxH: root._ctxRowVisible
            ? dropdown._gap + 1 + dropdown._gap + dropdown._ctrlH : 0
        // The drop-down at its TALLEST brand: what the swipe area is held at
        // while a gesture is live (see the header).
        readonly property real _holdH: dropdown._pad * 2 + dropdown._tabsH
            + Math.min(root.maxListHeight, Math.max(28, root._maxBrandCount * root.rowHeight))
            + dropdown._ctxH
        // The tabs' own minimum: every slot as wide as the widest label plus
        // its air, so more brands than the list is wide widens the box
        // rather than crowding the labels.
        readonly property real _tabsMinW: root._tabsVisible
            ? dropdown._pad * 2 + root._brands.length * (root._widestBrandW + root._tabAir) : 0
        // The ROW's own minimum, the same law as the tabs': the box grows to
        // seat what it must show rather than sliding the table under the
        // dots. The terms are the row's, in order -- its left inset, the
        // table, the gap to the marks, the three dot slots, the right
        // margin.
        readonly property real _specMinW: dropdown._pad * 2 + 10 + root._specTableW
            + 8 + 3 * root.capSlotWidth + 10

        opacity: root.open ? 1 : 0
        visible: opacity > 0
        // Presence fades; the content does not crossfade through anything.
        Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

        ShadowBox {
            anchors.fill: parent
            baseRadius: 14
            // The ground OUTSIDE the box is whatever the list floats over,
            // which -- opening upward from the composer -- is the transcript's
            // container, not the popup's surface.
            surfaceColor: root.listBoxColor
            backgroundColor: root.fieldColor
            bevelColor: root.bevelColor
            shadowColor: root.shadowColor
            bevelWidth: 1
            shadowWidth: 3
        }

        // ---- The brand band -----------------------------------------------
        // The tabs, then the rule -- the same rule as the ctx band's -- with
        // the box's gap either side of it.
        PickerTabs {
            id: brandTabs
            visible: root._tabsVisible
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: dropdown._pad
            anchors.leftMargin: dropdown._pad
            anchors.rightMargin: dropdown._pad
            tabs: root._brandTabs
            swipeEnabled: true
            onTabChanged: id => { root._brand = id; }
            // A click writes TabSelector.currentTab, which would sever a
            // binding on first use; the truth lives in `_brandShown` and is
            // restored from it instead, as the ctx toggle's is -- and again
            // when the tabs themselves change, since the selector's own
            // default would otherwise park it on the first.
            Connections {
                target: root
                function on_BrandShownChanged() {
                    if (brandTabs.currentTab !== root._brandShown)
                        brandTabs.currentTab = root._brandShown;
                }
            }
            onTabsChanged: {
                if (brandTabs.currentTab !== root._brandShown)
                    brandTabs.currentTab = root._brandShown;
            }
        }
        Divider {
            id: tabsRule
            visible: root._tabsVisible
            anchors.top: brandTabs.bottom
            anchors.topMargin: dropdown._gap
        }

        // ---- The swipe, captured across the whole drop-down ---------------
        // A MouseArea on top, not a WheelHandler, for the update popup's
        // reason: the list's scrolling handler sits deeper (ScrollDressing,
        // below) and would take every wheel event first. This one takes no
        // buttons and accepts nothing, so clicks, hover and the vertical
        // scroll all pass through to what is under it. Anchored to the FOOT
        // of the box -- the edge that stays put when the list changes height
        // -- and held at the tallest brand's height while a gesture is live.
        WheelArea {
            id: swipeArea
            z: 5
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            height: root._gestureActive ? Math.max(parent.height, dropdown._holdH) : parent.height
            enabled: root.open && root._tabsVisible && root.swipeToSwitchBrand
            turned: wheel => {
                // a mouse: a sideways notch is a brand (an upright one is the list's, or the brand row's own)
                if (wheel.device === "wheel") {
                    if (wheel.angleDelta.x !== 0)
                        brandTabs.applySteps(wheel.steps);
                    wheel.accepted = false;
                    return;
                }
                let dx = wheel.angleDelta.x;
                if (dx === 0 && wheel.pixelDelta.x !== 0)
                    dx = wheel.pixelDelta.x * root.swipePixelToAngle;
                // Zero on BOTH axes is the touchpad's scroll-end: the
                // fingers have left the surface.
                const ended = dx === 0
                           && wheel.angleDelta.y === 0
                           && wheel.pixelDelta.y === 0;
                if (ended) {
                    gestureIdle.stop();
                    brandTabs.applySwipe(0);
                    root._gestureActive = false;
                    wheel.accepted = false;
                    return;
                }
                gestureIdle.restart();
                if (!root._gestureActive)
                    root._gestureActive = true;
                if (dx !== 0)
                    brandTabs.applySwipe(dx);
                // Never consumed: the list still needs the vertical part.
                wheel.accepted = false;
            }
        }
        Timer {
            id: gestureIdle
            interval: root.gestureIdleEndMs
            onTriggered: {
                brandTabs.applySwipe(0);
                root._gestureActive = false;
            }
        }

        Flickable {
            id: list
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: dropdown._pad + dropdown._tabsH
            anchors.leftMargin: dropdown._pad
            anchors.rightMargin: dropdown._pad
            height: dropdown._listH
            contentWidth: width
            contentHeight: listColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            Column {
                id: listColumn
                width: list.width
                spacing: 0

                Text {
                    width: parent.width
                    height: visible ? 28 : 0
                    visible: !root.models || root.models.length === 0
                    verticalAlignment: Text.AlignVCenter
                    text: root.busy ? "Loading models…"
                          : root.offline ? "Ollama is not running" : "No models installed"
                    color: root.faintText
                    font.family: root.fontFamily
                    font.pixelSize: 11
                }

                Repeater {
                    model: root._visibleModels

                    Item {
                        id: row
                        required property var modelData
                        width: listColumn.width
                        height: root.rowHeight

                        readonly property string _id: row.modelData ? (row.modelData.id || "") : ""
                        readonly property bool _isCurrent: row._id === root.current
                        // The module's default: a right-click's tag, marked
                        // with the SAME stripe, drained.
                        readonly property bool _isDefault: row._id.length > 0
                                                           && row._id === root.defaultModel
                        readonly property real _vram: root._vramFractionOf(row._id)
                        readonly property real _vramCard: root._vramCardFractionOf(row._id)
                        readonly property bool _spilling: root._vramSpillingOf(row._id)
                        // The bar's colour: one material, two meanings.
                        readonly property color _barColor: row._spilling ? root.spillColor : root.accent
                        // 0..1 -- how much of this row's bar is drawn right
                        // now. See `_swapU`: one curve, two sequential halves.
                        readonly property real _barExtent: root._barExtentOf(row._id)

                        property real _hoverF: rowArea.containsMouse ? 1 : 0
                        Behavior on _hoverF { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                        // ONE MARK, TWO DIMENSIONS: `_markF` is
                        // whether the stripe is there at all (the default's
                        // only feedback, so it fades on the shell's presence
                        // number), `_selF` how far it has travelled from
                        // drained to full accent. Fractions, never a
                        // `Behavior on color`: the theme is one clock.
                        property real _markF: (row._isCurrent || row._isDefault) ? 1 : 0
                        Behavior on _markF { NumberAnimation { duration: root.defaultStripeFadeMs; easing.type: Easing.OutCubic } }
                        property real _selF: row._isCurrent ? 1 : 0
                        Behavior on _selF { NumberAnimation { duration: root.stripeSelectFadeMs; easing.type: Easing.OutCubic } }

                        Rectangle {
                            anchors.fill: parent
                            anchors.topMargin: 1
                            anchors.bottomMargin: 1
                            radius: 8
                            color: Mix.c(root.fieldColor, root.surfaceColor, row._hoverF)
                        }

                        // The row's stripe: the same mark the shell uses for
                        // a selected row everywhere else, and -- drained the
                        // system update's way -- for the DEFAULT model. A row
                        // that is both shows the accent and nothing else: one
                        // row, one coloured mark.
                        Rectangle {
                            x: 0
                            anchors.verticalCenter: parent.verticalCenter
                            width: 3
                            height: 22
                            radius: 1.5
                            color: Mix.c(root._faintStripeColor, root.accent, row._selF)
                            opacity: row._markF
                            visible: row._markF > 0
                        }

                        Column {
                            anchors.left: parent.left
                            anchors.leftMargin: 10
                            anchors.right: rowRight.left
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1

                            Text {
                                width: parent.width
                                text: row._id
                                elide: Text.ElideRight
                                color: row._isCurrent ? root.accent : root.primaryText
                                font.family: root.fontFamily
                                font.pixelSize: 12
                                font.bold: row._isCurrent
                            }
                            // The specs, in columns (see `_specParamsW`).
                            // LEFT-ALIGNED ON A COMMON START: the first value
                            // sits under the first letter of the model's NAME,
                            // and each column starts where its slot starts.
                            // Right-aligned figures would centre the group in
                            // the eye and hang it away from the name. The Row
                            // has no `width` at all, so it is as wide as its
                            // cells and ends where the values end, rather than
                            // stretching to the dots.
                            Row {
                                id: specRow
                                height: root.specFontSize + 4
                                spacing: root.specColumnGap

                                // Parameters.
                                Text {
                                    width: root._specParamsW
                                    height: specRow.height
                                    verticalAlignment: Text.AlignVCenter
                                    text: root._paramsOf(row.modelData)
                                    color: root.faintText
                                    font.family: root.fontFamily
                                    font.pixelSize: root.specFontSize
                                }
                                // Context: the figure alone, in its own
                                // slot (no unit; "128K" beside a parameter
                                // count says what it is). Empty when there
                                // is none; the slot stays.
                                Text {
                                    id: ctxCell
                                    readonly property string _c: root._ctxLabel(row.modelData ? row.modelData.ctx : 0)
                                    width: root._specCtxNumW
                                    height: specRow.height
                                    verticalAlignment: Text.AlignVCenter
                                    text: ctxCell._c
                                    color: root.faintText
                                    font.family: root.fontFamily
                                    font.pixelSize: root.specFontSize
                                }
                                // MIXTURE OR DENSE, between the
                                // two capacities and the encoding: it is
                                // neither -- it is what the model DOES with
                                // them, and it is why a 35 B here answers
                                // thirteen times faster than a 31 B. The
                                // server's own fact (see `_refreshMoe`), in
                                // its own fixed slot: empty until it lands,
                                // and nothing after it moves when it does.
                                Text {
                                    visible: root.showMoeColumn
                                    width: root._specMoeW
                                    height: specRow.height
                                    verticalAlignment: Text.AlignVCenter
                                    text: root._moeLabelOf(row._id)
                                    color: root.faintText
                                    font.family: root.fontFamily
                                    font.pixelSize: root.specFontSize
                                }
                                // Quantisation, last: the encoding, after
                                // the two capacities.
                                Text {
                                    width: root._specQuantW
                                    height: specRow.height
                                    verticalAlignment: Text.AlignVCenter
                                    text: root._quantOf(row.modelData)
                                    elide: Text.ElideRight
                                    color: root.faintText
                                    font.family: root.fontFamily
                                    font.pixelSize: root.specFontSize
                                }
                            }
                        }

                        Column {
                            id: rowRight
                            // Above rowArea, for the dots' HoverHandlers --
                            // same reason as pillRow; the handler is
                            // non-blocking, so the row keeps its wash.
                            z: 1
                            anchors.right: parent.right
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            // 0: each child owns its own space -- the 6px of
                            // gap above the bar is the top of the residency
                            // slot, so the bar can be hovered without moving a
                            // painted pixel.
                            spacing: 0

                            CapDots {
                                id: rowDots
                                anchors.right: parent.right
                                entry: row.modelData
                                tipsHeld: dropdown._resizing
                            }

                            // THE CARD, AS A BAR. The whole track is the
                            // GPU; two fills come in from the left: the
                            // lighter, longer one is what the CARD has in
                            // use, the full-accent one on top of it is what
                            // THIS MODEL is holding. The remainder is THE
                            // SAME BAR faded back rather than a second
                            // colour, and the fills are the same accent at
                            // two strengths: one material, two facts of one
                            // kind, and the eye reads two shares of one
                            // whole instead of three objects.
                            //
                            // Every end is a capsule within the bar's own
                            // 4 px -- no head wider than the line. The
                            // model's fill is floored at its own
                            // capsule so a tiny share is a dot, not a
                            // sliver; below f = 4/44 it therefore sits
                            // slightly right of the truth, and the tip is
                            // where the truth is exact. The card's fill is
                            // never shorter than the model's plus the
                            // minimum step (`minStepPx`), so the two never
                            // merge into one end.
                            //
                            // THE SLOT IS THE HOVER TARGET, NOT THE BAR. A
                            // 4px mark has the dots' problem (a human cannot
                            // park a pointer on a 5px mark and hold it
                            // 250 ms), and a child grown past the bar's
                            // bounds would paint but never receive the
                            // hover -- Qt prunes pointer delivery at ancestor
                            // bounds. So the slot claims the gap above the
                            // bar: the bar's width by 10 of target with the
                            // bar centred inside it.
                            //
                            // AS WIDE AS THE DOTS: the bar spans
                            // exactly the dots' ink -- first dot's left edge
                            // to last dot's right edge, gaps included -- so
                            // the two marks read as one column; the dots are
                            // the fixed thing, the bar follows them.
                            //
                            // EMPTY, NOT ABSENT, on the selected model when
                            // it is not loaded -- see the header.
                            //
                            // IT GROWS FROM THE LEFT AND RETREATS TO THE
                            // LEFT. `_barExtent` is the row's share of the
                            // one gesture (`_swapU`): the bar's ink is
                            // revealed by a clip that runs out from the left
                            // edge, so the fills keep their true positions
                            // while it moves -- a scaled bar would show a
                            // wrong figure on every frame of the animation.
                            // The SLOT's height rides the same number, which
                            // is what slides the dots above it into place
                            // instead of jumping them 5 px.
                            Item {
                                id: vramSlot
                                anchors.right: parent.right
                                anchors.rightMargin: rowDots.inkRightInset
                                width: rowDots.inkWidth
                                height: 10 * row._barExtent
                                visible: row._barExtent > 0

                                readonly property real barH: root.vramBarHeight
                                // THE MINIMUM VISIBLE STEP between the two
                                // fills, in px. The model's fill ends in a
                                // capsule of radius barH/2 and so does the
                                // card's; where the card's fill shows past
                                // the model's, its own cap takes barH/2 of
                                // that, so what is left as a flat, lighter
                                // run is (step - barH/2). For that run to
                                // read as a length of bar -- not a halo
                                // around the model's cap -- it has to be at
                                // least as long as the bar is tall: step >=
                                // barH/2 + barH = 6 px at a 4 px bar.
                                readonly property real minStepPx: root.vramMinStepPx
                                // The model's extent, in px, with its own
                                // capsule as its floor: the smallest fill is
                                // a dot as tall as the bar, never wider. -1
                                // (an empty bar) draws no fill at all.
                                readonly property real fillW: row._vram < 0 ? -1
                                    : Math.max(vramSlot.barH,
                                               vramSlot.width * Math.max(0, row._vram))
                                // The card's extent: its own share, pushed
                                // out to `fillW + minStepPx` when it would
                                // end within the step of the model's -- and
                                // never past the bar (a nearly full card
                                // with a model that fills nearly all of it
                                // has no room for a step; the bar being full
                                // is then what is true). -1 when unknown:
                                // no second fill is drawn.
                                readonly property real cardW: row._vramCard < 0 ? -1
                                    : Math.min(vramSlot.width,
                                               Math.max(vramSlot.width * row._vramCard,
                                                        vramSlot.fillW + vramSlot.minStepPx))

                                // The ink, revealed from the left. The three
                                // rects are laid out at the bar's FULL width
                                // inside it, so what the clip uncovers is
                                // always the bar as it really is.
                                Item {
                                    id: barClip
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Math.max(0, vramSlot.width * row._barExtent)
                                    height: 10
                                    clip: true

                                    // The remainder: the same bar, faded back.
                                    Rectangle {
                                        id: vramTrack
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: vramSlot.width
                                        height: vramSlot.barH
                                        radius: height / 2
                                        color: row._barColor
                                        opacity: root.vramTrackOpacity
                                        z: 0
                                    }
                                    // What the CARD holds: the longer,
                                    // lighter fill, under the model's.
                                    Rectangle {
                                        id: vramCardFill
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: vramSlot.cardW >= 0
                                        width: Math.max(0, vramSlot.cardW)
                                        height: vramSlot.barH
                                        radius: height / 2
                                        color: row._barColor
                                        opacity: root.vramCardOpacity
                                        z: 1
                                    }
                                    // What the MODEL holds: full strength, on
                                    // top, never longer than the card's.
                                    Rectangle {
                                        id: vramModelFill
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: vramSlot.fillW >= 0
                                        width: Math.max(0, vramSlot.fillW)
                                        height: vramSlot.barH
                                        radius: height / 2
                                        color: row._barColor
                                        z: 2
                                    }
                                }

                                // HoverHandler, like the dots': it takes
                                // neither the row's click nor its wash.
                                HoverHandler { id: vramHover }
                                // GIVE THE CARD BACK: a right-click here
                                // asks the service to unload. RIGHT BUTTON
                                // ONLY is load-bearing
                                // -- measured: with Left|Right this area
                                // swallows the left click and the bar stops
                                // picking the model. Not hover-enabled:
                                // nothing here needs it, and the row's own
                                // wash and the slot's tip are read from the
                                // handler above and from rowArea.
                                MouseArea {
                                    anchors.fill: parent
                                    acceptedButtons: Qt.RightButton
                                    cursorShape: undefined   // the left button passes through: the cursor is what lies under it (a MouseArea owns an Arrow)
                                    hoverEnabled: false
                                    onClicked: root._requestUnload(row._id)
                                }
                                HoverTip {
                                    id: vramTipHover
                                    // Not while the box is moving: this
                                    // slot travels with it, and a tip does
                                    // not follow its anchor (see the header).
                                    show: vramHover.hovered && !dropdown._resizing
                                    delayMs: 250
                                    anchorItem: vramSlot
                                    overlayItem: root.overlayItem
                                    // A TABLE, not a string: HoverTip's own
                                    // label measures its text as one line,
                                    // and these cells only line up if a grid
                                    // lays them out.
                                    contentComponent: vramTipContent
                                    // The label's own padding is 8 x 5; the
                                    // content path pads one number on every
                                    // side, so the grid carries the other
                                    // 3 px of width itself.
                                    contentPadding: 5
                                    fontFamily: root.fontFamily
                                    fontPixelSize: root.tipFontSize
                                    surfaceColor: root.surfaceColor
                                    bevelColor: root.bevelColor
                                    shadowColor: root.shadowColor
                                    textColor: root.primaryText
                                }
                                Component {
                                    id: vramTipContent
                                    Item {
                                        id: vramTipBody
                                        // The four slots of this tip, read
                                        // once: the cells below are its
                                        // columns, not the picker's.
                                        readonly property var slots: root._vramTipSlots(row._id)
                                        implicitWidth: Math.max(vramTipGrid.implicitWidth,
                                                                vramTipNote.visible ? vramTipNote.implicitWidth : 0) + 6
                                        implicitHeight: vramTipGrid.implicitHeight
                                                      + (vramTipNote.visible ? vramTipNote.implicitHeight + 3 : 0)
                                        // FOUR COLUMNS, EVERY CELL LEFT-
                                        // ALIGNED ON ITS OWN START, each slot
                                        // as wide as the widest string that
                                        // column can hold -- so the figures
                                        // of every row begin on one x and a
                                        // model loading under the pointer
                                        // changes digits and nothing else.
                                        // Centred figures move both ways at
                                        // once.
                                        Grid {
                                            id: vramTipGrid
                                            x: 3
                                            columns: 4
                                            columnSpacing: 6
                                            rowSpacing: 0
                                            Repeater {
                                                model: {
                                                    const rows = root._vramTipRows(row._id);
                                                    const cells = [];
                                                    for (let i = 0; i < rows.length; ++i) {
                                                        const r = rows[i];
                                                        const vals = [r.mark, r.used, r.total, r.pct];
                                                        for (let j = 0; j < 4; ++j)
                                                            cells.push({ text: vals[j], col: j });
                                                    }
                                                    return cells;
                                                }
                                                Text {
                                                    required property var modelData
                                                    // The slot: measured from
                                                    // the widest value, never
                                                    // from this cell's own.
                                                    width: vramTipBody.slots[modelData.col]
                                                    // Every column reads from
                                                    // the left of its slot but
                                                    // the share, which is the
                                                    // last: it grows LEFT so
                                                    // three digits never push
                                                    // past the tip's edge and
                                                    // two never leave a hole
                                                    // at it.
                                                    horizontalAlignment: modelData.col === 3
                                                        ? Text.AlignRight : Text.AlignLeft
                                                    text: modelData.text
                                                    color: vramTipHover.textColor
                                                    // The mark is a glyph, and
                                                    // it lives in the symbol
                                                    // font.
                                                    font.family: modelData.col === 0
                                                        ? "Symbols Nerd Font" : vramTipHover.fontFamily
                                                    font.pixelSize: vramTipHover.fontPixelSize
                                                }
                                            }
                                        }
                                        // The one line of prose: why the bar
                                        // is empty, or what the yellow means.
                                        Text {
                                            id: vramTipNote
                                            x: 3
                                            y: vramTipGrid.implicitHeight + 3
                                            text: root._vramTipNote(row._id)
                                            visible: text.length > 0
                                            color: vramTipHover.textColor
                                            font.family: vramTipHover.fontFamily
                                            font.pixelSize: vramTipHover.fontPixelSize
                                        }
                                    }
                                }
                            }
                        }

                        // PICKING DOES NOT CLOSE THE LIST. Choosing a model
                        // is a comparison, not a commit: one tries a model,
                        // reads what the pill and this row now say, and tries
                        // the next without re-opening. So the click
                        // only reports the choice; the list is dismissed the
                        // four ways a menu is dismissed anywhere -- a click
                        // outside, the pill again, Escape, and going back to
                        // typing in the prompt.
                        //
                        // AND A RIGHT-CLICK TAGS THE DEFAULT, the system
                        // update's own idiom for the same kind of choice. It
                        // does not dismiss the list either, for the same
                        // reason.
                        MouseArea {
                            id: rowArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            onClicked: mouse => {
                                if (mouse.button === Qt.RightButton)
                                    root._toggleDefault(row._id);
                                else
                                    root.picked(row._id);
                            }
                        }

                        // WHAT THIS MODEL IS FOR: the notes, to
                        // the LEFT of the drop-down. The row starts `_pad`
                        // inside the box's edge, so the gap carries the tip
                        // past that edge by the shell's tip gap -- never
                        // over the list. Nothing when the registry has
                        // nothing to say.
                        HoverTip {
                            // NOT WHILE THE BOX IS MOVING: a tip
                            // maps its anchor once, at open, and this row
                            // travels with the top edge, so a tip opened
                            // mid-flight hangs where the row was. It comes
                            // back on its own delay once the box has settled.
                            show: rowArea.containsMouse && !dropdown._resizing
                                  && root._tipOf(row._id)
                            anchorItem: row
                            overlayItem: root.overlayItem
                            side: "left"
                            gap: dropdown._pad + root.notesTipGap
                            contentComponent: notesTipContent
                            // The label's own padding is 8 x 5; the content
                            // path pads one number on every side, so the
                            // column carries the other 3 px of width itself.
                            contentPadding: 5
                            fontFamily: root.fontFamily
                            fontPixelSize: root.tipFontSize
                            surfaceColor: root.surfaceColor
                            bevelColor: root.bevelColor
                            shadowColor: root.shadowColor
                            textColor: root.primaryText
                        }
                        Component {
                            id: notesTipContent
                            Item {
                                id: notesBody
                                readonly property var notes: root._notesOf(row._id)
                                readonly property var strengths: notesBody.notes && notesBody.notes.strengths ? notesBody.notes.strengths : []
                                readonly property var caveats: notesBody.notes && notesBody.notes.caveats ? notesBody.notes.caveats : []
                                readonly property string compare: notesBody.notes && notesBody.notes.compare ? String(notesBody.notes.compare) : ""
                                readonly property string reads: root._capTextOf(row._id)
                                implicitWidth: root.notesTipWidth + 6
                                implicitHeight: notesCol.implicitHeight
                                Column {
                                    id: notesCol
                                    x: 3
                                    width: root.notesTipWidth
                                    spacing: 2
                                    Repeater {
                                        model: notesBody.strengths
                                        NoteLine {
                                            required property string modelData
                                            mark: "+"
                                            body: modelData
                                            tint: root.primaryText
                                        }
                                    }
                                    Repeater {
                                        model: notesBody.caveats
                                        NoteLine {
                                            required property string modelData
                                            mark: "−"
                                            body: modelData
                                            tint: root.faintText
                                        }
                                    }
                                    // The compare sentence, last, a
                                    // paragraph of its own.
                                    Item {
                                        width: 1
                                        height: 4
                                        visible: notesBody.compare.length > 0
                                                 && (notesBody.strengths.length > 0 || notesBody.caveats.length > 0)
                                    }
                                    Text {
                                        width: parent.width
                                        visible: notesBody.compare.length > 0
                                        wrapMode: Text.WordWrap
                                        text: notesBody.compare
                                        color: root.mutedText
                                        font.family: root.fontFamily
                                        font.pixelSize: root.tipFontSize
                                    }
                                    // What it may read, last: a fact of the
                                    // module, not of the registry.
                                    Item {
                                        width: 1
                                        height: 4
                                        visible: notesBody.reads.length > 0
                                                 && (notesBody.strengths.length > 0 || notesBody.caveats.length > 0 || notesBody.compare.length > 0)
                                    }
                                    Text {
                                        width: parent.width
                                        visible: notesBody.reads.length > 0
                                        wrapMode: Text.WordWrap
                                        text: notesBody.reads
                                        color: root.mutedText
                                        font.family: root.fontFamily
                                        font.pixelSize: root.tipFontSize
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // The list's wheel and its faded ends, the shell's one answer.
        // A SIBLING of the Flickable, never a child, and BELOW
        // the swipe capture in z: the MouseArea still reads the horizontal
        // gesture first and this only sees what it passes on. It takes no
        // input itself, so the rows are still clicked and hovered through it.
        // `ground` is the box's own fill, which is what the rows sit on.
        ScrollDressing {
            anchors.fill: list
            flick: list
            ground: root.fieldColor
        }

        // ---- The ctx row --------------------------------------------------
        // How big the CURRENT model's context is, pinned under the list and
        // separated by the shell's divider. Left: Manual | Auto, a compact
        // TabSelector in the picker's palette (same pill motion as the update
        // popup's mode selector). Right: the value, a carved fixed-slot
        // figure -- an input in manual, a read-out in auto. Both read
        // root._ctx and both are synced imperatively (a click writes
        // TabSelector.currentTab, typing writes TextInput.text -- a binding
        // would be severed on first use, so Connections restore instead).
        Divider {
            id: ctxRule
            anchors.top: list.bottom
            anchors.topMargin: dropdown._gap
            visible: root._ctxRowVisible
        }

        Item {
            id: ctxRow
            visible: root._ctxRowVisible
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: dropdown._pad
            anchors.rightMargin: dropdown._pad
            anchors.bottomMargin: dropdown._pad
            height: dropdown._ctrlH

            PickerTabs {
                id: ctxToggle
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                // THE TOGGLE TAKES THE ROW. A fixed width would leave a gap
                // between it and the figure slot that reads as a mistake, not
                // as breathing room. The field keeps its fixed slot (74, so
                // the digits never move) and the toggle takes everything else
                // bar one gap, which is the shell's 12: at the default
                // 268-wide list that is 248 - 74 - 12 = 162. The floor keeps
                // it sane if a host ever opens a narrow list.
                width: Math.max(104, ctxRow.width - ctxFieldBox.width - 12)
                tabs: [{ id: "manual", label: "Manual" }, { id: "auto", label: "Auto" }]
                // The wheel belongs to the list above; the toggle answers
                // clicks only.
                swipeEnabled: false
                // The INACTIVE tint dims to faint when auto is refused: the
                // only inactive label then IS "Auto" (the pill is parked on
                // Manual), so the dim lands exactly on the disabled stage.
                textColor: root._ctxAutoSupported ? root.primaryText : root.faintText

                onTabChanged: id => {
                    if (!root.service || !root._ctx)
                        return;
                    if (id === "auto" && !root._ctxAutoSupported) {
                        // Belt and braces -- autoBlock eats the click first.
                        ctxToggle.currentTab = "manual";
                        return;
                    }
                    if (id !== String(root._ctx.mode)
                            && typeof root.service.setCtxMode === "function") {
                        root.service.setCtxMode(root.current, id);
                        root._refreshCtx();
                    }
                }
                Connections {
                    target: root
                    function on_CtxChanged() {
                        const m = root._ctx ? String(root._ctx.mode) : "manual";
                        if (ctxToggle.currentTab !== m)
                            ctxToggle.currentTab = m;
                    }
                }
            }

            // Hover and the refusal, over the toggle: the HoverHandler names
            // the control; the MouseArea covers the Auto half only while auto
            // is unsupported, eats the click and explains itself. Handlers on
            // a sibling overlay because TabSelector owns its own innards.
            Item {
                anchors.fill: ctxToggle
                HoverHandler { id: ctxToggleHover }
                MouseArea {
                    id: autoBlock
                    x: parent.width / 2
                    width: parent.width / 2
                    height: parent.height
                    enabled: root._ctxRowVisible && !root._ctxAutoSupported
                    hoverEnabled: true
                    onClicked: { /* swallowed: auto is refused for this model */ }
                }
                HoverTip {
                    show: ctxToggleHover.hovered && !autoBlock.containsMouse
                    anchorItem: ctxToggle
                    overlayItem: root.overlayItem
                    text: "how the context size is set"
                    fontFamily: root.fontFamily
                    surfaceColor: root.surfaceColor
                    bevelColor: root.bevelColor
                    shadowColor: root.shadowColor
                    textColor: root.primaryText
                }
                HoverTip {
                    show: autoBlock.containsMouse
                    anchorItem: autoBlock
                    overlayItem: root.overlayItem
                    text: "does not fit in VRAM"
                    fontFamily: root.fontFamily
                    surfaceColor: root.surfaceColor
                    bevelColor: root.bevelColor
                    shadowColor: root.shadowColor
                    textColor: root.primaryText
                }
            }

            // The value: a carved fixed-slot figure. The slot never resizes
            // with its content; digits sit right-aligned against the box's
            // edge. In auto the field is a dimmed read-out -- no carved focus,
            // no I-beam -- showing the tuned value, or an ellipsis while the
            // tuner runs.
            Item {
                id: ctxFieldBox
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: 74
                height: dropdown._ctrlH

                property real _focusF: ctxField.activeFocus ? 1 : 0
                Behavior on _focusF { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

                ShadowBox {
                    anchors.fill: parent
                    baseRadius: 8
                    surfaceColor: root.fieldColor
                    backgroundColor: root.headerBoxColor
                    bevelColor: root.bevelColor
                    // Focus lives in the inset shadow, the same place a
                    // category's colour lives -- eased as a fraction, mixed.
                    shadowColor: Mix.c(root.shadowColor, root.accent, ctxFieldBox._focusF)
                    bevelWidth: 1
                    shadowWidth: 3
                }

                TextInput {
                    id: ctxField
                    Keys.forwardTo: [ctxFieldKeys]
                    EditKeys {
                        id: ctxFieldKeys
                        target: ctxField
                        selectAll: true
                    }
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    clip: true
                    verticalAlignment: TextInput.AlignVCenter
                    horizontalAlignment: TextInput.AlignRight
                    enabled: root._ctxManual
                    readOnly: !root._ctxManual
                    color: root._ctxManual ? root.primaryText : root.faintText
                    selectionColor: root.accent
                    selectedTextColor: root.textOnAccent
                    font.family: root.fontFamily
                    font.pixelSize: 11
                    validator: RegularExpressionValidator { regularExpression: /[0-9]{0,7}/ }
                    inputMethodHints: Qt.ImhDigitsOnly
                    text: root._ctxDisplayValue()

                    function commit() {
                        if (!root.service || !root._ctxManual
                                || typeof root.service.setCtxValue !== "function")
                            return;
                        if (ctxField.text === root._ctxDisplayValue())
                            return;             // unchanged, or an escape revert
                        const v = parseInt(ctxField.text, 10);
                        if (isNaN(v)) {
                            ctxField.text = root._ctxDisplayValue();
                            return;
                        }
                        root.service.setCtxValue(root.current, v);
                        // The service clamps and rounds; show its truth, not
                        // the keystrokes.
                        root._refreshCtx();
                        ctxField.text = root._ctxDisplayValue();
                    }

                    Keys.onPressed: function (event) {
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            ctxField.commit();
                            ctxField.focus = false;
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Escape) {
                            ctxField.text = root._ctxDisplayValue();
                            ctxField.focus = false;
                            event.accepted = true;
                        }
                    }
                    onActiveFocusChanged: if (!ctxField.activeFocus) ctxField.commit()

                    Connections {
                        target: root
                        function on_CtxChanged() {
                            if (!ctxField.activeFocus)
                                ctxField.text = root._ctxDisplayValue();
                        }
                    }
                }

                MouseArea {
                    // Cursor only; the field handles its own mouse.
                    anchors.fill: parent
                    acceptedButtons: Qt.NoButton
                    cursorShape: root._ctxManual ? Qt.IBeamCursor : Qt.ArrowCursor
                }

                HoverHandler { id: ctxFieldHover }
                HoverTip {
                    show: ctxFieldHover.hovered && !ctxField.activeFocus
                    anchorItem: ctxFieldBox
                    overlayItem: root.overlayItem
                    text: root._ctxManual ? root._ctxManualTip : root._ctxAutoTip
                    fontFamily: root.fontFamily
                    surfaceColor: root.surfaceColor
                    bevelColor: root.bevelColor
                    shadowColor: root.shadowColor
                    textColor: root.primaryText
                }
            }
        }
    }
}
