#!/usr/bin/env bash
# tools/dev/tray_pocket_probe.sh -- THE POCKET (GooeyGeometry.js) never drops a frame while the tray's label goes from one
# item to the next (feedback window+tray "Secondary connection to bar": hovering from Proton Pass, a one-line label, to KDE
# Connect, two lines and wider, "the narrowing down U shape ... can jitter a hole in and out rapidly").
#
#   tools/dev/tray_pocket_probe.sh [<out>]          TRAYPOCKET RESULT PASS | FAIL
#   SCALE=1.25 (the user's)  TP_SLOW=4  TP_DELAYS=700,120  TP_TITLES='<t>|<t>'  TP_ORDERS="thin,thick thick,thin"
#   ARM=outcorner  the fault, in the copy: the pocket refused again wherever the closing body's open-end corner is the outer
#                  piece of another join's S, loose or not (the island's end corner and its slim side bar's S: round 5's
#                  rule) -> the judge must FAIL on `pocket dropped` and `hole flickered` (the title that ends the island
#                  inside the label's widening)
#
# THE RECORDING. tools/dev/qml/tray_pocket_record.qml builds the shell's own frame (mockups/shell.qml, mock services, the
# user's border and halo, scale 1.25) in a tools/dev/sandbox.sh copy, offscreen (the software scene graph: only the engine's
# layout is read, nothing is drawn), gives the mock tray the session's two items, and for each of three window titles (the
# left island ends where its title does: inside the thin label, inside the thick label's widening, past both) pins the strip
# and plays each leg as a pointer does (icon A's label out or still opening, then the pointer onto icon B), printing the
# field's input every frame. The engine's child clocks run TP_SLOW times slower: more frames on the same curves. A run that
# warns (a binding loop, an assignment that failed, a script error) fails.
#
# THE JUDGE (tools/dev/tray_pocket_judge.js, no Qt) replays every frame through this tree's GooeyGeometry.fieldShape and, on
# every frame where the label stands within the pocket's reach under the bar beside its strip (the channel the user sees),
# demands the pocket: its fillets in the field's output (`pocket dropped` names the leg and the frames), and the air between
# label, strip and bar sampled on a quarter-pixel grid: it may only shrink as the label rises, never jump open for a frame
# and shut again (`hole flickered`).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1
. tools/dev/result_lib.sh
OUT="${1:-}"
# From a work tree: into a sandbox copy of it. Inside a copy already (no .git: shell_gates' box, runner_noload_check.sh): here.
if [ -e .git ] && [ -z "${TP_INNER:-}" ]; then
    own=0
    [ -z "$OUT" ] && { OUT="$(mktemp -d "${TMPDIR:-/tmp}/traypocket.XXXXXX")"; own=1; }
    mkdir -p "$OUT"
    OUT="$(cd "$OUT" && pwd)"
    sown=0
    [ -z "${SANDBOX:-}" ] && sown=1
    export SANDBOX="${SANDBOX:-/tmp/lares-sandbox-traypocket}"
    tools/dev/sandbox.sh -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE QT_QPA_PLATFORM=offscreen MOCKUP_REPO= TP_INNER=1 \
        tools/dev/tray_pocket_probe.sh "$OUT"
    rc=$?
    [ "$sown" = 1 ] && rm -rf "$SANDBOX"
    [ "$own" = 1 ] && [ "$rc" = 0 ] && rm -rf "$OUT"
    exit $rc
fi

# ---- inside the copy -------------------------------------------------------------------------------------------------
[ -e .git ] && { echo "TRAYPOCKET RESULT FAIL (the inner run stands in a work tree, not a sandbox copy)"; exit 1; }
[ -z "$OUT" ] && { OUT="$(mktemp -d "${TMPDIR:-/tmp}/traypocket.XXXXXX")"; echo "(logs: $OUT)"; }
mkdir -p "$OUT"
case "${ARM:-}" in
    "") ;;
    outcorner)
        python3 - <<'PY' || { echo "TRAYPOCKET RESULT FAIL (ARM outcorner: its anchor is gone)"; exit 1; }
