#!/usr/bin/env bash
# aerial's bar owner as the SHELL hosts it (docs/contracts/shell.md section 4),
# on a real gooey engine per screen, driven by synthetic clicks through the window.
# Headless, in its own sandbox. See tools/dev/qml/shell_hosted_m3_probe.qml for the verdicts
# (h0..h3).
#
#   tools/dev/shell_hosted_m3_probe.sh              last line: SHELL-HOSTED-M3 RESULT PASS|FAIL
#   ARM=<name> tools/dev/shell_hosted_m3_probe.sh   one fault armed in the SANDBOX copy; it must FAIL
#                                               its own check (last line: SHELL-HOSTED-M3 ARM ...)
#   ARM=all tools/dev/shell_hosted_m3_probe.sh      every arm in turn
#   VERBOSE=1                                   every sub-check, not only the verdicts
#
# THE ARMS, each patching the sandbox copy (never the tree), each watched red:
#   selfwrite     a hosted owner keeps writing the service's popupOpen (the Binding ignores
#                 shellHosted): two screens' owners would overrule each other
#                                                                      -> h1.writes-nothing
#   noflag        the owner's `aerialPopupOpen` flag is never up (the host would never hear a popup)
#                                                                      -> h1.a.flags-open
#   openonly      a click on the pill only ever opens (a second click does not close the popup)
#                                                                      -> h3.second-click-closes
#   scanonce      a second press of SCAN starts the search again instead of ending it (round 5's behaviour)
#                                                                      -> h2 (search ended / scan.second-press-stops)
#   noescstep     the engine's Escape ignores shell.jsonc `"escape": "detail"` (never asks stepBack)
#                                                                      -> h3.psk.escape-detail-first-puts-the-panel-away
#
# THE REAL SERVICE. Nothing here builds one: the owners are handed the mock, and the second
# launch (NSHM_PHASE=own) hands a hosted owner NOTHING -- a real AerialService starts the helper
# (python3, the system bus) and reads the machine. Every process is STUBBED first on PATH and
# logged (<epoch_ms> <tool> <argv>), nothing is forwarded to a real tool, and the QML refuses to
# build anything unless the stub directory is first on PATH. A clean run logs Theme's mkdir of its private state directory and nothing else.
#
# Private XDG_CONFIG_HOME (theme/state.json names the mode), XDG_STATE_HOME and
# XDG_CACHE_HOME: a launch that lets Theme write ~/.config/theme/state.json flips the user's
# real desktop. No `timeout` around quickshell: $! has to be quickshell itself, the only pid
# this script may kill.
set -u
cd "$(dirname "$0")/../.."
. tools/dev/result_lib.sh
if [ -e .git ] && [ -z "${NSHM_INNER:-}" ]; then
    export SANDBOX="${SANDBOX:-/tmp/lares-sandbox-shell-hosted}"
    exec tools/dev/sandbox.sh NSHM_INNER=1 QT_QPA_PLATFORM=offscreen SANDBOX="$SANDBOX" ARM="${ARM:-}" VERBOSE="${VERBOSE:-}" \
        bash tools/dev/shell_hosted_m3_probe.sh
fi
ROOT=$(pwd)
# Beside the sandbox rather than inside it: the next rsync --delete would take it.
OUT="${NSHM_OUT:-$ROOT-out}"
OWNER="modules/aerial/AerialBarOwner.qml"
PROBE="tools/dev/qml/shell_hosted_m3_probe.qml"

arm() {  # file, count, from, to
    [ -e .git ] && { echo "ARM patches the sandbox copy only; run through tools/dev/sandbox.sh"; exit 2; }
    python3 - "$@" <<'PYARM' || { echo "ARM $ARM: anchor not found the expected number of times"; exit 2; }
import sys
p, n, a, b = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
s = open(p, encoding="utf-8").read()
if s.count(a) != n:
    print("  found %d, want %d: %r" % (s.count(a), n, a[:70]))
    sys.exit(1)
open(p, "w", encoding="utf-8").write(s.replace(a, b))
PYARM
    echo "ARMED $ARM in $(basename "$1")"
}
apply_arm() {  # name
    case "$1" in
        selfwrite)    arm "$OWNER" 1 '        value: owner.sharedFlags.aerialPopupOpen
        when: !owner.shellHosted && !!owner.svc' '        value: owner.sharedFlags.aerialPopupOpen
        when: !!owner.svc' ;;
        noflag)       arm "$OWNER" 1 '            aerialPopupOpen: owner.popupMine,' '            aerialPopupOpen: false,' ;;
        openonly)     arm "$OWNER" 1 '        onClicked: owner.toggle()' '        onClicked: owner.open()' ;;
        scanonce)     arm "$OWNER" 1 '            s.bt.discovering ? s.btStopSearch() : s.btSearch();' '            s.btSearch();' ;;
        noescstep)    arm modules/bar/gooey/GooeyEngine.qml 1 '        if (engine.escapeDetailFirst && it && typeof it.stepBack === "function" && it.stepBack() === true)' '        if (false)' ;;
        *) echo "unknown ARM=$1"; exit 2 ;;
    esac
}
needle() {  # arm -> "<log> <text that must read FAIL>"
    case "$1" in
        selfwrite)    echo "main FAIL h1.writes-nothing" ;;
        noflag)       echo "main FAIL h1.a.flags-open" ;;
        openonly)     echo "main FAIL h3.second-click-closes" ;;
        scanonce)     echo "main FAIL h2.scan.second-press-stops" ;;
        noescstep)    echo "main FAIL h3.psk.escape-detail-first-puts-the-panel-away" ;;
    esac
}

