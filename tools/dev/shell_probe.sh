#!/usr/bin/env bash
# shell_probe.sh -- the REAL shell.qml (SHELL_SERVICES=mock) in the isolated nested Hyprland of tools/dev/lock_env.sh, on two
# outputs with the second ABOVE the first as the user's ultrawide is (stream F2). Nothing shows on the user's screen and
# nothing of theirs is touched: the compositor, its bus, its runtime dir and the XDG homes are lock_env's; every quickshell
# runs from a sandbox copy of this tree; only the pids this script started are killed. Ends in SHELL_PROBE RESULT PASS|FAIL.
#
#   tools/dev/shell_probe.sh                     all groups
#   ONLY="p3 p9" tools/dev/shell_probe.sh        some groups (see tools/dev/shell_platform_probe.py)
#   SCALE=1.25 tools/dev/shell_probe.sh          the shell's configured global scale (shell.json's `scale.global`, written into the
#                                            mock config before the shell starts); the checks speak design px to the shell and
#                                            logical px to the compositor (round 2, stream SC)
#   HYPR_SCALE=1.5 tools/dev/shell_probe.sh      Hyprland's own scale of LOCK-1 (LOCK-2 stays 1): the shell's size must not move
#   SCALE_OUT2=1.75 tools/dev/shell_probe.sh     LOCK-2 gets its OWN entry in shell.json (`scale.outputs.LOCK-2.global`), which wins over the
#                                            block's global: with SCALE=1.25 HYPR_SCALE=1.5 the two outputs run at three different numbers
#   BAR_RATIO=1.25 POPUP_RATIO=1.5 tools/dev/shell_probe.sh   shell.json's `scale.bar` / `scale.popup` (round 2, stream EL): the main bar, its
#                                            reserve, its mask, the modules' clicks and the keyboard at the bar's ratio, the popups' boxes at the
#                                            popup's (p2 .. p5, p9, p12 and p14 speak them); they stack with SCALE and HYPR_SCALE
#   ARM=<a> tools/dev/shell_probe.sh             one fault patched into the run's own sandbox copy; the run must FAIL
#   ARM=all tools/dev/shell_probe.sh             every ARM below, each must fail its own check
#
# What it holds (tools/dev/shell_platform_probe.py has the checks):
#   p1  the ready line, the mock mode, `status`, the service census (exactly one of each, no BatteryData), the nine hosted
#       owners take `shellHosted` and the OSD owner reads the focus tracker
#   p2  hyprctl's layers: lares-bar on the TOP layer on each output and no other window of the shell at rest; the main bar reserves 40, the slim bars 0
#   p3  the input mask on a REAL compositor: a click on an island is the shell's; on the slim bars, in the void between islands,
#       under an island and in the middle it reaches the window under (a client of its own: tools/dev/qml/shell_platform_probe.qml)
#   p4  every button's real click opens its popup on its outlet (notes out of the left bar, the rest on the island that holds the
#       button) on the output it was clicked on; p5 the layer's keyboard mode the compositor holds is the one the engine asks for
#   p6  the reels open on hover and close when the pointer leaves
#   p7  the shortcuts (`hyprctl dispatch hl.dsp.global(...)`, a press and no release) act on the FOCUSED output, which follows the
#       pointer between the two outputs
#   p8  the OSD comes out on the focused output only
#   p9  the bars toggle: reserve released, every bar gone (0 px), the pointer passes where the island was; the key does the same
#   p10 the aggregation on the real screens: one output closing does not drop what the other still holds
#   p11 a plugged output gets its bars, an unplugged one loses them, nothing is built twice
#   p15 an output replaced in one go keeps its frame in the registry (ARM replacedframe)
#   p12 the scale: the frame's Item scale and render scale, the slim bars' 6 compositor px, the island's foot and an open popup's
#       box where the scale puts them (real clicks); meaningful at SCALE / HYPR_SCALE other than 1 (it holds at 1 too)
#   p13 (only when named, with SHP_WATCH=1) the scale is hot where the file watcher is on: shell.json rewritten, the frame follows
#   p14 the ratios: the configured ones, the bar and the outlets, the modules inside the scaled islands, a popup's box = its content x the
#       popup's ratio, a reel strip's = its content x the BAR's (it continues its bar cell)
# SHELL_FOCUS=live gives the mock's FocusedScreen the nested compositor's focus (it follows the pointer between outputs).
#
# THE TRIPWIRES. The copy is patched (tools/dev/shell_tripwires.py) so that any real service a mock must never build logs TRIPWIRE;
# one in the shell's log fails the run.
#
# ARMs (each patches ONE thing in the sandbox copy; it must fail the check it names, and the shell must have loaded):
#   slimmask     the slim bars take input again -- their rects are in the mask                             p3
#   nomask       the window has no input region at all                                                     p3
#   nolayer      the bar window is on the Bottom layer, not Top                                            p2
#   nokeyboard   the layer's keyboard mode is never mapped from the engine                                 p5
#   noreserve    the main bar reserves nothing                                                             p2
#   noaggregate  a service flag is the LAST screen's, not the OR of all                                    p10
#   allosd       every screen presents the OSD (every owner is told it is active)                                         p8
#   nohosted     the launcher owner is not told it is hosted (it would build its own service)                               p1
# The scale ARMs run at SCALE=1.25 (noindep at HYPR_SCALE=1.5 as well), where they bite:
#   noscale      the frame is not scaled (ScaleRoot's factor is 1)                                                         p12
#   fixedreserve the output's reserve is the engine's in design px, not x k                                                p2
#   fixedslim    the outlet bars are 6 design px, not 6 / k                                                                p12
#   noindep      the frame's scale is the configured number, not divided by the window's pixel ratio                      p12
#   nooutputs    the per-output entries of the scale block are ignored (LOCK-2 gets the global)                            p12 (SCALE_OUT2)
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT="$PWD"
. "$ROOT/tools/dev/result_lib.sh"
E="$ROOT/tools/dev/lock_env.sh"
export LOCK_ENV="${LOCK_ENV:-shp0}"
SANDBOX="${SANDBOX:-${SCRATCH:-/tmp}/lares-sandbox-shp}"
SCR="${SCRATCH:-/tmp}/shellprobe-$LOCK_ENV"
ONLY="${ONLY:-}"
ARMS_ALL="slimmask nomask nolayer nokeyboard noreserve noaggregate allosd nohosted noscale fixedreserve fixedslim noindep nooutputs noratiobar noratiopopup nozonerow nothick"
SCALE="${SCALE:-1}"
HYPR_SCALE="${HYPR_SCALE:-1}"
SCALE_OUT2="${SCALE_OUT2:-}"
BAR_RATIO="${BAR_RATIO:-1}"
POPUP_RATIO="${POPUP_RATIO:-1}"
export SCALE HYPR_SCALE SCALE_OUT2 BAR_RATIO POPUP_RATIO

