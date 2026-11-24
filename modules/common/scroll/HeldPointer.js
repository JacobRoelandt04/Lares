.pragma library

// HeldPointer.js -- how a hidden pointer is kept in place: two Lua expressions for Hyprland (`Hyprland.dispatch(expr)` is
// `hl.dispatch(expr)`). The place is read and kept INSIDE the compositor (a Lua global), so no coordinate crosses over and no scale is in it.
//   "hold"           remember where the pointer is (and move it there: nothing)
//   "home"           put it back at the remembered place (with none remembered -- a reload is a fresh Lua state --: where it is)
//   "anchor" dx dy   put it that far from the remembered place (whole logical px)
// tools/dev/side_swipe_env_probe.sh holds them to a nested Hyprland.
function expr(what, dx, dy) {
    if (what === "hold")
        return "(function() LARES_POINTER = hl.get_cursor_pos() return hl.dsp.cursor.move({ x = LARES_POINTER.x, y = LARES_POINTER.y }) end)()";
    var off = what === "anchor" ? [Math.round(dx || 0), Math.round(dy || 0)] : [0, 0];
    return "(function() local p = LARES_POINTER or hl.get_cursor_pos() return hl.dsp.cursor.move({ x = p.x + (" + off[0] + "), y = p.y + (" + off[1] + ") }) end)()";
}
