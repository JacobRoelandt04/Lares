#!/usr/bin/env bash
# lares's deployed shell (deploy / start / restart / apply / the rescue / the crash loop), `binds`, `setup` and the one-time
# `cleanup-marks`, against a FAKE WORLD -- never the desktop, never the user's files.
#
#   tools/dev/lares_deploy_probe.sh                 ends in LARES_DEPLOY RESULT PASS|FAIL
#   ONLY="deploy start" tools/dev/...              just those scenarios (a development aid; guard always runs first)
#   REAL=1 tools/dev/...                           the fake home's configs are COPIES of the user's as they are today (read,
#                                                  never written) instead of the fixtures: the cleanup judged on today's files
#   ARM=<name> tools/dev/...                       a fault in the world's COPY of tools/shell; must FAIL on its needle
#   ARM=all                                        every ARM; LARES_DEPLOY ARMS PASS when each failed as it must
#     editsfile        deploy writes keybinds.lua                    -> "deploy writes no config file"
#     devkit           the snapshot carries the dev kit (tools/dev/)  -> "the snapshot carries no dev kit"
#     noreexec         start runs the WORKING TREE's supervisor       -> "the supervisor runs from the snapshot"
#     switchfirst      the supervisor moves `current` before it stops the shell -> "stopped BEFORE current moved"
#     noguard          deploy is not guarded                         -> "deploy is refused while db.lck exists"
#     noslow           a crash loop restarts fast for ever, unsaid    -> "the crash loop is said ONCE"
#     nostale          a dead session's record is never cleared       -> "a dead session's record is cleared"
#     staleflag        `binds` never calls a line STALE               -> "a bind running a command that is gone is STALE"
#     cleanupkeepsuser the cleanup drops the user's comment lines too  -> "every line you wrote and every shell line stays"
#     chezwrite        the cleanup writes chezmoi's source too       -> "chezmoi's source is left alone"
#     portalblind      setup never judges the portal units           -> "the portal units that are installed (not the termfilechooser's) are TO DO"
#     portalnotinst    setup asks a drop-in for an uninstalled unit  -> the same
#     portalwrong      the printed line writes another drop-in       -> "the printed line wrote session.conf (Requisite=graphical-session.target)"
#     noshim           deploy places no shim at the old names         -> "the shims are in the SNAPSHOTS"
#     shimalways       deploy places the shims whatever names them    -> "the same deploy takes the shims away"
#     nogate           deploy does not wait for migrate-name          -> "deploy before migrate-name is REFUSED"
#     migrateown       migrate-name moves Quickshell's own dirs too   -> "Quickshell's own (by-shell"
#     noputback        migrate-name leaves Qt's misplaced dirs        -> "Qt's own dirs an earlier run moved are put back"
#     qtshaderours     qtshadercache-* / _qt_* counted as ours (r9)   -> "Qt's shader caches are not ours"
#     naivemove        rename, then link (a gap at the old path)      -> "NO INSTANT WITHOUT THE OLD PATH"
#     nohandover       deploy leaves the old-name supervisor alone    -> "the old supervisor and the old shell are gone"
#     cleanupnovenv    cleanup-old-name ignores the dictation's venv  -> "it refuses for the dictation's venv"
#     cleanupnolines   cleanup-old-name ignores your lines            -> "it refuses for your lines"
#     cleanuplock      cleanup-old-name ignores a lock of the old name -> "it refuses for a lock of the old name"
#     boostuid         setup takes a boost unit of another uid for yours -> "R6: a unit written for another uid is TO DO"
#
# THE WORLD. A temp dir holds a HOME, an XDG_RUNTIME_DIR, a git repo (the fixture "repo" with a COPY of tools/shell -- the code
# under test, armed or not -- so that a snapshot of a commit holds the tool too, and `start` re-execs the snapshot's copy as it
# does at login), a fake root (/etc and /usr/local, READ by `setup`), a fake D-Bus services dir (a mako that would take the
# notification name), a private session bus (tools/dev/notifications_bus.sh) and the stubs first on PATH
# (tools/dev/fixtures/lares/bin: hyprctl, systemctl, quickshell, waybar ...). chezmoi is not used (the user's call): the fake
# home keeps a chezmoi source dir with hypridle.conf's template, marks and all, which the cleanup must leave alone. The home is
# tools/dev/fixtures/lares/deploy/home -- copies of the user's autostart / keybinds / layerrules / windowrules /
# environment.lua, hypridle.conf (and its old chezmoi template), ~/.local/bin/hyprlock and hyproled-toggle.sh as they
# were on 2026-11-09, with the marks an earlier `lares deploy` left in them; their /home/user/ paths are made the fake
# home's -- plus shell.jsonc, llm.jsonc, and the record that earlier deploy kept (record.json, deploy.json, originals/) and an
# earlier trial's leftovers. Everything runs under `env -i`.
#
# NOTHING OUTSIDE MOVED. The outer half takes stat + sha256 of every real file the tool could touch (the user's Hyprland files,
# hypridle.conf, the chezmoi sources, the hyprlock wrapper, hyproled, the quickshell configs, ~/.config/systemd/user, the
# snapshots' `current` links, deploy's old record, /etc's autologin and lares-lock, /usr/local) before the inner half runs and
# after it, and FAILS on any difference (the check "outside: ...").
#
# THE SCENARIOS (one world, in this order):
#   guard       stubs first on PATH; HOME, bus, runtime dir and signature the world's
#   dryrun      deploy --dry-run: what it would snapshot and point; nothing written, nothing started
#   deploy      a snapshot of the COMMIT (no .qmlls.ini, no dev kit, locale linked, the repo named), the lock's snapshot, current;
#               no question asked, no config file written, the old record untouched, nothing started; the config summary line
#   status      deployed and not running: exit 1, it says so; the marks note
#   start       the supervisor started by the compositor FROM THE SNAPSHOT, the shell `-n -p <deploy>/current/shell.qml` owning
#               the notification name, the geoclue agent once; a program of the session left alone; a second start does nothing
#   restart     a new shell pid from the same snapshot
#   redeploy    a new commit: the supervisor stops the shell, moves current, starts it; lares-ime's changed source is said, an
#               unchanged one is not; older snapshots pruned (the supervisor's own kept)
#   apply       apply --commit: committed, the shell deployed on it
#   pacman      the guard: deploy and restart refused (exit 4; the refusal said through hyprctl notify), apply commits and is not
#               deployed (exit 4); a deploy after it catches up
#   fallback    the former panic command: the shell restarted, the line called stale (a notice), nothing else started
#   crashloop   a shell that does not load: the restarts, then ONE notice through hyprctl notify and slower tries, nothing else
#               started; the rescue key (restart) cuts the wait and the loop
#   stale       a record of a dead session is cleared by the next command; `start` waits for a package transaction, then starts
#   logcap      a shell that floods its log cannot fill the runtime tmpfs
#   binds       the config's lines against the shell's: ok, the stale panic line, then a missing, a conflicting, a differing and
#               stale lines made on purpose; nothing written; with them fixed, exit 0
#   setup       every check; the root steps run AS PRINTED on the fake root (sudo dropped), twice, then their undo: /etc byte for
#               byte; a notification daemon D-Bus could start, masked
#   boost       (after deploy) R6, the interaction boost: no row while silicon's helper is not installed; a helper that has
#               boost-serve: optional ("-") until silicon.jsonc asks, then TO DO; the step's lines run AS PRINTED on the fake root
#               (sudo dropped), twice: the unit is the snapshot's template with your uid, systemctl asked to enable it; ok; a unit of
#               another uid is TO DO; the undo takes it out (/etc byte for byte); an older helper gets the rebuild line
#   namemove    (a second world, today's layout: our state / cache / data under the Quickshell names, a deployed shell of the OLD name under
#               the real old supervisor) deploy refused before migrate-name; migrate-name: dry run, a no, a yes -- every directory of ours
#               moves to its Lares name and a SYMLINK stays at the old path in ONE exchange (a reader asking ten old paths in a loop
#               misses none), Quickshell's own dirs untouched, ~/.local/bin/lares linked, the old link out, a second run a no-op, a
#               script of the user's left alone, a conflict refused with nothing moved
#   namedeploy  the first deploy after the move replaces the old supervisor (the new shell runs the NEW path, quickshell lists it there),
#               places a shim at each old entry-point name a line of yours / an installed old root file still runs -- in the snapshots, never
#               the repo -- takes them away again once nothing names them
#   namebinds   the old lines are STALE (the OLD app id, the OLD names, the OLD snapshot path, the OLD namespaces), the new ones beside them;
#               setup lists hypridle.conf / hyproled-toggle.sh; nothing written
#   nameroot    setup for today's root: the Lares files BESIDE the old (boot lock, session, PAM copies, silicon's polkit action), SDDM's line
#               switched, run AS PRINTED on the fake root twice, the old files byte for byte; the printed undo brings the root back
#   namecleanup cleanup-old-name refuses for each reason (your lines, the venv, a lock of the old name), then removes the symlinks and
#               prints the root removal; a second run has nothing to do
#   cleanup     cleanup-marks: dry run, a no, a mangled mark, a symlink, a file changed while the plan was shown -- each writes
#               nothing; a yes: every mark and commented-out line gone, every other line kept, chezmoi's source left alone byte for
#               byte, modes kept, deploy's record and the trial's logs archived; a second run has nothing to do
#
# A run that printed no LARES_DEPLOY RESULT ends on `LARES_DEPLOY RESULT FAIL (no result: <log>)` (tools/dev/result_lib.sh).
# shellcheck disable=SC2016   # the bodies of the `bash -c '...'` checks are literal scripts that read their own positional parameters
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
FIX=$ROOT/tools/dev/fixtures/lares
FIXD=$FIX/deploy
NAME=LARES_DEPLOY
# shellcheck source=tools/dev/result_lib.sh
. tools/dev/result_lib.sh
HOMEFILES=".config/hypr/config/autostart.lua .config/hypr/config/keybinds.lua .config/hypr/config/layerrules.lua
.config/hypr/config/windowrules.lua .config/hypr/config/environment.lua .config/hypr/hypridle.conf .local/bin/hyprlock
.config/hypr/scripts/hyproled/hyproled-toggle.sh .config/chezmoi/chezmoi.toml .local/share/chezmoi/dot_config/hypr/executable_hypridle.conf.tmpl"

# =====================================================================================================
# THE OUTER HALF: the world's directory, the inner half under `env -i`, the verdict; nothing outside may move
# =====================================================================================================
outside_paths() {   # every real path the tool could reach on this machine
    local h=$HOME c=${XDG_CONFIG_HOME:-$HOME/.config}
    printf '%s\n' "$c/hypr/config" "$c/hypr/hypridle.conf" "$h/.local/bin/hyprlock" "$c/hypr/scripts/hyproled" \
        "$c/quickshell/shell.jsonc" "$c/quickshell/llm.jsonc" "$c/systemd/user" "$h/.local/share/chezmoi/dot_config/hypr" \
        "$h/.local/state/lares/shell/current" "$h/.local/state/lares/lock/current" "$h/.local/state/lares/tool/deploy" \
        /etc/sddm.conf.d /etc/pam.d/lares-lock /usr/local/share/wayland-sessions /usr/local/bin/lares-boot-lock \
        "$c/quickshell/config/silicon.jsonc" /etc/systemd/system/lares-boost.service
}
outside_state() {   # stat + sha256 of each (a directory: of everything in it); read only
    python3 -B - "$@" << 'PY'
import hashlib, os, sys
def one(p):
    try:
        st = os.lstat(p)
    except OSError:
        return "%s ABSENT" % p
    if os.path.islink(p):
        return "%s LINK %s %d" % (p, os.readlink(p), int(st.st_mtime))
    if os.path.isdir(p):
        out = ["%s DIR %o" % (p, st.st_mode)]
        for d, ds, fs in os.walk(p):
            ds.sort()
            for f in sorted(fs) + [x for x in ds if os.path.islink(os.path.join(d, x))]:
                out.append(one(os.path.join(d, f)))
        return "\n".join(out)
    try:
        h = hashlib.sha256(open(p, "rb").read()).hexdigest()
    except OSError as e:
        h = "unreadable(%s)" % e.errno
    return "%s FILE %o %d %s" % (p, st.st_mode, int(st.st_mtime), h)
print("\n".join(one(p) for p in sys.argv[1:]))
PY
}

outer() {
    local W LOG rc arm=${1:-} before after
    W=$(mktemp -d /tmp/lrdep.XXXXXX) || exit 1
    chmod 700 "$W"
    LOG=$W/probe.log
    # shellcheck disable=SC2064
    trap "reap_world '$W'" EXIT
    mapfile -t OUTSIDE < <(outside_paths)
    before=$(outside_state "${OUTSIDE[@]}")
    env -i HOME="$W/home" PATH="$FIX/bin:/usr/local/bin:/usr/bin:/bin" LANG=C.UTF-8 USER="${USER:-probe}" TERM=dumb \
        XDG_RUNTIME_DIR="$W/rt" XDG_CONFIG_HOME="$W/home/.config" XDG_STATE_HOME="$W/home/.local/state" \
        XDG_CACHE_HOME="$W/home/.cache" XDG_DATA_HOME="$W/home/.local/share" \
        WAYLAND_DISPLAY=wayland-fake HYPRLAND_INSTANCE_SIGNATURE=fakesig LARES_FAKE="$W/fake" \
        LARES_PROBE_INNER=1 W="$W" ARM="$arm" ONLY="${ONLY:-}" KEEP="${KEEP:-}" REAL="${REAL:-}" REALHOME="$HOME" \
        "$ROOT/tools/dev/notifications_bus.sh" bash "$ROOT/tools/dev/lares_deploy_probe.sh" > "$LOG" 2>&1
    rc=$?
    after=$(outside_state "${OUTSIDE[@]}")
    if [ "$before" = "$after" ]; then
        echo "  ok   outside: nothing outside the world moved (stat + sha256 of ${#OUTSIDE[@]} real paths, before and after)" >> "$LOG"
    else
        { echo "  FAIL outside: a REAL path moved during the run:"; diff <(echo "$before") <(echo "$after") | head -20
          echo "$NAME RESULT FAIL (outside: a real file moved)"; } >> "$LOG"
    fi
    grep -a -v "^$NAME RESULT" "$LOG"
    echo "(inner half exited $rc)"
    if [ -n "$arm" ]; then
        judge_arm "$arm" "$LOG"
        return $?
    fi
    if grep -aq "^  FAIL outside:" "$LOG"; then echo "$NAME RESULT FAIL (outside: a real file moved during the run: $LOG)"; KEEP=1; return 1; fi
    rl_result "$NAME" "$LOG"
}

# reap_world <dir>: every process that carries this world's marker in its environment (never by name), then the dir.
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
    if [ -n "${KEEP:-}" ]; then echo "(kept: $w)"; else rm -rf "$w"; fi
}

arm_needle() {
    case $1 in
        editsfile)        echo "deploy writes no config file" ;;
        devkit)           echo "the snapshot carries no dev kit" ;;
        noreexec)         echo "the supervisor runs from the snapshot" ;;
        switchfirst)      echo "stopped BEFORE current moved" ;;
        noguard)          echo "deploy is refused while db.lck exists" ;;
        noslow)           echo "the crash loop is said ONCE" ;;
        nostale)          echo "a dead session's record is cleared" ;;
        staleflag)        echo "a bind running a command that is gone is STALE" ;;
        cleanupkeepsuser) echo "every line you wrote and every shell line stays" ;;
        chezwrite)        echo "chezmoi's source is left alone" ;;
        portalblind|portalnotinst) echo "the portal units that are installed (not the termfilechooser's) are TO DO" ;;
        portalwrong)      echo "the printed line wrote session.conf (Requisite=graphical-session.target)" ;;
        noshim)           echo "the shims are in the SNAPSHOTS" ;;
        shimalways)       echo "the same deploy takes the shims away" ;;
        nogate)           echo "deploy before migrate-name is REFUSED" ;;
        migrateown)       echo "Quickshell's own (by-shell" ;;
        noputback)        echo "Qt's own dirs an earlier run moved are put back" ;;
        qtshaderours)     echo "Qt's shader caches are not ours" ;;
        naivemove)        echo "NO INSTANT WITHOUT THE OLD PATH" ;;
        nohandover)       echo "the old supervisor and the old shell are gone" ;;
        cleanupnovenv)    echo "it refuses for the dictation's venv" ;;
        cleanupnolines)   echo "it refuses for your lines" ;;
        cleanuplock)      echo "it refuses for a lock of the old name" ;;
        sddmfirst)        echo "SDDM is switched only together with" ;;
        boostuid)         echo "R6: a unit written for another uid is TO DO" ;;
        alwayscolour)     echo "setup: the printed steps hold 5 commands" ;;
        nocolour)         echo "setup on a terminal: the commands are coloured" ;;
    esac
}
arm_scenarios() {
    case $1 in
        editsfile|devkit) echo "deploy" ;;
        noreexec) echo "deploy start" ;;
        switchfirst) echo "deploy start redeploy" ;;
        noguard) echo "deploy start pacman" ;;
        noslow) echo "deploy start crashloop" ;;
        nostale) echo "deploy start stale" ;;
        staleflag) echo "deploy binds" ;;
        cleanupkeepsuser|chezwrite) echo "cleanup" ;;
        portalblind|portalnotinst|portalwrong) echo "deploy setup" ;;
        noshim) echo "namemove namedeploy" ;;
        shimalways|nogate|nohandover) echo "namemove namedeploy" ;;
        migrateown|noputback|qtshaderours|naivemove) echo "namemove" ;;
        cleanupnovenv|cleanupnolines|cleanuplock) echo "namemove namedeploy nameroot namecleanup" ;;
        sddmfirst) echo "namemove namedeploy nameroot" ;;
        boostuid) echo "deploy boost" ;;
        alwayscolour|nocolour) echo "deploy setup" ;;
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
if arm == "editsfile":
    patch("lares", "    printf '[4/4] %s\\n' \"older snapshots\"\n",
          "    printf '[4/4] %s\\n' \"older snapshots\"\n    printf '\\n-- deployed\\n' >> \"$HYPR_CONF_DIR/config/keybinds.lua\"\n")