if [ "${ARM:-}" = "all" ]; then
    rc=0
    # the group each ARM must fail (a stale anchor that breaks something ELSE proves nothing)
    declare -A NEED=([slimmask]="p3" [nomask]="p3" [nolayer]="p2" [nokeyboard]="p5" [noreserve]="p2" [noaggregate]="p10" [allosd]="p8" [nohosted]="p1"
                     [noscale]="p12" [fixedreserve]="p2" [fixedslim]="p12" [noindep]="p12" [nooutputs]="p12"
                     [noratiobar]="p2" [noratiopopup]="p14" [nozonerow]="p4" [nothick]="p12" [replacedframe]="p15")
    for a in ${ONLY_ARMS:-$ARMS_ALL}; do
        # the scale ARMs need a scale to bite on
        ascale="$SCALE"; ahypr="$HYPR_SCALE"; aout="$SCALE_OUT2"; abar="$BAR_RATIO"; apop="$POPUP_RATIO"
        case "$a" in noscale|fixedreserve|fixedslim) [ "$ascale" = 1 ] && ascale=1.25 ;; noindep) [ "$ascale" = 1 ] && ascale=1.25; [ "$ahypr" = 1 ] && ahypr=1.5 ;; nooutputs) [ "$ascale" = 1 ] && ascale=1.25; [ -z "$aout" ] && aout=1.75 ;; esac
        # the ratio ARMs need a ratio to bite on
        case "$a" in noratiobar|nozonerow|nothick) [ "$abar" = 1 ] && abar=1.25 ;; noratiopopup) [ "$apop" = 1 ] && apop=1.25 ;; esac
        out=$(ARM="$a" ONLY="$ONLY" SCALE="$ascale" HYPR_SCALE="$ahypr" SCALE_OUT2="$aout" BAR_RATIO="$abar" POPUP_RATIO="$apop" SANDBOX="$SANDBOX-$a" LOCK_ENV="${LOCK_ENV}${a:0:3}" SCRATCH="${SCRATCH:-/tmp}" bash "$0" 2>&1)
        # the armed run failed (it was meant to), so its logs stayed; the sweep has read what it needs of them
        _armscr="${SCRATCH:-/tmp}/shellprobe-${LOCK_ENV}${a:0:3}"
        [ "${SHP_KEEP:-0}" = 1 ] || rm -rf "$_armscr"
        # the no-result verdict by its own text too, not only through result_lib (ARM=armload of runner_noload_check)
        if rl_isnoresult "$out" || printf '%s\n' "$out" | grep -qF "RESULT FAIL (no result: "; then
            echo "ARM $a: NOT PROVEN (the armed copy did not load)"; rc=1
        elif printf '%s\n' "$out" | grep -q "^SHELL_PROBE RESULT FAIL" && printf '%s\n' "$out" | grep -qE "^ *${NEED[$a]}\.[^ ]* FAIL"; then
            echo "ARM $a: FAILED AS IT MUST ($(printf '%s\n' "$out" | grep -E "^ *${NEED[$a]}\.[^ ]* FAIL" | head -1 | sed 's/^ *//' | cut -c1-120))"
        elif printf '%s\n' "$out" | grep -q "^SHELL_PROBE RESULT FAIL"; then
            echo "ARM $a: FAILED, BUT NOT AT ITS OWN CHECK (${NEED[$a]}): $(printf '%s\n' "$out" | grep -E ' FAIL ' | head -1 | sed 's/^ *//' | cut -c1-110)"; rc=1
        else
            echo "ARM $a: STAYED GREEN"; rc=1
        fi
    done
    [ "$rc" = 0 ] && echo "SHELL_PROBE ARMS RESULT PASS" || echo "SHELL_PROBE ARMS RESULT FAIL"
    exit "$rc"
