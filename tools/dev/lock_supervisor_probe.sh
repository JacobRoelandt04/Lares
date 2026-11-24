#!/usr/bin/env bash
# The lock's way in on the deploy path (2026-10-23, "the Lares lockscreen in the trial"): what tools/lockscreen/lares-lock
# sets in Hyprland before every launch and takes back on the way out, tools/lockscreen/lares-lock-session (the launcher the
# reel and hypridle call: it takes the lock file BEFORE screentimed's lock-run and hands it over open), --rescue, and the
# EGL pin. In the isolated Hyprland of tools/dev/lock_env.sh, PAM = the scripted stub (password "hunter2"), the lock from a
# TREE COPY (tools/dev/lock_a1_lib.sh): nothing of the user's is touched, and nothing shows on their screen. The env is
# given the user's live settings first (2026-10-23: allow_session_lock_restore false, nothing of the shell above a lock).
#
#   tools/dev/lock_supervisor_probe.sh             ends in LOCK_SUPERVISOR RESULT PASS|FAIL
#   ARM=<name> tools/dev/lock_supervisor_probe.sh  a fault in the TREE COPY; must FAIL the check named
#   ARM=all                                    every ARM: LOCK_SUPERVISOR ARMS PASS when each failed as it must
#     nosettings   lock_settings sets no restore                    -> S1
#     relaunchold  only the first launch sets it (a reload put the config's value back mid-lock) -> S2
#     noback       the way out leaves the settings                  -> S3
#     norescue     --rescue's flag is ignored: the same files are relaunched -> S5
#     nopin        no EGL pin                                       -> S6
#     pamalways    the password context always asks lares-lock (a machine with only the old PAM file) -> S7
#     nofresh      a machine with neither PAM file is asked qs-lock, which is not installed -> S7
#     nooldlock    neither the launcher nor the supervisor notices a lock of the old name -> S9
#     supoldblind  the supervisor itself starts beside a lock of the old name (the launcher still refuses) -> S10
#     heldpair     lares-lock-held reads only the file it is given (an old-name lock is not "a lock is up") -> S9
#     hlblind      the last-resort hyprlock always gets the pinned lares-lock service, installed or not -> S11
#
# The checks
#   S1  a lock through the launcher sets both while it is up: restore true, the fixture's lares-bar drawn ABOVE the lock
#   S4  (while that lock is up) the launcher again: exits at once, reaches nothing (not screentimed's lock-run: one call
#       in all), one supervisor; the supervisor holds the lock file through the real screentimed's exec
#       (tools/lockscreen/lares-lock-held)
#   S2  a reload's value put back mid-lock (restore false), then the lock killed: the supervisor sets it again before the
#       relaunch, and the relaunch TAKES OVER -- Hyprland reads the option when the new locker asks
#   S3  the password unlocks; the supervisor exits; restore is false again, and a bare lock is drawn over the bar (rule 0)
#   S5  --rescue ends the Lares lock and the supervisor goes STRAIGHT to the last-resort hyprlock (a stand-in), no relaunch;
#       a second --rescue refuses (it never ends hyprlock: that is lockdead); lares-lock-held is true until the supervisor
#       exits, false after
#   S7  the PAM services: with the stub pam.d holding ONLY the old name's files (qs-lock, qs-lock-face) the lock asks them and the password
#       unlocks (the log says "password qs-lock"); with BOTH the new names win ("password lares-lock"); with NEITHER (a fresh machine) the
#       lock asks the machine's own "login" and the password unlocks; S3 is the new files alone
#   S9  a lock of the OLD name that is up ($XDG_RUNTIME_DIR/qs-lock.lock held): lares-lock-held on the new file name says held, and the launcher
#       exits at once and starts nothing (no supervisor, no screentimed call); S10: the supervisor itself refuses to start beside it
#   S11 the last resort: hyprlock's pinned config names its PAM service, and one that is not installed denies everything -- with only the old
#       name's PAM file in the stub dir it is handed a copy of the pinned file whose service is qs-lock, with neither one whose service is login;
#       with the new file, the pinned file itself
#   S6  the lock's environment: a caller's __EGL_VENDOR_LIBRARY_FILENAMES is kept as given; with none and an Intel boot
#       GPU, Mesa's file is pinned (with another boot GPU, none is)
# shellcheck disable=SC2016   # the ARM patches are literal code
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PNAME=LOCK_SUPERVISOR   # not NAME: tools/dev/lock_a1_lib.sh sets that to the env's name
ARMS="nosettings relaunchold noback norescue nopin pamalways nofresh nooldlock supoldblind heldpair hlblind"
arm_check() { case $1 in nosettings) echo S1 ;; relaunchold) echo S2 ;; noback) echo S3 ;; norescue) echo S5 ;; nopin) echo S6 ;; pamalways|nofresh) echo S7 ;; nooldlock|heldpair) echo S9 ;; supoldblind) echo S10 ;; hlblind) echo S11 ;; esac; }