elif arm == "devkit":
    patch("lares", "-- . ':(exclude).qmlls.ini' ':(exclude)tools/dev' 2>", "-- . ':(exclude).qmlls.ini' 2>")
elif arm == "noreexec":
    patch("lares", '        exec "$here/lares" start "$@"\n', '        true\n')
elif arm == "switchfirst":
    patch("lares-supervise", "    SLOW=0 CRASHES=()\n    stop_child\n    if [ -s \"$RUN/switch\" ]; then", "    SLOW=0 CRASHES=()\n    if [ -s \"$RUN/switch\" ]; then")
    patch("lares-supervise", "        rm -f \"$RUN/switch\"\n    fi\n    start_shell\n}", "        rm -f \"$RUN/switch\"\n    fi\n    stop_child\n    start_shell\n}")
elif arm == "noguard":
    patch("lares", '    guard_pacman "deploy" "$force" || exit 4\n', '')
elif arm == "noslow":
    patch("lares-supervise", "        if (( n > RESTART_LIMIT )); then\n", "        if false; then\n")
elif arm == "nostale":
    patch("lares", "    [ -n \"$rec\" ] || return 1\n    [ \"$rec\" != \"${HYPRLAND_INSTANCE_SIGNATURE:-}\" ] || return 1\n    supervisor_alive && return 1\n    hypr_answers_on \"$rec\" && return 1\n    return 0\n}",
          "    return 1\n}")
elif arm == "staleflag":
    patch("lares-config.py", '    """Why an exec command is stale: a `lares` command that is gone, a snapshot path the snapshot does not have."""\n',
          '    """Why an exec command is stale: a `lares` command that is gone, a snapshot path the snapshot does not have."""\n    return []\n')
elif arm == "cleanupkeepsuser":
    patch("lares-config.py", "        if MARK_OLD.match(line):\n", "        if MARK_OLD.match(line) or line.lstrip().startswith((\"--\", \"#\")):\n")
elif arm == "chezwrite":
    patch("lares-config.py", "        if os.path.realpath(path).startswith(cz_dir + os.sep):\n", "        if False:\n")
elif arm == "portalblind":   # setup never judges the portal units: a machine with no drop-in reads "ok"
    patch("lares", "            *graphical-session.target*) ;;\n            *) printf '%s\\n' \"$u\" ;;\n", "            *) ;;\n")
elif arm == "portalnotinst":   # an uninstalled unit is asked for a drop-in too
    patch("lares", "        [ \"$(timeout 5 \"$SYSTEMCTL\" --user show -p LoadState --value \"$u.service\" 2> /dev/null)\" = loaded ] || continue\n", "")
elif arm == "portalwrong":   # the printed line writes another drop-in than the one the checker asks for
    patch("lares", "\\\\nRequisite=graphical-session.target\\\\n' > ", "\\\\nWants=graphical-session.target\\\\n' > ")
elif arm == "noshim":
    patch("lares", '    mapfile -t want < <(python3 "$MIGRATE" shims "${MIGRATE_ARGS[@]}" 2> /dev/null)\n', '    want=()\n')
elif arm == "shimalways":
    patch("lares", '    mapfile -t want < <(python3 "$MIGRATE" shims "${MIGRATE_ARGS[@]}" 2> /dev/null)\n', '    want=(qs-shell qs-lock-session qs-lock-held qs-lock-warm)\n')
elif arm == "nogate":
    patch("lares", '    migration_gate "deploy" || exit 4\n', '')
elif arm == "migrateown":
    patch("lares-migrate.py", 'def qs_own(name):\n    return name in QS_OWN or name.startswith(QS_OWN_PREFIXES)', 'def qs_own(name):\n    return False')
elif arm == "noputback":
    patch("lares-migrate.py", '    back = returns_of(c)\n', '    back = []\n')
elif arm == "qtshaderours":
    patch("lares-migrate.py", 'QS_OWN_PREFIXES = ("qtpipelinecache", "qtshadercache", "_qt_")', 'QS_OWN_PREFIXES = ("qtpipelinecache",)')
elif arm == "naivemove":
    patch("lares-migrate.py", '    os.symlink(new, new)               # a dangling loop, allowed: the placeholder the exchange puts at the OLD name\n    try:\n        exchange(old, new)\n',
          '    try:\n        os.rename(old, new)\n        import time\n        time.sleep(0.004)\n        os.symlink(new, old)\n')
elif arm == "nohandover":
    patch("lares", '    if supervisor_is_old; then handover_supervisor "$sha"; return; fi\n', '')
elif arm == "cleanupnovenv":
    patch("lares-migrate.py", '    venv = venv_hits(c)\n', '    venv = []\n')
elif arm == "cleanupnolines":
    patch("lares-migrate.py", '    hits = scan_lines(c)\n    old_root, sddm = root_state(c)\n    venv = venv_hits(c)', '    hits = []\n    old_root, sddm = root_state(c)\n    venv = venv_hits(c)')
elif arm == "cleanuplock":
    patch("lares-migrate.py", '    run = running_old(c)\n', '    run = []\n')
elif arm == "boostuid":
    patch("lares", '    grep -q "boost-serve uid=$(id -u) " "$ROOT_PREFIX$ROOT_BOOST_UNIT"', '    grep -q "boost-serve uid=" "$ROOT_PREFIX$ROOT_BOOST_UNIT"')
elif arm == "alwayscolour":   # colour whatever the output is: a file, a pipe (every parse of the printed steps reads escapes)
    patch("lares", '    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then CMD_ON=', '    if true; then CMD_ON=')
elif arm == "nocolour":   # never colour: a terminal sees plain text
    patch("lares", "cmdc() { printf '%s%s%s' \"$CMD_ON\" \"$*\" \"$CMD_OFF\"; }", "cmdc() { printf '%s' \"$*\"; }")
    patch("lares", '    if [ -n "$CMD_ON" ]; then sed -E', '    if false; then sed -E')
elif arm == "sddmfirst":
    patch("lares", " $ROOT_SESSION && sudo sed -i 's/^Session=hyprland", " $ROOT_SESSION\n      sudo sed -i 's/^Session=hyprland")
else:
    print("no such ARM: " + arm); sys.exit(3)
PY
}

ALL_ARMS="editsfile devkit noreexec switchfirst noguard noslow nostale staleflag cleanupkeepsuser chezwrite portalblind portalnotinst portalwrong noshim shimalways nogate migrateown noputback qtshaderours naivemove nohandover cleanupnovenv cleanupnolines cleanuplock sddmfirst boostuid alwayscolour nocolour"
if [ "${LARES_PROBE_INNER:-}" != 1 ]; then
    case ${ARM:-} in
        all)
            bad=0
            for a in ${ONLY_ARMS:-$ALL_ARMS}; do
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
REPO=$W/repo
OUT=$W/out
LOGF=$LARES_FAKE/stub.log
PASSES=0 FAILS=0
FAILED=()
# shellcheck disable=SC2034   # read by the shared lib
SESSION_SIG=fakesig
# shellcheck source=tools/dev/fixtures/lares/probe_lib.sh
. "$FIX/probe_lib.sh"

TOOLSRC=$W/tools/shell   # the code under test: a copy (an ARM patches it), committed into the fixture repo
export LARES_PACMAN_LOCK=$W/fake/pacman/db.lck LARES_PM_COMMS="pmstub yaystub"
export LARES_GEOCLUE_AGENT=$FIX/geoclue/agent
export LARES_ROOT_PREFIX=$W/root LARES_DBUS_SERVICES=$W/dbus LARES_EGL_PLATFORMS=$W/egl   # no NVIDIA platforms in the fake machine: setup checks none
export LARES_READY_TIMEOUT=10 LARES_OWNER_WAIT=3 LARES_STOP_TIMEOUT=2 LARES_BACKOFF=0.2 LARES_START_WAIT=3
export LARES_RESTART_LIMIT=3 LARES_RESTART_WINDOW=60 LARES_SLOW_BACKOFF=1 LARES_SLOW_MAX=2 LARES_STABLE=3
RUN=$XDG_RUNTIME_DIR/lares
export PERSIST=$HOME/.local/state/lares/tool   # exported: state_hash runs inside the checks' bash -c too
DSTATE=$PERSIST/deploy
DDIR=$HOME/.local/state/lares/shell
LDIR=$HOME/.local/state/lares/lock
HYPR=$HOME/.config/hypr
KB=$HYPR/config/keybinds.lua
RC=0
T() {   # T <args...>: the repo's lares (the working tree's, as the user runs it), stdin closed; output $OUT/last.out, status $RC
    timeout 120 "$REPO/tools/shell/lares" "$@" > "$OUT/last.out" 2>&1 < /dev/null
    RC=$?
}
Ty() {  # Ty <answer> <args...>: the same, with the answer on stdin (cleanup-marks' typed yes)
    local ans=$1; shift
    printf '%s\n' "$ans" | timeout 120 "$REPO/tools/shell/lares" "$@" > "$OUT/last.out" 2>&1
    RC=$?
}
out_has() { grep -aqF -- "$1" "$OUT/last.out"; }
rc_is() { [ "$RC" -eq "$1" ]; }
shell_pid() { cat "$RUN/pid" 2> /dev/null; }
sup_pid() { cat "$RUN/supervise.pid" 2> /dev/null; }
owner_pid() {
    gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.GetConnectionUnixProcessID org.freedesktop.Notifications 2> /dev/null | sed -nE 's/.*uint32 ([0-9]+).*/\1/p'
}
repo() { git -C "$REPO" "$@"; }
cur_rev() { local r; r=$(readlink "$DDIR/current" 2> /dev/null) && echo "${r##*/}"; }
shell_owns_name() { local p; p=$(shell_pid); [ -n "$p" ] && [ "$(owner_pid)" = "$p" ]; }
deployed_up() { local p; p=$(shell_pid); [ -n "$p" ] && alive "$p" && shell_owns_name && grep -qF "QUICKSHELL ready pid=$p" "$LOGF"; }
new_shell_ready() { local n; n=$(shell_pid); [ -n "$n" ] && [ "$n" != "$1" ] && alive "$n" && grep -qF "QUICKSHELL ready pid=$n" "$LOGF"; }
sup_log_has() { grep -aqF -- "$1" "$RUN/supervise.log" 2> /dev/null; }

home_hash() {   # every file of the fake home a config writer could reach: the Hyprland files, the wrapper, the quickshell configs, the mask, chezmoi
    ( cd "$HOME" && find .config/hypr .local/bin .config/quickshell .config/systemd .local/share/chezmoi \
        \( -type f -o -type l \) 2> /dev/null | LC_ALL=C sort | while IFS= read -r f; do
            if [ -L "$f" ]; then printf '%s LINK %s\n' "$f" "$(readlink "$f")"; else printf '%s %s %s\n' "$f" "$(stat -c %a "$f")" "$(sha256sum < "$f" | cut -c1-64)"; fi
        done )
}
state_hash() { ( cd "$PERSIST" && find deploy last-trial first-trial-done -type f 2> /dev/null | LC_ALL=C sort | xargs -r sha256sum ); }
home_same_as() { diff <(home_hash) "$1" > "$OUT/home.diff"; }

# ---- the world --------------------------------------------------------------------------------------
home_up() {   # the user's configs as they were on 2026-11-09 (or REAL=1: copies of today's), their /home/user/ (or $REALHOME/) the fake home
    local f src=$FIXD/home
    rm -rf "$HOME"; mkdir -p "$HOME"
    [ -n "${REAL:-}" ] && { src=$REALHOME; echo "-- REAL=1: the fake home holds copies of today's real configs"; }
    for f in $HOMEFILES; do
        [ -e "$src/$f" ] || continue
        mkdir -p "$HOME/${f%/*}"; cp -p "$src/$f" "$HOME/$f"
        sed -i -e "s|/home/user/|$HOME/|g" -e "s|$REALHOME/|$HOME/|g" "$HOME/$f"
    done
    mkdir -p "$HOME/.config/quickshell" "$HOME/.config/theme" "$HOME/.cache"
    cp "$FIXD/shell.fixture.jsonc" "$HOME/.config/quickshell/shell.jsonc"
    cp "$FIXD/llm.fixture.jsonc" "$HOME/.config/quickshell/llm.jsonc"
    printf '{"fixture": "locale"}\n' > "$HOME/.config/quickshell/locale.jsonc"
    mkdir -p "$HOME/.config/quickshell/config"            # the user's config/ folder (2026-11-12): linked into both snapshots
    printf '{"fixture": "lockscreen"}\n' > "$HOME/.config/quickshell/config/lockscreen.jsonc"
    printf '{\n  "theme": "eva",\n  "mode": "light"\n}\n' > "$HOME/.config/theme/state.json"
    old_record_up
    rm -rf "$W/root"; mkdir -p "$W/root"; cp -a "$FIXD/root/." "$W/root/"
    mkdir -p "$W/dbus"   # a notification daemon D-Bus would start while the shell is down (mako's own service file)
    printf '[D-BUS Service]\nName=org.freedesktop.Notifications\nExec=/usr/bin/mako\nSystemdService=mako.service\n' > "$W/dbus/fr.emersion.mako.service"
}
old_record_up() {   # what an earlier deploy recorded (record.json, deploy.json, originals/) and an earlier trial left (its logs, its marker)
    python3 - "$HOME" "$PERSIST/deploy" << 'PY'
import json, os, sys
home, state = sys.argv[1:3]
files = [(".config/hypr/config/autostart.lua", "lua"), (".config/hypr/config/keybinds.lua", "lua"), (".config/hypr/config/layerrules.lua", "lua"),
         (".config/hypr/config/windowrules.lua", "lua"), (".config/hypr/config/environment.lua", "lua"), (".config/hypr/hypridle.conf", "hyprlang"),
         (".local/bin/hyprlock", "bash"), (".config/hypr/scripts/hyproled/hyproled-toggle.sh", "bash"), (".config/quickshell/llm.jsonc", "jsonc"),
         (".local/share/chezmoi/dot_config/hypr/executable_hypridle.conf.tmpl", "hyprlang")]
os.makedirs(os.path.join(state, "originals"), exist_ok=True)
rec = {}
for i, (f, syn) in enumerate(files):
    name = "%03d-%s" % (i, os.path.basename(f))
    open(os.path.join(state, "originals", name), "w").write("the original of %s, before the first deploy\n" % f)
    rec[os.path.join(home, f)] = {"kind": "chezmoi-source" if "chezmoi" in f else "file", "mode": 420, "original": "originals/" + name,
                                 "reconstructed": False, "syntax": syn, "written_sha": "0" * 64}
json.dump({"files": rec}, open(os.path.join(state, "record.json"), "w"), indent=1)
json.dump({"version": 1, "repo": "/nonexistent", "state": "deployed", "mako_masked_by_us": True}, open(os.path.join(state, "deploy.json"), "w"))
PY
    mkdir -p "$PERSIST/last-trial"; printf 'a log of an earlier trial\n' > "$PERSIST/last-trial/shell.log"
    : > "$PERSIST/first-trial-done"
}

world_up() {
    mkdir -p "$LARES_FAKE"/{ctl,qs,pacman} "$OUT" "$W/tools"
    if [ -d "$XDG_RUNTIME_DIR" ]; then chmod 700 "$XDG_RUNTIME_DIR"; else mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"; fi
    : > "$LOGF"
    home_up
    rm -rf "$TOOLSRC"; cp -r "$ROOT/tools/shell" "$TOOLSRC"; rm -rf "$TOOLSRC/__pycache__"
    if [ -n "${ARM:-}" ]; then arm_patch "$TOOLSRC" "$ARM" || { echo "$NAME RESULT FAIL (the ARM could not be applied)"; exit 3; }; fi
    make_repo
    mkdir -p "$REPO/tools/shell"
    cp -r "$TOOLSRC/." "$REPO/tools/shell/"
    ( cd "$REPO" && git add -A tools/shell && git commit -q -m "fixture: the tool under test" )
    home_hash > "$OUT/home.pristine"
    state_hash > "$OUT/state.pristine"
}

