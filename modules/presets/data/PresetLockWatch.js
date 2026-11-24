.pragma library

// PresetLockWatch.js -- the one fact of the desktop Hyprland announces nowhere: a group's LOCK. Toggling it (hl.dsp.group.lock, one
// group or all) sends no socket2 event and fires no `hl.on` hook (Hyprland 0.57.2, measured nested), and adding a window to a group
// through Lua (`group:add`) sends none either. So while a Presets tab is on show (PresetsService's watch) the shell installs a small
// watcher INSIDE the compositor: a chain of 500 ms one-shot timers that compares every grouped window's address and lock with the last
// look and, on a difference, dispatches `hl.dsp.event(EVENT)` -- socket2 `custom>>lares-presets-lock`, which the service hears like any
// other desktop event. No fork, no clock in the shell.
//
// ONE CHAIN: a start while one runs only renews its lease and keeps its last look, so a lock made just before a renewal is still told
// (a new chain would take the changed state as its baseline and say nothing).
// A LEASE, not a promise to stop: each start gives the chain `LEASE` ticks (120 s); the service renews it while it watches (and after a
// config reload, which is a fresh Lua state: the chain is gone) and stop() ends it at the next tick. A shell that dies leaves at most
// two minutes of a 500 ms look behind. Both are expressions for `Hyprland.dispatch(expr)` (`hl.dispatch(expr)`: an expression that
// returns a dispatcher, HeldPointer.js's way). tools/dev/presets_lockwatch_env_probe.sh holds them to a nested Hyprland.
var EVENT = "lares-presets-lock";
var TICK_MS = 500;
var LEASE = 240;

function start() {
    return "(function() " +
        "local W = LARES_PRESET_LOCKS " +
        "if not W then W = { left = 0, alive = false } LARES_PRESET_LOCKS = W end " +
        "W.left = " + LEASE + " " +
        "if W.alive then return hl.dsp.no_op() end " +
        "local function sig() local s = {} " +
            "for _, w in ipairs(hl.get_windows()) do local g = w.group " +
            "if g then s[#s + 1] = tostring(w.address) .. (g.locked and \"1\" or \"0\") end end " +
            "table.sort(s) return table.concat(s, \" \") end " +
        "W.alive = true " +
        "local okSig, first = pcall(sig) W.sig = okSig and first or \"\" " +
        "local tick " +
        "tick = function() " +
            "local ok = pcall(function() " +
                "W.left = W.left - 1 " +
                "if W.left <= 0 then W.alive = false return end " +
                "local s = sig() " +
                "if s ~= W.sig then W.sig = s hl.dispatch(hl.dsp.event(\"" + EVENT + "\")) end " +
                "W.timer = hl.timer(tick, { timeout = " + TICK_MS + ", type = \"oneshot\" }) " +
            "end) " +
            "if not ok then W.alive = false end " +
        "end " +
        "W.timer = hl.timer(tick, { timeout = " + TICK_MS + ", type = \"oneshot\" }) " +
        "return hl.dsp.no_op() end)()";
}

function stop() {
    return "(function() if LARES_PRESET_LOCKS then LARES_PRESET_LOCKS.left = 0 end return hl.dsp.no_op() end)()";
}
