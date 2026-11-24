#!/usr/bin/env bash
# lares (tools/shell/) against a FAKE WORLD, the commands that need no deployed shell -- never the desktop.
# (deploy / start / restart / binds / setup / cleanup-marks run in tools/dev/lares_deploy_probe.sh's world: a fake home.)
#
#   tools/dev/lares_tool_probe.sh                  ends in LARES_TOOL RESULT PASS|FAIL
#   ONLY="pacman preview" tools/dev/lares_tool_probe.sh   just those scenarios (a development aid)
#   ARM=<name> tools/dev/lares_tool_probe.sh       a fault in a SANDBOX copy of tools/shell; must FAIL on its needle
#   ARM=all                                       every ARM; LARES_TOOL ARMS PASS when each failed as it must
#     nopmguard     the restart guard lets everything through         -> "preview is refused while db.lck exists"
#     nopmargs      any pacman / yay process is a transaction         -> "checkupdates (pacman -Sy --dbpath <a copy>) is none"
#     norecover     no command gives a stranded .qmlls.ini back       -> "the next command puts the .qmlls.ini back"
#     nopreviewlive a running preview's link is not left alone        -> "leaves a running preview's .qmlls.ini alone"
#     nolayerrow    the auth pill's layer rule is left out of the table -> "the namespaces the code opens"
#     noglobal      a global of the modules is missing from the tables  -> "every GlobalShortcut the modules declare"
#
# THE WORLD. A temp dir holds a HOME, an XDG_RUNTIME_DIR, a git repo (the fixture "repo" the tool is pointed at), a private
# session bus (tools/dev/notifications_bus.sh: no activatable service) and the stubs of tools/dev/fixtures/lares/bin first on
# PATH: hyprctl, systemctl, quickshell (owns org.freedesktop.Notifications, prints the ready line, answers list and ipc), and
# pmstub / yaystub / waybar as sleeping processes whose comm is their name. Everything runs under `env -i`: the desktop's
# WAYLAND_DISPLAY, Hyprland signature and runtime dir never reach a process here.
#
# THE SCENARIOS:
#   guard      stubs first on PATH; the bus, HOME, runtime dir and signature are the world's
#   pacman     the restart guard: db.lck, or a pacman / yay process whose command line is a transaction (-Syu, -S, -U, -R; not
#              checkupdates' `-Sy --dbpath`, not -Ss / -Si / -Qua), refuses preview (exit 4, the reason, --force); a dry run
#              says WOULD REFUSE; a refusal with no terminal is said through `hyprctl notify`
#   preview    the whole `preview` command against a stand-in for tools/dev/lock_env.sh (no window anywhere): the .qmlls.ini is
#              set aside for its life and back after, the session goes down on TERM, a second one is refused
#   stranded   a preview that died without giving its .qmlls.ini back (a reboot): the next command puts it back, from the
#              record or, with the saved link gone, from HEAD; a dry run only says; a running preview's is left alone
#   apply      apply --commit with nothing deployed: exactly the named files, a staged stranger stays staged, "committed
#              only"; no-change and refusals
#   tables     the keys against modules/osd/OsdShortcuts.qml's header, the layer rules against the namespaces the modules open,
#              the globals against every GlobalShortcut name the modules declare
#   update     update-running: the pid of a run its marker says runs and whose pid lives; nothing otherwise
#   misc       help, usage errors, the commands that are gone, oled with nothing deployed, shellcheck
#
# A run that printed no LARES_TOOL RESULT (the inner half died) ends on
# `LARES_TOOL RESULT FAIL (no result: <log>)` (tools/dev/result_lib.sh).
# shellcheck disable=SC2016   # the bodies of the `bash -c '...'` checks are literal scripts that read their own positional parameters
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
FIX=$ROOT/tools/dev/fixtures/lares
NAME=LARES_TOOL
# shellcheck source=tools/dev/result_lib.sh
. tools/dev/result_lib.sh

