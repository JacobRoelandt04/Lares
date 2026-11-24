#!/usr/bin/env bash
# Run a command against a PRIVATE COPY of this config, so nothing here is
# touched while it runs.
#
#   tools/dev/sandbox.sh tools/dev/shell_hosted_m1_probe.sh
#   tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen quickshell -p mockups/audio_player.qml
#   SANDBOX=/tmp/mine tools/dev/sandbox.sh tools/dev/smoke.sh --all
#
# WHY THIS EXISTS. Every quickshell instance rewrites `.qmlls.ini` in the
# directory it is started from, and a quickshell that is already running there
# sees that write and RELOADS ITS CONFIG. So starting a probe next to somebody
# else's running shell restarts theirs -- mid update run, mid capture, mid
# whatever they were doing. Editing any file under the config does the same.
#
# The sandbox is an rsync of the whole config minus `.git`, the screenshots and
# the helpers, into a scratch directory that nobody watches. Probe runners `cd`
# to their own `dirname/..`, so they land inside the copy and stay there; grabs,
# logs and the `.qmlls.ini` the run creates are all written in there too.
#
# The copy is refreshed on every call (rsync only moves what changed, so it is
# a few hundred milliseconds), which means: EDIT IN THE REAL CONFIG, TEST HERE.
#
# QUICKSHELL'S RUNTIME DIRS. Every quickshell also keeps a directory per
# instance under $XDG_RUNTIME_DIR/quickshell/by-id (its logs and IPC socket)
# and never removes it; /run/user/<uid> is a small tmpfs, and on 2026-09-25
# four days of test runs had filled it (25,314 dirs) until every quickshell
# logged "No space left on device". So this script (tools/dev/lares_runtime.py):
#   - gives a command whose environment says QT_QPA_PLATFORM=offscreen a
#     PRIVATE runtime dir (0700, beside the sandbox in <sandbox>.lrrt/, or in
#     /tmp when that path is too long for a socket), with every other entry of
#     the real one linked in (the bus, systemd, pipewire, mpd, hyprland), and
#     removes it when the command ends;
#   - removes, on every call and again when the command ends and when its
#     caller ends, the instance dirs in the real runtime dir whose config lies
#     under this sandbox (or under $SCRATCH when that is the sandbox's parent,
#     however shallow: SCRATCH=/tmp/lares-ns counts, /tmp itself does not)
#     and whose process is gone. A live instance is never touched, nor anything
#     outside quickshell/by-id and the by-pid / by-shell links that name the
#     instance, nor any instance of ~/.config/quickshell or the git tree.
# THE SESSION'S AUDIO IS NOT LINKED. The private runtime dir links every entry of the real one
# EXCEPT quickshell's instance tree and the session's audio -- PipeWire's sockets and its
# PulseAudio shim (pipewire-*, pulse/) and mpd's (mpd/). A linked socket is not a read-only
# window: a spike's `pw-metadata` set the user's real default.audio.source to a missing node
# for 1.5 minutes (2026-10-21). So in a sandbox `pw-cli`, a Pipewire reader and mpd find
# nothing, by default. A test that only READS the session's audio opts in, with the word
# `SANDBOX_LINK=pipewire,mpd` among the command's leading NAME=VALUE words (or in this
# script's environment); a test that WRITES audio state makes its own private daemon in a
# runtime dir of its own and points PIPEWIRE_REMOTE at it by absolute path.
# (A command that is not
# offscreen keeps the session's own runtime dir, as before.)
#
# The command is still exec'd -- its pid is this script's, as before, so a
# runner's `kill $!` reaches it; the waiting is done by a detached watcher
# (setsid, no fd of the caller's kept) that ends when the command and the
# caller have. A caller that syncs and then starts quickshells itself
# (`tools/dev/sandbox.sh true`, or no command) is covered by that second wait; a
# long-lived caller (an interactive shell) keeps one idle watcher per sandbox
# until it exits.
#
# MOCKUP_REPO. A mockup run from the copy saves into the tree the copy is made
# of: Save to mockup and the control panel's profiles write the real config,
# not a copy the next sync puts back (docs/contracts/mockup_framework.md). So the copy's command gets MOCKUP_REPO=<this config> unless the
# caller set it: its own value wins (a probe's scratch repo), and an EMPTY one
# keeps every write in the copy. By itself such a run writes nothing there but
# the derived default.json profile, and that only while the copy's mockup file
# is the repo's byte for byte (MockupWindow._mayWriteDefault).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export MOCKUP_REPO="${MOCKUP_REPO-$ROOT}"
# THE CRASH HANDLER IS OFF in a sandboxed run unless the caller set the variable.
# With it on, a quickshell that crashes more than 10 s after its start restarts
# IN PLACE as a crash reporter under the same pid (measured),
# which outlives the runner that started it: on 2026-10-14 fourteen of them sat
# idle under init (~60 MB each), left by a probe that aborts in its teardown.
# Off, the crash ends the process with 134/139 and the runner sees the status.
export QS_DISABLE_CRASH_HANDLER="${QS_DISABLE_CRASH_HANDLER-1}"
# THE ICON THEME of a sandboxed quickshell is Papirus unless the caller says otherwise: the shell takes it from QS_ICON_THEME at start
# (tools/shell/lares-supervise exports what GTK reports), and a bare quickshell has no theme, so every icon would be the fallback.
export QS_ICON_THEME="${QS_ICON_THEME-Papirus}"
SANDBOX="${SANDBOX:-${SCRATCH:-/tmp}/lares-sandbox}"
LARES_RT="$ROOT/tools/dev/lares_runtime.py"

