# How a list expands, collapses and swaps

(The gates, probes and fixtures this contract names without a directory went with the cleanup: tag `pre-cleanup` has them. What a change is proved with now is in `tools/dev/`, [tools.md](../tools.md).)

The shell has four or five lists by now — the update's categories, the LLM's
history, the player's queue and library, the calendar's appointments — and
every one of them has been written with the same bug in it. This is the rule,
written once, in the user's own terms. **Read it before touching a list that
animates.**

## The bug, as it shows up

> I expand a long album. It expands normally for the first 10-12 items and then
> instantly all other entries fly in at the same time, not staggered. I collapse
> the list with as many items in the viewport: the first 10-12 items exit
> correctly and then the remaining items exit instantly.

That is what a naive stagger looks like: every row is given `index * staggerMs`,
so row 40 waits two seconds, and by the time its turn comes the container has
already finished resizing. The rows that were never on screen still "animate" —
into nothing, all at once, at the end.

## The rule

**Only what is on screen animates. Everything below the fold is placed.**

### Expanding

1. Rows enter staggered, from the top, as usual.
2. Keep staggering **as long as the viewport is not yet full**. The moment the
   first row that will land fully off-screen is reached, stop staggering:
   every remaining row appears instantly, below the last on-screen one.
2a. **They appear when the head has finished, not at the start.** This is the
   part that gets written wrong every time:

   > when expanding, the items that are not going to appear entering the
   > viewport since they will be off-screen once the on-screen items have
   > populated the scene, these item they appear instantly. So what happens is
   > I expand a list, instantly see items from the 19th appear, and then see
   > items 1-18 enter the list, pushing down the other items.

   Placing the tail immediately is not "instant", it is *early* — the tail is
   on screen before the head that is supposed to be above it, and then gets
   shoved down by it. The tail belongs below the fold, so it must not be
   visible until the fold is where it will finally be: place it when the last
   staggered row has entered, not when the expansion begins.
3. The list is then already at its full height — the scrollbar, the fade and
   anything anchored to the foot are correct from that instant, not two
   seconds later.
4. **Reassess while it runs.** The user can scroll during the entrance, which
   brings rows that were off-screen into view. On every scroll, recompute
   which row is the last visible one; rows that have come into view before
   their turn keep animating.

### Expanding at the very bottom of the list

> Expanding the last header in the list when scrolled all the way down does not
> follow the opened items. It should follow them to before the point where with
> the next follow the header would go partially off-screen at the top.

A list already scrolled to its end has nowhere to put what opens below the last
header, so the rows appear off screen and the expansion reads as nothing having
happened. Scroll with them — but stop before the header itself would leave:
the header staying visible is what says *this* is the thing you opened.

"Off-screen at the top" is the host's line, not the viewport's edge: a list
with a top fade has its header partly faded well before it leaves, so the line
is the fade's foot (the notification manager's is its 34 px fade less a gap).

A group that arrives WHOLE — its header with its rows, an Undo of a group that
was swiped clear at the foot — is followed the same way, and the header that
must stay is its own. It is the first thing that arrives, with nothing laid out
above it in its section; the thing above THAT is the previous group, far off
the top, and taking it for the header left the view where it was and the
whole group below the fold.