# =====================================================================================================
# THE OUTER HALF: build the world's directory, run the inner half in it under `env -i`, judge the log
# =====================================================================================================
outer() {
    local W LOG rc arm=${1:-}
    W=$(mktemp -d /tmp/lrshp.XXXXXX) || exit 1
    chmod 700 "$W"
    LOG=$W/probe.log
    # shellcheck disable=SC2064
    trap "reap_world '$W'" EXIT
    env -i HOME="$W/home" PATH="$FIX/bin:/usr/local/bin:/usr/bin:/bin" LANG=C.UTF-8 USER="${USER:-probe}" TERM=dumb \
        XDG_RUNTIME_DIR="$W/rt" XDG_CONFIG_HOME="$W/home/.config" XDG_STATE_HOME="$W/home/.local/state" \
        XDG_CACHE_HOME="$W/home/.cache" XDG_DATA_HOME="$W/home/.local/share" \
        WAYLAND_DISPLAY=wayland-fake HYPRLAND_INSTANCE_SIGNATURE=fakesig LARES_FAKE="$W/fake" \
        LARES_PROBE_INNER=1 W="$W" ARM="$arm" ONLY="${ONLY:-}" KEEP="${KEEP:-}" \
        "$ROOT/tools/dev/notifications_bus.sh" bash "$ROOT/tools/dev/lares_tool_probe.sh" > "$LOG" 2>&1
    rc=$?
    grep -a -v "^$NAME RESULT" "$LOG"
    echo "(inner half exited $rc)"
    if [ -n "$arm" ]; then
        judge_arm "$arm" "$LOG"
        return $?
    fi
    rl_result "$NAME" "$LOG"
}

# reap_world <dir>: end every process that carries this world's marker in its environment (found through
# /proc/<pid>/environ, never by name), then remove the dir. KEEP=1 keeps the dir for a look.
reap_world() {
    local w=$1 p pids left
    for _ in 1 2 3; do
        pids=""
        for p in /proc/[0-9]*; do
            [ -O "$p" ] || continue
            { tr '\0' '\n' < "$p/environ"; } 2> /dev/null | grep -qx "LARES_FAKE=$w/fake" && pids="$pids ${p#/proc/}"
        done
        [ -z "$pids" ] && break
        # shellcheck disable=SC2086
        kill -TERM $pids 2> /dev/null
        sleep 0.4
        left=""
        for p in $pids; do [ -d "/proc/$p" ] && left="$left $p"; done
        # shellcheck disable=SC2086
        [ -n "$left" ] && kill -KILL $left 2> /dev/null
    done
    rm -rf /tmp/lrlk-f6pv
    if [ -n "${KEEP:-}" ]; then echo "(kept: $w)"; else rm -rf "$w"; fi
}

# ARM verdicts: the armed copy must fail, and the failure must be the one the ARM aims at.
arm_needle() {
    case $1 in
        nopmguard)     echo "preview is refused while db.lck exists" ;;
        nopmargs)      echo "checkupdates (pacman -Sy --dbpath <a copy>) is none" ;;
        norecover)     echo "the next command puts the .qmlls.ini back" ;;
        nopreviewlive) echo "leaves a running preview's .qmlls.ini alone" ;;
        nolayerrow)    echo "the namespaces the code opens" ;;
        noglobal)      echo "every GlobalShortcut the modules declare" ;;
    esac
}
arm_scenarios() {
    case $1 in
        nopmguard|nopmargs) echo "pacman" ;;
        norecover) echo "stranded" ;;
        nopreviewlive) echo "preview" ;;
        nolayerrow|noglobal) echo "tables" ;;
    esac
}
judge_arm() {
    local arm=$1 log=$2 needle
    needle=$(arm_needle "$arm")
    if rl_clean "$log" | grep -a -q "^$NAME RESULT FAIL (no result" || ! rl_clean "$log" | grep -a -q "^$NAME RESULT "; then
        echo "$NAME ARM $arm BAD (the armed copy printed no RESULT: it did not run to its end: $log)"; return 1
    fi
    if grep -aq "^ARM anchor FAIL" "$log"; then echo "$NAME ARM $arm BAD (its anchor is gone: $(grep -a '^ARM anchor FAIL' "$log" | head -1))"; return 1; fi
    if ! rl_clean "$log" | grep -a -q "^$NAME RESULT FAIL"; then echo "$NAME ARM $arm BAD (it PASSED: the fault is not caught)"; return 1; fi
    if ! rl_clean "$log" | grep -a "^  FAIL" | grep -aqF -- "$needle"; then
        echo "$NAME ARM $arm BAD (failed, but not on '$needle'):"; rl_clean "$log" | grep -a "^  FAIL" | head -5; return 1
    fi
    echo "$NAME ARM $arm FAILED AS IT MUST ('$needle')"
}

