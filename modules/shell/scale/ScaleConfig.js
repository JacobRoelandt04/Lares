.pragma library

// =============================================================================
// ScaleConfig.js -- the `scale` block of shell.jsonc, as pure functions.
//
//     "scale": {
//         "global": 1.0, "bar": 1.0, "popup": 1.0,
//         "popups": { "silicon": 1.35, "aerial": 1.35, "llm": 1.1 }, "pills": { "osd": 1.0, "toast": 1.0 },
//         "outputs": { "<connector>": { "global": 1.25, "bar": 1.0, "popup": 1.0, "popups": { ... }, "pills": { ... } } }
//     }
//
//   global       DEVICE pixels per DESIGN pixel -- the number the user turns. 1.25 makes everything 25 % bigger on any
//                output at any Hyprland scale (the shell divides Hyprland's own scale out: ShellScale.frameScale).
//   bar, popup   RATIOS on it, default 1: the bar's thickness and modules, and a popup's content, a little off the rest.
//                The main bar -- its 40 px, the reserve the windows keep clear of it, the islands' lengths and every module in
//                them -- is laid out in its own units and drawn `bar` times larger (ShellFrame, ShellLayout.bars); a popup's
//                content is laid out in its own and drawn `popup` times larger, the engine's radius, fillets and snaps with it
//                (GooeyEngine: THE RATIOS), except a popup that CONTINUES its bar cell (the reel strips, the tray strip), which
//                follows the bar's. The outlet bars stay the compositor's own 6 px.
//   popups       a ratio for ONE popup, by its owner's id (silicon, weather, clock, stocks, player, aerial, update, notifications, notes, llm,
//                clipboard, launcher, windowtray): THAT popup's content is laid out in its own units and drawn this much larger on the global
//                scale, INSTEAD of `popup` (an entry says what the popup's ratio is, not a factor on `popup`). The mechanism is `popup`'s own, per
//                body (GooeyBody.ratio): the radius, the box, the textures follow it. Unless the file says otherwise silicon is 1.35 (the text
//                on its board is small at the global scale) and the LLM 1.1 (a feature-rich popup, slightly bigger).
//                "<id>.detail" is the same for that popup's DETAIL (every child level: its secondary, that card's own, the tray's chain under
//                the reel's strip): with no entry the plain `popup` ratio, never the main popup's (GooeyBody.ownScale; the keys are taken as
//                they are, any id is a key).
//   pills        the same for the floating pills while the bars are hidden or a window is fullscreen: "osd", "toast", and "popup" for the
//                popups that float then; a pill with no entry is `popup`'s.
//   outputs      the same three keys (and `popups`, `pills`, key by key) for one output, by connector name (`hyprctl monitors`); an entry wins over the
//                block's own value, key by key.
//
// A value that is not a number is the default; a number outside the range is clamped to it (a typo of 12 is 4, not 1).
// Never throws. No Qt in here.
// =============================================================================

var GLOBAL_MIN = 0.5;
var GLOBAL_MAX = 4;
var RATIO_MIN = 0.5;
var RATIO_MAX = 2;

function _clamp(v, lo, hi, d) {
    if (typeof v !== "number" || !isFinite(v))
        return d;
    return Math.max(lo, Math.min(hi, v));
}

function _obj(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v) ? v : null;
}

function _has(o, k) {
    return Object.prototype.hasOwnProperty.call(o, k);
}

// The parsed shell.jsonc (whatever shape, or nothing) -> { global, bar, popup, outputs: { name: { global?, bar?, popup? } } }.
// A map of ratios by id: the numbers it holds, clamped; whatever else is left out. Own keys only (an id like `constructor` is no entry).
function _ratios(v) {
    const o = _obj(v), r = {};
    if (o)
        for (const k in o)
            if (_has(o, k) && typeof o[k] === "number" && isFinite(o[k]))
                r[k] = _clamp(o[k], RATIO_MIN, RATIO_MAX, 1);
    return _alias(r);
}

