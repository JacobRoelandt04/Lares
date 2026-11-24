.pragma library

// RemapRule.js -- when ShellScreen's rise watch may remap its window (pure; node-tested: tools/dev/shell_remap_cases.js).
// A remap deletes the layer surface's QQuickWindow and builds a new one, so it is the last resort: a missing frame first gets ONE
// request for a frame, and a window that was just remapped is left alone for a cool-down.

// "ask" the window for a frame | "remap" it | "skip" (a frame was asked for and did not come, but a remap happened `cooldownMs` ago).
function decide(asked, sinceRemapMs, cooldownMs) {
    if (!asked)
        return "ask";
    return sinceRemapMs >= cooldownMs ? "remap" : "skip";
}