if [ "${ARM:-}" = all ]; then
    bad=0
    for a in $ARMS; do
        out=$(ARM=$a "$0" 2>&1); line=$(printf '%s\n' "$out" | grep -a "^$PNAME ARM $a" | tail -1)
        echo "${line:-$PNAME ARM $a BAD (no verdict)}"
        case $line in *"FAILED AS IT MUST"*) ;; *) bad=1 ;; esac
    done
    [ "$bad" -eq 0 ] && { echo "$PNAME ARMS PASS"; exit 0; }
    echo "$PNAME ARMS FAIL"; exit 1
fi

# shellcheck source=tools/dev/lock_a1_lib.sh
. "$ROOT/tools/dev/lock_a1_lib.sh"
a1_init lsup
fails=0 FAILED=""
say() { echo "$PNAME $*"; case "$*" in *" FAIL"*) fails=$((fails + 1)); FAILED="$FAILED ${1%% *}" ;; esac; }
finish() {
    if [ -n "${ARM:-}" ]; then
        want=$(arm_check "$ARM")
        case " $FAILED " in
            *" $want "*) echo "$PNAME ARM $ARM FAILED AS IT MUST ($want)" ;;
            *) echo "$PNAME ARM $ARM BAD (${FAILED:+failed$FAILED, }not $want)" ;;
        esac
    fi
    if [ "$fails" -eq 0 ]; then echo "$PNAME RESULT PASS"; else echo "$PNAME RESULT FAIL ($fails:$FAILED)"; fi
}
trap 'a1_down' EXIT

a1_build_pam || { echo "$PNAME RESULT FAIL (pam stub did not build)"; exit 1; }
a1_tree '{ "face": "off", "veil": "dimples", "veils": ["dimples"] }' || { echo "$PNAME RESULT FAIL (tree copy)"; exit 1; }
LK="$T/tools/lockscreen"
for f in lares-lock lares-lock-session lares-lock-held; do
    [ -x "$LK/$f" ] || { echo "$PNAME RESULT FAIL (no $f in the tree copy)"; exit 1; }
done

arm_patch() {   # arm_patch <old> <new> in the copy's supervisor
    a1_patch tools/lockscreen/lares-lock "$1" "$2" || { echo "$PNAME ARM $ARM BAD (anchor gone)"; echo "$PNAME RESULT FAIL (ARM anchor gone)"; exit 3; }
}
case ${ARM:-} in
    "") ;;
    nosettings)  arm_patch '    r=$(timeout 3 hyprctl eval "hl.config({ misc = { allow_session_lock_restore = true } })" 2>&1)' '    r=ok' ;;
    relaunchold) arm_patch '    local r
    r=$(timeout 3 hyprctl eval "hl.config({ misc = { allow_session_lock_restore = true } })" 2>&1)' '    local r
    [ -n "${ARMED_ONCE:-}" ] && return 0; ARMED_ONCE=1
    r=$(timeout 3 hyprctl eval "hl.config({ misc = { allow_session_lock_restore = true } })" 2>&1)' ;;
    noback)      arm_patch 'settings_back() {   # the way out: what lock_settings changed' 'settings_back() { return 0; }
