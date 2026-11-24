.pragma library

// =============================================================================
// SoftRules.js -- the soft idle mode's rules, with no Qt in them.
//
// What soft DOES to the machine is one thing: the laptop panel's brightness, in three levels:
//
//   0  full      brightness.sh --resume    the saved full value, put back exactly                       (their script)
//   1  dimmed    the `dim` step            saves the full raw value in the script's state file, sets `dimLevel` (0.7) of it
//   2  deep      the `deep` step           sets `deepLevel` (0.5) of the saved full value; the state file is left alone
//
// THE LEVELS ARE PERCEIVED, NOT RAW. The shell already knows how bright a raw value LOOKS: the OSD's brightness keys climb a ladder of
// rungs laid along raw = max * (rung / N) ^ gamma (modules/osd/data/OsdKinds.js: brightnessRungs, brightnessPos, brightnessRawAt;
// gamma, step and floorRaw from OsdConfig's `brightness`). `dimLevel` and `deepLevel` are fractions of the full value's POSITION on
// that ladder, so soft's steps are the same perceived amount at any starting brightness: at the default gamma 2 a dimLevel of 0.7 is
// about half the raw value (0.7^2) and a deepLevel of 0.5 about a quarter -- from 400 that is 196 and 100 -- but from 100 it is 49 and
// 25 on the SAME curve, not 50 and 25 of a linear one.
//
// SOFT NEVER GOES DARK. Their hypridle's third step, brightness.sh --idle, is `brightnessctl set 0`, and their --pre-idle is half by
// integer division (0 on a panel already at 1): soft runs neither. It does both its steps itself, never below raw 1 -- the true
// minimum -- and never above where the panel is. The one exception is the user's own: a full value of 0 (the panel set off by hand)
// is left at 0, soft never raises it. The state file is written in the script's own format (the raw number), so their --resume
// restores the full value exactly, soft's or hypridle's.
//
// Two things ask for a level: the INPUT IDLENESS (nothing touched for dimAfter -> 1, for deepAfter -> 2) and the ATTENTION
// (an external output is connected and the focus has been on it for awayAfter -> 1). The panel takes the higher of the two.
// Blank, lock and suspend are not here at all: soft holds the Wayland inhibitor, so hypridle's own listeners never fire.
//
// THE STATE FILE IS NOT FORGIVING and the rules are shaped by it: the dim step saves the brightness it finds as the one to give
// back, so running it twice (or while deep) would save the DIMMED value for good. So the steps always run in the order
// resume -> dim -> deep, and the dim step only ever starts from full.
// =============================================================================

var FULL = 0;
var DIM = 1;
var DEEP = 2;

// The steps' names. `--resume` is the user's script; `dim` and `deep` are soft's own (neither is a flag of the script).
var DIM_ARG = "dim";
var DEEP_ARG = "deep";
var FLAG = { 0: "--resume", 1: DIM_ARG, 2: DEEP_ARG };

// What a dim / deep step reads first: `bash -c READ_SH idle-read <stateFile> <brightnessctl> <device>` prints "<now> <max> <saved>" -- the
// panel's raw brightness, its maximum, and what the state file holds ("-" when there is none). A reading that fails is an exit code and no
// output, never a guess. THE DEVICE IS NAMED, always (`-c backlight -d <device>`, PanelBacklight's answer): a bare brightnessctl takes the
// first backlight it finds, which in dGPU mode is nvidia_0 even when it is not the panel's. No device is exit 6, nothing is touched.
var READ_SH = [
    '[ -n "$3" ] || exit 6',
    'g=$("$2" -c backlight -d "$3" g 2> /dev/null) || exit 3',
    'm=$("$2" -c backlight -d "$3" m 2> /dev/null) || exit 4',
    's=$(cat "$1" 2> /dev/null) || s=-',
    'echo "$g $m $s"'
].join("\n");

// What it then does: `bash -c SET_SH idle-set <stateFile> <brightnessctl> <save|-> <target|-> <device>`. The full value is saved BEFORE the
// brightness moves (a crash in between leaves something to give back), and `-` is "nothing": the deep step saves nothing, and a panel
// that is off has nothing to set.
var SET_SH = [
    '[ -n "$5" ] || exit 6',
    'if [ "$3" != "-" ]; then echo "$3" > "$1" || exit 5; fi',
    'if [ "$4" != "-" ]; then exec "$2" -c backlight -d "$5" set "$4"; fi'
].join("\n");

function _int(t) {
    return /^[0-9]+$/.test(String(t)) ? Number(t) : NaN;
}

