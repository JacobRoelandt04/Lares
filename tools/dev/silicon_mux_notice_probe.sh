#!/usr/bin/env bash
# The MUX outcome is told as a NOTIFICATION (stored in the manager), never an OSD card: the silicon mockup's owner probe,
# step O16 (the guard's windows, dGPU only -> restart -> the keep prompt, a toast -> run out the window, the shell's start tells the
# outcome ONCE through the stage's own NotificationService, a blocked app through the notify-send stub) and step O19 (the keep
# prompt at a login is a toast: no popup opens, the helper is told, Keep and Go back now are its actions, the lock takes it
# away). Offscreen, in the sandbox, on a private bus, with notify-send / pw-play stand-ins; nothing reaches the desktop.
#
#   tools/dev/silicon_mux_notice_probe.sh                 last line: SILICON-MUX-NOTICE RESULT PASS|FAIL
#   STEPS=O16,O1 tools/dev/silicon_mux_notice_probe.sh    other owner steps (default O16,O19)
#   ARM=<name>                                            a fault in the SANDBOX copy; the run must end FAIL
#   ARM=all                                               every ARM; SILICON-MUX-NOTICE ARMS PASS when each one failed
#
#     silent    the watcher posts no notification              -> "ONE notification" FAILS
#     twice     the outcome is not marked told                 -> "told once" FAILS
#     liar      a `failed` record whose wiring is in effect is told as a failure again (MuxFlow.outcome)
#                                                              -> the words check ("dGPU only is on") FAILS
#
# The words themselves (MuxFlow.outcome) are checked first, in node, on the record of 2026-11-04: want dgpu, state failed
# ("the firmware holds hybrid after the write"), wiring in effect dgpu -> "dGPU only is on"; the same record with the wiring
# still hybrid (a real failure) -> "The GPU change did not go through" with the helper's reason.
cd "$(dirname "$0")/../.." || exit 1
if [ -e .git ] && [ -z "${SMN_INNER:-}" ]; then
    SCRATCH="${SCRATCH:-/tmp/lares-scratch-silicon-mux}"
    mkdir -p "$SCRATCH"
    exec env SANDBOX="${SANDBOX:-$SCRATCH/lares-sandbox}" SCRATCH="$SCRATCH" MOCKUP_REPO= tools/dev/sandbox.sh \
        QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi SMN_INNER=1 ARM="${ARM:-}" STEPS="${STEPS:-O16,O19}" bash tools/dev/silicon_mux_notice_probe.sh "$@"
fi
ROOT="$PWD"
. "$ROOT/tools/dev/result_lib.sh"
SCRATCH="${SCRATCH:-/tmp}"
NAME="SILICON-MUX-NOTICE"

arm() {  # file from to -- the anchor must be there exactly once
    python3 - "$@" <<'PY'
import sys
p, a, b = sys.argv[1:4]
s = open(p, encoding="utf-8").read()
if s.count(a) != 1:
    print("ARM anchor found %d times in %s: %r" % (s.count(a), p, a[:80])); sys.exit(2)
open(p, "w", encoding="utf-8").write(s.replace(a, b))
PY
}

words() {  # MuxFlow.js -> 0 when outcome() says the true thing about the 2026-11-04 record
    node - "$1" <<'JS'
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8").replace(/^\.pragma.*$/m, "");
const outcome = new Function(src + ";return outcome;")();
const rec = { state: "failed", want: "dgpu", why: "the firmware holds hybrid after the write" };
const bad = [];
const a = outcome(Object.assign({ wiringNow: "dgpu" }, rec));
if (!a || a.title !== "dGPU only is on" || !/no keep prompt/.test(a.body)) bad.push("the landed switch: " + JSON.stringify(a));
const b = outcome(Object.assign({ wiringNow: "hybrid" }, rec));
if (!b || b.title !== "The GPU change did not go through" || b.body !== rec.why) bad.push("the real failure: " + JSON.stringify(b));
const c = outcome({ state: "reverted", want: "dgpu", wiringNow: "hybrid" });
if (!c || c.title !== "dGPU only was not kept") bad.push("reverted: " + JSON.stringify(c));
if (outcome({ state: "kept", want: "dgpu" }) !== null) bad.push("kept tells nothing");
if (bad.length) { console.log("words: FAIL " + bad.join(" | ")); process.exit(1); }
console.log("words: ok");
JS
}

run_once() {  # arm-name -> the run's output; sets RC
    local armname="$1" tree w out
    tree=$(mktemp -d "$SCRATCH/smn.XXXXXX") || return 1
    rsync -a --exclude .git --exclude .qmlls.ini --exclude Screenshots "$ROOT/" "$tree/" || return 1
    w="$tree/modules/silicon/SiliconMuxWatcher.qml"
    case "$armname" in
        "") ;;
        silent) arm "$w" '        notifier.notify("silicon-mux", { title: o.title, body: o.body });' '        void o;' || return 3 ;;
        twice)  arm "$w" '        notifier.notify("silicon-mux", { title: o.title, body: o.body });
        root.vm.markMuxOutcomeSeen();' '        notifier.notify("silicon-mux", { title: o.title, body: o.body });' || return 3 ;;
        liar)   arm "$tree/modules/silicon/popup/MuxFlow.js" 'String(mux.wiringNow || "") === want' 'false' || return 3 ;;
        *) echo "unknown ARM $armname"; return 3 ;;
    esac
    words "$tree/modules/silicon/popup/MuxFlow.js" || { rm -rf "$tree"; echo "$NAME words FAIL"; echo "SILICONOWNER RESULT FAIL (the words check)"; return 1; }
    mkdir -p "$tree/stubs" "$tree/xdg/config/theme" "$tree/xdg/state" "$tree/home"
    printf '{"theme":"eva","mode":"light"}\n' > "$tree/xdg/config/theme/state.json"
    for c in notify-send pw-play; do
        printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >> "$STUB_LOG"\n[ "%s" = notify-send ] && echo 1\nexit 0\n' "$(echo "$c" | tr a-z A-Z | sed 's/NOTIFY-SEND/NOTIFY/;s/PW-PLAY/PLAY/')" "$c" > "$tree/stubs/$c"
        chmod +x "$tree/stubs/$c"
    done
    : > "$tree/stub.log"
    (
        cd "$tree" || exit 1
        env XDG_CONFIG_HOME="$tree/xdg/config" XDG_STATE_HOME="$tree/xdg/state" HOME="$tree/home" \
            PATH="$tree/stubs:$PATH" STUB_LOG="$tree/stub.log" STUB_PWPLAY="$tree/stubs/pw-play" PROBE=owner STEPS="$STEPS" ZOOM=1 \
            tools/dev/notifications_bus.sh timeout 240 quickshell -n -p mockups/silicon.qml > "$tree/run.log" 2>&1
    )
    out=$(rl_result "$NAME" "$tree/run.log" "SILICONOWNER RESULT .*")
    RC=$?
    printf '%s\n' "$out"
    grep -a "FAIL" "$tree/run.log" | sed 's/\x1b\[[0-9;]*m//g' | grep SILICONOWNER | head -5
    rl_isnoresult "$out" || rm -rf "$tree"   # a no-result verdict names the log: keep it
    return $RC
}

if [ "${ARM:-}" = all ]; then
    bad=0
    for a in silent twice liar; do
        o=$(ARM= run_once "$a"); rc=$?
        if rl_isnoresult "$o"; then echo "ARM $a: did not load (proves nothing)"; bad=1
        elif [ "$rc" = 0 ]; then echo "ARM $a: still PASSES (toothless)"; bad=1
        else echo "ARM $a: failed as it must"; fi
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