# =====================================================================================================
# THE SCENARIOS
# =====================================================================================================
guard_abort() { echo "  FAIL guard: $*"; echo "$NAME RESULT FAIL (guard aborted the run before anything was changed: $*)"; exit 2; }
sc_guard() {
    note "guard: nothing here may be the real desktop or the real home"
    local c
    for c in hyprctl systemctl quickshell waybar; do
        case $(command -v "$c") in "$FIX"/bin/*) ;; *) guard_abort "$c resolves to $(command -v "$c"), not a stub" ;; esac
    done
    case ${DBUS_SESSION_BUS_ADDRESS:-} in ""|*/run/user/*) guard_abort "the session bus is not the private one" ;; esac
    case $HOME in "$W"/*) ;; *) guard_abort "HOME is not the world's" ;; esac
    case $XDG_RUNTIME_DIR in "$W"/*) ;; *) guard_abort "XDG_RUNTIME_DIR is not the world's" ;; esac
    [ "$HYPRLAND_INSTANCE_SIGNATURE" = fakesig ] || guard_abort "the signature is not fakesig"
    grep -rqF -e "/home/user/" -e "$REALHOME/" "$HOME/.config/hypr" "$HOME/.local/bin" && guard_abort "a path of the real home is left in the fake home's configs"
    ok "guard: the programs that act are stubs; the bus, HOME, runtime dir and signature are the world's"
}

# ---- deploy ---------------------------------------------------------------------------------------------------------
sc_dryrun() {
    note "dryrun: deploy --dry-run says what it would snapshot and point, and changes nothing"
    mark dryrun
    T deploy --dry-run
    check "dryrun: exit 0, 'nothing was changed'" bash -c '[ "$1" -eq 0 ] && grep -aq "nothing was changed" "$2"' _ "$RC" "$OUT/last.out"
    check "dryrun: it says the snapshot, the lock's snapshot and current it WOULD make, and that no config file is touched" bash -c '
        grep -aq "^WOULD SNAPSHOT .* into " "$1" && grep -aq "^WOULD SNAPSHOT .* for the lock" "$1" && grep -aq "^WOULD POINT .*current" "$1" &&
        grep -aq "no config file is read or written by a deploy" "$1"' _ "$OUT/last.out"
    check "dryrun: nothing was written or started (home, snapshots, the old record, hyprctl dispatch)" bash -c '
        diff <(home_hash) "$1" > /dev/null && [ ! -e "$2" ] && [ ! -e "$3" ] && diff <(state_hash) "$4" > /dev/null && ! sed -n "/^MARK dryrun\$/,\$p" "$5" | grep -aq "HYPRCTL dispatch"' \
        _ "$OUT/home.pristine" "$DDIR" "$LDIR" "$OUT/state.pristine" "$LOGF"
}
export -f home_hash state_hash

sc_deploy() {
    note "deploy: the snapshot, the lock's snapshot, current -- and no config file"
    printf 'Item { property int value: 77 }\n' > "$REPO/modules/clock/Other.qml"   # an uncommitted edit: the snapshot is the COMMIT
    mark deploy
    T deploy
    check "deploy: exit 0 with no question asked (stdin closed), every step said" bash -c '[ "$1" -eq 0 ] && grep -aq "\[4/4\]" "$2" && ! grep -aqi "type yes" "$2"' _ "$RC" "$OUT/last.out"
    check "deploy: it says the uncommitted edit is not in it (a deploy takes the commit)" bash -c 'grep -aq "1 tracked file(s) .* differ from HEAD" "$1"' _ "$OUT/last.out"
    local sha; sha=$(repo rev-parse HEAD)
    check "deploy: the snapshot is the COMMIT (complete and naming its repo, the tool in it, no .qmlls.ini, not the uncommitted edit, locale linked)" bash -c '
        d=$1/$2; [ "$(cat "$d/.complete")" = "repo=$4" ] && [ -x "$d/tools/shell/lares" ] && [ ! -e "$d/.qmlls.ini" ] && [ ! -L "$d/.qmlls.ini" ] &&
        grep -q "value: 1" "$d/modules/clock/Other.qml" && [ "$(readlink "$d/locale.jsonc")" = "$3/.config/quickshell/locale.jsonc" ]' _ "$DDIR" "$sha" "$HOME" "$REPO"
    check "deploy: the snapshot carries no dev kit (tools/dev/ is in the commit, not in the snapshot)" bash -c '
        [ -n "$(git -C "$1" ls-tree --name-only HEAD tools/dev)" ] && [ ! -e "$2/$3/tools/dev" ] && [ -x "$2/$3/tools/shell/lares" ]' _ "$REPO" "$DDIR" "$sha"
    check "deploy: the config/ folder is linked into both snapshots (the lock reads config/lockscreen.jsonc through it)" bash -c '
        [ "$(readlink "$1/$3/config")" = "$4/.config/quickshell/config" ] && [ "$(readlink "$2/$3/config")" = "$4/.config/quickshell/config" ] &&
        [ -f "$2/$3/config/lockscreen.jsonc" ]' _ "$DDIR" "$LDIR" "$sha" "$HOME"
    check "deploy: current -> the commit; the lock's snapshot is the same commit (its configs linked), its shaders warmed" bash -c '
        [ "$1" = "$2" ] && [ "$(readlink "$3/current")" = "$2" ] && [ "$(readlink "$3/$2/locale.jsonc")" = "$4/.config/quickshell/locale.jsonc" ] &&
        sed -n "/^MARK deploy\$/,\$p" "$5" | grep -aq "^WARM --if-stale"' _ "$(cur_rev)" "$sha" "$LDIR" "$HOME" "$LOGF"
    check "deploy: deploy writes no config file (the fake home is byte for byte as it was) and leaves the old record alone" bash -c '
        diff <(home_hash) "$1" && diff <(state_hash) "$2"' _ "$OUT/home.pristine" "$OUT/state.pristine"
    check "deploy: nothing is started (no shell runs in this session, and it says so)" bash -c '
        ! sed -n "/^MARK deploy\$/,\$p" "$1" | grep -aq "HYPRCTL dispatch" && grep -aq "no shell runs in this session" "$2"' _ "$LOGF" "$OUT/last.out"
    check "deploy: it ends with one line on the config (the stale panic line, the two bare lock keys, the two lock-key lines and Panorama's missing) and the note to clean up the marks" bash -c '
        grep -aq "^config: 6 line(s) of your Hyprland config differ .*3 MISSING.*3 STALE.*lares binds" "$1" && grep -aq "lares cleanup-marks" "$1"' _ "$OUT/last.out"
    repo checkout -q -- modules/clock/Other.qml
}

sc_status() {
    note "status: deployed, not running"
    T status
    check "status: exit 1, the commit, NOT RUNNING in this session, the lock's snapshot, the marks note" bash -c '
        [ "$1" -eq 1 ] && grep -aq "^deployed    $3" "$2" && grep -aq "NOT RUNNING in this session" "$2" && grep -aq "^lock        snapshot $3" "$2" &&
        grep -aq "cleanup-marks" "$2"' _ "$RC" "$OUT/last.out" "$(cur_rev | cut -c1-9)"
}

sc_start() {
    note "start: the supervisor from the snapshot, the shell, the geoclue agent; nothing of the session stopped"
    spawn_fake waybar   # a program of the session the shell has nothing to do with
    waitfor 5 bash -c '[ -n "$1" ]' _ "$(fake_pid waybar)"
    local wb; wb=$(fake_pid waybar)
    mark start
    T start
    check "start: exit 0, the shell runs" bash -c '[ "$1" -eq 0 ] && grep -aq "the shell runs (pid" "$2"' _ "$RC" "$OUT/last.out"
    check "start: the supervisor runs from the snapshot (started by the compositor, the snapshot's copy of the tool)" bash -c '
        sed -n "/^MARK start\$/,\$p" "$1" | grep -aq "^SPAWN .$2/$3/tools/shell/lares-supervise. --run"' _ "$LOGF" "$DDIR" "$(cur_rev)"
    check "start: the shell runs the snapshot through its link (-n -p <deploy>/current/shell.qml), owns the notification name, said ready" bash -c '
        grep -a "QUICKSHELL start pid=$(cat "$2/pid") " "$1" | grep -aqF "argv=-n -p $3/current/shell.qml"' _ "$LOGF" "$RUN" "$DDIR"
    check "start: ... up" waitfor 5 deployed_up
    check "start: the geoclue agent (shell.jsonc geoclueAgent) started once, by the compositor" bash -c '
        [ "$(sed -n "/^MARK start\$/,\$p" "$1" | grep -ac "^SPAWN .*geoclue/agent")" -eq 1 ] && [ "$2" -eq 1 ]' _ "$LOGF" "$(fake_pids agent | wc -l)"
    check "start: a program of the session is left alone (start stops nothing)" alive "$wb"
    T start
    check "start: a second start does nothing (exit 0, 'runs already'; no second agent)" bash -c '
        [ "$1" -eq 0 ] && grep -aq "runs already" "$2" && [ "$3" -eq 1 ]' _ "$RC" "$OUT/last.out" "$(fake_pids agent | wc -l)"
    T status
    check "status: exit 0 while it runs (ipc answers, the name is the shell's)" bash -c '
        [ "$1" -eq 0 ] && grep -aq "shell.ping() -> ok" "$2" && grep -aq "is the shell.s" "$2"' _ "$RC" "$OUT/last.out"
    kill "$wb" 2> /dev/null
}

sc_restart() {
    note "restart: the shell again, from the same snapshot"
    local old cur; old=$(shell_pid); cur=$(cur_rev)
    T restart
    check "restart: exit 0, a new shell pid, ready; current unchanged; the supervisor logged the requested restart" bash -c '
        [ "$1" -eq 0 ] && [ "$(cat "$2/pid")" != "$3" ] && [ "$(readlink "$4/current")" = "$5" ] && grep -aq "restart requested" "$2/supervise.log"' \
        _ "$RC" "$RUN" "$old" "$DDIR" "$cur"
    check "restart: ... up" waitfor 5 new_shell_ready "$old"
}

sc_redeploy() {
    note "redeploy: a new commit -- stop, current, start; lares-ime's source"
    local old prev sha sup
    old=$(shell_pid); prev=$(cur_rev); sup=$(jq -r .supervisor_rev "$RUN/deployed")
    printf 'Item { property int value: 5 }\n' > "$REPO/modules/clock/ClockStyle.qml"
    printf '/* lares-ime, changed */\n' > "$REPO/tools/stt/ime/lares-ime.c"
    repo commit -qam "fixture: a change, lares-ime's too"
    sha=$(repo rev-parse HEAD)
    : > "$RUN/supervise.log.mark"; cp "$RUN/supervise.log" "$OUT/sup.before"
    T deploy
    check "redeploy: exit 0, current -> the new commit, a new shell pid" bash -c '[ "$1" -eq 0 ] && [ "$2" = "$3" ] && [ "$(cat "$4/pid")" != "$5" ]' _ "$RC" "$(cur_rev)" "$sha" "$RUN" "$old"
    check "redeploy: ... up" waitfor 5 new_shell_ready "$old"
    check "redeploy: the old shell was stopped BEFORE current moved (the supervisor's order)" bash -c '
        new=$(tail -c +"$(( $(stat -c %s "$1") + 1 ))" "$2"); s=$(grep -an "was stopped" <<< "$new" | head -1 | cut -d: -f1); m=$(grep -an "switched .*current to" <<< "$new" | head -1 | cut -d: -f1)
        [ -n "$s" ] && [ -n "$m" ] && [ "$s" -lt "$m" ]' _ "$OUT/sup.before" "$RUN/supervise.log"
    check "redeploy: lares-ime's source changed: it says to rebuild it, with the snapshot's build.sh" bash -c '
        grep -aq "lares-ime.s source changed" "$1" && grep -aqF "$2/$3/tools/stt/ime/build.sh" "$1"' _ "$OUT/last.out" "$DDIR" "$sha"
    check "redeploy: no config file was written" home_same_as "$OUT/home.pristine"
    printf 'Item { property int value: 6 }\n' > "$REPO/modules/clock/ClockStyle.qml"
    repo commit -qam "fixture: a change, not lares-ime's"
    old=$(shell_pid)
    T deploy
    check "redeploy: a commit that leaves lares-ime alone says nothing of it" bash -c '[ "$1" -eq 0 ] && ! grep -aq "lares-ime.s source changed" "$2"' _ "$RC" "$OUT/last.out"
    waitfor 5 new_shell_ready "$old"
    check "redeploy: the snapshots kept are current, the one before and the running supervisor's; the first deploy's other ones go" bash -c '
        ls "$1" | grep -E "^[0-9a-f]{40}$" | sort > "$5/snaps"; printf "%s\n" "$2" "$3" "$4" | sort -u > "$5/want"; cmp -s "$5/snaps" "$5/want"' \
        _ "$DDIR" "$(cur_rev)" "$sha" "$sup" "$OUT"
}

sc_apply() {
    note "apply: a mockup's Save commits, and the deployed shell follows"
    local old; old=$(shell_pid)
    printf 'Item { property int value: 9 }\n' > "$REPO/modules/clock/ClockStyle.qml"
    T apply --commit clock modules/clock/ClockStyle.qml
    check "apply: exit 0, committed, deployed on that commit, a new shell pid" bash -c '
        [ "$1" -eq 0 ] && grep -aq "committed" "$2" && grep -aq "is deployed on that commit" "$2" && [ "$3" = "$4" ] && [ "$(cat "$5/pid")" != "$6" ]' \
        _ "$RC" "$OUT/last.out" "$(cur_rev)" "$(repo rev-parse HEAD)" "$RUN" "$old"
    waitfor 5 new_shell_ready "$old"
}

sc_pacman() {
    note "pacman: the restart guard"
    local cur old head0
    cur=$(cur_rev); old=$(shell_pid)
    : > "$LARES_FAKE/pacman/db.lck"
    printf 'Item { property int value: 10 }\n' > "$REPO/modules/clock/ClockStyle.qml"; repo commit -qam "fixture: during an update"
    mark pmd
    T deploy
    check "pacman: deploy is refused while db.lck exists (exit 4, the reason) and moves nothing" bash -c '
        [ "$1" -eq 4 ] && grep -aq "deploy refused: a package transaction runs" "$2" && [ "$3" = "$4" ]' _ "$RC" "$OUT/last.out" "$(cur_rev)" "$cur"
    T restart
    check "pacman: restart is refused too (exit 4), the shell untouched, the refusal said through hyprctl notify (no terminal)" bash -c '
        [ "$1" -eq 4 ] && [ "$(cat "$2/pid")" = "$3" ] && sed -n "/^MARK pmd\$/,\$p" "$4" | grep -aq "^HYPRCTL notify 0 15000 0 lares restart refused"' \
        _ "$RC" "$RUN" "$old" "$LOGF"
    head0=$(repo rev-parse HEAD)
    printf 'Item { property int value: 11 }\n' > "$REPO/modules/clock/ClockStyle.qml"
    T apply --commit clock modules/clock/ClockStyle.qml
    check "pacman: apply commits all the same, and is not deployed (exit 4, it says so)" bash -c '
        [ "$1" -eq 4 ] && [ "$(git -C "$2" rev-parse HEAD)" != "$3" ] && grep -aq "NOT deployed" "$4" && [ "$5" = "$6" ]' \
        _ "$RC" "$REPO" "$head0" "$OUT/last.out" "$(cur_rev)" "$cur"
    rm -f "$LARES_FAKE/pacman/db.lck"
    T deploy
    check "pacman: once it is over, deploy catches up (current -> HEAD)" bash -c '[ "$1" -eq 0 ] && [ "$2" = "$3" ]' _ "$RC" "$(cur_rev)" "$(repo rev-parse HEAD)"
    waitfor 5 new_shell_ready "$old"
}

sc_fallback() {
    note "fallback: the former panic command restarts the shell and says its line is stale"
    local old; old=$(shell_pid)
    mark fb
    timeout 60 "$REPO/tools/shell/lares" fallback --reason 'panic bind' > "$OUT/last.out" 2>&1 < /dev/null; RC=$?
    check "fallback: exit 0, the shell restarted (a new pid, ready)" bash -c '[ "$1" -eq 0 ] && [ "$(cat "$2/pid")" != "$3" ]' _ "$RC" "$RUN" "$old"
    check "fallback: ... up" waitfor 5 new_shell_ready "$old"
    check "fallback: it says the line is stale, on stderr and through hyprctl notify" bash -c '
        grep -aq "fallback. is gone" "$1" && sed -n "/^MARK fb\$/,\$p" "$2" | grep -aq "^HYPRCTL notify 0 15000 0 Super+Shift+F12 ran .lares fallback."' _ "$OUT/last.out" "$LOGF"
    check "fallback: nothing else is started (no compositor child at all)" no_since fb "HYPRCTL dispatch"
}

crash_starts() { since crash | grep -ac "^QUICKSHELL crash pid="; }
sc_crashloop() {
    note "crashloop: a shell that does not load is said once and tried slower; the rescue key cuts the wait"
    local old sp
    old=$(shell_pid); sp=$(sup_pid)
    : > "$LARES_FAKE/ctl/lares_crash"
    mark crash
    kill -KILL "$old"
    waitfor 15 bash -c '[ "$(sed -n "/^MARK crash\$/,\$p" "$1" | grep -ac "^QUICKSHELL crash pid=")" -ge 5 ]' _ "$LOGF"
    check "crashloop: the crash loop is said ONCE (hyprctl notify, an error, naming lares log) and tried slower (1 s, then 2 s)" bash -c '
        [ "$(sed -n "/^MARK crash\$/,\$p" "$1" | grep -ac "^HYPRCTL notify 3 30000 0 The shell keeps crashing")" -eq 1 ] &&
        sed -n "/^MARK crash\$/,\$p" "$1" | grep -a "^HYPRCTL notify 3" | grep -aq "lares log" &&
        grep -aq "crash loop: the next try in 1.0s" "$2" && grep -aq "crash loop: the next try in 2.0s" "$2"' _ "$LOGF" "$RUN/supervise.log"
    check "crashloop: nothing else is started (no compositor child), and the supervisor stays" bash -c '
        ! sed -n "/^MARK crash\$/,\$p" "$1" | grep -aq "HYPRCTL dispatch" && kill -0 "$2"' _ "$LOGF" "$sp"
    rm -f "$LARES_FAKE/ctl/lares_crash"
    T restart
    check "crashloop: the rescue key (restart) brings it back at once, the crash count afresh" bash -c '
        [ "$1" -eq 0 ] && grep -aq "the crash count starts afresh" "$2/supervise.log"' _ "$RC" "$RUN"
    check "crashloop: ... up" waitfor 5 deployed_up
}

