pragma ComponentBehavior: Bound

import QtQuick
import "../theme"

// =============================================================================
// MockupRegistry -- the bookkeeping behind a mockup's control panel.
//
// Which value lists exist, which live object each one writes to, what the
// file default of every entry is, and the questions the panel keeps asking:
// is this value modified, how many on this tab are, put them back, collect
// them, apply a set. Pure data and functions; MockupStore does the file I/O.
//
// A list is a plain array declared in the mockup file, one entry per value:
//   numeric: { label, prop, group, tip, val, from, to, step }  -> a slider
//   boolean: { label, prop, group, tip, val: true }             -> a switch
//   choice : { label, prop, group, tip, val: 0, choices: ["a", "b"] }
//                                                  -> a drop-down; the value
//                                                     is the index (a number)
//   text   : { label, prop, group, tip, val: "words", kind: "text" }
//                                                  -> a line of text
//   json   : { label, prop, group, tip, val: "[\"x\"]", kind: "json",
//              shape: "array" | "strings" | "object" | "rules" }
//                                                  -> JSON text, applied only
//                                                     while it parses (and has
//                                                     the shape)
//   colour : { label, prop, group, tip, val: "#RRGGBB" }        -> a hex field
//            val "@<token>" -> the colour FOLLOWS that Theme token (the
//            component's own binding when it binds that token, else one the
//            load makes); a hex typed over it is an override, one colour in
//            both modes, and Reset puts the binding back
// `blurb` on the first entry of a group is that group's description. The KIND
// of a row is its own `val` (and `kind` / `choices` where a string or a number
// could mean two things): a boolean one is a switch, a number a slider (a
// drop-down with `choices`), a string with `kind` a text row, and a list whose
// FIRST entry's `val` is a string WITHOUT a `kind` is a colour list (so bools,
// choices and text belong in a param list, beside the numbers of the same
// component, never in a colour one). An entry's `val` is the mockup's
// default for `prop` on the list's target: pushed in on load, restored by
// Reset, compared against for the * marks, and rewritten by "Save to mockup".
//
// SAVE WRITES THE MODULE TOO (round 1 of the shell assembly). A row's value is
// the module's setting: Save finds, with tools/dev/mockup_promote.py, where the
// module ships that default and writes it there (the module's own declaration,
// or -- for a component other modules share -- the module's own use of it), then
// commits exactly those files through tools/shell/lares. `plan` holds what the
// script said of each row at load ({"list.prop": {status, reason, mode, where,
// shared, sharedWhere}}), and `sharedPick` the rows whose per-row switch asks for
// the SHARED component's own default instead (every module that uses it follows).
//
// A list named in `fileBacked` ({listId: "<file>"}) keeps its values in a file
// of the module's own (a config the mockup writes as its rows move): its `val:`
// is the code's default, so Save to mockup leaves it out -- a saved val would
// either be overridden by the file at the next launch or override it -- and its
// * says "the file sets its own value". It stays in Reset and in the profiles.
//
// A list named in `themedLists` is the exception: its values live in the
// theme, so `colorOf` reads them from Theme and `setColor` writes them with
// Theme.setToken, and they are never pushed into the target at all -- it may
// not even have such a property. `val` stays the shipped default. Such a list
// is out of Reset, out of the * marks and out of the profiles: it is not the
// module's state, so a profile that carried it would be a copy of the user's
// palette that overwrote the theme file when loaded.
// =============================================================================
QtObject {
    id: reg

    // {listId: entries}. The id is the mockup's property name for that
    // array, because tools/dev/mockup_save_defaults.py finds the array in the
    // file by `property var <listId>: [`.
    property var lists: ({})
    // The object every list writes to unless `targets` names another.
    property var target: null
    // {listId: object} for the lists that write somewhere else.
    property var targets: ({})
    // The list ids whose values ARE theme tokens: the component's property is
    // bound to Theme, so writing it (t[e.prop] = v) would destroy that binding
    // permanently and the module would stop following the theme -- and
    // applyDefaults alone would do it the moment the mockup opened. Those
    // lists read and write through Theme instead. Per list, so a module can
    // theme one of its lists without changing how any other behaves.
    property var themedLists: []
    // {listId: "<file name>"}: the lists whose values live in a file of the
    // module's own (see the header). The name is what a row's tip names.
    property var fileBacked: ({})
    // False while the mockup runs from a COPY of the config (tools/dev/sandbox.sh):
    // a themed row's edit would write the copy's themes/<name>.json, which the
    // next sync puts back without a word -- so such a row is read-only then.
    property bool themeWritable: true
    // Bumped after a save rewrites the defaults; every * mark takes it as
    // an argument so it re-evaluates.
    property int defaultsRev: 0

    // What Save would do with each row (tools/dev/mockup_promote.py plan), read once
    // at load: {"list.prop": {status: write|same|refuse|skip, reason, mode, where,
    // shared, sharedWhere}}. Empty until it arrives, and for a mockup run from a
    // scripted mode (a grab, a render): the panel is then exactly what it was.
    property var plan: ({})
    // {"list.prop": true}: rows whose "shared default" switch is on. REASSIGNED on a
    // change (never mutated), so a binding that asks hears it.
    property var sharedPick: ({})
    function rowPlan(id, e) {
        return reg.plan[id + "." + e.prop] || null;
    }
    // Does this row have a shared component's declaration as an alternative to the module's own use of it?
    function hasSharedChoice(id, e) {
        const p = reg.rowPlan(id, e);
        return !!p && p.shared === true;
    }
    function sharedOn(id, e) {
        return reg.sharedPick[id + "." + e.prop] === true;
    }
    function setShared(id, e, on) {
        const next = Object.assign({}, reg.sharedPick);
        if (on)
            next[id + "." + e.prop] = true;
        else
            delete next[id + "." + e.prop];
        reg.sharedPick = next;
    }
    // The picks that apply to a Save: switched on AND saveable (a row whose switch was left on after its
    // value went back to the default has nothing to write).
    function sharedKeys(changes) {
        const out = [];
        for (const k of Object.keys(reg.sharedPick)) {
            const i = k.indexOf(".");
            if (changes[k.substring(0, i)] && changes[k.substring(0, i)][k.substring(i + 1)] !== undefined)
                out.push(k);
        }
        return out;
    }
    // What Save will do with this row, in words (appended to the row's tip).
    function planNote(id, e) {
        const p = reg.rowPlan(id, e);
        if (!p || reg.isThemed(id) || reg.isFileBacked(id))
            return "";
        if (p.status === "write")
            return "\nSave writes it to the module: " + (p.where || "") + (p.mode ? " (" + p.mode + ")" : "") + ".";
        if (p.status === "same")
            return "\nThe module ships this value now; a change is written to the module by Save.";
        if (p.status === "refuse")
            return "\nSave keeps this in the mockup only; the module is not written: " + p.reason + ".";
        return "\nNot a module setting: " + p.reason + ".";
    }
    // The shared switch's explanation, for a row that has one.
    function sharedNote(id, e) {
        const p = reg.rowPlan(id, e);
        if (!p || p.shared !== true)
            return "";
        return "\nA component other modules use too: by default Save writes the value at THIS module's use of it, "
             + "and leaves the component alone. The switch writes the component's own default instead ("
             + (p.sharedWhere || "its declaration") + "), which every module that uses it then follows.";
    }

    readonly property var listIds: Object.keys(reg.lists)

    function entries(id) {
        return reg.lists[id] || [];
    }
    function targetOf(id) {
        return reg.targets[id] || reg.target;
    }
    function isColorList(id) {
        const a = reg.entries(id);
        return a.length > 0 && typeof a[0].val === "string" && !a[0].kind;
    }
    // The kind of ONE row, asked of the entry rather than of the list: a
    // param list holds a component's numbers and its switches together,
    // because they are the same component's settings and the panel splits by
    // component, never by kind. `val` is the marker, and `kind` / `choices`
    // where the val alone could mean two things -- an entry stays
    // { label, prop, group, tip, val } whatever it drives.
    function isBoolEntry(e) {
        return typeof e.val === "boolean";
    }
    // Not Array.isArray: a delegate's modelData hands the list over as a
    // sequence (a QVariantList), which is array-like but no Array.
    function isChoiceEntry(e) {
        const c = e.choices;
        return !!c && typeof c !== "string" && c.length > 0;
    }
    function isTextEntry(e) {
        return e.kind === "text" || e.kind === "json";
    }
    function isJsonEntry(e) {
        return e.kind === "json";
    }
    // A slider: a number with a range, none of the kinds above.
    function isSliderEntry(e) {
        return !reg.isBoolEntry(e) && !reg.isChoiceEntry(e) && !reg.isTextEntry(e);
    }
    // A slider's figure as its row shows it: the decimals its step implies.
    function figureText(e, v) {
        return Number(v).toFixed(e.step < 0.01 ? 3 : e.step < 1 ? 2 : 0);
    }
    function isThemed(id) {
        return reg.themedLists.indexOf(id) >= 0;
    }
    function isFileBacked(id) {
        return Object.prototype.hasOwnProperty.call(reg.fileBacked, id);
    }
    // The lists "Save to mockup" writes: neither the theme's nor a file's.
    function savedIds() {
        return reg.listIds.filter(id => !reg.isThemed(id) && !reg.isFileBacked(id));
    }

    // ---- JSON rows --------------------------------------------------------
    // Why a JSON row's text is NOT applied, or "" when it may be: it must
    // parse, and have the entry's `shape` -- "array", "strings" (an array of
    // strings), "object", "rules" (an object whose every value is an object).
    function jsonProblem(e, text) {
        let v;
        try {
            v = JSON.parse(String(text));
        } catch (err) {
            return String(err.message || err);
        }
        const isObj = x => x !== null && typeof x === "object" && !Array.isArray(x);
        switch (e.shape) {
        case "array":
            return Array.isArray(v) ? "" : "not a list [ ... ]";
        case "strings":
            return Array.isArray(v) && v.every(x => typeof x === "string") ? "" : "not a list of strings [\"...\", ...]";
        case "object":
            return isObj(v) ? "" : "not an object { ... }";
        case "rules":
            if (!isObj(v))
                return "not an object { \"name\": { ... } }";
            for (const k in v)
                if (!isObj(v[k]))
                    return "\"" + k + "\" is not an object of keys";
            return "";
        default:
            return "";
        }
    }
    // The text in one form, so formatting never reads as a change.
    function canonicalJson(text) {
        try {
            return JSON.stringify(JSON.parse(String(text)));
        } catch (err) {
            return String(text);
        }
    }

    // ---- colours that follow a theme token --------------------------------
    // A colour val "@<token>" is the component's own binding to that Theme
    // token: "" for any other val.
    function tokenDefault(v) {
        return typeof v === "string" && v.charAt(0) === "@" ? v.substring(1) : "";
    }
    // The token's live colour -- read by NAME off Theme, so a binding that
    // calls this depends on the token itself, exactly as the component's
    // own `Theme.<token>` does.
    function tokenColor(tok) {
        return Theme[Theme.tokenKey(tok)];
    }
    // The colour a token has IN THE MODE AN ENTRY IS FOR. An entry may carry
    // `themeMode: "light" | "dark"` (a per-theme colour, the notifications'
    // group palette): its property is bound to the token as the module binds
    // it, so it shows the token in the mode on screen -- right for the row
    // whose mode is on screen, the other mode's colour for the other row,
    // which is what Theme.counterpart answers. Entries without a themeMode
    // are the token as it stands.
    function tokenColorFor(e, tok) {
        const c = reg.tokenColor(tok);
        if (e && e.themeMode !== undefined && e.themeMode !== Theme.mode)
            return Qt.color(Theme.counterpart(String(c), Theme.tokenKey(tok)));
        return c;
    }
    // What a colour field accepts: a hex, or "@<token>" for a known token.
    function isColorText(s) {
        const tok = reg.tokenDefault(s);
        return reg.isHex(s) || (tok !== "" && Theme.hasToken(tok));
    }
    // Which token a colour row follows right now ("" = a literal colour), by
    // "<listId>.<prop>". Written wherever a colour is assigned (_assign); a row
    // nothing has assigned yet is at its load default, which for "@<token>" is
    // the component's own binding to it (or the one the load made). REASSIGNED
    // on a change, never mutated in place, so a binding that asks -- a row's
    // * mark, its field -- hears a row switch token even when its colour does
    // not move: two tokens that agree in this mode (eva's light textFaint is
    // ansiBrightWhite) left the * off, and Save skipped the row.
    property var _follows: ({})
    function _setFollows(key, tok) {
        if (Object.prototype.hasOwnProperty.call(reg._follows, key) && reg._follows[key] === tok)
            return;
        const next = Object.assign({}, reg._follows);
        next[key] = tok;
        reg._follows = next;
    }
    function followsToken(id, e) {
        const key = id + "." + e.prop;
        return Object.prototype.hasOwnProperty.call(reg._follows, key) ? reg._follows[key]
            : reg.tokenDefault(reg.defaultOf(id, e.prop));
    }
    // THE one way a value reaches a target. A colour "@<token>" becomes a
    // BINDING to that token -- the component's own kind of default, so the row
    // follows every theme switch again; any other value is assigned as it is.
    // A literal colour equal to what the row's default token shows right now
    // is taken as that token: it is the default, and a literal would stop
    // following at the next switch.
    function _assign(id, e, v) {
        const t = reg.targetOf(id);
        if (!t)
            return false;
        if (reg.isColorList(id)) {
            const key = id + "." + e.prop;
            let tok = reg.tokenDefault(v);
            const dtok = reg.tokenDefault(reg.defaultOf(id, e.prop));
            if (tok === "" && dtok !== "" && reg.isHex(String(v)) && Qt.colorEqual(v, reg.tokenColorFor(e, dtok)))
                tok = dtok;
            // Recorded BEFORE the write: the write's own change handlers (a
            // field's sync) ask which token the row follows.
            if (tok !== "") {
                const k = Theme.tokenKey(tok);
                reg._setFollows(key, tok);
                t[e.prop] = Qt.binding(() => Theme[k]);
                return true;
            }
            reg._setFollows(key, "");
        }
        t[e.prop] = v;
        return true;
    }
    // The theme token behind one entry, or "" when this entry is not themed.
    // An entry of a themed list whose prop is no token falls back to the
    // ordinary path rather than calling Theme with a key it does not know.
    function themeKeyOf(id, e) {
        if (!reg.isThemed(id) || !Theme.hasToken(e.prop))
            return "";
        return Theme.tokenKey(e.prop);
    }
    // Every list a tab reaches: its own plus those of its sub-tabs.
    function tabLists(def) {
        if (!def)
            return [];
        const ids = (def.lists || []).slice();
        for (const s of (def.subs || []))
            for (const id of (s.lists || []))
                if (ids.indexOf(id) < 0)
                    ids.push(id);
        return ids;
    }
    // The file default for one property. Looked up by name rather than read
    // off a delegate's modelData: the model hands delegates a COPY of each
    // entry, so a save that rewrites `val` in place would never reach them.
    function defaultOf(id, prop) {
        const all = reg.entries(id);
        for (let i = 0; i < all.length; i++)
            if (all[i].prop === prop)
                return all[i].val;
        return undefined;
    }
    // Is this row's live value something other than its file default? One
    // function for both kinds a param list holds: a number is compared with
    // the slack its own step implies, a bool is simply not the same bool.
    function valueModified(rev, target, id, e) {
        const d = reg.defaultOf(id, e.prop);
        if (!target || d === undefined)
            return false;
        if (reg.isBoolEntry(e))
            return !!target[e.prop] !== d;
        // JSON is compared as data, so re-indenting it is not a change.
        if (reg.isJsonEntry(e))
            return reg.canonicalJson(target[e.prop]) !== reg.canonicalJson(d);
        if (reg.isTextEntry(e))
            return String(target[e.prop]) !== String(d);
        return Math.abs(Number(target[e.prop]) - d) > (e.step > 0 ? e.step * 1e-3 : 1e-6);
    }
    function colorModified(rev, target, id, e) {
        const d = reg.defaultOf(id, e.prop);
        if (d === undefined)
            return false;
        // A themed row is NEVER modified, and comparing it against `val` was
        // wrong in both directions. `val` is the light shipped default, so in
        // dark mode every themed row read as modified: thirty stars, a banner
        // claiming thirty values differ, and a "Save to mockup" offering to
        // write dark hexes into the light defaults. And there is nothing for
        // the mark to mean anyway -- setToken writes the theme file as you
        // drag, so the row and its file are never out of step. The theme file
        // is the thing under version control; that is what says it changed.
        if (reg.themeKeyOf(id, e) !== "")
            return false;
        if (!target)
            return false;
        // A row that follows a token its default does not (or none where its
        // default does) is modified whatever it shows: two tokens can agree
        // in this mode and part in the other. Otherwise it is modified when
        // it shows anything but its default's colour -- read live, so a token
        // default stays unmarked through a theme switch, and a module whose
        // own binding went stale is marked.
        const tok = reg.tokenDefault(d);
        if (reg.followsToken(id, e) !== tok)
            return true;
        return !Qt.colorEqual(target[e.prop], tok !== "" ? reg.tokenColor(tok) : d);
    }
    function entryModified(rev, id, e) {
        const t = reg.targetOf(id);
        return reg.isColorList(id) ? reg.colorModified(rev, t, id, e) : reg.valueModified(rev, t, id, e);
    }
    // How many entries of these lists (optionally only of these groups)
    // differ from their defaults.
    function modifiedCount(rev, ids, groups) {
        let n = 0;
        for (const id of ids)
            for (const e of reg.entries(id))
                if ((!groups || groups.indexOf(e.group) >= 0) && reg.entryModified(rev, id, e))
                    n++;
        return n;
    }
    // Puts ONE entry back to its file default: the per-value counterpart of
    // applyDefaults, behind the right-click on a modified label. The default
    // is looked up by name instead of taken from the `e` handed in, because
    // a list delegate holds a COPY of its entry and that copy's `val` is
    // stale once a save has adopted new defaults.
    function resetEntry(id, e) {
        const d = reg.defaultOf(id, e.prop);
        if (d === undefined)
            return false;
        // A themed row has no default of its own to go back to: `val` is the
        // light value, which is not what "reset" means while the shell is
        // dark. Unreachable in practice (the gesture is gated on the * mark,
        // which a themed row never carries) and refused here so it stays that
        // way if the gate ever changes.
        if (reg.themeKeyOf(id, e) !== "")
            return false;
        return reg._assign(id, e, d);
    }
    // What a modified row appends to its own tip. It lives here so both
    // lists word it the same way, and so a row can carry the affordance
    // without a glyph: the tip and the pointer are all that announce it.
    // What a themed row appends to its tip instead of the reset line: it says
    // where the value it edits actually lives, which is the question a row
    // with no * invites.
    function themeNote(id, e) {
        const key = reg.themeKeyOf(id, e);
        if (key === "")
            return "";
        // The file Theme READ the theme from, which is where the edit lands: the user's ~/.config/theme/themes/<name>.json once there
        // is one (themectl and the shell read it too), the repo's themes/<name>.json until then.
        return "\nEdits \"" + key + "\" in the " + Theme.mode + " half of "
             + (Theme.themePath !== "" ? Theme.themePath : "themes/" + Theme.themeName + ".json")
             + " — the theme itself, so there is no separate default.";
    }
    function resetHint(id, e) {
        const d = reg.defaultOf(id, e.prop);
        if (d === undefined)
            return "";
        // Through hexOf so a `val:` written in lower case still reads the
        // way the row's own field shows it, a bool in the words its own
        // switch is read by rather than as `true`, a choice by its name.
        const tok = reg.tokenDefault(d);
        const shown = tok !== "" ? "the theme's " + tok
            : reg.isColorList(id) ? reg.hexOf(d)
            : reg.isBoolEntry(e) ? (d ? "on" : "off")
            : reg.isChoiceEntry(e) ? (e.choices[d] !== undefined ? e.choices[d] : d)
            : reg.isTextEntry(e) ? "\"" + String(d) + "\""
            : d;
        return "\nRight-click the label to reset it to " + shown + ".";
    }
    // What a row of a file-backed list appends to its tip: where its value
    // really lives, and so why Save to mockup leaves it out.
    function fileNote(id) {
        if (!reg.isFileBacked(id))
            return "";
        return "\nKept in " + reg.fileBacked[id] + ", which the mockup writes as you move this -- not in"
             + " the mockup's val:, which is the code's default. So Save to mockup leaves it out, and a *"
             + " here says the file sets a value of its own.";
    }
    // Could the target's own binding BE `tok`? It shows that token's colour
    // now, and no token showing the same colour now parts from it in the
    // other mode -- values collide: in eva's light mode catMultilib is also
    // ansiBrightCyan and textFaint is ansiBrightWhite, and each pair parts in
    // the dark (measured), so a component bound to one passes for the other
    // until the first switch. Read by name off Theme, like tokenColor.
    function _mayBindToken(t, prop, tok) {
        const c = reg.tokenColor(tok);
        if (!Qt.colorEqual(t[prop], c))
            return false;
        const hex = String(c);
        const alt = Theme.counterpart(hex, Theme.tokenKey(tok));
        return Theme.tokenNames.every(n => !Qt.colorEqual(Theme[n], c) || Theme.counterpart(hex, n) === alt);
    }
    // `initial` is the load. A colour whose default is "@<token>" is then
    // left alone when the component may already bind that token: the mockup
    // shows the module's OWN binding, not a copy of it, so a module that
    // stops following the theme is seen here. Any other target gets the
    // binding -- a token SAVED over the module's own (System -> @accent) is
    // the mockup's default like any saved val, and skipping it drew the
    // module's cyan under a field reading @accent, marked * for good (R2E
    // refix P1.7). Reset (not initial) always puts the binding back.
    function applyDefaults(ids, initial) {
        for (const id of ids) {
            // A themed list is skipped whole: its values live in the theme,
            // and pushing the mockup's val: over them would sever the target's
            // theme bindings before a single control had been touched.
            if (reg.isThemed(id))
                continue;
            const t = reg.targetOf(id);
            if (!t)
                continue;
            for (const e of reg.entries(id)) {
                if (e.val === undefined)
                    continue;
                if (initial === true && reg.isColorList(id) && reg.tokenDefault(e.val) !== ""
                        && reg._mayBindToken(t, e.prop, reg.tokenDefault(e.val)))
                    continue;
                reg._assign(id, e, e.val);
            }
        }
    }
    // Decimal places implied by a slider's step, so 0.30000000000000004 is
    // saved and compared as 0.3.
    function stepDecimals(step) {
        const s = String(step);
        const dot = s.indexOf(".");
        return dot < 0 ? 0 : Math.min(6, s.length - dot - 1);
    }
    function isHex(s) {
        return /^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(s);
    }
    function hexOf(c) {
        return String(c).toUpperCase();
    }
    // The live COLOUR of a colour entry -- what its swatch and its hex field
    // show. A themed row is read from the theme, never from the target: a
    // themed list may legitimately have no target of its own (its values are
    // not the module's), and where it does have one the property is bound to
    // this same token anyway. Reading the target regardless is what put
    // `undefined` into a QColor twenty times per launch as soon as a themed
    // list named tokens the target does not carry.
    function colorOf(id, e) {
        const key = reg.themeKeyOf(id, e);
        if (key !== "")
            return Theme.tokenOf(key);
        const t = reg.targetOf(id);
        if (!t)
            return "transparent";
        // A per-theme row that follows a token, shown in the OTHER mode: the
        // property holds the token as it is on screen, the row is for the one
        // that is not.
        const tok = reg.followsToken(id, e);
        return tok !== "" && e.themeMode !== undefined && e.themeMode !== Theme.mode
            ? reg.tokenColorFor(e, tok) : t[e.prop];
    }
    // The counterpart write, for the same reason and one more: a themed row
    // IS the theme, so it goes through setToken. Assigning the target's
    // property would destroy its `Theme.<token>` binding permanently -- the
    // module would keep the typed colour and ignore every later switch.
    // A themed row under a copy of the config is refused (themeWritable).
    function setColor(id, e, hex) {
        const key = reg.themeKeyOf(id, e);
        if (key !== "")
            return reg.themeWritable ? Theme.setToken(key, hex) : false;
        return reg._assign(id, e, hex);
    }
    // What a colour row's field shows: "@<token>" while the row follows one,
    // else the live hex.
    function colorTextOf(id, e) {
        if (reg.themeKeyOf(id, e) === "") {
            const tok = reg.followsToken(id, e);
            if (tok !== "")
                return "@" + tok;
        }
        return reg.hexOf(reg.colorOf(id, e));
    }
    // The live value of an entry, in the form the file and a profile hold.
    // Themed rows still answer, because the panel's readouts ask -- but see
    // collect(): they never reach a profile.
    function liveValue(id, e) {
        const key = reg.themeKeyOf(id, e);
        if (key !== "")
            return reg.hexOf(Theme.tokenOf(key));
        const t = reg.targetOf(id);
        // A colour following its token is "@<token>", never the hex it shows
        // in this mode: a profile or a save holding the hex would pin the
        // light colour into the dark theme.
        if (reg.isColorList(id))
            return reg.followsToken(id, e) !== "" ? "@" + reg.followsToken(id, e) : reg.hexOf(t[e.prop]);
        // A bool stays a bool all the way out: it is written into the file as
        // `val: true` and into a profile as JSON `true`, so anything that
        // rounded it through a Number here would save a switch as 1.
        if (reg.isBoolEntry(e))
            return !!t[e.prop];
        if (reg.isTextEntry(e))
            return String(t[e.prop]);
        return Number(Number(t[e.prop]).toFixed(reg.stepDecimals(e.step)));
    }
    // An entry's default in the form a profile holds it (the derived
    // `default` profile): through the same helpers as a live value, so the two
    // are written identically.
    function defaultForm(id, e) {
        if (reg.isColorList(id))
            return reg.tokenDefault(e.val) !== "" ? e.val : reg.hexOf(e.val);
        if (reg.isBoolEntry(e) || reg.isTextEntry(e))
            return e.val;
        return Number(Number(e.val).toFixed(reg.stepDecimals(e.step)));
    }
    // A value this entry does NOT hold, per kind: what the panel self-test
    // writes to make a row modified. It lives here because the kinds do --
    // "one step up" means nothing to a switch, and a self-test that could
    // only nudge numbers was a self-test that proved nothing about the
    // other two kinds.
    function nudgedValue(id, e) {
        if (reg.isBoolEntry(e))
            return !e.val;
        if (reg.isColorList(id))
            return reg.hexOf(e.val) === "#FF0000" ? "#00FF00" : "#FF0000";
        if (reg.isChoiceEntry(e))
            return (Number(e.val) + 1) % e.choices.length;
        if (reg.isJsonEntry(e)) {
            const empty = e.shape === "array" || e.shape === "strings" ? "[]" : "{}";
            const other = e.shape === "array" || e.shape === "strings" ? "[\"x\"]" : "{\"x\": {}}";
            return reg.canonicalJson(e.val) === empty ? other : empty;
        }
        if (reg.isTextEntry(e))
            return String(e.val) + " x";
        // Number() around the ternary as well as around the result: the
        // step's decimals are what keeps 0.30000000000000004 out of the file,
        // and without the inner one qmllint cannot see a number to round.
        const v = e.val + e.step <= e.to ? e.val + e.step : e.val - e.step;
        return Number(Number(v).toFixed(reg.stepDecimals(e.step)));
    }
    // {listId: {prop: value}} for every entry, or only the modified ones.
    //
    // A THEMED LIST IS NEVER COLLECTED. A profile is a snapshot of the
    // module's knobs; a themed row is not the module's, it is the theme --
    // which is why it carries no `*` and cannot be reset. Collecting one put
    // the user's live palette into every profile, and loading that profile
    // then wrote it back through setToken, one literal per token: the first
    // profile round trip flattened every `@alias` in the active mode's block
    // of themes/<name>.json. Measured, not feared -- the panel self-test did
    // it to eva.json's light half.
    function collect(ids, onlyModified) {
        const out = {};
        for (const id of ids) {
            if (reg.isThemed(id) || !reg.targetOf(id))
                continue;
            for (const e of reg.entries(id)) {
                if (onlyModified && !reg.entryModified(reg.defaultsRev, id, e))
                    continue;
                if (!out[id])
                    out[id] = {};
                out[id][e.prop] = reg.liveValue(id, e);
            }
        }
        return out;
    }
    // Pushes a {listId: {prop: value}} set into the targets. Unknown lists
    // and props are ignored, so an older profile still applies what it can --
    // and so is any themed list, which a profile written before collect()
    // stopped gathering them may still carry. Replaying those would edit the
    // theme file, and a profile has no business doing that; the panel edits
    // the theme through setColor, one row at a time, deliberately.
    function applyValues(obj) {
        for (const id in obj) {
            if (reg.listIds.indexOf(id) < 0 || typeof obj[id] !== "object")
                continue;
            if (reg.isThemed(id))
                continue;
            if (!reg.targetOf(id))
                continue;
            for (const e of reg.entries(id)) {
                const v = obj[id][e.prop];
                if (v !== undefined)
                    reg.setValue(id, e, v);
            }
        }
    }
    // One row's value, as the panel's own controls write it: a colour through
    // _assign ("@<token>" is a binding), JSON only while it parses and has its
    // shape (a profile or a probe cannot put what the row would refuse into
    // the target). Returns whether it was written.
    function setValue(id, e, v) {
        if (reg.isJsonEntry(e) && reg.jsonProblem(e, v) !== "")
            return false;
        return reg._assign(id, e, v);
    }
    // Makes a {listId: {prop: value}} set the in-memory defaults, after the
    // file has been rewritten with those same values.
    function adoptDefaults(obj) {
        const next = Object.assign({}, reg.sharedPick);
        for (const id in obj)
            for (const e of reg.entries(id))
                if (obj[id][e.prop] !== undefined) {
                    e.val = obj[id][e.prop];
                    delete next[id + "." + e.prop];     // the pick was for this Save
                }
        reg.sharedPick = next;
        reg.defaultsRev++;
    }
}
