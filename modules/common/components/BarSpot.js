.pragma library

// =============================================================================
// BarSpot.js -- where a stack stands on the bars: the place a `spot` names.
// The notification lane and the OSD place their stack by this one rule.
//
// `bars` is the engine's `barsList` ({ barId, edge, rawPos, rawLen, ... }).
// Returns { barId, local, alongAt, corner2D, corner, key }, or null when no bar
// serves the spot.
// =============================================================================

// THE SPOT. A screen corner -- `{ corner: "top-right" }`, the edge first:
// the stack at the end of the bar on that edge that reaches furthest toward
// the corner, opening out of it -- or a point along a bar -- `{ bar: <id>,
// along: 0..1 }`, from the bar's start on the SCREEN (its left or top end).
// One rule places both: the point at `along` of the bar is the point at
// `along` of the stack (a corner is along 0 or 1 of its bar), so the stack
// never leaves its bar, and as a toast more grows it, it grows away from
// that point in proportion -- away from a corner, both ways about a
// middle. The engine keeps that point as the size changes (openLane's
// alongAt): an along centre computed from the stack's size is wrong the
// moment the size changes, and on a side bar -- where the stack's length
// along the bar IS its height -- from the first toast. The track runs against the screen on
// the bottom and left edges, so there the fraction is turned round. A bar
// the config names that is not there, or a corner that is not one, falls
// back to the default corner; a corner with no bar on its edge has no lane.

function placeOf(spot, bars) {
    if (!bars || !bars.length)
        return null;
    let bar = null, f = 0.5, corner = "";
    if (spot && spot.bar !== undefined && spot.bar !== null) {
        bar = bars.find(b => !!b && b.barId === String(spot.bar)) || null;
        const a = Number(spot.along);
        f = isFinite(a) ? Math.max(0, Math.min(1, a)) : 0.5;
    }
    if (!bar) {
        corner = spot && /^(top-(left|right)|bottom-(left|right)|left-(top|bottom)|right-(top|bottom))$/.test(String(spot.corner))
            ? String(spot.corner) : "top-right";
        const edge = corner.split("-")[0], far = /-(right|bottom)$/.test(corner);
        // The bar on that edge reaching furthest toward the corner.
        const reach = b => far ? b.rawPos + b.rawLen : -b.rawPos;
        for (const b of bars)
            if (b && b.edge === edge && (!bar || reach(b) > reach(bar)))
                bar = b;
        if (!bar)
            return null;
        f = far ? 1 : 0;
    }
    const g = bar.edge === "bottom" || bar.edge === "left" ? 1 - f : f;
    return { barId: bar.barId, local: g * bar.rawLen, alongAt: g, corner2D: corner !== "", corner: corner,
             key: bar.barId + "@" + g + ":" + bar.rawLen + (corner !== "" ? "/2d" : "") };
}