fi

# THE CLEAN-UP RUNS ON EVERY WAY OUT (the end, an error, ^C, a TERM, a closed terminal): `lock_env down` kills every process of
# the nested env by its marker -- the compositor, its host, its bus, the pointer and whatever quickshell is left -- so a run
# that is cut short leaves nothing under init (a nested shell, a host compositor and a bus sat there for 8 hours once).
QPID=""; SPID=""; _cleaned=0; _ok=0
cleanup() {
    [ "$_cleaned" = 1 ] && return
    _cleaned=1
    [ -n "$SPID" ] && kill "$SPID" 2> /dev/null
    [ -n "$QPID" ] && kill "$QPID" 2> /dev/null
    "$E" down > /dev/null 2>&1
    wait 2> /dev/null
    # The copy always goes; the logs go with a PASS only -- a failed run's logs are what the verdict line names (SHP_KEEP=1
    # keeps them anyway; not KEEP, which is lock_env's own: it keeps the whole nested env).
    rm -rf "$SANDBOX"
    [ "$_ok" = 1 ] && [ "${SHP_KEEP:-0}" != 1 ] && rm -rf "$SCR"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP
rm -rf "$SCR"; mkdir -p "$SCR"
SANDBOX="$SANDBOX" tools/dev/sandbox.sh > /dev/null || { echo "SHELL_PROBE RESULT FAIL (the sandbox did not sync)"; exit 1; }
SB="$SANDBOX"
python3 tools/dev/shell_tripwires.py "$SB" || { echo "SHELL_PROBE RESULT FAIL (the tripwires did not go in)"; exit 1; }

arm() {  # file count from to
    python3 - "$@" <<'PY' || { echo "ARM ${ARM:-}: anchor check failed"; exit 2; }
import sys
p, n, a, b = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
s = open(p, encoding="utf-8").read()
c = s.count(a)
if c != n:
    print(f"FAIL  anchor found {c} times in {p}, expected {n}: {a[:70]!r}")
    sys.exit(1)
open(p, "w", encoding="utf-8").write(s.replace(a, b))
PY
    echo "ARMED ${ARM:-} in $(basename "$1")"
}
case "${ARM:-}" in
    "") ;;
    slimmask) arm "$SB/modules/shell/ShellLayout.js" 1 'out.push(_bar("bottom", "bottom", 0, W, slim, 0, false));' 'out.push(_bar("bottom", "bottom", 0, W, slim, 0, true));' ;;
    nomask) arm "$SB/modules/shell/ShellScreen.qml" 1 '    mask: !win.presented ? heldMask : win.locked ? lockedMask : gooeyMask' '' ;;
    nolayer) arm "$SB/modules/shell/ShellScreen.qml" 1 '    WlrLayershell.layer: win.overlayWanted ? WlrLayer.Overlay : WlrLayer.Top' '    WlrLayershell.layer: WlrLayer.Bottom' ;;
    nokeyboard) arm "$SB/modules/shell/ShellScreen.qml" 1 '    WlrLayershell.keyboardFocus: win.locked ? WlrKeyboardFocus.None
        : screenFrame.engine.keyboardFocus === "exclusive" ? WlrKeyboardFocus.Exclusive
        : screenFrame.engine.keyboardFocus === "onDemand" ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None' '    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None' ;;
    noreserve) arm "$SB/modules/shell/ShellFrame.qml" 1 '    readonly property bool reserveOn: frame.barsShown && frame.toggleT < 0.001' '    readonly property bool reserveOn: false' ;;
    nohosted) arm "$SB/modules/shell/ShellFrame.qml" 1 '        shellHosted: true
        service: frame.services.launcher' '        service: frame.services.launcher' ;;
    noscale) arm "$SB/modules/shell/ShellScreen.qml" 1 '    readonly property real frameScale: ShellScale.frameScale(body, win.outputName)' '    readonly property real frameScale: 1' ;;
    fixedreserve) arm "$SB/modules/shell/ShellScreen.qml" 1 'reserveSrc.ring, win.frameScale, screenFrame.reserveOn)' 'reserveSrc.ring, 1, screenFrame.reserveOn)' ;;
    fixedslim) arm "$SB/modules/shell/ShellFrame.qml" 1 '    readonly property real slim: 6 / Math.max(0.01, frame.frameScale)' '    readonly property real slim: 6' ;;
    noindep) arm "$SB/modules/shell/scale/ShellScale.qml" 1 '        return root.configured(name, "frame") / root.dpr(item);' '        return root.configured(name, "frame");' ;;
    nooutputs) arm "$SB/modules/shell/scale/ScaleConfig.js" 1 '    const e = _has(cfg.outputs, name) ? cfg.outputs[name] : {};' '    const e = {};' ;;
    noratiobar) arm "$SB/modules/shell/ShellScreen.qml" 1 '                barRatio: ShellScale.ratio(win.outputName, "bar")' '                barRatio: 1' ;;
    noratiopopup) arm "$SB/modules/bar/gooey/GooeyBody.qml" 1 '        return Math.max(0.01, bar ? e.barRatio : e.popupRatio);' '        return Math.max(0.01, bar ? e.barRatio : 1);' ;;
    nozonerow) arm "$SB/modules/shell/ShellFrame.qml" 1 '        factor: frame.barRatio
        hostWidth: frame.lengths[row.zone] * frame.barRatio' '        factor: 1
        hostWidth: frame.lengths[row.zone] * frame.barRatio' ;;
    nothick) arm "$SB/modules/shell/ShellLayout.js" 1 '    const top = thicknessAt(TOP * k, hide), slim = thicknessAt(SLIM, hide);' '    const top = thicknessAt(TOP, hide), slim = thicknessAt(SLIM, hide);' ;;
    allosd) arm "$SB/modules/shell/ShellFrame.qml" 1 '        focusSource: frame.services.focus
        fullscreenMode: frame.services.osd.config.config.fullscreen' '        focusSource: frame.services.focus
        active: true
        fullscreenMode: frame.services.osd.config.config.fullscreen' ;;
    replacedframe) arm "$SB/modules/shell/ShellFrame.qml" 1 '        if (frame.services.frames[frame.screenName] !== frame)
            return;
