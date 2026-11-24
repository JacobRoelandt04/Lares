#!/bin/sh
# The detached owner of a system-update run.
#
#   helpers/update-run.sh [--kind <kind>] <run-dir> <command...>
#
# <kind> is what the run is, recorded in run.json and the marker: "update" (the default) or "undo" (pacman -U of
# the packages a snapshot's undo plan names). Only an update counts as the last successful update.
#
# WHY THIS EXISTS. `yay -Syu` as a child of the shell would die with it:
# Quickshell's `Process` destructor calls kill() -- SIGKILL -- while `Process`
# is a PostReloadHook rather than Reloadable, so a CONFIG RELOAD destroys it
# too. Saving any .qml file during an update would kill the update
# mid-transaction. An interrupted transaction can leave the machine unbootable:
# /usr/share/libalpm/hooks/60-mkinitcpio-remove.hook runs PreTransaction and
# DELETES the initramfs, and 90-mkinitcpio-install.hook only rebuilds it after
# every package is written. The window between them is "new kernel on disk, no
# initramfs".
#
# So the shell does not own the run. This script does, and the shell is only
# ever a viewer attached to the files below.
#
# WHAT IT SETS UP, in the run dir:
#   transcript.log  the PTY typescript, written by script(1) with -f (flushed
#                   per write), which the shell tails to see the run live
#   timing.log      script(1)'s per-write timings. The typescript itself
#                   carries no clock, and ui-state.jsonl stops the moment the
#                   shell dies -- so without this the majority of a detached
#                   run cannot be timed after the fact at all, which is most
#                   of what reading the log after a run is for.
#   stdin.fifo      prompt answers and the abort byte, written by the shell
#   run.json        { runId, pid, command, startedAt } -- pid is THIS script
#   exit            the command's exit code, written when it ends
#
# THE FIFO IS HELD OPEN READ-WRITE (`exec 0<>`). A fifo opened read-only gives
# the child EOF the moment the last writer closes, which would end every prompt
# yay ever asks. Held open here, it never EOFs and any number of writers can
# come and go -- which is what lets the shell die and a new one take over.
#
# ABORTING is a 0x03 byte into that fifo: script(1) passes it to the pty, whose
# line discipline turns it into a kernel-delivered SIGINT to the foreground
# process group. That is the ONLY signal path that reaches pacman, because
# pacman runs as root under sudo and a user-owned shell cannot signal it.
# Verified, with a plain byte as the negative control.
#
# SUDO ASKS THROUGH THE SHELL, NOT THE TERMINAL. yay calls sudo for pacman and
# for AUR installs, and a prompt on this PTY would need the popup's own field to
# type the password into stdin.fifo. Instead yay's sudo is helpers/sudo-askpass
# (`yay --sudo`, which adds -A to EVERY call, --sudoloop's bare `sudo -v`
# included -- --sudoflags does not reach that one), and sudo asks its
# SUDO_ASKPASS helper, which connects to the socket the popup's AskpassServer
# serves and the authentication toast answers (face, password or cancel). No
# secret ever crosses this fifo: the fifo's bytes land in whatever reads the
# PTY next, and a face can win the same instant the user types.
#
# The socket path is STABLE ($XDG_RUNTIME_DIR/lares-askpass-update.sock,
# the same for every run) because this run outlives any one shell: a reload
# or a crash happens in the middle of a sudo and the next shell serves the same
# path. So the helper RETRIES (LARES_ASKPASS_RETRY=1: a missing socket, or a server
# that died without a word, is tried again every 250 ms) up to
# LARES_ASKPASS_TIMEOUT, 300 s -- sudo's own passwd_timeout, which is how long a
# terminal prompt waits. The popup's server takes answerWindowMs to match.
# pkexec (the helper driver) goes through polkit and is not touched.
# THE WHOLE SCRIPT IS ONE BRACE GROUP, closed on the last line. bash reads a
# script from disk AS IT RUNS, so a file rewritten in place under a live run
# is read at the old offset in the new bytes: an edit made while a run waited
# at sudo killed that run the moment yay ended ("unexpected EOF while looking
# for matching `"'"), before it wrote `exit` or the finished marker -- the
# marker said "running" for a pid that was gone. bash parses a brace group
# whole before running any of it, so an edit reaches only the next run.
{
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
export SUDO_ASKPASS="${LARES_ASKPASS_HELPER:-$SELF_DIR/../llm_tools/askpass.py}"
export LARES_ASKPASS_SOCKET="${LARES_ASKPASS_SOCKET:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/lares-askpass-update.sock}"
export LARES_ASKPASS_RETRY=1
export LARES_ASKPASS_TIMEOUT="${LARES_ASKPASS_TIMEOUT:-300}"

# THE INHIBITOR wraps the command rather than being taken by the shell, so it
# is held for exactly as long as the run lasts -- released on success, on
# failure, and on abort -- and correctly stays held if the shell dies. It holds
# SLEEP (and shutdown and the lid), not idle: an update is work the user waits
# on, which may dim but must never suspend -- the shell's idle auto layer puts
# soft idle in force for the run (IdleAuto: the screen dims, the Wayland
# inhibitor keeps hypridle's listeners quiet). If the shell is gone, hypridle's
# 240 s `systemctl suspend` is refused by this block all the same.
set -u

KIND=update
if [ "${1:-}" = "--kind" ]; then
    KIND="${2:-}"
    case "$KIND" in update|undo) ;; *) echo "update-run.sh: unknown kind: $KIND" >&2; exit 2 ;; esac
    shift 2
fi

RUNDIR="${1:?usage: update-run.sh [--kind <kind>] <run-dir> <command...>}"
shift
CMD="$*"
[ -n "$CMD" ] || { echo "update-run.sh: no command given" >&2; exit 2; }