settings_back_unused() {' ;;
    norescue)    arm_patch 'if [ -e "$RESCUE" ]; then
    say "ended by --rescue' 'if false; then
    say "ended by --rescue' ;;
    nopin)       arm_patch '            && EGL_PIN=(__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json)' '            && EGL_PIN=()' ;;
    pamalways)   a1_patch modules/lockscreen/lock/AuthController.qml '        if (pamPasswordFile.text() !== "")
            root.passwordService = "lares-lock";' '        if (true)
            root.passwordService = "lares-lock";' || { echo "$PNAME RESULT FAIL (ARM anchor gone)"; exit 3; } ;;
    nofresh)     a1_patch modules/lockscreen/lock/AuthController.qml '        else if (pamOldPasswordFile.text() === "")
            root.passwordService = "login";
' '' || { echo "$PNAME RESULT FAIL (ARM anchor gone)"; exit 3; } ;;
    nooldlock)   # TWO GUARDS FOR ONE RULE: the launcher's and the supervisor's -- this ARM takes both away
        a1_patch tools/lockscreen/lares-lock-session '"$HERE/lares-lock-held" --old && exit 0' 'true' || { echo "$PNAME RESULT FAIL (ARM anchor gone)"; exit 3; }
        arm_patch '    if "$ROOT/tools/lockscreen/lares-lock-held" --old; then' '    if false; then' ;;
    supoldblind) arm_patch '    if "$ROOT/tools/lockscreen/lares-lock-held" --old; then' '    if false; then' ;;
    hlblind)     arm_patch '    if [ -s "$pam_dir/lares-lock" ]; then printf '"'"'%s'"'"' "$conf"; return 0; fi' '    printf '"'"'%s'"'"' "$conf"; return 0' ;;
    heldpair)    a1_patch tools/lockscreen/lares-lock-held '       case ${1##*/} in lares-lock.lock|qs-lock.lock) files=("${1%/*}/lares-lock.lock" "${1%/*}/qs-lock.lock") ;; esac ;;' '       true ;;' || { echo "$PNAME RESULT FAIL (ARM anchor gone)"; exit 3; } ;;
    *) echo "$PNAME RESULT FAIL (no such ARM: $ARM)"; exit 3 ;;
esac

a1_up OUTPUTS=1 || { echo "$PNAME RESULT FAIL (env)"; exit 1; }
cp "$A1_ROOT/tools/dev/lock_env/probes/lock_basic.qml" "$FX/"
RT=$B/rt
getopt_restore() { "$E" hyprctl getoption misc:allow_session_lock_restore -j 2> /dev/null | jq -r 'if has("bool") then .bool else (.int != 0) end' 2> /dev/null; }
"$E" hyprctl eval 'hl.config({ misc = { allow_session_lock_restore = false } })' > /dev/null
"$E" hyprctl eval 'hl.layer_rule({ name = "lares_bar_above_lock", match = { namespace = "^lares-bar$" }, above_lock = 0 })' > /dev/null
BLUE="68 128 244"; LOCKC="234 237 245"
near() { python3 -c "a=list(map(int,'$1'.split())); b=list(map(int,'$2'.split())); import sys; sys.exit(0 if max(abs(x-y) for x,y in zip(a,b))<=${3:-3} else 1)"; }
bar_px() { a1_shot "$1"; a1_px "$1" 20 20; }   # the fixture bar's blue square (8..32, 8..32)
held() { "$LK/lares-lock-held" "$RT/lares-lock.lock"; }
env_pids() {   # env_pids <cmdline ERE>: this env's processes (their environment carries LOCK_ENV_DIR=<env>), never anyone else's
    local p
    for p in /proc/[0-9]*; do
        [ -O "$p" ] || continue
        { tr '\0' '\n' < "$p/environ"; } 2> /dev/null | grep -qx "LOCK_ENV_DIR=$B" || continue
        { tr '\0' ' ' < "$p/cmdline"; } 2> /dev/null | grep -qE -- "$1" && echo "${p#/proc/}"
    done
}
sup_pids() { env_pids 'tools/lockscreen/lares-lock *$'; }
lock_child() { cat "$RT/lares-lock.child" 2> /dev/null; }
unlock_pw() { "$E" type hunter2; sleep 0.3; "$E" key Return; a1_wait_log 'LARESLOCK unlocked' 10; }
wait_no_sup() { local _; for _ in $(seq 1 $(( ${1:-10} * 10 ))); do [ -z "$(sup_pids)" ] && return 0; sleep 0.1; done; return 1; }
wait_text() { local f=$1 t=$2 s=${3:-10} _; for _ in $(seq 1 $(( s * 10 ))); do grep -aq -- "$t" "$f" 2> /dev/null && return 0; sleep 0.1; done; return 1; }
wait_relaunch_secure() {   # the old log says secure until the relaunch truncates it: wait for the word, then for secure
    wait_text "$1" "relaunching the lock" 10 || return 1
    sleep 0.3
    a1_wait_log 'LARESLOCK secure' 15
}