' '' ;;
    noaggregate) arm "$SB/modules/shell/ShellServices.qml" 1 '                if (sf && sf[row.flag] === true)
                    v = true;' '                v = !!(sf && sf[row.flag] === true);' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac

# ---- the compositor: two outputs, the second above the first -------------------------------------------------------
"$E" down > /dev/null 2>&1
OUTPUTS=2 "$E" up > /dev/null || { echo "SHELL_PROBE RESULT FAIL (the nested Hyprland did not come up)"; exit 1; }
if [ "$HYPR_SCALE" = 1 ]; then
    "$E" hyprctl eval 'hl.monitor({ output = "LOCK-2", mode = "3440x1440@60", position = "-280x-1440", scale = 1 })' > /dev/null
else
    # LOCK-1 at Hyprland's own scale (its layout is 2880 / scale logical px wide), LOCK-2 centred above it at scale 1
    lx=$(python3 -c "print(round((2880 / $HYPR_SCALE - 3440) / 2))")
    "$E" hyprctl eval "hl.monitor({ output = \"LOCK-1\", mode = \"2880x1620@60\", position = \"0x0\", scale = $HYPR_SCALE })" > /dev/null
    "$E" hyprctl eval "hl.monitor({ output = \"LOCK-2\", mode = \"3440x1440@60\", position = \"${lx}x-1440\", scale = 1 })" > /dev/null