# yay's sudo must ask through SUDO_ASKPASS (see above). The run records the
# command as it really ran.
case "$CMD" in
    yay|"yay "*) CMD="yay --sudo '$SELF_DIR/sudo-askpass'${CMD#yay}" ;;
esac

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/lares/system-update"
MARKER="$STATE_DIR/last-run.json"
RUNID="$(basename "$RUNDIR")"

mkdir -p "$RUNDIR" "$STATE_DIR" || exit 2
# execDetached gives this script stderr on /dev/null, so without this a failed
# mkfifo or a missing systemd-inhibit is a silent death and the shell just
# spins its attach poll until it gives up.
exec 2>>"$RUNDIR/supervisor.log"
FIFO="$RUNDIR/stdin.fifo"
[ -p "$FIFO" ] || mkfifo "$FIFO" || exit 2

now() { date +%s%3N; }
STARTED="$(now)"

json_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

cat > "$RUNDIR/run.json" <<EOF
{ "runId": "$(json_esc "$RUNID")",
  "pid": $$,
  "command": "$(json_esc "$CMD")",
  "kind": "$KIND",
  "startedAt": $STARTED }
EOF

# The DURABLE marker, outside the runtime dir, because $XDG_RUNTIME_DIR is
# cleared by a reboot -- and a reboot in the middle of a transaction is exactly
# the case that has to be detectable next launch.
write_marker() {
    # The pid is in HERE, not only in run.json, because the shell reads this
    # one file and nothing else: a QML FileView loads synchronously on its
    # FIRST path assignment but NOT on later ones, so a shell that has to
    # open a second, run-specific path to learn the pid reads stale bytes.
    # One static path it can reload() forever is the only reliable shape.
    cat > "$MARKER" <<EOF
{ "runId": "$(json_esc "$RUNID")",
  "runDir": "$(json_esc "$RUNDIR")",
  "command": "$(json_esc "$CMD")",
  "pid": $$,
  "kind": "$KIND",
  "startedAt": $STARTED,
  "state": "$1"$2 }
EOF
}
write_marker running ""

# PRUNING: the newest KEEP_RUNS runs (30; LARES_UPDATE_KEEP_RUNS) stay, by run time, and the older ones go as a NEW run starts.
# The run dir is the RECORDER'S dir: it holds ui-state.jsonl and the raw transcript, the ground truth CLAUDE.md says to read
# after every real run, so the limit is generous (50 runs were 60 MB) and the prune is blind to nothing it must keep:
#   - only directories named like a run id (YYYY-MM-DD_HH-MM-SS) inside a directory called `runs` are ever looked at, a
#     symlink never is, and the run dir this script was given is never removed;
#   - a run that is still alive (no `exit` file and a live pid in its run.json) is never removed, however old.
# The run id is a timestamp, so sorting the names IS sorting by run time. Done before the command starts: nothing reads the
# old runs meanwhile, and a prune that fails changes nothing about the run.
prune_runs() {
    local parent keep n=0 d name pid
    parent="$(dirname "$RUNDIR")"
    keep="${LARES_UPDATE_KEEP_RUNS:-30}"
    case "$keep" in ''|*[!0-9]*) keep=30 ;; esac
    [ "$(basename "$parent")" = runs ] || return 0
    for d in $(ls -1 "$parent" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$' | sort -r); do
        d="$parent/$d"
        [ -d "$d" ] && [ ! -L "$d" ] || continue
        n=$((n + 1))
        [ "$n" -gt "$keep" ] || continue
        [ "$d" != "$RUNDIR" ] || continue
        if [ ! -e "$d/exit" ] && [ -r "$d/run.json" ]; then
            pid="$(sed -n 's/^ *"pid": *\([0-9][0-9]*\).*/\1/p' "$d/run.json" | head -1)"
            [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null || continue
        fi
        rm -rf -- "$d"
    done
    return 0
}
prune_runs

# Hold the fifo open so the child's stdin never sees EOF, then run the command
# on a PTY whose typescript is the transcript the shell reads.
exec 0<>"$FIFO"

# SIZE THE PTY FROM THE INSIDE. script(1) has no flag for it and the slave's
# stty is what the child reads. At the default 80 columns pacman truncates
# download filenames and prints the COMPACT transaction table with no
# per-package sizes -- and the download tracker matches by filename while
# category progress is weighted by size, so neither is recoverable afterwards.
# Attach mode does not start script from the shell, so the size is set here.
#
# 200, not 120: a 43-character package cell needs ~125 columns, and below that
# pacman prints "warning: insufficient columns available for table display" and
# falls back to the compact list -- costing every official package its size for
# the whole download, and truncating download filenames besides. pacman only
# ever uses the width it needs, so the headroom is free.
SIZED="stty cols ${PTY_COLS:-200} rows ${PTY_ROWS:-50} 2>/dev/null; $CMD"

# systemd-inhibit is NOT optional, and not only for the inhibitor: a command
# backgrounded from a non-interactive shell inherits SIGINT as SIG_IGN, and
# that survives exec -- script(1) does NOT reset it, systemd-inhibit DOES.
# Drop it from the chain and the abort byte silently stops working in exactly
# the launch shapes that poison SIGINT. Measured.
systemd-inhibit \
    --what=sleep:shutdown:handle-lid-switch \
    --who="lares system update" \
    --why="$CMD" \
    --mode=block \
    script -qefc "$SIZED" --log-timing "$RUNDIR/timing.log" "$RUNDIR/transcript.log"
CODE=$?

printf '%s\n' "$CODE" > "$RUNDIR/exit"
write_marker finished ", \"exit\": $CODE, \"endedAt\": $(now)"
exit "$CODE"
}