# a screentimed of the real binary behind a recorder (no daemon in this runtime dir: its lock feed goes nowhere); the
# last-resort locker's stand-in, which says it ran and waits for a file
mkdir -p "$W/bin"
real_st=$(command -v screentimed 2> /dev/null || echo "$HOME/.local/bin/screentimed")
[ -x "$real_st" ] || { echo "$PNAME RESULT FAIL (no screentimed binary to exec through: $real_st)"; exit 1; }
printf '#!/bin/bash\necho "$*" >> %q\nexec %q "$@"\n' "$W/screentimed.calls" "$real_st" > "$W/bin/screentimed"
printf '#!/bin/bash\necho "HYPRLOCK $*" >> %q\nwhile [ ! -e %q ]; do sleep 0.1; done\nexit 0\n' "$W/hyprlock.calls" "$W/hyprlock.release" > "$W/bin/hyprlock-stub"
chmod +x "$W/bin/screentimed" "$W/bin/hyprlock-stub"
LPATH="$W/bin:/usr/local/bin:/usr/bin:/bin"
session() {   # session <out> [env options / assignments...]: the launcher in the env, in the background
    local out=$1; shift
    a1_pam_guard || { say "GUARD FAIL (pamDirectory is not the stub's: no lock was started)"; finish; exit 1; }
    : > "$RT/lares-lock.log"   # the last lock's "LARESLOCK secure" must not be read as this one's (the supervisor truncates it too, later)
    ( "$E" run env "$@" PATH="$LPATH" LARES_LOCK_FACE=0 LARES_LOCK_HYPRLOCK="$W/bin/hyprlock-stub" LARES_LOCK_PAM_DIR="$W/pam.d" bash "$LK/lares-lock-session" > "$out" 2>&1 & )
}

# ---- S1, S4, S2, S3: one lock through the launcher -------------------------------------------------------
r0=$(getopt_restore)
session "$W/s1.out"
if ! a1_wait_log 'LARESLOCK secure' 15; then
    say "S1 FAIL (the launcher's lock never said secure: $(tail -3 "$W/s1.out" | tr '\n' ' '))"
    say "S4 FAIL (no lock to ask again)"; say "S2 FAIL (no lock)"; say "S3 FAIL (no lock)"
