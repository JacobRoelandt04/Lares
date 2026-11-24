#!/usr/bin/env bash
# osd_lockkeys_probe.sh -- the Caps / Num Lock card from the REAL key, in a nested Hyprland (tools/dev/lock_env.sh, LOCK_ENV=osdlockkeys):
# the shell's two bind lines (modules/osd/OsdShortcuts.qml's header, which `lares binds` writes into keybinds.lua) evaluated in it,
# tools/dev/qml/osd_lockkeys_probe.qml (OsdShortcuts + the live LockKeysSource + a focused field), and a virtual keyboard
# (tools/dev/osd_lockkeys_vkbd.c) pressing the laptop's keycodes -- KEY_CAPSLOCK 58, KEY_NUMLOCK 69, KEY_A 30.
#
#   tools/dev/osd_lockkeys_probe.sh              OSDLOCKKEYS RESULT PASS | FAIL
#   ARM=oldbind tools/dev/osd_lockkeys_probe.sh  the binds as they were before Hyprland 0.57 (`Caps_Lock`, `Num_Lock` with no modifier):
#                                                "caps on: the shortcut fired" must go red
#   ARM=settle      nothing is announced before the burst's last word (the 450 ms of before)   -> "caps on: at once"
#   ARM=norelease   the release starts no reading                                              -> "held 700 ms"
#   ARM=firstread   the first answer of a press is the card, changed or not (the guess)        -> "the card says"
#   ARM=anyboard    a lock is on when any keyboard has it on, whichever flipped                -> "a second keyboard's lock"
#
# Checks: each press fires the shortcut once; the card that follows says what the key did (caps on, num on, caps off); the key
# still reaches the focused application (Caps, a, Caps, a types "Aa": the binds are non_consuming).
#
# WHY THE MODIFIER. On Hyprland 0.57 a lock key's own modifier is held WHILE the key is down (xkb's LockMods: depressed and toggled),
# and the bind lookup takes the modifiers with the key applied: a Caps Lock press is CAPS + Caps_Lock (modmask 2), a Num Lock press
# MOD2 + Num_Lock (16), whichever way the lock goes. A bind of plain `Caps_Lock` (modmask 0) never fires -- nor `code:66`. 0.56 matched
# the plain one. Nothing on the desktop is touched: the env's own Hyprland, private runtime / config dirs, offscreen only for nothing
# (the harness is a Wayland client of the nested compositor, which nobody sees).
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
mkdir -p "${SCRATCH:-/tmp}"
D="$(mktemp -d "${SCRATCH:-/tmp}/olk.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
export LOCK_ENV="${LOCK_ENV:-osdlockkeys}"

# the bind lines: OsdShortcuts.qml's header (`hl.bind("<keys>", osd("osd-lockkeys"), { non_consuming = true })`), or the old ones
HEADER=$(sed -nE 's|^// *hl\.bind\("([^"]+)", *osd\("(osd-lockkeys)"\), *(\{ non_consuming = true \})\).*|\1|p' modules/osd/OsdShortcuts.qml)
case "${ARM:-}" in
    "") KEYS=$HEADER; NEEDLE="" ;;
    oldbind) KEYS=$(printf 'Caps_Lock\nNum_Lock\n'); NEEDLE='OLK FAIL caps on: the shortcut fired' ;;
    settle)    KEYS=$HEADER; NEEDLE='OLK FAIL caps on: at once'; ARM_A='if (root._burst && (flippedCaps'; ARM_B='if (false && (flippedCaps' ;;
    norelease) KEYS=$HEADER; NEEDLE='OLK FAIL held 700 ms'; ARM_A=$'    function release() {\n        root._event();'; ARM_B=$'    function release() {\n        ;' ;;
    firstread) KEYS=$HEADER; NEEDLE='the card says'; ARM_A='if (root._burst && (flippedCaps !== null || flippedNum !== null))'; ARM_B='if (root._burst && !root._said)' ;;
    anyboard)  KEYS=$HEADER; NEEDLE="OLK FAIL a second keyboard's lock"; ARM_A='            caps = flippedCaps;'; ARM_B='            caps = caps;' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
[ "$(printf '%s\n' "$KEYS" | grep -c .)" = 2 ] || { echo "OLK FAIL the header of OsdShortcuts.qml does not have the two lock-key binds"; echo "OSDLOCKKEYS RESULT FAIL"; exit 1; }

# the virtual keyboard, built once per run
G="$D/gen"; mkdir -p "$G"
XML=tools/stt/ime/protocols/virtual-keyboard-unstable-v1.xml
wayland-scanner client-header "$XML" "$G/virtual-keyboard-unstable-v1-client-protocol.h" \
  && wayland-scanner private-code "$XML" "$G/vk-protocol.c" \
  && gcc -O2 -Wall -o "$D/vkbd" -I "$G" tools/dev/osd_lockkeys_vkbd.c "$G/vk-protocol.c" $(pkg-config --cflags --libs wayland-client xkbcommon) \
  || { echo "OSDLOCKKEYS RESULT FAIL (the virtual keyboard did not build)"; exit 1; }

