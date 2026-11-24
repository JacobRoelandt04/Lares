#!/usr/bin/env bash
# shell_modules_probe.sh -- a module that shell.jsonc switches off (`"modules": { "silicon": false }`) is not loaded: no service, no button,
# no key, no prewarm, no warning; everything else stands as it did, and a running shell does not follow the file. On the MOCK shell, offscreen
# (tools/dev/qml/shell_modules_probe.qml: one ShellServices and one ShellFrame), the file written before each start.
#
#   tools/dev/shell_modules_probe.sh              SHELL_MODULES RESULT PASS | FAIL
#   EACH=1 tools/dev/shell_modules_probe.sh       also every module alone (one start each, ~1 min)
#   ARM=<name> tools/dev/shell_modules_probe.sh   one fault in the SANDBOX copy; it must FAIL on its check's own needle
#   ARM=all
#     stillbuilt  silicon's Loader does not ask                       -> "silicon: its service is not built"
#     blocker     the frame waits for a service that will not come    -> "the frame stands"
#     leak        a module's slot is shown whatever the file says     -> "its button is not shown"
#     nozone      the layout puts a switched-off module back          -> "it stands in no zone"
#     hot         a running shell follows the file                    -> "a running shell does not follow the file"
#     keyopens    the key of a switched-off module is answered        -> "its key opens nothing"
#     idleholds   the idle module is off and a cause still holds the inhibitor -> "idle: nothing is held"
# The cases: none (no file: everything is there), desk (what a desktop without a battery switches off), all (every module), bad (names and
# values that are no switch: said, nothing is switched off). A case's log may hold no warning the `none` case has not.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
NAME=SHELL_MODULES
ARMS="stillbuilt blocker leak nozone hot keyopens idleholds"

if [ -e .git ] && [ -z "${SMOD_INNER:-}" ]; then
    export SMOD_INNER=1
    exec tools/dev/sandbox.sh env QT_QPA_PLATFORM=offscreen SMOD_INNER=1 ARM="${ARM:-}" EACH="${EACH:-}" KEEP="${KEEP:-}" bash tools/dev/shell_modules_probe.sh "$@"
fi

D="$(mktemp -d "${SCRATCH:-/tmp}/smod.XXXXXX")"
KEEP_D=0
trap '[ "$KEEP_D" = 1 ] || [ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
arm_needle() {
    case $1 in
        stillbuilt) echo "silicon: its service is not built" ;;
        blocker) echo "the frame stands" ;;
        leak) echo "its button is not shown" ;;
        nozone) echo "it stands in no zone" ;;
        hot) echo "a running shell does not follow the file" ;;
        keyopens) echo "its key opens nothing" ;;
        idleholds) echo "idle: nothing is held" ;;
    esac
}
patch() {   # patch <file> <old> <new>: exactly one match, or the run says so
    python3 - "$1" "$2" "$3" << 'PY' || { echo "$NAME ARM $ARM BAD (anchor gone: $1)"; echo "$NAME RESULT FAIL (ARM anchor gone)"; exit 3; }
import sys
f, old, new = sys.argv[1:4]
s = open(f).read()
if s.count(old) != 1:
    sys.exit(1)
open(f, "w").write(s.replace(old, new))
PY
}
arm_files="modules/shell/ShellServices.qml modules/shell/ModuleSlot.qml modules/shell/ShellLayout.js modules/shell/ShellConfig.qml modules/shell/ShortcutRouter.qml modules/idle/IdleService.qml"
arm_apply() {
    case $1 in
        stillbuilt) patch modules/shell/ShellServices.qml '!services.moduleOn("silicon") ? null : services.mock ? siliconMock : siliconLive' 'services.mock ? siliconMock : siliconLive' ;;
        blocker) patch modules/shell/ShellServices.qml 'services._up("silicon", services.silicon)' '!!services.silicon' ;;
        leak) patch modules/shell/ModuleSlot.qml 'visible: slot.host.moduleOn(slot.moduleId)' 'visible: true' ;;
        nozone) patch modules/shell/ShellLayout.js 'd.zones[z] = d.zones[z].filter(id => off[id] !== true);' 'd.zones[z] = d.zones[z].slice();' ;;
        hot) patch modules/shell/ShellConfig.qml 'readonly property var modulesOff: root.live ? root._startModules.off : ' 'readonly property var modulesOff: ' ;;
        keyopens) patch modules/shell/ShortcutRouter.qml 'if (root.services.moduleOn && !root.services.moduleOn(key))' 'if (false)' ;;
        idleholds) patch modules/idle/IdleService.qml 'readonly property string mode: root.present ? AutoRules.higher(root.selectedMode, autoLayer.mode) : "off"' 'readonly property string mode: AutoRules.higher(root.selectedMode, autoLayer.mode)' ;;
        *) echo "$NAME RESULT FAIL (no such ARM: $1)"; exit 3 ;;
    esac
}

