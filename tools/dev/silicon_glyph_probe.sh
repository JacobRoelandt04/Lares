#!/usr/bin/env bash
# The bar's GPU glyph shows the true mode from its first frame, or nothing (round 7: after the boot back from dGPU-only the glyph
# drew Hybrid -- the fallback for "cardwire has not answered" -- until the popup opened and forced a read). The model's `gpu.known`,
# a CardwireClient whose first read of the daemon fails (a busy boot), and the button's GPU glyph (tools/dev/qml/silicon_glyph_probe.qml), offscreen
# in the sandbox on a private session bus with the cardwire stand-in (tools/dev/stubs/silicon/cardwire_stub.py) up, and a busctl shim that
# fails the first read of Mode.
#
#   tools/dev/silicon_glyph_probe.sh          last line: SILICON-GLYPH RESULT PASS|FAIL
#   ARM=guess       the model calls the fallback step a fact   -> model-unasked / -cardwire-unasked FAIL
#   ARM=slowretry   cardwire is asked again only a minute later (the old retry) -> client-reads-soon FAILS
#   ARM=draws       the glyph is drawn, live and armed before the mode is known -> button-hidden-unknown FAILS
#   ARM=nowire      the service does not tell the model whether cardwire was asked -> the static wire check FAILS
#   ARM=nohdmi      an external display on the card's HDMI does not count as in use (the faint glyph) -> model-hdmi-in-use FAILS
#   ARM=all         every ARM; SILICON-GLYPH ARMS PASS when each one failed
cd "$(dirname "$0")/../.." || exit 1
if [ -e .git ] && [ -z "${SGP_INNER:-}" ]; then
    SCRATCH="${SCRATCH:-/tmp/lares-scratch-silicon-glyph}"
    mkdir -p "$SCRATCH"
    exec env SANDBOX="${SANDBOX:-$SCRATCH/lares-sandbox}" SCRATCH="$SCRATCH" MOCKUP_REPO= tools/dev/sandbox.sh \
        QT_QPA_PLATFORM=offscreen SGP_INNER=1 ARM="${ARM:-}" bash tools/dev/silicon_glyph_probe.sh "$@"
fi
. tools/dev/result_lib.sh
SCRATCH="${SCRATCH:-/tmp}"
NAME="SILICON-GLYPH"

arm() {
    python3 - "$@" <<'PY'
import sys
p, a, b = sys.argv[1:4]
s = open(p, encoding="utf-8").read()
if s.count(a) != 1:
    print("ARM anchor found %d times in %s: %r" % (s.count(a), p, a[:80])); sys.exit(2)
open(p, "w", encoding="utf-8").write(s.replace(a, b))
PY
}

wire() {  # the service hands the model the facts that say cardwire / the helper were asked (the one link the probe cannot run)
    local f="$1/modules/silicon/data/SiliconService.qml"
    grep -q 'asked: cardwire.settled,' "$f" && grep -q 'answered: helperClient.answered' "$f" && return 0
    echo "SGLYPH wire: FAIL  SiliconService does not pass cardwire.settled / helperClient.answered to the model"
    echo "SGLYPH RESULT FAIL (wire)"
    return 1
}

run_once() {  # arm -> prints the verdict, returns its status
    local tree log out rc
    tree=$(mktemp -d "$SCRATCH/sgp.XXXXXX") || return 1
    rsync -a --exclude .git --exclude .qmlls.ini --exclude Screenshots ./ "$tree/" || return 1
    case "$1" in
        "") ;;
        guess) arm "$tree/modules/silicon/data/SiliconModel.js" 'known: (cw.asked !== false) && !(inp.helper && inp.helper.answered === false),' 'known: true,' || return 3 ;;
        slowretry) arm "$tree/modules/silicon/data/CardwireClient.qml" 'retry.interval = Math.min(root.retryMs, wait);' 'retry.interval = root.retryMs;' || return 3 ;;
        draws) arm "$tree/modules/silicon/bar/SiliconBarFace.qml" 'opacity: face.host.gpuKnown ? 1 : 0' 'opacity: 1' || return 3
               arm "$tree/modules/silicon/bar/SiliconBarFace.qml" 'live: face.host.liveMotion && face.host.gpuKnown' 'live: face.host.liveMotion' || return 3
               arm "$tree/modules/silicon/bar/SiliconBarFace.qml" 'known: face.host.gpuKnown' 'known: true' || return 3 ;;
        nowire) arm "$tree/modules/silicon/data/SiliconService.qml" 'asked: cardwire.settled, ' '' || return 3 ;;
        nohdmi) arm "$tree/modules/silicon/data/SiliconModel.js" ' || gpu.holders.length > 0 || display.hdmi);' ' || gpu.holders.length > 0);' || return 3 ;;
        *) echo "unknown ARM $1"; return 3 ;;
    esac
    wire "$tree" || return 1
    mkdir -p "$tree/xdg/config/theme" "$tree/xdg/state" "$tree/home"
    printf '{"theme":"eva","mode":"light"}\n' > "$tree/xdg/config/theme/state.json"
    log="$tree/run.log"
    # busctl shim: the daemon IS up but its first read of Mode fails (a busy boot's timeout), then everything is the real busctl
    mkdir -p "$tree/stubs"
    cat > "$tree/stubs/busctl" <<'SH'