sc_stale() {
    note "stale: a record of a session that is gone; start waits for a package transaction"
    local sp
    sp=$(sup_pid)
    kill -TERM "$sp"; waitfor 10 gone "$sp"
    jq '.session.sig = "deadsig"' "$RUN/deployed" > "$RUN/deployed.tmp" && mv "$RUN/deployed.tmp" "$RUN/deployed"
    echo deadsig > "$LARES_FAKE/ctl/hypr_dead_sigs"
    T deploy --dry-run
    check "stale: a dry run says it WOULD CLEAR the record and clears nothing" bash -c 'grep -aq "WOULD CLEAR the record of a shell of an earlier session" "$1" && [ -e "$2/deployed" ]' _ "$OUT/last.out" "$RUN"
    : > "$LARES_FAKE/pacman/db.lck"
    T start
    rm -f "$LARES_FAKE/pacman/db.lck"
    check "stale: a dead session's record is cleared by the next command, which says so" bash -c 'grep -aq "EARLIER SESSION is still recorded" "$1"' _ "$OUT/last.out"
    check "stale: start waited for the package transaction (START_WAIT), then started anyway (exit 0)" bash -c '
        [ "$1" -eq 0 ] && grep -aq "the shell starts when it is over" "$2" && grep -aq "starting anyway" "$2"' _ "$RC" "$OUT/last.out"
    check "stale: ... up, and the record names this session" bash -c '[ "$(jq -r .session.sig "$1/deployed")" = fakesig ]' _ "$RUN"
    waitfor 5 deployed_up
}

log_is_small() { [ "$(stat -c %s "$RUN/shell.log")" -lt 20000 ]; }
sc_logcap() {
    note "logcap: a shell that floods its log cannot fill the runtime tmpfs"
    local sp; sp=$(sup_pid)
    kill -TERM "$sp"; waitfor 10 gone "$sp"
    LARES_LOG_MAX=20000 LARES_LOGCAP_EVERY=1 T start
    check "logcap: start" rc_is 0
    head -c 80000 /dev/zero | tr '\0' x >> "$RUN/shell.log"
    check "logcap: the supervisor cut the log to a tenth of its cap, and said so" bash -c 'waitfor() { local i; for (( i = 0; i < 160; i++ )); do [ "$(stat -c %s "$1")" -lt 20000 ] && return 0; sleep 0.05; done; return 1; }
        waitfor "$1/shell.log" && grep -aq "shell.log was" "$1/supervise.log"' _ "$RUN"
}

# ---- binds -------------------------------------------------------------------------------------------------------
binds_row() { grep -aE "^  $1 +$2( |$)" "$OUT/last.out"; }   # binds_row <status> <label regexp>
sc_binds() {
    note "binds: the config's lines against what the shell needs"
    local f=$KB
    cp -p "$f" "$OUT/kb.bak"; cp -p "$HYPR/config/autostart.lua" "$OUT/au.bak"; cp -p "$HYPR/config/layerrules.lua" "$OUT/lr.bak"; cp -p "$HYPR/config/environment.lua" "$OUT/env.bak"
    T binds
    check "binds: a bind running a command that is gone is STALE (the panic line runs lares fallback; the shell's line runs restart)" bash -c '
        grep -aE "^  STALE +SUPER \+ SHIFT \+ F12 " "$1" | grep -aq "lares fallback.*which is gone" && grep -aqF "hl.bind(\"SUPER + SHIFT + F12\", hl.dsp.exec_cmd(\"$2/current/tools/shell/lares restart\"))" "$1"' \
        _ "$OUT/last.out" "$DDIR"
    check "binds: today's Caps_Lock / Num_Lock lines are STALE (a bare lock key never fires on Hyprland 0.57) and the shell's two MISSING" bash -c '
        grep -aE "^  STALE +Caps_Lock " "$1" | grep -aq "never fires on Hyprland 0.57" && grep -aE "^  STALE +Num_Lock " "$1" | grep -aq "never fires" &&
        grep -aqE "^  MISSING +CAPS \+ Caps_Lock " "$1" && grep -aqE "^  MISSING +MOD2 \+ Num_Lock " "$1"' _ "$OUT/last.out"
    check "binds: everything else of today's config is ok (25 keys, 5 layer rules, the environment line, 4 autostart lines), exit 1 for the rest" bash -c '
        [ "$1" -eq 1 ] && [ "$(grep -acE "^  ok " "$2")" -eq 35 ] && grep -aq "^3 MISSING, 0 CONFLICT, 0 DIFFERS, 3 STALE -- nothing was written" "$2"' _ "$RC" "$OUT/last.out"
    check "binds: a config from before Panorama is MISSING its line, and the row names the one-time import" bash -c '
        grep -aE "^  MISSING +panorama " "$1" | grep -aq "lares panorama-import"' _ "$OUT/last.out"
    check "binds: the autostart's geoclue line is a note (lares start starts the agent too)" bash -c 'grep -aE "^  note +exec_cmd " "$1" | grep -aq "geoclue agent"' _ "$OUT/last.out"
    # faults made on purpose
    sed -i '/^hl.bind("ALT + N",/d' "$f"
    sed -i 's|^hl.bind("ALT + V", .*|hl.bind("ALT + V",              hl.dsp.exec_cmd("cliphist list \| wofi --dmenu"))|' "$f"
    sed -i 's|^\(hl.bind("XF86AudioMute",.*"lares:osd-volume-mute")\), { locked = true })|\1)|' "$f"
    sed -i 's|^hl.bind("SUPER + SHIFT + S",|hl.bind("SHIFT + SUPER + S",|' "$f"
    sed -i 's|^hl.bind("SUPER + F2", *hl.dsp.global("lares:bars"))|hl.bind("SUPER + F2",\n    hl.dsp.global("lares:bars"))|' "$f"
    printf 'hl.bind("SUPER + B", hl.dsp.global("lares:oldname"))\nhl.bind("SUPER + G", hl.dsp.exec_cmd("%s/current/tools/osd/nothere.sh"))\n' "$DDIR" >> "$f"
    sed -i '/lares start")$/d' "$HYPR/config/autostart.lua"
    sed -i '/lares_toast_pill_noanim/d' "$HYPR/config/layerrules.lua"
    sed -i 's|^hl.env("QS_CONFIG_PATH", .*|hl.env("QS_CONFIG_PATH", "/somewhere/else/shell.qml")|' "$HYPR/config/environment.lua"
    home_hash > "$OUT/home.binds"
    T binds
    check "binds: a key the config lacks is MISSING, with the line to add (ALT + N)" bash -c 'binds_row(){ grep -aE "^  $1 +$2( |$)" "$3"; }; binds_row MISSING "ALT \+ N" "$1" > /dev/null && grep -aqF "hl.bind(\"ALT + N\", hl.dsp.global(\"lares:notes\"))" "$1"' _ "$OUT/last.out"
    check "binds: a key bound to something else is a CONFLICT (ALT + V)" bash -c 'grep -aE "^  CONFLICT +ALT \+ V " "$1" | grep -aq "cliphist"' _ "$OUT/last.out"
    check "binds: a volume key without { locked = true } DIFFERS" bash -c 'grep -aE "^  DIFFERS +XF86AudioMute " "$1" | grep -aq "locked"' _ "$OUT/last.out"
    check "binds: a global the shell does not have is STALE (SUPER + B), so is a path the snapshot does not have (SUPER + G)" bash -c '
        grep -aE "^  STALE +SUPER \+ B " "$1" | grep -aq "lares:oldname, a global the shell does not have" && grep -aE "^  STALE +SUPER \+ G " "$1" | grep -aq "the deployed snapshot does not have"' _ "$OUT/last.out"
    check "binds: keys spelled in another order, a bind over two lines: ok (SUPER + SHIFT + S, SUPER + F2)" bash -c '
        grep -aqE "^  ok +SUPER \+ SHIFT \+ S " "$1" && grep -aqE "^  ok +SUPER \+ F2 " "$1"' _ "$OUT/last.out"
    check "binds: the autostart's lares start, a layer rule, the environment line: MISSING / MISSING / DIFFERS" bash -c '
        grep -aqE "^  MISSING +the shell " "$1" && grep -aqE "^  MISSING +lares_toast_pill_noanim " "$1" && grep -aqE "^  DIFFERS +QS_CONFIG_PATH " "$1"' _ "$OUT/last.out"
    check "binds: the tally (6 MISSING, 1 CONFLICT, 2 DIFFERS, 5 STALE: today's two lock-key lines and Panorama's in it), exit 1, nothing written" bash -c '
        [ "$1" -eq 1 ] && grep -aq "^6 MISSING, 1 CONFLICT, 2 DIFFERS, 5 STALE -- nothing was written" "$2" && diff <(home_hash) "$3" > /dev/null' _ "$RC" "$OUT/last.out" "$OUT/home.binds"
    # all mended, the panic line the shell's
    cp -p "$OUT/kb.bak" "$f"; cp -p "$OUT/au.bak" "$HYPR/config/autostart.lua"; cp -p "$OUT/lr.bak" "$HYPR/config/layerrules.lua"; cp -p "$OUT/env.bak" "$HYPR/config/environment.lua"
    sed -i "s|^hl.bind(\"SUPER + SHIFT + F12\", .*|hl.bind(\"SUPER + SHIFT + F12\",  hl.dsp.exec_cmd(\"'$DDIR/current/tools/shell/lares' restart\"))|" "$f"
    sed -i -e 's|^hl.bind("Caps_Lock", |hl.bind("CAPS + Caps_Lock", |' -e 's|^hl.bind("Num_Lock", |hl.bind("MOD2 + Num_Lock", |' "$f"
    # and the displays Panorama's, as `lares panorama-import` leaves them: one line requires the generated file, which is there
    printf 'pcall(require, "config/panorama")\n' > "$HYPR/hyprland.lua"; : > "$HYPR/config/panorama.lua"
    T binds
    check "binds: with the panic line on lares restart (quoted or not), nothing to change: exit 0" bash -c '[ "$1" -eq 0 ] && grep -aq "^0 MISSING, 0 CONFLICT, 0 DIFFERS, 0 STALE" "$2"' _ "$RC" "$OUT/last.out"
    T setup   # its one line on the config
    check "binds: setup's summary of the config agrees" bash -c 'grep -aE "^  ok +the shell.s lines" "$1" | grep -aq "every line the shell needs"' _ "$OUT/last.out"
    home_hash > "$OUT/home.pristine"   # the mended panic line is the home from here on
}

# ---- setup -------------------------------------------------------------------------------------------------------
root_cmds() {   # root_cmds make|undo <setup output>: the printed command lines of that half, made to run on the fake root (sudo dropped)
    awk -v want="$1" '
        /^R[567]  / { half = ""; next }   # R5 (snapshots), R6 (the boost) and R7 (the udev rule of a DisplayLink dock, only where evdi is loaded) have checks of their own or need the real udev
        /^R[0-9]  / { half = "make"; next }
        /^    undo:/ { half = "undo"; next }
        /^If the first boot/ { half = "" }
        half == want && /^      (sudo |grep |sed )/ { sub(/^      /, ""); print }' "$2" \
        | sed -e 's/\(^\|[|&;] *\)sudo /\1/g' -e "s| /etc/| ${RROOT:-$W/root}/etc/|g" -e "s| /usr/local/| ${RROOT:-$W/root}/usr/local/|g" -e "s| /usr/share/| ${RROOT:-$W/root}/usr/share/|g"
}
run_root_cmds() {   # run_root_cmds <file>: each line through bash -- never one that still says sudo, or names a real /etc or /usr/local path
    local c
    while IFS= read -r c; do
        if [[ $c == *sudo* ]] || [[ $c =~ (^|[[:space:]])/(etc|usr/local|usr/share)/ ]]; then echo "      (refused to run: $c)" >&2; echo "REFUSED $c" >> "$OUT/root.refused"; continue; fi
        bash -c "$c" > /dev/null 2>&1
    done < "$1"
}
sc_setup() {
    note "setup: every check; the root steps run AS PRINTED (sudo dropped; /etc and /usr/local moved into the fake root)"
    T setup
    cp "$OUT/last.out" "$OUT/setup.out"
    # on a terminal the commands you type are coloured, and nothing else changes (tools/dev/fixtures/lares/setup_colour_check.py)
    TERM=xterm-256color timeout 120 script -qec "$REPO/tools/shell/lares setup" /dev/null > "$OUT/setup.tty" 2>&1 < /dev/null
    check "setup on a terminal: the commands are coloured, nothing else, and the text is the file's" python3 -B "$FIX/setup_colour_check.py" "$OUT/setup.tty" "$OUT/setup.out"
    check "setup: exit 1 with the root steps, and the mako D-Bus could start, to do; the snapshots, programs and hypridle ok" bash -c '
        [ "$1" -eq 1 ] && grep -aqE "^  TO DO +R1 the boot lock" "$2" && grep -aqE "^  TO DO +R2 PAM \+ keyring" "$2" &&
        grep -aE "^  TO DO +D-Bus activation" "$2" | grep -aq "systemctl --user mask mako.service" &&
        grep -aqE "^  ok +the shell " "$2" && grep -aqE "^  ok +the lock " "$2" && grep -aqE "^  ok +programs " "$2" && grep -aqE "^  ok +hypridle " "$2"' _ "$RC" "$OUT/setup.out"
    check "setup: the portal units that are installed (not the termfilechooser's) are TO DO, and the printed line writes a drop-in for each" bash -c '
        grep -aE "^  TO DO +portals in a session" "$1" | grep -aq "xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-hyprland: " &&
        ! grep -aE "^  TO DO +portals in a session" "$1" | grep -aq termfilechooser && grep -aq "^ *for u in xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-hyprland; do " "$1"' _ "$OUT/setup.out"
    grep -a "^ *for u in xdg-desktop-portal " "$OUT/setup.out" | sed 's/^ *//' > "$OUT/portal.do"
    root_cmds make "$OUT/setup.out" > "$OUT/root.do"; root_cmds undo "$OUT/setup.out" > "$OUT/root.undo"
    check "setup: the printed steps hold 5 commands to make them (R1: 2, R2: the PAM copy and the keyring 3) and 4 to undo them" bash -c '[ "$(wc -l < "$1")" -eq 5 ] && [ "$(wc -l < "$2")" -eq 4 ]' _ "$OUT/root.do" "$OUT/root.undo"
    rm -f "$OUT/root.refused"
    run_root_cmds "$OUT/root.do"
    run_root_cmds "$OUT/root.do"   # twice: each is safe to run again
    check "setup: every printed command could be moved to the fake root (no sudo left, no real path)" test ! -e "$OUT/root.refused"
    check "setup: the autologin session is hyprland-lares; the keyring line is in lares-lock ONCE, right after pam_unix.so" bash -c '
        grep -qx "Session=hyprland-lares" "$1" && [ "$(grep -c pam_gnome_keyring "$2")" -eq 1 ] && grep -A1 "pam_unix.so" "$2" | grep -q "^auth  *optional  *pam_gnome_keyring.so$"' \
        _ "$W/root/etc/sddm.conf.d/autologin.conf" "$W/root/etc/pam.d/lares-lock"
    check "setup: the installed session file and wrapper are the snapshot's, executable" bash -c '
        [ -x "$1/usr/local/bin/lares-boot-lock" ] && cmp -s "$1/usr/local/bin/lares-boot-lock" "$2/current/tools/shell/root/lares-boot-lock" && cmp -s "$1/usr/local/share/wayland-sessions/hyprland-lares.desktop" "$2/current/tools/shell/root/hyprland-lares.desktop"' \
        _ "$W/root" "$DDIR"
    systemctl --user mask mako.service > /dev/null
    bash "$OUT/portal.do" > /dev/null 2>&1   # the printed drop-in line, as printed: it writes under the fake home's .config/systemd only
    check "setup: the printed line wrote session.conf (Requisite=graphical-session.target) for each of the three units, and nothing else" bash -c '
        n=0; for u in xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-hyprland; do
            [ "$(cat "$1/$u.service.d/session.conf" 2> /dev/null)" = "$(printf "[Unit]\nRequisite=graphical-session.target")" ] && n=$((n + 1)); done
        [ "$n" -eq 3 ] && [ "$(find "$1" -name "*.conf" | wc -l)" -eq 3 ]' _ "$HOME/.config/systemd/user"
    check "setup: folders open in a desktop file that is not lares-yazi.desktop: TO DO, with ONE printed line joined by && (copy from the snapshot, then xdg-mime default)" bash -c '
        grep -aqE "^  TO DO +folders open in" "$1" && [ "$(grep -ac "xdg-mime default lares-yazi.desktop inode/directory" "$1")" -eq 1 ] &&
        grep -a "xdg-mime default lares-yazi.desktop" "$1" | grep -aqE "^ *mkdir -p [^ ]+ [^ ]+ && cp $2/current/tools/shell/applications/lares-yazi.desktop [^ ]+ && xdg-mime default lares-yazi.desktop inode/directory$"' _ "$OUT/setup.out" "$DDIR"
    grep -a "xdg-mime default lares-yazi.desktop" "$OUT/setup.out" | sed 's/^ *//' > "$OUT/opener.do"
    bash "$OUT/opener.do" > /dev/null 2>&1   # the printed line, as printed: it writes under the fake home's .local/share and .config only
    check "setup: the printed line COPIED the desktop file (not a link, the snapshot's bytes) and made it the folder default" bash -c '
        f="$1/.local/share/applications/lares-yazi.desktop"; [ -f "$f" ] && [ ! -L "$f" ] && cmp -s "$f" "$2/current/tools/shell/applications/lares-yazi.desktop" &&
        [ "$(xdg-mime query default inode/directory)" = lares-yazi.desktop ]' _ "$HOME" "$DDIR"
    bash "$OUT/opener.do" > /dev/null 2>&1   # twice: safe to run again
    T setup
    check "setup: after the printed line the folders row is ok" bash -c 'grep -aqE "^  ok +folders open in" "$1" && ! grep -aqE "^  TO DO +folders open in" "$1"' _ "$OUT/last.out"
    check "setup: with no lares in ~/.local/bin and no screentimed, both are TO DO, each with the line that makes it" bash -c '
        grep -aE "^  TO DO +the command " "$1" | grep -aqF "ln -s $2/tools/shell/lares" && grep -aE "^  TO DO +screen time " "$1" | grep -aqF "cargo build --release && ./install.sh"' _ "$OUT/last.out" "$REPO"
    mkdir -p "$HOME/.local/bin"; ln -s "$REPO/tools/shell/lares" "$HOME/.local/bin/lares"; printf '#!/bin/sh\n' > "$HOME/.local/bin/screentimed"; chmod +x "$HOME/.local/bin/screentimed"
    T setup
    check "setup: with the steps run, the drop-ins written and mako masked, everything is in place (exit 0)" bash -c '
        [ "$1" -eq 0 ] && grep -aqE "^  ok +R1 the boot lock" "$2" && grep -aqE "^  ok +R2 PAM \+ keyring" "$2" && grep -aqE "^  ok +D-Bus activation" "$2" && grep -aqE "^  ok +portals in a session" "$2" && grep -aq "everything is in place" "$2"' _ "$RC" "$OUT/last.out"
    run_root_cmds "$OUT/root.undo"
    check "setup: the printed undo puts /etc back byte for byte and removes what was installed" bash -c '
        diff -r "$1/etc" "$2/etc" > /dev/null && [ ! -e "$2/usr/local/bin/lares-boot-lock" ] && [ ! -e "$2/usr/local/share/wayland-sessions/hyprland-lares.desktop" ]' _ "$FIXD/root" "$W/root"
    systemctl --user unmask mako.service > /dev/null
    rm -rf "$HOME/.config/systemd/user/"xdg-desktop-portal*.service.d   # the drop-ins were the probe's run of the printed line, not setup's
    rm -f "$HOME/.local/share/applications/lares-yazi.desktop" "$HOME/.config/mimeapps.list"   # the probe's run of the printed folder line, not setup's
    rm -f "$HOME/.local/bin/lares" "$HOME/.local/bin/screentimed"
    check "setup: nothing of the home was written by it" home_same_as "$OUT/home.pristine"
}