else
    sleep 1.5
    r1=$(getopt_restore); p1=$(bar_px s1)
    if [ "$r0" = false ] && [ "$r1" = true ] && near "$p1" "$BLUE" 30; then
        say "S1 PASS (restore false -> true while locked; the lares-bar drawn above the lock)"
    else
        say "S1 FAIL (restore before='$r0' while locked='$r1'; the bar's square under the lock='$p1', blue is '$BLUE')"
    fi
    # S4
    sups1=$(sup_pids | paste -sd, -)
    t0=$(date +%s%N)
    "$E" run env PATH="$LPATH" bash "$LK/lares-lock-session" > "$W/s4.out" 2>&1; rc4=$?
    ms4=$(( ($(date +%s%N) - t0) / 1000000 ))
    sups2=$(sup_pids | paste -sd, -)
    calls=$(grep -c . "$W/screentimed.calls" 2> /dev/null || echo 0)
    fd9=$(readlink "/proc/${sups1%%,*}/fd/9" 2> /dev/null)
    if [ "$rc4" -eq 0 ] && [ "$ms4" -lt 1500 ] && [ -n "$sups1" ] && [ "$sups1" = "$sups2" ] && [[ $sups1 != *,* ]] \
        && [ "$calls" -eq 1 ] && grep -q '^lock-run ' "$W/screentimed.calls" && held && [ "$fd9" = "$RT/lares-lock.lock" ]; then
        say "S4 PASS (second call exit 0 in ${ms4} ms, one supervisor ($sups1), screentimed asked once; the lock file held on fd 9 through its exec)"
    else
        say "S4 FAIL (rc=$rc4 ${ms4}ms supervisors before='$sups1' after='$sups2' screentimed calls=$calls fd9='$fd9' held=$(held && echo yes || echo no))"
    fi
    # S2
    "$E" hyprctl eval 'hl.config({ misc = { allow_session_lock_restore = false } })' > /dev/null
    c=$(lock_child)
    [ -n "$c" ] && env_pids 'lock/shell\.qml' | grep -qx "$c" && kill -9 "$c" 2> /dev/null
    if [ -n "$c" ] && wait_relaunch_secure "$W/s1.out"; then
        r2=$(getopt_restore)
        if [ "$r2" = true ]; then say "S2 PASS (killed with restore put back to false: set again, the relaunch took over)"
        else say "S2 FAIL (the relaunch is secure but restore reads '$r2')"; fi
    else
        say "S2 FAIL (child '$c'; no relaunched lock took over: $(grep -a 'lares-lock:' "$W/s1.out" | tail -3 | tr '\n' ' '))"
    fi
    # S3
    if unlock_pw && wait_no_sup 8; then
        sleep 0.4
        r3=$(getopt_restore)
        ( "$E" run quickshell -p "$FX/lock_basic.qml" > "$W/basic.log" 2>&1 & )
        wait_text "$W/basic.log" 'PROBE secure true' 10; sleep 0.6
        p3=$(bar_px s3)
        "$E" type u; wait_text "$W/basic.log" 'PROBE unlocked' 5; sleep 0.8
        if [ "$r3" = false ] && near "$p3" "$LOCKC" 6 && ! held; then
            say "S3 PASS (unlocked; restore false again, a bare lock covers the bar again, the lock file free)"
        else
            say "S3 FAIL (restore after='$r3'; the bar's square under a bare lock='$p3', the lock's colour is '$LOCKC'; held=$(held && echo yes || echo no))"
        fi
    else
        say "S3 FAIL (the password did not unlock, or the supervisor stayed: $(sup_pids | paste -sd, -); the lock said: $(a1_lock_log | grep -a -i 'pam\|password\|error' | tail -4 | tr '\n' ' '))"
    fi
fi

# ---- S5: --rescue ------------------------------------------------------------------------------------------
rm -f "$W/hyprlock.calls" "$W/hyprlock.release"
session "$W/s5.out"
if ! a1_wait_log 'LARESLOCK secure' 15; then
    say "S5 FAIL (no lock to rescue: $(tail -3 "$W/s5.out" | tr '\n' ' '))"