#!/bin/sh
case " $* " in
    *" get-property "*" Mode "*)
        n=$(cat "$SHIM_COUNT" 2> /dev/null || echo 0)
        if [ "$n" -lt 1 ]; then
            echo $((n + 1)) > "$SHIM_COUNT"
            echo "Failed to get property Mode: Connection timed out" >&2
            exit 1
        fi ;;
esac
exec "$REAL_BUSCTL" "$@"
SH
    chmod +x "$tree/stubs/busctl"
    cat > "$tree/inner.sh" <<'SH'
#!/bin/bash
python3 tools/dev/stubs/silicon/cardwire_stub.py > stub.out 2>&1 &
spid=$!
for _ in $(seq 1 60); do grep -q 'cardwire-stub ready' stub.out 2> /dev/null && break; sleep 0.1; done
grep -q 'cardwire-stub ready' stub.out || echo "SGLYPH stub did not come up"
REAL_BUSCTL=$(command -v busctl) SHIM_COUNT="$PWD/shim.count" PATH="$PWD/stubs:$PATH" timeout 60 quickshell -n -p tools/dev/qml/silicon_glyph_probe.qml
kill "$spid" 2> /dev/null
SH
    chmod +x "$tree/inner.sh"
    ( cd "$tree" && env XDG_CONFIG_HOME="$tree/xdg/config" XDG_STATE_HOME="$tree/xdg/state" HOME="$tree/home" \
        tools/dev/notifications_bus.sh bash "$tree/inner.sh" > "$log" 2>&1 )
    out=$(rl_result "$NAME" "$log" "SGLYPH RESULT .*")
    rc=$?
    printf '%s\n' "$out"
    rl_clean "$log" | grep -a "SGLYPH .*FAIL" | head -4
    [ "$rc" = 0 ] || cp "$log" "$SCRATCH/last-fail.log" 2> /dev/null     # the work dir goes: a failed run's log stays
    rl_isnoresult "$out" || rm -rf "$tree"   # a no-result verdict names the log: keep it
    return $rc
}

if [ "${ARM:-}" = all ]; then
    bad=0
    for a in guess slowretry draws nowire nohdmi; do
        o=$(run_once "$a"); rc=$?
        if rl_isnoresult "$o"; then echo "ARM $a: did not load (proves nothing)"; bad=1
        elif [ "$rc" = 0 ]; then echo "ARM $a: still PASSES (toothless)"; bad=1
        else echo "ARM $a: failed as it must ($(printf '%s\n' "$o" | grep -a 'SGLYPH .*FAIL' | head -2 | tr '\n' ';'))"; fi
    done
    echo "$NAME ARMS $([ "$bad" = 0 ] && echo PASS || echo FAIL)"
    exit $bad
fi
out=$(run_once "${ARM:-}"); rc=$?
printf '%s\n' "$out"
if rl_isnoresult "$out"; then
    # the probe never loaded: result_lib's verdict (printed above) is the last word
    [ -n "${ARM:-}" ] && echo "ARM ${ARM}: the armed copy did not load -- it proves nothing"
    exit 1
fi
echo "$NAME RESULT $([ "$rc" = 0 ] && echo PASS || echo FAIL)"
exit $rc