# ---- boost (R6) ---------------------------------------------------------------------------------------------------
step_cmds() {   # step_cmds <R-step> make|undo <setup output>: that one step's printed command lines, made to run on the fake root (as root_cmds)
    awk -v step="$1" -v want="$2" '
        /^R[0-9]  / { half = ($1 == step) ? "make" : ""; next }
        /^    undo/ { if (half != "") half = "undo"; next }
        half == want && /^      (sudo |grep |sed )/ { sub(/^      /, ""); print }' "$3" \
        | sed -e 's/\(^\|[|&;] *\)sudo /\1/g' -e "s| /etc/| $W/root/etc/|g" -e "s| /usr/local/| $W/root/usr/local/|g" -e "s| /usr/share/| $W/root/usr/share/|g"
}
boost_helper() {   # boost_helper new|old|gone: a stand-in for the installed silicon-helper in the fake root (only `capabilities` is asked)
    local f=$W/root/usr/local/libexec/silicon-helper verbs='"status","wifi-powersave","capabilities"'
    case $1 in
        gone) rm -f "$f"; rmdir "${f%/*}" 2> /dev/null || true; return ;;
        new) verbs="$verbs"',"boost-serve","boost-restore"' ;;
    esac
    mkdir -p "${f%/*}"
    printf '#!/bin/sh\n[ "$1" = capabilities ] && echo '"'"'{"ok":true,"proto":1,"verbs":[%s]}'"'"' && exit 0\nexit 2\n' "$verbs" > "$f"; chmod +x "$f"
}
sc_boost() {
    note "boost: R6, the interaction boost's unit, printed and run AS PRINTED on the fake root"
    local sj=$HOME/.config/quickshell/config/silicon.jsonc unit=$W/root/etc/systemd/system/lares-boost.service had_dir=1
    [ -d "${sj%/*}" ] || had_dir=0
    mkdir -p "$W/root/etc/systemd/system"   # every systemd machine has it
    cp -a "$W/root/etc" "$OUT/etc.before"
    T setup
    check "boost: with no silicon helper installed, R6 is no TO DO and no step is printed" bash -c '
        grep -aqE "^  - +R6 interaction boost +silicon.s helper is not installed" "$1" && ! grep -aq "^R6  " "$1"' _ "$OUT/last.out"
    boost_helper new
    T setup
    cp "$OUT/last.out" "$OUT/boost1.out"
    check "boost: a helper with boost-serve and no unit: R6 is optional (-) while silicon.jsonc does not ask, and its step is printed" bash -c '
        grep -aqE "^  - +R6 interaction boost +not installed" "$1" && grep -aq "^R6  THE INTERACTION BOOST" "$1" && ! sed -n "/^R6  /,\$p" "$1" | grep -aq "cargo build"' _ "$OUT/boost1.out"
    mkdir -p "${sj%/*}"; printf '// the probe asks for the boost\n{ "interactionBoost": true }\n' > "$sj"
    T setup
    cp "$OUT/last.out" "$OUT/boost2.out"
    check "boost: silicon.jsonc asks (interactionBoost: true): R6 is TO DO" grep -aqE "^  TO DO +R6 interaction boost" "$OUT/boost2.out"
    step_cmds R6 make "$OUT/boost2.out" > "$OUT/boost.do"; step_cmds R6 undo "$OUT/boost2.out" > "$OUT/boost.undo"
    check "boost: the step holds 2 commands to make it (the unit, systemctl) and 2 to undo it" bash -c '[ "$(wc -l < "$1")" -eq 2 ] && [ "$(wc -l < "$2")" -eq 2 ]' _ "$OUT/boost.do" "$OUT/boost.undo"
    rm -f "$OUT/root.refused"
    cp "$LARES_FAKE/stub.log" "$OUT/stub.before" 2> /dev/null || : > "$OUT/stub.before"
    run_root_cmds "$OUT/boost.do"
    run_root_cmds "$OUT/boost.do"   # twice: safe to run again
    check "boost: every printed command could be moved to the fake root (no sudo left, no real path)" test ! -e "$OUT/root.refused"
    check "boost: the unit is the deployed snapshot's template with YOUR uid in it, and systemctl was asked to reload and enable it" bash -c '
        [ -f "$1" ] && diff <(sed "s/@UID@/$(id -u)/" "$2/current/tools/shell/root/lares-boost.service.in") "$1" > /dev/null &&
        grep -q "^ExecStart=/usr/local/libexec/silicon-helper boost-serve uid=$(id -u) " "$1" &&
        diff "$3" "$4" | grep -aq "SYSTEMCTL daemon-reload" && diff "$3" "$4" | grep -aq "SYSTEMCTL enable --now lares-boost.service"' \
        _ "$unit" "$DDIR" "$OUT/stub.before" "$LARES_FAKE/stub.log"
    T setup
    check "boost: with the step run, R6 is ok and its step is no longer printed" bash -c '
        grep -aqE "^  ok +R6 interaction boost +installed" "$1" && ! grep -aq "^R6  " "$1"' _ "$OUT/last.out"
    sed -i "s/boost-serve uid=$(id -u) /boost-serve uid=4242 /" "$unit"
    T setup
    check "boost: R6: a unit written for another uid is TO DO, and the step is printed again" bash -c '
        grep -aqE "^  TO DO +R6 interaction boost .*another uid" "$1" && grep -aq "^R6  THE INTERACTION BOOST" "$1"' _ "$OUT/last.out"
    run_root_cmds "$OUT/boost.undo"
    check "boost: the printed undo takes the unit out: /etc is back byte for byte" bash -c '[ ! -e "$1" ] && diff -r "$2" "$3/etc" > /dev/null' _ "$unit" "$OUT/etc.before" "$W/root"
    boost_helper old
    T setup
    check "boost: an installed helper without boost-serve: the step starts with the rebuild of the helper (TO DO: silicon.jsonc asks)" bash -c '
        grep -aqE "^  TO DO +R6 interaction boost +the installed helper predates boost-serve" "$1" && sed -n "/^R6  /,\$p" "$1" | grep -aq "cargo build --release) && sudo .*/install.sh"' _ "$OUT/last.out"
    boost_helper gone; rm -f "$sj"; [ "$had_dir" = 1 ] || rmdir "${sj%/*}" 2> /dev/null || true
}

# ---- cleanup-marks -------------------------------------------------------------------------------------------------
MARKED=".config/hypr/config/autostart.lua .config/hypr/config/layerrules.lua .config/hypr/config/windowrules.lua .config/hypr/config/environment.lua
.config/hypr/hypridle.conf .local/bin/hyprlock .config/hypr/scripts/hyproled/hyproled-toggle.sh .config/quickshell/llm.jsonc"
CZTMPL=.local/share/chezmoi/dot_config/hypr/executable_hypridle.conf.tmpl   # marked too, and left alone: chezmoi is not used
c_keeps_user() {   # every line that is no mark stays, in order; only marks, commented-out lines and the blank runs they leave go
    python3 - "$OUT/pre" "$HOME" $MARKED << 'PY'
import re, sys
pre, home, files = sys.argv[1], sys.argv[2], sys.argv[3:]
mark = re.compile(r"^\s*(--|#|//) qs-shell deploy( BEGIN | END |:)")
def squeeze(lines):
    out = []
    for l in lines:
        if l.strip() == "" and out and out[-1].strip() == "":
            continue
        out.append(l)
    return out
bad = 0
for f in files:
    old = open(pre + "/" + f).read().split("\n")
    new = open(home + "/" + f).read().split("\n")
    want = squeeze([l for l in old if not mark.match(l)])
    if squeeze(new) != want or any(mark.match(l) for l in new):
        print("      (%s: the cleaned file is not the old one less its marks)" % f, file=sys.stderr)
        bad += 1
    if sum(1 for l in new if l.strip()) != sum(1 for l in old if l.strip() and not mark.match(l)):
        print("      (%s: a line that is no mark is gone)" % f, file=sys.stderr)
        bad += 1
sys.exit(1 if bad else 0)
PY
}
cleanup_answer_after_change() {   # the plan shown, then a file changes, then the yes
    rm -f "$OUT/ans"; mkfifo "$OUT/ans"
    ( timeout 120 "$REPO/tools/shell/lares" cleanup-marks < "$OUT/ans" > "$OUT/last.out" 2>&1; echo $? > "$OUT/cm.rc" ) &
    exec 7> "$OUT/ans"
    waitfor 60 grep -aq "Type yes" "$OUT/last.out"
    printf '\n-- touched while the plan was shown\n' >> "$HYPR/config/layerrules.lua"
    echo yes >&7
    exec 7>&-
    wait
    RC=$(cat "$OUT/cm.rc")
}
sc_cleanup() {
    note "cleanup: the marks of an earlier deploy, taken out once"
    local f before
    rm -rf "$OUT/pre"; mkdir -p "$OUT/pre"
    for f in $MARKED .config/hypr/config/keybinds.lua $CZTMPL; do mkdir -p "$OUT/pre/${f%/*}"; cp -p "$HOME/$f" "$OUT/pre/$f"; done
    before=$(home_hash)
    T cleanup-marks --dry-run
    check "cleanup: a dry run plans the eight marked files, leaves chezmoi's source alone, plans the record's move, and changes nothing" bash -c '
        [ "$1" -eq 0 ] && [ "$(grep -ac "^WILL CLEAN " "$2")" -eq 8 ] && grep -aq "^clean       .*keybinds.lua" "$2" &&
        grep -aq "^left alone  .*executable_hypridle.conf.tmpl (chezmoi.s source: chezmoi is not used)" "$2" &&
        grep -aq "^WILL MOVE .*lares/tool/deploy (deploy.s record" "$2" && grep -aq "^WILL MOVE .*last-trial" "$2" && grep -aq "^WILL REMOVE .*first-trial-done" "$2" &&
        grep -aq "^nothing was changed" "$2" && [ "$(home_hash)" = "$3" ] && [ -e "$4/record.json" ]' _ "$RC" "$OUT/last.out" "$before" "$DSTATE"
    check "cleanup: the plan shows the diff (a BEGIN mark and a commented-out line going; no diff of chezmoi's template)" bash -c '
        grep -aq "^-    -- qs-shell deploy BEGIN autostart" "$1" && grep -aq "^-    # qs-shell deploy: lock_cmd = pidof hyprlock" "$1" && ! grep -aq "^--- .*executable_hypridle.conf.tmpl" "$1"' _ "$OUT/last.out"
    Ty no cleanup-marks
    check "cleanup: a no writes nothing (exit 1)" bash -c '[ "$1" -eq 1 ] && grep -aq "nothing was written" "$2" && [ "$(home_hash)" = "$3" ] && [ -e "$4/record.json" ]' _ "$RC" "$OUT/last.out" "$before" "$DSTATE"
    cp -p "$HYPR/config/environment.lua" "$OUT/env.keep"
    printf -- '-- qs-shell deploy BEGIN stray: a block left open\nhl.env("X", "1")\n' >> "$HYPR/config/environment.lua"
    T cleanup-marks --dry-run
    check "cleanup: a block that never ends REFUSES the run, nothing written" bash -c '[ "$1" -eq 1 ] && grep -aq "REFUSED: .*environment.lua: block stray (line [0-9]*) never ends" "$2"' _ "$RC" "$OUT/last.out"
    cp -p "$OUT/env.keep" "$HYPR/config/environment.lua"
    mv "$HOME/.local/bin/hyprlock" "$OUT/hyprlock.keep"; cp -p "$OUT/hyprlock.keep" "$OUT/hyprlock.target"; ln -s "$OUT/hyprlock.target" "$HOME/.local/bin/hyprlock"
    T cleanup-marks --dry-run
    check "cleanup: a marked file that is a symlink REFUSES the run" bash -c '[ "$1" -eq 1 ] && grep -aq "REFUSED: .*hyprlock is a symlink" "$2"' _ "$RC" "$OUT/last.out"
    rm -f "$HOME/.local/bin/hyprlock"; mv "$OUT/hyprlock.keep" "$HOME/.local/bin/hyprlock"
    cp -p "$HYPR/config/layerrules.lua" "$OUT/lr.keep"
    cleanup_answer_after_change
    check "cleanup: a file changed while the plan was shown REFUSES after the yes, and nothing is written" bash -c '
        [ "$1" -eq 1 ] && grep -aq "REFUSED: .*layerrules.lua changed while the plan was shown" "$2" &&
        diff <(home_hash | grep -v layerrules.lua) <(grep -v layerrules.lua <<< "$3") > /dev/null && [ -e "$4/record.json" ]' _ "$RC" "$OUT/last.out" "$before" "$DSTATE"
    cp -p "$OUT/lr.keep" "$HYPR/config/layerrules.lua"
    Ty yes cleanup-marks; cp "$OUT/last.out" "$OUT/yes.out"
    check "cleanup: a yes writes (exit 0, each file said)" bash -c '[ "$1" -eq 0 ] && [ "$(grep -ac "^written " "$2")" -eq 8 ]' _ "$RC" "$OUT/last.out"
    check "cleanup: every line you wrote and every shell line stays; only the marks, the commented-out lines and their blank runs go" c_keeps_user
    check "cleanup: no file holds a mark; keybinds.lua (no marks) is untouched; the shell's lines are plain lines now" bash -c '
        ! grep -rq "qs-shell deploy" "$1/.config/hypr" "$1/.local/bin" "$1/.config/quickshell" && cmp -s "$2/.config/hypr/config/keybinds.lua" "$1/.config/hypr/config/keybinds.lua" &&
        grep -aqx "    hl.exec_cmd(\"$3/current/tools/shell/lares start\")" "$1/.config/hypr/config/autostart.lua" && grep -aq "^    lock_cmd = .*lares-lock-session$" "$1/.config/hypr/hypridle.conf"' \
        _ "$HOME" "$OUT/pre" "$DDIR"
    check "cleanup: chezmoi's source is left alone, byte for byte (its marks too: chezmoi is not used)" bash -c '
        cmp -s "$1/.local/share/chezmoi/dot_config/hypr/executable_hypridle.conf.tmpl" "$2/.local/share/chezmoi/dot_config/hypr/executable_hypridle.conf.tmpl" &&
        grep -q "qs-shell deploy" "$1/.local/share/chezmoi/dot_config/hypr/executable_hypridle.conf.tmpl"' _ "$HOME" "$OUT/pre"
    check "cleanup: each file keeps its mode (hypridle.conf, the hyprlock wrapper and hyproled executable)" bash -c '
        for f in .config/hypr/hypridle.conf .local/bin/hyprlock .config/hypr/scripts/hyproled/hyproled-toggle.sh .config/hypr/config/autostart.lua; do
            [ "$(stat -c %a "$1/$f")" = "$(stat -c %a "$2/$f")" ] || exit 1; done' _ "$HOME" "$OUT/pre"
    check "cleanup: deploy's record and the originals, and the trial's logs, are in deploy-archive-<date>/; the record dir and the marker are gone" bash -c '
        a=$1/deploy-archive-$(date +%F); [ -e "$a/record.json" ] && [ -e "$a/deploy.json" ] && [ -e "$a/originals/000-autostart.lua" ] && [ -e "$a/last-trial/shell.log" ] &&
        [ ! -e "$1/deploy" ] && [ ! -e "$1/first-trial-done" ] && [ ! -e "$1/last-trial" ]' _ "$PERSIST"
    T cleanup-marks
    check "cleanup: a second run has nothing to do (exit 0)" bash -c '[ "$1" -eq 0 ] && grep -aq "nothing to clean up" "$2"' _ "$RC" "$OUT/last.out"
}

