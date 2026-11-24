# shellcheck shell=bash
# The helpers both lares probes share (tools/dev/lares_tool_probe.sh, tools/dev/lares_deploy_probe.sh: a fake
# world each). Sourced, never run.
#
# It expects the caller to have set: LARES_FAKE (the dir of the stubs' log and ctl files, which is also the
# marker every process of the world carries in its environment), LOGF (= $LARES_FAKE/stub.log), FIX (this
# directory: tools/dev/fixtures/lares), ROOT, REPO, SESSION_SIG (the Hyprland signature of the
# world's session -- the scope the tool works in) and the counters PASSES / FAILS / FAILED=().

ok()    { PASSES=$(( PASSES + 1 )); echo "  ok   $*"; }
bad()   { FAILS=$(( FAILS + 1 )); FAILED+=("$*"); echo "  FAIL $*"; }
check() { local n=$1; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }
note()  { echo "-- $*"; }

# ---- tiny independent process helpers (not the tool's) --------------------------------------------
alive() { local s; s=$(awk '/^State:/ {print $2}' "/proc/$1/status" 2> /dev/null); [ -n "$s" ] && [ "$s" != Z ]; }
waitfor() { local n=$1 i; shift; for (( i = 0; i < n * 20; i++ )); do "$@" && return 0; sleep 0.05; done; return 1; }
gone() { ! alive "$1"; }
env_is() { { tr '\0' '\n' < "/proc/$1/environ"; } 2> /dev/null | grep -qx "$2"; }
marked() { env_is "$1" "LARES_FAKE=$LARES_FAKE"; }   # carries the world's marker
# fake_pids <comm> [cmdline substring]: this world's live processes of that comm
fake_pids() {
    local p c
    for p in /proc/[0-9]*; do
        read -r c 2> /dev/null < "$p/comm" || continue   # builtin reads only: this runs over every process of the machine
        [ "$c" = "$1" ] || continue
        [ -O "$p" ] || continue
        marked "${p#/proc/}" || continue
        alive "${p#/proc/}" || continue
        if [ -n "${2:-}" ]; then tr '\0' ' ' < "$p/cmdline" | grep -qF -- "$2" || continue; fi
        echo "${p#/proc/}"
    done
}
fake_pid() { fake_pids "$@" | head -1; }
waybars_of() {   # waybars of the world with that Hyprland signature
    local p
    for p in $(fake_pids waybar); do env_is "$p" "HYPRLAND_INSTANCE_SIGNATURE=$1" && echo "$p"; done
}
session_waybars() { waybars_of "$SESSION_SIG"; }
all_gone() { local p; for p in "$@"; do alive "$p" && return 1; done; return 0; }
all_alive() { local p; [ "$#" -gt 0 ] || return 1; for p in "$@"; do alive "$p" || return 1; done; return 0; }
one_of() { [ "$(printf '%s\n' "$1" | grep -c .)" -eq 1 ]; }   # a list of exactly one line

# ---- the stub log -----------------------------------------------------------------------------------
mark()  { echo "MARK $1" >> "$LOGF"; }
since() { sed -n "/^MARK $1\$/,\$p" "$LOGF"; }
count_since() { since "$1" | grep -cF -- "$2"; }
has_since() { since "$1" | grep -qF -- "$2"; }
no_since() { ! has_since "$1" "$2"; }
# ordered <mark> <pattern>...: the patterns appear after the mark, each on a later line than the one before
ordered() {
    local label=$1 pat i=0
    local -a L
    shift
    mapfile -t L < <(since "$label")
    for pat in "$@"; do
        while [ "$i" -lt "${#L[@]}" ] && [[ ${L[$i]} != *"$pat"* ]]; do i=$(( i + 1 )); done
        if [ "$i" -ge "${#L[@]}" ]; then echo "      (not found in order: $pat)" >&2; return 1; fi
        i=$(( i + 1 ))
    done
}