run_case() {   # run_case <name> <modules json or "">: the log is $D/<name>.log
    local priv=$D/$1
    mkdir -p "$priv/config/theme" "$priv/state/lares-shell-mock/config" "$priv/cache"
    printf '{"theme":"eva","mode":"light"}\n' > "$priv/config/theme/state.json"
    [ -z "$2" ] || printf '// a comment, as a user writes one\n{ "modules": %s }\n' "$2" > "$priv/state/lares-shell-mock/config/shell.jsonc"
    env -u WAYLAND_DISPLAY XDG_STATE_HOME="$priv/state" XDG_CONFIG_HOME="$priv/config" XDG_CACHE_HOME="$priv/cache" SHELL_SERVICES=mock QT_QPA_PLATFORM=offscreen \
        QT_QPA_PLATFORMTHEME= QT_QUICK_BACKEND=rhi QT_LOGGING_RULES="qt.qpa.services.warning=false" \
        timeout 60 quickshell -p tools/dev/qml/shell_modules_probe.qml > "$D/$1.log" 2>&1
}
desk='{ "silicon": false, "bridge": false, "screentime": false }'
all='{ "power": false, "idle": false, "theme": false, "notes": false, "llm": false, "weather": false, "stocks": false, "player": false, "volume": false, "aerial": false, "bridge": false, "panorama": false, "silicon": false, "update": false, "clipboard": false, "picker": false, "wiki": false, "screentime": false }'
bad='{ "silikon": false, "clock": false, "silicon": "no", "network": true, "weather": 0 }'

judge() {   # the cases that ran, judged together (tools/dev/shell_modules_judge is this heredoc)
    python3 - "$D" "$@" << 'PY'
import json, re, sys
d, cases = sys.argv[1], sys.argv[2:]
fails = []
n = 0
def check(case, what, ok, detail=""):
    global n
    n += 1
    if not ok:
        fails.append(what)
        print("SHELL_MODULES FAIL %s: %s%s" % (case, what, "  [%s]" % detail if detail else ""))
def read(case):
    txt = re.sub(r"\x1b\[[0-9;]*m", "", open("%s/%s.log" % (d, case), errors="replace").read())
    out = {}
    for k in ("FACTS", "HOT", "KEYS"):
        m = re.search(r"SMOD %s (\{.*\})" % k, txt)
        out[k] = json.loads(m.group(1)) if m else None
    warn = set()
    for line in txt.splitlines():
        if re.match(r"^\s*(WARN|ERROR)|.*(Unable to assign|Binding loop|TypeError|non-existent property)", line):
            warn.add(re.sub(r"0x[0-9a-f]+", "0x", line.strip()))
    return out, warn
FIXED = {"clock", "windowtray", "notifications"}
base, base_warn = read("none")
for case in cases:
    r, warn = read(case)
    if not r["FACTS"]:
        check(case, "the frame stands", False, "no facts: see the log")
        continue
    f, h, k = r["FACTS"], r["HOT"], r["KEYS"]
    check(case, "the frame stands", f["ready"])
    want = {"none": [], "bad": [], "desk": ["bridge", "screentime", "silicon"], "all": sorted(f["modules"])}.get(case, [case] + (["picker"] if case == "clipboard" else []))
    check(case, "the file's modules are the ones that are off", f["off"] == sorted(want), "%s, want %s" % (f["off"], sorted(want)))
    off = set(want)
    for m in f["modules"]:
        on = m not in off
        if m in f["shown"]:
            check(case, "%s: it stands in its zone" % m if on else "%s: it stands in no zone" % m, (m in f["placed"]) == on)
            check(case, "%s: its button is shown" % m if on else "%s: its button is not shown" % m, f["shown"][m] == on)
        if m in f["built"]:
            check(case, "%s: its service is built" % m if on else "%s: its service is not built" % m, f["built"][m] == on)
    for m in FIXED:
        check(case, "%s is always there" % m, m in f["placed"] and f["shown"][m])
    if "idle" in off:
        check(case, "idle: nothing is held", f["idle"]["mode"] == "off" and f["idle"]["hold"] is False, str(f["idle"]))
    else:
        check(case, "idle: a mode that is asked for is in force and held", f["idle"]["mode"] == "normal" and f["idle"]["hold"] is True, str(f["idle"]))
    check(case, "casting goes with the displays", f["cast"] == ("panorama" not in off))
    check(case, "the update's own service looks for updates only when it is on", f["updatesLive"] == ("update" not in off) and f["lockUpdates"] == ("update" not in off))
    check(case, "the OSD is told which backends are left out on purpose", sorted(f["absent"]) == sorted([s for s, m in (("mpd", "player"), ("aerial", "aerial")) if m in off]))
    for m in ("weather", "silicon", "aerial", "llm", "bridge", "panorama", "theme"):
        check(case, "%s: prewarmed only when it is on" % m, (m in f["prewarm"]) == (m not in off) or (m in ("weather",) and not base["FACTS"]["built"]["weather"]), str(f["prewarm"]))
    check(case, "a running shell does not follow the file", h is not None and h["off"] == f["off"] and h["placed"].keys() == f["placed"].keys() and h["built"] == f["built"] and h["shown"] == f["shown"])
    if case not in ("none",):
        check(case, "the hot part of the same file is followed", h is not None and h["font"] == "Inter")
    for m in ("notes", "clipboard", "picker"):
        if m in off:
            check(case, "%s: its key opens nothing" % m, k is not None and k[m] is False)
        elif k is not None and base["KEYS"] is not None:
            check(case, "%s: its key works as it did" % m, k[m] == base["KEYS"][m])
    new = sorted(w for w in warn - base_warn if not (case == "bad" and "ShellConfig: shell.jsonc: modules" in w))
    check(case, "no warning of its own", not new, "; ".join(new)[:400])
    if case == "bad":
        said = " ".join(sorted(warn))
        for w in ('"silikon" is no module', '"clock" cannot be switched off', '"silicon" must be true or false', '"weather" must be true or false'):
            check(case, "said: %s" % w, w in said)
print("SHELL_MODULES %d of %d checks" % (n - len(fails), n))
sys.exit(1 if fails else 0)
PY
}