# ---- the name change (THE NAME CHANGE in tools/shell/lares) ------------------------------------------------------------
# A SECOND WORLD, `$W/nw`, laid out as the user's machine is TODAY: our state / cache / data under the Quickshell names, a deployed shell of
# the OLD name running under a supervisor of the OLD name (the real old scripts, tools/dev/fixtures/lares/old/), the user's lines (the old-name
# fixtures) and an old root. lares runs against it through N(): the repo's tool (the code under test, armed or not), this world's HOME.
NW=$W/nw
NHOME=$NW/home NRT=$NW/rt NROOT=$NW/root
NSTATE=$NHOME/.local/state NCACHE=$NHOME/.cache NDATA=$NHOME/.local/share
OLDSHA=1111111111111111111111111111111111111111
NRC=0
nenv() {
    env HOME="$NHOME" XDG_RUNTIME_DIR="$NRT" XDG_CONFIG_HOME="$NHOME/.config" XDG_STATE_HOME="$NSTATE" XDG_CACHE_HOME="$NCACHE" XDG_DATA_HOME="$NDATA" \
        LARES_ROOT_PREFIX="$NROOT" LARES_BIN_DIR="$NHOME/.local/bin" LARES_HYPRIDLE_CONF="$NHOME/.config/hypr/hypridle.conf" "$@"
}
N() {    # N <args...>: the repo's lares in the name world, stdin closed; output $OUT/n.out, status $NRC
    nenv timeout 120 "$REPO/tools/shell/lares" "$@" > "$OUT/n.out" 2>&1 < /dev/null
    NRC=$?
}
Ny() {   # Ny <answer> <args...>: the same with the answer typed
    local ans=$1; shift
    printf '%s\n' "$ans" | nenv timeout 120 "$REPO/tools/shell/lares" "$@" > "$OUT/n.out" 2>&1
    NRC=$?
}
nout_has() { grep -aqF -- "$1" "$OUT/n.out"; }
ntree() {   # every path of the name world's home and runtime dir with its type and link target: what a move could change
    ( cd "$NW" && find home rt -mindepth 1 -printf '%p %y %l\n' 2> /dev/null | LC_ALL=C sort )
}
nino() { stat -c '%i' -- "$1" 2> /dev/null; }

name_world_up() {
    local f d
    rm -rf "$NW"; mkdir -p "$NHOME" "$NRT" "$NROOT"; chmod 700 "$NRT"
    # the user's lines, as they are today (old names), and the old root
    for f in config/autostart.lua config/keybinds.lua config/layerrules.lua config/environment.lua hypridle.conf scripts/hyproled/hyproled-toggle.sh; do
        mkdir -p "$NHOME/.config/hypr/${f%/*}"; cp -p "$FIX/deploy_old/home/.config/hypr/$f" "$NHOME/.config/hypr/$f"
        sed -i "s|/home/user/|$NHOME/|g" "$NHOME/.config/hypr/$f"
    done
    cp -a "$FIX/deploy_old/root/." "$NROOT/"
    mkdir -p "$NHOME/.config/quickshell/config" "$NHOME/.config/theme"
    printf '{"fixture": "lockscreen"}\n' > "$NHOME/.config/quickshell/config/lockscreen.jsonc"
    # our state, cache and data under the OLD names, with something in each; and Quickshell's own beside them
    mkdir -p "$NSTATE/quickshell"/{notifications,llm,wiki/img,session,by-shell/abc} "$NCACHE/quickshell"/{wiki,stocks/charts,qmlcache,crashes,qtpipelinecache-abc,by-shell} \
        "$NDATA/quickshell"/{screentime/days/2026,stt/venv/bin,weather-accuracy,by-shell}
    printf '{"history": []}\n' > "$NSTATE/quickshell/notifications/history.json"
    printf '{"c": 1}\n' > "$NSTATE/quickshell/llm/conversations.json"
    printf '{"step": 3}\n' > "$NSTATE/quickshell/oled-shift.json"
    printf 'x\n' > "$NSTATE/quickshell/by-shell/abc/state"; printf 'x\n' > "$NCACHE/quickshell/qmlcache/q"; printf 'x\n' > "$NCACHE/quickshell/crashes/c1"
    # Qt's own caches beside them (the GL program binaries, Qt Quick Effects' shader builder) -- and two that round 9's first run moved:
    # one still behind our link, one whose link cleanup-old-name took (2026-11-15)
    mkdir -p "$NCACHE/quickshell"/{qtshadercache-abc,_qt_QGfxShaderBuilder_6.12.0} "$NCACHE/lares"/{qtshadercache-moved,_qt_QGfxShaderBuilder_6.11.0}
    printf 'x\n' > "$NCACHE/quickshell/qtshadercache-abc/b"; printf 'x\n' > "$NCACHE/quickshell/_qt_QGfxShaderBuilder_6.12.0/s"
    printf 'm\n' > "$NCACHE/lares/qtshadercache-moved/b"; printf 'm\n' > "$NCACHE/lares/_qt_QGfxShaderBuilder_6.11.0/s"
    ln -s "$NCACHE/lares/qtshadercache-moved" "$NCACHE/quickshell/qtshadercache-moved"
    printf '{"day": 1}\n' > "$NDATA/quickshell/screentime/days/2026/2026-11-14.json"
    printf 'cfg\n' > "$NDATA/quickshell/stt/venv/pyvenv.cfg"
    printf 'command = python -m venv %s/.local/share/quickshell/stt/venv\n' "$NHOME" > "$NDATA/quickshell/stt/venv/pyvenv.cfg"
    printf '#!%s/.local/share/quickshell/stt/venv/bin/python\nprint(1)\n' "$NHOME" > "$NDATA/quickshell/stt/venv/bin/pip"; chmod +x "$NDATA/quickshell/stt/venv/bin/pip"
    mkdir -p "$NSTATE/qs-shell"/{qmlls,deploy}; printf 'old log\n' > "$NSTATE/qs-shell/qs-shell.log"; : > "$NSTATE/qs-shell/lock"; printf '{}\n' > "$NSTATE/qs-shell/deploy/record.json"
    mkdir -p "$NCACHE/quickshell-stt"/{bin,uv-cache,models} "$NCACHE/quickshell-lock"
    printf '#!/bin/sh\necho qs-ime\n' > "$NCACHE/quickshell-stt/bin/qs-ime"; chmod +x "$NCACHE/quickshell-stt/bin/qs-ime"; printf 'm\n' > "$NCACHE/quickshell-stt/models/m.bin"
    printf 'stamp\n' > "$NCACHE/quickshell-lock/warm.stamp"
    mkdir -p "$NRT/qs-session/pending" "$NRT/quickshell/by-id/xyz"; printf 'mark\n' > "$NRT/qs-session/pending/tok"
    mkdir -p "$NHOME/.local/bin"; ln -s "$REPO/tools/shell/qs-shell" "$NHOME/.local/bin/qs-shell"
    printf '[ -f ~/.local/state/quickshell/shell/current/tools/session/session-hook.bash ] && . ~/.local/state/quickshell/shell/current/tools/session/session-hook.bash\n' > "$NHOME/.bashrc"
    # the snapshots the OLD deploy made: the shell's (with the old supervisor) and the lock's (the old launchers)
    d=$NSTATE/quickshell/shell/$OLDSHA
    mkdir -p "$d/tools/shell" "$d/tools/osd"
    printf 'import Quickshell\nShellRoot {}\n' > "$d/shell.qml"; printf 'repo=%s\n' "$REPO" > "$d/.complete"
    cp "$FIX/old/qs-shell-supervise" "$FIX/old/qs-shell-lib.sh" "$d/tools/shell/"
    printf '#!/bin/sh\n# the old tool, as the old supervisor calls it (update-running): nothing runs\nexit 1\n' > "$d/tools/shell/qs-shell"; chmod +x "$d/tools/shell/qs-shell" "$d/tools/shell/qs-shell-supervise"
    ln -s "$OLDSHA" "$NSTATE/quickshell/shell/current"
    d=$NSTATE/quickshell/lock/$OLDSHA
    mkdir -p "$d/tools/lockscreen" "$d/lock" "$d/modules/lockscreen/lock"; : > "$d/.complete"
    for f in qs-lock-session qs-lock-held qs-lock-warm; do printf '#!/bin/sh\necho OLD-%s "$@"\n' "$f" > "$d/tools/lockscreen/$f"; chmod +x "$d/tools/lockscreen/$f"; done
    ln -s "$OLDSHA" "$NSTATE/quickshell/lock/current"
}

name_old_shell_up() {   # the deployed shell of the OLD name, under the real old supervisor, in this world's runtime dir
    local run=$NRT/qs-shell old=$NSTATE/quickshell/shell
    mkdir -p "$run"; chmod 700 "$run"
    printf 'QSSHELL\n' > "$LARES_FAKE/ctl/lares_ready_word"
    {
        printf 'RUN=%q\nPERSIST=%q\nTOOL=%q\nSHELL_QML=%q\nDEPLOY_DIR=%q\n' "$run" "$NSTATE/qs-shell" "$old/$OLDSHA/tools/shell/qs-shell" "$old/current/shell.qml" "$old"
        printf 'QUICKSHELL=%q\nHYPRCTL=%q\n' "$FIX/bin/quickshell" "$FIX/bin/hyprctl"
        printf 'RESTART_LIMIT=3\nRESTART_WINDOW=60\nBACKOFF=0.2\nSLOW_BACKOFF=1\nSLOW_MAX=2\nSTABLE=3\nSTOP_TIMEOUT=2\nLOG_MAX=104857600\nLOGCAP_EVERY=10\n'
        printf 'export HYPRLAND_INSTANCE_SIGNATURE=%q XDG_RUNTIME_DIR=%q WAYLAND_DISPLAY=%q HOME=%q PATH=%q\n' fakesig "$NRT" wayland-fake "$NHOME" "$PATH"
        printf 'export DBUS_SESSION_BUS_ADDRESS=%q\n' "$DBUS_SESSION_BUS_ADDRESS"
    } > "$run/supervise.env"
    ( setsid -f bash "$old/$OLDSHA/tools/shell/qs-shell-supervise" --run "$run" < /dev/null > /dev/null 2>&1 )
    waitfor 10 test -s "$run/pid" && waitfor 10 bash -c 'grep -aq "QSSHELL ready" "$1"' _ "$run/shell.log"
    local sp sh
    sp=$(cat "$run/supervise.pid" 2> /dev/null); sh=$(cat "$run/pid" 2> /dev/null)
    python3 - "$run/deployed" "$OLDSHA" "$sp" "$sh" << 'PY'
import json, sys
f, rev, sp, sh = sys.argv[1:5]
def start(p):
    s = open("/proc/%s/stat" % p).read()
    return s[s.rindex(")") + 2:].split()[19]
json.dump({"version": 1, "state": "running", "started": 0, "rev": rev, "supervisor_rev": rev,
           "session": {"sig": "fakesig", "wayland": "wayland-fake", "supervisor": {"pid": int(sp), "start": start(sp)}, "shell": {"pid": int(sh), "start": start(sh)}}}, open(f, "w"))
PY
}

main_world_down() {   # the first world's shell (earlier scenarios) must not hold the notification name: the old world's shell takes it
    local p
    [ -e "$RUN/supervise.pid" ] && { : > "$RUN/stop"; p=$(sup_pid); [ -n "$p" ] && kill -TERM "$p" 2> /dev/null; waitfor 15 bash -c '[ -z "$(cat "$1" 2> /dev/null)" ] || ! kill -0 "$(cat "$1")" 2> /dev/null' _ "$RUN/supervise.pid"; }
    p=$(shell_pid); [ -n "$p" ] && alive "$p" && kill -TERM "$p" 2> /dev/null
    waitfor 10 bash -c '[ -z "$1" ] || ! kill -0 "$1" 2> /dev/null' _ "$p"
    return 0
}

# the reader: asks every old path over and over, from before the move to after it, and counts each time one is missing (ENOENT / ELOOP)
reader_up() {
    cat > "$OUT/reader.py" << 'PY'
import os, sys, time
paths = sys.argv[3:]
stop, report = sys.argv[1], sys.argv[2]
n = bad = 0
first = ""
open(report + ".started", "w").close()
while not os.path.exists(stop):
    for p in paths:
        n += 1
        try:
            os.stat(p)
        except OSError as e:
            bad += 1
            first = first or "%s: %s" % (p, e)
open(report, "w").write("%d %d %s\n" % (n, bad, first))
PY
    rm -f "$OUT/reader.stop" "$OUT/reader.report" "$OUT/reader.report.started"
    ( setsid -f python3 "$OUT/reader.py" "$OUT/reader.stop" "$OUT/reader.report" \
        "$NSTATE/quickshell/shell/current/shell.qml" "$NSTATE/quickshell/lock/current/tools/lockscreen/qs-lock-session" "$NRT/qs-shell/pid" "$NRT/qs-shell/supervise.env" \
        "$NSTATE/quickshell/notifications/history.json" "$NSTATE/quickshell/llm/conversations.json" "$NSTATE/qs-shell/qs-shell.log" "$NDATA/quickshell/screentime/days/2026/2026-11-14.json" \
        "$NCACHE/quickshell-stt/models/m.bin" "$NRT/qs-session/pending/tok" < /dev/null > /dev/null 2>&1 )
    waitfor 5 test -e "$OUT/reader.report.started"
}
reader_down() { : > "$OUT/reader.stop"; waitfor 5 test -s "$OUT/reader.report"; cat "$OUT/reader.report" 2> /dev/null; }