p = "modules/bar/gooey/GooeyGeometry.js"
s = open(p, encoding="utf-8").read()
a = "&& !family(J.I) && !looseOut(J))"
if s.count(a) != 1:
    raise SystemExit(1)
open(p, "w", encoding="utf-8").write(s.replace(a, "&& !family(J.I))"))
print("ARM outcorner: an open-end corner that is any S's outer piece refuses the pocket")
PY
        ;;
    *) echo "TRAYPOCKET RESULT FAIL (unknown ARM ${ARM})"; exit 1 ;;
esac
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lares-tp.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/stubs"
for prog in nvidia-smi nvidia-modprobe systemd-run; do printf '#!/bin/sh\nexit 1\n' > "$WORK/stubs/$prog"; chmod +x "$WORK/stubs/$prog"; done
cp tools/dev/qml/tray_pocket_record.qml mockups/zz_tray_pocket.qml
bad=0
for order in ${TP_ORDERS:-thin,thick thick,thin}; do
    tag="${order/,/-}"
    d="$WORK/$tag"
    mkdir -p "$d/cfg/theme" "$d/state/lares-shell-mock/config" "$d/cache" "$d/data" "$d/rt"
    chmod 700 "$d/rt"
    printf '{"theme":"eva","mode":"light"}\n' > "$d/cfg/theme/state.json"
    # The user's shell.jsonc as it bears on the field (2026-11-09): the border ring widens the joints' radius and with it the
    # pocket's reach (2 x 18.8 px at scale 1.25, where the thick label rests 30 px under the bar: its pocket is half zipped at
    # rest); the halo and the aura add the sky's fillets.
    printf '{ "scale": { "global": %s }, "shadow": { "mode": "halo", "aura": true }, "border": true }\n' "${SCALE:-1.25}" \
        > "$d/state/lares-shell-mock/config/shell.jsonc"
    LOG="$OUT/$tag.log"
    env -i \
        HOME="$HOME" USER="${USER:-user}" PATH="$WORK/stubs:$PATH" LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 TZ=Europe/Brussels \
        XDG_RUNTIME_DIR="$d/rt" XDG_CONFIG_HOME="$d/cfg" XDG_STATE_HOME="$d/state" XDG_CACHE_HOME="$d/cache" XDG_DATA_HOME="$d/data" \
        QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software QT_QPA_PLATFORMTHEME= QT_LOGGING_RULES=qt.qpa.services.warning=false \
        QS_ICON_THEME=Papirus QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 LARES_SLEEP_MONITOR=off MOCKUP_REPO= \
        SHELL_SERVICES=mock ZOOM=1 SCALE="${SCALE:-1.25}" \
        TP_ORDER="$order" TP_DELAYS="${TP_DELAYS:-}" TP_TITLES="${TP_TITLES:-}" TP_SLOW="${TP_SLOW:-4}" \
        tools/dev/notifications_bus.sh timeout -k 5 600 quickshell -p mockups/zz_tray_pocket.qml > "$LOG" 2>&1
    # (a run that did not finish is no result, and the verdict: nothing after it)
    if ! rl_has "$LOG" "TPRECORD DONE"; then
        [ -n "${ARM:-}" ] && { echo "ARM $ARM: the armed copy did not load -- it proves nothing ($LOG)"; exit 1; }
        rl_noresult TRAYPOCKET "$LOG"; exit 1
    fi
    warned=$(rl_clean "$LOG" | grep -a -E "binding loop|Cannot assign|Unable to assign|TypeError|ReferenceError|is not a type" | head -3)
    [ -n "$warned" ] && { echo "TRAYPOCKET $tag: the run warned:"; echo "$warned" | sed 's/^/    /'; bad=1; }
    node tools/dev/tray_pocket_judge.js "$LOG" modules/bar/gooey/GooeyGeometry.js "$tag" | tee "$OUT/$tag.judge.txt"
    grep -aq "TRAYPOCKET $tag PASS" "$OUT/$tag.judge.txt" || bad=1
done
echo "TRAYPOCKET RESULT $([ $bad = 0 ] && echo PASS || echo "FAIL (logs: $OUT)")"
[ $bad = 0 ]