if [ "${ARM:-}" = all ]; then
    mkdir -p "$D/keep"; for f in $arm_files; do mkdir -p "$D/keep/${f%/*}"; cp "$f" "$D/keep/$f"; done
    badarms=0
    for a in $ARMS; do
        for f in $arm_files; do cp "$D/keep/$f" "$f"; done   # a later arm must not be judged on an earlier one's fault
        out=$(ARM=$a bash tools/dev/shell_modules_probe.sh 2>&1); line=$(printf '%s\n' "$out" | grep -a "^$NAME ARM $a" | tail -1)
        echo "${line:-$NAME ARM $a BAD (no verdict)}"
        case $line in *"FAILED AS IT MUST"*) ;; *) badarms=1 ;; esac
    done
    [ "$badarms" -eq 0 ] && { echo "$NAME ARMS PASS"; exit 0; }
    echo "$NAME ARMS FAIL"; exit 1
fi
[ -z "${ARM:-}" ] || arm_apply "$ARM"
run_case none ""; run_case desk "$desk"; run_case all "$all"; run_case bad "$bad"
cases="none desk all bad"
if [ -n "${EACH:-}" ]; then
    for m in power idle theme notes llm weather stocks player volume aerial bridge panorama silicon update clipboard picker wiki screentime; do
        run_case "$m" "{ \"$m\": false }"; cases="$cases $m"
    done
fi
# shellcheck disable=SC2086
judge $cases > "$D/verdict"; rc=$?
cat "$D/verdict"
if ! grep -aq 'SMOD FACTS' "$D/none.log" && [ -z "${ARM:-}" ]; then KEEP_D=1; echo "$NAME RESULT FAIL (no result: $D/none.log)"; exit 1; fi
if [ -n "${ARM:-}" ]; then
    needle=$(arm_needle "$ARM")
    if ! grep -aq 'SMOD FACTS' "$D/none.log"; then echo "$NAME ARM $ARM BAD (the armed copy did not load)"
    elif grep -a "^$NAME FAIL" "$D/verdict" | grep -aqF -- "$needle"; then echo "$NAME ARM $ARM FAILED AS IT MUST ($needle)"
    else echo "$NAME ARM $ARM BAD (not '$needle')"; fi
fi
if [ "$rc" -eq 0 ]; then echo "$NAME RESULT PASS"; else [ -n "${ARM:-}" ] || KEEP_D=1; echo "$NAME RESULT FAIL ($D)"; exit 1; fi
