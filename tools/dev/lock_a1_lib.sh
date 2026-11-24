# shellcheck shell=bash
# Sourced by the lock process's probe runners (stream A1), never run.
#
# One private world per runner: an isolated Hyprland (tools/dev/lock_env.sh), a
# scratch COPY of the tree in which the lock's PAM directory points at a private
# pam.d whose stacks use a scripted stub module instead of pam_unix / pam_howdy
# (so no probe needs a password or the camera, and none touches the faillock
# tally), and a fake shell on the lock's socket (tools/dev/lock_env/a1_fake_shell.py).
#
# The production code has `configDirectory` "/etc/pam.d" and no override; only
# the COPY is patched (a1_tree), and the patch is verified to have landed once.
#
#   a1_init NAME          sets E B T W FS (NAME starts with a1)
#   a1_build_pam          the stub module + pam.d + scripts in $W
#   a1_tree [json]        the tree copy; lockscreen.json content = $1 (default {})
#   a1_up [ENV=VAL...]    the env (extra vars go to `lock_env.sh up`), fixture desktop
#   a1_fake [args...]     start the fake shell; a1_fake_stop
#   a1_lock [ENV=VAL...]  start the supervisor in the env (background); $SUP = its pid
#   a1_state FIELD        the latest LockState field the fake shell heard
#   a1_wait_state F V S   wait up to S seconds for state F == V
#   a1_shot NAME          grim the layout to $W/NAME.png; a1_px NAME X Y
#   a1_down               everything down
# shellcheck disable=SC2034
A1_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$A1_ROOT/tools/dev/result_lib.sh"
E="$A1_ROOT/tools/dev/lock_env.sh"
A1_LOCK_ARGS="${A1_LOCK_ARGS:-}"

a1_init() {
    # A1_ENV_PREFIX: a parallel stream names its envs apart (r2a_) so two streams never share one.
    NAME="${A1_ENV_PREFIX:-}$1"; export LOCK_ENV="$NAME"
    B="/tmp/lrlk-$NAME"; T="/tmp/lrlk-$NAME-t"; W="/tmp/lrlk-$NAME-w"; FS="$W/fake"
    FX="$W/fx"; SUP=""
    mkdir -p "$W"
}

a1_build_pam() {
    rm -rf "$W/pam.d" "$W/marks"; mkdir -p "$W/pam.d" "$W/marks"
    gcc -shared -fPIC -O2 -Wall -o "$W/pam_lrlk_stub.so" "$A1_ROOT/tools/dev/lock_env/pam_stub.c" -lpam || return 1
    printf 'auth required %s script=%s\n' "$W/pam_lrlk_stub.so" "$W/pw.script" > "$W/pam.pw.tpl"
    printf 'auth [success=done default=die] %s script=%s\nauth required pam_deny.so\n' "$W/pam_lrlk_stub.so" "$W/face.script" > "$W/pam.face.tpl"
    a1_pam_set new
    a1_scripts 'prompt Password: 
expect hunter2
faildelay 2000' 'sleep 60000'
}
# a1_pam_set old|new|both|none -- which service files the stub pam.d holds: lares-lock / lares-lock-face (new: the default), the OLD name's
# qs-lock / qs-lock-face, both (the lock asks the new ones once they are there), or none (a fresh machine: only its own `login`, which answers as the
# stub then and DENIES in every other variant, so a lock that asked it there would never open). Between two locks only: AuthController reads it when it is built.
a1_pam_set() {
    rm -f "$W/pam.d/lares-lock" "$W/pam.d/lares-lock-face" "$W/pam.d/qs-lock" "$W/pam.d/qs-lock-face"
    if [ "$1" = none ]; then cp "$W/pam.pw.tpl" "$W/pam.d/login"; else printf 'auth required pam_deny.so\n' > "$W/pam.d/login"; fi
    case $1 in new|both) cp "$W/pam.pw.tpl" "$W/pam.d/lares-lock"; cp "$W/pam.face.tpl" "$W/pam.d/lares-lock-face" ;; esac
    case $1 in old|both) cp "$W/pam.pw.tpl" "$W/pam.d/qs-lock"; cp "$W/pam.face.tpl" "$W/pam.d/qs-lock-face" ;; esac
}
# a1_pam_guard -- THE LAW: immediately before ANY lock starts, the tree copy's AuthController.pamDirectory is the stub's (a copy overlaid with another
# revision's modules/ puts the real /etc/pam.d back, and every password the runner types goes to the machine's PAM).
a1_pam_guard() {
    grep -q "property string pamDirectory: \"$W/pam.d\"" "$T/modules/lockscreen/lock/AuthController.qml" 2> /dev/null && return 0
    echo "a1: the tree copy's pamDirectory is NOT the stub's ($W/pam.d): no lock is started" >&2
    return 1
}

# a1_scripts PASSWORD_SCRIPT FACE_SCRIPT
a1_scripts() { printf '%s\n' "$1" > "$W/pw.script"; printf '%s\n' "$2" > "$W/face.script"; }