arm_patch() {   # arm_patch <tools/shell copy> <arm>: each step ok, or the run stops on a lost anchor
    python3 - "$1" "$2" << 'PY'
import sys
d, arm = sys.argv[1:3]
def patch(fname, old, new):
    p = d + "/" + fname
    s = open(p).read()
    n = s.count(old)
    if n != 1:
        print("ARM anchor FAIL (%d matches) in %s: %r" % (n, fname, old[:80]))
        sys.exit(3)
    open(p, "w").write(s.replace(old, new))
    print("ARM step ok: %s" % old[:60].replace("\n", "\\n"))
if arm == "nopmguard":
    patch("lares", "    why=$(pacman_busy) || return 0\n    if [ \"$2\" -eq 1 ]; then warn", "    return 0\n    if [ \"$2\" -eq 1 ]; then warn")
elif arm == "nopmargs":
    patch("lares", "        if pm_args_transact \"${argv[@]:i+1}\"; then", "        if true; then")
elif arm == "norecover":
    patch("lares", "    [ -e \"$QMLLS_DIR/record\" ] || [ -L \"$saved\" ] || [ -e \"$saved\" ] || return 0\n", "    return 0\n")
elif arm == "nopreviewlive":
    patch("lares", "        if pid_alive \"$pid\" && argv_runs_lares \"$pid\"; then return 0; fi\n", "")
elif arm == "nolayerrow":
    patch("lares", "lares_auth_pill_noanim    | ^auth-pill$\n", "")
elif arm == "noglobal":
    patch("lares", "EXTRA_GLOBALS='lock popup-escape'", "EXTRA_GLOBALS='popup-escape'")
else:
    print("no such ARM: " + arm); sys.exit(3)
PY
}

if [ "${LARES_PROBE_INNER:-}" != 1 ]; then
    case ${ARM:-} in
        all)
            bad=0
            for a in nopmguard nopmargs norecover nopreviewlive nolayerrow noglobal; do
                ARM=$a "$0" || bad=1
                echo
            done
            [ $bad -eq 0 ] && { echo "$NAME ARMS PASS"; exit 0; }
            echo "$NAME ARMS FAIL"; exit 1 ;;
        "") outer ""; exit $? ;;
        *) outer "$ARM"; exit $? ;;
    esac
fi

# =====================================================================================================
# THE INNER HALF: inside the private bus, under `env -i`, in the world
# =====================================================================================================
TOOLDIR=$ROOT/tools/shell
REPO=$W/repo
OUT=$W/out
LOGF=$LARES_FAKE/stub.log
PASSES=0 FAILS=0
FAILED=()
# shellcheck disable=SC2034   # read by the shared lib
SESSION_SIG=fakesig
# shellcheck source=tools/dev/fixtures/lares/probe_lib.sh
. "$FIX/probe_lib.sh"

export LARES_REPO=$REPO
# The restart guard reads the machine's pacman: the lock file and the processes. The world has a lock file of its own and looks
# for stand-ins named pmstub / yaystub, so a real transaction on the machine cannot refuse the probe's commands.
export LARES_PACMAN_LOCK=$W/fake/pacman/db.lck LARES_PM_COMMS="pmstub yaystub"
PERSIST=$HOME/.local/state/lares/tool
QMLLS_STORE=$PERSIST/qmlls   # where the tool keeps a .qmlls.ini a preview set aside: persistent, the runtime dir is a tmpfs
QMLLS_TARGET0=$XDG_RUNTIME_DIR/quickshell/vfs/fakeid/.qmlls.ini
RC=0
T() {   # T <args...>: run lares; its output is $OUT/last.out, its status $RC
    timeout 120 "$TOOLDIR/lares" "$@" > "$OUT/last.out" 2>&1 < /dev/null
    RC=$?
}
rc_is() { [ "$RC" -eq "$1" ]; }
repo() { git -C "$REPO" "$@"; }
qmlls_absent() { [ ! -L "$REPO/.qmlls.ini" ] && [ ! -e "$REPO/.qmlls.ini" ]; }
qmlls_not_aside() { [ ! -e "$QMLLS_STORE/record" ] && ! compgen -G "$QMLLS_STORE/qmlls.ini.saved*" > /dev/null; }
c_qmlls_back() { [ -L "$REPO/.qmlls.ini" ] && [ "$(readlink "$REPO/.qmlls.ini")" = "$QMLLS_TARGET0" ]; }

world_up() {
    mkdir -p "$LARES_FAKE"/{ctl,qs,pacman} "$OUT" "$HOME"
    if [ -d "$XDG_RUNTIME_DIR" ]; then chmod 700 "$XDG_RUNTIME_DIR"; else mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"; fi
    : > "$LOGF"
    make_repo
}