fi
"$E" hyprctl eval 'hl.config({ general = { gaps_out = 6 } })' > /dev/null
# the bars do not fade in and out (the trial tool installs the same rule; layerrules.lua at the cutover)
"$E" hyprctl eval 'hl.layer_rule({ name = "lares_bar_noanim", match = { namespace = "^lares-bar$" }, no_anim = true })' > /dev/null
sleep 1

CLOG="$SCR/client.log"; SLOG="$SCR/shell.log"
"$E" run env SHP_MODE=bg QS_DISABLE_CRASH_HANDLER=1 quickshell -n -p "$SB/tools/dev/qml/shell_platform_probe.qml" > "$CLOG" 2>&1 &
QPID=$!
for _ in $(seq 1 100); do grep -aq "SHP ready" "$CLOG" 2> /dev/null && break; sleep 0.2; done
grep -aq "SHP ready" "$CLOG" || { rl_noresult SHELL_PROBE "$CLOG"; exit 1; }

# The scale: shell.json's `scale.global`, in the mock's config dir, before the shell starts (the mock reads its files from
# <state>/lares-shell-mock/config/). Hot, so a probe may rewrite it later.
if [ "$SCALE" != 1 ] || [ -n "$SCALE_OUT2" ] || [ "$BAR_RATIO" != 1 ] || [ "$POPUP_RATIO" != 1 ] || [ "${SHP_WATCH:-0}" = 1 ]; then      # (a watched file has to exist when the shell starts: p13 rewrites it)
    mkdir -p "$("$E" dir)/state/lares-shell-mock/config"
    if [ -n "$SCALE_OUT2" ]; then
        printf '{ "scale": { "global": %s, "bar": %s, "popup": %s, "outputs": { "LOCK-2": { "global": %s } } } }\n' "$SCALE" "$BAR_RATIO" "$POPUP_RATIO" "$SCALE_OUT2" > "$("$E" dir)/state/lares-shell-mock/config/shell.json"
    else
        printf '{ "scale": { "global": %s, "bar": %s, "popup": %s } }\n' "$SCALE" "$BAR_RATIO" "$POPUP_RATIO" > "$("$E" dir)/state/lares-shell-mock/config/shell.json"
    fi
