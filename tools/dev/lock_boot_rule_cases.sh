#!/usr/bin/env bash
# When `lares-lock-session --boot` locks: the launcher's rule (`login_asked`), case by case, with no compositor and no lock. The
# launcher runs from a copy beside a STUB supervisor that only says it was started; logind's session records, the compositor's
# pid file and the compositor itself (a sleep under another name) are this runner's own.
#
#   tools/dev/lock_boot_rule_cases.sh             ends in LOCK_BOOT_RULE RESULT PASS|FAIL
#   ARM=<name> tools/dev/lock_boot_rule_cases.sh  a fault in the copy; must FAIL the case named
#   ARM=all
#     alwayslock   a greeter's session is locked as well                         -> greeter
#     neverlock    an autologin session is not locked                            -> autologin
#     heldblind    a compositor that holds the session locked is not looked at   -> held
#     anyservice   a service the rule does not know counts as asked              -> unknown
#     nowait       the compositor's pid file is read once, at the start          -> late
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PNAME=LOCK_BOOT_RULE
ARMS="alwayslock neverlock heldblind anyservice nowait"
arm_check() { case $1 in alwayslock) echo greeter ;; neverlock) echo autologin ;; heldblind) echo held ;; anyservice) echo unknown ;; nowait) echo late ;; esac; }
if [ "${ARM:-}" = all ]; then
    bad=0
    for a in $ARMS; do
        line=$(ARM=$a "$0" 2>&1 | grep -a "^$PNAME ARM $a" | tail -1)
        echo "${line:-$PNAME ARM $a BAD (no verdict)}"
        case $line in *"FAILED AS IT MUST"*) ;; *) bad=1 ;; esac
    done
    [ "$bad" -eq 0 ] && { echo "$PNAME ARMS PASS"; exit 0; }
    echo "$PNAME ARMS FAIL"; exit 1
fi
W=$(mktemp -d "${TMPDIR:-/tmp}/lrbr.XXXXXX") || exit 1
PIDS=()
trap 'for p in "${PIDS[@]}"; do kill "$p" 2> /dev/null; done; rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/rt/hypr/sig" "$W/sessions"
cp "$ROOT/tools/lockscreen/lares-lock-session" "$W/bin/" || exit 1
printf '#!/bin/sh\necho "LOCKED $*"\n' > "$W/bin/lares-lock"
printf '#!/bin/sh\nexit 1\n' > "$W/bin/lares-lock-held"
chmod +x "$W/bin"/*
arm() {   # arm <old> <new>: in the copy, OLD exactly once
    python3 - "$W/bin/lares-lock-session" "$1" "$2" << 'PY' || { echo "$PNAME ARM $ARM BAD (anchor gone)"; echo "$PNAME RESULT FAIL (ARM anchor gone)"; exit 3; }
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
sys.exit(1) if s.count(old) != 1 else open(p, "w").write(s.replace(old, new))
PY
}
case ${ARM:-} in
    "") ;;
    alwayslock) arm 'if [ "${1:-}" = --boot ] && login_asked; then exit 0; fi' 'true' ;;
    neverlock)  arm 'case $svc in sddm|gdm-password|lightdm) ;; *) return 1 ;; esac' 'case $svc in sddm*|gdm-password|lightdm) ;; *) return 1 ;; esac' ;;
    heldblind)  arm "grep -qx -- '--locked-cmd' && return 1" "grep -qx -- '--locked-cmd' && return 0" ;;
    anyservice) arm 'case $svc in sddm|gdm-password|lightdm) ;; *) return 1 ;; esac' 'true' ;;
    nowait)     arm 'for (( n = 0; n < 60; n++ )); do [ -s "$hl" ] && break; sleep 0.05; done' ':' ;;
    *) echo "$PNAME RESULT FAIL (no such ARM: $ARM)"; exit 3 ;;
esac
fails=0 FAILED=""
# compositor <args...>: a process whose command line is those words; its pid in the pid file
compositor() { python3 -c 'import os, sys, time; os.execv("/usr/bin/sleep", sys.argv[1:])' "$@" & PIDS+=("$!"); printf '%s\nwayland-1\n' "$!" > "$W/rt/hypr/sig/hyprland.lock"; sleep 0.2; }
check() {   # check <name> <want: locked|skipped> <what> [launcher args...]
    local name=$1 want=$2 what=$3 out got; shift 3
    out=$(env -i PATH="$PATH" HOME="$HOME" XDG_RUNTIME_DIR="$W/rt" LOCK_ENV_DIR="$W" LARES_SESSIONS_DIR="$W/sessions" HYPRLAND_INSTANCE_SIGNATURE="${SIG-sig}" \
        ${SID+XDG_SESSION_ID="$SID"} PATH="/usr/bin:/bin" bash "$W/bin/lares-lock-session" "$@" 2> "$W/err")
    case $out in *LOCKED*) got=locked ;; *) got=skipped ;; esac
    if [ "$got" = "$want" ]; then echo "$PNAME $name PASS ($what: $got)"
    else echo "$PNAME $name FAIL ($what: $got, want $want; $(head -c 200 "$W/err"))"; fails=$(( fails + 1 )); FAILED="$FAILED $name"; fi
}
session() { printf 'UID=1000\nSERVICE=%s\nTYPE=wayland\n' "$1" > "$W/sessions/7"; }
SID=7
compositor Hyprland 600
session sddm-autologin; check autologin locked "SDDM's autologin: nobody typed a password" --boot
session sddm;           check greeter skipped "SDDM's greeter asked" --boot
session sddm;           check asked locked "the same session, a lock the user asked for (no --boot)"
session gdm-password;   check gdm skipped "GDM's greeter asked" --boot
session login;          check tty locked "a TTY login (agetty's autologin is the same service)" --boot
session greetd;         check unknown locked "a service the rule does not know" --boot
rm -f "$W/sessions/7";  check norecord locked "no session record" --boot
session sddm; SID="";   check noid locked "no session id in the environment" --boot
SID=../7;               check badid locked "a session id that is no id" --boot
SID=7; SIG=gone;        check nocompositor locked "no compositor to look at" --boot
# the autostart runs before Hyprland has written its pid file: the same file, 0.6 s late
SIG=late; mkdir -p "$W/rt/hypr/late"
( sleep 0.6; cp "$W/rt/hypr/sig/hyprland.lock" "$W/rt/hypr/late/hyprland.lock" ) & PIDS+=("$!")
session sddm;           check late skipped "SDDM's greeter asked, and Hyprland writes its pid file 0.6 s later" --boot
SIG=sig
python3 -c 'import time; time.sleep(600)' --locked-cmd /usr/local/bin/lares-boot-lock & PIDS+=("$!")
printf '%s\nwayland-1\n' "$!" > "$W/rt/hypr/sig/hyprland.lock"; sleep 0.2
session sddm;           check held locked "a compositor started with --locked-cmd, behind a greeter" --boot
if [ -n "${ARM:-}" ]; then
    want=$(arm_check "$ARM")
    case " $FAILED " in *" $want "*) echo "$PNAME ARM $ARM FAILED AS IT MUST ($want)" ;; *) echo "$PNAME ARM $ARM BAD (${FAILED:+failed$FAILED, }not $want)" ;; esac
fi
if [ "$fails" -eq 0 ]; then echo "$PNAME RESULT PASS"; else echo "$PNAME RESULT FAIL ($fails:$FAILED)"; exit 1; fi