**A list that fits is scrolled all the way down too.** A popup's list is sized
by its rows up to a cap (the notification manager's: min(cap, content)), so with
every group folded the whole list is on screen and is also its own end. Opening
the last group there grows the view to its cap and THEN overflows it — and the
rows that overflow are the ones to follow. Judged against the view's height when
the group opened, the follow rode the first few rows, which only grew the view
(the scroll a view that grows with its content can take is zero until it stops
growing), wrote nothing, and left the header low with rows below the fold —
measured on the manager: the header stayed at 176 with 142 px of room above it,
and the same held for an accordion from a short group and for the Undo of a
group cleared at the foot. So every plan is judged at the height the view will
have when the wave is over: min(cap, the content then). The scroll is still the
rows' own clock, clamped to the content: it stays at the list's end while the
view grows and takes the follow once the view has reached its cap, so the header
rises only while the rows below it are overflowing, and never in a step
(ListWave's `viewMaxHeight`).

### Collapsing

1. Work out what is on screen **first**.
2. Everything below the last on-screen row is removed **instantly**, in the
   same frame — so the next header sits directly under the last visible row,
   exactly as if the collapsing list had only ever contained what you can see.
3. The rows that ARE on screen then exit staggered as usual.
4. Rows ABOVE the fold — the list is scrolled into the middle of the group
   being collapsed — keep their **full height** until the wave has retired,
   and go in one step at the end. They are not below the fold and they may not
   be zeroed early: content above the viewport shrinking moves everything on
   screen up by that much in a single frame, and it does it to the rows that
   are still flying. Measured on the LLM sidebar, four rows above the fold:
   zeroed at the start the visible list is yanked **122.4 px in the first
   frame, 12 ms in, while the wave is in the air**; held, the same 122.1 px is
   spent at 943 ms, when the wave is over and nothing else is moving. The
   update's category section carries the same rule, and measured a 2911 px
   version of it on a 180-row category.
5. No reassessment is needed: nothing new can come into view once the list
   below has already closed up. (At the list's end what comes into view is
   what sits ABOVE the collapse, which is not the wave's: see Collapsing at
   the very bottom of the list.)
6. **What closes up ends on the line, not under the fade.** Clear a group
   scrolled into (the manager's Clear all, a group swiped away) and what is
   below it rises as the cleared rows leave above it, ending where the first
   of them began: at the top of the viewport, under the fade, or with the next
   header partly off the top. So for a collapse the band between the
   viewport's top and the line (the fade's foot, as in Expanding at the very
   bottom) counts as above the fold. A row wholly above the line is held and
   goes in one step with the others at the end. The row across the line
   leaves, and the part of it above the line comes off the scroll *as it
   shrinks*, on its own clock, so what closes up ends exactly on the line and
   nothing steps. Near the list's top there may be less scroll than that
   asks for, and the line never asks for more than there is: what closes up
   ends at the list's own top instead. Asked for anyway, the part the view
   could not give came off in one step when the held rows went (measured:
   78 px asked of a 50 px scroll, and everything on screen jumped 28 px up in
   one frame). The list's own top is where its first row rests with the view
   at the top, which may be ABOVE the viewport's edge: the manager hides its
   first box's bevel slack above the clip, 4 px. There a first row wholly above
   the viewport can be taller than the scroll (58 px on 56), and held — then
   retired at the list's end — it took more off the scroll than there was:
   everything on screen and the popup's foot moved 2 px in one frame before
   the wave began. The line goes as far up as the list's own top instead: that
   row is across it, leaves unseen with the first visible one (it takes no
   stagger step of its own), and lifts what the scroll can give as it shrinks,
   the rest coming off on the same clock.

### Collapsing at the very bottom of the list

A list scrolled to its end has nothing below the fold to close up. What
leaves makes the content shorter, and the view, clamped to the content's end,
is pulled DOWN instead: what is above the leaving rows comes into view from
the top. The rows held above the fold (Collapsing 4) came down with it, on
screen at full height below the fade, and went in one frame when the wave was
over, the next thing above them popping in where they had been. Measured on
the probe's fold of its last open group at the foot: 352 px of held rows came
into view before they went.

So a collapse at the list's end is judged against the viewport the clamp will
END at:

1. How far the view will be pulled: what leaves on screen and below the fold,
   less the content below the fold, less what a swap's new rows bring back,
   never more than the scroll above the viewport.
2. Every held row that pull would bring below the line is placed now. It goes
   in the collapse's own frame and the scroll loses its height in that same
   frame, so nothing on screen moves: it was above the fold and nobody saw it
   go. Walking up from the line, each row placed brings the one above it that
   much closer. A row still landing above the fold, which would be held once
   it lands, is judged the same way.
3. The first held row the pull cannot reach, and everything above it, is held
   as before: nothing brings it into view.
4. What comes into view as the list shortens is then what stays above the
   collapse (the group's header, the list above it). It comes down with the
   list, on the leaving rows' clock, and never in a step.

Mid-list, with content below the fold to close up, nothing is pulled and this
is Collapsing 4 exactly.

### Swapping one list for another (a grouping change, a filter, a new day)

Not "the old rows vanish and the new ones fly in over them". It is a collapse
followed by an expand:

1. Every **visible** row of the old list exits, staggered (the rest are simply
   gone, per Collapsing).
2. The new list's visible rows enter on the SAME clock, rank for rank: the
   first new row sets off with the first old one (the rest are placed, per
   Expanding). A stagger step later, as it used to be, the old rows shrank for
   a step before anything grew, and a list sized by its rows dipped its foot
   and came back — the manager's popup 614 -> 606 -> 614 px at the list's
   end, 288 -> 256 before growing to its cap from a short group. Rank for
   rank, the list's height moves only by what the two lists differ.
3. **The header being opened ends on the line, not under the fade.** The
   swap's collapse is a collapse (Collapsing 6): in an accordion scrolled into
   the old group, the new group's header rises as the old rows leave above it
   and ends on the line. At the list's end, where the old rows are taller
   than the new ones paired with them, the content is shorter for a moment
   and the view is clamped down by the difference; the scroll is held on the
   same formula, so it comes back up as the new rows grow. What the new rows
   bring back is not pulled (Collapsing at the very bottom, 1): an accordion at
   the foot whose new group is at least as tall as what leaves holds the old
   group's rows above the line as usual, and only a shorter one places any.

`modules/clock/calendar/` is the worked example: `AnimatedAppointmentRow` +
`CalendarView`'s `staggerIndex`, where changing the selected day flies the old
day's appointments out and the new day's in.

### Interrupting

A wave can be interrupted: the user collapses a second group while the first
is still emptying, or changes their mind and reopens the one that is leaving.
Both were undefined, and both looked like a fault.

**A second wave may not touch the first one's rows.** The rows already flying
keep the schedule they were given and finish it. What used to happen in the
LLM sidebar is that one shared retirement timer served the whole list, so
starting a second collapse restarted it with an interval sized to the new
(small) wave, and every row still airborne from the first was dropped where it
stood — measured: 9 of 22 rows removed in mid-air, the worst still 30.5 px
tall. The user's word for it was that the list *panics*. So a row carries its
own deadline (when its kick lands, when its flight is over) and a sweeper
retires it on that and on nothing else; the only shared number in a wave is
the one instant a turn-around aims at.

**Reopening a group that is still emptying rewinds it.** In the user's words:

> I think the best solution would be to let all items that have been exited,
> return in reverse order. So if when expanding when still collapsing, and the
> last conversation that exited was for example `write python program`, this
> `write python program` would be the first one appearing at the top of the
> list, followed by the item above it. The list would then continue filling
> like normal.

So the return is the departure played backwards. Rows leave from the top down,
which means the last one to leave is the deepest one that got out; it is the
first one back, and the rows above it follow in reverse, each landing above the
one before and pushing it down. A row whose turn had **not** come never moved
and is simply not leaving any more — it stays exactly where it stands, at full
height, and the rewind lands above it. When the rewind is done the ordinary
entrance takes over and fills the rest of the viewport from there, staggered as
usual, with everything past the fold placed.

**Collapsing a group that is still filling is the same rule, forwards.** The
rows that made it in exit as an ordinary collapse of just those rows. Nothing
that had not yet arrived arrives first: a row still off-screen left is dropped
in that same frame, because it was never seen. And a row in flight is **not**
flipped where it is — it lands first. Flipping it mid-entrance snaps it back to
x = 0 at full height in one frame: measured 30.5 px of height and 340 px of x,
against 6.0 px and 67.3 px for one step of the ease.

**Both wait a beat before they start.** Again in the user's words:

> To add some extra tacktility a slight delay when triggering this edgecase
> should be added, letting all items that started exiting finish their
> animation, to then let these items that just departed, come back again from
> the left. ... For both scenarios this delay should be very small, since we
> dont want to wait too long, but just enough for visual clarity.

The delay is the remaining flight time of the rows already in the air, not a
fixed number picked by feel: a row that has just started gets to land, and an
interruption that arrives when nothing is moving costs nothing. It needs no cap
either — because the rows that had not started are cancelled rather than flown,
the longest anything can still be in the air is ONE row's flight, however deep
the wave was.

**The turn happens at the row's own deadline, and the whole turned wave aims at
one instant.** Each row is flipped when its own flight ends — off-screen, at
zero height, so the flip itself is invisible whichever way it goes — and it
then waits out what remains until the shared instant before its own rank in the
new wave applies. That is `AnimatedListRow.startDelayMs`: one number per row on
top of `staggerIdx * staggerMs`, so the return's order is the WAVE's and not
the order the rows happened to land in. Give every row the same delay (or
none) and the whole rewind fires as one block — measured, with the head start
removed: five rows returning over 17 ms instead of 160.

### A row that holds rows (the notification manager's open bundle)

> The staggered exit animation on the items in a category breaks when a group of
> notifications are expanded ... the other 5 that were in view were all kitty
> claude code that I expanded from being grouped. This made the enter/exit
> animations of these kitty notifs happen in parallel rather than staggered.

The stagger is per CARD, not per entry. An app's bundle, unfolded, was one row of
the wave with its members riding inside it on a clock of their own, so an
accordion or a Clear all flew five cards as one block (measured: five cards set
off in the same frame, 44 ms in; after: 47, 90, 140, 191, 256, 307). Every card
that is on the list is a row of the wave: the head's slot is the wave's row for
the head, and each member is a row of its own that lives in the TAIL of that
slot (`ManagerSlot.tailHost`): the slot's `implicitHeight` / `_fullHeight` --
what ListWave reads -- are the head's alone, its layout `height` is the head plus
the tail, and the tail holds still while the head slides. The host hands the
wave the head and its members together, in layout order (`GroupSection`'s
`_pushOut` / `_pushIn` / `rowItems`); nothing in ListWave knows about bundles
except two things a row inside a row needs: `_slotTop` follows a zero-height row
through a parent that is no positioner (the tail), and a row may name what it
opens under (`waveKeep`, a first member opens under its head) and the line that
header may rise to (`waveTopPx`, a card has no gap above it).

**A bundle's own unfold and fold are the same wave.** The user's answer to "a
bundle unfolded at the list's foot: follow it like a group?" was yes. Opening a
bundle hands its new members (born collapsed) to `expand`: the ones on screen
fly in on the stagger, the tail below the fold is placed when the head has
landed, and the view follows them at the foot, stopping before the head card
would pass under the top fade. Folding hands them to `collapse`. The bundle had a
clock of its own for this (`memberMs`, the panel's "bundle ms"): it is gone, a
member that arrives because a record joined an open bundle takes the row
arrival's clock (`arriveMs`) like any other new row.

An entry whose head has collapsed goes only when its members have: the head is
the first row of the wave to land, and dropping the entry then took the members
still in the air with it.

### The moving edge is fog (ManagerSlot)

> The fog fade that appears when sliding a notification either side is not
> present when expanding or collapsing a header: the notifs get a harsh cutoff
> line instead.

A row that grows or shrinks keeps its content at full size and only shows the top
`implicitHeight` of it. What was below that edge was cut by whatever lay over it
-- the next row's top, a hard line across the card. The row now clips its content
to the height it shows and dissolves the last 34 px (the side cut's long ramp)
into the ground with a `SeamFade` at that edge: the same fog the sideways cut
has, for every way a row's height moves (the wave's extent, an arrival's grow, a
flight's reveal). At rest the clip is off and the band is invisible, so a resting
list is what it was byte for byte.

## What "on screen" means

The viewport is the Flickable, not the item's own height. A row is on screen
when its slot intersects `[contentY, contentY + height]`, and it is worth
allowing a row's worth of margin either side so a row that is one pixel below
the fold does not read as a popped-in row — except at the top of a collapse,
where a row wholly above the viewport is above the fold even inside that
margin and is held with the rest (Collapsing 4): nobody can see it leave, and
flown out, its height would go from above the viewport while the wave is in
the air, which in an accordion leaves the next header one row above the
viewport.

The count is therefore `ceil(viewport height / row height) + 1` in the simple
case, and a real measurement (`row.y` against the Flickable) in a list whose
rows differ in height — a header, a song, an expanded album.

## Why it is worth the trouble

The stagger exists to say *these arrived together, in this order*. Past the
fold it says nothing at all, because nobody is looking; all it does is hold the
container's height wrong for as long as it runs, which is what makes the rest
of the list jump when it finishes. Cutting it off at the fold costs nothing
visible and fixes the jump.

## Where this already lives

- `modules/notifications/ListWave.qml` (+ `ListWave.js`, the arithmetic,
  node-tested) — all of this page as one component over AnimatedListRows: the
  bands, the per-row deadlines, the turn-around, the follow at the foot, the
  anchoring of held rows, the line a collapse or a swap ends on, and the
  list's end. The notification manager is its host.
  `list_wave_probe.sh` checks every rule frame by frame, with an
  arm per rule (`ARM=all`), and `BEFORE=<rev>` runs the same probe on an older
  ListWave. A view that grows with its content is `viewMaxHeight` (W24-W28 in
  the probe, from every start height the manager has shown the fault at).
- `modules/common/components/AnimatedListRow.qml` — the row states
  (`rest` / `entering` / `leaving` / `collapsed`), `staggerIdx`, `staggerMs`,
  `startDelayMs`. It animates what it is told to; the decision of WHO animates
  is the list's.
- `modules/bar/llm/components/LlmSidebar.qml` — the worked example of all of
  it in one merge: the three bands (`_bandOf`), the per-row deadlines and the
  sweeper (`_retire`), and the turn-around (`_revive` / `_turn`).
  `llm_sidebar_collapse_probe_run.sh` drives real collapses and a pure
  expansion on a seeded history (seeded inside TODAY: seeded a minute per row
  back from now, it lost rows to yesterday in the first 21 minutes after
  midnight and went red on a sidebar that was right) and asserts every rule on
  this page frame by frame, with an arm for each one (`early` is the tail placed before the head
  lands on an expansion -- the bug the sidebar shipped with until round 3 of
  the networking module found it).
- `modules/bar/system_update/components/UpdateCategorySection.qml` — `_animRange` and
  `_close`, where the three bands were first measured.
- `modules/clock/calendar/AnimatedAppointmentRow.qml` — the same idea with an
  explicit kick timer, and the reference for the swap.
- `modules/common/components/SelectionAutoScroll.qml` — keeping a row in view
  while the list moves under it.