# =====================================================================================================
# THE SCENARIOS
# =====================================================================================================
guard_abort() { echo "  FAIL guard: $*"; echo "$NAME RESULT FAIL (guard aborted the run before anything was changed: $*)"; exit 2; }
sc_guard() {
    note "guard: nothing here may be the real desktop"
    local c
    for c in hyprctl systemctl quickshell waybar; do
        case $(command -v "$c") in "$FIX"/bin/*) ;; *) guard_abort "$c resolves to $(command -v "$c"), not a stub" ;; esac
    done
    case ${DBUS_SESSION_BUS_ADDRESS:-} in ""|*/run/user/*) guard_abort "the session bus is not the private one" ;; esac
    case $HOME in "$W"/*) ;; *) guard_abort "HOME is not the world's" ;; esac
    case $XDG_RUNTIME_DIR in "$W"/*) ;; *) guard_abort "XDG_RUNTIME_DIR is not the world's" ;; esac
    [ "$HYPRLAND_INSTANCE_SIGNATURE" = fakesig ] || guard_abort "the signature is not fakesig"
    ok "guard: the programs that act are stubs; the bus, HOME, runtime dir and signature are the world's"
}

# ---- the restart guard -------------------------------------------------------------------------------
pm_case() {   # pm_case <busy|free> <label> <stub> <args...>: a process with that command line; what `preview --dry-run` says of it
    local want=$1 label=$2 stub=$3 p
    shift 3
    spawn_fake "$stub" "$@"
    waitfor 5 bash -c '[ -n "$1" ]' _ "$(fake_pid "$stub")" > /dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do p=$(fake_pid "$stub"); [ -n "$p" ] && break; sleep 0.1; done
    T preview --dry-run
    if [ "$want" = busy ]; then
        check "pacman: $label is a transaction (preview --dry-run: WOULD REFUSE, exit 4)" bash -c '[ "$1" -eq 4 ] && grep -aq "WOULD REFUSE preview" "$2"' _ "$RC" "$OUT/last.out"
    else
        check "pacman: $label is none (preview --dry-run goes on, exit 0)" bash -c '[ "$1" -eq 0 ] && ! grep -aq "WOULD REFUSE" "$2"' _ "$RC" "$OUT/last.out"
    fi
    [ -n "$p" ] && kill "$p" 2> /dev/null
    waitfor 3 bash -c '[ -z "$1" ]' _ "$(fake_pid "$stub")" > /dev/null
}
sc_pacman() {
    note "pacman: the restart guard (a shell started mid-update would load a half-replaced Qt)"
    : > "$LARES_FAKE/pacman/db.lck"
    mark pm
    T preview
    check "pacman: preview is refused while db.lck exists (exit 4, the reason), before the nested session is made" bash -c '
        [ "$1" -eq 4 ] && grep -aq "preview refused: a package transaction runs" "$2" && grep -aq "db.lck exists" "$2"' _ "$RC" "$OUT/last.out"
    check "pacman: ... nothing of the preview was started" no_since pm "LOCKENV up"
    check "pacman: ... and, with no terminal to read it, the refusal is said through hyprctl notify" has_since pm "HYPRCTL notify 0 15000 0 lares preview refused"
    T preview --dry-run
    check "pacman: preview --dry-run says WOULD REFUSE (exit 4) and runs nothing" bash -c '[ "$1" -eq 4 ] && grep -aq "WOULD REFUSE preview" "$2"' _ "$RC" "$OUT/last.out"
    T preview --dry-run --force
    check "pacman: --force goes on (the dry run says so, exit 0)" bash -c '[ "$1" -eq 0 ] && grep -aq "force: it goes on" "$2"' _ "$RC" "$OUT/last.out"
    rm -f "$LARES_FAKE/pacman/db.lck"
    pm_case busy "pacman -Syu" pmstub -Syu
    pm_case busy "pacman -S foo" pmstub -S foo
    pm_case busy "pacman -U x.pkg.tar.zst" pmstub -U x.pkg.tar.zst
    pm_case busy "pacman -Rns foo" pmstub -Rns foo
    pm_case busy "yay (no argument = -Syu)" yaystub -Syu --noconfirm
    pm_case free "checkupdates (pacman -Sy --dbpath <a copy>)" pmstub -Sy --dbpath /tmp/checkup-db-x --logfile /dev/null
    pm_case free "pacman -Ss foo" pmstub -Ss foo
    pm_case free "pacman -Si foo" pmstub -Si foo
    pm_case free "yay -Qua" yaystub -Qua
}

# ---- preview, for real, against a stand-in for tools/dev/lock_env.sh ---------------------------------------------
preview_shell_up() { has_since pv "QUICKSHELL ready"; }
last_shell_started_without_qmlls() { grep -a "QUICKSHELL start" "$LOGF" | tail -1 | grep -aq "qmlls=absent"; }
sc_preview() {
    note "preview: the whole command against a stand-in lock_env: the .qmlls.ini is set aside for its life"
    rm -rf /tmp/lrlk-f6pv
    mark pv
    ( LARES_PREVIEW_ENV=f6pv "$TOOLDIR/lares" preview > "$OUT/pv.out" 2>&1 < /dev/null & echo $! > "$OUT/pv.pid" )
    waitfor 15 preview_shell_up
    check "preview: nested session up with HOST=window, the gaps set, the shell started with mock services" \
        ordered pv "LOCKENV up [LOCK_ENV=f6pv HOST=window]" "LOCKENV hyprctl eval" "LOCKENV run env SHELL_SERVICES=mock" "QUICKSHELL start"
    check "preview: the repo's .qmlls.ini is set aside while it runs, and the shell started without one" bash -c 'qmlls(){ [ ! -L "$1/.qmlls.ini" ] && [ ! -e "$1/.qmlls.ini" ]; }; qmlls "$1"' _ "$REPO"
    check "preview: the shell started in a root with no .qmlls.ini" last_shell_started_without_qmlls
    check "preview: the link is kept in the persistent state dir, recorded as the preview's (its pid)" bash -c 'grep -qx "owner=preview:$(cat "$1/pv.pid")" "$2/record"' _ "$OUT" "$QMLLS_STORE"
    T apply --commit clock modules/clock/ClockStyle.qml   # any command that is not a pure query looks for a stranded link first
    check "preview: another lares command leaves a running preview's .qmlls.ini alone" qmlls_absent
    LARES_PREVIEW_ENV=f6pv T preview
    check "preview: a second preview is refused while the environment is up (exit 1)" bash -c '[ "$1" -eq 1 ] && grep -aq "is up already" "$2"' _ "$RC" "$OUT/last.out"
    kill -TERM "$(cat "$OUT/pv.pid")"
    check "preview: ended (TERM, like Ctrl-C): the nested session goes down" waitfor 10 bash -c 'grep -aq "LOCKENV down" <(sed -n "/^MARK pv\$/,\$p" "$1")' _ "$LOGF"
    check "preview: ... and the .qmlls.ini is back, the same link" waitfor 5 c_qmlls_back
    check "preview: ... and nothing is left aside" qmlls_not_aside
    check "preview: ... and the environment is gone" waitfor 5 bash -c '[ ! -e /tmp/lrlk-f6pv ]'
    local q; for q in $(fake_pids quickshell); do kill "$q" 2> /dev/null; done
}

# ---- a preview that died without giving its link back ---------------------------------------------
strand() {   # strand <owner pid>: the root's link set aside as a preview with that pid would have left it
    mkdir -p "$QMLLS_STORE"
    printf 'root=%s\nowner=preview:%s\n' "$REPO" "$1" > "$QMLLS_STORE/record"
    mv -T "$REPO/.qmlls.ini" "$QMLLS_STORE/qmlls.ini.saved"
}
sc_stranded() {
    note "stranded: a preview that ended without giving its .qmlls.ini back (a reboot, a kill -9)"
    strand 999999
    T preview --dry-run
    check "stranded: a dry run says it WOULD PUT BACK the link, and does not" bash -c 'grep -aq "WOULD PUT BACK the .qmlls.ini a preview set aside" "$1" && [ ! -L "$2/.qmlls.ini" ]' _ "$OUT/last.out" "$REPO"
    T apply --commit clock modules/clock/ClockStyle.qml
    check "stranded: the next command puts the .qmlls.ini back (the same link) and says so" bash -c '
        [ "$(readlink "$1/.qmlls.ini")" = "$2" ] && grep -aq "qmlls.ini   put back" "$3"' _ "$REPO" "$QMLLS_TARGET0" "$OUT/last.out"
    check "stranded: ... and keeps nothing aside" qmlls_not_aside
    strand 999999
    rm -f "$QMLLS_STORE/qmlls.ini.saved"
    T apply --commit clock modules/clock/ClockStyle.qml
    check "stranded: with the saved link gone too, the link HEAD tracks comes back" bash -c '[ "$(readlink "$1/.qmlls.ini")" = "$2" ]' _ "$REPO" "$QMLLS_TARGET0"
    check "stranded: ... and the record is dropped" qmlls_not_aside
    spawn_fake waybar   # a live pid whose command line is no lares: not a preview any more
    strand "$(fake_pid waybar)"
    T apply --commit clock modules/clock/ClockStyle.qml
    check "stranded: a pid that lives but is no lares (a reused pid) does not hold the link: it is put back" c_qmlls_back
    kill "$(fake_pid waybar)" 2> /dev/null
}

# ---- apply ------------------------------------------------------------------------------------------
c_head_is() { [ "$(repo rev-parse HEAD)" = "$1" ]; }
c_commit_files() { [ "$(repo show --name-only --format= HEAD | sort | paste -sd,)" = "$1" ]; }
c_staged_is() { [ "$(repo diff --cached --name-only | paste -sd,)" = "$1" ]; }
c_subject_is() { [ "$(repo log -1 --format=%s)" = "$1" ]; }
c_no_trailer() { ! repo log -1 --format=%B | grep -qi "co-authored"; }
sc_apply() {
    note "apply --commit with nothing deployed: exactly the named files"
    local head0 count0
    printf 'Item { property int value: 2 }\n' > "$REPO/modules/clock/ClockStyle.qml"
    printf 'Item { property int value: 2 }\n' > "$REPO/modules/stocks/StocksStyle.qml"
    printf 'Item { property int value: 3 }\n' > "$REPO/modules/clock/Other.qml"
    repo add modules/clock/Other.qml                               # a stranger, staged (somebody else's work)
    printf 'untracked\n' > "$REPO/modules/clock/Stray.qml"          # a stranger, untracked
    count0=$(repo rev-list --count HEAD)
    T apply --commit clock modules/clock/ClockStyle.qml "$REPO/modules/stocks/StocksStyle.qml"
    check "apply: exit 0, committed; nothing is deployed, so committed only" bash -c '[ "$1" -eq 0 ] && grep -aq "committed" "$2" && grep -aq "nothing is deployed: committed only" "$2"' _ "$RC" "$OUT/last.out"
    check "apply: the title is 'PROBE - tuning: clock' (the repo's user.name, Probe)" c_subject_is "PROBE - tuning: clock"
    check "apply: no Co-Authored-By trailer (the commit is the user's)" c_no_trailer
    check "apply: the commit holds exactly the two named files (one named relative, one absolute)" c_commit_files "modules/clock/ClockStyle.qml,modules/stocks/StocksStyle.qml"
    check "apply: exactly one commit was added" test "$(repo rev-list --count HEAD)" -eq $(( count0 + 1 ))
    check "apply: the staged stranger (Other.qml) is still staged and uncommitted" c_staged_is "modules/clock/Other.qml"
    check "apply: the untracked stranger (Stray.qml) is still untracked" bash -c 'git -C "$1" status --porcelain | grep -qx "?? modules/clock/Stray.qml"' _ "$REPO"
    head0=$(repo rev-parse HEAD)
    T apply --commit clock modules/clock/ClockStyle.qml
    check "apply: files with no change are not committed" bash -c '[ "$1" -eq 0 ] && grep -aq "nothing changed" "$2"' _ "$RC" "$OUT/last.out"
    check "apply: HEAD did not move" c_head_is "$head0"
    T apply --commit clock modules/clock/Stray.qml
    check "apply: a new (untracked) file is committed when named" c_commit_files "modules/clock/Stray.qml"
    check "apply: the staged stranger is still staged after the second commit" c_staged_is "modules/clock/Other.qml"
    head0=$(repo rev-parse HEAD)
    mv -T "$REPO/.qmlls.ini" "$OUT/qmlls.keep"; printf 'x\n' > "$REPO/.qmlls.ini"
    T apply --commit clock /etc/hostname
    check "apply: a file outside the repo is refused (exit 1)" rc_is 1
    T apply --commit clock .qmlls.ini
    check "apply: .qmlls.ini is refused (exit 1)" rc_is 1
    T apply --commit clock modules/clock
    check "apply: a directory is refused (exit 1)" rc_is 1
    T apply --commit clock modules/clock/Nope.qml
    check "apply: a file that is neither on disk nor tracked is refused (exit 1)" rc_is 1
    T apply --commit clock
    check "apply: no files is a usage error (exit 2)" rc_is 2
    T apply modules/clock/ClockStyle.qml
    check "apply: without --commit is a usage error (exit 2)" rc_is 2
    check "apply: none of the refusals committed anything" c_head_is "$head0"
    rm -f "$REPO/.qmlls.ini"; mv -T "$OUT/qmlls.keep" "$REPO/.qmlls.ini"
    repo reset -q -- modules/clock/Other.qml
}

# ---- the tables against the modules -----------------------------------------------------------------
table_rows() { sed -n "/^BINDS_TABLE=/,/^'\$/p" "$TOOLDIR/lares"; }   # the rows of BINDS_TABLE, as written
c_osd_table_matches() {   # the OSD rows of BINDS_TABLE are modules/osd/OsdShortcuts.qml's header, key for key
    local header ours
    header=$(sed -nE 's|^// *hl\.bind\("([^"]+)", *osd\("([^"]+)"\), *(K\|\{ non_consuming = true \})\).*|\1 \2|p' "$ROOT/modules/osd/OsdShortcuts.qml" | sort)
    ours=$(table_rows | sed -nE 's/^([A-Za-z_0-9 +]+[A-Za-z_0-9]) +\| global:(osd-[a-z-]+) .*/\1 \2/p' | sort)
    [ -n "$header" ] && [ "$header" = "$ours" ] || { diff <(echo "$header") <(echo "$ours") >&2; return 1; }
}
c_layer_namespaces_match_code() {   # every layer surface the shell opens has a rule, and no rule names a surface that is gone
    local code ours
    code=$(grep -rhoE 'WlrLayershell\.namespace: *"[^"]+"' "$ROOT/modules" "$ROOT/shell.qml" | sed -E 's/.*"([^"]+)"/\1/' | sort -u)
    ours=$(sed -n "/^LAYER_RULES_TABLE=/,/^'/p" "$TOOLDIR/lares" | sed -nE 's/^[a-z_]+ +\| \^([^$]+)\$$/\1/p' | sort -u)
    [ -n "$code" ] && [ "$code" = "$ours" ] || { diff <(echo "$code") <(echo "$ours") >&2; return 1; }
}
c_globals_match_code() {   # every GlobalShortcut name the modules declare is a key of the table or one of EXTRA_GLOBALS, and back
    local code ours extra
    code=$( { grep -rh -A3 'GlobalShortcut {' "$ROOT/modules" --include=*.qml | sed -nE 's/^ *name: *"([^"]+)".*/\1/p'
              sed -nE 's|^// *hl\.bind\("[^"]+", *osd\("([^"]+)"\).*|\1|p' "$ROOT/modules/osd/OsdShortcuts.qml"; } | sort -u)
    extra=$(sed -nE "s/^EXTRA_GLOBALS='([^']*)'.*/\1/p" "$TOOLDIR/lares")
    # shellcheck disable=SC2086
    ours=$( { table_rows | sed -nE 's/.*\| global:([a-z-]+) .*/\1/p'; printf '%s\n' $extra; } | sort -u)
    [ -n "$code" ] && [ "$code" = "$ours" ] || { diff <(echo "$code") <(echo "$ours") >&2; return 1; }
}
sc_tables() {
    note "tables: the tool's tables against the modules"
    check "tables: the OSD rows of BINDS_TABLE are OsdShortcuts.qml's header, key for key" c_osd_table_matches
    check "tables: the layer rules name exactly the namespaces the code opens (WlrLayershell.namespace in modules/)" c_layer_namespaces_match_code
    check "tables: the globals are every GlobalShortcut the modules declare (BINDS_TABLE + EXTRA_GLOBALS), no more" c_globals_match_code
}