OUTPUTS=1 tools/dev/lock_env.sh up > "$D/up.log" 2>&1 || { cat "$D/up.log"; echo "OSDLOCKKEYS RESULT FAIL (the nested Hyprland did not come up)"; exit 1; }
cleanup_env() { tools/dev/lock_env.sh down > /dev/null 2>&1; }
while IFS= read -r k; do
    [ -n "$k" ] || continue
    r=$(tools/dev/lock_env.sh hyprctl eval "hl.bind(\"$k\", hl.dsp.global(\"lares:osd-lockkeys\"), { non_consuming = true })" 2>&1)
    echo "bind $k: $r"
done <<< "$KEYS"

LOG="$D/olk.log"; : > "$LOG"
# the harness runs inside a sandbox copy of the tree (a quickshell rewrites .qmlls.ini where it starts); its runtime dir is the env's
cat > "$D/live.sh" <<LIVE_EOF
tools/dev/lock_env.sh run quickshell -p tools/dev/qml/osd_lockkeys_probe.qml > $LOG 2>&1 &
QP=\$!
for i in \$(seq 1 100); do grep -aq "OLK ready" $LOG && break; sleep 0.2; done
sleep 0.5
# caps on; num on; caps off -- each with the burst's whole length after it -- then the field
tools/dev/lock_env.sh run $D/vkbd tap 58 sleep 1200 tap 69 sleep 1200 tap 58 sleep 1200 tap 58 sleep 150 tap 30 sleep 150 tap 58 sleep 150 tap 30 sleep 1500 > $D/vkbd.log 2>&1
sleep 0.5
# the keys flicked: caps tapped six times in a row (it ends as it began, off), then on, off, on, and off by a key held 700 ms
tools/dev/lock_env.sh run $D/vkbd tap 58 sleep 40 tap 58 sleep 40 tap 58 sleep 40 tap 58 sleep 40 tap 58 sleep 40 tap 58 sleep 1200 tap 58 sleep 1000 tap 58 sleep 1000 tap 58 sleep 1000 down 58 sleep 700 up 58 sleep 1000 > $D/vkbd2.log 2>&1
sleep 0.5
# a second keyboard whose caps stays on, while the first one's goes on and off
tools/dev/lock_env.sh run $D/vkbd tap 58 sleep 6000 > $D/vkbd3.log 2>&1 &
BP=\$!
sleep 1.6
tools/dev/lock_env.sh run $D/vkbd sleep 300 tap 58 sleep 1200 tap 58 sleep 1200 > $D/vkbd4.log 2>&1
wait \$BP 2> /dev/null
sleep 0.3
kill \$QP; wait \$QP 2> /dev/null; true
LIVE_EOF
export SANDBOX="${SANDBOX:-/tmp/lares-sandbox-osd-lockkeys}"
if [ -n "${ARM_A:-}" ]; then
    printf '%s' "$ARM_A" > "$D/arm_a"; printf '%s' "$ARM_B" > "$D/arm_b"
    cat > "$D/arm.py" <<'PY'
import sys
p, a, b = sys.argv[1], open(sys.argv[2]).read(), open(sys.argv[3]).read()
s = open(p).read()
if s.count(a) != 1:
    print("ARMLOST"); sys.exit(1)
open(p, "w").write(s.replace(a, b))
PY
    sed -i "1i python3 $D/arm.py modules/osd/data/sources/LockKeysSource.qml $D/arm_a $D/arm_b || exit 3" "$D/live.sh"
fi
tools/dev/sandbox.sh bash "$D/live.sh" > "$D/live.run" 2>&1
cleanup_env
if grep -q ARMLOST "$D/live.run"; then echo "ARM $ARM: its anchor matched nothing -- it proves nothing"; exit 1; fi

rl_clean "$LOG" | grep -a -o 'OLK .*'
fails=0 checks=0
check() {   # check <name> <ok 0|1> [detail]
    checks=$((checks + 1))
    if [ "$2" = 1 ]; then echo "OLK ok   $1"; else echo "OLK FAIL $1${3:+  [$3]}" | tee -a "$D/fails"; fails=$((fails + 1)); fi
}
: > "$D/fails"
lines=$(rl_clean "$LOG" | grep -a -o 'OLK .*')
ready=0; printf '%s\n' "$lines" | grep -q '^OLK ready' && ready=1
check "the harness came up with the field focused" $ready
# the presses in order: shortcut n, then its card; the four lock-key taps are presses 1..4 (the field's two Caps are 4 and 5)
cards=$(printf '%s\n' "$lines" | grep '^OLK card' | sed 's/^OLK card //')
card() { printf '%s\n' "$cards" | sed -n "${1}p"; }
shortcut() { printf '%s\n' "$lines" | grep -q "^OLK shortcut $1\$" && echo 1 || echo 0; }
check "caps on: the shortcut fired" "$(shortcut 1)"
check "caps on: the card says caps on, num off" "$([ "$(card 1)" = "caps=true num=false changed=caps" ] && echo 1 || echo 0)" "$(card 1)"
check "num on: the shortcut fired" "$(shortcut 2)"
check "num on: the card says num on" "$([ "$(card 2)" = "caps=true num=true changed=num" ] && echo 1 || echo 0)" "$(card 2)"
check "caps off: the shortcut fired" "$(shortcut 3)"
check "caps off: the card says caps off" "$([ "$(card 3)" = "caps=false num=true changed=caps" ] && echo 1 || echo 0)" "$(card 3)"
check "one shortcut per press (18 presses of a lock key, no doubles)" "$([ "$(printf '%s\n' "$lines" | grep -c '^OLK shortcut')" = 18 ] && echo 1 || echo 0)" \
      "$(printf '%s\n' "$lines" | grep -c '^OLK shortcut') shortcuts"