else
    sleep 0.5
    "$E" run bash "$LK/lares-lock" --rescue > "$W/rescue1.out" 2>&1; rc1=$?
    wait_text "$W/hyprlock.calls" HYPRLOCK 10
    "$E" run bash "$LK/lares-lock" --rescue > "$W/rescue2.out" 2>&1; rc2=$?
    held_mid=$(held && echo yes || echo no)
    touch "$W/hyprlock.release"
    wait_no_sup 8
    held_after=$(held && echo yes || echo no)
    if [ "$rc1" -eq 0 ] && grep -q "ended by --rescue" "$W/s5.out" && ! grep -q "relaunching the lock" "$W/s5.out" \
        && grep -q "^HYPRLOCK --grace 0 -c $T/tools/lockscreen/hyprlock.conf" "$W/hyprlock.calls" \
        && [ "$rc2" -eq 1 ] && grep -q "no Lares lock is running" "$W/rescue2.out" && [ "$held_mid" = yes ] && [ "$held_after" = no ]; then
        say "S5 PASS (rescued: no relaunch, hyprlock at once; a second --rescue refused; held while hyprlock ran, free after)"
    else
        say "S5 FAIL (rc1=$rc1 rc2=$rc2 held mid=$held_mid after=$held_after; supervisor: $(grep -a 'lares-lock:' "$W/s5.out" | tr '\n' ' '); hyprlock: $(cat "$W/hyprlock.calls" 2> /dev/null))"
    fi
fi

# ---- S6: the EGL pin -------------------------------------------------------------------------------------
boot_intel=no
for c in /sys/class/drm/card*; do
    case "${c##*/}" in *-*) continue ;; esac
    [ "$(cat "$c/device/boot_vga" 2> /dev/null)" = 1 ] || continue
    [ "$(cat "$c/device/vendor" 2> /dev/null)" = 0x8086 ] && boot_intel=yes
    break
done
egl_of_child() { tr '\0' '\n' < "/proc/$(lock_child)/environ" 2> /dev/null | sed -n 's/^__EGL_VENDOR_LIBRARY_FILENAMES=//p'; }
s6=""
for mode in unset kept; do
    if [ "$mode" = unset ]; then session "$W/s6$mode.out" -u __EGL_VENDOR_LIBRARY_FILENAMES
    else session "$W/s6$mode.out" __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/./50_mesa.json; fi
    if a1_wait_log 'LARESLOCK secure' 15; then
        got=$(egl_of_child)
        unlock_pw > /dev/null; wait_no_sup 8
    else
        got="(no lock: $(tail -2 "$W/s6$mode.out" | tr '\n' ' '))"
    fi
    s6="$s6 $mode='$got'"
    case $mode in
        unset) if [ "$boot_intel" = yes ]; then want=/usr/share/glvnd/egl_vendor.d/50_mesa.json; else want=""; fi ;;
        kept)  want=/usr/share/glvnd/egl_vendor.d/./50_mesa.json ;;
    esac
    [ "$got" = "$want" ] || s6="$s6(want '$want')"
done
case $s6 in
    *"(want"*) say "S6 FAIL (boot GPU Intel: $boot_intel;$s6)" ;;
    *) say "S6 PASS (boot GPU Intel: $boot_intel;$s6)" ;;
esac

# ---- S7: the PAM services: the old name's files only, then both ---------------------------------------------
s7=""
for variant in old both none; do
    a1_pam_set "$variant"
    session "$W/s7$variant.out"
    if a1_wait_log 'LARESLOCK secure' 15; then
        got=$(a1_lock_log | grep -a 'LARESLOCK pam services' | tail -1 | sed 's/.*pam services: //')
        if unlock_pw && wait_no_sup 8; then s7="$s7 $variant: unlocked, '$got';"; else s7="$s7 $variant: NOT unlocked ('$got');"; a1_kill_lock; fi
    else
        s7="$s7 $variant: no lock ($(tail -2 "$W/s7$variant.out" | tr '\n' ' '));"
    fi
done
case $s7 in
    *"old: unlocked, 'password qs-lock, face qs-lock-face'"*"both: unlocked, 'password lares-lock, face lares-lock-face'"*"none: unlocked, 'password login, face qs-lock-face'"*)
        say "S7 PASS (only the old PAM files: the lock asks qs-lock and the password unlocks it; with both, the new ones win; with neither, login:$s7)" ;;
    *) say "S7 FAIL ($s7)" ;;
esac
a1_pam_set new