# ---- update-running -------------------------------------------------------------------------------------
sc_update() {
    note "update: update-running"
    local marker=$HOME/.local/state/lares/system-update/last-run.json p
    mkdir -p "${marker%/*}"
    spawn_fake pmstub -Q
    p=$(fake_pid pmstub)
    printf '{"state": "running", "pid": %s}\n' "$p" > "$marker"
    T update-running
    check "update: a run the marker says runs, whose pid lives: its pid (exit 0)" bash -c '[ "$1" -eq 0 ] && [ "$(cat "$2")" = "$3" ]' _ "$RC" "$OUT/last.out" "$p"
    printf '{"state": "done", "pid": %s}\n' "$p" > "$marker"
    T update-running
    check "update: a finished run is none (exit 1, nothing printed)" bash -c '[ "$1" -eq 1 ] && [ ! -s "$2" ]' _ "$RC" "$OUT/last.out"
    kill "$p"; waitfor 3 gone "$p"
    printf '{"state": "running", "pid": %s}\n' "$p" > "$marker"
    T update-running
    check "update: a run whose pid is gone is none (exit 1)" rc_is 1
    rm -f "$marker"
}

# ---- misc -------------------------------------------------------------------------------------------
sc_misc() {
    note "misc"
    T preview --dry-run
    check "preview: --dry-run prints the nested-Hyprland commands (HOST=window, mock services) and runs none" bash -c '
        [ "$1" -eq 0 ] && grep -aq "HOST=window" "$2" && grep -aq "SHELL_SERVICES=mock" "$2" && grep -aq "quickshell -n -p" "$2" && [ ! -e /tmp/lrlk-shellpv ]' _ "$RC" "$OUT/last.out"
    T help
    check "help: prints the commands (exit 0) and stops at the divider" bash -c '
        [ "$1" -eq 0 ] && grep -aq "lares deploy" "$2" && grep -aq "lares binds" "$2" && grep -aq "lares setup" "$2" && grep -aq "lares cleanup-marks" "$2" &&
        ! grep -aq "THE SNAPSHOTS" "$2"' _ "$RC" "$OUT/last.out"
    T nonsense
    check "an unknown command is a usage error (exit 2)" rc_is 2
    T trial on
    check "'trial' is gone: exit 2 and it says so" bash -c '[ "$1" -eq 2 ] && grep -aq "is gone" "$2"' _ "$RC" "$OUT/last.out"
    T revert
    check "'revert' is gone: exit 2" rc_is 2
    T root-steps
    check "'root-steps' is gone: exit 2, and it names setup" bash -c '[ "$1" -eq 2 ] && grep -aq "lares setup" "$2"' _ "$RC" "$OUT/last.out"
    T binds apply
    check "'binds apply' is gone (exit 1, it says so)" bash -c '[ "$1" -eq 1 ] && grep -aq "is gone" "$2"' _ "$RC" "$OUT/last.out"
    T oled status
    check "oled with nothing deployed: exit 3" rc_is 3
    T oled on
    check "'oled on' is gone (the switch is shell.jsonc's oled.enabled): exit 2" rc_is 2
    T oled off
    check "'oled off' is gone: exit 2" rc_is 2
    T status
    check "status with nothing deployed: exit 3, it says so" bash -c '[ "$1" -eq 3 ] && grep -aq "nothing is deployed" "$2"' _ "$RC" "$OUT/last.out"
    check "no command of this run wrote a config file of the home (there is none: the home holds the tool's own state only)" bash -c '
        [ -z "$(find "$1" -path "$1/.local/state" -prune -o -type f -print | head -1)" ]' _ "$HOME"
    if command -v shellcheck > /dev/null; then
        check "shellcheck: lares, lares-supervise, lares-lib.sh and the two probes are clean" \
            shellcheck -x "$ROOT/tools/shell/lares" "$ROOT/tools/shell/lares-supervise" "$ROOT/tools/shell/lares-lib.sh" \
            "$ROOT/tools/dev/lares_tool_probe.sh" "$ROOT/tools/dev/lares_deploy_probe.sh"
    else
        echo "  (shellcheck is not installed: skipped; bash -n is the quick tier's)"
    fi
}