mkdir -p "$SANDBOX"
# Not `.claude/`: it holds every stream's git worktree (git ignores them, rsync does not), and a copy that carried them
# was 1.3 GB and minutes of rsync (2026-10-22).
rsync -a --delete \
      --exclude '.git' \
      --exclude '.qmlls.ini' \
      --exclude 'screenshots/' \
      --exclude 'helpers/' \
      --exclude '.claude/' \
      "$ROOT/" "$SANDBOX/" || exit 1

cd "$SANDBOX" || exit 1
[ -f "$LARES_RT" ] && command -v python3 > /dev/null && command -v setsid > /dev/null || LARES_RT=""

# What the command's environment will say: env's own reading of the leading
# words (NAME=VALUE, -u NAME, -i, a nested `env`), in order.
qpa="${QT_QPA_PLATFORM:-}" rt_cmd="" rt_named="" link="${SANDBOX_LINK:-}"
i=1
while [ "$i" -le "$#" ]; do
    w="${!i}"
    case "$w" in
        env|--) ;;
        -i|--ignore-environment) qpa="" ;;
        -u|--unset) i=$((i + 1)); w="${!i:-}"
                    [ "$w" = QT_QPA_PLATFORM ] && qpa=""; [ "$w" = XDG_RUNTIME_DIR ] && rt_named=1 ;;
        -u*|--unset=*) w="${w#-u}"; w="${w#--unset=}"
                    [ "$w" = QT_QPA_PLATFORM ] && qpa=""; [ "$w" = XDG_RUNTIME_DIR ] && rt_named=1 ;;
        -C|--chdir|-S|--split-string) i=$((i + 1)) ;;
        -*) ;;
        QT_QPA_PLATFORM=*) qpa="${w#*=}" ;;
        XDG_RUNTIME_DIR=*) rt_named=1 rt_cmd="${w#*=}" ;;
        SANDBOX_LINK=*) link="${w#*=}" ;;
        *=*) ;;
        *) break ;;
    esac
    i=$((i + 1))
done

private=""
if [ -n "$LARES_RT" ]; then
    SB="$(pwd -P)"
    RT="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    where=(--rt "$RT" --sandbox "$SB" --scratch "${SCRATCH:-}" --root "$ROOT")
    [ -n "$rt_cmd" ] && [ "$rt_cmd" != "$RT" ] && where+=(--rt "$rt_cmd")
    python3 "$LARES_RT" sweep "${where[@]}" 2> /dev/null
    spawn() {  # the watcher, detached, holding none of the caller's fds
        [ -n "${SANDBOX_REAP_LOG:-}" ] && printf '%s spawn\n' "$(date +%s.%N)" >> "$SANDBOX_REAP_LOG"
        setsid -f python3 "$LARES_RT" watch "$@" < /dev/null > /dev/null 2>&1
    }
    if [ "$#" -eq 0 ]; then
        spawn --caller "$PPID" "${where[@]}"
    else
        if [ "${qpa%%:*}" = offscreen ] && [ -z "$rt_named" ] && [ ! -f "$RT/.lares-sandbox-rt" ]; then
            # An offscreen run needs no display of its own; its quickshells
            # keep their instance dirs in a runtime dir of their own. (A
            # runtime dir that already is one -- a sandbox call from inside a
            # sandboxed run -- is used as it is.)
            private=$(python3 "$LARES_RT" mkrt --sandbox "$SB" --parent "$RT" --owner "$$" --link "$link" 2> /dev/null) || private=""
            [ -n "$private" ] && export XDG_RUNTIME_DIR="$private"
        fi
        spawn --cmd "$$" --caller "$PPID" --private "$private" "${where[@]}"
    fi
fi
[ "$#" -eq 0 ] && { echo "sandbox ready at $SANDBOX"; exit 0; }
exec env "$@"