a1_tree() {
    rm -rf "$T"; mkdir -p "$T"
    rsync -a --exclude '.git/' "$A1_ROOT/lock" "$A1_ROOT/modules" "$A1_ROOT/themes" "$A1_ROOT/tools" "$A1_ROOT/.examples" "$T/" || return 1
    local f="$T/modules/lockscreen/lock/AuthController.qml"
    [ "$(grep -c 'property string pamDirectory: "/etc/pam.d"' "$f")" = 1 ] || { echo "a1_tree: pamDirectory anchor missing"; return 1; }
    sed -i "s|property string pamDirectory: \"/etc/pam.d\"|property string pamDirectory: \"$W/pam.d\"|" "$f"
    printf '%s\n' "${1:-{\}}" > "$T/lockscreen.json"
    [ -n "${A1_STALL_MS:-}" ] && a1_patch modules/lockscreen/lock/AuthController.qml 'property int stallMs: 30000' "property int stallMs: $A1_STALL_MS"
    return 0
}

# a1_patch FILE OLD NEW  -- in the TREE COPY only; OLD must occur exactly once.
a1_patch() {
    python3 - "$T/$1" "$2" "$3" <<'PY' || return 1
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1:
    print("a1_patch: %d occurrences of %r in %s" % (s.count(old), old, p)); sys.exit(1)
open(p, "w").write(s.replace(old, new))
PY
}

# a1_seq FIELD -- the values the fake shell heard for a LockState field, in
# order, each once, as value@ms-since-the-first-line.
a1_seq() {
    python3 - "$FS/recv.log" "$1" <<'PY'
import sys, json
out, last, t0 = [], object(), None
for ln in open(sys.argv[1]):
    ms, _, line = ln.partition(" ")
    if t0 is None: t0 = int(ms)
    try: m = json.loads(line)
    except Exception: continue
    if m.get("t") != "state": continue
    v = m["s"].get(sys.argv[2])
    if v != last:
        out.append("%s@%d" % (v, int(ms) - t0)); last = v
print(" ".join(out))
PY
}

# Kill this env's lock (supervisor + quickshell) without unlocking: the
# session goes lockdead, and the next lock takes over.
a1_kill_lock() {
    local p
    for p in $("$E" status | grep -E 'lares-lock|lock/shell.qml' | awk '{print $1}'); do kill -9 "$p" 2> /dev/null; done
    sleep 0.3
}

a1_up() {
    "$E" down > /dev/null 2>&1
    rm -rf "$FX"; mkdir -p "$FX"; cp "$A1_ROOT"/tools/dev/lock_env/probes/desktop_fixture.qml "$FX/"
    env AUTOSTART="quickshell -p $FX/desktop_fixture.qml" "$@" "$E" up > /dev/null || { echo "a1: env up failed"; return 1; }
    sleep 2
}

a1_fake() {
    a1_fake_stop
    rm -rf "$FS"; mkdir -p "$FS"
    python3 "$A1_ROOT/tools/dev/lock_env/a1_fake_shell.py" --sock "$B/rt/lares-lock/wayland-1.sock" --dir "$FS" "$@" > "$FS.out" 2>&1 &
    FAKEPID=$!
    sleep 0.3
}
a1_fake_stop() {
    [ -n "${FAKEPID:-}" ] && kill "$FAKEPID" 2> /dev/null
    FAKEPID=""
}
a1_fake_cmd() { echo "$*" >> "$FS/cmd"; }

# The supervisor, in the env, in the background. Its log: $B/rt/lares-lock.log.
# A1_LOCK_ENV="VAR=val ..." adds to every lock's environment (a diagnostic such as
# QT_LOGGING_RULES=quickshell.service.pam.debug=true).
a1_lock() {
    a1_pam_guard || return 1
    ( "$E" run env ${A1_LOCK_ENV:-} "$@" bash "$T/tools/lockscreen/lares-lock" $A1_LOCK_ARGS > "$W/sup.out" 2>&1 & echo $! > "$W/sup.pid" )
    sleep 0.1; SUP=$(cat "$W/sup.pid")
}
a1_lock_log() { rl_clean "$B/rt/lares-lock.log"; }
a1_sup_alive() { kill -0 "$SUP" 2> /dev/null; }
# Wait (S seconds) for a line in the lock's log
a1_wait_log() { local ere=$1 s=${2:-10} i; for i in $(seq 1 $((s * 10))); do a1_lock_log | grep -aqE "$ere" && return 0; sleep 0.1; done; return 1; }

a1_state() { jq -r ".$1" "$FS/state.json" 2> /dev/null; }
a1_wait_state() {
    local f=$1 v=$2 s=${3:-10} i
    for i in $(seq 1 $((s * 20))); do [ "$(a1_state "$f")" = "$v" ] && return 0; sleep 0.05; done
    return 1
}
a1_shot() { "$E" shot "$W/$1.png" "${2:-}" 2> /dev/null; }
a1_px() { python3 -c "from PIL import Image; print(*Image.open('$W/$1.png').convert('RGB').getpixel(($2,$3)))"; }

a1_down() {
    a1_fake_stop
    [ -n "${SUP:-}" ] && kill "$SUP" 2> /dev/null
    "$E" down > /dev/null 2>&1
    rm -rf "$T" "$W"
}
