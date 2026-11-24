# Two-finger gestures, and why they are always written wrong

(The gates, probes and fixtures this contract names without a directory went with the cleanup: tag `pre-cleanup` has them. What a change is proved with now is in `tools/dev/`, [tools.md](../tools.md).)

Every module that wanted a two-finger swipe has had it written wrong first —
the tab selector, the calendar, the power reel. Always the same three
mistakes, so this is the rule, written once. **Read it before adding a swipe
to anything.**

## 1. A two-finger swipe is a WHEEL. It is not a drag.

There is no touch event, no `DragHandler`, no `PointerHandler` for it. libinput
turns two fingers on a touchpad into scroll, Qt delivers it as
`QWheelEvent`, and it arrives on **the axis the fingers moved on**:

| the gesture | what arrives (Qt 6.12, Hyprland 0.57.2; recorded) |
|---|---|
| two fingers down / up, left / right | `angleDelta` 12 x `pixelDelta` on the axis they moved on, phase `ScrollUpdate`; a zero event `ScrollBegin` before, a zero event `ScrollEnd` after |
| a mouse wheel notch | `angleDelta.y == +-120` **and `pixelDelta.y == +-15`**, phase `NoScrollPhase` |
| a high-resolution wheel | smaller pieces of the same, many events |

So a horizontal swipe is a **horizontal wheel**, and a component that only
reads `angleDelta.y` is a component that cannot be swiped sideways.

**"It has pixels" does not say touchpad** (it did before Qt 6.12). The scroll
PHASE does, and nobody reads it himself: **`WheelArea`** (section 2) hands every
event on NORMALISED by `WheelHub.read`:

| field | what it is |
|---|---|
| `device` | `"wheel"` (a mouse), `"touch"` (fingers), `"swipe"` (a side button held, section 6) |
| `pixelDelta` | `(0, 0)` for a mouse, so "pixels = fingers" is true again in every reader |
| `notches` | the whole notches this event completed, per axis, signed as the angle (a high-resolution wheel's pieces add up) |
| `steps` | the same as steps to the NEXT one: `+` rolled down, tilted right, a side button's notch down; `-` the previous |
| `click` | made by a click of a side button: a reader whose step destroys something leaves those alone (a toast's verbs) |
| `accepted` | what the reader writes; `false` passes the event on |

**A mouse's notch is ONE STEP**, whatever a swipe's threshold and cooldown are:
`SwipeSteps.notch(n)`, `TabSelector.applySteps(n)`, `IconReel.notch(n)`,
`WheelStepper.feed(120 * n, false)`. Never feed a notch into a detent that
counts fingers.

**What a mouse reaches with no gesture at all** (the user's rule, 2026-11-22):
an upright notch over the CONTROL itself steps it (a tab row, a view's dots, a
strip of days, a month, a reel, the workspaces, a board's part); anywhere else
in the popup a side button held while the wheel turns is one step sideways;
elsewhere a plain notch scrolls what scrolls.

## 2. Use a `WheelArea`. Never a MouseArea's `onWheel`, never a WheelHandler.

```qml
import "../common/scroll"

// Takes no buttons, decides no cursor. Passes the event on unless it keeps it.
WheelArea {
    anchors.fill: parent
    turned: ev => {
        ev.accepted = false;                        // the lists under it still need theirs
        if (ev.device === "wheel") {                // a mouse
            if (ev.angleDelta.x !== 0)
                tabs.applySteps(ev.steps);          // a sideways notch: one step
            return;
        }
        const a = horizontal ? ev.angleDelta.x : ev.angleDelta.y;
        if (a === 0) endGesture(); else applySwipe(a);
    }
}
```

`turned` is a FUNCTION property, not a signal: an object handed through a QML
signal is a copy, and the `accepted` a handler writes on it is lost.
`tools/dev/wheel_readers_check.py` (quick tier) fails a bare reader.

Why not the others, each of which has cost a round:

- **`WheelHandler.orientation` defaults to `Qt.Vertical`.** It filters by axis,
  and a horizontal swipe never reaches it at all. This is what stopped the
  power reel on the vertical bar from being swipeable, and nothing about it is
  visible in a render.
- **A `WheelHandler` is shadowed** by any scrolling handler that happens to sit
  deeper in the scene. That is what stopped `TabSelector` working once it lived
  inside a popup full of lists.
- **A bare `onWheel`** reads a mouse as fingers, and a side-button swipe does
  not reach it.

**A wheel event's deltas are in the DEVICE's axes and are not rotated with the
item.** Anything inside a `GooeyBar` is drawn in the bar's own rotated frame, so
a module on a left bar is horizontal on screen while its layout is "vertical".
Choose the axis by where the strip is ON SCREEN, not by its local frame
(`IconReelView.screenVertical`).

## 3. A zero-delta wheel event is the fingers LIFTING.

libinput sends a scroll-end and Qt forwards it as a wheel event carrying no
movement. That, not a timeout, is what should release a rubber band. A timeout
springs the band back a second into a gesture the user is still making; a
timeout long enough not to do that leaves the band stranded when the device
never sends the end. Handle the zero **and** keep a long timeout as a fallback
only (`TabSelector.swipeIdleResetMs`, `IconReelStyle.swipeIdleResetMs`: 6000).

## 4. A gesture is STICKY, and the host routes it to its owner.

A swipe that switches to a smaller view shrinks the popup under the fingers, so
the pointer often ends up outside it while the fingers are still down. The
gesture must keep going until they lift: the content grows its swipe area to
the hold rect (`swipeGestureActive`, `gestureHoldWidth`/`Height`) and the host
keeps its input mask at least that big.

That is not enough when the host CLIPS the content (`GooeyBody` is
`clip: true`, and so is the weather mockup's body). A clipped item delivers no
pointer event to a child outside its rect -- Qt prunes delivery at the clip --
and `containmentMask` does not lift that (probed). So the grown swipe area is
deaf exactly where it was grown. And a wheel that lands on ANOTHER body (a
view swipe drifting onto the closing detail) is read by that body's content,
which starts a gesture of its own and takes the event.

So the HOST routes the gesture. A content that holds gestures exposes

```qml
function gestureWheel(ev)   // ev = {x, y, angleDelta, pixelDelta}, content coords
```

(returning false when no gesture is held), and while its `swipeGestureActive`
is true the host puts a wheel-only `MouseArea` ABOVE every body and every bar
module that hands it every wheel landing OUTSIDE its body -- over nothing, or
over any other body -- and lets the ones INSIDE its body through
(`wheel.accepted = false`) to the content's own readers. Not "every wheel":
a content may read part of its wheel in a nested reader `gestureWheel` does
not reach (the weather popup's daily list scrolls through its own
ScrollDressing), and round 4's router, which took those too, scrolled the list
one notch per motion. The area is enabled only while the gesture lives, so the
first wheel of a gesture still reaches the owner's own reader, which is what
picks the owner. `GooeyEngine`'s `gestureLayer` does this for
every slot, the weather mockup's `gestureRouter` for the popup and the detail;
`WeatherPopup.gestureWheel` and `WeatherDetail.gestureWheel` are the content
side. `test_gooey_engine_probe.qml`'s `sticky` checks prove it with real wheels
through the window, and fail with the area pushed under the bodies.

## 5. A mouse has no lift: its commit ENDS the gesture.

§3's lift comes from a touchpad. A mouse's tilt wheel (a notch: whole angle,
no pixel delta) never sends one, so a reader that holds its gesture "until the
lift" holds a mouse gesture until its idle fallback -- and everything a host
holds for fingers that are down is held with it. `SwipeVerbReader` did: a
notch that deleted the last toast kept `active` (the toast's
`swipeGestureActive`) true for `mouseIdleMs`, and the engine held the lane's
close for 400 ms over a popup whose content was already emptying (R2E I3.1).

So the reader tells the two apart by what the gesture CARRIED: a gesture that
never had a pixel delta (normalised: section 1) is a mouse's, and its commit ends it -- `active` falls
BEFORE the card commits, so whatever the commit sets off (the lane's close)
finds nothing held. The rest of that tilt is still one card's: a tilt wheel
repeats while it is held, so the reader stays SPENT -- swallowing further
sideways notches -- until `mouseIdleMs` passes without one; a vertical wheel
or a pixel-carrying event is a new gesture and goes through at once. A
touchpad's commit holds until the lift, as §4 needs (the next row slides up
under the fingers and must not move). `swipe_verb_probe.sh`'s
`notch (mouse)` checks are the gate; `ARM=notchhold` puts the old hold back
and fails them.

A mouse can also SCRUB: a hi-res or thumb wheel sends angle in pieces smaller
than a notch, so a card can be pushed past its line without a notch or the
pull-through, and then the idle fallback is its "lift" -- the release that
commits it. That release comes after the gesture has ended, not inside it:
the reader drops `active` first, as for a notch, so every way a mouse commits
a card finds nothing held (a first version released first and cleared the
flag last, and the lane's close met a live gesture inside the commit).
`idle release (mouse)` is the check, `ARM=idlehold` the fault.

## 6. The mouse's side buttons are the two fingers it has not got.

`SideSwipe` (one per window, above everything in it; `MockupStage` has one too)
hears the Back and Forward buttons:

- **held + moved** (5 px): the readers under the PRESS get the events fingers
  make -- a zero `ScrollBegin`, updates with the hand's way as pixels and 12 x
  the angle, a zero `ScrollEnd` at the release -- so every gesture in the shell
  follows it, leans, coasts and springs back with nothing of its own. The
  content follows the hand; `inverted` is true on them (a reader of the hand's
  own direction, the volume, turns them as it turns natural scrolling).
- The chain of readers is taken ONCE, at the press, in the order Qt would offer
  them a wheel (`WheelHub.chainAt`: z, then declaration, children over parents,
  clips cut), and kept for the gesture: a popup that shrinks under the swipe
  changes nothing (section 4's hold is the touchpad's problem).
- **held + the wheel**: `WheelHub.read` turns the notch sideways (down = the
  next), and the press is then neither a click nor a drag.
- **a click**: one sideways notch, Back = the previous, Forward = the next.
- **The pointer** is hidden meanwhile and stays where it was: the host keeps it
  at the press (`HeldPointer.js`, Lua inside Hyprland, the bridge's free look
  uses it too) and puts it back when it has strayed 140 px and at the end. The
  jump home is no motion of the hand; what the pointer is off its start when
  the jump is seen IS. Nothing under the window's `CursorCover` can hide the
  pointer, so the cover follows `SideSwipe.hiding`.

`shell.jsonc` `"input"` has the switches (`sideButtons`, `sideClick`,
`sideGain`, `sidePointer`) and the notch's length in a list. Proved by
`tools/dev/side_swipe_probe.sh` (offscreen) and `side_swipe_env_probe.sh` (a
nested Hyprland: real notches, fingers and side buttons).

## The shape of the thing

`SwipeSteps` (`modules/common/components/`) is the reference implementation: the
shell's ONE sticky swipe, behind the tab selector's pill and the workspaces' ball
(`IconReel.applySwipe()` is the same machinery still written out in different
units). A host reads the wheel with its own MouseArea, picks the axis, and feeds
the units on it -- `swipe.feed(dx)`, `swipe.feed(0)` for the lift -- and takes
`stepped(dir, to)` and `pull` (the lean, in positions) back. The shape, so that a
new host knows what it is getting:

- **Accumulate against a threshold.** ~800–1000 wheel units per step. A swipe is
  thousands of units; the natural failure mode is a flick of a few millimetres
  skipping two items.
- **Give, with a taper.** `1 - (1 - t)^k` — most of the travel early, then
  resistance, so what is left of the gesture reads as effort. Saturate the give
  below half a slot: it must never complete a step by itself, or the detent has
  nothing left to snap.
- **Momentum.** Above ~2600 units/second a swipe keeps its remainder and skips
  the cooldown, so a flick carries through the middle of a list instead of
  stalling on it.
- **Cooldown.** ~320 ms between committed steps otherwise, so one long slow
  swipe steps once at a time.
- **A mouse's notch is one item** at once, whatever the threshold and the
  cooldown say (section 1).
- **A host that answers late is counted from where it was told to go.** The
  workspaces change in the compositor, which says so a few milliseconds later: a
  flick that steps three times in that gap must order three different workspaces,
  not the first one three times (`SwipeSteps._ordered`, which a release does not
  forget -- a flick released at the end of the list is released while the host is
  still answering).
- **A two-finger scroll is never one axis**: a vertical read arrives with a few
  degrees of x. The workspaces' reader picks the axis once one leads by 1.2x and
  keeps it until the lift (`Workspaces._swipeWheel`), so a vertical scroll over the
  strip does not creep the ball; the tab selector's own reader feeds its axis
  unlatched (its hosts latch it themselves).

Where a swipe steps something with no rubber band (a card's views, the weather
detail's days), the detent is `WheelStepper` (`modules/common/components/`):
a notch threshold for a mouse, a touchpad threshold for any event that carries
a pixel delta, a step cooldown (the fingers' alone), and `end()` on
the lift. One counter; `CardViewCycler`, `WeatherDetail` and the clock's
duration fields (`MinuteField`) feed it -- the fields had their own counter
with no rest, and at 150 and then 500 units a minute it still ran away.

## Proving it

Synthetic input must go through what would steal it. QtTest makes a MOUSE's
wheel (whole notches of angle, no pixels, no phase) through the window:

```qml
TestCase { id: tc; name: "..."; when: false }
tc.mouseWheel(win.contentItem, x, y, 0, -120);
```

It cannot make FINGERS. Those go along the readers under the point, as Qt would
offer them:

```qml
WheelHub.deliver(WheelHub.chainAt(root, x, y), root, x, y, WheelHub.fingers(px, py, Qt.ScrollUpdate));
WheelHub.deliver(..., WheelHub.fingers(0, 0, Qt.ScrollEnd));      // the lift
```

or a real side-button drag (`tc.mousePress(.., Qt.BackButton)`, moves, release)
where a `SideSwipe` is over the stage; a real compositor's fingers are
`tools/dev/lock_env.sh point "finger DX DY"` / `"lift"` / `"notch N"` /
`"side back down"`.

**Use a DIAGONAL delta.** With a pure horizontal one the check passes even with
the axis wrong, because a sane handler falls back to the other axis when its
main one is empty — and a real two-finger swipe is never perfectly straight
either.