# ---- the stubs ------------------------------------------------------------------
# One tab-separated line per invocation: <epoch_ms> <tool> <argv>. nmcli answers the profile
# list from the same capture the service probes use and refuses anything else; nothing is
# ever forwarded to a real tool except `mkdir`, under the private XDG_CACHE_HOME / CONFIG.
stubs() {  # dir
    mkdir -p "$1"
    for t in nmcli protonvpn nm-connection-editor blueman-manager bluetoothctl rfkill python3 iw; do
        cat > "$1/$t" <<SH
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "\$(date +%s%3N)" "$t" "\$*" >> "\${STUB_LOG:?}"
echo "$t stub: this probe never runs the real one" >&2
exit 2
SH
    done
    cat > "$1/mkdir" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "$(date +%s%3N)" "mkdir" "$*" >> "${STUB_LOG:?}"
exec /usr/bin/mkdir "$@"
SH
    chmod +x "$1/"*
    for t in nmcli python3; do
        local resolved
        resolved=$(PATH="$1:$PATH" command -v "$t")
        if [ "$resolved" != "$1/$t" ]; then
            echo "FAIL runner: $t resolves to $resolved, not the stub -- refusing to launch"
            return 1
        fi
    done
}

# one launch: <tag> <phase> -> $OUT/<tag>.log, $OUT/<tag>_stub.log
launch() {
    local tag="$1" phase="$2" limit="$3" pid
    : > "$OUT/${tag}_stub.log"
    env -u WAYLAND_DISPLAY \
        PATH="$OUT/stub:$PATH" NSHM=1 NSHM_PHASE="$phase" NSHM_STUB_DIR="$OUT/stub" \
        STUB_LOG="$OUT/${tag}_stub.log" \
        XDG_CONFIG_HOME="$OUT/cfg" XDG_STATE_HOME="$OUT/state" XDG_CACHE_HOME="$OUT/cache" \
        QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi \
        QT_LOGGING_RULES="qt.qpa.services.warning=false" \
        quickshell -p "$PROBE" > "$OUT/$tag.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 "$limit"); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
    if kill -0 "$pid" 2>/dev/null; then
        echo "FAIL runner: the $tag launch is still running after $((limit / 4)) s, killing $pid"
        kill "$pid" 2>/dev/null; sleep 0.5; kill -9 "$pid" 2>/dev/null
    fi
    wait "$pid" 2>/dev/null
}

warnings() {  # log
    rl_clean "$1" \
        | grep -a -E "^\s*(WARN|ERROR)|Unable to assign|Binding loop|non-existent property|ReferenceError|TypeError|is not defined|is not a function" \
        | grep -a -v -E "WAYLAND_DISPLAY|WARNING ---|actually running|window masks|quickshell.tooling" | sort | uniq -c
}