# ---- S11: the last resort's PAM service: the old name's file only -> the pinned config with qs-lock ------------------------
s11=""
pinned=$(sed -n 's/^[[:space:]]*module = //p' "$T/tools/lockscreen/hyprlock.conf" | head -1)
for variant in old:qs-lock none:login; do
    a1_pam_set "${variant%%:*}"
    rm -f "$W/hyprlock.calls" "$W/hyprlock.release"
    session "$W/s11.out"
    if a1_wait_log 'LARESLOCK secure' 15; then
        sleep 0.5
        "$E" run env LARES_LOCK_PAM_DIR="$W/pam.d" bash "$LK/lares-lock" --rescue > "$W/s11.rescue" 2>&1
        wait_text "$W/hyprlock.calls" HYPRLOCK 10
        conf=$(sed -n 's/^HYPRLOCK --grace 0 -c //p' "$W/hyprlock.calls" | head -1)
        mod=$(sed -n 's/^[[:space:]]*module = //p' "$conf" 2> /dev/null | head -1)
        touch "$W/hyprlock.release"; wait_no_sup 8
        if [ "$conf" = "$RT/lares-lock.hyprlock.conf" ] && [ "$mod" = "${variant#*:}" ]; then s11="$s11 ${variant%%:*}: $mod;"
        else s11="$s11 ${variant%%:*}: FAIL (config '$conf' says module '$mod');"; fi
    else
        s11="$s11 ${variant%%:*}: FAIL (no lock to rescue: $(tail -3 "$W/s11.out" | tr '\n' ' '));"
    fi
done
case $s11 in
    *FAIL*) say "S11 FAIL ($s11)" ;;
    *) if [ "$pinned" = lares-lock ]; then say "S11 PASS (hyprlock got a copy of the pinned config with the service that is installed:$s11 the pinned file itself still says $pinned)"
       else say "S11 FAIL (the pinned file says '$pinned')"; fi ;;
esac
a1_pam_set new

# ---- S9 / S10: a lock of the OLD name that is up -----------------------------------------------------------------
( "$E" run flock -n "$RT/qs-lock.lock" sleep 602 > /dev/null 2>&1 & )
sleep 0.6
hold=$(env_pids 'sleep 602' | head -1)
calls0=$(grep -c . "$W/screentimed.calls" 2> /dev/null || echo 0)
session "$W/s9.out"
sleep 2.5
calls1=$(grep -c . "$W/screentimed.calls" 2> /dev/null || echo 0)
if [ -n "$hold" ] && held && [ -z "$(sup_pids)" ] && [ "$calls1" = "$calls0" ] && ! a1_wait_log 'LARESLOCK secure' 2; then
    say "S9 PASS (a lock of the old name is up: lares-lock-held on the new file name says held; the launcher exited at once and started nothing)"
else
    say "S9 FAIL (holder='$hold' held=$(held && echo yes || echo no) supervisors='$(sup_pids | paste -sd, -)' screentimed calls $calls0 -> $calls1)"
fi
if [ -n "$(sup_pids)" ]; then unlock_pw > /dev/null 2>&1; wait_no_sup 8 || a1_kill_lock; fi   # a second lock started: end it so the next check starts clean
timeout 10 "$E" run env LARES_LOCK_FACE=0 LARES_LOCK_PAM_DIR="$W/pam.d" bash "$LK/lares-lock" > "$W/s10.out" 2>&1; rc10=$?   # a supervisor that DOES start a lock stays up: the timeout ends the wait, the check fails
if [ "$rc10" -eq 0 ] && grep -q "a lock of the old name (qs-lock) is up" "$W/s10.out" && [ -z "$(sup_pids)" ]; then
    say "S10 PASS (the supervisor itself refuses to start beside a lock of the old name: exit 0, said so, none started)"
else
    say "S10 FAIL (rc=$rc10 supervisors='$(sup_pids | paste -sd, -)': $(tail -2 "$W/s10.out" | tr '\n' ' '))"
fi
if [ -n "$(sup_pids)" ]; then unlock_pw > /dev/null 2>&1; wait_no_sup 8 || a1_kill_lock; fi
[ -n "$hold" ] && kill "$hold" 2> /dev/null

finish