sc_final() {
    check "final: no .qmlls.ini is left aside in the state dir" qmlls_not_aside
}

# ---- the run ------------------------------------------------------------------------------------------
world_up
if [ -n "${ARM:-}" ]; then
    rm -rf "$W/armed"; mkdir -p "$W/armed"; cp -r "$ROOT/tools/shell" "$W/armed/shell"
    arm_patch "$W/armed/shell" "$ARM" || { echo "$NAME RESULT FAIL (the ARM could not be applied)"; exit 3; }
    TOOLDIR=$W/armed/shell
fi
sc_guard   # always first, whatever ONLY says: nothing below may run before the world is proven to be the world
SCENARIOS=${ONLY:-}
if [ -z "$SCENARIOS" ]; then
    if [ -n "${ARM:-}" ]; then SCENARIOS=$(arm_scenarios "$ARM"); else SCENARIOS="pacman preview stranded apply tables update misc final"; fi
fi
for s in $SCENARIOS; do   # a name that is no scenario is a failure, not a pass of fewer checks
    [ "$s" = guard ] && continue
    if declare -F "sc_$s" > /dev/null; then "sc_$s"; else bad "no such scenario: $s"; fi
done
if [ "$FAILS" -eq 0 ]; then
    echo "$NAME RESULT PASS ($PASSES checks)"
else
    echo "$NAME RESULT FAIL ($FAILS of $(( PASSES + FAILS )) failed: $(IFS=';'; echo "${FAILED[*]}"))"
fi
