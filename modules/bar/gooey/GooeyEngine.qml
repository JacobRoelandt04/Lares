pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "GooeyGeometry.js" as Geo
import "GooeyRipple.js" as Ripple
import "GooeyAura.js" as Aura
import "../../common/scroll"

// =============================================================================
// GooeyEngine.qml -- the bars and their popups, as one surface.
//
// Every bar and every popup is a BODY: a box. GooeyField draws all of them as
// one signed-distance surface, so a popup grows out of its bar with concave
// fillets, necks before it touches, rides around a screen corner onto the next
// bar, and a secondary popup grows out of an open one the same way -- all from
// the same rules (GooeyGeometry.js, shaders/gooey_field.frag).
//
// What this file does is TIME AND PLACE: where each body's box is on this
// frame. Every motion is ONE clock (GooeyBody.t) and a box read off it, so a
// retarget restarts one number, nothing is ever animated by two Behaviors that
// can disagree, and at rest nothing runs.
//
//   field (z 0)       GooeyField, every body
//   popup content     one clipped host per slot (GooeyBody)
//   flourish content  the flourish's host (overLayer: above every popup, no input)
//   bars (z 2)        GooeyBar and their modules, the default content
//
// THE POPUP. There is one (`thePopup`), owned by whichever module opened it
// last. Opening it from a module on another bar MIGRATES it -- along the edge,
// or around the screen corners through the bars between -- and when there is
// no chain of bars to travel along, the old one closes in place while a fresh
// one opens at the destination. A second slot exists only for that.
//
// THE SECONDARY POPUP (child). openChild() grows a box out of the primary's
// side, centred on a point of the primary's content, and keeps it attached to
// the primary's CURRENT box every frame. Content can ask for one without
// knowing about the engine through the content contract (below).
//
// THE CHILD CHAIN (a tray menu's submenu is a popup out of
// the menu, as the menu is out of the strip). A child may have a child of its
// own, and so on down `childPopups` -- [childSlot (the secondary), the
// tertiary, the quaternary]: N levels, as many as there are slots declared
// (one more is one more GooeyBody in that list). Every level is placed, drawn,
// joined and timed exactly as the secondary is, against its PARENT's box; a
// child's content speaks the same contract a primary's does to open the next
// level (its owner id is the parent's + "/secondary") -- with one name changed:
// a child's own `secondaryKey` is the engine's (the key IT shows), so it names
// its child's key `secondaryChildKey`; closing a level closes
// every level below it first, one after the other (A CHAIN CLOSES IN SEQUENCE,
// below); and the lane, the OSD and the rules that keep
// out of thePopup's way treat thePopup and ALL its live descendants as one.
// The field relates a child to its parent alone (GooeyGeometry: HOST AND
// GUEST, by `parent` id), so a level touching another level's sibling melts
// with nothing. With no level below the secondary out, the chain adds no
// body, index or uniform to the field.
//
// THE CONTENT CONTRACT. A primary's content item MAY declare
//
//     property Component secondaryComponent   the detail view
//     property bool   secondaryOpen           open it / close it
//     property point  secondaryAnchor         where, in the content's coords
//     property string secondarySide           "far" | "start" | "end" | edge
//     property bool   secondaryOverhang       may hang past the primary's side
//     property real   secondaryInset          how far it reaches INTO the
//                                             primary (px); the overlap is the
//                                             primary's
//     property var    secondaryKey            what it shows; a change while
//                                             open slides and swaps
//     property bool   secondaryPersistent     the secondary comes back with
//                                             its popup (below); default false
//     property real   secondaryAnchorAt       0..1, default 0.5: WHICH point of
//                                             the child sits on the anchor along
//                                             the side -- 0 its start, 1 its end.
//                                             That point holds still when the
//                                             child's size changes (a label growing
//                                             into a menu grows away from its top,
//                                             one clock, nothing translating), and
//                                             the open grows out of it
//     property real   secondaryWidthFrom      0..1, default childWidthFrom: the
//                                             share of its length the child opens
//                                             at, about that point. 0 with an
//                                             anchor at the start: the child grows
//                                             in 2D out of the corner its start
//                                             makes with the parent's side -- one
//                                             flush against the bar face grows out
//                                             of the inner corner of bar and parent,
//                                             part of both from the first frame
//     property real   secondaryOpenAt         0..1, default secondaryAnchorAt:
//                                             the point of the child its OPEN
//                                             grows out of, where that is not the
//                                             point it is held by (a submenu held
//                                             level with its row, opening about
//                                             its own centre)
//     property real   secondaryOpenMin        px, default 0: the least length
//                                             along the side the open starts at.
//                                             A child no longer than that has its
//                                             whole length from the first frame and
//                                             only slides out of its parent (a
//                                             one-row submenu)
//
// A PERSISTENT SECONDARY. The content owns what it shows, so it is the content
// that remembers it was open (a module's state, across boots if it likes) and
// comes up with `secondaryOpen` already true. What the engine owns is WHEN:
// instead of growing out of a popup that is itself still growing, the child is
// held back and opens on the mirror of the close. A close runs the secondary
// first and releases the popup when the secondary is `closeChildLead` of the
// way in; the secondary's last stretch then plays while the popup starts. Played
// backwards, the popup opens first and the secondary comes out when the popup is
// `closeChildLead` of the way OUT, so its first stretch plays while the popup
// lands. That is the popup's DRAWN extent, not its clock: an OutBack is full size
// at 45 % of its clock and spends the rest settling, and a secondary started
// "a lead before the clock's end" came out 175 ms after the popup had landed --
// two motions in a row where the close is one. A popup closed while its child is held back simply never
// opens it. Without the flag nothing changes: a content that loads with
// `secondaryOpen` true opens its child at once.
//
// A CHAIN CLOSES IN SEQUENCE: a tertiary closing under a secondary that is closing as
// well would visually disconnect. Closing a level with levels still
// out below it closes the DEEPEST first, on a clock that fits a third of the time the
// close has (`childMs`; a travel's `migrateMs`), and holds every level above at its
// full box -- content showing, attached to what carries it, so it travels with the
// primary -- until the level below is `closeChildLead` of the way in; each level then
// runs on a third of what is left, the topmost on all of it (two levels: 1/3, 2/3).
// `closeChild(owner, { sequenceMs })` asks for another window; a close with a single
// level out is the plain close.
//
// and the secondary's root MAY declare `property var secondaryKey`, which the
// engine assigns when its content is hidden (on load, and between the fade out
// and the fade in of a swap), `function secondarySwapsInPlace(key)`, true for a key the
// content will swap to itself: the engine then skips its fade and assigns the key at once, with the content
// in full view, and the content fades what it wants faded (SwapCurtain; a chart morphing into the next
// stock is the reason), `property rect secondaryCutout`, which it keeps
// set to the part of the secondary its primary covers (secondary coordinates),
// so an inset secondary can lay its content out around it, and `property bool
// secondaryMoving`, true while the secondary's box moves (opening, closing,
// sliding to a new anchor, easing a resize) -- the content holds its expensive
// work until it rests (the stocks detail's chart: rebuilt mid-slide it costs a
// missed frame on every swap). The engine never writes a property of the
// primary's content. Content may also declare `swipeGestureActive` with
// `gestureHoldWidth`/`gestureHoldHeight`; while the gesture is live the input
// mask is held at least that large. And because a body CLIPS its content, a
// wheel that lands in the held area but outside the body reaches nothing in
// it (Qt 6 delivers no pointer event to a clipped child outside the clipping
// item's rect), and one that lands on ANOTHER body is read by that body's
// content. Content that also declares `function gestureWheel(event)` is handed
// every wheel that lands OUTSIDE its body -- { x, y (content coordinates),
// angleDelta, pixelDelta } -- for as long as its gesture is live, over nothing
// or over another body alike; inside its body its own readers hear the event
// as always. That is what keeps a swipe going when the view shrinks out from
// under the fingers (WeatherPopup, WeatherDetail).
//
// A POPUP'S OWN RATIO (shell.jsonc `scale.popups.<owner>`): `popupScales` { ownerId: ratio } puts one popup's content under a ratio of
// its own -- the same machinery, per body (GooeyBody.ownScale: its entry over `popupRatio`) -- so its box, its radius and its textures
// (`primaryScale`) follow, and a travel between two popups of different ratios aims at the box the destination will have (the remembered
// size carries the ratio it was laid out under). A popup's DETAIL (every child level of it: its secondary, that secondary's own, and the
// reel's chain under the tray's strip) has a ratio of its own too, the entry `"<owner>.detail"`, and with no entry the plain popup
// ratio -- never its parent's (a board read at 1.35 does not make its tuning card 1.35: GooeyBody.ownScale). A child's content that
// declares a `renderScale` is handed its own (`detailRenderScale`), so its textures are made at the ratio it is drawn at.
//
// THE RATIOS (shell.jsonc `scale.bar` / `scale.popup`). The engine works in its FRAME's
// units. A host that draws the popups (and the bar) a little larger or smaller than the rest says so with `popupRatio` and
// `barRatio` (1 and 1, the default and every mockup's, draws the engine at its design size, to the byte), and every body hosts its content in a
// ScaleRoot of ITS ratio (`GooeyBody.ratio`: the bar's for a primary whose content continues its bar cell, `continuesBarCell`, the
// popup's for every other): the content is laid out in its OWN units, `ratio` times smaller than the box that holds it. So every
// number that crosses between a content and the engine is converted, in one place each, and nothing else knows:
//   content -> engine  (x ratio)   implicitWidth / implicitHeight (and any size a caller asks: open()'s w and h), `alongShift`,
//                                  `secondaryAnchor`, `secondaryInset`, `secondaryOpenMin` (the PARENT's units), `gestureHoldWidth` / `Height`
//   engine -> content  (/ ratio)   `hostRoom` (every length and position in it, and `restAt`'s arguments and answer), `secondaryCutout`
//                                  (the secondary's units), `popupRadius`, `popupCornerRadii` (the primary's), the mouse positions
//                                  `gestureWheel` is handed (mapped through the scaled content, so it needs nothing)
// The engine's own lengths follow the popups' ratio -- `blendRadius`, `attachDistance`, `snapDistance`, `flushSnap`, `stretchMax`,
// `tintBlend` are DESIGN values and the geometry reads their `_` twins (but for `blendRadius`: below) -- and every body's corner radius is `maxR` x its own ratio
// (a bar's `barRadius`: x `barRatio`), so a popup's fillet keeps the shape it has at ratio 1. Where the two ratios differ the join
// of a popup to its bar is drawn with the popup's constants: the surface is one, and one fillet can be one size. `maxR` itself is
// the design number a content reads (NotificationsBarOwner: its card's radius). `blendRadius` is the JOINT -- the circle every concave
// corner of the surface is drawn with: where two bars meet, where a popup's neck leaves its bar -- and the host sets it, in the frame's px,
// so that the circle it draws on the glass is as big as a tiled window's outline (Hyprland's rounding + border_size, in compositor px:
// ShellFrame.jointRadius, HyprJoint.js); it is not a popup's or a bar's, so neither ratio scales it. `renderScale` is device px per popup CONTENT px
// (the host's frame scale x popupRatio); `frameRenderScale` and `barRenderScale` are the other two.
//
// THE LIVE CONTRACT: a content the user resizes and colours by hand (the notes
// popup). Every member is optional and looked up with `in`; a content without
// them is placed and drawn by the plain rules, to the byte.
//
//     property bool   liveResizeActive      content-owned. While it is true on
//                                           the PRIMARY's content and that popup
//                                           is open (or easing a resize or a
//                                           shift -- never on a migration), every
//                                           implicitWidth / implicitHeight /
//                                           alongShift change is FOLLOWED: the
//                                           box is its target on the frame the
//                                           change is drawn in (no ease, phase
//                                           "open", no content clip, corners at
//                                           maxR), and the input mask is the WHOLE
//                                           engine (liveResizeMask), so a drag
//                                           outward never loses the pointer; back
//                                           to the exact box when it ends, and
//                                           that box is placed then (THE WALL:
//                                           never mid-drag). The
//                                           changes a frame collects (a drag
//                                           writes width, height and shift one
//                                           after another) are laid out ONCE, in
//                                           that frame's polish (`followHook`):
//                                           read hostRoom's a0/a1 on the next
//                                           event, not in the same handler that
//                                           wrote the size.
//     property string liveResizeMask        content-owned: what the input mask is
//                                           while liveResizeActive holds.
//                                           "engine" (the default, and any other
//                                           value): the WHOLE engine, told to the
//                                           compositor twice (on and off) -- for
//                                           a drag, whose pointer may leave the
//                                           box. "box": the popup's CURRENT box,
//                                           followed every frame like the box
//                                           itself -- for a content that moves
//                                           its own size (a list animating its
//                                           rows: the notifications manager),
//                                           where a whole-engine mask would swallow
//                                           the clicks meant for other windows
//                                           for as long as the rows moved (up to
//                                           660 ms). A change while live applies
//                                           on that frame.
//     property real   alongShift            content-owned: screen px along the
//                                           bar's SCREEN axis (x on a top or
//                                           bottom bar, y on a left or right one;
//                                           + is +x / +y on screen), added to the
//                                           placement centre before the clamp to
//                                           the edge (and THE WALL, which may
//                                           move the box further). Outside a live
//                                           resize a change eases like a resize;
//                                           the open grows out of the shifted
//                                           centre.
//     property var    hostRoom              HOST-assigned, if declared: a new
//                                           object only when a value changed
//                                           (see _roomOf): the edge, the anchor
//                                           `center` WITHOUT the shift, the
//                                           usable `lo`..`hi` the placement clamps
//                                           to, the most the popup may reach
//                                           `out` of its bar, the box's actual
//                                           `a0`..`a1` (the clamp and THE WALL
//                                           may have moved it), the bar
//                                           `face` it hangs from -- engine
//                                           coordinates, along the edge's screen
//                                           axis (`face` on the other one) --
//                                           `wallLo`/`wallHi` (a bar stands at
//                                           lo / hi), `snap` (snapDistance),
//                                           and `restAt(along, shift)` ->
//                                           { a0, a1 }: where the engine WOULD
//                                           rest a box of that size and shift
//                                           now, by the placement itself (the
//                                           clamp, THE WALL, THE BAR'S END),
//                                           so a content that animates its own
//                                           box lands where it will rest and
//                                           never mirrors the rules.
//     property color  surfaceTint           content-owned: the FINAL colour of
//                                           its popup's surface (invalid or alpha
//                                           0: none), poured across the join into
//                                           the untinted bar over `tintBlend` px
//                                           (GooeyField: TINTS). Any slot's
//                                           content may carry one -- a secondary
//                                           its own, a popup closing in the spare
//                                           slot the one it had.
//     property string keyboardFocusRequest  content-owned: "none" | "onDemand"
//                                           | "exclusive". `popupKeyboard` is the
//                                           open primary's, else "none"; a host
//                                           binds its layer's keyboard focus to it.
//     property bool   pointerHidden         content-owned, optional: true = the pointer is not shown while this content is the
//                                           open primary (the bridge's free look). `engine.pointerHidden` is the open primary's;
//                                           the host's cursor cover follows it (modules/shell/cursor).
//     function handleEscape(): bool         content-owned, optional: Escape pressed while this
//                                           content is the open primary (the shell binds the key while a popup holds
//                                           the keyboard; `pressEscape()` below). true = the content took it (an editor
//                                           saved, a menu closed, a query cleared) and the popup STAYS; false, or no
//                                           such function, = the popup closes. The clipboard's and the launcher's run
//                                           their whole Esc chain through it. A content with a DETAIL (its secondary)
//                                           does not put the detail away here: that is the engine's choice (next).
//     function stepBack(): bool             content-owned, optional: put the content's detail away (its secondary, the
//                                           one level a popup keeps beside it); true when there was one. Asked on
//                                           Escape, after handleEscape() answered false, ONLY while `escapeDetailFirst`
//                                           (shell.jsonc `"escape": "detail"`); by default one press closes the popup
//                                           and its detail together, the same way in every popup.
//     property bool   maskCatchAll          ANY slot's content (the lane, a primary,
//                                           a child): true = the input region also
//                                           takes the whole track (one more rect),
//                                           so a press anywhere reaches the shell
//                                           (the auth prompt's outside click; a
//                                           menu dismissed by a click in the void,
//                                           as waybar's are). A press that lands on
//                                           NO body and no bar reaches the VOID
//                                           CATCHER, which calls the content's
//                                           `function outsidePress()` when it
//                                           declares one. Read live; a change
//                                           re-lays out.
//     property bool   continuesBarCell      content-owned: the popup CONTINUES
//                                           its module's cell in the bar (the
//                                           reel: the ring runs straight through
//                                           from the cell into the strip), so it
//                                           rests exactly on its anchor -- the
//                                           clamp to the edge only; THE WALL and
//                                           THE BAR'S END never move it (they
//                                           would move the reel's strip 20 px off its
//                                           cell beside a side bar, 3 px at a
//                                           bar's end). The field still draws a
//                                           face near a wall pulled toward it.
//     property bool   revealOnOpen          content-owned (a primary's or a child's):
//                                           true = laid out at its rest box, where it
//                                           rests, for the whole of an open and a
//                                           close -- the growing box reveals it, the
//                                           shrinking one hides it (THE REST FRAME).
//                                           Read live.
//     property real   openOvershootCap      content-owned, optional: the cap of this
//                                           content's open swell, in its units (THE
//                                           OVERSHOOT'S BIAS); 0 = proportional to
//                                           the travel (the old engine: no cap and no
//                                           area budget). Absent: the engine's. Read
//                                           when an open starts.
//
// THE LANE ("theNotification"). A fourth slot beside the popup's two and the
// child: a popup of its own that a module keeps out WHILE thePopup comes and
// goes (the notifications' toast stack). It is never the primary or the spare
// and has no secondary; its content speaks the same contract as a primary's
// (implicit size on the resize clock, the swipe hold and gestureWheel,
// keyboardFocusRequest, hostRoom, surfaceTint), without the live resize.
//
//     openLane(ownerId, barId, localCenter, w, h, cornerAnim2D, component, widthFrom, alongAt)
//                               -- alongAt (0..1, default 0.5): localCenter is the
//                                  point at that fraction of the lane's own length
//                                  along the TRACK (0 its start, 1 its end), so a
//                                  lane at a bar's end keeps that end as its
//                                  content grows (a stack at a corner, or a
//                                  point along a bar: NotificationsBarOwner's
//                                  spot); a 2D open of a lane held at an end
//                                  grows out of that end. Asked for on another
//                                  bar while out, it folds in where it is and
//                                  opens there -- a box does not glide between
//                                  bars.
//     closeLane()               -- the close starts at once, gesture or not (when
//                                  the last toast leaves, the close starts
//                                  immediately); while its content's
//                                  swipeGestureActive is true only its END waits
//                                  for the fingers to lift -- the content stays
//                                  loaded and the input hold stays, so the rest of
//                                  the swipe is still the stack's).
//                                  So does every other close of the lane under a
//                                  live gesture (a hop's fold, a fold for room):
//                                  a hop opens on its new bar after the lift
//     laneOpen, laneOwnerId, laneBlocked, laneBlockedReason ("" | "room" |
//     "budget": THE BUDGET, below), laneKeyboard, keyboardFocus (the
//     stronger of popupKeyboard and laneKeyboard), laneMelt, laneGlideMs,
//     laneRequestOwner (whose request the engine holds, "" none: out, folded
//     away waiting for room or for a body, or hopping -- an owner keeps it equal
//     to what it wants, so a request left behind while blocked never opens an
//     empty lane)
//
// It opens and closes on its own clock exactly as a primary does (2D out of a
// corner as a point). Where thePopup (or its child) will be is where it may not
// be: at every change of thePopup's TARGET -- an open, a retarget, a migration's
// start, a close -- and of its own request or size, Geo.lanePlace puts it flush
// beside that target on the side facing its own spot, else on the other side,
// else nowhere (`laneBlocked`: it folds away and waits, the owner holds its
// content), and it eases there on ONE clock (`laneGlideMs`; a resize of thePopup
// moves it on thePopup's own resize clock, so the two faces move as one). It is
// never re-placed per frame. The two MELT (the field's PEERS): touching, a
// fillet at the free end, a seam over the contact, the channel on the bar closed
// by the joins' own facing fillets.
//
// NO CONTENT OVERLAP, ON ANY FRAME: the lane has the right of way. Every other
// slot is kept on its own side of the lane's CURRENT box along the lane's bar
// (GooeyBody.laneSide, fixed at each placement; Geo.laneClip on every frame),
// wherever the two share the band across. So thePopup's OutBack overshoot stops
// at the lane's face, a popup opening onto the lane is born empty and grows out
// behind it as it glides aside, and a lane gliding back through a closing popup
// sweeps it away -- continuously, because a box is only ever cut at a face that
// moves continuously. Nothing ever passes THROUGH the other: a migration that
// would carry thePopup through the lane closes in place and opens at its
// destination instead (the pathless jump), and a lane whose new place is on the
// far side of a popup that is out folds into its bar and opens there (a hop).
//
// THE OSD SLOT ("theOsd"). A fifth slot: a transient popup of its own that comes out
// of any bar when something changes (volume, brightness, ...) and DIPS -- folds into
// its bar and rises again with other content -- when the kind changes while it is out.
// It lives shorter than anything it meets, so IT yields: it glides to
// the free place nearest its home beside thePopup, its child and the lane
// (Geo.yieldPlace), else the lane is displaced around it, else thePopup is pushed along
// its bar (GooeyBody.osdYield), else it waits (osdBlocked). Every frame it is clipped
// against every other slot (Geo.laneClip), so a popup's OutBack overshoot squeezes the
// OSD and never the reverse, and it melts with the neighbours it lies flush against on
// its own bar (the field's PEERS, a list). It is the last slot in the field's body list
// before the flourish: with none out it adds no body, index or uniform.
//
//     openOsd(ownerId, barId, along, w, h, component, opts)   opts { alongAt, widthFrom, key, tucked }
//                               -- along: bar-local px (open's localCenter), alongAt the
//                                  fraction of its length that sits there; w / h null
//                                  follow the implicit size. The same component and key
//                                  while out: in place (the size follows on the resize
//                                  clock). Another component or key: a dip. Another bar:
//                                  a hop (a dip whose rise opens fresh on the new bar)
//                               -- tucked: THE TUCK. The OSD sinks into its bar until
//                                  `osdTuckPx` of it stands out (the close's clock, its
//                                  content fading) and is placed as that sliver; asked
//                                  again untucked it rises (the dip's rise). The content
//                                  is kept and runs on underneath. At rest a sliver on a
//                                  thin bar is hovered over the bar beside it too
//                                  (`osdTuckZone`, the owner's hover: the screen's edge
//                                  is the easy target, 3 px of sliver are not)
//     closeOsd(opts)            -- opts { ms, easingIndex }
//     signal osdSwap(ownerId, key)   the bottom of a dip, BEFORE the component is set
//     osdOpen, osdOwnerId, osdRequestOwner, osdBlocked, osdBlockedReason ("" | "room" |
//     "budget"), osdPhase (closed | opening | open | moving | dipping | closing), osdKey,
//     osdStats, theOsd; tunables osd* below; osdPoseBox (debug: draw it at this box)
//
// THE LANE GIVES WAY. The lane has the right of way over a popup that stands still -- until it
// is the one that is leaving. A stack FOLDING FOR A POPUP (a hop to the other side of it, below to beside and back, no room left:
// `GooeyBody.hopFold`) does not cut the popup to its side: the popup draws exactly the box it has with no stack at all (held
// at the stack's face for the whole fold -- 200 px of height, 390 of width -- it would jump the frame the fold ended), and the stack is
// cut to the popup's DRAWN box instead, on its own side (`Geo.laneClip`, the same continuous cut turned round): folding anchored at the
// edge that touches the popup, which follows the popup's face. And a stack hung from a popup that CLOSES FOLLOWS ITS DRAWN FACE to the
// end (`_laneFollow`): a glide to its home on a clock of its own (OutCubic against the popup's OutBack) would leave a gap near the
// end, so the stack's near face IS the popup's drawn one, down to the bar, and only then glides the rest of the way home (the
// player's gap case: first in y to the bar, then in x into the joint).
//
// THE FLOATING POPUP. A popup that opens with no shell to hang from is a pill like the OSD: it exists on its own, attached to nothing,
// floating around the same areas where it would normally appear; when the shell is back it reattaches seamlessly, with a small
// translation. The rule keys on ONE fact, read when a popup OPENS: `floatWanted`, no shell to hang from -- this screen's focused
// window is fullscreen (`fullscreenHere`) or the bars are hidden (`barsHidden`; the popups of a hidden shell look exactly the same as the
// fullscreen ones) -- not on the module, so a key that opens a popup tomorrow gets it for free. Such a popup is `floating`: it stands
// `floatGap` off the SCREEN's edge it would hang from and at least that far off the other three (the toast pill's margin, the same for
// every one of these popups; `_floatDelta`, the whole body shifted, `floatF` x the
// shift), is drawn as a FREE body (no join with a bar,
// no snapping: a pill of the shell's material), and its children with it. The host puts its window on the Overlay layer while one is out
// (`floatOverlay`) and draws the bars away (the pill is alone on the video). With the bars hidden over ordinary windows the window on Top would
// show it as well, but a window that goes fullscreen under it is told to the shell after it happened, and on Top the popup would be gone for one frame of that. When `floatWanted` goes false it slides home
// on `floatSlideMs` (`floatF` 1 -> 0, one clock) and is an ordinary popup again (one that stands over a window going fullscreen, or back, with the bars
// hidden, stands where it stands: the fact has not changed); one that opens with `floatWanted` false never floats, whatever happens to the window
// later. Popups in front of a window that goes fullscreen stay where they are.
// THE WAY HOME: a popup sliding home is free until `floatF` is `floatJoinAt`, and from there its joins come in with the slide (`join` on the body, 0 .. 1, GooeyGeometry.js), so it
// reaches its bar joined; freed at the end of the slide instead, its corners against the bar turned into the join in one frame (a pop at the end of a motion that had all but stopped).
// The bars leave the screen's edge on a clock of their own and a floating box stands `floatGap` off the edge WHATEVER the bars' thickness, so with the bars waiting for the window to be
// lowered (`floatHomeWaitMs`, the host's) the slide waits too: gone ahead of them it would first run towards the edge they have not left yet, 7 px the wrong way.
// NOTHING TRAVELS OVER A FULLSCREEN WINDOW, nor with the bars hidden: without the context the rest of the shell provides, a translation
// looks out of place, so a popup that must move closes and reappears where it is needed. While `floatWanted`, a change of owner
// closes the old popup where it is and only then opens the new one in the other slot: `_openFresh(..., after)` makes the new one the primary AT ONCE
// (its content, its keys, Escape, `popupOwnerId`: the owners see an ordinary open, nothing is pending anywhere) with its body held at its origin
// (`openAfter`: no clock, no fade, nothing drawn), and the first frame the old one has no drawn area left starts it (`_releaseOpenAfter`, on the drawn
// extent: an OutBack close has gone at 45 % of its clock, and waiting for the clock's end would be 220 ms of an empty screen). A held popup has not
// been seen, so what comes next is free: asked away it goes at once (close()), replaced it takes the next owner's place in the same wait
// (_openPrimary), the same owner again is an ordinary resize, and the shell coming back starts it docked, now. A popup asked for while a
// floating one closes waits the same way. A popup that was out DOCKED when the window went fullscreen stands under that window, seen by nobody: it
// goes in one step and the new one floats at once. A popup sliding home (`floatWanted` false, `floating` still true) travels: the shell is back.
//
// THE REEL SLOT ("theReel"). A sixth slot: the power and idle reels' strip -- and the tray's (WindowTrayOwner: "the type of
// popup used for the reels", not a reel) -- a body of its own so that hovering a reel's cell, or the window title, never
// migrates or shuts whatever popup is out. It is a primary-class body of its own that continues
// its module's cell in the bar (`continuesBarCell`: pinned on its anchor, no wall, no bar's end) and comes and goes with
// the pointer on that cell WHILE thePopup is out -- the primary is never touched. ONE reel at a time: another reel's cell on
// the same edge travels the strip along the bar (the primary's own migration along one edge, same clock), another edge folds it
// and opens it fresh. It does not move for anything: the strip IS its cell's continuation, and a strip that stood off its cell
// would have no ring to belong to. What is in its way gives way instead -- the lane (the toasts) and the OSD place themselves
// around its target as they do around a popup (`_laneObstacles`, `_osdObstacles`), and thePopup, which may stand under it (the
// notes and the LLM hang from the left bar into the very corner the reels open in), is simply UNDER it: the strip's body is the
// topmost host and its content paints an opaque ground (IconReelView.opaque), so it reads as a card laid over the popup and
// the popup's own content is never cut or pushed. The field relates two popups to nothing but their bar, so the surfaces just
// unite.
//
//     openReel(ownerId, barId, localCenter, w, h, component, widthFrom)   as open() (never 2D)
//     closeReel(opts)         opts { ms, easingIndex, overshoot } as close()
// THE REEL'S CHAIN ("reelChildPopups", "theReelChild" its first level): the strip has a child chain of its own, as deep as the
// tray needs -- the idle reel's reason is level 1; the tray's label or menu, its submenu and that submenu's submenu are levels 1
// to 3 -- opened with openChild(<the parent's owner>, ...) or by the strip's / a level's content through the secondary contract
// (_syncSecondary takes the strip), closed with closeChild(<its owner>): placed, drawn, joined and timed exactly as thePopup's
// chain is, against the strip's box (a chain closes IN SEQUENCE, the deepest first). Its own slots, never the primary's chain: a
// strip that comes out over a popup must not take that popup's secondary away. The strip closing closes its chain first and holds
// until level 1 is mostly in; the strip going to another owner closes it at once (on the travel's clock). The lane and the OSD go
// round every level as round the strip. THE KEYS: the strip's content may ask for the keyboard (`reelKeyboard`, part of
// `keyboardFocus`: a tray menu), and while it does it answers Escape first (`pressEscape`), so the popup under it stays.
// THE REEL PASS: the strip and every level are cards over the popup under them, and the field, which is ONE surface under every
// content, draws a card inside a popup as nothing at all -- no ground over the popup's content, no fillet where the strip leaves the
// bar, no ring, no halo (it draws both only outside its union). ReelCast draws all four with the field's own shader baked a second time
// (gooey_field.frag, THE REEL PASS) from the field's own shape of the same frame: every layout says which bodies are the reel group,
// which the bars and which the popups (`reelCast.plan`, before the field is handed its bodies), and the field feeds the pass each
// shape it draws (GooeyField.shapeTap). Between the popups and the reel slot: the FILL is the cards' ground over the popup's
// content (so a body paints none of its own), the RING and the HALO are the reel's share of the union's -- along a fillet they
// leave the strip whole and are gone where the arc lands on the bar, whose underside has neither over a popup; where the strip is
// one with a bar there is no outline and so no ring --, each body's ink its content's fade (in with an open, out with the merge into
// the bar), and all of it cut to the popups' drawn coverage, where the field's own ring takes over. With no popup under the group
// the pass has no tile and nothing moves a pixel.
//     reelOpen (live), reelOwnerId, reelPhase, reelBlocked (no free body of the field: THE BUDGET), reelChildBlocked (a level waits
//     for a body), reelKeyboard, reelRadius (the free corner's radius on this frame, in the strip content's units: the strip cuts its
//     icons to it), theReel, reelChildPopups
//
// THE BUDGET keeps the order bars -> primaries -> reel -> its chain -> lane -> OSD: the reel's bodies are laid out BEFORE the
// lane's and the OSD's, so a layout that finds more than the field draws gives the OSD's up, then the lane's (a reel is held open
// by a hand; the toast and the OSD wait), then the deepest level of the reel's chain (it goes at once and opens again when a body is
// free, _bodyFreed). A reel is refused (`reelBlocked`), and a level of its chain (`reelChildBlocked`), rather than drawn without a
// surface. With the tray in the reel slot the worst case is 6 bars + thePopup + its secondary + the strip + 3 levels = 12 (no
// primary's content has a third level since the tray left thePopup); only a spare closing while a popup changes owner makes 13,
// and then the tray's deepest menu waits for it.
//
// THE BUDGET (the field's body limit). The field draws GooeyField.maxBodies (12) bodies: every
// bar with an area, every slot that is not "closed" -- the primary, the spare, the child chain's
// levels, the reel; a slot closing is still a body --, the lane, the OSD, and the flourish and droplets only
// if room. Past 12 the field draws the first 12 and the last lose their surface while their content
// and input rect stay: the shell's six bars + primary + spare + three child levels + lane + OSD are
// 13. With 12 or fewer nothing below changes a byte. The bars and the primaries come first, then
// the lane, then the OSD (the one that moves, the one that lives shortest):
//
//   - A lane or OSD asked for with no body to open into WAITS: it does not open, `laneBlocked` /
//     `osdBlocked` are true and `laneBlockedReason` / `osdBlockedReason` say "budget" ("room": no
//     room beside thePopup; "": not blocked). Its request stays -- the owner keeps asking and keeps
//     its content -- and the moment a body is free (a slot finishing its close, _bodyFreed) the
//     lane is placed again, then the OSD.
//   - The OSD holding the last body when the lane asks for one (or a lane asked for while it is
//     out and one body is left) folds on its own clock (the room's fold); the lane opens into the
//     body when the fold ends. The lane never waits behind a body that is not leaving.
//   - A body that becomes live while the lane and the OSD are out and takes the count past 12 (a
//     third child level, the spare) makes the OSD, then the lane, give its body up AT ONCE, in
//     the layout that would draw the 13th (_budgetYield): a fold animated from there would be
//     drawn without a surface, past the last body the field takes. It then waits like the above.
//
// EVERY BAR ITS OWN THICKNESS. A GooeyBar carries `thickness`, `radius` and
// `reserve` (GooeyBar.qml); `thickness` and `maxR` here are only their
// defaults. Everything placed against a bar takes THAT bar's number: a popup's
// face is its host bar's thickness, a popup at the end of an edge stays off the
// perpendicular bar there by that bar's own thickness, a migration turns each
// corner against the walls that are really there (and eases its face between
// two bars of different thickness on one edge), a secondary is kept between the
// edges' own bars, hostRoom's face and `out` are the host's and the opposite
// edge's, and `edgeReserve` is what each edge takes from the compositor. So a 6
// px bar under a 40 px one is one property, not an engine of its own.
//
// A bar's `inputMask` (default true) says whether its rect is part of the input
// region (GooeyMask). False keeps it out, so the screen's edge under a slim bar
// passes the pointer to what is beneath it (the shell's 6 px bars hold nothing to
// click). It is the bar's own rect only: every slot's rects are the engine's as
// ever, and a press on such a bar while a content catches the whole track
// (`maskCatchAll`) is a press in the void (_voidPress).
//
// THE WALL. A primary whose rest box would stop 0 < gap < snapDistance short of
// the perpendicular bar at an end of its edge rests FLUSH against that bar
// instead: moved along its bar by the gap, never resized (_flushPlace). The field
// draws a face resting in that zone pulled toward the bar (GooeyGeometry:
// SNAPPING) while the content keeps the real box, so there a content's padding
// read wider on the wall's side (the notifications manager: 12 / 28); flush,
// the surface is the box. Every placement takes it -- an open (which grows out
// of the moved centre), a retarget, a migration's destination, the lane's home
// -- and a live resize never meets it mid-drag: it keeps the wall shift it
// started with until the content places itself, and where the drag leaves the
// box is placed when it ends. hostRoom's `center` is still the anchor; `a0`/`a1`
// are the box as placed; `restAt` answers where any size and shift would rest,
// by the same function (_restPlace), so no content mirrors the rule. A
// secondary is placed by its parent and never pulled (children never snap),
// and the lane beside thePopup stays against thePopup's face: lanePlace takes
// thePopup's target, wall and all, so the two never overlap. A content that
// continues its bar cell (`continuesBarCell`) opts out of this rule and the
// next one: moved off its anchor it would no longer line up with its cell.
//
// THE WALL JOIN. Flush against a bar across its edge, a popup meets that bar
// at its foot in a concave corner, and the field draws it as the bars' own corner
// travelling with the foot -- no stretch, no resistance, no presence ramp, a circle of
// blendRadius from the first sliver of popup to the last (GooeyGeometry.js THE WALL
// JOIN). The engine names the edge each PRIMARY hangs from on its body (`wallJoin`);
// a secondary and the lane do not, and keep their ordinary joins.
//
// THE BAR'S END. The same for the end of the bar a popup hangs from: the field
// draws a popup's end within flushSnap of it flush with it (letting go by twice
// that), so a rest box whose end would come to rest 0 < |d| < 2 * flushSnap
// from its bar's end -- short of it or past it -- is placed ON the bar's end,
// moved, never resized, with the same guarantees (the open out of the moved
// rest, the live hold, the end of a drag placed). The wall has the right of
// way: a box in a wall's zone takes the wall's rule, and a placement on the
// bar's end that would leave it in one is not taken (_flushPlace).
//
// A CLOSE OF ITS OWN. close(opts) takes { ms, easingIndex,
// overshoot, hold } for that one close (the defaults are openMs, openEasingIndex,
// openOvershoot; `close()` is the plain close). `hold: true` HOLDS it:
// the box stays where it is and the content fades, until the owner calls
// releaseClose() -- then it runs on the clock it asked for (_waitsForFlourish).
// A reopen by the same owner while held resumes it (the content fades back in);
// another module's open lets it go as a held-for-secondary close is let go.
//
// THE REST FRAME (post-deploy round, the user: "no popup to have layout following past the final popup dimensions into
// the overshoot"). An open's OutBack carries the SURFACE past the box it rests at -- 5 % at openOvershoot 1.2 -- and a
// content laid out on the live box followed it there: the conversation box and New chat grew and gave back, the vinyl
// grew and shrank. So while an OPEN's box reaches past its rest box (`restBox`: a primary's last placement, kept apart from
// toBox, which a close aims at the origin; a child's span at full extent), the content's frame is the rest box cut to the
// box (GooeyBody `framed`, frameX/Y/W/H): its final size, at its final place on the screen, and the surface overshoots
// round it. Inside the rest box -- every frame of the growth from the origin -- the frame is the body, to the bit, so
// nothing changes before the curve passes 1 and nothing at rest; at e = 1 the two are the same box, so the switch is
// continuous. `framing` says the motion is an open's: set by the open (_freshStart, openChild), kept by a resize that
// lands DURING it (the box re-aims and still overshoots its new rest) and by a close that interrupts it (the content
// leaves at the size it had), dropped by everything else -- a travel (its rest is another module's), a resize at rest, a
// live follow, the landing. A child is placed against its parent's CONTENT (_heldBoxOf), so a secondary that comes out
// while its popup overshoots (a persistent one, released at closeChildLead) stays where it will rest, and the parent's
// surface swells over its attach face the way an inset's does; its `secondaryCutout` is the parent's content over its
// own. The lane, the OSD and the reel are never framed: what they yield to is the surface.
//   A content that declares `revealOnOpen: true` is laid out at its rest box, where it rests, for the WHOLE of an open and a
// close: the growing box reveals it and the shrinking one hides it, and nothing in it moves (the player: its record is sized
// by its view, and in a box still growing the transport rode up over it). Every other content follows the box inside its
// rest box as it always did.
//
// THE OVERSHOOT'S BIAS (post-deploy round 2, the user: "some cap or bias that popups tend to have for their overshoot amount
// ... by no means a constant ... the popups that have an overshoot I already like stay similar"; round 3: "still overshooting too
// much" and "the clipboard's overshoot looks way bigger than the reel's though their growing axis is about the same: the reels
// are very small in the other dimension, so less pixels are moving"). An OutBack swells past its rest by a SHARE of its travel
// (5.3 % at openOvershoot 1.2), so a tall popup swelled a lot (the launcher 30 px, the player 38) and a short one a little; and
// what reads as how much moved is that swell times the extent it drags along: the reel's 9 px over 40 px across is 360 px², the
// clipboard's 11 over 790 is 8900, a tray menu's 18 over 240 is 4300. Every run on the open's curve -- a fresh open
// (_freshStart), a re-aim during it (_retarget), a child (openChild), the reel turned round, the lane's open and placements --
// takes its OWN overshoot, chosen for its travel (the longest way an edge goes, Geo.edgeTravel) and its extent ACROSS the
// motion (Geo.crossExtent: the width of a popup out of a top bar, the height of one out of a side bar, the shorter side of a
// menu out of a point): `openOvershootPx(travel, slot, cross)` = a soft minimum of three (Geo.biasedPeakPx) -- the old share
// of the travel, `openOvershootCap` px (what a narrow tall open leans to) and `openOvershootArea` / cross (a wide one's swept
// area) --, `openOvershootBend` its sharpness, and the s whose OutBack peaks there (Geo.biasedOvershoot, in thousandths; s0
// itself where the bias moves it less). ONE curve per run, never "grow, then bounce": the speed is continuous from the first
// frame to the rest. Calibrated on what the user likes as it was: the reels (40 px across) keep their swell, every tray menu
// level stays within 3 % of round 2, the launcher (420 across) went 30 -> 22 -> 17.8 (a popup of its width loses half again
// as much as in round 2), a wider one more (silicon, 1026 across: 36 -> 23 -> 8.7), the clipboard (790 across) 11.4 -> 9.0. A
// content may ask for its own cap (`openOvershootCap`, its units; 0: proportional, the old engine, the area too: the theme popup).
// Closes, travels, the OSD (`osdOvershoot`) and every other curve are untouched. Every reader of the drawn extent
// (closeChildLead, _openTimeAt, _reopenWaits, the rest frame, the mask's ease range) reads the slot's own `overshoot`.
//
// THE FLOURISH (a launched row detaches, rises, becomes a
// ball and falls back into its bar). A fifth body its OWNER drives box by box,
// in its own layer above every popup's content and below the bars' modules,
// with no input region. It is FREE: attached to no bar and no popup, never in
// the per-slot rules (no lane clip, no peer, no surface tension, no stick, no
// fade-in, no mask), never snapped, joined or filleted by the field
// (GooeyGeometry `free`); its only relation is the field's SMOOTH GROUP, which
// the owner names. It outlives the popup it came from (that content's end does
// not touch it) and a reopen of that popup.
//
//     openFlourish(ownerId, component, box, opts)   box { x0, y0, x1, y1 } or a
//         rect { x, y, width, height }, engine coordinates; the component is
//         laid out at the box, drawn at full opacity from the first frame, cut
//         to the body's outline (the clip layer, on for its whole life) with
//         opts.clipFeather (item px: the text cull) as its feather. opts:
//         radii ([tl, tr, br, bl], each a number or [rx, ry]; default maxR:
//         GooeyGeometry's RADIUS OVERRIDE), clipFeather, host (the ownerId of
//         the primary it bridges to: the group's 'host' is that owner's primary
//         while it is CLOSING, found every layout -- reopened, or its slot
//         reused for another popup, it leaves the group), smoothK.
//     setFlourish(box, radii, opts)   a new box / radii (null: keep) / opts
//         { clipFeather, smoothK }, laid out ONCE in this frame's polish
//         (followHook, its own flag beside the live follow's); nothing is
//         laid out, and nothing runs, while they do not change.
//     setFlourishGroup(members, k)    the smooth group: members from 'host',
//         'flourish', 'droplets', 'bar:<barId>', mapped to body indices every
//         layout (fewer than two present: no group). k: the blend radius. The
//         group drawn is EASED to the one asked for (THE GROUP EASES, below).
//     setFlourishNeck(neck | null)   an EXPLICIT bridge between the flourish and
//         the closing 'host' (the flourish's host owner's primary while it is
//         closing), drawn instead of the smooth group between them: neck is
//         { a, mu, l, ml ({x, y}, engine px: the card-side capsule's wide end
//         and its tip, the host-side capsule's wide end and its tip), rA, qU,
//         rL, qL (their radii), kA, kB, kMid, kJoin (the blend radii: the card
//         onto the neck, the host onto it, the two capsules, the two sides)
//         } -- shaders/gooey_field.frag, THE NECK. The card and the host are
//         never blended with each other. Not drawn (nothing happens) while
//         either body is missing. A ripple running is faded out by the layout
//         that finds a neck (they share the field's lanes). Laid out once in
//         this frame's polish, like setFlourish.
//     setFlourishCut(barId)   the content is cut where it enters that bar's
//         face (the icon sinks into the bar), with the clip's feather; "" none.
//     spawnDroplets(barId, list)   list [{ x, y, vx, vy, r, A, g }]: centre (engine
//         px), velocity (px/s), radius, ripple amplitude (default r *
//         dropletRippleScale). Ballistic under g (default dropletGravity) TOWARD that bar;
//         free beads (no snapping: within snapDistance they would be drawn as
//         threads); each lands as a ripple source on that bar (the analytic
//         landing time, so a posed clock replays it) and leaves once it is a
//         group radius deep in the bar. Only as many as there are free body
//         indices, less dropletReserve (THE DROPLETS' BUDGET, below); returns
//         how many flew.
//     rippleBar(barId, params)   the bar's face ripples (GooeyRipple.js: params'
//         globals, plus the impact `s` along the face in engine px, default the
//         bar's centre, and its amplitude `A`; the bulge stands at s unless `sb`
//         says). The engine's clock runs it to Tend and turns it off (the bytes
//         of the bar alone again). Returns false, and starts nothing, while a
//         ripple runs (one at a time: replacing it would take its waves off in
//         one frame) or while a body is related to that bar's face (_barHeld).
//     addRippleSource(barId, s, A)   a landing on that bar now (at most 3
//         sources a ripple; starts one with the last globals, no bulge, if none
//         runs; refused on another bar's ripple and on a held bar).
//     closeFlourish()   flourishOpen false, flourishClosed() emitted.
//     flourishOpen, flourishOwnerId, theFlourish (its GooeyBody).
//
// A ripple never runs beside a join: a body coming to the rippling bar's face
// (a popup or the lane opening on it, a popup reaching it from a perpendicular
// bar: within snapDistance) fades the ripple out over rippleCutMs, from every
// layout that finds one. The ripple and the droplets run on ONE clock,
// `effectTime` (s), a FrameAnimation that runs only while one of them is live
// and holds still under a theme crossfade; `effectsPosed` stops it for a
// harness that writes effectTime itself.
//
// THE GROUP EASES. The group the field draws is not the one last asked for but
// the one eased to it on the effects' clock, so no call pops: its k moves toward
// the k asked for at no more than groupRate px/s (a k of 40 in 120 ms), and a
// body already drawn that ENTERS or LEAVES the group does so at k 0 -- the k
// goes down with the old members, the members change there (a group at k 0
// draws the bytes of none) and it comes back up with the new ones. A body NEW
// this layout (the flourish opening, a droplet thrown) joins at once: where it
// first appears is its owner's choice, as it is for any body. A body that is
// GONE leaves at once. Fewer than two members drawn is no group, and k 0, so a
// group always grows from nothing. Without the easing, setFlourishGroup(['host',
// 'flourish'], 40) with the flourish 12 px inside the host would bulge the host's
// sides 4.9 px in one frame. flourishGroupK says what is
// drawn.
//
// THE DROPLETS' BUDGET. Droplets take the body indices left after every slot and
// the flourish, less dropletReserve (1) kept free, so a body that needs an index
// while they fly (a popup opening) takes the reserve at once. The last droplet
// then SHRINKS OUT over dropletShrinkMs (its radius to 0 on the effects' clock,
// its landing's ripple source cancelled if it has not landed) and only then
// frees its index: the reserve is back. A second body inside that time finds
// none, and the last droplet goes at once (the only way one still vanishes).
// =============================================================================
Item {
    id: engine

    // The default of every GooeyBar's `thickness` (and so of its `reserve`)
    // and of its `radius`; nothing is placed by these numbers themselves.
    property real thickness: 40
    property real maxR: 20
    // What a host is scaling the whole engine by. The engine itself has no
    // texture that could go soft; content that captures itself (the reel's
    // rounded end) reads this. DEVICE px per popup CONTENT px: a host with a popup ratio sets it to its frame's x that ratio.
    property real renderScale: 1
    // THE RATIOS (header): the bar's and the popups' scale on the host's frame. 1 and 1 is the engine at its design size.
    property real barRatio: 1
    property real popupRatio: 1
    // A popup's OWN ratio, by owner id ({ silicon: 1.35 }: shell.jsonc `scale.popups`, ShellScale.popupMap): it stands INSTEAD of `popupRatio` for that
    // owner's content (GooeyBody.ownScale), and an owner with no entry keeps `popupRatio`. What a host that scales the textures of the popup
    // that is out multiplies `renderScale` by is `primaryScale`: the primary's own factor (1 with no entry). A child level's own key is
    // "<owner>.detail" (the owner is its parent's, before the first "/"), by default the plain popup ratio: `detailRatio`.
    property var popupScales: ({})
    readonly property real primaryScale: engine._primary.ownScale
    // DEVICE px per FRAME px as the host knows it (ShellFrame: its frame's render scale). A host that multiplies `renderScale` by
    // `primaryScale` (the shell) says it here, or `frameRenderScale` would carry the primary's own factor into every other body; 0 (a
    // mockup's engine, with no popupScales) derives it from `renderScale`.
    property real hostRenderScale: 0
    property color surfaceColor: Theme.surface
    // How far a content's surfaceTint runs past its popup's join into the bar,
    // and as far again into the popup (px).
    property real tintBlend: 20

    property real w: width
    property real h: height

    property var barsList: []

    // ---- The surface (see GooeyField / GooeyGeometry.js) -----------------
    // The largest a join's fillet gets along the face it runs on.
    property real blendRadius: engine.maxR
    // A popup face within this of a bar face is drawn fully against it, and
    // lets go gradually until snapDistance.
    property real attachDistance: 12
    property real snapDistance: 50
    // How much a join resists following its popup's side while the popup
    // opens and closes, the most it stretches, and how much of that also runs
    // down the popup's side.
    property real stickiness: 0.75
    property real stretchMax: 60
    property real sideStretch: 1
    // How long a join takes to let go once its popup has left.
    property int settleMs: 160
    // A child within this of its parent's side is snapped flush with it.
    property real flushSnap: 3
    // THE RATIOS: the lengths above and `maxR` are DESIGN values (ratio 1); these are what the geometry reads -- each x the popups'
    // ratio, but the joint (`blendRadius`: the host's, in the frame's px) -- and the three scales a host and its owners ask for.
    readonly property real _pr: Math.max(0.01, engine.popupRatio)
    readonly property real _br: Math.max(0.01, engine.barRatio)
    readonly property real _tintBlend: engine.tintBlend * engine._pr
    readonly property real _blendRadius: engine.blendRadius
    readonly property real _attachDistance: engine.attachDistance * engine._pr
    readonly property real _snapDistance: engine.snapDistance * engine._pr
    readonly property real _stretchMax: engine.stretchMax * engine._pr
    readonly property real _flushSnap: engine.flushSnap * engine._pr
    // A bar's own corner radius (GooeyBar's default): maxR x the bar's ratio.
    readonly property real barRadius: engine.maxR * engine._br
    // Device px per FRAME px (`renderScale` is per popup content px): the layers' grid reads it (GooeyBody).
    readonly property real frameRenderScale: engine.hostRenderScale > 0 ? engine.hostRenderScale : engine.renderScale / engine._pr
    // THE DETAIL'S RATIO (frame units per content unit) of a popup's child levels: its "<owner>.detail" entry, else the popup ratio.
    // `ownerId` may be any id of the owner's chain ("silicon", "silicon/secondary"). Reads `popupScales` and `popupRatio` only, so a
    // binding that calls it follows both.
    function detailRatio(ownerId: string): real {
        const v = engine.popupScales ? engine.popupScales[String(ownerId).split("/")[0] + ".detail"] : undefined;
        return typeof v === "number" && v > 0 ? v : engine._pr;
    }
    // Device px per content px of that detail: what a child content's textures, canvases and decodes are multiplied by.
    function detailRenderScale(ownerId: string): real {
        return engine.frameRenderScale * engine.detailRatio(ownerId);
    }
    // Device px per BAR px: a bar module's textures, and the strip of a content that continues its bar's cell (the reel).
    readonly property real barRenderScale: engine.frameRenderScale * engine._br

    // ---- Motion ----------------------------------------------------------
    // Easing indices: 0 Linear, 1 OutCubic, 2 OutQuint, 3 OutBack,
    // 4 InOutCubic, 5 OutExpo, 6 InQuad, 7 InCubic, 8 InBack
    // (GooeyGeometry.EASING_NAMES).
    property int openMs: 400
    property int openEasingIndex: 3
    property real openOvershoot: 1.2
    // THE OVERSHOOT'S BIAS (header): what a tall NARROW open's overshoot leans to (design px: ratio 1, times the popups' ratio; 0
    // keeps every open proportional to its travel, the old engine), the swept area a WIDE one's swell leans to -- swell times the
    // extent across its motion (design px², times the ratio squared; 0: the cap alone, round 2's rule) --, and how sharply a
    // growing open turns from `openOvershoot`'s 5.3 % of its travel into them.
    property real openOvershootCap: 30
    property real openOvershootArea: 9000
    property real openOvershootBend: 3
    property int migrateMs: 400
    property int migrateEasingIndex: 2
    property int resizeMs: 260
    property int resizeEasingIndex: 1
    property int contentFadeMs: 160
    property real swapOutFrac: 0.2
    property real swapInFrac: 0.3
    property int childMs: 400
    // Closing a popup whose secondary is out: how far the secondary is back in
    // (share of its size) before the popup itself starts to close. 0 closes both
    // at once, 1 waits for the secondary to be all the way in. A persistent
    // secondary REOPENING with its popup is the same number played backwards: it
    // comes out when the popup is this far out (_reopenWaits).
    property real closeChildLead: 0.9
    // The primary whose persistent child is waiting for that moment, or null.
    property var _pendingChild: null
    property int childEasingIndex: 3
    property int childSlideMs: 400
    property real childWidthFrom: 0.5

    // ---- Debug -----------------------------------------------------------
    property bool showTiles: false
    property bool forceSingleTile: false
    property bool showBoxes: false
    // Cut every slot's content to the field's outline even at rest, and draw
    // the surface with no content in it: the two levers the content-clip gate
    // renders its frames with.
    property bool forceContentClip: false
    property bool hideContent: false

    // THE PARKED CONTENT. Building a popup's content SYNCHRONOUSLY in the click's frame costs ~45 us a visual item:
    // 182-196 ms for the LLM, the weather and the clock. So a primary's content is the engine's -- it builds it (in the body's frame,
    // or AHEAD of the click), hosts it
    // (GooeyBody.adopt) and lets go of it -- and an owner calls `prebuild(ownerId, component)` when the pointer has rested on its
    // button (hover intent, ~80 ms: HoverIntent): the content is built into a PARKED place when the engine is next at rest --
    // hidden, laid out at its implicit size, `parked: true` on it when it declares the property -- and open() or a travel ADOPTS it,
    // so nothing is built in the click's frame. One parked content per engine: another prebuild replaces it.
    //
    // THE CONTENT'S SIDE. A content that says nothing is built, shown and destroyed by the plain rules; what it may declare:
    //   property bool parked   true while it is held hidden; written by the engine, never by the content. While true it runs no
    //                          animation, timer, FrameAnimation, particle system or repaint and asks no service for anything, and its
    //                          implicit size stays valid. A content built ahead is built WITH `parked: true` (prebuild's `initial`:
    //                          its owner knows it declares the property), so what it does at its completion can already ask: a
    //                          content that takes the keyboard when it is built must not while parked (it would take it from
    //                          whoever has it, hidden) and takes it when `parked` turns false.
    //   function recycle()     return to the state a NEW content starts in (a secondary closed, today's date, the first page).
    //                          Without it a content that has been SHOWN is not kept: its close, or the travel leaving it, destroys
    //                          it; with it the last closed content stays parked and the next open, or the travel back,
    //                          adopts it. A prebuilt content has not been shown, so it never needs it.
    //   property bool parkPinned   true: never replaced by another owner's prebuild or close and kept after its prewarm: it waits beside the
    //                          one parked place for its owner. The content whose button moves on hover (the clock: a 180 ms build in
    //                          the middle of that motion is a lag spike on expand); it costs its memory for as long as the shell runs.
    // A prebuilt content that does not declare `parked` is let go `parkLingerMs` after its build if nothing adopted it (it would
    // run hidden); one that does but cannot be recycled is let go `parkMaxAgeMs` after it was parked (a date built into it goes stale). One that
    // can be recycled is kept (a timer that retires it is a rebuild, in the hover that next wants it): recycled when it is wanted and older than
    // `parkMaxAgeMs`, which is also why nothing runs for it at rest. A content the
    // engine lets go of that declares `parked` is held inert and destroyed `retireMs` after the engine is next at rest, one at a time
    // (a tree of thousands of items is a hitch); one that does not is destroyed at once.
    //   parkedOwnerId   the owner whose content is parked ("" none)
    //   parkStats       { prebuilds, deferred, adopted, built, parkedAtClose, retired, lingered, aged, refreshed, pinned }, mutated in place (a probe's
    //                   instrument)
    property int parkLingerMs: 4000
    property int parkMaxAgeMs: 120000
    property int retireMs: 700
    property var parkStats: ({ prebuilds: 0, deferred: 0, adopted: 0, built: 0, parkedAtClose: 0, retired: 0, lingered: 0, aged: 0, refreshed: 0, pinned: 0 })
    readonly property string parkedOwnerId: {
        void engine._parkedSerial;
        return engine._parked ? engine._parked.ownerId : "";
    }
    property var _parked: null            // { ownerId, component, item, honours, at }
    property var _pinned: []              // parked entries of contents that say `parkPinned`, waiting beside `_parked`
    property int _parkedSerial: 0
    property var _lastComponent: ({})     // ownerId -> the Component its last open() was given (prebuild(ownerId) alone)
    property var _prebuildWant: null      // { ownerId, component, until }: a prebuild waiting for the engine to be at rest
    property var _incubating: null        // { ownerId, component, inc }: the build ahead in the air
    property var _retiring: []            // contents let go that declare `parked`, destroyed when the engine is at rest

    default property alias content: barLayer.data

    // ---- What hosts read ---------------------------------------------------
    readonly property GooeyBody thePopup: engine._primary
    readonly property bool popupOpen: engine._primary.live
    // During a migration this is the module it is travelling TO: that is the
    // one that owns it from the moment the journey starts.
    readonly property string popupOwnerId: engine._primary.ownerId
    // The popup's corner radius as it is on this frame -- the largest of its
    // corners, which is its free end. Content that cuts itself to the popup's
    // outline follows this, not maxR. (In the primary's content's units: THE RATIOS.)
    readonly property real popupRadius: engine._popupRadius
    readonly property var popupCornerRadii: engine._popupRadii
    readonly property int tileCount: field.tileCount

    readonly property bool childOpen: childSlot.live
    readonly property string childOwnerId: childSlot.ownerId
    readonly property real childX: childSlot.popX
    readonly property real childY: childSlot.popY
    readonly property real childW: childSlot.popW
    readonly property real childH: childSlot.popH
    readonly property GooeyBody childPopup: childSlot
    // THE CHILD CHAIN (header): level 1 is the secondary, each next level a
    // child of the one before it.
    readonly property var childPopups: [childSlot, child2Slot, child3Slot]

    readonly property var maskItems: engine._maskItems
    // THE INK (shell.jsonc workarounds.visibleInk; GooeyInk, which makes the window's visible region of it): what layout() last saw of
    // where the engine can draw, in engine px -- every bar as its edge and depth ({ edge, depth }: how far its far face stands from
    // that edge, so an island moving along it changes nothing) and every slot that is
    // out as its input rect (a box at rest, the union of where it came from and where it goes for a whole transition, overshoot
    // included: _maskRectOf) -- written only when it changed, and only while `inkWanted`. The field's tiles (inkField) are the truth;
    // these keep the region still through a motion.
    property bool inkWanted: false
    property var inkBoxes: []
    property string _inkKey: ""
    readonly property Item inkField: field
    // the prewarm's stage (in the window's corner, at 2 % of its size and opacity): ink while a content is built there
    readonly property Item inkStage: pwStage.visible ? pwBody : null
    // What each screen edge reserves of the compositor's work area: the largest
    // `reserve` of the bars on it, 0 for a bare edge (HyprReserve).
    readonly property var edgeReserve: {
        const r = { top: 0, right: 0, bottom: 0, left: 0 };
        for (const b of engine.barsList)
            if (b && (b.edge in r))
                r[b.edge] = Math.max(r[b.edge], b.reserve);
        return r;
    }
    // What the open primary's content asks of the keyboard (the live contract).
    readonly property string popupKeyboard: engine._keyboardOf(engine._primary)
    // The open primary's content hides the pointer (the live contract; the bridge's free look). A host with a CursorCover binds its
    // `hidden` to it: nothing under the cover can decide a cursor.
    readonly property bool pointerHidden: engine._primary.live && !!engine._primary.contentItem && engine._primary.contentItem.pointerHidden === true
    // THE KEYS LET GO. A window that opens or takes the focus is where the user types: the shell calls
    // `releaseKeys()` and the open primary asks for NO keyboard (`popupKeyboardHeld`) until the pointer moves in it again
    // (`reclaimKeys()`), it closes, or another popup opens. The popup STAYS open. The layer's keyboard mode, a host's focus grabs and
    // the Escape bind (`escapeWanted` in ShellFrame) all follow the held one. The lane's request (a password card) is not touched.
    property bool keysReleased: false
    readonly property string popupKeyboardHeld: engine.keysReleased ? "none" : engine.popupKeyboard
    // ESCAPE WITH A DETAIL OPEN (feedback/general.md "Double escape press"): false (the default), one press closes the popup with its
    // detail; true, the first press puts the detail away (the content's `stepBack()`) and the next closes the popup. ONE rule for every
    // popup, decided here and not per content: the host binds it to shell.jsonc `escape`.
    property bool escapeDetailFirst: false
    onPopupOpenChanged: {
        if (!engine.popupOpen)
            engine.keysReleased = false;
    }

    // ---- The lane (see the header) -----------------------------------------
    readonly property GooeyBody theLane: laneSlot
    readonly property bool laneOpen: laneSlot.live
    readonly property string laneOwnerId: laneSlot.ownerId
    // The last placement found no room beside thePopup, or no body of the field to
    // open into (THE BUDGET): the lane is folded away (or never opened) until there is.
    readonly property bool laneBlocked: engine._laneBlocked || engine._laneBudget
    // Why: "" (not blocked), "room" (none beside thePopup) or "budget" (no free body).
    readonly property string laneBlockedReason: engine._laneBudget ? "budget" : engine._laneBlocked ? "room" : ""
    readonly property string laneKeyboard: engine._keyboardOf(laneSlot)
    // The stronger of the two, exclusive > onDemand > none: what a host binds
    // its layer's keyboard focus to (the popup's, unless its keys were let go).
    readonly property string keyboardFocus: {
        const rank = { none: 0, onDemand: 1, exclusive: 2 };
        let k = engine.popupKeyboardHeld;
        for (const o of [engine.laneKeyboard, engine.reelKeyboard])
            if (rank[o] > rank[k])
                k = o;
        return k;
    }
    // Melt with thePopup (touching, joined); off: kept blendRadius apart.
    property bool laneMelt: true
    // A lane displaced by a popup that is longer along its bar than out of it hangs from that popup's foot (off: always beside it).
    property bool laneBelowWide: true
    property int laneGlideMs: 400
    // A popup shallower than this (px out of its bar) is related to nothing while the stack stands under the same bar: THE SLIVER BESIDE A STACK AT HOME.
    property real laneSliverPx: 1
    property int laneGlideEasingIndex: 1
    // The owner whose lane request the engine holds ("" none) -- out, folded
    // away while blocked, or hopping. An owner compares it with its own id to
    // know whether to ask or to withdraw (NotificationsBarOwner._syncLane).
    // It hangs from thePopup's foot, not beside it (a readout for probes).
    readonly property string laneRequestOwner: engine._laneRequest ? engine._laneRequest.ownerId : ""

    // ---- The OSD slot (see the header) ---------------------------------------
    readonly property GooeyBody theOsd: osdSlot
    // Out, or dipping (folding to come back with other content).
    readonly property bool osdOpen: osdSlot.live || osdSlot.dipping
    readonly property string osdOwnerId: osdSlot.ownerId
    // Whose request the engine holds ("" none): out, folded away waiting for room, or hopping.
    readonly property string osdRequestOwner: engine._osdRequest ? engine._osdRequest.ownerId : ""
    // The last placement found no room (and nothing to move for it), or no body of the
    // field to open into (THE BUDGET).
    readonly property bool osdBlocked: engine._osdBlocked || engine._osdBudget
    // Why: "" (not blocked), "room" or "budget".
    readonly property string osdBlockedReason: engine._osdBudget ? "budget" : engine._osdBlocked ? "room" : ""
    readonly property string osdPhase: osdSlot.dipping ? "dipping" : osdSlot.phase
    readonly property var osdKey: osdSlot.key
    readonly property var osdStats: engine._osdStats
    // The slot's own clocks: open and close, the dip's fold (InQuad) and rise (OutBack),
    // a glide beside what it yields to, and where it starts (a fraction of its length).
    property int osdOpenMs: 320
    property int osdOpenEasingIndex: 3
    property real osdOvershoot: 1.15
    property int osdCloseMs: 220
    property int osdCloseEasingIndex: 1
    property int osdDipFoldMs: 110
    property int osdDipFoldEasingIndex: 6
    property int osdDipRiseMs: 240
    property int osdDipRiseEasingIndex: 3
    // How wide the folded face is, as a fraction of the box it folds out of (1: as wide).
    property real osdDipWidthTo: 1
    property int osdGlideMs: 300
    property int osdGlideEasingIndex: 1
    property real osdWidthFrom: 0.6
    // Melt with the neighbours it touches on its own bar (off: kept blendRadius apart);
    // may the lane be displaced, may thePopup be pushed, for its room.
    property bool osdMelt: true
    property bool osdDisplaceLane: true
    property bool osdPushPopup: true
    // Debug: the OSD is drawn at this box (a PoseRecorder's playback); null: its own.
    property var osdPoseBox: null
    signal osdSwap(string ownerId, var key)
    // THE TUCK (the header): how much of a tucked OSD stands out of its bar, and the thickest bar whose whole thickness beside the
    // sliver counts as the sliver for the hover (a slim outlet: the pointer thrown to the screen's edge finds it; on a thicker bar the
    // modules under the card's span are the bar's).
    property real osdTuckPx: 3
    property real osdTuckEdgeMax: 12
    // The tucked OSD at rest: the request says tucked and the slot has come to rest as the sliver.
    readonly property bool osdTuckedRest: engine._osdTucked && osdSlot.phase === "open"
    // Where a tucked OSD at rest is hovered (an Item in the bodies' frame, no size otherwise; the owner hangs its HoverArm on it).
    readonly property Item osdTuckZone: osdTuckZoneItem

    // ---- The reel slot (see the header) ----------------------------------------
    readonly property GooeyBody theReel: reelSlot
    readonly property GooeyBody theReelChild: reelChildSlot
    // THE REEL'S CHAIN (header): the strip's levels, nearest first -- the idle reel's reason is level 1, the tray's label / menu,
    // submenu and the submenu's submenu are levels 1 to 3.
    readonly property var reelChildPopups: [reelChildSlot, reelChild2Slot, reelChild3Slot]
    // What the strip's content asks of the keyboard (a tray menu: "onDemand"), and whether a level of its chain waits for a body of
    // the field (THE BUDGET: asked for, refused, opened by itself once one is free).
    readonly property string reelKeyboard: engine._keyboardOf(reelSlot)
    readonly property bool reelChildBlocked: engine._reelChainWaits
    property bool _reelChainWaits: false
    readonly property bool reelOpen: reelSlot.live
    readonly property string reelOwnerId: reelSlot.ownerId
    readonly property string reelPhase: reelSlot.phase
    // No free body of the field (THE BUDGET): the last open was refused.
    readonly property bool reelBlocked: engine._reelBudget
    // The strip's free-corner radius on this frame, in its content's units (popupRadius's twin).
    readonly property real reelRadius: engine._reelRadius
    property real _reelRadius: 0
    // THE REEL PASS (above): the layer, for the gates (its `count`, `ink`, `drawn`).
    readonly property var reelCast: reelCastLayer

    // ---- The floating popup (see the header) --------------------------------------------------------------------
    // The host: this screen's focused window is fullscreen (ShellFrame, from the shell's one FocusedScreen).
    property bool fullscreenHere: false
    // The host: the bars are hidden by the toggle. Nothing to hang from here either: a popup floats as it does over a fullscreen window.
    property bool barsHidden: false
    readonly property bool floatWanted: engine.fullscreenHere || engine.barsHidden
    // How far a floating popup stands off the screen's edges (frame px; ShellFrame hands it the toast pill's margin), how long it takes to come home.
    property real floatGap: 12
    property int floatSlideMs: 300
    // THE WAY HOME (the header): how far short of home a sliding popup's joins start to come in (`floatF`), how long the host holds its bars once the shell is back.
    property real floatJoinAt: 0.3
    property int floatHomeWaitMs: 0
    // THE ATTRACTION LETS GO AT REST (GooeyGeometry.js, the void): how long a landed body waits, how long it takes to let go, how fast a new motion brings it back.
    property int attractHoldMs: 200
    property int attractLetGoMs: 520
    property int attractReturnMs: 160
    // A body with no void flare at its last layout has nothing to let go of: no clock, so a landing costs no frames.
    function _attractRest(S) {
        if (S.isLane || S.isOsd)
            return;
        const id = engine._bodyIdOf(S);
        if (field.voidKeys().some(k => k.split("|").indexOf(id) >= 0))
            S.attractTo(0, engine.attractHoldMs, engine.attractLetGoMs);
        else
            S.attractTo(0, 0, 0);
    }
    function _floats(S) {
        return S.floating && S.phase !== "closed";
    }
    // A floating popup is out (live or closing): the host's window is on the Overlay layer for it.
    readonly property bool floatOverlay: engine.floatWanted && (engine._floats(slotA) || engine._floats(slotB))
    // (Each reads the two facts themselves: a handler runs before a binding on what just changed.)
    onFullscreenHereChanged: engine._shellBack()
    onBarsHiddenChanged: engine._shellBack()
    function _shellBack() {
        if (engine.fullscreenHere || engine.barsHidden)
            return;
        // One that has not shown yet opens docked, now: the shell is back, and what it waited for slides home as it goes.
        for (const S of [slotA, slotB]) {
            if (S.openAfter) {
                S.floatTo(0, 0);
                engine._startHeldOpen(S);
            }
        }
        if (engine.floatHomeWaitMs > 0) {
            floatHome.interval = engine.floatHomeWaitMs;
            floatHome.restart();
        } else {
            engine._slideHome();
        }
    }
    function _slideHome() {
        for (const S of [slotA, slotB])
            if (S.floating && S.phase !== "closed")
                S.floatTo(0, engine.floatSlideMs);
    }
    Timer {
        id: floatHome
        onTriggered: {
            if (!engine.floatWanted)
                engine._slideHome();
        }
    }
    // How far a slot floats (0..1): its own floatF, a child's its chain's primary's (a child floats with its parent).
    function _floatOf(S) {
        let P = S;
        for (let n = 0; P && P.isChild && n < 8; n++)
            P = P.parentSlot;
        return P && !P.isChild ? Math.max(0, Math.min(1, P.floatF)) : 0;
    }
    // A FLOATING POPUP IS A PILL: its shape is that of the OSD pill or of a toast sliding offscreen, with practically no deforming; its
    // border radius is capped. A docked popup's corners are its SURFACE TENSION (Geo.tensionRadii):
    // small, it inflates toward a circle half its full size (a 600 px clipboard opened with 300 px corners) and squishes them into ellipses where a
    // side is short -- a drop of the bar's goo. A floating popup is no drop of anything: its corners are the resting radius, circular, capped at
    // half its shorter side -- the OSD pill's capsule while it is thin, a rounded box at rest -- blended in with how far it floats (`f`), so the
    // slide home is one shape.
    function _pillRadii(tr, w, h, ratio, f) {
        const r = Math.max(0, Math.min(engine.maxR * ratio, w / 2, h / 2));
        return { rx: tr.rx + (r - tr.rx) * f, ry: tr.ry + (r - tr.ry) * f };
    }
    // Where a box of this edge's floats to, as a shift x `f` of how far it floats: `floatGap` off the screen's edge on the side it hangs from (the
    // face is the bars' way, and they are drawn away) and never nearer than that to the other three. Read from the box as it stands, so a box
    // that grows towards a corner stops at the margin instead of jumping there when its target changes.
    function _floatDelta(b, edge, f) {
        const m = engine.floatGap, W = engine.w, H = engine.h;
        let dx = 0, dy = 0;
        if (edge === "top")
            dy = m - b.y0;
        else if (edge === "bottom")
            dy = H - m - b.y1;
        else if (edge === "left")
            dx = m - b.x0;
        else
            dx = W - m - b.x1;
        if (edge === "top" || edge === "bottom")
            dx = b.x0 < m ? m - b.x0 : b.x1 > W - m ? W - m - b.x1 : 0;
        else
            dy = b.y0 < m ? m - b.y0 : b.y1 > H - m ? H - m - b.y1 : 0;
        return { x: dx * f, y: dy * f };
    }
    function _floatMoved(b, d) {
        return { x0: b.x0 + d.x, y0: b.y0 + d.y, x1: b.x1 + d.x, y1: b.y1 + d.y };
    }
    // The reel slot's input rect as an item of its own (the engine's 16 mask proxies hold every body's): the window's input region while the
    // session is locked is the idle cell and this -- nothing else of the shell takes a click over the lock (ShellScreen).
    readonly property Item reelMaskItem: reelMaskProxy
    property bool _reelBudget: false

    property GooeyBody _primary: slotA
    property real _popupRadius: 0
    property var _popupRadii: [0, 0, 0, 0]
    property var _maskItems: []
    property bool _inLayout: false
    // A live follow asked for and not yet laid out (the polish hook runs it).
    property bool _followPending: false
    // Which body index each slot had in the last layout, for the tints.
    property var _tintSlots: []
    // The lane's: what its owner asked for (kept while it is blocked or
    // hopping), the last placement, the counts
    // (mutated in place: a count read by nothing that it counts), and how many
    // thePopup operations are running (each places the lane once, at its end).
    property var _laneRequest: null
    // The stack follows the popup that closes (THE LANE GIVES WAY): { slot, below, side, box (the stack's box where it began) }, null none.
    property var _laneFollow: null
    property bool _laneBlocked: false
    // THE BUDGET: the lane's request waits for a free body of the field (it is closed, or gave
    // its body up); the OSD's likewise. Written by the placements and _budgetYield only.
    property bool _laneBudget: false
    property var _laneTarget: null
    property var _laneStats: ({ placements: 0, opens: 0, hops: 0, pathless: 0 })
    property int _laneBatch: 0
    // The OSD's: what its owner asked for (kept while it is blocked or hopping), the
    // last placement, whether the lane is displaced for it, the counts (mutated in
    // place: a count read by nothing that it counts) and the reentrancy guard.
    property var _osdRequest: null
    property bool _osdBlocked: false
    property bool _osdBudget: false
    property var _osdTarget: null
    property bool _osdOverLane: false
    // thePopup is pushed for the OSD: the lane then places itself around the OSD's target too
    // (its place is part of the arrangement, as when the lane is displaced).
    property bool _osdPins: false
    property var _osdStats: ({ placements: 0, opens: 0, dips: 0, hops: 0, displaced: 0, pushes: 0, blocked: 0, tucks: 0 })
    property int _osdBatch: 0
    // What the slot is configured for (_osdHome, from the request): tucked into its bar or out.
    property bool _osdTucked: false
    // How many layouts and bar relayouts have run, for probes (mutated in place: a count read by nothing that it counts): a
    // cascade of bar changes is ONE relayout and one layout a frame (_requestBarsRelayout).
    property var _layoutStats: ({ layouts: 0, relayouts: 0 })
    // A bar changed since the last relayout (the polish hook lays them out once).
    property bool _barsDirty: false

    // ---- The flourish (see the header) ----------------------------------------
    readonly property bool flourishOpen: flourishSlot.live
    readonly property string flourishOwnerId: flourishSlot.live ? flourishSlot.ownerId : ""
    readonly property GooeyBody theFlourish: flourishSlot
    signal flourishClosed()
    // Toward the bar a droplet was thrown from (px/s^2), when its entry says none.
    property real dropletGravity: 2000
    // A droplet's ripple amplitude per px of its radius, when its entry says none.
    property real dropletRippleScale: 0.25
    // A droplet landing after the ripple would have ended keeps it this long
    // after its landing (s), while the ripple has not started to fade.
    property real dropletRippleMinS: 0.6
    // A popup opening on a rippling bar fades the ripple out over this (ms).
    property int rippleCutMs: 120
    // THE GROUP EASES (header): the fastest the drawn group's k follows the k
    // asked for (px/s): a k of 40 -- the bridge's -- comes and goes in 120 ms,
    // so no outline moves by more than ~1.4 px a 60 Hz frame (a smooth-min's
    // dent grows by at most a quarter of its k's change).
    property real groupRate: 333
    // THE DROPLETS' BUDGET (header): the body indices droplets leave free, and
    // how long one that gives its index back takes to shrink out (ms).
    property int dropletReserve: 1
    property int dropletShrinkMs: 60
    // The group as drawn (THE GROUP EASES): its members' body ids, and its k.
    readonly property real flourishGroupK: engine._groupK
    // THE EFFECTS' CLOCK (s): the ripple's and the droplets' time. Runs only while
    // one of them is live; a harness sets effectsPosed and writes effectTime.
    property bool effectsPosed: false
    property real effectTime: 0
    readonly property bool effectsLive: engine._effectsLive
    // The droplets in flight: [{ id, barId, x, y, vx, vy, r, A, t0, land, leave }]
    // (spawn state, and the effect time it began to shrink out; its box on this
    // frame is dropletBox(d)).
    readonly property var droplets: engine._droplets
    property var _flourishBox: null
    property var _flourishRadii: null
    property string _flourishHostOwner: ""
    property var _flourishNeck: null
    property var _flourishGroup: []
    property real _flourishK: 0
    // THE GROUP EASES (header): the members drawn (body ids), their k and what
    // it is heading for, whether the effects' clock carries it, the effect time
    // it was last stepped at, and the body ids of the last layout.
    property var _groupIds: []
    property real _groupK: 0
    property real _groupAim: 0
    property bool _groupEasing: false
    property real _groupT: 0
    property var _groupSeen: ({})
    property string _flourishCutBar: ""
    // A flourish change not laid out yet (the frame hook lays it out once).
    property bool _flourishDirty: false
    property bool _pokePending: false
    property var _droplets: []
    property int _dropletSerial: 0
    property bool _effectsLive: false
    property bool _effectsResetting: false
    property string _rippleBarId: ""
    property var _rippleGlobals: null
    property var _rippleSources: []
    property real _rippleEpoch: 0

    // ---- The perimeter --------------------------------------------------
    // The screen's edge as one clockwise coordinate: top left->right, right
    // top->bottom, bottom right->left, left bottom->top. A bar's `rawPos` is
    // measured from the start of its own edge in screen terms (from the left
    // or from the top), which for bottom and left runs against the track.
    readonly property QtObject track: QtObject {
        id: track

        readonly property real w: engine.w
        readonly property real h: engine.h
        readonly property real length: (track.w * 2) + (track.h * 2)
        readonly property var bars: engine.barsList

        function getBarInfoById(id) {
            if (track.w === 0 || track.h === 0)
                return null;
            for (let i = 0; i < track.bars.length; i++) {
                const bar = track.bars[i];
                if (!bar || bar.barId !== id)
                    continue;
                let startPos = 0;
                if (bar.edge === "top")
                    startPos = bar.rawPos;
                else if (bar.edge === "right")
                    startPos = track.w + bar.rawPos;
                else if (bar.edge === "bottom")
                    startPos = track.w + track.h + (track.w - (bar.rawPos + bar.rawLen));
                else if (bar.edge === "left")
                    startPos = track.w + track.h + track.w + (track.h - (bar.rawPos + bar.rawLen));
                return { start: startPos, end: startPos + bar.rawLen, len: bar.rawLen, edge: bar.edge,
                         thickness: bar.thickness, bar: bar };
            }
            return null;
        }

        // The bar covering a track position (a pixel either side counts), or
        // null.
        function barAt(pos) {
            if (track.length === 0)
                return null;
            const p = ((pos % track.length) + track.length) % track.length;
            for (let i = 0; i < track.bars.length; i++) {
                const info = track.bars[i] ? track.getBarInfoById(track.bars[i].barId) : null;
                if (info && p >= info.start - 1 && p <= info.end + 1)
                    return track.bars[i];
            }
            return null;
        }

        // The bar on the edge that meets this corner, or null. Sampling 2 px
        // from the corner would sample INSIDE the corner square, which belongs to the
        // bar running through it, so a side bar starting at the top bar's
        // thickness (the usual way to leave the square to the top bar) would be
        // missed and popups placed over it. The square is as deep as the
        // bars on the edge the question is asked FROM are thick, so `reach` is
        // the thickest of those plus 2 (edgeThickness): 42 past a 40 px top
        // bar's corner, 8 past a 6 px bottom bar's.
        function barPast(corner, dir, reach) {
            return track.barAt(corner + dir * reach);
        }

        // The thickest bar on an edge, 0 for a bare edge.
        function edgeThickness(edgeName) {
            let t = 0;
            for (let i = 0; i < track.bars.length; i++)
                if (track.bars[i] && track.bars[i].edge === edgeName)
                    t = Math.max(t, track.bars[i].thickness);
            return t;
        }

        function hasBarOnEdge(edgeName) {
            for (let i = 0; i < track.bars.length; i++)
                if (track.bars[i] && track.bars[i].edge === edgeName)
                    return true;
            return false;
        }

        // Is there a chain of bars around the corners from one edge to the
        // other, one way or the other?
        function hasPath(srcEdge, dstEdge) {
            if (srcEdge === dstEdge)
                return true;
            const edges = ["top", "right", "bottom", "left"];
            const si = edges.indexOf(srcEdge);
            const di = edges.indexOf(dstEdge);
            if (si < 0 || di < 0)
                return true;
            let fwd = true;
            for (let i = (si + 1) % 4; i !== di; i = (i + 1) % 4)
                if (!track.hasBarOnEdge(edges[i])) {
                    fwd = false;
                    break;
                }
            let bwd = true;
            for (let i = (si + 3) % 4; i !== di; i = (i + 3) % 4)
                if (!track.hasBarOnEdge(edges[i])) {
                    bwd = false;
                    break;
                }
            return fwd || bwd;
        }

        function getMetrics(pos) {
            if (track.w === 0 || track.h === 0)
                return { edge: "top", x: 0, y: 0, rot: 0 };
            const p = ((pos % track.length) + track.length) % track.length;
            if (p < track.w)
                return { edge: "top", x: p, y: 0, rot: 0 };
            if (p < track.w + track.h)
                return { edge: "right", x: track.w, y: p - track.w, rot: 90 };
            if (p < (2 * track.w) + track.h)
                return { edge: "bottom", x: track.w - (p - (track.w + track.h)), y: track.h, rot: 180 };
            return { edge: "left", x: 0, y: track.h - (p - ((2 * track.w) + track.h)), rot: 270 };
        }
    }

    // =====================================================================
    //  Opening and closing
    // =====================================================================

    function toggle(ownerId, barId, localCenter, w, h, cornerAnim2D = false, contentComponent = null, widthFrom = 0.5) {
        if (engine.popupOpen && engine._primary.ownerId === ownerId)
            engine.close();
        else
            engine.open(ownerId, barId, localCenter, w, h, cornerAnim2D, contentComponent, widthFrom);
    }

    // `w` is the popup's size ALONG its bar and `h` its size OUT of it; either
    // may be null to follow the content's implicit size. `widthFrom` is the
    // fraction of its width it starts at: 0.5 inflates sideways as it comes
    // out, 1 slides out at full width (what content anchored to the bar needs,
    // or it wanders while the popup opens).
    function open(ownerId, barId, localCenter, w, h, cornerAnim2D = false, contentComponent = null, widthFrom = 0.5) {
        if (ownerId && contentComponent)
            engine._lastComponent[ownerId] = contentComponent;
        engine._stackOnOpen(ownerId, barId, localCenter, w, h, cornerAnim2D, contentComponent, widthFrom);
        // A popup asked for while the stack follows another's close: the stack is placed round the new one from where it is.
        engine._laneFollowEnd(false);
        // A content waiting for the engine to rest is for a click that did not come: this open is the click.
        engine._prebuildWant = null;
        // Whatever this changes of thePopup's target (and its child's), the lane
        // is placed ONCE, after it (THE LANE) -- for the same module asking again while it is out, a RESIZE, on the popup's own resize
        // clock, the two faces as one (as a content's own resize does, _contentResizedNow): on the lane's glide instead, a stack under a
        // popup that shrank would stand up to 77 px off its foot for the length of the glide.
        const P0 = engine._primary;
        const resize = (P0.live || P0.closeHeld) && P0.ownerId === ownerId;
        engine._laneBatch++;
        engine._openPrimary(ownerId, barId, localCenter, w, h, cornerAnim2D, contentComponent, widthFrom);
        engine._laneBatch--;
        engine._laneEvent(resize ? engine.resizeMs : engine.laneGlideMs, resize ? engine.resizeEasingIndex : engine.laneGlideEasingIndex);
    }

    function _openPrimary(ownerId, barId, localCenter, w, h, cornerAnim2D, contentComponent, widthFrom) {
        const info = track.getBarInfoById(barId);
        if (!info)
            return;
        let P = engine._primary;
        // NOTHING TRAVELS OVER A FULLSCREEN WINDOW: another module while this one waits for the old one to go. It has not been seen: it
        // gives way, and the new request stands where it stood.
        if (P.openAfter && P.ownerId !== ownerId) {
            const O = P.openAfter;
            engine._finishClose(P);
            engine._primary = O;
            P = O;
        }
        // Another module while this one is held for its secondary: it has not
        // moved yet, so let it go from where it stands instead of leaving a
        // full-size ghost behind.
        if (P.closeHeld && P.ownerId !== ownerId) {
            P.stop();
            P.phase = "open";
            P.framing = false;
            P.fromBox = P.box;
        }

        // The same module again while it is out, or while it is holding for its
        // secondary: follow the new size/place, and take the secondary back.
        if ((P.live || P.closeHeld) && P.ownerId === ownerId) {
            const resumed = !P.live;
            // A content about to be replaced does not place its successor.
            if (contentComponent !== P.component)
                P.swapping = true;
            engine._configure(P, ownerId, info, barId, localCenter, w, h, cornerAnim2D, widthFrom);
            if (contentComponent !== P.component)
                engine._swapContent(P, contentComponent);
            engine._retarget(P, engine.resizeEasingIndex, engine.resizeMs);
            if (resumed) {
                // A close held for a flourish faded its content: back in.
                if (P.holdFaded) {
                    P.holdFaded = false;
                    P.fadeTo(1, engine.contentFadeMs);
                }
                engine._syncSecondary(P);
            }
            return;
        }

        // Nothing out, or the old one on its way in: a fresh popup. One that
        // is closing for ANOTHER module keeps closing in the other slot.
        if (!P.live) {
            let S = P;
            if (P.phase === "closing" && P.ownerId !== ownerId)
                S = engine._takeSpareSlot();
            engine._openFresh(S, ownerId, info, barId, localCenter, w, h, cornerAnim2D, contentComponent, widthFrom,
                              S !== P && engine.floatWanted && P.floating ? P : null);
            return;
        }

        // Out DOCKED since before the window went fullscreen (the header): it stands under that window. It goes unseen, and the new one does not wait for it.
        if (engine.fullscreenHere && !P.floating) {
            for (const C of engine._descendants(P).reverse())
                engine._finishClose(C);
            engine._finishClose(P);
            engine._openFresh(P, ownerId, info, barId, localCenter, w, h, cornerAnim2D, contentComponent, widthFrom);
            return;
        }

        // Out, for another module: travel, or jump if there is no way there. A chain of levels out closes IN SEQUENCE over the
        // travel's time (_closeInSequence): the deepest first, each level above held until the one below it is in.
        engine.closeChild(undefined, { sequenceMs: engine.migrateMs });
        const srcEdge = P.move ? engine._polyEdgeNow(P) : P.edge;
        // No way there -- or the way there runs through the lane, which it may
        // not pass (THE LANE): close in place, open at the destination.
        const crossesLane = track.hasPath(srcEdge, info.edge)
            && engine._crossesLane(P, info, localCenter, w, h, cornerAnim2D, widthFrom, srcEdge);
        if (crossesLane)
            engine._laneStats.pathless++;
        // Over a fullscreen window nothing travels, nor with the bars hidden (the header): the old one closes where it is, the new one opens once it has gone.
        if (engine.floatWanted) {
            const old = engine._primary;
            const S = engine._spare();
            if (S.phase !== "closed")
                engine._finishClose(S);
            // The content first, and only then the turn of the owners: building it takes tens of ms, and between the old owner's focus grab going and the new one's
            // coming the keyboard is the fullscreen window's (a word typed at once reached it, 5 runs in 8).
            engine._freshContent(S, ownerId, info, barId, localCenter, w, h, cornerAnim2D, contentComponent, widthFrom);
            engine._primary = S;
            engine._closeSlot(old);
            engine._freshStart(S, old);
            return;
        }
        if (!track.hasPath(srcEdge, info.edge) || crossesLane) {
            const old = engine._primary;
            const S = engine._takeSpareSlot();
            engine._closeSlot(old);
            engine._openFresh(S, ownerId, info, barId, localCenter, w, h, cornerAnim2D, contentComponent, widthFrom);
            return;
        }

        const current = P.box || P.toBox;
        // A journey has no push in it: the OSD places itself again on landing.
        P.osdYield = 0;
        // The content still loaded is the one leaving: its shift is not the
        // destination's, nor its size (THE OWNER'S SIZE MEMORY: aim at what the destination will be).
        if (contentComponent !== P.component) {
            P.swapping = true;
            P.sizeHint = engine._rememberedSize(ownerId, contentComponent);
        }
        engine._configure(P, ownerId, info, barId, localCenter, w, h, cornerAnim2D, widthFrom);
        engine._swapContent(P, contentComponent);
        P.move = engine._moveFor(current, P.toBox, srcEdge, info.edge, !!P.move);
        P.fromBox = current;
        P.phase = "moving";
        P.framing = false;
        P.travelling = true;
        P.easingIndex = engine.migrateEasingIndex;
        P.overshoot = engine.openOvershoot;
        P.run(engine.migrateMs);
    }

    // opts (A CLOSE OF ITS OWN, header): { ms, easingIndex, overshoot, hold }.
    function close(opts) {
        const P = engine._primary;
        if (!P.live)
            return;
        engine._changedAt = Date.now();
        // A popup that joined THE STACK gives the place back to the one it covered (not with `noStack`, not when that one's bar is gone).
        const back = engine._stacked;
        if (back && !(opts && opts.noStack) && engine.stackJoiners.indexOf(P.ownerId) >= 0 && track.getBarInfoById(back.barId)) {
            engine._stacked = null;
            engine._restoring = true;
            engine.open(back.ownerId, back.barId, back.localCenter, back.w, back.h, back.cornerAnim2D, back.contentComponent, back.widthFrom);
            engine._restoring = false;
            return;
        }
        // Waiting for the old one to go (NOTHING TRAVELS OVER A FULLSCREEN WINDOW): nobody has seen it, so it is gone now, and what it waited for is the primary again.
        if (P.openAfter) {
            const O = P.openAfter;
            engine._finishClose(P);
            engine._primary = O;
            return;
        }
        engine._laneFollowBegin(P);
        engine._laneBatch++;
        engine._closeSlot(P, opts);
        engine._laneBatch--;
        // (Armed once the popup is closing: a layout inside _closeSlot, before its phase changes, must not find the follow over.)
        if (engine._laneFollow !== null)
            engine._laneFollow.armed = true;
        engine._laneEvent(engine.laneGlideMs, engine.laneGlideEasingIndex);
    }

    // =====================================================================
    //  The stack, the keys and Escape
    // =====================================================================
    // THE POPUP STACK: the clipboard, the launcher and the hover-opened popups must not make the open popup go away -- and since
    // two cannot be out at once, the one that was open comes back when they close. `stackJoiners` is the ids of the owners that JOIN: a joiner opening over an ordinary popup remembers
    // that popup's last open() (its bar, place, size, content) and, when the joiner closes, the engine opens it again THERE -- the
    // joiner's box travels to where the other stood, as any change of owner does. One level: a joiner over a joiner keeps the first
    // memory; an ordinary popup opening (any, the remembered one included: a deliberate open) or `dropStack()` forgets it. The
    // popup under a joiner is not live, so it cannot be closed meanwhile: its being replaced is the whole of its absence. (The
    // reels have a slot of their own and never take the primary: they join nothing.) `noStack` in close()'s opts closes for good.
    property var stackJoiners: []
    readonly property string stackedOwnerId: engine._stacked ? engine._stacked.ownerId : ""
    property var _stacked: null           // { ownerId, barId, localCenter, w, h, cornerAnim2D, contentComponent, widthFrom }
    property var _lastOpen: null          // the same record for the last open() of the live primary
    property bool _restoring: false

    function dropStack(): void {
        engine._stacked = null;
    }

    function _stackOnOpen(ownerId, barId, localCenter, w, h, cornerAnim2D, contentComponent, widthFrom) {
        const P = engine._primary;
        engine._changedAt = Date.now();
        if (!engine._restoring) {
            const joins = engine.stackJoiners.indexOf(ownerId) >= 0;
            const covers = P.live && P.ownerId !== ownerId;
            if (!joins)
                engine._stacked = null;
            else if (covers && engine.stackJoiners.indexOf(P.ownerId) < 0 && engine._lastOpen && engine._lastOpen.ownerId === P.ownerId)
                engine._stacked = engine._lastOpen;
            // a popup that takes the place of another, or a fresh one, asks for the keys anew
            if (!P.live || P.ownerId !== ownerId)
                engine.keysReleased = false;
        } else {
            engine.keysReleased = false;
        }
        engine._lastOpen = { ownerId: ownerId, barId: barId, localCenter: localCenter, w: w, h: h, cornerAnim2D: cornerAnim2D,
                             contentComponent: contentComponent || engine._lastComponent[ownerId] || null, widthFrom: widthFrom };
    }

    // THE KEYS (see keysReleased): false when there is no popup, or its keys are already let go. `byFocus`: the cause is a window that
    // TOOK THE FOCUS (activewindowv2), not one that opened: the compositor sends that event when a popup opens or closes itself (a grab
    // or an on-demand layer changing hands gives the focus to the window under it: measured, one event ~50 ms after the clipboard opened
    // over the LLM) and it is no one's typing -- so it counts only when the popup has been as it is for `focusGraceMs`.
    property int focusGraceMs: 600
    property double _changedAt: 0
    function releaseKeys(byFocus: bool): bool {
        if (!engine.popupOpen || engine.keysReleased)
            return false;
        if (byFocus === true && Date.now() - engine._changedAt < engine.focusGraceMs)
            return false;
        engine.keysReleased = true;
        return true;
    }
    function reclaimKeys(): void {
        engine.keysReleased = false;
    }

    // ESCAPE (`pressEscape`: a method called `escape` is an "Illegal method name" in QML). The open primary's content gets `handleEscape()` (contract above) and the popup closes unless the content took the key
    // -- or, while `escapeDetailFirst`, unless the content had a detail to put away (`stepBack()`).
    // true when there was a popup to answer for it. The close is close(): a joiner gives its place back.
    function pressEscape(): bool {
        // The reel slot's content while it asks for the keyboard (a tray menu over a popup): the keys are its, and so is Escape --
        // the popup under it stays (THE REEL'S CHAIN, the keys).
        const R = reelSlot;
        const rit = R.live && engine.reelKeyboard !== "none" ? R.contentItem : null;
        if (rit && typeof rit.handleEscape === "function" && rit.handleEscape() === true)
            return true;
        const P = engine._primary;
        if (!P.live)
            return false;
        const it = P.contentItem;
        if (it && typeof it.handleEscape === "function" && it.handleEscape() === true)
            return true;
        if (engine.escapeDetailFirst && it && typeof it.stepBack === "function" && it.stepBack() === true)
            return true;
        engine.close();
        return true;
    }

    // A close held for a flourish (close({ hold: true })) runs now, on its clock.
    function releaseClose() {
        let any = false;
        for (const S of [slotA, slotB]) {
            if (S.flourishHold) {
                S.flourishHold = false;
                any = true;
            }
        }
        if (any)
            engine._releaseCloses();
    }

    // The path of a migration from `current` to `target`, or null for a
    // straight one along one edge (`moving`: the popup is on a path already).
    function _moveFor(current, target, srcEdge, dstEdge, moving) {
        if (srcEdge === dstEdge && !moving)
            return null;
        let corners = srcEdge !== dstEdge ? engine._cornersBetween(srcEdge, dstEdge, current, target) : [];
        // One corner that the popup is already sitting in: no detour.
        if (corners.length === 1 && current) {
            const cp = engine._cornerPos(corners[0], current.x1 - current.x0, current.y1 - current.y0);
            if (Math.abs(current.x0 - cp.x) < 80 && Math.abs(current.y0 - cp.y) < 80)
                corners = [];
        }
        // sf / ef: how far the start box's face is off its edge and the end
        // box's off its own -- the walls the first and the last leg ride.
        return {
            sx: current.x0, sy: current.y0, sw: current.x1 - current.x0, sh: current.y1 - current.y0,
            ex: target.x0, ey: target.y0, ew: target.x1 - target.x0, eh: target.y1 - target.y0,
            corners: corners, srcEdge: srcEdge, dstEdge: dstEdge,
            sf: engine._faceOf(srcEdge, current), ef: engine._faceOf(dstEdge, target)
        };
    }

    // =====================================================================
    //  The secondary popup
    // =====================================================================

    // Grow a child out of the live primary owned by `parentOwnerId`.
    //   side    "far" (away from the bar), "start"/"end" (along it), or an
    //           explicit "top" | "right" | "bottom" | "left"
    //   anchor  a point in the parent's content coordinates; the child is
    //           centred on it along the side
    //   w, h    the child's width and height (in its content's units: screen px at
    //           ratio 1, THE RATIOS); null follows its content's implicit size
    //   (the anchor, `inset` and `openMin` are in the PARENT's content units)
    //   opts    { overhang: false, widthFrom: childWidthFrom, key, inset,
    //             anchorAt: 0.5 (which point of the child sits on the anchor; see
    //             the contract's secondaryAnchorAt), openAt: anchorAt (the point
    //             its open grows out of), openMin: 0 (the least length it opens
    //             at) }
    //   The parent may be a child itself (THE CHILD CHAIN): the child opens at the
    //   level below it.
    // Calling it again while the child is out re-anchors it: it slides along
    // the side, and swaps its content if `key` or `component` changed.
    function openChild(parentOwnerId, childOwnerId, side, anchor, w, h, component, opts) {
        const P = [slotA, slotB, reelSlot].concat(engine.childPopups, engine.reelChildPopups).find(s => s.live && s.ownerId === parentOwnerId);
        if (!P)
            return;
        opts = opts || {};
        // The level below P's: the secondary for a primary, the next for a child
        // (none past the last declared level: nothing opens).
        const C = engine._childLevelOf(P);
        if (!C)
            return;
        // THE REEL'S CHAIN is optional: a level with no body of the field left for it (THE BUDGET) does not open, rather than draw
        // without a surface; it waits, and opens by itself once a body is free (_bodyFreed asks its parent's contract again).
        if (engine.reelChildPopups.indexOf(C) >= 0 && C.phase === "closed" && engine._bodiesBase() >= field.maxBodies) {
            engine._reelChainWaits = true;
            return;
        }
        const edge = engine._resolveSide(P.edge, side || "far");
        const along = edge === "top" || edge === "bottom";
        // The anchor, the inset and the least length it opens at are the PARENT's content's numbers, in its units (THE RATIOS).
        const pk = P.ratio > 0 ? P.ratio : 1;
        const offset = anchor ? (along ? anchor.x : anchor.y) * pk : 0;

        if (C.live && C.parentSlot === P && C.edge === edge) {
            // Everything about where it sits eases from where it is drawn now -- unless nothing is drawn yet (_childUndrawn).
            const undrawn = engine._childUndrawn(C);
            if (!undrawn)
                engine._beginChildSlide(C);
            C.anchorOffset = offset;
            C.anchorAt = engine._anchorAtOf(opts);
            C.openAt = engine._openAtOf(opts, C.anchorAt);
            C.openMin = Math.max(0, Number(opts.openMin) || 0) * pk;
            C.askAlong = w;
            C.askOut = h;
            C.overhang = !!opts.overhang;
            C.inset = Math.max(0, Number(opts.inset) || 0) * pk;
            const keyChanged = opts.key !== undefined && opts.key !== C.key;
            C.ownerId = childOwnerId;
            if (component !== C.component)
                engine._swapContent(C, component, opts.key);
            else if (keyChanged)
                engine._swapKey(C, opts.key);
            if (undrawn)
                engine._openUndrawnAt(C);
            engine.layout();
            engine._laneEvent(engine.laneGlideMs, engine.laneGlideEasingIndex);
            return;
        }

        // Asked for again while it closes, on the same face of the same popup: it turns
        // round from where it is drawn (the OSD's rule) -- unless it has folded to
        // nothing, when it simply opens at its new place. Read before anything changes.
        // The close runs on its own forward curve (closeCurve), which only _finishClose
        // clears: left set, this open would run t to 1 ON THE CLOSE CURVE and end open, at
        // full opacity, with no height.
        const reverse = C.phase === "closing" && C.parentSlot === P && C.edge === edge
            && engine._childExtent(C) > 1e-3;
        const extentNow = reverse ? Math.min(1, engine._childExtent(C)) : 0;
        const wasClosing = C.phase === "closing";
        C.stop();
        C.parentSlot = P;
        C.ownerId = childOwnerId;
        C.edge = edge;
        C.askAlong = w;
        C.askOut = h;
        C.inset = Math.max(0, Number(opts.inset) || 0) * pk;
        C.overhang = !!opts.overhang;
        C.widthFrom = opts.widthFrom === undefined ? engine.childWidthFrom : opts.widthFrom;
        C.key = opts.key;
        C.anchorOffset = offset;
        C.anchorAt = engine._anchorAtOf(opts);
        C.openAt = engine._openAtOf(opts, C.anchorAt);
        C.openMin = Math.max(0, Number(opts.openMin) || 0) * pk;
        if (reverse) {
            engine._beginChildSlide(C);     // where it sits eases from where it is drawn
        } else {
            C.spanFrom = null;
            C.spanLast = null;
            C.slideT = 1;
        }
        C.closeCurve = false;
        C.closeFrom = 1;
        C.easingIndex = engine.childEasingIndex;
        // THE OVERSHOOT'S BIAS: from the span it opens over -- before t is placed on the curve, where a child turned round finds
        // its extent -- and, for one that starts from nothing, again from its own content once that is built (at t = 0 nothing
        // drawn moves).
        C.overshoot = engine._childOvershootFor(C);
        if (reverse)
            C.t = engine._openTimeAt(C.easingIndex, C.overshoot, extentNow);
        else if (C.phase === "closed" || wasClosing)
            C.t = 0;
        C.component = component;
        engine._assignKey(C);
        if (!reverse && C.t === 0)
            C.overshoot = engine._childOvershootFor(C);
        C.phase = "opening";
        C.framing = true;
        C.fadeTo(1, engine.contentFadeMs);
        C.runTo(1, engine.childMs);
        engine._laneEvent(engine.laneGlideMs, engine.laneGlideEasingIndex);
    }

    // opts { sequenceMs }: the time the levels below it have to close in (_closeInSequence), `childMs` unless a travel gives its own.
    function closeChild(childOwnerId, opts) {
        // By owner, at any level; none named: the primary's secondary.
        const C = childOwnerId === undefined ? childSlot
            : engine.childPopups.concat(engine.reelChildPopups).find(s => s.live && s.ownerId === childOwnerId);
        if (!C || !C.live)
            return;
        // Every level below it goes too, and goes first (the rule for a popup and its secondary, all the
        // way down) -- one after the other, the deepest first (_closeInSequence).
        const below = engine._childLevelOf(C);
        if (!!below && below.live && below.parentSlot === C) {
            engine._closeInSequence(C, opts && Number(opts.sequenceMs) > 0 ? Number(opts.sequenceMs) : engine.childMs);
            engine._laneEvent(engine.laneGlideMs, engine.laneGlideEasingIndex);
            return;
        }
        C.phase = "closing";
        C.fadeTo(0, engine.contentFadeMs);
        // On the popup's own close curve, from wherever it is: played backwards,
        // the open curve swells past full size first and is still at 83 % after
        // two thirds of the time, so nothing could overlap with it.
        C.closeFrom = engine._childExtent(C);
        C.closeCurve = true;
        C.run(Math.max(1, engine.childMs * C.closeFrom));
        engine._laneEvent(engine.laneGlideMs, engine.laneGlideEasingIndex);
    }

    // A chain closing IN SEQUENCE. Closed all at once, a tertiary would be placed against a secondary that is shrinking away under it and
    // come apart from it -- on a plain close too, not only on a travel. So the DEEPEST level goes first, on a clock that fits a third
    // of the time asked (`ms`: a travel's, else childMs; a tertiary is never very big, and the secondary then gets the remaining 2/3), and
    // every level above is HELD -- at its full box, its content showing, attached to what carries it (its box is read off its
    // parent's live one on every frame, so it travels with the primary) -- until the level below it is `closeChildLead` of the
    // way in (_waitsForChild: the rule a popup closing with its secondary out follows, _releaseCloses), then runs
    // on a third of what is left (the topmost on all of it). A child's visible close ends where its curve reaches zero --
    // the open curve's first t at 1, `_closeTailMs(.., 0, 1)` of its clock -- so a clock is sized as the window over that.
    function _closeInSequence(C, ms) {
        const levels = [C].concat(engine._descendants(C));
        let left = ms;
        for (let j = levels.length - 1; j >= 0; j--) {
            const L = levels[j];
            const mine = j === 0 ? left : left / 3;
            left -= mine;
            // (the extent first: it reads the curve the level is on now)
            const from = engine._childExtent(L);
            const visible = Math.max(0.05, engine._closeTailMs(L.easingIndex, L.overshoot, 0, 1));
            L.phase = "closing";
            L.closeFrom = from;
            L.closeCurve = true;
            L.closeMs = Math.max(1, Math.round(mine / visible));
            if (j === levels.length - 1) {
                L.fadeTo(0, engine.contentFadeMs);
                L.run(L.closeMs);
            } else {
                L.hold();
            }
        }
    }

    // ---- The child chain ---------------------------------------------------
    // The level below a slot: a primary's is the secondary, a child's the next
    // in the chain; null past the last declared level.
    function _childLevelOf(P) {
        if (P === reelSlot)
            return reelChildSlot;
        if (!P.isChild)
            return childSlot;
        for (const chain of [engine.childPopups, engine.reelChildPopups]) {
            const i = chain.indexOf(P);
            if (i >= 0)
                return i + 1 < chain.length ? chain[i + 1] : null;
        }
        return null;
    }
    // A slot's live children down the chain, nearest first.
    function _descendants(P) {
        const out = [];
        let S = P, C = engine._childLevelOf(P);
        while (C && C.live && C.parentSlot === S) {
            out.push(C);
            S = C;
            C = engine._childLevelOf(C);
        }
        return out;
    }
    function _anchorAtOf(opts) {
        const a = opts && opts.anchorAt !== undefined ? Number(opts.anchorAt) : NaN;
        return isFinite(a) ? Math.max(0, Math.min(1, a)) : 0.5;
    }
    // The point a child's open grows out of: its anchor point unless asked.
    function _openAtOf(opts, anchorAt) {
        const a = opts && opts.openAt !== undefined ? Number(opts.openAt) : NaN;
        return isFinite(a) ? Math.max(0, Math.min(1, a)) : anchorAt;
    }
    // A slot's id in the field's body list (and the OSD's sides).
    function _bodyIdOf(S) {
        if (S === slotA)
            return "slotA";
        if (S === slotB)
            return "slotB";
        if (S === laneSlot)
            return "lane";
        if (S === reelSlot)
            return "reel";
        const r = engine.reelChildPopups.indexOf(S);
        if (r >= 0)
            return r === 0 ? "reelChild" : "reelChild" + (r + 1);
        const i = engine.childPopups.indexOf(S);
        return i <= 0 ? "child" : "child" + (i + 1);
    }
    // thePopup's box and every live child's target, as one box (the OSD's push).
    function _hullWith(core, P) {
        let h = core;
        for (const C of engine._descendants(P)) {
            const t = engine._childTargetBox(C);
            const cb = t ? engine._unpushed(t, P) : null;
            if (cb)
                h = { x0: Math.min(h.x0, cb.x0), y0: Math.min(h.y0, cb.y0),
                      x1: Math.max(h.x1, cb.x1), y1: Math.max(h.y1, cb.y1) };
        }
        return h;
    }

    // THE OVERSHOOT'S BIAS (header): how far (frame px) an open whose longest edge travels `travel` px, `cross` px across
    // (Geo.crossExtent), swells past its rest, and the OutBack overshoot of a run from one box to another that gives it.
    // The cap is the engine's, or the slot's content's own `openOvershootCap` (its units, times its ratio; 0: none); the area is
    // the engine's.
    readonly property real _openOvershootCap: engine.openOvershootCap * engine._pr
    readonly property real _openOvershootArea: engine.openOvershootArea * engine._pr * engine._pr
    function _overshootCapOf(S) {
        const it = S ? S.contentItem : null;
        if (it && ("openOvershootCap" in it)) {
            const c = Number(it.openOvershootCap);
            if (isFinite(c))
                return Math.max(0, c) * (S.ratio > 0 ? S.ratio : 1);
        }
        return engine._openOvershootCap;
    }
    function openOvershootPx(travel, S, cross) {
        return Geo.biasedPeakPx(travel, engine.openOvershoot, engine._overshootCapOf(S), engine.openOvershootBend, cross,
                                engine._openOvershootArea);
    }
    // The swell of a run from box `from` to box `to` (a probe's measure, the same numbers `_overshootFor` runs on).
    function openOvershootPxFor(S, from, to) {
        return engine.openOvershootPx(Geo.edgeTravel(from, to), S, Geo.crossExtent(from, to));
    }
    function _overshootFor(S, from, to) {
        return Geo.biasedOvershoot(Geo.edgeTravel(from, to), engine.openOvershoot, engine._overshootCapOf(S), engine.openOvershootBend,
                                   Geo.crossExtent(from, to), engine._openOvershootArea);
    }
    // A child's: the span it opens over, at no extent and at full (its content's size, the parent's held box).
    function _childOvershootFor(C) {
        const a = engine._childBox(C, 0, true), b = engine._childBox(C, 1, true);
        return a && b ? engine._overshootFor(C, a, b) : engine.openOvershoot;
    }

    // The first t at which the open curve has brought a body out to `extent` of its size:
    // a scan, because a curve with overshoot swells past 1 before it settles.
    function _openTimeAt(easingIndex, overshoot, extent) {
        if (extent <= 0)
            return 0;
        const N = 240;
        let prev = Geo.ease(easingIndex, 0, overshoot);
        for (let i = 1; i <= N; i++) {
            const e = Geo.ease(easingIndex, i / N, overshoot);
            if (e >= extent) {
                const f = e - prev > 1e-9 ? (extent - prev) / (e - prev) : 1;
                return (i - 1 + Math.max(0, Math.min(1, f))) / N;
            }
            prev = e;
        }
        return 1;
    }

    // How much of the child is out, on whichever curve it is running.
    function _childExtent(C) {
        const e = Geo.ease(C.easingIndex, C.t, C.overshoot);
        return C.closeCurve ? C.closeFrom * (1 - e) : e;
    }

    // How long a child's close takes from the popup's release to all the way
    // in: the curve's first t past `lead`, to its first t at full (an OutBack
    // gets there early and swells past it; a curve that never overshoots at 1).
    function _closeTailMs(easingIndex, overshoot, lead, ms) {
        const N = 1000;
        let tLead = -1, tIn = 1;
        for (let i = 0; i <= N; i++) {
            const e = Geo.ease(easingIndex, i / N, overshoot);
            if (tLead < 0 && e >= lead)
                tLead = i / N;
            if (e >= 1 - 1e-6) {
                tIn = i / N;
                break;
            }
        }
        return tLead < 0 ? 0 : Math.max(0, (tIn - tLead) * ms);
    }

    // Whether a persistent child of S is still to wait: S is growing out of its bar and is not yet `closeChildLead` of the way
    // out -- the close played backwards (a close releases the popup when its secondary is back to 1 - closeChildLead; the reopen
    // releases the secondary when the popup is that far out). Counted on the popup's drawn extent, not on the popup's
    // CLOCK to its end: an overshooting curve is full size long before that (0.9 at 35 %, 1.0 at 45 % of an OutBack's clock), so
    // the secondary would come out when the popup had been landed for 175 ms.
    function _reopenWaits(S) {
        if (S.phase !== "opening" || (childSlot.live && childSlot.parentSlot === S))
            return false;
        return Geo.ease(S.easingIndex, S.t, S.overshoot) < engine.closeChildLead - 1e-6;
    }

    // Every layout: the held child opens on the first frame it is due.
    function _releasePendingChild() {
        const S = engine._pendingChild;
        if (!S)
            return;
        if (S !== engine._primary || !S.live || S.phase === "closing" || S.phase === "closed") {
            engine._pendingChild = null;
            return;
        }
        if (engine._reopenWaits(S))
            return;
        engine._pendingChild = null;
        engine._syncSecondary(S, true);
    }

    // A popup that is closing with its own secondary still out waits: the
    // secondary goes in first, and the popup is released on
    // the first frame the secondary is `closeChildLead` of the way in, so the
    // two overlap instead of running strictly one after the other.
    function _waitsForChild(S) {
        // The level below S: a primary's is the secondary, a child's the next in the chain (closing in sequence).
        const C = engine._childLevelOf(S);
        if (engine.closeChildLead <= 0 || !C || C.parentSlot !== S || C.phase !== "closing")
            return false;
        return engine._childExtent(C) > 1 - engine.closeChildLead + 1e-6;
    }

    // NOTHING TRAVELS OVER A FULLSCREEN WINDOW (the header): every layout, a held open starts on the first frame the popup it waits for
    // has no drawn area. (`box` is the last frame's: the frame that drew nothing is the one the new one starts after.)
    function _releaseOpenAfter() {
        for (const S of [slotA, slotB]) {
            const O = S.openAfter;
            if (O && (O.phase !== "closing" || (!O.closeHeld && !engine._hasArea(O.box))))
                engine._startHeldOpen(S);
        }
    }
    function _startHeldOpen(S) {
        S.openAfter = null;
        S.fromBox = S.originBox;
        S.box = S.originBox;
        S.fadeTo(1, engine.contentFadeMs);
        S.run(engine.openMs);
    }

    // A close held for a flourish waits for its owner (releaseClose).
    function _waitsForFlourish(S) {
        return S.flourishHold === true;
    }

    function _releaseCloses() {
        for (const S of [slotA, slotB, reelSlot].concat(engine.childPopups, engine.reelChildPopups)) {
            if (!S.closeHeld || engine._waitsForChild(S) || engine._waitsForFlourish(S))
                continue;
            // A flourish's hold faded the content already: it runs on.
            if (!S.holdFaded)
                S.fadeTo(0, engine.contentFadeMs);
            S.holdFaded = false;
            S.run(S.closeMs);
            engine._laneEvent(engine.laneGlideMs, engine.laneGlideEasingIndex);
        }
    }

    // =====================================================================
    //  The lane (theNotification; see the header)
    // =====================================================================

    // Open the lane -- or, out already, follow a new size, place or content.
    // Arguments as open(). With no room beside thePopup it does not open and
    // `laneBlocked` says so; it opens the moment there is.
    function openLane(ownerId, barId, localCenter, w, h, cornerAnim2D = false, component = null, widthFrom = 0.5,
                      alongAt = 0.5) {
        if (!track.getBarInfoById(barId))
            return;
        const at = Number(alongAt);
        engine._laneRequest = { ownerId: ownerId, barId: barId, localCenter: localCenter, w: w, h: h,
                                corner2D: !!cornerAnim2D, component: component,
                                widthFrom: Math.max(0.01, Math.min(1, widthFrom)),
                                alongAt: isFinite(at) ? Math.max(0, Math.min(1, at)) : 0.5 };
        const L = laneSlot;
        if (L.live) {
            L.ownerId = ownerId;
            if (component !== L.component)
                engine._swapContent(L, component);
        }
        engine._laneEvent(engine.resizeMs, engine.resizeEasingIndex);
    }

    // Close the lane, now. The close starts the moment
    // the last toast leaves -- a swipe that commits while the fingers are still
    // down (a pull-through) included: held until the lift, the lane would sit at full
    // height with its rows emptying for as long as the fingers stay down.
    // What a live gesture (swipeGestureActive) still holds is the END: the
    // content stays loaded and the input mask keeps its hold rect until the
    // fingers lift (_slotFinished, _laneGestureChanged), so the rest of the
    // swipe is still read by the stack and never reaches a window below.
    function closeLane() {
        engine._laneFollow = null;
        engine._laneRequest = null;
        engine._laneBlocked = false;
        engine._laneBudget = false;
        engine._laneTarget = null;
        const L = laneSlot;
        if (!L.live) {
            // Folded away waiting for room: the content kept for its size goes
            // (still closing, its own finish drops it).
            if (L.phase === "closed")
                L.component = null;
            // The body it waited for is no longer wanted: an OSD that gave way to it looks again.
            if (engine._osdBudget)
                engine._osdEvent(engine.laneGlideMs, engine.laneGlideEasingIndex);
            return;
        }
        engine._closeLane();
        engine._osdEvent(engine.laneGlideMs, engine.laneGlideEasingIndex);
    }

    // Does this slot's content hold a live gesture (the swipe-hold contract)?
    // An untyped parameter: the member is the content's own, not QQuickItem's.
    function _gestureHeld(S) {
        const it = S.contentItem;
        return !!it && it.swipeGestureActive === true;
    }

    // The content's gesture changed: a close whose end waited for it ends now
    // (or at its clock's end, if that is still to come), and the input mask
    // takes (or drops) the hold rect.
    function _laneGestureChanged() {
        if (laneSlot.phase === "closing" && laneSlot.t >= 1 && !engine._gestureHeld(laneSlot)) {
            engine._slotFinished(laneSlot);
            return;
        }
        engine.layout();
    }

    // The lane's home from its request: its bar, anchor and size, and the box
    // it opens from there. Configures the slot (bar, edge, asked size, 2D) --
    // everything but where it is going.
    function _laneHome(L, req) {
        const info = track.getBarInfoById(req.barId);
        if (!info)
            return null;
        L.barId = req.barId;
        L.edge = info.edge;
        L.localCenter = req.localCenter;
        L.askAlong = req.w;
        L.askOut = req.h;
        L.corner2D = req.corner2D;
        L.widthFrom = req.widthFrom;
        L.alongAt = req.alongAt;
        const t = engine._targetsOf(L, info, 0);
        L.homeBox = t.toBox;
        L.fullW = t.fullW;
        L.fullH = t.fullH;
        L.roomDirty = true;
        return { info: info, home: t.toBox, origin: t.originBox };
    }

    // A body handed to the field with no depth: the depth axis onto the face it hangs from (`edge` is the bar's: a top bar's popup hangs below
    // it, its face is y0), its corner radius along that axis and its stick with it. The stick is the slot's own toBox or fromBox (_stickOf), so
    // it is replaced, never written: a write there is the popup's destination gone, and it opens to nothing.
    function _collapseSliver(body, edge) {
        const X = edge === "left" || edge === "right";
        const lo = X ? "x0" : "y0", hi = X ? "x1" : "y1", r = X ? "rx" : "ry";
        const face = edge === "left" || edge === "top" ? lo : hi;
        const set = o => { if (face === lo) o[hi] = o[lo]; else o[lo] = o[hi]; };
        set(body);
        if (body.stick) {
            body.stick = Object.assign({}, body.stick);
            set(body.stick);
        }
        body[r] = 0;
    }
    function _laneAxis(edge) {
        return edge === "left" || edge === "right" ? "y" : "x";
    }

    // THE STACK FOLLOWS THE POPUP IT HANGS FROM (THE LANE GIVES WAY): called as thePopup starts to close. It applies when the stack is
    // at rest against it -- hung from its foot, or flush beside it -- and the popup closes in place on this edge.
    function _laneFollowBegin(P) {
        const L = laneSlot;
        engine._laneFollow = null;
        if (!L.live || L.phase === "closing" || L.t < 1 || !engine._hasArea(L.box) || !L.homeBox || P.edge !== L.edge)
            return;
        if (!(L.placedBelow || L.placedSide !== 0))
            return;
        engine._laneFollow = { slot: P, below: L.placedBelow, side: L.placedSide,
                               box: { x0: L.box.x0, y0: L.box.y0, x1: L.box.x1, y1: L.box.y1 } };
    }

    // The follow is over: the stack glides from where it is to its target (home) on its own clock -- or is there already. `glide`
    // false: another popup asked for; the placement that follows starts from the box it has.
    function _laneFollowEnd(glide, at) {
        const F = engine._laneFollow;
        if (F === null)
            return;
        engine._laneFollow = null;
        const L = laneSlot;
        if (!L.live)
            return;
        L.placedBelow = false;
        L.placedSide = 0;
        if (!glide)
            return;
        // (`at`: the box the stack stands at on this very frame, the last it follows)
        const to = L.toBox, b = at || L.box || F.box;
        L.stop();
        L.move = null;
        L.hopFold = false;
        L.fromBox = b;
        if (!to || engine._nearBox(b, to, 0.5)) {
            L.phase = "open";
            L.fromBox = to || b;
            L.toBox = to || b;
            L.snap();
            return;
        }
        L.phase = "moving";
        L.easingIndex = engine.laneGlideEasingIndex;
        L.overshoot = engine.openOvershoot;
        L.run(engine.laneGlideMs);
    }

    // Where the stack is on this frame while it follows: the part of its own box (`own`: the clock's, which stands at the box it
    // began at) that stays on the popup's DRAWN face, as far as home -- the popup's foot (below) or its edge on the stack's side
    // (beside) -- never ahead of it, never behind. Ends the follow (and hands over to the clock) when the popup has no box left to follow.
    function _laneFollowBox(own) {
        const F = engine._laneFollow, P = F.slot, L = laneSlot;
        const pb = P.box, home = L.toBox;
        if (!F.armed)
            return own;
        // (A stack beside the popup follows its edge while it has a box; one below it follows the foot, which a box with no depth
        // still has -- down to the bar, where it is at home across the bar: that is the end of the first leg.)
        if (P.phase !== "closing" || !home || !pb || (!F.below && !engine._hasArea(pb))) {
            engine._laneFollowEnd(true);
            return engine._slotBox(L);
        }
        const b = F.box, edge = L.edge;
        const nb = { x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y1 };
        if (F.below) {
            // across the bar: out of the popup's far face
            if (edge === "top") {
                const y0 = Math.max(pb.y1, home.y0);
                nb.y0 = y0;
                nb.y1 = y0 + (b.y1 - b.y0);
            } else if (edge === "bottom") {
                const y1 = Math.min(pb.y0, home.y1);
                nb.y1 = y1;
                nb.y0 = y1 - (b.y1 - b.y0);
            } else if (edge === "left") {
                const x0 = Math.max(pb.x1, home.x0);
                nb.x0 = x0;
                nb.x1 = x0 + (b.x1 - b.x0);
            } else {
                const x1 = Math.min(pb.x0, home.x1);
                nb.x1 = x1;
                nb.x0 = x1 - (b.x1 - b.x0);
            }
            // The foot is at the bar: the first leg is over, and the way home along the bar (if there is any) is the next, at once.
            const across = edge === "top" ? nb.y0 <= home.y0 + 0.75 : edge === "bottom" ? nb.y1 >= home.y1 - 0.75
                         : edge === "left" ? nb.x0 <= home.x0 + 0.75 : nb.x1 >= home.x1 - 0.75;
            if (across) {
                engine._laneFollowEnd(true, nb);
                return nb;
            }
        } else if (edge === "top" || edge === "bottom") {
            // beside: along the bar, its near face on the popup's, as far as home
            const len = b.x1 - b.x0;
            if (F.side < 0) {
                nb.x1 = Math.min(pb.x0, home.x1);
                nb.x0 = nb.x1 - len;
            } else {
                nb.x0 = Math.max(pb.x1, home.x0);
                nb.x1 = nb.x0 + len;
            }
        } else {
            const len = b.y1 - b.y0;
            if (F.side < 0) {
                nb.y1 = Math.min(pb.y0, home.y1);
                nb.y0 = nb.y1 - len;
            } else {
                nb.y0 = Math.max(pb.y1, home.y0);
                nb.y1 = nb.y0 + len;
            }
        }
        return nb;
    }

    // A popup that is taller than wide (the lane would stand beside it) with the stack's home against a perpendicular bar the popup
    // does not reach -- the player with its side panel hidden, a gap between it and the slim bar: the stack beside it would not
    // continue into the bar, so it hangs from its foot instead, its right edge on the popup's. The rule keys on that geometry, not on the player.
    function _laneGapCase(info, home, popup) {
        const edge = info.edge;
        const H = edge === "top" || edge === "bottom";
        const k0 = H ? "x0" : "y0", k1 = H ? "x1" : "y1", c0 = H ? "y0" : "x0", c1 = H ? "y1" : "x1";
        if (popup[k1] - popup[k0] > popup[c1] - popup[c0] + 1e-6)
            return false;
        // the stretch of this edge's axis between the bars across it
        const room = engine._acrossRoom(H ? "left" : "top");
        const tol = Math.max(1, engine._flushSnap);
        if (home[k1] >= room.hi - tol && room.hi - popup[k1] > tol)
            return true;
        return home[k0] <= room.lo + tol && popup[k0] - room.lo > tol;
    }

    // Where the lane goes, from home, out of `obs` (what _laneObstacles hands back: { all, rest, popup, popupEdge }). Beside what
    // is in its way (Geo.lanePlace) -- unless what is in its way is a popup longer along its bar than out of it, when it hangs
    // from that popup's FOOT instead (Geo.laneBelowPlace; `below` in the answer).
    function _lanePlacement(home, info, obs) {
        const axis = engine._laneAxis(info.edge), X = axis === "x";
        const lim = engine._limits(info);
        const l0 = engine._screenAlong(info.edge, lim.min), l1 = engine._screenAlong(info.edge, lim.max);
        const along = { lo: Math.min(l0, l1), hi: Math.max(l0, l1) };
        const pl = Geo.lanePlace({ axis: axis, a0: X ? home.x0 : home.y0, c0: X ? home.y0 : home.x0, c1: X ? home.y1 : home.x1 },
                                 { along: X ? home.x1 - home.x0 : home.y1 - home.y0, gap: engine.laneMelt ? 0 : engine._blendRadius },
                                 obs.all, along);
        if (engine.laneBelowWide && obs.popup && obs.popupEdge === info.edge && (pl.side !== 0 || pl.blocked)) {
            let box = Geo.laneBelowPlace(info.edge, home, obs.popup, obs.rest, along, engine._acrossRoom(info.edge));
            if (!box && engine._laneGapCase(info, home, obs.popup)) {
                // (laneBelowPlace places only under a popup longer than it is out: the same popup with its far face kept and its
                // depth taken away is one, and the along-the-bar rule -- under the popup, its edge flush -- is the one it has)
                const p = obs.popup, e = info.edge;
                const thin = e === "top" ? { x0: p.x0, y0: p.y1 - 1, x1: p.x1, y1: p.y1 }
                           : e === "bottom" ? { x0: p.x0, y0: p.y0, x1: p.x1, y1: p.y0 + 1 }
                           : e === "left" ? { x0: p.x1 - 1, y0: p.y0, x1: p.x1, y1: p.y1 }
                           : { x0: p.x0, y0: p.y0, x1: p.x0 + 1, y1: p.y1 };
                box = Geo.laneBelowPlace(e, home, thin, obs.rest, along, engine._acrossRoom(e));
            }
            if (box)
                return { box: box, side: 0, blocked: false, below: true };
        }
        return {
            box: X ? { x0: pl.a0, y0: home.y0, x1: pl.a1, y1: home.y1 } : { x0: home.x0, y0: pl.a0, x1: home.x1, y1: pl.a1 },
            side: pl.side,
            blocked: pl.blocked,
            below: false
        };
    }

    // How far across a bar's edge a box may reach: between the bars on the two edges across it (a bare edge: the screen's).
    function _acrossRoom(edge) {
        if (edge === "top" || edge === "bottom")
            return { lo: track.edgeThickness("top"), hi: track.h - track.edgeThickness("bottom") };
        return { lo: track.edgeThickness("left"), hi: track.w - track.edgeThickness("right") };
    }

    // What the lane may not be in: thePopup's TARGET box and its child's -- and
    // the box of a popup holding its close for its secondary, which is still
    // all there, content and all (_releaseCloses places the lane again when it
    // lets go).
    // { all, rest, popup, popupEdge }: every box, the same without thePopup's (a lane hung from its foot may not be on what is
    // left), thePopup's target and its edge.
    function _laneObstacles() {
        const rest = [];
        const P = engine._primary;
        const popup = P.live && P.toBox ? P.toBox : null;
        for (const S of [slotA, slotB])
            if (S.closeHeld && S.box)
                rest.push(S.box);
        for (const C of engine._descendants(P)) {
            const cb = engine._childTargetBox(C);
            if (cb)
                rest.push(cb);
        }
        // The OSD the lane was displaced for (THE OSD SLOT): it has the place.
        if ((engine._osdOverLane || engine._osdPins) && engine._osdTarget)
            rest.push(engine._osdTarget);
        // The reel's strip stands where its cell is (THE REEL SLOT): the lane goes round it.
        if (reelSlot.live && reelSlot.toBox)
            rest.push(reelSlot.toBox);
        for (const C of engine._descendants(reelSlot)) {
            const rc = engine._childTargetBox(C);
            if (rc)
                rest.push(rc);
        }
        return { all: popup ? [popup].concat(rest) : rest, rest: rest, popup: popup, popupEdge: P.edge };
    }

    // Where the child will be once it and its parent are at rest.
    function _childTargetBox(C) {
        const P = C.parentSlot;
        // A child of a child: its parent's own target, down the chain.
        const pb = !P ? null : P.isChild ? engine._childTargetBox(P) : P.toBox;
        if (!pb)
            return null;
        const sideways = C.edge === "left" || C.edge === "right";
        const t = engine._childTarget(C, pb, sideways);
        const a0 = (sideways ? pb.y0 : pb.x0) + t.rel0;
        return engine._childFace(C.edge, pb, a0, a0 + t.along, t.out, t.ins);
    }

    function _hasArea(b) {
        return !!b && b.x1 - b.x0 > 1e-6 && b.y1 - b.y0 > 1e-6;
    }

    // Do two boxes share the band across `axis` (both with extent there)?
    function _sharesBand(a, b, axis) {
        return axis === "x" ? Math.min(a.y1, b.y1) - Math.max(a.y0, b.y0) > 1e-6
                            : Math.min(a.x1, b.x1) - Math.max(a.x0, b.x0) > 1e-6;
    }

    function _mid(b, axis) {
        return axis === "x" ? (b.x0 + b.x1) / 2 : (b.y0 + b.y1) / 2;
    }

    // THE LANE PLACEMENT. Something changed where the lane may be -- thePopup's
    // target (and its child's), the lane's own request or size -- so it is
    // placed ONCE (Geo.lanePlace) and eased there over `ms` on `easing`.
    // Nothing re-places it per frame; the one per-frame rule is the clip.
    function _laneEvent(ms, easing) {
        // Inside open() / close(): they place it once, at their end.
        if (engine._laneBatch > 0)
            return;
        engine._laneEventBody(ms, easing);
        // Whatever moved the lane or thePopup may have moved the OSD's room (THE OSD SLOT).
        engine._osdEvent(ms, easing);
    }

    function _laneEventBody(ms, easing) {
        const L = laneSlot;
        const req = engine._laneRequest;
        if (!req) {
            if (L.phase !== "closed")
                engine._laneSides();
            return;
        }
        // Asked for on ANOTHER bar while it is out: it folds in on the bar it is
        // on and opens on the new one once it is in (_slotFinished asks again) --
        // a box eased from one bar's face to another's would cross the screen
        // attached to neither. Its place is not touched until then: the close
        // folds toward THIS bar's face. Under a live gesture the fold's end,
        // like any close's, waits for the lift -- also when the fold had
        // already reached it (a pull-through emptied the stack, then the spot
        // moved): nothing here has to finish it, the lift does.
        if (L.phase !== "closed" && L.barId !== req.barId) {
            if (L.live) {
                engine._laneStats.hops++;
                engine._closeLane(true);
            }
            engine._laneSides();
            engine.layout();
            return;
        }
        // Its content first: a lane sized by its content needs it to exist.
        if (!L.live && L.component !== req.component) {
            L.contentOpacity = 0;
            L.component = req.component;
        }
        L.ownerId = req.ownerId;
        const h = engine._laneHome(L, req);
        if (!h)
            return;
        const pl = engine._lanePlacement(h.home, h.info, engine._laneObstacles());
        engine._laneBlocked = pl.blocked;
        if (pl.blocked) {
            // No room either side: fold away (2D into its corner at home, else
            // into its bar away from thePopup) and wait for room.
            engine._laneBudget = false;
            engine._laneTarget = null;
            if (L.live)
                engine._closeLane(true);
            engine._laneSides();
            engine.layout();
            return;
        }
        // THE BUDGET (header): a body of the field to open into, else it waits for one, folded
        // away like the room's wait (a lane that is out folds; the layout takes its body at once
        // if the count is past the field's already).
        if (!engine._laneFits()) {
            engine._laneBudget = true;
            engine._laneTarget = null;
            if (L.live)
                engine._closeLane();
            engine._laneSides();
            engine.layout();
            return;
        }
        engine._laneBudget = false;
        engine._laneTarget = pl.box;
        // The popup it hangs from is closing and the stack goes with its drawn face (_laneFollowBox): the target is home, reached
        // when the popup is gone, and the clock waits (the mask holds the box it began at and home, as for any move).
        if (engine._laneFollow !== null && L.live) {
            L.toBox = pl.box;
            if (L.phase !== "moving") {
                L.stop();
                L.fromBox = engine._laneFollow.box;
                L.phase = "moving";
            }
            engine._laneSides();
            engine.layout();
            return;
        }
        if (!L.live) {
            engine._laneOpenFresh(L, h, pl);
            return;
        }
        // Another KIND of place -- beside the popup, or hung from its foot -- is reached by folding in here and opening there too:
        // a box eased from one to the other would cross the popup's corner. (Home is neither: a lane goes from under a popup
        // that is closing to home, and from home to under one that is opening, by a plain glide up or down its foot.)
        if ((L.placedBelow && pl.side !== 0) || (pl.below && L.placedSide !== 0)) {
            engine._laneStats.hops++;
            engine._closeLane(true);
            engine._laneSides();
            engine.layout();
            return;
        }
        // Never through a popup that is out: a new place on its far side is
        // reached by folding in here and opening there (a hop). (Hung from a foot it stays under it, whatever side of it.)
        if (!(pl.below && L.placedBelow) && engine._laneCrosses(pl.box)) {
            engine._laneStats.hops++;
            engine._closeLane(true);
            engine._laneSides();
            engine.layout();
            return;
        }
        // Hung from the foot of a popup that is growing it rides that foot: on the popup's own clock, the two faces as one.
        if (pl.below && engine._primary.phase === "opening") {
            ms = engine.openMs;
            easing = engine.openEasingIndex;
        }
        const t = L.toBox;
        if (!t || Math.abs(t.x0 - pl.box.x0) > 1e-6 || Math.abs(t.y0 - pl.box.y0) > 1e-6
                || Math.abs(t.x1 - pl.box.x1) > 1e-6 || Math.abs(t.y1 - pl.box.y1) > 1e-6) {
            L.move = null;
            L.travelling = false;
            L.hopFold = false;
            L.fromBox = L.box || L.toBox;
            L.toBox = pl.box;
            if (L.phase !== "opening")
                L.phase = "moving";
            L.easingIndex = easing;
            L.overshoot = engine._overshootFor(L, L.fromBox, L.toBox);
            L.run(ms);
            engine._laneStats.placements++;
        }
        // The side it is on from now on (a hop folds into the popup it
        // sits beside, on the side it still is).
        L.placedSide = pl.side;
        L.placedBelow = !!pl.below;
        engine._laneSides();
        engine.layout();
    }

    // Open (or reopen, from where it is while closing) at the place just found:
    // out of its corner as a point or out of its bar at home, and at its full
    // length out of the bar where it sits beside thePopup -- growing along the
    // bar there would push into it. It waits (does not open) while a popup that
    // is out still has to pass where it would be.
    function _laneOpenFresh(L, h, pl) {
        const axis = engine._laneAxis(h.info.edge), X = axis === "x";
        const p0 = X ? pl.box.x0 : pl.box.y0, p1 = X ? pl.box.x1 : pl.box.y1;
        for (const S of [engine._primary].concat(engine.childPopups)) {
            const b = S.box;
            if (!S.live || !engine._hasArea(b) || !engine._sharesBand(b, pl.box, axis))
                continue;
            // Where it is and where it is going, along the bar.
            const t = (S.isChild ? engine._childTargetBox(S) : S.toBox) || b;
            const a0 = Math.min(X ? b.x0 : b.y0, X ? t.x0 : t.y0), a1 = Math.max(X ? b.x1 : b.y1, X ? t.x1 : t.y1);
            if (Math.min(a1, p1) - Math.max(a0, p0) > 1e-6)
                return;     // _slotFinished asks again once it is at rest
        }
        // Reopened while it closes: from where it is -- unless it has folded to
        // nothing already, when it simply opens at its new place (a box with no
        // area has no presence to continue from, and starting from its point
        // would slide it through the popup it was hopping round).
        const from = L.phase === "closing" && engine._hasArea(L.box) ? L.box : null;
        // Folding in for a hop: it opens on the far side once it is in.
        if (from && engine._laneCrosses(pl.box))
            return;
        L.stop();
        L.move = null;
        L.travelling = false;
        L.hopFold = false;
        L.placedSide = pl.side;
        L.placedBelow = !!pl.below;
        L.toBox = pl.box;
        // (Hung from a foot it unrolls out of it along its whole length, as it does beside a popup.)
        L.originBox = pl.side === 0 && !pl.below ? h.origin : engine._laneFace(pl.box, h.info.edge, 0);
        L.fromBox = from || L.originBox;
        L.box = L.fromBox;
        L.phase = "opening";
        L.easingIndex = engine.openEasingIndex;
        L.overshoot = engine._overshootFor(L, L.fromBox, L.toBox);
        L.fadeTo(1, engine.contentFadeMs);
        L.run(engine.openMs);
        engine._laneStats.opens++;
        engine._laneSides();
        engine.layout();
    }

    // A box on the face of its bar: `b` with no extent out of it, along the
    // whole of it (end 0), or a point at its low (-1) or high (+1) end along.
    function _laneFace(b, edge, end) {
        const X = engine._laneAxis(edge) === "x";
        let a0 = X ? b.x0 : b.y0, a1 = X ? b.x1 : b.y1;
        if (end < 0)
            a1 = a0;
        else if (end > 0)
            a0 = a1;
        if (edge === "top")
            return { x0: a0, y0: b.y0, x1: a1, y1: b.y0 };
        if (edge === "bottom")
            return { x0: a0, y0: b.y1, x1: a1, y1: b.y1 };
        if (edge === "left")
            return { x0: b.x0, y0: a0, x1: b.x0, y1: a1 };
        return { x0: b.x1, y0: a0, x1: b.x1, y1: a1 };
    }

    // `b` folded across its whole depth onto its end NEXT to thePopup: the end at its high side (along the bar's axis) for a lane before the
    // popup (`side` -1), its low side for one after it (+1). A box with no extent along the bar and all of its own out of it.
    function _laneEdgeNext(b, edge, side) {
        if (engine._laneAxis(edge) === "x") {
            const e = side < 0 ? b.x1 : b.x0;
            return { x0: e, y0: b.y0, x1: e, y1: b.y1 };
        }
        const e = side < 0 ? b.y1 : b.y0;
        return { x0: b.x0, y0: e, x1: b.x1, y1: e };
    }

    // Close the lane from where it is: at home into the box it opened from (its
    // corner, for a 2D lane); hung from a popup's foot up into it; and beside thePopup INTO THE POPUP'S EDGE -- the whole of its own
    // face against the popup, across, its far face coming to it (not shrinking away from the popup into nothing, and not folding
    // to a point on the bar's face at that end, 2D, its height going with its width). The peers' join lets go as the lane's length falls under PRESENCE, so nothing is dragged.
    function _closeLane(hop) {
        const L = laneSlot;
        if (!L.live)
            return;
        engine._laneFollow = null;
        // A fold for a popup is the popup's right of way (THE LANE GIVES WAY); a plain close, and one for the budget, are not.
        L.hopFold = hop === true;
        L.move = null;
        L.travelling = false;
        L.fromBox = L.box || L.toBox;
        const info = track.getBarInfoById(L.barId);
        if (info) {
            const X = engine._laneAxis(L.edge) === "x";
            const b = L.fromBox, home = L.homeBox;
            // (A lane hung from a popup's foot stands at its home's place ALONG the bar all the same: it is not at home.)
            const atHome = !L.placedBelow && !!home && Math.abs((X ? b.x0 - home.x0 : b.y0 - home.y0)) < 0.5
                && Math.abs((X ? b.x1 - home.x1 : b.y1 - home.y1)) < 0.5;
            if (atHome && L.corner2D) {
                const along = X ? b.x1 - b.x0 : b.y1 - b.y0;
                L.originBox = engine._boxAt(info, engine._cornerOrigin(info, L, engine._trackPosOf(L.edge, b), along), 0, 0);
            } else if (atHome) {
                L.originBox = engine._targetsOf(L, info, 0).originBox;
            } else if (L.placedBelow) {
                L.originBox = engine._laneFace(b, L.edge, 0);
            } else {
                L.originBox = engine._laneEdgeNext(b, L.edge, L.placedSide);
            }
        }
        L.toBox = L.originBox;
        L.phase = "closing";
        L.easingIndex = engine.openEasingIndex;
        L.overshoot = engine.openOvershoot;
        L.fadeTo(0, engine.contentFadeMs);
        L.run(engine.openMs);
        engine.layout();
    }

    // Would the lane's new place `nb` be on the far side of a popup that is out
    // and in its band? It may not pass through it.
    function _laneCrosses(nb) {
        const L = laneSlot, lb = L.box;
        if (!engine._hasArea(lb))
            return false;
        const axis = engine._laneAxis(L.edge);
        for (const S of [engine._primary].concat(engine.childPopups)) {
            if (!S.live || !engine._hasArea(S.box) || !engine._sharesBand(S.box, lb, axis))
                continue;
            const t = S.isChild ? engine._childTargetBox(S) : S.toBox;
            if (!t)
                continue;
            if ((engine._mid(S.box, axis) >= engine._mid(lb, axis)) !== (engine._mid(t, axis) >= engine._mid(nb, axis)))
                return true;
        }
        return false;
    }

    // Would this migration carry thePopup THROUGH the lane? Round a corner:
    // does its path cross where the lane is or is going. Along one edge: does
    // it end on the other side of the lane than it is on now.
    function _crossesLane(P, info, localCenter, w, h, cornerAnim2D, widthFrom, srcEdge) {
        const L = laneSlot, lb = L.box;
        if (!L.live || !engine._hasArea(lb) || !engine._laneRequest || !L.homeBox)
            return false;
        const t = engine._targetsOf({ edge: info.edge, askAlong: w, askOut: h, localCenter: localCenter,
                                      corner2D: !!cornerAnim2D, widthFrom: Math.max(0.01, Math.min(1, widthFrom)),
                                      contentItem: P.contentItem, ratio: P.ratio }, info, 0);
        const lInfo = track.getBarInfoById(L.barId);
        if (!lInfo)
            return false;
        const pl = engine._lanePlacement(L.homeBox, lInfo, { all: [t.toBox], rest: [], popup: t.toBox, popupEdge: info.edge });
        if (pl.blocked || (pl.below && L.placedBelow))
            return false;
        const nb = pl.box;
        const current = P.box || P.toBox;
        const mv = engine._moveFor(current, t.toBox, srcEdge, info.edge, !!P.move);
        if (mv) {
            const hull = { x0: Math.min(lb.x0, nb.x0), y0: Math.min(lb.y0, nb.y0),
                           x1: Math.max(lb.x1, nb.x1), y1: Math.max(lb.y1, nb.y1) };
            for (let k = 0; k <= 48; k++) {
                const b = engine._polyAt(mv, k / 48).box;
                if (Math.min(b.x1, hull.x1) - Math.max(b.x0, hull.x0) > 1e-6
                        && Math.min(b.y1, hull.y1) - Math.max(b.y0, hull.y0) > 1e-6)
                    return true;
            }
            return false;
        }
        const axis = engine._laneAxis(L.edge);
        if (!engine._hasArea(current) || !engine._sharesBand(current, lb, axis))
            return false;
        return (engine._mid(current, axis) >= engine._mid(lb, axis)) !== (engine._mid(t.toBox, axis) >= engine._mid(nb, axis));
    }

    // Which side of the lane each other slot is kept on until the next
    // placement (GooeyBody.laneSide; Geo.laneClip applies it every frame). A
    // slot with area keeps the side it is on -- it cannot pass the lane without
    // the two drawn over each other -- and one with none yet (opening) takes the
    // side its target has of the lane's.
    function _laneSides() {
        const L = laneSlot;
        const lb = L.phase !== "closed" ? (L.box || L.toBox) : null;
        const lt = engine._laneTarget || lb;
        const barAxis = engine._laneAxis(L.edge);
        for (const S of [slotA, slotB].concat(engine.childPopups)) {
            if (!lb || S.phase === "closed") {
                S.laneSide = 0;
                S.laneAxis = "";
                continue;
            }
            // Stacked with the lane -- it hangs from this slot's foot -- the two are kept apart ACROSS the bar, and they keep that
            // side and that axis for as long as they share a stretch of the bar: a lane leaving from under a popup that is
            // still closing rises INTO its y-range, where they are no longer "stacked" by their boxes, and changing the axis
            // there would cut the popup sideways in one frame.
            const across = barAxis === "x" ? "y" : "x";
            if (S.laneSide !== 0 && S.laneAxis === across && !engine._laneStacked(S, lb) && engine._hasArea(S.box)
                    && engine._overlapAlong(S.box, lb, barAxis) > 1e-6)
                continue;
            const axis = engine._laneStacked(S, lb) ? across : barAxis;
            S.laneAxis = axis;
            if (engine._hasArea(S.box)) {
                S.laneSide = engine._mid(S.box, axis) >= engine._mid(lb, axis) ? 1 : -1;
                continue;
            }
            const t = S.isChild ? engine._childTargetBox(S) : S.toBox;
            S.laneSide = t && lt ? (engine._mid(t, axis) >= engine._mid(lt, axis) ? 1 : -1) : 0;
        }
    }

    // Is the lane stacked with slot `S` across its bar: hung from its foot, or -- still on its way out of there -- under it, the
    // two sharing a stretch of the bar and not a px across it? The axis they are kept apart on is the one that was between them,
    // so a lane that leaves from under a popup that is closing does not change axis in mid-motion (that would cut the popup in one frame).
    function _laneStacked(S, lb) {
        if (laneSlot.placedBelow && S === engine._primary)
            return true;
        if (!engine._hasArea(S.box) || !engine._hasArea(lb))
            return false;
        const barAxis = engine._laneAxis(laneSlot.edge), across = barAxis === "x" ? "y" : "x";
        return engine._overlapAlong(S.box, lb, barAxis) > 1e-6 && engine._overlapAlong(S.box, lb, across) <= 1e-6;
    }
    function _overlapAlong(a, b, axis) {
        return axis === "x" ? Math.min(a.x1, b.x1) - Math.max(a.x0, b.x0) : Math.min(a.y1, b.y1) - Math.max(a.y0, b.y0);
    }

    // A bar or the screen changed: the lane settles on its new place at once.
    function _laneRelayout() {
        const L = laneSlot;
        const req = engine._laneRequest;
        if (!req || !L.live)
            return;
        const h = engine._laneHome(L, req);
        if (!h)
            return;
        const pl = engine._lanePlacement(h.home, h.info, engine._laneObstacles());
        if (pl.blocked) {
            engine._laneEvent(engine.laneGlideMs, engine.laneGlideEasingIndex);
            return;
        }
        engine._laneTarget = pl.box;
        L.placedSide = pl.side;
        L.placedBelow = !!pl.below;
        L.toBox = pl.box;
        if (L.phase === "open") {
            L.fromBox = L.toBox;
            L.move = null;
        }
        engine._laneSides();
    }

    // =====================================================================
    //  The reel slot (theReel; see the header)
    // =====================================================================

    // Does the field have a body for the reel? One that is out keeps its body; a closed one opens only when the bars and
    // the primaries leave one (the lane and the OSD give theirs up in the layout: the reel comes before them).
    function _reelFits() {
        return engine._bodiesBase() < field.maxBodies;
    }

    // Open the reel's strip -- or, out already, follow it: the same owner again re-places it, another reel's cell on the same
    // edge TRAVELS the strip there (a fade swaps the ring's view), a strip closing turns round from where it is. Arguments as
    // open(); `w` is the strip's size along its bar and `h` out of it, in the content's units.
    function openReel(ownerId, barId, localCenter, w, h, component, widthFrom = 0.5) {
        const info = track.getBarInfoById(barId);
        const R = reelSlot;
        if (!info || !component)
            return;
        // THE REEL'S CHAIN is its owner's: the strip going to another owner takes it away first, the deepest level first
        // (_closeInSequence), on the travel's clock.
        if (reelChildSlot.live && R.ownerId !== ownerId)
            engine.closeChild(reelChildSlot.ownerId, { sequenceMs: engine.migrateMs });
        if (ownerId && component)
            engine._lastComponent[ownerId] = component;
        if (R.phase !== "closed" && info.edge === R.edge && (R.live || engine._hasArea(R.box))) {
            const sameOwner = R.live && R.ownerId === ownerId;
            const swap = component !== R.component;
            const current = R.box || R.toBox;
            if (swap) {
                R.swapping = true;
                R.sizeHint = sameOwner ? null : engine._rememberedSize(ownerId, component);
            }
            engine._configure(R, ownerId, info, barId, localCenter, w, h, false, widthFrom);
            if (swap)
                engine._swapContent(R, component);
            R.move = null;
            R.fromBox = current;
            R.easingIndex = engine.openEasingIndex;
            R.overshoot = engine._overshootFor(R, current, R.toBox);
            if (sameOwner) {
                // follow: a new size or place on the resize clock
                engine._retarget(R, engine.resizeEasingIndex, engine.resizeMs);
            } else if (R.phase === "closing") {
                // turned round from where it is: it opens again, the ring's fade back in
                if (!swap)
                    R.fadeTo(1, engine.contentFadeMs);
                R.phase = "opening";
                R.run(engine.openMs);
            } else {
                // another reel's cell: the strip travels there
                R.phase = "moving";
                R.travelling = true;
                R.easingIndex = engine.migrateEasingIndex;
                R.run(engine.migrateMs);
            }
            engine._laneEvent(engine.laneGlideMs, engine.laneGlideEasingIndex);
            return;
        }
        // Closing, or out on another edge (no way to travel there): gone -- its chain first, a level placed against nothing
        // would stand where the strip was -- and a fresh strip opens at its place.
        if (R.phase !== "closed") {
            for (const C of engine.reelChildPopups.slice().reverse())
                if (C.phase !== "closed")
                    engine._finishClose(C);
            engine._finishClose(R);
        }
        if (!engine._reelFits()) {
            engine._reelBudget = true;
            return;
        }
        engine._reelBudget = false;
        engine._openFresh(R, ownerId, info, barId, localCenter, w, h, false, component, widthFrom);
        engine._laneEvent(engine.laneGlideMs, engine.laneGlideEasingIndex);
    }

    // Close the strip into its bar: opts { ms, easingIndex, overshoot } as close() (the defaults are the popup's open clock).
    function closeReel(opts) {
        const R = reelSlot;
        engine._reelBudget = false;
        engine._reelChainWaits = false;
        if (!R.live)
            return;
        // THE REEL'S CHILD goes first; the strip holds at its box until it is mostly in (_releaseCloses), as a popup does.
        const childOut = reelChildSlot.live && reelChildSlot.parentSlot === R;
        if (childOut)
            engine.closeChild(reelChildSlot.ownerId);
        R.move = null;
        R.travelling = false;
        R.fromBox = R.box || R.toBox;
        R.toBox = R.originBox;
        R.phase = "closing";
        const o = opts || {};
        const num = (v, d) => {
            const n = Number(v);
            return v !== undefined && v !== null && isFinite(n) ? n : d;
        };
        R.easingIndex = Math.round(num(o.easingIndex, engine.openEasingIndex));
        R.overshoot = num(o.overshoot, engine.openOvershoot);
        R.closeMs = Math.max(1, Math.round(num(o.ms, engine.openMs)));
        if (childOut && engine._waitsForChild(R)) {
            R.hold();
            engine._releaseCloses();
        } else {
            R.fadeTo(0, engine.contentFadeMs);
            R.run(R.closeMs);
        }
        engine.layout();
        // What gave way to it comes back.
        engine._laneEvent(engine.laneGlideMs, engine.laneGlideEasingIndex);
    }

    // =====================================================================
    //  The OSD slot (theOsd; see the header)
    // =====================================================================

    // Open the OSD -- or, out already, follow a new size or place (in place), dip
    // to other content (a different component or key) or hop to another bar.
    // `along` is bar-local px (open's localCenter), `alongAt` the fraction of the
    // OSD's length that sits there; `w` / `h` null follow the content's implicit
    // size. With no room it does not open and `osdBlocked` says so; it opens the
    // moment there is.
    function openOsd(ownerId, barId, along, w, h, component, opts) {
        if (!component || !track.getBarInfoById(barId))
            return;
        const o = opts || {};
        const at = Number(o.alongAt), wf = Number(o.widthFrom), a = Number(along);
        engine._osdRequest = {
            ownerId: ownerId, barId: barId, along: isFinite(a) ? a : 0,
            w: w === undefined ? null : w, h: h === undefined ? null : h,
            component: component,
            alongAt: o.alongAt !== undefined && isFinite(at) ? Math.max(0, Math.min(1, at)) : 0.5,
            widthFrom: o.widthFrom !== undefined && isFinite(wf) ? Math.max(0.01, Math.min(1, wf)) : engine.osdWidthFrom,
            key: o.key,
            tucked: o.tucked === true
        };
        engine._osdEvent(engine.resizeMs, engine.resizeEasingIndex);
    }

    // Close the OSD (opts { ms, easingIndex }). A dip's fold in progress goes on as
    // a plain close: nothing comes back up.
    function closeOsd(opts) {
        const S = osdSlot;
        engine._osdRequest = null;
        engine._osdBlocked = false;
        engine._osdBudget = false;
        if (S.dipping) {
            S.dipping = false;
        } else if (!S.live) {
            // Folded away waiting for room: the content kept for its size goes.
            if (S.phase === "closed")
                S.component = null;
        } else {
            engine._closeOsd(opts);
        }
        engine._osdRelease();
    }

    // Everything the OSD moved for goes back: the lane it displaced, the popup it
    // pushed. Idempotent; run at every close and whenever the OSD is gone.
    function _osdRelease() {
        const wasLane = engine._osdOverLane || engine._osdPins;
        engine._osdOverLane = false;
        engine._osdPins = false;
        engine._osdTarget = null;
        engine._osdPushTo(0);
        if (wasLane)
            engine._laneAgain();
    }

    // The lane placed again, from the OSD's code (the wrapper would place the OSD
    // again too; `_laneBatch` is a popup operation's, which places both at its end).
    function _laneAgain() {
        if (engine._laneBatch === 0)
            engine._laneEventBody(engine.laneGlideMs, engine.laneGlideEasingIndex);
    }

    // The OSD's home from its request: its bar, anchor and size, and the box it
    // opens from there. Configures the slot -- everything but where it is going.
    function _osdHome(S, req) {
        const info = track.getBarInfoById(req.barId);
        if (!info)
            return null;
        S.barId = req.barId;
        S.edge = info.edge;
        S.localCenter = req.along;
        S.askAlong = req.w;
        S.askOut = req.h;
        S.corner2D = false;
        S.widthFrom = req.widthFrom;
        S.alongAt = req.alongAt;
        const t = engine._targetsOf(S, info, 0);
        // Tucked, it is placed as the sliver it is: it neither pushes nor displaces for a card nobody sees, and the corners at rest
        // are a sliver's (fullW / fullH its size: no tension in a box that is not growing).
        engine._osdTucked = req.tucked === true;
        const home = engine._osdTucked ? engine._osdTuckBox(t.toBox, info.edge) : t.toBox;
        S.homeBox = home;
        S.fullW = engine._osdTucked ? home.x1 - home.x0 : t.fullW;
        S.fullH = engine._osdTucked ? home.y1 - home.y0 : t.fullH;
        S.roomDirty = true;
        return { info: info, home: home, origin: t.originBox };
    }

    // The tuck's hover zone on whole pixels (null: no size).
    function _placeTuckZone(z) {
        const Z = osdTuckZoneItem;
        const x = z ? Math.floor(z.x0) : 0, y = z ? Math.floor(z.y0) : 0;
        const w = z ? Math.ceil(z.x1) - x : 0, h = z ? Math.ceil(z.y1) - y : 0;
        if (Z.x !== x) Z.x = x;
        if (Z.y !== y) Z.y = y;
        if (Z.width !== w) Z.width = w;
        if (Z.height !== h) Z.height = h;
    }
    // The box `b` cut to `osdTuckPx` out of the bar on `edge`: its face on the bar kept, its span along the bar kept.
    function _osdTuckBox(b, edge) {
        const k = Math.min(engine.osdTuckPx, edge === "left" || edge === "right" ? b.x1 - b.x0 : b.y1 - b.y0);
        return edge === "top" ? { x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y0 + k }
             : edge === "bottom" ? { x0: b.x0, y0: b.y1 - k, x1: b.x1, y1: b.y1 }
             : edge === "left" ? { x0: b.x0, y0: b.y0, x1: b.x0 + k, y1: b.y1 }
             : { x0: b.x1 - k, y0: b.y0, x1: b.x1, y1: b.y1 };
    }
    // Where the tucked sliver `b` is hovered: the sliver, and on a bar no thicker than osdTuckEdgeMax the bar beside it to the
    // screen's edge.
    function _osdTuckZoneBox(b, edge, thickness) {
        if (!(thickness <= engine.osdTuckEdgeMax))
            return b;
        return edge === "top" ? { x0: b.x0, y0: 0, x1: b.x1, y1: b.y1 }
             : edge === "bottom" ? { x0: b.x0, y0: b.y0, x1: b.x1, y1: track.h }
             : edge === "left" ? { x0: 0, y0: b.y0, x1: b.x1, y1: b.y1 }
             : { x0: b.x0, y0: b.y0, x1: track.w, y1: b.y1 };
    }

    // The clock a placement runs on: the lane's glide arrives as the OSD's own
    // (osdGlideMs), a resize of thePopup or of the OSD's content as the resize clock,
    // so the faces move as one.
    function _osdClock(ms, easing) {
        const glide = ms === engine.laneGlideMs && easing === engine.laneGlideEasingIndex
            && !(ms === engine.resizeMs && easing === engine.resizeEasingIndex);
        return glide ? { ms: engine.osdGlideMs, easing: engine.osdGlideEasingIndex } : { ms: ms, easing: easing };
    }

    // thePopup, as a box that moves back by what the OSD pushed it: where it would
    // stand with no OSD. The placement reads it, so the same facts give the same
    // answer at every event (a pushed popup is not an obstacle by being pushed).
    function _unpushed(b, P) {
        const v = Number(P.osdYield) || 0;
        if (!b || v === 0)
            return b;
        return P.edge === "left" || P.edge === "right"
            ? { x0: b.x0, y0: b.y0 - v, x1: b.x1, y1: b.y1 - v }
            : { x0: b.x0 - v, y0: b.y0, x1: b.x1 - v, y1: b.y1 };
    }

    function _osdBodyId(S) {
        return engine._bodyIdOf(S);
    }

    // A box AT REST ON the face of `info`'s bar: its side towards the bar lies on the face line. A popup of another bar that
    // ends flush against this bar's face -- the player, from the top bar, against the right bar (THE WALL) -- is on it too:
    // whatever hangs from the face beside it lies along the SAME line, so the two would meet either way.
    function _onFace(b, info) {
        if (!b)
            return false;
        const e = 0.5, t = info.thickness;
        return info.edge === "top" ? Math.abs(b.y0 - t) <= e
             : info.edge === "bottom" ? Math.abs(b.y1 - (track.h - t)) <= e
             : info.edge === "left" ? Math.abs(b.x0 - t) <= e
             : Math.abs(b.x1 - (track.w - t)) <= e;
    }

    // What the OSD may not be in: thePopup's TARGET box and its child's, a popup
    // holding its close for its secondary, and the lane's target. A box that lies on the OSD's
    // own bar -- of that bar, or resting flush on its face (_onFace) -- melts with it (gap 0), any other
    // is kept `blendRadius` off.
    // opt.unpushed: thePopup and its child as they would stand with no push;
    // opt.popup === false: neither (thePopup is to be pushed aside); opt.lane ===
    // false: not the lane (it is to be displaced).
    function _osdObstacles(info, opt) {
        const out = [];
        const gapOf = same => same && engine.osdMelt ? 0 : engine._blendRadius;
        const add = (b, id, edge) => {
            if (b)
                out.push({ x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y1, id: id, gap: gapOf(edge === info.edge || engine._onFace(b, info)) });
        };
        const P = engine._primary;
        const un = opt.unpushed === true, withPopup = opt.popup !== false;
        if (withPopup && P.live && P.toBox)
            add(un ? engine._unpushed(P.toBox, P) : P.toBox, engine._osdBodyId(P), P.edge);
        for (const S of [slotA, slotB])
            if (S.closeHeld && S.box && !(S === P && un))
                add(S.box, engine._osdBodyId(S), S.edge);
        if (withPopup)
            for (const C of engine._descendants(P)) {
                const cb = engine._childTargetBox(C);
                add(un ? engine._unpushed(cb, P) : cb, engine._bodyIdOf(C), P.edge);
            }
        if (opt.lane !== false && laneSlot.live && engine._laneTarget)
            add(engine._laneTarget, "lane", laneSlot.edge);
        if (reelSlot.live && reelSlot.toBox)
            add(reelSlot.toBox, "reel", reelSlot.edge);
        for (const C of engine._descendants(reelSlot))
            add(engine._childTargetBox(C), engine._bodyIdOf(C), reelSlot.edge);
        return out;
    }

    // Where the OSD goes from home, out of `obstacles` (Geo.yieldPlace).
    function _osdPlaceBox(home, info, obstacles) {
        const axis = engine._laneAxis(info.edge), X = axis === "x";
        const lim = engine._limits(info);
        const l0 = engine._screenAlong(info.edge, lim.min), l1 = engine._screenAlong(info.edge, lim.max);
        const pl = Geo.yieldPlace({ axis: axis, a0: X ? home.x0 : home.y0, c0: X ? home.y0 : home.x0, c1: X ? home.y1 : home.x1 },
                                  { along: X ? home.x1 - home.x0 : home.y1 - home.y0, gap: engine._blendRadius },
                                  obstacles, { lo: Math.min(l0, l1), hi: Math.max(l0, l1) });
        return {
            box: X ? { x0: pl.a0, y0: home.y0, x1: pl.a1, y1: home.y1 } : { x0: home.x0, y0: pl.a0, x1: home.x1, y1: pl.a1 },
            side: pl.side,
            blocked: pl.blocked,
            touching: pl.touching,
            displace: false,
            push: 0
        };
    }

    // Can the OSD push thePopup: it is out and at rest on its bar -- not a content that
    // continues its bar cell, not one being resized by hand, not travelling.
    function _pushable(P) {
        return P.live && !P.travelling && !P.closeHeld && !P.swapping && P.phase !== "closing"
            && !engine._liveOf(P) && !engine._pinnedOf(P);
    }

    // A box moved `v` px along thePopup's bar (screen axis).
    function _shifted(b, P, v) {
        if (!b || v === 0)
            return b;
        return P.edge === "left" || P.edge === "right"
            ? { x0: b.x0, y0: b.y0 + v, x1: b.x1, y1: b.y1 + v }
            : { x0: b.x0 + v, y0: b.y0, x1: b.x1 + v, y1: b.y1 };
    }

    // Would the lane still find a place if the OSD stood at `osdBox` and thePopup (and its child)
    // `shift` px from where it stands with no push? A lane with no request has nothing to keep.
    // This is the lane's own placement (Geo.lanePlace), so "fits" is exactly "does not fold".
    function _laneFitsAround(osdBox, P, shift) {
        const L = laneSlot;
        if (!engine._laneRequest || !L.homeBox)
            return true;
        const lInfo = track.getBarInfoById(L.barId);
        if (!lInfo)
            return true;
        const rest = [osdBox];
        let popup = null;
        if (P.live && P.toBox) {
            popup = engine._shifted(engine._unpushed(P.toBox, P), P, shift);
            for (const C of engine._descendants(P)) {
                const cb = engine._childTargetBox(C);
                if (cb)
                    rest.push(engine._shifted(engine._unpushed(cb, P), P, shift));
            }
        }
        for (const S of [slotA, slotB])
            if (S.closeHeld && S.box && S !== P)
                rest.push(S.box);
        const obs = popup ? [osdBox, popup].concat(rest.slice(1)) : rest;
        const pl = engine._lanePlacement(L.homeBox, lInfo, { all: obs, rest: rest, popup: popup, popupEdge: P.edge });
        if (pl.blocked)
            return false;
        // (Hung from thePopup's foot it passes nothing.)
        if (pl.below)
            return true;
        // ...and it gets there without passing thePopup (a lane whose new place is on the far side
        // of a popup that is out folds and opens there: all three visible only at the end).
        const axis = engine._laneAxis(L.edge);
        const lb = engine._hasArea(L.box) ? L.box : L.homeBox;
        for (let i = 1; i < obs.length; i++) {
            const pb = obs[i];
            if (!pb || !engine._sharesBand(pb, lb, axis))
                continue;
            if ((engine._mid(pb, axis) >= engine._mid(lb, axis)) !== (engine._mid(pb, axis) >= engine._mid(pl.box, axis)))
                return false;
        }
        return true;
    }

    // THE PRIORITY (the OSD moves first, because it lives shorter; folding is only for
    // when nothing fits):
    //   1. it glides to the free place nearest home (beside whatever is there);
    //   2. else the lane is displaced: the OSD takes home and the lane moves around it -- if
    //      the lane still finds a place;
    //   3. else thePopup is pushed along its bar by the smallest shift (never through the OSD),
    //      with the lane an obstacle that stays, or displaced as well -- the arrangement in which
    //      all three stay visible wins;
    //   4. else the best arrangement that folds the lane (2, then 3), and else it waits (blocked).
    // Returns { box, side, blocked, touching, displace, push (screen px, thePopup's) }.
    function _osdPlacement(S, h) {
        const pl = engine._osdPlacementPlan(S, h);
        // The lane is moved around the OSD AFTER it is placed, so it is not among the obstacles
        // that said what it touches: it melts with it as it arrives (a peer's weight is the gap's).
        if (!pl.blocked && engine.osdMelt && laneSlot.phase !== "closed" && laneSlot.edge === h.info.edge
                && pl.touching.indexOf("lane") < 0)
            pl.touching = pl.touching.concat(["lane"]);
        return pl;
    }

    function _osdPlacementPlan(S, h) {
        const info = h.info, P = engine._primary;
        const pushable = engine._pushable(P);
        const laneHeld = !!engine._laneRequest && laneSlot.live;
        const overLane = engine._osdOverLane && engine.osdDisplaceLane;
        let pl = null, folding = null, foldingPush = null;
        // 1. glide (with the lane in the way, unless it is displaced already)
        if (!overLane) {
            pl = engine._osdPlaceBox(h.home, info, engine._osdObstacles(info, { unpushed: pushable }));
            if (!pl.blocked)
                return pl;
        }
        // 2. the lane gives way
        if (engine.osdDisplaceLane && (overLane || laneHeld)) {
            pl = engine._osdPlaceBox(h.home, info, engine._osdObstacles(info, { unpushed: pushable, lane: false }));
            if (!pl.blocked) {
                pl.displace = true;
                if (!laneHeld || engine._laneFitsAround(pl.box, P, 0))
                    return pl;
                folding = pl;
            }
        }
        // 3. thePopup gives way
        if (engine.osdPushPopup && pushable) {
            for (const displace of overLane ? [true] : (engine.osdDisplaceLane && laneHeld ? [false, true] : [false])) {
                const q = engine._osdPushPlan(P, h, engine._osdObstacles(info, { popup: false, lane: !displace }), displace && laneHeld);
                if (!q)
                    continue;
                q.displace = displace;
                if (!displace || !laneHeld || q.laneFits)
                    return q;
                if (!foldingPush)
                    foldingPush = q;
            }
        }
        // 4. nothing keeps all three: the lane folds, with as little moved as it takes
        return folding || foldingPush || { box: h.home, side: 0, blocked: true, touching: [], displace: false, push: 0 };
    }

    // The arrangement that moves thePopup least: the OSD's place and thePopup's shift together.
    // The OSD's own nearest free place ignoring thePopup (it may be home, in the middle of a bar
    // where thePopup then has nowhere to go), and -- when they share an axis -- the places flush
    // against thePopup as it would stand pushed to either end of its limits and unpushed, the
    // OSD's own limits, and (with the lane to be moved, `moveLane`) the places that leave the lane
    // room at either end of the bar: the free ones are each tried with the smallest shift that
    // clears them, and the one that moves thePopup least wins -- among those where the lane keeps
    // a place too (`laneFits`), a tie the one nearer home. A lane that stays (`!moveLane`) is an
    // obstacle thePopup may not be pushed onto. With the OSD already out (and thePopup with it)
    // the side it is on is kept: neither passes through the other.
    // Returns { box, side, blocked, touching, displace, push, laneFits } or null.
    function _osdPushPlan(P, h, obstacles, moveLane) {
        const info = h.info, home = h.home;
        const axisO = engine._laneAxis(info.edge), X = axisO === "x";
        const cands = [];
        const q0 = engine._osdPlaceBox(home, info, obstacles);
        if (!q0.blocked)
            cands.push(q0);
        const pInfo = track.getBarInfoById(P.barId);
        if (pInfo && P.toBox && engine._laneAxis(P.edge) === axisO) {
            const core = engine._unpushed(P.toBox, P);
            const hull = engine._hullWith(core, P);
            const lim = engine._limits(pInfo);
            const pl0 = engine._screenAlong(pInfo.edge, lim.min), pl1 = engine._screenAlong(pInfo.edge, lim.max);
            const lo = Math.min(pl0, pl1), hi = Math.max(pl0, pl1);
            const k0 = X ? "x0" : "y0", k1 = X ? "x1" : "y1";
            const len = X ? home.x1 - home.x0 : home.y1 - home.y0;
            const gap = P.edge === info.edge && engine.osdMelt ? 0 : engine._blendRadius;
            const oLim = engine._limits(info);
            const o0 = engine._screenAlong(info.edge, oLim.min), o1 = engine._screenAlong(info.edge, oLim.max);
            const oLo = Math.min(o0, o1), oHi = Math.max(o0, o1);
            const at = [oLo, oHi - len];
            // The lane at an end of the bar, the OSD flush against it: all three in a row.
            if (moveLane && laneSlot.homeBox && laneSlot.edge === info.edge) {
                const lh = laneSlot.homeBox, ll = X ? lh.x1 - lh.x0 : lh.y1 - lh.y0;
                at.push(oLo + ll, oHi - ll - len);
            }
            for (const sh of [lo - core[k0], 0, hi - core[k1]]) {
                at.push(hull[k1] + sh + gap);
                at.push(hull[k0] + sh - gap - len);
            }
            for (const a0 of at) {
                const hb = X ? { x0: a0, y0: home.y0, x1: a0 + len, y1: home.y1 } : { x0: home.x0, y0: a0, x1: home.x1, y1: a0 + len };
                const q = engine._osdPlaceBox(hb, info, obstacles);
                if (!q.blocked && q.side === 0)
                    cands.push(q);
            }
        }
        const O = osdSlot;
        const keep = O.live && engine._hasArea(O.box) && engine._hasArea(P.box)
            ? (engine._mid(O.box, axisO) >= engine._mid(P.box, axisO) ? 1 : -1) : 0;
        const lt = !moveLane && laneSlot.live ? engine._laneTarget : null;
        let best = null, bf = 2, bd = Infinity, bs = Infinity;
        const hm = X ? home.x0 : home.y0;
        for (const q of cands) {
            const push = engine._osdPush(P, info, q, keep);
            if (push === null)
                continue;
            // A lane that stays must not be pushed onto.
            if (lt && engine._hasArea(lt) && engine._laneAxis(P.edge) === axisO) {
                const pb = engine._shifted(engine._unpushed(P.toBox, P), P, push.shift);
                const gapL = laneSlot.edge === P.edge && engine.laneMelt ? 0 : engine._blendRadius;
                const a0 = X ? pb.x0 : pb.y0, a1 = X ? pb.x1 : pb.y1, l0 = X ? lt.x0 : lt.y0, l1 = X ? lt.x1 : lt.y1;
                if (engine._sharesBand(pb, lt, axisO) && Math.min(a1, l1 + gapL) - Math.max(a0, l0 - gapL) > 1e-6)
                    continue;
            }
            const fit = moveLane ? (engine._laneFitsAround(q.box, P, push.shift) ? 0 : 1) : 0;
            const d = Math.abs((X ? q.box.x0 : q.box.y0) - hm), s = Math.abs(push.shift);
            if (fit < bf || (fit === bf && (s < bs - 1e-6 || (Math.abs(s - bs) <= 1e-6 && d < bd - 1e-6)))) {
                bf = fit;
                bs = s;
                bd = d;
                best = { q: q, push: push };
            }
        }
        if (!best)
            return null;
        const q = best.q;
        q.push = best.push.shift;
        q.laneFits = bf === 0;
        for (const id of best.push.touching)
            if (q.touching.indexOf(id) < 0)
                q.touching.push(id);
        return q;
    }

    // How far thePopup has to move along its bar for the OSD at `q` (a placement made
    // ignoring thePopup): { shift, touching } (the bodies it ends flush against), or
    // null when it cannot clear it. It moves away from the OSD and never through it.
    function _osdPush(P, info, q, keep) {
        const pInfo = track.getBarInfoById(P.barId);
        if (!pInfo || !P.toBox)
            return null;
        const core = engine._unpushed(P.toBox, P);
        const hull = engine._hullWith(core, P);
        const axis = engine._laneAxis(P.edge);
        const lim = engine._limits(pInfo);
        const l0 = engine._screenAlong(pInfo.edge, lim.min), l1 = engine._screenAlong(pInfo.edge, lim.max);
        const gap = P.edge === info.edge && engine.osdMelt ? 0 : engine._blendRadius;
        const r = Geo.pushPlace({ box: hull, core: core }, axis, q.box, gap, { lo: Math.min(l0, l1), hi: Math.max(l0, l1) },
                                engine._mid(q.box, axis) >= engine._mid(hull, axis) ? 1 : -1);
        if (!r)
            return null;
        // Already out beside thePopup: it stays on its side of it.
        if (keep && r.shift !== 0 && (r.shift < 0 ? 1 : -1) !== keep)
            return null;
        const touching = [];
        if (gap === 0 && r.shift !== 0) {
            const moved = (b, k) => k === "x" ? { x0: b.x0 + r.shift, y0: b.y0, x1: b.x1 + r.shift, y1: b.y1 }
                                              : { x0: b.x0, y0: b.y0 + r.shift, x1: b.x1, y1: b.y1 + r.shift };
            const k = axis === "x" ? "x" : "y";
            const flush = b => {
                const m = moved(b, k), oa = axis === "x" ? [q.box.x0, q.box.x1] : [q.box.y0, q.box.y1];
                const ma = axis === "x" ? [m.x0, m.x1] : [m.y0, m.y1];
                return Math.abs(ma[1] - oa[0]) < 1e-6 || Math.abs(ma[0] - oa[1]) < 1e-6;
            };
            if (flush(core))
                touching.push(engine._osdBodyId(P));
            // Every live level of thePopup's child chain it would end flush against.
            for (const C of engine._descendants(P)) {
                const t = engine._childTargetBox(C);
                const cb = t ? engine._unpushed(t, P) : null;
                if (cb && flush(cb))
                    touching.push(engine._osdBodyId(C));
            }
        }
        return { shift: r.shift, touching: touching };
    }

    // thePopup pushed to `v` (screen px along its bar): re-placed and eased there on the
    // resize clock; the lane then places itself against it. Not while it cannot be pushed
    // (a live resize in hand, a journey): it is placed again when that ends.
    function _osdPushTo(v) {
        const P = engine._primary;
        if (Math.abs(P.osdYield - v) < 1e-6)
            return;
        if (P.live && !engine._pushable(P))
            return;
        P.osdYield = v;
        const info = P.live ? track.getBarInfoById(P.barId) : null;
        if (!info)
            return;
        engine._placeTargets(P, info);
        engine._retarget(P, engine.resizeEasingIndex, engine.resizeMs);
        if (v !== 0)
            engine._osdStats.pushes++;
        engine._laneAgain();
    }

    // THE OSD PLACEMENT. Something changed where the OSD may be -- thePopup's target,
    // the lane's, its own request or size -- so it is placed ONCE and eased there.
    // Every _laneEvent (a popup operation, the lane's own) ends in one of these.
    function _osdEvent(ms, easing) {
        if (engine._osdBatch > 0)
            return;
        const S = osdSlot, req = engine._osdRequest;
        if (!req) {
            if (S.phase !== "closed")
                engine._osdSides();
            else
                engine._osdRelease();
            return;
        }
        engine._osdBatch++;
        try {
            engine._osdPlace(S, req, ms, easing);
        } finally {
            engine._osdBatch--;
        }
    }

    function _osdSame(S, req) {
        return req.component === S.component && req.key === S.key;
    }

    function _osdPlace(S, req, ms, easing) {
        const stats = engine._osdStats;
        // THE BUDGET (header), before anything is configured for the request: the bars and the
        // primaries have the field's bodies, then the lane (out, or asked for and not short of
        // room); the OSD waits for what is left. One that is out folds on its own clock (a dip's
        // fold goes on as a plain close; the layout takes its body at once if the count is past the
        // field's already), and the lane opens into the body when the fold ends.
        if (!engine._osdFits()) {
            engine._osdBudget = true;
            engine._osdBlocked = false;
            engine._osdRelease();
            if (S.dipping)
                S.dipping = false;
            else if (S.live)
                engine._closeOsd();
            engine._osdSides();
            engine.layout();
            return;
        }
        engine._osdBudget = false;
        // In the fold of a dip: its bottom takes the latest request. Back to the
        // content shown, on its bar, cancels the dip: it rises again from where it is.
        if (S.dipping) {
            if (engine._osdSame(S, req) && S.barId === req.barId)
                engine._osdUndip(S, req);
            return;
        }
        // Asked for on ANOTHER bar while out: it dips on this one and opens on the new
        // (the bottom). A close in progress finishes first (_slotFinished asks again).
        if (S.phase !== "closed" && S.barId !== req.barId) {
            if (S.live) {
                stats.hops++;
                engine._dipOsd(S);
            }
            return;
        }
        // Other content, or another key: a dip.
        if (S.live && !engine._osdSame(S, req)) {
            engine._dipOsd(S);
            return;
        }
        // Its content first: an OSD sized by its content needs it to exist.
        if (!S.live && S.component !== req.component) {
            S.contentOpacity = 0;
            S.component = req.component;
        }
        S.ownerId = req.ownerId;
        const wasTucked = engine._osdTucked;
        const h = engine._osdHome(S, req);
        if (!h)
            return;
        const pl = engine._osdPlacement(S, h);
        engine._osdBlocked = pl.blocked;
        if (pl.blocked) {
            // No room either side, nothing to move: fold away (at home into the bar it
            // opened from, else into its bar away from what is beside it) and wait.
            stats.blocked++;
            engine._osdTarget = null;
            const wasLane = engine._osdOverLane || engine._osdPins;
            engine._osdOverLane = false;
            engine._osdPins = false;
            engine._osdPushTo(0);
            if (wasLane)
                engine._laneAgain();
            if (S.live)
                engine._closeOsd();
            engine._osdSides();
            engine.layout();
            return;
        }
        engine._osdMove(pl);
        const t = S.toBox;
        // Never through a popup that is out: a new place on its far side is reached by
        // dipping here and opening there.
        if (S.live && engine._osdCrosses(S.box || t, pl.box)) {
            stats.hops++;
            engine._dipOsd(S);
            return;
        }
        S.peerIds = pl.touching;
        if (!S.live) {
            engine._osdOpenFresh(S, h, pl, req);
            return;
        }
        if (wasTucked !== engine._osdTucked) {
            engine._osdTuck(S, pl);
            engine._osdSides();
            engine.layout();
            return;
        }
        if (!t || Math.abs(t.x0 - pl.box.x0) > 1e-6 || Math.abs(t.y0 - pl.box.y0) > 1e-6
                || Math.abs(t.x1 - pl.box.x1) > 1e-6 || Math.abs(t.y1 - pl.box.y1) > 1e-6) {
            const clk = engine._osdClock(ms, easing);
            S.move = null;
            S.travelling = false;
            S.fromBox = S.box || S.toBox;
            S.toBox = pl.box;
            if (S.phase !== "opening")
                S.phase = "moving";
            S.easingIndex = clk.easing;
            S.overshoot = engine.osdOvershoot;
            S.run(clk.ms);
            stats.placements++;
        }
        S.placedSide = pl.side;
        engine._osdSides();
        engine.layout();
    }

    // What a placement asks of the others, applied before the OSD itself moves: the
    // lane displaced (or let go) and thePopup pushed (or let go), each placing once.
    function _osdMove(pl) {
        engine._osdTarget = pl.box;
        const was = engine._osdOverLane, wasPins = engine._osdPins;
        engine._osdOverLane = pl.displace;
        engine._osdPins = pl.push !== 0;
        if (pl.displace && !was)
            engine._osdStats.displaced++;
        engine._osdPushTo(pl.push);
        if (was !== pl.displace || wasPins !== engine._osdPins)
            engine._laneAgain();
    }

    // Would a place `nb` be on the far side of a popup that is out from where the OSD
    // is (`lb`, along the bar)? It may not pass through it.
    function _osdCrosses(lb, nb) {
        if (!lb || !nb)
            return false;
        const axis = engine._laneAxis(osdSlot.edge), X = axis === "x";
        const cb = X ? { x0: lb.x0, y0: nb.y0, x1: lb.x1, y1: nb.y1 } : { x0: nb.x0, y0: lb.y0, x1: nb.x1, y1: lb.y1 };
        for (const S of [engine._primary].concat(engine.childPopups)) {
            if (!S.live || !engine._hasArea(S.box) || !engine._sharesBand(S.box, cb, axis))
                continue;
            const t = S.isChild ? engine._childTargetBox(S) : S.toBox;
            if (!t)
                continue;
            if ((engine._mid(S.box, axis) >= engine._mid(cb, axis)) !== (engine._mid(t, axis) >= engine._mid(nb, axis)))
                return true;
        }
        return false;
    }

    // The line on the OSD's bar face that a box at `b` opens out of and folds back into: ITS OWN CENTRE, `widthFrom` of its
    // length -- what an OSD at home opens from (_targetsOf's origin) -- about the box it is PLACED at when something nudged it
    // (not from the whole face, which would fold into one END of it: the origin is the centre of the OSD popup).
    function _osdOriginAbout(b, edge, widthFrom) {
        const X = engine._laneAxis(edge) === "x";
        const f = engine._laneFace(b, edge, 0);
        const m = ((X ? b.x0 : b.y0) + (X ? b.x1 : b.y1)) / 2, half = ((X ? b.x1 - b.x0 : b.y1 - b.y0) / 2) * widthFrom;
        return X ? { x0: m - half, y0: f.y0, x1: m + half, y1: f.y1 } : { x0: f.x0, y0: m - half, x1: f.x1, y1: m + half };
    }

    // Open (or reopen, from where it is while it closes) at the place just found: out
    // of its bar about the box it is placed at (_osdOriginAbout; at home, `h.origin`).
    // It waits (does not open) while a popup that is out still has to pass where it would be.
    function _osdOpenFresh(S, h, pl, req) {
        const axis = engine._laneAxis(h.info.edge), X = axis === "x";
        const p0 = X ? pl.box.x0 : pl.box.y0, p1 = X ? pl.box.x1 : pl.box.y1;
        for (const P of [engine._primary].concat(engine.childPopups)) {
            const b = P.box;
            if (!P.live || !engine._hasArea(b) || !engine._sharesBand(b, pl.box, axis))
                continue;
            const t = (P.isChild ? engine._childTargetBox(P) : P.toBox) || b;
            const a0 = Math.min(X ? b.x0 : b.y0, X ? t.x0 : t.y0), a1 = Math.max(X ? b.x1 : b.y1, X ? t.x1 : t.y1);
            if (Math.min(a1, p1) - Math.max(a0, p0) > 1e-6)
                return;     // _slotFinished asks again once it is at rest
        }
        // Reopened while it closes: from where it is -- unless it has folded to nothing,
        // when it simply opens at its new place.
        const from = S.phase === "closing" && engine._hasArea(S.box) ? S.box : null;
        engine._osdRise(S, h, pl, from || engine._osdOriginOf(S, h, pl), engine.osdOpenMs, engine.osdOpenEasingIndex);
        S.key = req.key;
        engine._osdStats.opens++;
    }

    function _osdOriginOf(S, h, pl) {
        return pl.side === 0 ? h.origin : engine._osdOriginAbout(pl.box, h.info.edge, S.widthFrom);
    }

    // The OSD grows from `from` to `pl.box` over `ms` on `easing`: an open, or the rise
    // of a dip (from the folded face where it stands -- never from the origin).
    function _osdRise(S, h, pl, from, ms, easing) {
        S.stop();
        S.move = null;
        S.travelling = false;
        S.dipping = false;
        S.placedSide = pl.side;
        S.peerIds = pl.touching;
        S.toBox = pl.box;
        S.originBox = engine._osdOriginOf(S, h, pl);
        S.fromBox = from;
        S.box = from;
        S.phase = "opening";
        S.easingIndex = easing;
        S.overshoot = engine.osdOvershoot;
        // (a rise into the tuck -- the card hidden, come back after a dip or a fresh open -- shows no content: the sliver is all of it)
        S.fadeTo(engine._osdTucked ? 0 : 1, engine.contentFadeMs);
        S.run(ms);
        engine._osdSides();
        engine.layout();
    }

    // THE TUCK (the header): from where it is to the placed box -- the sliver, down on the close's clock with the content fading
    // out; or the card, up on the dip's rise with it fading in. A run of the "moving" phase: it stays live, and comes to rest open.
    function _osdTuck(S, pl) {
        const down = engine._osdTucked;
        S.stop();
        S.move = null;
        S.travelling = false;
        S.placedSide = pl.side;
        S.fromBox = S.box || S.toBox;
        S.toBox = pl.box;
        S.phase = "moving";
        S.easingIndex = down ? engine.osdCloseEasingIndex : engine.osdDipRiseEasingIndex;
        S.overshoot = down ? 1 : engine.osdOvershoot;
        const ms = down ? engine.osdCloseMs : engine.osdDipRiseMs;
        S.fadeTo(down ? 0 : 1, Math.min(engine.contentFadeMs, ms));
        S.run(ms);
        engine._osdStats.tucks++;
    }

    // THE DIP. A different kind (or key) while out: the OSD FOLDS into its bar from the
    // box it has now (not _openFresh, which would jump the box to the origin), its
    // content fading, and at the bottom (_osdBottom) comes back with the new one. The
    // phase is "closing" for the whole fold, so the clip, the seam fade and the sticking
    // joins are the close's own.
    function _dipOsd(S) {
        S.stop();
        S.move = null;
        S.travelling = false;
        S.dipping = true;
        S.fromBox = S.box || S.toBox;
        const X = engine._laneAxis(S.edge) === "x";
        let face = engine._laneFace(S.fromBox, S.edge, 0);
        const f = Math.max(0, Math.min(1, engine.osdDipWidthTo));
        if (f < 1) {
            const a0 = X ? face.x0 : face.y0, a1 = X ? face.x1 : face.y1;
            const m = (a0 + a1) / 2, half = (a1 - a0) / 2 * f;
            face = X ? { x0: m - half, y0: face.y0, x1: m + half, y1: face.y1 }
                     : { x0: face.x0, y0: m - half, x1: face.x1, y1: m + half };
        }
        S.toBox = face;
        S.phase = "closing";
        S.easingIndex = engine.osdDipFoldEasingIndex;
        S.overshoot = 1;
        S.fadeTo(0, Math.min(engine.contentFadeMs, engine.osdDipFoldMs));
        S.run(engine.osdDipFoldMs);
        engine._osdStats.dips++;
        engine._osdSides();
        engine.layout();
    }

    // The fold was cancelled (the content shown was asked for again): it rises from
    // where the fold has taken it, with no swap and no osdSwap.
    function _osdUndip(S, req) {
        const h = engine._osdHome(S, req);
        const pl = h ? engine._osdPlacement(S, h) : null;
        S.dipping = false;
        if (!pl || pl.blocked)
            return;     // the fold goes on as a plain close
        engine._osdBlocked = false;
        engine._osdMove(pl);
        engine._osdRise(S, h, pl, S.box || S.toBox, engine.osdDipRiseMs, engine.osdDipRiseEasingIndex);
    }

    // The bottom of a dip's fold: the owner is told (osdSwap, BEFORE anything is set:
    // it promotes its payload), the content is swapped, and the OSD rises from the
    // folded face where it stands. Another bar, a place across a popup, or no room:
    // the fold is finished and it opens fresh (or waits) where it goes now.
    function _osdBottom(S) {
        const req0 = engine._osdRequest;
        if (!req0) {
            S.dipping = false;
            engine._finishClose(S);
            engine._bodyFreed();
            return;
        }
        engine._osdBatch++;
        try {
            engine.osdSwap(req0.ownerId, req0.key);
            const req = engine._osdRequest || req0;
            let rose = false;
            if (S.barId === req.barId) {
                S.ownerId = req.ownerId;
                S.component = req.component;
                S.key = req.key;
                const h = engine._osdHome(S, req);
                const pl = h ? engine._osdPlacement(S, h) : null;
                if (pl && !pl.blocked && !engine._osdCrosses(S.box, pl.box)) {
                    engine._osdBlocked = false;
                    engine._osdMove(pl);
                    engine._osdRise(S, h, pl, S.box || S.toBox, engine.osdDipRiseMs, engine.osdDipRiseEasingIndex);
                    rose = true;
                }
            }
            if (!rose) {
                S.dipping = false;
                engine._finishClose(S);
            }
        } finally {
            engine._osdBatch--;
        }
        if (S.phase === "closed")
            engine._bodyFreed();
        if (S.phase === "closed" && engine._osdRequest)
            engine._osdEvent(engine.osdGlideMs, engine.osdGlideEasingIndex);
    }

    // Close the OSD from where it is: into the line it opened from -- at home that box's origin, nudged away from home the
    // same line about the box it is placed at (_osdOriginAbout), so it folds into its own centre whichever way it was moved.
    function _closeOsd(opts) {
        const S = osdSlot;
        if (!S.live)
            return;
        const o = opts || {};
        const num = (v, d) => {
            const n = Number(v);
            return v !== undefined && v !== null && isFinite(n) ? n : d;
        };
        const ms = Math.max(1, Math.round(num(o.ms, engine.osdCloseMs)));
        S.move = null;
        S.travelling = false;
        S.fromBox = S.box || S.toBox;
        const info = track.getBarInfoById(S.barId);
        if (info) {
            const X = engine._laneAxis(S.edge) === "x";
            const b = S.fromBox, home = S.homeBox;
            const atHome = !!home && Math.abs(X ? b.x0 - home.x0 : b.y0 - home.y0) < 0.5
                && Math.abs(X ? b.x1 - home.x1 : b.y1 - home.y1) < 0.5;
            S.originBox = atHome ? engine._targetsOf(S, info, 0).originBox
                                 : engine._osdOriginAbout(engine._hasArea(S.toBox) ? S.toBox : b, S.edge, S.widthFrom);
        }
        S.toBox = S.originBox;
        S.phase = "closing";
        S.easingIndex = Math.round(num(o.easingIndex, engine.osdCloseEasingIndex));
        S.overshoot = 1;
        S.fadeTo(0, Math.min(engine.contentFadeMs, ms));
        S.run(ms);
        engine.layout();
    }

    // Which side of each other slot the OSD is kept on until the next placement
    // (GooeyBody.yieldSides; Geo.laneClip applies it every frame): the inverse of
    // _laneSides. A slot with area keeps the side it is on -- it cannot pass the OSD
    // without the two drawn over each other -- and one with none yet (opening) takes
    // the side its target has of the OSD's.
    function _osdSides() {
        const O = osdSlot;
        const ob = O.phase !== "closed" ? (O.box || O.toBox) : null;
        const ot = engine._osdTarget || ob;
        const axis = engine._laneAxis(O.edge);
        const sides = {};
        for (const X of [slotA, slotB].concat(engine.childPopups, [laneSlot])) {
            let v = 0;
            if (ob && X.phase !== "closed") {
                if (engine._hasArea(X.box) && engine._hasArea(ob)) {
                    v = engine._mid(ob, axis) >= engine._mid(X.box, axis) ? 1 : -1;
                } else {
                    const t = X.isChild ? engine._childTargetBox(X) : (X.isLane ? (engine._laneTarget || X.toBox) : X.toBox);
                    v = t && ot ? (engine._mid(ot, axis) >= engine._mid(t, axis) ? 1 : -1) : 0;
                }
            }
            sides[engine._osdBodyId(X)] = v;
        }
        O.yieldSides = sides;
    }

    // A bar or the screen changed: the OSD settles on its new place at once.
    function _osdRelayout() {
        const S = osdSlot;
        const req = engine._osdRequest;
        if (!req || !S.live)
            return;
        const h = engine._osdHome(S, req);
        if (!h)
            return;
        const pl = engine._osdPlacement(S, h);
        if (pl.blocked) {
            engine._osdEvent(engine.osdGlideMs, engine.osdGlideEasingIndex);
            return;
        }
        engine._osdMove(pl);
        S.peerIds = pl.touching;
        S.placedSide = pl.side;
        S.toBox = pl.box;
        if (S.phase === "open") {
            S.fromBox = S.toBox;
            S.move = null;
        }
        engine._osdSides();
    }

    // =====================================================================
    //  The budget (see the header)
    // =====================================================================

    // The bodies the layout hands the field before the lane and the OSD: every bar with an
    // area and every primary-class slot (the primary, the spare, the child chain) that is not
    // closed -- a slot closing is still a body.
    function _bodiesBase() {
        let n = 0;
        for (const bar of engine.barsList)
            if (bar && bar.absW > 0 && bar.absH > 0)
                n++;
        for (const S of [slotA, slotB].concat(engine.childPopups, [reelSlot], engine.reelChildPopups))
            if (S.phase !== "closed")
                n++;
        return n;
    }

    // Does the lane have a body of the field? One that is out keeps its body while the bars and
    // the primaries leave it one. A closed one opens only into a body nobody holds -- an OSD that
    // is folding for it holds its body until the fold ends.
    function _laneFits() {
        const held = laneSlot.phase !== "closed";
        return engine._bodiesBase() + (!held && osdSlot.phase !== "closed" ? 1 : 0) < field.maxBodies;
    }

    // ...and the OSD: whatever the bars, the primaries and the lane (out, or asked for and not
    // short of room) leave. The lane has the right of way.
    function _osdFits() {
        const lane = laneSlot.phase !== "closed" || (!!engine._laneRequest && !engine._laneBlocked);
        return engine._bodiesBase() + (lane ? 1 : 0) < field.maxBodies;
    }

    // The layout found more bodies than the field draws, and the lane or the OSD is out: the
    // one that gives way goes NOW, with its request kept (it waits for a free body). An
    // animated fold from here would be drawn without a surface -- the field takes the first
    // maxBodies, and these are the last.
    function _budgetYield(S) {
        if (S.isOsd) {
            engine._osdBudget = true;
            engine._osdBlocked = false;
            // The lane it displaced and the popup it pushed go back.
            engine._osdRelease();
            engine._finishClose(S);
            engine._osdSides();
        } else {
            engine._laneBudget = true;
            engine._laneBlocked = false;
            engine._laneTarget = null;
            engine._laneFollow = null;
            engine._finishClose(S);
            engine._laneSides();
        }
    }

    // A body of the field is free (a slot finished closing, a bar went): a lane or OSD that
    // waited for one is placed again, the lane first.
    function _bodyFreed() {
        if (engine._laneBudget || engine._osdBudget)
            engine._laneEvent(engine.laneGlideMs, engine.laneGlideEasingIndex);
        // A level of the strip's chain refused for want of a body (THE BUDGET): its parent's contract is asked again, once there is
        // one -- the deepest live level's, which is the one whose child was refused.
        if (engine._reelChainWaits && engine._bodiesBase() < field.maxBodies) {
            engine._reelChainWaits = false;
            const chain = [reelSlot].concat(engine._descendants(reelSlot));
            if (reelSlot.live)
                engine._syncSecondary(chain[chain.length - 1]);
        }
    }

    // =====================================================================
    //  Internals
    // =====================================================================

    function _spare() {
        return engine._primary === slotA ? slotB : slotA;
    }

    // The slot that is not on screen, emptied and made the primary.
    function _takeSpareSlot() {
        const S = engine._spare();
        if (S.phase !== "closed")
            engine._finishClose(S);
        engine._primary = S;
        return S;
    }

    function _configure(S, ownerId, info, barId, localCenter, w, h, cornerAnim2D, widthFrom) {
        S.ownerId = ownerId;
        S.barId = barId;
        S.edge = info.edge;
        S.localCenter = localCenter;
        S.askAlong = w;
        S.askOut = h;
        S.corner2D = !!cornerAnim2D;
        S.widthFrom = Math.max(0.01, Math.min(1, widthFrom));
        engine._placeTargets(S, info);
    }

    // THE OWNER'S SIZE MEMORY. A travel is configured while the OLD content is still loaded -- the destination's loads once
    // that has faded out -- so its target would be the old content's size centred on the new anchor, short of a wall the destination
    // rests on, and would be re-aimed when the new content arrives (a gap right of the popup that appears in motion and disappears
    // when it settles). The engine remembers the size each owner's content last asked for
    // (implicit width and height: the destination's own edge decides which is along and which out) and aims the trip there from
    // its first frame (`sizeHint`, used by _asked while the old content is the one loaded); a content that arrives at another
    // size re-aims the trip, one that arrives at that size leaves it alone (_contentResized). A first-ever travel has no
    // memory and is aimed from what is loaded.
    property var _restSizes: ({})     // ownerId -> [{ comp, iw, ih, ratio }], mutated in place (nothing binds to it)
    function _rememberSize(S) {
        const it = S.contentItem;
        if (S.swapping || S.isChild || S.isLane || S.isOsd || !it || !S.component || S.ownerId === undefined || S.ownerId === "")
            return;
        // A content whose view RESETS on a reopen says what it will ask for then (`restImplicitWidth` / `restImplicitHeight`, content-owned,
        // optional): the size it has now is the view it was left in, and a trip back to it would fly at that size and turn round when the
        // fresh content arrives (the system update left in verbose, 1080 x 760, reopens in quiet, 424 x 86: the trip would flash the size of what it
        // was before returning to quiet view).
        const iw = ("restImplicitWidth" in it) && it.restImplicitWidth > 0 ? it.restImplicitWidth : it.implicitWidth;
        const ih = ("restImplicitHeight" in it) && it.restImplicitHeight > 0 ? it.restImplicitHeight : it.implicitHeight;
        if (!(iw > 0 && ih > 0))
            return;
        // (In the content's own units, with the ratio it was laid out under: the destination's, when a travel aims at it.)
        const list = engine._restSizes[S.ownerId] || (engine._restSizes[S.ownerId] = []);
        for (const e of list)
            if (e.comp === S.component) {
                e.iw = iw;
                e.ih = ih;
                e.ratio = S.ratio;
                return;
            }
        list.push({ comp: S.component, iw: iw, ih: ih, ratio: S.ratio });
    }
    function _rememberedSize(ownerId, comp) {
        const list = engine._restSizes[ownerId];
        if (list)
            for (const e of list)
                if (e.comp === comp)
                    return { iw: e.iw, ih: e.ih, ratio: e.ratio };
        return null;
    }
    function _nearBox(a, c, tol) {
        return !!a && !!c && Math.abs(a.x0 - c.x0) <= tol && Math.abs(a.y0 - c.y0) <= tol
            && Math.abs(a.x1 - c.x1) <= tol && Math.abs(a.y1 - c.y1) <= tol;
    }

    // The size a slot is asked for, along its edge and out of it, in the frame's units. A content's sizes (its implicit one, and what
    // a caller asks for) are in ITS units: times its ratio (THE RATIOS) -- the ratio of the content they were asked of, which is a
    // remembered size's own while a travel's old content is still the one loaded. A pseudo-slot without a `ratio` is ratio 1.
    function _asked(S) {
        const it = S.contentItem;
        const vertical = S.edge === "left" || S.edge === "right";
        // The content on its way out is not the destination's: a remembered size stands in for the one that is coming.
        const hint = S.swapping ? S.sizeHint : null;
        const r = hint && hint.ratio > 0 ? hint.ratio : (S.ratio > 0 ? S.ratio : 1);
        const iw = hint ? hint.iw : (it ? it.implicitWidth : 0);
        const ih = hint ? hint.ih : (it ? it.implicitHeight : 0);
        const along = S.askAlong !== null && S.askAlong !== undefined ? S.askAlong : (vertical ? ih : iw);
        const out = S.askOut !== null && S.askOut !== undefined ? S.askOut : (vertical ? iw : ih);
        return { along: Math.max(0, along * r), out: Math.max(0, out * r) };
    }

    // Where a primary rests (toBox) and where it opens from / closes to
    // (originBox), on its bar: centred on localCenter, kept inside the edge
    // and off a perpendicular bar at either end, and against one it would
    // otherwise stop short of within snapDistance (THE WALL), or on its bar's
    // end where it would stop within twice flushSnap of it (THE BAR'S END).
    //
    // `live`: a follow of a live resize. It never meets the wall mid-drag: it
    // keeps the wall shift of the placement before it for as long as the
    // content's shift is the one that placement had, and has none once the
    // content places itself -- a drag takes its new shift from hostRoom's
    // a0/a1, the box as it IS, wall and all, so from its first write the
    // content's own shift says everything. Where the drag leaves the box is
    // placed when it ends (_livePlaced).
    function _placeTargets(S, info, live) {
        engine._rememberSize(S);
        // The content's shift is along the SCREEN axis; the track runs against
        // it on the bottom and left edges.
        const shift = engine._contentShift(S);
        const wall = live ? (shift === S.placedShift ? S.wallShift : 0) : undefined;
        const t = engine._targetsOf(S, info, shift, wall);
        S.placedShift = t.shift;
        S.placedPinned = engine._pinnedOf(S);
        S.wallShift = t.wall;
        S.roomDirty = true;
        S.toBox = t.toBox;
        // THE REST FRAME (header): where this placement rests, kept apart from toBox, which a close aims at the origin.
        S.restBox = t.toBox;
        S.fullW = t.fullW;
        S.fullH = t.fullH;
        S.originBox = t.originBox;
    }

    // The same, only computed: `S` is a slot or anything with its `edge`, asked
    // size (askAlong, askOut, contentItem), localCenter, widthFrom and
    // corner2D -- a destination not configured yet, the lane's home. `wall`:
    // the wall shift to place with (a live follow's, held); undefined places
    // by the rule (_flushPlace). The rest box, the origin and a 2D open's
    // corner are all placed about the centre the rule moved, so the open grows
    // out of where the popup will rest.
    function _targetsOf(S, info, shift, wall) {
        const size = engine._asked(S);
        const lim = engine._limits(info);
        const minLimit = lim.min, maxLimit = lim.max;
        const pinned = engine._pinnedOf(S);
        const rest = engine._restPlace(info, lim, engine._anchoredCenter(info, S, shift, size.along), size.along, wall, pinned);
        // What the OSD pushed it by (THE OSD SLOT), along the track.
        const oy = engine._yieldTrack(S, info);
        const targetP = rest.p + oy, ws = rest.wall;
        const centerPos = rest.center + oy;
        const idealW = size.along * S.widthFrom;
        let startP = centerPos - idealW / 2;
        if (startP < minLimit) startP = minLimit;
        if (startP + idealW > maxLimit) startP = maxLimit - idealW;
        // An end of the origin already in a corner's pull stays where the
        // popup will rest (_originHold); a pinned content opens on its anchor.
        if (!pinned)
            startP += engine._originHold(lim, targetP, size.along, startP, idealW);

        const vertical = info.edge === "left" || info.edge === "right";
        let originBox;
        if (S.corner2D) {
            const c = engine._cornerOrigin(info, S, targetP, size.along);
            originBox = engine._boxAt(info, c, 0, 0);
        } else {
            // Clamped to the bar: a popup whose end hangs past the bar's end
            // opens out of the bar and grows over the void, instead of the
            // overhanging part appearing out of nothing.
            let o0 = Math.max(startP, info.start);
            let o1 = Math.min(startP + idealW, info.end);
            if (o1 < o0) {
                const m = Math.min(Math.max(centerPos, info.start), info.end);
                o0 = m;
                o1 = m;
            }
            originBox = engine._boxAt(info, o0, o1 - o0, 0);
        }
        return {
            toBox: engine._boxAt(info, targetP, size.along, size.out),
            originBox: originBox,
            fullW: vertical ? size.out : size.along,
            fullH: vertical ? size.along : size.out,
            shift: shift,
            wall: ws
        };
    }

    // The OSD's push of a slot (osdYield, screen px along its bar) as a distance along
    // the track, which runs against the screen axis on the bottom and left edges. A
    // pseudo-slot without one is 0.
    function _yieldTrack(S, info) {
        const v = Number(S.osdYield) || 0;
        return info.edge === "bottom" || info.edge === "left" ? -v : v;
    }

    // Where `localCenter` plus a content's `shift` puts a box's centre on the
    // track. The shift is along the SCREEN axis; the track runs against it on
    // the bottom and left edges.
    function _centerOf(info, localCenter, shift) {
        return info.start + localCenter + (info.edge === "bottom" || info.edge === "left" ? -shift : shift);
    }

    // The centre of a box `along` long whose point at `S.alongAt` of its length
    // (along the track: 0 its start, 1 its end; 0.5, its centre, for every
    // primary) is at `S.localCenter` plus a content's `shift`. The lane of a
    // spot at a bar's end (0 or 1) keeps that end as its content grows; one at
    // a fraction of its bar grows away from that point in proportion. Anything
    // without an `alongAt` (a primary's pseudo-slot) is centred.
    function _anchoredCenter(info, S, shift, along) {
        const at = S.alongAt === undefined ? 0.5 : S.alongAt;
        return engine._centerOf(info, S.localCenter, shift) + (0.5 - at) * along;
    }

    // Where a 2D open starts (a point on the track): a box held at one of its
    // ends (alongAt 0 or 1) grows out of that end -- a bar's end where the bar
    // stops short of the screen's corner (a stack at the foot of a side bar);
    // anything else, and an end that IS the corner's, out of the screen corner
    // nearest its centre (_closestCorner, whose own number is kept there).
    function _cornerOrigin(info, S, startP, along) {
        const at = S.alongAt === undefined ? 0.5 : S.alongAt;
        const c = engine._closestCorner(startP + along / 2, info);
        if (at !== 0 && at !== 1)
            return c;
        const end = startP + at * along;
        return Math.abs(end - c) < 0.5 ? c : end;
    }

    // THE REST: where a box `along` long, centred on `centerPos` (track), rests
    // on `info`'s edge -- clamped into the edge's limits `lim`, then THE WALL and
    // THE BAR'S END (_flushPlace) -- or, given `wall` (a live follow's held
    // shift), moved by that and clamped again. THE one placement: _targetsOf
    // places every box by it and hostRoom.restAt answers by it (_restAt), so a
    // content asking where a box will rest and the engine resting it cannot
    // disagree. `pinned` (a content that continues its bar cell) takes the
    // clamp alone. Returns { p: the box's start on the track, wall: the shift
    // the rule (or the held wall) took, center: centerPos moved by it }.
    function _restPlace(info, lim, centerPos, along, wall, pinned) {
        let p = centerPos - along / 2;
        if (p < lim.min) p = lim.min;
        if (p + along > lim.max) p = lim.max - along;
        if (pinned)
            return { p: p, wall: 0, center: centerPos };
        const fl = wall === undefined ? engine._flushPlace(lim, info, p, along) : null;
        const ws = wall !== undefined ? wall : (fl ? fl.shift : 0);
        if (ws !== 0) {
            centerPos += ws;
            if (fl) {
                // Exactly flush: the end on the wall's face or on the bar's
                // end, to the bit.
                p = fl.p;
            } else {
                p = centerPos - along / 2;
                if (p < lim.min) p = lim.min;
                if (p + along > lim.max) p = lim.max - along;
            }
        }
        return { p: p, wall: ws, center: centerPos };
    }

    // hostRoom.restAt(along, shift): where the engine would REST `S`'s box if
    // its content asked for `along` and `shift` now -- { a0, a1 } along the
    // edge's screen axis (hostRoom's terms), or null (no bar; the lane with no
    // room beside thePopup). A primary by _restPlace, exactly as _targetsOf
    // places it; the lane at its home as _laneHome places it -- at shift 0,
    // whatever `shift` says, since the engine never reads a lane content's
    // shift -- then beside thePopup where Geo.lanePlace would put it. Read
    // live, so it answers for the bars, walls and obstacles as they are when
    // it is called. The shift is taken as the engine takes a content's
    // (_shiftValue: not a number is 0); an `along` that is not a number has
    // no answer.
    function _restAt(S, along, shift) {
        const info = track.getBarInfoById(S.barId);
        const a = Math.max(0, Number(along));
        if (!info || !isFinite(a))
            return null;
        const lane = S.isLane || S.isOsd;
        const lim = engine._limits(info);
        const p = engine._restPlace(info, lim, engine._anchoredCenter(info, S, lane ? 0 : engine._shiftValue(shift), a), a,
                                    undefined, engine._pinnedOf(S)).p + engine._yieldTrack(S, info);
        let b = engine._boxAt(info, p, a, lane ? engine._asked(S).out : 0);
        if (S.isOsd) {
            const pl = engine._osdPlaceBox(b, info, engine._osdObstacles(info, { unpushed: engine._pushable(engine._primary) }));
            if (pl.blocked)
                return null;
            b = pl.box;
        } else if (lane) {
            const pl = engine._lanePlacement(b, info, engine._laneObstacles());
            if (pl.blocked)
                return null;
            b = pl.box;
        }
        const vertical = info.edge === "left" || info.edge === "right";
        return { a0: vertical ? b.y0 : b.x0, a1: vertical ? b.y1 : b.x1 };
    }

    // hostRoom.restAt as the content asks it: `along` and `shift` in its units, the answer in them (THE RATIOS).
    function _restAtOf(S, along, shift) {
        const k = S.ratio > 0 ? S.ratio : 1;
        const r = engine._restAt(S, Number(along) * k, engine._shiftValue(shift) * k);
        return r ? { a0: r.a0 / k, a1: r.a1 / k } : null;
    }

    // The stretch of track a popup on this edge may occupy: the edge, less the
    // perpendicular bar at either end (by that bar's own thickness).
    function _limits(info) {
        const W = track.w, H = track.h;
        let edgeStart = 0, edgeEnd = 0;
        if (info.edge === "top") { edgeStart = 0; edgeEnd = W; }
        else if (info.edge === "right") { edgeStart = W; edgeEnd = W + H; }
        else if (info.edge === "bottom") { edgeStart = W + H; edgeEnd = (W * 2) + H; }
        else { edgeStart = (W * 2) + H; edgeEnd = track.length; }
        const ins = engine._endInsets(info.edge);
        return { min: edgeStart + ins.lo, max: edgeEnd - ins.hi, loBar: ins.lo > 0, hiBar: ins.hi > 0 };
    }

    // THE ORIGIN'S END IN A CORNER. A 1D open grows out of its bar centred on
    // its anchor. An end of that origin which starts where the field already
    // pulls a face toward the perpendicular bar at the end of the edge (within
    // snapDistance of it, all the way within attachDistance) would sweep through the
    // corner of the two bars while the popup is a few px tall: its face would race
    // onto the side bar, and the slot between the two, capped by the corner's
    // C, would run across the corner in the first frames of the open and the last of
    // the close (mockups/notifications.qml's stand-in: a 300 px popup under a
    // button 90 px from the side bar rests against it, and its origin ends
    // 15 px short of it). Such an end starts at the rest end's own gap instead,
    // by the field's attach weight of where it would have started, so it does
    // not move while the popup opens -- the popup grows out of the corner along
    // its bar. An origin starting outside the pull is placed at its anchor.
    // Returns the shift of the origin along the track.
    function _originHold(lim, targetP, along, startP, idealW) {
        const aD = engine._attachDistance, sD = Math.max(engine._attachDistance + 1e-6, engine._snapDistance);
        const attach = g => g <= aD ? 1 : 1 - Geo.smoothstep(aD, sD, g);
        let d = 0;
        if (lim.hiBar) {
            const gO = lim.max - (startP + idealW), gT = lim.max - (targetP + along);
            d += Math.max(0, gO - gT) * attach(gO);
        }
        if (lim.loBar) {
            const gO = startP - lim.min, gT = targetP - lim.min;
            d -= Math.max(0, gO - gT) * attach(gO);
        }
        return d;
    }

    // THE WALL. The field draws a popup face that rests within snapDistance of
    // a perpendicular bar's face pulled toward it (GooeyGeometry: SNAPPING) --
    // all the way within attachDistance, letting go by snapDistance -- while
    // the content keeps the real box. So a popup resting 30 px off a side bar
    // would draw 16 px of surface past its content's box on that side, and a
    // content's padding would read 12 on one side and 28 on the other (the
    // notifications manager). A primary's REST box whose end would
    // stop 0 < gap < snapDistance short of the perpendicular bar at that end of
    // its edge is placed with that end FLUSH against the bar instead: moved
    // along its bar by the gap, never resized. Then the surface is the box.
    // An end already flush (the clamp), or both ends clear, moves nothing; an
    // edge too short to be clear of both walls takes the nearer, and one exactly
    // between them is left alone (the two ends are drawn alike).
    //
    // THE BAR'S END. The field also draws an END of a popup that comes within
    // flushSnap of the end of the bar it hangs from flush with that end, letting
    // go by twice flushSnap (SNAPPING again), so a popup resting a pixel short
    // of its bar's end, or past it, would be drawn a pixel off its box there -- and
    // keep its clip layer at rest (a popup at 461..711 drawn
    // from 460). A REST box whose end would come to rest 0 < |d| < 2 *
    // flushSnap from an end of its host bar is placed with that end ON the
    // bar's end: moved along the bar, never resized. The wall has the right of
    // way: a box in a wall's zone, or flush against a wall, takes the wall's
    // rule and no other, and a placement on the bar's end that would leave the
    // box in a wall's zone is not taken (there the field's larger pull, the
    // wall's, would draw it off the box again). An end already on its bar's end
    // moves nothing; both ends in the zone takes the nearer, exactly between
    // them neither; a bar's end the box cannot reach (under a perpendicular
    // bar) is none of its business. A popup hanging well past its bar's end
    // (the S of a join, blendRadius + its radius long) is not this rule's.
    //
    // `p` is the clamped rest box's start on the track; returns the shift
    // along it and the flush start, exactly -- { shift, p } -- or null.
    function _flushPlace(lim, info, p, along) {
        const eps = 1e-6, sD = engine._snapDistance;
        const gLo = lim.loBar ? p - lim.min : Infinity;
        const gHi = lim.hiBar ? lim.max - (p + along) : Infinity;
        if (gLo <= eps || gHi <= eps)
            return null;
        if (gHi < sD && gHi < gLo)
            return { shift: gHi, p: lim.max - along };
        if (gLo < sD && gLo < gHi)
            return { shift: -gLo, p: lim.min };
        if (gLo < sD || gHi < sD)
            return null;
        const z = 2 * engine._flushSnap;
        const dLo = info.start >= lim.min - eps ? Math.abs(p - info.start) : Infinity;
        const dHi = info.end <= lim.max + eps ? Math.abs(info.end - (p + along)) : Infinity;
        if (dLo <= eps || dHi <= eps)
            return null;
        let q = null;
        if (dHi < z && dHi < dLo)
            q = info.end - along;
        else if (dLo < z && dLo < dHi)
            q = info.start;
        if (q === null)
            return null;
        const nLo = lim.loBar ? q - lim.min : Infinity;
        const nHi = lim.hiBar ? lim.max - (q + along) : Infinity;
        if (nLo < -eps || nHi < -eps || (nLo > eps && nLo < sD) || (nHi > eps && nHi < sD))
            return null;
        return { shift: q - p, p: q };
    }

    // The perpendicular bars at the two ends of an edge -- `lo` where the edge
    // starts on the track, `hi` where it ends -- and how far a popup on the
    // edge stays off each: that bar's own thickness, 0 where there is none.
    function _endInsets(edge) {
        const W = track.w, H = track.h, L = track.length;
        const reach = track.edgeThickness(edge) + 2;
        let lo = null, hi = null;
        if (edge === "top") {
            lo = track.barPast(L, -1, reach);
            hi = track.barPast(W, 1, reach);
        } else if (edge === "right") {
            lo = track.barPast(W, -1, reach);
            hi = track.barPast(W + H, 1, reach);
        } else if (edge === "bottom") {
            lo = track.barPast(W + H, -1, reach);
            hi = track.barPast((W * 2) + H, 1, reach);
        } else {
            lo = track.barPast((W * 2) + H, -1, reach);
            hi = track.barPast(0, 1, reach);
        }
        return { lo: lo ? lo.thickness : 0, hi: hi ? hi.thickness : 0, loBar: lo, hiBar: hi };
    }

    // A box on the edge of the bar `info` describes, from a track position, a
    // size along it and out of it: hanging from THAT bar's face.
    function _boxAt(info, p, along, out) {
        const W = track.w, H = track.h, t = info.thickness, edge = info.edge;
        if (edge === "top")
            return { x0: p, y0: t, x1: p + along, y1: t + out };
        if (edge === "right") {
            const y0 = p - W;
            return { x0: W - t - out, y0: y0, x1: W - t, y1: y0 + along };
        }
        if (edge === "bottom") {
            const x1 = W - (p - (W + H));
            return { x0: x1 - along, y0: H - t - out, x1: x1, y1: H - t };
        }
        const y1 = H - (p - (2 * W + H));
        return { x0: t, y0: y1 - along, x1: t + out, y1: y1 };
    }

    // `after`: the slot it opens after (NOTHING TRAVELS OVER A FULLSCREEN WINDOW, the header): all of this now, the body's clock and fade when that one has gone.
    function _openFresh(S, ownerId, info, barId, localCenter, w, h, cornerAnim2D, contentComponent, widthFrom, after) {
        engine._freshContent(S, ownerId, info, barId, localCenter, w, h, cornerAnim2D, contentComponent, widthFrom);
        engine._freshStart(S, after);
    }
    function _freshContent(S, ownerId, info, barId, localCenter, w, h, cornerAnim2D, contentComponent, widthFrom) {
        S.stop();
        S.openAfter = null;
        S.travelling = false;
        S.osdYield = 0;
        // THE FLOATING POPUP: decided here, once, by the window at this moment.
        S.floatTo(0, 0);
        S.floating = engine.floatWanted && !S.isReel;
        if (S.floating)
            S.floatTo(1, 0);
        // Content first: a popup sized by its content needs it to exist.
        S.contentOpacity = 0;
        engine._installContent(S, ownerId, contentComponent);
        engine._configure(S, ownerId, info, barId, localCenter, w, h, cornerAnim2D, widthFrom);
    }
    function _freshStart(S, after) {
        S.openAfter = after || null;
        S.move = null;
        S.fromBox = S.originBox;
        S.box = S.originBox;
        S.phase = "opening";
        S.framing = true;
        S.easingIndex = engine.openEasingIndex;
        S.overshoot = engine._overshootFor(S, S.originBox, S.toBox);
        if (S.openAfter) {
            S.t = 0;
        } else {
            S.fadeTo(1, engine.contentFadeMs);
            S.run(engine.openMs);
        }
        engine.layout();
        engine._syncSecondary(S);
    }

    // A new target from where the box is, on the given clock. A migration
    // still on its way (`travelling`) stays one until it lands (_slotFinished):
    // its content's first size -- the destination loads while the popup
    // travels -- re-targets it, and clearing the flag here would let a content that
    // is live from its load (liveResizeActive: the notifications manager) take
    // the journey over and SNAP the box onto its target in one frame.
    function _retarget(S, easingIndex, ms) {
        S.move = null;
        S.fromBox = S.box || S.originBox;
        if (S.phase !== "opening") {
            S.phase = "moving";
            S.framing = false;
        }
        S.easingIndex = easingIndex;
        S.overshoot = engine._overshootFor(S, S.fromBox, S.toBox);
        S.run(ms);
    }

    // A content's new size or shift, eased from where the box is. DURING AN OPEN it stays an open: the open's own curve, from
    // where the box has got to, to the new rest (whose box the content's frame now is: THE REST FRAME). A content that settles
    // its size a frame or two after it is built -- the notifications manager's rows (54 px asked at the open, 194 two frames
    // later) -- was re-aimed on the resize clock, OutCubic, and was the one popup that never overshot. Any other time, the
    // resize clock.
    function _reaim(S) {
        if (S.phase === "opening" && !S.travelling)
            engine._retarget(S, engine.openEasingIndex, engine.openMs);
        else
            engine._retarget(S, engine.resizeEasingIndex, engine.resizeMs);
    }

    function _closeSlot(S, opts) {
        S.openAfter = null;
        if (engine._pendingChild === S)
            engine._pendingChild = null;
        if (S === engine._primary)
            engine.closeChild();
        else if (childSlot.parentSlot === S)
            engine.closeChild();
        S.move = null;
        S.travelling = false;
        S.fromBox = S.box || S.toBox;
        if (S.corner2D) {
            const b = S.fromBox;
            const info = track.getBarInfoById(S.barId);
            if (info) {
                const along = (S.edge === "left" || S.edge === "right") ? b.y1 - b.y0 : b.x1 - b.x0;
                const startP = engine._trackPosOf(S.edge, b);
                const c = engine._closestCorner(startP + along / 2, info);
                S.originBox = engine._boxAt(info, c, 0, 0);
            }
        }
        S.toBox = S.originBox;
        const atRest = S.phase === "open";
        S.phase = "closing";
        // A CLOSE OF ITS OWN (header): this close's clock, else the engine's.
        const o = opts || {};
        const num = (v, d) => {
            const n = Number(v);
            return v !== undefined && v !== null && isFinite(n) ? n : d;
        };
        S.easingIndex = Math.round(num(o.easingIndex, engine.openEasingIndex));
        S.overshoot = num(o.overshoot, engine.openOvershoot);
        S.closeMs = Math.max(1, Math.round(num(o.ms, engine.openMs)));
        const held = o.hold === true;
        // A popup at rest whose secondary is out holds its box until the
        // secondary is mostly in (_releaseCloses). One that is already moving --
        // mid-migration, mid-swap -- closes from where it is: freezing
        // it there would strand it in the middle of the screen. A close held for
        // a flourish holds wherever it is, its content fading now, until the
        // owner releases it.
        if (atRest || held) {
            // The flag first: hold() lays out (t moves), and the layout's own
            // _releaseCloses would let an unflagged hold go at once.
            S.flourishHold = held;
            S.hold();
            if (held) {
                S.fadeTo(0, engine.contentFadeMs);
                S.holdFaded = true;
            }
            engine._releaseCloses();
        } else {
            S.fadeTo(0, engine.contentFadeMs);
            S.run(S.closeMs);
        }
    }

    function _finishClose(S) {
        S.stop();
        S.openAfter = null;
        S.phase = "closed";
        S.framing = false;
        S.framed = false;
        S.closeCurve = false;
        S.closeFrom = 1;
        S.move = null;
        S.travelling = false;
        S.swapping = false;
        S.sizeHint = null;
        S.placedShift = 0;
        S.placedPinned = false;
        S.wallShift = 0;
        S.room = null;
        S.dipping = false;
        S.hopFold = false;
        S.floatTo(0, 0);
        S.floating = false;
        S.peerIds = [];
        S.yieldSides = {};
        S.osdYield = 0;
        S.placedBelow = false;
        // A primary's content is the engine's: the last closed one stays PARKED (THE PARKED CONTENT), the rest are destroyed.
        if (S === slotA || S === slotB || S === reelSlot) {
            if (S.ahead) {
                S.ahead.item.destroy();
                S.ahead = null;
            }
            engine._releaseContent(S);
        }
        // A lane folded away while its owner still wants it (blocked, or
        // hopping to its other side) keeps its content: its size decides where
        // it goes next. The OSD's request the same.
        const req = engine._laneRequest, oreq = engine._osdRequest;
        if (!((S.isLane && req && req.component === S.component) || (S.isOsd && oreq && oreq.component === S.component)))
            S.component = null;
        S.contentOpacity = 0;
        S.box = null;
        S.popX = 0;
        S.popY = 0;
        S.popW = 0;
        S.popH = 0;
        if (S.isChild)
            S.parentSlot = null;
        engine.layout();
    }

    function _slotFinished(S) {
        if (S.phase === "closing") {
            // A lane closed under a live gesture keeps its content and its
            // input hold until the lift: its box is gone
            // already. The lift finishes it (_laneGestureChanged).
            if (S.isLane && engine._gestureHeld(S))
                return;
            // The bottom of a dip: swap and rise (the OSD does not leave).
            if (S.isOsd && S.dipping) {
                engine._osdBottom(S);
                return;
            }
            if (engine._laneFollow !== null && engine._laneFollow.slot === S)
                engine._laneFollowEnd(true);
            engine._finishClose(S);
            // A body is free (THE BUDGET): a lane or OSD that waited for one looks again.
            engine._bodyFreed();
            // The reel's strip is gone: the lane and the OSD that went round it come home.
            if (S.isReel)
                engine._laneEvent(engine.laneGlideMs, engine.laneGlideEasingIndex);
            // Folded away with its owner still wanting it: open where it goes now.
            if (S.isLane && engine._laneRequest)
                engine._laneEvent(engine.laneGlideMs, engine.laneGlideEasingIndex);
            // The OSD likewise (a hop, a wait for room); and one waiting for room
            // looks again when something that was in its way is gone.
            if (engine._osdRequest || S.isOsd)
                engine._osdEvent(engine.osdGlideMs, engine.osdGlideEasingIndex);
            return;
        }
        if (S.phase === "opening" || S.phase === "moving") {
            S.phase = "open";
            S.framing = false;
            S.travelling = false;
            if (!S.isChild) {
                S.move = null;
                S.fromBox = S.toBox;
            }
        }
        engine.layout();
        // A lane that waited for a popup to come to rest opens now.
        if (!S.isLane && engine._laneRequest && !laneSlot.live)
            engine._laneEvent(engine.laneGlideMs, engine.laneGlideEasingIndex);
        // An OSD that waited for a popup to come to rest opens now.
        if (!S.isOsd && engine._osdRequest && !osdSlot.live)
            engine._osdEvent(engine.osdGlideMs, engine.osdGlideEasingIndex);
    }

    // ---- THE PARKED CONTENT (see the property block) -----------------------------------------------------
    function _honours(item) {
        return !!item && ("parked" in item);
    }
    function _recyclable(item) {
        return engine._honours(item) && typeof item.recycle === "function";
    }

    // No body is moving: what a build, or a destruction, of thousands of items may land on without a visible hitch.
    function _calm() {
        const slots = [slotA, slotB, childSlot, child2Slot, child3Slot, laneSlot, osdSlot];
        for (let i = 0; i < slots.length; i++) {
            const S = slots[i];
            const ph = S.phase;
            if (ph === "opening" || ph === "closing" || ph === "moving" || S.swapping || S.closeHeld)
                return false;
        }
        return true;
    }

    // Hover intent: build `ownerId`'s content, parked, for the click that follows. `component` is the Component the owner opens
    // with (the last one it opened with when omitted); `initial` is the properties it is created with -- `{ parked: true }` from an
    // owner whose content declares it. Built at once when the engine is at rest, else when it next is (a build is a hitch for
    // whatever moves under it). True when a content of it is parked afterwards, or on its way there.
    //
    // A BUILD AHEAD IS INCUBATED: a hovered button's fade is running, and a whole content built in one event is a 33-48 ms hole in it, on every hover
    // of five buttons and of every button a pointer rests on as it crosses the bar. Qt spreads an incubation over the frames, about 2 ms a frame while something animates; the
    // click that comes before it is done finishes it (_finishIncubation).
    function prebuild(ownerId, component, initial) {
        const c = component || engine._lastComponent[ownerId] || null;
        if (!c || c.status !== Component.Ready)
            return false;
        // The content on screen is this one's: nothing to build.
        const P = engine._primary;
        if (P.live && P.adopted && P.component === c)
            return false;
        engine._unpin(c);
        if (engine._parked && engine._parked.component === c) {
            if (!engine._parked.honours)
                parkLinger.restart();
            engine._refreshParked();
            return true;
        }
        if (engine._incubating && engine._incubating.component === c)
            return true;
        if (!engine._calm()) {
            engine._prebuildWant = { ownerId: ownerId, component: c, initial: initial || null, until: Date.now() + 3000 };
            engine.parkStats.deferred++;
            prebuildWait.restart();
            return false;
        }
        engine._prebuildNow(ownerId, c, initial);
        return true;
    }

    function _prebuildNow(ownerId, c, initial) {
        engine._prebuildWant = null;
        prebuildWait.stop();
        // One at a time: the wish waits for the build in the air, as it waits for a motion.
        if (engine._incubating) {
            engine._prebuildWant = { ownerId: ownerId, component: c, initial: initial || null, until: Date.now() + 3000 };
            prebuildWait.restart();
            return;
        }
        // A size of its own from the first moment (GooeyBody.build says why); the implicit one is set when it is parked.
        const props = { width: 0, height: 0 };
        if (initial)
            for (const k in initial)
                props[k] = initial[k];
        const inc = c.incubateObject(parkHost, props, Qt.Asynchronous);
        if (inc.status !== Component.Loading) {
            engine._incubated(ownerId, c, inc);
            return;
        }
        engine._incubating = { ownerId: ownerId, component: c, inc: inc };
        inc.onStatusChanged = function () {
            if (inc.status === Component.Loading || !engine._incubating || engine._incubating.inc !== inc)
                return;
            engine._incubating = null;
            engine._incubated(ownerId, c, inc);
        };
    }
    function _incubated(ownerId, c, inc) {
        if (inc.status !== Component.Ready) {
            console.warn("GooeyEngine: a content did not build: " + c.errorString());
            return;
        }
        engine.parkStats.prebuilds++;
        engine._parkIn(ownerId, c, inc.object, false);
    }
    // An open that wants what is still being built: the rest of the build now, in the click's own frame.
    function _finishIncubation(component) {
        const w = engine._incubating;
        if (!w || w.component !== component)
            return;
        engine._incubating = null;
        w.inc.forceCompletion();
        engine._incubated(w.ownerId, w.component, w.inc);
    }

    Timer {
        id: prebuildWait
        interval: 50
        repeat: true
        onTriggered: {
            const w = engine._prebuildWant;
            if (!w || Date.now() > w.until) {
                engine._prebuildWant = null;
                prebuildWait.stop();
                return;
            }
            if (!engine._calm())
                return;
            const P = engine._primary;
            const here = (P.live && P.adopted && P.component === w.component) || (engine._parked && engine._parked.component === w.component);
            if (here) {
                engine._prebuildWant = null;
                prebuildWait.stop();
                return;
            }
            engine._prebuildNow(w.ownerId, w.component, w.initial);
        }
    }

    // `item` becomes THE parked content (the one before it is retired). A content that has been shown (`used`) is recycled first.
    function _parkIn(ownerId, component, item, used) {
        const old = engine._parked;
        const honours = engine._honours(item);
        item.anchors.fill = undefined;
        item.parent = parkHost;
        item.visible = true;
        if (used && engine._recyclable(item))
            item.recycle();
        if (honours)
            item.parked = true;
        item.width = item.implicitWidth;
        item.height = item.implicitHeight;
        engine._parked = { ownerId: ownerId, component: component, item: item, honours: honours, at: Date.now() };
        engine._parkedSerial++;
        if (old && old.item !== item)
            engine._letGo(old);
        engine._parkClock();
    }

    // The timer of the content in the parked place: none for one that can be recycled.
    function _parkClock() {
        if (engine._parked && engine._recyclable(engine._parked.item))
            parkLinger.stop();
        else
            parkLinger.restart();
    }

    // A parked entry leaves the parked place: a pinned content waits beside it, anything else is retired.
    function _letGo(p) {
        if (p.honours && p.item.parkPinned === true) {
            engine._pinned.push(p);
            engine.parkStats.pinned++;
        } else {
            engine._retire(p.item);
        }
    }

    // `component`'s pinned content back into the parked place.
    function _unpin(component) {
        const at = engine._pinned.findIndex(p => p.component === component);
        if (at < 0)
            return;
        const p = engine._pinned.splice(at, 1)[0], old = engine._parked;
        engine._parked = p;
        engine._parkedSerial++;
        if (old)
            engine._letGo(old);
        engine._parkClock();
    }

    // What is wanted now and has been waiting: as new again (its dates, THE PARKED CONTENT above).
    function _refreshParked() {
        const p = engine._parked;
        if (!p || !engine._recyclable(p.item) || Date.now() - p.at < engine.parkMaxAgeMs)
            return;
        p.item.recycle();
        p.item.width = p.item.implicitWidth;
        p.item.height = p.item.implicitHeight;
        p.at = Date.now();
        engine.parkStats.refreshed++;
    }

    function _takeParked() {
        const p = engine._parked;
        engine._parked = null;
        engine._parkedSerial++;
        parkLinger.stop();
        return p;
    }

    // Let go of a content. One that declares `parked` is held inert and destroyed when the engine is next at rest; one that does not
    // is destroyed at once (it would run on until its deletion).
    function _retire(item) {
        if (!item)
            return;
        engine.parkStats.retired++;
        item.anchors.fill = undefined;
        item.visible = false;
        item.parent = parkHost;
        if (engine._honours(item)) {
            item.parked = true;
            engine._retiring.push(item);
            retireTimer.restart();
        } else {
            item.destroy();
        }
    }

    Timer {
        id: retireTimer
        interval: Math.max(1, engine.retireMs)
        onTriggered: {
            if (engine._retiring.length === 0)
                return;
            if (!engine._calm()) {
                retireTimer.restart();
                return;
            }
            engine._retiring.shift().destroy();
            if (engine._retiring.length > 0)
                retireTimer.restart();
        }
    }

    // A slot's content goes: the last closed content stays parked if it can be recycled (the way back, or the next open, is an
    // adoption), else it is retired.
    function _releaseContent(S) {
        const comp = S.component;
        const it = S.release();
        if (!it)
            return;
        if (comp && engine._recyclable(it)) {
            engine.parkStats.parkedAtClose++;
            engine._parkIn(S.contentOwner, comp, it, true);
        } else {
            engine._retire(it);
        }
    }

    // `component`'s content into slot `S`: the parked one adopted when it is the same, else built here in the body's frame (the
    // click's own cost). The content it replaces is let go AFTER the new one is taken (a travel's destination is
    // the parked one, and the content leaving takes its place).
    function _installContent(S, ownerId, component) {
        // The slot already shows this component (a popup asked for again while it closes, on its own slot: it turns round with its
        // content).
        if (component && S.component === component && S.contentItem) {
            S.contentOwner = ownerId;
            return;
        }
        let item = null;
        if (component) {
            engine._finishIncubation(component);
            engine._unpin(component);
        }
        if (component && engine._parked && engine._parked.component === component) {
            engine._refreshParked();
            item = engine._takeParked().item;
            engine.parkStats.adopted++;
        }
        const ahead = S.ahead;
        S.ahead = null;
        if (ahead) {
            if (!item && ahead.component === component) {
                item = ahead.item;
                engine.parkStats.built++;
            } else {
                ahead.item.destroy();
            }
        }
        engine._releaseContent(S);
        if (!component) {
            S.component = null;
            return;
        }
        if (!item && component.status === Component.Ready) {
            item = S.build(component);
            engine.parkStats.built++;
            if (!item)
                console.warn("GooeyEngine: the content of '" + ownerId + "' did not build: " + component.errorString());
        }
        S.contentOwner = ownerId;
        if (!item) {
            // a component that is not ready, or does not build: the body's Loader says why
            S.component = component;
            return;
        }
        S.adopt(item);
        S.component = component;
        if (engine._honours(item))
            item.parked = false;
        S.loaded();
    }

    // A parked content nobody took: a prebuilt one that does not declare `parked` (it runs hidden), or one that cannot be recycled and has
    // outlived `parkMaxAgeMs`.
    Timer {
        id: parkLinger
        interval: Math.max(1, engine._parked && engine._parked.honours ? engine.parkMaxAgeMs : engine.parkLingerMs)
        onTriggered: {
            const p = engine._takeParked();
            if (!p)
                return;
            if (p.honours)
                engine.parkStats.aged++;
            else
                engine.parkStats.lingered++;
            engine._retire(p.item);
        }
    }

    // ---- THE INTERACTION BOOST ---------------------------------------------------------------------------------------------
    // `boost` is the host's service ({ kick(ms) }: a raised hardware floor for that many ms from now; null = absent or off). Every body
    // whose clock starts a motion (an open, a close, a travel, a slide: GooeyBody.run / runTo / runSlide) asks for the motion's own length
    // and 100 ms more, once per motion: a kick that would end within 50 ms of the one already asked for is not sent again.
    property var boost: null
    property real _boostUntil: 0
    function kickBoost(ms) {
        const b = engine.boost;
        if (!b || ms <= 0)
            return;
        const until = Date.now() + ms + 100;
        if (until <= engine._boostUntil + 50)
            return;
        engine._boostUntil = until;
        b.kick(Math.round(ms + 100));
    }

    // ---- THE PREWARM ----------------------------------------------------------------------------------------------------
    // A popup's FIRST draw in a window links the pipelines of everything in it: weather's first visible frame carries a 91 ms gap
    // (sync 54 + render 74), and a cold open costs 30-77 ms over a warm one. A generic prewarm -- a
    // content drawn once in the bar window -- gains only 15-40 ms and leaves weather's gap, because a popup's content is drawn through the
    // body's clip LAYER while it moves, which is another set of pipelines. So this prewarm draws it through the body's own two paths.
    //
    // prewarm([{ ownerId, component, initial }, ...]) -- the host calls it once, when the shell is up and idle. For each entry, one at
    // a time and `prewarmBeatMs` apart whenever the engine is at rest with no popup out and none parked: the content is built into a
    // body made as a popup's is (GooeyBody), drawn PLAIN for `prewarmFrames` frames, then through the CLIP LAYER for as many, and
    // destroyed. The body stands in a corner of the window at 2 % scale and 2 % opacity (SiliconPrewarm's rule: inside the window and
    // its clips, above 0 so that it is drawn, a tint of a couple of levels on a patch the size of a fingernail), takes no input,
    // and is no body of the field: nothing of the engine's state, mask or budget moves. A popup asked for meanwhile ends the entry
    // in hand at once (the click is not made to wait for a warm-up), and the rest wait for the next rest.
    //
    // The content is built with the entry's `initial` (`{ parked: true }` for a content that declares it, so that it takes nothing:
    // the keyboard, a service) and stays parked: what it draws is its structure, which is what the pipelines are made of.
    // When the last entry is through, THE REEL PASS is warmed the same way (`_pwWarmPass`: its effect drawn for three frames with no tile).
    property bool prewarmEnabled: true
    property int prewarmBeatMs: 150
    property int prewarmFrames: 2
    property var prewarmStats: ({ drawn: 0, yielded: 0, waits: 0, failed: 0 })
    readonly property bool prewarming: engine._pwItem !== null || engine._pwInc !== null
    // The stage and the body the warm-up draws through, for a probe.
    property var _pwQueue: []
    property var _pwEntry: null
    property Item _pwItem: null
    // the entry being INCUBATED ({ e, inc, tb }): an entry is built by an incubator unless it says `sync` (a content kept after its
    // warm-up, the clock's, is built as it always was: THE GC law of a build whose root is parented before its completion)
    property var _pwInc: null
    property string _pwPhase: ""
    property int _pwFrames: 0

    // `info` (optional): { afterReadyMs, gate } -- what the host knows of the start, for the log line.
    function prewarm(entries, info) {
        if (!engine.prewarmEnabled || !entries)
            return;
        const nBefore = engine._pwQueue.length;
        for (let i = 0; i < entries.length; i++) {
            const e = entries[i];
            if (e && e.component)
                engine._pwQueue.push({ ownerId: e.ownerId || "", component: e.component, initial: e.initial || null, sync: e.sync === true });
        }
        // THE REEL PASS's pipeline too, once the entries are through (ReelCast.warm: its first draw is a compile the size of the
        // field's, which belongs here and not in the middle of a strip's first opening over a popup).
        engine._pwReelPass = true;
        if (engine._pwQueue.length > nBefore) {
            if (!engine._pwLog.active)
                engine._pwLog = { active: true, t0: Date.now(), reason: "", rec: null, pending: null };
            pwHeart.last = Date.now();
            pwHeart.start();
            console.log("LARES prewarm start entries=" + (engine._pwQueue.length - nBefore) + " after-ready="
                + (info && info.afterReadyMs !== undefined ? Math.round(info.afterReadyMs) : -1) + " gate=" + (info && info.gate ? info.gate : "none"));
        }
        if (engine._pwQueue.length > 0 && !engine.prewarming)
            pwBeat.restart();
        else if (!engine.prewarming)
            engine._pwWarmPass();
    }
    property bool _pwReelPass: false
    // An incubation still in flight when the shell goes (a quit seconds after `ready`) is finished and thrown away here: an incubator left
    // pending at the QML engine's destruction is a warning ("items in the process of being created at engine destruction").
    Component.onDestruction: engine._pwAbandon()
    function _pwAbandon() {
        const w = engine._pwInc;
        if (!w)
            return;
        engine._pwInc = null;
        if (w.inc.status === Component.Loading)
            w.inc.forceCompletion();
        if (w.inc.object)
            w.inc.object.destroy();
    }
    function _pwWarmPass() {
        if (!engine._pwReelPass)
            return;
        engine._pwReelPass = false;
        reelCastLayer.warm();
    }

    // At rest, and nothing a click could be waiting behind: no popup out, none parked, none asked for. The reel's strip and its side
    // popup are popups too (`_calm` does not walk them): a build under a strip that opens or closes is a stall of its motion.
    function _pwIdle() {
        return engine._pwWaitReason() === "";
    }
    // Why the warm-up waits ("" = it may build), for the log.
    function _pwWaitReason() {
        if (engine.popupOpen)
            return "popup";
        if (!engine._reelsClosed())
            return "reel";
        if (!engine._calm())
            return "motion";
        // A content parked a moment ago is what the next click may take (a hover's build ahead, a popup just closed): wait. One that
        // has stood longer is no sign of a click -- a recyclable one stays parked for good, and waiting on it stopped the warm-up for
        // ever (a popup used during the start: `LARES settled` never came).
        if (engine._parked && Date.now() - engine._parked.at < engine.parkLingerMs)
            return "parked";
        if (engine._prebuildWant)
            return "prebuild";
        if (engine._incubating)
            return "incubating";
        return "";
    }
    function _reelsClosed() {
        return reelSlot.phase === "closed" && engine.reelChildPopups.every(C => C.phase === "closed");
    }

    function _pwStep() {
        if (engine.prewarming || engine._pwQueue.length === 0)
            return;
        const why = engine._pwWaitReason();
        if (why !== engine._pwLog.reason) {
            engine._pwLog.reason = why;
            if (why !== "")
                console.log("LARES prewarm wait " + why);
        }
        if (why !== "") {
            engine.prewarmStats.waits++;
            pwBeat.restart();
            return;
        }
        const e = engine._pwQueue.shift();
        // (a pinned content already warm: an entry that yielded to a click kept what it had)
        if (engine._pinned.some(p => p.component === e.component)) {
            pwBeat.restart();
            return;
        }
        engine._pwFlush();
        const tb = Date.now();
        if (!e.sync && e.component.status === Component.Ready) {
            const inc = pwBody.incubate(e.component, e.initial);
            if (inc.status === Component.Loading) {
                engine._pwInc = { e: e, inc: inc, tb: tb };
                engine._pwLog.rec = { id: e.ownerId, t0: tb, build: -1, block: Date.now() - tb, tPhase: 0, plain: -1, clip: -1 };
                pwHeart.last = Date.now();
                inc.onStatusChanged = function () {
                    if (inc.status === Component.Loading || !engine._pwInc || engine._pwInc.inc !== inc)
                        return;
                    engine._pwIncubated();
                };
                return;
            }
            engine._pwInc = { e: e, inc: inc, tb: tb };
            engine._pwIncubated();
            return;
        }
        const item = e.component.status === Component.Ready ? pwBody.build(e.component, e.initial) : null;
        const tBuilt = Date.now();
        engine._pwShow(e, item, tb, tBuilt);
    }
    // An incubated entry is built: shown as a built one is, unless a click came meanwhile (then it goes, and the entry waits again).
    function _pwIncubated() {
        const w = engine._pwInc;
        engine._pwInc = null;
        const item = w.inc.status === Component.Ready ? w.inc.object : null;
        const tBuilt = Date.now();
        if (item && engine._pwWaitReason() !== "") {
            item.destroy();
            engine.prewarmStats.yielded++;
            console.log("LARES prewarm yield " + w.e.ownerId);
            w.e.tries = (w.e.tries || 0) + 1;
            if (w.e.tries < 5)
                engine._pwQueue.unshift(w.e);
            engine._pwLog.rec = null;
            pwBeat.restart();
            return;
        }
        const rec = engine._pwLog.rec;
        engine._pwShow(w.e, item, w.tb, tBuilt);
        if (rec && engine._pwLog.rec)
            engine._pwLog.rec.block = Math.max(engine._pwLog.rec.block, rec.block);
    }
    function _pwShow(e, item, tb, tBuilt) {
        if (!item) {
            console.log("LARES prewarm failed " + e.ownerId);
            engine.prewarmStats.failed++;
            pwBeat.restart();
            return;
        }
        engine._pwEntry = e;
        engine._pwItem = item;
        pwBody.popW = Math.max(1, item.implicitWidth);
        pwBody.popH = Math.max(1, item.implicitHeight);
        pwBody.adopt(item);
        pwBody.contentOpacity = 1;
        engine._pwPhase = "plain";
        engine._pwFrames = 0;
        engine._pwLog.rec = { id: e.ownerId, t0: tb, build: tBuilt - tb, block: e.sync || !engine._pwLog.rec ? tBuilt - tb : 0, tPhase: Date.now(), plain: -1, clip: -1 };
        pwHeart.last = Date.now();
        pwWatchdog.restart();
    }

    // One frame of the warm-up swapped: the plain path is shown for `prewarmFrames`, then the layer's.
    function _pwFrame() {
        if (!engine._pwItem)
            return;
        // A click: the content in hand goes at once, and its entry waits for the next rest (a few times at most).
        if (engine.popupOpen || !engine._reelsClosed() || !engine._calm()) {
            engine.prewarmStats.yielded++;
            console.log("LARES prewarm yield " + engine._pwEntry.ownerId);
            if (engine._pwLog.rec)
                engine._pwLog.rec.yielded = true;
            const e = engine._pwEntry;
            e.tries = (e.tries || 0) + 1;
            if (e.tries < 5)
                engine._pwQueue.unshift(e);
            engine._pwEnd();
            return;
        }
        engine._pwFrames++;
        if (engine._pwFrames < engine.prewarmFrames)
            return;
        if (engine._pwPhase === "plain") {
            if (engine._pwLog.rec) {
                engine._pwLog.rec.plain = Date.now() - engine._pwLog.rec.tPhase;
                engine._pwLog.rec.tPhase = Date.now();
            }
            engine._pwPhase = "clip";
            engine._pwFrames = 0;
            pwBody.clipBox = Qt.vector4d(0, 0, pwBody.popW, pwBody.popH);
            pwBody.clipOn = true;
            return;
        }
        engine.prewarmStats.drawn++;
        if (engine._pwLog.rec)
            engine._pwLog.rec.clip = Date.now() - engine._pwLog.rec.tPhase;
        engine._pwEnd();
    }

    function _pwEnd() {
        const it = pwBody.release();
        const e = engine._pwEntry;
        pwBody.clipOn = false;
        pwBody.popW = 0;
        pwBody.popH = 0;
        engine._pwItem = null;
        engine._pwEntry = null;
        engine._pwPhase = "";
        pwWatchdog.stop();
        if (it && it.parkPinned === true && engine._recyclable(it) && e) {
            // built and warm: it is what its first hover would build
            it.parent = parkHost;
            it.visible = true;
            it.width = it.implicitWidth;
            it.height = it.implicitHeight;
            engine._letGo({ ownerId: e.ownerId, component: e.component, item: it, honours: true, at: Date.now() });
            if (engine._pwLog.rec)
                engine._pwLog.rec.kept = true;
        } else if (it) {
            it.destroy();
        }
        // the entry's line waits for the next heartbeat: a deferred deletion lands in between, and its gap is the entry's
        if (engine._pwLog.rec) {
            engine._pwLog.rec.tDestroy = Date.now();
            engine._pwLog.pending = engine._pwLog.rec;
            engine._pwLog.rec = null;
        }
        if (engine._pwQueue.length > 0)
            pwBeat.restart();
        else
            engine._pwWarmPass();
    }

    // ---- the warm-up's log (one line per entry, measured by a 16 ms heartbeat: its lateness is the GUI thread's block) ----
    // LARES prewarm start entries=<n> after-ready=<ms> gate=<why>   LARES prewarm wait <reason>   LARES prewarm yield <id>
    // LARES prewarm entry <id> build=<ms> block=<ms> plain=<ms> clip=<ms> destroy=<ms>|kept   LARES prewarm end drawn= yielded= failed= total=
    property var _pwLog: ({ active: false, t0: 0, reason: "", rec: null, pending: null })
    function _pwFlush() {
        const r = engine._pwLog.pending;
        if (!r)
            return;
        engine._pwLog.pending = null;
        console.log("LARES prewarm entry " + r.id + " build=" + r.build + " block=" + r.block + " plain=" + r.plain + " clip=" + r.clip
            + (r.yielded ? " yielded" : r.kept ? " destroy=kept" : " destroy=" + (r.destroyMs !== undefined ? r.destroyMs : -1)));
    }
    Timer {
        id: pwHeart
        property real last: 0
        interval: 16
        repeat: true
        onTriggered: {
            const now = Date.now();
            const gap = now - pwHeart.last - pwHeart.interval;
            pwHeart.last = now;
            const L = engine._pwLog;
            if (L.rec)
                L.rec.block = Math.max(L.rec.block, gap);
            if (L.pending) {
                L.pending.block = Math.max(L.pending.block, gap);
                if (L.pending.destroyMs === undefined)
                    L.pending.destroyMs = Math.max(0, now - L.pending.tDestroy - pwHeart.interval);
                engine._pwFlush();
            }
            if (!engine.prewarming && engine._pwQueue.length === 0 && !L.pending && L.active) {
                L.active = false;
                const st = engine.prewarmStats;
                console.log("LARES prewarm end drawn=" + st.drawn + " yielded=" + st.yielded + " failed=" + st.failed + " total=" + (now - L.t0));
                pwHeart.stop();
            }
        }
    }

    Timer {
        id: pwBeat
        interval: Math.max(1, engine.prewarmBeatMs)
        onTriggered: engine._pwStep()
    }
    // A window that does not present (hidden, occluded) never swaps a frame: the warm-up goes on without it rather than hold a
    // content for ever.
    Timer {
        id: pwWatchdog
        interval: 2000
        onTriggered: {
            if (engine._pwItem)
                engine._pwFrame();
            if (engine._pwItem)
                pwWatchdog.restart();
        }
    }
    Connections {
        target: engine._pwItem ? engine.Window.window : null
        function onFrameSwapped() {
            engine._pwFrame();
        }
    }

    // Content change: fade out, swap, fade in, one after the other.
    //
    // THE BUILD GOES IN FRONT OF THE FLIGHT. The swap lands in the middle of a journey, in an animation tick: a content built there is a 36-60 ms hole
    // in the box's motion. Built here, in the click's own turn, the same work is a first frame that comes a little later, before anything has started to move.
    function _buildAhead(S, component) {
        if (S.ahead) {
            S.ahead.item.destroy();
            S.ahead = null;
        }
        if (!component || component.status !== Component.Ready)
            return;
        engine._finishIncubation(component);
        if ((engine._parked && engine._parked.component === component) || engine._pinned.some(p => p.component === component))
            return;
        const item = S.buildAhead(component);
        if (item)
            S.ahead = { component: component, item: item };
    }
    function _swapContent(S, component, key) {
        if (component === S.component) {
            if (key !== undefined && key !== S.key)
                engine._swapKey(S, key);
            return;
        }
        const outMs = engine.migrateMs * engine.swapOutFrac;
        const inMs = engine.migrateMs * engine.swapInFrac;
        S.swapping = true;
        engine._buildAhead(S, component);
        S.fadeTo(0, outMs, function () {
            engine._installContent(S, S.ownerId, component);
            S.swapping = false;
            S.sizeHint = null;
            if (key !== undefined)
                S.key = key;
            engine._assignKey(S);
            if (S.askAlong === null || S.askOut === null)
                engine._contentResized(S);
            else if (!engine._placedAsContent(S))
                engine._contentShifted(S);
            S.fadeTo(1, inMs);
        });
    }

    function _swapKey(S, key) {
        const it = S.contentItem;
        if (it && typeof it.secondarySwapsInPlace === "function" && it.secondarySwapsInPlace(key)) {
            S.fadeTo(1, engine.migrateMs * engine.swapInFrac);
            S.key = key;
            engine._assignKey(S);
            return;
        }
        const outMs = engine.migrateMs * engine.swapOutFrac;
        const inMs = engine.migrateMs * engine.swapInFrac;
        S.fadeTo(0, outMs, function () {
            S.key = key;
            engine._assignKey(S);
            S.fadeTo(1, inMs);
        });
    }

    function _assignKey(S) {
        const it = S.contentItem;
        if (S.isChild && it && ("secondaryKey" in it) && S.key !== undefined)
            it.secondaryKey = S.key;
    }

    function _contentResized(S) {
        // The OSD follows its content on the resize clock (a dip's fold has its own).
        if (S.isOsd) {
            if (engine._osdRequest && !S.dipping && (S.askAlong === null || S.askOut === null))
                engine._osdEvent(engine.resizeMs, engine.resizeEasingIndex);
            return;
        }
        // The lane follows its content on the resize clock, also while it is
        // folded away waiting for room (its content is kept for its size).
        if (S.isLane) {
            if (engine._laneRequest && (S.askAlong === null || S.askOut === null))
                engine._laneEvent(engine.resizeMs, engine.resizeEasingIndex);
            return;
        }
        if (!S.live || (S.askAlong !== null && S.askOut !== null))
            return;
        if (S.isChild) {
            engine._childResized(S);
            return;
        }
        if (engine._liveOf(S)) {
            engine._requestFollow();
            return;
        }
        // ONE RESIZE PER TURN: a popup that nudges the toast stack and then shrinks (the system update) must not make the toast close and reappear. A content's width and height are
        // two bindings, and the first one's change signal arrives while the other still holds its old value (one binding that reads
        // two others can see them from different generations): the system update's views (1080 x 760, 700 x 560, 424 x 150) set the width first,
        // so a SHRINK would pass through a box narrower than tall (700 x 760, 424 x 560) -- which puts the stack beside the popup instead of under its
        // foot, a change of side, a fold and a reopen -- and a GROWTH through one wider than ever (1080 x 560), which keeps it under. The resize is
        // taken once both have landed, at the end of the turn (Qt.callLater), from the content's size as it then is.
        if (engine._resizedSlots.indexOf(S) < 0)
            engine._resizedSlots.push(S);
        Qt.callLater(engine._flushContentResized);
    }
    // The resizes a turn collected (_contentResized), each slot once, from its content's size now.
    property var _resizedSlots: []
    function _flushContentResized() {
        const list = engine._resizedSlots;
        engine._resizedSlots = [];
        for (const S of list)
            engine._contentResizedNow(S);
    }
    function _contentResizedNow(S) {
        if (!S.live || (S.askAlong !== null && S.askOut !== null))
            return;
        if (engine._liveOf(S)) {
            engine._requestFollow();
            return;
        }
        const info = track.getBarInfoById(S.barId);
        if (!info)
            return;
        const aimed = S.toBox;
        engine._placeTargets(S, info);
        // A trip that was aimed at this very box (the destination's remembered size, THE OWNER'S SIZE MEMORY) goes on as it
        // is: re-aiming would restart its clock for a target that has not moved.
        if (S.travelling && engine._nearBox(aimed, S.toBox, 0.5))
            return;
        engine._reaim(S);
        // The lane beside it moves on the same clock: the two faces as one -- and round the reel's strip (THE REEL SLOT) as round a popup.
        if (S === engine._primary || S === reelSlot)
            engine._laneEvent(engine.resizeMs, engine.resizeEasingIndex);
    }

    // =====================================================================
    //  The live contract (see the header)
    // =====================================================================

    // Could this slot follow its content? The primary only, at rest or on a
    // resize/shift ease; never opening, closing or travelling.
    function _followable(S) {
        return S === engine._primary && !S.isChild && !S.travelling && (S.phase === "open" || S.phase === "moving");
    }

    // ...and is it: its content is being dragged.
    function _liveOf(S) {
        if (!engine._followable(S))
            return false;
        const it = S.contentItem;
        return !!it && it.liveResizeActive === true;
    }

    // What the input mask is while it is: "box" when the content asks for it,
    // else "engine".
    function _liveMaskOf(S) {
        const it = S.contentItem;
        return !!it && it.liveResizeMask === "box" ? "box" : "engine";
    }

    // liveResizeMask changed: a live primary's mask is laid out again now.
    function _contentLiveMaskChanged(S) {
        if (S === engine._primary && engine._liveOf(S))
            engine.layout();
    }

    // The content's shift along the bar's screen axis; 0 for a content that
    // has none, for a child, and for the content that is on its way out.
    function _contentShift(S) {
        const it = S.contentItem;
        if (S.isChild || S.isLane || S.isOsd || S.swapping || !it || !("alongShift" in it))
            return 0;
        // The content's units: times its ratio (THE RATIOS).
        return engine._shiftValue(it.alongShift) * (S.ratio > 0 ? S.ratio : 1);
    }

    // A shift as the placement takes it: a number, 0 when it is none. The
    // content's (_contentShift) and one hostRoom.restAt is asked about.
    function _shiftValue(v) {
        const n = Number(v);
        return isFinite(n) ? n : 0;
    }

    // Does the content continue its bar cell (continuesBarCell: placed on its
    // anchor, no wall, no bar's end)? Not for a child or the lane, and not
    // for the content on its way out of a swap -- the one coming in says.
    // THE REEL SLOT's strip always does, in a swap too: what leaves is a strip and what arrives is one (the reels', the tray's). Judged
    // unpinned for the frames of the swap's fade, a strip sent to another reel's cell was aimed at a popup's place on the wall -- its
    // left border going the wrong way for four frames -- and aimed again, on a clock started over, when the new strip landed.
    function _pinnedOf(S) {
        const it = S.contentItem;
        if (S.isReel && S.swapping)
            return true;
        return !S.isChild && !S.isLane && !S.isOsd && !S.swapping && !!it && it.continuesBarCell === true;
    }

    // Were the targets placed as the content asks now (its shift, its pin)?
    // After a swap the new content may ask otherwise than the one leaving did.
    function _placedAsContent(S) {
        return engine._contentShift(S) === S.placedShift && engine._pinnedOf(S) === S.placedPinned;
    }

    function _contentShifted(S) {
        if (!S.live || S.isChild || S.swapping || engine._placedAsContent(S))
            return;
        if (engine._liveOf(S)) {
            engine._requestFollow();
            return;
        }
        const info = track.getBarInfoById(S.barId);
        if (!info)
            return;
        engine._placeTargets(S, info);
        engine._reaim(S);
        if (S === engine._primary)
            engine._laneEvent(engine.resizeMs, engine.resizeEasingIndex);
    }

    // liveResizeActive went up or down. Up: the box becomes its target now (a
    // resize still easing ends in this frame) and the mask the whole engine
    // (or the box, liveResizeMask).
    // Down: a follow still waiting for its frame is laid out first -- a release
    // handler that writes the last size and then ends the drag must not lose
    // it -- and the mask goes back to the box.
    function _contentLiveChanged(S) {
        if (S !== engine._primary)
            return;
        const pending = engine._followPending;
        engine._followPending = false;
        if (engine._followable(S) && (pending || engine._liveOf(S)))
            engine._followLive(S);
        else
            engine.layout();
        // A drag is not re-placed per frame (the lane is a wall to it, laneClip);
        // where it ended is placed (THE WALL, THE BAR'S END), and a new target the lane makes
        // room for.
        if (!engine._liveOf(S)) {
            engine._livePlaced(S);
            engine._laneEvent(engine.resizeMs, engine.resizeEasingIndex);
        }
    }

    // A live resize has ended: where it left the box is placed now, by the
    // rule. A box left within snapDistance of a perpendicular bar eases flush
    // against it on the resize clock -- a shift, never a resize; one left
    // anywhere else is already where the placement puts it, and nothing moves.
    function _livePlaced(S) {
        if (!engine._followable(S) || !S.toBox)
            return;
        const info = track.getBarInfoById(S.barId);
        if (!info)
            return;
        const was = S.toBox;
        engine._placeTargets(S, info);
        const b = S.toBox;
        if (Math.abs(b.x0 - was.x0) > 1e-6 || Math.abs(b.y0 - was.y0) > 1e-6
                || Math.abs(b.x1 - was.x1) > 1e-6 || Math.abs(b.y1 - was.y1) > 1e-6)
            engine._retarget(S, engine.resizeEasingIndex, engine.resizeMs);
    }

    // Every change before a frame is ONE layout, in that frame's polish
    // (followHook), which runs before the frame is synchronised: the drag's
    // frame draws the box it asked for, however many pointer events it
    // collected. (Qt.callLater instead runs after EACH event: measured 1.56
    // layouts a frame at three events a frame; a 1000 Hz mouse on a 120 Hz
    // panel would be up to eight.)
    function _requestFollow() {
        if (engine._followPending)
            return;
        engine._followPending = true;
        engine._poke();
    }

    // The flourish's changes ride the same hook on a flag of their own: a live
    // follow consumed early (_contentLiveChanged) must not take one with it.
    function _requestFrameLayout() {
        engine._flourishDirty = true;
        engine._poke();
    }

    // One poke a frame, whoever asked.
    function _poke() {
        if (engine._pokePending)
            return;
        engine._pokePending = true;
        followPoke.width = followPoke.width > 0 ? 0 : 1;
    }

    function _flushFollow() {
        engine._pokePending = false;
        // The bars first: a live follow places against them.
        if (engine._barsDirty)
            engine._relayoutTargets();
        if (engine._followPending) {
            engine._followPending = false;
            const S = engine._primary;
            if (engine._liveOf(S))
                engine._followLive(S);
        }
        // Laid out since it changed (the follow, a clock's tick): nothing to do.
        if (engine._flourishDirty)
            engine.layout();
    }

    // The box is its target, on this frame: re-placed, the clock at its end
    // (the content's fade untouched), phase "open".
    function _followLive(S) {
        const info = track.getBarInfoById(S.barId);
        if (!info)
            return;
        engine._placeTargets(S, info, true);
        S.move = null;
        S.travelling = false;
        S.fromBox = S.toBox;
        S.phase = "open";
        S.framing = false;
        const was = S.t;
        S.snap();
        if (was === 1)
            engine.layout();
    }

    // A slot content's surfaceTint, or null.
    function _tintOf(S) {
        const it = S.contentItem;
        if (!it || !("surfaceTint" in it))
            return null;
        const c = it.surfaceTint;
        return c && c.valid && c.a > 0 ? c : null;
    }

    // The tints of the bodies the last layout drew. Only a real change reaches
    // the field: a colour easing costs its uniforms, never the shape.
    function _pushTints() {
        const list = [];
        for (const e of engine._tintSlots) {
            const c = engine._tintOf(e.slot);
            if (c)
                list.push({ body: e.index, color: c });
        }
        const old = field.tints || [];
        let same = old.length === list.length;
        for (let i = 0; same && i < list.length; i++)
            same = old[i].body === list[i].body && Qt.colorEqual(old[i].color, list[i].color);
        if (!same)
            field.tints = list;
    }

    // A track position on an edge as the screen coordinate along that edge.
    function _screenAlong(edge, p) {
        const W = track.w, H = track.h;
        if (edge === "top")
            return p;
        if (edge === "right")
            return p - W;
        if (edge === "bottom")
            return W - (p - (W + H));
        return H - (p - (2 * W + H));
    }

    // hostRoom, in engine coordinates along the edge's SCREEN axis (x for a
    // top/bottom bar, y for a left/right one):
    //   center  where localCenter anchors the popup, WITHOUT alongShift; a box
    //           held at another point than its centre (the lane's alongAt) is
    //           anchored as long as the box IS, not as its content asks
    //   lo, hi  the stretch the placement clamps the box to (the edge, less a
    //           perpendicular bar at either end)
    //   out     the most the popup may reach out of its bar: the screen's extent
    //           on the other axis, less the host bar's thickness and the
    //           thickest bar on the opposite edge (none: 0), less 12
    //   a0, a1  the box as it actually is (the clamp, THE WALL or THE BAR'S
    //           END may have moved it off center + shift)
    //   face    the bar face it hangs from, on the OTHER axis
    //   wallLo, wallHi  a perpendicular bar stands at `lo` / `hi` (THE WALL);
    //           otherwise lo..hi ends at the screen's edge, where nothing snaps
    //   snap    how near a wall a box is put against it (snapDistance)
    //   restAt(along, shift) -> { a0, a1 } | null: where the engine WOULD rest
    //           a box of that size and shift now -- the placement itself
    //           (_restAt), not a copy of its rules
    // A content resizing itself keeps its box inside lo..hi, so the clamp never
    // engages under a drag, and takes the edge it holds still from a0/a1.
    // The track runs against the screen axis on the bottom and left edges, so
    // there `lo` is the track's max end and the walls swap.
    // NOTHING IN A ROOM IS A FUNCTION OF THE CONTENT'S ASKED SIZE. The engine
    // hears a size change inside the content's own notification of it and lays
    // out at once, so a room that moved with the asked size would be written back
    // INTO that notification: the toast stack's padding (which reads the
    // room's edge) would re-enter itself whenever it changed the stack's width --
    // "Binding loop detected for property _minPadding". The box has not moved
    // yet then (its clock starts on the next frame), so a room of the box as
    // it is holds still until the clock moves it.
    function _roomOf(S) {
        const info = track.getBarInfoById(S.barId);
        const b = S.box || S.toBox;
        if (!info || !b)
            return null;
        const e = info.edge;
        const vertical = e === "left" || e === "right";
        const lim = engine._limits(info);
        const l0 = engine._screenAlong(e, lim.min), l1 = engine._screenAlong(e, lim.max);
        const t = info.thickness;
        const opposite = { top: "bottom", bottom: "top", left: "right", right: "left" }[e];
        // In the CONTENT's units (THE RATIOS): every length and position, over the content's ratio; `restAt` takes and gives them.
        const k = S.ratio > 0 ? S.ratio : 1;
        return {
            edge: e,
            center: engine._screenAlong(e, engine._anchoredCenter(info, S, 0, vertical ? b.y1 - b.y0 : b.x1 - b.x0)) / k,
            lo: Math.min(l0, l1) / k,
            hi: Math.max(l0, l1) / k,
            out: ((vertical ? track.w : track.h) - t - track.edgeThickness(opposite) - 12) / k,
            a0: (vertical ? b.y0 : b.x0) / k,
            a1: (vertical ? b.y1 : b.x1) / k,
            face: (e === "top" || e === "left" ? t : (vertical ? track.w : track.h) - t) / k,
            wallLo: l0 <= l1 ? lim.loBar : lim.hiBar,
            wallHi: l0 <= l1 ? lim.hiBar : lim.loBar,
            snap: engine._snapDistance / k,
            restAt: (along, shift) => engine._restAtOf(S, along, shift)
        };
    }

    // Hand the primary's content its room if it declares one and anything in
    // it changed: when its targets were placed, and whenever it is at rest
    // (settled, or following a live resize). `restAt` is not a value: every
    // room's asks the slot as it is when called, so a room kept because
    // nothing else changed answers exactly as a new one would.
    function _assignRoom(S) {
        const it = S.contentItem;
        if (!it || !("hostRoom" in it) || !(S.phase === "open" || S.roomDirty))
            return;
        S.roomDirty = false;
        const r = engine._roomOf(S);
        if (!r)
            return;
        const o = S.room;
        if (o && engine._roomHeld(it, o) && o.edge === r.edge && o.center === r.center && o.lo === r.lo
                && o.hi === r.hi && o.out === r.out && o.a0 === r.a0 && o.a1 === r.a1 && o.face === r.face
                && o.wallLo === r.wallLo && o.wallHi === r.wallHi && o.snap === r.snap)
            return;
        S.room = r;
        engine._applyRoom(it, r);
    }

    // The content's members are not a type the engine knows; untyped
    // parameters read and write them without a member check.
    function _roomHeld(it, o) {
        return it.hostRoom === o;
    }
    function _applyRoom(it, r) {
        it.hostRoom = r;
    }

    // The live slots whose content asks for the whole track as input: the lane,
    // the primary, any child (`maskCatchAll`).
    property var _catching: []
    function _catchers() {
        return [engine._primary].concat(engine.childPopups, [laneSlot]).filter(S => engine._catchAllOf(S) || engine._clickAwayOf(S));
    }
    // THE POPUPS A PRESS IN THE VOID CLOSES (owner ids, shell.jsonc clickAway): the primary of one of them catches as a content's own
    // `maskCatchAll` does, until its close begins.
    property var clickAwayIds: []
    onClickAwayIdsChanged: engine.layout()
    function _clickAwayOf(S) {
        return !!S && S === engine._primary && S.live && engine.clickAwayIds.indexOf(S.ownerId) >= 0;
    }
    // A press that landed on no body and no bar, while a content catches: each
    // catching content that declares `outsidePress()` is told. One inside any
    // live body or bar is not the void (the content's own padding, the strip
    // between two icons) and is let go.
    function _voidPress(x, y) {
        const inside = b => !!b && x >= b.x0 && x < b.x1 && y >= b.y0 && y < b.y1;
        for (const S of [slotA, slotB, laneSlot, osdSlot, reelSlot].concat(engine.childPopups, engine.reelChildPopups))
            if (S.phase !== "closed" && inside(S.box))
                return false;
        for (const bar of engine.barsList)
            if (bar && bar.visible && bar.inputMask !== false
                    && inside({ x0: bar.absX, y0: bar.absY, x1: bar.absX + bar.absW, y1: bar.absY + bar.absH }))
                return false;
        let told = false;
        for (const S of engine._catching) {
            const it = S.contentItem;
            if (it && typeof it.outsidePress === "function") {
                it.outsidePress();
                told = true;
            }
        }
        if (engine._clickAwayOf(engine._primary)) {
            engine.close();
            told = true;
        }
        return told;
    }

    // Whether the slot's live content asks for the whole track as input.
    function _catchAllOf(S) {
        const it = S && S.live ? S.contentItem : null;
        return !!it && ("maskCatchAll" in it) && it.maskCatchAll === true;
    }

    function _keyboardOf(S) {
        if (!S || !S.live)
            return "none";
        const it = S.contentItem;
        if (!it || !("keyboardFocusRequest" in it))
            return "none";
        const v = String(it.keyboardFocusRequest);
        return v === "onDemand" || v === "exclusive" ? v : "none";
    }

    function _syncSecondary(S, due) {
        // The primary's content, the reel strip's (THE REEL'S CHAIN), or a live child's (THE CHILD CHAIN).
        if (!S.live || (!S.isChild && S !== engine._primary && S !== reelSlot))
            return;
        const it = S.contentItem;
        if (!it || !("secondaryOpen" in it))
            return;
        const childId = S.ownerId + "/secondary";
        // A persistent secondary asked for while its popup is still growing is
        // held back (the reopen); `due` is its release from layout().
        if (!due && S === engine._primary && it.secondaryOpen && it.secondaryComponent && it.secondaryPersistent === true
                && engine._reopenWaits(S)) {
            engine._pendingChild = S;
            return;
        }
        if (engine._pendingChild === S)
            engine._pendingChild = null;
        if (it.secondaryOpen && it.secondaryComponent) {
            engine.openChild(S.ownerId, childId, it.secondarySide || "far", it.secondaryAnchor,
                null, null, it.secondaryComponent,
                // A child's `secondaryKey` is the engine's (what it shows): it
                // names its own child's key `secondaryChildKey`.
                { overhang: !!it.secondaryOverhang, key: S.isChild ? it.secondaryChildKey : it.secondaryKey,
                  inset: ("secondaryInset" in it) ? Number(it.secondaryInset) || 0 : 0,
                  anchorAt: ("secondaryAnchorAt" in it) ? it.secondaryAnchorAt : 0.5,
                  openAt: ("secondaryOpenAt" in it) ? it.secondaryOpenAt : undefined,
                  openMin: ("secondaryOpenMin" in it) ? Number(it.secondaryOpenMin) || 0 : 0,
                  widthFrom: ("secondaryWidthFrom" in it) ? Number(it.secondaryWidthFrom) : undefined });
        } else {
            engine.closeChild(childId);
        }
    }

    function _resolveSide(parentEdge, side) {
        const horizontalBar = parentEdge === "top" || parentEdge === "bottom";
        if (side === "far")
            return { top: "bottom", bottom: "top", left: "right", right: "left" }[parentEdge] || "bottom";
        if (side === "start")
            return horizontalBar ? "left" : "top";
        if (side === "end")
            return horizontalBar ? "right" : "bottom";
        return side;
    }

    function _trackPosOf(edge, b) {
        const W = track.w, H = track.h;
        if (edge === "top") return b.x0;
        if (edge === "right") return b.y0 + W;
        if (edge === "bottom") return (W + H) + (W - b.x1);
        return (2 * W + H) + (H - b.y1);
    }

    // The screen corner nearest a point on the track, stepped in to the
    // inner corner where a perpendicular bar sits (the 2D open/close): by that
    // bar's own thickness.
    function _closestCorner(targetCenter, info) {
        const L = track.length, W = track.w, H = track.h;
        const nCenter = ((targetCenter % L) + L) % L;
        const corners = [0, W, W + H, (W * 2) + H, L];
        let C = corners[0];
        let minDiff = Math.abs(nCenter - corners[0]);
        for (let i = 1; i < corners.length; i++) {
            const diff = Math.abs(nCenter - corners[i]);
            if (diff < minDiff) {
                minDiff = diff;
                C = corners[i];
            }
        }
        const e = info.edge;
        const ins = engine._endInsets(e);
        if (e === "top") {
            if (C === 0 || C === L) C = ins.loBar ? ins.lo : 0;
            else if (C === W) C = ins.hiBar ? W - ins.hi : W - 0.001;
        } else if (e === "right") {
            if (C === W) C = ins.loBar ? W + ins.lo : W;
            else if (C === W + H) C = ins.hiBar ? W + H - ins.hi : W + H - 0.001;
        } else if (e === "bottom") {
            if (C === W + H) C = ins.loBar ? W + H + ins.lo : W + H;
            else if (C === (W * 2) + H) C = ins.hiBar ? (W * 2) + H - ins.hi : (W * 2) + H - 0.001;
        } else if (e === "left") {
            if (C === (W * 2) + H) C = ins.loBar ? (W * 2) + H + ins.lo : (W * 2) + H;
            else if (C === 0 || C === L) C = ins.hiBar ? L - ins.hi : L - 0.001;
        }
        return C;
    }

    // ---- Migration around the corners -------------------------------------
    // Where a bw x bh box sits in a screen corner: against both of its walls.
    function _cornerPos(cn, bw, bh) {
        const wl = engine._cornerWall(cn);
        if (cn === "TL") return { x: wl.x, y: wl.y };
        if (cn === "TR") return { x: track.w - wl.x - bw, y: wl.y };
        if (cn === "BR") return { x: track.w - wl.x - bw, y: track.h - wl.y - bh };
        if (cn === "BL") return { x: wl.x, y: track.h - wl.y - bh };
        return { x: 0, y: 0 };
    }

    // The walls of a screen corner, per axis: `x` its side edge's (left for TL
    // and BL, right for TR and BR), `y` its top or bottom edge's.
    function _cornerWall(cn) {
        const top = cn === "TL" || cn === "TR", left = cn === "TL" || cn === "BL";
        return { x: engine._edgeWall(left ? "left" : "right", cn), y: engine._edgeWall(top ? "top" : "bottom", cn) };
    }

    // How far from the screen edge a popup travelling along `edge` rides at the
    // corner `cn`: the thickness of that edge's bar nearest the corner (the
    // thicker of two equally near), 0 on a bare edge.
    function _edgeWall(edge, cn) {
        const W = track.w, H = track.h;
        const c = edge === "top" ? (cn === "TL" ? 0 : W)
                : edge === "right" ? (cn === "TR" ? W : W + H)
                : edge === "bottom" ? (cn === "BR" ? W + H : (W * 2) + H)
                : (cn === "BL" ? (W * 2) + H : track.length);
        let t = 0, best = Infinity;
        for (let i = 0; i < track.bars.length; i++) {
            const bar = track.bars[i];
            if (!bar || bar.edge !== edge)
                continue;
            const info = track.getBarInfoById(bar.barId);
            if (!info)
                continue;
            const d = Math.max(0, info.start - c, c - info.end);
            if (d < best - 1e-6 || (d <= best + 1e-6 && bar.thickness > t)) {
                best = Math.min(best, d);
                t = bar.thickness;
            }
        }
        return t;
    }

    // How far a box's face on `edge` is from that screen edge.
    function _faceOf(edge, b) {
        if (edge === "top")
            return b.y0;
        if (edge === "bottom")
            return track.h - b.y1;
        if (edge === "left")
            return b.x0;
        return track.w - b.x1;
    }

    // The screen corners between two edges, the short way round.
    function _cornersBetween(srcEdge, dstEdge, from, to) {
        const edges = ["top", "right", "bottom", "left"];
        const names = ["TR", "BR", "BL", "TL"];
        const si = edges.indexOf(srcEdge), di = edges.indexOf(dstEdge);
        if (si < 0 || di < 0 || si === di)
            return [];
        const fwd = [];
        for (let i = si; i !== di; i = (i + 1) % 4)
            fwd.push(names[i]);
        const bwd = [];
        for (let i = si; i !== di; i = (i + 3) % 4)
            bwd.push(names[(i + 3) % 4]);
        // Prefer the way round that has bars on it, even when that
        // is the longer one; the shorter one
        // when both or neither do.
        const fwdOk = engine._routeHasBars(si, di, 1);
        const bwdOk = engine._routeHasBars(si, di, 3);
        if (fwdOk && !bwdOk)
            return fwd;
        if (bwdOk && !fwdOk)
            return bwd;
        // The SHORTER way round, by the length of the path the box really flies (its centre through the corners to the other box's centre), not by
        // the number of corners: opposite edges (top <-> bottom, left <-> right) have two ways of the same count, and always taking the clockwise one
        // would send silicon at the top right to the clipboard at the bottom by the right edge (the shorter), and the way back from the bottom by
        // the left (the longer). Two ways of one length (the boxes
        // centred) take the same side both ways: the right edge between top and bottom, the top edge between left and right.
        if (from && to) {
            const lf = engine._routeLength(fwd, from, to), lb = engine._routeLength(bwd, from, to);
            if (Math.abs(lf - lb) > 0.5)
                return lf < lb ? fwd : bwd;
            const opposite = Math.abs(si - di) === 2;
            const want = si % 2 === 0 ? "BR" : "TL";
            if (opposite && fwd.indexOf(want) !== bwd.indexOf(want))
                return fwd.indexOf(want) >= 0 ? fwd : bwd;
        }
        return fwd.length <= bwd.length ? fwd : bwd;
    }

    // The length of the polyline from one box's centre through the screen corners `names` to the other's.
    function _routeLength(names, from, to) {
        const at = { TL: { x: 0, y: 0 }, TR: { x: track.w, y: 0 }, BR: { x: track.w, y: track.h }, BL: { x: 0, y: track.h } };
        let px = (from.x0 + from.x1) / 2, py = (from.y0 + from.y1) / 2, len = 0;
        for (const n of names) {
            len += Math.hypot(at[n].x - px, at[n].y - py);
            px = at[n].x;
            py = at[n].y;
        }
        return len + Math.hypot((to.x0 + to.x1) / 2 - px, (to.y0 + to.y1) / 2 - py);
    }

    function _routeHasBars(si, di, step) {
        const edges = ["top", "right", "bottom", "left"];
        for (let i = (si + step) % 4; i !== di; i = (i + step) % 4)
            if (!track.hasBarOnEdge(edges[i]))
                return false;
        return true;
    }

    function _sharedEdge(c1, c2) {
        const k = [c1, c2].sort().join("");
        return { TLTR: "top", BRTR: "right", BLBR: "bottom", BLTL: "left" }[k] || "";
    }

    // The box at eased progress `e` of a corner migration: a polyline from the
    // start through each corner to the end, walked by arc length, with the
    // axis facing the current wall pinned to it. The wall is the leg's own and
    // eased between its two ends -- the start box's face and the first corner's
    // wall on the first leg, one corner's and the next's in between, the last
    // corner's and the end box's on the last -- so a migration from a 40 px top
    // bar round a side bar to a 6 px bottom bar rides every wall it passes, and
    // one past two bars of different thickness on an edge moves between them.
    function _polyAt(mv, e) {
        let w = mv.sw + (mv.ew - mv.sw) * e;
        let h = mv.sh + (mv.eh - mv.sh) * e;
        if (mv.corners.length > 0) {
            // ONE AXIS AT A TIME. Around a corner the popup travels along one
            // axis and then the other; a size changing across the axis it is
            // travelling on moves a free edge sideways and reads as diagonal
            // travel. So the width changes only while it travels horizontally
            // and the height only while it travels vertically, each by the
            // share of that axis's path covered so far (measured on the path
            // at the starting size). A size with no path along its axis follows
            // the overall progress.
            const t = Math.max(0, Math.min(1, e));
            const p0 = [{ x: mv.sx, y: mv.sy }];
            for (let i = 0; i < mv.corners.length; i++)
                p0.push(engine._cornerPos(mv.corners[i], mv.sw, mv.sh));
            p0.push({ x: mv.ex, y: mv.ey });
            let total = 0, hLen = 0, vLen = 0;
            const segs = [];
            for (let i = 1; i < p0.length; i++) {
                const dx = Math.abs(p0[i].x - p0[i - 1].x), dy = Math.abs(p0[i].y - p0[i - 1].y);
                const len = Math.hypot(dx, dy);
                segs.push({ dx: dx, dy: dy, len: len });
                total += len;
                hLen += dx;
                vLen += dy;
            }
            let left = t * total, hc = 0, vc = 0;
            for (const sg of segs) {
                const f = sg.len > 0 ? Math.max(0, Math.min(1, left / sg.len)) : 1;
                hc += sg.dx * f;
                vc += sg.dy * f;
                left -= sg.len;
                if (left <= 0)
                    break;
            }
            const fw = hLen > 0.5 ? hc / hLen : t;
            const fh = vLen > 0.5 ? vc / vLen : t;
            w = mv.sw + (mv.ew - mv.sw) * fw;
            h = mv.sh + (mv.eh - mv.sh) * fh;
        }
        if (mv.corners.length === 0) {
            const x = mv.sx + (mv.ex - mv.sx) * e;
            const y = mv.sy + (mv.ey - mv.sy) * e;
            return { box: { x0: x, y0: y, x1: x + w, y1: y + h }, edge: mv.dstEdge };
        }
        const pts = [{ x: mv.sx, y: mv.sy }];
        for (let i = 0; i < mv.corners.length; i++)
            pts.push(engine._cornerPos(mv.corners[i], w, h));
        pts.push({ x: mv.ex, y: mv.ey });
        const cd = [0];
        for (let i = 1; i < pts.length; i++)
            cd.push(cd[i - 1] + Math.hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y));
        const total = cd[cd.length - 1];
        if (total < 1)
            return { box: { x0: mv.ex, y0: mv.ey, x1: mv.ex + w, y1: mv.ey + h }, edge: mv.dstEdge };
        const target = Math.max(0, Math.min(1, e)) * total;
        let seg = 0, segT = 1, rx = mv.ex, ry = mv.ey;
        for (let i = 1; i < pts.length; i++) {
            if (target <= cd[i] || i === pts.length - 1) {
                seg = i - 1;
                const len = cd[i] - cd[i - 1];
                segT = len > 0.1 ? (target - cd[i - 1]) / len : 1;
                rx = pts[i - 1].x + (pts[i].x - pts[i - 1].x) * segT;
                ry = pts[i - 1].y + (pts[i].y - pts[i - 1].y) * segT;
                break;
            }
        }
        const n = mv.corners.length;
        const edge = seg === 0 ? mv.srcEdge
                   : seg >= n ? mv.dstEdge
                   : engine._sharedEdge(mv.corners[seg - 1], mv.corners[seg]);
        const f0 = seg === 0 ? mv.sf : engine._edgeWall(edge, mv.corners[seg - 1]);
        const f1 = seg >= n ? mv.ef : engine._edgeWall(edge, mv.corners[seg]);
        const face = f0 + (f1 - f0) * segT;
        if (edge === "top") ry = face;
        else if (edge === "bottom") ry = track.h - face - h;
        else if (edge === "left") rx = face;
        else if (edge === "right") rx = track.w - face - w;
        return { box: { x0: rx, y0: ry, x1: rx + w, y1: ry + h }, edge: edge };
    }

    function _polyEdgeNow(S) {
        return engine._polyAt(S.move, Geo.ease(S.easingIndex, S.t, S.overshoot)).edge;
    }

    // Content declaring `secondaryCutout` / `secondaryMoving` is not a type the
    // engine knows; an untyped parameter reads and writes it without a member
    // check.
    function _applyMoving(it, v) {
        if (it.secondaryMoving !== v)
            it.secondaryMoving = v;
    }
    function _applyCutout(it, r) {
        const cur = it.secondaryCutout;
        if (!cur || cur.x !== r.x || cur.y !== r.y || cur.width !== r.width || cur.height !== r.height)
            it.secondaryCutout = r;
    }

    // ---- The child's box ----------------------------------------------------
    // Where the child wants to sit on its parent's side: how far its near end is
    // from the parent's ( rel0 ), how long it is ( along ), how far out ( out )
    // and how far its attach face goes into the parent ( ins ). The clamps live
    // here, so the slide clock can ease between two of these.
    function _childTarget(C, pb, sideways) {
        const it = C.contentItem;
        // The child's content's units, times its ratio (THE RATIOS).
        const r = C.ratio > 0 ? C.ratio : 1;
        const iw = it ? it.implicitWidth : 0;
        const ih = it ? it.implicitHeight : 0;
        const fullW = (C.askAlong !== null && C.askAlong !== undefined ? C.askAlong : iw) * r;
        const fullH = (C.askOut !== null && C.askOut !== undefined ? C.askOut : ih) * r;
        const along = sideways ? fullH : fullW;
        const out = sideways ? fullW : fullH;
        const p0 = sideways ? pb.y0 : pb.x0;
        const p1 = sideways ? pb.y1 : pb.x1;
        // The screen between the bars on the two edges across its axis, each by
        // its own thickness (a bare edge: the screen's edge).
        const lo0 = track.edgeThickness(sideways ? "top" : "left");
        const hi0 = (sideways ? track.h : track.w) - track.edgeThickness(sideways ? "bottom" : "right");
        // A child wider than where it may go hangs past BOTH of its parent's
        // sides, centred on it; a child that fits is clamped to the parent
        // (or, with overhang, to the screen between the edge bars).
        const lo = C.overhang ? lo0 : p0;
        const hi = C.overhang ? hi0 : p1;
        let s0;
        if (hi - lo <= along)
            s0 = Math.max(lo0, Math.min(hi0 - along, (lo + hi) / 2 - along / 2));
        else
            s0 = Math.max(lo, Math.min(hi - along, p0 + C.anchorOffset - along * C.anchorAt));
        if (Math.abs(s0 - p0) < engine._flushSnap)
            s0 = p0;
        if (Math.abs(s0 + along - p1) < engine._flushSnap)
            s0 = p1 - along;
        return { rel0: s0 - p0, along: along, out: out, ins: Math.max(0, C.inset) };
    }

    // The child's content asked for a different size. Ease to it like any other
    // change of where it sits; if a slide is already running, keep its clock and
    // solve the span it must have come from, so a size that animates every frame
    // is followed instead of restarting the ease on every one of them.
    function _childResized(C) {
        engine._childResizedBody(C);
        engine._laneEvent(engine.laneGlideMs, engine.laneGlideEasingIndex);
    }

    function _childResizedBody(C) {
        if (!C.live) {
            engine.layout();
            return;
        }
        if (engine._childUndrawn(C)) {
            engine._openUndrawnAt(C);
            engine.layout();
            return;
        }
        const se = Geo.ease(engine.migrateEasingIndex, C.slideT, 0);
        const last = C.spanLast;
        if (!last || C.slideT >= 1 || se >= 1 - 1e-6) {
            engine._beginChildSlide(C);
            engine.layout();
            return;
        }
        const P = C.parentSlot;
        const pb = P ? engine._heldBoxOf(P) : null;
        if (!pb) {
            engine.layout();
            return;
        }
        const t = engine._childTarget(C, pb, C.edge === "left" || C.edge === "right");
        const back = (now, to) => (now - se * to) / (1 - se);
        C.spanFrom = { rel0: back(last.rel0, t.rel0), along: back(last.along, t.along),
                       out: back(last.out, t.out), ins: back(last.ins, t.ins) };
        engine.layout();
    }

    // A child at t = 0 of its open has drawn nothing: a re-ask or a new size while its content is still being built (a
    // content that learns its height in its build re-asks through its owner's contract) is where it OPENS, not a slide
    // from a span never drawn -- the empty span laid out before the content existed. Sliding from it, the open grew on two
    // clocks and took its overshoot from that empty span (s0, no bias: the wiki's child swelled 21 px for 14).
    function _childUndrawn(C) {
        return C.t === 0 && C.phase !== "closing";
    }
    function _openUndrawnAt(C) {
        C.spanFrom = null;
        C.spanLast = null;
        C.slideT = 1;
        C.overshoot = engine._childOvershootFor(C);
    }

    // Start a slide from where the child is drawn now: every change to where it
    // sits (a new anchor, a new width, a new inset) eases from there.
    function _beginChildSlide(C) {
        const last = C.spanLast;
        C.spanFrom = last ? { rel0: last.rel0, along: last.along, out: last.out, ins: last.ins } : null;
        C.runSlide(engine.childSlideMs);
    }

    // A child is placed against its parent's CONTENT (_heldBoxOf): the parent's box, but while the parent's open overshoots
    // its rest box, that rest box (THE REST FRAME) -- a secondary out of an overshooting popup stays where it will rest, and the
    // parent's surface overshoots over its attach face as an inset's does.
    // `pure`: only computed -- nothing of the slot written (its span, full size and rest box), for a question asked before the
    // child runs (THE OVERSHOOT'S BIAS: a span written at its open, with no content yet, made the content's arrival a slide from it).
    function _childBox(C, eOverride, pure) {
        const P = C.parentSlot;
        const pb = P ? engine._heldBoxOf(P) : null;
        if (!pb)
            return null;
        const sideways = C.edge === "left" || C.edge === "right";
        const p0 = sideways ? pb.y0 : pb.x0;
        const tgt = engine._childTarget(C, pb, sideways);
        const se = Geo.ease(engine.migrateEasingIndex, C.slideT, 0);
        const f = C.spanFrom || tgt;
        const sp = {
            rel0: f.rel0 + (tgt.rel0 - f.rel0) * se,
            along: f.along + (tgt.along - f.along) * se,
            out: f.out + (tgt.out - f.out) * se,
            ins: f.ins + (tgt.ins - f.ins) * se
        };
        const along = sp.along, out = sp.out;
        if (!pure) {
            C.spanLast = sp;
            C.fullW = sideways ? out : along;
            C.fullH = sideways ? along : out;
        }

        const e = eOverride !== undefined ? eOverride : engine._childExtent(C);
        const outNow = Math.max(0, out * e);
        const p1 = sideways ? pb.y1 : pb.x1;
        const s0 = p0 + sp.rel0;
        // It opens out of the parent: the span it starts at (widthFrom of its
        // length, and never less than openMin of it, about its OPEN point --
        // openAt of its length: its anchor point unless asked, the centre by
        // default, its start for a box that grows out of a corner) is clamped
        // to the parent's side, so a part that will hang past the parent grows
        // out from the parent instead of appearing beside it.
        const c = s0 + along * C.openAt;
        const len = Math.max(along * C.widthFrom, Math.min(C.openMin, along));
        let o0 = Math.max(c - len * C.openAt, p0);
        let o1 = Math.min(c + len * (1 - C.openAt), p1);
        if (o1 < o0) {
            const m = Math.min(Math.max(c, p0), p1);
            o0 = m;
            o1 = m;
        }
        const a0 = o0 + (s0 - o0) * e, a1 = o1 + (s0 + along - o1) * e;
        // INSET: its attach face moves that far into the parent as it opens.
        // The overlap belongs to the parent (drawn above it); the child's
        // content is told where it is through `secondaryCutout`.
        const ins = sp.ins * e;
        // THE REST FRAME: the box this span rests at (the open at e = 1), for the frame of the box drawn.
        if (eOverride === undefined)
            C.restBox = engine._childFace(C.edge, pb, s0, s0 + along, out, sp.ins);
        return engine._childFace(C.edge, pb, a0, a1, outNow, ins);
    }

    // A child's box from its span along its parent's face (a0..a1), how far it is out and how far it reaches in.
    function _childFace(edge, pb, a0, a1, out, ins) {
        if (edge === "bottom")
            return { x0: a0, y0: pb.y1 - ins, x1: a1, y1: pb.y1 - ins + out };
        if (edge === "top")
            return { x0: a0, y0: pb.y0 + ins - out, x1: a1, y1: pb.y0 + ins };
        if (edge === "right")
            return { x0: pb.x1 - ins, y0: a0, x1: pb.x1 - ins + out, y1: a1 };
        return { x0: pb.x0 + ins - out, y0: a0, x1: pb.x0 + ins, y1: a1 };
    }

    // THE REST FRAME (header): the content's frame in the body's own px -- the rest box cut to the box drawn -- while an open's
    // box (or a close's that began as one: `framing`) reaches past it; for a content that asks for it (`revealOnOpen`) the whole
    // rest box, where it rests, for the whole of an open and a close. Null while the frame is the body itself. Never a travel's.
    function _restFrameOf(S, b) {
        if (!b || !S.restBox || S.move || S.travelling)
            return null;
        const reveal = (S.phase === "opening" || S.phase === "closing") && engine._revealsOf(S);
        if (!S.framing && !reveal)
            return null;
        // A floating popup rests where its own float puts its rest box (a child follows its parent's content, floated already).
        const r = S.restBox;
        const ff = S.isChild ? 0 : S.floatF;
        const rb = ff > 0 ? engine._floatMoved(r, engine._floatDelta(r, S.edge, ff)) : r;
        const x0 = reveal ? rb.x0 : Math.max(b.x0, rb.x0), y0 = reveal ? rb.y0 : Math.max(b.y0, rb.y0);
        const x1 = reveal ? rb.x1 : Math.min(b.x1, rb.x1), y1 = reveal ? rb.y1 : Math.min(b.y1, rb.y1);
        const eps = 1e-4;
        if (Math.abs(x0 - b.x0) <= eps && Math.abs(y0 - b.y0) <= eps && Math.abs(x1 - b.x1) <= eps && Math.abs(y1 - b.y1) <= eps)
            return null;
        return { x: x0 - b.x0, y: y0 - b.y0, w: Math.max(0, x1 - x0), h: Math.max(0, y1 - y0) };
    }

    // Does the slot's content ask to be laid out at rest through its open and close (`revealOnOpen`, THE REST FRAME)?
    function _revealsOf(S) {
        const it = S.contentItem;
        return !!it && it.revealOnOpen === true;
    }

    // Where a slot's content is laid out (screen px): its box, or its frame while it has one (THE REST FRAME).
    function _contentBoxOf(S) {
        const b = S.box;
        if (!b || !S.framed)
            return b;
        const x0 = b.x0 + S.frameX, y0 = b.y0 + S.frameY;
        return { x0: x0, y0: y0, x1: x0 + S.frameW, y1: y0 + S.frameH };
    }

    // The part of a slot that holds its content on this frame -- its box cut to its frame: the rest box while an open
    // overshoots it, the box while a revealed content is larger than the box -- which is what a child is placed against.
    function _heldBoxOf(S) {
        const b = S.box;
        if (!b || !S.framed)
            return b;
        const c = engine._contentBoxOf(S);
        return { x0: Math.max(b.x0, c.x0), y0: Math.max(b.y0, c.y0), x1: Math.min(b.x1, c.x1), y1: Math.min(b.y1, c.y1) };
    }

    function _slotBox(S) {
        if (S.isChild)
            return engine._childBox(S);
        const e = Geo.ease(S.easingIndex, S.t, S.overshoot);
        let b;
        if (S.move)
            b = engine._polyAt(S.move, e).box;
        else if (S.fromBox && S.toBox)
            b = Geo.lerpBox(S.fromBox, S.toBox, e);
        else
            b = S.toBox;
        return b ? Geo.collapseBox(b, S.move ? null : S.fromBox, S.move ? null : S.toBox) : null;
    }

    // =====================================================================
    //  Layout: every body's box on this frame, into the field and the mask
    // =====================================================================
    // Which of a bar's corners are SQUARE, [tl, tr, br, bl]: every corner with
    // a side on the screen's edge (a bar is never
    // rounded on a side flush with the screen). A full-width bar is square all
    // round; a bar ending mid-screen rounds only the corners of that end away
    // from the screen, and the geometry lets such a corner round across the
    // whole thickness (GooeyGeometry.js, BODY `square`).
    function _barSquare(b) {
        const e = 0.5;
        const L = b.x0 <= e, R = b.x1 >= engine.w - e;
        const T = b.y0 <= e, B = b.y1 >= engine.h - e;
        return [T || L, T || R, B || R, B || L];
    }

    // THE SKY (GooeyGeometry.js): the body beyond the screen's edge a bar's outer face lies on, for a bar with `sky` -- one gigantic
    // popup above the bars off-screen, for any edge. Far larger than the screen, so the fillets at both ends of
    // any bar have it behind them.
    function _skyBoxOf(edge) {
        const W = track.w, H = track.h, S = 4096;
        return edge === "top" ? { x0: -S, y0: -S, x1: W + S, y1: 0 }
             : edge === "bottom" ? { x0: -S, y0: H, x1: W + S, y1: H + S }
             : edge === "left" ? { x0: -S, y0: -S, x1: 0, y1: H + S }
             : { x0: W, y0: -S, x1: W + S, y1: H + S };
    }

    function layout() {
        if (engine._inLayout || !(track.w > 0) || !(track.h > 0))
            return;
        engine._layoutStats.layouts++;
        engine._inLayout = true;
        engine._releaseCloses();
        engine._releaseOpenAfter();
        engine._releasePendingChild();

        const bodies = [];
        const maskRects = [];
        const ink = engine.inkWanted ? [] : null;
        // Which body each bar and slot is, for the flourish's group and the ripple.
        const barIndex = {};
        const slotIndex = new Map();
        engine._flourishDirty = false;
        for (let i = 0; i < engine.barsList.length; i++) {
            const bar = engine.barsList[i];
            if (!bar || !(bar.absW > 0) || !(bar.absH > 0))
                continue;
            const b = { x0: bar.absX, y0: bar.absY, x1: bar.absX + bar.absW, y1: bar.absY + bar.absH };
            barIndex[bar.barId] = bodies.length;
            // The face drawn where the window's border starts (edgeFix: THE DEVICE EDGE), and a side bar's end that stops short of the
            // screen's edge (under the main bar's face, on the bottom bar's: those two run to the screen's corners) moved with the face it
            // stops at -- left where it was, the two bars' corner would be a join across a gap of the fix, and the windows' lower corners would show
            // up to 1.3 px of background at Hyprland's 1.5. The mask and the corners keep the bar's own rect.
            const fix = engine.edgeFix ? Number(engine.edgeFix[bar.edge]) || 0 : 0;
            const fixOf = e => (engine.edgeFix ? Number(engine.edgeFix[e]) || 0 : 0);
            const side = bar.edge === "left" || bar.edge === "right";
            const f = { x0: b.x0 - (bar.edge === "right" ? fix : 0), y0: b.y0 - (bar.edge === "bottom" ? fix : 0) + (side && b.y0 > 0.5 ? fixOf("top") : 0),
                        x1: b.x1 + (bar.edge === "left" ? fix : 0), y1: b.y1 + (bar.edge === "top" ? fix : 0) - (side && b.y1 < track.h - 0.5 ? fixOf("bottom") : 0) };
            bodies.push({ id: "bar:" + bar.barId, x0: f.x0, y0: f.y0, x1: f.x1, y1: f.y1,
                          r: bar.radius, mobile: false, square: engine._barSquare(b),
                          skyBox: bar.sky ? engine._skyBoxOf(bar.edge) : undefined });
            if (bar.inputMask !== false)
                maskRects.push(bar.maskBox ? engine._asBox(bar.maskBox) : b);
            if (ink) {
                // a bar is a band of its edge as deep as its far face (the region holds the whole band: an island moving along it changes nothing)
                const e = bar.edge;
                const depth = e === "top" ? Math.max(b.y1, f.y1) : e === "bottom" ? track.h - Math.min(b.y0, f.y0)
                    : e === "left" ? Math.max(b.x1, f.x1) : track.w - Math.min(b.x0, f.x0);
                ink.push({ edge: e, depth: depth });
            }
        }

        // (The reel's strip last, and its chain after it: bodies drawn only while they are out, so with none they add no index or uniform.)
        const order = [engine._primary, engine._spare()].concat(engine.childPopups, [reelSlot], engine.reelChildPopups);
        const clipOf = [];
        const tintSlots = [];
        let primaryIndex = -1;
        let reelMaskRect = null;
        let reelIndex = -1;
        let primaryTension = null;
        // THE LANE first, drawn last: every other slot is kept on its side of
        // the lane's box on this frame (Geo.laneClip), and melts with it (the
        // field's PEERS). With no lane nothing here changes a body.
        const lane = laneSlot;
        const laneOwn = lane.phase !== "closed" ? engine._slotBox(lane) : null;
        const laneAxis = engine._laneAxis(lane.edge);
        // THE LANE GIVES WAY (header): a stack folding for a popup, or hung from one that closes, does not cut it.
        const hopFolding = !!laneOwn && lane.phase === "closing" && lane.hopFold;
        const following = !!laneOwn && engine._laneFollow !== null;
        const laneBox0 = hopFolding || following ? null : laneOwn;
        let laneBox = laneOwn;
        for (const S of order) {
            if (S.phase === "closed") {
                S.box = null;
                continue;
            }
            let b = engine._slotBox(S);
            if (!b) {
                S.box = null;
                continue;
            }
            // THE FLOATING POPUP: off the screen's edges (a child follows its parent's drawn box, shifted already)
            const fdelta = !S.isChild && S.floatF > 0 ? engine._floatDelta(b, S.edge, S.floatF) : null;
            if (fdelta)
                b = engine._floatMoved(b, fdelta);
            if (laneBox0 && S.laneSide !== 0)
                b = Geo.laneClip(b, laneBox0, S.laneAxis || laneAxis, S.laneSide);
            S.box = b;
            S.popX = b.x0;
            S.popY = b.y0;
            S.popW = b.x1 - b.x0;
            S.popH = b.y1 - b.y0;
            // THE REST FRAME (header): the values first, then the switch, so the content never sees a frame half written.
            const fr = engine._restFrameOf(S, b);
            if (fr) {
                if (S.frameX !== fr.x) S.frameX = fr.x;
                if (S.frameY !== fr.y) S.frameY = fr.y;
                if (S.frameW !== fr.w) S.frameW = fr.w;
                if (S.frameH !== fr.h) S.frameH = fr.h;
                if (!S.framed) S.framed = true;
            } else if (S.framed) {
                S.framed = false;
            }
            const bw = b.x1 - b.x0, bh = b.y1 - b.y0;
            if (S === engine._primary)
                primaryIndex = bodies.length;
            if (S === reelSlot)
                reelIndex = bodies.length;
            slotIndex.set(S, bodies.length);
            clipOf.push({ slot: S, index: bodies.length });
            tintSlots.push({ slot: S, index: bodies.length });
            const ff = engine._floatOf(S);
            const tr0 = Geo.tensionRadii(bw, bh, S.fullW, S.fullH, engine.maxR * S.ratio);
            const tr = ff > 0 ? engine._pillRadii(tr0, bw, bh, S.ratio, ff) : tr0;
            if (S === engine._primary)
                primaryTension = tr;
            let stick = engine._stickOf(S);
            if (fdelta && stick)
                stick = engine._floatMoved(stick, fdelta);
            // A join facing the lane does not stretch into it.
            if (laneBox0 && S.laneSide !== 0 && stick)
                stick = Geo.laneClip(stick, laneBox0, S.laneAxis || laneAxis, S.laneSide);
            const body = {
                id: engine._bodyIdOf(S),
                x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y1,
                rx: tr.rx, ry: tr.ry, mobile: true,
                stick: stick,
                parent: S.isChild && S.parentSlot ? engine._bodyIdOf(S.parentSlot) : "",
                // The bar it hangs from: only its ends draw this popup's ends
                // flush (GooeyGeometry.js SNAPPING) -- a side bar it rests
                // against held a manager's foot on that bar's end.
                host: "bar:" + S.barId,
                attract: S.attractF,
                // The edge it hangs from: where it rests flush against a bar across
                // that edge, its foot's corner is that bar's own corner travelling
                // (GooeyGeometry.js THE WALL JOIN). Not a secondary's, not the lane's.
                wallJoin: S.isChild ? "" : S.edge
            };
            // THE SLIVER BESIDE A STACK AT HOME: a popup with no
            // depth yet or none left -- the first frames of an open, the OutBack tail of a close, where its width still swings across the
            // bar's end -- draws nothing, but it is a guest of the bar's island like any other and its end, a few px from the island's end,
            // wins the island's lower corner as the convex piece of ITS S. The stack at home under the same island claims that corner square
            // (its own S is solved against a square one), so the two joins would disagree and the corner would stay round over air the stack's fillet and
            // the sliver enclose: a pocket of the ring's colour, 20 px, that pops in and out (218 px of
            // the inside flip in one frame in a replay; 0 with the sliver unrelated). A sliver is related to nothing while the stack stands under
            // the same bar; its relations return with its first pixel of depth.
            // ...AND IT IS DRAWN WITH NO AREA: unrelated is not enough. A sliver of 0.3 px (the first frame of an open that lands
            // a hair after the clock's start, or a frame of the close's tail) still encloses a pocket of the ring's colour 5 x 8 px at the island's
            // lower corner -- 121 to 136 half-pixel samples in a replay of the engine's own record, whether the stack hangs from its foot or stands
            // at home -- where the same popup at depth 0 (no area: not drawn) leaves none. So the field is handed it as it is at depth 0: the
            // depth axis collapsed onto the bar's face (the box the content clips to and the mask are untouched). Which of the two a film frame
            // catches is luck, so a film of it reads bimodal on identical code.
            if (laneOwn && lane.placedSide === 0 && !S.isChild && S.edge === lane.edge
                    && (engine._laneAxis(S.edge) === "x" ? b.y1 - b.y0 : b.x1 - b.x0) < engine.laneSliverPx) {
                body.free = true;
                engine._collapseSliver(body, S.edge);
            }
            // a floating popup (and its children) is related to nothing: no join with a bar, no snapping; on the way home its joins come in (THE WAY HOME, header)
            if (ff > engine.floatJoinAt)
                body.free = true;
            else if (ff > 0)
                body.join = 1 - Geo.smoothstep(0, engine.floatJoinAt, ff);
            // (Hung from a popup's foot the lane is its CHILD, below; beside it the two are peers -- also while the stack folds INTO this
            // popup's edge for it (_closeLane): the stack is cut to the popup's drawn face and melts into it to the end, where unmelted it
            // would be an oval with the ring round it beside the popup, off its bar as well.)
            if (laneOwn && (!hopFolding || lane.placedSide !== 0) && engine.laneMelt && !lane.placedBelow)
                body.peer = "lane";
            bodies.push(body);
            maskRects.push(engine._maskRectOf(S, b));
            if (ink)
                ink.push(maskRects[maskRects.length - 1]);
            if (S === reelSlot)
                reelMaskRect = maskRects[maskRects.length - 1];
        }
        // THE REEL PASS (header): which bodies are the reel group (the strip, then its levels), which the bars and which the popups a
        // card can lie over -- said BEFORE the field shapes this frame, so the pass is fed this frame's classes with this frame's shape.
        {
            const group = [reelSlot].concat(engine.reelChildPopups).map(S => slotIndex.has(S) ? slotIndex.get(S) : -1);
            const pops = [slotA, slotB].concat(engine.childPopups).filter(S => slotIndex.has(S)).map(S => slotIndex.get(S));
            reelCastLayer.plan = group.some(i => i >= 0) && pops.length > 0
                ? { group: group, bars: Object.keys(barIndex).map(k => barIndex[k]), pops: pops } : null;
        }

        // The stack, once the popups have their boxes: cut to the popup's drawn box on its own side while it folds for it, on the
        // popup's drawn face while it follows a popup closing.
        if (hopFolding) {
            for (const S of order)
                if (S.box && S.laneSide !== 0 && S.phase !== "closed")
                    laneBox = Geo.laneClip(laneBox, S.box, S.laneAxis || laneAxis, -S.laneSide);
        } else if (following) {
            laneBox = engine._laneFollowBox(laneOwn);
        }
        lane.box = laneBox;
        if (laneBox) {
            lane.popX = laneBox.x0;
            lane.popY = laneBox.y0;
            lane.popW = laneBox.x1 - laneBox.x0;
            lane.popH = laneBox.y1 - laneBox.y0;
            clipOf.push({ slot: lane, index: bodies.length });
            tintSlots.push({ slot: lane, index: bodies.length });
            const tr = Geo.tensionRadii(lane.popW, lane.popH, lane.fullW, lane.fullH, engine.maxR * lane.ratio);
            bodies.push({ id: "lane", x0: laneBox.x0, y0: laneBox.y0, x1: laneBox.x1, y1: laneBox.y1,
                          rx: tr.rx, ry: tr.ry, mobile: true, stick: engine._stickOf(lane),
                          parent: lane.placedBelow ? engine._bodyIdOf(engine._primary) : "", host: "bar:" + lane.barId });
            maskRects.push(engine._maskRectOf(lane, laneBox));
            if (ink)
                ink.push(maskRects[maskRects.length - 1]);
        }

        // THE OSD (header): after the lane, before the flourish -- with none out it adds no
        // body, index or uniform. It yields on EVERY frame: its
        // box (and the box its joins stick to) is cut to its side of every other slot
        // it shares a band with (Geo.laneClip), so a popup's OutBack overshoot squeezes
        // the OSD and never the reverse; and it melts with the neighbours it lies flush
        // against on its own bar (`peer`, a list).
        const osd = osdSlot;
        let osdBox = null;
        if (osd.phase !== "closed")
            osdBox = (engine.osdPoseBox ? engine._asBox(engine.osdPoseBox) : null) || engine._slotBox(osd);
        if (osdBox) {
            const osdAxis = engine._laneAxis(osd.edge);
            let osdStick = engine._stickOf(osd);
            // ...and it melts with whatever it lies flush against on THIS frame too, not only with what it was placed
            // against: a popup's overshoot squeezes it flush, and a popup closing away from where it rests is swept by it
            // (the join's weight is the contact's, so one far off draws nothing).
            const touchingNow = osd.peerIds.slice();
            for (const e of [slotA, slotB].concat(engine.childPopups, [lane]).map(X => [engine._bodyIdOf(X), X])) {
                const side = osd.yieldSides[e[0]] || 0;
                if (side === 0 || !e[1].box || e[1].phase === "closed")
                    continue;
                osdBox = Geo.laneClip(osdBox, e[1].box, osdAxis, side);
                if (osdStick)
                    osdStick = Geo.laneClip(osdStick, e[1].box, osdAxis, side);
                if (touchingNow.indexOf(e[0]) < 0 && engine._hasArea(osdBox) && engine._hasArea(e[1].box)
                        && engine._sharesBand(osdBox, e[1].box, osdAxis)) {
                    const X = osdAxis === "x";
                    const gap = side > 0 ? (X ? osdBox.x0 - e[1].box.x1 : osdBox.y0 - e[1].box.y1)
                                         : (X ? e[1].box.x0 - osdBox.x1 : e[1].box.y0 - osdBox.y1);
                    if (Math.abs(gap) < 0.75)
                        touchingNow.push(e[0]);
                }
            }
            osd.box = osdBox;
            osd.popX = osdBox.x0;
            osd.popY = osdBox.y0;
            osd.popW = osdBox.x1 - osdBox.x0;
            osd.popH = osdBox.y1 - osdBox.y0;
            clipOf.push({ slot: osd, index: bodies.length });
            tintSlots.push({ slot: osd, index: bodies.length });
            const otr = Geo.tensionRadii(osd.popW, osd.popH, osd.fullW, osd.fullH, engine.maxR * osd.ratio);
            bodies.push({ id: "osd", x0: osdBox.x0, y0: osdBox.y0, x1: osdBox.x1, y1: osdBox.y1,
                          rx: otr.rx, ry: otr.ry, mobile: true, stick: osdStick, parent: "", host: "bar:" + osd.barId,
                          peer: engine.osdMelt ? touchingNow : [] });
            // THE TUCK's hover zone (the header): it takes input over the slim bar beside the sliver, which takes none of its own (an
            // outlet is in the compositor's gap: nothing of a window is under it), so the OSD's rect in the input region is the zone
            const info = engine.osdTuckedRest ? track.getBarInfoById(osd.barId) : null;
            const zone = info ? engine._osdTuckZoneBox(osdBox, osd.edge, info.thickness) : null;
            engine._placeTuckZone(zone);
            const mr = engine._maskRectOf(osd, osdBox);
            if (ink)
                ink.push(mr);
            maskRects.push(zone ? { x0: Math.min(mr.x0, zone.x0), y0: Math.min(mr.y0, zone.y0), x1: Math.max(mr.x1, zone.x1), y1: Math.max(mr.y1, zone.y1) } : mr);
        } else {
            osd.box = null;
            engine._placeTuckZone(null);
        }

        // THE BUDGET (header). The field draws maxBodies; past that the last bodies lose their
        // surface. Nothing is written to the field yet: the OSD, then the lane, give their bodies
        // up (their requests stay) and the layout is done again without them. With the primaries
        // and the bars alone past the budget there is nothing left to give and it goes on as it
        // is.
        if (bodies.length > field.maxBodies && (osdBox || laneBox)) {
            let over = bodies.length - field.maxBodies;
            if (osdBox) {
                engine._budgetYield(osd);
                over--;
            }
            if (laneBox && over > 0)
                engine._budgetYield(lane);
            engine._inLayout = false;
            engine.layout();
            return;
        }
        // ...and past them, the deepest level of the reel strip's chain (the last body of the slots: a body that became live under
        // it -- the spare, while a popup changes owner -- took its place). It goes now and waits for a body, as they do; its
        // parent's contract opens it again when one is free (_bodyFreed).
        const reelLast = bodies.length > field.maxBodies ? engine.reelChildPopups.filter(C => C.phase !== "closed").pop() : null;
        if (reelLast) {
            // (one that was closing anyway is not asked back)
            if (reelLast.live)
                engine._reelChainWaits = true;
            engine._finishClose(reelLast);
            engine._inLayout = false;
            engine.layout();
            return;
        }

        // THE FLOURISH (header): a FREE body after every slot, none of the
        // per-slot rules and no input rect; then the droplets, while body
        // indices are left.
        const F = flourishSlot;
        let flourishIndex = -1;
        const fb = F.live ? engine._flourishBox : null;
        if (fb && bodies.length < field.maxBodies) {
            F.box = fb;
            F.popX = fb.x0;
            F.popY = fb.y0;
            F.popW = fb.x1 - fb.x0;
            F.popH = fb.y1 - fb.y0;
            flourishIndex = bodies.length;
            clipOf.push({ slot: F, index: flourishIndex });
            tintSlots.push({ slot: F, index: flourishIndex });
            bodies.push({ id: "flourish", x0: fb.x0, y0: fb.y0, x1: fb.x1, y1: fb.y1,
                          radii: engine._flourishRadii, mobile: true, free: true });
        } else {
            F.box = null;
            F.popW = 0;
            F.popH = 0;
        }
        const dropIndex = [];
        engine._retireDroplets();
        engine._budgetDroplets(field.maxBodies - bodies.length);
        for (const d of engine._droplets) {
            if (bodies.length >= field.maxBodies)
                break;
            const db = engine.dropletBox(d);
            const dr = (db.x1 - db.x0) / 2;
            dropIndex.push(bodies.length);
            bodies.push({ id: "drop" + d.id, x0: db.x0, y0: db.y0, x1: db.x1, y1: db.y1,
                          radii: [dr, dr, dr, dr], mobile: true, free: true });
        }
        // The smooth group asked for, as the body ids present now; 'host': that
        // owner's primary while it is CLOSING, found every layout (reopened it is
        // not closing, reused it is not that owner's). Then the group EASED to it
        // (header), as body bits (fewer than two, or k 0: none).
        const hostOwner = engine._flourishHostOwner;
        const host = hostOwner === "" ? null
            : [engine._primary, engine._spare()].find(S => S.phase === "closing" && S.ownerId === hostOwner) || null;
        const idIndex = {};
        for (let i = 0; i < bodies.length; i++)
            idIndex[bodies[i].id] = i;
        const want = [];
        const ask = id => {
            if (want.indexOf(id) < 0)
                want.push(id);
        };
        for (const m of engine._flourishGroup) {
            if (m === "flourish" && flourishIndex >= 0)
                ask("flourish");
            else if (m === "droplets")
                for (const j of dropIndex)
                    ask(bodies[j].id);
            else if (m === "host" && host && slotIndex.has(host))
                ask(bodies[slotIndex.get(host)].id);
            else if (m.indexOf("bar:") === 0 && barIndex[m.slice(4)] !== undefined)
                ask(m);
        }
        const groupIds = engine._easeGroup(want, idIndex);
        engine._groupSeen = idIndex;
        let mask = 0;
        for (const id of groupIds)
            mask |= 1 << idIndex[id];
        const smoothK = groupIds.length >= 2 && engine._groupK > 0 ? engine._groupK : 0;
        if (!smoothK)
            mask = 0;
        // The neck between the flourish and the closing host (setFlourishNeck):
        // the bodies' indices now, the field draws it when both are there.
        const neckNow = engine._flourishNeck !== null && flourishIndex >= 0 && host && slotIndex.has(host)
            ? Object.assign({ sideA: flourishIndex, sideB: slotIndex.get(host) }, engine._flourishNeck) : null;
        // A body coming to the rippling bar's face (a popup or the lane opening
        // on it, one reaching it from a perpendicular bar) fades the ripple out,
        // and so does a neck (the two share the field's lanes).
        if (engine._rippleBarId !== "" && (neckNow !== null || engine._barHeld(engine._rippleBarId)))
            engine._rippleCut();
        const rippleIndex = engine._rippleBarId !== "" && barIndex[engine._rippleBarId] !== undefined
            ? barIndex[engine._rippleBarId] : -1;

        field.batch(() => {
            if (field.smoothMask !== mask)
                field.smoothMask = mask;
            if (field.smoothK !== smoothK)
                field.smoothK = smoothK;
            field.neck = neckNow;
            engine._pushRipple(rippleIndex);
            field.bodies = bodies;
        });
        engine._tintSlots = tintSlots;
        engine._pushTints();
        engine._pushAura(bodies);

        // The outline the field just drew each slot with, handed to that slot
        // so gooey_clip.frag can cut its content to it (GooeyBody: "The cut to
        // the field's own outline"). `field.bodies` is applied synchronously,
        // so cornerRadii is this frame's.
        for (let i = 0; i < clipOf.length; i++)
            engine._applyClip(clipOf[i].slot, field.cornerRadii[clipOf[i].index]);
        for (const S of order.concat([lane, osd, F]))
            if (S.phase === "closed") {
                S.clipOn = false;
                S.seamFade = Qt.vector4d(0, 0, 0, 0);
            }

        // Every child level: the part of it its parent covers, in its own
        // coordinates, for content that declares `secondaryCutout` (an inset
        // child); and whether its box moves on this frame. Each clock's last
        // tick (t, slideT at 1) lays out once more, so the flag always ends false.
        for (const C of engine.childPopups.concat(engine.reelChildPopups)) {
            const cit = C.contentItem;
            if (cit && ("secondaryCutout" in cit)) {
                // (the parent's content over the child's, from the child's content's origin: THE REST FRAME)
                const cb = engine._heldBoxOf(C), co = engine._contentBoxOf(C);
                const pb = C.parentSlot ? engine._heldBoxOf(C.parentSlot) : null;
                let r = Qt.rect(0, 0, 0, 0);
                if (cb && pb) {
                    const x0 = Math.max(cb.x0, pb.x0), y0 = Math.max(cb.y0, pb.y0);
                    const x1 = Math.min(cb.x1, pb.x1), y1 = Math.min(cb.y1, pb.y1);
                    // in the child's content's units (THE RATIOS)
                    const ck = C.ratio > 0 ? C.ratio : 1;
                    if (x1 > x0 && y1 > y0)
                        r = Qt.rect((x0 - co.x0) / ck, (y0 - co.y0) / ck, (x1 - x0) / ck, (y1 - y0) / ck);
                }
                engine._applyCutout(cit, r);
            }
            if (cit && ("secondaryMoving" in cit))
                engine._applyMoving(cit, (C.phase === "opening" && C.t < 1)
                                         || C.phase === "closing" || C.slideT < 1);
        }

        // popupRadius is the popup's free-corner radius
        // (max(effRx, effRy)); the per-corner list is what the field draws.
        // (in the primary's content's units: THE RATIOS)
        const radii = primaryIndex >= 0 ? field.cornerRadii[primaryIndex] : null;
        const pk = engine._primary.ratio > 0 ? engine._primary.ratio : 1;
        engine._popupRadii = radii ? radii.ex.map((v, i) => Math.max(v, radii.ey[i]) / pk) : [0, 0, 0, 0];
        // ...and the reel strip's, in its own content's units (it continues a bar cell: the bar's ratio).
        const rr = reelIndex >= 0 ? field.cornerRadii[reelIndex] : null;
        const rk = reelSlot.ratio > 0 ? reelSlot.ratio : 1;
        const reelR = rr ? Math.max.apply(null, rr.ex.map((v, i) => Math.max(v, rr.ey[i]))) / rk : 0;
        if (engine._reelRadius !== reelR)
            engine._reelRadius = reelR;
        {
            const rm = reelMaskRect;
            const x = rm ? Math.floor(rm.x0) : 0, y = rm ? Math.floor(rm.y0) : 0;
            const mw = rm ? Math.ceil(rm.x1) - x : 0, mh = rm ? Math.ceil(rm.y1) - y : 0;
            if (reelMaskProxy.x !== x) reelMaskProxy.x = x;
            if (reelMaskProxy.y !== y) reelMaskProxy.y = y;
            if (reelMaskProxy.width !== mw) reelMaskProxy.width = mw;
            if (reelMaskProxy.height !== mh) reelMaskProxy.height = mh;
        }
        engine._popupRadius = primaryTension ? Math.max(primaryTension.rx, primaryTension.ry) / pk : 0;

        // A content that asks for it (`maskCatchAll`: the auth prompt's outside
        // click, a menu a press in the void dismisses) takes the WHOLE track as
        // input: one more rect, so a press anywhere reaches the shell -- the
        // content where it lands on its body, the void catcher where it lands
        // on nothing.
        const catching = engine._catchers();
        if (catching.length !== engine._catching.length || catching.some((S, i) => S !== engine._catching[i]))
            engine._catching = catching;
        if (catching.length > 0)
            maskRects.push({ x0: 0, y0: 0, x1: track.w, y1: track.h });

        for (let i = 0; i < engine._maskItems.length; i++) {
            const m = engine._maskItems[i];
            const r = maskRects[i];
            const x = r ? Math.floor(r.x0) : 0, y = r ? Math.floor(r.y0) : 0;
            const mw = r ? Math.ceil(r.x1) - x : 0, mh = r ? Math.ceil(r.y1) - y : 0;
            if (m.x !== x) m.x = x;
            if (m.y !== y) m.y = y;
            if (m.width !== mw) m.width = mw;
            if (m.height !== mh) m.height = mh;
        }

        if (ink) {
            let key = "";
            for (let i = 0; i < ink.length; i++) {
                const r = ink[i];
                key += r.edge ? r.edge + Math.ceil(r.depth) + ";"
                     : Math.floor(r.x0) + "," + Math.floor(r.y0) + "," + Math.ceil(r.x1) + "," + Math.ceil(r.y1) + ";";
            }
            if (key !== engine._inkKey) {
                engine._inkKey = key;
                engine.inkBoxes = ink;
            }
        }

        engine._inLayout = false;
        // After the layout: a content that sizes itself from its room lays out
        // again rather than being dropped by the re-entry guard.
        engine._assignRoom(engine._primary);
        if (laneBox)
            engine._assignRoom(lane);
        if (osdBox)
            engine._assignRoom(osd);
    }

    // One slot's cut. The outline is in the body's OWN pixels, so a face the
    // field snapped elsewhere still lands where the ink is.
    //
    // The mask is a layer, and a layer at rest is an FBO nobody needs plus a
    // resample of everything in it, so it is on only while the outline is
    // something other than the resting rounded rectangle: a phase that is not
    // "open", a corner surface tension has inflated past maxR, or a face the
    // field moved off the body's box. At rest the rectangle the body already
    // clips to and the outline differ by corners of maxR, which the design
    // language's own radius rule keeps free of ink.
    function _applyClip(S, r) {
        if (!r) {
            S.clipOn = false;
            S.seamFade = Qt.vector4d(0, 0, 0, 0);
            return;
        }
        if (S.isFlourish) {
            engine._applyFlourishClip(S, r);
            return;
        }
        // The face the body hangs from is not an outline: its bar (a child's:
        // its parent) is drawn on the other side of it, and content crossing
        // it -- the reel's icons run straight through from the bar's cell --
        // continues there. The cut's inset and feather are an edge's
        // tolerance, and on this face they are a half-pixel line through
        // whatever crosses it. So the box is grown far past it while both of
        // its corners are square, which is when the face lies on the host;
        // a rounded corner there (a 2D open out of a point) keeps the cut.
        // The body's own rectangle clip still ends the content on the face.
        const box = [r.x0 - S.popX, r.y0 - S.popY, r.x1 - S.popX, r.y1 - S.popY];
        const face = S.isChild ? { top: "bottom", bottom: "top", left: "right", right: "left" }[S.edge]
                               : S.edge;
        const fi = { left: 0, top: 1, right: 2, bottom: 3 }[face];
        // Corners TL, TR, BR, BL; the face's two.
        const fc = { left: [3, 0], top: [0, 1], right: [1, 2], bottom: [2, 3] }[face];
        if (fc && fc.every(k => Math.min(r.ex[k], r.ey[k]) < 0.05)) {
            const g = Math.max(S.popW, S.popH) + engine._hostThickness(S);
            box[fi] += fi < 2 ? -g : g;
        }
        S.clipBox = Qt.vector4d(box[0], box[1], box[2], box[3]);
        S.clipEx = Qt.vector4d(r.ex[0], r.ex[1], r.ex[2], r.ex[3]);
        S.clipEy = Qt.vector4d(r.ey[0], r.ey[1], r.ey[2], r.ey[3]);
        S.clipIx = Qt.vector4d(r.ix[0], r.ix[1], r.ix[2], r.ix[3]);
        S.clipIy = Qt.vector4d(r.iy[0], r.iy[1], r.iy[2], r.iy[3]);
        // A popup holding its close for its secondary has not moved yet, so its
        // outline is still the resting one: no need for the layer.
        let on = engine.forceContentClip || (S.phase !== "open" && !S.closeHeld);
        const rest = engine.maxR * S.ratio + 0.5;
        for (let k = 0; k < 4 && !on; k++)
            on = r.ex[k] > rest || r.ey[k] > rest;
        if (!on)
            on = Math.abs(r.x0 - S.popX) > 0.5 || Math.abs(r.y0 - S.popY) > 0.5
                || Math.abs(r.x1 - S.popX - S.popW) > 0.5 || Math.abs(r.y1 - S.popY - S.popH) > 0.5;
        // A FLOATING popup keeps the cut at rest. Its content is laid out for the popup
        // it docks as, whose corners on its face are square against the bar; floating, those corners are rounded, and a content drawing to its
        // box's corner there (the clipboard's) would be cut to them only while the cut is on -- moving -- and stand square past the outline at rest.
        if (!on && engine._floatOf(S) > 0.001)
            on = true;
        // Never under a live resize: the outline there is the resting one but
        // for a face drawn flush with a bar's end (flushSnap px), and a layer
        // switched on and off under a drag is an FBO allocated and a resample
        // of the whole content on the frames it crosses that end.
        if (!engine.forceContentClip && engine._liveOf(S))
            on = false;
        S.clipOn = on;

        // THE FADE BESIDE A FILLET (GooeyBody: seamFade). The cut above is the
        // body's outline, and wherever the field goes on past an edge the fold
        // moves, over surface, no outline of the body reaches: the moving edge
        // cut the content there straight across. Past the FAR edge (opposite
        // the face) that happens where a far corner is drawn square -- the
        // field squares a corner only where it joins it, into a perpendicular
        // bar or a peer, and its fillet runs on down that (the lane closing
        // into its corner: a card and its icon ended on a line, surface
        // below). Past a SIDE edge it always happens: at the face the S fillet
        // into the host bar runs on beyond every side, and a popup the body
        // sits beside melts into it (the lane closing sideways, away from
        // thePopup: its header, body and bell cut straight down).
        // So while the body opens or closes, its content fades toward every
        // edge the fold moves, but for a far edge with no join. The length is
        // the field's own reach past the box (blendRadius) on the fold's
        // envelope along that edge's axis (SeamFade's, min(1, 6e(1 - e)) of
        // the fold's own fraction: nothing at either end), so rest is untouched
        // and the layer comes and goes at no fade. A far join whose fade has
        // been drawn keeps it to the fold's end: the field rounds that corner
        // again where the fold is a few px thin, and the fade would snap off there
        // over content still at 10-17 % (a join seen only at the fold's end point,
        // at no fade -- the lane leaving thePopup's side -- latches nothing). A
        // resize (moving) takes none: its target changes under the envelope,
        // which would switch the fade on at full length.
        const fade = [0, 0, 0, 0];
        const ends = on && (S.phase === "opening" || S.phase === "closing") && !S.closeHeld && fi !== undefined
            ? engine._foldEnds(S) : null;
        if (ends) {
            const far = (fi + 2) % 4;
            const key = ["x0", "y0", "x1", "y1"];
            const env = k => {
                const vertical = k === 0 || k === 2;
                const full = vertical ? S.fullW : S.fullH, now = vertical ? S.popW : S.popH;
                const e = full > 0 ? Math.max(0, Math.min(1, now / full)) : 1;
                return engine._blendRadius * Math.min(1, 6 * e * (1 - e));
            };
            let joined = [[3, 0], [0, 1], [1, 2], [2, 3]][far].some(k => Math.min(r.ex[k], r.ey[k]) < 0.05);
            if (joined && env(far) > 0.5)
                S.seamJoinRun = S.runSerial;
            joined = joined || S.seamJoinRun === S.runSerial;
            for (let k = 0; k < 4; k++)
                if (k !== fi && (k !== far || joined) && Math.abs(ends.rest[key[k]] - ends.origin[key[k]]) >= 0.5)
                    fade[k] = env(k);
        }
        S.seamFade = Qt.vector4d(fade[0], fade[1], fade[2], fade[3]);
    }

    // The two ends of a fold: the box it is (or was) open at and the box it
    // folds out of or into. An edge where they differ is one the fold moves.
    function _foldEnds(S) {
        if (S.isChild) {
            const rest = engine._childBox(S, 1), origin = engine._childBox(S, 0);
            return rest && origin ? { rest: rest, origin: origin } : null;
        }
        const rest = S.phase === "opening" ? S.toBox : S.fromBox, origin = S.phase === "opening" ? S.fromBox : S.toBox;
        return rest && origin ? { rest: rest, origin: origin } : null;
    }

    // The flourish's cut: its outline as drawn (no face: it hangs from nothing),
    // the layer on for its whole life, and the face of the bar it sinks into.
    function _applyFlourishClip(S, r) {
        S.clipBox = Qt.vector4d(r.x0 - S.popX, r.y0 - S.popY, r.x1 - S.popX, r.y1 - S.popY);
        S.clipEx = Qt.vector4d(r.ex[0], r.ex[1], r.ex[2], r.ex[3]);
        S.clipEy = Qt.vector4d(r.ey[0], r.ey[1], r.ey[2], r.ey[3]);
        S.clipIx = Qt.vector4d(r.ix[0], r.ix[1], r.ix[2], r.ix[3]);
        S.clipIy = Qt.vector4d(r.iy[0], r.iy[1], r.iy[2], r.iy[3]);
        const lim = [-1e6, -1e6, 1e6, 1e6];
        const f = engine._flourishCutBar !== "" ? engine._barFace(engine._flourishCutBar) : null;
        if (f)
            lim[f.side] = f.pos - (f.side === 0 || f.side === 2 ? S.popX : S.popY);
        const cl = S.clipLim;
        if (cl.x !== lim[0] || cl.y !== lim[1] || cl.z !== lim[2] || cl.w !== lim[3])
            S.clipLim = Qt.vector4d(lim[0], lim[1], lim[2], lim[3]);
        S.clipOn = true;
    }

    // A bar's free face as a cut: which edge of a body entering it the face
    // bounds (0 L, 1 T, 2 R, 3 B: a bottom bar's top face bounds a body's
    // bottom) and where it lies (engine px).
    function _barFace(barId) {
        const info = track.getBarInfoById(barId);
        const b = info ? info.bar : null;
        if (!b)
            return null;
        if (b.edge === "bottom")
            return { side: 3, pos: b.absY };
        if (b.edge === "top")
            return { side: 1, pos: b.absY + b.absH };
        if (b.edge === "left")
            return { side: 0, pos: b.absX + b.absW };
        return { side: 2, pos: b.absX };
    }

    // The thickness of the bar a slot hangs from (a child: its parent's).
    function _hostThickness(S) {
        const P = S.isChild ? S.parentSlot : S;
        const info = P ? track.getBarInfoById(P.barId) : null;
        return info ? info.thickness : engine.thickness;
    }

    // The lowest and highest value an easing takes on [0, 1], sampled once per
    // (curve, overshoot).
    property var _easeRanges: ({})
    function _easeRange(index, overshoot) {
        const k = index + ":" + overshoot;
        let r = engine._easeRanges[k];
        if (!r) {
            r = { min: 0, max: 1 };
            for (let i = 0; i <= 64; i++) {
                const v = Geo.ease(index, i / 64, overshoot);
                r.min = Math.min(r.min, v);
                r.max = Math.max(r.max, v);
            }
            engine._easeRanges[k] = r;
        }
        return r;
    }

    // What a popup's joins stick to while it opens or closes: the box it is (or
    // was) open at, and how much, scaled by how much of the popup is there yet
    // along its bar, so a sliver just out of the bar pulls no long flares.
    // The box a popup is open at, while it opens or closes: its joins resist
    // following its sides toward it. How much of the popup is out is decided per
    // join, along the bar that join runs on (GooeyGeometry.js), not here.
    function _stickOf(S) {
        if (S.phase !== "opening" && S.phase !== "closing")
            return null;
        return (S.isChild ? engine._childBox(S, 1) : (S.phase === "opening" ? S.toBox : S.fromBox)) || null;
    }

    // The input rect of a slot: its exact box at rest, and for the whole of a
    // transition the union of where it came from and where it is going, so the
    // compositor hears about it twice rather than every frame.
    function _maskRectOf(S, b) {
        // A live resize holds the whole engine: the drag goes wherever the
        // pointer does, and the compositor hears about it twice (on and off).
        // A content that asks for "box" (it moves its own size; nobody drags)
        // keeps the box it has on this frame: phase "open", so the exact box.
        if (engine._liveOf(S) && engine._liveMaskOf(S) !== "box")
            return { x0: 0, y0: 0, x1: track.w, y1: track.h };
        let r = { x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y1 };
        const grow = (a) => {
            if (!a)
                return;
            r.x0 = Math.min(r.x0, a.x0);
            r.y0 = Math.min(r.y0, a.y0);
            r.x1 = Math.max(r.x1, a.x1);
            r.y1 = Math.max(r.y1, a.y1);
        };
        if (S.phase !== "open") {
            if (S.isChild) {
                r = { x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y1 };
                // A child's box follows its parent; hold the whole side it
                // can occupy while it moves.
                const pb = S.parentSlot ? S.parentSlot.box : null;
                if (pb && S.phase !== "closing") {
                    const sideways = S.edge === "left" || S.edge === "right";
                    const out = sideways ? S.fullW : S.fullH;
                    if (S.edge === "bottom") grow({ x0: pb.x0, y0: pb.y1, x1: pb.x1, y1: pb.y1 + out });
                    else if (S.edge === "top") grow({ x0: pb.x0, y0: pb.y0 - out, x1: pb.x1, y1: pb.y0 });
                    else if (S.edge === "right") grow({ x0: pb.x1, y0: pb.y0, x1: pb.x1 + out, y1: pb.y1 });
                    else grow({ x0: pb.x0 - out, y0: pb.y0, x1: pb.x0, y1: pb.y1 });
                }
            } else {
                // Not the current box: that moves every frame. The union of
                // the from and to boxes at the easing's lowest and highest
                // value holds still for the whole transition and still covers
                // an OutBack overshoot past either end.
                r = null;
                const range = engine._easeRange(S.easingIndex, S.overshoot);
                const f = S.fromBox || b, to = S.toBox || b;
                for (const e of [0, 1, range.min, range.max]) {
                    const lb = Geo.lerpBox(f, to, e);
                    if (!r)
                        r = { x0: Math.min(lb.x0, lb.x1), y0: Math.min(lb.y0, lb.y1),
                              x1: Math.max(lb.x0, lb.x1), y1: Math.max(lb.y0, lb.y1) };
                    else
                        grow({ x0: Math.min(lb.x0, lb.x1), y0: Math.min(lb.y0, lb.y1),
                               x1: Math.max(lb.x0, lb.x1), y1: Math.max(lb.y0, lb.y1) });
                }
                if (S.move) {
                    grow({ x0: S.move.sx, y0: S.move.sy, x1: S.move.sx + S.move.sw, y1: S.move.sy + S.move.sh });
                    grow({ x0: S.move.ex, y0: S.move.ey, x1: S.move.ex + S.move.ew, y1: S.move.ey + S.move.eh });
                    for (const cn of S.move.corners) {
                        const cw = Math.max(S.move.sw, S.move.ew), ch = Math.max(S.move.sh, S.move.eh);
                        const p = engine._cornerPos(cn, cw, ch);
                        grow({ x0: p.x, y0: p.y, x1: p.x + cw, y1: p.y + ch });
                    }
                }
            }
        }
        // A floating popup moves with its float: where it stands now and where it is going (the union holds still for a transition)
        if (!S.isChild && S.floatF > 0 && S.phase !== "open")
            grow(engine._floatMoved(r, engine._floatDelta(r, S.edge, 1)));
        // The swipe-hold contract: while the content's gesture is live, keep
        // at least its hold size, measured from the bar's side.
        const it = S.contentItem;
        if (!S.isChild && it && it.swipeGestureActive === true) {
            const gk = S.ratio > 0 ? S.ratio : 1;       // the content's units (THE RATIOS)
            const hw = (Number(it.gestureHoldWidth) || 0) * gk, hh = (Number(it.gestureHoldHeight) || 0) * gk;
            const cx = (b.x0 + b.x1) / 2, cy = (b.y0 + b.y1) / 2;
            if (S.edge === "top") grow({ x0: cx - hw / 2, y0: b.y0, x1: cx + hw / 2, y1: b.y0 + hh });
            else if (S.edge === "bottom") grow({ x0: cx - hw / 2, y0: b.y1 - hh, x1: cx + hw / 2, y1: b.y1 });
            else if (S.edge === "left") grow({ x0: b.x0, y0: cy - hh / 2, x1: b.x0 + hw, y1: cy + hh / 2 });
            else grow({ x0: b.x1 - hw, y0: cy - hh / 2, x1: b.x1, y1: cy + hh / 2 });
        }
        return r;
    }

    // A bar's box or radius: its thickness moves every popup placed against it
    // (the face, the end insets, the walls), so live popups are re-placed.
    //
    // ONE RELAYOUT A FRAME. A bar's rect arrives in a CASCADE: the shell's bars toggle moves six bars' thickness
    // and the side bars' ends from one clock, and each of those writes is a dozen notifications of this binding --
    // 15 layouts (70 ms of them) in one animation tick, measured, where one is wanted. So a change asks, and the
    // frame's polish (followHook, before the frame is synchronised) lays everything out ONCE with every bar where it
    // now is. The bars' own items are synchronised in that same frame, so nothing is drawn a frame apart.
    readonly property var _barRects: engine.barsList.map(b => b ? [b.absX, b.absY, b.absW, b.absH, b.radius] : null)
    on_BarRectsChanged: engine._requestBarsRelayout()
    onWChanged: engine._relayoutTargets()
    onHChanged: engine._relayoutTargets()
    onMaxRChanged: engine.layout()
    onPopupRatioChanged: engine._relayoutTargets()
    // (a turn later: the bodies' ratios are bindings on the same property and follow it after this handler)
    onPopupScalesChanged: Qt.callLater(engine._relayoutTargets)
    onBarRatioChanged: engine._relayoutTargets()
    onLaneMeltChanged: engine._laneEvent(engine.laneGlideMs, engine.laneGlideEasingIndex)
    onOsdMeltChanged: engine._osdEvent(engine.osdGlideMs, engine.osdGlideEasingIndex)
    onOsdPoseBoxChanged: engine.layout()

    // =====================================================================
    //  The flourish (see the header)
    // =====================================================================

    // { x0, y0, x1, y1 } from a box or a rect { x, y, width, height }; null for
    // anything else.
    function _asBox(v) {
        if (!v)
            return null;
        const n = x => Number(x);
        let b = null;
        if (v.x0 !== undefined)
            b = { x0: n(v.x0), y0: n(v.y0), x1: n(v.x1), y1: n(v.y1) };
        else if (v.width !== undefined)
            b = { x0: n(v.x), y0: n(v.y), x1: n(v.x) + n(v.width), y1: n(v.y) + n(v.height) };
        if (!b || ![b.x0, b.y0, b.x1, b.y1].every(isFinite))
            return null;
        return { x0: Math.min(b.x0, b.x1), y0: Math.min(b.y0, b.y1), x1: Math.max(b.x0, b.x1), y1: Math.max(b.y0, b.y1) };
    }

    // [tl, tr, br, bl] from a number or a list of four (each a number or
    // [rx, ry]); anything else: maxR all round.
    function _asRadii(v) {
        const one = x => {
            if (Array.isArray(x))
                return [Math.max(0, Number(x[0]) || 0), Math.max(0, Number(x[1]) || 0)];
            return Math.max(0, Number(x) || 0);
        };
        if (typeof v === "number" && isFinite(v))
            return [one(v), one(v), one(v), one(v)];
        if (v && v.length === 4)
            return [one(v[0]), one(v[1]), one(v[2]), one(v[3])];
        return [engine.maxR * engine._pr, engine.maxR * engine._pr, engine.maxR * engine._pr, engine.maxR * engine._pr];
    }

    function _sameBox(a, b) {
        return !!a && !!b && a.x0 === b.x0 && a.y0 === b.y0 && a.x1 === b.x1 && a.y1 === b.y1;
    }

    function _sameRadii(a, b) {
        return JSON.stringify(a) === JSON.stringify(b);
    }

    function openFlourish(ownerId, component, box, opts) {
        const b = engine._asBox(box);
        if (!b)
            return false;
        const o = opts || {};
        const F = flourishSlot;
        F.stop();
        F.ownerId = String(ownerId);
        F.t = 1;
        // Drawn from its first frame (the row it replaces is hidden in the same one).
        F.contentOpacity = 1;
        F.component = component || null;
        F.clipFeather = Math.max(0, Number(o.clipFeather) || 0);
        engine._flourishBox = b;
        engine._flourishRadii = engine._asRadii(o.radii);
        engine._flourishHostOwner = o.host !== undefined && o.host !== null ? String(o.host) : "";
        if (o.smoothK !== undefined)
            engine._flourishK = Math.max(0, Number(o.smoothK) || 0);
        engine._flourishCutBar = "";
        F.phase = "open";
        engine.layout();
        return true;
    }

    function setFlourish(box, radii, opts) {
        const F = flourishSlot;
        if (!F.live)
            return;
        const b = box ? (engine._asBox(box) || engine._flourishBox) : engine._flourishBox;
        const r = radii !== undefined && radii !== null ? engine._asRadii(radii) : engine._flourishRadii;
        let changed = !engine._sameBox(b, engine._flourishBox) || !engine._sameRadii(r, engine._flourishRadii);
        const o = opts || {};
        if (o.clipFeather !== undefined) {
            const f = Math.max(0, Number(o.clipFeather) || 0);
            if (f !== F.clipFeather)
                F.clipFeather = f;
        }
        if (o.smoothK !== undefined) {
            const k = Math.max(0, Number(o.smoothK) || 0);
            if (k !== engine._flourishK) {
                engine._flourishK = k;
                changed = true;
            }
        }
        if (!changed)
            return;
        engine._flourishBox = b;
        engine._flourishRadii = r;
        engine._requestFrameLayout();
    }

    function setFlourishGroup(members, k) {
        const list = Array.isArray(members) ? members.map(m => String(m)) : [];
        const kk = k !== undefined && k !== null ? Math.max(0, Number(k) || 0) : engine._flourishK;
        if (JSON.stringify(list) === JSON.stringify(engine._flourishGroup) && kk === engine._flourishK)
            return;
        engine._flourishGroup = list;
        engine._flourishK = kk;
        engine._requestFrameLayout();
    }

    function setFlourishNeck(neck) {
        if (neck === null || neck === undefined) {
            if (engine._flourishNeck === null)
                return;
            engine._flourishNeck = null;
        } else {
            engine._flourishNeck = neck;
        }
        engine._requestFrameLayout();
    }

    function setFlourishCut(barId) {
        const id = barId ? String(barId) : "";
        if (id === engine._flourishCutBar)
            return;
        engine._flourishCutBar = id;
        engine._requestFrameLayout();
    }

    function closeFlourish() {
        const F = flourishSlot;
        if (!F.live)
            return;
        F.stop();
        F.phase = "closed";
        F.component = null;
        F.contentOpacity = 0;
        F.clipOn = false;
        F.clipFeather = 0;
        F.clipLim = Qt.vector4d(-1e6, -1e6, 1e6, 1e6);
        F.popX = 0;
        F.popY = 0;
        engine._flourishBox = null;
        engine._flourishNeck = null;
        engine._flourishHostOwner = "";
        engine._flourishCutBar = "";
        engine.layout();
        engine.flourishClosed();
    }

    // ---- The effects: the ripple and the droplets, on effectTime ---------------

    // A bar's inward axis and face: n the unit direction INTO the bar from its
    // free side, `face` the free face's coordinate along n (so a point is in
    // the bar once its coordinate along n passes it), `along` the face's axis.
    function _barAxis(barId) {
        const info = track.getBarInfoById(barId);
        const b = info ? info.bar : null;
        if (!b)
            return null;
        if (b.edge === "bottom")
            return { nx: 0, ny: 1, face: b.absY, alongX: true, lo: b.absX, hi: b.absX + b.absW, rface: 0 };
        if (b.edge === "top")
            return { nx: 0, ny: -1, face: -(b.absY + b.absH), alongX: true, lo: b.absX, hi: b.absX + b.absW, rface: 1 };
        if (b.edge === "left")
            return { nx: -1, ny: 0, face: -(b.absX + b.absW), alongX: false, lo: b.absY, hi: b.absY + b.absH, rface: 3 };
        return { nx: 1, ny: 0, face: b.absX, alongX: false, lo: b.absY, hi: b.absY + b.absH, rface: 2 };
    }

    // A droplet's centre at effect time t: thrown at t0, falling toward its bar.
    function _dropletAt(d, t) {
        const tau = Math.max(0, t - d.t0);
        const g = 0.5 * d.g * tau * tau;
        return { x: d.x + d.vx * tau + d.nx * g, y: d.y + d.vy * tau + d.ny * g };
    }

    // Its radius now: r, or less while it shrinks out (THE DROPLETS' BUDGET).
    function _dropletR(d) {
        if (d.leave === undefined)
            return d.r;
        const f = 1 - (engine.effectTime - d.leave) / Math.max(0.001, engine.dropletShrinkMs / 1000);
        return d.r * Math.max(0, Math.min(1, f));
    }

    // Its box now (probes read it).
    function dropletBox(d) {
        const c = engine._dropletAt(d, engine.effectTime);
        const r = engine._dropletR(d);
        return { x0: c.x - r, y0: c.y - r, x1: c.x + r, y1: c.y + r };
    }

    // The first tau >= 0 at which a point starting at p along n, moving at v,
    // under g toward the bar, reaches `to`; -1 never.
    function _reachTime(p, v, g, to) {
        const c = p - to;
        if (c >= 0)
            return 0;
        if (g > 0)
            return (-v + Math.sqrt(Math.max(0, v * v - 2 * g * c))) / g;
        return v > 0 ? -c / v : -1;
    }

    function spawnDroplets(barId, list) {
        const ax = engine._barAxis(barId);
        if (!ax || !list || !list.length)
            return 0;
        // THE DROPLETS' BUDGET (header): the reserve stays free.
        const room = field.maxBodies - field.bodyCount - Math.max(0, engine.dropletReserve);
        const add = [];
        for (let i = 0; i < list.length && add.length < room; i++) {
            const e = list[i] || {};
            const d = { id: ++engine._dropletSerial, barId: String(barId), x: Number(e.x) || 0, y: Number(e.y) || 0,
                        vx: Number(e.vx) || 0, vy: Number(e.vy) || 0, r: Math.max(0.5, Number(e.r) || 6),
                        nx: ax.nx, ny: ax.ny, t0: engine.effectTime, g: Number(e.g) > 0 ? Number(e.g) : engine.dropletGravity };
            d.A = e.A !== undefined ? Number(e.A) || 0 : d.r * engine.dropletRippleScale;
            // Its landing: the centre reaching the face, from the ballistic path.
            const p = d.x * ax.nx + d.y * ax.ny, v = d.vx * ax.nx + d.vy * ax.ny;
            const tau = engine._reachTime(p, v, d.g, ax.face);
            d.land = tau >= 0 ? d.t0 + tau : -1;
            add.push(d);
        }
        if (!add.length)
            return 0;
        engine._droplets = engine._droplets.concat(add);
        for (const d of add) {
            if (d.land < 0 || d.A === 0)
                continue;
            const c = engine._dropletAt(d, d.land);
            d.src = engine._addRippleSource(d.barId, ax.alongX ? c.x : c.y, d.A, d.land);
        }
        engine._effectsLive = true;
        engine.layout();
        return add.length;
    }

    // Droplets gone into their bar (a group radius past its face), out of the
    // screen for good, or shrunk out (THE DROPLETS' BUDGET) are dropped: from
    // there they change no pixel.
    function _retireDroplets() {
        if (!engine._droplets.length)
            return;
        const k = Math.max(engine._flourishK, engine._groupK) + 1;
        const keep = [];
        for (const d of engine._droplets) {
            const ax = engine._barAxis(d.barId);
            const c = engine._dropletAt(d, engine.effectTime);
            const deep = ax ? (c.x * ax.nx + c.y * ax.ny) - d.r - ax.face : Infinity;
            const off = c.x + d.r < -k || c.y + d.r < -k || c.x - d.r > track.w + k || c.y - d.r > track.h + k;
            if (deep > k || off || engine.effectTime - d.t0 > 4 || !(engine._dropletR(d) > 0))
                continue;
            keep.push(d);
        }
        if (keep.length !== engine._droplets.length)
            engine._droplets = keep;
    }

    // THE DROPLETS' BUDGET (header), with `room` body indices left for them:
    // droplets past it go at once (a second body inside a shrink), and while
    // fewer than dropletReserve would be left free the last droplets still
    // whole begin to shrink out.
    function _budgetDroplets(room) {
        let list = engine._droplets;
        const n = Math.max(0, room);
        if (list.length > n) {
            for (const d of list.slice(n))
                engine._cancelDropSource(d);
            list = list.slice(0, n);
            engine._droplets = list;
        }
        let short = Math.max(0, engine.dropletReserve) - (n - list.length);
        for (let i = list.length - 1; i >= 0 && short > 0; i--, short--) {
            const d = list[i];
            if (d.leave !== undefined)
                continue;
            d.leave = engine.effectTime;
            engine._cancelDropSource(d);
        }
    }

    // A droplet that leaves before it lands takes its landing's ripple source
    // with it: the source's amplitude 0 (a slot that draws nothing), so no wave
    // comes out of a bar where no droplet fell.
    function _cancelDropSource(d) {
        const i = d.src ? engine._rippleSources.indexOf(d.src) : -1;
        if (i < 0 || !(d.land > engine.effectTime))
            return;
        const list = engine._rippleSources.slice();
        list[i] = { s: d.src.s, t0: d.src.t0, A: 0 };
        engine._rippleSources = list;
        d.src = null;
    }

    // The ripple's globals as the field takes them, and its Tend / fade.
    function _rippleTend() {
        const g = engine._rippleGlobals || {};
        const t = Number(g.Tend);
        return isFinite(t) ? t : Ripple.DEFAULTS.Tend;
    }
    function _rippleFade() {
        const g = engine._rippleGlobals || {};
        const f = Number(g.fade);
        return isFinite(f) ? Math.max(0, f) : Ripple.DEFAULTS.fade;
    }

    // A ripple runs on ONE bar, one at a time, and never beside a body related
    // to that bar's face (_barHeld): refused (false) while one runs anywhere --
    // replacing it would take its waves off in one frame -- and on a bar a body
    // hangs from or reaches.
    function rippleBar(barId, params) {
        const ax = engine._barAxis(barId);
        if (!ax || engine._rippleBarId !== "" || engine._barHeld(String(barId)))
            return false;
        const p = params || {};
        const g = {};
        for (const k in Ripple.DEFAULTS)
            if (p[k] !== undefined && isFinite(Number(p[k])))
                g[k] = Number(p[k]);
        const s = p.s !== undefined && isFinite(Number(p.s)) ? Number(p.s) : (ax.lo + ax.hi) / 2;
        if (g.sb === undefined)
            g.sb = s;
        const A = Number(p.A) || 0;
        engine._rippleBarId = String(barId);
        engine._rippleGlobals = g;
        engine._rippleEpoch = engine.effectTime;
        engine._rippleSources = A !== 0 ? [{ s: s, t0: 0, A: A }] : [];
        engine._effectsLive = true;
        engine.layout();
        return true;
    }

    function addRippleSource(barId, s, A) {
        return engine._addRippleSource(String(barId), Number(s), Number(A), engine.effectTime) !== null;
    }

    // A source landing at effect time `at` (a droplet's is known when it is
    // thrown). A bar that is not rippling starts one with the last globals and
    // no bulge; another bar's ripple, or a held bar (rippleBar), refuses it.
    // Returns the source ({ s, t0, A }: a droplet keeps it to cancel), or null.
    function _addRippleSource(barId, s, A, at) {
        if (!engine._barAxis(barId) || !isFinite(s) || !isFinite(A) || A === 0)
            return null;
        if (engine._rippleBarId !== "" ? engine._rippleBarId !== barId : engine._barHeld(barId))
            return null;
        const t = engine.effectTime - engine._rippleEpoch;
        if (engine._rippleBarId !== barId || !(t < engine._rippleTend())) {
            const g = {};
            const old = engine._rippleGlobals || {};
            for (const k in old)
                g[k] = old[k];
            g.B = 0;
            engine._rippleBarId = barId;
            engine._rippleGlobals = g;
            engine._rippleEpoch = engine.effectTime;
            engine._rippleSources = [];
        }
        if (engine._rippleSources.length >= Ripple.MAX_SOURCES)
            return null;
        const t0 = at - engine._rippleEpoch;
        // Room for it to run, while the window is still whole (a longer window
        // moved under a fade would bring the waves back up).
        const need = t0 + engine.dropletRippleMinS;
        const now = engine.effectTime - engine._rippleEpoch;
        if (need > engine._rippleTend() && now < engine._rippleTend() - engine._rippleFade()) {
            const g = {};
            for (const k in engine._rippleGlobals)
                g[k] = engine._rippleGlobals[k];
            g.Tend = need;
            engine._rippleGlobals = g;
        }
        const src = { s: s, t0: t0, A: A };
        engine._rippleSources = engine._rippleSources.concat([src]);
        engine._effectsLive = true;
        engine.layout();
        return src;
    }

    // A body come to the rippling bar (layout: _barHeld): the ripple fades out
    // over rippleCutMs from the value its window has now (a window already
    // fading faster keeps its value and ends as soon), instead of a join
    // against a moving face. Called every such layout; once cut it is a no-op.
    function _rippleCut() {
        if (engine._rippleBarId === "")
            return;
        const t = engine.effectTime - engine._rippleEpoch;
        const T = engine._rippleTend(), fd = engine._rippleFade();
        const F = Math.max(0.001, engine.rippleCutMs / 1000);
        if (!(t < T) || t + F >= T)
            return;
        const x = fd > 0 ? (t - (T - fd)) / fd : 0;
        const g = {};
        for (const k in engine._rippleGlobals)
            g[k] = engine._rippleGlobals[k];
        g.Tend = t + F;
        g.fade = x > 0 ? F / (1 - x) : F;
        // The layout that found the body pushes it to the field.
        engine._rippleGlobals = g;
    }

    // Is a body related to this bar's face: a slot (the lane included) hanging
    // from it, or any slot's box within snapDistance of its free face across its
    // span (a popup from a perpendicular bar reaching it)? The flourish and the
    // droplets are free: never.
    function _barHeld(barId) {
        const ax = engine._barAxis(barId);
        if (!ax)
            return false;
        for (const S of [slotA, slotB].concat(engine.childPopups, [laneSlot, osdSlot])) {
            if (S.phase === "closed")
                continue;
            if (!S.isChild && S.barId === barId)
                return true;
            const b = S.box;
            if (!b)
                continue;
            const lo = ax.alongX ? b.x0 : b.y0, hi = ax.alongX ? b.x1 : b.y1;
            if (hi <= ax.lo || lo >= ax.hi)
                continue;
            // The box's side nearest the bar, along the bar's inward axis.
            const near = Math.max(b.x0 * ax.nx + b.y0 * ax.ny, b.x1 * ax.nx + b.y1 * ax.ny);
            if (ax.face - near <= engine._snapDistance)
                return true;
        }
        return false;
    }

    // Into the field (inside layout's batch): the rippling bar's index, its
    // face, the globals, the sources and the time -- each only if it changed.
    function _pushRipple(index) {
        if (index < 0) {
            if (field.rippleBody !== -1)
                field.rippleBody = -1;
            return;
        }
        const ax = engine._barAxis(engine._rippleBarId);
        if (field.rippleFace !== ax.rface)
            field.rippleFace = ax.rface;
        if (field.rippleParams !== engine._rippleGlobals)
            field.rippleParams = engine._rippleGlobals;
        const names = ["rippleSource0", "rippleSource1", "rippleSource2"];
        for (let i = 0; i < names.length; i++) {
            const s = engine._rippleSources[i];
            const v = s ? [s.s, s.t0, s.A] : [0, 0, 0];
            const o = field[names[i]];
            if (o.x !== v[0] || o.y !== v[1] || o.z !== v[2] || o.w !== 0)
                field[names[i]] = Qt.vector4d(v[0], v[1], v[2], 0);
        }
        engine._pushRippleTime();
        if (field.rippleBody !== index)
            field.rippleBody = index;
    }

    function _pushRippleTime() {
        const t = engine.effectTime - engine._rippleEpoch;
        if (field.rippleTime !== t)
            field.rippleTime = t;
    }

    // The effects' clock moved: droplets are re-laid out with everything, a
    // ripple alone is its time (GooeyField re-reduces its lanes, no layout).
    function _effectsAt() {
        if (engine._effectsResetting || !engine._effectsLive)
            return;
        let relayout = engine._droplets.length > 0;
        // THE GROUP EASES (header): its k toward its aim, at groupRate (a clock
        // posed backwards moves it by nothing).
        if (engine._groupEasing) {
            const dt = Math.max(0, engine.effectTime - engine._groupT);
            engine._groupT = engine.effectTime;
            const stepK = engine.groupRate * dt;
            const k = engine._groupK, aim = engine._groupAim;
            engine._groupK = k < aim ? Math.min(aim, k + stepK) : Math.max(aim, k - stepK);
            relayout = true;
        }
        if (engine._rippleBarId !== "" && !(engine.effectTime - engine._rippleEpoch < engine._rippleTend())) {
            // Ended: the field has turned it off already (its window is 0 from
            // Tend on); the bar is the bar alone again.
            engine._rippleBarId = "";
            engine._rippleSources = [];
            relayout = true;
        }
        if (relayout)
            engine.layout();
        else if (engine._rippleBarId !== "")
            engine._pushRippleTime();
        if (!engine._droplets.length && engine._rippleBarId === "" && !engine._groupEasing)
            engine._effectsIdle();
    }

    // THE GROUP EASES (header): the members to draw this layout from those drawn
    // and those asked for (`want`, body ids present now; `present`: every body id
    // of this layout), and k's aim; starts the ease on the effects' clock, or
    // ends it. Returns the members.
    function _easeGroup(want, present) {
        const seen = engine._groupSeen;
        const has = (list, id) => list.indexOf(id) >= 0;
        // Gone: out at once. New this layout: in at once.
        let ids = engine._groupIds.filter(id => present[id] !== undefined);
        for (const id of want)
            if (seen[id] === undefined && !has(ids, id))
                ids.push(id);
        // Fewer than two drawn is no group: its k is 0, and at k 0 the members
        // change freely (a group at k 0 draws the bytes of none).
        if (ids.length < 2)
            engine._groupK = 0;
        if (!(engine._groupK > 0))
            ids = want.slice();
        if (ids.length < 2)
            engine._groupK = 0;
        const same = ids.length === want.length && want.every(id => has(ids, id));
        engine._groupAim = same ? engine._flourishK : 0;
        if (ids.length !== engine._groupIds.length || !ids.every(id => has(engine._groupIds, id)))
            engine._groupIds = ids;
        const easing = ids.length >= 2 && engine._groupK !== engine._groupAim;
        if (easing && !engine._groupEasing) {
            engine._groupT = engine.effectTime;
            engine._groupEasing = true;
            engine._effectsLive = true;
        } else if (!easing) {
            engine._groupEasing = false;
        }
        return ids;
    }

    function _effectsIdle() {
        engine._effectsLive = false;
        engine._rippleGlobals = null;
        engine._rippleSources = [];
        engine._effectsResetting = true;
        engine.effectTime = 0;
        engine._rippleEpoch = 0;
        engine._effectsResetting = false;
    }

    onEffectTimeChanged: engine._effectsAt()

    function _requestBarsRelayout() {
        engine._barsDirty = true;
        engine._poke();
    }

    // The screen or a bar changed: settle every live popup on its new place
    // without animating.
    function _relayoutTargets() {
        engine._barsDirty = false;
        engine._layoutStats.relayouts++;
        for (const S of [slotA, slotB, reelSlot]) {
            if (!S.live)
                continue;
            const info = track.getBarInfoById(S.barId);
            if (!info)
                continue;
            engine._placeTargets(S, info, engine._liveOf(S));
            if (S.phase === "open") {
                S.fromBox = S.toBox;
                S.move = null;
            }
        }
        engine._laneRelayout();
        engine._osdRelayout();
        engine.layout();
        // A bar with no area is no body: a lane or OSD that waited for one looks again.
        engine._bodyFreed();
    }

    Component.onCompleted: engine.layout()

    // =====================================================================
    //  The scene
    // =====================================================================
    // THE SHELL'S EDGE (GooeyField): a shadow under everything the
    // surface is -- bars, popups in motion, the flourish's card, droplets, ripples, the lane, the OSD -- and a ring
    // round it, handed to the field as they are (0 is off; the colours are the field's Theme tokens). The shell
    // sets them from shell.jsonc; a host that does not (the mockups) leaves them off, and GOOEY_SHADOW /
    // GOOEY_BORDER in the environment stand in (GooeyField).
    property real shadowReach: 0
    property real shadowStrength: 0.3
    // Its spread (px), softness (0 .. 1), colour and the radius its union of the bodies is smooth over (GooeyField has the meanings);
    // the colours default to the field's Theme tokens.
    property real shadowSpread: 0
    property real shadowSoftness: 1
    property color shadowColor: Theme.shellShadow
    property real shadowBlend: 20
    property real borderWidth: 0
    // What the host says the ring is drawn TIMES: its width on whole compositor px over the configured one (ShellScreen, HyprJoint.ringWidth: the
    // ring's outer edge then lies on a pixel the window's border can start on). 1: the ring as it is configured, as every mockup draws it.
    property real borderFix: 1
    // THE DEVICE EDGE (HyprJoint.edgeFix): per screen edge, the px the field draws that edge's bars thicker by (negative: thinner), at their
    // FACE, so the ring ends on the device px Hyprland starts a window's border on under its own scale (1.25: the reserve's 53.75 is drawn at
    // 54). Only the drawn body moves: the bars' rects, the reserve and everything placed against a bar stay where they are. All 0 (every
    // mockup, any frame at Hyprland's scale 1): the bars are drawn at their own thickness.
    property var edgeFix: ({ top: 0, right: 0, bottom: 0, left: 0 })
    onEdgeFixChanged: engine._requestBarsRelayout()
    property color borderColor: Theme.shellBorder
    // What the field runs its fragment shader on, in px^2, the shape's tiles and the shadow's (GooeyField): the edge's cost, for the probes.
    readonly property real shapeArea: field.shapeArea
    readonly property real shadowArea: field.shadowArea

    // =====================================================================
    //  THE AURA (gooey_field.frag, THE AURA): a colored gradient shadow
    // =====================================================================
    // The halo lit with a few hues flowing round the outline, under large slow noise, for an event the shell picks:
    // brightening in (auraAttackMs), living (the life asked for: waves travelling), fading out (auraReleaseMs). A PROTOTYPE behind
    // a switch the host owns (ShellServices.playAura checks shell.jsonc `shadow.aura`): nothing here plays by itself, and at rest the
    // field is the plain one (auraReach 0, level 0: no tiles of its own, one untaken test in the shadow's branch).
    //   playAura(palette, group, lifeMs)   palette: GooeyAura.PALETTES; group: all | island | side. A play over a play carries on
    //                                      from the level it is at, its waves and noise where they stand; a new palette and a new
    //                                      group ease in over auraAttackMs. False for a word it does not know.
    //   stopAura()                         lets go at once.
    //   releaseAura()                      goes to the way out from the level it is at; nothing when nothing plays or the way out
    //                                      has begun.
    // ONLY THE LEVEL MOVES AT A HAND-OVER (a release, a play over a play: the user's dictation take, its renewal, an event over
    // it). The envelope's clock is moved to where its curve is at the level now, and the PICTURE's time -- the noise's drift and
    // the waves' travel, the shader's auraTime -- is that clock less every move made to it (`_auraSkip`), so it runs on
    // unbroken; the seed is drawn only by a play from nothing, and the waves are counted only then.
    // WITH THE SHADOW OFF the aura is its own halo: the shadow's tiles are made for it alone and its ink is the aura's, and both
    // are gone with it. With the shadow on, the aura lies over the shadow's own ink (the shadow keeps its look underneath).
    // THE ONE CLOCK: `_auraClock` (ms), a single animation that exists only while an aura plays -- the render loop asks for frames
    // because it runs and not otherwise (the shader's time is a uniform, so every frame is a whole-window redraw: that is what the
    // aura costs while it plays and nothing at rest).
    property real auraReachPx: 44
    // The alpha at the surface's edge at the brightest (the envelope scales it).
    property real auraStrength: 0.85
    property int auraAttackMs: 300
    property int auraLifeMs: 2000
    property int auraReleaseMs: 600
    // Wavelengths round the outlines, px: a popup's or the island's, and the screen's. A whole number of them go round (GooeyAura.cycles).
    property real auraWaveIsland: 640
    property real auraWaveFrame: 1100
    // The bars of the island group (the centre island, or the continuous bar); what hangs from them, and from what hangs from them, is the group's too.
    property var auraIslandBars: ["topC", "top"]
    readonly property var auraPalettes: Aura.PALETTES
    readonly property real auraLevel: engine._auraLevel

    property string _auraWord: ""
    property real _auraClock: 0
    property real _auraTotal: 0
    property real _auraLife: 2000
    property real _auraSeed: 0
    // ms the envelope's clock has been moved by hand since the play from nothing (THE ONE CLOCK: the picture's time is the clock less it)
    property real _auraSkip: 0
    property int _auraMode: 0
    // A GROUP HANDED OVER (a play over a play in another group: the dictation take's island group at the press, all of it once the model
    // runs): the ink of each group shown when it came ([the island group's, the rest's], GooeyAura.groupShare), eased to the new group's over
    // auraAttackMs of the picture's time from `_auraGroupAt` -- the rest of the frame fades in while the island's aura runs on, never pops in
    // at full level. Any group to any other, and a hand-over in the middle of one starts from what it shows.
    property var _auraGroupFrom: null
    property real _auraGroupAt: 0
    readonly property real _auraGroupEase: engine._auraGroupFrom === null ? 1
        : Aura.ease((engine._auraT - engine._auraGroupAt) / Math.max(1, engine.auraAttackMs))
    // settled: the mode's own frozen array (GooeyAura.groupShare), the same object every frame
    readonly property var _auraGroups: {
        const to = Aura.groupShare(engine._auraMode), f = engine._auraGroupFrom, e = engine._auraGroupEase;
        return f === null || e >= 1 ? to : [f[0] + (to[0] - f[0]) * e, f[1] + (to[1] - f[1]) * e];
    }
    property var _auraColors: []
    // A palette handed over: the colours shown when it came, eased out over auraAttackMs of the picture's time from `_auraSwapAt`.
    property var _auraColorsFrom: null
    property real _auraSwapAt: 0
    readonly property real _auraT: engine._auraClock - engine._auraSkip
    readonly property real _auraSwap: engine._auraColorsFrom === null ? 1
        : Math.max(0, Math.min(1, (engine._auraT - engine._auraSwapAt) / Math.max(1, engine.auraAttackMs)))
    readonly property var _auraShown: engine._auraSwap >= 1 ? engine._auraColors : Aura.mixColors(engine._auraColorsFrom, engine._auraColors, engine._auraSwap)
    property var _auraCycles: [2, 4, 1]
    // THE JOIN (GooeyAura.joinOf): where the island group's and the chain's loops touch the frame, their free arcs and the frame's
    // coordinate at the junctions (each null: a plain loop); and the whole waves each adds round its arc, counted as it comes (like the cycles).
    property var _auraJoinGeo: ({ a: null, c: null })
    property var _auraExtra: [0, 0]
    readonly property var _auraJoins: [Aura.joinVec(engine._auraJoinGeo.a, engine._auraCycles[0], engine._auraCycles[1], engine._auraExtra[0]),
                                       Aura.joinVec(engine._auraJoinGeo.c, engine._auraCycles[2], engine._auraCycles[1], engine._auraExtra[1])]
    property var _auraBodies: []
    property var _auraChainBodies: []
    property string _auraChainId: ""
    property var _auraRef: null
    readonly property real _auraLevel: engine._auraWord === "" ? 0
        : Aura.level(engine._auraClock, engine.auraAttackMs, engine._auraLife, engine.auraReleaseMs)

    function playAura(palette: string, group: string, lifeMs: int): bool {
        const cols = Aura.paletteOf(palette, Theme.accent);
        const mode = Aura.modeOf(group);
        if (!cols || mode < 0 || !(track.w > 0))
            return false;
        // A play over a play (in any phase, its way out too) does not start from nothing: the envelope's clock goes to where the way
        // in is at the level now, and the picture's time runs on (ONLY THE LEVEL MOVES AT A HAND-OVER).
        const over = engine._auraWord !== "";
        const from = over ? Aura.clockOfLevel(engine._auraLevel, engine.auraAttackMs) : 0;
        // what is on screen now, read before anything is written (a write cascades through the bindings below)
        const shown = engine._auraShown;
        const groupsShown = engine._auraGroups;
        const tNow = engine._auraT;
        auraAnim.stop();
        if (over) {
            engine._auraSkip = from - tNow;
            if (!Aura.sameColors(shown, cols)) {
                engine._auraColorsFrom = shown;
                engine._auraSwapAt = tNow;
            }
            if (mode !== engine._auraMode) {
                engine._auraGroupFrom = groupsShown;
                engine._auraGroupAt = tNow;
            }
        } else {
            engine._auraSeed = Math.random() * 40;
            engine._auraSkip = 0;
            engine._auraColorsFrom = null;
            engine._auraGroupFrom = null;
        }
        engine._auraColors = cols;
        engine._auraMode = mode;
        engine._auraLife = lifeMs > 0 ? lifeMs : engine.auraLifeMs;
        engine._auraTotal = engine.auraAttackMs + engine._auraLife + engine.auraReleaseMs;
        engine._auraClock = from;
        engine._auraWord = String(palette).toLowerCase();
        // the group's bodies for this very frame (a layout is made on a change, and nothing may change while it plays)
        engine.layout();
        // The waves round the loops as they stand when the aura comes, for as long as it plays: a popup that moves meanwhile stretches
        // them, it does not change their count (a count that changes is a jump of every hue, and one that is not whole a step at the
        // outline's start) -- a play over a play keeps them too.
        if (!over) {
            const ref = engine._auraRef;
            engine._auraCycles = [Aura.cycles(Aura.perimeterOf(ref ? ref.a : null), engine.auraWaveIsland), Aura.cycles(Aura.perimeterOf(ref ? ref.b : null), engine.auraWaveFrame), engine._auraCycles[2]];
            const jg = engine._auraJoinGeo;
            engine._auraExtra = [Aura.extraWaves(jg.a, engine._auraCycles[1], engine.auraWaveIsland), Aura.extraWaves(jg.c, engine._auraCycles[1], engine.auraWaveIsland)];
        }
        auraAnim.from = from;
        auraAnim.to = engine._auraTotal;
        auraAnim.duration = Math.max(1, engine._auraTotal - from);
        auraAnim.start();
        return true;
    }

    function stopAura() {
        auraAnim.stop();
        engine._auraEnd();
    }

    function releaseAura() {
        if (engine._auraWord === "")
            return;
        const rel = engine.auraAttackMs + engine._auraLife;
        if (engine._auraClock >= rel)
            return;
        // the way out is smooth(1 - u) over auraReleaseMs: the u whose level is the level now
        const from = rel + engine.auraReleaseMs * (1 - Aura.clockOfLevel(engine._auraLevel, 1));
        auraAnim.stop();
        // the picture's time runs on: the envelope's clock moves, the skip moves with it (ONLY THE LEVEL MOVES AT A HAND-OVER)
        engine._auraSkip += from - engine._auraClock;
        engine._auraClock = from;
        auraAnim.from = from;
        auraAnim.to = engine._auraTotal;
        auraAnim.duration = Math.max(1, engine._auraTotal - from);
        auraAnim.start();
    }

    function _auraEnd() {
        engine._auraWord = "";
        engine._auraClock = 0;
        engine._auraSkip = 0;
        engine._auraColorsFrom = null;
        engine._auraGroupFrom = null;
        engine._auraBodies = [];
        engine._auraChainBodies = [];
        engine._auraChainId = "";
        engine._auraRef = null;
        engine._auraJoinGeo = { a: null, c: null };
        engine._auraExtra = [0, 0];
    }

    // The loops from the bodies layout() made (GooeyAura.groups). Only while it plays. A chain that comes out while it plays counts its waves once, as it comes.
    function _pushAura(bodies) {
        if (engine._auraWord === "")
            return;
        const g = Aura.groups(bodies, engine.auraIslandBars, { w: field.width, h: field.height });
        if (g.chain !== engine._auraChainId) {
            engine._auraChainId = g.chain;
            engine._auraCycles = [engine._auraCycles[0], engine._auraCycles[1], Aura.cycles(Aura.perimeterOf(g.ref.c), engine.auraWaveIsland)];
            engine._auraExtra = [engine._auraExtra[0], Aura.extraWaves(g.join.c, engine._auraCycles[1], engine.auraWaveIsland)];
        }
        engine._auraJoinGeo = g.join;
        engine._auraRef = g.ref;
        engine._auraBodies = g.a;
        engine._auraChainBodies = g.c;
    }

    NumberAnimation {
        id: auraAnim
        target: engine
        property: "_auraClock"
        easing.type: Easing.Linear
        onFinished: engine._auraEnd()
    }

    GooeyField {
        id: field
        anchors.fill: parent
        color: engine.surfaceColor
        auraReach: engine._auraWord !== "" ? engine.auraReachPx : 0
        auraLevel: engine._auraLevel * engine.auraStrength
        auraTime: engine._auraSeed + engine._auraT / 1000
        auraColors: engine._auraShown
        auraGroups: engine._auraGroups
        auraBodies: engine._auraBodies
        auraChainBodies: engine._auraChainBodies
        auraRef: engine._auraRef
        auraCycles: engine._auraCycles
        auraJoins: engine._auraJoins
        shadowReach: engine.shadowReach
        shadowStrength: engine.shadowStrength
        shadowSpread: engine.shadowSpread
        shadowSoftness: engine.shadowSoftness
        shadowColor: engine.shadowColor
        shadowBlend: engine.shadowBlend
        borderWidth: engine.borderWidth * engine.borderFix
        borderColor: engine.borderColor
        tintBlend: engine._tintBlend
        blendRadius: engine._blendRadius
        attachDistance: engine._attachDistance
        snapDistance: engine._snapDistance
        stickiness: engine.stickiness
        stretchMax: engine._stretchMax
        sideStretch: engine.sideStretch
        settleMs: engine.settleMs
        flushSnap: engine._flushSnap
        showTiles: engine.showTiles
        forceSingleTile: engine.forceSingleTile
        shapeTap: reelCastLayer
    }

    // THE VOID CATCHER: below every popup's content and every bar, enabled only
    // while some content asks for the whole track (`maskCatchAll`). It hears only
    // presses nobody above took, and of those only the ones on no body and no
    // bar (_voidPress): a click in empty space while a menu is out dismisses it.
    MouseArea {
        id: voidCatcher
        anchors.fill: parent
        enabled: engine._catching.length > 0
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onPressed: mouse => {
            mouse.accepted = engine._voidPress(mouse.x, mouse.y);
        }
    }

    // Where a parked content lives: in the window, hidden (its effective visibility is false, so what gates itself on `visible`
    // is parked already, and nothing of it is drawn).
    Item {
        id: parkHost
        visible: false
        width: 0
        height: 0
    }

    Item {
        id: hostLayer
        anchors.fill: parent

        Item {
            id: pwStage
            // under everything else of the host layer, in the window's corner; never a target of the pointer
            z: -1000
            x: 0
            y: 0
            width: 1
            height: 1
            enabled: false
            visible: engine._pwItem !== null
            scale: 0.02
            transformOrigin: Item.TopLeft
            opacity: 0.02
            GooeyBody {
                id: pwBody
                engine: engine
            }
        }

        // Primaries above the child: an inset child's overlap belongs to its
        // parent, content and clicks alike.
        GooeyBody {
            id: slotA
            z: 1
            engine: engine
            onFinished: engine._slotFinished(slotA)
            onLoaded: engine._syncSecondary(slotA)
            onContractChanged: engine._syncSecondary(slotA)
            onContentCatch: engine.layout()
            onImplicitSizeChanged: engine._contentResized(slotA)
            onContentLiveResize: engine._contentLiveChanged(slotA)
            onContentLiveMask: engine._contentLiveMaskChanged(slotA)
            onContentShift: engine._contentShifted(slotA)
            onContentTint: engine._pushTints()
        }
        GooeyBody {
            id: slotB
            z: 1
            engine: engine
            onFinished: engine._slotFinished(slotB)
            onLoaded: engine._syncSecondary(slotB)
            onContractChanged: engine._syncSecondary(slotB)
            onContentCatch: engine.layout()
            onImplicitSizeChanged: engine._contentResized(slotB)
            onContentLiveResize: engine._contentLiveChanged(slotB)
            onContentLiveMask: engine._contentLiveMaskChanged(slotB)
            onContentShift: engine._contentShifted(slotB)
            onContentTint: engine._pushTints()
        }
        GooeyBody {
            id: childSlot
            engine: engine
            isChild: true
            onFinished: engine._slotFinished(childSlot)
            onSlid: engine.layout()
            onLoaded: {
                engine._assignKey(childSlot);
                engine._syncSecondary(childSlot);
            }
            onContractChanged: engine._syncSecondary(childSlot)
            onImplicitSizeChanged: engine._contentResized(childSlot)
            onContentTint: engine._pushTints()
            onContentCatch: engine.layout()
        }
        // THE CHILD CHAIN's deeper levels (header). Each below the one before it:
        // an inset child's overlap belongs to its parent, content and clicks alike.
        GooeyBody {
            id: child2Slot
            z: -1
            engine: engine
            isChild: true
            onFinished: engine._slotFinished(child2Slot)
            onSlid: engine.layout()
            onLoaded: {
                engine._assignKey(child2Slot);
                engine._syncSecondary(child2Slot);
            }
            onContractChanged: engine._syncSecondary(child2Slot)
            onImplicitSizeChanged: engine._contentResized(child2Slot)
            onContentTint: engine._pushTints()
            onContentCatch: engine.layout()
        }
        GooeyBody {
            id: child3Slot
            z: -2
            engine: engine
            isChild: true
            onFinished: engine._slotFinished(child3Slot)
            onSlid: engine.layout()
            onLoaded: {
                engine._assignKey(child3Slot);
                engine._syncSecondary(child3Slot);
            }
            onContractChanged: engine._syncSecondary(child3Slot)
            onImplicitSizeChanged: engine._contentResized(child3Slot)
            onContentTint: engine._pushTints()
            onContentCatch: engine.layout()
        }
        // THE LANE (see the header). Never overlaps another slot, so its z only
        // matters for the gesture hand-over, which sits above every body.
        GooeyBody {
            id: laneSlot
            z: 1
            engine: engine
            isLane: true
            onFinished: engine._slotFinished(laneSlot)
            onImplicitSizeChanged: engine._contentResized(laneSlot)
            onContentTint: engine._pushTints()
            onContentGesture: engine._laneGestureChanged()
            onContentCatch: engine.layout()
        }
        // THE REEL PASS (header): the reel group's fill, ring and halo over the popups, between them and the reel slot.
        // (its z is its own: 1.2 while it draws, under everything while it does not)
        ReelCast {
            id: reelCastLayer
            engine: engine
            field: field
        }
        // THE REEL SLOT (see the header): above the primaries, so a strip hanging over a popup is on top of it, content and
        // clicks alike.
        GooeyBody {
            id: reelSlot
            z: 2
            engine: engine
            isReel: true
            onFinished: engine._slotFinished(reelSlot)
            // the strip's content may speak the secondary contract (the tray's label and menus: THE REEL'S CHAIN)
            onLoaded: engine._syncSecondary(reelSlot)
            onContractChanged: engine._syncSecondary(reelSlot)
            onImplicitSizeChanged: engine._contentResized(reelSlot)
            onContentTint: engine._pushTints()
        }
        // THE REEL'S CHAIN (header): above the primaries with its strip, each level below the one before it and the first below the
        // strip (an inset's overlap is its parent's, content and clicks alike).
        GooeyBody {
            id: reelChildSlot
            z: 1.5
            engine: engine
            isChild: true
            onFinished: engine._slotFinished(reelChildSlot)
            onSlid: engine.layout()
            onLoaded: {
                engine._assignKey(reelChildSlot);
                engine._syncSecondary(reelChildSlot);
            }
            onContractChanged: engine._syncSecondary(reelChildSlot)
            onImplicitSizeChanged: engine._contentResized(reelChildSlot)
            onContentTint: engine._pushTints()
            onContentCatch: engine.layout()
        }
        GooeyBody {
            id: reelChild2Slot
            z: 1.4
            engine: engine
            isChild: true
            onFinished: engine._slotFinished(reelChild2Slot)
            onSlid: engine.layout()
            onLoaded: {
                engine._assignKey(reelChild2Slot);
                engine._syncSecondary(reelChild2Slot);
            }
            onContractChanged: engine._syncSecondary(reelChild2Slot)
            onImplicitSizeChanged: engine._contentResized(reelChild2Slot)
            onContentTint: engine._pushTints()
            onContentCatch: engine.layout()
        }
        GooeyBody {
            id: reelChild3Slot
            z: 1.3
            engine: engine
            isChild: true
            onFinished: engine._slotFinished(reelChild3Slot)
            onSlid: engine.layout()
            onLoaded: {
                engine._assignKey(reelChild3Slot);
                engine._syncSecondary(reelChild3Slot);
            }
            onContractChanged: engine._syncSecondary(reelChild3Slot)
            onImplicitSizeChanged: engine._contentResized(reelChild3Slot)
            onContentTint: engine._pushTints()
            onContentCatch: engine.layout()
        }
        // THE OSD SLOT (see the header). It yields to every other slot on every frame
        // (the layout clips it), so its z only matters for the gesture hand-over.
        GooeyBody {
            id: osdSlot
            z: 1
            engine: engine
            isOsd: true
            onFinished: engine._slotFinished(osdSlot)
            onImplicitSizeChanged: engine._contentResized(osdSlot)
            onContentTint: engine._pushTints()
        }
    }

    // THE FLOURISH's host: above every popup's content, below the bars' modules,
    // and deaf -- it takes no pointer event anywhere (it has no input region
    // either: layout pushes no mask rect for it).
    Item {
        id: overLayer
        anchors.fill: parent
        enabled: false

        GooeyBody {
            id: flourishSlot
            engine: engine
            isFlourish: true
            onContentTint: engine._pushTints()
        }
    }

    Item {
        id: barLayer
        anchors.fill: parent
    }

    // THE EFFECTS' CLOCK: one clock for the ripple and the droplets, running only
    // while one of them is live and nobody poses it -- and holding still under a
    // theme crossfade (a still picture of the frame before: waves moving under
    // it are a second copy of themselves).
    FrameAnimation {
        id: effectClock
        running: engine._effectsLive && !engine.effectsPosed && !Theme.crossfading
        onTriggered: engine.effectTime += effectClock.frameTime
    }

    // THE STICKY GESTURE's hand-over (see the header): one area per body,
    // ABOVE every body and the bars and enabled only while that body's content
    // holds a live gesture, so a wheel of the gesture that lands OUTSIDE the
    // owner's clipped body goes to its owner -- where nothing else would hear
    // it, or over ANOTHER body or a bar module, which would otherwise start a
    // gesture of its own and take the event (a view swipe drifting onto the
    // closing detail stepped the detail's day). Inside the owner's own body
    // the event is let through to the content's own readers, all of them: a
    // content may read part of its wheel in a nested reader that
    // gestureWheel() does not reach (the weather popup's daily list scrolls
    // through its own ScrollDressing; routing those too scrolled it one notch
    // per motion).
    Item {
        id: gestureLayer
        anchors.fill: parent

        Repeater {
            model: [slotA, slotB].concat(engine.childPopups, [laneSlot])
            delegate: WheelArea {
                id: handOver
                required property var modelData
                // `var`: the contract's members are the content's own, not QQuickItem's.
                readonly property var content: handOver.modelData ? handOver.modelData.contentItem : null
                anchors.fill: parent
                // NO CURSOR OF ITS OWN: Qt 6.12 gives every MouseArea an Arrow cursor and picks the topmost one under the pointer --
                // disabled or not -- so this layer over the whole window was the shell's cursor everywhere: no hand on any popup's
                // button, and the bridge's free look could not hide the pointer (`qt.quick.hover.cursor`: "setting cursor ArrowCursor
                // from ... handOver", tools/dev/bridge_look_shell_probe.sh). The reset takes it out of the lookup.
                enabled: !!handOver.content && handOver.content.swipeGestureActive === true
                    && typeof handOver.content.gestureWheel === "function"
                turned: wheel => {
                    const body = handOver.modelData;
                    const b = handOver.mapToItem(body, wheel.x, wheel.y);
                    if (b.x >= 0 && b.y >= 0 && b.x < body.width && b.y < body.height) {
                        wheel.accepted = false;
                        return;
                    }
                    const p = handOver.mapToItem(handOver.content, wheel.x, wheel.y);
                    handOver.content.gestureWheel(Object.assign({}, wheel, { x: p.x, y: p.y }));
                    wheel.accepted = true;
                }
            }
        }
    }

    // THE TUCK's hover zone (osdTuckZone): above the bars, so the pointer on a slim bar beside the sliver is over it; no handler of
    // its own (the owner's HoverArm adds a HoverHandler, which blocks nothing under it). No size while nothing is tucked.
    Item {
        id: osdTuckZoneItem
    }

    // THE LIVE FOLLOW'S FRAME HOOK. A positioner lays itself out in the polish
    // phase, before the frame is synchronised, and says so: a follow requested
    // since the last frame (_requestFollow pokes the child) is laid out there,
    // once, and drawn in the same frame as the change that asked for it.
    Row {
        id: followHook
        onPositioningComplete: engine._flushFollow()
        Item {
            id: followPoke
        }
    }

    // The input region's proxies: GooeyMask points one Region at each.
    Item {
        id: maskLayer
        anchors.fill: parent

        Item {
            id: reelMaskProxy
        }

        Repeater {
            model: 16
            delegate: Item {}
            onItemAdded: (index, item) => {
                const a = engine._maskItems.slice();
                a[index] = item;
                engine._maskItems = a;
            }
        }
    }
}