// What the file says nothing about: silicon's and aerial's boards are read at 1.35, the LLM's chat at 1.1.
var DEFAULT_POPUPS = { silicon: 1.35, aerial: 1.35, llm: 1.1 };

// `network` is aerial (the module's old id): a user's entry for it counts as aerial's unless the file names aerial itself.
function _alias(r) {
    for (const k of ["network", "network.detail"]) {
        if (!_has(r, k))
            continue;
        const to = "aerial" + k.slice(7);
        if (!_has(r, to))
            r[to] = r[k];
        delete r[k];
    }
    return r;
}

function parse(raw) {
    const root = _obj(raw);
    const s = root && _obj(root.scale) ? root.scale : {};
    const out = {
        global: _clamp(s.global, GLOBAL_MIN, GLOBAL_MAX, 1),
        bar: _clamp(s.bar, RATIO_MIN, RATIO_MAX, 1),
        popup: _clamp(s.popup, RATIO_MIN, RATIO_MAX, 1),
        popups: Object.assign({}, DEFAULT_POPUPS, _ratios(s.popups)),
        pills: _ratios(s.pills),
        outputs: {}
    };
    const outs = _obj(s.outputs);
    if (outs) {
        for (const name in outs) {
            const e = _obj(outs[name]);
            if (!e || !_has(outs, name))
                continue;
            const r = {};
            if (typeof e.global === "number" && isFinite(e.global))
                r.global = _clamp(e.global, GLOBAL_MIN, GLOBAL_MAX, 1);
            if (typeof e.bar === "number" && isFinite(e.bar))
                r.bar = _clamp(e.bar, RATIO_MIN, RATIO_MAX, 1);
            if (typeof e.popup === "number" && isFinite(e.popup))
                r.popup = _clamp(e.popup, RATIO_MIN, RATIO_MAX, 1);
            const ep = _ratios(e.popups), el = _ratios(e.pills);
            if (Object.keys(ep).length)
                r.popups = ep;
            if (Object.keys(el).length)
                r.pills = el;
            out.outputs[name] = r;
        }
    }
    return out;
}

// The RATIO of a kind on the frame, for one output: what its own `bar` / `popup` key says, else the block's; 1 for "frame" and anything
// else. (Not `configured(kind) / configured("frame")`: that division is the ratio only to the last bit.)
function ratio(cfg, name, kind) {
    const e = _has(cfg.outputs, name) ? cfg.outputs[name] : {};
    if (kind === "bar")
        return e.bar !== undefined ? e.bar : cfg.bar;
    if (kind === "popup")
        return e.popup !== undefined ? e.popup : cfg.popup;
    // "pill:osd": that pill's own entry (the output's, then the block's), else the popups' ratio
    if (typeof kind === "string" && kind.indexOf("pill:") === 0) {
        const k = kind.slice(5);
        if (e.pills && _has(e.pills, k))
            return e.pills[k];
        if (cfg.pills && _has(cfg.pills, k))
            return cfg.pills[k];
        return ratio(cfg, name, "popup");
    }
    return 1;
}

// Every popup's own ratio for one output: { ownerId: ratio } -- the block's (silicon's default included) under the output's. What the
// frame hands its engine (GooeyEngine.popupScales); an owner with no entry is `popup`'s.
function popupMap(cfg, name) {
    const e = _has(cfg.outputs, name) ? cfg.outputs[name] : {};
    return Object.assign({}, cfg.popups || {}, e.popups || {});
}

// DEVICE px per DESIGN px for one output and one kind: "frame" (the global), "bar" (global x the bar's ratio) or "popup".
function configured(cfg, name, kind) {
    const e = _has(cfg.outputs, name) ? cfg.outputs[name] : {};
    const g = e.global !== undefined ? e.global : cfg.global;
    if (kind === "bar")
        return g * (e.bar !== undefined ? e.bar : cfg.bar);
    if (kind === "popup")
        return g * (e.popup !== undefined ? e.popup : cfg.popup);
    if (typeof kind === "string" && kind.indexOf("pill:") === 0)
        return g * ratio(cfg, name, kind);
    return g;
}