fi

# The shell, mock services, the mock's focus following the nested compositor's pointer. A private runtime, config, state
# and cache are lock_env's; HOME is the user's but nothing below HOME is written (the mock keeps to the state dir).
# (SHP_WATCH=1 leaves the file watcher ON, for p13: the scale is hot where it is; the trial runs with it off)
WATCHENV="QS_DISABLE_FILE_WATCHER=1"; [ "${SHP_WATCH:-0}" = 1 ] && WATCHENV="LARES_WATCH_ON=1"
"$E" run env SHELL_SERVICES=mock SHELL_FOCUS=live QS_DISABLE_CRASH_HANDLER=1 "$WATCHENV" quickshell -n -p "$SB/shell.qml" > "$SLOG" 2>&1 &
SPID=$!
for _ in $(seq 1 300); do
    grep -aq "LARES ready" "$SLOG" 2> /dev/null && break
    kill -0 "$SPID" 2> /dev/null || break
    sleep 0.3
done
grep -aq "LARES ready" "$SLOG" || { rl_noresult SHELL_PROBE "$SLOG"; exit 1; }
sleep 2   # the first frames, the fonts, the silicon / launcher first-use compile are not what is judged

# ---- the checks --------------------------------------------------------------------------------------------------------------
# shellcheck disable=SC2086
python3 tools/dev/shell_platform_probe.py "$ROOT" "$SB" "$LOCK_ENV" "$CLOG" "$SLOG" $ONLY 2>&1 | tee "$SCR/checks.log" | grep -a "SHELL_PLATFORM" | grep -av "SHELL_PLATFORM p5.table" | sed 's/^SHELL_PLATFORM /    /'
rc=${PIPESTATUS[0]}
grep -a "SHELL_PLATFORM p5.table" "$SCR/checks.log" | sed 's/^SHELL_PLATFORM /    /'

fail=0
[ "$rc" = 0 ] || fail=1
trips=$(rl_clean "$SLOG" | grep -a "TRIPWIRE" | sed 's/.*TRIPWIRE //' | sort | uniq -c | sed 's/^ *//' | tr '\n' ';')
if [ -n "$trips" ]; then echo "    FAIL tripwires: a mock built a real service: $trips"; fail=1; fi
kill -0 "$SPID" 2> /dev/null || { echo "    FAIL the shell died during the run (see $SLOG)"; fail=1; }
warns=$(rl_clean "$SLOG" | rl_platform_noise | grep -aE "^\s*(WARN|ERROR)|Unable to assign|Binding loop|non-existent property" \
    | grep -avE "quickshell.tooling|--- WARNING ---|actually running wayland|does not support setting window masks|Failed to register with host portal|Could not load icon \"(nm-signal-50|internet-chat|blueman-disabled)\"")
if [ -n "$warns" ] && [ -z "${ARM:-}" ]; then
    echo "    FAIL the shell's log complains:"
    printf '%s\n' "$warns" | sed 's/^ *//' | sort | uniq -c | sort -rn | head -12 | sed 's/^/        /'
    fail=1
fi
if [ "$fail" = 0 ]; then
    s=$(grep -a "SHELL_PLATFORM SUMMARY" "$SCR/checks.log" | tail -1 | sed 's/.*SUMMARY //')
    echo "SHELL_PROBE RESULT PASS ($s)"
    _ok=1
    exit 0
fi
echo "SHELL_PROBE RESULT FAIL ($(grep -a "SHELL_PLATFORM SUMMARY" "$SCR/checks.log" | tail -1 | sed 's/.*SUMMARY //'))"
exit 1