sc_namemove() {
    note "namemove: migrate-name moves what is ours to its Lares name, in one exchange each, and the old paths never go missing"
    main_world_down
    name_world_up
    name_old_shell_up
    local sp sh pre post own_before own_after
    sp=$(cat "$NRT/qs-shell/supervise.pid"); sh=$(cat "$NRT/qs-shell/pid")
    check "namemove: the world is today's: a deployed shell of the OLD name under the old supervisor (qs-shell-supervise), snapshots under the Quickshell dirs" bash -c '
        kill -0 "$1" && kill -0 "$2" && tr "\0" " " < /proc/$1/cmdline | grep -q "qs-shell-supervise" && [ -d "$3/quickshell/shell/$4" ] && [ ! -e "$3/lares" ]' _ "$sp" "$sh" "$NSTATE" "$OLDSHA"
    N deploy
    check "namemove: deploy before migrate-name is REFUSED (exit 4), says why, and writes nothing" bash -c '
        [ "$1" -eq 4 ] && grep -aq "migrate-name. has not run" "$2" && grep -aq "state/quickshell/shell" "$2" && [ ! -e "$3/lares" ]' _ "$NRC" "$OUT/n.out" "$NSTATE"
    N deploy --dry-run
    check "namemove: deploy --dry-run says WOULD REFUSE (exit 4)" bash -c '[ "$1" -eq 4 ] && grep -aq "^WOULD REFUSE deploy: .*migrate-name" "$2"' _ "$NRC" "$OUT/n.out"
    check "namemove: Qt's shader caches are not ours: the refusal names neither qtshadercache-* nor _qt_*" bash -c '! grep -aE "qtshadercache|_qt_QGfx" "$1"' _ "$OUT/n.out"
    pre=$(ntree); own_before=$(for p in "$NSTATE/quickshell/by-shell/abc" "$NCACHE/quickshell/qmlcache" "$NCACHE/quickshell/crashes" "$NCACHE/quickshell/qtpipelinecache-abc" "$NCACHE/quickshell/qtshadercache-abc" "$NCACHE/quickshell/_qt_QGfxShaderBuilder_6.12.0" "$NDATA/quickshell/by-shell" "$NRT/quickshell/by-id/xyz"; do echo "$p $(nino "$p")"; done)
    N migrate-name --dry-run
    check "namemove: --dry-run lists every move and Quickshell's own dirs as untouched, and changes nothing (exit 0)" bash -c '
        [ "$1" -eq 0 ] && grep -aq "^WILL MOVE .*quickshell/shell  ->  .*lares/shell" "$2" && grep -aq "^WILL MOVE .*quickshell/lock  ->  .*lares/lock" "$2" && grep -aq "^WILL MOVE .*qs-shell  ->  .*lares/tool" "$2" &&
        grep -aq "^WILL MOVE .*quickshell-stt  ->  .*lares-stt" "$2" && grep -aq "^WILL MOVE .*/qs-shell  ->  .*/lares$" "$2" && grep -aq "^WILL MOVE .*oled-shift.json" "$2" &&
        grep -aq "^untouched   .*by-shell (Quickshell.s own)" "$2" && grep -aq "^untouched   .*qmlcache" "$2" && grep -aq "^untouched   .*qtpipelinecache-abc" "$2" && grep -aq "^untouched   .*crashes" "$2" &&
        grep -aq "^WILL LINK   .*lares" "$2" && grep -aq "^WILL REMOVE .*bin/qs-shell" "$2" && grep -aq "^WILL COPY   .*qs-ime" "$2" && grep -aq "^nothing was changed" "$2"' _ "$NRC" "$OUT/n.out"
    check "namemove: ... and nothing moved (the whole tree, byte for byte its listing)" test "$(ntree)" = "$pre"
    Ny no migrate-name
    check "namemove: a no moves nothing (exit 1)" bash -c '[ "$1" -eq 1 ] && grep -aq "nothing was moved" "$2"' _ "$NRC" "$OUT/n.out"
    check "namemove: ... the tree is as it was" test "$(ntree)" = "$pre"
    reader_up
    Ny yes migrate-name; cp "$OUT/n.out" "$OUT/migrate.out"
    post=$(reader_down)
    check "namemove: a yes moves them (exit 0), each said" bash -c '[ "$1" -eq 0 ] && [ "$(grep -ac "^moved " "$2")" -ge 14 ] && grep -aq "^linked      .*bin/lares" "$2" && grep -aq "^removed     .*bin/qs-shell" "$2" && grep -aq "^copied      .*qs-ime" "$2"' _ "$NRC" "$OUT/migrate.out"
    check "namemove: every old path is now a SYMLINK to its Lares name (state, cache, data, the tool dir, the dictation home) and the Lares name is the real directory" bash -c '
        h=$1; bad=0
        for p in .local/state/quickshell/shell:.local/state/lares/shell .local/state/quickshell/lock:.local/state/lares/lock .local/state/quickshell/notifications:.local/state/lares/notifications \
                 .local/state/quickshell/llm:.local/state/lares/llm .local/state/quickshell/wiki:.local/state/lares/wiki .local/state/quickshell/oled-shift.json:.local/state/lares/oled-shift.json \
                 .local/state/qs-shell:.local/state/lares/tool .cache/quickshell-stt:.cache/lares-stt .cache/quickshell-lock:.cache/lares-lock .cache/quickshell/wiki:.cache/lares/wiki \
                 .cache/quickshell/stocks:.cache/lares/stocks .local/share/quickshell/screentime:.local/share/lares/screentime .local/share/quickshell/stt:.local/share/lares/stt \
                 .local/share/quickshell/weather-accuracy:.local/share/lares/weather-accuracy; do
            o=$h/${p%%:*}; n=$h/${p##*:}
            if [ -L "$o" ] && [ "$(readlink "$o")" = "$n" ] && [ ! -L "$n" ] && [ -e "$n" ]; then :; else echo "      (not a link to its Lares name: $o)" >&2; bad=1; fi
        done
        [ "$bad" -eq 0 ]' _ "$NHOME"
    check "namemove: the runtime dirs moved too (qs-shell -> lares, qs-session -> lares-session) and the data is where it was (inodes, content)" bash -c '
        [ -L "$1/qs-shell" ] && [ "$(readlink "$1/qs-shell")" = "$1/lares" ] && [ -s "$1/lares/supervise.env" ] && [ -L "$1/qs-session" ] && [ "$(cat "$1/lares-session/pending/tok")" = mark ] &&
        [ "$(cat "$2/.local/share/lares/screentime/days/2026/2026-11-14.json")" = "{\"day\": 1}" ] && [ "$(cat "$2/.local/state/lares/notifications/history.json")" = "{\"history\": []}" ] &&
        [ "$(cat "$2/.local/state/lares/oled-shift.json")" = "{\"step\": 3}" ]' _ "$NRT" "$NHOME"
    own_after=$(for p in "$NSTATE/quickshell/by-shell/abc" "$NCACHE/quickshell/qmlcache" "$NCACHE/quickshell/crashes" "$NCACHE/quickshell/qtpipelinecache-abc" "$NCACHE/quickshell/qtshadercache-abc" "$NCACHE/quickshell/_qt_QGfxShaderBuilder_6.12.0" "$NDATA/quickshell/by-shell" "$NRT/quickshell/by-id/xyz"; do echo "$p $(nino "$p")"; done)
    check "namemove: Qt's own dirs an earlier run moved are put back: real directories at the old name with their content, nothing left under lares/ (the link's case and the cleaned-up case)" bash -c '
        c=$1/.cache; [ -d "$c/quickshell/qtshadercache-moved" ] && [ ! -L "$c/quickshell/qtshadercache-moved" ] && [ "$(cat "$c/quickshell/qtshadercache-moved/b")" = m ] &&
        [ -d "$c/quickshell/_qt_QGfxShaderBuilder_6.11.0" ] && [ "$(cat "$c/quickshell/_qt_QGfxShaderBuilder_6.11.0/s")" = m ] &&
        [ ! -e "$c/lares/qtshadercache-moved" ] && [ ! -L "$c/lares/qtshadercache-moved" ] && [ ! -e "$c/lares/_qt_QGfxShaderBuilder_6.11.0" ] &&
        grep -aq "^put back    .*qtshadercache-moved" "$2" && grep -aq "^put back    .*_qt_QGfxShaderBuilder_6.11.0" "$2"' _ "$NHOME" "$OUT/migrate.out"
    check "namemove: Quickshell's own (by-shell, qmlcache, crashes, qtpipelinecache-*, qtshadercache-*, _qt_*, by-id) were not touched: same inodes, still real directories, none under lares/" bash -c '
        [ "$1" = "$2" ] && [ ! -L "$3/.local/state/quickshell/by-shell" ] && [ ! -e "$3/.local/state/lares/by-shell" ] && [ ! -e "$3/.cache/lares/qmlcache" ] && [ ! -e "$3/.cache/lares/crashes" ] && [ ! -e "$3/.cache/lares/qtpipelinecache-abc" ] &&
        [ ! -e "$3/.cache/lares/qtshadercache-abc" ] && [ ! -e "$3/.cache/lares/_qt_QGfxShaderBuilder_6.12.0" ] && [ ! -e "$3/.local/share/lares/by-shell" ]' _ "$own_before" "$own_after" "$NHOME"
    check "namemove: ~/.local/bin/lares links the repo's tool; ~/.local/bin/qs-shell (a link of ours) is gone; lares-ime is a copy of the old binary, which stays until cleanup" bash -c '
        [ "$(readlink "$1/.local/bin/lares")" = "$2/tools/shell/lares" ] && [ ! -e "$1/.local/bin/qs-shell" ] && [ ! -L "$1/.local/bin/qs-shell" ] && [ -x "$1/.cache/lares-stt/bin/lares-ime" ] && [ -x "$1/.cache/lares-stt/bin/qs-ime" ]' _ "$NHOME" "$REPO"
    check "namemove: NO INSTANT WITHOUT THE OLD PATH: a reader asking ten old paths in a loop, from before the move to after it, missed none ($post)" bash -c '
        set -- $1; [ "${1:-0}" -gt 2000 ] && [ "${2:-1}" -eq 0 ]' _ "$post"
    check "namemove: the old supervisor and the old shell ran through it (same pids, alive)" bash -c 'kill -0 "$1" && kill -0 "$2" && [ "$(cat "$3/lares/supervise.pid")" = "$1" ]' _ "$sp" "$sh" "$NRT"
    check "namemove: it printed what is left: deploy FIRST (R1 and R3 install the deployed snapshot's files), the STALE lines, the root steps (R1 / R2 / R3, beside the old)" bash -c '
        grep -aq "^What is left, in this order" "$1" && grep -aq "R1  THE BOOT LOCK" "$1" && grep -aq "R2  THE PAM SERVICES" "$1" && grep -aq "R3  SILICON.S POLKIT ACTION" "$1" && grep -aq "lares deploy" "$1" &&
        grep -aq "STALE" "$1" && grep -aq "cleanup-old-name" "$1" &&
        [ "$(grep -an "^  1. lares deploy" "$1" | head -1 | cut -d: -f1)" -lt "$(grep -an "R1  THE BOOT LOCK" "$1" | head -1 | cut -d: -f1)" ]' _ "$OUT/migrate.out"
    N migrate-name
    check "namemove: a second run has nothing to do (exit 0) and asks nothing" bash -c '[ "$1" -eq 0 ] && grep -aq "nothing to do" "$2" && ! grep -aqi "type yes" "$2"' _ "$NRC" "$OUT/n.out"
    check "namemove: ... and moved nothing" test "$(ntree | grep -c ' l ')" -ge 14
    N status
    check "namemove: lares status sees the supervisor of the OLD name and says a deploy replaces it" bash -c 'grep -aq "runs under the OLD name" "$1"' _ "$OUT/n.out"
    # a link the user made himself is left alone
    local w2=$NW/two
    mkdir -p "$w2/home/.local/bin" "$w2/rt"; chmod 700 "$w2/rt"; printf '#!/bin/sh\necho mine\n' > "$w2/home/.local/bin/qs-shell"
    env HOME="$w2/home" XDG_RUNTIME_DIR="$w2/rt" XDG_CONFIG_HOME="$w2/home/.config" XDG_STATE_HOME="$w2/home/.local/state" XDG_CACHE_HOME="$w2/home/.cache" XDG_DATA_HOME="$w2/home/.local/share" \
        LARES_ROOT_PREFIX="$w2/root" LARES_BIN_DIR="$w2/home/.local/bin" bash -c 'printf "yes\n" | "$1/tools/shell/lares" migrate-name' _ "$REPO" > "$OUT/two.out" 2>&1
    check "namemove: a ~/.local/bin/qs-shell that is NOT a link of ours (a script of the user's) is left alone" bash -c 'grep -q "^#!/bin/sh" "$1" && grep -aq "left alone  .*bin/qs-shell" "$2" && [ -L "$3" ]' _ "$w2/home/.local/bin/qs-shell" "$OUT/two.out" "$w2/home/.local/bin/lares"
    # a conflict: both names hold something -> refused, nothing moved
    local w3=$NW/three
    mkdir -p "$w3/home/.local/state/quickshell/notifications" "$w3/home/.local/state/lares/notifications" "$w3/home/.local/state/quickshell/llm" "$w3/rt"; chmod 700 "$w3/rt"
    printf 'a\n' > "$w3/home/.local/state/quickshell/notifications/x"; printf 'b\n' > "$w3/home/.local/state/lares/notifications/y"
    env HOME="$w3/home" XDG_RUNTIME_DIR="$w3/rt" XDG_CONFIG_HOME="$w3/home/.config" XDG_STATE_HOME="$w3/home/.local/state" XDG_CACHE_HOME="$w3/home/.cache" XDG_DATA_HOME="$w3/home/.local/share" \
        LARES_ROOT_PREFIX="$w3/root" LARES_BIN_DIR="$w3/home/.local/bin" bash -c 'printf "yes\n" | "$1/tools/shell/lares" migrate-name' _ "$REPO" > "$OUT/three.out" 2>&1
    check "namemove: both names holding something is REFUSED with nothing moved (the other directories stay where they are)" bash -c '
        grep -aq "REFUSED     .*notifications and .*notifications both exist" "$1" && [ -d "$2/quickshell/llm" ] && [ ! -L "$2/quickshell/llm" ] && [ ! -e "$2/lares/llm" ]' _ "$OUT/three.out" "$w3/home/.local/state"
}

sc_namedeploy() {
    note "namedeploy: the first deploy after the move replaces the old supervisor and places a shim at each old entry-point name your lines still run"
    local sp sh sha snap lsnap
    sp=$(cat "$NRT/lares/supervise.pid" 2> /dev/null); sh=$(cat "$NRT/lares/pid" 2> /dev/null)
    check "namedeploy: before the deploy the old shell and supervisor still run (the world of the previous scenario)" bash -c 'kill -0 "$1" && kill -0 "$2"' _ "$sp" "$sh"
    rm -f "$LARES_FAKE/ctl/lares_ready_word"   # the shell the new snapshot starts says LARES
    mark namedeploy
    N deploy
    sha=$(repo rev-parse HEAD); snap=$NSTATE/lares/shell/$sha; lsnap=$NSTATE/lares/lock/$sha
    check "namedeploy: it deploys (exit 0) after the move, and says the old supervisor is replaced" bash -c '[ "$1" -eq 0 ] && grep -aq "runs under the old name" "$2" && grep -aq "shims of the old name placed in the shell snapshot: qs-shell" "$2"' _ "$NRC" "$OUT/n.out"
    check "namedeploy: the old supervisor and the old shell are gone; a supervisor of the NEW name runs from the new snapshot (lares-supervise) and the shell it started runs the new path" bash -c '
        ! kill -0 "$1" 2> /dev/null && ! kill -0 "$2" 2> /dev/null && np=$(cat "$3/lares/supervise.pid") && [ "$np" != "$1" ] && tr "\0" " " < /proc/$np/cmdline | grep -q "lares-supervise" &&
        tr "\0" " " < /proc/$np/cmdline | grep -qF "$4/tools/shell/lares-supervise" &&
        grep -a "QUICKSHELL start pid=$(cat "$3/lares/pid") " "$5" | grep -aqF "argv=-n -p $6/lares/shell/current/shell.qml"' _ "$sp" "$sh" "$NRT" "$snap" "$LOGF" "$NSTATE"
    check "namedeploy: the new shell says LARES ready, owns the notification name, and quickshell lists it by the NEW path" bash -c '
        grep -aq "LARES ready screens=" "$1/lares/shell.log" && [ "$(gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.GetConnectionUnixProcessID org.freedesktop.Notifications 2> /dev/null | sed -nE "s/.*uint32 ([0-9]+).*/\1/p")" = "$(cat "$1/lares/pid")" ] &&
        quickshell list --path "$2/lares/shell/current/shell.qml" --json | grep -q "\"pid\": $(cat "$1/lares/pid")"' _ "$NRT" "$NSTATE"
    check "namedeploy: the shims are in the SNAPSHOTS: qs-shell in the shell's; qs-lock-session, qs-lock-held (hyproled) and qs-lock-warm (autostart) in the lock's -- one line each, executable, never in the repo" bash -c '
        for f in "$1/tools/shell/qs-shell" "$2/tools/lockscreen/qs-lock-session" "$2/tools/lockscreen/qs-lock-held" "$2/tools/lockscreen/qs-lock-warm"; do
            [ -x "$f" ] && grep -q "a shim of the OLD name" "$f" && [ "$(grep -vc "^#" "$f")" -eq 1 ] || { echo "      (no shim: $f)" >&2; exit 1; }; done
        [ -z "$(git -C "$3" ls-files | grep -E "(^|/)qs-")" ] && [ ! -e "$3/tools/shell/qs-shell" ] && [ ! -e "$3/tools/lockscreen/qs-lock-session" ]' _ "$snap" "$lsnap" "$REPO"
    check "namedeploy: a line of yours that still runs the OLD path works: qs-shell status through ~/.local/state/quickshell/shell/current/tools/shell/qs-shell; the lock launchers likewise" bash -c '
        o=$1/.local/state/quickshell; h=$HOME
        out=$(env HOME="$1" XDG_RUNTIME_DIR="$2" XDG_STATE_HOME="$1/.local/state" XDG_CONFIG_HOME="$1/.config" "$o/shell/current/tools/shell/qs-shell" status 2>&1)
        echo "$out" | grep -q "^deployed " || { echo "      ($out)" >&2; exit 1; }
        env XDG_RUNTIME_DIR="$2" "$o/lock/current/tools/lockscreen/qs-lock-held"; [ $? -eq 1 ]' _ "$NHOME" "$NRT"
    # new lines: no shim is placed; the same commit deployed again takes the shims away
    local f
    for f in config/autostart.lua config/keybinds.lua config/layerrules.lua config/environment.lua hypridle.conf scripts/hyproled/hyproled-toggle.sh; do
        cp -p "$FIXD/home/.config/hypr/$f" "$NHOME/.config/hypr/$f"; sed -i "s|/home/user/|$NHOME/|g" "$NHOME/.config/hypr/$f"
    done
    printf '[ -f ~/.local/state/lares/shell/current/tools/session/session-hook.bash ] && . ~/.local/state/lares/shell/current/tools/session/session-hook.bash\n' > "$NHOME/.bashrc"
    rm -f "$NROOT/usr/local/bin/qs-boot-lock" "$NROOT/usr/local/share/wayland-sessions/hyprland-qslock.desktop"
    sed -i 's/^Session=hyprland-qslock/Session=hyprland-lares/' "$NROOT/etc/sddm.conf.d/autologin.conf"
    mark namedeploy2
    N deploy
    check "namedeploy: with the lines new (and no old boot lock installed) the same deploy takes the shims away and says none placed" bash -c '
        [ "$1" -eq 0 ] && [ ! -e "$2/tools/shell/qs-shell" ] && [ ! -e "$3/tools/lockscreen/qs-lock-session" ] && [ ! -e "$3/tools/lockscreen/qs-lock-held" ] && [ ! -e "$3/tools/lockscreen/qs-lock-warm" ] &&
        ! grep -aq "shims of the old name placed" "$4"' _ "$NRC" "$snap" "$lsnap" "$OUT/n.out"
    # only the installed old boot lock names an old entry point
    cp -a "$FIX/deploy_old/root/usr/local/bin/qs-boot-lock" "$NROOT/usr/local/bin/qs-boot-lock"
    mark namedeploy3
    N deploy
    check "namedeploy: an installed old root file (qs-boot-lock) alone asks for ONE shim, qs-lock-session, and not for qs-shell" bash -c '
        [ "$1" -eq 0 ] && [ -x "$3/tools/lockscreen/qs-lock-session" ] && [ ! -e "$3/tools/lockscreen/qs-lock-held" ] && [ ! -e "$2/tools/shell/qs-shell" ] && grep -aq "placed in the lock snapshot: qs-lock-session" "$4"' _ "$NRC" "$snap" "$lsnap" "$OUT/n.out"
    rm -f "$NROOT/usr/local/bin/qs-boot-lock"
    N deploy
}

sc_namebinds() {
    note "namebinds: a line of yours that names the old name is STALE, with the new line beside it"
    local f pre
    for f in config/autostart.lua config/keybinds.lua config/layerrules.lua config/environment.lua hypridle.conf scripts/hyproled/hyproled-toggle.sh; do   # today's lines again
        cp -p "$FIX/deploy_old/home/.config/hypr/$f" "$NHOME/.config/hypr/$f"; sed -i "s|/home/user/|$NHOME/|g" "$NHOME/.config/hypr/$f"
    done
    pre=$(cd "$NHOME" && find .config -type f -exec sha256sum {} + | LC_ALL=C sort)
    N binds; cp "$OUT/n.out" "$OUT/binds_old.out"
    check "namebinds: exit 1; each old global (quickshell:launcher ...) is STALE as the OLD app id, with the shell's line (lares:launcher) beside it" bash -c '
        [ "$1" -eq 1 ] && grep -aE "^  STALE +ALT \+ SPACE" "$2" | grep -aq "the OLD app id" && grep -aq "hl.bind(\"ALT + SPACE\", hl.dsp.global(\"lares:launcher\"))" "$2"' _ "$NRC" "$OUT/binds_old.out"
    check "namebinds: the old autostart lines (qs-shell start, qs-lock-session --boot, qs-lock-warm) and the rescue key are STALE: the OLD name, now lares / lares-lock-*" bash -c '
        grep -aE "^  STALE .*exec_cmd" "$1" | grep -aq "runs .qs-shell., the OLD name (now .lares.)" && grep -aE "^  STALE .*exec_cmd" "$1" | grep -aq "runs .qs-lock-session., the OLD name" &&
        grep -aE "^  STALE .*exec_cmd" "$1" | grep -aq "runs .qs-lock-warm., the OLD name" && grep -aE "^  STALE .*F12" "$1" | grep -aq "the OLD name"' _ "$OUT/binds_old.out"
    check "namebinds: QS_CONFIG_PATH naming the old snapshot path is STALE (not merely DIFFERS); the old layer rules (^qs-bar$ ...) are STALE namespaces" bash -c '
        grep -aE "^  STALE +QS_CONFIG_PATH" "$1" | grep -aq "the OLD snapshot path" && grep -aE "^  STALE +layer rule" "$1" | grep -aq "OLD namespace ^qs-bar\$ (now ^lares-bar\$)"' _ "$OUT/binds_old.out"
    check "namebinds: nothing was written (every config file of the home byte for byte)" test "$(cd "$NHOME" && find .config -type f -exec sha256sum {} + | LC_ALL=C sort)" = "$pre"
    N setup; cp "$OUT/n.out" "$OUT/setup_old.out"
    check "namebinds: setup names the lines of yours that still say the old name (hypridle.conf, hyproled-toggle.sh, ~/.bashrc?) and the shims keep them working" bash -c '
        grep -aE "^  TO DO +your lines" "$1" > /dev/null && grep -aq "hypridle.conf:.*names qs-lock-session" "$1" && grep -aq "hyproled-toggle.sh:.*names qs-lock-held" "$1"' _ "$OUT/setup_old.out"
}

nroot_cmds() { RROOT=$NROOT root_cmds "$@"; }
sc_nameroot() {
    note "nameroot: setup prints the root steps for an OLD root (today's machine), the Lares files go BESIDE the old, and they run AS PRINTED on the fake root"
    local before
    rm -rf "$NROOT"; mkdir -p "$NROOT"; cp -a "$FIX/deploy_old/root/." "$NROOT/"   # today's machine again (the previous scenario edited it)
    before=$(cd "$NROOT" && find . -type f -exec sha256sum {} + | LC_ALL=C sort)
    N setup; cp "$OUT/n.out" "$OUT/nsetup.out"
    check "nameroot: R1, R2 and R3 are TO DO (the Lares files are not there), and the steps name the copies beside the old (qs-lock -> lares-lock, org.lares.silicon.helper beside the old policy)" bash -c '
        grep -aqE "^  TO DO +R1 the boot lock" "$1" && grep -aqE "^  TO DO +R2 PAM \+ keyring" "$1" && grep -aqE "^  TO DO +R3 silicon.s polkit" "$1" &&
        grep -aq "sudo install -m 0644 /etc/pam.d/qs-lock /etc/pam.d/lares-lock" "$1" && grep -aq "sudo install -m 0644 /etc/pam.d/qs-lock-face /etc/pam.d/lares-lock-face" "$1" &&
        grep -aq "org.lares.silicon.helper.policy" "$1" && grep -aq "Session=hyprland-qslock/" "$1"' _ "$OUT/nsetup.out"
    nroot_cmds make "$OUT/nsetup.out" > "$OUT/nroot.do"; nroot_cmds undo "$OUT/nsetup.out" > "$OUT/nroot.undo"
    check "nameroot: the printed steps hold 9 commands to make them (R1 2, R2 4, R3 3) and 5 to undo them" bash -c '[ "$(wc -l < "$1")" -eq 9 ] && [ "$(wc -l < "$2")" -eq 5 ]' _ "$OUT/nroot.do" "$OUT/nroot.undo"
    # SDDM may name the new session only on the line that installs both of its files: a failed install must leave the old session in force
    check "nameroot: SDDM is switched only together with the boot lock and the session file (one line, joined by &&)" bash -c '
        l=$(grep -a "Session=hyprland-lares/" "$1"); [ "$(printf "%s\n" "$l" | grep -c .)" -eq 1 ] &&
        printf "%s" "$l" | grep -aq "lares-boot-lock .*&& .*hyprland-lares.desktop .*&& .*sed -i"' _ "$OUT/nroot.do"
    rm -f "$OUT/root.refused"
    run_root_cmds "$OUT/nroot.do"; run_root_cmds "$OUT/nroot.do"   # twice: each is safe to run again
    check "nameroot: every printed command could be moved to the fake root (no sudo left, no real path)" test ! -e "$OUT/root.refused"
    check "nameroot: the Lares files are BESIDE the old: the boot lock and session file are the snapshot's, lares-lock / lares-lock-face are copies (the keyring line ONCE), the new polkit policy and rule are in; SDDM says hyprland-lares" bash -c '
        r=$1; [ -x "$r/usr/local/bin/lares-boot-lock" ] && [ -e "$r/usr/local/share/wayland-sessions/hyprland-lares.desktop" ] && grep -qx "Session=hyprland-lares" "$r/etc/sddm.conf.d/autologin.conf" &&
        cmp -s "$r/etc/pam.d/qs-lock" "$r/etc/pam.d/lares-lock" && cmp -s "$r/etc/pam.d/qs-lock-face" "$r/etc/pam.d/lares-lock-face" && [ "$(grep -c pam_gnome_keyring "$r/etc/pam.d/lares-lock")" -eq 1 ] &&
        [ -f "$r/usr/share/polkit-1/actions/org.lares.silicon.helper.policy" ] && grep -q "org.lares.silicon.helper" "$r/etc/polkit-1/rules.d/50-lares-silicon-helper.rules" && grep -q "user\|$(id -un)" "$r/etc/polkit-1/rules.d/50-lares-silicon-helper.rules"' _ "$NROOT"
    check "nameroot: NOTHING OF THE OLD NAME WAS REMOVED (qs-boot-lock, hyprland-qslock.desktop, qs-lock, qs-lock-face, the old policy and rule: byte for byte)" bash -c '
        cd "$1" && for f in usr/local/bin/qs-boot-lock usr/local/share/wayland-sessions/hyprland-qslock.desktop etc/pam.d/qs-lock etc/pam.d/qs-lock-face usr/share/polkit-1/actions/org.quickshell.silicon.helper.policy etc/polkit-1/rules.d/50-quickshell-silicon-helper.rules; do
            cmp -s "$f" "$2/$f" || { echo "      (changed: $f)" >&2; exit 1; }; done' _ "$NROOT" "$FIX/deploy_old/root"
    N setup
    check "nameroot: with the steps run, R1, R2 and R3 are ok" bash -c 'grep -aqE "^  ok +R1 the boot lock" "$1" && grep -aqE "^  ok +R2 PAM \+ keyring" "$1" && grep -aqE "^  ok +R3 silicon.s polkit" "$1"' _ "$OUT/n.out"
    run_root_cmds "$OUT/nroot.undo"
    check "nameroot: the printed undo removes the Lares files and puts SDDM's line back to hyprland-qslock; the old files are untouched (the whole root byte for byte as before)" test "$(cd "$NROOT" && find . -type f -exec sha256sum {} + | LC_ALL=C sort)" = "$before"
    run_root_cmds "$OUT/nroot.do"   # the steps stay done for the cleanup scenario
}

sc_namecleanup() {
    note "namecleanup: cleanup-old-name refuses while anything still names an old thing, then removes the symlinks"
    local pre n holder
    # still old: the user's lines, the venv; the old boot session in SDDM was switched by the root steps; a lock of the old name is up
    for f in config/autostart.lua config/keybinds.lua config/layerrules.lua config/environment.lua hypridle.conf scripts/hyproled/hyproled-toggle.sh; do
        cp -p "$FIX/deploy_old/home/.config/hypr/$f" "$NHOME/.config/hypr/$f"; sed -i "s|/home/user/|$NHOME/|g" "$NHOME/.config/hypr/$f"
    done
    ( setsid -f flock -n "$NRT/qs-lock.lock" sleep 601 < /dev/null > /dev/null 2>&1 )   # a lock of the old name: the flock is held by that sleep
    waitfor 5 env XDG_RUNTIME_DIR="$NRT" "$REPO/tools/lockscreen/lares-lock-held" --old
    N cleanup-old-name; cp "$OUT/n.out" "$OUT/cu1.out"
    check "namecleanup: REFUSED (exit 1), every reason named, nothing removed" bash -c '[ "$1" -eq 1 ] && grep -aq "nothing was removed" "$2" && [ -L "$3/.local/state/quickshell/shell" ]' _ "$NRC" "$OUT/cu1.out" "$NHOME"
    check "namecleanup: it refuses for your lines that still name an old name (autostart, hypridle, hyproled-toggle.sh)" bash -c '
        grep -aq "^REFUSED     .*autostart.lua:[0-9]* still names qs-shell" "$1" && grep -aq "^REFUSED     .*hypridle.conf:[0-9]* still names qs-lock-session" "$1" && grep -aq "^REFUSED     .*hyproled-toggle.sh:[0-9]* still names" "$1"' _ "$OUT/cu1.out"
    check "namecleanup: it refuses for the dictation's venv that names the old path (pyvenv.cfg and a script's shebang)" bash -c '
        grep -aq "^REFUSED     the dictation.s venv names the old path (pyvenv.cfg)" "$1" && grep -aq "^REFUSED     the dictation.s venv names the old path (bin/pip)" "$1"' _ "$OUT/cu1.out"
    check "namecleanup: it refuses for a lock of the old name that is up" bash -c 'grep -aq "^REFUSED     a lock of the old name is up" "$1"' _ "$OUT/cu1.out"
    # fix them one at a time
    for f in config/autostart.lua config/keybinds.lua config/layerrules.lua config/environment.lua hypridle.conf scripts/hyproled/hyproled-toggle.sh; do
        cp -p "$FIXD/home/.config/hypr/$f" "$NHOME/.config/hypr/$f"; sed -i "s|/home/user/|$NHOME/|g" "$NHOME/.config/hypr/$f"
    done
    N cleanup-old-name; cp "$OUT/n.out" "$OUT/cu2.out"
    check "namecleanup: with the lines new the refusals for them are gone; the venv and the old lock are still named" bash -c '
        [ "$1" -eq 1 ] && ! grep -aq "still names" "$2" && grep -aq "^REFUSED     the dictation.s venv" "$2" && grep -aq "^REFUSED     a lock of the old name is up" "$2"' _ "$NRC" "$OUT/cu2.out"
    printf 'command = python -m venv %s/.local/share/lares/stt/venv\n' "$NHOME" > "$NDATA/lares/stt/venv/pyvenv.cfg"
    printf '#!%s/.local/share/lares/stt/venv/bin/python\nprint(1)\n' "$NHOME" > "$NDATA/lares/stt/venv/bin/pip"
    N cleanup-old-name; cp "$OUT/n.out" "$OUT/cu3.out"
    check "namecleanup: with the venv rebuilt (its paths new) only the lock of the old name is left to refuse" bash -c '[ "$1" -eq 1 ] && ! grep -aq "venv" "$2"' _ "$NRC" "$OUT/cu3.out"
    # release the lock holder by its own pid: the one process whose environment carries this world's marker and whose command line holds the flock
    for n in $(fake_pids sleep 601); do kill "$n" 2> /dev/null; done
    waitfor 5 bash -c '! env XDG_RUNTIME_DIR="$2" "$1/tools/lockscreen/lares-lock-held" --old' _ "$REPO" "$NRT"
    N cleanup-old-name --dry-run
    check "namecleanup: --dry-run plans the removal of every symlink, lists the root files to remove (only the installed ones), changes nothing" bash -c '
        [ "$1" -eq 0 ] && grep -aq "^WILL REMOVE .*quickshell/shell (a link to" "$2" && grep -aq "^WILL REMOVE .*qs-shell (a link to" "$2" && grep -aq "^WILL REMOVE .*qs-ime (lares-ime is built" "$2" &&
        grep -aq "sudo rm -f /usr/local/bin/qs-boot-lock /usr/local/share/wayland-sessions/hyprland-qslock.desktop /etc/pam.d/qs-lock /etc/pam.d/qs-lock-face /usr/share/polkit-1/actions/org.quickshell.silicon.helper.policy /etc/polkit-1/rules.d/50-quickshell-silicon-helper.rules" "$2" &&
        grep -aq "^nothing was changed" "$2" && [ -L "$3/.local/state/quickshell/shell" ]' _ "$NRC" "$OUT/n.out" "$NHOME"
    Ny no cleanup-old-name
    check "namecleanup: a no removes nothing" bash -c '[ "$1" -eq 1 ] && grep -aq "nothing was removed" "$2" && [ -L "$3/.local/state/quickshell/shell" ]' _ "$NRC" "$OUT/n.out" "$NHOME"
    Ny yes cleanup-old-name; cp "$OUT/n.out" "$OUT/cu4.out"
    check "namecleanup: a yes removes every symlink of the old name (state, cache, data, runtime) and the old ime copy; the Lares directories are intact; Quickshell's own are untouched" bash -c '
        h=$1; for p in .local/state/quickshell/shell .local/state/quickshell/lock .local/state/quickshell/notifications .local/state/qs-shell .cache/quickshell-stt .cache/quickshell-lock .cache/quickshell/wiki .local/share/quickshell/screentime .local/share/quickshell/stt; do
            [ ! -e "$h/$p" ] && [ ! -L "$h/$p" ] || { echo "      (left: $p)" >&2; exit 1; }; done
        [ ! -L "$2/qs-shell" ] && [ ! -e "$2/qs-shell" ] && [ ! -e "$2/qs-session" ] && [ ! -e "$h/.cache/lares-stt/bin/qs-ime" ] && [ -x "$h/.cache/lares-stt/bin/lares-ime" ] &&
        [ -s "$h/.local/state/lares/notifications/history.json" ] && [ -d "$h/.local/state/quickshell/by-shell/abc" ] && [ -d "$h/.cache/quickshell/qmlcache" ] && [ -d "$h/.local/share/quickshell/by-shell" ] && [ -d "$2/quickshell/by-id/xyz" ]' _ "$NHOME" "$NRT"
    N cleanup-old-name
    check "namecleanup: a second run has nothing left to remove (exit 0)" bash -c '[ "$1" -eq 0 ] && grep -aq "nothing to do" "$2"' _ "$NRC" "$OUT/n.out"
}

# ---- the run ------------------------------------------------------------------------------------------
world_up
sc_guard   # always first, whatever ONLY says: nothing below may run before the world is proven to be the world
SCENARIOS=${ONLY:-}
if [ -z "$SCENARIOS" ]; then
    if [ -n "${ARM:-}" ]; then SCENARIOS=$(arm_scenarios "$ARM")
    else SCENARIOS="dryrun deploy status start restart redeploy apply pacman fallback crashloop stale logcap binds setup boost cleanup namemove namedeploy namebinds nameroot namecleanup"; fi
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