# One full run on the tree as it is (or as ARM armed it): both launches. Echoes the verdict
# lines and sets RUN_FAIL=1 when anything is red. LOGS: $OUT/main.log, $OUT/own.log.
run_all() {
    RUN_FAIL=0
    rm -rf "$OUT/main.log" "$OUT/own.log"
    launch main "" 520
    launch own own 120
    local main own
    main=$(rl_clean "$OUT/main.log" | sed 's/^ *DEBUG qml: //; s/^ *INFO qml: //')
    own=$(rl_clean "$OUT/own.log" | sed 's/^ *DEBUG qml: //; s/^ *INFO qml: //')
    if [ "${VERBOSE:-}" = "1" ]; then
        printf '%s\n' "$main" | grep -a -E "^ *(ok|FAIL) |^NOTE "
    else
        printf '%s\n' "$main" | grep -a -E "^  FAIL |^NOTE |^FAIL watchdog"
    fi
    printf '%s\n' "$main" | grep -a -E "^(PASS|FAIL) h[0-9]"
    printf '%s\n' "$own" | grep -a -E "^(PASS|FAIL) h0"
    printf '%s\n' "$main" | grep -a -q "^SHELL-HOSTED-M3 RESULT PASS" || RUN_FAIL=1
    printf '%s\n' "$own" | grep -a -q "^SHELL-HOSTED-M3 OWN RESULT PASS" || RUN_FAIL=1
    # Every process of both runs, stubbed: Theme's mkdir of its (private) state directory only.
    local tag bad calls
    for tag in main own; do
        calls=$(wc -l < "$OUT/${tag}_stub.log")
        bad=$(grep -a -vP '^\d+\tmkdir\t-p '"$OUT"'/cfg/theme$' "$OUT/${tag}_stub.log")
        if [ -n "$bad" ]; then
            echo "FAIL $tag.real-processes: calls beyond Theme's own mkdir (a real service was built):"
            printf '%s\n' "$bad" | sed 's/^/    /' | head -8
            RUN_FAIL=1
        else
            echo "PASS $tag.real-processes: $calls call(s), Theme's mkdir only -- no real service ran anything"
        fi
        local w
        w=$(warnings "$OUT/$tag.log")
        if [ -n "$w" ]; then
            echo "FAIL $tag.warnings:"
            printf '%s\n' "$w" | sed 's/^/    /'
            RUN_FAIL=1
        fi
    done
}

# ---- go ----------------------------------------------------------------------------
rm -rf "$OUT"
mkdir -p "$OUT/cfg/theme" "$OUT/state" "$OUT/cache"
printf '{"theme":"eva","mode":"light"}\n' > "$OUT/cfg/theme/state.json"
stubs "$OUT/stub" || { echo "SHELL-HOSTED-M3 RESULT FAIL (runner)"; exit 1; }

if [ -n "${ARM:-}" ]; then
    arms="$ARM"
    [ "$ARM" = all ] && arms="selfwrite noflag openonly scanonce noescstep"
    good=1
    for a in $arms; do
        # one tree copy per arm: the arm patches the sandbox copy, so put the files back after it
        cp "$OWNER" "$OUT/owner.bak"
        cp modules/bar/gooey/GooeyEngine.qml "$OUT/engine.bak"
        ARM="$a"
        if ! apply_arm "$a"; then good=0; cp "$OUT/owner.bak" "$OWNER"; cp "$OUT/engine.bak" modules/bar/gooey/GooeyEngine.qml; continue; fi
        run_all > "$OUT/arm_$a.out" 2>&1
        cp "$OUT/owner.bak" "$OWNER"
        cp "$OUT/engine.bak" modules/bar/gooey/GooeyEngine.qml
        read -r which text <<< "$(needle "$a")"
        if ! rl_has "$OUT/$which.log" "SHELL-HOSTED-M3 (OWN )?RESULT "; then
            echo "ARM $a: the armed copy did not load -- it proves nothing"
            rl_noresult SHELL-HOSTED-M3 "$OUT/$which.log"
            good=0
        elif grep -a -q -F "$text" "$OUT/arm_$a.out"; then
            grep -a -F "$text" "$OUT/arm_$a.out" | head -1 | cut -c1-200 | sed 's/^/    /'
            echo "ARM $a: FAIL on \"${text#FAIL }\", as it must"
        else
            echo "ARM $a: DID NOT FAIL \"${text#FAIL }\":"
            sed 's/^/    /' "$OUT/arm_$a.out" | head -12
            good=0
        fi
    done
    if [ "$good" = 1 ]; then echo "SHELL-HOSTED-M3 ARM RESULT PASS"; exit 0; fi
    echo "SHELL-HOSTED-M3 ARM RESULT FAIL"
    exit 1
fi

run_all
if ! rl_has "$OUT/main.log" "SHELL-HOSTED-M3 RESULT "; then
    rl_noresult SHELL-HOSTED-M3 "$OUT/main.log"
    exit 1
fi
if ! rl_has "$OUT/own.log" "SHELL-HOSTED-M3 OWN RESULT "; then
    rl_noresult SHELL-HOSTED-M3 "$OUT/own.log"
    exit 1
fi
if [ "$RUN_FAIL" -eq 0 ]; then
    echo "SHELL-HOSTED-M3 RESULT PASS"
else
    echo "SHELL-HOSTED-M3 RESULT FAIL (log $OUT/main.log)"
fi
exit "$RUN_FAIL"
