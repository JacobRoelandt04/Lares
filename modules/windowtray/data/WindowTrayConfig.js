.pragma library

// =============================================================================
// WindowTrayConfig.js -- windowtray.jsonc merged over the code's defaults, pure
// and node-testable.
//
//   defaultConfig()  -> the config of a missing file
//   merge(obj)       -> { config, warnings }
//
// Every key is optional. A value of the wrong type takes the default and says so
// in `warnings`; an entry of a list that cannot work (a regex that does not
// compile) is dropped and says so. Nothing here throws.
//
// THE TERMINALS. A shell's integration sets the window's title to the command it
// is about to run and back to the directory when it ends, so `ls` flashes
// "~ -> ls -> ~" across the bar (executing `ls` does not
// flash the title). A title change of a window whose class is in `terminalClasses`
// is held `terminalTitleMs` before it shows, and a change back within it never
// shows (ActiveWindowState). The list is the classes of the usual terminals, kitty
// first; a class is matched whole and without regard to case.
// =============================================================================

// The window classes of the usual terminal emulators, kitty (the user's) first.
var TERMINALS = ["kitty", "Alacritty", "foot", "footclient", "org.wezfurlong.wezterm", "com.mitchellh.ghostty",
                 "org.kde.konsole", "konsole", "XTerm", "URxvt", "st-256color", "terminator", "com.gexperts.Tilix",
                 "gnome-terminal-server", "org.gnome.Terminal", "org.gnome.Ptyxis", "xfce4-terminal", "rio",
                 "cool-retro-term"];
// How long a terminal's title change waits (ms), by default: more than a prompt takes to come back after a quick command
// (git's status in the prompt is the slow part), little enough that a command that runs on is named at once.
var TERMINAL_TITLE_MS = 150;

function defaultConfig() {
    return {
        follow: "screen",
        stripSuffix: true,
        rewrites: [],
        trayOrder: [],
        trayHide: [],
        trayRename: {},
        trayIconMode: "ink",
        openOn: "hover",
        closeOnLeave: true,
        closeOnActivate: true,
        trayPassive: "faint",
        attention: "peek",
        desktopText: "Desktop",
        terminalClasses: TERMINALS.slice(),
        terminalTitleMs: TERMINAL_TITLE_MS
    };
}

function _isObj(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v);
}

function _strings(v, key, warnings) {
    var out = [];
    if (v === undefined)
        return out;
    if (!Array.isArray(v)) {
        warnings.push(key + ": not a list of strings -- ignored");
        return out;
    }
    for (var i = 0; i < v.length; i++) {
        if (typeof v[i] === "string" && v[i] !== "")
            out.push(v[i]);
        else
            warnings.push(key + "[" + i + "]: not a string -- dropped");
    }
    return out;
}

function _regexOk(src) {
    try {
        new RegExp(src);
        return true;
    } catch (e) {
        return false;
    }
}

// [{re, <valueKey>}] -> the usable ones.
function _rules(v, key, valueKey, warnings) {
    var out = [];
    if (v === undefined)
        return out;
    if (!Array.isArray(v)) {
        warnings.push(key + ": not a list -- ignored");
        return out;
    }
    for (var i = 0; i < v.length; i++) {
        var r = v[i];
        if (!_isObj(r) || typeof r.re !== "string" || r.re === "") {
            warnings.push(key + "[" + i + "]: needs a \"re\" string -- dropped");
            continue;
        }
        if (!_regexOk(r.re)) {
            warnings.push(key + "[" + i + "]: invalid regex " + JSON.stringify(r.re) + " -- dropped");
            continue;
        }
        var value = r[valueKey];
        if (valueKey === "icon") {
            if (typeof value !== "string" || value === "") {
                warnings.push(key + "[" + i + "]: needs an \"icon\" string -- dropped");
                continue;
            }
        } else if (value === undefined) {
            value = "";
        } else if (typeof value !== "string") {
            warnings.push(key + "[" + i + "]: \"to\" is not a string -- dropped");
            continue;
        }
        var o = { re: r.re };
        o[valueKey] = value;
        out.push(o);
    }
    return out;
}

// One of two words, into cfg[key].
function _word(cfg, o, key, words, warnings) {
    if (o[key] === undefined)
        return;
    if (words.indexOf(o[key]) >= 0)
        cfg[key] = o[key];
    else
        warnings.push(key + ": must be \"" + words.join("\" or \"") + "\" -- default kept");
}

function _bool(cfg, o, key, warnings) {
    if (o[key] === undefined)
        return;
    if (typeof o[key] === "boolean")
        cfg[key] = o[key];
    else
        warnings.push(key + ": must be true or false -- default kept");
}

function merge(obj) {
    var warnings = [];
    var cfg = defaultConfig();
    var o = _isObj(obj) ? obj : {};

    _word(cfg, o, "follow", ["screen", "focus"], warnings);
    _bool(cfg, o, "stripSuffix", warnings);
    _word(cfg, o, "openOn", ["hover", "click"], warnings);
    _bool(cfg, o, "closeOnLeave", warnings);
    _bool(cfg, o, "closeOnActivate", warnings);
    _word(cfg, o, "trayPassive", ["faint", "hide"], warnings);
    _word(cfg, o, "attention", ["peek", "off"], warnings);
    if (o.desktopText !== undefined) {
        if (typeof o.desktopText === "string")
            cfg.desktopText = o.desktopText;
        else
            warnings.push("desktopText: not a string -- default kept");
    }
    cfg.rewrites = _rules(o.rewrites, "rewrites", "to", warnings);
    cfg.trayOrder = _strings(o.trayOrder, "trayOrder", warnings);
    cfg.trayHide = _strings(o.trayHide, "trayHide", warnings);
    if (o.trayRename !== undefined) {
        if (_isObj(o.trayRename)) {
            for (var id in o.trayRename) {
                if (typeof o.trayRename[id] === "string" && o.trayRename[id] !== "")
                    cfg.trayRename[id] = o.trayRename[id];
                else
                    warnings.push("trayRename." + id + ": not a name -- dropped");
            }
        } else {
            warnings.push("trayRename: not an object -- ignored");
        }
    }
    if (o.terminalClasses !== undefined) {
        // a list the user wrote stands as written, an empty one switches the hold off
        if (Array.isArray(o.terminalClasses))
            cfg.terminalClasses = _strings(o.terminalClasses, "terminalClasses", warnings);
        else
            warnings.push("terminalClasses: not a list of strings -- default kept");
    }
    if (o.terminalTitleMs !== undefined) {
        if (typeof o.terminalTitleMs === "number" && isFinite(o.terminalTitleMs) && o.terminalTitleMs >= 0 && o.terminalTitleMs <= 2000)
            cfg.terminalTitleMs = Math.round(o.terminalTitleMs);
        else
            warnings.push("terminalTitleMs: must be a number of ms from 0 to 2000 -- default kept");
    }
    _word(cfg, o.trayIconMode === "color" ? { trayIconMode: "colour" } : o, "trayIconMode", ["ink", "colour"], warnings);
    return { config: cfg, warnings: warnings };
}
