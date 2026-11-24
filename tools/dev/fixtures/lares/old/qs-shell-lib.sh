# shellcheck shell=bash
# Shared by tools/shell/qs-shell and tools/shell/qs-shell-supervise: small helpers that keep no state
# of their own. Sourced, never run. Needs bash 5 ($EPOCHREALTIME, printf '%(...)T', mapfile -d).
#
# THE SCOPE RULE. Every process this tool looks for is found through /proc, and /proc is the whole machine:
# a second Hyprland (the nested one under tools/dev/lock_env.sh, a probe's fake world) has processes of its
# own, and the tool must never reach them -- nor can a probe's fake world be trusted to keep the REAL
# session's processes out of a scan by comm. So a process only counts when it is MINE (uid) and carries THIS
# session's HYPRLAND_INSTANCE_SIGNATURE and XDG_RUNTIME_DIR in its environment (every child of Hyprland
# inherits both). `in_session` is that test; every finder below goes through it.

# ---- time ----------------------------------------------------------------------------------------
now_s()  { printf '%(%s)T' -1; }
now_ms() { local t=${EPOCHREALTIME//[.,]/}; printf '%s' "${t%???}"; }

# to_ms <seconds, maybe fractional> -> whole milliseconds ("0.5" -> 500, "2" -> 2000)
to_ms() {
    local v=$1 whole=${1%%.*} frac=""
    [[ $v == *.* ]] && frac=${v#*.}
    frac=${frac}000
    printf '%s' $(( ${whole:-0} * 1000 + 10#${frac:0:3} ))
}

# ---- logging -------------------------------------------------------------------------------------
# Every line goes to each file named in LOG_FILES (the caller sets it) with the time and LOG_TAG.
LOG_TAG=${LOG_TAG:-qs-shell}
LOG_FILES=()
log() {
    local line f
    printf -v line '%(%H:%M:%S)T %s: %s' -1 "$LOG_TAG" "$*"
    # stderr first: a failed `>> "$f"` (no state dir yet: a dry run on a fresh machine) reports on the stderr in force
    for f in "${LOG_FILES[@]}"; do printf '%s\n' "$line" 2> /dev/null >> "$f"; done
    return 0
}
say()  { printf '%s\n' "$*"; log "$*"; }
warn() { printf '%s: WARN %s\n' "$LOG_TAG" "$*" >&2; log "WARN $*"; }
die()  { printf '%s: %s\n' "$LOG_TAG" "$*" >&2; log "FATAL $*"; exit 1; }

# ---- quoting -------------------------------------------------------------------------------------
# lua_escape: the inside of a Lua "..." string.   shquote: one word for `sh -c`.
lua_escape() { local s=${1//\\/\\\\}; printf '%s' "${s//\"/\\\"}"; }
shquote() {
    local q="'" r="'\\''"
    printf "'%s'" "${1//$q/$r}"
}
trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# ---- files ---------------------------------------------------------------------------------------
# atomic_write <file>: the content on stdin lands whole or not at all (same directory, then rename),
# and never as an empty file -- a producer that failed must not leave the file blank.
atomic_write() {
    local f=$1 tmp
    tmp=$(mktemp "$f.XXXXXX") || return 1
    [ -e "$f" ] && chmod --reference="$f" "$tmp" 2> /dev/null
    if cat > "$tmp" && [ -s "$tmp" ] && mv -f "$tmp" "$f"; then return 0; fi
    rm -f "$tmp"
    return 1
}

# ---- processes -----------------------------------------------------------------------------------
# The one-letter state of a pid ("" when it is gone). A zombie is dead for every purpose here: a
# child that was not wait()ed for still answers kill -0.
pid_state() {
    local k v
    while read -r k v _; do
        [ "$k" = State: ] && { printf '%s' "$v"; return 0; }
    done 2> /dev/null < "/proc/$1/status"
    return 0
}
pid_alive() { local s; s=$(pid_state "$1"); [ -n "$s" ] && [ "$s" != Z ] && [ "$s" != X ]; }
pid_gone()  { ! pid_alive "$1"; }
pid_comm()  { local c; read -r c 2> /dev/null < "/proc/$1/comm" && printf '%s' "$c"; }

# pid_start <pid>: the process's start time (field 22 of /proc/<pid>/stat, in clock ticks since boot); nothing when it is gone.
# With the pid it is the process's identity: a pid is reused, the pair is not.
pid_start() {
    local s
    s=$(cat "/proc/$1/stat" 2> /dev/null) || return 1
    s=${s##*) }
    # shellcheck disable=SC2086   # the fields after the command name, split on blanks: $1 is field 3, so field 22 is the 20th
    set -- $s
    printf '%s' "${20:-}"
}

# pid_argv <array name> <pid>: the command line, one element per argument.
pid_argv() {
    mapfile -d '' -t "$1" 2> /dev/null < "/proc/$2/cmdline"
}

# pid_env_has <pid> <NAME=value>: 0 when the process's environment holds exactly that entry.
pid_env_has() {
    local e
    while IFS= read -r -d '' e; do
        [ "$e" = "$2" ] && return 0
    done 2> /dev/null < "/proc/$1/environ"
    return 1
}

# in_session <pid>: mine, and of THIS Hyprland session (see the scope rule above).
in_session() {
    [ -O "/proc/$1" ] || return 1
    pid_env_has "$1" "HYPRLAND_INSTANCE_SIGNATURE=${HYPRLAND_INSTANCE_SIGNATURE:-}" \
        && pid_env_has "$1" "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-}"
}

# session_pids_by_comm <comm>: pids of this session's processes whose comm is <comm>.
session_pids_by_comm() {
    local f p c
    for f in /proc/[0-9]*/comm; do
        p=${f#/proc/}; p=${p%/comm}
        read -r c 2> /dev/null < "$f" || continue
        [ "$c" = "$1" ] && in_session "$p" && printf '%s\n' "$p"
    done
    return 0
}

# wait_until <seconds, maybe fractional> <command...>: poll every 50 ms; 0 when the command succeeded.
wait_until() {
    local deadline=$(( $(now_ms) + $(to_ms "$1") ))
    shift
    while ! "$@"; do
        [ "$(now_ms)" -ge "$deadline" ] && return 1
        sleep 0.05
    done
    return 0
}

# stop_pid <pid> <comm> [seconds]: TERM, then KILL when it ignores it. A pid that is no longer <comm>
# (the number was reused) is left alone; 0 when the process is gone afterwards.
stop_pid() {
    local pid=$1 comm=$2 limit=${3:-${STOP_TIMEOUT:-5}}
    pid_alive "$pid" || return 0
    [ "$(pid_comm "$pid")" = "$comm" ] || { log "pid $pid is no longer $comm: left alone"; return 0; }
    kill -TERM "$pid" 2> /dev/null
    wait_until "$limit" pid_gone "$pid" && return 0
    log "pid $pid ($comm) ignored TERM for ${limit}s: KILL"
    kill -KILL "$pid" 2> /dev/null
    wait_until 3 pid_gone "$pid"
}

# ---- .qmlls.ini ------------------------------------------------------------------------------------------
# Two quickshells with different entry files in a root that holds a `.qmlls.ini` fall into a re-link
# ping-pong (~24 000 dirent events/s and ~1.3 cores EACH, until one exits) on the
# first event in the root; QS_DISABLE_FILE_WATCHER and settings.watchFiles do not prevent it. With NO
# .qmlls.ini in the root nothing is written and it cannot start. The file is a symlink into
# $XDG_RUNTIME_DIR/quickshell/vfs/ (untracked, in .gitignore), so it is MOVED (mv: the link itself, never read through) to
# <dir>/qmlls.ini.saved while `qs-shell preview` runs its quickshell in the repo, and put back exactly after. (The deployed
# shell runs from a snapshot whose root holds none: nothing to move.)
#
# <dir> is the caller's PERSISTENT directory ($XDG_STATE_HOME/qs-shell/qmlls), never the runtime dir: that is a tmpfs,
# and a reboot in the middle of a preview would leave the root without its link for the user to find.
# Beside the link <dir>/record says whose it is -- `root=<the root it came from>` and `owner=preview:<pid of the qs-shell
# that set it aside>` -- so that any later qs-shell command can give it back (qs-shell's qmlls_recover).

qmlls_present() { [ -L "$1/.qmlls.ini" ] || [ -e "$1/.qmlls.ini" ]; }
qmlls_is_vfs_link() {   # qmlls_is_vfs_link <file>: a symlink into quickshell's own vfs dir (made at will by any instance)
    local t; [ -L "$1" ] || return 1
    t=$(readlink "$1")
    [[ $t == "${XDG_RUNTIME_DIR:-/nonexistent}/quickshell/vfs/"* ]]
}

# qmlls_record_get <dir> <key>: one value of <dir>/record ("" when there is none).
qmlls_record_get() { sed -n "s/^$2=//p" "$1/record" 2> /dev/null | head -1; }

# qmlls_forget <dir>: the record goes, and the directory when nothing else is kept in it.
qmlls_forget() {
    rm -f -- "$1/record"
    rmdir -- "$1" 2> /dev/null
    return 0
}

# qmlls_aside <root> <dir> [owner]: 0 when the root had a .qmlls.ini and has none now. The FIRST one is kept in
# <dir>/qmlls.ini.saved, with the record written BEFORE the move (a stop between the two leaves a record whose link is
# still in the root, which is harmless; the other order would leave a link nobody knows of); a later quickshell link is
# deleted (the first stands for it), anything else is kept aside under its own name. <owner> is `preview:<pid>`.
qmlls_aside() {
    local f=$1/.qmlls.ini saved=$2/qmlls.ini.saved other owner=${3:-preview}
    qmlls_present "$1" || return 1
    mkdir -p -- "$2" || return 1
    if [ ! -L "$saved" ] && [ ! -e "$saved" ]; then
        printf 'root=%s\nowner=%s\n' "$1" "$owner" | atomic_write "$2/record" || return 1
        mv -T -- "$f" "$saved" || return 1
        log ".qmlls.ini moved aside to $saved (-> $(readlink "$saved" 2> /dev/null || echo 'a regular file'))"
    elif qmlls_is_vfs_link "$f"; then
        rm -f -- "$f" || return 1
        log ".qmlls.ini made again (a quickshell link): removed, the first one stays saved"
    else
        other=$saved.$(now_s)
        mv -T -- "$f" "$other" || return 1
        log ".qmlls.ini made again and not quickshell's link: moved aside to $other"
    fi
}

# qmlls_restore <root> <dir>: the first saved .qmlls.ini goes back as it was and its record goes; 0 when it is there
# again (or nothing was saved). A quickshell link that is in the way is deleted; any other file is left alone.
qmlls_restore() {
    local f=$1/.qmlls.ini saved=$2/qmlls.ini.saved
    [ -L "$saved" ] || [ -e "$saved" ] || return 0
    if qmlls_present "$1"; then
        qmlls_is_vfs_link "$f" || return 1
        rm -f -- "$f" || return 1
    fi
    mv -T -- "$saved" "$f" || return 1
    qmlls_forget "$2"
}

# qmlls_head_target <root>: prints the target of the symlink the repo tracks as .qmlls.ini; 1 (nothing printed) when
# HEAD tracks none.
qmlls_head_target() {
    local mode target
    mode=$(git -C "$1" ls-tree HEAD -- .qmlls.ini 2> /dev/null | awk '{print $1}')
    [ "$mode" = 120000 ] || return 1
    target=$(git -C "$1" show HEAD:.qmlls.ini 2> /dev/null) && [ -n "$target" ] || return 1
    printf '%s' "$target"
}

# qmlls_from_head <root>: the root's .qmlls.ini linked again from that blob -- the fallback when no record says where
# the link pointed, the same as `ln -sfn "$(git show HEAD:.qmlls.ini)" .qmlls.ini`. 0 when it is there (prints the
# target); 1 when HEAD tracks no symlink of that name.
qmlls_from_head() {
    local target
    target=$(qmlls_head_target "$1") || return 1
    ln -sfn -- "$target" "$1/.qmlls.ini" || return 1
    printf '%s' "$target"
}

# hypr_notice <icon> <text> [ms]: Hyprland's own notification (`hyprctl notify`; icon 0 warning, 3 error), shown for ms (15000)
# by the compositor with no notification daemon at all -- the shell IS the daemon, so a notice about the shell cannot go through
# it. Nothing outside a Hyprland session ($HYPRCTL, else hyprctl).
hypr_notice() {
    [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || return 0
    timeout 5 "${HYPRCTL:-hyprctl}" notify "$1" "${3:-15000}" 0 "$2" > /dev/null 2>&1 8>&- 9>&-
    log "hyprctl notify: $2"
}

# stop_quickshell <pid> [seconds]: the polite way first -- `quickshell kill --pid` (the shell quits
# itself, status 0) --, SIGTERM (143) when it is still there 3 s later, KILL when that is ignored too.
# $QUICKSHELL is the program. 0 when the process is gone afterwards.
stop_quickshell() {
    local pid=$1 limit=${2:-${STOP_TIMEOUT:-5}}
    pid_alive "$pid" || return 0
    timeout 5 "$QUICKSHELL" kill --pid "$pid" > /dev/null 2>&1 8>&- 9>&-
    wait_until 3 pid_gone "$pid" && return 0
    log "pid $pid is still there 3 s after quickshell kill: TERM"
    kill -TERM "$pid" 2> /dev/null
    wait_until "$limit" pid_gone "$pid" && return 0
    log "pid $pid ignored TERM for ${limit}s: KILL"
    kill -KILL "$pid" 2> /dev/null
    wait_until 3 pid_gone "$pid"
}
