#!/bin/sh
# Attach a terminal to a running system update, when the popup cannot.
#
#   helpers/update-attach.sh                 watch, and type answers
#   helpers/update-attach.sh --status        is anything running, and where
#   helpers/update-attach.sh --answer y      send one line and leave
#   helpers/update-attach.sh --abort         send Ctrl-C and leave
#   helpers/update-attach.sh --dir <rundir>  a specific run instead of the last
#
# The run is owned by helpers/update-run.sh, not by any shell, so there is
# nothing to "reconnect" -- the two ends are just files:
#
#   transcript.log   everything it has printed          (read it)
#   stdin.fifo       everything it is waiting to read    (write it)
#
# which is why this needs no reptyr, no ptrace, and no tmux. The general
# problem -- moving an ALREADY-RUNNING tty process onto a new terminal -- is
# genuinely hard (see the notes at the bottom); this side-steps it by never
# tying the run to a terminal in the first place.
#
# In watch mode your terminal's input is forwarded line by line, so a [Y/n]
# question is answered by typing y and pressing enter. Ctrl-C is caught and
# forwarded AS the update's Ctrl-C rather than killing this viewer -- and Ctrl-D
# (or `q`) leaves without touching the run.
set -u

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/lares/system-update"
MARKER="$STATE_DIR/last-run.json"
MODE=watch
RUNDIR=""
TEXT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --status) MODE=status ;;
        --abort)  MODE=abort ;;
        --answer) MODE=answer; TEXT="${2:-}"; shift ;;
        --dir)    RUNDIR="${2:-}"; shift ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

jq_field() {  # file key -- no jq dependency, these files are ours and flat
    python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))
except Exception: pass' "$1" "$2" 2>/dev/null
}

if [ -z "$RUNDIR" ]; then
    [ -f "$MARKER" ] || { echo "no update has ever run on this machine"; exit 1; }
    RUNDIR="$(jq_field "$MARKER" runDir)"
    STATE="$(jq_field "$MARKER" state)"
    PID="$(jq_field "$MARKER" pid)"
else
    STATE=running
    PID="$(jq_field "$RUNDIR/run.json" pid)"
fi
[ -n "$RUNDIR" ] && [ -d "$RUNDIR" ] || { echo "no run directory: $RUNDIR"; exit 1; }

# The supervisor's pid is the one fact that cannot go stale: a marker still
# saying "running" with a dead pid means the machine went down mid-run.
LIVE=no
[ -n "$PID" ] && kill -0 "$PID" 2>/dev/null && LIVE=yes

# The supervisor's pid is not quite the whole story: it runs the command in the
# FOREGROUND (backgrounding it would make the child inherit SIGINT as SIG_IGN
# and break the abort byte), so killing the supervisor alone orphans a
# systemd-inhibit + script that keep going. Measured. Rather than call that
# "interrupted" and be wrong, look at whether the transcript is still moving.
STILL_WRITING=no
if [ "$LIVE" = no ] && [ ! -f "$RUNDIR/exit" ] && [ -f "$RUNDIR/transcript.log" ]; then
    _a=$(wc -c < "$RUNDIR/transcript.log" 2>/dev/null || echo 0)
    sleep 1.2
    _b=$(wc -c < "$RUNDIR/transcript.log" 2>/dev/null || echo 0)
    [ "$_b" -gt "$_a" ] && STILL_WRITING=yes
fi

if [ "$MODE" = status ] || [ "$LIVE" = no ]; then
    echo "run:    $RUNDIR"
    echo "state:  $STATE (supervisor pid $PID, ${LIVE} alive)"
    [ -f "$RUNDIR/exit" ] && echo "exit:   $(cat "$RUNDIR/exit")"
    if [ "$LIVE" = no ] && [ "$STATE" = running ]; then
        echo
        if [ "$STILL_WRITING" = yes ]; then
            echo "  !  the supervisor is gone but THE COMMAND IS STILL RUNNING"
            echo "     (the transcript is still growing). Let it finish. The"
            echo "     fifo still works, so answers and Ctrl-C still reach it;"
            echo "     only the exit code will not be recorded."
        else
            echo "  !! it says running, its process is gone and nothing is being"
            echo "     written: this run was INTERRUPTED (killed, or the machine"
            echo "     went down). If it got past 'Running pre-transaction"
            echo "     hooks' the initramfs may be missing -- check /boot"
            echo "     BEFORE rebooting:  ls -l /boot/initramfs-*.img"
        fi
    fi
    echo "last output:"
    tail -5 "$RUNDIR/transcript.log" 2>/dev/null | sed 's/^/  /'
    [ "$MODE" = status ] && exit 0
    exit 1
fi

FIFO="$RUNDIR/stdin.fifo"
[ -p "$FIFO" ] || { echo "no fifo at $FIFO"; exit 1; }

case "$MODE" in
    answer) printf '%s\n' "$TEXT" > "$FIFO"; echo "sent: $TEXT"; exit 0 ;;
    abort)  printf '\003'        > "$FIFO"; echo "sent Ctrl-C"; exit 0 ;;
esac

echo "attached to $RUNDIR"
echo "type an answer and press enter; Ctrl-C interrupts THE UPDATE; Ctrl-D or q leaves."
echo "---"
tail -n 40 -f "$RUNDIR/transcript.log" &
TAILPID=$!
# Ctrl-C here is the update's Ctrl-C, not this viewer's -- leaving is Ctrl-D.
trap 'printf "\003" > "$FIFO"' INT
trap 'kill $TAILPID 2>/dev/null; exit 0' TERM

while IFS= read -r line; do
    [ "$line" = "q" ] && break
    printf '%s\n' "$line" > "$FIFO"
done

kill "$TAILPID" 2>/dev/null
echo "--- detached (the update is still running)"

# ---------------------------------------------------------------------------
# THE GENERAL PROBLEM, for the record.
#
# Moving an already-running tty process onto a different terminal:
#
#   reptyr <pid>      the tool for it (extra/reptyr). It ptraces the target and
#                     swaps its controlling terminal for yours. With
#                     kernel.yama.ptrace_scope=1 (this machine) it can only
#                     touch its own descendants, so an unrelated process needs
#                     `sudo reptyr` or scope=0. Use `reptyr -T <pid>` to steal a
#                     whole session -- for script->yay->sudo->pacman you want
#                     the session, not the leaf.
#
#   TIOCSTI           the "echo into /dev/pts/N" trick. DEAD on this kernel:
#                     dev.tty.legacy_tiocsti=0. And writing to the pty SLAVE was
#                     never right anyway -- that writes to the terminal's output
#                     side, not the process's stdin.
#
#   tmux / screen     the clean answer, but only if you decided BEFORE starting:
#                     `tmux new -d -s upd 'yay -Syu'` then `tmux attach -t upd`.
#                     Neither is installed here. What update-run.sh does is the
#                     useful half of this without the dependency.
# ---------------------------------------------------------------------------
