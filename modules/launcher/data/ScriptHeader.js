.pragma library

// =============================================================================
// ScriptHeader.js -- what a launcher script says about itself. Pure.
//
//   parse(text, fileName) -> { name, icon, terminal, description, hasHeader }
//
// A script in the launcher's scripts root may describe itself in comment
// lines among its first MAX_LINES lines:
//
//   #!/bin/sh
//   # name: Sync photos
//   # icon: folder-pictures          (a theme icon name, for the icon bake)
//   # terminal: yes                  (run it in kitty)
//   # description: rsync to the NAS
//
// Keys are case-insensitive, the first line of each key wins, anything else
// is ignored (a shebang, ordinary comments, code). `terminal` is true for
// yes / true / on / 1. With no `name:` the name is the file name without its
// extension ("backup.sh" -> "backup"; a name with no dot, or a dotfile, is
// kept whole).
// =============================================================================

var MAX_LINES = 20;
var _KEY = /^\s*#+\s*(name|icon|terminal|description)\s*:\s*(.*?)\s*$/i;

function fallbackName(fileName) {
    const f = String(fileName || "");
    const dot = f.lastIndexOf(".");
    return dot > 0 ? f.substring(0, dot) : f;
}

function isYes(v) {
    return /^(yes|true|on|1)$/i.test(String(v || "").trim());
}

function parse(text, fileName) {
    const out = {
        name: "",
        icon: "",
        terminal: false,
        description: "",
        hasHeader: false
    };
    const seen = {};
    const lines = String(text || "").split("\n");
    const n = Math.min(lines.length, MAX_LINES);
    for (let i = 0; i < n; i++) {
        const m = _KEY.exec(lines[i].replace(/\r$/, ""));
        if (!m)
            continue;
        const k = m[1].toLowerCase();
        if (seen[k] === true)
            continue;
        seen[k] = true;
        out.hasHeader = true;
        if (k === "terminal")
            out.terminal = isYes(m[2]);
        else
            out[k] = m[2];
    }
    if (out.name.length === 0)
        out.name = fallbackName(fileName);
    return out;
}