// The raw value a step sets: `level` of the PERCEIVED position of `full` on the OSD's ladder. `Osd` is OsdKinds.js (the module object:
// brightnessRungs, brightnessPos, brightnessRawAt), `max` the panel's maximum, `ladder` { gamma, step, floorRaw } (any field missing
// takes OsdKinds' default). 0 means "set nothing": a full value of 0 is the user's (the panel is off), and soft never raises it.
// Otherwise never below 1 and never above `full`.
function stepRaw(Osd, full, max, level, ladder) {
    var f = Math.round(Number(full));
    if (!(f > 0))
        return 0;
    var m = Math.max(1, Math.round(Number(max)));
    f = Math.min(f, m);
    var o = ladder || {};
    var rungs = Osd.brightnessRungs(m, o.gamma, o.step, o.floorRaw);
    // (+1e-9: an exact half raw unit rounds UP, always -- float noise in level * position must not decide it)
    var raw = Osd.brightnessRawAt(level * Osd.brightnessPos(f, rungs) + 1e-9, rungs);
    return Math.min(f, Math.max(1, raw));
}

// What READ_SH said, turned into what to do. `arg`: DIM_ARG | DEEP_ARG; `text`: READ_SH's output; `s`: the settings (dimLevel, deepLevel,
// stateFile). -> { ok: false, why } when there is nothing to go on, else { ok: true, full, max, save, target }:
// `save` the number to write to the state file (null: leave it alone), `target` the raw value to set (0: set nothing).
function decide(Osd, arg, text, s, ladder) {
    var p = String(text === undefined || text === null ? "" : text).trim().split(/\s+/);
    var g = _int(p[0]);
    var m = _int(p[1]);
    var saved = p.length > 2 ? _int(p[2]) : NaN;
    if (!(m >= 1) || !(g >= 0))
        return { ok: false, why: "no reading of the backlight" };
    if (arg === DIM_ARG)
        return { ok: true, full: g, max: m, save: g, target: stepRaw(Osd, g, m, s.dimLevel, ladder) };
    if (!(saved >= 0))
        return { ok: false, why: "no saved brightness in " + s.stateFile };
    // the deep step never raises: wherever the panel is now is its ceiling
    return { ok: true, full: saved, max: m, save: null, target: Math.min(g, stepRaw(Osd, saved, m, s.deepLevel, ladder)) };
}

// The argv a step starts with: the script's own flag for --resume; for dim and deep the READ snippet (the SET snippet follows, setArgv).
function argvOf(arg, s) {
    if (arg === DIM_ARG || arg === DEEP_ARG)
        return ["bash", "-c", READ_SH, "idle-read", s.stateFile, s.brightnessctl, String(s.device || "")];
    return ["bash", s.script, arg];
}

// The argv that does what decide() said.
function setArgv(s, save, target) {
    return ["bash", "-c", SET_SH, "idle-set", s.stateFile, s.brightnessctl, save === null || save === undefined ? "-" : String(save), target > 0 ? String(target) : "-", String(s.device || "")];
}

function _step(level) {
    return { arg: FLAG[level], end: level };
}

// The level the panel should be at. `active`: soft is the applied mode. `idleLevel`: 0 | 1 | 2 from the input idleness.
// `awayDimmed`: the attention has been elsewhere long enough. `current`: the level the panel is at (or on its way to).
//
// While the attention is away the panel never LIGHTENS from deep to dimmed: it is looked at by nobody, deep is the kinder level
// for an OLED, and the only way back to a dimmed panel is a resume followed by a dim -- a flash of full brightness.
function target(active, idleLevel, awayDimmed, current) {
    if (!active)
        return FULL;
    var away = awayDimmed ? Math.max(DIM, Math.min(DEEP, current)) : FULL;
    return Math.max(idleLevel, away);
}

// The steps, in order, that take the panel from level `from` to level `to`:
// [{ arg: "dim", end: 1 }, ...] -- `end` is the level each one leaves behind.
function planSteps(from, to) {
    if (from === to)
        return [];
    if (to === FULL)
        return [_step(FULL)];
    if (from === FULL)
        return to === DIM ? [_step(DIM)] : [_step(DIM), _step(DEEP)];
    if (from === DIM)
        return [_step(DEEP)];
    return [_step(FULL), _step(DIM)];
}

// Is this output the laptop panel? `panel` is a name prefix ("eDP" is eDP-1); case does not matter.
function isPanel(name, panel) {
    var p = String(panel || "").toLowerCase();
    return p !== "" && String(name || "").toLowerCase().indexOf(p) === 0;
}

// Where the attention is. `monitors`: [{ name }] (the outputs that are on), `focused`: the focused output's name ("" = unknown),
// `panel`: the laptop panel's name prefix. -> { panelPresent, externalPresent, onPanel, away }
// `away`: there is a panel to protect, an external output beside it, and the focus is on the external one. An unknown focus is
// not away (nothing is dimmed on a guess).
function attention(monitors, focused, panel) {
    var panelPresent = false;
    var externalPresent = false;
    var list = Array.isArray(monitors) ? monitors : [];
    for (var i = 0; i < list.length; i++) {
        if (isPanel(list[i].name, panel))
            panelPresent = true;
        else
            externalPresent = true;
    }
    var f = String(focused || "");
    var onPanel = f === "" || isPanel(f, panel);
    return { panelPresent: panelPresent, externalPresent: externalPresent, onPanel: onPanel, away: panelPresent && externalPresent && !onPanel };
}