# WHEN. The card against the key event that made the change (the keyboard's own clock): a lock goes on at its press and off at its release.
rl_clean "$LOG" | grep -a -o 'OLKT .*' > "$D/times"
rl_clean "$LOG" | grep -a -o 'OLK card .*' > "$D/cardlines"
cat > "$D/judge.py" <<'PY'
import sys
d = sys.argv[1]
keys = lambda f: [(l.split()[1], int(l.split()[2]), int(l.split()[3])) for l in open(d + "/" + f) if l.startswith("vkbd ") and len(l.split()) == 4]
t = [int(l.split()[2]) for l in open(d + "/times") if l.split()[1] == "card"]
c = [dict(p.split("=") for p in l.split()[2:]) for l in open(d + "/cardlines")]
cards = list(zip(t, c))
def first(after, before=10**15):
    for at, k in cards:
        if after <= at < before:
            return at, k
    return None, None
k1 = keys("vkbd.log")
def near(name, ev, want, ms=90):
    at, k = first(ev[1 + 1])
    ok = at is not None and at - ev[2] <= ms and all(k[x] == y for x, y in want.items())
    print("%d|%s|%s" % (1 if ok else 0, name, "no card" if at is None else "%d ms after, %s" % (at - ev[2], k)))
downs = [e for e in k1 if e[0] == "down" and e[1] in (58, 69)]
ups = [e for e in k1 if e[0] == "up" and e[1] in (58, 69)]
near("caps on: at once (the press)", downs[0], {"caps": "true"})
near("num on: at once (the press)", downs[1], {"num": "true"})
near("caps off: at once (the release)", ups[2], {"caps": "false"})
# nothing is said before the change: no card between the third press and its release
at, k = first(downs[2][2], ups[2][2])
print("%d|caps off: nothing is said before the release|%s" % (1 if at is None else 0, k))
# flicked: the last card says off, then on, then off
k2 = [e for e in keys("vkbd2.log") if e[1] == 58]
end6 = [e for e in k2 if e[0] == "up"][5][2]
d7 = [e for e in k2 if e[0] == "down"][6]; u8 = [e for e in k2 if e[0] == "up"][7]
last = [x for x in cards if x[0] < d7[2]][-1][1]
print("%d|flicked six times: the last card says off|%s" % (1 if last["caps"] == "false" else 0, last))
near("after the flicking, on: at once", d7, {"caps": "true"})
near("after the flicking, off: at once", u8, {"caps": "false"})
near("held 700 ms: off at the release, at once", [e for e in k2 if e[0] == "up"][9], {"caps": "false"})
# a second keyboard
k4 = [e for e in keys("vkbd4.log") if e[1] == 58]
u2 = [e for e in k4 if e[0] == "up"][1]
near("a second keyboard's lock does not hold the answer (off where off)", u2, {"caps": "false"}, 120)
PY
while IFS='|' read -r ok name detail; do check "$name" "$ok" "$detail"; done < <(python3 "$D/judge.py" "$D" 2>&1 || echo "0|the judge ran|$(python3 "$D/judge.py" "$D" 2>&1 | tail -1)")
check "the keys still reach the application (Caps a Caps a typed \"Aa\")" "$(printf '%s\n' "$lines" | grep -q '^OLK text Aa$' && echo 1 || echo 0)" \
      "$(printf '%s\n' "$lines" | grep '^OLK text' | tail -1)"
warn=$(rl_clean "$LOG" | rl_platform_noise | grep -a -E 'WARN|ERROR|TypeError|ReferenceError|Unable to assign|non-existent' | grep -v 'quickshell.tooling\|outside of the config folder' | head -3)
check "no warnings in the harness's log" "$([ -z "$warn" ] && echo 1 || echo 0)" "$warn"

if [ -n "${ARM:-}" ]; then
    if [ "$ready" = 0 ]; then echo "ARM $ARM: the armed copy did not load ($LOG) -- it proves nothing"; KEEP=1; exit 1; fi
    if grep -q -F -- "$NEEDLE" "$D/fails"; then echo "ARM $ARM: failed as it must ($NEEDLE)"; exit 0; fi
    echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it"; exit 1
fi
if [ "$ready" = 0 ]; then KEEP=1; echo "OSDLOCKKEYS RESULT FAIL (no result: $LOG)"; exit 1; fi
echo "OSDLOCKKEYS RESULT $([ $fails = 0 ] && echo PASS || echo FAIL) ($((checks - fails))/$checks checks)"
[ $fails = 0 ]