# ---- the fixture repo the tool is pointed at ------------------------------------------------------------
make_repo() {   # make_repo [shell.qml text]: a git repo with the files the tool reads, one commit
    local r=$REPO n qml=${1:-}
    [ -n "$qml" ] || qml=$(printf 'import Quickshell\nShellRoot {}')
    mkdir -p "$r/tools/osd" "$r/modules/clock" "$r/modules/stocks" "$r/tools/dev" "$r/tools/stt/ime" "$r/tools/theme"
    printf '%s\n' "$qml" > "$r/shell.qml"
    printf '#!/bin/sh\n' > "$r/tools/osd/shot.sh"; chmod +x "$r/tools/osd/shot.sh"
    printf '#!/bin/sh\n' > "$r/tools/theme/themectl"; chmod +x "$r/tools/theme/themectl"
    printf '/* lares-ime, a stand-in: deploy says to rebuild it when this changes */\n' > "$r/tools/stt/ime/lares-ime.c"
    cat > "$r/tools/dev/lock_env.sh" << 'SH'
#!/bin/sh
# A stand-in for tools/dev/lock_env.sh in the fixture repo (what `lares preview` runs): records its calls; `run`
# runs the command in the probe's own world -- there is no nested compositor here and no window anywhere.
: "${LARES_FAKE:?}"
echo "LOCKENV $* [LOCK_ENV=${LOCK_ENV:-} HOST=${HOST:-}]" >> "$LARES_FAKE/stub.log"
case ${1:-} in
    up) mkdir -p "/tmp/lrlk-${LOCK_ENV:?}"; : > "/tmp/lrlk-$LOCK_ENV/up" ;;
    down) rm -rf "/tmp/lrlk-${LOCK_ENV:?}" ;;
    run) shift; exec "$@" ;;
esac
SH
    chmod +x "$r/tools/dev/lock_env.sh"
    mkdir -p "$r/.examples" "$r/helpers/silicon_helper/polkit"
    cp "$FIX"/polkit_standins/* "$r/helpers/silicon_helper/polkit/"   # R3 of `setup` installs them from the snapshot (stand-ins: a sandbox copy has no helpers/)
    ln -s "${QMLLS_TARGET:-${XDG_RUNTIME_DIR:-/nonexistent}/quickshell/vfs/fakeid/.qmlls.ini}" "$r/.qmlls.ini"   # an older tree tracked it: the snapshot leaves it out either way
    for n in modules/clock/ClockStyle.qml modules/clock/Other.qml modules/stocks/StocksStyle.qml; do
        printf 'Item { property int value: 1 }\n' > "$r/$n"
    done
    # what lares snapshots for the lock (THE SNAPSHOTS): the real scripts (only parsed and found executable here, never run),
    # stand-ins for the QML and the configs
    mkdir -p "$r/lock" "$r/modules/lockscreen/lock" "$r/themes" "$r/tools/lockscreen"
    printf 'import Quickshell\nShellRoot {}\n' > "$r/lock/shell.qml"
    printf 'Item { property int value: 1 }\n' > "$r/modules/lockscreen/lock/LockRoot.qml"
    printf '{"fixture": "eva"}\n' > "$r/themes/eva.json"
    for n in lockscreen locale; do printf '{"fixture": "%s"}\n' "$n" > "$r/.examples/$n.jsonc"; done
    for n in lares-lock lares-lock-session lares-lock-held; do cp "$ROOT/tools/lockscreen/$n" "$r/tools/lockscreen/$n"; done
    # the shader warmer's stand-in: records its call (the real one starts a headless sway)
    # shellcheck disable=SC2016   # the stand-in's own script, expanded when IT runs
    printf '#!/bin/sh\necho "WARM $*" >> "$LARES_FAKE/stub.log"\n' > "$r/tools/lockscreen/lares-lock-warm"
    chmod +x "$r/tools/lockscreen/lares-lock-warm"
    ( cd "$r" && git -c init.defaultBranch=main init -q && git config user.name Probe && git config user.email probe@example.invalid \
        && git add -A && git commit -q -m "fixture" )
}

# spawn_fake <stub> [args...]: start a stub as a compositor child would be -- detached, a session of its own
spawn_fake() { ( setsid -f "$FIX/bin/$1" "${@:2}" < /dev/null > /dev/null 2>&1 ); }
